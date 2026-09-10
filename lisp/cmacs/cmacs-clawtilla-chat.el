;;; cmacs-clawtilla-chat.el --- A clawtilla transcript -*- lexical-binding: t; -*-

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

;; One conversation, in the shape ement.el gave Emacs for this: a
;; read-only transcript that appends, and composing as a separate act.
;;
;; What is drawn is decided by the library wherever there is a decision
;; to make -- where a run starts, when a day divider belongs, how a
;; timestamp reads, how a group of tool calls summarises -- because
;; those answers already exist and a third opinion about them is how
;; three clients stop looking like one product.
;;
;; Two behaviours are worth naming because they are easy to get subtly
;; wrong and nobody reports them as bugs, they just stop using the
;; thing:
;;
;; A refresh APPENDS.  Redrawing the whole transcript on every event
;; loses the selection, the scroll position and any collapsed tool run,
;; and does it most often exactly when the agent is busiest.
;;
;; Following the live edge is conditional on already being at it.  A
;; transcript that scrolls to the bottom while you are reading further
;; up is one you cannot read during a turn -- which is the only time
;; anybody is watching it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-alerts)

(declare-function cmacs-clawtilla--run-is-start "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--time-label "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--step-summary "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--steps "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--step-precedes "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--unread-should-count
                  "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla-fleet "cmacs-clawtilla-fleet")
(declare-function cmacs-clawtilla-agent "cmacs-clawtilla-agent")

(defcustom cmacs-clawtilla-chat-follow t
  "Whether the transcript follows new messages to the bottom.

Only when point is already at the bottom.  Scrolling somebody down
while they are reading further up makes a transcript unreadable during
a turn, which is the only time anybody watches one."
  :type 'boolean
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-chat-sender-width 12
  "Columns reserved for a sender's name."
  :type 'integer
  :group 'cmacs-clawtilla)

(defvar-local cmacs-clawtilla-chat--room nil)
(defvar-local cmacs-clawtilla-chat--agent nil)
(defvar-local cmacs-clawtilla-chat--seen nil
  "Ids of the messages already drawn, so a refresh appends.")
(defvar-local cmacs-clawtilla-chat--last-sender nil)
(defvar-local cmacs-clawtilla-chat--last-day nil)
(defvar-local cmacs-clawtilla-chat--steps nil)
(defvar-local cmacs-clawtilla-chat--steps-start nil
  "Where the live activity line begins, or nil.")

(defface cmacs-clawtilla-chat-self
  '((t :inherit font-lock-string-face))
  "Face for the operator's own name in a transcript."
  :group 'cmacs-clawtilla)


;;;; Drawing.

(defun cmacs-clawtilla-chat--at-end-p ()
  "Return non-nil if point is at the live edge."
  (>= (point) (- (point-max) 1)))

(defmacro cmacs-clawtilla-chat--appending (&rest body)
  "Append with BODY, following the live edge only if already there."
  (declare (indent 0) (debug t))
  `(let ((inhibit-read-only t)
         (follow (and cmacs-clawtilla-chat-follow
                      (cmacs-clawtilla-chat--at-end-p)))
         (windows (get-buffer-window-list (current-buffer) nil t)))
     (save-excursion
       (goto-char (point-max))
       ,@body)
     (when follow
       (goto-char (point-max))
       (dolist (window windows)
         (with-selected-window window
           (goto-char (point-max))
           (recenter -1))))))

(defun cmacs-clawtilla-chat--seal (start end)
  "Make the region from START to END read-only.

`front-sticky' as well as `rear-nonsticky': without the first, text can
be inserted at the very START of a protected run, which is not
protection, it is protection that fails in the one place somebody would
notice."
  (add-text-properties start end
                       '(read-only t front-sticky (read-only)
                                   rear-nonsticky (read-only))))

(defun cmacs-clawtilla-chat--day (ts)
  "Return the day key for TS."
  (format-time-string "%F" (seconds-to-time ts)))

(defun cmacs-clawtilla-chat--insert-message (message)
  "Insert MESSAGE at point."
  (let* ((sender (or (alist-get 'sender message) "?"))
         (body (or (alist-get 'body message) ""))
         (ts (or (alist-get 'ts message) 0))
         (day (cmacs-clawtilla-chat--day ts))
         (boundary (cmacs-clawtilla--parse
                    (cmacs-clawtilla--run-is-start
                     cmacs-clawtilla-chat--last-sender
                     cmacs-clawtilla-chat--last-day sender day)))
         (start-run (eq t (alist-get 'start boundary)))
         (new-day (eq t (alist-get 'new-day boundary)))
         (start (point)))
    ;; The divider, and whether there should be one, are both the
    ;; library's answer.  A client that decided for itself would draw
    ;; one on every message or lose it entirely.
    (when new-day
      (insert "\n"
              (cmacs-clawtilla-dim
               (format "── %s ──"
                       (or (cmacs-clawtilla--time-label ts t) day)))
              "\n"))
    (when start-run
      (insert (propertize
               (truncate-string-to-width
                sender cmacs-clawtilla-chat-sender-width nil ?\s)
               'face (if (equal sender "user")
                         'cmacs-clawtilla-chat-self
                       'cmacs-clawtilla-agent))
              " "
              (cmacs-clawtilla-dim (or (cmacs-clawtilla--time-label ts) ""))
              "\n"))
    (dolist (line (split-string (cmacs-clawtilla-render-markdown body) "\n"))
      (insert "    " line "\n"))
    (put-text-property start (point) 'cmacs-clawtilla-section
                       (list :type 'message :value message
                             :identity (format "message/%s"
                                               (alist-get 'id message))
                             :level 0 :foldable nil))
    (cmacs-clawtilla-chat--seal start (point))
    (setq cmacs-clawtilla-chat--last-sender sender)
    (setq cmacs-clawtilla-chat--last-day day)))

(defun cmacs-clawtilla-chat--append-messages (messages)
  "Append any of MESSAGES not already drawn."
  (cmacs-clawtilla-chat--appending
    ;; The activity line lives at the very end, so it is taken down
    ;; before messages are added and put back after: a turn's steps
    ;; belong under the transcript, not buried in the middle of it.
    (cmacs-clawtilla-chat--clear-activity)
    (dolist (message messages)
      (let ((id (alist-get 'id message)))
        (unless (member id cmacs-clawtilla-chat--seen)
          (push id cmacs-clawtilla-chat--seen)
          (cmacs-clawtilla-chat--insert-message message))))
    (cmacs-clawtilla-chat--draw-activity)))

(defun cmacs-clawtilla-chat--clear-activity ()
  "Remove the live activity line, if there is one."
  (when (and cmacs-clawtilla-chat--steps-start
             (<= cmacs-clawtilla-chat--steps-start (point-max)))
    (let ((inhibit-read-only t))
      (delete-region cmacs-clawtilla-chat--steps-start (point-max)))
    (setq cmacs-clawtilla-chat--steps-start nil)))

(defun cmacs-clawtilla-chat--newest-ts ()
  "Return the timestamp of the newest message drawn, or 0."
  (let ((newest 0))
    (save-excursion
      (goto-char (point-max))
      (let ((limit 0))
        (while (and (> (point) (point-min)) (< limit 200))
          (let ((section (cmacs-clawtilla-section-at-point)))
            (when (and section (eq (plist-get section :type) 'message))
              (setq newest (max newest
                                (or (alist-get 'ts (plist-get section :value))
                                    0)))))
          (forward-line -1)
          (setq limit (1+ limit)))))
    newest))

(defun cmacs-clawtilla-chat--draw-activity ()
  "Draw what the agent is doing right now, under the transcript."
  (when cmacs-clawtilla-chat--steps
    (setq cmacs-clawtilla-chat--steps-start (point-max))
    (goto-char (point-max))
    (let* ((newest (cmacs-clawtilla-chat--newest-ts))
           ;; Steps that predate the last message have already been
           ;; overtaken by it: they belong in the history above rather
           ;; than in the live line below, which is how a finished
           ;; turn's steps stop piling up under the transcript.
           (live (seq-remove
                  (lambda (step)
                    (and (> newest 0)
                         (cmacs-clawtilla--step-precedes
                          (json-serialize step) newest
                          cmacs-clawtilla-chat--agent)))
                  cmacs-clawtilla-chat--steps))
           (json (json-serialize (vconcat live)))
           (summary (and live
                         (cmacs-clawtilla--step-summary
                          json cmacs-clawtilla-chat--agent))))
      (when summary
        (insert "\n" (cmacs-clawtilla-dim (concat "· " summary)) "\n")))))


;;;; Loading.

(defun cmacs-clawtilla-chat--load (&optional buffer)
  "Fetch history and steps for BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (room (buffer-local-value 'cmacs-clawtilla-chat--room buffer)))
    (cmacs-clawtilla-request
     conn "room.history" (list (cons 'room room) (cons 'as "user"))
     (lambda (data err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             ;; The resolved room, not the id asked for: an agent id
             ;; resolves to its direct room, and every later frame has
             ;; to name the same thing the daemon named back.
             (setq cmacs-clawtilla-chat--room
                   (or (cmacs-clawtilla-get data 'room) room))
             (cmacs-clawtilla-chat--append-messages
              (cmacs-clawtilla-get data 'messages)))))))
    (cmacs-clawtilla-request
     conn "room.steps" (list (cons 'room room) (cons 'as "user")
                             (cons 'live t))
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-chat--steps
                 (cmacs-clawtilla-get data 'steps))
           (cmacs-clawtilla-chat--appending
             (cmacs-clawtilla-chat--clear-activity)
             (cmacs-clawtilla-chat--draw-activity))))))))


;;;; Sending.

(defun cmacs-clawtilla-chat--send (body)
  "Send BODY to this conversation."
  (let ((conn (cmacs-clawtilla-current))
        (target (or cmacs-clawtilla-chat--agent cmacs-clawtilla-chat--room))
        (buffer (current-buffer)))
    (cmacs-clawtilla-request
     conn "msg.send"
     (list (cons 'target target) (cons 'body body) (cons 'from "user"))
     (lambda (data err)
       (cond
        (err (message "clawtilla: %s" err))
        ;; A stopped agent accepts mail -- that is what the mailbox is
        ;; for -- but nothing will read it until it starts, and a client
        ;; that cannot say so shows a spinner that never resolves.
        ((equal (cmacs-clawtilla-get data 'target_state) "stopped")
         (message "clawtilla: held in %s's mailbox until it starts" target))
        ((eq t (cmacs-clawtilla-get data 'steered))
         (message "clawtilla: steered into the running turn")))
       (when (buffer-live-p buffer)
         (cmacs-clawtilla-chat--load buffer))))))

(defun cmacs-clawtilla-chat-send (message)
  "Send MESSAGE, or run it if it is a slash command."
  (interactive (list (read-string "Message: ")))
  (setq message (string-trim message))
  (unless (string-empty-p message)
    (if (string-prefix-p "/" message)
        (cmacs-clawtilla-chat--slash message)
      (cmacs-clawtilla-chat--send message))))

(defun cmacs-clawtilla-chat-compose ()
  "Compose a multi-line message in its own buffer."
  (interactive)
  (let ((parent (current-buffer))
        (buffer (get-buffer-create "*clawtilla compose*")))
    (with-current-buffer buffer
      (erase-buffer)
      (text-mode)
      (setq-local header-line-format
                  "C-c C-c to send, C-c C-k to abandon")
      (setq-local cmacs-clawtilla-chat--parent parent)
      (local-set-key (kbd "C-c C-c") #'cmacs-clawtilla-chat-compose-send)
      (local-set-key (kbd "C-c C-k") #'kill-buffer-and-window))
    (cmacs-clawtilla-display buffer)))

(defvar-local cmacs-clawtilla-chat--parent nil)

(defun cmacs-clawtilla-chat-compose-send ()
  "Send what is in the compose buffer."
  (interactive)
  (let ((body (string-trim (buffer-string)))
        (parent cmacs-clawtilla-chat--parent))
    (when (buffer-live-p parent)
      (with-current-buffer parent
        (cmacs-clawtilla-chat--send body)))
    (kill-buffer-and-window)))


;;;; Slash commands.

(defconst cmacs-clawtilla-chat-slash-commands
  '(("/agents"    . "list the fleet")
    ("/attach"    . "send a file")
    ("/clear"     . "clear this transcript")
    ("/compose"   . "write a longer message")
    ("/copy"      . "copy the last reply")
    ("/edit"      . "open a file of this agent's")
    ("/export"    . "save this conversation")
    ("/files"     . "browse this agent's files")
    ("/flow"      . "what the agents said to each other")
    ("/help"      . "this list")
    ("/interrupt" . "stop the running turn")
    ("/memory"    . "search what is remembered")
    ("/new"       . "start a fresh conversation")
    ("/recall"    . "recall a past conversation")
    ("/reset"     . "reset this agent's session")
    ("/restart"   . "restart this agent")
    ("/retry"     . "send the last message again")
    ("/start"     . "start this agent")
    ("/stop"      . "stop this agent")
    ("/tasks"     . "what has been delegated"))
  "Every slash command, with what it does.

The same twenty the GTK client answers.  clawtilla's `make parity'
compares the literal set each client contains, so one added there and
not here fails the build rather than going unnoticed until somebody
reaches for the half that was not built.")

(defun cmacs-clawtilla-chat--slash (input)
  "Run INPUT, a slash command."
  (pcase-let* ((`(,command . ,rest)
                (let ((space (string-search " " input)))
                  (if space
                      (cons (substring input 0 space)
                            (string-trim (substring input space)))
                    (cons input "")))))
    (pcase command
      ("/help" (cmacs-clawtilla-chat-help))
      ("/agents" (cmacs-clawtilla-fleet (cmacs-clawtilla-current)))
      ("/compose" (cmacs-clawtilla-chat-compose))
      ("/clear" (cmacs-clawtilla-chat-clear))
      ("/copy" (cmacs-clawtilla-chat-copy-last))
      ("/export" (cmacs-clawtilla-chat-export))
      ("/interrupt" (cmacs-clawtilla-chat--agent-frame "agent.interrupt"))
      ("/start" (cmacs-clawtilla-chat--agent-frame "agent.start"))
      ("/stop" (cmacs-clawtilla-chat--agent-frame "agent.stop"))
      ("/restart" (cmacs-clawtilla-chat--agent-frame "agent.restart"))
      ("/reset" (cmacs-clawtilla-chat--agent-frame "agent.reset"))
      ("/new" (cmacs-clawtilla-chat-new))
      ("/retry" (cmacs-clawtilla-chat-retry))
      ("/attach" (call-interactively #'cmacs-clawtilla-chat-attach))
      ("/files" (cmacs-clawtilla-chat-files))
      ("/edit" (cmacs-clawtilla-chat-edit rest))
      ("/memory" (cmacs-clawtilla-chat-memory rest))
      ("/recall" (cmacs-clawtilla-chat-recall rest))
      ("/flow" (cmacs-clawtilla-chat-flow))
      ("/tasks" (cmacs-clawtilla-chat-tasks))
      (_ (message "clawtilla: no such command %s; /help lists them"
                  command)))))

(defun cmacs-clawtilla-chat-help ()
  "Show every slash command."
  (interactive)
  (with-current-buffer (get-buffer-create "*clawtilla help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dolist (entry cmacs-clawtilla-chat-slash-commands)
        (insert (propertize (format "%-12s" (car entry))
                            'face 'cmacs-clawtilla-heading)
                (cdr entry) "\n"))
      (goto-char (point-min))
      (special-mode))
    (cmacs-clawtilla-display (current-buffer))))

(defun cmacs-clawtilla-chat--agent-frame (kind)
  "Send KIND for this conversation's agent."
  (let ((agent cmacs-clawtilla-chat--agent))
    (unless agent
      (user-error "This is a room, not one agent"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind (list (cons 'agent agent))
     (lambda (_data err)
       (message "clawtilla: %s" (or err (format "%s %s" agent kind)))))))

(defun cmacs-clawtilla-chat-clear ()
  "Clear what is on screen, leaving the record alone.

Only the buffer.  What was said is the daemon's and is still there; a
client that could delete it from here would be one keystroke from
losing a conversation."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq cmacs-clawtilla-chat--seen nil)
    (setq cmacs-clawtilla-chat--last-sender nil)
    (setq cmacs-clawtilla-chat--last-day nil)
    (setq cmacs-clawtilla-chat--steps-start nil)))

(defun cmacs-clawtilla-chat-copy-last ()
  "Copy the last message's body."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (let ((section nil))
      (while (and (not section) (> (point) (point-min)))
        (setq section (cmacs-clawtilla-section-at-point))
        (unless section (forward-line -1)))
      (if section
          (let ((body (alist-get 'body (plist-get section :value))))
            (kill-new body)
            (message "clawtilla: copied"))
        (user-error "Nothing to copy")))))

(defun cmacs-clawtilla-chat-export ()
  "Save this conversation to a file."
  (interactive)
  (let ((file (read-file-name "Export to: " nil nil nil
                              (format "%s.org" cmacs-clawtilla-chat--room))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "room.history"
     (list (cons 'room cmacs-clawtilla-chat--room) (cons 'as "user"))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-temp-file file
           (insert (format "#+title: %s\n\n" cmacs-clawtilla-chat--room))
           (dolist (message (cmacs-clawtilla-get data 'messages))
             (insert (format "* %s  %s\n%s\n\n"
                             (alist-get 'sender message)
                             (or (cmacs-clawtilla--time-label
                                  (or (alist-get 'ts message) 0)) "")
                             (alist-get 'body message)))))
         (message "clawtilla: exported to %s" file))))))

(defun cmacs-clawtilla-chat-new ()
  "Start a fresh conversation with this agent."
  (interactive)
  (cmacs-clawtilla-chat--agent-frame "agent.reset")
  (cmacs-clawtilla-chat-clear)
  (cmacs-clawtilla-chat--load))

(defun cmacs-clawtilla-chat-retry ()
  "Send the operator's last message again."
  (interactive)
  (let ((last nil))
    (save-excursion
      (goto-char (point-max))
      (while (and (not last) (> (point) (point-min)))
        (let ((section (cmacs-clawtilla-section-at-point)))
          (when (and section
                     (equal (alist-get 'sender (plist-get section :value))
                            "user"))
            (setq last (alist-get 'body (plist-get section :value)))))
        (forward-line -1)))
    (if last
        (cmacs-clawtilla-chat--send last)
      (user-error "Nothing of yours to send again"))))

(defun cmacs-clawtilla-chat-attach (file)
  "Send FILE to this conversation."
  (interactive "fSend file: ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "attachment.put"
   (list (cons 'agent (or cmacs-clawtilla-chat--agent ""))
         (cons 'room cmacs-clawtilla-chat--room)
         (cons 'name (file-name-nondirectory file))
         (cons 'data (base64-encode-string
                      (with-temp-buffer
                        (set-buffer-multibyte nil)
                        (insert-file-contents-literally file)
                        (buffer-string))
                      t)))
   (lambda (_data err)
     (message "clawtilla: %s" (or err (format "sent %s"
                                              (file-name-nondirectory
                                               file)))))))

(defun cmacs-clawtilla-chat-files ()
  "Browse this agent's files."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.files"
   (list (cons 'agent cmacs-clawtilla-chat--agent))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (with-current-buffer (get-buffer-create "*clawtilla files*")
         (let ((inhibit-read-only t))
           (erase-buffer)
           (dolist (file (cmacs-clawtilla-get data 'files))
             (insert (format "%s\n" (or (alist-get 'path file) file))))
           (goto-char (point-min))
           (special-mode))
         (cmacs-clawtilla-display (current-buffer)))))))

(defun cmacs-clawtilla-chat-edit (path)
  "Open PATH, one of this agent's files, in a buffer."
  (interactive "sFile: ")
  (let ((agent cmacs-clawtilla-chat--agent)
        (conn (cmacs-clawtilla-current)))
    (cmacs-clawtilla-request
     conn "agent.file_read" (list (cons 'agent agent) (cons 'name path))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let ((buffer (get-buffer-create
                        (format "*clawtilla:%s:%s*" agent path))))
           (with-current-buffer buffer
             (erase-buffer)
             (insert (or (cmacs-clawtilla-get data 'content) ""))
             (goto-char (point-min))
             (setq-local cmacs-clawtilla-connection conn)
             (setq-local cmacs-clawtilla-chat--agent agent))
           (cmacs-clawtilla-display buffer)))))))

(defun cmacs-clawtilla-chat-memory (query)
  "Search what this fleet remembers for QUERY."
  (interactive "sRecall what? ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "memory.search"
   (list (cons 'query query) (cons 'agent cmacs-clawtilla-chat--agent))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla memory*" (cmacs-clawtilla-get data 'memories)
        ;; Each memory says which store it came out of.  A listing that
        ;; mixed an agent's own conclusion with something the whole
        ;; fleet believes would turn two different claims into one row.
        (lambda (row) (format "%-6s %s"
                              (or (alist-get 'scope row) "")
                              (or (alist-get 'summary row)
                                  (alist-get 'content row) ""))))))))

(defun cmacs-clawtilla-chat-recall (query)
  "Find a past conversation matching QUERY."
  (interactive "sRecall which conversation? ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "memory.recall"
   ;; Recall searches the TRANSCRIPT rather than the memories, and is
   ;; not room-filtered: a person can open any transcript already.
   (list (cons 'query query) (cons 'agent cmacs-clawtilla-chat--agent))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla recall*" (cmacs-clawtilla-get data 'hits)
        (lambda (row) (format "%-14s %-12s %s"
                              (or (alist-get 'room row) "")
                              (or (alist-get 'from_name row)
                                  (alist-get 'from row) "")
                              (or (alist-get 'body row) ""))))))))

(defun cmacs-clawtilla-chat-flow ()
  "Show what the agents said to each other."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "room.history"
   (list (cons 'room "flow") (cons 'as "user"))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla flow*" (cmacs-clawtilla-get data 'messages)
        (lambda (row) (format "%-12s %s" (alist-get 'sender row)
                              (alist-get 'body row))))))))

(defun cmacs-clawtilla-chat-tasks ()
  "Show what has been delegated."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "task.list" nil
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla tasks*" (cmacs-clawtilla-get data 'tasks)
        (lambda (row) (format "%-10s %-10s %s"
                              (or (alist-get 'assignee row) "?")
                              (or (alist-get 'state row) "?")
                              (or (alist-get 'title row) ""))))))))

(defun cmacs-clawtilla-chat--show-list (name rows format-row)
  "Show ROWS in NAME, each through FORMAT-ROW."
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (if (null rows)
          (insert (cmacs-clawtilla-dim "nothing to show") "\n")
        (dolist (row rows)
          (insert (funcall format-row row) "\n")))
      (goto-char (point-min))
      (special-mode))
    (cmacs-clawtilla-display (current-buffer))))


;;;; Attachments already sent, and rooms.

(defun cmacs-clawtilla-chat-attachment-get ()
  "Fetch the attachment at point and open it."
  (interactive)
  (let* ((message (cmacs-clawtilla-value-at-point 'message))
         (id (and message (or (alist-get 'attachment message)
                              (alist-get 'attachment_id message)))))
    (unless id (user-error "No attachment on the message at point"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "attachment.get" (list (cons 'id id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((name (or (cmacs-clawtilla-get data 'name) id))
                (encoded (cmacs-clawtilla-get data 'base64))
                (file (expand-file-name name temporary-file-directory)))
           (when encoded
             (let ((coding-system-for-write 'binary))
               (with-temp-file file
                 (set-buffer-multibyte nil)
                 (insert (base64-decode-string encoded))))
             (find-file file))))))))

(defun cmacs-clawtilla-chat-attachment-remove ()
  "Remove the attachment at point."
  (interactive)
  (let* ((message (cmacs-clawtilla-value-at-point 'message))
         (id (and message (or (alist-get 'attachment message)
                              (alist-get 'attachment_id message)))))
    (unless id (user-error "No attachment on the message at point"))
    (when (yes-or-no-p "Remove that attachment? ")
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "attachment.remove"
       ;; Named by agent and file name, not by id: this deletes from an
       ;; agent's drop-box, and it answers with the host path it
       ;; unlinked.
       (list (cons 'agent (or cmacs-clawtilla-chat--agent ""))
             (cons 'name id))
       (lambda (data e)
         (message "clawtilla: %s"
                  (or e (cmacs-clawtilla-get data 'removed) "removed")))))))

(defun cmacs-clawtilla-chat-room-create (room name members)
  "Make a room called NAME with id ROOM holding MEMBERS.

Creating it writes the config entry AND makes the room, because writing
the config is not creating it: a room that lived only in the running
daemon was one somebody made, used, restarted, and could not find --
with its transcript still on disk and nothing that would reopen it."
  (interactive (list (read-string "Room id: ")
                     (read-string "Name: ")
                     (read-string "Members (comma separated): ")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "room.create"
   (list (cons 'room room) (cons 'name name) (cons 'members members))
   (lambda (_d e) (message "clawtilla: %s" (or e (format "made %s" room))))))

(defun cmacs-clawtilla-chat-room-set ()
  "Change this room.

A `members' list REPLACES the membership rather than adding to it, so
it is how somebody is taken out of a room as well as put in -- and
membership is permission, so it is worth knowing which one you are
doing."
  (interactive)
  (let* ((field (completing-read "Change: "
                                 '("name" "members" "require_mention") nil t))
         (value (read-string
                 (if (equal field "members")
                     "Members (this REPLACES the list): "
                   (format "%s: " field)))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "room.set"
     (list (cons 'room cmacs-clawtilla-chat--room) (cons field value))
     (lambda (_d e) (message "clawtilla: %s" (or e "changed"))))))

;;;; The mode.

(transient-define-prefix cmacs-clawtilla-chat-menu ()
  "What this conversation can do."
  ["Say"
   [("i" "send a message" cmacs-clawtilla-chat-send)
    ("c" "compose" cmacs-clawtilla-chat-compose)
    ("a" "attach a file" cmacs-clawtilla-chat-attach)]
   [("r" "send the last again" cmacs-clawtilla-chat-retry)
    ("w" "copy the last" cmacs-clawtilla-chat-copy-last)
    ("x" "export" cmacs-clawtilla-chat-export)]]
  ["Agent"
   [("s" "start" (lambda () (interactive)
                   (cmacs-clawtilla-chat--agent-frame "agent.start")))
    ("S" "stop" (lambda () (interactive)
                  (cmacs-clawtilla-chat--agent-frame "agent.stop")))]
   [("k" "interrupt" (lambda () (interactive)
                       (cmacs-clawtilla-chat--agent-frame "agent.interrupt")))
    ("n" "fresh conversation" cmacs-clawtilla-chat-new)]]
  ["Look at"
   [("f" "files" cmacs-clawtilla-chat-files)
    ("m" "memory" cmacs-clawtilla-chat-memory)]
   [("t" "tasks" cmacs-clawtilla-chat-tasks)
    ("F" "flow" cmacs-clawtilla-chat-flow)]]
  ["Attachments and rooms"
   [("g" "open the attachment" cmacs-clawtilla-chat-attachment-get)
    ("D" "remove it" cmacs-clawtilla-chat-attachment-remove)]
   [("N" "make a room" cmacs-clawtilla-chat-room-create)
    ("E" "change this room" cmacs-clawtilla-chat-room-set)]])

(defvar cmacs-clawtilla-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-chat-send)
    (define-key map (kbd "i") #'cmacs-clawtilla-chat-send)
    (define-key map (kbd "c") #'cmacs-clawtilla-chat-compose)
    (define-key map (kbd "a") #'cmacs-clawtilla-chat-attach)
    (define-key map (kbd "r") #'cmacs-clawtilla-chat-retry)
    (define-key map (kbd "w") #'cmacs-clawtilla-chat-copy-last)
    (define-key map (kbd "x") #'cmacs-clawtilla-chat-export)
    (define-key map (kbd "?") #'cmacs-clawtilla-chat-menu)
    map)
  "Keymap for `cmacs-clawtilla-chat-mode'.")

(define-derived-mode cmacs-clawtilla-chat-mode special-mode "Clawtilla-Chat"
  "Major mode for one clawtilla conversation."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-chat--load (current-buffer))))
  (setq-local cmacs-clawtilla-chat--seen nil)
  (visual-line-mode 1))

;;;###autoload
(defun cmacs-clawtilla-chat (conn &optional agent room)
  "Open the conversation with AGENT, or ROOM, on CONN."
  (interactive (list (cmacs-clawtilla-current) nil nil))
  (let* ((agent-id (cond ((stringp agent) agent)
                         ((consp agent) (alist-get 'id agent))))
         (room-id (cond ((stringp room) room)
                        ((consp room) (alist-get 'id room))
                        (t agent-id)))
         (buffer (get-buffer-create
                  (format "*clawtilla: %s*" (or agent-id room-id)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-chat-mode)
        (cmacs-clawtilla-chat-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-chat--agent agent-id)
      (setq-local cmacs-clawtilla-chat--room room-id)
      (cmacs-clawtilla-chat--load buffer))
    ;; Opening it is reading it, and saying so is what stops the count
    ;; being raised again while it is in front of you.
    (setq cmacs-clawtilla--viewing-room room-id)
    (cmacs-clawtilla-mark-read room-id)
    (cmacs-clawtilla-display buffer)))

(defun cmacs-clawtilla-chat--on-event (conn kind data)
  "Append to any transcript for CONN that KIND in DATA concerns."
  (when (string-match-p (rx bos (or "message" "turn.")) kind)
    (let ((subject (cmacs-clawtilla-event-subject data)))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'cmacs-clawtilla-chat-mode)
                     (eq cmacs-clawtilla-connection conn)
                     ;; Only the transcript this concerns.  Reloading
                     ;; every open one meant a message in one room
                     ;; refetched the history of all of them, which is a
                     ;; request per buffer per message and gets worse the
                     ;; more conversations somebody keeps open.
                     (or (null subject)
                         (equal subject cmacs-clawtilla-chat--room)
                         (equal subject cmacs-clawtilla-chat--agent)))
            (cmacs-clawtilla-chat--load buffer)))))))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-chat--on-event)


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-chat-mode-map 'cmacs-clawtilla-chat-mode)

(provide 'cmacs-clawtilla-chat)

;;; cmacs-clawtilla-chat.el ends here
