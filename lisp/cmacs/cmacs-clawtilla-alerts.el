;;; cmacs-clawtilla-alerts.el --- Alerts and unread -*- lexical-binding: t; -*-

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

;; The bell: what wants somebody, and the unread counts beside each
;; conversation.
;;
;; Since clawtilla 0.52 neither is this client's to keep.  The daemon
;; holds the notification list (`notice.list': conversations with
;; something unread, decisions waiting, Grok jobs needing attention, and
;; alerts) and the read marks (`room.read'), so a count cleared here is
;; cleared in the GTK client and on the phone, and a client that has
;; just connected shows the number everybody else does.  What this file
;; does is ask, draw, and send the verbs.
;;
;; The rules that remain on the client are still the library's and none
;; is restated here:
;;
;; - the number on the bell is `clawt_notice_list_badge';
;; - which agents are muted is `clawt_notice_list_mutes', and a total
;;   leaves their conversations out through `clawt_unread_total' -- the
;;   row keeps its count, dimmed, because a mute takes away the
;;   interruption and not the information;
;; - the daemon's counts come in through `clawt_unread_seed', which also
;;   knows the conversation on screen is never counted;
;; - between listings a message raises a count by
;;   `clawt_unread_should_count' -- not your own room, not your own
;;   message, not older than the connection;
;; - an alert that lands while you are looking at the alerts buffer has
;;   been seen as it arrived, which is `clawt_alert_arrives_read': the
;;   list is marked read at once rather than left counting a row the
;;   operator watched appear.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(declare-function cmacs-clawtilla--alert-arrives-read
                  "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--unread-should-count
                  "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla-chat "cmacs-clawtilla-chat")
(declare-function cmacs-clawtilla-section "cmacs-clawtilla-section")
(declare-function cmacs-clawtilla-grok-remove-job "cmacs-clawtilla-grok")

(defcustom cmacs-clawtilla-mode-line-bell t
  "Whether the bell's count is shown in the mode line of clawtilla buffers.

The count is the daemon's, through `clawt_notice_list_badge': unread
conversations, decisions waiting, Grok jobs needing attention and
unread alerts, already less the muted agents'."
  :type 'boolean
  :group 'cmacs-clawtilla)

(defvar cmacs-clawtilla-unread (make-hash-table :test 'equal)
  "Unread counts, keyed by room id.

Seeded from the daemon's own (`cmacs-clawtilla-unread-seed') and moved
between listings by `room.read' and by the unread rule.")

(defvar cmacs-clawtilla--viewing-room nil
  "The room whose transcript is in front of the operator, if any.")

(defvar-local cmacs-clawtilla-alerts--agent nil
  "The agent this alerts buffer is narrowed to, or nil for the fleet.")

(defvar-local cmacs-clawtilla-alerts--history nil
  "The daemon's event log as last loaded into this buffer, newest first.")

(defvar-local cmacs-clawtilla-chat--room nil)

(defvar cmacs-clawtilla-unread-changed-hook nil
  "Functions called with no arguments when an unread count or a mute moved.

The fleet buffer redraws on it: a pill is drawn from the table, and a
muted agent's is drawn dimmed.")


;;;; Unread counts.

(defvar cmacs-clawtilla-known-rooms-function nil
  "Function returning the rooms this client has a row for.

The unread rule needs it: an event about a room with no row cannot
raise a count on it, because there is nothing there to show one.")

(defun cmacs-clawtilla-known-rooms (&optional conn)
  "Return the rooms this client has a row for on CONN."
  (if cmacs-clawtilla-known-rooms-function
      (funcall cmacs-clawtilla-known-rooms-function)
    (delete-dups
     (delq nil
           (append
            ;; Every agent the fleet buffer lists has its conversation
            ;; with you, and every listed room has a row of its own.
            (and conn
                 (mapcar (lambda (agent) (alist-get 'dm_room agent))
                         (cmacs-clawtilla-connection-agents conn)))
            (and conn
                 (mapcar (lambda (room) (alist-get 'id room))
                         (cmacs-clawtilla-connection-rooms conn)))
            ;; And every transcript that is open: a room somebody is
            ;; looking at is one they can see a count on.
            (mapcar (lambda (buffer)
                      (buffer-local-value 'cmacs-clawtilla-chat--room buffer))
                    (seq-filter
                     (lambda (buffer)
                       (with-current-buffer buffer
                         (derived-mode-p 'cmacs-clawtilla-chat-mode)))
                     (buffer-list))))))))

(defun cmacs-clawtilla-viewing-room ()
  "Return the room in front of the operator, or nil.

The selected window's, when it shows a transcript; otherwise the one
last opened, so a caller that set `cmacs-clawtilla--viewing-room' by
hand is still believed."
  (let ((buffer (window-buffer (selected-window))))
    (or (and (buffer-live-p buffer)
             (with-current-buffer buffer
               (and (derived-mode-p 'cmacs-clawtilla-chat-mode)
                    cmacs-clawtilla-chat--room)))
        cmacs-clawtilla--viewing-room)))

(defun cmacs-clawtilla-unread-count (room)
  "Return ROOM's unread count."
  (gethash room cmacs-clawtilla-unread 0))

(defun cmacs-clawtilla-unread-seed (conn rooms-json)
  "Take the daemon's unread counts from ROOMS-JSON into the table.

ROOMS-JSON is a `room.list' reply's `rooms', as the text the daemon
sent.  The taking is `clawt_unread_seed': each listed room this client
draws a row for gets the daemon's number, and the room on screen gets 0
whatever the daemon says.  A daemon too old to hold read marks sends no
counts; nothing is changed then and the client goes on counting from
events as it always did.  Returns non-nil if the daemon supplied counts."
  (let ((answer (cmacs-clawtilla-ask
                 "unread-seed"
                 :rooms (cons :json rooms-json)
                 :rows (vconcat (cmacs-clawtilla-known-rooms conn))
                 :viewing (cmacs-clawtilla-viewing-room))))
    ;; Tested on the text, not on its parse: an empty object is a real
    ;; answer -- nothing unread anywhere -- and parses to nil.
    (when answer
      (clrhash cmacs-clawtilla-unread)
      (dolist (pair (cmacs-clawtilla--parse answer))
        (when (and (numberp (cdr pair)) (> (cdr pair) 0))
          (puthash (symbol-name (car pair)) (cdr pair)
                   cmacs-clawtilla-unread)))
      (run-hooks 'cmacs-clawtilla-unread-changed-hook)
      t)))

(defun cmacs-clawtilla-unread-total (&optional conn)
  "Return every unread count added up, less the muted agents' conversations.

`clawt_unread_total': a mute takes a conversation out of every total a
client draws, and leaves its own row's count alone."
  (let ((counts nil))
    (maphash (lambda (room count)
               (push (cons (intern room) count) counts))
             cmacs-clawtilla-unread)
    (string-to-number
     (or (cmacs-clawtilla-ask
          "unread-total"
          :unread (cons :json (if counts (json-serialize counts) "{}"))
          :muted (vconcat (and conn (cmacs-clawtilla-connection-muted conn))))
         "0"))))

(defun cmacs-clawtilla-agent-muted-p (conn agent)
  "Return non-nil if AGENT's notifications are muted on CONN."
  (and conn agent
       (member agent (cmacs-clawtilla-connection-muted conn))
       t))

(defun cmacs-clawtilla--notice-verb (conn kind payload)
  "Send the notice or read verb KIND with PAYLOAD on CONN, and forget it.

Fire and forget, as the GTK client's is: the daemon answers with
`notice.changed' or `room.read' to every client, this one included, and
the redraw is that event's.  A daemon too old to know the verb answers
an error nobody needs to see."
  (when (and conn (cmacs-clawtilla--connected-p
                   (cmacs-clawtilla-connection-handle conn)))
    (cmacs-clawtilla-request conn kind payload #'ignore)))

(defun cmacs-clawtilla-mark-read (room &optional conn upto)
  "Mark ROOM read, for every client.

The count is the daemon's now, so clearing it here alone would light up
again on the next listing and every other client would go on showing
it: `room.read' is sent on CONN as well.  UPTO is the id of the last
message on screen, so a reply that lands between a history load and
this request still counts; nil means the newest."
  (remhash room cmacs-clawtilla-unread)
  (run-hooks 'cmacs-clawtilla-unread-changed-hook)
  (when-let* ((conn (or conn (car cmacs-clawtilla-connections))))
    (cmacs-clawtilla--notice-verb
     conn "room.read"
     (append (list (cons 'room room))
             (and upto (list (cons 'upto upto)))))))

(defun cmacs-clawtilla-mark-all-read (&optional conn)
  "Mark every conversation and every alert on CONN read."
  (interactive)
  (let ((conn (or conn (cmacs-clawtilla-current))))
    (clrhash cmacs-clawtilla-unread)
    (run-hooks 'cmacs-clawtilla-unread-changed-hook)
    ;; {"all": true}, which notice.read and room.read both take.
    (cmacs-clawtilla--notice-verb conn "notice.read" '((all . t)))
    (cmacs-clawtilla--notice-verb conn "room.read" '((all . t)))))

(defun cmacs-clawtilla-set-agent-muted (conn agent muted)
  "Mute AGENT's notifications on CONN, or unmute them if MUTED is nil.

A mute is the daemon's, like the list it silences: it holds for every
client until it is undone."
  (cmacs-clawtilla--notice-verb
   conn (if muted "notice.mute" "notice.unmute")
   (list (cons 'agent agent))))

(defun cmacs-clawtilla-alerts--apply-room-read (room unread)
  "Take the daemon's count UNREAD for ROOM after somebody read it.

Somebody: this client, another one, or the CLI.  The count is 0 unless
the mark was set short of the newest message, and the room on screen is
never counted whatever the daemon says."
  (when room
    (if (or (not (numberp unread)) (<= unread 0)
            (equal room (cmacs-clawtilla-viewing-room)))
        (remhash room cmacs-clawtilla-unread)
      (puthash room unread cmacs-clawtilla-unread))
    (run-hooks 'cmacs-clawtilla-unread-changed-hook)))

(defun cmacs-clawtilla-alerts--count-unread (conn kind data ts)
  "Raise an unread count for CONN if KIND in DATA at TS earns one."
  (when (member kind '("message" "message.sent"))
    ;; The room is `subject' and the sender lives in `detail'.  Reading
    ;; `room' and `sender' -- which is what this did -- found nothing
    ;; and quietly counted nothing.
    (let* ((room (cmacs-clawtilla-event-subject data))
           (from (cmacs-clawtilla-event-detail data 'from))
           (connected-at (or (cmacs-clawtilla-connection-connected-at conn)
                             0)))
      (when (and room
                 (cmacs-clawtilla--unread-should-count
                  room (cmacs-clawtilla-viewing-room) from ts connected-at
                  (json-serialize
                   (vconcat (cmacs-clawtilla-known-rooms conn)))))
        (puthash room (1+ (gethash room cmacs-clawtilla-unread 0))
                 cmacs-clawtilla-unread)
        (run-hooks 'cmacs-clawtilla-unread-changed-hook)))))


;;;; The daemon's list.

(defun cmacs-clawtilla-alerts--surface-showing-p ()
  "Return non-nil if an alerts buffer is on screen."
  (seq-some (lambda (window)
              (with-current-buffer (window-buffer window)
                (derived-mode-p 'cmacs-clawtilla-alerts-mode)))
            (window-list)))

(defun cmacs-clawtilla-notice-badge (&optional conn)
  "Return the number on CONN's bell, from the daemon's own counts.

`clawt_notice_list_badge', so every client shows the same number.  0
before the first list has arrived."
  (let ((conn (or conn (car cmacs-clawtilla-connections))))
    (if (and conn (cmacs-clawtilla-connection-notices-json conn))
        (string-to-number
         (or (cmacs-clawtilla-ask
              "notice-badge"
              :reply (cons :json (cmacs-clawtilla-connection-notices-json
                                  conn)))
             "0"))
      0)))

(defun cmacs-clawtilla-alerts--take (conn data text)
  "Adopt the `notice.list' reply DATA, with its TEXT, as CONN's list."
  (setf (cmacs-clawtilla-connection-notices conn) data)
  (setf (cmacs-clawtilla-connection-notices-json conn) text)
  ;; The muted set drives the fleet buffer: a muted agent's count is
  ;; drawn dimmed and leaves every total.  Announced only when the set
  ;; moved, because every message lands here.
  (let ((muted (sort (copy-sequence
                      (cmacs-clawtilla-ask-parsed
                       "notice-mutes" :reply (cons :json text)))
                     #'string<)))
    (unless (equal muted (cmacs-clawtilla-connection-muted conn))
      (setf (cmacs-clawtilla-connection-muted conn) muted)
      (run-hooks 'cmacs-clawtilla-unread-changed-hook)))
  ;; An alert that lands in front of somebody has been seen as it
  ;; arrived, so it is read at once: otherwise the bell counts a row the
  ;; operator watched appear until they close the buffer and open it
  ;; again.  The rule is the library's; "notice" stands for any tier the
  ;; list carries, since the daemon lists none it would skip.
  (when (and (> (or (alist-get 'unread data) 0) 0)
             (cmacs-clawtilla--alert-arrives-read
              (cmacs-clawtilla-alerts--surface-showing-p) "notice"))
    (cmacs-clawtilla--notice-verb conn "notice.read" '((all . t))))
  (cmacs-clawtilla-alerts--redraw)
  (force-mode-line-update t))

(defvar cmacs-clawtilla-alerts--pending nil
  "Connections with a coalesced `notice.list' waiting.")

(defun cmacs-clawtilla-notices-refresh (conn)
  "Ask CONN's daemon for its notification list again, soon.

Gathered over a short window because a reply that lands with ten
messages behind it would otherwise be ten round trips for one redraw.
Unscoped, always: the bell counts the whole fleet whatever a buffer is
narrowed to, and the narrowing is applied when drawing."
  (unless (memq conn cmacs-clawtilla-alerts--pending)
    (push conn cmacs-clawtilla-alerts--pending)
    (run-at-time
     0.25 nil
     (lambda ()
       (setq cmacs-clawtilla-alerts--pending
             (delq conn cmacs-clawtilla-alerts--pending))
       (when (and (memq conn cmacs-clawtilla-connections)
                  (cmacs-clawtilla--connected-p
                   (cmacs-clawtilla-connection-handle conn)))
         (cmacs-clawtilla-request-both
          conn "notice.list" nil
          (lambda (data text err)
            ;; A daemon that keeps no notifications answers an error;
            ;; there is then simply no list, and nothing to say about it.
            (unless err
              (cmacs-clawtilla-alerts--take conn data text)))))))))

(defun cmacs-clawtilla-alerts--on-event (conn kind data)
  "Keep CONN's list and counts current for the event KIND carrying DATA.

Nothing is recorded here: the list is the daemon's, so it is asked for
again when anything it counts may have moved -- the list itself, a
conversation read or written to, a decision, a Grok job."
  (when (or (member kind '("notice.changed" "room.read" "message"
                           "grok.job_updated"))
            (string-prefix-p "decision." kind))
    (cmacs-clawtilla-notices-refresh conn))
  (cond
   ;; A conversation was read -- here, in another client, or from the
   ;; CLI.  Its count takes the daemon's number, so reading in one
   ;; window clears it in every window.
   ((equal kind "room.read")
    (cmacs-clawtilla-alerts--apply-room-read
     (cmacs-clawtilla-event-subject data)
     (cmacs-clawtilla-event-detail data 'unread)))
   ;; A task tree out of messages is said aloud as well as listed: its
   ;; agents have just gone quiet, and the list alone would leave
   ;; somebody watching them wondering why.  Worded by libclawt.
   ((equal kind "task.tree_budget")
    (when-let* ((line (cmacs-clawtilla-ask
                       "tree-alert"
                       :tree (cmacs-clawtilla-event-detail data 'tree)
                       :count (or (cmacs-clawtilla-event-detail data 'count) 0)
                       :limit (or (cmacs-clawtilla-event-detail data 'limit)
                                  0))))
      (message "clawtilla: %s" line)))
   (t
    (cmacs-clawtilla-alerts--count-unread
     conn kind data (cmacs-clawtilla-event-seconds data)))))

(defun cmacs-clawtilla-alerts--on-connect (conn)
  "Ask CONN for its list and its unread counts once its link is up."
  (cmacs-clawtilla-notices-refresh conn)
  (cmacs-clawtilla-request-raw
   conn "room.list" nil
   (lambda (json err)
     (unless err
       (let ((payload (cmacs-clawtilla-payload-text json)))
         (setf (cmacs-clawtilla-connection-rooms conn)
               (cmacs-clawtilla-get (cmacs-clawtilla--parse payload) 'rooms))
         (cmacs-clawtilla-unread-seed
          conn (cmacs-clawtilla-member-json payload 'rooms)))))))

(add-hook 'cmacs-clawtilla-connect-hook #'cmacs-clawtilla-alerts--on-connect)


;;;; Drawing.

(defun cmacs-clawtilla-alerts--in-scope-p (agent)
  "Return non-nil if a row about AGENT belongs in this buffer."
  (or (null cmacs-clawtilla-alerts--agent)
      (equal cmacs-clawtilla-alerts--agent agent)))

(defun cmacs-clawtilla-alerts--tier-face (tier)
  "Return the face for TIER."
  (pcase tier
    ("error" 'cmacs-clawtilla-error)
    ("notice" 'cmacs-clawtilla-busy)
    (_ 'cmacs-clawtilla-dim)))

(defun cmacs-clawtilla-alerts--insert-group (title rows)
  "Insert the section TITLE holding ROWS, each (TYPE VALUE HEADING DETAIL)."
  (when rows
    (insert "\n" (propertize (format "%s (%d)" title (length rows))
                             'face 'cmacs-clawtilla-heading)
            "\n")
    (dolist (row rows)
      (pcase-let ((`(,type ,value ,heading ,detail) row))
        (cmacs-clawtilla-insert-section
         :type type :value value :level 1 :heading heading
         :body (lambda ()
                 (when (and detail (not (string-empty-p detail)))
                   (insert "      " (cmacs-clawtilla-dim detail) "\n"))))))))

(defun cmacs-clawtilla-alerts--chat-rows (data)
  "Return the Chats rows of the list DATA: conversations with unread."
  (delq nil
        (mapcar
         (lambda (chat)
           (let ((agent (alist-get 'agent chat))
                 (room (alist-get 'room chat)))
             (when (and room (cmacs-clawtilla-alerts--in-scope-p agent))
               (list 'notice-chat chat
                     (concat (propertize (or agent (alist-get 'name chat) room)
                                         'face 'cmacs-clawtilla-agent)
                             " · "
                             (propertize
                              (format "%d unread" (or (alist-get 'unread chat)
                                                      0))
                              'face 'cmacs-clawtilla-unread))
                     nil))))
         (alist-get 'chats data))))

(defun cmacs-clawtilla-alerts--decision-rows (data)
  "Return the Decisions rows of the list DATA."
  (delq nil
        (mapcar
         (lambda (decision)
           (let ((agent (alist-get 'agent decision)))
             (when (cmacs-clawtilla-alerts--in-scope-p agent)
               (list 'notice-decision decision
                     (or (alist-get 'question decision) "") agent))))
         (alist-get 'decisions data))))

(defun cmacs-clawtilla-alerts--grok-rows (data)
  "Return the Grok rows of the list DATA: jobs that need somebody."
  (delq nil
        (mapcar
         (lambda (job)
           (let ((agent (alist-get 'agent job)))
             (when (cmacs-clawtilla-alerts--in-scope-p agent)
               (list 'notice-grok job
                     (format "%s · %s" (or (alist-get 'bot job) "?")
                             (or (alist-get 'state job) "?"))
                     (or (alist-get 'note job) agent)))))
         (alist-get 'grok data))))

(defun cmacs-clawtilla-alerts--alert-rows (data)
  "Return the Alerts rows of the list DATA."
  (delq nil
        (mapcar
         (lambda (notice)
           (let ((agent (alist-get 'agent notice))
                 (tier (or (alist-get 'tier notice) "notice")))
             (when (cmacs-clawtilla-alerts--in-scope-p agent)
               (list 'notice
                     ;; `id' as a string, so the row keeps its place
                     ;; across a redraw: the identity is built from it.
                     (cons (cons 'name (format "%s" (alist-get 'id notice)))
                           notice)
                     (concat
                      ;; Unread is marked, and read is `read: false' in
                      ;; the reply -- which parses to nil, like absent.
                      ;; The daemon always sends the member, so absent
                      ;; cannot be mistaken for unread here.
                      (if (eq t (alist-get 'read notice))
                          "  " (propertize "• " 'face 'cmacs-clawtilla-unread))
                      (propertize (or (alist-get 'title notice) "")
                                  'face (cmacs-clawtilla-alerts--tier-face
                                         tier)))
                     ;; Relative time and the source, so a row says where
                     ;; to go and look without a second step.
                     (concat (if agent (concat agent " · ") "")
                             (or (cmacs-clawtilla-time-ago
                                  (alist-get 'created_at notice))
                                 "")
                             " · " (or (alist-get 'source notice) ""))))))
         (alist-get 'notices data))))

(defun cmacs-clawtilla-alerts--draw ()
  "Redraw the alerts buffer from its connection's list."
  (cmacs-clawtilla-ui-preserving
    (let* ((conn cmacs-clawtilla-connection)
           (data (and conn (cmacs-clawtilla-connection-notices conn)))
           (chats (cmacs-clawtilla-alerts--chat-rows data))
           (decisions (cmacs-clawtilla-alerts--decision-rows data))
           (grok (cmacs-clawtilla-alerts--grok-rows data))
           (alerts (cmacs-clawtilla-alerts--alert-rows data))
           (badge (and conn (cmacs-clawtilla-notice-badge conn))))
      (insert (propertize "Notifications" 'face 'cmacs-clawtilla-heading)
              (if (and badge (> badge 0))
                  (concat "  " (propertize (format "%d" badge)
                                           'face 'cmacs-clawtilla-unread))
                "")
              (if cmacs-clawtilla-alerts--agent
                  (concat "  " (cmacs-clawtilla-dim
                                (format "only %s -- `a' shows the fleet"
                                        cmacs-clawtilla-alerts--agent)))
                "")
              "\n")
      (when-let* ((muted (and conn (cmacs-clawtilla-connection-muted conn))))
        (insert (cmacs-clawtilla-dim
                 (format "muted: %s" (string-join muted ", ")))
                "\n"))
      (cond
       ((null data)
        (insert "\n  " (cmacs-clawtilla-dim "asking the daemon…") "\n"))
       ((not (or chats decisions grok alerts))
        (insert "\n  " (propertize "Nothing needs you" 'face 'bold) "\n  "
                (cmacs-clawtilla-dim
                 "Unread conversations, decisions waiting, Grok jobs and alerts appear here.")
                "\n"))
       (t
        (cmacs-clawtilla-alerts--insert-group "Chats" chats)
        (cmacs-clawtilla-alerts--insert-group "Decisions waiting" decisions)
        (cmacs-clawtilla-alerts--insert-group
         "Grok jobs needing attention" grok)
        (cmacs-clawtilla-alerts--insert-group "Alerts" alerts)))
      (when cmacs-clawtilla-alerts--history
        (insert "\n" (propertize "Event log" 'face 'cmacs-clawtilla-heading)
                "\n")
        (dolist (event cmacs-clawtilla-alerts--history)
          (insert "  " (cmacs-clawtilla-dim
                        (format "%s · %s" (or (alist-get 'kind event) "?")
                                (or (alist-get 'subject event) "the fleet")))
                  "\n"))))))

(defun cmacs-clawtilla-alerts--redraw ()
  "Redraw every alerts buffer."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'cmacs-clawtilla-alerts-mode)
        (cmacs-clawtilla-alerts--draw)))))

(defun cmacs-clawtilla-alerts-mode-line ()
  "Return the bell for the mode line: the daemon's count, or nothing."
  (let ((count (and cmacs-clawtilla-mode-line-bell
                    cmacs-clawtilla-connection
                    (cmacs-clawtilla-notice-badge
                     cmacs-clawtilla-connection))))
    (if (and count (> count 0))
        (propertize (format " [%d]" count) 'face 'cmacs-clawtilla-unread
                    'help-echo "clawtilla: things that want you")
      "")))


;;;; Acting.

(defun cmacs-clawtilla-alerts--section ()
  "Return the notification row at point as (TYPE . VALUE), or signal."
  (let ((section (cmacs-clawtilla-section-at-point)))
    (unless (and section
                 (memq (plist-get section :type)
                       '(notice notice-chat notice-decision notice-grok)))
      (user-error "No notification at point"))
    (cons (plist-get section :type) (plist-get section :value))))

(defun cmacs-clawtilla-alerts-visit ()
  "Go where the row at point leads.

A conversation opens; a decision opens the Decisions page, where it is
answered; a Grok job opens the Grok page; an alert about an agent opens
that agent's conversation."
  (interactive)
  (pcase-let ((`(,type . ,value) (cmacs-clawtilla-alerts--section))
              (conn (cmacs-clawtilla-current)))
    (pcase type
      ('notice-chat
       (if (alist-get 'agent value)
           (cmacs-clawtilla-chat conn (alist-get 'agent value))
         (cmacs-clawtilla-chat conn nil (alist-get 'room value))))
      ('notice-decision
       (cmacs-clawtilla-section conn "work")
       (message "clawtilla: decisions are on the Work section's Decisions page"))
      ('notice-grok
       (cmacs-clawtilla-section conn "work")
       (message "clawtilla: Grok jobs are on the Work section's Grok page"))
      ('notice
       (cmacs-clawtilla--notice-verb
        conn "notice.read" (list (cons 'id (alist-get 'id value))))
       (if (alist-get 'agent value)
           (cmacs-clawtilla-chat conn (alist-get 'agent value))
         (message "clawtilla: that alert names nothing to open"))))))

(defun cmacs-clawtilla-alerts-read ()
  "Mark the row at point read: an alert, or a whole conversation."
  (interactive)
  (pcase-let ((`(,type . ,value) (cmacs-clawtilla-alerts--section))
              (conn (cmacs-clawtilla-current)))
    (pcase type
      ('notice-chat
       (cmacs-clawtilla-mark-read (alist-get 'room value) conn))
      ('notice
       (cmacs-clawtilla--notice-verb
        conn "notice.read" (list (cons 'id (alist-get 'id value)))))
      (_ (user-error "That is settled where it is answered, not here")))))

(defun cmacs-clawtilla-alerts-dismiss ()
  "Dismiss the alert at point, or remove the Grok job at point.

Removing a job asks first, in the daemon's words for that job's state:
an open one has an agent waiting on it."
  (interactive)
  (pcase-let ((`(,type . ,value) (cmacs-clawtilla-alerts--section))
              (conn (cmacs-clawtilla-current)))
    (pcase type
      ('notice
       (cmacs-clawtilla--notice-verb
        conn "notice.dismiss" (list (cons 'id (alist-get 'id value)))))
      ('notice-grok
       (cmacs-clawtilla-grok-remove-job
        conn (alist-get 'id value)
        (or (alist-get 'remove_question value) "It goes from the Grok page.")))
      (_ (user-error "Only an alert or a Grok job can be dismissed")))))

(defun cmacs-clawtilla-alerts-mute ()
  "Mute the agent of the row at point, or unmute it if it is muted."
  (interactive)
  (pcase-let* ((`(,_type . ,value) (cmacs-clawtilla-alerts--section))
               (conn (cmacs-clawtilla-current))
               (agent (alist-get 'agent value)))
    (unless agent (user-error "That row is about no agent"))
    (let ((muted (cmacs-clawtilla-agent-muted-p conn agent)))
      (cmacs-clawtilla-set-agent-muted conn agent (not muted))
      ;; The words are the menu item's, from the library: it reads back
      ;; the state it offers to undo.
      (message "clawtilla: %s: %s" agent
               (or (cmacs-clawtilla-ask "menu-mute-label"
                                        :muted (if muted t :false))
                   (if muted "unmuted" "muted"))))))

(defun cmacs-clawtilla-alerts-unmute (agent)
  "Unmute AGENT, chosen from the agents that are muted."
  (interactive
   (let ((muted (cmacs-clawtilla-connection-muted (cmacs-clawtilla-current))))
     (unless muted (user-error "No agent is muted"))
     (list (completing-read "Unmute: " muted nil t))))
  (cmacs-clawtilla-set-agent-muted (cmacs-clawtilla-current) agent nil))

(defun cmacs-clawtilla-alerts-scope ()
  "Narrow this buffer to the agent of the row at point, or widen it again."
  (interactive)
  (setq cmacs-clawtilla-alerts--agent
        (if cmacs-clawtilla-alerts--agent
            nil
          (or (alist-get 'agent (cdr (cmacs-clawtilla-alerts--section)))
              (user-error "That row is about no agent"))))
  (setq cmacs-clawtilla-alerts--history nil)
  (cmacs-clawtilla-alerts--draw))

(defun cmacs-clawtilla-alerts-mark-all-read ()
  "Mark every alert, and every conversation, read."
  (interactive)
  (cmacs-clawtilla-mark-all-read (cmacs-clawtilla-current)))

(defun cmacs-clawtilla-alerts-clear ()
  "Clear every alert showing -- or only the narrowed agent's.

For every client: the list is the daemon's.  Its event log is
untouched; `o' still has all of it."
  (interactive)
  (when (yes-or-no-p (if cmacs-clawtilla-alerts--agent
                         (format "Clear every alert about %s? "
                                 cmacs-clawtilla-alerts--agent)
                       "Clear every alert, for every client? "))
    (cmacs-clawtilla--notice-verb
     (cmacs-clawtilla-current) "notice.clear"
     (and cmacs-clawtilla-alerts--agent
          (list (cons 'agent cmacs-clawtilla-alerts--agent))))))

(defun cmacs-clawtilla-alerts-history ()
  "Load the daemon's own event log into this buffer.

Fifty lines, on request rather than on every refresh: it is a round
trip, and every event in the fleet redraws this buffer.  The log goes
back further than the list does, which is the difference between
\"nothing happened\" and \"I was not here\"."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "event.list"
     (append '((limit . "50"))
             (and cmacs-clawtilla-alerts--agent
                  (list (cons 'subject cmacs-clawtilla-alerts--agent))))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             ;; Newest first, like the list above it.
             (setq cmacs-clawtilla-alerts--history
                   (reverse (cmacs-clawtilla-get data 'events)))
             (cmacs-clawtilla-alerts--draw))))))))


;;;; The mode.

(transient-define-prefix cmacs-clawtilla-alerts-menu ()
  "What the notifications buffer can do."
  ["Row"
   [("RET" "go where it leads" cmacs-clawtilla-alerts-visit)
    ("r" "mark read" cmacs-clawtilla-alerts-read)
    ("d" "dismiss / remove the job" cmacs-clawtilla-alerts-dismiss)]
   [("z" "mute or unmute its agent" cmacs-clawtilla-alerts-mute)
    ("U" "unmute an agent" cmacs-clawtilla-alerts-unmute)
    ("a" "only this agent / the fleet" cmacs-clawtilla-alerts-scope)]]
  ["Everything"
   [("m" "mark all read" cmacs-clawtilla-alerts-mark-all-read)
    ("x" "clear the alerts" cmacs-clawtilla-alerts-clear)
    ("o" "load the daemon's log" cmacs-clawtilla-alerts-history)]])

(defvar cmacs-clawtilla-alerts-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-alerts-visit)
    (define-key map (kbd "r") #'cmacs-clawtilla-alerts-read)
    (define-key map (kbd "d") #'cmacs-clawtilla-alerts-dismiss)
    (define-key map (kbd "z") #'cmacs-clawtilla-alerts-mute)
    (define-key map (kbd "U") #'cmacs-clawtilla-alerts-unmute)
    (define-key map (kbd "a") #'cmacs-clawtilla-alerts-scope)
    (define-key map (kbd "m") #'cmacs-clawtilla-alerts-mark-all-read)
    (define-key map (kbd "x") #'cmacs-clawtilla-alerts-clear)
    (define-key map (kbd "o") #'cmacs-clawtilla-alerts-history)
    (define-key map (kbd "?") #'cmacs-clawtilla-alerts-menu)
    map)
  "Keymap for `cmacs-clawtilla-alerts-mode'.")

(define-derived-mode cmacs-clawtilla-alerts-mode special-mode
  "Clawtilla-Alerts"
  "Major mode for the daemon's notification list."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda ()
                (when cmacs-clawtilla-connection
                  (cmacs-clawtilla-notices-refresh
                   cmacs-clawtilla-connection))
                (cmacs-clawtilla-alerts--draw)))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-alerts (&optional conn)
  "Show what wants somebody on CONN: the daemon's notification list.

Opening it reads the alerts: whatever was unread is marked read for
every client, as the GTK client's panel does on opening."
  (interactive)
  (let* ((conn (or conn (cmacs-clawtilla-current)))
         (buffer (get-buffer-create "*clawtilla alerts*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-alerts-mode)
        (cmacs-clawtilla-alerts-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (cmacs-clawtilla-alerts--draw))
    (cmacs-clawtilla-display buffer)
    (when (> (or (alist-get 'unread (cmacs-clawtilla-connection-notices conn))
                 0)
             0)
      (cmacs-clawtilla--notice-verb conn "notice.read" '((all . t))))
    (cmacs-clawtilla-notices-refresh conn)
    buffer))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-alerts--on-event)

;; The bell, in the mode line of every buffer that belongs to a
;; connection.  Keyed on the buffer-local connection, so it costs
;; nothing anywhere else.
(add-to-list 'mode-line-misc-info
             '(cmacs-clawtilla-connection
               (:eval (cmacs-clawtilla-alerts-mode-line))))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-alerts-mode-map 'cmacs-clawtilla-alerts-mode)

(provide 'cmacs-clawtilla-alerts)

;;; cmacs-clawtilla-alerts.el ends here
