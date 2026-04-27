;;; cmacs-ink-region.el --- Region-bound transparent ink overlays  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A second flavour of cmacs-ink, complementary to the per-line
;; marginalia in `cmacs-ink-marginalia.el'.
;;
;; Where marginalia attaches an ink note as an SVG image overlay BELOW
;; a single line, this module captures a multi-line region, opens the
;; capture window with that region rendered as the canvas BACKGROUND
;; (via `cmacs-frame-screenshot-rect'), and renders the strokes back
;; into Emacs as a transparent Cairo layer painted ON TOP of the
;; actual buffer text.  The underlying text remains live and
;; editable; strokes scroll with it and re-anchor on each redisplay.
;;
;; The redisplay-finish paint pass lives in C
;; (`cmacs-ink-overlay.c', wired into `pgtk_frame_up_to_date'); this
;; file owns the data, the capture flow, and the sidecar format.
;;
;; Storage extends the existing `<source>.cmacs-ink' sidecar:
;;
;;   ((:format "cmacs-ink/marginalia/2"
;;     :file ".../foo.c"
;;     :anchors ((... v1 per-line entries ...))     ;; coexist
;;     :region-anchors                              ;; THIS module
;;     ((:id "rgn-7f3a"
;;       :start-line 412 :start-col 4
;;       :end-line 415   :end-col 12
;;       :region-hash "9af2c0…"
;;       :width 480 :height 60
;;       :created 1745600000
;;       :strokes (...)))))
;;
;; v1 sidecars (no `:region-anchors') load cleanly into this v2
;; reader; v2 sidecars opened by an old binary lose
;; `:region-anchors' on the next save.  Acceptable on the
;; `drawing-tab-support' branch; we'll bump main when this lands.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Implemented in `cmacs-ink-storage.el'.  See header comment in
;; `cmacs-ink-marginalia.el' for rationale.
(declare-function cmacs-ink--save "cmacs-ink-storage" ())
(declare-function cmacs-ink--load "cmacs-ink-storage" ())

;; Defined in `cmacs-ink-marginalia.el' which we don't require
;; (storage pulls it in).  Touch it from the overlay-mode toggle
;; to decide whether a load is needed; declaring it here silences
;; the byte-compiler's free-variable warning.
(defvar cmacs-ink-marginalia--anchors)

;; Forward declaration for the byte-compiler — `cmacs-ink-overlay-mode'
;; is defined further down via `define-minor-mode' but referenced by
;; the debug helper above it.
(defvar cmacs-ink-overlay-mode)

(defgroup cmacs-ink-region nil
  "Region-bound transparent ink overlays."
  :group 'cmacs-ink
  :prefix "cmacs-ink-region-")

(defcustom cmacs-ink-region-default-colour "#cc2a2a"
  "Default ink colour for region annotations.
Red works on most code themes; override per-buffer if needed."
  :type 'string
  :safe #'stringp)

(defcustom cmacs-ink-region-default-base-width 2.0
  "Default base pen width for region annotations."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ink-region-default-alpha 0.85
  "Default opacity for rendered stroke layers (0.0..1.0).
Strokes painted on top of buffer text are slightly transparent so
the user sees the underlying glyphs.  The C-side paint hook
reads this; changes take effect on next redisplay."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ink-region-search-radius 10
  "Lines to scan around recorded :start-line for region-hash matches
during sidecar reconciliation.  Same semantics as the per-line
marginalia setting."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ink-region-auto-prune-on-delete t
  "When non-nil, annotations whose region is fully deleted are removed.

Edits inside the region shift the markers normally; only when
deletion collapses the region (start-marker reaches end-marker)
do we treat the annotation as gone and prune it from the
buffer-local list.  The next save then drops it from the inline
section / sidecar.

Note: Emacs `undo' will restore the buffer text but cannot
restore the pruned annotation — re-edit or re-paste will need a
fresh annotation.  Set to nil if you'd rather keep stale
annotations and clean them up manually via
`M-x cmacs-ink-region-list' / `C-c i D'."
  :type 'boolean
  :safe #'booleanp)

;; ---------------------------------------------------------------------
;; Buffer-local state
;; ---------------------------------------------------------------------

(defvar-local cmacs-ink-region--annotations nil
  "List of plists holding region annotations for this buffer.

Each plist has:
  :id              \"rgn-XXXX\" string
  :start-marker    advance-on-insert-before marker
  :end-marker      stay-on-insert-before marker
  :width           canvas width in pixels
  :height          canvas height in pixels
  :strokes-string  serialised stroke S-expressions
  :region-hash     SHA1 of the original region content
  :created         Unix timestamp
  :orphan          t if reconciliation could not relocate the region

Read from the C-side post-glyph paint hook via
`buffer-local-value'.")

(defvar-local cmacs-ink-region--dirty nil
  "Non-nil when the in-memory annotation list diverges from sidecar.")

;; ---------------------------------------------------------------------
;; Hash + reconciliation
;; ---------------------------------------------------------------------

(defun cmacs-ink-region--region-hash (start end)
  "Return SHA1 of the buffer text between START and END."
  (secure-hash 'sha1 (buffer-substring-no-properties start end)))

(defun cmacs-ink-region--lookup-region-by-hash (hash hint-line radius)
  "Search ±RADIUS lines around HINT-LINE for a region whose hash matches HASH.
Returns (start . end) buffer positions, or nil.  The search
spans contiguous chunks of the same line-count as the original
region — i.e. we re-anchor by content rather than by exact position."
  (save-excursion
    (save-restriction
      (widen)
      (let* ((max-line (line-number-at-pos (point-max)))
             (lo (max 1 (- hint-line radius)))
             (hi (min max-line (+ hint-line radius)))
             found)
        (cl-block search
          (dotimes (i (1+ (- hi lo)))
            (let ((line (+ lo i)))
              (goto-char (point-min))
              (forward-line (1- line))
              (let ((s (point)))
                (forward-line 1)
                (let ((e (point)))
                  (when (string= (cmacs-ink-region--region-hash s e) hash)
                    (setq found (cons s e))
                    (cl-return-from search nil)))))))
        found))))

;; ---------------------------------------------------------------------
;; Anchor plist <-> in-memory shape
;; ---------------------------------------------------------------------
;;
;; Sidecar / inline-section I/O is owned by `cmacs-ink-storage.el'.
;; This module exposes the conversion helpers that translate
;; between the on-disk plist (line/col integers, hash, strokes as
;; a list of S-exprs) and the runtime form (markers, strokes
;; serialised as a string for the C overlay paint hook).

(defun cmacs-ink-region--strokes-string (raw)
  "Normalise RAW (string or list of forms) to canonical stroke-text."
  (cond ((stringp raw) raw)
        ((listp raw) (mapconcat (lambda (f) (format "%S" f)) raw "\n"))
        (t "")))

(defun cmacs-ink-region--strokes-ptr-from-string (text)
  "Return a parsed-stroke user-ptr for TEXT, or nil on failure.
The C-side overlay paint hook reads this directly so it never has
to re-parse on every redisplay."
  (and text
       (not (string-blank-p text))
       (condition-case _err
           (org-ex-ink-strokes-from-string text)
         (error nil))))

(defun cmacs-ink-region--anchor-from-plist (plist)
  "Materialise an in-memory anchor plist from a sidecar PLIST.
Adds a `:strokes-ptr' user-ptr (parsed once) so the C paint hook
can skip re-parsing on every redisplay."
  (let* ((start-line (or (plist-get plist :start-line) 1))
         (start-col  (or (plist-get plist :start-col) 0))
         (end-line   (or (plist-get plist :end-line) start-line))
         (end-col    (or (plist-get plist :end-col) 0))
         (hash       (plist-get plist :region-hash))
         (max-line   (line-number-at-pos (point-max)))
         (start-line-clamped (min (max 1 start-line) max-line))
         (end-line-clamped   (min (max 1 end-line)   max-line))
         (locate
          (lambda (ln col)
            (save-excursion
              (goto-char (point-min))
              (forward-line (1- ln))
              (move-to-column col)
              (point-marker))))
         (start-marker (funcall locate start-line-clamped start-col))
         (end-marker   (funcall locate end-line-clamped   end-col))
         (current-hash (cmacs-ink-region--region-hash
                        (marker-position start-marker)
                        (marker-position end-marker)))
         (orphan nil)
         (strokes-string
          (cmacs-ink-region--strokes-string (plist-get plist :strokes)))
         (strokes-ptr
          (cmacs-ink-region--strokes-ptr-from-string strokes-string)))
    (when (and hash (not (string= hash current-hash)))
      ;; Try to relocate via hash search around the saved start line.
      (let ((relocated
             (cmacs-ink-region--lookup-region-by-hash
              hash start-line cmacs-ink-region-search-radius)))
        (cond
         (relocated
          (set-marker start-marker (car relocated))
          (set-marker end-marker   (cdr relocated)))
         (t (setq orphan t)))))
    (set-marker-insertion-type start-marker t)  ; advance on insert before
    (set-marker-insertion-type end-marker nil)  ; stay on insert at
    (list :id          (plist-get plist :id)
          :start-marker start-marker
          :end-marker   end-marker
          :width  (or (plist-get plist :width)  400)
          :height (or (plist-get plist :height) 60)
          :capture-dx (or (plist-get plist :capture-dx) 0)
          :capture-dy (or (plist-get plist :capture-dy) 0)
          :strokes-string strokes-string
          :strokes-ptr    strokes-ptr
          :region-hash hash
          :created     (plist-get plist :created)
          :orphan      orphan)))

(defun cmacs-ink-region--anchor-to-plist (anchor)
  "Convert ANCHOR back to the on-disk sidecar plist form."
  (let* ((start (cmacs-ink-region--anchor-marker anchor :start-marker))
         (end   (cmacs-ink-region--anchor-marker anchor :end-marker))
         (s     (or (plist-get anchor :strokes-string) ""))
         (forms nil))
    (with-temp-buffer
      (insert s)
      (goto-char (point-min))
      (condition-case _err
          (while (not (eobp))
            (push (read (current-buffer)) forms))
        (end-of-file nil)
        (invalid-read-syntax nil)
        (error nil)))
    (list :id (plist-get anchor :id)
          :start-line (when (and start (marker-buffer start))
                        (line-number-at-pos (marker-position start)))
          :start-col  (when (and start (marker-buffer start))
                        (save-excursion
                          (goto-char (marker-position start))
                          (current-column)))
          :end-line   (when (and end (marker-buffer end))
                        (line-number-at-pos (marker-position end)))
          :end-col    (when (and end (marker-buffer end))
                        (save-excursion
                          (goto-char (marker-position end))
                          (current-column)))
          :region-hash (plist-get anchor :region-hash)
          :width  (plist-get anchor :width)
          :height (plist-get anchor :height)
          :capture-dx (or (plist-get anchor :capture-dx) 0)
          :capture-dy (or (plist-get anchor :capture-dy) 0)
          :created (plist-get anchor :created)
          :strokes (nreverse forms))))

(defun cmacs-ink-region--anchor-marker (anchor key)
  "Read marker KEY from ANCHOR, returning nil for detached markers."
  (let ((m (plist-get anchor key)))
    (if (and m (marker-buffer m)) m nil)))

;; ---------------------------------------------------------------------
;; Capture flow
;; ---------------------------------------------------------------------

(defun cmacs-ink-region--new-id ()
  (format "rgn-%04x" (random #x10000)))

(defun cmacs-ink-region--region-pixel-rect (start end)
  "Return (X Y W H DX DY) for the [START..END] region.
X Y W H is the frame-pixel screenshot rectangle.  DX, DY are the
text-area-relative offsets from the START glyph to the rect's
top-left.  When START is to the right of (or below) END (e.g.
multi-line region whose END sits at column 0 of a continuation
line), the rect extends LEFT (or UP) of START, and DX/DY are the
positive offsets needed at paint time to recover the rect's
top-left from the start-marker's current glyph position.

Falls back to the current line geometry if either endpoint is
not currently visible — keeps the screenshot path robust against
horizontal scrolling and folded regions."
  (let ((s-pos (posn-at-point start))
        (e-pos (posn-at-point end))
        ;; Use *body* pixel edges (text area in frame coords) so that
        ;; (body-left + posn-x, body-top + posn-y) = frame-absolute
        ;; glyph origin.  `window-pixel-edges' is the window's OUTER
        ;; top-left and excludes the tab-line + header-line height,
        ;; while `posn-x-y' returns text-area-relative coords — the
        ;; mismatch made the screenshot top-left land
        ;; (tab+header) pixels above the actual glyph, and the C
        ;; overlay (which uses pos_visible_p's window-box-relative
        ;; y) painted strokes ~1.5 lines below where the user drew.
        (body-edges (window-body-pixel-edges (selected-window))))
    (unless (and s-pos e-pos)
      (user-error "cmacs-ink-region: selected region not currently visible"))
    (let* ((s-xy (posn-x-y s-pos))
           (e-xy (posn-x-y e-pos))
           (sx (+ (car body-edges) (car s-xy)))
           (sy (+ (cadr body-edges) (cdr s-xy)))
           (ex (+ (car body-edges) (car e-xy)))
           (ey (+ (cadr body-edges) (cdr e-xy)))
           (line-h (line-pixel-height))
           ;; Bounding box: leftmost X of either endpoint,
           ;; topmost Y, extending to the right window edge and
           ;; one line below the bottom endpoint.
           (right-edge (nth 2 body-edges))
           (x (min sx ex))
           (y (min sy ey))
           (w (- right-edge x))
           (h (- (+ (max sy ey) line-h) y))
           ;; dx/dy: how far (right, down) the start-marker glyph
           ;; sits from the rect's top-left.  When start is the
           ;; leftmost/topmost endpoint these are 0; for multi-line
           ;; regions where end falls at column 0 of a later line,
           ;; the rect extends left and `dx' captures the gap so
           ;; paint can re-derive rect top-left from the marker.
           (dx (- sx x))
           (dy (- sy y)))
      (list x y (max 50 w) (max line-h h) dx dy))))

;;;###autoload
(defun cmacs-ink-region-annotate (start end)
  "Annotate the active region with a transparent ink layer.

Opens the capture window with a screenshot of the selected text
as the canvas background.  On commit, the strokes are stored as
a region annotation that paints on top of the live buffer text
(visible when `cmacs-ink-overlay-mode' is on).  Strokes scroll
with text and re-anchor on each redisplay via the C-side paint
hook.

Coexists with `cmacs-ink-marginalia-add' \(per-line image
overlay) on the same buffer / sidecar."
  (interactive "r")
  (unless (use-region-p)
    (user-error "cmacs-ink-region: select a region first"))
  (unless (buffer-file-name)
    (user-error "cmacs-ink-region: buffer is not visiting a file"))
  (unless (display-graphic-p)
    (user-error "cmacs-ink-region: requires a graphical frame"))
  (unless (fboundp 'cmacs-frame-screenshot-rect)
    (user-error "cmacs-ink-region: cmacs not built with --with-pgtk"))
  (let* ((rect (cmacs-ink-region--region-pixel-rect start end))
         (x (nth 0 rect)) (y (nth 1 rect))
         (w (nth 2 rect)) (h (nth 3 rect))
         (dx (or (nth 4 rect) 0))
         (dy (or (nth 5 rect) 0))
         (bg (cmacs-frame-screenshot-rect x y w h))
         (capture (org-ex-ink-capture-with-background
                   bg nil w h
                   cmacs-ink-region-default-colour
                   cmacs-ink-region-default-base-width
                   t))
         (strokes  (car capture))
         (cancelled (cdr capture)))
    (cond
     (cancelled
      (message "cmacs-ink-region: cancelled"))
     (t
      (let* ((text  (org-ex-ink-strokes-to-string strokes))
             (hash  (cmacs-ink-region--region-hash start end))
             (sm    (copy-marker start))
             (em    (copy-marker end))
             (anchor (list :id (cmacs-ink-region--new-id)
                           :start-marker sm
                           :end-marker em
                           :width  w
                           :height h
                           ;; Stroke (0,0) on canvas = rect top-left.
                           ;; Paint origin = (start-marker glyph) - (dx, dy).
                           :capture-dx dx
                           :capture-dy dy
                           :strokes-string text
                           ;; Reuse the GPtrArray we already have
                           ;; from capture — avoids one parse cycle
                           ;; for the just-drawn strokes.
                           :strokes-ptr strokes
                           :region-hash hash
                           :created (time-convert (current-time) 'integer)
                           :orphan nil)))
        (set-marker-insertion-type sm t)
        (set-marker-insertion-type em nil)
        (push anchor cmacs-ink-region--annotations)
        (setq cmacs-ink-region--dirty t) (cmacs-ink--save)
        ;; Auto-enable the paint pass for first-time annotators in
        ;; this buffer.  Otherwise the user wonders why their
        ;; just-committed strokes don't appear.
        (when (and (fboundp 'cmacs-ink-overlay-mode)
                   (not (bound-and-true-p cmacs-ink-overlay-mode)))
          (cmacs-ink-overlay-mode 1))
        (force-window-update (current-buffer))
        (message "cmacs-ink-region: %d stroke(s) anchored to lines %d–%d"
                 (org-ex-ink-strokes-count strokes)
                 (line-number-at-pos start)
                 (line-number-at-pos end)))))))

;;;###autoload
(defun cmacs-ink-region-edit-at-point ()
  "Edit the region annotation that contains point (if any)."
  (interactive)
  (let ((p (point))
        (target nil))
    (dolist (a cmacs-ink-region--annotations)
      (let ((s (cmacs-ink-region--anchor-marker a :start-marker))
            (e (cmacs-ink-region--anchor-marker a :end-marker)))
        (when (and s e
                   (>= p (marker-position s))
                   (<= p (marker-position e)))
          (setq target a))))
    (unless target
      (user-error "No region annotation contains point"))
    (let* ((s (marker-position
               (plist-get target :start-marker)))
           (e (marker-position
               (plist-get target :end-marker)))
           (rect (cmacs-ink-region--region-pixel-rect s e))
           (w (nth 2 rect)) (h (nth 3 rect))
           (dx (or (nth 4 rect) 0))
           (dy (or (nth 5 rect) 0))
           (bg (cmacs-frame-screenshot-rect
                (nth 0 rect) (nth 1 rect) w h))
           (initial (org-ex-ink-strokes-from-string
                     (or (plist-get target :strokes-string) "")))
           (capture (org-ex-ink-capture-with-background
                     bg initial w h
                     cmacs-ink-region-default-colour
                     cmacs-ink-region-default-base-width
                     t)))
      (if (cdr capture)
          (message "cmacs-ink-region: edit cancelled")
        (plist-put target :strokes-string
                   (org-ex-ink-strokes-to-string (car capture)))
        ;; Refresh the cached parsed-strokes user-ptr so the next
        ;; redisplay picks up the new strokes without re-parsing.
        (plist-put target :strokes-ptr (car capture))
        (plist-put target :capture-dx dx)
        (plist-put target :capture-dy dy)
        (plist-put target :region-hash
                   (cmacs-ink-region--region-hash s e))
        (setq cmacs-ink-region--dirty t) (cmacs-ink--save)
        (force-window-update (current-buffer))
        (message "cmacs-ink-region: %d stroke(s) updated"
                 (org-ex-ink-strokes-count (car capture)))))))

;;;###autoload
(defun cmacs-ink-region-delete-at-point ()
  "Delete the region annotation that contains point."
  (interactive)
  (let ((p (point))
        (target nil))
    (dolist (a cmacs-ink-region--annotations)
      (let ((s (cmacs-ink-region--anchor-marker a :start-marker))
            (e (cmacs-ink-region--anchor-marker a :end-marker)))
        (when (and s e
                   (>= p (marker-position s))
                   (<= p (marker-position e)))
          (setq target a))))
    (unless target
      (user-error "No region annotation contains point"))
    (let ((s (plist-get target :start-marker))
          (e (plist-get target :end-marker)))
      (when s (set-marker s nil))
      (when e (set-marker e nil)))
    (setq cmacs-ink-region--annotations
          (delq target cmacs-ink-region--annotations))
    (setq cmacs-ink-region--dirty t) (cmacs-ink--save)
    (force-window-update (current-buffer))
    (message "cmacs-ink-region: annotation deleted")))

;;;###autoload
(defun cmacs-ink-region-list ()
  "Show all region annotations in the current buffer."
  (interactive)
  (if (null cmacs-ink-region--annotations)
      (message "cmacs-ink-region: no region annotations")
    (let ((buf (get-buffer-create "*cmacs-ink regions*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (dolist (a cmacs-ink-region--annotations)
            (let ((s (cmacs-ink-region--anchor-marker a :start-marker))
                  (e (cmacs-ink-region--anchor-marker a :end-marker)))
              (insert (format "%-12s lines %s-%s%s\n"
                              (plist-get a :id)
                              (if s (line-number-at-pos
                                     (marker-position s)) "?")
                              (if e (line-number-at-pos
                                     (marker-position e)) "?")
                              (if (plist-get a :orphan) "  (ORPHAN)" "")))))
          (goto-char (point-min))
          (special-mode)))
      (display-buffer buf))))

;; ---------------------------------------------------------------------
;; Mode + hooks
;; ---------------------------------------------------------------------

;;;###autoload
(defun cmacs-ink-region-reload ()
  "Force-reload region (and marginalia) annotations from disk.
Useful after hand-editing the inline section or sidecar."
  (interactive)
  (require 'cmacs-ink-storage)
  (cmacs-ink--load)
  (force-window-update (current-buffer)))

;;;###autoload
(defun cmacs-ink-redraw ()
  "Force a complete redraw of all region overlays.
Use when strokes appear out of sync with the buffer (cursor
move chipped them, scroll left ghosts behind, etc.).  Does NOT
re-read from disk — for that, use `cmacs-ink-region-reload'.

Triggers a full-frame redisplay so the post-glyph paint hook
runs against fresh glyph contents and re-applies every stroke
of every annotation in every visible window."
  (interactive)
  (require 'cmacs-ink-storage)
  ;; Force a full-buffer redisplay rather than the partial-row
  ;; updates that incremental redisplay normally schedules.  This
  ;; clears any stroke pixels left over from the previous frame
  ;; and ensures the paint hook runs against a clean slate.
  (force-mode-line-update t)
  (let ((display-buffer-alist nil))
    ;; `redraw-frame' is the hammer — discards the back buffer and
    ;; redraws the entire frame from scratch.  The resulting
    ;; redisplay cycle goes through `unblock_buffer_flips' which
    ;; calls `cmacs_ink_overlay_paint' per pgtk frame.
    (redraw-frame (selected-frame)))
  (force-window-update (current-buffer))
  (message "cmacs-ink: redrew %d region overlay%s in this buffer"
           (length cmacs-ink-region--annotations)
           (if (= (length cmacs-ink-region--annotations) 1) "" "s")))

;;;###autoload
(defun cmacs-ink-region-debug ()
  "Print diagnostic info for region annotations in the current buffer.
Use when annotations are loaded but not visibly rendering."
  (interactive)
  (require 'cmacs-ink-storage)
  (let* ((buf (get-buffer-create "*cmacs-ink debug*"))
         (anchors cmacs-ink-region--annotations)
         (mode-on cmacs-ink-overlay-mode)
         (win (selected-window))
         (frame (selected-frame))
         (file (buffer-file-name))
         (origin (current-buffer))
         ;; Compute line numbers + posn-at-point in the SOURCE buffer
         ;; before switching to the debug output buffer.
         (rows
          (mapcar
           (lambda (a)
             (let* ((sm (plist-get a :start-marker))
                    (em (plist-get a :end-marker))
                    (pos (and sm (marker-position sm)))
                    (line (and pos
                               (save-excursion
                                 (goto-char (min pos (point-max)))
                                 (line-number-at-pos))))
                    (posn (and pos (posn-at-point pos win))))
               (list :id (plist-get a :id)
                     :orphan (plist-get a :orphan)
                     :pos pos
                     :line line
                     :end-pos (and em (marker-position em))
                     :width  (plist-get a :width)
                     :height (plist-get a :height)
                     :strokes-type (type-of (plist-get a :strokes-ptr))
                     :strokes-count (and (plist-get a :strokes-ptr)
                                         (org-ex-ink-strokes-count
                                          (plist-get a :strokes-ptr)))
                     :posn posn)))
           anchors)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "buffer file:        %s\n" file))
        (insert (format "buffer last-line:   %d\n"
                        (with-current-buffer origin
                          (line-number-at-pos (point-max)))))
        (insert (format "overlay-mode:       %s\n" mode-on))
        (insert (format "annotations count:  %d\n" (length anchors)))
        (insert (format "frame width × hgt:  %d × %d\n"
                        (frame-pixel-width frame)
                        (frame-pixel-height frame)))
        (insert (format "window pixel-edges: %S\n"
                        (window-pixel-edges win)))
        (insert (format "window text-area:   %S\n"
                        (window-body-edges win)))
        (dolist (r rows)
          (insert (format "\n--- %s ---\n" (plist-get r :id)))
          (insert (format "  orphan:        %s\n"
                          (plist-get r :orphan)))
          (insert (format "  start-pos:     %s (line %s)\n"
                          (plist-get r :pos) (plist-get r :line)))
          (insert (format "  end-pos:       %s\n"
                          (plist-get r :end-pos)))
          (insert (format "  width × height: %s × %s\n"
                          (plist-get r :width)
                          (plist-get r :height)))
          (insert (format "  strokes-ptr:   %s (count=%s)\n"
                          (plist-get r :strokes-type)
                          (plist-get r :strokes-count)))
          (insert (format "  posn-at-point: %S\n"
                          (plist-get r :posn))))
        (special-mode)))
    (display-buffer buf)))

(defun cmacs-ink-region--prune-collapsed (_begin _end length)
  "Remove annotations whose region was fully deleted.

Hooked onto `after-change-functions' when
`cmacs-ink-overlay-mode' is on AND
`cmacs-ink-region-auto-prune-on-delete' is non-nil.  We ONLY
scan when LENGTH > 0 — i.e. the change deleted text — to avoid
pathological scans on every keystroke insert or font-lock
text-property tweak.

When triggered, walks the buffer-local list and prunes anchors
whose markers collapsed (start-pos >= end-pos) or detached
entirely.  Each prune sets the dirty flag and schedules a save
so the inline section / sidecar is updated on the next
opportunity."
  (when (and cmacs-ink-region-auto-prune-on-delete
             (> length 0))
    (let ((removed 0)
          (kept nil))
      (dolist (a cmacs-ink-region--annotations)
        (let* ((sm (plist-get a :start-marker))
               (em (plist-get a :end-marker))
               (sb (and sm (marker-buffer sm)))
               (eb (and em (marker-buffer em)))
               (sp (and sb (marker-position sm)))
               (ep (and eb (marker-position em))))
          (cond
           ;; Markers detached or buffer mismatch — drop.
           ((or (null sb) (null eb))
            (when sm (set-marker sm nil))
            (when em (set-marker em nil))
            (setq removed (1+ removed)))
           ;; Region collapsed (start caught up to end via deletion).
           ((>= sp ep)
            (set-marker sm nil)
            (set-marker em nil)
            (setq removed (1+ removed)))
           (t (push a kept)))))
      (when (> removed 0)
        (setq cmacs-ink-region--annotations (nreverse kept)
              cmacs-ink-region--dirty t)
        ;; Defer the save out of the after-change context so we
        ;; don't dirty the buffer mid-edit.
        (run-with-idle-timer
         0 nil
         (lambda (buf)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (when (fboundp 'cmacs-ink--save)
                 (cmacs-ink--save))
               (force-window-update buf))))
         (current-buffer))
        (message "cmacs-ink: pruned %d annotation%s (region deleted)"
                 removed (if (= removed 1) "" "s"))))))

;;;###autoload
(define-minor-mode cmacs-ink-overlay-mode
  "Render `cmacs-ink-region' annotations on top of buffer text.
When on, the C-side post-glyph paint hook composites stroke
layers onto the frame.  When off, the paint hook short-circuits
and no extra Cairo work happens.

Enabling the mode in a file-visiting buffer triggers a fresh
`cmacs-ink--load' if no annotations are currently in memory, so
existing annotations from disk are rendered right away — even if
`cmacs-ink-mode' wasn't enabled at the time the file was opened.

To force-reload after hand-editing the inline section or
sidecar, use `M-x cmacs-ink-region-reload' instead of toggling
this mode off and on."
  :lighter " Ink^"
  :group 'cmacs-ink-region
  (cond
   (cmacs-ink-overlay-mode
    ;; The annotation persistence lives in `cmacs-ink-storage.el',
    ;; which `cmacs-ink-region.el' deliberately does NOT require
    ;; (to avoid a circular require — storage requires us).  When
    ;; the user enables this mode standalone (without
    ;; `cmacs-ink-mode'), storage may not be loaded yet, so
    ;; `cmacs-ink--load' is unbound and our load-on-enable
    ;; silently no-ops.  Pull it in here so the path is reliable
    ;; regardless of how the user got here.
    (require 'cmacs-ink-storage)
    ;; Only trigger a load when the in-memory list is empty.
    ;; Avoids a redundant second load when the user came in via
    ;; find-file-hook → cmacs-ink-mode → cmacs-ink--load →
    ;; apply-loaded → auto-enable us → our body fires here.
    (when (and (buffer-file-name)
               (null cmacs-ink-region--annotations)
               (null cmacs-ink-marginalia--anchors))
      (cmacs-ink--load))
    ;; Watch for region collapse — if the user deletes the text the
    ;; annotation was anchored to, drop the annotation.
    (add-hook 'after-change-functions
              #'cmacs-ink-region--prune-collapsed nil t))
   (t
    (remove-hook 'after-change-functions
                 #'cmacs-ink-region--prune-collapsed t)))
  (force-window-update (current-buffer)))

;; Save/load hooks live in `cmacs-ink-storage.el'.

(provide 'cmacs-ink-region)
;;; cmacs-ink-region.el ends here
