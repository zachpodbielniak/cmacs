;;; cmacs-gnuseye-meteo.el --- GNU's Eye meteorology suite  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Live weather on the globe, all keyless by default:
;;   cyclones        tropical cyclones, all basins (NHC/JTWC via the Esri
;;                   Living Atlas Active_Hurricanes_v1 GeoJSON): storm
;;                   centre + observed track + forecast track/positions +
;;                   error cone + 34/50/64 kt wind radii + watches/warnings
;;   radar           precipitation radar draped on the globe (RainViewer
;;                   composite tiles; ~13 past frames, animated), or the
;;                   optional keyed OpenWeatherMap tile styles
;;   clouds          global cloud imagery draped translucently (NASA GIBS
;;                   WMS world image, luminance -> opacity)
;;   wind-particles  animated wind-flow streaks advected through an
;;                   Open-Meteo grid (surface or 850/500/250 hPa)
;;   metar           worldwide METAR surface observations, view-scoped
;;                   (aviationweather.gov), coloured by flight category
;; plus a click-anywhere 7-day forecast panel (Open-Meteo), an "Earth
;; today" real-imagery base texture, and `cmacs-gnuseye-weather-showcase'
;; -- one key (W) that lights the whole picture and flies to the most
;; intense active storm.
;;
;; Raster layers (radar/clouds/earth-today) need the C overlay DEFUNs
;; (cmacs-gnuseye-overlay.c); without them the vector layers still work
;; and the raster commands explain themselves.  US NWS alert polygons
;; live in cmacs-gnuseye-natural.el (layer `nws-alerts') and complete
;; the picture.

;;; Code:

(require 'cl-lib)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence
(require 'cmacs-gnuseye)
(require 'cmacs-gnuseye-overlay)

(declare-function cmacs-gnuseye-haversine "cmacs-gnuseye-geo.c")
(declare-function cmacs-gnuseye-view-center "cmacs-gnuseye-defuns.c")
(declare-function cmacs-gnuseye-attached-p "cmacs-gnuseye-defuns.c")
(declare-function cmacs-gnuseye-overlay-ensure "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-compose-frame "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-show-frame "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-frames "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-set-alpha "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-clear "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-set-base-texture "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-screen-to-globe "cmacs-gnuseye-defuns.c")
(declare-function cmacs-gnuseye-fly-to "cmacs-gnuseye-defuns.c")
(declare-function cmacs-gnuseye-chart-sparkline "cmacs-gnuseye-charts")

;;;; Shared helpers -----------------------------------------------------------

(defun cmacs-gnuseye-meteo--num (v)
  "Coerce V (number or numeric string) to a number, else nil."
  (cond ((numberp v) v)
        ((stringp v) (let ((n (string-to-number v)))
                       (and (or (not (= n 0)) (string-match-p "^[0.+-]" v))
                            n)))))

(defun cmacs-gnuseye-meteo--compass (deg)
  "Compass point string for bearing DEG."
  (if (not (numberp deg)) "?"
    (let ((pts ["N" "NNE" "NE" "ENE" "E" "ESE" "SE" "SSE"
                "S" "SSW" "SW" "WSW" "W" "WNW" "NW" "NNW"]))
      (aref pts (mod (round (/ (mod deg 360.0) 22.5)) 16)))))

(defun cmacs-gnuseye-meteo--globe-buffer ()
  "The live globe buffer, or nil."
  (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
       (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer)
       cmacs-gnuseye-buffer))

;;;; Tropical cyclones --------------------------------------------------------

(defcustom cmacs-gnuseye-cyclones-url-format
  (concat "https://services9.arcgis.com/RHVPKKiFTONKtxq3/arcgis/rest/"
          "services/Active_Hurricanes_v1/FeatureServer/%d/query"
          "?where=1%%3D1&outFields=*&f=geojson")
  "Esri Living Atlas Active Hurricanes query URL (%d = sublayer id).
Sublayers: 0 forecast position, 1 observed position, 2 forecast track,
4 error cone, 5 watches/warnings, 7/8/9 = 34/50/64 kt wind fields."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cyclones-source 'esri
  "Active-cyclone feed: `esri' (all basins, full geometry) or `nhc'
(NOAA CurrentStorms.json -- Atlantic/E-Pacific centres only, no
cones/tracks; a cross-check fallback)."
  :type '(choice (const esri) (const nhc)) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cyclones-nhc-url
  "https://www.nhc.noaa.gov/CurrentStorms.json"
  "NOAA NHC active-storms JSON (the `nhc' fallback source)."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cyclones-wind-radii '(34 50 64)
  "Wind-field rings to drape per storm (kt); nil disables them."
  :type '(repeat (choice (const 34) (const 50) (const 64)))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cyclones-cone t
  "Non-nil drapes each storm's forecast error cone."
  :type 'boolean :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cyclones-watches t
  "Non-nil draws coastal hurricane/TS watch and warning segments."
  :type 'boolean :group 'cmacs-gnuseye)

(defconst cmacs-gnuseye-cyclones--ss-colors
  ["#5ab0ff" "#7cd6ff" "#ffe08a" "#ffc14a" "#ff8c3a" "#ff4a3a" "#ff2ad0"]
  "Saffir-Simpson colour ramp: TD, TS, Cat 1..5.")

(defun cmacs-gnuseye-cyclones--category (ssnum stormtype)
  "Category label + colour (LABEL . COLOR) from SSNUM and STORMTYPE."
  (let* ((ss (or (cmacs-gnuseye-meteo--num ssnum) 0))
         (ty (upcase (format "%s" (or stormtype "")))))
    (cond
     ((>= ss 1) (cons (format "Cat %d" (min ss 5))
                      (aref cmacs-gnuseye-cyclones--ss-colors
                            (min 6 (+ 1 ss)))))
     ((string-match-p "\\`\\(TS\\|STS\\)" ty)
      (cons "TS" (aref cmacs-gnuseye-cyclones--ss-colors 1)))
     ((string-match-p "\\`\\(HU\\|TY\\|STY\\)" ty)
      (cons "Cat 1" (aref cmacs-gnuseye-cyclones--ss-colors 2)))
     (t (cons "TD" (aref cmacs-gnuseye-cyclones--ss-colors 0))))))

(defun cmacs-gnuseye-cyclones--rings (geom)
  "GEOM (geojson Polygon/MultiPolygon) -> list of outer rings ((LAT LON)...)."
  (let ((type (alist-get 'type geom))
        (cs (alist-get 'coordinates geom)))
    (mapcar (lambda (ring)
              (mapcar (lambda (pt) (list (cadr pt) (car pt))) ring))
            (cond ((equal type "Polygon") (list (car cs)))
                  ((equal type "MultiPolygon") (mapcar #'car cs))
                  (t nil)))))

(defun cmacs-gnuseye-cyclones--lines (geom)
  "GEOM (geojson LineString/MultiLineString) -> list of ((LAT LON)...)."
  (let ((type (alist-get 'type geom))
        (cs (alist-get 'coordinates geom)))
    (mapcar (lambda (line)
              (mapcar (lambda (pt) (list (cadr pt) (car pt))) line))
            (cond ((equal type "LineString") (list cs))
                  ((equal type "MultiLineString") cs)
                  (t nil)))))

(defun cmacs-gnuseye-cyclones--decimate (ring step maxn)
  "Every STEPth vertex of RING, capped at MAXN."
  (let ((out nil) (i 0))
    (dolist (p ring)
      (when (zerop (% i (max 1 step))) (push p out))
      (setq i (1+ i)))
    (let ((r (nreverse out)))
      (if (> (length r) maxn) (seq-take r maxn) r))))

(defun cmacs-gnuseye-cyclones--storm-key (props)
  (upcase (format "%s" (or (alist-get 'STORMNAME props)
                           (alist-get 'stormname props) "?"))))

(defun cmacs-gnuseye-cyclones--assemble (results)
  "Build entities from RESULTS: hash of sublayer id -> geojson features."
  (let ((storms (make-hash-table :test 'equal))  ; NAME -> plist of parts
        (out nil))
    (cl-flet ((part (name key val)
                (let ((s (gethash name storms)))
                  (puthash name (plist-put s key (cons val (plist-get s key)))
                           storms))))
      ;; Bucket every feature under its storm.
      (dolist (spec '((0 . fpos) (1 . opos) (2 . ftrack) (4 . cone)
                      (5 . ww) (7 . r34) (8 . r50) (9 . r64)))
        (dolist (f (gethash (car spec) results))
          (part (cmacs-gnuseye-cyclones--storm-key (alist-get 'properties f))
                (cdr spec) f))))
    (maphash
     (lambda (name parts)
       (let* ((fpos (sort (plist-get parts 'fpos)
                          (lambda (a b)
                            (< (or (cmacs-gnuseye-meteo--num
                                    (alist-get 'TAU (alist-get 'properties a)))
                                   999)
                               (or (cmacs-gnuseye-meteo--num
                                    (alist-get 'TAU (alist-get 'properties b)))
                                   999)))))
              (now (car fpos))
              (props (and now (alist-get 'properties now)))
              (coord (and now (alist-get 'coordinates
                                         (alist-get 'geometry now))))
              (lat (and coord (cadr coord)))
              (lon (and coord (car coord))))
         (when (and (numberp lat) (numberp lon))
           (let* ((ssnum (alist-get 'SSNUM props))
                  (stype (alist-get 'STORMTYPE props))
                  (cat (cmacs-gnuseye-cyclones--category ssnum stype))
                  (color (cdr cat))
                  (maxw (cmacs-gnuseye-meteo--num (alist-get 'MAXWIND props)))
                  (gust (cmacs-gnuseye-meteo--num (alist-get 'GUST props)))
                  (mslp (cmacs-gnuseye-meteo--num (alist-get 'MSLP props)))
                  (tcdir (cmacs-gnuseye-meteo--num (alist-get 'TCDIR props)))
                  (tcspd (cmacs-gnuseye-meteo--num (alist-get 'TCSPD props)))
                  (basin (alist-get 'BASIN props))
                  (base (format "cyc:%s" name))
                  ;; Observed track, oldest -> newest, as the centre's trail.
                  (obs (delq nil
                             (mapcar
                              (lambda (f)
                                (let ((c (alist-get 'coordinates
                                                    (alist-get 'geometry f))))
                                  (and (numberp (car-safe c))
                                       (list (cadr c) (car c)))))
                              (reverse (plist-get parts 'opos))))))
             ;; Storm centre: the marquee marker (bespoke cyclone glyph).
             (push (list :id base :kind 'cyclone
                         :lat lat :lon lon
                         :label (format "%s %s (%s)"
                                        (or stype "TC") name (car cat))
                         :label-mode 3
                         :color color
                         :scale (+ 1.1 (* 0.18 (or (cmacs-gnuseye-meteo--num
                                                    ssnum)
                                                   0)))
                         :heading (or tcdir -1)
                         :speed (and tcspd (* tcspd 0.514444))
                         :trail (and (> (length obs) 1) obs)
                         :data `((center . t) (name . ,name)
                                 (basin . ,basin) (type . ,stype)
                                 (category . ,(car cat))
                                 (maxwind-kt . ,maxw) (gust-kt . ,gust)
                                 (mslp-mb . ,mslp)
                                 (movement . ,(format "%s at %s kt"
                                                      (cmacs-gnuseye-meteo--compass tcdir)
                                                      (or tcspd "?")))
                                 (advisory . ,(alist-get 'FLDATELBL props))
                                 (source . "NHC/JTWC via Esri Living Atlas")))
                   out)
             ;; Forecast positions (+12h, +24h, ...).
             (dolist (f (cdr fpos))
               (let* ((p (alist-get 'properties f))
                      (c (alist-get 'coordinates (alist-get 'geometry f)))
                      (tau (cmacs-gnuseye-meteo--num (alist-get 'TAU p)))
                      (fcat (cmacs-gnuseye-cyclones--category
                             (alist-get 'SSNUM p) (alist-get 'STORMTYPE p))))
                 (when (and (numberp (car-safe c)) tau)
                   (push (list :id (format "%s:f%d" base tau)
                               :kind 'cyclone :lat (cadr c) :lon (car c)
                               :label (format "+%dh %s" tau (car fcat))
                               :label-mode 2 :scale 0.45
                               :color (concat color "b0")
                               :data `((name . ,name) (tau . ,tau)
                                       (maxwind-kt
                                        . ,(cmacs-gnuseye-meteo--num
                                            (alist-get 'MAXWIND p)))
                                       (valid . ,(alist-get 'FLDATELBL p))))
                         out))))
             ;; Forecast track polyline.
             (let ((lines (apply #'append
                                 (mapcar (lambda (f)
                                           (cmacs-gnuseye-cyclones--lines
                                            (alist-get 'geometry f)))
                                         (plist-get parts 'ftrack)))))
               (let ((i 0))
                 (dolist (line lines)
                   (when (> (length line) 1)
                     (push (list :id (format "%s:ftrack%d" base i)
                                 :kind 'cyclone :label-mode 0 :scale 0.05
                                 :lat (car (car (last line)))
                                 :lon (cadr (car (last line)))
                                 :color (concat color "90")
                                 :trail line
                                 :data `((name . ,name) (part . ftrack)))
                           out)
                     (setq i (1+ i))))))
             ;; Error cone.
             (when cmacs-gnuseye-cyclones-cone
               (let ((i 0))
                 (dolist (f (plist-get parts 'cone))
                   (dolist (ring (cmacs-gnuseye-cyclones--rings
                                  (alist-get 'geometry f)))
                     (let ((r (cmacs-gnuseye-cyclones--decimate ring 2 140)))
                       (when (> (length r) 2)
                         (push (list :id (format "%s:cone%d" base i)
                                     :kind 'cyclone :label-mode 0 :scale 0.05
                                     :lat (caar r) :lon (cadar r)
                                     :color "#b0b0ff42"
                                     :polygon r
                                     :data `((name . ,name) (part . cone)))
                               out)
                         (setq i (1+ i))))))))
             ;; Wind radii rings (64 kt innermost on top).
             (dolist (spec '((r34 34 "#ffd23a30") (r50 50 "#ff8c3a44")
                             (r64 64 "#ff3a3a58")))
               (when (memq (nth 1 spec) cmacs-gnuseye-cyclones-wind-radii)
                 (let ((i 0))
                   (dolist (f (plist-get parts (nth 0 spec)))
                     (dolist (ring (cmacs-gnuseye-cyclones--rings
                                    (alist-get 'geometry f)))
                       (let ((r (cmacs-gnuseye-cyclones--decimate ring 2 100)))
                         (when (> (length r) 2)
                           (push (list :id (format "%s:%s-%d" base
                                                   (nth 0 spec) i)
                                       :kind 'cyclone :label-mode 0
                                       :scale 0.05
                                       :lat (caar r) :lon (cadar r)
                                       :color (nth 2 spec)
                                       :polygon r
                                       :data `((name . ,name)
                                               (part . ,(nth 0 spec))))
                                 out)
                           (setq i (1+ i)))))))))
             ;; Coastal watches/warnings.
             (when cmacs-gnuseye-cyclones-watches
               (let ((i 0))
                 (dolist (f (plist-get parts 'ww))
                   (let* ((p (alist-get 'properties f))
                          (code (upcase (format "%s" (or (alist-get 'TCWW p)
                                                         ""))))
                          (wcol (pcase code
                                  ("HWR" "#ff2a2a") ("HWA" "#ff7be5")
                                  ("TWR" "#4a90ff") ("TWA" "#ffd23a")
                                  (_ "#ffd23a"))))
                     (dolist (line (cmacs-gnuseye-cyclones--lines
                                    (alist-get 'geometry f)))
                       (when (> (length line) 1)
                         (push (list :id (format "%s:ww%d" base i)
                                     :kind 'cyclone :label-mode 0 :scale 0.05
                                     :lat (caar line) :lon (cadar line)
                                     :color wcol
                                     :trail line
                                     :data `((name . ,name) (part . ww)
                                             (code . ,code)))
                               out)
                         (setq i (1+ i))))))))))))
     storms)
    (nreverse out)))

(defun cmacs-gnuseye-cyclones--nhc-parse (data)
  "Centre-only entities from NOAA CurrentStorms DATA."
  (let (out)
    (dolist (s (alist-get 'activeStorms data))
      (let ((lat (cmacs-gnuseye-meteo--num (alist-get 'latitudeNumeric s)))
            (lon (cmacs-gnuseye-meteo--num (alist-get 'longitudeNumeric s)))
            (name (alist-get 'name s))
            (cls (alist-get 'classification s))
            (kt (cmacs-gnuseye-meteo--num (alist-get 'intensity s))))
        (when (and (numberp lat) (numberp lon))
          (let ((cat (cmacs-gnuseye-cyclones--category
                      (and kt (max 0 (floor (- kt 64) 20))) cls)))
            (push (list :id (format "cyc:%s" (upcase (format "%s" name)))
                        :kind 'cyclone :lat lat :lon lon
                        :label (format "%s %s" (or cls "TC") name)
                        :label-mode 3 :scale 1.2
                        :color (cdr cat)
                        :heading (or (cmacs-gnuseye-meteo--num
                                      (alist-get 'movementDir s))
                                     -1)
                        :speed (let ((v (cmacs-gnuseye-meteo--num
                                         (alist-get 'movementSpeed s))))
                                 (and v (* v 0.514444)))
                        :data `((center . t) (name . ,name)
                                (type . ,cls) (category . ,(car cat))
                                (maxwind-kt . ,kt)
                                (pressure-mb
                                 . ,(cmacs-gnuseye-meteo--num
                                     (alist-get 'pressure s)))
                                (source . "NOAA NHC")))
                  out)))))
    (nreverse out)))

(defun cmacs-gnuseye-cyclones--fetch (cb)
  (if (eq cmacs-gnuseye-cyclones-source 'nhc)
      (cmacs-gnuseye-fetch-json
       cmacs-gnuseye-cyclones-nhc-url
       (lambda (data)
         (funcall cb (and data (cmacs-gnuseye-cyclones--nhc-parse data)))))
    (let* ((subs (append '(0 1 2)
                         (and cmacs-gnuseye-cyclones-cone '(4))
                         (and cmacs-gnuseye-cyclones-watches '(5))
                         (mapcar (lambda (kt) (pcase kt (34 7) (50 8) (64 9)))
                                 cmacs-gnuseye-cyclones-wind-radii)))
           (results (make-hash-table :test 'eq))
           (pending (length subs)))
      (dolist (sub subs)
        (let ((i sub))                     ; per-iteration binding for the cb
          (cmacs-gnuseye-fetch-json
           (format cmacs-gnuseye-cyclones-url-format i)
           (lambda (data)
             (puthash i (and data (alist-get 'features data)) results)
             (when (zerop (setq pending (1- pending)))
               (funcall cb (cmacs-gnuseye-cyclones--assemble results))))))))))

(defun cmacs-gnuseye-cyclones--strongest ()
  "The strongest active storm-centre entity, or nil."
  (let (best bestw)
    (dolist (e (gethash 'cyclones cmacs-gnuseye--layer-entities))
      (let ((d (plist-get e :data)))
        (when (alist-get 'center d)
          (let ((w (or (alist-get 'maxwind-kt d) 0)))
            (when (or (null best) (> w bestw))
              (setq best e bestw w))))))
    best))

(cmacs-gnuseye-define-layer cyclones
  :title "Tropical cyclones (NHC/JTWC)"
  :group 'meteo
  :kind 'cyclone
  :interval 900
  :default-on t
  :fetch #'cmacs-gnuseye-cyclones--fetch
  :advance #'cmacs-gnuseye-dead-reckon-layer)

;;;; Precipitation radar ------------------------------------------------------

(defcustom cmacs-gnuseye-radar-index-url
  "https://api.rainviewer.com/public/weather-maps.json"
  "RainViewer maps index (frame timestamps + tile paths; keyless)."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-provider 'rainviewer
  "Radar drape source: keyless `rainviewer' (animated composite) or
`owm' (OpenWeatherMap precipitation tiles; needs OPENWEATHERMAP_API_KEY,
current-conditions only)."
  :type '(choice (const rainviewer) (const owm)) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-zoom 2
  "Mercator zoom of the world radar drape (2 = 16 tiles, 3 = 64)."
  :type '(choice (const 2) (const 3)) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-color 2
  "RainViewer colour scheme (0-8; 2 = universal blue)."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-options "1_1"
  "RainViewer tile options (smoothing_snow)."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-frames 8
  "How many recent radar frames to keep composed for animation."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-frame-interval 0.6
  "Seconds between animation steps (`cmacs-gnuseye-radar-animate')."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-alpha 0.8
  "Radar drape opacity (0..1)."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-radar-keep-seconds 10800
  "Age limit for cached radar tiles on disk."
  :type 'integer :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-meteo--radar-host nil)
(defvar cmacs-gnuseye-meteo--radar-frames nil
  "Oldest-first list of (:time N :path P :tag T :nowcast BOOL).")
(defvar cmacs-gnuseye-meteo--radar-anim nil)
(defvar cmacs-gnuseye-meteo--radar-idx nil)
(defvar cmacs-gnuseye-meteo--radar-last-step 0)
(defvar cmacs-gnuseye-meteo--radar-busy nil)

(defun cmacs-gnuseye-meteo--radar-tag (fr)
  (format "rv:z%d:%s" cmacs-gnuseye-radar-zoom (plist-get fr :time)))

(defun cmacs-gnuseye-meteo--radar-tile-url (path x y z)
  (format "%s%s/%d/%d/%d/%d/%d/%s.png"
          (or cmacs-gnuseye-meteo--radar-host "https://tilecache.rainviewer.com")
          path 256 z x y
          cmacs-gnuseye-radar-color cmacs-gnuseye-radar-options))

(defun cmacs-gnuseye-meteo--radar-tile-file (path x y z)
  (cmacs-gnuseye-overlay-cache-file
   "radar" (format "%s-%d-%d-%d.png" (string-replace "/" "_" path) z x y)))

(defun cmacs-gnuseye-meteo--radar-compose (buf fr show &optional done)
  "Download + compose radar frame FR on BUF; SHOW displays it."
  (let ((path (plist-get fr :path)))
    (cmacs-gnuseye-overlay-ensure-tile-frame
     buf 'radar (cmacs-gnuseye-meteo--radar-tag fr)
     (list :tiles (cmacs-gnuseye-overlay-world-tiles cmacs-gnuseye-radar-zoom)
           :url-fn (lambda (x y z)
                     (cmacs-gnuseye-meteo--radar-tile-url path x y z))
           :file-fn (lambda (x y z)
                      (cmacs-gnuseye-meteo--radar-tile-file path x y z))
           :opts (and show '(:show t)))
     (lambda (result) (when done (funcall done result))))))

(defun cmacs-gnuseye-meteo--radar-prefetch (buf frames shown)
  "Compose FRAMES one at a time (newest first); SHOWN marks one displayed."
  (when (and frames (buffer-live-p buf))
    (let* ((fr (car frames))
           (cached (member (cmacs-gnuseye-meteo--radar-tag fr)
                           (and (fboundp 'cmacs-gnuseye-overlay-frames)
                                (cmacs-gnuseye-overlay-frames buf 'radar)))))
      (if cached
          (cmacs-gnuseye-meteo--radar-prefetch buf (cdr frames) shown)
        (cmacs-gnuseye-meteo--radar-compose
         buf fr (not shown)
         (lambda (_res)
           (run-with-timer
            0.3 nil #'cmacs-gnuseye-meteo--radar-prefetch
            buf (cdr frames) t)))))))

(defun cmacs-gnuseye-meteo--radar-index (data)
  "Digest a RainViewer index DATA into the frame list."
  (let* ((radar (alist-get 'radar data))
         (past (alist-get 'past radar))
         (nowcast (alist-get 'nowcast radar))
         (frames (append
                  (mapcar (lambda (f)
                            (list :time (alist-get 'time f)
                                  :path (alist-get 'path f)))
                          past)
                  (mapcar (lambda (f)
                            (list :time (alist-get 'time f)
                                  :path (alist-get 'path f)
                                  :nowcast t))
                          nowcast))))
    (setq cmacs-gnuseye-meteo--radar-host (alist-get 'host data))
    ;; Empty feeds happen; keep the previous drape rather than blanking.
    (when frames
      (setq cmacs-gnuseye-meteo--radar-frames
            (seq-take (sort frames
                            (lambda (a b) (< (or (plist-get a :time) 0)
                                             (or (plist-get b :time) 0))))
                      64)))))

(defun cmacs-gnuseye-meteo--radar-fetch (cb)
  (let ((buf (cmacs-gnuseye-meteo--globe-buffer)))
    (cond
     ((not (cmacs-gnuseye-overlay-supported-p))
      (message "GNU's Eye: this build lacks raster overlay support")
      (funcall cb nil))
     ((null buf) (funcall cb nil))
     ((eq cmacs-gnuseye-radar-provider 'owm)
      (cmacs-gnuseye-meteo--radar-owm buf cb))
     (t
      (cmacs-gnuseye-overlay-ensure buf 'radar 1.0)
      (cmacs-gnuseye-overlay-set-alpha buf 'radar cmacs-gnuseye-radar-alpha)
      (add-hook 'cmacs-gnuseye--tick-functions
                #'cmacs-gnuseye-meteo--radar-tick)
      (cmacs-gnuseye-overlay-prune "radar" cmacs-gnuseye-radar-keep-seconds)
      (cmacs-gnuseye-fetch-json
       cmacs-gnuseye-radar-index-url
       (lambda (data)
         (when data (cmacs-gnuseye-meteo--radar-index data))
         (funcall cb nil)
         (let ((frames (seq-take (reverse cmacs-gnuseye-meteo--radar-frames)
                                 (max 1 cmacs-gnuseye-radar-frames))))
           (cmacs-gnuseye-meteo--radar-prefetch buf frames nil))))))))

(defun cmacs-gnuseye-meteo--radar-owm (buf cb)
  "Drape the OpenWeatherMap precipitation tiles (current only)."
  (let ((z cmacs-gnuseye-radar-zoom)
        (hour (format-time-string "%Y%m%d%H" nil t)))
    (if (not (cmacs-gnuseye-owm-tile-url "precipitation_new" 0 0 0))
        (progn
          (message "GNU's Eye: OWM radar needs OPENWEATHERMAP_API_KEY")
          (funcall cb nil))
      (cmacs-gnuseye-overlay-ensure buf 'radar 1.0)
      (cmacs-gnuseye-overlay-set-alpha buf 'radar cmacs-gnuseye-radar-alpha)
      (cmacs-gnuseye-overlay-ensure-tile-frame
       buf 'radar (format "owm:precip:%s" hour)
       (list :tiles (cmacs-gnuseye-overlay-world-tiles z)
             :url-fn (lambda (x y zz)
                       (cmacs-gnuseye-owm-tile-url "precipitation_new" x y zz))
             :file-fn (lambda (x y zz)
                        (cmacs-gnuseye-overlay-cache-file
                         "owm" (format "precip-%s-%d-%d-%d.png" hour zz x y)))
             :opts '(:show t))
       (lambda (_res) nil))
      (funcall cb nil))))

(defun cmacs-gnuseye-meteo--radar-tick (buf now _dt)
  "Animation stepper on the shared smooth tick."
  (when (and cmacs-gnuseye-meteo--radar-anim
             cmacs-gnuseye-meteo--radar-frames
             (not cmacs-gnuseye-meteo--radar-busy)
             (>= (- now cmacs-gnuseye-meteo--radar-last-step)
                 cmacs-gnuseye-radar-frame-interval))
    (setq cmacs-gnuseye-meteo--radar-last-step now)
    (let* ((frames (seq-take (reverse cmacs-gnuseye-meteo--radar-frames)
                             (max 1 cmacs-gnuseye-radar-frames)))
           (frames (reverse frames))       ; oldest -> newest loop
           (n (length frames)))
      (when (> n 0)
        (let* ((idx (% (1+ (or cmacs-gnuseye-meteo--radar-idx -1)) n))
               (fr (nth idx frames))
               (tag (cmacs-gnuseye-meteo--radar-tag fr)))
          (setq cmacs-gnuseye-meteo--radar-idx idx)
          (unless (cmacs-gnuseye-overlay-show-frame buf 'radar tag)
            ;; Not composed yet: build it in the background, skip this beat.
            (setq cmacs-gnuseye-meteo--radar-busy t)
            (cmacs-gnuseye-meteo--radar-compose
             buf fr nil
             (lambda (_res)
               (setq cmacs-gnuseye-meteo--radar-busy nil)))))))))

;;;###autoload
(defun cmacs-gnuseye-radar-animate ()
  "Toggle the animated radar loop (past frames + nowcast when present)."
  (interactive)
  (unless (cmacs-gnuseye-overlay-supported-p)
    (user-error "GNU's Eye: this build lacks raster overlay support"))
  (let ((layer (gethash 'radar cmacs-gnuseye--layers)))
    (when (and layer (not (cmacs-gnuseye-layer-enabled layer)))
      (cmacs-gnuseye--enable-layer layer)
      (cmacs-gnuseye-layers-refresh)))
  (setq cmacs-gnuseye-meteo--radar-anim (not cmacs-gnuseye-meteo--radar-anim))
  (message "GNU's Eye: radar animation %s"
           (if cmacs-gnuseye-meteo--radar-anim "on" "off")))

(cmacs-gnuseye-define-layer radar
  :title "Precipitation radar (RainViewer)"
  :group 'meteo
  :kind 'storm
  :interval 300
  :default-on nil
  :fetch #'cmacs-gnuseye-meteo--radar-fetch
  :teardown (lambda ()
              (remove-hook 'cmacs-gnuseye--tick-functions
                           #'cmacs-gnuseye-meteo--radar-tick)
              (setq cmacs-gnuseye-meteo--radar-anim nil
                    cmacs-gnuseye-meteo--radar-idx nil
                    cmacs-gnuseye-meteo--radar-busy nil)
              (let ((buf (cmacs-gnuseye-meteo--globe-buffer)))
                (when (and buf (fboundp 'cmacs-gnuseye-overlay-clear))
                  (ignore-errors
                    (cmacs-gnuseye-overlay-clear buf 'radar))))))

;;;; Cloud imagery (NASA GIBS) ------------------------------------------------

(defcustom cmacs-gnuseye-gibs-url-format
  (concat "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"
          "?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap&LAYERS=%s&STYLES="
          "&SRS=EPSG:4326&BBOX=-180,-90,180,90&WIDTH=%d&HEIGHT=%d"
          "&FORMAT=image/jpeg&TIME=%s")
  "NASA GIBS WMS GetMap template (%s layer, %d width, %d height, %s date).
The empty STYLES= parameter is required."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-clouds-layer
  "VIIRS_SNPP_CorrectedReflectance_TrueColor"
  "GIBS layer draped as clouds (luminance becomes opacity).
True colour makes bright cloud decks pop; deserts/snow can ghost
faintly -- tune `cmacs-gnuseye-clouds-luma' or pick an IR layer."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-clouds-luma '(0.55 . 3.2)
  "Cloud luminance->alpha mapping (LO . GAIN) in 0..1 luma units."
  :type '(cons number number) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-clouds-alpha 0.6
  "Cloud drape opacity (0..1)."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-clouds-width 2048
  "GIBS request width in pixels (height is half)."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-earth-layer
  "VIIRS_SNPP_CorrectedReflectance_TrueColor"
  "GIBS layer used by `cmacs-gnuseye-earth-today'."
  :type 'string :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-meteo--gibs-date ()
  "Yesterday (UTC) -- the newest date with guaranteed global coverage."
  (format-time-string "%F" (time-subtract nil (* 26 3600)) t))

(defun cmacs-gnuseye-meteo--gibs-fetch (layer w h cb)
  "Fetch the GIBS world image for LAYER at W x H; call (CB FILE-OR-NIL)."
  (let* ((date (cmacs-gnuseye-meteo--gibs-date))
         (file (cmacs-gnuseye-overlay-cache-file
                "gibs" (format "%s-%s-%d.jpg"
                               (replace-regexp-in-string "[^A-Za-z0-9_-]" "_"
                                                         layer)
                               date w)))
         (url (format cmacs-gnuseye-gibs-url-format layer w h date)))
    (cmacs-gnuseye-overlay-prune "gibs" (* 7 86400))
    (cmacs-gnuseye-overlay-fetch-file
     url file (lambda (ok) (funcall cb (and ok file))))))

(defun cmacs-gnuseye-meteo--clouds-fetch (cb)
  (let ((buf (cmacs-gnuseye-meteo--globe-buffer))
        (w cmacs-gnuseye-clouds-width))
    (cond
     ((not (cmacs-gnuseye-overlay-supported-p))
      (message "GNU's Eye: this build lacks raster overlay support")
      (funcall cb nil))
     ((null buf) (funcall cb nil))
     (t
      (cmacs-gnuseye-overlay-ensure buf 'clouds 2.0)
      (cmacs-gnuseye-overlay-set-alpha buf 'clouds cmacs-gnuseye-clouds-alpha)
      (cmacs-gnuseye-meteo--gibs-fetch
       cmacs-gnuseye-clouds-layer w (/ w 2)
       (lambda (file)
         (when (and file (buffer-live-p buf))
           (cmacs-gnuseye-overlay-compose-frame
            buf 'clouds (cmacs-gnuseye-meteo--gibs-date)
            (list (list file 0 0))
            (list :canvas-width w :canvas-height (/ w 2)
                  :luma-alpha cmacs-gnuseye-clouds-luma
                  :show t)))
         (funcall cb nil)))))))

(cmacs-gnuseye-define-layer clouds
  :title "Cloud imagery (NASA GIBS)"
  :group 'meteo
  :kind 'storm
  :interval 10800
  :default-on nil
  :fetch #'cmacs-gnuseye-meteo--clouds-fetch
  :teardown (lambda ()
              (let ((buf (cmacs-gnuseye-meteo--globe-buffer)))
                (when (and buf (fboundp 'cmacs-gnuseye-overlay-clear))
                  (ignore-errors
                    (cmacs-gnuseye-overlay-clear buf 'clouds))))))

;;;###autoload
(defun cmacs-gnuseye-earth-today ()
  "Re-skin the globe with yesterday's real satellite imagery (NASA GIBS)."
  (interactive)
  (let ((buf (cmacs-gnuseye-meteo--globe-buffer)))
    (unless buf (user-error "GNU's Eye: no globe is open"))
    (message "GNU's Eye: fetching today's Earth…")
    (cmacs-gnuseye-meteo--gibs-fetch
     cmacs-gnuseye-earth-layer 2048 1024
     (lambda (file)
       (cond
        ((null file)
         (message "GNU's Eye: Earth imagery fetch failed"))
        ((not (fboundp 'cmacs-gnuseye-set-base-texture))
         (setq cmacs-gnuseye-base-texture file)
         (message "GNU's Eye: imagery cached; reopen the globe to apply"))
        ((and (buffer-live-p buf)
              (cmacs-gnuseye-set-base-texture buf file))
         (message "GNU's Eye: Earth as of %s"
                  (cmacs-gnuseye-meteo--gibs-date)))
        (t (message "GNU's Eye: could not apply the imagery")))))))

;;;; Wind-flow particles ------------------------------------------------------

(defcustom cmacs-gnuseye-wind-url "https://api.open-meteo.com/v1/forecast"
  "Open-Meteo forecast endpoint for the wind grid (keyless)."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-grid-step 15
  "Wind grid spacing in degrees."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-lat-range '(-60 . 75)
  "Wind grid latitude coverage (MIN . MAX)."
  :type '(cons integer integer) :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-level 'surface
  "Wind level: `surface' (10 m) or a pressure level (850/500/250 hPa;
250 shows the jet streams)."
  :type '(choice (const surface) (const 850) (const 500) (const 250))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-particles 400
  "Number of wind particles (each is one globe entity; the render cap
`cmacs-gnuseye-render-max' culls beyond it)."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-exaggeration 40.0
  "Motion exaggeration: real m/s are imperceptible at globe scale."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-trail-length 8
  "Streak length in tick samples."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-wind-ttl '(20 . 60)
  "Particle lifetime range in seconds (MIN . MAX)."
  :type '(cons integer integer) :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-meteo--wind-field nil
  "Vector of rows; each row a vector of (U . V) m/s, west->east.")
(defvar cmacs-gnuseye-meteo--wind-meta nil
  "Plist :lat0 :lon0 :step :rows :cols :ts :level.")

(defun cmacs-gnuseye-meteo--wind-cache-file ()
  (cmacs-gnuseye-overlay-cache-file
   "wind" (format "grid-%s-%d.el" cmacs-gnuseye-wind-level
                  cmacs-gnuseye-wind-grid-step)))

(defun cmacs-gnuseye-meteo--wind-points ()
  "Row-major grid points ((LAT . LON) ...)."
  (let* ((step cmacs-gnuseye-wind-grid-step)
         (lat0 (car cmacs-gnuseye-wind-lat-range))
         (lat1 (cdr cmacs-gnuseye-wind-lat-range))
         (pts nil))
    (let ((lat lat0))
      (while (<= lat lat1)
        (let ((lon -180))
          (while (< lon 180)
            (push (cons lat lon) pts)
            (setq lon (+ lon step))))
        (setq lat (+ lat step))))
    (nreverse pts)))

(defun cmacs-gnuseye-meteo--wind-uv (speed dir)
  "(U . V) motion vector from SPEED (m/s) and meteorological DIR (from)."
  (if (and (numberp speed) (numberp dir))
      (let ((r (* (+ dir 180.0) (/ float-pi 180.0))))
        (cons (* speed (sin r)) (* speed (cos r))))
    (cons 0.0 0.0)))

(defun cmacs-gnuseye-meteo--wind-hour-index (hourly)
  "Index of the current UTC hour in HOURLY's time array, or 0."
  (let ((now (format-time-string "%Y-%m-%dT%H:00" nil t))
        (idx 0) (found 0))
    (dolist (tm (alist-get 'time hourly))
      (when (equal tm now) (setq found idx))
      (setq idx (1+ idx)))
    found))

(defun cmacs-gnuseye-meteo--wind-parse-one (obj)
  "(U . V) for one Open-Meteo location OBJ at the configured level."
  (if (eq cmacs-gnuseye-wind-level 'surface)
      (let ((cur (alist-get 'current obj)))
        (cmacs-gnuseye-meteo--wind-uv
         (alist-get 'wind_speed_10m cur)
         (alist-get 'wind_direction_10m cur)))
    (let* ((hourly (alist-get 'hourly obj))
           (i (cmacs-gnuseye-meteo--wind-hour-index hourly))
           (sk (intern (format "wind_speed_%shPa" cmacs-gnuseye-wind-level)))
           (dk (intern (format "wind_direction_%shPa"
                               cmacs-gnuseye-wind-level))))
      (cmacs-gnuseye-meteo--wind-uv
       (nth i (alist-get sk hourly))
       (nth i (alist-get dk hourly))))))

(defun cmacs-gnuseye-meteo--wind-save ()
  (ignore-errors
    (with-temp-file (cmacs-gnuseye-meteo--wind-cache-file)
      (prin1 (list cmacs-gnuseye-meteo--wind-meta
                   cmacs-gnuseye-meteo--wind-field)
             (current-buffer)))))

(defun cmacs-gnuseye-meteo--wind-load ()
  "Load a cached wind grid; non-nil when a usable one was found."
  (let ((f (cmacs-gnuseye-meteo--wind-cache-file)))
    (when (file-readable-p f)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents f)
          (let ((data (read (current-buffer))))
            (setq cmacs-gnuseye-meteo--wind-meta (nth 0 data)
                  cmacs-gnuseye-meteo--wind-field (nth 1 data))
            t))))))

(defun cmacs-gnuseye-meteo--wind-fresh-p ()
  (let ((ts (plist-get cmacs-gnuseye-meteo--wind-meta :ts))
        (lvl (plist-get cmacs-gnuseye-meteo--wind-meta :level)))
    (and cmacs-gnuseye-meteo--wind-field ts
         (equal lvl cmacs-gnuseye-wind-level)
         (< (- (float-time) ts) 10800))))

(defun cmacs-gnuseye-meteo--wind-refetch (cb)
  "Rebuild the wind grid from Open-Meteo; call (CB OK)."
  (let* ((pts (cmacs-gnuseye-meteo--wind-points))
         (n (length pts))
         (vals (make-vector n nil))
         (chunks nil)
         (offset 0))
    (while pts
      (push (cons offset (seq-take pts 60)) chunks)
      (setq offset (+ offset (length (seq-take pts 60)))
            pts (nthcdr 60 pts)))
    (let ((pending (length chunks)))
      (if (zerop pending)
          (funcall cb nil)
        (dolist (chunk chunks)
          (let* ((off (car chunk))
                 (cpts (cdr chunk))
                 (lats (mapconcat (lambda (p) (number-to-string (car p)))
                                  cpts ","))
                 (lons (mapconcat (lambda (p) (number-to-string (cdr p)))
                                  cpts ","))
                 (url (format
                       "%s?latitude=%s&longitude=%s&%s&wind_speed_unit=ms"
                       cmacs-gnuseye-wind-url lats lons
                       (if (eq cmacs-gnuseye-wind-level 'surface)
                           "current=wind_speed_10m,wind_direction_10m"
                         (format "hourly=wind_speed_%shPa,wind_direction_%shPa&forecast_days=1"
                                 cmacs-gnuseye-wind-level
                                 cmacs-gnuseye-wind-level)))))
            (cmacs-gnuseye-fetch-json
             url
             (lambda (data)
               ;; Multi-location responses are arrays; a lone point is a
               ;; bare object.
               (let ((objs (cond ((null data) nil)
                                 ((and (listp data)
                                       (listp (car-safe data))
                                       (alist-get 'latitude (car data)))
                                  data)
                                 (t (list data))))
                     (i 0))
                 (dolist (obj objs)
                   (when (< (+ off i) n)
                     (aset vals (+ off i)
                           (cmacs-gnuseye-meteo--wind-parse-one obj)))
                   (setq i (1+ i))))
               (when (zerop (setq pending (1- pending)))
                 ;; Assemble rows.
                 (let* ((step cmacs-gnuseye-wind-grid-step)
                        (cols (/ 360 step))
                        (rows (/ n cols))
                        (field (make-vector rows nil)))
                   (dotimes (r rows)
                     (let ((row (make-vector cols (cons 0.0 0.0))))
                       (dotimes (c cols)
                         (aset row c (or (aref vals (+ (* r cols) c))
                                         (cons 0.0 0.0))))
                       (aset field r row)))
                   (setq cmacs-gnuseye-meteo--wind-field field
                         cmacs-gnuseye-meteo--wind-meta
                         (list :lat0 (car cmacs-gnuseye-wind-lat-range)
                               :lon0 -180
                               :step step :rows rows :cols cols
                               :ts (float-time)
                               :level cmacs-gnuseye-wind-level))
                   (cmacs-gnuseye-meteo--wind-save)
                   (funcall cb t)))))))))))

(defun cmacs-gnuseye-meteo-wind-at (lat lon)
  "Bilinearly interpolated (U . V) at LAT LON from the wind grid."
  (let ((meta cmacs-gnuseye-meteo--wind-meta)
        (field cmacs-gnuseye-meteo--wind-field))
    (if (not (and meta field)) (cons 0.0 0.0)
      (let* ((step (float (plist-get meta :step)))
             (lat0 (plist-get meta :lat0))
             (lon0 (plist-get meta :lon0))
             (rows (plist-get meta :rows))
             (cols (plist-get meta :cols))
             (fr (/ (- (max (float lat0)
                            (min lat (+ lat0 (* step (1- rows)))))
                       lat0)
                    step))
             (fc (/ (mod (- lon lon0) 360.0) step))
             (r0 (min (1- rows) (max 0 (floor fr))))
             (r1 (min (1- rows) (1+ r0)))
             (c0 (% (floor fc) cols))
             (c1 (% (1+ c0) cols))
             (tr (- fr r0)) (tc (- fc (floor fc)))
             (p00 (aref (aref field r0) c0))
             (p01 (aref (aref field r0) c1))
             (p10 (aref (aref field r1) c0))
             (p11 (aref (aref field r1) c1))
             (u (+ (* (- 1 tr) (+ (* (- 1 tc) (car p00)) (* tc (car p01))))
                   (* tr (+ (* (- 1 tc) (car p10)) (* tc (car p11))))))
             (v (+ (* (- 1 tr) (+ (* (- 1 tc) (cdr p00)) (* tc (cdr p01))))
                   (* tr (+ (* (- 1 tc) (cdr p10)) (* tc (cdr p11)))))))
        (cons u v)))))

(defun cmacs-gnuseye-meteo--wind-color (spd)
  (cond ((< spd 3) "#4a90d0")
        ((< spd 8) "#7cf7c8")
        ((< spd 15) "#ffd24a")
        (t "#ff5a3a")))

(defun cmacs-gnuseye-meteo--wind-spawn (e)
  "(Re)spawn particle plist E at a windy spot; returns E."
  (let* ((lat0 (car cmacs-gnuseye-wind-lat-range))
         (lat1 (cdr cmacs-gnuseye-wind-lat-range))
         (lat 0.0) (lon 0.0) (uv nil) (spd 0.0))
    ;; A few weighted tries: prefer lively cells so streaks show flow.
    (cl-dotimes (_ 6)
      (setq lat (+ lat0 (* (- lat1 lat0) (/ (random 1000) 1000.0)))
            lon (- (* 360.0 (/ (random 1000) 1000.0)) 180.0)
            uv (cmacs-gnuseye-meteo-wind-at lat lon)
            spd (sqrt (+ (* (car uv) (car uv)) (* (cdr uv) (cdr uv)))))
      (when (> spd 2.0) (cl-return)))
    (plist-put e :lat lat)
    (plist-put e :lon lon)
    (plist-put e :trail nil)
    (plist-put e :color (cmacs-gnuseye-meteo--wind-color spd))
    (plist-put e :ttl (+ (car cmacs-gnuseye-wind-ttl)
                         (random (max 1 (- (cdr cmacs-gnuseye-wind-ttl)
                                           (car cmacs-gnuseye-wind-ttl))))))
    e))

(defun cmacs-gnuseye-meteo--wind-seed ()
  "Fresh particle entity list."
  (let (out)
    (dotimes (i cmacs-gnuseye-wind-particles)
      (push (cmacs-gnuseye-meteo--wind-spawn
             (list :id (format "wp:%d" i) :kind 'windp
                   :lat 0.0 :lon 0.0 :scale 0.25 :label-mode 0))
            out))
    out))

(defun cmacs-gnuseye-meteo--wind-advance (entities dt _now)
  "Advect particles through the wind field (the layer's :advance hook)."
  (let ((k (* dt cmacs-gnuseye-wind-exaggeration))
        (lat0 (- (car cmacs-gnuseye-wind-lat-range) 5))
        (lat1 (+ (cdr cmacs-gnuseye-wind-lat-range) 5))
        (tl cmacs-gnuseye-wind-trail-length))
    (dolist (e entities)
      (let* ((lat (plist-get e :lat))
             (lon (plist-get e :lon))
             (uv (cmacs-gnuseye-meteo-wind-at lat lon))
             (u (car uv)) (v (cdr uv))
             (spd (sqrt (+ (* u u) (* v v))))
             (ttl (- (or (plist-get e :ttl) 0) dt)))
        (if (or (<= ttl 0) (< spd 0.3) (< lat lat0) (> lat lat1))
            (cmacs-gnuseye-meteo--wind-spawn e)
          (let* ((dlat (/ (* v k) 111320.0))
                 (dlon (/ (* u k)
                          (* 111320.0
                             (max 0.15 (abs (cos (* lat (/ float-pi
                                                           180.0)))))))))
            (plist-put e :ttl ttl)
            (plist-put e :trail
                       (cons (list lat lon)
                             (seq-take (plist-get e :trail) (1- tl))))
            (plist-put e :lat (max -89.0 (min 89.0 (+ lat dlat))))
            (plist-put e :lon (- (mod (+ lon dlon 540.0) 360.0) 180.0))))))))

(defun cmacs-gnuseye-meteo--wind-fetch (cb)
  (cond
   ((cmacs-gnuseye-meteo--wind-fresh-p)
    (funcall cb (cmacs-gnuseye-meteo--wind-seed)))
   ((and (null cmacs-gnuseye-meteo--wind-field)
         (cmacs-gnuseye-meteo--wind-load)
         (cmacs-gnuseye-meteo--wind-fresh-p))
    (funcall cb (cmacs-gnuseye-meteo--wind-seed))
    (cmacs-gnuseye-meteo--wind-refetch #'ignore))
   (t
    (cmacs-gnuseye-meteo--wind-refetch
     (lambda (ok)
       (funcall cb (and (or ok cmacs-gnuseye-meteo--wind-field)
                        (cmacs-gnuseye-meteo--wind-seed))))))))

;;;###autoload
(defun cmacs-gnuseye-wind-cycle-level ()
  "Cycle the wind layer between surface, 850, 500, and 250 hPa."
  (interactive)
  (setq cmacs-gnuseye-wind-level
        (cadr (memq cmacs-gnuseye-wind-level '(surface 850 500 250 surface))))
  (setq cmacs-gnuseye-meteo--wind-meta nil
        cmacs-gnuseye-meteo--wind-field nil)
  (let ((layer (gethash 'wind-particles cmacs-gnuseye--layers)))
    (when (and layer (cmacs-gnuseye-layer-enabled layer))
      (cmacs-gnuseye--refresh-layer layer)))
  (message "GNU's Eye: wind level %s"
           (if (eq cmacs-gnuseye-wind-level 'surface) "surface (10 m)"
             (format "%s hPa" cmacs-gnuseye-wind-level))))

(cmacs-gnuseye-define-layer wind-particles
  :title "Wind flow (Open-Meteo)"
  :group 'meteo
  :kind 'windp
  :interval 10800
  :default-on nil
  :transient t
  :fetch #'cmacs-gnuseye-meteo--wind-fetch
  :advance #'cmacs-gnuseye-meteo--wind-advance)

;;;; METAR surface observations -----------------------------------------------

(defcustom cmacs-gnuseye-metar-url "https://aviationweather.gov/api/data/metar"
  "aviationweather.gov METAR endpoint (JSON, keyless)."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-metar-max 400
  "Hard cap on METAR stations kept per refresh."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-metar-refresh-move-deg 8.0
  "Re-fetch when the view centre moved this many degrees."
  :type 'number :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-meteo--metar-center nil)
(defvar cmacs-gnuseye-meteo--metar-last-check 0)

(defconst cmacs-gnuseye-meteo--fltcat-colors
  '(("VFR" . "#3adf6a") ("MVFR" . "#4a90ff")
    ("IFR" . "#ff5a5a") ("LIFR" . "#ff2ad0")))

(defun cmacs-gnuseye-meteo--metar-bboxes ()
  "View-scoped bbox strings (minLat,minLon,maxLat,maxLon)."
  (let* ((buf (cmacs-gnuseye-meteo--globe-buffer))
         (vc (and buf (ignore-errors (cmacs-gnuseye-view-center buf)))))
    (if (not (and (consp vc) (numberp (nth 0 vc))))
        '("-85,-180,85,180")
      (let* ((lat (nth 0 vc)) (lon (nth 1 vc))
             (dist (max 6.4 (or (nth 2 vc) 12.0)))
             (half (max 8.0 (min 55.0
                                 (* (/ 180.0 float-pi)
                                    (acos (min 1.0 (/ 6.371 dist)))))))
             (la0 (max -85.0 (- lat half)))
             (la1 (min 85.0 (+ lat half)))
             (lo0 (max -180.0 (- lon (* half 1.4))))
             (lo1 (min 180.0 (+ lon (* half 1.4)))))
        (setq cmacs-gnuseye-meteo--metar-center (cons lat lon))
        (list (format "%.1f,%.1f,%.1f,%.1f" la0 lo0 la1 lo1))))))

(defun cmacs-gnuseye-meteo--metar-parse (data)
  "Entities from an aviationweather METAR array DATA."
  (let (out)
    (dolist (m data)
      (let ((lat (cmacs-gnuseye-meteo--num (alist-get 'lat m)))
            (lon (cmacs-gnuseye-meteo--num (alist-get 'lon m)))
            (icao (alist-get 'icaoId m)))
        (when (and (numberp lat) (numberp lon) icao)
          (let* ((cat (format "%s" (or (alist-get 'fltCat m) "")))
                 (temp (cmacs-gnuseye-meteo--num (alist-get 'temp m)))
                 (dewp (cmacs-gnuseye-meteo--num (alist-get 'dewp m)))
                 (wdir (cmacs-gnuseye-meteo--num (alist-get 'wdir m)))
                 (wspd (cmacs-gnuseye-meteo--num (alist-get 'wspd m)))
                 (clouds (mapconcat
                          (lambda (c)
                            (format "%s%s" (or (alist-get 'cover c) "")
                                    (if (alist-get 'base c)
                                        (format "@%s" (alist-get 'base c))
                                      "")))
                          (alist-get 'clouds m) " ")))
            (push (list :id (format "metar:%s" icao)
                        :kind 'metar :lat lat :lon lon
                        :label (format "%s" icao)
                        :label-mode 2 :scale 0.55
                        :color (or (cdr (assoc cat
                                               cmacs-gnuseye-meteo--fltcat-colors))
                                   "#9ab8d8")
                        :data `((station . ,(alist-get 'name m))
                                (flight-category . ,cat)
                                (temp-c . ,temp) (dewpoint-c . ,dewp)
                                (wind . ,(format "%s° %s kt"
                                                 (or wdir "?") (or wspd "?")))
                                (altim-hpa
                                 . ,(cmacs-gnuseye-meteo--num
                                     (alist-get 'altim m)))
                                (clouds . ,clouds)
                                (raw . ,(alist-get 'rawOb m))))
                  out)))))
    (nreverse out)))

(defun cmacs-gnuseye-meteo--metar-fetch (cb)
  (let* ((bboxes (cmacs-gnuseye-meteo--metar-bboxes))
         (pending (length bboxes))
         (byid (make-hash-table :test 'equal)))
    (add-hook 'cmacs-gnuseye--tick-functions
              #'cmacs-gnuseye-meteo--metar-tick)
    (dolist (bbox bboxes)
      (cmacs-gnuseye-fetch-json
       (format "%s?bbox=%s&format=json" cmacs-gnuseye-metar-url bbox)
       (lambda (data)
         (when (listp data)
           (dolist (e (cmacs-gnuseye-meteo--metar-parse data))
             (puthash (plist-get e :id) e byid)))
         (when (zerop (setq pending (1- pending)))
           (let (all)
             (maphash (lambda (_ e) (push e all)) byid)
             (funcall cb (seq-take all cmacs-gnuseye-metar-max)))))
       nil 'list))))

(defun cmacs-gnuseye-meteo--metar-tick (buf now _dt)
  "Re-fetch the view-scoped observations when the camera moved far."
  (when (>= (- now cmacs-gnuseye-meteo--metar-last-check) 10)
    (setq cmacs-gnuseye-meteo--metar-last-check now)
    (let ((layer (gethash 'metar cmacs-gnuseye--layers))
          (vc (ignore-errors (cmacs-gnuseye-view-center buf))))
      (when (and layer (cmacs-gnuseye-layer-enabled layer)
                 (not (cmacs-gnuseye-layer-in-flight layer))
                 (consp vc) (numberp (nth 0 vc))
                 cmacs-gnuseye-meteo--metar-center)
        (let ((d (cmacs-gnuseye-haversine
                  (car cmacs-gnuseye-meteo--metar-center)
                  (cdr cmacs-gnuseye-meteo--metar-center)
                  (nth 0 vc) (nth 1 vc))))
          (when (> d (* cmacs-gnuseye-metar-refresh-move-deg 111320.0))
            (cmacs-gnuseye--refresh-layer layer)))))))

(cmacs-gnuseye-define-layer metar
  :title "Surface observations (METAR)"
  :group 'meteo
  :kind 'metar
  :interval 600
  :default-on nil
  :cluster t
  :fetch #'cmacs-gnuseye-meteo--metar-fetch
  :teardown (lambda ()
              (remove-hook 'cmacs-gnuseye--tick-functions
                           #'cmacs-gnuseye-meteo--metar-tick)
              (setq cmacs-gnuseye-meteo--metar-center nil)))

;;;; Point forecast (Open-Meteo) ----------------------------------------------

(defcustom cmacs-gnuseye-forecast-url "https://api.open-meteo.com/v1/forecast"
  "Open-Meteo endpoint for the click-anywhere forecast panel (keyless)."
  :type 'string :group 'cmacs-gnuseye)

(defconst cmacs-gnuseye-meteo--wmo-codes
  '((0 . "clear") (1 . "mostly clear") (2 . "partly cloudy") (3 . "overcast")
    (45 . "fog") (48 . "rime fog")
    (51 . "light drizzle") (53 . "drizzle") (55 . "heavy drizzle")
    (56 . "freezing drizzle") (57 . "freezing drizzle")
    (61 . "light rain") (63 . "rain") (65 . "heavy rain")
    (66 . "freezing rain") (67 . "freezing rain")
    (71 . "light snow") (73 . "snow") (75 . "heavy snow") (77 . "snow grains")
    (80 . "light showers") (81 . "showers") (82 . "violent showers")
    (85 . "snow showers") (86 . "snow showers")
    (95 . "thunderstorm") (96 . "thunderstorm w/ hail")
    (99 . "thunderstorm w/ hail")))

(defun cmacs-gnuseye-meteo--wmo (code)
  (or (alist-get (or (cmacs-gnuseye-meteo--num code) -1)
                 cmacs-gnuseye-meteo--wmo-codes)
      "?"))

(defvar cmacs-gnuseye-forecast-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    map))

(define-derived-mode cmacs-gnuseye-forecast-mode special-mode "GnuseyeWx"
  "Read-only viewer for GNU's Eye point forecasts.")

;; Under Evil (Doom) `q' records a macro instead of quitting this pane;
;; install the map as an Evil intercept map (see cmacs-evil.el).
(cmacs-evil-setup-mode-map cmacs-gnuseye-forecast-mode-map
                           'cmacs-gnuseye-forecast-mode)

(defun cmacs-gnuseye-meteo--spark (values)
  "Sparkline string for VALUES (SVG when available, else unicode)."
  (if (fboundp 'cmacs-gnuseye-chart-sparkline)
      (cmacs-gnuseye-chart-sparkline values 220 24)
    ""))

(defun cmacs-gnuseye-meteo--forecast-render (lat lon label data)
  "Fill the forecast buffer from Open-Meteo DATA."
  (let ((buf (get-buffer-create "*GNU's Eye Forecast*"))
        (cur (alist-get 'current data))
        (hourly (alist-get 'hourly data))
        (daily (alist-get 'daily data)))
    (with-current-buffer buf
      (cmacs-gnuseye-forecast-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "%s\n" (or label "Forecast"))
                            'face 'bold))
        (insert (format "%.2f°, %.2f° · %s\n\n" lat lon
                        (or (alist-get 'timezone data) "UTC")))
        (when cur
          (insert (propertize "Now  " 'face 'bold)
                  (format "%s°C (feels %s°C) · %s\n"
                          (or (alist-get 'temperature_2m cur) "?")
                          (or (alist-get 'apparent_temperature cur) "?")
                          (cmacs-gnuseye-meteo--wmo
                           (alist-get 'weather_code cur)))
                  (format "     wind %s m/s %s · humidity %s%% · %s hPa · precip %s mm\n\n"
                          (or (alist-get 'wind_speed_10m cur) "?")
                          (cmacs-gnuseye-meteo--compass
                           (alist-get 'wind_direction_10m cur))
                          (or (alist-get 'relative_humidity_2m cur) "?")
                          (or (alist-get 'pressure_msl cur) "?")
                          (or (alist-get 'precipitation cur) "?"))))
        (when hourly
          (let ((temps (seq-take (alist-get 'temperature_2m hourly) 48))
                (pprob (seq-take (alist-get 'precipitation_probability hourly)
                                 48))
                (wind (seq-take (alist-get 'wind_speed_10m hourly) 48)))
            (insert (propertize "Next 48 h\n" 'face 'bold))
            (insert "  temp   " (cmacs-gnuseye-meteo--spark temps) "\n")
            (insert "  precip " (cmacs-gnuseye-meteo--spark pprob) "\n")
            (insert "  wind   " (cmacs-gnuseye-meteo--spark wind) "\n\n")))
        (when daily
          (insert (propertize "7-day\n" 'face 'bold))
          (let ((times (alist-get 'time daily))
                (tmax (alist-get 'temperature_2m_max daily))
                (tmin (alist-get 'temperature_2m_min daily))
                (rain (alist-get 'precipitation_sum daily))
                (code (alist-get 'weather_code daily))
                (i 0))
            (dolist (day times)
              (insert (format "  %s  %5s / %-5s  %4s mm  %s\n"
                              day
                              (or (nth i tmax) "?") (or (nth i tmin) "?")
                              (or (nth i rain) "?")
                              (cmacs-gnuseye-meteo--wmo (nth i code))))
              (setq i (1+ i)))))
        (insert "\nSource: open-meteo.com\n")
        (goto-char (point-min))))
    (display-buffer-in-side-window
     buf '((side . right) (slot . 2) (window-width . 0.32)))))

;;;###autoload
(defun cmacs-gnuseye-forecast-at (lat lon &optional label)
  "Show the Open-Meteo forecast panel for LAT, LON."
  (interactive "nLatitude: \nnLongitude: ")
  (let ((url (format
              (concat "%s?latitude=%.4f&longitude=%.4f"
                      "&current=temperature_2m,apparent_temperature,"
                      "relative_humidity_2m,precipitation,weather_code,"
                      "wind_speed_10m,wind_direction_10m,pressure_msl"
                      "&hourly=temperature_2m,precipitation_probability,"
                      "wind_speed_10m"
                      "&daily=weather_code,temperature_2m_max,"
                      "temperature_2m_min,precipitation_sum"
                      "&forecast_days=7&timezone=auto&wind_speed_unit=ms")
              cmacs-gnuseye-forecast-url lat lon)))
    (message "GNU's Eye: fetching forecast…")
    (cmacs-gnuseye-fetch-json
     url
     (lambda (data)
       (if (not data)
           (message "GNU's Eye: forecast fetch failed")
         (cmacs-gnuseye-meteo--forecast-render lat lon label data))))))

(defun cmacs-gnuseye-forecast-entity (e)
  "Forecast panel for entity E's position (inspector action)."
  (cmacs-gnuseye-forecast-at (plist-get e :lat) (plist-get e :lon)
                             (plist-get e :label)))

(defvar cmacs-gnuseye-meteo--fc-armed nil)

(defun cmacs-gnuseye-meteo--fc-click (buffer _node-id vx vy)
  "One-shot click consumer for `cmacs-gnuseye-forecast-here'."
  (when cmacs-gnuseye-meteo--fc-armed
    (setq cmacs-gnuseye-meteo--fc-armed nil)
    (remove-hook 'cmacs-gnuseye--click-functions
                 #'cmacs-gnuseye-meteo--fc-click)
    (let ((ll (and (fboundp 'cmacs-gnuseye-screen-to-globe)
                   (cmacs-gnuseye-screen-to-globe buffer vx vy))))
      (if ll
          (cmacs-gnuseye-forecast-at (nth 0 ll) (nth 1 ll))
        (message "GNU's Eye: that click missed the globe")))
    t))

;;;###autoload
(defun cmacs-gnuseye-forecast-here ()
  "Arm a one-shot click: the next globe click opens its forecast."
  (interactive)
  (setq cmacs-gnuseye-meteo--fc-armed t)
  (add-hook 'cmacs-gnuseye--click-functions
            #'cmacs-gnuseye-meteo--fc-click)
  (message "GNU's Eye: click anywhere on the globe for its forecast"))

;;;; Showcase ------------------------------------------------------------------

(defcustom cmacs-gnuseye-showcase-fallback '(25.0 -60.0 8.0)
  "Fly-to (LAT LON RANGE) when no tropical cyclone is active."
  :type '(list number number number) :group 'cmacs-gnuseye)

(defconst cmacs-gnuseye-meteo--showcase-layers
  '(cyclones radar clouds wind-particles metar nws-alerts))

(defun cmacs-gnuseye-meteo--showcase-fly (attempts)
  "Fly to the strongest storm once cyclone data lands (poll ATTEMPTS)."
  (let ((best (cmacs-gnuseye-cyclones--strongest))
        (buf (cmacs-gnuseye-meteo--globe-buffer)))
    (cond
     ((null buf) nil)
     (best
      (cmacs-gnuseye--select-entity (plist-get best :id))
      (message "GNU's Eye: %s — the strongest active cyclone"
               (plist-get best :label)))
     ((> attempts 0)
      (run-with-timer 2 nil #'cmacs-gnuseye-meteo--showcase-fly
                      (1- attempts)))
     (t
      (when (fboundp 'cmacs-gnuseye-fly-to)
        (apply #'cmacs-gnuseye-fly-to buf cmacs-gnuseye-showcase-fallback))
      (message "GNU's Eye: no active tropical cyclones — showing radar/clouds")))))

;;;###autoload
(defun cmacs-gnuseye-weather-showcase ()
  "Light the whole weather picture and fly to the strongest storm.
Enables cyclones, radar (animated), clouds, wind particles, METARs, and
the US NWS alert zones; with no active cyclone it settles over the
Atlantic basin."
  (interactive)
  (unless (fboundp 'cmacs-gnuseye)
    (user-error "GNU's Eye is not available in this build"))
  (cmacs-gnuseye)
  (dolist (name cmacs-gnuseye-meteo--showcase-layers)
    (let ((layer (gethash name cmacs-gnuseye--layers)))
      (when (and layer (not (cmacs-gnuseye-layer-enabled layer))
                 (or (memq name '(cyclones wind-particles metar nws-alerts))
                     (cmacs-gnuseye-overlay-supported-p)))
        (let ((needs (cmacs-gnuseye-layer-needs-key layer)))
          (unless (and needs (not (cmacs-gnuseye-secret needs)))
            (cmacs-gnuseye--enable-layer layer))))))
  (when (and (cmacs-gnuseye-overlay-supported-p)
             (not cmacs-gnuseye-meteo--radar-anim))
    (setq cmacs-gnuseye-meteo--radar-anim t))
  (cmacs-gnuseye-layers-refresh)
  (run-with-timer 3 nil #'cmacs-gnuseye-meteo--showcase-fly 5)
  (message "GNU's Eye: weather showcase — cyclones, radar, clouds, wind"))

;;;; Keybindings + inspector action -------------------------------------------

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "R") #'cmacs-gnuseye-radar-animate)
  (define-key cmacs-gnuseye-mode-map (kbd "W")
              #'cmacs-gnuseye-weather-showcase)
  (define-key cmacs-gnuseye-mode-map (kbd "P") #'cmacs-gnuseye-forecast-here)
  (define-key cmacs-gnuseye-mode-map (kbd "E") #'cmacs-gnuseye-earth-today))

(when (fboundp 'cmacs-gnuseye-register-inspector-action)
  (cmacs-gnuseye-register-inspector-action
   "p" "forecast" #'cmacs-gnuseye-forecast-entity
   (lambda (e) (numberp (plist-get e :lat)))))

(provide 'cmacs-gnuseye-meteo)
;;; cmacs-gnuseye-meteo.el ends here
