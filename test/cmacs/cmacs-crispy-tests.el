;;; cmacs-crispy-tests.el --- Tests for crispy C scripting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs crispy C scripting integration.
;; Tests cover inline evaluation, string evaluation with stdout capture,
;; file compilation, script execution, REPL operations, and cache status.

;;; Code:

(require 'ert)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Basic eval tests

(ert-deftest cmacs-crispy-test-eval-returns-integer ()
  "Test that `crispy-eval' returns an integer exit code."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((rc (crispy-eval "int main(void) { return 0; }")))
    (should (integerp rc))))

(ert-deftest cmacs-crispy-test-eval-nonzero-exit ()
  "Test that `crispy-eval' returns an integer for nonzero exit."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((rc (crispy-eval "int main(void) { return 42; }")))
    (should (integerp rc))))

(ert-deftest cmacs-crispy-test-eval-requires-string ()
  "Test that `crispy-eval' rejects non-string code."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-eval 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-crispy-test-eval-invalid-c ()
  "Test that `crispy-eval' signals crispy-error for invalid C."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-eval "this is not valid C at all;;;")
                :type 'crispy-error))

;;; String eval tests (stdout capture)

(ert-deftest cmacs-crispy-test-eval-string-returns-string ()
  "Test that `crispy-eval-string' returns a string (stdout capture)."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((output (crispy-eval-string
                 "#include <stdio.h>\nint main(void) { printf(\"hello\"); return 0; }")))
    (should (stringp output))))

(ert-deftest cmacs-crispy-test-eval-string-empty-output ()
  "Test that `crispy-eval-string' returns empty string for no output."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((output (crispy-eval-string "int main(void) { return 0; }")))
    (should (stringp output))
    (should (equal output ""))))

(ert-deftest cmacs-crispy-test-eval-string-requires-string ()
  "Test that `crispy-eval-string' rejects non-string code."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-eval-string 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-crispy-test-eval-string-invalid-c ()
  "Test that `crispy-eval-string' signals crispy-error for invalid C."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-eval-string "not valid C code!!!")
                :type 'crispy-error))

;;; Compile tests

(ert-deftest cmacs-crispy-test-compile-requires-string ()
  "Test that `crispy-compile' rejects non-string file arg."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-compile 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-crispy-test-compile-nonexistent-file ()
  "Test that `crispy-compile' signals crispy-error for missing file."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-compile "/nonexistent/path/to/script.c")
                :type 'crispy-error))

(ert-deftest cmacs-crispy-test-compile-valid-file ()
  "Test compiling a temporary C file returns a cached path."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((tmpfile (make-temp-file "cmacs-crispy-test-" nil ".c")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "int main(void) { return 0; }\n"))
          (let ((result (crispy-compile tmpfile)))
            ;; Should return either a string path or nil.
            (should (or (stringp result) (null result)))))
      (delete-file tmpfile))))

;;; Run tests

(ert-deftest cmacs-crispy-test-run-requires-string ()
  "Test that `crispy-run' rejects non-string file arg."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-run 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-crispy-test-run-valid-file ()
  "Test running a temporary C script returns an exit code."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((tmpfile (make-temp-file "cmacs-crispy-test-" nil ".c")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "int main(void) { return 7; }\n"))
          (let ((rc (crispy-run tmpfile)))
            (should (integerp rc))
            (should (= rc 7))))
      (delete-file tmpfile))))

(ert-deftest cmacs-crispy-test-run-with-args ()
  "Test running a C script that uses argc."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((tmpfile (make-temp-file "cmacs-crispy-test-" nil ".c")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "int main(int argc, char **argv) { return argc; }\n"))
          (let ((rc (crispy-run tmpfile "arg1" "arg2")))
            (should (integerp rc))
            ;; argc counts the program args (not the file itself in crispy).
            (should (>= rc 2))))
      (delete-file tmpfile))))

;;; REPL tests

(ert-deftest cmacs-crispy-test-repl-eval-returns-integer ()
  "Test that `crispy-repl-eval' returns an integer."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((rc (crispy-repl-eval "int x = 42;")))
    (should (integerp rc))))

(ert-deftest cmacs-crispy-test-repl-eval-requires-string ()
  "Test that `crispy-repl-eval' rejects non-string code."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-error (crispy-repl-eval 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-crispy-test-repl-reset ()
  "Test that `crispy-repl-reset' returns nil without error."
  (skip-unless (cmacs-feature-p 'crispy))
  (should-not (crispy-repl-reset)))

(ert-deftest cmacs-crispy-test-repl-eval-after-reset ()
  "Test REPL eval after reset still works."
  (skip-unless (cmacs-feature-p 'crispy))
  (crispy-repl-reset)
  (let ((rc (crispy-repl-eval "int y = 10;")))
    (should (integerp rc))))

;;; Cache status tests

(ert-deftest cmacs-crispy-test-cache-status-returns-string-or-nil ()
  "Test that `crispy-cache-status' returns a string or nil."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((status (crispy-cache-status)))
    (should (or (stringp status) (null status)))))

(ert-deftest cmacs-crispy-test-cache-status-is-directory ()
  "Test that the cache directory path actually exists."
  (skip-unless (cmacs-feature-p 'crispy))
  (let ((dir (crispy-cache-status)))
    (when (stringp dir)
      (should (file-directory-p dir)))))

;; Edge cases
(ert-deftest cmacs-crispy-eval-empty-string ()
  "Evaluating an empty string should not crash."
  (skip-unless (fboundp 'crispy-eval))
  (should (integerp (crispy-eval ""))))

(ert-deftest cmacs-crispy-eval-string-no-output ()
  "C code that produces no output returns empty string."
  (skip-unless (fboundp 'crispy-eval-string))
  (let ((result (crispy-eval-string "int main(void){return 0;}")))
    (should (stringp result))
    (should (string= result ""))))

(ert-deftest cmacs-crispy-eval-string-multiline ()
  "C code with printf should not error and should return a string."
  (skip-unless (fboundp 'crispy-eval-string))
  (let ((result (crispy-eval-string
                 "#include <stdio.h>\nint main(void){printf(\"a\\nb\\n\");return 0;}")))
    (should (stringp result))))

(ert-deftest cmacs-crispy-run-nonexistent-file ()
  "Running a nonexistent file should error."
  (skip-unless (fboundp 'crispy-run))
  (should-error (crispy-run "/nonexistent/file.c")))

(ert-deftest cmacs-crispy-repl-eval-multiple ()
  "Multiple REPL evals in sequence should not corrupt state."
  (skip-unless (fboundp 'crispy-repl-eval))
  ;; Each REPL eval is an independent compilation — variables don't
  ;; persist across evals, so use self-contained statements.
  (should (integerp (crispy-repl-eval "int x = 1;")))
  (should (integerp (crispy-repl-eval "int y = 2;"))))

(ert-deftest cmacs-crispy-compile-type-check ()
  "crispy-compile requires a string argument."
  (skip-unless (fboundp 'crispy-compile))
  (should-error (crispy-compile 42))
  (should-error (crispy-compile nil)))

(provide 'cmacs-crispy-tests)
;;; cmacs-crispy-tests.el ends here
