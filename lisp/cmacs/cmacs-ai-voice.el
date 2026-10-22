;;; cmacs-ai-voice.el --- whisper -> ai -> piper voice loop  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Wires the existing whisper (STT), ai-glib (chat), and piper (TTS)
;; subsystems into a push-to-talk voice chat:
;;
;;   M-x cmacs-ai-voice-chat
;;     C-c v c         -> start recording
;;     C-c v c again   -> whisper transcribe
;;                     -> ai-glib chat (streaming)
;;                     -> piper speak (per-sentence streaming)
;;
;; (Emacs cannot see a key being held, so "hold to talk" is a toggle on
;; the keyboard; in VR, holding a controller button is the real thing,
;; see cmacs-lrg-vr-voice.el.)
;;
;; Sentence-boundary detection accumulates streamed deltas and
;; speaks each completed sentence as soon as one terminator
;; (`. ? !` followed by space or newline) is seen, so the user
;; hears the reply unfolding live rather than after the model
;; finishes.
;;
;; Recording and speech both go through the shared voice engine
;; (cmacs-voice.el): the recording takes the microphone from the
;; always-on loop for its length, and the sentences join one speech
;; queue, synthesised one at a time.  That queue is what fixed this
;; file's old habit of speaking sentences out of order -- each sentence
;; used to be its own piper job, and a short one could finish first.
;;
;; For hands-free conversation -- always listening, a wake word,
;; partial transcripts, talking over the reply -- see
;; `cmacs-voice-loop-mode' (cmacs-voice-loop.el).  Turned on from a
;; voice chat buffer (C-c v l there) it adopts that buffer.

;;; Code:

(require 'cmacs-ai)
(require 'cmacs-ai-chat)
(require 'cmacs-voice)

(defcustom cmacs-ai-voice-auto-speak t
  "Whether the model's reply is spoken via piper."
  :type 'boolean
  :group 'cmacs-ai)

(defcustom cmacs-ai-voice-max-seconds 120
  "Longest prompt recorded before recording stops (and sends) on its own."
  :type 'number
  :group 'cmacs-ai)

(defvar-local cmacs-ai-voice--tts-tail "")

(defvar cmacs-ai-voice--target nil
  "The voice chat buffer the recording in progress will be sent to.")

(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(declare-function cmacs-voice-loop-mode "cmacs-voice-loop" (&optional arg))

(defun cmacs-ai-voice--speak (text)
  "Queue TEXT on the engine's speech queue, when replies are spoken."
  (when cmacs-ai-voice-auto-speak
    (cmacs-voice-speak text)))

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

(defun cmacs-ai-voice-send (text &optional buffer)
  "Send TEXT as a turn of voice chat BUFFER (default: current) and speak the reply."
  (with-current-buffer (or buffer (current-buffer))
    (cmacs-ai-chat--insert-heading (current-buffer) "user" text)
    (let ((session (cdr cmacs-ai-chat-session-pair))
          (b (current-buffer)))
      (cmacs-ai-chat-stream
       session text
       (lambda (payload)
         (cmacs-ai-voice--stream-callback-wrap b payload))))))

(defun cmacs-ai-voice-send-compose ()
  "Send the compose region as a voice turn: the reply is spoken."
  (interactive)
  (let ((text (cmacs-ai-chat--read-compose)))
    (unless text (user-error "Compose is empty"))
    (cmacs-ai-voice-send text)))

(defun cmacs-ai-voice-recording-p ()
  "Non-nil while a spoken prompt is being recorded."
  (cmacs-voice-ptt-active-p 'ai-voice))

(defun cmacs-ai-voice--finish ()
  "Stop recording; transcribe and send what was said."
  (let ((pcm (cmacs-voice-ptt-stop 'ai-voice))
        (buf cmacs-ai-voice--target))
    (setq cmacs-ai-voice--target nil)
    (if (< (length pcm) 3200)
        (progn (fillarray pcm 0)
               (message "Voice: heard nothing"))
      (message "Voice: transcribing...")
      (cmacs-voice-transcribe
       pcm
       (lambda (result)
         (let ((err (cdr (assq :error result)))
               (text (cmacs-voice-clean (cdr (assq :text result)))))
           (cond
            (err (message "Voice: %s" err))
            ((string-empty-p text) (message "Voice: heard nothing"))
            ((not (buffer-live-p buf)) (message "Voice: the chat is gone"))
            (t (message "%s" text)
               (cmacs-ai-voice-send text buf)))))))))

(defun cmacs-ai-voice-dictate ()
  "Record a voice prompt via whisper, then send it as a chat turn.
Run once to start recording and again to stop: what you said is
transcribed and sent, and the reply is spoken.  Recording also stops
on its own after `cmacs-ai-voice-max-seconds'."
  (interactive)
  (unless (cmacs-voice-available-p)
    (user-error "cmacs-whisper not available"))
  (if (cmacs-ai-voice-recording-p)
      (cmacs-ai-voice--finish)
    (unless (file-exists-p (cmacs-whisper-model-path))
      (user-error "Whisper model not found: M-x cmacs-whisper-download-model"))
    (setq cmacs-ai-voice--target (current-buffer))
    (cmacs-voice-ptt-start 'ai-voice
                           :max-seconds cmacs-ai-voice-max-seconds
                           :on-timeout #'cmacs-ai-voice--finish)
    (message "Recording.  Run %s again to stop and send."
             (substitute-command-keys "\\[cmacs-ai-voice-dictate]"))))

(defalias 'cmacs-ai-voice-talk #'cmacs-ai-voice-dictate)

(defvar cmacs-ai-voice-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m cmacs-ai-chat-mode-map)
    (define-key m (kbd "C-c C-c") #'cmacs-ai-voice-send-compose)
    (define-key m (kbd "C-c v c") #'cmacs-ai-voice-dictate)
    (define-key m (kbd "C-c v t") #'cmacs-ai-voice-dictate)
    (define-key m (kbd "C-c v s") #'cmacs-voice-stop-speaking)
    (define-key m (kbd "C-c v l") #'cmacs-voice-loop-mode)
    m)
  "Keymap for cmacs-ai voice mode (extends `cmacs-ai-chat-mode-map').")

;;;###autoload
(defun cmacs-ai-voice-chat ()
  "Open a chat buffer wired for whisper-in / piper-out voice loop."
  (interactive)
  (cmacs-ai--ensure)
  (let ((buf (cmacs-ai-chat-open cmacs-ai-default-provider)))
    (with-current-buffer buf
      (use-local-map cmacs-ai-voice-mode-map)
      (setq-local mode-name "cmacs-AI [voice]"))
    buf))

(provide 'cmacs-ai-voice)
;;; cmacs-ai-voice.el ends here
