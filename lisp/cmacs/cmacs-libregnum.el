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
          (cmacs-libregnum-build-tree buffer root))))
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
      (cmacs-libregnum-build-tree (current-buffer) abs))
    (switch-to-buffer buf)
    buf))

(defvar-local cmacs-libregnum--scene-root nil
  "Absolute path of the project root for the current tree scene, if any.")

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

(provide 'cmacs-libregnum)
;;; cmacs-libregnum.el ends here
