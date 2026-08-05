;;; cmacs-brigade-voice.el --- Talking to the brigade  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Voice in, voice out, over machinery that already exists.
;;
;; The input half is whisper, but not through `cmacs-whisper-dictate':
;; that is a streaming insert-as-you-talk toggle, which is the right
;; shape for writing prose into a buffer and the wrong shape here.  What
;; this file needs is push-to-talk -- say one phrase, get the whole thing
;; back as a string -- so `cmacs-brigade-voice-listen' builds that
;; directly on the audio capture DEFUNs and transcribes once at the end.
;; Transcribing the phrase whole also transcribes it better, since a
;; sentence split across three-second windows loses the context that
;; makes the middle of it unambiguous.
;;
;; The output half is deliberately thin.  `cmacs-brigade-notify' already
;; owns when to speak and how insistently; this file only adds what you
;; would want to ask it unprompted -- what is running, what is waiting on
;; me, what has this cost -- and answers out loud, because if you asked
;; out loud you are not looking at the screen.
;;
;; Dictating a task writes an org headline and adopts it, rather than
;; poking the runtime directly.  Org is authoritative for intent; a
;; spoken task is still intent, and it should be as visible, editable and
;; git-tracked as one you typed.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-notify)
(require 'cl-lib)
(require 'subr-x)

;; Required, not merely declared.  `cmacs-whisper-model-path' and the
;; capture defaults are Elisp, and a `declare-function' or a bare
;; `defvar' loads nothing: `cmacs-brigade-voice-listen' died on a void
;; `cmacs-whisper-model-path' the first time anyone pressed the key,
;; because nothing in a session had happened to pull those files in.
;; Soft, so a build without whisper or audio still loads this file --
;; `cmacs-brigade-voice-available-p' is what decides whether the
;; commands can run.
(require 'cmacs-whisper nil t)
(require 'cmacs-audio nil t)
(require 'cmacs-piper nil t)
;; The voice keymap binds `cmacs-brigade-compose-voice', so the compose
;; layer has to be there when the map is built.  No cycle: compose pulls
;; voice in at call time, not load time.
(require 'cmacs-brigade-compose)

(defgroup cmacs-brigade-voice nil
  "Voice control for the brigade."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-voice-")

(defcustom cmacs-brigade-voice-agent nil
  "Agent used for a dictated task when none is named.  nil asks."
  :type '(choice (const :tag "Ask" nil) symbol)
  :group 'cmacs-brigade-voice)

(defcustom cmacs-brigade-voice-plan-file nil
  "Plan a dictated task is appended to.

nil means `inbox.org' under `cmacs-brigade-plan-directory'.  A spoken
task is a capture, and captures want one predictable destination."
  :type '(choice (const :tag "inbox.org in the plan directory" nil) file)
  :group 'cmacs-brigade-voice)

(defcustom cmacs-brigade-voice-confirm t
  "Whether a dictated task is shown for confirmation before it is queued.

Worth leaving on.  Transcription is good but not perfect, and the failure
mode is an agent spending real money on a misheard instruction."
  :type 'boolean
  :group 'cmacs-brigade-voice)

(defcustom cmacs-brigade-voice-speak-answers t
  "Whether spoken questions get spoken answers."
  :type 'boolean
  :group 'cmacs-brigade-voice)

(defcustom cmacs-brigade-voice-speak-approvals t
  "Whether a confirmation request is read aloud.

The answer is still typed.  Approval is a synchronous gate, and blocking
the editor for several seconds to record a spoken yes would stall
whatever else is running -- under `--gowl' that is the compositor.
Hearing the question from across the room is the part that matters; you
are coming back to the keyboard either way."
  :type 'boolean
  :group 'cmacs-brigade-voice)

(defcustom cmacs-brigade-voice-max-seconds 120
  "Longest phrase recorded before stopping on its own.

A backstop against a push-to-talk that never gets its second push --
without it a forgotten recording grows at 32 KB per second until
something notices."
  :type 'integer
  :group 'cmacs-brigade-voice)

(defcustom cmacs-brigade-voice-poll-seconds 0.25
  "How often capture is drained while recording."
  :type 'number
  :group 'cmacs-brigade-voice)

(declare-function cmacs-whisper-supported-p "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-transcribe-pcm-async "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-model-path "cmacs-whisper")
(declare-function cmacs-piper-supported-p "cmacs-piper-defuns.c")
(declare-function cmacs-piper-speak-async "cmacs-piper")
(declare-function cmacs-audio--capture-open-1 "cmacs-audio-defuns.c")
(declare-function cmacs-audio-start "cmacs-audio-defuns.c")
(declare-function cmacs-audio-close "cmacs-audio-defuns.c")
(declare-function cmacs-audio-read-pcm "cmacs-audio-defuns.c")
(declare-function cmacs-brigade-plan-adopt "cmacs-brigade-plan")
(declare-function cmacs-brigade-plan-mode "cmacs-brigade-plan")
(declare-function cmacs-brigade-plan-append-task "cmacs-brigade-plan"
                  (file spec))

;; Both live in cmacs-brigade-plan.el, which is loaded on demand rather
;; than required here: dictating a task is the only path that needs the
;; plan layer, and requiring it eagerly would pull org into a session
;; that only ever asks for status.
(defvar cmacs-brigade-plan-todo-line)
(defvar cmacs-brigade-plan-directory)
(defvar cmacs-audio-default-rate)
(defvar cmacs-audio-capture-source)
(defvar cmacs-audio-default-device)
(defvar cmacs-whisper-language)

(defun cmacs-brigade-voice-available-p ()
  "Whether voice input is usable in this build.

Checks the Elisp layers too, not just the C DEFUNs.  Testing only
`cmacs-whisper-supported-p' reported voice as available in a build where
the whisper Lisp file had never been loaded, so the key worked right up
until it called `cmacs-whisper-model-path' and died."
  (and (fboundp 'cmacs-whisper-supported-p)
       (cmacs-whisper-supported-p)
       (fboundp 'cmacs-audio--capture-open-1)
       (fboundp 'cmacs-whisper-model-path)
       (boundp 'cmacs-audio-default-rate)))

(defun cmacs-brigade-voice--say (text)
  "Speak TEXT if speech is available and wanted.  Returns TEXT."
  (when (and cmacs-brigade-voice-speak-answers
             (fboundp 'cmacs-piper-supported-p)
             (cmacs-piper-supported-p))
    (cmacs-piper-speak-async text nil cmacs-brigade-notify-voice))
  text)


;;;; Push to talk
;;
;; One recording at a time, globally.  Two concurrent captures on the
;; same device is not a state worth supporting, and the second command
;; stopping the first is what a push-to-talk key is expected to do.

(defvar cmacs-brigade-voice--handle nil)
(defvar cmacs-brigade-voice--timer nil)
(defvar cmacs-brigade-voice--chunks nil)
(defvar cmacs-brigade-voice--callback nil)
(defvar cmacs-brigade-voice--started nil)
(defvar cmacs-brigade-voice--label "")

(defun cmacs-brigade-voice-recording-p ()
  "Whether a phrase is being recorded right now."
  (and cmacs-brigade-voice--handle t))

(defun cmacs-brigade-voice--drain ()
  "Move whatever capture has buffered into the accumulator."
  (when cmacs-brigade-voice--handle
    ;; `cmacs-audio-read-pcm' drains *up to* this many frames, so ask for
    ;; several polls' worth: over-requesting costs a transient buffer,
    ;; under-requesting silently drops the tail of a late tick.
    (let ((pcm (ignore-errors
                 (cmacs-audio-read-pcm cmacs-brigade-voice--handle
                                       (* cmacs-audio-default-rate 2)))))
      (when (and pcm (> (length pcm) 0))
        (push pcm cmacs-brigade-voice--chunks)))
    ;; Stop on our own rather than record forever if the second push
    ;; never comes.
    (when (> (- (float-time) cmacs-brigade-voice--started)
             cmacs-brigade-voice-max-seconds)
      (message "cmacs-brigade-voice: stopped at %ds"
               cmacs-brigade-voice-max-seconds)
      (cmacs-brigade-voice-stop))))

;;;###autoload
(defun cmacs-brigade-voice-listen (label callback)
  "Record a phrase, then call CALLBACK with its text.

LABEL says what is being recorded, for the echo area.  Returns
immediately: recording stops on the next `cmacs-brigade-voice-stop', and
CALLBACK runs after transcription.

The public primitive the other voice commands are built on, and the one
to reach for when adding your own."
  (unless (cmacs-brigade-voice-available-p)
    (user-error "cmacs-brigade: voice needs whisper and audio in this build"))
  (when (cmacs-brigade-voice-recording-p)
    (cmacs-brigade-voice-stop))
  (let ((model (cmacs-whisper-model-path)))
    (unless (file-exists-p model)
      (user-error "Whisper model not found: %s.  Run %s"
                  model "M-x cmacs-whisper-download-model")))
  (setq cmacs-brigade-voice--chunks nil
        cmacs-brigade-voice--callback callback
        cmacs-brigade-voice--label label
        cmacs-brigade-voice--started (float-time)
        cmacs-brigade-voice--handle
        (cmacs-audio--capture-open-1
         :source cmacs-audio-capture-source
         :rate cmacs-audio-default-rate
         :channels 1
         :device cmacs-audio-default-device))
  (cmacs-audio-start cmacs-brigade-voice--handle)
  (setq cmacs-brigade-voice--timer
        (run-with-timer cmacs-brigade-voice-poll-seconds
                        cmacs-brigade-voice-poll-seconds
                        #'cmacs-brigade-voice--drain))
  (message "%s -- recording.  %s to stop." label
           (substitute-command-keys "\\[cmacs-brigade-voice-stop]")))

;;;###autoload
(defun cmacs-brigade-voice-stop ()
  "Stop recording and transcribe what was said."
  (interactive)
  (unless (cmacs-brigade-voice-recording-p)
    (user-error "cmacs-brigade-voice: not recording"))
  (when cmacs-brigade-voice--timer
    (cancel-timer cmacs-brigade-voice--timer)
    (setq cmacs-brigade-voice--timer nil))
  (cmacs-brigade-voice--drain)
  (let ((pcm (apply #'concat (nreverse cmacs-brigade-voice--chunks)))
        (cb cmacs-brigade-voice--callback))
    (cmacs-audio-close cmacs-brigade-voice--handle)
    (setq cmacs-brigade-voice--handle nil
          cmacs-brigade-voice--chunks nil
          cmacs-brigade-voice--callback nil)
    ;; Under ~0.1s of audio: a stray double-press, not a phrase.
    (if (< (length pcm) 3200)
        (message "cmacs-brigade-voice: heard nothing")
      (message "%s -- transcribing..." cmacs-brigade-voice--label)
      (cmacs-whisper-transcribe-pcm-async
       (cmacs-whisper-model-path) pcm
       (lambda (result)
         (let ((err (cdr (assq :error result)))
               (text (string-trim (or (cdr (assq :text result)) ""))))
           (cond
            (err (message "cmacs-brigade-voice: %s" err))
            ((string-empty-p text)
             (message "cmacs-brigade-voice: heard nothing"))
            (t (funcall cb text)))))
       cmacs-whisper-language))))


;;;; Dictating a task

(defun cmacs-brigade-voice--plan-file ()
  "The file a dictated task is appended to, created if absent."
  (require 'cmacs-brigade-plan)
  (let ((file (or cmacs-brigade-voice-plan-file
                  (expand-file-name "inbox.org"
                                    cmacs-brigade-plan-directory))))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+title: Voice inbox\n"
                cmacs-brigade-plan-todo-line "\n\n")))
    file))

;;;###autoload
(defun cmacs-brigade-voice-task (&optional agent)
  "Dictate a task for AGENT.

Run it, say what you want done, run `cmacs-brigade-voice-stop' to finish.
The task is appended to the voice plan as an ordinary org headline and
adopted -- so it is editable, refilable and in git like any other."
  (interactive
   (list (or cmacs-brigade-voice-agent
             (let ((names (cmacs-brigade-registry-list 'agent)))
               (when names
                 (intern (completing-read "Agent: " names nil t)))))))
  (cmacs-brigade-voice-listen
   "Task"
   (lambda (text)
     (if (and cmacs-brigade-voice-confirm
              (not (y-or-n-p (format "Queue for %s: %S ? "
                                     (or agent "default") text))))
         (message "cmacs-brigade-voice: discarded")
       (cmacs-brigade-voice--queue text agent)))))

(defun cmacs-brigade-voice--queue (text agent)
  "Append TEXT as a task for AGENT to the voice plan, and adopt it.

The heading is a summary and the body is the prompt: splitting them
keeps the agenda readable when the spoken task runs long."
  (require 'cmacs-brigade-plan)
  (let ((file (cmacs-brigade-voice--plan-file)))
    (cmacs-brigade-plan-append-task
     file (list :title (cmacs-brigade-voice--summarize text)
                :prompt text
                :agent agent))
    (with-current-buffer (find-file-noselect file)
      (when (fboundp 'cmacs-brigade-plan-mode) (cmacs-brigade-plan-mode 1)))
    (cmacs-brigade-voice--say
     (format "Queued for %s." (or agent "the default agent")))
    file))

(defun cmacs-brigade-voice--summarize (text)
  "A headline-length summary of TEXT."
  (let ((one (replace-regexp-in-string "[ \t\n]+" " " (string-trim text))))
    (if (<= (length one) 60) one
      (concat (substring one 0 57) "..."))))


;;;; Asking about state

(defconst cmacs-brigade-voice--queries
  '(("waiting\\|blocked\\|stuck\\|need"       . waiting)
    ("cost\\|spend\\|spent\\|budget\\|money"  . spend)
    ("done\\|finished\\|complete"             . finished)
    ("running\\|going\\|active\\|status\\|doing" . status))
  "Spoken phrasings mapped to the question being asked.

Regexp matching rather than a model call on purpose: there are four
questions, the answers are already computed, and round-tripping \"what is
running\" through an LLM to find out would take longer than the answer is
worth.  Ordered most specific first -- \"what still needs me\" contains
neither \"running\" nor \"status\" but is not a status query.")

;;;###autoload
(defun cmacs-brigade-voice-ask ()
  "Ask the brigade a spoken question about what it is doing."
  (interactive)
  (cmacs-brigade-voice-listen
   "Question"
   (lambda (text)
     (let ((answer (cmacs-brigade-voice-answer-query text)))
       (message "%s" answer)
       (cmacs-brigade-voice--say answer)))))

(defun cmacs-brigade-voice-answer-query (text)
  "Answer the question in TEXT about the brigade's state.

Returns a sentence meant to be heard: short, leading with the number,
because that is the part being listened for."
  (let ((kind (cl-loop for (re . k) in cmacs-brigade-voice--queries
                       when (string-match-p re (downcase text)) return k)))
    (pcase kind
      ('waiting (cmacs-brigade-voice--waiting))
      ('spend (cmacs-brigade-voice--spend))
      ('finished (cmacs-brigade-voice--finished))
      (_ (cmacs-brigade-notify-status)))))

(defun cmacs-brigade-voice--waiting ()
  "A spoken summary of what is blocked on you."
  (let ((p (cmacs-brigade-notify-pending)))
    (if (null p) "Nothing is waiting on you."
      (format "%d waiting: %s." (length p)
              (string-join (mapcar (lambda (c)
                                     (format "%s" (or (plist-get (cdr c) :agent)
                                                      (car c))))
                                   p)
                           ", ")))))

(defun cmacs-brigade-voice--tasks ()
  "Every runtime record, or nil when the runtime is not compiled in."
  (and (fboundp 'cmacs-brigade-task-list) (cmacs-brigade-task-list)))

(defun cmacs-brigade-voice--spend ()
  "A spoken summary of what has been spent."
  (if (not (fboundp 'cmacs-brigade-task-list))
      "I cannot see spending in this build."
    (let ((total 0))
      (dolist (r (cmacs-brigade-voice--tasks))
        (setq total (+ total (or (plist-get r :cost-micros) 0))))
      (format "%.2f dollars so far." (/ total 1000000.0)))))

(defun cmacs-brigade-voice--finished ()
  "A spoken summary of what has finished."
  (if (not (fboundp 'cmacs-brigade-task-list))
      "I cannot see tasks in this build."
    (let ((done (cl-remove-if-not
                 (lambda (r) (eq (plist-get r :state) 'done))
                 (cmacs-brigade-voice--tasks))))
      (if (null done) "Nothing has finished yet."
        (format "%d finished: %s."
                (length done)
                (string-join
                 (mapcar (lambda (r) (format "%s" (or (plist-get r :agent)
                                                      (plist-get r :id))))
                         done)
                 ", "))))))


;;;; Reading confirmations aloud
;;
;; NOT registered at load.  Registering any approval handler replaces the
;; fallback policy in `cmacs-brigade--confirm', and that fallback refuses
;; when it cannot ask -- a batch or headless session must not have
;; "could not ask" quietly become "went ahead anyway".  A handler
;; installed merely because this file was loaded would take that decision
;; away from every session, including ones with no human in them.
;;
;; So this is opt-in, and the handler itself still refuses rather than
;; prompts when there is nobody to prompt.

(defun cmacs-brigade-voice--approve (req)
  "Speak REQ, then ask for confirmation the ordinary way.

Speaking is the useful half when you are away from the keyboard; the
answer is still typed, because approval is a synchronous gate and
recording a spoken yes would block the editor -- under `--gowl' that is
the compositor."
  (cond
   ;; Nobody to ask: refuse, exactly as the built-in fallback would.
   (noninteractive nil)
   (t
    (when cmacs-brigade-voice-speak-approvals
      (cmacs-brigade-voice--say
       (format "%s wants to run %s."
               (or (plist-get req :agent) "An agent")
               (replace-regexp-in-string "_" " "
                                         (or (plist-get req :tool) "a tool")))))
    (yes-or-no-p (format "Agent %s wants to run %s.  Allow? "
                         (or (plist-get req :agent) "?")
                         (plist-get req :tool))))))

;;;###autoload
(defun cmacs-brigade-voice-setup-approvals ()
  "Have confirmation requests read aloud before they are asked.

Opt-in: put this in your init.  It registers an approval handler at a
late `:order', so a handler you register yourself still wins."
  (interactive)
  (cmacs-brigade-register-approval-handler
   :name 'voice
   :order 90
   :ask #'cmacs-brigade-voice--approve))


;;;; Dashboard integration

(defvar cmacs-brigade-voice-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "t") #'cmacs-brigade-voice-task)
    ;; The drafted counterpart of `t': same recording, but a model turns
    ;; what you said into a whole spec and you get a look at it before
    ;; anything is created.
    (define-key m (kbd "n") #'cmacs-brigade-compose-voice)
    (define-key m (kbd "q") #'cmacs-brigade-voice-ask)
    (define-key m (kbd "s") #'cmacs-brigade-voice-stop)
    (define-key m (kbd "?") #'cmacs-brigade-notify-status)
    m)
  "Voice commands, reached under `v' in the dashboard.")

;;;###autoload
(defun cmacs-brigade-voice-setup-dashboard (map)
  "Bind the voice prefix into dashboard keymap MAP."
  (define-key map (kbd "v") cmacs-brigade-voice-map))

(provide 'cmacs-brigade-voice)

;;; cmacs-brigade-voice.el ends here
