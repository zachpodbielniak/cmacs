;;; cmacs-gnuseye-history.el --- GNU's Eye disk time-series store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A bounded, append-only on-disk log of compact per-layer position snapshots,
;; captured (throttled) off the reindex hook.  It is the basis for long replay
;; (days/weeks) and backtesting — the in-memory replay ring only spans minutes.
;; Each record is one `prin1' form per line: (TS LAYER ENTS) where ENTS is a
;; vector of [id lat lon kind label] (no :trail/:data, to bound size).

;;; Code:

(require 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-history-enabled t
  "Capture a disk history of layer positions for long replay/backtesting."
  :type 'boolean :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-history-interval 60.0
  "Minimum seconds between captured history snapshots."
  :type 'number :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-history-cap 600
  "Maximum entities captured per layer per snapshot."
  :type 'integer :group 'cmacs-gnuseye)

(defcustom cmacs-gnuseye-history-max-lines 60000
  "Hard cap on stored snapshot lines (oldest trimmed on capture)."
  :type 'integer :group 'cmacs-gnuseye)

(defvar cmacs-gnuseye-history--last 0.0)

(defun cmacs-gnuseye-history-file ()
  "Path of the history log under the gnuseye cache dir."
  (expand-file-name "cmacs/gnuseye/history.eld"
                    (or (getenv "XDG_CACHE_HOME") "~/.cache")))

(defun cmacs-gnuseye-history--compact (e)
  (vector (format "%s" (plist-get e :id))
          (plist-get e :lat) (plist-get e :lon)
          (plist-get e :kind) (or (plist-get e :label) "")))

(defun cmacs-gnuseye-history--capture ()
  "Append a snapshot of enabled layers' positions to the disk log (throttled)."
  (let ((now (float-time)))
    (when (and cmacs-gnuseye-history-enabled
               (>= (- now cmacs-gnuseye-history--last)
                   cmacs-gnuseye-history-interval))
      (setq cmacs-gnuseye-history--last now)
      (let ((file (cmacs-gnuseye-history-file)) (lines nil))
        (maphash
         (lambda (name ents)
           ;; Transient layers (wind particles) are synthetic -- not history.
           (when (and ents (not (cmacs-gnuseye--layer-transient-p name)))
             (push (prin1-to-string
                    (list now name
                          (vconcat (mapcar #'cmacs-gnuseye-history--compact
                                           (seq-take ents
                                                     cmacs-gnuseye-history-cap)))))
                   lines)))
         cmacs-gnuseye--layer-entities)
        (when lines
          (ignore-errors
            (make-directory (file-name-directory file) t)
            (write-region (concat (mapconcat #'identity (nreverse lines) "\n")
                                  "\n")
                          nil file t 'silent)
            (cmacs-gnuseye-history--maybe-trim file)))))))

(defun cmacs-gnuseye-history--maybe-trim (file)
  "Trim FILE to the last `cmacs-gnuseye-history-max-lines' lines when it grows."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((n (count-lines (point-min) (point-max))))
        (when (> n (+ cmacs-gnuseye-history-max-lines 2000))
          (goto-char (point-max))
          (forward-line (- cmacs-gnuseye-history-max-lines))
          (write-region (point) (point-max) file nil 'silent))))))

(defun cmacs-gnuseye-history-load (since until &optional layer)
  "Return snapshots (TS LAYER ENTS) with SINCE <= TS <= UNTIL.
LAYER, if non-nil, restricts to that layer symbol.  ENTS is the stored
vector of [id lat lon kind label]."
  (let ((file (cmacs-gnuseye-history-file)) out)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((rec (ignore-errors (read (current-buffer)))))
            (when (and (consp rec) (numberp (nth 0 rec))
                       (>= (nth 0 rec) since) (<= (nth 0 rec) until)
                       (or (null layer) (eq (nth 1 rec) layer)))
              (push rec out)))
          (forward-line 1))))
    (nreverse out)))

(defun cmacs-gnuseye-history-span ()
  "Return (OLDEST . NEWEST) timestamps in the log, or nil if empty."
  (let ((file (cmacs-gnuseye-history-file)) oldest newest)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((r (ignore-errors (read (current-buffer)))))
          (when (consp r) (setq oldest (nth 0 r))))
        (goto-char (point-max))
        (forward-line -1)
        (let ((r (ignore-errors (read (current-buffer)))))
          (when (consp r) (setq newest (nth 0 r))))))
    (and oldest newest (cons oldest newest))))

;;;###autoload
(defun cmacs-gnuseye-history-enable ()
  "Start capturing the disk history (subscribe to the reindex hook)."
  (add-hook 'cmacs-gnuseye--reindex-functions #'cmacs-gnuseye-history--capture))

(when cmacs-gnuseye-history-enabled
  (cmacs-gnuseye-history-enable))

(provide 'cmacs-gnuseye-history)
;;; cmacs-gnuseye-history.el ends here
