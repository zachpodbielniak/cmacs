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

(defcustom cmacs-gnuseye-air-global t
  "When non-nil, track ALL aircraft worldwide, not just the current view.
A handful of large overlapping queries sweep the globe and are merged by
ICAO hex, so every aircraft adsb.lol can see is indexed and searchable.
Rendering is still capped (`cmacs-gnuseye-render-max') for performance, but
the full set is in the entity list."
  :type 'boolean :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-global-tiles
  '((0 . 0) (0 . 90) (0 . 180) (0 . -90) (50 . 10) (40 . -100))
  "Query centres (LAT . LON) for the global aircraft sweep.
The defaults (four equatorial points plus dense Europe/US) cover the world
with overlap when combined with `cmacs-gnuseye-air-global-radius-nm'."
  :type '(repeat (cons number number)) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-global-radius-nm 5000
  "Radius (nautical miles) for each global-sweep tile query."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-max nil
  "Optional hard cap on indexed aircraft (nil = keep all that are fetched).
Rendering is capped separately by `cmacs-gnuseye-render-max'."
  :type '(choice (const :tag "Keep all" nil) integer)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-marker-scale 0.15
  "Size of aircraft markers, relative to the default icon size.
Small by design: with thousands of planes the globe is only readable when
each icon is tiny.  Markers are additionally zoom-scaled for a constant
on-screen size."
  :type 'number :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-air--advance (lat lon speed-ms heading-deg dt)
  "Great-circle destination from LAT,LON after SPEED-MS for DT s on HEADING.
Returns (LAT2 . LON2), or nil when there is nothing to advance."
  (when (and (numberp lat) (numberp lon) (numberp speed-ms) (> speed-ms 0)
             (numberp heading-deg) (>= heading-deg 0) (> dt 0))
    (let* ((r 6371000.0) (d (/ (* speed-ms dt) r))
           (d2r (/ float-pi 180.0))
           (la (* lat d2r)) (lo (* lon d2r)) (th (* heading-deg d2r))
           (sla (sin la)) (cla (cos la)) (sd (sin d)) (cd (cos d))
           (la2 (asin (max -1.0 (min 1.0 (+ (* sla cd) (* cla sd (cos th)))))))
           (lo2 (+ lo (atan (* (sin th) sd cla)
                            (- cd (* sla (sin la2)))))))
      (cons (/ la2 d2r) (/ lo2 d2r)))))

(defun cmacs-gnuseye-air--advance-layer (entities dt _now)
  "Dead-reckon each of ENTITIES forward DT seconds along its heading.
The shared smooth-motion tick (`cmacs-gnuseye--smooth-tick') calls this."
  (dolist (e entities)
    (let ((np (cmacs-gnuseye-air--advance
               (plist-get e :lat) (plist-get e :lon)
               (plist-get e :speed) (plist-get e :heading) dt)))
      (when np
        (plist-put e :lat (car np))
        (plist-put e :lon (cdr np))))))

(defcustom cmacs-gnuseye-air-radius-nm nil
  "Radius in nautical miles around the view centre for adsb.lol.
When nil, the radius is chosen automatically to cover the visible area at
the current zoom (so aircraft fill the view rather than a single patch)."
  :type '(choice (const :tag "Automatic (fit the view)" nil) integer)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-air-center nil
  "Fallback (LAT . LON) for the aircraft query when no globe is shown.
When nil and there is no globe to take the view centre from, the fetch is
skipped (no aircraft until a globe is open)."
  :type '(choice (const :tag "View centre only" nil)
                 (cons (number :tag "lat") (number :tag "lon")))
  :group 'cmacs-gnuseye)

;; ── adsb.lol (keyless, default) ─────────────────────────────────────────

(defun cmacs-gnuseye-air--view ()
  "Return (LAT LON RADIUS-NM) for the aircraft query, or nil.
The radius covers the visible area at the current zoom unless
`cmacs-gnuseye-air-radius-nm' overrides it."
  (let ((vc (and (boundp 'cmacs-gnuseye-buffer) cmacs-gnuseye-buffer
                 (buffer-live-p cmacs-gnuseye-buffer)
                 (fboundp 'cmacs-gnuseye-view-center)
                 (ignore-errors
                   (cmacs-gnuseye-view-center cmacs-gnuseye-buffer)))))
    (cond
     ((and (consp vc) (numberp (nth 2 vc)))
      ;; (lat lon distance): radius ~ the on-screen ground extent.
      (let* ((dist (nth 2 vc))
             (r (or cmacs-gnuseye-air-radius-nm
                    (max 250 (min 2200 (round (* (- dist 6.371) 290)))))))
        (list (nth 0 vc) (nth 1 vc) r)))
     ((consp cmacs-gnuseye-air-center)
      (list (car cmacs-gnuseye-air-center) (cdr cmacs-gnuseye-air-center)
            (or cmacs-gnuseye-air-radius-nm 600)))
     (t nil))))

(defun cmacs-gnuseye-air--adsblol-url (lat lon radius-nm)
  (format "https://api.adsb.lol/v2/lat/%.4f/lon/%.4f/dist/%d"
          lat lon (max 1 radius-nm)))

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
                        :scale cmacs-gnuseye-air-marker-scale
                        :data `((registration . ,reg) (type . ,typ)
                                (hex . ,hex) (altitude-ft . ,altb)
                                (ground-speed-kt . ,gs)))
                  out)
            (setq n (1+ n))
            (when (and cmacs-gnuseye-air-max (>= n cmacs-gnuseye-air-max))
              (throw 'done nil))))))
    (nreverse out)))

(defcustom cmacs-gnuseye-air-priority-radius-nm 350
  "Radius (nm) of the small fast query fired first, around the view centre.
Its planes show almost immediately while the larger global tiles download
in parallel."
  :type 'integer :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-air--fetch-global (cb)
  "Sweep the globe with several queries in parallel; call (CB MERGED).
All run on their own C worker threads at once.  A small query around the
current view fires first so local planes appear right away, and CB is
invoked after EACH query completes (with the cumulative set merged by id),
so the map fills in progressively instead of waiting for the slowest tile."
  (let* ((radius cmacs-gnuseye-air-global-radius-nm)
         (view (cmacs-gnuseye-air--view))
         (queries
          (append
           ;; Fast, relevant first: a small circle around what you're viewing.
           (when (and (consp view) (numberp (nth 0 view)))
             (list (list (float (nth 0 view)) (float (nth 1 view))
                         cmacs-gnuseye-air-priority-radius-nm)))
           ;; Then the worldwide tiles.
           (mapcar (lambda (tc)
                     (list (float (car tc)) (float (cdr tc)) radius))
                   cmacs-gnuseye-air-global-tiles)))
         (acc (make-hash-table :test 'equal)))
    (if (null queries)
        (funcall cb nil)
      (dolist (q queries)
        (cmacs-gnuseye-fetch-json
         (cmacs-gnuseye-air--adsblol-url (nth 0 q) (nth 1 q) (nth 2 q))
         (lambda (data)
           (when data
             (dolist (e (cmacs-gnuseye-air--parse-adsblol data))
               (puthash (plist-get e :id) e acc)))
           (funcall cb (hash-table-values acc))))))))

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
                        :scale cmacs-gnuseye-air-marker-scale
                        :data `((country . ,origin) (squawk . ,squawk)
                                (velocity-ms . ,vel)))
                  out)
            (setq n (1+ n))
            (when (>= n cmacs-gnuseye-air-max) (throw 'done nil))))))
    (nreverse out)))

;; ── Dispatch ────────────────────────────────────────────────────────────

(defun cmacs-gnuseye-air--fetch (cb)
  (cond
   ((eq cmacs-gnuseye-air-source 'opensky)
    (cmacs-gnuseye-fetch-json
     (cmacs-gnuseye-air--opensky-url)
     (lambda (data) (funcall cb (and data (cmacs-gnuseye-air--parse-opensky
                                           data))))
     (cmacs-gnuseye-air--opensky-headers) 'list))
   (cmacs-gnuseye-air-global
    (cmacs-gnuseye-air--fetch-global cb))
   (t
    (let ((v (cmacs-gnuseye-air--view)))
      (if (not v)
          (funcall cb nil)
        (cmacs-gnuseye-fetch-json
         (cmacs-gnuseye-air--adsblol-url (float (nth 0 v)) (float (nth 1 v))
                                         (nth 2 v))
         (lambda (data) (funcall cb (and data (cmacs-gnuseye-air--parse-adsblol
                                               data))))))))))

(cmacs-gnuseye-define-layer aircraft
  :title "Air traffic (ADS-B, worldwide)"
  :group 'air
  :kind 'aircraft
  :interval 20
  :default-on t
  :fetch #'cmacs-gnuseye-air--fetch
  :advance #'cmacs-gnuseye-air--advance-layer)

(provide 'cmacs-gnuseye-air)
;;; cmacs-gnuseye-air.el ends here
