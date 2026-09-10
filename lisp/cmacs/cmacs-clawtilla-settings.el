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


;;;; The mode.

(transient-define-prefix cmacs-clawtilla-settings-menu ()
  "What settings can do."
  ["Panel"
   [("TAB" "next panel" cmacs-clawtilla-settings-next-panel)
    ("g" "refresh" cmacs-clawtilla-refresh)]]
  ["Change"
   [("RET" "change setting" cmacs-clawtilla-settings-set)
    ("h" "check health" cmacs-clawtilla-settings-health)]
   [("c" "connect an account" cmacs-clawtilla-settings-connect-account)
    ("D" "revoke" cmacs-clawtilla-settings-revoke)]])

(defvar cmacs-clawtilla-settings-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map cmacs-clawtilla-common-map)
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
    (pop-to-buffer buffer)))

(provide 'cmacs-clawtilla-settings)

;;; cmacs-clawtilla-settings.el ends here
