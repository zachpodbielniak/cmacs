;;; cmacs-gnuseye-overlay.el --- raster overlay/tile engine  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Provider-agnostic plumbing for the draped raster weather overlays
;; (radar, clouds, ...): binary tile/image downloads with an on-disk
;; cache, a bounded-concurrency fetch queue, web-mercator tile math, and
;; a compose driver over the C overlay DEFUNs
;; (`cmacs-gnuseye-overlay-ensure' / `-compose-frame' / `-show-frame' /
;; `-frames' / `-set-alpha' / `-clear', from cmacs-gnuseye-overlay.c).
;; RainViewer, OpenWeatherMap, and NASA GIBS all feed through this file;
;; the layers themselves live in cmacs-gnuseye-meteo.el.
;;
;; Everything degrades gracefully when the C half is absent (an older
;; build): `cmacs-gnuseye-overlay-supported-p' gates every GPU call.
;;
;; v1 rasters compose the whole world per frame (mercator zoom <= 3, a
;; canvas of at most 2048 px); view-following regional windows are a
;; roadmap item.

;;; Code:

(require 'cmacs-gnuseye)

(defvar url-http-response-status)       ; bound by url-http in the cb buffer

(declare-function cmacs-gnuseye-overlay-ensure "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-compose-frame "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-show-frame "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-frames "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-set-alpha "cmacs-gnuseye-overlay.c")
(declare-function cmacs-gnuseye-overlay-clear "cmacs-gnuseye-overlay.c")

(defcustom cmacs-gnuseye-overlay-cache-dir
  (expand-file-name "~/.cache/cmacs/gnuseye/overlay/")
  "Directory caching downloaded weather tiles/imagery, one subdir per feed."
  :type 'directory
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-overlay-fetch-concurrency 4
  "Parallel downloads per overlay frame (politeness cap per provider)."
  :type 'integer
  :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-overlay-deadline 15
  "Seconds to wait for a frame's tiles before composing what arrived.
Missing tiles stay transparent; they retry on the next refresh."
  :type 'number
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-overlay-supported-p ()
  "Non-nil when this cmacs build has the C raster-overlay DEFUNs."
  (fboundp 'cmacs-gnuseye-overlay-compose-frame))

(defun cmacs-gnuseye-overlay-cache-file (subdir name)
  "Path of cache file NAME under SUBDIR, creating the directory."
  (let ((dir (expand-file-name subdir cmacs-gnuseye-overlay-cache-dir)))
    (unless (file-directory-p dir) (ignore-errors (make-directory dir t)))
    (expand-file-name name dir)))

(defun cmacs-gnuseye-overlay-prune (subdir max-age)
  "Delete SUBDIR cache files older than MAX-AGE seconds."
  (let ((dir (expand-file-name subdir cmacs-gnuseye-overlay-cache-dir))
        (cutoff (- (float-time) max-age)))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\`[^.]" t))
        (when (and (file-regular-p f)
                   (< (float-time (file-attribute-modification-time
                                   (file-attributes f)))
                      cutoff))
          (ignore-errors (delete-file f)))))))

;;;; Binary downloads ---------------------------------------------------------

;; The native gnuseye HTTP client is text-only (it returns a decoded Lisp
;; string), so raster bytes go through `url-retrieve' + a binary
;; `write-region' -- the celestial-texture pattern -- with an atomic
;; tmp+rename and one retry.

(defun cmacs-gnuseye-overlay--fetch-1 (url path callback headers retries)
  (let ((url-request-extra-headers headers))
    (condition-case nil
        (url-retrieve
         url
         (lambda (status)
           (let ((ok nil))
             (unwind-protect
                 (when (and (not (plist-get status :error))
                            (integerp (bound-and-true-p
                                       url-http-response-status))
                            (<= 200 url-http-response-status 299)
                            (re-search-forward "\n\n" nil t))
                   (let ((coding-system-for-write 'binary)
                         (tmp (concat path ".tmp")))
                     (write-region (point) (point-max) tmp nil 'silent)
                     (rename-file tmp path t)
                     (setq ok t)))
               (kill-buffer (current-buffer))
               (if (or ok (<= retries 0))
                   (funcall callback ok)
                 (run-with-timer
                  1 nil #'cmacs-gnuseye-overlay--fetch-1
                  url path callback headers (1- retries))))))
         nil t t)
      (error (funcall callback nil)))))

(defun cmacs-gnuseye-overlay-fetch-file (url path callback &optional headers)
  "GET URL into PATH (binary), then call (CALLBACK OK).
A non-empty PATH short-circuits as a cache hit.  HEADERS is an alist of
extra request headers.  Writes are atomic (tmp + rename); one retry."
  (if (and (file-exists-p path)
           (> (or (file-attribute-size (file-attributes path)) 0) 0))
      (funcall callback t)
    (ignore-errors (make-directory (file-name-directory path) t))
    (cmacs-gnuseye-overlay--fetch-1 url path callback headers 1)))

(defun cmacs-gnuseye-overlay-fetch-queue (jobs concurrency callback)
  "Download JOBS -- a list of (URL . PATH) -- CONCURRENCY at a time.
Calls (CALLBACK NOK NTOTAL) once every job finished (success or not)."
  (let* ((total (length jobs))
         (ok 0) (finished 0) (queue jobs) (launch nil))
    (if (null jobs)
        (funcall callback 0 0)
      (setq launch
            (lambda ()
              (when queue
                (let ((job (pop queue)))
                  (cmacs-gnuseye-overlay-fetch-file
                   (car job) (cdr job)
                   (lambda (success)
                     (when success (setq ok (1+ ok)))
                     (setq finished (1+ finished))
                     (if (>= finished total)
                         (funcall callback ok total)
                       (funcall launch))))))))
      (dotimes (_ (min (max 1 concurrency) total))
        (funcall launch)))))

;;;; Web-mercator tile math ---------------------------------------------------

(defconst cmacs-gnuseye-overlay-mercator-max-lat 85.05112878
  "Web-mercator latitude limit (EPSG:3857).")

(defun cmacs-gnuseye-overlay-tile-xy (lat lon z)
  "Slippy-map tile (X . Y) containing LAT,LON at zoom Z."
  (let* ((n (ash 1 z))
         (lat (max (- cmacs-gnuseye-overlay-mercator-max-lat)
                   (min cmacs-gnuseye-overlay-mercator-max-lat lat)))
         (x (floor (* (/ (+ lon 180.0) 360.0) n)))
         (rad (* lat (/ float-pi 180.0)))
         (y (floor (* (/ (- 1.0 (/ (log (+ (tan rad) (/ 1.0 (cos rad))))
                                   float-pi))
                         2.0)
                      n))))
    (cons (max 0 (min (1- n) x)) (max 0 (min (1- n) y)))))

(defun cmacs-gnuseye-overlay-world-tiles (z)
  "All (X Y Z) tiles covering the world at zoom Z (2^Z x 2^Z of them)."
  (let ((n (ash 1 z)) out)
    (dotimes (y n)
      (dotimes (x n)
        (push (list x y z) out)))
    (nreverse out)))

;;;; Frame driver -------------------------------------------------------------

(defun cmacs-gnuseye-overlay-ensure-tile-frame (buffer channel tag spec
                                                       callback)
  "Download SPEC's mercator tiles, then compose frame TAG on CHANNEL.
SPEC is a plist:
  :tiles     list of (X Y Z) slippy tiles (all the same Z)
  :url-fn    (lambda (x y z)) -> tile URL
  :file-fn   (lambda (x y z)) -> cache path for that tile
  :tile-size tile pixel size (default 256)
  :opts      extra OPTS for `cmacs-gnuseye-overlay-compose-frame'
             (`:projection mercator' and the canvas size are supplied)
Tiles already cached are not re-fetched.  Composes when every download
finished or after `cmacs-gnuseye-overlay-deadline' seconds, with missing
tiles left transparent; calls (CALLBACK RESULT) where RESULT is the
compose-frame value (nil when nothing composed)."
  (let* ((tiles (plist-get spec :tiles))
         (url-fn (plist-get spec :url-fn))
         (file-fn (plist-get spec :file-fn))
         (size (or (plist-get spec :tile-size) 256))
         (z (nth 2 (car tiles)))
         (canvas (* (ash 1 (or z 0)) size))
         (done nil)
         timer
         (compose
          (lambda ()
            (unless done
              (setq done t)
              (when (timerp timer) (cancel-timer timer))
              (let (placements)
                (dolist (tl tiles)
                  (let* ((f (funcall file-fn (nth 0 tl) (nth 1 tl)
                                     (nth 2 tl))))
                    (when (and f (file-exists-p f)
                               (> (or (file-attribute-size
                                       (file-attributes f))
                                      0)
                                  0))
                      (push (list f (* (nth 0 tl) size) (* (nth 1 tl) size)
                                  size size)
                            placements))))
                (funcall
                 callback
                 (and placements
                      (cmacs-gnuseye-overlay-supported-p)
                      (buffer-live-p buffer)
                      (cmacs-gnuseye-overlay-compose-frame
                       buffer channel tag (nreverse placements)
                       (append (plist-get spec :opts)
                               (list :canvas-width canvas
                                     :canvas-height canvas
                                     :projection 'mercator))))))))))
    (if (or (null tiles) (not (cmacs-gnuseye-overlay-supported-p)))
        (funcall callback nil)
      (let (jobs)
        (dolist (tl tiles)
          (let ((f (funcall file-fn (nth 0 tl) (nth 1 tl) (nth 2 tl))))
            (unless (and (file-exists-p f)
                         (> (or (file-attribute-size (file-attributes f)) 0)
                            0))
              (push (cons (funcall url-fn (nth 0 tl) (nth 1 tl) (nth 2 tl))
                          f)
                    jobs))))
        (if (null jobs)
            (funcall compose)
          (setq timer (run-with-timer cmacs-gnuseye-overlay-deadline nil
                                      compose))
          (cmacs-gnuseye-overlay-fetch-queue
           (nreverse jobs) cmacs-gnuseye-overlay-fetch-concurrency
           (lambda (_nok _ntotal) (funcall compose))))))))

;;;; OpenWeatherMap tile provider (optional, keyed) ---------------------------

(defconst cmacs-gnuseye-owm-tile-styles
  '("precipitation_new" "clouds_new" "temp_new" "wind_new" "pressure_new")
  "OpenWeatherMap weather-map tile styles.")

(defun cmacs-gnuseye-owm-tile-url (style x y z)
  "OpenWeatherMap tile URL for STYLE at X,Y,Z, or nil without an API key.
The key resolves via `cmacs-gnuseye-secret' (OPENWEATHERMAP_API_KEY):
environment, ~/.authinfo(.gpg) (machine api.openweathermap.org), or the
keys file."
  (let ((key (cmacs-gnuseye-secret "OPENWEATHERMAP_API_KEY")))
    (and key
         (format "https://tile.openweathermap.org/map/%s/%d/%d/%d.png?appid=%s"
                 style z x y key))))

(provide 'cmacs-gnuseye-overlay)
;;; cmacs-gnuseye-overlay.el ends here
