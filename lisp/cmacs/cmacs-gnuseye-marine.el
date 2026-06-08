;;; cmacs-gnuseye-marine.el --- GNU's Eye marine-vessel layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Marine vessels via AIS.  NOTE: free *global* AIS is hard -- it is mostly
;; websocket + key (aisstream.io) or regional/SDR.  This layer fetches a
;; vessel JSON feed from `cmacs-gnuseye-marine-url' (default nil = off) so
;; you can point it at a regional open-AIS REST endpoint or a LAN
;; AIS-catcher / rtl-ais JSON server.  It parses a flexible record shape
;; (mmsi/lat/lon/cog/sog/name under common key spellings).  Off by default.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-marine-url nil
  "URL of a vessel JSON feed (array of objects), or nil to disable.
Each object should provide a latitude, longitude, and ideally an MMSI,
course-over-ground, speed-over-ground and name under common key names."
  :type '(choice (const :tag "Disabled" nil) (string :tag "URL"))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-marine-max 300
  "Maximum number of vessel markers to render."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-marine--get (obj &rest keys)
  "Return the first present value among KEYS in alist OBJ."
  (catch 'hit
    (dolist (k keys)
      (let ((v (alist-get k obj)))
        (when (and v (not (eq v :null))) (throw 'hit v))))
    nil))

(defun cmacs-gnuseye-marine--parse (data)
  "Parse a vessel array DATA (list of alists) into ship entities."
  (let ((records (if (and (listp data) (alist-get 'features data))
                     (alist-get 'features data)   ; GeoJSON
                   data))
        (out nil) (n 0))
    (catch 'done
      (dolist (r records)
        (let* ((props (or (alist-get 'properties r) r))
               (lat (cmacs-gnuseye-marine--get props 'lat 'latitude 'LAT 'y))
               (lon (cmacs-gnuseye-marine--get props 'lon 'longitude 'LON 'lng 'x))
               (mmsi (cmacs-gnuseye-marine--get props 'mmsi 'MMSI 'userid))
               (name (cmacs-gnuseye-marine--get props 'name 'shipname 'NAME))
               (cog (cmacs-gnuseye-marine--get props 'cog 'course 'heading 'COG))
               (sog (cmacs-gnuseye-marine--get props 'sog 'speed 'SOG)))
          (when (and (numberp lat) (numberp lon))
            ;; AIS speed-over-ground is knots; store m/s so the shared
            ;; dead-reckoning :advance moves the vessel correctly.
            (push (list :id (format "ship:%s" (or mmsi name lat))
                        :kind 'ship
                        :label (and name (format "%s" name))
                        :lat lat :lon lon
                        :heading (if (numberp cog) cog -1)
                        :speed (and (numberp sog) (* sog 0.514444))
                        :data `((mmsi . ,mmsi) (sog-kt . ,sog) (cog . ,cog)))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-marine-max) (throw 'done nil))))))
    (nreverse out)))

(defun cmacs-gnuseye-marine--fetch (cb)
  (if (not cmacs-gnuseye-marine-url)
      (funcall cb nil)
    (cmacs-gnuseye-fetch-json
     cmacs-gnuseye-marine-url
     (lambda (data) (funcall cb (and data (cmacs-gnuseye-marine--parse data))))
     nil 'list)))

(cmacs-gnuseye-define-layer vessels
  :title "Marine vessels (AIS — set cmacs-gnuseye-marine-url)"
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
