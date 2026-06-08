;;; cmacs-gnuseye-replay.el --- GNU's Eye time-scrub / replay  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A ring buffer of compact per-layer position snapshots, captured (throttled)
;; off the reindex hook.  `cmacs-gnuseye-replay-toggle' enters a replay mode
;; with a header-line scrubber: step back/forward through snapshots, play, set
;; speed, and jump back to live.  Bounded memory (drops :trail/:data; caps
;; entities per layer); live timers keep populating, so exiting snaps to now.

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-replay-depth 180
  "Maximum snapshots kept in the replay ring (× interval = retention)."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-replay-interval 10.0
  "Minimum seconds between captured replay snapshots."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-replay-cap 400
  "Maximum entities captured per layer per snapshot."
  :type 'integer :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-replay--ring nil
  "List of (TS . LAYER-HASH) snapshots, newest first.")
(defvar cmacs-gnuseye-replay--last 0.0)
(defvar cmacs-gnuseye-replay--active nil)
(defvar cmacs-gnuseye-replay--idx 0 "Index into the ring while replaying.")
(defvar cmacs-gnuseye-replay--play nil)
(defvar cmacs-gnuseye-replay--play-timer nil)

(defun cmacs-gnuseye-replay--capture ()
  "Snapshot enabled layers' current positions (throttled)."
  (let ((now (float-time)))
    (when (and (not cmacs-gnuseye-replay--active)
               (>= (- now cmacs-gnuseye-replay--last)
                   cmacs-gnuseye-replay-interval))
      (setq cmacs-gnuseye-replay--last now)
      (let ((snap (make-hash-table :test 'eq)) (any nil))
        (maphash
         (lambda (name ents)
           (when ents
             (setq any t)
             (puthash name
                      (mapcar (lambda (e)
                                (list :id (plist-get e :id) :lat (plist-get e :lat)
                                      :lon (plist-get e :lon) :alt (plist-get e :alt)
                                      :heading (plist-get e :heading)
                                      :kind (plist-get e :kind)
                                      :label (plist-get e :label)))
                              (seq-take ents cmacs-gnuseye-replay-cap))
                      snap)))
         cmacs-gnuseye--layer-entities)
        (when any
          (push (cons now snap) cmacs-gnuseye-replay--ring)
          (when (> (length cmacs-gnuseye-replay--ring) cmacs-gnuseye-replay-depth)
            (setcdr (nthcdr (1- cmacs-gnuseye-replay-depth)
                            cmacs-gnuseye-replay--ring)
                    nil)))))))

(defun cmacs-gnuseye-replay--apply (snap)
  "Render SNAP (layer-hash) onto the globe without disturbing live data."
  (let ((buf cmacs-gnuseye-buffer))
    (when (and buf (buffer-live-p buf))
      (maphash
       (lambda (name ents)
         (ignore-errors
           (cmacs-gnuseye-set-entities
            buf name (cmacs-gnuseye--entities->vector ents))))
       snap))))

(defun cmacs-gnuseye-replay--show ()
  "Apply the snapshot at the current replay index + update the scrubber."
  (let* ((ring cmacs-gnuseye-replay--ring)
         (n (length ring)))
    (when (> n 0)
      (setq cmacs-gnuseye-replay--idx
            (max 0 (min (1- n) cmacs-gnuseye-replay--idx)))
      (let* ((snap (nth cmacs-gnuseye-replay--idx ring))
             (ts (car snap))
             (age (truncate (- (float-time) ts))))
        (cmacs-gnuseye-replay--apply (cdr snap))
        (let ((buf cmacs-gnuseye-buffer))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (setq header-line-format
                    (format " REPLAY  T-%d:%02d  [%d/%d]  %s  < > step · SPC play · = live"
                            (/ age 60) (mod age 60)
                            (- n cmacs-gnuseye-replay--idx) n
                            (if cmacs-gnuseye-replay--play "▶" "⏸"))))))))))

(defun cmacs-gnuseye-replay-step-back ()
  (interactive) (cl-incf cmacs-gnuseye-replay--idx) (cmacs-gnuseye-replay--show))
(defun cmacs-gnuseye-replay-step-fwd ()
  (interactive) (cl-decf cmacs-gnuseye-replay--idx) (cmacs-gnuseye-replay--show))

(defun cmacs-gnuseye-replay--play-tick ()
  (if (or (not cmacs-gnuseye-replay--active) (<= cmacs-gnuseye-replay--idx 0))
      (setq cmacs-gnuseye-replay--play nil)
    (cl-decf cmacs-gnuseye-replay--idx)
    (cmacs-gnuseye-replay--show)))

(defun cmacs-gnuseye-replay-play-pause ()
  (interactive)
  (setq cmacs-gnuseye-replay--play (not cmacs-gnuseye-replay--play))
  (when (timerp cmacs-gnuseye-replay--play-timer)
    (cancel-timer cmacs-gnuseye-replay--play-timer))
  (when cmacs-gnuseye-replay--play
    (setq cmacs-gnuseye-replay--play-timer
          (run-with-timer 0.5 0.5 #'cmacs-gnuseye-replay--play-tick)))
  (cmacs-gnuseye-replay--show))

(defun cmacs-gnuseye-replay-live ()
  "Exit replay and snap back to live."
  (interactive)
  (setq cmacs-gnuseye-replay--active nil cmacs-gnuseye-replay--play nil)
  (when (timerp cmacs-gnuseye-replay--play-timer)
    (cancel-timer cmacs-gnuseye-replay--play-timer))
  (let ((buf cmacs-gnuseye-buffer))
    (when (buffer-live-p buf)
      (with-current-buffer buf (setq header-line-format nil))
      (cmacs-gnuseye--render-all buf)))
  (message "GNU's Eye: live"))

(defvar cmacs-gnuseye-replay-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "<") #'cmacs-gnuseye-replay-step-back)
    (define-key m (kbd ">") #'cmacs-gnuseye-replay-step-fwd)
    (define-key m (kbd "SPC") #'cmacs-gnuseye-replay-play-pause)
    (define-key m (kbd "=") #'cmacs-gnuseye-replay-live)
    m)
  "Transient keymap active while replaying.")

;;;###autoload
(defun cmacs-gnuseye-replay-toggle ()
  "Enter (or leave) replay mode at the most recent snapshot."
  (interactive)
  (if cmacs-gnuseye-replay--active
      (cmacs-gnuseye-replay-live)
    (if (null cmacs-gnuseye-replay--ring)
        (user-error "No replay history captured yet")
      (setq cmacs-gnuseye-replay--active t cmacs-gnuseye-replay--idx 0)
      (set-transient-map cmacs-gnuseye-replay-mode-map
                         (lambda () cmacs-gnuseye-replay--active))
      (cmacs-gnuseye-replay--show)
      (message "GNU's Eye: replay — < > step, SPC play, = live"))))

(add-hook 'cmacs-gnuseye--reindex-functions #'cmacs-gnuseye-replay--capture)

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "T") #'cmacs-gnuseye-replay-toggle))

(provide 'cmacs-gnuseye-replay)
;;; cmacs-gnuseye-replay.el ends here
