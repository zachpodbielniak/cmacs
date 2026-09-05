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
;; `cmacs-brigade--task-prompt' and `--task-cwd' call into the plan layer
;; unguarded; declaring them loads nothing.  It happened to work only
;; because something else in the session had pulled org in first.
(require 'cmacs-brigade-plan)
(require 'cl-lib)
(require 'subr-x)
;; Required, not declared.  `declare-function' satisfies the byte-compiler
;; and loads nothing, so the inproc worker died on a void
;; `cmacs-ai-make-session' the first time anyone pressed s.  The subsystem
;; hard-requires --with-cmacs-ai at configure time, so this is not
;; optional and must not be guarded as if it were.
(require 'cmacs-ai)
(require 'cmacs-brigade-tools)
;; Both required, not declared: a turn ending writes its reply to the log
;; and consults the mailbox on the way out, so neither can be optional.
;; They do not require this file back -- the mailbox reaches the run layer
;; through `declare-function' precisely so this direction stays a plain
;; dependency rather than a cycle.
(require 'cmacs-brigade-log)
(require 'cmacs-brigade-mailbox)
(require 'cmacs-brigade-output)

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
    (claude-tmux . claude-code)
    (codex-cli   . codex)
    (codex       . codex))
  "Providers that are a CLI, and the worker each implies.

An HTTP provider is absent on purpose and runs under `inproc', which is
also where a name from `cmacs-ai-openai-compatible-endpoints' lands: it
is an HTTP server, so the in-process tool loop drives it and every
brigade tool works.")

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

(defcustom cmacs-brigade-codex-program "codex"
  "Program used by the `codex' worker.

OpenAI's Codex CLI, driven as `codex exec'.  CODEX_PATH overrides it,
matching what ai-glib does for the same provider."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-codex-sandbox "workspace-write"
  "Sandbox codex runs under: read-only, workspace-write or danger-full-access.

Codex enforces this itself, which is a real boundary rather than a
prompt the model is asked to respect -- so it is set explicitly here
rather than left to the CLI's default.  `workspace-write' matches what
an agent with an isolation backend is expected to do: change its own
worktree and nothing else."
  :type '(choice (const "read-only") (const "workspace-write")
                 (const "danger-full-access") string)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-ollama-program "ollama"
  "Program that launches a claude-code model through Ollama.

Used only for an `ollama/\=' transport model -- see
`cmacs-brigade--ollama-transport-model'.  `OLLAMA_PATH\=' overrides it,
matching what ai-glib does for the same case."
  :type 'string
  :group 'cmacs-brigade)

(defun cmacs-brigade--ollama-transport-model (model)
  "Return the Ollama model name in MODEL, or nil.

The claude-code and claude-tmux CLI clients accept a model spelled
`ollama/NAME\=' and run it through Ollama as the transport rather than
through Anthropic.  With our own provider prefix on the front that is
`claude-code/ollama/NAME\=', so the name to hand Ollama is whatever
follows the *second* slash."
  (let ((bare (cdr (cmacs-brigade--split-model model))))
    (when (and bare (string-match "\\`ollama/\\(.+\\)\\'" bare))
      (match-string 1 bare))))

(defun cmacs-brigade--claude-argv-prefix (model)
  "Return the program and leading arguments for running MODEL.

Plain models exec the claude CLI.  An `ollama/\=' transport model execs

  ollama launch claude --model NAME --

instead, which is the invocation ai-glib builds for the same model in
the in-process path; claude itself must still be installed, and its own
--model is omitted because Ollama supplies it.  Emitting
`claude --model ollama/NAME\=' -- which is what happened before -- asks
claude for a model that does not exist."
  (let ((ollama (cmacs-brigade--ollama-transport-model model)))
    (if ollama
        (list (or (getenv "OLLAMA_PATH") cmacs-brigade-ollama-program)
              "launch" "claude" "--model" ollama "--")
      (list cmacs-brigade-claude-program))))

(defvar cmacs-brigade--runs (make-hash-table :test 'equal)
  "TASK-ID -> plist describing a live run.")

(defvar cmacs-brigade--conversations (make-hash-table :test 'equal)
  "TASK-ID -> plist describing a parked conversation.

Unlike `cmacs-brigade--runs\=' this outlives a turn.  It holds whatever has
to be the same next time: the provider session (a cmacs-ai handle pair
and executor for `inproc\=', a session id string for a CLI), the isolation
the agent has been making a mess in, the directory it works from, the
allowlist it was granted, and its running totals.")

(defvar cmacs-brigade--finishing (make-hash-table :test 'equal)
  "TASK-IDs currently inside `cmacs-brigade--finish\='.

A re-entrancy guard, not bookkeeping.  Tool calls arriving over MCP are
evaluated from inside Emacs's pselect hook, and the finished hooks pump
-- loopback opens files and sends chat messages.  So `agent_send\=' can
genuinely run in the middle of a completion.  Without this flag a send
arriving during the hooks would try to start a turn while the previous
one was still being retired.")

(defvar cmacs-brigade-run-finished-functions nil
  "Abnormal hook run with the task id and final state when a run ends.

\"Ends\" means the conversation is over, not that a turn finished.  A
task that parks with messages waiting has not ended; use
`cmacs-brigade-turn-finished-functions\=' to observe every turn.")

(defvar cmacs-brigade-turn-finished-functions nil
  "Abnormal hook run with the task id, turn number and output each turn.

Fires once per turn, including the turn that ends the conversation.
Split from `cmacs-brigade-run-finished-functions\=' because the two
questions are different and most observers want only one of them: the
transaction log wants every turn, a desktop notification saying \"all
agents have finished\" wants only the last.")

(defcustom cmacs-brigade-conversation-ttl 86400
  "Seconds a parked conversation may sit idle before it is swept.

A parked conversation holds a provider session, a tool executor and
possibly a git worktree or a container, none of which are reclaimed by
garbage collection -- they are handles into C-side registries and
directories on disk.  Left alone they accumulate for as long as the
editor runs.  nil disables the sweep, which is a choice about leaking,
not about whether the sweep is needed."
  :type '(choice (const :tag "Never sweep" nil) integer)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-conversation-max-attempts 3
  "How many times a resumed turn may fail to start before giving up.

Without a bound a conversation whose isolation has been deleted out from
under it retries on every kick forever, and its mailbox is stranded with
no path back and nobody told."
  :type 'integer
  :group 'cmacs-brigade)


;;;; Conversations
;;
;; A conversation is what makes a task something you can go on talking
;; to.  It is created the first time a task starts and torn down
;; explicitly -- by `agent_close', by cancelling, by the idle sweep, or
;; by Emacs exiting.  Crucially it is NOT torn down when a turn ends,
;; which is the one thing that distinguishes this from what the brigade
;; did before.

(defun cmacs-brigade-conversation-get (id)
  "The parked conversation record for task ID, or nil."
  (gethash id cmacs-brigade--conversations))

(defun cmacs-brigade-conversation-p (id)
  "Whether task ID has a conversation that can be continued."
  (and (gethash id cmacs-brigade--conversations) t))

(defun cmacs-brigade-conversation-turn (id)
  "How many turns task ID's conversation has completed, or nil."
  (when-let* ((c (gethash id cmacs-brigade--conversations)))
    (or (plist-get c :turn) 0)))

(defun cmacs-brigade-conversation-session-id (id)
  "The provider session id for task ID's conversation, or nil.
Meaningful only for the CLI workers; `inproc\=' keeps a handle instead."
  (when-let* ((c (gethash id cmacs-brigade--conversations)))
    (plist-get c :session-id)))

(defun cmacs-brigade-conversation-put (id &rest fields)
  "Merge FIELDS into task ID's conversation record, creating it if absent."
  (let ((c (or (gethash id cmacs-brigade--conversations) (list :turn 0))))
    (while fields
      (setq c (plist-put c (pop fields) (pop fields))))
    (setq c (plist-put c :last-activity (float-time)))
    (puthash id c cmacs-brigade--conversations)
    c))

(defun cmacs-brigade-task-supports-session-p (id)
  "Whether task ID runs under a worker that can continue a conversation.

A worker declares this with `:supports-session\='.  The `shell\=' worker
does not: piping a follow-up message to bash produces a fresh process
that has never seen the first one, and presenting that as a continued
conversation would be a lie the caller cannot detect."
  (let* ((rec (and (fboundp 'cmacs-brigade-task-get)
                   (cmacs-brigade-task-get id)))
         (agent (and rec (plist-get rec :agent)
                     (cmacs-brigade-agent-get (plist-get rec :agent))))
         (w (and agent (cmacs-brigade-registry-get
                        'worker (cmacs-brigade-resolve-worker agent)))))
    ;; Unknown worker or unknown agent: allow, and let the start fail
    ;; with a real reason.  Refusing here would report "cannot be
    ;; continued" for what is actually "no such agent".
    (if w (and (plist-get w :supports-session) t) t)))

(defun cmacs-brigade--teardown-conversation (id &optional reason)
  "Release everything task ID's conversation is holding.

The single place any of this happens, so that a conversation ended by
cancelling, by `agent_close\=', by the idle sweep or by Emacs exiting is
released the same way each time.  Ordering matters and is the same as
`cmacs-brigade--finish\=' uses: the credential goes first, because it is
the only piece whose survival is a security problem rather than a leak,
and every later step is wrapped so one failure cannot skip the rest."
  (let ((c (gethash id cmacs-brigade--conversations)))
    (when c
      (cmacs-brigade-host-revoke id)
      (when-let* ((iso (plist-get c :isolation)))
        (ignore-errors (cmacs-brigade-isolation-teardown iso id)))
      ;; Executor before session, matching the in-process completion
      ;; path: the executor holds tool registrations keyed by the
      ;; session's client.
      (when-let* ((e (plist-get c :executor)))
        (ignore-errors (cmacs-ai-tools-free e)))
      (when-let* ((s (plist-get c :session)))
        (ignore-errors (cmacs-ai-free-session s)))
      (remhash id cmacs-brigade--conversations)
      (cmacs-brigade-log-append id "state" :state "closed"
                                :turn (or (plist-get c :turn) 0)
                                :reason reason)
      t)))

(defun cmacs-brigade-close-conversation (id &optional reason)
  "End task ID's conversation, releasing the session it was holding.

The task itself is usually already `done\=' -- closing says \"I will not
be sending anything else\", not \"stop\".  A conversation that had not
reached a terminal state yet (parked after a failed resume, say) is
settled at `done\=', since whatever it produced is all it is going to."
  (interactive "sTask id: ")
  (let ((had (cmacs-brigade--teardown-conversation id (or reason "closed"))))
    (when (and had (fboundp 'cmacs-brigade-task-get))
      (when (memq (plist-get (cmacs-brigade-task-get id) :state)
                  '(waiting-input blocked))
        (cmacs-brigade-task-transition id 'done reason)))
    had))

(defun cmacs-brigade-sweep-conversations (&optional force)
  "Tear down conversations idle past `cmacs-brigade-conversation-ttl'.

FORCE ignores the TTL and sweeps every parked conversation.  A
conversation that is running or mid-finish is never swept whatever the
clock says: the worker holds its own references, and retiring the record
underneath a callback that is about to fire into it trades a leak for a
crash.  Idleness is measured from the last activity -- a delivery or a
completed turn -- not from when the conversation started, so one waiting
behind a busy concurrency cap is not swept while its message is still
pending."
  (interactive "P")
  (let ((n 0)
        (cutoff (and cmacs-brigade-conversation-ttl
                     (- (float-time) cmacs-brigade-conversation-ttl))))
    (when (or force cutoff)
      (dolist (id (hash-table-keys cmacs-brigade--conversations))
        (let ((c (gethash id cmacs-brigade--conversations)))
          (when (and c
                     (null (gethash id cmacs-brigade--runs))
                     (null (gethash id cmacs-brigade--finishing))
                     (or force (< (or (plist-get c :last-activity) 0) cutoff)))
            ;; Undelivered mail is reported, never dropped quietly.  A
            ;; message somebody queued and nobody ever saw is exactly the
            ;; failure a mailbox exists to prevent.
            (let ((pending (if (fboundp 'cmacs-brigade-mailbox-count)
                               (cmacs-brigade-mailbox-count id)
                             0)))
              (when (> pending 0)
                (message "cmacs-brigade: swept %s with %d undelivered message(s)"
                         id pending)
                (cmacs-brigade-log-append
                 id "state" :state "swept"
                 :turn (or (plist-get c :turn) 0)
                 :reason (format "%d message(s) never delivered" pending))
                ;; Attempted, not assumed: the task has usually already
                ;; finished, and `done' to `failed' is refused -- rightly,
                ;; since the run did succeed and it is the messages that
                ;; were lost.  The log entry above is the record either
                ;; way.
                (cmacs-brigade-task-transition
                 id 'failed
                 (format "conversation swept with %d message(s) undelivered"
                         pending)))
              (cmacs-brigade--teardown-conversation
               id (if (> pending 0) "swept with mail pending" "idle"))
              (setq n (1+ n)))))))
    (when (called-interactively-p 'any)
      (message "cmacs-brigade: swept %d conversation(s)" n))
    n))

(defun cmacs-brigade--teardown-all-conversations ()
  "Release every parked conversation.  For `kill-emacs-hook\='."
  (dolist (id (hash-table-keys cmacs-brigade--conversations))
    (ignore-errors (cmacs-brigade--teardown-conversation id "editor exiting"))))

;; Parked isolation is a git worktree or a container, neither of which
;; goes away on its own.  Without this every conversation alive at exit
;; leaves one behind.
(add-hook 'kill-emacs-hook #'cmacs-brigade--teardown-all-conversations)


;;;; Workers

(defun cmacs-brigade--worker-command (worker agent prompt-file endpoint
                                             &optional session-id)
  "Return the argv for WORKER running AGENT with PROMPT-FILE."
  (let ((model (plist-get agent :model))
        (config (and endpoint (plist-get endpoint :path))))
    (pcase worker
      ('claude-code
       (append (cmacs-brigade--claude-argv-prefix model)
               (list "--print"
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
               ;; Continue the conversation rather than starting a new
               ;; one.  claude resolves a session id against the project
               ;; directory, which is why the conversation's cwd is
               ;; parked and never re-resolved -- resuming from a
               ;; different directory silently starts fresh instead of
               ;; failing, which is the worst of both.
               (when (and session-id (not (string-empty-p session-id)))
                 (list "--resume" session-id))
               ;; The bare name: the provider prefix is ours, not the
               ;; CLI's, and passing "claude-code/opus" through as
               ;; --model asks for a model that does not exist.
               ;;
               ;; Omitted entirely for an ollama/ transport model: the
               ;; name went to `ollama launch --model' in the prefix
               ;; above, and claude must not be asked for it as well.
               (when (and model
                          (not (cmacs-brigade--ollama-transport-model model)))
                 (list "--model" (cdr (cmacs-brigade--split-model model))))))
      ('opencode
       (append (list cmacs-brigade-opencode-program "run" "--format" "json")
               ;; opencode spells the same idea `--session'.
               (when (and session-id (not (string-empty-p session-id)))
                 (list "--session" session-id))
               ;; Everything after the first slash, so opencode's own
               ;; "vendor/model" spelling survives ours.
               (when model (list "--model"
                                 (cdr (cmacs-brigade--split-model model))))))
      ('codex
       (append (list (or (getenv "CODEX_PATH") cmacs-brigade-codex-program)
                     "exec"
                     ;; JSONL, so the run reports its own events rather
                     ;; than us scraping prose.
                     "--json"
                     ;; Codex enforces this itself.  Unlike claude's
                     ;; --dangerously-skip-permissions, which removes a
                     ;; prompt, this is a real boundary: a run that tries
                     ;; to write outside the workspace fails rather than
                     ;; asking.
                     "--sandbox" cmacs-brigade-codex-sandbox)
               ;; Resume rather than start fresh.  `codex exec resume ID'
               ;; is a subcommand, not a flag, so it cannot simply be
               ;; appended like claude's --resume.
               (when (and session-id (not (string-empty-p session-id)))
                 (list "resume" session-id))
               (when model
                 (list "--model" (cdr (cmacs-brigade--split-model model))))))
      ;; opencode has no flag for it; the same thing is an environment
      ;; variable, applied in `cmacs-brigade--worker-env'.
      ('shell (list "bash" "-c" (format "cat %s | bash"
                                        (shell-quote-argument prompt-file))))
      (_ (user-error "cmacs-brigade: %s has no subprocess form" worker)))))

(defconst cmacs-brigade-opencode-allow-all "{\"*\":\"allow\"}"
  "Value of OPENCODE_PERMISSION that auto-approves every category.

opencode expresses what claude does with a flag as an environment
variable; this mirrors what ai-glib sets for the same purpose.")

(defun cmacs-brigade--codex-home ()
  "The Codex home directory a run should start from."
  (or (getenv "CODEX_HOME")
      (expand-file-name ".codex" (or (getenv "HOME") "~"))))

(defun cmacs-brigade--codex-overlay (config)
  "Build a CODEX_HOME overlay whose config.toml carries CONFIG's servers.

Codex reads its MCP servers from CODEX_HOME/config.toml, and there is no
flag that points at another file the way claude's --mcp-config does.
Writing into the user's own ~/.codex/config.toml is out of the question:
it is theirs, agents run concurrently, and a crash would leave an
orphaned server declared there for every later codex run, brigade or not.

So the overlay is a directory of its own holding just config.toml, with
every other entry of the real home symlinked in -- auth.json above all,
or the run arrives unauthenticated and the failure reads as a model
error.  The `-c mcp_servers...' override would have avoided the
directory entirely, and is not used: that puts the socket path and token
in argv, which is world-readable through /proc.

Returns the overlay directory, or nil when there is nothing to deliver."
  (when (and config (file-readable-p config))
    (let* ((parent (progn
                     (make-directory cmacs-brigade-runtime-dir t)
                     (set-file-modes cmacs-brigade-runtime-dir #o700)
                     cmacs-brigade-runtime-dir))
           ;; Not the shared temp directory: codex refuses to create its
           ;; PATH helper binaries under one and says so on every run,
           ;; and the runtime directory is 0700 and already where this
           ;; agent's other credentials live.
           (temporary-file-directory (file-name-as-directory parent))
           (dir (make-temp-file "cmacs-brigade-codex" t))
           (real (cmacs-brigade--codex-home)))
      (set-file-modes dir #o700)
      (when (file-directory-p real)
        (dolist (entry (directory-files real nil "\\`[^.]" t))
          (unless (equal entry "config.toml")
            (ignore-errors
              (make-symbolic-link (expand-file-name entry real)
                                  (expand-file-name entry dir) t)))))
      ;; The user's own config first, so their settings survive, then our
      ;; server table appended -- the same shape and the same reasoning
      ;; as the grok dialect in cmacs-brigade-host.el.
      (with-file-modes #o600
        (with-temp-file (expand-file-name "config.toml" dir)
          (let ((user-config (expand-file-name "config.toml" real)))
            (when (file-readable-p user-config)
              (insert-file-contents user-config)
              (goto-char (point-max))
              (unless (bolp) (insert "\n"))))
          (insert-file-contents config)))
      dir)))

(defun cmacs-brigade--worker-env (worker env &optional endpoint)
  "Environment for WORKER, on top of ENV.

ENDPOINT is the provisioned MCP config, which codex takes as a whole
CODEX_HOME rather than as a file path."
  (pcase worker
    ('opencode
     (cons (cons "OPENCODE_PERMISSION" cmacs-brigade-opencode-allow-all) env))
    ('codex
     (let ((overlay (cmacs-brigade--codex-overlay
                     (and endpoint (plist-get endpoint :path)))))
       (if overlay (cons (cons "CODEX_HOME" overlay) env) env)))
    (_ env)))

(defun cmacs-brigade--start-process (task-id agent prompt cwd env endpoint)
  "Spawn AGENT's worker for TASK-ID.  Returns the process."
  ;; The resolver, not a second copy of its rule: computing the worker
  ;; here as well is how a run dispatched to claude-code ended up asking
  ;; for inproc's argv.
  (let* ((worker (cmacs-brigade-resolve-worker agent))
         (prompt-file (make-temp-file "cmacs-brigade-prompt"))
         ;; Looked up here rather than threaded through the worker
         ;; `:start' signature, so a user-registered worker written
         ;; against the old four arguments still works.
         (argv (cmacs-brigade--worker-command
                worker agent prompt-file endpoint
                (cmacs-brigade-conversation-session-id task-id)))
         (default-directory (or cwd default-directory))
         (process-environment
          (append (mapcar (lambda (c) (format "%s=%s" (car c) (cdr c)))
                          (cmacs-brigade--worker-env worker env endpoint))
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
  "End a turn of TASK-ID in STATE, having produced OUTPUT.

Shared by every worker: whatever ran, the credential has to be revoked,
the state recorded and the queue drained, and having each worker do that
itself is how one of them ends up not doing one of them.

A turn ending is not the same as a conversation ending, but a task that
answered you is `done\=' either way.  It is *not* parked in some open
state: `done\=' is what every existing observer means by finished, and a
task that sat in `waiting-input\=' after answering would tell the
dashboard, the notifier and the plan that it was still going.

What makes it resumable is the conversation record, which outlives a
successful turn.  `done\=' to `queued\=' is a legal transition -- it is how
retrying has always worked -- so a message arriving later simply starts
the next turn on the session that is still there.  A turn that ended
badly is a different matter: the conversation is released, because
resuming a run that failed halfway is not something to do quietly."
  ;; Guard first.  Everything below can yield -- the hooks open files and
  ;; send chat messages, both of which pump the main loop -- and a second
  ;; entry (a cancel racing a completing worker) would otherwise fire the
  ;; turn hooks twice and deliver the same reply twice.
  (if (gethash task-id cmacs-brigade--finishing)
      nil
    (puthash task-id t cmacs-brigade--finishing)
    (unwind-protect
        (let* ((run (gethash task-id cmacs-brigade--runs))
               (conv (gethash task-id cmacs-brigade--conversations))
               (turn (1+ (or (and conv (plist-get conv :turn)) 0)))
               ;; Whether the conversation lives on past this turn.  Only
               ;; a clean finish keeps it: a failure, a cancellation or a
               ;; budget stop ends it whatever is queued, because
               ;; resuming a session whose last turn broke is the kind of
               ;; recovery that should be asked for rather than assumed.
               (keep (and conv (eq state 'done))))
          (when run
            ;; Revoke the credential before anything else can fail, so a
            ;; token never outlives the run that needed it.  The
            ;; credential is per-turn on purpose -- a fresh random token
            ;; each turn is strictly better than one long-lived one, and
            ;; the config path it names is regenerated anyway.
            (cmacs-brigade-host-revoke task-id)
            ;; Isolation is NOT torn down while the conversation lives.
            ;; Removing the worktree between turns would delete the
            ;; agent's uncommitted work while its conversation still
            ;; believes it made those edits -- the worst shape of
            ;; failure available, because the model then builds
            ;; confidently on files that no longer exist.
            (unless keep
              (cmacs-brigade-isolation-teardown
               (plist-get run :isolation) task-id))
            ;; Removed here, which is what releases the concurrency slot.
            (remhash task-id cmacs-brigade--runs))
          (when conv
            (cmacs-brigade-conversation-put task-id :turn turn :attempts 0))
          (cmacs-brigade-output-put task-id output turn)
          (cmacs-brigade-log-append
           task-id "reply" :turn turn :text output
           :state (symbol-name state) :reason reason)
          (when (fboundp 'cmacs-brigade-task-transition)
            (cmacs-brigade-task-transition task-id state reason))
          (unless keep
            (when conv (cmacs-brigade--teardown-conversation task-id reason)))
          ;; Both hooks fire, in that order.  `turn-finished' is the new,
          ;; finer-grained one; `run-finished' keeps meaning exactly what
          ;; it always did, so every existing observer -- output,
          ;; notification, the plan -- goes on working unchanged.
          (run-hook-with-args 'cmacs-brigade-turn-finished-functions
                              task-id turn output)
          (run-hook-with-args 'cmacs-brigade-run-finished-functions
                              task-id state output))
      (remhash task-id cmacs-brigade--finishing))
    ;; Outside the guard, so a message that arrived *during* the hooks
    ;; above is seen.  This is the second half of the delivery race: the
    ;; sender enqueued unconditionally and its kick was refused by the
    ;; flag, so the re-read here is what picks it up.  Nothing is lost
    ;; and nothing starts twice.
    (cmacs-brigade-kick-conversation task-id)
    (cmacs-brigade--drain-queue)
    t))

(defun cmacs-brigade-kick-conversation (task-id)
  "Queue TASK-ID for another turn if it is parked with a message waiting.

Idempotent and safe to call from anywhere, which is the point: both
`cmacs-brigade-mailbox-send\=' and the tail of `cmacs-brigade--finish\=' call
it without either needing to know what the other is doing.  It does not
start the turn itself -- it moves the task into the queue and lets
`cmacs-brigade--drain-queue\=' apply one policy to every candidate.
Starting directly from here would let a chatty conversation re-take the
slot it just released ahead of tasks that have been waiting longer,
making the release nominal.

The task is usually `done\=' when this runs, which is the ordinary case:
it answered, nobody had anything more to say at the time, and now
somebody does.  `done\=' to `queued\=' is the same transition a retry
makes."
  (let ((rec (and (fboundp 'cmacs-brigade-task-get)
                  (cmacs-brigade-task-get task-id))))
    (when (and rec
               (gethash task-id cmacs-brigade--conversations)
               (null (gethash task-id cmacs-brigade--runs))
               (null (gethash task-id cmacs-brigade--finishing))
               (fboundp 'cmacs-brigade-mailbox-peek)
               (cmacs-brigade-mailbox-peek task-id)
               (not (memq (plist-get rec :state) '(starting running))))
      (let ((res (cmacs-brigade-task-transition task-id 'queued)))
        (unless (plist-get res :rejected)
          (cmacs-brigade--drain-queue)
          t)))))

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

(defun cmacs-brigade--worker-inproc (task-id agent prompt cwd _env _endpoint)
  "Run AGENT's turn for TASK-ID inside cmacs.  Returns the run state.

PROMPT is the task text only: the agent's own instructions go in as the
session's system prompt, so they are not repeated inside the user turn.

CWD is where the built-in tools work.  It used to be ignored, so an
agent told to work in one tree resolved every relative path -- and ran
every shell command -- against whatever directory Emacs happened to be
in, which is wherever you last visited a file.

A conversation that is already under way reuses its session and its
executor rather than building new ones.  That is what makes the second
turn a continuation: the session carries the previous turns' messages,
so the model sees what it already said instead of being handed a
follow-up with no idea what it is following up on."
  (unless (fboundp 'cmacs-ai-tools-run-async)
    (user-error "cmacs-brigade: the inproc worker needs --with-cmacs-ai"))
  (let* ((conv (cmacs-brigade-conversation-get task-id))
         (resumed (and conv (plist-get conv :session)))
         (split (cmacs-brigade--split-model (plist-get agent :model)))
         (pair (or resumed
                   (cmacs-ai-make-session
                    (car split) (cdr split)
                    (cmacs-brigade--system-prompt agent))))
         (executor (or (and conv (plist-get conv :executor))
                       (cmacs-ai-tools-new)))
         (allowlist (or (and conv (plist-get conv :allowlist))
                        (cmacs-brigade-agent-allowlist agent))))
    (condition-case err
        (progn
          (when (and cwd (fboundp 'cmacs-ai-tools-set-working-directory))
            (cmacs-ai-tools-set-working-directory executor cwd))
          ;; Installed once, on the turn that creates the executor.  A
          ;; resumed turn must not re-register: the tool set an agent
          ;; holds should not change underneath it because the agent
          ;; definition was reloaded between turns.
          (unless resumed
            ;; Built from the allowlist, so the agent cannot call a tool
            ;; that was not installed -- enforcement by construction
            ;; rather than a check at call time.  The task id goes in so
            ;; the transaction log can attribute each call.
            (cmacs-brigade-install-tools executor allowlist
                                         (plist-get agent :name) nil task-id))
          (cmacs-ai-session-append-message (cdr pair) 'user prompt)
          (cmacs-ai-tools-run-async
           (cdr pair) executor
           (lambda (payload)
             (cmacs-brigade--inproc-done task-id payload)))
          ;; Recorded on the conversation, not just the run: the run is
          ;; removed when the turn ends and these have to survive it.
          (cmacs-brigade-conversation-put task-id :session pair
                                          :executor executor
                                          :allowlist allowlist)
          (list :session pair :executor executor))
      (error
       ;; Only unwind what this call created.  Freeing a session we
       ;; inherited from a previous turn would destroy the conversation
       ;; because one turn failed to start.
       (unless resumed
         (ignore-errors (cmacs-ai-tools-free executor))
         (ignore-errors (cmacs-ai-free-session pair)))
       (signal (car err) (cdr err))))))

(defun cmacs-brigade--inproc-done (task-id payload)
  "Finish TASK-ID from the tool loop's PAYLOAD.

The session and executor are deliberately not freed here.  They belong
to the conversation now, and `cmacs-brigade--finish\=' releases them
through `cmacs-brigade--teardown-conversation\=' when the conversation
actually ends -- which for a parked task is later, and may be much
later."
  (let ((text (plist-get payload :text))
        (err (plist-get payload :error)))
    (cmacs-brigade--finish task-id (if err 'failed 'done)
                           (or text err) err)))

(defun cmacs-brigade--cancel-inproc (_task-id run)
  "Stop an in-process run described by RUN.

Cancels the in-flight request only.  Freeing the handles is the
conversation's business -- `cmacs-brigade-cancel-task\=' tears the
conversation down straight afterwards, and doing it here as well would
be a double free of handles that are integers into a C-side registry,
where the second free silently releases whatever now holds that number."
  (when-let* ((pair (plist-get run :session)))
    (when (fboundp 'cmacs-ai-chat-cancel)
      (ignore-errors (cmacs-ai-chat-cancel (cdr pair))))))

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
             ;; opencode spells it `sessionID'; claude `session_id'.
             (sid (or (alist-get 'session_id json)
                      (alist-get 'sessionID json)
                      (alist-get 'sessionId json)))
             (text (or (alist-get 'result json)
                       (alist-get 'text json)
                       (alist-get 'output json))))
        ;; Re-captured every turn, never pinned.  Some CLI versions fork
        ;; a new session id when resuming, which is why ai-glib re-reads
        ;; it from each response too.  Recording turn one's id and
        ;; reusing it forever would mean turn three silently resumed the
        ;; state after turn one, truncating history with nothing to show
        ;; that it had happened.
        (when (and (stringp sid) (not (string-empty-p sid))
                   (cmacs-brigade-conversation-p task-id))
          (cmacs-brigade-conversation-put task-id :session-id sid))
        ;; Accumulated, not assigned.  A resumed turn's report carries
        ;; that invocation's figures only, so assigning them made every
        ;; turn overwrite the conversation's running cost with the last
        ;; turn's -- under-reporting the budget by everything before it.
        (when (and (or turns in out cost)
                   (fboundp 'cmacs-brigade-task-progress-add))
          (ignore-errors
            (cmacs-brigade-task-progress-add
             task-id (or turns 0) (or in 0) (or out 0)
             ;; Integer micro-dollars: cost is summed across runs and
             ;; float drift in the one number a budget acts on is worse
             ;; than no number at all.
             (round (* 1000000 (or cost 0))))))
        (if (stringp text) text raw)))))

(defun cmacs-brigade--parse-codex-report (raw task-id)
  "Extract the answer from codex's JSONL RAW, recording TASK-ID's usage.

Codex does not print one report the way claude does; `codex exec --json'
streams a JSONL event per line, so the whole-object parser above reads
none of it and would hand the caller the raw stream as the answer.

The three lines that matter:

  thread.started   carries thread_id, which is what `codex exec resume'
                   takes -- so it is the session id
  item.completed   with an agent_message item; the last one is the reply
  turn.completed   carries the usage

Anything else -- reasoning, command executions, MCP tool calls -- is the
work, not the answer, and is dropped here the same way the claude
report's intermediate turns are.  Returns RAW unchanged when not one
line parses, so a crash or a usage message still reaches the caller."
  (let ((sid nil) (text nil) (in 0) (out 0) (turns 0) (saw nil))
    (dolist (line (split-string (or raw "") "\n" t "[ \t\r]+"))
      (let ((json (condition-case nil
                      (json-parse-string line :object-type 'alist
                                         :array-type 'list
                                         :null-object nil :false-object nil)
                    (error nil))))
        (when (consp json)
          (setq saw t)
          (let ((type (alist-get 'type json)))
            (cond
             ((equal type "thread.started")
              (setq sid (alist-get 'thread_id json)))
             ((equal type "turn.completed")
              (let ((u (alist-get 'usage json)))
                (setq turns (1+ turns)
                      in  (+ in  (or (alist-get 'input_tokens u) 0))
                      out (+ out (or (alist-get 'output_tokens u) 0)))))
             ((equal type "item.completed")
              (let ((item (alist-get 'item json)))
                (when (equal (alist-get 'type item) "agent_message")
                  ;; The last one wins: a turn can produce several, and
                  ;; the closing message is the reply.
                  (setq text (alist-get 'text item))))))))))
    (when (and (stringp sid) (not (string-empty-p sid))
               (cmacs-brigade-conversation-p task-id))
      (cmacs-brigade-conversation-put task-id :session-id sid))
    (when (and saw (or (> turns 0) (> in 0) (> out 0))
               (fboundp 'cmacs-brigade-task-progress-add))
      ;; Codex reports no cost, so the budget sees tokens and zero
      ;; dollars rather than a number invented from a price list that
      ;; would be wrong the week it changed.
      (ignore-errors
        (cmacs-brigade-task-progress-add task-id turns in out 0)))
    (if (stringp text) text raw)))

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
 :cancel #'cmacs-brigade--cancel-inproc
 ;; The session is a live handle held across turns, so continuing is
 ;; simply appending another user message to it.
 :supports-session t)

;; The third field is whether the worker reports usage as JSON; the
;; fourth is whether it can continue a conversation.  `shell' can do
;; neither: piping a follow-up to bash produces a process that has never
;; seen the first message, and calling that a continuation would be a lie
;; the caller has no way to detect.
(dolist (w `((claude-code "Drive the claude CLI in --print mode." t t
                          ,#'cmacs-brigade--parse-cli-report)
             (opencode    "Drive the opencode CLI." t t
                          ,#'cmacs-brigade--parse-cli-report)
             (codex       "Drive OpenAI's codex CLI as `codex exec'." t t
                          ,#'cmacs-brigade--parse-codex-report)
             (shell       "Pipe the prompt to bash.  Mostly for testing."
                          nil nil nil)))
  (cmacs-brigade-register-worker
   :name (nth 0 w)
   :description (nth 1 w)
   :start #'cmacs-brigade--worker-subprocess
   :cancel #'cmacs-brigade--cancel-process
   ;; shell has no report to read; its stdout is the answer.  codex
   ;; streams JSONL rather than printing one object, so it reads its own.
   :parse-output (nth 4 w)
   :supports-session (nth 3 w)))


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
    ;; Checked, not assumed.  `cmacs-brigade-task-transition' returns
    ;; `:rejected' rather than signalling, so discarding it meant an
    ;; illegal transition -- `done' straight to `starting', say -- still
    ;; fell through and spawned the process.  That run then held a slot,
    ;; spent money and reported nowhere, because as far as the state
    ;; table was concerned it had never started.  Refusing here is what
    ;; makes every other lifecycle mistake loud instead of silent, and it
    ;; must happen before anything is provisioned.
    (let ((res (cmacs-brigade-task-transition task-id 'starting)))
      (when (plist-get res :rejected)
        (message "cmacs-brigade: %s cannot start: %s"
                 task-id (plist-get res :reason))
        (cl-return-from cmacs-brigade--start-now nil)))
    (condition-case err
        (let* ((conv (cmacs-brigade-conversation-get task-id))
               ;; A turn is "resumed" when there is already a
               ;; conversation with a message waiting for it.  The very
               ;; first turn creates the conversation and uses the plan's
               ;; task text; every turn after takes its prompt from the
               ;; mailbox.
               (message-in (and conv (fboundp 'cmacs-brigade-mailbox-peek)
                                (cmacs-brigade-mailbox-peek task-id)))
               (resumed (and conv message-in t)))
          (if resumed
              ;; Reused wholesale, not re-prepared.  The agent has been
              ;; working in this directory and possibly editing files in
              ;; it; preparing again would hand it a pristine tree while
              ;; its conversation still believes it made those changes.
              (setq prepared (plist-get conv :prepared))
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
            ;; Resolved once, here, and never again.  A resumed turn that
            ;; re-resolved would pick up whatever `default-directory' the
            ;; sentinel happened to fire in -- and for a CLI worker that
            ;; is not merely untidy: claude resolves `--resume' against
            ;; the project directory, so a drifted cwd silently starts a
            ;; brand new conversation instead of failing.
            (cmacs-brigade-conversation-put
             task-id :isolation isolation :prepared prepared
             :cwd (plist-get prepared :cwd) :allowlist allowlist))
          ;; The dialect follows the provider: an opencode, grok or codex
          ;; agent needs its own config shape, and passing no :format
          ;; handed every one of them claude's .mcp.json -- which they
          ;; read as nothing at all.
          (setq endpoint
                (cmacs-brigade-host-provision
                 task-id allowlist
                 :format (and (fboundp 'cmacs-brigade-host-format-for-provider)
                              (cmacs-brigade-host-format-for-provider
                               (car (cmacs-brigade--split-model
                                     (plist-get agent :model)))))))
          (setq proc (funcall (plist-get worker :start)
                              task-id agent
                              (cond
                               ;; A resumed turn sends the message and
                               ;; nothing else.  Not `--build-prompt':
                               ;; that prepends the agent's standing
                               ;; instructions, which the CLI already has
                               ;; from the session being resumed and the
                               ;; in-process session already has as its
                               ;; system prompt.  Re-sending them wastes
                               ;; tokens and re-injects the whole prompt
                               ;; into the middle of a conversation.
                               (resumed (plist-get message-in :text))
                               ((eq worker-name 'inproc)
                                (cmacs-brigade--task-prompt record))
                               (t (cmacs-brigade--build-prompt record agent)))
                              (plist-get prepared :cwd)
                              (plist-get prepared :env)
                              endpoint))
          (puthash task-id (append proc
                                   (list :isolation isolation
                                         :worker worker-name
                                         :agent (plist-get agent :name)
                                         :started (float-time)))
                   cmacs-brigade--runs)
          ;; Popped only now that the turn is genuinely under way.
          ;; Popping at peek time meant a start that failed anywhere
          ;; above silently ate what somebody had typed.
          (when resumed
            (cmacs-brigade-mailbox-pop task-id)
            (cmacs-brigade-conversation-put task-id :attempts 0))
          (unless conv
            ;; First turn: record the opening instruction so the log
            ;; reads as a conversation from the beginning rather than
            ;; starting abruptly with a reply.
            (cmacs-brigade-log-append
             task-id "message" :turn 1 :role "user" :from "plan"
             :text (cmacs-brigade--task-prompt record)))
          (cmacs-brigade-log-append task-id "state" :state "running"
                                    :turn (1+ (or (cmacs-brigade-conversation-turn
                                                   task-id)
                                                  0)))
          (cmacs-brigade-task-transition task-id 'running)
          t)
      (error
       ;; Unwind whatever got as far as being created.  The credential is
       ;; always safe to revoke; isolation is torn down only when this
       ;; call is what prepared it, since a resumed turn inherited a
       ;; sandbox that the conversation still owns and that the *next*
       ;; attempt will need.
       (cmacs-brigade-host-revoke task-id)
       (unless (cmacs-brigade-conversation-get task-id)
         (cmacs-brigade-isolation-teardown isolation task-id))
       (cmacs-brigade--start-failed task-id (error-message-string err))
       nil))))

(defun cmacs-brigade--start-failed (task-id reason)
  "Record that TASK-ID could not start, and give up if it keeps happening.

A conversation whose sandbox was deleted out from under it fails the same
way on every kick.  Without a bound it would retry forever with its
mailbox stranded and nobody told; with one, it fails loudly and releases
what it was holding."
  (let ((conv (cmacs-brigade-conversation-get task-id)))
    (if (null conv)
        (cmacs-brigade-task-transition task-id 'failed reason)
      (let ((n (1+ (or (plist-get conv :attempts) 0))))
        (cmacs-brigade-conversation-put task-id :attempts n)
        (if (< n cmacs-brigade-conversation-max-attempts)
            ;; Back to parked: the message is still at the head of the
            ;; queue, so the next kick will try again.
            (cmacs-brigade-task-transition task-id 'waiting-input reason)
          (cmacs-brigade-log-append
           task-id "state" :state "failed"
           :turn (or (cmacs-brigade-conversation-turn task-id) 0)
           :reason (format "gave up after %d attempts: %s" n reason))
          (cmacs-brigade-task-transition
           task-id 'failed
           (format "could not resume after %d attempts: %s" n reason))
          (cmacs-brigade--teardown-conversation task-id reason)
          (run-hook-with-args 'cmacs-brigade-run-finished-functions
                              task-id 'failed reason))))))

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
  "Start whatever queued tasks now fit, oldest first.

Ordered on purpose.  `cmacs-brigade-task-list\=' returns hash-table bucket
order, which is arbitrary but *stable* for a fixed set of keys -- so a
task in a late bucket loses to the same competitors on every drain,
indefinitely.  That is invisible while each task is drained once and
becomes real starvation as soon as a task can be re-queued repeatedly,
which is exactly what a conversation does.  `:queued-at-usec\=' is stamped
by the C state layer on entry to the queue -- in microseconds, because a
fan-out queues a dozen tasks inside the same second -- so a resumed turn
takes its place in line by when it was ready rather than by where it
hashes."
  (when (fboundp 'cmacs-brigade-task-list)
    (let ((queued (sort (cl-remove-if-not
                         (lambda (r) (eq 'queued (plist-get r :state)))
                         (cmacs-brigade-task-list))
                        (lambda (a b) (< (or (plist-get a :queued-at-usec) 0)
                                         (or (plist-get b :queued-at-usec) 0))))))
      (dolist (rec queued)
        (when (cmacs-brigade-can-start-p)
          (cmacs-brigade-start-task (plist-get rec :id)))))))

(defun cmacs-brigade-cancel-task (task-id)
  "Stop TASK-ID, whether it is running or parked mid-conversation.

Returns non-nil only if the task actually reached `cancelled\='.  It used
to return t unconditionally while discarding the transition's result,
which for a parked conversation meant reporting \"Cancelled\" for
something that stayed exactly as it was, still holding a session, a
sandbox and a queue of messages.

Everything the conversation holds goes first, before the transition, so
that even a refused transition still releases the resources -- the caller
asked for this to stop, and the least useful outcome is stopping nothing
and saying so quietly."
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
    (when (fboundp 'cmacs-brigade-mailbox-drop)
      (cmacs-brigade-mailbox-drop task-id))
    ;; Covers the credential, the parked isolation and the session
    ;; handles.  For a task with no conversation this is a no-op and the
    ;; two lines below do the work.
    (cmacs-brigade--teardown-conversation task-id "cancelled")
    (cmacs-brigade-host-revoke task-id)
    (when run
      (cmacs-brigade-isolation-teardown (plist-get run :isolation) task-id))
    (remhash task-id cmacs-brigade--runs)
    (remhash task-id cmacs-brigade--finishing)
    (let* ((res (cmacs-brigade-task-transition task-id 'cancelled))
           (rejected (plist-get res :rejected))
           ;; A task that had already finished cannot become `cancelled',
           ;; and does not need to: what the caller asked for was that it
           ;; stop, and a terminal task with its conversation released is
           ;; stopped.  Reporting failure here would be pedantry about
           ;; the state name for an outcome that was achieved.
           (already-done (and rejected
                              (memq (plist-get (cmacs-brigade-task-get task-id)
                                               :state)
                                    '(done failed cancelled over-budget)))))
      (cmacs-brigade--drain-queue)
      (cond
       ((not rejected)
        (run-hook-with-args 'cmacs-brigade-run-finished-functions
                            task-id 'cancelled
                            (cmacs-brigade-output-get task-id))
        t)
       (already-done t)
       (t (message "cmacs-brigade: %s could not be cancelled: %s"
                   task-id (plist-get res :reason))
          nil)))))

(defun cmacs-brigade-outstanding-count ()
  "How much work is still in flight, counting parked conversations.

Not `cmacs-brigade-live-count\=', which is the concurrency gate and must
keep counting running processes only -- inflating it would defeat the
whole point of a parked conversation releasing its slot.  This is the
number to ask when deciding whether everything is finished: a task
sitting in `waiting-input\=' with three messages queued is emphatically not
finished, however idle the process table looks."
  (+ (hash-table-count cmacs-brigade--runs)
     (let ((n 0))
       (dolist (id (hash-table-keys cmacs-brigade--conversations) n)
         (when (and (null (gethash id cmacs-brigade--runs))
                    (fboundp 'cmacs-brigade-mailbox-count)
                    (> (cmacs-brigade-mailbox-count id) 0))
           (setq n (1+ n)))))))

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
