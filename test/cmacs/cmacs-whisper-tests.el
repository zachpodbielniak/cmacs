;;; cmacs-whisper-tests.el --- ERT for cmacs-whisper  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Most tests skip unless a whisper model file is present locally.

;;; Code:

(require 'ert)
(require 'cmacs)
(when (cmacs-feature-p 'whisper)
  (require 'cmacs-whisper))

(ert-deftest cmacs-whisper--supported ()
  (skip-unless (fboundp 'cmacs-whisper-supported-p))
  (should (cmacs-whisper-supported-p)))

(ert-deftest cmacs-whisper--system-info ()
  (skip-unless (cmacs-feature-p 'whisper))
  (should (eq t (cmacs-whisper-print-system-info))))

(ert-deftest cmacs-whisper--transcribe-fixture ()
  "Transcribe the JFK 5s fixture if both model and WAV are present."
  (skip-unless (cmacs-feature-p 'whisper))
  (let ((model (cmacs-whisper-model-path))
        (wav   (expand-file-name "fixtures/whisper-jfk-5s.wav"
                                 (file-name-directory
                                  (or load-file-name buffer-file-name)))))
    (skip-unless (and (file-exists-p model) (file-exists-p wav)))
    (let* ((res (cmacs-whisper-transcribe-file model wav "en"))
           (text (cdr (assq :text res))))
      (should (stringp text))
      (should (> (length text) 0)))))

(provide 'cmacs-whisper-tests)

;;; cmacs-whisper-tests.el ends here
