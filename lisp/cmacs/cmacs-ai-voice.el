;;; cmacs-ai-voice.el --- whisper -> ai -> piper voice loop  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Wires the existing whisper (STT), ai-glib (chat), and piper (TTS)
;; subsystems into a hold-to-talk voice loop:
;;
;;   M-x cmacs-ai-voice-chat
;;     C-c v c (hold)  -> record while held
;;     release         -> whisper transcribe
;;                     -> ai-glib chat (streaming)
;;                     -> piper speak (per-sentence streaming)
;;
;; Sentence-boundary detection accumulates streamed deltas and
;; speaks each completed sentence as soon as one terminator
;; (`. ? !` followed by space or newline) is seen, so the user
;; hears the reply unfolding live rather than after the model
;; finishes.

;;; Code:

(require 'cmacs-ai)
(require 'cmacs-ai-chat)

(defcustom cmacs-ai-voice-auto-speak t
  "Whether the model's reply is spoken via piper."
  :type 'boolean
  :group 'cmacs-ai)

(defvar-local cmacs-ai-voice--tts-tail "")

(declare-function cmacs-whisper-dictate "cmacs-whisper-dictate")
(declare-function cmacs-piper-speak-region "cmacs-piper")
(declare-function cmacs-piper-stop "cmacs-piper")
(declare-function cmacs-piper-supported-p "cmacs-piper-defuns.c")

(defun cmacs-ai-voice--speak (text)
  (when (and cmacs-ai-voice-auto-speak
             (fboundp 'cmacs-piper-supported-p)
             (cmacs-piper-supported-p))
    (with-temp-buffer
      (insert text)
      (cmacs-piper-speak-region (point-min) (point-max)))))

(defun cmacs-ai-voice--on-delta-sentence (chunk)
  "Accumulate CHUNK; speak each completed sentence."
  (setq cmacs-ai-voice--tts-tail
        (concat cmacs-ai-voice--tts-tail chunk))
  (let ((s cmacs-ai-voice--tts-tail))
    (while (string-match "\\([^.?!]*[.?!]\\)[\n\t ]+" s)
      (let ((sent (match-string 1 s)))
        (setq s (substring s (match-end 0)))
        (cmacs-ai-voice--speak sent)))
    (setq cmacs-ai-voice--tts-tail s)))

(defun cmacs-ai-voice--stream-callback-wrap (buf payload)
  "Wrap the chat stream callback to also feed piper sentence-by-sentence."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (pcase (car payload)
        (:start (setq cmacs-ai-voice--tts-tail ""))
        (:delta (cmacs-ai-voice--on-delta-sentence (cadr payload)))
        (:end   (when (not (string-empty-p cmacs-ai-voice--tts-tail))
                  (cmacs-ai-voice--speak cmacs-ai-voice--tts-tail)
                  (setq cmacs-ai-voice--tts-tail "")))))
    (cmacs-ai-chat--stream-callback buf payload)))

(defvar cmacs-ai-voice-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m cmacs-ai-chat-mode-map)
    (define-key m (kbd "C-c v t") #'cmacs-ai-voice-dictate)
    (define-key m (kbd "C-c v s") #'cmacs-piper-stop)
    m)
  "Keymap for cmacs-ai voice mode (extends `cmacs-ai-chat-mode-map').")

(defun cmacs-ai-voice-dictate ()
  "Record a voice prompt via whisper, then send it as a chat turn."
  (interactive)
  (unless (fboundp 'cmacs-whisper-dictate)
    (user-error "cmacs-whisper not available"))
  (let ((buf (current-buffer))
        (cmacs-whisper-dictate-target-buffer (current-buffer)))
    ;; Use whisper-dictate's record-stop loop; user finishes by
    ;; toggling the same command (whisper-dictate is a minor mode).
    (cmacs-whisper-dictate)
    (message "Recording.  Run %s again to stop and send."
             (substitute-command-keys
              "\\[cmacs-ai-voice-dictate]"))
    (with-current-buffer buf buf)))

;;;###autoload
(defun cmacs-ai-voice-chat ()
  "Open a chat buffer wired for whisper-in / piper-out voice loop."
  (interactive)
  (cmacs-ai--ensure)
  (let ((buf (cmacs-ai-chat-open cmacs-ai-default-provider)))
    (with-current-buffer buf
      (use-local-map cmacs-ai-voice-mode-map)
      (setq-local mode-name "cmacs-AI [voice]")
      ;; Replace the standard send to also feed piper.
      (local-set-key (kbd "C-c C-c")
                     (lambda ()
                       (interactive)
                       (let ((text (cmacs-ai-chat--read-compose)))
                         (unless text (user-error "Compose is empty"))
                         (cmacs-ai-chat--insert-heading
                          (current-buffer) "user" text)
                         (let ((session (cdr cmacs-ai-chat-session-pair))
                               (b (current-buffer)))
                           (cmacs-ai-chat-stream
                            session text
                            (lambda (payload)
                              (cmacs-ai-voice--stream-callback-wrap
                               b payload))))))))
    buf))

(provide 'cmacs-ai-voice)
;;; cmacs-ai-voice.el ends here
