;;; cmacs-gnuseye-bookmarks.el --- GNU's Eye viewpoints + tours  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Named camera viewpoints and ordered tours, persisted under the GNU's Eye
;; config dir.  A tour auto-flies through its stops with a dwell at each.

;;; Code:

(require 'cmacs-gnuseye)

(defvar cmacs-gnuseye--bookmarks nil
  "List of (:name :lat :lon :range) viewpoints.")
(defvar cmacs-gnuseye--tours nil
  "List of (:name :loop :stops ((:name :lat :lon :range :dwell) …)).")
(defvar cmacs-gnuseye--bookmarks-loaded nil)

(defun cmacs-gnuseye--bm-load ()
  (unless cmacs-gnuseye--bookmarks-loaded
    (setq cmacs-gnuseye--bookmarks-loaded t)
    (let ((bf (cmacs-gnuseye--config-file "bookmarks.el"))
          (tf (cmacs-gnuseye--config-file "tours.el")))
      (when (file-readable-p bf)
        (ignore-errors
          (with-temp-buffer (insert-file-contents bf)
                            (setq cmacs-gnuseye--bookmarks (read (current-buffer))))))
      (when (file-readable-p tf)
        (ignore-errors
          (with-temp-buffer (insert-file-contents tf)
                            (setq cmacs-gnuseye--tours (read (current-buffer)))))))))

(defun cmacs-gnuseye--bm-save ()
  (ignore-errors
    (with-temp-file (cmacs-gnuseye--config-file "bookmarks.el")
      (prin1 cmacs-gnuseye--bookmarks (current-buffer)))
    (with-temp-file (cmacs-gnuseye--config-file "tours.el")
      (prin1 cmacs-gnuseye--tours (current-buffer)))))

;;;###autoload
(defun cmacs-gnuseye-bookmark-set (name)
  "Save the current camera viewpoint as a bookmark NAME."
  (interactive "sBookmark name: ")
  (cmacs-gnuseye--bm-load)
  (let ((vc (and cmacs-gnuseye-buffer
                 (ignore-errors (cmacs-gnuseye-view-center cmacs-gnuseye-buffer)))))
    (if (not (consp vc))
        (user-error "No globe view to bookmark")
      (setq cmacs-gnuseye--bookmarks
            (cons (list :name name :lat (nth 0 vc) :lon (nth 1 vc)
                        :range (nth 2 vc))
                  (cl-remove name cmacs-gnuseye--bookmarks
                             :key (lambda (b) (plist-get b :name))
                             :test #'equal)))
      (cmacs-gnuseye--bm-save)
      (message "GNU's Eye: bookmarked %s" name))))

;;;###autoload
(defun cmacs-gnuseye-bookmark-jump (name)
  "Fly the camera to bookmark NAME."
  (interactive
   (progn (cmacs-gnuseye--bm-load)
          (list (completing-read "Jump to bookmark: "
                                 (mapcar (lambda (b) (plist-get b :name))
                                         cmacs-gnuseye--bookmarks)
                                 nil t))))
  (let ((b (cl-find name cmacs-gnuseye--bookmarks
                    :key (lambda (b) (plist-get b :name)) :test #'equal)))
    (when (and b cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
      (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer (plist-get b :lat)
                            (plist-get b :lon) (plist-get b :range) t)
      (run-with-timer 1.5 nil #'cmacs-gnuseye-refresh-view-layers))))

;;; Tours ---------------------------------------------------------------------

(defvar cmacs-gnuseye--tour-timer nil)
(defcustom cmacs-gnuseye-tour-dwell 6.0
  "Default seconds to dwell at each tour stop."
  :type 'number :group 'cmacs-gnuseye)

(defun cmacs-gnuseye--tour-step (remaining full loopp)
  "Fly to the first of REMAINING stops, then schedule the rest; FULL is the
whole stop list (for looping)."
  (if (null remaining)
      (when (and loopp full)
        (cmacs-gnuseye--tour-step full full loopp))
    (let* ((s (car remaining))
           (dwell (or (plist-get s :dwell) cmacs-gnuseye-tour-dwell)))
      (when (and cmacs-gnuseye-buffer (buffer-live-p cmacs-gnuseye-buffer))
        (ignore-errors
          (cmacs-gnuseye-fly-to cmacs-gnuseye-buffer (plist-get s :lat)
                                (plist-get s :lon) (or (plist-get s :range) 8.0) t))
        (run-with-timer 1.6 nil #'cmacs-gnuseye-refresh-view-layers))
      (setq cmacs-gnuseye--tour-timer
            (run-with-timer
             dwell nil
             (lambda () (cmacs-gnuseye--tour-step (cdr remaining) full loopp)))))))

;;;###autoload
(defun cmacs-gnuseye-tour-start (name)
  "Start auto-flying tour NAME."
  (interactive
   (progn (cmacs-gnuseye--bm-load)
          (list (completing-read "Tour: "
                                 (mapcar (lambda (tt) (plist-get tt :name))
                                         cmacs-gnuseye--tours)
                                 nil t))))
  (let ((tour (cl-find name cmacs-gnuseye--tours
                       :key (lambda (tt) (plist-get tt :name)) :test #'equal)))
    (when tour
      (cmacs-gnuseye-tour-stop)
      (let ((stops (plist-get tour :stops)))
        (cmacs-gnuseye--tour-step stops stops (plist-get tour :loop))))))

;;;###autoload
(defun cmacs-gnuseye-tour-stop ()
  "Stop the running tour."
  (interactive)
  (when (timerp cmacs-gnuseye--tour-timer)
    (cancel-timer cmacs-gnuseye--tour-timer))
  (setq cmacs-gnuseye--tour-timer nil cmacs-gnuseye--tour-current nil))

;;;###autoload
(defun cmacs-gnuseye-tour-from-bookmarks (name &rest bookmark-names)
  "Define tour NAME from the named bookmarks (programmatic helper)."
  (cmacs-gnuseye--bm-load)
  (let ((stops (delq nil
                     (mapcar (lambda (bn)
                               (let ((b (cl-find bn cmacs-gnuseye--bookmarks
                                                 :key (lambda (x) (plist-get x :name))
                                                 :test #'equal)))
                                 (and b (list :name bn :lat (plist-get b :lat)
                                              :lon (plist-get b :lon)
                                              :range (plist-get b :range)))))
                             bookmark-names))))
    (setq cmacs-gnuseye--tours
          (cons (list :name name :loop t :stops stops)
                (cl-remove name cmacs-gnuseye--tours
                           :key (lambda (tt) (plist-get tt :name)) :test #'equal)))
    (cmacs-gnuseye--bm-save)))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "m") #'cmacs-gnuseye-bookmark-set)
  (define-key cmacs-gnuseye-mode-map (kbd "'") #'cmacs-gnuseye-bookmark-jump)
  (define-key cmacs-gnuseye-mode-map (kbd "O") #'cmacs-gnuseye-tour-start))

(provide 'cmacs-gnuseye-bookmarks)
;;; cmacs-gnuseye-bookmarks.el ends here
