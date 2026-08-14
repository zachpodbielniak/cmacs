;;; cmacs-libregnum.el --- libregnum 3D scene buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Major mode + entry points for cmacs-libregnum, the libregnum-
;; backed 3D scene subsystem.  Each `cmacs-libregnum-mode' buffer
;; owns a view that renders a libregnum scene into the full window
;; area via the C bridge in cmacs/libregnum/.

;;; Code:

(require 'subr-x)

(defgroup cmacs-libregnum nil
  "libregnum 3D scene subsystem for cmacs."
  :group 'cmacs
  :prefix "cmacs-libregnum-")

(defcustom cmacs-libregnum-default-size '(800 . 500)
  "Default (WIDTH . HEIGHT) pixels for a fresh libregnum view."
  :type '(cons integer integer)
  :group 'cmacs-libregnum)

(defun cmacs-libregnum-default-font-file ()
  "Resolve the default face's font family to a TTF/OTF file path.
Used by anything that draws text inside a libregnum framebuffer -- the
in-scene node labels and the vidstudio timeline overlay -- so that text
is rendered in the same font as the rest of the editor rather than
raylib's built-in bitmap font.  Returns nil when it cannot be resolved,
which the C side treats as \"use the built-in font\"."
  (ignore-errors
    (let ((family (face-attribute 'default :family nil t)))
      (when (and (stringp family)
                 (not (string-empty-p family))
                 (executable-find "fc-match"))
        (let ((f (string-trim
                  (shell-command-to-string
                   (format "fc-match -f '%%{file}' %s"
                           (shell-quote-argument family))))))
          (and (stringp f) (> (length f) 0) (file-readable-p f) f))))))

(defcustom cmacs-libregnum-clear-color "#101015"
  "Background colour for libregnum scenes (informational; the C side
holds the active value)."
  :type 'color
  :group 'cmacs-libregnum)

(defcustom cmacs-libregnum-target-fps 60
  "Target frame rate for animated libregnum views.
Only affects views switched into animation mode via
`cmacs-libregnum-toggle-animation' (or the `cmacs-libregnum-set-animated'
primitive).  Static scenes render on demand and ignore this value."
  :type 'integer
  :group 'cmacs-libregnum)

(declare-function cmacs-libregnum-supported-p "cmacs-libregnum-defuns.c" ())
(declare-function cmacs-libregnum-attach "cmacs-libregnum-defuns.c"
                  (buffer &optional width height))
(declare-function cmacs-libregnum-detach "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-attached-p "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-resize "cmacs-libregnum-defuns.c"
                  (buffer width height))
(declare-function cmacs-libregnum-redraw "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-build-tree "cmacs-libregnum-defuns.c"
                  (buffer root))
(declare-function cmacs-libregnum-build-gobject "cmacs-libregnum-defuns.c"
                  (buffer &optional namespace))
(declare-function cmacs-libregnum-build-mindmap "cmacs-libregnum-defuns.c"
                  (buffer org-file))
(declare-function cmacs-libregnum-camera-state "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-set-camera "cmacs-libregnum-defuns.c"
                  (buffer position target fov))
(declare-function cmacs-libregnum-set-animated "cmacs-libregnum-defuns.c"
                  (buffer flag &optional target-fps))
(declare-function cmacs-libregnum-animated-p "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-tree-nodes "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-set-selection "cmacs-libregnum-defuns.c"
                  (buffer id &optional focus))

;;;; Buffer text format -----------------------------------------------

;; The scene file is human-editable.  Format is a tiny subset of YAML:
;;   key: value
;; with values being either:
;;   - a bare string up to end of line
;;   - "[X, Y, Z]" coordinate triples
;;   - bare floats / ints
;; Comments start with #.  Blank lines ignored.  This is sufficient for
;; v1 -- if we need full YAML later, swap the parser for yaml-glib.

(defun cmacs-libregnum--parse-buffer ()
  "Parse the current buffer's scene text into an alist of (KEY . VAL)."
  (save-excursion
    (goto-char (point-min))
    (let (acc)
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (cond
           ((string-match "\\`[ \t]*#" line)
            nil)
           ((string-match "\\`[ \t]*\\'" line)
            nil)
           ((string-match "\\`\\([A-Za-z0-9_]+\\):[ \t]*\\(.*\\)\\'" line)
            (let ((k (intern (match-string 1 line)))
                  (raw (match-string 2 line)))
              (push (cons k (cmacs-libregnum--parse-value raw)) acc)))))
        (forward-line 1))
      (nreverse acc))))

(defun cmacs-libregnum--parse-value (raw)
  (let ((s (string-trim raw)))
    (cond
     ((string-match "\\`\\[\\(.*\\)\\]\\'" s)
      (mapcar (lambda (tok)
                (string-to-number (string-trim tok)))
              (split-string (match-string 1 s) ",")))
     ((string-match "\\`-?[0-9]+\\(\\.[0-9]+\\)?\\'" s)
      (string-to-number s))
     (t s))))

(defun cmacs-libregnum--alist-get (key alist)
  (cdr (assq key alist)))

(defun cmacs-libregnum--serialise-buffer (alist)
  "Replace the current buffer's text with a YAML-ish dump of ALIST."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "# -*- mode: cmacs-libregnum -*-\n")
    (dolist (pair alist)
      (let ((k (car pair))
            (v (cdr pair)))
        (cond
         ((consp v)
          (insert (format "%s: [%s]\n" k
                          (mapconcat (lambda (n) (format "%.4f" n))
                                     v ", "))))
         ((stringp v)
          (insert (format "%s: %s\n" k v)))
         ((numberp v)
          (insert (format "%s: %s\n" k v))))))))

(defun cmacs-libregnum--apply-camera (buffer alist)
  "If ALIST has :position/target/fov keys, push them into BUFFER's view."
  (let ((pos (cmacs-libregnum--alist-get 'position alist))
        (tgt (cmacs-libregnum--alist-get 'target alist))
        (fov (cmacs-libregnum--alist-get 'fov alist)))
    (when (and (listp pos) (listp tgt))
      (cmacs-libregnum-set-camera buffer pos tgt (or fov 0.0)))))

(defun cmacs-libregnum--apply-scene (buffer alist)
  "Dispatch on `scene_type' and rebuild BUFFER's scene from ALIST."
  (let ((type (cmacs-libregnum--alist-get 'scene_type alist)))
    (cond
     ((equal type "project_tree")
      (let ((root (cmacs-libregnum--alist-get 'project_root alist)))
        (when (and root (stringp root) (file-directory-p root))
          (cmacs-libregnum-build-tree buffer root)
          (with-current-buffer buffer
            (setq-local cmacs-libregnum--scene-root
                        (file-name-as-directory (expand-file-name root)))
            (cmacs-libregnum--load-model)))))
     ((equal type "gobject")
      (let ((ns (cmacs-libregnum--alist-get 'namespace alist)))
        (cmacs-libregnum-build-gobject
         buffer (and ns (stringp ns) ns))))
     ((equal type "mindmap")
      (let ((org-file (cmacs-libregnum--alist-get 'org_file alist)))
        (when (and org-file (stringp org-file) (file-exists-p org-file))
          (cmacs-libregnum-build-mindmap buffer org-file)))))))

(defun cmacs-libregnum--read-scene-from-buffer ()
  "Rebuild this buffer's scene + restore camera from buffer text."
  (when (cmacs-libregnum-attached-p (current-buffer))
    (let ((alist (cmacs-libregnum--parse-buffer)))
      (cmacs-libregnum--apply-scene (current-buffer) alist)
      (cmacs-libregnum--apply-camera (current-buffer) alist))))

(defun cmacs-libregnum--write-scene-to-buffer ()
  "Snapshot camera + scene parameters into buffer text (called on save)."
  (when (cmacs-libregnum-attached-p (current-buffer))
    (let* ((existing (cmacs-libregnum--parse-buffer))
           (state    (cmacs-libregnum-camera-state (current-buffer)))
           (pos      (plist-get state :position))
           (tgt      (plist-get state :target))
           (fov      (plist-get state :fov))
           (new (copy-alist existing)))
      (setf (alist-get 'position new) pos)
      (setf (alist-get 'target   new) tgt)
      (setf (alist-get 'fov      new) fov)
      (cmacs-libregnum--serialise-buffer new))))

;;;; Mode -------------------------------------------------------------

(defvar cmacs-libregnum-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "q")       #'kill-this-buffer)
    (define-key m (kbd "g r")     #'cmacs-libregnum-reload-from-buffer)
    (define-key m (kbd "g g")     #'cmacs-libregnum-redraw-current)
    (define-key m (kbd "g s")     #'cmacs-libregnum-save-to-buffer)
    (define-key m (kbd "a")       #'cmacs-libregnum-toggle-animation)
    ;; Tree navigation: arrows + hjkl move the selection; RET opens a
    ;; file / enters a directory; u (or ^) goes up a directory.
    (define-key m (kbd "<up>")    #'cmacs-libregnum-select-parent)
    (define-key m (kbd "<down>")  #'cmacs-libregnum-select-child)
    (define-key m (kbd "<left>")  #'cmacs-libregnum-select-prev-sibling)
    (define-key m (kbd "<right>") #'cmacs-libregnum-select-next-sibling)
    (define-key m (kbd "k")       #'cmacs-libregnum-select-parent)
    (define-key m (kbd "j")       #'cmacs-libregnum-select-child)
    (define-key m (kbd "h")       #'cmacs-libregnum-select-prev-sibling)
    (define-key m (kbd "l")       #'cmacs-libregnum-select-next-sibling)
    (define-key m (kbd "RET")     #'cmacs-libregnum-activate)
    (define-key m (kbd "u")       #'cmacs-libregnum-up)
    (define-key m (kbd "^")       #'cmacs-libregnum-up)
    m)
  "Keymap for `cmacs-libregnum-mode'.")

(defun cmacs-libregnum-toggle-animation ()
  "Toggle continuous animation for the current libregnum buffer.
Animated views are re-rendered at `cmacs-libregnum-target-fps' while
on-screen; static views render only on demand."
  (interactive)
  (unless (cmacs-libregnum-attached-p (current-buffer))
    (user-error "No libregnum view attached to this buffer"))
  (let ((on (not (cmacs-libregnum-animated-p (current-buffer)))))
    (cmacs-libregnum-set-animated (current-buffer) on
                                  cmacs-libregnum-target-fps)
    (message "cmacs-libregnum animation %s%s"
             (if on "on" "off")
             (if on (format " (%d FPS target)" cmacs-libregnum-target-fps)
               ""))))

(defun cmacs-libregnum-reload-from-buffer ()
  "Reload current scene from the buffer's YAML text."
  (interactive)
  (cmacs-libregnum--read-scene-from-buffer)
  (cmacs-libregnum-redraw-current))

(defun cmacs-libregnum-save-to-buffer ()
  "Snapshot current camera state into the buffer text."
  (interactive)
  (cmacs-libregnum--write-scene-to-buffer))

(defun cmacs-libregnum-redraw-current ()
  "Force a redraw of the current libregnum buffer's scene."
  (interactive)
  (when (cmacs-libregnum-attached-p (current-buffer))
    (cmacs-libregnum-redraw (current-buffer))))

;;;; Tree navigation --------------------------------------------------

(defvar-local cmacs-libregnum--scene-root nil
  "Absolute path of the project root for the current tree scene, if any.")
(defvar-local cmacs-libregnum--tree-model nil
  "Vector of node plists for the current scene (see `cmacs-libregnum-tree-nodes').")
(defvar-local cmacs-libregnum--children nil
  "Hash mapping a node id to the ordered list of its child ids.")
(defvar-local cmacs-libregnum--selected 0
  "Currently selected node id.")

(defun cmacs-libregnum--load-model ()
  "Refresh the navigation model from the C node table and select root."
  (setq cmacs-libregnum--tree-model
        (cmacs-libregnum-tree-nodes (current-buffer)))
  (setq cmacs-libregnum--children (make-hash-table :test 'eq))
  (when (vectorp cmacs-libregnum--tree-model)
    (dotimes (i (length cmacs-libregnum--tree-model))
      (let ((parent (plist-get (aref cmacs-libregnum--tree-model i) :parent)))
        (when parent
          (push i (gethash parent cmacs-libregnum--children)))))
    (maphash (lambda (k v)
               (puthash k (nreverse v) cmacs-libregnum--children))
             cmacs-libregnum--children)
    (cmacs-libregnum--select-id 0)))

(defun cmacs-libregnum--node (id)
  "Return the plist for node ID, or nil."
  (when (and (vectorp cmacs-libregnum--tree-model)
             (integerp id) (>= id 0)
             (< id (length cmacs-libregnum--tree-model)))
    (aref cmacs-libregnum--tree-model id)))

(defun cmacs-libregnum--select-id (id)
  "Select node ID, move the camera to it, and echo its path."
  (when-let* ((node (cmacs-libregnum--node id)))
    (setq cmacs-libregnum--selected id)
    (cmacs-libregnum-set-selection (current-buffer) id t)
    (let* ((path (plist-get node :path))
           (root cmacs-libregnum--scene-root)
           (rel (if (and root path (string-prefix-p
                                    (expand-file-name root) path))
                    (file-relative-name path root)
                  (plist-get node :name))))
      (message "%s%s" (if (plist-get node :dir) "[dir] " "") rel))))

(defun cmacs-libregnum-select-parent ()
  "Select the parent of the current node."
  (interactive)
  (let ((p (plist-get (cmacs-libregnum--node cmacs-libregnum--selected) :parent)))
    (if p (cmacs-libregnum--select-id p) (message "At root"))))

(defun cmacs-libregnum-select-child ()
  "Select the first child of the current node."
  (interactive)
  (let ((kids (gethash cmacs-libregnum--selected cmacs-libregnum--children)))
    (if kids (cmacs-libregnum--select-id (car kids))
      (message "No children"))))

(defun cmacs-libregnum--sibling (delta)
  "Select the sibling DELTA steps from the current node."
  (let ((p (plist-get (cmacs-libregnum--node cmacs-libregnum--selected) :parent)))
    (if (null p)
        (message "Root has no siblings")
      (let* ((sibs (gethash p cmacs-libregnum--children))
             (pos  (seq-position sibs cmacs-libregnum--selected)))
        (when pos
          (let ((n (+ pos delta)))
            (if (and (>= n 0) (< n (length sibs)))
                (cmacs-libregnum--select-id (nth n sibs))
              (message "No more siblings"))))))))

(defun cmacs-libregnum-select-next-sibling ()
  "Select the next sibling."
  (interactive)
  (cmacs-libregnum--sibling 1))

(defun cmacs-libregnum-select-prev-sibling ()
  "Select the previous sibling."
  (interactive)
  (cmacs-libregnum--sibling -1))

(defun cmacs-libregnum-activate ()
  "Open the selected file, or drill into the selected directory."
  (interactive)
  (when-let* ((node (cmacs-libregnum--node cmacs-libregnum--selected))
              (path (plist-get node :path)))
    (if (plist-get node :dir)
        (cmacs-libregnum--drill-to (current-buffer) path)
      (find-file path))))

(defun cmacs-libregnum--drill-to (buffer path)
  "Re-root BUFFER's tree scene at directory PATH."
  (with-current-buffer buffer
    (when (and (cmacs-libregnum-attached-p buffer)
               (stringp path) (file-directory-p path))
      (let ((abs (file-name-as-directory (expand-file-name path))))
        (cmacs-libregnum-build-tree buffer abs)
        (setq-local cmacs-libregnum--scene-root abs)
        (let ((alist (cmacs-libregnum--parse-buffer)))
          (setf (alist-get 'scene_type alist) "project_tree")
          (setf (alist-get 'project_root alist) (directory-file-name abs))
          (cmacs-libregnum--serialise-buffer alist))
        (cmacs-libregnum--load-model)))))

(defun cmacs-libregnum--node-clicked (buffer info)
  "Dispatch a viewport node click in BUFFER.
INFO is (ID PATH IS-DIR VX VY) from the C input layer (VX/VY are the
view-local click pixel; ID is -1 for an empty-space miss).  This single
entry point lets each scene/mode decide what a click means: the gnuseye
globe opens an entity detail view or measures, while the default tree
behaviour drills into a directory or visits a file.  Called on the cmacs
GMainContext."
  (when (buffer-live-p buffer)
    (let ((id (nth 0 info)) (path (nth 1 info)) (is-dir (nth 2 info))
          (vx (nth 3 info)) (vy (nth 4 info)))
      (with-current-buffer buffer
        (cond
         ((and (fboundp 'cmacs-gnuseye--on-pick)
               (derived-mode-p 'cmacs-gnuseye-mode))
          ;; PATH is the marker's entity-id string, captured synchronously at
          ;; pick time -- stable across the per-tick marker rebuilds (the
          ;; numeric node id is NOT: it may be stale by dispatch time).
          (cmacs-gnuseye--on-pick buffer id vx vy path))
         ((and (fboundp 'cmacs-roamgraph--on-pick)
               (derived-mode-p 'cmacs-roamgraph-mode))
          ;; Same discipline: PATH is the org-roam id string, which is
          ;; what every piece of roamgraph state is keyed on.
          (cmacs-roamgraph--on-pick buffer id vx vy path))
         (is-dir (cmacs-libregnum--drill-to buffer path))
         ((and (stringp path) (> (length path) 0)) (find-file path)))))))

(defun cmacs-libregnum--node-context-menu (buffer info)
  "Dispatch a viewport RIGHT-click in BUFFER to the mode's context menu.
INFO is (ID PATH IS-DIR VX VY) like `cmacs-libregnum--node-clicked'.
Runs on the cmacs GMainContext (inside the pselect wait), so handlers must
NOT pop a menu here -- re-schedule onto the command loop with a 0-delay
timer (the editor does the same)."
  (when (buffer-live-p buffer)
    (let ((id (nth 0 info)) (path (nth 1 info))
          (vx (nth 3 info)) (vy (nth 4 info)))
      (with-current-buffer buffer
        (cond
         ((and (fboundp 'cmacs-gnuseye--context-menu)
               (derived-mode-p 'cmacs-gnuseye-mode))
          (cmacs-gnuseye--context-menu buffer id path vx vy))
         ((and (fboundp 'cmacs-roamgraph--context-menu)
               (derived-mode-p 'cmacs-roamgraph-mode))
          (cmacs-roamgraph--context-menu buffer id path vx vy)))))))

;; ── 2D image-mode input dispatchers ────────────────────────────────────
;; The C input layer defers image-viewport mouse events here (document pixel
;; coords).  Each dispatcher forwards to a buffer-local hook function the
;; hosting editor (imgedit / vidstudio) installs, keeping this file
;; content-agnostic.  All run on the cmacs GMainContext.

(defvar-local cmacs-libregnum-image-press-function nil
  "Function called on image-viewport left press: (BUFFER DX DY BUTTON MODS).")
(defvar-local cmacs-libregnum-image-drag-function nil
  "Function called on image-viewport left drag: (BUFFER DX DY BUTTON MODS).")
(defvar-local cmacs-libregnum-image-release-function nil
  "Function called on image-viewport left release (after motion).")
(defvar-local cmacs-libregnum-image-click-function nil
  "Function called on image-viewport click (press+release, no motion).")
(defvar-local cmacs-libregnum-image-context-menu-function nil
  "Function called on image-viewport right release: (BUFFER DX DY FX FY).")
(defvar-local cmacs-libregnum-image-timeline-press-function nil
  "Timeline-strip press hook: (BUFFER FRAME CLIP-ID NEAR-EDGE).")
(defvar-local cmacs-libregnum-image-timeline-drag-function nil
  "Timeline-strip drag hook: (BUFFER FRAME CLIP-ID NEAR-EDGE).")
(defvar-local cmacs-libregnum-image-timeline-release-function nil
  "Timeline-strip release hook: (BUFFER FRAME CLIP-ID NEAR-EDGE).")

(defun cmacs-libregnum--image-dispatch (buffer hookvar dx dy button mods)
  "Call BUFFER's HOOKVAR with (BUFFER DX DY BUTTON MODS) if bound."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((fn (symbol-value hookvar)))
        (when (functionp fn)
          (funcall fn buffer dx dy button mods))))))

(defun cmacs-libregnum--image-press (buffer info)
  "Dispatch an image-viewport left press.  INFO is (DX DY BUTTON MODS)."
  (cmacs-libregnum--image-dispatch buffer 'cmacs-libregnum-image-press-function
                                   (nth 0 info) (nth 1 info) (nth 2 info)
                                   (nth 3 info)))

(defun cmacs-libregnum--image-drag (buffer info)
  "Dispatch an image-viewport left drag.  INFO is (DX DY BUTTON MODS)."
  (cmacs-libregnum--image-dispatch buffer 'cmacs-libregnum-image-drag-function
                                   (nth 0 info) (nth 1 info) (nth 2 info)
                                   (nth 3 info)))

(defun cmacs-libregnum--image-release (buffer info)
  "Dispatch an image-viewport left release.  INFO is (DX DY BUTTON MODS)."
  (cmacs-libregnum--image-dispatch buffer
                                   'cmacs-libregnum-image-release-function
                                   (nth 0 info) (nth 1 info) (nth 2 info)
                                   (nth 3 info)))

(defun cmacs-libregnum--image-click (buffer info)
  "Dispatch an image-viewport click.  INFO is (DX DY BUTTON MODS)."
  (cmacs-libregnum--image-dispatch buffer 'cmacs-libregnum-image-click-function
                                   (nth 0 info) (nth 1 info) (nth 2 info)
                                   (nth 3 info)))

(defun cmacs-libregnum--image-timeline-dispatch (buffer hookvar info)
  "Call BUFFER's timeline HOOKVAR with (BUFFER FRAME CLIP-ID NEAR-EDGE)."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((fn (symbol-value hookvar)))
        (when (functionp fn)
          (funcall fn buffer (nth 0 info) (nth 1 info) (nth 2 info)))))))

(defun cmacs-libregnum--image-timeline-press (buffer info)
  "Dispatch a timeline-strip press.  INFO is (FRAME CLIP-ID NEAR-EDGE 0)."
  (cmacs-libregnum--image-timeline-dispatch
   buffer 'cmacs-libregnum-image-timeline-press-function info))

(defun cmacs-libregnum--image-timeline-drag (buffer info)
  "Dispatch a timeline-strip drag.  INFO is (FRAME CLIP-ID NEAR-EDGE 0)."
  (cmacs-libregnum--image-timeline-dispatch
   buffer 'cmacs-libregnum-image-timeline-drag-function info))

(defun cmacs-libregnum--image-timeline-release (buffer info)
  "Dispatch a timeline-strip release.  INFO is (FRAME CLIP-ID NEAR-EDGE 0)."
  (cmacs-libregnum--image-timeline-dispatch
   buffer 'cmacs-libregnum-image-timeline-release-function info))

(defun cmacs-libregnum--image-context-menu (buffer info)
  "Dispatch an image-viewport right-click.  INFO is (DX DY FX FY CLIP-ID),
where CLIP-ID is the timeline clip under the cursor (-1 = none).
Runs inside the pselect wait, so the handler must NOT pop a menu here --
re-schedule onto the command loop with a 0-delay timer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((fn cmacs-libregnum-image-context-menu-function))
        (when (functionp fn)
          (funcall fn buffer (nth 0 info) (nth 1 info)
                   (nth 2 info) (nth 3 info) (nth 4 info)))))))

(defun cmacs-libregnum-up ()
  "Re-root the tree at the parent of the current root directory."
  (interactive)
  (let* ((root (directory-file-name
                (or cmacs-libregnum--scene-root default-directory)))
         (parent (file-name-directory root)))
    (if (and parent (not (equal (directory-file-name parent) root)))
        (cmacs-libregnum--drill-to (current-buffer) parent)
      (message "At filesystem root"))))

(defun cmacs-libregnum--on-kill ()
  "Tear down the view when the buffer is killed."
  (when (cmacs-libregnum-attached-p (current-buffer))
    (cmacs-libregnum-detach (current-buffer))))

;;;###autoload
(define-derived-mode cmacs-libregnum-mode special-mode "cmacs-3D"
  "Major mode for cmacs-libregnum 3D scene buffers.

The buffer IS the 3D view: cmacs's pgtk_handle_draw blits the
view's BGRA framebuffer across the window's text area every
redisplay.  Buffer text is the YAML serialisation of the scene
state (camera, layout options, selection).

\\{cmacs-libregnum-mode-map}"
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format
              '("%e" mode-line-front-space mode-line-buffer-identification
                "  cmacs-libregnum-mode"))
  (add-hook 'kill-buffer-hook #'cmacs-libregnum--on-kill nil t)
  (add-hook 'before-save-hook
            #'cmacs-libregnum--write-scene-to-buffer nil t)
  ;; Attach the view (idempotent).
  (let ((sz cmacs-libregnum-default-size))
    (cmacs-libregnum-attach (current-buffer) (car sz) (cdr sz)))
  ;; If the buffer was visiting a file with prior scene state,
  ;; rebuild the scene + restore the camera now.  Skip when the
  ;; buffer is a fresh interactive shell (no `scene_type:' yet).
  (when (and buffer-file-name
             (> (buffer-size) 0)
             (save-excursion (goto-char (point-min))
                             (re-search-forward "^scene_type:" nil t)))
    (cmacs-libregnum--read-scene-from-buffer)))

;; Under Evil (Doom), a `special-mode' buffer sits in normal/motion
;; state, where j/k/h/l/g/a/RET are Evil motions that shadow this mode's
;; single-key bindings (hence "j" -> evil-next-line -> "end of buffer").
;; These buffers are non-editable 3D viewports, so start them in Evil
;; *emacs state* and let the major-mode keymap own every key.  No-op
;; without Evil.
(defun cmacs-libregnum-evil-normal-state ()
  "Drop a libregnum viewport out of Evil emacs-state into normal state.
These 3-D viewport buffers sit in Evil *emacs state* so their single-key
camera/navigation bindings work directly (see comment above).  That means a
bare <escape> would not return to normal state the way an Evil user expects,
so this command -- bound to <escape> -- does it explicitly.  Re-enter
navigation (emacs state) with \\[evil-emacs-state] (C-z).  A no-op without Evil."
  (interactive)
  (when (fboundp 'evil-normal-state)
    (evil-normal-state)))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-libregnum-mode 'emacs))
  ;; Keep Evil window management (C-w ...) usable even though scene buffers
  ;; sit in emacs state for their single-key navigation.
  (when (and (boundp 'evil-window-map) (keymapp evil-window-map))
    (define-key cmacs-libregnum-mode-map (kbd "C-w") evil-window-map))
  ;; <escape> (the GUI escape key, distinct from the ESC meta-prefix) leaves
  ;; emacs state for normal state -- what an Evil user reaches for.  Inherited
  ;; by `cmacs-libregnum-editor-mode' (and the CAD viewport) via the parent
  ;; keymap.  Bound only under Evil so non-Evil setups are unaffected.
  (define-key cmacs-libregnum-mode-map (kbd "<escape>")
              #'cmacs-libregnum-evil-normal-state))

;;;; Entry points ----------------------------------------------------

;;;###autoload
(defun cmacs-libregnum-demo ()
  "Open a blank cmacs-libregnum scene buffer (smoke test)."
  (interactive)
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let ((buf (get-buffer-create "*cmacs-libregnum demo*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# cmacs-libregnum demo scene\n")
        (insert "# (whole window is the 3D view; this text is hidden\n")
        (insert "#  behind the BGRA blit)\n"))
      (cmacs-libregnum-mode))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(defun cmacs-libregnum-project-tree (&optional root)
  "Open a libregnum scene visualising the project file tree under ROOT.
With no ROOT, uses the current project root if `project-current'
returns one, otherwise `default-directory'.  Each regular file becomes
a coloured cube; height encodes file size, hue encodes extension.
Left- or right-drag to orbit, middle-drag to pan, scroll-wheel to zoom."
  (interactive)
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let* ((dir (or root
                  (when (fboundp 'project-current)
                    (when-let* ((proj (project-current nil)))
                      (if (fboundp 'project-root)
                          (project-root proj)
                        (car (with-no-warnings
                               (project-roots proj))))))
                  default-directory))
         (abs (file-name-as-directory (expand-file-name dir)))
         (buf (get-buffer-create
               (format "*cmacs-libregnum tree: %s*"
                       (file-name-nondirectory
                        (directory-file-name abs))))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# -*- mode: cmacs-libregnum -*-\n")
        (insert "scene_type: project_tree\n")
        (insert (format "project_root: %s\n" abs)))
      (cmacs-libregnum-mode)
      (setq-local cmacs-libregnum--scene-root abs)
      (cmacs-libregnum-build-tree (current-buffer) abs)
      (cmacs-libregnum--load-model))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(defun cmacs-libregnum-gobject-graph (&optional namespace)
  "Open a libregnum scene visualising the GObject class hierarchy.
With prefix arg or NAMESPACE non-nil, prompts for a leading type-name
prefix (e.g. \"Gtk\", \"Lrg\") to scope the graph."
  (interactive
   (list (when current-prefix-arg
           (read-string "Type-name prefix (empty = all): "))))
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let* ((ns (and namespace (not (string-empty-p namespace)) namespace))
         (buf (get-buffer-create
               (if ns (format "*cmacs-libregnum gobject: %s*" ns)
                 "*cmacs-libregnum gobject*"))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# -*- mode: cmacs-libregnum -*-\n")
        (insert "scene_type: gobject\n")
        (when ns (insert (format "namespace: %s\n" ns))))
      (cmacs-libregnum-mode)
      (cmacs-libregnum-build-gobject (current-buffer) ns))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(defun cmacs-libregnum-mind-map (org-file)
  "Open a libregnum scene visualising the heading tree of ORG-FILE."
  (interactive
   (list (read-file-name "Org file: " nil nil t
                         (when (and buffer-file-name
                                    (string-match-p "\\.org\\'" buffer-file-name))
                           (file-name-nondirectory buffer-file-name)))))
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let* ((abs (expand-file-name org-file))
         (buf (get-buffer-create
               (format "*cmacs-libregnum mindmap: %s*"
                       (file-name-nondirectory abs)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# -*- mode: cmacs-libregnum -*-\n")
        (insert "scene_type: mindmap\n")
        (insert (format "org_file: %s\n" abs)))
      (cmacs-libregnum-mode)
      (cmacs-libregnum-build-mindmap (current-buffer) abs))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(add-to-list 'auto-mode-alist
             '("\\.lrg-scene\\'" . cmacs-libregnum-mode))

;;;; Game-module hosting ----------------------------------------------

;; A libregnum game packaged as a loadable module (.so, built with
;; LRG_DEFINE_GAME_MODULE) can be hosted in a buffer: the C layer drives
;; the game each frame into the view's framebuffer and routes mouse input
;; to it.  Keyboard input is forwarded from this minor mode, because Emacs
;; owns the keymap (the game's hidden window never sees real key events).

(declare-function cmacs-libregnum-load-game "cmacs-libregnum-defuns.c"
                  (buffer so-path &optional argv))
(declare-function cmacs-libregnum-unload-game "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-game-loaded-p "cmacs-libregnum-defuns.c"
                  (buffer))
(declare-function cmacs-libregnum-game-key "cmacs-libregnum-defuns.c"
                  (buffer grl-key press))

(defcustom cmacs-libregnum-game-key-release-delay 0.4
  "Seconds after a key's last press before it is reported released to the game.
Emacs delivers no key-release events, so a held key is emulated from the
keyboard's auto-repeat: each repeat re-arms this timer, and when the
repeats stop the key is released.  Set this a little longer than your
system's key-repeat delay to avoid a held key stuttering; lower it for a
snappier release once you let go."
  :type 'number
  :group 'cmacs-libregnum)

;; raylib/graylib KeyboardKey (GrlKey) codes for the non-ASCII keys.
;; (Letters/digits/space and most punctuation already equal their raylib
;; code, modulo lowercase->uppercase for letters; see the mapping below.)
(defconst cmacs-libregnum-game--symbol-keys
  '((left . 263) (right . 262) (up . 265) (down . 264)
    (return . 257) (kp-enter . 257) (tab . 258) (backspace . 259)
    (escape . 256) (delete . 261) (deletechar . 261) (insert . 260)
    (home . 268) (end . 269) (prior . 266) (next . 267)
    (f1 . 290) (f2 . 291) (f3 . 292) (f4 . 293) (f5 . 294) (f6 . 295)
    (f7 . 296) (f8 . 297) (f9 . 298) (f10 . 299) (f11 . 300) (f12 . 301))
  "Alist mapping Emacs key symbols to graylib GrlKey integer codes.")

(defun cmacs-libregnum-game--char->grl (ch)
  "Map a character key event CH to a GrlKey integer, or nil."
  (cond
   ((and (>= ch ?a) (<= ch ?z)) (- ch 32))        ; a..z -> KEY_A..KEY_Z
   ((and (>= ch ?A) (<= ch ?Z)) ch)               ; A..Z already 65..90
   ((and (>= ch ?0) (<= ch ?9)) ch)               ; 0..9 already 48..57
   ;; space + punctuation whose ASCII value equals its raylib KEY_ code
   ((memq ch '(?\s 39 44 45 46 47 59 61 91 92 93 96)) ch)
   (t nil)))

(defun cmacs-libregnum-game--event->grl (event)
  "Map an Emacs key EVENT (character or symbol) to a GrlKey integer, or nil."
  (cond
   ((integerp event)
    (cond
     ((= event ?\r) 257)                           ; RET
     ((= event ?\t) 258)                           ; TAB
     ((= event 127) 259)                           ; DEL / backspace
     ((= event ?\e) 256)                           ; ESC
     (t (cmacs-libregnum-game--char->grl event))))
   ((symbolp event)
    (cdr (assq event cmacs-libregnum-game--symbol-keys)))))

(defvar-local cmacs-libregnum-game--held nil
  "Hash table mapping a currently-held GrlKey to its pending release timer.")

(defun cmacs-libregnum-game--press (grl)
  "Report GrlKey GRL as pressed to the game, auto-releasing after a delay.
A first press is forwarded immediately; subsequent auto-repeats only
re-arm the release timer so the key stays down while physically held."
  (let ((buf (current-buffer)))
    (unless (hash-table-p cmacs-libregnum-game--held)
      (setq cmacs-libregnum-game--held (make-hash-table :test 'eq)))
    (let ((tm (gethash grl cmacs-libregnum-game--held)))
      (if (timerp tm)
          (cancel-timer tm)                         ; already down: re-arm only
        (cmacs-libregnum-game-key buf grl t))       ; first press
      (puthash grl
               (run-at-time
                cmacs-libregnum-game-key-release-delay nil
                (lambda ()
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (when (hash-table-p cmacs-libregnum-game--held)
                        (remhash grl cmacs-libregnum-game--held))
                      (ignore-errors
                        (cmacs-libregnum-game-key buf grl nil))))))
               cmacs-libregnum-game--held))))

(defun cmacs-libregnum-game--release-all ()
  "Cancel all hold timers and release every currently-held key."
  (when (hash-table-p cmacs-libregnum-game--held)
    (let ((buf (current-buffer)))
      (maphash (lambda (grl tm)
                 (when (timerp tm) (cancel-timer tm))
                 (ignore-errors (cmacs-libregnum-game-key buf grl nil)))
               cmacs-libregnum-game--held)
      (clrhash cmacs-libregnum-game--held))))

(defun cmacs-libregnum-game-dispatch-key ()
  "Forward the key that invoked this command to the hosted game.
Bound to the game keys in `cmacs-libregnum-game-mode-map'."
  (interactive)
  (let ((grl (cmacs-libregnum-game--event->grl last-command-event)))
    (when (and grl (cmacs-libregnum-game-loaded-p (current-buffer)))
      (cmacs-libregnum-game--press grl))))

(defun cmacs-libregnum-game-quit ()
  "Release held keys, unload the game, and kill the buffer."
  (interactive)
  (cmacs-libregnum-game--release-all)
  (when (and (cmacs-libregnum-attached-p (current-buffer))
             (cmacs-libregnum-game-loaded-p (current-buffer)))
    (cmacs-libregnum-unload-game (current-buffer)))
  (when (bound-and-true-p cmacs-libregnum-game-mode)
    (cmacs-libregnum-game-mode -1))
  (kill-buffer (current-buffer)))

(defvar cmacs-libregnum-game-mode-map
  (let ((m (make-sparse-keymap)))
    ;; Letters, digits, space -> the game.
    (dolist (ch (number-sequence ?a ?z))
      (define-key m (vector ch) #'cmacs-libregnum-game-dispatch-key))
    (dolist (ch (number-sequence ?0 ?9))
      (define-key m (vector ch) #'cmacs-libregnum-game-dispatch-key))
    (define-key m (kbd "SPC") #'cmacs-libregnum-game-dispatch-key)
    ;; Arrows, editing keys, function keys, and 1:1 punctuation.
    (dolist (k '("<left>" "<right>" "<up>" "<down>"
                 "RET" "<return>" "TAB" "<tab>" "<backspace>" "DEL"
                 "<prior>" "<next>" "<home>" "<end>" "<insert>" "<delete>"
                 "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>"
                 "<f7>" "<f8>" "<f9>" "<f10>" "<f11>" "<f12>"
                 "-" "=" "[" "]" ";" "'" "," "." "/" "`" "\\"))
      (define-key m (kbd k) #'cmacs-libregnum-game-dispatch-key))
    ;; Escape is left to Emacs (it is the meta prefix); quit with C-c C-q.
    (define-key m (kbd "C-c C-q") #'cmacs-libregnum-game-quit)
    m)
  "Keymap for `cmacs-libregnum-game-mode'.")

;; Doom/Evil: a game buffer sits in Evil emacs state so WASD and friends
;; reach the game instead of being read as Evil motions.  In emacs state
;; C-w is not the window prefix, so rebind it to the Evil window map here --
;; otherwise window management (C-w v / s / h j k l / c / o ...) would be
;; unavailable while a game is focused.  No effect without Evil.
(with-eval-after-load 'evil
  (when (and (boundp 'evil-window-map) (keymapp evil-window-map))
    (define-key cmacs-libregnum-game-mode-map (kbd "C-w") evil-window-map)))

;;;###autoload
(define-minor-mode cmacs-libregnum-game-mode
  "Forward keyboard input from this buffer to a hosted libregnum game.

Enable this in a buffer whose libregnum view has a game module loaded
\(see `cmacs-libregnum-play').  Game keys (letters, digits, space, the
arrows, and common editing/function keys) are sent to the game; mouse
input is routed by the C layer.  Quit with \\[cmacs-libregnum-game-quit].

Because Emacs has no key-release events, a held key is emulated from
keyboard auto-repeat -- see `cmacs-libregnum-game-key-release-delay'.

Under Doom/Evil the buffer stays in Evil emacs state so these keys reach
the game; the C-w window-command prefix is preserved, so window
management (C-w v, C-w s, C-w h/j/k/l, ...) still works while playing.

\\{cmacs-libregnum-game-mode-map}"
  :lighter " LRG-Game"
  :keymap cmacs-libregnum-game-mode-map
  (if cmacs-libregnum-game-mode
      (setq cmacs-libregnum-game--held (make-hash-table :test 'eq))
    (cmacs-libregnum-game--release-all)))

;;;###autoload
(defun cmacs-libregnum-play (module &optional argv)
  "Open a buffer hosting the libregnum game MODULE (a built game `.so').
The buffer renders the game and forwards keyboard and mouse input to it.
MODULE is a shared object built with `LRG_DEFINE_GAME_MODULE'.

Optional ARGV is a list of strings passed verbatim to the module as a
CLI-style argument vector (e.g. '(\"--profile\" \"warm\"))."
  (interactive
   (list (read-file-name
          "Game module (.so): " nil nil t nil
          (lambda (f) (or (file-directory-p f) (string-suffix-p ".so" f))))))
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let* ((abs (expand-file-name module))
         (buf (get-buffer-create
               (format "*cmacs-libregnum game: %s*"
                       (file-name-nondirectory abs)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# cmacs-libregnum game view\n"))
      ;; Major mode attaches the view + sets up the per-redisplay blit.
      (cmacs-libregnum-mode)
      (cmacs-libregnum-load-game (current-buffer) abs argv)
      ;; Minor mode (after load) forwards keyboard input to the game.
      (cmacs-libregnum-game-mode 1))
    (switch-to-buffer buf)
    buf))

;;; ─────────────────────────────────────────────────────────────────
;;; Editor / level authoring
;;;
;;; `cmacs-libregnum-editor-mode' hosts an engine LrgEditor whose level is
;;; baked into the scene drawables, so the 3D viewport, picking and
;;; `cmacs-libregnum-tree-nodes' double as the editor viewport and outliner.
;;; Edits go through the engine's undoable command stack (the C primitives
;;; `cmacs-libregnum-editor-*').  The full native panel UI (property
;;; inspector, asset drag-and-drop) is still being built; this provides the
;;; core authoring loop: new/open/save, place primitives, select, move,
;;; delete, undo/redo, and a tree outliner.

;; LrgPrimitiveType integer values (see deps/libregnum/src/lrg-enums.h).
(defconst cmacs-libregnum-primitive-plane        0)
(defconst cmacs-libregnum-primitive-cube         1)
(defconst cmacs-libregnum-primitive-circle       2)
(defconst cmacs-libregnum-primitive-uv-sphere    3)
(defconst cmacs-libregnum-primitive-ico-sphere   4)
(defconst cmacs-libregnum-primitive-cylinder     5)
(defconst cmacs-libregnum-primitive-cone         6)
(defconst cmacs-libregnum-primitive-torus        7)
(defconst cmacs-libregnum-primitive-grid         8)
(defconst cmacs-libregnum-primitive-rectangle-2d 10)
(defconst cmacs-libregnum-primitive-circle-2d    11)

;; LrgNodeVisualKind values, for non-primitive placeable nodes.
(defconst cmacs-libregnum-visual-mesh-asset 2)
(defconst cmacs-libregnum-visual-sprite     3)
(defconst cmacs-libregnum-visual-tilemap    4)
(defconst cmacs-libregnum-visual-light      5)
(defconst cmacs-libregnum-visual-camera     6)
(defconst cmacs-libregnum-visual-audio      7)
(defconst cmacs-libregnum-visual-prefab     8)

;; LrgScriptLanguage values, for `cmacs-libregnum-editor-attach-script'.
(defconst cmacs-libregnum-script-languages
  '(("lua" . 1) ("python" . 2) ("gjs" . 3) ("crispy" . 4))
  "Alist of script language name → `LrgScriptLanguage' int.")

(defvar-local cmacs-libregnum-editor--current nil
  "Scene node id of the current editor selection, or nil.")

(defvar-local cmacs-libregnum-editor--src-buffer nil
  "In an outliner buffer, the editor buffer it reflects.")

(defcustom cmacs-libregnum-editor-nudge-step 0.25
  "World-unit distance one keyboard nudge moves the selected node.
A numeric prefix argument multiplies it (e.g. \\[universal-argument] 4 = 4× the step)."
  :type 'number
  :group 'cmacs-libregnum)

(defcustom cmacs-libregnum-editor-snap-steps '(nil 0.25 0.5 1.0)
  "Grid sizes `cmacs-libregnum-editor-cycle-snap' cycles through.
nil means no snapping; numbers snap moves/drags to that grid."
  :type '(repeat (choice (const :tag "off" nil) number))
  :group 'cmacs-libregnum)

(defvar-local cmacs-libregnum-editor--snap nil
  "Current translate grid (a number) for keyboard nudge + mouse drag, or nil.")

(defvar-local cmacs-libregnum-editor--audio-handle nil
  "Integer handle from `cmacs-audio-play-file' for the currently-playing audio
node in this editor buffer, or nil when nothing is playing.")

(defvar cmacs-libregnum-editor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c")        #'cmacs-libregnum-editor-add-cube)
    (define-key map (kbd "b")        #'cmacs-libregnum-editor-add-sphere)
    (define-key map (kbd "y")        #'cmacs-libregnum-editor-add-cylinder)
    (define-key map (kbd "n")        #'cmacs-libregnum-editor-add-plane)
    (define-key map (kbd "x")        #'cmacs-libregnum-editor-delete-current)
    (define-key map (kbd "<delete>") #'cmacs-libregnum-editor-delete-current)
    (define-key map (kbd "m")        #'cmacs-libregnum-editor-move-current)
    ;; Move the selection with the keyboard: arrows / hjkl nudge on the ground
    ;; (X/Z) plane; J/K and PageUp/Down nudge vertically (Y).  A numeric prefix
    ;; multiplies the step.  (Mouse: just drag the object in the viewport.)
    (define-key map (kbd "<left>")   #'cmacs-libregnum-editor-nudge-left)
    (define-key map (kbd "<right>")  #'cmacs-libregnum-editor-nudge-right)
    (define-key map (kbd "<up>")     #'cmacs-libregnum-editor-nudge-forward)
    (define-key map (kbd "<down>")   #'cmacs-libregnum-editor-nudge-back)
    (define-key map (kbd "h")        #'cmacs-libregnum-editor-nudge-left)
    (define-key map (kbd "l")        #'cmacs-libregnum-editor-nudge-right)
    (define-key map (kbd "k")        #'cmacs-libregnum-editor-nudge-forward)
    (define-key map (kbd "j")        #'cmacs-libregnum-editor-nudge-back)
    (define-key map (kbd "K")        #'cmacs-libregnum-editor-nudge-up)
    (define-key map (kbd "J")        #'cmacs-libregnum-editor-nudge-down)
    (define-key map (kbd "<prior>")  #'cmacs-libregnum-editor-nudge-up)
    (define-key map (kbd "<next>")   #'cmacs-libregnum-editor-nudge-down)
    (define-key map (kbd "s")        #'cmacs-libregnum-editor-cycle-snap)
    (define-key map (kbd "f")        #'cmacs-libregnum-editor-focus-selected)
    ;; Rotate (about Y / X) and scale the selection.  Numeric prefix multiplies.
    (define-key map (kbd "[")        #'cmacs-libregnum-editor-rotate-ccw)
    (define-key map (kbd "]")        #'cmacs-libregnum-editor-rotate-cw)
    (define-key map (kbd "{")        #'cmacs-libregnum-editor-rotate-pitch-up)
    (define-key map (kbd "}")        #'cmacs-libregnum-editor-rotate-pitch-down)
    (define-key map (kbd "=")        #'cmacs-libregnum-editor-scale-up)
    (define-key map (kbd "+")        #'cmacs-libregnum-editor-scale-up)
    (define-key map (kbd "-")        #'cmacs-libregnum-editor-scale-down)
    ;; Gizmo tool: drag the on-screen handles for axis-constrained transforms.
    (define-key map (kbd "w")        #'cmacs-libregnum-editor-tool-translate)
    (define-key map (kbd "e")        #'cmacs-libregnum-editor-tool-rotate)
    (define-key map (kbd "r")        #'cmacs-libregnum-editor-tool-scale)
    (define-key map (kbd "t")        #'cmacs-libregnum-editor-tool-select)
    (define-key map (kbd "v")        #'cmacs-libregnum-editor-toggle-2d)
    (define-key map (kbd "u")        #'cmacs-libregnum-editor-undo-edit)
    (define-key map (kbd "C-r")      #'cmacs-libregnum-editor-redo-edit)
    (define-key map (kbd "o")        #'cmacs-libregnum-editor-outliner)
    (define-key map (kbd "p")        #'cmacs-libregnum-editor-palette)
    (define-key map (kbd "i")        #'cmacs-libregnum-editor-inspector)
    (define-key map (kbd "A")        #'cmacs-libregnum-editor-assets)
    (define-key map (kbd "L")        #'cmacs-libregnum-editor-add-script)
    (define-key map (kbd "T")        #'cmacs-libregnum-editor-tilemap-create)
    ;; Scene-shading toggle (G for Global illumination).
    (define-key map (kbd "G")        #'cmacs-libregnum-editor-toggle-shading)
    ;; Stop look-through camera.
    (define-key map (kbd "C-c l")    #'cmacs-libregnum-editor-stop-look-through)
    (define-key map (kbd "C-c p")    #'cmacs-libregnum-editor-prefab-save)
    (define-key map (kbd "C-c P")    #'cmacs-libregnum-editor-place-prefab)
    (define-key map (kbd "C-c i")    #'cmacs-libregnum-editor-scene-import)
    (define-key map (kbd "C-c a")    #'cmacs-libregnum-editor-play-audio)
    (define-key map (kbd "C-c A")    #'cmacs-libregnum-editor-stop-audio)
    (define-key map (kbd "<f5>")     #'cmacs-libregnum-editor-play-toggle)
    (define-key map (kbd "C-x C-s")  #'cmacs-libregnum-editor-save-as)
    ;; Neutralize parent (scene) bindings whose semantics are wrong for an
    ;; editable level: RET would `find-file' a node's guid, ^ re-roots a file
    ;; tree, and `g r' reloads the buffer (wiping the level).
    (define-key map (kbd "RET")      #'ignore)
    (define-key map (kbd "^")        #'ignore)
    (define-key map (kbd "g r")      #'ignore)
    map)
  "Keymap for `cmacs-libregnum-editor-mode'.")

(defconst cmacs-libregnum-editor--hint
  (concat " Libregnum editor — "
          "[c]ube [b]all [y]cyl [n]plane  "
          "gizmo [w]move [e]rot [r]scale (drag handles)  [v]2D [x]del  "
          "[u]ndo [C-r]edo  [p]al [o]ut [i]nsp [A]ssets [L]ogic [G]I [f5]play "
          "[C-x C-s]save  right-click: menu")
  "Header-line hint shown over the editor viewport (the window body is the
3D view, so on-screen affordances live in the header line until the native
panels land).  [G] toggles scene-wide shading (global illumination).")

(define-derived-mode cmacs-libregnum-editor-mode cmacs-libregnum-mode
  "cmacs-Editor"
  "Major mode: edit a libregnum level in a live 3D viewport buffer.

The whole window body is the live 3D viewport (a blit over hidden text), so
the editor is driven by keys; the header line lists them.  A brand-new level
is empty, so the viewport starts black — press \\<cmacs-libregnum-editor-mode-map>\\[cmacs-libregnum-editor-add-cube] to place a cube
at the origin (the default camera is framed on it).

\\{cmacs-libregnum-editor-mode-map}"
  (setq-local cmacs-libregnum-editor--current nil)
  ;; The header line is window chrome above the viewport blit, so it stays
  ;; visible and gives the otherwise-hidden keyboard controls a home.
  (setq-local header-line-format cmacs-libregnum-editor--hint)
  ;; The parent mode's navigation keys read these buffer-locals, but the
  ;; editor never runs `cmacs-libregnum--load-model', so initialise them to an
  ;; empty model.  (A nil `cmacs-libregnum--children' crashes inherited nav
  ;; with "wrong type argument: hash-table-p, nil".)
  (setq-local cmacs-libregnum--tree-model [])
  (setq-local cmacs-libregnum--children (make-hash-table :test 'eq)))

(defun cmacs-libregnum-editor--buffer ()
  "Return the current editor buffer, or signal if not in one."
  (unless (derived-mode-p 'cmacs-libregnum-editor-mode)
    (user-error "Not in a cmacs-libregnum editor buffer"))
  (current-buffer))

;;;###autoload
(defun cmacs-libregnum-editor (&optional file)
  "Open the libregnum level editor.
With a prefix arg, prompt for a `.rlevel' FILE to open; otherwise start
an empty level."
  (interactive
   (list (when current-prefix-arg
           (read-file-name "Open .rlevel: " nil nil t))))
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let ((buf (get-buffer-create "*cmacs-libregnum editor*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# -*- mode: cmacs-libregnum-editor -*-\n")
        (insert "# libregnum level editor (whole window is the 3D viewport)\n"))
      (cmacs-libregnum-editor-mode)
      (if (and file (file-exists-p file))
          (cmacs-libregnum-editor-open buf (expand-file-name file))
        (cmacs-libregnum-editor-new buf)))
    (switch-to-buffer buf)
    ;; Editor perspective: primitive palette over the node outliner on the
    ;; left, the property inspector on the right, viewport in the middle.
    (with-current-buffer buf
      (cmacs-libregnum-editor-palette)
      (cmacs-libregnum-editor-outliner)
      (cmacs-libregnum-editor-inspector))
    (message "%s" cmacs-libregnum-editor--hint)
    buf))

(defun cmacs-libregnum-editor--add (prim name)
  "Add a PRIM (LrgPrimitiveType int) primitive named NAME, select it, and
refresh the side panels so the new node shows in the outliner + inspector."
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor-add-primitive buf prim name)))
    (setq cmacs-libregnum-editor--current id)
    (when id
      ;; Select the new node in the engine so the inspector (which reads the
      ;; engine selection) shows it.
      (ignore-errors (cmacs-libregnum-editor-select buf id))
      ;; A node was added: refresh the outliner LIST (so its row exists), then
      ;; sync point + the inspector to the new selection.
      (let ((out (get-buffer "*cmacs-libregnum outliner*")))
        (when (and out (buffer-live-p out))
          (with-current-buffer out
            (when (eq cmacs-libregnum-editor--src-buffer buf)
              (ignore-errors (cmacs-libregnum-outliner-refresh))))))
      (cmacs-libregnum-editor--sync-panels buf id)
      (message "Added %s (node %d)" name id))
    id))

(defun cmacs-libregnum-editor-add-cube ()
  "Add a cube to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-cube "Cube"))

(defun cmacs-libregnum-editor-add-sphere ()
  "Add a sphere to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-uv-sphere "Sphere"))

(defun cmacs-libregnum-editor-add-cylinder ()
  "Add a cylinder to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-cylinder "Cylinder"))

(defun cmacs-libregnum-editor-add-plane ()
  "Add a plane to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-plane "Plane"))

(defun cmacs-libregnum-editor-add-ico-sphere ()
  "Add an icosphere to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-ico-sphere
                               "IcoSphere"))

(defun cmacs-libregnum-editor-add-cone ()
  "Add a cone to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-cone "Cone"))

(defun cmacs-libregnum-editor-add-torus ()
  "Add a torus to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-torus "Torus"))

(defun cmacs-libregnum-editor-add-circle ()
  "Add a circle (flat disc) to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-circle "Circle"))

(defun cmacs-libregnum-editor-add-grid ()
  "Add a reference grid to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-grid "Grid"))

(defun cmacs-libregnum-editor-add-rectangle-2d ()
  "Add a 2D rectangle (flat slab) to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-rectangle-2d "Rect2D"))

(defun cmacs-libregnum-editor-add-circle-2d ()
  "Add a 2D circle (flat disc) to the level."
  (interactive)
  (cmacs-libregnum-editor--add cmacs-libregnum-primitive-circle-2d "Circle2D"))

(defun cmacs-libregnum-editor--add-visual (kind name &optional asset)
  "Add a KIND (an `LrgNodeVisualKind' int) node named NAME with ASSET; select it."
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor-add-visual buf kind asset name)))
    (setq cmacs-libregnum-editor--current id)
    (when id (message "Added %s%s" name (if id (format " (node %d)" id) "")))
    id))

(defun cmacs-libregnum-editor-add-light ()
  "Add a light node (gizmo) to the level."
  (interactive)
  (cmacs-libregnum-editor--add-visual cmacs-libregnum-visual-light "Light"))

(defun cmacs-libregnum-editor-add-camera ()
  "Add a camera node (gizmo) to the level."
  (interactive)
  (cmacs-libregnum-editor--add-visual cmacs-libregnum-visual-camera "Camera"))

(defun cmacs-libregnum-editor-add-audio ()
  "Add an audio-emitter node (gizmo) to the level."
  (interactive)
  (cmacs-libregnum-editor--add-visual cmacs-libregnum-visual-audio "Audio"))

(defun cmacs-libregnum-editor-add-mesh (file)
  "Add a mesh-asset node loading FILE (a .glb/.gltf/.obj model)."
  (interactive
   (list (read-file-name "Mesh model (.glb/.gltf/.obj): " nil nil t)))
  (cmacs-libregnum-editor--add-visual cmacs-libregnum-visual-mesh-asset
                                      (file-name-nondirectory file)
                                      (expand-file-name file)))

(defun cmacs-libregnum-editor-add-sprite (file)
  "Add a sprite node showing image FILE (gizmo placeholder until textured)."
  (interactive (list (read-file-name "Sprite image: " nil nil t)))
  (cmacs-libregnum-editor--add-visual cmacs-libregnum-visual-sprite
                                      (file-name-nondirectory file)
                                      (expand-file-name file)))

(defvar cmacs-libregnum-editor-tilemap-brush 0
  "Tile index painted by `cmacs-libregnum-editor-tilemap-paint'.")

(defun cmacs-libregnum-editor-tilemap-create (file tile-w tile-h cols
                                              map-w map-h)
  "Add a tilemap node using tileset image FILE.
TILE-W x TILE-H is the tile pixel size, COLS the tileset columns, and
MAP-W x MAP-H the map size in cells.  Persisted in the level."
  (interactive
   (list (read-file-name "Tileset image: " nil nil t)
         (read-number "Tile width (px): " 16)
         (read-number "Tile height (px): " 16)
         (read-number "Tileset columns: " 1)
         (read-number "Map width (cells): " 8)
         (read-number "Map height (cells): " 8)))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id (cmacs-libregnum-editor-add-visual
              buf cmacs-libregnum-visual-tilemap "Tilemap"
              (expand-file-name file))))
    (cmacs-libregnum-editor-tilemap-config
     buf id (expand-file-name file) tile-w tile-h cols map-w map-h)
    (setq cmacs-libregnum-editor--current id)
    (message "Tilemap %dx%d created (node %d); M-x \
cmacs-libregnum-editor-tilemap-paint to paint" map-w map-h id)
    id))

(defun cmacs-libregnum-editor-tilemap-set-brush (tile)
  "Set the tile index TILE painted by the tilemap brush."
  (interactive (list (read-number "Brush tile index: "
                                  cmacs-libregnum-editor-tilemap-brush)))
  (setq cmacs-libregnum-editor-tilemap-brush tile)
  (message "Tilemap brush = tile %d" tile))

(defun cmacs-libregnum-editor-tilemap-paint ()
  "Paint the selected tilemap by clicking its cells in the viewport.
Each click sets the cell under the cursor to the current brush tile
\(`cmacs-libregnum-editor-tilemap-brush'); painting stays armed until
\\[cmacs-libregnum-editor-stop-paint]."
  (interactive)
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf))
         (info (and id (cmacs-libregnum-editor-tilemap-info buf id))))
    (cond
     ((null id) (user-error "Select a tilemap node first"))
     ((null info) (user-error "Selected node %d is not a tilemap" id))
     (t (cmacs-libregnum-editor--arm
         buf
         (lambda (b wx wy wz)
           (let* ((nfo (cmacs-libregnum-editor-tilemap-info b id))
                  (loc (cmacs-libregnum-editor-node-location b id))
                  (mw (plist-get nfo :map-w))
                  (mh (plist-get nfo :map-h))
                  (ox (- (nth 0 loc) (/ mw 2.0)))
                  (oz (- (nth 2 loc) (/ mh 2.0)))
                  (cx (floor (- wx ox)))
                  (cy (floor (- wz oz))))
             (when (and (>= cx 0) (< cx mw) (>= cy 0) (< cy mh))
               (cmacs-libregnum-editor-tilemap-set-tile
                b id cx cy cmacs-libregnum-editor-tilemap-brush))))
         (format "tile %d" cmacs-libregnum-editor-tilemap-brush)
         t)))))

(defun cmacs-libregnum-editor--available-languages ()
  "Languages libregnum was actually built with, as an alist (NAME . INT).
Falls back to the static list if the runtime query is unavailable."
  (or (and (fboundp 'cmacs-libregnum-scripting-languages)
           (ignore-errors (cmacs-libregnum-scripting-languages)))
      cmacs-libregnum-script-languages))

(defun cmacs-libregnum-editor-add-script (language file)
  "Attach a LANGUAGE script FILE to the selected node (persisted in the level).
Only languages compiled into libregnum are offered.  Wraps the
`cmacs-libregnum-editor-attach-script' primitive and installs a hot-reload
hook on FILE's buffer."
  (interactive
   (let ((langs (cmacs-libregnum-editor--available-languages)))
     (when (null langs)
       (user-error "No scripting backends are built into libregnum"))
     (list (completing-read "Language: " langs nil t)
           (read-file-name "Script file: "))))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf))
         (langs (cmacs-libregnum-editor--available-languages))
         (lang (cdr (assoc language langs))))
    (cond
     ((null id) (user-error "No node selected"))
     ((null lang) (user-error "Unknown/unavailable language: %s" language))
     (t (cmacs-libregnum-editor-attach-script buf id lang
                                              (expand-file-name file))
        (cmacs-libregnum-editor--watch-script (expand-file-name file) buf)
        (message "Attached %s script to node %d (%d total)" language id
                 (or (cmacs-libregnum-editor-node-script-count buf id) 0))))))

(defun cmacs-libregnum-editor--watch-script (file editor-buf)
  "Open FILE and install a hot-reload after-save-hook bound to EDITOR-BUF."
  (when (file-exists-p file)
    (with-current-buffer (find-file-noselect file)
      (setq-local cmacs-libregnum-editor--src-buffer editor-buf)
      (add-hook 'after-save-hook
                #'cmacs-libregnum-editor--script-saved nil t))))

(defun cmacs-libregnum-editor--script-saved ()
  "Hot-reload: when a watched script is saved, re-run the play world if active."
  (let ((eb cmacs-libregnum-editor--src-buffer))
    (when (and (buffer-live-p eb)
               (ignore-errors (cmacs-libregnum-editor-playing-p eb)))
      (cmacs-libregnum-editor-stop eb)
      (cmacs-libregnum-editor-play eb)
      (message "libregnum: reloaded scripts (replayed)"))))

(defconst cmacs-libregnum-editor--script-templates
  `((1 ".lua" . ,(concat "-- libregnum node script (Lua)\n"
                         "-- Define start(node) / update(node, dt) if your\n"
                         "-- libregnum build calls the script lifecycle hooks.\n\n"
                         "function start(node)\nend\n\n"
                         "function update(node, dt)\nend\n"))
    (2 ".py" . ,(concat "# libregnum node script (Python)\n\n"
                        "def start(node):\n    pass\n\n"
                        "def update(node, dt):\n    pass\n"))
    (3 ".js" . ,(concat "// libregnum node script (GJS)\n\n"
                        "function start(node) {}\n\n"
                        "function update(node, dt) {}\n"))
    (4 ".c" . ,(concat "/* libregnum node script (crispy C).\n"
                       "   main() runs when the script component starts. */\n"
                       "#include <glib.h>\n\n"
                       "int\nmain (void)\n{\n"
                       "  g_print (\"hello from node script\\n\");\n"
                       "  return 0;\n}\n")))
  "Per-language (LANG-INT EXT . TEMPLATE) starter scaffolds for new scripts.
LANG-INT matches `cmacs-libregnum-script-languages' (1 Lua, 2 Python, 3 GJS,
4 crispy).")

(defun cmacs-libregnum-editor--script-ext (lang)
  "File extension for script LANGUAGE int LANG (default \".txt\")."
  (or (cadr (assq lang cmacs-libregnum-editor--script-templates)) ".txt"))

(defun cmacs-libregnum-editor--script-template (lang)
  "Starter scaffold text for script LANGUAGE int LANG (default empty)."
  (or (cddr (assq lang cmacs-libregnum-editor--script-templates)) ""))

(defun cmacs-libregnum-editor--read-language ()
  "Prompt for an available script language; return (NAME . INT)."
  (let ((langs (cmacs-libregnum-editor--available-languages)))
    (when (null langs)
      (user-error "No scripting backends are built into libregnum"))
    (let ((name (completing-read "Language: " langs nil t)))
      (cons name (cdr (assoc name langs))))))

(defun cmacs-libregnum-editor--ctx-existing-script (buffer id)
  "Attach an EXISTING script file to node ID in BUFFER."
  (let* ((lang (cmacs-libregnum-editor--read-language))
         (file (expand-file-name (read-file-name "Existing script file: "
                                                 nil nil t))))
    (cond
     ((null (cdr lang)) (user-error "Unknown/unavailable language: %s" (car lang)))
     ((not (file-exists-p file)) (user-error "No such file: %s" file))
     (t (cmacs-libregnum-editor-attach-script buffer id (cdr lang) file)
        (cmacs-libregnum-editor--watch-script file buffer)
        (cmacs-libregnum-editor--sync-panels buffer id)
        (message "Attached %s script to node %d (%d total)" (car lang) id
                 (or (cmacs-libregnum-editor-node-script-count buffer id) 0))))))

(defun cmacs-libregnum-editor--ctx-new-script (buffer id)
  "Create a NEW script file (scaffolded), attach it to node ID, and open it."
  (let* ((lang (cmacs-libregnum-editor--read-language))
         (lint (cdr lang))
         (ext  (cmacs-libregnum-editor--script-ext lint))
         (file (expand-file-name
                (read-file-name (format "New %s script file: " (car lang))
                                nil nil nil (concat "node-script" ext)))))
    (when (null lint)
      (user-error "Unknown/unavailable language: %s" (car lang)))
    (when (or (not (file-exists-p file))
              (yes-or-no-p (format "%s exists; overwrite? " file)))
      (let ((dir (file-name-directory file)))
        (when (and dir (not (file-directory-p dir)))
          (make-directory dir t)))
      (write-region (cmacs-libregnum-editor--script-template lint) nil file)
      (cmacs-libregnum-editor-attach-script buffer id lint file)
      (cmacs-libregnum-editor--watch-script file buffer)
      (cmacs-libregnum-editor--sync-panels buffer id)
      (find-file-other-window file)
      (message "Created + attached %s script to node %d" (car lang) id))))

(defun cmacs-libregnum-editor-prefab-save (file)
  "Save the selected node's subtree to a .rprefab FILE for reuse.
Wraps the `cmacs-libregnum-editor-save-prefab' primitive."
  (interactive (list (read-file-name "Save prefab to: " nil nil nil nil
                                     (lambda (n) (string-suffix-p ".rprefab" n)))))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (cond
     ((null id) (user-error "No node selected"))
     ((cmacs-libregnum-editor-save-prefab buf id (expand-file-name file))
      (message "Saved prefab: %s" file))
     (t (user-error "Could not save prefab")))))

(defun cmacs-libregnum-editor-place-prefab (file)
  "Instantiate a .rprefab FILE into the level under the selection (or root)."
  (interactive (list (read-file-name "Prefab: " nil nil t nil
                                     (lambda (n) (string-suffix-p ".rprefab" n)))))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (parent (cmacs-libregnum-editor--sel buf))
         (newid (cmacs-libregnum-editor-instantiate-prefab
                 buf (expand-file-name file) parent)))
    (if newid
        (progn
          (cmacs-libregnum-editor-select buf newid)
          (when (get-buffer "*cmacs-libregnum outliner*")
            (cmacs-libregnum-editor-outliner))
          (cmacs-libregnum-editor--sync-panels buf newid)
          (message "Placed prefab as node %d" newid))
      (user-error "Could not load prefab: %s" file))))

(defun cmacs-libregnum-editor-scene-import (file)
  "Import a Blender-exported scene YAML FILE as the editor's current level.
Wraps the `cmacs-libregnum-editor-import-scene' primitive."
  (interactive (list (read-file-name "Import scene (.yaml): " nil nil t)))
  (let ((buf (cmacs-libregnum-editor--buffer)))
    (if (cmacs-libregnum-editor-import-scene buf (expand-file-name file))
        (progn
          (when (get-buffer "*cmacs-libregnum outliner*")
            (cmacs-libregnum-editor-outliner))
          (message "Imported scene: %s" file))
      (user-error "Could not import scene: %s" file))))

(defun cmacs-libregnum-project-new (root name)
  "Scaffold a new libregnum project at ROOT named NAME and open its level.
Creates levels/ assets/ scripts/, a project.ryaml manifest, and a starter
levels/main.rlevel."
  (interactive (list (read-directory-name "New project dir: ")
                     (read-string "Project name: " "Game")))
  (let* ((root (expand-file-name root))
         (lvl  (expand-file-name "levels/main.rlevel" root)))
    (make-directory (expand-file-name "levels" root) t)
    (make-directory (expand-file-name "assets" root) t)
    (make-directory (expand-file-name "scripts" root) t)
    (unless (cmacs-libregnum-project-create root name
                                            "levels/main.rlevel" "build/game.so")
      (user-error "Could not write project manifest"))
    (cmacs-libregnum-editor)
    (let ((buf (get-buffer "*cmacs-libregnum editor*")))
      (cmacs-libregnum-editor-save buf lvl))
    (message "Project created at %s (level %s)" root lvl)))

(defun cmacs-libregnum-project-open (root)
  "Open the libregnum project at ROOT and load its default level."
  (interactive (list (read-directory-name "Project dir: ")))
  (cmacs-libregnum-editor)
  (let ((buf (get-buffer "*cmacs-libregnum editor*")))
    (if (cmacs-libregnum-editor-open-project buf (expand-file-name root))
        (progn
          (when (get-buffer "*cmacs-libregnum outliner*")
            (cmacs-libregnum-editor-outliner))
          (message "Opened project: %s" root))
      (user-error "No project.ryaml at %s" root))))

;;; Light / camera / audio authoring + audio playback.  The light/audio range
;;; spheres + camera frustum render live from these visual params.

(defun cmacs-libregnum-editor-set-light (range red green blue)
  "Set the selected LIGHT node's RANGE and colour (RED GREEN BLUE, 0-255).
The viewport draws a range sphere in that colour."
  (interactive (list (read-number "Light range: " 4)
                     (read-number "R (0-255): " 250)
                     (read-number "G (0-255): " 240)
                     (read-number "B (0-255): " 140)))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (unless id (user-error "No node selected"))
    (cmacs-libregnum-editor-set-visual-param buf id "range" range)
    (cmacs-libregnum-editor-set-visual-param buf id "r" red)
    (cmacs-libregnum-editor-set-visual-param buf id "g" green)
    (cmacs-libregnum-editor-set-visual-param buf id "b" blue)
    (message "Light: range %s, rgb %s/%s/%s" range red green blue)))

(defun cmacs-libregnum-editor-set-camera-fov (fov)
  "Set the selected CAMERA node's field of view FOV (degrees).
The viewport draws a frustum at that angle."
  (interactive (list (read-number "Camera FOV (deg): " 50)))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (unless id (user-error "No node selected"))
    (cmacs-libregnum-editor-set-visual-param buf id "fov" fov)
    (message "Camera FOV %s" fov)))

(defun cmacs-libregnum-editor-set-audio-range (range)
  "Set the selected AUDIO node's RANGE (draws a range sphere)."
  (interactive (list (read-number "Audio range: " 4)))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (unless id (user-error "No node selected"))
    (cmacs-libregnum-editor-set-visual-param buf id "range" range)
    (message "Audio range %s" range)))

(defun cmacs-libregnum-editor-play-audio ()
  "Play the selected AUDIO node's sound file.
When `cmacs-audio-supported-p' is non-nil, uses the cmacs-audio subsystem
\(GStreamer-backed): stores the playback handle buffer-locally, reads the
node's \"volume\" visual param, and registers a state-handler to clear the
handle on EOS/error/closed.  Falls back to `play-sound-file' (synchronous,
WAV/AU only) when the cmacs-audio subsystem is absent."
  (interactive)
  (let* ((buf   (cmacs-libregnum-editor--buffer))
         (id    (cmacs-libregnum-editor--sel buf))
         (asset (and id (cmacs-libregnum-editor-node-asset buf id))))
    (cond
     ((null id)    (user-error "No node selected"))
     ((null asset) (user-error "Node %d has no sound asset" id))
     ((not (file-exists-p asset))
      (user-error "Sound file not found: %s" asset))
     ;; cmacs-audio path (preferred).  Note `cmacs-audio-supported-p' is a C
     ;; primitive (always present in an audio build), but `cmacs-audio-play-file'
     ;; lives in cmacs-audio.el, which may not be loaded yet -- load it before
     ;; relying on it, and fall back to `play-sound-file' if it (or playback)
     ;; is unavailable.
     ((and (fboundp 'cmacs-audio-supported-p)
           (cmacs-audio-supported-p)
           (progn (unless (fboundp 'cmacs-audio-play-file)
                    (ignore-errors (require 'cmacs-audio nil t)))
                  (fboundp 'cmacs-audio-play-file)))
      (let* ((abs (expand-file-name asset))
             (vol (if (fboundp 'cmacs-libregnum-editor-get-visual-param)
                      (ignore-errors
                        (cmacs-libregnum-editor-get-visual-param
                         buf id "volume" 1.0))
                    1.0))
             (handle (ignore-errors (cmacs-audio-play-file abs))))
        (if (null handle)
            ;; Playback could not start (no audio sink, unreadable file, ...);
            ;; fall back to the synchronous built-in player.
            (condition-case e
                (progn (play-sound-file abs)
                       (message "Playing %s" (file-name-nondirectory asset)))
              (error (user-error "Could not play %s: %S" asset e)))
          ;; Stop any previously playing handle in this buffer.
          (when-let* ((old (buffer-local-value
                            'cmacs-libregnum-editor--audio-handle buf)))
            (ignore-errors (cmacs-audio-close old)))
          (with-current-buffer buf
            (setq cmacs-libregnum-editor--audio-handle handle))
          ;; Honour the node's volume param.
          (when (and vol (numberp vol))
            (ignore-errors (cmacs-audio-set-volume handle vol)))
          ;; Clear the handle automatically on end-of-stream / error / close.
          (when (fboundp 'cmacs-audio-add-state-handler)
            (ignore-errors
              (cmacs-audio-add-state-handler
               handle
               (let ((b buf))
                 (lambda (_h state)
                   (when (memq state '(eos error closed))
                     (when (buffer-live-p b)
                       (with-current-buffer b
                         (setq cmacs-libregnum-editor--audio-handle nil)))))))))
          (message "Playing %s (handle %s)"
                   (file-name-nondirectory asset) handle))))
     ;; Fallback: synchronous built-in player.
     (t
      (condition-case e
          (progn (play-sound-file (expand-file-name asset))
                 (message "Playing %s" (file-name-nondirectory asset)))
        (error (user-error "Could not play %s: %S" asset e)))))))

(defun cmacs-libregnum-editor-stop-audio ()
  "Stop the currently-playing audio in this editor buffer.
Closes the buffer-local cmacs-audio handle if one is live; no-op otherwise."
  (interactive)
  (let ((handle cmacs-libregnum-editor--audio-handle))
    (cond
     ((null handle)
      (user-error "No audio is playing in this buffer"))
     ((not (fboundp 'cmacs-audio-close))
      (user-error "cmacs-audio not available"))
     (t
      (ignore-errors (cmacs-audio-stop handle))
      (ignore-errors (cmacs-audio-close handle))
      (setq cmacs-libregnum-editor--audio-handle nil)
      (message "Audio stopped")))))

(defun cmacs-libregnum-editor-set-audio-volume (volume)
  "Set the selected AUDIO node's volume to VOLUME (0.0 to 1.0).
Persists the value via the visual-param \"volume\" (read back at next
`cmacs-libregnum-editor-play-audio').  If audio is currently playing, also
adjusts the live handle immediately."
  (interactive (list (read-number "Volume (0.0 to 1.0): " 1.0)))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf))
         (v   (max 0.0 (min 1.0 (float volume)))))
    (unless id (user-error "No node selected"))
    (cmacs-libregnum-editor-set-visual-param buf id "volume" v)
    ;; Apply to the live handle if one exists.
    (when-let* ((handle cmacs-libregnum-editor--audio-handle))
      (when (fboundp 'cmacs-audio-set-volume)
        (ignore-errors (cmacs-audio-set-volume handle v))))
    (message "Audio volume set to %.2f" v)))

;;; ─── Scene-shading (global illumination / ambient) toggle ──────────────────

(defun cmacs-libregnum-editor-toggle-shading ()
  "Toggle scene-wide shading (global illumination / ambient) for this buffer.
When on, the renderer applies ambient + GI; when off it shows flat unlit colour.
Requires the `cmacs-libregnum-editor-set-shading' C DEFUN (built in parallel);
the command is a no-op + message if that DEFUN is absent."
  (interactive)
  (let ((buf (cmacs-libregnum-editor--buffer)))
    (cond
     ((not (fboundp 'cmacs-libregnum-editor-set-shading))
      (message "cmacs-libregnum-editor-set-shading not yet available"))
     (t
      (let* ((on (if (fboundp 'cmacs-libregnum-editor-shading-p)
                     (ignore-errors (cmacs-libregnum-editor-shading-p buf))
                   nil))
             (next (not on)))
        (ignore-errors (cmacs-libregnum-editor-set-shading buf next))
        (message "Scene shading %s" (if next "on (GI / ambient)" "off")))))))

;;; ─── Look-through camera ────────────────────────────────────────────────────

(defun cmacs-libregnum-editor-stop-look-through ()
  "Stop look-through-camera mode and restore the free-fly viewport camera.
Wraps `cmacs-libregnum-editor-look-through-off'; no-op if the DEFUN is absent."
  (interactive)
  (cond
   ((not (fboundp 'cmacs-libregnum-editor-look-through-off))
    (message "cmacs-libregnum-editor-look-through-off not yet available"))
   (t
    (ignore-errors
      (cmacs-libregnum-editor-look-through-off
       (cmacs-libregnum-editor--buffer)))
    (message "Stopped look-through; back to free-fly camera"))))

(defvar cmacs-libregnum-editor--play-timer nil
  "Repeating timer ticking the play-in-editor world, or nil.")

(defun cmacs-libregnum-editor-play-toggle ()
  "Start or stop play-in-editor for this level.
Instantiates the level into a runtime world and ticks it ~30 Hz; the level
document itself is never mutated.  Press again to stop."
  (interactive)
  (let ((buf (cmacs-libregnum-editor--buffer)))
    (if (cmacs-libregnum-editor-playing-p buf)
        (progn
          (when (timerp cmacs-libregnum-editor--play-timer)
            (cancel-timer cmacs-libregnum-editor--play-timer))
          (setq cmacs-libregnum-editor--play-timer nil)
          (cmacs-libregnum-editor-stop buf)
          (message "Stopped play-in-editor"))
      (if (not (cmacs-libregnum-editor-play buf))
          (user-error "Could not instantiate the level")
        (setq cmacs-libregnum-editor--play-timer
              (run-with-timer
               0.033 0.033
               (lambda (b)
                 (if (and (buffer-live-p b)
                          (cmacs-libregnum-editor-playing-p b))
                     (cmacs-libregnum-editor-play-tick b 0.033)
                   (when (timerp cmacs-libregnum-editor--play-timer)
                     (cancel-timer cmacs-libregnum-editor--play-timer))))
               buf))
        (message "Playing — press the play key again to stop")))))

(defun cmacs-libregnum-editor--sel (&optional buf)
  "Return the selected node id in BUF (default the current editor buffer).
Prefers the engine selection (so viewport mouse picks count), falling back to
the last Lisp-side selection.  Returns nil when nothing is selected."
  (let ((buf (or buf (cmacs-libregnum-editor--buffer))))
    (or (cmacs-libregnum-editor-selected-id buf)
        (buffer-local-value 'cmacs-libregnum-editor--current buf))))

(defun cmacs-libregnum-editor-delete-current ()
  "Delete the currently selected node."
  (interactive)
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (if (null id)
        (user-error "No node selected")
      (cmacs-libregnum-editor-delete buf id)
      (setq cmacs-libregnum-editor--current nil)
      (message "Deleted node"))))

(defun cmacs-libregnum-editor-move-current (x y z)
  "Set the current node's local position to (X Y Z).
This types exact coordinates; for interactive moving, drag the object in the
viewport or nudge it with the arrow / hjkl keys."
  (interactive "nX: \nnY: \nnZ: ")
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (if (null id)
        (user-error "No node selected")
      (cmacs-libregnum-editor-set-position buf id x y z)
      (setq cmacs-libregnum-editor--current id))))

(defun cmacs-libregnum-editor--snap-value (v)
  "Round V to the active editor grid, or return V unchanged when snapping off."
  (if (and (numberp cmacs-libregnum-editor--snap)
           (> cmacs-libregnum-editor--snap 0))
      (* (round v cmacs-libregnum-editor--snap) cmacs-libregnum-editor--snap)
    v))

(defun cmacs-libregnum-editor--nudge (dx dy dz)
  "Move the selected node by (DX DY DZ) times the nudge step.
A numeric prefix argument multiplies the step; honours the active snap grid."
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (if (null id)
        (user-error "No node selected — click one or add a shape first")
      (let* ((mult (if current-prefix-arg
                       (prefix-numeric-value current-prefix-arg) 1))
             (step (* cmacs-libregnum-editor-nudge-step mult))
             (loc (cmacs-libregnum-editor-node-location buf id))
             (x (cmacs-libregnum-editor--snap-value (+ (nth 0 loc) (* dx step))))
             (y (cmacs-libregnum-editor--snap-value (+ (nth 1 loc) (* dy step))))
             (z (cmacs-libregnum-editor--snap-value (+ (nth 2 loc) (* dz step)))))
        (cmacs-libregnum-editor-set-position buf id x y z)
        (setq cmacs-libregnum-editor--current id)
        (message "Moved node %d to (%.2f %.2f %.2f)" id x y z)))))

(defun cmacs-libregnum-editor-nudge-left ()
  "Nudge the selection along -X."
  (interactive) (cmacs-libregnum-editor--nudge -1 0 0))
(defun cmacs-libregnum-editor-nudge-right ()
  "Nudge the selection along +X."
  (interactive) (cmacs-libregnum-editor--nudge 1 0 0))
(defun cmacs-libregnum-editor-nudge-forward ()
  "Nudge the selection along -Z (away)."
  (interactive) (cmacs-libregnum-editor--nudge 0 0 -1))
(defun cmacs-libregnum-editor-nudge-back ()
  "Nudge the selection along +Z (toward)."
  (interactive) (cmacs-libregnum-editor--nudge 0 0 1))
(defun cmacs-libregnum-editor-nudge-up ()
  "Nudge the selection along +Y (up)."
  (interactive) (cmacs-libregnum-editor--nudge 0 1 0))
(defun cmacs-libregnum-editor-nudge-down ()
  "Nudge the selection along -Y (down)."
  (interactive) (cmacs-libregnum-editor--nudge 0 -1 0))

(defun cmacs-libregnum-editor-cycle-snap ()
  "Cycle the move/drag grid through `cmacs-libregnum-editor-snap-steps'."
  (interactive)
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (steps cmacs-libregnum-editor-snap-steps)
         (tail (member cmacs-libregnum-editor--snap steps))
         (next (if (and tail (cdr tail)) (cadr tail) (car steps))))
    (setq cmacs-libregnum-editor--snap next)
    (cmacs-libregnum-editor-set-snap buf (or next 0))
    (message "Move snap: %s" (if next (format "%s units" next) "off"))))

(defun cmacs-libregnum-editor-focus-selected ()
  "Frame the camera on the selected node."
  (interactive)
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (if (null id)
        (user-error "No node selected")
      (cmacs-libregnum-editor-focus buf id))))

(defcustom cmacs-libregnum-editor-rotate-step (/ float-pi 12)
  "Radians one keyboard rotate step turns the selected node (default 15°).
A numeric prefix argument multiplies it."
  :type 'number
  :group 'cmacs-libregnum)

(defcustom cmacs-libregnum-editor-scale-step 0.1
  "Amount one keyboard scale step adds to / removes from each axis.
A numeric prefix argument multiplies it."
  :type 'number
  :group 'cmacs-libregnum)

(defun cmacs-libregnum-editor--rotate (drx dry drz)
  "Rotate the selected node by (DRX DRY DRZ) * `cmacs-libregnum-editor-rotate-step'."
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (if (null id)
        (user-error "No node selected")
      (let* ((mult (if current-prefix-arg
                       (prefix-numeric-value current-prefix-arg) 1))
             (s   (* cmacs-libregnum-editor-rotate-step mult))
             (rot (cmacs-libregnum-editor-node-rotation buf id))
             (x (+ (nth 0 rot) (* drx s)))
             (y (+ (nth 1 rot) (* dry s)))
             (z (+ (nth 2 rot) (* drz s))))
        (cmacs-libregnum-editor-set-rotation buf id x y z)
        (setq cmacs-libregnum-editor--current id)
        (message "Rotated node %d to (%.0f° %.0f° %.0f°)" id
                 (radians-to-degrees x) (radians-to-degrees y)
                 (radians-to-degrees z))))))

(defun cmacs-libregnum-editor-rotate-ccw ()
  "Rotate the selection counter-clockwise about the Y axis (yaw)."
  (interactive) (cmacs-libregnum-editor--rotate 0 1 0))
(defun cmacs-libregnum-editor-rotate-cw ()
  "Rotate the selection clockwise about the Y axis (yaw)."
  (interactive) (cmacs-libregnum-editor--rotate 0 -1 0))
(defun cmacs-libregnum-editor-rotate-pitch-up ()
  "Rotate the selection about +X (pitch)."
  (interactive) (cmacs-libregnum-editor--rotate 1 0 0))
(defun cmacs-libregnum-editor-rotate-pitch-down ()
  "Rotate the selection about -X (pitch)."
  (interactive) (cmacs-libregnum-editor--rotate -1 0 0))

(defun cmacs-libregnum-editor--scale (dsx dsy dsz)
  "Add (DSX DSY DSZ) * `cmacs-libregnum-editor-scale-step' to the node scale."
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf)))
    (if (null id)
        (user-error "No node selected")
      (let* ((mult (if current-prefix-arg
                       (prefix-numeric-value current-prefix-arg) 1))
             (s   (* cmacs-libregnum-editor-scale-step mult))
             (scl (cmacs-libregnum-editor-node-scale buf id))
             (x (max 0.05 (+ (nth 0 scl) (* dsx s))))
             (y (max 0.05 (+ (nth 1 scl) (* dsy s))))
             (z (max 0.05 (+ (nth 2 scl) (* dsz s)))))
        (cmacs-libregnum-editor-set-scale buf id x y z)
        (setq cmacs-libregnum-editor--current id)
        (message "Scaled node %d to (%.2f %.2f %.2f)" id x y z)))))

(defun cmacs-libregnum-editor-scale-up ()
  "Scale the selection up uniformly."
  (interactive) (cmacs-libregnum-editor--scale 1 1 1))
(defun cmacs-libregnum-editor-scale-down ()
  "Scale the selection down uniformly."
  (interactive) (cmacs-libregnum-editor--scale -1 -1 -1))

;; On-screen gizmo tools.  The handles are drawn by the C layer over the
;; selection; the user drags an axis handle in the viewport to transform along
;; it (mouse handling is in cmacs-libregnum-input.c).
(defun cmacs-libregnum-editor-tool-select ()
  "Hide the transform gizmo (selection only)."
  (interactive)
  (cmacs-libregnum-editor-set-tool (cmacs-libregnum-editor--buffer) 0)
  (message "Gizmo: off (select)"))
(defun cmacs-libregnum-editor-tool-translate ()
  "Show the translate gizmo (drag the arrows to move along an axis)."
  (interactive)
  (cmacs-libregnum-editor-set-tool (cmacs-libregnum-editor--buffer) 1)
  (message "Gizmo: translate — drag an arrow"))
(defun cmacs-libregnum-editor-tool-rotate ()
  "Show the rotate gizmo (drag a ring to rotate about an axis)."
  (interactive)
  (cmacs-libregnum-editor-set-tool (cmacs-libregnum-editor--buffer) 2)
  (message "Gizmo: rotate — drag a ring"))
(defun cmacs-libregnum-editor-tool-scale ()
  "Show the scale gizmo (drag a handle to scale along an axis)."
  (interactive)
  (cmacs-libregnum-editor-set-tool (cmacs-libregnum-editor--buffer) 3)
  (message "Gizmo: scale — drag a handle"))

(defun cmacs-libregnum-editor-toggle-2d ()
  "Toggle a top-down orthographic 2D view (for 2D levels)."
  (interactive)
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (now (not (cmacs-libregnum-editor-view-2d-p buf))))
    (cmacs-libregnum-editor-set-view-2d buf now)
    (message "View: %s" (if now "2D (top-down ortho)" "3D (perspective)"))))

(defun cmacs-libregnum-editor--sync-panels (buffer &optional id)
  "Refresh the outliner + inspector side panels for BUFFER's selection.
Call this from EVERY path that changes the selection (viewport pick, outliner,
palette/add, keyboard) so the inspector always tracks what is selected.  When
ID is a valid node id, the outliner point is moved to its row; the inspector
always rebuilds from the editor's *current* selection regardless of ID.  Each
panel only follows BUFFER if it is the editor that panel is showing."
  (when (buffer-live-p buffer)
    (let ((out (get-buffer "*cmacs-libregnum outliner*")))
      (when (and out (buffer-live-p out) (integerp id) (>= id 0))
        (with-current-buffer out
          (when (eq cmacs-libregnum-editor--src-buffer buffer)
            (ignore-errors (cmacs-libregnum-outliner--goto-id id))))))
    (let ((insp (get-buffer "*cmacs-libregnum inspector*")))
      (when (and insp (buffer-live-p insp))
        (with-current-buffer insp
          (when (eq cmacs-libregnum-editor--src-buffer buffer)
            (ignore-errors (cmacs-libregnum-inspector--rebuild))))))
    ;; A viewport pick is consumed in the C input layer and never reaches the
    ;; command loop, so this runs deferred (via the cmacs GMainContext, inside
    ;; the pselect wait) with NO redisplay otherwise scheduled -- the rebuilt
    ;; panels would not repaint until the next user event (the "delayed
    ;; inspector").  Mark just the panel windows, then force an immediate
    ;; redisplay so they update the instant you click; targeting only the panels
    ;; avoids dragging the viewport through its (~35ms) Emacs-redisplay path.
    ;; From command-loop callers the extra `(redisplay)' is a cheap no-op-ish
    ;; repaint that the command loop would do anyway.
    (let ((insp (get-buffer "*cmacs-libregnum inspector*"))
          (out  (get-buffer "*cmacs-libregnum outliner*")))
      (when (buffer-live-p insp) (force-window-update insp))
      (when (buffer-live-p out)  (force-window-update out))
      (when (or (buffer-live-p insp) (buffer-live-p out))
        (redisplay)))))

(defun cmacs-libregnum-editor--on-select (buffer id)
  "Sync editor BUFFER's selection to node ID picked in the viewport.
Called (deferred onto the cmacs context) from the C input layer after a
viewport click or drag, so the keyboard commands, outliner and inspector
follow the mouse."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cmacs-libregnum-editor--current
            (and (integerp id) (>= id 0) id)))
    (cmacs-libregnum-editor--sync-panels buffer id)
    (run-hook-with-args 'cmacs-libregnum-editor-select-functions
                        buffer id)))

(defvar cmacs-libregnum-editor-select-functions nil
  "Functions run with (BUFFER ID) after a viewport selection change.
Subsystem panels (e.g. the CAD feature tree) refresh from here.")

;;; ─── Right-click context menu ──────────────────────────────────────────
;;;
;;; A right-CLICK (press+release without movement) on an entity in the viewport
;;; pops a real GTK menu (Emacs `x-popup-menu', which the pgtk build renders as
;;; a native GTK menu) whose items vary by the node's kind.  A right-DRAG still
;;; pans the camera.  The C input layer (cmacs-libregnum-input.c) ray-picks the
;;; node and defers `cmacs-libregnum-editor--context-menu' onto the cmacs
;;; GMainContext; that runs during the pselect wait, so we must NOT pop the menu
;;; there (a nested GTK menu loop would re-enter the GLib dispatch).  Instead we
;;; re-schedule the pop onto the Emacs command loop with a 0-delay timer.
;;;
;;; The menu is data-driven: add an item by adding one plist to
;;; `cmacs-libregnum-editor-context-menu-items'.

;;; Declare new C DEFUNs being built in parallel.  All calls are fboundp-guarded
;;; so the file byte-compiles cleanly when they are absent.

;;; Scene-shading (global illumination / ambient) toggle.
(declare-function cmacs-libregnum-editor-set-shading
                  "cmacs-libregnum-defuns.c" (buffer on))
(declare-function cmacs-libregnum-editor-shading-p
                  "cmacs-libregnum-defuns.c" (buffer))

;;; Look-through camera.
(declare-function cmacs-libregnum-editor-look-through
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-look-through-off
                  "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-editor-look-through-p
                  "cmacs-libregnum-defuns.c" (buffer))

;;; Per-node visual param reader (for wireframe, cast_shadow, volume, ...).
(declare-function cmacs-libregnum-editor-get-visual-param
                  "cmacs-libregnum-defuns.c" (buffer id name default))

;;; cmacs-audio subsystem (--with-cmacs-audio gated; all calls fboundp-guarded).
(declare-function cmacs-audio-supported-p   "cmacs-audio.c" ())
(declare-function cmacs-audio-play-file     "cmacs-audio.c" (path))
(declare-function cmacs-audio-stop          "cmacs-audio.c" (handle))
(declare-function cmacs-audio-close         "cmacs-audio.c" (handle))
(declare-function cmacs-audio-set-volume    "cmacs-audio.c" (handle v))
(declare-function cmacs-audio-state         "cmacs-audio.c" (handle))
(declare-function cmacs-audio-add-state-handler "cmacs-audio.c" (handle fn))

(declare-function cmacs-libregnum-editor-set-color
                  "cmacs-libregnum-defuns.c" (buffer id r g b a))
(declare-function cmacs-libregnum-editor-node-color
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-set-roughness
                  "cmacs-libregnum-defuns.c" (buffer id v))
(declare-function cmacs-libregnum-editor-set-metallic
                  "cmacs-libregnum-defuns.c" (buffer id v))
(declare-function cmacs-libregnum-editor-duplicate-node
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-node-parent
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-add-empty
                  "cmacs-libregnum-defuns.c" (buffer name parent-id))
(declare-function cmacs-libregnum-editor-node-scripts
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-detach-script
                  "cmacs-libregnum-defuns.c" (buffer id index))
(declare-function cmacs-libregnum-editor-set-node-asset
                  "cmacs-libregnum-defuns.c" (buffer id asset))
(declare-function cmacs-libregnum-editor-unpack-prefab
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-select-add
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-select-remove
                  "cmacs-libregnum-defuns.c" (buffer id))
(declare-function cmacs-libregnum-editor-select-clear
                  "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-editor-selected-ids
                  "cmacs-libregnum-defuns.c" (buffer))

;; The empty-space "Add" menu reuses the palette sections, which are defined
;; later in this file (with the palette panel UI); forward-declare so the
;; byte-compiler does not flag the reference in `--popup-add-menu'.
(defvar cmacs-libregnum-editor--palette)

(defun cmacs-libregnum-editor--kind-symbol (kind)
  "Map an integer visual KIND (or nil) to a context-menu node-kind symbol.
A nil KIND means the node has no visual (a group/transform node)."
  (cond
   ((null kind)                                  'group)
   ((= kind 1)                                   'primitive)
   ((= kind cmacs-libregnum-visual-mesh-asset)   'mesh)
   ((= kind cmacs-libregnum-visual-sprite)       'sprite)
   ((= kind cmacs-libregnum-visual-tilemap)      'tilemap)
   ((= kind cmacs-libregnum-visual-light)        'light)
   ((= kind cmacs-libregnum-visual-camera)       'camera)
   ((= kind cmacs-libregnum-visual-audio)        'audio)
   ((= kind cmacs-libregnum-visual-prefab)       'prefab)
   (t                                            'unknown)))

(defconst cmacs-libregnum-editor--primitive-labels
  '((0 . "Plane") (1 . "Cube") (2 . "Circle") (3 . "Sphere") (4 . "IcoSphere")
    (5 . "Cylinder") (6 . "Cone") (7 . "Torus") (8 . "Grid") (9 . "Mesh")
    (10 . "Rectangle") (11 . "Circle2D"))
  "LrgPrimitiveType int → friendly shape label for the outliner.")

(defun cmacs-libregnum-editor--type-label (src id)
  "A friendly type label for node ID in SRC, independent of its (renameable) name.
Primitives report their concrete shape (\"Cube\"); other kinds report their
kind (\"Light\"); a group node reports \"Group\"."
  (let ((kind (ignore-errors (cmacs-libregnum-editor-node-kind src id))))
    (cond
     ((null kind) "Group")
     ((= kind 1)
      (or (and (fboundp 'cmacs-libregnum-editor-node-primitive)
               (cdr (assq (ignore-errors
                            (cmacs-libregnum-editor-node-primitive src id))
                          cmacs-libregnum-editor--primitive-labels)))
          "Shape"))
     ((= kind cmacs-libregnum-visual-mesh-asset) "Mesh")
     ((= kind cmacs-libregnum-visual-sprite)     "Sprite")
     ((= kind cmacs-libregnum-visual-tilemap)    "Tilemap")
     ((= kind cmacs-libregnum-visual-light)      "Light")
     ((= kind cmacs-libregnum-visual-camera)     "Camera")
     ((= kind cmacs-libregnum-visual-audio)      "Audio")
     ((= kind cmacs-libregnum-visual-prefab)     "Prefab")
     (t "Node"))))

(defun cmacs-libregnum-editor--outliner-label (src id name)
  "Outliner row label: the node's type, with a custom NAME in parentheses.
A node whose NAME is still its default (equal to the type, e.g. a fresh
\"Cube\") shows just the type; a renamed node shows e.g. \"Cube (Player)\" so
the chosen name is clearly showcased."
  (let ((type (cmacs-libregnum-editor--type-label src id)))
    (if (and name (stringp name) (not (string-empty-p name))
             (not (string-equal (downcase name) (downcase type))))
        (format "%s (%s)" type name)
      type)))

;;; Helper commands the menu items dispatch to.  Each takes (BUFFER ID).

(defun cmacs-libregnum-editor--ctx-rotate (buffer id drx dry drz)
  "Add (DRX DRY DRZ) radians to node ID's rotation in BUFFER (undoable)."
  (let ((r (cmacs-libregnum-editor-node-rotation buffer id)))
    (when r
      (cmacs-libregnum-editor-set-rotation
       buffer id (+ (nth 0 r) drx) (+ (nth 1 r) dry) (+ (nth 2 r) drz))
      (cmacs-libregnum-editor--sync-panels buffer id))))

(defun cmacs-libregnum-editor--ctx-reset-transform (buffer id)
  "Reset node ID's position, rotation and scale in BUFFER (undoable)."
  (cmacs-libregnum-editor-set-position buffer id 0 0 0)
  (cmacs-libregnum-editor-set-rotation buffer id 0 0 0)
  (cmacs-libregnum-editor-set-scale    buffer id 1 1 1)
  (cmacs-libregnum-editor--sync-panels buffer id))

(defun cmacs-libregnum-editor--ctx-toggle (buffer id prop)
  "Toggle boolean GObject PROP (\"visible\"/\"locked\") on node ID in BUFFER."
  (let ((obj (cmacs-libregnum-editor-node-object buffer id)))
    (if (null obj)
        (user-error "No node object")
      (gobject-set obj prop (not (gobject-get obj prop)))
      (cmacs-libregnum-redraw buffer)
      (cmacs-libregnum-editor--sync-panels buffer id)
      (message "%s: %s" prop (if (gobject-get obj prop) "on" "off")))))

(defun cmacs-libregnum-editor--ctx-rename (buffer id)
  "Prompt for and set node ID's name in BUFFER.
Uses `cmacs-libregnum-editor-set-name', which re-bakes the level so the new
name shows in the outliner (whose labels are cached at bake time); falls back
to the GObject `name' property when that primitive is unavailable."
  (let* ((obj (cmacs-libregnum-editor-node-object buffer id))
         (old (and obj (gobject-get obj "name")))
         (new (read-string "Name: " old)))
    (if (fboundp 'cmacs-libregnum-editor-set-name)
        (cmacs-libregnum-editor-set-name buffer id new)
      (when obj (gobject-set obj "name" new)))
    ;; Rebuild the outliner so the new name shows, then re-sync panels.
    (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
      (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
    (cmacs-libregnum-editor--sync-panels buffer id)
    (message "Renamed node %d to %s" id new)))

(defun cmacs-libregnum-editor--ctx-open-asset (buffer id)
  "Visit node ID's backing asset file (mesh/sprite/audio) in BUFFER."
  (let ((asset (cmacs-libregnum-editor-node-asset buffer id)))
    (if (and asset (not (string-empty-p asset))
             (file-exists-p (expand-file-name asset)))
        (find-file-other-window (expand-file-name asset))
      (user-error "No asset file for this node"))))

(defun cmacs-libregnum-editor--ctx-duplicate (buffer id)
  "Duplicate node ID in BUFFER.
Saves the node's subtree to a temporary .rprefab and re-instantiates it under
the root, nudged slightly so the copy is visible.  (A native engine-side clone
under the original's parent is a future improvement.)"
  (let ((tmp (make-temp-file "cmacs-lrg-dup" nil ".rprefab")))
    (unwind-protect
        (if (not (cmacs-libregnum-editor-save-prefab buffer id tmp))
            (user-error "Could not duplicate node")
          (let ((newid (cmacs-libregnum-editor-instantiate-prefab
                        buffer tmp -1)))
            (when newid
              (let ((loc (cmacs-libregnum-editor-node-location buffer newid)))
                (when loc
                  (cmacs-libregnum-editor-set-position
                   buffer newid (+ (nth 0 loc) 0.5) (nth 1 loc)
                   (+ (nth 2 loc) 0.5))))
              (cmacs-libregnum-editor-select buffer newid)
              (with-current-buffer buffer
                (setq cmacs-libregnum-editor--current newid))
              (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
                (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
              (cmacs-libregnum-editor--sync-panels buffer newid)
              (message "Duplicated node %d → %d" id newid))))
      (ignore-errors (delete-file tmp)))))

;;; ─── Clipboard state ────────────────────────────────────────────────────────

(defvar cmacs-libregnum-editor--clipboard nil
  "Temp file path for the last Cut/Copy'd node subtree (.rprefab), or nil.")

;;; ─── New context-menu helper commands ──────────────────────────────────────

(defun cmacs-libregnum-editor--ctx-set-color (buffer id)
  "Prompt for a colour and apply it to node ID's material in BUFFER."
  (let* ((hex (read-color "Node color: " t))
         (rgb (color-name-to-rgb hex)))
    (if (and rgb (fboundp 'cmacs-libregnum-editor-set-color))
        (progn
          (cmacs-libregnum-editor-set-color
           buffer id (nth 0 rgb) (nth 1 rgb) (nth 2 rgb) 1.0)
          (cmacs-libregnum-editor--sync-panels buffer id)
          (message "Color set to %s" hex))
      (unless (fboundp 'cmacs-libregnum-editor-set-color)
        (user-error "set-color not yet available")))))

(defun cmacs-libregnum-editor--ctx-set-roughness (buffer id)
  "Prompt for roughness (0..1) and apply to node ID's material in BUFFER."
  (let ((v (read-number "Roughness (0..1): " 0.5)))
    (if (fboundp 'cmacs-libregnum-editor-set-roughness)
        (progn
          (cmacs-libregnum-editor-set-roughness buffer id v)
          (cmacs-libregnum-editor--sync-panels buffer id)
          (message "Roughness set to %s" v))
      (user-error "set-roughness not yet available"))))

(defun cmacs-libregnum-editor--ctx-set-metallic (buffer id)
  "Prompt for metallic value (0..1) and apply to node ID in BUFFER."
  (let ((v (read-number "Metallic (0..1): " 0.0)))
    (if (fboundp 'cmacs-libregnum-editor-set-metallic)
        (progn
          (cmacs-libregnum-editor-set-metallic buffer id v)
          (cmacs-libregnum-editor--sync-panels buffer id)
          (message "Metallic set to %s" v))
      (user-error "set-metallic not yet available"))))

(defun cmacs-libregnum-editor--ctx-scale-x2 (buffer id)
  "Scale node ID by 2x in BUFFER."
  (let ((s (ignore-errors (cmacs-libregnum-editor-node-scale buffer id))))
    (if s
        (progn
          (cmacs-libregnum-editor-set-scale
           buffer id (* 2 (nth 0 s)) (* 2 (nth 1 s)) (* 2 (nth 2 s)))
          (cmacs-libregnum-editor--sync-panels buffer id))
      (user-error "Could not read node scale"))))

(defun cmacs-libregnum-editor--ctx-scale-half (buffer id)
  "Scale node ID by 0.5 in BUFFER."
  (let ((s (ignore-errors (cmacs-libregnum-editor-node-scale buffer id))))
    (if s
        (progn
          (cmacs-libregnum-editor-set-scale
           buffer id (* 0.5 (nth 0 s)) (* 0.5 (nth 1 s)) (* 0.5 (nth 2 s)))
          (cmacs-libregnum-editor--sync-panels buffer id))
      (user-error "Could not read node scale"))))

(defun cmacs-libregnum-editor--ctx-reset-scale (buffer id)
  "Reset node ID's scale to (1 1 1) in BUFFER."
  (cmacs-libregnum-editor-set-scale buffer id 1.0 1.0 1.0)
  (cmacs-libregnum-editor--sync-panels buffer id))

(defun cmacs-libregnum-editor--ctx-set-scale (buffer id)
  "Prompt for SX SY SZ and set node ID's scale in BUFFER."
  (let ((sx (read-number "Scale X: " 1.0))
        (sy (read-number "Scale Y: " 1.0))
        (sz (read-number "Scale Z: " 1.0)))
    (cmacs-libregnum-editor-set-scale buffer id sx sy sz)
    (cmacs-libregnum-editor--sync-panels buffer id)))

(defun cmacs-libregnum-editor--ctx-drop-to-ground (buffer id)
  "Set node ID's Y position to 0 in BUFFER."
  (let ((loc (ignore-errors (cmacs-libregnum-editor-node-location buffer id))))
    (cmacs-libregnum-editor-set-position
     buffer id (if loc (nth 0 loc) 0.0) 0.0 (if loc (nth 2 loc) 0.0))
    (cmacs-libregnum-editor--sync-panels buffer id)))

(defun cmacs-libregnum-editor--ctx-snap-to-grid (buffer id)
  "Snap node ID's position to the active snap grid (or 1.0) in BUFFER."
  (let* ((loc (ignore-errors (cmacs-libregnum-editor-node-location buffer id)))
         (g   (with-current-buffer buffer
                (or cmacs-libregnum-editor--snap 1.0))))
    (when loc
      (cmacs-libregnum-editor-set-position
       buffer id
       (* g (round (/ (nth 0 loc) g)))
       (* g (round (/ (nth 1 loc) g)))
       (* g (round (/ (nth 2 loc) g))))
      (cmacs-libregnum-editor--sync-panels buffer id))))

(defun cmacs-libregnum-editor--ctx-reset-position (buffer id)
  "Reset node ID's position to (0 0 0) in BUFFER."
  (cmacs-libregnum-editor-set-position buffer id 0.0 0.0 0.0)
  (cmacs-libregnum-editor--sync-panels buffer id))

(defun cmacs-libregnum-editor--ctx-duplicate-native (buffer id)
  "Duplicate node ID using native engine clone if available, else fall back."
  (if (fboundp 'cmacs-libregnum-editor-duplicate-node)
      (let ((newid (ignore-errors
                     (cmacs-libregnum-editor-duplicate-node buffer id))))
        (if newid
            (progn
              (cmacs-libregnum-editor-select buffer newid)
              (with-current-buffer buffer
                (setq cmacs-libregnum-editor--current newid))
              (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
                (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
              (cmacs-libregnum-editor--sync-panels buffer newid)
              (message "Duplicated node %d -> %d" id newid))
          (cmacs-libregnum-editor--ctx-duplicate buffer id)))
    (cmacs-libregnum-editor--ctx-duplicate buffer id)))

(defun cmacs-libregnum-editor--ctx-copy (buffer id)
  "Copy node ID's subtree to the clipboard temp file in BUFFER."
  (let ((tmp (make-temp-file "cmacs-lrg-clip" nil ".rprefab")))
    (if (cmacs-libregnum-editor-save-prefab buffer id tmp)
        (progn
          (setq cmacs-libregnum-editor--clipboard tmp)
          (message "Copied node %d to clipboard" id))
      (ignore-errors (delete-file tmp))
      (user-error "Could not copy node"))))

(defun cmacs-libregnum-editor--ctx-cut (buffer id)
  "Cut node ID — copy to clipboard then delete it in BUFFER."
  (cmacs-libregnum-editor--ctx-copy buffer id)
  (cmacs-libregnum-editor-delete buffer id)
  (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
    (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
  (cmacs-libregnum-editor--sync-panels buffer nil)
  (message "Cut node %d" id))

(defun cmacs-libregnum-editor--ctx-paste (buffer id)
  "Paste clipboard under node ID (or root) in BUFFER."
  (if (not cmacs-libregnum-editor--clipboard)
      (user-error "Clipboard is empty")
    (let ((newid (cmacs-libregnum-editor-instantiate-prefab
                  buffer cmacs-libregnum-editor--clipboard id)))
      (if newid
          (progn
            (cmacs-libregnum-editor-select buffer newid)
            (with-current-buffer buffer
              (setq cmacs-libregnum-editor--current newid))
            (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
              (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
            (cmacs-libregnum-editor--sync-panels buffer newid)
            (message "Pasted clipboard as node %d" newid))
        (user-error "Could not paste from clipboard")))))

(defun cmacs-libregnum-editor--ctx-copy-guid (buffer id)
  "Copy node ID's GUID to the kill-ring in BUFFER."
  (let ((guid (ignore-errors (cmacs-libregnum-editor-node-guid buffer id))))
    (if guid
        (progn (kill-new guid) (message "GUID %s copied" guid))
      (user-error "Could not get GUID for node %d" id))))

(defun cmacs-libregnum-editor--ctx-reparent-under (buffer id)
  "Prompt for a parent node and reparent node ID under it in BUFFER."
  (let* ((nodes (ignore-errors (cmacs-libregnum-tree-nodes buffer)))
         (cands (and nodes
                     (let (acc)
                       (dotimes (i (length nodes))
                         (let* ((pl (aref nodes i))
                                (nid  (plist-get pl :id))
                                (name (or (plist-get pl :name) ""))
                                (lbl  (cmacs-libregnum-editor--outliner-label
                                       buffer nid name)))
                           (unless (eq nid id)
                             (push (cons (format "%d: %s" nid lbl) nid) acc))))
                       (nreverse acc))))
         (choice (and cands
                      (completing-read "Reparent under: " cands nil t))))
    (when choice
      (let ((parent (cdr (assoc choice cands))))
        (when parent
          (cmacs-libregnum-editor-reparent buffer id parent)
          (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
            (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
          (cmacs-libregnum-editor--sync-panels buffer id)
          (message "Reparented node %d under node %d" id parent))))))

(defun cmacs-libregnum-editor--ctx-add-child (buffer id)
  "Pop the Add palette and reparent the new node under node ID in BUFFER."
  (let* ((sections cmacs-libregnum-editor--palette)
         (flat nil) (i 0)
         (panes
          (mapcar
           (lambda (section)
             (cons (car section)
                   (mapcar
                    (lambda (item)
                      (let ((label (nth 0 item)) (ptype (nth 1 item))
                            (vsym  (nth 2 item)))
                        (setq flat (cons (list ptype
                                               (and vsym (symbol-value vsym))
                                               label)
                                         flat))
                        (prog1 (cons label i) (setq i (1+ i)))))
                    (cdr section))))
           sections))
         (frame  (or (window-frame (get-buffer-window buffer t))
                     (selected-frame)))
         (choice (cmacs-libregnum-popup-menu (list (list 0 0) frame)
                                             (cons "Add child" panes))))
    (setq flat (nreverse flat))
    (when (integerp choice)
      (let* ((entry (nth choice flat))
             (type  (nth 0 entry))
             (value (nth 1 entry))
             (name  (nth 2 entry))
             (newid (cmacs-libregnum-editor--place-item
                     buffer type value name 0.0 0.0 0.0)))
        (when newid
          (cmacs-libregnum-editor-reparent buffer newid id)
          (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
            (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
          (cmacs-libregnum-editor--sync-panels buffer newid)
          (message "Added %s under node %d" name id))))))

(defun cmacs-libregnum-editor--ctx-add-empty-group-under (buffer id)
  "Add an empty group node under node ID in BUFFER."
  (if (fboundp 'cmacs-libregnum-editor-add-empty)
      (let ((name (read-string "Group name: " "Group"))
            (newid (ignore-errors
                     (cmacs-libregnum-editor-add-empty buffer "Group" id))))
        (when newid
          (cmacs-libregnum-editor-select buffer newid)
          (with-current-buffer buffer
            (setq cmacs-libregnum-editor--current newid))
          (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
            (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
          (cmacs-libregnum-editor--sync-panels buffer newid)
          (message "Added empty group under node %d" id))
        (ignore name))
    (user-error "add-empty not yet available")))

(defun cmacs-libregnum-editor--ctx-replace-asset (buffer id)
  "Prompt for a new asset file and replace node ID's asset in BUFFER."
  (let ((file (read-file-name "Replace asset: " nil nil t)))
    (if (fboundp 'cmacs-libregnum-editor-set-node-asset)
        (progn
          (cmacs-libregnum-editor-set-node-asset
           buffer id (expand-file-name file))
          (cmacs-libregnum-editor--sync-panels buffer id)
          (message "Asset replaced: %s" file))
      (user-error "set-node-asset not yet available"))))

(defun cmacs-libregnum-editor--ctx-edit-sprite (buffer id)
  "Open node ID's image asset in the 2D image editor (cmacs-imgedit).
Saving in the image editor reloads the node's texture in BUFFER via
`cmacs-imgedit-after-save-functions', closing the 2D->3D sprite loop."
  (unless (fboundp 'cmacs-imgedit-open-file)
    (user-error "cmacs was not built with --with-cmacs-imgedit"))
  (let ((asset (cmacs-libregnum-editor-node-asset buffer id)))
    (unless (and asset (not (string-empty-p asset))
                 (file-exists-p (expand-file-name asset)))
      (user-error "No image asset file for this node"))
    (setq asset (expand-file-name asset))
    (let ((edit-buf (cmacs-imgedit-open-file asset)))
      (with-current-buffer edit-buf
        (add-hook 'cmacs-imgedit-after-save-functions
                  (lambda (path)
                    (when (and (string= path asset)
                               (buffer-live-p buffer)
                               (fboundp 'cmacs-libregnum-editor-set-node-asset))
                      (cmacs-libregnum-editor-set-node-asset buffer id path)
                      (message "Sprite reloaded in the 3D editor")))
                  nil t))
      (message "Editing %s — save (s) to refresh the 3D node"
               (file-name-nondirectory asset)))))

(defun cmacs-libregnum-editor--ctx-manage-scripts-items-fn (buffer id)
  "Return a dynamic script-management item list for node ID in BUFFER.
Called at pop time so script list is always current."
  (let* ((scripts (and (fboundp 'cmacs-libregnum-editor-node-scripts)
                       (ignore-errors
                         (cmacs-libregnum-editor-node-scripts buffer id))))
         (lang-names (mapcar #'car cmacs-libregnum-script-languages))
         (items nil))
    (dolist (lang-name lang-names)
      (ignore lang-name))
    (when scripts
      (let ((idx 0))
        (dolist (s scripts)
          (let* ((path   (plist-get s :path))
                 (lang   (plist-get s :language))
                 (base   (if path (file-name-nondirectory path) "?"))
                 (lang-n (car (rassq lang cmacs-libregnum-script-languages)))
                 (lbl    (format "%s: %s" (or lang-n "?") base))
                 (i      idx))
            (push `(:label ,(format "%s — Edit" lbl)
                    :action ,(let ((p path))
                               (lambda (_b _id)
                                 (when (and p (file-exists-p p))
                                   (find-file-other-window p)))))
                  items)
            (push `(:label ,(format "%s — Detach" lbl)
                    :action ,(let ((ii i))
                               (lambda (buf nid)
                                 (when (fboundp
                                        'cmacs-libregnum-editor-detach-script)
                                   (cmacs-libregnum-editor-detach-script
                                    buf nid ii)
                                   (cmacs-libregnum-editor--sync-panels
                                    buf nid))))
                    :enable ,(lambda (_b _id)
                               (fboundp
                                'cmacs-libregnum-editor-detach-script)))
                  items))
          (setq idx (1+ idx)))))
    (push '(:sep) items)
    (push '(:label "Attach new…"
            :action cmacs-libregnum-editor--ctx-new-script)
          items)
    (push '(:label "Attach existing…"
            :action cmacs-libregnum-editor--ctx-existing-script)
          items)
    (nreverse items)))

(defun cmacs-libregnum-editor--ctx-set-light-intensity (buffer id)
  "Prompt for an intensity and set it on light node ID in BUFFER."
  (let ((v (read-number "Light intensity: " 1.0)))
    (cmacs-libregnum-editor-set-visual-param buffer id "intensity" v)
    (cmacs-libregnum-editor--sync-panels buffer id)
    (message "Light intensity set to %s" v)))

(defun cmacs-libregnum-editor--ctx-align-camera-to-view (buffer id)
  "Align camera node ID's transform to the current editor viewport in BUFFER."
  (if (not (fboundp 'cmacs-libregnum-camera-state))
      (user-error "camera-state not yet available")
    (let ((cs (ignore-errors (cmacs-libregnum-camera-state buffer))))
      (if (not cs)
          (user-error "Could not read camera state")
        ;; `cmacs-libregnum-camera-state' returns a plist
        ;; (:position (X Y Z) :target (X Y Z) :fov FOV).
        (let* ((pos (plist-get cs :position))
               (tgt (plist-get cs :target))
               (px (nth 0 pos)) (py (nth 1 pos)) (pz (nth 2 pos))
               (tx (nth 0 tgt)) (ty (nth 1 tgt)) (tz (nth 2 tgt))
               (fov (plist-get cs :fov))
               (yaw (atan (- tx px) (- tz pz)))
               (dx  (- tx px)) (dz (- tz pz)) (dy (- ty py))
               (pitch (- (atan dy (sqrt (+ (* dx dx) (* dz dz)))))))
          (cmacs-libregnum-editor-set-position buffer id px py pz)
          (cmacs-libregnum-editor-set-rotation buffer id pitch yaw 0.0)
          (when fov
            (cmacs-libregnum-editor-set-visual-param buffer id "fov" fov))
          (cmacs-libregnum-editor--sync-panels buffer id)
          (message "Camera aligned to viewport (yaw %.2f°)"
                   (/ (* yaw 180) float-pi)))))))

(defun cmacs-libregnum-editor--ctx-enter-paint-mode (buffer id)
  "Enter paint mode on tilemap node ID in BUFFER."
  (ignore id)
  (with-current-buffer buffer (cmacs-libregnum-editor-tilemap-paint)))

(defun cmacs-libregnum-editor--ctx-clear-tilemap (buffer id)
  "Clear all tiles in tilemap node ID to -1 in BUFFER."
  (let ((info (ignore-errors (cmacs-libregnum-editor-tilemap-info buffer id))))
    (if (not info)
        (user-error "Node %d is not a tilemap" id)
      (let ((mw (plist-get info :map-w))
            (mh (plist-get info :map-h)))
        (dotimes (cx mw)
          (dotimes (cy mh)
            (cmacs-libregnum-editor-tilemap-set-tile buffer id cx cy -1)))
        (message "Tilemap cleared (%dx%d)" mw mh)))))

(defun cmacs-libregnum-editor--ctx-resize-tilemap (buffer id)
  "Prompt for new dimensions and resize tilemap node ID in BUFFER."
  (let ((info (ignore-errors (cmacs-libregnum-editor-tilemap-info buffer id))))
    (if (not info)
        (user-error "Node %d is not a tilemap" id)
      (let* ((ts  (plist-get info :tileset))
             (tw  (plist-get info :tile-w))
             (th  (plist-get info :tile-h))
             (cols (plist-get info :cols))
             (mw  (read-number "New map width (cells): "
                               (plist-get info :map-w)))
             (mh  (read-number "New map height (cells): "
                               (plist-get info :map-h))))
        (cmacs-libregnum-editor-tilemap-config
         buffer id ts tw th cols mw mh)
        (cmacs-libregnum-editor--sync-panels buffer id)
        (message "Tilemap resized to %dx%d" mw mh)))))

(defun cmacs-libregnum-editor--ctx-unpack-prefab (buffer id)
  "Unpack prefab node ID in BUFFER."
  (if (fboundp 'cmacs-libregnum-editor-unpack-prefab)
      (progn
        (cmacs-libregnum-editor-unpack-prefab buffer id)
        (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
          (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
        (cmacs-libregnum-editor--sync-panels buffer id)
        (message "Prefab unpacked"))
    (user-error "unpack-prefab not yet available")))

(defun cmacs-libregnum-editor--ctx-select-add (buffer id)
  "Add node ID to the multi-selection in BUFFER."
  (if (fboundp 'cmacs-libregnum-editor-select-add)
      (progn
        (cmacs-libregnum-editor-select-add buffer id)
        (message "Added node %d to selection" id))
    (user-error "select-add not yet available")))

(defun cmacs-libregnum-editor--ctx-select-remove (buffer id)
  "Remove node ID from the multi-selection in BUFFER."
  (if (fboundp 'cmacs-libregnum-editor-select-remove)
      (progn
        (cmacs-libregnum-editor-select-remove buffer id)
        (message "Removed node %d from selection" id))
    (user-error "select-remove not yet available")))

(defun cmacs-libregnum-editor--ctx-select-clear (buffer id)
  "Clear the multi-selection in BUFFER."
  (ignore id)
  (if (fboundp 'cmacs-libregnum-editor-select-clear)
      (progn
        (cmacs-libregnum-editor-select-clear buffer)
        (message "Selection cleared"))
    (user-error "select-clear not yet available")))

(defun cmacs-libregnum-editor--ctx-select-parent (buffer id)
  "Select node ID's parent in BUFFER."
  (if (fboundp 'cmacs-libregnum-editor-node-parent)
      (let ((parent (ignore-errors
                      (cmacs-libregnum-editor-node-parent buffer id))))
        (if (and parent (>= parent 0))
            (progn
              (cmacs-libregnum-editor-select buffer parent)
              (with-current-buffer buffer
                (setq cmacs-libregnum-editor--current parent))
              (cmacs-libregnum-editor--sync-panels buffer parent)
              (message "Selected parent node %d" parent))
          (user-error "Node %d has no parent" id)))
    (user-error "node-parent not yet available")))

(defun cmacs-libregnum-editor--ctx-delete-selected (buffer id)
  "Delete all nodes in the current multi-selection in BUFFER."
  (ignore id)
  (if (fboundp 'cmacs-libregnum-editor-selected-ids)
      (let ((ids (ignore-errors (cmacs-libregnum-editor-selected-ids buffer))))
        (dolist (sid ids) (ignore-errors (cmacs-libregnum-editor-delete buffer sid)))
        (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
          (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
        (cmacs-libregnum-editor--sync-panels buffer nil)
        (message "Deleted %d nodes" (length ids)))
    (user-error "selected-ids not yet available")))

(defun cmacs-libregnum-editor--ctx-group-selected (buffer id)
  "Create an empty group and reparent all selected nodes under it in BUFFER."
  (ignore id)
  (if (not (fboundp 'cmacs-libregnum-editor-selected-ids))
      (user-error "selected-ids not yet available")
    (if (not (fboundp 'cmacs-libregnum-editor-add-empty))
        (user-error "add-empty not yet available")
      (let* ((ids (ignore-errors (cmacs-libregnum-editor-selected-ids buffer)))
             (grp (ignore-errors
                    (cmacs-libregnum-editor-add-empty buffer "Group" -1))))
        (when grp
          (dolist (sid ids)
            (ignore-errors (cmacs-libregnum-editor-reparent buffer sid grp)))
          (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
            (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
          (cmacs-libregnum-editor--sync-panels buffer grp)
          (message "Grouped %d nodes under node %d" (length ids) grp))))))

(defun cmacs-libregnum-editor--ctx-toggle-wireframe (buffer id)
  "Toggle the wireframe overlay on node ID in BUFFER.
Reads \"wireframe\" via `cmacs-libregnum-editor-get-visual-param' (default 0.0)
and flips it.  The renderer's display layer honours this flag.  Persisted via
`cmacs-libregnum-editor-set-visual-param'."
  (let* ((cur (if (fboundp 'cmacs-libregnum-editor-get-visual-param)
                  (ignore-errors
                    (cmacs-libregnum-editor-get-visual-param
                     buffer id "wireframe" 0.0))
                0.0))
         (next (if (and (numberp cur) (> cur 0.5)) 0.0 1.0)))
    (cmacs-libregnum-editor-set-visual-param buffer id "wireframe" next)
    (cmacs-libregnum-editor--sync-panels buffer id)
    (message "Wireframe: %s" (if (> next 0.5) "on" "off"))))

(defun cmacs-libregnum-editor--ctx-toggle-cast-shadow (buffer id)
  "Toggle the cast-shadow flag on node ID in BUFFER.
Authors the \"cast_shadow\" visual param (1.0 = shadows on, 0.0 = off).
This is metadata only until shadow-map rendering is implemented — it is
already persisted in the level so it takes effect the moment the render layer
is wired up.  Reads current value via `cmacs-libregnum-editor-get-visual-param'
\(default 1.0 — shadows on by default)."
  (let* ((cur (if (fboundp 'cmacs-libregnum-editor-get-visual-param)
                  (ignore-errors
                    (cmacs-libregnum-editor-get-visual-param
                     buffer id "cast_shadow" 1.0))
                1.0))
         (next (if (and (numberp cur) (< cur 0.5)) 1.0 0.0)))
    (cmacs-libregnum-editor-set-visual-param buffer id "cast_shadow" next)
    (cmacs-libregnum-editor--sync-panels buffer id)
    (message "Cast shadow: %s (metadata — effective when shadow mapping lands)"
             (if (> next 0.5) "on" "off"))))

(defvar cmacs-libregnum-editor-display-menu-items
  `((:label "Toggle wireframe"
     :action cmacs-libregnum-editor--ctx-toggle-wireframe)
    (:label "Toggle cast shadow"
     :action cmacs-libregnum-editor--ctx-toggle-cast-shadow))
  "Items for the right-click \"Display\" submenu (primitives and meshes).")

(defvar cmacs-libregnum-editor-material-menu-items
  `((:label "Set color…"     :action cmacs-libregnum-editor--ctx-set-color)
    (:label "Set roughness…" :action cmacs-libregnum-editor--ctx-set-roughness)
    (:label "Set metallic…"  :action cmacs-libregnum-editor--ctx-set-metallic))
  "Items for the right-click \"Material\" submenu (primitives and meshes).")

(defvar cmacs-libregnum-editor-scale-menu-items
  `((:label "2×"          :action cmacs-libregnum-editor--ctx-scale-x2)
    (:label "0.5×"        :action cmacs-libregnum-editor--ctx-scale-half)
    (:label "Reset scale" :action cmacs-libregnum-editor--ctx-reset-scale)
    (:sep)
    (:label "Set scale…"  :action cmacs-libregnum-editor--ctx-set-scale))
  "Items for the right-click \"Scale\" submenu.")

(defvar cmacs-libregnum-editor-tool-menu-items
  `((:label "Translate" :action ,(lambda (_b _i)
                                   (cmacs-libregnum-editor-tool-translate)))
    (:label "Rotate"    :action ,(lambda (_b _i)
                                   (cmacs-libregnum-editor-tool-rotate)))
    (:label "Scale"     :action ,(lambda (_b _i)
                                   (cmacs-libregnum-editor-tool-scale)))
    (:label "Select"    :action ,(lambda (_b _i)
                                   (cmacs-libregnum-editor-tool-select))))
  "Items for the right-click \"Tool\" submenu.")

(defvar cmacs-libregnum-editor-light-type-menu-items
  `((:label "Point"       :action ,(lambda (b i)
                                     (cmacs-libregnum-editor-set-visual-param
                                      b i "type" 0)))
    (:label "Spot"        :action ,(lambda (b i)
                                     (cmacs-libregnum-editor-set-visual-param
                                      b i "type" 1)))
    (:label "Directional" :action ,(lambda (b i)
                                     (cmacs-libregnum-editor-set-visual-param
                                      b i "type" 2))))
  "Items for the right-click \"Light type\" submenu.")

(defvar cmacs-libregnum-editor-selection-menu-items
  `((:label "Add to selection"    :action cmacs-libregnum-editor--ctx-select-add)
    (:label "Remove from selection"
            :action cmacs-libregnum-editor--ctx-select-remove)
    (:label "Clear selection"     :action cmacs-libregnum-editor--ctx-select-clear)
    (:label "Select parent"
            :action cmacs-libregnum-editor--ctx-select-parent
            :enable ,(lambda (b i)
                       (and (fboundp 'cmacs-libregnum-editor-node-parent)
                            (let ((p (ignore-errors
                                       (cmacs-libregnum-editor-node-parent b i))))
                              (and p (>= p 0))))))
    (:sep)
    (:label "Delete selected"
            :action cmacs-libregnum-editor--ctx-delete-selected
            :enable ,(lambda (b _i)
                       (and (fboundp 'cmacs-libregnum-editor-selected-ids)
                            (let ((ids (ignore-errors
                                         (cmacs-libregnum-editor-selected-ids b))))
                              (> (length ids) 1)))))
    (:label "Group selected"
            :action cmacs-libregnum-editor--ctx-group-selected
            :enable ,(lambda (b _i)
                       (and (fboundp 'cmacs-libregnum-editor-selected-ids)
                            (fboundp 'cmacs-libregnum-editor-add-empty)
                            (let ((ids (ignore-errors
                                         (cmacs-libregnum-editor-selected-ids b))))
                              (> (length ids) 1))))))
  "Items for the right-click \"Select\" submenu.")

(defvar cmacs-libregnum-editor-rotate-menu-items
  `((:label "X axis +45°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i (/ float-pi 4) 0 0)))
    (:label "X axis −45°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i (- (/ float-pi 4)) 0 0)))
    (:label "X axis +90°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i (/ float-pi 2) 0 0)))
    (:label "X axis −90°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i (- (/ float-pi 2)) 0 0)))
    (:sep)
    (:label "Y axis +45°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 (/ float-pi 4) 0)))
    (:label "Y axis −45°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 (- (/ float-pi 4)) 0)))
    (:label "Y axis +90°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 (/ float-pi 2) 0)))
    (:label "Y axis −90°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 (- (/ float-pi 2)) 0)))
    (:sep)
    (:label "Z axis +45°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 0 (/ float-pi 4))))
    (:label "Z axis −45°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 0 (- (/ float-pi 4)))))
    (:label "Z axis +90°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 0 (/ float-pi 2))))
    (:label "Z axis −90°" :action ,(lambda (b i) (cmacs-libregnum-editor--ctx-rotate b i 0 0 (- (/ float-pi 2)))))
    (:sep)
    (:label "Reset rotation" :action ,(lambda (b i) (cmacs-libregnum-editor-set-rotation b i 0 0 0))))
  "Items for the right-click \"Rotate\" submenu: ±45°/±90° about each axis.
Same plist shape as `cmacs-libregnum-editor-context-menu-items' (no :kinds —
all rotations apply to every node).")

(defvar cmacs-libregnum-editor-script-menu-items
  '((:label "New script…"      :action cmacs-libregnum-editor--ctx-new-script)
    (:label "Existing script…" :action cmacs-libregnum-editor--ctx-existing-script))
  "Items for the right-click \"Attach script\" submenu.")

(defvar cmacs-libregnum-editor-context-menu-items
  `((:label "Rename…"
     :kinds t :action cmacs-libregnum-editor--ctx-rename)
    (:label "Set position…"
     :kinds t :action ,(lambda (_b _i)
                         (call-interactively
                          #'cmacs-libregnum-editor-move-current)))
    (:label "Rotate"
     :kinds t :submenu cmacs-libregnum-editor-rotate-menu-items)
    (:label "Scale"
     :kinds t :submenu cmacs-libregnum-editor-scale-menu-items)
    (:sep)
    (:label "Drop to ground"
     :kinds t :action cmacs-libregnum-editor--ctx-drop-to-ground)
    (:label "Snap to grid"
     :kinds t :action cmacs-libregnum-editor--ctx-snap-to-grid)
    (:label "Reset position"
     :kinds t :action cmacs-libregnum-editor--ctx-reset-position)
    (:label "Reset transform"
     :kinds t :action cmacs-libregnum-editor--ctx-reset-transform)
    (:sep)
    (:label "Duplicate"
     :kinds t :action cmacs-libregnum-editor--ctx-duplicate-native
     :keys "d")
    (:label "Cut"
     :kinds t :action cmacs-libregnum-editor--ctx-cut)
    (:label "Copy"
     :kinds t :action cmacs-libregnum-editor--ctx-copy)
    (:label "Paste"
     :kinds t :action cmacs-libregnum-editor--ctx-paste
     :enable ,(lambda (_b _i)
                (not (null cmacs-libregnum-editor--clipboard))))
    (:label "Copy GUID"
     :kinds t :action cmacs-libregnum-editor--ctx-copy-guid)
    (:sep)
    (:label "Reparent under…"
     :kinds t :action cmacs-libregnum-editor--ctx-reparent-under)
    (:label "Reparent to root"
     :kinds t :action ,(lambda (b i) (cmacs-libregnum-editor-reparent b i -1))
     :enable ,(lambda (b i)
                (and (fboundp 'cmacs-libregnum-editor-node-parent)
                     (let ((p (ignore-errors
                                (cmacs-libregnum-editor-node-parent b i))))
                       (and p (>= p 0))))))
    (:label "Add child…"
     :kinds t :action cmacs-libregnum-editor--ctx-add-child)
    (:label "Add empty group here"
     :kinds t :action cmacs-libregnum-editor--ctx-add-empty-group-under)
    (:sep)
    (:label "Toggle visible"
     :kinds t :action ,(lambda (b i)
                         (cmacs-libregnum-editor--ctx-toggle b i "visible")))
    (:label "Toggle locked"
     :kinds t :action ,(lambda (b i)
                         (cmacs-libregnum-editor--ctx-toggle b i "locked")))
    (:sep)
    (:label "Attach script"
     :kinds t :submenu cmacs-libregnum-editor-script-menu-items)
    (:label "Manage scripts"
     :kinds t :items-fn cmacs-libregnum-editor--ctx-manage-scripts-items-fn)
    (:sep)
    (:label "Tool"
     :kinds t :submenu cmacs-libregnum-editor-tool-menu-items)
    (:label "Select"
     :kinds t :submenu cmacs-libregnum-editor-selection-menu-items)
    (:sep)
    (:label "Inspector"
     :kinds t :action ,(lambda (_b _i) (cmacs-libregnum-editor-inspector))
     :keys "i")
    (:label "Focus camera"
     :kinds t :action ,(lambda (_b _i) (cmacs-libregnum-editor-focus-selected))
     :keys "f")
    (:label "Save as prefab…"
     :kinds t :action ,(lambda (_b _i)
                         (call-interactively
                          #'cmacs-libregnum-editor-prefab-save)))
    (:sep)
    (:label "Material"
     :kinds (primitive mesh)
     :submenu cmacs-libregnum-editor-material-menu-items)
    (:label "Display"
     :kinds (primitive mesh)
     :submenu cmacs-libregnum-editor-display-menu-items)
    (:label "Open asset file"
     :kinds (mesh sprite audio)
     :action cmacs-libregnum-editor--ctx-open-asset
     :enable ,(lambda (b i)
                (let ((a (ignore-errors
                           (cmacs-libregnum-editor-node-asset b i))))
                  (and a (not (string-empty-p a)) (file-exists-p a)))))
    (:label "Replace asset…"
     :kinds (mesh sprite audio)
     :action cmacs-libregnum-editor--ctx-replace-asset
     :enable ,(lambda (_b _i)
                (fboundp 'cmacs-libregnum-editor-set-node-asset)))
    (:label "Edit sprite image…"
     :kinds (sprite tilemap)
     :action cmacs-libregnum-editor--ctx-edit-sprite
     :enable ,(lambda (b i)
                (and (fboundp 'cmacs-imgedit-open-file)
                     (let ((a (ignore-errors
                                (cmacs-libregnum-editor-node-asset b i))))
                       (and a (not (string-empty-p a))
                            (file-exists-p (expand-file-name a)))))))
    (:sep)
    (:label "Set light range/color…"
     :kinds (light)
     :action ,(lambda (_b _i)
                (call-interactively #'cmacs-libregnum-editor-set-light)))
    (:label "Set intensity…"
     :kinds (light)
     :action cmacs-libregnum-editor--ctx-set-light-intensity)
    (:label "Light type"
     :kinds (light)
     :submenu cmacs-libregnum-editor-light-type-menu-items)
    (:sep)
    (:label "Set camera FOV…"
     :kinds (camera)
     :action ,(lambda (_b _i)
                (call-interactively #'cmacs-libregnum-editor-set-camera-fov)))
    (:label "Align to view"
     :kinds (camera)
     :action cmacs-libregnum-editor--ctx-align-camera-to-view)
    (:label "Look through this camera"
     :kinds (camera)
     :action ,(lambda (b i)
                (if (fboundp 'cmacs-libregnum-editor-look-through)
                    (ignore-errors (cmacs-libregnum-editor-look-through b i))
                  (user-error
                   "cmacs-libregnum-editor-look-through not yet available")))
     :enable ,(lambda (_b _i)
                (fboundp 'cmacs-libregnum-editor-look-through)))
    (:label "Stop look-through"
     :kinds t
     :action ,(lambda (b _i)
                (if (fboundp 'cmacs-libregnum-editor-look-through-off)
                    (progn
                      (ignore-errors
                        (cmacs-libregnum-editor-look-through-off b))
                      (message "Stopped look-through; back to free-fly camera"))
                  (user-error
                   "cmacs-libregnum-editor-look-through-off not yet available")))
     :enable ,(lambda (b _i)
                (and (fboundp 'cmacs-libregnum-editor-look-through-p)
                     (ignore-errors
                       (cmacs-libregnum-editor-look-through-p b)))))
    (:sep)
    (:label "Set audio range…"
     :kinds (audio)
     :action ,(lambda (_b _i)
                (call-interactively #'cmacs-libregnum-editor-set-audio-range)))
    (:label "Set volume…"
     :kinds (audio)
     :action ,(lambda (_b _i)
                (call-interactively
                 #'cmacs-libregnum-editor-set-audio-volume)))
    (:label "Play audio"
     :kinds (audio)
     :action ,(lambda (_b _i) (cmacs-libregnum-editor-play-audio)))
    (:label "Stop audio"
     :kinds (audio)
     :action ,(lambda (_b _i) (cmacs-libregnum-editor-stop-audio))
     :enable ,(lambda (b _i)
                (with-current-buffer b
                  cmacs-libregnum-editor--audio-handle)))
    (:sep)
    (:label "Set tilemap brush…"
     :kinds (tilemap)
     :action ,(lambda (_b _i)
                (call-interactively
                 #'cmacs-libregnum-editor-tilemap-set-brush)))
    (:label "Enter paint mode"
     :kinds (tilemap)
     :action cmacs-libregnum-editor--ctx-enter-paint-mode)
    (:label "Clear tilemap"
     :kinds (tilemap)
     :action cmacs-libregnum-editor--ctx-clear-tilemap)
    (:label "Resize tilemap…"
     :kinds (tilemap)
     :action cmacs-libregnum-editor--ctx-resize-tilemap)
    (:sep)
    (:label "Unpack prefab"
     :kinds (prefab)
     :action cmacs-libregnum-editor--ctx-unpack-prefab
     :enable ,(lambda (_b _i)
                (fboundp 'cmacs-libregnum-editor-unpack-prefab)))
    (:sep)
    (:label "Delete"
     :kinds t
     :action ,(lambda (_b _i) (cmacs-libregnum-editor-delete-current))
     :keys "x"))
  "Data-driven entity context menu for `cmacs-libregnum-editor-mode'.
Each entry is a plist, one of:

  (:label STRING :kinds KINDS :action FN)          ; a command item
  (:label STRING :kinds KINDS :submenu SYMBOL)     ; a real nested submenu
  (:label STRING :kinds KINDS :items-fn FN)        ; a dynamic submenu
  (:sep)                                           ; a divider

Optional per-item keys:
  :enable PRED   — closure (BUFFER ID)->bool; if nil, item is greyed out.
  :keys  STRING  — accelerator hint shown in the menu (editor key binding).

KINDS is t (all node kinds) or a list of node-kind symbols; the item shows only
when the right-clicked node's kind matches.  FN is called as (FN BUFFER ID) on
the right-clicked node, which is already selected.  SYMBOL names a variable
holding a list of sub-items in this same plist shape (see
`cmacs-libregnum-editor-rotate-menu-items').

:items-fn FN is called as (FN BUFFER ID) at pop time and must return a list of
item plists; useful for submenus whose content changes at runtime (e.g. the
per-node script list under \"Manage scripts\").

Node-kind symbols: group primitive mesh sprite tilemap light camera audio
prefab.  To add a menu item, add one plist here — no other code changes.")

(defvar-local cmacs-libregnum-editor-extra-menu-items nil
  "Buffer-local extra right-click menu items appended after the built-in ones.
Subsystems that specialise the editor (e.g. the CAD model viewer adding
print/slice actions) `setq-local' this to a list of item plists shaped like
`cmacs-libregnum-editor-context-menu-items'.  Kept buffer-local so the core
menu stays subsystem-agnostic.")

(defun cmacs-libregnum-editor--filter-menu-items (ksym)
  "Return the menu items applicable to node-kind symbol KSYM.
Keeps every (:sep) marker and every item whose :kinds is t or contains KSYM, in
their original order, so indices stay stable for dispatch."
  (seq-filter
   (lambda (it)
     (or (plist-member it :sep)
         (let ((k (plist-get it :kinds)))
           (or (eq k t) (memq ksym k)))))
   cmacs-libregnum-editor-context-menu-items))

;; The backend detection, menu flattening and popup routing used to live
;; here.  They now live in cmacs-menu.el, which carries no libregnum
;; dependency, so subsystems built WITHOUT --with-cmacs-libregnum (the
;; AI right-click menu, ai-brigade) can use the same code rather than
;; grow a second copy that drifts.  The names below stay as delegations:
;; every existing caller and test keeps working unchanged.
(require 'cmacs-menu)

(defalias 'cmacs-libregnum--lrg-frame-p #'cmacs-menu-lrg-frame-p
  "Non-nil when FRAME (or the selected frame) uses the --lrg display backend.
See `cmacs-menu-lrg-frame-p'.")

(declare-function lrg-popup-menu "cmacs-lrgterm.c" (items &optional x y))

(defalias 'cmacs-libregnum--menu-xy #'cmacs-menu-xy
  "Return (X . Y) frame pixels from an `x-popup-menu' POSITION.
See `cmacs-menu-xy'.")

;; The flatteners turn an Emacs menu into the NESTED tree `lrg-popup-menu'
;; takes: each node is nil (separator), (LABEL . INDEX) (a leaf returning the
;; fixnum INDEX), (LABEL) (a disabled leaf), or (LABEL CHILD...) (a submenu).
;; A parallel VALUES vector maps each leaf's INDEX to its Lisp value, so the
;; chosen index round-trips back to the value regardless of nesting.

(defalias 'cmacs-libregnum--collapse-separators
  #'cmacs-menu-collapse-separators
  "Return TREE with runs of separators collapsed to one, and edges trimmed.
See `cmacs-menu-collapse-separators'.")

(defun cmacs-libregnum--alist-menu-to-lrg (menu)
  "Flatten an alist-form `x-popup-menu' MENU into (TREE . VALUES).
MENU is (TITLE (PANE-TITLE ITEM...) ...); ITEM is (LABEL . VALUE) or a \"--\"
separator.  Panes are joined with separator rows (no header text).  TREE is
the `lrg-popup-menu' item tree; VALUES is a vector indexed by leaf INDEX."
  (cmacs-menu-alist-to-tree menu))

(defalias 'cmacs-libregnum--keymap-menu-to-lrg #'cmacs-menu-keymap-to-tree
  "Flatten a menu KEYMAP into (TREE . VALUES) for `lrg-popup-menu'.
See `cmacs-menu-keymap-to-tree'.")

(defun cmacs-libregnum-popup-menu (position menu)
  "Show MENU like `x-popup-menu' at POSITION and return the chosen value.
On graphical frames this pops a native menu; under the --lrg backend it draws
the in-engine `lrg-popup-menu' (a libregnum/raylib-rendered popup) instead.
MENU must be an alist-style menu (\"(TITLE (PANE (LABEL . VALUE)...)...)\");
both paths return the chosen VALUE, so callers keep their result handling
unchanged.  Keymap menus are handled at their call sites (or, more simply,
by `cmacs-menu-popup-keymap').

A thin wrapper over `cmacs-menu-popup', kept because it is the name the
libregnum-side callers and their tests already use."
  (cmacs-menu-popup position menu))

(defun cmacs-libregnum-editor--menu-keymap (items buffer id &optional title)
  "Build a keymap menu from ITEMS for `x-popup-menu'.
Each command item binds a unique key to an interactive closure that calls its
:action as (ACTION BUFFER ID); each :submenu becomes a real nested GTK submenu
(built recursively); an :items-fn entry calls the function at pop time to get a
dynamic item list for a nested submenu; (:sep) becomes a divider.  Returns the
keymap, which the caller pops and then resolves with `lookup-key' on the chosen
event path.  Submenus are NOT kind-filtered (their items apply to every node).

Optional item keys honoured by this function:
  :enable PRED  — closure (BUFFER ID)->bool; emitted as an :enable form.
  :keys STRING  — accelerator string shown in the menu item."
  (let ((map (make-sparse-keymap (or title "Entity")))
        (n 0))
    (dolist (it items)
      (let ((key (intern (format "cmacs-lrg-mi-%d" n))))
        (setq n (1+ n))
        (cond
         ((plist-member it :sep)
          (define-key map (vector key) '(menu-item "--")))
         ((plist-get it :items-fn)
          ;; Dynamic submenu: call the function now to get current items.
          (let* ((fn       (plist-get it :items-fn))
                 (label    (plist-get it :label))
                 (subitems (ignore-errors (funcall fn buffer id)))
                 (sub      (cmacs-libregnum-editor--menu-keymap
                            (or subitems '((:label "—" :action ignore)))
                            buffer id label)))
            (define-key map (vector key)
              (list 'menu-item label sub))))
         ((plist-get it :submenu)
          (let* ((label (plist-get it :label))
                 (sub   (cmacs-libregnum-editor--menu-keymap
                         (symbol-value (plist-get it :submenu))
                         buffer id label)))
            (define-key map (vector key)
              (list 'menu-item label sub))))
         (t
          (let* ((action  (plist-get it :action))
                 (label   (plist-get it :label))
                 (enable  (plist-get it :enable))
                 (keys    (plist-get it :keys))
                 (closure (lambda ()
                            (interactive)
                            (when action (funcall action buffer id))))
                 (item    (list 'menu-item label closure)))
            ;; Append :keys hint if provided.
            (when keys
              (setq item (append item (list :keys keys))))
            ;; Append :enable form if provided.
            (when enable
              (let ((en-val
                     (ignore-errors (funcall enable buffer id))))
                (setq item (append item (list :enable en-val)))))
            (define-key map (vector key) item))))))
    map))

(defun cmacs-libregnum-editor--context-menu (buffer id pos)
  "Deferred entry point invoked from the C input layer on a viewport right-click.
ID is the picked node id (or -1 for empty space); POS is (FX FY [GX GY GZ]) with
FX,FY the frame-pixel click point and GX,GY,GZ the world ground point.  Pops the
menu from the command loop via a 0-delay timer (never from this GMainContext
callback) so `x-popup-menu' does not start a nested GTK loop in the pselect
wait."
  (when (buffer-live-p buffer)
    (run-with-timer 0 nil
                    #'cmacs-libregnum-editor--popup-context-menu
                    buffer id pos)))

(defun cmacs-libregnum-editor--popup-context-menu (buffer id pos)
  "Pop the context menu for node ID in BUFFER at POS (see `--context-menu')."
  (when (and (buffer-live-p buffer) (consp pos))
    (let ((frame  (or (window-frame (get-buffer-window buffer t))
                      (selected-frame)))
          (fx     (round (nth 0 pos)))
          (fy     (round (nth 1 pos)))
          (ground (nthcdr 2 pos)))
      (if (or (null id) (< id 0))
          (cmacs-libregnum-editor--popup-add-menu buffer fx fy ground frame)
        ;; Select the right-clicked node so --sel-based actions act on it.
        (ignore-errors (cmacs-libregnum-editor-select buffer id))
        (with-current-buffer buffer (setq cmacs-libregnum-editor--current id))
        (cmacs-libregnum-editor--sync-panels buffer id)
        (let* ((kind   (cmacs-libregnum-editor-node-kind buffer id))
               (ksym   (cmacs-libregnum-editor--kind-symbol kind))
               (items  (append
                        (cmacs-libregnum-editor--filter-menu-items ksym)
                        (buffer-local-value
                         'cmacs-libregnum-editor-extra-menu-items buffer)))
               (node-name (ignore-errors
                            (let* ((obj (cmacs-libregnum-editor-node-object
                                         buffer id))
                                   (n (and obj (gobject-get obj "name"))))
                              n)))
               (title  (cmacs-libregnum-editor--outliner-label
                         buffer id (or node-name "")))
               (keymap (cmacs-libregnum-editor--menu-keymap
                         items buffer id title))
               ;; Resolve the chosen leaf to its (curried) action closure, then
               ;; run it WITH THE EDITOR BUFFER CURRENT.  This timer fires in
               ;; whatever buffer was selected at the pop (often a sibling
               ;; panel, e.g. the CAD model viewer's sidebar), so an action that
               ;; reads `current-buffer' -- like the interactive
               ;; `cmacs-libregnum-editor-delete-current' bound to "Delete"/"x"
               ;; -- would otherwise signal "Not in a cmacs-libregnum editor
               ;; buffer".  Native popups return the chosen leaf's event path
               ;; (resolve via `lookup-key'); the --lrg tmm fallback (no-execute)
               ;; returns the leaf binding directly.
               (binding
                (if (cmacs-libregnum--lrg-frame-p frame)
                    ;; In-engine popup: flatten the keymap to items+bindings,
                    ;; pop the libregnum menu, map the chosen index -> binding.
                    (let* ((flat (cmacs-libregnum--keymap-menu-to-lrg keymap))
                           (idx  (lrg-popup-menu (car flat) fx fy))
                           (b    (and idx (aref (cdr flat) idx))))
                      (and (functionp b) b))
                  (let ((choice (x-popup-menu (list (list fx fy) frame)
                                              keymap)))
                    (and choice (listp choice)
                         (let ((b (lookup-key keymap (apply #'vector choice))))
                           (and (functionp b) b)))))))
          (when binding
            (with-current-buffer buffer (funcall binding))))))))

(defun cmacs-libregnum-editor--popup-add-menu (buffer fx fy ground frame)
  "Pop the empty-space \"Add\" menu at frame pixel (FX FY); place at GROUND.
GROUND is (GX GY GZ) or nil; a chosen item is placed at that ground point (or
the origin when GROUND is unavailable)."
  (let* ((sections cmacs-libregnum-editor--palette)
         (flat nil) (i 0)
         (panes
          (mapcar
           (lambda (section)
             (cons (car section)
                   (mapcar
                    (lambda (item)
                      (let ((label (nth 0 item)) (ptype (nth 1 item))
                            (vsym  (nth 2 item)))
                        (setq flat (cons (list ptype (and vsym (symbol-value vsym))
                                               label)
                                         flat))
                        (prog1 (cons label i) (setq i (1+ i)))))
                    (cdr section))))
           sections))
         (choice (cmacs-libregnum-popup-menu (list (list fx fy) frame)
                                             (cons "Add" panes))))
    (setq flat (nreverse flat))
    (when (integerp choice)
      (let* ((entry (nth choice flat))
             (type  (nth 0 entry))
             (value (nth 1 entry))
             (name  (nth 2 entry))
             (wx (or (nth 0 ground) 0.0))
             (wy (or (nth 1 ground) 0.0))
             (wz (or (nth 2 ground) 0.0)))
        (when (cmacs-libregnum-editor--place-item buffer type value name
                                                  wx wy wz)
          (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
            (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
          (cmacs-libregnum-editor--sync-panels buffer))))))

(defun cmacs-libregnum-editor--place-item (buf type value name wx wy wz)
  "Add a palette item to BUF and move it to ground point (WX WY WZ).
TYPE is `prim'/`kind'/`mesh'/`sprite'; VALUE is the primitive/visual int (for
prim/kind).  Returns the new node id, or nil.  Shared by the palette drop path
and the right-click \"Add\" menu."
  (with-current-buffer buf
    (let ((id (pcase type
                ('prim (cmacs-libregnum-editor-add-primitive buf value name))
                ('kind (cmacs-libregnum-editor-add-visual buf value name))
                ('mesh (let ((f (read-file-name "Mesh: " nil nil t)))
                         (cmacs-libregnum-editor-add-visual
                          buf cmacs-libregnum-visual-mesh-asset
                          (file-name-nondirectory f) (expand-file-name f))))
                ('sprite (let ((f (read-file-name "Sprite: " nil nil t)))
                           (cmacs-libregnum-editor-add-visual
                            buf cmacs-libregnum-visual-sprite
                            (file-name-nondirectory f) (expand-file-name f))))
                (_ nil))))
      (when id (cmacs-libregnum-editor-set-position buf id wx wy wz))
      id)))

(defun cmacs-libregnum-editor-undo-edit ()
  "Undo the last level edit."
  (interactive)
  (cmacs-libregnum-editor-undo (cmacs-libregnum-editor--buffer)))

(defun cmacs-libregnum-editor-redo-edit ()
  "Redo the last undone level edit."
  (interactive)
  (cmacs-libregnum-editor-redo (cmacs-libregnum-editor--buffer)))

(defun cmacs-libregnum-editor-save-as (path)
  "Save the level to PATH (a `.rlevel' file)."
  (interactive "FSave .rlevel: ")
  (cmacs-libregnum-editor-save (cmacs-libregnum-editor--buffer)
                               (expand-file-name path))
  (message "Saved level to %s" path))

(defun cmacs-libregnum-editor-outliner ()
  "Show the level's node tree in a side buffer; RET selects a node."
  (interactive)
  (let* ((src (cmacs-libregnum-editor--buffer))
         (nodes (cmacs-libregnum-tree-nodes src))
         (out (get-buffer-create "*cmacs-libregnum outliner*")))
    (with-current-buffer out
      (cmacs-libregnum-outliner-mode)
      (setq cmacs-libregnum-editor--src-buffer src)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dotimes (i (length nodes))
          (let* ((pl (aref nodes i))
                 (name (or (plist-get pl :name) ""))
                 (depth (or (plist-get pl :depth) 0))
                 (id (plist-get pl :id))
                 (label (cmacs-libregnum-editor--outliner-label src id name)))
            (insert (propertize
                     (format "%s%s\n" (make-string (* 2 depth) ?\s) label)
                     'cmacs-libregnum-node-id id))))
        (goto-char (point-min))))
    (display-buffer-in-side-window out '((side . left) (slot . 1)))))

(defvar cmacs-libregnum-outliner-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")       #'cmacs-libregnum-outliner-select)
    (define-key map (kbd "g")         #'cmacs-libregnum-outliner-refresh)
    (define-key map (kbd "m")         #'cmacs-libregnum-outliner-mark)
    (define-key map (kbd "P")         #'cmacs-libregnum-outliner-reparent)
    (define-key map (kbd "r")         #'cmacs-libregnum-outliner-reparent-root)
    (define-key map [mouse-3]         #'cmacs-libregnum-outliner-context-menu)
    (define-key map [down-mouse-3]    #'cmacs-libregnum-outliner-context-menu)
    map)
  "Keymap for `cmacs-libregnum-outliner-mode'.")

(define-derived-mode cmacs-libregnum-outliner-mode special-mode
  "cmacs-Outliner"
  "Major mode for the libregnum editor outliner.")

(defvar-local cmacs-libregnum-outliner--marked nil
  "Node id marked (with \\[cmacs-libregnum-outliner-mark]) awaiting reparent.")

(defun cmacs-libregnum-outliner--id-at-point ()
  "Return the node id on the current outliner line, or nil."
  (get-text-property (line-beginning-position) 'cmacs-libregnum-node-id))

(defun cmacs-libregnum-outliner-mark ()
  "Mark the node on the current line for reparenting."
  (interactive)
  (let ((id (cmacs-libregnum-outliner--id-at-point)))
    (if (null id)
        (user-error "No node on this line")
      (setq cmacs-libregnum-outliner--marked id)
      (message "Marked node %d — move to a target then P (reparent) or r (to root)"
               id))))

(defun cmacs-libregnum-outliner-reparent ()
  "Reparent the marked node under the node on the current line."
  (interactive)
  (let ((child  cmacs-libregnum-outliner--marked)
        (parent (cmacs-libregnum-outliner--id-at-point))
        (src    cmacs-libregnum-editor--src-buffer))
    (cond
     ((null child)  (user-error "Mark a node first with m"))
     ((null parent) (user-error "No target node on this line"))
     ((eq child parent) (user-error "Cannot reparent a node under itself"))
     ((not (buffer-live-p src)) (user-error "No editor buffer"))
     ((cmacs-libregnum-editor-reparent src child parent)
      (setq cmacs-libregnum-outliner--marked nil)
      (cmacs-libregnum-outliner-refresh)
      (message "Reparented node %d under node %d" child parent))
     (t (user-error "Reparent failed (would it create a cycle?)")))))

(defun cmacs-libregnum-outliner-reparent-root ()
  "Reparent the marked node to the level root (top level)."
  (interactive)
  (let ((child cmacs-libregnum-outliner--marked)
        (src   cmacs-libregnum-editor--src-buffer))
    (cond
     ((null child) (user-error "Mark a node first with m"))
     ((not (buffer-live-p src)) (user-error "No editor buffer"))
     ((cmacs-libregnum-editor-reparent src child -1)
      (setq cmacs-libregnum-outliner--marked nil)
      (cmacs-libregnum-outliner-refresh)
      (message "Reparented node %d to root" child))
     (t (user-error "Reparent failed")))))

(defun cmacs-libregnum-outliner--goto-id (id)
  "Move point to the outliner row whose node id is ID, if present.
Returns non-nil when found."
  (goto-char (point-min))
  (let (found)
    (while (and (not found) (not (eobp)))
      (if (eq (get-text-property (line-beginning-position)
                                 'cmacs-libregnum-node-id)
              id)
          (setq found t)
        (forward-line 1)))
    (when found (beginning-of-line))
    found))

(defun cmacs-libregnum-outliner-select ()
  "Select the node on the current outliner line in its editor buffer."
  (interactive)
  (let ((id (get-text-property (line-beginning-position)
                               'cmacs-libregnum-node-id))
        (src cmacs-libregnum-editor--src-buffer))
    (when (and id (buffer-live-p src))
      (cmacs-libregnum-editor-select src id)
      (with-current-buffer src
        (setq cmacs-libregnum-editor--current id))
      (cmacs-libregnum-editor--sync-panels src id)
      (message "Selected node %d" id))))

(defun cmacs-libregnum-outliner-refresh ()
  "Rebuild the outliner from its editor buffer."
  (interactive)
  (when (buffer-live-p cmacs-libregnum-editor--src-buffer)
    (with-current-buffer cmacs-libregnum-editor--src-buffer
      (cmacs-libregnum-editor-outliner))))

(defun cmacs-libregnum-outliner-context-menu (event)
  "Pop the node context menu for the row clicked in the outliner.
Reads the node id under the mouse EVENT position, selects it, then
delegates to `cmacs-libregnum-editor--popup-context-menu' against the
source editor buffer."
  (interactive "e")
  (let* ((posn   (event-start event))
         (pt     (posn-point posn))
         (src    cmacs-libregnum-editor--src-buffer))
    (when (and pt (buffer-live-p src))
      (goto-char pt)
      (let ((id (cmacs-libregnum-outliner--id-at-point)))
        (when id
          (let* ((fpos (posn-x-y posn))
                 (fx   (or (car fpos) 0))
                 (fy   (or (cdr fpos) 0))
                 (frame (window-frame (posn-window posn))))
            (ignore frame)
            (cmacs-libregnum-editor--popup-context-menu
             src id (list fx fy))))))))

;;; Also add an "Add empty group" top-level entry to the outliner for
;;; empty-space use via the command system (optional; deferred --
;;; requires empty space detection in C input layer).

;;; Primitive palette — click (or RET) a shape to add it to the level.
;;;
;;; This is the "asset palette": a left-column panel of placeable primitives.
;;; Clicking adds the shape at the origin and selects it.  (True mouse-drag
;;; from the palette onto a 3D point in the viewport — via pgtk-dnd and a
;;; ground-plane ray — is a planned refinement; click-to-add is the MVP.)

(require 'button)

(defconst cmacs-libregnum-editor--palette
  '(("Primitives"
     ("Cube"      prim cmacs-libregnum-primitive-cube)
     ("Sphere"    prim cmacs-libregnum-primitive-uv-sphere)
     ("IcoSphere" prim cmacs-libregnum-primitive-ico-sphere)
     ("Cylinder"  prim cmacs-libregnum-primitive-cylinder)
     ("Cone"      prim cmacs-libregnum-primitive-cone)
     ("Torus"     prim cmacs-libregnum-primitive-torus)
     ("Plane"     prim cmacs-libregnum-primitive-plane)
     ("Circle"    prim cmacs-libregnum-primitive-circle)
     ("Grid"      prim cmacs-libregnum-primitive-grid)
     ("Rect2D"    prim cmacs-libregnum-primitive-rectangle-2d)
     ("Circle2D"  prim cmacs-libregnum-primitive-circle-2d))
    ("Objects"
     ("Light"     kind cmacs-libregnum-visual-light)
     ("Camera"    kind cmacs-libregnum-visual-camera)
     ("Audio"     kind cmacs-libregnum-visual-audio))
    ("Assets"
     ("Mesh..."   mesh nil)
     ("Sprite..." sprite nil)))
  "Palette sections: (SECTION (LABEL TYPE VALUE-SYMBOL-OR-NIL)...).
TYPE is `prim' (a primitive), `kind' (a visual-kind node), `mesh' or `sprite'
\(prompt for a file), or `fn' (VALUE is a function called with the item
label, in the editor buffer -- the extension type subsystems use).")

(defvar cmacs-libregnum-editor-palette-extra-sections nil
  "Extra palette sections contributed by other subsystems (e.g. CAD).
Each element is either a section in `cmacs-libregnum-editor--palette'
shape or a function returning a list of such sections.  Items may use
the `fn' type so contributors need no palette internals.")

(defvar cmacs-libregnum-palette-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")   #'cmacs-libregnum-palette-activate)
    (define-key map [mouse-1]     #'push-button)
    (define-key map (kbd "g")     #'cmacs-libregnum-palette-refresh)
    (define-key map (kbd "D")     #'cmacs-libregnum-palette-drop)
    (define-key map [drag-mouse-1] #'cmacs-libregnum-palette-drag)
    ;; GTK drag-source: arm a GDK drag on button-press so the OS drag
    ;; machinery can carry the payload to other GTK apps / the viewport.
    (define-key map [down-mouse-1] #'cmacs-libregnum-palette--arm-dnd)
    map)
  "Keymap for `cmacs-libregnum-palette-mode'.")

(defun cmacs-libregnum-palette-activate ()
  "Add the shape named on the current palette line.
Works wherever point sits on the line (so Evil hjkl navigation lands)."
  (interactive)
  (let ((b (button-at (point))))
    (unless b
      (let ((btn (next-button (line-beginning-position))))
        (when (and btn (< (button-start btn) (line-end-position)))
          (setq b btn))))
    (if b
        (button-activate b)
      (user-error "No shape on this line"))))

(define-derived-mode cmacs-libregnum-palette-mode special-mode
  "cmacs-Palette"
  "Major mode for the libregnum editor primitive palette.")

;;; Drop-at-point — arm an asset, then click a 3D point to drop it there.

(defvar cmacs-libregnum-editor--drop-thunk nil
  "Closure (BUF WX WY WZ) that places the armed asset, or nil.")
(defvar cmacs-libregnum-editor--drop-sticky nil
  "When non-nil the armed thunk stays armed after each click (tile painting).")

(defun cmacs-libregnum-editor--arm (src thunk what &optional sticky)
  "Arm SRC so the next viewport click runs THUNK; WHAT names the asset.
With STICKY, stay armed after each click (for tile painting)."
  (setq cmacs-libregnum-editor--drop-thunk thunk
        cmacs-libregnum-editor--drop-sticky sticky)
  (cmacs-libregnum-editor-set-armed src t)
  (message "Click %s in the viewport to %s%s"
           (if sticky "cells" "a point")
           what (if sticky " (M-x ...-stop-paint to finish)" "")))

(defun cmacs-libregnum-editor-stop-paint ()
  "Disarm tile painting / drop-at-point."
  (interactive)
  (setq cmacs-libregnum-editor--drop-thunk nil
        cmacs-libregnum-editor--drop-sticky nil)
  (let ((buf (ignore-errors (cmacs-libregnum-editor--buffer))))
    (when buf (cmacs-libregnum-editor-set-armed buf nil)))
  (message "Painting off"))

(defun cmacs-libregnum-editor--drop (buffer pos)
  "Place the armed asset at ground POS (X Y Z) in BUFFER.
Called (deferred) from the C input layer on the click that follows arming."
  (when (and cmacs-libregnum-editor--drop-thunk (buffer-live-p buffer))
    (funcall cmacs-libregnum-editor--drop-thunk buffer
             (nth 0 pos) (nth 1 pos) (nth 2 pos))
    (if cmacs-libregnum-editor--drop-sticky
        (cmacs-libregnum-editor-set-armed buffer t)   ;; keep painting
      (setq cmacs-libregnum-editor--drop-thunk nil)
      (cmacs-libregnum-editor-set-armed buffer nil))
    (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
      (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))
    (cmacs-libregnum-editor--sync-panels buffer)))

(defun cmacs-libregnum-palette--button-on-line ()
  "Return the palette/asset button on the current line, or nil."
  (or (button-at (point))
      (let ((b (next-button (line-beginning-position))))
        (and b (< (button-start b) (line-end-position)) b))))

(defun cmacs-libregnum-palette--thunk (b)
  "Return a closure (BUF WX WY WZ) that places palette button B's item there."
  (let ((ptype (button-get b 'ptype))
        (value (button-get b 'value))
        (name  (button-get b 'name)))
    (lambda (buf wx wy wz)
      (cmacs-libregnum-editor--place-item buf ptype value name wx wy wz))))

(defun cmacs-libregnum-palette-drop ()
  "Arm the palette item on this line for drop-at-click in the viewport."
  (interactive)
  (let ((b (cmacs-libregnum-palette--button-on-line))
        (src cmacs-libregnum-editor--src-buffer))
    (if (or (null b) (not (buffer-live-p src)))
        (user-error "No item on this line")
      (cmacs-libregnum-editor--arm src (cmacs-libregnum-palette--thunk b)
                                   (button-get b 'name)))))

;;; True mouse drag (intra-Emacs): press a palette/asset item and release
;;; over the viewport to drop it at that 3D point.  This uses Emacs' own
;;; `drag-mouse-1' event (the drag is delivered to the START buffer's keymap
;;; with the release position) for the common case where the source and target
;;; are both inside the same Emacs frame.
;;;
;;; A GTK-native GDK drag-source (for cross-process drops) is layered on top:
;;; see the `cmacs-libregnum-palette--arm-dnd' / `cmacs-libregnum-dnd-arm'
;;; machinery below and in cmacs-libregnum-dnd.c.  The one upstream pgtk hunk
;;; it requires is catalogued in `doc_org/cmacs/cmacs-upstream-changes.org'.

(defun cmacs-libregnum-editor--view-drop (src thunk win px py)
  "Run THUNK (SRC WX WY WZ) at the ground point under window-pixel (PX,PY) of
WIN, which must show SRC's viewport.  PX,PY are window-body relative."
  (let* ((vs (cmacs-libregnum-view-size src))
         (vw (and vs (nth 0 vs)))
         (vh (and vs (nth 1 vs)))
         (bw (window-body-width win t))
         (bh (window-body-height win t)))
    (when (and vw vh (> vw 0) (> vh 0) (> bw 0) (> bh 0))
      (let* ((vx (* px (/ (float vw) bw)))
             (vy (* py (/ (float vh) bh)))
             (pos (cmacs-libregnum-editor-screen-to-ground src vx vy vw vh)))
        (when pos
          (funcall thunk src (nth 0 pos) (nth 1 pos) (nth 2 pos))
          (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
            (with-current-buffer src (cmacs-libregnum-editor-outliner)))
          t)))))

(defun cmacs-libregnum-editor--drag-handler (event thunk-of-button)
  "Handle a drag from a palette/asset panel: THUNK-OF-BUTTON makes a placement
closure from the dragged button.  Dropping on the viewport places at that 3D
point; dropping elsewhere falls back to activating the item (add at origin)."
  (let* ((start (event-start event))
         (end   (event-end event))
         (sbuf  (window-buffer (posn-window start)))
         (b     (with-current-buffer sbuf
                  (save-excursion
                    (goto-char (posn-point start))
                    (cmacs-libregnum-palette--button-on-line))))
         (src   (buffer-local-value 'cmacs-libregnum-editor--src-buffer sbuf))
         (ewin  (posn-window end)))
    (cond
     ((null b) nil)
     ((and src (windowp ewin) (eq (window-buffer ewin) src))
      (let ((xy (posn-x-y end)))
        (if (cmacs-libregnum-editor--view-drop
             src (funcall thunk-of-button b) ewin (car xy) (cdr xy))
            (message "Dropped %s into the viewport" (button-get b 'name))
          (message "Could not place there"))))
     (t (button-activate b)))))   ;; not over the viewport: add at origin

(defun cmacs-libregnum-palette-drag (event)
  "Drag a palette item and drop it at a 3D point in the viewport."
  (interactive "e")
  (cmacs-libregnum-editor--drag-handler event #'cmacs-libregnum-palette--thunk))

(defun cmacs-libregnum-palette--add (button)
  "Add the item described by BUTTON to the palette's editor buffer."
  (let ((ptype (button-get button 'ptype))
        (value (button-get button 'value))
        (name  (button-get button 'name))
        (src   cmacs-libregnum-editor--src-buffer))
    (if (not (buffer-live-p src))
        (user-error "Palette has no live editor buffer")
      (with-current-buffer src
        (pcase ptype
          ('prim   (cmacs-libregnum-editor--add value name))
          ('kind   (cmacs-libregnum-editor--add-visual value name))
          ('mesh   (call-interactively #'cmacs-libregnum-editor-add-mesh))
          ('sprite (call-interactively #'cmacs-libregnum-editor-add-sprite))
          ('fn     (funcall value name))))
      ;; Keep the outliner + inspector in sync if they are showing.
      (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
        (with-current-buffer src (cmacs-libregnum-editor-outliner)))
      (when (buffer-live-p (get-buffer "*cmacs-libregnum inspector*"))
        (with-current-buffer (get-buffer "*cmacs-libregnum inspector*")
          (cmacs-libregnum-inspector--rebuild))))))

(defun cmacs-libregnum-editor-palette ()
  "Show the primitive palette for the current editor buffer (a side window)."
  (interactive)
  (let* ((src (cmacs-libregnum-editor--buffer))
         (pal (get-buffer-create "*cmacs-libregnum palette*")))
    (with-current-buffer pal
      (cmacs-libregnum-palette-mode)
      (setq cmacs-libregnum-editor--src-buffer src)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Palette  " 'face 'bold))
        (insert (propertize "j/k move · RET/click add\n\n" 'face 'shadow))
        (dolist (section (append cmacs-libregnum-editor--palette
                                 (cl-loop for ext in cmacs-libregnum-editor-palette-extra-sections
                                          append (if (functionp ext)
                                                     (funcall ext)
                                                   (list ext)))))
          (insert (propertize (format "%s\n" (car section)) 'face 'bold))
          (dolist (item (cdr section))
            (let* ((label (nth 0 item))
                   (ptype (nth 1 item))
                   (vsym  (nth 2 item))
                   ;; `fn' items carry the function symbol itself; the
                   ;; others store a value under a variable symbol.
                   (value (and vsym (if (eq ptype 'fn)
                                        vsym
                                      (symbol-value vsym)))))
              (insert "  ")
              (insert-text-button
               label
               'ptype ptype 'value value 'name label
               'action #'cmacs-libregnum-palette--add
               'follow-link t
               'help-echo (format "Add %s" label))
              (insert "\n")))
          (insert "\n"))
        (goto-char (point-min))))
    (display-buffer-in-side-window pal '((side . left) (slot . 0)))))

(defun cmacs-libregnum-palette-refresh ()
  "Rebuild the palette from its editor buffer."
  (interactive)
  (when (buffer-live-p cmacs-libregnum-editor--src-buffer)
    (with-current-buffer cmacs-libregnum-editor--src-buffer
      (cmacs-libregnum-editor-palette))))

;;; Asset browser — list model/image files; click to place one in the level.

(defcustom cmacs-libregnum-editor-asset-extensions
  '("glb" "gltf" "obj" "png" "jpg" "jpeg")
  "File extensions the asset browser lists (models become mesh nodes,
images become sprite nodes)."
  :type '(repeat string)
  :group 'cmacs-libregnum)

(defvar-local cmacs-libregnum-assets--dir nil
  "Directory the asset browser is scanning.")

(defvar cmacs-libregnum-assets-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-libregnum-palette-activate)
    (define-key map [mouse-1]   #'push-button)
    (define-key map (kbd "g")   #'cmacs-libregnum-assets-refresh)
    (define-key map (kbd "d")   #'cmacs-libregnum-editor-assets)
    (define-key map (kbd "D")   #'cmacs-libregnum-assets-drop)
    (define-key map [drag-mouse-1] #'cmacs-libregnum-assets-drag)
    ;; GTK drag-source: arm a GDK drag on button-press.
    (define-key map [down-mouse-1] #'cmacs-libregnum-assets--arm-dnd)
    map)
  "Keymap for `cmacs-libregnum-assets-mode'.")

(define-derived-mode cmacs-libregnum-assets-mode special-mode
  "cmacs-Assets"
  "Major mode for the libregnum editor asset browser.")

(defun cmacs-libregnum-assets--add (button)
  "Place the asset file described by BUTTON into the editor level."
  (let ((path (button-get button 'path))
        (kind (button-get button 'kind))
        (name (button-get button 'name))
        (src  cmacs-libregnum-editor--src-buffer))
    (if (not (buffer-live-p src))
        (user-error "Asset browser has no live editor buffer")
      (with-current-buffer src
        (cmacs-libregnum-editor--add-visual kind name path))
      (when (buffer-live-p (get-buffer "*cmacs-libregnum outliner*"))
        (with-current-buffer src (cmacs-libregnum-editor-outliner))))))

(defun cmacs-libregnum-assets--thunk (b)
  "Return a closure (BUF WX WY WZ) that places asset button B's file there."
  (let ((path (button-get b 'path))
        (kind (button-get b 'kind))
        (name (button-get b 'name)))
    (lambda (buf wx wy wz)
      (with-current-buffer buf
        (let ((id (cmacs-libregnum-editor-add-visual buf kind name path)))
          (when id (cmacs-libregnum-editor-set-position buf id wx wy wz)))))))

(defun cmacs-libregnum-assets-drop ()
  "Arm the asset on this line for drop-at-click in the viewport."
  (interactive)
  (let ((b (cmacs-libregnum-palette--button-on-line))
        (src cmacs-libregnum-editor--src-buffer))
    (if (or (null b) (not (buffer-live-p src)))
        (user-error "No asset on this line")
      (cmacs-libregnum-editor--arm src (cmacs-libregnum-assets--thunk b)
                                   (button-get b 'name)))))

(defun cmacs-libregnum-assets-drag (event)
  "Drag an asset and drop it at a 3D point in the viewport."
  (interactive "e")
  (cmacs-libregnum-editor--drag-handler event #'cmacs-libregnum-assets--thunk))

(defun cmacs-libregnum-editor-assets (&optional dir)
  "Show an asset browser for DIR (default the level's directory) as a side
window.  Click (or RET) a file to add it: models as mesh nodes, images as
sprite nodes."
  (interactive
   (list (when current-prefix-arg
           (read-directory-name "Asset directory: "))))
  (let* ((src (cmacs-libregnum-editor--buffer))
         (dir (or dir cmacs-libregnum-assets--dir
                  (buffer-local-value 'default-directory src)))
         (rx  (concat "\\.\\("
                      (mapconcat #'regexp-quote
                                 cmacs-libregnum-editor-asset-extensions "\\|")
                      "\\)\\'"))
         (models '("glb" "gltf" "obj"))
         (files (ignore-errors
                  (seq-take (directory-files-recursively dir rx) 200)))
         (ass (get-buffer-create "*cmacs-libregnum assets*")))
    (with-current-buffer ass
      (cmacs-libregnum-assets-mode)
      (setq cmacs-libregnum-editor--src-buffer src
            cmacs-libregnum-assets--dir dir)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Assets  " 'face 'bold))
        (insert (propertize "RET/click place · g refresh · d dir\n" 'face 'shadow))
        (insert (propertize (format "%s\n\n" (abbreviate-file-name dir))
                            'face 'shadow))
        (if (null files)
            (insert (propertize "(no model/image files found)\n" 'face 'shadow))
          (dolist (f files)
            (let* ((ext (downcase (or (file-name-extension f) "")))
                   (kind (if (member ext models)
                             cmacs-libregnum-visual-mesh-asset
                           cmacs-libregnum-visual-sprite))
                   (label (file-name-nondirectory f)))
              (insert "  ")
              (insert-text-button
               label
               'path f 'kind kind 'name label
               'action #'cmacs-libregnum-assets--add
               'follow-link t
               'help-echo (format "Place %s" f))
              (insert "\n"))))
        (goto-char (point-min))))
    (display-buffer-in-side-window ass '((side . left) (slot . 2)))))

(defun cmacs-libregnum-assets-refresh ()
  "Rescan the asset browser's directory."
  (interactive)
  (when (buffer-live-p cmacs-libregnum-editor--src-buffer)
    (let ((dir cmacs-libregnum-assets--dir))
      (with-current-buffer cmacs-libregnum-editor--src-buffer
        (cmacs-libregnum-editor-assets dir)))))

;;; Property inspector — view/edit the selected node's name + transform.
;;;
;;; A `widget.el' form (position, rotation in degrees, scale) whose Apply
;;; routes writes through the undoable editor commands; refreshed on selection
;;; by `cmacs-libregnum-editor--on-select'.  The buffer is editable (not a
;;; read-only `special-mode'), so widget fields accept input.

(require 'wid-edit)

(defvar cmacs-libregnum-inspector-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map widget-keymap)
    (define-key map (kbd "C-c C-c") #'cmacs-libregnum-inspector-apply)
    (define-key map (kbd "C-c C-k") #'cmacs-libregnum-inspector-refresh)
    map)
  "Keymap for `cmacs-libregnum-inspector-mode'.")

(define-derived-mode cmacs-libregnum-inspector-mode fundamental-mode
  "cmacs-Inspector"
  "Major mode for the libregnum editor property inspector (a widget form).")

(defvar-local cmacs-libregnum-inspector--id nil
  "Node id the inspector is currently showing.")
(defvar-local cmacs-libregnum-inspector--fields nil
  "Alist (KEY . WIDGET) of the inspector's editable number fields.")
(defvar-local cmacs-libregnum-inspector--props nil
  "List of (PROP-NAME WIDGET . KIND) for introspected node properties.
KIND is `bool', `string' or `number'.")

(defconst cmacs-libregnum-inspector--skip-props '("guid" "visual")
  "Node properties the inspector does not expose for editing.")

(defun cmacs-libregnum-inspector--prop-kind (type)
  "Classify a GObject property TYPE name into a widget kind, or nil to skip."
  (cond ((string= type "gboolean") 'bool)
        ((string= type "gchararray") 'string)
        ((member type '("gint" "guint" "glong" "gulong" "gint64" "guint64"
                        "gfloat" "gdouble")) 'number)
        (t nil)))                       ;; objects/enums/boxed: not edited here

(defun cmacs-libregnum-inspector--prop-field (obj name kind)
  "Insert an editable widget for property NAME of KIND on OBJ; return the widget."
  (let ((val (ignore-errors (gobject-get obj name))))
    (widget-insert (format "  %-10s " name))
    (prog1
        (pcase kind
          ('bool   (widget-create 'checkbox (and val t)))
          ('number (widget-create 'editable-field :size 9 :format "%v"
                                  (format "%.6g" (or val 0))))
          (_       (widget-create 'editable-field :size 16 :format "%v"
                                  (or val ""))))
      (widget-insert "\n"))))

(defun cmacs-libregnum-inspector--node-name (buf id)
  "Return node ID's name from BUF's tree-nodes, or a default."
  (let ((nodes (cmacs-libregnum-tree-nodes buf)) (name "(node)"))
    (dotimes (i (length nodes))
      (when (eq (plist-get (aref nodes i) :id) id)
        (setq name (or (plist-get (aref nodes i) :name) "(node)"))))
    name))

(defun cmacs-libregnum-inspector--field (label val)
  "Insert LABEL + an editable number field for VAL; return the field widget."
  (widget-insert (format "  %-2s " label))
  (prog1 (widget-create 'editable-field :size 9 :format "%v"
                        (format "%.4g" val))
    (widget-insert "\n")))

(defun cmacs-libregnum-inspector--rebuild ()
  "Render the inspector for the current selection (in the inspector buffer)."
  (let* ((src cmacs-libregnum-editor--src-buffer)
         (id  (and (buffer-live-p src) (cmacs-libregnum-editor--sel src))))
    (let ((inhibit-read-only t)) (erase-buffer) (remove-overlays))
    (setq cmacs-libregnum-inspector--id id
          cmacs-libregnum-inspector--fields nil
          cmacs-libregnum-inspector--props nil)
    (if (null id)
        (progn
          (widget-insert (propertize "Inspector\n\n" 'face 'bold))
          (widget-insert (propertize "No selection.\nClick a node, or add a \
shape, then edit it here." 'face 'shadow))
          (widget-setup))
      (let* ((loc (cmacs-libregnum-editor-node-location src id))
             (rot (cmacs-libregnum-editor-node-rotation src id))
             (scl (cmacs-libregnum-editor-node-scale src id))
             (nm  (cmacs-libregnum-inspector--node-name src id))
             (nsc (or (cmacs-libregnum-editor-node-script-count src id) 0)))
        (widget-insert (propertize (format "Node %d  (%s)\n" id nm)
                                   'face 'bold))
        (widget-insert (propertize (format "scripts: %d  (L to attach)\n\n" nsc)
                                   'face 'shadow))
        (widget-insert (propertize "Position\n" 'face 'bold))
        (push (cons 'px (cmacs-libregnum-inspector--field "X" (nth 0 loc)))
              cmacs-libregnum-inspector--fields)
        (push (cons 'py (cmacs-libregnum-inspector--field "Y" (nth 1 loc)))
              cmacs-libregnum-inspector--fields)
        (push (cons 'pz (cmacs-libregnum-inspector--field "Z" (nth 2 loc)))
              cmacs-libregnum-inspector--fields)
        (widget-insert (propertize "Rotation (deg)\n" 'face 'bold))
        (push (cons 'rx (cmacs-libregnum-inspector--field
                         "X" (radians-to-degrees (nth 0 rot))))
              cmacs-libregnum-inspector--fields)
        (push (cons 'ry (cmacs-libregnum-inspector--field
                         "Y" (radians-to-degrees (nth 1 rot))))
              cmacs-libregnum-inspector--fields)
        (push (cons 'rz (cmacs-libregnum-inspector--field
                         "Z" (radians-to-degrees (nth 2 rot))))
              cmacs-libregnum-inspector--fields)
        (widget-insert (propertize "Scale\n" 'face 'bold))
        (push (cons 'sx (cmacs-libregnum-inspector--field "X" (nth 0 scl)))
              cmacs-libregnum-inspector--fields)
        (push (cons 'sy (cmacs-libregnum-inspector--field "Y" (nth 1 scl)))
              cmacs-libregnum-inspector--fields)
        (push (cons 'sz (cmacs-libregnum-inspector--field "Z" (nth 2 scl)))
              cmacs-libregnum-inspector--fields)
        ;; Introspected node properties (name/visible/locked/is-2d/...), driven
        ;; by GObject GParamSpecs via the node->GObject bridge.
        (when (and (fboundp 'cmacs-libregnum-editor-node-object)
                   (fboundp 'gobject-list-properties))
          (let ((obj (ignore-errors
                       (cmacs-libregnum-editor-node-object src id))))
            (when obj
              (widget-insert (propertize "Properties\n" 'face 'bold))
              (dolist (pname (ignore-errors (gobject-list-properties obj)))
                (unless (member pname cmacs-libregnum-inspector--skip-props)
                  (let* ((info (ignore-errors
                                 (gobject-property-info obj pname)))
                         (kind (and info (plist-get info :writable)
                                    (cmacs-libregnum-inspector--prop-kind
                                     (plist-get info :type)))))
                    (when kind
                      (push (cons pname
                                  (cons (cmacs-libregnum-inspector--prop-field
                                         obj pname kind)
                                        kind))
                            cmacs-libregnum-inspector--props)))))
              (widget-insert "\n"))))
        (widget-create 'push-button
                       :notify (lambda (&rest _)
                                 (cmacs-libregnum-inspector-apply))
                       "Apply")
        (widget-insert "  ")
        (widget-create 'push-button
                       :notify (lambda (&rest _)
                                 (cmacs-libregnum-inspector-refresh))
                       "Revert")
        (widget-insert (propertize "\n\nTab: next field · C-c C-c apply\n"
                                   'face 'shadow))
        (run-hook-with-args 'cmacs-libregnum-inspector-extra-sections
                            src id)
        (widget-setup)
        (goto-char (point-min))))))

(defvar cmacs-libregnum-inspector-extra-sections nil
  "Functions run with (SRC-BUFFER NODE-ID) while building the inspector.
Called in the inspector buffer after the built-in sections; insert
widgets to add subsystem panels (the CAD params section uses this).")

(defun cmacs-libregnum-inspector--num (key)
  "Return the numeric value of inspector field KEY."
  (string-to-number (widget-value
                     (cdr (assq key cmacs-libregnum-inspector--fields)))))

(defun cmacs-libregnum-inspector-apply ()
  "Write the inspector's fields back to the node as undoable edits."
  (interactive)
  (let ((src cmacs-libregnum-editor--src-buffer)
        (id  cmacs-libregnum-inspector--id))
    (if (not (and (buffer-live-p src) id cmacs-libregnum-inspector--fields))
        (user-error "Nothing to apply")
      (cmacs-libregnum-editor-set-position src id
                                           (cmacs-libregnum-inspector--num 'px)
                                           (cmacs-libregnum-inspector--num 'py)
                                           (cmacs-libregnum-inspector--num 'pz))
      (cmacs-libregnum-editor-set-rotation
       src id
       (degrees-to-radians (cmacs-libregnum-inspector--num 'rx))
       (degrees-to-radians (cmacs-libregnum-inspector--num 'ry))
       (degrees-to-radians (cmacs-libregnum-inspector--num 'rz)))
      (cmacs-libregnum-editor-set-scale src id
                                        (cmacs-libregnum-inspector--num 'sx)
                                        (cmacs-libregnum-inspector--num 'sy)
                                        (cmacs-libregnum-inspector--num 'sz))
      ;; Write back introspected properties via the GObject bridge.  (These go
      ;; direct, so they are not on the engine undo stack -- transform is.)
      (when (and cmacs-libregnum-inspector--props
                 (fboundp 'cmacs-libregnum-editor-node-object))
        (let ((obj (ignore-errors
                     (cmacs-libregnum-editor-node-object src id))))
          (when obj
            (dolist (p cmacs-libregnum-inspector--props)
              (let* ((name (car p)) (widget (cadr p)) (kind (cddr p))
                     (raw (widget-value widget))
                     (val (pcase kind
                            ('bool (and raw t))
                            ('number (string-to-number raw))
                            (_ raw))))
                (ignore-errors (gobject-set obj name val)))))
          (cmacs-libregnum-redraw src)))
      (message "Applied node %d" id))))

(defun cmacs-libregnum-inspector-refresh ()
  "Rebuild the inspector from its editor buffer's current selection."
  (interactive)
  (when (buffer-live-p cmacs-libregnum-editor--src-buffer)
    (cmacs-libregnum-inspector--rebuild)))

(defun cmacs-libregnum-editor-inspector ()
  "Show an editable property inspector for the selected node (a side window)."
  (interactive)
  (let* ((src (cmacs-libregnum-editor--buffer))
         (insp (get-buffer-create "*cmacs-libregnum inspector*")))
    (with-current-buffer insp
      (cmacs-libregnum-inspector-mode)
      (setq cmacs-libregnum-editor--src-buffer src)
      (cmacs-libregnum-inspector--rebuild))
    (display-buffer-in-side-window insp '((side . right) (slot . 0)))))

;; Evil (e.g. Doom) integration:
;;  - Editor viewport: Emacs state, so its single-key tool commands
;;    (c/b/y/n/x/m/u/...) reach the editor keymap instead of Evil operators.
;;  - Palette + outliner: read-only list panels in Motion state, so Evil
;;    hjkl navigation works like a normal buffer while they stay read-only;
;;    RET activates the item on the current line.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-libregnum-editor-mode 'emacs)
    (evil-set-initial-state 'cmacs-libregnum-palette-mode 'motion)
    (evil-set-initial-state 'cmacs-libregnum-outliner-mode 'motion)
    (evil-set-initial-state 'cmacs-libregnum-assets-mode 'motion)
    ;; The inspector is an editable widget form, but keep it in Normal state so
    ;; Evil hjkl navigation + Esc work like any other buffer.  Point starts at
    ;; column 0 (left of the "  X " field labels), so j/k move down the margin
    ;; and never land inside a field's self-inserting keymap.  Edit a field with
    ;; `i'/`a' (Insert state) then `Esc'; toggle checkboxes / press Apply with
    ;; RET; apply everything with `C-c C-c'.
    (evil-set-initial-state 'cmacs-libregnum-inspector-mode 'normal))
  ;; In Motion state Evil's own RET/g/m shadow the major-mode map, so register
  ;; the activation keys in each mode's Motion-state overlay.  Use the FUNCTION
  ;; `evil-define-key*', never the `evil-define-key' MACRO: the macro only
  ;; expands at byte-compile time when Evil is already loaded; compiled without
  ;; Evil it is emitted as a runtime function call and signals "invalid
  ;; function: evil-define-key".  (`fboundp' is t for a macro too, so the old
  ;; guard did not catch it.)
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion cmacs-libregnum-palette-mode-map
      (kbd "RET")      #'cmacs-libregnum-palette-activate
      (kbd "D")        #'cmacs-libregnum-palette-drop
      [drag-mouse-1]   #'cmacs-libregnum-palette-drag
      [down-mouse-1]   #'cmacs-libregnum-palette--arm-dnd)
    (evil-define-key* 'motion cmacs-libregnum-outliner-mode-map
      (kbd "RET") #'cmacs-libregnum-outliner-select
      (kbd "g")   #'cmacs-libregnum-outliner-refresh
      (kbd "m")   #'cmacs-libregnum-outliner-mark
      (kbd "P")   #'cmacs-libregnum-outliner-reparent
      (kbd "r")   #'cmacs-libregnum-outliner-reparent-root)
    (evil-define-key* 'motion cmacs-libregnum-assets-mode-map
      (kbd "RET")    #'cmacs-libregnum-palette-activate
      (kbd "g")      #'cmacs-libregnum-assets-refresh
      (kbd "d")      #'cmacs-libregnum-editor-assets
      (kbd "D")      #'cmacs-libregnum-assets-drop
      [drag-mouse-1] #'cmacs-libregnum-assets-drag
      [down-mouse-1] #'cmacs-libregnum-assets--arm-dnd)
    ;; Inspector runs in Normal state (editable widget form): Evil's Normal map
    ;; would otherwise shadow the widget keys, so re-register RET (activate
    ;; button / toggle checkbox), TAB / S-TAB (move between fields), and the
    ;; apply/revert chords.  hjkl + Esc + i/a then fall through to Evil itself.
    (evil-define-key* 'normal cmacs-libregnum-inspector-mode-map
      (kbd "RET")       #'widget-button-press
      (kbd "TAB")       #'widget-forward
      (kbd "<tab>")     #'widget-forward
      (kbd "<backtab>") #'widget-backward
      (kbd "C-c C-c")   #'cmacs-libregnum-inspector-apply
      (kbd "C-c C-k")   #'cmacs-libregnum-inspector-refresh)))


;;; GTK drag-source for palette / asset rows.
;;;
;;; When HAVE_PGTK and HAVE_CMACS_LIBREGNUM are both defined, the C side
;;; provides `cmacs-libregnum-dnd-arm' (cmacs-libregnum-dnd.c).  The Elisp
;;; side arms it via [down-mouse-1] in the palette/asset mode maps; the C
;;; motion handler then initiates the GDK drag when the threshold is crossed.
;;;
;;; On the receiving side we add "application/x-libregnum" to the pgtk-dnd
;;; type list so drops on the viewport buffer are decoded and forwarded to the
;;; existing placement machinery (cmacs-libregnum-editor--view-drop).

(defun cmacs-libregnum-palette--make-payload (button)
  "Return a payload string for the GDK drag from palette BUTTON.
Format: \"lrg-prim:NAME\", \"lrg-kind:VALUE\", \"lrg-asset:NAME\" or nil."
  (when button
    (let ((ptype (button-get button 'ptype))
          (value (button-get button 'value))
          (name  (button-get button 'name)))
      (pcase ptype
        ('prim   (format "lrg-prim:%s" name))
        ('kind   (format "lrg-kind:%s" (or value name)))
        ('mesh   (format "lrg-asset:%s" (or name "mesh")))
        ('sprite (format "lrg-asset:%s" (or name "sprite")))
        (_ nil)))))

(defun cmacs-libregnum-assets--make-payload (button)
  "Return a payload string for the GDK drag from asset browser BUTTON.
Format: \"lrg-asset:PATH\" or nil."
  (when button
    (let ((path (button-get button 'path)))
      (when path (format "lrg-asset:%s" path)))))

(defun cmacs-libregnum-palette--arm-dnd (event)
  "Arm a GDK drag from a [down-mouse-1] press on a palette row.
Calls `cmacs-libregnum-dnd-arm' so the C motion handler can initiate a
GTK drag when the pointer crosses the drag threshold.  Falls back silently
when the C DEFUN is absent (non-pgtk builds)."
  (interactive "e")
  ;; Let Emacs process the down-mouse-1 normally too (focus, etc.).
  ;; We return immediately; the C side does the work on motion events.
  (when (fboundp 'cmacs-libregnum-dnd-arm)
    (let* ((pos (event-start event))
           (win (posn-window pos))
           (b   (when (windowp win)
                  (with-current-buffer (window-buffer win)
                    (save-excursion
                      (goto-char (posn-point pos))
                      (cmacs-libregnum-palette--button-on-line)))))
           (payload (cmacs-libregnum-palette--make-payload b))
           (xy (posn-x-y pos)))
      (when (and payload xy)
        (cmacs-libregnum-dnd-arm payload (car xy) (cdr xy))))))

(defun cmacs-libregnum-assets--arm-dnd (event)
  "Arm a GDK drag from a [down-mouse-1] press on an asset row."
  (interactive "e")
  (when (fboundp 'cmacs-libregnum-dnd-arm)
    (let* ((pos (event-start event))
           (win (posn-window pos))
           (b   (when (windowp win)
                  (with-current-buffer (window-buffer win)
                    (save-excursion
                      (goto-char (posn-point pos))
                      (cmacs-libregnum-palette--button-on-line)))))
           (payload (cmacs-libregnum-assets--make-payload b))
           (xy (posn-x-y pos)))
      (when (and payload xy)
        (cmacs-libregnum-dnd-arm payload (car xy) (cdr xy))))))

;;; Viewport drop handler for GTK DnD drops on the libregnum editor buffer.
;;;
;;; When a GDK drag (from our palette/asset arm or an external app) is
;;; dropped over the viewport, pgtk-dnd fires drag-drop → DRAG_N_DROP_EVENT
;;; → pgtk-dnd-handle-gdk → pgtk-dnd-drop-data → our handler below.
;;; The handler decodes the "lrg-*" payload and calls the existing
;;; placement machinery.

(defun cmacs-libregnum--dnd-handle-drop (window _action data)
  "Handle a GTK DnD drop of an \"application/x-libregnum\" or text/plain
lrg-* payload onto WINDOW.
If WINDOW shows a libregnum editor viewport, place the dragged item at
the drop ground point.  Otherwise return nil (reject)."
  (when (and (windowp window) (window-live-p window))
    (let* ((buf (window-buffer window))
           (payload (if (stringp data)
                        (string-trim data)
                      (decode-coding-string data 'utf-8))))
      (when (and (buffer-live-p buf)
                 (cmacs-libregnum-attached-p buf)
                 (string-match
                  "\`lrg-\(prim\|kind\|asset\):\(.*\)\'" payload))
        (let* ((kind    (match-string 1 payload))
               (value   (match-string 2 payload))
               ;; Build a thunk that places the item: we read the drop
               ;; coordinates from the event position after the fact.
               (thunk   (pcase kind
                          ("prim"
                           (lambda (b wx wy wz)
                             (cmacs-libregnum-editor-add-primitive
                              b value value)
                             (let ((id (cmacs-libregnum-editor-selected-id b)))
                               (when id
                                 (cmacs-libregnum-editor-set-position
                                  b id wx wy wz)))))
                          ("kind"
                           (let ((k (string-to-number value)))
                             (lambda (b wx wy wz)
                               (let ((id (cmacs-libregnum-editor-add-visual
                                          b k value nil)))
                                 (when id
                                   (cmacs-libregnum-editor-set-position
                                    b id wx wy wz))))))
                          ("asset"
                           (let ((path (expand-file-name value)))
                             (lambda (b wx wy wz)
                               (let* ((ext (downcase
                                            (or (file-name-extension path)
                                                "")))
                                      (mesh-exts
                                       '("glb" "gltf" "obj"))
                                      (kind (if (member ext mesh-exts)
                                                cmacs-libregnum-visual-mesh-asset
                                              cmacs-libregnum-visual-sprite))
                                      (name (file-name-nondirectory path))
                                      (id   (cmacs-libregnum-editor-add-visual
                                             b kind name path)))
                                 (when id
                                   (cmacs-libregnum-editor-set-position
                                    b id wx wy wz)))))))))
          ;; Convert the drop window-pixel position to a 3D ground point
          ;; via the existing screen-to-ground raycaster.
          (let* ((pos   (event-start last-input-event))
                 (xy    (posn-x-y pos))
                 (px    (or (car xy) 0))
                 (py    (or (cdr xy) 0))
                 (vs    (cmacs-libregnum-view-size buf))
                 (vw    (and vs (nth 0 vs)))
                 (vh    (and vs (nth 1 vs)))
                 (bw    (window-body-width window t))
                 (bh    (window-body-height window t)))
            (when (and vw vh (> vw 0) (> vh 0) (> bw 0) (> bh 0))
              (let* ((vx  (* px (/ (float vw) bw)))
                     (vy  (* py (/ (float vh) bh)))
                     (gnd (cmacs-libregnum-editor-screen-to-ground
                           buf vx vy vw vh)))
                (when gnd
                  (funcall thunk buf
                           (nth 0 gnd) (nth 1 gnd) (nth 2 gnd))
                  (when (buffer-live-p
                         (get-buffer "*cmacs-libregnum outliner*"))
                    (with-current-buffer buf
                      (cmacs-libregnum-editor-outliner)))
                  'copy)))))))))

;;; Register our drop handler with pgtk-dnd when the library is loaded.
;;; The check for pgtk-dnd-types-alist ensures we don't crash on non-pgtk
;;; builds or when pgtk-dnd hasn't been loaded yet.

(defun cmacs-libregnum--dnd-register ()
  "Add libregnum drop targets to `pgtk-dnd-types-alist' and
`pgtk-dnd-known-types' (both are frame-global, not buffer-local).
Safe to call multiple times."
  (when (boundp 'pgtk-dnd-types-alist)
    (unless (assoc "application/x-libregnum" pgtk-dnd-types-alist)
      (push (cons "application/x-libregnum"
                  #'cmacs-libregnum--dnd-handle-drop)
            pgtk-dnd-types-alist)))
  ;; Also accept text/plain with an lrg-* prefix from external drag sources
  ;; (the existing text/plain handler inserts text; ours intercepts first via
  ;; buffer-local pgtk-dnd-test-function override on viewport buffers -- see
  ;; cmacs-libregnum-mode setup below).
  (when (boundp 'pgtk-dnd-known-types)
    (unless (member "application/x-libregnum" pgtk-dnd-known-types)
      ;; Prepend so it is preferred over generic text/plain.
      (setq pgtk-dnd-known-types
            (cons "application/x-libregnum" pgtk-dnd-known-types)))))

(with-eval-after-load 'pgtk-dnd
  (cmacs-libregnum--dnd-register))

;; Also register now if pgtk-dnd is already loaded.
(when (featurep 'pgtk-dnd)
  (cmacs-libregnum--dnd-register))

;;;; Keep viewports undistorted: track each view window's aspect ratio ------

;; The overlay blits a view's FBO across its window's pixel rectangle with a
;; per-axis scale (pw/vw, ph/vh).  If the FBO's aspect differs from the
;; window's, that scale is non-uniform and content is stretched -- a square
;; renders as a rectangle when the window is resized.  The fix (same one
;; gnuseye uses) is to keep every on-screen view's FBO sized to its window's
;; exact pixel dimensions, so the blit is 1:1 and raylib derives the correct
;; camera aspect from the FBO.  The C resize no-ops when the size is
;; unchanged, so this is cheap.

(defvar cmacs-libregnum--fit-timer nil
  "Idle timer coalescing window-size changes for `cmacs-libregnum--fit-views'.")

(defun cmacs-libregnum--fit-views ()
  "Resize every on-screen libregnum view's FBO to its window's BODY size.
The FBO is sized to the text area (`window-body-*'), NOT the full window
pixel size: the compositors paint the FBO into `window_box' TEXT_AREA and the
click mapping (`frame_to_view_coords') uses the same body rect, so sizing the
FBO to the pixel height -- which includes the mode line -- stretched the view
over the Doom modeline."
  (setq cmacs-libregnum--fit-timer nil)
  (when (fboundp 'cmacs-libregnum-attached-p)
    (dolist (frame (frame-list))
      (when (frame-live-p frame)
        (dolist (win (window-list frame 'no-minibuffer))
          (let ((buf (window-buffer win)))
            (when (and (buffer-live-p buf)
                       (ignore-errors (cmacs-libregnum-attached-p buf)))
              (let ((w (window-body-width win t))
                    (h (window-body-height win t)))
                (when (and (> w 1) (> h 1))
                  (ignore-errors (cmacs-libregnum-resize buf w h)))))))))))

(defun cmacs-libregnum--on-size-change (&optional _frame)
  "Coalesce window size changes, then refit all views (see `--fit-views')."
  (unless cmacs-libregnum--fit-timer
    (setq cmacs-libregnum--fit-timer
          (run-with-idle-timer 0.06 nil #'cmacs-libregnum--fit-views))))

(defun cmacs-libregnum-fit-window (&optional buffer)
  "Fit BUFFER's (or the current buffer's) view FBO to its window now.
Call after first displaying a view so its initial frame is not distorted
before the first window-size change fires."
  (let ((buf (or buffer (current-buffer))))
    (when (and (buffer-live-p buf)
               (fboundp 'cmacs-libregnum-attached-p)
               (ignore-errors (cmacs-libregnum-attached-p buf)))
      (let ((win (get-buffer-window buf t)))
        (when (window-live-p win)
          ;; Body size (text area), not window-pixel -- see `--fit-views'.
          (let ((w (window-body-width win t))
                (h (window-body-height win t)))
            (when (and (> w 1) (> h 1))
              (ignore-errors (cmacs-libregnum-resize buf w h)))))))))

(add-hook 'window-size-change-functions #'cmacs-libregnum--on-size-change)

(provide 'cmacs-libregnum)
;;; cmacs-libregnum.el ends here
