;;; cmacs-gnuseye.el --- GNU's Eye: live planetary situational globe  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; GNU's Eye (gnuseye) is a Google-Earth / Palantir-style live 3D globe
;; rendered through the libregnum subsystem.  Real-time geospatial feeds
;; (satellites, aircraft, vessels, weather, geo-events) are drawn as
;; clickable markers on a textured Earth.
;;
;; The crux is EXTENSIBILITY: data sources are LAYERS defined in Elisp via
;; `cmacs-gnuseye-define-layer'.  Each layer supplies an async fetch
;; function that returns a list of entity plists; the C core
;; (`cmacs-gnuseye-set-entities') renders whatever entities a layer pushes
;; and stashes each entity as its marker's pick payload.  Adding a new feed
;; is one macro call -- no rebuild.
;;
;; Entity plist schema (what a layer's fetch returns):
;;   (:id S :lat F :lon F                       ; required
;;    :alt F :heading F :speed F :kind SYM       ; optional
;;    :label S :color "#rrggbb" :scale F :trail LIST
;;    :detail FN :data ANY :ts F)
;; Only :id :lat :lon are required.  :kind selects an icon/colour style.
;; :data is an opaque escape hatch surfaced in the detail view.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url)
(require 'cmacs-evil)                   ;Evil/Doom keymap precedence
;; The C input handler dispatches every globe click to
;; `cmacs-libregnum--node-clicked' (defined in cmacs-libregnum.el), which
;; routes it back to `cmacs-gnuseye--on-pick'.  Without this require, a
;; gnuseye-only session never loads that dispatcher and every click dies
;; inside safe_call with (void-function cmacs-libregnum--node-clicked).
(require 'cmacs-libregnum)

(declare-function cmacs-libregnum-resize "cmacs-libregnum-defuns.c"
                  (buffer width height))

(defgroup cmacs-gnuseye nil
  "GNU's Eye live planetary globe."
  :group 'cmacs
  :prefix "cmacs-gnuseye-")

(defcustom cmacs-gnuseye-base-texture nil
  "Path to an equirectangular Earth texture (e.g. NASA Blue Marble).
When nil or missing, a procedural ocean+graticule globe is used."
  :type '(choice (const :tag "Procedural" nil) (file :must-match t))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-default-layers '(satellites aircraft quakes)
  "Layer names enabled automatically when the globe opens."
  :type '(repeat symbol)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-focus-range 5.0
  "Camera range (world units) used when clicking a marker to recentre on it.
Smaller zooms in closer."
  :type 'number
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-layer-files
  '(cmacs-gnuseye-astro cmacs-gnuseye-air
    cmacs-gnuseye-marine cmacs-gnuseye-weather cmacs-gnuseye-meteo
    cmacs-gnuseye-natural cmacs-gnuseye-space cmacs-gnuseye-conflict
    cmacs-gnuseye-infra cmacs-gnuseye-health cmacs-gnuseye-media
    cmacs-gnuseye-keyed cmacs-gnuseye-celestial)
  "Feature files providing the built-in layers, loaded when the globe opens."
  :type '(repeat symbol)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-keys-file
  (expand-file-name "cmacs/gnuseye/keys.el"
                    (or (getenv "XDG_CONFIG_HOME") "~/.config"))
  "Optional alist file mapping API-key names to values.
Read on demand by `cmacs-gnuseye-secret'.  Keep it out of version control."
  :type 'file
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-feature-files
  '(cmacs-gnuseye-geoloc cmacs-gnuseye-charts cmacs-gnuseye-history
    cmacs-gnuseye-viz cmacs-gnuseye-measure cmacs-gnuseye-export
    cmacs-gnuseye-watch cmacs-gnuseye-news cmacs-gnuseye-country
    cmacs-gnuseye-search cmacs-gnuseye-stats cmacs-gnuseye-geofence
    cmacs-gnuseye-bookmarks cmacs-gnuseye-replay cmacs-gnuseye-intel
    cmacs-gnuseye-track cmacs-gnuseye-markets cmacs-gnuseye-overlay)
  "Interaction/intelligence feature files loaded when the globe opens.
Distinct from `cmacs-gnuseye-layer-files' (data layers).  Each is required
softly, so a file that does not exist yet is simply skipped."
  :type '(repeat symbol)
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--config-dir ()
  "Directory holding GNU's Eye user config (bookmarks, tours, geofences)."
  (expand-file-name "cmacs/gnuseye/"
                    (or (getenv "XDG_CONFIG_HOME") "~/.config")))

(defun cmacs-gnuseye--config-file (name)
  "Absolute path of config file NAME under the GNU's Eye config dir.
Ensures the directory exists."
  (let ((dir (cmacs-gnuseye--config-dir)))
    (unless (file-directory-p dir) (ignore-errors (make-directory dir t)))
    (expand-file-name name dir)))

(defun cmacs-gnuseye--load-features ()
  "Load the interaction/intelligence feature files (soft require)."
  (dolist (f cmacs-gnuseye-feature-files)
    (require f nil t)))

(defvar cmacs-gnuseye-buffer nil
  "The active GNU's Eye globe buffer that layer timers push entities to.")

;;;; Entity index, filter, and selection state -------------------------------

(defvar cmacs-gnuseye--layer-entities (make-hash-table :test 'eq)
  "Layer-name symbol -> list of the layer's current (rich) entity plists.
The source of truth the dashboard list, search, and filter operate on, and
what the globe is (re)rendered from.")

(defvar cmacs-gnuseye--id-index (make-hash-table :test 'equal)
  "Entity :id string -> entity plist (tagged with :layer) for quick lookup.")

(defvar cmacs-gnuseye-active-kinds nil
  "When nil, show every marker kind; otherwise a list of kind symbols to
show.  Applies to BOTH the globe and the entity list, so you can declutter
to e.g. only planes, or planes and boats.")

(defvar cmacs-gnuseye--search ""
  "Case-insensitive substring narrowing the entity list (label/id/kind).")

(defvar cmacs-gnuseye--selected-id nil
  "The :id of the currently selected entity (labelled + highlighted).")

(defconst cmacs-gnuseye--known-kinds
  '(satellite aircraft ship quake fire launch storm camera city
    event volcano alert cyber outage cable port health radiation airq
    displaced base spaceport hotspot
    cyclone metar windp
    sun moon planet asteroid probe)
  "Selectable marker kinds for filtering.")

;;;; Kind styles -------------------------------------------------------------

(defconst cmacs-gnuseye--kind-codes
  '((generic . 0) (satellite . 1) (aircraft . 2) (ship . 3)
    (quake . 4) (fire . 5) (launch . 6) (storm . 7) (camera . 8) (city . 9)
    ;; Extended kinds reuse the nearest C marker mesh (0-9) until they get
    ;; bespoke icons; their distinct colour carries the meaning meanwhile.
    (event . 7) (volcano . 5) (alert . 7) (cyber . 0) (outage . 0)
    (cable . 0) (port . 9) (health . 0) (radiation . 0) (airq . 0)
    (displaced . 9) (base . 9) (spaceport . 6) (hotspot . 4)
    ;; Meteorology: cyclone gets the bespoke storm glyph (C mesh 7);
    ;; METAR stations are generic pins, wind particles tiny spheres.
    (cyclone . 7) (metar . 0) (windp . 4)
    ;; Cluster count badges render as small spheres (the quake mesh).
    (cluster . 4)
    ;; Celestial bodies: spheres for worlds, the satellite mesh for probes.
    (sun . 4) (moon . 4) (planet . 4) (asteroid . 4) (probe . 1))
  "Marker kind symbol -> C CmacsGnuseyeMarkerKind code.")

(defcustom cmacs-gnuseye-kind-styles
  '((satellite :color "#9ad0ff" :scale 1.0)
    (aircraft  :color "#ffd24a" :scale 1.0)
    (ship      :color "#7cfc98" :scale 1.0)
    (quake     :color "#ff5a5a" :scale 1.4)
    (fire      :color "#ff8c1a" :scale 1.1)
    (launch    :color "#ff7be5" :scale 1.3)
    (storm     :color "#b0b0ff" :scale 1.2)
    (camera    :color "#7ad7ff" :scale 1.0)
    (city      :color "#dddddd" :scale 0.8)
    (generic   :color "#ffd24a" :scale 1.0)
    ;; Extended kinds (Phase 2+).
    (event     :color "#c0a0ff" :scale 1.1)
    (volcano   :color "#ff7038" :scale 1.2)
    (alert     :color "#ffd23a" :scale 1.0)
    (cyber     :color "#ff3df0" :scale 0.9)
    (outage    :color "#ff9030" :scale 1.0)
    (cable     :color "#7ad7ff" :scale 0.8)
    (port      :color "#7cfc98" :scale 0.9)
    (health    :color "#ff6b6b" :scale 1.0)
    (radiation :color "#c8ff3a" :scale 1.0)
    (airq      :color "#b0d0a0" :scale 0.9)
    (displaced :color "#ffb870" :scale 1.0)
    (base      :color "#9aa6b2" :scale 0.9)
    (spaceport :color "#ff7be5" :scale 1.0)
    (hotspot   :color "#ff2a2a" :scale 1.7)
    (cluster   :color "#9ab8d8" :scale 0.6)
    ;; Meteorology (cmacs-gnuseye-meteo.el); cyclone colour is overridden
    ;; per storm by the Saffir-Simpson ramp, this is the fallback.
    (cyclone   :color "#7cd6ff" :scale 1.2)
    (metar     :color "#9ab8d8" :scale 0.5)
    (windp     :color "#8fd0ff" :scale 0.25)
    ;; Celestial fallbacks; real per-body sqrt-law values come from
    ;; cmacs-gnuseye-celestial--bodies (radius = 6.371*sqrt(R/R_earth)).
    (sun       :color "#ffd96a" :scale 673.0)
    (moon      :color "#cfd2d6" :scale 33.6)
    (planet    :color "#e0bc8f" :scale 129.0)
    (asteroid  :color "#b9b3a8" :scale 4.0)
    (probe     :color "#7ad7ff" :scale 5.0))
  "Per-kind default marker style (:color hex, :scale multiplier)."
  :type '(alist :key-type symbol :value-type plist)
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--color->rgba (color &optional alpha)
  "Convert COLOR (\"#rrggbb\" or \"#rrggbbaa\") to an integer 0xRRGGBBAA.
ALPHA (0-255) is applied when COLOR has no alpha (default 255)."
  (let ((a (or alpha 255)))
    (if (and (stringp color) (string-prefix-p "#" color))
        (let ((hex (substring color 1)))
          (cond
           ((= (length hex) 6) (logior (ash (string-to-number hex 16) 8) a))
           ((= (length hex) 8) (string-to-number hex 16))
           (t (logior (ash #xffd24a 8) a))))
      (logior (ash #xffd24a 8) a))))

;;;; Entity normalisation ----------------------------------------------------

(defun cmacs-gnuseye--normalize-trail (trail)
  "Normalise TRAIL (list/vector of (LAT LON [ALT])) to a vector of [LAT LON ALT]."
  (when (and trail (> (length trail) 1))
    (vconcat
     (mapcar (lambda (p)
               (vector (float (or (elt p 0) 0.0))
                       (float (or (elt p 1) 0.0))
                       (float (or (and (> (length p) 2) (elt p 2)) 0.0))))
             (append trail nil)))))

(defun cmacs-gnuseye--normalize-poly (poly)
  "Normalise POLY (list/vector of (LAT LON)) to a vector of [LAT LON] vertices.
For a filled region draped on the globe (alert zones, AOIs, aurora bands)."
  (when (and poly (> (length poly) 2))
    (vconcat
     (mapcar (lambda (p)
               (vector (float (or (elt p 0) 0.0))
                       (float (or (elt p 1) 0.0))))
             (append poly nil)))))

(defvar cmacs-gnuseye--zoom-scale 1.0
  "Marker scale factor for the current zoom (set per render).
Keeps aircraft a roughly constant on-screen size, so zooming into a busy
airport spreads them out instead of leaving a fixed-size pile.")

(defvar cmacs-gnuseye--render-opacity 1.0
  "Alpha multiplier for the layer being rendered (set per render from
the layer's :opacity).")

(defun cmacs-gnuseye--apply-opacity (rgba mult)
  "Scale the alpha byte of packed RGBA by MULT in [0,1]."
  (if (and (numberp mult) (< mult 1.0))
      (let ((a (round (* (logand rgba #xff) (max 0.0 (min 1.0 mult))))))
        (logior (logand rgba #xffffff00) (logand a #xff)))
    rgba))

(defun cmacs-gnuseye--normalize-entity (e)
  "Normalise a layer entity plist E into the C-facing form.
Resolves :kind to its integer code and :color to packed RGBA, defaults
missing fields, and preserves the original keys (:detail :data ...) so the
stored payload drives the detail view."
  (let* ((kind  (or (plist-get e :kind) 'generic))
         (style (alist-get kind cmacs-gnuseye-kind-styles))
         (color (or (plist-get e :color) (plist-get style :color) "#ffd24a"))
         (scale (float (or (plist-get e :scale) (plist-get style :scale) 1.0)))
         ;; Dense moving kinds keep a roughly constant on-screen size.
         (scale (if (memq kind '(aircraft ship))
                    (* scale cmacs-gnuseye--zoom-scale)
                  scale))
         (code  (or (alist-get kind cmacs-gnuseye--kind-codes) 0))
         (lab   (plist-get e :label))
         (id    (format "%s" (or (plist-get e :id) "")))
         (sel   (and cmacs-gnuseye--selected-id
                     (equal id cmacs-gnuseye--selected-id)))
         ;; Celestial bodies are true-scale globes: enlarging or whitening
         ;; them on selection would destroy the scale/look, so they keep
         ;; their size and colour (their label is always on anyway).
         (celestial (memq kind '(sun moon planet asteroid probe))))
    (list :id        id
          :lat       (float (or (plist-get e :lat) 0.0))
          :lon       (float (or (plist-get e :lon) 0.0))
          :alt       (float (or (plist-get e :alt) 0.0))
          :heading   (float (or (plist-get e :heading) -1.0))
          ;; The selected entity is enlarged, brightened, and always labelled.
          :scale     (if (and sel (not celestial)) (* scale 1.6) scale)
          :kind      code
          :kind-name kind
          :color     (cmacs-gnuseye--apply-opacity
                      (cmacs-gnuseye--color->rgba
                       (if (and sel (not celestial)) "#ffffff" color))
                      cmacs-gnuseye--render-opacity)
          :label     (and lab (format "%s" lab))
          ;; Default "hover" (mouse over to identify); "always" when selected.
          :label-mode (if sel 3 (or (plist-get e :label-mode) 2))
          :trail     (cmacs-gnuseye--normalize-trail (plist-get e :trail))
          :polygon   (cmacs-gnuseye--normalize-poly (plist-get e :polygon))
          :texture   (plist-get e :texture)
          :detail    (plist-get e :detail)
          :data      (plist-get e :data)
          :speed     (plist-get e :speed)
          :ts        (plist-get e :ts))))

(defun cmacs-gnuseye--entities->vector (entities)
  "Normalise a list of layer ENTITIES into the vector C wants."
  (vconcat (delq nil (mapcar #'cmacs-gnuseye--normalize-entity entities))))

;;;; Fetch helpers -----------------------------------------------------------

(defun cmacs-gnuseye-fetch-text (url callback &optional headers)
  "GET URL asynchronously; call (CALLBACK BODY-STRING) or (CALLBACK nil).
HEADERS is an alist of (NAME . VALUE).  Prefers the native libsoup client
when built, else falls back to `url-retrieve' so a layer needs no C."
  (if (fboundp 'cmacs-gnuseye-http-get-async)
      (cmacs-gnuseye-http-get-async
       url (lambda (status body) (funcall callback (and status body))) headers)
    (let ((url-request-extra-headers headers))
      (url-retrieve
       url
       (lambda (status)
         (let ((body (unless (plist-get status :error)
                       (goto-char (point-min))
                       (when (re-search-forward "\n\n" nil t)
                         (decode-coding-string
                          (buffer-substring-no-properties (point) (point-max))
                          'utf-8)))))
           (funcall callback body)))
       nil t t))))

(defun cmacs-gnuseye-fetch-json (url callback &optional headers array-type)
  "GET URL and call (CALLBACK PARSED) with the parsed JSON, or (CALLBACK nil).
HEADERS is an alist of (NAME . VALUE).  ARRAY-TYPE is passed to
`json-parse-string' (default `list')."
  (cmacs-gnuseye-fetch-text
   url
   (lambda (body)
     (funcall callback
              (and body (stringp body)
                   (condition-case nil
                       (json-parse-string body :object-type 'alist
                                          :array-type (or array-type 'list)
                                          :null-object nil :false-object nil)
                     (error nil)))))
   headers))

;;;; Secrets -----------------------------------------------------------------

(defcustom cmacs-gnuseye-secret-use-auth-source t
  "Non-nil to resolve API keys via auth-source (~/.authinfo, ~/.authinfo.gpg).
auth-source sits between environment variables and `cmacs-gnuseye-keys-file'
in `cmacs-gnuseye-secret's resolution order."
  :type 'boolean
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-secret-hosts
  '(("OPENSKY_USER"           :host "opensky-network.org"          :field user)
    ("OPENSKY_PASS"           :host "opensky-network.org"          :field secret)
    ("FIRMS_MAP_KEY"          :host "firms.modaps.eosdis.nasa.gov" :field secret)
    ("OPENAQ_API_KEY"         :host "api.openaq.org"               :field secret)
    ("ACLED_EMAIL"            :host "api.acleddata.com"            :field user)
    ("ACLED_KEY"              :host "api.acleddata.com"            :field secret)
    ("WINDY_WEBCAMS_KEY"      :host "api.windy.com"                :field secret)
    ("FRED_API_KEY"           :host "api.stlouisfed.org"           :field secret)
    ("OPENWEATHERMAP_API_KEY" :host "api.openweathermap.org"       :field secret))
  "API-key NAME -> auth-source lookup spec (:host HOST :field secret|user).
Maps each key name onto the real service hostname in ~/.authinfo(.gpg), so a
single \"machine opensky-network.org login U password P\" line feeds both
OPENSKY_USER (:field user) and OPENSKY_PASS (:field secret); ACLED works the
same way with login = account email.  A name not listed here (or missing at
its mapped host) also tries a literal \"machine NAME\" entry, so any key can
be stored without editing this table."
  :type '(alist :key-type string :value-type plist)
  :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--keys nil)
(defvar cmacs-gnuseye--keys-loaded nil)

(defvar cmacs-gnuseye--secret-memo (make-hash-table :test 'equal)
  "Session memo of auth-source lookups: NAME -> secret string, or `miss'.
Misses memoize too, so an encrypted ~/.authinfo.gpg decrypts at most once
per name per session (no repeated pinentry prompts on pane repaints).")

(defun cmacs-gnuseye--keys ()
  "The `cmacs-gnuseye-keys-file' alist, loaded lazily once."
  (unless cmacs-gnuseye--keys-loaded
    (setq cmacs-gnuseye--keys-loaded t)
    (when (file-readable-p cmacs-gnuseye-keys-file)
      (ignore-errors
        (with-temp-buffer
          (insert-file-contents cmacs-gnuseye-keys-file)
          (setq cmacs-gnuseye--keys (read (current-buffer)))))))
  cmacs-gnuseye--keys)

(defun cmacs-gnuseye--auth-source-field (entry field)
  "Extract FIELD (`secret' or `user') from auth-source ENTRY plist.
auth-source may wrap the secret in a closure; unwrap it."
  (when entry
    (let ((v (plist-get entry (if (eq field 'user) :user :secret))))
      (if (functionp v) (funcall v) v))))

(defun cmacs-gnuseye--secret-auth-source (name)
  "Resolve NAME via auth-source, memoized (hits AND misses).
Tries the `cmacs-gnuseye-secret-hosts' mapping first, then a literal
\"machine NAME\" entry.  Errors (unreadable authinfo, failed decrypt)
memoize as a miss so they cannot re-prompt every lookup.  Returns the
secret string or nil."
  (let ((memo (gethash name cmacs-gnuseye--secret-memo)))
    (cond
     ((stringp memo) memo)
     ((eq memo 'miss) nil)
     (t
      (require 'auth-source)
      (let* ((spec (cdr (assoc name cmacs-gnuseye-secret-hosts)))
             (found
              (condition-case nil
                  (or (and spec
                           (cmacs-gnuseye--auth-source-field
                            (car (auth-source-search
                                  :host (plist-get spec :host) :max 1))
                            (or (plist-get spec :field) 'secret)))
                      (cmacs-gnuseye--auth-source-field
                       (car (auth-source-search
                             :host name :max 1 :require '(:secret)))
                       'secret))
                (error nil))))
        (puthash name (if (stringp found) found 'miss)
                 cmacs-gnuseye--secret-memo)
        (and (stringp found) found))))))

(defun cmacs-gnuseye-secret (name &optional default)
  "Resolve an API key NAME.
Order: environment variable, auth-source (~/.authinfo / ~/.authinfo.gpg,
see `cmacs-gnuseye-secret-hosts'), `cmacs-gnuseye-keys-file', DEFAULT.
auth-source lookups memoize for the session (`cmacs-gnuseye-secret-forget'
clears them); the first lookup against an encrypted authinfo may prompt
for the gpg passphrase."
  (or (getenv name)
      (and cmacs-gnuseye-secret-use-auth-source
           (cmacs-gnuseye--secret-auth-source name))
      (cdr (assoc name (cmacs-gnuseye--keys)))
      default))

(defun cmacs-gnuseye-secret-cached (name &optional default)
  "Like `cmacs-gnuseye-secret' but never performs auth-source I/O.
Consults the environment, already-memoized auth-source hits, and the keys
file only -- safe for passive UI repaints (cannot trigger pinentry).  A key
that lives only in an encrypted authinfo reads as absent here until the
first real `cmacs-gnuseye-secret' resolution (e.g. enabling its layer)."
  (or (getenv name)
      (let ((memo (gethash name cmacs-gnuseye--secret-memo)))
        (and (stringp memo) memo))
      (cdr (assoc name (cmacs-gnuseye--keys)))
      default))

;;;###autoload
(defun cmacs-gnuseye-secret-forget ()
  "Drop every cached API-key lookup (memo, keys file, auth-source cache).
Run after editing ~/.authinfo(.gpg), `cmacs-gnuseye-keys-file', or the
environment so the next lookup re-resolves."
  (interactive)
  (clrhash cmacs-gnuseye--secret-memo)
  (setq cmacs-gnuseye--keys nil cmacs-gnuseye--keys-loaded nil)
  (when (fboundp 'auth-source-forget-all-cached)
    (auth-source-forget-all-cached))
  (message "GNU's Eye: secret caches cleared"))

;;;; Geometry helpers: dead reckoning, rings, routes -------------------------

(defun cmacs-gnuseye-dead-reckon (lat lon speed-ms heading-deg dt)
  "Great-circle destination from LAT,LON after SPEED-MS for DT s on HEADING-DEG.
Returns (LAT2 . LON2), or nil when there is nothing to move (no speed/heading)."
  (when (and (numberp lat) (numberp lon) (numberp speed-ms) (> speed-ms 0)
             (numberp heading-deg) (>= heading-deg 0) (> dt 0))
    (let* ((r 6371000.0) (d (/ (* speed-ms dt) r)) (d2r (/ float-pi 180.0))
           (la (* lat d2r)) (lo (* lon d2r)) (th (* heading-deg d2r))
           (sla (sin la)) (cla (cos la)) (sd (sin d)) (cd (cos d))
           (la2 (asin (max -1.0 (min 1.0 (+ (* sla cd) (* cla sd (cos th)))))))
           (lo2 (+ lo (atan (* (sin th) sd cla) (- cd (* sla (sin la2)))))))
      (cons (/ la2 d2r) (/ lo2 d2r)))))

(defun cmacs-gnuseye-dead-reckon-layer (entities dt _now)
  "Generic :advance hook: dead-reckon each of ENTITIES forward DT seconds along
its :heading at its :speed (metres/second).  Fresh fetches course-correct the
extrapolated positions.  Use as a moving layer's :advance."
  (dolist (e entities)
    (let ((np (cmacs-gnuseye-dead-reckon
               (plist-get e :lat) (plist-get e :lon)
               (plist-get e :speed) (plist-get e :heading) dt)))
      (when np (plist-put e :lat (car np)) (plist-put e :lon (cdr np))))))

(defun cmacs-gnuseye-destination (lat lon brg-deg dist-m)
  "Destination DIST-M metres from (LAT LON) on initial bearing BRG-DEG.
Returns (LAT . LON), longitude normalised to [-180,180]."
  (let* ((r 6371000.0) (dr (/ dist-m r)) (d2r (/ float-pi 180.0))
         (p1 (* lat d2r)) (l1 (* lon d2r)) (b (* brg-deg d2r))
         (sp (sin p1)) (cp (cos p1)) (sd (sin dr)) (cd (cos dr))
         (p2 (asin (max -1.0 (min 1.0 (+ (* sp cd) (* cp sd (cos b)))))))
         (l2 (+ l1 (atan (* (sin b) sd cp) (- cd (* sp (sin p2)))))))
    (cons (/ p2 d2r) (- (mod (+ (/ l2 d2r) 540.0) 360.0) 180.0))))

(defun cmacs-gnuseye-circle-points (lat lon radius-m &optional n)
  "Vector of N [LAT LON] vertices forming a small circle of RADIUS-M about
\(LAT LON).  For coverage/range rings (satellite footprints, geofence circles),
usable as an entity :polygon (filled) or fed to a polyline.  N defaults to 48."
  (let ((n (or n 48)) (pts nil))
    (dotimes (i n)
      (let ((d (cmacs-gnuseye-destination
                lat lon (* 360.0 (/ (float i) n)) radius-m)))
        (push (vector (car d) (cdr d)) pts)))
    (vconcat (nreverse pts))))

;;;; Layer registry ----------------------------------------------------------

(cl-defstruct (cmacs-gnuseye-layer (:constructor cmacs-gnuseye--make-layer))
  name title group fetch interval default-on detail kind needs-key advance
  timer enabled last-fetch last-error in-flight
  ;; Bumped on every enable AND disable.  An async fetch captures the value at
  ;; dispatch; a callback whose captured value no longer matches (the layer was
  ;; toggled mid-flight) is dropped, so a late response can never re-add the
  ;; markers of a layer the user has switched off.  See `--refresh-layer'.
  (generation 0)
  ;; Non-nil to cluster this layer's markers when zoomed out (dense point
  ;; layers like aircraft/vessels): nearby markers collapse to one count badge.
  cluster
  ;; Marker/polygon alpha multiplier in [0,1] (nil = 1.0); per-layer opacity.
  opacity
  ;; Non-nil for high-churn synthetic layers (wind particles): entities are
  ;; rendered but excluded from the id-index (entity list, search, export)
  ;; and from replay/history capture -- their ids churn too fast to index.
  transient
  ;; Optional (lambda ()) run after the layer is disabled and cleared, for
  ;; state outside the entity model (overlay channels, tick hooks).
  teardown)

(defvar cmacs-gnuseye--layers (make-hash-table :test 'eq)
  "Registry of defined layers: NAME symbol -> `cmacs-gnuseye-layer'.")

(defmacro cmacs-gnuseye-define-layer (name &rest props)
  "Define (or redefine) a GNU's Eye data layer NAME.
PROPS is a plist with:
  :title      human-readable string
  :group      grouping symbol (astronomical/air/marine/weather/...)
  :kind       default marker kind symbol for this layer
  :fetch      (lambda (CALLBACK) ...) that calls (CALLBACK ENTITIES) async
  :interval   refresh seconds (nil = fetch once)
  :default-on non-nil to allow auto-enable
  :detail     (lambda (ENTITY) ...) to render a clicked entity (optional)
  :needs-key  a key name string this layer requires (optional)
  :advance    (lambda (ENTITIES DT NOW) ...) called between fetches to move
              this layer's entities smoothly (dead reckoning / re-propagation);
              mutate the entity plists in place (optional).  Generic moving
              layers can use `cmacs-gnuseye-dead-reckon-layer'.
  :cluster    non-nil to collapse dense markers into count badges when zoomed
              out (good for aircraft/vessels)
  :opacity    marker/polygon alpha multiplier in [0,1] (default 1.0)
  :transient  non-nil for high-churn synthetic layers (wind particles):
              entities render on the globe but stay out of the id-index
              (entity list, search, export) and replay/history capture
  :teardown   (lambda ()) run after the layer is disabled and cleared --
              drop overlay channels, remove tick hooks (optional)"
  (declare (indent 1))
  `(progn
     (puthash ',name
              (cmacs-gnuseye--make-layer
               :name ',name
               :title ,(plist-get props :title)
               :group ,(plist-get props :group)
               :kind ,(plist-get props :kind)
               :fetch ,(plist-get props :fetch)
               :interval ,(plist-get props :interval)
               :default-on ,(plist-get props :default-on)
               :detail ,(plist-get props :detail)
               :needs-key ,(plist-get props :needs-key)
               :advance ,(plist-get props :advance)
               :cluster ,(plist-get props :cluster)
               :opacity ,(plist-get props :opacity)
               :transient ,(plist-get props :transient)
               :teardown ,(plist-get props :teardown))
              cmacs-gnuseye--layers)
     ',name))

(defun cmacs-gnuseye--kind-visible-p (kind)
  "Non-nil if KIND passes the active-kinds filter."
  (or (null cmacs-gnuseye-active-kinds)
      (memq kind cmacs-gnuseye-active-kinds)))

(defun cmacs-gnuseye--entity-visible-p (e)
  "Non-nil if entity E passes the active-kinds filter."
  (cmacs-gnuseye--kind-visible-p (or (plist-get e :kind) 'generic)))

(defvar cmacs-gnuseye--reindex-functions nil
  "Abnormal hook run (no args) after `cmacs-gnuseye--reindex' rebuilds the index.
Features (search index, stats pane, replay capture) subscribe here so they
refresh off the single debounced reindex rather than every fetch chunk.")

(defun cmacs-gnuseye--layer-transient-p (name)
  "Non-nil when layer NAME is registered as :transient."
  (let ((layer (gethash name cmacs-gnuseye--layers)))
    (and layer (cmacs-gnuseye-layer-transient layer))))

(defun cmacs-gnuseye--reindex ()
  "Rebuild the id -> entity index from `cmacs-gnuseye--layer-entities'.
Transient layers are skipped: their entities draw on the globe but stay out
of the index and everything built on it (entity list, search, export)."
  (clrhash cmacs-gnuseye--id-index)
  (maphash
   (lambda (lname ents)
     (unless (cmacs-gnuseye--layer-transient-p lname)
       (dolist (e ents)
         (let ((id (format "%s" (or (plist-get e :id) ""))))
           (unless (string-empty-p id)
             (puthash id (append (list :layer lname) e)
                      cmacs-gnuseye--id-index))))))
   cmacs-gnuseye--layer-entities)
  (run-hook-with-args 'cmacs-gnuseye--reindex-functions))

(defcustom cmacs-gnuseye-render-max 700
  "Maximum markers rendered per layer on the globe.
The full set stays in the entity index (so it is all searchable in the
list); only the markers nearest the view are drawn, to keep the globe
fast.  nil renders everything (heavy with worldwide aircraft)."
  :type '(choice (const :tag "Render all" nil) integer)
  :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--rendered-ids (make-hash-table :test 'eq)
  "Layer name -> hash of entity ids currently drawn on the globe.
Used for a STICKY render set: an entity that is already drawn stays drawn
while it remains in view, so incremental data chunks and the smooth-motion
tick do not re-pick a different subset each time (which flickered).")

(defun cmacs-gnuseye--record-rendered (lname ents)
  "Record ENTS as LNAME's currently-drawn set."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (e ents) (puthash (format "%s" (plist-get e :id)) t h))
    (puthash lname h cmacs-gnuseye--rendered-ids)))

(defun cmacs-gnuseye--viewport-predicate (buf)
  "Return a predicate (ENTITY) -> non-nil if within BUF's on-screen radius.
The radius is the camera's true horizon angle acos(R/d) (the geometry of how
much of the sphere a camera at distance D can see), plus a small margin --
so zoomed out the whole visible hemisphere qualifies, and zoomed in only the
local region does."
  (let ((vc (ignore-errors (cmacs-gnuseye-view-center buf))))
    (if (not (and (consp vc) (numberp (nth 0 vc))))
        (lambda (_e) t)
      (let* ((d2r (/ float-pi 180.0))
             (clat (* d2r (nth 0 vc))) (clon (* d2r (nth 1 vc)))
             (dist (max 6.372 (or (nth 2 vc) 12.0)))
             (vrad (max 0.12 (* 1.06 (acos (min 1.0 (/ 6.371 dist))))))
             (cosr (cos (min float-pi vrad)))
             (scl (sin clat)) (ccl (cos clat)))
        (lambda (e)
          (let ((la (* d2r (or (plist-get e :lat) 0)))
                (lo (* d2r (or (plist-get e :lon) 0))))
            (>= (+ (* scl (sin la)) (* ccl (cos la) (cos (- lo clon)))) cosr)))))))

(defun cmacs-gnuseye--select-render (all lname buf cap)
  "Choose up to CAP of ALL to draw for LNAME, stickily.
Keep entities already drawn that are still in view, fill remaining slots
with new in-view entities, and drop those that have left the view -- so the
drawn set stays stable between updates instead of flickering."
  (if (or (null cap) (<= (length all) cap))
      (progn (cmacs-gnuseye--record-rendered lname all) all)
    (let* ((vp (cmacs-gnuseye--viewport-predicate buf))
           (prev (gethash lname cmacs-gnuseye--rendered-ids))
           (kept nil) (fresh nil) (keptn 0))
      (dolist (e all)
        (when (funcall vp e)
          (if (and prev (gethash (format "%s" (plist-get e :id)) prev))
              (progn (push e kept) (setq keptn (1+ keptn)))
            (push e fresh))))
      (let ((out kept) (slots (- cap keptn)))
        (while (and fresh (> slots 0))
          (push (pop fresh) out)
          (setq slots (1- slots)))
        ;; Always include the selected entity, even off-view.
        (when cmacs-gnuseye--selected-id
          (unless (seq-find (lambda (e) (equal (format "%s" (plist-get e :id))
                                               cmacs-gnuseye--selected-id))
                            out)
            (let ((sel (seq-find
                        (lambda (e) (equal (format "%s" (plist-get e :id))
                                           cmacs-gnuseye--selected-id))
                        all)))
              (when sel (push sel out)))))
        (cmacs-gnuseye--record-rendered lname out)
        out))))

(defun cmacs-gnuseye--zoom-scale-for (buf)
  "Zoom-dependent marker scale for BUF (constant on-screen size)."
  (let ((vc (ignore-errors (cmacs-gnuseye-view-center buf))))
    (if (and (consp vc) (numberp (nth 2 vc)))
        (max 0.25 (min 3.0 (/ (- (nth 2 vc) 6.371) 3.0)))
      1.0)))

;;;; Low-zoom clustering ------------------------------------------------------

(defcustom cmacs-gnuseye-cluster t
  "Collapse dense point markers into count badges when zoomed out.
Only applies to layers declared with :cluster (aircraft, vessels).  Zooming
in dissolves the clusters back into individual markers."
  :type 'boolean :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-cluster-min 8
  "Do not cluster a layer with fewer than this many in-view markers."
  :type 'integer :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--cluster-cell-deg (buf)
  "Grid cell size in degrees for clustering at BUF's zoom, or nil when zoomed
in close enough to show individual markers."
  (let ((vc (ignore-errors (cmacs-gnuseye-view-center buf))))
    (when (and (consp vc) (numberp (nth 2 vc)) (> (nth 2 vc) 8.5))
      (max 2.0 (min 24.0 (* (- (nth 2 vc) 6.371) 1.2))))))

(defun cmacs-gnuseye--cluster (entities cell layer)
  "Bucket ENTITIES into a CELL-degree grid; collapse multi-member cells to one
synthetic cluster marker (count badge), passing single-member cells through.
Cluster ids are stable per cell so the sticky render set does not flicker."
  (let ((buckets (make-hash-table :test 'equal)) (out nil)
        (kind (or (cmacs-gnuseye-layer-kind layer) 'generic))
        (lname (cmacs-gnuseye-layer-name layer)))
    (dolist (e entities)
      (let* ((lat (or (plist-get e :lat) 0.0)) (lon (or (plist-get e :lon) 0.0))
             (key (cons (floor (/ lat cell)) (floor (/ lon cell)))))
        (push e (gethash key buckets))))
    (maphash
     (lambda (key members)
       (if (= (length members) 1)
           (push (car members) out)
         (let ((slat 0.0) (slon 0.0) (n 0)
               ;; A badge is a small count bubble (sphere) tinted with the
               ;; layer kind's colour -- NOT the layer's icon: a plane/ship
               ;; mesh at badge scale (worse, zoom-multiplied for aircraft)
               ;; reads as a giant rogue marker when zoomed out.
               (color (or (plist-get (alist-get kind cmacs-gnuseye-kind-styles)
                                     :color)
                          "#9ab8d8")))
           (dolist (m members)
             (setq slat (+ slat (or (plist-get m :lat) 0.0))
                   slon (+ slon (or (plist-get m :lon) 0.0)) n (1+ n)))
           (push (list :id (format "cluster:%s:%s:%s" lname (car key) (cdr key))
                       :kind 'cluster :lat (/ slat n) :lon (/ slon n)
                       :color color
                       :label (number-to-string n)
                       :scale (min 1.6 (+ 0.5 (* 0.04 n)))
                       :label-mode 3
                       :data `((:cluster . t) (:count . ,n) (:layer . ,lname)))
                 out))))
     buckets)
    out))

(defun cmacs-gnuseye--render-layer (buf lname)
  "Push LNAME's kind-filtered entities from the index to BUF's globe.
All entities stay in the index; only up to `cmacs-gnuseye-render-max'
nearest the view are drawn.  Layers declared :cluster collapse to count
badges when zoomed out (`cmacs-gnuseye-cluster')."
  (setq cmacs-gnuseye--zoom-scale (cmacs-gnuseye--zoom-scale-for buf))
  (when (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf))
    (let* ((layer (gethash lname cmacs-gnuseye--layers))
           (cmacs-gnuseye--render-opacity
            (or (and layer (cmacs-gnuseye-layer-opacity layer)) 1.0))
           (all (seq-filter #'cmacs-gnuseye--entity-visible-p
                            (gethash lname cmacs-gnuseye--layer-entities)))
           (cell (and cmacs-gnuseye-cluster layer
                      (cmacs-gnuseye-layer-cluster layer)
                      (>= (length all) cmacs-gnuseye-cluster-min)
                      (cmacs-gnuseye--cluster-cell-deg buf)))
           (all (if cell (cmacs-gnuseye--cluster all cell layer) all))
           (ents (cmacs-gnuseye--select-render
                  all lname buf cmacs-gnuseye-render-max)))
      (cmacs-gnuseye-set-entities
       buf lname (cmacs-gnuseye--entities->vector ents)))))

(defun cmacs-gnuseye--render-all (&optional buf)
  "Re-render every layer's markers (e.g. after a filter change)."
  (let ((buf (or buf cmacs-gnuseye-buffer)))
    (when (and buf (buffer-live-p buf))
      (maphash (lambda (lname _) (cmacs-gnuseye--render-layer buf lname))
               cmacs-gnuseye--layer-entities))))

;;;; Smooth motion: move markers between fetches -----------------------------

;; Any layer with an :advance function is advanced on a fast timer and
;; re-rendered, so its markers glide between the (slower) data fetches; the
;; next fetch corrects the extrapolated positions.  Aircraft dead-reckon
;; along their heading; satellites re-propagate their orbit with SGP4.

(defcustom cmacs-gnuseye-smooth t
  "Smoothly move markers between data fetches.
Each layer with an :advance function (aircraft, satellites) is advanced
every `cmacs-gnuseye-smooth-interval' seconds and re-rendered."
  :type 'boolean :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-smooth-interval 0.4
  "Seconds between smooth-motion updates (lower = smoother, heavier)."
  :type 'number :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--smooth-timer nil)
(defvar cmacs-gnuseye--smooth-last nil)

(defvar cmacs-gnuseye--tick-functions nil
  "Abnormal hook run as (BUF NOW DT) at the end of each smooth-motion tick.
Lets features (geofence evaluation, follow-camera) hang cheap periodic work
off the single shared timer.  Subscribers MUST stay cheap and throttle their
own heavier work; the tick fires every `cmacs-gnuseye-smooth-interval'.")

(defun cmacs-gnuseye--smooth-tick ()
  "Advance every enabled layer that has an :advance fn, then re-render it."
  (let ((buf cmacs-gnuseye-buffer))
    (cond
     ((not (and buf (buffer-live-p buf)))
      (when cmacs-gnuseye--smooth-timer
        (cancel-timer cmacs-gnuseye--smooth-timer)
        (setq cmacs-gnuseye--smooth-timer nil)))
     ((cmacs-gnuseye-attached-p buf)
      (let* ((now (float-time))
             (dt (if cmacs-gnuseye--smooth-last
                     (- now cmacs-gnuseye--smooth-last) 0.0)))
        (setq cmacs-gnuseye--smooth-last now)
        (when (and cmacs-gnuseye-smooth (> dt 0.0) (< dt 5.0))
          (maphash
           (lambda (name layer)
             (let ((adv (cmacs-gnuseye-layer-advance layer)))
               (when (and adv (cmacs-gnuseye-layer-enabled layer))
                 (let ((ents (gethash name cmacs-gnuseye--layer-entities)))
                   (when ents
                     (ignore-errors (funcall adv ents dt now))
                     (cmacs-gnuseye--render-layer buf name))))))
           cmacs-gnuseye--layers))
        ;; Feature hooks (geofence, follow-camera) run every tick regardless of
        ;; the smooth setting, but should throttle their own heavier work.
        (when (and (> dt 0.0) (< dt 5.0))
          (run-hook-with-args 'cmacs-gnuseye--tick-functions buf now dt)))))))

(defun cmacs-gnuseye--smooth-start ()
  "Start the shared smooth-motion tick if not already running."
  (unless cmacs-gnuseye--smooth-timer
    (setq cmacs-gnuseye--smooth-last nil
          cmacs-gnuseye--smooth-timer
          (run-with-timer cmacs-gnuseye-smooth-interval
                          (max 0.1 cmacs-gnuseye-smooth-interval)
                          #'cmacs-gnuseye--smooth-tick))))

;;;; Day/night terminator -----------------------------------------------------

(defcustom cmacs-gnuseye-day-night t
  "Light the globe's day side for the real time of day.
The globe shader already shades a soft terminator; when non-nil the sun
direction tracks the actual subsolar point and is refreshed periodically."
  :type 'boolean :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-sun-interval 60
  "Seconds between day/night terminator updates."
  :type 'number :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--sun-timer nil)

(defun cmacs-gnuseye--sun-update ()
  "Point the globe's sun at the current subsolar point."
  (let ((buf cmacs-gnuseye-buffer))
    (if (not (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf)))
        (when cmacs-gnuseye--sun-timer
          (cancel-timer cmacs-gnuseye--sun-timer)
          (setq cmacs-gnuseye--sun-timer nil))
      (when cmacs-gnuseye-day-night
        (ignore-errors (cmacs-gnuseye-set-sun-time buf nil))))))

(defun cmacs-gnuseye--sun-start ()
  "Apply the terminator now and arm the periodic sun update."
  (when (and cmacs-gnuseye-day-night (not cmacs-gnuseye--sun-timer))
    (cmacs-gnuseye--sun-update)
    (setq cmacs-gnuseye--sun-timer
          (run-with-timer cmacs-gnuseye-sun-interval
                          cmacs-gnuseye-sun-interval
                          #'cmacs-gnuseye--sun-update))))

(defun cmacs-gnuseye--refresh-layer (layer)
  "Run LAYER's fetch, store its entities in the index, and render them.
The fetch callback is guarded by the layer's generation token: if the layer
is disabled (or toggled) while the fetch is in flight, the late response is
dropped silently, so a disabled layer can never be re-drawn by a stale async
reply."
  (let ((buf cmacs-gnuseye-buffer)
        (gen (cmacs-gnuseye-layer-generation layer)))
    (when (and buf (buffer-live-p buf)
               (cmacs-gnuseye-attached-p buf)
               (cmacs-gnuseye-layer-enabled layer)
               (not (cmacs-gnuseye-layer-in-flight layer)))
      (setf (cmacs-gnuseye-layer-in-flight layer) t)
      (condition-case err
          (funcall
           (cmacs-gnuseye-layer-fetch layer)
           (lambda (entities)
             ;; Drop the response if the layer was toggled since dispatch.
             (when (and (cmacs-gnuseye-layer-enabled layer)
                        (= gen (cmacs-gnuseye-layer-generation layer)))
               (setf (cmacs-gnuseye-layer-in-flight layer) nil
                     (cmacs-gnuseye-layer-last-fetch layer) (float-time)
                     (cmacs-gnuseye-layer-last-error layer) nil)
               (condition-case e2
                   (let ((buf cmacs-gnuseye-buffer))
                     (puthash (cmacs-gnuseye-layer-name layer) (or entities nil)
                              cmacs-gnuseye--layer-entities)
                     ;; Markers now (render-layer reads layer-entities, not the
                     ;; id-index) for fast first paint; the costly reindex +
                     ;; list repaint are debounced so a burst of incremental
                     ;; chunks collapses to one.
                     (when (and buf (buffer-live-p buf))
                       (cmacs-gnuseye--render-layer
                        buf (cmacs-gnuseye-layer-name layer)))
                     (cmacs-gnuseye--schedule-index-refresh))
                 (error
                  (setf (cmacs-gnuseye-layer-last-error layer)
                        (error-message-string e2)))))))
        (error
         (setf (cmacs-gnuseye-layer-in-flight layer) nil
               (cmacs-gnuseye-layer-last-error layer)
               (error-message-string err)))))))

(defun cmacs-gnuseye--enable-layer (layer)
  "Enable LAYER: fetch now and (re)arm its refresh timer."
  (cmacs-gnuseye--disable-layer layer)
  ;; Bump generation so any fetch dispatched under the previous enable/disable
  ;; cannot land as ours (and our own fetches capture this fresh value).
  (cl-incf (cmacs-gnuseye-layer-generation layer))
  (setf (cmacs-gnuseye-layer-enabled layer) t)
  (cmacs-gnuseye--refresh-layer layer)
  (let ((iv (cmacs-gnuseye-layer-interval layer)))
    (when (and iv (> iv 0))
      (setf (cmacs-gnuseye-layer-timer layer)
            (run-with-timer (+ iv (random 3)) iv
                            #'cmacs-gnuseye--refresh-layer layer)))))

(defun cmacs-gnuseye--disable-layer (layer)
  "Disable LAYER atomically: cancel its timer, invalidate any in-flight fetch,
and clear every trace of it from the index and the globe.
Bumping the generation makes a late async fetch callback a no-op, so nothing
the layer had in flight can re-draw it after it is switched off."
  (when (timerp (cmacs-gnuseye-layer-timer layer))
    (cancel-timer (cmacs-gnuseye-layer-timer layer)))
  (cl-incf (cmacs-gnuseye-layer-generation layer))   ; invalidate in-flight
  (setf (cmacs-gnuseye-layer-timer layer) nil
        (cmacs-gnuseye-layer-enabled layer) nil
        (cmacs-gnuseye-layer-in-flight layer) nil)
  (remhash (cmacs-gnuseye-layer-name layer) cmacs-gnuseye--layer-entities)
  (cmacs-gnuseye--reindex)
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
             (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer))
    (ignore-errors
      (cmacs-gnuseye-clear-layer cmacs-gnuseye-buffer
                                 (cmacs-gnuseye-layer-name layer)))
    ;; Textured celestial spheres persist across marker rebuilds, so the
    ;; marker clear leaves them behind: drop them all; any still-enabled
    ;; celestial layer re-adds its own on the next tick.
    (when (and (eq (cmacs-gnuseye-layer-group layer) 'celestial)
               (fboundp 'cmacs-gnuseye-clear-bodies))
      (ignore-errors (cmacs-gnuseye-clear-bodies cmacs-gnuseye-buffer))))
  ;; State outside the entity model (overlay channels, tick hooks) is the
  ;; layer's own to drop.
  (let ((td (cmacs-gnuseye-layer-teardown layer)))
    (when (functionp td) (ignore-errors (funcall td))))
  (cmacs-gnuseye--list-refresh-soon))

(defun cmacs-gnuseye--load-layers ()
  "Load the built-in layer feature files."
  (dolist (f cmacs-gnuseye-layer-files)
    (require f nil t)))

;;;; Selection + inspector pane ----------------------------------------------

(defconst cmacs-gnuseye--inspector-name "*GNU's Eye Inspector*")
(defconst cmacs-gnuseye--list-name "*GNU's Eye Entities*")

(defun cmacs-gnuseye--select-entity (id &optional no-fly)
  "Select entity ID: show it in the inspector, highlight it on the globe,
and (unless NO-FLY) recentre the camera on it."
  (setq cmacs-gnuseye--selected-id (and id (format "%s" id)))
  (let ((e (and cmacs-gnuseye--selected-id
                (gethash cmacs-gnuseye--selected-id cmacs-gnuseye--id-index))))
    (when e
      (unless no-fly
        (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
                   (plist-get e :lat))
          ;; Celestial bodies sit far off the surface: ORBIT THE BODY --
          ;; the camera target moves onto it (drag revolves around it, zoom
          ;; approaches *it* asymptotically), standing back ~6 radii with
          ;; Earth behind.  Any fly-to / home / deselect restores the Earth
          ;; orbit.  Surface entities keep the normal fly-to.
          (let* ((alt (or (plist-get e :alt) 0.0))
                 (shell-r (* 6.371 (+ 1.0 (/ (float alt) 6371000.0))))
                 (body-r (* 0.099 (float (or (plist-get e :scale) 1.0)))))
            (if (and (> shell-r 9.0) (fboundp 'cmacs-gnuseye-orbit-point))
                (ignore-errors
                  (cmacs-gnuseye-orbit-point cmacs-gnuseye-buffer
                                             (float (plist-get e :lat))
                                             (float (plist-get e :lon))
                                             (float alt) body-r t))
              (ignore-errors
                (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer
                                      (float (plist-get e :lat))
                                      (float (plist-get e :lon))
                                      cmacs-gnuseye-focus-range t))))
          ;; After the fly-to tween settles, re-pick nearest so the
          ;; destination region's other markers fill in around it.
          (run-with-timer 1.5 nil #'cmacs-gnuseye-refresh-view-layers)))
      (cmacs-gnuseye--show-inspector e)
      ;; Re-render so the selected marker is enlarged/brightened/labelled.
      (cmacs-gnuseye--render-all))
    e))

;;;###autoload
(defun cmacs-gnuseye-deselect ()
  "Deselect the current entity and recentre the orbit on Earth's centre.
Clicking a marker focuses the camera's orbit onto that object (so dragging
rotates around it); this clears the selection and flies to the current
sub-camera point with the target back at the globe centre, keeping your
heading and zoom, so dragging orbits Earth again.  Clicking empty space on
the globe does the same."
  (interactive)
  (setq cmacs-gnuseye--selected-id nil)
  (let ((buf cmacs-gnuseye-buffer))
    (when (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf))
      (let ((vc (ignore-errors (cmacs-gnuseye-view-center buf))))
        (when (and (consp vc) (numberp (nth 2 vc)))
          (ignore-errors
            (cmacs-gnuseye-fly-to buf (nth 0 vc) (nth 1 vc)
                                  (max 0.5 (- (nth 2 vc) 6.371)) nil))))
      (cmacs-gnuseye--render-all buf)
      (ignore-errors (cmacs-gnuseye-redraw buf))
      (cmacs-gnuseye--show-inspector nil))))

(defun cmacs-gnuseye-escape ()
  "Two-stage <escape> for the GNU's Eye globe.
With an entity selected, deselect it and re-orbit Earth (the original
behaviour).  With nothing selected, drop the globe buffer from Evil emacs
state -- which it uses so single keys drive the camera -- into normal state,
as an Evil user expects (re-enter with \\[evil-emacs-state], C-z).  Without
Evil, or with a selection, it just deselects."
  (interactive)
  (if cmacs-gnuseye--selected-id
      (cmacs-gnuseye-deselect)
    (if (fboundp 'evil-normal-state)
        (evil-normal-state)
      (cmacs-gnuseye-deselect))))

;;;###autoload
(defun cmacs-gnuseye-home ()
  "Go back to Earth: clear the selection and reset to the default Earth view.
After flying out to the Moon, a planet, or a probe on the celestial shells,
this recentres the orbit on Earth's centre at the standard distance."
  (interactive)
  (setq cmacs-gnuseye--selected-id nil)
  (let ((buf cmacs-gnuseye-buffer))
    (when (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf))
      (let* ((vc (ignore-errors (cmacs-gnuseye-view-center buf)))
             (lat (if (consp vc) (nth 0 vc) 20.0))
             (lon (if (consp vc) (nth 1 vc) -30.0)))
        (ignore-errors (cmacs-gnuseye-fly-to buf lat lon 6.6 t)))
      (cmacs-gnuseye--render-all buf)
      (ignore-errors (cmacs-gnuseye-redraw buf))
      (cmacs-gnuseye--show-inspector nil)
      (message "GNU's Eye: back to Earth"))))

(defvar cmacs-gnuseye--click-functions nil
  "Abnormal hook run as (BUFFER NODE-ID VX VY) on each globe click before the
default select.  VX/VY are the view-local click pixel (map to a lat/lon with
`cmacs-gnuseye-screen-to-globe').  A function returning non-nil CONSUMES the
click (default select/cluster handling is skipped) — used by the measurement
tool.")

(defvar cmacs-gnuseye--last-click nil
  "Last globe click as (VX . VY) view-local pixel.")

(defun cmacs-gnuseye--on-pick (buffer node-id &optional vx vy path)
  "Handle a globe click: select the entity (inspector + highlight + list),
or, for a cluster badge, zoom toward it so it dissolves into individuals.
NODE-ID is -1 for an empty-globe click; VX/VY are the click pixel; PATH is
the picked marker's entity-id string (stable across marker rebuilds, unlike
NODE-ID).  Features on `cmacs-gnuseye--click-functions' may intercept first
\(measurement, country details).  Called from
`cmacs-libregnum--node-clicked' on the cmacs context."
  (when (and (numberp vx) (numberp vy))
    (setq cmacs-gnuseye--last-click (cons vx vy)))
  (unless (run-hook-with-args-until-success
           'cmacs-gnuseye--click-functions buffer node-id vx vy)
    (if (and (integerp node-id) (>= node-id 0))
        (cmacs-gnuseye--on-pick-1 buffer node-id path)
      ;; Empty-globe click: deselect + recentre the orbit on Earth.
      (cmacs-gnuseye-deselect))))

(defun cmacs-gnuseye--resolve-pick (buffer node-id path)
  "Resolve a click to its entity, surviving marker-rebuild id churn.
The smooth tick rebuilds markers every ~0.4 s, renumbering node ids; the
payload looked up by NODE-ID can therefore be stale by dispatch time.  PATH
\(the entity id captured at pick time) is authoritative: when the payload's
id disagrees with PATH, or the payload is gone, fall back to the id index."
  (let ((e (and (integerp node-id) (>= node-id 0)
                (ignore-errors (cmacs-gnuseye-entity-at buffer node-id)))))
    (cond
     ;; Payload agrees with the picked path (or no path): trust it.
     ((and e (or (null path)
                 (equal (format "%s" (plist-get e :id)) path)))
      e)
     ;; Cluster badges are synthetic (not in the index): only a matching
     ;; payload is usable; a stale one is dropped.
     ((and path (string-prefix-p "cluster:" path))
      (and e (string-prefix-p "cluster:"
                              (format "%s" (plist-get e :id)))
           e))
     ;; Stale or missing payload: the id index has the real entity.
     (path (gethash path cmacs-gnuseye--id-index))
     (t e))))

(defun cmacs-gnuseye--on-pick-1 (buffer node-id &optional path)
  "Default click handling: select/zoom the picked NODE-ID (PATH = entity id).
Always reports the outcome in the echo area, so a click that fails to
resolve says so (and why) instead of failing silently."
  (when (or (and (integerp node-id) (>= node-id 0)) path)
    (let ((e (cmacs-gnuseye--resolve-pick buffer node-id path)))
      (if (null e)
          (message "GNU's Eye: click did not resolve (node %s, id %s)"
                   node-id (or path "?"))
        (let ((data (plist-get e :data)))
          (if (and (listp data) (assq :cluster data))
              ;; Cluster: fly in closer; the next render shows individuals.
              (let* ((vc (ignore-errors (cmacs-gnuseye-view-center buffer)))
                     (dist (if (and (consp vc) (numberp (nth 2 vc)))
                               (nth 2 vc) 12.0)))
                (message "GNU's Eye: cluster of %s — zooming in"
                         (or (cdr (assq :count data)) "?"))
                (ignore-errors
                  (cmacs-gnuseye-fly-to buffer (float (plist-get e :lat))
                                        (float (plist-get e :lon))
                                        (max 7.4 (* 0.55 dist)) t)))
            (unless (cmacs-gnuseye--select-entity (plist-get e :id))
              ;; Index miss (mid-rebuild debounce): still show what was
              ;; clicked -- the resolved entity is fully displayable.
              (setq cmacs-gnuseye--selected-id
                    (format "%s" (plist-get e :id)))
              (cmacs-gnuseye--show-inspector e)
              (cmacs-gnuseye--render-all))
            (message "GNU's Eye: selected %s"
                     (or (plist-get e :label) (plist-get e :id)))
            (ignore-errors (cmacs-gnuseye--list-goto (plist-get e :id)))))))))

;;;; Right-click context menu --------------------------------------------------

(defun cmacs-gnuseye--context-menu-items (e)
  "Menu item list ((LABEL . FN) or nil separator) for entity E (or nil).
With E: select/fly plus every registered inspector action whose predicate
passes.  Without E (empty-space right-click): view-level actions."
  (if e
      (append
       (list (cons (format "Fly to %s"
                           (or (plist-get e :label) (plist-get e :id)))
                   (lambda ()
                     (cmacs-gnuseye--select-entity (plist-get e :id))))
             (cons "Inspect (no fly)"
                   (lambda ()
                     (or (cmacs-gnuseye--select-entity (plist-get e :id) t)
                         (progn (setq cmacs-gnuseye--selected-id
                                      (format "%s" (plist-get e :id)))
                                (cmacs-gnuseye--show-inspector e)))))
             nil)
       ;; Registered inspector actions (ask AI, compose, track, watch, ...)
       ;; operate on the inspected entity: show E first, then run.
       (delq nil
             (mapcar
              (lambda (a)
                (pcase-let ((`(,_key ,label ,fn ,pred) a))
                  (when (or (null pred) (ignore-errors (funcall pred e)))
                    (cons (concat (upcase (substring label 0 1))
                                  (substring label 1))
                          (lambda ()
                            (setq cmacs-gnuseye--selected-id
                                  (format "%s" (plist-get e :id)))
                            (cmacs-gnuseye--show-inspector e)
                            (call-interactively fn))))))
              (reverse cmacs-gnuseye-inspector-actions)))
       (list nil
             (cons "Copy coordinates"
                   (lambda ()
                     (let ((s (format "%.5f, %.5f"
                                      (or (plist-get e :lat) 0)
                                      (or (plist-get e :lon) 0))))
                       (kill-new s)
                       (message "GNU's Eye: copied %s" s))))))
    (list (cons "Deselect / re-orbit Earth" #'cmacs-gnuseye-deselect)
          (cons "Back to Earth (home)" #'cmacs-gnuseye-home)
          nil
          (cons "Measure from here" (lambda ()
                                      (when (fboundp 'cmacs-gnuseye-measure)
                                        (call-interactively
                                         #'cmacs-gnuseye-measure)))))))

(defun cmacs-gnuseye--context-menu (buffer node-id path _vx _vy)
  "Pop a context menu for the right-clicked entity (or empty space).
Called from `cmacs-libregnum--node-context-menu' on the cmacs GMainContext;
the actual popup is re-scheduled onto the command loop (a nested GTK menu
loop inside the GLib dispatch would re-enter the event machinery)."
  (let* ((e (cmacs-gnuseye--resolve-pick buffer node-id path))
         (items (cmacs-gnuseye--context-menu-items e))
         (title (if e (format "%s" (or (plist-get e :label) (plist-get e :id)))
                  "GNU's Eye")))
    (run-with-timer
     0 nil
     (lambda ()
       (let ((choice (cmacs-libregnum-popup-menu
                      t (list title
                              (cons "" (mapcar (lambda (it)
                                                 (if it (cons (car it) (cdr it))
                                                   '("--")))
                                               items))))))
         (when (functionp choice) (funcall choice)))))))

(defvar cmacs-gnuseye-inspector-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "f") #'cmacs-gnuseye-inspector-fly)
    (define-key map (kbd "RET") #'cmacs-gnuseye-inspector-fly)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-gnuseye-inspector-mode'.")

(define-derived-mode cmacs-gnuseye-inspector-mode special-mode "GnuseyeInspect"
  "GNU's Eye entity inspector pane.")

(defvar cmacs-gnuseye-inspector-actions nil
  "Alist of extra inspector actions: (KEY LABEL FN PRED).
KEY is a key-description string, LABEL a footer hint, FN a command (called
with no args; it reads `cmacs-gnuseye--selected-id'), PRED an optional
predicate of the selected entity gating whether the action is offered.
Feature files add to this via `cmacs-gnuseye-register-inspector-action' so
they can extend the inspector (ask-AI, track, open stream/news) without
editing the renderer.")

(defun cmacs-gnuseye-register-inspector-action (key label fn &optional pred)
  "Register an inspector action: press KEY to run FN, shown in the footer as
LABEL.  PRED, if non-nil, is called with the selected entity and must return
non-nil for the action to be offered.  Binds KEY in the inspector keymap --
and in Evil normal/motion state too, where the major-mode map is shadowed
\(otherwise `a' is evil-append and the action never fires under Doom)."
  (setq cmacs-gnuseye-inspector-actions
        (cons (list key label fn pred)
              (assoc-delete-all key cmacs-gnuseye-inspector-actions)))
  (define-key cmacs-gnuseye-inspector-mode-map (kbd key) fn)
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) cmacs-gnuseye-inspector-mode-map
      (kbd key) fn)))

(defun cmacs-gnuseye-inspector-fly ()
  "Recentre the globe on the inspected entity."
  (interactive)
  (when cmacs-gnuseye--selected-id
    (cmacs-gnuseye--select-entity cmacs-gnuseye--selected-id)))

(defun cmacs-gnuseye--insp-row (k v)
  (when (and v (not (and (stringp v) (string-empty-p v))))
    (insert (format "  %-10s %s\n" k v))))

(defun cmacs-gnuseye--inspector-render (e)
  "Render entity E (a rich layer plist) into the current inspector buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (if (null e)
        (insert "No entity selected.\n\n"
                "Click a marker on the globe, or select a row\n"
                "in the entity list with RET.\n")
      (let ((label (or (plist-get e :label)
                       (format "%s" (or (plist-get e :id) "entity")))))
        (insert (propertize (format "%s\n" label) 'face '(bold)))
        (insert (make-string (max 10 (string-width label)) ?─) "\n\n")
        (cmacs-gnuseye--insp-row "kind" (plist-get e :kind))
        (cmacs-gnuseye--insp-row "layer" (plist-get e :layer))
        (cmacs-gnuseye--insp-row "id" (plist-get e :id))
        (when (plist-get e :lat)
          (cmacs-gnuseye--insp-row "lat" (format "%.4f" (plist-get e :lat))))
        (when (plist-get e :lon)
          (cmacs-gnuseye--insp-row "lon" (format "%.4f" (plist-get e :lon))))
        (let ((a (plist-get e :alt)))
          (when (and (numberp a) (> a 0))
            (cmacs-gnuseye--insp-row "altitude" (format "%.1f km" (/ a 1000.0)))))
        (when (plist-get e :speed)
          (cmacs-gnuseye--insp-row "speed" (plist-get e :speed)))
        (when (and (numberp (plist-get e :heading))
                   (>= (plist-get e :heading) 0))
          (cmacs-gnuseye--insp-row "heading"
                                   (format "%s°" (plist-get e :heading))))
        (let ((data (plist-get e :data)))
          (when data
            (insert "\n" (propertize "data\n" 'face '(bold)))
            (cond
             ((and (consp data) (consp (car data)))
              (dolist (kv data)
                (cmacs-gnuseye--insp-row (format "%s" (car kv)) (cdr kv))))
             (t (insert (format "  %S\n" data))))))
        (insert "\n")
        ;; Feature-registered actions (ask-AI, track, open stream/news…),
        ;; offered only when their predicate matches this entity.
        (dolist (a (reverse cmacs-gnuseye-inspector-actions))
          (let ((pred (nth 3 a)))
            (when (or (null pred) (ignore-errors (funcall pred e)))
              (insert (format "[%s] %s   " (nth 0 a) (nth 1 a))))))
        (insert "[f] fly-to   [q] close\n")))
    (goto-char (point-min))))

(defvar cmacs-gnuseye--inspector-entity nil
  "The entity plist currently displayed in the inspector pane.
This is what inspector actions operate on -- NOT the marker selection:
pseudo-entities (countries, index-miss fallbacks) are displayed without a
marker selection, so resolving actions through `cmacs-gnuseye--selected-id'
alone wrongly reported \"No entity selected\" for them.")

(defun cmacs-gnuseye-inspector-entity ()
  "Return the entity the inspector is showing (or the marker selection)."
  (or cmacs-gnuseye--inspector-entity
      (and cmacs-gnuseye--selected-id
           (gethash cmacs-gnuseye--selected-id cmacs-gnuseye--id-index))))

(defun cmacs-gnuseye-entity-context-string (e)
  "Readable one-entity context block for AI prompts (chat / ask)."
  (when e
    (concat
     (format "Entity: %s\n" (or (plist-get e :label) (plist-get e :id)))
     (format "Kind: %s\n" (or (plist-get e :kind) 'generic))
     (let ((layer (plist-get e :layer)))
       (if layer (format "Layer: %s\n" layer) ""))
     (if (numberp (plist-get e :lat))
         (format "Position: %.4f, %.4f\n"
                 (plist-get e :lat) (plist-get e :lon))
       "")
     (let ((data (plist-get e :data)))
       (if (consp data)
           (mapconcat (lambda (kv)
                        (format "%s: %s" (car kv) (cdr kv)))
                      (seq-filter (lambda (kv) (and (consp kv) (cdr kv)))
                                  data)
                      "\n")
         "")))))

(defun cmacs-gnuseye--show-inspector (&optional e)
  "Show the inspector pane for entity E (or the current selection)."
  (let ((b (get-buffer-create cmacs-gnuseye--inspector-name))
        (shown (or e (and cmacs-gnuseye--selected-id
                          (gethash cmacs-gnuseye--selected-id
                                   cmacs-gnuseye--id-index)))))
    (setq cmacs-gnuseye--inspector-entity shown)
    (with-current-buffer b
      (unless (derived-mode-p 'cmacs-gnuseye-inspector-mode)
        (cmacs-gnuseye-inspector-mode))
      (cmacs-gnuseye--inspector-render shown))
    (display-buffer-in-side-window
     b '((side . right) (slot . 0) (window-width . 0.26)))
    b))

;;;; Entity list pane (search + filter) --------------------------------------

(defun cmacs-gnuseye--data-haystack (e)
  "Lowercased text of E's :data alist values (callsign, MMSI, country, …)."
  (let ((d (plist-get e :data)) (acc ""))
    (when (and (consp d) (consp (car d)))
      (dolist (kv d)
        (setq acc (concat acc " " (format "%s" (cdr-safe kv))))))
    (downcase acc)))

(defun cmacs-gnuseye--search-match-p (e)
  "Non-nil if entity E matches the current list search across all its fields
\(label, id, kind, and every :data value — so a callsign / MMSI / NORAD id /
country matches too)."
  (or (string-empty-p cmacs-gnuseye--search)
      (let ((q (downcase cmacs-gnuseye--search)))
        (or (string-search q (downcase (or (plist-get e :label) "")))
            (string-search q (downcase (format "%s" (or (plist-get e :id) ""))))
            (string-search q (symbol-name (or (plist-get e :kind) 'generic)))
            (string-search q (cmacs-gnuseye--data-haystack e))))))

(defcustom cmacs-gnuseye-list-max 500
  "Maximum rows shown in the entity list at once.
Search/filter still scan the full index; this only bounds how many rows
are painted, because a tabulated-list of thousands of rows is very slow to
build.  Narrow with the search to see specific entities."
  :type 'integer :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--list-total 0
  "Total entities matching the current filter/search (may exceed what is shown).")

(defun cmacs-gnuseye--list-entries ()
  "Tabulated-list rows for the entity list, honouring kind filter + search.
Capped at `cmacs-gnuseye-list-max' rows; `cmacs-gnuseye--list-total' records
how many matched."
  (let ((rows nil) (shown 0) (total 0)
        (cap (or cmacs-gnuseye-list-max most-positive-fixnum)))
    (catch 'full
      (maphash
       (lambda (id e)
         (when (and (cmacs-gnuseye--entity-visible-p e)
                    (cmacs-gnuseye--search-match-p e))
           (setq total (1+ total))
           (when (< shown cap)
             (let ((a (plist-get e :alt)))
               (push (list id
                           (vector
                            (symbol-name (or (plist-get e :kind) 'generic))
                            (or (plist-get e :label) id)
                            (format "%.2f" (or (plist-get e :lat) 0.0))
                            (format "%.2f" (or (plist-get e :lon) 0.0))
                            (if (and (numberp a) (> a 0))
                                (format "%.0f" (/ a 1000.0)) "-")
                            (format "%s" (or (plist-get e :layer) ""))))
                     rows)
               (setq shown (1+ shown))))))
       cmacs-gnuseye--id-index))
    (setq cmacs-gnuseye--list-total total)
    rows))

(defun cmacs-gnuseye--list-refresh-now ()
  "Repaint the entity list buffer if it exists, keeping point."
  (let ((b (get-buffer cmacs-gnuseye--list-name)))
    (when (and b (buffer-live-p b))
      (with-current-buffer b
        (setq tabulated-list-entries (cmacs-gnuseye--list-entries))
        (tabulated-list-print t)
        (cmacs-gnuseye--list-update-header)))))

(defvar cmacs-gnuseye--list-refresh-timer nil)

(defun cmacs-gnuseye--list-refresh-soon ()
  "Repaint the entity list, debounced so rapid updates coalesce into one.
Painting a large tabulated-list is expensive, so callers that fire in
bursts (the incremental fetch, search-as-you-type) must not paint every
time."
  (when (timerp cmacs-gnuseye--list-refresh-timer)
    (cancel-timer cmacs-gnuseye--list-refresh-timer))
  (setq cmacs-gnuseye--list-refresh-timer
        (run-with-timer 0.35 nil #'cmacs-gnuseye--list-refresh-now)))

(defvar cmacs-gnuseye--index-refresh-timer nil)

(defun cmacs-gnuseye--schedule-index-refresh ()
  "Debounced rebuild of the id-index + entity list.
The fetch callback fires this once per (incremental) chunk; coalescing
keeps the expensive reindex + list paint off the hot path."
  (when (timerp cmacs-gnuseye--index-refresh-timer)
    (cancel-timer cmacs-gnuseye--index-refresh-timer))
  (setq cmacs-gnuseye--index-refresh-timer
        (run-with-timer
         0.4 nil
         (lambda ()
           (setq cmacs-gnuseye--index-refresh-timer nil)
           (cmacs-gnuseye--reindex)
           (cmacs-gnuseye--list-refresh-now)
           (cmacs-gnuseye-layers-refresh)))))

(defun cmacs-gnuseye--list-update-header ()
  (let ((shown (length tabulated-list-entries)))
    (setq header-line-format
          (format " entities: %s   filter: %s   search: %s"
                  (if (> cmacs-gnuseye--list-total shown)
                      (format "%d of %d (search to narrow)"
                              shown cmacs-gnuseye--list-total)
                    (format "%d" shown))
                  (if cmacs-gnuseye-active-kinds
                      (mapconcat #'symbol-name cmacs-gnuseye-active-kinds ",")
                    "all")
                  (if (string-empty-p cmacs-gnuseye--search) "-"
                    cmacs-gnuseye--search)))))

(defun cmacs-gnuseye--list-goto (id)
  "Move point to the row for ID in the list buffer, if shown."
  (let ((b (get-buffer cmacs-gnuseye--list-name)))
    (when (and b (buffer-live-p b) (get-buffer-window b))
      (with-current-buffer b
        (goto-char (point-min))
        (let ((target (format "%s" id)))
          (while (and (not (eobp))
                      (not (equal (tabulated-list-get-id) target)))
            (forward-line 1)))))))

(defvar cmacs-gnuseye-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-gnuseye-list-select)
    (define-key map (kbd "s")   #'cmacs-gnuseye-search)
    (define-key map (kbd "f")   #'cmacs-gnuseye-filter-kinds)
    (define-key map (kbd "c")   #'cmacs-gnuseye-filter-clear)
    (define-key map (kbd "g")   #'cmacs-gnuseye-list-refresh)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map [mouse-1]   #'cmacs-gnuseye-list-select)
    map)
  "Keymap for `cmacs-gnuseye-list-mode'.")

(define-derived-mode cmacs-gnuseye-list-mode tabulated-list-mode "GnuseyeEntities"
  "Searchable, filterable list of the globe's live entities."
  (setq tabulated-list-format
        [("Kind" 10 t) ("Label" 18 t) ("Lat" 8 t) ("Lon" 9 t)
         ("Alt" 6 t) ("Layer" 10 t)])
  (setq tabulated-list-sort-key '("Kind" . nil))
  (tabulated-list-init-header))

(defun cmacs-gnuseye-list-select (&optional event)
  "Select the entity on the current list row (inspector + globe)."
  (interactive (list last-nonmenu-event))
  (when event (ignore-errors (mouse-set-point event)))
  (let ((id (tabulated-list-get-id)))
    (when id (cmacs-gnuseye--select-entity id))))

(defun cmacs-gnuseye-list-refresh ()
  "Repaint the entity list."
  (interactive)
  (cmacs-gnuseye--list-refresh-soon))

(defun cmacs-gnuseye-search (query)
  "Narrow the entity list to rows matching QUERY (empty clears)."
  (interactive
   (list (read-string "Search entities (label/id/kind, empty clears): "
                      cmacs-gnuseye--search)))
  (setq cmacs-gnuseye--search (or query ""))
  (cmacs-gnuseye--list-refresh-soon))

(defun cmacs-gnuseye-filter-kinds (kinds)
  "Show only KINDS on the globe and in the list (empty selection = all).
Pick one or more of e.g. aircraft, ship, satellite, quake."
  (interactive
   (list (completing-read-multiple
          "Show kinds (comma-separated, empty = all): "
          (mapcar #'symbol-name cmacs-gnuseye--known-kinds))))
  (setq cmacs-gnuseye-active-kinds
        (delq nil (mapcar (lambda (s) (and (stringp s) (not (string-empty-p s))
                                           (intern s)))
                          kinds)))
  (cmacs-gnuseye--render-all)
  (cmacs-gnuseye--list-refresh-soon)
  (message "GNU's Eye showing: %s"
           (if cmacs-gnuseye-active-kinds
               (mapconcat #'symbol-name cmacs-gnuseye-active-kinds ", ")
             "all kinds")))

(defun cmacs-gnuseye-filter-clear ()
  "Clear the kind filter and the search."
  (interactive)
  (setq cmacs-gnuseye-active-kinds nil
        cmacs-gnuseye--search "")
  (cmacs-gnuseye--render-all)
  (cmacs-gnuseye--list-refresh-soon)
  (message "GNU's Eye filters cleared"))

(defun cmacs-gnuseye--show-list ()
  "Show the entity list pane."
  (let ((b (get-buffer-create cmacs-gnuseye--list-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'cmacs-gnuseye-list-mode)
        (cmacs-gnuseye-list-mode))
      (setq tabulated-list-entries (cmacs-gnuseye--list-entries))
      (tabulated-list-print)
      (cmacs-gnuseye--list-update-header))
    (display-buffer-in-side-window
     b '((side . left) (slot . 1) (window-width . 0.24)))
    b))

;;;; Entity-type toggles (checkbox pane) -------------------------------------

;; A checkbox per entity type (data layer): checking it turns that type's
;; rendering on (the layer fetches + draws); unchecking turns it off and
;; clears its markers.  Everything starts off.

(defconst cmacs-gnuseye--types-name "*GNU's Eye Types*")

(defcustom cmacs-gnuseye-group-order
  '(celestial astronomical air marine weather meteo natural space-weather
    conflict infra health media markets)
  "Order the entity-type categories appear in the toggle pane.
Groups not listed here are appended alphabetically after these."
  :type '(repeat symbol)
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-group-titles
  '((celestial . "Solar system") (astronomical . "Astronomical")
    (air . "Air traffic")
    (marine . "Marine") (weather . "Weather & events")
    (meteo . "Meteorology")
    (natural . "Natural events") (space-weather . "Space weather")
    (conflict . "Conflict & geopolitics") (infra . "Infrastructure")
    (health . "Health & society") (media . "Media & cameras")
    (markets . "Markets") (other . "Other"))
  "Human titles for entity-type categories in the toggle pane."
  :type '(alist :key-type symbol :value-type string)
  :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye--expanded-groups (make-hash-table :test 'eq)
  "Category symbol -> non-nil when that group is expanded in the toggle pane.
Absent means collapsed: every category starts collapsed, so the pane opens as
a short list of categories the user expands to reveal and enable layers.")

(defun cmacs-gnuseye--group-of (layer)
  "The category symbol for LAYER (`other' when it declares no :group)."
  (or (cmacs-gnuseye-layer-group layer) 'other))

(defun cmacs-gnuseye--group-title (g)
  "Human title for category symbol G."
  (or (alist-get g cmacs-gnuseye-group-titles)
      (capitalize (symbol-name g))))

(defun cmacs-gnuseye--group-expanded-p (g)
  "Non-nil when category G is expanded."
  (gethash g cmacs-gnuseye--expanded-groups))

(defun cmacs-gnuseye--layer-status (layer)
  "Short status string for LAYER in the toggle pane."
  (let* ((on (cmacs-gnuseye-layer-enabled layer))
         (needs (cmacs-gnuseye-layer-needs-key layer))
         ;; -cached: pane repaints are passive and must never trigger a gpg
         ;; pinentry; the enable path does the full (prompting) resolution.
         (missing (and needs (not (cmacs-gnuseye-secret-cached needs)))))
    (cond
     (missing (format "needs %s" needs))
     ((and on (cmacs-gnuseye-layer-last-error layer))
      (truncate-string-to-width (cmacs-gnuseye-layer-last-error layer) 12))
     (on (let ((lf (cmacs-gnuseye-layer-last-fetch layer)))
           (if lf (format "%ds" (truncate (- (float-time) lf))) "loading…")))
     (t ""))))

(defun cmacs-gnuseye--layers-entries ()
  "Tabulated-list rows for the entity-type toggle pane.
Layers are grouped under collapsible category headers; a header row has id
\\=(:group . SYM), a layer row has the layer name as its id.  Everything is off
by default and categories start collapsed."
  (let ((buckets (make-hash-table :test 'eq)))
    (maphash (lambda (_ layer)
               (push layer (gethash (cmacs-gnuseye--group-of layer) buckets)))
             cmacs-gnuseye--layers)
    (let* ((present (hash-table-keys buckets))
           (ordered (append
                     (seq-filter (lambda (g) (memq g present))
                                 cmacs-gnuseye-group-order)
                     (sort (seq-remove (lambda (g)
                                         (memq g cmacs-gnuseye-group-order))
                                       present)
                           (lambda (a b) (string< (symbol-name a)
                                                  (symbol-name b))))))
           rows)
      (dolist (g ordered)
        (let* ((layers (sort (gethash g buckets)
                             (lambda (a b)
                               (string< (format "%s" (cmacs-gnuseye-layer-title a))
                                        (format "%s" (cmacs-gnuseye-layer-title b))))))
               (on-count (seq-count #'cmacs-gnuseye-layer-enabled layers))
               (expanded (cmacs-gnuseye--group-expanded-p g)))
          (push (list (cons :group g)
                      (vector (if expanded "▾" "▸")
                              (cmacs-gnuseye--group-title g)
                              (if (> on-count 0) (format "%d on" on-count) "")))
                rows)
          (when expanded
            (dolist (layer layers)
              (let ((name (cmacs-gnuseye-layer-name layer)))
                (push (list name
                            (vector (concat " " (if (cmacs-gnuseye-layer-enabled
                                                     layer)
                                                    "☑" "☐"))
                                    (concat "  " (or (cmacs-gnuseye-layer-title layer)
                                                     (capitalize
                                                      (symbol-name name))))
                                    (cmacs-gnuseye--layer-status layer)))
                      rows))))))
      (nreverse rows))))

(defvar cmacs-gnuseye-layers-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-gnuseye-layers-toggle)
    (define-key map (kbd "SPC") #'cmacs-gnuseye-layers-toggle)
    (define-key map (kbd "t")   #'cmacs-gnuseye-layers-toggle)
    (define-key map (kbd "g")   #'cmacs-gnuseye-layers-refresh)
    (define-key map (kbd "q")   #'quit-window)
    (define-key map [mouse-1]   #'cmacs-gnuseye-layers-toggle)
    map)
  "Keymap for `cmacs-gnuseye-layers-mode' (the entity-type toggle pane).")

(define-derived-mode cmacs-gnuseye-layers-mode tabulated-list-mode "GnuseyeTypes"
  "Checkbox list toggling which entity types are rendered on the globe.
Categories collapse/expand; layers are checkboxes.  Everything starts off."
  (setq tabulated-list-format [("" 2 nil) ("Type" 20 nil) ("" 12 nil)]
        tabulated-list-sort-key nil)
  (tabulated-list-init-header)
  (setq header-line-format " Categories · SPC/RET expand+toggle · g refresh"))

(defun cmacs-gnuseye-layers-refresh ()
  "Repaint the entity-type toggle pane."
  (interactive)
  (let ((b (get-buffer cmacs-gnuseye--types-name)))
    (when (and b (buffer-live-p b))
      (with-current-buffer b
        (setq tabulated-list-entries (cmacs-gnuseye--layers-entries))
        (tabulated-list-print t)))))

(defun cmacs-gnuseye-layers-toggle (&optional event)
  "Act on the current toggle-pane row.
On a category header, expand or collapse that category.  On a layer row,
turn that entity type on or off (enabling fetches + draws; disabling clears
it).  Layers needing an API key that is unset cannot be enabled."
  (interactive (list last-nonmenu-event))
  (when (mouse-event-p event) (ignore-errors (mouse-set-point event)))
  (let ((id (tabulated-list-get-id)))
    (cond
     ;; Category header: toggle collapse/expand.
     ((and (consp id) (eq (car id) :group))
      (let ((g (cdr id)))
        (if (cmacs-gnuseye--group-expanded-p g)
            (remhash g cmacs-gnuseye--expanded-groups)
          (puthash g t cmacs-gnuseye--expanded-groups)))
      (cmacs-gnuseye-layers-refresh))
     ;; Layer row: enable/disable.
     ((symbolp id)
      (let ((layer (and id (gethash id cmacs-gnuseye--layers))))
        (when layer
          (if (cmacs-gnuseye-layer-enabled layer)
              (cmacs-gnuseye--disable-layer layer)
            (let ((needs (cmacs-gnuseye-layer-needs-key layer)))
              (if (and needs (not (cmacs-gnuseye-secret needs)))
                  (message "GNU's Eye: %s needs %s to enable"
                           (or (cmacs-gnuseye-layer-title layer)
                               (capitalize (symbol-name id)))
                           needs)
                (cmacs-gnuseye--enable-layer layer))))
          (cmacs-gnuseye-layers-refresh)))))))

(defun cmacs-gnuseye--show-types ()
  "Show the entity-type checkbox pane (above the entity list)."
  (let ((b (get-buffer-create cmacs-gnuseye--types-name)))
    (with-current-buffer b
      (unless (derived-mode-p 'cmacs-gnuseye-layers-mode)
        (cmacs-gnuseye-layers-mode))
      (setq tabulated-list-entries (cmacs-gnuseye--layers-entries))
      (tabulated-list-print))
    (display-buffer-in-side-window
     b '((side . left) (slot . 0) (window-width . 0.24)
         (window-height . 10) (preserve-size . (nil . t))))
    b))

;;;###autoload
(defun cmacs-gnuseye-layers ()
  "Open the GNU's Eye entity-type toggle pane."
  (interactive)
  (cmacs-gnuseye--load-layers)
  (select-window (get-buffer-window (cmacs-gnuseye--show-types))))

;;;; Mode + entry point ------------------------------------------------------

(defun cmacs-gnuseye-legend ()
  "Show a legend of marker kinds, shapes, and colours."
  (interactive)
  (let ((buf (get-buffer-create "*GNU's Eye Legend*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "GNU's Eye — marker legend\n" 'face 'bold))
        (insert "─────────────────────────\n\n")
        (dolist (row '(("satellite" "winged body + solar panels, high, orbit trail")
                       ("aircraft"  "plane (nose = heading), floats at altitude + drop-line")
                       ("ship"      "hull + superstructure (bow = heading), on the water")
                       ("quake"     "sphere sized by magnitude, on the surface")
                       ("fire"      "flame, on the surface")
                       ("launch"    "upright rocket at the pad")
                       ("camera"    "camera body")
                       ("city"      "pin")))
          (let* ((kind (intern (car row)))
                 (style (alist-get kind cmacs-gnuseye-kind-styles))
                 (color (or (plist-get style :color) "#ffd24a")))
            (insert (propertize "  ███  " 'face (list :foreground color)))
            (insert (format "%-10s %s\n" (car row) (cadr row)))))
        (insert "\nInteract: drag = orbit, scroll = zoom, right-drag = pan,\n")
        (insert "hover = identify, click = recentre + details.\n"))
      (goto-char (point-min))
      (special-mode))
    (display-buffer
     buf '((display-buffer-in-side-window) (side . right) (window-width . 0.34)))))

(defvar cmacs-gnuseye-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "e") #'cmacs-gnuseye-entities)
    (define-key map (kbd "i") #'cmacs-gnuseye-inspector)
    (define-key map (kbd "l") #'cmacs-gnuseye-layers)
    (define-key map (kbd "s") #'cmacs-gnuseye-search)
    (define-key map (kbd "F") #'cmacs-gnuseye-filter-kinds)
    (define-key map (kbd "c") #'cmacs-gnuseye-filter-clear)
    (define-key map (kbd "g") #'cmacs-gnuseye-refresh-all)
    (define-key map (kbd "f") #'cmacs-gnuseye-fly-to-place)
    (define-key map (kbd "?") #'cmacs-gnuseye-legend)
    (define-key map (kbd "2") #'cmacs-gnuseye-view-2d)
    (define-key map (kbd "3") #'cmacs-gnuseye-view-3d)
    (define-key map (kbd "u") #'cmacs-gnuseye-deselect)
    (define-key map (kbd "<escape>") #'cmacs-gnuseye-escape)
    (define-key map (kbd "0") #'cmacs-gnuseye-home)
    (define-key map (kbd "<home>") #'cmacs-gnuseye-home)
    (define-key map (kbd "+") #'cmacs-gnuseye-zoom-in)
    (define-key map (kbd "=") #'cmacs-gnuseye-zoom-in)
    (define-key map (kbd "-") #'cmacs-gnuseye-zoom-out)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-gnuseye-mode'.")

(defun cmacs-gnuseye--on-kill ()
  "Tear down the globe view and stop tracking the window when the buffer dies."
  (remove-hook 'window-size-change-functions #'cmacs-gnuseye--on-size-change)
  (when cmacs-gnuseye--sun-timer
    (cancel-timer cmacs-gnuseye--sun-timer)
    (setq cmacs-gnuseye--sun-timer nil))
  (ignore-errors (cmacs-gnuseye-detach (current-buffer)))
  (when (eq (current-buffer) cmacs-gnuseye-buffer)
    (setq cmacs-gnuseye-buffer nil)))

(define-derived-mode cmacs-gnuseye-mode special-mode "GNU's-Eye"
  "Major mode for the GNU's Eye live globe.
The buffer's text area is covered by the libregnum globe blit; mouse
drag orbits, scroll zooms, right-drag pans, hover identifies a marker,
and clicking one selects it (inspector + recentre)."
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'cmacs-gnuseye--on-kill nil t)
  (setq-local mode-line-format
              '(" GNU's Eye  drag=orbit scroll=zoom hover=id click=select \
 [e]ntities [i]nspect [l]ayers [s]earch [u]nselect [0]home [?]legend [q]uit")))

(defun cmacs-gnuseye-entities ()
  "Show (and select) the entity list pane."
  (interactive)
  (select-window (get-buffer-window (cmacs-gnuseye--show-list))))

(defun cmacs-gnuseye-inspector ()
  "Show the inspector pane for the current selection."
  (interactive)
  (cmacs-gnuseye--show-inspector))

(defun cmacs-gnuseye-refresh-all ()
  "Refresh every enabled layer now."
  (interactive)
  (maphash (lambda (_ layer)
             (when (cmacs-gnuseye-layer-enabled layer)
               (cmacs-gnuseye--refresh-layer layer)))
           cmacs-gnuseye--layers)
  (message "GNU's Eye: refreshing enabled layers"))

(defun cmacs-gnuseye-refresh-view-layers ()
  "Re-pick which markers are drawn for the current view.
With worldwide aircraft the full set is already indexed, so this just
re-renders the nearest `cmacs-gnuseye-render-max' to the new view centre
\(instant, no network); fresh positions arrive on the layer timer.  In
view-scoped (non-global) mode it also re-fetches aircraft."
  (interactive)
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
    (cmacs-gnuseye--render-all cmacs-gnuseye-buffer)
    (when (and (boundp 'cmacs-gnuseye-air-global)
               (not cmacs-gnuseye-air-global))
      (let ((layer (and (boundp 'cmacs-gnuseye--layers)
                        (gethash 'aircraft cmacs-gnuseye--layers))))
        (when (and layer (cmacs-gnuseye-layer-enabled layer))
          (cmacs-gnuseye--refresh-layer layer))))))

(defun cmacs-gnuseye-fly-to-place (lat lon)
  "Fly the globe camera to LAT, LON (degrees, read from the minibuffer)."
  (interactive "nLatitude: \nnLongitude: ")
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
    (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer (float lat) (float lon) 14.0 t)
    ;; Let the fly-to tween settle, then re-scope aircraft to the new view.
    (run-with-timer 2.0 nil #'cmacs-gnuseye-refresh-view-layers)))

;;;; The map: coastlines, borders, labels, admin-1, all aligned ------------

;; Real geography drawn in the globe's own lat/lon convention, so (unlike a
;; raster texture) it always lines up with the markers.  Data is Natural
;; Earth (public domain), downloaded once and cached under the gnuseye
;; cache directory.

(defconst cmacs-gnuseye--ne-base
  "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/")

(defcustom cmacs-gnuseye-coastlines t
  "Draw continent coastlines on the globe." :type 'boolean
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-borders t
  "Draw country borders on the globe." :type 'boolean :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-labels t
  "Draw country name labels (shown once zoomed in)." :type 'boolean
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-admin1 t
  "Draw admin-1 boundaries (states/provinces) for `cmacs-gnuseye-admin1-countries'."
  :type 'boolean :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-admin1-countries '("USA" "CAN")
  "ISO-A3 country codes whose states/provinces are drawn (admin-1)."
  :type '(repeat string) :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-flags t
  "Draw country flags on the globe (shown once zoomed in).
Flag images (flagcdn.com) are downloaded once and cached; the first time
they trickle in over a short while, then load instantly."
  :type 'boolean :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-flag-size 0.02
  "Country flag apparent size (a little larger than the label text).
Flags are scaled by the zoom so they keep a roughly constant on-screen
size; this is that size as a fraction of the camera's near distance."
  :type 'number :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-flag-url-format "https://flagcdn.com/w80/%s.png"
  "Flag image URL; %s is the lowercase ISO-A2 country code."
  :type 'string :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-lakes t
  "Draw major lakes (incl. the Great Lakes) on the globe." :type 'boolean
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-coastline-color "#c8a96f"
  "Coastline colour." :type 'string :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-lake-color "#5b86b0"
  "Lake-shore colour (a muted water blue)." :type 'string
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-border-color "#6f93ba"
  "Country border colour." :type 'string :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-admin1-color "#48627f"
  "Admin-1 (state/province) border colour." :type 'string
  :group 'cmacs-gnuseye)
(defcustom cmacs-gnuseye-label-color "#e8eff6"
  "Country label colour." :type 'string :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--geojson (file callback)
  "Fetch+cache Natural Earth FILE under the gnuseye cache; call (CALLBACK DATA)."
  (let ((path (expand-file-name (concat "cmacs/gnuseye/" file)
                                (or (getenv "XDG_CACHE_HOME") "~/.cache"))))
    (cl-flet ((parse (s) (ignore-errors
                           (json-parse-string s :object-type 'alist
                                              :array-type 'list))))
      (if (file-readable-p path)
          (funcall callback
                   (parse (with-temp-buffer (insert-file-contents path)
                                            (buffer-string))))
        (cmacs-gnuseye-fetch-text
         (concat cmacs-gnuseye--ne-base file)
         (lambda (body)
           (when (and body (> (length body) 100))
             (ignore-errors
               (make-directory (file-name-directory path) t)
               (with-temp-file path (insert body)))
             (funcall callback (parse body)))))))))

(defun cmacs-gnuseye--decimate (coords step)
  "Keep every STEP-th point of COORDS, always including the last."
  (if (<= step 1) coords
    (let ((out nil) (i 0) (n (length coords)))
      (dolist (p coords)
        (when (or (zerop (mod i step)) (= i (1- n))) (push p out))
        (setq i (1+ i)))
      (nreverse out))))

(defun cmacs-gnuseye--draw-line (buffer coords rgba &optional step)
  "Draw one COORDS polyline (list of (LON LAT)) on BUFFER's globe."
  (let* ((pts (cmacs-gnuseye--decimate coords (or step 1)))
         (n (length pts)))
    (when (>= n 2)
      (let ((lats (make-vector n 0.0)) (lons (make-vector n 0.0)) (i 0))
        (dolist (p pts)
          (aset lons i (float (or (nth 0 p) 0.0)))
          (aset lats i (float (or (nth 1 p) 0.0)))
          (setq i (1+ i)))
        (ignore-errors (cmacs-gnuseye-add-coastline buffer lats lons rgba))))))

(defun cmacs-gnuseye--draw-lines (buffer data rgba &optional step)
  "Draw all LineString/MultiLineString features of DATA."
  (dolist (f (alist-get 'features data))
    (let* ((geom (alist-get 'geometry f))
           (gt (alist-get 'type geom))
           (coords (alist-get 'coordinates geom)))
      (cond
       ((equal gt "LineString")
        (cmacs-gnuseye--draw-line buffer coords rgba step))
       ((equal gt "MultiLineString")
        (dolist (l coords) (cmacs-gnuseye--draw-line buffer l rgba step)))))))

(defun cmacs-gnuseye--draw-polygons (buffer data rgba filter &optional step)
  "Draw the rings of Polygon/MultiPolygon features passing FILTER."
  (dolist (f (alist-get 'features data))
    (when (or (null filter) (funcall filter f))
      (let* ((geom (alist-get 'geometry f))
             (gt (alist-get 'type geom))
             (coords (alist-get 'coordinates geom)))
        (cond
         ((equal gt "Polygon")
          (dolist (ring coords)
            (cmacs-gnuseye--draw-line buffer ring rgba step)))
         ((equal gt "MultiPolygon")
          (dolist (poly coords)
            (dolist (ring poly)
              (cmacs-gnuseye--draw-line buffer ring rgba step)))))))))

(defun cmacs-gnuseye--draw-country-labels (buffer data)
  "Add a label at each country's anchor point (NAME + LABEL_X/LABEL_Y)."
  (let ((rgba (cmacs-gnuseye--color->rgba cmacs-gnuseye-label-color)))
    (dolist (f (alist-get 'features data))
      (let* ((props (alist-get 'properties f))
             (name (or (alist-get 'NAME props) (alist-get 'name props)))
             (lx (alist-get 'LABEL_X props))
             (ly (alist-get 'LABEL_Y props)))
        (when (and (stringp name) (numberp lx) (numberp ly))
          (ignore-errors
            (cmacs-gnuseye-add-label buffer (float ly) (float lx) name rgba)))))))

;;;; Choropleth (country fill by a scalar; driven by the CII intel layer) -----

(defun cmacs-gnuseye--risk->rgba (scalar &optional alpha)
  "Map SCALAR in [0,1] to a green->yellow->red translucent wash RGBA.
ALPHA (0-255) is the wash opacity (default 90 -- see-through)."
  (let* ((s (max 0.0 (min 1.0 (or scalar 0.0))))
         (a (or alpha 90))
         (r (round (* 255 (min 1.0 (* 2.0 s)))))
         (g (round (* 255 (min 1.0 (* 2.0 (- 1.0 s)))))))
    (logior (ash r 24) (ash g 16) (ash 40 8) a)))

(defun cmacs-gnuseye--choropleth-iso (props)
  "ISO-A3 code from a Natural Earth admin-0 feature's PROPS, or nil."
  (or (alist-get 'ISO_A3 props) (alist-get 'adm0_a3 props)
      (alist-get 'ADM0_A3 props) (alist-get 'iso_a3 props)))

(defun cmacs-gnuseye--choropleth-ring (buffer ring rgba step)
  "Fill one outer RING (list of (LON LAT)) as a persistent polygon on BUFFER."
  (let* ((pts (cmacs-gnuseye--decimate ring (or step 1)))
         (n (length pts)))
    (when (>= n 3)
      (let ((lats (make-vector n 0.0)) (lons (make-vector n 0.0)) (i 0))
        (dolist (p pts)
          (aset lons i (float (or (nth 0 p) 0.0)))
          (aset lats i (float (or (nth 1 p) 0.0)))
          (setq i (1+ i)))
        (ignore-errors (cmacs-gnuseye-add-polygon buffer lats lons rgba t))))))

(defun cmacs-gnuseye-choropleth (buffer scores &optional alpha step)
  "Fill countries on BUFFER's globe by SCORES (a hash or alist of ISO-A3 ->
scalar in [0,1]).  Clears any previous choropleth fills first.  ALPHA sets the
wash opacity; STEP decimates rings (default 3).  Uses the cached Natural Earth
admin-0 countries.  Outer rings only; antimeridian-crossing countries may
smear (a documented refinement)."
  (let ((step (or step 3)))
    (when (and buffer (buffer-live-p buffer) (cmacs-gnuseye-attached-p buffer))
      (ignore-errors (cmacs-gnuseye-clear-polygons buffer t))
      (cmacs-gnuseye--geojson
       "ne_110m_admin_0_countries.geojson"
       (lambda (d)
         (when (buffer-live-p buffer)
           (dolist (f (alist-get 'features d))
             (let* ((props (alist-get 'properties f))
                    (iso (cmacs-gnuseye--choropleth-iso props))
                    (sc (and iso (if (hash-table-p scores)
                                     (gethash iso scores)
                                   (cdr (assoc iso scores))))))
               (when (numberp sc)
                 (let* ((rgba (cmacs-gnuseye--risk->rgba sc alpha))
                        (geom (alist-get 'geometry f))
                        (gt (alist-get 'type geom))
                        (coords (alist-get 'coordinates geom)))
                   (cond
                    ((equal gt "Polygon")
                     (cmacs-gnuseye--choropleth-ring buffer (car coords)
                                                     rgba step))
                    ((equal gt "MultiPolygon")
                     (dolist (poly coords)
                       (cmacs-gnuseye--choropleth-ring buffer (car poly)
                                                       rgba step))))))))
           (cmacs-gnuseye-redraw buffer)))))))

(defun cmacs-gnuseye-choropleth-clear (&optional buffer)
  "Remove the choropleth fills from BUFFER (or the active globe)."
  (interactive)
  (let ((buffer (or buffer cmacs-gnuseye-buffer)))
    (when (and buffer (buffer-live-p buffer) (cmacs-gnuseye-attached-p buffer))
      (ignore-errors (cmacs-gnuseye-clear-polygons buffer t))
      (cmacs-gnuseye-redraw buffer))))

(defun cmacs-gnuseye--flag-path (cc)
  (expand-file-name (format "cmacs/gnuseye/flags/%s.png" (downcase cc))
                    (or (getenv "XDG_CACHE_HOME") "~/.cache")))

(defun cmacs-gnuseye--fetch-flag (cc path callback)
  "Download the flag for ISO-A2 code CC to PATH (binary); call (CALLBACK OK)."
  (url-retrieve
   (format cmacs-gnuseye-flag-url-format (downcase cc))
   (lambda (status)
     (let ((ok nil))
       (unless (plist-get status :error)
         (goto-char (point-min))
         (when (re-search-forward "\r?\n\r?\n" nil t)
           (let ((data (buffer-substring-no-properties (point) (point-max))))
             (ignore-errors
               (make-directory (file-name-directory path) t)
               (let ((coding-system-for-write 'binary))
                 (with-temp-file path
                   (set-buffer-multibyte nil)
                   (insert data)))
               (setq ok (file-readable-p path))))))
       (when callback (funcall callback ok))))
   nil t t))

(defun cmacs-gnuseye--flag-fetch-queue (buffer queue size)
  "Fetch missing flags in QUEUE one at a time, adding each as it arrives."
  (when (and queue (buffer-live-p buffer))
    (let ((item (car queue)))
      (cmacs-gnuseye--fetch-flag
       (nth 0 item) (nth 3 item)
       (lambda (ok)
         (when (and ok (buffer-live-p buffer)
                    (cmacs-gnuseye-attached-p buffer))
           (ignore-errors
             (cmacs-gnuseye-add-flag buffer (nth 1 item) (nth 2 item)
                                     (nth 3 item) size))
           (cmacs-gnuseye-redraw buffer))
         (cmacs-gnuseye--flag-fetch-queue buffer (cdr queue) size))))))

(defun cmacs-gnuseye--load-flags (buffer data)
  "Place a flag at each country's anchor (cached flags now, missing async)."
  (let ((size cmacs-gnuseye-flag-size) (queue nil))
    (dolist (f (alist-get 'features data))
      (let* ((props (alist-get 'properties f))
             (cc (seq-find (lambda (c) (and (stringp c) (= (length c) 2)
                                            (not (string= c "-99"))))
                           (list (alist-get 'ISO_A2_EH props)
                                 (alist-get 'ISO_A2 props)
                                 (alist-get 'iso_a2 props))))
             (lx (alist-get 'LABEL_X props))
             (ly (alist-get 'LABEL_Y props)))
        (when (and (stringp cc) (numberp lx) (numberp ly))
          (let ((path (cmacs-gnuseye--flag-path cc)))
            (if (file-readable-p path)
                (ignore-errors
                  (cmacs-gnuseye-add-flag buffer (float ly) (float lx)
                                          path size))
              (push (list cc (float ly) (float lx) path) queue))))))
    (cmacs-gnuseye-redraw buffer)
    (cmacs-gnuseye--flag-fetch-queue buffer (nreverse queue) size)))

;;;###autoload
(defun cmacs-gnuseye-load-map (&optional buffer)
  "Draw the world map (coastlines, borders, labels, admin-1) on BUFFER's globe.
Each layer's data is downloaded + cached once.  Honours the
`cmacs-gnuseye-coastlines'/`-borders'/`-labels'/`-admin1' toggles."
  (interactive)
  (let ((buffer (or buffer cmacs-gnuseye-buffer)))
    (when (and buffer (buffer-live-p buffer)
               (cmacs-gnuseye-attached-p buffer)
               (fboundp 'cmacs-gnuseye-add-coastline))
      (cmacs-gnuseye-clear-coastlines buffer)
      (cmacs-gnuseye-clear-labels buffer)
      (when (fboundp 'cmacs-gnuseye-clear-flags)
        (cmacs-gnuseye-clear-flags buffer))
      (when cmacs-gnuseye-coastlines
        (cmacs-gnuseye--geojson
         "ne_110m_coastline.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-lines
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-coastline-color))
             (cmacs-gnuseye-redraw buffer)))))
      (when cmacs-gnuseye-lakes
        (cmacs-gnuseye--geojson
         "ne_50m_lakes.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-polygons
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-lake-color)
              nil)
             (cmacs-gnuseye-redraw buffer)))))
      (when cmacs-gnuseye-borders
        (cmacs-gnuseye--geojson
         "ne_110m_admin_0_boundary_lines_land.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-lines
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-border-color))
             (cmacs-gnuseye-redraw buffer)))))
      (when cmacs-gnuseye-admin1
        (cmacs-gnuseye--geojson
         "ne_50m_admin_1_states_provinces.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (cmacs-gnuseye--draw-polygons
              buffer d (cmacs-gnuseye--color->rgba cmacs-gnuseye-admin1-color)
              (lambda (f)
                (member (alist-get 'adm0_a3 (alist-get 'properties f))
                        cmacs-gnuseye-admin1-countries))
              2)
             (cmacs-gnuseye-redraw buffer)))))
      (when (or cmacs-gnuseye-labels cmacs-gnuseye-flags)
        (cmacs-gnuseye--geojson
         "ne_110m_admin_0_countries.geojson"
         (lambda (d)
           (when (buffer-live-p buffer)
             (when cmacs-gnuseye-labels
               (cmacs-gnuseye--draw-country-labels buffer d))
             (when (and cmacs-gnuseye-flags
                        (fboundp 'cmacs-gnuseye-add-flag))
               (cmacs-gnuseye--load-flags buffer d))
             (cmacs-gnuseye-redraw buffer))))))))

(defalias 'cmacs-gnuseye-load-coastlines 'cmacs-gnuseye-load-map)

(defun cmacs-gnuseye-zoom-in ()
  "Zoom the globe camera in one step (altitude-proportional, never through)."
  (interactive)
  (when (and cmacs-gnuseye-buffer (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-gnuseye-zoom))
    (cmacs-gnuseye-zoom cmacs-gnuseye-buffer 1.0)))

(defun cmacs-gnuseye-zoom-out ()
  "Zoom the globe camera out one step."
  (interactive)
  (when (and cmacs-gnuseye-buffer (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-gnuseye-zoom))
    (cmacs-gnuseye-zoom cmacs-gnuseye-buffer -1.0)))

(defun cmacs-gnuseye--set-projection-1 (flat)
  "Switch the view to the 2D flat map (FLAT non-nil) or the 3D globe."
  (let ((buf cmacs-gnuseye-buffer))
    (when (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf)
               (fboundp 'cmacs-gnuseye-set-projection))
      (if (eq (and (cmacs-gnuseye-flat-p buf) t) (and flat t))
          (message "GNU's Eye: already the %s"
                   (if flat "2D flat map" "3D globe"))
        (cmacs-gnuseye-set-projection buf flat)
        (cmacs-gnuseye-load-map buf)
        (cmacs-gnuseye--render-all buf)
        (cmacs-gnuseye-redraw buf)
        (message "GNU's Eye: %s" (if flat "2D flat map" "3D globe"))))))

;;;###autoload
(defun cmacs-gnuseye-view-2d ()
  "Switch to the 2D equirectangular flat map (key `2'; `3' returns to 3D)."
  (interactive)
  (cmacs-gnuseye--set-projection-1 t))

;;;###autoload
(defun cmacs-gnuseye-view-3d ()
  "Switch back to the 3D globe (key `3')."
  (interactive)
  (cmacs-gnuseye--set-projection-1 nil))

;;;###autoload
(defun cmacs-gnuseye-toggle-2d ()
  "Toggle between the 3D globe and a 2D equirectangular flat map.
Reprojects all geography and markers onto the chosen surface."
  (interactive)
  (let ((buf cmacs-gnuseye-buffer))
    (when (and buf (buffer-live-p buf) (cmacs-gnuseye-attached-p buf)
               (fboundp 'cmacs-gnuseye-flat-p))
      (cmacs-gnuseye--set-projection-1 (not (cmacs-gnuseye-flat-p buf))))))

;;;; Keep the globe round: track the window's aspect ratio ------------------

(defvar cmacs-gnuseye--resize-timer nil)

(defun cmacs-gnuseye--fit-window-now ()
  "Resize the globe's render target (FBO) to its window's pixel size.
The overlay blits the FBO 1:1 across the window's pixel rectangle, so the
FBO must share the window's exact dimensions or the sphere is stretched
into an oval.  No-ops when the size is unchanged (the C side guards)."
  (setq cmacs-gnuseye--resize-timer nil)
  (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-gnuseye-attached-p)
             (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer)
             (fboundp 'cmacs-libregnum-resize))
    (let ((win (get-buffer-window cmacs-gnuseye-buffer t)))
      (when (window-live-p win)
        (let ((w (window-pixel-width win))
              (h (window-pixel-height win)))
          (when (and (> w 1) (> h 1))
            (ignore-errors
              (cmacs-libregnum-resize cmacs-gnuseye-buffer w h))))))))

(defun cmacs-gnuseye--on-size-change (&optional _frame)
  "Coalesce window size changes, then refit the globe (see `…-fit-window-now')."
  (unless cmacs-gnuseye--resize-timer
    (setq cmacs-gnuseye--resize-timer
          (run-with-idle-timer 0.06 nil #'cmacs-gnuseye--fit-window-now))))

;;;###autoload
(defun cmacs-gnuseye (&optional no-dashboard)
  "Open the GNU's Eye live planetary globe dashboard.
The globe viewport sits in the centre with an entity list on the left
and an inspector on the right.  With a prefix arg (NO-DASHBOARD), open
just the globe viewport."
  (interactive "P")
  (unless (and (fboundp 'cmacs-gnuseye-supported-p) (cmacs-gnuseye-supported-p))
    (user-error "This cmacs was not built with --with-cmacs-gnuseye"))
  (let ((buf (get-buffer-create "*GNU's Eye*")))
    (setq cmacs-gnuseye-buffer buf)
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-gnuseye-mode)
        (cmacs-gnuseye-mode))
      (let ((inhibit-read-only t))
        (when (= (buffer-size) 0)
          (insert "GNU's Eye — initialising globe…\n")))
      (unless (cmacs-gnuseye-attached-p buf)
        (cmacs-gnuseye-attach
         buf 900 600
         (or (and cmacs-gnuseye-base-texture
                  (file-exists-p cmacs-gnuseye-base-texture)
                  (expand-file-name cmacs-gnuseye-base-texture))
             ;; Real Blue-Marble style Earth when the celestial texture
             ;; fetcher has cached one (cmacs-gnuseye-celestial.el).
             (let ((f (expand-file-name
                       "~/.cache/cmacs/gnuseye/textures/2k_earth_daymap.png")))
               (and (file-exists-p f) f)))))
      ;; Start with every entity type OFF -- the user enables them from the
      ;; type-toggle pane.  (Layers are only loaded/registered here.)
      (cmacs-gnuseye--load-layers)
      (cmacs-gnuseye--load-features))
    ;; Lay out the dashboard: globe centre; entity-type toggles over the
    ;; entity list on the left; inspector on the right.
    (switch-to-buffer buf)
    (delete-other-windows)
    (unless no-dashboard
      (cmacs-gnuseye--show-types)
      (cmacs-gnuseye--show-list)
      (cmacs-gnuseye--show-inspector)
      (select-window (get-buffer-window buf)))
    ;; Keep the sphere round at any window aspect: match the FBO to the
    ;; window now, and on every later size change.
    (add-hook 'window-size-change-functions #'cmacs-gnuseye--on-size-change)
    (cmacs-gnuseye--fit-window-now)
    (cmacs-gnuseye--on-size-change)
    ;; Real geography (coastlines, borders, labels, admin-1) aligned with
    ;; the markers.
    (cmacs-gnuseye-load-map buf)
    ;; Smoothly move markers (aircraft dead-reckon, satellites re-propagate)
    ;; and re-apply the zoom scale between fetches.
    (cmacs-gnuseye--smooth-start)
    ;; Track the real day/night terminator.
    (cmacs-gnuseye--sun-start)
    buf))

;;;; Evil (Doom) + vanilla navigation -----------------------------------------

;; Make every pane usable with both vanilla Emacs and Evil/Doom:
;;  - Globe viewport: Emacs state, so its single-key commands reach the
;;    keymap instead of Evil operators (mouse drives the camera anyway).
;;  - Entity list + layers: Motion state, so Evil hjkl navigation works
;;    while they stay read-only; RET / s / f / g activate via the keymap.
;;  - Inspector: Normal state so Evil motion + Esc behave normally.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-gnuseye-mode 'emacs)
    (evil-set-initial-state 'cmacs-gnuseye-list-mode 'motion)
    (evil-set-initial-state 'cmacs-gnuseye-inspector-mode 'normal)
    (evil-set-initial-state 'cmacs-gnuseye-layers-mode 'motion))
  ;; Bind the list/layers actions in Motion state too (Motion otherwise
  ;; swallows single keys like s/f/g), keeping hjkl navigation.
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion cmacs-gnuseye-list-mode-map
      (kbd "RET") #'cmacs-gnuseye-list-select
      "s" #'cmacs-gnuseye-search
      "f" #'cmacs-gnuseye-filter-kinds
      "c" #'cmacs-gnuseye-filter-clear
      "g" #'cmacs-gnuseye-list-refresh
      "q" #'quit-window)
    (evil-define-key* 'motion cmacs-gnuseye-layers-mode-map
      (kbd "RET") #'cmacs-gnuseye-layers-toggle
      (kbd "SPC") #'cmacs-gnuseye-layers-toggle
      "t" #'cmacs-gnuseye-layers-toggle
      "g" #'cmacs-gnuseye-layers-refresh
      "q" #'quit-window)
    ;; Inspector: Normal state shadows the major-mode map (a = evil-append,
    ;; q = record macro...), so bind the built-in actions in-state; feature
    ;; actions ([a]sk AI, [.]track, [w]atch, [n]ews) bind themselves via
    ;; `cmacs-gnuseye-register-inspector-action'.
    (evil-define-key* '(normal motion) cmacs-gnuseye-inspector-mode-map
      "f" #'cmacs-gnuseye-inspector-fly
      (kbd "RET") #'cmacs-gnuseye-inspector-fly
      "q" #'quit-window)
    ;; Re-bind any actions registered before Evil loaded.
    (dolist (a cmacs-gnuseye-inspector-actions)
      (evil-define-key* '(normal motion) cmacs-gnuseye-inspector-mode-map
        (kbd (nth 0 a)) (nth 2 a))))
  ;; The globe runs in Emacs state (single keys reach its commands), where
  ;; C-w is kill-region -- so Doom's C-w h/l window movement died in the
  ;; render window.  Hand C-w to the Evil window map there.
  (when (boundp 'evil-window-map)
    (define-key cmacs-gnuseye-mode-map (kbd "C-w") evil-window-map)))

;; The auxiliary maps above are still below Evil's *minor-mode* maps, so
;; evil-snipe (default-on in Doom) can swallow `s'/`f'/`t' in the panes it
;; is active in.  Promote each pane's aux maps to intercept precedence,
;; keeping the bindings exactly as written above.  The globe viewport is
;; deliberately left out: it runs in Emacs state, where Evil binds nothing
;; and `C-z' back to Normal state must keep working.
(cmacs-evil-intercept-mode-map cmacs-gnuseye-list-mode-map
                               'cmacs-gnuseye-list-mode)
(cmacs-evil-intercept-mode-map cmacs-gnuseye-layers-mode-map
                               'cmacs-gnuseye-layers-mode)
(cmacs-evil-intercept-mode-map cmacs-gnuseye-inspector-mode-map
                               'cmacs-gnuseye-inspector-mode)

(provide 'cmacs-gnuseye)
;;; cmacs-gnuseye.el ends here
