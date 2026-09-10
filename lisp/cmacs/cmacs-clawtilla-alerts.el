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

;; Alerts, and the unread counts beside each agent.
;;
;; Both rules belong to the library and neither is restated here.
;;
;; Which events are worth interrupting somebody for is
;; `clawt_alert_tier_for_event': four tiers, of which one is "skip", and
;; a client that decided for itself would either alert on every typing
;; indicator or miss the refusals.
;;
;; Whether a message raises an unread count is `clawt_unread_should_count':
;; not your own room, not your own message, not older than the
;; connection.  That last clause is the one everybody gets wrong on
;; their own -- without it, connecting to a fleet marks its whole
;; history unread and the count can never be cleared by reading.
;;
;; An alert that lands while you are looking at the alerts buffer
;; arrives ALREADY READ, which is `clawt_alert_arrives_read'.  Marking it
;; unread would leave a count that reading cannot clear.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(declare-function cmacs-clawtilla--alert-tier "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--alert-arrives-read
                  "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--unread-should-count
                  "cmacs-clawtilla-defuns.c")

(defcustom cmacs-clawtilla-alert-tiers '("notice" "error")
  "Which alert tiers are shown when the buffer is filtered.

The tier names come from the library; this is which of them you want
in front of you, which is a preference and not a rule."
  :type '(repeat string)
  :group 'cmacs-clawtilla)

(defvar cmacs-clawtilla-alerts nil
  "Every alert seen this session, newest first.")

(defvar cmacs-clawtilla-unread (make-hash-table :test 'equal)
  "Unread counts, keyed by room id.")

(defvar cmacs-clawtilla--viewing-room nil
  "The room whose transcript is in front of the operator, if any.")

(defvar-local cmacs-clawtilla-alerts--all nil
  "Whether this buffer shows every tier rather than the filtered set.")

(cl-defstruct (cmacs-clawtilla-alert (:copier nil))
  "One thing worth telling somebody about."
  kind subject tier ts read)


;;;; Taking events in.

(defun cmacs-clawtilla-alerts--surface-showing-p ()
  "Return non-nil if an alerts buffer is on screen."
  (seq-some (lambda (window)
              (with-current-buffer (window-buffer window)
                (derived-mode-p 'cmacs-clawtilla-alerts-mode)))
            (window-list)))

(defun cmacs-clawtilla-alerts--on-event (conn kind data)
  "Consider CONN's event of KIND carrying DATA for an alert."
  (let* ((subject (or (cmacs-clawtilla-get data 'subject)
                      (cmacs-clawtilla-get data 'agent)))
         (ts (or (cmacs-clawtilla-get data 'ts)
                 (cmacs-clawtilla-get data 'timestamp)
                 (truncate (float-time))))
         (tier (cmacs-clawtilla--alert-tier kind subject ts)))
    (unless (equal tier "skip")
      (let ((alert (make-cmacs-clawtilla-alert
                    :kind kind :subject subject :tier tier :ts ts
                    :read (cmacs-clawtilla--alert-arrives-read
                           (cmacs-clawtilla-alerts--surface-showing-p)
                           tier))))
        (push alert cmacs-clawtilla-alerts)
        (cmacs-clawtilla-alerts--redraw)))
    (cmacs-clawtilla-alerts--count-unread conn kind data ts)))

(defun cmacs-clawtilla-alerts--count-unread (conn kind data ts)
  "Raise an unread count for CONN if KIND in DATA at TS earns one."
  (when (member kind '("message" "message.sent"))
    (let* ((room (cmacs-clawtilla-get data 'room))
           (from (cmacs-clawtilla-get data 'sender))
           (connected-at (or (cmacs-clawtilla-connection-connected-at conn)
                             0)))
      (when (and room
                 (cmacs-clawtilla--unread-should-count
                  room cmacs-clawtilla--viewing-room from ts connected-at))
        (puthash room (1+ (gethash room cmacs-clawtilla-unread 0))
                 cmacs-clawtilla-unread)))))

(defun cmacs-clawtilla-mark-read (room)
  "Clear ROOM's unread count."
  (remhash room cmacs-clawtilla-unread))

(defun cmacs-clawtilla-unread-count (room)
  "Return ROOM's unread count."
  (gethash room cmacs-clawtilla-unread 0))


;;;; Drawing.

(defun cmacs-clawtilla-alerts--visible ()
  "Return the alerts this buffer should show."
  (if cmacs-clawtilla-alerts--all
      cmacs-clawtilla-alerts
    (seq-filter (lambda (alert)
                  (member (cmacs-clawtilla-alert-tier alert)
                          cmacs-clawtilla-alert-tiers))
                cmacs-clawtilla-alerts)))

(defun cmacs-clawtilla-alerts--tier-face (tier)
  "Return the face for TIER."
  (pcase tier
    ("error" 'cmacs-clawtilla-error)
    ("notice" 'cmacs-clawtilla-busy)
    (_ 'cmacs-clawtilla-dim)))

(defun cmacs-clawtilla-alerts--draw ()
  "Redraw the alerts buffer."
  (cmacs-clawtilla-ui-preserving
    (let ((alerts (cmacs-clawtilla-alerts--visible)))
      (insert (propertize "Alerts" 'face 'cmacs-clawtilla-heading)
              "  "
              (cmacs-clawtilla-dim
               (if cmacs-clawtilla-alerts--all
                   "every tier"
                 (format "%s only -- `a' shows everything"
                         (string-join cmacs-clawtilla-alert-tiers ", "))))
              "\n\n")
      (if (null alerts)
          (insert "  " (cmacs-clawtilla-dim "nothing to report") "\n")
        (dolist (alert alerts)
          (cmacs-clawtilla-insert-section
           :type 'alert :value alert :level 1
           :heading
           (concat
            (if (cmacs-clawtilla-alert-read alert)
                "  " (propertize "• " 'face 'cmacs-clawtilla-unread))
            (propertize (format "%-8s" (cmacs-clawtilla-alert-tier alert))
                        'face (cmacs-clawtilla-alerts--tier-face
                               (cmacs-clawtilla-alert-tier alert)))
            " "
            (cmacs-clawtilla-dim
             (or (cmacs-clawtilla--time-label
                  (cmacs-clawtilla-alert-ts alert)) ""))
            "  "
            (cmacs-clawtilla-alert-kind alert)
            (when (cmacs-clawtilla-alert-subject alert)
              (concat "  " (propertize (cmacs-clawtilla-alert-subject alert)
                                       'face 'cmacs-clawtilla-agent))))))))))

(defun cmacs-clawtilla-alerts--redraw ()
  "Redraw every alerts buffer."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'cmacs-clawtilla-alerts-mode)
        (cmacs-clawtilla-alerts--draw)))))


;;;; Acting.

(defun cmacs-clawtilla-alerts-toggle-filter ()
  "Show every tier, or only the ones asked for."
  (interactive)
  (setq cmacs-clawtilla-alerts--all (not cmacs-clawtilla-alerts--all))
  (cmacs-clawtilla-alerts--draw))

(defun cmacs-clawtilla-alerts-mark-all-read ()
  "Mark every alert read."
  (interactive)
  (dolist (alert cmacs-clawtilla-alerts)
    (setf (cmacs-clawtilla-alert-read alert) t))
  (cmacs-clawtilla-alerts--draw))

(defun cmacs-clawtilla-alerts-clear ()
  "Forget every alert.

Only this client's record of them.  The event log is the daemon's and
is untouched -- `event.list' still has all of it."
  (interactive)
  (setq cmacs-clawtilla-alerts nil)
  (cmacs-clawtilla-alerts--draw))

(defun cmacs-clawtilla-alerts-history ()
  "Load the daemon's own event log into this buffer.

This client only sees what happened while it was connected.  The log is
the daemon's and goes back further, which is the difference between
\"nothing happened\" and \"I was not here\"."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "event.list" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (dolist (event (reverse (cmacs-clawtilla-get data 'events)))
           (let* ((kind (or (alist-get 'kind event) ""))
                  (subject (alist-get 'subject event))
                  (ts (or (alist-get 'ts event)
                          (alist-get 'timestamp event) 0))
                  (tier (cmacs-clawtilla--alert-tier kind subject ts)))
             (unless (equal tier "skip")
               ;; History arrives read.  It already happened, and a
               ;; count for things from before you connected is one
               ;; that reading cannot clear.
               (push (make-cmacs-clawtilla-alert
                      :kind kind :subject subject :tier tier :ts ts
                      :read t)
                     cmacs-clawtilla-alerts))))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (cmacs-clawtilla-alerts--draw))))))))

(defun cmacs-clawtilla-alerts-visit ()
  "Open what the alert at point is about."
  (interactive)
  (let* ((alert (cmacs-clawtilla-value-at-point 'alert))
         (subject (and alert (cmacs-clawtilla-alert-subject alert))))
    (unless subject (user-error "That alert names nothing to open"))
    (setf (cmacs-clawtilla-alert-read alert) t)
    (cmacs-clawtilla-chat (cmacs-clawtilla-current) subject)))

(declare-function cmacs-clawtilla-chat "cmacs-clawtilla-chat")


;;;; The mode.

(transient-define-prefix cmacs-clawtilla-alerts-menu ()
  "What the alerts buffer can do."
  ["Alerts"
   [("RET" "open what it is about" cmacs-clawtilla-alerts-visit)
    ("a" "show every tier" cmacs-clawtilla-alerts-toggle-filter)]
   [("m" "mark all read" cmacs-clawtilla-alerts-mark-all-read)
    ("k" "forget them" cmacs-clawtilla-alerts-clear)
    ("H" "load the daemon's log" cmacs-clawtilla-alerts-history)]])

(defvar cmacs-clawtilla-alerts-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map cmacs-clawtilla-common-map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-alerts-visit)
    (define-key map (kbd "a") #'cmacs-clawtilla-alerts-toggle-filter)
    (define-key map (kbd "m") #'cmacs-clawtilla-alerts-mark-all-read)
    (define-key map (kbd "k") #'cmacs-clawtilla-alerts-clear)
    (define-key map (kbd "H") #'cmacs-clawtilla-alerts-history)
    (define-key map (kbd "?") #'cmacs-clawtilla-alerts-menu)
    map)
  "Keymap for `cmacs-clawtilla-alerts-mode'.")

(define-derived-mode cmacs-clawtilla-alerts-mode special-mode
  "Clawtilla-Alerts"
  "Major mode for clawtilla alerts."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              #'cmacs-clawtilla-alerts--draw)
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-alerts (&optional conn)
  "Show the alerts for CONN."
  (interactive)
  (let* ((conn (or conn (cmacs-clawtilla-current)))
         (buffer (get-buffer-create "*clawtilla alerts*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-alerts-mode)
        (cmacs-clawtilla-alerts-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (cmacs-clawtilla-alerts--draw))
    (pop-to-buffer buffer)))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-alerts--on-event)

(provide 'cmacs-clawtilla-alerts)

;;; cmacs-clawtilla-alerts.el ends here
