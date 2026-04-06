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

;;;###autoload
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
      (with-help-window "*Gowl Monitors*"
        (princ (format "Gowl Monitors (%d):\n\n" (length monitors)))
        (princ (format "%-14s %-18s %-10s %-6s %-8s %s\n"
                       "Name" "Mode" "Position" "Scale" "Status" "Transform"))
        (princ (make-string 78 ?-))
        (princ "\n")
        (dolist (m monitors)
          (let* ((info (gowl-monitor-info m))
                 (name (cdr (assq 'name info)))
                 (geo (cdr (assq 'geometry info)))
                 (mode (gowl-monitor-current-mode m))
                 (scale (gowl-monitor-scale m))
                 (enabled (gowl-monitor-enabled-p m))
                 (xform (gowl-monitor-transform m)))
            (princ (format "%-14s %-18s %-10s %-6.1f %-8s %s\n"
                           name
                           (if mode
                               (format "%dx%d@%dHz"
                                       (nth 0 mode) (nth 1 mode)
                                       (/ (nth 2 mode) 1000))
                             "unknown")
                           (format "%d,%d" (nth 0 geo) (nth 1 geo))
                           scale
                           (if enabled "on" "off")
                           xform))))))))

(defun cmacs-gowl--read-monitor (prompt)
  "Read a monitor name with completion using PROMPT."
  (let* ((monitors (gowl-list-monitors))
         (names (mapcar (lambda (m)
                          (cdr (assq 'name (gowl-monitor-info m))))
                        monitors))
         (name (completing-read prompt names nil t)))
    (gowl-find-monitor name)))

(defun cmacs-gowl-monitor-info ()
  "Display detailed info for a selected monitor."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (info (gowl-monitor-info mon)))
    (with-help-window "*Gowl Monitor Info*"
      (dolist (kv info)
        (princ (format "%-15s %S\n" (car kv) (cdr kv)))))))

(defun cmacs-gowl-set-resolution ()
  "Set resolution for a selected monitor from available modes."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (modes (gowl-monitor-modes mon))
         (choices (mapcar (lambda (m)
                            (format "%dx%d@%dHz"
                                    (nth 0 m) (nth 1 m)
                                    (/ (nth 2 m) 1000)))
                          modes))
         (choice (completing-read "Mode: " choices nil t))
         (idx (cl-position choice choices :test #'string=))
         (mode (nth idx modes)))
    (if (gowl-set-monitor-mode (nth 0 mode) (nth 1 mode) (nth 2 mode) mon)
        (message "Mode set to %s" choice)
      (message "Failed to set mode"))))

(defun cmacs-gowl-set-scale (scale)
  "Set SCALE factor for a selected monitor."
  (interactive "nScale factor: ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((mon (cmacs-gowl--read-monitor "Monitor: ")))
    (if (gowl-set-monitor-scale scale mon)
        (message "Scale set to %.1f" scale)
      (message "Failed to set scale"))))

(defun cmacs-gowl-set-transform ()
  "Set transform for a selected monitor."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (transforms '("normal" "90" "180" "270"
                        "flipped" "flipped-90" "flipped-180" "flipped-270"))
         (choice (completing-read "Transform: " transforms nil t))
         (sym (intern choice)))
    (if (gowl-set-monitor-transform sym mon)
        (message "Transform set to %s" choice)
      (message "Failed to set transform"))))

(defun cmacs-gowl-toggle-monitor ()
  "Toggle enable/disable for a selected monitor."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (enabled (gowl-monitor-enabled-p mon)))
    (if (gowl-set-monitor-enabled (not enabled) mon)
        (message "Monitor %s"
                 (if enabled "disabled" "enabled"))
      (message "Failed to toggle monitor"))))


;;; ── Client embedding ──────────────────────────────────────────────
;;
;; Embeds Wayland clients as xwidget buffer content.  Each embedded
;; client is backed by a gowl-type xwidget whose GtkDrawingArea is
;; managed by the Emacs display engine (XWIDGET_GLYPH).  The C layer
;; reads pixels from the client's wlr_texture on each surface commit
;; and paints them via Cairo.  Mouse and keyboard events on the widget
;; are forwarded to the Wayland client through the compositor's wlr_seat.

(define-derived-mode gowl-embed-mode special-mode "GowlEmbed"
  "Major mode for buffers displaying an embedded Wayland client.
The client renders as an xwidget glyph — real buffer content
managed by the Emacs display engine.

In Evil, pressing \\`i' or \\`a' gives keyboard focus to the
embedded client.  Pressing ESC in the embedded client returns
control to Emacs."
  :group 'cmacs-gowl
  (setq-local cursor-type nil)
  (setq-local mode-line-buffer-identification
              (propertize "%b" 'face 'mode-line-buffer-id))
  (when (boundp 'doom-real-buffer-p)
    (setq-local doom-real-buffer-p t)))

(with-eval-after-load 'evil
  (eval '(evil-define-key 'normal gowl-embed-mode-map
           "i" #'gowl-embed--enter-client
           "a" #'gowl-embed--enter-client
           "A" #'gowl-embed--enter-client
           "I" #'gowl-embed--enter-client
           "o" #'gowl-embed--enter-client
           "O" #'gowl-embed--enter-client
           (kbd "RET") #'gowl-embed--enter-client)))

(defun gowl-embed--enter-client ()
  "Give keyboard focus to the embedded client in the current buffer."
  (interactive)
  (when gowl-embedded-client
    (gowl-embed-focus gowl-embedded-client)))

(defvar-local gowl-embedded-client nil
  "The gowl client embedded in this buffer, or nil.")

(defvar-local gowl-embedded-client-pid nil
  "PID of the embedded client, cached to avoid dereferencing dead objects.")

(defvar-local gowl-embed--xwidget nil
  "The xwidget displaying the embedded client, or nil.")

(defvar gowl-embed--pending nil
  "Alist of (PID . WINDOW) for spawned clients awaiting map.")

(defvar gowl-embed--pending-timer nil
  "Timer polling for pending embeds.")

(defvar gowl-embed--health-timer nil
  "Timer checking if embedded clients are still alive.")

(defun gowl-embed--do-embed (client window)
  "Embed CLIENT as xwidget content in WINDOW's buffer."
  (with-selected-window window
    (let* ((buf (window-buffer window))
           (w (window-body-width window t))
           (h (window-body-height window t))
           (xw (gowl-make-xwidget client w h buf)))
      (setq-local gowl-embedded-client client)
      (setq-local gowl-embedded-client-pid (gowl-client-pid client))
      (setq-local gowl-embed--xwidget xw)
      ;; Mark as embedded so arrange() skips it.
      (gowl-set-client-embedded client t)
      (gowl-set-client-border-width client 0)
      (gowl-set-client-visible client nil)
      ;; Insert xwidget as buffer content.
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize " " 'display (list 'xwidget :xwidget xw))))
      (gowl-embed--ensure-health-timer))))

(defun gowl-embed--setup-buffer (buf command)
  "Initialize BUF as an embed buffer for COMMAND."
  (with-current-buffer buf
    (gowl-embed-mode)
    ;; Placeholder until client maps and xwidget is inserted.
    (let ((inhibit-read-only t))
      (insert (propertize (format " Embedding %s…" command)
                          'face 'shadow)))))

(defun gowl-embed--display-buffer (buf window)
  "Display BUF in WINDOW and mark it dedicated."
  (set-window-buffer window buf)
  (set-window-dedicated-p window t)
  (when (bound-and-true-p persp-mode)
    (persp-add-buffer buf)))

(defun gowl-embed--check-pending ()
  "Match pending embeds to newly mapped gowl clients.
First tries PID matching (works for direct processes).  If that
fails, falls back to matching any embedded client that doesn't
have an embed view yet (catches flatpak/sandbox launchers)."
  (if (null gowl-embed--pending)
      (progn
        (when gowl-embed--pending-timer
          (cancel-timer gowl-embed--pending-timer)
          (setq gowl-embed--pending-timer nil)))
    (let ((clients (gowl-list-clients)))
      (dolist (entry (copy-sequence gowl-embed--pending))
        (let* ((pid (car entry))
               (window (cdr entry))
               ;; Try PID match first.
               (client (seq-find
                        (lambda (c) (= (gowl-client-pid c) pid))
                        clients))
               ;; Fallback: any embedded client without a view yet.
               ;; The client-map callback marks it embedded; this
               ;; catches flatpak/sandbox where spawn PID != client PID.
               (client (or client
                          (seq-find
                           (lambda (c)
                             (and (alist-get 'embedded (gowl-client-info c))
                                  (not (gowl-embed-view-p c))))
                           clients))))
          (when client
            (setq gowl-embed--pending (delq entry gowl-embed--pending))
            (when (window-live-p window)
              (gowl-embed--do-embed client window))))))))

(defun gowl-embed--start-pending-timer ()
  "Start the timer that checks for pending embeds."
  (unless gowl-embed--pending-timer
    (setq gowl-embed--pending-timer
          (run-with-timer 0.1 0.1 #'gowl-embed--check-pending))))

(defun gowl-embed--check-health ()
  "Kill embed buffers whose clients have exited.
Uses the cached PID to avoid dereferencing dead client objects
whose underlying wlr resources may already be freed."
  (let ((client-pids (when (gowl-running-p)
                       (mapcar #'gowl-client-pid (gowl-list-clients))))
        (has-embeds nil))
    (dolist (buf (buffer-list))
      (when-let ((pid (buffer-local-value 'gowl-embedded-client-pid buf)))
        (if (memq pid client-pids)
            (setq has-embeds t)
          ;; Client is gone — clean up without touching the dead object.
          (with-current-buffer buf
            (setq gowl-embedded-client nil)
            (setq gowl-embedded-client-pid nil)
            (let ((win (get-buffer-window buf t)))
              (when win (set-window-dedicated-p win nil)))
            (kill-buffer buf)))))
    (unless has-embeds
      (when gowl-embed--health-timer
        (cancel-timer gowl-embed--health-timer)
        (setq gowl-embed--health-timer nil)))))

(defun gowl-embed--ensure-health-timer ()
  "Start the health-check timer if not running."
  (unless gowl-embed--health-timer
    (setq gowl-embed--health-timer
          (run-with-timer 1 1 #'gowl-embed--check-health))))

(defun gowl-embed--on-kill-buffer ()
  "Close the embedded client when its buffer is killed."
  (when gowl-embedded-client
    (let ((win (get-buffer-window (current-buffer) t))
          (client gowl-embedded-client)
          (pid gowl-embedded-client-pid)
          (live-pids (when (gowl-running-p)
                       (mapcar #'gowl-client-pid (gowl-list-clients)))))
      (when win (set-window-dedicated-p win nil))
      ;; Only call gowl functions if the client is still alive.
      (when (and pid (memq pid live-pids))
        (condition-case nil
            (gowl-close-client client)
          (error nil)))
      (setq gowl-embedded-client nil)
      (setq gowl-embedded-client-pid nil)
      (setq gowl-embed--xwidget nil))))

(defun gowl-embed--adjust-size (frame)
  "Resize gowl xwidgets to match their window dimensions in FRAME."
  (walk-windows
   (lambda (win)
     (when-let* ((xw (buffer-local-value 'gowl-embed--xwidget
                                          (window-buffer win))))
       (let ((w (window-body-width win t))
             (h (window-body-height win t)))
         (when (and (> w 0) (> h 0))
           (xwidget-resize xw w h)
           (when-let* ((client (buffer-local-value 'gowl-embedded-client
                                                    (window-buffer win))))
             (gowl-resize-client client w h))))))
   'no-minibuf frame))

(add-hook 'kill-buffer-hook #'gowl-embed--on-kill-buffer)
(add-hook 'window-size-change-functions #'gowl-embed--adjust-size)

;;;###autoload
(defun gowl-embed (command)
  "Spawn COMMAND and embed it as xwidget content in the current window.
The Wayland client renders as a gowl xwidget glyph — real buffer
content managed by the Emacs display engine.  The surface resizes
with the window and hides/shows with buffer switching."
  (interactive "sEmbed: ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((pid (gowl-spawn command))
         (buf (generate-new-buffer (format "*gowl: %s*" command)))
         (win (selected-window)))
    (gowl-prefloat-pid pid)
    (gowl-embed-expect-client)
    (gowl-embed--setup-buffer buf command)
    (gowl-embed--display-buffer buf win)
    (push (cons pid win) gowl-embed--pending)
    (gowl-embed--start-pending-timer)))

;;;###autoload
(defun gowl-embed-client (client)
  "Embed an existing gowl CLIENT in the current Emacs window."
  (interactive
   (list (let* ((clients (gowl-list-clients))
                (candidates
                 (mapcar (lambda (c)
                           (let ((info (gowl-client-info c)))
                             (cons (format "%s — %s"
                                           (cdr (assq 'title info))
                                           (cdr (assq 'app-id info)))
                                   c)))
                         clients))
                (choice (completing-read "Embed client: " candidates nil t)))
           (cdr (assoc choice candidates)))))
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((info (gowl-client-info client))
         (title (or (cdr (assq 'title info)) "client"))
         (buf (generate-new-buffer (format "*gowl: %s*" title)))
         (win (selected-window)))
    (gowl-embed--setup-buffer buf title)
    (gowl-embed--display-buffer buf win)
    (gowl-embed--do-embed client win)))

(defun gowl-unembed ()
  "Release the embedded client from the current buffer."
  (interactive)
  (when-let ((client gowl-embedded-client))
    (setq gowl-embedded-client nil)
    (setq gowl-embed--xwidget nil)
    (set-window-dedicated-p (selected-window) nil)
    (gowl-set-client-embedded client nil)
    (gowl-set-client-border-width client 1)
    (gowl-reparent-client client 2)
    (gowl-arrange)
    (kill-buffer (current-buffer))))

(provide 'cmacs-gowl)
;;; cmacs-gowl.el ends here
