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
    ("TAB" "next page" cmacs-clawtilla-agent-next-page)]
   [("g" "refresh" cmacs-clawtilla-refresh)
    ("q" "quit" quit-window)]])

(defvar cmacs-clawtilla-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map cmacs-clawtilla-common-map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-agent-set)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-agent-next-page)
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
    (pop-to-buffer buffer)))

(provide 'cmacs-clawtilla-agent)

;;; cmacs-clawtilla-agent.el ends here
