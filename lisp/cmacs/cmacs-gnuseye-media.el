;;; cmacs-gnuseye-media.el --- GNU's Eye media/camera layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Media & camera layers, in the `media' category.  Their markers carry a
;; stream/article URL in :data; the inspector's [w] (open stream) and [n]
;; (open news) actions (intelligence phase) open them via `cmacs-video-open'
;; / `cmacs-gsurf'.
;;
;;   iss      the ISS as a moving camera marker (keyless wheretheiss.at),
;;            with a configurable live-stream URL.
;;   webcams  live webcams from a configurable feed (Windy needs a key).

;;; Code:

(require 'cmacs-gnuseye)

;;;; ISS live camera ----------------------------------------------------------

(defcustom cmacs-gnuseye-iss-url
  "https://api.wheretheiss.at/v1/satellites/25544"
  "Keyless ISS position endpoint (wheretheiss.at)."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-iss-stream-url
  "https://ittvis.nasa.gov/hdev/HDEV.m3u8"
  "ISS live-stream URL opened from the inspector's [w] action.
Set to whatever stream `cmacs-video-open' can play (http/hls/rtsp/...)."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-iss--parse (data)
  (let ((lat (alist-get 'latitude data))
        (lon (alist-get 'longitude data))
        (alt (alist-get 'altitude data)))
    (when (and (numberp lat) (numberp lon))
      (list (list :id "iss"
                  :kind 'camera
                  :label "ISS"
                  :lat (float lat) :lon (float lon)
                  :alt (* 1000.0 (or alt 420.0))   ; km -> m
                  :scale 1.4
                  :data `((stream . ,cmacs-gnuseye-iss-stream-url)
                          (altitude-km . ,alt)
                          (velocity . ,(alist-get 'velocity data))))))))

(defun cmacs-gnuseye-iss--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-iss-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-iss--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer iss
  :title "ISS live (camera)"
  :group 'media
  :kind 'camera
  :interval 10
  :default-on nil
  :fetch #'cmacs-gnuseye-iss--fetch)

;;;; Webcams (configurable; Windy needs a key) --------------------------------

(defcustom cmacs-gnuseye-webcams-url nil
  "URL of a webcam JSON feed (array of objects with lat/lon/title/stream),
or nil to use the Windy API (needs WINDY_WEBCAMS_KEY)."
  :type '(choice (const :tag "Windy (key)" nil) string)
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-webcams--parse (data)
  "Parse a flexible webcam feed DATA (array, or Windy {webcams:[...]})."
  (let ((records (or (alist-get 'webcams data)
                     (and (alist-get 'result data)
                          (alist-get 'webcams (alist-get 'result data)))
                     (and (listp data) data)))
        out)
    (dolist (w records)
      (let* ((loc (or (alist-get 'location w) w))
             (lat (or (alist-get 'latitude loc) (alist-get 'lat w)))
             (lon (or (alist-get 'longitude loc) (alist-get 'lon w)))
             (title (or (alist-get 'title w) (alist-get 'name w)))
             (player (alist-get 'player w))
             (stream (or (and player (alist-get 'live (alist-get 'day player)))
                         (alist-get 'stream w) (alist-get 'url w))))
        (when (and (numberp lat) (numberp lon))
          (push (list :id (format "cam:%s" (or (alist-get 'webcamId w) title))
                      :kind 'camera
                      :label (and title (format "%s" title))
                      :lat (float lat) :lon (float lon)
                      :data `((stream . ,stream) (title . ,title)))
                out))))
    (nreverse out)))

(defun cmacs-gnuseye-webcams--fetch (cb)
  (cond
   (cmacs-gnuseye-webcams-url
    (cmacs-gnuseye-fetch-json
     cmacs-gnuseye-webcams-url
     (lambda (data) (funcall cb (and data (cmacs-gnuseye-webcams--parse data))))
     nil 'list))
   ((cmacs-gnuseye-secret "WINDY_WEBCAMS_KEY")
    (let ((key (cmacs-gnuseye-secret "WINDY_WEBCAMS_KEY")))
      (cmacs-gnuseye-fetch-json
       "https://api.windy.com/webcams/api/v3/webcams?limit=200&include=location,player"
       (lambda (data) (funcall cb (and data (cmacs-gnuseye-webcams--parse data))))
       `(("x-windy-api-key" . ,key)) 'list)))
   (t (funcall cb nil))))

;; No :needs-key: usable either with `cmacs-gnuseye-webcams-url' (keyless) or
;; a Windy key; with neither set the fetch simply yields nothing.
(cmacs-gnuseye-define-layer webcams
  :title "Webcams (Windy / configurable URL)"
  :group 'media
  :kind 'camera
  :interval 600
  :default-on nil
  :fetch #'cmacs-gnuseye-webcams--fetch)

(provide 'cmacs-gnuseye-media)
;;; cmacs-gnuseye-media.el ends here
