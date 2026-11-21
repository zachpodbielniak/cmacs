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

;; `cmacs-brigade-deftool' is a MACRO, and the forms that use it sit
;; inside a runtime `when' further down.  Without the registry loaded at
;; compile time the byte compiler cannot expand them, compiles each one
;; as a call to a function named `cmacs-brigade-deftool', and loading the
;; result evaluates the tool name as a variable ("void-variable
;; db-connections").  Whether it was loaded used to depend on what the
;; build happened to compile first, so an image could ship broken while
;; the tree worked.
(eval-when-compile (require 'cmacs-brigade-registry nil t))

;; cmacs-dbexplorer.el is required lazily, in
;; `cmacs-dbexplorer-tools--ensure', not at the top of this file: the
;; MCP, D-Bus and emacsctl surfaces load this file at startup, and an
;; agent surface should not drag the transient and auth-source machinery
;; in behind it.  But it MUST be loaded when a tool actually runs --
;; every tool below reaches `cmacs-dbexplorer-connect',
;; `cmacs-dbexplorer-query' and friends, and in a session where the user
;; never opened the explorer themselves nothing else will have loaded
;; them; without the lazy require the entire agent surface dies on the
;; first call with a void-function error.

(declare-function cmacs-dbexplorer-connection-specs "cmacs-dbexplorer" ())
(declare-function cmacs-dbexplorer-connect "cmacs-dbexplorer" (&optional name))
(declare-function cmacs-dbexplorer-disconnect "cmacs-dbexplorer" (&optional name))
(declare-function cmacs-dbexplorer-connection-spec "cmacs-dbexplorer" (name))
(declare-function cmacs-dbexplorer-when-connected "cmacs-dbexplorer"
                  (name function &optional failure))
(declare-function cmacs-dbexplorer-query "cmacs-dbexplorer"
                  (connection sql &rest keys))
(declare-function cmacs-dbexplorer-execute "cmacs-dbexplorer"
                  (connection sql &rest keys))
(declare-function cmacs-dbexplorer-run-export "cmacs-dbexplorer"
                  (connection sql format path &rest keys))
(declare-function cmacs-dbexplorer-cancel "cmacs-dbexplorer" (id))
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

(defcustom cmacs-dbexplorer-tools-export-timeout 600
  "Seconds `cmacs-dbexplorer-tool-export' waits for the export to finish.

Separate from `cmacs-dbexplorer-tools-timeout', and much larger: the C
streamer exists precisely to move tables bigger than the editor could
hold, and a big table takes longer than any sensible query timeout.  A
30-second cap here would tell the agent the export failed while the file
went on quietly filling up behind it."
  :type 'number
  :group 'cmacs-dbexplorer-tools)

(defun cmacs-dbexplorer-tools--await (start &optional timeout)
  "Run START, which takes a DONE callback, and wait for its result.

DONE is called with (VALUE . nil) on success or (nil . MESSAGE) on
failure.  Returns VALUE, or signals with MESSAGE.  TIMEOUT overrides
`cmacs-dbexplorer-tools-timeout'.

The wait spins the event loop with `sit-for' rather than blocking,
because the reply arrives through that same loop -- a blocking wait would
prevent the very callback it is waiting for."
  (let* ((timeout (or timeout cmacs-dbexplorer-tools-timeout))
         (box nil)
         (deadline (+ (float-time) timeout)))
    (funcall start (lambda (value message) (setq box (list value message))))
    (while (and (null box) (< (float-time) deadline))
      (sit-for 0.01))
    (cond
     ((null box)
      (error "Timed out after %s seconds" timeout))
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

(defun cmacs-dbexplorer-tools--ensure ()
  "Signal unless the explorer is built, then load its core.
See the commentary at the top of the file for why the require is here
and not at load time."
  (cmacs-dbexplorer--require)
  (require 'cmacs-dbexplorer))

(defun cmacs-dbexplorer-tools--connection (name)
  "Return the live connection called NAME, connecting if needed.

Signals rather than returning nil, because every caller here would
otherwise have to repeat the same check and one of them would forget."
  (cmacs-dbexplorer-tools--ensure)
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9._-]+\\'" name))
    (error "Not a valid connection name: %S" name))
  (let ((connection (cmacs-dbexplorer-connection name)))
    (unless (cmacs-dbexplorer-connection-open-p connection)
      (unless (cmacs-dbexplorer-connection-spec name)
        (error "%s is not a configured connection" name))
      ;; Connecting is asynchronous, so the connection cannot be looked
      ;; up on the next line; wait for it to open or to fail.  The
      ;; failure watcher is what turns a bad password into an immediate
      ;; error instead of a full timeout spent waiting for a connect
      ;; that already said no.
      (setq connection
            (cmacs-dbexplorer-tools--await
             (lambda (done)
               (cmacs-dbexplorer-when-connected
                name
                (lambda (opened) (funcall done opened nil))
                (lambda (_name)
                  (funcall done nil (format "could not connect to %s" name))))
               (cmacs-dbexplorer-connect name)))))
    (unless (cmacs-dbexplorer-connection-open-p connection)
      (error "Could not connect to %s" name))
    connection))

(defun cmacs-dbexplorer-tools--check-name (name)
  "Signal unless NAME has the shape of a saved connection name.

A connection is named, never described: the name selects one an
operator already saved, so a caller cannot hand cmacs a URL -- and with
it a host and credentials -- of its own choosing."
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9._-]+\\'" name))
    (error "'connection' must be a saved connection name \
\([A-Za-z0-9._-]+); connection URLs are not accepted")))

(defun cmacs-dbexplorer-tools--identifier (value what)
  "Return VALUE if it is a plain SQL identifier, nil if blank, else signal.
WHAT names the argument for the error.

Table and schema names reach the database as identifiers.  Quoted ones
\(\"odd name\") are refused rather than half-handled: accepting the
opening quote without owning the quoting rules of three dialects is how
an injection gets in.  The C tools made this check before calling in;
the registry's tools are reached without passing through them."
  (cond
   ((or (null value) (equal value "")) nil)
   ((and (stringp value)
         (string-match-p "\\`[A-Za-z_][A-Za-z0-9_$]*\\'" value))
    value)
   (t (error "'%s' must be a plain unquoted identifier" what))))

(defun cmacs-dbexplorer-tools--connect-async (name done)
  "Open the saved connection NAME, then call DONE with its JSON description.

The non-blocking form of `cmacs-dbexplorer-tool-connect': the same
checks and the same reply, but the handshake is waited for by the
connect hooks rather than by this thread.  A failure reaches DONE as an
\"Error: ...\" string, the registry's convention for an asynchronous
tool; a bad name or an unconfigured connection is signalled at once."
  (cmacs-dbexplorer-tools--ensure)
  (cmacs-dbexplorer-tools--check-name name)
  (let ((describe
         (lambda (connection)
           (funcall
            done
            (condition-case err
                (cmacs-dbexplorer-tools--json
                 (list (cons 'name name)
                       (cons 'dialect
                             (cmacs-dbexplorer-connection-dialect connection))
                       (cons 'read_only
                             (if (cmacs-dbexplorer-connection-read-only
                                  connection)
                                 t json-false))))
              (error (format "Error: %s" (error-message-string err))))))))
    (if (cmacs-dbexplorer-connection-open-p (cmacs-dbexplorer-connection name))
        ;; Already open: left alone, and described.
        (funcall describe (cmacs-dbexplorer-connection name))
      (unless (cmacs-dbexplorer-connection-spec name)
        (error "%s is not a configured connection" name))
      ;; The failure watcher is what turns a bad password into an answer
      ;; now instead of a timeout later.
      (cmacs-dbexplorer-when-connected
       name describe
       (lambda (_name)
         (funcall done (format "Error: could not connect to %s" name))))
      (cmacs-dbexplorer-connect name))))

(defun cmacs-dbexplorer-tools--cell-json (cell)
  "Render CELL for JSON, keeping NULL distinct from the string \"NULL\"."
  (cond
   ((eq cell :null) nil)
   ((and (consp cell) (eq (car cell) :blob))
    (format "<%d bytes>" (cdr cell)))
   (t cell)))


;;;; Without waiting -----------------------------------------------------
;;
;; `cmacs-dbexplorer-tools--await' above waits in `sit-for'.  That is
;; what the hand-written D-Bus handlers in C still call (the MCP ones
;; that also did are deleted), and for
;; them it is no worse than it was.  The registry's tools must not: a
;; tool call is dispatched on the main thread, which under `emacs --gowl'
;; is the compositor's, and `sit-for' there holds the desktop for as long
;; as the database takes -- or signals outright, because an RPC dispatch
;; binds `inhibit-interaction' and `sit-for' reads an event.
;;
;; So every tool below is :async and built from these: nothing waits,
;; each step is a callback, and DONE is called exactly once.

(defun cmacs-dbexplorer-tools--once (done timeout &optional on-timeout)
  "Return (OK . FAIL): two functions that answer DONE at most once.

OK takes a thunk producing the reply string; it runs under a handler, so
an error while rendering is a failed call and not an escape from a
callback (where a signal goes nowhere anyone is looking).  FAIL takes a
message.  Failures reach DONE in the registry's \"Error: ...\" form.

After TIMEOUT seconds with neither called, ON-TIMEOUT runs (to cancel
whatever is still going) and the call fails as timed out.  The registry
has a timeout of its own; this one is slightly earlier and is what lets
a stream be cancelled by the answer that reports it."
  (let* ((settled nil)
         (timer nil)
         (answer (lambda (text)
                   (unless settled
                     (setq settled t)
                     (when (timerp timer) (cancel-timer timer))
                     (funcall done text)))))
    (setq timer
          (run-at-time
           timeout nil
           (lambda ()
             (unless settled
               (when on-timeout (ignore-errors (funcall on-timeout)))
               (funcall answer
                        (format "Error: Timed out after %s seconds"
                                timeout))))))
    (cons (lambda (thunk)
            (funcall answer
                     (condition-case err
                         (funcall thunk)
                       (error (format "Error: %s"
                                      (error-message-string err))))))
          (lambda (message)
            (funcall answer (format "Error: %s" message))))))

(defun cmacs-dbexplorer-tools--connection-async (name then fail)
  "Call THEN with the live connection NAME, opening it first if needed.

The non-blocking form of `cmacs-dbexplorer-tools--connection'.  A bad
name or an unconfigured connection is signalled at once, before anything
is started; a connect that is refused calls FAIL with a message.  THEN
runs from the connect hooks, not from here, unless the connection was
already open."
  (cmacs-dbexplorer-tools--ensure)
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9._-]+\\'" name))
    (error "Not a valid connection name: %S" name))
  (let ((connection (cmacs-dbexplorer-connection name)))
    (if (cmacs-dbexplorer-connection-open-p connection)
        (funcall then connection)
      (unless (cmacs-dbexplorer-connection-spec name)
        (error "%s is not a configured connection" name))
      (cmacs-dbexplorer-when-connected
       name
       (lambda (opened)
         (if (cmacs-dbexplorer-connection-open-p opened)
             (funcall then opened)
           (funcall fail (format "Could not connect to %s" name))))
       (lambda (_name)
         (funcall fail (format "could not connect to %s" name))))
      (cmacs-dbexplorer-connect name))))


(defun cmacs-dbexplorer-tools--with-connection (name fail then)
  "Call THEN with the live connection NAME; report any failure to FAIL.
`cmacs-dbexplorer-tools--connection-async' with its signals caught: by
the time a tool calls this it has armed a timer through
`cmacs-dbexplorer-tools--once', and a bad name that escaped as a signal
would leave that timer to fire at nobody thirty seconds later."
  (condition-case err
      (cmacs-dbexplorer-tools--connection-async name then fail)
    (error (funcall fail (error-message-string err)))))


;;;; The tool functions -------------------------------------------------

;; These are the entry points the MCP, D-Bus and emacsctl surfaces call.
;; Each returns a JSON string; each signals `cmacs-dbexplorer-error' or a
;; plain error on failure, which the C surfaces turn into their own error
;; representation.

(defun cmacs-dbexplorer-tool-connections ()
  "Return the configured and live connections as JSON.

Configured means `cmacs-dbexplorer-connection-specs' -- the defcustom
plus every registered connection source -- and live connections are
listed even when no spec mentions them, since `cmacs-dbexplorer-tool-query'
happily addresses one by name.  An agent working from a listing that
hides connections the other tools accept is being lied to."
  (cmacs-dbexplorer-tools--ensure)
  (let* ((specs (cmacs-dbexplorer-connection-specs))
         (names (delete-dups
                 (append (mapcar #'car specs)
                         (mapcar #'cmacs-dbexplorer-connection-name
                                 (cmacs-dbexplorer-connections))))))
    (cmacs-dbexplorer-tools--json
     (vconcat
      (mapcar
       (lambda (name)
         (let ((spec (cdr (assoc name specs)))
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
       names)))))

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
  (cmacs-dbexplorer-tools--ensure)
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
    (cmacs-dbexplorer-tools--query-json result)))

(defun cmacs-dbexplorer-tools--query-json (result)
  "Render the query RESULT as the JSON `db_query' answers with."
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
                        (append (cmacs-dbexplorer-result-rows result) nil)))))))

(defun cmacs-dbexplorer-tool-query-async (done name sql &optional max-rows)
  "Run SQL on the connection NAME; call DONE with the rows as JSON.
`cmacs-dbexplorer-tool-query' without the wait: the same read path, the
same cap, the same reply."
  (pcase-let* ((limit (min (or max-rows cmacs-dbexplorer-tools-max-rows)
                           cmacs-dbexplorer-tools-max-rows))
               (`(,ok . ,fail)
                (cmacs-dbexplorer-tools--once
                 done cmacs-dbexplorer-tools-timeout)))
    (cmacs-dbexplorer-tools--with-connection
     name fail
     (lambda (connection)
       (cmacs-dbexplorer-query
        connection sql
        :options (list :max-rows limit)
        :on-result (lambda (r)
                     (funcall ok (lambda ()
                                   (cmacs-dbexplorer-tools--query-json r))))
        :on-error fail)))))

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
    (cmacs-dbexplorer-tools--execute-json reply)))

(defun cmacs-dbexplorer-tools--execute-json (reply)
  "Render the execute REPLY as the JSON `db_execute' answers with."
  (cmacs-dbexplorer-tools--json
   (list (cons 'rows_affected
               (or (and (listp reply) (alist-get :rows-affected reply)) 0))
         (cons 'last_insert_rowid
               (or (and (listp reply) (alist-get :last-insert-rowid reply))
                   0)))))

(defun cmacs-dbexplorer-tool-execute-async (done name sql)
  "Run the writing statement SQL on connection NAME; answer through DONE.
`cmacs-dbexplorer-tool-execute' without the wait.  Refused by the C
layer on a read-only connection, exactly as there."
  (pcase-let ((`(,ok . ,fail)
               (cmacs-dbexplorer-tools--once
                done cmacs-dbexplorer-tools-timeout)))
    (cmacs-dbexplorer-tools--with-connection
     name fail
     (lambda (connection)
       (cmacs-dbexplorer-execute
        connection sql
        :on-done (lambda (r)
                   (funcall ok (lambda ()
                                 (cmacs-dbexplorer-tools--execute-json r))))
        :on-error fail)))))

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
    (cmacs-dbexplorer-tools--tables-json relations)))

(defun cmacs-dbexplorer-tools--tables-json (relations)
  "Render RELATIONS, a list of plists, as the JSON `db_tables' answers with."
  (cmacs-dbexplorer-tools--json
   (vconcat
    (mapcar (lambda (relation)
              (list (cons 'name (plist-get relation :name))
                    (cons 'kind (format "%s" (plist-get relation :kind)))
                    (cons 'schema (plist-get relation :schema))))
            relations))))

(defun cmacs-dbexplorer-tools--settle-async (reply ok fail render)
  "Hand the C layer's REPLY to OK through RENDER, or its error to FAIL.
The non-blocking twin of `cmacs-dbexplorer-tools--settle'."
  (let ((message (alist-get :error reply)))
    (if message
        (funcall fail message)
      (funcall ok (lambda () (funcall render reply))))))

(defun cmacs-dbexplorer-tool-tables-async (done name &optional schema)
  "List the relations of SCHEMA on connection NAME; answer through DONE.
`cmacs-dbexplorer-tool-tables' without the wait."
  (pcase-let ((`(,ok . ,fail)
               (cmacs-dbexplorer-tools--once
                done cmacs-dbexplorer-tools-timeout)))
    (cmacs-dbexplorer-tools--with-connection
     name fail
     (lambda (connection)
       (cmacs-dbexplorer--tables-async
        (cmacs-dbexplorer--handle connection) schema
        (lambda (reply)
          (cmacs-dbexplorer-tools--settle-async
           reply ok fail
           (lambda (r)
             (cmacs-dbexplorer-tools--tables-json
              (cmacs-dbexplorer-tools--reply-vector r :relations))))))))))

(defun cmacs-dbexplorer-tool-columns (name table &optional schema)
  "Return the columns of TABLE in SCHEMA on the connection called NAME."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (info (cmacs-dbexplorer-tools--await
                (lambda (done)
                  (cmacs-dbexplorer--table-info-async
                   (cmacs-dbexplorer--handle connection) schema table
                   (lambda (reply) (cmacs-dbexplorer-tools--settle reply done)))))))
    (cmacs-dbexplorer-tools--columns-json table info)))

(defun cmacs-dbexplorer-tools--columns-json (table info)
  "Render INFO about TABLE as the JSON `db_columns' answers with."
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
                   (cmacs-dbexplorer-tools--reply-vector info :columns)))))))

(defun cmacs-dbexplorer-tool-columns-async (done name table &optional schema)
  "Describe TABLE in SCHEMA on connection NAME; answer through DONE.
`cmacs-dbexplorer-tool-columns' without the wait."
  (pcase-let ((`(,ok . ,fail)
               (cmacs-dbexplorer-tools--once
                done cmacs-dbexplorer-tools-timeout)))
    (cmacs-dbexplorer-tools--with-connection
     name fail
     (lambda (connection)
       (cmacs-dbexplorer--table-info-async
        (cmacs-dbexplorer--handle connection) schema table
        (lambda (reply)
          (cmacs-dbexplorer-tools--settle-async
           reply ok fail
           (lambda (r) (cmacs-dbexplorer-tools--columns-json table r)))))))))

(defun cmacs-dbexplorer-tool-export (name sql format path)
  "Export the results of SQL from connection NAME to PATH in FORMAT.

Waits for the export to finish rather than reporting that it started.
These three transports are request and response: the caller gets one
reply and has no channel on which to hear how it went later, so \"an
export has begun\" is a reply nobody can act on -- and a bad path or a
failing statement would be indistinguishable from success.

The rows are streamed from the database into the file by the C layer and
never enter Emacs, so exporting a table larger than the editor could hold
is a question of disk rather than memory."
  (let* ((connection (cmacs-dbexplorer-tools--connection name))
         (path (expand-file-name path))
         (stream nil)
         (summary
          (condition-case err
              (cmacs-dbexplorer-tools--await
               (lambda (done)
                 (setq stream
                       (cmacs-dbexplorer-run-export
                        connection sql format path
                        ;; With a header: the file is going somewhere this
                        ;; process cannot explain it, so the column names
                        ;; travel with it.
                        :options (list :header t)
                        :on-done (lambda (s) (funcall done s nil))
                        :on-error (lambda (m) (funcall done nil m)))))
               ;; The export gets its own, far longer deadline -- see the
               ;; defcustom -- and on timing out the stream is cancelled,
               ;; so the caller is not told "it failed" while the file
               ;; keeps growing behind its back.
               cmacs-dbexplorer-tools-export-timeout)
            (error
             (when stream
               (ignore-errors (cmacs-dbexplorer-cancel stream)))
             (signal (car err) (cdr err))))))
    (cmacs-dbexplorer-tools--export-json format summary)))

(defun cmacs-dbexplorer-tools--export-json (format summary)
  "Render the export SUMMARY in FORMAT as the JSON `db_export' answers with."
  (cmacs-dbexplorer-tools--json
   (list (cons 'path (plist-get summary :path))
         (cons 'format format)
         (cons 'rows (plist-get summary :row-count))
         (cons 'truncated (if (plist-get summary :truncated) t json-false)))))

(defun cmacs-dbexplorer-tool-export-async (done name sql format path)
  "Export the results of SQL from connection NAME to PATH in FORMAT.
`cmacs-dbexplorer-tool-export' without the wait: DONE is called when the
C streamer finishes, with the same summary.  On timing out the stream is
cancelled first, so the caller is not told it failed while the file
keeps growing behind its back."
  (pcase-let* ((path (expand-file-name path))
               (stream nil)
               (`(,ok . ,fail)
                (cmacs-dbexplorer-tools--once
                 done cmacs-dbexplorer-tools-export-timeout
                 (lambda ()
                   (when stream (cmacs-dbexplorer-cancel stream))))))
    (cmacs-dbexplorer-tools--with-connection
     name fail
     (lambda (connection)
       (setq stream
             (cmacs-dbexplorer-run-export
              connection sql format path
              ;; With a header: see `cmacs-dbexplorer-tool-export'.
              :options (list :header t)
              :on-done (lambda (summary)
                         (funcall ok
                                  (lambda ()
                                    (cmacs-dbexplorer-tools--export-json
                                     format summary))))
              :on-error fail))))))


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
     (sql string "The SELECT statement to run")
     ;; The C tool of this name took it (see the frozen schema,
     ;; test/cmacs/data/mcp-wire-schema.json), and the registry's is the
     ;; only one MCP clients reach now that the C is deleted.
     (max_rows integer "Maximum rows to fetch; omit for the configured default"
               :optional t))
    ;; :async, like every tool here that talks to a database: see
    ;; "Without waiting" above.  The registry's timeout sits just past
    ;; the tool's own, so the tool's answer is the one that arrives.
    :group 'database
    :async t :timeout (+ cmacs-dbexplorer-tools-timeout 15)
    (cmacs-dbexplorer-tool-query-async done connection sql
                                       (and (integerp max_rows) (> max_rows 0)
                                            max_rows)))

  (cmacs-brigade-deftool db-tables
    "List the tables and views in a database."
    ((connection string "Connection name from db-connections")
     (schema string "Schema to list; omit for the default" :optional t))
    :group 'database
    :async t :timeout (+ cmacs-dbexplorer-tools-timeout 15)
    (cmacs-dbexplorer-tool-tables-async
     done connection (cmacs-dbexplorer-tools--identifier schema "schema")))

  (cmacs-brigade-deftool db-columns
    "Describe one table: its columns with types and nullability, and its
primary key.  Use this before writing a query against a table you have not
seen."
    ((connection string "Connection name from db-connections")
     (table string "Table name")
     (schema string "Schema containing the table; omit for the default"
             :optional t))
    :group 'database
    :async t :timeout (+ cmacs-dbexplorer-tools-timeout 15)
    (cmacs-dbexplorer-tool-columns-async
     done connection
     (or (cmacs-dbexplorer-tools--identifier table "table")
         (error "db_columns: missing 'table'"))
     (cmacs-dbexplorer-tools--identifier schema "schema")))

  (cmacs-brigade-deftool db-execute
    "Run a statement that CHANGES the database -- INSERT, UPDATE, DELETE or
DDL.  Refused outright on a connection marked read-only."
    ((connection string "Connection name from db-connections")
     (sql string "The statement to run"))
    :group 'database
    :destructive t
    :undo '(irreversible "a committed statement cannot be taken back")
    :confirm 'ask
    :async t :timeout (+ cmacs-dbexplorer-tools-timeout 15)
    (cmacs-dbexplorer-tool-execute-async done connection sql))

  (cmacs-brigade-deftool db-export
    "Export the results of a query to a file as csv or json."
    ((connection string "Connection name from db-connections")
     (sql string "The SELECT statement whose results to export")
     (format string "csv or json")
     (path string "Absolute path to write"))
    :group 'database
    :destructive t
    :undo 'cmacs-brigade-undo-capture-db-export
    :confirm 'ask
    :async t :timeout (+ cmacs-dbexplorer-tools-export-timeout 15)
    ;; An exporter is named by a short symbol-shaped token; anything
    ;; else is a mistake worth reporting instead of forwarding.
    (unless (and (stringp format)
                 (string-match-p "\\`[a-z][a-z0-9-]*\\'" format))
      (error "db_export: 'format' must be an exporter name ([a-z][a-z0-9-]*)"))
    (cmacs-dbexplorer-tool-export-async done connection sql format path))

  ;; Opening and closing a saved connection.  These two were the last of
  ;; the family still served only by cmacs-mcp-tools-dbexplorer.c.
  ;;
  ;; `db-connect' is :async: a connect is a network handshake, and the
  ;; synchronous `cmacs-dbexplorer-tool-connect' waits for it on the
  ;; calling thread -- which for an RPC is the dispatch thread, and under
  ;; `emacs --gowl' the compositor's.  This one starts the connect and
  ;; answers from the connect hooks.  The reply is the same JSON.
  (cmacs-brigade-deftool db-connect
    "Open the saved connection named CONNECTION, so queries can run
against it.  Names come from db_connections; a connection URL is not
accepted.  Already-open connections are left alone."
    ((connection string "Saved connection name from db_connections"))
    :group 'database
    :async t
    :timeout 60
    (cmacs-dbexplorer-tools--connect-async connection done))

  (cmacs-brigade-deftool db-disconnect
    "Close the connection named CONNECTION, releasing its database handle
and dropping its cached schema.  The saved definition survives, so
db_connect brings it back."
    ((connection string "Saved connection name from db_connections"))
    :group 'database
    (cmacs-dbexplorer-tools--check-name connection)
    (cmacs-dbexplorer-tool-disconnect connection))

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
