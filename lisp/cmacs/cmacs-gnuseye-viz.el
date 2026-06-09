;;; cmacs-gnuseye-viz.el --- GNU's Eye visualization upgrades  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Density heatmaps, per-layer opacity, satellite footprint rings, and
;; great-circle flow arcs — all on the existing polygon/arc primitives.

;;; Code:

(require 'cmacs-gnuseye)

;;; Density heatmap -----------------------------------------------------------

(defcustom cmacs-gnuseye-heatmap-cell 4.0
  "Grid cell size in degrees for density heatmaps."
  :type 'number :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-heatmap-cells (entities cell)
  "Bin ENTITIES into a CELL-degree grid; return ((CLAT CLON COUNT) …)."
  (let ((h (make-hash-table :test 'equal)) out)
    (dolist (e entities)
      (let* ((lat (or (plist-get e :lat) 0.0)) (lon (or (plist-get e :lon) 0.0))
             (gy (floor (/ lat cell))) (gx (floor (/ lon cell)))
             (key (cons gy gx)))
        (cl-incf (gethash key h 0))))
    (maphash (lambda (k n)
               (push (list (* (+ (car k) 0.5) cell) (* (+ (cdr k) 0.5) cell) n)
                     out))
             h)
    out))

(defun cmacs-gnuseye-heatmap (buffer entities &optional cell)
  "Draw a translucent density heatmap of ENTITIES on BUFFER's globe.
Uses the persistent polygon list (shares it with the choropleth — use one at a
time).  Each grid cell is a quad coloured green→red by relative density."
  (let* ((cell (or cell cmacs-gnuseye-heatmap-cell))
         (cells (cmacs-gnuseye-heatmap-cells entities cell))
         (maxc (apply #'max 1 (mapcar (lambda (c) (nth 2 c)) cells)))
         (d (/ cell 2.0)))
    (when (and buffer (buffer-live-p buffer) (cmacs-gnuseye-attached-p buffer))
      (ignore-errors (cmacs-gnuseye-clear-polygons buffer t))
      (dolist (c cells)
        (let* ((la (nth 0 c)) (lo (nth 1 c))
               (rgba (cmacs-gnuseye--risk->rgba (/ (float (nth 2 c)) maxc) 120))
               (lats (vector (- la d) (- la d) (+ la d) (+ la d)))
               (lons (vector (- lo d) (+ lo d) (+ lo d) (- lo d))))
          (ignore-errors (cmacs-gnuseye-add-polygon buffer lats lons rgba t))))
      (cmacs-gnuseye-redraw buffer))))

;;;###autoload
(defun cmacs-gnuseye-heatmap-layer (layer)
  "Draw a density heatmap of LAYER's entities."
  (interactive
   (list (intern (completing-read
                  "Heatmap layer: "
                  (let (ks) (maphash (lambda (k v)
                                       (when (cmacs-gnuseye-layer-enabled v)
                                         (push k ks)))
                                     cmacs-gnuseye--layers) ks)
                  nil t))))
  (cmacs-gnuseye-heatmap cmacs-gnuseye-buffer
                         (gethash layer cmacs-gnuseye--layer-entities)))

;;;###autoload
(defun cmacs-gnuseye-heatmap-clear ()
  "Remove the heatmap (persistent polygons)."
  (interactive)
  (when (and cmacs-gnuseye-buffer (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer))
    (ignore-errors (cmacs-gnuseye-clear-polygons cmacs-gnuseye-buffer t))
    (cmacs-gnuseye-redraw cmacs-gnuseye-buffer)))

;;; Per-layer opacity ---------------------------------------------------------

;;;###autoload
(defun cmacs-gnuseye-set-layer-opacity (layer opacity)
  "Set LAYER's marker/polygon OPACITY (0..1) and re-render."
  (interactive
   (list (intern (completing-read
                  "Layer: "
                  (let (ks) (maphash (lambda (k _) (push k ks))
                                     cmacs-gnuseye--layers) ks)
                  nil t))
         (read-number "Opacity (0..1): " 1.0)))
  (let ((l (gethash layer cmacs-gnuseye--layers)))
    (when l
      (setf (cmacs-gnuseye-layer-opacity l) (max 0.0 (min 1.0 opacity)))
      (cmacs-gnuseye--render-all))))

;;; Satellite footprint rings -------------------------------------------------

(defun cmacs-gnuseye-footprint-radius-m (alt-m)
  "Ground radius (m) of the horizon circle for an object at ALT-M altitude."
  (let ((re 6371000.0))
    (* re (acos (/ re (+ re (max 1.0 alt-m)))))))

;;;###autoload
(defun cmacs-gnuseye-sat-footprints (&optional buffer)
  "Draw the current coverage footprint of each satellite as a persistent ring."
  (interactive)
  (let ((buffer (or buffer cmacs-gnuseye-buffer)))
    (when (and buffer (cmacs-gnuseye-attached-p buffer))
      (ignore-errors (cmacs-gnuseye-clear-polygons buffer t))
      (dolist (e (gethash 'satellites cmacs-gnuseye--layer-entities))
        (let* ((lat (plist-get e :lat)) (lon (plist-get e :lon))
               (alt (or (plist-get e :alt) 500000.0)))
          (when (and (numberp lat) (numberp lon))
            (let* ((ring (cmacs-gnuseye-circle-points
                          lat lon (cmacs-gnuseye-footprint-radius-m alt) 48))
                   (lats (apply #'vector (mapcar (lambda (p) (aref p 0))
                                                 (append ring nil))))
                   (lons (apply #'vector (mapcar (lambda (p) (aref p 1))
                                                 (append ring nil)))))
              (ignore-errors
                (cmacs-gnuseye-add-polygon buffer lats lons #x9ad0ff33 t))))))
      (cmacs-gnuseye-redraw buffer))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "H") #'cmacs-gnuseye-heatmap-layer))

(provide 'cmacs-gnuseye-viz)
;;; cmacs-gnuseye-viz.el ends here
