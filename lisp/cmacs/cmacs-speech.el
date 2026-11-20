;;; cmacs-speech.el --- one speech API over whisper, sherpa-onnx and piper  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; Author: Zach Podbielniak
;; Keywords: multimedia, speech, cmacs

;;; Commentary:

;; cmacs has more than one speech engine: whisper.cpp (speech to text,
;; Silero VAD), piper (text to speech) and sherpa-onnx (all of those plus
;; streaming recognition, keyword spotting, diarization, speaker ID,
;; punctuation, language ID, audio tagging, denoising and source
;; separation).  This file is the one place that decides which engine
;; and which model does a job, so that no feature names an engine.
;;
;; Vocabulary:
;;
;;   COMPONENT  a capability: `stt', `stt-live', `stt-stream', `wake',
;;              `vad', `tts', `diarize', `speaker-id', `punctuate',
;;              `lang-id', `audio-tag', `denoise', `separate'.
;;   FEATURE    a consumer: `voice-loop', `dictate', `transcribe', ...
;;              A feature uses the setting of its component unless it
;;              has a setting of its own.
;;   BACKEND    an engine adapter registered with
;;              `cmacs-speech-define-backend' (`whisper', `sherpa',
;;              `piper' ship with cmacs).
;;
;; Where a choice comes from, highest first:
;;
;;   1. `cmacs-speech-with-config' around a call (programmatic, scoped);
;;   2. a session override made in the settings buffer (never saved);
;;   3. init.el: `cmacs-speech-config' / `cmacs-speech-set';
;;   4. the settings buffer's state file (`cmacs-speech-state-file');
;;   5. `auto': the first backend in `cmacs-speech-auto-preference' that
;;      is built in and has a model installed.
;;
;; A feature-specific entry beats a component-wide one wherever it is
;; set, so "dictate uses sherpa" in the settings buffer is honoured even
;; when init.el sets the `stt' default; anything init.el names
;; explicitly always wins over the buffer.  `cmacs-speech-resolve'
;; reports which layer answered (`:source'), and so does every row of
;; `M-x cmacs-speech'.
;;
;;   (cmacs-speech-set 'tts 'sherpa :model "kokoro-en-v0_19" :speaker 3)
;;   (cmacs-speech-set 'stt-live 'sherpa :model "moonshine-base-en" :feature 'dictate)
;;   (cmacs-speech-with-config '((tts piper :model "en_GB-alan-low.onnx"))
;;     (cmacs-speech-speak "Cheerio"))

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-speech nil
  "Choose the speech engine and model for every cmacs speech feature."
  :group 'cmacs
  :prefix "cmacs-speech-")

;;;; Components and features

(defconst cmacs-speech-components
  '((stt        "Speech to text"        "Files and recordings: transcribe, ingest, MCP")
    (stt-live   "Live speech to text"   "Push-to-talk utterances: voice loop, commands, AI voice")
    (stt-stream "Streaming recognition" "Words as you speak: dictation, voice-loop partials")
    (wake       "Wake word"             "Always-on keyword spotting")
    (vad        "Voice activity"        "When speech starts and stops")
    (tts        "Text to speech"        "Every voice cmacs speaks with")
    (diarize    "Who spoke when"        "Speaker turns in a recording")
    (speaker-id "Speaker identity"      "Enrolled voices, \"is this me?\"")
    (punctuate  "Punctuation"           "Punctuation and casing for raw text")
    (lang-id    "Language ID"           "Which language is being spoken")
    (audio-tag  "Sound tagging"         "Speech, music, a dog, a doorbell")
    (denoise    "Denoise"               "Speech enhancement")
    (separate   "Separate"              "Vocals from accompaniment"))
  "Speech components: (SYMBOL LABEL DESCRIPTION).")

(defconst cmacs-speech-features
  '((voice-loop     "Voice loop"        (wake vad stt-live stt-stream tts speaker-id))
    (dictate        "Dictation"         (stt-stream stt-live vad punctuate))
    (voice-commands "Voice commands"    (stt-live tts))
    (ai-voice       "AI voice chat"     (stt-live tts))
    (brigade        "Brigade voice"     (stt-live tts))
    (vr             "VR voice"          (stt-live tts))
    (gowl-macro     "Macro voice match" (stt-live))
    (transcribe     "Batch transcribe"  (stt diarize punctuate lang-id denoise))
    (secondbrain    "Second-brain ingest" (stt audio-tag))
    (meeting        "Meeting recorder"  (stt diarize))
    (libreclaw      "libreclaw chat"    (stt-live))
    (audio-org      "#+BEGIN_AUDIO"     (stt))
    (rpc            "MCP / D-Bus / emacsctl" (stt tts diarize))
    (reader         "Read aloud"        (tts)))
  "Speech features: (SYMBOL LABEL COMPONENTS-IT-USES).")

(defun cmacs-speech-component-label (component)
  "Human label of COMPONENT."
  (or (nth 1 (assq component cmacs-speech-components))
      (symbol-name component)))

(defun cmacs-speech-feature-label (feature)
  "Human label of FEATURE."
  (or (nth 1 (assq feature cmacs-speech-features))
      (symbol-name feature)))

;;;; Where models live

(defcustom cmacs-speech-models-directory
  (expand-file-name "cmacs/speech-models"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Root of the speech model store: one subdirectory per backend.
Downloads land in <root>/whisper/, <root>/piper/ and <root>/sherpa/<id>/.
The older ~/.local/share/cmacs/whisper-models/ and piper-voices/
directories, and the system copies under /usr/share/cmacs/, are still
searched."
  :type 'directory
  :group 'cmacs-speech)

(defcustom cmacs-speech-models-extra-directories nil
  "More model trees, laid out like `cmacs-speech-models-directory'.
Each is searched after the store for <dir>/whisper, <dir>/piper and
<dir>/sherpa models -- a shared drive, a project's own models, models
you trained.  Anything recognisable there shows up in \[cmacs-speech]."
  :type '(repeat directory)
  :group 'cmacs-speech)

(defcustom cmacs-speech-system-models-directory "/usr/share/cmacs/speech-models"
  "Read-only model tree an image build ships, searched last."
  :type 'directory
  :group 'cmacs-speech)

(defun cmacs-speech-model-dirs (backend)
  "Directories holding BACKEND's models, in search order (store first)."
  (let ((name (symbol-name backend)))
    (mapcar (lambda (root) (file-name-as-directory (expand-file-name name root)))
            (append (list cmacs-speech-models-directory)
                    cmacs-speech-models-extra-directories
                    (list cmacs-speech-system-models-directory)))))

;;;; Backends

(defvar cmacs-speech--backends (make-hash-table :test 'eq)
  "Backend NAME -> plist, see `cmacs-speech-define-backend'.")

(defvar cmacs-speech-backend-order nil
  "Backend names in registration order.")

(defun cmacs-speech-define-backend (name &rest plist)
  "Register speech backend NAME with PLIST.
Keys:
  :label           a short display name
  :components      components it can serve
  :available-p     (lambda (COMPONENT)) non-nil when usable now
  :models          (lambda (COMPONENT)) installed model ids
  :default-model   (lambda (COMPONENT)) the model `auto' uses, or nil
  :describe        (lambda ()) one line: version, runtime
  :transcribe      (lambda (R PCM RATE CALLBACK))       stt, stt-live
  :stream-open     (lambda (R ON-RESULT)) -> stream      stt-stream
  :stream-feed     (lambda (STREAM PCM))
  :stream-finish   (lambda (STREAM))
  :stream-close    (lambda (STREAM))
  :wake-open       (lambda (R PHRASES ON-HIT)) -> object  wake
  :wake-feed       (lambda (OBJ PCM))
  :wake-close      (lambda (OBJ))
  :vad-open        (lambda (R)) -> object                 vad
  :vad-feed        (lambda (OBJ PCM CALLBACK))   CALLBACK gets PROBS
  :vad-close       (lambda (OBJ))
  :synthesize      (lambda (R TEXT CALLBACK CHUNK-FN)) -> token   tts
  :cancel          (lambda (TOKEN))
  :run             (lambda (R COMPONENT INPUT CALLBACK CHUNK-FN))
                   for the analysis components
R is the plist `cmacs-speech-resolve' returns.  Re-registering a NAME
replaces it."
  (puthash name plist cmacs-speech--backends)
  (unless (memq name cmacs-speech-backend-order)
    (setq cmacs-speech-backend-order
          (append cmacs-speech-backend-order (list name))))
  name)

(defun cmacs-speech-backend (name)
  "The plist of backend NAME, or nil."
  (gethash name cmacs-speech--backends))

(defun cmacs-speech-backends (&optional component)
  "Registered backend names, those serving COMPONENT when given."
  (cl-remove-if-not
   (lambda (b)
     (or (null component)
         (memq component (plist-get (cmacs-speech-backend b) :components))))
   cmacs-speech-backend-order))

(defun cmacs-speech-backend-label (name)
  "Display label of backend NAME."
  (or (plist-get (cmacs-speech-backend name) :label) (symbol-name name)))

(defun cmacs-speech-backend-available-p (name component)
  "Non-nil when backend NAME can serve COMPONENT right now."
  (let ((b (cmacs-speech-backend name)))
    (and b (memq component (plist-get b :components))
         (let ((f (plist-get b :available-p)))
           (or (null f) (ignore-errors (funcall f component)))))))

(defun cmacs-speech-backend-models (name component)
  "Installed model ids backend NAME has for COMPONENT."
  (let ((f (plist-get (cmacs-speech-backend name) :models)))
    (and f (ignore-errors (funcall f component)))))

(defun cmacs-speech-backend-default-model (name component)
  "The model backend NAME uses for COMPONENT when none is named."
  (let ((f (plist-get (cmacs-speech-backend name) :default-model)))
    (and f (ignore-errors (funcall f component)))))

;;;; Configuration layers

(defcustom cmacs-speech-config nil
  "Speech choices made in init.el; they beat the settings buffer.
Each entry is (COMPONENT BACKEND . PLIST).  PLIST may hold :model, a
:feature the entry is limited to, and backend options (:speaker,
:speed, :language, :phrases, :threads, ...).  BACKEND `auto' picks by
`cmacs-speech-auto-preference'.  Prefer `cmacs-speech-set' to editing
this list by hand."
  :type '(repeat (cons (symbol :tag "Component")
                       (cons (symbol :tag "Backend")
                             (plist :tag "Options"))))
  :group 'cmacs-speech)

(defcustom cmacs-speech-auto-preference
  '((stt        whisper sherpa)
    (stt-live   whisper sherpa)
    (stt-stream sherpa)
    (wake       sherpa)
    (vad        whisper sherpa)
    (tts        sherpa piper)
    (diarize    sherpa)
    (speaker-id sherpa)
    (punctuate  sherpa)
    (lang-id    sherpa)
    (audio-tag  sherpa)
    (denoise    sherpa)
    (separate   sherpa))
  "Backends `auto' tries per component, best first.
A backend is chosen only when it is built in and has a model for the
component installed, so a fresh install keeps today's engines until a
sherpa model is downloaded."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'cmacs-speech)

(defcustom cmacs-speech-state-file
  (expand-file-name "speech.eld"
                    (if (boundp 'cmacs-config-directory)
                        cmacs-config-directory
                      (expand-file-name "cmacs" (or (getenv "XDG_CONFIG_HOME")
                                                    "~/.config"))))
  "Where the settings buffer saves its choices.
Entries here lose to `cmacs-speech-config' (init.el)."
  :type 'file
  :group 'cmacs-speech)

(defvar cmacs-speech-override nil
  "Entries that beat everything, bound by `cmacs-speech-with-config'.")

(defvar cmacs-speech--session nil
  "Session overrides made in the settings buffer; never saved.")

(defvar cmacs-speech--ui nil
  "Entries from `cmacs-speech-state-file'.")

(defvar cmacs-speech--ui-loaded nil
  "Non-nil once the state file has been read.")

(defvar cmacs-speech-config-changed-hook nil
  "Run after any speech choice changes (UI, session, `cmacs-speech-set').")

(defmacro cmacs-speech-with-config (entries &rest body)
  "Run BODY with speech ENTRIES taking precedence over everything.
ENTRIES has the shape of `cmacs-speech-config'."
  (declare (indent 1) (debug t))
  `(let ((cmacs-speech-override (append ,entries cmacs-speech-override)))
     ,@body))

(defun cmacs-speech--entry-key (entry)
  "(COMPONENT . FEATURE) identifying ENTRY."
  (cons (car entry) (plist-get (cddr entry) :feature)))

(defun cmacs-speech--put (entries component backend plist)
  "ENTRIES with (COMPONENT BACKEND . PLIST) replacing any same-keyed one."
  (let ((key (cons component (plist-get plist :feature))))
    (append (cl-remove-if (lambda (e) (equal (cmacs-speech--entry-key e) key))
                          entries)
            (list (cons component (cons backend plist))))))

(defun cmacs-speech--drop (entries component feature)
  "ENTRIES without the one keyed (COMPONENT . FEATURE)."
  (cl-remove-if (lambda (e) (equal (cmacs-speech--entry-key e)
                                   (cons component feature)))
                entries))

;;;###autoload
(defun cmacs-speech-set (component backend &rest plist)
  "Use BACKEND for speech COMPONENT; for init.el.
PLIST may give :model, :feature (limit to one feature), and backend
options.  Beats anything chosen in the settings buffer.

  (cmacs-speech-set \\='tts \\='sherpa :model \"kokoro-en-v0_19\" :speaker 3)"
  (unless (assq component cmacs-speech-components)
    (error "Unknown speech component: %S" component))
  (setq cmacs-speech-config
        (cmacs-speech--put cmacs-speech-config component backend plist))
  (run-hooks 'cmacs-speech-config-changed-hook)
  component)

(defun cmacs-speech-unset (component &optional feature)
  "Forget the init.el choice for COMPONENT (and FEATURE)."
  (setq cmacs-speech-config
        (cmacs-speech--drop cmacs-speech-config component feature))
  (run-hooks 'cmacs-speech-config-changed-hook))

;;;; The state file

(defun cmacs-speech--load-state ()
  "Read `cmacs-speech-state-file' once."
  (unless cmacs-speech--ui-loaded
    (setq cmacs-speech--ui-loaded t
          cmacs-speech--ui
          (when (file-readable-p cmacs-speech-state-file)
            (condition-case err
                (with-temp-buffer
                  (insert-file-contents cmacs-speech-state-file)
                  (let ((data (read (current-buffer))))
                    (alist-get 'entries data)))
              (error
               (message "cmacs-speech: ignoring unreadable %s: %s"
                        cmacs-speech-state-file (error-message-string err))
               nil))))))

(defun cmacs-speech--save-state ()
  "Write the settings buffer's entries to `cmacs-speech-state-file'."
  (make-directory (file-name-directory cmacs-speech-state-file) t)
  (let ((print-length nil) (print-level nil) (tmp (make-temp-name
                                                   (concat cmacs-speech-state-file ".tmp"))))
    (with-temp-file tmp
      (insert ";; -*- mode: lisp-data -*-\n"
              ";; Written by M-x cmacs-speech.  init.el's `cmacs-speech-config'\n"
              ";; and `cmacs-speech-set' always win over what is here.\n")
      (pp `((version . 1) (entries . ,cmacs-speech--ui)) (current-buffer)))
    ;; Rename over the old file, so a crash mid-write never leaves a
    ;; half-written state file that would then be ignored.
    (rename-file tmp cmacs-speech-state-file t)))

(defun cmacs-speech-ui-set (component backend &rest plist)
  "Record a settings-buffer choice and save it.
Returns non-nil; the choice is shadowed when init.el names the same
component and feature (see `cmacs-speech-init-owned-p')."
  (cmacs-speech--load-state)
  (setq cmacs-speech--ui (cmacs-speech--put cmacs-speech--ui component backend plist))
  (cmacs-speech--save-state)
  (run-hooks 'cmacs-speech-config-changed-hook)
  t)

(defun cmacs-speech-ui-unset (component &optional feature)
  "Forget the settings-buffer choice for COMPONENT (and FEATURE)."
  (cmacs-speech--load-state)
  (setq cmacs-speech--ui (cmacs-speech--drop cmacs-speech--ui component feature))
  (cmacs-speech--save-state)
  (run-hooks 'cmacs-speech-config-changed-hook))

(defun cmacs-speech-session-set (component backend &rest plist)
  "Override COMPONENT for this session only (nothing is saved)."
  (setq cmacs-speech--session
        (cmacs-speech--put cmacs-speech--session component backend plist))
  (run-hooks 'cmacs-speech-config-changed-hook))

(defun cmacs-speech-session-unset (component &optional feature)
  "Drop the session override for COMPONENT (and FEATURE)."
  (setq cmacs-speech--session
        (cmacs-speech--drop cmacs-speech--session component feature))
  (run-hooks 'cmacs-speech-config-changed-hook))

(defun cmacs-speech-init-owned-p (component &optional feature)
  "Non-nil when init.el sets COMPONENT (for FEATURE) itself."
  (cl-some (lambda (e) (equal (cmacs-speech--entry-key e) (cons component feature)))
           cmacs-speech-config))

;;;; Resolution

(defun cmacs-speech--layers ()
  "Configuration layers, highest first, as (SOURCE . ENTRIES)."
  (cmacs-speech--load-state)
  (list (cons 'override cmacs-speech-override)
        (cons 'session  cmacs-speech--session)
        (cons 'init     cmacs-speech-config)
        (cons 'ui       cmacs-speech--ui)))

(defun cmacs-speech--find (component feature)
  "First matching entry as (SOURCE . ENTRY).
A FEATURE entry in any layer beats a component-wide one in any layer."
  (let ((layers (cmacs-speech--layers)))
    (or (and feature
             (cl-loop for (source . entries) in layers
                      for e = (cl-find-if (lambda (e) (equal (cmacs-speech--entry-key e)
                                                             (cons component feature)))
                                          entries)
                      when e return (cons source e)))
        (cl-loop for (source . entries) in layers
                 for e = (cl-find-if (lambda (e) (equal (cmacs-speech--entry-key e)
                                                        (cons component nil)))
                                     entries)
                 when e return (cons source e)))))

(defun cmacs-speech--auto (component)
  "(BACKEND . MODEL) `auto' picks for COMPONENT, or nil."
  (cl-loop for b in (or (alist-get component cmacs-speech-auto-preference)
                        cmacs-speech-backend-order)
           for model = (and (cmacs-speech-backend-available-p b component)
                            (cmacs-speech-backend-default-model b component))
           when model return (cons b model)))

(defun cmacs-speech--strip (plist &rest keys)
  "PLIST without KEYS."
  (let (out)
    (while plist
      (unless (memq (car plist) keys)
        (setq out (plist-put out (car plist) (cadr plist))))
      (setq plist (cddr plist)))
    out))

(defun cmacs-speech-resolve (component &optional feature)
  "Which backend and model serve COMPONENT for FEATURE.
Returns a plist (:component :feature :backend :model :options :source),
where :source is `override', `session', `init', `ui' or `auto' (with
:auto t also when a configured entry said `auto').  :backend is nil
when nothing can serve the component."
  (let* ((hit (cmacs-speech--find component feature))
         (source (car hit))
         (entry (cdr hit))
         (backend (cadr entry))
         (plist (cddr entry))
         (model (plist-get plist :model))
         (auto nil))
    (when (or (null backend) (eq backend 'auto))
      (let ((pick (cmacs-speech--auto component)))
        (setq auto t
              backend (car pick)
              model (or model (cdr pick))
              source (or source 'auto))))
    (when (and backend (null model))
      (setq model (cmacs-speech-backend-default-model backend component)))
    (list :component component :feature feature :backend backend
          :model model :source source :auto auto
          :options (cmacs-speech--strip plist :model :feature))))

(defun cmacs-speech-option (resolved key &optional default)
  "Option KEY of RESOLVED (from `cmacs-speech-resolve'), or DEFAULT."
  (let ((opts (plist-get resolved :options)))
    (if (plist-member opts key) (plist-get opts key) default)))

(defun cmacs-speech--op (resolved op)
  "The function OP of RESOLVED's backend, or signal a clear error."
  (let* ((name (plist-get resolved :backend))
         (fn (plist-get (cmacs-speech-backend name) op)))
    (cond
     ((null name)
      (user-error "No speech engine can do %s; install a model with M-x cmacs-speech"
                  (cmacs-speech-component-label (plist-get resolved :component))))
     ((null fn)
      (user-error "The %s engine cannot do %s"
                  (cmacs-speech-backend-label name)
                  (cmacs-speech-component-label (plist-get resolved :component))))
     (t fn))))

(defun cmacs-speech-can-p (component &optional feature op)
  "Non-nil when COMPONENT for FEATURE resolves to a backend with OP."
  (let ((r (cmacs-speech-resolve component feature)))
    (and (plist-get r :backend)
         (or (null op) (plist-get (cmacs-speech-backend (plist-get r :backend)) op))
         r)))

;;;; Events

(defcustom cmacs-speech-event-functions nil
  "Abnormal hook run as (EVENT PLIST) when speech things happen.
EVENT is `transcription' (:text :feature :backend :model),
`keyword' (:keyword :feature), `speaker' (:name :score :feature),
`synthesis' (:text :feature :backend).  podomation's
on_transcription_ready / on_voice_command / on_keyword / on_speaker
events are fired from here."
  :type 'hook
  :group 'cmacs-speech)

(defun cmacs-speech-emit (event &rest plist)
  "Run `cmacs-speech-event-functions' with EVENT and PLIST, never signalling."
  (dolist (fn (if (functionp cmacs-speech-event-functions)
                  (list cmacs-speech-event-functions)
                cmacs-speech-event-functions))
    (unless (eq fn t)
      (condition-case err
          (funcall fn event plist)
        (error (message "cmacs-speech: event hook %S: %s" fn
                        (error-message-string err)))))))

(declare-function cmacs-podomation-emit-event "cmacs-podomation.c" (event data))

(defun cmacs-speech--podomation (event plist)
  "Forward speech EVENT with PLIST to podomation, when it runs."
  (when (fboundp 'cmacs-podomation-emit-event)
    (when-let* ((name (pcase event
                        ('transcription "on_transcription_ready")
                        ('keyword "on_keyword")
                        ('speaker "on_speaker"))))
      (ignore-errors
        (cmacs-podomation-emit-event
         name (cl-loop for (k v) on plist by #'cddr
                       when v collect (cons (substring (symbol-name k) 1)
                                            (format "%s" v))))))))

(add-hook 'cmacs-speech-event-functions #'cmacs-speech--podomation)

(defun cmacs-speech--podomation-command (text fn)
  "Forward a voice command that ran (spoken TEXT, function FN) to podomation."
  (when (fboundp 'cmacs-podomation-emit-event)
    (ignore-errors
      (cmacs-podomation-emit-event
       "on_voice_command" (list (cons "text" text) (cons "command" (format "%s" fn)))))))

(with-eval-after-load 'cmacs-voice-commands
  (add-hook 'cmacs-voice-command-functions #'cmacs-speech--podomation-command))

;;;; PCM helpers

(defun cmacs-speech-pcm-wav (pcm rate)
  "A WAV file's bytes (unibyte) for S16LE mono PCM at RATE."
  (let ((n (length pcm)))
    (cl-flet ((u32 (v) (unibyte-string (logand v 255) (logand (ash v -8) 255)
                                       (logand (ash v -16) 255) (logand (ash v -24) 255)))
              (u16 (v) (unibyte-string (logand v 255) (logand (ash v -8) 255))))
      (concat "RIFF" (u32 (+ 36 n)) "WAVEfmt "
              (u32 16) (u16 1) (u16 1) (u32 rate) (u32 (* 2 rate)) (u16 2) (u16 16)
              "data" (u32 n) pcm))))

(defun cmacs-speech-write-wav (file pcm rate)
  "Write S16LE mono PCM at RATE to FILE as a WAV; return FILE."
  (let ((coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (cmacs-speech-pcm-wav pcm rate))
      (write-region nil nil file nil 'silent)))
  file)

(defun cmacs-speech-read-wav (file)
  "Read PCM WAV FILE as (PCM . RATE): S16LE mono, any rate.
Uses sherpa's reader when built in, else parses 16-bit PCM itself."
  (if (fboundp 'cmacs-sherpa-read-wav)
      (cmacs-sherpa-read-wav file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((coding-system-for-read 'binary))
        (insert-file-contents-literally file))
      (let ((s (buffer-string)) (pos 12) rate data channels)
        (unless (and (>= (length s) 44) (string= (substring s 0 4) "RIFF"))
          (error "%s is not a WAV file" file))
        (cl-flet ((u16 (i) (logior (aref s i) (ash (aref s (1+ i)) 8)))
                  (u32 (i) (logior (aref s i) (ash (aref s (+ i 1)) 8)
                                   (ash (aref s (+ i 2)) 16) (ash (aref s (+ i 3)) 24))))
          (while (and (< (+ pos 8) (length s)) (not data))
            (let ((id (substring s pos (+ pos 4))) (size (u32 (+ pos 4))))
              (cond ((string= id "fmt ")
                     (setq channels (u16 (+ pos 10)) rate (u32 (+ pos 12))))
                    ((string= id "data")
                     (setq data (substring s (+ pos 8) (min (length s) (+ pos 8 size))))))
              (setq pos (+ pos 8 size (logand size 1))))))
        (unless (and data rate) (error "%s has no PCM data" file))
        (when (and channels (> channels 1))
          ;; Keep the first channel.
          (let ((frame (* 2 channels)) (out nil))
            (dotimes (i (/ (length data) frame))
              (push (substring data (* i frame) (+ (* i frame) 2)) out))
            (setq data (apply #'concat (nreverse out)))))
        (cons data rate)))))

(defcustom cmacs-speech-ffmpeg-program "ffmpeg"
  "ffmpeg used to turn any audio or video file into 16 kHz mono WAV."
  :type 'string
  :group 'cmacs-speech)

(defun cmacs-speech--wav-p (file)
  "Non-nil when FILE looks like a RIFF WAV."
  (and (string-match-p "\\.wav\\'" (downcase file))
       (with-temp-buffer
         (set-buffer-multibyte nil)
         (ignore-errors (insert-file-contents-literally file nil 0 12))
         (and (>= (buffer-size) 12)
              (string= (buffer-substring 1 5) "RIFF")
              (string= (buffer-substring 9 13) "WAVE")))))

(defun cmacs-speech-file-pcm (file callback)
  "Call CALLBACK with (PCM . RATE) for any audio/video FILE, asynchronously.
A WAV is read directly; anything else goes through ffmpeg to a
transient 16 kHz mono WAV.  On failure CALLBACK gets (:error . MESSAGE)."
  (setq file (expand-file-name file))
  (cond
   ((not (file-readable-p file))
    (funcall callback (cons :error (format "cannot read %s" file))))
   ((cmacs-speech--wav-p file)
    (funcall callback (condition-case err (cmacs-speech-read-wav file)
                        (error (cons :error (error-message-string err))))))
   (t
    (let* ((tmp (make-temp-file "cmacs-speech-" nil ".wav"))
           (buf (generate-new-buffer " *cmacs-speech-ffmpeg*")))
      (condition-case err
          (make-process
           :name "cmacs-speech-ffmpeg" :buffer buf :noquery t
           :command (list cmacs-speech-ffmpeg-program "-nostdin" "-y" "-loglevel" "error"
                          "-i" file "-ac" "1" "-ar" "16000" "-c:a" "pcm_s16le" "-f" "wav" tmp)
           :sentinel
           (lambda (proc _event)
             (unless (process-live-p proc)
               (let ((ok (and (eq (process-status proc) 'exit)
                              (zerop (process-exit-status proc))))
                     (msg (with-current-buffer buf (string-trim (buffer-string)))))
                 (kill-buffer buf)
                 (funcall callback
                          (if ok
                              (condition-case e (cmacs-speech-read-wav tmp)
                                (error (cons :error (error-message-string e))))
                            (cons :error (format "ffmpeg failed on %s: %s" file msg))))
                 (ignore-errors (delete-file tmp))))))
        (error
         (kill-buffer buf)
         (ignore-errors (delete-file tmp))
         (funcall callback (cons :error (format "cannot run %s: %s"
                                                cmacs-speech-ffmpeg-program
                                                (error-message-string err))))))))))

;;;; Speech to text

(defun cmacs-speech--decorate (result resolved)
  "RESULT alist with :backend and :model of RESOLVED added."
  (if (assq :error result)
      result
    (append result (list (cons :backend (plist-get resolved :backend))
                         (cons :model (plist-get resolved :model))))))

;;;###autoload
(cl-defun cmacs-speech-transcribe (pcm callback &key feature component model backend
                                      language (rate 16000))
  "Transcribe S16LE mono PCM at RATE; CALLBACK gets the result alist.
The result is ((:text . S) (:segments SEGMENT ...) (:backend . B)
\(:model . M) ...), each SEGMENT ((:start . MS) (:end . MS) (:text . S)),
or ((:error . MESSAGE)).
COMPONENT defaults to `stt-live' when FEATURE is given, else `stt'.
MODEL and BACKEND force a choice; LANGUAGE is a hint.  Never signals:
a failure to start reaches CALLBACK."
  (let* ((component (or component (if feature 'stt-live 'stt)))
         (r (cmacs-speech-resolve component feature)))
    (when backend (setq r (plist-put r :backend backend)))
    (when model (setq r (plist-put r :model model)))
    (when language
      (setq r (plist-put r :options (plist-put (copy-sequence (plist-get r :options))
                                               :language language))))
    (condition-case err
        (funcall (cmacs-speech--op r :transcribe) r pcm rate
                 (lambda (result)
                   (let ((out (cmacs-speech--decorate result r)))
                     (unless (assq :error out)
                       (cmacs-speech-emit 'transcription
                                          :text (alist-get :text out)
                                          :feature feature
                                          :backend (plist-get r :backend)
                                          :model (plist-get r :model)))
                     (funcall callback out))))
      (error (funcall callback (list (cons :error (error-message-string err))))))))

;;;###autoload
(cl-defun cmacs-speech-transcribe-file (file callback &rest keys &key feature &allow-other-keys)
  "Transcribe audio or video FILE; CALLBACK gets the result alist.
KEYS are as for `cmacs-speech-transcribe'; FEATURE defaults to none
(component `stt')."
  (ignore feature)
  (cmacs-speech-file-pcm
   file
   (lambda (got)
     (if (eq (car-safe got) :error)
         (funcall callback (list got))
       (apply #'cmacs-speech-transcribe (car got) callback
              :rate (cdr got)
              :component (or (plist-get keys :component) 'stt)
              (cmacs-speech--strip keys :component :rate))))))

;;;; Streaming recognition

(cl-defstruct (cmacs-speech-stream (:constructor cmacs-speech-stream--make))
  resolved backend-object on-partial on-final on-error closed)

(defun cmacs-speech-stream-available-p (&optional feature)
  "Non-nil when `stt-stream' for FEATURE has a real streaming engine."
  (cmacs-speech-can-p 'stt-stream feature :stream-open))

(cl-defun cmacs-speech-stream-open (&key feature on-partial on-final on-error)
  "Open a streaming recognizer for FEATURE, or nil if none is available.
ON-PARTIAL gets the text so far of the current utterance; ON-FINAL gets
an alist ((:text . S) (:start . MS) (:end . MS)) when an utterance
ends; ON-ERROR gets a message.  Feed it with `cmacs-speech-stream-feed'."
  (when-let* ((r (cmacs-speech-stream-available-p feature)))
    (let ((s (cmacs-speech-stream--make :resolved r :on-partial on-partial
                                        :on-final on-final :on-error on-error)))
      (setf (cmacs-speech-stream-backend-object s)
            (funcall (cmacs-speech--op r :stream-open) r
                     (lambda (result)
                       (unless (cmacs-speech-stream-closed s)
                         (cmacs-speech--stream-dispatch s result feature)))))
      s)))

(defun cmacs-speech--stream-dispatch (stream result feature)
  "Route one backend RESULT of STREAM to its callbacks."
  (cond
   ((assq :error result)
    (when-let* ((f (cmacs-speech-stream-on-error stream)))
      (funcall f (alist-get :error result))))
   (t
    (let ((partial (alist-get :partial result))
          (final (alist-get :final result)))
      (when (and partial (cmacs-speech-stream-on-partial stream))
        (funcall (cmacs-speech-stream-on-partial stream) partial))
      (when (and final (not (string-empty-p final)))
        (cmacs-speech-emit 'transcription :text final :feature feature
                           :backend (plist-get (cmacs-speech-stream-resolved stream) :backend))
        (when (cmacs-speech-stream-on-final stream)
          (funcall (cmacs-speech-stream-on-final stream)
                   `((:text . ,final)
                     (:start . ,(alist-get :start result))
                     (:end . ,(alist-get :end result))
                     ;; Word times, from engines that have them:
                     ;; ((WORD START-MS END-MS) ...) on the same axis.
                     ,@(when-let* ((words (alist-get :words result)))
                         (list (cons :words words)))))))))))

(defun cmacs-speech-stream-feed (stream pcm)
  "Give STREAM more S16LE 16 kHz mono PCM."
  (unless (cmacs-speech-stream-closed stream)
    (funcall (cmacs-speech--op (cmacs-speech-stream-resolved stream) :stream-feed)
             (cmacs-speech-stream-backend-object stream) pcm)))

(defun cmacs-speech-stream-finish (stream)
  "End of input: flush STREAM's last utterance (it stays usable)."
  (unless (cmacs-speech-stream-closed stream)
    (funcall (cmacs-speech--op (cmacs-speech-stream-resolved stream) :stream-finish)
             (cmacs-speech-stream-backend-object stream))))

(defun cmacs-speech-stream-close (stream)
  "Close STREAM; later results are dropped."
  (unless (cmacs-speech-stream-closed stream)
    (setf (cmacs-speech-stream-closed stream) t)
    (funcall (cmacs-speech--op (cmacs-speech-stream-resolved stream) :stream-close)
             (cmacs-speech-stream-backend-object stream))))

;;;; Wake words

(defun cmacs-speech-wake-available-p (&optional feature)
  "Non-nil when `wake' for FEATURE has a keyword spotter."
  (cmacs-speech-can-p 'wake feature :wake-open))

(cl-defun cmacs-speech-wake-open (phrases on-hit &key feature)
  "Listen for PHRASES; ON-HIT gets the phrase heard.  Nil if unavailable.
Feed audio with `cmacs-speech-wake-feed', stop with `cmacs-speech-wake-close'."
  (when-let* ((r (cmacs-speech-wake-available-p feature)))
    (let ((obj (funcall (cmacs-speech--op r :wake-open) r phrases
                        (lambda (phrase)
                          (cmacs-speech-emit 'keyword :keyword phrase :feature feature)
                          (funcall on-hit phrase)))))
      (and obj (cons r obj)))))

(defun cmacs-speech-wake-feed (wake pcm)
  "Feed WAKE (from `cmacs-speech-wake-open') PCM."
  (funcall (cmacs-speech--op (car wake) :wake-feed) (cdr wake) pcm))

(defun cmacs-speech-wake-close (wake)
  "Stop WAKE."
  (when wake
    (funcall (cmacs-speech--op (car wake) :wake-close) (cdr wake))))

;;;; Voice activity

(cl-defun cmacs-speech-vad-open (&key feature)
  "A VAD for FEATURE as (RESOLVED . OBJECT), or nil when none is installed."
  (when-let* ((r (cmacs-speech-can-p 'vad feature :vad-open))
              (obj (ignore-errors (funcall (plist-get (cmacs-speech-backend
                                                       (plist-get r :backend))
                                                      :vad-open)
                                           r))))
    (cons r obj)))

(defun cmacs-speech-vad-feed (vad pcm callback)
  "Feed VAD whole 512-sample frames of PCM; CALLBACK gets the result alist.
The alist has :probs, a vector with one speech probability per frame,
or :error."
  (funcall (cmacs-speech--op (car vad) :vad-feed) (cdr vad) pcm callback))

(defun cmacs-speech-vad-close (vad)
  "Release VAD."
  (when vad
    (ignore-errors (funcall (cmacs-speech--op (car vad) :vad-close) (cdr vad)))))

;;;; Text to speech

(defvar cmacs-speech--playback nil "Shared playback handle.")
(defvar cmacs-speech--playback-rate nil "Its sample rate.")
(defvar cmacs-speech--speak-gen 0 "Bumped by `cmacs-speech-stop-speaking'.")
(defvar cmacs-speech--speak-tokens nil "Cancel tokens of in-flight synthesis.")
(defvar cmacs-speech--speak-until 0.0 "When queued playback ends.")

(defun cmacs-speech--ensure-playback (rate)
  "The shared playback handle at RATE, started."
  (unless (and (eql cmacs-speech--playback-rate rate)
               cmacs-speech--playback
               (ignore-errors (cmacs-audio-state cmacs-speech--playback) t))
    (when cmacs-speech--playback
      (ignore-errors (cmacs-audio-close cmacs-speech--playback)))
    (setq cmacs-speech--playback (cmacs-audio--playback-open-pcm-1 rate 1)
          cmacs-speech--playback-rate rate))
  (cmacs-audio-start cmacs-speech--playback)
  cmacs-speech--playback)

(defun cmacs-speech-play-pcm (pcm rate)
  "Play S16LE mono PCM at RATE through the shared output; return seconds."
  (let ((secs (/ (length pcm) (* 2.0 rate))))
    (cmacs-audio-push-pcm (cmacs-speech--ensure-playback rate) pcm)
    (setq cmacs-speech--speak-until (+ (max (float-time) cmacs-speech--speak-until) secs))
    secs))

(defun cmacs-speech-speaking-p ()
  "Non-nil while speech synthesised here is generating or playing."
  (or cmacs-speech--speak-tokens (< (float-time) cmacs-speech--speak-until)))

(defun cmacs-speech-tts-available-p (&optional feature)
  "Non-nil when some engine can speak for FEATURE."
  (cmacs-speech-can-p 'tts feature :synthesize))

(cl-defun cmacs-speech-synthesize (text callback &key feature voice backend speed
                                        speaker stream)
  "Synthesise TEXT; CALLBACK gets ((:pcm . S) (:sample-rate . R)) or (:error ...).
VOICE / BACKEND force a model / engine; SPEED and SPEAKER (a speaker id
of a multi-speaker model) override the configured ones.  With STREAM, a
function, audio is handed to it as ((:pcm . S) (:sample-rate . R)) per
sentence while it is generated and the final result carries no :pcm.
Returns a token for `cmacs-speech-cancel'."
  (let ((r (cmacs-speech-resolve 'tts feature)))
    (when backend (setq r (plist-put r :backend backend)))
    (when voice (setq r (plist-put r :model voice)))
    (let ((opts (copy-sequence (plist-get r :options))))
      (when speed (setq opts (plist-put opts :speed speed)))
      (when speaker (setq opts (plist-put opts :speaker speaker)))
      (setq r (plist-put r :options opts)))
    (condition-case err
        (let ((token (funcall (cmacs-speech--op r :synthesize) r text
                              (lambda (result)
                                (unless (assq :error result)
                                  (cmacs-speech-emit 'synthesis :text text :feature feature
                                                     :backend (plist-get r :backend)))
                                (funcall callback result))
                              stream)))
          (cons r token))
      (error (funcall callback (list (cons :error (error-message-string err))))
             nil))))

(defun cmacs-speech-cancel (token)
  "Cancel synthesis TOKEN from `cmacs-speech-synthesize'."
  (when-let* ((r (car-safe token))
              (f (plist-get (cmacs-speech-backend (plist-get r :backend)) :cancel)))
    (ignore-errors (funcall f (cdr token)))))

;;;###autoload
(cl-defun cmacs-speech-speak (text &key feature voice speed speaker)
  "Speak TEXT now, streaming audio as it is generated when the engine can.
Returns the synthesis token."
  (interactive (list (if (use-region-p)
                         (buffer-substring-no-properties (region-beginning) (region-end))
                       (read-string "Say: "))))
  (let* ((gen cmacs-speech--speak-gen)
         (tok nil))
    (setq tok (cmacs-speech-synthesize
               text
               (lambda (result)
                 (setq cmacs-speech--speak-tokens (delq tok cmacs-speech--speak-tokens))
                 (cond
                  ((/= gen cmacs-speech--speak-gen))
                  ((assq :error result)
                   (message "Speech: %s" (alist-get :error result)))
                  ((alist-get :pcm result)
                   (cmacs-speech-play-pcm (alist-get :pcm result)
                                          (alist-get :sample-rate result)))))
               :feature (or feature 'reader) :voice voice :speed speed :speaker speaker
               :stream (lambda (chunk)
                         (when (= gen cmacs-speech--speak-gen)
                           (cmacs-speech-play-pcm (alist-get :pcm chunk)
                                                  (alist-get :sample-rate chunk))))))
    (when tok (push tok cmacs-speech--speak-tokens))
    tok))

;;;###autoload
(defun cmacs-speech-stop-speaking ()
  "Stop everything `cmacs-speech-speak' started."
  (interactive)
  (cl-incf cmacs-speech--speak-gen)
  (mapc #'cmacs-speech-cancel cmacs-speech--speak-tokens)
  (setq cmacs-speech--speak-tokens nil
        cmacs-speech--speak-until 0.0)
  (when cmacs-speech--playback
    (ignore-errors (cmacs-audio-stop cmacs-speech--playback))))

;;;###autoload
(cl-defun cmacs-speech-synthesize-to-file (text file &optional callback &key voice feature speed speaker)
  "Synthesise TEXT into WAV FILE; CALLBACK (if any) gets FILE or (:error . M).
Returns the synthesis token."
  (cmacs-speech-synthesize
   text
   (lambda (result)
     (let ((out (if (assq :error result)
                    (assq :error result)
                  (cmacs-speech-write-wav (expand-file-name file)
                                          (alist-get :pcm result)
                                          (alist-get :sample-rate result)))))
       (when callback (funcall callback out))))
   :feature feature :voice voice :speed speed :speaker speaker))

(cl-defun cmacs-speech-synthesize-to-file-wait (text file &key voice backend feature
                                                       (timeout 300))
  "Synthesise TEXT into WAV FILE and return FILE once it is written.
For callers that need the audio before they go on (rendering a podcast
turn by turn).  Emacs keeps processing input and redisplay while it
waits; signals on failure or after TIMEOUT seconds."
  (let ((result nil) (deadline (+ (float-time) timeout)))
    (cmacs-speech-with-config (and backend `((tts ,backend)))
      (cmacs-speech-synthesize-to-file text file (lambda (r) (setq result (or r 'failed)))
                                       :voice voice :feature feature))
    (while (and (null result) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (cond ((stringp result) result)
          ((null result) (error "Speech synthesis timed out after %ds" timeout))
          (t (error "Speech synthesis failed: %s" (cdr-safe result))))))

;;;; Analysis components

(defun cmacs-speech--run (component input callback &rest keys)
  "Run analysis COMPONENT on INPUT; CALLBACK gets the result alist.
KEYS: :feature, :backend, :model, :chunk-fn, and options merged into
the resolved :options."
  (let* ((feature (plist-get keys :feature))
         (r (cmacs-speech-resolve component feature)))
    (when-let* ((b (plist-get keys :backend))) (setq r (plist-put r :backend b)))
    (when-let* ((m (plist-get keys :model))) (setq r (plist-put r :model m)))
    (setq r (plist-put r :options (append (cmacs-speech--strip keys :feature :backend
                                                                :model :chunk-fn)
                                          (plist-get r :options))))
    (condition-case err
        (funcall (cmacs-speech--op r :run) r component input
                 (lambda (result) (funcall callback (cmacs-speech--decorate result r)))
                 (plist-get keys :chunk-fn))
      (error (funcall callback (list (cons :error (error-message-string err))))))))

(defun cmacs-speech--run-file (component file callback keys)
  "Run COMPONENT on FILE's audio."
  (cmacs-speech-file-pcm
   file (lambda (got)
          (if (eq (car-safe got) :error)
              (funcall callback (list got))
            (apply #'cmacs-speech--run component (car got) callback
                   :rate (cdr got) keys)))))

(defun cmacs-speech-diarize (pcm callback &rest keys)
  "Who spoke when in 16 kHz PCM.
CALLBACK gets ((:segments ...) (:num-speakers . N)).
KEYS: :num-speakers (if known), :threshold, :feature, :chunk-fn (progress)."
  (apply #'cmacs-speech--run 'diarize pcm callback keys))

(defun cmacs-speech-diarize-file (file callback &rest keys)
  "`cmacs-speech-diarize' on audio/video FILE."
  (cmacs-speech--run-file 'diarize file callback keys))

(defun cmacs-speech-punctuate (text callback &rest keys)
  "Add punctuation to TEXT; CALLBACK gets ((:text . PUNCTUATED))."
  (apply #'cmacs-speech--run 'punctuate text callback keys))

(defun cmacs-speech-detect-language (pcm callback &rest keys)
  "Spoken language of PCM; CALLBACK gets ((:lang . CODE))."
  (apply #'cmacs-speech--run 'lang-id pcm callback keys))

(defun cmacs-speech-tag-audio (pcm callback &rest keys)
  "Sound events in PCM; CALLBACK gets ((:events ((:name . S) (:prob . F)) ...))."
  (apply #'cmacs-speech--run 'audio-tag pcm callback keys))

(defun cmacs-speech-denoise (pcm callback &rest keys)
  "Enhance speech in PCM; CALLBACK gets ((:pcm . S) (:sample-rate . R))."
  (apply #'cmacs-speech--run 'denoise pcm callback keys))

(defun cmacs-speech-separate (pcm callback &rest keys)
  "Split PCM into stems.
CALLBACK gets ((:stems ((:index . I) (:pcm . S)) ...) (:sample-rate . R))."
  (apply #'cmacs-speech--run 'separate pcm callback keys))

(defun cmacs-speech-identify-speaker (pcm callback &rest keys)
  "Best enrolled matches for the voice in PCM; CALLBACK gets ((:matches ...))."
  (apply #'cmacs-speech--run 'speaker-id pcm
         (lambda (result)
           (when-let* ((best (car (alist-get :matches result))))
             (cmacs-speech-emit 'speaker :name (alist-get :name best)
                                :score (alist-get :score best)
                                :feature (plist-get keys :feature)))
           (funcall callback result))
         :op 'identify keys))

(defun cmacs-speech-enroll-speaker (name pcm callback &rest keys)
  "Enroll the voice in PCM as NAME (persisted); CALLBACK gets the result."
  (apply #'cmacs-speech--run 'speaker-id pcm callback :op 'enroll :name name keys))

(defun cmacs-speech--clock (ms)
  "MS as HH:MM:SS,mmm."
  (let ((ms (or ms 0)))
    (format "%02d:%02d:%02d,%03d" (/ ms 3600000) (% (/ ms 60000) 60)
            (% (/ ms 1000) 60) (% ms 1000))))

(defun cmacs-speech-label-speakers (turns segments)
  "Lines \"- Speaker N [time]: text\": each transcript SEGMENT gets the
speaker TURN it overlaps most; consecutive lines by one speaker merge.
Speakers are numbered 1, 2, ... in order of first appearance, whatever
cluster ids the diarizer used."
  (let ((lines nil) (last nil) (numbers nil))
    (dolist (s segments)
      (let* ((s0 (alist-get :start s)) (s1 (alist-get :end s))
             (best (cl-loop with best = nil and most = 0
                            for tr in turns
                            for ov = (- (min s1 (alist-get :end tr)) (max s0 (alist-get :start tr)))
                            when (> ov most) do (setq best tr most ov)
                            finally return best))
             (who (if (null best) "?"
                    (let ((id (alist-get :speaker best)))
                      (or (alist-get id numbers)
                          (cdar (push (cons id (1+ (length numbers))) numbers))))))
             (text (string-trim (or (alist-get :text s) ""))))
        (if (and last (eql (car last) who))
            (setcdr last (concat (cdr last) " " text))
          (when last (push last lines))
          (setq last (cons who (format "[%s] %s"
                                       (substring (cmacs-speech--clock s0) 0 8) text))))))
    (when last (push last lines))
    (mapconcat (lambda (l) (format "- *Speaker %s* %s" (car l) (cdr l)))
               (nreverse lines) "\n")))

;;;; Synchronous variants, for RPC surfaces
;;
;; MCP and D-Bus answer a call with its result, on the editor's thread
;; (the compositor's, under --gowl).  Waiting there for an asynchronous
;; engine would need a nested main loop inside an RPC dispatch, so these
;; run the engine on the calling thread instead -- exactly what the
;; whisper sync transcription these surfaces always used did.  Backends
;; provide :transcribe-now, :synthesize-now and :run-now.  Interactive
;; code uses the asynchronous functions above.

(defun cmacs-speech-file-pcm-now (file)
  "(PCM . RATE) of audio/video FILE, converting with ffmpeg if needed."
  (setq file (expand-file-name file))
  (unless (file-readable-p file) (error "Cannot read %s" file))
  (if (cmacs-speech--wav-p file)
      (cmacs-speech-read-wav file)
    (let ((tmp (make-temp-file "cmacs-speech-" nil ".wav")))
      (unwind-protect
          (if (zerop (call-process cmacs-speech-ffmpeg-program nil nil nil
                                   "-nostdin" "-y" "-loglevel" "error" "-i" file
                                   "-ac" "1" "-ar" "16000" "-c:a" "pcm_s16le" "-f" "wav" tmp))
              (cmacs-speech-read-wav tmp)
            (error "ffmpeg could not read %s" file))
        (ignore-errors (delete-file tmp))))))

(defun cmacs-speech--resolve-for (component keys)
  "`cmacs-speech-resolve' COMPONENT, adjusted by KEYS.
KEYS supply :feature, :backend, :model and options."
  (let ((r (cmacs-speech-resolve component (plist-get keys :feature))))
    (when-let* ((b (plist-get keys :backend))) (setq r (plist-put r :backend b)))
    (when-let* ((m (plist-get keys :model))) (setq r (plist-put r :model m)))
    (plist-put r :options (append (cmacs-speech--strip keys :feature :backend :model)
                                  (plist-get r :options)))))

(defun cmacs-speech-transcribe-now (pcm &rest keys)
  "Transcribe PCM now; return the result alist.  KEYS as for
`cmacs-speech-transcribe' (:feature :component :backend :model :language :rate)."
  (let* ((component (or (plist-get keys :component) 'stt))
         (r (cmacs-speech--resolve-for component (cmacs-speech--strip keys :component :rate)))
         (res (cmacs-speech--decorate
               (funcall (cmacs-speech--op r :transcribe-now) r pcm
                        (or (plist-get keys :rate) 16000))
               r)))
    (unless (assq :error res)
      (cmacs-speech-emit 'transcription :text (alist-get :text res)
                         :feature (plist-get keys :feature)
                         :backend (plist-get r :backend) :model (plist-get r :model)))
    res))

(defun cmacs-speech-transcribe-file-now (file &rest keys)
  "Transcribe audio/video FILE now; return the result alist."
  (let ((got (cmacs-speech-file-pcm-now file)))
    (apply #'cmacs-speech-transcribe-now (car got) :rate (cdr got) keys)))

(defun cmacs-speech-synthesize-now (text &rest keys)
  "Synthesise TEXT now; return ((:pcm . S) (:sample-rate . R)).
KEYS: :voice (a model), :backend, :feature, :speed, :speaker."
  (let* ((keys (if (plist-member keys :voice)
                   (plist-put (cmacs-speech--strip keys :voice) :model (plist-get keys :voice))
                 keys))
         (r (cmacs-speech--resolve-for 'tts keys)))
    (funcall (cmacs-speech--op r :synthesize-now) r text)))

(defun cmacs-speech-run-now (component input &rest keys)
  "Run analysis COMPONENT on INPUT (PCM or text) now; return the alist."
  (let ((r (cmacs-speech--resolve-for component keys)))
    (cmacs-speech--decorate (funcall (cmacs-speech--op r :run-now) r component input) r)))

(defun cmacs-speech-who-spoke-now (file &rest keys)
  "A speaker-labelled transcript of FILE, as org text.  KEYS: :num-speakers."
  (let* ((got (cmacs-speech-file-pcm-now file))
         (d (apply #'cmacs-speech-run-now 'diarize (car got) :rate (cdr got) keys))
         (tr (cmacs-speech-transcribe-now (car got) :rate (cdr got) :feature 'rpc)))
    (when (assq :error d) (error "Diarization: %s" (alist-get :error d)))
    (when (assq :error tr) (error "Transcription: %s" (alist-get :error tr)))
    (format "%d speakers\n\n%s" (alist-get :num-speakers d)
            (cmacs-speech-label-speakers (alist-get :segments d) (alist-get :segments tr)))))

;;;; Introspection

(defun cmacs-speech-describe-resolution ()
  "Resolution of every component and feature, as a list of plists."
  (append
   (mapcar (lambda (c) (cmacs-speech-resolve (car c))) cmacs-speech-components)
   (cl-loop for (f _label comps) in cmacs-speech-features
            append (cl-loop for c in comps
                            for r = (cmacs-speech-resolve c f)
                            when (memq (plist-get r :source) '(override session init ui))
                            when (cmacs-speech--find c f)
                            when (plist-get (cdr (cmacs-speech--find c f)) :feature)
                            collect r))))

;;;###autoload
(defun cmacs-speech-describe ()
  "Show which engine and model each speech component and feature uses, and why."
  (interactive)
  (with-help-window "*cmacs speech*"
    (princ "Speech engines\n\n")
    (dolist (b cmacs-speech-backend-order)
      (let ((d (plist-get (cmacs-speech-backend b) :describe)))
        (princ (format "  %-8s %s\n" b (or (and d (ignore-errors (funcall d))) "")))))
    (princ "\nComponent     Feature         Backend   Model                                  Source\n")
    (princ (make-string 98 ?-))
    (princ "\n")
    (dolist (r (cmacs-speech-describe-resolution))
      (princ (format "%-13s %-15s %-9s %-38s %s%s\n"
                     (plist-get r :component)
                     (or (plist-get r :feature) "")
                     (or (plist-get r :backend) "-")
                     (truncate-string-to-width (format "%s" (or (plist-get r :model) "-")) 38)
                     (plist-get r :source)
                     (if (and (plist-get r :auto) (not (eq (plist-get r :source) 'auto)))
                         " (auto)" ""))))))

(provide 'cmacs-speech)

;; Backends that ship with cmacs.  Each file registers itself and is a
;; no-op when its engine is not compiled in.
(require 'cmacs-speech-whisper nil t)
(require 'cmacs-speech-piper nil t)
(require 'cmacs-speech-sherpa nil t)

;; Speech tools for brigade agents, once brigade is loaded.
(with-eval-after-load 'cmacs-brigade-registry
  (require 'cmacs-speech-brigade nil t))

;;; cmacs-speech.el ends here
