;;; cmacs-gowl-tests.el --- Tests for gowl compositor integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs gowl Wayland compositor integration.
;; Tests cover compositor lifecycle (start/stop/running-p), client
;; management (list, info, focus, close, move, resize, tags),
;; monitor listing, tag switching, layout setting, and spawning.
;;
;; NOTE: Many tests cannot fully exercise the compositor without a
;; running Wayland session.  Tests that require an active compositor
;; use `gowl-running-p' as a skip guard.  Error-path tests can run
;; without a compositor.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
;; The cheatsheet helpers are internal, so nothing autoloads them.
(require 'cmacs-gowl)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Running predicate tests

(ert-deftest cmacs-gowl-test-running-p-returns-boolean ()
  "Test that `gowl-running-p' returns t or nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (let ((result (gowl-running-p)))
    (should (memq result '(t nil)))))

;;; Start/stop lifecycle tests

(ert-deftest cmacs-gowl-test-start-already-running ()
  "Test that `gowl-start' errors when compositor is already running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-start)
                :type 'error))

(ert-deftest cmacs-gowl-test-stop-returns-nil ()
  "Test that `gowl-stop' returns nil."
  (skip-unless (cmacs-feature-p 'gowl))
  ;; Only test the return value semantics; don't actually stop a
  ;; live compositor during testing.
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-stop)))

(ert-deftest cmacs-gowl-test-stop-when-not-running ()
  "Test that `gowl-stop' is a no-op when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-stop)))

;;; A real compositor, started and stopped in a second cmacs

(defun cmacs-gowl-tests--runtime-parent ()
  "The runtime directory a test's private one is made in, or nil."
  (let ((dir (getenv "XDG_RUNTIME_DIR")))
    (and dir (file-directory-p dir) dir)))

(defun cmacs-gowl-tests--run-headless (form &optional extra-env)
  "Evaluate FORM in a second cmacs, against gowl's headless backend.
Return (STATUS . OUTPUT).  The child gets a runtime directory of its
own inside $XDG_RUNTIME_DIR (a socket path has 108 bytes), systemd off,
no parent display, the pixman renderer and fatal GLib criticals.  It
runs in that directory, with its state and config directories inside
it: the clipboard module makes a store under the state directory at
startup, and a gowl config reload finds data/config.yaml relative to
where it runs before it looks at the user's.  EXTRA-ENV entries come
first, so they win.  A compositor started in the test process itself
would outlive the test, and nothing would fail on a critical."
  (let* ((runtime (make-temp-file
                   (expand-file-name "cmacs-gowl-test-"
                                     (cmacs-gowl-tests--runtime-parent))
                   t))
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
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "120" emacs))
                                       ;; The error, not the whole form
                                       ;; printed again at every frame.
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defconst cmacs-gowl-tests--start-stop-form
  '(let ((runtime (getenv "XDG_RUNTIME_DIR")))
     (dotimes (cycle 2)
       (gowl-start)
       (unless (gowl-running-p)
         (error "Cycle %d: not running after `gowl-start'" cycle))
       (unless (directory-files runtime nil "\\`wayland-[0-9]+\\'")
         (error "Cycle %d: the compositor has no socket" cycle))
       (unless (gowl-clipboard-watch)
         (error "Cycle %d: `gowl-clipboard-watch' connected nothing" cycle))
       (gowl-stop)
       (when (gowl-running-p)
         (error "Cycle %d: still running after `gowl-stop'" cycle))
       (when (directory-files runtime nil "\\`wayland-[0-9]+\\'")
         (error "Cycle %d: `gowl-stop' left the compositor alive" cycle)))
     ;; A wrapper keeps the compositor alive past `gowl-stop'.  It goes,
     ;; with the module manager and config it owns, when the wrapper is
     ;; collected.
     (gowl-start)
     (let ((held (gowl-compositor)))
       (gowl-stop)
       (ignore held))
     (when (directory-files runtime nil "\\`wayland-[0-9]+\\'")
       (dotimes (_ 5)
         (garbage-collect))
       (when (directory-files runtime nil "\\`wayland-[0-9]+\\'")
         (message "The compositor the wrapper held was never collected")
         (kill-emacs 77)))
     (princ "cmacs-gowl-start-stop: ok\n"))
  "What `cmacs-gowl-test-start-stop-headless' runs in the second cmacs.")

(defconst cmacs-gowl-tests--failed-start-form
  '(progn
     (condition-case nil
         (progn
           (gowl-start)
           (error "`gowl-start' succeeded on a backend wlroots lacks"))
       (gowl-error nil))
     (when (gowl-running-p)
       (error "A failed `gowl-start' left a compositor behind"))
     ;; Nothing to stop, and saying so must not touch what is gone.
     (gowl-stop)
     (princ "cmacs-gowl-failed-start: ok\n"))
  "What `cmacs-gowl-test-failed-start-headless' runs in the second cmacs.")

(ert-deftest cmacs-gowl-test-start-stop-headless ()
  "`gowl-start' and `gowl-stop' really bring a compositor up and down.
Each of two cycles checks that `gowl-stop' finalizes the compositor --
its socket goes -- and that the next start finds clean state:
`gowl-clipboard-watch' used to report the first compositor's handlers
and connect nothing.  Then a `gowl-compositor' wrapper keeps one alive
past `gowl-stop', and collecting the wrapper finalizes it with the
module manager and config it owns.  Releasing those in `gowl-stop'
itself would leave that compositor to be finalized against freed
memory.  GLib criticals are fatal throughout, so the module teardown
`gowl-stop' runs -- shutdown hooks while the compositor lives, every
module deactivated after it -- has to be clean too."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (cmacs-gowl-tests--runtime-parent))
  (let* ((result (cmacs-gowl-tests--run-headless
                  cmacs-gowl-tests--start-stop-form))
         (status (car result))
         (output (cdr result)))
    (when (eql status 77)
      (ert-skip "the compositor a wrapper held was never garbage-collected"))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-search "cmacs-gowl-start-stop: ok" output)))))

(ert-deftest cmacs-gowl-test-failed-start-headless ()
  "A `gowl-start' that fails leaves nothing running and nothing half-built.
By the time wlroots refuses the backend, the compositor owns its config
and a module manager with every default module loaded; all of it goes
on the way out, and with GLib criticals fatal, taking down a compositor
that never started has to be clean."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (cmacs-gowl-tests--runtime-parent))
  (let* ((result (cmacs-gowl-tests--run-headless
                  cmacs-gowl-tests--failed-start-form
                  '("WLR_BACKENDS=cmacs-test-no-such-backend")))
         (status (car result))
         (output (cdr result)))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-search "cmacs-gowl-failed-start: ok" output)))))

(defconst cmacs-gowl-tests--reset-config-form
  '(let ((rss (lambda ()
                (with-temp-buffer
                  (insert-file-contents "/proc/self/status")
                  (re-search-forward "^VmRSS:[ \t]*\\([0-9]+\\)")
                  (string-to-number (match-string 1))))))
     (gowl-start)
     ;; gowl's own reload first: it reads data/config.yaml, here, into a
     ;; config the compositor makes and releases itself.  It used to
     ;; release the config cmacs gave it instead -- freed memory at
     ;; once, and cmacs released it again at the reset or the stop
     ;; below.  Values are read with `gowl-config-get', never through a
     ;; `gowl-config-object' wrapper, whose reference would keep that
     ;; config alive and hide the bug.
     (make-directory "data" t)
     (with-temp-file "data/config.yaml"
       (insert "border-width: 9\n"))
     (let ((default (gowl-config-get "border-width")))
       (gowl-add-keybind "Super+Shift+r" 'reload-config)
       (unless (gowl-run-keybind "Super+Shift+r")
         (error "The reload bind did not run"))
       (unless (eql (gowl-config-get "border-width") 9)
         (error "The reload bind did not load data/config.yaml"))
       ;; The reset is real: the value comes back to its default.
       (gowl-reload-config)
       (unless (eql (gowl-config-get "border-width") default)
         (error "`gowl-reload-config' did not reset border-width")))
     ;; And the config each reset replaces goes.  Warm up first, so that
     ;; what is measured is steady state rather than the allocator
     ;; settling.
     (dotimes (_ 200)
       (gowl-reload-config))
     (garbage-collect)
     (let ((before (funcall rss)))
       (dotimes (_ 2000)
         (gowl-reload-config))
       (garbage-collect)
       (princ (format "cmacs-gowl-reset-config: grew %d kB\n"
                      (- (funcall rss) before))))
     (gowl-stop))
  "What `cmacs-gowl-test-reset-config-frees-the-old-one' runs.")

(ert-deftest cmacs-gowl-test-reset-config-frees-the-old-one ()
  "`gowl-reload-config' with no file resets the config and frees the old one.
The reset makes a new config object, and the one it replaced used to
be kept forever: about 4 kB a call, 8 MB over the 2000 resets here.
Growing by less than a kilobyte a reset leaves room for the allocator
and nothing for a leaked config.  gowl's own reload keybind runs
first, because it used to release the config cmacs owns: a
use-after-free at once, and a second release at the reset or the
stop."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (cmacs-gowl-tests--runtime-parent))
  (let* ((result (cmacs-gowl-tests--run-headless
                  cmacs-gowl-tests--reset-config-form))
         (status (car result))
         (output (cdr result))
         (grown (and (string-match "cmacs-gowl-reset-config: grew \\(-?[0-9]+\\) kB"
                                   output)
                     (string-to-number (match-string 1 output)))))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should grown)
      (should (< grown 2000)))))

;;; Client list tests

(ert-deftest cmacs-gowl-test-list-clients-returns-list ()
  "Test that `gowl-list-clients' returns a list."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (should (listp clients))))

(ert-deftest cmacs-gowl-test-list-clients-not-running ()
  "Test that `gowl-list-clients' returns nil when not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-list-clients)))

(ert-deftest cmacs-gowl-test-list-clients-all-gobjects ()
  "Test that all items in client list are GObjects."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (dolist (c clients)
      (should (gobject-p c)))))

;;; Client info tests

(ert-deftest cmacs-gowl-test-client-info-non-gobject ()
  "Test that `gowl-client-info' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-client-info 42)
                :type 'error))

(ert-deftest cmacs-gowl-test-client-info-nil ()
  "Test that `gowl-client-info' errors for nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-client-info nil)
                :type 'error))

(ert-deftest cmacs-gowl-test-client-info-returns-alist ()
  "Test that `gowl-client-info' returns expected alist keys."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (let ((info (gowl-client-info (car clients))))
      (should (listp info))
      ;; The keys are symbols: `assoc' on strings never matched them.
      (should (natnump (cdr (assq 'id info))))
      (should (assq 'title info))
      (should (assq 'app-id info))
      (should (assq 'tags info))
      (should (assq 'floating info))
      (should (assq 'geometry info)))))

;;; Focus tests

(ert-deftest cmacs-gowl-test-focus-client-non-gobject ()
  "Test that `gowl-focus-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-focus-client 42)
                :type 'error))

(ert-deftest cmacs-gowl-test-focus-client-nil ()
  "Test that `gowl-focus-client' errors for nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-focus-client nil)
                :type 'error))

;;; Move client tests

(ert-deftest cmacs-gowl-test-move-client-non-gobject ()
  "Test that `gowl-move-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-move-client 42 0 0)
                :type 'error))

(ert-deftest cmacs-gowl-test-move-client-non-integer-coords ()
  "Test that `gowl-move-client' rejects non-integer coordinates."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (should-error (gowl-move-client (car clients) "bad" 0)
                  :type 'wrong-type-argument)))

;;; Resize client tests

(ert-deftest cmacs-gowl-test-resize-client-non-gobject ()
  "Test that `gowl-resize-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-resize-client 42 100 100)
                :type 'error))

(ert-deftest cmacs-gowl-test-resize-client-non-integer-dims ()
  "Test that `gowl-resize-client' rejects non-integer dimensions."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (should-error (gowl-resize-client (car clients) "bad" 100)
                  :type 'wrong-type-argument)))

;;; Close client tests

(ert-deftest cmacs-gowl-test-close-client-non-gobject ()
  "Test that `gowl-close-client' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-close-client 42)
                :type 'error))

(ert-deftest cmacs-gowl-test-close-client-nil ()
  "Test that `gowl-close-client' errors for nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-close-client nil)
                :type 'error))

;;; Set tags tests

(ert-deftest cmacs-gowl-test-set-tags-non-gobject ()
  "Test that `gowl-set-tags' errors for non-GObject."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-tags 42 1)
                :type 'error))

(ert-deftest cmacs-gowl-test-set-tags-requires-fixnat ()
  "Test that `gowl-set-tags' requires a non-negative integer bitmask."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((clients (gowl-list-clients)))
    (skip-unless clients)
    (should-error (gowl-set-tags (car clients) "bad")
                  :type 'wrong-type-argument)))

;;; Monitor tests

(ert-deftest cmacs-gowl-test-list-monitors-returns-list ()
  "Test that `gowl-list-monitors' returns a list."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((monitors (gowl-list-monitors)))
    (should (listp monitors))))

(ert-deftest cmacs-gowl-test-list-monitors-not-running ()
  "Test that `gowl-list-monitors' returns nil when not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-list-monitors)))

(ert-deftest cmacs-gowl-test-list-monitors-all-gobjects ()
  "Test that all items in monitor list are GObjects."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (cmacs-feature-p 'gobject))
  (skip-unless (gowl-running-p))
  (let ((monitors (gowl-list-monitors)))
    (dolist (m monitors)
      (should (gobject-p m)))))

;;; View tags tests

(ert-deftest cmacs-gowl-test-view-tags-requires-fixnat ()
  "Test that `gowl-view-tags' requires a non-negative integer tagmask."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-view-tags "bad")
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-view-tags-not-running ()
  "Test that `gowl-view-tags' errors when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-view-tags 1)
                :type 'error))

;;; Layout tests

(ert-deftest cmacs-gowl-test-set-layout-requires-string ()
  "Test that `gowl-set-layout' requires a string layout name."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-layout 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-set-layout-not-running ()
  "Test that `gowl-set-layout' errors when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-set-layout "tile")
                :type 'error))

;;; Spawn tests

(ert-deftest cmacs-gowl-test-spawn-requires-string ()
  "Test that `gowl-spawn' requires a string command."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-spawn 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-spawn-not-running ()
  "Test that `gowl-spawn' errors when compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-spawn "echo hello")
                :type 'error))

;; Edge cases
(ert-deftest cmacs-gowl-start-stop-cycle ()
  "Start/stop cycle should leave clean state."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (not (gowl-running-p)))
  ;; Gowl may not start without a display, so just test stop is safe
  (gowl-stop)
  (should-not (gowl-running-p)))

(ert-deftest cmacs-gowl-spawn-empty-string ()
  "Spawning empty command should error or handle gracefully."
  (skip-unless (fboundp 'gowl-spawn))
  (skip-unless (gowl-running-p))
  (should-error (gowl-spawn "")))

(ert-deftest cmacs-gowl-view-tags-zero ()
  "Tag mask of zero should be valid (show no tags)."
  (skip-unless (fboundp 'gowl-view-tags))
  (skip-unless (gowl-running-p))
  (gowl-view-tags 0))

(ert-deftest cmacs-gowl-move-client-negative-coords ()
  "Moving to negative coordinates should not crash."
  (skip-unless (fboundp 'gowl-move-client))
  ;; Without a real client, this should error on the type check
  (should-error (gowl-move-client nil -100 -200)))

(ert-deftest cmacs-gowl-resize-client-zero ()
  "Resizing to zero dimensions should not crash."
  (skip-unless (fboundp 'gowl-resize-client))
  (should-error (gowl-resize-client nil 0 0)))

(ert-deftest cmacs-gowl-set-layout-invalid ()
  "Setting an invalid layout string should not crash."
  (skip-unless (fboundp 'gowl-set-layout))
  (skip-unless (gowl-running-p))
  ;; Even an invalid name should not crash -- the function may just ignore it
  (gowl-set-layout "nonexistent_layout"))

(ert-deftest cmacs-gowl-client-info-nil ()
  "Getting info for nil should error."
  (skip-unless (fboundp 'gowl-client-info))
  (should-error (gowl-client-info nil)))

;;; Module management tests

(ert-deftest cmacs-gowl-test-enable-module-not-running ()
  "Enabling a module without a running compositor should error."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-enable-module "alpha") :type 'error))

(ert-deftest cmacs-gowl-test-enable-module-bad-name ()
  "Enabling a nonexistent module should signal gowl-error."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-enable-module "nonexistent-module-xyz")
                :type 'gowl-error))

(ert-deftest cmacs-gowl-test-enable-module-type-check ()
  "gowl-enable-module should reject non-string arguments."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-enable-module 42) :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-disable-module-not-loaded ()
  "Disabling a module that isn't loaded should return nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-not (gowl-disable-module "nonexistent-module-xyz")))

(ert-deftest cmacs-gowl-test-disable-module-type-check ()
  "gowl-disable-module should reject non-string arguments."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-disable-module 42) :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-configure-module-type-check ()
  "gowl-configure-module should reject non-string name."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-configure-module 42 '()) :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-configure-module-alist-check ()
  "gowl-configure-module should reject non-list alist."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-configure-module "test" 42) :type 'wrong-type-argument))

;;; Alpha convenience DEFUN tests

(ert-deftest cmacs-gowl-test-set-client-alpha-type-check ()
  "gowl-set-client-alpha should reject nil client."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-client-alpha nil 0.5) :type 'error))

(ert-deftest cmacs-gowl-test-alpha-info-no-module ()
  "gowl-alpha-info returns nil when alpha module is not loaded."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should (null (gowl-alpha-info))))

(ert-deftest cmacs-gowl-test-set-focused-alpha-type-check ()
  "gowl-set-focused-alpha should reject non-number."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-focused-alpha "bad") :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-set-unfocused-alpha-type-check ()
  "gowl-set-unfocused-alpha should reject non-number."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-unfocused-alpha "bad") :type 'wrong-type-argument))

;;; Gaps convenience DEFUN tests

(ert-deftest cmacs-gowl-test-gaps-info-no-module ()
  "gowl-gaps-info returns nil when vanitygaps module is not loaded."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should (null (gowl-gaps-info))))

(ert-deftest cmacs-gowl-test-set-gaps-type-check ()
  "gowl-set-gaps should reject non-list argument."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-set-gaps 42) :type 'wrong-type-argument))

;;; Screenlock convenience DEFUN tests

(ert-deftest cmacs-gowl-test-configure-screenlock-type-check ()
  "gowl-configure-screenlock should reject non-list argument."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-configure-screenlock 42) :type 'wrong-type-argument))

;;; Scratchpad convenience DEFUN tests

(ert-deftest cmacs-gowl-test-scratchpad-toggle-type-check ()
  "gowl-scratchpad-toggle should reject non-string argument."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-error (gowl-scratchpad-toggle 42) :type 'wrong-type-argument))

;;; Window rule DEFUN tests

(ert-deftest cmacs-gowl-test-add-rule-full-round-trip ()
  "`gowl-add-rule-full' then `gowl-list-rules' returns the rule."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((marker (format "test-rule-%d" (random 100000))))
    (unwind-protect
        (progn
          (gowl-add-rule-full marker nil 0 t -1 0 0 nil)
          (let* ((rules (gowl-list-rules))
                 (found (seq-find
                          (lambda (r)
                            (equal (cdr (assq 'app-id r)) marker))
                          rules)))
            (should found)
            (should (equal (cdr (assq 'floating found)) t))
            (should (equal (cdr (assq 'regex found)) nil))))
      (gowl-remove-rule marker nil))))

(ert-deftest cmacs-gowl-test-add-rule-regex-flag ()
  "Regex rules round-trip with the :regex field set."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (unwind-protect
      (progn
        (gowl-add-rule-full nil "^Zoom.*" 0 t -1 0 0 t)
        (let* ((rules (gowl-list-rules))
               (found (seq-find
                        (lambda (r)
                          (equal (cdr (assq 'title r)) "^Zoom.*"))
                        rules)))
          (should found)
          (should (equal (cdr (assq 'regex found)) t))))
    (gowl-remove-rule nil "^Zoom.*")))

(ert-deftest cmacs-gowl-test-remove-rule-returns-nil-for-missing ()
  "Removing a non-existent rule returns nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-not (gowl-remove-rule "nonexistent-app-id-xyz-123" nil)))

(ert-deftest cmacs-gowl-test-clear-rules-empties-list ()
  "`gowl-clear-rules' removes every rule."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  ;; Snapshot for restoration.
  (let ((snapshot (gowl-list-rules)))
    (unwind-protect
        (progn
          (gowl-clear-rules)
          (should (null (gowl-list-rules))))
      ;; Restore.
      (dolist (r snapshot)
        (gowl-add-rule-full
          (cdr (assq 'app-id r))
          (cdr (assq 'title r))
          (cdr (assq 'tags r))
          (cdr (assq 'floating r))
          (cdr (assq 'monitor r))
          (cdr (assq 'width r))
          (cdr (assq 'height r))
          (cdr (assq 'regex r)))))))

;;; Dropdown DEFUN tests

(ert-deftest cmacs-gowl-test-add-dropdown-round-trip ()
  "`gowl-add-dropdown' then `gowl-list-dropdowns' returns the entry."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((marker (format "test-dd-%d" (random 100000))))
    (unwind-protect
        (progn
          (gowl-add-dropdown marker "true" nil 1.0 0.4 0 0 'top)
          (let* ((dds (gowl-list-dropdowns))
                 (found (seq-find
                          (lambda (d)
                            (equal (cdr (assq 'name d)) marker))
                          dds)))
            (should found)
            (should (equal (cdr (assq 'spawn-cmd found)) "true"))
            (should (equal (cdr (assq 'anchor found)) 'top))))
      (gowl-remove-dropdown marker))))

(ert-deftest cmacs-gowl-test-add-dropdown-type-check ()
  "`gowl-add-dropdown' requires NAME and SPAWN-CMD strings."
  (skip-unless (cmacs-feature-p 'gowl))
  ;; The DEFUN runs GOWL_CHECK_RUNNING before CHECK_STRING, so the
  ;; type check is only reachable with a live compositor.
  (skip-unless (gowl-running-p))
  (should-error (gowl-add-dropdown 42 "foo" nil 1.0 0.4 0 0 'top)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gowl-test-remove-dropdown-returns-nil-for-missing ()
  "Removing a non-existent dropdown returns nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-not (gowl-remove-dropdown "nonexistent-dropdown-xyz-123")))

(ert-deftest cmacs-gowl-test-dropdown-toggle-type-check ()
  "`gowl-dropdown-toggle' requires a string argument."
  (skip-unless (cmacs-feature-p 'gowl))
  ;; GOWL_CHECK_RUNNING precedes the type check; needs a compositor.
  (skip-unless (gowl-running-p))
  (should-error (gowl-dropdown-toggle 42) :type 'wrong-type-argument))

;;; Customization integration tests

(ert-deftest cmacs-gowl-test-float-rules-defaults-valid ()
  "Every shipped default float rule has a non-nil pattern."
  (require 'cmacs-gowl)
  (dolist (r cmacs-gowl-float-rules)
    (should (or (plist-get r :app-id) (plist-get r :title)))))

(ert-deftest cmacs-gowl-test-dropdowns-defaults-valid ()
  "Every shipped default dropdown has a :name and either a spawn-cmd
or nil (which falls back to `cmacs-gowl-default-dropdown-terminal')."
  (require 'cmacs-gowl)
  (dolist (d cmacs-gowl-dropdowns)
    (should (plist-get d :name))))

;;; Tag keybindings and launch-into-tag tests

(ert-deftest cmacs-gowl-test-default-keybinds-tag-bitmasks ()
  "The keybind installer passes tag-action args as raw bitmasks.
The compositor interprets a tag-action arg as `atoi(arg) & TAGMASK',
so tag N must be (ash 1 (1- N)) and \"view all\" must be (1<<9)-1,
not the plain tag number / \"0\" that gowl's default-config.c uses."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  (let ((captured nil)
        (cmacs-gowl--keybinds-installed nil))
    (cl-letf (((symbol-function 'gowl-add-keybind)
               (lambda (key action &optional arg)
                 (push (list key action arg) captured))))
      (cmacs-gowl--install-default-keybinds))
    ;; tag 1 -> bit 0 = "1", tag 3 -> bit 2 = "4", tag 9 -> bit 8 = "256".
    (should (member '("Super+1" tag-view "1") captured))
    (should (member '("Super+3" tag-view "4") captured))
    (should (member '("Super+9" tag-view "256") captured))
    ;; Shift moves the focused client to that tag.
    (should (member '("Super+Shift+3" tag-set "4") captured))
    ;; Ctrl toggles the tag's visibility; Shift+Ctrl toggles on client.
    (should (member '("Super+Ctrl+3" tag-toggle-view "4") captured))
    (should (member '("Super+Shift+Ctrl+3" tag-toggle "4") captured))
    ;; "All tags" is the full mask (1<<9)-1 = 511, never "0" (a no-op).
    (should (member '("Super+0" tag-view "511") captured))
    (should (member '("Super+Shift+0" tag-set "511") captured))
    (should-not (member '("Super+0" tag-view "0") captured))
    ;; Launcher + terminal binds are present.
    (should (cl-find-if (lambda (e) (and (equal (car e) "Super+p")
                                         (eq (nth 1 e) 'spawn)))
                        captured))
    (should (cl-find-if (lambda (e) (and (equal (car e) "Super+Return")
                                         (eq (nth 1 e) 'spawn)))
                        captured))))

(ert-deftest cmacs-gowl-test-bemenu-binary-strips-run ()
  "`cmacs-gowl--bemenu-binary' derives the dmenu-mode binary name."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (let ((cmacs-gowl-dmenu-command "bemenu-run"))
    (should (equal (cmacs-gowl--bemenu-binary) "bemenu")))
  (let ((cmacs-gowl-dmenu-command "bemenu"))
    (should (equal (cmacs-gowl--bemenu-binary) "bemenu")))
  (let ((cmacs-gowl-dmenu-command "rofi -show drun"))
    (should (equal (cmacs-gowl--bemenu-binary) "rofi"))))

(ert-deftest cmacs-gowl-test-launch-commands-defined ()
  "Tag-launch commands and the pretag primitive are available."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (commandp 'cmacs-gowl-spawn-in-tag))
  (should (commandp 'cmacs-gowl-launch-in-tag))
  (should (commandp 'cmacs-gowl-bemenu-in-tag))
  (should (commandp 'cmacs-gowl-toggle-tag))
  (should (commandp 'cmacs-gowl-assign-monitor-tags))
  (should (fboundp 'gowl-pretag-pid))
  ;; gowl-pretag-pid takes (PID TAGMASK &optional MONITOR).
  (should (equal (func-arity 'gowl-pretag-pid) '(2 . 3))))

(ert-deftest cmacs-gowl-test-assign-monitor-tags ()
  "`cmacs-gowl-assign-monitor-tags' views tag i+1 on monitor i."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  (let ((calls nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda () t))
              ((symbol-function 'gowl-list-monitors)
               (lambda () '(:m0 :m1 :m2)))
              ((symbol-function 'gowl-monitor-enabled-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-view-tags)
               (lambda (mask mon &rest _) (push (cons mon mask) calls)))
              ((symbol-function 'cmacs-gowl--bar-redraw) #'ignore))
      (cmacs-gowl-assign-monitor-tags))
    ;; monitor 0 → tag 1 (bit 0 = 1), 1 → tag 2 (2), 2 → tag 3 (4).
    (should (equal (assoc :m0 calls) '(:m0 . 1)))
    (should (equal (assoc :m1 calls) '(:m1 . 2)))
    (should (equal (assoc :m2 calls) '(:m2 . 4)))))

(ert-deftest cmacs-gowl-test-monitor-index-showing-tag ()
  "`cmacs-gowl--monitor-index-showing-tag' finds the monitor viewing a tag."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  ;; Three monitors viewing tags 1, 2, 4 (bits 0, 1, 2).
  (cl-letf (((symbol-function 'gowl-list-monitors)
             (lambda () '(:m0 :m1 :m2)))
            ((symbol-function 'gowl-monitor-info)
             (lambda (m)
               (list (cons 'tags (pcase m (:m0 1) (:m1 2) (:m2 4)))))))
    (should (equal (cmacs-gowl--monitor-index-showing-tag 1) 0))
    (should (equal (cmacs-gowl--monitor-index-showing-tag 2) 1))
    (should (equal (cmacs-gowl--monitor-index-showing-tag 4) 2))
    ;; A tag shown on no monitor (fewer monitors than tags) → nil.
    (should (null (cmacs-gowl--monitor-index-showing-tag 8)))))

(ert-deftest cmacs-gowl-test-picker-commands-defined ()
  "The M-x tag/window pickers are interactive commands."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (commandp 'cmacs-gowl-switch-tag))
  (should (commandp 'cmacs-gowl-switch-to-app))
  (should (commandp 'cmacs-gowl-view-tag))
  (should (fboundp 'cmacs-gowl--refresh-view)))

(ert-deftest cmacs-gowl-test-tag-mask-label ()
  "`cmacs-gowl--tag-mask-label' renders tag bitmasks compactly."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (equal (cmacs-gowl--tag-mask-label 1) "1"))
  (should (equal (cmacs-gowl--tag-mask-label 4) "3"))
  (should (equal (cmacs-gowl--tag-mask-label 6) "2,3"))
  (should (equal (cmacs-gowl--tag-mask-label 256) "9"))
  (should (equal (cmacs-gowl--tag-mask-label 0) "—")))

(ert-deftest cmacs-gowl-test-client-label ()
  "`cmacs-gowl--client-label' formats title, app-id and tag."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (string-match-p
           "Firefox.*\\[firefox\\].*tag 2"
           (cmacs-gowl--client-label
            '((title . "Firefox") (app-id . "firefox") (tags . 2)))))
  ;; Untitled + no app-id still yields a usable label.
  (should (string-match-p
           "(untitled).*tag 1"
           (cmacs-gowl--client-label
            '((title . "") (app-id . "") (tags . 1))))))

(ert-deftest cmacs-gowl-test-spawn-in-tag-requires-running ()
  "`cmacs-gowl-spawn-in-tag' errors when the compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (skip-unless (not (gowl-running-p)))
  (should-error (cmacs-gowl-spawn-in-tag "true" 2)))

(ert-deftest cmacs-gowl-test-pretag-pid-requires-running ()
  "`gowl-pretag-pid' errors when the compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-pretag-pid 12345 2)))

(ert-deftest cmacs-gowl-test-pretag-pid-type-checks ()
  "`gowl-pretag-pid' type-checks its PID and TAGMASK arguments."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-pretag-pid "notapid" 2) :type 'wrong-type-argument)
  (should-error (gowl-pretag-pid 123 "notamask") :type 'wrong-type-argument))

;;; Layer-surface keyboard grab
;;
;; Regression coverage for the "wofi maps, is drawn on top, and is
;; completely deaf" defect reported by Ben Doty on 2026-08-08.  A
;; keyboard-interactive layer surface is granted the keyboard by the
;; compositor's `arrangelayers', and every cmacs path that moves seat
;; keyboard focus must then leave it alone until it unmaps.
;;
;; cmacs moves seat focus by calling `wlr_seat_keyboard_notify_enter'
;; directly rather than going through `gowl_compositor_focus_client'
;; -- embedded clients are deliberately invisible to the compositor's
;; focus stack -- so the compositor's own guards do NOT cover these
;; paths.  `cmacs_gowl_layer_owns_keyboard' is the only thing that
;; does, and the source-shape test below is what keeps it that way: a
;; new seat-focus path that forgets the check reintroduces the bug,
;; and no runtime test can catch that without a live compositor, a
;; live layer-shell client, and a Wayland session.
;;
;; The decision logic itself (which layer surfaces take the keyboard,
;; which focus changes are refused) is unit-tested on the gowl side in
;; `deps/gowl/tests/test-focus-rules.c'.

(defconst cmacs-gowl-tests--this-file
  (or load-file-name buffer-file-name)
  "Absolute path of this test file, captured at load time.
`load-file-name' is nil while ERT bodies run, so the source-shape
tests below cannot resolve the tree from inside a test.")

(defun cmacs-gowl-tests--source-file (relative)
  "Return the absolute path of RELATIVE inside the cmacs source tree.
Resolves against this test file's own location, so it works from a
worktree or an out-of-tree test run.  Returns nil when the file is
not present (installed trees ship no C sources)."
  (let* ((here (or cmacs-gowl-tests--this-file
                   (locate-library "cmacs-gowl-tests")))
         (root (and here
                    (expand-file-name "../.." (file-name-directory here))))
         (file (and root (expand-file-name relative root))))
    (and file (file-readable-p file) file)))

(defun cmacs-gowl-tests--strip-c-comments ()
  "Replace every /* ... */ comment in the current buffer with a space.
The C sources document these call sites at length, quoting the very
identifiers the tests search for, so the prose has to go before any
call-site matching can mean anything."
  (goto-char (point-min))
  (while (re-search-forward "/\\*" nil t)
    (let ((start (match-beginning 0)))
      (if (re-search-forward "\\*/" nil t)
          (delete-region start (point))
        ;; Unterminated comment: drop the rest of the buffer.
        (delete-region start (point-max))))))

(defun cmacs-gowl-tests--defun-bodies (source symbol)
  "Return the code of each top-level C function in SOURCE calling SYMBOL.
Comments are stripped first.  A body runs from the enclosing top-level
function's opening brace (a `{' in column 0) through to the SYMBOL
call.  Good enough to answer \"was the guard checked before this
call?\" without parsing C."
  (let ((bodies nil))
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (goto-char (point-min))
      (while (re-search-forward
              (concat "\\_<" (regexp-quote symbol) "\\_>[[:space:]]*(")
              nil t)
        (let ((call-end (point))
              (start (save-excursion
                       (if (re-search-backward "^{" nil t)
                           (point)
                         (point-min)))))
          (push (buffer-substring-no-properties start call-end)
                bodies))))
    (nreverse bodies)))

(ert-deftest cmacs-gowl-test-seat-focus-paths-check-layer-grab ()
  "Every cmacs seat-keyboard-focus path consults the layer grab first.

This is the regression guard for the deaf-launcher bug: a path that
calls `wlr_seat_keyboard_notify_enter' without first checking
`cmacs_gowl_layer_owns_keyboard' can take the keyboard away from a
mapped launcher, leaving it visible, on top, and unable to receive a
single keystroke."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (let ((bodies (cmacs-gowl-tests--defun-bodies
                   source "wlr_seat_keyboard_notify_enter")))
      ;; Sanity: the call sites still exist and were actually found.
      ;; A zero here would make the assertion below vacuously true.
      (should (>= (length bodies) 4))
      (dolist (body bodies)
        (should (string-match-p "cmacs_gowl_layer_owns_keyboard" body))))))

(ert-deftest cmacs-gowl-test-layer-grab-helper-uses-compositor-api ()
  "`cmacs_gowl_layer_owns_keyboard' delegates to the compositor.

The grab must be derived from live compositor state rather than
cached in cmacs: a surface that unmaps or stops asking for the
keyboard releases it immediately, so a stale cmacs-side copy could
wedge keyboard focus with no way out."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (should (string-match-p
               "gowl_compositor_has_exclusive_keyboard_layer"
               (buffer-string))))))

(ert-deftest cmacs-gowl-test-grant-focus-requires-running ()
  "`gowl-grant-focus-to-emacs' errors when the compositor is not running."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (not (gowl-running-p)))
  (should-error (gowl-grant-focus-to-emacs)))

(ert-deftest cmacs-gowl-test-return-focus-without-redirect ()
  "`gowl-return-focus-to-embed' is a no-op with no active redirect."
  (skip-unless (cmacs-feature-p 'gowl))
  (should-not (gowl-return-focus-to-embed)))

(ert-deftest cmacs-gowl-test-focus-redirect-predicates ()
  "The focus-redirect predicates return booleans and default to nil."
  (skip-unless (cmacs-feature-p 'gowl))
  (should (memq (gowl-focus-redirect-active-p) '(t nil)))
  (should (memq (gowl-focus-redirect-sticky-p) '(t nil)))
  ;; With no redirect pushed, neither is active.
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-focus-redirect-active-p))
  (should-not (gowl-focus-redirect-sticky-p)))

(ert-deftest cmacs-gowl-test-focus-post-command-is-safe ()
  "The `post-command-hook' focus restore never errors.

It runs after literally every command in the session; a signal here
would make the editor unusable, so it must tolerate no compositor, no
redirect, and a redirect blocked by a layer grab alike."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl-focus)
  (should-not (cmacs-gowl-focus--post-command)))

(ert-deftest cmacs-gowl-test-prefix-keys-exclude-plain-escape ()
  "Plain ESC is not a prefix key; it is the hardcoded sticky redirect.
Listing it here would push a non-sticky redirect that
`post-command-hook' pops one command later, defeating the escape
hatch out of an embed."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl-focus)
  (should-not (member "Escape" cmacs-gowl-prefix-keys))
  (should (member "Control+Escape" cmacs-gowl-prefix-keys)))

;;; emacsclient --gowl / cmacs-gowl-attach

(ert-deftest cmacs-gowl-test-attach-is-an-interactive-command ()
  "`cmacs-gowl-attach' is defined and callable as a command.
`emacsclient --gowl' reaches it through server.el's `-gowl' branch, and
`M-x' through the autoload in `cmacs.el'."
  (require 'cmacs-gowl)
  (should (fboundp 'cmacs-gowl-attach))
  (should (commandp 'cmacs-gowl-attach)))

(ert-deftest cmacs-gowl-test-attach-refuses-without-a-display ()
  "`cmacs-gowl-attach' errors instead of letting wlroots fail deep inside.
A headless daemon has no parent session to nest in and no graphical
frame whose display gowl could borrow, so there is nothing to host an
output; the error is what `emacsclient --gowl' reports to the user."
  ;; `fboundp' rather than `cmacs-feature-p': that helper lives in
  ;; cmacs-glib-tests and is not loaded when this file runs alone.
  (skip-unless (fboundp 'gowl-start))
  (require 'cmacs-gowl)
  (require 'cl-lib)
  (skip-unless (not (gowl-running-p)))
  (skip-unless (not (cl-some #'display-graphic-p (frame-list))))
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "WAYLAND_DISPLAY" nil)
    (should-error (cmacs-gowl-attach))))

(ert-deftest cmacs-gowl-test-server-honours-the-gowl-request ()
  "`lisp/server.el' still carries the `-gowl' client command.
Without both hunks -- the request arm and the frame-dispatch branch --
`emacsclient --gowl' either dies with \"Unknown command: -gowl\" or
silently opens a frame on the launcher's terminal instead of bringing
up the compositor.  Both are re-applied by hand after an upstream
merge, so guard them."
  (let ((source (cmacs-gowl-tests--source-file "lisp/server.el")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (let ((text (buffer-string)))
        (should (string-match-p "(\"-gowl\"" text))
        (should (string-match-p "cmacs-gowl-attach" text))))))

(ert-deftest cmacs-gowl-test-emacsclient-has-the-gowl-option ()
  "`lib-src/emacsclient.c' still carries the `--gowl' option.
Guards the other half of the same upstream touch-point: the long
option, the request it sends, and the `emacs --gowl' fallback used when
no server answers."
  (let ((source (cmacs-gowl-tests--source-file "lib-src/emacsclient.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (let ((text (buffer-string)))
        (should (string-match-p "\"gowl\"[[:space:]]*," text))
        (should (string-match-p "\"-gowl \"" text))
        (should (string-match-p "emacs --gowl" text))))))

(ert-deftest cmacs-gowl-test-desktop-launchers-exist ()
  "The gowl application launchers ship and point at the right commands."
  (let ((session (cmacs-gowl-tests--source-file "etc/emacs-gowl.desktop"))
        (client (cmacs-gowl-tests--source-file "etc/emacsclient-gowl.desktop")))
    (skip-unless (and session client))
    (with-temp-buffer
      (insert-file-contents session)
      (should (string-match-p "^Exec=emacs --gowl" (buffer-string)))
      ;; A compositor session must not become the handler for text files.
      (should-not (string-match-p "^MimeType=" (buffer-string))))
    (with-temp-buffer
      (insert-file-contents client)
      (should (string-match-p "^Exec=emacsclient --gowl" (buffer-string)))
      (should-not (string-match-p "^MimeType=" (buffer-string))))))

;;; Keybind cheatsheet

(ert-deftest cmacs-gowl-test-keybind-label-prefers-desc ()
  "A bind's description wins over its action and argument."
  (should (equal (cmacs-gowl--keybind-label
                  '((key . "Super+Return") (action . spawn)
                    (arg . "gst") (desc . "Terminal")))
                 "Terminal")))

(ert-deftest cmacs-gowl-test-keybind-label-falls-back-to-action-arg ()
  "With no description, the label is the action and its argument.
Binds arriving from a YAML config or a module carry no desc, and a
cheatsheet listing them as a bare action nick would be less useful
than what they actually do."
  (should (equal (cmacs-gowl--keybind-label
                  '((key . "Super+p") (action . spawn)
                    (arg . "wofi --show drun") (desc . nil)))
                 "spawn: wofi --show drun"))
  (should (equal (cmacs-gowl--keybind-label
                  '((key . "Super+Shift+c") (action . kill-client)
                    (arg . nil) (desc . nil)))
                 "kill-client")))

(ert-deftest cmacs-gowl-test-keybind-label-empty-desc ()
  "An empty description is treated as absent, not printed as blank."
  (should (equal (cmacs-gowl--keybind-label
                  '((key . "Super+m") (action . set-layout)
                    (arg . "monocle") (desc . "")))
                 "set-layout: monocle")))

(ert-deftest cmacs-gowl-test-keybind-sort-groups-by-modifiers ()
  "Binds sort by modifier count first, so media keys group together.
A plain XF86 key has no modifier and must not be interleaved with the
Super binds."
  (should (= (car (cmacs-gowl--keybind-sort-key
                   '((key . "XF86AudioMute"))))
             0))
  (should (= (car (cmacs-gowl--keybind-sort-key
                   '((key . "Super+p"))))
             1))
  (should (= (car (cmacs-gowl--keybind-sort-key
                   '((key . "Super+Shift+Ctrl+1"))))
             3)))

(ert-deftest cmacs-gowl-test-keybind-sort-key-handles-missing-key ()
  "A malformed entry sorts rather than erroring.
`gowl-list-keybinds' always supplies a key, but the cheatsheet should
not be the thing that breaks if one day it does not."
  (should (cmacs-gowl--keybind-sort-key '((action . quit)))))

(ert-deftest cmacs-gowl-test-describe-keybinds-renders ()
  "The cheatsheet lists every live bind, one line each."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (skip-unless (gowl-list-keybinds))
  (let ((count (length (gowl-list-keybinds))))
    (cmacs-gowl-describe-keybinds)
    (with-current-buffer cmacs-gowl-describe-keybinds-buffer
      (should (string-match-p (format "^%d compositor keybinds" count)
                              (buffer-string)))
      ;; Header, blank line, then one line per bind.
      (should (= (count-lines (point-min) (point-max)) (+ 2 count))))))

;;; Action symbols

(ert-deftest cmacs-gowl-test-list-keybinds-action-is-a-symbol ()
  "`gowl-list-keybinds' reports actions by name, not by enum number.
The integer it used to return meant a caller had to know the C enum's
order to make any sense of the answer."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (let ((binds (gowl-list-keybinds)))
    (skip-unless binds)
    (dolist (entry binds)
      (let ((action (cdr (assq 'action entry))))
        (should (or (symbolp action) (integerp action)))))
    ;; At least one must be a symbol, or the mapping is not working.
    (should (cl-some (lambda (e) (symbolp (cdr (assq 'action e)))) binds))))

(ert-deftest cmacs-gowl-test-add-keybind-accepts-desc ()
  "A fourth argument to `gowl-add-keybind' round-trips as `desc'."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (unwind-protect
      (progn
        (gowl-remove-keybind "Super+Ctrl+Shift+F12")
        (should (gowl-add-keybind "Super+Ctrl+Shift+F12" 'none nil
                                  "cmacs test bind"))
        (let ((entry (cl-find-if
                      (lambda (e)
                        (equal (cdr (assq 'desc e)) "cmacs test bind"))
                      (gowl-list-keybinds))))
          (should entry)
          (should (eq (cdr (assq 'action entry)) 'none))))
    (gowl-remove-keybind "Super+Ctrl+Shift+F12")))

(ert-deftest cmacs-gowl-test-add-keybind-unknown-action-errors ()
  "An action name gowl does not know is an error, not a silent no-op."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (should-error (gowl-add-keybind "Super+Ctrl+Shift+F11"
                                  'no-such-gowl-action)))

;;; Dashboard config path

(ert-deftest cmacs-gowl-test-dashboard-config-path-includes-gowl ()
  "The dashboard saves under gowl/, whether or not XDG_CONFIG_HOME is set.
An earlier version passed XDG_CONFIG_HOME straight in as the
directory, so with it set -- the usual case -- the file landed at
~/.config/config.yaml, which gowl never reads."
  (require 'cmacs-gowl-dashboard)
  (let ((process-environment
         (cons "XDG_CONFIG_HOME=/tmp/cmacs-test-xdg" process-environment)))
    (should (equal (cmacs-gowl-dashboard-config-file)
                   "/tmp/cmacs-test-xdg/gowl/config.yaml")))
  (let ((process-environment
         (cl-remove-if (lambda (v) (string-prefix-p "XDG_CONFIG_HOME=" v))
                       process-environment)))
    (should (string-suffix-p "/.config/gowl/config.yaml"
                             (cmacs-gowl-dashboard-config-file)))))

;;; Nested-vs-seat detection (source guards)

;; These read the C sources rather than calling anything: the decision
;; runs in early main(), before the Lisp VM exists, and the failure it
;; guards against does not show up in the session that causes it.  A
;; cmacs session that exits leaves its Wayland socket file behind (Emacs
;; exits through exit(), so libwayland never removes it); treating that
;; file as proof of a running compositor made the NEXT login nest itself
;; into a dead socket and die at the display manager.  The liveness
;; probe itself is tested for real in gowl (tests/test-wayland-socket.c);
;; what can regress here is somebody reintroducing the file check.

(defvar cmacs-gowl-tests--source-root
  (and (or load-file-name buffer-file-name)
       (expand-file-name
        "../../" (file-name-directory (or load-file-name buffer-file-name))))
  "Top of the cmacs source tree, or nil when tests run outside it.")

(defun cmacs-gowl-tests--source (relative)
  "Contents of RELATIVE under the source tree, or nil if unavailable."
  (let ((file (and cmacs-gowl-tests--source-root
                   (expand-file-name relative
                                     cmacs-gowl-tests--source-root))))
    (when (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(ert-deftest cmacs-gowl-test-nested-detection-probes-liveness ()
  "Nested detection must delegate to gowl, not decide for itself.
The policy lives in `gowl_wayland_detect_parent_session\=' because the
direction it errs in is what matters: a probe that reaches no verdict
has to resolve to \"there is a parent\".  Backwards, inside a GNOME
session, gowl believes it owns the seat and stops
graphical-session.target on the way out --- which is GNOME\='s.  That
asymmetry is unit-tested over there; re-deciding it here would put it
somewhere nothing tests."
  (let ((src (cmacs-gowl-tests--source "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless src)
    (should (string-match-p "cmacs_gowl_detect_nested" src))
    (should (string-match-p "gowl_wayland_detect_parent_session" src))
    ;; No second opinion about the environment: one unset in a place
    ;; with no test around it is the whole hazard.
    (should-not (string-match-p "unsetenv (\"WAYLAND_DISPLAY\")" src))))

(ert-deftest cmacs-gowl-test-emacs-c-has-no-socket-file-probe ()
  "The --gowl entry in emacs.c must not decide nestedness from a file.
This is the exact hunk that wedged logins: it scanned
$XDG_RUNTIME_DIR for wayland-0..3 and believed whichever file it
found.  It now calls `cmacs_gowl_detect_nested', which probes."
  (let ((src (cmacs-gowl-tests--source "src/emacs.c")))
    (skip-unless src)
    (should (string-match-p "cmacs_gowl_detect_nested" src))
    (should-not (string-match-p "wayland-%d" src))))

;;; Scratchpad
;;
;; gowl's scratchpad module: a panel of windows that slides up from the
;; bottom of the focused output.  The module itself is tested in gowl
;; (tests/test-scratchpad-module.c, test-overlay-adopt.c); what can go
;; wrong here is the keys, the commands' handling of the module's
;; replies, and whether cmacs loads and configures the module at all.

(require 'cl-lib)

(defmacro cmacs-gowl-tests--with-scratchpad (replies &rest body)
  "Run BODY with gowl stubbed to answer scratchpad commands from REPLIES.
REPLIES is an alist of (LINE . REPLY); a line not in it gets nil, as
from a session without the module.  BODY sees the lines it sent in
`sent', newest first."
  (declare (indent 1))
  `(let ((sent nil))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-run-command)
                (lambda (line &rest _)
                  (push line sent)
                  (cdr (assoc line ,replies)))))
       ,@body)))

(ert-deftest cmacs-gowl-test-scratchpad-keybinds ()
  "Super+s toggles the scratchpad, Super+Alt+s and Super+Ctrl+s (or
Super+Ctrl+Shift+s) send a window and bring it back.  Super+Ctrl+s must
be bound: unbound, a terminal takes it as Ctrl+S (XOFF) and freezes.
The screenshot keeps Super+Shift+s,
Super+s no longer selects the scrolling layout, and that layout stays
reachable by cycling."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (let ((captured nil)
        (cmacs-gowl--keybinds-installed nil))
    (cl-letf (((symbol-function 'gowl-add-keybind)
               (lambda (key action &optional arg &rest _)
                 (push (list key action arg) captured)))
              ((symbol-function 'gowl-remove-keybind) #'ignore))
      (cmacs-gowl--install-default-keybinds))
    (should (member '("Super+s" ipc-command "scratchpad-toggle") captured))
    (should (member '("Super+Alt+s" ipc-command "scratchpad-add") captured))
    (should (member '("Super+Ctrl+s" ipc-command "scratchpad-remove")
                    captured))
    (should (member '("Super+Ctrl+Shift+s" ipc-command "scratchpad-remove")
                    captured))
    (should (member '("Super+Shift+s" ipc-command "screenshot-area")
                    captured))
    ;; gowl dispatches the first bind that matches, so a second Super+s
    ;; would decide by table order which one the key does.
    (should (= 1 (cl-count "Super+s" captured :key #'car :test #'equal)))
    (should-not (member '("Super+s" set-layout "scrolling") captured))
    (should (cl-find 'cycle-layout captured :key #'cadr))))

(ert-deftest cmacs-gowl-test-scratchpad-report ()
  "The module's replies become sentences; anything else passes through."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (equal (cmacs-gowl--scratchpad-report "OK shown 1")
                 "Scratchpad up, 1 window"))
  (should (equal (cmacs-gowl--scratchpad-report "OK shown 3")
                 "Scratchpad up, 3 windows"))
  (should (equal (cmacs-gowl--scratchpad-report "OK hidden")
                 "Scratchpad rolled away"))
  (should (equal (cmacs-gowl--scratchpad-report "OK added 2")
                 "Sent to the scratchpad (2 windows in it)"))
  (should (equal (cmacs-gowl--scratchpad-report "OK removed 0")
                 "Back from the scratchpad (0 left in it)"))
  (should (equal (cmacs-gowl--scratchpad-report "OK something new")
                 "OK something new")))

(ert-deftest cmacs-gowl-test-scratchpad-toggle-sends-its-word ()
  "The toggle command sends `scratchpad-toggle' and says what happened."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (cmacs-gowl-tests--with-scratchpad '(("scratchpad-toggle" . "OK shown 2"))
    (should (equal (cmacs-gowl-scratchpad-toggle) "Scratchpad up, 2 windows"))
    (should (equal sent '("scratchpad-toggle")))))

(ert-deftest cmacs-gowl-test-scratchpad-errors-are-user-errors ()
  "An ERROR reply is a `user-error' carrying the module's reason, no
reply means the module is not loaded, and no compositor is refused."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (cmacs-gowl-tests--with-scratchpad
      '(("scratchpad-toggle"
         . "ERROR the scratchpad is empty; add a window with scratchpad-add"))
    (let ((err (should-error (cmacs-gowl-scratchpad-toggle)
                             :type 'user-error)))
      (should (string-match-p "the scratchpad is empty" (cadr err)))))
  (cmacs-gowl-tests--with-scratchpad nil
    (let ((err (should-error (cmacs-gowl-scratchpad-toggle)
                             :type 'user-error)))
      (should (string-match-p "not loaded" (cadr err)))))
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
    (should-error (cmacs-gowl-scratchpad-toggle) :type 'user-error)))

(ert-deftest cmacs-gowl-test-scratchpad-add-remove-by-id ()
  "With an id the commands name the window; with nil they act on the
focused one, as the keys do."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (cmacs-gowl-tests--with-scratchpad '(("scratchpad-add 12" . "OK added 1")
                                       ("scratchpad-add" . "OK added 2")
                                       ("scratchpad-remove 12" . "OK removed 1")
                                       ("scratchpad-remove" . "OK removed 0"))
    (should (equal (cmacs-gowl-scratchpad-add 12)
                   "Sent to the scratchpad (1 window in it)"))
    (cmacs-gowl-scratchpad-add nil)
    (cmacs-gowl-scratchpad-remove 12)
    (cmacs-gowl-scratchpad-remove nil)
    (should (equal (reverse sent)
                   '("scratchpad-add 12" "scratchpad-add"
                     "scratchpad-remove 12" "scratchpad-remove")))))

(ert-deftest cmacs-gowl-test-scratchpad-pickers ()
  "Adding offers the windows not in the scratchpad, never an embedded
one; removing offers only its members, read from `scratchpad-status'."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (let ((infos '(((id . 4) (title . "Music") (app-id . "player") (tags . 0))
                 ((id . 7) (title . "Editor") (app-id . "cmacs") (tags . 1))
                 ((id . 9) (title . "Chat") (app-id . "chat") (tags . 0))
                 ((id . 11) (title . "Frame") (app-id . "web") (tags . 1)
                  (embedded . t))))
        (offered nil))
    (cmacs-gowl-tests--with-scratchpad
        '(("scratchpad-status"
           . "OK visible=0 count=2 members=4,9 width-pct=1 height-pct=0.666667 width=0 height=0 gap=0")
          ("scratchpad-add 7" . "OK added 3")
          ("scratchpad-remove 9" . "OK removed 1"))
      (cl-letf (((symbol-function 'gowl-list-clients) (lambda (&rest _) infos))
                ((symbol-function 'gowl-client-info) (lambda (info &rest _) info))
                ((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (mapcar #'cdr collection))
                   (car (car (last collection))))))
        (call-interactively #'cmacs-gowl-scratchpad-add)
        (should (equal offered '(7)))
        (call-interactively #'cmacs-gowl-scratchpad-remove)
        (should (equal offered '(4 9)))
        (should (member "scratchpad-add 7" sent))
        (should (member "scratchpad-remove 9" sent))))))

(ert-deftest cmacs-gowl-test-scratchpad-settings-pushed ()
  "The options reach the module as the string alist it parses, and
nothing is pushed without a compositor.  The defaults are the
dropdown's size."
  (skip-unless (cmacs-feature-p 'gowl))
  (require 'cmacs-gowl)
  (should (equal (default-toplevel-value 'cmacs-gowl-scratchpad-width-pct) 1.0))
  (should (equal (default-toplevel-value 'cmacs-gowl-scratchpad-height-pct)
                 0.666667))
  (let ((cmacs-gowl-scratchpad-width-pct 0.5)
        (cmacs-gowl-scratchpad-height-pct 0.4)
        (cmacs-gowl-scratchpad-width 0)
        (cmacs-gowl-scratchpad-height 300)
        (cmacs-gowl-scratchpad-gap 8)
        (pushed nil))
    (should (equal (cmacs-gowl--scratchpad-settings)
                   '(("width-pct" . "0.5") ("height-pct" . "0.4")
                     ("width" . "0") ("height" . "300") ("gap" . "8"))))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
              ((symbol-function 'gowl-configure-module)
               (lambda (name alist &rest _) (push (cons name alist) pushed))))
      (cmacs-gowl--apply-scratchpad))
    (should (equal (caar pushed) "scratchpad"))
    (should (equal (cdar pushed) (cmacs-gowl--scratchpad-settings)))
    (setq pushed nil)
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil))
              ((symbol-function 'gowl-configure-module)
               (lambda (&rest args) (push args pushed))))
      (cmacs-gowl--apply-scratchpad))
    (should-not pushed)))

(ert-deftest cmacs-gowl-test-scratchpad-loaded-by-default ()
  "cmacs --gowl loads gowl's scratchpad module with its other defaults.
The three scratchpad keys reach it by name, so without it they would do
nothing at all."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (goto-char (point-min))
      (should (re-search-forward
               "const gchar \\*names\\[\\] = {[^}]*\"scratchpad\"" nil t)))))

(ert-deftest cmacs-gowl-test-scratchpad-toggle-takes-the-lock ()
  "`gowl-scratchpad-toggle' presents windows and moves focus from the
Emacs thread, so it must hold the compositor lock while it does."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (let ((bodies (cmacs-gowl-tests--defun-bodies
                   source "gowl_scratchpad_handler_toggle_scratchpad")))
      (should (= (length bodies) 1))
      (should (string-match-p "cmacs_gowl_lock ()" (car bodies))))))

(ert-deftest cmacs-gowl-test-config-defuns-take-the-lock ()
  "Every Emacs-thread path to the compositor's config holds the gowl lock.

The dispatch thread holds `cmacs_gowl_mutex' for the length of each
`wl_event_loop_dispatch', and the config object is not merely mutated
but replaced outright -- by `gowl-reload-config' with no file, and by
gowl's own reload keybind.  A DEFUN that reads it without the lock can
be reading a config that is being released underneath it.  Running a
keybind counts too: that is a whole compositor action, the same one
the dispatch thread runs for a real key press."
  (dolist (relative '("cmacs/gowl/cmacs-gowl.c"
                      "cmacs/glib/cmacs-eval-dispatch.c"))
    (let ((source (cmacs-gowl-tests--source-file relative)))
      (skip-unless source)
      (dolist (symbol '("gowl_compositor_get_config"
                        "gowl_compositor_dispatch_keybind"))
        (let ((bodies (cmacs-gowl-tests--defun-bodies source symbol)))
          (dolist (body bodies)
            (ert-info ((format "%s: a body reaching %s" relative symbol))
              (should (string-match-p
                       (rx (or "cmacs_gowl_lock_scoped ()"
                               "cmacs_gowl_lock ()"
                               "pthread_mutex_lock (&cmacs_gowl_mutex)"))
                       body)))))))))

(ert-deftest cmacs-gowl-test-scoped-lock-releases-through-specpdl ()
  "The scoped gowl lock releases via the specpdl, not a written unlock.
These DEFUNs signal after taking the lock -- no config loaded, a key
that will not parse, an unknown property -- and `error' longjmps past
any unlock placed after the body.  The mutex would stay held and the
dispatch thread would wedge on its next pass: a frozen desktop, which
is worse than the race the lock is there to close."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (goto-char (point-min))
      (should (re-search-forward
               "record_unwind_protect_void (cmacs_gowl_unlock)" nil t)))))

(ert-deftest cmacs-gowl-test-scoped-lock-returns-unwind ()
  "No body leaves the gowl lock held by returning around `unbind_to'.
Once `cmacs_gowl_lock_scoped' has run, every exit must go through
`unbind_to'; signalling unwinds on its own.  A plain `return' keeps
the mutex and wedges the dispatch thread.  This guard exists because
exactly one such return was written, and missed, in the change that
added the lock."
  (let ((source (cmacs-gowl-tests--source-file "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless source)
    (with-temp-buffer
      (insert-file-contents source)
      (cmacs-gowl-tests--strip-c-comments)
      (goto-char (point-min))
      (let ((offenders nil)
            (scoped 0))
        (while (re-search-forward "cmacs_gowl_lock_scoped ()" nil t)
          (setq scoped (1+ scoped))
          ;; From the lock to the end of its enclosing function.
          (let ((end (save-excursion
                       (if (re-search-forward "^}" nil t)
                           (point)
                         (point-max)))))
            (save-excursion
              (while (re-search-forward "^.*\\_<return\\_>.*$" end t)
                (let ((line (match-string 0)))
                  (unless (string-match-p "unbind_to" line)
                    (push (string-trim line) offenders)))))))
        (should (> scoped 0))
        (should (equal offenders nil))))))

(provide 'cmacs-gowl-tests)
;;; cmacs-gowl-tests.el ends here
