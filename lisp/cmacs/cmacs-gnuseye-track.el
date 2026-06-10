;;; cmacs-gnuseye-track.el --- GNU's Eye follow-camera + detail actions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-gnuseye-track-toggle' locks the camera onto the selected entity so
;; it stays centred as it moves.  Plus inspector actions to open a marker's
;; live stream (cmacs-video) or news article (gsurf) from its :data.

;;; Code:

(require 'cmacs-gnuseye)

;;; Follow camera -------------------------------------------------------------

(defvar cmacs-gnuseye-track--id nil "Entity id the camera is following, or nil.")
(defvar cmacs-gnuseye-track--last nil "Last (LAT . LON) followed, for jitter cut.")

(defun cmacs-gnuseye-track--tick (buf _now _dt)
  (when (and cmacs-gnuseye-track--id buf (buffer-live-p buf))
    (let ((e (gethash cmacs-gnuseye-track--id cmacs-gnuseye--id-index)))
      (if (null e)
          (setq cmacs-gnuseye-track--id nil)        ; gone -> stop
        (let ((lat (plist-get e :lat)) (lon (plist-get e :lon)))
          (when (and (numberp lat) (numberp lon))
            (let ((moved (or (null cmacs-gnuseye-track--last)
                             (> (+ (abs (- lat (car cmacs-gnuseye-track--last)))
                                   (abs (- lon (cdr cmacs-gnuseye-track--last))))
                                0.05))))
              (when moved
                (setq cmacs-gnuseye-track--last (cons lat lon))
                (let ((vc (ignore-errors (cmacs-gnuseye-view-center buf))))
                  (ignore-errors
                    (cmacs-gnuseye-fly-to buf lat lon
                                          (if (and (consp vc) (numberp (nth 2 vc)))
                                              (nth 2 vc) 7.5)
                                          t)))))))))))

;;;###autoload
(defun cmacs-gnuseye-track-toggle ()
  "Toggle following the selected entity with the camera."
  (interactive)
  (if cmacs-gnuseye-track--id
      (progn (setq cmacs-gnuseye-track--id nil cmacs-gnuseye-track--last nil)
             (message "GNU's Eye: stopped tracking"))
    (if (not cmacs-gnuseye--selected-id)
        (user-error "No entity selected")
      (setq cmacs-gnuseye-track--id cmacs-gnuseye--selected-id
            cmacs-gnuseye-track--last nil)
      (add-hook 'cmacs-gnuseye--tick-functions #'cmacs-gnuseye-track--tick)
      (message "GNU's Eye: tracking %s" cmacs-gnuseye--selected-id))))

;;; Inspector open-stream / open-news -----------------------------------------

(defun cmacs-gnuseye-track--data-val (e &rest keys)
  (let ((d (plist-get e :data)))
    (and (consp d) (consp (car d))
         (catch 'hit (dolist (k keys)
                       (let ((v (cdr (assq k d)))) (when v (throw 'hit v))))))))

(defun cmacs-gnuseye-track--stream-p (e)
  (and (cmacs-gnuseye-track--data-val e 'stream 'rtsp 'hls) t))
(defun cmacs-gnuseye-track--news-p (e)
  (and (cmacs-gnuseye-track--data-val e 'url 'link 'html 'article) t))

(defun cmacs-gnuseye--selected-entity ()
  (and cmacs-gnuseye--selected-id
       (gethash cmacs-gnuseye--selected-id cmacs-gnuseye--id-index)))

;;;###autoload
(defun cmacs-gnuseye-inspector-open-stream ()
  "Open the selected entity's live stream (camera/ISS) via cmacs-video."
  (interactive)
  (let* ((e (cmacs-gnuseye--selected-entity))
         (url (and e (cmacs-gnuseye-track--data-val e 'stream 'rtsp 'hls))))
    (cond ((not url) (user-error "No stream URL on this entity"))
          ((fboundp 'cmacs-video-open) (cmacs-video-open url))
          ((fboundp 'cmacs-video-open-url) (cmacs-video-open-url url))
          (t (browse-url url)))))

;;;###autoload
(defun cmacs-gnuseye-inspector-open-news ()
  "Open the selected entity's article via gsurf (or eww/browse-url)."
  (interactive)
  (let* ((e (cmacs-gnuseye--selected-entity))
         (url (and e (cmacs-gnuseye-track--data-val e 'url 'link 'article))))
    (cond ((not url)
           ;; Fall back to a GDELT search for the entity's location.
           (if (and e (plist-get e :label))
               (let ((q (url-hexify-string (format "%s" (plist-get e :label)))))
                 (browse-url (format "https://www.google.com/search?q=%s+news" q)))
             (user-error "No article URL on this entity")))
          ((fboundp 'cmacs-gsurf) (cmacs-gsurf url))
          ((fboundp 'cmacs-gsurf-lite-open) (cmacs-gsurf-lite-open url))
          (t (browse-url url)))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd ".") #'cmacs-gnuseye-track-toggle)
  (when (fboundp 'cmacs-gnuseye-register-inspector-action)
    (cmacs-gnuseye-register-inspector-action
     "." "track" #'cmacs-gnuseye-track-toggle)
    (cmacs-gnuseye-register-inspector-action
     "w" "watch stream" #'cmacs-gnuseye-inspector-open-stream
     #'cmacs-gnuseye-track--stream-p)
    (cmacs-gnuseye-register-inspector-action
     "n" "open news" #'cmacs-gnuseye-inspector-open-news
     #'cmacs-gnuseye-track--news-p)))

(provide 'cmacs-gnuseye-track)
;;; cmacs-gnuseye-track.el ends here
