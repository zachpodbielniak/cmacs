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

(provide 'cmacs-gowl-tests)
;;; cmacs-gowl-tests.el ends here
