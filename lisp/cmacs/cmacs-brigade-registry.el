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

(defconst cmacs-brigade-tool-types '("string" "integer" "number" "boolean")
  "Parameter types a tool may declare.

Deliberately flat: ai-glib's `AiTool' parameter model has no nested
objects or arrays, and a schema the providers cannot express is worse
than no schema -- it would validate here and be silently dropped on the
wire.  Pass structured data as a JSON string parameter.")

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
  menu-label)     ; string shown in the menu instead of the tool name

(define-error 'cmacs-brigade-tool-error
  "Invalid brigade tool definition" 'cmacs-brigade-error)

(defun cmacs-brigade--parse-param (spec)
  "Normalise one parameter SPEC into a plist.
SPEC is (NAME TYPE DOC &rest KEYWORDS) where KEYWORDS may include
:optional, :default and :enum."
  (unless (and (consp spec) (>= (length spec) 3))
    (signal 'cmacs-brigade-tool-error
            (list "parameter spec needs (NAME TYPE DOC ...)" spec)))
  (let* ((name (nth 0 spec))
         (type (nth 1 spec))
         (doc  (nth 2 spec))
         (kw   (nthcdr 3 spec))
         (type-name (if (symbolp type) (symbol-name type) type)))
    (unless (member type-name cmacs-brigade-tool-types)
      (signal 'cmacs-brigade-tool-error
              (list (format "unknown parameter type %S; expected one of %s"
                            type (string-join cmacs-brigade-tool-types ", "))
                    spec)))
    (unless (stringp doc)
      (signal 'cmacs-brigade-tool-error
              (list "parameter description must be a string" spec)))
    (list :name     (cmacs-brigade-wire-name name)
          :type     type-name
          :doc      doc
          ;; Required unless explicitly marked optional.  Defaulting to
          ;; required is the safer error: a model omitting an argument
          ;; the handler needs fails loudly instead of receiving nil.
          :required (not (plist-get kw :optional))
          :default  (plist-get kw :default)
          :enum     (plist-get kw :enum))))

(defun cmacs-brigade--params-json (params)
  "Serialise PARAMS to the JSON array the C mirror stores."
  (json-serialize
   (vconcat
    (mapcar (lambda (p)
              (list :name        (plist-get p :name)
                    :type        (plist-get p :type)
                    :description (plist-get p :doc)
                    :required    (if (plist-get p :required) t :false)))
            params))))

;;;###autoload
(cl-defun cmacs-brigade-register-tool
    (&key name description params handler
          group destructive confirm async timeout menu menu-label)
  "Publish a capability to every brigade agent surface.

NAME is a symbol; the wire name is its snake_case form.  DESCRIPTION is
what a model reads to decide whether to call it, so it should say what
the tool does and when to use it.  PARAMS is a list of
\(NAME TYPE DOC &rest KEYWORDS) specs.  HANDLER is the function.

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
  (let* ((parsed (mapcar #'cmacs-brigade--parse-param params))
         (wire   (cmacs-brigade-wire-name name))
         (tool   (cmacs-brigade--make-tool
                  :name name :wire-name wire :description description
                  :params parsed :group group :destructive destructive
                  :confirm confirm :async async
                  :timeout (or timeout cmacs-brigade-tool-default-timeout)
                  :handler handler
                  :menu menu :menu-label menu-label)))
    (cmacs-brigade--registry-put 'tool name tool)
    ;; Mirror the metadata into C for MCP publication and the allowlist
    ;; gate.  Absent when brigade is not compiled in, in which case the
    ;; Elisp registry still works for in-process use.
    (when (fboundp 'cmacs-brigade--mirror-put)
      (funcall 'cmacs-brigade--mirror-put
               wire description (cmacs-brigade--params-json parsed)
               (list :group group :destructive destructive
                     :confirm confirm :async async
                     :timeout (cmacs-brigade-tool-timeout tool))))
    (run-hook-with-args 'cmacs-brigade-tool-registered-functions tool)
    name))

;;;###autoload
(defun cmacs-brigade-unregister-tool (name)
  "Remove NAME from the tool registry.  Returns non-nil if it was there."
  (let ((had (cmacs-brigade-registry-get 'tool name)))
    (remhash name (cmacs-brigade--registry 'tool))
    (when (fboundp 'cmacs-brigade--mirror-remove)
      (funcall 'cmacs-brigade--mirror-remove (cmacs-brigade-wire-name name)))
    (and had t)))

;;;###autoload
(defmacro cmacs-brigade-deftool (name description params &rest body)
  "Define and register a brigade tool called NAME.

DESCRIPTION is the model-facing summary.  PARAMS is a list of
\(PNAME TYPE DOC &rest KEYWORDS) specs; each PNAME is bound in BODY.

BODY may be preceded by keyword options -- :group, :destructive,
:confirm, :async, :timeout, :menu and :menu-label -- which mean what they
do in `cmacs-brigade-register-tool'.

:menu is how a tool reaches you as well as your agents:

  (cmacs-brigade-deftool file-facts
    \"Report size, mtime and line count for a path.\"
    ((path string \"File to inspect\"))
    :menu \\='(file files) :menu-label \"File facts\"
    (my/file-facts path))

That one form now answers to an in-process agent, a CLI agent over the
MCP relay, an external MCP client, and a right-click on a file in dired.

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
