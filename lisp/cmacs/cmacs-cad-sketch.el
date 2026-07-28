;;; cmacs-cad-sketch.el --- Interactive 2D constraint sketcher -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A 2D constraint sketcher rendered as an SVG image in an Emacs buffer,
;; driving cad-glib's SolveSpace solver through the `cmacs-cad-sketch-*'
;; DEFUNs.  Place points (click or `p'), connect lines (`l'), draw circles
;; (`c'); select entities and apply constraints (Horizontal, Vertical,
;; Parallel, perpeNdicular, Equal, Tangent, Coincident, Midpoint, Fixed);
;; `D' adds a dimension.  The header-line shows the remaining degrees of
;; freedom (green 0 / yellow >0 / red failed).  `C-c C-c' serialises the
;; sketch to a `(defsketch NAME ...)' form and splices it into the part
;; buffer (write-back).
;;
;; This is the buffer-native sketcher; it shares the solver and write-back
;; with any future in-viewport sketcher.

;;; Code:

(require 'svg)
(require 'cl-lib)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence

(declare-function cmacs-cad-sketch-new "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-free "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-add-point "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-add-line "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-add-circle "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-constrain "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-solve "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-dof "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-failed "cmacs-cad-sketch.c")
(declare-function cmacs-cad-sketch-point "cmacs-cad-sketch.c")

(defcustom cmacs-cad-sketch-size 560
  "Edge length in pixels of the sketch canvas."
  :type 'integer :group 'cmacs-cad)

(defcustom cmacs-cad-sketch-scale 14.0
  "Pixels per sketch unit."
  :type 'number :group 'cmacs-cad)

;; Buffer-local sketcher state.
(defvar-local cmacs-cad-sketch--handle nil)
(defvar-local cmacs-cad-sketch--points nil   "alist (id . (x . y)) -- pre-solve.")
(defvar-local cmacs-cad-sketch--lines nil    "alist (id . (a . b)).")
(defvar-local cmacs-cad-sketch--circles nil  "alist (id . (center . r)).")
(defvar-local cmacs-cad-sketch--selection nil "list of selected entity ids.")
(defvar-local cmacs-cad-sketch--name "sketch")
(defvar-local cmacs-cad-sketch--target nil   "(BUFFER . NAME) to write back to.")
(defvar-local cmacs-cad-sketch--status "")

;;; Coordinate transforms (sketch space <-> canvas pixels, origin centered)

(defun cmacs-cad-sketch--sx (x)
  (+ (/ cmacs-cad-sketch-size 2.0) (* x cmacs-cad-sketch-scale)))
(defun cmacs-cad-sketch--sy (y)
  (- (/ cmacs-cad-sketch-size 2.0) (* y cmacs-cad-sketch-scale)))
(defun cmacs-cad-sketch--ux (px)
  (/ (- px (/ cmacs-cad-sketch-size 2.0)) cmacs-cad-sketch-scale))
(defun cmacs-cad-sketch--uy (py)
  (/ (- (/ cmacs-cad-sketch-size 2.0) py) cmacs-cad-sketch-scale))

(defun cmacs-cad-sketch--pt (id)
  "Return (X . Y) of point ID, preferring the solved value."
  (or (ignore-errors
        (let ((p (cmacs-cad-sketch-point cmacs-cad-sketch--handle id)))
          (and p (cons (nth 0 p) (nth 1 p)))))
      (cdr (assq id cmacs-cad-sketch--points))))

;;; Rendering

(defun cmacs-cad-sketch--render ()
  "Redraw the sketch canvas."
  (let* ((size cmacs-cad-sketch-size)
         (svg (svg-create size size))
         (inhibit-read-only t))
    (svg-rectangle svg 0 0 size size :fill "#0d0d12")
    ;; Axes.
    (svg-line svg 0 (cmacs-cad-sketch--sy 0) size (cmacs-cad-sketch--sy 0)
              :stroke "#333" :stroke-width 1)
    (svg-line svg (cmacs-cad-sketch--sx 0) 0 (cmacs-cad-sketch--sx 0) size
              :stroke "#333" :stroke-width 1)
    ;; Lines.
    (dolist (l cmacs-cad-sketch--lines)
      (let ((a (cmacs-cad-sketch--pt (cadr l)))
            (b (cmacs-cad-sketch--pt (cddr l))))
        (when (and a b)
          (svg-line svg (cmacs-cad-sketch--sx (car a))
                    (cmacs-cad-sketch--sy (cdr a))
                    (cmacs-cad-sketch--sx (car b))
                    (cmacs-cad-sketch--sy (cdr b))
                    :stroke (if (memq (car l) cmacs-cad-sketch--selection)
                                "#ffd75f" "#7fbfff")
                    :stroke-width 2))))
    ;; Circles.
    (dolist (c cmacs-cad-sketch--circles)
      (let ((ctr (cmacs-cad-sketch--pt (cadr c))))
        (when ctr
          (svg-circle svg (cmacs-cad-sketch--sx (car ctr))
                      (cmacs-cad-sketch--sy (cdr ctr))
                      (* (cddr c) cmacs-cad-sketch-scale)
                      :fill "none"
                      :stroke (if (memq (car c) cmacs-cad-sketch--selection)
                                  "#ffd75f" "#7fbfff")
                      :stroke-width 2))))
    ;; Points.
    (dolist (p cmacs-cad-sketch--points)
      (let ((xy (cmacs-cad-sketch--pt (car p))))
        (when xy
          (svg-circle svg (cmacs-cad-sketch--sx (car xy))
                      (cmacs-cad-sketch--sy (cdr xy))
                      (if (memq (car p) cmacs-cad-sketch--selection) 5 3)
                      :fill (if (memq (car p) cmacs-cad-sketch--selection)
                                "#ffd75f" "#dddddd")))))
    (erase-buffer)
    (insert-image (svg-image svg :scale 1.0 :map
                             (cmacs-cad-sketch--image-map)))
    (insert "\n")
    (insert (propertize cmacs-cad-sketch--status 'face 'shadow))
    (goto-char (point-min))))

(defun cmacs-cad-sketch--image-map ()
  "Build a clickable hot-spot map of points (so clicks select them)."
  (delq nil
        (mapcar
         (lambda (p)
           (let ((xy (cmacs-cad-sketch--pt (car p))))
             (when xy
               (let ((cx (round (cmacs-cad-sketch--sx (car xy))))
                     (cy (round (cmacs-cad-sketch--sy (cdr xy)))))
                 (list (cons 'circle (cons (cons cx cy) 8))
                       (car p)
                       (list 'pointer 'hand))))))
         cmacs-cad-sketch--points)))

(defun cmacs-cad-sketch--update-header ()
  (let* ((dof (ignore-errors (cmacs-cad-sketch-dof cmacs-cad-sketch--handle)))
         (failed (ignore-errors
                   (cmacs-cad-sketch-failed cmacs-cad-sketch--handle))))
    (setq header-line-format
          (cond
           (failed (propertize (format " OVER-CONSTRAINED: %S " failed)
                               'face '(:foreground "red" :weight bold)))
           ((and dof (= dof 0))
            (propertize " Fully constrained (DOF 0) "
                        'face '(:foreground "green" :weight bold)))
           (dof (propertize (format " DOF %d " dof)
                            'face '(:foreground "yellow")))
           (t " (unsolved) ")))))

;;; Entity creation

(defun cmacs-cad-sketch-add-point-at (x y)
  "Add a point at sketch coords (X Y)."
  (interactive (list (read-number "x: " 0.0) (read-number "y: " 0.0)))
  (let ((id (cmacs-cad-sketch-add-point cmacs-cad-sketch--handle x y)))
    (push (cons id (cons x y)) cmacs-cad-sketch--points)
    (setq cmacs-cad-sketch--status (format "point %d at (%.2f %.2f)" id x y))
    (cmacs-cad-sketch--refresh)
    id))

(defun cmacs-cad-sketch-line ()
  "Connect the two selected points with a line."
  (interactive)
  (if (/= 2 (length cmacs-cad-sketch--selection))
      (user-error "Select exactly two points first")
    (let* ((sel (reverse cmacs-cad-sketch--selection))
           (id (cmacs-cad-sketch-add-line cmacs-cad-sketch--handle
                                          (nth 0 sel) (nth 1 sel))))
      (push (cons id (cons (nth 0 sel) (nth 1 sel))) cmacs-cad-sketch--lines)
      (setq cmacs-cad-sketch--selection nil
            cmacs-cad-sketch--status (format "line %d" id))
      (cmacs-cad-sketch--refresh))))

(defun cmacs-cad-sketch-circle (radius)
  "Draw a circle of RADIUS at the selected center point."
  (interactive (list (read-number "radius: " 5.0)))
  (if (/= 1 (length cmacs-cad-sketch--selection))
      (user-error "Select exactly one point (the center) first")
    (let* ((center (car cmacs-cad-sketch--selection))
           (id (cmacs-cad-sketch-add-circle cmacs-cad-sketch--handle
                                            center radius)))
      (push (cons id (cons center radius)) cmacs-cad-sketch--circles)
      (setq cmacs-cad-sketch--selection nil
            cmacs-cad-sketch--status (format "circle %d" id))
      (cmacs-cad-sketch--refresh))))

;;; Selection + click

(defun cmacs-cad-sketch-click (event)
  "Select the point under the mouse, or place one on empty canvas."
  (interactive "e")
  (let* ((posn (event-start event))
         (id (posn-area posn))
         (obj (posn-object posn)))
    (cond
     ;; A hot-spot id (an integer from the image map) -> toggle selection.
     ((and (consp obj) (integerp (cdr obj)))
      (cmacs-cad-sketch--toggle (cdr obj)))
     ;; Empty canvas -> place a point there.
     ((posn-object-x-y posn)
      (let ((xy (posn-object-x-y posn)))
        (cmacs-cad-sketch-add-point-at
         (cmacs-cad-sketch--ux (car xy))
         (cmacs-cad-sketch--uy (cdr xy)))))
     (t (ignore id)))))

(defun cmacs-cad-sketch--toggle (id)
  (if (memq id cmacs-cad-sketch--selection)
      (setq cmacs-cad-sketch--selection
            (delq id cmacs-cad-sketch--selection))
    (push id cmacs-cad-sketch--selection))
  (cmacs-cad-sketch--refresh))

(defun cmacs-cad-sketch-clear-selection ()
  "Deselect everything."
  (interactive)
  (setq cmacs-cad-sketch--selection nil)
  (cmacs-cad-sketch--refresh))

;;; Constraints

(defun cmacs-cad-sketch--apply (kind &optional value)
  "Apply constraint KIND to the current selection (1 or 2 entities)."
  (let* ((sel (reverse cmacs-cad-sketch--selection))
         (a (nth 0 sel)) (b (nth 1 sel)))
    (unless a (user-error "Select an entity first"))
    (condition-case err
        (progn
          (cmacs-cad-sketch-constrain cmacs-cad-sketch--handle kind a b value)
          (setq cmacs-cad-sketch--selection nil
                cmacs-cad-sketch--status (format "constraint: %s" kind))
          (cmacs-cad-sketch-solve-quiet))
      (error (setq cmacs-cad-sketch--status
                   (format "constraint failed: %s"
                           (error-message-string err)))))
    (cmacs-cad-sketch--refresh)))

(defmacro cmacs-cad-sketch--def-constraint (name kind &optional dimension)
  "Define an interactive constraint command NAME applying KIND."
  `(defun ,name ()
     ,(format "Apply the `%s' constraint to the selection." kind)
     (interactive)
     (cmacs-cad-sketch--apply ',kind
                              ,(if dimension
                                   '(read-number "value: " 10.0)
                                 nil))))

(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-horizontal horizontal)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-vertical vertical)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-parallel parallel)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-perpendicular perpendicular)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-equal equal)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-tangent tangent)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-coincident coincident)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-midpoint midpoint)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-fixed fixed)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-distance distance t)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-diameter diameter t)
(cmacs-cad-sketch--def-constraint cmacs-cad-sketch-angle angle t)

;;; Solve + refresh

(defun cmacs-cad-sketch-solve-quiet ()
  "Solve, swallowing the closed-profile error; update the header."
  (ignore-errors (cmacs-cad-sketch-solve cmacs-cad-sketch--handle))
  (cmacs-cad-sketch--update-header))

(defun cmacs-cad-sketch-do-solve ()
  "Solve the sketch and report."
  (interactive)
  (condition-case err
      (progn (cmacs-cad-sketch-solve cmacs-cad-sketch--handle)
             (setq cmacs-cad-sketch--status "solved"))
    (error (setq cmacs-cad-sketch--status
                 (format "solve: %s" (error-message-string err)))))
  (cmacs-cad-sketch--refresh))

(defun cmacs-cad-sketch--refresh ()
  (cmacs-cad-sketch--update-header)
  (cmacs-cad-sketch--render))

;;; Write-back

(defun cmacs-cad-sketch-serialize ()
  "Return a `(defsketch NAME ...)' form string for the current sketch."
  (let ((parts (list (format "(defsketch %s" cmacs-cad-sketch--name))))
    (dolist (p (reverse cmacs-cad-sketch--points))
      (let ((xy (cmacs-cad-sketch--pt (car p))))
        (push (format "  (pt p%d %.3f %.3f)" (car p) (car xy) (cdr xy))
              parts)))
    (dolist (l (reverse cmacs-cad-sketch--lines))
      (push (format "  (line l%d p%d p%d)"
                    (car l) (cadr l) (cddr l)) parts))
    (dolist (c (reverse cmacs-cad-sketch--circles))
      (push (format "  (circle c%d p%d %.3f)"
                    (car c) (cadr c) (cddr c)) parts))
    (concat (mapconcat #'identity (nreverse parts) "\n") ")\n")))

(defun cmacs-cad-sketch-finish ()
  "Serialise the sketch and write it into the target part buffer."
  (interactive)
  (let ((form (cmacs-cad-sketch-serialize))
        (target cmacs-cad-sketch--target))
    (if (and target (buffer-live-p (car target)))
        (with-current-buffer (car target)
          (save-excursion
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert "\n" form))
          (message "Sketch written to %s" (buffer-name (car target))))
      (kill-new form)
      (message "Sketch copied to the kill-ring (no target buffer)"))))

;;; Mode

(defvar cmacs-cad-sketch-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'cmacs-cad-sketch-click)
    (define-key map (kbd "p") #'cmacs-cad-sketch-add-point-at)
    (define-key map (kbd "l") #'cmacs-cad-sketch-line)
    (define-key map (kbd "c") #'cmacs-cad-sketch-circle)
    (define-key map (kbd "H") #'cmacs-cad-sketch-horizontal)
    (define-key map (kbd "V") #'cmacs-cad-sketch-vertical)
    (define-key map (kbd "P") #'cmacs-cad-sketch-parallel)
    (define-key map (kbd "N") #'cmacs-cad-sketch-perpendicular)
    (define-key map (kbd "E") #'cmacs-cad-sketch-equal)
    (define-key map (kbd "T") #'cmacs-cad-sketch-tangent)
    (define-key map (kbd "C") #'cmacs-cad-sketch-coincident)
    (define-key map (kbd "M") #'cmacs-cad-sketch-midpoint)
    (define-key map (kbd "F") #'cmacs-cad-sketch-fixed)
    (define-key map (kbd "D") #'cmacs-cad-sketch-distance)
    (define-key map (kbd "R") #'cmacs-cad-sketch-diameter)
    (define-key map (kbd "A") #'cmacs-cad-sketch-angle)
    (define-key map (kbd "s") #'cmacs-cad-sketch-solve)
    (define-key map (kbd "g") #'cmacs-cad-sketch--refresh)
    (define-key map (kbd "u") #'cmacs-cad-sketch-clear-selection)
    (define-key map (kbd "C-c C-c") #'cmacs-cad-sketch-finish)
    map)
  "Keymap for `cmacs-cad-sketch-mode'.")

;; Under Evil (Doom) the state maps outrank the major-mode map, so the whole
;; tool/constraint alphabet ran Evil commands instead (`p' paste, `c'/`s'
;; change/substitute, `u' undo, `D'/`R'/`A' delete-line/replace/append, ...).
;; Install the map as an Evil intercept map -- see cmacs-evil.el.
(cmacs-evil-setup-mode-map cmacs-cad-sketch-mode-map 'cmacs-cad-sketch-mode)

(define-derived-mode cmacs-cad-sketch-mode special-mode "cmacs-Sketch"
  "Major mode for the interactive 2D constraint sketcher."
  (setq cmacs-cad-sketch--handle (cmacs-cad-sketch-new))
  (add-hook 'kill-buffer-hook
            (lambda () (when cmacs-cad-sketch--handle
                         (ignore-errors
                           (cmacs-cad-sketch-free cmacs-cad-sketch--handle))))
            nil t))

;;;###autoload
(defun cmacs-cad-sketch (&optional name target-buffer)
  "Open an interactive 2D constraint sketcher named NAME.
On finish (\\<cmacs-cad-sketch-mode-map>\\[cmacs-cad-sketch-finish]) the
`(defsketch ...)' form is written into TARGET-BUFFER (or the current part
buffer)."
  (interactive
   (list (read-string "Sketch name: " "sketch") (current-buffer)))
  (unless (and (fboundp 'cmacs-cad-supported-p) (cmacs-cad-supported-p))
    (user-error "CAD subsystem not built (--with-cmacs-cad)"))
  ;; Only the s-expression DSL supports sketch write-back; from a crispy
  ;; (.ccad) buffer the finished form goes to the kill-ring instead (the
  ;; user pastes it into a referenced .cad sketch file).
  (when (and target-buffer
             (not (let ((f (buffer-file-name target-buffer)))
                    (and f (string-suffix-p ".cad" f)))))
    (message "Sketch write-back needs a .cad buffer; result will go to \
the kill-ring")
    (setq target-buffer nil))
  (let ((buf (get-buffer-create (format "*cmacs-cad sketch: %s*" name))))
    (with-current-buffer buf
      (cmacs-cad-sketch-mode)
      (setq cmacs-cad-sketch--name name
            cmacs-cad-sketch--target (and target-buffer
                                          (cons target-buffer name))
            cmacs-cad-sketch--status
            "click to place points · l line · c circle · H/V/F… constrain")
      (cmacs-cad-sketch--refresh))
    (pop-to-buffer buf)))

(provide 'cmacs-cad-sketch)
;;; cmacs-cad-sketch.el ends here
