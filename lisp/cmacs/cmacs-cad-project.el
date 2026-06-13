;;; cmacs-cad-project.el --- Project + git tooling for CAD parts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Project-aware tooling for parts: scaffolds (`cmacs-cad-new-part',
;; `cmacs-cad-new-project'), a part browser over the current project's
;; .cad/.ccad files (with async thumbnails cached by content hash), and
;; `cmacs-cad-diff' -- a git-revision diff that compares two versions of a
;; part by parameters and feature-tree structure (and, on a display,
;; side-by-side snapshots under identical framing).
;;
;; Uses project.el; projectile, if loaded, is registered as optional
;; sugar but never required.

;;; Code:

(require 'cl-lib)
(require 'project)

(declare-function cmacs-cad-doc-open "cmacs-cad-defuns.c")
(declare-function cmacs-cad-set-source "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-params "cmacs-cad-defuns.c")
(declare-function cmacs-cad-feature-tree "cmacs-cad-defuns.c")
(declare-function cmacs-cad-mcp-snapshot "cmacs-cad-mcp")

(defcustom cmacs-cad-thumb-dir
  (expand-file-name "cmacs-cad/thumbs/" (or (getenv "XDG_CACHE_HOME")
                                            "~/.cache"))
  "Directory for cached part thumbnails."
  :type 'directory :group 'cmacs-cad)

;;; Scaffolds

(defconst cmacs-cad-part-skeleton
  ";; %s -- a parametric part\n\
(defparam size 20.0 :min 1 :max 200)\n\n\
(defpart %s\n  (box size size size))\n"
  "Skeleton for a new .cad part (formatted with the file + part name).")

;;;###autoload
(defun cmacs-cad-new-part (path)
  "Create a new .cad part skeleton at PATH and open it."
  (interactive
   (list (read-file-name "New part: " nil nil nil "part.cad")))
  (let ((base (file-name-base path)))
    (when (or (not (file-exists-p path))
              (yes-or-no-p (format "%s exists; overwrite? " path)))
      (with-temp-file path
        (insert (format cmacs-cad-part-skeleton
                        (file-name-nondirectory path) base))))
    (find-file path)))

;;;###autoload
(defun cmacs-cad-new-project (dir)
  "Scaffold a new CAD project under DIR: a part, a README and .gitignore."
  (interactive (list (read-directory-name "New project dir: ")))
  (make-directory dir t)
  (let* ((name (file-name-nondirectory (directory-file-name dir)))
         (part (expand-file-name (concat name ".cad") dir)))
    (unless (file-exists-p part)
      (with-temp-file part
        (insert (format cmacs-cad-part-skeleton
                        (concat name ".cad") name))))
    (let ((gi (expand-file-name ".gitignore" dir)))
      (unless (file-exists-p gi)
        (with-temp-file gi
          (insert "# build artifacts\n*.stl\n*.gcode\n*.step\n"))))
    (let ((readme (expand-file-name "README.org" dir)))
      (unless (file-exists-p readme)
        (with-temp-file readme
          (insert (format "#+TITLE: %s\n\nA cmacs-cad project.\n" name)))))
    (find-file part)))

;;; Part browser

(defun cmacs-cad--project-parts ()
  "Return the .cad/.ccad files in the current project (or `default-directory')."
  (let ((root (if (project-current)
                  (project-root (project-current))
                default-directory)))
    (cl-remove-if-not
     (lambda (f) (string-match-p "\\.\\(c?cad\\)\\'" f))
     (ignore-errors
       (directory-files-recursively root "\\.\\(c?cad\\)\\'")))))

(defun cmacs-cad--thumb-path (part)
  "Return the cached thumbnail path for PART, keyed by content hash."
  (let ((hash (secure-hash 'sha1
                           (concat part ":"
                                   (if (file-readable-p part)
                                       (with-temp-buffer
                                         (insert-file-contents part)
                                         (buffer-string))
                                     "")))))
    (expand-file-name (concat hash ".png") cmacs-cad-thumb-dir)))

(defun cmacs-cad--ensure-thumb (part)
  "Return PART's thumbnail path, rendering it (graphical only) on a miss."
  (let ((thumb (cmacs-cad--thumb-path part)))
    (when (and (not (file-exists-p thumb)) (display-graphic-p)
               (fboundp 'cmacs-cad-mcp-snapshot))
      (make-directory cmacs-cad-thumb-dir t)
      (ignore-errors (cmacs-cad-mcp-snapshot part thumb)))
    (and (file-exists-p thumb) thumb)))

;;;###autoload
(defun cmacs-cad-part-browser ()
  "List the current project's CAD parts with thumbnails where available."
  (interactive)
  (let ((parts (cmacs-cad--project-parts))
        (buf (get-buffer-create "*cmacs-cad parts*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize "CAD parts\n\n" 'face 'bold))
        (if (null parts)
            (insert (propertize "(no .cad/.ccad files in this project)\n"
                                'face 'shadow))
          (dolist (part parts)
            (let ((thumb (cmacs-cad--ensure-thumb part)))
              (when (and thumb (display-graphic-p))
                (insert-image (create-image thumb nil nil :height 64))
                (insert " "))
              (insert-text-button
               (file-relative-name part default-directory)
               'action (lambda (_) (find-file part))
               'follow-link t)
              (insert "\n"))))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;; Git-revision diff

(defun cmacs-cad--git-show (rev path)
  "Return the contents of PATH at git REV, or signal."
  (let* ((root (or (and (project-current)
                        (project-root (project-current)))
                   default-directory))
         (rel (file-relative-name (expand-file-name path) root)))
    (with-temp-buffer
      (let ((default-directory root))
        (unless (= 0 (call-process "git" nil t nil "show"
                                   (format "%s:%s" rev rel)))
          (user-error "git show %s:%s failed" rev rel)))
      (buffer-string))))

(defun cmacs-cad--eval-source (source extension)
  "Eval SOURCE (a part in EXTENSION's language); return (PARAMS . TREE)."
  (let ((path (make-temp-file "cmacs-cad-diff" nil extension)))
    (unwind-protect
        (progn
          (with-temp-file path (insert source))
          (cmacs-cad-doc-open path)
          (cmacs-cad-eval path)
          (cons (cmacs-cad-params path) (cmacs-cad-feature-tree path)))
      (ignore-errors (delete-file path)))))

(defun cmacs-cad--tree-shape (node)
  "Return NODE's structural shape (labels + kinds, no coordinates)."
  (cons (list (plist-get node :label) (plist-get node :kind))
        (mapcar #'cmacs-cad--tree-shape (plist-get node :children))))

(defun cmacs-cad--param-diff (pa pb)
  "Return human lines describing parameter differences between PA and PB."
  (let (lines)
    (dolist (p pa)
      (let* ((name (plist-get p :name))
             (other (cl-find name pb
                             :key (lambda (q) (plist-get q :name))
                             :test #'equal)))
        (cond
         ((null other) (push (format "  - %s removed" name) lines))
         ((not (equal (plist-get p :value) (plist-get other :value)))
          (push (format "  ~ %s: %g -> %g" name
                        (plist-get p :value) (plist-get other :value))
                lines)))))
    (dolist (q pb)
      (unless (cl-find (plist-get q :name) pa
                       :key (lambda (p) (plist-get p :name)) :test #'equal)
        (push (format "  + %s added" (plist-get q :name)) lines)))
    (nreverse lines)))

;;;###autoload
(defun cmacs-cad-diff (rev-a &optional rev-b)
  "Diff the current part between git REV-A and REV-B (default working tree).
Compares parameters and feature-tree structure; on a display also shows
side-by-side snapshots."
  (interactive
   (list (read-string "Revision A: " "HEAD~1")
         (read-string "Revision B (blank = working tree): " "")))
  (let* ((path (or (buffer-file-name)
                   (user-error "Not visiting a part file")))
         (ext (concat "." (file-name-extension path)))
         (src-a (cmacs-cad--git-show rev-a path))
         (src-b (if (and rev-b (> (length rev-b) 0))
                    (cmacs-cad--git-show rev-b path)
                  (with-temp-buffer (insert-file-contents path)
                                    (buffer-string))))
         (a (cmacs-cad--eval-source src-a ext))
         (b (cmacs-cad--eval-source src-b ext))
         (pdiff (cmacs-cad--param-diff (car a) (car b)))
         (same-shape (equal (cmacs-cad--tree-shape (cdr a))
                            (cmacs-cad--tree-shape (cdr b))))
         (buf (get-buffer-create "*cmacs-cad diff*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (propertize (format "CAD diff  %s .. %s\n\n" rev-a
                                    (if (> (length rev-b) 0) rev-b
                                      "working tree"))
                            'face 'bold))
        (insert (propertize "Parameters\n" 'face 'bold))
        (if pdiff
            (insert (mapconcat #'identity pdiff "\n") "\n")
          (insert "  (no parameter changes)\n"))
        (insert (propertize "\nFeature tree\n" 'face 'bold))
        (insert (if same-shape
                    "  structurally identical\n"
                  "  STRUCTURE CHANGED\n"))
        (goto-char (point-min))))
    (pop-to-buffer buf)
    (list :param-diff pdiff :same-shape same-shape)))

(provide 'cmacs-cad-project)
;;; cmacs-cad-project.el ends here
