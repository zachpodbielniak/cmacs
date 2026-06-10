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

(defun cmacs-gnuseye-celestial-shell-alt (dist-km)
  "Compressed shell altitude (:alt metres) for a body DIST-KM away.
Maps the body's true distance to a world radius in [12, 74] via
20 + 10*log10(dist_km/1e5), then to the :alt that places a marker there."
  (let* ((wr (max 12.0 (min 74.0 (+ 20.0 (* 10.0 (log (max 1.0 (/ dist-km 1e5))
                                                      10))))))
         ;; world_r = R*(1 + alt/Re)  =>  alt = (world_r/R - 1) * Re
         (alt (* (- (/ wr 6.371) 1.0) 6371000.0)))
    alt))

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
  ;; (BODY KIND LABEL COLOR SCALE) -- scales tuned for apparent size at each
  ;; body's shell distance: the Sun unmistakably dominant, gas giants larger
  ;; than rocky planets, the (near-shell) Moon naturally big in the sky.
  '((sun     sun    "Sun"     "#ffd96a" 40.0)
    (moon    moon   "Moon"    "#cfd2d6" 12.0)
    (mercury planet "Mercury" "#b3a08a" 6.0)
    (venus   planet "Venus"   "#f2e3c0" 9.0)
    (mars    planet "Mars"    "#e07a4f" 8.0)
    (jupiter planet "Jupiter" "#e0bc8f" 16.0)
    (saturn  planet "Saturn"  "#e8d8a8" 14.0)
    (uranus  planet "Uranus"  "#9adfe0" 11.0)
    (neptune planet "Neptune" "#7aa8ff" 11.0))
  "The locally-computed bodies and their marker styles.")

(defun cmacs-gnuseye-celestial--body-entity (spec &optional time)
  "Entity plist for body SPEC ((BODY KIND LABEL COLOR SCALE)) at TIME."
  (pcase-let ((`(,body ,kind ,label ,color ,scale) spec))
    (let ((p (cmacs-gnuseye-ephem-body body time)))
      (when p
        (let ((dist (plist-get p :dist-km)))
          (list :id (format "cel:%s" body)
                :kind kind :label label :color color :scale scale
                :lat (plist-get p :sublat) :lon (plist-get p :sublon)
                :alt (cmacs-gnuseye-celestial-shell-alt dist)
                :label-mode 3
                :data `((body . ,body)
                        (distance . ,(cmacs-gnuseye-celestial--fmt-dist dist))
                        (dist-km . ,dist)
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
