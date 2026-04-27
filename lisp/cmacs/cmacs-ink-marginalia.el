;;; cmacs-ink-marginalia.el --- Ink annotations on any buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; F2 of cmacs-ink: ink annotations layered on top of any buffer
;; (code, prose, anything visiting a file).
;;
;; Storage: a sidecar file `<source>.cmacs-ink' containing an Elisp
;; plist tree.  Format:
;;
;;   ((:format "cmacs-ink/marginalia/1"
;;     :file "src/foo.c"
;;     :anchors
;;     ((:id "ann-7f3a"
;;       :line 412
;;       :line-hash "9af2c0..."   ; SHA1 of line + 2 lines of context
;;       :width 320
;;       :height 120
;;       :created 1745600000
;;       :strokes
;;       ((s :t pen :c "#cc2a2a" :w 2 :p ((50 30 850) (60 35 870)))
;;        ...)))))
;;
;; Reconciliation at load time:
;;   1. Match by :line; if :line-hash matches → bind to current marker
;;   2. Else search ±10 lines for matching :line-hash → relocate
;;   3. Else mark orphan, float to top of buffer with badge
;;
;; SVGs are anchored as before-string overlays at column 0 of the
;; mapped line, so they sit visibly without disturbing source text.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Implemented in `cmacs-ink-storage.el', loaded by `cmacs-ink.el'.
;; Annotate / edit / delete commands call it to persist the change
;; (inline section for org buffers, sidecar otherwise) without
;; waiting for `after-save-hook'.
(declare-function cmacs-ink--save "cmacs-ink-storage" ())

(defgroup cmacs-ink-marginalia nil
  "Ink annotation overlays on arbitrary buffers."
  :group 'cmacs-ink
  :prefix "cmacs-ink-marginalia-")

(defcustom cmacs-ink-marginalia-default-width 320
  "Default annotation canvas width in pixels."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ink-marginalia-default-height 120
  "Default annotation canvas height in pixels."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ink-marginalia-default-colour "#cc2a2a"
  "Default ink colour for annotations."
  :type 'string
  :safe #'stringp)

(defcustom cmacs-ink-marginalia-default-base-width 2.0
  "Default ink base width in pixels."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ink-marginalia-search-radius 10
  "Lines to search around recorded :line for :line-hash matches."
  :type 'integer
  :safe #'integerp)

;; ---------------------------------------------------------------------
;; Per-buffer state
;; ---------------------------------------------------------------------

(cl-defstruct cmacs-ink-marginalia-anchor
  id line line-hash width height created strokes-string
  marker overlay orphan)

(defvar-local cmacs-ink-marginalia--anchors nil
  "List of `cmacs-ink-marginalia-anchor' records for this buffer.")

(defvar-local cmacs-ink-marginalia--dirty nil
  "Non-nil when the in-memory anchor set diverges from disk.
Persistence lives in `cmacs-ink-storage.el'; this flag tells it
when there's something to write.")

;; ---------------------------------------------------------------------
;; Line hashing for resilient anchoring
;; ---------------------------------------------------------------------

(defun cmacs-ink-marginalia--line-context (line)
  "Return a string covering LINE +/- 2 lines for hashing."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (max 0 (- line 3))) ; line - 3 + 1 = line - 2
      (let ((start (point)))
        (forward-line 5) ; covers line-2..line+2
        (buffer-substring-no-properties start (point))))))

(defun cmacs-ink-marginalia--hash-line (line)
  (secure-hash 'sha1 (cmacs-ink-marginalia--line-context line)))

(defun cmacs-ink-marginalia--find-hash (target-hash hint-line)
  "Search for TARGET-HASH near HINT-LINE; return matching line or nil."
  (let* ((max-line (line-number-at-pos (point-max)))
         (radius cmacs-ink-marginalia-search-radius)
         (lo (max 1 (- hint-line radius)))
         (hi (min max-line (+ hint-line radius)))
         (n  lo)
         found)
    (while (and (not found) (<= n hi))
      (when (string= (cmacs-ink-marginalia--hash-line n) target-hash)
        (setq found n))
      (cl-incf n))
    found))

;; ---------------------------------------------------------------------
;; Anchor → overlay
;; ---------------------------------------------------------------------

(defun cmacs-ink-marginalia--strokes-of (anchor)
  (let ((s (cmacs-ink-marginalia-anchor-strokes-string anchor)))
    (if (or (null s) (string-blank-p s))
        (org-ex-ink-strokes-empty)
      (condition-case _err
          (org-ex-ink-strokes-from-string s)
        (error (org-ex-ink-strokes-empty))))))

(defun cmacs-ink-marginalia--make-overlay (anchor)
  "Install or refresh the overlay for ANCHOR using the marker's line."
  (when (cmacs-ink-marginalia-anchor-overlay anchor)
    (delete-overlay (cmacs-ink-marginalia-anchor-overlay anchor)))
  (let* ((mk (cmacs-ink-marginalia-anchor-marker anchor)))
    (when (and mk (marker-buffer mk) (display-graphic-p))
      (let* ((pos (marker-position mk))
             (svg (org-ex-ink-strokes-to-svg
                   (cmacs-ink-marginalia--strokes-of anchor)
                   (cmacs-ink-marginalia-anchor-width  anchor)
                   (cmacs-ink-marginalia-anchor-height anchor)))
             (img (create-image svg 'svg t :scale 1.0 :ascent 'center))
             (ov  (save-excursion
                    (goto-char pos)
                    (beginning-of-line)
                    (make-overlay (point) (point) nil t nil))))
        (overlay-put ov 'cmacs-ink-marginalia anchor)
        (overlay-put ov 'before-string
                     (concat (if (cmacs-ink-marginalia-anchor-orphan anchor)
                                 (propertize "[orphan annotation] "
                                             'face 'warning)
                               "")
                             (propertize " " 'display img)
                             "\n"))
        (setf (cmacs-ink-marginalia-anchor-overlay anchor) ov)
        ov))))

;; ---------------------------------------------------------------------
;; Anchor reconciliation on load
;; ---------------------------------------------------------------------

(defun cmacs-ink-marginalia--bind-anchor (anchor)
  "Compute marker placement for ANCHOR and set its orphan flag."
  (let* ((line (cmacs-ink-marginalia-anchor-line anchor))
         (h    (cmacs-ink-marginalia-anchor-line-hash anchor))
         (max-line (line-number-at-pos (point-max)))
         (clamped (min (max 1 line) max-line))
         (current-hash (cmacs-ink-marginalia--hash-line clamped))
         (resolved-line nil))
    (cond
     ;; 1. Hash matches at recorded line → use it
     ((and h (string= h current-hash))
      (setq resolved-line clamped))
     ;; 2. Search ±10 lines for the hash
     (h
      (setq resolved-line
            (cmacs-ink-marginalia--find-hash h clamped)))
     ;; 3. No hash → trust the line number
     (t
      (setq resolved-line clamped)))
    (let ((target-line (or resolved-line 1))
          (orphan (and h (null resolved-line))))
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- target-line))
        (setf (cmacs-ink-marginalia-anchor-marker anchor)
              (point-marker))
        (set-marker-insertion-type
         (cmacs-ink-marginalia-anchor-marker anchor) t))
      (setf (cmacs-ink-marginalia-anchor-orphan anchor) orphan)
      anchor)))

;; ---------------------------------------------------------------------
;; Sidecar parse / serialise
;; ---------------------------------------------------------------------

(defun cmacs-ink-marginalia--anchor-from-plist (plist)
  (make-cmacs-ink-marginalia-anchor
   :id        (plist-get plist :id)
   :line      (or (plist-get plist :line) 1)
   :line-hash (plist-get plist :line-hash)
   :width     (or (plist-get plist :width)
                  cmacs-ink-marginalia-default-width)
   :height    (or (plist-get plist :height)
                  cmacs-ink-marginalia-default-height)
   :created   (plist-get plist :created)
   :strokes-string
   (let ((sl (plist-get plist :strokes)))
     (cond
      ((stringp sl) sl)
      ((listp sl)
       (mapconcat (lambda (s) (format "%S" s))
                  sl "\n"))
      (t "")))))

(defun cmacs-ink-marginalia--anchor-to-plist (anchor)
  ;; Serialise strokes-string back into a list of forms by reading
  ;; them — keeps the on-disk form structured even when they were
  ;; round-tripped through C as text.
  (let* ((s (or (cmacs-ink-marginalia-anchor-strokes-string anchor) ""))
         (forms nil))
    (with-temp-buffer
      (insert s)
      (goto-char (point-min))
      (condition-case _err
          (while (not (eobp))
            (let ((form (read (current-buffer))))
              (push form forms)))
        (end-of-file nil)
        (invalid-read-syntax nil)
        (error nil)))
    (list :id        (cmacs-ink-marginalia-anchor-id anchor)
          :line      (let ((mk (cmacs-ink-marginalia-anchor-marker anchor)))
                       (if (and mk (marker-buffer mk))
                           (line-number-at-pos (marker-position mk))
                         (cmacs-ink-marginalia-anchor-line anchor)))
          :line-hash (cmacs-ink-marginalia-anchor-line-hash anchor)
          :width     (cmacs-ink-marginalia-anchor-width anchor)
          :height    (cmacs-ink-marginalia-anchor-height anchor)
          :created   (cmacs-ink-marginalia-anchor-created anchor)
          :strokes   (nreverse forms))))

;; Sidecar I/O is owned by `cmacs-ink-storage.el'.  This module
;; only owns the in-memory shape (the cl-defstruct) and the
;; reconciliation logic above.  Save/load happen through the
;; unified hooks installed by `cmacs-ink-mode'.

;; ---------------------------------------------------------------------
;; User entry points
;; ---------------------------------------------------------------------

(defun cmacs-ink-marginalia--new-id ()
  (format "ann-%04x" (random #x10000)))

;;;###autoload
(defun cmacs-ink-marginalia-add ()
  "Annotate the current line with an ink note.
Opens the modal capture window; on commit a new annotation is
attached to the line containing point.  Stored in the sidecar
file alongside the source on save."
  (interactive)
  (unless (buffer-file-name)
    (user-error "Buffer is not visiting a file"))
  (let* ((line (line-number-at-pos))
         (hash (cmacs-ink-marginalia--hash-line line))
         (capture
          (org-ex-ink-capture
           nil
           cmacs-ink-marginalia-default-width
           cmacs-ink-marginalia-default-height
           cmacs-ink-marginalia-default-colour
           cmacs-ink-marginalia-default-base-width
           t)))
    (if (cdr capture)
        (message "cmacs-ink: cancelled")
      (let* ((strokes (car capture))
             (text (org-ex-ink-strokes-to-string strokes))
             (anchor (make-cmacs-ink-marginalia-anchor
                      :id        (cmacs-ink-marginalia--new-id)
                      :line      line
                      :line-hash hash
                      :width     cmacs-ink-marginalia-default-width
                      :height    cmacs-ink-marginalia-default-height
                      :created   (time-convert (current-time) 'integer)
                      :strokes-string text)))
        (cmacs-ink-marginalia--bind-anchor anchor)
        (cmacs-ink-marginalia--make-overlay anchor)
        (push anchor cmacs-ink-marginalia--anchors)
        (setq cmacs-ink-marginalia--dirty t) (cmacs-ink--save)
        (message "cmacs-ink: annotation %s on line %d (%d strokes)"
                 (cmacs-ink-marginalia-anchor-id anchor)
                 line
                 (org-ex-ink-strokes-count strokes))))))

;;;###autoload
(defun cmacs-ink-marginalia-edit-at-point ()
  "Edit the annotation overlapping point, or the nearest below."
  (interactive)
  (let* ((p (point))
         (anchor
          (cl-find-if
           (lambda (a)
             (let ((m (cmacs-ink-marginalia-anchor-marker a)))
               (and m (marker-buffer m)
                    (= (line-number-at-pos (marker-position m))
                       (line-number-at-pos p)))))
           cmacs-ink-marginalia--anchors)))
    (unless anchor
      (user-error "No annotation on this line"))
    (let* ((initial (cmacs-ink-marginalia--strokes-of anchor))
           (capture
            (org-ex-ink-capture
             initial
             (cmacs-ink-marginalia-anchor-width anchor)
             (cmacs-ink-marginalia-anchor-height anchor)
             cmacs-ink-marginalia-default-colour
             cmacs-ink-marginalia-default-base-width
             t)))
      (if (cdr capture)
          (message "cmacs-ink: edit cancelled")
        (let ((new-text (org-ex-ink-strokes-to-string (car capture))))
          (setf (cmacs-ink-marginalia-anchor-strokes-string anchor)
                new-text)
          (cmacs-ink-marginalia--make-overlay anchor)
          (setq cmacs-ink-marginalia--dirty t) (cmacs-ink--save)
          (message "cmacs-ink: %d stroke(s)"
                   (org-ex-ink-strokes-count (car capture))))))))

;;;###autoload
(defun cmacs-ink-marginalia-delete-at-point ()
  "Delete the annotation on the current line."
  (interactive)
  (let* ((p (point))
         (anchor
          (cl-find-if
           (lambda (a)
             (let ((m (cmacs-ink-marginalia-anchor-marker a)))
               (and m (marker-buffer m)
                    (= (line-number-at-pos (marker-position m))
                       (line-number-at-pos p)))))
           cmacs-ink-marginalia--anchors)))
    (unless anchor
      (user-error "No annotation on this line"))
    (when (cmacs-ink-marginalia-anchor-overlay anchor)
      (delete-overlay (cmacs-ink-marginalia-anchor-overlay anchor)))
    (setq cmacs-ink-marginalia--anchors
          (delq anchor cmacs-ink-marginalia--anchors))
    (setq cmacs-ink-marginalia--dirty t) (cmacs-ink--save)
    (message "cmacs-ink: annotation deleted")))

;;;###autoload
(defun cmacs-ink-marginalia-list ()
  "Show all annotations in the current buffer."
  (interactive)
  (if (null cmacs-ink-marginalia--anchors)
      (message "cmacs-ink: no annotations")
    (let ((buf (get-buffer-create "*cmacs-ink annotations*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (dolist (a cmacs-ink-marginalia--anchors)
            (insert (format "%s  line %s%s\n"
                            (cmacs-ink-marginalia-anchor-id a)
                            (let ((mk (cmacs-ink-marginalia-anchor-marker a)))
                              (if (and mk (marker-buffer mk))
                                  (line-number-at-pos
                                   (marker-position mk))
                                "?"))
                            (if (cmacs-ink-marginalia-anchor-orphan a)
                                "  (ORPHAN)"
                              ""))))
          (goto-char (point-min))
          (special-mode)))
      (display-buffer buf))))

;; Persistence hooks live in `cmacs-ink-storage.el', which sets
;; `find-file-hook' / `after-save-hook' once for all annotation
;; flavours.

(provide 'cmacs-ink-marginalia)
;;; cmacs-ink-marginalia.el ends here
