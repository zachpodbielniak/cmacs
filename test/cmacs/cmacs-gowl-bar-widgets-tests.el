;;; cmacs-gowl-bar-widgets-tests.el --- Tests for the extended bar widget defaults  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gowl-bar-widgets-apply' decides what the extended gowl bar
;; widgets look like under cmacs --gowl.  No bar runs here: both of the
;; functions that would reach one are rebound to record what they were
;; given.
;;
;; What would go wrong unnoticed without these:
;;
;;   - placement by wholesale region list instead of amendment keys,
;;     which would wipe the shipped layout (the tray bug, again);
;;   - an add without its remove, so every restart of the compositor
;;     puts another copy of each widget on the bar;
;;   - one failing setup function costing the others -- or the
;;     compositor's startup, which calls this.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-bar-widgets)

(defmacro cmacs-gowl-bar-widgets-tests--with (pushes configures &rest body)
  "Run BODY recording PUSHES (alists) and CONFIGURES ((BAR . ALIST) ...)."
  (declare (indent 2))
  `(let ((,pushes nil)
         (,configures nil)
         (cmacs-gowl-bar-widgets-setup-functions nil))
     (let ((cmacs-gowl-bar-push-function
            (lambda (alist) (setq ,pushes (append ,pushes (list alist)))))
           (cmacs-gowl-bar-widgets-configure-function
            (lambda (bar alist)
              (setq ,configures (append ,configures
                                        (list (cons bar alist)))))))
       ,@body)))

(defun cmacs-gowl-bar-widgets-tests--pushed (pushes key)
  "The last value pushed for KEY across PUSHES."
  (let (val)
    (dolist (a pushes)
      (when (assoc key a) (setq val (cdr (assoc key a)))))
    val))

(ert-deftest cmacs-gowl-bar-widgets-test-defaults ()
  "Out of the box: creature cpu, meeting-notes and ai-assistant on top."
  (cmacs-gowl-bar-widgets-tests--with pushes configures
    (let ((cmacs-gowl-bar-cpu-style 'creature)
          (cmacs-gowl-bar-default-widgets
           (default-value 'cmacs-gowl-bar-default-widgets))
          (cmacs-gowl-bar-ai-widgets
           (default-value 'cmacs-gowl-bar-ai-widgets)))
      (cmacs-gowl-bar-widgets-apply)
      (should (equal (cmacs-gowl-bar-widgets-tests--pushed pushes "cpu.style")
                     "creature"))
      (should (equal (cmacs-gowl-bar-widgets-tests--pushed
                      pushes "bottom-cpu.style")
                     "creature"))
      (dolist (w '("ai-assistant" "ai-rewrite" "translate" "meeting-notes"))
        (should (equal (cmacs-gowl-bar-widgets-tests--pushed
                        pushes (concat w ".ai-backend"))
                       "cmacs")))
      (should (equal (cmacs-gowl-bar-widgets-tests--pushed
                      pushes "translate.engine")
                     "ai"))
      (should (equal configures
                     '((top ("widgets-right-remove" . "meeting-notes ai-assistant")
                            ("widgets-right-add" . "meeting-notes ai-assistant"))))))))

(ert-deftest cmacs-gowl-bar-widgets-test-only-amendment-keys ()
  "Never a wholesale region list: that would replace the shipped layout."
  (cmacs-gowl-bar-widgets-tests--with pushes configures
    (let ((cmacs-gowl-bar-default-widgets
           '(("wow-gold" . bottom-right) ("tvremote" . top-left)
             ("keywheel" . top-right))))
      (cmacs-gowl-bar-widgets-apply)
      (dolist (entry configures)
        (dolist (cell (cdr entry))
          (should (string-match-p "-\\(add\\|remove\\)\\'" (car cell)))))
      ;; Each widget's add is paired with its remove, per bar.
      (should (equal (cdr (assq 'bottom configures))
                     '(("widgets-right-remove" . "wow-gold")
                       ("widgets-right-add" . "wow-gold"))))
      (should (equal (cdr (assq 'top configures))
                     '(("widgets-left-remove" . "tvremote")
                       ("widgets-left-add" . "tvremote")
                       ("widgets-right-remove" . "keywheel")
                       ("widgets-right-add" . "keywheel")))))))

(ert-deftest cmacs-gowl-bar-widgets-test-turning-things-off ()
  "nil style touches the cpu not at all; an empty list places nothing."
  (cmacs-gowl-bar-widgets-tests--with pushes configures
    (let ((cmacs-gowl-bar-cpu-style nil)
          (cmacs-gowl-bar-default-widgets nil)
          (cmacs-gowl-bar-ai-widgets nil))
      (cmacs-gowl-bar-widgets-apply)
      (should-not pushes)
      (should-not configures))))

(ert-deftest cmacs-gowl-bar-widgets-test-a-failing-step-costs-only-itself ()
  "Setup functions that signal are reported; the rest still run."
  (let ((ran nil))
    (cmacs-gowl-bar-widgets-tests--with pushes configures
      (defalias 'cmacs-gowl-bar-widgets-tests--boom
        (lambda () (error "kaboom")))
      (defalias 'cmacs-gowl-bar-widgets-tests--ok
        (lambda () (setq ran t)))
      (let ((cmacs-gowl-bar-widgets-setup-functions
             '(cmacs-gowl-bar-widgets-tests--boom
               cmacs-gowl-bar-widgets-tests--undefined
               cmacs-gowl-bar-widgets-tests--ok))
            (cmacs-gowl-bar-widgets-configure-function
             (lambda (&rest _) (error "no bar"))))
        (should-not (cmacs-gowl-bar-widgets-apply))
        (should ran)))))

(ert-deftest cmacs-gowl-bar-widgets-test-bad-place-is-reported ()
  "An unknown place is an error naming it, caught by apply."
  (should-error (cmacs-gowl-bar-widgets--place 'middle-earth))
  (cmacs-gowl-bar-widgets-tests--with pushes configures
    (let ((cmacs-gowl-bar-default-widgets '(("x" . middle-earth))))
      (should-error (cmacs-gowl-bar-widgets--placement-alists)))))

(provide 'cmacs-gowl-bar-widgets-tests)

;;; cmacs-gowl-bar-widgets-tests.el ends here
