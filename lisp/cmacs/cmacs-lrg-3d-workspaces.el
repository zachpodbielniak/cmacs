;;; cmacs-lrg-3d-workspaces.el --- Spatial 3D workspace switcher for --lrg=3d -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Renders Doom / persp-mode workspaces as live panels arranged on a curved arc
;; ("carousel") around the current workspace in the libregnum 3D backend
;; (`emacs --lrg=3d').  The current workspace is the live centre (the real window
;; panels); every other workspace is a panel that keeps rendering its real
;; contents off screen, so you can see all your workspaces in 3D space, move /
;; rotate them, and switch with a 3D transition.

;; Layout: workspaces sit in `+workspace-list-names' order on an arc that curves
;; away from the camera; the slot a workspace occupies is its position RELATIVE to
;; the current one (so the current is always centred and switching shifts the
;; carousel).  Each non-current workspace is rendered off screen into its own
;; panel texture via the C primitive `cmacs-lrg-3d-render-into-panel' (which the
;; live round-robin updater drives continuously; see the updater section).

;; This file is a soft dependency on persp-mode / Doom's `+workspace' API and on
;; a 3D lrg frame: every entry point no-ops gracefully when either is absent, so
;; it is harmless under 2D, pgtk, or a non-Doom configuration.

;;; Code:

(require 'cmacs-lrg-3d)
(require 'cl-lib)
(require 'subr-x)

;; Soft dependencies on Doom's `+workspace' API and persp-mode.  Declared so the
;; byte-compiler is quiet; every call site is `fboundp'-guarded at runtime.
(declare-function +workspace-list-names "ext:workspaces")
(declare-function +workspace-current-name "ext:workspaces")
(declare-function +workspace-get "ext:workspaces" (name &optional noerror))
(declare-function +workspace-switch "ext:workspaces" (name &optional auto-create-p))
(declare-function persp-parameter "ext:persp-mode" (param-name &optional persp))
(declare-function set-persp-parameter "ext:persp-mode" (param-name value &optional persp))
(declare-function safe-persp-window-conf "ext:persp-mode" (p))
(declare-function persp-buffers "ext:persp-mode" (p))

;; Forward declaration: the mode variable is defined by the `define-minor-mode'
;; at the end of this file but referenced by the lifecycle hooks above it.
(defvar cmacs-lrg-3d-workspaces-mode)

(defgroup cmacs-lrg-3d-workspaces nil
  "Spatial 3D workspace switcher for the libregnum backend."
  :group 'cmacs-lrg-3d
  :prefix "cmacs-lrg-3d-workspaces-")

(defcustom cmacs-lrg-3d-workspaces-radius 10.0
  "Curve radius (world units) of the workspace carousel.
Larger values flatten the arc; the centre-of-curvature sits this far behind the
live centre, so the centre slot lands on the origin and side slots curve away
from the camera."
  :type 'number
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-spacing 28.0
  "Angular spacing, in degrees, between adjacent workspace slots on the arc."
  :type 'number
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-auto t
  "When non-nil, enable the workspace carousel automatically.
The carousel turns on once persp-mode is active on a 3D lrg frame (so
`emacs --lrg=3d' shows your workspaces without an explicit
\\[cmacs-lrg-3d-workspaces-mode])."
  :type 'boolean
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-frame-zoom 1.0
  "Optional camera pull-back applied when the carousel is enabled.
A factor on the eye-to-target distance (>1 = further back); larger shows more
workspaces at once but a smaller live centre.  The default 1.0 leaves the camera
alone — with the default `cmacs-lrg-3d-workspaces-radius' / `-spacing' the
immediate neighbours already sit in view; raise this to glance at more of the
ring at rest (or use \\[cmacs-lrg-3d-workspaces-overview] on demand)."
  :type 'number
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-height 3.2
  "Height, in world units, of each workspace panel.
The width is this times the frame's pixel aspect ratio."
  :type 'number
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-elevation 0.0
  "Vertical offset, in world units, of the workspace arc."
  :type 'number
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-max 8
  "Maximum number of non-current workspaces to show on the arc.
Workspaces farther than this many slots from the current one (on either side)
are not drawn.  nil means no limit."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-live t
  "When non-nil, keep non-current workspace panels rendering their live contents.
A repeating timer re-renders changed workspaces one at a time (round-robin), so
a process or clock running in another workspace updates on its panel while you
work.  Set to nil to render workspace panels only on switch / explicit refresh."
  :type 'boolean
  :group 'cmacs-lrg-3d-workspaces)

(defcustom cmacs-lrg-3d-workspaces-update-interval 0.12
  "Seconds between live-updater ticks.
Each tick re-renders at most one changed off-screen workspace, so a workspace
that is changing updates roughly every (this * number-of-workspaces) seconds.
Larger values cost less; smaller values feel more live."
  :type 'number
  :group 'cmacs-lrg-3d-workspaces)

(defconst cmacs-lrg-3d-workspaces--default-aspect 1.6
  "Aspect ratio used for arc math when no live frame is available (e.g. tests).")

;; --- workspace <-> panel index map ----------------------------------------

(defvar cmacs-lrg-3d-workspaces--index-table (make-hash-table :test 'equal)
  "Map of workspace name -> stable small panel index (the C panel key).")

(defvar cmacs-lrg-3d-workspaces--index-counter 0
  "Monotonic counter handing out panel indices to workspaces.")

(defvar cmacs-lrg-3d-workspaces--applied (make-hash-table :test 'equal)
  "Map of workspace name -> last transform we placed it at.
Used to detect a manual move/rotate (live geometry diverging from this) so it
can be persisted, and to avoid re-persisting our own placements.")

(defvar cmacs-lrg-3d-workspaces--hidden nil
  "When non-nil, the carousel is hidden (panels removed, updates paused).")

(defconst cmacs-lrg-3d-workspaces--move-epsilon 0.05
  "World-unit / degree threshold for treating a panel as manually moved.")

(defun cmacs-lrg-3d-workspaces--name-for-index (idx)
  "Return the workspace name mapped to panel index IDX, or nil."
  (catch 'found
    (maphash (lambda (name i) (when (= i idx) (throw 'found name)))
             cmacs-lrg-3d-workspaces--index-table)
    nil))

(defun cmacs-lrg-3d-workspaces--index (name)
  "Return the stable panel index for workspace NAME, assigning one if needed."
  (or (gethash name cmacs-lrg-3d-workspaces--index-table)
      (puthash name
               (prog1 cmacs-lrg-3d-workspaces--index-counter
                 (setq cmacs-lrg-3d-workspaces--index-counter
                       (1+ cmacs-lrg-3d-workspaces--index-counter)))
               cmacs-lrg-3d-workspaces--index-table)))

(defun cmacs-lrg-3d-workspaces--forget (name)
  "Forget workspace NAME's panel index (after its panel is removed)."
  (remhash name cmacs-lrg-3d-workspaces--index-table)
  (remhash name cmacs-lrg-3d-workspaces--applied))

;; --- availability ----------------------------------------------------------

(defun cmacs-lrg-3d-workspaces--available-p (&optional frame)
  "Return non-nil when the spatial workspace switcher can run on FRAME.
Requires Doom's `+workspace' API and a live 3D lrg frame."
  (and (fboundp '+workspace-list-names)
       (fboundp '+workspace-current-name)
       (fboundp 'cmacs-lrg-3d-place-workspace-panel)
       (cmacs-lrg-3d-active-p frame)))

;; --- arc geometry (pure) ---------------------------------------------------

(defun cmacs-lrg-3d-workspaces--aspect (&optional frame)
  "Return FRAME's pixel aspect ratio (width / height), or a sane default."
  (let ((f (or frame (selected-frame))))
    (if (and (frame-live-p f)
             (> (frame-pixel-height f) 0))
        (/ (float (frame-pixel-width f)) (frame-pixel-height f))
      cmacs-lrg-3d-workspaces--default-aspect)))

(defun cmacs-lrg-3d-workspaces--slot (rel aspect)
  "Return the transform (PX PY PZ YAW W H) for the slot REL steps from centre.
REL is the signed offset from the current workspace (0 = centre, negative =
left).  ASPECT is the frame aspect ratio.  Panels sit on a concave arc that
wraps around the viewer: positions curve back at the sides, and each panel is
toed in (yaw = -beta) so its face turns toward you -- you read neighbours at a
glance rather than edge-on."
  (let* ((beta-deg (* rel cmacs-lrg-3d-workspaces-spacing))
         (beta (* beta-deg (/ float-pi 180.0)))
         (rw cmacs-lrg-3d-workspaces-radius)
         (h cmacs-lrg-3d-workspaces-height)
         (w (* h aspect))
         (px (* rw (sin beta)))
         (pz (* rw (- (cos beta) 1.0)))
         (py cmacs-lrg-3d-workspaces-elevation))
    (list px py pz (- beta-deg) w h)))

(defun cmacs-lrg-3d-workspaces--placement (name rel aspect)
  "Return the placement transform for workspace NAME at slot REL.
If the workspace carries a saved `lrg-3d-xform' persp-parameter (a user move /
rotate), use that; otherwise compute the default arc slot."
  (or (and (fboundp 'persp-parameter)
           (fboundp '+workspace-get)
           (let ((persp (ignore-errors (+workspace-get name t))))
             (and persp (persp-parameter 'lrg-3d-xform persp))))
      (cmacs-lrg-3d-workspaces--slot rel aspect)))

(defun cmacs-lrg-3d-workspaces--xform-moved-p (a b)
  "Return non-nil if transforms A and B differ in position or yaw.
Compares px, py, pz, yaw (ignores width/height, which track the frame aspect)."
  (or (> (abs (- (nth 0 a) (nth 0 b))) cmacs-lrg-3d-workspaces--move-epsilon)
      (> (abs (- (nth 1 a) (nth 1 b))) cmacs-lrg-3d-workspaces--move-epsilon)
      (> (abs (- (nth 2 a) (nth 2 b))) cmacs-lrg-3d-workspaces--move-epsilon)
      (> (abs (- (nth 3 a) (nth 3 b))) cmacs-lrg-3d-workspaces--move-epsilon)))

(defun cmacs-lrg-3d-workspaces--save-xform (name xform)
  "Persist XFORM as workspace NAME's `lrg-3d-xform' persp-parameter."
  (when (and (fboundp 'set-persp-parameter) (fboundp '+workspace-get))
    (let ((persp (ignore-errors (+workspace-get name t))))
      (when persp
        (set-persp-parameter 'lrg-3d-xform xform persp)))))

;; --- off-screen render of one workspace ------------------------------------

(defmacro cmacs-lrg-3d-workspaces--with-offscreen (frame &rest body)
  "Run BODY with on-screen presents on FRAME suppressed and side effects muted.
Saves and restores FRAME's window configuration and inhibits the hooks that a
temporary `window-state-put' would otherwise fire (modeline, eldoc, buffer-list,
persp tracking), so rendering a non-current workspace off screen leaves the live
session untouched."
  (declare (indent 1) (debug (form body)))
  (let ((f (make-symbol "frame"))
        (wc (make-symbol "wconf")))
    `(let* ((,f ,frame)
            (,wc (current-window-configuration ,f))
            (window-configuration-change-hook nil)
            (window-selection-change-functions nil)
            (window-buffer-change-functions nil)
            (window-size-change-functions nil)
            (buffer-list-update-hook nil)
            (inhibit-redisplay nil))
       (unwind-protect
           (progn
             (cmacs-lrg-3d-begin-offscreen ,f)
             ,@body)
         (set-window-configuration ,wc)
         (cmacs-lrg-3d-end-offscreen ,f)))))

(defun cmacs-lrg-3d-workspaces--render-one (name &optional frame)
  "Render workspace NAME's live contents into its 3D panel, off screen.
Installs NAME's saved window layout in FRAME's root window, redisplays it (so
its buffers' current contents are drawn) and captures it to NAME's panel
texture, then restores the live layout.  No-op for the current workspace or
without a window layout."
  (let ((f (or frame (selected-frame))))
    (when (and (cmacs-lrg-3d-workspaces--available-p f)
               (not (active-minibuffer-window))
               (not (string= name (+workspace-current-name))))
      (let* ((persp (ignore-errors (+workspace-get name t)))
             (conf (and persp (fboundp 'safe-persp-window-conf)
                        (safe-persp-window-conf persp)))
             (index (cmacs-lrg-3d-workspaces--index name)))
        (when conf
          (condition-case err
              (cmacs-lrg-3d-workspaces--with-offscreen f
                (window-state-put conf (frame-root-window f) t)
                (redisplay t)
                (cmacs-lrg-3d-render-into-panel index f))
            (error
             (message "cmacs-lrg-3d-workspaces: render %s failed: %S"
                      name err))))))))

;; --- placement / relayout --------------------------------------------------

(defun cmacs-lrg-3d-workspaces--place-one (name rel aspect &optional frame)
  "Place workspace NAME's panel at slot REL (or its saved transform) on FRAME.
Eases the panel into place (the first placement snaps).  If the panel has been
manually moved or rotated since we last placed it, that placement is persisted
first so it is kept rather than overwritten."
  (let* ((f (or frame (selected-frame)))
         (index (cmacs-lrg-3d-workspaces--index name))
         (geom (cmacs-lrg-3d-workspace-panel-geometry index f))
         (applied (gethash name cmacs-lrg-3d-workspaces--applied)))
    (when (and geom applied
               (cmacs-lrg-3d-workspaces--xform-moved-p geom applied))
      (cmacs-lrg-3d-workspaces--save-xform name geom))
    (let ((xf (cmacs-lrg-3d-workspaces--placement name rel aspect)))
      (apply #'cmacs-lrg-3d-place-workspace-panel-eased index (append xf (list f)))
      (puthash name xf cmacs-lrg-3d-workspaces--applied))))

(defun cmacs-lrg-3d-workspaces--visible-p (rel)
  "Return non-nil if a workspace REL slots from centre should be drawn."
  (or (null cmacs-lrg-3d-workspaces-max)
      (<= (abs rel) cmacs-lrg-3d-workspaces-max)))

(defun cmacs-lrg-3d-workspaces-relayout (&optional frame)
  "Place every non-current workspace panel on the arc around the current one.
Removes the current workspace's panel (it is the live centre) and panels for
workspaces that no longer exist or fall outside the visible range.  Does not
render contents (see `cmacs-lrg-3d-workspaces--render-one')."
  (when (and (cmacs-lrg-3d-workspaces--available-p frame)
             (not cmacs-lrg-3d-workspaces--hidden))
    (let* ((f (or frame (selected-frame)))
           (names (+workspace-list-names))
           (current (+workspace-current-name))
           (cur-pos (or (cl-position current names :test #'string=) 0))
           (aspect (cmacs-lrg-3d-workspaces--aspect f))
           (live (make-hash-table :test 'equal)))
      (cl-loop for name in names
               for i from 0
               for rel = (- i cur-pos)
               do (if (and (not (string= name current))
                           (cmacs-lrg-3d-workspaces--visible-p rel))
                      (progn
                        (puthash name t live)
                        (cmacs-lrg-3d-workspaces--place-one name rel aspect f))
                    ;; current workspace, or out-of-range: ensure no panel
                    (cmacs-lrg-3d-workspaces--drop name f)))
      ;; Drop panels for workspaces that vanished entirely.
      (maphash (lambda (name _idx)
                 (unless (or (gethash name live)
                             (member name names))
                   (cmacs-lrg-3d-workspaces--drop name f)))
               (copy-hash-table cmacs-lrg-3d-workspaces--index-table)))))

(defun cmacs-lrg-3d-workspaces--drop (name &optional frame)
  "Remove workspace NAME's 3D panel and forget its index."
  (when (gethash name cmacs-lrg-3d-workspaces--index-table)
    (let ((index (cmacs-lrg-3d-workspaces--index name)))
      (when (fboundp 'cmacs-lrg-3d-remove-workspace-panel)
        (cmacs-lrg-3d-remove-workspace-panel index (or frame (selected-frame))))
      (cmacs-lrg-3d-workspaces--forget name))))

;;;###autoload
(defun cmacs-lrg-3d-workspaces-refresh (&optional frame)
  "Relayout and re-render every workspace panel on FRAME now.
Lays the carousel out around the current workspace and renders each non-current
workspace's live contents into its panel.  Safe to call anytime; no-op without a
3D lrg frame and Doom workspaces."
  (interactive)
  (when (and (cmacs-lrg-3d-workspaces--available-p frame)
             (not cmacs-lrg-3d-workspaces--hidden))
    (let ((f (or frame (selected-frame))))
      (cmacs-lrg-3d-workspaces-relayout f)
      (let ((current (+workspace-current-name)))
        (dolist (name (+workspace-list-names))
          (unless (string= name current)
            (when (gethash name cmacs-lrg-3d-workspaces--index-table)
              (cmacs-lrg-3d-workspaces--render-one name f))))))))

;; --- live round-robin updater ----------------------------------------------

(defvar cmacs-lrg-3d-workspaces--timer nil
  "Repeating timer driving the live workspace updater, or nil.")

(defvar cmacs-lrg-3d-workspaces--rr 0
  "Round-robin cursor into the non-current workspace list.")

(defvar cmacs-lrg-3d-workspaces--last-sig (make-hash-table :test 'equal)
  "Map of workspace name -> last rendered content signature (for dirty-tracking).")

(defvar cmacs-lrg-3d-workspaces--last-current nil
  "Name of the workspace that was current before the last switch.")

(defun cmacs-lrg-3d-workspaces--signature (name)
  "Return a value summarising workspace NAME's content, or nil if unknown.
Changes when any of the workspace's buffers change, so an unchanged workspace
can be skipped by the updater.  nil (no persp buffer list) means always
re-render."
  (when (and (fboundp '+workspace-get) (fboundp 'persp-buffers))
    (let ((persp (ignore-errors (+workspace-get name t))))
      (when persp
        (let ((sig 0))
          (dolist (b (ignore-errors (persp-buffers persp)))
            (when (buffer-live-p b)
              (setq sig (+ sig (buffer-chars-modified-tick b)))))
          sig)))))

(defun cmacs-lrg-3d-workspaces--force-dirty ()
  "Mark every workspace dirty so the updater re-renders them."
  (clrhash cmacs-lrg-3d-workspaces--last-sig))

(defun cmacs-lrg-3d-workspaces--non-current-names ()
  "Return the visible non-current workspace names, in arc order."
  (let* ((names (+workspace-list-names))
         (current (+workspace-current-name))
         (cur-pos (or (cl-position current names :test #'string=) 0)))
    (cl-loop for name in names
             for i from 0
             unless (or (string= name current)
                        (not (cmacs-lrg-3d-workspaces--visible-p (- i cur-pos))))
             collect name)))

(defun cmacs-lrg-3d-workspaces--consume-pending ()
  "Switch to the workspace a Ctrl+double-left-click chose, if any.
Polls the C-side pending selection; the switch runs here in the command loop
(never from the input path), so the persp hooks and the eased transition fire
normally."
  (when (fboundp 'cmacs-lrg-3d-take-pending-workspace)
    (let ((idx (cmacs-lrg-3d-take-pending-workspace)))
      (when (and idx (fboundp '+workspace-switch))
        (let ((name (cmacs-lrg-3d-workspaces--name-for-index idx)))
          (when (and name (member name (+workspace-list-names))
                     (not (string= name (+workspace-current-name))))
            (+workspace-switch name)))))))

(defun cmacs-lrg-3d-workspaces--tick ()
  "Live-updater tick.
First applies a pending click-to-switch, then (when the live updater is on)
re-renders the next off-screen workspace whose content changed since it was last
drawn (at most one per tick, to bound cost)."
  (when (and cmacs-lrg-3d-workspaces-mode
             (cmacs-lrg-3d-workspaces--available-p)
             (not cmacs-lrg-3d-workspaces--hidden)
             (not (active-minibuffer-window)))
    (cmacs-lrg-3d-workspaces--consume-pending)
    (when cmacs-lrg-3d-workspaces-live
      (let* ((names (cmacs-lrg-3d-workspaces--non-current-names))
             (n (length names)))
        (when (> n 0)
          (cl-dotimes (k n)
            (let* ((i (mod (+ cmacs-lrg-3d-workspaces--rr k) n))
                   (name (nth i names))
                   (sig (cmacs-lrg-3d-workspaces--signature name)))
              (when (or (null sig)
                        (not (equal sig (gethash name
                                                 cmacs-lrg-3d-workspaces--last-sig
                                                 'none))))
                (cmacs-lrg-3d-workspaces--render-one name)
                (when sig
                  (puthash name sig cmacs-lrg-3d-workspaces--last-sig))
                (setq cmacs-lrg-3d-workspaces--rr (mod (1+ i) n))
                (cl-return)))))))))

(defun cmacs-lrg-3d-workspaces--start-timer ()
  "Start the workspace timer (idempotent).
It runs while the mode is on regardless of `cmacs-lrg-3d-workspaces-live' so
click-to-switch stays responsive; the live re-render is gated inside the tick."
  (cmacs-lrg-3d-workspaces--stop-timer)
  (setq cmacs-lrg-3d-workspaces--timer
        (run-with-timer cmacs-lrg-3d-workspaces-update-interval
                        cmacs-lrg-3d-workspaces-update-interval
                        #'cmacs-lrg-3d-workspaces--tick)))

(defun cmacs-lrg-3d-workspaces--stop-timer ()
  "Stop the live updater timer."
  (when cmacs-lrg-3d-workspaces--timer
    (cancel-timer cmacs-lrg-3d-workspaces--timer)
    (setq cmacs-lrg-3d-workspaces--timer nil)))

;; --- workspace lifecycle hooks ---------------------------------------------

(defun cmacs-lrg-3d-workspaces--on-change (&rest _)
  "Relayout the carousel after a workspace was created/killed/renamed.
Marks every workspace dirty so the live updater re-renders them."
  (when cmacs-lrg-3d-workspaces-mode
    (cmacs-lrg-3d-workspaces-relayout)
    (cmacs-lrg-3d-workspaces--force-dirty)))

(defun cmacs-lrg-3d-workspaces--on-switch (&rest _)
  "After switching workspaces, relayout and mark every workspace dirty.
The live updater re-renders them over the next few ticks; the just-vacated
workspace is rendered immediately so its panel is not blank.  With the live
updater off, fall back to a full synchronous refresh."
  (when cmacs-lrg-3d-workspaces-mode
    (if cmacs-lrg-3d-workspaces-live
        (let ((left cmacs-lrg-3d-workspaces--last-current))
          ;; relayout eases the carousel to the new arrangement (the transition);
          ;; the updater re-renders contents over the next few ticks.
          (cmacs-lrg-3d-workspaces-relayout)
          (cmacs-lrg-3d-workspaces--force-dirty)
          (when (and left
                     (not (string= left (+workspace-current-name)))
                     (member left (+workspace-list-names)))
            (cmacs-lrg-3d-workspaces--render-one left)))
      (cmacs-lrg-3d-workspaces-refresh))
    (setq cmacs-lrg-3d-workspaces--last-current (+workspace-current-name))))

(defvar cmacs-lrg-3d-workspaces--hooks
  '((persp-created-functions     . cmacs-lrg-3d-workspaces--on-change)
    (persp-before-kill-functions . cmacs-lrg-3d-workspaces--on-change)
    (persp-renamed-functions     . cmacs-lrg-3d-workspaces--on-change)
    (persp-activated-functions   . cmacs-lrg-3d-workspaces--on-switch))
  "Persp-mode hooks the workspace switcher installs while enabled.")

(defun cmacs-lrg-3d-workspaces--install-hooks (install)
  "Add (INSTALL non-nil) or remove the persp lifecycle hooks."
  (dolist (cell cmacs-lrg-3d-workspaces--hooks)
    (when (boundp (car cell))
      (if install
          (add-hook (car cell) (cdr cell))
        (remove-hook (car cell) (cdr cell))))))

;; --- interactive commands --------------------------------------------------

;;;###autoload
(defun cmacs-lrg-3d-workspaces-overview ()
  "Pull the 3D camera back to frame the whole workspace carousel at once."
  (interactive)
  (if (cmacs-lrg-3d-workspaces--available-p)
      (progn
        (when (fboundp 'cmacs-lrg-3d-camera)
          (cmacs-lrg-3d-camera "reset"))
        (when (fboundp 'cmacs-lrg-3d-dolly)
          (cmacs-lrg-3d-dolly 1.9)))
    (user-error "Not a 3D lrg frame with workspaces")))

;;;###autoload
(defun cmacs-lrg-3d-workspaces-toggle ()
  "Hide or show the workspace carousel (the live centre is unaffected)."
  (interactive)
  (setq cmacs-lrg-3d-workspaces--hidden (not cmacs-lrg-3d-workspaces--hidden))
  (if cmacs-lrg-3d-workspaces--hidden
      (progn
        (when (cmacs-lrg-3d-workspaces--available-p)
          (dolist (name (hash-table-keys cmacs-lrg-3d-workspaces--index-table))
            (cmacs-lrg-3d-workspaces--drop name)))
        (message "lrg 3D workspaces: hidden"))
    (cmacs-lrg-3d-workspaces-refresh)
    (message "lrg 3D workspaces: shown")))

;;;###autoload
(defun cmacs-lrg-3d-workspaces-rotate (name degrees)
  "Rotate workspace NAME's panel by DEGREES about world Y, and remember it.
Interactively, choose a non-current workspace and a rotation."
  (interactive
   (list (completing-read "Rotate workspace: "
                          (and (fboundp 'cmacs-lrg-3d-workspaces--non-current-names)
                               (cmacs-lrg-3d-workspaces--non-current-names))
                          nil t)
         (read-number "Rotate by (degrees): " 15)))
  (if (and (cmacs-lrg-3d-workspaces--available-p)
           (fboundp 'cmacs-lrg-3d-rotate-workspace-panel))
      (let ((index (cmacs-lrg-3d-workspaces--index name)))
        (cmacs-lrg-3d-rotate-workspace-panel index degrees)
        ;; Persist the new transform so it survives switches/relayouts.
        (let ((geom (cmacs-lrg-3d-workspace-panel-geometry index)))
          (when geom
            (cmacs-lrg-3d-workspaces--save-xform name geom)
            (puthash name geom cmacs-lrg-3d-workspaces--applied)))
        (message "lrg 3D workspaces: rotated %s by %s deg" name degrees))
    (user-error "Not a 3D lrg frame with workspaces")))

(defun cmacs-lrg-3d-workspaces--frame ()
  "Pull the camera back to frame the whole carousel.
At the default head-on framing the live centre fills the view and side panels
sit at the edges; pulling back is what makes the neighbour workspaces visible.
The dolly is a factor on the eye-to-target distance, so it must run from the
reset (default) pose -- the reset eases over ~0.3s, hence the deferred dolly --
otherwise it would compound on whatever zoom the camera already had."
  (when (and (> cmacs-lrg-3d-workspaces-frame-zoom 1.0)
             (fboundp 'cmacs-lrg-3d-camera)
             (fboundp 'cmacs-lrg-3d-dolly))
    (cmacs-lrg-3d-camera "reset")
    (run-at-time 0.35 nil
                 (lambda ()
                   (when cmacs-lrg-3d-workspaces-mode
                     (cmacs-lrg-3d-dolly cmacs-lrg-3d-workspaces-frame-zoom))))))

;; --- mode ------------------------------------------------------------------

;;;###autoload
(define-minor-mode cmacs-lrg-3d-workspaces-mode
  "Show persp-mode workspaces as a live 3D carousel around the current one.
When enabled on a 3D lrg frame, every non-current workspace renders its real
contents into a panel arranged on a curved arc; switching workspaces shifts the
carousel.  No-op without Doom's `+workspace' API or off a 3D lrg frame."
  :global t
  :group 'cmacs-lrg-3d-workspaces
  (if cmacs-lrg-3d-workspaces-mode
      (progn
        (require 'cl-lib)
        (setq cmacs-lrg-3d-workspaces--hidden nil)
        (setq cmacs-lrg-3d-workspaces--last-current
              (and (fboundp '+workspace-current-name)
                   (+workspace-current-name)))
        (cmacs-lrg-3d-workspaces--install-hooks t)
        (cmacs-lrg-3d-workspaces-refresh)
        (cmacs-lrg-3d-workspaces--frame)
        (cmacs-lrg-3d-workspaces--start-timer))
    (cmacs-lrg-3d-workspaces--stop-timer)
    (cmacs-lrg-3d-workspaces--install-hooks nil)
    ;; Tear down every workspace panel.
    (when (cmacs-lrg-3d-workspaces--available-p)
      (dolist (name (hash-table-keys cmacs-lrg-3d-workspaces--index-table))
        (cmacs-lrg-3d-workspaces--drop name)))))

;; --- auto-enable -----------------------------------------------------------

(defun cmacs-lrg-3d-workspaces--maybe-auto-enable (&rest _)
  "Enable the carousel when configured to, persp-mode is up, and on a 3D frame."
  (when (and cmacs-lrg-3d-workspaces-auto
             (not cmacs-lrg-3d-workspaces-mode)
             (cmacs-lrg-3d-workspaces--available-p))
    (cmacs-lrg-3d-workspaces-mode 1)))

;; persp-mode is enabled by Doom after this file loads (during lrg display init),
;; so hook its activation; window-setup-hook covers persp-already-on; and try now
;; in case both are already live (e.g. on re-eval).
(add-hook 'persp-mode-hook #'cmacs-lrg-3d-workspaces--maybe-auto-enable)
(add-hook 'window-setup-hook #'cmacs-lrg-3d-workspaces--maybe-auto-enable)
(cmacs-lrg-3d-workspaces--maybe-auto-enable)

(provide 'cmacs-lrg-3d-workspaces)

;;; cmacs-lrg-3d-workspaces.el ends here
