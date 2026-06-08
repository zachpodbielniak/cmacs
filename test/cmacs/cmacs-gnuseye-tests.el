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
  "Equator/prime-meridian on +X, north pole on +Y, lon east toward +Z."
  (cmacs-gnuseye-tests--skip)
  (let ((o (cmacs-gnuseye-latlon-to-xyz 0 0))
        (np (cmacs-gnuseye-latlon-to-xyz 90 0))
        (e (cmacs-gnuseye-latlon-to-xyz 0 90)))
    (should (< (abs (- (aref o 0) 6.371)) 1e-3))
    (should (< (abs (aref o 1)) 1e-3))
    (should (< (abs (- (aref np 1) 6.371)) 1e-3))
    (should (< (abs (- (aref e 2) 6.371)) 1e-3))))

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

(provide 'cmacs-gnuseye-tests)

;;; cmacs-gnuseye-tests.el ends here
