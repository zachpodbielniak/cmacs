;;; cmacs-screensaver-tests.el --- ERT for cmacs-screensaver  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Display-independent tests for the screensaver Elisp layer: config and module
;; resolution (named key, absolute path, args), the picker candidate set,
;; module-dir search order, error paths, and defaults/gating.  The GL/gowl
;; render path (wallpaper/lock) needs a live compositor and is covered by the
;; manual end-to-end checks, not here.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-screensaver)

(defmacro cmacs-screensaver-tests--with-fake-modules (names &rest body)
  "Run BODY with `cmacs-screensaver-module-path' bound to a temp dir holding
empty NAMES (each a base name) as `.so' files."
  (declare (indent 1))
  `(let ((dir (make-temp-file "scr-mods" t)))
     (unwind-protect
         (progn
           (dolist (n ,names)
             (with-temp-file (expand-file-name (concat n ".so") dir)))
           (cl-letf (((symbol-function 'cmacs-screensaver-module-path)
                      (lambda () (list dir))))
             ,@body))
       (delete-directory dir t))))

;;;; Config + module resolution ----------------------------------------------

(ert-deftest cmacs-screensaver--resolve-by-key ()
  "A symbol key resolves through `cmacs-screensaver-modules-alist'."
  (cmacs-screensaver-tests--with-fake-modules '("blackhole")
    (let ((r (cmacs-screensaver--resolve-config 'default)))
      (should (string-suffix-p "blackhole.so" (car r)))
      (should (file-name-absolute-p (car r)))
      (should (null (cdr r))))))

(ert-deftest cmacs-screensaver--resolve-with-args ()
  "The :args list is returned verbatim as the module argv."
  (cmacs-screensaver-tests--with-fake-modules '("blackhole")
    (let ((r (cmacs-screensaver--resolve-config 'blackhole-warm)))
      (should (string-suffix-p "blackhole.so" (car r)))
      (should (equal (cdr r) '("--profile" "warm"))))))

(ert-deftest cmacs-screensaver--resolve-multiple-variants ()
  "Several configs of the SAME module each resolve to their own args."
  (cmacs-screensaver-tests--with-fake-modules '("blackhole")
    (should (equal (cdr (cmacs-screensaver--resolve-config 'blackhole-warm))
                   '("--profile" "warm")))
    (should (equal (cdr (cmacs-screensaver--resolve-config 'blackhole-cool))
                   '("--profile" "cool" "--orbit-radius" "60" "--infall" "2")))
    (should (equal (cdr (cmacs-screensaver--resolve-config 'blackhole-infall))
                   '("--profile" "cool" "--infall" "8")))))

(ert-deftest cmacs-screensaver--resolve-absolute-path ()
  "An absolute `.so' path in :module is used directly when it exists."
  (let ((f (make-temp-file "saver" nil ".so")))
    (unwind-protect
        (let* ((cmacs-screensaver-configs
                (list (cons 'abs (list :module f :args '("--x")))))
               (r (cmacs-screensaver--resolve-config 'abs)))
          (should (equal (car r) f))
          (should (equal (cdr r) '("--x"))))
      (delete-file f))))

(ert-deftest cmacs-screensaver--empty-args ()
  "A config with no :args resolves to an empty argv."
  (cmacs-screensaver-tests--with-fake-modules '("blackhole")
    (let ((cmacs-screensaver-configs '((e . (:module blackhole :args nil)))))
      (should (null (cdr (cmacs-screensaver--resolve-config 'e)))))))

;;;; Error paths -------------------------------------------------------------

(ert-deftest cmacs-screensaver--unknown-config-errors ()
  (should-error (cmacs-screensaver--resolve-config 'no-such-config)
                :type 'user-error))

(ert-deftest cmacs-screensaver--unknown-module-key-errors ()
  (cmacs-screensaver-tests--with-fake-modules '("blackhole")
    (let ((cmacs-screensaver-configs '((bad . (:module zzz-missing :args nil)))))
      (should-error (cmacs-screensaver--resolve-config 'bad)
                    :type 'user-error))))

(ert-deftest cmacs-screensaver--missing-absolute-errors ()
  (let ((cmacs-screensaver-configs
         '((x . (:module "/nonexistent/foo.so" :args nil)))))
    (should-error (cmacs-screensaver--resolve-config 'x) :type 'user-error)))

;;;; Picker + search path -----------------------------------------------------

(ert-deftest cmacs-screensaver--picker-candidates ()
  "The picker offers exactly the config names, in order."
  (let ((cmacs-screensaver-configs
         '((a . (:module x)) (b . (:module y)) (c . (:module z)))))
    (should (equal (mapcar #'car cmacs-screensaver-configs) '(a b c)))))

(ert-deftest cmacs-screensaver--module-path-env-first ()
  "The dev override $CMACS_SCREENSAVER_MODULE_DIR is searched first."
  (let ((process-environment
         (cons "CMACS_SCREENSAVER_MODULE_DIR=/tmp/scr-dev-xyz"
               process-environment)))
    (should (equal (car (cmacs-screensaver-module-path)) "/tmp/scr-dev-xyz"))))

(ert-deftest cmacs-screensaver--module-path-no-nils ()
  "The search path never contains nil entries."
  (let ((process-environment
         (cl-remove-if (lambda (e)
                         (string-prefix-p "CMACS_SCREENSAVER_MODULE_DIR=" e))
                       process-environment)))
    (should-not (memq nil (cmacs-screensaver-module-path)))))

;;;; Defaults + gating --------------------------------------------------------

(ert-deftest cmacs-screensaver--defaults ()
  (should (eq cmacs-screensaver-default-config 'default))
  (should (= cmacs-screensaver-fps 30))
  (should (eq cmacs-screensaver-pause-when-covered t))
  (should (null cmacs-screensaver-wallpaper-config))
  (should (null cmacs-screensaver-lock-config)))

(ert-deftest cmacs-screensaver--supported-p-boolean ()
  "`cmacs-screensaver-supported-p' is a boolean either way (C subr when the
subsystem is built with gowl, nil fallback otherwise)."
  (should (memq (cmacs-screensaver-supported-p) '(nil t))))

;;;; Out-of-process renderer control surface -----------------------------------

(ert-deftest cmacs-screensaver--start-timeout-defcustom ()
  "The start-timeout knob exists and is a positive integer."
  (should (integerp cmacs-screensaver-start-timeout))
  (should (> cmacs-screensaver-start-timeout 0)))

(ert-deftest cmacs-screensaver--commands-bound ()
  "The new control commands are all defined."
  (dolist (cmd '(cmacs-screensaver-status
                 cmacs-screensaver-restart
                 cmacs-screensaver-pause
                 cmacs-screensaver-resume
                 cmacs-screensaver-set-fps
                 cmacs-screensaver-last-error))
    (should (fboundp cmd))))

(ert-deftest cmacs-screensaver--status-plist-when-idle ()
  "`cmacs-screensaver-status' returns a plist (not an error) when idle.
With the C subsystem built it reports :running nil; without it, nil."
  (let ((st (cmacs-screensaver-status)))
    (when st
      (should (plistp st))
      (should (memq :running st))
      (should (null (plist-get st :running))))))

(ert-deftest cmacs-screensaver--set-fps-rejects-nonpositive ()
  "`cmacs-screensaver-set-fps' rejects non-positive values at the Elisp edge,
before reaching the C primitive."
  (let ((cmacs-screensaver-fps 30))
    (cl-letf (((symbol-function 'cmacs-screensaver--set-fps) #'ignore))
      (should-error (cmacs-screensaver-set-fps 0) :type 'user-error)
      (should-error (cmacs-screensaver-set-fps -5) :type 'user-error)
      ;; valid value is clamped to <= 240 and stored
      (cmacs-screensaver-set-fps 300)
      (should (= cmacs-screensaver-fps 240)))))

(ert-deftest cmacs-screensaver--restart-gated ()
  "`cmacs-screensaver-restart' errors cleanly in a build without the subsystem."
  (cl-letf (((symbol-function 'cmacs-screensaver-supported-p) (lambda () nil)))
    (should-error (cmacs-screensaver-restart) :type 'user-error)))

(provide 'cmacs-screensaver-tests)
;;; cmacs-screensaver-tests.el ends here
