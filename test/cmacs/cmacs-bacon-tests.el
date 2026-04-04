;;; cmacs-bacon-tests.el --- Tests for bacon shell integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs bacon shell integration.
;; Tests cover shell start/stop lifecycle, command evaluation,
;; C block evaluation, alias get/set, completion, environment,
;; file sourcing, and running state predicates.

;;; Code:

(require 'ert)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Start/stop lifecycle tests

(ert-deftest cmacs-bacon-test-start ()
  "Test that `bacon-start' returns non-nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (should (bacon-start))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-start-idempotent ()
  "Test that starting an already-running shell returns non-nil without error."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should (bacon-start)))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-stop-returns-nil ()
  "Test that `bacon-stop' returns nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-start)
  (should-not (bacon-stop)))

(ert-deftest cmacs-bacon-test-stop-when-not-running ()
  "Test that stopping when not running is a no-op."
  (skip-unless (cmacs-feature-p 'bacon))
  ;; Ensure stopped state.
  (bacon-stop)
  (should-not (bacon-stop)))

;;; Running predicate tests

(ert-deftest cmacs-bacon-test-running-p-after-start ()
  "Test that `bacon-running-p' is non-nil after start."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should (bacon-running-p)))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-running-p-after-stop ()
  "Test that `bacon-running-p' is nil after stop."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-start)
  (bacon-stop)
  (should-not (bacon-running-p)))

(ert-deftest cmacs-bacon-test-running-p-initial ()
  "Test that `bacon-running-p' returns t or nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (let ((result (bacon-running-p)))
    (should (memq result '(t nil)))))

;;; Eval tests

(ert-deftest cmacs-bacon-test-eval-returns-integer ()
  "Test that `bacon-eval' returns an integer exit code."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((rc (bacon-eval "true")))
          (should (integerp rc))
          (should (= rc 0))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-eval-false ()
  "Test that `bacon-eval' of false returns nonzero."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((rc (bacon-eval "false")))
          (should (integerp rc))
          (should (/= rc 0))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-eval-requires-string ()
  "Test that `bacon-eval' rejects non-string command."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-eval 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-bacon-test-eval-auto-starts ()
  "Test that `bacon-eval' auto-starts the shell if not running."
  (skip-unless (cmacs-feature-p 'bacon))
  ;; Ensure stopped.
  (bacon-stop)
  (unwind-protect
      (progn
        (bacon-eval "true")
        (should (bacon-running-p)))
    (bacon-stop)))

;;; C block eval tests

(ert-deftest cmacs-bacon-test-eval-c-returns-integer ()
  "Test that `bacon-eval-c' returns an integer exit code."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((rc (bacon-eval-c "int main(void) { return 0; }")))
          (should (integerp rc))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-eval-c-requires-string ()
  "Test that `bacon-eval-c' rejects non-string code."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-eval-c 42)
                :type 'wrong-type-argument))

;;; Alias tests

(ert-deftest cmacs-bacon-test-alias-set-and-get ()
  "Test setting and retrieving a bacon alias."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (bacon-alias "test-alias" "echo hello")
        (let ((val (bacon-alias "test-alias")))
          (should (equal val "echo hello"))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-alias-get-nonexistent ()
  "Test that getting a nonexistent alias returns nil."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should-not (bacon-alias "nonexistent-alias-xyz-12345")))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-alias-requires-string-name ()
  "Test that `bacon-alias' requires a string name."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-alias 42)
                :type 'wrong-type-argument))

;;; Completion tests

(ert-deftest cmacs-bacon-test-complete-returns-list ()
  "Test that `bacon-complete' returns a list."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (let ((result (bacon-complete "ech")))
          (should (listp result))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-complete-requires-string ()
  "Test that `bacon-complete' requires a string prefix."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-complete 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-bacon-test-complete-no-shell ()
  "Test that `bacon-complete' returns nil when shell is not running."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-stop)
  (should-not (bacon-complete "anything")))

;;; Environment tests

(ert-deftest cmacs-bacon-test-environment-returns-list ()
  "Test that `bacon-environment' returns a list."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (bacon-eval "true")
        (let ((env (bacon-environment)))
          (should (listp env))))
    (bacon-stop)))

(ert-deftest cmacs-bacon-test-environment-no-shell ()
  "Test that `bacon-environment' returns nil when shell is not running."
  (skip-unless (cmacs-feature-p 'bacon))
  (bacon-stop)
  (should-not (bacon-environment)))

;;; Source tests

(ert-deftest cmacs-bacon-test-source-requires-string ()
  "Test that `bacon-source' requires a string file path."
  (skip-unless (cmacs-feature-p 'bacon))
  (should-error (bacon-source 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-bacon-test-source-nonexistent-file ()
  "Test that `bacon-source' signals bacon-error for missing file."
  (skip-unless (cmacs-feature-p 'bacon))
  (unwind-protect
      (progn
        (bacon-start)
        (should-error (bacon-source "/nonexistent/path/to/file.sh")
                      :type 'bacon-error))
    (bacon-stop)))

(provide 'cmacs-bacon-tests)
;;; cmacs-bacon-tests.el ends here
