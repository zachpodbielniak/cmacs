;;; cmacs-brigade-tools.el --- Dispatching registered tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Turns a registered tool into an actual call, on each of the surfaces
;; the brigade publishes to.
;;
;; The two paths differ in one important way.  For an in-process agent we
;; build an `AiToolExecutor' containing *only* the tools that agent is
;; allowed -- so an unauthorised call is not refused, it is
;; unrepresentable.  For MCP the tool set is shared, so the allowlist is
;; checked at dispatch instead; that check is the C gate
;; (`cmacs-brigade-tool-allowed-p'), never a rule expressed here, because
;; a policy written in Lisp can be rewritten by anything holding `eval'.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)

(defvar cmacs-brigade-tool-denied-functions nil
  "Abnormal hook run when the allowlist refuses a call.
Receives a plist with :tool and :agent.  The dashboard uses this to show
denials, which is how you find out an agent is missing a capability
rather than misbehaving.")

(defcustom cmacs-brigade-confirm-function nil
  "Function used to confirm a tool call, or nil for the default.
The default asks in the minibuffer.  Setting this is the quick way to
override; registering an approval handler is the composable way."
  :type '(choice (const :tag "Default (minibuffer)" nil) function)
  :group 'cmacs-brigade)


;;;; Argument marshalling

(defun cmacs-brigade--coerce (value type)
  "Coerce VALUE, as delivered by a model, to TYPE.

Models are unreliable about JSON types -- an integer parameter arrives
as the string \"3\" often enough that refusing it would just produce
retry loops.  Coerce what is unambiguous and pass the rest through; a
handler that needs stricter validation can do it itself."
  (pcase type
    ("integer" (cond ((integerp value) value)
                     ((floatp value) (truncate value))
                     ((and (stringp value) (string-match-p "\\`-?[0-9]+\\'" value))
                      (string-to-number value))
                     (t value)))
    ("number"  (cond ((numberp value) value)
                     ((and (stringp value)
                           (string-match-p "\\`-?[0-9.]+\\'" value))
                      (string-to-number value))
                     (t value)))
    ("boolean" (pcase value
                 ((or :false "false" "no" 0) nil)
                 ((or 't "true" "yes") t)
                 (_ (and value t))))
    (_ (if (stringp value) value (and value (format "%s" value))))))

(defun cmacs-brigade--tool-args (tool arg-alist)
  "Build the positional argument list for TOOL from ARG-ALIST.

Missing optional parameters fall back to their :default.  A missing
required parameter signals, because the alternative -- handing the
handler nil and letting it fail somewhere deeper -- produces an error
message the model cannot act on."
  (mapcar
   (lambda (p)
     (let* ((key (plist-get p :name))
            (cell (assoc key arg-alist))
            (raw (cdr cell)))
       (cond
        (cell (cmacs-brigade--coerce raw (plist-get p :type)))
        ((plist-get p :default) (plist-get p :default))
        ((plist-get p :required)
         (signal 'cmacs-brigade-tool-error
                 (list (format "%s: missing required argument `%s'"
                               (cmacs-brigade-tool-wire-name tool) key))))
        (t nil))))
   (cmacs-brigade-tool-params tool)))

(defun cmacs-brigade--parse-args (json)
  "Parse JSON, a tool-call argument object, into an alist of (NAME . VALUE)."
  (cond
   ((null json) nil)
   ((stringp json)
    (condition-case err
        (let ((parsed (json-parse-string json :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object :false)))
          (mapcar (lambda (c) (cons (format "%s" (car c)) (cdr c))) parsed))
      (json-parse-error
       (signal 'cmacs-brigade-tool-error
               (list "tool arguments were not valid JSON"
                     (error-message-string err))))))
   ((listp json) json)
   (t nil)))


;;;; Confirmation

(defcustom cmacs-brigade-auto-approve t
  "Tools that may run without asking.

t, the default, approves everything; a list approves the wire names in
it; nil asks, which in practice means declines.

What this switches off is the *confirmation prompt*, not the gate.  What
an agent may reach at all is its tool allowlist, enforced in C at the
dispatch point, and that is unaffected: an agent asking for `*\\=' still
cannot call `eval\\=', `shell\\=', `bash\\=', `execute_command\\=', `send_keys\\=',
`crispy_eval\\=' or the C-patching tools.  Those have to be named outright
in the agent's definition, which is a deliberate act by whoever wrote it.
So `t\\=' means \"do not interrupt me about the tools I already granted\",
not \"grant everything\".

Default because the prompt was mostly unanswerable anyway.  A tool call
arriving from a chat or any other GLib callback runs inside a dispatch,
where Lisp cannot prompt -- a minibuffer there re-enters the main loop
underneath the dispatch and wedges the editor -- so cmacs binds
`inhibit-interaction\\=' and a gated tool is declined rather than asked
about.  Leaving the default at nil meant every `:confirm\\=' tool silently
failed on the surface that most used it.

Set a list to be asked about specific tools, understanding that outside
an interactive command being asked means being declined:

  (setq cmacs-brigade-auto-approve
        \\='(\"agent_status\" \"agent_result\" \"agent_list\"))

Worth knowing what `t\\=' now covers that a prompt used to: an agent
granted `project_write_file\\=' writes files without asking, and
`agent_spawn\\=' starts runs that spend money -- bounded by the agent's
budget and `cmacs-brigade-subagent-max-depth\\=', not by you."
  :type '(choice (const :tag "Approve everything (default)" t)
                 (const :tag "Ask (declines where it cannot ask)" nil)
                 (repeat string))
  :group 'cmacs-brigade)

(defun cmacs-brigade--auto-approved-p (wire-name)
  "Whether WIRE-NAME is pre-approved."
  (cond ((eq cmacs-brigade-auto-approve t) t)
        ((listp cmacs-brigade-auto-approve)
         (and (member wire-name cmacs-brigade-auto-approve) t))))

(defun cmacs-brigade--confirm (tool args agent)
  "Return non-nil if the call of TOOL with ARGS on behalf of AGENT may proceed."
  (let ((mode (cmacs-brigade-tool-confirm tool))
        (req (list :tool (cmacs-brigade-tool-wire-name tool)
                   :args args :agent agent
                   :destructive (cmacs-brigade-tool-destructive tool))))
    (cond
     ((null mode) t)
     ((cmacs-brigade--auto-approved-p (cmacs-brigade-tool-wire-name tool)) t)
     (cmacs-brigade-confirm-function (funcall cmacs-brigade-confirm-function req))
     ;; Registered handlers, lowest :order first; the first one that
     ;; answers decides.  Ordering matters because a headless handler
     ;; that always allows would otherwise shadow an interactive one.
     ((cmacs-brigade-registry-list 'approval-handler)
      (let ((handlers (sort (mapcar (lambda (n)
                                      (cmacs-brigade-registry-get
                                       'approval-handler n))
                                    (cmacs-brigade-registry-list
                                     'approval-handler))
                            (lambda (a b) (< (or (plist-get a :order) 50)
                                             (or (plist-get b :order) 50))))))
        (funcall (plist-get (car handlers) :ask) req)))
     ;; Nowhere to ask: refuse rather than silently allow.  A batch
     ;; session has nobody at a prompt, and `inhibit-interaction' means
     ;; we are inside a GLib dispatch, where prompting would re-enter the
     ;; main loop underneath the dispatch and wedge the editor.  "Could
     ;; not ask" must not become "went ahead anyway" for a tool whose
     ;; author asked for a prompt.
     ((or noninteractive
          (and (boundp 'inhibit-interaction) inhibit-interaction))
      (signal 'cmacs-brigade-error
              (list (format "%s needs approval and cannot be asked for it here; add it to `cmacs-brigade-auto-approve' to allow it"
                            (cmacs-brigade-tool-wire-name tool)))))
     (t (yes-or-no-p
         (format "Agent %s wants to run %s%s.  Allow? "
                 (or agent "?")
                 (cmacs-brigade-tool-wire-name tool)
                 (if (cmacs-brigade-tool-destructive tool) " (destructive)" "")))))))


;;;; Dispatch

(defun cmacs-brigade-call-tool (wire-name json-args &optional agent allowlist
                                          task)
  "Call the tool named WIRE-NAME with JSON-ARGS and return its result string.

AGENT names the caller for the audit trail and confirmation prompt.
ALLOWLIST, when given, is checked through the C gate first.  TASK, when
given, is the brigade task on whose behalf the call is being made; it
reaches the hooks as `:task' and is what lets the transaction log record
which run a tool call belonged to.  A call with no TASK -- from a chat
buffer, or an external MCP client -- belongs to no run, which is a fact
worth recording as absence rather than papering over.  A CLI agent's
calls arrive over MCP with the TASK its scoped socket was opened for
\(`cmacs-brigade-scope-open'); that id is the editor's own record and
is never taken from the client.

Errors are returned as an \"Error: ...\" string rather than signalled:
that is ai-glib's soft-error convention, and it matters because a
signalled error aborts the agent's whole turn while a returned one lets
the model read what went wrong and try something else."
  (condition-case err
      (let* ((gated (cmacs-brigade--gate-call wire-name json-args agent
                                              allowlist task))
             (tool (nth 0 gated))
             (alist (nth 1 gated))
             (req (nth 2 gated)))
        (let ((result (cmacs-brigade--invoke tool alist)))
          (run-hook-with-args 'cmacs-brigade-after-tool-call-functions
                              (append req (list :result result)))
          result))
    (error
     (let ((msg (format "Error: %s" (error-message-string err))))
       (run-hook-with-args 'cmacs-brigade-after-tool-call-functions
                           (list :tool wire-name :agent agent :task task
                                 :error err))
       msg))))

(defun cmacs-brigade--gate-call (wire-name json-args agent allowlist task)
  "Run every gate in front of a call of WIRE-NAME; return (TOOL ALIST REQ).

The gates, in the order every surface applies them: the tool exists, the
C allowlist admits it (when ALLOWLIST is given), JSON-ARGS parse, no
`cmacs-brigade-before-tool-call-functions' hook vetoes, and the
confirmation policy allows it.  Signals on the first that fails.

Shared by `cmacs-brigade-call-tool' and `cmacs-brigade-call-tool-async'
so the blocking and the non-blocking path cannot come to disagree about
what a caller is allowed to do.  AGENT and TASK are as there; REQ is the
plist the hooks receive."
  (let ((tool (cmacs-brigade--tool-by-wire wire-name)))
    (unless tool
      (error "No such brigade tool: %s" wire-name))
    (when (and allowlist
               (fboundp 'cmacs-brigade-tool-allowed-p)
               (not (cmacs-brigade-tool-allowed-p allowlist wire-name)))
      (run-hook-with-args 'cmacs-brigade-tool-denied-functions
                          (list :tool wire-name :agent agent))
      (error "Tool %s is not in this agent's allowlist" wire-name))
    (let* ((alist (cmacs-brigade--parse-args json-args))
           (req (list :tool wire-name :args alist :agent agent
                      :task task)))
      (unless (run-hook-with-args-until-failure
               'cmacs-brigade-before-tool-call-functions req)
        (error "Tool %s vetoed by a before-tool-call hook" wire-name))
      (unless (cmacs-brigade--confirm tool alist agent)
        (error "Tool %s declined by the user" wire-name))
      (list tool alist req))))

(defun cmacs-brigade-call-tool-async (wire-name json-args callback
                                                &optional agent allowlist task)
  "Call the tool WIRE-NAME with JSON-ARGS and hand the outcome to CALLBACK.

The non-blocking twin of `cmacs-brigade-call-tool': the same gates, the
same hooks, the same handler, but an :async tool is not waited for.
`cmacs-brigade-call-tool' waits in `sit-for', which is right for a
provider's synchronous tool contract and wrong for an RPC dispatch --
there the wait runs on the main thread, and under `--gowl' the main
thread is the compositor.  This one returns as soon as the handler has
been started.

CALLBACK is called with two arguments, STATUS and TEXT, exactly once:

  ok       TEXT is the tool's result
  error    TEXT says what went wrong (a gate refused, the handler
           signalled, or the tool returned an \"Error: ...\" string)
  timeout  the tool's own :timeout passed before it called `done'

Exactly once is the contract a caller builds on -- a D-Bus method
invocation must be answered once and only once -- so it is enforced
here rather than hoped for: a tool that calls `done' twice, or calls it
after its timeout already fired, has the second call dropped.  For a
synchronous tool CALLBACK runs before this function returns.

Returns nil.  AGENT, ALLOWLIST and TASK are as in
`cmacs-brigade-call-tool'."
  (let* ((settled nil)
         (timer nil)
         (req nil)
         (settle
          (lambda (status text &optional err)
            (unless settled
              (setq settled t)
              (when (timerp timer) (cancel-timer timer))
              ;; The audit hook sees the same plist shapes the blocking
              ;; path gives it.  A hook that signals must not cost the
              ;; caller its answer, hence the demoted errors.
              (with-demoted-errors "cmacs-brigade: after-tool-call hook: %S"
                (run-hook-with-args
                 'cmacs-brigade-after-tool-call-functions
                 (if (eq status 'ok)
                     (append req (list :result text))
                   (list :tool wire-name :agent agent :task task
                         :error (or err (list 'error text))))))
              (funcall callback status text)))))
    (condition-case err
        (let* ((gated (cmacs-brigade--gate-call wire-name json-args agent
                                                allowlist task))
               (tool (nth 0 gated))
               (alist (nth 1 gated))
               (args (cmacs-brigade--tool-args tool alist))
               ;; The soft-error convention: a handler reports failure by
               ;; returning \"Error: ...\".  Surfaces with a real error
               ;; channel want that as a status, not as text to sniff.
               (finish
                (lambda (value)
                  (let ((text (cmacs-brigade--stringify value)))
                    (if (string-prefix-p "Error: " text)
                        (funcall settle 'error
                                 (substring text (length "Error: ")))
                      (funcall settle 'ok text))))))
          (setq req (nth 2 gated))
          (if (not (cmacs-brigade-tool-async tool))
              (funcall finish (apply (cmacs-brigade-tool-handler tool) args))
            ;; Armed before the handler starts, so a handler that calls
            ;; `done' synchronously finds a timer to cancel.
            (setq timer
                  (run-at-time
                   (cmacs-brigade-tool-timeout tool) nil
                   (lambda ()
                     (funcall settle 'timeout
                              (format "%s timed out after %ss"
                                      (cmacs-brigade-tool-wire-name tool)
                                      (cmacs-brigade-tool-timeout tool))))))
            (apply (cmacs-brigade-tool-handler tool) finish args)))
      (error
       (funcall settle 'error (error-message-string err) err)))
    nil))

(defun cmacs-brigade--tool-by-wire (wire-name)
  "Return the tool registered under WIRE-NAME, or nil.
WIRE-NAME may also be one of the tool's :aliases."
  (cl-loop for n in (cmacs-brigade-registry-list 'tool)
           for tool = (cmacs-brigade-registry-get 'tool n)
           when (or (equal (cmacs-brigade-tool-wire-name tool) wire-name)
                    (member wire-name (cmacs-brigade-tool-aliases tool)))
           return tool))

(defun cmacs-brigade--invoke (tool alist)
  "Apply TOOL's handler to the arguments in ALIST and return a string."
  (let ((args (cmacs-brigade--tool-args tool alist)))
    (if (not (cmacs-brigade-tool-async tool))
        (cmacs-brigade--stringify (apply (cmacs-brigade-tool-handler tool) args))
      ;; Async: the handler gets a DONE callback and we wait here.
      ;;
      ;; Waiting rather than returning a job id keeps the tool contract
      ;; synchronous on every surface, which is what the providers and
      ;; MCP both expect.  `sit-for' keeps redisplay and process output
      ;; alive while we wait, so the editor does not appear wedged; the
      ;; timeout is the tool's own, because only its author knows
      ;; whether 2 seconds or 10 minutes is normal.
      (let* ((done nil) (result nil)
             (cb (lambda (r) (setq result r done t)))
             (deadline (+ (float-time) (cmacs-brigade-tool-timeout tool))))
        (apply (cmacs-brigade-tool-handler tool) cb args)
        (while (and (not done) (< (float-time) deadline))
          ;; `sit-for' reads an event, and `read-event' signals when
          ;; `inhibit-interaction' is set -- which the RPC dispatch sets
          ;; around every call arriving over MCP.  Waited for that way,
          ;; an :async tool called by a CLI agent started its work and
          ;; then answered "Error: inhibited-interaction" in any session
          ;; with a display (batch never saw it: there `sit-for' is
          ;; `sleep-for').  `accept-process-output' runs the same
          ;; process filters and timers and reads no event.
          (if (bound-and-true-p inhibit-interaction)
              (accept-process-output nil 0.05)
            (sit-for 0.05)))
        (if done
            (cmacs-brigade--stringify result)
          (format "Error: %s timed out after %ss"
                  (cmacs-brigade-tool-wire-name tool)
                  (cmacs-brigade-tool-timeout tool)))))))

(defun cmacs-brigade--stringify (value)
  "Render VALUE as the string a model receives."
  (cond ((stringp value) value)
        ((null value) "")
        (t (prin1-to-string value))))


;;;; Surface 1: in-process agents

(defun cmacs-brigade-tools-for-allowlist (allowlist &optional include-destructive)
  "Return the tool structs an agent holding ALLOWLIST may use.

INCLUDE-DESTRUCTIVE nil filters out tools marked destructive even when
the allowlist would admit them, which is what makes a read-only agent
read-only without having to enumerate every tool it must not have."
  (cl-loop for n in (cmacs-brigade-registry-list 'tool)
           for tool = (cmacs-brigade-registry-get 'tool n)
           for wire = (cmacs-brigade-tool-wire-name tool)
           when (and (cmacs-brigade-tool-on-surface-p tool 'agents)
                     (or (null (cmacs-brigade-tool-destructive tool))
                         include-destructive)
                     (or (not (fboundp 'cmacs-brigade-tool-allowed-p))
                         (cmacs-brigade-tool-allowed-p allowlist wire)))
           collect tool))

(defun cmacs-brigade-install-tools (executor allowlist
                                    &optional agent include-destructive task)
  "Register on EXECUTOR every tool ALLOWLIST admits.  Returns the count.

EXECUTOR is a `cmacs-ai-tools-new' handle.  Only permitted tools are
installed, so the agent cannot call anything else -- the allowlist is
enforced by construction here rather than by a check at call time.

TASK, when given, is the brigade task this executor belongs to; every
call made through it is attributed to that task in the transaction log.
It is captured here rather than passed per call because the executor
outlives a single turn: a parked conversation reuses the same executor,
and the task it belongs to does not change."
  (let ((tools (cmacs-brigade-tools-for-allowlist allowlist include-destructive))
        (n 0))
    (dolist (tool tools)
      (let ((wire (cmacs-brigade-tool-wire-name tool)))
        (cmacs-ai-tools-register
         executor wire (cmacs-brigade-tool-description tool)
         (cons (mapcar (lambda (p)
                         (list (plist-get p :name)
                               (plist-get p :type)
                               (plist-get p :doc)
                               (plist-get p :required)))
                       (cmacs-brigade-tool-params tool))
               ;; The executor calls back with (NAME INPUT-JSON ID); the
               ;; allowlist is not re-checked because this executor was
               ;; built from it.
               (lambda (name input-json _id)
                 (cmacs-brigade-call-tool name input-json agent nil task))))
        (setq n (1+ n))))
    n))

(provide 'cmacs-brigade-tools)

;; The capability table (D-Bus, emacsctl and the generated reference, all
;; derived from the registry) and the tool families migrated onto it.
;; After `provide' because it requires this file back, and here rather
;; than in a file of its own choosing because this one is loaded eagerly
;; with the brigade: the migrated families have to be in the registry
;; before the first MCP session lists its tools.
(require 'cmacs-capability nil 'noerror)

;;; cmacs-brigade-tools.el ends here
