;;; cmacs-gowl-power-tests.el --- Tests for power-saver window effects -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gowl-power-saver-mode' against a fake compositor and a fake
;; power-profiles-daemon: entering power saver switches the backdrop and
;; the tube off and toasts; leaving puts back exactly what was there; a
;; choice made by hand meanwhile is not overridden; a session that
;; starts in power saver never pushes the user's backdrop; the user's
;; defcustoms are never written; and the D-Bus PropertiesChanged shapes
;; are parsed.  No compositor and no system bus are touched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl)
(require 'cmacs-gowl-power)

(defvar cmacs-gowl-power-tests--backdrop nil
  "The fake compositor's backdrop.")
(defvar cmacs-gowl-power-tests--crt nil
  "The fake compositor's tube.")
(defvar cmacs-gowl-power-tests--calls nil
  "Every set call the fake compositor received, newest first.")
(defvar cmacs-gowl-power-tests--toasts nil
  "Every toast summary, newest first.")
(defvar cmacs-gowl-power-tests--profile nil
  "What the fake daemon answers for ActiveProfile.")

(defmacro cmacs-gowl-power-tests--with-fake (backdrop crt profile &rest body)
  "Run BODY against a compositor showing BACKDROP and CRT.
PROFILE is what the fake daemon reports.  Stubs take &rest: a stub of a
C DEFUN with the wrong arity only fails under `make check-cmacs'."
  (declare (indent 3))
  `(let ((cmacs-gowl-power-tests--backdrop ,backdrop)
         (cmacs-gowl-power-tests--crt ,crt)
         (cmacs-gowl-power-tests--calls nil)
         (cmacs-gowl-power-tests--toasts nil)
         (cmacs-gowl-power-tests--profile ,profile)
         (cmacs-gowl-power--held nil)
         (cmacs-gowl-power--profile nil)
         (cmacs-gowl-power--signals nil)
         (cmacs-gowl-power-saver-mode nil)
         (cmacs-gowl-power-saver-effects t)
         (cmacs-gowl-power-saver-toast t)
         (cmacs-gowl-power-saver-profiles '("power-saver")))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-backdrop)
                (lambda (&rest _) cmacs-gowl-power-tests--backdrop))
               ((symbol-function 'gowl-set-backdrop)
                (lambda (style &rest _)
                  (push (list 'backdrop style) cmacs-gowl-power-tests--calls)
                  ;; The compositor's rule: the `crt' stop of the tour
                  ;; switches the tube on arriving and off leaving.
                  (cond ((and (eq style 'crt)
                              (not (eq cmacs-gowl-power-tests--backdrop 'crt)))
                         (setq cmacs-gowl-power-tests--crt t))
                        ((and (not (eq style 'crt))
                              (eq cmacs-gowl-power-tests--backdrop 'crt))
                         (setq cmacs-gowl-power-tests--crt nil)))
                  (setq cmacs-gowl-power-tests--backdrop style)))
               ((symbol-function 'gowl-crt-p)
                (lambda (&rest _) cmacs-gowl-power-tests--crt))
               ((symbol-function 'gowl-set-crt)
                (lambda (on &rest _)
                  (push (list 'crt on) cmacs-gowl-power-tests--calls)
                  (setq cmacs-gowl-power-tests--crt (and on t))))
               ((symbol-function 'gowl-bar-notify)
                (lambda (summary &rest _)
                  (push summary cmacs-gowl-power-tests--toasts)))
               ((symbol-function 'run-at-time)
                (lambda (_time _repeat fn &rest args) (apply fn args)))
               ((symbol-function 'cmacs-gowl-power--read-profile)
                (lambda (&rest _) cmacs-gowl-power-tests--profile))
               ((symbol-function 'cmacs-gowl-power--register) #'ignore)
               ((symbol-function 'cmacs-gowl-power--unregister) #'ignore))
       ,@body)))

(ert-deftest cmacs-gowl-power-test-saver-switches-effects-off ()
  "Entering power saver sets the backdrop to none and toasts."
  (cmacs-gowl-power-tests--with-fake 'rain nil "balanced"
    (cmacs-gowl-power--update "balanced")
    (should-not cmacs-gowl-power-tests--calls)
    (cmacs-gowl-power--update "power-saver")
    (should (eq cmacs-gowl-power-tests--backdrop 'none))
    (should-not cmacs-gowl-power-tests--crt)
    (should (equal cmacs-gowl-power--held '(rain . nil)))
    (should (equal cmacs-gowl-power-tests--toasts
                   '("Power saver: window effects off")))))

(ert-deftest cmacs-gowl-power-test-leaving-saver-restores ()
  "Leaving power saver puts back exactly what was showing."
  (cmacs-gowl-power-tests--with-fake 'storm nil nil
    (cmacs-gowl-power--update "power-saver")
    (cmacs-gowl-power--update "performance")
    (should (eq cmacs-gowl-power-tests--backdrop 'storm))
    (should-not cmacs-gowl-power--held)
    (should (equal (car cmacs-gowl-power-tests--toasts)
                   "Window effects restored"))))

(ert-deftest cmacs-gowl-power-test-hand-set-tube-survives ()
  "A tube switched on beside a backdrop goes off and comes back on."
  (cmacs-gowl-power-tests--with-fake 'water t nil
    (cmacs-gowl-power--update "power-saver")
    (should (eq cmacs-gowl-power-tests--backdrop 'none))
    (should-not cmacs-gowl-power-tests--crt)
    (cmacs-gowl-power--update "balanced")
    (should (eq cmacs-gowl-power-tests--backdrop 'water))
    (should cmacs-gowl-power-tests--crt)))

(ert-deftest cmacs-gowl-power-test-crt-stop-restores ()
  "The `crt' stop of the tour comes back as the tube."
  (cmacs-gowl-power-tests--with-fake 'crt t nil
    (cmacs-gowl-power--update "power-saver")
    (should-not cmacs-gowl-power-tests--crt)
    (cmacs-gowl-power--update "balanced")
    (should (eq cmacs-gowl-power-tests--backdrop 'crt))
    (should cmacs-gowl-power-tests--crt)))

(ert-deftest cmacs-gowl-power-test-hand-choice-not-overridden ()
  "A backdrop picked by hand during power saver stays when it ends."
  (cmacs-gowl-power-tests--with-fake 'rain nil nil
    (cmacs-gowl-power--update "power-saver")
    ;; Super+" pressed while power saver holds.
    (gowl-set-backdrop 'glass)
    (cmacs-gowl-power--update "balanced")
    (should (eq cmacs-gowl-power-tests--backdrop 'glass))
    (should-not cmacs-gowl-power--held)))

(ert-deftest cmacs-gowl-power-test-already-dark-is-quiet ()
  "No effect showing means nothing to switch off and nothing to say."
  (cmacs-gowl-power-tests--with-fake 'none nil nil
    (cmacs-gowl-power--update "power-saver")
    (cmacs-gowl-power--update "balanced")
    (should-not cmacs-gowl-power-tests--calls)
    (should-not cmacs-gowl-power-tests--toasts)))

(ert-deftest cmacs-gowl-power-test-repeat-announce-ignored ()
  "The same profile announced twice (two D-Bus names) acts once."
  (cmacs-gowl-power-tests--with-fake 'rain nil nil
    (cmacs-gowl-power--update "power-saver")
    (cmacs-gowl-power--update "power-saver")
    (should (= (length cmacs-gowl-power-tests--toasts) 1))
    (should (equal cmacs-gowl-power--held '(rain . nil)))))

(ert-deftest cmacs-gowl-power-test-extra-profiles ()
  "`cmacs-gowl-power-saver-profiles' decides which profiles hold."
  (cmacs-gowl-power-tests--with-fake 'rain nil nil
    (let ((cmacs-gowl-power-saver-profiles '("power-saver" "balanced")))
      (cmacs-gowl-power--update "balanced")
      (should (eq cmacs-gowl-power-tests--backdrop 'none))
      (cmacs-gowl-power--update "performance")
      (should (eq cmacs-gowl-power-tests--backdrop 'rain)))))

(ert-deftest cmacs-gowl-power-test-toast-off ()
  "`cmacs-gowl-power-saver-toast' nil switches the effects silently."
  (cmacs-gowl-power-tests--with-fake 'rain nil nil
    (let ((cmacs-gowl-power-saver-toast nil))
      (cmacs-gowl-power--update "power-saver")
      (should (eq cmacs-gowl-power-tests--backdrop 'none))
      (should-not cmacs-gowl-power-tests--toasts))))

(ert-deftest cmacs-gowl-power-test-start-in-saver-never-draws ()
  "A session starting in power saver never pushes the user's backdrop."
  (cmacs-gowl-power-tests--with-fake 'none nil "power-saver"
    (let ((cmacs-gowl-backdrop 'rain)
          (cmacs-gowl-crt nil))
      (cmacs-gowl-power--on-start)
      (should cmacs-gowl-power-saver-mode)
      (should (cmacs-gowl-power-holding-p))
      (cmacs-gowl--apply-backdrop)
      (should-not (member '(backdrop rain) cmacs-gowl-power-tests--calls))
      (should-not (member '(crt t) cmacs-gowl-power-tests--calls))
      (should (equal cmacs-gowl-power--held '(rain . nil)))
      ;; The defcustom still says what the user wants.
      (should (eq cmacs-gowl-backdrop 'rain))
      (should (equal cmacs-gowl-power-tests--toasts
                     '("Power saver: window effects off")))
      (cmacs-gowl-power--update "balanced")
      (should (eq cmacs-gowl-power-tests--backdrop 'rain)))))

(ert-deftest cmacs-gowl-power-test-start-balanced-applies ()
  "Outside power saver the start pushes the backdrop as before."
  (cmacs-gowl-power-tests--with-fake 'none nil "balanced"
    (let ((cmacs-gowl-backdrop 'rain)
          (cmacs-gowl-crt nil))
      (cmacs-gowl-power--on-start)
      (should-not (cmacs-gowl-power-holding-p))
      (cmacs-gowl--apply-backdrop)
      (should (member '(backdrop rain) cmacs-gowl-power-tests--calls))
      (should-not cmacs-gowl-power-tests--toasts))))

(ert-deftest cmacs-gowl-power-test-opt-out ()
  "`cmacs-gowl-power-saver-effects' nil leaves everything alone."
  (cmacs-gowl-power-tests--with-fake 'none nil "power-saver"
    (let ((cmacs-gowl-power-saver-effects nil)
          (cmacs-gowl-backdrop 'rain)
          (cmacs-gowl-crt nil))
      (cmacs-gowl-power--on-start)
      (should-not cmacs-gowl-power-saver-mode)
      (cmacs-gowl--apply-backdrop)
      (should (eq cmacs-gowl-power-tests--backdrop 'rain)))))

(ert-deftest cmacs-gowl-power-test-mode-off-releases ()
  "Turning the mode off while holding restores the effects."
  (cmacs-gowl-power-tests--with-fake 'snow nil "power-saver"
    (cmacs-gowl-power-saver-mode 1)
    (should (eq cmacs-gowl-power-tests--backdrop 'none))
    (cmacs-gowl-power-saver-mode -1)
    (should (eq cmacs-gowl-power-tests--backdrop 'snow))
    (should-not cmacs-gowl-power--held)))

(ert-deftest cmacs-gowl-power-test-stop-forgets ()
  "Stopping the compositor drops the hold without restoring."
  (cmacs-gowl-power-tests--with-fake 'rain nil nil
    (cmacs-gowl-power--update "power-saver")
    (setq cmacs-gowl-power-tests--calls nil)
    (cmacs-gowl-power--on-stop)
    (should-not cmacs-gowl-power--held)
    (should-not cmacs-gowl-power-saver-mode)
    (should-not cmacs-gowl-power-tests--calls)))

(ert-deftest cmacs-gowl-power-test-properties-changed ()
  "PropertiesChanged is parsed in both variant shapes, and invalidation."
  (cmacs-gowl-power-tests--with-fake 'rain nil "balanced"
    (cmacs-gowl-power--on-properties-changed
     "net.hadess.PowerProfiles" '(("ActiveProfile" ("power-saver"))) nil)
    (should (eq cmacs-gowl-power-tests--backdrop 'none))
    (cmacs-gowl-power--on-properties-changed
     "org.freedesktop.UPower.PowerProfiles"
     '(("ActiveProfile" "balanced")) nil)
    (should (eq cmacs-gowl-power-tests--backdrop 'rain))
    (setq cmacs-gowl-power-tests--profile "power-saver")
    (cmacs-gowl-power--on-properties-changed
     "net.hadess.PowerProfiles" nil '("ActiveProfile"))
    (should (eq cmacs-gowl-power-tests--backdrop 'none))
    ;; Another interface on the same path is not ours.
    (cmacs-gowl-power--on-properties-changed
     "org.example.Other" '(("ActiveProfile" ("balanced"))) nil)
    (should (eq cmacs-gowl-power-tests--backdrop 'none))))

(ert-deftest cmacs-gowl-power-test-no-compositor-is-safe ()
  "Without a running compositor nothing is called and nothing signals."
  (cmacs-gowl-power-tests--with-fake 'rain nil nil
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
      (cmacs-gowl-power--update "power-saver")
      (cmacs-gowl-power--update "balanced")
      (should-not cmacs-gowl-power-tests--calls))))

(provide 'cmacs-gowl-power-tests)
;;; cmacs-gowl-power-tests.el ends here
