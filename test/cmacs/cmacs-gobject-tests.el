;;; cmacs-gobject-tests.el --- Tests for GObject bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs GObject <-> elisp type bridge.
;; Tests cover wrap/unwrap, type predicates, property access,
;; signal listing, object creation, and signal connect/disconnect.

;;; Code:

(require 'ert)
(require 'cmacs)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Predicate tests

(ert-deftest cmacs-gobject-test-p-nil ()
  "Test that nil is not a GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-not (gobject-p nil)))

(ert-deftest cmacs-gobject-test-p-number ()
  "Test that a number is not a GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-not (gobject-p 42)))

(ert-deftest cmacs-gobject-test-p-string ()
  "Test that a string is not a GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-not (gobject-p "hello")))

(ert-deftest cmacs-gobject-test-p-cons ()
  "Test that a cons cell is not a GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-not (gobject-p '(a . b))))

;;; Object creation tests

(ert-deftest cmacs-gobject-test-new-invalid-type ()
  "Test that `gobject-new' signals an error for unknown type."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-new "NonExistentGType12345")
                :type 'error))

(ert-deftest cmacs-gobject-test-new-non-string-type ()
  "Test that `gobject-new' signals an error for non-string type arg."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-new 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gobject-test-new-gobject ()
  "Test creating a plain GObject and verifying it is recognized."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should (gobject-p obj))))

;;; Type name tests

(ert-deftest cmacs-gobject-test-type-name-gobject ()
  "Test that a plain GObject reports type name \"GObject\"."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should (equal (gobject-type-name obj) "GObject"))))

(ert-deftest cmacs-gobject-test-type-name-nil ()
  "Test that `gobject-type-name' signals an error for nil."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-type-name nil)
                :type 'error))

(ert-deftest cmacs-gobject-test-type-name-non-gobject ()
  "Test that `gobject-type-name' signals an error for non-GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-type-name 42)
                :type 'error))

;;; Property tests

(ert-deftest cmacs-gobject-test-list-properties-gobject ()
  "Test that `gobject-list-properties' returns a list for GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((props (gobject-list-properties (gobject-new "GObject"))))
    (should (listp props))))

(ert-deftest cmacs-gobject-test-list-properties-nil ()
  "Test that `gobject-list-properties' errors on nil."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-list-properties nil)
                :type 'error))

(ert-deftest cmacs-gobject-test-get-invalid-property ()
  "Test that `gobject-get' errors on nonexistent property."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-get obj "nonexistent-property-xyz")
                  :type 'error)))

(ert-deftest cmacs-gobject-test-set-invalid-property ()
  "Test that `gobject-set' errors on nonexistent property."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-set obj "nonexistent-property-xyz" 42)
                  :type 'error)))

(ert-deftest cmacs-gobject-test-get-requires-string-property ()
  "Test that `gobject-get' requires a string property name."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-get obj 42)
                  :type 'wrong-type-argument)))

;;; Signal tests

(ert-deftest cmacs-gobject-test-list-signals-gobject ()
  "Test that `gobject-list-signals' returns a list for GObject."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((signals (gobject-list-signals (gobject-new "GObject"))))
    (should (listp signals))
    ;; GObject has a \"notify\" signal.
    (should (member "notify" signals))))

(ert-deftest cmacs-gobject-test-list-signals-nil ()
  "Test that `gobject-list-signals' errors on nil."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-list-signals nil)
                :type 'error))

(ert-deftest cmacs-gobject-test-connect-requires-string-signal ()
  "Test that `gobject-connect' requires a string signal name."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-connect obj 42 #'ignore)
                  :type 'wrong-type-argument)))

(ert-deftest cmacs-gobject-test-connect-requires-function ()
  "Test that `gobject-connect' requires a function callback."
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-connect obj "notify" "not-a-function")
                  :type 'wrong-type-argument)))

(ert-deftest cmacs-gobject-test-connect-returns-handler-id ()
  "Test that `gobject-connect' returns a positive integer handler ID."
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((obj (gobject-new "GObject"))
         (handler-id (gobject-connect obj "notify" #'ignore)))
    (should (integerp handler-id))
    (should (> handler-id 0))
    (gobject-disconnect obj handler-id)))

(ert-deftest cmacs-gobject-test-disconnect ()
  "Test that `gobject-disconnect' does not error for valid handler."
  (skip-unless (cmacs-feature-p 'gobject))
  (let* ((obj (gobject-new "GObject"))
         (handler-id (gobject-connect obj "notify" #'ignore)))
    (should (null (gobject-disconnect obj handler-id)))))

(ert-deftest cmacs-gobject-test-disconnect-nil-object ()
  "Test that `gobject-disconnect' errors on nil object."
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gobject-disconnect nil 1)
                :type 'error))

;; Edge cases: boundary values and error recovery
(ert-deftest cmacs-gobject-p-various-types ()
  "gobject-p should reject all non-GObject types gracefully."
  (skip-unless (fboundp 'gobject-p))
  (should-not (gobject-p 0))
  (should-not (gobject-p -1))
  (should-not (gobject-p 1.5))
  (should-not (gobject-p ""))
  (should-not (gobject-p 'symbol))
  (should-not (gobject-p [vector]))
  (should-not (gobject-p (make-hash-table))))

(ert-deftest cmacs-gobject-new-empty-string ()
  "Creating a GObject with empty type string should error."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-new "")))

(ert-deftest cmacs-gobject-wrap-unwrap-identity ()
  "Wrapping and immediately using a GObject should preserve type."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-type-name)))
  (let ((obj (gobject-new "GObject")))
    (should (gobject-p obj))
    (should (equal (gobject-type-name obj) "GObject"))))

(ert-deftest cmacs-gobject-connect-invalid-signal ()
  "Connecting to a nonexistent signal returns 0 (no valid handler)."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-connect)))
  ;; g_signal_connect_closure returns 0 for invalid signals rather
  ;; than raising an error — it emits a GLib warning instead.
  (let* ((obj (gobject-new "GObject"))
         (handler-id (gobject-connect obj "nonexistent-signal-xyz" #'ignore)))
    (should (integerp handler-id))
    (should (= handler-id 0))))

(ert-deftest cmacs-gobject-disconnect-invalid-id ()
  "Disconnecting an invalid handler ID should not crash."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-disconnect)))
  (let ((obj (gobject-new "GObject")))
    ;; Should not signal an error — just a no-op
    (gobject-disconnect obj 999999)))

(ert-deftest cmacs-gobject-set-invalid-property-name ()
  "Setting a nonexistent property should error, not crash."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-set)))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-set obj "totally-fake-property" 42))))

(ert-deftest cmacs-gobject-get-invalid-property-name ()
  "Getting a nonexistent property should error, not crash."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-get)))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-get obj "totally-fake-property"))))

(provide 'cmacs-gobject-tests)
;;; cmacs-gobject-tests.el ends here
