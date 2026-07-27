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
    (let* ((dest (cmacs-dbus-per-pid-name))
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
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Eval"
                  "(+ 40 2)")))
      (should (string-match-p "42" out)))))

(ert-deftest cmacs-dbus-eval-refuses-to-prompt ()
  "An RPC eval that would prompt errors instead of wedging the loop.
`cmacs_dispatch_eval' binds `inhibit-interaction', so a form that
reaches the minibuffer signals `inhibited-interaction' instead of
entering a recursive edit inside the GLib dispatch -- which used to
hang the request (and the editor) until a human answered the prompt."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Eval"
                  "(read-string \"never answered: \")")))
      (should (string-match-p "inhibited" (downcase out))))))

(ert-deftest cmacs-dbus-object-manager-empty-on-phase-1 ()
  "Phase 1 has no managed children; GetManagedObjects returns ()."
  (skip-unless (cmacs-feature-p 'glib))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method"
                  "org.freedesktop.DBus.ObjectManager.GetManagedObjects")))
      ;; Empty dict prints as "({},)" on gdbus.
      (should (string-match-p "{}" out)))))

;;; Phase 6 MCP-parity interfaces (consumed by emacsctl)

(ert-deftest cmacs-dbus-parity-ifaces-present ()
  "Introspection lists the Phase 6 parity interfaces."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "introspect" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor")))
      (dolist (iface '("org.cmacs.Editor1.Eshell"
                       "org.cmacs.Editor1.Edit"
                       "org.cmacs.Editor1.Input"
                       "org.cmacs.Editor1.Debug"
                       "org.cmacs.Editor1.Instance"
                       "org.cmacs.Editor1.Log"))
        (should (string-match-p (regexp-quote iface) out))))))

(ert-deftest cmacs-dbus-instance-info-json ()
  "Instance.Info returns JSON with this process's pid and features."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Instance.Info")))
      (should (string-match-p (format "pid.:%d" (emacs-pid)) out))
      (should (string-match-p "features" out)))))

(ert-deftest cmacs-dbus-log-recent-messages ()
  "Log.RecentMessages returns the tail of *Messages*."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (message "cmacs-dbus-log-test-marker")
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Log.RecentMessages"
                  "5")))
      (should (string-match-p "cmacs-dbus-log-test-marker" out)))))

(ert-deftest cmacs-dbus-eshell-eval ()
  "Eshell.Eval runs a command and returns its output."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session"
                  "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Eshell.Eval"
                  "echo dbus-eshell-ok")))
      (should (string-match-p "dbus-eshell-ok" out)))))

;;; Events endpoint (org.cmacs.Editor1.Events)

(ert-deftest cmacs-dbus-emit-event-returns-nil-when-stopped ()
  "`cmacs-dbus-emit-event' is a no-op returning nil when stopped."
  (skip-unless (fboundp 'cmacs-dbus-emit-event))
  (cmacs-dbus-stop)
  (should-not (cmacs-dbus-emit-event "file" "saved" "/tmp/x" '(:a 1))))

(ert-deftest cmacs-dbus-emit-event-returns-t-when-running ()
  "`cmacs-dbus-emit-event' returns t when the service is running."
  (skip-unless (fboundp 'cmacs-dbus-emit-event))
  (cmacs-dbus-tests--with-service
    (should (eq t (cmacs-dbus-emit-event
                   "file" "saved" "/tmp/x"
                   '(:file "/tmp/x" :buffer "x"))))))

(ert-deftest cmacs-dbus-events-introspect ()
  "The Events interface, firehose, and named signals are introspectable."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "introspect" "--session" "--dest" dest
                  "--object-path" "/org/cmacs/Editor")))
      (dolist (s '("org.cmacs.Editor1.Events" "Event" "FileOpened"
                   "BufferSwitched" "ProjectSwitched" "FrameOpened"
                   "EventTypes" "Recent"))
        (should (string-match-p (regexp-quote s) out))))))

(ert-deftest cmacs-dbus-events-event-types-method ()
  "Events.EventTypes returns the category/name taxonomy."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (cmacs-dbus-tests--with-service
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session" "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Events.EventTypes")))
      (should (string-match-p "file/opened" out))
      (should (string-match-p "buffer/switched" out)))))

(ert-deftest cmacs-dbus-events-recent-method ()
  "Events.Recent returns a JSON array reflecting recorded events."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (skip-unless (executable-find "gdbus"))
  (require 'cmacs-dbus-events)
  (cmacs-dbus-tests--with-service
    (cmacs-dbus-events--emit "file" "saved" "/tmp/marker-xyz"
                             '(:file "/tmp/marker-xyz"))
    (let* ((dest (cmacs-dbus-per-pid-name))
           (out  (cmacs-dbus-tests--gdbus
                  "call" "--session" "--dest" dest
                  "--object-path" "/org/cmacs/Editor"
                  "--method" "org.cmacs.Editor1.Events.Recent" "5")))
      (should (string-match-p "\\[" out))
      (should (string-match-p "marker-xyz" out)))))

(ert-deftest cmacs-dbus-events-ring-records ()
  "Emitting records into the ring; Recent JSON reflects it (in-process)."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (require 'cmacs-dbus-events)
  (cmacs-dbus-tests--with-service
    (let ((cmacs-dbus-events--ring nil))
      (cmacs-dbus-events--emit "file" "opened" "/tmp/abc" '(:file "/tmp/abc"))
      (let ((json (cmacs-dbus-events--recent-json 10)))
        (should (string-match-p "opened" json))
        (should (string-match-p "abc" json))))))

(ert-deftest cmacs-dbus-events-mode-toggles ()
  "`cmacs-dbus-events-mode' installs and removes its hooks cleanly."
  (skip-unless (fboundp 'cmacs-dbus-start))
  (require 'cmacs-dbus-events)
  (unwind-protect
      (progn
        (cmacs-dbus-events-mode 1)
        (should cmacs-dbus-events-mode)
        (should (member #'cmacs-dbus-events--on-find-file find-file-hook)))
    (cmacs-dbus-events-mode -1))
  (should-not cmacs-dbus-events-mode)
  (should-not (member #'cmacs-dbus-events--on-find-file find-file-hook)))

(provide 'cmacs-dbus-tests)

;;; cmacs-dbus-tests.el ends here
