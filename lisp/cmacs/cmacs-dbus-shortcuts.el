;;; cmacs-dbus-shortcuts.el --- xdg-desktop-portal GlobalShortcuts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 5 GlobalShortcuts portal client.  Lets cmacs register
;; system-wide hotkeys that fire even when emacs isn't focused.
;; Useful for: "capture screenshot to current buffer", "start
;; dictation buffer", "raise emacs to front".
;;
;; Spec: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html
;;
;; The portal API is async + handle-based; this wrapper hides the
;; Request handle dance and presents a simple
;; (cmacs-global-shortcut KEY COMMAND) API.

;;; Code:

(require 'dbus)

(defvar cmacs-dbus-shortcuts--session nil
  "GlobalShortcuts session object path returned by the portal.")

(defvar cmacs-dbus-shortcuts--registry nil
  "Alist of (SHORTCUT-ID . COMMAND) to dispatch on Activated.")

(defconst cmacs-dbus-shortcuts--bus "org.freedesktop.portal.Desktop")
(defconst cmacs-dbus-shortcuts--path "/org/freedesktop/portal/desktop")
(defconst cmacs-dbus-shortcuts--iface "org.freedesktop.portal.GlobalShortcuts")

(defun cmacs-dbus-shortcuts--ensure-session ()
  "Open a portal GlobalShortcuts session, return its object path."
  (unless cmacs-dbus-shortcuts--session
    (setq cmacs-dbus-shortcuts--session
          (dbus-call-method
           :session cmacs-dbus-shortcuts--bus
           cmacs-dbus-shortcuts--path
           cmacs-dbus-shortcuts--iface
           "CreateSession"
           '(:array :signature "{sv}"
                    (:dict-entry "session_handle_token"
                                 (:variant "cmacs1")))))
    (dbus-register-signal
     :session cmacs-dbus-shortcuts--bus
     cmacs-dbus-shortcuts--session
     cmacs-dbus-shortcuts--iface
     "Activated"
     #'cmacs-dbus-shortcuts--on-activated))
  cmacs-dbus-shortcuts--session)

(defun cmacs-dbus-shortcuts--on-activated (session-handle shortcut-id _ts _opts)
  "Portal Activated signal handler -- dispatch to user command."
  (when-let ((cmd (cdr (assoc shortcut-id cmacs-dbus-shortcuts--registry))))
    (cond
     ((commandp cmd) (call-interactively cmd))
     ((functionp cmd) (funcall cmd))
     (t (eval cmd t)))))

;;;###autoload
(defun cmacs-global-shortcut (id description preferred-trigger command)
  "Register ID (a string) as a desktop-wide hotkey running COMMAND.
DESCRIPTION is the human-readable label shown in the
shortcut-binding UI.  PREFERRED-TRIGGER is a portal trigger string
like \"<Ctrl><Alt>e\".  COMMAND is a function symbol or
callable -- invoked when the user activates the shortcut anywhere
on the desktop, even when emacs is not focused."
  (cmacs-dbus-shortcuts--ensure-session)
  (push (cons id command) cmacs-dbus-shortcuts--registry)
  (dbus-call-method
   :session cmacs-dbus-shortcuts--bus
   cmacs-dbus-shortcuts--path
   cmacs-dbus-shortcuts--iface
   "BindShortcuts"
   cmacs-dbus-shortcuts--session
   `((:struct ,id
              ((:dict-entry "description" (:variant ,description))
               (:dict-entry "preferred_trigger" (:variant ,preferred-trigger)))))
   "" '()))

;;;###autoload
(defun cmacs-global-shortcut-remove (id)
  "Unbind a previously-registered global shortcut by ID."
  (setq cmacs-dbus-shortcuts--registry
        (assoc-delete-all id cmacs-dbus-shortcuts--registry)))

(provide 'cmacs-dbus-shortcuts)
;;; cmacs-dbus-shortcuts.el ends here
