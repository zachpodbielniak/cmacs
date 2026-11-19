;;; speech-engine.el --- headless scenario: the sherpa engine is in  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase-1 proof: the sherpa-onnx engine is linked, reports its version
;; and onnxruntime, lists its kinds and config keys, and whisper and
;; piper are still there beside it.

;;; Code:

(cmacs-headless-steps
 (lambda ()
   (switch-to-buffer (get-buffer-create "*sherpa engine*"))
   (erase-buffer)
   (insert (propertize "cmacs speech engines\n\n" 'face '(:height 1.6 :weight bold)))
   (insert (format "IS-CMACS-SHERPA   %S\n" IS-CMACS-SHERPA))
   (insert (format "IS-CMACS-WHISPER  %S\n" IS-CMACS-WHISPER))
   (insert (format "IS-CMACS-PIPER    %S\n\n" IS-CMACS-PIPER))
   (insert (format "(cmacs-sherpa-version)              => %S\n"
                   (cmacs-sherpa-version)))
   (insert (format "(cmacs-sherpa-onnxruntime-version)  => %S\n\n"
                   (cmacs-sherpa-onnxruntime-version)))
   (insert "(cmacs-sherpa-kinds)\n")
   (dolist (k (cmacs-sherpa-kinds))
     (insert (format "  %-15s %3d config keys\n" k
                     (length (cmacs-sherpa-config-keys k)))))
   (insert "\n(cmacs-sherpa-config-keys 'vad)\n")
   (dolist (k (cmacs-sherpa-config-keys 'vad))
     (insert (format "  %-38s %s\n" (car k) (cdr k))))
   (goto-char (point-min))
   nil)
 (lambda () (cmacs-headless-shot "phase1-sherpa-engine") nil))

;;; speech-engine.el ends here
