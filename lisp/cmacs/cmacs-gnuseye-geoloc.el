;;; cmacs-gnuseye-geoloc.el --- GNU's Eye geolocation helpers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Shared geolocation: an ISO-A3 country-centroid table + nearest-country, and
;; a keyless, cached IP -> (lat lon country) resolver (ip-api.com).  Used by
;; country-only feeds (Cloudflare outages), cyber-threat IP feeds, and the
;; point-in-country CII.

;;; Code:

(require 'cmacs-gnuseye)

(defconst cmacs-gnuseye-country-centroids
  '(("USA" 39.8 -98.6) ("CAN" 56.1 -106.3) ("MEX" 23.6 -102.5)
    ("GTM" 15.8 -90.2) ("CUB" 21.5 -79.5) ("BRA" -10.3 -53.2)
    ("ARG" -38.4 -63.6) ("COL" 4.6 -74.3) ("CHL" -35.7 -71.5)
    ("PER" -9.2 -75.0) ("VEN" 6.4 -66.6) ("BOL" -16.3 -63.6)
    ("GBR" 54.0 -2.4) ("IRL" 53.2 -8.2) ("FRA" 46.6 2.2) ("DEU" 51.2 10.4)
    ("ESP" 40.0 -3.7) ("PRT" 39.6 -8.0) ("ITA" 41.9 12.6) ("CHE" 46.8 8.2)
    ("AUT" 47.6 14.1) ("BEL" 50.6 4.6) ("NLD" 52.1 5.3) ("DNK" 56.0 9.5)
    ("NOR" 64.5 17.9) ("SWE" 62.2 17.6) ("FIN" 64.5 26.3) ("POL" 51.9 19.1)
    ("CZE" 49.8 15.5) ("HUN" 47.2 19.4) ("ROU" 45.9 24.97) ("GRC" 39.1 21.8)
    ("UKR" 48.4 31.2) ("BLR" 53.7 28.0) ("RUS" 61.5 105.3) ("TUR" 38.9 35.2)
    ("SYR" 35.0 38.5) ("IRQ" 33.2 43.7) ("IRN" 32.4 53.7) ("ISR" 31.4 35.0)
    ("LBN" 33.9 35.9) ("JOR" 31.3 36.2) ("SAU" 23.9 45.1) ("ARE" 23.9 54.3)
    ("QAT" 25.3 51.2) ("KWT" 29.3 47.6) ("YEM" 15.6 48.5) ("OMN" 21.5 56.1)
    ("EGY" 26.8 30.8) ("LBY" 26.3 17.2) ("TUN" 34.1 9.6) ("DZA" 28.0 1.7)
    ("MAR" 31.8 -7.1) ("SDN" 12.9 30.2) ("SSD" 7.3 30.3) ("ETH" 9.1 40.5)
    ("ERI" 15.4 39.8) ("SOM" 5.2 46.2) ("KEN" 0.0 37.9) ("TZA" -6.4 34.9)
    ("UGA" 1.4 32.4) ("NGA" 9.1 8.7) ("NER" 17.6 8.1) ("MLI" 17.6 -4.0)
    ("TCD" 15.4 18.7) ("CMR" 5.7 12.7) ("COD" -4.0 21.8) ("AGO" -11.2 17.9)
    ("ZAF" -30.6 22.9) ("ZWE" -19.0 29.9) ("MOZ" -17.3 35.5) ("MDG" -19.4 46.7)
    ("IND" 22.4 78.7) ("PAK" 30.4 69.3) ("AFG" 33.9 67.7) ("BGD" 23.7 90.4)
    ("LKA" 7.9 80.7) ("NPL" 28.4 84.1) ("CHN" 35.9 104.2) ("MNG" 46.9 103.8)
    ("JPN" 36.2 138.3) ("KOR" 36.5 127.8) ("PRK" 40.3 127.5) ("TWN" 23.7 121.0)
    ("IDN" -2.5 118.0) ("PHL" 12.9 121.8) ("VNM" 14.1 108.3) ("MMR" 21.9 95.96)
    ("THA" 15.9 100.99) ("MYS" 4.2 102.0) ("KHM" 12.6 104.9) ("LAO" 18.2 103.9)
    ("AUS" -25.7 133.8) ("NZL" -41.8 173.0) ("PNG" -6.5 145.0))
  "ISO-A3 -> centroid (NAME LAT LON) for assigning signals to countries.")

(defun cmacs-gnuseye-nearest-country (lat lon &optional max-km)
  "ISO-A3 of the nearest centroid to (LAT LON), or nil if beyond MAX-KM
\(default 2000 km)."
  (let ((best nil) (bestd 1.0e30) (limit (* 1000.0 (or max-km 2000.0))))
    (dolist (c cmacs-gnuseye-country-centroids)
      (let ((d (ignore-errors
                 (cmacs-gnuseye-haversine lat lon (nth 1 c) (nth 2 c)))))
        (when (and (numberp d) (< d bestd)) (setq bestd d best (nth 0 c)))))
    (and (< bestd limit) best)))

(defun cmacs-gnuseye-country-latlon (iso)
  "Return (LAT . LON) centroid for ISO-A3 code ISO, or nil."
  (let ((c (assoc iso cmacs-gnuseye-country-centroids)))
    (and c (cons (nth 1 c) (nth 2 c)))))

;;; Keyless IP geolocation (ip-api.com), disk-cached -------------------------

(defcustom cmacs-gnuseye-ipgeo-url "http://ip-api.com/json/%s"
  "Keyless IP geolocation endpoint; %s is the IP address."
  :type 'string :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-ipgeo--cache nil)
(defvar cmacs-gnuseye-ipgeo--loaded nil)

(defun cmacs-gnuseye-ipgeo--file ()
  (expand-file-name "cmacs/gnuseye/ipgeo.el"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache")))

(defun cmacs-gnuseye-ipgeo--load ()
  (unless cmacs-gnuseye-ipgeo--loaded
    (setq cmacs-gnuseye-ipgeo--loaded t)
    (let ((f (cmacs-gnuseye-ipgeo--file)))
      (when (file-readable-p f)
        (ignore-errors
          (setq cmacs-gnuseye-ipgeo--cache
                (with-temp-buffer (insert-file-contents f)
                                  (read (current-buffer))))))))
  (unless (hash-table-p cmacs-gnuseye-ipgeo--cache)
    (setq cmacs-gnuseye-ipgeo--cache (make-hash-table :test 'equal))))

(defun cmacs-gnuseye-ipgeo--save ()
  (ignore-errors
    (let ((f (cmacs-gnuseye-ipgeo--file)))
      (make-directory (file-name-directory f) t)
      (with-temp-file f (prin1 cmacs-gnuseye-ipgeo--cache (current-buffer))))))

(defun cmacs-gnuseye-geolocate-ip (ip callback)
  "Resolve IP to (LAT LON COUNTRY) and call (CALLBACK RESULT) (or nil).
Cached to disk; ip-api.com is keyless and rate-limited (~45/min)."
  (cmacs-gnuseye-ipgeo--load)
  (let ((hit (gethash ip cmacs-gnuseye-ipgeo--cache)))
    (if hit
        (funcall callback hit)
      (cmacs-gnuseye-fetch-json
       (format cmacs-gnuseye-ipgeo-url ip)
       (lambda (data)
         (let ((res (and data (equal (alist-get 'status data) "success")
                         (list (alist-get 'lat data) (alist-get 'lon data)
                               (alist-get 'countryCode data)))))
           (when res
             (puthash ip res cmacs-gnuseye-ipgeo--cache)
             (cmacs-gnuseye-ipgeo--save))
           (funcall callback res)))))))

(provide 'cmacs-gnuseye-geoloc)
;;; cmacs-gnuseye-geoloc.el ends here
