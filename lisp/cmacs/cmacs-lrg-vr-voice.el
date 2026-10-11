;;; cmacs-lrg-vr-voice.el --- Voice in VR: dictation and voice commands -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Push-to-talk for Emacs in a VR headset (`emacs --lrg=3dvr'), usable off
;; one too.  Hold a controller button, speak, let go:
;;
;;   hold A            dictate -- the words are typed where the cursor is
;;   hold Y            a voice command -- "new workspace", "save",
;;                     "switch to buffer notes", "split right", ...
;;
;; From a keyboard the same two are toggles:
;; \\[cmacs-lrg-vr-voice-dictate] and \\[cmacs-lrg-vr-voice-command].
;;
;; Audio is captured through cmacs-audio and transcribed offline by
;; whisper (`cmacs-whisper-transcribe-pcm-async', off the main thread).
;; A light above the controller shows the state: red listening, amber
;; transcribing.
;;
;; Voice commands are an ordered registry of regexps
;; (`cmacs-lrg-vr-voice-commands'); add your own with
;; `cmacs-lrg-vr-define-voice-command'.  Anything that matches none is
;; tried as a command name ("org agenda" -> `org-agenda'), and otherwise
;; opens M-x with the words already typed, to pick from with the laser.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-lrg-vr)

(declare-function cmacs-audio--capture-open-1 "cmacs-audio-defuns.c" (&rest plist))
(declare-function cmacs-audio-start "cmacs-audio-defuns.c" (handle))
(declare-function cmacs-audio-close "cmacs-audio-defuns.c" (handle))
(declare-function cmacs-audio-read-pcm "cmacs-audio-defuns.c" (handle n))
(declare-function cmacs-whisper-supported-p "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-transcribe-pcm-async "cmacs-whisper-defuns.c"
                  (model pcm callback &optional language threads))
(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(declare-function cmacs-whisper-download-model "cmacs-whisper" (model))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function term-send-raw-string "term" (chars))
(declare-function consult-line "consult" (&optional initial start))
(declare-function cmacs-lrg-vr-workspace-new "cmacs-lrg-vr-ui" (&optional name))
(declare-function cmacs-lrg-vr-workspace-next "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-workspace-previous "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-workspace-close "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-workspace-goto "cmacs-lrg-vr-ui" (which))
(declare-function cmacs-lrg-vr-workspace-overview "cmacs-lrg-vr-ui" (&optional arg))
(declare-function cmacs-lrg-vr-switch-buffer "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-find-file "cmacs-lrg-vr-ui" (&optional initial))
(declare-function cmacs-lrg-vr-recent-file "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-controller-help "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-quick-menu "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-undo "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-split-right "cmacs-lrg-vr-ui")
(declare-function cmacs-lrg-vr-split-below "cmacs-lrg-vr-ui")
(defvar cmacs-audio-default-rate)
(defvar cmacs-audio-capture-source)
(defvar cmacs-audio-default-device)
(defvar cmacs-whisper-language)
(defvar cmacs-whisper-default-model)
(defvar cmacs-whisper-dictate-command-words)

(defgroup cmacs-lrg-vr-voice nil
  "Push-to-talk dictation and voice commands, for VR and elsewhere."
  :group 'cmacs-lrg-vr
  :prefix "cmacs-lrg-vr-voice-")

(defcustom cmacs-lrg-vr-voice-max-seconds 60
  "Longest a push-to-talk recording runs before it stops on its own."
  :type 'number)

(defcustom cmacs-lrg-vr-voice-poll-seconds 0.25
  "How often captured audio is drained while recording."
  :type 'number)

(defcustom cmacs-lrg-vr-voice-threads nil
  "CPU threads whisper may use, or nil for all of them."
  :type '(choice (const :tag "All" nil) integer))

(defcustom cmacs-lrg-vr-voice-speak-feedback nil
  "Non-nil: say voice-command results aloud with piper, besides showing them."
  :type 'boolean)

(defcustom cmacs-lrg-vr-voice-capitalize t
  "Non-nil: dictation starting a sentence starts with a capital letter."
  :type 'boolean)

(defcustom cmacs-lrg-vr-voice-unmatched 'minibuffer
  "What a voice command that matches nothing does.
`minibuffer' opens M-x with the words typed, to pick from; `message'
just says it was not understood."
  :type '(choice (const minibuffer) (const message)))

(defface cmacs-lrg-vr-voice-heard
  '((t :inherit success :weight bold))
  "Face for what voice input heard, in the echo area.")


;;;; Availability

(defun cmacs-lrg-vr-voice-available-p ()
  "Non-nil when this build can record and transcribe speech."
  (and (fboundp 'cmacs-audio--capture-open-1)
       (fboundp 'cmacs-whisper-supported-p)
       (cmacs-whisper-supported-p)
       (or (fboundp 'cmacs-whisper-model-path)
           (require 'cmacs-whisper nil t))
       (or (boundp 'cmacs-audio-default-rate)
           (require 'cmacs-audio nil t))))

(defun cmacs-lrg-vr-voice--check ()
  "Signal a `user-error' saying what is missing for voice, if anything."
  (unless (cmacs-lrg-vr-voice-available-p)
    (user-error "Voice needs whisper and audio capture in this build"))
  (let ((model (cmacs-whisper-model-path)))
    (unless (file-exists-p model)
      (if (y-or-n-p (format "No speech model at %s.  Download %s (about 140 MB)? "
                            (abbreviate-file-name model)
                            cmacs-whisper-default-model))
          (progn
            (cmacs-whisper-download-model cmacs-whisper-default-model)
            (unless (file-exists-p (cmacs-whisper-model-path))
              (user-error "The speech model did not download")))
        (user-error "Voice needs a speech model: M-x cmacs-whisper-download-model")))))


;;;; Recording

(defvar cmacs-lrg-vr-voice--handle nil "The capture handle while recording.")
(defvar cmacs-lrg-vr-voice--timer nil)
(defvar cmacs-lrg-vr-voice--chunks nil)
(defvar cmacs-lrg-vr-voice--started nil)
(defvar cmacs-lrg-vr-voice--purpose nil
  "What the current recording is for: `dictate' or `command'.")
(defvar cmacs-lrg-vr-voice--callback nil)
(defvar cmacs-lrg-vr-voice--hand nil
  "The controller whose light shows the voice state.")
(defvar cmacs-lrg-vr-voice--busy nil
  "Non-nil while a transcription is running.")

(defun cmacs-lrg-vr-voice-recording-p ()
  "Non-nil while push-to-talk is recording."
  (and cmacs-lrg-vr-voice--handle t))

(defun cmacs-lrg-vr-voice--light (color)
  "Set the voice light to COLOR (\"#RRGGBB\") or off (nil)."
  (when (and cmacs-lrg-vr-voice--hand (cmacs-lrg-vr-active-now-p)
             (fboundp 'cmacs-lrg-vr-set-indicator))
    (ignore-errors
      (cmacs-lrg-vr-set-indicator cmacs-lrg-vr-voice--hand color))))

(defun cmacs-lrg-vr-voice--buzz (seconds amplitude)
  "Pulse the voice controller, when there is one."
  (when (and cmacs-lrg-vr-voice--hand (cmacs-lrg-vr-active-now-p)
             (bound-and-true-p cmacs-lrg-vr-haptics))
    (ignore-errors
      (cmacs-lrg-vr-haptic cmacs-lrg-vr-voice--hand seconds amplitude))))

(defun cmacs-lrg-vr-voice--drain ()
  "Move whatever the capture has buffered into the accumulator."
  (when cmacs-lrg-vr-voice--handle
    ;; Ask for several polls' worth: read-pcm drains *up to* this many.
    (let ((pcm (ignore-errors
                 (cmacs-audio-read-pcm cmacs-lrg-vr-voice--handle
                                       (* cmacs-audio-default-rate 2)))))
      (when (and pcm (> (length pcm) 0))
        (push pcm cmacs-lrg-vr-voice--chunks)))
    (when (> (- (float-time) cmacs-lrg-vr-voice--started)
             cmacs-lrg-vr-voice-max-seconds)
      (message "Voice: stopped after %ds" cmacs-lrg-vr-voice-max-seconds)
      (cmacs-lrg-vr-voice-stop))))

(defun cmacs-lrg-vr-voice-start (purpose callback &optional hand)
  "Start recording speech for PURPOSE; CALLBACK gets the text later.
PURPOSE is `dictate' or `command', for the messages.  HAND (`left' or
`right') is the controller that lights up.  Recording runs until
`cmacs-lrg-vr-voice-stop'; CALLBACK runs after transcription, with the
text, from the command loop (`cmacs-lrg-vr-run-later')."
  (cmacs-lrg-vr-voice--check)
  (when (cmacs-lrg-vr-voice-recording-p)
    (cmacs-lrg-vr-voice-cancel))
  (setq cmacs-lrg-vr-voice--chunks nil
        cmacs-lrg-vr-voice--purpose purpose
        cmacs-lrg-vr-voice--callback callback
        cmacs-lrg-vr-voice--hand hand
        cmacs-lrg-vr-voice--started (float-time))
  (condition-case err
      (progn
        (setq cmacs-lrg-vr-voice--handle
              (cmacs-audio--capture-open-1
               :source cmacs-audio-capture-source
               :rate cmacs-audio-default-rate
               :channels 1
               :device cmacs-audio-default-device))
        (cmacs-audio-start cmacs-lrg-vr-voice--handle))
    (error
     (when cmacs-lrg-vr-voice--handle
       (ignore-errors (cmacs-audio-close cmacs-lrg-vr-voice--handle)))
     (setq cmacs-lrg-vr-voice--handle nil)
     (user-error "Voice: could not open the microphone: %s"
                 (error-message-string err))))
  (setq cmacs-lrg-vr-voice--timer
        (run-with-timer cmacs-lrg-vr-voice-poll-seconds
                        cmacs-lrg-vr-voice-poll-seconds
                        #'cmacs-lrg-vr-voice--drain))
  (cmacs-lrg-vr-voice--light "#ff3030")
  (cmacs-lrg-vr-voice--buzz 0.04 0.6)
  (message "%s" (propertize (if (eq purpose 'dictate)
                                "Listening -- dictation..."
                              "Listening -- say a command...")
                            'face 'cmacs-lrg-vr-voice-heard)))

(defun cmacs-lrg-vr-voice--clean (text)
  "Whisper's TEXT without its annotations, trimmed and single-spaced."
  (let ((s (replace-regexp-in-string
            "\\[[^]]*\\]\\|([^)]*)\\|\\*[^*]*\\*" " " (or text ""))))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " s))))

(defun cmacs-lrg-vr-voice--finish (callback)
  "Turn the voice light off and hand back a transcription to CALLBACK."
  (lambda (result)
    (setq cmacs-lrg-vr-voice--busy nil)
    (cmacs-lrg-vr-voice--light nil)
    (let ((err (cdr (assq :error result)))
          (text (cmacs-lrg-vr-voice--clean (cdr (assq :text result)))))
      (cond
       (err (message "Voice: %s" err))
       ((string-empty-p text)
        (cmacs-lrg-vr-voice--buzz 0.02 0.2)
        (message "Voice: heard nothing"))
       (t
        (cmacs-lrg-vr-voice--buzz 0.02 0.4)
        (cmacs-lrg-vr-run-later (lambda () (funcall callback text))))))))

(defun cmacs-lrg-vr-voice-stop ()
  "Stop recording and transcribe what was said."
  (interactive)
  (unless (cmacs-lrg-vr-voice-recording-p)
    (user-error "Voice: not recording"))
  (when cmacs-lrg-vr-voice--timer
    (cancel-timer cmacs-lrg-vr-voice--timer)
    (setq cmacs-lrg-vr-voice--timer nil))
  (cmacs-lrg-vr-voice--drain)
  (let ((pcm (apply #'concat (nreverse cmacs-lrg-vr-voice--chunks)))
        (cb cmacs-lrg-vr-voice--callback))
    (ignore-errors (cmacs-audio-close cmacs-lrg-vr-voice--handle))
    (setq cmacs-lrg-vr-voice--handle nil
          cmacs-lrg-vr-voice--chunks nil
          cmacs-lrg-vr-voice--callback nil)
    ;; Under ~0.25 s of 16-bit mono: a brush of the button, not speech.
    (if (< (length pcm) (* cmacs-audio-default-rate 2 0.25))
        (progn
          (cmacs-lrg-vr-voice--light nil)
          (message "Voice: too short -- hold the button while you speak"))
      (setq cmacs-lrg-vr-voice--busy t)
      (cmacs-lrg-vr-voice--light "#ffb020")
      (message "Voice: transcribing...")
      (cmacs-whisper-transcribe-pcm-async
       (cmacs-whisper-model-path) pcm
       (cmacs-lrg-vr-voice--finish cb)
       cmacs-whisper-language cmacs-lrg-vr-voice-threads))))

(defun cmacs-lrg-vr-voice-cancel ()
  "Stop recording and throw the audio away."
  (interactive)
  (when cmacs-lrg-vr-voice--timer
    (cancel-timer cmacs-lrg-vr-voice--timer)
    (setq cmacs-lrg-vr-voice--timer nil))
  (when cmacs-lrg-vr-voice--handle
    (ignore-errors (cmacs-audio-close cmacs-lrg-vr-voice--handle)))
  (setq cmacs-lrg-vr-voice--handle nil
        cmacs-lrg-vr-voice--chunks nil
        cmacs-lrg-vr-voice--callback nil)
  (cmacs-lrg-vr-voice--light nil))

(defun cmacs-lrg-vr-voice--hand-of-event ()
  "The controller that sent the current command's event, if one did."
  (let ((base (and (symbolp (event-basic-type last-command-event))
                   (symbol-name (event-basic-type last-command-event)))))
    (cond ((null base) (and (cmacs-lrg-vr-active-now-p) 'right))
          ((string-match-p "\\`vr-\\(?:left\\|dpad\\|view\\)" base) 'left)
          (t 'right))))


;;;; Dictation

(defun cmacs-lrg-vr-voice--target ()
  "Where dictated text goes: the selected window's buffer at point."
  (list (selected-window) (current-buffer) (point-marker)
        (minibufferp)))

(defun cmacs-lrg-vr-voice--spaced (text buffer pos)
  "TEXT made to fit at POS in BUFFER: a space before it, a capital if due."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let* ((before (char-before))
             (after (char-after))
             (sentence-start
              (save-excursion
                (skip-chars-backward " \t")
                (or (bobp) (bolp)
                    (memq (char-before) '(?. ?! ?? ?\n)))))
             (out text))
        (when (and cmacs-lrg-vr-voice-capitalize sentence-start
                   (not (minibufferp)))
          (setq out (concat (upcase (substring out 0 1)) (substring out 1))))
        (when (and before (not (memq before '(?\s ?\t ?\n ?\( ?\[ ?\{ ?\" ?')))
                   (not (string-match-p "\\`[[:punct:]]" out)))
          (setq out (concat " " out)))
        (when (and after (memq (char-syntax after) '(?w ?_)))
          (setq out (concat out " ")))
        out))))

(defun cmacs-lrg-vr-voice-insert (text &optional target)
  "Type TEXT where TARGET says, else at point.
TARGET is (WINDOW BUFFER MARKER MINIBUFFERP) as `cmacs-lrg-vr-voice--target'
makes it.  A terminal buffer gets TEXT sent to its process; a read-only
one gets it on the kill ring instead."
  (require 'cmacs-whisper-dictate nil t)
  (pcase-let* ((`(,win ,buf ,marker ,_mini)
                (or target (cmacs-lrg-vr-voice--target)))
               (cmd (and (boundp 'cmacs-whisper-dictate-command-words)
                         (assoc-string (downcase (string-trim text ".,!? "))
                                       cmacs-whisper-dictate-command-words t))))
    (unless (buffer-live-p buf)
      (setq buf (current-buffer) marker (point-marker)))
    (with-current-buffer buf
      (cond
       ;; "new line", "period", ... -- the dictation phrase list.
       (cmd (save-excursion
              (goto-char marker)
              (funcall (cdr cmd))))
       ((derived-mode-p 'vterm-mode)
        (vterm-send-string text))
       ((and (derived-mode-p 'term-mode) (get-buffer-process buf))
        (term-send-raw-string text))
       ((and buffer-read-only (not (minibufferp)))
        (kill-new text)
        (message "Read-only buffer: copied %S" text))
       (t
        (let* ((out (cmacs-lrg-vr-voice--spaced text buf marker))
               (point-there (= (point) marker))
               (window-there (and (window-live-p win)
                                  (eq (window-buffer win) buf)
                                  (= (window-point win) marker))))
          (save-excursion
            (goto-char marker)
            (insert out)
            (set-marker marker (point)))
          ;; Point follows the text when it was where the text went, in
          ;; the buffer and in the window showing it.
          (when point-there
            (goto-char marker))
          (when window-there
            (set-window-point win marker))
          (message "%s" (propertize out 'face 'cmacs-lrg-vr-voice-heard))))))))

;;;###autoload
(defun cmacs-lrg-vr-voice-dictate-hold ()
  "Push-to-talk dictation: speak while the button is held.
On release the words are typed where the cursor was when you pressed.
Bound to holding A in VR.  Off a controller, toggles like
\\[cmacs-lrg-vr-voice-dictate]."
  (interactive)
  (if (cmacs-lrg-vr-voice-recording-p)
      (cmacs-lrg-vr-voice-stop)
    (let ((target (cmacs-lrg-vr-voice--target)))
      (cmacs-lrg-vr-voice-start
       'dictate (lambda (text) (cmacs-lrg-vr-voice-insert text target))
       (cmacs-lrg-vr-voice--hand-of-event))
      (cmacs-lrg-vr-on-release #'cmacs-lrg-vr-voice--release))))

;;;###autoload
(defun cmacs-lrg-vr-voice-dictate ()
  "Start dictating; run again to stop and type what was said at point."
  (interactive)
  (cmacs-lrg-vr-voice-dictate-hold))

(defun cmacs-lrg-vr-voice--release ()
  "A push-to-talk button was let go: stop and transcribe."
  (when (cmacs-lrg-vr-voice-recording-p)
    (cmacs-lrg-vr-voice-stop)))


;;;; Voice commands

(defvar cmacs-lrg-vr-voice-commands nil
  "Voice commands: a list of (REGEXP FUNCTION DOC), tried in order.
The spoken text is lower-cased, its punctuation removed and number words
turned into digits (\"workspace two\" -> \"workspace 2\") before it is
matched against each REGEXP, whole.  FUNCTION is called, as a command
\(from the command loop), with the regexp's groups as string arguments
\(nil for a group that did not match).  DOC is shown by
\\[cmacs-lrg-vr-voice-help].  Add your own with
`cmacs-lrg-vr-define-voice-command'.")

(defun cmacs-lrg-vr-define-voice-command (regexp function &optional doc append)
  "Add a voice command: speech matching REGEXP calls FUNCTION.
FUNCTION gets REGEXP's groups as arguments.  New commands are tried
before the shipped ones unless APPEND.  DOC is a short description
\(\"new workspace [called NAME]\").  A REGEXP already defined is replaced."
  (setq cmacs-lrg-vr-voice-commands
        (cl-remove regexp cmacs-lrg-vr-voice-commands
                   :key #'car :test #'equal))
  (let ((entry (list regexp function doc)))
    (setq cmacs-lrg-vr-voice-commands
          (if append
              (append cmacs-lrg-vr-voice-commands (list entry))
            (cons entry cmacs-lrg-vr-voice-commands))))
  regexp)

(defconst cmacs-lrg-vr-voice--numbers
  '(("zero" . 0) ("one" . 1) ("won" . 1) ("two" . 2) ("to" . 2) ("too" . 2)
    ("three" . 3) ("four" . 4) ("for" . 4) ("five" . 5) ("six" . 6)
    ("seven" . 7) ("eight" . 8) ("nine" . 9) ("ten" . 10) ("eleven" . 11)
    ("twelve" . 12) ("first" . 1) ("second" . 2) ("third" . 3)
    ("fourth" . 4) ("fifth" . 5))
  "Spoken numbers and their values, for workspace and line numbers.")

(defun cmacs-lrg-vr-voice--normalize (text)
  "TEXT lower-cased, without punctuation, with number words as digits.
Number words become digits only after \"workspace\", \"line\" or
\"number\", where a number is expected: \"open two files\" stays put."
  (let* ((s (downcase text))
         (s (replace-regexp-in-string "[^[:alnum:] '._/-]" " " s))
         (s (replace-regexp-in-string "\\.\\'\\|\\. " " " s))
         (s (string-trim (replace-regexp-in-string "[ \t]+" " " s))))
    (replace-regexp-in-string
     "\\(\\(?:workspace\\|line\\|number\\|tab\\) \\)\\([a-z]+\\)\\b"
     (lambda (m)
       (let ((n (assoc (match-string 2 m) cmacs-lrg-vr-voice--numbers)))
         (if n
             (concat (match-string 1 m) (number-to-string (cdr n)))
           m)))
     s t t)))

(defun cmacs-lrg-vr-voice--say (fmt &rest args)
  "Show FMT with ARGS, and speak it when `cmacs-lrg-vr-voice-speak-feedback'."
  (let ((msg (apply #'format fmt args)))
    (message "%s" (propertize msg 'face 'cmacs-lrg-vr-voice-heard))
    (when (and cmacs-lrg-vr-voice-speak-feedback
               (fboundp 'cmacs-piper-speak-async))
      (ignore-errors (cmacs-piper-speak-async msg)))
    msg))

(defun cmacs-lrg-vr-voice--command-name (words)
  "The command WORDS name (\"org agenda\" -> `org-agenda'), or nil."
  (let ((sym (intern-soft (replace-regexp-in-string " " "-" words))))
    (and sym (commandp sym) sym)))

(defun cmacs-lrg-vr-voice-run (text)
  "Do what the spoken TEXT says: a voice command, a command name, or M-x.
Returns the function run, or nil."
  (let ((s (cmacs-lrg-vr-voice--normalize text))
        (case-fold-search t))
    (catch 'done
      (pcase-dolist (`(,re ,fn ,_doc) cmacs-lrg-vr-voice-commands)
        (when (string-match (concat "\\`\\(?:" re "\\)\\'") s)
          (let ((args (cl-loop for i from 1 to (regexp-opt-depth re)
                               collect (match-string i s))))
            (cmacs-lrg-vr-voice--say "\"%s\"" text)
            (apply fn args)
            (throw 'done fn))))
      (let ((cmd (cmacs-lrg-vr-voice--command-name s)))
        (when cmd
          (cmacs-lrg-vr-voice--say "\"%s\" -> %s" text cmd)
          (setq this-command cmd)
          (call-interactively cmd)
          (throw 'done cmd)))
      (if (eq cmacs-lrg-vr-voice-unmatched 'minibuffer)
          (progn
            (cmacs-lrg-vr-voice--say "\"%s\" -- pick a command" text)
            (minibuffer-with-setup-hook
                (lambda () (insert (replace-regexp-in-string " " "-" s)))
              (call-interactively #'execute-extended-command)))
        (cmacs-lrg-vr-voice--say "Didn't understand \"%s\"" text))
      nil)))

;;;###autoload
(defun cmacs-lrg-vr-voice-command-hold ()
  "Push-to-talk voice command: speak while the button is held.
Bound to holding Y in VR.  \\[cmacs-lrg-vr-voice-help] lists what is
understood.  Off a controller, toggles like \\[cmacs-lrg-vr-voice-command]."
  (interactive)
  (if (cmacs-lrg-vr-voice-recording-p)
      (cmacs-lrg-vr-voice-stop)
    (cmacs-lrg-vr-voice-start 'command #'cmacs-lrg-vr-voice-run
                              (cmacs-lrg-vr-voice--hand-of-event))
    (cmacs-lrg-vr-on-release #'cmacs-lrg-vr-voice--release)))

;;;###autoload
(defun cmacs-lrg-vr-voice-command ()
  "Start listening for a voice command; run again to stop and do it."
  (interactive)
  (cmacs-lrg-vr-voice-command-hold))

;;;###autoload
(defun cmacs-lrg-vr-voice-help ()
  "List the voice commands."
  (interactive)
  (with-help-window "*VR Voice Commands*"
    (princ "Voice commands (hold Y in VR, or C-c v SPC):\n\n")
    (pcase-dolist (`(,_re ,fn ,doc) cmacs-lrg-vr-voice-commands)
      (princ (format "  %-38s %s\n" (or doc "") fn)))
    (princ "\nAnything else is tried as a command name (\"org agenda\"),\n")
    (princ "then opens M-x with the words typed.\n\n")
    (princ "Dictation (hold A, or C-c v i) types at the cursor; say\n")
    (princ "\"new line\", \"period\" etc. on their own for those.\n")))


;;;; The shipped voice commands

(defun cmacs-lrg-vr-voice--do (command)
  "A voice-command function that runs COMMAND interactively."
  (lambda (&rest _) (call-interactively command)))

(defun cmacs-lrg-vr-voice--scroll (dir)
  (lambda (&rest _)
    (condition-case nil
        (if (eq dir 'down) (scroll-up-command) (scroll-down-command))
      ((beginning-of-buffer end-of-buffer) nil))))

(defun cmacs-lrg-vr-voice--search (string)
  "Search for STRING: `consult-line' when there is one, else isearch."
  (if (fboundp 'consult-line)
      (consult-line string)
    (isearch-forward nil t)
    (isearch-yank-string string)))

(defun cmacs-lrg-vr-voice--buffer (name)
  "Switch to the buffer whose name best matches the spoken NAME."
  (let* ((words (split-string name))
         (cands (cl-remove-if
                 (lambda (b) (string-prefix-p " " (buffer-name b)))
                 (buffer-list)))
         (hit (or (cl-find name cands :key #'buffer-name :test #'string-equal-ignore-case)
                  (cl-find-if (lambda (b)
                                (let ((bn (downcase (buffer-name b))))
                                  (cl-every (lambda (w) (string-search w bn)) words)))
                              cands))))
    (if hit
        (switch-to-buffer hit)
      (minibuffer-with-setup-hook (lambda () (insert name))
        (call-interactively #'cmacs-lrg-vr-switch-buffer)))))

(defun cmacs-lrg-vr-voice--define-defaults ()
  "Install the shipped voice commands (after any the user added)."
  (dolist (c
           `(;; Workspaces
             ("\\(?:new\\|create\\|make\\|open a new\\) workspace\\(?: \\(?:called\\|named\\) \\(.+\\)\\)?"
              ,(lambda (name) (cmacs-lrg-vr-workspace-new name))
              "new workspace [called NAME]")
             ("\\(?:next\\|forward\\) workspace" ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-workspace-next)
              "next workspace")
             ("\\(?:previous\\|last\\|back\\|prior\\) workspace"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-workspace-previous) "previous workspace")
             ("\\(?:close\\|kill\\|delete\\) \\(?:this \\)?workspace"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-workspace-close) "close workspace")
             ("\\(?:go to\\|switch to\\|open\\|show\\) workspace \\(.+\\)"
              ,(lambda (which) (cmacs-lrg-vr-workspace-goto which))
              "go to workspace N / NAME")
             ("workspace \\([0-9]+\\)"
              ,(lambda (which) (cmacs-lrg-vr-workspace-goto which)) "workspace N")
             ("\\(?:show \\)?\\(?:all \\)?workspaces\\|overview\\|show overview"
              ,(lambda (&rest _) (cmacs-lrg-vr-workspace-overview 1)) "workspaces / overview")
             ("\\(?:close\\|hide\\|exit\\) overview\\|back to work"
              ,(lambda (&rest _) (cmacs-lrg-vr-workspace-overview -1)) "close overview")
             ;; Buffers and files
             ("\\(?:switch to\\|go to\\|show\\)\\(?: the\\)? buffer \\(.+\\)\\|buffer \\(.+\\)"
              ,(lambda (a b) (cmacs-lrg-vr-voice--buffer (or a b))) "buffer NAME")
             ("\\(?:switch\\|change\\) buffers?\\|buffers"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-switch-buffer) "switch buffer")
             ("\\(?:open\\|find\\) file\\(?: \\(.+\\)\\)?"
              ,(lambda (name) (cmacs-lrg-vr-find-file name)) "open file [NAME]")
             ("\\(?:open \\)?recent\\(?: files?\\)?"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-recent-file) "recent files")
             ("save all\\(?: files\\| buffers\\)?"
              ,(lambda (&rest _) (save-some-buffers t)) "save all")
             ("save\\(?: \\(?:file\\|buffer\\|this\\)\\)?"
              ,(cmacs-lrg-vr-voice--do 'save-buffer) "save")
             ("\\(?:kill\\|close\\) \\(?:this \\)?buffer"
              ,(lambda (&rest _) (kill-buffer (current-buffer))) "close buffer")
             ;; Editing
             ("undo\\(?: that\\)?" ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-undo) "undo")
             ("redo" ,(lambda (&rest _)
                        (call-interactively (if (fboundp 'evil-redo) 'evil-redo
                                              (if (fboundp 'undo-redo) 'undo-redo 'undo))))
              "redo")
             ("\\(?:type\\|insert\\|write\\) \\(.+\\)"
              ,(lambda (text) (cmacs-lrg-vr-voice-insert text)) "type TEXT")
             ("\\(?:search\\|find\\)\\(?: for\\)? \\(.+\\)"
              ,#'cmacs-lrg-vr-voice--search "search for TEXT")
             ("\\(?:go to \\)?line \\([0-9]+\\)"
              ,(lambda (n) (goto-char (point-min)) (forward-line (1- (string-to-number n))))
              "go to line N")
             ("\\(?:go to \\)?\\(?:the \\)?\\(?:top\\|beginning\\|start\\)\\(?: of \\(?:the \\)?\\(?:buffer\\|file\\)\\)?"
              ,(lambda (&rest _) (push-mark) (goto-char (point-min))) "top")
             ("\\(?:go to \\)?\\(?:the \\)?\\(?:bottom\\|end\\)\\(?: of \\(?:the \\)?\\(?:buffer\\|file\\)\\)?"
              ,(lambda (&rest _) (push-mark) (goto-char (point-max))) "bottom")
             ("\\(?:page\\|scroll\\) down" ,(cmacs-lrg-vr-voice--scroll 'down) "scroll down")
             ("\\(?:page\\|scroll\\) up" ,(cmacs-lrg-vr-voice--scroll 'up) "scroll up")
             ;; Windows
             ("split\\(?: \\(?:the \\)?window\\)? \\(?:right\\|vertically\\|side by side\\)"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-split-right) "split right")
             ("split\\(?: \\(?:the \\)?window\\)?\\(?: \\(?:below\\|down\\|horizontally\\)\\)?"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-split-below) "split [below]")
             ("\\(?:close\\|delete\\) \\(?:this \\)?window"
              ,(cmacs-lrg-vr-voice--do 'delete-window) "close window")
             ("\\(?:only\\|maximize\\|maximise\\|one\\) window\\|maximi[sz]e\\|full screen"
              ,(cmacs-lrg-vr-voice--do 'delete-other-windows) "maximize window")
             ("\\(?:other\\|next\\|switch\\) window" ,(cmacs-lrg-vr-voice--do 'other-window)
              "other window")
             ;; The VR view
             ("\\(?:\\(?:show\\|hide\\|toggle\\) \\)?\\(?:the \\)?keyboard"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-toggle-keyboard) "keyboard")
             ("\\(?:re-?\\)?cent\\(?:er\\|re\\)\\(?: \\(?:the \\)?view\\)?\\|in front of me"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-recenter-view) "recenter")
             ("reset\\(?: the\\)? view" ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-reset-view) "reset view")
             ("\\(?:make it \\)?\\(?:bigger\\|larger\\)" ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-bigger)
              "bigger (the world)")
             ("\\(?:make it \\)?smaller" ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-smaller)
              "smaller (the world)")
             ("\\(?:text \\)?\\(?:zoom in\\|bigger text\\|larger text\\)"
              ,(lambda (&rest _) (text-scale-increase 1)) "zoom in (text)")
             ("\\(?:text \\)?\\(?:zoom out\\|smaller text\\)"
              ,(lambda (&rest _) (text-scale-decrease 1)) "zoom out (text)")
             ("\\(?:quick \\)?menu" ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-quick-menu) "menu")
             ("\\(?:help\\|controls\\|controller help\\|what can i \\(?:say\\|do\\)\\)"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-controller-help) "help / what can I say")
             ;; Getting out
             ("\\(?:cancel\\|never ?mind\\|escape\\|quit\\|stop\\)"
              ,(cmacs-lrg-vr-voice--do 'cmacs-lrg-vr-escape) "cancel")
             ("\\(?:run\\|execute\\|command\\|m ?x\\|meta x\\) \\(.+\\)"
              ,(lambda (words)
                 (let ((cmd (cmacs-lrg-vr-voice--command-name words)))
                   (if cmd
                       (call-interactively cmd)
                     (minibuffer-with-setup-hook
                         (lambda () (insert (replace-regexp-in-string " " "-" words)))
                       (call-interactively #'execute-extended-command)))))
              "run COMMAND NAME")))
    (cmacs-lrg-vr-define-voice-command (nth 0 c) (nth 1 c) (nth 2 c) t)))

(cmacs-lrg-vr-voice--define-defaults)

(provide 'cmacs-lrg-vr-voice)

;;; cmacs-lrg-vr-voice.el ends here
