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

(defcustom cmacs-brigade-max-concurrent 4
  "How many agents may run at once.
Beyond this, tasks stay queued until a slot frees."
  :type 'integer
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-worker 'claude-code
  "Default execution backend for an agent that does not name one."
  :type 'symbol
  :group 'cmacs-brigade)

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
       (append (list cmacs-brigade-claude-program "--print")
               ;; The prompt arrives on stdin rather than argv: prompts
               ;; routinely exceed ARG_MAX, and argv is world-readable.
               (when config (list "--mcp-config" config))
               (when model (list "--model"
                                 (string-remove-prefix "claude/" model)))))
      ('opencode
       (append (list cmacs-brigade-opencode-program "run" "--format" "json")
               (when model (list "--model" model))))
      ('shell (list "bash" "-c" (format "cat %s | bash"
                                        (shell-quote-argument prompt-file))))
      (_ (user-error "cmacs-brigade: unknown worker %s" worker)))))

(defun cmacs-brigade--start-process (task-id agent prompt cwd env endpoint)
  "Spawn AGENT's worker for TASK-ID.  Returns the process."
  (let* ((worker (or (plist-get agent :worker) cmacs-brigade-worker))
         (prompt-file (make-temp-file "cmacs-brigade-prompt"))
         (argv (cmacs-brigade--worker-command worker agent prompt-file
                                              endpoint))
         (default-directory (or cwd default-directory))
         (process-environment
          (append (mapcar (lambda (c) (format "%s=%s" (car c) (cdr c))) env)
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

(defun cmacs-brigade--on-exit (task-id proc)
  "Record that TASK-ID's PROC finished."
  (let* ((run (gethash task-id cmacs-brigade--runs))
         (status (process-exit-status proc))
         (buf (process-buffer proc))
         (output (when (buffer-live-p buf)
                   (with-current-buffer buf (buffer-string))))
         (state (if (zerop status) 'done 'failed)))
    (when-let* ((f (process-get proc 'brigade-prompt-file)))
      (ignore-errors (delete-file f)))
    (when run
      ;; Order matters: revoke the credential before anything else can
      ;; fail, so a token never outlives the run that needed it.
      (cmacs-brigade-host-revoke task-id)
      (cmacs-brigade-isolation-teardown (plist-get run :isolation) task-id)
      (remhash task-id cmacs-brigade--runs))
    (when (fboundp 'cmacs-brigade-task-transition)
      (cmacs-brigade-task-transition
       task-id state (unless (zerop status)
                       (format "worker exited %s" status))))
    (when (buffer-live-p buf)
      (with-current-buffer buf (set-buffer-modified-p nil))
      (kill-buffer buf))
    (run-hook-with-args 'cmacs-brigade-run-finished-functions task-id state
                        output)
    (cmacs-brigade--drain-queue)))


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

(defun cmacs-brigade--start-now (task-id record agent)
  "Actually start TASK-ID with AGENT."
  (let* ((isolation (or (plist-get agent :isolation) 'none))
         (allowlist (cmacs-brigade-agent-allowlist agent))
         prepared endpoint proc)
    (unless (cmacs-brigade-isolation-available-p isolation)
      (cmacs-brigade-task-transition
       task-id 'failed (format "%s isolation is unavailable here" isolation))
      (cl-return-from cmacs-brigade--start-now nil))
    (cmacs-brigade-task-transition task-id 'starting)
    (condition-case err
        (progn
          (setq prepared (cmacs-brigade-isolation-prepare isolation task-id))
          (setq endpoint (cmacs-brigade-host-provision task-id allowlist))
          (setq proc (cmacs-brigade--start-process
                      task-id agent
                      (cmacs-brigade--build-prompt record agent)
                      (plist-get prepared :cwd)
                      (plist-get prepared :env)
                      endpoint))
          (puthash task-id (list :process proc :isolation isolation
                                 :agent (plist-get agent :name)
                                 :started (float-time))
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

(defun cmacs-brigade--build-prompt (record agent)
  "Assemble the prompt for RECORD run by AGENT."
  (let ((parts (list (plist-get agent :prompt))))
    ;; Context providers are a public registry, so a configuration can
    ;; inject whatever it wants here without patching this function.
    (dolist (name (cmacs-brigade-registry-list 'context-provider))
      (let* ((p (cmacs-brigade-registry-get 'context-provider name))
             (text (ignore-errors (funcall (plist-get p :provide) agent))))
        (when (and text (not (string-empty-p text)))
          (push text parts))))
    (push (or (plist-get record :prompt) "") parts)
    (string-join (nreverse (delq nil parts)) "\n\n")))

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
      (let ((proc (plist-get run :process)))
        (when (process-live-p proc) (delete-process proc))))
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
