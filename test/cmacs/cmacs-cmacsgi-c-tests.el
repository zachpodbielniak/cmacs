;;; cmacs-cmacsgi-c-tests.el --- Tests for cmacsgi `c' subcommand group  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT smoke tests for the cmacsgi `c' subcommand group.  Each test
;; exercises one branch of the cintrospect/cpatch surface via
;; `bacon-eval' so the full Bacon -> libcmacs-api -> Emacs -> DEFUN
;; round-trip is covered.
;;
;; All tests skip when the bacon feature isn't compiled in, and the
;; cintrospect/cpatch tests additionally skip when the corresponding
;; DEFUNs aren't bound (e.g. configure didn't probe libdw, or the
;; build didn't pass --enable-cmacs-cpatch).

;;; Code:

(require 'ert)

(declare-function cmacs-feature-p "cmacs-glib-tests")
(declare-function bacon-start "bacon")
(declare-function bacon-stop "bacon")
(declare-function bacon-eval "bacon")

(defmacro cmacs-cmacsgi-c--with-bacon (&rest body)
  "Start bacon, run BODY, always stop."
  (declare (indent 0))
  `(unwind-protect
       (progn (bacon-start) ,@body)
     (bacon-stop)))

;;; Read-only introspection

(ert-deftest cmacs-cmacsgi-c-help ()
  "`cmacsgi c --help' lists the subcommands."
  (skip-unless (cmacs-feature-p 'bacon))
  (cmacs-cmacsgi-c--with-bacon
    (let ((rc (bacon-eval "cmacsgi c --help")))
      (should (integerp rc))
      (should (= rc 0)))))

(ert-deftest cmacs-cmacsgi-c-list-defuns ()
  "`cmacsgi c list defun -n 1' completes successfully."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'cmacs-c-list-defuns))
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval "cmacsgi c list defun -n 1")))))

(ert-deftest cmacs-cmacsgi-c-list-objects ()
  "`cmacsgi c objects' completes successfully."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'cmacs-c-list-objects))
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval "cmacsgi c objects")))))

(ert-deftest cmacs-cmacsgi-c-defun-info ()
  "`cmacsgi c defun-info Fcons' completes successfully."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'cmacs-c-defun-info))
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval "cmacsgi c defun-info cons")))))

(ert-deftest cmacs-cmacsgi-c-stack ()
  "`cmacsgi c stack -d 4' completes successfully."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'cmacs-c-stack-trace))
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval "cmacsgi c stack -d 4")))))

(ert-deftest cmacs-cmacsgi-c-list-missing-kind ()
  "`cmacsgi c list' without a KIND exits non-zero."
  (skip-unless (cmacs-feature-p 'bacon))
  (cmacs-cmacsgi-c--with-bacon
    (should (/= 0 (bacon-eval "cmacsgi c list")))))

;;; Symbol read/write (uses the cintrospect demo globals)

(ert-deftest cmacs-cmacsgi-c-get-test-int ()
  "`cmacsgi c get cmacs_cintrospection_test_int int' completes."
  (skip-unless (cmacs-feature-p 'bacon))
  (skip-unless (fboundp 'cmacs-c-symbol-value))
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval
                  "cmacsgi c get cmacs_cintrospection_test_int int")))))

;;; cpatch (only when --enable-cmacs-cpatch)

(ert-deftest cmacs-cmacsgi-c-patches-empty ()
  "`cmacsgi c patches' returns success on a clean image."
  (skip-unless (cmacs-feature-p 'bacon))
  ;; Always succeeds: with cpatch enabled it returns the (possibly
  ;; empty) list; without cpatch it prints the friendly disabled msg.
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval "cmacsgi c patches")))))

(ert-deftest cmacs-cmacsgi-c-unpatch-all-clean ()
  "`cmacsgi c unpatch-all' on a clean image is a no-op."
  (skip-unless (cmacs-feature-p 'bacon))
  (cmacs-cmacsgi-c--with-bacon
    (should (= 0 (bacon-eval "cmacsgi c unpatch-all")))))

(provide 'cmacs-cmacsgi-c-tests)

;;; cmacs-cmacsgi-c-tests.el ends here
