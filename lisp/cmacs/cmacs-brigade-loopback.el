;;; cmacs-brigade-loopback.el --- Telling the asker when an agent is done  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A chat asks for a subagent, gets an id back, and then stops.
;;
;; That is correct behaviour -- `agent_spawn' returns immediately because
;; a blocking spawn holds a turn open for minutes -- but it leaves the
;; conversation parked.  The work finishes, nothing says so, and the
;; whole thing waits for a human to come back and type "is it done yet".
;; The agent had everything it needed to carry on and no way to know it
;; was time.
;;
;; So: a finished run delivers a turn back into the conversation that
;; asked for it.  The model sees "subagent a17 finished", calls
;; `agent_result', and continues on its own.
;;
;; Two ways a task acquires somewhere to report back to:
;;
;;   - implicitly, when `agent_spawn' runs inside a chat.  The chat
;;     buffer is current while its tools execute, so the spawn simply
;;     notices where it is;
;;   - explicitly, from the compose transient's `N' key, which is how a
;;     task you started by hand can still report into a conversation.
;;
;; Either way it lands in the same place: a `:NOTIFY:' property on the
;; task, so the target is visible in the plan, survives a restart, and is
;; editable like every other piece of intent.
;;
;; Delivery goes through the `client' registry rather than knowing about
;; chat buffers, so libreclaw, a Matrix room, or anything else is reached
;; by the same path -- see `cmacs-brigade-register-client'.  A target
;; that is busy is waited for rather than interrupted: a message arriving
;; mid-stream would interleave with the model's own turn.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-run)
;; The notify target is a plan property, so the reader has to be here.
;; No extra cost: cmacs-brigade-run already pulls this in.
(require 'cmacs-brigade-plan)
(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-ai-chat-send-compose "cmacs-ai-chat" ())

(defvar cmacs-ai-chat--compose-marker)
(defvar cmacs-ai-chat--assistant-marker)
(defvar cmacs-ai-chat--pending-tool-uses)

(defcustom cmacs-brigade-loopback-enabled t
  "Whether a finished agent tells the conversation that asked for it.

Off means the old behaviour: the chat is left parked until someone
notices.  Nothing is delivered to a task that never recorded a target, so
turning this off only matters for the ones that did."
  :type 'boolean
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-loopback-message
  "[automatic] Subagent %s (%s) has finished with state `%s'.  \
Call agent_result with id \"%s\" to collect what it produced, then \
carry on with what you were doing.  If it failed, say so and stop \
rather than retrying it blindly."
  "Message delivered when a subagent finishes.

Takes the task id, the agent name, the final state, and the id again.

Deliberately says the state but not the output: the result can be long,
and `agent_result' is the tool the model already knows.  Marked
`[automatic]' so the transcript shows plainly that nobody typed it."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-loopback-retry-seconds 5
  "How often a queued message re-checks whether its target is free."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-loopback-give-up-seconds 900
  "How long a queued message waits for a busy target before it is dropped.

A conversation left mid-stream for a quarter of an hour is not coming
back to this; delivering then would drop an unexplained line into
something the user has long moved on from."
  :type 'number
  :group 'cmacs-brigade)


;;;; Targets
;;
;; A target id is "CLIENT:REST" -- "chat:*cmacs-ai: grok*".  The prefix
;; picks the client out of the registry, and the rest means whatever that
;; client wants.  One string, so it fits in an org property and reads as
;; what it is.

(defun cmacs-brigade-loopback-target-client (target)
  "The client plist handling TARGET, or nil."
  (when (and target (stringp target) (string-match "\\`\\([^:]+\\):" target))
    (cmacs-brigade-registry-get 'client (intern (match-string 1 target)))))

(defun cmacs-brigade-loopback--call (target key &rest args)
  "Call TARGET's client function KEY with TARGET and ARGS.
Returns nil when the client or the function is absent."
  (when-let* ((client (cmacs-brigade-loopback-target-client target))
              (fn (plist-get client key)))
    (apply fn target args)))

(defun cmacs-brigade-loopback-targets ()
  "Every live target, as (ID . LABEL), across every registered client."
  (let (out)
    (dolist (name (cmacs-brigade-registry-list 'client))
      (let ((client (cmacs-brigade-registry-get 'client name)))
        (when-let* ((fn (plist-get client :targets)))
          (setq out (append out (ignore-errors (funcall fn)))))))
    out))

(defun cmacs-brigade-loopback-current-target ()
  "The target for the context this is being called from, or nil.

What `agent_spawn' uses to notice that it is running inside a chat."
  (let (found)
    (dolist (name (cmacs-brigade-registry-list 'client))
      (unless found
        (let ((client (cmacs-brigade-registry-get 'client name)))
          (when-let* ((fn (plist-get client :current)))
            (setq found (ignore-errors (funcall fn)))))))
    found))

(defun cmacs-brigade-loopback-live-p (target)
  "Whether TARGET still exists."
  (and target
       (let ((fn (plist-get (cmacs-brigade-loopback-target-client target)
                            :live-p)))
         (if fn (and (ignore-errors (funcall fn target)) t) t))))

(defun cmacs-brigade-loopback-ready-p (target)
  "Whether TARGET can take a message right now."
  (let ((fn (plist-get (cmacs-brigade-loopback-target-client target)
                       :ready-p)))
    (if fn (and (ignore-errors (funcall fn target)) t) t)))


;;;; Delivery, with waiting

(defvar cmacs-brigade-loopback--queue nil
  "List of (TARGET TEXT DEADLINE) waiting for a busy target.")

(defvar cmacs-brigade-loopback--timer nil)

(defun cmacs-brigade-loopback-deliver (target text)
  "Deliver TEXT to TARGET, waiting if it is busy.  Returns non-nil if sent."
  (cond
   ((not (cmacs-brigade-loopback-live-p target))
    (message "cmacs-brigade: %s is gone; not delivering" target)
    nil)
   ((cmacs-brigade-loopback-ready-p target)
    (cmacs-brigade-loopback--send target text))
   (t
    ;; Busy: a message inserted mid-stream interleaves with the model's
    ;; own turn and corrupts the transcript for both.
    (push (list target text
                (+ (float-time) cmacs-brigade-loopback-give-up-seconds))
          cmacs-brigade-loopback--queue)
    (cmacs-brigade-loopback--arm-timer)
    nil)))

(defun cmacs-brigade-loopback--send (target text)
  "Hand TEXT to TARGET's client.  Returns non-nil on success."
  (condition-case err
      (and (cmacs-brigade-loopback--call target :deliver text) t)
    (error
     (message "cmacs-brigade: could not notify %s: %s"
              target (error-message-string err))
     nil)))

(defun cmacs-brigade-loopback--arm-timer ()
  (unless cmacs-brigade-loopback--timer
    (setq cmacs-brigade-loopback--timer
          (run-at-time cmacs-brigade-loopback-retry-seconds
                       cmacs-brigade-loopback-retry-seconds
                       #'cmacs-brigade-loopback--drain))))

(defun cmacs-brigade-loopback--drain ()
  "Try the queued messages again, dropping the ones that timed out."
  (let ((now (float-time))
        (still nil))
    (dolist (entry cmacs-brigade-loopback--queue)
      (cl-destructuring-bind (target text deadline) entry
        (cond
         ((not (cmacs-brigade-loopback-live-p target)) nil)
         ((> now deadline)
          (message "cmacs-brigade: gave up notifying %s" target))
         ((cmacs-brigade-loopback-ready-p target)
          (unless (cmacs-brigade-loopback--send target text)
            (push entry still)))
         (t (push entry still)))))
    (setq cmacs-brigade-loopback--queue (nreverse still))
    (unless cmacs-brigade-loopback--queue
      (when cmacs-brigade-loopback--timer
        (cancel-timer cmacs-brigade-loopback--timer)
        (setq cmacs-brigade-loopback--timer nil)))))


;;;; The finished hook

(defvar cmacs-brigade-loopback--notified (make-hash-table :test 'equal)
  "Task ids already reported, so a re-fired hook cannot double-notify.")

(defun cmacs-brigade-loopback-task-target (task-id)
  "The target TASK-ID reports to, or nil."
  (when-let* ((record (and (fboundp 'cmacs-brigade-task-get)
                           (cmacs-brigade-task-get task-id))))
    (and (fboundp 'cmacs-brigade-plan-task-property)
         (cmacs-brigade-plan-task-property
          (plist-get record :plan) task-id "NOTIFY"))))

(defun cmacs-brigade-loopback-on-finished (task-id state &optional _output)
  "Tell whoever asked for TASK-ID that it ended in STATE."
  (when (and cmacs-brigade-loopback-enabled
             (not (gethash task-id cmacs-brigade-loopback--notified)))
    (when-let* ((target (cmacs-brigade-loopback-task-target task-id)))
      (puthash task-id t cmacs-brigade-loopback--notified)
      (let* ((record (cmacs-brigade-task-get task-id))
             (agent (or (plist-get record :agent) "an agent"))
             (text (format cmacs-brigade-loopback-message
                           task-id agent state task-id)))
        (cmacs-brigade-loopback-deliver target text)))))

(add-hook 'cmacs-brigade-run-finished-functions
          #'cmacs-brigade-loopback-on-finished)


;;;; The shipped client: cmacs-ai chat buffers

(defun cmacs-brigade-loopback--chat-buffer (target)
  "The live chat buffer TARGET names, or nil."
  (when (and target (string-prefix-p "chat:" target))
    (let ((buf (get-buffer (substring target (length "chat:")))))
      (when (and (buffer-live-p buf)
                 (with-current-buffer buf
                   (derived-mode-p 'cmacs-ai-chat-mode)))
        buf))))

(defun cmacs-brigade-loopback--chat-current ()
  "The target for the current buffer, when it is a chat.

`agent_spawn' calls this while the chat's tool loop is running, and the
chat layer executes tools with its own buffer current -- so noticing
where we are needs no plumbing between the two."
  (when (and (derived-mode-p 'cmacs-ai-chat-mode)
             (buffer-live-p (current-buffer)))
    (format "chat:%s" (buffer-name))))

(defun cmacs-brigade-loopback--chat-targets ()
  "Every open chat buffer, as (TARGET . LABEL)."
  (let (out)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'cmacs-ai-chat-mode)
          (push (cons (format "chat:%s" (buffer-name)) (buffer-name)) out))))
    (nreverse out)))

(defun cmacs-brigade-loopback--chat-ready-p (target)
  "Whether the chat TARGET names is idle enough to take a message.

Three ways it is not: a reply is streaming, tool calls are pending, or
the human has something half-typed in the compose region -- and sending
then would take their draft along with it."
  (when-let* ((buf (cmacs-brigade-loopback--chat-buffer target)))
    (with-current-buffer buf
      (and (not (bound-and-true-p cmacs-ai-chat--assistant-marker))
           (null (bound-and-true-p cmacs-ai-chat--pending-tool-uses))
           (or (null cmacs-ai-chat--compose-marker)
               (string-empty-p
                (string-trim
                 (buffer-substring-no-properties
                  cmacs-ai-chat--compose-marker (point-max)))))))))

(defun cmacs-brigade-loopback--chat-deliver (target text)
  "Put TEXT in the chat TARGET names and send it.

Through the ordinary compose-and-send path rather than a private one, so
the turn is rendered, persisted, tool-enabled and streamed exactly like
one that was typed."
  (when-let* ((buf (cmacs-brigade-loopback--chat-buffer target)))
    (with-current-buffer buf
      (unless (and cmacs-ai-chat--compose-marker
                   (fboundp 'cmacs-ai-chat-send-compose))
        (error "cmacs-brigade: %s has no compose region" target))
      (save-excursion
        (goto-char (point-max))
        (let ((inhibit-read-only t))
          (insert text)))
      (cmacs-ai-chat-send-compose)
      t)))

(cmacs-brigade-register-client
 :name 'chat
 :current #'cmacs-brigade-loopback--chat-current
 :targets #'cmacs-brigade-loopback--chat-targets
 :live-p (lambda (target) (cmacs-brigade-loopback--chat-buffer target))
 :ready-p #'cmacs-brigade-loopback--chat-ready-p
 :deliver #'cmacs-brigade-loopback--chat-deliver)

(provide 'cmacs-brigade-loopback)

;;; cmacs-brigade-loopback.el ends here
