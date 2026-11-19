;;; cmacs-speech-whisper.el --- whisper.cpp backend for cmacs-speech  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Adapts cmacs-whisper (whisper.cpp) to the `cmacs-speech' backend
;; protocol: `stt' and `stt-live' through the async PCM transcriber
;; (exact segment timestamps, context carried past 30 s -- still the
;; best engine for batch transcription), and `vad' through whisper.cpp's
;; Silero VAD.  It calls exactly what cmacs-voice called before the
;; speech layer existed, so a setup that resolves everything to whisper
;; behaves as it always did.
;;
;; whisper has no streaming recognizer and no keyword spotter: those
;; components are not offered, and their callers keep their own
;; whisper-based fallbacks (windowed partials, wake-phrase text match).

;;; Code:

(require 'cl-lib)
(require 'cmacs-speech)

(declare-function cmacs-whisper-transcribe-pcm-async "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-vad-open "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-vad-feed "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-vad-close "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-pcm-resample "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-model-path "cmacs-whisper")
(declare-function cmacs-whisper-list-models "cmacs-whisper")
(defvar cmacs-whisper-default-model)
(defvar cmacs-whisper-default-vad-model)
(defvar cmacs-whisper-language)
(defvar cmacs-voice-threads)
(defvar cmacs-voice-vad-model)

(defun cmacs-speech-whisper-available-p ()
  "Non-nil when whisper.cpp is compiled in."
  (and (fboundp 'cmacs-whisper-supported-p)
       (or (featurep 'cmacs-whisper) (require 'cmacs-whisper nil t))))

(defun cmacs-speech-whisper--vad-file-p (name)
  "Non-nil when model file NAME is a VAD model, not a recognizer."
  (string-match-p "silero\\|vad" name))

(defun cmacs-speech-whisper--models (component)
  "Installed whisper model files serving COMPONENT."
  (when (cmacs-speech-whisper-available-p)
    (let ((all (cmacs-whisper-list-models)))
      (if (eq component 'vad)
          (cl-remove-if-not #'cmacs-speech-whisper--vad-file-p all)
        (cl-remove-if #'cmacs-speech-whisper--vad-file-p all)))))

(defun cmacs-speech-whisper--default-model (component)
  "The whisper model used for COMPONENT when none is named, if installed."
  (when (cmacs-speech-whisper-available-p)
    (let* ((want (if (eq component 'vad)
                     (or (and (boundp 'cmacs-voice-vad-model) cmacs-voice-vad-model)
                         cmacs-whisper-default-vad-model)
                   cmacs-whisper-default-model))
           (models (cmacs-speech-whisper--models component)))
      (cond ((member want models) want)
            ;; The VAD is optional: no model means the energy detector.
            ((eq component 'vad) nil)
            (t (car models))))))

(defun cmacs-speech-whisper--path (resolved)
  "Absolute model file for RESOLVED."
  (let ((m (plist-get resolved :model)))
    (if (and m (file-name-absolute-p m)) m (cmacs-whisper-model-path m))))

(defun cmacs-speech-whisper--transcribe (resolved pcm rate callback)
  "Transcribe PCM (at RATE) with whisper.cpp."
  ;; whisper.cpp wants 16 kHz.
  (when (and rate (/= rate 16000))
    (setq pcm (cmacs-whisper-pcm-resample pcm rate 16000)))
  (cmacs-whisper-transcribe-pcm-async
   (cmacs-speech-whisper--path resolved) pcm callback
   (or (cmacs-speech-option resolved :language)
       (and (boundp 'cmacs-whisper-language) cmacs-whisper-language))
   (or (cmacs-speech-option resolved :threads)
       (and (boundp 'cmacs-voice-threads) cmacs-voice-threads))))

(declare-function cmacs-whisper-transcribe-pcm "cmacs-whisper-defuns.c")

(defun cmacs-speech-whisper--transcribe-now (resolved pcm rate)
  "Transcribe PCM synchronously with whisper.cpp."
  (when (and rate (/= rate 16000))
    (setq pcm (cmacs-whisper-pcm-resample pcm rate 16000)))
  (cmacs-whisper-transcribe-pcm
   (cmacs-speech-whisper--path resolved) pcm
   (or (cmacs-speech-option resolved :language)
       (and (boundp 'cmacs-whisper-language) cmacs-whisper-language))
   (or (cmacs-speech-option resolved :threads)
       (and (boundp 'cmacs-voice-threads) cmacs-voice-threads))))

(defun cmacs-speech-whisper--vad-open (resolved)
  "Open whisper.cpp's Silero VAD for RESOLVED."
  (let ((p (cmacs-speech-whisper--path resolved)))
    (and (file-exists-p p) (cmacs-whisper-vad-open p))))

(defun cmacs-speech-whisper--describe ()
  "Version line for the settings buffer."
  (if (cmacs-speech-whisper-available-p)
      (format "whisper.cpp (ggml, CPU), %d models installed"
              (length (cmacs-whisper-list-models)))
    "not built in (configure --with-cmacs-whisper)"))

(cmacs-speech-define-backend
 'whisper
 :label "whisper.cpp"
 :components '(stt stt-live vad)
 :available-p (lambda (_c) (cmacs-speech-whisper-available-p))
 :models #'cmacs-speech-whisper--models
 :default-model #'cmacs-speech-whisper--default-model
 :describe #'cmacs-speech-whisper--describe
 :transcribe #'cmacs-speech-whisper--transcribe
 :transcribe-now #'cmacs-speech-whisper--transcribe-now
 :vad-open #'cmacs-speech-whisper--vad-open
 :vad-feed #'cmacs-whisper-vad-feed
 :vad-close #'cmacs-whisper-vad-close)

(provide 'cmacs-speech-whisper)
;;; cmacs-speech-whisper.el ends here
