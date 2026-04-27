;;; cmacs-ink-storage.el --- Storage policy for cmacs-ink annotations  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Single source of truth for saving and loading the two cmacs-ink
;; annotation flavours that ride alongside source files (per-line
;; marginalia, region overlay ink).  Replaces the per-module
;; sidecar I/O that lived in `cmacs-ink-marginalia.el' and
;; `cmacs-ink-region.el'.
;;
;; Storage policy
;; --------------
;; Two on-disk forms, one runtime dispatcher:
;;
;;   * INLINE — annotations live in an `* cmacs-ink' :noexport: org
;;     section near the end of the buffer.  Travels with the file
;;     on copy/move.  Default for org buffers.
;;
;;   * SIDECAR — annotations live in `<source>.cmacs-ink' next to
;;     the source.  Default for non-org buffers (the source format
;;     usually can't host arbitrary blocks).  Also used when
;;     `cmacs-ink-storage' is forced to `'sidecar'.
;;
;; Both forms use the same one-stroke-per-line S-expression grammar
;; produced by `org-ex-ink-strokes-to-string' (see
;; `cmacs/org-ex/lib/core/org-ex-ink-stroke.c'), so a `git diff'
;; stays minimal regardless of which flavour you pick.
;;
;; Inline section format
;; ---------------------
;;   * cmacs-ink                                                       :noexport:
;;   :PROPERTIES:
;;   :VISIBILITY: folded
;;   :END:
;;
;;   #+BEGIN_INK_MARGINALIA :id ann-... :line N :hash X :w W :h H :created T
;;   ;; cmacs-ink marginalia v1; one stroke per line
;;   (s :t pen :c "#cc2a2a" :w 2 :p ((50 30 850) (60 35 870)))
;;   #+END_INK_MARGINALIA
;;
;;   #+BEGIN_INK_REGION :id rgn-... :start-line N :start-col M
;;     :end-line K :end-col L :hash X :w W :h H :created T
;;   ;; cmacs-ink region v1; one stroke per line
;;   (s :t pen :c "#cc2a2a" :w 2 :p ((10 5 850) (24 12 875)))
;;   #+END_INK_REGION
;;
;; Header keys are flat `:key value' pairs; body lines are stroke
;; S-exprs (or `;;' comments which the parser preserves on
;; round-trip).
;;
;; Backward compatibility
;; ----------------------
;; * The loader tries inline first, then falls back to sidecar.  An
;;   org buffer with an existing `<file>.cmacs-ink' continues to
;;   work; the next save migrates to inline (or you can force
;;   migration with `M-x cmacs-ink-migrate-to-inline').
;; * The sidecar reader handles BOTH the legacy single-line
;;   `prin1' form (cmacs-ink/marginalia/1 and /2) and the new
;;   pretty-printed form (one anchor per block).  No flag day.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; The two annotation modules — required so we can read their
;; buffer-local lists and call their from-plist / to-plist
;; conversion helpers.  No circular dependency: those modules do
;; NOT require this one (they expose data; we own I/O).
(require 'cmacs-ink-marginalia)
(require 'cmacs-ink-region)

;; ---------------------------------------------------------------------
;; Customisation
;; ---------------------------------------------------------------------

(defgroup cmacs-ink-storage nil
  "Storage policy for cmacs-ink annotations."
  :group 'cmacs-ink
  :prefix "cmacs-ink-storage-")

(defcustom cmacs-ink-storage 'auto
  "Where to persist cmacs-ink annotations for the current buffer.

Possible values:

  `auto'    org-mode buffers → inline org section;
            everything else  → sidecar file.  (default)
  `inline'  always inline.  Errors when the buffer is not org-mode.
  `sidecar' always `<file>.cmacs-ink'.

May be set buffer-locally or via `.dir-locals.el'."
  :type '(choice (const :tag "Auto (org → inline; else → sidecar)" auto)
                 (const :tag "Always inline (org only)"            inline)
                 (const :tag "Always sidecar"                      sidecar))
  :group 'cmacs-ink-storage
  :safe (lambda (v) (memq v '(auto inline sidecar))))

(defcustom cmacs-ink-storage-section-name "cmacs-ink"
  "Heading text used for the inline annotation section.
The section is created under a level-1 heading with this text and
the `:noexport:' tag.  Override only if you have an existing
heading by the same name you want to keep separate.

WARNING: any text you put inside the `* cmacs-ink' section that
is not inside a `#+BEGIN_INK_*'..`#+END_INK_*' block will be
deleted on the next save — the writer rewrites the entire
section as a unit.  Keep your own notes in a sibling heading."
  :type 'string
  :group 'cmacs-ink-storage
  :safe #'stringp)

;; ---------------------------------------------------------------------
;; Re-entry guard
;; ---------------------------------------------------------------------

(defvar-local cmacs-ink-storage--saving nil
  "Buffer-local guard preventing `after-save-hook' recursion.
Inline writes modify the buffer, which triggers another
`after-save-hook'; we set this around the write so the recursive
call no-ops.")

(defvar-local cmacs-ink-storage--last-mode nil
  "Last storage mode used for this buffer's save.
Used by `cmacs-ink-storage--mode-changed-p' to detect a flip
from `'sidecar' to `'inline' (or vice versa) so the save path
can clean up the stale on-disk form.")

;; ---------------------------------------------------------------------
;; Mode dispatch
;; ---------------------------------------------------------------------

(defun cmacs-ink-storage--mode-for-buffer ()
  "Return `inline' or `sidecar' for the current buffer."
  (pcase cmacs-ink-storage
    ('inline
     (unless (derived-mode-p 'org-mode)
       (user-error "cmacs-ink-storage: 'inline requires an org buffer"))
     'inline)
    ('sidecar 'sidecar)
    (_ (if (derived-mode-p 'org-mode) 'inline 'sidecar))))

;; ---------------------------------------------------------------------
;; Header parser/printer (shared with #+BEGIN_INK)
;; ---------------------------------------------------------------------

(defun cmacs-ink-storage--parse-header (s)
  "Parse :keyword value pairs out of S into a plist.
Values are read as Lisp objects via `read', so integers stay
integers, strings stay strings.  Mirror of
`cmacs-org-ex-ink--parse-header-args' but emits a plist."
  (let ((acc nil)
        (pos 0))
    (when s
      (while (string-match
              "[ \t]*:\\([A-Za-z_-]+\\)[ \t]+\\(\"[^\"]*\"\\|\\S-+\\)"
              s pos)
        (let* ((key (intern (concat ":" (match-string 1 s))))
               (raw (match-string 2 s))
               (val (condition-case _err
                        (car (read-from-string raw))
                      (error raw))))
          (setq acc (plist-put acc key val))
          (setq pos (match-end 0)))))
    acc))

(defun cmacs-ink-storage--format-header (plist keys)
  "Render PLIST as a flat header string using KEYS in order.
Skips keys whose value is nil."
  (let ((parts nil))
    (dolist (k keys)
      (let ((v (plist-get plist k)))
        (when v
          (push (format "%s %s" k
                        (cond ((stringp v) (prin1-to-string v))
                              (t v)))
                parts))))
    (string-join (nreverse parts) " ")))

;; ---------------------------------------------------------------------
;; Block reader/writer
;; ---------------------------------------------------------------------

(defconst cmacs-ink-storage--marg-begin-rx
  "^[ \t]*#\\+BEGIN_INK_MARGINALIA\\(?:[ \t]+\\(.*\\)\\)?$")
(defconst cmacs-ink-storage--marg-end-rx
  "^[ \t]*#\\+END_INK_MARGINALIA[ \t]*$")
(defconst cmacs-ink-storage--rgn-begin-rx
  "^[ \t]*#\\+BEGIN_INK_REGION\\(?:[ \t]+\\(.*\\)\\)?$")
(defconst cmacs-ink-storage--rgn-end-rx
  "^[ \t]*#\\+END_INK_REGION[ \t]*$")

(defconst cmacs-ink-storage--marg-keys
  '(:id :line :hash :w :h :created)
  "Header key order for #+BEGIN_INK_MARGINALIA.")

(defconst cmacs-ink-storage--rgn-keys
  '(:id :start-line :start-col :end-line :end-col :hash :w :h :dx :dy :created)
  "Header key order for #+BEGIN_INK_REGION.

`:dx', `:dy' are the text-area-relative offsets from the start
glyph to the screenshot rect's top-left at capture time.  Older
blocks omit them; loaders default to 0 (correct for single-line
or top-left-anchored regions where start IS the rect's top-left).")

(defun cmacs-ink-storage--marginalia-anchor-to-block (anchor)
  "Format a marginalia ANCHOR plist (sidecar form) as an org block string."
  (let ((header
         (cmacs-ink-storage--format-header
          (list :id      (plist-get anchor :id)
                :line    (plist-get anchor :line)
                :hash    (plist-get anchor :line-hash)
                :w       (plist-get anchor :width)
                :h       (plist-get anchor :height)
                :created (plist-get anchor :created))
          cmacs-ink-storage--marg-keys))
        (strokes (plist-get anchor :strokes)))
    (concat
     "#+BEGIN_INK_MARGINALIA " header "\n"
     ";; cmacs-ink marginalia v1; one stroke per line for git-friendly diffs\n"
     (mapconcat (lambda (s) (format "%S" s)) strokes "\n")
     (when strokes "\n")
     "#+END_INK_MARGINALIA\n")))

(defun cmacs-ink-storage--region-anchor-to-block (anchor)
  "Format a region ANCHOR plist (sidecar form) as an org block string."
  (let ((header
         (cmacs-ink-storage--format-header
          (list :id         (plist-get anchor :id)
                :start-line (plist-get anchor :start-line)
                :start-col  (plist-get anchor :start-col)
                :end-line   (plist-get anchor :end-line)
                :end-col    (plist-get anchor :end-col)
                :hash       (plist-get anchor :region-hash)
                :w          (plist-get anchor :width)
                :h          (plist-get anchor :height)
                :dx         (plist-get anchor :capture-dx)
                :dy         (plist-get anchor :capture-dy)
                :created    (plist-get anchor :created))
          cmacs-ink-storage--rgn-keys))
        (strokes (plist-get anchor :strokes)))
    (concat
     "#+BEGIN_INK_REGION " header "\n"
     ";; cmacs-ink region v1; one stroke per line for git-friendly diffs\n"
     (mapconcat (lambda (s) (format "%S" s)) strokes "\n")
     (when strokes "\n")
     "#+END_INK_REGION\n")))

(defun cmacs-ink-storage--read-strokes-body (start end)
  "Read stroke S-exprs from buffer text [START..END), skipping ;; comments.
Returns a list of stroke forms."
  (let ((forms nil))
    (save-excursion
      (goto-char start)
      (while (< (point) end)
        (skip-chars-forward " \t\n\r")
        (cond
         ((looking-at ";;")
          (forward-line 1))
         ((>= (point) end) nil)
         (t
          (condition-case _err
              (let ((form (read (current-buffer))))
                (push form forms))
            (end-of-file (goto-char end))
            (invalid-read-syntax (forward-line 1))
            (error (forward-line 1)))))))
    (nreverse forms)))

(defun cmacs-ink-storage--block-from-buffer (begin-rx end-rx header-keys
                                                       extra-keys)
  "Find every BEGIN_RX..END_RX block and return a list of plists.
HEADER-KEYS are renamed verbatim from the header (`:id', `:hash'
etc.); EXTRA-KEYS is an alist that maps header keys to the
sidecar plist key — e.g. `((:hash . :line-hash))' for marginalia
where the inline header uses `:hash' but the sidecar plist
expects `:line-hash'."
  (let ((acc nil))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (while (re-search-forward begin-rx nil t)
          (let* ((header-str (match-string 1))
                 (header (cmacs-ink-storage--parse-header header-str))
                 (body-begin (line-beginning-position 2))
                 (body-end nil))
            (when (re-search-forward end-rx nil t)
              (setq body-end (match-beginning 0))
              (let* ((strokes
                      (cmacs-ink-storage--read-strokes-body
                       body-begin body-end))
                     ;; Translate inline-header key names → sidecar keys.
                     (translated nil))
                (dolist (k header-keys)
                  (let* ((sk (or (cdr (assq k extra-keys)) k))
                         (v  (plist-get header k)))
                    (when v
                      (setq translated (plist-put translated sk v)))))
                (setq translated (plist-put translated :strokes strokes))
                (push translated acc)))))))
    (nreverse acc)))

;; ---------------------------------------------------------------------
;; Inline section: locate / write
;; ---------------------------------------------------------------------

(defun cmacs-ink-storage--section-rx ()
  "Regexp matching the inline section heading."
  (concat "^\\*+[ \t]+"
          (regexp-quote cmacs-ink-storage-section-name)
          "\\(?:[ \t]+:.*:\\)?[ \t]*$"))

(defun cmacs-ink-storage--section-bounds ()
  "Return (BEGIN . END) of the inline section, or nil if absent.
BEGIN is the heading line bol; END is the position right after
the section's last char (i.e. where `org-end-of-subtree' lands)."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (when (re-search-forward (cmacs-ink-storage--section-rx) nil t)
        (let ((begin (line-beginning-position))
              end)
          (goto-char begin)
          (forward-line 1)
          (cond
           ((re-search-forward "^\\*+[ \t]" nil t)
            (setq end (line-beginning-position)))
           (t (setq end (point-max))))
          (cons begin end))))))

(defun cmacs-ink-storage--load-inline ()
  "Return (LINE-PLISTS . REGION-PLISTS) parsed from the inline section.
Returns nil if no section is present.  Both lists may be empty."
  (when (cmacs-ink-storage--section-bounds)
    (let ((line-anchors
           (cmacs-ink-storage--block-from-buffer
            cmacs-ink-storage--marg-begin-rx
            cmacs-ink-storage--marg-end-rx
            '(:id :line :hash :w :h :created)
            '((:hash . :line-hash)
              (:w    . :width)
              (:h    . :height))))
          (region-anchors
           (cmacs-ink-storage--block-from-buffer
            cmacs-ink-storage--rgn-begin-rx
            cmacs-ink-storage--rgn-end-rx
            '(:id :start-line :start-col :end-line :end-col
                  :hash :w :h :dx :dy :created)
            '((:hash . :region-hash)
              (:w    . :width)
              (:h    . :height)
              (:dx   . :capture-dx)
              (:dy   . :capture-dy)))))
      (cons line-anchors region-anchors))))

(defun cmacs-ink-storage--save-inline (line-plists region-plists)
  "Write LINE-PLISTS and REGION-PLISTS into the inline section.
Replaces any existing section.  No-op when both lists are empty
*and* no section already exists.  When both lists are empty *and*
a section exists, the section is deleted."
  (let ((existing (cmacs-ink-storage--section-bounds))
        (body
         (concat
          (mapconcat #'cmacs-ink-storage--marginalia-anchor-to-block
                     line-plists "\n")
          (when (and line-plists region-plists) "\n")
          (mapconcat #'cmacs-ink-storage--region-anchor-to-block
                     region-plists "\n"))))
    (cond
     ;; Nothing to write and no section — no-op.
     ((and (null line-plists) (null region-plists) (null existing))
      nil)
     ;; Empty payload — delete the existing section.
     ((and (null line-plists) (null region-plists) existing)
      (let ((cmacs-ink-storage--saving t)
            (inhibit-read-only t))
        (delete-region (car existing) (cdr existing))))
     ;; Replace existing or append new section.
     (t
      (let ((cmacs-ink-storage--saving t)
            (inhibit-read-only t)
            (heading
             (concat "* " cmacs-ink-storage-section-name
                     "\t\t\t\t\t\t\t :noexport:\n"
                     ":PROPERTIES:\n"
                     ":VISIBILITY: folded\n"
                     ":END:\n\n")))
        (cond
         (existing
          (delete-region (car existing) (cdr existing))
          (save-excursion
            (goto-char (car existing))
            (insert heading body)))
         (t
          (save-excursion
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (unless (looking-back "\n\n" 2) (insert "\n"))
            (insert heading body)))))))))

;; ---------------------------------------------------------------------
;; Sidecar: read (legacy + pretty) and write (pretty)
;; ---------------------------------------------------------------------

(defun cmacs-ink-storage--sidecar-path (&optional file)
  (let ((src (or file (buffer-file-name))))
    (when src (concat src ".cmacs-ink"))))

(defun cmacs-ink-storage--read-sidecar (path)
  "Read a sidecar file at PATH, returning a (LINE-PLISTS . REGION-PLISTS)
pair.  Handles both legacy single-line `prin1' form
(cmacs-ink/marginalia/1 and /2) and the new pretty-printed form."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      ;; Skip leading whitespace and `;;'-prefixed comment lines —
      ;; `read' from a buffer does not auto-skip them, and our
      ;; sidecar always starts with a generated header comment.
      (while (or (looking-at "[ \t\n\r]")
                 (looking-at ";;"))
        (cond
         ((looking-at ";;")
          (forward-line 1))
         (t (forward-char 1))))
      (let ((data (condition-case _err (read (current-buffer))
                    (error nil))))
        (when (and data (consp data))
          (let ((plist (car data)))
            (cons (or (plist-get plist :anchors) nil)
                  (or (plist-get plist :region-anchors) nil))))))))

(defun cmacs-ink-storage--save-sidecar (line-plists region-plists)
  "Write LINE-PLISTS and REGION-PLISTS to the sidecar, pretty-printed.
Deletes the file when both lists are empty.  On-disk shape is
still one big readable s-expr — but with structural newlines so
git diffs stay minimal as strokes change."
  (let* ((path (cmacs-ink-storage--sidecar-path))
         ;; Capture the source filename here — `(buffer-file-name)'
         ;; returns nil inside the `with-temp-file' block below.
         (src-name (and (buffer-file-name)
                        (file-name-nondirectory (buffer-file-name)))))
    (when path
      (cond
       ((and (null line-plists) (null region-plists))
        (when (file-exists-p path) (delete-file path)))
       (t
        (with-temp-file path
          (insert ";; cmacs-ink/marginalia v2 - generated; safe to hand-edit.\n")
          (insert "((:format \"cmacs-ink/marginalia/2\"\n")
          (insert (format "  :file %S\n" (or src-name "")))
          ;; Line anchors block.
          (insert "  :anchors")
          (cond
           ((null line-plists) (insert " nil\n"))
           (t
            (insert "\n  (\n")
            (dolist (a line-plists)
              (cmacs-ink-storage--prin1-anchor a 4))
            (insert "  )\n")))
          ;; Region anchors block.
          (insert "  :region-anchors")
          (cond
           ((null region-plists) (insert " nil))\n"))
           (t
            (insert "\n  (\n")
            (dolist (a region-plists)
              (cmacs-ink-storage--prin1-anchor a 4))
            (insert "  )))\n")))))))))

(defun cmacs-ink-storage--prin1-anchor (anchor indent)
  "Pretty-print ANCHOR plist at INDENT columns.
Strokes go on their own lines; everything else on the header
line.  Output is `read'-equivalent to a flat plist."
  (let ((pad (make-string indent ?\s))
        (strokes (plist-get anchor :strokes))
        (k anchor)
        first)
    (insert pad "(")
    (setq first t)
    (while k
      (let ((key (car k))
            (val (cadr k)))
        (unless (eq key :strokes)
          (unless first (insert " "))
          (insert (format "%s %S" key val))
          (setq first nil))
        (setq k (cddr k))))
    (cond
     ((null strokes)
      (insert " :strokes nil)\n"))
     (t
      (insert "\n" pad " :strokes\n")
      (insert pad "  (\n")
      (dolist (s strokes)
        (insert pad "   " (format "%S" s) "\n"))
      (insert pad "  ))\n")))))

;; ---------------------------------------------------------------------
;; Public dispatcher: load / save
;; ---------------------------------------------------------------------

(defun cmacs-ink--apply-loaded (line-plists region-plists)
  "Convert raw plists into in-memory anchor lists (with markers).
Replaces any existing buffer-local lists.  Auto-enables
`cmacs-ink-overlay-mode' when REGION-PLISTS is non-empty so the
strokes are visible immediately on file open without the user
having to toggle anything."
  ;; Tear down old marginalia overlays.
  (mapc (lambda (a)
          (when (cmacs-ink-marginalia-anchor-overlay a)
            (delete-overlay (cmacs-ink-marginalia-anchor-overlay a))))
        cmacs-ink-marginalia--anchors)
  (setq cmacs-ink-marginalia--anchors nil)
  (dolist (p line-plists)
    (let ((a (cmacs-ink-marginalia--anchor-from-plist p)))
      (cmacs-ink-marginalia--bind-anchor a)
      (cmacs-ink-marginalia--make-overlay a)
      (push a cmacs-ink-marginalia--anchors)))
  ;; `dolist + push' reverses order; flip back so the on-disk order
  ;; round-trips faithfully and `git diff' doesn't see a swap on
  ;; every save.
  (setq cmacs-ink-marginalia--anchors
        (nreverse cmacs-ink-marginalia--anchors))
  (setq cmacs-ink-marginalia--dirty nil)
  ;; Tear down old region markers.
  (mapc (lambda (a)
          (let ((s (plist-get a :start-marker))
                (e (plist-get a :end-marker)))
            (when s (set-marker s nil))
            (when e (set-marker e nil))))
        cmacs-ink-region--annotations)
  (setq cmacs-ink-region--annotations nil)
  (dolist (p region-plists)
    (push (cmacs-ink-region--anchor-from-plist p)
          cmacs-ink-region--annotations))
  (setq cmacs-ink-region--annotations
        (nreverse cmacs-ink-region--annotations))
  (setq cmacs-ink-region--dirty nil)
  ;; Make annotations visible right away.  The C paint hook is gated
  ;; on `cmacs-ink-overlay-mode' being t in the buffer; without this,
  ;; opening a file with annotations would render nothing until the
  ;; user manually toggles the mode.
  (when (and region-plists
             (fboundp 'cmacs-ink-overlay-mode)
             (not (bound-and-true-p cmacs-ink-overlay-mode)))
    (cmacs-ink-overlay-mode 1)))

(defun cmacs-ink--collect-for-save ()
  "Return (LINE-PLISTS . REGION-PLISTS) ready to hand to a writer."
  (let ((line-plists
         (mapcar #'cmacs-ink-marginalia--anchor-to-plist
                 cmacs-ink-marginalia--anchors))
        (region-plists
         (mapcar #'cmacs-ink-region--anchor-to-plist
                 cmacs-ink-region--annotations)))
    (cons line-plists region-plists)))

(defun cmacs-ink--load ()
  "Load annotations from inline section or sidecar.
Tries inline first; if no section is present (or non-org), falls
back to the sidecar.  Bound to `find-file-hook' by
`cmacs-ink-mode'.  Echoes a one-line summary so the user knows
strokes were loaded and where to scroll to see them."
  (when (buffer-file-name)
    (let* ((inline (and (derived-mode-p 'org-mode)
                        (cmacs-ink-storage--load-inline)))
           (data (or inline
                     (cmacs-ink-storage--read-sidecar
                      (cmacs-ink-storage--sidecar-path)))))
      (when data
        (cmacs-ink--apply-loaded (car data) (cdr data))
        ;; Tell the user where their annotations live so a quiet
        ;; "where are my strokes" question gets answered.
        (let ((line-count (length cmacs-ink-marginalia--anchors))
              (region-count (length cmacs-ink-region--annotations))
              (region-lines
               (delq nil
                     (mapcar (lambda (a)
                               (let ((m (plist-get a :start-marker)))
                                 (and m (marker-position m)
                                      (line-number-at-pos
                                       (marker-position m)))))
                             cmacs-ink-region--annotations))))
          (cond
           ((and (zerop line-count) (zerop region-count)) nil)
           (t
            (message
             "cmacs-ink: %s%s%s"
             (if (zerop line-count) ""
               (format "%d marginalia " line-count))
             (if (zerop region-count) ""
               (format "%d region overlay%s on lines %s "
                       region-count
                       (if (= region-count 1) "" "s")
                       region-lines))
             (if (and (display-graphic-p)
                      (not (bound-and-true-p cmacs-ink-overlay-mode))
                      (> region-count 0))
                 "(M-x cmacs-ink-overlay-mode to render)"
               "")))))))))

(defun cmacs-ink--save ()
  "Save annotations using the active storage policy.
Bound to `after-save-hook' by `cmacs-ink-mode'.  Inline writes
modify the buffer; the recursive after-save call is gated by
`cmacs-ink-storage--saving'."
  (when (and (buffer-file-name)
             (not cmacs-ink-storage--saving)
             (or cmacs-ink-marginalia--dirty
                 cmacs-ink-region--dirty
                 ;; Also re-emit when storage mode changes — e.g.
                 ;; user flipped to 'inline; we want next save to
                 ;; remove the now-stale sidecar.
                 (cmacs-ink-storage--mode-changed-p)))
    (let* ((mode (cmacs-ink-storage--mode-for-buffer))
           (data (cmacs-ink--collect-for-save))
           (line-plists   (car data))
           (region-plists (cdr data)))
      (pcase mode
        ('inline
         ;; Drop any old sidecar so we don't have two sources of truth.
         (let ((stale (cmacs-ink-storage--sidecar-path)))
           (when (and stale (file-exists-p stale))
             (delete-file stale)))
         (cmacs-ink-storage--save-inline line-plists region-plists)
         ;; The buffer was modified — save it again so the inline
         ;; section actually lands on disk.
         (let ((cmacs-ink-storage--saving t))
           (when (buffer-modified-p)
             (save-buffer))))
        ('sidecar
         (cmacs-ink-storage--save-sidecar line-plists region-plists)))
      (setq cmacs-ink-marginalia--dirty nil
            cmacs-ink-region--dirty nil
            cmacs-ink-storage--last-mode mode))))

(defun cmacs-ink-storage--mode-changed-p ()
  "Non-nil if storage mode would change relative to the last save."
  (and cmacs-ink-storage--last-mode
       (not (eq cmacs-ink-storage--last-mode
                (cmacs-ink-storage--mode-for-buffer)))))

;; ---------------------------------------------------------------------
;; Migration command
;; ---------------------------------------------------------------------

;;;###autoload
(defun cmacs-ink-migrate-to-inline ()
  "Migrate the current org buffer's `<file>.cmacs-ink' sidecar into
an inline `* cmacs-ink' section.  Errors when not in org-mode.

After writing the inline section and saving the buffer, prompts
to delete the now-redundant sidecar file."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "cmacs-ink-migrate-to-inline: requires an org buffer"))
  (let* ((path (cmacs-ink-storage--sidecar-path))
         (data (and path (cmacs-ink-storage--read-sidecar path))))
    (unless data
      (user-error "cmacs-ink-migrate-to-inline: no sidecar at %s"
                  (or path "<no buffer file>")))
    (let* ((line-plists   (car data))
           (region-plists (cdr data)))
      (cmacs-ink-storage--save-inline line-plists region-plists)
      (let ((cmacs-ink-storage--saving t))
        (save-buffer))
      ;; Pin storage to inline for this buffer so the next save
      ;; doesn't regenerate the sidecar (e.g. when the user has a
      ;; project-wide `(setq cmacs-ink-storage 'sidecar)' but
      ;; explicitly migrated this one file).
      (setq-local cmacs-ink-storage 'inline)
      (setq cmacs-ink-storage--last-mode 'inline)
      ;; Refresh the in-memory anchor lists from the migrated data
      ;; so overlays / paint hook reflect the current state right
      ;; away — without this, the buffer-local lists would still
      ;; hold whatever was loaded before migration (potentially
      ;; nil if the user just opened the file).
      (cmacs-ink--apply-loaded line-plists region-plists)
      (when (and path (file-exists-p path)
                 (yes-or-no-p
                  (format "Delete %s? " (file-name-nondirectory path))))
        (delete-file path)
        (message "cmacs-ink: migrated to inline; sidecar removed")))))

(provide 'cmacs-ink-storage)
;;; cmacs-ink-storage.el ends here
