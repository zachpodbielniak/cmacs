;;; cmacs-capability.el --- One capability table for every surface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The brigade tool registry (cmacs-brigade-registry.el) already is the
;; one place a capability is written down for in-process agents, MCP
;; clients and the right-click menu.  This file makes it the one place
;; for the remaining surfaces too:
;;
;;   D-Bus     org.cmacs.Editor1.Tools   List / Describe / Call
;;   emacsctl  `emacsctl tool ...'       built from List at run time
;;   docs      `cmacs-capability-doc', and a checked-in reference that a
;;             test fails on when it is stale
;;
;; Nothing here holds a second copy of any tool's metadata.  Everything
;; is computed from the registry by `cmacs-capability-describe', and
;; that function's value -- as Lisp data, or as JSON through
;; `cmacs-capability-json' -- is the single description each of those
;; surfaces reads.  A capability added with one `cmacs-brigade-deftool'
;; form therefore shows up in `emacsctl tool list', in the D-Bus table
;; and in the reference without a row being added anywhere.
;;
;; What a caller on D-Bus may do is decided here, in this order, which
;; is the order the MCP surface uses:
;;
;;   1. the tool exists
;;   2. surface    its :surfaces include `dbus'
;;   3. scope      (nothing to check: a D-Bus caller cannot be scoped,
;;                  see `cmacs-capability-call')
;;   4. arguments  the JSON object validates against the typed params
;;   5. the shared gates of `cmacs-brigade-call-tool-async': the
;;      before-call hooks and the confirmation policy
;;
;; Caller text never becomes Lisp source.  The C side passes the tool
;; name and the JSON argument object as two escaped string literals to
;; `cmacs-capability-dbus-call'; the JSON is parsed here with
;; `json-parse-string' and reaches the handler as values.

;;; Code:

(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-capability nil
  "The capability table: one tool registry, every RPC surface."
  :group 'cmacs-brigade
  :prefix "cmacs-capability-")

(define-error 'cmacs-capability-error "Capability call refused")

(defconst cmacs-capability-version 1
  "Version of the table `cmacs-capability-json' emits.
A client that reads the table checks this before trusting the member
names; it changes only when a member is renamed or removed, never when
one is added.")


;;;; CLI verbs
;;
;; ONE rule, applied to every tool that does not set :cli itself:
;;
;;   GROUP = the tool's :group ("misc" when it has none, or when the
;;           group is a word `emacsctl tool' keeps for itself)
;;   VERB  = the wire name with a leading "GROUP_" removed
;;   both with `_' written as `-'
;;
;; so `desktop_launch' in group `desktop' is `emacsctl tool desktop
;; launch', and `lql_query' in group `data' is `emacsctl tool data
;; lql-query'.  The wire name is unique, so the only way two tools can
;; land on one verb is the prefix removal -- `desktop_launch' and
;; `launch', both in `desktop'.  Then the prefix is kept for every tool
;; involved: both stay reachable and neither silently wins.

(defun cmacs-capability--dashed (name)
  "Return NAME, a symbol or string, with underscores written as hyphens."
  (replace-regexp-in-string
   "_" "-" (if (symbolp name) (symbol-name name) name)))

(defun cmacs-capability-cli-group (tool)
  "Return the `emacsctl tool' group word for TOOL."
  (let* ((cli (cmacs-brigade-tool-cli tool))
         (group (cmacs-brigade-tool-group tool))
         (word (cond (cli (car (split-string cli " ")))
                     (group (cmacs-capability--dashed group))
                     (t "misc"))))
    (if (member word cmacs-brigade-tool-cli-reserved) "misc" word)))

(defun cmacs-capability-cli-verb (tool &optional keep-prefix)
  "Return (GROUP . VERB), the words that follow `emacsctl tool' for TOOL.

An explicit :cli wins.  Otherwise the verb is the wire name minus a
leading \"GROUP_\", unless KEEP-PREFIX is non-nil, in which case the
whole wire name is the verb -- which is what
`cmacs-capability-describe' asks for when two tools would otherwise
share one."
  (let ((cli (cmacs-brigade-tool-cli tool))
        (group (cmacs-capability-cli-group tool)))
    (if cli
        (let ((words (split-string cli " ")))
          (cons (nth 0 words) (nth 1 words)))
      (let* ((wire (cmacs-brigade-tool-wire-name tool))
             (prefix (concat (replace-regexp-in-string "-" "_" group) "_"))
             (verb (if (and (not keep-prefix)
                            (string-prefix-p prefix wire)
                            (> (length wire) (length prefix)))
                       (substring wire (length prefix))
                     wire)))
        (cons group (cmacs-capability--dashed verb))))))

(defun cmacs-capability--cli-table (tools)
  "Return a hash of wire name -> \"GROUP VERB\" for TOOLS, without clashes."
  (let ((seen (make-hash-table :test 'equal))
        (out (make-hash-table :test 'equal)))
    ;; First pass: count how many tools want each derived spelling.
    (dolist (tool tools)
      (let ((gv (cmacs-capability-cli-verb tool)))
        (push tool (gethash gv seen))))
    (dolist (tool tools)
      (let* ((gv (cmacs-capability-cli-verb tool))
             (clash (cdr (gethash gv seen)))
             (final (if (and clash (not (cmacs-brigade-tool-cli tool)))
                        (cmacs-capability-cli-verb tool t)
                      gv)))
        (puthash (cmacs-brigade-tool-wire-name tool)
                 (concat (car final) " " (cdr final)) out)))
    out))


;;;; The table

(defun cmacs-capability--tools ()
  "Return every registered tool struct, sorted by wire name."
  (sort (mapcar (lambda (n) (cmacs-brigade-registry-get 'tool n))
                (cmacs-brigade-registry-list 'tool))
        (lambda (a b) (string< (cmacs-brigade-tool-wire-name a)
                               (cmacs-brigade-tool-wire-name b)))))

(defun cmacs-capability--describe-param (p)
  "Return the table entry for parameter plist P."
  (append (list :name (plist-get p :name)
                :type (plist-get p :type)
                :description (plist-get p :doc)
                :required (and (plist-get p :required) t))
          (when (plist-get p :default)
            (list :default (plist-get p :default)))
          (when (plist-get p :enum)
            (list :enum (mapcar (lambda (e) (format "%s" e))
                                (plist-get p :enum))))))

(defun cmacs-capability--describe-tool (tool cli)
  "Return the table entry for TOOL, whose CLI words are the string CLI."
  (list :name (cmacs-brigade-tool-wire-name tool)
        :description (cmacs-brigade-tool-description tool)
        :group (and (cmacs-brigade-tool-group tool)
                    (format "%s" (cmacs-brigade-tool-group tool)))
        :params (mapcar #'cmacs-capability--describe-param
                        (cmacs-brigade-tool-params tool))
        :destructive (and (cmacs-brigade-tool-destructive tool) t)
        :confirm (cmacs-brigade-tool-confirm tool)
        :async (and (cmacs-brigade-tool-async tool) t)
        :timeout (cmacs-brigade-tool-timeout tool)
        ;; In the canonical order, so two descriptions of one registry
        ;; compare equal whatever order :surfaces was written in.
        :surfaces (cl-remove-if-not
                   (lambda (s) (cmacs-brigade-tool-on-surface-p tool s))
                   cmacs-brigade-tool-surfaces)
        :cli cli
        :returns (or (cmacs-brigade-tool-returns tool) 'string)
        :example (cmacs-brigade-tool-example tool)
        :aliases (cmacs-brigade-tool-aliases tool)))

;;;###autoload
(defun cmacs-capability-describe (&optional surface)
  "Return the capability table as data: a list of plists, one per tool.

With SURFACE -- one of `cmacs-brigade-tool-surfaces' -- only the tools
published there.  Each plist has

  :name :description :group :params :destructive :confirm :async
  :timeout :surfaces :cli :returns :example :aliases

where :params is a list of (:name :type :description :required
[:default] [:enum]) plists and :cli is the \"GROUP VERB\" that follows
`emacsctl tool'.

Pure: it reads the registry and builds a fresh list, so it may be
called from an RPC dispatch.  This is the description every derived
surface reads; nothing else enumerates tools for D-Bus, the CLI or the
generated reference."
  (let* ((tools (cmacs-capability--tools))
         ;; Verbs are settled over the WHOLE registry, not the filtered
         ;; view: a tool's CLI spelling must not change depending on
         ;; which surface asked.
         (cli (cmacs-capability--cli-table tools)))
    (cl-loop for tool in tools
             when (or (null surface)
                      (cmacs-brigade-tool-on-surface-p tool surface))
             collect (cmacs-capability--describe-tool
                      tool
                      (gethash (cmacs-brigade-tool-wire-name tool) cli)))))

;;;###autoload
(defun cmacs-capability-describe-tool (name &optional surface)
  "Return the table entry for the tool NAME, or nil.
NAME is a wire name, an alias, or the registry symbol.  With SURFACE,
nil unless the tool is published there."
  (let* ((wire (cmacs-brigade-wire-name name))
         (tool (cmacs-brigade--tool-by-wire wire)))
    (when tool
      (cl-find (cmacs-brigade-tool-wire-name tool)
               (cmacs-capability-describe surface)
               :key (lambda (e) (plist-get e :name))
               :test #'equal))))

(defun cmacs-capability--json-tool (entry)
  "Return ENTRY, a table plist, in the shape `json-serialize' wants."
  (let ((bool (lambda (v) (if v t :false)))
        (str (lambda (v) (if v (format "%s" v) :null))))
    (list :name (plist-get entry :name)
          :description (plist-get entry :description)
          :group (funcall str (plist-get entry :group))
          :params
          (vconcat
           (mapcar
            (lambda (p)
              (append
               (list :name (plist-get p :name)
                     :type (plist-get p :type)
                     :description (plist-get p :description)
                     :required (funcall bool (plist-get p :required)))
               (when (plist-member p :default)
                 (list :default (let ((d (plist-get p :default)))
                                  (if (or (stringp d) (numberp d))
                                      d
                                    (format "%s" d)))))
               (when (plist-member p :enum)
                 (list :enum (vconcat (plist-get p :enum))))))
            (plist-get entry :params)))
          :destructive (funcall bool (plist-get entry :destructive))
          :confirm (funcall str (plist-get entry :confirm))
          :async (funcall bool (plist-get entry :async))
          :timeout (plist-get entry :timeout)
          :surfaces (vconcat (mapcar #'symbol-name
                                     (plist-get entry :surfaces)))
          :cli (plist-get entry :cli)
          :returns (symbol-name (plist-get entry :returns))
          :example (funcall str (plist-get entry :example))
          :aliases (vconcat (plist-get entry :aliases)))))

;;;###autoload
(defun cmacs-capability-json (&optional surface)
  "Return the capability table as a JSON string.

The document is {\"version\": N, \"tools\": [...]}, each tool an
object with the members `cmacs-capability-describe' documents.  With
SURFACE, a symbol or its name, only the tools published there.

This is what org.cmacs.Editor1.Tools.List returns, and so what
`emacsctl tool' builds its commands and its --help from."
  (let ((surface (if (stringp surface)
                     (and (not (string-empty-p surface)) (intern surface))
                   surface)))
    (json-serialize
     (list :version cmacs-capability-version
           :tools (vconcat (mapcar #'cmacs-capability--json-tool
                                   (cmacs-capability-describe surface)))))))

;;;###autoload
(defun cmacs-capability-tool-json (name &optional surface)
  "Return the table entry of the tool NAME as a JSON object string.
Signals `cmacs-capability-error' when there is no such tool, or none on
SURFACE.  This is org.cmacs.Editor1.Tools.Describe."
  (let ((entry (cmacs-capability-describe-tool name surface)))
    (unless entry
      (signal 'cmacs-capability-error
              (list (format "no tool named %s%s" name
                            (if surface (format " on %s" surface) "")))))
    (json-serialize (cmacs-capability--json-tool entry))))


;;;; Arguments
;;
;; `cmacs-brigade--coerce' is lenient on purpose: a model that sends
;; "abc" for an integer gets the handler's own complaint, which it can
;; read and act on.  A caller on D-Bus or the command line is a program
;; or a person with a typo, and both are better served by being told
;; which argument is wrong before anything runs.  So this surface
;; validates first.  It accepts the unambiguous spellings (the string
;; "3" for an integer, 3.0 for an integer) and refuses the rest.

(defun cmacs-capability--bad (fmt &rest args)
  "Signal a `cmacs-capability-error' of kind BadArguments.
FMT and ARGS are as for `format'."
  (signal 'cmacs-capability-error
          (list (apply #'format fmt args) "BadArguments")))

(defun cmacs-capability--json-value-p (v)
  "Non-nil when V is a JSON array or object as parsed by this file."
  (or (vectorp v) (hash-table-p v)))

(defun cmacs-capability--convert (value type pname)
  "Convert VALUE to TYPE for the parameter PNAME, or signal.
Booleans come back as t or :false, the spelling
`cmacs-brigade--coerce' turns into t and nil."
  (pcase type
    ("string"
     (cond ((stringp value) value)
           ((numberp value) (number-to-string value))
           ;; The registry's types are flat by design, and its
           ;; convention for structured data is a JSON string parameter.
           ;; So an array or object given for a string parameter is
           ;; that: its JSON text.
           ((cmacs-capability--json-value-p value) (json-serialize value))
           (t (cmacs-capability--bad
               "argument `%s' must be a string" pname))))
    ("integer"
     (cond ((integerp value) value)
           ((and (floatp value) (= value (ftruncate value)))
            (truncate value))
           ((and (stringp value)
                 (string-match-p "\\`[-+]?[0-9]+\\'" value))
            (string-to-number value))
           (t (cmacs-capability--bad
               "argument `%s' must be an integer" pname))))
    ("number"
     (cond ((numberp value) value)
           ((and (stringp value)
                 (string-match-p
                  "\\`[-+]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\'"
                  value))
            (string-to-number value))
           (t (cmacs-capability--bad
               "argument `%s' must be a number" pname))))
    ("boolean"
     (cond ((eq value t) t)
           ((eq value :false) :false)
           ((member value '("true" "yes" "1")) t)
           ((member value '("false" "no" "0")) :false)
           (t (cmacs-capability--bad
               "argument `%s' must be true or false" pname))))
    (_ (cmacs-capability--bad "argument `%s' has unknown type %s"
                              pname type))))

(defun cmacs-capability-parse-args (tool json-args)
  "Return the validated argument alist for TOOL from the string JSON-ARGS.

JSON-ARGS must be a JSON object (the empty string and \"null\" mean no
arguments).  The result is an alist of (NAME . VALUE) holding only
parameters TOOL declares, each converted to its declared type, ready
for `cmacs-brigade-call-tool'.

Signals `cmacs-capability-error' -- kind \"BadArguments\" -- for text
that is not a JSON object, a member that is not a parameter, a value of
the wrong type or outside its :enum, and a required parameter that is
missing.  An unknown member is an error rather than ignored: the usual
cause is a misspelt flag, and dropping it would run the tool with a
default the caller did not ask for."
  (let* ((text (if (or (null json-args) (string-blank-p json-args))
                   "{}"
                 json-args))
         (obj (condition-case err
                  (json-parse-string text :object-type 'hash-table
                                     :array-type 'array
                                     :null-object :null
                                     :false-object :false)
                (error
                 (cmacs-capability--bad "arguments are not valid JSON: %s"
                                        (error-message-string err)))))
         (params (cmacs-brigade-tool-params tool))
         (out nil))
    (when (eq obj :null)
      (setq obj (make-hash-table :test 'equal)))
    (unless (hash-table-p obj)
      (cmacs-capability--bad "arguments must be a JSON object"))
    (maphash
     (lambda (k _v)
       (unless (cl-find k params :test #'equal
                        :key (lambda (p) (plist-get p :name)))
         (cmacs-capability--bad
          "%s has no argument `%s' (it takes: %s)"
          (cmacs-brigade-tool-wire-name tool) k
          (if params
              (mapconcat (lambda (p) (plist-get p :name)) params ", ")
            "none"))))
     obj)
    (dolist (p params)
      (let* ((pname (plist-get p :name))
             (raw (gethash pname obj :null)))
        (cond
         ;; JSON null is "not given", the same as leaving it out.
         ((eq raw :null)
          (when (and (plist-get p :required)
                     (not (plist-get p :default)))
            (cmacs-capability--bad "%s: missing required argument `%s'"
                                   (cmacs-brigade-tool-wire-name tool)
                                   pname)))
         (t
          (let ((value (cmacs-capability--convert
                        raw (plist-get p :type) pname))
                (enum (plist-get p :enum)))
            (when (and enum
                       (not (member (format "%s" value)
                                    (mapcar (lambda (e) (format "%s" e))
                                            enum))))
              (cmacs-capability--bad
               "argument `%s' must be one of: %s" pname
               (mapconcat (lambda (e) (format "%s" e)) enum ", ")))
            (push (cons pname value) out))))))
    (nreverse out)))


;;;; Calling

(defun cmacs-capability-call (name json-args surface callback)
  "Call the tool NAME for a caller on SURFACE; report through CALLBACK.

NAME is a wire name or alias, JSON-ARGS the JSON object text of its
arguments.  CALLBACK receives (KIND TEXT) exactly once: KIND is nil and
TEXT the result on success, otherwise KIND is one of

  \"NoSuchTool\"     nothing is registered under NAME
  \"NotOnSurface\"   the tool is not published on SURFACE
  \"BadArguments\"   JSON-ARGS did not validate
  \"ToolFailed\"     a hook vetoed it, confirmation refused it, or the
                   handler failed
  \"Timeout\"        an :async tool did not finish within its :timeout

and TEXT says why.  Never signals and never blocks: an :async tool's
CALLBACK runs later, from wherever the tool calls `done'.

The gates run in the order of the MCP surface -- surface, scope,
arguments, then the shared hooks and confirmation.  The scope gate is
empty here and that is a statement about D-Bus, not an omission: the
MCP surface can hand a caller a socket whose allowlist the C gate
enforces, but every process on the session bus reaches every method of
every interface, org.cmacs.Editor1.Eval included.  There is no
narrower caller to check for.  What stands in for it is the surface
gate's default, which keeps a :destructive tool off `dbus' and `cli'
until its author lists them in :surfaces.

Confirmation is not bypassed.  A tool with :confirm goes through
`cmacs-brigade-auto-approve' and the approval-handler registry exactly
as it does for an MCP caller, and where nothing can answer it is
refused: the dispatch binds `inhibit-interaction', so there is no
prompt to fall back on and no way for this call to block on one."
  (condition-case err
      (let ((tool (cmacs-brigade--tool-by-wire
                   (cmacs-brigade-wire-name name))))
        (unless tool
          (signal 'cmacs-capability-error
                  (list (format "no tool named %s" name) "NoSuchTool")))
        (unless (cmacs-brigade-tool-on-surface-p tool surface)
          (signal 'cmacs-capability-error
                  (list (format
                         "%s is not published on %s%s"
                         (cmacs-brigade-tool-wire-name tool) surface
                         (if (and (cmacs-brigade-tool-destructive tool)
                                  (null (cmacs-brigade-tool-surfaces tool)))
                             " (it is destructive, and a destructive tool \
is only there when its :surfaces list it)"
                           ""))
                        "NotOnSurface")))
        (let ((alist (cmacs-capability-parse-args tool json-args)))
          (cmacs-brigade-call-tool-async
           (cmacs-brigade-tool-wire-name tool) alist
           (lambda (status text)
             (funcall callback
                      (pcase status
                        ('ok nil)
                        ('timeout "Timeout")
                        (_ "ToolFailed"))
                      text))
           (symbol-name surface))))
    (cmacs-capability-error
     (funcall callback (or (nth 2 err) "ToolFailed") (nth 1 err)))
    (error
     (funcall callback "ToolFailed" (error-message-string err))))
  nil)

(declare-function cmacs-capability--dbus-reply "cmacs-dbus-iface-tools.c"
                  (token kind text))

(defun cmacs-capability-dbus-call (token name json-args)
  "Run the tool NAME for the D-Bus method invocation TOKEN.

Called by org.cmacs.Editor1.Tools.Call (cmacs/dbus/cmacs-dbus-tools.c)
with NAME and JSON-ARGS as string literals.  TOKEN is the integer under
which the C side parked the invocation; the answer goes back through
`cmacs-capability--dbus-reply', which answers a token once and ignores
it afterwards.  Returns nil at once -- for an :async tool the reply is
sent when the tool finishes, so the main thread is never held."
  (cmacs-capability-call
   name json-args 'dbus
   (lambda (kind text)
     (cmacs-capability--dbus-reply token kind (or text ""))))
  nil)


;;;; Documentation from the table

(defun cmacs-capability--flags (entry)
  "Return the human-readable flag list for the table ENTRY, or nil."
  (delq nil
        (list (and (plist-get entry :destructive) "destructive")
              (and (plist-get entry :confirm)
                   (format "confirm=%s" (plist-get entry :confirm)))
              (and (plist-get entry :async)
                   (format "async (timeout %ss)"
                           (plist-get entry :timeout))))))

(defun cmacs-capability--one-line (text)
  "Return TEXT with every run of whitespace collapsed to one space."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))

(defun cmacs-capability--by-group (table)
  "Return TABLE as an alist of (CLI-GROUP . ENTRIES), groups sorted."
  (let ((groups nil))
    (dolist (entry table)
      (let* ((g (car (split-string (plist-get entry :cli) " ")))
             (cell (assoc g groups)))
        (if cell
            (setcdr cell (append (cdr cell) (list entry)))
          (push (list g entry) groups))))
    (sort groups (lambda (a b) (string< (car a) (car b))))))

(defun cmacs-capability-org (table &optional title preamble)
  "Render TABLE, a `cmacs-capability-describe' value, as org text.
TITLE and PREAMBLE, both strings, replace the default heading matter."
  (with-temp-buffer
    (insert "#+title: " (or title "cmacs capability table") "\n")
    (insert (or preamble "") "\n")
    (pcase-dolist (`(,group . ,entries) (cmacs-capability--by-group table))
      (insert "* " group "\n\n")
      (dolist (e entries)
        (insert "** " (plist-get e :name) "\n\n"
                (cmacs-capability--one-line (plist-get e :description))
                "\n\n"
                "- CLI :: =emacsctl tool " (plist-get e :cli) "=\n"
                "- Surfaces :: "
                (mapconcat #'symbol-name (plist-get e :surfaces) ", ") "\n"
                "- Returns :: " (symbol-name (plist-get e :returns)) "\n")
        (when-let* ((flags (cmacs-capability--flags e)))
          (insert "- Flags :: " (string-join flags ", ") "\n"))
        (when (plist-get e :aliases)
          (insert "- Aliases :: "
                  (string-join (plist-get e :aliases) ", ") "\n"))
        (when (plist-get e :example)
          (insert "- Example :: =" (plist-get e :example) "=\n"))
        (insert "\n")
        (if (null (plist-get e :params))
            (insert "Takes no arguments.\n\n")
          (insert "| Argument | Type | Required | Description |\n"
                  "|----------+------+----------+-------------|\n")
          (dolist (p (plist-get e :params))
            (insert
             (format "| =%s= | %s | %s | %s |\n"
                     (plist-get p :name) (plist-get p :type)
                     (if (plist-get p :required) "yes" "no")
                     ;; A `|' in a description would end the cell.
                     (replace-regexp-in-string
                      "|" "\\\\vert{}"
                      (concat
                       (cmacs-capability--one-line
                        (plist-get p :description))
                       (when (plist-get p :enum)
                         (format " One of: %s."
                                 (string-join (plist-get p :enum) ", ")))
                       (when (plist-member p :default)
                         (format " Default: %s."
                                 (plist-get p :default))))))))
          (insert "\n"))))
    (buffer-string)))

(defun cmacs-capability--texi-quote (text)
  "Return TEXT with Texinfo's three special characters escaped."
  (replace-regexp-in-string "[@{}]" "@\\&" (or text "")))

(defun cmacs-capability-texi (table)
  "Render TABLE, a `cmacs-capability-describe' value, as a Texinfo fragment.
The fragment is the body of a section: @subheading per group, a @table
of tools, a @multitable of arguments.  It says what
`cmacs-capability-org' says."
  (let ((q #'cmacs-capability--texi-quote))
    (with-temp-buffer
      (pcase-dolist (`(,group . ,entries) (cmacs-capability--by-group table))
        (insert "@subheading " (funcall q group) "\n\n@table @code\n")
        (dolist (e entries)
          (insert "@item " (funcall q (plist-get e :name)) "\n"
                  (funcall q (cmacs-capability--one-line
                              (plist-get e :description)))
                  "\n\n@itemize @bullet\n"
                  "@item CLI: @command{emacsctl tool "
                  (funcall q (plist-get e :cli)) "}\n"
                  "@item Surfaces: "
                  (mapconcat #'symbol-name (plist-get e :surfaces) ", ") "\n"
                  "@item Returns: " (symbol-name (plist-get e :returns)) "\n")
          (when-let* ((flags (cmacs-capability--flags e)))
            (insert "@item Flags: " (funcall q (string-join flags ", ")) "\n"))
          (when (plist-get e :aliases)
            (insert "@item Aliases: @code{"
                    (funcall q (string-join (plist-get e :aliases) ", "))
                    "}\n"))
          (when (plist-get e :example)
            (insert "@item Example: @code{"
                    (funcall q (plist-get e :example)) "}\n"))
          (insert "@end itemize\n\n")
          (if (null (plist-get e :params))
              (insert "Takes no arguments.\n\n")
            (insert "@multitable @columnfractions .2 .12 .1 .58\n"
                    "@headitem Argument @tab Type @tab Required "
                    "@tab Description\n")
            (dolist (p (plist-get e :params))
              (insert
               "@item @code{" (funcall q (plist-get p :name)) "} @tab "
               (plist-get p :type) " @tab "
               (if (plist-get p :required) "yes" "no") " @tab "
               (funcall
                q (concat
                   (cmacs-capability--one-line (plist-get p :description))
                   (when (plist-get p :enum)
                     (format " One of: %s."
                             (string-join (plist-get p :enum) ", ")))
                   (when (plist-member p :default)
                     (format " Default: %s." (plist-get p :default)))))
               "\n"))
            (insert "@end multitable\n\n")))
        (insert "@end table\n\n"))
      (buffer-string))))

;;;###autoload
(defun cmacs-capability-doc ()
  "Show the live capability table in an org buffer.

Live means this session's registry: the shipped tools and whatever
your own configuration registered, with the surfaces each is on and
the `emacsctl tool' words that reach it.  The checked-in reference
\(doc_org/cmacs/cmacs-capability-reference.org) is the same rendering
of the shipped tools alone."
  (interactive)
  (let ((buf (get-buffer-create "*cmacs capabilities*"))
        (table (cmacs-capability-describe)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (cmacs-capability-org
                 table "cmacs capabilities (live)"
                 (format "\n%d tools in this session's registry.  \
Rendered by =M-x cmacs-capability-doc=.\n"
                         (length table))))
        (when (fboundp 'org-mode) (org-mode))
        (goto-char (point-min))
        (setq buffer-read-only t)))
    (pop-to-buffer buf)))


;;;; The checked-in reference
;;
;; Generated, then guarded: `admin/cmacs-capability-audit.sh --write-docs'
;; (or `cmacs-capability-batch-write-reference' directly) regenerates the
;; two files below from the tools the shipped lisp/cmacs files define,
;; and test/cmacs/cmacs-capability-tests.el fails when what is checked
;; in differs from what the tree would generate.

(defconst cmacs-capability-reference-org
  "doc_org/cmacs/cmacs-capability-reference.org"
  "The generated org reference, relative to the source tree's root.")

(defconst cmacs-capability-reference-texi
  "doc/cmacs/capability-reference.texi"
  "The generated Texinfo reference, relative to the source tree's root.")

(defun cmacs-capability-shipped-files (lisp-dir)
  "Return the files under LISP-DIR that register a tool, sorted.
Found by their text, not by a list kept here: a list would be one more
table to forget."
  (let ((out nil))
    (dolist (file (directory-files lisp-dir t "\\`cmacs-.*\\.el\\'"))
      (unless (string-match-p "loaddefs" file)
        (with-temp-buffer
          (insert-file-contents file)
          (when (re-search-forward
                 "^[ \t]*(cmacs-brigade-\\(?:deftool\\|register-tool\\)\\_>"
                 nil t)
            (push file out)))))
    (sort out #'string<)))

(defun cmacs-capability-load-shipped (lisp-dir)
  "Load every tool-registering file under LISP-DIR.
Returns the list of (FILE . ERROR-MESSAGE) for those that would not
load in this build -- a subsystem that was not compiled in, usually.
The registry file itself is skipped: the forms in it that match are
docstring examples."
  (let ((load-prefer-newer t)
        (failed nil))
    (dolist (file (cmacs-capability-shipped-files lisp-dir))
      (unless (member (file-name-base file)
                      '("cmacs-brigade-registry" "cmacs-capability"))
        (condition-case err
            (load (file-name-sans-extension file) nil t)
          (error (push (cons (file-name-nondirectory file)
                             (error-message-string err))
                       failed)))))
    (nreverse failed)))

(defun cmacs-capability-reference-strings ()
  "Return (ORG . TEXI), the reference for the registry as it stands.
Each ends in exactly one newline: the renderers close their last
section with a blank line, and a blank line at end of file is
something the commit hook refuses."
  (let ((raw (cmacs-capability--reference-strings-raw)))
    (cons (replace-regexp-in-string "\n+\\'" "\n" (car raw))
          (replace-regexp-in-string "\n+\\'" "\n" (cdr raw)))))

(defun cmacs-capability--reference-strings-raw ()
  "Return (ORG . TEXI) as the renderers produce them."
  (let ((table (cmacs-capability-describe)))
    (cons
     (cmacs-capability-org
      table "cmacs capability reference"
      (concat
       "#+description: Every tool the shipped lisp/cmacs files register, \
generated from the tool registry.\n"
       "\n"
       "# GENERATED FILE -- do not edit.  Regenerate with\n"
       "#   admin/cmacs-capability-audit.sh --write-docs\n"
       "# test/cmacs/cmacs-capability-tests.el fails when this is stale.\n"
       "\n"
       (format "%d tools.  Each is reachable by its wire name over MCP and \
=org.cmacs.Editor1.Tools.Call=, and by the CLI words shown, on the surfaces \
listed.  See [[file:cmacs-capability.org][cmacs-capability.org]] for how the \
table works.\n"
               (length table))))
     (concat
      "@c GENERATED FILE -- do not edit.  Regenerate with\n"
      "@c   admin/cmacs-capability-audit.sh --write-docs\n"
      "@c test/cmacs/cmacs-capability-tests.el fails when this is stale.\n"
      "\n"
      (format "%d tools.  Each is reachable by its wire name over MCP and\n\
@code{org.cmacs.Editor1.Tools.Call}, and by the CLI words shown, on the\n\
surfaces listed.\n\n"
              (length table))
      (cmacs-capability-texi table)))))

(defun cmacs-capability-batch-write-reference ()
  "Batch entry point: regenerate the checked-in reference.

Run as

  emacs --batch -Q -L lisp/cmacs -l cmacs-capability \\
        -f cmacs-capability-batch-write-reference ROOT [--check]

where ROOT is the source tree.  Loads every shipped tool file, then
writes `cmacs-capability-reference-org' and
`cmacs-capability-reference-texi' under ROOT.  With --check nothing is
written and the exit status is 1 when either file is stale.

Exits 2, writing nothing, when a tool file would not load: a reference
generated by a build that lacks a subsystem would silently drop that
subsystem's tools, and the next full build would then call it stale."
  (let* ((root (file-name-as-directory
                (expand-file-name (or (pop command-line-args-left) "."))))
         (check (equal (car command-line-args-left) "--check"))
         (failed (progn
                   (setq command-line-args-left nil)
                   (cmacs-capability-load-shipped
                    (expand-file-name "lisp/cmacs" root))))
         (stale nil))
    (when failed
      (dolist (f failed)
        (message "cmacs-capability: cannot load %s: %s" (car f) (cdr f)))
      (kill-emacs 2))
    (pcase-let ((`(,org . ,texi) (cmacs-capability-reference-strings)))
      (dolist (pair (list (cons cmacs-capability-reference-org org)
                          (cons cmacs-capability-reference-texi texi)))
        (let* ((file (expand-file-name (car pair) root))
               (old (and (file-readable-p file)
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))))
          (unless (equal old (cdr pair))
            (setq stale t)
            (if check
                (message "cmacs-capability: %s is stale" (car pair))
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (cdr pair) nil file nil 'silent))
              (message "cmacs-capability: wrote %s" (car pair)))))))
    (kill-emacs (if (and check stale) 1 0))))


;;;; Migrated families
;;
;; A hand-written MCP/D-Bus/emacsctl family is migrated by moving its
;; tools into a `cmacs-<subsystem>-tools.el' of `cmacs-brigade-deftool'
;; forms and naming that file here.  The files are loaded with the
;; brigade (see the end of cmacs-brigade-tools.el), which is before an
;; MCP session can ask what tools exist.  The recipe is in
;; doc_org/cmacs/cmacs-capability.org.

(defconst cmacs-capability-migrated-families
  '((cmacs-calculator-tools . IS-CMACS-CALCULATOR)
    ;; The editor core: built into every cmacs.
    (cmacs-buffer-tools . t)
    (cmacs-window-tools . t)
    (cmacs-edit-tools . t)
    (cmacs-process-tools . t)
    (cmacs-debug-tools . t)
    (cmacs-project-tools . t)
    (cmacs-describe-tools . t)
    (cmacs-gi-tools . IS-CMACS-GI)
    (cmacs-gowl-tools . IS-CMACS-GOWL)
    (cmacs-ai-tools . IS-CMACS-AI)
    (cmacs-audio-tools . IS-CMACS-AUDIO)
    (cmacs-secondbrain-tools . IS-CMACS-SECONDBRAIN)
    (cmacs-dbexplorer-tools . IS-CMACS-DBEXPLORER)
    (cmacs-gsurf-tools . IS-CMACS-GSURF)
    (cmacs-gnuseye-tools . IS-CMACS-GNUSEYE)
    (cmacs-libregnum-tools . IS-CMACS-LIBREGNUM)
    (cmacs-lrgterm-tools . IS-CMACS-LRGTERM)
    (cmacs-cad-tools . IS-CMACS-CAD)
    (cmacs-imgedit-tools . IS-CMACS-IMGEDIT)
    (cmacs-vidstudio-tools . IS-CMACS-VIDSTUDIO)
    (cmacs-lql-watch-tools . IS-CMACS-LQL))
  "Alist of (FEATURE . FLAG): tool files to load when FLAG is non-nil.
FLAG is an `IS-CMACS-*' variable from cmacs/core/cmacs-features.c, so a
family is only offered by a build that compiled its subsystem in; t
names a family of the always-built core.")

(provide 'cmacs-capability)

;; After `provide': a family file requires the registry, which may be
;; what is loading us.
;; Declared special HERE as well as in the registry.  The binding below
;; is dynamic only if this file's compilation knows the variable is
;; special, and a build that compiles this file against a registry .elc
;; older than the variable bakes in a lexical binding instead: every
;; family then loads unmarked, and every migrated tool is refused by the
;; MCP publisher in favour of its C twin, silently.
(defvar cmacs-brigade-registering-shipped-family)

(pcase-dolist (`(,feature . ,flag) cmacs-capability-migrated-families)
  (when (or (eq flag t) (and (boundp flag) (symbol-value flag)))
    ;; Bound so the registry knows these tools are the shipped
    ;; replacements of hand-written C tools: the MCP publisher lets only
    ;; those take a built-in's name.
    (let ((cmacs-brigade-registering-shipped-family feature))
      (require feature nil 'noerror))))

;;; cmacs-capability.el ends here
