;;; cmacs-dbexplorer-tools.el --- Database explorer as an agent capability  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The database explorer as something other than a keyboard drives.
;;
;; Three surfaces call into this file -- the MCP tool set, the
;; org.cmacs.Editor1.DbExplorer D-Bus interface, and `emacsctl db' -- and
;; they all call the same `cmacs-dbexplorer-tool-*' functions, which
;; return JSON strings.  Keeping one implementation behind three
;; transports is what stops them drifting into three slightly different
;; databases-over-RPC.
;;
;; Two constraints shape the shape of these functions, both taken from
;; the office tool set, and both from ai-glib's tool model: parameters
;; are flat scalars, and a handler returns a string.  So a connection is
;; addressed by its SAVED NAME rather than by a handle or a URL.  A name
;; means a caller cannot invent a database to connect to, cannot supply
;; its own credentials, and cannot hold a handle across calls and act on
;; stale state.
;;
;; The read-only guarantee is not implemented here.  It lives on the
;; C-side connection, so it holds for these functions the same way it
;; holds for the grid, and nothing in this file can weaken it.  What this
;; file adds is a second, narrower limit: `cmacs-dbexplorer-tool-query'
;; is only ever routed through the read path, so even a read-write
;; connection cannot be made to write through it.

;;; Code:

(require 'cmacs-dbexplorer-model)
(require 'json)
(require 'subr-x)

;; Defined in cmacs-dbexplorer.el, which this file must not require: the
;; UI half pulls in the transient and auth-source machinery, and an agent
;; calling a tool should not drag a user interface in behind it.
(defvar cmacs-dbexplorer-connections)

(declare-function cmacs-dbexplorer-connect "cmacs-dbexplorer" (&optional name))
(declare-function cmacs-dbexplorer-disconnect "cmacs-dbexplorer" (&optional name))
(declare-function cmacs-dbexplorer-connection-spec "cmacs-dbexplorer" (name))
(declare-function cmacs-dbexplorer-when-connected "cmacs-dbexplorer" (name function))
(declare-function cmacs-dbexplorer-query "cmacs-dbexplorer"
                  (connection sql &rest keys))
(declare-function cmacs-dbexplorer-execute "cmacs-dbexplorer"
                  (connection sql &rest keys))
(declare-function cmacs-dbexplorer-export-result "cmacs-dbexplorer-export"
                  (result path format &optional header))
(declare-function cmacs-dbexplorer--handle "cmacs-dbexplorer" (connection))
(declare-function cmacs-dbexplorer--tables-async "src/cmacs-dbexplorer-defuns.c"
                  (handle schema callback))
(declare-function cmacs-dbexplorer--table-info-async "src/cmacs-dbexplorer-defuns.c"
                  (handle schema table callback))


;;;; Waiting -----------------------------------------------------------

;; The explorer is asynchronous all the way down, and these three
;; transports are not: MCP, D-Bus and emacsctl each want a value returned
;; from the call they made. So the agent surface is the one place that
;; waits, and it waits here rather than in six copies.

(defcustom cmacs-dbexplorer-tools-timeout 30
  "Seconds an agent-facing call waits for the database before giving up.

A caller that has blocked this long is better told so than left holding
a connection that may never answer."
  :type 'number
  :group 'cmacs-dbexplorer-tools)

(defun cmacs-dbexplorer-tools--await (start)
  "Run START, which takes a DONE callback, and wait for its result.

DONE is called with (VALUE . nil) on success or (nil . MESSAGE) on
failure.  Returns VALUE, or signals with MESSAGE.

The wait spins the event loop with `sit-for' rather than blocking,
because the reply arrives through that same loop -- a blocking wait would
prevent the very callback it is waiting for."
  (let ((box nil)
        (deadline (+ (float-time) cmacs-dbexplorer-tools-timeout)))
    (funcall start (lambda (value message) (setq box (list value message))))
    (while (and (null box) (< (float-time) deadline))
      (sit-for 0.01))
    (cond
     ((null box)
      (error "Timed out after %s seconds" cmacs-dbexplorer-tools-timeout))
     ((nth 1 box) (error "%s" (nth 1 box)))
     (t (nth 0 box)))))


;;;; Limits -------------------------------------------------------------

(defgroup cmacs-dbexplorer-tools nil
  "Database explorer capabilities published to agents."
  :group 'cmacs-dbexplorer
  :prefix "cmacs-dbexplorer-tools-")

(defcustom cmacs-dbexplorer-tools-max-rows 200
  "Most rows any agent-facing query returns.

A person who asks for a million rows scrolls past them; a model is
charged for every one and then reasons over a truncated view without
necessarily noticing.  So the cap is low and the truncation is stated in
the reply rather than left to be inferred from the row count."
  :type 'integer
  :group 'cmacs-dbexplorer-tools)

(defcustom cmacs-dbexplorer-tools-max-chars 40000
  "Most characters any agent-facing reply contains.

Row count alone does not bound size -- one row holding a document blows
the same budget as a thousand narrow ones."
  :type 'integer
  :group 'cmacs-dbexplorer-tools)

(defun cmacs-dbexplorer-tools--cap (string)
  "Truncate STRING to `cmacs-dbexplorer-tools-max-chars', saying so."
  (if (<= (length string) cmacs-dbexplorer-tools-max-chars)
      string
    (concat (substring string 0 cmacs-dbexplorer-tools-max-chars)
            (format "\n[truncated at %d characters]"
                    cmacs-dbexplorer-tools-max-chars))))

(defun cmacs-dbexplorer-tools--json (object)
  "Encode OBJECT as JSON, capped."
  (cmacs-dbexplorer-tools--cap
   (let ((json-encoding-pretty-print nil))
     (json-encode object))))

(defun cmacs-dbexplorer-tools--settle (reply done)
  "Hand REPLY to DONE, treating an (:error . MESSAGE) entry as failure.

The C layer reports database failures inside the reply rather than by
signalling, because these callbacks run where a Lisp signal would abort
the process rather than unwind."
  (let ((message (alist-get :error reply)))
    (if message (funcall done nil message) (funcall done reply nil))))

(defun cmacs-dbexplorer-tools--reply-vector (reply key)
  "Return KEY of REPLY as a list, accepting a vector or a list."
  (let ((value (alist-get key reply)))
    (if (vectorp value) (append value nil) value)))

(defun cmacs-dbexplorer-tools--connection (name)
  "Return the live connection called NAME, connecting if needed.

Signals rather than returning nil, because every caller here would
otherwise have to repeat the same check and one of them would forget."
  (cmacs-dbexplorer--require)
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9._-]+\\'" name))
    (error "Not a valid connection name: %S" name))
  (let ((connection (cmacs-dbexplorer-connection name)))
    (unless (cmacs-dbexplorer-connection-open-p connection)
      (unless (cmacs-dbexplorer-connection-spec name)
        (error "%s is not a configured connection" name))
      ;; Connecting is asynchronous, so the connection cannot be looked
      ;; up on the next line; wait for it to open or to fail.
      (setq connection
            (cmacs-dbexplorer-tools--await
             (lambda (done)
               (cmacs-dbexplorer-when-connected
                name (lambda (opened) (funcall done opened nil)))
               (cmacs-dbexplorer-connect name)))))
    (unless (cmacs-dbexplorer-connection-open-p connection)
      (error "Could not connect to %s" name))
    connection))

(defun cmacs-dbexplorer-tools--cell-json (cell)
  "Render CELL for JSON, keeping NULL distinct from the string \"NULL\"."
  (cond
   ((eq cell :null) nil)
   ((and (consp cell) (eq (car cell) :blob))
    (format "<%d bytes>" (cdr cell)))
   (t cell)))


;;;; The tool functions -------------------------------------------------

;; These are the entry points the MCP, D-Bus and emacsctl surfaces call.
;; Each returns a JSON string; each signals `cmacs-dbexplorer-error' or a
;; plain error on failure, which the C surfaces turn into their own error
;; representation.

(defun cmacs-dbexplorer-tool-connections ()
  "Return the configured and live connections as JSON."
  (cmacs-dbexplorer--require)
  (cmacs-dbexplorer-tools--json
   (vconcat
    (mapcar
     (lambda (entry)
       (let* ((name (car entry))
              (spec (cdr entry))
              (live (cmacs-dbexplorer-connection name)))
         (list (cons 'name name)
               (cons 'dialect (and live (cmacs-dbexplorer-connection-dialect live)))
               (cons 'state (format "%s" (if live
                                             (cmacs-dbexplorer-connection-state live)
                                           'closed)))
               ;; The saved intent, not just the live flag, so a caller
               ;; can see a connection is read-only before opening it.
               (cons 'read_only
                     (if (or (plist-get spec :read-only)
                             (and live (cmacs-dbexplorer-connection-read-only live)))
                         t json-false)))))
     cmacs-dbexplorer-connections))))

(defun cmacs-dbexplorer-tool-connect (name)
  "Open the saved connection called NAME."
  (let ((connection (cmacs-dbexplorer-tools--connection name)))
    (cmacs-dbexplorer-tools--json
     (list (cons 'name name)
           (cons 'dialect (cmacs-dbexplorer-connection-dialect connection))
           (cons 'read_only (if (cmacs-dbexplorer-connection-read-only connection)
                                t json-false))))))

(defun cmacs-dbexplorer-tool-disconnect (name)
  "Close the connection called NAME."
  (cmacs-dbexplorer--require)
  (cmacs-dbexplorer-disconnect name)
  (cmacs-dbexplorer-tools--json (list (cons 'name name) (cons 'state "closed"))))

(defun cmacs-dbexplorer-tool-query (name sql &optional max-rows)
  "Run SQL on the connection called NAME and return rows as JSON.

Always routed through the read path, so this cannot write even on a
read-write connection."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (limit (min (or max-rows cmacs-dbexplorer-tools-max-rows)
                     cmacs-dbexplorer-tools-max-rows))
         (result (cmacs-dbexplorer-tools--await
                  (lambda (done)
                    (cmacs-dbexplorer-query
                     connection sql
                     :options (list :max-rows limit)
                     :on-result (lambda (r) (funcall done r nil))
                     :on-error (lambda (m) (funcall done nil m)))))))
    (cmacs-dbexplorer-tools--json
     (list (cons 'columns (vconcat (cmacs-dbexplorer-result-column-names result)))
           (cons 'row_count (cmacs-dbexplorer-result-row-count result))
           (cons 'truncated (if (cmacs-dbexplorer-result-truncated result)
                                t json-false))
           (cons 'rows
                 (vconcat
                  (mapcar (lambda (row)
                            (vconcat (mapcar #'cmacs-dbexplorer-tools--cell-json
                                             (append row nil))))
                          (append (cmacs-dbexplorer-result-rows result) nil))))))))

(defun cmacs-dbexplorer-tool-execute (name sql)
  "Run a writing statement SQL on the connection called NAME.

Refused by the C layer on a read-only connection."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (reply (cmacs-dbexplorer-tools--await
                 (lambda (done)
                   (cmacs-dbexplorer-execute
                    connection sql
                    :on-done (lambda (r) (funcall done (or r t) nil))
                    :on-error (lambda (m) (funcall done nil m)))))))
    (cmacs-dbexplorer-tools--json
     (list (cons 'rows_affected (or (alist-get :rows-affected reply) 0))
           (cons 'last_insert_rowid (or (alist-get :last-insert-rowid reply) 0))))))

(defun cmacs-dbexplorer-tool-tables (name &optional schema)
  "Return the relations of SCHEMA on the connection called NAME."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (relations (cmacs-dbexplorer-tools--reply-vector
                     (cmacs-dbexplorer-tools--await
                      (lambda (done)
                        (cmacs-dbexplorer--tables-async
                         (cmacs-dbexplorer--handle connection) schema
                         (lambda (reply) (cmacs-dbexplorer-tools--settle reply done)))))
                     :relations)))
    (cmacs-dbexplorer-tools--json
     (vconcat
      (mapcar (lambda (relation)
                (list (cons 'name (plist-get relation :name))
                      (cons 'kind (format "%s" (plist-get relation :kind)))
                      (cons 'schema (plist-get relation :schema))))
              relations)))))

(defun cmacs-dbexplorer-tool-columns (name table &optional schema)
  "Return the columns of TABLE in SCHEMA on the connection called NAME."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (info (cmacs-dbexplorer-tools--await
                (lambda (done)
                  (cmacs-dbexplorer--table-info-async
                   (cmacs-dbexplorer--handle connection) schema table
                   (lambda (reply) (cmacs-dbexplorer-tools--settle reply done)))))))
    (cmacs-dbexplorer-tools--json
     (list
      (cons 'table table)
      ;; The reply is an alist of vectors; each column inside it is a
      ;; plist.  Mixing the two accessors up yields an empty answer
      ;; rather than an error, which is why this is spelled out.
      (cons 'primary_key
            (vconcat (cmacs-dbexplorer-tools--reply-vector info :primary-key)))
      (cons 'columns
            (vconcat
             (mapcar (lambda (column)
                       (list (cons 'name (plist-get column :name))
                             (cons 'type (plist-get column :type-name))
                             (cons 'nullable (if (plist-get column :nullable)
                                                 t json-false))
                             (cons 'primary_key (if (plist-get column :primary-key)
                                                    t json-false))
                             (cons 'default (plist-get column :default))))
                     (cmacs-dbexplorer-tools--reply-vector info :columns))))))))

(defun cmacs-dbexplorer-tool-export (name sql format path)
  "Export the results of SQL from connection NAME to PATH in FORMAT."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (path (expand-file-name path))
         (result (cmacs-dbexplorer-tools--await
                  (lambda (done)
                    (cmacs-dbexplorer-query
                     connection sql
                     :on-result (lambda (r) (funcall done r nil))
                     :on-error (lambda (m) (funcall done nil m)))))))
    (require 'cmacs-dbexplorer-export)
    ;; With a header: an exported file is going somewhere this process
    ;; cannot explain it, so the column names have to travel with it.
    (cmacs-dbexplorer-export-result result path (intern format) t)
    (cmacs-dbexplorer-tools--json
     (list (cons 'path path)
           (cons 'format format)
           (cons 'rows (cmacs-dbexplorer-result-row-count result))))))


;;;; ai-brigade ---------------------------------------------------------

;; Guarded rather than assumed: the explorer can be built without the AI
;; fabric, and a missing macro at load time should leave the rest of the
;; subsystem working rather than failing the file.
(when (and (cmacs-dbexplorer-available-p)
           (require 'cmacs-brigade-registry nil t)
           (fboundp 'cmacs-brigade-deftool))

  (cmacs-brigade-deftool db-connections
    "List the databases this Emacs can reach, with their dialect and whether
they are read-only.  Call this first: every other database tool addresses a
connection by the names this returns."
    ()
    :group 'database
    (cmacs-dbexplorer-tool-connections))

  (cmacs-brigade-deftool db-query
    "Run a read-only SQL query and return the rows as JSON.  Only reads are
permitted: SELECT, VALUES, EXPLAIN, SHOW and read-only pragmas.  Results are
capped, and the reply says so when it was truncated."
    ((connection string "Connection name from db-connections")
     (sql string "The SELECT statement to run"))
    :group 'database
    (cmacs-dbexplorer-tool-query connection sql))

  (cmacs-brigade-deftool db-tables
    "List the tables and views in a database."
    ((connection string "Connection name from db-connections")
     (schema string "Schema to list; omit for the default" :optional t))
    :group 'database
    (cmacs-dbexplorer-tool-tables connection schema))

  (cmacs-brigade-deftool db-columns
    "Describe one table: its columns with types and nullability, and its
primary key.  Use this before writing a query against a table you have not
seen."
    ((connection string "Connection name from db-connections")
     (table string "Table name")
     (schema string "Schema containing the table; omit for the default"
             :optional t))
    :group 'database
    (cmacs-dbexplorer-tool-columns connection table schema))

  (cmacs-brigade-deftool db-execute
    "Run a statement that CHANGES the database -- INSERT, UPDATE, DELETE or
DDL.  Refused outright on a connection marked read-only."
    ((connection string "Connection name from db-connections")
     (sql string "The statement to run"))
    :group 'database
    :destructive t
    :confirm 'ask
    (cmacs-dbexplorer-tool-execute connection sql))

  (cmacs-brigade-deftool db-export
    "Export the results of a query to a file as csv or json."
    ((connection string "Connection name from db-connections")
     (sql string "The SELECT statement whose results to export")
     (format string "csv or json")
     (path string "Absolute path to write"))
    :group 'database
    :destructive t
    :confirm 'ask
    (cmacs-dbexplorer-tool-export connection sql format path))

  ;; A panel on the brigade dashboard, so a running agent's database
  ;; access is visible next to everything else it is doing.
  (when (fboundp 'cmacs-brigade-register-panel)
    (cmacs-brigade-register-panel
     :name 'dbexplorer
     :title "Databases"
     :order 60
     :render
     (lambda ()
       (let ((connections (cmacs-dbexplorer-connections)))
         (if (null connections)
             (list "  (no open connections)")
           (mapcar
            (lambda (connection)
              (format "  %-20s %-12s %-8s%s"
                      (cmacs-dbexplorer-connection-name connection)
                      (or (cmacs-dbexplorer-connection-dialect connection) "?")
                      (cmacs-dbexplorer-connection-state connection)
                      (if (cmacs-dbexplorer-connection-read-only connection)
                          "  read-only" "")))
            connections)))))))

(provide 'cmacs-dbexplorer-tools)
;;; cmacs-dbexplorer-tools.el ends here
