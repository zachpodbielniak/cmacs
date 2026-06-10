;;; cmacs-gnuseye-measure.el --- GNU's Eye measurement tool  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Click two points on the globe to measure the great-circle distance and
;; initial bearing between them; the measured arc is drawn.  Uses the Phase-8
;; screen-to-globe ray-pick and the click hook.

;;; Code:

(require 'cmacs-gnuseye)

(defvar cmacs-gnuseye-measure--active nil)
(defvar cmacs-gnuseye-measure--first nil)

(defun cmacs-gnuseye-measure--click (buffer _id vx vy)
  "Click handler while measuring: capture points, then report + draw."
  (when cmacs-gnuseye-measure--active
    (let ((p (and (numberp vx) (numberp vy)
                  (ignore-errors (cmacs-gnuseye-screen-to-globe buffer vx vy)))))
      (cond
       ((null p)
        (message "Measure: clicked off the globe — click a point on it"))
       ((null cmacs-gnuseye-measure--first)
        (setq cmacs-gnuseye-measure--first p)
        (message "Measure: from %.3f, %.3f — click the second point"
                 (nth 0 p) (nth 1 p)))
       (t
        (let* ((a cmacs-gnuseye-measure--first) (b p)
               (km (/ (cmacs-gnuseye-haversine (nth 0 a) (nth 1 a)
                                               (nth 0 b) (nth 1 b))
                      1000.0))
               (brg (cmacs-gnuseye-bearing (nth 0 a) (nth 1 a)
                                           (nth 0 b) (nth 1 b)))
               (gc (cmacs-gnuseye-great-circle (nth 0 a) (nth 1 a)
                                               (nth 0 b) (nth 1 b) 48))
               (lats (apply #'vector (mapcar (lambda (x) (aref x 0))
                                             (append gc nil))))
               (lons (apply #'vector (mapcar (lambda (x) (aref x 1))
                                             (append gc nil)))))
          (ignore-errors (cmacs-gnuseye-add-coastline buffer lats lons #xffee44ff))
          (ignore-errors (cmacs-gnuseye-redraw buffer))
          (message "Measure: %s, bearing %.1f deg  (%s reloads the map to clear)"
                   (if (>= km 1000.0) (format "%.0f km / %.0f nmi"
                                              km (* km 0.539957))
                     (format "%.1f km" km))
                   brg "g")
          (setq cmacs-gnuseye-measure--first nil
                cmacs-gnuseye-measure--active nil)
          (remove-hook 'cmacs-gnuseye--click-functions
                       #'cmacs-gnuseye-measure--click)))))
    t))                                  ; consume the click

;;;###autoload
(defun cmacs-gnuseye-measure ()
  "Measure great-circle distance + bearing between two clicked globe points."
  (interactive)
  (setq cmacs-gnuseye-measure--active t cmacs-gnuseye-measure--first nil)
  (add-hook 'cmacs-gnuseye--click-functions #'cmacs-gnuseye-measure--click)
  (message "Measure: click the first point on the globe (then the second)"))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "M") #'cmacs-gnuseye-measure))

(provide 'cmacs-gnuseye-measure)
;;; cmacs-gnuseye-measure.el ends here
