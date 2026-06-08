;;; cmacs-gnuseye-conflict.el --- GNU's Eye conflict/geopolitics layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Keyless conflict / geopolitics layers, in the `conflict' category:
;;   gdelt  GDELT GEO 2.0 geolocated news mentions for a query (default a
;;          conflict query), each location a point sized by mention volume.
;;          No key; ~1 request/second, so the refresh interval is generous.
;;
;; UCDP/ACLED battle-event layers are planned follow-ons (ACLED needs a key).

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-gdelt-query
  "(conflict OR airstrike OR shelling OR offensive OR clashes)"
  "GDELT query for the geolocated-news layer (GDELT query syntax)."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-gdelt-timespan "1d"
  "GDELT lookback window (e.g. 15min, 1h, 1d)."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-gdelt-max 250
  "Maximum GDELT locations to plot."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-gdelt--url ()
  (format (concat "https://api.gdeltproject.org/api/v2/geo/geo"
                  "?query=%s&format=GeoJSON&timespan=%s")
          (url-hexify-string cmacs-gnuseye-gdelt-query)
          (url-hexify-string cmacs-gnuseye-gdelt-timespan)))

(defun cmacs-gnuseye-gdelt--parse (data)
  "Parse a GDELT GEO GeoJSON DATA into geolocated event entities."
  (let ((out nil) (n 0))
    (catch 'done
      (dolist (f (alist-get 'features data))
        (let* ((geom (alist-get 'geometry f))
               (coords (alist-get 'coordinates geom))
               (props (alist-get 'properties f))
               (lon (nth 0 coords)) (lat (nth 1 coords))
               (name (alist-get 'name props))
               (count (alist-get 'count props)))
          (when (and (numberp lat) (numberp lon))
            (push (list :id (format "gdelt:%s:%d" (or name "?") n)
                        :kind 'event
                        :label (and name (format "%s" name))
                        :lat (float lat) :lon (float lon)
                        :scale (max 0.6 (min 2.0
                                            (* 0.35 (log (+ 2.0 (or count 1))))))
                        :data `((mentions . ,count)
                                (query . ,cmacs-gnuseye-gdelt-query)
                                (html . ,(alist-get 'html props))))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-gdelt-max) (throw 'done nil))))))
    (nreverse out)))

(defun cmacs-gnuseye-gdelt--fetch (cb)
  (cmacs-gnuseye-fetch-json
   (cmacs-gnuseye-gdelt--url)
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-gdelt--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer gdelt
  :title "Geolocated news (GDELT)"
  :group 'conflict
  :kind 'event
  :interval 900
  :default-on nil
  :cluster t
  :fetch #'cmacs-gnuseye-gdelt--fetch)

(provide 'cmacs-gnuseye-conflict)
;;; cmacs-gnuseye-conflict.el ends here
