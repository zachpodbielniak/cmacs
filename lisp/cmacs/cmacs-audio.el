;;; cmacs-audio.el --- GStreamer audio capture/playback for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Lisp layer for the cmacs-audio C subsystem.  Wraps the underlying
;; DEFUNs (cmacs-audio--capture-open-1, cmacs-audio--playback-open-*,
;; etc.) with user-facing defcustoms, a mode-line indicator, the
;; standalone `cmacs-audio-mode' player, and the M-x entry points
;; bound under the shared `cmacs-voice-map' (C-c v).
;;
;; Audio capture defaults to 16 kHz mono S16LE — whisper.cpp-ready, so
;; PCM drained via `cmacs-audio-read-pcm' goes straight into
;; `cmacs-whisper-transcribe-pcm' without resampling.
;;
;; Companion files:
;;   cmacs-audio-org.el           #+BEGIN_AUDIO block parsing + record flow
;;   cmacs-audio-transcribe.el    auto whisper transcript subblocks
;;   cmacs-whisper.el             offline STT (separate subsystem)
;;   cmacs-piper.el               offline TTS  (separate subsystem)

;;; Code:

(require 'cl-lib)

(defgroup cmacs-audio nil
  "GStreamer-backed audio capture and playback."
  :group 'cmacs
  :prefix "cmacs-audio-")

;;;; ────────────────────── User-tunable knobs ──────────────────────

(defcustom cmacs-audio-capture-source 'auto
  "Default capture source kind.
`auto'      Prefer pipewiresrc, fall back to pulsesrc.
`pipewire'  Force pipewiresrc.
`pulse'     Force pulsesrc.
`coreaudio' macOS only.
`test'      Synthetic audiotestsrc (for tests)."
  :type '(choice (const auto) (const pipewire) (const pulse)
                 (const coreaudio) (const test))
  :group 'cmacs-audio)

(defcustom cmacs-audio-default-rate 16000
  "Default capture sample rate in Hz.
16000 matches whisper.cpp's expected input; bump to 44100/48000
for music capture if you do not need transcription."
  :type 'integer
  :group 'cmacs-audio)

(defcustom cmacs-audio-default-channels 1
  "Default number of capture channels (1 = mono, 2 = stereo)."
  :type 'integer
  :group 'cmacs-audio)

(defcustom cmacs-audio-default-device nil
  "Optional PipeWire / Pulse device hint.  Nil = system default."
  :type '(choice (const nil) string)
  :group 'cmacs-audio)

(defcustom cmacs-audio-output-dir
  (expand-file-name "Documents/notes/03_resources/cmacs-audio/" "~")
  "Directory where recorded WAV files and #+BEGIN_AUDIO sidecars live."
  :type 'directory
  :group 'cmacs-audio)

(defcustom cmacs-audio-mode-line-indicator t
  "Show a 🎤 / 🔊 indicator in the mode-line when streams are live."
  :type 'boolean
  :group 'cmacs-audio)

;;;; ────────────────────── State / mode line ──────────────────────

(defvar cmacs-audio--mode-line-state ""
  "Current contribution from cmacs-audio to `mode-line-misc-info'.")

(defun cmacs-audio--mode-line-update ()
  (let* ((live (and (fboundp 'cmacs-audio-list) (cmacs-audio-list)))
         (capturing 0) (playing 0))
    (dolist (h live)
      (let ((st (ignore-errors (cmacs-audio-state h))))
        (cond ((eq st 'playing) (cl-incf playing)))))
    (setq cmacs-audio--mode-line-state
          (cond ((and (zerop capturing) (zerop playing)) "")
                (t (format " [a:%d]" (+ capturing playing)))))
    (force-mode-line-update t)))

(when cmacs-audio-mode-line-indicator
  (unless (memq 'cmacs-audio--mode-line-state mode-line-misc-info)
    (add-to-list 'mode-line-misc-info '(:eval cmacs-audio--mode-line-state) t)))

;;;; ────────────────────── High-level wrappers ─────────────────────

(defvar cmacs-audio--pending-recording nil
  "Internal: (HANDLE . PATH) for the most recent open-ended recording.")

(defun cmacs-audio-record-to-file (path &optional seconds)
  "Capture PATH (WAV) for SECONDS (default: until M-x cmacs-audio-stop)."
  (interactive "FOutput WAV: \nP")
  (unless (file-directory-p (file-name-directory path))
    (make-directory (file-name-directory path) t))
  (let ((h (cmacs-audio--capture-open-1
            :source   cmacs-audio-capture-source
            :rate     cmacs-audio-default-rate
            :channels cmacs-audio-default-channels
            :device   cmacs-audio-default-device
            :level-meter nil)))
    (cmacs-audio-start h)
    (cmacs-audio--mode-line-update)
    (cond
     ((numberp seconds)
      (run-at-time seconds nil
                   (lambda ()
                     (cmacs-audio-write-file h path)
                     (cmacs-audio-close h)
                     (cmacs-audio--mode-line-update)
                     (message "cmacs-audio: wrote %s" path))))
     (t
      (message "cmacs-audio: recording -> %s (M-x cmacs-audio-finish-recording to stop)" path)
      (setq cmacs-audio--pending-recording (cons h path))))
    h))

(defun cmacs-audio-finish-recording ()
  "Finish the recording started by `cmacs-audio-record-to-file' (no SECONDS)."
  (interactive)
  (pcase cmacs-audio--pending-recording
    (`(,h . ,path)
     (cmacs-audio-write-file h path)
     (cmacs-audio-close h)
     (setq cmacs-audio--pending-recording nil)
     (cmacs-audio--mode-line-update)
     (message "cmacs-audio: wrote %s" path))
    (_ (user-error "cmacs-audio: no open recording"))))

(defun cmacs-audio-play-file (path)
  "Play audio file PATH (file://) on the default sink.  Returns handle."
  (interactive "fAudio file: ")
  (let* ((uri (if (string-match-p "\\`[a-z]+://" path)
                  path
                (concat "file://" (expand-file-name path))))
         (h (cmacs-audio--playback-open-file-1 uri)))
    (cmacs-audio-start h)
    (cmacs-audio--mode-line-update)
    h))

(defun cmacs-audio-stop-all ()
  "Close every live cmacs-audio stream."
  (interactive)
  (dolist (h (cmacs-audio-list))
    (ignore-errors (cmacs-audio-close h)))
  (cmacs-audio--mode-line-update))

;;;; ────────────────────── Standalone player mode ──────────────────

(defvar-local cmacs-audio-mode--handle nil)

(define-derived-mode cmacs-audio-mode special-mode "CmacsAudio"
  "Major mode for a single inline audio player."
  (setq cursor-type nil
        buffer-read-only t))

(define-key cmacs-audio-mode-map (kbd "SPC")
            (lambda ()
              (interactive)
              (when cmacs-audio-mode--handle
                (pcase (cmacs-audio-state cmacs-audio-mode--handle)
                  ('playing (cmacs-audio-pause cmacs-audio-mode--handle))
                  (_        (cmacs-audio-start cmacs-audio-mode--handle))))))
(define-key cmacs-audio-mode-map (kbd "q")
            (lambda () (interactive)
              (when cmacs-audio-mode--handle
                (ignore-errors (cmacs-audio-close cmacs-audio-mode--handle)))
              (kill-buffer)))

(defun cmacs-audio-open-buffer (path)
  "Open PATH in a new cmacs-audio-mode buffer."
  (interactive "fAudio file: ")
  (let ((buf (generate-new-buffer
              (format "*cmacs-audio: %s*" (file-name-nondirectory path)))))
    (with-current-buffer buf
      (cmacs-audio-mode)
      (let ((inhibit-read-only t))
        (insert (format "Audio: %s\nSPC play/pause   q quit\n" path)))
      (setq cmacs-audio-mode--handle (cmacs-audio-play-file path)))
    (pop-to-buffer buf)
    buf))

;;;; ────────────────────── Shared voice keymap ─────────────────────
;;
;; All voice keys live under the `cmacs-voice-map' prefix bound to
;; `C-c v' globally.  The defvar + the prefix install + every binding
;; carry `;;;###autoload' cookies so the keymap exists in `loaddefs.el'
;; and is wired into `global-map' at Emacs startup -- BEFORE any
;; cmacs-audio / -whisper / -piper command has run.  That makes
;; `C-c v d', `C-c v s', etc. work the very first time you press
;; them, without first having to `M-x cmacs-whisper-dictate' (or
;; similar) to trigger the file load.
;;
;; The autoload-cookie forms in cmacs-whisper-dictate.el and
;; cmacs-piper.el reference `cmacs-voice-map' the same way; loaddefs
;; processes files alphabetically so this defvar lands first.

;;;###autoload
(defvar cmacs-voice-map (make-sparse-keymap)
  "Shared keymap for cmacs voice features (audio + whisper + piper).
Bound to `C-c v' globally.")

;;;###autoload (define-key global-map (kbd "C-c v") cmacs-voice-map)

;;;###autoload (define-key cmacs-voice-map (kbd "r") #'cmacs-audio-record-to-file)
;;;###autoload (define-key cmacs-voice-map (kbd "R") #'cmacs-audio-finish-recording)
;;;###autoload (define-key cmacs-voice-map (kbd "p") #'cmacs-audio-play-file)
;;;###autoload (define-key cmacs-voice-map (kbd "x") #'cmacs-audio-stop-all)

;;;; ────────────────────── Lifecycle hooks ─────────────────────────

(add-hook 'kill-emacs-hook
          (lambda ()
            (when (fboundp 'cmacs-audio-list)
              (dolist (h (cmacs-audio-list))
                (ignore-errors (cmacs-audio-close h))))))

(provide 'cmacs-audio)

;;; cmacs-audio.el ends here
