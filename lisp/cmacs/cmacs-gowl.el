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
      (message "Gowl: %d monitor(s) connected" (length monitors)))))


;;; ── Client embedding ──────────────────────────────────────────────
;;
;; Embeds Wayland clients into Emacs buffer windows.  A GtkDrawingArea
;; is added to the Emacs frame's GTK container and positioned over the
;; buffer window's body area.  The C layer reads pixels from the
;; client's wlr_texture on each surface commit and paints them into
;; the GtkDrawingArea via Cairo.  Mouse and keyboard events on the
;; widget are forwarded to the Wayland client through the compositor's
;; wlr_seat.
;;
;; Compositor overlay: the embedded client's scene node is reparented
;; into Emacs's scene tree and positioned over the window body area.
;; The compositor renders it directly — no pixel copying, no EGL
;; conflicts, no swapchain issues.  Input is routed by the
;; compositor's focus-follows-mouse.

(define-derived-mode gowl-embed-mode special-mode "GowlEmbed"
  "Major mode for buffers displaying an embedded Wayland client.
The buffer is a placeholder; the actual client renders as a
compositor overlay positioned over this window's body area.

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

(defvar gowl-embed--pending nil
  "Alist of (PID . WINDOW) for spawned clients awaiting map.")

(defvar gowl-embed--pending-timer nil
  "Timer polling for pending embeds.")

(defvar gowl-embed--health-timer nil
  "Timer checking if embedded clients are still alive.")

(defvar gowl-embed--syncing nil
  "Non-nil while `gowl-embed--sync-all' is running (recursion guard).")

(defun gowl-embed--body-geometry (window)
  "Return (X Y W H) of WINDOW's body area in frame-relative pixels."
  (let ((edges (window-body-pixel-edges window)))
    (list (nth 0 edges)
          (nth 1 edges)
          (- (nth 2 edges) (nth 0 edges))
          (- (nth 3 edges) (nth 1 edges)))))

(defun gowl-embed--sync-position (window)
  "Reposition the embedded client overlay for WINDOW."
  (when-let* ((buf (window-buffer window))
              (client (buffer-local-value 'gowl-embedded-client buf)))
    (let ((geom (gowl-embed--body-geometry window)))
      (when (and (> (nth 2 geom) 0) (> (nth 3 geom) 0))
        (gowl-position-embedded client
                                (nth 0 geom) (nth 1 geom)
                                (nth 2 geom) (nth 3 geom))
        (gowl-set-client-visible client t)))))

(defun gowl-embed--sync-all ()
  "Sync position and visibility for all embedded clients."
  (when (and (gowl-running-p) (not gowl-embed--syncing))
    (let ((gowl-embed--syncing t))
      (dolist (buf (buffer-list))
        (when-let ((client (buffer-local-value 'gowl-embedded-client buf)))
          (let ((win (get-buffer-window buf t)))
            (if win
                (gowl-embed--sync-position win)
              ;; Buffer not displayed — hide the overlay.
              (condition-case nil
                  (gowl-set-client-visible client nil)
                (error nil)))))))))

(defun gowl-embed--do-embed (client window)
  "Embed CLIENT into WINDOW via compositor scene graph.
Reparents CLIENT into Emacs's scene tree so its position is
frame-relative, then positions it over the window body area."
  (with-selected-window window
    (setq-local gowl-embedded-client client)
    (setq-local gowl-embedded-client-pid (gowl-client-pid client))
    ;; Mark as embedded so arrange() skips it.
    (gowl-set-client-embedded client t)
    (gowl-set-client-border-width client 0)
    ;; Reparent into Emacs's scene tree — positions become frame-relative.
    (when-let ((emacs-client (gowl-emacs-client)))
      (gowl-embed-into client emacs-client))
    ;; Position over the window body and show.
    (let ((geom (gowl-embed--body-geometry window)))
      (when (and (> (nth 2 geom) 0) (> (nth 3 geom) 0))
        (gowl-position-embedded client
                                (nth 0 geom) (nth 1 geom)
                                (nth 2 geom) (nth 3 geom))
        (gowl-set-client-visible client t)))
    (gowl-embed--ensure-health-timer)))

(defun gowl-embed--setup-buffer (buf command)
  "Initialize BUF as an embed buffer for COMMAND."
  (with-current-buffer buf
    (gowl-embed-mode)
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
            (progn
              (gowl-set-client-visible client nil)
              (gowl-set-client-embedded client nil)
              (gowl-close-client client))
          (error nil)))
      (setq gowl-embedded-client nil)
      (setq gowl-embedded-client-pid nil))))

(add-hook 'kill-buffer-hook #'gowl-embed--on-kill-buffer)
(add-hook 'window-configuration-change-hook #'gowl-embed--sync-all)

;;;###autoload
(defun gowl-embed (command)
  "Spawn COMMAND and embed it in the current Emacs window.
The Wayland client is reparented into Emacs's compositor scene
tree and positioned over the window body area.  Modeline, fringes,
and header line remain visible.  The compositor's focus-follows-mouse
routes input to the client when the pointer is over it."
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
    (set-window-dedicated-p (selected-window) nil)
    (gowl-set-client-visible client nil)
    (gowl-set-client-embedded client nil)
    (gowl-set-client-border-width client 1)
    (gowl-reparent-client client 2)
    (gowl-arrange)
    (kill-buffer (current-buffer))))

(provide 'cmacs-gowl)
;;; cmacs-gowl.el ends here
