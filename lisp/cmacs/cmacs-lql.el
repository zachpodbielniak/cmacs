;;; cmacs-lql.el --- LQL, the libre query language, in cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: data, tools, languages
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; LQL (deps/libre-query-language) is linked into this Emacs: the
;; language and every source the `lql' program has -- files of any
;; format, git, exec, the journal, coredumps, Kubernetes, SQL.  This file
;; is the Lisp side of it:
;;
;;  - Editor-state sources.  `cmacs-lql-define-source' makes any Lisp
;;    function a source: buffers, windows, processes, org headings, the
;;    kill ring, ... ship with cmacs, and a user adds their own the same
;;    way.  A source's rows are snapshotted on this thread just before a
;;    query that names it runs, because the query itself runs on a
;;    worker thread that must never touch Lisp.
;;
;;  - Running queries: `cmacs-lql-run' (async, callback) and
;;    `cmacs-lql-run-sync' (for MCP/D-Bus/brigade callers that wait).
;;    Results land in a grid buffer (cmacs-lql-results.el) or a REPL
;;    (cmacs-lql-repl.el).
;;
;;  - Out-of-the-box editing of .lql files: the upstream `lql-mode' is
;;    found (in-tree or installed), eglot runs `lql-language-server'
;;    against an environment file describing THIS cmacs's environment
;;    (so completion knows `buffers' and friends), and C-c C-c runs the
;;    query at point.
;;
;; Everything here is read-only: no source writes to the editor.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

(declare-function cmacs-lql--run "cmacs-lql-defuns.c" (query &optional options callback))
(declare-function cmacs-lql--poll "cmacs-lql-defuns.c" (id))
(declare-function cmacs-lql--cancel "cmacs-lql-defuns.c" (id))
(declare-function cmacs-lql--define-source "cmacs-lql-defuns.c" (name columns &optional description))
(declare-function cmacs-lql--describe "cmacs-lql-defuns.c" ())
(declare-function cmacs-lql--complete "cmacs-lql-defuns.c" (text pos))
(declare-function cmacs-lql--hover "cmacs-lql-defuns.c" (text pos))
(declare-function cmacs-lql--signature "cmacs-lql-defuns.c" (text pos))
(declare-function cmacs-lql--diagnose "cmacs-lql-defuns.c" (text))
(declare-function cmacs-lql--explain "cmacs-lql-defuns.c" (text))
(declare-function cmacs-lql--format "cmacs-lql-defuns.c" (text &optional width))
(declare-function cmacs-lql--sources "cmacs-lql-defuns.c" ())
(declare-function cmacs-lql--version "cmacs-lql-defuns.c" ())
(declare-function cmacs-lql-results-show "cmacs-lql-results" (query payload &rest props))
(declare-function cmacs-lql-results--loading "cmacs-lql-results" (query &rest props))
(declare-function cmacs-lsp-ensure "cmacs-lsp" ())
(declare-function lql-mode "lql-mode" ())
(declare-function eglot-current-server "eglot" ())
(declare-function eglot-shutdown "eglot" (server &optional interactive timeout preserve-buffers))
(declare-function org-agenda-files "org" (&optional unrestricted archives))
(declare-function gowl-list-clients "cmacs-gowl.c" ())
(declare-function bookmark-get-filename "bookmark" (bookmark-name-or-record))
(declare-function bookmark-get-position "bookmark" (bookmark-name-or-record))
(defvar bookmark-alist)
(defvar recentf-list)
(defvar eglot-server-programs)
(defvar lql-register-with-eglot)
(defvar lql-language-server-program)
(defvar lql-environment-commands)
(defvar lql-mode-map)

(defgroup cmacs-lql nil
  "LQL, the libre query language, linked into cmacs."
  :group 'cmacs
  :prefix "cmacs-lql-")

(define-error 'cmacs-lql-unavailable "LQL is not built into this cmacs")

;;;; Customization

(defcustom cmacs-lql-max-rows 5000
  "Most rows a query hands back to a results buffer or the REPL.
The query still runs in full -- `total' counts every row -- but a
million-row grid helps nobody.  Nil means no limit."
  :type '(choice (const :tag "No limit" nil) natnum))

(defcustom cmacs-lql-timeout 120
  "Seconds before a query run from cmacs gives up.  Nil: liblql's own."
  :type '(choice (const :tag "liblql's default" nil) natnum))

(defcustom cmacs-lql-org-max-files 200
  "Most org files the `org_headings' source reads per query.
The source reads `org-agenda-files'; a query that names it pays for
every file, so the bound keeps a stray `from org_headings' cheap."
  :type 'natnum)

(defcustom cmacs-lql-kill-ring-max-chars 500
  "Characters of each kill kept by the `kill_ring' source's text column."
  :type 'natnum)

(defcustom cmacs-lql-environment-file
  (expand-file-name "cmacs/lql-environment.json"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "Where cmacs writes its LQL environment for the language server.
`lql-language-server --environment' reads it, so completion, hover and
diagnostics in .lql buffers know cmacs's own sources."
  :type 'file)

(defcustom cmacs-lql-auto-eglot t
  "Non-nil means .lql buffers start eglot with cmacs's environment."
  :type 'boolean)

;;;; Availability and locating the dep

(defun cmacs-lql-available-p ()
  "Non-nil when this cmacs was built --with-cmacs-lql."
  (fboundp 'cmacs-lql--run))

(defun cmacs-lql--ensure ()
  "Signal `cmacs-lql-unavailable' unless LQL is built in."
  (unless (cmacs-lql-available-p)
    (signal 'cmacs-lql-unavailable
            (list "rebuild cmacs --with-cmacs-lql"))))

(defun cmacs-lql--dep-dir ()
  "The deps/libre-query-language checkout this cmacs was built from, or nil."
  (let ((dir (and (bound-and-true-p source-directory)
                  (expand-file-name "deps/libre-query-language"
                                    source-directory))))
    (and dir (file-directory-p dir) dir)))

(defun cmacs-lql--build-dir ()
  "The dep's build directory holding the lql programs, or nil."
  (when-let* ((dep (cmacs-lql--dep-dir)))
    (or (and (getenv "CMACS_LQL_DIR")
             (file-directory-p (getenv "CMACS_LQL_DIR"))
             (getenv "CMACS_LQL_DIR"))
        (cl-find-if (lambda (d)
                      (file-executable-p
                       (expand-file-name "lql-language-server" d)))
                    (list (expand-file-name "build/debug" dep)
                          (expand-file-name "build/release" dep))))))

(defun cmacs-lql-program (name)
  "Absolute file name of the lql program NAME, or nil.
The tree's own build wins over an installed copy, so a dev build
always talks to the server it was built with."
  (or (when-let* ((dir (cmacs-lql--build-dir))
                  (file (expand-file-name name dir)))
        (and (file-executable-p file) file))
      (executable-find name)))

(defun cmacs-lql--load-lql-mode ()
  "Load the upstream `lql-mode', from site-lisp or the dep checkout."
  (or (featurep 'lql-mode)
      (progn
        ;; cmacs registers its own eglot contact (with cmacs's
        ;; environment); the upstream one would race it.
        (setq lql-register-with-eglot nil)
        (or (require 'lql-mode nil t)
            (when-let* ((dep (cmacs-lql--dep-dir))
                        (dir (expand-file-name "editors/emacs" dep)))
              (when (file-readable-p (expand-file-name "lql-mode.el" dir))
                (add-to-list 'load-path dir)
                (require 'lql-mode nil t)))))))

;;;; Value conversion: Lisp rows -> JSON for a snapshot

(defconst cmacs-lql--types
  '((string . "String") (int . "Int") (integer . "Int") (double . "Double")
    (float . "Double") (number . "Double") (boolean . "Boolean")
    (bool . "Boolean") (timestamp . "Timestamp") (duration . "Duration")
    (array . "Array") (list . "Array") (record . "Record") (any . "Any"))
  "Column type symbols `cmacs-lql-define-source' accepts, and LQL's names.")

(defun cmacs-lql--type-name (type)
  "LQL's name for the column TYPE symbol."
  (or (cdr (assq type cmacs-lql--types))
      (error "cmacs-lql: unknown column type %S (one of %s)" type
             (mapconcat (lambda (c) (symbol-name (car c))) cmacs-lql--types " "))))

(defun cmacs-lql--json-value (value type)
  "VALUE as something `json-serialize' takes, for a column of TYPE."
  (cond
   ((and (null value) (eq type 'boolean)) :false)
   ((eq value t) t)
   ((null value) :null)
   ((stringp value) (substring-no-properties value))
   ((numberp value) value)
   ((symbolp value) (symbol-name value))
   ((bufferp value) (buffer-name value))
   ((markerp value) (or (marker-position value) :null))
   ((and (consp value) (eq type 'timestamp)) (float-time value))
   ((and (consp value) (keywordp (car value)))   ; a plist: a record
    (cmacs-lql--plist-object value))
   ((listp value) (vconcat (mapcar (lambda (v) (cmacs-lql--json-value v 'any))
                                   value)))
   ((vectorp value) (vconcat (mapcar (lambda (v) (cmacs-lql--json-value v 'any))
                                     value)))
   (t (format "%S" value))))

(defun cmacs-lql--plist-object (plist)
  "PLIST (keyword keys) as an alist object for `json-serialize'."
  (let (out)
    (while plist
      (push (cons (intern (substring (symbol-name (car plist)) 1))
                  (cmacs-lql--json-value (cadr plist) 'any))
            out)
      (setq plist (cddr plist)))
    (nreverse out)))

(defun cmacs-lql--row-object (row columns)
  "ROW (a plist or alist) as a JSON object, typed by COLUMNS."
  (let ((pairs (if (and (consp row) (keywordp (car row)))
                   (cl-loop for (k v) on row by #'cddr
                            collect (cons (substring (symbol-name k) 1) v))
                 (mapcar (lambda (p) (cons (format "%s" (car p)) (cdr p))) row))))
    (mapcar (lambda (p)
              (let ((type (or (cdr (assoc (car p) columns)) 'any)))
                (cons (intern (car p)) (cmacs-lql--json-value (cdr p) type))))
            pairs)))

;;;; The source registry

(defvar cmacs-lql--sources (make-hash-table :test #'equal)
  "Source name -> plist (:columns :function :description) of Elisp sources.")

(defun cmacs-lql-define-source (name columns function &optional description)
  "Define the LQL source NAME, whose rows FUNCTION returns.

COLUMNS is a list of (COLUMN TYPE) pairs, COLUMN a string and TYPE one
of `string', `int', `double', `boolean', `timestamp', `duration',
`array', `record' or `any'.  FUNCTION takes no arguments and returns a
list of rows, each a plist (:column VALUE ...) or an alist.  A
timestamp may be a Lisp time value or `float-time' seconds; a boolean
column reads nil as false.  Columns a row leaves out are NULL, and
fields it has beyond COLUMNS come along untyped.

FUNCTION runs on the editor thread just before every query that names
NAME, so keep it cheap or bounded.  DESCRIPTION is a one-line summary
shown by completion and hover.  Redefining NAME replaces it.

  (cmacs-lql-define-source \"features\" \\='((\"name\" string))
    (lambda () (mapcar (lambda (f) (list :name f)) features))
    \"Loaded Lisp features.\")"
  (cl-check-type name string)
  (unless (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" name)
    (error "cmacs-lql: %S is not a valid source name" name))
  (let ((cols (mapcar (lambda (c) (cons (car c) (cadr c))) columns)))
    (dolist (c cols) (cmacs-lql--type-name (cdr c)))
    (puthash name (list :columns cols :function function
                        :description description)
             cmacs-lql--sources)
    (when (cmacs-lql-available-p)
      (cmacs-lql--define-source
       name
       (json-serialize
        (vconcat (mapcar (lambda (c)
                           `((name . ,(car c))
                             (type . ,(cmacs-lql--type-name (cdr c)))))
                         cols)))
       description)
      (cmacs-lql--environment-changed))
    name))

(defun cmacs-lql-source-names ()
  "Names of the Elisp-defined sources, sorted."
  (sort (hash-table-keys cmacs-lql--sources) #'string<))

(defun cmacs-lql--referenced-sources (query)
  "The Elisp source names QUERY mentions as whole symbols."
  (cl-loop for name being the hash-keys of cmacs-lql--sources
           when (string-match-p (concat "\\_<" (regexp-quote name) "\\_>") query)
           collect name))

(defun cmacs-lql--snapshot (name)
  "Rows of Elisp source NAME as a JSON array string."
  (let* ((spec (gethash name cmacs-lql--sources))
         (columns (plist-get spec :columns))
         (rows (condition-case err
                   (funcall (plist-get spec :function))
                 (error
                  (message "cmacs-lql: source %s failed: %s" name
                           (error-message-string err))
                  nil))))
    (json-serialize
     (vconcat (mapcar (lambda (row) (cmacs-lql--row-object row columns))
                      rows))
     :null-object :null :false-object :false)))

(defun cmacs-lql--snapshots (query)
  "The :snapshots alist for QUERY."
  (mapcar (lambda (name) (cons name (cmacs-lql--snapshot name)))
          (cmacs-lql--referenced-sources query)))

;;;; Running queries

(defun cmacs-lql-run (query callback &rest options)
  "Run the LQL QUERY; call CALLBACK with its payload.  Return the id.

The payload is (:ok :json JSON :text TEXT :rows N :elapsed SECS),
\(:error MESSAGE) or (:cancelled).  CALLBACK nil means collect it with
`cmacs-lql-wait'.  OPTIONS: :max-rows (default `cmacs-lql-max-rows'),
:text-width (also render the table as text), :timeout in seconds
\(default `cmacs-lql-timeout')."
  (cmacs-lql--ensure)
  (let ((max-rows (if (plist-member options :max-rows)
                      (plist-get options :max-rows)
                    cmacs-lql-max-rows))
        (timeout (if (plist-member options :timeout)
                     (plist-get options :timeout)
                   cmacs-lql-timeout)))
    (cmacs-lql--run query
                    (append (list :snapshots (cmacs-lql--snapshots query))
                            (and max-rows (list :max-rows max-rows))
                            (and (plist-get options :text-width)
                                 (list :text-width (plist-get options :text-width)))
                            (and timeout (list :timeout (* 1000 timeout))))
                    callback)))

(defun cmacs-lql-wait (id &optional timeout)
  "Wait for LQL request ID and return its payload.
Polls with `accept-process-output', never `sit-for', so it is safe
inside MCP and D-Bus dispatch.  Gives up after TIMEOUT seconds
\(default `cmacs-lql-timeout' plus a margin), cancelling the request."
  (let ((deadline (+ (float-time) (or timeout (+ (or cmacs-lql-timeout 3600) 15))))
        payload)
    (unwind-protect
        (progn
          (while (and (not (setq payload (cmacs-lql--poll id)))
                      (< (float-time) deadline))
            (accept-process-output nil 0.02))
          (or payload (list :error (format "LQL request %s timed out" id))))
      (unless payload
        (cmacs-lql--cancel id)
        ;; It still finishes once; collect it so the C side forgets it.
        (run-with-timer 1 nil (lambda ()
                                (ignore-errors (cmacs-lql--poll id))))))))

(defun cmacs-lql-run-sync (query &rest options)
  "Run the LQL QUERY and return its payload (see `cmacs-lql-run').
Blocks the caller, not the query: that runs on the LQL worker thread."
  (cmacs-lql-wait (apply #'cmacs-lql-run query nil options)))

(defun cmacs-lql-parse (json)
  "Parse a result JSON into a table plist.
That is (:columns ((NAME . TYPE)...) :rows (VECTOR...) :total N)."
  (let* ((doc (json-parse-string json :object-type 'alist :array-type 'array
                                 :null-object nil :false-object :false))
         (columns (mapcar (lambda (c) (cons (alist-get 'name c) (alist-get 'type c)))
                          (alist-get 'columns doc)))
         (rows (append (alist-get 'rows doc) nil)))
    (list :columns columns :rows rows :total (alist-get 'total doc))))

(defun cmacs-lql-payload-table (payload)
  "The parsed table of an :ok PAYLOAD, or nil."
  (when (eq (car payload) :ok)
    (cmacs-lql-parse (plist-get (cdr payload) :json))))

;;;; Editor helpers that must never wait

(defmacro cmacs-lql--unless-busy (&rest body)
  "Run BODY; nil when a running query holds the LQL environment."
  (declare (indent 0) (debug t))
  `(condition-case nil (progn ,@body) (cmacs-lql-busy nil)))

(defun cmacs-lql--byte-to-char (text byte)
  "The character index in TEXT of BYTE, a UTF-8 byte offset."
  (if (multibyte-string-p text)
      (length (decode-coding-string
               (substring (encode-coding-string text 'utf-8 t) 0
                          (min byte (string-bytes text)))
               'utf-8 t))
    byte))

(defun cmacs-lql-completions (text pos)
  "Completion candidates for LQL TEXT at character index POS.
A list of (LABEL KIND DETAIL DOC START END), START and END character
indices of the text a candidate replaces.  Nil while a query runs."
  (cmacs-lql--unless-busy
    (when-let* ((json (cmacs-lql--complete text pos)))
      (mapcar (lambda (c)
                (let* ((start (cmacs-lql--byte-to-char text (alist-get 'offset c)))
                       (end (cmacs-lql--byte-to-char
                             text (+ (alist-get 'offset c) (alist-get 'length c)))))
                  (list (alist-get 'insert c) (alist-get 'kind c)
                        (alist-get 'detail c) (alist-get 'doc c) start end)))
              (json-parse-string json :object-type 'alist :array-type 'list
                                 :null-object nil)))))

(defun cmacs-lql-hover-text (text pos)
  "Hover documentation for LQL TEXT at character index POS, or nil."
  (cmacs-lql--unless-busy
    (when-let* ((json (cmacs-lql--hover text pos)))
      (alist-get 'text (json-parse-string json :object-type 'alist)))))

(defun cmacs-lql-signature-text (text pos)
  "One-line signature of the call around POS in LQL TEXT, or nil."
  (cmacs-lql--unless-busy
    (when-let* ((json (cmacs-lql--signature text pos)))
      (let ((sig (json-parse-string json :object-type 'alist :null-object nil)))
        (alist-get 'signature sig)))))

;;;; Environment file for the language server

(defvar cmacs-lql--environment-timer nil
  "Pending rewrite of `cmacs-lql-environment-file'.")

(defun cmacs-lql-write-environment ()
  "Write cmacs's LQL environment to `cmacs-lql-environment-file'.
Returns the file name, or nil when a running query held the
environment (a retry is scheduled)."
  (cmacs-lql--ensure)
  (let ((json (cmacs-lql--unless-busy (cmacs-lql--describe))))
    (if (not json)
        (progn (cmacs-lql--environment-changed) nil)
      (make-directory (file-name-directory cmacs-lql-environment-file) t)
      ;; Write then rename: the server watches the file and must never
      ;; read half of it.
      (let ((tmp (make-temp-file (expand-file-name
                                  ".lql-env" (file-name-directory
                                              cmacs-lql-environment-file)))))
        (with-temp-file tmp
          (set-buffer-file-coding-system 'utf-8-unix)
          (insert json))
        (rename-file tmp cmacs-lql-environment-file t))
      cmacs-lql-environment-file)))

(defun cmacs-lql--environment-changed ()
  "Rewrite the environment file soon (debounced)."
  (when (timerp cmacs-lql--environment-timer)
    (cancel-timer cmacs-lql--environment-timer))
  (setq cmacs-lql--environment-timer
        (run-with-idle-timer 0.5 nil
                             (lambda ()
                               (setq cmacs-lql--environment-timer nil)
                               (ignore-errors (cmacs-lql-write-environment))))))

(defun cmacs-lql-server-contact (&optional _interactive)
  "Command line of the LQL language server for cmacs.
The server runs against cmacs's own environment file, so it knows the
editor-state sources, plus any `lql-environment-commands'."
  (let ((program (or (cmacs-lql-program "lql-language-server")
                     (bound-and-true-p lql-language-server-program)
                     "lql-language-server"))
        (env (and (cmacs-lql-available-p)
                  (or (file-exists-p cmacs-lql-environment-file)
                      (cmacs-lql-write-environment))
                  cmacs-lql-environment-file)))
    (append (list program)
            (and env (list "--environment" env))
            (mapcan (lambda (c) (list "--environment-command" c))
                    (bound-and-true-p lql-environment-commands)))))

(defun cmacs-lql--register-eglot ()
  "Point eglot's `lql-mode' entry at `cmacs-lql-server-contact'."
  (setq eglot-server-programs
        (cons '(lql-mode . cmacs-lql-server-contact)
              (cl-remove-if (lambda (e) (eq (car-safe e) 'lql-mode))
                            eglot-server-programs))))

(with-eval-after-load 'eglot
  (cmacs-lql--register-eglot))

;;;; lql-mode commands

(defvar-local cmacs-lql-target 'local
  "Where `cmacs-lql-run-at-point' runs a query: `local' or `libresearch'.")
(put 'cmacs-lql-target 'safe-local-variable
     (lambda (v) (memq v '(local libresearch))))

(defun cmacs-lql-query-at-point ()
  "The LQL query at point: the region, else the blank-line-delimited block."
  (string-trim
   (if (use-region-p)
       (buffer-substring-no-properties (region-beginning) (region-end))
     (save-excursion
       (let ((start (progn (if (re-search-backward "^[ \t]*$" nil t)
                               (forward-line 1)
                             (goto-char (point-min)))
                           (point)))
             (end (progn (if (re-search-forward "^[ \t]*$" nil t)
                             (match-beginning 0)
                           (point-max)))))
         (buffer-substring-no-properties start end))))))

;;;###autoload
(defun cmacs-lql-query (query)
  "Run the LQL QUERY and show its rows in a results buffer."
  (interactive (list (read-string "LQL: " nil 'cmacs-lql-history)))
  (cmacs-lql--ensure)
  (require 'cmacs-lql-results)
  (cmacs-lql-results--loading query :target 'local))

(defvar cmacs-lql-history nil "Minibuffer history of LQL queries.")

(defun cmacs-lql-run-at-point ()
  "Run the LQL query at point (region or block); show it in a grid.
In a buffer whose `cmacs-lql-target' is `libresearch', the query runs
on the libresearch server instead."
  (interactive)
  (let ((query (cmacs-lql-query-at-point)))
    (when (string-empty-p query)
      (user-error "No LQL query at point"))
    (require 'cmacs-lql-results)
    (cmacs-lql-results--loading query :target cmacs-lql-target)))

(defun cmacs-lql-toggle-target ()
  "Switch this buffer's query target between local and libresearch."
  (interactive)
  (setq cmacs-lql-target (if (eq cmacs-lql-target 'local) 'libresearch 'local))
  (message "LQL target: %s" cmacs-lql-target))

(defun cmacs-lql-explain-at-point ()
  "Show the plan liblql would run for the query at point."
  (interactive)
  (cmacs-lql--ensure)
  (let* ((query (cmacs-lql-query-at-point))
         (plan (condition-case err (cmacs-lql--explain query)
                 (cmacs-lql-busy (user-error "A query is running; try again"))
                 (cmacs-lql-error (user-error "%s" (cadr err))))))
    (with-help-window "*LQL plan*"
      (princ query) (princ "\n\n") (princ plan))))

(defun cmacs-lql-format-at-point ()
  "Reformat the query at point (region or block) with liblql's formatter."
  (interactive)
  (cmacs-lql--ensure)
  (let* ((bounds (if (use-region-p)
                     (cons (region-beginning) (region-end))
                   (save-excursion
                     (cons (progn (if (re-search-backward "^[ \t]*$" nil t)
                                      (forward-line 1)
                                    (goto-char (point-min)))
                                  (point))
                           (progn (if (re-search-forward "^[ \t]*$" nil t)
                                      (match-beginning 0)
                                    (point-max)))))))
         (text (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (out (condition-case err (cmacs-lql--format text fill-column)
                (cmacs-lql-busy (user-error "A query is running; try again"))
                (cmacs-lql-error (user-error "%s" (cadr err))))))
    (unless (equal (string-trim-right out) (string-trim-right text))
      (save-excursion
        (goto-char (car bounds))
        (delete-region (car bounds) (cdr bounds))
        (insert (string-trim-right out))))))

(defun cmacs-lql--lql-mode-setup ()
  "Make an `lql-mode' buffer work out of the box in cmacs."
  (when (cmacs-lql-available-p)
    (when (and cmacs-lql-auto-eglot buffer-file-name
               (cmacs-lql-program "lql-language-server")
               (require 'cmacs-lsp nil t))
      (cmacs-lsp-ensure))))

(defun cmacs-lql--install-lql-mode ()
  "Load `lql-mode' and bind cmacs's commands in it."
  (when (cmacs-lql--load-lql-mode)
    (define-key lql-mode-map (kbd "C-c C-c") #'cmacs-lql-run-at-point)
    (define-key lql-mode-map (kbd "C-c C-e") #'cmacs-lql-explain-at-point)
    (define-key lql-mode-map (kbd "C-c C-f") #'cmacs-lql-format-at-point)
    (define-key lql-mode-map (kbd "C-c C-t") #'cmacs-lql-toggle-target)
    (define-key lql-mode-map (kbd "C-c C-z") #'cmacs-lql-repl)
    (add-hook 'lql-mode-hook #'cmacs-lql--lql-mode-setup)
    t))

;;;###autoload
(defun cmacs-lql-mode-autoload ()
  "Enter `lql-mode' with cmacs's setup (the .lql `auto-mode-alist' entry)."
  (if (cmacs-lql--install-lql-mode)
      (lql-mode)
    (prog-mode)
    (message "cmacs-lql: lql-mode not found (deps/libre-query-language/editors/emacs)")))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.lql\\'" . cmacs-lql-mode-autoload))

;; ob-lql runs the `lql' program; point it at the tree's build when
;; there is one, so a dev build needs no PATH setup.
(defvar ob-lql-program)
(with-eval-after-load 'org
  (when (cmacs-lql--load-lql-mode)
    (when (require 'ob-lql nil t)
      (when-let* ((lql (cmacs-lql-program "lql")))
        (setq ob-lql-program lql)))))

(declare-function cmacs-lql-repl "cmacs-lql-repl" ())

;;;; Shipped editor-state sources

(defun cmacs-lql--buffer-rows ()
  "Rows of the `buffers' source."
  (mapcar (lambda (b)
            (with-current-buffer b
              (list :name (buffer-name)
                    :file buffer-file-name
                    :directory (and default-directory
                                    (expand-file-name default-directory))
                    :mode (symbol-name major-mode)
                    :size (buffer-size)
                    :modified (buffer-modified-p)
                    :read_only buffer-read-only
                    :visible (and (get-buffer-window b t) t)
                    :process (let ((p (get-buffer-process b)))
                               (and p (process-name p)))
                    :hidden (string-prefix-p " " (buffer-name)))))
          (buffer-list)))

(defun cmacs-lql--window-rows ()
  "Rows of the `windows' source."
  (let (rows)
    (dolist (f (frame-list))
      (dolist (w (window-list f 'no-minibuf))
        (push (list :frame (frame-parameter f 'name)
                    :buffer (buffer-name (window-buffer w))
                    :width (window-width w) :height (window-height w)
                    :selected (eq w (selected-window))
                    :dedicated (and (window-dedicated-p w) t)
                    :point (window-point w))
              rows)))
    (nreverse rows)))

(defun cmacs-lql--process-rows ()
  "Rows of the `processes' source (Emacs subprocesses)."
  (mapcar (lambda (p)
            (list :name (process-name p)
                  :pid (process-id p)
                  :status (symbol-name (process-status p))
                  :type (symbol-name (process-type p))
                  :command (and (process-command p)
                                (mapconcat #'identity (process-command p) " "))
                  :buffer (and (process-buffer p)
                               (buffer-name (process-buffer p)))))
          (process-list)))

(defun cmacs-lql--recentf-rows ()
  "Rows of the `recentf' source."
  (when (bound-and-true-p recentf-list)
    (cl-loop for f in recentf-list for i from 0
             collect (list :rank i :file f
                           :directory (file-name-directory f)
                           :extension (file-name-extension f)
                           :remote (and (file-remote-p f) t)
                           :exists (and (not (file-remote-p f))
                                        (file-exists-p f))))))

(defun cmacs-lql--kill-ring-rows ()
  "Rows of the `kill_ring' source."
  (cl-loop for k in kill-ring for i from 0
           collect (list :index i :length (length k)
                         :text (truncate-string-to-width
                                (substring-no-properties k) cmacs-lql-kill-ring-max-chars))))

(defun cmacs-lql--bookmark-rows ()
  "Rows of the `bookmarks' source."
  (when (require 'bookmark nil t)
    (ignore-errors (bookmark-maybe-load-default-file))
    (mapcar (lambda (b)
              (list :name (car b)
                    :file (bookmark-get-filename b)
                    :position (bookmark-get-position b)))
            bookmark-alist)))
(declare-function bookmark-maybe-load-default-file "bookmark" ())

(defvar org-heading-regexp)
(defvar org-inhibit-startup)
(declare-function org-element-at-point "org-element" (&optional pom cached-only))
(declare-function org-element-property "org-element-ast" (property node &optional dflt force-undefer))
(declare-function org-mode "org" ())

(defun cmacs-lql--org-heading-rows ()
  "Rows of the `org_headings' source, from `org-agenda-files' (bounded)."
  (when (require 'org nil t)
    (let ((files (seq-take (org-agenda-files) cmacs-lql-org-max-files))
          rows)
      (dolist (file files)
        (when (file-readable-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (let ((org-inhibit-startup t)
                  (delay-mode-hooks t))
              (delay-mode-hooks (org-mode)))
            (goto-char (point-min))
            (while (re-search-forward org-heading-regexp nil t)
              (let ((el (org-element-at-point)))
                (push (list :file file
                            :line (line-number-at-pos (match-beginning 0))
                            :level (org-element-property :level el)
                            :heading (org-element-property :raw-value el)
                            :todo (org-element-property :todo-keyword el)
                            :priority (let ((p (org-element-property :priority el)))
                                        (and p (char-to-string p)))
                            :tags (org-element-property :tags el)
                            :scheduled (let ((s (org-element-property :scheduled el)))
                                         (and s (org-element-property :raw-value s)))
                            :deadline (let ((d (org-element-property :deadline el)))
                                        (and d (org-element-property :raw-value d)))
                            :id (org-element-property :ID el))
                      rows))))))
      (nreverse rows))))

(defun cmacs-lql--gowl-client-rows ()
  "Rows of the `gowl_clients' source (windows of the gowl compositor)."
  (when (fboundp 'gowl-list-clients)
    (mapcar (lambda (c)
              (if (and (consp c) (keywordp (car c)))
                  c
                (list :client (format "%S" c))))
            (condition-case nil (gowl-list-clients) (error nil)))))

(defun cmacs-lql--define-shipped-sources ()
  "Define the editor-state sources cmacs ships."
  (cmacs-lql-define-source
   "buffers"
   '(("name" string) ("file" string) ("directory" string) ("mode" string)
     ("size" int) ("modified" boolean) ("read_only" boolean)
     ("visible" boolean) ("process" string) ("hidden" boolean))
   #'cmacs-lql--buffer-rows "Every live buffer.")
  (cmacs-lql-define-source
   "windows"
   '(("frame" string) ("buffer" string) ("width" int) ("height" int)
     ("selected" boolean) ("dedicated" boolean) ("point" int))
   #'cmacs-lql--window-rows "Every window of every frame.")
  (cmacs-lql-define-source
   "processes"
   '(("name" string) ("pid" int) ("status" string) ("type" string)
     ("command" string) ("buffer" string))
   #'cmacs-lql--process-rows "Emacs subprocesses and network processes.")
  (cmacs-lql-define-source
   "recentf"
   '(("rank" int) ("file" string) ("directory" string) ("extension" string)
     ("remote" boolean) ("exists" boolean))
   #'cmacs-lql--recentf-rows "Recently visited files (recentf).")
  (cmacs-lql-define-source
   "kill_ring"
   '(("index" int) ("length" int) ("text" string))
   #'cmacs-lql--kill-ring-rows "The kill ring, newest first.")
  (cmacs-lql-define-source
   "bookmarks"
   '(("name" string) ("file" string) ("position" int))
   #'cmacs-lql--bookmark-rows "Emacs bookmarks.")
  (cmacs-lql-define-source
   "org_headings"
   '(("file" string) ("line" int) ("level" int) ("heading" string)
     ("todo" string) ("priority" string) ("tags" array) ("scheduled" string)
     ("deadline" string) ("id" string))
   #'cmacs-lql--org-heading-rows
   "Headings of `org-agenda-files' (at most `cmacs-lql-org-max-files').")
  (when (bound-and-true-p is-cmacs-gowl)
    (cmacs-lql-define-source
     "gowl_clients" '(("client" any))
     #'cmacs-lql--gowl-client-rows "Windows managed by the gowl compositor.")))

(when (cmacs-lql-available-p)
  (cmacs-lql--define-shipped-sources))

(provide 'cmacs-lql)

;;; cmacs-lql.el ends here
