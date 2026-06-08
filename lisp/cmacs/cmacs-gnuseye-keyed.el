;;; cmacs-gnuseye-keyed.el --- GNU's Eye keyed / graceful-off layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Layers that need an API key or a configured URL.  They register normally
;; but stay off (showing "needs KEY") until configured, so the default build
;; is unaffected.
;;
;;   bases   notable military bases & spaceports (static, keyless).
;;   acled   ACLED armed-conflict events (needs ACLED_KEY + ACLED_EMAIL).
;;   sirens  Israel Home-Front (OREF) / regional alert feed (configurable URL).
;;
;; Windy webcams live in `cmacs-gnuseye-media.el'.  Cloudflare Radar outages
;; are a planned follow-on (their annotations are country-level and need a
;; country -> centroid geocode).

;;; Code:

(require 'cmacs-gnuseye)

;;;; Military bases & spaceports (static) -------------------------------------

(defconst cmacs-gnuseye-bases
  '(;; (NAME LAT LON KIND)
    ("Ramstein AB" 49.44 7.60 base) ("Diego Garcia" -7.31 72.41 base)
    ("Guantanamo Bay" 19.90 -75.10 base) ("Incirlik AB" 37.00 35.43 base)
    ("Al Udeid AB" 25.12 51.32 base) ("Camp Humphreys" 36.97 127.03 base)
    ("Kadena AB" 26.36 127.77 base) ("Pearl Harbor" 21.36 -157.95 base)
    ("Yokosuka" 35.29 139.67 base) ("Naval Base San Diego" 32.68 -117.13 base)
    ("Bagram" 34.95 69.27 base) ("Thule AB" 76.53 -68.70 base)
    ("Andersen AFB (Guam)" 13.58 144.93 base) ("Djibouti (Lemonnier)" 11.55 43.16 base)
    ;; Spaceports
    ("Kennedy Space Center" 28.57 -80.65 spaceport)
    ("Vandenberg SFB" 34.74 -120.57 spaceport)
    ("Baikonur" 45.92 63.34 spaceport) ("Kourou (CSG)" 5.24 -52.77 spaceport)
    ("Tanegashima" 30.40 130.97 spaceport) ("Jiuquan" 40.96 100.30 spaceport)
    ("Wenchang" 19.61 110.95 spaceport) ("Sriharikota" 13.72 80.23 spaceport)
    ("Plesetsk" 62.93 40.57 spaceport) ("Boca Chica (Starbase)" 25.997 -97.156 spaceport))
  "Notable military bases and spaceports (NAME LAT LON KIND).")

(defun cmacs-gnuseye-bases--fetch (cb)
  (funcall cb
           (mapcar (lambda (b)
                     (list :id (format "base:%s" (nth 0 b))
                           :kind (nth 3 b)
                           :label (nth 0 b)
                           :lat (nth 1 b) :lon (nth 2 b)
                           :data `((name . ,(nth 0 b)) (type . ,(nth 3 b)))))
                   cmacs-gnuseye-bases)))

(cmacs-gnuseye-define-layer bases
  :title "Military bases & spaceports"
  :group 'infra
  :kind 'base
  :interval nil
  :default-on nil
  :fetch #'cmacs-gnuseye-bases--fetch)

;;;; ACLED armed-conflict events ----------------------------------------------

(defcustom cmacs-gnuseye-acled-limit 500
  "Maximum ACLED events to fetch."
  :type 'integer :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-acled--num (v)
  (cond ((numberp v) v) ((stringp v) (string-to-number v)) (t nil)))

(defun cmacs-gnuseye-acled--parse (data)
  (let (out)
    (dolist (r (alist-get 'data data))
      (let ((lat (cmacs-gnuseye-acled--num (alist-get 'latitude r)))
            (lon (cmacs-gnuseye-acled--num (alist-get 'longitude r))))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "acled:%s" (or (alist-get 'data_id r)
                                                 (alist-get 'event_id_cnty r)))
                      :kind 'event
                      :label (alist-get 'event_type r)
                      :lat lat :lon lon
                      :scale (let ((f (cmacs-gnuseye-acled--num
                                       (alist-get 'fatalities r))))
                               (if (and f (> f 0)) (min 2.0 (+ 0.8 (/ f 10.0))) 0.8))
                      :data `((event_type . ,(alist-get 'event_type r))
                              (date . ,(alist-get 'event_date r))
                              (fatalities . ,(alist-get 'fatalities r))
                              (country . ,(alist-get 'country r))
                              (notes . ,(alist-get 'notes r))))
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-acled--fetch (cb)
  (let ((key (cmacs-gnuseye-secret "ACLED_KEY"))
        (email (cmacs-gnuseye-secret "ACLED_EMAIL")))
    (if (not (and key email))
        (funcall cb nil)
      (cmacs-gnuseye-fetch-json
       (format "https://api.acleddata.com/acled/read?key=%s&email=%s&limit=%d"
               (url-hexify-string key) (url-hexify-string email)
               cmacs-gnuseye-acled-limit)
       (lambda (data) (funcall cb (and data (cmacs-gnuseye-acled--parse data))))
       nil 'list))))

(cmacs-gnuseye-define-layer acled
  :title "Armed conflict (ACLED)"
  :group 'conflict
  :kind 'event
  :interval 3600
  :default-on nil
  :cluster t
  :needs-key "ACLED_KEY"
  :fetch #'cmacs-gnuseye-acled--fetch)

;;;; Regional alert sirens (OREF / configurable) ------------------------------

(defcustom cmacs-gnuseye-sirens-url nil
  "URL of a regional alert/siren JSON feed (array with lat/lon/title), or nil.
Point at an OREF mirror or a regional civil-alert endpoint."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-sirens--parse (data)
  (let ((records (if (and (listp data) (alist-get 'alerts data))
                     (alist-get 'alerts data)
                   data))
        out)
    (dolist (r records)
      (let ((lat (or (alist-get 'lat r) (alist-get 'latitude r)))
            (lon (or (alist-get 'lon r) (alist-get 'longitude r)))
            (title (or (alist-get 'title r) (alist-get 'name r)
                       (alist-get 'area r))))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "siren:%s" (or title lat))
                      :kind 'alert
                      :label (and title (format "%s" title))
                      :lat lat :lon lon :color "#ff2a2a"
                      :data r)
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-sirens--fetch (cb)
  (if (not cmacs-gnuseye-sirens-url)
      (funcall cb nil)
    (cmacs-gnuseye-fetch-json
     cmacs-gnuseye-sirens-url
     (lambda (data) (funcall cb (and data (cmacs-gnuseye-sirens--parse data))))
     nil 'list)))

(cmacs-gnuseye-define-layer sirens
  :title "Alert sirens (configure URL)"
  :group 'conflict
  :kind 'alert
  :interval 30
  :default-on nil
  :fetch #'cmacs-gnuseye-sirens--fetch)

(provide 'cmacs-gnuseye-keyed)
;;; cmacs-gnuseye-keyed.el ends here
