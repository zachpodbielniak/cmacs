;;; cmacs-dbexplorer.el --- Database explorer entry points and plumbing  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The one file that talks to C, and the one file that touches secrets.
;;
;; Two design decisions are embodied here and nowhere else.
;;
;; First, the C layer offers exactly one stream callback and one
;; connection-state callback for the whole session.  A view that installed
;; its own would take the other views' events with it, and the second view
;; to load would silently win.  So this file installs both, once, and fans
;; the events out: stream payloads to a per-stream handler kept in a hash
;; table, connection state to the model's abnormal hook.  Views listen to
;; the hook; nothing but this file calls `cmacs-dbexplorer--set-*-callback'.
;;
;; Second, a password is resolved here, at the moment of connecting, and is
;; never stored in a struct, a buffer, a defcustom or a message.  The
;; configured URL carries a host, a user and a port; auth-source answers
;; with the secret; the two are joined into a URL that is handed straight
;; to C and then dropped.  `:inline-password' opts out of that for a
;; throwaway local database, and says so loudly in the docstring, because
;; the cost is a plaintext credential living in a config file.
;;
;; Everything asynchronous funnels through `cmacs-dbexplorer-query' and
;; `cmacs-dbexplorer-execute', which turn the C stream into a
;; `cmacs-dbexplorer-result' and announce it on the model's hooks.  A view
;; that wants rows asks for them here and waits to be told, rather than
;; driving the primitives itself -- which is what keeps a second view from
;; having to reimplement batching, truncation and error reporting.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-dbexplorer-model)
(require 'auth-source)
(require 'url-parse)

;; The primitives.  They may be absent from a build that was configured
;; without the subsystem, which is what `cmacs-dbexplorer--need' is for.
(declare-function cmacs-dbexplorer--connect-async
                  "src/cmacs-dbexplorer-defuns.c" (url read-only cb))
(declare-function cmacs-dbexplorer--disconnect
                  "src/cmacs-dbexplorer-defuns.c" (handle))
(declare-function cmacs-dbexplorer--connection-list
                  "src/cmacs-dbexplorer-defuns.c" ())
(declare-function cmacs-dbexplorer--set-read-only
                  "src/cmacs-dbexplorer-defuns.c" (handle flag))
(declare-function cmacs-dbexplorer--set-state-callback
                  "src/cmacs-dbexplorer-defuns.c" (fn))
(declare-function cmacs-dbexplorer--set-stream-callback
                  "src/cmacs-dbexplorer-defuns.c" (fn))
(declare-function cmacs-dbexplorer--schemas-async
                  "src/cmacs-dbexplorer-defuns.c" (handle cb))
(declare-function cmacs-dbexplorer--tables-async
                  "src/cmacs-dbexplorer-defuns.c" (handle schema cb))
(declare-function cmacs-dbexplorer--table-info-async
                  "src/cmacs-dbexplorer-defuns.c" (handle schema table cb))
(declare-function cmacs-dbexplorer--query-async
                  "src/cmacs-dbexplorer-defuns.c" (handle sql params options))
(declare-function cmacs-dbexplorer--execute-async
                  "src/cmacs-dbexplorer-defuns.c" (handle sql params cb))
(declare-function cmacs-dbexplorer--cancel
                  "src/cmacs-dbexplorer-defuns.c" (stream-id))
(declare-function cmacs-dbexplorer--begin-async
                  "src/cmacs-dbexplorer-defuns.c" (handle cb))
(declare-function cmacs-dbexplorer--commit-async
                  "src/cmacs-dbexplorer-defuns.c" (handle cb))
(declare-function cmacs-dbexplorer--rollback-async
                  "src/cmacs-dbexplorer-defuns.c" (handle savepoint cb))
(declare-function cmacs-dbexplorer--savepoint-async
                  "src/cmacs-dbexplorer-defuns.c" (handle name cb))
(declare-function cmacs-dbexplorer--apply-edits-async
                  "src/cmacs-dbexplorer-defuns.c" (handle ops cb))
(declare-function cmacs-dbexplorer--export-async
                  "src/cmacs-dbexplorer-defuns.c" (handle sql format path options))
(declare-function cmacs-dbexplorer--quote-identifier
                  "src/cmacs-dbexplorer-defuns.c" (handle name))


;;;; Customization ------------------------------------------------------

(defgroup cmacs-dbexplorer nil
  "Browse and edit SQL databases inside cmacs."
  :group 'cmacs
  :prefix "cmacs-dbexplorer-")

(defcustom cmacs-dbexplorer-unicode 'auto
  "Whether the explorer draws with Unicode glyphs.
`auto' asks the display whether it can show them."
  :type '(choice (const auto) (const t) (const nil))
  :group 'cmacs-dbexplorer)

(defconst cmacs-dbexplorer--glyphs
  '((null      . ("∅" . "NULL"))
    (ellipsis  . ("…" . "..."))
    (expanded  . ("▾" . "-"))
    (collapsed . ("▸" . "+"))
    (leaf      . ("·" . " "))
    (staged    . ("*" . "*"))
    (deleted   . ("-" . "-"))
    (inserted  . ("+" . "+"))
    (more      . ("⋯" . "..."))
    (rule      . ("─" . "-")))
  "Display glyphs, Unicode first and ASCII second.

Every glyph has a twin because these buffers are used over ssh in a
terminal whose coding system cannot render the first column, and a table
whose ellipsis is a question mark in a box is worse than one that says
`...'.")

(defun cmacs-dbexplorer-unicode-p ()
  "Return non-nil when the explorer should draw Unicode glyphs."
  (pcase cmacs-dbexplorer-unicode
    ('auto (and (char-displayable-p ?∅) t))
    (value value)))

(defun cmacs-dbexplorer-glyph (name)
  "Return the glyph called NAME for the current display."
  (let ((pair (alist-get name cmacs-dbexplorer--glyphs)))
    (if (cmacs-dbexplorer-unicode-p) (car pair) (cdr pair))))

(defcustom cmacs-dbexplorer-connections nil
  "Saved database connections, as an alist of NAME to a plist.

NAME is a string and is the identity the whole explorer uses; it is what
appears in buffer names and what `cmacs-dbexplorer-connect' completes
over.  The plist takes:

  :url              the connection URL, e.g.
                    \"postgresql://zach@db.example:5432/app\" or
                    \"sqlite:///home/zach/notes.db\"
  :read-only        non-nil to refuse every write on this connection
  :auto-connect     non-nil to connect when the workbench opens
  :inline-password  non-nil when :url already carries its own password

Leave the password OUT of :url.  A URL with a user, a host and no
password is completed from auth-source at connect time -- the secret is
spliced in on the way to C and is not kept anywhere afterwards -- so the
netrc or authinfo.gpg entry stays the only copy.  A matching entry looks
like:

  machine db.example login zach port 5432 password s3cret

:inline-password t is the escape hatch for a throwaway local database
that is not worth an auth-source entry.  Understand what it costs: the
password then lives in plain text in whichever file sets this variable,
it is readable by anything that can read your configuration, and it will
be in the backup of that file too.  Do not use it for anything you would
mind losing.

Note that `cmacs-dbexplorer-connections' is also a function, which
returns the connections that are live right now.  The two do not
collide: Lisp keeps a symbol's value and its function separately, and
naming both after the same thing is what the rest of the prefix does."
  :type '(alist :key-type (string :tag "Name")
                :value-type (plist :tag "Settings"))
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-page-size 500
  "How many rows one page holds.

One more than this is always asked for, and the extra row is shown as a
truncation indicator rather than as data -- so \"there is another page\"
is something the database said, not something guessed from a page that
happened to come back full.  It also caps an ad-hoc statement, which is
the difference between a mistyped join and a wedged editor."
  :type 'integer
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-connect-hook nil
  "Functions run with the connection struct after it opens."
  :type 'hook
  :group 'cmacs-dbexplorer)


;;;; Faces --------------------------------------------------------------

;; Every face inherits.  A literal colour here would look deliberate in
;; the theme it was picked under and illegible in every other one, and
;; these buffers are read in a terminal as often as under pgtk.

(defface cmacs-dbexplorer-header '((t :inherit bold))
  "Face for column headers and section titles."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-null '((t :inherit shadow))
  "Face for a SQL NULL.

The glyph alone is not enough: a column can legitimately contain the
string \"NULL\", and telling the two apart is the difference between a
missing value and a typo someone committed."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-staged '((t :inherit diff-changed))
  "Face for a cell holding a staged, uncommitted value."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-staged-delete
  '((t :inherit diff-removed :strike-through t))
  "Face for a row staged for deletion."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-staged-insert '((t :inherit diff-added))
  "Face for a row staged for insertion."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-immediate '((t :inherit error))
  "Face for the indicator that edits are written straight through."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-read-only '((t :inherit warning))
  "Face for the indicator that a connection refuses writes."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-type '((t :inherit font-lock-type-face))
  "Face for a column's SQL type."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-table '((t :inherit font-lock-function-name-face))
  "Face for a table or view name."
  :group 'cmacs-dbexplorer)

(defface cmacs-dbexplorer-key '((t :inherit font-lock-constant-face))
  "Face for a primary-key or foreign-key column."
  :group 'cmacs-dbexplorer)


;;;; Primitives ---------------------------------------------------------

(defun cmacs-dbexplorer--need (symbol)
  "Signal unless the primitive SYMBOL exists in this build.

`cmacs-dbexplorer--require' answers \"was the subsystem compiled in\",
which is a different question from \"does this particular primitive
exist\" -- and the second one is the one that produces an unreadable
`void-function' backtrace when the answer is no."
  (cmacs-dbexplorer--require)
  (unless (fboundp symbol)
    (user-error "cmacs-dbexplorer: this build has no %s primitive" symbol)))

(defun cmacs-dbexplorer--reply-error (reply)
  "Return REPLY's error message, or nil.

Errors arrive inside the reply rather than as a signal, so every callback
has to look for one; forgetting to is how a failed query renders as an
empty table."
  (and (consp reply) (alist-get :error reply)))

(defun cmacs-dbexplorer-resolve (connection)
  "Return CONNECTION as a struct, accepting a name or a struct."
  (cond
   ((cmacs-dbexplorer-connection-p connection) connection)
   ((stringp connection) (cmacs-dbexplorer-connection connection))
   (t nil)))

(defun cmacs-dbexplorer--handle (connection)
  "Return the live C handle for CONNECTION, or signal."
  (let ((connection (cmacs-dbexplorer-resolve connection)))
    (unless (cmacs-dbexplorer-connection-open-p connection)
      (user-error "cmacs-dbexplorer: no open connection%s"
                  (if connection
                      (format " called %s"
                              (cmacs-dbexplorer-connection-name connection))
                    "")))
    (cmacs-dbexplorer-connection-handle connection)))

(defun cmacs-dbexplorer-quote (connection name)
  "Return NAME quoted as an identifier in CONNECTION's dialect.

Falls back to standard double quoting when there is no open connection to
ask -- which happens in a review buffer describing edits against a
connection that has since closed, and in batch.  The fallback is for
display and for building a statement the database is about to re-parse
anyway; it is never the last word on quoting, because only the dialect
knows whether it wants backticks."
  (let* ((connection (cmacs-dbexplorer-resolve connection))
         (handle (and connection
                      (cmacs-dbexplorer-connection-open-p connection)
                      (cmacs-dbexplorer-connection-handle connection))))
    (if (and handle (fboundp 'cmacs-dbexplorer--quote-identifier))
        (cmacs-dbexplorer--quote-identifier handle name)
      (concat "\"" (replace-regexp-in-string "\"" "\"\"" (or name "")) "\""))))

(defun cmacs-dbexplorer-qualified-name (connection schema table)
  "Return TABLE in SCHEMA, quoted for CONNECTION."
  (if (and schema (not (string-empty-p schema)))
      (concat (cmacs-dbexplorer-quote connection schema) "."
              (cmacs-dbexplorer-quote connection table))
    (cmacs-dbexplorer-quote connection table)))


;;;; Credentials --------------------------------------------------------

(defun cmacs-dbexplorer--url-port (url)
  "Return URL's port as a string, or nil.

`url-port' fills in the scheme's default, which is meaningless for a
database URL and would make an auth-source entry with no port stop
matching; only a port that was actually written counts."
  (let ((spec (url-portspec url)))
    (and spec (number-to-string spec))))

(defun cmacs-dbexplorer--auth-secret (host user port)
  "Return the auth-source secret for HOST, USER and PORT, or nil."
  (when host
    (let* ((found (car (auth-source-search :host host :user user :port port
                                           :max 1 :require '(:secret))))
           (secret (and found (plist-get found :secret))))
      (cond ((functionp secret) (funcall secret))
            ((stringp secret) secret)))))

(defun cmacs-dbexplorer-resolve-url (url &optional inline-password)
  "Return URL with a password filled in from auth-source.

URL is returned unchanged when INLINE-PASSWORD is non-nil, when it
already carries a password, or when it names no host to look one up by --
which covers every `sqlite://' URL, where there is no credential to find.

The secret is percent-encoded on the way in, because a password is
allowed to contain the characters a URL uses as punctuation and an
unencoded `@' or `/' silently reparses into a different host."
  (let ((parsed (url-generic-parse-url url)))
    (cond
     (inline-password url)
     ((url-password parsed) url)
     ((null (url-host parsed)) url)
     (t
      (let ((secret (cmacs-dbexplorer--auth-secret
                     (url-host parsed) (url-user parsed)
                     (cmacs-dbexplorer--url-port parsed))))
        (if (null secret)
            url
          (setf (url-password parsed) (url-hexify-string secret))
          (url-recreate-url parsed)))))))

(defun cmacs-dbexplorer-redact-url (url)
  "Return URL with any password replaced by a fixed marker.

Used for everything that might end up on screen or in *Messages*: the
point of resolving credentials late is lost if the resolved URL is then
echoed."
  (let ((parsed (ignore-errors (url-generic-parse-url url))))
    (if (and parsed (url-password parsed))
        (progn (setf (url-password parsed) "***")
               (url-recreate-url parsed))
      url)))


;;;; Connection specs ---------------------------------------------------

(defun cmacs-dbexplorer-connection-specs ()
  "Return every configured connection as (NAME . PLIST).

The defcustom first, then whatever the registered connection sources
enumerate, so a source can supply connections a config never listed --
a .pg_service.conf, a project file, a secrets manager -- and the two
paths reach the explorer identically."
  (let ((specs (copy-sequence cmacs-dbexplorer-connections)))
    (dolist (entry (cmacs-dbexplorer-connection-sources))
      (let ((enumerate (plist-get (cdr entry) :enumerate)))
        (condition-case err
            (dolist (spec (funcall enumerate))
              (unless (assoc (car spec) specs)
                (setq specs (append specs (list spec)))))
          (error
           (message "cmacs-dbexplorer: connection source %s failed: %s"
                    (car entry) (error-message-string err))))))
    specs))

(defun cmacs-dbexplorer-connection-spec (name)
  "Return the configured connection spec called NAME, or nil."
  (cdr (assoc name (cmacs-dbexplorer-connection-specs))))

(defun cmacs-dbexplorer-read-connection-name (prompt &optional live-only)
  "Read a connection name with PROMPT.

With LIVE-ONLY, only connections that are open are offered."
  (let* ((live (mapcar #'cmacs-dbexplorer-connection-name
                       (cmacs-dbexplorer-connections)))
         (names (if live-only live
                  (delete-dups
                   (append live
                           (mapcar #'car (cmacs-dbexplorer-connection-specs)))))))
    (unless names
      (user-error "cmacs-dbexplorer: no connections %s"
                  (if live-only "are open" "are configured")))
    (if (= 1 (length names))
        (car names)
      (completing-read prompt names nil t nil nil (car names)))))


;;;; The two C callbacks ------------------------------------------------

(defvar cmacs-dbexplorer--streams (make-hash-table :test 'eql)
  "Live streams, keyed by the integer id the C layer issued.

Each value is a plist holding the accumulating result and the callbacks
that asked for it.")

(defvar cmacs-dbexplorer--callbacks-installed nil
  "Non-nil once the single pair of C callbacks has been installed.")

(defun cmacs-dbexplorer--normalize-event (args)
  "Return ARGS as a payload list.

The state callback is documented as receiving one list whose car is a
keyword, the same shape stream payloads have; accepting a spread argument
list as well costs one line and turns a contract mismatch into something
that works rather than something that silently stops updating the
connection list."
  (if (and (= 1 (length args)) (consp (car args)))
      (car args)
    args))

(defun cmacs-dbexplorer--state-callback (&rest args)
  "Handle a connection-state event from C.

The event names a handle, not a name, so the connection it refers to is
found by handle; a struct whose handle was cleared by a disconnect is no
longer a candidate, which is what stops a stale event from reopening a
connection the user closed."
  (let* ((event (cmacs-dbexplorer--normalize-event args))
         (handle (nth 1 event))
         (state (nth 2 event)))
    (dolist (connection (cmacs-dbexplorer-connections))
      (when (eql handle (cmacs-dbexplorer-connection-handle connection))
        (setf (cmacs-dbexplorer-connection-state connection)
              (pcase state
                ('open 'idle)
                ('closed 'closed)
                ('busy 'busy)
                (other other)))
        (when (eq state 'closed)
          (setf (cmacs-dbexplorer-connection-handle connection) nil))
        (cmacs-dbexplorer--notify-connection connection)))))

(defun cmacs-dbexplorer--ensure-callbacks ()
  "Install the session's stream and state callbacks, once."
  (unless cmacs-dbexplorer--callbacks-installed
    (when (and (fboundp 'cmacs-dbexplorer--set-stream-callback)
               (fboundp 'cmacs-dbexplorer--set-state-callback))
      (cmacs-dbexplorer--set-stream-callback
       #'cmacs-dbexplorer--stream-callback)
      (cmacs-dbexplorer--set-state-callback
       #'cmacs-dbexplorer--state-callback)
      (setq cmacs-dbexplorer--callbacks-installed t))))

(defun cmacs-dbexplorer--stream-callback (id payload)
  "Route PAYLOAD to the handler registered for stream ID.

A payload for an unknown id is dropped rather than signalled: a stream
cancelled while a batch was already in flight produces exactly that, and
erroring inside a C callback is worse than losing rows nobody is waiting
for."
  (let ((stream (gethash id cmacs-dbexplorer--streams)))
    (when stream
      (condition-case err
          (cmacs-dbexplorer--stream-event id stream payload)
        (error
         (remhash id cmacs-dbexplorer--streams)
         (message "cmacs-dbexplorer: stream %s failed: %s"
                  id (error-message-string err)))))))

(defun cmacs-dbexplorer--stream-event (id stream payload)
  "Apply PAYLOAD to STREAM, the state of stream ID."
  (pcase (car payload)
    (:meta
     (plist-put stream :columns (nth 1 payload)))
    (:rows
     ;; Batches are consed on and reversed once at the end.  Appending
     ;; each batch to a growing vector is quadratic, and a browse of a
     ;; wide table arrives in a lot of batches.
     (plist-put stream :batches
                (cons (nth 1 payload) (plist-get stream :batches))))
    (:progress
     (let ((fn (plist-get stream :on-progress)))
       (when fn (funcall fn (nth 1 payload)))))
    (:error
     (remhash id cmacs-dbexplorer--streams)
     (cmacs-dbexplorer--stream-failed stream (nth 1 payload)))
    (:end
     (remhash id cmacs-dbexplorer--streams)
     (cmacs-dbexplorer--stream-finished stream (cdr payload)))))

(defun cmacs-dbexplorer--stream-rows (stream)
  "Return STREAM's accumulated rows as one vector."
  (let ((batches (nreverse (plist-get stream :batches))))
    (apply #'vconcat (mapcar (lambda (batch) (append batch nil)) batches))))

(defun cmacs-dbexplorer--stream-failed (stream message)
  "Report that STREAM failed with MESSAGE."
  (let ((fn (plist-get stream :on-error)))
    (cmacs-dbexplorer--run-hook
     'cmacs-dbexplorer-result-received-functions
     (list :connection (plist-get stream :connection)
           :result nil :error message :sql (plist-get stream :sql)))
    (if fn
        (funcall fn message)
      (message "cmacs-dbexplorer: %s" message))))

(defun cmacs-dbexplorer--stream-finished (stream end)
  "Build STREAM's result from END and hand it to its caller."
  (let ((result (cmacs-dbexplorer-result-create
                 :connection-name (plist-get stream :connection)
                 :sql (plist-get stream :sql)
                 :columns (or (plist-get stream :columns) (vector))
                 :rows (cmacs-dbexplorer--stream-rows stream)
                 :truncated (plist-get end :truncated)
                 :elapsed-ms (plist-get end :elapsed-ms)
                 :table (plist-get stream :table)
                 :schema (plist-get stream :schema)
                 :primary-key (plist-get stream :primary-key)
                 :offset (or (plist-get stream :offset) 0))))
    (cmacs-dbexplorer--run-hook
     'cmacs-dbexplorer-result-received-functions
     (list :connection (plist-get stream :connection)
           :result result :error nil :sql (plist-get stream :sql)))
    (let ((fn (plist-get stream :on-result)))
      (when fn (funcall fn result)))))


;;;; Running statements -------------------------------------------------

(cl-defun cmacs-dbexplorer-query (connection sql
                                             &key params options table schema
                                             primary-key offset on-result
                                             on-error on-progress)
  "Run SQL on CONNECTION and return the stream id.

PARAMS are bound values for the statement's placeholders and OPTIONS is
the C option plist (`:max-rows' and friends).  TABLE, SCHEMA and
PRIMARY-KEY describe where the rows came from and are copied into the
result; supplying them is what makes the result editable, so they are
passed only when the rows really are one table's, never for a join.
OFFSET is the row number the first row carries, for a paged browse.

ON-RESULT is called with the `cmacs-dbexplorer-result', ON-ERROR with a
message string, ON-PROGRESS with a percentage.  The
`cmacs-dbexplorer-result-received-functions' hook fires either way, so a
view that only wants to know when anything happened can listen there
instead of passing callbacks."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--query-async)
  (cmacs-dbexplorer--ensure-callbacks)
  (let* ((connection (cmacs-dbexplorer-resolve connection))
         (handle (cmacs-dbexplorer--handle connection))
         (id (cmacs-dbexplorer--query-async handle sql params options)))
    ;; Registered after the call, which is safe because payloads are
    ;; delivered through the event loop: nothing can arrive while this
    ;; function is still on the stack.
    (puthash id (list :connection (cmacs-dbexplorer-connection-name connection)
                      :sql sql :table table :schema schema
                      :primary-key primary-key :offset offset
                      :on-result on-result :on-error on-error
                      :on-progress on-progress
                      :columns nil :batches nil)
             cmacs-dbexplorer--streams)
    id))

(cl-defun cmacs-dbexplorer-execute (connection sql &key params on-done on-error)
  "Run SQL on CONNECTION for its effect rather than its rows.

ON-DONE is called with the reply alist, which carries `:rows-affected'
and `:last-insert-rowid'.  ON-ERROR is called with the message when the
statement failed; without one the message is simply shown."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--execute-async)
  (cmacs-dbexplorer--ensure-callbacks)
  (let ((handle (cmacs-dbexplorer--handle connection)))
    (cmacs-dbexplorer--execute-async
     handle sql params
     (lambda (reply)
       (let ((error-message (cmacs-dbexplorer--reply-error reply)))
         (cond
          ((and error-message on-error) (funcall on-error error-message))
          (error-message (message "cmacs-dbexplorer: %s" error-message))
          (on-done (funcall on-done reply))))))))

(defun cmacs-dbexplorer-cancel (id)
  "Cancel the stream called ID and forget its handler."
  (when id
    (remhash id cmacs-dbexplorer--streams)
    (when (fboundp 'cmacs-dbexplorer--cancel)
      (cmacs-dbexplorer--cancel id))))


;;;; Transactions -------------------------------------------------------

(defun cmacs-dbexplorer--transaction-reply (connection in-transaction verb)
  "Return a callback marking CONNECTION as IN-TRANSACTION, reporting VERB."
  (lambda (reply)
    (let ((error-message (cmacs-dbexplorer--reply-error reply)))
      (if error-message
          (message "cmacs-dbexplorer: %s failed: %s" verb error-message)
        (setf (cmacs-dbexplorer-connection-in-transaction connection)
              in-transaction)
        (cmacs-dbexplorer--notify-connection connection)
        (message "cmacs-dbexplorer: %s" verb)))))

(defun cmacs-dbexplorer-begin (connection)
  "Open a transaction on CONNECTION."
  (interactive (list (cmacs-dbexplorer-read-connection-name "Connection: " t)))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--begin-async)
  (let ((connection (cmacs-dbexplorer-resolve connection)))
    (cmacs-dbexplorer--begin-async
     (cmacs-dbexplorer--handle connection)
     (cmacs-dbexplorer--transaction-reply connection t "BEGIN"))))

(defun cmacs-dbexplorer-commit (connection)
  "Commit CONNECTION's transaction."
  (interactive (list (cmacs-dbexplorer-read-connection-name "Connection: " t)))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--commit-async)
  (let ((connection (cmacs-dbexplorer-resolve connection)))
    (cmacs-dbexplorer--commit-async
     (cmacs-dbexplorer--handle connection)
     (cmacs-dbexplorer--transaction-reply connection nil "COMMIT"))))

(defun cmacs-dbexplorer-rollback (connection &optional savepoint)
  "Roll CONNECTION back, to SAVEPOINT when one is named."
  (interactive
   (list (cmacs-dbexplorer-read-connection-name "Connection: " t)
         (let ((name (read-string "Savepoint (empty for the whole transaction): ")))
           (unless (string-empty-p name) name))))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--rollback-async)
  (let ((connection (cmacs-dbexplorer-resolve connection)))
    (cmacs-dbexplorer--rollback-async
     (cmacs-dbexplorer--handle connection) savepoint
     ;; A rollback to a savepoint leaves the transaction open; only a
     ;; whole-transaction rollback ends it.
     (cmacs-dbexplorer--transaction-reply
      connection (and savepoint t)
      (if savepoint (format "ROLLBACK TO %s" savepoint) "ROLLBACK")))))

(defun cmacs-dbexplorer-savepoint (connection name)
  "Create savepoint NAME on CONNECTION."
  (interactive
   (list (cmacs-dbexplorer-read-connection-name "Connection: " t)
         (read-string "Savepoint name: " "sp1")))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--savepoint-async)
  (let ((connection (cmacs-dbexplorer-resolve connection)))
    (cmacs-dbexplorer--savepoint-async
     (cmacs-dbexplorer--handle connection) name
     (cmacs-dbexplorer--transaction-reply
      connection t (format "SAVEPOINT %s" name)))))


;;;; Connecting ---------------------------------------------------------

(defun cmacs-dbexplorer--connected (name read-only reply)
  "Record a connection called NAME from REPLY, or report its failure.
READ-ONLY is the flag the connection was opened with."
  (let ((error-message (cmacs-dbexplorer--reply-error reply)))
    (if error-message
        (progn
          (cmacs-dbexplorer--drop-connection name)
          (message "cmacs-dbexplorer: %s: %s" name error-message))
      (let ((connection (cmacs-dbexplorer-connection-create
                         :name name
                         :handle (alist-get :handle reply)
                         :dialect (alist-get :dialect reply)
                         :state 'idle
                         :read-only read-only)))
        (cmacs-dbexplorer--put-connection connection)
        (run-hook-with-args 'cmacs-dbexplorer-connect-hook connection)
        (message "cmacs-dbexplorer: %s connected (%s%s)" name
                 (or (cmacs-dbexplorer-connection-dialect connection) "?")
                 (if read-only ", read-only" ""))))))

;;;###autoload
(defun cmacs-dbexplorer-connect (&optional name)
  "Open the saved connection called NAME."
  (interactive)
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--connect-async)
  (let* ((name (or name (cmacs-dbexplorer-read-connection-name "Connect: ")))
         (spec (cmacs-dbexplorer-connection-spec name)))
    (unless spec
      (user-error "cmacs-dbexplorer: %s is not a configured connection" name))
    (cmacs-dbexplorer--connect-with-spec name spec)))

(defun cmacs-dbexplorer--connect-with-spec (name spec)
  "Connect NAME using SPEC, resolving its password on the way."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--connect-async)
  (cmacs-dbexplorer--ensure-callbacks)
  (let ((url (plist-get spec :url))
        (read-only (plist-get spec :read-only)))
    (unless url
      (user-error "cmacs-dbexplorer: %s has no :url" name))
    (when (cmacs-dbexplorer-connection-open-p (cmacs-dbexplorer-connection name))
      (user-error "cmacs-dbexplorer: %s is already connected" name))
    (let ((connection (cmacs-dbexplorer-connection-create
                       :name name :state 'connecting :read-only read-only)))
      (cmacs-dbexplorer--put-connection connection))
    (cmacs-dbexplorer--connect-async
     (cmacs-dbexplorer-resolve-url url (plist-get spec :inline-password))
     read-only
     (lambda (reply) (cmacs-dbexplorer--connected name read-only reply)))))

;;;###autoload
(defun cmacs-dbexplorer-connect-url (url &optional name read-only)
  "Connect to URL under NAME, refusing writes when READ-ONLY.

Interactively the name defaults to the URL's database, which is what you
would have called it anyway."
  (interactive
   (let* ((url (read-string "Database URL: "))
          (default (cmacs-dbexplorer--default-name url)))
     (list url
           (read-string (format "Name (%s): " default) nil nil default)
           (y-or-n-p "Read-only? "))))
  (cmacs-dbexplorer--connect-with-spec
   (or name (cmacs-dbexplorer--default-name url))
   ;; No :inline-password: a URL typed at the prompt is resolved against
   ;; auth-source like any other, and one that already carries a password
   ;; is left alone by the resolver anyway.
   (list :url url :read-only read-only)))

(defun cmacs-dbexplorer--default-name (url)
  "Return a reasonable connection name for URL."
  (let* ((parsed (ignore-errors (url-generic-parse-url url)))
         (file (and parsed (url-filename parsed)))
         (base (and file (file-name-base file))))
    (if (and base (not (string-empty-p base)))
        base
      (or (and parsed (url-host parsed)) "db"))))

;;;###autoload
(defun cmacs-dbexplorer-disconnect (&optional name)
  "Close the connection called NAME."
  (interactive)
  (let* ((name (or name (cmacs-dbexplorer-read-connection-name "Disconnect: " t)))
         (connection (cmacs-dbexplorer-connection name)))
    (unless connection
      (user-error "cmacs-dbexplorer: %s is not connected" name))
    (when (and (cmacs-dbexplorer-connection-handle connection)
               (fboundp 'cmacs-dbexplorer--disconnect))
      (cmacs-dbexplorer--disconnect
       (cmacs-dbexplorer-connection-handle connection)))
    (cmacs-dbexplorer--drop-connection name)
    (message "cmacs-dbexplorer: %s closed" name)))

;;;###autoload
(defun cmacs-dbexplorer-reconnect (&optional name)
  "Close and reopen the connection called NAME.

The handle changes, so anything holding one is stale afterwards; the
model keys on the name for exactly this reason."
  (interactive)
  (let* ((name (or name (cmacs-dbexplorer-read-connection-name "Reconnect: ")))
         (connection (cmacs-dbexplorer-connection name))
         (spec (or (cmacs-dbexplorer-connection-spec name)
                   (user-error
                    "cmacs-dbexplorer: %s has no saved settings to reopen with"
                    name))))
    (when connection
      (cmacs-dbexplorer-disconnect name))
    (cmacs-dbexplorer--connect-with-spec name spec)))

(defun cmacs-dbexplorer-toggle-read-only (&optional name)
  "Flip whether the connection called NAME accepts writes."
  (interactive)
  (let* ((name (or name (cmacs-dbexplorer-read-connection-name "Connection: " t)))
         (connection (cmacs-dbexplorer-connection name))
         (flag (not (cmacs-dbexplorer-connection-read-only connection))))
    (cmacs-dbexplorer--need 'cmacs-dbexplorer--set-read-only)
    (cmacs-dbexplorer--set-read-only (cmacs-dbexplorer--handle connection) flag)
    (setf (cmacs-dbexplorer-connection-read-only connection) flag)
    (cmacs-dbexplorer--notify-connection connection)
    (message "cmacs-dbexplorer: %s is now %s" name
             (if flag "read-only" "writable"))))

(defun cmacs-dbexplorer-when-connected (name function)
  "Call FUNCTION with the connection called NAME once it is open.

Connecting is asynchronous, so a command that means \"connect and then
show me the tables\" cannot look the connection up on the next line.
The watcher removes itself, and only fires for its own name, so two of
these outstanding at once do not cross."
  (let ((connection (cmacs-dbexplorer-connection name)))
    (if (cmacs-dbexplorer-connection-open-p connection)
        (funcall function connection)
      (letrec ((watch
                (lambda (opened)
                  (when (equal name (cmacs-dbexplorer-connection-name opened))
                    (remove-hook 'cmacs-dbexplorer-connect-hook watch)
                    (funcall function opened)))))
        (add-hook 'cmacs-dbexplorer-connect-hook watch)))))

(defun cmacs-dbexplorer-connect-auto ()
  "Open every configured connection marked `:auto-connect'."
  (dolist (spec (cmacs-dbexplorer-connection-specs))
    (when (and (plist-get (cdr spec) :auto-connect)
               (not (cmacs-dbexplorer-connection-open-p
                     (cmacs-dbexplorer-connection (car spec)))))
      (condition-case err
          (cmacs-dbexplorer--connect-with-spec (car spec) (cdr spec))
        (error (message "cmacs-dbexplorer: %s: %s" (car spec)
                        (error-message-string err)))))))


;;;; The current connection ---------------------------------------------

(defvar-local cmacs-dbexplorer--connection-name nil
  "The connection this buffer belongs to.")

(defun cmacs-dbexplorer-buffer-connection ()
  "Return this buffer's connection struct, or nil."
  (and cmacs-dbexplorer--connection-name
       (cmacs-dbexplorer-connection cmacs-dbexplorer--connection-name)))

(defun cmacs-dbexplorer-buffer-connection-or-error ()
  "Return this buffer's connection, or signal if it is not open."
  (let ((connection (cmacs-dbexplorer-buffer-connection)))
    (unless (cmacs-dbexplorer-connection-open-p connection)
      (user-error "cmacs-dbexplorer: %s is not connected"
                  (or cmacs-dbexplorer--connection-name "this buffer")))
    connection))


;;;; Coalesced redraws --------------------------------------------------

(defcustom cmacs-dbexplorer-refresh-idle 0.15
  "Seconds of idle time before a dirty explorer buffer redraws."
  :type 'number
  :group 'cmacs-dbexplorer)

(defvar cmacs-dbexplorer--pending nil
  "Buffers waiting to be redrawn, as (BUFFER . FUNCTION).")

(defvar cmacs-dbexplorer--refresh-timer nil
  "The single idle timer that flushes `cmacs-dbexplorer--pending'.")

(defun cmacs-dbexplorer-mark-dirty (buffer function)
  "Arrange for FUNCTION to redraw BUFFER once the display is idle.

Coalescing matters here for the same reason it does in the brigade
dashboard: rows arrive in batches and a connection can change state
several times a second, and redrawing per event means redrawing a
thousand-row table forty times to show the same thing.  One timer serves
every explorer buffer, and a buffer already queued is not queued twice."
  (unless (assq buffer cmacs-dbexplorer--pending)
    (push (cons buffer function) cmacs-dbexplorer--pending))
  (unless cmacs-dbexplorer--refresh-timer
    (setq cmacs-dbexplorer--refresh-timer
          (run-with-idle-timer cmacs-dbexplorer-refresh-idle nil
                               #'cmacs-dbexplorer--flush-refresh))))

(defun cmacs-dbexplorer--flush-refresh ()
  "Redraw every buffer marked dirty, unless a prompt is open.

A redraw erases the buffer, which moves point out from under whatever
command is reading its argument at the minibuffer -- so answering a
prompt would finish with \"no row here\".  The work is deferred rather
than dropped: nothing is lost, because each redraw rebuilds from the
model anyway."
  (setq cmacs-dbexplorer--refresh-timer nil)
  (if (minibuffer-window-active-p (minibuffer-window))
      (when cmacs-dbexplorer--pending
        (setq cmacs-dbexplorer--refresh-timer
              (run-with-idle-timer cmacs-dbexplorer-refresh-idle nil
                                   #'cmacs-dbexplorer--flush-refresh)))
    (let ((pending cmacs-dbexplorer--pending))
      (setq cmacs-dbexplorer--pending nil)
      (dolist (entry pending)
        (let ((buffer (car entry)))
          ;; Only what someone can see: redrawing a buried table on every
          ;; batch is pure waste, and every view re-renders when shown.
          (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
            (with-current-buffer buffer
              (condition-case err
                  (funcall (cdr entry))
                (error (message "cmacs-dbexplorer: redraw failed: %s"
                                (error-message-string err)))))))))))


;;;; Leaving a view -----------------------------------------------------

(defvar cmacs-dbexplorer--saved-window-configuration nil
  "The window configuration the workbench replaced, or nil.

Kept here rather than in the workbench so that every view's `q' can
restore it without depending on the workbench being loaded.")

(defun cmacs-dbexplorer-quit ()
  "Close this view.

Inside the workbench that means putting back the window configuration it
replaced, because the workbench took the whole frame and quitting one of
its four windows would leave the other three."
  (interactive)
  (if cmacs-dbexplorer--saved-window-configuration
      (let ((configuration cmacs-dbexplorer--saved-window-configuration))
        (setq cmacs-dbexplorer--saved-window-configuration nil)
        (set-window-configuration configuration))
    (quit-window)))

(provide 'cmacs-dbexplorer)
;;; cmacs-dbexplorer.el ends here
