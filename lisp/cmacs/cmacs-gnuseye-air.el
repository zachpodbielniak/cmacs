;;; cmacs-gnuseye-air.el --- GNU's Eye air-traffic layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Live aircraft from the OpenSky Network (no key required; a free OpenSky
;; account in OPENSKY_USER/OPENSKY_PASS raises the rate-limit budget).
;; Aircraft are heading-oriented and capped to keep the marker count sane;
;; set a bounding box to scope the fetch and respect rate limits.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-bbox nil
  "Optional (LAMIN LOMIN LAMAX LOMAX) bounding box for the OpenSky fetch.
When nil, the global feed is requested (heavier; rate-limited).  Scoping
to your area of interest is strongly recommended."
  :type '(choice (const :tag "Global" nil)
                 (list (number :tag "lat min") (number :tag "lon min")
                       (number :tag "lat max") (number :tag "lon max")))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-max 300
  "Maximum number of aircraft markers to render."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-air--url ()
  (concat "https://opensky-network.org/api/states/all"
          (when cmacs-gnuseye-air-bbox
            (apply #'format "?lamin=%s&lomin=%s&lamax=%s&lomax=%s"
                   cmacs-gnuseye-air-bbox))))

(defun cmacs-gnuseye-air--headers ()
  (let ((user (cmacs-gnuseye-secret "OPENSKY_USER"))
        (pass (cmacs-gnuseye-secret "OPENSKY_PASS")))
    (when (and user pass)
      (list (cons "Authorization"
                  (concat "Basic "
                          (base64-encode-string (concat user ":" pass) t)))))))

(defun cmacs-gnuseye-air--parse (data)
  "Turn an OpenSky /states/all DATA alist into aircraft entities."
  (let ((states (alist-get 'states data))
        (out nil) (n 0))
    (catch 'done
      (dolist (s states)
        (let ((icao (nth 0 s)) (call (nth 1 s)) (origin (nth 2 s))
              (lon (nth 5 s)) (lat (nth 6 s)) (baro (nth 7 s))
              (onground (nth 8 s)) (vel (nth 9 s)) (track (nth 10 s))
              (geo (nth 13 s)) (squawk (nth 14 s)))
          (when (and lat lon (not (eq onground t)))
            (push (list :id (format "ac:%s" icao)
                        :kind 'aircraft
                        :label (and call (string-trim call))
                        :lat lat :lon lon :alt (or geo baro 0)
                        :heading (or track -1) :speed vel
                        :data `((country . ,origin) (squawk . ,squawk)
                                (velocity-ms . ,vel)))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-air-max) (throw 'done nil))))))
    (nreverse out)))

(defun cmacs-gnuseye-air--fetch (cb)
  (cmacs-gnuseye-fetch-json
   (cmacs-gnuseye-air--url)
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-air--parse data))))
   (cmacs-gnuseye-air--headers)
   'list))

(cmacs-gnuseye-define-layer aircraft
  :title "Air traffic (OpenSky ADS-B)"
  :group 'air
  :kind 'aircraft
  :interval 15
  :default-on t
  :fetch #'cmacs-gnuseye-air--fetch)

(provide 'cmacs-gnuseye-air)
;;; cmacs-gnuseye-air.el ends here
