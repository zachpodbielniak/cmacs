;;; cmacs-brigade-mailbox.el --- Saying one more thing to an agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A queue of messages waiting to be delivered to a task, and the five
;; tools that let a model -- or you, or D-Bus, or bacon -- put something
;; in it.
;;
;; The queue exists because delivery cannot be synchronous.  A task is
;; either running, in which case interrupting its turn would mean
;; discarding work already paid for, or parked, in which case waking it
;; costs a process spawn.  Neither is something a caller should have to
;; know about, so `agent_send' always does the same thing: append, then
;; ask the run layer to consider starting.  What state the task was in
;; changes when the message is delivered, never whether it is.
;;
;; Two rules the rest of this file exists to keep:
;;
;;   Enqueue unconditionally, before anything else.  Brigade tool calls
;;   arriving over MCP are evaluated from inside Emacs's pselect hook, so
;;   `agent_send' can genuinely run in the middle of another task's
;;   completion.  A send that first asked "is it running?" and then
;;   enqueued could have the answer change underneath it.  Appending
;;   first makes the question irrelevant: whoever looks next sees the
;;   message.
;;
;;   Peek, never pop, until the turn has actually started.  Popping at
;;   delivery time means a start that fails -- an isolation backend that
;;   has gone away, an agent definition that was reloaded out from under
;;   the task -- silently eats what somebody typed.
;;
;; Messages are persisted as JSONL under the state directory, so a
;; message queued against a busy agent survives the restart that happens
;; before it is delivered.  The file is rewritten rather than appended
;; because a mailbox is small and `agent_drop' has to be able to remove
;; from the middle.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-log)
(require 'json)
(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-brigade-kick-conversation "cmacs-brigade-run")
(declare-function cmacs-brigade-conversation-p "cmacs-brigade-run")
(declare-function cmacs-brigade-conversation-turn "cmacs-brigade-run")
(declare-function cmacs-brigade-close-conversation "cmacs-brigade-run")
(declare-function cmacs-brigade-task-supports-session-p "cmacs-brigade-run")

(defcustom cmacs-brigade-mailbox-dir
  (expand-file-name "mailbox" cmacs-brigade-state-dir)
  "Where undelivered messages are kept, one file per task."
  :type 'directory
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-mailbox-max 64
  "Most messages that may be queued against one task.

A runaway parent that spawns a child and then talks to it in a loop is
the shape of mistake that only shows up on the bill.  Refusing past a
bound turns that into an error the model can read."
  :type 'integer
  :group 'cmacs-brigade)

(defvar cmacs-brigade--mailbox (make-hash-table :test 'equal)
  "Task id -> list of pending message plists, oldest first.")

(defvar cmacs-brigade-mailbox-delivered-functions nil
  "Abnormal hook run with the task id and message plist on delivery.")


;;;; Storage

(defun cmacs-brigade-mailbox-file (id)
  "Path of task ID's pending-message file."
  (expand-file-name (format "%s.jsonl" id) cmacs-brigade-mailbox-dir))

(defun cmacs-brigade-mailbox--save (id)
  "Write task ID's queue to disk, or remove the file when it is empty."
  (condition-case err
      (let ((msgs (gethash id cmacs-brigade--mailbox))
            (file (cmacs-brigade-mailbox-file id)))
        (if (null msgs)
            (when (file-exists-p file) (delete-file file))
          (make-directory cmacs-brigade-mailbox-dir t)
          (let ((coding-system-for-write 'utf-8))
            (with-temp-file file
              (dolist (m msgs)
                (insert (json-serialize
                         (list :text (or (plist-get m :text) "")
                               :from (or (plist-get m :from) "?")
                               :at (or (plist-get m :at) 0)))
                        "\n"))))))
    ;; A queue that cannot be persisted is still a queue that works for
    ;; this session; losing it on restart is much better than refusing
    ;; the message now.
    (error (message "cmacs-brigade: could not save mailbox for %s: %s"
                    id (error-message-string err)))))

(defun cmacs-brigade-mailbox--load (id)
  "Read task ID's queue from disk into memory."
  (let ((file (cmacs-brigade-mailbox-file id))
        msgs)
    (when (file-readable-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p (string-trim line))
              ;; A malformed line is skipped, not fatal: the file is
              ;; rewritten from a live editor and a truncated tail is a
              ;; normal consequence of a crash.  Dropping the other
              ;; messages because of one bad line would be the larger
              ;; loss.
              (when-let* ((e (condition-case nil
                                 (json-parse-string line :object-type 'alist
                                                    :array-type 'list
                                                    :null-object nil
                                                    :false-object nil)
                               (error nil))))
                (push (list :text (or (alist-get 'text e) "")
                            :from (or (alist-get 'from e) "?")
                            :at (or (alist-get 'at e) 0))
                      msgs))))
          (forward-line 1))))
    (when msgs (puthash id (nreverse msgs) cmacs-brigade--mailbox))
    (gethash id cmacs-brigade--mailbox)))

;;;###autoload
(defun cmacs-brigade-mailbox-restore ()
  "Load every persisted mailbox.  Returns how many tasks had one."
  (interactive)
  (let ((n 0))
    (when (file-directory-p cmacs-brigade-mailbox-dir)
      (dolist (f (directory-files cmacs-brigade-mailbox-dir nil "\\.jsonl\\'"))
        (when (cmacs-brigade-mailbox--load (file-name-base f))
          (setq n (1+ n)))))
    (when (called-interactively-p 'any)
      (message "cmacs-brigade: %d mailbox(es) restored" n))
    n))


;;;; Queue operations

(defun cmacs-brigade-mailbox-count (id)
  "How many messages are waiting for task ID."
  (length (gethash id cmacs-brigade--mailbox)))

(defun cmacs-brigade-mailbox-list (id)
  "The messages waiting for task ID, oldest first."
  (copy-sequence (gethash id cmacs-brigade--mailbox)))

(defun cmacs-brigade-mailbox-peek (id)
  "The next message for task ID without removing it, or nil.

Deliberately not a pop.  The caller removes it with
`cmacs-brigade-mailbox-pop' once the turn has actually started; a start
that fails leaves the message at the head of the queue where the next
attempt will find it, rather than consuming it into a run that never
happened."
  (car (gethash id cmacs-brigade--mailbox)))

(defun cmacs-brigade-mailbox-pop (id)
  "Remove and return task ID's next message."
  (let* ((msgs (gethash id cmacs-brigade--mailbox))
         (head (car msgs)))
    (when head
      (if (cdr msgs)
          (puthash id (cdr msgs) cmacs-brigade--mailbox)
        (remhash id cmacs-brigade--mailbox))
      (cmacs-brigade-mailbox--save id)
      (run-hook-with-args 'cmacs-brigade-mailbox-delivered-functions id head))
    head))

(defun cmacs-brigade-mailbox-enqueue (id text &optional from)
  "Append TEXT to task ID's queue and return the message.

Does no kicking and asks nothing about the task's state -- that is
`cmacs-brigade-mailbox-send'.  Kept separate so the enqueue is a single
step that nothing can interleave with."
  (let ((msgs (gethash id cmacs-brigade--mailbox)))
    (when (>= (length msgs) cmacs-brigade-mailbox-max)
      (signal 'cmacs-brigade-error
              (list (format "%s already has %d messages queued"
                            id (length msgs)))))
    (let ((msg (list :text text
                     :from (or from "human")
                     :at (floor (float-time)))))
      ;; Appended at the tail: order is the entire contract of a mailbox,
      ;; and a `push' here would have delivered the most recent message
      ;; first, which is the exact opposite of what anyone means.
      (puthash id (append msgs (list msg)) cmacs-brigade--mailbox)
      (cmacs-brigade-mailbox--save id)
      msg)))

(defun cmacs-brigade-mailbox-drop (id &optional index)
  "Remove one queued message from task ID, or all of them.

INDEX is zero-based and counts from the front of the queue; nil clears
the whole mailbox.  Returns how many were removed."
  (let ((msgs (gethash id cmacs-brigade--mailbox)))
    (cond
     ((null msgs) 0)
     ((null index)
      (remhash id cmacs-brigade--mailbox)
      (cmacs-brigade-mailbox--save id)
      (length msgs))
     ((or (< index 0) (>= index (length msgs)))
      (signal 'cmacs-brigade-error
              (list (format "%s has no message at index %d (0-%d)"
                            id index (1- (length msgs))))))
     (t
      (let ((rest (append (cl-subseq msgs 0 index)
                          (cl-subseq msgs (1+ index)))))
        (if rest
            (puthash id rest cmacs-brigade--mailbox)
          (remhash id cmacs-brigade--mailbox))
        (cmacs-brigade-mailbox--save id)
        1)))))

;;;###autoload
(defun cmacs-brigade-mailbox-send (id text &optional from)
  "Queue TEXT for task ID and wake it if it is parked.

The order here is the whole point: the message is on the queue before
anything looks at the task's state, so a completion racing this send
cannot finish between the check and the append and leave the message
undelivered.  Whichever of the two runs second does the waking."
  (let ((rec (and (fboundp 'cmacs-brigade-task-get)
                  (cmacs-brigade-task-get id))))
    (unless rec
      (signal 'cmacs-brigade-error (list (format "no such task: %s" id))))
    ;; Refused rather than queued forever: a worker with no session
    ;; cannot continue a conversation, and silently re-running it with a
    ;; follow-up message as though that were a fresh first prompt is the
    ;; kind of wrong that looks like it worked.
    (when (and (fboundp 'cmacs-brigade-task-supports-session-p)
               (not (cmacs-brigade-task-supports-session-p id)))
      (signal 'cmacs-brigade-error
              (list (format "%s runs under a worker that has no session; it cannot be continued"
                            id))))
    (let ((msg (cmacs-brigade-mailbox-enqueue id text from)))
      (cmacs-brigade-log-append
       id "message"
       :turn (1+ (if (fboundp 'cmacs-brigade-conversation-turn)
                     (or (cmacs-brigade-conversation-turn id) 0)
                   0))
       :role "user" :text text :from (or from "human"))
      (when (fboundp 'cmacs-brigade-kick-conversation)
        (cmacs-brigade-kick-conversation id))
      msg)))


;;;; Tools

(defun cmacs-brigade-mailbox--describe (id)
  "A short listing of task ID's queue."
  (let ((msgs (cmacs-brigade-mailbox-list id)))
    (if (null msgs)
        (format "%s has no messages waiting." id)
      (concat
       (format "%s has %d message(s) waiting:\n" id (length msgs))
       (mapconcat
        (lambda (m)
          (let ((text (or (plist-get m :text) "")))
            (format "  [%d] from %s: %s"
                    (cl-position m msgs)
                    (or (plist-get m :from) "?")
                    (if (<= (length text) 70) text
                      (concat (substring text 0 67) "...")))))
        msgs "\n")))))

(cmacs-brigade-deftool agent-send
  "Say something more to an agent.  Works whether it is still running --
the message is delivered when its current turn ends -- or already
finished, in which case it starts again with the same conversation and
remembers everything from before.  Returns immediately; poll with
agent_status and collect with agent_result as usual."
  ((id string "Task id, from agent_spawn")
   (message string "What to say.  It continues the existing conversation,
so you do not need to repeat context you already gave it."))
  :group 'mailbox
  ;; Destructive for the same reason agent_spawn is: it starts work that
  ;; costs money on a schedule the caller does not control.
  :destructive t :confirm 'ask
  (condition-case err
      (progn
        (cmacs-brigade-mailbox-send id message "agent")
        (format "Queued for %s (%d waiting).  Poll agent_status(\"%s\")."
                id (cmacs-brigade-mailbox-count id) id))
    (error (format "Could not send: %s" (error-message-string err)))))

(cmacs-brigade-deftool agent-inbox
  "List the messages queued for an agent that it has not yet been given.
Use it to check whether something you sent has been picked up."
  ((id string "Task id, from agent_spawn"))
  :group 'mailbox
  (cmacs-brigade-mailbox--describe id))

(cmacs-brigade-deftool agent-drop
  "Remove a message you queued but no longer want delivered.  Only works
while it is still waiting -- a message already given to the agent cannot
be taken back."
  ((id string "Task id, from agent_spawn")
   (index integer "Which queued message, from agent_inbox.  Omit to clear
the whole queue." :optional t))
  :group 'mailbox
  :destructive t
  (condition-case err
      (let ((n (cmacs-brigade-mailbox-drop id index)))
        (format "Dropped %d message(s) from %s." n id))
    (error (format "Could not drop: %s" (error-message-string err)))))

(cmacs-brigade-deftool agent-log
  "Read the full transaction log of any agent -- every message it was
given, every reply, every tool it called, in order.  You do NOT need to
have spawned it.

This is how you inspect an agent that is misbehaving: read its log and
see what it actually did, rather than what it says it did.  Use from_turn
to read only what is new since you last looked."
  ((id string "Task id of the agent to inspect")
   (from_turn integer "Only entries from this turn onward.  Omit for all."
              :optional t)
   (kinds string "Comma-separated entry kinds to keep: message, reply,
tool, state.  Omit for all." :optional t))
  :group 'mailbox
  (let* ((kind-list (and kinds (not (string-empty-p kinds))
                         (split-string kinds "[, ]+" t)))
         (text (cmacs-brigade-log-render
                id (and from_turn (> from_turn 0) from_turn) kind-list)))
    (cond
     ((and text (not (string-empty-p (string-trim text)))) text)
     ((and (fboundp 'cmacs-brigade-task-get) (cmacs-brigade-task-get id))
      (format "%s has produced no log entries yet." id))
     (t (format "No such task: %s" id)))))

(cmacs-brigade-deftool agent-close
  "Finish with an agent for good: drop anything still queued for it and
release the conversation it was holding.  Its log stays readable.  Do
this when you are done with a subagent you have been going back and forth
with, so it is not holding a session open indefinitely."
  ((id string "Task id, from agent_spawn"))
  :group 'mailbox
  :destructive t
  (if (not (and (fboundp 'cmacs-brigade-close-conversation)
                (cmacs-brigade-task-get id)))
      (format "No such task: %s" id)
    (let ((dropped (cmacs-brigade-mailbox-drop id)))
      (cmacs-brigade-close-conversation id)
      (format "Closed %s%s." id
              (if (> dropped 0)
                  (format ", dropping %d undelivered message(s)" dropped)
                "")))))

(provide 'cmacs-brigade-mailbox)

;;; cmacs-brigade-mailbox.el ends here
