;;; cmacs-dbexplorer-model.el --- Database explorer state, hooks and registries  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The view-agnostic half of the database explorer.  Everything here is
;; state and notification; nothing here draws.
;;
;; The rule the whole subsystem rests on is that views render the model
;; and the model never knows the views.  That is what lets a second view
;; -- a libregnum 2D or 3D scene, a different grid, something nobody has
;; thought of -- be a new file that registers itself, rather than an edit
;; to the code that already works.  Concretely:
;;
;;   - State lives in `cl-defstruct's keyed on stable identities: a
;;     connection by NAME, a row by its primary-key values.  Never on a
;;     buffer position or a C handle, both of which churn.  (The same
;;     reason roamgraph keys everything on the org-roam UUID.)
;;
;;   - The C layer gets ONE callback per stream and one for connection
;;     state.  This file owns those and re-broadcasts through abnormal
;;     hooks, so any number of views and integrations can listen without
;;     any of them touching C.
;;
;;   - Views, result actions, exporters and connection sources are
;;     registries.  Shipped features use the same ones a user's init
;;     does; there is no private back door.
;;
;; Load order: this file must not require any UI file, and every UI file
;; requires this one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-dbexplorer-supported-p "src/cmacs-dbexplorer-defuns.c" ())


;;;; Structures ---------------------------------------------------------

(cl-defstruct (cmacs-dbexplorer-connection
               (:constructor cmacs-dbexplorer-connection-create)
               (:copier nil))
  "A database connection as the explorer sees it.

NAME is the identity.  HANDLE is the integer the C layer issued and is
valid only while STATE is not `closed'; nothing outside this file should
keep one across a reconnect."
  (name nil :read-only t)
  handle
  dialect
  (state 'closed)
  read-only
  ;; Schema is cached because a tree redraw must not re-query, and the
  ;; SQL completion-at-point function reads it on every keystroke.
  (schema-cache (make-hash-table :test 'equal))
  in-transaction)

(cl-defstruct (cmacs-dbexplorer-result
               (:constructor cmacs-dbexplorer-result-create)
               (:copier nil))
  "One query's rows, with everything a view needs to render them.

COLUMNS is a vector of plists (:name :type :nullable).  ROWS is a vector
of vectors; a cell is a string, the keyword `:null', or a cons
\(:blob . SIZE) for a value too large to have been sent."
  (connection-name nil :read-only t)
  (sql nil :read-only t)
  columns
  rows
  truncated
  elapsed-ms
  ;; Set when the rows came from browsing one table, which is what makes
  ;; them editable: an arbitrary join has no row identity to update by.
  table
  schema
  primary-key
  (offset 0))

(cl-defstruct (cmacs-dbexplorer-edit
               (:constructor cmacs-dbexplorer-edit-create)
               (:copier nil))
  "One staged change, not yet sent to the database.

OP is `update', `insert' or `delete'.  KEY is the primary-key alist that
names the row, and is nil for an insert."
  (op nil :read-only t)
  (table nil :read-only t)
  (schema nil :read-only t)
  key
  values)


;;;; Live connections ---------------------------------------------------

(defvar cmacs-dbexplorer--live (make-hash-table :test 'equal)
  "Live connections, keyed by name.  Values are structs.")

(defun cmacs-dbexplorer-connection (name)
  "Return the live connection called NAME, or nil."
  (gethash name cmacs-dbexplorer--live))

(defun cmacs-dbexplorer-connections ()
  "Return every live connection, sorted by name."
  (sort (hash-table-values cmacs-dbexplorer--live)
        (lambda (a b) (string< (cmacs-dbexplorer-connection-name a)
                               (cmacs-dbexplorer-connection-name b)))))

(defun cmacs-dbexplorer--put-connection (connection)
  "Record CONNECTION as live and announce it."
  (puthash (cmacs-dbexplorer-connection-name connection) connection
           cmacs-dbexplorer--live)
  (cmacs-dbexplorer--notify-connection connection)
  connection)

(defun cmacs-dbexplorer--drop-connection (name)
  "Forget the connection called NAME."
  (when-let* ((connection (gethash name cmacs-dbexplorer--live)))
    (setf (cmacs-dbexplorer-connection-state connection) 'closed)
    (setf (cmacs-dbexplorer-connection-handle connection) nil)
    (cmacs-dbexplorer--notify-connection connection))
  (remhash name cmacs-dbexplorer--live))

(defun cmacs-dbexplorer-connection-open-p (connection)
  "Return non-nil if CONNECTION is usable."
  (and connection
       (cmacs-dbexplorer-connection-handle connection)
       (not (eq (cmacs-dbexplorer-connection-state connection) 'closed))))


;;;; Hooks --------------------------------------------------------------

;; Abnormal hooks, each documented with the exact plist it receives, so a
;; listener never has to read this file to find out what it is being
;; handed.

(defvar cmacs-dbexplorer-connection-state-functions nil
  "Functions called when a connection's state changes.

Each is called with one plist:

  :connection  the `cmacs-dbexplorer-connection' struct
  :name        its name
  :state       one of `closed', `connecting', `idle', `busy'
  :read-only   non-nil when the connection refuses writes

Called on the main thread, after the struct has been updated.")

(defvar cmacs-dbexplorer-result-received-functions nil
  "Functions called when a query finishes.

Each is called with one plist:

  :connection  the connection name
  :result      a `cmacs-dbexplorer-result', or nil when the query failed
  :error       an error string, or nil on success
  :sql         the statement that ran")

(defvar cmacs-dbexplorer-schema-updated-functions nil
  "Functions called when cached schema information changes.

Each is called with one plist:

  :connection  the connection name
  :schema      the schema name, or nil for the default
  :table       the table whose details were refreshed, or nil when the
               change was to the relation list itself")

(defvar cmacs-dbexplorer-edits-applied-functions nil
  "Functions called after staged edits are committed.

Each is called with one plist:

  :connection  the connection name
  :applied     how many statements the database reported
  :edits       the list of `cmacs-dbexplorer-edit' structs that were sent
  :error       an error string, or nil on success")

(defun cmacs-dbexplorer--run-hook (hook payload)
  "Run HOOK with PAYLOAD, surviving a listener that signals.

A view whose redraw errors must not stop the other listeners from being
told, and must not turn a successful query into a failed one."
  (dolist (fn (symbol-value hook))
    (condition-case err
        (funcall fn payload)
      (error
       (message "cmacs-dbexplorer: %s handler failed: %s"
                hook (error-message-string err))))))

(defun cmacs-dbexplorer--notify-connection (connection)
  "Announce CONNECTION's current state."
  (cmacs-dbexplorer--run-hook
   'cmacs-dbexplorer-connection-state-functions
   (list :connection connection
         :name (cmacs-dbexplorer-connection-name connection)
         :state (cmacs-dbexplorer-connection-state connection)
         :read-only (cmacs-dbexplorer-connection-read-only connection))))


;;;; Registries ---------------------------------------------------------

(defmacro cmacs-dbexplorer--define-registry (kind required)
  "Define a registry for KIND whose entries must carry REQUIRED keys.

Generates `cmacs-dbexplorer-register-KIND', its `unregister' partner, a
lookup and a list accessor.  Re-registering a name replaces it, so
reloading a file that registers something is safe."
  (let* ((name (symbol-name kind))
         (table (intern (format "cmacs-dbexplorer--%ss" name)))
         (reg (intern (format "cmacs-dbexplorer-register-%s" name)))
         (unreg (intern (format "cmacs-dbexplorer-unregister-%s" name)))
         (get (intern (format "cmacs-dbexplorer-%s" name)))
         (list-fn (intern (format "cmacs-dbexplorer-%ss" name))))
    `(progn
       (defvar ,table (make-hash-table :test 'eq)
         ,(format "Registered %s entries, keyed by name symbol." name))

       (defun ,reg (name &rest plist)
         ,(format "Register a %s called NAME from PLIST.

Required keys: %s.  Re-registering the same NAME replaces it."
                  name required)
         (unless (symbolp name)
           (error "cmacs-dbexplorer: a %s needs a symbol name" ,name))
         (dolist (key ',required)
           (unless (plist-get plist key)
             (error "cmacs-dbexplorer: %s %s needs a %s" ,name name key)))
         (puthash name plist ,table)
         name)

       (defun ,unreg (name)
         ,(format "Remove the %s called NAME." name)
         (remhash name ,table))

       (defun ,get (name)
         ,(format "Return the %s called NAME, or nil." name)
         (gethash name ,table))

       (defun ,list-fn ()
         ,(format "Return every registered %s as (NAME . PLIST), by name."
                  name)
         (let (out)
           (maphash (lambda (k v) (push (cons k v) out)) ,table)
           (sort out (lambda (a b)
                       (string< (symbol-name (car a))
                                (symbol-name (car b))))))))))

(cmacs-dbexplorer--define-registry view (:open))
(cmacs-dbexplorer--define-registry result-action (:key :label :run))
(cmacs-dbexplorer--define-registry exporter (:label :run))
(cmacs-dbexplorer--define-registry connection-source (:enumerate))

;; The registry docstrings above are generated, so the contracts each
;; kind actually has to satisfy are spelled out here:
;;
;; view              :open (fn CONNECTION) -> buffer.  Optional :render
;;                   (fn OBJECT) to re-render an existing view, :supports
;;                   a list of `result'/`schema', and :label for the
;;                   picker.  `cmacs-dbexplorer-open-view' completes over
;;                   these, so a new view is reachable the moment it
;;                   registers -- which is how a libregnum 2D/3D view
;;                   would arrive without touching anything here.
;;
;; result-action     :key a key description, :label for the legend, :run
;;                   (fn RESULT ROW-INDEX COLUMN-INDEX).  Optional :pred
;;                   (fn RESULT) to hide the action when it cannot apply.
;;                   The grid installs these into its keymap and its
;;                   Evil auxiliary map, and generates the legend from
;;                   the same list, so the two cannot disagree.
;;
;; exporter          :label, :run (fn RESULT PATH), optional :extension.
;;
;; connection-source :enumerate (fn) -> list of (NAME . PLIST) connection
;;                   specs, letting connections come from somewhere other
;;                   than the defcustom -- a .pg_service.conf, a secrets
;;                   manager, a project file.

(defun cmacs-dbexplorer-view-supports-p (view kind)
  "Return non-nil if VIEW's plist claims support for KIND.

A view that says nothing about what it supports is assumed to support
everything, so the common case needs no boilerplate."
  (let ((supports (plist-get view :supports)))
    (or (null supports) (memq kind supports))))


;;;; Schema cache -------------------------------------------------------

(defun cmacs-dbexplorer--cache-key (schema table)
  "Return the schema-cache key for TABLE in SCHEMA."
  (format "%s\0%s" (or schema "") (or table "")))

(defun cmacs-dbexplorer-schema-get (connection schema table)
  "Return cached details for TABLE in SCHEMA on CONNECTION, or nil."
  (gethash (cmacs-dbexplorer--cache-key schema table)
           (cmacs-dbexplorer-connection-schema-cache connection)))

(defun cmacs-dbexplorer-schema-put (connection schema table info)
  "Cache INFO for TABLE in SCHEMA on CONNECTION and announce it."
  (puthash (cmacs-dbexplorer--cache-key schema table) info
           (cmacs-dbexplorer-connection-schema-cache connection))
  (cmacs-dbexplorer--run-hook
   'cmacs-dbexplorer-schema-updated-functions
   (list :connection (cmacs-dbexplorer-connection-name connection)
         :schema schema
         :table table))
  info)

(defun cmacs-dbexplorer-schema-forget (connection)
  "Drop every cached schema detail for CONNECTION.

Called after DDL, which can invalidate anything."
  (clrhash (cmacs-dbexplorer-connection-schema-cache connection))
  (cmacs-dbexplorer--run-hook
   'cmacs-dbexplorer-schema-updated-functions
   (list :connection (cmacs-dbexplorer-connection-name connection)
         :schema nil :table nil)))


;;;; Result helpers -----------------------------------------------------

(defun cmacs-dbexplorer-result-column-names (result)
  "Return RESULT's column names as a list of strings."
  (mapcar (lambda (column) (plist-get column :name))
          (append (cmacs-dbexplorer-result-columns result) nil)))

(defun cmacs-dbexplorer-result-column-index (result name)
  "Return the index of the column called NAME in RESULT, or nil."
  (cl-position name (cmacs-dbexplorer-result-column-names result)
               :test #'equal))

(defun cmacs-dbexplorer-result-cell (result row column)
  "Return the cell at ROW and COLUMN of RESULT."
  (let ((rows (cmacs-dbexplorer-result-rows result)))
    (when (and (>= row 0) (< row (length rows)))
      (let ((cells (aref rows row)))
        (when (and (>= column 0) (< column (length cells)))
          (aref cells column))))))

(defun cmacs-dbexplorer-result-row-count (result)
  "Return how many rows RESULT holds."
  (length (cmacs-dbexplorer-result-rows result)))

(defun cmacs-dbexplorer-result-editable-p (result)
  "Return non-nil if rows of RESULT can be updated in place.

Editing needs a table to write to and a primary key to name the row
with.  An arbitrary join has neither, and a table without a primary key
has no way to say which row you meant -- offering to edit either would be
offering to corrupt something."
  (and (cmacs-dbexplorer-result-table result)
       (cmacs-dbexplorer-result-primary-key result)
       t))

(defun cmacs-dbexplorer-result-row-key (result row)
  "Return the primary-key alist naming ROW of RESULT, or nil."
  (when (cmacs-dbexplorer-result-editable-p result)
    (let ((key nil)
          (complete t))
      (dolist (column (cmacs-dbexplorer-result-primary-key result))
        (let ((index (cmacs-dbexplorer-result-column-index result column)))
          (if (null index)
              ;; A primary-key column missing from the SELECT means the
              ;; row cannot be named.  A partial key would still produce
              ;; a syntactically valid WHERE clause -- one that matches
              ;; more rows than intended -- so the answer is no key.
              (setq complete nil)
            (push (cons column (cmacs-dbexplorer-result-cell result row index))
                  key))))
      (and complete (nreverse key)))))

(defun cmacs-dbexplorer-cell-display (cell &optional null-text)
  "Return CELL as a string for display, showing NULL as NULL-TEXT."
  (cond
   ((eq cell :null) (or null-text "NULL"))
   ((and (consp cell) (eq (car cell) :blob))
    (format "<%s bytes>" (cdr cell)))
   ((stringp cell) cell)
   (t (format "%s" cell))))


;;;; Staged edits -------------------------------------------------------

(defun cmacs-dbexplorer-edits-to-ops (edits)
  "Convert EDITS into the plist ops the C layer applies.

The shapes are fixed by `cmacs-dbexplorer--apply-edits-async': an update
carries :set and :where, an insert carries :values, a delete carries
:where.  Update and delete both carry :expect 1, which is what makes a
WHERE clause that matched the wrong number of rows roll the batch back
instead of committing it."
  (mapcar
   (lambda (edit)
     (let ((op (cmacs-dbexplorer-edit-op edit))
           (table (cmacs-dbexplorer-edit-table edit))
           (schema (cmacs-dbexplorer-edit-schema edit)))
       (pcase op
         ('update (list :op 'update :schema schema :table table
                        :set (cmacs-dbexplorer-edit-values edit)
                        :where (cmacs-dbexplorer-edit-key edit)
                        :expect 1))
         ('insert (list :op 'insert :schema schema :table table
                        :values (cmacs-dbexplorer-edit-values edit)))
         ('delete (list :op 'delete :schema schema :table table
                        :where (cmacs-dbexplorer-edit-key edit)
                        :expect 1))
         (_ (error "cmacs-dbexplorer: unknown edit op %S" op)))))
   edits))

(defun cmacs-dbexplorer-edit-describe (edit)
  "Return a one-line description of EDIT for a review buffer."
  (let ((table (cmacs-dbexplorer-edit-table edit)))
    (pcase (cmacs-dbexplorer-edit-op edit)
      ('update (format "UPDATE %s SET %s WHERE %s" table
                       (cmacs-dbexplorer--pairs
                        (cmacs-dbexplorer-edit-values edit))
                       (cmacs-dbexplorer--pairs
                        (cmacs-dbexplorer-edit-key edit))))
      ('insert (format "INSERT INTO %s (%s)" table
                       (cmacs-dbexplorer--pairs
                        (cmacs-dbexplorer-edit-values edit))))
      ('delete (format "DELETE FROM %s WHERE %s" table
                       (cmacs-dbexplorer--pairs
                        (cmacs-dbexplorer-edit-key edit))))
      (op (format "%s %s" op table)))))

(defun cmacs-dbexplorer--pairs (alist)
  "Render ALIST as \"a = x, b = y\" for display only."
  (mapconcat (lambda (pair)
               (format "%s = %s" (car pair)
                       (cmacs-dbexplorer-cell-display (cdr pair))))
             alist ", "))


;;;; Availability -------------------------------------------------------

;;;###autoload
(defun cmacs-dbexplorer-available-p ()
  "Return non-nil if this build has the database explorer compiled in."
  (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer
       (fboundp 'cmacs-dbexplorer-supported-p)
       (cmacs-dbexplorer-supported-p)))

(defun cmacs-dbexplorer--require ()
  "Signal unless the database explorer is available."
  (unless (cmacs-dbexplorer-available-p)
    (user-error "cmacs was not built with --with-cmacs-dbexplorer")))

(provide 'cmacs-dbexplorer-model)
;;; cmacs-dbexplorer-model.el ends here
