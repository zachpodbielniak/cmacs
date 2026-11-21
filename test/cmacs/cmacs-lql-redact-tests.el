;;; cmacs-lql-redact-tests.el --- ERT tests: LQL sources as a model sees them  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An agent can read the editor-state sources (`buffers', `kill_ring',
;; `notes', ...) through any tool that runs a query.  The rows are put
;; through the user's privacy rules at the snapshot, which is plain
;; Elisp: these tests take snapshots and read the JSON, and the engine
;; is never called.  Sources live in a private registry and a private
;; cache for the length of a test, and the rule set is the test's own.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'warnings)
(require 'cmacs-redact)
(require 'cmacs-lql)
(require 'cmacs-lql-notes nil t)

(defvar recentf-list)

(defmacro cmacs-lql-redact-tests--with (rules &rest body)
  "Run BODY with RULES as the rule set, an empty registry, and no engine.
Inside BODY the caller is the user; see `cmacs-lql-redact-tests--model'."
  (declare (indent 1) (debug t))
  `(let* ((cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters ,rules)
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter--signature nil)
          (cmacs-journal-filter-case-fold t)
          (cmacs-journal-filter-hash-key "test-key-0123456789abcdef0123456789")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-redact-mode t)
          (cmacs-redact-surfaces '(tool rpc prompt))
          (cmacs-redact-text-field-rules t)
          (cmacs-redact--as-model nil)
          (cmacs-redact--in-tool-call nil)
          (cmacs-redact--pending nil)
          (cmacs-redact--last-check (+ (float-time) 3600.0))
          (inhibit-interaction nil)
          (cmacs-lql--sources (make-hash-table :test #'equal))
          (cmacs-lql--snapshot-cache (make-hash-table :test #'equal))
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency)
          (inhibit-message t))
     (cl-letf (((symbol-function 'cmacs-lql-available-p) #'ignore))
       (cmacs-journal-filters-reload)
       ,@body)))

(defmacro cmacs-lql-redact-tests--model (&rest body)
  "Run BODY as a brigade tool call would run it."
  (declare (indent 0) (debug t))
  `(let ((cmacs-redact--in-tool-call t)) ,@body))

(defun cmacs-lql-redact-tests--rows (name)
  "The snapshot of source NAME, parsed: a list of alists."
  (json-parse-string (cmacs-lql--snapshot name)
                     :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defun cmacs-lql-redact-tests--column (name column)
  "The values of COLUMN (a symbol) in the snapshot of source NAME."
  (mapcar (lambda (row) (alist-get column row))
          (cmacs-lql-redact-tests--rows name)))

;;;; Roles

(ert-deftest cmacs-lql-redact-test-the-users-own-query-is-untouched ()
  (cmacs-lql-redact-tests--with
      '((:match ((:file . "\\.gpg\\'")) :exclude t)
        (:match ((:text . "secret")) :replace ((:text "secret" "_"))))
    (cmacs-lql-define-source
     "t_files" '(("file" string) ("note" string))
     (lambda () '((:file "/x/a.gpg" :note "a secret")
                  (:file "/x/b.txt" :note "plain")))
     nil '(("file" . file) ("note" . text)))
    (should (equal (cmacs-lql-redact-tests--column "t_files" 'file)
                   '("/x/a.gpg" "/x/b.txt")))
    (should (equal (cmacs-lql-redact-tests--column "t_files" 'note)
                   '("a secret" "plain")))
    (cmacs-lql-redact-tests--model
      (should (equal (cmacs-lql-redact-tests--column "t_files" 'file)
                     '("/x/b.txt"))))))

(ert-deftest cmacs-lql-redact-test-file-url-and-text-roles ()
  (cmacs-lql-redact-tests--with
      '((:match ((:file . "/hidden/")) :exclude t)
        (:match ((:file . "/clients/"))
         :replace ((:file "/clients/[^/]+" "/clients/_")))
        (:match ((:url . "bank\\.example")) :exclude t)
        (:match ((:text . "sk-[a-z0-9]+"))
         :replace ((:text "sk-[a-z0-9]+" "[key]"))))
    (cmacs-lql-define-source
     "t_mixed"
     '(("file" string) ("dir" string) ("url" string) ("text" string)
       ("tags" array) ("kind" string) ("n" int))
     (lambda ()
       '((:file "/hidden/a" :dir "/hidden/" :kind "sk-keep" :n 1)
         (:file "/clients/acme/n.org" :dir "/clients/acme/" :text "sk-abc1"
          :tags ("sk-tag9" "ok") :kind "sk-keep" :n 2)
         (:file "/plain/p.org" :dir "/plain/" :url "https://bank.example/"
          :n 3)
         (:file "/plain/q.org" :dir "/plain/" :url "https://example.org/"
          :text "fine" :kind "sk-keep" :n 4)))
     nil
     '(("file" . file) ("dir" . derived) ("url" . url) ("text" . text)
       ("tags" . text) ("kind" . plain)))
    (cmacs-lql-redact-tests--model
      (let ((rows (cmacs-lql-redact-tests--rows "t_mixed")))
        ;; The hidden file and the bank URL are not rows at all.
        (should (equal (mapcar (lambda (r) (alist-get 'n r)) rows) '(2 4)))
        (let ((client (car rows)) (plain (cadr rows)))
          (should (equal (alist-get 'file client) "/clients/_/n.org"))
          ;; Rewritten file: what was derived from it is blanked.
          (should-not (alist-get 'dir client))
          (should (equal (alist-get 'text client) "[key]"))
          (should (equal (alist-get 'tags client) '("[key]" "ok")))
          ;; `plain' is shown as it is, even when a text rule matches.
          (should (equal (alist-get 'kind client) "sk-keep"))
          ;; Untouched file: its directory stays.
          (should (equal (alist-get 'dir plain) "/plain/"))
          (should (equal (alist-get 'url plain) "https://example.org/")))))))

(ert-deftest cmacs-lql-redact-test-window-and-buffer-roles ()
  (cmacs-lql-redact-tests--with
      '((:match ((:app . "keepass")) :exclude t)
        (:match ((:title . "Invoice")) :replace ((:title "[0-9]+" "#")))
        (:match ((:buffer . "\\`\\*vault")) :exclude t))
    (cmacs-lql-define-source
     "t_wins" '(("app_id" string) ("title" string) ("pid" int))
     (lambda () '((:app_id "keepassxc" :title "Vault" :pid 5)
                  (:app_id "evince" :title "Invoice 778" :pid 6)))
     nil '(("app_id" . app) ("title" . title) ("pid" . pid)))
    (cmacs-lql-define-source
     "t_bufs" '(("name" string))
     (lambda () '((:name "*vault of things*") (:name "no-such-buffer-xyz")))
     nil '(("name" . buffer)))
    (cmacs-lql-redact-tests--model
      (should (equal (cmacs-lql-redact-tests--rows "t_wins")
                     '(((app_id . "evince") (title . "Invoice #") (pid . 6)))))
      (should (equal (cmacs-lql-redact-tests--column "t_bufs" 'name)
                     '("no-such-buffer-xyz"))))))

(ert-deftest cmacs-lql-redact-test-an-undeclared-source-is-all-free-text ()
  "A source that says nothing about its columns: every string is text."
  (cmacs-lql-redact-tests--with
      '((:match ((:text . "hunter2")) :replace ((:text "hunter2" "_")))
        (:match ((:title . "Invoice")) :replace ((:title "[0-9]\\{6,\\}" "***"))))
    (cmacs-lql-define-source
     "t_plain" '(("a" string) ("n" int) ("l" array))
     (lambda () '(((a . "pw hunter2") (n . 7) (l . ("acct 12345678")))
                  (:a "ok" :n 8 :extra "hunter2 again"))))
    (cmacs-lql-redact-tests--model
      (should (equal (cmacs-lql-redact-tests--rows "t_plain")
                     '(((a . "pw _") (n . 7) (l "acct ***"))
                       ((a . "ok") (n . 8) (extra . "_ again"))))))))

(ert-deftest cmacs-lql-redact-test-a-function-or-none-is-honoured ()
  (cmacs-lql-redact-tests--with
      '((:match ((:text . "x")) :replace ((:text "x" "y"))))
    (cmacs-lql-define-source
     "t_fn" '(("a" string)) (lambda () '((:a "x1") (:a "x2")))
     nil (lambda (rows) (list (car rows))))
    (cmacs-lql-define-source
     "t_none" '(("a" string)) (lambda () '((:a "x1"))) nil 'none)
    (should-error (cmacs-lql-set-source-redaction "t_fn" '(("a" . nonsense))))
    (should-error (cmacs-lql-set-source-redaction "nope" nil))
    (cmacs-lql-redact-tests--model
      (should (equal (cmacs-lql-redact-tests--column "t_fn" 'a) '("x1")))
      (should (equal (cmacs-lql-redact-tests--column "t_none" 'a) '("x1")))
      ;; A redactor that breaks leaves a model nothing, not everything.
      (cmacs-lql-set-source-redaction "t_fn" (lambda (_) (error "boom")))
      (should-not (cmacs-lql-redact-tests--rows "t_fn")))
    (should (= 2 (length (cmacs-lql-redact-tests--rows "t_fn"))))))

;;;; Fail closed

(ert-deftest cmacs-lql-redact-test-unusable-rules-mean-no-rows-for-a-model ()
  (cmacs-lql-redact-tests--with
      '((:match ((:app . "\\(unbalanced")) :exclude t))
    (should-not (cmacs-journal-filter-ready-p))
    (cmacs-lql-define-source
     "t_a" '(("a" string)) (lambda () '((:a "one"))) nil '(("a" . plain)))
    (cmacs-lql-define-source
     "t_b" '(("a" string)) (lambda () '((:a "one"))) nil 'none)
    (cmacs-lql-redact-tests--model
      (should (equal (cmacs-lql--snapshot "t_a") "[]"))
      (should (equal (cmacs-lql--snapshot "t_b") "[]")))
    ;; The user still sees their own data.
    (should (equal (cmacs-lql-redact-tests--column "t_a" 'a) '("one")))))

;;;; The cache

(ert-deftest cmacs-lql-redact-test-snapshots-never-share-a-cache-entry ()
  "A snapshot made for the user is never the one handed to a model."
  (cmacs-lql-redact-tests--with
      '((:match ((:file . "\\.gpg\\'")) :exclude t))
    (let ((calls 0))
      (cmacs-lql-define-source
       "t_cached" '(("file" string))
       (lambda () (setq calls (1+ calls))
         '((:file "/x/a.gpg") (:file "/x/b.txt")))
       nil '(("file" . file)))
      ;; A generation that never changes: only who asks can.
      (cmacs-lql-set-source-generation "t_cached" (lambda () 'same))
      (let* ((mine (cmacs-lql--snapshot "t_cached"))
             (theirs (cmacs-lql-redact-tests--model
                       (cmacs-lql--snapshot "t_cached"))))
        (should (string-match-p "a\\.gpg" mine))
        (should-not (string-match-p "a\\.gpg" theirs))
        (should (= calls 2))
        ;; Both are cached, each under its own entry, in either order.
        (should (eq (cmacs-lql--snapshot "t_cached") mine))
        (should (eq (cmacs-lql-redact-tests--model
                      (cmacs-lql--snapshot "t_cached"))
                    theirs))
        (should (eq (cmacs-lql--snapshot "t_cached") mine))
        (should (= calls 2))
        (should (= (hash-table-count cmacs-lql--snapshot-cache) 2))
        (let ((user (gethash '("t_cached" . nil) cmacs-lql--snapshot-cache))
              (model (gethash '("t_cached" . t) cmacs-lql--snapshot-cache)))
          (should (eq (cdr user) mine))
          (should (eq (cdr model) theirs))
          ;; Nor do they share a generation.
          (should-not (equal (car user) (car model))))
        ;; No entry anywhere in the cache for a model holds the row.
        (maphash (lambda (slot entry)
                   (when (cdr slot)
                     (should-not (string-match-p "a\\.gpg" (cdr entry)))))
                 cmacs-lql--snapshot-cache)
        ;; Every signal that makes a caller model-facing gets `theirs'.
        (let ((inhibit-interaction t))
          (should (eq (cmacs-lql--snapshot "t_cached") theirs)))
        (cmacs-redact-as-model
          (should (eq (cmacs-lql--snapshot "t_cached") theirs)))))))

(ert-deftest cmacs-lql-redact-test-a-change-of-rules-is-a-new-snapshot ()
  (cmacs-lql-redact-tests--with
      '((:match ((:file . "\\.gpg\\'")) :exclude t))
    (cmacs-lql-define-source
     "t_cached" '(("file" string))
     (lambda () '((:file "/x/a.gpg") (:file "/x/b.txt")))
     nil '(("file" . file)))
    (cmacs-lql-set-source-generation "t_cached" (lambda () 'same))
    (cmacs-lql-redact-tests--model
      (should (equal (cmacs-lql-redact-tests--column "t_cached" 'file)
                     '("/x/b.txt")))
      (setq cmacs-journal-filters '((:match ((:file . "\\.txt\\'")) :exclude t)))
      (cmacs-journal-filters-reload)
      (should (equal (cmacs-lql-redact-tests--column "t_cached" 'file)
                     '("/x/a.gpg")))
      ;; Rules that stop loading: the cached rows are not served on.
      (setq cmacs-journal-filters '((:match ((:app . "\\(")) :exclude t)))
      (cmacs-journal-filters-reload)
      (should (equal (cmacs-lql--snapshot "t_cached") "[]")))
    ;; Turning the mode off is the user's view, from the user's entry.
    (let ((cmacs-redact-mode nil) (cmacs-redact--in-tool-call t))
      (should (= 2 (length (cmacs-lql-redact-tests--rows "t_cached")))))))

;;;; The shipped sources

(ert-deftest cmacs-lql-redact-test-shipped-sources-hide-what-the-rules-hide ()
  (cmacs-lql-redact-tests--with
      '((:match ((:file . "\\.gpg\\'")) :exclude t)
        (:match ((:app . "keepass")) :exclude t)
        (:match ((:text . "hunter2")) :replace ((:text "hunter2" "_"))))
    (cmacs-lql--define-shipped-sources)
    (let ((secret (generate-new-buffer "lql-redact-keys"))
          (plain (generate-new-buffer "lql-redact-plain"))
          (kill-ring '("password is hunter2" "nothing"))
          (recentf-list '("/x/keys.gpg" "/x/main.c")))
      (unwind-protect
          (cl-letf (((symbol-function 'gowl-list-clients)
                     (lambda (&rest _) '(c1 c2)))
                    ((symbol-function 'gowl-client-info)
                     (lambda (c &rest _)
                       (if (eq c 'c1)
                           '((app-id . "keepassxc") (title . "Vault"))
                         '((app-id . "foot") (title . "sh")))))
                    ((symbol-function 'gowl-client-pid) (lambda (&rest _) 9)))
            (with-current-buffer secret (setq buffer-file-name "/x/keys.gpg"))
            (with-current-buffer plain (setq buffer-file-name "/x/main.c"))
            (cmacs-lql-define-source
             "gowl_clients"
             '(("client" any) ("app_id" string) ("title" string) ("pid" int))
             #'cmacs-lql--gowl-client-rows nil
             '(("app_id" . app) ("title" . title) ("pid" . pid)
               ("client" . text)))
            ;; The user sees all of it.
            (should (member "lql-redact-keys"
                            (cmacs-lql-redact-tests--column "buffers" 'name)))
            (cmacs-lql-redact-tests--model
              (let ((names (cmacs-lql-redact-tests--column "buffers" 'name)))
                (should (member "lql-redact-plain" names))
                (should-not (member "lql-redact-keys" names)))
              (should (equal (cmacs-lql-redact-tests--column "kill_ring" 'text)
                             '("password is _" "nothing")))
              (should (equal (cmacs-lql-redact-tests--column "recentf" 'file)
                             '("/x/main.c")))
              (should (equal (cmacs-lql-redact-tests--column "gowl_clients"
                                                             'app_id)
                             '("foot")))
              ;; A window showing the hidden buffer is not a row either.
              (save-window-excursion
                (switch-to-buffer secret)
                (should-not (member "lql-redact-keys"
                                    (cmacs-lql-redact-tests--column
                                     "windows" 'buffer))))))
        (dolist (b (list secret plain))
          (with-current-buffer b
            (setq buffer-file-name nil) (set-buffer-modified-p nil))
          (kill-buffer b))))))

(ert-deftest cmacs-lql-redact-test-every-shipped-source-declares-its-columns ()
  "A new shipped source must say what its columns are."
  (cmacs-lql-redact-tests--with nil
    (cmacs-lql--define-shipped-sources)
    (when (fboundp 'cmacs-lql-notes-define-sources)
      (cmacs-lql-notes-define-sources))
    (should (> (hash-table-count cmacs-lql--sources) 6))
    (maphash
     (lambda (name spec)
       (ert-info ((format "source %s" name))
         (let ((redaction (plist-get spec :redaction)))
           (should redaction)
           (when (and (listp redaction) (not (functionp redaction)))
             ;; Every declared column exists.
             (dolist (cell redaction)
               (should (assoc (car cell) (plist-get spec :columns))))
             ;; Every string column is declared, not left to the default.
             (pcase-dolist (`(,column . ,type) (plist-get spec :columns))
               (when (eq type 'string)
                 (should (assoc column redaction))))))))
     cmacs-lql--sources)))

(ert-deftest cmacs-lql-redact-test-notes-rows-follow-the-file ()
  (skip-unless (fboundp 'cmacs-lql-notes-define-sources))
  (cmacs-lql-redact-tests--with
      '((:match ((:file . "/private/")) :exclude t)
        (:match ((:file . "/clients/")) :hash (:file)))
    (cmacs-lql-notes-define-sources)
    (puthash "notes"
             (plist-put (plist-put (gethash "notes" cmacs-lql--sources)
                                   :function
                                   (lambda ()
                                     '((:file "/n/private/a.org" :path "private/a.org" :title "A")
                                       (:file "/n/clients/b.org" :path "clients/b.org" :name "b" :para "areas" :title "B")
                                       (:file "/n/c.org" :path "c.org" :name "c" :para "inbox" :title "C"))))
                        :generation nil)
             cmacs-lql--sources)
    (cmacs-lql-redact-tests--model
      (let ((rows (cmacs-lql-redact-tests--rows "notes")))
        (should (equal (mapcar (lambda (r) (alist-get 'title r)) rows)
                       '("B" "C")))
        (should (string-prefix-p "#" (alist-get 'file (car rows))))
        (should-not (alist-get 'path (car rows)))
        (should-not (alist-get 'name (car rows)))
        (should (equal (alist-get 'path (cadr rows)) "c.org"))
        (should (equal (alist-get 'para (cadr rows)) "inbox"))))))

(provide 'cmacs-lql-redact-tests)

;;; cmacs-lql-redact-tests.el ends here
