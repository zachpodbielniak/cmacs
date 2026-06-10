;;; cmacs-gnuseye-celestial.el --- GNU's Eye solar-system layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The solar system on the globe: the Sun, the Moon, the planets, deep-space
;; probes (Voyager 1/2, New Horizons, JWST), and asteroids -- each rendered at
;; its TRUE geocentric direction (directly above its sub-point, sweeping with
;; Earth's rotation live) on a log-compressed "celestial shell":
;;
;;   world radius = clamp(20 + 10*log10(dist_km / 1e5), 12, 74)
;;   Moon ~ 26, Sun ~ 52, Neptune ~ 66, Voyager 1 ~ 74
;;
;; True scale is impossible (and invisible); direction and ordering are
;; truthful, and the inspector reports the real distance and light-time.
;; Sun/Moon/planets are computed locally (cmacs-gnuseye-ephem, no network);
;; probes and asteroids come from JPL Horizons (keyless), refreshed slowly.

;;; Code:

(require 'cmacs-gnuseye)
(require 'cmacs-gnuseye-ephem)

;;;; Celestial shell ----------------------------------------------------------

(defconst cmacs-gnuseye-celestial-au-scale 290.0
  "World units per astronomical unit for the solar-system chart.
Distances are LINEAR (one uniform scale), so all relative geometry is
exactly true: Jupiter really is ~5.2x as far from the Sun as Earth is.")

(defun cmacs-gnuseye-celestial-shell-radius (dist-km)
  "World radius for a body DIST-KM from Earth: linearly true distance.
dist x 290 units/AU, with two documented exceptions: a floor of 26 (only
the Moon hits it -- its true scaled distance, 0.75, would sit inside the
Earth globe) and a 9000-unit chart edge (only deep-space probes hit it --
Voyager's true 49,000 would sit beyond the render horizon).  Every planet
is in the linear regime, so the orbital structure is exact."
  (max 26.0 (min 9000.0 (* cmacs-gnuseye-celestial-au-scale
                           (/ dist-km 149597870.7)))))

(defun cmacs-gnuseye-celestial-shell-alt (dist-km)
  "Chart altitude (:alt metres) for a body DIST-KM from Earth."
  ;; world_r = R*(1 + alt/Re)  =>  alt = (world_r/R - 1) * Re
  (* (- (/ (cmacs-gnuseye-celestial-shell-radius dist-km) 6.371) 1.0)
     6371000.0))

(defun cmacs-gnuseye-celestial--fmt-dist (dist-km)
  "Human distance string: km, with AU and light-time when far."
  (let ((au (/ dist-km 149597870.7))
        (lt-s (/ dist-km 299792.458)))
    (cond
     ((> au 0.1)
      (format "%.3f AU (%s)" au
              (cond ((> lt-s 3600) (format "%.1f light-hours" (/ lt-s 3600)))
                    ((> lt-s 60) (format "%.1f light-minutes" (/ lt-s 60)))
                    (t (format "%.0f light-seconds" lt-s)))))
     (t (format "%s km (%.1f light-seconds)"
                (let ((k (round dist-km)))
                  (if (> k 10000)
                      (format "%d,%03d" (/ k 1000) (mod k 1000))
                    (number-to-string k)))
                lt-s)))))

;;;; Sun + Moon + planets (local ephemeris; always live) ----------------------

(defconst cmacs-gnuseye-celestial--bodies
  ;; (BODY KIND LABEL COLOR RADIUS-RATIO) -- RADIUS-RATIO is the body's TRUE
  ;; radius relative to Earth (the Sun's real 109.2 included: no caps).
  '((sun     sun    "Sun"     "#ffd96a" 109.2)
    (moon    moon   "Moon"    "#cfd2d6" 0.273)
    (mercury planet "Mercury" "#b3a08a" 0.383)
    (venus   planet "Venus"   "#f2e3c0" 0.950)
    (mars    planet "Mars"    "#e07a4f" 0.532)
    (jupiter planet "Jupiter" "#e0bc8f" 10.97)
    (saturn  planet "Saturn"  "#e8d8a8" 9.14)
    (uranus  planet "Uranus"  "#9adfe0" 3.98)
    (neptune planet "Neptune" "#7aa8ff" 3.87))
  "The locally-computed bodies and their true Earth-relative radii.")

(defun cmacs-gnuseye-celestial--ratio->scale (ratio)
  "Marker :scale rendering a body of true radius RATIO x Earth.
One sqrt size law for every body (the Sun included -- no arbitrary caps):
rendered radius = 6.371 * sqrt(RATIO), so size ORDER and the dominance
hierarchy are exact while a 109x Sun does not engulf the chart: the Sun
renders 10.4x Earth and 3.2x Jupiter; Venus ~ Earth; the Moon ~ half.
The C sphere radius is 0.9 * 0.11 * scale = 0.099 * scale world units."
  (/ (* (sqrt ratio) 6.371) 0.099))

(defun cmacs-gnuseye-celestial--body-entity (spec &optional time)
  "Entity plist for body SPEC ((BODY KIND LABEL COLOR RATIO)) at TIME."
  (pcase-let ((`(,body ,kind ,label ,color ,ratio) spec))
    (let ((p (cmacs-gnuseye-ephem-body body time)))
      (when p
        (let ((dist (plist-get p :dist-km)))
          (list :id (format "cel:%s" body)
                :kind kind :label label :color color
                :scale (cmacs-gnuseye-celestial--ratio->scale ratio)
                :lat (plist-get p :sublat) :lon (plist-get p :sublon)
                :alt (cmacs-gnuseye-celestial-shell-alt dist)
                :label-mode 3
                :data `((body . ,body)
                        (distance . ,(cmacs-gnuseye-celestial--fmt-dist dist))
                        (dist-km . ,dist)
                        (size . ,(format "true %.2fx Earth (drawn sqrt: %.1fx)"
                                         ratio (sqrt ratio)))
                        (sub-point . ,(format "%.2f, %.2f"
                                              (plist-get p :sublat)
                                              (plist-get p :sublon))))))))))

(defun cmacs-gnuseye-celestial--fetch (cb)
  (funcall cb (delq nil (mapcar #'cmacs-gnuseye-celestial--body-entity
                                cmacs-gnuseye-celestial--bodies))))

(defun cmacs-gnuseye-celestial--advance (entities _dt now)
  "Recompute every body's live position (they sweep with Earth's rotation)."
  (dolist (e entities)
    (let* ((body (cdr (assq 'body (plist-get e :data))))
           (spec (assq body cmacs-gnuseye-celestial--bodies))
           (fresh (and spec (cmacs-gnuseye-celestial--body-entity
                             spec (seconds-to-time now)))))
      (when fresh
        (plist-put e :lat (plist-get fresh :lat))
        (plist-put e :lon (plist-get fresh :lon))
        (plist-put e :alt (plist-get fresh :alt))))))

(cmacs-gnuseye-define-layer solar-system
  :title "Sun, Moon & planets"
  :group 'celestial
  :kind 'planet
  :interval 3600          ; positions self-update every tick via :advance
  :default-on nil
  :fetch #'cmacs-gnuseye-celestial--fetch
  :advance #'cmacs-gnuseye-celestial--advance)

;;;; Probes + asteroids (JPL Horizons; keyless) -------------------------------

(defcustom cmacs-gnuseye-probes
  '(("-31" "Voyager 1") ("-32" "Voyager 2")
    ("-98" "New Horizons") ("-170" "JWST"))
  "Deep-space probes to track: (HORIZONS-ID LABEL)."
  :type '(repeat (list string string))
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-asteroids
  '(("Apophis;" "Apophis") ("Ceres;" "Ceres")
    ("Bennu;" "Bennu") ("433;" "Eros"))
  "Asteroids to track: (HORIZONS-COMMAND LABEL).
A trailing ; tells Horizons to match small bodies."
  :type '(repeat (list string string))
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-celestial--horizons-url (command)
  (let* ((now (current-time))
         (start (format-time-string "%Y-%m-%d %H:%M" now t))
         (stop (format-time-string "%Y-%m-%d %H:%M"
                                   (time-add now (seconds-to-time 120)) t)))
    (concat "https://ssd.jpl.nasa.gov/api/horizons.api?format=json"
            "&COMMAND='" (url-hexify-string command) "'"
            "&OBJ_DATA=NO&MAKE_EPHEM=YES&EPHEM_TYPE=OBSERVER"
            "&CENTER='500@399'&QUANTITIES='1,20'&ANG_FORMAT=DEG"
            "&CSV_FORMAT=YES"
            "&START_TIME='" (url-hexify-string start) "'"
            "&STOP_TIME='" (url-hexify-string stop) "'"
            "&STEP_SIZE='2m'")))

(defun cmacs-gnuseye-celestial--horizons-parse (result)
  "Parse a Horizons OBSERVER CSV RESULT string -> (RA-DEG DEC-DEG DELTA-AU).
Reads the first data row between $$SOE and $$EOE."
  (when (and (stringp result) (string-match "\\$\\$SOE\n\\([^\n]+\\)" result))
    (let* ((row (match-string 1 result))
           ;; Keep empty fields: columns are Date, solar-presence,
           ;; lunar-presence (often empty), RA, DEC, delta, deldot.
           (f (split-string row "," nil "[ \t]+")))
      (when (>= (length f) 6)
        (list (string-to-number (nth 3 f))
              (string-to-number (nth 4 f))
              (string-to-number (nth 5 f)))))))

(defun cmacs-gnuseye-celestial--horizons-entity (id label kind radec)
  "Entity for Horizons body ID/LABEL of KIND from RADEC (RA DEC DELTA-AU).
RA/Dec are stored in :data so the :advance hook can re-derive the sub-point
as Earth rotates (the sub-longitude moves ~15 deg/hour)."
  (pcase-let ((`(,ra ,dec ,delta) radec))
    (let* ((now (float-time))
           (dist-km (* delta 149597870.7))
           (sublon (- (mod (+ (- ra (cmacs-gnuseye-ephem-gmst now)) 540.0)
                           360.0)
                      180.0)))
      (list :id (format "cel:%s" id)
            :kind kind :label label
            :color (if (eq kind 'probe) "#7ad7ff" "#b9b3a8")
            :scale (if (eq kind 'probe) 5.0 4.0)
            :lat dec :lon sublon
            :alt (cmacs-gnuseye-celestial-shell-alt dist-km)
            :label-mode 3
            :data `((horizons-id . ,id)
                    (ra . ,ra) (dec . ,dec)
                    (distance . ,(cmacs-gnuseye-celestial--fmt-dist dist-km))
                    (dist-km . ,dist-km))))))

(defun cmacs-gnuseye-celestial--horizons-advance (entities _dt now)
  "Sweep Horizons bodies with Earth's rotation between (slow) refetches:
their RA/Dec is essentially fixed over hours, but the sub-longitude is
RA - GMST and moves ~15 deg/hour."
  (let ((gmst (cmacs-gnuseye-ephem-gmst now)))
    (dolist (e entities)
      (let ((ra (cdr (assq 'ra (plist-get e :data)))))
        (when (numberp ra)
          (plist-put e :lon (- (mod (+ (- ra gmst) 540.0) 360.0) 180.0)))))))

(defun cmacs-gnuseye-celestial--horizons-fetch (bodies kind cb)
  "Fetch every (ID LABEL) in BODIES from Horizons; CB gets the entity list."
  (let ((pending (length bodies)) (acc nil))
    (if (zerop pending)
        (funcall cb nil)
      (dolist (b bodies)
        (cmacs-gnuseye-fetch-json
         (cmacs-gnuseye-celestial--horizons-url (nth 0 b))
         (lambda (data)
           (let* ((res (and data (alist-get 'result data)))
                  (radec (and res (cmacs-gnuseye-celestial--horizons-parse res))))
             (when radec
               (push (cmacs-gnuseye-celestial--horizons-entity
                      (nth 0 b) (nth 1 b) kind radec)
                     acc)))
           (when (zerop (setq pending (1- pending)))
             (funcall cb (nreverse acc)))))))))

(cmacs-gnuseye-define-layer probes
  :title "Deep-space probes (Horizons)"
  :group 'celestial
  :kind 'probe
  :interval 21600
  :default-on nil
  :fetch (lambda (cb)
           (cmacs-gnuseye-celestial--horizons-fetch
            cmacs-gnuseye-probes 'probe cb))
  :advance #'cmacs-gnuseye-celestial--horizons-advance)

(cmacs-gnuseye-define-layer asteroids
  :title "Asteroids (Horizons)"
  :group 'celestial
  :kind 'asteroid
  :interval 21600
  :default-on nil
  :fetch (lambda (cb)
           (cmacs-gnuseye-celestial--horizons-fetch
            cmacs-gnuseye-asteroids 'asteroid cb))
  :advance #'cmacs-gnuseye-celestial--horizons-advance)

(provide 'cmacs-gnuseye-celestial)
;;; cmacs-gnuseye-celestial.el ends here
