;;; cmacs-whisper-dictate.el --- Live STT into the current buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; M-x cmacs-whisper-dictate toggles dictation: capture from the
;; microphone, transcribe in ~3 s windows, and insert each finalised
;; window at point.  Voice commands ("new line", "period", "delete
;; word") can be intercepted before insertion.
;;
;; Bound to `C-c v d' via `cmacs-voice-map'.
;;
;; While you talk, the window in progress is re-transcribed every
;; `cmacs-whisper-dictate-partial-interval' seconds and shown at the
;; insertion point, dimmed, as an overlay -- insert-as-you-talk -- until
;; the window is final and its text is inserted for real.
;;
;; The microphone belongs to the shared voice engine (cmacs-voice.el):
;; dictation is an exclusive client of it, so the always-on loop pauses
;; while you dictate, and a push-to-talk command elsewhere (VR, the
;; brigade, C-c v v) ends the dictation rather than fighting it for the
;; device.  Windows are transcribed one at a time, so text is inserted
;; in the order it was said; a window with no sound in it is not sent
;; to whisper at all.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-audio)
(require 'cmacs-whisper)
(require 'cmacs-voice)

(defvar cmacs-voice-energy-floor-db)

(defgroup cmacs-whisper-dictate nil
  "Live dictation into the current buffer via whisper.cpp."
  :group 'cmacs-whisper
  :prefix "cmacs-whisper-dictate-")

(defcustom cmacs-whisper-dictate-window-seconds 3.0
  "Length (s) of each PCM window handed to whisper for transcription."
  :type 'number
  :group 'cmacs-whisper-dictate)

(defcustom cmacs-whisper-dictate-partial-interval 1.0
  "Seconds between partial transcripts of the window in progress.
The partial is shown at the insertion point until the window is final.
nil turns partials off."
  :type '(choice (const :tag "No partials" nil) number)
  :group 'cmacs-whisper-dictate)

(defcustom cmacs-whisper-dictate-auto-punctuate t
  "When non-nil, capitalise the first letter of inserted segments and
ensure trailing punctuation."
  :type 'boolean
  :group 'cmacs-whisper-dictate)

(defcustom cmacs-whisper-dictate-command-words
  '(("new line"   . newline)
    ("new paragraph" . (lambda () (newline) (newline)))
    ("period"     . (lambda () (insert ?.)))
    ("question mark" . (lambda () (insert ??)))
    ("delete word" . backward-kill-word)
    ("undo"       . undo))
  "Alist of (PHRASE . COMMAND) intercepted before text is inserted.
COMMAND may be a function symbol or a lambda."
  :type '(alist :key-type string :value-type sexp)
  :group 'cmacs-whisper-dictate)

(defface cmacs-whisper-dictate-partial
  '((t :inherit shadow :slant italic))
  "Face for the not-yet-final words shown at the insertion point.")

(defvar-local cmacs-whisper-dictate--handle nil
  "Non-nil in the buffer being dictated into.
Kept for compatibility: it was the capture handle; the engine owns the
microphone now and this is just the engine client id.")
(defvar-local cmacs-whisper-dictate--timer  nil
  "Unused since the engine drains the microphone; kept for compatibility.")
(defvar-local cmacs-whisper-dictate--state  'idle)   ; idle | recording | thinking
(defvar-local cmacs-whisper-dictate--target-buffer nil)
(defvar-local cmacs-whisper-dictate--target-marker nil)

(defvar cmacs-whisper-dictate--buffer nil
  "The buffer dictation is going into, or nil.  One at a time: one mic.")
(defvar cmacs-whisper-dictate--chunks nil "PCM of the window in progress, newest first.")
(defvar cmacs-whisper-dictate--bytes 0 "Bytes in the window in progress.")
(defvar cmacs-whisper-dictate--queue nil "Final windows waiting for whisper, in order.")
(defvar cmacs-whisper-dictate--busy nil "Non-nil while whisper has a window.")
(defvar cmacs-whisper-dictate--partial-at 0.0 "When the last partial started.")
(defvar cmacs-whisper-dictate--overlay nil "Overlay showing the partial text.")
(defvar cmacs-whisper-dictate--gen 0 "Bumped per final window; stale partials drop.")

(defun cmacs-whisper-dictate--active-p ()
  "Non-nil while dictation holds the microphone."
  (and (memq 'dictate (cmacs-voice-owners)) t))

(defun cmacs-whisper-dictate--mode-line-glyph ()
  (pcase cmacs-whisper-dictate--state
    ('recording " 🎤")
    ('thinking  " 🎤…")
    (_          "")))

(defun cmacs-whisper-dictate--set-state (state)
  "Set the dictated buffer's STATE and refresh the mode line."
  (when (buffer-live-p cmacs-whisper-dictate--buffer)
    (with-current-buffer cmacs-whisper-dictate--buffer
      (setq-local cmacs-whisper-dictate--state state)))
  (force-mode-line-update t))

(defun cmacs-whisper-dictate--maybe-command (text)
  "Run a registered voice command if TEXT matches one.  Return non-nil if matched."
  (let ((clean (downcase (string-trim text "[ \t\n.,!?]+" "[ \t\n.,!?]+"))))
    (catch 'matched
      (dolist (entry cmacs-whisper-dictate-command-words)
        (when (string= clean (car entry))
          (let ((buf cmacs-whisper-dictate--target-buffer)
                (mk cmacs-whisper-dictate--target-marker))
            (if (and (buffer-live-p buf) (markerp mk))
                (with-current-buffer buf
                  (save-excursion
                    (goto-char mk)
                    (funcall (if (functionp (cdr entry)) (cdr entry)
                               (eval (cdr entry) t)))
                    (set-marker mk (point))))
              (funcall (if (functionp (cdr entry)) (cdr entry)
                         (eval (cdr entry) t)))))
          (throw 'matched t)))
      nil)))

(defun cmacs-whisper-dictate--insert (text)
  "Insert TEXT at the dictate marker (with auto-punctuation if enabled)."
  (let ((buf cmacs-whisper-dictate--target-buffer)
        (mk  cmacs-whisper-dictate--target-marker))
    (when (and buf (buffer-live-p buf) mk)
      (with-current-buffer buf
        (save-excursion
          (goto-char mk)
          (let* ((trimmed (string-trim text))
                 (final   (if cmacs-whisper-dictate-auto-punctuate
                              (concat (when (and (not (bobp))
                                                 (not (memq (char-before) '(?\s ?\n))))
                                        " ")
                                      (capitalize (substring trimmed 0 1))
                                      (substring trimmed 1))
                            trimmed)))
            (undo-boundary)
            (insert final)
            (set-marker mk (point))))))))

(defun cmacs-whisper-dictate--show-partial (text)
  "Show not-yet-final TEXT at the insertion point."
  (let ((buf cmacs-whisper-dictate--target-buffer)
        (mk cmacs-whisper-dictate--target-marker))
    (when (and (buffer-live-p buf) (markerp mk))
      (with-current-buffer buf
        (unless (overlayp cmacs-whisper-dictate--overlay)
          (setq cmacs-whisper-dictate--overlay (make-overlay mk mk buf nil t)))
        (move-overlay cmacs-whisper-dictate--overlay mk mk buf)
        ;; An after-string, not text: nothing reaches the buffer (or its
        ;; undo list) until the window is final.
        (overlay-put cmacs-whisper-dictate--overlay 'after-string
                     (propertize (concat " " text " …")
                                 'face 'cmacs-whisper-dictate-partial))))))

(defun cmacs-whisper-dictate--clear-partial ()
  "Remove the partial text."
  (when (overlayp cmacs-whisper-dictate--overlay)
    (delete-overlay cmacs-whisper-dictate--overlay))
  (setq cmacs-whisper-dictate--overlay nil))

(defun cmacs-whisper-dictate--on-result (result)
  "Callback after whisper finishes one window."
  (let* ((text (cmacs-voice-clean (cdr (assq :text result))))
         (err  (cdr (assq :error result))))
    (cmacs-whisper-dictate--clear-partial)
    (cond
     (err (message "cmacs-whisper-dictate: %s" err))
     ((string-empty-p text) nil)
     ((cmacs-whisper-dictate--maybe-command text) nil)
     (t (cmacs-whisper-dictate--insert text)))))

(defun cmacs-whisper-dictate--silent-p (pcm)
  "Non-nil when no window of PCM rises above the energy floor."
  (let ((levels (ignore-errors (cmacs-whisper-pcm-levels pcm))))
    (and levels (> (length levels) 0)
         (< (apply #'max (append levels nil)) cmacs-voice-energy-floor-db))))

(defun cmacs-whisper-dictate--pump ()
  "Send the next final window to whisper, one at a time, in order."
  (when (and cmacs-whisper-dictate--queue (not cmacs-whisper-dictate--busy))
    (let ((pcm (pop cmacs-whisper-dictate--queue)))
      (if (cmacs-whisper-dictate--silent-p pcm)
          (progn (fillarray pcm 0) (cmacs-whisper-dictate--pump))
        (setq cmacs-whisper-dictate--busy t)
        (cl-incf cmacs-whisper-dictate--gen)
        (when cmacs-whisper-dictate--buffer
          (cmacs-whisper-dictate--set-state 'thinking))
        (cmacs-voice-transcribe
         pcm
         (lambda (result)
           (setq cmacs-whisper-dictate--busy nil)
           (cmacs-whisper-dictate--on-result result)
           (cmacs-whisper-dictate--set-state
            (if (cmacs-whisper-dictate--active-p) 'recording
              (if cmacs-whisper-dictate--queue 'thinking 'idle)))
           (cmacs-whisper-dictate--pump)))))))

(defun cmacs-whisper-dictate--cut ()
  "Close the window in progress and queue it."
  (when cmacs-whisper-dictate--chunks
    (let ((pcm (apply #'concat (reverse cmacs-whisper-dictate--chunks))))
      (cmacs-voice-wipe cmacs-whisper-dictate--chunks)
      (setq cmacs-whisper-dictate--chunks nil
            cmacs-whisper-dictate--bytes 0)
      (setq cmacs-whisper-dictate--queue
            (append cmacs-whisper-dictate--queue (list pcm)))
      (cmacs-whisper-dictate--pump))))

(defun cmacs-whisper-dictate--ingest (pcm)
  "Engine consumer: add PCM to the window; cut it when full."
  (push pcm cmacs-whisper-dictate--chunks)
  (cl-incf cmacs-whisper-dictate--bytes (length pcm))
  (when (>= cmacs-whisper-dictate--bytes
            (* 2 cmacs-voice-rate cmacs-whisper-dictate-window-seconds))
    (cmacs-whisper-dictate--cut)))

(defun cmacs-whisper-dictate--tick ()
  "Engine tick: show a partial of the window in progress when one is due."
  (when (and cmacs-whisper-dictate-partial-interval
             (cmacs-whisper-dictate--active-p)
             (not cmacs-whisper-dictate--busy)
             (null cmacs-whisper-dictate--queue)
             (>= cmacs-whisper-dictate--bytes cmacs-voice-rate) ; 0.5 s
             (>= (- (float-time) cmacs-whisper-dictate--partial-at)
                 cmacs-whisper-dictate-partial-interval))
    (let ((pcm (apply #'concat (reverse cmacs-whisper-dictate--chunks)))
          (gen cmacs-whisper-dictate--gen))
      (setq cmacs-whisper-dictate--partial-at (float-time))
      (unless (cmacs-whisper-dictate--silent-p pcm)
        (setq cmacs-whisper-dictate--busy t)
        (cmacs-voice-transcribe
         pcm
         (lambda (result)
           (setq cmacs-whisper-dictate--busy nil)
           (let ((text (cmacs-voice-clean (cdr (assq :text result)))))
             (when (and (= gen cmacs-whisper-dictate--gen)
                        (cmacs-whisper-dictate--active-p)
                        (not (string-empty-p text)))
               (cmacs-whisper-dictate--show-partial text)))
           (cmacs-whisper-dictate--pump)))))))

(defun cmacs-whisper-dictate--start ()
  "Start dictating into the current buffer at point."
  (unless (file-exists-p (cmacs-whisper-model-path))
    (user-error "Whisper model not found: %s.  Run M-x cmacs-whisper-download-model"
                (cmacs-whisper-model-path)))
  (setq cmacs-whisper-dictate--buffer (current-buffer)
        cmacs-whisper-dictate--chunks nil
        cmacs-whisper-dictate--bytes 0
        cmacs-whisper-dictate--partial-at (float-time))
  (setq-local cmacs-whisper-dictate--target-buffer (current-buffer))
  (setq-local cmacs-whisper-dictate--target-marker (point-marker))
  (set-marker-insertion-type cmacs-whisper-dictate--target-marker t)
  (condition-case err
      (cmacs-voice-acquire 'dictate :exclusive t
                           :consumer #'cmacs-whisper-dictate--ingest
                           :preempt #'cmacs-whisper-dictate--stop)
    (error (setq cmacs-whisper-dictate--buffer nil)
           (signal (car err) (cdr err))))
  (setq-local cmacs-whisper-dictate--handle 'dictate)
  (add-hook 'cmacs-voice-tick-functions #'cmacs-whisper-dictate--tick)
  (cmacs-whisper-dictate--set-state 'recording)
  (add-to-list 'mode-line-misc-info
               '(:eval (cmacs-whisper-dictate--mode-line-glyph)) t)
  (message "cmacs-whisper-dictate: recording (C-c v d to stop)"))

(defun cmacs-whisper-dictate--stop ()
  "Stop dictating; what is left of the last window is still transcribed."
  (when (cmacs-whisper-dictate--active-p)
    (remove-hook 'cmacs-voice-tick-functions #'cmacs-whisper-dictate--tick)
    (cmacs-voice--drain)
    (cmacs-voice-release 'dictate)
    (if (>= cmacs-whisper-dictate--bytes cmacs-voice-rate)
        (cmacs-whisper-dictate--cut)
      (cmacs-voice-wipe cmacs-whisper-dictate--chunks)
      (setq cmacs-whisper-dictate--chunks nil
            cmacs-whisper-dictate--bytes 0))
    (cl-incf cmacs-whisper-dictate--gen)
    (cmacs-whisper-dictate--clear-partial)
    (when (buffer-live-p cmacs-whisper-dictate--buffer)
      (with-current-buffer cmacs-whisper-dictate--buffer
        (setq-local cmacs-whisper-dictate--handle nil)))
    (cmacs-whisper-dictate--set-state
     (if (or cmacs-whisper-dictate--busy cmacs-whisper-dictate--queue) 'thinking 'idle))
    (message "cmacs-whisper-dictate: stopped")))

;;;###autoload
(defun cmacs-whisper-dictate ()
  "Toggle live dictation into the current buffer.
One dictation at a time (there is one microphone): toggling in another
buffer moves dictation there."
  (interactive)
  (cond
   ((and (cmacs-whisper-dictate--active-p)
         (eq cmacs-whisper-dictate--buffer (current-buffer)))
    (cmacs-whisper-dictate--stop))
   (t
    (when (cmacs-whisper-dictate--active-p)
      (cmacs-whisper-dictate--stop))
    (cmacs-whisper-dictate--start))))

;; C-c v d binding is installed via an autoload cookie below so it
;; works at startup BEFORE this file is loaded.  The cookie references
;; `cmacs-voice-map' which is itself autoload-cookied in cmacs-audio.el
;; -- loaddefs processes files alphabetically so the defvar lands
;; ahead of this define-key.
;;
;;;###autoload (define-key cmacs-voice-map (kbd "d") #'cmacs-whisper-dictate)

(provide 'cmacs-whisper-dictate)

;;; cmacs-whisper-dictate.el ends here
