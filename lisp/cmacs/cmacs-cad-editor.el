;;; cmacs-cad-editor.el --- CAD toolset for the libregnum editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The CAD experience EXTENDS the existing libregnum editor rather than
;; building a parallel viewport: parts render as CAD_PART nodes through
;; the editor's normal bake/blit pipeline, and this file plugs into the
;; editor's generic extension hooks:
;;
;;   `cmacs-libregnum-editor-palette-extra-sections'  -> "CAD" palette
;;   `cmacs-libregnum-inspector-extra-sections'       -> Params section
;;   `cmacs-libregnum-editor-select-functions'        -> panel sync
;;
;; The headline workflow is the *part workbench*
;; (`cmacs-cad-workbench', C-c C-v from a part buffer): the libregnum
;; editor opens on a scratch level holding one CAD_PART node that
;; references the part file; every successful re-evaluation of the
;; source buffer (C-c C-c / save) invalidates the CAD cache and
;; refreshes the scene -- edit text on the left, watch the solid
;; change on the right.

;;; Code:

(require 'cl-lib)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence
(require 'cmacs-cad)

(declare-function cmacs-libregnum-editor "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-palette "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-outliner "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-inspector "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-add-visual "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-refresh "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-cad-invalidate "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-focus "cmacs-libregnum-defuns.c")

;; Defined in cmacs-cad-crispy.el; bound lazily via `with-eval-after-load'.
(defvar cmacs-cad-crispy-mode-map)

(defconst cmacs-cad-editor-visual-cad-part 9
  "LRG_NODE_VISUAL_CAD_PART's enum value (appended after PREFAB_INSTANCE).")

(defvar-local cmacs-cad-editor--part-path nil
  "The part source path this editor buffer is a workbench for, or nil.")
(defvar-local cmacs-cad-editor--part-buffer nil
  "The part source buffer paired with this workbench, or nil.")
(defvar-local cmacs-cad-editor--node-id nil
  "The CAD_PART node id this editor buffer's workbench part lives at.")
(defvar-local cmacs-cad-editor--touched-params nil
  "Param names the user has edited in the inspector (their `cad:'
override is preserved across source re-evals; untouched params re-seed
to the new source default).")
(defvar-local cmacs-cad-editor--workbench nil
  "The workbench editor buffer paired with this part source buffer.")

(defun cmacs-cad-editor-available-p ()
  (and (cmacs-cad-available-p)
       (fboundp 'cmacs-libregnum-editor-add-visual)))

;;; The part workbench

;;;###autoload
(defun cmacs-cad-workbench ()
  "Open the libregnum editor as a workbench for this part buffer.
Creates (or reuses) an editor on a scratch level containing one
CAD_PART node referencing the file; source | viewport side by side,
with the palette, outliner and inspector panels.  Re-evaluating the
source (C-c C-c or save) refreshes the geometry live."
  (interactive)
  (unless (cmacs-cad-editor-available-p)
    (user-error "CAD workbench needs --with-cmacs-cad and --with-cmacs-libregnum"))
  (let* ((path (or (buffer-file-name)
                   (user-error "This part buffer is not visiting a file")))
         (part-buffer (current-buffer)))
    ;; Make sure the part parses before opening a viewport on it.
    (cmacs-cad-doc-open path)
    (if (buffer-live-p cmacs-cad-editor--workbench)
        (pop-to-buffer cmacs-cad-editor--workbench)
      (let ((editor (save-window-excursion (cmacs-libregnum-editor))))
        (with-current-buffer editor
          (setq cmacs-cad-editor--part-path path
                cmacs-cad-editor--part-buffer part-buffer)
          (let ((id (cmacs-libregnum-editor-add-visual
                     (current-buffer) cmacs-cad-editor-visual-cad-part path
                     (file-name-base path))))
            ;; Seed each param's `cad:' override to its source default so
            ;; the inspector edits + undo have a meaningful baseline (an
            ;; absent key would record a 0.0 "before").
            (when id
              (setq cmacs-cad-editor--node-id id)
              (cmacs-cad-editor--seed-overrides (current-buffer) id path))
            ;; Lit, shaded-with-edges display so the part reads with depth.
            (when (fboundp 'cmacs-cad-apply-view-style)
              (cmacs-cad-apply-view-style (current-buffer)))
            ;; add-visual bakes synchronously, so the node's bounds are
            ;; valid here and the camera can frame the part.
            (when (and id (fboundp 'cmacs-libregnum-editor-focus))
              (ignore-errors
                (cmacs-libregnum-editor-focus (current-buffer) id)))))
        (setq cmacs-cad-editor--workbench editor)
        ;; Layout: source left, viewport right; panels join via the
        ;; editor's own side-window commands.
        (delete-other-windows)
        (set-window-buffer (selected-window) part-buffer)
        (select-window (split-window-right))
        (switch-to-buffer editor)
        (with-current-buffer editor
          (cmacs-libregnum-editor-inspector))
        (cmacs-cad-feature-tree-panel part-buffer)
        (select-window (get-buffer-window part-buffer))))
    ;; Wire the live loop once per part buffer.
    (with-current-buffer part-buffer
      (add-hook 'cmacs-cad-after-eval-hook
                #'cmacs-cad-editor--after-eval nil t))))

(defun cmacs-cad-editor--after-eval ()
  "Refresh the paired workbench after a successful part evaluation.
The viewport bakes through libregnum's OWN document cache, so push
this buffer's (possibly unsaved) text into it before rebuilding --
otherwise the scene would show the on-disk file.  Params the user has
not touched re-seed to the new source defaults so source edits to a
defparam default take effect; manually-edited params keep their value."
  (let ((path (buffer-file-name))
        (editor cmacs-cad-editor--workbench))
    (when (and path (buffer-live-p editor)
               (fboundp 'cmacs-libregnum-cad-set-source))
      (cmacs-libregnum-cad-set-source
       path (buffer-substring-no-properties (point-min) (point-max)))
      (let ((id (buffer-local-value 'cmacs-cad-editor--node-id editor))
            (touched (buffer-local-value 'cmacs-cad-editor--touched-params
                                         editor)))
        (when (and (integerp id)
                   (fboundp 'cmacs-libregnum-editor-set-visual-param))
          (dolist (p (ignore-errors (cmacs-cad-params path)))
            (let ((name (plist-get p :name))
                  (def  (plist-get p :value)))
              (when (and name (numberp def) (not (member name touched)))
                (ignore-errors
                  (cmacs-libregnum-editor-set-visual-param
                   editor id (concat "cad:" name) def)))))))
      (cmacs-libregnum-editor-refresh editor)
      (cmacs-cad-feature-tree-refresh))))

(with-eval-after-load 'cmacs-cad
  (define-key cmacs-cad-mode-map (kbd "C-c C-v") #'cmacs-cad-workbench))
(with-eval-after-load 'cmacs-cad-crispy
  (define-key cmacs-cad-crispy-mode-map (kbd "C-c C-v")
              #'cmacs-cad-workbench))

;;; Palette section (via the generic extension hook)

(defun cmacs-cad-editor--palette-section ()
  "The \"CAD\" palette section, when the subsystem is available."
  (when (cmacs-cad-editor-available-p)
    (list
     '("CAD"
       ("New Part..."     fn cmacs-cad-editor--palette-new-part)
       ("Place Part..."   fn cmacs-cad-editor--palette-place-part)
       ("Import STL/STEP..." fn cmacs-cad-editor--palette-import-mesh)))))

(defun cmacs-cad-editor--palette-new-part (_name)
  "Create a new .cad file from a skeleton and place it as a node."
  (let ((path (read-file-name "New part file: " nil nil nil "part.cad")))
    (with-temp-file path
      (insert ";; " (file-name-nondirectory path) "\n"
              "(defparam size 10.0 :min 1 :max 100)\n\n"
              "(defpart " (file-name-base path) "\n"
              "  (box size size size))\n"))
    (cmacs-cad-editor--place path)))

(defun cmacs-cad-editor--palette-place-part (_name)
  "Place an existing part file as a CAD_PART node."
  (cmacs-cad-editor--place
   (read-file-name "Part file (.cad/.ccad): " nil nil t)))

(defun cmacs-cad-editor--palette-import-mesh (_name)
  "Import an STL/OBJ/STEP/IGES file as an editable CAD part.
Wraps the file in a sibling .cad part `(import \"file\")' so it renders
through the same CAD_PART bake path as native parts and can be combined,
drilled or measured immediately."
  (let* ((mesh (read-file-name "Import mesh/STEP (.stl/.obj/.step/.iges): "
                               nil nil t))
         (base (file-name-base mesh))
         (part (read-file-name "Wrapper part file: "
                               (file-name-directory mesh) nil nil
                               (concat base ".cad"))))
    (with-temp-file part
      (insert ";; " (file-name-nondirectory part)
              " -- imported from " (file-name-nondirectory mesh) "\n"
              "(defpart " (file-name-base part) "\n"
              "  (import \"" (file-relative-name
                              (expand-file-name mesh)
                              (file-name-directory (expand-file-name part)))
              "\"))\n"))
    (cmacs-cad-editor--place part)))

(defun cmacs-cad-editor--place (path)
  "Add PATH as a CAD_PART node to the current editor buffer."
  (cmacs-libregnum-editor-add-visual
   (current-buffer) cmacs-cad-editor-visual-cad-part
   (expand-file-name path) (file-name-base path)))

(add-hook 'cmacs-libregnum-editor-palette-extra-sections
          #'cmacs-cad-editor--palette-section)

;;; Inspector Params section (via the generic extension hook)

(declare-function cmacs-libregnum-editor-set-visual-param-undoable
                  "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-get-visual-param
                  "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-inspector-refresh "cmacs-libregnum")
(declare-function widget-create "wid-edit")
(declare-function widget-value "wid-edit")
(declare-function widget-insert "wid-edit")

(defun cmacs-cad-editor--seed-overrides (editor id path)
  "Set each of PATH's params as a `cad:NAME' override = its source default
on node ID, so inspector edits + undo have a real baseline (a node that
never had the key would otherwise record 0.0 as the pre-edit value).
These seeds re-bind to the same defaults, so geometry is unchanged."
  (when (fboundp 'cmacs-libregnum-editor-set-visual-param)
    (dolist (p (ignore-errors (cmacs-cad-params path)))
      (let ((name (plist-get p :name))
            (def  (plist-get p :value)))
        (when (and name (numberp def))
          (ignore-errors
            (cmacs-libregnum-editor-set-visual-param
             editor id (concat "cad:" name) def)))))))

(defun cmacs-cad-editor--param-current (editor id name default)
  "Current value of param NAME for node ID: the `cad:' override, else DEFAULT."
  (if (and (integerp id) (>= id 0)
           (fboundp 'cmacs-libregnum-editor-get-visual-param))
      (ignore-errors
        (cmacs-libregnum-editor-get-visual-param
         editor id (concat "cad:" name) default))
    default))

(defun cmacs-cad-editor--set-param (editor id name value min max merge)
  "Set param NAME to VALUE (clamped to [MIN,MAX]) on node ID as an
undoable `cad:' override, re-bake the viewport, and refresh the panels.
MERGE coalesces a continuing nudge sequence into one undo step."
  (let ((v value))
    (when (numberp min) (setq v (max v min)))
    (when (numberp max) (setq v (min v max)))
    ;; Remember that the user set this param, so a later source re-eval
    ;; does not clobber it back to the source default.
    (when (buffer-live-p editor)
      (with-current-buffer editor
        (cl-pushnew name cmacs-cad-editor--touched-params :test #'equal)))
    (when (fboundp 'cmacs-libregnum-editor-set-visual-param-undoable)
      (cmacs-libregnum-editor-set-visual-param-undoable
       editor id (concat "cad:" name) v merge))
    (when (fboundp 'cmacs-libregnum-editor-refresh)
      (ignore-errors (cmacs-libregnum-editor-refresh editor)))
    (cmacs-cad-feature-tree-refresh)
    ;; Rebuild the inspector to echo the new value, but DEFER it: we are
    ;; inside a widget's own callback, and rebuilding would delete that
    ;; widget out from under the widget machinery.
    (when (fboundp 'cmacs-libregnum-inspector-refresh)
      (run-at-time 0 nil
                   (lambda ()
                     (ignore-errors (cmacs-libregnum-inspector-refresh)))))
    v))

(defun cmacs-cad-editor--inspector-section (src id)
  "Insert the interactive CAD Params section when SRC is a CAD workbench.
Each `defparam' gets a live, undoable field + nudge buttons that set a
`cad:' override on the selected node and re-bake -- so parameters re-bind
without editing source.  Values are clamped to the param's declared range
so the override never fails the kernel's bounds check."
  (when (and (buffer-live-p src)
             (buffer-local-value 'cmacs-cad-editor--part-path src)
             (cmacs-cad-available-p))
    (let* ((path (buffer-local-value 'cmacs-cad-editor--part-path src))
           (params (ignore-errors (cmacs-cad-params path)))
           (have-node (and (integerp id) (>= id 0))))
      (when params
        (widget-insert (propertize "\nCAD Parameters\n" 'face 'bold))
        (if (not have-node)
            (progn
              (dolist (p params)
                (widget-insert
                 (format "  %-14s %8.3f\n" (plist-get p :name)
                         (plist-get p :value))))
              (widget-insert
               (propertize "  (select the part to edit parameters)\n"
                           'face 'shadow)))
          (dolist (p params)
            (let* ((name (plist-get p :name))
                   (mn   (plist-get p :min))
                   (mx   (plist-get p :max))
                   (def  (plist-get p :value))
                   (cur  (cmacs-cad-editor--param-current src id name def))
                   (step (if (and (numberp mn) (numberp mx) (> mx mn))
                             (/ (- mx mn) 20.0) 1.0)))
              (widget-insert (format "  %-14s " name))
              (widget-create
               'editable-field
               :size 8
               :value (format "%g" cur)
               :cad-name name :cad-min mn :cad-max mx
               :cad-step step :cad-editor src :cad-id id
               :action
               (lambda (w &rest _)
                 (cmacs-cad-editor--set-param
                  (widget-get w :cad-editor) (widget-get w :cad-id)
                  (widget-get w :cad-name)
                  (string-to-number (widget-value w))
                  (widget-get w :cad-min) (widget-get w :cad-max) nil)))
              (widget-insert " ")
              (widget-create
               'push-button
               :cad-name name :cad-min mn :cad-max mx :cad-step step
               :cad-editor src :cad-id id
               :notify
               (lambda (w &rest _)
                 (let ((nv (- (cmacs-cad-editor--param-current
                               (widget-get w :cad-editor)
                               (widget-get w :cad-id)
                               (widget-get w :cad-name) 0.0)
                              (widget-get w :cad-step))))
                   (cmacs-cad-editor--set-param
                    (widget-get w :cad-editor) (widget-get w :cad-id)
                    (widget-get w :cad-name) nv
                    (widget-get w :cad-min) (widget-get w :cad-max) nil)))
               "-")
              (widget-insert " ")
              (widget-create
               'push-button
               :cad-name name :cad-min mn :cad-max mx :cad-step step
               :cad-editor src :cad-id id
               :notify
               (lambda (w &rest _)
                 (let ((nv (+ (cmacs-cad-editor--param-current
                               (widget-get w :cad-editor)
                               (widget-get w :cad-id)
                               (widget-get w :cad-name) 0.0)
                              (widget-get w :cad-step))))
                   (cmacs-cad-editor--set-param
                    (widget-get w :cad-editor) (widget-get w :cad-id)
                    (widget-get w :cad-name) nv
                    (widget-get w :cad-min) (widget-get w :cad-max) nil)))
               "+")
              (when (and (numberp mn) (numberp mx))
                (widget-insert (format "   [%g..%g]" mn mx)))
              (widget-insert "\n")))
          (widget-insert
           (propertize "  RET in a field / -,+ nudge · undoable\n"
                       'face 'shadow)))))))

(add-hook 'cmacs-libregnum-inspector-extra-sections
          #'cmacs-cad-editor--inspector-section)

;;; Feature tree panel

(defvar cmacs-cad-feature-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-cad-feature-tree-visit)
    (define-key map [mouse-1]   #'cmacs-cad-feature-tree-visit)
    (define-key map (kbd "g")   #'cmacs-cad-feature-tree-refresh)
    map)
  "Keymap for `cmacs-cad-feature-tree-mode'.")

(define-derived-mode cmacs-cad-feature-tree-mode special-mode
  "cmacs-CAD-Tree"
  "Major mode for the CAD feature tree panel.")

;; Under Evil (Doom) `g' is a prefix and RET a motion, so neither reached
;; this panel.  Install the map as an Evil intercept map (see cmacs-evil.el).
(cmacs-evil-setup-mode-map cmacs-cad-feature-tree-mode-map
                           'cmacs-cad-feature-tree-mode)

(defvar-local cmacs-cad-tree--part-buffer nil)

(defun cmacs-cad-feature-tree-panel (&optional part-buffer)
  "Show the feature tree for PART-BUFFER (default: current) in a side window."
  (interactive)
  (let* ((part (or part-buffer (current-buffer)))
         (tree-buf (get-buffer-create "*cmacs-cad tree*")))
    (with-current-buffer tree-buf
      (cmacs-cad-feature-tree-mode)
      (setq cmacs-cad-tree--part-buffer part)
      (cmacs-cad-feature-tree--render))
    (display-buffer-in-side-window tree-buf '((side . right) (slot . 1)))))

(defun cmacs-cad-feature-tree-refresh ()
  "Rebuild the feature tree panel."
  (interactive)
  (let ((tree-buf (get-buffer "*cmacs-cad tree*")))
    (when (buffer-live-p tree-buf)
      (with-current-buffer tree-buf
        (cmacs-cad-feature-tree--render)))))

(defun cmacs-cad-feature-tree--render ()
  "Render the tree from the part buffer's document."
  (let* ((part cmacs-cad-tree--part-buffer)
         (path (and (buffer-live-p part)
                    (buffer-local-value 'buffer-file-name part)))
         (tree (and path (ignore-errors (cmacs-cad-feature-tree path))))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Feature tree  " 'face 'bold)
            (propertize "RET: jump to source · g: refresh\n\n"
                        'face 'shadow))
    (if (null tree)
        (insert (propertize "No evaluated part.\nC-c C-c in the source \
buffer first." 'face 'shadow))
      (cmacs-cad-feature-tree--insert tree 0))
    (goto-char (point-min))))

(defun cmacs-cad-feature-tree--insert (node depth)
  "Insert NODE at DEPTH, recursing over children."
  (let ((span (plist-get node :span))
        (label (plist-get node :label))
        (kind (plist-get node :kind)))
    (insert (make-string (* 2 depth) ?\s))
    (insert (propertize (format "%s" label)
                        'face (if (eq kind 'group) 'bold
                                'font-lock-function-name-face)
                        'cmacs-cad-span span
                        'mouse-face 'highlight
                        'help-echo "RET: jump to source"))
    (insert (propertize (format "  (%s)\n" kind) 'face 'shadow))
    (dolist (child (plist-get node :children))
      (cmacs-cad-feature-tree--insert child (1+ depth)))))

(defun cmacs-cad-feature-tree-visit ()
  "Jump to (and pulse) the source span of the feature at point."
  (interactive)
  (let ((span (get-text-property (line-beginning-position)
                                 'cmacs-cad-span))
        (part cmacs-cad-tree--part-buffer))
    (cond
     ((not (buffer-live-p part)) (user-error "Part buffer is gone"))
     ((null span) (user-error "This node has no source span"))
     (t
      (pop-to-buffer part)
      (goto-char (1+ (car span)))
      (when (fboundp 'pulse-momentary-highlight-region)
        (pulse-momentary-highlight-region (1+ (car span))
                                          (1+ (cdr span))))))))

;;; Panel sync on viewport selection

(defun cmacs-cad-editor--on-select (buffer _id)
  "Refresh CAD panels when the selection changes in a workbench BUFFER."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'cmacs-cad-editor--part-path buffer))
    (cmacs-cad-feature-tree-refresh)))

(add-hook 'cmacs-libregnum-editor-select-functions
          #'cmacs-cad-editor--on-select)

(provide 'cmacs-cad-editor)
;;; cmacs-cad-editor.el ends here
