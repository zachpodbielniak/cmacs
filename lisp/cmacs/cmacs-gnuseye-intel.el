;;; cmacs-gnuseye-intel.el --- GNU's Eye intelligence/AI layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The intelligence layer:
;;   * cross-source correlation -> a synthetic `hotspots' layer of co-located
;;     multi-kind signal clusters (pure Elisp; O(n) grid clustering);
;;   * a country-instability index (CII) that aggregates active signals per
;;     country and drives the choropleth fill;
;;   * AI commands (ask about an entity, brief the region) via cmacs-ai when
;;     it is available, into Org side buffers (gracefully absent otherwise).

;;; Code:

(require 'cmacs-gnuseye)

(defconst cmacs-gnuseye-intel--signal-kinds
  '(quake fire storm volcano alert event outage cyber launch radiation)
  "Entity kinds treated as situational `signals' for correlation + CII.")

(defun cmacs-gnuseye-intel--signals ()
  "All current signal-kind entities from the index."
  (let (out)
    (maphash (lambda (_ e)
               (when (memq (plist-get e :kind) cmacs-gnuseye-intel--signal-kinds)
                 (push e out)))
             cmacs-gnuseye--id-index)
    out))

;;; Cross-source correlation -> hotspots --------------------------------------

(defcustom cmacs-gnuseye-intel-cell-deg 3.0
  "Grid cell (degrees) for spatial correlation clustering."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-intel-min-kinds 2
  "A hotspot needs at least this many DISTINCT signal kinds co-located."
  :type 'integer :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-intel--compute-hotspots ()
  "Grid-cluster signals; a cell with >= `cmacs-gnuseye-intel-min-kinds'
distinct kinds becomes a scored hotspot entity."
  (let ((cell cmacs-gnuseye-intel-cell-deg)
        (buckets (make-hash-table :test 'equal)) out)
    (dolist (e (cmacs-gnuseye-intel--signals))
      (let ((key (cons (floor (/ (or (plist-get e :lat) 0) cell))
                       (floor (/ (or (plist-get e :lon) 0) cell)))))
        (push e (gethash key buckets))))
    (maphash
     (lambda (key members)
       (let ((kinds (delete-dups (mapcar (lambda (m) (plist-get m :kind)) members)))
             (slat 0.0) (slon 0.0) (n 0))
         (when (>= (length kinds) cmacs-gnuseye-intel-min-kinds)
           (dolist (m members)
             (setq slat (+ slat (or (plist-get m :lat) 0.0))
                   slon (+ slon (or (plist-get m :lon) 0.0)) n (1+ n)))
           (push (list :id (format "hotspot:%s:%s" (car key) (cdr key))
                       :kind 'hotspot
                       :label (format "%d signals / %d kinds" n (length kinds))
                       :lat (/ slat n) :lon (/ slon n)
                       :scale (min 2.5 (+ 1.2 (* 0.15 n)))
                       :label-mode 3
                       :data `((count . ,n) (kinds . ,kinds)
                               (members . ,(mapcar (lambda (m) (plist-get m :label))
                                                   members))))
                 out))))
     buckets)
    out))

(defun cmacs-gnuseye-intel--hotspots-fetch (cb)
  (funcall cb (cmacs-gnuseye-intel--compute-hotspots)))

(defun cmacs-gnuseye-intel--hotspot-detail (e)
  "Inspector detail for a hotspot E."
  (insert (propertize "Correlation hotspot\n" 'face 'bold))
  (let ((d (plist-get e :data)))
    (insert (format "  signals : %s\n" (alist-get 'count d)))
    (insert (format "  kinds   : %s\n" (alist-get 'kinds d)))
    (insert "  members :\n")
    (dolist (m (alist-get 'members d))
      (when m (insert (format "    - %s\n" m))))))

(cmacs-gnuseye-define-layer hotspots
  :title "Hotspots (cross-source correlation)"
  :group 'conflict
  :kind 'hotspot
  :interval 60
  :default-on nil
  :fetch #'cmacs-gnuseye-intel--hotspots-fetch
  :detail #'cmacs-gnuseye-intel--hotspot-detail)

;;; Country-instability index (CII) -> choropleth -----------------------------

(defconst cmacs-gnuseye-intel--country-centroids
  '(("USA" 39.8 -98.6) ("CAN" 56.1 -106.3) ("MEX" 23.6 -102.5)
    ("BRA" -10.3 -53.2) ("ARG" -38.4 -63.6) ("COL" 4.6 -74.3)
    ("GBR" 54.0 -2.4) ("FRA" 46.6 2.2) ("DEU" 51.2 10.4) ("ESP" 40.0 -3.7)
    ("ITA" 41.9 12.6) ("UKR" 48.4 31.2) ("POL" 51.9 19.1) ("RUS" 61.5 105.3)
    ("TUR" 38.9 35.2) ("SYR" 35.0 38.5) ("IRQ" 33.2 43.7) ("IRN" 32.4 53.7)
    ("ISR" 31.4 35.0) ("SAU" 23.9 45.1) ("YEM" 15.6 48.5) ("EGY" 26.8 30.8)
    ("LBY" 26.3 17.2) ("SDN" 12.9 30.2) ("ETH" 9.1 40.5) ("NGA" 9.1 8.7)
    ("COD" -4.0 21.8) ("SOM" 5.2 46.2) ("ZAF" -30.6 22.9) ("KEN" 0.0 37.9)
    ("IND" 22.4 78.7) ("PAK" 30.4 69.3) ("AFG" 33.9 67.7) ("CHN" 35.9 104.2)
    ("JPN" 36.2 138.3) ("KOR" 36.5 127.8) ("PRK" 40.3 127.5) ("TWN" 23.7 121.0)
    ("IDN" -2.5 118.0) ("PHL" 12.9 121.8) ("VNM" 14.1 108.3) ("MMR" 21.9 95.96)
    ("AUS" -25.7 133.8) ("THA" 15.9 100.99) ("VEN" 6.4 -66.6) ("GRC" 39.1 21.8))
  "Compact ISO-A3 -> centroid table for assigning signals to countries.")

(defcustom cmacs-gnuseye-intel-cii-weights
  '((quake . 1.5) (fire . 1.0) (storm . 1.0) (volcano . 1.5) (alert . 0.8)
    (outage . 1.5) (cyber . 1.2) (event . 1.0) (hotspot . 3.0) (launch . 0.5)
    (radiation . 1.5))
  "Per-kind weights for the country-instability index."
  :type '(alist :key-type symbol :value-type number) :group 'cmacs-gnuseye)

(defun cmacs-gnuseye-intel--nearest-country (lat lon)
  "ISO-A3 of the nearest centroid to (LAT LON), or nil if implausibly far."
  (let ((best nil) (bestd 1.0e30))
    (dolist (c cmacs-gnuseye-intel--country-centroids)
      (let ((d (ignore-errors
                 (cmacs-gnuseye-haversine lat lon (nth 1 c) (nth 2 c)))))
        (when (and (numberp d) (< d bestd)) (setq bestd d best (nth 0 c)))))
    (and (< bestd 2.0e6) best)))           ; within ~2000 km

(defvar cmacs-gnuseye-cii--scores nil
  "Hash ISO-A3 -> instability score in [0,1] (drives the choropleth).")

(defun cmacs-gnuseye-intel--compute-cii ()
  "Aggregate active signals per country into a 0..1 instability score hash."
  (let ((raw (make-hash-table :test 'equal)) (maxv 1.0))
    (dolist (e (cmacs-gnuseye-intel--signals))
      (let ((iso (cmacs-gnuseye-intel--nearest-country
                  (or (plist-get e :lat) 0) (or (plist-get e :lon) 0)))
            (w (or (alist-get (plist-get e :kind) cmacs-gnuseye-intel-cii-weights)
                   1.0)))
        (when iso
          (puthash iso (+ (gethash iso raw 0.0) w) raw))))
    (maphash (lambda (_ v) (setq maxv (max maxv v))) raw)
    (let ((scores (make-hash-table :test 'equal)))
      (maphash (lambda (iso v) (puthash iso (/ v maxv) scores)) raw)
      (setq cmacs-gnuseye-cii--scores scores))))

;;;###autoload
(defun cmacs-gnuseye-intel-cii ()
  "Compute the country-instability index and paint it as a choropleth."
  (interactive)
  (cmacs-gnuseye-intel--compute-cii)
  (if (zerop (hash-table-count cmacs-gnuseye-cii--scores))
      (message "GNU's Eye: no active signals to score (enable some layers)")
    (when (and cmacs-gnuseye-buffer (fboundp 'cmacs-gnuseye-choropleth))
      (cmacs-gnuseye-choropleth cmacs-gnuseye-buffer cmacs-gnuseye-cii--scores 110))
    (let (ranked)
      (maphash (lambda (iso v) (push (cons iso v) ranked))
               cmacs-gnuseye-cii--scores)
      (message "GNU's Eye CII: %s"
               (mapconcat (lambda (c) (format "%s %.2f" (car c) (cdr c)))
                          (seq-take (sort ranked (lambda (a b) (> (cdr a) (cdr b))))
                                    5)
                          "  ")))))

;;;###autoload
(defun cmacs-gnuseye-intel-cii-clear ()
  "Remove the CII choropleth."
  (interactive)
  (when (fboundp 'cmacs-gnuseye-choropleth-clear) (cmacs-gnuseye-choropleth-clear)))

;;; AI commands (cmacs-ai; graceful when absent) ------------------------------

(defun cmacs-gnuseye-intel--ai-available-p ()
  (fboundp 'cmacs-ai-prompt-sync))

(defun cmacs-gnuseye-intel--ai-buffer (title text)
  (let ((b (get-buffer-create "*GNU's Eye Intel*")))
    (with-current-buffer b
      (let ((inhibit-read-only t))
        (erase-buffer)
        (when (fboundp 'org-mode) (org-mode))
        (insert "#+TITLE: " title "\n\n" text "\n"))
      (goto-char (point-min)))
    (display-buffer b '((display-buffer-in-side-window) (side . right)
                        (window-width . 0.34)))))

(defconst cmacs-gnuseye-intel--entity-system
  "You are a geospatial intelligence analyst.  Given a single tracked entity \
explain what it is, why it might matter, notable context for its position / \
heading / altitude, and any operational or safety implications.  Be concise, \
use Org markup, and reason ONLY from the provided fields.")

;;;###autoload
(defun cmacs-gnuseye-ai-ask-entity ()
  "Ask the AI about the selected entity."
  (interactive)
  (if (not (cmacs-gnuseye-intel--ai-available-p))
      (user-error "cmacs-ai is not available in this build")
    (let ((e (and cmacs-gnuseye--selected-id
                  (gethash cmacs-gnuseye--selected-id cmacs-gnuseye--id-index))))
      (unless e (user-error "No entity selected"))
      (let* ((prompt (format "Entity:\n%S\n\nAnalyse it." e))
             (out (cmacs-ai-prompt-sync prompt nil
                                        cmacs-gnuseye-intel--entity-system)))
        (cmacs-gnuseye-intel--ai-buffer
         (format "Intel: %s" (or (plist-get e :label) (plist-get e :id))) out)))))

(defconst cmacs-gnuseye-intel--brief-system
  "You are a senior geospatial intelligence analyst producing a SITREP for \
the region currently in view.  Lead with a one-line BLUF, then bullet findings \
by domain (air / sea / space / seismic / fire / conflict).  Use Org markup and \
ground every statement in the supplied data; flag gaps explicitly.")

;;;###autoload
(defun cmacs-gnuseye-ai-brief ()
  "Brief the AI on the entities currently in view."
  (interactive)
  (if (not (cmacs-gnuseye-intel--ai-available-p))
      (user-error "cmacs-ai is not available in this build")
    (let ((counts (make-hash-table :test 'eq)) (notable nil) (total 0))
      (maphash (lambda (_ e)
                 (when (cmacs-gnuseye--entity-visible-p e)
                   (cl-incf total)
                   (cl-incf (gethash (or (plist-get e :kind) 'generic) counts 0))
                   (when (and (< (length notable) 25) (plist-get e :label))
                     (push (format "%s (%s)" (plist-get e :label)
                                   (plist-get e :kind))
                           notable))))
               cmacs-gnuseye--id-index)
      (let* ((kinds (let (k) (maphash (lambda (kk n)
                                        (push (format "%s:%d" kk n) k)) counts) k))
             (prompt (format "On screen: %d entities.\nBy kind: %s\nNotable: %s\n\nBrief it."
                             total (string-join kinds ", ")
                             (string-join (nreverse notable) "; ")))
             (out (cmacs-ai-prompt-sync prompt nil
                                        cmacs-gnuseye-intel--brief-system)))
        (cmacs-gnuseye-intel--ai-buffer "Region SITREP" out)))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "A") #'cmacs-gnuseye-ai-brief)
  (define-key cmacs-gnuseye-mode-map (kbd "C") #'cmacs-gnuseye-intel-cii)
  (when (fboundp 'cmacs-gnuseye-register-inspector-action)
    (cmacs-gnuseye-register-inspector-action
     "a" "ask AI" #'cmacs-gnuseye-ai-ask-entity)))

(provide 'cmacs-gnuseye-intel)
;;; cmacs-gnuseye-intel.el ends here
