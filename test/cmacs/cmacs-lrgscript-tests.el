;;; cmacs-lrgscript-tests.el --- Tests for elisp libregnum scripting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the `cmacs-lrgscript' Emacs Lisp scripting backend for
;; libregnum.  These exercise the C backend end to end -- the LrgScripting
;; vtable, the GValue<->Lisp marshalling, hook-name translation, globals, and
;; per-frame error isolation -- entirely headlessly: the scripting bridge and
;; the libregnum scripting manager need no GL context.  Interactive node /
;; game scripting (which needs a display) is verified separately.
;;
;; Every test skips cleanly when the subsystem is not compiled in.

;;; Code:

(require 'ert)

(defmacro cmacs-lrgscript-tests--skip-unless-built ()
  "Skip unless the elisp scripting backend is compiled in and registered."
  '(skip-unless (and (bound-and-true-p IS-CMACS-LRGSCRIPT)
                     (fboundp 'cmacs-lrgscript-available-p)
                     (cmacs-lrgscript-available-p))))

(ert-deftest cmacs-lrgscript-test-feature-flag ()
  "The IS-CMACS-LRGSCRIPT flag and compiled-features agree."
  (skip-unless (fboundp 'cmacs-compiled-features))
  (should (eq (and (bound-and-true-p IS-CMACS-LRGSCRIPT) t)
              (and (memq 'lrgscript (cmacs-compiled-features)) t))))

(ert-deftest cmacs-lrgscript-test-backend-registered ()
  "The elisp backend is registered with libregnum's scripting manager."
  (cmacs-lrgscript-tests--skip-unless-built)
  (should (cmacs-lrgscript-available-p))
  ;; libregnum now reports elisp as language 5 alongside the compiled-in set.
  (when (fboundp 'cmacs-libregnum-scripting-languages)
    (should (equal (assoc "Emacs Lisp" (cmacs-libregnum-scripting-languages))
                   '("Emacs Lisp" . 5)))))

(ert-deftest cmacs-lrgscript-test-load-and-call ()
  "Loading a multi-form script and calling it round-trips scalar types."
  (cmacs-lrgscript-tests--skip-unless-built)
  (cmacs-lrgscript-eval
   "(defun cmacs-lrgscript-tests--id-int (n) n)
    (defun cmacs-lrgscript-tests--id-str (s) s)
    (defun cmacs-lrgscript-tests--id-flt (x) x)
    (defun cmacs-lrgscript-tests--yes () t)
    (defun cmacs-lrgscript-tests--no () nil)")
  (should (= 42 (cmacs-lrgscript-call "cmacs-lrgscript-tests--id-int" 42)))
  (should (equal "hello" (cmacs-lrgscript-call "cmacs-lrgscript-tests--id-str" "hello")))
  (should (= 2.5 (cmacs-lrgscript-call "cmacs-lrgscript-tests--id-flt" 2.5)))
  (should (eq t (cmacs-lrgscript-call "cmacs-lrgscript-tests--yes")))
  (should (eq nil (cmacs-lrgscript-call "cmacs-lrgscript-tests--no"))))

(ert-deftest cmacs-lrgscript-test-globals ()
  "get/set of a global variable cross the GValue boundary."
  (cmacs-lrgscript-tests--skip-unless-built)
  (cmacs-lrgscript-eval "(defvar cmacs-lrgscript-tests--v 0)")
  (cmacs-lrgscript-set "cmacs-lrgscript-tests--v" 7)
  (should (= 7 (cmacs-lrgscript-get "cmacs-lrgscript-tests--v")))
  (cmacs-lrgscript-set "cmacs-lrgscript-tests--v" "text")
  (should (equal "text" (cmacs-lrgscript-get "cmacs-lrgscript-tests--v"))))

(ert-deftest cmacs-lrgscript-test-hook-name-translation ()
  "A hyphenated hook is reachable by libregnum's underscore hook name.
LrgScriptComponent calls `lrg_script_update'; the backend also accepts the
idiomatic `lrg-script-update' an .el script defines."
  (cmacs-lrgscript-tests--skip-unless-built)
  (cmacs-lrgscript-eval
   "(defvar cmacs-lrgscript-tests--ticks 0)
    (defun lrg-script-update (_dt)
      (setq cmacs-lrgscript-tests--ticks (1+ cmacs-lrgscript-tests--ticks)))")
  (cmacs-lrgscript-call "lrg_script_update" 0.016)
  (cmacs-lrgscript-call "lrg_script_update" 0.016)
  (should (= 2 (cmacs-lrgscript-get "cmacs-lrgscript-tests--ticks")))
  (fmakunbound 'lrg-script-update))

(ert-deftest cmacs-lrgscript-test-error-isolation ()
  "A signalling script surfaces `cmacs-lrgscript-error', it does not abort."
  (cmacs-lrgscript-tests--skip-unless-built)
  (cmacs-lrgscript-eval "(defun cmacs-lrgscript-tests--boom () (error \"kaboom\"))")
  (should-error (cmacs-lrgscript-call "cmacs-lrgscript-tests--boom")
                :type 'cmacs-lrgscript-error)
  ;; calling an unbound function is also a clean signal, not a crash
  (should-error (cmacs-lrgscript-call "cmacs-lrgscript-tests--nope-nope")
                :type 'cmacs-lrgscript-error))

(ert-deftest cmacs-lrgscript-test-unavailable-when-absent ()
  "When the subsystem is absent, the elisp wrapper returns nil, not an error."
  (skip-unless (not (bound-and-true-p IS-CMACS-LRGSCRIPT)))
  (when (fboundp 'cmacs-lrgscript-available-p*)
    (should-not (cmacs-lrgscript-available-p*))))

;;; ------------------------------------------------------------------
;;; Game-authoring layer (headless where the engine is not required)
;;; ------------------------------------------------------------------

(ert-deftest cmacs-lrgscript-test-game-defuns-present ()
  "The game-loop commands are defined when the subsystem is built."
  (cmacs-lrgscript-tests--skip-unless-built)
  (should (fboundp 'cmacs-lrgscript-run-game))
  (should (fboundp 'cmacs-lrgscript-stop-game)))

(ert-deftest cmacs-lrgscript-test-breakout-logic ()
  "A complete game's simulation runs as pure elisp, driven by fixed-update.
This proves a whole game is authored in elisp without needing a GL display: we
tick the pure step function and assert the world evolves, bricks break, and the
game can be won -- exactly what the :fixed-update hook drives on-screen."
  (skip-unless (require 'cmacs-lrgscript-examples nil t))
  (let* ((s (cmacs-lrgscript-breakout--new-state))
         (x0 (plist-get s :ball-x))
         (y0 (plist-get s :ball-y)))
    ;; one tick moves the ball
    (setq s (cmacs-lrgscript-breakout--step s (/ 1.0 60)))
    (should-not (and (= (plist-get s :ball-x) x0) (= (plist-get s :ball-y) y0)))
    ;; the ball bounces off the ceiling (never escapes the top)
    (dotimes (_ 600) (setq s (cmacs-lrgscript-breakout--step s (/ 1.0 60))))
    (should (>= (plist-get s :ball-y) 0))
    ;; a full clear is a win: nuke the wall, place ball under a brick going up
    (let ((s2 (cmacs-lrgscript-breakout--new-state)))
      (fillarray (plist-get s2 :bricks) nil)
      (aset (plist-get s2 :bricks) 0 t)
      (pcase-let ((`(,rx ,ry ,rw ,_rh) (cmacs-lrgscript-breakout--brick-rect 0)))
        (setq s2 (plist-put s2 :ball-x (+ rx (/ rw 2.0))))
        (setq s2 (plist-put s2 :ball-y (+ ry 30)))
        (setq s2 (plist-put s2 :ball-vx 0.0))
        (setq s2 (plist-put s2 :ball-vy -400.0)))
      (let ((won nil))
        (dotimes (_ 120)
          (setq s2 (cmacs-lrgscript-breakout--step s2 (/ 1.0 60)))
          (when (eq (plist-get s2 :status) 'won) (setq won t)))
        (should won)))))

(ert-deftest cmacs-lrgscript-test-breakout-collision ()
  "The circle/rect overlap test the ball physics relies on is correct."
  (skip-unless (require 'cmacs-lrgscript-examples nil t))
  (should (cmacs-lrgscript-breakout--hit-rect-p 10 10 5 8 8 20 20))
  (should-not (cmacs-lrgscript-breakout--hit-rect-p 100 100 5 8 8 20 20)))

(provide 'cmacs-lrgscript-tests)
;;; cmacs-lrgscript-tests.el ends here
