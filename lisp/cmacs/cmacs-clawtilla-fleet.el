;;; cmacs-clawtilla-fleet.el --- The fleet, as a buffer -*- lexical-binding: t; -*-

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

;; The GTK client's sidebar, as a magit-shaped buffer: collapsible
;; sections, a transient of every action, and one keystroke to the thing
;; under point.
;;
;; Teams come from `team.list' and agents from `agent.list', which
;; already returns them grouped by team -- so the grouping here is the
;; daemon's rather than one this client invented, and an agent that
;; belongs to no team is a group the daemon describes too.  The counts
;; beside a team name come from `clawt_team_tally', not from counting
;; the rows on screen: three clients counting the same thing is three
;; chances to disagree about what "active" means.
;;
;; Every team gets a heading, including an empty one.  A team somebody
;; made and has not filled is exactly the team they are about to drag
;; somebody into, and a client that hides it until it has a member makes
;; that impossible.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(declare-function cmacs-clawtilla--activity-label "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--team-tally "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla-chat "cmacs-clawtilla-chat")
(declare-function cmacs-clawtilla-agent "cmacs-clawtilla-agent")

(defcustom cmacs-clawtilla-fleet-show-descriptions t
  "Whether an agent's description is drawn under its name.

Off puts it on the pointer instead, which is the same choice the GTK
client offers: a fleet of thirty with a sentence each is a buffer you
scroll rather than read."
  :type 'boolean
  :group 'cmacs-clawtilla)

(defvar-local cmacs-clawtilla-fleet--agents nil)
(defvar-local cmacs-clawtilla-fleet--agents-json nil
  "The agents array exactly as the daemon sent it.")
(defvar-local cmacs-clawtilla-fleet--teams nil)
(defvar-local cmacs-clawtilla-fleet--rooms nil)
(defvar-local cmacs-clawtilla-fleet--warnings nil)
(defvar-local cmacs-clawtilla-fleet--unread nil
  "Hash of room id to unread count.")


;;;; Drawing.

(defun cmacs-clawtilla-fleet--agent-line (agent)
  "Return the display line for AGENT."
  (let* ((name (or (alist-get 'name agent) (alist-get 'id agent)))
         (state (alist-get 'state agent))
         (busy (alist-get 'busy agent))
         (peer (alist-get 'peer agent))
         (room (alist-get 'dm_room agent))
         (depth (or (alist-get 'mailbox_depth agent) 0))
         (unread (and cmacs-clawtilla-fleet--unread room
                      (gethash room cmacs-clawtilla-fleet--unread)))
         (activity (cmacs-clawtilla--activity-label busy peer))
         (parts nil))
    (when (eq t (alist-get 'chief_of_staff agent))
      (push (cmacs-clawtilla-badge "chief") parts))
    (when (equal (alist-get 'team_role agent) "lead")
      (push (cmacs-clawtilla-badge "lead") parts))
    (concat
     (propertize name 'face 'cmacs-clawtilla-agent)
     (when parts (concat " " (string-join (nreverse parts) " ")))
     "  "
     (propertize (or state "?")
                 'face (cmacs-clawtilla-state-face
                        (if (eq t busy) "busy" state)))
     ;; The activity sentence, when there is one.  Asked of the library
     ;; rather than assembled: the CLI rendered neither `busy' nor
     ;; `peer' for as long as they existed, and the web client dropped
     ;; `peer' on the floor.
     (when activity (concat "  " (cmacs-clawtilla-dim activity)))
     (when (and unread (> unread 0))
       (concat "  " (propertize (format "%d" unread)
                                'face 'cmacs-clawtilla-unread)))
     (when (> depth 0)
       (concat "  " (cmacs-clawtilla-dim (format "%d queued" depth)))))))

(defun cmacs-clawtilla-fleet--insert-agent (agent level)
  "Insert AGENT at LEVEL."
  (cmacs-clawtilla-insert-section
   :type 'agent :value agent :level level
   :heading (cmacs-clawtilla-fleet--agent-line agent)
   :foldable nil)
  (when-let* ((description (and cmacs-clawtilla-fleet-show-descriptions
                                (alist-get 'description agent))))
    (let ((start (point)))
      (insert (make-string (* 2 (1+ level)) ?\s)
              (cmacs-clawtilla-dim description) "\n")
      ;; The description belongs to its agent, so a command run with
      ;; point on it acts on the agent rather than on nothing.
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type 'agent :value agent
                               :identity (cmacs-clawtilla-ui--identity
                                          'agent agent)
                               :level level :foldable nil)))))

(defun cmacs-clawtilla-fleet--team-heading (team)
  "Return the heading line for TEAM."
  (let* ((tally (cmacs-clawtilla--parse
                 ;; The RAW agents array, not a re-serialisation of the
                 ;; parsed one.  json-parse-string maps null to nil and
                 ;; json-serialize writes nil back as `{}', so a round
                 ;; trip turns `"team": null' -- which every agent in no
                 ;; team has -- into an empty OBJECT, and the tally then
                 ;; logged a json-glib CRITICAL on every redraw.  The
                 ;; counts stayed right, which is why it was invisible.
                 (cmacs-clawtilla--team-tally
                  (or cmacs-clawtilla-fleet--agents-json "[]")
                  (alist-get 'id team))))
         (total (or (alist-get 'total tally) 0))
         (running (or (alist-get 'running tally) 0))
         (busy (or (alist-get 'busy tally) 0)))
    (concat
     (propertize (or (alist-get 'name team) (alist-get 'id team))
                 'face 'cmacs-clawtilla-team)
     "  "
     (cmacs-clawtilla-dim
      (if (zerop total)
          "empty"
        (format "%d/%d up%s" running total
                (if (> busy 0) (format ", %d busy" busy) "")))))))

(defun cmacs-clawtilla-fleet--agents-in (team-id)
  "Return the agents whose team is TEAM-ID."
  (seq-filter (lambda (agent) (equal (alist-get 'team agent) team-id))
              cmacs-clawtilla-fleet--agents))

(defun cmacs-clawtilla-fleet--draw ()
  "Redraw the fleet buffer."
  (cmacs-clawtilla-ui-preserving
    (let ((conn cmacs-clawtilla-connection))
      (insert (propertize (cmacs-clawtilla-connection-label conn)
                          'face 'cmacs-clawtilla-heading)
              "  "
              (cmacs-clawtilla-dim
               (or (cmacs-clawtilla-connection-describe conn) ""))
              "\n")
      (unless (eq (cmacs-clawtilla-connection-state conn) 'connected)
        (insert (propertize (cmacs-clawtilla-link-notice conn)
                            'face 'cmacs-clawtilla-error)
                "\n"))
      ;; Fleet-wide warnings, which only the whole fleet can see: a
      ;; team whose lead has been removed is not visible from any one
      ;; agent's row.
      (dolist (warning cmacs-clawtilla-fleet--warnings)
        (insert "  " (propertize (format "! %s" warning)
                                 'face 'cmacs-clawtilla-error)
                "\n"))
      (insert "\n")

      (dolist (team cmacs-clawtilla-fleet--teams)
        (cmacs-clawtilla-insert-section
         :type 'team :value team :level 0 :foldable t
         :heading (cmacs-clawtilla-fleet--team-heading team)
         :body (lambda ()
                 (dolist (agent (cmacs-clawtilla-fleet--agents-in
                                 (alist-get 'id team)))
                   (cmacs-clawtilla-fleet--insert-agent agent 1))))
        (insert "\n"))

      (let ((loose (cmacs-clawtilla-fleet--agents-in nil)))
        (when loose
          (cmacs-clawtilla-insert-section
           :type 'team :value "no-team" :level 0 :foldable t
           :heading (concat (propertize "No team"
                                        'face 'cmacs-clawtilla-team)
                            "  "
                            (cmacs-clawtilla-dim
                             (format "%d" (length loose))))
           :body (lambda ()
                   (dolist (agent loose)
                     (cmacs-clawtilla-fleet--insert-agent agent 1))))
          (insert "\n")))

      (when cmacs-clawtilla-fleet--rooms
        (cmacs-clawtilla-insert-section
         :type 'rooms :value "rooms" :level 0 :foldable t
         :heading (propertize "Rooms" 'face 'cmacs-clawtilla-team)
         :body (lambda ()
                 (dolist (room cmacs-clawtilla-fleet--rooms)
                   (cmacs-clawtilla-insert-section
                    :type 'room :value room :level 1
                    :heading (or (alist-get 'name room)
                                 (alist-get 'id room))))))))))


;;;; Loading.

(defun cmacs-clawtilla-fleet--load (&optional buffer)
  "Refetch everything the fleet buffer draws into BUFFER."
  (let ((buffer (or buffer (current-buffer)))
        (conn (buffer-local-value 'cmacs-clawtilla-connection
                                  (or buffer (current-buffer)))))
    (cmacs-clawtilla-request-raw
     conn "agent.list" nil
     (lambda (json err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             (let ((data (cmacs-clawtilla--parse json)))
               (setq cmacs-clawtilla-fleet--agents
                     (cmacs-clawtilla-get data 'agents))
               ;; Kept as text for anything that goes back to C.
               (setq cmacs-clawtilla-fleet--agents-json
                     (cmacs-clawtilla-member-json json 'agents)))
             (cmacs-clawtilla-fleet--draw))))))
    (cmacs-clawtilla-request
     conn "team.list" nil
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-fleet--teams
                 (cmacs-clawtilla-get data 'teams))
           (setq cmacs-clawtilla-fleet--warnings
                 (cmacs-clawtilla-get data 'warnings))
           (cmacs-clawtilla-fleet--draw)))))
    (cmacs-clawtilla-request
     conn "room.list" nil
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-fleet--rooms
                 (cmacs-clawtilla-get data 'rooms))
           (cmacs-clawtilla-fleet--draw)))))))


;;;; Acting.

(defun cmacs-clawtilla-fleet--agent-id ()
  "Return the id of the agent at point, or signal."
  (let ((agent (cmacs-clawtilla-value-at-point 'agent)))
    (unless agent (user-error "No agent at point"))
    (alist-get 'id agent)))

(defun cmacs-clawtilla-fleet--act (kind &optional extra confirm)
  "Send KIND for the agent at point, with EXTRA in the payload.

CONFIRM, when non-nil, is a question asked first: an action that ends a
turn or removes a machine is not one to discover you have run."
  (let* ((id (cmacs-clawtilla-fleet--agent-id))
         (conn (cmacs-clawtilla-current))
         (buffer (current-buffer)))
    (when (or (null confirm) (yes-or-no-p (format confirm id)))
      (cmacs-clawtilla-request
       conn kind (append (list (cons 'agent id)) extra)
       (lambda (_data err)
         (if err
             (message "clawtilla: %s" err)
           (message "clawtilla: %s %s" id kind)
           (when (buffer-live-p buffer)
             (cmacs-clawtilla-fleet--load buffer))))))))

(defun cmacs-clawtilla-fleet-start ()
  "Start the agent at point."
  (interactive)
  (cmacs-clawtilla-fleet--act "agent.start"))

(defun cmacs-clawtilla-fleet-stop ()
  "Stop the agent at point."
  (interactive)
  (cmacs-clawtilla-fleet--act "agent.stop"))

(defun cmacs-clawtilla-fleet-restart ()
  "Restart the agent at point."
  (interactive)
  (cmacs-clawtilla-fleet--act "agent.restart"))

(defun cmacs-clawtilla-fleet-interrupt ()
  "Interrupt the turn the agent at point is running."
  (interactive)
  (cmacs-clawtilla-fleet--act "agent.interrupt"))

(defun cmacs-clawtilla-fleet-reset ()
  "Reset the agent at point, dropping its session.

Not the same as a restart, and the difference is the whole reason both
exist: a restart brings the same conversation back, a reset is what
makes an identity change take."
  (interactive)
  (cmacs-clawtilla-fleet--act
   "agent.reset" nil "Reset %s, dropping its conversation? "))

(defun cmacs-clawtilla-fleet-remove ()
  "Remove the agent at point."
  (interactive)
  (let* ((id (cmacs-clawtilla-fleet--agent-id))
         (files (yes-or-no-p (format "Remove %s's files as well? " id)))
         (computer (yes-or-no-p (format "Remove %s's computer as well? " id))))
    (when (yes-or-no-p (format "Really remove %s? " id))
      (cmacs-clawtilla-fleet--act "agent.remove"
                                  (list (cons 'remove_files files)
                                        (cons 'remove_computer computer))))))

(defun cmacs-clawtilla-fleet-visit ()
  "Open what is at point: an agent's chat, or a room."
  (interactive)
  (let ((section (cmacs-clawtilla-section-at-point)))
    (pcase (and section (plist-get section :type))
      ('agent (cmacs-clawtilla-chat (cmacs-clawtilla-current)
                                    (plist-get section :value)))
      ('room (cmacs-clawtilla-chat (cmacs-clawtilla-current)
                                   nil (plist-get section :value)))
      (_ (user-error "Nothing to open here")))))

(defun cmacs-clawtilla-fleet-describe ()
  "Open the agent at point's own page."
  (interactive)
  (cmacs-clawtilla-agent (cmacs-clawtilla-current)
                         (cmacs-clawtilla-value-at-point 'agent)))


;;;; The menu.

(transient-define-prefix cmacs-clawtilla-fleet-menu ()
  "Everything the fleet buffer can do."
  ["Agent at point"
   [("RET" "open chat" cmacs-clawtilla-fleet-visit)
    ("o" "agent page" cmacs-clawtilla-fleet-describe)]
   [("s" "start" cmacs-clawtilla-fleet-start)
    ("S" "stop" cmacs-clawtilla-fleet-stop)
    ("R" "restart" cmacs-clawtilla-fleet-restart)]
   [("k" "interrupt turn" cmacs-clawtilla-fleet-interrupt)
    ("!" "reset session" cmacs-clawtilla-fleet-reset)
    ("D" "remove" cmacs-clawtilla-fleet-remove)]]
  ["Fleet"
   [("c" "create agent" cmacs-clawtilla-agent-create)
    ("i" "import agent" cmacs-clawtilla-agent-import)]
   [("h" "hold fleet" cmacs-clawtilla-fleet-hold)
    ("H" "resume fleet" cmacs-clawtilla-fleet-resume)]
   [("g" "refresh" cmacs-clawtilla-refresh)
    ("q" "quit" quit-window)]])

(defun cmacs-clawtilla-fleet-hold ()
  "Pause the whole fleet."
  (interactive)
  (cmacs-clawtilla-request (cmacs-clawtilla-current) "control.pause" nil
                           (lambda (_d e)
                             (message "clawtilla: %s" (or e "fleet held")))))

(defun cmacs-clawtilla-fleet-resume ()
  "Resume the whole fleet."
  (interactive)
  (cmacs-clawtilla-request (cmacs-clawtilla-current) "control.resume" nil
                           (lambda (_d e)
                             (message "clawtilla: %s" (or e "fleet resumed")))))


;;;; The mode.

(defvar cmacs-clawtilla-fleet-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map cmacs-clawtilla-common-map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-fleet-visit)
    (define-key map (kbd "o") #'cmacs-clawtilla-fleet-describe)
    (define-key map (kbd "s") #'cmacs-clawtilla-fleet-start)
    (define-key map (kbd "S") #'cmacs-clawtilla-fleet-stop)
    (define-key map (kbd "R") #'cmacs-clawtilla-fleet-restart)
    (define-key map (kbd "k") #'cmacs-clawtilla-fleet-interrupt)
    (define-key map (kbd "!") #'cmacs-clawtilla-fleet-reset)
    (define-key map (kbd "D") #'cmacs-clawtilla-fleet-remove)
    (define-key map (kbd "?") #'cmacs-clawtilla-fleet-menu)
    map)
  "Keymap for `cmacs-clawtilla-fleet-mode'.")

(define-derived-mode cmacs-clawtilla-fleet-mode special-mode "Clawtilla"
  "Major mode for the clawtilla fleet."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-fleet--load (current-buffer))))
  (setq-local cmacs-clawtilla-fleet--unread (make-hash-table :test 'equal))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-fleet (&optional conn)
  "Show the fleet on CONN."
  (interactive)
  (let* ((conn (or conn
                   (if cmacs-clawtilla-connections
                       (cmacs-clawtilla-current)
                     (call-interactively #'cmacs-clawtilla-connect))))
         (buffer (get-buffer-create
                  (format "*clawtilla: %s*"
                          (or (cmacs-clawtilla-connection-name conn)
                              "fleet")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-fleet-mode)
        (cmacs-clawtilla-fleet-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (cmacs-clawtilla-fleet--load buffer))
    (pop-to-buffer buffer)))

(defun cmacs-clawtilla-fleet--on-event (conn kind data)
  "Redraw any fleet buffer for CONN when KIND in DATA changes it."
  (when (string-match-p
         (rx bos (or "agent." "team." "room." "control." "fleet.")) kind)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'cmacs-clawtilla-fleet-mode)
                   (eq cmacs-clawtilla-connection conn))
          ;; Refetched rather than patched from the event.  An event says
          ;; what changed, not what everything now is, and a client that
          ;; edits its own copy drifts from the daemon in exactly the
          ;; cases nobody is watching.
          (cmacs-clawtilla-fleet--load buffer)))))
  (ignore data))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-fleet--on-event)

(provide 'cmacs-clawtilla-fleet)

;;; cmacs-clawtilla-fleet.el ends here
