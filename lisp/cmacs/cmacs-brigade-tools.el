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

(defun cmacs-brigade-call-tool (wire-name json-args &optional agent allowlist)
  "Call the tool named WIRE-NAME with JSON-ARGS and return its result string.

AGENT names the caller for the audit trail and confirmation prompt.
ALLOWLIST, when given, is checked through the C gate first.

Errors are returned as an \"Error: ...\" string rather than signalled:
that is ai-glib's soft-error convention, and it matters because a
signalled error aborts the agent's whole turn while a returned one lets
the model read what went wrong and try something else."
  (condition-case err
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
               (req (list :tool wire-name :args alist :agent agent)))
          (unless (run-hook-with-args-until-failure
                   'cmacs-brigade-before-tool-call-functions req)
            (error "Tool %s vetoed by a before-tool-call hook" wire-name))
          (unless (cmacs-brigade--confirm tool alist agent)
            (error "Tool %s declined by the user" wire-name))
          (let ((result (cmacs-brigade--invoke tool alist)))
            (run-hook-with-args 'cmacs-brigade-after-tool-call-functions
                                (append req (list :result result)))
            result)))
    (error
     (let ((msg (format "Error: %s" (error-message-string err))))
       (run-hook-with-args 'cmacs-brigade-after-tool-call-functions
                           (list :tool wire-name :agent agent :error err))
       msg))))

(defun cmacs-brigade--tool-by-wire (wire-name)
  "Return the tool registered under WIRE-NAME, or nil."
  (cl-loop for n in (cmacs-brigade-registry-list 'tool)
           for tool = (cmacs-brigade-registry-get 'tool n)
           when (equal (cmacs-brigade-tool-wire-name tool) wire-name)
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
          (sit-for 0.05))
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
           when (and (or (null (cmacs-brigade-tool-destructive tool))
                         include-destructive)
                     (or (not (fboundp 'cmacs-brigade-tool-allowed-p))
                         (cmacs-brigade-tool-allowed-p allowlist wire)))
           collect tool))

(defun cmacs-brigade-install-tools (executor allowlist
                                    &optional agent include-destructive)
  "Register on EXECUTOR every tool ALLOWLIST admits.  Returns the count.

EXECUTOR is a `cmacs-ai-tools-new' handle.  Only permitted tools are
installed, so the agent cannot call anything else -- the allowlist is
enforced by construction here rather than by a check at call time."
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
                 (cmacs-brigade-call-tool name input-json agent nil))))
        (setq n (1+ n))))
    n))

(provide 'cmacs-brigade-tools)

;;; cmacs-brigade-tools.el ends here
