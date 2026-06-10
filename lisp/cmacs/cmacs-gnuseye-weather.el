;;; cmacs-gnuseye-weather.el --- GNU's Eye weather + geo-events layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Several high-value, mostly key-free geo-event layers:
;;   quakes   USGS earthquakes (GeoJSON, no key)             default-on
;;   launches Launch Library 2 upcoming rocket launches      default-off
;;   fires    NASA FIRMS active fires (CSV, needs MAP_KEY)    default-off

;;; Code:

(require 'cmacs-gnuseye)

;;;; Earthquakes (USGS) ------------------------------------------------------

(defcustom cmacs-gnuseye-quakes-url
  "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson"
  "USGS earthquake GeoJSON feed (e.g. all_hour / all_day)."
  :type 'string
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-quakes--parse (data)
  (let (out)
    (dolist (f (alist-get 'features data))
      (let* ((geom (alist-get 'geometry f))
             (coords (alist-get 'coordinates geom))
             (props (alist-get 'properties f))
             (lon (nth 0 coords)) (lat (nth 1 coords)) (depth (nth 2 coords))
             (mag (alist-get 'mag props)))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "eq:%s" (alist-get 'id f))
                      :kind 'quake
                      :label (format "M%.1f" (or mag 0))
                      :lat lat :lon lon
                      :scale (max 0.6 (* (or mag 1.0) 0.5))
                      :data `((magnitude . ,mag)
                              (place . ,(alist-get 'place props))
                              (depth-km . ,depth)
                              (url . ,(alist-get 'url props))))
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-quakes--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-quakes-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-quakes--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer quakes
  :title "Earthquakes (USGS)"
  :group 'weather
  :kind 'quake
  :interval 300
  :default-on t
  :fetch #'cmacs-gnuseye-quakes--fetch)

;;;; Rocket launches (Launch Library 2) --------------------------------------

(defcustom cmacs-gnuseye-launches-url
  "https://ll.thespacedevs.com/2.2.0/launch/upcoming/?limit=20&mode=list"
  "Launch Library 2 upcoming-launches endpoint (no key; rate-limited)."
  :type 'string
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-launches--num (v)
  (cond ((numberp v) v) ((stringp v) (string-to-number v)) (t nil)))

(defun cmacs-gnuseye-launches--parse (data)
  (let (out)
    (dolist (r (alist-get 'results data))
      (let* ((pad (alist-get 'pad r))
             (lat (cmacs-gnuseye-launches--num (alist-get 'latitude pad)))
             (lon (cmacs-gnuseye-launches--num (alist-get 'longitude pad)))
             (prov (alist-get 'launch_service_provider r)))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "launch:%s" (alist-get 'id r))
                      :kind 'launch
                      :label (alist-get 'name r)
                      :lat lat :lon lon
                      :data `((net . ,(alist-get 'net r))
                              (provider . ,(and prov (alist-get 'name prov)))
                              (pad . ,(alist-get 'name pad))))
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-launches--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-launches-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-launches--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer launches
  :title "Rocket launches (Launch Library 2)"
  :group 'weather
  :kind 'launch
  :interval 1800
  :default-on nil
  :fetch #'cmacs-gnuseye-launches--fetch)

;;;; Wildfires (NASA FIRMS) --------------------------------------------------

(defcustom cmacs-gnuseye-fires-source "VIIRS_SNPP_NRT"
  "FIRMS data source (e.g. VIIRS_SNPP_NRT, MODIS_NRT)."
  :type 'string
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-fires--url ()
  (let ((key (cmacs-gnuseye-secret "FIRMS_MAP_KEY")))
    (and key (format
              "https://firms.modaps.eosdis.nasa.gov/api/area/csv/%s/%s/world/1"
              key cmacs-gnuseye-fires-source))))

(defun cmacs-gnuseye-fires--parse (csv)
  "Parse a FIRMS CSV string CSV into fire entities (lat,lon,...,frp,...)."
  (let ((lines (split-string csv "\n" t))
        (out nil) (i 0))
    (when lines (setq lines (cdr lines)))   ; drop header
    (dolist (line lines)
      (let* ((f (split-string line ","))
             (lat (string-to-number (or (nth 0 f) "")))
             (lon (string-to-number (or (nth 1 f) "")))
             (frp (and (nth 12 f) (string-to-number (nth 12 f))))
             (conf (nth 9 f)))
        (when (and (/= lat 0.0) (/= lon 0.0))
          (push (list :id (format "fire:%d" (setq i (1+ i)))
                      :kind 'fire
                      :label "fire"
                      :lat lat :lon lon
                      :scale (if (and frp (> frp 0))
                                 (min 2.0 (+ 0.6 (/ frp 50.0))) 0.8)
                      :data `((frp . ,frp) (confidence . ,conf)))
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-fires--fetch (cb)
  (let ((url (cmacs-gnuseye-fires--url)))
    (if (not url)
        (funcall cb nil)
      (cmacs-gnuseye-fetch-text
       url
       (lambda (body) (funcall cb (and body (cmacs-gnuseye-fires--parse body))))))))

(cmacs-gnuseye-define-layer fires
  :title "Wildfires (NASA FIRMS)"
  :group 'weather
  :kind 'fire
  :interval 900
  :default-on nil
  :needs-key "FIRMS_MAP_KEY"
  :fetch #'cmacs-gnuseye-fires--fetch)

(provide 'cmacs-gnuseye-weather)
;;; cmacs-gnuseye-weather.el ends here
