;;; cmacs-notify-bar.el --- gowl bar surface for the notification daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Feeds the gowl bar's `notifications' widget, and answers the three
;; things that widget's panel can ask for: show the backlog, clear it,
;; and toggle Do Not Disturb.
;;
;; The direction matters.  The widget does not query Emacs: its poll,
;; its panel and its clicks all run on the compositor thread, and a
;; round trip into the Lisp VM from there is a deadlock waiting for a
;; quiet afternoon.  So this pushes instead -- it writes the widget's
;; settings whenever the count or the mode changes, and the widget only
;; ever renders what it was last told.  With this file unloaded the
;; widget reads zero and stays quiet, which is the right failure.
;;
;; Unread is defined as "arrived since you last looked", not "still on
;; screen": a notification that timed out unseen is exactly the one the
;; backlog exists for.

;;; Code:

(require 'cmacs-notify-daemon)

(defgroup cmacs-notify-bar nil
  "Notification state published to the gowl bar."
  :group 'cmacs
  :prefix "cmacs-notify-bar-")

(defcustom cmacs-notify-bar-widget "notifications"
  "Widget name whose settings carry the notification state.
Change this only if the widget is registered under another name."
  :type 'string
  :group 'cmacs-notify-bar)

(defcustom cmacs-notify-bar-dnd nil
  "Non-nil while Do Not Disturb is on.
Set through `cmacs-notify-bar-toggle-dnd' rather than directly, so the
bar is told."
  :type 'boolean
  :group 'cmacs-notify-bar)

(defvar cmacs-notify-bar--unread 0
  "Notifications that have arrived since the backlog was last shown.")

(defun cmacs-notify-bar--push ()
  "Publish the current count and mode to the bar widget.
Silent when the compositor is not running: this is called from a
notification hook, and a notification must never fail because there is
no bar to tell."
  (when (fboundp 'gowl-bar-configure)
    (let* ((w cmacs-notify-bar-widget)
           (last (car cmacs-notify-daemon-history))
           (summary (or (plist-get last :summary) "")))
      (ignore-errors
        (gowl-bar-configure
         (list (cons (concat w ".count")
                     (number-to-string cmacs-notify-bar--unread))
               (cons (concat w ".dnd")
                     (if cmacs-notify-bar-dnd "1" "0"))
               ;; The tooltip and the panel's "Last" row.  Truncated
               ;; here rather than in C: the widget renders what it is
               ;; given, and a novel-length summary is the sender's
               ;; doing, not the bar's problem.
               (cons (concat w ".last")
                     (truncate-string-to-width summary 72 nil nil t))))))))

(defun cmacs-notify-bar--on-notification (_info)
  "Count an arriving notification and republish.
Added to `cmacs-notify-daemon-functions', which runs before display."
  (setq cmacs-notify-bar--unread (1+ cmacs-notify-bar--unread))
  (cmacs-notify-bar--push))

;;;###autoload
(defun cmacs-notify-bar-show-history ()
  "Show the notification backlog and mark it read.
This is what the bar widget's History button runs."
  (interactive)
  (setq cmacs-notify-bar--unread 0)
  (cmacs-notify-bar--push)
  (cmacs-notify-daemon-history-buffer))

;;;###autoload
(defun cmacs-notify-bar-clear ()
  "Drop the notification backlog.
This is what the bar widget's Clear button runs."
  (interactive)
  (setq cmacs-notify-daemon-history nil
        cmacs-notify-bar--unread 0)
  (cmacs-notify-bar--push)
  (when-let* ((buf (get-buffer cmacs-notify-daemon-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer))))
  (message "Notifications cleared"))

;;;###autoload
(defun cmacs-notify-bar-toggle-dnd ()
  "Toggle Do Not Disturb.
Notifications keep arriving and keep being recorded -- the backlog is
the point -- but they stop interrupting.  This is what the bar widget's
toggle runs."
  (interactive)
  (setq cmacs-notify-bar-dnd (not cmacs-notify-bar-dnd))
  ;; Suppress the interrupting halves only.  History and the hook stay
  ;; live, so nothing is lost while the mode is on.
  (setq cmacs-notify-daemon-echo (not cmacs-notify-bar-dnd)
        cmacs-notify-daemon-pop-to-buffer-urgencies
        (if cmacs-notify-bar-dnd nil '(critical)))
  (cmacs-notify-bar--push)
  (message "Do not disturb %s" (if cmacs-notify-bar-dnd "on" "off")))

;;;###autoload
(define-minor-mode cmacs-notify-bar-mode
  "Publish notification state to the gowl bar's `notifications' widget."
  :global t
  :group 'cmacs-notify-bar
  (if cmacs-notify-bar-mode
      (progn
        (add-hook 'cmacs-notify-daemon-functions
                  #'cmacs-notify-bar--on-notification)
        (cmacs-notify-bar--push))
    (remove-hook 'cmacs-notify-daemon-functions
                 #'cmacs-notify-bar--on-notification)))

(provide 'cmacs-notify-bar)

;;; cmacs-notify-bar.el ends here
