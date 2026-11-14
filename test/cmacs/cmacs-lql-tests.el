;;; cmacs-lql-tests.el --- ERT tests for the LQL subsystem  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Covers cmacs-lql.el and its C primitives: defining Elisp sources and
;; snapshotting them into a query, the async and sync run paths, the
;; result JSON, the editor helpers (completion, hover, explain,
;; format), the environment file the language server reads, the eglot
;; contact, the results grid and the REPL.
;;
;; The value conversion is pure Elisp and runs on any build; everything
;; that runs a query skips without `cmacs-lql--run'.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-lql-tests

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'cmacs-lql nil 'noerror)
(require 'cmacs-lql-results nil 'noerror)
(require 'cmacs-lql-repl nil 'noerror)

(defvar cmacs-lql-environment-file)
(defvar eglot-server-programs)

(defmacro cmacs-lql-tests--with-source (name columns rows &rest body)
  "Define source NAME with COLUMNS returning ROWS, run BODY, forget it."
  (declare (indent 3))
  `(unwind-protect
       (progn (cmacs-lql-define-source ,name ,columns (lambda () ,rows))
              ,@body)
     (remhash ,name cmacs-lql--sources)))

;;;; Pure Elisp

(ert-deftest cmacs-lql-json-value-conversion ()
  "Lisp values become JSON the way a column's type says."
  (skip-unless (fboundp 'cmacs-lql--json-value))
  (should (eq (cmacs-lql--json-value nil 'boolean) :false))
  (should (eq (cmacs-lql--json-value nil 'string) :null))
  (should (eq (cmacs-lql--json-value t 'boolean) t))
  (should (equal (cmacs-lql--json-value '(1 2) 'array) [1 2]))
  (should (equal (cmacs-lql--json-value 'foo 'string) "foo"))
  (should (equal (cmacs-lql--json-value (propertize "x" 'face 'bold) 'string) "x"))
  (should (equal (cmacs-lql--json-value '(:a 1) 'record) '((a . 1))))
  (should (numberp (cmacs-lql--json-value (current-time) 'timestamp))))

(ert-deftest cmacs-lql-row-object-plist-and-alist ()
  "A row may be a plist or an alist; both serialise the same."
  (skip-unless (fboundp 'cmacs-lql--row-object))
  (let ((cols '(("a" . int) ("b" . boolean))))
    (should (equal (cmacs-lql--row-object '(:a 1 :b nil) cols)
                   '((a . 1) (b . :false))))
    (should (equal (cmacs-lql--row-object '(("a" . 1) ("b" . t)) cols)
                   '((a . 1) (b . t))))))

(ert-deftest cmacs-lql-define-source-validates ()
  "Bad names and unknown types are refused up front."
  (skip-unless (fboundp 'cmacs-lql-define-source))
  (should-error (cmacs-lql-define-source "bad name" nil #'ignore))
  (should-error (cmacs-lql-define-source "ok_name" '(("c" nosuchtype)) #'ignore)))

(ert-deftest cmacs-lql-referenced-sources-whole-symbols ()
  "Only whole-symbol mentions of a source trigger its snapshot."
  (skip-unless (fboundp 'cmacs-lql--referenced-sources))
  (let ((cmacs-lql--sources (make-hash-table :test #'equal)))
    (puthash "buffers" '(:columns nil) cmacs-lql--sources)
    (should (equal (cmacs-lql--referenced-sources "fetch buffers | limit 1")
                   '("buffers")))
    (should-not (cmacs-lql--referenced-sources "fetch my_buffers_x"))))

(ert-deftest cmacs-lql-query-at-point-blocks ()
  "The query at point is the blank-line-delimited block."
  (skip-unless (fboundp 'cmacs-lql-query-at-point))
  (with-temp-buffer
    (insert "fetch a\n| limit 1\n\nfetch b\n| limit 2\n")
    (goto-char (point-min))
    (should (equal (cmacs-lql-query-at-point) "fetch a\n| limit 1"))
    (goto-char (point-max))
    (forward-line -1)
    (should (equal (cmacs-lql-query-at-point) "fetch b\n| limit 2"))))

;;;; Queries (need the C primitives)

(ert-deftest cmacs-lql-run-sync-elisp-source ()
  "An Elisp source is snapshotted into the query that names it."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-tests--with-source "ert_numbers" '(("n" int) ("even" boolean))
      (cl-loop for i from 1 to 10 collect (list :n i :even (cl-evenp i)))
    (let* ((p (cmacs-lql-run-sync
               "fetch ert_numbers | filter even | sort n DESC | limit 3"))
           (table (cmacs-lql-payload-table p)))
      (should (eq (car p) :ok))
      (should (equal (mapcar #'car (plist-get table :columns)) '("n" "even")))
      (should (equal (mapcar (lambda (r) (aref r 0)) (plist-get table :rows))
                     '(10 8 6)))
      (should (= (plist-get (cdr p) :rows) 3)))))

(ert-deftest cmacs-lql-run-error-and-max-rows ()
  "A bad query is an :error payload; :max-rows truncates but `total' counts."
  (skip-unless (fboundp 'cmacs-lql--run))
  (should (eq (car (cmacs-lql-run-sync "this is not lql")) :error))
  (cmacs-lql-tests--with-source "ert_many" '(("i" int))
      (cl-loop for i below 50 collect (list :i i))
    (let* ((p (cmacs-lql-run-sync "fetch ert_many" :max-rows 5))
           (table (cmacs-lql-payload-table p)))
      (should (= (length (plist-get table :rows)) 5))
      (should (= (plist-get table :total) 50)))))

(ert-deftest cmacs-lql-run-async-callback ()
  "The callback receives the payload once, on the Lisp thread."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-tests--with-source "ert_one" '(("x" string))
      (list (list :x "hello"))
    (let (got (n 0))
      (cmacs-lql-run "fetch ert_one" (lambda (p) (push p got)) :text-width 40)
      (while (and (null got) (< n 200))
        (accept-process-output nil 0.02)
        (setq n (1+ n)))
      (should (= (length got) 1))
      (should (eq (caar got) :ok))
      (should (string-match-p "hello" (plist-get (cdar got) :text))))))

(ert-deftest cmacs-lql-buffers-source-sees-buffers ()
  "The shipped `buffers' source lists live buffers."
  (skip-unless (fboundp 'cmacs-lql--run))
  (with-temp-buffer
    (rename-buffer "ert-lql-probe" t)
    (let ((name (buffer-name)))
      (let* ((p (cmacs-lql-run-sync
                 (format "fetch buffers | filter name == \"%s\" | fields name, size"
                         name)))
             (rows (plist-get (cmacs-lql-payload-table p) :rows)))
        (should (eq (car p) :ok))
        (should (equal (aref (car rows) 0) name))))))

(ert-deftest cmacs-lql-editor-helpers ()
  "Completion, hover and explain answer from liblql's assist code."
  (skip-unless (fboundp 'cmacs-lql--complete))
  (cmacs-lql-tests--with-source "ert_helper" '(("col_a" string))
      nil
    ;; Let the pending definition land.
    (cmacs-lql-run-sync "fetch ert_helper")
    (should (assoc "ert_helper" (cmacs-lql-completions "fetch ert_h" 11)))
    (should (string-match-p "col_a" (or (cmacs-lql-hover-text "fetch ert_helper" 8) "")))
    (should (stringp (cmacs-lql--explain "fetch ert_helper | limit 1")))
    (should-error (cmacs-lql--explain "fetch") :type 'cmacs-lql-error)))

(ert-deftest cmacs-lql-environment-file-and-eglot-contact ()
  "cmacs writes the environment the server reads, and eglot runs it."
  (skip-unless (fboundp 'cmacs-lql--describe))
  (let* ((dir (make-temp-file "cmacs-lql-env" t))
         (cmacs-lql-environment-file (expand-file-name "env.json" dir)))
    (unwind-protect
        (progn
          (should (equal (cmacs-lql-write-environment) cmacs-lql-environment-file))
          (with-temp-buffer
            (insert-file-contents cmacs-lql-environment-file)
            (should (string-match-p "\"buffers\"" (buffer-string))))
          (let ((contact (cmacs-lql-server-contact)))
            (should (member "--environment" contact))
            (should (member cmacs-lql-environment-file contact))))
      (delete-directory dir t))))

(ert-deftest cmacs-lql-eglot-entry ()
  "Loading eglot points `lql-mode' at cmacs's contact, once."
  (skip-unless (and (fboundp 'cmacs-lql--register-eglot) (require 'eglot nil t)))
  (cmacs-lql--register-eglot)
  (should (eq (alist-get 'lql-mode eglot-server-programs) 'cmacs-lql-server-contact))
  (should (= 1 (cl-count-if (lambda (e) (eq (car-safe e) 'lql-mode))
                            eglot-server-programs))))

;;;; Grid and REPL

(ert-deftest cmacs-lql-results-grid ()
  "A query fills a sortable grid whose rows come back typed."
  (skip-unless (fboundp 'cmacs-lql--run))
  (cmacs-lql-tests--with-source "ert_grid" '(("name" string) ("n" int))
      (list (list :name "b" :n 2) (list :name "a" :n 10) (list :name "c" :n 1))
    (let ((buf (cmacs-lql-results--loading "fetch ert_grid")))
      (unwind-protect
          (with-current-buffer buf
            (let ((i 0))
              (while (and cmacs-lql-results--status (< i 200))
                (accept-process-output nil 0.02) (setq i (1+ i))))
            (should (= (length cmacs-lql-results--rows) 3))
            (goto-char (point-min))
            (should (equal (cdr (assoc "name" (cmacs-lql-results-row-at-point))) "b"))
            (should (string-match-p "| name | n |" (cmacs-lql-results-org-table)))
            ;; Numeric sort uses the typed value, not its text.
            (tabulated-list-sort 1)
            (goto-char (point-min))
            (should (= (cdr (assoc "n" (cmacs-lql-results-row-at-point))) 1)))
        (kill-buffer buf)))))

(ert-deftest cmacs-lql-results-local-refine ()
  "Refining runs LQL over the rows shown, as the `results' source."
  (skip-unless (fboundp 'cmacs-lql--run))
  (with-temp-buffer
    (cmacs-lql-results-mode)
    (setq cmacs-lql-results--columns '(("k" . "String") ("v" . "Int"))
          cmacs-lql-results--rows (list ["x" 1] ["y" 5] ["z" 9]))
    (let ((buf (save-window-excursion (cmacs-lql-results-refine "filter v > 2"))))
      (unwind-protect
          (with-current-buffer buf
            (let ((i 0))
              (while (and cmacs-lql-results--status (< i 200))
                (accept-process-output nil 0.02) (setq i (1+ i))))
            (should (equal (mapcar (lambda (r) (aref r 0)) cmacs-lql-results--rows)
                           '("y" "z"))))
        (kill-buffer buf)))))

(ert-deftest cmacs-lql-repl-evaluates ()
  "The REPL prints a table and a fresh prompt."
  (skip-unless (fboundp 'cmacs-lql--run))
  (save-window-excursion
    (cmacs-lql-repl)
    (let ((buf (get-buffer cmacs-lql-repl-buffer-name)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-max))
            (insert ":sources")
            (comint-send-input)
            (should (string-match-p "buffers" (buffer-string)))
            (goto-char (point-max))
            (insert "fetch kill_ring | limit 1")
            (comint-send-input)
            (let ((i 0))
              (while (and (not (string-match-p "rows?[,)]" (buffer-string))) (< i 200))
                (accept-process-output nil 0.02) (setq i (1+ i))))
            (should (string-match-p "rows?[,)]" (buffer-string))))
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf))))))

(provide 'cmacs-lql-tests)

;;; cmacs-lql-tests.el ends here
