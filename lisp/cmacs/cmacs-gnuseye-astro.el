;;; cmacs-gnuseye-astro.el --- GNU's Eye astronomical layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Satellites / spacecraft layer.  TLEs are fetched from CelesTrak (no
;; key) at most every few hours and cached; on every (fast) refresh the
;; cached element sets are re-propagated locally to "now" with the
;; two-body propagator in cmacs-gnuseye-sgp4.c -- so live motion needs no
;; network.  Each satellite carries its one-orbit ground track as a trail.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-astro-group "stations"
  "CelesTrak GP group to track (e.g. \"stations\", \"visual\", \"starlink\")."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-astro-max 40
  "Maximum number of satellites to render (bounds marker/trail count)."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-astro-show-orbits t
  "When non-nil, draw each satellite's one-orbit ground track."
  :type 'boolean
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-astro-tle-ttl (* 6 3600)
  "Seconds to reuse cached TLEs before refetching from CelesTrak."
  :type 'integer
  :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-astro--elsets nil
  "Cached list of (NAME . ELSET) from the last TLE fetch.")
(defvar cmacs-gnuseye-astro--tle-time 0)

(defun cmacs-gnuseye-astro--url ()
  (format "https://celestrak.org/NORAD/elements/gp.php?GROUP=%s&FORMAT=tle"
          (url-hexify-string cmacs-gnuseye-astro-group)))

(defun cmacs-gnuseye-astro--parse-tles (body)
  "Parse BODY (CelesTrak 3-line TLE text) into a list of (NAME . ELSET)."
  (let ((lines (seq-filter (lambda (l) (> (length (string-trim l)) 0))
                           (split-string body "\n")))
        (out nil) (count 0))
    (while (and (>= (length lines) 3) (< count cmacs-gnuseye-astro-max))
      (let* ((name (string-trim (nth 0 lines)))
             (l1 (nth 1 lines))
             (l2 (nth 2 lines))
             (el (and (string-prefix-p "1 " (string-trim l1))
                      (string-prefix-p "2 " (string-trim l2))
                      (cmacs-gnuseye-tle-parse l1 l2))))
        (when el
          (push (cons name el) out)
          (setq count (1+ count)))
        (setq lines (nthcdr 3 lines))))
    (nreverse out)))

(defun cmacs-gnuseye-astro--entity (name elset now)
  "Build a satellite entity for NAME/ELSET propagated to NOW."
  (let* ((pos (cmacs-gnuseye-sat-propagate elset now))
         (ahead (cmacs-gnuseye-sat-propagate elset (+ now 30)))
         (heading (and pos ahead
                       (cmacs-gnuseye-bearing (nth 0 pos) (nth 1 pos)
                                              (nth 0 ahead) (nth 1 ahead))))
         (n (aref elset 7))               ; mean motion rad/s
         (period (if (> n 0) (/ (* 2 float-pi) n) 5400.0))
         (trail (when cmacs-gnuseye-astro-show-orbits
                  (append (cmacs-gnuseye-sat-track elset now (/ period 24.0) 24)
                          nil))))
    (when pos
      (list :id (format "sat:%s" name)
            :kind 'satellite
            :label name
            :lat (nth 0 pos) :lon (nth 1 pos) :alt (nth 2 pos)
            :heading heading
            :trail (mapcar (lambda (p) (list (aref p 0) (aref p 1) (aref p 2)))
                           trail)
            :data `((period-min . ,(/ period 60.0))
                    (altitude-km . ,(/ (nth 2 pos) 1000.0)))))))

(defun cmacs-gnuseye-astro--entities (now)
  (delq nil (mapcar (lambda (pair)
                      (cmacs-gnuseye-astro--entity (car pair) (cdr pair) now))
                    cmacs-gnuseye-astro--elsets)))

(defun cmacs-gnuseye-astro--fetch (cb)
  "Layer fetch: refetch TLEs when stale, else re-propagate cached elsets."
  (let ((now (float-time)))
    (if (and cmacs-gnuseye-astro--elsets
             (< (- now cmacs-gnuseye-astro--tle-time) cmacs-gnuseye-astro-tle-ttl))
        (funcall cb (cmacs-gnuseye-astro--entities now))
      (cmacs-gnuseye-fetch-text
       (cmacs-gnuseye-astro--url)
       (lambda (body)
         (when (and body (> (length body) 10))
           (setq cmacs-gnuseye-astro--elsets (cmacs-gnuseye-astro--parse-tles body)
                 cmacs-gnuseye-astro--tle-time now))
         (funcall cb (cmacs-gnuseye-astro--entities now)))))))

(cmacs-gnuseye-define-layer satellites
  :title "Satellites (CelesTrak TLE)"
  :group 'astronomical
  :kind 'satellite
  :interval 5
  :default-on t
  :fetch #'cmacs-gnuseye-astro--fetch)

(provide 'cmacs-gnuseye-astro)
;;; cmacs-gnuseye-astro.el ends here
