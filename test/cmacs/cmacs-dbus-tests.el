;;; cmacs-dbus-tests.el --- Tests for the cmacs D-Bus subsystem -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for cmacs's D-Bus service.
;; Phase 1 covers: lifecycle (start/stop/name), dual bus-name claim
;; (well-known + per-PID), signal emit + properties-changed helpers,
;; ObjectManager registration, and back-compat preservation of the
;; org.cmacs.Editor1 method surface.
;;
;; Tests skip-unless `cmacs-feature-p 'glib' returns non-nil so they
;; are no-ops in builds without --with-cmacs-glib.

;;; Code:

(require 'ert)

(declare-function cmacs-feature-p "cmacs-glib-tests")

(defmacro cmacs-dbus-tests--with-service (&rest body)
  "Start the D-Bus service, run BODY, always stop."
  (declare (indent 0))
  `(unwind-protect
       (progn (cmacs-dbus-start) ,@body)
     (cmacs-dbus-stop)))

;;; Lifecycle

(ert-deftest cmacs-dbus-start-returns-string ()
  "`cmacs-dbus-start' returns a non-empty bus name."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-tests--with-service
    (let ((name (cmacs-dbus-name)))
      (should (stringp name))
      (should (string-prefix-p "org.cmacs.Editor" name)))))

(ert-deftest cmacs-dbus-start-idempotent ()
  "Calling `cmacs-dbus-start' twice returns the same name without error."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-tests--with-service
    (let ((name1 (cmacs-dbus-name))
          (name2 (cmacs-dbus-start)))
      (should (equal name1 name2)))))

(ert-deftest cmacs-dbus-stop-returns-t ()
  "`cmacs-dbus-stop' returns t when the service was running."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-start)
  (should (eq t (cmacs-dbus-stop))))

(ert-deftest cmacs-dbus-stop-when-not-running ()
  "`cmacs-dbus-stop' returns nil when the service was not running."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-stop)  ;; ensure stopped
  (should-not (cmacs-dbus-stop)))

;;; Dual bus-name claim

(ert-deftest cmacs-dbus-per-pid-name-format ()
  "Per-PID bus name follows org.cmacs.Editor.PidNNNN."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-tests--with-service
    (let ((name (cmacs-dbus-per-pid-name)))
      (should (stringp name))
      (should (string-match-p "\\`org\\.cmacs\\.Editor\\.Pid[0-9]+\\'" name)))))

(ert-deftest cmacs-dbus-well-known-or-per-pid ()
  "Dominant name is either well-known or per-PID; never nil while running."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-tests--with-service
    (let ((dominant (cmacs-dbus-name))
          (well     (cmacs-dbus-well-known-name))
          (per-pid  (cmacs-dbus-per-pid-name)))
      (should dominant)
      (should per-pid)
      (should (or (and well (equal dominant well))
                  (and (null well) (equal dominant per-pid)))))))

;;; Signal emit returns nil when stopped

(ert-deftest cmacs-dbus-emit-signal-returns-nil-when-stopped ()
  "`cmacs-dbus-emit-signal' is a no-op returning nil when the service
is not running."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-stop)
  (should-not (cmacs-dbus-emit-signal "/org/cmacs/Editor"
                                      "org.cmacs.Editor1.Test"
                                      "Bang"
                                      nil)))

(ert-deftest cmacs-dbus-emit-signal-returns-t-when-running ()
  "`cmacs-dbus-emit-signal' returns t when the service is running."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-tests--with-service
    (should (eq t (cmacs-dbus-emit-signal
                   "/org/cmacs/Editor"
                   "org.cmacs.Editor1.Test"
                   "Bang"
                   '("hello" 42))))))

(ert-deftest cmacs-dbus-emit-properties-changed-returns-t-when-running ()
  "`cmacs-dbus-emit-properties-changed' accepts a plist + invalidated list."
  (skip-unless (cmacs-feature-p 'glib))
  (cmacs-dbus-tests--with-service
    (should (eq t (cmacs-dbus-emit-properties-changed
                   "/org/cmacs/Editor"
                   "org.cmacs.Editor1.Test"
                   '(:name "scratch" :modified t)
                   '("Stale"))))))

;;; gdbus introspection round-trip
;;
;; Method-call tests must NOT use call-process: it blocks the cmacs main
;; thread, preventing the GLib loop from servicing the inbound D-Bus
;; request, which gdbus then times out on.  Use make-process + sit-for
;; so the parent loop can dispatch while the child runs gdbus.

(defun cmacs-dbus-tests--gdbus (&rest args)
  "Run gdbus with ARGS via make-process; return collected output.
Pumps the cmacs main loop while gdbus runs so the embedded D-Bus
service can dispatch the inbound call."
  (let* ((buf (generate-new-buffer " *gdbus-test*"))
         (proc (make-process
                :name "gdbus-test"
                :command (cons "gdbus" args)
                :buffer buf
                :noquery t)))
    (unwind-protect
        (progn
          (while (process-live-p proc)
            (accept-process-output proc 0.1)
            (sit-for 0.05))
          (with-current-buffer buf (buffer-string)))
      (kill-buffer buf))))

(ert-deftest cmacs-dbus-introspect-shows-all-ifaces ()
  "`gdbus introspect' returns ObjectManager + Editor1 + Properties."
  (skip-unless (cmacs-feature-p 'glib))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-name))
           (out  (cmacs-dbus-tests--gdbus
                  "introspect" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor")))
      (should (string-match-p "org\\.cmacs\\.Editor1" out))
      (should (string-match-p "org\\.freedesktop\\.DBus\\.ObjectManager" out))
      (should (string-match-p "GetManagedObjects" out)))))

(ert-deftest cmacs-dbus-back-compat-eval-method ()
  "The back-compat Eval method on org.cmacs.Editor1 still answers."
  (skip-unless (cmacs-feature-p 'glib))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Eval"
                  "(+ 40 2)")))
      (should (string-match-p "42" out)))))

(ert-deftest cmacs-dbus-object-manager-empty-on-phase-1 ()
  "Phase 1 has no managed children; GetManagedObjects returns ()."
  (skip-unless (cmacs-feature-p 'glib))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method"
                  "org.freedesktop.DBus.ObjectManager.GetManagedObjects")))
      ;; Empty dict prints as "({},)" on gdbus.
      (should (string-match-p "{}" out)))))

(provide 'cmacs-dbus-tests)

;;; cmacs-dbus-tests.el ends here
