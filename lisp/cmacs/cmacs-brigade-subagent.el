;;; cmacs-brigade-subagent.el --- Agents that spawn agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The five tools that let a model hand work to another model:
;; `agent_spawn', `agent_status', `agent_result', `agent_cancel' and
;; `agent_list'.  Published like any other brigade tool, so one
;; registration reaches in-process agents, CLI agents over the MCP relay,
;; and external MCP clients -- and a plain `cmacs-ai' chat buffer, which
;; is where you would reach for them by hand.
;;
;; Spawning is deliberately not `brigade_spawn'.  The allowlist refuses
;; every `brigade_' and `ai_' name outright, so that an agent cannot
;; reach back into the orchestrator and start work outside its budget
;; accounting.  These five are the sanctioned way through that wall: they
;; go through the same queue, the same concurrency cap and the same state
;; machine as a task you started yourself, and a parent that spawns is
;; visible on the dashboard next to what it spawned.
;;
;; They are asynchronous by design.  `agent_spawn' returns an id
;; immediately rather than blocking until the subagent finishes: a
;; blocking spawn holds a turn open for minutes, and every provider has
;; a tool-call timeout shorter than the work is likely to take.  The
;; parent polls with `agent_status' and collects with `agent_result'.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-run)
(require 'cmacs-brigade-output)
;; A spawn records where it came from, so the client registry has to be
;; live by then.  No cycle: loopback knows nothing about subagents.
(require 'cmacs-brigade-loopback)
(require 'cmacs-ai nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

(defcustom cmacs-brigade-subagent-plan nil
  "Plan file that spawned subagents are recorded in.

nil means `subagents.org' under `cmacs-brigade-plan-directory'.  They go
in a plan like everything else, so a subagent is as visible, inspectable
and cancellable as a task you wrote by hand."
  :type '(choice (const :tag "subagents.org in the plan directory") file)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-subagent-default-agent 'general
  "Agent used when a spawn names none.

`general\=' is a neutral agent that ships with cmacs.  It matters that the
default is deliberate: the fallback used to be whichever agent sorted
first, which on a machine with `~/.claude/agents\=' meant every unqualified
spawn silently inherited a code reviewer\='s system prompt.

nil restores that alphabetical fallback."
  :type '(choice (const :tag "First registered" nil) symbol)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-subagent-max-depth 2
  "How deep spawning may nest.

A subagent that can spawn can spawn something that spawns, and a runaway
tree is expensive in a way that is hard to notice until the bill.  Depth
0 forbids spawning entirely."
  :type 'integer
  :group 'cmacs-brigade)

(defvar cmacs-brigade-subagent--parent (make-hash-table :test 'equal)
  "Task id -> the task that spawned it.")

(declare-function cmacs-brigade-plan-adopt "cmacs-brigade-plan")
(declare-function cmacs-ai-providers "cmacs-ai-defuns.c")
(declare-function cmacs-ai-list-models "cmacs-ai-stream.c")
(declare-function cmacs-ai-client-new "cmacs-ai-client.c")
(declare-function cmacs-ai-client-cli-p "cmacs-ai-client.c")
(declare-function cmacs-brigade-plan--entry-id "cmacs-brigade-plan")
(defvar cmacs-brigade-plan-todo-line)
(defvar cmacs-brigade-plan-directory)

(defun cmacs-brigade-subagent--plan ()
  "The subagent plan file, created if absent."
  (require 'cmacs-brigade-plan)
  (let ((file (or cmacs-brigade-subagent-plan
                  (expand-file-name "subagents.org"
                                    cmacs-brigade-plan-directory))))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+title: Spawned subagents\n"
                cmacs-brigade-plan-todo-line "\n\n")))
    file))

(defun cmacs-brigade-subagent-depth (task-id)
  "How many spawns deep TASK-ID is."
  (let ((depth 0) (cur task-id))
    (while (and cur (< depth 100))
      (setq cur (gethash cur cmacs-brigade-subagent--parent))
      (when cur (setq depth (1+ depth))))
    depth))

(defun cmacs-brigade-subagent-children (task-id)
  "The tasks TASK-ID spawned."
  (let (out)
    (maphash (lambda (child parent)
               (when (equal parent task-id) (push child out)))
             cmacs-brigade-subagent--parent)
    (nreverse out)))

(defun cmacs-brigade-subagent-parent (task-id)
  "The task that spawned TASK-ID, or nil."
  (gethash task-id cmacs-brigade-subagent--parent))

(defun cmacs-brigade-subagent-spawn (agent task &optional title parent model
                                           directory)
  "Queue TASK for AGENT and return the new task id.

PARENT, when given, is the task doing the spawning; it bounds depth and
puts the pair on the dashboard as a tree.  MODEL overrides the agent's
own, as \"provider/model\"; nil keeps whatever the agent definition
says, which is the usual case."
  (let* ((agent (or agent
                    ;; Only fall through when the named default is not
                    ;; loaded: a missing `general' should not silently
                    ;; become whatever sorts first.
                    (and cmacs-brigade-subagent-default-agent
                         (cmacs-brigade-agent-get
                          cmacs-brigade-subagent-default-agent)
                         cmacs-brigade-subagent-default-agent)
                    (car (cmacs-brigade-registry-list 'agent))))
         (depth (if parent (1+ (cmacs-brigade-subagent-depth parent)) 0))
         ;; Captured before the plan buffer is opened below: inside that
         ;; `with-current-buffer', `default-directory' is the plan file's
         ;; directory, so recording it there wrote the wrong answer --
         ;; the notes tree rather than the project the spawn came from.
         (cwd (file-name-as-directory
               (expand-file-name (or directory default-directory))))
         (notify (and (fboundp 'cmacs-brigade-loopback-current-target)
                      (cmacs-brigade-loopback-current-target))))
    (unless agent
      (signal 'cmacs-brigade-error (list "no agent definitions are loaded")))
    (unless (cmacs-brigade-agent-get agent)
      (signal 'cmacs-brigade-error
              (list (format "no agent named %s" agent)
                    (format "known: %s"
                            (mapconcat #'symbol-name
                                       (cmacs-brigade-registry-list 'agent)
                                       ", ")))))
    (when (> depth cmacs-brigade-subagent-max-depth)
      (signal 'cmacs-brigade-error
              (list (format "spawn depth %d exceeds %d"
                            depth cmacs-brigade-subagent-max-depth))))
    (let ((file (cmacs-brigade-subagent--plan))
          task-id)
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert (format "* TODO %s  :brigade:\n"
                          (or title
                              (cmacs-brigade-subagent--summarize task))))
          (insert "  :PROPERTIES:\n"
                  (format "  :AGENT:  %s\n" agent)
                  ;; Written as a property so the override is visible in
                  ;; the plan and survives a restart, the same way a
                  ;; hand-written one does.
                  (if (and model (not (string-empty-p model)))
                      (format "  :MODEL:  %s\n" model) "")
                  (format "  :CWD:    %s\n" (abbreviate-file-name cwd))
                  ;; Where to report back to when this finishes.  Captured
                  ;; at spawn because that is the only moment the origin
                  ;; is knowable: the chat's tool loop runs with its own
                  ;; buffer current, and by the time the subagent ends
                  ;; that context is long gone.
                  (if notify (format "  :NOTIFY: %s\n" notify) "")
                  (if parent (format "  :SPAWNED-BY: %s\n" parent) "")
                  "  :END:\n")
          (insert "  " task "\n")
          (org-back-to-heading t)
          (setq task-id (cmacs-brigade-plan--entry-id 'create)))
        (save-buffer)
        (cmacs-brigade-plan-adopt))
      (when parent (puthash task-id parent cmacs-brigade-subagent--parent))
      ;; Queued rather than started: `cmacs-brigade-start-task' respects
      ;; the concurrency cap, and a spawn storm must not get to walk past
      ;; the limit a hand-started task obeys.
      (cmacs-brigade-task-transition task-id 'queued)
      (cmacs-brigade-start-task task-id)
      task-id)))

(defun cmacs-brigade-subagent--summarize (text)
  (let ((one (replace-regexp-in-string "[ \t\n]+" " " (string-trim text))))
    (if (<= (length one) 60) one (concat (substring one 0 57) "..."))))

(defun cmacs-brigade-subagent--describe (id)
  "A one-line status for ID."
  (let ((r (cmacs-brigade-task-get id)))
    (if (null r) (format "%s: no such task" id)
      (format "%s: %s  agent=%s turns=%s tokens=%s/%s cost=$%.4f%s"
              id (plist-get r :state) (or (plist-get r :agent) "-")
              (or (plist-get r :turns) 0)
              (or (plist-get r :in-tokens) 0)
              (or (plist-get r :out-tokens) 0)
              (/ (or (plist-get r :cost-micros) 0) 1000000.0)
              (if-let* ((e (plist-get r :error))) (format "  error=%s" e) "")))))


;;;; The tools

(cmacs-brigade-deftool agent-spawn
  "Hand a piece of work to another agent, which runs in parallel with
you.  Returns a task id immediately -- it does NOT wait for the work to
finish.  Poll it with agent_status and collect the answer with
agent_result once the state is `done'.  Spawn several and poll them all
rather than spawning one and waiting."
  ((task string "What the subagent should do.  Write it as a standalone
instruction: the subagent does not see your conversation.")
   (agent string "Which agent definition to use; omit for the default"
          :optional t)
   (model string "Model as provider/model, e.g. claude/claude-sonnet-4-6.
Omit to use the agent's own -- call agent_models first if you want to
choose one." :optional t)
   (title string "Short label for the dashboard" :optional t))
  :group 'agent
  ;; Destructive: it spends money on your behalf, on a schedule you do
  ;; not control, which is exactly the shape of thing to confirm.
  :destructive t :confirm 'ask
  (condition-case err
      (let ((id (cmacs-brigade-subagent-spawn
                 (and agent (not (string-empty-p agent)) (intern agent))
                 task
                 (and title (not (string-empty-p title)) title)
                 nil
                 (and model (not (string-empty-p model)) model))))
        (format "Spawned %s.  Poll it with agent_status(\"%s\")." id id))
    (error (format "Could not spawn: %s" (error-message-string err)))))

(cmacs-brigade-deftool agent-status
  "Check on a subagent you spawned.  States are draft, queued, starting,
running, waiting-input, done, failed, cancelled and over-budget.  Only
`done' and `failed' are final."
  ((id string "Task id returned by agent_spawn"))
  :group 'agent
  (cmacs-brigade-subagent--describe id))

(cmacs-brigade-deftool agent-result
  "Collect what a subagent produced.  Call it once agent_status reports
`done'; on a `failed' task it returns whatever was produced before the
failure, which is usually the explanation."
  ((id string "Task id returned by agent_spawn"))
  :group 'agent
  (let ((r (cmacs-brigade-task-get id)))
    (cond
     ((null r) (format "No such task: %s" id))
     ((memq (plist-get r :state) '(draft queued starting running))
      (format "Still %s.  Poll agent_status again before collecting."
              (plist-get r :state)))
     (t (or (cmacs-brigade-output-get id)
            (format "%s finished with state %s and produced no output."
                    id (plist-get r :state)))))))


(cmacs-brigade-deftool agent-providers
  "List the AI providers this cmacs can reach, and whether each looks
usable.  Use before agent_models when you want to pick a model for a
spawn."
  ()
  :group 'agent
  (if (not (fboundp 'cmacs-ai-providers))
      "cmacs-ai is not available in this build."
    (mapconcat
     (lambda (p)
       (format "%s%s" p
               (if (and (fboundp 'cmacs-ai-client-cli-p)
                        (ignore-errors
                          (cmacs-ai-client-cli-p
                           (cmacs-ai-client-new p nil))))
                   "  (command-line agent)" "  (HTTP API)")))
     (cmacs-ai-providers) "\n")))

(cmacs-brigade-deftool agent-models
  "List the models a provider offers, for use as agent_spawn's model
argument.  The value to pass is \"provider/model\"."
  ((provider string "Provider name, from agent_providers"))
  :group 'agent
  (condition-case err
      (let ((models (cmacs-ai-list-models (intern provider))))
        (if (null models)
            (format "%s offers no model list; pass any name it accepts."
                    provider)
          (mapconcat (lambda (m) (format "%s/%s" provider m)) models "\n")))
    (error (format "Could not list models for %s: %s"
                   provider (error-message-string err)))))

(cmacs-brigade-deftool agent-cancel
  "Stop a subagent you spawned."
  ((id string "Task id returned by agent_spawn"))
  :group 'agent
  :destructive t
  (if (null (cmacs-brigade-task-get id))
      (format "No such task: %s" id)
    (cmacs-brigade-cancel-task id)
    (format "Cancelled %s." id)))

(cmacs-brigade-deftool agent-list
  "List the agent definitions available to spawn, and every task
currently known with its state."
  ()
  :group 'agent
  (let ((agents (cmacs-brigade-registry-list 'agent))
        (tasks (and (fboundp 'cmacs-brigade-task-list)
                    (cmacs-brigade-task-list))))
    (concat
     (format "Agents you can spawn: %s\n\n"
             (if agents (mapconcat #'symbol-name agents ", ") "none"))
     (if (null tasks) "No tasks."
       (concat "Tasks:\n"
               (mapconcat (lambda (r)
                            (concat "  " (cmacs-brigade-subagent--describe
                                          (plist-get r :id))))
                          tasks "\n"))))))


;;;; Publication into a plain cmacs-ai chat
;;
;; Through the hook cmacs-ai offers rather than by cmacs-ai requiring the
;; brigade: the brigade depends on cmacs-ai, and wiring it the other way
;; round would be a cycle.

(defcustom cmacs-brigade-chat-tools "agent,memory"
  "Brigade tool groups given to a `cmacs-ai' chat buffer.

Comma-separated groups or names, or nil to add none.  Chat buffers get
the agent and memory groups by default: those are the two that are
useful to have by hand and safe to hand a model unprompted."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-brigade)

;;;###autoload
(defun cmacs-brigade-chat-install-tools (executor _provider)
  "Add the brigade's tools to a cmacs-ai chat EXECUTOR."
  (when (and cmacs-brigade-chat-tools executor)
    (condition-case err
        ;; include-destructive: a chat buffer has a human in it, and
        ;; agent_spawn and agent_cancel are the whole point of having
        ;; these here.  They carry :confirm \='ask, so the confirmation
        ;; is the gate rather than the filter -- excluding them left a
        ;; chat that could inspect subagents and never start one.
        (cmacs-brigade-install-tools executor cmacs-brigade-chat-tools nil t)
      (error (message "cmacs-brigade: could not add tools to the chat: %s"
                      (error-message-string err))))))

;; The hook goes into loaddefs as a bare form, so it is in place at
;; startup without this file -- or the brigade at all -- being loaded.
;; Nothing requires `cmacs-brigade': its own eager-load block sits inside
;; it, so unless something pulls the file in, the registries stay empty
;; and a chat sees no brigade tools.  Registering the hook eagerly and
;; the handler lazily means opening a chat is what loads the fabric.
;;;###autoload (add-hook 'cmacs-ai-chat-executor-functions #'cmacs-brigade-chat-install-tools)
(add-hook 'cmacs-ai-chat-executor-functions
          #'cmacs-brigade-chat-install-tools)

(provide 'cmacs-brigade-subagent)

;;; cmacs-brigade-subagent.el ends here
