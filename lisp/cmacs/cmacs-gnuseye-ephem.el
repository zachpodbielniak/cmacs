;;; cmacs-gnuseye-ephem.el --- GNU's Eye solar-system ephemerides  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Local (no-network, always-current) geocentric positions of the Sun, the
;; Moon, and the planets:
;;
;;   - Planets + Sun: JPL/Standish "Approximate Positions of the Planets"
;;     Keplerian elements + per-century rates (valid 1800-2050; arcminute
;;     class) -> heliocentric J2000 ecliptic -> geocentric.
;;   - Moon: the Astronomical Almanac low-precision series (~0.3 deg).
;;
;; The result is delivered as the body's SUB-POINT -- the (lat, lon) on Earth
;; it is directly above (lat = declination, lon = RA - GMST, east positive) --
;; plus its true distance, which is exactly what the globe needs to place a
;; marker in the body's real direction.

;;; Code:

(defconst cmacs-gnuseye-ephem--d2r (/ float-pi 180.0))
(defconst cmacs-gnuseye-ephem--au-km 149597870.7)

(defun cmacs-gnuseye-ephem--norm360 (x)
  (mod x 360.0))

(defun cmacs-gnuseye-ephem--norm180 (x)
  (- (mod (+ x 540.0) 360.0) 180.0))

(defun cmacs-gnuseye-ephem--jd (unix-s)
  "Julian date for Unix time UNIX-S."
  (+ (/ unix-s 86400.0) 2440587.5))

(defun cmacs-gnuseye-ephem-gmst (unix-s)
  "Greenwich Mean Sidereal Time in degrees at Unix time UNIX-S.
Same series as the C gmst_rad in cmacs-gnuseye-sgp4.c."
  (let* ((d (- (cmacs-gnuseye-ephem--jd unix-s) 2451545.0))
         (tc (/ d 36525.0))
         (g (+ 280.46061837 (* 360.98564736629 d)
               (* 0.000387933 tc tc) (- (/ (* tc tc tc) 38710000.0)))))
    (cmacs-gnuseye-ephem--norm360 g)))

(defun cmacs-gnuseye-ephem--obliquity (tc)
  "Mean obliquity of the ecliptic (degrees) at TC Julian centuries from J2000."
  (- 23.439291 (* 0.0130042 tc)))

;; JPL/Standish approximate Keplerian elements, J2000 ecliptic, 1800-2050 AD.
;; Per body: (a e I L peri node) at epoch + the same six per-century rates.
;; a in AU, angles in degrees; L = mean longitude, peri = longitude of
;; perihelion, node = longitude of ascending node.
(defconst cmacs-gnuseye-ephem--elements
  '((mercury (0.38709927 0.20563593 7.00497902 252.25032350 77.45779628 48.33076593)
             (0.00000037 0.00001906 -0.00594749 149472.67411175 0.16047689 -0.12534081))
    (venus   (0.72333566 0.00677672 3.39467605 181.97909950 131.60246718 76.67984255)
             (0.00000390 -0.00004107 -0.00078890 58517.81538729 0.00268329 -0.27769418))
    (earth   (1.00000261 0.01671123 -0.00001531 100.46457166 102.93768193 0.0)
             (0.00000562 -0.00004392 -0.01294668 35999.37244981 0.32327364 0.0))
    (mars    (1.52371034 0.09339410 1.84969142 -4.55343205 -23.94362959 49.55953891)
             (0.00001847 0.00007882 -0.00813131 19140.30268499 0.44441088 -0.29257343))
    (jupiter (5.20288700 0.04838624 1.30439695 34.39644051 14.72847983 100.47390909)
             (-0.00011607 -0.00013253 -0.00183714 3034.74612775 0.21252668 0.20469106))
    (saturn  (9.53667594 0.05386179 2.48599187 49.95424423 92.59887831 113.66242448)
             (-0.00125060 -0.00050991 0.00193609 1222.49362201 -0.41897216 -0.28867794))
    (uranus  (19.18916464 0.04725744 0.77263783 313.23810451 170.95427630 74.01692503)
             (-0.00196176 -0.00004397 -0.00242939 428.48202785 0.40805281 0.04240589))
    (neptune (30.06992276 0.00859048 1.77004347 -55.12002969 44.96476227 131.78422574)
             (0.00026291 0.00005105 0.00035372 218.45945325 -0.32241464 -0.00508664)))
  "Standish approximate planetary elements (epoch J2000 + rates/century).")

(defun cmacs-gnuseye-ephem--kepler (m-deg e)
  "Solve Kepler's equation: eccentric anomaly (deg) for mean anomaly M-DEG."
  (let* ((estar (* 57.29577951308232 e))
         (m (cmacs-gnuseye-ephem--norm180 m-deg))
         (en (+ m (* estar (sin (* m cmacs-gnuseye-ephem--d2r))))))
    (dotimes (_ 8)
      (let* ((er (* en cmacs-gnuseye-ephem--d2r))
             (dm (- m (- en (* estar (sin er)))))
             (de (/ dm (- 1.0 (* e (cos er))))))
        (setq en (+ en de))))
    en))

(defun cmacs-gnuseye-ephem--helio-xyz (body tc)
  "Heliocentric J2000-ecliptic (X Y Z) in AU for BODY at TC centuries."
  (let* ((row (alist-get body cmacs-gnuseye-ephem--elements))
         (e0 (nth 0 row)) (er (nth 1 row))
         (a    (+ (nth 0 e0) (* (nth 0 er) tc)))
         (ecc  (+ (nth 1 e0) (* (nth 1 er) tc)))
         (inc  (* (+ (nth 2 e0) (* (nth 2 er) tc)) cmacs-gnuseye-ephem--d2r))
         (ll   (+ (nth 3 e0) (* (nth 3 er) tc)))
         (peri (+ (nth 4 e0) (* (nth 4 er) tc)))
         (node (+ (nth 5 e0) (* (nth 5 er) tc)))
         (m (- ll peri))
         (w (* (- peri node) cmacs-gnuseye-ephem--d2r))
         (om (* node cmacs-gnuseye-ephem--d2r))
         (eanom (* (cmacs-gnuseye-ephem--kepler m ecc)
                   cmacs-gnuseye-ephem--d2r))
         (xp (* a (- (cos eanom) ecc)))
         (yp (* a (sqrt (- 1.0 (* ecc ecc))) (sin eanom)))
         (cw (cos w)) (sw (sin w)) (co (cos om)) (so (sin om))
         (ci (cos inc)) (si (sin inc)))
    (list (+ (* (- (* cw co) (* sw so ci)) xp)
             (* (- (- (* sw co)) (* cw so ci)) yp))
          (+ (* (+ (* cw so) (* sw co ci)) xp)
             (* (- (* cw co ci) (* sw so)) yp))
          (+ (* sw si xp) (* cw si yp)))))

(defun cmacs-gnuseye-ephem--ecl->subpoint (x y z unix-s)
  "Geocentric ecliptic (X Y Z) in AU -> (:sublat :sublon :dist-km).
Rotates to the equatorial frame, takes declination + right ascension, and
converts RA to an east-positive sub-longitude via GMST."
  (let* ((tc (/ (- (cmacs-gnuseye-ephem--jd unix-s) 2451545.0) 36525.0))
         (eps (* (cmacs-gnuseye-ephem--obliquity tc) cmacs-gnuseye-ephem--d2r))
         (xe x)
         (ye (- (* y (cos eps)) (* z (sin eps))))
         (ze (+ (* y (sin eps)) (* z (cos eps))))
         (r (sqrt (+ (* xe xe) (* ye ye) (* ze ze))))
         (dec (/ (asin (/ ze (max 1e-12 r))) cmacs-gnuseye-ephem--d2r))
         (ra (/ (atan ye xe) cmacs-gnuseye-ephem--d2r))
         (sublon (cmacs-gnuseye-ephem--norm180
                  (- ra (cmacs-gnuseye-ephem-gmst unix-s)))))
    (list :sublat dec :sublon sublon
          :dist-km (* r cmacs-gnuseye-ephem--au-km))))

(defun cmacs-gnuseye-ephem--moon (unix-s)
  "Low-precision geocentric Moon (Astronomical Almanac series, ~0.3 deg)."
  (let* ((tc (/ (- (cmacs-gnuseye-ephem--jd unix-s) 2451545.0) 36525.0))
         (d2r cmacs-gnuseye-ephem--d2r)
         (s (lambda (a b) (sin (* (+ a (* b tc)) d2r))))
         (c (lambda (a b) (cos (* (+ a (* b tc)) d2r))))
         (lam (+ 218.32 (* 481267.881 tc)
                 (* 6.29 (funcall s 135.0 477198.87))
                 (* -1.27 (funcall s 259.3 -413335.36))
                 (* 0.66 (funcall s 235.7 890534.22))
                 (* 0.21 (funcall s 269.9 954397.74))
                 (* -0.19 (funcall s 357.5 35999.05))
                 (* -0.11 (funcall s 186.5 966404.03))))
         (beta (+ (* 5.13 (funcall s 93.3 483202.02))
                  (* 0.28 (funcall s 228.2 960400.89))
                  (* -0.28 (funcall s 318.3 6003.15))
                  (* -0.17 (funcall s 217.6 -407332.21))))
         (par (+ 0.9508
                 (* 0.0518 (funcall c 135.0 477198.87))
                 (* 0.0095 (funcall c 259.3 -413335.36))
                 (* 0.0078 (funcall c 235.7 890534.22))
                 (* 0.0028 (funcall c 269.9 954397.74))))
         (dist-km (/ 6378.14 (sin (* par d2r))))
         (lamr (* lam d2r)) (betar (* beta d2r))
         ;; unit ecliptic vector scaled to AU so the shared conversion works
         (r-au (/ dist-km cmacs-gnuseye-ephem--au-km))
         (x (* r-au (cos betar) (cos lamr)))
         (y (* r-au (cos betar) (sin lamr)))
         (z (* r-au (sin betar))))
    (cmacs-gnuseye-ephem--ecl->subpoint x y z unix-s)))

;;;###autoload
(defun cmacs-gnuseye-ephem-body (body &optional time)
  "Geocentric sub-point of BODY at TIME (default: now).
BODY is one of `sun', `moon', `mercury', `venus', `mars', `jupiter',
`saturn', `uranus', `neptune'.  Returns (:sublat LAT :sublon LON
:dist-km KM): the body is directly above (LAT, LON) at distance KM."
  (let* ((unix-s (if time (float-time time) (float-time)))
         (tc (/ (- (cmacs-gnuseye-ephem--jd unix-s) 2451545.0) 36525.0)))
    (cond
     ((eq body 'moon) (cmacs-gnuseye-ephem--moon unix-s))
     ((eq body 'sun)
      (let ((e (cmacs-gnuseye-ephem--helio-xyz 'earth tc)))
        (cmacs-gnuseye-ephem--ecl->subpoint
         (- (nth 0 e)) (- (nth 1 e)) (- (nth 2 e)) unix-s)))
     ((alist-get body cmacs-gnuseye-ephem--elements)
      (let ((p (cmacs-gnuseye-ephem--helio-xyz body tc))
            (e (cmacs-gnuseye-ephem--helio-xyz 'earth tc)))
        (cmacs-gnuseye-ephem--ecl->subpoint
         (- (nth 0 p) (nth 0 e)) (- (nth 1 p) (nth 1 e))
         (- (nth 2 p) (nth 2 e)) unix-s)))
     (t nil))))

(provide 'cmacs-gnuseye-ephem)
;;; cmacs-gnuseye-ephem.el ends here
