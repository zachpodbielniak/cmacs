;;; cmacs-gnuseye-infra.el --- GNU's Eye infrastructure layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Keyless infrastructure layers, in the `infra' category:
;;   cables  submarine telecom cables (TeleGeography GeoJSON) as polylines.
;;   ports   a built-in set of major seaports / chokepoints (static, offline).
;;
;; Cyber-threat IP feeds (Feodo/URLhaus) are a planned follow-on; they need
;; IP->location resolution, so they land with the geolocation helper.

;;; Code:

(require 'cmacs-gnuseye)

;;;; Submarine cables (TeleGeography) -----------------------------------------

(defcustom cmacs-gnuseye-cables-url
  "https://www.submarinecablemap.com/api/v3/cable/cable-geo.json"
  "Submarine-cable GeoJSON (TeleGeography; no key).  Fetched once."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cables-max 600
  "Maximum cable segments to draw."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-cables--seg->trail (seg)
  "GeoJSON SEG (list of (LON LAT)) -> a :trail of (LAT LON) pairs."
  (mapcar (lambda (p) (list (float (or (nth 1 p) 0.0))
                            (float (or (nth 0 p) 0.0))))
          seg))

(defun cmacs-gnuseye-cables--parse (data)
  "Parse a submarine-cable FeatureCollection DATA into cable polyline entities."
  (let ((out nil) (n 0))
    (catch 'done
      (dolist (f (alist-get 'features data))
        (let* ((props (alist-get 'properties f))
               (name (or (alist-get 'name props) "cable"))
               (id (or (alist-get 'id props) name))
               (geom (alist-get 'geometry f))
               (gt (alist-get 'type geom))
               (coords (alist-get 'coordinates geom))
               (segs (cond ((equal gt "MultiLineString") coords)
                           ((equal gt "LineString") (list coords))))
               (si 0))
          (dolist (seg segs)
            (when (>= (length seg) 2)
              (let* ((trail (cmacs-gnuseye-cables--seg->trail seg))
                     (mid (nth (/ (length trail) 2) trail)))
                (push (list :id (format "cable:%s:%d" id si)
                            :kind 'cable
                            :label (and (zerop si) name)
                            :label-mode 2
                            :lat (nth 0 mid) :lon (nth 1 mid)
                            :scale 0.4
                            :trail trail
                            :data `((cable . ,name)))
                      out)
                (setq si (1+ si) n (1+ n))
                (when (>= n cmacs-gnuseye-cables-max) (throw 'done nil))))))))
    (nreverse out)))

(defun cmacs-gnuseye-cables--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-cables-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-cables--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer cables
  :title "Submarine cables (TeleGeography)"
  :group 'infra
  :kind 'cable
  :interval nil                         ; static; fetch once on enable
  :default-on nil
  :fetch #'cmacs-gnuseye-cables--fetch)

;;;; Ports & chokepoints (built-in static set) --------------------------------

(defconst cmacs-gnuseye-ports
  '(("Shanghai" 31.23 121.49) ("Singapore" 1.26 103.83)
    ("Ningbo-Zhoushan" 29.87 121.55) ("Rotterdam" 51.95 4.14)
    ("Busan" 35.10 129.04) ("Los Angeles/Long Beach" 33.74 -118.26)
    ("Hamburg" 53.54 9.93) ("Antwerp" 51.28 4.32)
    ("New York/New Jersey" 40.67 -74.05) ("Dubai (Jebel Ali)" 25.01 55.06)
    ("Hong Kong" 22.30 114.18) ("Tanjung Pelepas" 1.36 103.55)
    ("Suez Canal (Port Said)" 31.26 32.30) ("Panama Canal (Colon)" 9.36 -79.90)
    ("Strait of Hormuz" 26.57 56.25) ("Strait of Malacca" 2.50 101.00)
    ("Bab-el-Mandeb" 12.58 43.33) ("Bosphorus (Istanbul)" 41.12 29.07)
    ("Gibraltar" 36.01 -5.36) ("Cape of Good Hope" -34.36 18.47)
    ("Santos" -23.96 -46.30) ("Valencia" 39.44 -0.31)
    ("Piraeus" 37.94 23.64) ("Felixstowe" 51.95 1.31)
    ("Savannah" 32.08 -81.10) ("Colombo" 6.94 79.85))
  "Major seaports and maritime chokepoints (name lat lon).")

(defun cmacs-gnuseye-ports--fetch (cb)
  (funcall cb
           (mapcar (lambda (p)
                     (list :id (format "port:%s" (nth 0 p))
                           :kind 'port
                           :label (nth 0 p)
                           :lat (nth 1 p) :lon (nth 2 p)
                           :data `((name . ,(nth 0 p)))))
                   cmacs-gnuseye-ports)))

(cmacs-gnuseye-define-layer ports
  :title "Ports & chokepoints"
  :group 'infra
  :kind 'port
  :interval nil
  :default-on nil
  :fetch #'cmacs-gnuseye-ports--fetch)

;;;; Cyber-threat IPs (Feodo Tracker, geolocated) -----------------------------

(require 'cmacs-gnuseye-geoloc)

(defcustom cmacs-gnuseye-cyber-url
  "https://feodotracker.abuse.ch/downloads/ipblocklist.json"
  "Feodo Tracker C2 IP blocklist (keyless JSON array)."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cyber-max 30
  "Maximum C2 IPs to geolocate + plot (bounded by the geoloc rate limit)."
  :type 'integer :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-cyber--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-cyber-url
   (lambda (data)
     (let* ((rows (seq-take (or data nil) cmacs-gnuseye-cyber-max))
            (out nil) (pending (length rows)))
       (if (zerop pending)
           (funcall cb nil)
         (dolist (r rows)
           (let ((ip (alist-get 'ip_address r))
                 (mal (alist-get 'malware r)))
             (if (not (stringp ip))
                 (when (zerop (setq pending (1- pending))) (funcall cb out))
               (cmacs-gnuseye-geolocate-ip
                ip
                (lambda (res)
                  (when res
                    (push (list :id (format "cyber:%s" ip)
                                :kind 'cyber :label ip
                                :lat (nth 0 res) :lon (nth 1 res)
                                :data `((ip . ,ip) (malware . ,mal)
                                        (country . ,(nth 2 res))))
                          out))
                  (when (zerop (setq pending (1- pending)))
                    (funcall cb out))))))))))
   nil 'list))

(cmacs-gnuseye-define-layer cyber
  :title "Cyber C2 servers (Feodo)"
  :group 'infra
  :kind 'cyber
  :interval 3600
  :default-on nil
  :cluster t
  :fetch #'cmacs-gnuseye-cyber--fetch)

(provide 'cmacs-gnuseye-infra)
;;; cmacs-gnuseye-infra.el ends here
