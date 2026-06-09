;;; cmacs-gnuseye-export.el --- GNU's Eye data/image export  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Export the indexed entities to GeoJSON or CSV, or snapshot the globe to PNG.

;;; Code:

(require 'cmacs-gnuseye)
(require 'json)

(defun cmacs-gnuseye-export--entities ()
  "All currently-indexed entities as a list of plists (tagged :layer)."
  (let (out) (maphash (lambda (_ e) (push e out)) cmacs-gnuseye--id-index)
       (nreverse out)))

(defun cmacs-gnuseye-export--geojson-string (&optional entities)
  "A GeoJSON FeatureCollection string for ENTITIES (default: all indexed)."
  (let (feats)
    (dolist (e (or entities (cmacs-gnuseye-export--entities)))
      (when (and (numberp (plist-get e :lat)) (numberp (plist-get e :lon)))
        (push (list (cons 'type "Feature")
                    (cons 'geometry
                          (list (cons 'type "Point")
                                (cons 'coordinates
                                      (vector (plist-get e :lon)
                                              (plist-get e :lat)))))
                    (cons 'properties
                          (list (cons 'id (format "%s" (plist-get e :id)))
                                (cons 'kind (format "%s" (plist-get e :kind)))
                                (cons 'label (or (plist-get e :label) ""))
                                (cons 'layer (format "%s" (plist-get e :layer))))))
              feats)))
    (json-encode (list (cons 'type "FeatureCollection")
                       (cons 'features (nreverse feats))))))

(defun cmacs-gnuseye-export--csvq (s)
  (let ((s (format "%s" s)))
    (if (string-match-p "[,\"\n]" s)
        (concat "\"" (replace-regexp-in-string "\"" "\"\"" s) "\"")
      s)))

(defun cmacs-gnuseye-export--csv-string (&optional entities)
  "A CSV string (id,kind,label,lat,lon,layer) for ENTITIES."
  (concat
   "id,kind,label,lat,lon,layer\n"
   (mapconcat
    (lambda (e)
      (mapconcat #'cmacs-gnuseye-export--csvq
                 (list (plist-get e :id) (plist-get e :kind)
                       (or (plist-get e :label) "")
                       (plist-get e :lat) (plist-get e :lon)
                       (plist-get e :layer))
                 ","))
    (or entities (cmacs-gnuseye-export--entities)) "\n")))

;;;###autoload
(defun cmacs-gnuseye-export-geojson (file)
  "Export the indexed entities to FILE as GeoJSON."
  (interactive "FExport GeoJSON to: ")
  (with-temp-file file (insert (cmacs-gnuseye-export--geojson-string)))
  (message "GNU's Eye: wrote %s" file))

;;;###autoload
(defun cmacs-gnuseye-export-csv (file)
  "Export the indexed entities to FILE as CSV."
  (interactive "FExport CSV to: ")
  (with-temp-file file (insert (cmacs-gnuseye-export--csv-string)))
  (message "GNU's Eye: wrote %s" file))

;;;###autoload
(defun cmacs-gnuseye-export-png (file)
  "Snapshot the globe to FILE (PNG)."
  (interactive "FSnapshot PNG to: ")
  (when (and cmacs-gnuseye-buffer (cmacs-gnuseye-attached-p cmacs-gnuseye-buffer))
    (cmacs-gnuseye-snapshot cmacs-gnuseye-buffer (expand-file-name file))
    (message "GNU's Eye: wrote %s" file)))

(provide 'cmacs-gnuseye-export)
;;; cmacs-gnuseye-export.el ends here
