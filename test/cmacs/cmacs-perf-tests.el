;;; cmacs-perf-tests.el --- the cmacs-perf harness  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Self-test for admin/cmacs-perf.sh and its in-editor runtime
;; admin/cmacs-perf/cmacs-perf.el.  A benchmark harness that quietly
;; measures the wrong thing is worse than none, so these tests pin the
;; properties the numbers depend on rather than the numbers themselves:
;;
;;   - a workload whose CHECK fails is a mismatch (exit 3), one that
;;     signals is an error (exit 2), and the driver keeps neither;
;;   - TEARDOWN runs even when the body signalled;
;;   - a declared primary metric that is not reported voids the sample;
;;   - the perf gate counts only the timed body: the instruction count
;;     scales with iterations instead of being swamped by startup;
;;   - every workload file byte-compiles warning-free, and batch and
;;     TUI workloads both run to "ok" through the real driver.
;;
;; The full catalogue at one iteration each is tagged :expensive-test.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst cmacs-perf-tests--root
  (expand-file-name "../../" (file-name-directory
                              (or load-file-name buffer-file-name)))
  "The tree under test.")

(defconst cmacs-perf-tests--script
  (expand-file-name "admin/cmacs-perf.sh" cmacs-perf-tests--root)
  "The driver under test.")

(defconst cmacs-perf-tests--runtime
  (expand-file-name "admin/cmacs-perf/cmacs-perf.el" cmacs-perf-tests--root)
  "The in-editor runtime under test.")

(defconst cmacs-perf-tests--editor
  (expand-file-name invocation-name invocation-directory)
  "The Emacs running these tests, used as the editor under test.")

(defun cmacs-perf-tests--tools-p ()
  "Return non-nil when the driver's required tools are installed."
  (cl-every #'executable-find '("bash" "yq" "awk" "column" "timeout")))

(defmacro cmacs-perf-tests--with-temp-dir (var &rest body)
  "Bind VAR to a fresh temporary directory around BODY, then delete it."
  (declare (indent 1))
  `(let ((,var (make-temp-file "cmacs-perf-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun cmacs-perf-tests--driver (out &rest args)
  "Run the driver with ARGS, writing sessions under OUT.
Return (EXIT-STATUS . OUTPUT)."
  (with-temp-buffer
    (let ((status (apply #'call-process "bash" nil t nil
                         cmacs-perf-tests--script
                         "--editor" cmacs-perf-tests--editor
                         "--out" out "--quiet" args)))
      (cons status (buffer-string)))))

(defun cmacs-perf-tests--samples (out)
  "Return the rows of the newest session's samples.csv under OUT.
Each row is a list of fields; the header is dropped."
  (let* ((sessions (sort (directory-files out t "\\`[0-9]") #'string<))
         (csv (expand-file-name "samples.csv" (car (last sessions)))))
    (with-temp-buffer
      (insert-file-contents csv)
      (mapcar (lambda (line) (split-string line ","))
              (cdr (split-string (buffer-string) "\n" t))))))

(defun cmacs-perf-tests--run-workload-file (workload body &optional extra)
  "Run WORKLOAD defined by the form BODY in a child Emacs.
EXTRA is more Lisp evaluated after BODY.  Return (EXIT . RESULT) where
RESULT is the parsed result JSON as an alist, or nil."
  (cmacs-perf-tests--with-temp-dir dir
    (let ((file (expand-file-name "cmacs-perf-test-workload.el" dir))
          (result (expand-file-name "result.json" dir))
          (process-environment (copy-sequence process-environment)))
      (with-temp-file file
        (insert ";;; -*- lexical-binding: t; -*-\n"
                (prin1-to-string '(require 'cmacs-perf)) "\n"
                (prin1-to-string body) "\n"
                (if extra (prin1-to-string extra) "") "\n"))
      (setenv "CMACS_PERF_WORKLOAD" workload)
      (setenv "CMACS_PERF_RESULT" result)
      (setenv "CMACS_PERF_CTL" nil)
      (setenv "CMACS_PERF_ACK" nil)
      (setenv "CMACS_PERF_ITERATIONS" nil)
      (let ((exit (call-process cmacs-perf-tests--editor nil nil nil
                                "-Q" "--batch"
                                "-L" (file-name-directory
                                      cmacs-perf-tests--runtime)
                                "-l" "cmacs-perf" "-l" file
                                "-f" "cmacs-perf-main")))
        (cons exit
              (and (file-exists-p result)
                   (with-temp-buffer
                     (insert-file-contents result)
                     (json-parse-buffer :object-type 'alist
                                        :null-object nil
                                        :false-object nil))))))))

;;;; The runtime's verdicts.

(ert-deftest cmacs-perf-test-ok-workload ()
  "A workload whose invariants hold exits 0 and reports its metrics."
  (pcase-let ((`(,exit . ,result)
               (cmacs-perf-tests--run-workload-file
                "t-ok"
                '(cmacs-perf-define
                  "t-ok" :iterations 3
                  :body (lambda (_state n) `((answer . ,(* n 2))))
                  :check (lambda (_state metrics)
                           (cmacs-perf-expect nil "answer"
                                              (alist-get 'answer metrics)
                                              6))))))
    (should (= exit 0))
    (should (equal (alist-get 'status result) "ok"))
    (should (equal (alist-get 'workload result) "t-ok"))
    (should (= (alist-get 'iterations result) 3))
    (should (= (alist-get 'answer (alist-get 'metrics result)) 6))
    (should (equal (alist-get 'frontend result) "batch"))))

(ert-deftest cmacs-perf-test-mismatch-exits-3 ()
  "A failed invariant is a mismatch, never a sample."
  (pcase-let ((`(,exit . ,result)
               (cmacs-perf-tests--run-workload-file
                "t-bad"
                '(cmacs-perf-define
                  "t-bad"
                  :body (lambda (_state _n) '((answer . 41)))
                  :check (lambda (_state metrics)
                           (cmacs-perf-expect nil "answer"
                                              (alist-get 'answer metrics)
                                              42))))))
    (should (= exit 3))
    (should (equal (alist-get 'status result) "mismatch"))
    (should (string-match-p "answer: got 41, expected 42"
                            (aref (alist-get 'failures result) 0)))))

(ert-deftest cmacs-perf-test-error-exits-2-and-tears-down ()
  "A body that signals is an error, and TEARDOWN still runs."
  (cmacs-perf-tests--with-temp-dir dir
    (let ((marker (expand-file-name "torn-down" dir)))
      (pcase-let ((`(,exit . ,result)
                   (cmacs-perf-tests--run-workload-file
                    "t-error"
                    `(cmacs-perf-define
                      "t-error"
                      :body (lambda (_state _n) (error "Deliberate failure"))
                      :teardown (lambda (_state)
                                  (write-region "" nil ,marker nil
                                                'silent))))))
        (should (= exit 2))
        (should (equal (alist-get 'status result) "error"))
        (should (string-match-p "Deliberate failure"
                                (alist-get 'error result)))
        (should (file-exists-p marker))))))

(ert-deftest cmacs-perf-test-missing-primary-is-mismatch ()
  "A declared primary metric the body never reports voids the sample."
  (pcase-let ((`(,exit . ,result)
               (cmacs-perf-tests--run-workload-file
                "t-primary"
                '(cmacs-perf-define
                  "t-primary" :primary 'latency_us
                  :body (lambda (_state _n) '((other . 1)))))))
    (should (= exit 3))
    (should (string-match-p "primary metric latency_us"
                            (aref (alist-get 'failures result) 0)))))

(ert-deftest cmacs-perf-test-primary-reported ()
  "A reported primary metric is copied to the top of the result."
  (pcase-let ((`(,exit . ,result)
               (cmacs-perf-tests--run-workload-file
                "t-primary-ok"
                '(cmacs-perf-define
                  "t-primary-ok" :primary 'latency_us
                  :body (lambda (_state _n) '((latency_us . 250)))))))
    (should (= exit 0))
    (should (equal (alist-get 'primary_metric result) "latency_us"))
    (should (= (alist-get 'primary result) 250))))

(ert-deftest cmacs-perf-test-unknown-workload ()
  "Naming a workload nobody registered is an error, not a silent no-op."
  (pcase-let ((`(,exit . ,result)
               (cmacs-perf-tests--run-workload-file "t-nobody" nil)))
    (should (= exit 2))
    (should (string-match-p "unknown cmacs-perf workload"
                            (alist-get 'error result)))))

;;;; The driver.

(ert-deftest cmacs-perf-test-shellcheck ()
  "The driver is ShellCheck-clean."
  (skip-unless (executable-find "shellcheck"))
  (should (= 0 (call-process "shellcheck" nil nil nil
                             cmacs-perf-tests--script))))

(ert-deftest cmacs-perf-test-list-compiles-every-workload ()
  "`list' byte-compiles every workload file warning-free and lists them.
`pf_build' compiles with `byte-compile-error-on-warn', so a warning in
any workload file fails this test."
  (skip-unless (cmacs-perf-tests--tools-p))
  (cmacs-perf-tests--with-temp-dir out
    (pcase-let ((`(,exit . ,output) (cmacs-perf-tests--driver out "list")))
      (should (= exit 0))
      (dolist (name '("bytecode-call-loop" "lexical-loop" "builtin-call-point"
                      "search-literal-forward" "bounded-search-no-edit"
                      "editing-simulation" "input-latency" "scrolling"
                      "mx-tab-completion"))
        (should (string-match-p (concat "^" (regexp-quote name) " ")
                                output))))))

(ert-deftest cmacs-perf-test-run-batch-and-tui ()
  "Batch and TUI workloads both run to ok through the real driver."
  (skip-unless (cmacs-perf-tests--tools-p))
  (cmacs-perf-tests--with-temp-dir out
    (pcase-let ((`(,exit . ,output)
                 (cmacs-perf-tests--driver
                  out "--no-counters" "--iterations" "2"
                  "run" "lexical-loop" "org-editing" "scrolling"
                  "sustained-editing")))
      (should (= exit 0))
      (let ((rows (cmacs-perf-tests--samples out)))
        (should (= (length rows) 4))
        (dolist (row rows)
          (should (equal (nth 3 row) "ok"))))
      (should (string-match-p "scrolling +ok" output)))))

(ert-deftest cmacs-perf-test-unknown-workload-is-usage-error ()
  "The driver refuses a workload name it does not know."
  (skip-unless (cmacs-perf-tests--tools-p))
  (cmacs-perf-tests--with-temp-dir out
    (should (= 2 (car (cmacs-perf-tests--driver
                       out "--no-counters" "run" "no-such-workload"))))))

(ert-deftest cmacs-perf-test-gate-excludes-startup ()
  "Gated counts cover the body, not startup, setup or result writing.
Startup alone executes on the order of a billion instructions.  With
the gate working, 1,000 iterations of `lexical-loop' count a small
fraction of that, and 1,000,000 iterations count roughly a thousand
times more -- the count follows the work."
  (skip-unless (and (cmacs-perf-tests--tools-p) (executable-find "perf")
                    (= 0 (call-process "perf" nil nil nil "stat" "-x,"
                                       "-e" "instructions:u" "-o"
                                       null-device "--" "true"))))
  (cmacs-perf-tests--with-temp-dir out
    (let (small large)
      (should (= 0 (car (cmacs-perf-tests--driver
                         out "--counters" "--iterations" "1000"
                         "run" "lexical-loop"))))
      (setq small (string-to-number
                   (nth 11 (car (cmacs-perf-tests--samples out)))))
      (should (= 0 (car (cmacs-perf-tests--driver
                         out "--counters" "--iterations" "1000000"
                         "run" "lexical-loop"))))
      (setq large (string-to-number
                   (nth 11 (car (cmacs-perf-tests--samples out)))))
      (should (> small 0))
      (should (< small 20000000))
      (should (> (/ large (float small)) 100)))))

(ert-deftest cmacs-perf-test-every-workload-runs ()
  "Every registered workload runs to ok at one iteration."
  :tags '(:expensive-test)
  (skip-unless (cmacs-perf-tests--tools-p))
  (cmacs-perf-tests--with-temp-dir out
    (let* ((listing (cdr (cmacs-perf-tests--driver out "list")))
           (names (mapcar (lambda (line) (car (split-string line)))
                          (cdr (split-string listing "\n" t)))))
      (should (> (length names) 40))
      (pcase-let ((`(,exit . ,output)
                   (apply #'cmacs-perf-tests--driver out "--no-counters"
                          "--iterations" "1" "run" names)))
        (should (= exit 0))
        (should-not (string-match-p "invalid" output))))))

(provide 'cmacs-perf-tests)

;;; cmacs-perf-tests.el ends here
