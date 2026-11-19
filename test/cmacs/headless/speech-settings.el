;;; speech-settings.el --- headless scenario: M-x cmacs-speech  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase-5 screenshots: the settings buffer with its sections, a model
;; downloading with live progress, a mic-free round-trip test of a
;; recognizer row, the benchmark, and the transient.  Choices go to a
;; private state file so the run never touches the user's.

;;; Code:

(require 'cmacs-speech-ui)
(setq cmacs-speech-state-file
      (expand-file-name (make-temp-name "speech-state-") temporary-file-directory)
      cmacs-speech--ui nil
      cmacs-speech--ui-loaded nil)
(set-face-attribute 'default nil :height 105)

(defun speech-shot--goto (re &optional line)
  "Put point (and the window) on the first line matching RE.
LINE is where that line should sit in the window (default 3)."
  (goto-char (point-min))
  (re-search-forward re)
  (beginning-of-line)
  (set-window-point (selected-window) (point))
  (recenter (or line 3)))

(let (job)
  (cmacs-headless-steps
   (lambda ()
     (cmacs-speech)
     (delete-other-windows)
     ;; Features and the rest start folded; show Components and Models.
     nil)
   (lambda () (cmacs-headless-shot "phase5-01-settings") nil)
   ;; A small real download: progress bar, speed, then installed.
   (lambda ()
     ;; Repeatable: the demo model goes to the trash first if a previous
     ;; run installed it.
     (when (cmacs-speech-models-installed-path 'sherpa "sherpa-onnx-moonshine-base-en-int8")
       (cmacs-speech-models-delete 'sherpa "sherpa-onnx-moonshine-base-en-int8")
       (cmacs-speech-ui--render))
     (speech-shot--goto "^    . sherpa-onnx-moonshine-base-en-int8" 8)
     (setq job (cmacs-speech-models-download
                (cmacs-speech-models-entry 'sherpa "sherpa-onnx-moonshine-base-en-int8")))
     nil)
   (lambda ()
     (if (< (cmacs-speech-models-job-bytes job) 50000000) 'wait
       (cmacs-speech-ui--render)
       (speech-shot--goto "^    . sherpa-onnx-moonshine-base-en-int8" 8)
       (cmacs-headless-log "jobs: %S"
                           (mapcar (lambda (j) (list (cmacs-speech-models-job-id j)
                                                     (cmacs-speech-models-job-state j)
                                                     (cmacs-speech-models-job-bytes j)
                                                     (cmacs-speech-models-job-total j)))
                                   cmacs-speech-models--jobs))
       (cmacs-headless-log "row: %s" (buffer-substring-no-properties
                                      (line-beginning-position) (line-end-position)))
       (cmacs-headless-shot "phase5-02-downloading")
       nil))
   (lambda ()
     ;; The point was the progress bar: cancel, and drop the .part.
     (cmacs-speech-models-cancel "sherpa-onnx-moonshine-base-en-int8")
     (when (file-exists-p (cmacs-speech-models-job-part job))
       (delete-file (cmacs-speech-models-job-part job)))
     (progn
       (cmacs-speech-ui--render)
       (speech-shot--goto "^▾ Components" 0)
       nil))
   ;; Try stt-live: TTS says a sentence, the recognizer hears it.
   (lambda ()
     (speech-shot--goto "^  stt-live ")
     (cmacs-speech-ui-try)
     nil)
   (lambda ()
     (if (not (string-match-p "heard" (or (alist-get 'stt-live cmacs-speech-ui--notes) "")))
         'wait
       nil))
   ;; And switch stt to sherpa moonshine for this run (private state).
   (lambda ()
     (cmacs-speech-ui-set 'stt 'sherpa :model "sherpa-onnx-moonshine-tiny-en-int8")
     (speech-shot--goto "^  stt ")
     (cmacs-speech-ui-try)
     nil)
   (lambda ()
     (if (not (string-match-p "heard" (or (alist-get 'stt cmacs-speech-ui--notes) "")))
         'wait
       (cmacs-speech-ui--render)
       (speech-shot--goto "^▾ Components" 0)
       (cmacs-headless-shot "phase5-03-try-rows")
       nil))
   ;; The bench: every installed recognizer on the same synthetic clip.
   (lambda ()
     (setq cmacs-clawtilla-ui--folded
           (delete (cmacs-clawtilla-ui--identity 'section 'bench) cmacs-clawtilla-ui--folded))
     (cmacs-speech-ui-bench)
     nil)
   (lambda ()
     (if (or (null cmacs-speech-ui--bench)
             (cl-some (lambda (b) (not (or (plist-get b :secs) (plist-get b :error))))
                      cmacs-speech-ui--bench))
         'wait
       (cmacs-speech-ui--render)
       (speech-shot--goto "^▾ Bench" 2)
       (cmacs-headless-shot "phase5-04-bench")
       nil))
   (lambda ()
     (speech-shot--goto "^▾ Components" 0)
     (cmacs-speech-ui-dispatch)
     nil)
   (lambda () (cmacs-headless-shot "phase5-05-transient") nil)))

;;; speech-settings.el ends here
