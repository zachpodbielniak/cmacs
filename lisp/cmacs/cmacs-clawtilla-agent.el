;;; cmacs-clawtilla-agent.el --- One agent, and its mailbox -*- lexical-binding: t; -*-

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

;; The Agent section: Overview and Mailbox, which is what the GTK client
;; groups under that name.
;;
;; Overview is editable in place -- every field is a line you press RET
;; on -- because an agent is mostly a set of small decisions (model,
;; effort, restart policy, whether it starts with the fleet) and a form
;; that has to be filled in and submitted turns changing one of them
;; into a ceremony.
;;
;; The values a field offers come from the library, never from a list
;; written here: computer types and import modes are enumerations
;; clawtilla exports precisely so a client does not hold its own copy,
;; and `make parity' fails a client that spells any of them out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(defvar-local cmacs-clawtilla-agent--id nil)
(defvar-local cmacs-clawtilla-agent--data nil)
(defvar-local cmacs-clawtilla-agent--mailbox nil)
(defvar-local cmacs-clawtilla-agent--page 'agent
  "Which page of the Agent section this buffer shows.")


;;;; Drawing.

(defun cmacs-clawtilla-agent--field (label value &optional key)
  "Insert LABEL and VALUE as an editable field named KEY."
  (let ((start (point)))
    (insert (format "  %-22s " label)
            (if value (format "%s" value) (cmacs-clawtilla-dim "—"))
            "\n")
    (when key
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type 'field :value key
                               :identity (format "field/%s" key)
                               :level 1 :foldable nil)))))

(defun cmacs-clawtilla-agent--draw-overview ()
  "Draw the agent's overview page."
  (let ((agent cmacs-clawtilla-agent--data))
    (cmacs-clawtilla-agent--field "Name" (alist-get 'name agent) 'name)
    (cmacs-clawtilla-agent--field "Description"
                                  (alist-get 'description agent) 'description)
    (cmacs-clawtilla-agent--field "Provider" (alist-get 'provider agent)
                                  'provider)
    (cmacs-clawtilla-agent--field "Model" (alist-get 'model agent) 'model)
    (cmacs-clawtilla-agent--field "Effort" (alist-get 'effort agent) 'effort)
    (cmacs-clawtilla-agent--field "Computer" (alist-get 'computer agent)
                                  'computer)
    (cmacs-clawtilla-agent--field "Team" (alist-get 'team agent) 'team)
    (cmacs-clawtilla-agent--field "Team role" (alist-get 'team_role agent)
                                  'team_role)
    (cmacs-clawtilla-agent--field "Restart" (alist-get 'restart agent)
                                  'restart)
    (cmacs-clawtilla-agent--field "Autostart"
                                  (if (eq t (alist-get 'autostart agent))
                                      "yes" "no")
                                  'autostart)
    (cmacs-clawtilla-agent--field "Chief of staff"
                                  (if (eq t (alist-get 'chief_of_staff agent))
                                      "yes" "no")
                                  'chief_of_staff)
    (cmacs-clawtilla-agent--field "Enabled"
                                  (if (eq t (alist-get 'enabled agent))
                                      "yes" "no")
                                  'enabled)
    (insert "\n")
    ;; Credentials are shown by reference and never by value.  A client
    ;; that could print one is a client that eventually does.
    (let ((credentials (alist-get 'credentials agent)))
      (cmacs-clawtilla-insert-section
       :type 'credentials :value "credentials" :level 0 :foldable t
       :heading (propertize "Credentials" 'face 'cmacs-clawtilla-heading)
       :body (lambda ()
               (if (null credentials)
                   (insert "  " (cmacs-clawtilla-dim "none") "\n")
                 (dolist (pair credentials)
                   (cmacs-clawtilla-agent--field
                    (format "%s" (car pair))
                    (cmacs-clawtilla-dim (format "%s" (cdr pair)))))))))))

(defun cmacs-clawtilla-agent--draw-mailbox ()
  "Draw the agent's mailbox."
  (if (null cmacs-clawtilla-agent--mailbox)
      (insert "  " (cmacs-clawtilla-dim "nothing waiting") "\n")
    (dolist (item cmacs-clawtilla-agent--mailbox)
      (cmacs-clawtilla-insert-section
       :type 'mail :value item :level 1
       :heading (concat
                 (propertize (or (alist-get 'from item) "?")
                             'face 'cmacs-clawtilla-agent)
                 "  "
                 (cmacs-clawtilla-dim
                  (or (cmacs-clawtilla--time-label
                       (or (alist-get 'created item) 0))
                      ""))
                 "  "
                 (or (alist-get 'subject item)
                     (truncate-string-to-width
                      (or (alist-get 'body item) "") 60 nil nil t)))))))

(defun cmacs-clawtilla-agent--draw ()
  "Redraw the agent buffer."
  (cmacs-clawtilla-ui-preserving
    (let* ((agent cmacs-clawtilla-agent--data)
           (id (or cmacs-clawtilla-agent--id (alist-get 'id agent))))
      (insert (propertize (or (alist-get 'name agent) id)
                          'face 'cmacs-clawtilla-heading)
              "  "
              (propertize (or (alist-get 'state agent) "?")
                          'face (cmacs-clawtilla-state-face
                                 (alist-get 'state agent)))
              "\n")
      ;; The pages of this section, named by the library rather than
      ;; here: a section that grows a page should grow one here too,
      ;; without an edit.
      (insert (cmacs-clawtilla-dim
               (mapconcat
                (lambda (page)
                  (let ((nick (alist-get 'nick page)))
                    (if (equal nick (symbol-name cmacs-clawtilla-agent--page))
                        (propertize (alist-get 'label page)
                                    'face 'cmacs-clawtilla-heading)
                      (alist-get 'label page))))
                (cmacs-clawtilla-agent--pages) "  |  "))
              "\n\n")
      (pcase cmacs-clawtilla-agent--page
        ('mailbox (cmacs-clawtilla-agent--draw-mailbox))
        (_ (cmacs-clawtilla-agent--draw-overview))))))

(defun cmacs-clawtilla-agent--pages ()
  "Return the pages of the Agent section, as the library groups them."
  (let ((section (seq-find (lambda (s) (equal (alist-get 'nick s) "agent"))
                           (cmacs-clawtilla-enum "section"))))
    (alist-get 'pages section)))


;;;; Loading.

(defun cmacs-clawtilla-agent--load (&optional buffer)
  "Refetch what the agent buffer draws into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (id (buffer-local-value 'cmacs-clawtilla-agent--id buffer)))
    (cmacs-clawtilla-request
     conn "agent.show" (list (cons 'agent id))
     (lambda (data err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             (setq cmacs-clawtilla-agent--data
                   (or (cmacs-clawtilla-get data 'agent) data))
             (cmacs-clawtilla-agent--draw))))))
    (cmacs-clawtilla-request
     conn "mailbox.list" (list (cons 'agent id))
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-agent--mailbox
                 (or (cmacs-clawtilla-get data 'items)
                     (cmacs-clawtilla-get data 'messages)))
           (cmacs-clawtilla-agent--draw)))))))


;;;; Editing.

(defun cmacs-clawtilla-agent--choices (key)
  "Return the values KEY offers, or nil for free text.

Read out of the library's enumerations rather than listed here.  A
computer type added to clawtilla is offered by this client the moment
it exists, and `make parity' fails a client holding its own copy."
  (pcase key
    ('computer (cmacs-clawtilla-enum-nicks "computer-type"))
    ('team_role '("member" "lead"))
    ((or 'autostart 'chief_of_staff 'enabled) '("yes" "no"))
    (_ nil)))

(defun cmacs-clawtilla-agent-set ()
  "Change the field at point."
  (interactive)
  (let* ((key (cmacs-clawtilla-value-at-point 'field))
         (agent cmacs-clawtilla-agent--data)
         (id (alist-get 'id agent))
         (conn (cmacs-clawtilla-current))
         (buffer (current-buffer)))
    (unless key (user-error "No field at point"))
    (let* ((choices (cmacs-clawtilla-agent--choices key))
           (current (alist-get key agent))
           (value (if choices
                      (completing-read (format "%s: " key) choices nil t)
                    (read-string (format "%s: " key)
                                 (and current (format "%s" current))))))
      (cmacs-clawtilla-request
       conn "agent.set"
       (list (cons 'agent id)
             (cons key (pcase value
                         ("yes" t) ("no" :false)
                         (_ value))))
       (lambda (_data err)
         (if err
             (message "clawtilla: %s" err)
           (when (buffer-live-p buffer)
             (cmacs-clawtilla-agent--load buffer))))))))

(defun cmacs-clawtilla-agent-next-page ()
  "Move to the next page of the Agent section."
  (interactive)
  (let* ((pages (mapcar (lambda (p) (intern (alist-get 'nick p)))
                        (cmacs-clawtilla-agent--pages)))
         (rest (cdr (memq cmacs-clawtilla-agent--page pages))))
    (setq cmacs-clawtilla-agent--page (or (car rest) (car pages)))
    (cmacs-clawtilla-agent--draw)))


;;;; The mailbox, and what to do about a stuck one.

(defun cmacs-clawtilla-agent--mail-id ()
  "Return the id of the mailbox item at point, or signal."
  (let ((item (cmacs-clawtilla-value-at-point 'mail)))
    (unless item (user-error "No mailbox item at point"))
    (or (alist-get 'id item) (user-error "That item has no id"))))

(defun cmacs-clawtilla-agent--mailbox (kind &optional payload)
  "Send KIND with PAYLOAD for this agent's mailbox and reload."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind
     (append (list (cons 'agent cmacs-clawtilla-agent--id)) payload)
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-agent--load buffer)))))))

(defun cmacs-clawtilla-agent-ack ()
  "Acknowledge the mailbox item at point."
  (interactive)
  (cmacs-clawtilla-agent--mailbox
   "mailbox.ack" (list (cons 'id (cmacs-clawtilla-agent--mail-id)))))

(defun cmacs-clawtilla-agent-requeue ()
  "Put the item at point back on the queue."
  (interactive)
  (cmacs-clawtilla-agent--mailbox
   "mailbox.requeue" (list (cons 'id (cmacs-clawtilla-agent--mail-id)))))

(defun cmacs-clawtilla-agent-dead-letters ()
  "Show what this agent's mailbox gave up on.

Its own view rather than a filter on the queue: a dead letter is not
waiting for anything, and showing it beside things that are invites
somebody to wait for it too."
  (interactive)
  (let ((agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "mailbox.dead" (list (cons 'agent agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla dead: %s*" agent))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (let ((items (or (cmacs-clawtilla-get data 'items)
                              (cmacs-clawtilla-get data 'messages))))
               (if (null items)
                   (insert (cmacs-clawtilla-dim "nothing gave up") "\n")
                 (dolist (item items)
                   (insert (format "%-14s %s\n"
                                   (or (alist-get 'from item) "?")
                                   (or (alist-get 'body item) ""))))))
             (goto-char (point-min))
             (special-mode))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-agent-purge ()
  "Throw away everything waiting in this agent's mailbox."
  (interactive)
  (when (yes-or-no-p
         (format "Discard everything waiting for %s? "
                 cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-agent--mailbox "mailbox.purge")))


;;;; The face an agent shows.

(defun cmacs-clawtilla-agent-avatar ()
  "Show this agent's avatar."
  (interactive)
  (let ((agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.avatar" (list (cons 'agent agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let ((encoded (cmacs-clawtilla-get data 'image)))
           (if (null encoded)
               (message "clawtilla: %s has no avatar" agent)
             (with-current-buffer (get-buffer-create
                                   (format "*clawtilla avatar: %s*" agent))
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert-image
                  (create-image (base64-decode-string encoded) nil t))
                 (special-mode))
               (cmacs-clawtilla-display (current-buffer))))))))))

(defun cmacs-clawtilla-agent-avatar-set (file)
  "Give this agent the picture in FILE."
  (interactive "fAvatar: ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.avatar_set"
   (list (cons 'agent cmacs-clawtilla-agent--id)
         (cons 'image (base64-encode-string
                       (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file)
                         (buffer-string))
                       t)))
   (lambda (_d e) (message "clawtilla: %s" (or e "avatar set")))))

(defun cmacs-clawtilla-agent-avatar-clear ()
  "Take this agent's avatar away."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.avatar_clear"
   (list (cons 'agent cmacs-clawtilla-agent--id))
   (lambda (_d e) (message "clawtilla: %s" (or e "avatar cleared")))))

(defun cmacs-clawtilla-agent-models ()
  "Offer the models this fleet's providers actually have.

Asked of the daemon rather than typed: a model name that is nearly
right fails at the first turn, by which time the agent exists and the
error mentions the provider rather than the typo."
  (interactive)
  (let ((buffer (current-buffer))
        (agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "model.list" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((models (cmacs-clawtilla-get data 'models))
                (names (mapcar (lambda (m)
                                 (or (alist-get 'id m) (alist-get 'name m)
                                     (format "%s" m)))
                               models))
                (choice (completing-read "Model: " names nil t)))
           (cmacs-clawtilla-request
            (cmacs-clawtilla-current) "agent.set"
            (list (cons 'agent agent) (cons 'model choice))
            (lambda (_d e)
              (if e (message "clawtilla: %s" e)
                (when (buffer-live-p buffer)
                  (cmacs-clawtilla-agent--load buffer)))))))))))

(defun cmacs-clawtilla-agent-discover ()
  "Find agents the daemon can see but does not manage."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.discover" nil
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (let ((found (cmacs-clawtilla-get data 'agents)))
         (if (null found)
             (message "clawtilla: nothing unmanaged found")
           (with-current-buffer (get-buffer-create "*clawtilla discover*")
             (let ((inhibit-read-only t))
               (erase-buffer)
               (dolist (entry found)
                 (insert (format "%-20s %s\n"
                                 (or (alist-get 'id entry) "?")
                                 (or (alist-get 'path entry) ""))))
               (goto-char (point-min))
               (special-mode))
             (cmacs-clawtilla-display (current-buffer)))))))))

(defun cmacs-clawtilla-agent-forget ()
  "Stop managing this agent, leaving what it made alone."
  (interactive)
  (when (yes-or-no-p (format "Stop managing %s? " cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.forget"
     (list (cons 'agent cmacs-clawtilla-agent--id))
     (lambda (_d e) (message "clawtilla: %s" (or e "forgotten"))))))


;;;; The agent designer.

(defun cmacs-clawtilla-agent-design (brief)
  "Have the fleet design an agent from BRIEF, then show what it proposes.

Proposed, not created.  `cmacs-clawtilla-agent-design-commit' is what
makes it, and the two are separate because an agent is a machine as
well as a config: committing one builds a container or boots a VM."
  (interactive "sWhat should this agent do? ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "design.agent" (list (cons 'brief brief))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (with-current-buffer (get-buffer-create "*clawtilla design*")
         (let ((inhibit-read-only t))
           (erase-buffer)
           (dolist (pair (or (cmacs-clawtilla-get data 'agent) data))
             (insert (propertize (format "%-18s " (car pair))
                                 'face 'cmacs-clawtilla-heading)
                     (format "%s" (cdr pair)) "\n"))
           (insert "\n" (cmacs-clawtilla-dim
                         "M-x cmacs-clawtilla-agent-design-commit to make it")
                   "\n")
           (goto-char (point-min))
           (special-mode))
         (cmacs-clawtilla-display (current-buffer)))))))

(defun cmacs-clawtilla-agent-design-commit (&optional start)
  "Create the agent that was designed, starting it unless START is nil."
  (interactive (list (y-or-n-p "Start it once made? ")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "design.commit"
   (list (cons 'start (if start t :false)))
   (lambda (data err)
     (cond
      (err (message "clawtilla: %s" err))
      ((cmacs-clawtilla-get data 'start_error)
       (message "clawtilla: made, but did not start: %s"
                (cmacs-clawtilla-get data 'start_error)))
      (t (message "clawtilla: made"))))))

(defun cmacs-clawtilla-agent-design-discard ()
  "Throw away the design that has not been committed."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "design.discard" nil
   (lambda (_d e) (message "clawtilla: %s" (or e "discarded")))))

;;;; Creating and importing.

;;;###autoload
(defun cmacs-clawtilla-agent-create ()
  "Create an agent on the current connection.

Answers `started' as well as created, because a computer is built at an
agent's first start: one created and left alone is a configuration file
and no machine, and a start that failed is reported without undoing the
creation."
  (interactive)
  (let* ((conn (cmacs-clawtilla-current))
         (id (read-string "Agent id: "))
         (model (read-string "Model: " "sonnet"))
         (computer (completing-read
                    "Computer: " (cmacs-clawtilla-enum-nicks "computer-type")
                    nil t nil nil "none"))
         (start (y-or-n-p "Start it now? ")))
    (cmacs-clawtilla-request
     conn "agent.create"
     (list (cons 'id id) (cons 'model model) (cons 'computer computer)
           (cons 'start (if start t :false)))
     (lambda (data err)
       (cond
        (err (message "clawtilla: %s" err))
        ((cmacs-clawtilla-get data 'start_error)
         (message "clawtilla: %s created but did not start: %s" id
                  (cmacs-clawtilla-get data 'start_error)))
        (t (message "clawtilla: %s created%s" id
                    (if (eq t (cmacs-clawtilla-get data 'started))
                        " and started" ""))))))))

;;;###autoload
(defun cmacs-clawtilla-agent-import ()
  "Import an agent from a directory or a URL.

The modes come from the library's own enumeration, and which of them
take a URL rather than a path is the library's answer too."
  (interactive)
  (let* ((conn (cmacs-clawtilla-current))
         (modes (cmacs-clawtilla-enum "import-mode"))
         (mode (completing-read "Mode: "
                                (mapcar (lambda (m) (alist-get 'nick m)) modes)
                                nil t))
         (entry (seq-find (lambda (m) (equal (alist-get 'nick m) mode)) modes))
         (from (if (eq t (alist-get 'url entry))
                   (read-string "URL: ")
                 (read-directory-name "Directory: ")))
         (id (read-string "Agent id: ")))
    (cmacs-clawtilla-request
     conn "agent.import"
     (list (cons 'id id) (cons 'from from) (cons 'mode mode))
     (lambda (data err)
       (message "clawtilla: %s" (or err
                                    (cmacs-clawtilla-get data 'detail)
                                    (format "imported %s" id)))))))


;;;; The mode.

(transient-define-prefix cmacs-clawtilla-agent-menu ()
  "What this agent's page can do."
  ["Agent"
   [("RET" "change field" cmacs-clawtilla-agent-set)
    ("TAB" "next page" cmacs-clawtilla-agent-next-page)
    ("M" "pick a model" cmacs-clawtilla-agent-models)]
   [("v" "avatar" cmacs-clawtilla-agent-avatar)
    ("V" "set avatar" cmacs-clawtilla-agent-avatar-set)
    ("C" "clear avatar" cmacs-clawtilla-agent-avatar-clear)]
   [("g" "refresh" cmacs-clawtilla-refresh)
    ("q" "quit" quit-window)]]
  ["Mailbox"
   [("k" "acknowledge" cmacs-clawtilla-agent-ack)
    ("u" "requeue" cmacs-clawtilla-agent-requeue)]
   [("Z" "dead letters" cmacs-clawtilla-agent-dead-letters)
    ("P" "purge" cmacs-clawtilla-agent-purge)]]
  ["Fleet"
   [("D" "design an agent" cmacs-clawtilla-agent-design)
    ("K" "commit the design" cmacs-clawtilla-agent-design-commit)
    ("X" "discard it" cmacs-clawtilla-agent-design-discard)]
   [("o" "discover unmanaged" cmacs-clawtilla-agent-discover)
    ("F" "forget this one" cmacs-clawtilla-agent-forget)]])

(defvar cmacs-clawtilla-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-agent-set)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-agent-next-page)
    (define-key map (kbd "k") #'cmacs-clawtilla-agent-ack)
    (define-key map (kbd "u") #'cmacs-clawtilla-agent-requeue)
    (define-key map (kbd "Z") #'cmacs-clawtilla-agent-dead-letters)
    (define-key map (kbd "P") #'cmacs-clawtilla-agent-purge)
    (define-key map (kbd "M") #'cmacs-clawtilla-agent-models)
    (define-key map (kbd "v") #'cmacs-clawtilla-agent-avatar)
    (define-key map (kbd "?") #'cmacs-clawtilla-agent-menu)
    map)
  "Keymap for `cmacs-clawtilla-agent-mode'.")

(define-derived-mode cmacs-clawtilla-agent-mode special-mode "Clawtilla-Agent"
  "Major mode for one clawtilla agent."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-agent--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-agent (conn agent)
  "Show AGENT on CONN."
  (interactive (list (cmacs-clawtilla-current) nil))
  (let* ((id (if (stringp agent) agent (alist-get 'id agent)))
         (buffer (get-buffer-create (format "*clawtilla agent: %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-agent-mode)
        (cmacs-clawtilla-agent-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-agent--id id)
      (setq-local cmacs-clawtilla-agent--data (and (consp agent) agent))
      (cmacs-clawtilla-agent--load buffer))
    (cmacs-clawtilla-display buffer)))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-agent-mode-map 'cmacs-clawtilla-agent-mode)

(provide 'cmacs-clawtilla-agent)

;;; cmacs-clawtilla-agent.el ends here
