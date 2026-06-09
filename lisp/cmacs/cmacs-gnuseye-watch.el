;;; cmacs-gnuseye-watch.el --- GNU's Eye threshold watchlists  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Watch a layer for entities matching a field/operator/value condition; when
;; the condition first becomes true, raise a desktop alert (cmacs-notify, with
;; a message fallback) and log it to the alerts buffer.  Re-arms when the
;; condition clears.  Evaluated (debounced) off the reindex hook.

;;; Code:

(require 'cmacs-gnuseye)

(cl-defstruct (cmacs-gnuseye-watch (:constructor cmacs-gnuseye--make-watch))
  name layer field op value fired)

(defvar cmacs-gnuseye--watches nil "List of `cmacs-gnuseye-watch'.")

(defconst cmacs-gnuseye-alerts-buffer "*GNU's Eye Alerts*")

(defun cmacs-gnuseye--alert (title msg)
  "Raise an alert: desktop notification + the alerts log."
  (if (fboundp 'cmacs-notify)
      (ignore-errors (cmacs-notify title msg 'critical))
    (message "GNU's Eye ALERT: %s — %s" title msg))
  (with-current-buffer (get-buffer-create cmacs-gnuseye-alerts-buffer)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (format-time-string "[%H:%M:%S] ") title ": " msg "\n"))))

(defun cmacs-gnuseye--watch-field (e field)
  "Value of FIELD (a string) on entity E: a plist key or a :data alist key."
  (or (plist-get e (intern (concat ":" field)))
      (let ((d (plist-get e :data)))
        (and (consp d) (consp (car d)) (cdr (assq (intern field) d))))))

(defun cmacs-gnuseye--watch-cmp (v op val)
  (cond
   ((null v) nil)
   ((member op '(">" "<" ">=" "<="))
    (let ((vn (if (numberp v) v (string-to-number (format "%s" v))))
          (tn (if (numberp val) val (string-to-number (format "%s" val)))))
      (pcase op (">" (> vn tn)) ("<" (< vn tn))
             (">=" (>= vn tn)) ("<=" (<= vn tn)))))
   ((equal op "=") (equal (format "%s" v) (format "%s" val)))
   ((equal op "~") (string-match-p (regexp-quote (format "%s" val))
                                   (downcase (format "%s" v))))
   (t nil)))

(defun cmacs-gnuseye--watch-check ()
  "Evaluate every watch against the current entities; alert on rising edge."
  (dolist (w cmacs-gnuseye--watches)
    (let* ((ents (gethash (cmacs-gnuseye-watch-layer w)
                          cmacs-gnuseye--layer-entities))
           (hits (seq-filter
                  (lambda (e)
                    (cmacs-gnuseye--watch-cmp
                     (cmacs-gnuseye--watch-field e (cmacs-gnuseye-watch-field w))
                     (cmacs-gnuseye-watch-op w) (cmacs-gnuseye-watch-value w)))
                  ents)))
      (if hits
          (unless (cmacs-gnuseye-watch-fired w)
            (setf (cmacs-gnuseye-watch-fired w) t)
            (cmacs-gnuseye--alert
             (cmacs-gnuseye-watch-name w)
             (format "%d %s match %s %s %s" (length hits)
                     (cmacs-gnuseye-watch-layer w) (cmacs-gnuseye-watch-field w)
                     (cmacs-gnuseye-watch-op w) (cmacs-gnuseye-watch-value w))))
        (setf (cmacs-gnuseye-watch-fired w) nil)))))

;;;###autoload
(defun cmacs-gnuseye-watch-add (name layer field op value)
  "Add a watch NAME on LAYER: alert when any entity's FIELD OP VALUE holds.
OP is one of > < >= <= = ~ (substring)."
  (interactive
   (list (read-string "Watch name: ")
         (intern (completing-read
                  "Layer: " (let (ks) (maphash (lambda (k _) (push k ks))
                                               cmacs-gnuseye--layers) ks) nil t))
         (read-string "Field (e.g. speed, alt, magnitude): ")
         (completing-read "Op: " '(">" "<" ">=" "<=" "=" "~") nil t)
         (read-string "Value: ")))
  (push (cmacs-gnuseye--make-watch :name name :layer layer :field field
                                   :op op :value value)
        cmacs-gnuseye--watches)
  (add-hook 'cmacs-gnuseye--reindex-functions #'cmacs-gnuseye--watch-check)
  (message "GNU's Eye: watching %s" name))

;;;###autoload
(defun cmacs-gnuseye-watch-clear ()
  "Remove all watches."
  (interactive)
  (setq cmacs-gnuseye--watches nil)
  (message "GNU's Eye: watches cleared"))

;;;###autoload
(defun cmacs-gnuseye-alerts ()
  "Show the alerts log buffer."
  (interactive)
  (display-buffer (get-buffer-create cmacs-gnuseye-alerts-buffer)))

(provide 'cmacs-gnuseye-watch)
;;; cmacs-gnuseye-watch.el ends here
