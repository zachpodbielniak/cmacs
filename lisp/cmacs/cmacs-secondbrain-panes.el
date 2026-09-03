;;; cmacs-secondbrain-panes.el --- inspector and preview panes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Two side panes beside the viewport:
;;
;;   +----------------+---------------------------+--------------+
;;   |                |                           |  inspector   |
;;   |    preview     |        viewport           +--------------+
;;   |                |                           |              |
;;   +----------------+---------------------------+--------------+
;;
;; The inspector is the card the reference design shows on click: name,
;; role, counts, path, buttons, and the node's connections.  The preview
;; renders the node's file inline, which is what makes a skill readable
;; without leaving the map -- the thing a graph view usually cannot do
;; and a file browser can.
;;
;; Both track which viewport they belong to rather than assuming the
;; canonical buffer name, so a second view does not steal the first
;; one's panes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar cmacs-secondbrain--selected)
(defvar cmacs-secondbrain--graph)
(defvar cmacs-secondbrain-buffer-name)

(declare-function cmacs-secondbrain-node-at "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-collapsed-p "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-node-count "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-visible-count "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-toggle-collapse "cmacs-secondbrain")
(declare-function cmacs-secondbrain-visit "cmacs-secondbrain")
(declare-function cmacs-secondbrain-copy-path "cmacs-secondbrain")
(declare-function cmacs-secondbrain-find-similar "cmacs-secondbrain-search")
(declare-function cmacs-libregnum-focus-node "cmacs-libregnum")

(defcustom cmacs-secondbrain-inspector-width 0.26
  "Width of the inspector pane, as a fraction of the frame."
  :type 'number
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-preview-width 0.30
  "Width of the preview pane, as a fraction of the frame."
  :type 'number
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-preview-max-bytes 40000
  "How much of a file the preview reads.

A cap, because the preview exists to let you read a skill without
leaving the map, not to be a second editor."
  :type 'integer
  :group 'cmacs-secondbrain)

(defface cmacs-secondbrain-heading-face '((t :inherit font-lock-keyword-face
                                             :weight bold))
  "Face for pane headings."
  :group 'cmacs-secondbrain)

(defface cmacs-secondbrain-label-face '((t :inherit font-lock-comment-face))
  "Face for field labels."
  :group 'cmacs-secondbrain)

;;;; Origin tracking --------------------------------------------------

(defvar-local cmacs-secondbrain--pane-origin nil
  "The viewport buffer this pane belongs to.")

(defvar-local cmacs-secondbrain--inspector-id nil
  "Id of the node the inspector is currently showing.")

(defun cmacs-secondbrain--origin ()
  "Return the viewport buffer this pane belongs to, or nil.

Called both from a pane (where the origin is recorded) and from the
viewport itself (where it is the current buffer).  Falling back to the
canonical buffer name alone would break a viewport that is not the one
named `cmacs-secondbrain-buffer-name'."
  (let ((b (cond ((derived-mode-p 'cmacs-secondbrain-mode) (current-buffer))
                 ((buffer-live-p cmacs-secondbrain--pane-origin)
                  cmacs-secondbrain--pane-origin)
                 (t (get-buffer cmacs-secondbrain-buffer-name)))))
    (and (buffer-live-p b) b)))

(defmacro cmacs-secondbrain--in-origin (&rest body)
  "Run BODY in the viewport buffer this pane belongs to."
  (declare (indent 0) (debug t))
  `(let ((origin (cmacs-secondbrain--origin)))
     (unless origin (user-error "No second-brain viewport"))
     (with-current-buffer origin ,@body)))

(defun cmacs-secondbrain--show-pane (buf side slot width)
  "Display BUF in a side window and return it."
  (display-buffer-in-side-window
   buf `((side . ,side) (slot . ,slot) (window-width . ,width)
         ;; Pin horizontally only, so stacked panes can still
         ;; redistribute height between themselves.
         (preserve-size . (t . nil)))))

;;;; Inspector actions (extension point) ------------------------------

(defvar cmacs-secondbrain-inspector-actions nil
  "Extra inspector actions, as (KEY LABEL FUNCTION &optional PREDICATE).
FUNCTION is called with the inspected node's id.")

(defvar cmacs-secondbrain-inspector-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-secondbrain-inspector-visit)
    (define-key m "O" #'cmacs-secondbrain-inspector-visit-other-window)
    (define-key m "f" #'cmacs-secondbrain-inspector-fly)
    (define-key m "y" #'cmacs-secondbrain-inspector-copy-path)
    (define-key m "x" #'cmacs-secondbrain-inspector-toggle-collapse)
    (define-key m "~" #'cmacs-secondbrain-inspector-similar)
    (define-key m "p" #'cmacs-secondbrain-preview)
    (define-key m "g" #'cmacs-secondbrain-inspector-refresh)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cmacs-secondbrain-inspector-mode'.")

(defun cmacs-secondbrain-register-inspector-action (key label fn &optional pred)
  "Add an inspector action bound to KEY, shown as LABEL, running FN.

FN receives the inspected node's id.  PRED, when given, decides whether
the action applies to a given id.

The binding is installed for Evil's normal and motion states as well --
without that half, a registered `a' would just be `evil-append' under
Doom, and the action would look registered while doing nothing."
  (setq cmacs-secondbrain-inspector-actions
        (cons (list key label fn pred)
              (assoc-delete-all key cmacs-secondbrain-inspector-actions)))
  (let ((cmd (lambda () (interactive)
               (when cmacs-secondbrain--inspector-id
                 (funcall fn cmacs-secondbrain--inspector-id)))))
    (define-key cmacs-secondbrain-inspector-mode-map (kbd key) cmd)
    (when (fboundp 'evil-define-key*)
      (evil-define-key* '(normal motion) cmacs-secondbrain-inspector-mode-map
        (kbd key) cmd))))

;;;; Inspector --------------------------------------------------------

(define-derived-mode cmacs-secondbrain-inspector-mode special-mode "SBInspect"
  "Details of the selected second-brain node.

\\{cmacs-secondbrain-inspector-mode-map}"
  (setq-local truncate-lines nil)
  (buffer-disable-undo))

(defun cmacs-secondbrain--insp-row (label value &optional face)
  "Insert a LABEL: VALUE row."
  (when (and value (not (equal value "")))
    (insert (propertize (format "%-12s" label) 'face 'cmacs-secondbrain-label-face)
            (if face (propertize (format "%s" value) 'face face)
              (format "%s" value))
            "\n")))

(defun cmacs-secondbrain--connections (id)
  "Return (INCOMING . OUTGOING) id lists for ID, from the collected graph."
  (let ((in nil) (out nil))
    (dolist (e (plist-get cmacs-secondbrain--graph :edges))
      (cond ((equal (plist-get e :from) id) (push (plist-get e :to) out))
            ((equal (plist-get e :to) id)   (push (plist-get e :from) in))))
    (cons (nreverse in) (nreverse out))))

(defun cmacs-secondbrain--title-of (origin id)
  "Return a display title for ID."
  (or (plist-get (cmacs-secondbrain-node-at origin id) :title) id))

(defun cmacs-secondbrain-inspector-render ()
  "Redraw the inspector from the origin viewport's selection."
  (let* ((origin (cmacs-secondbrain--origin))
         (id (and origin (buffer-local-value 'cmacs-secondbrain--selected origin)))
         (node (and id (cmacs-secondbrain-node-at origin id)))
         (buf (get-buffer-create "*second brain: inspector*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-secondbrain-inspector-mode)
        (cmacs-secondbrain-inspector-mode))
      (setq cmacs-secondbrain--pane-origin origin
            cmacs-secondbrain--inspector-id id)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (not node)
            (insert (propertize "Nothing selected\n"
                                'face 'cmacs-secondbrain-label-face)
                    "\nClick a node, or press "
                    (propertize "/" 'face 'help-key-binding) " to search.\n")
          (insert (propertize (cmacs-secondbrain--title-of origin id)
                              'face 'cmacs-secondbrain-heading-face)
                  "\n\n")
          (cmacs-secondbrain--insp-row "Role" (plist-get node :kind))
          (cmacs-secondbrain--insp-row "Ring" (plist-get node :ring))
          (cmacs-secondbrain--insp-row "Department" (plist-get node :department))
          (when (eq (plist-get node :kind) 'hub)
            (cmacs-secondbrain--insp-row
             "Folded" (if (cmacs-secondbrain-collapsed-p origin id) "yes" "no")))
          (cmacs-secondbrain--insp-row "Path" (plist-get node :file))
          (insert "\n")
          ;; Actions, shown as the keys that run them.  A button row you
          ;; cannot reach from the keyboard is a worse version of this.
          (insert (propertize "Actions\n" 'face 'cmacs-secondbrain-heading-face))
          (dolist (a `(("RET" . "open")
                       ("O"   . "open in other window")
                       ("p"   . "preview here")
                       ("y"   . "copy path")
                       ("x"   . "expand / collapse")
                       ("~"   . "find similar")
                       ("f"   . "fly to")))
            (insert "  " (propertize (car a) 'face 'help-key-binding)
                    "  " (cdr a) "\n"))
          (dolist (a cmacs-secondbrain-inspector-actions)
            (when (or (null (nth 3 a)) (funcall (nth 3 a) id))
              (insert "  " (propertize (nth 0 a) 'face 'help-key-binding)
                      "  " (nth 1 a) "\n")))
          (insert "\n")
          (let* ((conn (with-current-buffer origin
                         (cmacs-secondbrain--connections id)))
                 (in (car conn)) (out (cdr conn)))
            (insert (propertize (format "Connections (%d)\n" (+ (length in)
                                                                (length out)))
                                'face 'cmacs-secondbrain-heading-face))
            (if (and (null in) (null out))
                (insert (propertize "  none\n"
                                    'face 'cmacs-secondbrain-label-face))
              (dolist (o out)
                (insert "  → " (cmacs-secondbrain--title-of origin o) "\n"))
              (dolist (i in)
                (insert "  ← " (cmacs-secondbrain--title-of origin i) "\n")))))
        (goto-char (point-min)))
      (setq header-line-format
            (let ((o (cmacs-secondbrain--origin)))
              (when o
                (format " %s / %s nodes shown"
                        (or (cmacs-secondbrain-visible-count o) 0)
                        (or (cmacs-secondbrain-node-count o) 0))))))
    buf))

;;;###autoload
(defun cmacs-secondbrain-inspector ()
  "Show the inspector pane for the selected node."
  (interactive)
  (let ((buf (cmacs-secondbrain-inspector-render)))
    (cmacs-secondbrain--show-pane buf 'right 0
                                  cmacs-secondbrain-inspector-width)))

(defun cmacs-secondbrain-inspector-refresh ()
  "Redraw the inspector."
  (interactive)
  (cmacs-secondbrain-inspector-render))

(defun cmacs-secondbrain-inspector-visit ()
  "Open the inspected node's file."
  (interactive)
  (let ((id cmacs-secondbrain--inspector-id))
    (cmacs-secondbrain--in-origin
      (setq cmacs-secondbrain--selected id)
      (cmacs-secondbrain-visit))))

(defun cmacs-secondbrain-inspector-visit-other-window ()
  "Open the inspected node's file in another window."
  (interactive)
  (let ((id cmacs-secondbrain--inspector-id))
    (cmacs-secondbrain--in-origin
      (setq cmacs-secondbrain--selected id)
      (cmacs-secondbrain-visit t))))

(defun cmacs-secondbrain-inspector-copy-path ()
  "Copy the inspected node's path."
  (interactive)
  (let ((id cmacs-secondbrain--inspector-id))
    (cmacs-secondbrain--in-origin
      (setq cmacs-secondbrain--selected id)
      (cmacs-secondbrain-copy-path))))

(defun cmacs-secondbrain-inspector-toggle-collapse ()
  "Expand or collapse the inspected node."
  (interactive)
  (let ((id cmacs-secondbrain--inspector-id))
    (cmacs-secondbrain--in-origin
      (setq cmacs-secondbrain--selected id)
      (cmacs-secondbrain-toggle-collapse))
    (cmacs-secondbrain-inspector-render)))

(defun cmacs-secondbrain-inspector-similar ()
  "Highlight nodes similar to the inspected one."
  (interactive)
  (let ((id cmacs-secondbrain--inspector-id))
    (cmacs-secondbrain--in-origin (cmacs-secondbrain-find-similar id))))

(defun cmacs-secondbrain-inspector-fly ()
  "Move the camera to the inspected node."
  (interactive)
  (let ((id cmacs-secondbrain--inspector-id))
    (cmacs-secondbrain--in-origin
      (when (fboundp 'cmacs-libregnum-focus-node)
        (cmacs-libregnum-focus-node (current-buffer) id)))))

;;;; Preview ----------------------------------------------------------

(defvar cmacs-secondbrain-preview-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-secondbrain-preview-visit)
    (define-key m "g" #'cmacs-secondbrain-preview)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cmacs-secondbrain-preview-mode'.")

(define-derived-mode cmacs-secondbrain-preview-mode special-mode "SBPreview"
  "Inline preview of the selected node's file.

\\{cmacs-secondbrain-preview-mode-map}"
  (setq-local truncate-lines nil)
  (buffer-disable-undo))

(defvar-local cmacs-secondbrain--preview-file nil
  "File the preview is currently showing.")

;;;###autoload
(defun cmacs-secondbrain-preview ()
  "Preview the selected node's file beside the graph.

This is what makes a skill readable without leaving the map -- the thing
a graph view usually cannot do."
  (interactive)
  (let* ((origin (cmacs-secondbrain--origin))
         (id (and origin (buffer-local-value 'cmacs-secondbrain--selected origin)))
         (node (and id (cmacs-secondbrain-node-at origin id)))
         (file (plist-get node :file))
         (buf (get-buffer-create "*second brain: preview*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-secondbrain-preview-mode)
        (cmacs-secondbrain-preview-mode))
      (setq cmacs-secondbrain--pane-origin origin
            cmacs-secondbrain--preview-file file)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((not node)
          (insert (propertize "Nothing selected\n"
                              'face 'cmacs-secondbrain-label-face)))
         ((or (not file) (not (file-readable-p file)))
          (insert (propertize (format "%s\n\n" (or (plist-get node :title) id))
                              'face 'cmacs-secondbrain-heading-face)
                  (propertize "No file to preview.\n"
                              'face 'cmacs-secondbrain-label-face)
                  "\nApplications and routines are configuration, not documents.\n"))
         (t
          (insert-file-contents file nil 0 cmacs-secondbrain-preview-max-bytes)
          ;; Fontify as the file's own mode, then hand the buffer back to
          ;; the preview mode: `special-mode' keybindings on top of the
          ;; source language's colours.
          (let ((mode (ignore-errors
                        (assoc-default file auto-mode-alist #'string-match))))
            (when (and mode (fboundp mode))
              (delay-mode-hooks (funcall mode))
              (font-lock-ensure)
              (cmacs-secondbrain-preview-mode)
              (setq cmacs-secondbrain--pane-origin origin
                    cmacs-secondbrain--preview-file file)))))
        (goto-char (point-min)))
      (setq header-line-format
            (and file (abbreviate-file-name file))))
    (cmacs-secondbrain--show-pane buf 'left 0
                                  cmacs-secondbrain-preview-width)))

(defun cmacs-secondbrain-preview-visit ()
  "Open the previewed file properly."
  (interactive)
  (unless cmacs-secondbrain--preview-file (user-error "Nothing previewed"))
  (find-file cmacs-secondbrain--preview-file))

;;;; Closing ----------------------------------------------------------

;;;###autoload
(defun cmacs-secondbrain-close-panes ()
  "Close the inspector and preview panes."
  (interactive)
  (dolist (name '("*second brain: inspector*" "*second brain: preview*"))
    (when-let* ((b (get-buffer name))
                (w (get-buffer-window b)))
      (quit-window nil w))))

(provide 'cmacs-secondbrain-panes)

;;; cmacs-secondbrain-panes.el ends here
