;;; cmacs-gowl-app.el --- Buffer-per-client workflow for --gowl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Inspired by the emskin elisp client: when `cmacs-gowl-app-mode'
;; is enabled, each gowl client becomes an Emacs buffer whose
;; window body drives the compositor's scene-node geometry for the
;; underlying Wayland surface.  Splitting an Emacs window shrinks
;; the embedded app; `C-x b' lists apps as first-class buffers.
;;
;; This is the minimum-viable port.  It drives geometry and
;; lifecycle; mirror views (same client in multiple windows) are
;; queued under TODOs and will land once `gowl-client-add-mirror'
;; is implemented on the compositor side.  Buffer mode is OFF by
;; default — users opt in via `cmacs-gowl-app-mode'.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-gowl-app nil
  "Buffer-per-client workflow for --gowl."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-app-")

(defcustom cmacs-gowl-app-buffer-name-format "*gowl: %s*"
  "Format string for auto-generated gowl app buffer names.
The single %s is replaced with the client's app-id or title."
  :type 'string
  :group 'cmacs-gowl-app)

(defcustom cmacs-gowl-app-hide-cursor t
  "When non-nil, hide the text cursor inside gowl app buffers."
  :type 'boolean
  :group 'cmacs-gowl-app)

(defvar-local cmacs-gowl-app--client nil
  "The GowlClient GObject associated with the current buffer.
Set at buffer creation, cleared on kill.  Used by the reconciler
to push geometry updates.")

(defvar-local cmacs-gowl-app--last-geometry nil
  "Last (X Y W H) pushed to the compositor for this buffer.
Cached so the reconciler only issues IPC when geometry actually
changed — keeps the tick cost proportional to real resizes.")

(defvar-local cmacs-gowl-app--mirrors nil
  "Alist of (WINDOW . VIEW-ID) for this buffer's mirror windows.
The first window showing the buffer is the source (uses the
primary scene node), additional windows get mirrors.  The
reconciler maintains this list across splits / deletes / buffer
switches.")

(defvar cmacs-gowl-app--client-added-handler nil
  "Signal connection id returned from `client-added', or nil.
Disconnected on `cmacs-gowl-app-mode' teardown.")

(defun cmacs-gowl-app--buffer-name-for (client)
  "Compute a buffer name for CLIENT (GowlClient GObject).
Reads title / app-id from `gowl-client-info's alist — that DEFUN
is the stable accessor path and works across standalone / nested /
embedded modes without per-field DEFUN proliferation."
  (let* ((info   (ignore-errors (gowl-client-info client)))
         (title  (alist-get 'title info))
         (app-id (alist-get 'app-id info))
         (base   (or (and (stringp title) (not (string-empty-p title)) title)
                     (and (stringp app-id) (not (string-empty-p app-id)) app-id)
                     "app")))
    (format cmacs-gowl-app-buffer-name-format base)))

(defun cmacs-gowl-app--make-buffer (client)
  "Create and initialise the Emacs buffer backing CLIENT.
Uses `generate-new-buffer' so two clients with the same title do
not clobber each other's buffer-local `cmacs-gowl-app--client'."
  (let ((buf (generate-new-buffer (cmacs-gowl-app--buffer-name-for client))))
    (with-current-buffer buf
      (setq-local cmacs-gowl-app--client client)
      (setq-local buffer-read-only t)
      (setq-local left-fringe-width 0)
      (setq-local right-fringe-width 0)
      (setq-local left-margin-width 0)
      (setq-local right-margin-width 0)
      (when cmacs-gowl-app-hide-cursor
        (setq-local cursor-type nil))
      (setq-local mode-name "Gowl-App")
      (add-hook 'kill-buffer-hook
                #'cmacs-gowl-app--on-kill-buffer nil t))
    buf))

(defun cmacs-gowl-app--on-kill-buffer ()
  "Close the underlying client when its buffer is killed.
Drops any live mirror views first — the compositor will tear the
whole client down once the xdg toplevel is closed, but removing
mirrors explicitly keeps the scene graph tidy between the
kill-buffer notification and the client destroy dispatch."
  (when cmacs-gowl-app--client
    (when (fboundp 'gowl-client-remove-mirror)
      (dolist (entry cmacs-gowl-app--mirrors)
        (ignore-errors
          (gowl-client-remove-mirror cmacs-gowl-app--client (cdr entry)))))
    (when (fboundp 'gowl-close-client)
      (ignore-errors (gowl-close-client cmacs-gowl-app--client))))
  (setq cmacs-gowl-app--mirrors nil)
  (setq cmacs-gowl-app--client nil))

(defun cmacs-gowl-app--window-body-geometry (window)
  "Return (X Y W H) for WINDOW's body area.
`window-body-pixel-edges' excludes fringes, margins, header/mode
lines — exactly the rectangle we want the embedded client to
cover.  Coordinates are frame-local pixels."
  (let* ((edges (window-body-pixel-edges window))
         (x (nth 0 edges))
         (y (nth 1 edges))
         (w (- (nth 2 edges) x))
         (h (- (nth 3 edges) y)))
    (list x y w h)))

(defun cmacs-gowl-app--reconcile-window (window)
  "Push WINDOW's body geometry to the client it currently shows.
No-op if the buffer is not a gowl app buffer."
  (when-let* ((buf (window-buffer window))
              (client (buffer-local-value 'cmacs-gowl-app--client buf)))
    (let* ((geo (cmacs-gowl-app--window-body-geometry window))
           (last (buffer-local-value 'cmacs-gowl-app--last-geometry buf)))
      (unless (equal geo last)
        (with-current-buffer buf
          (setq-local cmacs-gowl-app--last-geometry geo))
        (ignore-errors
          (apply #'gowl-client-set-geometry client geo))))))

(defun cmacs-gowl-app--reconcile-frame (frame)
  "Walk FRAME's windows and reconcile each gowl app buffer's geometry.
Also reconciles mirror views when the same buffer is visible in
multiple windows (C-x 3, C-x 2, tear-off, etc.).  The first
window remains the source (drives the primary scene node via
`gowl-client-set-geometry'); subsequent windows each get a
`gowl-client-add-mirror' view, tracked in `cmacs-gowl-app--mirrors'."
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (let ((by-buffer (make-hash-table :test 'eq)))
      ;; Pass 1: bucket windows by their gowl-app buffer.
      (dolist (win (window-list frame 'no-minibuf))
        (let* ((buf (window-buffer win))
               (client (buffer-local-value 'cmacs-gowl-app--client buf)))
          (when client
            (puthash buf
                     (append (gethash buf by-buffer) (list win))
                     by-buffer))))
      ;; Pass 2: source + mirrors for each buffer.
      (maphash
       (lambda (buf wins)
         (cmacs-gowl-app--reconcile-buffer buf wins))
       by-buffer)
      ;; Pass 3: buffers not in this frame — drop their stale
      ;; mirrors so they don't linger as compositor scene nodes.
      (dolist (buf (buffer-list frame))
        (unless (gethash buf by-buffer)
          (cmacs-gowl-app--drop-all-mirrors buf))))))

(defun cmacs-gowl-app--reconcile-buffer (buf wins)
  "Reconcile BUF's source + mirror views against window list WINS.
WINS is ordered as returned by `window-list'; the head becomes
the source, the rest become mirrors.  Reuses existing mirror
view-ids across reconciler ticks when possible so the compositor
doesn't churn scene nodes on every key press."
  (let* ((client (buffer-local-value 'cmacs-gowl-app--client buf))
         (source-win (car wins))
         (mirror-wins (cdr wins))
         (prev (buffer-local-value 'cmacs-gowl-app--mirrors buf))
         (next nil))
    (when client
      ;; Source: primary scene node tracks source window geometry.
      (cmacs-gowl-app--reconcile-window source-win)
      ;; Mirrors: reuse prev entries by window identity.
      (dolist (mw mirror-wins)
        (let* ((entry (assq mw prev))
               (view-id (cdr entry))
               (geo (cmacs-gowl-app--window-body-geometry mw)))
          (cond
           ;; Existing mirror: update geometry in place.
           (view-id
            (ignore-errors
              (apply #'gowl-client-update-mirror client view-id geo))
            (push (cons mw view-id) next))
           ;; New mirror window: allocate.
           (t
            (let ((vid (ignore-errors
                         (apply #'gowl-client-add-mirror client geo))))
              (when vid (push (cons mw vid) next)))))))
      ;; Drop prev mirrors whose window is no longer showing buf.
      (dolist (old prev)
        (unless (assq (car old) next)
          (ignore-errors (gowl-client-remove-mirror client (cdr old)))))
      (with-current-buffer buf
        (setq-local cmacs-gowl-app--mirrors (nreverse next))))))

(defun cmacs-gowl-app--drop-all-mirrors (buf)
  "Remove every mirror registered against BUF from the compositor.
Called when BUF is no longer visible in the reconciled frame."
  (when-let* ((client (buffer-local-value 'cmacs-gowl-app--client buf))
              (prev (buffer-local-value 'cmacs-gowl-app--mirrors buf)))
    (dolist (entry prev)
      (ignore-errors (gowl-client-remove-mirror client (cdr entry))))
    (with-current-buffer buf
      (setq-local cmacs-gowl-app--mirrors nil))))

(defun cmacs-gowl-app--on-size-or-buffer-change (frame-or-window)
  "Hook body for `window-size-change-functions' and friends.
Accepts either a frame or a window per Emacs's inconsistent calling
convention across the different window hooks."
  (let ((frame (cond ((framep frame-or-window) frame-or-window)
                     ((windowp frame-or-window)
                      (window-frame frame-or-window))
                     (t (selected-frame)))))
    (cmacs-gowl-app--reconcile-frame frame)))

(defun cmacs-gowl-app--on-client-added (_compositor client)
  "Signal handler: create a buffer for newly-mapped CLIENT.
Attached via `gobject-signal-connect' on the compositor.  Bound
once at mode enable; disconnected on disable."
  (let ((buf (cmacs-gowl-app--make-buffer client)))
    (display-buffer buf '((display-buffer-pop-up-window
                           display-buffer-use-some-window)
                          (inhibit-same-window . t)
                          (reusable-frames . nil)))
    ;; Push initial geometry so the client has a valid rectangle
    ;; on its first commit.
    (when-let* ((win (get-buffer-window buf t)))
      (cmacs-gowl-app--reconcile-window win))))

(defun cmacs-gowl-app--on-usable-area-changed (_monitor _old _new)
  "Signal handler: reflow every frame when a bar maps/unmaps."
  (dolist (frame (frame-list))
    (cmacs-gowl-app--reconcile-frame frame)))

;;;###autoload
(define-minor-mode cmacs-gowl-app-mode
  "Buffer-per-client workflow for --gowl.
When enabled, every gowl client that maps gets an Emacs buffer;
the buffer's displayed window drives the compositor's scene-node
geometry for the client.  Disabling reverts to pure WM behaviour
(no automatic buffer creation; existing app buffers persist until
killed)."
  :global t
  :lighter " Gowl-App"
  :group 'cmacs-gowl-app
  (if cmacs-gowl-app-mode
      (cmacs-gowl-app--enable)
    (cmacs-gowl-app--disable)))

(defun cmacs-gowl-app--enable ()
  "Install hooks and the client-added signal listener."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (when (fboundp 'gobject-signal-connect)
    (setq cmacs-gowl-app--client-added-handler
          (gobject-signal-connect (gowl-compositor)
                                  "client-added"
                                  #'cmacs-gowl-app--on-client-added)))
  (add-hook 'window-size-change-functions
            #'cmacs-gowl-app--on-size-or-buffer-change)
  (add-hook 'window-buffer-change-functions
            #'cmacs-gowl-app--on-size-or-buffer-change)
  (when (fboundp 'gobject-signal-connect)
    ;; Reflow on canvas change too; any top-anchored layer surface
    ;; that maps or unmaps (waybar, rofi) will push a new usable-
    ;; area to every monitor.
    (dolist (m (ignore-errors (gowl-list-monitors)))
      (gobject-signal-connect
       m "usable-area-changed"
       #'cmacs-gowl-app--on-usable-area-changed))))

(defun cmacs-gowl-app--disable ()
  "Remove hooks and disconnect signal listeners."
  (remove-hook 'window-size-change-functions
               #'cmacs-gowl-app--on-size-or-buffer-change)
  (remove-hook 'window-buffer-change-functions
               #'cmacs-gowl-app--on-size-or-buffer-change)
  (when (and cmacs-gowl-app--client-added-handler
             (fboundp 'gobject-signal-disconnect))
    (ignore-errors
      (gobject-signal-disconnect (gowl-compositor)
                                  cmacs-gowl-app--client-added-handler))
    (setq cmacs-gowl-app--client-added-handler nil)))

(provide 'cmacs-gowl-app)
;;; cmacs-gowl-app.el ends here
