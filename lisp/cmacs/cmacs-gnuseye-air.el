;;; cmacs-gnuseye-air.el --- GNU's Eye air-traffic layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Live aircraft, heading-oriented and capped to keep the marker count sane.
;;
;; Default source is adsb.lol -- a free, keyless community ADS-B aggregator
;; queried by centre + radius around whatever the globe is currently looking
;; at.  OpenSky is also supported (`cmacs-gnuseye-air-source' = `opensky')
;; but its anonymous API is now heavily rate-limited (HTTP 429); a free
;; OpenSky account in OPENSKY_USER/OPENSKY_PASS raises that budget.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-source 'adsblol
  "Aircraft data source.
`adsblol' is keyless and recommended; `opensky' needs credentials to be
useful (anonymous access returns HTTP 429 \"Too many requests\")."
  :type '(choice (const :tag "adsb.lol (keyless)" adsblol)
                 (const :tag "OpenSky Network" opensky))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-max 200
  "Maximum number of aircraft markers to render."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-radius-nm 250
  "Radius in nautical miles (max 250) around the view centre for adsb.lol."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-center nil
  "Fallback (LAT . LON) for the aircraft query when no globe is shown.
When nil and there is no globe to take the view centre from, the fetch is
skipped (no aircraft until a globe is open)."
  :type '(choice (const :tag "View centre only" nil)
                 (cons (number :tag "lat") (number :tag "lon")))
  :group 'cmacs-gnuseye)

;; ── adsb.lol (keyless, default) ─────────────────────────────────────────

(defun cmacs-gnuseye-air--center ()
  "Centre (LAT . LON) for the regional aircraft query."
  (or (and (boundp 'cmacs-gnuseye-buffer) cmacs-gnuseye-buffer
           (buffer-live-p cmacs-gnuseye-buffer)
           (fboundp 'cmacs-gnuseye-view-center)
           (ignore-errors (cmacs-gnuseye-view-center cmacs-gnuseye-buffer)))
      cmacs-gnuseye-air-center))

(defun cmacs-gnuseye-air--adsblol-url (lat lon)
  (format "https://api.adsb.lol/v2/lat/%.4f/lon/%.4f/dist/%d"
          lat lon (min 250 (max 1 cmacs-gnuseye-air-radius-nm))))

(defun cmacs-gnuseye-air--parse-adsblol (data)
  "Turn an adsb.lol DATA alist (the `ac' array) into aircraft entities."
  (let ((ac (alist-get 'ac data)) (out nil) (n 0))
    (catch 'done
      (dolist (a ac)
        (let* ((lat (alist-get 'lat a)) (lon (alist-get 'lon a))
               (track (alist-get 'track a))
               (altb (alist-get 'alt_baro a))
               (gs (alist-get 'gs a))
               (flight (alist-get 'flight a))
               (hex (alist-get 'hex a))
               (reg (alist-get 'r a)) (typ (alist-get 't a))
               (alt-m (if (numberp altb) (* altb 0.3048) 0.0))
               (spd-ms (and (numberp gs) (* gs 0.514444))))
          (when (and (numberp lat) (numberp lon))
            (push (list :id (format "ac:%s" (or hex flight n))
                        :kind 'aircraft
                        :label (and (stringp flight) (string-trim flight))
                        :lat lat :lon lon :alt alt-m
                        :heading (if (numberp track) track -1)
                        :speed spd-ms
                        :data `((registration . ,reg) (type . ,typ)
                                (hex . ,hex) (altitude-ft . ,altb)
                                (ground-speed-kt . ,gs)))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-air-max) (throw 'done nil))))))
    (nreverse out)))

;; ── OpenSky (optional, needs creds) ─────────────────────────────────────

(defcustom cmacs-gnuseye-air-bbox nil
  "Optional (LAMIN LOMIN LAMAX LOMAX) bounding box for the OpenSky fetch."
  :type '(choice (const :tag "Global" nil)
                 (list (number :tag "lat min") (number :tag "lon min")
                       (number :tag "lat max") (number :tag "lon max")))
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-air--opensky-url ()
  (concat "https://opensky-network.org/api/states/all"
          (when cmacs-gnuseye-air-bbox
            (apply #'format "?lamin=%s&lomin=%s&lamax=%s&lomax=%s"
                   cmacs-gnuseye-air-bbox))))

(defun cmacs-gnuseye-air--opensky-headers ()
  (let ((user (cmacs-gnuseye-secret "OPENSKY_USER"))
        (pass (cmacs-gnuseye-secret "OPENSKY_PASS")))
    (when (and user pass)
      (list (cons "Authorization"
                  (concat "Basic "
                          (base64-encode-string (concat user ":" pass) t)))))))

(defun cmacs-gnuseye-air--parse-opensky (data)
  "Turn an OpenSky /states/all DATA alist into aircraft entities."
  (let ((states (alist-get 'states data)) (out nil) (n 0))
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

;; ── Dispatch ────────────────────────────────────────────────────────────

(defun cmacs-gnuseye-air--fetch (cb)
  (if (eq cmacs-gnuseye-air-source 'opensky)
      (cmacs-gnuseye-fetch-json
       (cmacs-gnuseye-air--opensky-url)
       (lambda (data) (funcall cb (and data (cmacs-gnuseye-air--parse-opensky
                                             data))))
       (cmacs-gnuseye-air--opensky-headers) 'list)
    (let ((c (cmacs-gnuseye-air--center)))
      (if (not (consp c))
          (funcall cb nil)
        (cmacs-gnuseye-fetch-json
         (cmacs-gnuseye-air--adsblol-url (float (car c)) (float (cdr c)))
         (lambda (data) (funcall cb (and data (cmacs-gnuseye-air--parse-adsblol
                                               data)))))))))

(cmacs-gnuseye-define-layer aircraft
  :title "Air traffic (ADS-B)"
  :group 'air
  :kind 'aircraft
  :interval 15
  :default-on t
  :fetch #'cmacs-gnuseye-air--fetch)

(provide 'cmacs-gnuseye-air)
;;; cmacs-gnuseye-air.el ends here
