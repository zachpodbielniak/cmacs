;;; cmacs-dbexplorer-tools-tests.el --- The database tool family on the capability table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-dbexplorer-tools.el provides every tool of
;; cmacs/mcp/cmacs-mcp-tools-dbexplorer.c while that file stays as the
;; fallback, so the first thing tested is that the two have not drifted:
;; every tool has the C tool's name, its parameters in its order, their
;; types and the same required set.
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

(defun cmacs-dbexplorer-tools-tests--c-tools (file)
  "Parse the MCP tool registrations in the C FILE.
Return a list of (NAME PARAMS REQUIRED): PARAMS is a list of
\(PARAM . TYPE) in schema order, REQUIRED the list of required names."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((starts nil) (out nil))
      (while (re-search-forward "mcp_tool_new (\"\\([a-z_]+\\)\"" nil t)
        (push (cons (match-string 1) (match-beginning 0)) starts))
      (setq starts (nreverse starts))
      (while starts
        (let ((name (car (car starts)))
              (beg (cdr (car starts)))
              (end (if (cdr starts) (cdr (cadr starts)) (point-max)))
              (params nil) (required nil))
          (goto-char beg)
          (while (re-search-forward
                  "\\\\\"\\([a-z_]+\\)\\\\\":{\\\\\"type\\\\\":\\\\\"\\([a-z]+\\)\\\\\""
                  end t)
            (push (cons (match-string 1) (match-string 2)) params))
          (goto-char beg)
          (when (re-search-forward "\\\\\"required\\\\\":\\[\\([^]]*\\)\\]" end t)
            (let ((list (match-string 1)) (at 0))
              (while (string-match "\\\\\"\\([a-z_]+\\)\\\\\"" list at)
                (push (match-string 1 list) required)
                (setq at (match-end 0)))))
          (push (list name (nreverse params) (nreverse required)) out))
        (setq starts (cdr starts)))
      (nreverse out))))

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

(defun cmacs-dbexplorer-tools-tests--check-against-c (c names)
  "Assert each tool in NAMES matches its entry in C, the parsed C tools."
  (dolist (name names)
    (pcase-let* ((`(,_ ,params ,required) (assoc name c))
                 (entry (cmacs-capability-describe-tool name)))
      (ert-info ((format "tool %s" name))
        (should entry)
        (should (equal (mapcar (lambda (p)
                                 (cons (plist-get p :name)
                                       (plist-get p :type)))
                               (plist-get entry :params))
                       params))
        (should (equal (cl-loop for p in (plist-get entry :params)
                                when (plist-get p :required)
                                collect (plist-get p :name))
                       required))))))

(defun cmacs-dbexplorer-tools-tests--available-p ()
  "Non-nil when the family file can be loaded and registers its tools."
  (and (cmacs-dbexplorer-tools-tests--root)
       (require 'cmacs-dbexplorer-model nil t)
       (fboundp 'cmacs-dbexplorer-available-p)
       (cmacs-dbexplorer-available-p)))

(ert-deftest cmacs-dbexplorer-tools-test-family-matches-c ()
  "Every tool has its C twin's name, parameters, types and required set."
  (let* ((root (cmacs-dbexplorer-tools-tests--root))
         (file (and root (expand-file-name
                          "cmacs/mcp/cmacs-mcp-tools-dbexplorer.c" root))))
    (skip-unless (and file (file-readable-p file)
                      (cmacs-dbexplorer-tools-tests--available-p)))
    (cmacs-dbexplorer-tools-tests--with-family
      (let ((c (cmacs-dbexplorer-tools-tests--c-tools file)))
        (should (equal (sort (mapcar #'car c) #'string<)
                       (sort (copy-sequence
                              cmacs-dbexplorer-tools-tests--migrated)
                             #'string<)))
        (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                     (cmacs-capability-describe))
                             #'string<)
                       (sort (copy-sequence
                              cmacs-dbexplorer-tools-tests--migrated)
                             #'string<)))
        (cmacs-dbexplorer-tools-tests--check-against-c
         c cmacs-dbexplorer-tools-tests--migrated)))))

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
      (cl-letf (((symbol-function 'cmacs-dbexplorer-tool-execute)
                 (lambda (&rest _) (setq ran t) "{}")))
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
      (cl-letf (((symbol-function 'cmacs-dbexplorer-tool-query)
                 (lambda (&rest args) (push (cons 'query args) log) "{}"))
                ((symbol-function 'cmacs-dbexplorer-tool-tables)
                 (lambda (&rest args) (push (cons 'tables args) log) "[]"))
                ((symbol-function 'cmacs-dbexplorer-tool-columns)
                 (lambda (&rest args) (push (cons 'columns args) log) "{}"))
                ((symbol-function 'cmacs-dbexplorer-tool-export)
                 (lambda (&rest args) (push (cons 'export args) log) "{}")))
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

(provide 'cmacs-dbexplorer-tools-tests)

;;; cmacs-dbexplorer-tools-tests.el ends here
