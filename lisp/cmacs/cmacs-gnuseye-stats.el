;;; cmacs-gnuseye-stats.el --- GNU's Eye live stats pane  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A side pane of live situational statistics: per-layer entity counts,
;; freshness, and errors; the on-screen total; and a kind tally with unicode
;; bars.  Repaints (debounced) off the shared reindex hook.

;;; Code:

(require 'cmacs-gnuseye)

(defconst cmacs-gnuseye-stats--name "*GNU's Eye Stats*")
(defvar cmacs-gnuseye-stats--timer nil)

(defun cmacs-gnuseye-stats--bar (n max width)
  "A WIDTH-char unicode bar for N out of MAX."
  (let ((k (if (and (numberp max) (> max 0))
               (round (* width (/ (float n) max))) 0)))
    (concat (make-string (min width k) ?█)
            (make-string (max 0 (- width (min width k))) ?·))))

(defun cmacs-gnuseye-stats--render ()
  "Render the stats buffer from the current layer state."
  (let ((b (get-buffer cmacs-gnuseye-stats--name)))
    (when (and b (buffer-live-p b))
      (with-current-buffer b
        (let ((inhibit-read-only t) (total 0) (rows nil) (maxc 1)
              (kinds (make-hash-table :test 'eq)))
          (maphash
           (lambda (name layer)
             (let* ((ents (gethash name cmacs-gnuseye--layer-entities))
                    (c (length ents))
                    (lf (cmacs-gnuseye-layer-last-fetch layer))
                    (age (and lf (truncate (- (float-time) lf))))
                    (err (cmacs-gnuseye-layer-last-error layer))
                    (on (cmacs-gnuseye-layer-enabled layer)))
               (when on
                 (setq total (+ total c) maxc (max maxc c))
                 (dolist (e ents)
                   (cl-incf (gethash (or (plist-get e :kind) 'generic) kinds 0)))
                 (push (list name c age err) rows))))
           cmacs-gnuseye--layers)
          (erase-buffer)
          (insert (propertize "GNU's Eye — live stats\n" 'face 'bold))
          (insert "──────────────────────────────\n")
          (if (null rows)
              (insert "No layers enabled.\nEnable types in the pane above.\n")
            (dolist (r (sort rows (lambda (a b) (> (nth 1 a) (nth 1 b)))))
              (insert (format "%-13s %6d  %-7s %s\n"
                              (truncate-string-to-width
                               (symbol-name (nth 0 r)) 13)
                              (nth 1 r)
                              (cond ((nth 3 r) "ERR")
                                    ((nth 2 r) (format "%ds" (nth 2 r)))
                                    (t "—"))
                              (cmacs-gnuseye-stats--bar (nth 1 r) maxc 12))))
            (insert "──────────────────────────────\n")
            (insert (format "On screen: %d / %d\n"
                            (let ((vis 0))
                              (maphash (lambda (_ e)
                                         (when (cmacs-gnuseye--entity-visible-p e)
                                           (cl-incf vis)))
                                       cmacs-gnuseye--id-index)
                              vis)
                            total))
            (insert "\nKinds:\n")
            (let (klist)
              (maphash (lambda (k n) (push (cons k n) klist)) kinds)
              (dolist (kv (seq-take (sort klist (lambda (a b) (> (cdr a) (cdr b)))) 8))
                (insert (format "  %-10s %5d\n" (car kv) (cdr kv))))))
          (goto-char (point-min)))))))

(defun cmacs-gnuseye-stats--schedule ()
  "Debounced stats repaint (hooked to the reindex hook)."
  (when (timerp cmacs-gnuseye-stats--timer)
    (cancel-timer cmacs-gnuseye-stats--timer))
  (setq cmacs-gnuseye-stats--timer
        (run-with-timer 0.4 nil #'cmacs-gnuseye-stats--render)))

(define-derived-mode cmacs-gnuseye-stats-mode special-mode "GnuseyeStats"
  "GNU's Eye live statistics pane.")

;;;###autoload
(defun cmacs-gnuseye-stats ()
  "Open (and focus) the GNU's Eye live stats pane."
  (interactive)
  (let ((b (get-buffer-create cmacs-gnuseye-stats--name)))
    (with-current-buffer b
      (unless (derived-mode-p 'cmacs-gnuseye-stats-mode)
        (cmacs-gnuseye-stats-mode))
      (cmacs-gnuseye-stats--render))
    (add-hook 'cmacs-gnuseye--reindex-functions #'cmacs-gnuseye-stats--schedule)
    (select-window
     (display-buffer-in-side-window
      b '((side . right) (slot . 1) (window-width . 0.22))))))

(with-eval-after-load 'cmacs-gnuseye
  (define-key cmacs-gnuseye-mode-map (kbd "S") #'cmacs-gnuseye-stats))

(provide 'cmacs-gnuseye-stats)
;;; cmacs-gnuseye-stats.el ends here
