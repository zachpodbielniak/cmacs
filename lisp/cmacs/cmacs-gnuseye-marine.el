;;; cmacs-gnuseye-marine.el --- GNU's Eye marine-vessel layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Marine vessels via AIS.  Free *global* AIS does not exist as keyless REST
;; -- it is websocket + key (aisstream.io) or regional -- so the default feed
;; is the Finnish Transport Infrastructure Agency's open Digitraffic AIS
;; (keyless GeoJSON; live coverage of the Baltic / Gulf of Finland, one of
;; the densest shipping areas in the world).  Point
;; `cmacs-gnuseye-marine-url' at any other vessel JSON feed (a regional
;; open-AIS REST endpoint or a LAN AIS-catcher / rtl-ais server): the parser
;; reads both GeoJSON FeatureCollections (lat/lon from geometry) and flat
;; arrays (mmsi/lat/lon/cog/sog/name under common key spellings).

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-marine-url
  "https://meri.digitraffic.fi/api/ais/v1/locations"
  "URL of a vessel JSON/GeoJSON feed, or nil to disable.
The default is Digitraffic's open AIS (keyless; Baltic coverage).  Any feed
whose records carry a position (GeoJSON geometry, or lat/lon fields) and
ideally MMSI, course- and speed-over-ground works."
  :type '(choice (const :tag "Disabled" nil) (string :tag "URL"))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-marine-urls nil
  "Additional vessel feed URLs merged with `cmacs-gnuseye-marine-url'.
Coverage is the union of the feeds: the keyless default only covers the
Baltic (free global AIS does not exist as keyless REST), so add other
regional open-AIS endpoints or LAN AIS-catcher / rtl-ais servers here to
widen it.  Records are merged by MMSI."
  :type '(repeat string)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-marine-max 1000
  "Maximum number of vessels kept from one fetch."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-marine-marker-scale 0.15
  "Ship marker size multiplier (ships are dense; keep them small).
Combined with the zoom scaling, ships keep a constant on-screen size."
  :type 'number
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-marine--get (obj &rest keys)
  "Return the first present value among KEYS in alist OBJ."
  (catch 'hit
    (dolist (k keys)
      (let ((v (alist-get k obj)))
        (when (and v (not (eq v :null))) (throw 'hit v))))
    nil))

(defun cmacs-gnuseye-marine--parse (data)
  "Parse a vessel feed DATA (GeoJSON FeatureCollection or array) into entities."
  (let ((records (if (and (listp data) (alist-get 'features data))
                     (alist-get 'features data)   ; GeoJSON
                   data))
        (out nil) (n 0))
    (catch 'done
      (dolist (r records)
        (let* ((props (or (alist-get 'properties r) r))
               (geom (alist-get 'geometry r))
               (coords (and geom (alist-get 'coordinates geom)))
               (lat (or (cmacs-gnuseye-marine--get props 'lat 'latitude 'LAT 'y)
                        (and (consp coords) (nth 1 coords))))
               (lon (or (cmacs-gnuseye-marine--get props 'lon 'longitude 'LON
                                                   'lng 'x)
                        (and (consp coords) (nth 0 coords))))
               (mmsi (or (cmacs-gnuseye-marine--get props 'mmsi 'MMSI 'userid)
                         (alist-get 'mmsi r)))
               (name (cmacs-gnuseye-marine--get props 'name 'shipname 'NAME))
               (cog (cmacs-gnuseye-marine--get props 'cog 'course 'COG))
               (hdg (cmacs-gnuseye-marine--get props 'heading 'HEADING))
               (sog (cmacs-gnuseye-marine--get props 'sog 'speed 'SOG))
               ;; AIS "not available" sentinels: heading 511, cog 360.
               (course (cond ((and (numberp hdg) (< hdg 360)) hdg)
                             ((and (numberp cog) (< cog 360)) cog)
                             (t -1))))
          (when (and (numberp lat) (numberp lon))
            ;; AIS speed-over-ground is knots; store m/s so the shared
            ;; dead-reckoning :advance moves the vessel correctly.
            (push (list :id (format "ship:%s" (or mmsi name lat))
                        :kind 'ship
                        :label (cond (name (format "%s" name))
                                     (mmsi (format "%s" mmsi)))
                        :lat (float lat) :lon (float lon)
                        :heading course
                        :scale cmacs-gnuseye-marine-marker-scale
                        :speed (and (numberp sog) (* sog 0.514444))
                        :data `((mmsi . ,mmsi) (sog-kt . ,sog) (cog . ,cog)))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-marine-max) (throw 'done nil))))))
    (nreverse out)))

(defun cmacs-gnuseye-marine--fetch (cb)
  "Fetch every configured AIS feed, merge by vessel id, and call CB once."
  (let ((urls (delete-dups
               (delq nil (cons cmacs-gnuseye-marine-url
                               (copy-sequence cmacs-gnuseye-marine-urls))))))
    (if (null urls)
        (progn
          (message "GNU's Eye: set `cmacs-gnuseye-marine-url' to an AIS feed")
          (funcall cb nil))
      (let ((pending (length urls))
            (seen (make-hash-table :test 'equal))
            (acc nil))
        (dolist (u urls)
          (cmacs-gnuseye-fetch-json
           u
           (lambda (data)
             (dolist (e (and data (cmacs-gnuseye-marine--parse data)))
               (let ((id (plist-get e :id)))
                 (unless (gethash id seen)
                   (puthash id t seen)
                   (push e acc))))
             (when (zerop (setq pending (1- pending)))
               (funcall cb (nreverse acc))))
           '(("Digitraffic-User" . "cmacs-gnuseye/1.0"))
           'list))))))

(cmacs-gnuseye-define-layer vessels
  :title "Marine vessels (AIS, Baltic default)"
  :group 'marine
  :kind 'ship
  :interval 30
  :default-on nil
  :cluster t
  :fetch #'cmacs-gnuseye-marine--fetch
  ;; Glide vessels along their course between AIS fixes; fetches correct them.
  :advance #'cmacs-gnuseye-dead-reckon-layer)

(provide 'cmacs-gnuseye-marine)
;;; cmacs-gnuseye-marine.el ends here
