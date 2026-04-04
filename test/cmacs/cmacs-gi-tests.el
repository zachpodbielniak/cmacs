;;; cmacs-gi-tests.el --- Tests for GObject Introspection bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs GObject Introspection bridge.
;; Tests cover namespace loading (gi-require), function calling
;; (gi-call), method invocation (gi-method), enum resolution
;; (gi-enum), function listing, and function info retrieval.

;;; Code:

(require 'ert)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Namespace loading tests

(ert-deftest cmacs-gi-test-require-glib ()
  "Test that loading the GLib typelib succeeds."
  (skip-unless (cmacs-feature-p 'gi))
  (should (gi-require "GLib" "2.0")))

(ert-deftest cmacs-gi-test-require-gio ()
  "Test that loading the Gio typelib succeeds."
  (skip-unless (cmacs-feature-p 'gi))
  (should (gi-require "Gio" "2.0")))

(ert-deftest cmacs-gi-test-require-nonexistent ()
  "Test that loading a nonexistent namespace signals gi-error."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-require "NonExistentNamespace12345" "1.0")
                :type 'gi-error))

(ert-deftest cmacs-gi-test-require-non-string ()
  "Test that `gi-require' rejects non-string namespace."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-require 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gi-test-require-nil-version ()
  "Test that `gi-require' accepts nil version (latest available)."
  (skip-unless (cmacs-feature-p 'gi))
  (should (gi-require "GLib" nil)))

;;; Function calling tests

(ert-deftest cmacs-gi-test-call-glib-function ()
  "Test calling a simple GLib function via GI."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  ;; g_get_user_name returns the current username as a string.
  (let ((name (gi-call "GLib" "get_user_name")))
    (should (stringp name))
    (should (> (length name) 0))))

(ert-deftest cmacs-gi-test-call-nonexistent-function ()
  "Test that calling a nonexistent function signals an error."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (should-error (gi-call "GLib" "nonexistent_function_xyz")
                :type 'error))

(ert-deftest cmacs-gi-test-call-requires-namespace ()
  "Test that `gi-call' requires at least namespace and function."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-call "GLib")
                :type 'wrong-number-of-arguments))

(ert-deftest cmacs-gi-test-call-non-string-namespace ()
  "Test that `gi-call' rejects non-string namespace."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-call 42 "some_function")
                :type 'wrong-type-argument))

(ert-deftest cmacs-gi-test-call-non-string-function ()
  "Test that `gi-call' rejects non-string function name."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-call "GLib" 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gi-test-call-hostname ()
  "Test calling g_get_host_name via GI."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (let ((hostname (gi-call "GLib" "get_host_name")))
    (should (stringp hostname))))

;;; Enum resolution tests

(ert-deftest cmacs-gi-test-enum-resolve ()
  "Test resolving a GLib enum value."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  ;; GLib.ChecksumType.md5 should resolve to an integer.
  (let ((val (gi-enum "GLib" "ChecksumType" "md5")))
    (should (integerp val))
    (should (= val 0))))

(ert-deftest cmacs-gi-test-enum-sha256 ()
  "Test resolving GLib.ChecksumType.sha256."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (let ((val (gi-enum "GLib" "ChecksumType" "sha256")))
    (should (integerp val))
    (should (= val 1))))

(ert-deftest cmacs-gi-test-enum-nonexistent-member ()
  "Test that resolving a nonexistent enum member signals an error."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (should-error (gi-enum "GLib" "ChecksumType" "nonexistent_member")
                :type 'error))

(ert-deftest cmacs-gi-test-enum-nonexistent-enum ()
  "Test that resolving a nonexistent enum signals an error."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (should-error (gi-enum "GLib" "FakeEnumXYZ" "value")
                :type 'error))

(ert-deftest cmacs-gi-test-enum-requires-strings ()
  "Test that `gi-enum' requires string arguments."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-enum 1 2 3)
                :type 'wrong-type-argument))

;;; Function listing tests

(ert-deftest cmacs-gi-test-list-functions-glib ()
  "Test that `gi-list-functions' returns a non-empty list for GLib."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (let ((funcs (gi-list-functions "GLib")))
    (should (listp funcs))
    (should (> (length funcs) 0))
    ;; All entries should be strings.
    (should (cl-every #'stringp funcs))))

(ert-deftest cmacs-gi-test-list-functions-requires-string ()
  "Test that `gi-list-functions' rejects non-string."
  (skip-unless (cmacs-feature-p 'gi))
  (should-error (gi-list-functions 42)
                :type 'wrong-type-argument))

;;; Function info tests

(ert-deftest cmacs-gi-test-function-info-returns-alist ()
  "Test that `gi-function-info' returns an alist with expected keys."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (let ((info (gi-function-info "GLib" "get_user_name")))
    (should (listp info))
    (should (assq 'name info))
    (should (assq 'args info))
    (should (assq 'return-type info))))

(ert-deftest cmacs-gi-test-function-info-nonexistent ()
  "Test that `gi-function-info' returns nil for unknown function."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (should-not (gi-function-info "GLib" "nonexistent_xyz_987")))

(ert-deftest cmacs-gi-test-function-info-name-matches ()
  "Test that the name field of function info matches the queried name."
  (skip-unless (cmacs-feature-p 'gi))
  (gi-require "GLib" "2.0")
  (let* ((info (gi-function-info "GLib" "get_host_name"))
         (name (cdr (assq 'name info))))
    (should (equal name "get_host_name"))))

;;; GI method tests

(ert-deftest cmacs-gi-test-method-requires-gobject ()
  "Test that `gi-method' errors when given a non-GObject."
  (skip-unless (cmacs-feature-p 'gi))
  (skip-unless (cmacs-feature-p 'gobject))
  (should-error (gi-method 42 "some_method")
                :type 'error))

(ert-deftest cmacs-gi-test-method-requires-string-method ()
  "Test that `gi-method' requires string method name."
  (skip-unless (cmacs-feature-p 'gi))
  (skip-unless (cmacs-feature-p 'gobject))
  (let ((obj (gobject-new "GObject")))
    (should-error (gi-method obj 42)
                  :type 'wrong-type-argument)))

(provide 'cmacs-gi-tests)
;;; cmacs-gi-tests.el ends here
