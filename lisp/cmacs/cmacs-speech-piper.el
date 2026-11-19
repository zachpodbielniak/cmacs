;;; cmacs-speech-piper.el --- piper backend for cmacs-speech  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Adapts cmacs-piper (the piper subprocess) to the `cmacs-speech'
;; backend protocol: `tts' only, one whole utterance per call (piper
;; writes raw PCM when it is done, so there is nothing to stream).  The
;; sherpa backend runs the same Piper voices in-process and streams them;
;; this one stays as the fallback and for voices only piper has.

;;; Code:

(require 'cl-lib)
(require 'cmacs-speech)

(declare-function cmacs-piper--synth-async-1 "cmacs-piper-defuns.c")
(declare-function cmacs-piper-voice-path "cmacs-piper")
(declare-function cmacs-piper-list-voices "cmacs-piper")
(declare-function cmacs-piper--voice-sample-rate "cmacs-piper")
(defvar cmacs-piper-default-voice)
(defvar cmacs-voice-voice)

(defun cmacs-speech-piper-available-p ()
  "Non-nil when piper is compiled in and its binary runs."
  (and (fboundp 'cmacs-piper-supported-p)
       (ignore-errors (cmacs-piper-supported-p))
       (or (featurep 'cmacs-piper) (require 'cmacs-piper nil t))))

(defun cmacs-speech-piper--default-model (_component)
  "The piper voice used when none is named, if installed."
  (when (cmacs-speech-piper-available-p)
    (let ((want (or (and (boundp 'cmacs-voice-voice) cmacs-voice-voice)
                    cmacs-piper-default-voice))
          (voices (cmacs-piper-list-voices)))
      (if (member want voices) want (car voices)))))

(defun cmacs-speech-piper--synthesize (resolved text callback _chunk-fn)
  "Synthesise TEXT with piper; one result, no streaming."
  (let* ((voice (cmacs-piper-voice-path (plist-get resolved :model)))
         (token (list nil)))
    (cmacs-piper--synth-async-1
     voice text
     (lambda (result)
       (cond
        ((car token) (funcall callback '((:cancelled . t))))
        ((stringp result)
         (funcall callback (list (cons :pcm result)
                                 (cons :sample-rate (cmacs-piper--voice-sample-rate voice)))))
        (t
         ;; piper hands back either (:error . M) or ((:error . M)).
         (funcall callback
                  (list (cons :error (or (cdr-safe (assq :error (and (consp (car-safe result)) result)))
                                         (and (eq (car-safe result) :error) (cdr result))
                                         "speech synthesis failed"))))))))
    token))

(declare-function cmacs-piper--synth-sync-1 "cmacs-piper-defuns.c")

(defun cmacs-speech-piper--synthesize-now (resolved text)
  "Synthesise TEXT with piper, synchronously."
  (let ((voice (cmacs-piper-voice-path (plist-get resolved :model))))
    (list (cons :pcm (cmacs-piper--synth-sync-1 voice text))
          (cons :sample-rate (cmacs-piper--voice-sample-rate voice)))))

(cmacs-speech-define-backend
 'piper
 :label "piper"
 :components '(tts)
 :available-p (lambda (_c) (cmacs-speech-piper-available-p))
 :models (lambda (_c) (and (cmacs-speech-piper-available-p) (cmacs-piper-list-voices)))
 :default-model #'cmacs-speech-piper--default-model
 :describe (lambda ()
             (if (cmacs-speech-piper-available-p)
                 (format "piper subprocess, %d voices installed"
                         (length (cmacs-piper-list-voices)))
               "not available (configure --with-cmacs-piper; pip install piper-tts)"))
 :synthesize #'cmacs-speech-piper--synthesize
 :synthesize-now #'cmacs-speech-piper--synthesize-now
 ;; A piper process cannot be interrupted mid-utterance; cancelling
 ;; drops its result instead.
 :cancel (lambda (token) (setcar token t)))

(provide 'cmacs-speech-piper)
;;; cmacs-speech-piper.el ends here
