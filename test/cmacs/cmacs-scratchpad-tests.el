;;; cmacs-scratchpad-tests.el --- Tests for scratchpad polyglot eval -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for cmacs-scratchpad: %crispy / %bacon marker block
;; detection, per-language evaluation, inline output insertion with
;; replace-on-re-eval, and the buffer-name auto-enable filter.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cmacs-scratchpad)

(declare-function cmacs-feature-p "cmacs-glib-tests")

(defmacro cmacs-scratchpad-tests--with-buffer (content &rest body)
  "Run BODY in a temp buffer containing CONTENT, point at start."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (goto-char (point-min))
     ,@body))

;;; Block detection (pure — no built binary needed)

(ert-deftest cmacs-scratchpad-block-elisp-default ()
  "A paragraph without a marker is an elisp block."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n(* 3 4)\n"
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (eq (plist-get block :lang) 'elisp))
      (should (equal (plist-get block :code) "(+ 1 2)\n(* 3 4)")))))

(ert-deftest cmacs-scratchpad-block-crispy-marker ()
  "A %crispy marker line selects the crispy language."
  (cmacs-scratchpad-tests--with-buffer
      "%crispy\ng_print(\"hi\\n\");\n"
    ;; Point on the marker line.
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (eq (plist-get block :lang) 'crispy))
      (should (equal (plist-get block :code) "g_print(\"hi\\n\");")))
    ;; Point inside the body.
    (forward-line 1)
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (eq (plist-get block :lang) 'crispy)))))

(ert-deftest cmacs-scratchpad-block-bacon-marker ()
  "A %bacon marker line selects the bacon language."
  (cmacs-scratchpad-tests--with-buffer "%bacon\necho hi\n"
    (forward-line 1)
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (eq (plist-get block :lang) 'bacon))
      (should (equal (plist-get block :code) "echo hi")))))

(ert-deftest cmacs-scratchpad-block-ends-at-blank-line ()
  "A blank line terminates the block."
  (cmacs-scratchpad-tests--with-buffer
      "%crispy\nline1();\nline2();\n\nnot-in-block\n"
    (forward-line 1)
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (equal (plist-get block :code) "line1();\nline2();")))))

(ert-deftest cmacs-scratchpad-block-ends-at-next-marker ()
  "The next marker line terminates the block."
  (cmacs-scratchpad-tests--with-buffer
      "%crispy\nc_code();\n%bacon\necho hi\n"
    (forward-line 1)
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (eq (plist-get block :lang) 'crispy))
      (should (equal (plist-get block :code) "c_code();")))))

(ert-deftest cmacs-scratchpad-block-nil-on-blank-line ()
  "Point on a blank line yields no block."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n\n(+ 3 4)\n"
    (forward-line 1)
    (should-not (cmacs-scratchpad--block-at-point))))

(ert-deftest cmacs-scratchpad-block-excludes-output ()
  "Output-propertized text is never part of a block."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n"
    (goto-char (point-max))
    (insert (propertize "3\n" 'cmacs-scratchpad-output t))
    ;; Point on the output line: no block.
    (goto-char (point-max))
    (forward-line -1)
    (should-not (cmacs-scratchpad--block-at-point))
    ;; Block at the code line stops before the output.
    (goto-char (point-min))
    (let ((block (cmacs-scratchpad--block-at-point)))
      (should (equal (plist-get block :code) "(+ 1 2)")))))

(ert-deftest cmacs-scratchpad-marker-not-greedy ()
  "Marker regexp matches only exact %crispy / %bacon lines."
  (should (string-match-p cmacs-scratchpad--marker-re "%crispy"))
  (should (string-match-p cmacs-scratchpad--marker-re "  %bacon  "))
  (should-not (string-match-p cmacs-scratchpad--marker-re "%python"))
  (should-not (string-match-p cmacs-scratchpad--marker-re "%crispy extra"))
  (should-not (string-match-p cmacs-scratchpad--marker-re "x %crispy")))

;;; Elisp evaluation and output handling (pure)

(ert-deftest cmacs-scratchpad-eval-elisp-block ()
  "An elisp block evaluates and prints => VALUE inline."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n"
    (cmacs-scratchpad-eval-block)
    (should (string-match-p "=> 3" (buffer-string)))))

(ert-deftest cmacs-scratchpad-eval-elisp-multiple-forms ()
  "Multiple forms are wrapped in progn; the last value prints."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n(* 3 4)\n"
    (cmacs-scratchpad-eval-block)
    (should (string-match-p "=> 12" (buffer-string)))
    (should-not (string-match-p "=> 3\\b" (buffer-string)))))

(ert-deftest cmacs-scratchpad-eval-elisp-error ()
  "Errors are reported inline instead of signaling."
  (cmacs-scratchpad-tests--with-buffer "(error \"boom\")\n"
    (cmacs-scratchpad-eval-block)
    (should (string-match-p "error:" (buffer-string)))))

(ert-deftest cmacs-scratchpad-reeval-replaces-output ()
  "Re-evaluating a block replaces its output instead of stacking."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n"
    (cmacs-scratchpad-eval-block)
    (cmacs-scratchpad-eval-block)
    (cmacs-scratchpad-eval-block)
    (let ((case-fold-search nil)
          (count 0))
      (goto-char (point-min))
      (while (search-forward "=> 3" nil t)
        (setq count (1+ count)))
      (should (= count 1)))))

(ert-deftest cmacs-scratchpad-output-is-propertized ()
  "Inserted output carries the cmacs-scratchpad-output property."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n"
    (cmacs-scratchpad-eval-block)
    (should (text-property-any (point-min) (point-max)
                               'cmacs-scratchpad-output t))))

(ert-deftest cmacs-scratchpad-clear-output-at-block ()
  "`cmacs-scratchpad-clear-output' removes the block's output."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n"
    (cmacs-scratchpad-eval-block)
    (goto-char (point-min))
    (cmacs-scratchpad-clear-output)
    (should-not (text-property-any (point-min) (point-max)
                                   'cmacs-scratchpad-output t))
    (should (string-match-p "(\\+ 1 2)" (buffer-string)))))

(ert-deftest cmacs-scratchpad-clear-all-output ()
  "A prefix argument clears every output region in the buffer."
  (cmacs-scratchpad-tests--with-buffer "(+ 1 2)\n\n(* 3 4)\n"
    (cmacs-scratchpad-eval-block)
    (goto-char (point-max))
    (search-backward "(* 3 4)")
    (cmacs-scratchpad-eval-block)
    (cmacs-scratchpad-clear-output 'all)
    (should-not (text-property-any (point-min) (point-max)
                                   'cmacs-scratchpad-output t))))

(ert-deftest cmacs-scratchpad-no-block-errors ()
  "Evaluating with no block at point signals a user error."
  (cmacs-scratchpad-tests--with-buffer "\n\n"
    (should-error (cmacs-scratchpad-eval-block) :type 'user-error)))

;;; Auto-enable filter (pure)

(ert-deftest cmacs-scratchpad-maybe-enable-scratch ()
  "*scratch* and Doom scratch buffers get the minor mode."
  (dolist (name '("*scratch*" "*doom:scratch*" "*doom:scratch (proj)*"))
    (with-current-buffer (get-buffer-create name)
      (unwind-protect
          (progn
            (cmacs-scratchpad-mode -1)
            (cmacs-scratchpad-maybe-enable)
            (should cmacs-scratchpad-mode))
        (kill-buffer)))))

(ert-deftest cmacs-scratchpad-maybe-enable-other-buffers ()
  "Ordinary buffers do not get the minor mode."
  (dolist (name '("foo.el" "*Messages*" "scratch"))
    (with-current-buffer (get-buffer-create (concat " cmacs-test-" name))
      (unwind-protect
          (progn
            (cmacs-scratchpad-mode -1)
            (cmacs-scratchpad-maybe-enable)
            (should-not cmacs-scratchpad-mode))
        (kill-buffer)))))

;;; Crispy / bacon block eval (needs built binary)

(ert-deftest cmacs-scratchpad-eval-crispy-block ()
  "A %crispy block executes C and inserts its output."
  (skip-unless (fboundp 'crispy-repl-eval-string))
  (cmacs-scratchpad-tests--with-buffer
      "%crispy\ng_print(\"scratch-crispy\\n\");\n"
    (forward-line 1)
    (cmacs-scratchpad-eval-block)
    (should (string-match-p "scratch-crispy" (buffer-string)))))

(ert-deftest cmacs-scratchpad-eval-bacon-block-fallback ()
  "A %bacon block falls back to the shell when bacon is not running."
  (cmacs-scratchpad-tests--with-buffer
      "%bacon\necho scratch-bacon\n"
    (forward-line 1)
    (cmacs-scratchpad-eval-block)
    (should (string-match-p "scratch-bacon" (buffer-string)))))

(provide 'cmacs-scratchpad-tests)
;;; cmacs-scratchpad-tests.el ends here
