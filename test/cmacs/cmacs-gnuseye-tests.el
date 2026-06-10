;;; cmacs-gnuseye-tests.el --- ERT for cmacs-gnuseye  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Pure-logic tests for GNU's Eye: geodesy, two-body satellite propagation,
;; entity normalisation, and the layer registry.  Live-feed and GL render
;; paths are not exercised here (they need network / a display).

;;; Code:

(require 'ert)
(require 'cmacs)
(when (cmacs-feature-p 'gnuseye)
  (require 'cmacs-gnuseye))

(defmacro cmacs-gnuseye-tests--skip ()
  '(skip-unless (cmacs-feature-p 'gnuseye)))

(ert-deftest cmacs-gnuseye--supported ()
  (cmacs-gnuseye-tests--skip)
  (should (cmacs-gnuseye-supported-p)))

;;;; Geodesy -----------------------------------------------------------------

(ert-deftest cmacs-gnuseye--latlon-axes ()
  "Equator/prime-meridian on +X, north pole on +Y, east toward -Z so the
globe is not east-west mirrored."
  (cmacs-gnuseye-tests--skip)
  (let ((o (cmacs-gnuseye-latlon-to-xyz 0 0))
        (np (cmacs-gnuseye-latlon-to-xyz 90 0))
        (e (cmacs-gnuseye-latlon-to-xyz 0 90)))
    (should (< (abs (- (aref o 0) 6.371)) 1e-3))
    (should (< (abs (aref o 1)) 1e-3))
    (should (< (abs (- (aref np 1) 6.371)) 1e-3))
    (should (< (abs (- (aref e 2) -6.371)) 1e-3))))

(ert-deftest cmacs-gnuseye--latlon-roundtrip ()
  (cmacs-gnuseye-tests--skip)
  (let* ((v (cmacs-gnuseye-latlon-to-xyz 37.6 -122.4 400000.0))
         (b (cmacs-gnuseye-xyz-to-latlon (aref v 0) (aref v 1) (aref v 2))))
    (should (< (abs (- (nth 0 b) 37.6)) 1e-3))
    (should (< (abs (- (nth 1 b) -122.4)) 1e-3))
    (should (< (abs (- (nth 2 b) 400000.0)) 1.0))))

(ert-deftest cmacs-gnuseye--haversine-bearing ()
  (cmacs-gnuseye-tests--skip)
  ;; One degree of longitude at the equator ~ 111.195 km.
  (should (< (abs (- (cmacs-gnuseye-haversine 0 0 0 1) 111195.0)) 50.0))
  (should (< (abs (- (cmacs-gnuseye-bearing 0 0 1 0) 0.0)) 1e-3))   ; north
  (should (< (abs (- (cmacs-gnuseye-bearing 0 0 0 1) 90.0)) 1e-3))) ; east

(ert-deftest cmacs-gnuseye--great-circle ()
  (cmacs-gnuseye-tests--skip)
  (let ((gc (cmacs-gnuseye-great-circle 0 0 0 90 3)))
    (should (= (length gc) 3))
    (should (< (abs (- (aref (aref gc 1) 1) 45.0)) 1e-3))))

;;;; Satellite propagation ---------------------------------------------------

(ert-deftest cmacs-gnuseye--iss-orbit ()
  "Parse + propagate an ISS TLE; check inclination and altitude sanity."
  (cmacs-gnuseye-tests--skip)
  (let* ((l1 "1 25544U 98067A   24001.50000000  .00016717  00000-0  10270-3 0  9005")
         (l2 "2 25544  51.6400 208.9163 0006317  69.9862 290.1614 15.49401520 10000")
         (el (cmacs-gnuseye-tle-parse l1 l2)))
    (should (vectorp el))
    (should (< (abs (- (* (aref el 2) (/ 180.0 float-pi)) 51.64)) 0.05))
    (let* ((pos (cmacs-gnuseye-sat-propagate el (aref el 1)))
           (alt-km (/ (nth 2 pos) 1000.0)))
      (should (and (> alt-km 380) (< alt-km 450)))
      (should (and (>= (nth 0 pos) -90) (<= (nth 0 pos) 90)))
      (should (and (>= (nth 1 pos) -180) (<= (nth 1 pos) 180))))
    (should (= (length (cmacs-gnuseye-sat-track el (aref el 1) 60 5)) 5))))

;;;; Entity normalisation + registry -----------------------------------------

(ert-deftest cmacs-gnuseye--color->rgba ()
  (cmacs-gnuseye-tests--skip)
  (should (= (cmacs-gnuseye--color->rgba "#ffd24a") #xffd24aff))
  (should (= (cmacs-gnuseye--color->rgba "#000000" 128) #x00000080)))

(ert-deftest cmacs-gnuseye--normalize ()
  (cmacs-gnuseye-tests--skip)
  (let ((e (cmacs-gnuseye--normalize-entity
            (list :id 'A1 :lat 10 :lon 20 :kind 'aircraft :heading 90
                  :label "UAL1" :trail '((10 20 0) (11 21 0))))))
    (should (equal (plist-get e :id) "A1"))
    (should (= (plist-get e :kind) 2))        ; aircraft code
    (should (= (plist-get e :heading) 90.0))
    (should (vectorp (plist-get e :trail)))
    (should (= (length (plist-get e :trail)) 2))))

(ert-deftest cmacs-gnuseye--layer-registry ()
  (cmacs-gnuseye-tests--skip)
  (cmacs-gnuseye--load-layers)
  (should (gethash 'satellites cmacs-gnuseye--layers))
  (should (gethash 'aircraft cmacs-gnuseye--layers))
  (should (gethash 'quakes cmacs-gnuseye--layers))
  (let ((l (gethash 'satellites cmacs-gnuseye--layers)))
    (should (cmacs-gnuseye-layer-default-on l))
    (should (functionp (cmacs-gnuseye-layer-fetch l)))))

(ert-deftest cmacs-gnuseye--define-layer ()
  "Define a throwaway layer and confirm it registers."
  (cmacs-gnuseye-tests--skip)
  (cmacs-gnuseye-define-layer cmacs-gnuseye--test-layer
    :title "Test" :group 'test :kind 'generic
    :fetch (lambda (cb) (funcall cb nil)) :interval 99)
  (unwind-protect
      (let ((l (gethash 'cmacs-gnuseye--test-layer cmacs-gnuseye--layers)))
        (should l)
        (should (= (cmacs-gnuseye-layer-interval l) 99)))
    (remhash 'cmacs-gnuseye--test-layer cmacs-gnuseye--layers)))

;;;; Phase 0: polygons, lifecycle, categories --------------------------------

(ert-deftest cmacs-gnuseye--normalize-poly ()
  "A :polygon ring normalises to a vector of [LAT LON] vertices and rides
through entity normalisation."
  (cmacs-gnuseye-tests--skip)
  (let ((p (cmacs-gnuseye--normalize-poly '((10 20) (11 21) (12 22)))))
    (should (vectorp p))
    (should (= (length p) 3))
    (should (equal (aref (aref p 0) 0) 10.0)))
  ;; too few vertices => nil (not a polygon)
  (should (null (cmacs-gnuseye--normalize-poly '((1 2) (3 4)))))
  (let ((e (cmacs-gnuseye--normalize-entity
            (list :id 'Z :lat 0 :lon 0 :kind 'generic
                  :polygon '((0 0) (0 10) (10 10) (10 0))))))
    (should (vectorp (plist-get e :polygon)))
    (should (= (length (plist-get e :polygon)) 4))))

(ert-deftest cmacs-gnuseye--polygon-defuns ()
  "The filled-polygon and dynamic-sun primitives are present."
  (cmacs-gnuseye-tests--skip)
  (should (fboundp 'cmacs-gnuseye-add-polygon))
  (should (fboundp 'cmacs-gnuseye-clear-polygons))
  (should (fboundp 'cmacs-gnuseye-set-sun-time)))

(ert-deftest cmacs-gnuseye--layer-generation ()
  "Enabling and disabling a layer bumps its generation token (so a late
async fetch can be detected as stale) and clears its enabled flag."
  (cmacs-gnuseye-tests--skip)
  (cmacs-gnuseye-define-layer cmacs-gnuseye--gentest
    :title "Gen" :group 'test :kind 'generic
    :fetch (lambda (cb) (funcall cb nil)))
  (unwind-protect
      (let* ((l (gethash 'cmacs-gnuseye--gentest cmacs-gnuseye--layers))
             (g0 (cmacs-gnuseye-layer-generation l)))
        (cmacs-gnuseye--disable-layer l)
        (should (> (cmacs-gnuseye-layer-generation l) g0))
        (should-not (cmacs-gnuseye-layer-enabled l)))
    (remhash 'cmacs-gnuseye--gentest cmacs-gnuseye--layers)))

(ert-deftest cmacs-gnuseye--toggle-pane-groups ()
  "The toggle pane groups layers under collapsible category headers; a
collapsed category shows only its header, expanding reveals its layers."
  (cmacs-gnuseye-tests--skip)
  (cmacs-gnuseye-define-layer cmacs-gnuseye--cat-a
    :title "Cat A" :group 'natural :fetch (lambda (cb) (funcall cb nil)))
  (cmacs-gnuseye-define-layer cmacs-gnuseye--cat-b
    :title "Cat B" :group 'natural :fetch (lambda (cb) (funcall cb nil)))
  (unwind-protect
      (let ((cmacs-gnuseye--expanded-groups (make-hash-table :test 'eq)))
        ;; Collapsed: a (:group . natural) header exists, no layer rows for it.
        (let* ((rows (cmacs-gnuseye--layers-entries))
               (hdr (assoc '(:group . natural) rows)))
          (should hdr)
          (should-not (assq 'cmacs-gnuseye--cat-a rows)))
        ;; Expanded: the two layers now appear as rows.
        (puthash 'natural t cmacs-gnuseye--expanded-groups)
        (let ((rows (cmacs-gnuseye--layers-entries)))
          (should (assq 'cmacs-gnuseye--cat-a rows))
          (should (assq 'cmacs-gnuseye--cat-b rows))))
    (remhash 'cmacs-gnuseye--cat-a cmacs-gnuseye--layers)
    (remhash 'cmacs-gnuseye--cat-b cmacs-gnuseye--layers)))

;;;; Phase 1: rings, dead reckoning, clustering, choropleth ramp -------------

(ert-deftest cmacs-gnuseye--destination ()
  "Destination point: 111.195 km east of the equator ~ 1 deg of longitude."
  (cmacs-gnuseye-tests--skip)
  (let ((d (cmacs-gnuseye-destination 0 0 90 111195.0)))
    (should (< (abs (- (car d) 0.0)) 1e-3))      ; stays on the equator
    (should (< (abs (- (cdr d) 1.0)) 0.02))))    ; ~1 deg east

(ert-deftest cmacs-gnuseye--circle-points ()
  "A range ring is N equidistant points all RADIUS from the centre."
  (cmacs-gnuseye-tests--skip)
  (let* ((c (cmacs-gnuseye-circle-points 40 -100 200000.0 24)))
    (should (= (length c) 24))
    (dotimes (i 24)
      (let ((p (aref c i)))
        (should (< (abs (- (cmacs-gnuseye-haversine 40 -100 (aref p 0) (aref p 1))
                           200000.0))
                   2000.0))))))

(ert-deftest cmacs-gnuseye--dead-reckon ()
  "Dead reckoning moves north at the right rate and no-ops without motion."
  (cmacs-gnuseye-tests--skip)
  (let ((np (cmacs-gnuseye-dead-reckon 0 0 100.0 0 10.0)))   ; 100 m/s N, 10 s
    (should np)
    (should (> (car np) 0.0))                                ; moved north
    (should (< (abs (cdr np)) 1e-6)))                        ; same meridian
  (should (null (cmacs-gnuseye-dead-reckon 0 0 0 90 10)))    ; no speed
  (should (null (cmacs-gnuseye-dead-reckon 0 0 100 -1 10)))) ; no heading

(ert-deftest cmacs-gnuseye--risk-ramp ()
  "Risk ramp: 0 -> green-ish, 1 -> red-ish, alpha preserved."
  (cmacs-gnuseye-tests--skip)
  (let ((lo (cmacs-gnuseye--risk->rgba 0.0 90))
        (hi (cmacs-gnuseye--risk->rgba 1.0 90)))
    (should (= (logand lo #xff) 90))                 ; alpha
    (should (> (logand (ash lo -16) #xff) 200))      ; low risk: green high
    (should (> (logand (ash hi -24) #xff) 200))))    ; high risk: red high

(ert-deftest cmacs-gnuseye--clustering ()
  "Clustering collapses a dense cell to one count badge but keeps a lone
marker individual."
  (cmacs-gnuseye-tests--skip)
  (cmacs-gnuseye-define-layer cmacs-gnuseye--cltest
    :title "Cl" :group 'test :kind 'aircraft :cluster t
    :fetch (lambda (cb) (funcall cb nil)))
  (unwind-protect
      (let* ((layer (gethash 'cmacs-gnuseye--cltest cmacs-gnuseye--layers))
             ;; three markers in one 10-deg cell + one far away
             (ents (list (list :id "a" :lat 40.1 :lon -100.1)
                         (list :id "b" :lat 40.2 :lon -100.2)
                         (list :id "c" :lat 40.3 :lon -100.3)
                         (list :id "d" :lat -30.0 :lon 150.0)))
             (out (cmacs-gnuseye--cluster ents 10.0 layer))
             (badge (seq-find (lambda (e) (assq :cluster (plist-get e :data))) out)))
        (should (= (length out) 2))                 ; one badge + the lone one
        (should badge)
        (should (equal (plist-get badge :label) "3"))
        ;; A badge is a small count bubble tinted with the layer kind's
        ;; colour -- not the layer's icon (which zoom-scaled to a giant).
        (should (eq (plist-get badge :kind) 'cluster))
        (should (equal (plist-get badge :color) "#ffd24a"))  ; aircraft tint
        (should (< (plist-get badge :scale) 1.0)))
    (remhash 'cmacs-gnuseye--cltest cmacs-gnuseye--layers)))

;;;; Phase 2: keyless data-layer parsers -------------------------------------

(ert-deftest cmacs-gnuseye--eonet-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-natural)
  (let* ((data '((events
                  ((id . "E1") (title . "Volcano X")
                   (categories ((id . "volcanoes") (title . "Volcanoes")))
                   (geometry ((type . "Point") (date . "2026-01-01")
                              (coordinates 10.0 20.0)))))))
         (out (cmacs-gnuseye-eonet--parse data)))
    (should (= (length out) 1))
    (should (eq (plist-get (car out) :kind) 'volcano))
    (should (= (plist-get (car out) :lat) 20.0))   ; coords are (lon lat)
    (should (= (plist-get (car out) :lon) 10.0))))

(ert-deftest cmacs-gnuseye--nws-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-natural)
  (let* ((data '((features
                  ((properties (event . "Tornado Warning") (severity . "Extreme")
                               (areaDesc . "County") (id . "A1"))
                   (geometry (type . "Polygon")
                             (coordinates ((-100.0 40.0) (-99.0 40.0)
                                           (-99.0 41.0) (-100.0 41.0)
                                           (-100.0 40.0))))))))
         (out (cmacs-gnuseye-nws--parse data)))
    (should (= (length out) 1))
    (should (eq (plist-get (car out) :kind) 'alert))
    (should (vectorp (plist-get (car out) :polygon)))
    (should (>= (length (plist-get (car out) :polygon)) 4))))

(ert-deftest cmacs-gnuseye--aurora-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-space)
  (let* ((cmacs-gnuseye-aurora-step 1)
         (cmacs-gnuseye-aurora-threshold 25)
         (data '((coordinates (100.0 65.0 40) (200.0 70.0 10) (270.0 -60.0 50))))
         (out (cmacs-gnuseye-aurora--parse data)))
    (should (= (length out) 2))                    ; the 10% point is below thr
    (should (member -90.0 (mapcar (lambda (e) (plist-get e :lon)) out)))))

(ert-deftest cmacs-gnuseye--gdelt-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-conflict)
  (let* ((data '((features
                  ((geometry (type . "Point") (coordinates 30.0 50.0))
                   (properties (name . "Kyiv") (count . 12))))))
         (out (cmacs-gnuseye-gdelt--parse data)))
    (should (= (length out) 1))
    (should (equal (plist-get (car out) :label) "Kyiv"))
    (should (= (plist-get (car out) :lon) 30.0))))

;;;; Phase 3: wave-2 keyless layer parsers -----------------------------------

(ert-deftest cmacs-gnuseye--cables-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-infra)
  (let* ((data '((features
                  ((properties (name . "Cable A") (id . "c1"))
                   (geometry (type . "MultiLineString")
                             (coordinates ((0.0 0.0) (10.0 10.0) (20.0 20.0))))))))
         (out (cmacs-gnuseye-cables--parse data)))
    (should (= (length out) 1))
    (should (eq (plist-get (car out) :kind) 'cable))
    (should (listp (plist-get (car out) :trail)))
    (should (= (length (plist-get (car out) :trail)) 3))))

(ert-deftest cmacs-gnuseye--ports-layer ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-infra)
  (let (res)
    (cmacs-gnuseye-ports--fetch (lambda (e) (setq res e)))
    (should (> (length res) 10))
    (should (eq (plist-get (car res) :kind) 'port))))

(ert-deftest cmacs-gnuseye--radiation-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-health)
  (let* ((data '(((id . 1) (latitude . 37.5) (longitude . 140.0)
                  (value . 0.3) (unit . "usv"))
                 ((id . 2) (latitude . "x") (longitude . 1.0))))
         (out (cmacs-gnuseye-radiation--parse data)))
    (should (= (length out) 1))                ; the bad-lat row is skipped
    (should (eq (plist-get (car out) :kind) 'radiation))))

(ert-deftest cmacs-gnuseye--iss-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-media)
  (let* ((data '((latitude . 12.3) (longitude . -45.6) (altitude . 420.0)))
         (out (cmacs-gnuseye-iss--parse data)))
    (should (= (length out) 1))
    (should (eq (plist-get (car out) :kind) 'camera))
    (should (assq 'stream (plist-get (car out) :data)))))

;;;; Phase 4: interaction -----------------------------------------------------

(ert-deftest cmacs-gnuseye--search-data ()
  "List search matches across :data values, not just label/id/kind."
  (cmacs-gnuseye-tests--skip)
  (let ((e (list :id "x" :label "" :kind 'aircraft
                 :data '((registration . "N12345") (origin . "US")))))
    (let ((cmacs-gnuseye--search "n12345"))
      (should (cmacs-gnuseye--search-match-p e)))
    (let ((cmacs-gnuseye--search "zzz"))
      (should-not (cmacs-gnuseye--search-match-p e)))))

(ert-deftest cmacs-gnuseye--jump-candidates ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-search)
  (clrhash cmacs-gnuseye--id-index)
  (puthash "a1" (list :layer 'aircraft :id "a1" :kind 'aircraft :label "UAL1"
                      :lat 1 :lon 2 :data '((callsign . "UAL1")))
           cmacs-gnuseye--id-index)
  (let ((cands (cmacs-gnuseye--jump-candidates)))
    (should (cl-some (lambda (c) (equal (cdr c) '(:entity "a1"))) cands))
    (should (cl-some (lambda (c) (eq (car-safe (cdr c)) :place)) cands))
    (should (cl-some (lambda (c) (eq (car-safe (cdr c)) :command)) cands)))
  (clrhash cmacs-gnuseye--id-index))

(ert-deftest cmacs-gnuseye--geofence-enter ()
  "An entity inside the fence radius is recorded inside; outside is not."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-geofence)
  (clrhash cmacs-gnuseye--id-index)
  (clrhash cmacs-gnuseye--geofences)
  (puthash "in" (list :layer 'test :id "in" :kind 'ship :lat 26.6 :lon 56.3)
           cmacs-gnuseye--id-index)
  (puthash "out" (list :layer 'test :id "out" :kind 'ship :lat 0.0 :lon 0.0)
           cmacs-gnuseye--id-index)
  (cmacs-gnuseye-add-geofence "hormuz" 26.57 56.25 60.0)
  (setq cmacs-gnuseye--geofence-last 0.0)
  (cmacs-gnuseye--geofence-eval)
  (let ((g (gethash "hormuz" cmacs-gnuseye--geofences)))
    (should (gethash "in" (cmacs-gnuseye-geofence-inside g)))
    (should-not (gethash "out" (cmacs-gnuseye-geofence-inside g))))
  (clrhash cmacs-gnuseye--id-index)
  (clrhash cmacs-gnuseye--geofences))

;;;; Phase 5: intelligence ----------------------------------------------------

(ert-deftest cmacs-gnuseye--correlation-hotspot ()
  "Co-located signals of >=2 distinct kinds form one hotspot; a lone signal
does not."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-intel)
  (clrhash cmacs-gnuseye--id-index)
  (puthash "q" (list :layer 'weather :id "q" :kind 'quake :lat 35.0 :lon 45.0)
           cmacs-gnuseye--id-index)
  (puthash "f" (list :layer 'natural :id "f" :kind 'fire :lat 35.4 :lon 45.3)
           cmacs-gnuseye--id-index)
  (puthash "lone" (list :layer 'weather :id "lone" :kind 'quake :lat -10.0 :lon 80.0)
           cmacs-gnuseye--id-index)
  (let* ((cmacs-gnuseye-intel-cell-deg 3.0)
         (hs (cmacs-gnuseye-intel--compute-hotspots)))
    (should (= (length hs) 1))
    (should (eq (plist-get (car hs) :kind) 'hotspot)))
  (clrhash cmacs-gnuseye--id-index))

(ert-deftest cmacs-gnuseye--cii-scoring ()
  "Signals near a country centroid score that country in [0,1]."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-intel)
  (should (equal (cmacs-gnuseye-intel--nearest-country 32.0 53.0) "IRN"))
  (clrhash cmacs-gnuseye--id-index)
  (puthash "s1" (list :layer 'x :id "s1" :kind 'quake :lat 32.0 :lon 53.0)
           cmacs-gnuseye--id-index)
  (let ((scores (cmacs-gnuseye-intel--compute-cii)))
    (should (numberp (gethash "IRN" scores)))
    (should (<= 0.0 (gethash "IRN" scores) 1.0)))
  (clrhash cmacs-gnuseye--id-index))

;;;; Phase 6: keyed / static layers -------------------------------------------

(ert-deftest cmacs-gnuseye--bases-layer ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-keyed)
  (let (res)
    (cmacs-gnuseye-bases--fetch (lambda (e) (setq res e)))
    (should (> (length res) 20))
    (should (cl-some (lambda (e) (eq (plist-get e :kind) 'spaceport)) res))))

(ert-deftest cmacs-gnuseye--acled-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-keyed)
  (let* ((data '((data ((data_id . 7) (latitude . "35.0") (longitude . "45.0")
                        (event_type . "Battles") (fatalities . "3")
                        (country . "Iraq")))))
         (out (cmacs-gnuseye-acled--parse data)))
    (should (= (length out) 1))
    (should (= (plist-get (car out) :lat) 35.0))
    (should (equal (plist-get (car out) :label) "Battles"))))

;;;; Phase 7: dashboard panels ------------------------------------------------

(ert-deftest cmacs-gnuseye--panels-registered ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-markets)
  (dolist (n '(crypto fear-greed fx predictions))
    (should (gethash n cmacs-gnuseye--panels)))
  ;; render on synthetic data yields a string mentioning the symbol
  (let* ((p (gethash 'crypto cmacs-gnuseye--panels))
         (s (funcall (plist-get p :render)
                     '(((symbol . "btc") (current_price . 50000)
                        (price_change_percentage_24h . 2.5))))))
    (should (string-match-p "BTC" s))))

;;;; v2 Phase 8: shared building blocks ---------------------------------------

(ert-deftest cmacs-gnuseye--screen-to-globe-defun ()
  (cmacs-gnuseye-tests--skip)
  (should (fboundp 'cmacs-gnuseye-screen-to-globe)))

(ert-deftest cmacs-gnuseye--opacity ()
  "Per-layer opacity scales the marker alpha byte."
  (cmacs-gnuseye-tests--skip)
  (should (= (cmacs-gnuseye--apply-opacity #xff0000ff 0.5) #xff000080))
  (should (= (cmacs-gnuseye--apply-opacity #xff0000ff 1.0) #xff0000ff))
  (let ((cmacs-gnuseye--render-opacity 0.5))
    (let ((e (cmacs-gnuseye--normalize-entity
              (list :id "z" :lat 0 :lon 0 :kind 'quake))))
      (should (= (logand (plist-get e :color) #xff) 128)))))

(ert-deftest cmacs-gnuseye--geoloc-nearest ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-geoloc)
  (should (equal (cmacs-gnuseye-nearest-country 32.0 53.0) "IRN"))
  (should (equal (cmacs-gnuseye-nearest-country 39.0 -98.0) "USA"))
  (should (consp (cmacs-gnuseye-country-latlon "FRA"))))

(ert-deftest cmacs-gnuseye--charts ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-charts)
  ;; unicode sparkline fallback always returns a non-empty string for >=2 vals
  (should (> (length (cmacs-gnuseye-charts--unicode-spark '(1 2 3 2 5))) 0)))

(ert-deftest cmacs-gnuseye--history-roundtrip ()
  "History capture writes records that load back within a time window."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-history)
  (let* ((tmp (make-temp-file "ge-hist" nil ".eld"))
         (cmacs-gnuseye-history-interval 0.0)
         (cmacs-gnuseye-history--last 0.0))
    (cl-letf (((symbol-function 'cmacs-gnuseye-history-file) (lambda () tmp)))
      (clrhash cmacs-gnuseye--layer-entities)
      (puthash 'test (list (list :id "a" :lat 10 :lon 20 :kind 'quake :label "M5"))
               cmacs-gnuseye--layer-entities)
      (cmacs-gnuseye-history--capture)
      (let ((recs (cmacs-gnuseye-history-load 0.0 (* 2 (float-time)) 'test)))
        (should (= (length recs) 1))
        (should (eq (nth 1 (car recs)) 'test))
        (should (vectorp (nth 2 (car recs))))))
    (clrhash cmacs-gnuseye--layer-entities)
    (ignore-errors (delete-file tmp))))

;;;; v2 Phase 9: new geospatial layer parsers --------------------------------

(ert-deftest cmacs-gnuseye--ucdp-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-conflict)
  (let* ((data '((Result ((id . 1) (latitude . "34.5") (longitude . "43.7")
                          (best . "10") (country . "Iraq")
                          (date_start . "2026-01-01")))))
         (out (cmacs-gnuseye-ucdp--parse data)))
    (should (= (length out) 1))
    (should (= (plist-get (car out) :lat) 34.5))
    (should (eq (plist-get (car out) :kind) 'event))))

(ert-deftest cmacs-gnuseye--disasters-parse ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-health)
  (let* ((data '((data ((id . "5")
                        (fields (name . "Flood X")
                                (status . "ongoing")
                                (country ((name . "Pakistan")
                                          (location (lat . 30.0) (lon . 70.0)))))))))
         (out (cmacs-gnuseye-disasters--parse data)))
    (should (= (length out) 1))
    (should (= (plist-get (car out) :lon) 70.0))
    (should (equal (plist-get (car out) :label) "Flood X"))))

(ert-deftest cmacs-gnuseye--cyber-registered ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-infra)
  (require 'cmacs-gnuseye-conflict)
  (require 'cmacs-gnuseye-health)
  (should (gethash 'cyber cmacs-gnuseye--layers))
  (should (gethash 'ucdp cmacs-gnuseye--layers))
  (should (gethash 'disasters cmacs-gnuseye--layers)))

;;;; v2 Phase 10: visualization upgrades --------------------------------------

(ert-deftest cmacs-gnuseye--heatmap-cells ()
  "Density binning groups co-cell entities and counts them."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-viz)
  (let* ((ents (list (list :lat 40.1 :lon -100.1) (list :lat 40.9 :lon -100.9)
                     (list :lat -20.0 :lon 30.0)))
         (cells (cmacs-gnuseye-heatmap-cells ents 4.0)))
    (should (= (length cells) 2))          ; two occupied 4-deg cells
    (should (= 2 (apply #'max (mapcar (lambda (c) (nth 2 c)) cells))))))

(ert-deftest cmacs-gnuseye--footprint-radius ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-viz)
  ;; ISS (~420 km) horizon radius is ~2200 km.
  (let ((r (/ (cmacs-gnuseye-footprint-radius-m 420000.0) 1000.0)))
    (should (and (> r 1900) (< r 2500)))))

;;;; v2 Phase 11: 2D flat-map mode --------------------------------------------

(ert-deftest cmacs-gnuseye--flat-defuns ()
  (cmacs-gnuseye-tests--skip)
  (should (fboundp 'cmacs-gnuseye-set-projection))
  (should (fboundp 'cmacs-gnuseye-flat-p))
  (should (fboundp 'cmacs-gnuseye-toggle-2d)))

;;;; v2 Phase 12: measurement, export, watchlists -----------------------------

(ert-deftest cmacs-gnuseye--export-geojson ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-export)
  (let* ((ents (list (list :id "a" :kind 'quake :label "M5" :lat 10 :lon 20
                           :layer 'weather)))
         (s (cmacs-gnuseye-export--geojson-string ents))
         (parsed (json-parse-string s :object-type 'alist :array-type 'list)))
    (should (equal (alist-get 'type parsed) "FeatureCollection"))
    (let* ((f (car (alist-get 'features parsed)))
           (coords (alist-get 'coordinates (alist-get 'geometry f))))
      (should (= (elt coords 0) 20))      ; lon first (GeoJSON order)
      (should (= (elt coords 1) 10)))))

(ert-deftest cmacs-gnuseye--export-csv ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-export)
  (let* ((ents (list (list :id "x,1" :kind 'fire :label "a\"b" :lat 1 :lon 2
                           :layer 'natural)))
         (s (cmacs-gnuseye-export--csv-string ents)))
    (should (string-prefix-p "id,kind,label,lat,lon,layer" s))
    (should (string-match-p "\"x,1\"" s))      ; comma-quoted
    (should (string-match-p "\"a\"\"b\"" s)))) ; quote-escaped

(ert-deftest cmacs-gnuseye--watch-cmp ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-watch)
  (should (cmacs-gnuseye--watch-cmp 7 ">" "5"))
  (should-not (cmacs-gnuseye--watch-cmp 3 ">" "5"))
  (should (cmacs-gnuseye--watch-cmp "Tornado Warning" "~" "tornado"))
  (let ((e (list :speed 300 :data '((country . "US")))))
    (should (= (cmacs-gnuseye--watch-field e "speed") 300))
    (should (equal (cmacs-gnuseye--watch-field e "country") "US"))))

(ert-deftest cmacs-gnuseye--measure-defun ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-measure)
  (should (fboundp 'cmacs-gnuseye-measure)))

;;;; v2 Phase 13-14: news + panels --------------------------------------------

(ert-deftest cmacs-gnuseye--news-parse ()
  "RSS items parse into (TITLE . LINK) pairs."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-news)
  (when (fboundp 'libxml-parse-xml-region)
    (let* ((xml (concat "<rss><channel>"
                        "<item><title>Headline A</title>"
                        "<link>https://x/a</link></item>"
                        "<item><title>Headline B</title>"
                        "<link>https://x/b</link></item>"
                        "</channel></rss>"))
           (out (cmacs-gnuseye-news--parse xml)))
      (should (= (length out) 2))
      (should (equal (caar out) "Headline A"))
      (should (equal (cdar out) "https://x/a")))))

(ert-deftest cmacs-gnuseye--new-panels ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-markets)
  (dolist (n '(crypto-treemap hackernews fred))
    (should (gethash n cmacs-gnuseye--panels)))
  ;; HN render on synthetic data
  (let* ((p (gethash 'hackernews cmacs-gnuseye--panels))
         (s (funcall (plist-get p :render)
                     '((hits ((points . 120) (title . "Cool thing")))))))
    (should (string-match-p "Cool thing" s))))

;;;; v2 Phase 15-16: history replay + analytics engines -----------------------

(ert-deftest cmacs-gnuseye--history-ring ()
  "A disk-history window builds a newest-first replay ring of layer hashes."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-replay)
  (require 'cmacs-gnuseye-history)
  (let ((tmp (make-temp-file "ge-hist" nil ".eld")))
    (cl-letf (((symbol-function 'cmacs-gnuseye-history-file) (lambda () tmp)))
      (with-temp-file tmp
        (insert (prin1-to-string (list 100.0 'quakes (vector (vector "q" 1 2 'quake "M5"))))
                "\n"
                (prin1-to-string (list 200.0 'quakes (vector (vector "q" 3 4 'quake "M6"))))
                "\n"))
      (let ((ring (cmacs-gnuseye-replay--history-ring 0.0 1000.0)))
        (should (= (length ring) 2))
        (should (= (car (car ring)) 200.0))   ; newest first
        (should (hash-table-p (cdr (car ring))))))
    (ignore-errors (delete-file tmp))))

(ert-deftest cmacs-gnuseye--engines ()
  "The analytics-engine commands and region context exist + work."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-intel)
  (require 'cmacs-gnuseye-replay)
  (dolist (fn '(cmacs-gnuseye-ai-deduce cmacs-gnuseye-ai-market-implication
                cmacs-gnuseye-ai-resilience cmacs-gnuseye-ai-country-brief
                cmacs-gnuseye-replay-from-history cmacs-gnuseye-backtest))
    (should (fboundp fn)))
  (clrhash cmacs-gnuseye--id-index)
  (puthash "a" (list :layer 'air :id "a" :kind 'aircraft :label "UAL1"
                     :lat 40 :lon -100) cmacs-gnuseye--id-index)
  (let ((ctx (cmacs-gnuseye-intel--region-context)))
    (should (stringp ctx))
    (should (string-match-p "aircraft" ctx)))
  (clrhash cmacs-gnuseye--id-index))

;;;; Marine: GeoJSON AIS (Digitraffic shape) ----------------------------------

(ert-deftest cmacs-gnuseye--marine-geojson-parse ()
  "The marine parser reads GeoJSON features (lat/lon from geometry) and
honours the AIS not-available sentinels (heading 511, cog 360)."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-marine)
  (let* ((data '((type . "FeatureCollection")
                 (features
                  ((mmsi . 230994270)
                   (geometry (type . "Point") (coordinates 24.96 60.15))
                   (properties (mmsi . 230994270) (sog . 10.0) (cog . 235.0)
                               (heading . 511)))
                  ((mmsi . 1)
                   (geometry (type . "Point") (coordinates 25.0 59.9))
                   (properties (mmsi . 1) (sog . 0.0) (cog . 360.0)
                               (heading . 511))))))
         (out (cmacs-gnuseye-marine--parse data)))
    (should (= (length out) 2))
    (let ((a (car out)) (b (cadr out)))
      (should (= (plist-get a :lat) 60.15))      ; from geometry (lon lat)
      (should (= (plist-get a :lon) 24.96))
      (should (= (plist-get a :heading) 235.0))  ; heading 511 -> cog
      (should (< (abs (- (plist-get a :speed) 5.14444)) 1e-3)) ; kt -> m/s
      (should (= (plist-get a :scale) cmacs-gnuseye-marine-marker-scale))
      (should (= (plist-get b :heading) -1)))))  ; both unavailable

;;;; v3: solar-system ephemerides + celestial layers --------------------------

;; Reference epoch 2026-06-09 00:00 UT (unix 1780963200); geocentric RA/Dec
;; (deg, ICRF) + delta (AU) captured from JPL Horizons this session.

(defconst cmacs-gnuseye-tests--epoch 1780963200.0)

(defun cmacs-gnuseye-tests--ra (p)
  "Reconstruct RA (deg) from a sub-point plist P at the test epoch."
  (mod (+ (plist-get p :sublon)
          (cmacs-gnuseye-ephem-gmst cmacs-gnuseye-tests--epoch))
       360.0))

(ert-deftest cmacs-gnuseye--ephem-gmst ()
  "GMST at the J2000 epoch (2000-01-01 12:00 UT) is ~280.46 deg."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-ephem)
  (should (< (abs (- (cmacs-gnuseye-ephem-gmst 946728000.0) 280.46061837))
             0.01)))

(ert-deftest cmacs-gnuseye--ephem-sun ()
  "Sun vs Horizons: RA 76.77464, Dec +22.87900, 1.01503 AU."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-ephem)
  (let ((p (cmacs-gnuseye-ephem-body 'sun cmacs-gnuseye-tests--epoch)))
    (should (< (abs (- (plist-get p :sublat) 22.87900)) 1.0))
    (should (< (abs (- (cmacs-gnuseye-tests--ra p) 76.77464)) 1.0))
    (should (< (abs (- (/ (plist-get p :dist-km) 149597870.7) 1.01503)) 0.01))))

(ert-deftest cmacs-gnuseye--ephem-moon ()
  "Moon vs Horizons: RA 354.55116, Dec -0.26075, 382,250 km."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-ephem)
  (let ((p (cmacs-gnuseye-ephem-body 'moon cmacs-gnuseye-tests--epoch)))
    (should (< (abs (- (plist-get p :sublat) -0.26075)) 2.0))
    (should (< (abs (cmacs-gnuseye-ephem--norm180
                     (- (cmacs-gnuseye-tests--ra p) 354.55116)))
               2.0))
    (should (< (abs (- (plist-get p :dist-km) 382250.0)) 12000.0))))

(ert-deftest cmacs-gnuseye--ephem-mars ()
  "Mars vs Horizons: RA 42.99427, Dec +15.89768, 2.16556 AU."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-ephem)
  (let ((p (cmacs-gnuseye-ephem-body 'mars cmacs-gnuseye-tests--epoch)))
    (should (< (abs (- (plist-get p :sublat) 15.89768)) 1.0))
    (should (< (abs (- (cmacs-gnuseye-tests--ra p) 42.99427)) 1.0))
    (should (< (abs (- (/ (plist-get p :dist-km) 149597870.7) 2.16556)) 0.05))))

(ert-deftest cmacs-gnuseye--celestial-shell ()
  "Distances are linearly true at 290 units/AU (Moon floored, probes capped)."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-celestial)
  (cl-flet ((wr (km) (cmacs-gnuseye-celestial-shell-radius km)))
    (should (< (abs (- (wr 1.496e8) 290.0)) 0.5))         ; Sun = 1 AU
    (should (< (abs (- (wr 4.498e9) (* 290 30.07))) 30))  ; Neptune linear
    (should (= (wr 384400.0) 26.0))                       ; Moon floored
    (should (<= (wr 2.54e10) 9000.001))                   ; Voyager capped
    ;; THE ORBIT CHECK: Jupiter at opposition (4.2 AU from Earth, 5.2 from
    ;; the Sun) must land 4.2x the Sun's distance from Earth -- the linear
    ;; law preserves all relative geometry by construction.
    (should (< (abs (- (/ (wr (* 4.2 1.496e8)) (wr 1.496e8)) 4.2)) 0.01))))

(ert-deftest cmacs-gnuseye--celestial-true-scale ()
  "One sqrt size law for every body (no caps): rendered radius =
6.371*sqrt(R/R_earth).  The Sun dominates Jupiter ~3.2x; Venus ~ Earth."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-celestial)
  (cl-flet ((r-of (body)
              (let* ((spec (assq body cmacs-gnuseye-celestial--bodies))
                     (e (cmacs-gnuseye-celestial--body-entity
                         spec cmacs-gnuseye-tests--epoch)))
                (* 0.099 (plist-get e :scale)))))
    (should (< (abs (- (r-of 'sun) (* 6.371 (sqrt 109.2)))) 0.5))    ; 66.6
    (should (< (abs (- (r-of 'jupiter) (* 6.371 (sqrt 10.97)))) 0.3)); 21.1
    (should (> (/ (r-of 'sun) (r-of 'jupiter)) 3.0))   ; Sun >> Jupiter
    (should (< (abs (- (r-of 'venus) 6.21)) 0.1))      ; Venus ~ Earth
    (should (< (abs (- (r-of 'moon) 3.33)) 0.1))))

(ert-deftest cmacs-gnuseye--horizons-parse ()
  "The Horizons CSV $$SOE block parses to (RA DEC DELTA)."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-celestial)
  (let ((res (concat "stuff\n$$SOE\n"
                     " 2026-Jun-09 00:00, , ,    76.77464,   22.87900,"
                     "  1.01502972366930,  0.2220795,\n$$EOE\n")))
    (pcase-let ((`(,ra ,dec ,delta)
                 (cmacs-gnuseye-celestial--horizons-parse res)))
      (should (< (abs (- ra 76.77464)) 1e-6))
      (should (< (abs (- dec 22.879)) 1e-6))
      (should (< (abs (- delta 1.0150297)) 1e-6)))))

(ert-deftest cmacs-gnuseye--horizons-advance ()
  "Horizons bodies sweep with Earth's rotation: the sub-longitude follows
RA - GMST as time advances (~15 deg/hour westward)."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-celestial)
  (let* ((e (cmacs-gnuseye-celestial--horizons-entity
             "-31" "Voyager 1" 'probe (list 158.0 12.0 170.0)))
         (lon0 (plist-get e :lon)))
    (should (numberp (cdr (assq 'ra (plist-get e :data)))))
    ;; Advance one hour: sub-lon must move ~15.04 deg west.
    (cmacs-gnuseye-celestial--horizons-advance
     (list e) 3600.0 (+ (float-time) 3600.0))
    (let ((dlon (- (mod (+ (- (plist-get e :lon) lon0) 540.0) 360.0) 180.0)))
      (should (< (abs (+ dlon 15.04)) 0.2)))))

(ert-deftest cmacs-gnuseye--celestial-layers ()
  "The celestial layers + home command register."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-celestial)
  (dolist (l '(solar-system probes asteroids))
    (should (gethash l cmacs-gnuseye--layers)))
  (should (fboundp 'cmacs-gnuseye-home))
  ;; A solar-system fetch yields 9 bodies with shells + live sub-points.
  (let (res)
    (cmacs-gnuseye-celestial--fetch (lambda (e) (setq res e)))
    (should (= (length res) 9))
    (dolist (e res)
      (should (numberp (plist-get e :lat)))
      (should (> (plist-get e :alt) 5e6)))))   ; well above the surface

;;;; Click resolution + country details ---------------------------------------

(ert-deftest cmacs-gnuseye--resolve-pick-stale ()
  "A stale node payload is overridden by the pick-time entity id (PATH):
marker rebuilds renumber node ids between pick and dispatch."
  (cmacs-gnuseye-tests--skip)
  (clrhash cmacs-gnuseye--id-index)
  (puthash "real" (list :layer 'air :id "real" :kind 'aircraft :lat 1 :lon 2)
           cmacs-gnuseye--id-index)
  (cl-letf (((symbol-function 'cmacs-gnuseye-entity-at)
             (lambda (_b _id) (list :id "stale" :kind 'ship))))
    ;; payload disagrees with path -> index wins
    (should (equal (plist-get (cmacs-gnuseye--resolve-pick nil 5 "real") :id)
                   "real"))
    ;; payload agrees -> payload used
    (should (equal (plist-get (cmacs-gnuseye--resolve-pick nil 5 "stale") :id)
                   "stale")))
  ;; payload gone entirely -> index by path
  (cl-letf (((symbol-function 'cmacs-gnuseye-entity-at) (lambda (_b _id) nil)))
    (should (equal (plist-get (cmacs-gnuseye--resolve-pick nil 5 "real") :id)
                   "real")))
  (clrhash cmacs-gnuseye--id-index))

(ert-deftest cmacs-gnuseye--pick-index-miss-fallback ()
  "If the id index misses (mid-rebuild) but the click resolved to a valid
payload entity, the inspector still shows it and the selection is set."
  (cmacs-gnuseye-tests--skip)
  (clrhash cmacs-gnuseye--id-index)
  (setq cmacs-gnuseye--selected-id nil)
  (cl-letf (((symbol-function 'cmacs-gnuseye-entity-at)
             (lambda (_b _id)
               (list :id "cel:jupiter" :kind 'planet :label "Jupiter"
                     :lat 10.0 :lon 20.0 :alt 1.0e9
                     :data '((body . jupiter)))))
            ;; no globe attached in batch: stub the camera/redraw paths
            ((symbol-function 'cmacs-gnuseye--render-all) #'ignore)
            ((symbol-function 'cmacs-gnuseye--list-goto) #'ignore))
    (cmacs-gnuseye--on-pick-1 nil 7 "cel:jupiter")
    (should (equal cmacs-gnuseye--selected-id "cel:jupiter"))
    (let ((b (get-buffer "*GNU's Eye Inspector*")))
      (should b)
      (with-current-buffer b
        (should (string-match-p "Jupiter" (buffer-string))))))
  (setq cmacs-gnuseye--selected-id nil))

(ert-deftest cmacs-gnuseye--country-pip ()
  "Point-in-country: inside a square ring, outside it, and hole handling."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-country)
  (let ((square '(((0 0) (10 0) (10 10) (0 10) (0 0)))))
    (should (cmacs-gnuseye-country--pip 5 5 square))
    (should-not (cmacs-gnuseye-country--pip 15 5 square))
    (should-not (cmacs-gnuseye-country--pip 5 -1 square)))
  ;; even-odd: a hole ring excludes its interior
  (let ((holed '(((0 0) (10 0) (10 10) (0 10) (0 0))
                 ((4 4) (6 4) (6 6) (4 6) (4 4)))))
    (should (cmacs-gnuseye-country--pip 2 2 holed))
    (should-not (cmacs-gnuseye-country--pip 5 5 holed))))

(ert-deftest cmacs-gnuseye--country-entity ()
  "A country pseudo-entity carries NE population/GDP/income rows."
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-country)
  (let* ((c (list "TST" "Testland"
                  '((POP_EST . 5000000) (GDP_MD . 250000)
                    (INCOME_GRP . "2. High income") (CONTINENT . "Europe"))
                  '(-10 10 -10 10) nil))
         (e (cmacs-gnuseye-country--entity c))
         (data (plist-get e :data)))
    (should (equal (plist-get e :label) "Testland"))
    (should (eq (plist-get e :kind) 'country))
    (should (equal (cdr (assq 'population\ \(est\) data)) "5.00 million"))
    (should (cl-some (lambda (kv) (string-match-p "billion" (format "%s" (cdr kv))))
                     data))))

(ert-deftest cmacs-gnuseye--country-fmt ()
  (cmacs-gnuseye-tests--skip)
  (require 'cmacs-gnuseye-country)
  (should (equal (cmacs-gnuseye-country--fmt-num 27.36e12) "27.36 trillion"))
  (should (equal (cmacs-gnuseye-country--fmt-num 4.2) "4.2")))

(provide 'cmacs-gnuseye-tests)

;;; cmacs-gnuseye-tests.el ends here
