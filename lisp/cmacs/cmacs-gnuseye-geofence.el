;;; cmacs-gnuseye-geofence.el --- GNU's Eye geofence alerts  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Geofences: named circular zones tested against tracked entities each tick
;; (throttled).  When an entity enters or leaves a fence, a podomation event
;; (`on_geofence_enter' / `on_geofence_exit') is emitted with the entity data,
;; so `.pod' rules can react (notify, log, webhook).  A fence can draw a
;; range ring on the globe.

;;; Code:

(require 'cmacs-gnuseye)

(cl-defstruct (cmacs-gnuseye-geofence (:constructor cmacs-gnuseye--make-geofence))
  name lat lon radius-km kinds inside ring)

(defvar cmacs-gnuseye--geofences (make-hash-table :test 'equal)
  "Geofence name -> `cmacs-gnuseye-geofence'.")

(defcustom cmacs-gnuseye-geofence-interval 2.0
  "Minimum seconds between geofence evaluations (throttles the tick)."
  :type 'number :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--geofence-last 0.0)

;;;###autoload
(defun cmacs-gnuseye-add-geofence (name lat lon radius-km &optional kinds)
  "Add a geofence NAME: a circle of RADIUS-KM about (LAT LON).
KINDS, if non-nil, restricts it to those entity kinds.  Emits podomation
events on enter/exit."
  (interactive
   (let ((vc (and cmacs-gnuseye-buffer
                  (ignore-errors (cmacs-gnuseye-view-center cmacs-gnuseye-buffer)))))
     (list (read-string "Geofence name: ")
           (read-number "Lat: " (and (consp vc) (nth 0 vc)))
           (read-number "Lon: " (and (consp vc) (nth 1 vc)))
           (read-number "Radius (km): " 200.0))))
  (puthash name
           (cmacs-gnuseye--make-geofence
            :name name :lat lat :lon lon :radius-km radius-km
            :kinds kinds :inside (make-hash-table :test 'equal))
           cmacs-gnuseye--geofences)
  (cmacs-gnuseye-geofence-add-hook)
  (message "GNU's Eye: geofence %s (%.0f km)" name radius-km))

(defun cmacs-gnuseye-remove-geofence (name)
  "Remove geofence NAME and its ring."
  (interactive (list (completing-read "Remove geofence: "
                                      (hash-table-keys cmacs-gnuseye--geofences)
                                      nil t)))
  (let ((g (gethash name cmacs-gnuseye--geofences)))
    (when (and g (cmacs-gnuseye-geofence-ring g)) (cmacs-gnuseye-geofence-ring-off g)))
  (remhash name cmacs-gnuseye--geofences))

(defun cmacs-gnuseye--geofence-emit (event g e dkm)
  (when (fboundp 'cmacs-gnuseye-haversine)   ; geo built
    (when (fboundp 'cmacs-podomation-emit-event)
      (ignore-errors
        (cmacs-podomation-emit-event
         event
         `(("fence"       . ,(cmacs-gnuseye-geofence-name g))
           ("entity_id"   . ,(format "%s" (plist-get e :id)))
           ("kind"        . ,(format "%s" (plist-get e :kind)))
           ("label"       . ,(or (plist-get e :label) ""))
           ("lat"         . ,(format "%.5f" (or (plist-get e :lat) 0.0)))
           ("lon"         . ,(format "%.5f" (or (plist-get e :lon) 0.0)))
           ("distance_km" . ,(format "%.2f" dkm))
           ("layer"       . ,(format "%s" (plist-get e :layer)))))))))

(defun cmacs-gnuseye--geofence-eval ()
  "Test every entity against every geofence, emitting enter/exit events."
  (let ((now (float-time)))
    (when (>= (- now cmacs-gnuseye--geofence-last) cmacs-gnuseye-geofence-interval)
      (setq cmacs-gnuseye--geofence-last now)
      (maphash
       (lambda (_ g)
         (let ((seen (make-hash-table :test 'equal))
               (inside (cmacs-gnuseye-geofence-inside g))
               (r (* 1000.0 (cmacs-gnuseye-geofence-radius-km g)))
               (kinds (cmacs-gnuseye-geofence-kinds g)))
           (maphash
            (lambda (id e)
              (when (or (null kinds) (memq (plist-get e :kind) kinds))
                (let ((dm (ignore-errors
                            (cmacs-gnuseye-haversine
                             (cmacs-gnuseye-geofence-lat g)
                             (cmacs-gnuseye-geofence-lon g)
                             (or (plist-get e :lat) 0.0)
                             (or (plist-get e :lon) 0.0)))))
                  (when (and (numberp dm) (<= dm r))
                    (puthash id t seen)
                    (unless (gethash id inside)
                      (puthash id t inside)
                      (cmacs-gnuseye--geofence-emit "on_geofence_enter" g e
                                                    (/ dm 1000.0)))))))
            cmacs-gnuseye--id-index)
           ;; Exits: ids previously inside that are no longer seen.
           (let (gone)
             (maphash (lambda (id _) (unless (gethash id seen) (push id gone)))
                      inside)
             (dolist (id gone)
               (remhash id inside)
               (let ((e (gethash id cmacs-gnuseye--id-index)))
                 (when e (cmacs-gnuseye--geofence-emit "on_geofence_exit" g e 0.0)))))))
       cmacs-gnuseye--geofences))))

(defun cmacs-gnuseye--geofence-tick (_buf _now _dt)
  (when (> (hash-table-count cmacs-gnuseye--geofences) 0)
    (ignore-errors (cmacs-gnuseye--geofence-eval))))

(defun cmacs-gnuseye-geofence-add-hook ()
  (add-hook 'cmacs-gnuseye--tick-functions #'cmacs-gnuseye--geofence-tick))

;;; Range-ring visualisation --------------------------------------------------

(defun cmacs-gnuseye-geofence-ring-on (g)
  "Draw G's range ring on the globe (persistent filled footprint)."
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-gnuseye-circle-points))
    (let* ((ring (cmacs-gnuseye-circle-points
                  (cmacs-gnuseye-geofence-lat g) (cmacs-gnuseye-geofence-lon g)
                  (* 1000.0 (cmacs-gnuseye-geofence-radius-km g)) 48))
           (lats (apply #'vector (mapcar (lambda (p) (aref p 0)) (append ring nil))))
           (lons (apply #'vector (mapcar (lambda (p) (aref p 1)) (append ring nil)))))
      (ignore-errors
        (cmacs-gnuseye-add-polygon cmacs-gnuseye-buffer lats lons #xffd23a55 t))
      (setf (cmacs-gnuseye-geofence-ring g) t))))

(defun cmacs-gnuseye-geofence-ring-off (g)
  "Remove all geofence rings (persistent polygons)."
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
    (ignore-errors (cmacs-gnuseye-clear-polygons cmacs-gnuseye-buffer t))
    (setf (cmacs-gnuseye-geofence-ring g) nil)))

;;;###autoload
(defun cmacs-gnuseye-geofence-here (name radius-km)
  "Add a geofence NAME of RADIUS-KM at the current camera subpoint, with a ring."
  (interactive "sGeofence name: \nnRadius (km): ")
  (let ((vc (and cmacs-gnuseye-buffer
                 (ignore-errors (cmacs-gnuseye-view-center cmacs-gnuseye-buffer)))))
    (when (consp vc)
      (cmacs-gnuseye-add-geofence name (nth 0 vc) (nth 1 vc) radius-km)
      (cmacs-gnuseye-geofence-ring-on (gethash name cmacs-gnuseye--geofences)))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "G") #'cmacs-gnuseye-geofence-here))

(provide 'cmacs-gnuseye-geofence)
;;; cmacs-gnuseye-geofence.el ends here
