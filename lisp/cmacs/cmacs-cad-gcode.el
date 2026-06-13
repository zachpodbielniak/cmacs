;;; cmacs-cad-gcode.el --- G-code toolpath viewer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A viewer for G-code (.gcode) files: a pure-Elisp parser (G0/G1 linear
;; and G2/G3 arc moves, absolute/relative positioning, per-layer
;; grouping) plus `cmacs-cad-gcode-mode' -- a top-view SVG preview of one
;; layer at a time with a stats header and layer navigation.  Standalone:
;; no C, no libregnum; renders through Emacs's native SVG image support.
;;
;; It hooks the slicer (Phase 9): the post-slice "view gcode" action opens
;; the produced file here.

;;; Code:

(require 'cl-lib)
;; For the 3-D render path: cmacs-cad-available-p + the import/CAD_PART
;; bake, and the libregnum editor.  Soft so the parser still loads in a
;; build without them (the viewer then degrades to raw text).
(require 'cmacs-cad nil t)
(require 'cmacs-libregnum nil t)

(defgroup cmacs-cad-gcode nil
  "G-code toolpath viewer (3-D, rendered through libregnum)."
  :group 'cmacs-cad
  :prefix "cmacs-cad-gcode-")

;;; Parsing

(cl-defstruct (cmacs-cad-gcode-move (:constructor cmacs-cad-gcode-move-make))
  x0 y0 x1 y1 z extrude)            ; one straight segment in a layer

(cl-defstruct (cmacs-cad-gcode-doc (:constructor cmacs-cad-gcode-doc-make))
  layers          ; vector of lists of cmacs-cad-gcode-move (per layer)
  z-values        ; vector of Z heights, parallel to LAYERS
  bbox            ; (xmin ymin xmax ymax) over extruding moves
  time-seconds    ; estimate from footer, or nil
  filament-mm)    ; estimate from footer, or nil

(defun cmacs-cad-gcode--num (line letter)
  "Return the float after LETTER (e.g. ?X) in LINE, or nil."
  (when (string-match (concat (char-to-string letter)
                              "\\(-?[0-9]+\\(?:\\.[0-9]+\\)?\\)")
                      line)
    (string-to-number (match-string 1 line))))

(defun cmacs-cad-gcode-parse (text)
  "Parse G-code TEXT into a `cmacs-cad-gcode-doc'.
Tracks absolute/relative positioning (G90/G91), groups moves into layers
on Z increase, and records extruding vs travel moves and a bounding box."
  (let ((x 0.0) (y 0.0) (z 0.0) (e 0.0)
        (absolute t) (abs-e t)
        (layers nil) (zs nil)
        (cur nil) (cur-z nil)
        (xmin most-positive-fixnum) (ymin most-positive-fixnum)
        (xmax most-negative-fixnum) (ymax most-negative-fixnum)
        (time nil) (filament nil))
    (dolist (raw (split-string text "\n"))
      (let* ((semi (string-search ";" raw))
             (code (string-trim (if semi (substring raw 0 semi) raw)))
             (comment (and semi (substring raw (1+ semi)))))
        ;; Footer / slicer stats from comments.
        (when comment
          (cond
           ((string-match "TIME:\\([0-9]+\\)" comment)
            (setq time (string-to-number (match-string 1 comment))))
           ((string-match "Filament used:\\s-*\\([0-9.]+\\)m" comment)
            (setq filament (* 1000.0 (string-to-number
                                      (match-string 1 comment)))))
           ((string-match "filament used \\[mm\\] = \\([0-9.]+\\)" comment)
            (setq filament (string-to-number (match-string 1 comment))))))
        (when (and (> (length code) 0)
                   (or (string-prefix-p "G0" code)
                       (string-prefix-p "G1" code)
                       (string-prefix-p "G90" code)
                       (string-prefix-p "G91" code)
                       (string-prefix-p "M82" code)
                       (string-prefix-p "M83" code)))
          (cond
           ((string-prefix-p "G90" code) (setq absolute t abs-e t))
           ((string-prefix-p "G91" code) (setq absolute nil abs-e nil))
           ((string-prefix-p "M82" code) (setq abs-e t))
           ((string-prefix-p "M83" code) (setq abs-e nil))
           (t
            (let* ((nx (cmacs-cad-gcode--num code ?X))
                   (ny (cmacs-cad-gcode--num code ?Y))
                   (nz (cmacs-cad-gcode--num code ?Z))
                   (ne (cmacs-cad-gcode--num code ?E))
                   (px x) (py y)
                   (new-x (if nx (if absolute nx (+ x nx)) x))
                   (new-y (if ny (if absolute ny (+ y ny)) y))
                   (new-z (if nz (if absolute nz (+ z nz)) z))
                   (de (cond ((null ne) 0.0)
                             (abs-e (- ne e))
                             (t ne)))
                   (extruding (> de 1e-6)))
              ;; A Z rise starts a new layer.
              (when (or (null cur-z) (> new-z (+ cur-z 1e-4)))
                (when cur (push (nreverse cur) layers) (push cur-z zs))
                (setq cur nil cur-z new-z))
              (when (or nx ny)
                (push (cmacs-cad-gcode-move-make
                       :x0 px :y0 py :x1 new-x :y1 new-y
                       :z new-z :extrude extruding)
                      cur)
                (when extruding
                  (setq xmin (min xmin px new-x) ymin (min ymin py new-y)
                        xmax (max xmax px new-x) ymax (max ymax py new-y))))
              (setq x new-x y new-y z new-z)
              (when ne (setq e ne))))))))
    (when cur (push (nreverse cur) layers) (push cur-z zs))
    (cmacs-cad-gcode-doc-make
     :layers (vconcat (nreverse layers))
     :z-values (vconcat (nreverse zs))
     :bbox (when (<= xmin xmax) (list xmin ymin xmax ymax))
     :time-seconds time
     :filament-mm filament)))

(defun cmacs-cad-gcode--format-time (sec)
  "Human-format SEC seconds."
  (if (null sec) "?"
    (let ((h (/ sec 3600)) (m (% (/ sec 60) 60)) (s (% sec 60)))
      (cond ((> h 0) (format "%dh%02dm" h m))
            ((> m 0) (format "%dm%02ds" m s))
            (t (format "%ds" s))))))

;;; Toolpath -> 3D mesh (OBJ), rendered through libregnum

(defcustom cmacs-cad-gcode-bead-width 0.45
  "Extruded-bead width in millimetres for the 3-D toolpath mesh."
  :type 'number)

(defcustom cmacs-cad-gcode-bead-height 0.25
  "Extruded-bead height in millimetres for the 3-D toolpath mesh."
  :type 'number)

(defcustom cmacs-cad-gcode-max-triangles 400000
  "Cap on toolpath-mesh triangles (12 per extruding move).  Beyond this,
later moves are dropped and the truncation is reported, so a huge print
still opens responsively."
  :type 'integer)

(declare-function cmacs-libregnum-editor "cmacs-libregnum")
(declare-function cmacs-libregnum-editor-add-visual "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-refresh "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-editor-focus "cmacs-libregnum-defuns.c")
(declare-function cmacs-libregnum-supported-p "cmacs-libregnum")
(declare-function cmacs-libregnum-cad-invalidate "cmacs-libregnum-defuns.c")
(declare-function cmacs-cad-available-p "cmacs-cad")
(declare-function cmacs-cad-toggle-edges "cmacs-cad")
(declare-function cmacs-cad-apply-view-style "cmacs-cad")

;; LRG_NODE_VISUAL_CAD_PART -- the toolpath mesh renders through the SAME
;; cad-glib import + CAD_PART bake path the workbench uses (cad-glib's own
;; OBJ reader + grl_model_new_from_mesh), NOT raylib's file loader.
(defconst cmacs-cad-gcode--visual-cad-part 9)

(defun cmacs-cad-gcode--write-obj (doc lo hi path)
  "Write layers [LO,HI] of DOC's extruding toolpath to PATH as an OBJ
mesh: each printed move becomes a thin extruded-bead box.  Returns the
number of moves emitted (which may be capped)."
  (let* ((hw (/ cmacs-cad-gcode-bead-width 2.0))
         (h cmacs-cad-gcode-bead-height)
         (layers (cmacs-cad-gcode-doc-layers doc))
         (vi 0) (emitted 0)
         (cap (/ cmacs-cad-gcode-max-triangles 12))
         (verts (make-string 0 ?\s))
         (vbuf (generate-new-buffer " *cad-gcode-obj*")))
    (unwind-protect
        (with-current-buffer vbuf
          (insert "# cmacs-cad gcode toolpath\n")
          (cl-block emit
            (cl-loop for li from (max 0 lo) to (min hi (1- (length layers)))
                     do
                     (dolist (m (aref layers li))
                       (when (cmacs-cad-gcode-move-extrude m)
                         (when (>= emitted cap) (cl-return-from emit))
                         (let* ((x0 (cmacs-cad-gcode-move-x0 m))
                                (y0 (cmacs-cad-gcode-move-y0 m))
                                (x1 (cmacs-cad-gcode-move-x1 m))
                                (y1 (cmacs-cad-gcode-move-y1 m))
                                (z  (cmacs-cad-gcode-move-z m))
                                (dx (- x1 x0)) (dy (- y1 y0))
                                (len (max 1e-6 (sqrt (+ (* dx dx) (* dy dy)))))
                                (px (* (/ (- dy) len) hw))
                                (py (* (/ dx len) hw))
                                (zb (- z h)) (zt z))
                           ;; 8 box corners (bottom 1-4, top 5-8).
                           (insert (format "v %.3f %.3f %.3f\n" (+ x0 px) (+ y0 py) zb))
                           (insert (format "v %.3f %.3f %.3f\n" (- x0 px) (- y0 py) zb))
                           (insert (format "v %.3f %.3f %.3f\n" (- x1 px) (- y1 py) zb))
                           (insert (format "v %.3f %.3f %.3f\n" (+ x1 px) (+ y1 py) zb))
                           (insert (format "v %.3f %.3f %.3f\n" (+ x0 px) (+ y0 py) zt))
                           (insert (format "v %.3f %.3f %.3f\n" (- x0 px) (- y0 py) zt))
                           (insert (format "v %.3f %.3f %.3f\n" (- x1 px) (- y1 py) zt))
                           (insert (format "v %.3f %.3f %.3f\n" (+ x1 px) (+ y1 py) zt))
                           (let ((b (1+ vi)))
                             (dolist (tri '((0 1 2) (0 2 3)        ; bottom
                                            (4 6 5) (4 7 6)        ; top
                                            (0 4 5) (0 5 1)        ; sides
                                            (1 5 6) (1 6 2)
                                            (2 6 7) (2 7 3)
                                            (3 7 4) (3 4 0)))
                               (insert (format "f %d %d %d\n"
                                               (+ b (nth 0 tri))
                                               (+ b (nth 1 tri))
                                               (+ b (nth 2 tri))))))
                           (setq vi (+ vi 8) emitted (1+ emitted)))))))
          (ignore verts)
          (write-region (point-min) (point-max) path nil 'silent))
      (kill-buffer vbuf))
    emitted))

;;; Major mode (libregnum-rendered)

(defvar-local cmacs-cad-gcode--doc nil)
(defvar-local cmacs-cad-gcode--lo 0)
(defvar-local cmacs-cad-gcode--hi most-positive-fixnum)
(defvar-local cmacs-cad-gcode--viewer nil "Paired libregnum editor buffer.")
(defvar-local cmacs-cad-gcode--dir nil "Temp dir holding the toolpath files.")
(defvar-local cmacs-cad-gcode--obj nil "Temp OBJ path for the toolpath mesh.")
(defvar-local cmacs-cad-gcode--cad nil "Temp .cad importing the toolpath OBJ.")

(defun cmacs-cad-gcode--nlayers ()
  (length (cmacs-cad-gcode-doc-layers cmacs-cad-gcode--doc)))

(defun cmacs-cad-gcode--available-p ()
  (and (display-graphic-p)
       (fboundp 'cmacs-libregnum-supported-p)
       (ignore-errors (cmacs-libregnum-supported-p))
       (fboundp 'cmacs-cad-available-p)
       (cmacs-cad-available-p)))

(defun cmacs-cad-gcode--write-part ()
  "Write the toolpath OBJ for the current layer range + the .cad importer."
  (cmacs-cad-gcode--write-obj cmacs-cad-gcode--doc
                              cmacs-cad-gcode--lo cmacs-cad-gcode--hi
                              cmacs-cad-gcode--obj)
  (with-temp-file cmacs-cad-gcode--cad
    (insert ";; generated toolpath part\n"
            "(defpart toolpath (import \"toolpath.obj\"))\n")))

(defvar cmacs-cad-gcode-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "]")   #'cmacs-cad-gcode-raise-top)
    (define-key map (kbd "[")   #'cmacs-cad-gcode-lower-top)
    (define-key map (kbd "G")   #'cmacs-cad-gcode-all-layers)
    (define-key map (kbd "g")   #'cmacs-cad-gcode-refresh)
    (define-key map (kbd "e")   #'cmacs-cad-toggle-edges)
    map)
  "Keymap for `cmacs-cad-gcode-mode'.")

;;;###autoload
(define-derived-mode cmacs-cad-gcode-mode prog-mode "G-code"
  "Major mode for a sliced G-code file.
The raw text stays in this buffer; the toolpath is rendered as a 3-D
extruded-bead mesh through the libregnum editor in a side window.  [ and
] scrub the top visible layer, G shows all layers."
  (setq cmacs-cad-gcode--doc
        (cmacs-cad-gcode-parse
         (let ((f (buffer-file-name)))
           (if (and f (file-readable-p f))
               (with-temp-buffer (insert-file-contents f) (buffer-string))
             (buffer-substring-no-properties (point-min) (point-max)))))
        cmacs-cad-gcode--lo 0
        cmacs-cad-gcode--hi (1- (max 1 (cmacs-cad-gcode--nlayers)))
        cmacs-cad-gcode--dir (make-temp-file "cmacs-cad-gcode" t)
        cmacs-cad-gcode--obj (expand-file-name "toolpath.obj"
                                               cmacs-cad-gcode--dir)
        cmacs-cad-gcode--cad (expand-file-name "toolpath.cad"
                                               cmacs-cad-gcode--dir))
  (setq mode-line-process
        '(:eval (format " [%s layers · %s · %s]"
                        (cmacs-cad-gcode--nlayers)
                        (cmacs-cad-gcode--format-time
                         (cmacs-cad-gcode-doc-time-seconds cmacs-cad-gcode--doc))
                        (if (cmacs-cad-gcode-doc-filament-mm cmacs-cad-gcode--doc)
                            (format "%.1fm"
                                    (/ (cmacs-cad-gcode-doc-filament-mm
                                        cmacs-cad-gcode--doc) 1000.0))
                          "?"))))
  (add-hook 'kill-buffer-hook #'cmacs-cad-gcode--cleanup nil t)
  ;; Defer opening the editor + window juggling until after `find-file' has
  ;; displayed this buffer (a synchronous open during the mode function leaves
  ;; the viewport unattached).
  (if (cmacs-cad-gcode--available-p)
      (let ((buf (current-buffer)))
        (run-with-timer 0.1 nil
         (lambda () (when (buffer-live-p buf)
                      (with-current-buffer buf
                        (ignore-errors (cmacs-cad-gcode--open-viewer)))))))
    (message "G-code: libregnum not available; showing raw text only")))

(defun cmacs-cad-gcode--cleanup ()
  (when (and cmacs-cad-gcode--dir (file-directory-p cmacs-cad-gcode--dir))
    (ignore-errors (delete-directory cmacs-cad-gcode--dir t)))
  (when (buffer-live-p cmacs-cad-gcode--viewer)
    (kill-buffer cmacs-cad-gcode--viewer)))

(defvar-local cmacs-cad-gcode--text-buffer nil
  "On the editor buffer: the paired G-code text buffer (for layer keys).")

(defvar cmacs-cad-gcode--viewport-map
  (let ((map (make-sparse-keymap)))
    (dolist (b '(("]" . cmacs-cad-gcode-raise-top)
                 ("[" . cmacs-cad-gcode-lower-top)
                 ("G" . cmacs-cad-gcode-all-layers)
                 ("g" . cmacs-cad-gcode-refresh)))
      (let ((cmd (cdr b)))
        (define-key map (kbd (car b))
          (lambda ()
            (interactive)
            (if (buffer-live-p cmacs-cad-gcode--text-buffer)
                (with-current-buffer cmacs-cad-gcode--text-buffer
                  (call-interactively cmd))
              (call-interactively cmd))))))
    (define-key map (kbd "e") #'cmacs-cad-toggle-edges)
    map)
  "Layer/edge keys composed onto the editor when it is a toolpath viewport
\(focused so mouse orbit/pan work without a pre-click).")

(defun cmacs-cad-gcode--open-viewer ()
  "Open the libregnum editor showing the toolpath mesh beside the text."
  (let ((text-buf (current-buffer)))
    (cmacs-cad-gcode--write-part)
    (let ((editor (save-window-excursion (cmacs-libregnum-editor))))
      (with-current-buffer text-buf (setq cmacs-cad-gcode--viewer editor))
      (let ((id (cmacs-libregnum-editor-add-visual
                 editor cmacs-cad-gcode--visual-cad-part
                 cmacs-cad-gcode--cad "toolpath")))
        (when (fboundp 'cmacs-cad-apply-view-style)
          (cmacs-cad-apply-view-style editor))
        (when (and id (fboundp 'cmacs-libregnum-editor-focus))
          (ignore-errors (cmacs-libregnum-editor-focus editor id))))
      ;; Compose the layer/edge keys onto the editor + focus it: mouse
      ;; orbit/pan only route to a libregnum view when its window is the
      ;; selected window (else right-drag falls through to a context menu).
      (with-current-buffer editor
        (setq cmacs-cad-gcode--text-buffer text-buf)
        (use-local-map (make-composed-keymap cmacs-cad-gcode--viewport-map
                                              (current-local-map))))
      (delete-other-windows)
      (set-window-buffer (selected-window) text-buf)
      (select-window (split-window-right))
      (switch-to-buffer editor)
      (select-window (get-buffer-window editor)))))

(defun cmacs-cad-gcode-refresh ()
  "Regenerate the toolpath mesh for the current layer range and redraw."
  (interactive)
  (unless (cmacs-cad-gcode--available-p)
    (user-error "libregnum/CAD not available"))
  (cmacs-cad-gcode--write-part)
  ;; The CAD manager caches the bake by .cad path, but the imported OBJ
  ;; changed underneath it -- drop the cache so the new layer range bakes.
  (when (fboundp 'cmacs-libregnum-cad-invalidate)
    (ignore-errors (cmacs-libregnum-cad-invalidate cmacs-cad-gcode--cad)))
  (if (buffer-live-p cmacs-cad-gcode--viewer)
      (ignore-errors (cmacs-libregnum-editor-refresh cmacs-cad-gcode--viewer))
    (cmacs-cad-gcode--open-viewer))
  (message "G-code: layers 0..%d of %d"
           cmacs-cad-gcode--hi (1- (cmacs-cad-gcode--nlayers))))

(defun cmacs-cad-gcode-raise-top ()
  "Show one more layer from the top (scrub the print upward)."
  (interactive)
  (setq cmacs-cad-gcode--hi
        (min (1- (cmacs-cad-gcode--nlayers)) (1+ cmacs-cad-gcode--hi)))
  (cmacs-cad-gcode-refresh))

(defun cmacs-cad-gcode-lower-top ()
  "Hide the top layer (scrub the print downward)."
  (interactive)
  (setq cmacs-cad-gcode--hi (max 0 (1- cmacs-cad-gcode--hi)))
  (cmacs-cad-gcode-refresh))

(defun cmacs-cad-gcode-all-layers ()
  "Show all layers."
  (interactive)
  (setq cmacs-cad-gcode--lo 0
        cmacs-cad-gcode--hi (1- (cmacs-cad-gcode--nlayers)))
  (cmacs-cad-gcode-refresh))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.gcode\\'" . cmacs-cad-gcode-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.gco\\'" . cmacs-cad-gcode-mode))

(provide 'cmacs-cad-gcode)
;;; cmacs-cad-gcode.el ends here
