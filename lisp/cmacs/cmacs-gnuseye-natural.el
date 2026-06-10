;;; cmacs-gnuseye-natural.el --- GNU's Eye natural-event layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Keyless natural-event layers, all in the `natural' category:
;;   natural-events  NASA EONET v3 -- a single rich feed of open events
;;                   (volcanoes, severe storms, wildfires, icebergs/sea-ice,
;;                   floods, landslides, ...), each a point marker.   no key
;;   nws-alerts      US NWS active alerts as filled alert ZONES (polygons),
;;                   coloured by severity, plus a marker at the centroid.  no
;;                   key (a descriptive User-Agent is required, set below).

;;; Code:

(require 'cmacs-gnuseye)

;;;; NASA EONET (Earth Observatory Natural Event Tracker) ---------------------

(defcustom cmacs-gnuseye-eonet-url
  "https://eonet.gsfc.nasa.gov/api/v3/events?status=open&limit=200"
  "NASA EONET v3 open-events endpoint (no key)."
  :type 'string
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-eonet--kind (cat-id)
  "Map an EONET category id CAT-ID to a gnuseye marker kind."
  (pcase cat-id
    ("wildfires"    'fire)
    ("volcanoes"    'volcano)
    ("severeStorms" 'storm)
    ("earthquakes"  'quake)
    ("seaLakeIce"   'event)
    (_              'event)))

(defun cmacs-gnuseye-eonet--parse (data)
  "Parse an EONET events response DATA into point entities (latest fix each)."
  (let (out)
    (dolist (ev (alist-get 'events data))
      (let* ((cats (alist-get 'categories ev))
             (cat  (and cats (alist-get 'id (car cats))))
             (kind (cmacs-gnuseye-eonet--kind cat))
             (geoms (alist-get 'geometry ev))
             (g (car (last geoms)))               ; most recent fix
             (gtype (and g (alist-get 'type g)))
             (coords (and g (alist-get 'coordinates g))))
        (when (and g (equal gtype "Point") (consp coords))
          (let ((lon (nth 0 coords)) (lat (nth 1 coords)))
            (when (and (numberp lat) (numberp lon))
              (push (list :id (format "eonet:%s" (alist-get 'id ev))
                          :kind kind
                          :label (alist-get 'title ev)
                          :lat (float lat) :lon (float lon)
                          :data `((category . ,cat)
                                  (date . ,(alist-get 'date g))
                                  (link . ,(alist-get 'link ev))))
                    out))))))
    (nreverse out)))

(defun cmacs-gnuseye-eonet--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-eonet-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-eonet--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer natural-events
  :title "Natural events (NASA EONET)"
  :group 'natural
  :kind 'event
  :interval 1800
  :default-on nil
  :fetch #'cmacs-gnuseye-eonet--fetch)

;;;; US NWS active alerts (filled severity zones) -----------------------------

(defcustom cmacs-gnuseye-nws-url
  "https://api.weather.gov/alerts/active"
  "US NWS active-alerts GeoJSON endpoint (no key)."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-nws-user-agent
  "cmacs-gnuseye/1.0 (https://github.com/; contact via cmacs)"
  "User-Agent sent to api.weather.gov (NWS returns 403 without a descriptive one)."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-nws-max 150
  "Maximum NWS alert zones to render (polygon-bearing alerts only)."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-nws--severity-color (sev)
  "Translucent fill colour for NWS severity SEV (alpha applied by the fill)."
  (pcase sev
    ("Extreme"  "#ff2a2a")
    ("Severe"   "#ff7a2a")
    ("Moderate" "#ffd23a")
    ("Minor"    "#9ad0ff")
    (_          "#b0b0ff")))

(defun cmacs-gnuseye-nws--ring->poly (ring)
  "GeoJSON RING (list of (LON LAT)) -> vector of [LAT LON] polygon vertices."
  (vconcat (mapcar (lambda (p) (vector (float (nth 1 p)) (float (nth 0 p))))
                   (cmacs-gnuseye--decimate ring 1))))

(defun cmacs-gnuseye-nws--centroid (ring)
  "Mean (LAT . LON) of GeoJSON RING (list of (LON LAT))."
  (let ((slat 0.0) (slon 0.0) (n 0))
    (dolist (p ring)
      (setq slat (+ slat (or (nth 1 p) 0.0))
            slon (+ slon (or (nth 0 p) 0.0)) n (1+ n)))
    (and (> n 0) (cons (/ slat n) (/ slon n)))))

(defun cmacs-gnuseye-nws--parse (data)
  "Parse an NWS active-alerts FeatureCollection DATA into alert-zone entities.
Only polygon-bearing alerts (warnings) are kept; each becomes a filled zone
plus a centroid marker coloured by severity."
  (let ((out nil) (n 0))
    (catch 'done
      (dolist (f (alist-get 'features data))
        (let* ((props (alist-get 'properties f))
               (geom (alist-get 'geometry f))
               (gt (and geom (alist-get 'type geom)))
               (coords (and geom (alist-get 'coordinates geom)))
               (ring (cond ((equal gt "Polygon") (car coords))
                           ((equal gt "MultiPolygon") (car (car coords)))))
               (event (alist-get 'event props))
               (sev (alist-get 'severity props)))
          (when (and ring (>= (length ring) 3))
            (let ((c (cmacs-gnuseye-nws--centroid ring)))
              (when c
                (push (list :id (format "nws:%s" (or (alist-get 'id props)
                                                     (alist-get 'id f) n))
                            :kind 'alert
                            :label event
                            :lat (car c) :lon (cdr c)
                            :color (cmacs-gnuseye-nws--severity-color sev)
                            :polygon (cmacs-gnuseye-nws--ring->poly ring)
                            :data `((event . ,event) (severity . ,sev)
                                    (area . ,(alist-get 'areaDesc props))
                                    (headline . ,(alist-get 'headline props))))
                      out)
                (setq n (1+ n))
                (when (>= n cmacs-gnuseye-nws-max) (throw 'done nil))))))))
    (nreverse out)))

(defun cmacs-gnuseye-nws--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-nws-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-nws--parse data))))
   `(("User-Agent" . ,cmacs-gnuseye-nws-user-agent)
     ("Accept" . "application/geo+json"))
   'list))

(cmacs-gnuseye-define-layer nws-alerts
  :title "Weather alerts (US NWS zones)"
  :group 'natural
  :kind 'alert
  :interval 300
  :default-on nil
  :fetch #'cmacs-gnuseye-nws--fetch)

(provide 'cmacs-gnuseye-natural)
;;; cmacs-gnuseye-natural.el ends here
