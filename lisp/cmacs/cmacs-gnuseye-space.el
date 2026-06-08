;;; cmacs-gnuseye-space.el --- GNU's Eye space-weather layers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Keyless space-weather layers (NOAA SWPC), in the `space-weather' category:
;;   aurora  the OVATION auroral-oval forecast plotted as a band of
;;           probability-coloured dots (no key).
;;
;; The planetary Kp index and solar-wind numbers are scalars, not map
;; features; they belong in the stats pane (Phase 4), not here.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-aurora-url
  "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"
  "NOAA SWPC OVATION aurora forecast (no key).
A grid of [lon lat probability%] triples."
  :type 'string
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-aurora-threshold 25
  "Minimum aurora probability (percent) to plot."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-aurora-step 2
  "Plot every Nth qualifying grid point (thins the oval; 1 = all)."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-aurora-max 600
  "Maximum aurora points to plot."
  :type 'integer
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-aurora--color (prob)
  "Aurora dot colour for probability PROB (percent): brighter green = higher."
  (let* ((p (max 0.0 (min 1.0 (/ (float prob) 100.0))))
         (g (round (+ 120 (* 135 p))))
         (r (round (* 60 p))))
    (format "#%02x%02x%02x" r g 90)))

(defun cmacs-gnuseye-aurora--parse (data)
  "Parse SWPC OVATION DATA into aurora point entities above the threshold."
  (let ((coords (alist-get 'coordinates data))
        (out nil) (i 0) (n 0)
        (step (max 1 cmacs-gnuseye-aurora-step)))
    (catch 'done
      (dolist (c coords)
        (let ((lon (nth 0 c)) (lat (nth 1 c)) (prob (nth 2 c)))
          (when (and (numberp prob) (>= prob cmacs-gnuseye-aurora-threshold))
            (when (zerop (mod i step))
              (let ((lon2 (if (> lon 180) (- lon 360) lon)))
                (push (list :id (format "aurora:%d" n)
                            :kind 'event
                            :label ""
                            :lat (float lat) :lon (float lon2)
                            :scale 0.45
                            :color (cmacs-gnuseye-aurora--color prob)
                            :data `((probability . ,prob)))
                      out)
                (setq n (1+ n))
                (when (>= n cmacs-gnuseye-aurora-max) (throw 'done nil))))
            (setq i (1+ i))))))
    (nreverse out)))

(defun cmacs-gnuseye-aurora--fetch (cb)
  (cmacs-gnuseye-fetch-json
   cmacs-gnuseye-aurora-url
   (lambda (data) (funcall cb (and data (cmacs-gnuseye-aurora--parse data))))
   nil 'list))

(cmacs-gnuseye-define-layer aurora
  :title "Aurora oval (NOAA SWPC OVATION)"
  :group 'space-weather
  :kind 'event
  :interval 300
  :default-on nil
  :fetch #'cmacs-gnuseye-aurora--fetch)

(provide 'cmacs-gnuseye-space)
;;; cmacs-gnuseye-space.el ends here
