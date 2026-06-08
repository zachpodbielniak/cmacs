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
        (should (equal (plist-get badge :label) "3")))
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

(provide 'cmacs-gnuseye-tests)

;;; cmacs-gnuseye-tests.el ends here
