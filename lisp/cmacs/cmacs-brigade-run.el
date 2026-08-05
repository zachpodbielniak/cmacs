;;; cmacs-brigade-run.el --- Starting and supervising agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Turns a plan task into a running agent, and keeps track of it.
;;
;; Agents run out of process.  A `--gowl' cmacs instance *is* the user's
;; Wayland session: an agent that blocks or errors in the editor process
;; takes the desktop with it, along with every application in it.  So the
;; shipped workers spawn something, and only bookkeeping happens inline.
;;
;; Concurrency is capped and the queue is honest about it -- a task that
;; cannot start yet stays `queued' rather than being silently dropped or
;; quietly started anyway.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-agent-def)
(require 'cmacs-brigade-host)
(require 'cmacs-brigade-isolation)
(require 'cl-lib)
(require 'subr-x)
;; Required, not declared.  `declare-function' satisfies the byte-compiler
;; and loads nothing, so the inproc worker died on a void
;; `cmacs-ai-make-session' the first time anyone pressed s.  The subsystem
;; hard-requires --with-cmacs-ai at configure time, so this is not
;; optional and must not be guarded as if it were.
(require 'cmacs-ai)
(require 'cmacs-brigade-tools)

(declare-function cmacs-brigade-plan-adopt "cmacs-brigade-plan")
(declare-function cmacs-brigade-plan-task-prompt "cmacs-brigade-plan")
(declare-function cmacs-brigade-plan-task-property "cmacs-brigade-plan")

(defcustom cmacs-brigade-max-concurrent 4
  "How many agents may run at once.
Beyond this, tasks stay queued until a slot frees."
  :type 'integer
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-worker 'inproc
  "Worker used when neither the agent nor its provider implies one.

Only consulted last: an agent that names a worker gets it, and a model
naming a CLI provider (`claude-code/opus\=') gets that CLI's worker, since
running a CLI provider through the in-process tool loop would silently
drop every tool -- the CLI clients ignore the tools argument and take
them over MCP instead."
  :type 'symbol
  :group 'cmacs-brigade)

(defconst cmacs-brigade-cli-providers
  '((claude-code . claude-code)
    (opencode    . opencode)
    (claude-tmux . claude-code))
  "Providers that are a CLI, and the worker each implies.")

(defun cmacs-brigade-resolve-worker (agent)
  "Return the worker AGENT should run under.

An explicit `worker:\=' in the definition wins; otherwise a CLI provider
in the model string picks its own worker; otherwise
`cmacs-brigade-worker\='."
  (or (plist-get agent :worker)
      (alist-get (car (cmacs-brigade--split-model (plist-get agent :model)))
                 cmacs-brigade-cli-providers)
      cmacs-brigade-worker))

(defcustom cmacs-brigade-claude-program "claude"
  "Program used by the `claude-code' worker."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-opencode-program "opencode"
  "Program used by the `opencode' worker."
  :type 'string
  :group 'cmacs-brigade)

(defvar cmacs-brigade--runs (make-hash-table :test 'equal)
  "TASK-ID -> plist describing a live run.")

(defvar cmacs-brigade-run-finished-functions nil
  "Abnormal hook run with the task id and final state when a run ends.")


;;;; Workers

(defun cmacs-brigade--worker-command (worker agent prompt-file endpoint)
  "Return the argv for WORKER running AGENT with PROMPT-FILE."
  (let ((model (plist-get agent :model))
        (config (and endpoint (plist-get endpoint :path))))
    (pcase worker
      ('claude-code
       (append (list cmacs-brigade-claude-program "--print"
                     ;; Without this the agent can see the tools its MCP
                     ;; config grants and cannot call any of them: run
                     ;; non-interactively there is nobody to approve
                     ;; them.  The allowlist in that config is the real
                     ;; gate.
                     "--dangerously-skip-permissions"
                     ;; JSON so the run reports its own usage: it carries
                     ;; result, num_turns, usage and total_cost_usd, and
                     ;; without it turns and cost stay stuck at zero with
                     ;; no way to tell a cheap run from an expensive one.
                     "--output-format" "json")
               ;; The prompt arrives on stdin rather than argv: prompts
               ;; routinely exceed ARG_MAX, and argv is world-readable.
               (when config (list "--mcp-config" config))
               ;; The bare name: the provider prefix is ours, not the
               ;; CLI's, and passing "claude-code/opus" through as
               ;; --model asks for a model that does not exist.
               (when model (list "--model"
                                 (cdr (cmacs-brigade--split-model model))))))
      ('opencode
       (append (list cmacs-brigade-opencode-program "run" "--format" "json")
               ;; Everything after the first slash, so opencode's own
               ;; "vendor/model" spelling survives ours.
               (when model (list "--model"
                                 (cdr (cmacs-brigade--split-model model))))))
      ;; opencode has no flag for it; the same thing is an environment
      ;; variable, applied in `cmacs-brigade--worker-env'.
      ('shell (list "bash" "-c" (format "cat %s | bash"
                                        (shell-quote-argument prompt-file))))
      (_ (user-error "cmacs-brigade: %s has no subprocess form" worker)))))

(defconst cmacs-brigade-opencode-allow-all "{\"*\":\"allow\"}"
  "Value of OPENCODE_PERMISSION that auto-approves every category.

opencode expresses what claude does with a flag as an environment
variable; this mirrors what ai-glib sets for the same purpose.")

(defun cmacs-brigade--worker-env (worker env)
  "Environment for WORKER, on top of ENV."
  (if (eq worker 'opencode)
      (cons (cons "OPENCODE_PERMISSION" cmacs-brigade-opencode-allow-all) env)
    env))

(defun cmacs-brigade--start-process (task-id agent prompt cwd env endpoint)
  "Spawn AGENT's worker for TASK-ID.  Returns the process."
  ;; The resolver, not a second copy of its rule: computing the worker
  ;; here as well is how a run dispatched to claude-code ended up asking
  ;; for inproc's argv.
  (let* ((worker (cmacs-brigade-resolve-worker agent))
         (prompt-file (make-temp-file "cmacs-brigade-prompt"))
         (argv (cmacs-brigade--worker-command worker agent prompt-file
                                              endpoint))
         (default-directory (or cwd default-directory))
         (process-environment
          (append (mapcar (lambda (c) (format "%s=%s" (car c) (cdr c)))
                          (cmacs-brigade--worker-env worker env))
                  process-environment))
         (buf (generate-new-buffer (format " *brigade-%s*" task-id)))
         proc)
    (with-temp-file prompt-file (insert prompt))
    (setq proc (make-process
                :name (format "brigade-%s" task-id)
                :buffer buf
                :command argv
                :noquery t
                :connection-type 'pipe
                :sentinel (lambda (p _event)
                            (unless (process-live-p p)
                              (cmacs-brigade--on-exit task-id p)))))
    (process-put proc 'brigade-prompt-file prompt-file)
    ;; stdin, not argv: prompts exceed ARG_MAX and argv is readable
    ;; through /proc by anything on the machine.
    (process-send-string proc prompt)
    (process-send-eof proc)
    proc))

(defun cmacs-brigade--finish (task-id state output &optional reason)
  "Retire TASK-ID in STATE, having produced OUTPUT.

Shared by every worker: whatever ran, the credential has to be revoked,
the sandbox torn down, the state recorded and the queue drained, and
having each worker do that itself is how one of them ends up not doing
one of them."
  (let ((run (gethash task-id cmacs-brigade--runs)))
    (when run
      ;; Order matters: revoke the credential before anything else can
      ;; fail, so a token never outlives the run that needed it.
      (cmacs-brigade-host-revoke task-id)
      (cmacs-brigade-isolation-teardown (plist-get run :isolation) task-id)
      (remhash task-id cmacs-brigade--runs)))
  (when (fboundp 'cmacs-brigade-task-transition)
    (cmacs-brigade-task-transition task-id state reason))
  (run-hook-with-args 'cmacs-brigade-run-finished-functions task-id state
                      output)
  (cmacs-brigade--drain-queue))

(defun cmacs-brigade--on-exit (task-id proc)
  "Record that TASK-ID's PROC finished."
  (let* ((status (process-exit-status proc))
         (buf (process-buffer proc))
         (output (when (buffer-live-p buf)
                   (with-current-buffer buf (buffer-string))))
         (state (if (zerop status) 'done 'failed)))
    (when-let* ((f (process-get proc 'brigade-prompt-file)))
      (ignore-errors (delete-file f)))
    (when (buffer-live-p buf)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf))
    ;; Through the worker's own reader, so a CLI that reports usage gets
    ;; it recorded and one that does not is passed through untouched.
    (let* ((run (gethash task-id cmacs-brigade--runs))
           (w (and run (cmacs-brigade-registry-get 'worker
                                                   (plist-get run :worker))))
           (parse (and w (plist-get w :parse-output))))
      (when (and parse output)
        (setq output (or (ignore-errors (funcall parse output task-id))
                         output)))
      (cmacs-brigade--finish task-id state output
                             (unless (zerop status)
                               (format "worker exited %s" status))))))


;;;; The in-process worker
;;
;; Runs the tool loop inside cmacs against a provider's HTTP API, rather
;; than shelling out to a CLI.  The loop itself happens on an ai-glib
;; worker thread and reports back through the dispatch callback registry,
;; so the editor is never blocked -- which matters more than usual here,
;; because under `--gowl' the editor is the compositor.

(defun cmacs-brigade--split-model (model)
  "Split MODEL, a \"provider/name\" string, into (PROVIDER . NAME).

PROVIDER is a symbol.  With no slash the whole string is the model name
and the provider is the configured default -- so `gpt-oss:20b\' still
works, and so does a name that itself contains a slash after the first."
  (if (and model (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" model))
      (cons (intern (match-string 1 model)) (match-string 2 model))
    (cons (and (boundp 'cmacs-ai-default-provider) cmacs-ai-default-provider)
          model)))

(defun cmacs-brigade--worker-inproc (task-id agent prompt _cwd _env _endpoint)
  "Run AGENT's turn for TASK-ID inside cmacs.  Returns the run state.

PROMPT is the task text only: the agent's own instructions go in as the
session's system prompt, so they are not repeated inside the user turn."
  (unless (fboundp 'cmacs-ai-tools-run-async)
    (user-error "cmacs-brigade: the inproc worker needs --with-cmacs-ai"))
  (let* ((split (cmacs-brigade--split-model (plist-get agent :model)))
         (pair (cmacs-ai-make-session (car split) (cdr split)
                                      (cmacs-brigade--system-prompt agent)))
         (executor (cmacs-ai-tools-new))
         (allowlist (cmacs-brigade-agent-allowlist agent)))
    (condition-case err
        (progn
          ;; Built from the allowlist, so the agent cannot name a tool
          ;; that was not installed -- enforcement by construction rather
          ;; than a check at call time.
          (cmacs-brigade-install-tools executor allowlist
                                       (plist-get agent :name))
          (cmacs-ai-session-append-message (cdr pair) 'user prompt)
          (cmacs-ai-tools-run-async
           (cdr pair) executor
           (lambda (payload)
             (cmacs-brigade--inproc-done task-id payload)))
          (list :session pair :executor executor))
      (error
       ;; Nothing is in the run table yet, so unwind by hand.
       (ignore-errors (cmacs-ai-tools-free executor))
       (ignore-errors (cmacs-ai-free-session pair))
       (signal (car err) (cdr err))))))

(defun cmacs-brigade--inproc-done (task-id payload)
  "Finish TASK-ID from the tool loop's PAYLOAD."
  (let* ((run (gethash task-id cmacs-brigade--runs))
         (text (plist-get payload :text))
         (err (plist-get payload :error)))
    ;; Freed before the state transition: the finished hooks can run
    ;; arbitrary user code, and a handle leaked because one of them
    ;; signalled would outlive the run.
    (when run
      (ignore-errors (cmacs-ai-tools-free (plist-get run :executor)))
      (ignore-errors (cmacs-ai-free-session (plist-get run :session))))
    (cmacs-brigade--finish task-id (if err 'failed 'done)
                           (or text err) err)))

(defun cmacs-brigade--cancel-inproc (_task-id run)
  "Stop an in-process run described by RUN."
  (when-let* ((pair (plist-get run :session)))
    (when (fboundp 'cmacs-ai-chat-cancel)
      (ignore-errors (cmacs-ai-chat-cancel (cdr pair))))
    (ignore-errors (cmacs-ai-tools-free (plist-get run :executor)))
    (ignore-errors (cmacs-ai-free-session pair))))

(defun cmacs-brigade--cancel-process (_task-id run)
  "Stop a subprocess run described by RUN."
  (when-let* ((proc (plist-get run :process)))
    (when (process-live-p proc) (delete-process proc))))


;;;; Reading a CLI's report
;;
;; The CLI workers are asked for JSON so a finished run can say what it
;; cost.  Parsing is best-effort in both directions: a JSON body that
;; does not look like a report is shown raw rather than swallowed, and a
;; report missing a usage block still yields its text.

(defun cmacs-brigade--parse-cli-report (raw task-id)
  "Extract the answer from RAW, recording TASK-ID's usage on the way.

Returns the text to keep.  RAW unchanged when it is not a report."
  (let ((json (and raw (cmacs-brigade--json-object raw))))
    (if (null json) raw
      (let* ((usage (alist-get 'usage json))
             (turns (alist-get 'num_turns json))
             ;; Cache creation and cache reads are billed, and for a CLI
             ;; agent they dwarf the rest: a "say ok" turn reported 10
             ;; input tokens against 28k cache-creation and 22k
             ;; cache-read.  Counting only input_tokens made the cost
             ;; look two orders of magnitude wrong when it was the token
             ;; figure that was incomplete.
             (in (+ (or (alist-get 'input_tokens usage)
                        (alist-get 'inputTokens usage) 0)
                    (or (alist-get 'cache_creation_input_tokens usage)
                        (alist-get 'cacheCreationInputTokens usage) 0)
                    (or (alist-get 'cache_read_input_tokens usage)
                        (alist-get 'cacheReadInputTokens usage) 0)))
             (out (or (alist-get 'output_tokens usage)
                      (alist-get 'outputTokens usage)))
             (cost (alist-get 'total_cost_usd json))
             (text (or (alist-get 'result json)
                       (alist-get 'text json)
                       (alist-get 'output json))))
        (when (and (fboundp 'cmacs-brigade-task-progress)
                   (or turns in out cost))
          (ignore-errors
            (cmacs-brigade-task-progress
             task-id (or turns 0) (or in 0) (or out 0)
             ;; Integer micro-dollars: cost is summed across runs and
             ;; float drift in the one number a budget acts on is worse
             ;; than no number at all.
             (round (* 1000000 (or cost 0))))))
        (if (stringp text) text raw)))))

(defun cmacs-brigade--json-object (raw)
  "Parse RAW as a JSON object, or nil.

Located rather than assumed to be the whole string: a CLI may print a
warning on stdout before its report."
  (let* ((start (string-search "{" raw))
         (end (and start (cl-position ?} raw :from-end t))))
    (when (and start end (< start end))
      (condition-case nil
          (let ((v (json-parse-string (substring raw start (1+ end))
                                      :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)))
            (and (listp v) v))
        (error nil)))))

;;;; Shipped workers
;;
;; Registered through the public `cmacs-brigade-register-worker' and
;; dispatched through the registry, so a user-registered worker is
;; reached by exactly the same path as a built-in one.  The runner used
;; to `pcase' over a hardcoded list instead, which made the registry
;; decorative and meant `inproc' -- the default in every agent
;; definition -- failed with "unknown worker".

(defun cmacs-brigade--worker-subprocess (task-id agent prompt cwd env endpoint)
  "Start AGENT for TASK-ID as a subprocess.  Returns the run state."
  (list :process (cmacs-brigade--start-process task-id agent prompt
                                               cwd env endpoint)))

(cmacs-brigade-register-worker
 :name 'inproc
 :description "Run the tool loop inside cmacs against a provider HTTP API."
 :start #'cmacs-brigade--worker-inproc
 :cancel #'cmacs-brigade--cancel-inproc)

(dolist (w '((claude-code "Drive the claude CLI in --print mode." t)
             (opencode    "Drive the opencode CLI." t)
             (shell       "Pipe the prompt to bash.  Mostly for testing." nil)))
  (cmacs-brigade-register-worker
   :name (nth 0 w)
   :description (nth 1 w)
   :start #'cmacs-brigade--worker-subprocess
   :cancel #'cmacs-brigade--cancel-process
   ;; shell has no report to read; its stdout is the answer.
   :parse-output (when (nth 2 w) #'cmacs-brigade--parse-cli-report)))


;;;; Starting

(defun cmacs-brigade-live-count ()
  "How many agents are running right now."
  (hash-table-count cmacs-brigade--runs))

(defun cmacs-brigade-can-start-p ()
  "Whether another agent may start."
  (or (zerop cmacs-brigade-max-concurrent)
      (< (cmacs-brigade-live-count) cmacs-brigade-max-concurrent)))

(defun cmacs-brigade-start-task (task-id)
  "Start TASK-ID if a slot is free.  Returns non-nil when it started."
  (let* ((record (cmacs-brigade-task-get task-id))
         (agent-name (plist-get record :agent))
         (agent (and agent-name (cmacs-brigade-agent-get agent-name))))
    (cond
     ((null record)
      (user-error "cmacs-brigade: no such task %s" task-id))
     ((null agent)
      (cmacs-brigade-task-transition
       task-id 'failed (format "no agent definition named %s" agent-name))
      nil)
     ((not (cmacs-brigade-can-start-p))
      ;; Left queued on purpose: silently starting it anyway would make
      ;; the concurrency cap a suggestion.
      nil)
     (t (cmacs-brigade--start-now task-id record agent)))))

(cl-defun cmacs-brigade--start-now (task-id record agent)
  "Actually start TASK-ID with AGENT."
  (let* ((isolation (or (plist-get agent :isolation) 'none))
         (allowlist (cmacs-brigade-agent-allowlist agent))
         (worker-name (cmacs-brigade-resolve-worker agent))
         (worker (cmacs-brigade-registry-get 'worker worker-name))
         prepared endpoint proc)
    (unless worker
      (cmacs-brigade-task-transition
       task-id 'failed
       (format "unknown worker %s (known: %s)" worker-name
               (mapconcat #'symbol-name
                          (cmacs-brigade-registry-list 'worker) ", ")))
      (cl-return-from cmacs-brigade--start-now nil))
    (unless (cmacs-brigade-isolation-available-p isolation)
      (cmacs-brigade-task-transition
       task-id 'failed (format "%s isolation is unavailable here" isolation))
      (cl-return-from cmacs-brigade--start-now nil))
    (cmacs-brigade-task-transition task-id 'starting)
    (condition-case err
        (progn
          (setq prepared (cmacs-brigade-isolation-prepare isolation task-id))
          ;; A :CWD: recorded when the task was created wins over
          ;; whatever `default-directory' the isolation backend saw.  By
          ;; the time a task starts the current buffer is whatever the
          ;; main loop happens to be in, so `none' isolation was picking
          ;; up an unrelated project -- a spawn from a chat ran in the
          ;; wrong tree.  A real sandbox still decides its own cwd.
          (when (eq isolation 'none)
            (when-let* ((recorded (cmacs-brigade--task-cwd record)))
              (setq prepared (plist-put (copy-sequence prepared)
                                        :cwd recorded))))
          (setq endpoint (cmacs-brigade-host-provision task-id allowlist))
          (setq proc (funcall (plist-get worker :start)
                              task-id agent
                              (if (eq worker-name 'inproc)
                                  (cmacs-brigade--task-prompt record)
                                (cmacs-brigade--build-prompt record agent))
                              (plist-get prepared :cwd)
                              (plist-get prepared :env)
                              endpoint))
          (puthash task-id (append proc
                                   (list :isolation isolation
                                         :worker worker-name
                                         :agent (plist-get agent :name)
                                         :started (float-time)))
                   cmacs-brigade--runs)
          (cmacs-brigade-task-transition task-id 'running)
          t)
      (error
       ;; Unwind whatever got as far as being created.  Both are safe to
       ;; call on something that was never made.
       (cmacs-brigade-host-revoke task-id)
       (cmacs-brigade-isolation-teardown isolation task-id)
       (cmacs-brigade-task-transition task-id 'failed
                                      (error-message-string err))
       nil))))

(defun cmacs-brigade--system-prompt (agent)
  "The standing instructions for AGENT: its own prompt plus context."
  (let ((parts (list (plist-get agent :prompt))))
    ;; Context providers are a public registry, so a configuration can
    ;; inject whatever it wants here without patching this function.
    (dolist (name (cmacs-brigade-registry-list 'context-provider))
      (let* ((p (cmacs-brigade-registry-get 'context-provider name))
             (text (ignore-errors (funcall (plist-get p :provide) agent))))
        (when (and text (not (string-empty-p text)))
          (push text parts))))
    (string-join (nreverse (delq nil parts)) "\n\n")))

(defun cmacs-brigade--task-cwd (record)
  "Where RECORD asked to run, or nil.

Expanded here rather than at write time so the property stays readable
in the plan -- it is written abbreviated, and a subprocess does not
expand a tilde."
  (when-let* ((raw (cmacs-brigade-plan-task-property
                    (plist-get record :plan) (plist-get record :id) "CWD")))
    (let ((dir (expand-file-name raw)))
      (and (file-directory-p dir) (file-name-as-directory dir)))))

(defun cmacs-brigade--task-prompt (record)
  "The task text for RECORD.

Not `(plist-get record :prompt)\=': the record comes from the C state
table, which holds runtime fields only and has never had a prompt in it.
Reading it from there silently produced an empty task, so every agent ran
with its standing instructions and no work to do."
  (or (cmacs-brigade-plan-task-prompt (plist-get record :plan)
                                      (plist-get record :id))
      ""))

(defun cmacs-brigade--build-prompt (record agent)
  "Assemble one prompt blob for RECORD run by AGENT.

For the CLI workers, which take a single blob on stdin.  The in-process
worker keeps the two apart -- see `cmacs-brigade--worker-inproc\=' -- so
the agent\='s instructions land in the system prompt rather than being
repeated inside the user turn."
  (string-join (delq nil (list (cmacs-brigade--system-prompt agent)
                               (cmacs-brigade--task-prompt record)))
               "\n\n"))

(defun cmacs-brigade--drain-queue ()
  "Start whatever queued tasks now fit."
  (when (fboundp 'cmacs-brigade-task-list)
    (dolist (rec (cmacs-brigade-task-list))
      (when (and (eq 'queued (plist-get rec :state))
                 (cmacs-brigade-can-start-p))
        (cmacs-brigade-start-task (plist-get rec :id))))))

(defun cmacs-brigade-cancel-task (task-id)
  "Stop TASK-ID if it is running."
  (interactive "sTask id: ")
  (let ((run (gethash task-id cmacs-brigade--runs)))
    (when run
      ;; Through the registry, so a user-registered worker gets to stop
      ;; its own kind of run rather than having a `delete-process' aimed
      ;; at something that is not a process.
      (when-let* ((w (cmacs-brigade-registry-get 'worker
                                                 (plist-get run :worker)))
                  (cancel (plist-get w :cancel)))
        (ignore-errors (funcall cancel task-id run))))
    (cmacs-brigade-task-transition task-id 'cancelled)
    (cmacs-brigade-host-revoke task-id)
    (when run
      (cmacs-brigade-isolation-teardown (plist-get run :isolation) task-id))
    (remhash task-id cmacs-brigade--runs)
    (cmacs-brigade--drain-queue)
    t))

;;;###autoload
(defun cmacs-brigade-start-plan (&optional buffer)
  "Adopt BUFFER's plan and start every queued task that fits."
  (interactive)
  (let ((results (cmacs-brigade-plan-adopt buffer))
        (started 0))
    (dolist (r results)
      (when (and (eq 'queued (plist-get r :state))
                 (cmacs-brigade-start-task (plist-get r :id)))
        (setq started (1+ started))))
    (message "cmacs-brigade: %d task(s), %d started, %d live"
             (length results) started (cmacs-brigade-live-count))
    started))

(provide 'cmacs-brigade-run)

;;; cmacs-brigade-run.el ends here
