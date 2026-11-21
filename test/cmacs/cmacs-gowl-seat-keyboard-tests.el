;;; cmacs-gowl-seat-keyboard-tests.el --- The seat's keyboard capability  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A seat with no physical keyboard used to advertise no `wl_keyboard'
;; at all, so on a tablet, a headset or a headless session keys from an
;; on-screen keyboard reached no client and toolkit clients never
;; enabled their text fields.  gowl now counts a virtual keyboard as a
;; keyboard and can be told to advertise one always
;; (deps/gowl/docs/configuration.org, "Machines without a keyboard";
;; the rule itself is tested in deps/gowl/tests/test-seat-keyboard.c).
;;
;; These tests are the cmacs side: `gowl-set-force-seat-keyboard',
;; `gowl-seat-has-keyboard-p' and the GOWL_SEAT_KEYBOARD environment
;; variable, against a real compositor on the headless backend in a
;; second cmacs.  Nothing here touches the session this runs in: the
;; child has its own runtime directory, no parent display, and stops
;; its compositor before it exits.

;;; Code:

(require 'ert)
(require 'cmacs)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-set-force-seat-keyboard "cmacs-gowl.c" (on))
(declare-function gowl-seat-has-keyboard-p "cmacs-gowl.c" ())

(defun cmacs-gowl-seat-keyboard-tests--run (form &optional extra-env)
  "Evaluate FORM in a second cmacs with a headless gowl available.
Return (STATUS . OUTPUT).  EXTRA-ENV entries come first, so they win.
The recipe is `cmacs-gowl-tests--run-headless', repeated here so this
file does not load that whole suite."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file
                   (expand-file-name "cmacs-gowl-seatkb-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append extra-env
                  (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME="
                                (expand-file-name "state" runtime))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status
                 (apply #'call-process (or timeout emacs) nil t nil
                        (append (and timeout (list "120" emacs))
                                (list "--batch" "-Q" "--eval"
                                      "(setq backtrace-on-error-noninteractive nil)"
                                      "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defun cmacs-gowl-seat-keyboard-tests--available-p ()
  "Non-nil when this build has the primitives and somewhere to run."
  (and (fboundp 'gowl-start)
       (fboundp 'gowl-set-force-seat-keyboard)
       (fboundp 'gowl-seat-has-keyboard-p)
       (let ((dir (getenv "XDG_RUNTIME_DIR")))
         (and dir (file-directory-p dir)))))

(ert-deftest cmacs-gowl-seat-keyboard-test-forced-at-run-time ()
  "A keyboardless seat has no keyboard until it is forced, and loses it
again when the forcing is taken back."
  (skip-unless (cmacs-gowl-seat-keyboard-tests--available-p))
  (let* ((result
          (cmacs-gowl-seat-keyboard-tests--run
           '(progn
              (gowl-start)
              (unless (gowl-running-p) (error "not running"))
              ;; Headless: no input devices, nothing forced.
              (when (gowl-seat-has-keyboard-p)
                (error "a headless seat claims a keyboard"))
              (when (gowl-config-get "force-seat-keyboard")
                (error "forced by default"))
              (unless (gowl-set-force-seat-keyboard t)
                (error "forcing did not give the seat a keyboard"))
              (unless (and (gowl-seat-has-keyboard-p)
                           (gowl-config-get "force-seat-keyboard"))
                (error "forced, but not reported"))
              (when (gowl-set-force-seat-keyboard nil)
                (error "automatic again, and still a keyboard"))
              (when (gowl-seat-has-keyboard-p)
                (error "the capability outlived the setting"))
              (gowl-stop)
              (princ "seat-keyboard: ok"))
           ;; The developer's own environment must not decide the result.
           '("GOWL_SEAT_KEYBOARD"))))
    (ert-info ((cdr result) :prefix "child output: ")
      (should (eql (car result) 0))
      (should (string-search "seat-keyboard: ok" (cdr result))))))

(ert-deftest cmacs-gowl-seat-keyboard-test-environment ()
  "GOWL_SEAT_KEYBOARD=always: there from the start, whatever is set later."
  (skip-unless (cmacs-gowl-seat-keyboard-tests--available-p))
  (let ((result
         (cmacs-gowl-seat-keyboard-tests--run
          '(progn
             (gowl-start)
             (unless (gowl-seat-has-keyboard-p)
               (error "the environment did not force the keyboard"))
             ;; The environment wins over the setting.
             (unless (gowl-set-force-seat-keyboard nil)
               (error "the setting beat the environment"))
             (gowl-stop)
             (princ "seat-keyboard-env: ok"))
          '("GOWL_SEAT_KEYBOARD=always"))))
    (ert-info ((cdr result) :prefix "child output: ")
      (should (eql (car result) 0))
      (should (string-search "seat-keyboard-env: ok" (cdr result))))))

(ert-deftest cmacs-gowl-seat-keyboard-test-needs-a-compositor ()
  "Both primitives refuse, rather than crash, with no compositor."
  (skip-unless (fboundp 'gowl-set-force-seat-keyboard))
  (skip-unless (not (and (fboundp 'gowl-running-p) (gowl-running-p))))
  (should-error (gowl-set-force-seat-keyboard t))
  (should-error (gowl-seat-has-keyboard-p)))

(provide 'cmacs-gowl-seat-keyboard-tests)

;;; cmacs-gowl-seat-keyboard-tests.el ends here
