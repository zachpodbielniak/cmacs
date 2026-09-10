;;; cmacs-clawtilla-settings.el --- Fleet settings -*- lexical-binding: t; -*-

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

;; The GTK client's Settings: Appearance, Integrations, Connectors,
;; Teams, Spending, Folders and Cloud images.
;;
;; Appearance is the one panel that is not the daemon's.  Its values are
;; still the library's -- palettes and measure units come from
;; `clawt_appearance_scheme_count' and `clawt_measure_unit_count', so a
;; palette added to libclawt is offered here the moment it exists and
;; `make parity' fails a client that keeps its own copy of the list.
;;
;; Connectors are the panel to be careful in.  A connected account keeps
;; its credential in the daemon and hands only the TOOLS to the agents,
;; so nothing here ever displays or accepts a secret: beginning a
;; connection returns a URL to open, and the daemon does the rest.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

;; The descriptions toggle belongs to the fleet buffer and is offered
;; here, so this file needs its definition rather than a forward
;; reference: a `defcustom' referenced before it is defined is a free
;; variable, and setting one from here would create a second binding
;; that the fleet never reads.
(require 'cmacs-clawtilla-fleet)

(defcustom cmacs-clawtilla-colour-scheme nil
  "The palette clawtilla buffers use, or nil for the Emacs theme.

Offered from the library's own list rather than one written here."
  :type '(choice (const :tag "Emacs theme" nil) string)
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-measure-unit nil
  "How wide a transcript's text column is measured, or nil for the default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-measure 72
  "How wide the transcript's text column is, in `cmacs-clawtilla-measure-unit'."
  :type 'integer
  :group 'cmacs-clawtilla)

(defvar-local cmacs-clawtilla-settings--panel "appearance")
(defvar-local cmacs-clawtilla-settings--rows nil)
(defvar-local cmacs-clawtilla-settings--extra nil)

(defconst cmacs-clawtilla-settings-panels
  '(("appearance"  . "Appearance")
    ("integrations" . "Integrations")
    ("connectors"  . "Connectors")
    ("teams"       . "Teams")
    ("spending"    . "Spending")
    ("folders"     . "Folders")
    ("images"      . "Cloud images"))
  "The panels, in the order the GTK client shows them.")


;;;; Drawing.

(defun cmacs-clawtilla-settings--row (label value &optional key)
  "Insert LABEL and VALUE as a field named KEY."
  (let ((start (point)))
    (insert (format "  %-22s " label)
            (if value (format "%s" value) (cmacs-clawtilla-dim "—")) "\n")
    (when key
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type 'setting :value key
                               :identity (format "setting/%s" key)
                               :level 1 :foldable nil)))))

(defun cmacs-clawtilla-settings--draw-appearance ()
  "Draw the Appearance panel."
  (cmacs-clawtilla-settings--row
   "Palette" (or cmacs-clawtilla-colour-scheme "the Emacs theme") 'scheme)
  (cmacs-clawtilla-settings--row
   "Measure" (format "%d %s" cmacs-clawtilla-measure
                     (or cmacs-clawtilla-measure-unit "columns"))
   'measure)
  (cmacs-clawtilla-settings--row
   "Descriptions" (if cmacs-clawtilla-fleet-show-descriptions
                      "under each agent" "on the pointer")
   'descriptions)
  (insert "\n  " (cmacs-clawtilla-dim
                  (format "%d palettes and %d measure units offered by libclawt"
                          (length (cmacs-clawtilla-enum "appearance-scheme"))
                          (length (cmacs-clawtilla-enum "measure-unit"))))
          "\n"))

(defun cmacs-clawtilla-settings--draw-rows (format-row empty)
  "Draw the fetched rows with FORMAT-ROW, or EMPTY."
  (if (null cmacs-clawtilla-settings--rows)
      (insert "  " (cmacs-clawtilla-dim empty) "\n")
    (dolist (row cmacs-clawtilla-settings--rows)
      (cmacs-clawtilla-insert-section
       :type 'setting-row :value row :level 1
       :heading (funcall format-row row)))))

(defun cmacs-clawtilla-settings--draw ()
  "Redraw the settings buffer."
  (cmacs-clawtilla-ui-preserving
    (insert (propertize "Settings" 'face 'cmacs-clawtilla-heading) "\n"
            (mapconcat
             (lambda (panel)
               (if (equal (car panel) cmacs-clawtilla-settings--panel)
                   (propertize (cdr panel) 'face 'cmacs-clawtilla-heading)
                 (cmacs-clawtilla-dim (cdr panel))))
             cmacs-clawtilla-settings-panels "  |  ")
            "\n\n")
    (pcase cmacs-clawtilla-settings--panel
      ("appearance" (cmacs-clawtilla-settings--draw-appearance))
      ("integrations"
       (cmacs-clawtilla-settings--draw-rows
        (lambda (row)
          (format "%-16s %-12s %-10s %s"
                  (or (alist-get 'id row) "?")
                  (or (alist-get 'type row) "")
                  (propertize (or (alist-get 'health row) "")
                              'face (cmacs-clawtilla-state-face
                                     (alist-get 'health row)))
                  (cmacs-clawtilla-dim (or (alist-get 'agent row) ""))))
        "no integrations"))
      ("connectors"
       (cmacs-clawtilla-settings--draw-rows
        (lambda (row)
          ;; Never a token, never a refresh token, never a scope that
          ;; happens to contain one.  A connected account's credential
          ;; stays in the daemon; the agents get the tools.
          (format "%-20s %-12s %s"
                  (or (alist-get 'id row) (alist-get 'name row) "?")
                  (if (eq t (alist-get 'connected row))
                      (propertize "connected" 'face 'cmacs-clawtilla-running)
                    (propertize "not connected"
                                'face 'cmacs-clawtilla-stopped))
                  (cmacs-clawtilla-dim (or (alist-get 'account row) ""))))
        "no connected accounts"))
      ("teams"
       (cmacs-clawtilla-settings--draw-rows
        (lambda (row)
          (format "%-18s lead %-14s %d member%s"
                  (or (alist-get 'name row) (alist-get 'id row) "?")
                  (or (alist-get 'lead row) "—")
                  (length (alist-get 'members row))
                  (if (= 1 (length (alist-get 'members row))) "" "s")))
        "no teams"))
      ("spending"
       (progn
         (cmacs-clawtilla-settings--row
          "Fleet total"
          (cmacs-clawtilla-settings--money
           (alist-get 'total cmacs-clawtilla-settings--extra)))
         (insert "\n")
         (cmacs-clawtilla-settings--draw-rows
          (lambda (row)
            (format "%-18s %s"
                    (or (alist-get 'agent row) "?")
                    (cmacs-clawtilla-settings--money (alist-get 'cost row))))
          "nothing spent yet")))
      ("folders"
       (cmacs-clawtilla-settings--draw-rows
        (lambda (row)
          (format "%-30s %-24s %s"
                  (or (alist-get 'source row) "?")
                  (or (alist-get 'target row) "")
                  (cmacs-clawtilla-dim (or (alist-get 'mode row) ""))))
        "no folders shared with every agent"))
      ("images"
       (cmacs-clawtilla-settings--draw-rows
        (lambda (row)
          (format "%-28s %-10s %s"
                  (or (alist-get 'name row) (alist-get 'id row) "?")
                  (or (alist-get 'state row) "")
                  (cmacs-clawtilla-dim
                   (let ((size (alist-get 'size row)))
                     (if size (file-size-human-readable size) "")))))
        "no cloud images")))))

(defun cmacs-clawtilla-settings--money (amount)
  "Format AMOUNT, as the provider reported it."
  (if (numberp amount)
      ;; The figure each provider reported, not one recomputed from
      ;; tokens: a client that did its own arithmetic would disagree
      ;; with the bill.
      (format "$%.2f" amount)
    (cmacs-clawtilla-dim "—")))


;;;; Loading.

(defconst cmacs-clawtilla-settings--frames
  '(("integrations" "integration.list" integrations)
    ("connectors"   "connector.list"   connectors)
    ("teams"        "team.list"        teams)
    ("spending"     "usage.summary"    agents)
    ("folders"      "defaults.mount.list" mounts)
    ("images"       "image.list"       images))
  "Which frame fills each panel, and where its rows live in the reply.")

(defun cmacs-clawtilla-settings--load (&optional buffer)
  "Refetch the current panel into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (panel (buffer-local-value 'cmacs-clawtilla-settings--panel buffer))
         (spec (assoc panel cmacs-clawtilla-settings--frames)))
    (if (null spec)
        (with-current-buffer buffer (cmacs-clawtilla-settings--draw))
      (cmacs-clawtilla-request
       conn (nth 1 spec) nil
       (lambda (data err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if err
                 (message "clawtilla: %s" err)
               (setq cmacs-clawtilla-settings--rows
                     (cmacs-clawtilla-get data (nth 2 spec)))
               (setq cmacs-clawtilla-settings--extra data)
               (cmacs-clawtilla-settings--draw)))))))))


;;;; Acting.

(defun cmacs-clawtilla-settings-next-panel ()
  "Move to the next settings panel."
  (interactive)
  (let* ((nicks (mapcar #'car cmacs-clawtilla-settings-panels))
         (rest (cdr (member cmacs-clawtilla-settings--panel nicks))))
    (setq cmacs-clawtilla-settings--panel (or (car rest) (car nicks)))
    (setq cmacs-clawtilla-settings--rows nil)
    (cmacs-clawtilla-settings--load)))

(defun cmacs-clawtilla-settings-set ()
  "Change the appearance setting at point."
  (interactive)
  (pcase (cmacs-clawtilla-value-at-point 'setting)
    ('scheme
     (setq cmacs-clawtilla-colour-scheme
           (completing-read "Palette: "
                            (cons "the Emacs theme"
                                  (cmacs-clawtilla-enum-nicks
                                   "appearance-scheme"))
                            nil t))
     (when (equal cmacs-clawtilla-colour-scheme "the Emacs theme")
       (setq cmacs-clawtilla-colour-scheme nil)))
    ('measure
     (let* ((units (cmacs-clawtilla-enum "measure-unit"))
            (nick (completing-read
                   "Measured in: "
                   (mapcar (lambda (u) (alist-get 'nick u)) units) nil t))
            (unit (seq-find (lambda (u) (equal (alist-get 'nick u) nick))
                            units)))
       (setq cmacs-clawtilla-measure-unit nick)
       ;; The bounds are the unit's, so a client cannot offer a width
       ;; the library would refuse.
       (setq cmacs-clawtilla-measure
             (read-number (format "%s (%d-%d): " (alist-get 'label unit)
                                  (alist-get 'min unit) (alist-get 'max unit))
                          (alist-get 'preset unit)))))
    ('descriptions
     (setq cmacs-clawtilla-fleet-show-descriptions
           (not cmacs-clawtilla-fleet-show-descriptions)))
    (_ (user-error "Nothing to change here")))
  (cmacs-clawtilla-settings--draw))

(defun cmacs-clawtilla-settings-connect-account ()
  "Connect an account.

The daemon holds the credential and the agents are given the tools; no
secret is shown here and none is accepted."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "connector.catalog" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((entries (cmacs-clawtilla-get data 'connectors))
                (choice (completing-read
                         "Connect which service: "
                         (mapcar (lambda (e) (alist-get 'id e)) entries)
                         nil t)))
           (cmacs-clawtilla-request
            (cmacs-clawtilla-current) "connector.begin"
            (list (cons 'connector choice))
            (lambda (begun begin-err)
              (if begin-err
                  (message "clawtilla: %s" begin-err)
                (let ((url (cmacs-clawtilla-get begun 'authorize_url)))
                  (if url
                      (progn
                        (kill-new url)
                        (message "clawtilla: open %s to authorise (copied)"
                                 url))
                    (message "clawtilla: %s" "the daemon returned no URL"))
                  (when (buffer-live-p buffer)
                    (cmacs-clawtilla-settings--load buffer))))))))))))

(defun cmacs-clawtilla-settings-revoke ()
  "Revoke the connected account at point."
  (interactive)
  (let* ((row (cmacs-clawtilla-value-at-point 'setting-row))
         (id (and row (or (alist-get 'id row) (alist-get 'name row))))
         (buffer (current-buffer)))
    (unless id (user-error "No account at point"))
    (when (yes-or-no-p (format "Revoke %s? " id))
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "connector.revoke"
       (list (cons 'connector id))
       (lambda (_d e)
         (message "clawtilla: %s" (or e "revoked"))
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-settings--load buffer)))))))

(defun cmacs-clawtilla-settings-health ()
  "Check the integration at point."
  (interactive)
  (let* ((row (cmacs-clawtilla-value-at-point 'setting-row))
         (id (and row (alist-get 'id row))))
    (unless id (user-error "No integration at point"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "integration.health"
     (list (cons 'id id))
     (lambda (data err)
       (message "clawtilla: %s" (or err
                                    (cmacs-clawtilla-get data 'detail)
                                    (cmacs-clawtilla-get data 'health)
                                    "checked"))))))


;;;; Integrations.

(defun cmacs-clawtilla-settings--row-id ()
  "Return the id of the row at point, or signal."
  (let ((row (cmacs-clawtilla-value-at-point 'setting-row)))
    (unless row (user-error "Nothing at point"))
    (or (alist-get 'id row) (alist-get 'name row)
        (user-error "That row has no id"))))

(defun cmacs-clawtilla-settings--reload ()
  "Return a callback that reports an error or reloads this buffer."
  (let ((buffer (current-buffer)))
    (lambda (_data err)
      (if err
          (message "clawtilla: %s" err)
        (when (buffer-live-p buffer)
          (cmacs-clawtilla-settings--load buffer))))))

(defun cmacs-clawtilla-settings-integration-add ()
  "Add an integration.

The types are asked for rather than listed: matrix, email, webhook,
local, cmacs, mcp, notify and connector are the daemon's set today and
a client holding its own copy is one that disagrees after an upgrade."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "integration.types" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((types (cmacs-clawtilla-get data 'types))
                (names (mapcar (lambda (entry)
                                 (if (stringp entry) entry
                                   (or (alist-get 'id entry)
                                       (alist-get 'type entry))))
                               types))
                (type (completing-read "Type: " names nil t))
                (id (read-string "Call it: "))
                (agent (read-string "For which agent (blank for all): ")))
           (cmacs-clawtilla-request
            (cmacs-clawtilla-current) "integration.add"
            (append (list (cons 'id id) (cons 'type type))
                    (unless (string-empty-p agent)
                      (list (cons 'agent agent))))
            (with-current-buffer buffer
              (cmacs-clawtilla-settings--reload)))))))))

(defun cmacs-clawtilla-settings-integration-update ()
  "Change a field of the integration at point."
  (interactive)
  (let* ((id (cmacs-clawtilla-settings--row-id))
         (field (read-string "Field: "))
         (value (read-string (format "%s: " field))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "integration.update"
     (list (cons 'id id) (cons field value))
     (cmacs-clawtilla-settings--reload))))

(defun cmacs-clawtilla-settings-integration-remove ()
  "Remove the integration at point."
  (interactive)
  (let ((id (cmacs-clawtilla-settings--row-id)))
    (when (yes-or-no-p (format "Remove %s? " id))
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "integration.remove" (list (cons 'id id))
       (cmacs-clawtilla-settings--reload)))))

(defun cmacs-clawtilla-settings-notify-test ()
  "Send a test notification through the integration at point."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "integration.notify_test"
   (list (cons 'id (cmacs-clawtilla-settings--row-id)))
   (lambda (_d e) (message "clawtilla: %s" (or e "test sent")))))

(defun cmacs-clawtilla-settings-matrix-login (user password)
  "Sign an integration in to Matrix as USER.

The password is sent to the daemon and never stored here.  It is read
with `read-passwd' so it does not land in the minibuffer history, which
is a file."
  (interactive (list (read-string "Matrix user: ") (read-passwd "Password: ")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "integration.matrix_login"
   (list (cons 'id (cmacs-clawtilla-settings--row-id))
         (cons 'user user) (cons 'password password))
   (lambda (_d e) (message "clawtilla: %s" (or e "signed in")))))

(defun cmacs-clawtilla-settings-matrix-rooms ()
  "List the Matrix rooms the integration at point can see."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "integration.matrix_rooms"
   (list (cons 'id (cmacs-clawtilla-settings--row-id)))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (with-current-buffer (get-buffer-create "*clawtilla matrix rooms*")
         (let ((inhibit-read-only t))
           (erase-buffer)
           (dolist (room (cmacs-clawtilla-get data 'rooms))
             (insert (format "%-40s %s\n"
                             (or (alist-get 'id room) "?")
                             (or (alist-get 'name room) ""))))
           (goto-char (point-min))
           (special-mode))
         (cmacs-clawtilla-display (current-buffer)))))))


;;;; Connectors.

(defun cmacs-clawtilla-settings-connector-await ()
  "Wait for the connection begun earlier to finish."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "connector.await"
   (list (cons 'connector (cmacs-clawtilla-settings--row-id)))
   (cmacs-clawtilla-settings--reload)))

(defun cmacs-clawtilla-settings-connector-key (key)
  "Connect the account at point with an API KEY.

For the services that have no authorisation dance.  The key goes to the
daemon and is never held here; `read-passwd' keeps it out of the
minibuffer history."
  (interactive (list (read-passwd "API key: ")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "connector.key"
   (list (cons 'connector (cmacs-clawtilla-settings--row-id))
         (cons 'key key))
   (cmacs-clawtilla-settings--reload)))

(defun cmacs-clawtilla-settings-connector-refresh ()
  "Refresh the credential of the account at point."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "connector.refresh"
   (list (cons 'connector (cmacs-clawtilla-settings--row-id)))
   (cmacs-clawtilla-settings--reload)))

(defun cmacs-clawtilla-settings-registry-refresh ()
  "Refetch the catalogue of services that can be connected."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "connector.registry_refresh" nil
   (cmacs-clawtilla-settings--reload)))


;;;; Teams.

(defun cmacs-clawtilla-settings-team-create (id name)
  "Make a team called NAME with id ID."
  (interactive (list (read-string "Team id: ") (read-string "Name: ")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "team.create"
   (list (cons 'id id) (cons 'name name))
   (cmacs-clawtilla-settings--reload)))

(defun cmacs-clawtilla-settings-team-set ()
  "Change the team at point.

`id' is refused by the daemon and not offered here: everything refers
to a team by it."
  (interactive)
  (let* ((id (cmacs-clawtilla-settings--row-id))
         (field (completing-read "Change: "
                                 '("name" "description" "lead" "members"
                                   "handles" "color")
                                 nil t))
         (value (read-string (format "%s: " field))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "team.set"
     (list (cons 'id id) (cons field value))
     (cmacs-clawtilla-settings--reload))))

(defun cmacs-clawtilla-settings-team-remove ()
  "Remove the team at point.

The agents that named it are not removed with it -- the daemon answers
how many are now orphaned, and saying that number is the point of
asking."
  (interactive)
  (let ((id (cmacs-clawtilla-settings--row-id))
        (buffer (current-buffer)))
    (when (yes-or-no-p (format "Remove team %s? " id))
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "team.remove" (list (cons 'id id))
       (lambda (data err)
         (if err
             (message "clawtilla: %s" err)
           (let ((orphaned (cmacs-clawtilla-get data 'orphaned)))
             (message "clawtilla: removed%s"
                      (if (and orphaned (> orphaned 0))
                          (format "; %d agent%s now in no team" orphaned
                                  (if (= orphaned 1) "" "s"))
                        "")))
           (when (buffer-live-p buffer)
             (cmacs-clawtilla-settings--load buffer))))))))


;;;; Folders shared with every agent.

(defun cmacs-clawtilla-settings-folder-add (source target mode)
  "Share SOURCE with every agent at TARGET, with MODE."
  (interactive (list (read-directory-name "Share: ")
                     (read-string "Mount at: ")
                     (completing-read "Mode: " '("ro" "rw") nil t "ro")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "defaults.mount.add"
   (list (cons 'source source) (cons 'target target) (cons 'mode mode))
   (cmacs-clawtilla-settings--reload)))

(defun cmacs-clawtilla-settings-folder-remove ()
  "Stop sharing the folder at point with every agent."
  (interactive)
  (let ((row (cmacs-clawtilla-value-at-point 'setting-row)))
    (unless row (user-error "No folder at point"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "defaults.mount.remove"
     (list (cons 'target (alist-get 'target row)))
     (cmacs-clawtilla-settings--reload))))


;;;; Cloud images.

(defun cmacs-clawtilla-settings-image-catalog ()
  "Show the cloud images that can be downloaded."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "image.vm_catalog" nil
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (with-current-buffer (get-buffer-create "*clawtilla images*")
         (let ((inhibit-read-only t))
           (erase-buffer)
           (dolist (image (cmacs-clawtilla-get data 'images))
             (insert (format "%-30s %s\n"
                             (or (alist-get 'id image) "?")
                             (or (alist-get 'description image) ""))))
           (goto-char (point-min))
           (special-mode))
         (cmacs-clawtilla-display (current-buffer)))))))

(defun cmacs-clawtilla-settings-image-download (id)
  "Start downloading cloud image ID."
  (interactive "sImage: ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "image.vm_download" (list (cons 'id id))
   (lambda (_d e) (message "clawtilla: %s" (or e "download started")))))

(defun cmacs-clawtilla-settings-image-cancel ()
  "Stop the download at point."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "image.vm_cancel"
   (list (cons 'id (cmacs-clawtilla-settings--row-id)))
   (cmacs-clawtilla-settings--reload)))

(defun cmacs-clawtilla-settings-image-remove ()
  "Delete the cloud image at point."
  (interactive)
  (let ((id (cmacs-clawtilla-settings--row-id)))
    (when (yes-or-no-p (format "Delete image %s? " id))
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "image.vm_remove" (list (cons 'id id))
       (cmacs-clawtilla-settings--reload)))))

(defun cmacs-clawtilla-settings-image-list ()
  "List the cloud images already downloaded."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "image.vm_list" nil
   (cmacs-clawtilla-settings--reload)))


;;;; Who the operator is.

(defun cmacs-clawtilla-settings-operator ()
  "Show and change what the fleet knows about you.

Agents read this, so it is worth being accurate: the name here is what
they call you."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "operator.get" nil
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (let* ((profile (or (cmacs-clawtilla-get data 'operator) data))
              (field (completing-read
                      "Change: "
                      (mapcar (lambda (pair) (symbol-name (car pair)))
                              profile)
                      nil nil))
              (current (alist-get (intern field) profile))
              (value (read-string (format "%s: " field)
                                  (and current (format "%s" current)))))
         (cmacs-clawtilla-request
          (cmacs-clawtilla-current) "operator.set"
          (list (cons (intern field) value))
          (lambda (_d e) (message "clawtilla: %s" (or e "saved")))))))))

;;;; The mode.

(transient-define-prefix cmacs-clawtilla-settings-menu ()
  "What settings can do."
  ["Panel"
   [("TAB" "next panel" cmacs-clawtilla-settings-next-panel)
    ("g" "refresh" cmacs-clawtilla-refresh)]]
  ["Change"
   [("RET" "change setting" cmacs-clawtilla-settings-set)
    ("h" "check health" cmacs-clawtilla-settings-health)
    ("o" "operator profile" cmacs-clawtilla-settings-operator)]]
  ["Integrations"
   [("A" "add" cmacs-clawtilla-settings-integration-add)
    ("U" "update" cmacs-clawtilla-settings-integration-update)
    ("R" "remove" cmacs-clawtilla-settings-integration-remove)]
   [("n" "send a test" cmacs-clawtilla-settings-notify-test)
    ("M" "matrix sign-in" cmacs-clawtilla-settings-matrix-login)
    ("L" "matrix rooms" cmacs-clawtilla-settings-matrix-rooms)]]
  ["Connectors"
   [("c" "connect an account" cmacs-clawtilla-settings-connect-account)
    ("w" "wait for it" cmacs-clawtilla-settings-connector-await)
    ("K" "connect with a key" cmacs-clawtilla-settings-connector-key)]
   [("f" "refresh credential" cmacs-clawtilla-settings-connector-refresh)
    ("F" "refresh catalogue" cmacs-clawtilla-settings-registry-refresh)
    ("D" "revoke" cmacs-clawtilla-settings-revoke)]]
  ["Teams and folders"
   [("t" "make a team" cmacs-clawtilla-settings-team-create)
    ("e" "change a team" cmacs-clawtilla-settings-team-set)
    ("x" "remove a team" cmacs-clawtilla-settings-team-remove)]
   [("d" "share a folder" cmacs-clawtilla-settings-folder-add)
    ("X" "stop sharing" cmacs-clawtilla-settings-folder-remove)]]
  ["Cloud images"
   [("i" "catalogue" cmacs-clawtilla-settings-image-catalog)
    ("l" "downloaded" cmacs-clawtilla-settings-image-list)]
   [("G" "download" cmacs-clawtilla-settings-image-download)
    ("C" "cancel" cmacs-clawtilla-settings-image-cancel)
    ("Z" "delete" cmacs-clawtilla-settings-image-remove)]])

(defvar cmacs-clawtilla-settings-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-settings-next-panel)
    (define-key map (kbd "RET") #'cmacs-clawtilla-settings-set)
    (define-key map (kbd "c") #'cmacs-clawtilla-settings-connect-account)
    (define-key map (kbd "h") #'cmacs-clawtilla-settings-health)
    (define-key map (kbd "D") #'cmacs-clawtilla-settings-revoke)
    (define-key map (kbd "?") #'cmacs-clawtilla-settings-menu)
    map)
  "Keymap for `cmacs-clawtilla-settings-mode'.")

(define-derived-mode cmacs-clawtilla-settings-mode special-mode
  "Clawtilla-Settings"
  "Major mode for clawtilla settings."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-settings--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-settings (&optional conn)
  "Show the fleet's settings on CONN."
  (interactive)
  (let* ((conn (or conn (cmacs-clawtilla-current)))
         (buffer (get-buffer-create "*clawtilla settings*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-settings-mode)
        (cmacs-clawtilla-settings-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (cmacs-clawtilla-settings--load buffer))
    (cmacs-clawtilla-display buffer)))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-settings-mode-map 'cmacs-clawtilla-settings-mode)

(provide 'cmacs-clawtilla-settings)

;;; cmacs-clawtilla-settings.el ends here
