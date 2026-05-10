;;; cmacs-notify.el --- Desktop notifications via D-Bus  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 4 outbound notification helper.  Routes (cmacs-notify ...)
;; calls through org.freedesktop.Notifications so cmacs can send
;; real desktop toasts (matching cmacsgi's `Message' but escaping
;; the echo area).

;;; Code:

(require 'dbus)

(defcustom cmacs-notify-app-name "cmacs"
  "Application name passed to org.freedesktop.Notifications."
  :type 'string :group 'cmacs-dbus)

(defcustom cmacs-notify-default-icon "text-editor"
  "Default icon (themed name) for cmacs notifications."
  :type 'string :group 'cmacs-dbus)

(defcustom cmacs-notify-default-timeout -1
  "Default expiration timeout in milliseconds.
-1 lets the notification daemon decide; 0 means never expire."
  :type 'integer :group 'cmacs-dbus)

;;;###autoload
(defun cmacs-notify (summary &optional body urgency icon timeout actions)
  "Send a desktop notification via D-Bus.
SUMMARY is the title.  BODY is optional detail text.  URGENCY is one
of `low', `normal', or `critical'.  ICON is a themed icon name.
TIMEOUT is in milliseconds (-1 = daemon default, 0 = never expire).
ACTIONS is a list of (KEY LABEL) pairs that surface as buttons.
Returns the notification id on success."
  (interactive "sSummary: \nsBody: ")
  (let* ((urg (cl-case urgency
                (low      0)
                (critical 2)
                (t        1)))
         (hints `((:dict-entry "urgency" (:variant :byte ,urg))))
         (action-vec (apply #'vector
                            (apply #'append
                                   (mapcar (lambda (p) (list (car p) (cadr p)))
                                           actions)))))
    (dbus-call-method
     :session "org.freedesktop.Notifications"
     "/org/freedesktop/Notifications"
     "org.freedesktop.Notifications" "Notify"
     cmacs-notify-app-name
     :uint32 0
     (or icon cmacs-notify-default-icon)
     summary
     (or body "")
     action-vec
     hints
     :int32 (or timeout cmacs-notify-default-timeout))))

;;;###autoload
(defun cmacs-notify-close (id)
  "Close a notification by ID (returned from `cmacs-notify')."
  (dbus-call-method
   :session "org.freedesktop.Notifications"
   "/org/freedesktop/Notifications"
   "org.freedesktop.Notifications" "CloseNotification"
   :uint32 id))

(provide 'cmacs-notify)
;;; cmacs-notify.el ends here
