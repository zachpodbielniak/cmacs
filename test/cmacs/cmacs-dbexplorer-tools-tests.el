;;; cmacs-dbexplorer-tools-tests.el --- The database tool family on the capability table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-dbexplorer-tools.el is the database MCP tool family.
;; The C handlers these tools replaced were deleted once the registry
;; was published by every build with an MCP server.  What they promised
;; a client -- frozen from a real tools/list beforehand, in
;; test/cmacs/data/mcp-wire-schema.json -- is what the first test holds
;; the family to, through cmacs-wire-schema.el: each tool's name, its
;; parameters in order, their types and the required set.
;;
;; The rest is what the C handlers used to guarantee before calling in,
;; and the registry's tools are reached without passing through them: a
;; connection is named, never described by a URL; table, schema and
;; exporter names are plain tokens; writes are declared to the
;; confirmation policy.  And `db_connect' answers from the connect
;; hooks rather than waiting for the handshake.
;;
;; Everything runs against a private registry with the C mirror stubbed,
;; so nothing registered here reaches the MCP surface of the Emacs
;; running the tests.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)
;; Beside this file, and named by its place: `make check' compiles
;; and runs the tests with test/cmacs off `load-path', where a bare
;; `require' of a helper fails the whole file -- silently for the count
;; of failed tests, which then covers every file but this one.
(require 'cmacs-wire-schema
         (expand-file-name
          "cmacs-wire-schema"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

(require 'json)

(declare-function cmacs-dbexplorer-connection-create "cmacs-dbexplorer-model"
                  (&rest slots))
(declare-function cmacs-dbexplorer-available-p "cmacs-dbexplorer-model" ())

(defconst cmacs-dbexplorer-tools-tests--migrated
  '("db_connections" "db_connect" "db_disconnect" "db_query" "db_execute"
    "db_tables" "db_columns" "db_export")
  "The C tools cmacs-dbexplorer-tools.el provides: all of them.")

(defun cmacs-dbexplorer-tools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-dbexplorer-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defmacro cmacs-dbexplorer-tools-tests--with-family (&rest body)
  "Run BODY with a private registry holding only the dbexplorer family."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       (let ((load-prefer-newer t))
         (load (expand-file-name "lisp/cmacs/cmacs-dbexplorer-tools"
                                 (cmacs-dbexplorer-tools-tests--root))
               nil t))
       ,@body)))

(defun cmacs-dbexplorer-tools-tests--call (name json)
  "Start the tool NAME with JSON; return a cell that receives the reply.
The cell's car becomes (STATUS TEXT) when the tool settles."
  (let ((cell (list nil)))
    (cmacs-brigade-call-tool-async
     name json (lambda (status text) (setcar cell (list status text))))
    cell))


;;;; The family is the C family

(defun cmacs-dbexplorer-tools-tests--available-p ()
  "Non-nil when the family file can be loaded and registers its tools."
  (and (cmacs-dbexplorer-tools-tests--root)
       (require 'cmacs-dbexplorer-model nil t)
       (fboundp 'cmacs-dbexplorer-available-p)
       (cmacs-dbexplorer-available-p)))

(ert-deftest cmacs-dbexplorer-tools-test-family-matches-c ()
  "Every tool keeps its frozen name, parameters, types and required set."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (let ((c (cmacs-wire-schema-names "cmacs-mcp-tools-dbexplorer.c")))
      (should (equal (sort (copy-sequence c) #'string<)
                     (sort (copy-sequence
                            cmacs-dbexplorer-tools-tests--migrated)
                           #'string<)))
      (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                   (cmacs-capability-describe))
                           #'string<)
                     (sort (copy-sequence
                            cmacs-dbexplorer-tools-tests--migrated)
                           #'string<)))
      (dolist (name cmacs-dbexplorer-tools-tests--migrated)
        (cmacs-wire-schema-should-match name)))))

(ert-deftest cmacs-dbexplorer-tools-test-writes-are-gated ()
  "The writing tools are destructive, confirmed, and off D-Bus by default."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (dolist (name '("db_execute" "db_export"))
      (let ((entry (cmacs-capability-describe-tool name)))
        (ert-info (name)
          (should (plist-get entry :destructive))
          (should (eq (plist-get entry :confirm) 'ask))
          (should-not (memq 'dbus (plist-get entry :surfaces))))))
    (dolist (name '("db_connections" "db_connect" "db_disconnect" "db_query"
                    "db_tables" "db_columns"))
      (should-not (plist-get (cmacs-capability-describe-tool name)
                             :destructive)))
    ;; Asked for confirmation with nobody to ask: declined, not run.
    (let ((cmacs-brigade-auto-approve nil) (ran nil))
      (cl-letf (((symbol-function 'cmacs-dbexplorer-tool-execute-async)
                 (lambda (done &rest _) (setq ran t) (funcall done "{}"))))
        (should (eq (car (car (cmacs-dbexplorer-tools-tests--call
                               "db_execute"
                               "{\"connection\":\"main\",\"sql\":\"DELETE FROM t\"}")))
                    'error))
        (should-not ran)))))


;;;; Behaviour

(defmacro cmacs-dbexplorer-tools-tests--with-explorer (&rest body)
  "Run BODY with the explorer's connection machinery stubbed.
BODY sees `log' (a list of (FUNCTION . ARGS)), `live' (the connection
the registry reports for a name, or nil), `spec' (the saved definition,
or nil) and, after a connect was started, `opened' and `failed', the
two watchers `cmacs-dbexplorer-when-connected' was given."
  (declare (indent 0) (debug t))
  `(let ((log nil) (live nil) (spec '(:url "sqlite:///tmp/x.db"))
         (opened nil) (failed nil))
     (ignore log live spec opened failed)
     (cl-letf (((symbol-function 'cmacs-dbexplorer-tools--ensure)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-dbexplorer-connection)
                (lambda (&rest _) live))
               ((symbol-function 'cmacs-dbexplorer-connection-spec)
                (lambda (&rest _) spec))
               ((symbol-function 'cmacs-dbexplorer-when-connected)
                (lambda (name function &optional failure)
                  (push (list 'watch name) log)
                  (setq opened function failed failure)))
               ((symbol-function 'cmacs-dbexplorer-connect)
                (lambda (&rest args) (push (cons 'connect args) log) nil))
               ((symbol-function 'cmacs-dbexplorer-disconnect)
                (lambda (&rest args) (push (cons 'disconnect args) log) nil)))
       ,@body)))

(defun cmacs-dbexplorer-tools-tests--connection (name)
  "Return an open, read-only stand-in connection called NAME."
  (cmacs-dbexplorer-connection-create
   :name name :handle 7 :dialect "sqlite" :state 'open :read-only t))

(ert-deftest cmacs-dbexplorer-tools-test-connect-completes ()
  "`db_connect' starts the connect and answers when the connection opens."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (cmacs-dbexplorer-tools-tests--with-explorer
      (let ((reply (cmacs-dbexplorer-tools-tests--call
                    "db_connect" "{\"connection\":\"main\"}")))
        ;; Started, not answered: nothing waited for the handshake.
        (should-not (car reply))
        (should (equal (assq 'connect log) '(connect "main")))
        (should opened)
        (funcall opened (cmacs-dbexplorer-tools-tests--connection "main"))
        (should (eq (car (car reply)) 'ok))
        (should (equal (json-parse-string (cadr (car reply))
                                          :object-type 'alist
                                          :false-object :false)
                       '((name . "main") (dialect . "sqlite")
                         (read_only . t))))))
    ;; Already open: described and left alone.
    (cmacs-dbexplorer-tools-tests--with-explorer
      (setq live (cmacs-dbexplorer-tools-tests--connection "main"))
      (let ((reply (cmacs-dbexplorer-tools-tests--call
                    "db_connect" "{\"connection\":\"main\"}")))
        (should (eq (car (car reply)) 'ok))
        (should-not (assq 'connect log))))))

(ert-deftest cmacs-dbexplorer-tools-test-connect-fails ()
  "A refused connect is a failed call; a URL or an unknown name never connects."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (cmacs-dbexplorer-tools-tests--with-explorer
      (let ((reply (cmacs-dbexplorer-tools-tests--call
                    "db_connect" "{\"connection\":\"main\"}")))
        (funcall failed "main")
        (should (equal (car reply) '(error "could not connect to main")))))
    (cmacs-dbexplorer-tools-tests--with-explorer
      (let ((reply (car (cmacs-dbexplorer-tools-tests--call
                         "db_connect"
                         "{\"connection\":\"postgres://u:p@host/db\"}"))))
        (should (eq (car reply) 'error))
        (should (string-match-p "URLs are not accepted" (cadr reply)))
        ;; The refusal must not echo credentials back.
        (should-not (string-match-p "u:p@host" (cadr reply))))
      (setq spec nil)
      (let ((reply (car (cmacs-dbexplorer-tools-tests--call
                         "db_connect" "{\"connection\":\"nowhere\"}"))))
        (should (eq (car reply) 'error))
        (should (string-match-p "not a configured connection" (cadr reply))))
      (should-not (assq 'connect log)))))

(ert-deftest cmacs-dbexplorer-tools-test-disconnect ()
  "`db_disconnect' closes a named connection and says so as JSON."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (cmacs-dbexplorer-tools-tests--with-explorer
      (let ((reply (car (cmacs-dbexplorer-tools-tests--call
                         "db_disconnect" "{\"connection\":\"main\"}"))))
        (should (eq (car reply) 'ok))
        (should (equal (json-parse-string (cadr reply) :object-type 'alist)
                       '((name . "main") (state . "closed"))))
        (should (equal (assq 'disconnect log) '(disconnect "main"))))
      (setq log nil)
      (should (eq (car (car (cmacs-dbexplorer-tools-tests--call
                             "db_disconnect" "{\"connection\":\"a b; c\"}")))
                  'error))
      (should-not log))))

(ert-deftest cmacs-dbexplorer-tools-test-names-are-validated ()
  "Identifier and exporter names are checked here, as the C handlers checked them."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (let ((log nil))
      ;; The tools are :async and call the `-async' entry points, whose
      ;; first argument is the DONE callback.
      (cl-letf (((symbol-function 'cmacs-dbexplorer-tool-query-async)
                 (lambda (done &rest args)
                   (push (cons 'query args) log) (funcall done "{}")))
                ((symbol-function 'cmacs-dbexplorer-tool-tables-async)
                 (lambda (done &rest args)
                   (push (cons 'tables args) log) (funcall done "[]")))
                ((symbol-function 'cmacs-dbexplorer-tool-columns-async)
                 (lambda (done &rest args)
                   (push (cons 'columns args) log) (funcall done "{}")))
                ((symbol-function 'cmacs-dbexplorer-tool-export-async)
                 (lambda (done &rest args)
                   (push (cons 'export args) log) (funcall done "{}"))))
        ;; What is well-formed goes through, with its values intact.
        (cmacs-dbexplorer-tools-tests--call
         "db_query" "{\"connection\":\"main\",\"sql\":\"select 1\",\"max_rows\":5}")
        (should (equal (assq 'query log) '(query "main" "select 1" 5)))
        (setq log nil)
        (cmacs-dbexplorer-tools-tests--call
         "db_query" "{\"connection\":\"main\",\"sql\":\"select 1\"}")
        (should (equal (assq 'query log) '(query "main" "select 1" nil)))
        (cmacs-dbexplorer-tools-tests--call
         "db_tables" "{\"connection\":\"main\"}")
        (should (equal (assq 'tables log) '(tables "main" nil)))
        (cmacs-dbexplorer-tools-tests--call
         "db_columns"
         "{\"connection\":\"main\",\"table\":\"users\",\"schema\":\"public\"}")
        (should (equal (assq 'columns log) '(columns "main" "users" "public")))
        (cmacs-dbexplorer-tools-tests--call
         "db_export"
         "{\"connection\":\"main\",\"sql\":\"select 1\",\"format\":\"csv\",\"path\":\"/tmp/o.csv\"}")
        (should (equal (assq 'export log)
                       '(export "main" "select 1" "csv" "/tmp/o.csv")))
        ;; What is not, does not.
        (setq log nil)
        (dolist (bad '(("db_tables"
                        . "{\"connection\":\"main\",\"schema\":\"a; drop\"}")
                       ("db_columns"
                        . "{\"connection\":\"main\",\"table\":\"\\\"odd name\\\"\"}")
                       ("db_columns"
                        . "{\"connection\":\"main\",\"table\":\"t\",\"schema\":\"x.y\"}")
                       ("db_export"
                        . "{\"connection\":\"main\",\"sql\":\"select 1\",\"format\":\"CSV!\",\"path\":\"/tmp/o\"}")))
          (ert-info ((format "%s %s" (car bad) (cdr bad)))
            (should (eq (car (car (cmacs-dbexplorer-tools-tests--call
                                   (car bad) (cdr bad))))
                        'error))))
        (should-not log)))))

(ert-deftest cmacs-dbexplorer-tools-test-nothing-waits ()
  "Every tool that talks to a database is :async and returns before it answers."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (dolist (name '("db_query" "db_tables" "db_columns" "db_execute"
                    "db_export" "db_connect"))
      (ert-info (name)
        (should (plist-get (cmacs-capability-describe-tool name) :async))))
    ;; The file's blocking helper is for the C handlers; no registered
    ;; tool may reach it.  `sit-for' on the dispatch thread is the bug
    ;; this conversion removed.
    (cl-letf (((symbol-function 'cmacs-dbexplorer-tools--await)
               (lambda (&rest _) (error "a registry tool waited")))
              ((symbol-function 'sit-for)
               (lambda (&rest _) (error "a registry tool called sit-for"))))
      (cmacs-dbexplorer-tools-tests--with-explorer
        (let ((query-args nil) (on-result nil))
          (setq live (cmacs-dbexplorer-tools-tests--connection "main"))
          (cl-letf (((symbol-function 'cmacs-dbexplorer-query)
                     (lambda (connection sql &rest keys)
                       (setq query-args (list connection sql)
                             on-result (plist-get keys :on-result))
                       nil))
                    ((symbol-function 'cmacs-dbexplorer-tools--query-json)
                     (lambda (result) (format "{\"got\":%S}" result))))
            (let ((reply (cmacs-dbexplorer-tools-tests--call
                          "db_query"
                          "{\"connection\":\"main\",\"sql\":\"select 1\"}")))
              ;; Started and not answered: the reply is still to come.
              (should (equal (cadr query-args) "select 1"))
              (should-not (car reply))
              (funcall on-result "rows")
              (should (equal (car reply) '(ok "{\"got\":\"rows\"}")))
              ;; A second answer from the database layer changes nothing.
              (funcall on-result "again")
              (should (equal (car reply) '(ok "{\"got\":\"rows\"}"))))))))))

(ert-deftest cmacs-dbexplorer-tools-test-async-failures ()
  "A database error and a refused connect are failed calls, once."
  (skip-unless (cmacs-dbexplorer-tools-tests--available-p))
  (cmacs-dbexplorer-tools-tests--with-family
    (cmacs-dbexplorer-tools-tests--with-explorer
      ;; Not open yet: the tool starts the connect and waits on the hooks.
      (let ((reply (cmacs-dbexplorer-tools-tests--call
                    "db_tables" "{\"connection\":\"main\"}")))
        (should-not (car reply))
        (should (equal (assq 'connect log) '(connect "main")))
        (funcall failed "main")
        (should (equal (car reply) '(error "could not connect to main")))))
    (cmacs-dbexplorer-tools-tests--with-explorer
      (setq live (cmacs-dbexplorer-tools-tests--connection "main"))
      (cl-letf (((symbol-function 'cmacs-dbexplorer-execute)
                 (lambda (_connection _sql &rest keys)
                   (funcall (plist-get keys :on-error) "read-only connection")
                   nil)))
        (should (equal (car (cmacs-dbexplorer-tools-tests--call
                             "db_execute"
                             "{\"connection\":\"main\",\"sql\":\"delete from t\"}"))
                       '(error "read-only connection")))))
    ;; A name that is not a saved connection never starts anything, and
    ;; is reported through the call rather than left to a timer.
    (cmacs-dbexplorer-tools-tests--with-explorer
      (should (eq (car (car (cmacs-dbexplorer-tools-tests--call
                             "db_query"
                             "{\"connection\":\"a b\",\"sql\":\"select 1\"}")))
                  'error))
      (should-not (assq 'connect log)))))

(provide 'cmacs-dbexplorer-tools-tests)

;;; cmacs-dbexplorer-tools-tests.el ends here
