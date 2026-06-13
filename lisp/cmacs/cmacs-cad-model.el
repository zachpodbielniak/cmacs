;;; cmacs-cad-model.el --- View STL/STEP/OBJ files through libregnum -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Visiting a mesh / B-rep file (.stl .obj .step .iges .3mf) opens it as a
;; rendered model in the libregnum editor, beside a small info panel
;; (format, triangle count, bounding box, watertightness).  The geometry
;; goes through cad-glib's importer + the CAD_PART bake path -- the same
;; one the workbench and the G-code viewer use -- so binary STL and B-rep
;; STEP both render with orbit / zoom / snapshot, with no raylib
;; file-loader involvement.

;;; Code:

(require 'cl-lib)
(require 'widget)
(require 'wid-edit)
(require 'cmacs-cad nil t)
(require 'cmacs-cad-slicer nil t)
(require 'cmacs-libregnum nil t)

(declare-function cmacs-libregnum-editor "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-add-visual "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-add-primitive "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-focus "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-delete "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-selected-id "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-select "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-scale "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-set-position "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-node-object "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-fit-window "cmacs-libregnum")
(declare-function cmacs-libregnum-supported-p "cmacs-libregnum")
(declare-function cmacs-cad-available-p "cmacs-cad")
(declare-function cmacs-cad-doc-open "cmacs-cad-defuns.c")
(declare-function cmacs-cad-eval "cmacs-cad-defuns.c")
(declare-function cmacs-cad-inspect "cmacs-cad-defuns.c")
(declare-function cmacs-cad-export "cmacs-cad-defuns.c")
(declare-function cmacs-cad-doc-close "cmacs-cad-defuns.c")
(declare-function cmacs-cad-slice "cmacs-cad-slicer")
(declare-function cmacs-cad-slicer-settings "cmacs-cad-slicer")
(declare-function gobject-set "cmacs-gobject")
(declare-function cmacs-cad-slicer-register "cmacs-cad-slicer")
(defvar cmacs-libregnum-primitive-plane)
(defvar cmacs-libregnum-editor-extra-menu-items)
(defvar cmacs-cad-slicer-supports)
(defvar cmacs-cad-slicer-support-style)
(defvar cmacs-cad-slicer-staging-dir)
(defvar cmacs-cad-slicer-layer-height)
(defvar cmacs-cad-slicer-first-layer-height)
(defvar cmacs-cad-slicer-infill)
(defvar cmacs-cad-slicer-perimeters)
(defvar cmacs-cad-slicer-brim-width)
(defvar cmacs-cad-slicer-prusa-program)

(defgroup cmacs-cad-model nil
  "Rendered STL/STEP/mesh viewing with a printer build plate."
  :group 'cmacs-cad)

(defcustom cmacs-cad-model-bed-x 250.0
  "Printer bed width (X) in millimetres for the build-plate plane."
  :type 'number :group 'cmacs-cad-model)

(defcustom cmacs-cad-model-bed-y 210.0
  "Printer bed depth (Y) in millimetres for the build-plate plane."
  :type 'number :group 'cmacs-cad-model)

(defcustom cmacs-cad-model-show-bed t
  "Whether to show the printer build-plate plane beneath the model."
  :type 'boolean :group 'cmacs-cad-model)

(defcustom cmacs-cad-model-orient-z-up t
  "Reorient imported models from Z-up (the STL / 3-D-printing convention)
to the viewer's Y-up, so a part stands upright on the bed instead of lying
on its side.  Disable for models already authored Y-up."
  :type 'boolean :group 'cmacs-cad-model)

(defcustom cmacs-cad-model-panel-width 42
  "Width in columns of the left settings/info panel (the viewport gets the
rest of the frame)."
  :type 'integer :group 'cmacs-cad-model)

(defvar-local cmacs-cad-model--widgets nil
  "On the info buffer: alist of (KEY . WIDGET) for the print-settings form.")

(defvar cmacs-cad-model--panel-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-buffer-map)
    (define-key map (kbd "TAB")       #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "n")         #'forward-button)
    (define-key map (kbd "p")         #'backward-button)
    (define-key map (kbd "C-c C-c")   #'cmacs-cad-model-apply-settings)
    (define-key map (kbd "C-c C-e")   #'cmacs-cad-model-export-gcode)
    (define-key map (kbd "i")         #'cmacs-cad-model-insert-file)
    (define-key map (kbd "x")         #'cmacs-cad-model-delete-selected)
    (define-key map (kbd "<delete>")  #'cmacs-cad-model-delete-selected)
    (define-key map (kbd "C-c C-k")   #'cmacs-cad-model--viewer-quit)
    (define-key map (kbd "q")         #'cmacs-cad-model--viewer-quit)
    map)
  "Keymap for the settings panel: button navigation + apply/export/insert.
Buttons themselves handle RET / mouse activation via `button-buffer-map'.")

(defconst cmacs-cad-model--visual-cad-part 9
  "LRG_NODE_VISUAL_CAD_PART (the import + CAD_PART bake render path).")

(defvar-local cmacs-cad-model--dir nil)
(defvar-local cmacs-cad-model--cad nil)
(defvar-local cmacs-cad-model--viewer nil)
(defvar-local cmacs-cad-model--bbox nil
  "On the info buffer: the model's (MINX MINY MINZ MAXX MAXY MAXZ) bbox.")
(defvar-local cmacs-cad-model--inspect nil
  "On the info buffer: the model's cad-glib inspect plist (triangles, …).")
(defvar-local cmacs-cad-model--next-x nil
  "On the info buffer: world X where the next inserted part's left edge goes,
so inserted parts line up in a row beside the model rather than overlap.")
(defvar-local cmacs-cad-model--part-id nil
  "On the editor buffer: the CAD_PART node id of the model.")
(defvar-local cmacs-cad-model--bed-id nil
  "On the editor buffer: the build-plate plane node id, or nil.")
(defvar-local cmacs-cad-model--info-buffer nil
  "On the editor buffer: the paired info buffer (for q/g from the viewport).")

(defun cmacs-cad-model--viewer-quit ()
  "Quit the model viewer (kills the info buffer, which cleans up the editor)."
  (interactive)
  (when (buffer-live-p cmacs-cad-model--info-buffer)
    ;; Editing settings fields marks this (file-visiting) buffer modified;
    ;; clear it so kill-buffer does not prompt (the file is never saved).
    (with-current-buffer cmacs-cad-model--info-buffer
      (set-buffer-modified-p nil))
    (kill-buffer cmacs-cad-model--info-buffer)))

(defun cmacs-cad-model--viewer-revert ()
  "Re-import the model from the viewport."
  (interactive)
  (when (buffer-live-p cmacs-cad-model--info-buffer)
    (with-current-buffer cmacs-cad-model--info-buffer
      (cmacs-cad-model-revert))))

(defvar cmacs-cad-model--viewport-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'cmacs-cad-toggle-edges)
    (define-key map (kbd "g") #'cmacs-cad-model--viewer-revert)
    (define-key map (kbd "G") #'cmacs-cad-model-export-gcode)
    (define-key map (kbd "S") #'cmacs-cad-slicer-settings)
    (define-key map (kbd "b") #'cmacs-cad-model-set-bed-size)
    (define-key map (kbd "B") #'cmacs-cad-model-toggle-bed)
    (define-key map (kbd "x")        #'cmacs-cad-model-delete-selected)
    (define-key map (kbd "<delete>") #'cmacs-cad-model-delete-selected)
    (define-key map (kbd "i") #'cmacs-cad-model-insert-file)
    (define-key map (kbd "q") #'cmacs-cad-model--viewer-quit)
    map)
  "Keys composed onto the editor buffer when it is a model viewport.
The viewport window is focused (so mouse orbit/pan work without a
pre-click), so these mirror the info-panel keys there.")

(defun cmacs-cad-model--available-p ()
  (and (display-graphic-p)
       (fboundp 'cmacs-libregnum-supported-p)
       (ignore-errors (cmacs-libregnum-supported-p))
       (fboundp 'cmacs-cad-available-p)
       (cmacs-cad-available-p)))

(defun cmacs-cad-model--write-importer (model)
  "Write a generated part that imports MODEL (absolute path); return its path."
  (setq cmacs-cad-model--dir (make-temp-file "cmacs-cad-model" t)
        cmacs-cad-model--cad (expand-file-name "view.cad"
                                               cmacs-cad-model--dir))
  (with-temp-file cmacs-cad-model--cad
    (let ((imp (format "(import %S)" (expand-file-name model))))
      (insert ";; generated viewer part\n"
              (format "(defpart imported %s)\n"
                      ;; Reorient Z-up (STL/print convention) to the viewer's
                      ;; Y-up so the part stands upright on the bed: a -90°
                      ;; turn about X maps +Z -> +Y.
                      (if cmacs-cad-model-orient-z-up
                          (format "(rotate (1 0 0) -90 %s)" imp)
                        imp)))))
  cmacs-cad-model--cad)

(defun cmacs-cad-model--info ()
  "Inspect the model and stash the result in `cmacs-cad-model--inspect' and
`cmacs-cad-model--bbox' (both buffer-local); return the inspect plist."
  (ignore-errors
    (cmacs-cad-eval cmacs-cad-model--cad)
    (prog1
        (let ((i (cmacs-cad-inspect cmacs-cad-model--cad)))
          (setq cmacs-cad-model--inspect i
                cmacs-cad-model--bbox (plist-get i :bbox))
          i)
      (ignore-errors (cmacs-cad-doc-close cmacs-cad-model--cad)))))

(defun cmacs-cad-model--cleanup ()
  (when (and cmacs-cad-model--dir (file-directory-p cmacs-cad-model--dir))
    (ignore-errors (delete-directory cmacs-cad-model--dir t)))
  (when (buffer-live-p cmacs-cad-model--viewer)
    (kill-buffer cmacs-cad-model--viewer)))

;;;; Printer build plate + slicing -------------------------------------------

(defun cmacs-cad-model--place-bed (editor bbox)
  "Add or refresh the printer build-plate plane in EDITOR beneath the model.
BBOX is (MINX MINY MINZ MAXX MAXY MAXZ) or nil.  The plate is a locked plane
sized to the configured bed footprint, sitting just under the model's lowest
point and centred on its XZ footprint.  Removes any previous plate first."
  (when (and (buffer-live-p editor)
             (fboundp 'cmacs-libregnum-editor-add-primitive)
             (boundp 'cmacs-libregnum-primitive-plane))
    (with-current-buffer editor
      (when (and cmacs-cad-model--bed-id
                 (fboundp 'cmacs-libregnum-editor-delete))
        (ignore-errors
          (cmacs-libregnum-editor-delete editor cmacs-cad-model--bed-id))
        (setq cmacs-cad-model--bed-id nil))
      (when cmacs-cad-model-show-bed
        (let* ((cx   (if bbox (/ (+ (nth 0 bbox) (nth 3 bbox)) 2.0) 0.0))
               (cz   (if bbox (/ (+ (nth 2 bbox) (nth 5 bbox)) 2.0) 0.0))
               (base (if bbox (float (nth 1 bbox)) 0.0))
               (id   (cmacs-libregnum-editor-add-primitive
                      editor cmacs-libregnum-primitive-plane "Printer Bed")))
          (when id
            (setq cmacs-cad-model--bed-id id)
            ;; The plane spans X and Z; scale to the bed footprint, flat in Y,
            ;; and drop it a hair below the model so they do not z-fight.
            (ignore-errors
              (cmacs-libregnum-editor-set-scale
               editor id cmacs-cad-model-bed-x 1.0 cmacs-cad-model-bed-y))
            (ignore-errors
              (cmacs-libregnum-editor-set-position
               editor id cx (- base 0.05) cz))
            ;; Lock it so orbit / move drags cannot grab the plate.
            (when (fboundp 'cmacs-libregnum-editor-node-object)
              (let ((obj (ignore-errors
                           (cmacs-libregnum-editor-node-object editor id))))
                (when (and obj (fboundp 'gobject-set))
                  (ignore-errors (gobject-set obj "locked" t)))))
            ;; Keep the model (not the plate) as the active selection.
            (when (and cmacs-cad-model--part-id
                       (fboundp 'cmacs-libregnum-editor-select))
              (ignore-errors
                (cmacs-libregnum-editor-select
                 editor cmacs-cad-model--part-id)))))))))

(defun cmacs-cad-model--context ()
  "Return (INFO EDITOR CAD BBOX) for the model viewer from any of its buffers.
Resolves whether the current buffer is the info panel or the editor; nil if
neither."
  (let ((info (cond ((local-variable-p 'cmacs-cad-model--cad) (current-buffer))
                    ((and (local-variable-p 'cmacs-cad-model--info-buffer)
                          (buffer-live-p cmacs-cad-model--info-buffer))
                     cmacs-cad-model--info-buffer))))
    (when (buffer-live-p info)
      (list info
            (buffer-local-value 'cmacs-cad-model--viewer info)
            (buffer-local-value 'cmacs-cad-model--cad info)
            (buffer-local-value 'cmacs-cad-model--bbox info)))))

(defun cmacs-cad-model-set-bed-size (x y)
  "Set the printer bed footprint to X by Y millimetres and refresh the plate."
  (interactive (list (read-number "Bed X (mm): " cmacs-cad-model-bed-x)
                     (read-number "Bed Y (mm): " cmacs-cad-model-bed-y)))
  (setq cmacs-cad-model-bed-x x
        cmacs-cad-model-bed-y y
        cmacs-cad-model-show-bed t)
  (cmacs-cad-model--refresh-viewport)
  (cmacs-cad-model--rerender)
  (message "Printer bed: %g × %g mm" x y))

(defun cmacs-cad-model-toggle-bed ()
  "Toggle the printer build-plate plane on or off."
  (interactive)
  (setq cmacs-cad-model-show-bed (not cmacs-cad-model-show-bed))
  (cmacs-cad-model--refresh-viewport)
  (cmacs-cad-model--rerender)
  (message "Printer bed %s" (if cmacs-cad-model-show-bed "shown" "hidden")))

(defun cmacs-cad-model-toggle-supports ()
  "Toggle support generation for slicing this model."
  (interactive)
  (require 'cmacs-cad-slicer nil t)
  (setq cmacs-cad-slicer-supports (not cmacs-cad-slicer-supports))
  (message "Supports %s%s" (if cmacs-cad-slicer-supports "on" "off")
           (if cmacs-cad-slicer-supports
               (format " (style: %s)" cmacs-cad-slicer-support-style) "")))

(defun cmacs-cad-model--set-support-style (style)
  "Enable supports and set their STYLE (`grid', `snug' or `organic')."
  (require 'cmacs-cad-slicer nil t)
  (setq cmacs-cad-slicer-support-style style
        cmacs-cad-slicer-supports t)
  (message "Supports on, style: %s" style))

(defun cmacs-cad-model-delete-selected ()
  "Delete the selected node in the model viewer's editor.
Works from either pane (the editor or the settings sidebar), unlike the
editor's own \"x\", which only works while the editor pane is focused."
  (interactive)
  (let* ((ctx (or (cmacs-cad-model--context) (user-error "Not in a model viewer")))
         (editor (nth 1 ctx)))
    (unless (buffer-live-p editor) (user-error "No model editor"))
    (let ((id (and (fboundp 'cmacs-libregnum-editor-selected-id)
                   (ignore-errors (cmacs-libregnum-editor-selected-id editor)))))
      (if (and id (>= id 0) (fboundp 'cmacs-libregnum-editor-delete))
          (progn
            (cmacs-libregnum-editor-delete editor id)
            (when (fboundp 'cmacs-libregnum-redraw)
              (ignore-errors (cmacs-libregnum-redraw editor)))
            (message "Deleted node %d" id))
        (user-error "No node selected — click a part in the viewport first")))))

(defun cmacs-cad-model-export-gcode ()
  "Slice the viewed model to G-code and open it in the toolpath viewer.
Uses the current slicer settings (layer height, infill, supports, …);
change them first with \\[cmacs-cad-slicer-settings]."
  (interactive)
  (let* ((ctx  (or (cmacs-cad-model--context)
                   (user-error "No CAD model in this buffer")))
         (info (nth 0 ctx))
         (model (buffer-local-value 'buffer-file-name info)))
    (unless (and model (fboundp 'cmacs-cad-slice))
      (user-error "CAD slicing is not available in this build"))
    (let* ((stage (file-name-as-directory
                   (expand-file-name cmacs-cad-slicer-staging-dir)))
           (base  (file-name-base model))
           (ext   (downcase (or (file-name-extension model) "")))
           (stl   (expand-file-name (concat base ".stl") stage))
           (sentinel
            (lambda (status out)
              (if (and (eq status 'done) (file-exists-p out))
                  (find-file out)
                (message "Slice failed — see the *cmacs-cad slice* buffer")))))
      (make-directory stage t)
      ;; CRITICAL: slice the model in its ORIGINAL orientation.  The viewer
      ;; bakes a Z-up->Y-up turn into its part for DISPLAY only; the slicer
      ;; reads STL in its own Z-up convention, so re-exporting the reoriented
      ;; viewer part would lay the print on its side.  For an STL input, copy
      ;; the file as-is (also puts it under the staging dir so a flatpak
      ;; slicer can read it).  For B-rep / other inputs, export through a
      ;; plain `import' (no display rotation).
      (if (string= ext "stl")
          (copy-file model stl t)
        (let ((xcad (expand-file-name (concat base "-export.cad") stage)))
          (unless (fboundp 'cmacs-cad-export)
            (user-error "CAD export is not available in this build"))
          (with-temp-file xcad
            (insert (format "(defpart imported (import %S))\n"
                            (expand-file-name model))))
          (cmacs-cad-eval xcad)
          (cmacs-cad-export xcad stl 'stl)
          (ignore-errors (cmacs-cad-doc-close xcad))))
      (message "Slicing %s…" base)
      (cmacs-cad-slice stl nil nil sentinel))))

(defvar cmacs-cad-model--support-menu-items
  `((:label "Toggle supports" :kinds t
            :action ,(lambda (_b _i) (cmacs-cad-model-toggle-supports)))
    (:sep)
    (:label "Style: Grid (classic)" :kinds t
            :action ,(lambda (_b _i) (cmacs-cad-model--set-support-style 'grid)))
    (:label "Style: Snug" :kinds t
            :action ,(lambda (_b _i) (cmacs-cad-model--set-support-style 'snug)))
    (:label "Style: Organic / tree" :kinds t
            :action ,(lambda (_b _i)
                       (cmacs-cad-model--set-support-style 'organic))))
  "\"Supports\" submenu for the model viewer's right-click menu.")

;;;; Inserting more models -----------------------------------------------------

(defconst cmacs-cad-model--ext-re
  "\\.\\(stl\\|obj\\|step\\|stp\\|iges\\|igs\\|3mf\\)\\'"
  "Regexp matching mesh / B-rep file extensions the viewer can import.")

(defun cmacs-cad-model--add-part (editor file)
  "Import FILE as an additional CAD_PART node in EDITOR (Z-up reoriented).
Places the part *on* the build plate (its base lifted to the plate level so
it can NEVER end up under the plate) and offset to the +X side of existing
parts (a row), so when the plate is full it spills off the edge rather than
underneath.  Returns the new node id, or nil."
  (let* ((info (car (cmacs-cad-model--context)))
         (pbb  (and info (buffer-local-value 'cmacs-cad-model--bbox info)))
         (plate-y (if pbb (float (nth 1 pbb)) 0.0))   ; build-plate Y level
         (dir  (or (and info (buffer-local-value 'cmacs-cad-model--dir info)
                        (file-directory-p
                         (buffer-local-value 'cmacs-cad-model--dir info))
                        (buffer-local-value 'cmacs-cad-model--dir info))
                   (make-temp-file "cmacs-cad-model" t)))
         (cad  (expand-file-name
                (format "insert-%x.cad" (sxhash (expand-file-name file))) dir)))
    (with-temp-file cad
      (let ((imp (format "(import %S)" (expand-file-name file))))
        (insert (format "(defpart imported %s)\n"
                        (if cmacs-cad-model-orient-z-up
                            (format "(rotate (1 0 0) -90 %s)" imp)
                          imp)))))
    ;; Inspect the inserted geometry (already reoriented) for its own bbox so
    ;; we can sit it on the plate and beside the others.
    (let ((ibb (ignore-errors
                 (cmacs-cad-eval cad)
                 (prog1 (plist-get (cmacs-cad-inspect cad) :bbox)
                   (ignore-errors (cmacs-cad-doc-close cad))))))
      (when (fboundp 'cmacs-libregnum-editor-add-visual)
        (let ((id (cmacs-libregnum-editor-add-visual
                   editor cmacs-cad-model--visual-cad-part cad
                   (file-name-base file))))
          (when (and id ibb (fboundp 'cmacs-libregnum-editor-set-position))
            (let* ((mnx (nth 0 ibb)) (mny (nth 1 ibb)) (mnz (nth 2 ibb))
                   (mxx (nth 3 ibb)) (mxz (nth 5 ibb))
                   (width (- mxx mnx))
                   (gap   (max 10.0 (* 0.15 (if pbb (- (nth 3 pbb) (nth 0 pbb))
                                              width))))
                   ;; left edge of the next free slot, in world X
                   (nx    (or (and info (buffer-local-value
                                         'cmacs-cad-model--next-x info))
                              (if pbb (+ (float (nth 3 pbb)) gap) gap)))
                   ;; node location = where to put model-origin so the part
                   ;; lands base-on-plate, left edge at NX, centred in Z on
                   ;; the primary (NEVER below PLATE-Y).
                   (loc-x (- nx mnx))
                   (loc-y (- plate-y mny))
                   (loc-z (if pbb
                              (- (/ (+ (nth 2 pbb) (nth 5 pbb)) 2.0)
                                 (/ (+ mnz mxz) 2.0))
                            (- (/ (+ mnz mxz) 2.0)))))
              (ignore-errors
                (cmacs-libregnum-editor-set-position editor id loc-x loc-y loc-z))
              (when info
                (with-current-buffer info
                  (setq cmacs-cad-model--next-x (+ nx width gap))))))
          (when (fboundp 'cmacs-cad-apply-view-style)
            (ignore-errors (cmacs-cad-apply-view-style editor)))
          (when (fboundp 'cmacs-libregnum-redraw)
            (ignore-errors (cmacs-libregnum-redraw editor)))
          id)))))

(defun cmacs-cad-model-insert-file (file)
  "Insert another mesh / B-rep FILE into the current model editor as a part.
The new part is reoriented and placed alongside the existing geometry; move
it with the gizmo (w) or drag.  Also reachable by dropping a file on the
viewport and from the right-click Insert menu."
  (interactive
   (list (read-file-name
          "Insert model: " nil nil t nil
          (lambda (n) (or (file-directory-p n)
                          (string-match-p cmacs-cad-model--ext-re n))))))
  (let* ((ctx (or (cmacs-cad-model--context)
                  (user-error "Not in a model viewer")))
         (editor (nth 1 ctx)))
    (unless (buffer-live-p editor)
      (user-error "No model editor to insert into"))
    (if (cmacs-cad-model--add-part editor file)
        (message "Inserted %s" (file-name-nondirectory file))
      (user-error "Could not insert %s" (file-name-nondirectory file)))))

(defun cmacs-cad-model--insert-by-ext (exts)
  "Prompt for a model file restricted to EXTS, then insert it."
  (let* ((re (concat "\\.\\(" (mapconcat #'regexp-quote exts "\\|") "\\)\\'"))
         (file (read-file-name "Insert model: " nil nil t nil
                               (lambda (n) (or (file-directory-p n)
                                               (string-match-p re n))))))
    (cmacs-cad-model-insert-file file)))

(defvar cmacs-cad-model--insert-menu-items
  `((:label "STL / OBJ / 3MF mesh…" :kinds t
            :action ,(lambda (_b _i)
                       (cmacs-cad-model--insert-by-ext '("stl" "obj" "3mf"))))
    (:label "STEP / IGES (B-rep)…" :kinds t
            :action ,(lambda (_b _i)
                       (cmacs-cad-model--insert-by-ext
                        '("step" "stp" "iges" "igs"))))
    (:label "Any model file…" :kinds t
            :action ,(lambda (_b _i)
                       (call-interactively #'cmacs-cad-model-insert-file))))
  "\"Insert\" submenu: add another model to the viewer's scene.")

(defvar cmacs-cad-model--print-menu-items
  `((:sep)
    (:label "Insert" :kinds t :submenu cmacs-cad-model--insert-menu-items)
    (:label "Export G-code…" :kinds t
            :action ,(lambda (_b _i) (cmacs-cad-model-export-gcode)))
    (:label "Slicer settings…" :kinds t
            :action ,(lambda (_b _i) (cmacs-cad-slicer-settings)))
    (:label "Supports" :kinds t :submenu cmacs-cad-model--support-menu-items)
    (:sep)
    (:label "Set bed size…" :kinds t
            :action ,(lambda (_b _i)
                       (call-interactively #'cmacs-cad-model-set-bed-size)))
    (:label "Toggle bed" :kinds t
            :action ,(lambda (_b _i) (cmacs-cad-model-toggle-bed))))
  "Print/slice actions appended to the model viewer's right-click menu.
Duplicate / Rotate / Scale / Cut / Copy come from the editor's built-in
menu; these add the printing + insert workflow on top.")

;;;; Settings panel (left sidebar; C-c C-c applies) ---------------------------

(defun cmacs-cad-model--rerender ()
  "Re-render the settings panel in the model viewer's info buffer."
  (let ((info (car (cmacs-cad-model--context))))
    (when (buffer-live-p info)
      (with-current-buffer info (cmacs-cad-model--render-panel)))))

(defun cmacs-cad-model--refresh-viewport ()
  "Re-place the build plate and force the editor window to repaint NOW.
The view renders on the GLib clock, so when the editor is not the selected
window a settings change updates the scene but the on-screen blit lags;
forcing a window update (now and again after the next render tick) blits the
fresh surface."
  (let* ((ctx (cmacs-cad-model--context))
         (editor (nth 1 ctx)))
    (when (buffer-live-p editor)
      (cmacs-cad-model--place-bed editor (nth 3 ctx))
      (when (fboundp 'cmacs-libregnum-redraw)
        (ignore-errors (cmacs-libregnum-redraw editor)))
      (let ((w (get-buffer-window editor t)))
        (when (window-live-p w)
          (force-window-update w)
          (run-with-timer 0.1 nil
                          (lambda () (when (window-live-p w)
                                       (force-window-update w)))))))))

(defun cmacs-cad-model--num-button (var prompt)
  "Return a closure that prompts (PROMPT) for a number into VAR and re-renders."
  (lambda ()
    (set var (read-number (concat prompt ": ") (symbol-value var)))
    (cmacs-cad-model--rerender)))

(defun cmacs-cad-model--row (label value action &optional help)
  "Insert a settings row: LABEL, then a clickable button showing VALUE."
  (insert (format "  %-12s" label))
  (insert-text-button (format "[%s]" value)
                      'action (lambda (_) (funcall action))
                      'follow-link t
                      'help-echo (or help "Click or RET to change"))
  (insert "\n"))

(defun cmacs-cad-model--render-panel (&rest _)
  "Render the model info + a clickable print-settings panel into the current
\(info) buffer.  Each value is a button: click or RET to change it; the change
applies immediately."
  (require 'cmacs-cad-slicer nil t)
  (let* ((model (or (buffer-file-name) "model"))
         (i  cmacs-cad-model--inspect)
         (bb cmacs-cad-model--bbox)
         (inhibit-read-only t))
    (erase-buffer)
    (remove-overlays)
    (insert (propertize (format "%s\n" (file-name-nondirectory model))
                        'face 'bold))
    (insert (propertize (format "%s\n\n"
                                (upcase (or (file-name-extension model) "?")))
                        'face 'shadow))
    ;; Model facts, one per line so they stay readable in the narrow panel.
    (if (null i)
        (insert (propertize "(could not import — unsupported or malformed)\n"
                            'face 'error))
      (insert (format "%s triangles\n" (or (plist-get i :triangles) "?")))
      (insert (format "watertight: %s\n"
                      (if (plist-get i :watertight) "yes" "no")))
      (when bb
        (insert (format "size: %.1f × %.1f × %.1f mm\n"
                        (- (nth 3 bb) (nth 0 bb))
                        (- (nth 4 bb) (nth 1 bb))
                        (- (nth 5 bb) (nth 2 bb))))))
    (insert "\n")
    (insert (propertize "Print settings" 'face 'bold))
    (insert (propertize "  (click a value)\n\n" 'face 'shadow))
    ;; Build plate (affects the viewport immediately).
    (cmacs-cad-model--row
     "Bed X" (format "%g mm" cmacs-cad-model-bed-x)
     (lambda () (call-interactively #'cmacs-cad-model-set-bed-size)))
    (cmacs-cad-model--row
     "Bed Y" (format "%g mm" cmacs-cad-model-bed-y)
     (lambda () (call-interactively #'cmacs-cad-model-set-bed-size)))
    (cmacs-cad-model--row
     "Build plate" (if cmacs-cad-model-show-bed "shown" "hidden")
     (lambda () (cmacs-cad-model-toggle-bed)))
    (insert "\n")
    ;; Slicer settings (used on export).
    (cmacs-cad-model--row
     "Layer" (format "%g mm" cmacs-cad-slicer-layer-height)
     (cmacs-cad-model--num-button 'cmacs-cad-slicer-layer-height
                                  "Layer height (mm)"))
    (cmacs-cad-model--row
     "First layer" (format "%g mm" cmacs-cad-slicer-first-layer-height)
     (cmacs-cad-model--num-button 'cmacs-cad-slicer-first-layer-height
                                  "First-layer height (mm)"))
    (cmacs-cad-model--row
     "Infill" (format "%d %%" cmacs-cad-slicer-infill)
     (lambda ()
       (setq cmacs-cad-slicer-infill
             (round (read-number "Infill (%): " cmacs-cad-slicer-infill)))
       (cmacs-cad-model--rerender)))
    (cmacs-cad-model--row
     "Walls" (format "%d" cmacs-cad-slicer-perimeters)
     (lambda ()
       (setq cmacs-cad-slicer-perimeters
             (round (read-number "Perimeters: " cmacs-cad-slicer-perimeters)))
       (cmacs-cad-model--rerender)))
    (cmacs-cad-model--row
     "Supports" (if cmacs-cad-slicer-supports "on" "off")
     (lambda ()
       (setq cmacs-cad-slicer-supports (not cmacs-cad-slicer-supports))
       (cmacs-cad-model--rerender)))
    (cmacs-cad-model--row
     "Style" (symbol-name cmacs-cad-slicer-support-style)
     (lambda ()
       (setq cmacs-cad-slicer-support-style
             (intern (completing-read "Support style: "
                                      '("grid" "snug" "organic") nil t))
             cmacs-cad-slicer-supports t)
       (cmacs-cad-model--rerender)))
    (cmacs-cad-model--row
     "Brim" (format "%g mm" cmacs-cad-slicer-brim-width)
     (cmacs-cad-model--num-button 'cmacs-cad-slicer-brim-width "Brim (mm)"))
    (cmacs-cad-model--row
     "Slicer" (if (and (stringp cmacs-cad-slicer-prusa-program)
                       (> (length cmacs-cad-slicer-prusa-program) 0))
                  cmacs-cad-slicer-prusa-program "auto")
     (lambda ()
       (let ((s (string-trim
                 (read-string "Slicer program (blank = auto): "
                              (and (stringp cmacs-cad-slicer-prusa-program)
                                   cmacs-cad-slicer-prusa-program)))))
         (setq cmacs-cad-slicer-prusa-program (and (> (length s) 0) s)))
       (cmacs-cad-model--rerender)))
    (insert "\n  ")
    (insert-text-button "[ Export G-code ]" 'follow-link t
                        'action (lambda (_) (cmacs-cad-model-export-gcode)))
    (insert "\n  ")
    (insert-text-button "[ Add STL… ]" 'follow-link t
                        'action (lambda (_)
                                  (call-interactively
                                   #'cmacs-cad-model-insert-file)))
    (insert "   ")
    (insert-text-button "[ Reload ]" 'follow-link t
                        'action (lambda (_) (cmacs-cad-model--viewer-revert)))
    (insert "\n")
    (use-local-map cmacs-cad-model--panel-map)
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)
    (goto-char (point-min))))

(defun cmacs-cad-model-apply-settings ()
  "Re-sync the viewport (bed) from the current settings and repaint (C-c C-c).
Settings apply immediately when clicked; this is a manual refresh."
  (interactive)
  (cmacs-cad-model--refresh-viewport)
  (cmacs-cad-model--rerender)
  (message "Bed %g×%g mm · %g mm layers · %d%% infill · supports %s"
           cmacs-cad-model-bed-x cmacs-cad-model-bed-y
           cmacs-cad-slicer-layer-height cmacs-cad-slicer-infill
           (if cmacs-cad-slicer-supports
               (format "on (%s)" cmacs-cad-slicer-support-style) "off")))

(defun cmacs-cad-model--existing-viewer ()
  "Return (INFO . EDITOR) of an already-open model viewer (other than the
current buffer) whose editor is live, or nil.  The libregnum editor is a
singleton, so a second viewer would clobber the first; we add to the
existing one instead."
  (catch 'found
    (dolist (b (buffer-list))
      (when (and (not (eq b (current-buffer)))
                 (buffer-local-value 'cmacs-cad-model--cad b))
        (let ((ed (buffer-local-value 'cmacs-cad-model--viewer b)))
          (when (buffer-live-p ed)
            (throw 'found (cons b ed))))))
    nil))

(defun cmacs-cad-model--layout (info editor)
  "Lay out INFO as a narrow sidebar and EDITOR as the viewport, side by side.
Leaves the viewport window selected."
  (when (and (buffer-live-p info) (buffer-live-p editor))
    (delete-other-windows)
    (set-window-buffer (selected-window) info)
    (let ((info-win (selected-window))
          (ed-win (split-window-right)))
      (set-window-buffer ed-win editor)
      (let ((delta (- cmacs-cad-model-panel-width
                      (window-total-width info-win))))
        (unless (zerop delta)
          (ignore-errors (window-resize info-win delta t))))
      (select-window ed-win))))

(defun cmacs-cad-model--settle-camera (editor)
  "After the lazy bake, fit EDITOR's FBO to its window and frame the part.
The CAD_PART is baked on the first render, so this waits (with a couple of
retries): a synchronous resize before the first paint can fail to allocate
the render target, and focusing before the bake frames the origin, leaving
an off-origin model out of view."
  (let ((tries 0))
    (cl-labels
        ((settle ()
           (setq tries (1+ tries))
           (when (buffer-live-p editor)
             (when (fboundp 'cmacs-libregnum-fit-window)
               (ignore-errors (cmacs-libregnum-fit-window editor)))
             (let ((pid (buffer-local-value 'cmacs-cad-model--part-id editor)))
               (when (and pid (fboundp 'cmacs-libregnum-editor-focus))
                 (ignore-errors (cmacs-libregnum-editor-focus editor pid))))
             (when (< tries 3)
               (run-with-idle-timer 0.2 nil #'settle)))))
      (run-with-idle-timer 0.2 nil #'settle))))

(defun cmacs-cad-model--open ()
  "Render the model in the libregnum viewer.
If a model viewer is already open, add this model to it (the libregnum
editor is a singleton -- a second viewer would clobber the first) and drop
this redundant file buffer; otherwise set up a fresh viewer."
  (let ((existing (cmacs-cad-model--existing-viewer))
        (model    (buffer-file-name))
        (this-buf (current-buffer)))
    (cond
     ;; A completion/preview session (file picker) is transiently *visiting*
     ;; this file to preview it -- a minibuffer is still active.  Do NOTHING:
     ;; never add or open a model from a preview, only from a committed
     ;; visit.  Otherwise navigating the "Add STL" picker would insert every
     ;; file the cursor lands on, and the chosen one twice.  The explicit add
     ;; runs via `cmacs-cad-model-insert-file' on RET, not here.
     ((and existing (active-minibuffer-window)) nil)
     ;; A viewer is already open: add this model to it (the libregnum editor
     ;; is a singleton -- a second viewer would clobber the first) and drop
     ;; this redundant file buffer.
     ((and existing model)
      (let ((existing-info (car existing))
            (editor        (cdr existing)))
        (with-current-buffer existing-info
          (cmacs-cad-model--add-part editor model))
        (cmacs-cad-model--layout existing-info editor)
        (cmacs-cad-model--settle-camera editor)
        (message "Added %s to the open model viewer"
                 (file-name-nondirectory model))
        ;; This freshly-visited .stl buffer is redundant now; drop it.  Its
        ;; own --viewer/--dir are unset (we never ran --write-importer), so
        ;; its kill-hook cleanup does not touch the shared editor.
        (run-with-timer
         0 nil
         (lambda ()
           (when (and (buffer-live-p this-buf)
                      (not (eq this-buf existing-info)))
             (with-current-buffer this-buf (set-buffer-modified-p nil))
             (kill-buffer this-buf))))))
     (t (cmacs-cad-model--open-fresh)))))

(defun cmacs-cad-model--open-fresh ()
  "Open the libregnum editor on the imported model beside this info buffer."
  (let* ((info-buf (current-buffer))
         (model (buffer-file-name))
         (name (file-name-base model)))
    (cmacs-cad-model--write-importer model)
    ;; Left sidebar: model facts + the clickable print-settings panel.  (The
    ;; file buffer itself is binary; we never save it.)
    (cmacs-cad-model--info)            ; populates --inspect / --bbox
    (cmacs-cad-model--render-panel)
    (set-buffer-modified-p nil)
    (let ((editor (save-window-excursion (cmacs-libregnum-editor))))
      (with-current-buffer info-buf (setq cmacs-cad-model--viewer editor))
      (let ((id (cmacs-libregnum-editor-add-visual
                 editor cmacs-cad-model--visual-cad-part
                 cmacs-cad-model--cad name)))
        (with-current-buffer editor (setq cmacs-cad-model--part-id id))
        (when (fboundp 'cmacs-cad-apply-view-style)
          (cmacs-cad-apply-view-style editor)))
      ;; NB: the camera is framed on the part in the deferred timer below,
      ;; NOT here.  The CAD_PART is baked lazily on the first render, so at
      ;; this point its AABB is unknown and `editor-focus' would frame the
      ;; origin -- leaving an off-origin model entirely out of view (a black
      ;; viewport).  Focus after the bake instead.
      ;; Compose the viewport keys onto the editor, append the print actions
      ;; to its right-click menu, and remember the info buffer.  Then FOCUS
      ;; the editor window: mouse orbit/pan only route to a libregnum view
      ;; when its window is selected, so a viewer that left the info buffer
      ;; focused made right-drag fall through to Emacs (a context-menu, not a
      ;; rotate).
      (with-current-buffer editor
        (setq cmacs-cad-model--info-buffer info-buf)
        (when (boundp 'cmacs-libregnum-editor-extra-menu-items)
          (setq-local cmacs-libregnum-editor-extra-menu-items
                      cmacs-cad-model--print-menu-items))
        (use-local-map (make-composed-keymap cmacs-cad-model--viewport-map
                                              (current-local-map))))
      ;; Printer build plate beneath the model.
      (cmacs-cad-model--place-bed
       editor (buffer-local-value 'cmacs-cad-model--bbox info-buf))
      (cmacs-cad-model--layout info-buf editor)
      (cmacs-cad-model--settle-camera editor))))

(declare-function cmacs-cad-toggle-edges "cmacs-cad")

(defvar cmacs-cad-model-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'cmacs-cad-model-revert)
    (define-key map (kbd "e") #'cmacs-cad-toggle-edges)
    (define-key map (kbd "G") #'cmacs-cad-model-export-gcode)
    (define-key map (kbd "S") #'cmacs-cad-slicer-settings)
    (define-key map (kbd "b") #'cmacs-cad-model-set-bed-size)
    (define-key map (kbd "B") #'cmacs-cad-model-toggle-bed)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-cad-model-mode'.")

;;;###autoload
(define-derived-mode cmacs-cad-model-mode special-mode "CAD-Model"
  "View an STL/OBJ/STEP/IGES/3MF file as a rendered model in libregnum."
  ;; This buffer visits a (possibly binary) model file but DISPLAYS an info
  ;; panel; guard hard against ever writing the panel over the model:
  ;;   * the info text is marked unmodified, and
  ;;   * a write-contents guard refuses any save.
  (setq-local write-contents-functions
              (list (lambda ()
                      (message "Model viewer: %s is left unchanged"
                               (file-name-nondirectory
                                (or (buffer-file-name) "the file")))
                      t)))
  (setq-local revert-buffer-function
              (lambda (&rest _) (cmacs-cad-model-revert)))
  (add-hook 'kill-buffer-hook #'cmacs-cad-model--cleanup nil t)
  ;; Replace the (possibly binary) file content with a placeholder NOW so no
  ;; raw bytes flash, then DEFER the real render: opening the libregnum editor
  ;; + window juggling must run after `find-file' has displayed this buffer,
  ;; otherwise the viewport fails to attach (the `.cad' workbench defers too).
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "%s\n\n"
                                (file-name-nondirectory
                                 (or (buffer-file-name) "model")))
                        'face 'bold))
    (insert (propertize (if (cmacs-cad-model--available-p)
                            "Loading 3-D view…\n"
                          "libregnum/CAD not available — cannot render.\n")
                        'face 'shadow)))
  (set-buffer-modified-p nil)
  (when (cmacs-cad-model--available-p)
    (let ((buf (current-buffer)))
      (run-with-timer 0.1 nil
       (lambda ()
         (when (buffer-live-p buf)
           (with-current-buffer buf
             (ignore-errors (cmacs-cad-model--open))
             (set-buffer-modified-p nil))))))))

(defun cmacs-cad-model-revert ()
  "Re-import and re-render the model (after it changed on disk)."
  (interactive)
  (cmacs-cad-model--cleanup)
  (cmacs-cad-model--open))

;;;; Drag-and-drop: drop a model file on the viewport to insert it ------------

(declare-function dnd-get-local-file-name "dnd")
(declare-function pgtk-dnd-handle-uri-list "pgtk-dnd")
(defvar pgtk-dnd-types-alist)

(defvar cmacs-cad-model--orig-uri-handler nil
  "Original pgtk \"text/uri-list\" drop handler we wrapped, to delegate to.")

(defun cmacs-cad-model--dnd-files (data)
  "Return readable model file paths parsed from DnD DATA (uri-list text)."
  (let (files)
    (dolist (tok (split-string (or data "") "[\0\r\n]+" t))
      (let ((f (or (and (file-readable-p tok) tok)
                   (ignore-errors (dnd-get-local-file-name tok t)))))
        (when (and f (file-readable-p f)
                   (string-match-p cmacs-cad-model--ext-re f))
          (push f files))))
    (nreverse files)))

(defun cmacs-cad-model--dnd-uri-list (window action data)
  "If WINDOW shows a model viewer, insert dropped model file(s); else delegate.
Non-model files, or drops on any other window, fall through to the original
handler unchanged, so normal file drag-and-drop is unaffected."
  (let* ((buf (and (windowp window) (window-live-p window)
                   (window-buffer window)))
         (ctx (and (buffer-live-p buf)
                   (with-current-buffer buf (cmacs-cad-model--context))))
         (editor (nth 1 ctx))
         (files (and (buffer-live-p editor) (cmacs-cad-model--dnd-files data))))
    (if (and (buffer-live-p editor) files)
        (let ((n 0))
          (dolist (f files)
            (when (cmacs-cad-model--add-part editor f) (setq n (1+ n))))
          (message "Inserted %d model%s into the viewer" n (if (= n 1) "" "s"))
          'copy)
      (cond ((functionp cmacs-cad-model--orig-uri-handler)
             (funcall cmacs-cad-model--orig-uri-handler window action data))
            ((fboundp 'pgtk-dnd-handle-uri-list)
             (pgtk-dnd-handle-uri-list window action data))))))

(defun cmacs-cad-model--install-dnd ()
  "Wrap the pgtk \"text/uri-list\" drop handler so a model file dropped on a
viewport is inserted (delegating to the original handler everywhere else)."
  (when (boundp 'pgtk-dnd-types-alist)
    (let ((cell (assoc "text/uri-list" pgtk-dnd-types-alist)))
      (when (and cell (not (eq (cdr cell) #'cmacs-cad-model--dnd-uri-list)))
        (setq cmacs-cad-model--orig-uri-handler (cdr cell))
        (setcdr cell #'cmacs-cad-model--dnd-uri-list)))))

(with-eval-after-load 'pgtk-dnd (cmacs-cad-model--install-dnd))
(when (and (boundp 'pgtk-dnd-types-alist) pgtk-dnd-types-alist)
  (cmacs-cad-model--install-dnd))

;;;###autoload
(progn
  (dolist (ext '("stl" "obj" "step" "stp" "iges" "igs" "3mf"))
    (add-to-list 'auto-mode-alist
                 (cons (format "\\.%s\\'" ext) #'cmacs-cad-model-mode))))

(provide 'cmacs-cad-model)
;;; cmacs-cad-model.el ends here
