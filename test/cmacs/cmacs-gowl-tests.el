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
      (should (assoc "title" info))
      (should (assoc "app-id" info))
      (should (assoc "tags" info))
      (should (assoc "floating" info))
      (should (assoc "geometry" info)))))

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

(provide 'cmacs-gowl-tests)
;;; cmacs-gowl-tests.el ends here
