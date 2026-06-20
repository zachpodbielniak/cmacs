;;; cmacs-piper-tests.el --- ERT for cmacs-piper  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Skips unless a Piper voice file is present locally.

;;; Code:

(require 'ert)
(require 'cl-lib)               ; cl-some, cl-letf
(require 'cmacs)
(when (cmacs-feature-p 'piper)
  (require 'cmacs-piper)
  (require 'cmacs-piper-context-menu))

(ert-deftest cmacs-piper--supported-matches-feature ()
  (skip-unless (fboundp 'cmacs-piper-supported-p))
  (should (eq (cmacs-feature-p 'piper)
              (and (cmacs-piper-supported-p) t))))

(ert-deftest cmacs-piper--synth-roundtrip ()
  "End-to-end: piper TTS -> PCM bytes -> playback handle opens."
  (skip-unless (cmacs-feature-p 'piper))
  (skip-unless (file-exists-p (cmacs-piper-voice-path)))
  ;; End-to-end synth needs a functional piper runtime (onnxruntime shader
  ;; cache, espeak-ng data, a writable HOME).  Skip when it can't initialise
  ;; -- e.g. the test harness pins HOME=/nonexistent -- rather than failing.
  (let ((pcm (condition-case nil
                 (cmacs-piper--synth-sync-1
                  (cmacs-piper-voice-path) "Hello, cmacs.")
               (cmacs-piper-error 'unavailable))))
    (skip-unless (not (eq pcm 'unavailable)))
    (should (stringp pcm))
    (should (> (length pcm) 0))))

(ert-deftest cmacs-piper--context-menu-entry ()
  "Context menu hook produces a menu containing a Speak entry when there's a region."
  (skip-unless (cmacs-feature-p 'piper))
  (with-temp-buffer
    (insert "hello world")
    (set-mark (point-min))
    (goto-char (point-max))
    (activate-mark)
    (let ((menu (make-sparse-keymap)))
      ;; Entries are only built on a graphic display; force it so the
      ;; menu-construction logic runs under batch ERT (no display).
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
        (cmacs-piper-context-menu-entry menu nil))
      ;; Check the menu has a binding labelled "Speak …"
      (should (cl-some
               (lambda (binding)
                 (and (consp binding)
                      (consp (cdr binding))
                      (eq (cadr binding) 'menu-item)
                      (stringp (nth 2 binding))
                      (string-match-p "Speak" (nth 2 binding))))
               (cdr menu))))))

(provide 'cmacs-piper-tests)

;;; cmacs-piper-tests.el ends here
