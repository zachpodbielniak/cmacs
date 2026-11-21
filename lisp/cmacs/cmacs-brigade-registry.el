;;; cmacs-brigade-registry.el --- The brigade extension surface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; This is the file the brigade exists for.
;;
;; Registering a capability is one form, and that one form publishes it
;; to every consumer at once:
;;
;;   1. in-process agents      -- as a tool on the agent's executor
;;   2. CLI agents             -- as an MCP tool through `emacs
;;                                --mcp-relay', scoped by the agent's
;;                                capability token
;;   3. external MCP clients   -- on cmacs's own MCP server
;;
;;   (cmacs-brigade-deftool weather-now
;;     "Current conditions for a place."
;;     ((place string "City or 'lat,lon'"))
;;     :group 'weather
;;     (my/fetch-weather place))
;;
;; Everything the shipped brigade features use goes through these same
;; functions.  There are deliberately no private back doors: when a
;; built-in needed a hook, that hook was made public rather than
;; special-cased, because a fabric whose own features bypass its API is
;; one whose API has not actually been tested.
;;
;; The registries are all the same shape -- a hash table of plists keyed
;; by a symbol, with a `-register-' writer, a `-get' reader and a
;; `-list' enumerator -- so learning one teaches the rest.

;;; Code:

(require 'cmacs-brigade)
(require 'cl-lib)
(require 'subr-x)

;;;; Options and hooks
;;
;; Declared first so the registration functions below can reference them
;; at byte-compile time without a free-variable warning.

(defcustom cmacs-brigade-tool-default-timeout 120
  "Seconds an async tool may run before it is abandoned.
Per-tool `:timeout' overrides this."
  :type 'integer
  :group 'cmacs-brigade)

(defvar cmacs-brigade-tool-registered-functions nil
  "Abnormal hook run with the `cmacs-brigade-tool' struct after registration.
Used by the MCP layer to announce a changed tool list to connected
clients; available for anything that needs to react to the tool set
growing.")

(defvar cmacs-brigade-before-tool-call-functions nil
  "Abnormal hook run before dispatching a tool call.
Each function receives a plist with :tool, :args and :agent.  Returning
nil from any function *vetoes* the call, which is how a configuration
adds its own policy layer without touching the C gate.")

(defvar cmacs-brigade-after-tool-call-functions nil
  "Abnormal hook run after a tool call returns.
Receives a plist with :tool, :args, :agent, :result and :error.")

(defvar cmacs-brigade--registries (make-hash-table :test 'eq)
  "Hash of KIND symbol -> hash table of NAME symbol -> plist.
One table per registry kind so `cmacs-brigade-registry-list' can
enumerate any of them without each kind needing its own variable.")

(defun cmacs-brigade--registry (kind)
  "Return the registry table for KIND, creating it on first use."
  (or (gethash kind cmacs-brigade--registries)
      (puthash kind (make-hash-table :test 'eq)
               cmacs-brigade--registries)))

(defun cmacs-brigade-registry-list (kind)
  "Return the names registered under KIND, sorted.
KIND is one of `tool', `agent', `worker', `isolation', `memory-source',
`deliverable', `panel', `context-provider', `client' or
`approval-handler'."
  (sort (hash-table-keys (cmacs-brigade--registry kind))
        (lambda (a b) (string< (symbol-name a) (symbol-name b)))))

(defun cmacs-brigade-registry-get (kind name)
  "Return the plist registered for NAME under KIND, or nil."
  (gethash name (cmacs-brigade--registry kind)))

(defun cmacs-brigade--registry-put (kind name plist)
  "Store PLIST for NAME under KIND.  Returns NAME."
  (puthash name plist (cmacs-brigade--registry kind))
  name)


;;;; Wire names
;;
;; Lisp symbols are kebab-case; tool names on the wire are snake_case,
;; because that is what every provider's function-calling schema and the
;; MCP tool namespace use.  The translation is mechanical and happens in
;; exactly one place so a tool cannot be registered under one spelling
;; and looked up under the other.

(defun cmacs-brigade-wire-name (symbol-or-string)
  "Return the wire name for SYMBOL-OR-STRING as a string.
Hyphens become underscores; an already-underscored string is unchanged."
  (let ((s (if (symbolp symbol-or-string)
               (symbol-name symbol-or-string)
             symbol-or-string)))
    (replace-regexp-in-string "-" "_" s)))


;;;; Tools

(defconst cmacs-brigade-tool-types
  '("string" "integer" "number" "boolean" "array" "object")
  "Parameter types a tool may declare.

The four scalars, and two structured types:

  array   a JSON array.  `:items' says what one element is -- a type
          name, or (TYPE KEYWORD...) for an element that is itself an
          array or an object.  Without `:items' the elements are
          free-form.
  object  a JSON object.  `:properties' lists its members as parameter
          specs, (NAME TYPE DOC KEYWORD...), each required unless
          marked `:optional'.  Without `:properties' the object is
          free-form: any members, passed through as they arrive.

A handler receives structured values as Lisp data in the shape this
file's `json-parse-string' calls have always produced: an array is a
LIST, an object is an ALIST with SYMBOL keys, in the order the caller
wrote them.  See `cmacs-brigade-structured-value'.")

(defconst cmacs-brigade-tool-structured-types '("array" "object")
  "The parameter types whose values are Lisp data rather than atoms.")

(cl-defstruct (cmacs-brigade-tool (:constructor cmacs-brigade--make-tool)
                                  (:copier nil))
  "A capability published to every agent surface."
  name            ; symbol, as written by the user
  wire-name       ; string, snake_case
  description
  params          ; list of plists (:name :type :doc :required :default :enum)
  group           ; symbol or nil
  destructive     ; boolean
  confirm         ; nil | ask | always
  async           ; boolean
  timeout         ; seconds
  handler         ; function
  menu            ; nil | t | (TARGET-KIND...) -- see `cmacs-ai-menu'
  menu-label      ; string shown in the menu instead of the tool name
  ;; Capability-table metadata (see cmacs-capability.el).  New slots go
  ;; at the END: accessors are compiled to slot indexes, so a stale .elc
  ;; of some other file keeps reading the right field.
  surfaces        ; nil (= default set) | list of mcp dbus cli menu agents
  cli             ; nil (= derived) | "GROUP VERB"
  returns         ; string | json -- how a client should render the result
  example         ; nil | string, one sample invocation for the docs
  aliases)        ; list of extra wire names answering to this tool

(define-error 'cmacs-brigade-tool-error
  "Invalid brigade tool definition" 'cmacs-brigade-error)

(defconst cmacs-brigade-tool-surfaces '(mcp dbus cli menu agents)
  "Every surface a registered tool can be published on.

  agents  in-process agent executors (`cmacs-brigade-install-tools')
  mcp     cmacs's MCP server: external clients, and CLI agents through
          the relay and the scoped sockets
  dbus    org.cmacs.Editor1.Tools
  cli     `emacsctl tool ...', which rides the D-Bus interface and so
          also needs `dbus'
  menu    the AI right-click menu, for a tool that also sets :menu

A tool that gives no :surfaces is on all of them, with one exception
decided in `cmacs-brigade-tool-effective-surfaces': a :destructive tool
stays off `dbus' and `cli' until it names them.")

(defconst cmacs-brigade-tool-cli-reserved '("list" "describe" "call" "help")
  "Words `emacsctl tool' keeps for itself, so no tool group may be one.")

(defun cmacs-brigade-tool-effective-surfaces (tool)
  "Return the list of surfaces TOOL is actually published on.

An explicit :surfaces is taken as written.  Without one the answer is
every surface, except that a destructive tool is left off `dbus' and
`cli'.  The reason is that those two cannot be scoped: an MCP caller can
be handed a socket whose allowlist the C gate enforces, an in-process
agent only ever holds the tools it was built with, but anything on the
session bus reaches every method of every interface.  So the registry
does not put a destructive capability one `gdbus call' away by default;
its author says so explicitly, by listing `dbus' in :surfaces."
  (or (cmacs-brigade-tool-surfaces tool)
      (if (cmacs-brigade-tool-destructive tool)
          (cl-set-difference cmacs-brigade-tool-surfaces '(dbus cli))
        cmacs-brigade-tool-surfaces)))

(defun cmacs-brigade-tool-on-surface-p (tool surface)
  "Non-nil when TOOL is published on SURFACE.
`cli' additionally needs `dbus', which is the wire it travels on."
  (let ((on (cmacs-brigade-tool-effective-surfaces tool)))
    (and (memq surface on)
         (or (not (eq surface 'cli)) (memq 'dbus on))
         t)))

(defun cmacs-brigade--check-tool-metadata (name surfaces cli returns example
                                                aliases)
  "Signal `cmacs-brigade-tool-error' unless the capability keys are valid.
NAME is the tool being registered; the rest are its SURFACES, CLI,
RETURNS, EXAMPLE and ALIASES arguments."
  (unless (and (listp surfaces)
               (cl-every (lambda (s) (memq s cmacs-brigade-tool-surfaces))
                         surfaces))
    (signal 'cmacs-brigade-tool-error
            (list (format "surfaces must be a list drawn from %S"
                          cmacs-brigade-tool-surfaces)
                  name surfaces)))
  (when cli
    ;; Exactly GROUP VERB, in the alphabet a shell word needs no quoting
    ;; for.  The CLI resolves two words and nothing else, so a verb with
    ;; a space in it could be registered and never be typed.
    (unless (and (stringp cli)
                 (string-match-p
                  "\\`[a-z][a-z0-9-]* [a-z][a-z0-9-]*\\'" cli)
                 (not (member (car (split-string cli " "))
                              cmacs-brigade-tool-cli-reserved)))
      (signal 'cmacs-brigade-tool-error
              (list "cli must be \"GROUP VERB\" in [a-z0-9-], and GROUP \
must not be list, describe, call or help" name cli))))
  (unless (memq returns '(nil string json))
    (signal 'cmacs-brigade-tool-error
            (list "returns must be `string' or `json'" name returns)))
  (unless (or (null example) (stringp example))
    (signal 'cmacs-brigade-tool-error
            (list "example must be a string" name example)))
  (unless (and (listp aliases)
               (cl-every (lambda (a) (or (stringp a) (symbolp a))) aliases))
    (signal 'cmacs-brigade-tool-error
            (list "aliases must be a list of names" name aliases))))

(defun cmacs-brigade--type-name (type spec)
  "Return TYPE, a symbol or string, as a known type name.
SPEC is what is being parsed, for the error."
  (let ((name (if (symbolp type) (symbol-name type) type)))
    (unless (member name cmacs-brigade-tool-types)
      (signal 'cmacs-brigade-tool-error
              (list (format "unknown parameter type %S; expected one of %s"
                            type (string-join cmacs-brigade-tool-types ", "))
                    spec)))
    name))

(defun cmacs-brigade--parse-schema (type kw spec)
  "Return the schema plist for TYPE with the keyword list KW.
A schema is (:type NAME [:items SCHEMA] [:properties PARAMS]): what a
value looks like, without a name or a description.  SPEC is the
enclosing spec, for errors.  `:items' and `:properties' are checked
against TYPE, because an `:items' on a string would be accepted here
and then ignored by every surface."
  (let ((type-name (cmacs-brigade--type-name type spec))
        (items (plist-get kw :items))
        (props (plist-get kw :properties)))
    (when (and items (not (equal type-name "array")))
      (signal 'cmacs-brigade-tool-error
              (list ":items only applies to an array parameter" spec)))
    (when (and props (not (equal type-name "object")))
      (signal 'cmacs-brigade-tool-error
              (list ":properties only applies to an object parameter" spec)))
    (append
     (list :type type-name)
     (when items
       (list :items
             ;; A bare type name, or (TYPE KEYWORD...) for an element
             ;; that is itself structured.
             (if (consp items)
                 (cmacs-brigade--parse-schema (car items) (cdr items) spec)
               (cmacs-brigade--parse-schema items nil spec))))
     (when props
       (unless (listp props)
         (signal 'cmacs-brigade-tool-error
                 (list ":properties must be a list of parameter specs" spec)))
       (list :properties (mapcar #'cmacs-brigade--parse-param props))))))

(defun cmacs-brigade--parse-param (spec)
  "Normalise one parameter SPEC into a plist.
SPEC is (NAME TYPE DOC &rest KEYWORDS) where KEYWORDS may include
:optional, :default and :enum, and for the structured types :items (on
an array) and :properties (on an object) -- see
`cmacs-brigade-tool-types'.  The members of an object are parsed by
this same function, so they nest."
  (unless (and (consp spec) (>= (length spec) 3))
    (signal 'cmacs-brigade-tool-error
            (list "parameter spec needs (NAME TYPE DOC ...)" spec)))
  (let* ((name (nth 0 spec))
         (type (nth 1 spec))
         (doc  (nth 2 spec))
         (kw   (nthcdr 3 spec))
         (schema (cmacs-brigade--parse-schema type kw spec)))
    (unless (stringp doc)
      (signal 'cmacs-brigade-tool-error
              (list "parameter description must be a string" spec)))
    (append
     (list :name     (cmacs-brigade-wire-name name)
           :type     (plist-get schema :type)
           :doc      doc
           ;; Required unless explicitly marked optional.  Defaulting to
           ;; required is the safer error: a model omitting an argument
           ;; the handler needs fails loudly instead of receiving nil.
           :required (not (plist-get kw :optional))
           :default  (plist-get kw :default)
           :enum     (plist-get kw :enum))
     ;; Only present on a structured parameter, so the plist of a scalar
     ;; one is exactly what it was before these types existed.
     (when (plist-member schema :items)
       (list :items (plist-get schema :items)))
     (when (plist-member schema :properties)
       (list :properties (plist-get schema :properties))))))

(defun cmacs-brigade-param-structured-p (param)
  "Non-nil when PARAM, a parsed parameter plist, is an array or an object."
  (and (member (plist-get param :type) cmacs-brigade-tool-structured-types)
       t))

;;;; Structured parameters
;;
;; One description of a structured value, read by every surface: the
;; JSON Schema below is what MCP clients and providers are shown, and
;; `cmacs-brigade-structured-value' is what turns whatever arrived into
;; the one shape a handler is written against.

(defun cmacs-brigade-param-json-schema (schema &optional description)
  "Return SCHEMA as a JSON Schema, in the shape `json-serialize' takes.
SCHEMA is a parsed parameter plist or the value of its :items.  With
DESCRIPTION, a string, the result carries it.

An array with no :items and an object with no :properties come out as
the bare type, which is JSON Schema's way of saying free-form."
  (let ((type (plist-get schema :type))
        (items (plist-get schema :items))
        (props (plist-get schema :properties))
        (enum (plist-get schema :enum))
        (out (make-hash-table :test 'equal)))
    (puthash "type" type out)
    (when (and description (not (string-empty-p description)))
      (puthash "description" description out))
    (when enum
      (puthash "enum" (vconcat (mapcar (lambda (e) (format "%s" e)) enum))
               out))
    (when items
      (puthash "items" (cmacs-brigade-param-json-schema items) out))
    (when props
      (let ((members (make-hash-table :test 'equal))
            (required nil))
        (dolist (p props)
          (puthash (plist-get p :name)
                   (cmacs-brigade-param-json-schema p (plist-get p :doc))
                   members)
          (when (plist-get p :required)
            (push (plist-get p :name) required)))
        (puthash "properties" members out)
        (puthash "required" (vconcat (nreverse required)) out)))
    out))

(defun cmacs-brigade-param-type-label (schema)
  "Return a short human description of SCHEMA's type.
\"string\", \"array of integer\", \"object {app, keys}\", \"array of
object {x, y}\".  Used by the generated reference, `--help' and the
menu prompt, so all three name a structured parameter the same way."
  (pcase (plist-get schema :type)
    ("array"
     (if-let* ((items (plist-get schema :items)))
         (concat "array of " (cmacs-brigade-param-type-label items))
       "array"))
    ("object"
     (if-let* ((props (plist-get schema :properties)))
         (format "object {%s}"
                 (mapconcat (lambda (p) (plist-get p :name)) props ", "))
       "object"))
    (type type)))

(defun cmacs-brigade--structured-bad (path fmt &rest args)
  "Signal an error about the argument at PATH.
FMT and ARGS are as for `format'.

A plain `error', not `cmacs-brigade-tool-error': that one's message is
\"Invalid brigade tool definition\", which is what a caller would then
be told about a tool that is defined perfectly well.  The text reaches
a model as \"Error: argument `rule.keys[2]' must be a string\", which
it can act on."
  (error "%s" (format "argument `%s' %s" path (apply #'format fmt args))))

(defun cmacs-brigade--json-lisp (value)
  "Return VALUE with every JSON container in the registry's shape.
Vectors become lists and hash tables become alists with symbol keys,
recursively; `:null' becomes nil.  Anything else is returned as is, so
data already in that shape passes through unchanged."
  (cond
   ((eq value :null) nil)
   ((vectorp value) (mapcar #'cmacs-brigade--json-lisp value))
   ((hash-table-p value)
    (let ((out nil))
      (maphash (lambda (k v)
                 (push (cons (if (symbolp k) k (intern (format "%s" k)))
                             (cmacs-brigade--json-lisp v))
                       out))
               value)
      (nreverse out)))
   (t value)))

(defun cmacs-brigade--alist-p (value)
  "Non-nil when VALUE is a list of (KEY . VALUE) pairs with name keys."
  (and (listp value)
       (cl-every (lambda (c) (and (consp c)
                                  (or (symbolp (car c)) (stringp (car c)))
                                  (car c)))
                 value)))

(defun cmacs-brigade--scalar-value (value type path)
  "Return VALUE converted to the scalar TYPE, or signal naming PATH.
Accepts what is unambiguous -- the string \"3\" for an integer -- and
refuses the rest: inside a structure there is no handler-side check to
fall back on, so a wrong kind is reported here."
  (pcase type
    ("string"
     (cond ((stringp value) value)
           ((numberp value) (number-to-string value))
           (t (cmacs-brigade--structured-bad path "must be a string"))))
    ("integer"
     (cond ((integerp value) value)
           ((and (floatp value) (= value (ftruncate value))) (truncate value))
           ((and (stringp value) (string-match-p "\\`[-+]?[0-9]+\\'" value))
            (string-to-number value))
           (t (cmacs-brigade--structured-bad path "must be an integer"))))
    ("number"
     (cond ((numberp value) value)
           ((and (stringp value)
                 (string-match-p
                  "\\`[-+]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\'"
                  value))
            (string-to-number value))
           (t (cmacs-brigade--structured-bad path "must be a number"))))
    ("boolean"
     (cond ((memq value '(t :true)) t)
           ((memq value '(nil :false)) nil)
           ((member value '("true" "yes")) t)
           ((member value '("false" "no")) nil)
           (t (cmacs-brigade--structured-bad path "must be true or false"))))
    (_ value)))

(defun cmacs-brigade--structured-walk (value schema path)
  "Return VALUE checked and converted against SCHEMA.
VALUE is already in list/alist form; PATH names it in errors."
  (pcase (plist-get schema :type)
    ("array"
     (unless (listp value)
       (cmacs-brigade--structured-bad path "must be an array"))
     ;; An object that reached here already parsed (a provider's or an
     ;; MCP client's arguments are alists by now) is a list too -- of
     ;; pairs whose car is a plain symbol, which no JSON array element
     ;; can be.  Without this an object given for an array of anything
     ;; would be taken as an array of its members.
     (when (and value
                (cl-every (lambda (c)
                            (and (consp c)
                                 (cmacs-brigade--json-key-p (car c))))
                          value))
       (cmacs-brigade--structured-bad path
                                      "must be an array, not an object"))
     (let ((items (plist-get schema :items))
           (n -1))
       (if (null items)
           value
         (mapcar (lambda (v)
                   (cmacs-brigade--structured-walk
                    v items (format "%s[%d]" path (cl-incf n))))
                 value))))
    ("object"
     (unless (cmacs-brigade--alist-p value)
       (cmacs-brigade--structured-bad path "must be an object"))
     (let* ((props (plist-get schema :properties))
            (alist (mapcar (lambda (c)
                             (cons (if (symbolp (car c)) (car c)
                                     (intern (car c)))
                                   (cdr c)))
                           value)))
       (dolist (p props)
         (let* ((key (intern (plist-get p :name)))
                (cell (assq key alist))
                (sub (format "%s.%s" path key)))
           (cond
            ;; Absent: an error when required, otherwise simply not
            ;; there, so `alist-get' answers nil.
            ((null cell)
             (when (plist-get p :required)
               (cmacs-brigade--structured-bad sub "is required")))
            ;; JSON null for a scalar is "not given".  (For a boolean
            ;; nil is false, and for an array or object it is the empty
            ;; one; both go on to the walk.)
            ((and (null (cdr cell))
                  (member (plist-get p :type)
                          '("string" "integer" "number")))
             (when (plist-get p :required)
               (cmacs-brigade--structured-bad sub "is required")))
            (t
             (setcdr cell (cmacs-brigade--structured-walk (cdr cell) p sub))
             (when-let* ((enum (plist-get p :enum)))
               (unless (member (format "%s" (cdr cell))
                               (mapcar (lambda (e) (format "%s" e)) enum))
                 (cmacs-brigade--structured-bad
                  sub "must be one of: %s"
                  (mapconcat (lambda (e) (format "%s" e)) enum ", "))))))))
       ;; Members the schema does not list are kept: an object is open
       ;; unless its tool says otherwise in the handler.
       alist))
    (type (cmacs-brigade--scalar-value value type path))))

;;;###autoload
(defun cmacs-brigade-structured-value (value param)
  "Return VALUE as the Lisp data a handler receives for PARAM.

PARAM is a parsed parameter plist of type `array' or `object'.  VALUE
may be what any surface delivers:

  a string      JSON text -- what a model sends when it stringifies an
                argument, what `emacsctl tool' passes for --NAME
                \\='<json>\\=', and what the menu reads
  a vector / hash table
                `json-parse-string' output with its default types
  a list / alist
                already in the registry's shape

and the result is always the same shape:

  array   a list of its elements
  object  an alist with SYMBOL keys, in the order given

so a handler reads an object with `alist-get' and walks an array with
`dolist'.  nil is both the empty array and the empty object.

Where PARAM declares :items or :properties the contents are checked and
converted too: a declared scalar becomes a string, an integer, a number
or t/nil, a required member that is missing is an error, an :enum is
enforced.  Free-form contents (no :items, no :properties, or members a
:properties list does not mention) are passed through as parsed, which
means JSON false is `:false' and JSON null is nil there -- the
convention of this registry's `json-parse-string' calls.

Signals an error whose message names the argument and the path inside
it (`rule.keys[2]') when VALUE does not fit."
  (let* ((name (plist-get param :name))
         (type (plist-get param :type))
         ;; Text is parsed with the parser's own container types first,
         ;; because a vector and a hash table still say which of the two
         ;; the caller wrote; a list and an alist no longer do.
         (raw (if (not (stringp value))
                  value
                (if (string-blank-p value)
                    nil
                  (condition-case err
                      (json-parse-string value :null-object nil
                                         :false-object :false)
                    (error
                     (cmacs-brigade--structured-bad
                      name "must be a JSON %s: %s" type
                      (error-message-string err))))))))
    (cond
     ((and (equal type "array") (hash-table-p raw))
      (cmacs-brigade--structured-bad name "must be an array, not an object"))
     ((and (equal type "object") (vectorp raw))
      (cmacs-brigade--structured-bad name "must be an object, not an array"))
     ;; A string that parsed to a scalar ("3", "true") is no container.
     ((and (stringp value) raw (not (vectorp raw)) (not (hash-table-p raw)))
      (cmacs-brigade--structured-bad name "must be a JSON %s" type)))
    (cmacs-brigade--structured-walk (cmacs-brigade--json-lisp raw)
                                    param name)))

(defun cmacs-brigade--json-key-p (key)
  "Non-nil when KEY can only be an object member's name.
A symbol other than nil, t and the keywords -- which are how JSON null,
true and false read in this registry's data, and so may also be the
first ELEMENT of an array."
  (and key (symbolp key) (not (eq key t)) (not (keywordp key))))

(defun cmacs-brigade--json-ready (value schema)
  "Return VALUE, in a handler's shape, as `json-serialize' input.
SCHEMA is the schema plist that describes VALUE, or nil where the tool
left it free-form."
  (pcase (plist-get schema :type)
    ("array"
     (let ((items (plist-get schema :items)))
       (vconcat (mapcar (lambda (v) (cmacs-brigade--json-ready v items))
                        value))))
    ("object"
     (let ((out (make-hash-table :test 'equal))
           (props (plist-get schema :properties)))
       (dolist (cell value)
         (let ((key (format "%s" (car cell))))
           (puthash key
                    (cmacs-brigade--json-ready
                     (cdr cell)
                     (cl-find key props :test #'equal
                              :key (lambda (p) (plist-get p :name))))
                    out)))
       out))
    ("boolean" (if (memq value '(nil :false)) :false t))
    ((or "string" "integer" "number") (if (null value) :null value))
    (_
     ;; Free-form.  The shape itself has to say what this was.
     (cond
      ((null value) :null)
      ((memq value '(t :false :null)) value)
      ((vectorp value)
       (vconcat (mapcar (lambda (v) (cmacs-brigade--json-ready v nil))
                        value)))
      ((hash-table-p value) value)
      ((and (consp value)
            (cl-every (lambda (c)
                        (and (consp c) (cmacs-brigade--json-key-p (car c))))
                      value))
       (cmacs-brigade--json-ready value '(:type "object")))
      ((listp value)
       (cmacs-brigade--json-ready value '(:type "array")))
      (t value)))))

;;;###autoload
(defun cmacs-brigade-structured-json (value param)
  "Return VALUE, an argument a handler received for PARAM, as JSON text.

The inverse of `cmacs-brigade-structured-value', for a tool that hands
its argument on -- to a module's command line, a subprocess, a file --
rather than taking it apart.  PARAM is the parsed parameter, or a
schema plist such as (:type \"object\"); it settles what VALUE is at the
top (nil is {} for an object and [] for an array) and wherever the tool
declared :items or :properties.

In free-form positions the data has to speak for itself, and two things
it cannot say.  A list is written as an object when every element is a
pair whose car is a plain symbol, and as an array otherwise.  And nil is
written as null: an empty array or object nested inside free-form data
arrives as nil (the registry parses with `:array-type \\='list' and
`:null-object nil') and cannot be told from a null any more.  A tool
that needs that distinction should declare the member."
  (decode-coding-string
   (json-serialize (cmacs-brigade--json-ready value param)
                   :null-object :null :false-object :false)
   'utf-8 t))

(defun cmacs-brigade--structured-handler (handler params async)
  "Return HANDLER wrapped to receive structured arguments as Lisp data.
PARAMS are the tool's parsed parameters and ASYNC is its :async flag
\(the wrapper then leaves the leading DONE argument alone).

The conversion lives on the handler, not in one surface's dispatch, so
every way of reaching a tool -- a provider's tool call, MCP, D-Bus, the
menu's minibuffer, a direct `funcall' in a test -- hands the body the
same data.  A tool with no structured parameter is not wrapped at all."
  (if (not (cl-some #'cmacs-brigade-param-structured-p params))
      handler
    (lambda (&rest args)
      (let ((head (and async (list (pop args))))
            (out nil))
        (dolist (p params)
          (let ((arg (pop args)))
            (push (cond
                   ((not (cmacs-brigade-param-structured-p p)) arg)
                   ;; An optional argument that was not given stays nil.
                   ;; Walking it would read nil as the empty object and
                   ;; then demand that object's required members.
                   ((and (null arg) (not (plist-get p :required))) nil)
                   (t (cmacs-brigade-structured-value arg p)))
                  out)))
        (apply handler (append head (nreverse out)))))))

(defun cmacs-brigade-tool-provider-params (tool)
  "Return TOOL's parameters in the form `cmacs-ai-tools-register' takes.
Each is (NAME TYPE DESCRIPTION REQUIRED [ITEM-SCHEMA-JSON]).  The fifth
element is only there for an array that declares :items: the JSON
Schema of one element, which ai-glib publishes as the array's `items'
\(Gemini refuses an array with none).  An object goes out as the bare
type with its members named in the description, because ai-glib's
parameter model has no nested properties."
  (mapcar
   (lambda (p)
     (let ((items (plist-get p :items))
           (props (plist-get p :properties)))
       (append
        (list (plist-get p :name)
              (plist-get p :type)
              (if props
                  (format "%s  (JSON object with members: %s.)"
                          (plist-get p :doc)
                          (mapconcat
                           (lambda (m)
                             (format "%s (%s%s)" (plist-get m :name)
                                     (cmacs-brigade-param-type-label m)
                                     (if (plist-get m :required)
                                         "" ", optional")))
                           props ", "))
                (plist-get p :doc))
              (plist-get p :required))
        (when items
          (list (json-serialize
                 (cmacs-brigade-param-json-schema items)))))))
   (cmacs-brigade-tool-params tool)))

(defun cmacs-brigade-read-param (param)
  "Read a value for PARAM, a parsed parameter plist, from the minibuffer.
A scalar is read as text, as the menu always did.  An array or object
is asked for as what it is -- JSON -- with its shape in the prompt, and
the answer is parsed before it is returned, so a typo is reported at
the prompt instead of inside the tool.  An empty answer is nil."
  (let ((name (plist-get param :name))
        (doc (or (plist-get param :doc) "")))
    (if (not (cmacs-brigade-param-structured-p param))
        (read-string (format "%s (%s): " name doc) nil nil "")
      (let ((text (read-string
                   (format "%s (%s) as JSON, %s: " name doc
                           (cmacs-brigade-param-type-label param))
                   nil nil "")))
        (cmacs-brigade-structured-value text param)))))

(defun cmacs-brigade--params-json (params)
  "Serialise PARAMS to the JSON array the C mirror stores.
A structured parameter carries one more member, \"schema\": its
complete JSON Schema, which the MCP publisher copies into the tool's
input schema verbatim instead of building one from the type name."
  (json-serialize
   (vconcat
    (mapcar (lambda (p)
              (append
               (list :name        (plist-get p :name)
                     :type        (plist-get p :type)
                     :description (plist-get p :doc)
                     :required    (if (plist-get p :required) t :false))
               (when (cmacs-brigade-param-structured-p p)
                 (list :schema (cmacs-brigade-param-json-schema
                                p (plist-get p :doc))))))
            params))))

;;;; Shipped families
;;
;; A shipped tool is one a file in `cmacs-capability-migrated-families'
;; registered, as opposed to one from a user's init or a package.  The
;; distinction used to decide publication: a shipped tool was allowed to
;; take the name of the hand-written C MCP tool it replaced.  Those C
;; handlers are deleted, so nothing is arbitrated any more -- the MCP
;; publisher refuses ANY registry tool whose name one of the remaining
;; C tools serves (`eval', `send_keys', ...), shipped or not.  What is
;; left is bookkeeping: which wire names came with cmacs.

(defvar cmacs-brigade-registering-shipped-family nil
  "Non-nil while a shipped tool family is being loaded: its feature.
Bound by `cmacs-capability--load-family' around each file named in
`cmacs-capability-migrated-families'.  A tool registered meanwhile is
remembered in `cmacs-brigade--shipped-tools'.  It gives the tool no
privilege.")

(defvar cmacs-brigade--shipped-tools (make-hash-table :test #'equal)
  "Wire names registered while a shipped family was loading.
Sticky on purpose: re-evaluating a family file while working on it does
not make its tools look like a user's.")

(defun cmacs-brigade--shipped-tool-p (wire)
  "Return non-nil when the tool with wire name WIRE is a shipped one.
Records WIRE as shipped when called during a family load."
  (when cmacs-brigade-registering-shipped-family
    (puthash wire t cmacs-brigade--shipped-tools))
  (gethash wire cmacs-brigade--shipped-tools))

;;;###autoload
(cl-defun cmacs-brigade-register-tool
    (&key name description params handler
          group destructive confirm async timeout menu menu-label
          surfaces cli returns example aliases)
  "Publish a capability to every brigade agent surface.

NAME is a symbol; the wire name is its snake_case form.  DESCRIPTION is
what a model reads to decide whether to call it, so it should say what
the tool does and when to use it.  PARAMS is a list of
\(NAME TYPE DOC &rest KEYWORDS) specs; TYPE is one of
`cmacs-brigade-tool-types' and KEYWORDS are :optional, :default, :enum,
and for an array or object :items and :properties.  HANDLER is the
function; it receives an array as a list and an object as an alist with
symbol keys (`cmacs-brigade-structured-value').

Optional keys:

  GROUP        symbol; allowlist vocabulary, so an agent can be granted
               a whole area at once
  DESTRUCTIVE  non-nil excludes the tool from read-only agents
  CONFIRM      nil, `ask' or `always'; gated through the approval
               handler before dispatch
  ASYNC        non-nil means HANDLER takes one extra leading argument,
               a DONE callback, and its return value is ignored
  TIMEOUT      seconds before an async call is abandoned
  MENU         non-nil publishes the tool to the AI right-click menu as
               well.  t means \"offer it on anything\"; a list of target
               kinds -- (region file org-node ...) -- restricts it to
               those.  The tool's first parameter receives the rendered
               target; the rest are read from the minibuffer.  A tool
               marked DESTRUCTIVE or CONFIRM is confirmed before it runs,
               because a menu click must not become a quieter way to do
               something the tool itself considers worth asking about.
  MENU-LABEL   menu text, when the tool's name is not what you want to
               read there
  SURFACES     list of the surfaces to publish on, drawn from
               `cmacs-brigade-tool-surfaces'.  Omitted means all of
               them, except that a DESTRUCTIVE tool is kept off `dbus'
               and `cli' until it lists them -- see
               `cmacs-brigade-tool-effective-surfaces'
  CLI          \"GROUP VERB\", the words after `emacsctl tool'.  Omitted
               means derived from GROUP and NAME -- see
               `cmacs-capability-cli-verb'
  RETURNS      `string' (the default) or `json': how a client should
               render the result
  EXAMPLE      one sample invocation, shown in the generated reference
  ALIASES      extra wire names that answer to this tool, for a
               capability that used to be published under another name

MENU is what makes the extension surface symmetrical: one
`cmacs-brigade-deftool' form in your init already publishes a capability
to in-process agents, to CLI agents over the MCP relay and to external
MCP clients.  With MENU it reaches you as well, without a second
registration and without any menu-specific code in the tool.

Re-registering a name replaces it, which is what makes reloading your
init file idempotent.

This is the function `cmacs-brigade-deftool' expands to; call it
directly when registering tools programmatically."
  (unless (symbolp name)
    (signal 'cmacs-brigade-tool-error (list "tool name must be a symbol" name)))
  (unless (stringp description)
    (signal 'cmacs-brigade-tool-error (list "tool needs a description" name)))
  (unless (functionp handler)
    (signal 'cmacs-brigade-tool-error (list "tool needs a handler" name)))
  (when (and confirm (not (memq confirm '(ask always))))
    (signal 'cmacs-brigade-tool-error
            (list "confirm must be nil, `ask' or `always'" confirm)))
  (cmacs-brigade--check-tool-metadata name surfaces cli returns example
                                      aliases)
  ;; The menu hands a tool's first parameter the thing that was clicked,
  ;; rendered as text.  Text is not an array or an object, so such a
  ;; tool could be offered and never run; refuse it where its author
  ;; sees the reason.  (Later parameters are fine: the menu asks for
  ;; them as JSON through `cmacs-brigade-read-param'.)
  (when (and menu (or (null surfaces) (memq 'menu surfaces))
             (consp (car params))
             (member (format "%s" (nth 1 (car params)))
                     cmacs-brigade-tool-structured-types))
    (signal 'cmacs-brigade-tool-error
            (list "a :menu tool's first parameter receives the clicked \
target as text, so it cannot be an array or an object" name)))
  (let* ((parsed (mapcar #'cmacs-brigade--parse-param params))
         (wire   (cmacs-brigade-wire-name name))
         ;; See `cmacs-brigade--structured-handler': an array or object
         ;; argument reaches the body as a list or an alist whichever
         ;; surface delivered it.
         (handler (cmacs-brigade--structured-handler handler parsed async))
         (alias-wires (delete wire
                              (delete-dups
                               (mapcar #'cmacs-brigade-wire-name aliases))))
         ;; A tool that opted out of the menu surface simply has no menu
         ;; entry: the menu reads this slot, so clearing it here filters
         ;; that surface without the menu code learning about surfaces.
         (menu   (and (or (null surfaces) (memq 'menu surfaces)) menu))
         (tool   (cmacs-brigade--make-tool
                  :name name :wire-name wire :description description
                  :params parsed :group group :destructive destructive
                  :confirm confirm :async async
                  :timeout (or timeout cmacs-brigade-tool-default-timeout)
                  :handler handler
                  :menu menu :menu-label menu-label
                  :surfaces surfaces :cli cli
                  :returns (or returns 'string) :example example
                  :aliases alias-wires))
         (old    (cmacs-brigade-registry-get 'tool name))
         (props  (list :group group :destructive destructive
                       :confirm confirm :async async
                       :timeout (cmacs-brigade-tool-timeout tool)
                       ;; Read by the MCP publisher: a tool that is not
                       ;; on the `mcp' surface stays in the mirror (the
                       ;; allowlist gate resolves groups from it) but is
                       ;; not offered to MCP clients.
                       :no-mcp (not (cmacs-brigade-tool-on-surface-p
                                     tool 'mcp)))))
    ;; Bookkeeping only; see "Shipped families" above.
    (cmacs-brigade--shipped-tool-p wire)
    ;; An alias dropped by a re-registration must stop answering.
    (when (and old (fboundp 'cmacs-brigade--mirror-remove))
      (dolist (a (cmacs-brigade-tool-aliases old))
        (unless (member a alias-wires)
          (funcall 'cmacs-brigade--mirror-remove a))))
    (cmacs-brigade--registry-put 'tool name tool)
    ;; Mirror the metadata into C for MCP publication and the allowlist
    ;; gate.  Absent when brigade is not compiled in, in which case the
    ;; Elisp registry still works for in-process use.
    (when (fboundp 'cmacs-brigade--mirror-put)
      (let ((json (cmacs-brigade--params-json parsed)))
        (funcall 'cmacs-brigade--mirror-put wire description json props)
        ;; Each alias is mirrored as a tool of its own, so the old name
        ;; is published, gated and allowlisted exactly like the new one.
        (dolist (a alias-wires)
          (funcall 'cmacs-brigade--mirror-put
                   a (format "%s  (Alias of %s.)" description wire)
                   json props))))
    (run-hook-with-args 'cmacs-brigade-tool-registered-functions tool)
    name))

;; The C mirror is a copy, and a copy can be lost: a test that swaps the
;; registry out removes the mirror's entries and, restoring the Lisp
;; table, restores nothing in C.  While every tool also had a
;; hand-written C twin that was invisible -- the twin answered.  With
;; the twins gone a tool missing from the mirror is a tool no MCP client
;; is offered, so there is a way to put the mirror back.
(defun cmacs-brigade-registry-remirror ()
  "Rebuild the C mirror of the tool registry from the Lisp registry.
Every registered tool, and each of its aliases, is mirrored again with
the metadata it was registered with.  Entries in the mirror that no
registered tool accounts for are left alone.  Return the number of
tools mirrored; does nothing in a build without the mirror."
  (let ((n 0))
    (when (fboundp 'cmacs-brigade--mirror-put)
      (dolist (name (cmacs-brigade-registry-list 'tool))
        (when-let* ((tool (cmacs-brigade-registry-get 'tool name)))
          (let ((wire (cmacs-brigade-tool-wire-name tool))
                (description (cmacs-brigade-tool-description tool))
                (json (cmacs-brigade--params-json
                       (cmacs-brigade-tool-params tool)))
                (props (list :group (cmacs-brigade-tool-group tool)
                             :destructive (cmacs-brigade-tool-destructive tool)
                             :confirm (cmacs-brigade-tool-confirm tool)
                             :async (cmacs-brigade-tool-async tool)
                             :timeout (cmacs-brigade-tool-timeout tool)
                             :no-mcp (not (cmacs-brigade-tool-on-surface-p
                                           tool 'mcp)))))
            (funcall 'cmacs-brigade--mirror-put wire description json props)
            (dolist (a (cmacs-brigade-tool-aliases tool))
              (funcall 'cmacs-brigade--mirror-put
                       a (format "%s  (Alias of %s.)" description wire)
                       json props))
            (setq n (1+ n))))))
    n))

;;;###autoload
(defun cmacs-brigade-unregister-tool (name)
  "Remove NAME from the tool registry.  Returns non-nil if it was there."
  (let ((had (cmacs-brigade-registry-get 'tool name)))
    (remhash name (cmacs-brigade--registry 'tool))
    (when (fboundp 'cmacs-brigade--mirror-remove)
      (funcall 'cmacs-brigade--mirror-remove (cmacs-brigade-wire-name name))
      (when had
        (dolist (a (cmacs-brigade-tool-aliases had))
          (funcall 'cmacs-brigade--mirror-remove a))))
    (and had t)))

;;;###autoload
(defmacro cmacs-brigade-deftool (name description params &rest body)
  "Define and register a brigade tool called NAME.

DESCRIPTION is the model-facing summary.  PARAMS is a list of
\(PNAME TYPE DOC &rest KEYWORDS) specs; each PNAME is bound in BODY.

BODY may be preceded by keyword options -- :group, :destructive,
:confirm, :async, :timeout, :menu, :menu-label, :surfaces, :cli,
:returns, :example and :aliases -- which mean what they do in
`cmacs-brigade-register-tool'.

:menu is how a tool reaches you as well as your agents:

  (cmacs-brigade-deftool file-facts
    \"Report size, mtime and line count for a path.\"
    ((path string \"File to inspect\"))
    :menu \\='(file files) :menu-label \"File facts\"
    (my/file-facts path))

That one form now answers to an in-process agent, a CLI agent over the
MCP relay, an external MCP client, and a right-click on a file in dired.

A parameter may be an array or an object, and BODY then sees Lisp data
-- a list, or an alist with symbol keys:

  (cmacs-brigade-deftool team-add
    \"Define a team of windows.\"
    ((name string \"Team name\")
     (members array \"Window ids\" :items integer)
     (rule object \"Who joins\" :optional t
           :properties ((app string \"App id\")
                        (title string \"Title regexp\" :optional t))))
    (my/team-add name members (alist-get \='app rule)))

With :async t, BODY additionally has `done' in scope; call it with the
result string when the work finishes, and BODY's own return value is
ignored:

  (cmacs-brigade-deftool call-for-me
    \"Place a phone call and return a transcript.\"
    ((number string \"E.164 destination\")
     (script string \"What to say\"))
    :group \\='telephony :destructive t :confirm \\='ask :async t
    (my/place-call number script
                   (lambda (wav) (funcall done (my/transcribe wav)))))

\(fn NAME DESCRIPTION PARAMS &rest [KEYWORD VALUE]... BODY)"
  (declare (indent 3) (doc-string 2))
  (let ((opts nil))
    (while (and body (keywordp (car body)) (cdr body))
      (push (pop body) opts)
      (push (pop body) opts))
    (setq opts (nreverse opts))
    (let* ((async (plist-get opts :async))
           (argnames (mapcar (lambda (p) (nth 0 p)) params))
           (lambda-args (if async (cons 'done argnames) argnames)))
      `(cmacs-brigade-register-tool
        :name ',name
        :description ,description
        :params ',params
        :handler (lambda ,lambda-args
                   (ignore ,@lambda-args)
                   ,@body)
        ,@opts))))


;;;; Other registries
;;
;; Same shape throughout: a keyword-argument writer that stores a plist.
;; Validation is deliberately light -- these are extension points, and
;; rejecting a plist because it carries an extra key the brigade does not
;; yet understand would make the API hostile to the very experimentation
;; it exists to enable.

(defmacro cmacs-brigade--define-registry (kind required &optional docstring)
  "Define `cmacs-brigade-register-KIND' storing a plist.
REQUIRED is a list of keywords that must be present and non-nil."
  (let ((fn (intern (format "cmacs-brigade-register-%s" kind))))
    `(progn
       (defun ,fn (&rest plist)
         ,(or docstring (format "Register a %s from PLIST." kind))
         ;; :name may be given as a symbol or a string and is normalised
         ;; to a symbol for the key.  Both spellings are natural
         ;; depending on where the registration comes from: an agent
         ;; defined in markdown frontmatter has a string name, one
         ;; written in Lisp has a symbol, and they must land in the same
         ;; registry under the same key or a plan file could not
         ;; reference either interchangeably.
         (let ((name (plist-get plist :name)))
           (when (stringp name)
             (setq name (intern name)
                   plist (plist-put (copy-sequence plist) :name name)))
           (unless (and name (symbolp name))
             (signal 'cmacs-brigade-error
                     (list ,(format "%s needs a symbol or string :name" kind)
                           (plist-get plist :name))))
           (dolist (key ',required)
             (unless (plist-get plist key)
               (signal 'cmacs-brigade-error
                       (list (format "%s %s needs %s" ',kind name key)))))
           (cmacs-brigade--registry-put ',(intern (symbol-name kind))
                                        name plist)))
       (put ',fn 'lisp-indent-function 'defun))))

(cmacs-brigade--define-registry agent (:prompt)
  "Register an agent definition from PLIST.

Recognised keys: :name, :prompt, :model, :fallback-model, :tools (a list
of tool symbols and/or group symbols), :isolation, :worker, :budget-usd,
:max-turns, :max-tokens, :emits, :description.

This is the Lisp-side equivalent of dropping a markdown file with YAML
frontmatter into `cmacs-brigade-agent-path'; both populate the same
registry, so an agent defined here can be referenced from a plan file
exactly like a file-defined one.")

(cmacs-brigade--define-registry worker (:start)
  "Register an execution backend from PLIST.

Recognised keys: :name, :start (function), :poll, :read-output, :cancel,
:parse-output, :supports-session.

A worker decides *how* an agent runs -- in this process, as a
`claude-code' subprocess, as a detached job, on another machine.  :poll
exists for workers that cannot push state (a detached process has no
SIGCHLD to deliver); leave it nil when the worker reports its own
transitions.

:supports-session declares that the worker can continue an existing
conversation rather than only starting a fresh one -- an in-process
session handle, or a CLI that takes a session id.  Without it a task run
by this worker refuses `agent_send': re-running it with a follow-up
message would produce something that has never seen the first message,
and presenting that as a continuation is a lie the caller cannot
detect.")

(cmacs-brigade--define-registry isolation (:prepare)
  "Register a sandbox backend from PLIST.

Recognised keys: :name, :prepare (returns a plist with :cwd and :env),
:teardown, :describe.

:teardown must be safe to call twice and safe to call on a preparation
that failed halfway, because it runs from an unwind form.")

(cmacs-brigade--define-registry memory-source (:enumerate :read-chunk)
  "Register a corpus for the memory index from PLIST.

Recognised keys: :name, :kind, :enumerate (returns a list of item ids),
:read-chunk (id -> list of chunk plists), :changed-p.

This is how the index covers something other than your notes: a Postgres
table, a code tree, a Zotero library, an IMAP folder.  Every agent's
`memory_search' then reaches it with no further work.")

(cmacs-brigade--define-registry deliverable (:render)
  "Register an output type from PLIST.

Recognised keys: :name, :render, :validate, :extension, :description.")

(cmacs-brigade--define-registry panel (:render)
  "Register a dashboard section from PLIST.

Recognised keys: :name, :title, :render (returns a list of lines),
:order.")

(cmacs-brigade--define-registry context-provider (:provide)
  "Register a source of automatically injected prompt context from PLIST.

Recognised keys: :name, :provide (agent -> string or nil), :order.

Providers run for every agent start, so :provide should be cheap and
must tolerate being called with an agent it knows nothing about.")

(cmacs-brigade--define-registry client (:deliver)
  "Register a conversational client that can be woken from PLIST.

Recognised keys: :name, :deliver (TARGET TEXT -> non-nil when the
message was accepted), :targets (-> list of (TARGET-ID . LABEL) that are
live now), :live-p, :ready-p (TARGET -> nil while it is busy, so a
message waits rather than interleaving) and :current (-> the target id
for the context this is being called from, or nil).

This is how a finished agent reaches whatever asked for it.  A chat that
spawns a subagent otherwise sits waiting for a human to notice and say
\"check on it\"; with a client registered, the finished run delivers a
turn back into that conversation and it carries on by itself.

The shipped implementation covers `cmacs-ai' chat buffers.  libreclaw
channels, a Matrix room or anything else register their own and are
reached by exactly the same path.")

(cmacs-brigade--define-registry approval-handler (:ask)
  "Register a way of asking the user to confirm a tool call from PLIST.

Recognised keys: :name, :ask (called with a plist describing the call;
returns non-nil to allow), :order.

The default handler prompts in the minibuffer.  A headless or remote
setup registers its own -- routing to the dashboard inbox, or to Matrix
through libreclaw -- so confirmation does not require a human at this
particular Emacs.")


(provide 'cmacs-brigade-registry)

;;; cmacs-brigade-registry.el ends here
