;;; cmacs-crispy-tests.el --- Tests for crispy C scripting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs crispy C scripting integration.
;; Tests cover inline evaluation, string evaluation with stdout capture,
;; file compilation, script execution, REPL operations, and cache status.

;;; Code:

(require 'ert)
(require 'cmacs-crispy)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;; NOTE: crispy compiles C via gcc into the user cache dir.  The test
;; harness sandboxes HOME to /nonexistent but exports a writable
;; XDG_CACHE_HOME (see TEST_XDG_CACHE in test/Makefile.in) so these
;; tests can compile.

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

;;; REPL colon-command parsing (pure — no built binary needed)

(ert-deftest cmacs-crispy-parse-command-with-arg ()
  "Colon command with an argument parses into (NAME . ARG)."
  (should (equal (crispy-repl--parse-command ":type 1+2")
                 '(":type" . "1+2"))))

(ert-deftest cmacs-crispy-parse-command-no-arg ()
  "Colon command without an argument has a nil ARG."
  (should (equal (crispy-repl--parse-command ":type") '(":type")))
  (should (equal (crispy-repl--parse-command ":help") '(":help"))))

(ert-deftest cmacs-crispy-parse-command-bang-normalized ()
  "\":!CMD\" with no space is normalized to (\":!\" . \"CMD\")."
  (should (equal (crispy-repl--parse-command ":!ls -la")
                 '(":!" . "ls -la")))
  (should (equal (crispy-repl--parse-command ":! echo hi")
                 '(":!" . "echo hi"))))

(ert-deftest cmacs-crispy-parse-command-malformed ()
  "Garbage colon input fails to parse."
  (should-not (crispy-repl--parse-command ": leading space"))
  (should-not (crispy-repl--parse-command ":123")))

(ert-deftest cmacs-crispy-lookup-command-aliases ()
  "Aliases resolve to the same command entry as the full name."
  (should (eq (crispy-repl--lookup-command ":t")
              (crispy-repl--lookup-command ":type")))
  (should (eq (crispy-repl--lookup-command ":?")
              (crispy-repl--lookup-command ":help")))
  (should (eq (crispy-repl--lookup-command ":!")
              (crispy-repl--lookup-command ":bacon")))
  (should-not (crispy-repl--lookup-command ":nosuch")))

(ert-deftest cmacs-crispy-dispatch-unknown-command ()
  "Unknown colon commands return a helpful message."
  (should (string-match-p "unknown command :nosuch"
                          (crispy-repl--dispatch-command ":nosuch"))))

(ert-deftest cmacs-crispy-dispatch-missing-arg ()
  "Arg-taking commands return a usage string without an argument."
  (should (string-match-p "\\`usage: :type"
                          (crispy-repl--dispatch-command ":type")))
  (should (string-match-p "\\`usage: :load"
                          (crispy-repl--dispatch-command ":l"))))

(ert-deftest cmacs-crispy-help-covers-every-command ()
  "The generated :help text mentions every command in the table."
  (let ((help (crispy-repl--dispatch-command ":help")))
    (dolist (entry crispy-repl-commands)
      (should (string-match-p (regexp-quote (car entry)) help)))))

(ert-deftest cmacs-crispy-type-probe-shape ()
  "The :type probe is a block statement covering all candidates."
  (let ((probe (crispy-repl--type-probe "1 + 2")))
    (should (string-prefix-p "{" probe))
    (should (string-suffix-p "}" probe))
    (should (string-match-p (regexp-quote "__typeof__(1 + 2)") probe))
    (dolist (type crispy-repl--type-candidates)
      (should (string-match-p (regexp-quote (format "\"%s\"" type))
                              probe)))))

;;; Multiline depth tracking (pure)

(ert-deftest cmacs-crispy-depth-delta-balanced ()
  "Balanced statements have zero depth."
  (should (= 0 (crispy-repl--depth-delta "int x = 1;")))
  (should (= 0 (crispy-repl--depth-delta "g_print(\"hi\\n\");")))
  (should (= 0 (crispy-repl--depth-delta
                "for (int i = 0; i < 3; i++) { g_print(\"x\"); }"))))

(ert-deftest cmacs-crispy-depth-delta-open ()
  "Unclosed braces yield a positive depth."
  (should (= 1 (crispy-repl--depth-delta "for (int i = 0; i < 3; i++) {")))
  (should (= 2 (crispy-repl--depth-delta "void f(void) { if (1) {"))))

(ert-deftest cmacs-crispy-depth-delta-string-literal ()
  "Braces inside string literals do not count."
  (should (= 0 (crispy-repl--depth-delta "char *s = \"}{\";")))
  (should (= 0 (crispy-repl--depth-delta "char *s = \"\\\"{\";"))))

(ert-deftest cmacs-crispy-depth-delta-char-literal ()
  "Braces inside character literals do not count."
  (should (= 0 (crispy-repl--depth-delta "char c = '{';"))))

(ert-deftest cmacs-crispy-depth-delta-comments ()
  "Braces inside comments do not count."
  (should (= 0 (crispy-repl--depth-delta "/* { */ int x;")))
  (should (= 0 (crispy-repl--depth-delta "// {\nint x;")))
  (should (= 1 (crispy-repl--depth-delta "if (1) { // }"))))

(ert-deftest cmacs-crispy-depth-delta-multiline-closes ()
  "A closing line brings the cumulative depth back to zero."
  (should (<= (crispy-repl--depth-delta
               "for (int i = 0; i < 3; i++) {\n  g_print(\"%d\", i);\n}")
              0)))

;;; Persistent REPL eval (needs built binary)

(ert-deftest cmacs-crispy-repl-eval-string-autoprint ()
  "Bare expressions are auto-printed as => VALUE."
  (skip-unless (fboundp 'crispy-repl-eval-string))
  (crispy-repl-reset)
  (should (string-match-p "=> 3" (crispy-repl-eval-string "1 + 2"))))

(ert-deftest cmacs-crispy-repl-eval-string-preamble-accumulates ()
  "Preprocessor directives accumulate in the REPL preamble."
  (skip-unless (fboundp 'crispy-repl-eval-string))
  (crispy-repl-reset)
  (unwind-protect
      (progn
        (crispy-repl-eval-string "#include <math.h>")
        (should (string-match-p "math\\.h" (crispy-repl-preamble))))
    (crispy-repl-reset)))

(ert-deftest cmacs-crispy-repl-eval-string-persistence ()
  "Function definitions persist across REPL evaluations."
  (skip-unless (fboundp 'crispy-repl-eval-string))
  (crispy-repl-reset)
  (unwind-protect
      (progn
        (crispy-repl-eval-string
         "int cmacs_test_square(int x) { return x * x; }")
        (should (string-match-p
                 "=> 49"
                 (crispy-repl-eval-string "cmacs_test_square(7)"))))
    (crispy-repl-reset)))

(ert-deftest cmacs-crispy-repl-preamble-reset ()
  "`crispy-repl-reset' clears the preamble."
  (skip-unless (fboundp 'crispy-repl-preamble))
  (crispy-repl-eval-string "#include <math.h>")
  (crispy-repl-reset)
  (should (string-empty-p (crispy-repl-preamble))))

(ert-deftest cmacs-crispy-repl-eval-string-invalid-c ()
  "Invalid C signals crispy-error from the persistent REPL."
  (skip-unless (fboundp 'crispy-repl-eval-string))
  (should-error (crispy-repl-eval-string "this is not C at all;;;")
                :type 'crispy-error))

(ert-deftest cmacs-crispy-repl-eval-no-hang ()
  "`crispy-repl-eval' returns promptly (regression: it used to call
crispy_repl_start, a blocking readline loop on stdin)."
  (skip-unless (fboundp 'crispy-repl-eval))
  (should (integerp (crispy-repl-eval "int cmacs_test_nohang = 1;"))))

;;; REPL buffer (prompt protection)

(ert-deftest cmacs-crispy-repl-prompt-read-only ()
  "The REPL prompt carries the read-only property and resists deletion."
  (skip-unless (fboundp 'crispy-eval-string))
  (let ((buf-name " *crispy-test-repl*"))
    (let ((crispy-repl-buffer-name buf-name))
      (unwind-protect
          (progn
            (save-window-excursion (crispy-repl))
            (with-current-buffer buf-name
              (should (get-text-property (1- (point-max)) 'read-only))
              (should-error
               (delete-region (- (point-max) 3) (point-max)))))
        (when (get-buffer buf-name)
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf-name)))))))

(ert-deftest cmacs-crispy-repl-buffer-eval ()
  "Sending input through the comint REPL prints => VALUE and a prompt."
  (skip-unless (fboundp 'crispy-repl-eval-string))
  (let ((buf-name " *crispy-test-repl2*"))
    (let ((crispy-repl-buffer-name buf-name))
      (unwind-protect
          (progn
            (save-window-excursion (crispy-repl))
            (with-current-buffer buf-name
              (goto-char (point-max))
              (insert "1 + 2")
              (comint-send-input)
              (let ((tail (buffer-substring-no-properties
                           (max (point-min) (- (point-max) 40))
                           (point-max))))
                (should (string-match-p "=> 3" tail))
                (should (string-suffix-p crispy-repl-prompt tail)))))
        (when (get-buffer buf-name)
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buf-name)))))))

(provide 'cmacs-crispy-tests)
;;; cmacs-crispy-tests.el ends here
