;;; cmacs-clawtilla-tasks.el --- Tasks, broken runs and projects -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Work section's Tasks page, the page for one task, and Projects.
;;
;; A task used to be a row: an id, an assignee, a state.  Since
;; clawtilla 0.2x it is a piece of work with a life -- it is created or
;; delegated, waits on other tasks, is handed to somebody, gets a
;; checkout of its own to change, is commented on, reviewed, mirrored
;; to VENTURE as a ticket, and retried when its run breaks.  This file
;; is that life from the operator's side.
;;
;; Three things are drawn:
;;
;; - The Tasks page (`cmacs-clawtilla-tasks--load' and `--draw', which
;;   the section buffer calls): broken runs first, then every task with
;;   what it is waiting on.  A broken run is an INCIDENT -- a run that
;;   failed, stalled or could not start, and a routine that did not
;;   run -- reported to somebody the daemon is told to report to.
;; - One task (`cmacs-clawtilla-task', a page): what was asked, what was
;;   said about it, what it waits for, its checkout, its ticket, its
;;   review and its history, each with the verbs that go with it.
;; - Projects (a page): what the work is for, and a monthly budget.
;;
;; What a state MEANS is libclawt's and asked per state -- the badge's
;; tone and whether Cancel or Retry is offered (`clawt_task_state_tone',
;; `_is_retryable', `_nick_is_cancellable') -- so no list of which
;; states are which lives here.  So are the caption over the list, what
;; a task is waiting on, and the mark on a consultation.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-page)

(declare-function cmacs-clawtilla-chat "cmacs-clawtilla-chat")
(declare-function cmacs-clawtilla-section--draw "cmacs-clawtilla-section")
(declare-function cmacs-clawtilla-section--load "cmacs-clawtilla-section")
(defvar cmacs-clawtilla-section--reply)
(defvar cmacs-clawtilla-section--rows)
(defvar cmacs-clawtilla-section--page)

(defvar cmacs-clawtilla-tasks--state-cache (make-hash-table :test 'equal)
  "What libclawt says about each task state, by nick.

Cached because the answer for a state cannot change inside one process
and a page asks it once per row.")

(defun cmacs-clawtilla-tasks--state (nick)
  "Return what libclawt says about the task state NICK.

An alist of `tone', `cancellable' and `retryable'."
  (let ((nick (or nick "")))
    (or (gethash nick cmacs-clawtilla-tasks--state-cache)
        (puthash nick
                 (cmacs-clawtilla-ask-parsed "task-state" :state nick)
                 cmacs-clawtilla-tasks--state-cache))))

(defun cmacs-clawtilla-tasks--badge (state)
  "Return the task STATE as a badge in libclawt's tone for it."
  (propertize (or state "?")
              'face (cmacs-clawtilla-page-tone-face
                     (alist-get 'tone (cmacs-clawtilla-tasks--state state)))))

(defun cmacs-clawtilla-tasks--who (task)
  "Return who asked for TASK and who has it."
  (if (alist-get 'assignee task)
      (format "%s → %s" (or (alist-get 'origin task) "?")
              (alist-get 'assignee task))
    (format "%s · on the backlog" (or (alist-get 'origin task) "?"))))

(defun cmacs-clawtilla-tasks--stamp (seconds)
  "Format the Unix time SECONDS as a task's history does."
  (if (and (numberp seconds) (> seconds 0))
      (format-time-string "%-d %b %H:%M" (seconds-to-time seconds))
    ""))


;;;; The Tasks page.

(defun cmacs-clawtilla-tasks--load (buffer conn)
  "Fetch `task.list' and `incident.list' on CONN into the section BUFFER."
  (let ((tasks nil) (tasks-text nil) (incidents nil) (pending 2))
    (cl-flet ((done ()
                (setq pending (1- pending))
                (when (and (zerop pending) (buffer-live-p buffer))
                  (with-current-buffer buffer
                    (setq cmacs-clawtilla-section--reply
                          (list (cons 'tasks tasks)
                                (cons 'tasks-text tasks-text)
                                (cons 'incidents incidents)))
                    (setq cmacs-clawtilla-section--rows
                          (cmacs-clawtilla-get tasks 'tasks))
                    (cmacs-clawtilla-section--draw)))))
      (cmacs-clawtilla-request-both
       conn "task.list" nil
       (lambda (data text err)
         (if err (message "clawtilla: %s" err)
           (setq tasks data tasks-text text))
         (done)))
      (cmacs-clawtilla-request
       conn "incident.list" nil
       (lambda (data err)
         ;; A daemon without incidents answers an error; the page then
         ;; simply has no such group.
         (unless err (setq incidents data))
         (done))))))

(defun cmacs-clawtilla-tasks--incident-status (incident)
  "Return where the report of INCIDENT stands, as the GTK client says it."
  (let ((recipient (alist-get 'recipient incident))
        (note (alist-get 'note incident))
        (occurrences (or (alist-get 'occurrences incident) 1))
        (retried-by (alist-get 'retried_by incident)))
    (concat
     (cond (note (format "Recorded for you: %s" note))
           ((and (eq t (alist-get 'queued incident)) recipient)
            (format "Waiting for %s to finish a turn" recipient))
           (recipient (format "Reported to %s" recipient))
           (t "Not reported yet"))
     (if (> occurrences 1) (format " · broke %d times" occurrences) "")
     (if retried-by
         (format " · last retried by %s"
                 (if (equal retried-by "user") "you" retried-by))
       ""))))

(defun cmacs-clawtilla-tasks--recipient-label (nick)
  "Return libclawt's label for the incident recipient NICK."
  (or (alist-get 'label
                 (seq-find (lambda (entry) (equal (alist-get 'nick entry) nick))
                           (cmacs-clawtilla-enum "incident-recipient")))
      nick))

(defun cmacs-clawtilla-tasks--draw-incidents (reply)
  "Draw the broken runs from the `incident.list' REPLY."
  (when reply
    (let ((incidents (alist-get 'incidents reply)))
      (insert "  " (propertize "Broken runs" 'face 'cmacs-clawtilla-team)
              "  " (cmacs-clawtilla-dim "c changes how they are reported")
              "\n    "
              (cmacs-clawtilla-dim
               ;; `enabled' defaults to on in the daemon, and an explicit
               ;; false parses to nil just as an absent member does --
               ;; so "off" is only believed when the member is there.
               (if (and (assq 'enabled reply)
                        (not (eq t (alist-get 'enabled reply))))
                   "Not reported to anybody."
                 (format "Reported to: %s"
                         (cmacs-clawtilla-tasks--recipient-label
                          (or (alist-get 'to reply) "")))))
              "\n")
      (if (null incidents)
          (insert "    " (cmacs-clawtilla-dim
                          "Nothing has broken.  A run that fails, stalls or cannot start is listed here.")
                  "\n")
        (dolist (incident incidents)
          (cmacs-clawtilla-insert-section
           :type 'incident :value incident :level 2
           :heading
           (concat
            (propertize (or (alist-get 'kind incident) "?")
                        'face 'cmacs-clawtilla-error)
            "  "
            (format "%s's run %s" (or (alist-get 'agent incident) "?")
                    (or (alist-get 'kind_label incident) "broke"))
            (if (eq t (alist-get 'retryable incident))
                (concat "  " (cmacs-clawtilla-dim "r retries"))
              ""))
           :body (lambda ()
                   (when-let* ((reason (alist-get 'reason incident)))
                     (insert "        " (cmacs-clawtilla-dim reason) "\n"))
                   (insert "        "
                           (cmacs-clawtilla-dim
                            (cmacs-clawtilla-tasks--incident-status incident))
                           "\n")))))
      (insert "\n"))))

(defun cmacs-clawtilla-tasks--task-detail (task raw)
  "Return the detail lines for TASK, whose entry as sent is RAW.

RAW is the faithful parse of the same entry, which is where the library
reads `waiting_on' from."
  (let ((waiting (alist-get 'waiting_on raw))
        (lines (list (concat (cmacs-clawtilla-tasks--who task)
                             (if (alist-get 'project task)
                                 (format " · %s" (alist-get 'project task))
                               "")
                             (if (alist-get 'reason task)
                                 (format " · %s" (alist-get 'reason task))
                               "")))))
    (cond
     ((and (vectorp waiting) (> (length waiting) 0))
      (push (cmacs-clawtilla-ask
             "task-waiting"
             :waiting_on (cons :json (cmacs-clawtilla-faithful-text waiting)))
            lines))
     ((alist-get 'progress_note task)
      (push (alist-get 'progress_note task) lines))
     ((eq t (alist-get 'result_inferred task))
      (push (concat "nobody reported this finished -- it is the last thing "
                    "the assignee wrote")
            lines)))
    (when (eq t (alist-get 'consult task))
      (push (cmacs-clawtilla-label 'task_consult) lines))
    (when-let* ((summary (and (alist-get 'thread_room task)
                              (cmacs-clawtilla-ask
                               "task-thread"
                               :room (alist-get 'thread_room task)))))
      (push (concat summary " · o opens it") lines))
    (nreverse (delq nil lines))))

(defun cmacs-clawtilla-tasks--draw ()
  "Draw the Tasks page: broken runs, then every task."
  (let* ((reply cmacs-clawtilla-section--reply)
         (tasks (alist-get 'tasks reply))
         (faithful (cmacs-clawtilla-faithful-get
                    (cmacs-clawtilla-faithful (alist-get 'tasks-text reply))
                    'tasks))
         (index 0))
    ;; What the list covers, in the library's words: how far back it
    ;; goes and whether older tasks are kept at all.
    (when-let* ((caption (and tasks
                              (cmacs-clawtilla-ask
                               "task-caption"
                               :since (or (alist-get 'since tasks) 0)
                               :kept (if (eq t (alist-get 'kept tasks))
                                         t :false)
                               :retention_days
                               (or (alist-get 'retention_days tasks) 0)))))
      (cmacs-clawtilla-page--insert-filled caption "  ")
      (insert "\n"))
    (cmacs-clawtilla-tasks--draw-incidents (alist-get 'incidents reply))
    (insert "  " (propertize "Tasks" 'face 'cmacs-clawtilla-team) "  "
            (cmacs-clawtilla-dim
             "i new · RET details · a assign · r retry · D cancel")
            "\n")
    (if (null cmacs-clawtilla-section--rows)
        (insert "    " (propertize "No tasks yet" 'face 'bold) "\n    "
                (cmacs-clawtilla-dim
                 "Ask an agent to delegate work, or press i.  Its progress and result appear here.")
                "\n")
      (dolist (task cmacs-clawtilla-section--rows)
        (let ((raw (cmacs-clawtilla-faithful-get faithful index)))
          (cmacs-clawtilla-insert-section
           :type 'task :value task :level 2
           :heading (concat
                     (format "%-11s " (cmacs-clawtilla-tasks--badge
                                       (alist-get 'state task)))
                     (string-replace
                      "\n" " "
                      (or (alist-get 'title task) (alist-get 'prompt task)
                          ""))
                     "  " (cmacs-clawtilla-dim (or (alist-get 'id task) "")))
           :body (lambda ()
                   (dolist (line (cmacs-clawtilla-tasks--task-detail task raw))
                     (insert "        " (cmacs-clawtilla-dim line) "\n")))))
        (setq index (1+ index))))))

(defun cmacs-clawtilla-tasks--at-point ()
  "Return the task at point, or signal."
  (or (cmacs-clawtilla-value-at-point 'task)
      (user-error "No task at point")))

(defun cmacs-clawtilla-tasks--reload ()
  "Reload whichever buffer a task verb was run from."
  (cond ((derived-mode-p 'cmacs-clawtilla-page-mode)
         (cmacs-clawtilla-page-load (current-buffer)))
        ((derived-mode-p 'cmacs-clawtilla-section-mode)
         (cmacs-clawtilla-section--load (current-buffer)))))

(defun cmacs-clawtilla-tasks--send (kind payload &optional said)
  "Send KIND with PAYLOAD, say SAID (a string or a function of the reply), reload."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind payload
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (when-let* ((text (if (functionp said) (funcall said data) said)))
           (message "clawtilla: %s" text))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (cmacs-clawtilla-tasks--reload))))))))

(defun cmacs-clawtilla-tasks-create (prompt &optional title agent after repo)
  "Create a task: PROMPT, optionally TITLE, for AGENT, after AFTER, in REPO.

Write PROMPT so it stands alone: the agent reads this and nothing else
about why it is wanted.  With no AGENT it goes on the backlog, to be
assigned when you know who.  AFTER is task ids it waits for; REPO is an
absolute path on the daemon's machine, for a checkout of the task's own."
  (interactive
   (list (read-string "The task (say it so it stands alone): ")
         (read-string "Title (optional): ")
         (cmacs-clawtilla-read-agent "Who does it (empty: the backlog): "
                                     nil t)
         (read-string "Wait for (task ids, optional): ")
         (read-string "Repository (absolute host path, optional): ")))
  (when (string-empty-p (string-trim prompt))
    (user-error "Say what the task is first"))
  (cmacs-clawtilla-tasks--send
   "task.create"
   (cmacs-clawtilla-payload :prompt (string-trim prompt) :title title
                            :agent agent :after after :repo repo)
   (if agent (format "handed to %s" agent)
     "on the backlog -- assign it when you know who")))

(defun cmacs-clawtilla-tasks-assign (task agent)
  "Hand TASK to AGENT.  The work goes to them now, from you, with its id."
  (interactive
   (let ((id (cmacs-clawtilla-tasks--id)))
     (list id (cmacs-clawtilla-read-agent (format "Hand %s to: " id)))))
  (cmacs-clawtilla-tasks--send
   "task.assign" (list (cons 'task task) (cons 'agent agent))
   (format "handed to %s" agent)))

(defun cmacs-clawtilla-tasks-cancel (task)
  "Cancel TASK."
  (interactive (list (cmacs-clawtilla-tasks--id)))
  (when (yes-or-no-p (format "Cancel task %s? " task))
    (cmacs-clawtilla-tasks--send "task.cancel" (list (cons 'task task))
                                 "cancelled")))

(defun cmacs-clawtilla-tasks-retry ()
  "Run the task at point again, or the broken run at point.

A task goes back to its assignee; a routine's broken run runs the
routine again.  Which happened is the daemon's to say."
  (interactive)
  (let* ((section (cmacs-clawtilla-section-at-point))
         (value (plist-get section :value))
         (payload (pcase (plist-get section :type)
                    ('incident (list (cons 'incident (alist-get 'id value))))
                    ('task (list (cons 'task (alist-get 'id value))))
                    (_ (if (cmacs-clawtilla-page-arg)
                           (list (cons 'task (cmacs-clawtilla-page-arg)))
                         (user-error "No task or broken run at point"))))))
    (cmacs-clawtilla-tasks--send
     "task.retry" payload
     (lambda (data)
       (if (eq t (cmacs-clawtilla-get data 'rerun))
           "running the routine again"
         "queued for its assignee again")))))

(defun cmacs-clawtilla-tasks-open-thread ()
  "Open the conversation the task at point is being worked in."
  (interactive)
  (let ((room (or (alist-get 'thread_room (cmacs-clawtilla-tasks--at-point))
                  (user-error "That task has no conversation of its own"))))
    (cmacs-clawtilla-chat (cmacs-clawtilla-current) nil room)))

(defun cmacs-clawtilla-tasks-configure-incidents ()
  "Change whether broken runs are reported, and who hears about them.

Who can hear is libclawt's list (the \"incident-recipient\" family)."
  (interactive)
  (let* ((what (completing-read "Change: " '("who hears about them"
                                             "whether they are reported")
                                nil t))
         (payload
          (if (equal what "whether they are reported")
              (list (cons 'enabled
                          (if (y-or-n-p "Report broken runs? ") t :false)))
            (let* ((choices (mapcar (lambda (entry)
                                      (cons (alist-get 'label entry)
                                            (alist-get 'nick entry)))
                                    (cmacs-clawtilla-enum "incident-recipient")))
                   (pick (completing-read "Who hears about them: " choices
                                          nil t)))
              (list (cons 'to (cdr (assoc pick choices))))))))
    (cmacs-clawtilla-tasks--send "incident.configure" payload "saved")))


;;;; One task.

(defun cmacs-clawtilla-tasks--id ()
  "Return the id of the task this buffer or point is about."
  (or (and (derived-mode-p 'cmacs-clawtilla-page-mode)
           (cmacs-clawtilla-page-arg))
      (alist-get 'id (cmacs-clawtilla-tasks--at-point))))

(defun cmacs-clawtilla-tasks--draw-task ()
  "Draw the page for one task."
  (let* ((task (cmacs-clawtilla-page-data 'task 'task))
         (notes (cmacs-clawtilla-page-data 'task 'notes))
         (journal (cmacs-clawtilla-page-data 'task 'journal))
         (venture (cmacs-clawtilla-page-data 'task 'venture))
         (checkout (alist-get 'checkout task))
         (state (alist-get 'state task))
         (after (alist-get 'after task)))
    (if (null task)
        (cmacs-clawtilla-page-insert-note "There is no such task")
      (insert "  " (cmacs-clawtilla-tasks--badge state) "  "
              (propertize (or (alist-get 'title task) "") 'face 'bold)
              "\n  " (cmacs-clawtilla-dim (cmacs-clawtilla-tasks--who task))
              "\n\n")
      (dolist (line (split-string (or (alist-get 'prompt task) "") "\n"))
        (insert "    " line "\n"))
      (when (alist-get 'result task)
        (insert "\n  " (propertize
                        (format "Result · %s"
                                (cmacs-clawtilla-tasks--stamp
                                 (alist-get 'finished_at task)))
                        'face 'cmacs-clawtilla-team)
                "\n")
        (dolist (line (split-string (alist-get 'result task) "\n"))
          (insert "    " line "\n")))

      ;; What was said about it.
      (insert "\n  " (propertize "The thread" 'face 'cmacs-clawtilla-team)
              "  " (cmacs-clawtilla-dim "c comments") "\n")
      (if (null notes)
          (insert "    " (cmacs-clawtilla-dim "Nothing said about it yet.")
                  "\n")
        (dolist (note notes)
          (cmacs-clawtilla-page-insert-row
           'task-note note
           (format "%s (%s) · %s" (or (alist-get 'author note) "clawtilla")
                   (or (alist-get 'kind note) "note")
                   (cmacs-clawtilla-tasks--stamp (alist-get 'at note)))
           (alist-get 'body note))))

      ;; What it waits for.  Only a task on the backlog, or one already
      ;; blocked, can be made to wait.
      (insert "\n  " (propertize "Waits for" 'face 'cmacs-clawtilla-team)
              (if (cmacs-clawtilla-tasks--can-wait-p state)
                  (concat "  " (cmacs-clawtilla-dim
                                "u adds a task to wait for, U drops one"))
                "")
              "\n")
      (if (null after)
          (insert "    " (cmacs-clawtilla-dim
                          (if (cmacs-clawtilla-tasks--can-wait-p state)
                              "Nothing."
                            "Nothing.  Only a task on the backlog can be made to wait."))
                  "\n")
        (dolist (blocker after)
          (cmacs-clawtilla-insert-section
           :type 'task-blocker :value blocker :level 2 :heading blocker)))

      ;; Its checkout.
      (when checkout
        (let ((present (eq t (alist-get 'present checkout))))
          (insert "\n  " (propertize "Changes" 'face 'cmacs-clawtilla-team)
                  "  " (cmacs-clawtilla-dim
                        (if present "d shows them, X removes the checkout"
                          "d shows them"))
                  "\n    "
                  (format "Branch %s of %s, from %s."
                          (or (alist-get 'branch checkout) "")
                          (or (alist-get 'repo checkout) "")
                          (truncate-string-to-width
                           (or (alist-get 'base checkout) "") 12))
                  "\n    "
                  (cmacs-clawtilla-dim
                   (if present (or (alist-get 'path checkout) "")
                     "The checkout was removed; the branch is kept."))
                  "\n")))

      ;; Its VENTURE ticket.
      (when venture
        (let ((vstate (or (alist-get 'state venture) ""))
              (reason (alist-get 'reason venture)))
          (insert "\n  " (propertize "VENTURE" 'face 'cmacs-clawtilla-team)
                  "  " (cmacs-clawtilla-dim
                        (concat (if (alist-get 'url venture) "o opens the ticket" "")
                                (if (cmacs-clawtilla-tasks--venture-stuck-p vstate)
                                    "  V sends it again" "")))
                  "\n    "
                  (cmacs-clawtilla-tasks--venture-line venture vstate reason)
                  "\n")))

      ;; Its review.
      (when (alist-get 'reviewer task)
        (insert "\n  " (propertize "Review" 'face 'cmacs-clawtilla-team)
                (if (equal state "review")
                    (concat "  " (cmacs-clawtilla-dim "v gives your verdict"))
                  "")
                "\n    "
                (format "Reviewed by %s%s"
                        (if (equal (alist-get 'reviewer task) "user")
                            "you" (alist-get 'reviewer task))
                        (if (> (or (alist-get 'review_round task) 0) 0)
                            "; changes asked for before" ""))
                "\n"))

      ;; Its history.
      (insert "\n  " (propertize "History" 'face 'cmacs-clawtilla-team) "\n")
      (dolist (entry journal)
        (cmacs-clawtilla-page-insert-row
         'task-journal entry
         (format "%s · %s" (or (alist-get 'state entry) "?")
                 (cmacs-clawtilla-tasks--stamp (alist-get 'at entry)))
         (alist-get 'what entry))))))

(defun cmacs-clawtilla-tasks--can-wait-p (state)
  "Return non-nil if a task in STATE can be made to wait for another.

Only a task nobody has yet, or one that is already blocked -- the two
states the GTK client offers the field for.  The daemon is the judge;
this only decides which hint is drawn."
  (member state '("unassigned" "blocked")))

(defun cmacs-clawtilla-tasks--venture-stuck-p (vstate)
  "Return non-nil if the VENTURE mirror in VSTATE can be sent again.

One that gave up, or that was never mirrored."
  (member vstate '("dead" "skipped")))

(defun cmacs-clawtilla-tasks--venture-line (venture vstate reason)
  "Return what to say about VENTURE, the mirror in VSTATE for REASON."
  (pcase vstate
    ("synced" (format "Ticket #%s, kept current as the task moves."
                      (or (alist-get 'ticket venture) 0)))
    ("queued" (format "Waiting to be sent%s%s"
                      (if reason ": " ".") (or reason "")))
    ("skipped" (format "Not mirrored: %s" (or reason "no reason given")))
    (_ (format "The mirror gave up: %s" (or reason "no reason given")))))

(defun cmacs-clawtilla-tasks-comment (text)
  "Say TEXT about this task.

Kept on the task.  While it is with its assignee they hear it too, in
the conversation the work is in."
  (interactive "sComment: ")
  (when (string-empty-p (string-trim text)) (user-error "Nothing to say"))
  (cmacs-clawtilla-tasks--send
   "task.comment"
   (list (cons 'task (cmacs-clawtilla-tasks--id))
         (cons 'text (string-trim text)))
   (lambda (data)
     (if (eq t (cmacs-clawtilla-get data 'delivered))
         "noted, and the assignee has it"
       "noted on the task"))))

(defun cmacs-clawtilla-tasks-diff ()
  "Show what this task's checkout has changed."
  (interactive)
  (let ((id (cmacs-clawtilla-tasks--id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "task.diff" (list (cons 'task id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let ((text (concat
                      (or (cmacs-clawtilla-get data 'diff) "")
                      (mapconcat (lambda (path)
                                   (format "new, not yet added: %s\n" path))
                                 (cmacs-clawtilla-get data 'untracked) ""))))
           (when (string-empty-p text) (setq text "No changes yet.\n"))
           (when (eq t (cmacs-clawtilla-get data 'truncated))
             (setq text (concat text "\n(cut short: read the rest in the "
                                "checkout)\n")))
           (cmacs-clawtilla-page-show-text
            (format "*clawtilla changes: %s*" id) text 'diff-mode)))))))

(defun cmacs-clawtilla-tasks-remove-checkout ()
  "Remove this task's checkout.  Its branch is kept."
  (interactive)
  (let ((id (cmacs-clawtilla-tasks--id)))
    (when (yes-or-no-p (format "Remove the checkout of %s?  Its branch is kept. "
                               id))
      (cmacs-clawtilla-tasks--send "task.checkout_remove"
                                   (list (cons 'task id))
                                   "checkout removed; its branch is kept"))))

(defun cmacs-clawtilla-tasks-review (verdict notes)
  "Give VERDICT on this task's result, with NOTES.

VERDICT is \"accept\" or \"changes\"; asking for changes needs NOTES
saying what to change.  What then happens is the daemon's to say."
  (interactive
   (let* ((verdict (if (y-or-n-p "Accept the result? ") "accept" "changes"))
          (notes (read-string (if (equal verdict "changes")
                                  "What to change: "
                                "Notes (optional): "))))
     (list verdict notes)))
  (when (and (equal verdict "changes") (string-empty-p (string-trim notes)))
    (user-error "Say what to change first"))
  (cmacs-clawtilla-tasks--send
   "task.review"
   (cmacs-clawtilla-payload :task (cmacs-clawtilla-tasks--id)
                            :verdict verdict :notes (string-trim notes))
   (lambda (data) (or (cmacs-clawtilla-get data 'said) "done"))))

(defun cmacs-clawtilla-tasks-link (blocker)
  "Make this task wait for the task BLOCKER."
  (interactive "sWait for (task id): ")
  (when (string-empty-p blocker) (user-error "Which task?"))
  (cmacs-clawtilla-tasks--send
   "task.link" (list (cons 'task (cmacs-clawtilla-tasks--id))
                     (cons 'after blocker))
   "it waits for that task now"))

(defun cmacs-clawtilla-tasks-unlink (blocker)
  "Stop this task waiting for BLOCKER: the one at point, or one asked for."
  (interactive
   (list (or (cmacs-clawtilla-value-at-point 'task-blocker)
             (completing-read "No longer wait for: "
                              (cmacs-clawtilla-page-data 'task 'task 'after)
                              nil t))))
  (cmacs-clawtilla-tasks--send
   "task.unlink" (list (cons 'task (cmacs-clawtilla-tasks--id))
                       (cons 'after blocker))
   "no longer waits for it"))

(defun cmacs-clawtilla-tasks-venture-retry ()
  "Send this task to VENTURE again."
  (interactive)
  (cmacs-clawtilla-tasks--send
   "task.venture_retry" (list (cons 'task (cmacs-clawtilla-tasks--id)))
   "sending to VENTURE again"))

(defun cmacs-clawtilla-tasks-open ()
  "Open what belongs to this task: its ticket, else its conversation."
  (interactive)
  (let ((url (cmacs-clawtilla-page-data 'task 'venture 'url))
        (room (cmacs-clawtilla-page-data 'task 'task 'thread_room)))
    (cond (url (browse-url url))
          (room (cmacs-clawtilla-chat (cmacs-clawtilla-current) nil room))
          (t (user-error "This task has no ticket and no conversation")))))

(cmacs-clawtilla-define-page "task"
  :title "Task"
  :fetch (list (list 'task "task.show"
                     (lambda ()
                       (list (cons 'task (cmacs-clawtilla-page-arg))
                             (cons 'journal t)))))
  :draw #'cmacs-clawtilla-tasks--draw-task
  :events "\\`task\\."
  :verbs '(("c" "comment" cmacs-clawtilla-tasks-comment)
           ("a" "assign" cmacs-clawtilla-tasks-assign)
           ("r" "retry" cmacs-clawtilla-tasks-retry)
           ("D" "cancel" cmacs-clawtilla-tasks-cancel)
           ("u" "wait for a task" cmacs-clawtilla-tasks-link)
           ("U" "stop waiting for one" cmacs-clawtilla-tasks-unlink)
           ("d" "show changes" cmacs-clawtilla-tasks-diff)
           ("X" "remove the checkout" cmacs-clawtilla-tasks-remove-checkout)
           ("v" "review verdict" cmacs-clawtilla-tasks-review)
           ("o" "open its ticket or conversation" cmacs-clawtilla-tasks-open)
           ("V" "send to VENTURE again" cmacs-clawtilla-tasks-venture-retry)))

;;;###autoload
(defun cmacs-clawtilla-task (id &optional conn)
  "Open the page for the task ID on CONN."
  (interactive "sTask id: ")
  (cmacs-clawtilla-page-open "task" (or conn (cmacs-clawtilla-current))
                             nil nil id))


;;;; Projects.

(defconst cmacs-clawtilla-projects-fields
  '(("name"                . "Name")
    ("goal"                . "Goal (every assignment in it starts with this)")
    ("directory"           . "Directory (absolute host path)")
    ("review_by"           . "Reviewed by")
    ("agents"              . "Agents who work in it (comma-separated; empty for all)")
    ("monthly_budget_usd"  . "Monthly budget in dollars (0 for none)")
    ("budget_warn_percent" . "Warn at this percent of the budget")
    ("budget_hard_stop"    . "Refuse new work once the budget is spent"))
  "The fields of a project `project.set' takes, and what each is asked as.

The daemon's keys, in the order the GTK client offers them.")

(defun cmacs-clawtilla-projects--field-text (project key)
  "Return PROJECT's value for KEY as the text it would be edited as."
  (let ((value (alist-get (intern key) project)))
    (cond ((null value) "")
          ((eq value t) "true")
          ((stringp value) value)
          ((numberp value) (format "%g" value))
          ((listp value) (mapconcat (lambda (item) (format "%s" item))
                                    value ", "))
          (t ""))))

(defun cmacs-clawtilla-projects--draw ()
  "Draw the Projects page."
  (let ((projects (cmacs-clawtilla-page-data 'projects 'projects)))
    (if (null projects)
        (cmacs-clawtilla-page-insert-note
         "No projects yet"
         "A fleet works without them.  A project tells each piece of work what it is for, and keeps a monthly budget on it.  i makes one.")
      (dolist (project projects)
        (let ((budget (or (alist-get 'monthly_budget_usd project) 0))
              (spent (or (alist-get 'month_spend_usd project) 0)))
          (cmacs-clawtilla-page-insert-row
           'project project
           (concat (propertize (or (alist-get 'name project)
                                   (alist-get 'id project) "?")
                               'face 'cmacs-clawtilla-agent)
                   "  " (cmacs-clawtilla-dim (or (alist-get 'id project) ""))
                   (if (eq t (alist-get 'stopped project))
                       (concat "  " (propertize "stopped"
                                                'face 'cmacs-clawtilla-error))
                     ""))
           (if (> budget 0)
               (format "$%.2f of $%.2f this month%s" spent budget
                       (if (eq t (alist-get 'stopped project))
                           " -- stopped" ""))
             (format "$%.2f this month, no budget" spent))
           (or (alist-get 'goal project) "no goal written")
           (let ((directory (alist-get 'directory project)))
             (and (stringp directory) (not (string-empty-p directory))
                  directory))))))))

(defun cmacs-clawtilla-projects-create (id)
  "Create the project ID.

An id in lowercase with hyphens.  Tasks name their project by it and it
cannot be changed afterwards."
  (interactive "sNew project id (lowercase, hyphens; it cannot be changed): ")
  (when (string-empty-p id) (user-error "A project needs an id"))
  (cmacs-clawtilla-page-send
   "project.create" (list (cons 'project id))
   "project created; give it a goal and a directory so work finds its way to it"))

(defun cmacs-clawtilla-projects--read-value (key label current)
  "Read a new value for the project field KEY, asked as LABEL, now CURRENT."
  (cond
   ((equal key "budget_hard_stop")
    (if (y-or-n-p (format "%s? " label)) "true" "false"))
   ((equal key "review_by")
    ;; libclawt's choices, worded for a project, plus any agent by id.
    (let* ((choices (mapcar (lambda (entry)
                              (cons (alist-get 'project-label entry)
                                    (alist-get 'nick entry)))
                            (cmacs-clawtilla-enum "review-by")))
           (agents (delq nil
                         (mapcar (lambda (agent) (alist-get 'id agent))
                                 (cmacs-clawtilla-connection-agents
                                  (cmacs-clawtilla-current)))))
           (pick (completing-read (format "%s (now %s): " label
                                          (if (string-empty-p current)
                                              "unset" current))
                                  (append (mapcar #'car choices) agents))))
      (or (cdr (assoc pick choices)) pick)))
   (t (read-string (format "%s: " label) current))))

(defun cmacs-clawtilla-projects-set ()
  "Change one field of the project at point."
  (interactive)
  (let* ((project (cmacs-clawtilla-page-row 'project))
         (labels (mapcar (lambda (field) (cons (cdr field) (car field)))
                         cmacs-clawtilla-projects-fields))
         (pick (completing-read "Change: " labels nil t))
         (key (cdr (assoc pick labels)))
         (value (cmacs-clawtilla-projects--read-value
                 key pick (cmacs-clawtilla-projects--field-text project key))))
    (cmacs-clawtilla-page-send
     "project.set"
     ;; Every value as text, which is what the daemon parses each field
     ;; from -- an empty one included: it is how a field is cleared.
     (list (cons 'project (alist-get 'id project))
           (cons 'key key) (cons 'value value))
     "saved")))

(defun cmacs-clawtilla-projects-remove ()
  "Remove the project at point.

Its tasks keep its name in their history; new work can no longer be put
in it, and its budget stops being enforced."
  (interactive)
  (let ((id (alist-get 'id (cmacs-clawtilla-page-row 'project))))
    (when (yes-or-no-p
           (format "Remove the project %s?  Its tasks keep its name, and its budget stops being enforced. "
                   id))
      (cmacs-clawtilla-page-send "project.remove" (list (cons 'project id))
                                 "project removed; its tasks keep its name"))))

(cmacs-clawtilla-define-page "projects"
  :title "Projects"
  :intro "What the work is for.  A task belongs to the project its delegation names, its parent's, or the one whose directory its repository is.  Its assignee is told the goal, and the project's month of spend is kept against its budget."
  :fetch '((projects "project.list"))
  :draw #'cmacs-clawtilla-projects--draw
  :events "\\`\\(project\\|spending\\)\\."
  :verbs '(("i" "new project" cmacs-clawtilla-projects-create)
           ("RET" "change a field" cmacs-clawtilla-projects-set)
           ("D" "remove" cmacs-clawtilla-projects-remove)))

;;;###autoload
(defun cmacs-clawtilla-projects (&optional conn)
  "Show the fleet's projects and their budgets on CONN."
  (interactive)
  (cmacs-clawtilla-page-open "projects" conn))

(provide 'cmacs-clawtilla-tasks)

;;; cmacs-clawtilla-tasks.el ends here
