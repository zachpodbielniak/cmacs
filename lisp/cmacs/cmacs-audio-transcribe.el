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
  "Transcribe WAV at PATH and insert a folded transcript block after BEG.
The engine is the one \[cmacs-speech] picks for `audio-org'."
  (when (and cmacs-audio-transcribe-auto
             (require 'cmacs-speech nil t)
             (cmacs-speech-can-p 'stt 'audio-org :transcribe))
    (let ((buf (current-buffer))
          (beg (copy-marker beg)))
      (cmacs-speech-transcribe-file
       path
       (lambda (result)
         (let ((text (cdr (assq :text result))))
           ;; The answer arrives later, from a timer: insert into the
           ;; buffer that asked, wherever the user is now.
           (when (and text (buffer-live-p buf))
             (with-current-buffer buf
               (save-excursion
                 (goto-char beg)
                 (forward-line)
                 (insert
                  (format "#+BEGIN_AUDIO_TRANSCRIPT\n%s\n#+END_AUDIO_TRANSCRIPT\n"
                          text))
                 (when (derived-mode-p 'org-mode)
                   (forward-line -2)
                   (when (fboundp 'org-cycle) (org-cycle))))))
           (set-marker beg nil)))
       :feature 'audio-org :component 'stt
       :language (bound-and-true-p cmacs-whisper-language)))))

(provide 'cmacs-audio-transcribe)

;;; cmacs-audio-transcribe.el ends here
