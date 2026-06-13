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
  (let ((map (make-composed-keymap nil widget-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-cad-model-apply-settings)
    (define-key map (kbd "C-c C-e") #'cmacs-cad-model-export-gcode)
    (define-key map (kbd "C-c C-k") #'cmacs-cad-model--viewer-quit)
    map)
  "Keymap for the settings panel: `widget-keymap' plus apply/export/quit.")

(defconst cmacs-cad-model--visual-cad-part 9
  "LRG_NODE_VISUAL_CAD_PART (the import + CAD_PART bake render path).")

(defvar-local cmacs-cad-model--dir nil)
(defvar-local cmacs-cad-model--cad nil)
(defvar-local cmacs-cad-model--viewer nil)
(defvar-local cmacs-cad-model--bbox nil
  "On the info buffer: the model's (MINX MINY MINZ MAXX MAXY MAXZ) bbox.")
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
  "Return a one-line info string for the model (triangles, bbox, …), or nil."
  (ignore-errors
    (cmacs-cad-eval cmacs-cad-model--cad)
    (let* ((i (cmacs-cad-inspect cmacs-cad-model--cad))
           (bb (plist-get i :bbox)))
      (setq cmacs-cad-model--bbox bb)
      (prog1
          (format "triangles %s   watertight %s%s"
                  (plist-get i :triangles)
                  (if (plist-get i :watertight) "yes" "no")
                  (if bb
                      (format "   size %.2f x %.2f x %.2f"
                              (- (nth 3 bb) (nth 0 bb))
                              (- (nth 4 bb) (nth 1 bb))
                              (- (nth 5 bb) (nth 2 bb)))
                    ""))
        (ignore-errors (cmacs-cad-doc-close cmacs-cad-model--cad))))))

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
  (let ((ctx (cmacs-cad-model--context)))
    (when ctx (cmacs-cad-model--place-bed (nth 1 ctx) (nth 3 ctx))))
  (message "Printer bed: %.0f x %.0f mm" x y))

(defun cmacs-cad-model-toggle-bed ()
  "Toggle the printer build-plate plane on or off."
  (interactive)
  (setq cmacs-cad-model-show-bed (not cmacs-cad-model-show-bed))
  (let ((ctx (cmacs-cad-model--context)))
    (when ctx (cmacs-cad-model--place-bed (nth 1 ctx) (nth 3 ctx))))
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

(defun cmacs-cad-model-export-gcode ()
  "Slice the viewed model to G-code and open it in the toolpath viewer.
Uses the current slicer settings (layer height, infill, supports, …);
change them first with \\[cmacs-cad-slicer-settings]."
  (interactive)
  (let* ((ctx  (or (cmacs-cad-model--context)
                   (user-error "No CAD model in this buffer")))
         (info (nth 0 ctx))
         (cad  (nth 2 ctx))
         (model (buffer-local-value 'buffer-file-name info)))
    (unless (and cad (fboundp 'cmacs-cad-export) (fboundp 'cmacs-cad-slice))
      (user-error "CAD slicing is not available in this build"))
    (let* ((stage (file-name-as-directory
                   (expand-file-name cmacs-cad-slicer-staging-dir)))
           (base  (file-name-base (or model "model")))
           (stl   (expand-file-name (concat base ".stl") stage)))
      (make-directory stage t)
      ;; cmacs-cad-export requires a prior eval (re-opens the doc closed by
      ;; the info pass); export the imported part to STL, then slice it.
      (cmacs-cad-eval cad)
      (cmacs-cad-export cad stl 'stl)
      (message "Slicing %s…" base)
      (cmacs-cad-slice
       stl nil nil
       (lambda (status out)
         (if (and (eq status 'done) (file-exists-p out))
             (find-file out)
           (message "Slice failed — see the *cmacs-cad slice* buffer")))))))

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

(defvar cmacs-cad-model--print-menu-items
  `((:sep)
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
menu; these add the printing workflow on top.")

;;;; Settings panel (left sidebar; C-c C-c applies) ---------------------------

(defun cmacs-cad-model--w (key)
  "Return the settings-panel widget registered under KEY, or nil."
  (cdr (assq key cmacs-cad-model--widgets)))

(defun cmacs-cad-model--render-panel (model info-string)
  "Render MODEL's header (INFO-STRING) and an editable print-settings form
into the current (info) buffer.  \\<cmacs-cad-model--panel-map>\\[cmacs-cad-model-apply-settings] applies it."
  (require 'cmacs-cad-slicer nil t)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (remove-overlays))
  (setq cmacs-cad-model--widgets nil
        buffer-read-only nil)
  (widget-insert
   (propertize (format "%s\n" (file-name-nondirectory model)) 'face 'bold))
  (widget-insert
   (propertize (format "%s\n" (upcase (or (file-name-extension model) "?")))
               'face 'shadow))
  (when info-string
    (widget-insert (propertize (concat info-string "\n") 'face 'shadow)))
  (widget-insert "\n")
  (widget-insert (propertize "Print settings  " 'face 'bold))
  (widget-insert (propertize "(C-c C-c applies)\n\n" 'face 'shadow))
  (cl-flet ((fld (key label val &optional size)
              (push (cons key
                          (widget-create 'editable-field
                                         :size (or size 7)
                                         :format (concat label ": %v")
                                         (format "%s" val)))
                    cmacs-cad-model--widgets)
              (widget-insert "\n")))
    (fld 'bed-x       "Bed X (mm)   " cmacs-cad-model-bed-x)
    (fld 'bed-y       "Bed Y (mm)   " cmacs-cad-model-bed-y)
    (widget-insert "\n")
    (fld 'layer       "Layer (mm)   " cmacs-cad-slicer-layer-height)
    (fld 'first-layer "1st layer    " cmacs-cad-slicer-first-layer-height)
    (fld 'infill      "Infill (%%)   " cmacs-cad-slicer-infill)
    (fld 'perimeters  "Walls        " cmacs-cad-slicer-perimeters)
    (fld 'brim        "Brim (mm)    " cmacs-cad-slicer-brim-width))
  (widget-insert "\n")
  (push (cons 'supports (widget-create 'checkbox cmacs-cad-slicer-supports))
        cmacs-cad-model--widgets)
  (widget-insert " Supports\n")
  (widget-insert "Style: ")
  (push (cons 'support-style
              (widget-create 'menu-choice
                             :value cmacs-cad-slicer-support-style
                             '(item :tag "Grid"    :value grid)
                             '(item :tag "Snug"    :value snug)
                             '(item :tag "Organic" :value organic)))
        cmacs-cad-model--widgets)
  (widget-insert "\n\n")
  (push (cons 'slicer
              (widget-create 'editable-field :size 18
                             :format "Slicer (blank=auto):\n  %v"
                             (or (and (boundp 'cmacs-cad-slicer-prusa-program)
                                      (stringp cmacs-cad-slicer-prusa-program)
                                      cmacs-cad-slicer-prusa-program)
                                 "")))
        cmacs-cad-model--widgets)
  (widget-insert "\n\n")
  (widget-create 'push-button
                 :notify (lambda (&rest _) (cmacs-cad-model-apply-settings))
                 "Apply")
  (widget-insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _)
                           (cmacs-cad-model-apply-settings)
                           (cmacs-cad-model-export-gcode))
                 "Export G-code")
  (widget-insert "\n")
  (widget-create 'push-button
                 :notify (lambda (&rest _) (cmacs-cad-model-toggle-bed))
                 "Toggle bed")
  (widget-insert " ")
  (widget-create 'push-button
                 :notify (lambda (&rest _) (cmacs-cad-model--viewer-revert))
                 "Reload")
  (widget-insert "\n")
  (use-local-map cmacs-cad-model--panel-map)
  (widget-setup)
  (goto-char (point-min)))

(defun cmacs-cad-model-apply-settings ()
  "Apply the print settings entered in the panel form (bound to C-c C-c).
Sets the bed size and the slicer defcustoms, then refreshes the build plate."
  (interactive)
  (require 'cmacs-cad-slicer nil t)
  (when cmacs-cad-model--widgets
    (cl-flet ((numv (key default)
                (let ((w (cmacs-cad-model--w key)))
                  (or (and w (ignore-errors
                               (string-to-number
                                (string-trim (widget-value w)))))
                      default))))
      (setq cmacs-cad-model-bed-x (numv 'bed-x cmacs-cad-model-bed-x)
            cmacs-cad-model-bed-y (numv 'bed-y cmacs-cad-model-bed-y))
      (when (boundp 'cmacs-cad-slicer-layer-height)
        (setq cmacs-cad-slicer-layer-height
              (numv 'layer cmacs-cad-slicer-layer-height)
              cmacs-cad-slicer-first-layer-height
              (numv 'first-layer cmacs-cad-slicer-first-layer-height)
              cmacs-cad-slicer-infill
              (round (numv 'infill cmacs-cad-slicer-infill))
              cmacs-cad-slicer-perimeters
              (round (numv 'perimeters cmacs-cad-slicer-perimeters))
              cmacs-cad-slicer-brim-width
              (numv 'brim cmacs-cad-slicer-brim-width)))
      (let ((sw (cmacs-cad-model--w 'supports)))
        (when (and sw (boundp 'cmacs-cad-slicer-supports))
          (setq cmacs-cad-slicer-supports (and (widget-value sw) t))))
      (let ((stw (cmacs-cad-model--w 'support-style)))
        (when (and stw (boundp 'cmacs-cad-slicer-support-style))
          (setq cmacs-cad-slicer-support-style (widget-value stw))))
      (let* ((slw (cmacs-cad-model--w 'slicer))
             (sl  (and slw (string-trim (widget-value slw)))))
        (when (boundp 'cmacs-cad-slicer-prusa-program)
          (setq cmacs-cad-slicer-prusa-program
                (and sl (> (length sl) 0) sl))))))
  (let ((ctx (cmacs-cad-model--context)))
    (when ctx (cmacs-cad-model--place-bed (nth 1 ctx) (nth 3 ctx))))
  (message
   "Applied: bed %.0fx%.0f mm · %s mm layers · %d%% infill · supports %s"
   cmacs-cad-model-bed-x cmacs-cad-model-bed-y
   cmacs-cad-slicer-layer-height cmacs-cad-slicer-infill
   (if cmacs-cad-slicer-supports
       (format "on (%s)" cmacs-cad-slicer-support-style) "off")))

(defun cmacs-cad-model--open ()
  "Open the libregnum editor on the imported model beside this info buffer."
  (let* ((info-buf (current-buffer))
         (model (buffer-file-name))
         (name (file-name-base model)))
    (cmacs-cad-model--write-importer model)
    ;; Left sidebar: model info + the editable print-settings form.  (The
    ;; file buffer itself is binary; we never save it.)
    (let ((info (cmacs-cad-model--info)))
      (cmacs-cad-model--render-panel
       model (or info "(could not import — unsupported or malformed)"))
      (set-buffer-modified-p nil))
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
      (delete-other-windows)
      (set-window-buffer (selected-window) info-buf)
      (let ((info-win (selected-window))
            (ed-win (split-window-right)))
        (set-window-buffer ed-win editor)
        ;; Narrow the settings/info sidebar; the viewport gets the rest of
        ;; the frame (the panel does not need half the window).
        (let ((delta (- cmacs-cad-model-panel-width
                        (window-total-width info-win))))
          (unless (zerop delta)
            (ignore-errors (window-resize info-win delta t))))
        (select-window ed-win)
        ;; After the first render -- when the GL context is current AND the
        ;; CAD_PART has been baked -- fit the FBO to the window and frame the
        ;; camera on the part.  Both must wait for the bake: a synchronous
        ;; resize before the first paint can fail to allocate the render
        ;; target, and focusing before the bake frames the origin (off-origin
        ;; models then sit out of view).  A couple of retries cover a slow
        ;; first bake.
        (let ((tries 0))
          (cl-labels
              ((settle ()
                 (setq tries (1+ tries))
                 (when (buffer-live-p editor)
                   (when (fboundp 'cmacs-libregnum-fit-window)
                     (ignore-errors (cmacs-libregnum-fit-window editor)))
                   (let ((pid (buffer-local-value 'cmacs-cad-model--part-id
                                                  editor)))
                     (when (and pid (fboundp 'cmacs-libregnum-editor-focus))
                       (ignore-errors
                         (cmacs-libregnum-editor-focus editor pid))))
                   (when (< tries 3)
                     (run-with-idle-timer 0.2 nil #'settle)))))
            (run-with-idle-timer 0.2 nil #'settle)))))))

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

;;;###autoload
(progn
  (dolist (ext '("stl" "obj" "step" "stp" "iges" "igs" "3mf"))
    (add-to-list 'auto-mode-alist
                 (cons (format "\\.%s\\'" ext) #'cmacs-cad-model-mode))))

(provide 'cmacs-cad-model)
;;; cmacs-cad-model.el ends here
