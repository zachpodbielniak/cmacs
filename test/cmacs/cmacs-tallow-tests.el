;;; cmacs-tallow-tests.el --- ERT tests for Tallow support  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Covers cmacs-tallow.el: finding the toolchain, the eglot and dape
;; registrations, the .tlw mode wiring, the REPL's JSON protocol handling
;; (fed canned lines, so it runs on any build) and, when the toolchain is
;; built, a real REPL round trip.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-tallow-tests

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'cmacs-tallow nil 'noerror)

(defvar eglot-server-programs)
(defvar dape-configs)

(ert-deftest cmacs-tallow-auto-mode ()
  "A .tlw file is routed through cmacs's mode setup."
  (skip-unless (fboundp 'cmacs-tallow-mode-autoload))
  (should (eq (cdr (assoc "\\.tlw\\'" auto-mode-alist)) 'cmacs-tallow-mode-autoload)))

(ert-deftest cmacs-tallow-server-contact ()
  "eglot runs `tallow lsp' with the toolchain cmacs found."
  (skip-unless (fboundp 'cmacs-tallow-server-contact))
  (let ((c (cmacs-tallow-server-contact)))
    (should (equal (cadr c) "lsp"))
    (should (string-match-p "tallow\\'" (car c)))))

(ert-deftest cmacs-tallow-eglot-entry ()
  "Loading eglot registers `tallow-mode' exactly once."
  (skip-unless (and (fboundp 'cmacs-tallow-server-contact) (require 'eglot nil t)))
  (should (eq (alist-get 'tallow-mode eglot-server-programs) 'cmacs-tallow-server-contact))
  (should (= 1 (cl-count-if (lambda (e) (eq (car-safe e) 'tallow-mode))
                            eglot-server-programs))))

(ert-deftest cmacs-tallow-dape-configs ()
  "Both debug configurations are offered: gdb-backed and suet time travel."
  (skip-unless (fboundp 'cmacs-tallow--dape-configs))
  (let ((cfgs (cmacs-tallow--dape-configs)))
    (should (assq 'tallow cfgs))
    (should (assq 'tallow-suet cfgs))
    (should (equal (plist-get (cdr (assq 'tallow-suet cfgs)) :backend) "suet"))
    (should (equal (plist-get (cdr (assq 'tallow cfgs)) 'command-args) '("dap")))))

(ert-deftest cmacs-tallow-repl-renders-protocol ()
  "JSON lines from `tallow repl --json' become prompt-terminated text;
responses a synchronous caller waits for are kept out of the buffer."
  (skip-unless (fboundp 'cmacs-tallow-repl--preoutput))
  (with-temp-buffer
    (setq-local cmacs-tallow-repl--partial "")
    (setq-local cmacs-tallow-repl--waiters (list (cons 9 nil)))
    (let ((out (cmacs-tallow-repl--preoutput
                (concat "{\"kind\":\"ready\",\"version\":\"0.33.0\"}\n"
                        "{\"id\":1,\"kind\":\"output\",\"text\":\"hi\\n\"}\n"
                        "{\"id\":1,\"kind\":\"value\",\"value\":\"3\",\"type\":\"i64\"}\n"
                        "{\"id\":9,\"kind\":\"candidates\",\"items\":[]}\n"
                        "{\"id\":2,\"kind\":\"err"))))
      (should (string-match-p "Tallow 0.33.0" out))
      (should (string-match-p "hi\n3 : i64\n" out))
      (should (string-suffix-p cmacs-tallow-repl-prompt out))
      ;; The completion response went to its waiter, not the buffer.
      (should (equal (plist-get (cdr (assq 9 cmacs-tallow-repl--waiters)) :kind)
                     "candidates"))
      ;; The partial line waits for the rest.
      (should (equal cmacs-tallow-repl--partial "{\"id\":2,\"kind\":\"err"))
      (let ((more (cmacs-tallow-repl--preoutput
                   "or\",\"message\":\"boom\",\"code\":\"E12\",\"span\":{\"line\":1,\"col\":4}}\n")))
        (should (string-match-p "error\\[E12\\]: boom (1:4)" more))))))

(ert-deftest cmacs-tallow-repl-round-trip ()
  "With the toolchain built, the REPL evaluates an expression."
  (skip-unless (and (fboundp 'cmacs-tallow-program)
                    (cmacs-tallow-program "tallow-suet")))
  (save-window-excursion
    (cmacs-tallow-repl)
    (let ((buf (get-buffer cmacs-tallow-repl-buffer-name)))
      (unwind-protect
          (with-current-buffer buf
            (let ((i 0))
              (while (and (not (string-match-p (regexp-quote cmacs-tallow-repl-prompt)
                                               (buffer-string)))
                          (< i 200))
                (accept-process-output nil 0.05) (setq i (1+ i))))
            (goto-char (point-max))
            (insert "1 + 2")
            (comint-send-input)
            (let ((i 0))
              (while (and (not (string-match-p "^3\\b" (buffer-string))) (< i 200))
                (accept-process-output nil 0.05) (setq i (1+ i))))
            (should (string-match-p "^3\\b" (buffer-string))))
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf))))))

(provide 'cmacs-tallow-tests)

;;; cmacs-tallow-tests.el ends here
