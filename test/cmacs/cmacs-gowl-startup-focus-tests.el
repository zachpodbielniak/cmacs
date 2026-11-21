;;; cmacs-gowl-startup-focus-tests.el --- Startup does not take the keyboard back  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A window mapped in the first moments of a `cmacs --gowl' session lost
;; the keyboard to the Emacs frame.  Two things in `cmacs-gowl--start'
;; did it, both on timers:
;;
;;   - half a second in, "ensure Emacs has keyboard focus" focused the
;;     first client in the list, whatever held the keyboard by then;
;;   - 0.6 s in, `cmacs-gowl-assign-monitor-tags' ran a second time (in
;;     case the outputs settled late) and ended, as it always did, by
;;     handing the keyboard to Emacs.
;;
;; The contract held here: startup gives Emacs the keyboard only when
;; NOTHING has it.  A window the compositor focused when it mapped keeps
;; the keyboard through both timers, and re-viewing the monitors' tags
;; puts focus back where it was.
;;
;; The compositor is stubbed: these are the Lisp decisions, and what
;; they ask of the compositor is recorded.  Clients are compared by id,
;; as the code must -- each call into the compositor returns a fresh
;; object for the same window, which the stubs reproduce.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)

(declare-function cmacs-gowl-assign-monitor-tags "cmacs-gowl" ())
(declare-function cmacs-gowl--focus-emacs-if-unfocused "cmacs-gowl" ())

(defvar cmacs-gowl-startup-focus-tests--windows nil
  "Ids of the windows the stubbed compositor has, Emacs's first.")
(defvar cmacs-gowl-startup-focus-tests--focused nil
  "Id of the window with the keyboard, or nil.")
(defvar cmacs-gowl-startup-focus-tests--focus-calls nil
  "Ids `gowl-focus-client' was asked for, newest first.")

(defun cmacs-gowl-startup-focus-tests--client (id)
  "A fresh object for window ID: never `eq' to an earlier one."
  (list 'client id (make-symbol "wrapper")))

(defmacro cmacs-gowl-startup-focus-tests--with-compositor (&rest body)
  "Run BODY against a stubbed compositor holding the test's windows.
Window 1 is Emacs's own frame.  `gowl-view-tags' moves focus to the
\"top client\" as the real one does: here, to Emacs."
  (declare (indent 0) (debug t))
  `(progn
     (skip-unless (locate-library "cmacs-gowl"))
     (require 'cmacs-gowl)
     (let ((cmacs-gowl-startup-focus-tests--focus-calls nil))
       (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
                 ((symbol-function 'gowl-list-monitors)
                  (lambda (&rest _) '(:m0)))
                 ((symbol-function 'gowl-monitor-enabled-p)
                  (lambda (&rest _) t))
                 ((symbol-function 'gowl-view-tags)
                  (lambda (&rest _)
                    (setq cmacs-gowl-startup-focus-tests--focused 1)))
                 ((symbol-function 'gowl-list-clients)
                  (lambda (&rest _)
                    (mapcar #'cmacs-gowl-startup-focus-tests--client
                            cmacs-gowl-startup-focus-tests--windows)))
                 ((symbol-function 'gowl-client-info)
                  (lambda (&rest args)
                    (list (cons 'id (nth 1 (car args))))))
                 ((symbol-function 'gowl-focused-client)
                  (lambda (&rest _)
                    (and cmacs-gowl-startup-focus-tests--focused
                         (cmacs-gowl-startup-focus-tests--client
                          cmacs-gowl-startup-focus-tests--focused))))
                 ((symbol-function 'gowl-emacs-client)
                  (lambda (&rest _)
                    (cmacs-gowl-startup-focus-tests--client 1)))
                 ((symbol-function 'gowl-focus-client)
                  (lambda (&rest args)
                    (let ((id (nth 1 (car args))))
                      (push id cmacs-gowl-startup-focus-tests--focus-calls)
                      (setq cmacs-gowl-startup-focus-tests--focused id))))
                 ((symbol-function 'cmacs-gowl--bar-redraw) #'ignore))
         ,@body))))

(ert-deftest cmacs-gowl-startup-focus-test-safety-net-leaves-a-focused-window ()
  "Half a second in: a window that has the keyboard keeps it."
  (cmacs-gowl-startup-focus-tests--with-compositor
    (should (fboundp 'cmacs-gowl--focus-emacs-if-unfocused))
    (let ((cmacs-gowl-startup-focus-tests--windows '(1 7))
          (cmacs-gowl-startup-focus-tests--focused 7))
      (cmacs-gowl--focus-emacs-if-unfocused)
      (should (eql cmacs-gowl-startup-focus-tests--focused 7))
      (should-not cmacs-gowl-startup-focus-tests--focus-calls))))

(ert-deftest cmacs-gowl-startup-focus-test-safety-net-focuses-emacs-when-nothing-is ()
  "Half a second in, nothing focused: Emacs's frame, not `the first client'."
  (cmacs-gowl-startup-focus-tests--with-compositor
    (should (fboundp 'cmacs-gowl--focus-emacs-if-unfocused))
    ;; Emacs is deliberately not first in the list.
    (let ((cmacs-gowl-startup-focus-tests--windows '(7 1))
          (cmacs-gowl-startup-focus-tests--focused nil))
      (cl-letf (((symbol-function 'gowl-list-clients)
                 (lambda (&rest _)
                   (mapcar #'cmacs-gowl-startup-focus-tests--client
                           '(7 1)))))
        (cmacs-gowl--focus-emacs-if-unfocused))
      (should (equal cmacs-gowl-startup-focus-tests--focus-calls '(1))))))

(ert-deftest cmacs-gowl-startup-focus-test-monitor-tags-keep-the-focused-window ()
  "Re-viewing the tags puts the keyboard back on the window that had it."
  (cmacs-gowl-startup-focus-tests--with-compositor
    (let ((cmacs-gowl-startup-focus-tests--windows '(1 7))
          (cmacs-gowl-startup-focus-tests--focused 7))
      (cmacs-gowl-assign-monitor-tags)
      (should (eql cmacs-gowl-startup-focus-tests--focused 7))
      ;; Asked for by id through a fresh lookup, and nothing after it.
      (should (eql (car cmacs-gowl-startup-focus-tests--focus-calls) 7)))))

(ert-deftest cmacs-gowl-startup-focus-test-monitor-tags-fall-back-to-emacs ()
  "Nothing focused before, or the window gone since: Emacs, as before."
  (cmacs-gowl-startup-focus-tests--with-compositor
    (let ((cmacs-gowl-startup-focus-tests--windows '(1 7))
          (cmacs-gowl-startup-focus-tests--focused nil))
      (cmacs-gowl-assign-monitor-tags)
      (should (eql cmacs-gowl-startup-focus-tests--focused 1)))
    ;; Focused before, closed while the tags moved: never focused again.
    (let ((cmacs-gowl-startup-focus-tests--windows '(1 7))
          (cmacs-gowl-startup-focus-tests--focused 7)
          (cmacs-gowl-startup-focus-tests--focus-calls nil))
      (cl-letf (((symbol-function 'gowl-view-tags)
                 (lambda (&rest _)
                   (setq cmacs-gowl-startup-focus-tests--windows '(1)
                         cmacs-gowl-startup-focus-tests--focused 1))))
        (cmacs-gowl-assign-monitor-tags))
      (should-not (memql 7 cmacs-gowl-startup-focus-tests--focus-calls))
      (should (eql cmacs-gowl-startup-focus-tests--focused 1)))))

(ert-deftest cmacs-gowl-startup-focus-test-no-unconditional-grab-in-start ()
  "`cmacs-gowl--start' schedules no focus of `the first client'.
A source guard: the timer body cannot be reached from a unit test
without starting a compositor."
  (let ((file (locate-library "cmacs-gowl.el")))
    (skip-unless file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (should (re-search-forward "^(defun cmacs-gowl--start ()" nil t))
      (let ((start (point))
            (end (progn (re-search-forward "^(defun " nil t) (point))))
        (goto-char start)
        (should-not (re-search-forward
                     "(gowl-focus-client (car clients))" end t))
        (goto-char start)
        (should (re-search-forward
                 "cmacs-gowl--focus-emacs-if-unfocused" end t))))))

(provide 'cmacs-gowl-startup-focus-tests)

;;; cmacs-gowl-startup-focus-tests.el ends here
