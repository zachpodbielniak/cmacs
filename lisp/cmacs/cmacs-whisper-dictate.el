;;; cmacs-whisper-dictate.el --- Live STT into the current buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; M-x cmacs-whisper-dictate toggles dictation: capture from the
;; microphone, transcribe in ~3 s sliding windows, and insert each
;; finalised segment at point.  Voice commands ("new line", "period",
;; "delete word") can be intercepted before insertion.
;;
;; Bound to `C-c v d' via `cmacs-voice-map-augment-hook'.
;;
;; This is a transparent loop: poll capture buffer, hand drained PCM
;; to `cmacs-whisper-transcribe-pcm-async', insert returned text.
;; The Whisper model itself does VAD-style end-of-utterance detection,
;; so segments only arrive when a real pause is detected.

;;; Code:

(require 'cmacs-audio)
(require 'cmacs-whisper)

(defgroup cmacs-whisper-dictate nil
  "Live dictation into the current buffer via whisper.cpp."
  :group 'cmacs-whisper
  :prefix "cmacs-whisper-dictate-")

(defcustom cmacs-whisper-dictate-window-seconds 3.0
  "Length (s) of each PCM window handed to whisper for transcription."
  :type 'number
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

(defvar-local cmacs-whisper-dictate--handle nil)
(defvar-local cmacs-whisper-dictate--timer  nil)
(defvar-local cmacs-whisper-dictate--state  'idle)   ; idle | recording | thinking
(defvar-local cmacs-whisper-dictate--target-buffer nil)
(defvar-local cmacs-whisper-dictate--target-marker nil)

(defun cmacs-whisper-dictate--mode-line-glyph ()
  (pcase cmacs-whisper-dictate--state
    ('recording " 🎤")
    ('thinking  " 🎤…")
    (_          "")))

(defun cmacs-whisper-dictate--maybe-command (text)
  "Run a registered voice command if TEXT matches one.  Return non-nil if matched."
  (let ((clean (downcase (string-trim text))))
    (catch 'matched
      (dolist (entry cmacs-whisper-dictate-command-words)
        (when (string= clean (car entry))
          (funcall (if (functionp (cdr entry)) (cdr entry)
                     (eval (cdr entry) t)))
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

(defun cmacs-whisper-dictate--on-result (result)
  "Callback after whisper finishes one window."
  (setq-local cmacs-whisper-dictate--state 'recording)
  (force-mode-line-update t)
  (let* ((text (cdr (assq :text result)))
         (err  (cdr (assq :error result))))
    (cond
     (err (message "cmacs-whisper-dictate: %s" err))
     ((null text) nil)
     ((string-empty-p (string-trim text)) nil)
     ((cmacs-whisper-dictate--maybe-command text) nil)
     (t (cmacs-whisper-dictate--insert text)))))

(defun cmacs-whisper-dictate--tick ()
  "Drain the capture buffer; if we have a full window, send to whisper."
  (when (and cmacs-whisper-dictate--handle
             (eq cmacs-whisper-dictate--state 'recording))
    (let* ((rate  cmacs-audio-default-rate)
           (need  (round (* rate cmacs-whisper-dictate-window-seconds)))
           (pcm   (cmacs-audio-read-pcm cmacs-whisper-dictate--handle need)))
      (when (and pcm (>= (length pcm) (* need 2)))
        (setq-local cmacs-whisper-dictate--state 'thinking)
        (force-mode-line-update t)
        (cmacs-whisper-transcribe-pcm-async
         (cmacs-whisper-model-path) pcm
         #'cmacs-whisper-dictate--on-result
         cmacs-whisper-language)))))

;;;###autoload
(defun cmacs-whisper-dictate ()
  "Toggle live dictation into the current buffer."
  (interactive)
  (cond
   (cmacs-whisper-dictate--handle
    ;; Stop.
    (when cmacs-whisper-dictate--timer
      (cancel-timer cmacs-whisper-dictate--timer))
    (cmacs-audio-close cmacs-whisper-dictate--handle)
    (setq-local cmacs-whisper-dictate--handle nil
                cmacs-whisper-dictate--state  'idle)
    (force-mode-line-update t)
    (message "cmacs-whisper-dictate: stopped"))
   (t
    (unless (file-exists-p (cmacs-whisper-model-path))
      (user-error "Whisper model not found: %s.  Run M-x cmacs-whisper-download-model"
                  (cmacs-whisper-model-path)))
    (setq-local cmacs-whisper-dictate--target-buffer (current-buffer))
    (setq-local cmacs-whisper-dictate--target-marker (point-marker))
    (set-marker-insertion-type cmacs-whisper-dictate--target-marker t)
    (setq-local cmacs-whisper-dictate--handle
                (cmacs-audio--capture-open-1
                 :source   cmacs-audio-capture-source
                 :rate     cmacs-audio-default-rate
                 :channels 1
                 :device   cmacs-audio-default-device))
    (cmacs-audio-start cmacs-whisper-dictate--handle)
    (setq-local cmacs-whisper-dictate--state 'recording)
    (setq-local cmacs-whisper-dictate--timer
                (run-with-timer cmacs-whisper-dictate-window-seconds
                                cmacs-whisper-dictate-window-seconds
                                #'cmacs-whisper-dictate--tick))
    (add-to-list 'mode-line-misc-info
                 '(:eval (cmacs-whisper-dictate--mode-line-glyph)) t)
    (force-mode-line-update t)
    (message "cmacs-whisper-dictate: recording (C-c v d to stop)"))))

;; C-c v d binding is installed via an autoload cookie below so it
;; works at startup BEFORE this file is loaded.  The cookie references
;; `cmacs-voice-map' which is itself autoload-cookied in cmacs-audio.el
;; -- loaddefs processes files alphabetically so the defvar lands
;; ahead of this define-key.
;;
;;;###autoload (define-key cmacs-voice-map (kbd "d") #'cmacs-whisper-dictate)

(provide 'cmacs-whisper-dictate)

;;; cmacs-whisper-dictate.el ends here
