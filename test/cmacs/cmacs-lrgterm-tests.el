;;; cmacs-lrgterm-tests.el --- ERT tests for output_lrg  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the independent libregnum/raylib display backend (output_lrg).
;;
;; Two tiers:
;;  - Presence tests run on any build with --with-cmacs-lrgterm (the `lrg'
;;    feature is provided at dump time), even under -batch / a non-lrg frame.
;;  - "Live" tests need an actual output_lrg frame and so `skip-unless' the
;;    selected frame's window-system is `lrg'.  Run them with:
;;        emacs --lrg -batch -l ert -l test/cmacs/cmacs-lrgterm-tests.el \
;;              -f ert-run-tests-batch-and-exit
;;    (or `make -C test check-cmacs TESTS=cmacs-lrgterm-tests' started under
;;    --lrg).  In the ordinary batch suite the live tests are skipped.
;;
;; Everything skips cleanly when the backend was not compiled in.

;;; Code:

(require 'ert)

(defun cmacs-lrgterm-tests--built-p ()
  "Non-nil when the output_lrg backend is compiled into this Emacs."
  (and (featurep 'lrg) (fboundp 'lrg-create-frame)))

(defun cmacs-lrgterm-tests--live-p ()
  "Non-nil when the selected frame is an output_lrg frame."
  (eq (framep-on-display) 'lrg))

;;;; Presence -----------------------------------------------------------

(ert-deftest cmacs-lrgterm-feature-provided ()
  "The `lrg' feature is provided by syms_of_cmacs_lrgterm."
  (skip-unless (cmacs-lrgterm-tests--built-p))
  (should (featurep 'lrg)))

(ert-deftest cmacs-lrgterm-defuns-present ()
  "The lrg C DEFUNs are defined."
  (skip-unless (cmacs-lrgterm-tests--built-p))
  (dolist (fn '(lrg-create-frame lrg-open-connection lrg-capture-screen
                lrg-display-pixel-size lrg-set-clipboard lrg-get-clipboard))
    (should (fboundp fn))))

(ert-deftest cmacs-lrgterm-win-support-loaded ()
  "lisp/term/lrg-win.el is loaded and registers a frame-creation method."
  (skip-unless (cmacs-lrgterm-tests--built-p))
  (should (or (featurep 'term/lrg-win) (featurep 'lrg-win)))
  ;; cl-generic method specialised on (window-system lrg) is installed.
  (should (boundp 'cmacs-lrg-render-mode)))

(ert-deftest cmacs-lrgterm-render-mode-default ()
  "The render mode defaults to 2d; only 2d/3d/3dvr are accepted tokens."
  (skip-unless (cmacs-lrgterm-tests--built-p))
  (should (member cmacs-lrg-render-mode '("2d" "3d" "3dvr")))
  (should (equal cmacs-lrg-render-mode "2d")))

;;;; Live (need an actual lrg frame) ------------------------------------

(ert-deftest cmacs-lrgterm-window-system ()
  "On an lrg frame `(window-system)' is `lrg'."
  (skip-unless (cmacs-lrgterm-tests--live-p))
  (should (eq (window-system) 'lrg)))

(ert-deftest cmacs-lrgterm-display-is-graphic-colour ()
  "An lrg frame is a graphical, truecolor display."
  (skip-unless (cmacs-lrgterm-tests--live-p))
  (should (display-graphic-p))
  (should (display-color-p))
  (should (>= (display-color-cells) 88))   ; gates the `(min-colors 88)' faces
  (should (eq (display-visual-class) 'true-color))
  (should (= (display-planes) 24)))

(ert-deftest cmacs-lrgterm-default-face-realises-colour ()
  "The default face resolves to a real monospace font, not the tty fallback."
  (skip-unless (cmacs-lrgterm-tests--live-p))
  ;; The classic regression was family=\"default\" / height=1 (tty poison).
  (should-not (equal (face-attribute 'default :family) "default"))
  (should (> (face-attribute 'default :height) 1))
  ;; font-lock faces gate on (class color)(min-colors 88); they must resolve.
  (should (color-defined-p (face-attribute 'font-lock-comment-face
                                           :foreground nil 'default))))

(ert-deftest cmacs-lrgterm-monitor-geometry ()
  "lrg-display-pixel-size returns a plausible monitor size."
  (skip-unless (cmacs-lrgterm-tests--live-p))
  (let ((sz (lrg-display-pixel-size)))
    (should (consp sz))
    (should (> (car sz) 0))
    (should (> (cdr sz) 0))
    (should (= (display-pixel-width) (car sz)))))

(ert-deftest cmacs-lrgterm-clipboard-roundtrip ()
  "Text put on the clipboard round-trips, including UTF-8."
  (skip-unless (cmacs-lrgterm-tests--live-p))
  (let ((s "lrg-clip-αβγ-✓-123"))
    (lrg-set-clipboard s)
    (should (equal (lrg-get-clipboard) s))
    ;; via the gui-selection machinery (kill/yank path):
    (gui-set-selection 'CLIPBOARD s)
    (should (equal (gui-get-selection 'CLIPBOARD 'STRING) s))))

(ert-deftest cmacs-lrgterm-capture-screen ()
  "lrg-capture-screen writes a non-trivial PNG of the frame."
  (skip-unless (cmacs-lrgterm-tests--live-p))
  (let ((png (make-temp-file "lrg-capture-" nil ".png")))
    (unwind-protect
        (progn
          (redisplay t)
          (lrg-capture-screen png)
          (should (file-exists-p png))
          ;; A real rendered frame is far larger than an empty/uniform image.
          (should (> (file-attribute-size (file-attributes png)) 1000)))
      (ignore-errors (delete-file png)))))

(provide 'cmacs-lrgterm-tests)
;;; cmacs-lrgterm-tests.el ends here
