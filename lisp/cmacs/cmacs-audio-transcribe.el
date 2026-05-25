;;; cmacs-audio-transcribe.el --- Auto-transcript subblocks for #+BEGIN_AUDIO  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; When `cmacs-whisper' is built, this module inserts a folded
;; `#+BEGIN_AUDIO_TRANSCRIPT' child block under each finalised
;; `#+BEGIN_AUDIO'.  Loaded by `cmacs-audio-org.el' iff
;; `(featurep 'cmacs-whisper)' is true at load time.

;;; Code:

(require 'cmacs-audio)

(defcustom cmacs-audio-transcribe-auto t
  "When non-nil, auto-transcribe new `#+BEGIN_AUDIO' blocks."
  :type 'boolean
  :group 'cmacs-audio)

(defun cmacs-audio-transcribe-block-at (beg path)
  "Transcribe WAV at PATH and insert a folded transcript block after BEG."
  (when (and (featurep 'cmacs-whisper)
             cmacs-audio-transcribe-auto
             (fboundp 'cmacs-whisper-transcribe-async))
    (cmacs-whisper-transcribe-async
     (cmacs-whisper-model-path) path
     (lambda (result)
       (let ((text (cdr (assq :text result))))
         (when text
           (save-excursion
             (goto-char beg)
             (forward-line)
             (insert
              (format "#+BEGIN_AUDIO_TRANSCRIPT\n%s\n#+END_AUDIO_TRANSCRIPT\n"
                      text))
             (when (derived-mode-p 'org-mode)
               (forward-line -2)
               (when (fboundp 'org-cycle) (org-cycle)))))))
     cmacs-whisper-language)))

(provide 'cmacs-audio-transcribe)

;;; cmacs-audio-transcribe.el ends here
