;;; cmacs-gowl-spatial.el --- Spatial Org: tag ↔ org file mapping  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Maps gowl compositor tags to Org files, creating a spatial
;; workspace system.  When the active tag changes, the corresponding
;; Org file is displayed and window configuration is restored.
;;
;; Usage:
;;   (setq cmacs-gowl-spatial-map
;;         '((1 . "~/org/inbox.org")
;;           (2 . "~/org/projects.org")
;;           (3 . "~/org/notes.org")))
;;   (cmacs-gowl-spatial-mode 1)

;;; Code:

(require 'cl-lib)

(defgroup cmacs-gowl-spatial nil
  "Spatial Org: tag-to-file workspace mapping."
  :group 'cmacs
  :prefix "cmacs-gowl-spatial-")

(defcustom cmacs-gowl-spatial-map nil
  "Alist mapping tag numbers (1-9) to Org file paths.
Each entry is (TAG-NUMBER . FILE-PATH).  When the compositor
switches to a tag, the corresponding file is opened."
  :type '(alist :key-type integer :value-type file)
  :group 'cmacs-gowl-spatial)

(defvar cmacs-gowl-spatial--configs (make-hash-table :test 'eql)
  "Hash table mapping tag numbers to saved window configurations.")

(defvar cmacs-gowl-spatial--current-tag nil
  "The currently active tag number, or nil.")

(defvar cmacs-gowl-spatial--signal-handle nil
  "Signal handle for the focus-changed connection.")

(defun cmacs-gowl-spatial--on-tag-changed ()
  "Handle tag change by switching to the associated Org file."
  (let* ((monitor (gowl-focused-monitor))
         (info (when monitor (gowl-monitor-info monitor)))
         (active-tags (cdr (assq 'active-tags info)))
         (new-tag (when active-tags
                    ;; Find the lowest set bit (primary tag)
                    (cl-loop for i from 0 below 9
                             when (logbitp i active-tags)
                             return (1+ i)))))
    (when (and new-tag (not (eql new-tag cmacs-gowl-spatial--current-tag)))
      ;; Save current window config for old tag
      (when cmacs-gowl-spatial--current-tag
        (puthash cmacs-gowl-spatial--current-tag
                 (current-window-configuration)
                 cmacs-gowl-spatial--configs))
      ;; Switch to new tag's org file
      (let ((file (cdr (assq new-tag cmacs-gowl-spatial-map))))
        (when file
          (let ((saved (gethash new-tag cmacs-gowl-spatial--configs)))
            (if saved
                ;; Restore saved window config
                (set-window-configuration saved)
              ;; Open the file fresh
              (find-file (expand-file-name file))))))
      (setq cmacs-gowl-spatial--current-tag new-tag))))

;;;###autoload
(define-minor-mode cmacs-gowl-spatial-mode
  "Map gowl compositor tags to Org files.
When enabled, switching tags in the compositor automatically opens
the associated Org file and restores the window configuration."
  :global t
  :lighter " Spatial"
  :group 'cmacs-gowl-spatial
  (if cmacs-gowl-spatial-mode
      (when (and (fboundp 'gowl-running-p) (gowl-running-p))
        (setq cmacs-gowl-spatial--signal-handle
              (cmacs-gowl-on-focus-changed
               (lambda (_client)
                 (cmacs-gowl-spatial--on-tag-changed)))))
    (when cmacs-gowl-spatial--signal-handle
      (cmacs-gowl-signal-disconnect cmacs-gowl-spatial--signal-handle)
      (setq cmacs-gowl-spatial--signal-handle nil))
    (clrhash cmacs-gowl-spatial--configs)
    (setq cmacs-gowl-spatial--current-tag nil)))

(provide 'cmacs-gowl-spatial)
;;; cmacs-gowl-spatial.el ends here
