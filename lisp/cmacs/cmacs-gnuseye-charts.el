;;; cmacs-gnuseye-charts.el --- GNU's Eye SVG chart helpers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Small SVG chart helpers (sparkline, bars, treemap) for dashboard panels and
;; the inspector, built on the bundled `svg.el'.  Each returns a string whose
;; display property is the rendered image (insert it anywhere); on a TTY/no-svg
;; Emacs they fall back to a unicode approximation.

;;; Code:

(require 'svg nil t)

(defun cmacs-gnuseye-charts--svgp ()
  (and (fboundp 'svg-create) (display-graphic-p) (image-type-available-p 'svg)))

(defun cmacs-gnuseye-chart-sparkline (values &optional w h color)
  "A sparkline image string for the numeric list VALUES (W x H px)."
  (let ((w (or w 120)) (h (or h 20)) (color (or color "#7cc4ff"))
        (vals (delq nil (mapcar (lambda (v) (and (numberp v) v)) values))))
    (if (or (not (cmacs-gnuseye-charts--svgp)) (< (length vals) 2))
        (cmacs-gnuseye-charts--unicode-spark vals)
      (let* ((mn (apply #'min vals)) (mx (apply #'max vals))
             (rng (max 1e-9 (- mx mn))) (n (length vals))
             (svg (svg-create w h))
             (pts (let ((i -1))
                    (mapcar (lambda (v)
                              (setq i (1+ i))
                              (cons (* (/ (float i) (1- n)) (1- w))
                                    (- (1- h) (* (/ (- v mn) rng) (- h 2)))))
                            vals))))
        (svg-polyline svg pts :stroke-color color :stroke-width 1.2 :fill "none")
        (propertize "spark" 'display (svg-image svg :ascent 'center))))))

(defun cmacs-gnuseye-charts--unicode-spark (vals)
  (if (< (length vals) 2) ""
    (let* ((mn (apply #'min vals)) (mx (apply #'max vals))
           (rng (max 1e-9 (- mx mn)))
           (blocks "▁▂▃▄▅▆▇█"))
      (mapconcat (lambda (v)
                   (string (aref blocks (min 7 (floor (* 7 (/ (- v mn) rng)))))))
                 vals ""))))

(defun cmacs-gnuseye-chart-treemap (pairs &optional w h)
  "A slice-and-dice treemap image for PAIRS ((LABEL . VALUE) …) (W x H px)."
  (let ((w (or w 240)) (h (or h 160))
        (pairs (seq-filter (lambda (p) (and (numberp (cdr p)) (> (cdr p) 0)))
                           pairs)))
    (if (or (not (cmacs-gnuseye-charts--svgp)) (null pairs))
        ""
      (let* ((svg (svg-create w h))
             (total (apply #'+ (mapcar #'cdr pairs)))
             (palette ["#3b6fb0" "#b04f3b" "#3bb06a" "#b0a13b" "#7a3bb0"
                       "#3bb0a8" "#b03b8e" "#6f7a8a"])
             (x 0.0) (i 0))
        (dolist (p (sort (copy-sequence pairs) (lambda (a b) (> (cdr a) (cdr b)))))
          (let ((cw (* w (/ (float (cdr p)) total))))
            (svg-rectangle svg x 0 (max 1 (- cw 1)) h
                           :fill (aref palette (mod i (length palette))))
            (when (> cw 36)
              (svg-text svg (truncate-string-to-width (format "%s" (car p)) 10)
                        :x (+ x 3) :y 14 :font-size 10 :fill "white"))
            (setq x (+ x cw) i (1+ i))))
        (propertize "treemap" 'display (svg-image svg :ascent 'center))))))

(provide 'cmacs-gnuseye-charts)
;;; cmacs-gnuseye-charts.el ends here
