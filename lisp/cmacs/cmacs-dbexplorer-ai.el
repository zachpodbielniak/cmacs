;;; cmacs-dbexplorer-ai.el --- AI actions for the database explorer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The right-click AI menu for database buffers, in the same shape mail
;; and git already have: resolvers that describe what is under the
;; pointer, and a `database' action group that only appears where it
;; applies.
;;
;; The distinction the resolvers exist to make is that a database buffer
;; has several different things under the pointer -- a cell, a row, a
;; result set, a table in a tree, a statement in an editor -- and an
;; action wants a different one of them each time.  "Explain this table"
;; wants the schema; "summarize these results" wants the rows;
;; "optimize this query" wants the SQL and the indexes.  Resolving that
;; once, here, keeps every action from re-deriving it.
;;
;; The tool-enabled actions are handed the READ-ONLY tool set.  A model
;; helping write a query should be able to read your schema, check its
;; work with EXPLAIN, and sample a few rows -- and should not be able to
;; decide that running it is the helpful next step.  `db-execute' is
;; absent from that list on purpose, and `cmacs-dbexplorer-ai-allow-execute'
;; is what a user flips if they disagree.

;;; Code:

(require 'cmacs-dbexplorer-model)
(require 'subr-x)

(declare-function cmacs-ai-register-target-resolver "cmacs-ai-target" (&rest plist))
(declare-function cmacs-ai-target-create "cmacs-ai-target" (&rest args))
(declare-function cmacs-ai-target-kind "cmacs-ai-target" (target))
(declare-function cmacs-ai-target-text "cmacs-ai-target" (target))
(declare-function cmacs-ai-target-buffer "cmacs-ai-target" (target))
(declare-function cmacs-ai-target-plist-get "cmacs-ai-target" (target key))
(declare-function cmacs-ai-register-action "cmacs-ai-actions" (&rest plist))
(declare-function cmacs-ai-call "cmacs-ai-call" (prompt &rest options))
(declare-function cmacs-dbexplorer-result-at-point "cmacs-dbexplorer-grid" ())
(declare-function cmacs-dbexplorer-cell-at-point "cmacs-dbexplorer-grid" ())
(declare-function cmacs-dbexplorer-node-at-point "cmacs-dbexplorer-schema-ui" ())
(declare-function cmacs-dbexplorer-buffer-connection "cmacs-dbexplorer" ())
(declare-function cmacs-dbexplorer-statement-at-point "cmacs-dbexplorer-sql" ())
(declare-function cmacs-dbexplorer-insert-sql "cmacs-dbexplorer-sql" (sql))

(defvar cmacs-ai-action-groups)


;;;; Options ------------------------------------------------------------

(defcustom cmacs-dbexplorer-ai-allow-execute nil
  "Whether AI actions may run statements that change the database.

Off by default, and the default is the point.  The actions here exist to
help you write SQL, and an assistant that can also run it will
occasionally decide that running it is what you meant -- against whichever
database happens to be connected.  Turning this on hands `db-execute' to
the model; the per-connection read-only flag still applies underneath, so
the safe habit is to leave this off and mark production read-only anyway."
  :type 'boolean
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-ai-model nil
  "Model for database AI actions, or nil for the cmacs-ai default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-dbexplorer)


;;;; Context ------------------------------------------------------------

(defun cmacs-dbexplorer-ai--available-p ()
  "Non-nil when both the explorer and cmacs-ai are usable."
  (and (cmacs-dbexplorer-available-p)
       (featurep 'cmacs-ai-actions)
       (fboundp 'cmacs-ai-call)))

(defun cmacs-dbexplorer-ai--tools ()
  "Return the tool names these actions may use.

Read-only unless the user has said otherwise.  Names match the
`cmacs-brigade-deftool' registrations in cmacs-dbexplorer-tools.el."
  (append '("db-connections" "db-tables" "db-columns" "db-query")
          (when cmacs-dbexplorer-ai-allow-execute '("db-execute"))))

(defun cmacs-dbexplorer-ai--schema-context (target)
  "Return a short description of the database behind TARGET, or nil.

Enough for the model to know which connection and dialect it is writing
for; the rest it can fetch through the tools, which is cheaper than
pasting a whole schema into every prompt."
  (when-let* ((name (cmacs-ai-target-plist-get target :db-connection)))
    (let ((connection (cmacs-dbexplorer-connection name)))
      (concat
       (format "Database connection: %s" name)
       (when connection
         (format " (%s%s)"
                 (or (cmacs-dbexplorer-connection-dialect connection) "unknown")
                 (if (cmacs-dbexplorer-connection-read-only connection)
                     ", read-only" "")))
       (when-let* ((table (cmacs-ai-target-plist-get target :db-table)))
         (format "\nTable in view: %s" table))
       "\n\nUse the db-tables and db-columns tools to look up anything you"
       " need rather than guessing at column names."))))

(defun cmacs-dbexplorer-ai--run (target prompt &optional heading)
  "Ask the model PROMPT about TARGET, showing the reply under HEADING."
  (let ((context (cmacs-dbexplorer-ai--schema-context target)))
    (cmacs-ai-call
     (concat (when context (concat context "\n\n")) prompt)
     :tools (cmacs-dbexplorer-ai--tools)
     :model cmacs-dbexplorer-ai-model
     :title (or heading "Database"))))


;;;; Target resolvers ---------------------------------------------------

;; Resolvers describe, they never act.  Anything that needs to run
;; something is an action below.

(with-eval-after-load 'cmacs-ai-target

  (cmacs-ai-register-target-resolver
   :name 'dbexplorer-grid :order 20
   :modes '(cmacs-dbexplorer-grid-mode)
   :resolve
   (lambda (_click)
     (when (fboundp 'cmacs-dbexplorer-result-at-point)
       (when-let* ((result (cmacs-dbexplorer-result-at-point)))
         (cmacs-ai-target-create
          :kind 'db-result
          :label (format "%d rows" (cmacs-dbexplorer-result-row-count result))
          ;; The rendered rows rather than the buffer text: the buffer
          ;; carries alignment padding and staging markers, which are
          ;; display and would only mislead a reader.
          :text (cmacs-dbexplorer-ai--render-result result)
          :buffer (current-buffer)
          :lang "database results"
          :plist (list :db-connection (cmacs-dbexplorer-result-connection-name result)
                       :db-table (cmacs-dbexplorer-result-table result)
                       :db-sql (cmacs-dbexplorer-result-sql result)
                       :db-result result))))))

  (cmacs-ai-register-target-resolver
   :name 'dbexplorer-schema :order 20
   :modes '(cmacs-dbexplorer-schema-mode)
   :resolve
   (lambda (_click)
     (when (fboundp 'cmacs-dbexplorer-node-at-point)
       (when-let* ((node (cmacs-dbexplorer-node-at-point)))
         (cmacs-ai-target-create
          :kind 'db-schema
          :label (or (plist-get node :name) "schema")
          :text (format "%s" node)
          :buffer (current-buffer)
          :lang "database schema"
          :plist (list :db-connection (plist-get node :connection)
                       :db-table (plist-get node :table)
                       :db-node node))))))

  (cmacs-ai-register-target-resolver
   :name 'dbexplorer-sql :order 20
   :modes '(cmacs-dbexplorer-sql-mode)
   :resolve
   (lambda (_click)
     (let ((sql (if (use-region-p)
                    (buffer-substring-no-properties (region-beginning) (region-end))
                  (and (fboundp 'cmacs-dbexplorer-statement-at-point)
                       (cmacs-dbexplorer-statement-at-point)))))
       (when (and sql (not (string-blank-p sql)))
         (cmacs-ai-target-create
          :kind 'db-sql
          :label "SQL"
          :text sql
          :buffer (current-buffer)
          :lang "sql"
          :plist (list :db-connection (and (fboundp 'cmacs-dbexplorer-buffer-connection)
                                           (cmacs-dbexplorer-buffer-connection))
                       :db-sql sql)))))))

(defun cmacs-dbexplorer-ai--render-result (result)
  "Render RESULT as plain delimited text for a prompt."
  (let ((columns (cmacs-dbexplorer-result-column-names result))
        (rows (append (cmacs-dbexplorer-result-rows result) nil)))
    (mapconcat
     #'identity
     (cons (mapconcat #'identity columns " | ")
           (mapcar (lambda (row)
                     (mapconcat (lambda (cell)
                                  (cmacs-dbexplorer-cell-display cell "NULL"))
                                (append row nil) " | "))
                   ;; A prompt does not need a thousand rows to show a
                   ;; shape, and the rest is budget spent for nothing.
                   (seq-take rows 50)))
     "\n")))


;;;; Actions ------------------------------------------------------------

(defun cmacs-dbexplorer-ai--db-target-p (target)
  "Non-nil when TARGET came from a database buffer."
  (and (cmacs-dbexplorer-ai--available-p)
       (memq (cmacs-ai-target-kind target) '(db-result db-schema db-sql))))

(defun cmacs-dbexplorer-ai--sql-target-p (target)
  "Non-nil when TARGET is SQL we can reason about."
  (and (cmacs-dbexplorer-ai--available-p)
       (memq (cmacs-ai-target-kind target) '(db-sql db-result))
       (cmacs-ai-target-plist-get target :db-sql)))

(with-eval-after-load 'cmacs-ai-actions

  ;; A domain group, so these appear only in database buffers and cost
  ;; nothing anywhere else.
  (unless (assq 'database cmacs-ai-action-groups)
    (setq cmacs-ai-action-groups
          (append cmacs-ai-action-groups '((database . "Database")))))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-write-query
   :group 'database :order 10
   :label "Help me write a query..."
   :help "Describe what you want; the model reads your schema and writes SQL"
   :applies #'cmacs-dbexplorer-ai--db-target-p
   :run
   (lambda (target)
     (let ((want (read-string "What should the query return? ")))
       (cmacs-dbexplorer-ai--run
        target
        (concat "Write a single SQL query for this database that returns: "
                want
                "\n\nLook up the tables and columns with the tools before"
                " writing it, and check it with EXPLAIN if that is cheap."
                " Reply with the query and a one-line explanation of what"
                " it does. Do not run it.")
        "Query"))))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-do
   :group 'database :order 20
   :label "Help me do..."
   :help "Free-form: ask for anything about this database"
   :applies #'cmacs-dbexplorer-ai--db-target-p
   :run
   (lambda (target)
     (let ((want (read-string "What do you want to do? ")))
       (cmacs-dbexplorer-ai--run target want "Database"))))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-explain-query
   :group 'database :order 30
   :label "Explain this query"
   :applies #'cmacs-dbexplorer-ai--sql-target-p
   :run
   (lambda (target)
     (cmacs-dbexplorer-ai--run
      target
      (concat "Explain what this SQL does, in plain prose, for someone who"
              " knows SQL but not this schema:\n\n"
              (or (cmacs-ai-target-plist-get target :db-sql)
                  (cmacs-ai-target-text target)))
      "Explain query")))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-optimize-query
   :group 'database :order 40
   :label "Optimize this query"
   :applies #'cmacs-dbexplorer-ai--sql-target-p
   :run
   (lambda (target)
     (cmacs-dbexplorer-ai--run
      target
      (concat "Suggest how to make this query faster. Run EXPLAIN on it and"
              " look at the indexes on the tables it touches before"
              " answering, and say which of your suggestions you actually"
              " verified:\n\n"
              (or (cmacs-ai-target-plist-get target :db-sql)
                  (cmacs-ai-target-text target)))
      "Optimize query")))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-suggest-indexes
   :group 'database :order 50
   :label "Suggest indexes for this query"
   :applies #'cmacs-dbexplorer-ai--sql-target-p
   :run
   (lambda (target)
     (cmacs-dbexplorer-ai--run
      target
      (concat "What indexes would help this query? List the existing ones"
              " first so it is clear what is missing rather than duplicated,"
              " and give the CREATE INDEX statements. Do not run them:\n\n"
              (or (cmacs-ai-target-plist-get target :db-sql)
                  (cmacs-ai-target-text target)))
      "Indexes")))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-explain-table
   :group 'database :order 60
   :label "Explain this table"
   :applies
   (lambda (target)
     (and (cmacs-dbexplorer-ai--db-target-p target)
          (cmacs-ai-target-plist-get target :db-table)))
   :run
   (lambda (target)
     (cmacs-dbexplorer-ai--run
      target
      (format (concat "Describe the table %s: what it appears to hold, what"
                      " its columns mean, its key, and how it relates to"
                      " other tables. Look it up with the tools.")
              (cmacs-ai-target-plist-get target :db-table))
      "Table")))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-summarize-results
   :group 'database :order 70
   :label "Summarize these results"
   :applies
   (lambda (target)
     (and (cmacs-dbexplorer-ai--available-p)
          (eq (cmacs-ai-target-kind target) 'db-result)))
   :run
   (lambda (target)
     (cmacs-dbexplorer-ai--run
      target
      (concat "Summarize what these query results show. Point out anything"
              " that looks anomalous:\n\n" (cmacs-ai-target-text target))
      "Summary")))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-test-data
   :group 'database :order 80
   :label "Generate test data..."
   :applies
   (lambda (target)
     (and (cmacs-dbexplorer-ai--db-target-p target)
          (cmacs-ai-target-plist-get target :db-table)))
   :run
   (lambda (target)
     (let ((n (read-number "How many rows? " 10)))
       (cmacs-dbexplorer-ai--run
        target
        (format (concat "Write %d INSERT statements of plausible test data"
                        " for the table %s. Look up its columns and"
                        " constraints first so the rows will actually"
                        " insert. Reply with only the SQL. Do not run it.")
                n (cmacs-ai-target-plist-get target :db-table))
        "Test data"))))

  (cmacs-ai-register-action
   :name 'cmacs-dbexplorer-ai-document-schema
   :group 'database :order 90
   :label "Document this schema"
   :applies #'cmacs-dbexplorer-ai--db-target-p
   :run
   (lambda (target)
     (cmacs-dbexplorer-ai--run
      target
      (concat "Write org-mode documentation for this database: a short"
              " overview, then a section per table covering its purpose,"
              " its columns and its relationships. Use the tools to read"
              " the real schema.")
      "Schema documentation"))))

(provide 'cmacs-dbexplorer-ai)
;;; cmacs-dbexplorer-ai.el ends here
