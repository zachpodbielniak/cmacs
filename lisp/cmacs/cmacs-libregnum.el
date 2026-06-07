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
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-libregnum-mode 'emacs))
  ;; Keep Evil window management (C-w ...) usable even though scene buffers
  ;; sit in emacs state for their single-key navigation.
  (when (and (boundp 'evil-window-map) (keymapp evil-window-map))
    (define-key cmacs-libregnum-mode-map (kbd "C-w") evil-window-map)))

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
Drag with the left mouse button to orbit, scroll-wheel to zoom."
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
                  (buffer so-path))
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
(defun cmacs-libregnum-play (module)
  "Open a buffer hosting the libregnum game MODULE (a built game `.so').
The buffer renders the game and forwards keyboard and mouse input to it.
MODULE is a shared object built with `LRG_DEFINE_GAME_MODULE'."
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
      (cmacs-libregnum-load-game (current-buffer) abs)
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
          "[u]ndo [C-r]edo  [p]al [o]ut [i]nsp [A]ssets [L]ogic [f5]play "
          "[C-x C-s]save")
  "Header-line hint shown over the editor viewport (the window body is the
3D view, so on-screen affordances live in the header line until the native
panels land).")

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
  "Add a PRIM (LrgPrimitiveType int) primitive named NAME and select it."
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor-add-primitive buf prim name)))
    (setq cmacs-libregnum-editor--current id)
    (when id (message "Added %s (node %d)" name id))
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

(defun cmacs-libregnum-editor-add-script (language file)
  "Attach a LANGUAGE script FILE to the selected node (persisted in the level).
Wraps the `cmacs-libregnum-editor-attach-script' primitive."
  (interactive
   (list (completing-read "Language: " cmacs-libregnum-script-languages
                          nil t)
         (read-file-name "Script file: ")))
  (let* ((buf (cmacs-libregnum-editor--buffer))
         (id  (cmacs-libregnum-editor--sel buf))
         (lang (cdr (assoc language cmacs-libregnum-script-languages))))
    (cond
     ((null id) (user-error "No node selected"))
     ((null lang) (user-error "Unknown language: %s" language))
     (t (cmacs-libregnum-editor-attach-script buf id lang
                                              (expand-file-name file))
        (message "Attached %s script to node %d (%d total)" language id
                 (or (cmacs-libregnum-editor-node-script-count buf id) 0))))))

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

(defun cmacs-libregnum-editor--on-select (buffer id)
  "Sync editor BUFFER's selection to node ID picked in the viewport.
Called (deferred onto the cmacs context) from the C input layer after a
viewport click or drag, so the keyboard commands and outliner follow the
mouse."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cmacs-libregnum-editor--current
            (and (integerp id) (>= id 0) id)))
    (let ((out (get-buffer "*cmacs-libregnum outliner*")))
      (when (and out (integerp id) (>= id 0))
        (with-current-buffer out
          (when (eq cmacs-libregnum-editor--src-buffer buffer)
            (cmacs-libregnum-outliner--goto-id id)))))
    (let ((insp (get-buffer "*cmacs-libregnum inspector*")))
      (when (and insp (buffer-live-p insp))
        (with-current-buffer insp
          (when (eq cmacs-libregnum-editor--src-buffer buffer)
            (cmacs-libregnum-inspector--rebuild)))))))

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
                 (name (or (plist-get pl :name) "(node)"))
                 (depth (or (plist-get pl :depth) 0))
                 (id (plist-get pl :id)))
            (insert (propertize
                     (format "%s%s\n" (make-string (* 2 depth) ?\s) name)
                     'cmacs-libregnum-node-id id))))
        (goto-char (point-min))))
    (display-buffer-in-side-window out '((side . left) (slot . 1)))))

(defvar cmacs-libregnum-outliner-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-libregnum-outliner-select)
    (define-key map (kbd "g")   #'cmacs-libregnum-outliner-refresh)
    (define-key map (kbd "m")   #'cmacs-libregnum-outliner-mark)
    (define-key map (kbd "P")   #'cmacs-libregnum-outliner-reparent)
    (define-key map (kbd "r")   #'cmacs-libregnum-outliner-reparent-root)
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
      (message "Selected node %d" id))))

(defun cmacs-libregnum-outliner-refresh ()
  "Rebuild the outliner from its editor buffer."
  (interactive)
  (when (buffer-live-p cmacs-libregnum-editor--src-buffer)
    (with-current-buffer cmacs-libregnum-editor--src-buffer
      (cmacs-libregnum-editor-outliner))))

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
\(prompt for a file).")

(defvar cmacs-libregnum-palette-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")   #'cmacs-libregnum-palette-activate)
    (define-key map [mouse-1]     #'push-button)
    (define-key map (kbd "g")     #'cmacs-libregnum-palette-refresh)
    (define-key map (kbd "D")     #'cmacs-libregnum-palette-drop)
    (define-key map [drag-mouse-1] #'cmacs-libregnum-palette-drag)
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
      (with-current-buffer buffer (cmacs-libregnum-editor-outliner)))))

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
      (with-current-buffer buf
        (let ((id (pcase ptype
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
          (when id (cmacs-libregnum-editor-set-position buf id wx wy wz)))))))

(defun cmacs-libregnum-palette-drop ()
  "Arm the palette item on this line for drop-at-click in the viewport."
  (interactive)
  (let ((b (cmacs-libregnum-palette--button-on-line))
        (src cmacs-libregnum-editor--src-buffer))
    (if (or (null b) (not (buffer-live-p src)))
        (user-error "No item on this line")
      (cmacs-libregnum-editor--arm src (cmacs-libregnum-palette--thunk b)
                                   (button-get b 'name)))))

;;; True mouse drag: press a palette/asset item and release over the viewport
;;; to drop it at that 3D point.  This uses Emacs' own `drag-mouse-1' event
;;; (the drag is delivered to the START buffer's keymap with the release
;;; position), so NO upstream pgtk change is needed -- see the libregnum entry
;;; in `doc_org/cmacs/cmacs-upstream-changes.org'.

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
          ('sprite (call-interactively #'cmacs-libregnum-editor-add-sprite))))
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
        (dolist (section cmacs-libregnum-editor--palette)
          (insert (propertize (format "%s\n" (car section)) 'face 'bold))
          (dolist (item (cdr section))
            (let* ((label (nth 0 item))
                   (ptype (nth 1 item))
                   (vsym  (nth 2 item))
                   (value (and vsym (symbol-value vsym))))
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
          cmacs-libregnum-inspector--fields nil)
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
        (widget-insert "\n")
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
        (widget-setup)
        (goto-char (point-min))))))

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
      (message "Applied transform to node %d" id))))

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
    ;; The inspector is an editable widget form, so keep it in Emacs state.
    (evil-set-initial-state 'cmacs-libregnum-inspector-mode 'emacs))
  ;; In Motion state Evil's own RET/g/m shadow the major-mode map, so register
  ;; the activation keys in each mode's Motion-state overlay.  Use the FUNCTION
  ;; `evil-define-key*', never the `evil-define-key' MACRO: the macro only
  ;; expands at byte-compile time when Evil is already loaded; compiled without
  ;; Evil it is emitted as a runtime function call and signals "invalid
  ;; function: evil-define-key".  (`fboundp' is t for a macro too, so the old
  ;; guard did not catch it.)
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion cmacs-libregnum-palette-mode-map
      (kbd "RET")     #'cmacs-libregnum-palette-activate
      (kbd "D")       #'cmacs-libregnum-palette-drop
      [drag-mouse-1]  #'cmacs-libregnum-palette-drag)
    (evil-define-key* 'motion cmacs-libregnum-outliner-mode-map
      (kbd "RET") #'cmacs-libregnum-outliner-select
      (kbd "g")   #'cmacs-libregnum-outliner-refresh
      (kbd "m")   #'cmacs-libregnum-outliner-mark
      (kbd "P")   #'cmacs-libregnum-outliner-reparent
      (kbd "r")   #'cmacs-libregnum-outliner-reparent-root)
    (evil-define-key* 'motion cmacs-libregnum-assets-mode-map
      (kbd "RET") #'cmacs-libregnum-palette-activate
      (kbd "g")       #'cmacs-libregnum-assets-refresh
      (kbd "d")       #'cmacs-libregnum-editor-assets
      (kbd "D")       #'cmacs-libregnum-assets-drop
      [drag-mouse-1]  #'cmacs-libregnum-assets-drag)))

(provide 'cmacs-libregnum)
;;; cmacs-libregnum.el ends here
