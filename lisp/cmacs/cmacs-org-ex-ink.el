;;; cmacs-org-ex-ink.el --- #+BEGIN_INK canvas blocks for org-ex  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; F1 of cmacs-ink: inline ink-canvas blocks inside org files.
;;
;; Block format (canonical, hand-editable, git-friendly):
;;
;;   #+BEGIN_INK :id 7e3a-9b21 :w 800 :h 400 :v 1
;;   ;; cmacs-ink v1; one stroke per line for git-friendly diffs
;;   (s :t pen :c "#222" :w 2 :p ((123 245 850) (130 250 860)))
;;   #+END_INK
;;
;; Rendering: an SVG image overlay covers the block body so the
;; reader sees ink instead of stroke s-exprs.  The underlying buffer
;; text is unchanged — `save-buffer' writes the canonical form.
;;
;; Editing: place point inside the block, M-x cmacs-org-ex-ink-edit
;; (C-c i e by default) opens the modal capture window.  On commit
;; the block body is rewritten in-place and the overlay refreshed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-org-ex-ink nil
  "Embedded ink canvases for org-ex."
  :group 'cmacs-org-ex
  :prefix "cmacs-org-ex-ink-")

(defcustom cmacs-org-ex-ink-default-width 800
  "Default canvas width in pixels for new ink blocks."
  :type 'integer
  :group 'cmacs-org-ex-ink)

(defcustom cmacs-org-ex-ink-default-height 400
  "Default canvas height in pixels for new ink blocks."
  :type 'integer
  :group 'cmacs-org-ex-ink)

(defcustom cmacs-org-ex-ink-default-colour "#222"
  "Default pen colour for new strokes."
  :type 'string
  :group 'cmacs-org-ex-ink)

(defcustom cmacs-org-ex-ink-default-base-width 2.0
  "Default pen base width in pixels."
  :type 'number
  :group 'cmacs-org-ex-ink)

(defcustom cmacs-org-ex-ink-side-button-erases t
  "If non-nil, button-2 in the capture window acts as eraser.
Provides an eraser-end fallback for tools without one."
  :type 'boolean
  :group 'cmacs-org-ex-ink)

(defcustom cmacs-org-ex-ink-auto-render t
  "If non-nil, automatically overlay SVG rendering on `find-file' and saves.
Set to nil to keep blocks visible as raw stroke s-exprs."
  :type 'boolean
  :group 'cmacs-org-ex-ink)

;; ---------------------------------------------------------------------
;; Block discovery & header parsing
;; ---------------------------------------------------------------------

(defconst cmacs-org-ex-ink--begin-rx
  "^[ \t]*#\\+BEGIN_INK\\(?:[ \t]+\\(.*\\)\\)?$"
  "Match a #+BEGIN_INK header line.  Group 1 = the header keyword arglist.")

(defconst cmacs-org-ex-ink--end-rx
  "^[ \t]*#\\+END_INK[ \t]*$"
  "Match a #+END_INK closer line.")

(defun cmacs-org-ex-ink--parse-header-args (s)
  "Parse :keyword value pairs out of S into an alist of (KEY . VALUE).
KEY is a keyword symbol like :id, value is a string."
  (let ((acc nil)
        (pos 0))
    (when s
      (while (string-match
              "[ \t]*:\\([A-Za-z_-]+\\)[ \t]+\\([^ \t]+\\)"
              s pos)
        (push (cons (intern (concat ":" (match-string 1 s)))
                    (match-string 2 s))
              acc)
        (setq pos (match-end 0))))
    (nreverse acc)))

(defun cmacs-org-ex-ink--header-int (alist key default)
  (let ((v (cdr (assq key alist))))
    (if (and v (string-match-p "\\`-?[0-9]+\\'" v))
        (string-to-number v)
      default)))

(cl-defstruct cmacs-org-ex-ink-block
  begin-line-bol      ;; pos at start of #+BEGIN_INK line
  begin-line-eol      ;; pos at end of #+BEGIN_INK line
  body-begin          ;; pos right after newline of begin
  body-end            ;; pos right before #+END_INK line
  end-line-bol
  end-line-eol
  args                ;; alist of header keyword args
  width
  height
  id)

(defun cmacs-org-ex-ink--block-at-point ()
  "Return the `cmacs-org-ex-ink-block' surrounding point, or nil."
  (save-excursion
    (let ((origin (point))
          begin-bol begin-eol body-begin body-end end-bol end-eol args)
      (beginning-of-line)
      ;; Search backward for #+BEGIN_INK before point
      (when (re-search-backward cmacs-org-ex-ink--begin-rx nil t)
        (setq begin-bol (match-beginning 0))
        (setq args (cmacs-org-ex-ink--parse-header-args (match-string 1)))
        (end-of-line)
        (setq begin-eol (point))
        (forward-char 1)
        (setq body-begin (point))
        ;; Find next #+END_INK
        (when (re-search-forward cmacs-org-ex-ink--end-rx nil t)
          (setq end-bol (match-beginning 0))
          (setq end-eol (match-end 0))
          (setq body-end end-bol)
          ;; Origin must be inside [begin-bol, end-eol]
          (when (and (>= origin begin-bol) (<= origin end-eol))
            (make-cmacs-org-ex-ink-block
             :begin-line-bol begin-bol
             :begin-line-eol begin-eol
             :body-begin     body-begin
             :body-end       body-end
             :end-line-bol   end-bol
             :end-line-eol   end-eol
             :args           args
             :id             (cdr (assq :id args))
             :width  (cmacs-org-ex-ink--header-int
                      args :w cmacs-org-ex-ink-default-width)
             :height (cmacs-org-ex-ink--header-int
                      args :h cmacs-org-ex-ink-default-height))))))))

(defun cmacs-org-ex-ink--find-block-by-id (id)
  "Find the #+BEGIN_INK block whose `:id' equals ID and return it.
Returns a fresh `cmacs-org-ex-ink-block' computed from a buffer
scan, or nil if no such block exists.  Used by write paths so a
commit cannot trample buffer text just because the position
captured at edit-time has drifted (auto-revert, concurrent
edits, the user accidentally launching another capture, etc.)."
  (when (and id (stringp id) (not (string-empty-p id)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let (found)
          (while (and (not found)
                      (re-search-forward
                       cmacs-org-ex-ink--begin-rx nil t))
            (let* ((begin-bol (match-beginning 0))
                   (begin-eol (match-end 0))
                   (args (cmacs-org-ex-ink--parse-header-args
                          (match-string 1)))
                   (matched-id (cdr (assq :id args))))
              (when (and matched-id (string= matched-id id))
                (forward-char 1)
                (let ((body-begin (point)))
                  (when (re-search-forward
                         cmacs-org-ex-ink--end-rx nil t)
                    (let ((end-bol (match-beginning 0))
                          (end-eol (match-end 0)))
                      (setq found
                            (make-cmacs-org-ex-ink-block
                             :begin-line-bol begin-bol
                             :begin-line-eol begin-eol
                             :body-begin     body-begin
                             :body-end       end-bol
                             :end-line-bol   end-bol
                             :end-line-eol   end-eol
                             :args           args
                             :id             matched-id
                             :width  (cmacs-org-ex-ink--header-int
                                      args :w
                                      cmacs-org-ex-ink-default-width)
                             :height (cmacs-org-ex-ink--header-int
                                      args :h
                                      cmacs-org-ex-ink-default-height)))))))))
          found)))))

(defun cmacs-org-ex-ink--map-blocks (fn)
  "Call FN with each `cmacs-org-ex-ink-block' in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (while (re-search-forward cmacs-org-ex-ink--begin-rx nil t)
      (let* ((begin-bol (match-beginning 0))
             (begin-eol (match-end 0))
             (args (cmacs-org-ex-ink--parse-header-args
                    (match-string 1)))
             body-begin body-end end-bol end-eol)
        (forward-char 1)
        (setq body-begin (point))
        (when (re-search-forward cmacs-org-ex-ink--end-rx nil t)
          (setq end-bol (match-beginning 0)
                end-eol (match-end 0)
                body-end end-bol)
          (funcall fn
                   (make-cmacs-org-ex-ink-block
                    :begin-line-bol begin-bol
                    :begin-line-eol begin-eol
                    :body-begin     body-begin
                    :body-end       body-end
                    :end-line-bol   end-bol
                    :end-line-eol   end-eol
                    :args           args
                    :id             (cdr (assq :id args))
                    :width  (cmacs-org-ex-ink--header-int
                             args :w cmacs-org-ex-ink-default-width)
                    :height (cmacs-org-ex-ink--header-int
                             args :h cmacs-org-ex-ink-default-height))))))))

;; ---------------------------------------------------------------------
;; Block body <-> stroke set
;; ---------------------------------------------------------------------

(defun cmacs-org-ex-ink--block-body-string (block)
  (buffer-substring-no-properties
   (cmacs-org-ex-ink-block-body-begin block)
   (cmacs-org-ex-ink-block-body-end   block)))

(defun cmacs-org-ex-ink--block-strokes (block)
  "Parse BLOCK's body to a stroke set (or empty if blank/malformed)."
  (let ((text (cmacs-org-ex-ink--block-body-string block)))
    (if (string-blank-p text)
        (org-ex-ink-strokes-empty)
      (condition-case _err
          (org-ex-ink-strokes-from-string text)
        (error (org-ex-ink-strokes-empty))))))

(defun cmacs-org-ex-ink--write-block-body (block strokes)
  "Replace BLOCK's body with the serialised STROKES set.

Re-resolves BLOCK by its `:id' against the current buffer just
before deleting, so stale positions captured before the modal
capture window opened cannot cause us to delete content outside
the intended block.  Refuses to write (signals an error) if the
block can no longer be located — the user-side strokes remain
intact for a retry rather than corrupting other text."
  (let* ((id (cmacs-org-ex-ink-block-id block))
         (target (cmacs-org-ex-ink--find-block-by-id id)))
    (unless target
      (error
       "cmacs-ink: block %s not found in buffer; refusing to write \
(strokes preserved — re-edit a block to retry)"
       (or id "<no-id>")))
    (let* ((inhibit-read-only t)
           (text  (org-ex-ink-strokes-to-string strokes))
           (begin (cmacs-org-ex-ink-block-body-begin target))
           (end   (cmacs-org-ex-ink-block-body-end   target)))
      ;; Defence in depth: confirm the resolved range is bounded by
      ;; #+BEGIN_INK above and #+END_INK below.  If the scan above
      ;; somehow hands us a degenerate range, we'd rather error than
      ;; trample text.
      (save-excursion
        (goto-char begin)
        (forward-line -1)
        (unless (looking-at cmacs-org-ex-ink--begin-rx)
          (error
           "cmacs-ink: body-begin %d not preceded by #+BEGIN_INK; \
refusing to write" begin))
        (goto-char end)
        (unless (looking-at cmacs-org-ex-ink--end-rx)
          (error
           "cmacs-ink: body-end %d not at #+END_INK; refusing to write"
           end)))
      (save-excursion
        (delete-region begin end)
        (goto-char begin)
        (insert ";; cmacs-ink v1; one stroke per line for git-friendly diffs\n")
        (insert text)))))

;; ---------------------------------------------------------------------
;; SVG overlay
;; ---------------------------------------------------------------------

(defvar-local cmacs-org-ex-ink--overlays nil
  "List of overlays installed by `cmacs-org-ex-ink-render-buffer'.")

(defun cmacs-org-ex-ink--clear-overlays ()
  (mapc #'delete-overlay cmacs-org-ex-ink--overlays)
  (setq cmacs-org-ex-ink--overlays nil))

(defun cmacs-org-ex-ink--make-overlay (block strokes)
  "Install an image overlay covering BLOCK's body region."
  (let* ((svg (org-ex-ink-strokes-to-svg
               strokes
               (cmacs-org-ex-ink-block-width block)
               (cmacs-org-ex-ink-block-height block)))
         (img (create-image svg 'svg t
                            :scale 1.0
                            :ascent 'center))
         ;; Overlay spans body-begin..body-end so the header line and
         ;; #+END_INK closer remain visible (they tell the reader this
         ;; is a canvas) but the raw strokes hide behind the image.
         (ov (make-overlay
              (cmacs-org-ex-ink-block-body-begin block)
              (cmacs-org-ex-ink-block-body-end block)
              nil t nil)))
    (overlay-put ov 'cmacs-org-ex-ink t)
    (overlay-put ov 'display img)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'modification-hooks
                 (list (lambda (o _after _b _e &rest _)
                         (when (overlay-buffer o)
                           (delete-overlay o)
                           (setq cmacs-org-ex-ink--overlays
                                 (delq o cmacs-org-ex-ink--overlays))))))
    (push ov cmacs-org-ex-ink--overlays)
    ov))

(defun cmacs-org-ex-ink-render-buffer ()
  "Refresh image overlays for every #+BEGIN_INK block in the buffer.
No-op in non-graphic frames (e.g. terminal, batch)."
  (interactive)
  (cmacs-org-ex-ink--clear-overlays)
  (when (display-graphic-p)
    (cmacs-org-ex-ink--map-blocks
     (lambda (block)
       (let ((strokes (cmacs-org-ex-ink--block-strokes block)))
         (cmacs-org-ex-ink--make-overlay block strokes))))))

(defun cmacs-org-ex-ink-unrender-buffer ()
  "Remove ink image overlays so the raw stroke s-exprs are visible."
  (interactive)
  (cmacs-org-ex-ink--clear-overlays))

;; ---------------------------------------------------------------------
;; Insertion / editing
;; ---------------------------------------------------------------------

(defun cmacs-org-ex-ink--new-id ()
  "Generate a short unique block id like `7e3a-9b21'."
  (format "%04x-%04x" (random #x10000) (random #x10000)))

(defun cmacs-org-ex-ink--escape-enclosing-block ()
  "If point is inside a #+BEGIN_INK block, move past its #+END_INK.
Returns t if it had to move, nil otherwise.  Inserting a new
block while point is inside an existing one would nest the new
block inside the old one, causing the next commit on either to
delete content across both bodies."
  (let ((existing (cmacs-org-ex-ink--block-at-point)))
    (when existing
      (goto-char (cmacs-org-ex-ink-block-end-line-eol existing))
      (when (and (not (eobp)) (eq (char-after) ?\n))
        (forward-char 1))
      t)))

(defun cmacs-org-ex-ink--park-after-block (id)
  "Move point onto the line AFTER the #+END_INK of block ID."
  (let ((b (cmacs-org-ex-ink--find-block-by-id id)))
    (when b
      (goto-char (cmacs-org-ex-ink-block-end-line-eol b))
      (when (and (not (eobp)) (eq (char-after) ?\n))
        (forward-char 1))
      t)))

;;;###autoload
(defun cmacs-org-ex-ink-insert (&optional no-edit width height)
  "Insert an empty #+BEGIN_INK canvas on the line below point.

The block always lands on its own line — point's current line is
never bisected, and if point is already inside another #+BEGIN_INK
block it is moved past that block's #+END_INK first so the new
block is never nested inside the old one.

Unless NO-EDIT is non-nil (or a prefix argument is given), the
capture window opens immediately so you can start drawing.  When
the function returns, point is left on the line *after* #+END_INK
so subsequent typing can never accidentally leak into the body."
  (interactive "P")
  (cmacs-org-ex-ink--escape-enclosing-block)
  (let ((w (or width  cmacs-org-ex-ink-default-width))
        (h (or height cmacs-org-ex-ink-default-height))
        (id (cmacs-org-ex-ink--new-id))
        block-start)
    ;; Always start the block on a fresh line below whatever the user
    ;; is on — never bisect their cursor position.
    (unless (bolp)
      (end-of-line)
      (insert "\n"))
    (setq block-start (point))
    (insert (format "#+BEGIN_INK :id %s :w %d :h %d :v 1\n" id w h))
    (insert ";; cmacs-ink v1; one stroke per line for git-friendly diffs\n")
    (insert "#+END_INK\n")
    ;; Pin a marker AFTER the block so we can restore point there
    ;; once everything (including the auto-edit) has finished —
    ;; surviving any body-rewrite that happens during the capture
    ;; commit.  insertion-type t = advance on insertions before, so
    ;; the marker stays past the block as the body grows.
    (let ((after-block (point-marker)))
      (set-marker-insertion-type after-block t)
      (unwind-protect
          (progn
            (when cmacs-org-ex-ink-auto-render
              (cmacs-org-ex-ink-render-buffer))
            (message "cmacs-ink: block %s inserted (%dx%d)" id w h)
            (redisplay t)
            (cond
             ((and (not no-edit) (display-graphic-p))
              ;; Position inside block so `cmacs-org-ex-ink-edit'
              ;; can resolve the surrounding block via point.
              (goto-char block-start)
              (forward-line 1)
              (end-of-line)
              (message "cmacs-ink: opening capture window…")
              (redisplay t)
              (cmacs-org-ex-ink-edit))))
        ;; Always land outside the block on exit.
        (when (marker-position after-block)
          (goto-char after-block))
        (set-marker after-block nil)))))

;;;###autoload
(defun cmacs-org-ex-ink-edit ()
  "Edit the ink block at point in the modal capture window.
On commit, point is left on the line AFTER #+END_INK so that
subsequent typing cannot leak into the block body."
  (interactive)
  (let ((block (cmacs-org-ex-ink--block-at-point)))
    (unless block
      (user-error "Point is not inside a #+BEGIN_INK block"))
    (let* ((id (cmacs-org-ex-ink-block-id block))
           (initial (cmacs-org-ex-ink--block-strokes block))
           (result  (org-ex-ink-capture
                     initial
                     (cmacs-org-ex-ink-block-width block)
                     (cmacs-org-ex-ink-block-height block)
                     cmacs-org-ex-ink-default-colour
                     cmacs-org-ex-ink-default-base-width
                     cmacs-org-ex-ink-side-button-erases))
           (new-strokes (car result))
           (cancelled   (cdr result)))
      (cond
       (cancelled
        (message "cmacs-ink: edit cancelled"))
       (t
        (cmacs-org-ex-ink--write-block-body block new-strokes)
        (when cmacs-org-ex-ink-auto-render
          (cmacs-org-ex-ink-render-buffer))
        ;; Park point AFTER the (possibly re-resolved) block so that
        ;; whatever the user types next cannot fall inside the body.
        (cmacs-org-ex-ink--park-after-block id)
        (message "cmacs-ink: %d stroke(s)"
                 (org-ex-ink-strokes-count new-strokes)))))))

;;;###autoload
(defun cmacs-org-ex-ink-toggle-render ()
  "Toggle between raw (stroke s-expr) and rendered (SVG) view."
  (interactive)
  (if cmacs-org-ex-ink--overlays
      (cmacs-org-ex-ink-unrender-buffer)
    (cmacs-org-ex-ink-render-buffer)))

(defun cmacs-org-ex-ink--maybe-render ()
  "After-find / after-save hook: render blocks if auto-render is on."
  (when (and cmacs-org-ex-ink-auto-render
             (save-excursion
               (goto-char (point-min))
               (re-search-forward cmacs-org-ex-ink--begin-rx nil t)))
    (cmacs-org-ex-ink-render-buffer)))

(provide 'cmacs-org-ex-ink)
;;; cmacs-org-ex-ink.el ends here
