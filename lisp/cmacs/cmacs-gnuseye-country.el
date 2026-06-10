;;; cmacs-gnuseye-country.el --- GNU's Eye country details on click  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Click a country on the globe (not on a marker) and the inspector shows its
;; properties: population, GDP, GDP per capita, unemployment, life expectancy,
;; inflation, income group, continent.  Instant figures come from the cached
;; Natural Earth admin-0 attributes; live indicators are fetched keylessly
;; from the World Bank API (latest non-empty value per indicator) and cached
;; to disk.  Clicking the ocean keeps the old behaviour (deselect).

;;; Code:

(require 'cmacs-gnuseye)

;;;; Country polygon index (point-in-country) ---------------------------------

(defvar cmacs-gnuseye-country--index nil
  "List of (ISO NAME PROPS BBOX RINGS); RINGS = list of (LON . LAT) lists.")
(defvar cmacs-gnuseye-country--loading nil)

(defun cmacs-gnuseye-country--rings (geom)
  "All rings of a GeoJSON Polygon/MultiPolygon GEOM as (LON LAT) lists."
  (let ((gt (alist-get 'type geom))
        (coords (alist-get 'coordinates geom)))
    (cond
     ((equal gt "Polygon") coords)
     ((equal gt "MultiPolygon") (apply #'append coords))
     (t nil))))

(defun cmacs-gnuseye-country--load ()
  "Build the country polygon index from the cached Natural Earth admin-0."
  (unless (or cmacs-gnuseye-country--index cmacs-gnuseye-country--loading)
    (setq cmacs-gnuseye-country--loading t)
    (cmacs-gnuseye--geojson
     "ne_110m_admin_0_countries.geojson"
     (lambda (d)
       (let (idx)
         (dolist (f (alist-get 'features d))
           (let* ((props (alist-get 'properties f))
                  (iso (cmacs-gnuseye--choropleth-iso props))
                  (name (or (alist-get 'NAME props) (alist-get 'ADMIN props)
                            iso))
                  (rings (cmacs-gnuseye-country--rings (alist-get 'geometry f))))
             (when rings
               (let ((mnlo 1e9) (mxlo -1e9) (mnla 1e9) (mxla -1e9))
                 (dolist (ring rings)
                   (dolist (p ring)
                     (let ((lo (nth 0 p)) (la (nth 1 p)))
                       (when (< lo mnlo) (setq mnlo lo))
                       (when (> lo mxlo) (setq mxlo lo))
                       (when (< la mnla) (setq mnla la))
                       (when (> la mxla) (setq mxla la)))))
                 (push (list iso (format "%s" name) props
                             (list mnlo mxlo mnla mxla) rings)
                       idx)))))
         (setq cmacs-gnuseye-country--index (nreverse idx)
               cmacs-gnuseye-country--loading nil))))))

(defun cmacs-gnuseye-country--pip (lat lon rings)
  "Even-odd point-in-polygon: is (LAT LON) inside RINGS?"
  (let ((inside nil))
    (dolist (ring rings)
      (let* ((n (length ring)) (j (1- n)) (i 0))
        (while (< i n)
          (let* ((pi_ (nth i ring)) (pj (nth j ring))
                 (xi (nth 0 pi_)) (yi (nth 1 pi_))
                 (xj (nth 0 pj)) (yj (nth 1 pj)))
            (when (and (not (eq (> yi lat) (> yj lat)))
                       (< lon (+ xi (/ (* (- xj xi) (- lat yi))
                                       (- yj yi)))))
              (setq inside (not inside))))
          (setq j i i (1+ i)))))
    inside))

(defun cmacs-gnuseye-country-at (lat lon)
  "Return the country index entry containing (LAT LON), or nil (ocean)."
  (seq-find (lambda (c)
              (pcase-let ((`(,_ ,_ ,_ (,mnlo ,mxlo ,mnla ,mxla) ,rings) c))
                (and (>= lon (- mnlo 0.01)) (<= lon (+ mxlo 0.01))
                     (>= lat (- mnla 0.01)) (<= lat (+ mxla 0.01))
                     (cmacs-gnuseye-country--pip lat lon rings))))
            cmacs-gnuseye-country--index))

;;;; World Bank live indicators (keyless, cached) -----------------------------

(defconst cmacs-gnuseye-country--indicators
  '(("SP.POP.TOTL"    . "population")
    ("NY.GDP.MKTP.CD" . "GDP (US$)")
    ("NY.GDP.PCAP.CD" . "GDP / capita")
    ("SL.UEM.TOTL.ZS" . "unemployment %")
    ("SP.DYN.LE00.IN" . "life expectancy")
    ("FP.CPI.TOTL.ZG" . "inflation %"))
  "World Bank indicator codes shown in the country inspector.")

(defvar cmacs-gnuseye-country--wb (make-hash-table :test 'equal)
  "ISO -> alist of (LABEL . \"VALUE (YEAR)\") fetched from the World Bank.")

(defun cmacs-gnuseye-country--fmt-num (v)
  "Format V with thousands grouping (and trim giant magnitudes)."
  (cond
   ((not (numberp v)) (format "%s" v))
   ((>= v 1e12) (format "%.2f trillion" (/ v 1e12)))
   ((>= v 1e9) (format "%.2f billion" (/ v 1e9)))
   ((>= v 1e6) (format "%.2f million" (/ v 1e6)))
   ((integerp v) (number-to-string v))
   (t (format "%.1f" v))))

(defun cmacs-gnuseye-country--wb-fetch (iso done)
  "Fetch the World Bank indicators for ISO; call DONE when all arrived."
  (let ((pending (length cmacs-gnuseye-country--indicators)) (acc nil))
    (dolist (ind cmacs-gnuseye-country--indicators)
      (cmacs-gnuseye-fetch-json
       (format (concat "https://api.worldbank.org/v2/country/%s/indicator/"
                       "%s?format=json&mrnev=1&per_page=1")
               iso (car ind))
       (lambda (data)
         (let* ((row (car (and (listp data) (nth 1 data))))
                (val (and row (alist-get 'value row)))
                (year (and row (alist-get 'date row))))
           (when (numberp val)
             (push (cons (cdr ind)
                         (format "%s (%s)"
                                 (cmacs-gnuseye-country--fmt-num val) year))
                   acc)))
         (when (zerop (setq pending (1- pending)))
           (puthash iso (nreverse acc) cmacs-gnuseye-country--wb)
           (funcall done)))
       nil 'list))))

;;;; Inspector display ---------------------------------------------------------

(defvar cmacs-gnuseye-country--current nil "ISO of the country being shown.")

(defun cmacs-gnuseye-country--entity (c)
  "Pseudo-entity plist for country index entry C, for the inspector."
  (pcase-let ((`(,iso ,name ,props ,_ ,_) c))
    (let* ((wb (gethash iso cmacs-gnuseye-country--wb))
           (pop (alist-get 'POP_EST props))
           (gdp-md (or (alist-get 'GDP_MD props) (alist-get 'GDP_MD_EST props)))
           (rows
            (append
             wb
             (unless (assoc "population" wb)
               (and pop `(("population (est)"
                           . ,(cmacs-gnuseye-country--fmt-num pop)))))
             (unless (assoc "GDP (US$)" wb)
               (and gdp-md `(("GDP (est)"
                              . ,(format "%s US$"
                                         (cmacs-gnuseye-country--fmt-num
                                          (* gdp-md 1e6)))))))
             (let ((inc (alist-get 'INCOME_GRP props))
                   (eco (alist-get 'ECONOMY props))
                   (cont (alist-get 'CONTINENT props))
                   (sub (alist-get 'SUBREGION props)))
               (delq nil
                     (list (and inc (cons "income group" inc))
                           (and eco (cons "economy" eco))
                           (and cont (cons "continent" cont))
                           (and sub (cons "subregion" sub)))))
             (unless wb '(("live data" . "fetching World Bank…"))))))
      (list :id (format "country:%s" iso)
            :kind 'country :label name
            :data (mapcar (lambda (kv) (cons (intern (car kv)) (cdr kv)))
                          rows)))))

(defun cmacs-gnuseye-country-show (c)
  "Show country index entry C in the inspector (+ async World Bank enrich)."
  (let ((iso (nth 0 c)))
    (setq cmacs-gnuseye-country--current iso
          cmacs-gnuseye--selected-id nil)
    (cmacs-gnuseye--show-inspector (cmacs-gnuseye-country--entity c))
    (unless (gethash iso cmacs-gnuseye-country--wb)
      (cmacs-gnuseye-country--wb-fetch
       iso
       (lambda ()
         ;; Refresh only if this country is still the one on display.
         (when (equal cmacs-gnuseye-country--current iso)
           (cmacs-gnuseye--show-inspector
            (cmacs-gnuseye-country--entity c))))))))

;;;; Click hook ----------------------------------------------------------------

(defun cmacs-gnuseye-country--click (buffer node-id vx vy)
  "Empty-globe clicks on land show that country's details (consumes the
click); marker clicks and ocean clicks pass through."
  (when (and (integerp node-id) (< node-id 0)
             (numberp vx) (numberp vy)
             cmacs-gnuseye-country--index
             (not (and (fboundp 'cmacs-gnuseye-flat-p)
                       (cmacs-gnuseye-flat-p buffer))))
    (let* ((ll (ignore-errors (cmacs-gnuseye-screen-to-globe buffer vx vy)))
           (c (and ll (cmacs-gnuseye-country-at (nth 0 ll) (nth 1 ll)))))
      (when c
        (cmacs-gnuseye-country-show c)
        t))))

(add-hook 'cmacs-gnuseye--click-functions #'cmacs-gnuseye-country--click)
;; Build the polygon index up front (the GeoJSON is already disk-cached by
;; the map loader, so this is instant after the first session).
(cmacs-gnuseye-country--load)

(provide 'cmacs-gnuseye-country)
;;; cmacs-gnuseye-country.el ends here
