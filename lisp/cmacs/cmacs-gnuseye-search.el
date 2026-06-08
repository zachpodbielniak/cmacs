;;; cmacs-gnuseye-search.el --- GNU's Eye search + command palette  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gnuseye-jump' is a command-palette / quick-jump over a merged
;; candidate set: every live entity (matched across all fields, including
;; :data — callsign, MMSI, NORAD id, country), named places/countries, and
;; commands.  Selecting an entity flies to + selects it; a place flies the
;; camera there; a command runs.  Bound to `/' on the globe and the list.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-places
  '(("New York" 40.71 -74.01 8.5) ("London" 51.51 -0.13 8.5)
    ("Tokyo" 35.68 139.69 8.5) ("Moscow" 55.75 37.62 8.5)
    ("Beijing" 39.90 116.40 8.5) ("Kyiv" 50.45 30.52 8.5)
    ("Tehran" 35.69 51.39 8.5) ("Gaza" 31.50 34.47 8.0)
    ("Taipei" 25.03 121.57 8.0) ("Washington" 38.90 -77.04 8.5)
    ("Cairo" 30.04 31.24 8.5) ("Delhi" 28.61 77.21 8.5)
    ("São Paulo" -23.55 -46.63 8.5) ("Sydney" -33.87 151.21 8.5)
    ("Strait of Hormuz" 26.57 56.25 7.5) ("Suez Canal" 30.50 32.35 7.5)
    ("Panama Canal" 9.08 -79.68 7.5) ("Taiwan Strait" 24.50 119.50 7.5)
    ("North Pole" 89.0 0.0 9.0) ("Antarctica" -82.0 0.0 9.0))
  "Named places for `cmacs-gnuseye-jump' (NAME LAT LON RANGE)."
  :type '(repeat (list string number number number))
  :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--jump-commands ()
  "Alist of (LABEL . FUNCTION) commands offered in the palette."
  (let ((cmds (list (cons "Command: refresh all" #'cmacs-gnuseye-refresh-all)
                    (cons "Command: clear filters" #'cmacs-gnuseye-filter-clear)
                    (cons "Command: legend" #'cmacs-gnuseye-legend)
                    (cons "Command: entity list" #'cmacs-gnuseye-entities))))
    (when (fboundp 'cmacs-gnuseye-stats)
      (push (cons "Command: stats pane" #'cmacs-gnuseye-stats) cmds))
    ;; One toggle command per registered layer.
    (maphash (lambda (name layer)
               (push (cons (format "Toggle layer: %s"
                                   (or (cmacs-gnuseye-layer-title layer) name))
                           (lambda () (interactive)
                             (if (cmacs-gnuseye-layer-enabled layer)
                                 (cmacs-gnuseye--disable-layer layer)
                               (cmacs-gnuseye--enable-layer layer))))
                     cmds))
             cmacs-gnuseye--layers)
    (nreverse cmds)))

(defun cmacs-gnuseye--jump-candidates ()
  "Build (CANDIDATE-STRING . TARGET) for the palette.
TARGET is (:entity ID), (:place LAT LON RANGE), or (:command FN)."
  (let (cands)
    ;; Entities.
    (maphash
     (lambda (id e)
       (let* ((kind (or (plist-get e :kind) 'generic))
              (label (or (plist-get e :label)
                         (format "%s" (or (plist-get e :id) id))))
              (extra (let ((d (plist-get e :data)))
                       (and (consp d) (consp (car d))
                            (or (cdr (assq 'callsign d)) (cdr (assq 'registration d))
                                (cdr (assq 'mmsi d)) (cdr (assq 'name d))))))
              (s (format "%s  ·  %s  ·  %s%s"
                         label kind (plist-get e :layer)
                         (if extra (format "  ·  %s" extra) ""))))
         (push (cons s (list :entity id)) cands)))
     cmacs-gnuseye--id-index)
    ;; Places.
    (dolist (p cmacs-gnuseye-places)
      (push (cons (format "Place: %s" (nth 0 p))
                  (list :place (nth 1 p) (nth 2 p) (nth 3 p)))
            cands))
    ;; Commands.
    (dolist (c (cmacs-gnuseye--jump-commands))
      (push (cons (car c) (list :command (cdr c))) cands))
    (nreverse cands)))

;;;###autoload
(defun cmacs-gnuseye-jump ()
  "Quick-jump / command palette over entities, places, and commands."
  (interactive)
  (let* ((cands (cmacs-gnuseye--jump-candidates))
         (choice (completing-read "GNU's Eye jump: " cands nil t))
         (target (cdr (assoc choice cands))))
    (pcase target
      (`(:entity ,id) (cmacs-gnuseye--select-entity id)
       (when (fboundp 'cmacs-gnuseye--list-goto) (cmacs-gnuseye--list-goto id)))
      (`(:place ,lat ,lon ,range)
       (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
         (ignore-errors (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer lat lon range t))
         (run-with-timer 1.5 nil #'cmacs-gnuseye-refresh-view-layers)))
      (`(:command ,fn) (call-interactively fn)))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "/") #'cmacs-gnuseye-jump)
  (when (boundp 'cmacs-gnuseye-list-mode-map)
    (define-key cmacs-gnuseye-list-mode-map (kbd "/") #'cmacs-gnuseye-jump)))

(provide 'cmacs-gnuseye-search)
;;; cmacs-gnuseye-search.el ends here
