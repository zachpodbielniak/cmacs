;;; cmacs-gowl.el --- Gowl compositor control  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp interface for the Gowl Wayland compositor.
;;
;; C primitives available:
;;   `gowl-start'         -- start the compositor
;;   `gowl-stop'          -- stop the compositor
;;   `gowl-running-p'     -- check if compositor is running
;;   `gowl-list-clients'  -- list managed window clients
;;   `gowl-focus-client'  -- focus a client window
;;   `gowl-spawn'         -- launch a Wayland client
;;   `gowl-list-monitors' -- list connected monitors
;;   `gowl-view-tags'     -- switch tag view
;;   `gowl-set-layout'    -- set layout on monitor
;;   `gowl-client-info'   -- get client info alist
;;   `gowl-move-client'   -- move client to x,y
;;   `gowl-resize-client' -- resize client to w,h
;;   `gowl-set-tags'      -- set tags bitmask on client
;;   `gowl-close-client'  -- close client window
;;
;; This file provides:
;;   - `cmacs-gowl-mode'  -- global minor mode
;;   - Customization for borders, layouts, autostart
;;   - Interactive window management commands

;;; Code:

(require 'cl-lib)

(defgroup cmacs-gowl nil
  "Gowl Wayland compositor integration."
  :group 'cmacs
  :prefix "cmacs-gowl-")

;;; Customization

(defcustom cmacs-gowl-border-width 2
  "Border width in pixels for Gowl windows."
  :type 'integer
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-border-color-focus "#5e81ac"
  "Border color for the focused window (hex string)."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-border-color-unfocus "#4c566a"
  "Border color for unfocused windows (hex string)."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-layouts '("tile" "monocle" "float")
  "List of available layout names."
  :type '(repeat string)
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-autostart nil
  "List of commands to spawn when `cmacs-gowl-mode' is enabled.
Each element is a string command to launch as a Wayland client.

Example:
  (setq cmacs-gowl-autostart
        \\='(\"foot\" \"waybar\"))"
  :type '(repeat string)
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-default-layout "tile"
  "Default layout to apply when the compositor starts."
  :type 'string
  :group 'cmacs-gowl)

;;; Internal state

(defvar cmacs-gowl--active nil
  "Non-nil when `cmacs-gowl-mode' is active.")

(defvar cmacs-gowl--autostart-launched nil
  "Non-nil if autostart programs have already been launched.")

;;; Internal functions

(defun cmacs-gowl--start ()
  "Start the Gowl compositor and apply configuration.
When launched with --gowl, the compositor is already running and
Emacs is rendering inside it.  This function ensures the dispatch
thread is running and applies configuration."
  (gowl-start)  ;; no-op if already running via --gowl
  ;; Apply default layout.
  (when cmacs-gowl-default-layout
    (gowl-set-layout cmacs-gowl-default-layout))
  ;; Ensure Emacs has keyboard focus.  The client may have mapped
  ;; before focus was properly assigned, so explicitly focus it.
  (run-with-timer 0.5 nil
    (lambda ()
      (when (gowl-running-p)
        (let ((clients (gowl-list-clients)))
          (when clients
            (gowl-focus-client (car clients)))))))
  ;; Launch autostart programs (only once per session).
  (unless cmacs-gowl--autostart-launched
    (dolist (cmd cmacs-gowl-autostart)
      (condition-case err
          (gowl-spawn cmd)
        (gowl-error
         (message "Gowl autostart failed for %S: %s"
                  cmd (cadr err)))))
    (setq cmacs-gowl--autostart-launched t))
  (setq cmacs-gowl--active t))

(defun cmacs-gowl--stop ()
  "Stop the Gowl compositor."
  (when (gowl-running-p)
    (gowl-stop))
  (setq cmacs-gowl--active nil))

;;; Global minor mode

;;;###autoload
(define-minor-mode cmacs-gowl-mode
  "Global minor mode for Gowl Wayland compositor control.

When enabled, starts the embedded Gowl compositor (if not already
running), applies configuration from the `cmacs-gowl' customization
group, and launches autostart programs.

When disabled, stops the compositor."
  :global t
  :lighter " Gowl"
  :group 'cmacs-gowl
  (if cmacs-gowl-mode
      (cmacs-gowl--start)
    (cmacs-gowl--stop)))

;;; Interactive window management commands

(defun cmacs-gowl-list-windows ()
  "Display a list of managed Gowl windows."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((clients (gowl-list-clients)))
    (if (null clients)
        (message "No windows")
      (with-help-window "*Gowl Windows*"
        (princ (format "Gowl Windows (%d):\n\n" (length clients)))
        (princ (format "%-30s %-20s %-8s %s\n"
                       "Title" "App ID" "Tags" "Geometry"))
        (princ (make-string 78 ?-))
        (princ "\n")
        (dolist (client clients)
          (let ((info (gowl-client-info client)))
            (princ (format "%-30s %-20s %-8s %s\n"
                           (truncate-string-to-width
                            (cdr (assq 'title info)) 30)
                           (truncate-string-to-width
                            (cdr (assq 'app-id info)) 20)
                           (cdr (assq 'tags info))
                           (cdr (assq 'geometry info))))))))))

(defun cmacs-gowl-focus-window ()
  "Interactively select and focus a Gowl window."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((clients (gowl-list-clients))
         (candidates
          (mapcar (lambda (client)
                    (let ((info (gowl-client-info client)))
                      (cons (format "%s [%s]"
                                    (cdr (assq 'title info))
                                    (cdr (assq 'app-id info)))
                            client)))
                  clients))
         (choice (completing-read "Focus window: " candidates nil t))
         (client (cdr (assoc choice candidates))))
    (when client
      (gowl-focus-client client))))

(defun cmacs-gowl-close-window ()
  "Interactively select and close a Gowl window."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((clients (gowl-list-clients))
         (candidates
          (mapcar (lambda (client)
                    (let ((info (gowl-client-info client)))
                      (cons (format "%s [%s]"
                                    (cdr (assq 'title info))
                                    (cdr (assq 'app-id info)))
                            client)))
                  clients))
         (choice (completing-read "Close window: " candidates nil t))
         (client (cdr (assoc choice candidates))))
    (when client
      (gowl-close-client client))))

(defun cmacs-gowl-spawn-command (command)
  "Launch COMMAND as a Wayland client in the Gowl compositor."
  (interactive "sSpawn command: ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (gowl-spawn command))

(defun cmacs-gowl-view-tag (tag)
  "Switch to TAG (1-9)."
  (interactive "nTag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (when (and (>= tag 1) (<= tag 9))
    (gowl-view-tags (ash 1 (1- tag)))))

(defun cmacs-gowl-send-to-tag (tag)
  "Send the focused client to TAG (1-9)."
  (interactive "nSend to tag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((clients (gowl-list-clients)))
    ;; Find focused client (first in list by convention).
    (when (and clients (>= tag 1) (<= tag 9))
      (gowl-set-tags (car clients) (ash 1 (1- tag))))))

(defun cmacs-gowl-set-layout (layout)
  "Set the current monitor LAYOUT."
  (interactive
   (list (completing-read "Layout: " cmacs-gowl-layouts nil t)))
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (gowl-set-layout layout))

(defun cmacs-gowl-list-monitors ()
  "Display information about connected monitors."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((monitors (gowl-list-monitors)))
    (if (null monitors)
        (message "No monitors detected")
      (message "Gowl: %d monitor(s) connected" (length monitors)))))

(provide 'cmacs-gowl)
;;; cmacs-gowl.el ends here
