;;; cmacs-office.el --- Office documents as org buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Opening a .docx, .xlsx, .pptx, .odt, .ods or .odp gives you an org
;; buffer of its contents instead of a page image.  You can read it,
;; search it, yank from it, and hand it to an agent.
;;
;; The buffer is a PROJECTION, not the document.  The document itself
;; stays open behind it as a C handle (`cmacs-office--handle'), and that
;; handle is what edits go through -- the org text is never re-parsed to
;; reconstruct the original.  That split is deliberate: projecting a
;; format we only partly understand is safe precisely because the
;; projection is never the thing we save.
;;
;; Anchors.  Every block carries where it came from -- the package part,
;; a stable id the file itself provides, and its ordinal within that
;; part.  Headings get them as org properties, where they are visible
;; and greppable; the complete table for every block, heading or not,
;; is kept buffer-locally in `cmacs-office--blocks'.  Writeback resolves
;; by id first, because an id survives edits elsewhere in the document
;; while an ordinal does not.
;;
;; Opening transforms the visited buffer IN PLACE (see
;; `cmacs-office--open-file'), the way `doc-view-mode' and `archive-mode'
;; do.  An earlier version killed the buffer and switched to a new one,
;; which broke badly in practice: completion frameworks preview a
;; candidate by visiting it, so merely moving the cursor over a file
;; name split a window and stole focus.
;;
;; The buffer keeps visiting the document, so `save-buffer' has to be
;; intercepted -- `write-contents-functions' routes it to
;; `cmacs-office-save-document', and auto-save is turned off.  Without
;; that, saving would write this org text into report.docx.
;;
;; Editing.  The org text itself is read-only -- typing in the buffer
;; would edit the projection, not the document, and saving that would
;; mean reconstructing the original from its own summary.  Instead the
;; editing commands act through the handle: `cmacs-office-edit-cell' on a
;; spreadsheet, and the `cmacs-office-set-block' /
;; `cmacs-office-set-slide-text' primitives for prose and slides.  Each
;; queues its change; `cmacs-office-save-document' writes it.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-office-supported-p "src/cmacs-office-defuns.c")
(declare-function cmacs-office-open "src/cmacs-office-defuns.c" (path))
(declare-function cmacs-office-close "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-path "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-format "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-kind "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-family "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-main-part "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-metadata "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-blocks "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-cells "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-office-sheet-names "src/cmacs-office-defuns.c" (handle))
(declare-function cmacs-evil-setup-mode-map "cmacs-evil" (map mode))
(declare-function cmacs-office-formula-eval "cmacs-office-formula"
                  (formula cells &optional sheet))

(defgroup cmacs-office nil
  "Native OOXML and OpenDocument support."
  :group 'cmacs
  :prefix "cmacs-office-")

(defcustom cmacs-office-max-cell-columns 64
  "Widest org table `cmacs-office' will render for a spreadsheet.

Sheets are frequently far wider than anything readable.  Columns past
this are summarised rather than rendered, which keeps the projection
useful instead of turning it into a horizontal scroll."
  :type 'integer
  :safe #'integerp
  :group 'cmacs-office)

(defcustom cmacs-office-show-metadata t
  "Whether to include a document properties section in the projection."
  :type 'boolean
  :safe #'booleanp
  :group 'cmacs-office)

(defvar-local cmacs-office--handle nil
  "The C handle for the document this buffer projects.")

(defvar-local cmacs-office--source nil
  "Absolute path of the document this buffer projects.")

(defvar-local cmacs-office--blocks nil
  "Every extracted block, in document order.

The complete anchor table: each entry is the plist `cmacs-office-blocks'
returned, carrying :part, :id and :index.  Headings also expose these as
org properties, but body paragraphs have nowhere to put them, so this is
the authoritative copy.")

(defvar-local cmacs-office--cells nil
  "Every extracted cell, for a spreadsheet projection.")

(defun cmacs-office-available-p ()
  "Return non-nil when this build has Office document support."
  (and (fboundp 'cmacs-office-supported-p)
       (cmacs-office-supported-p)))

(defun cmacs-office--require ()
  "Signal unless this build has Office document support."
  (unless (cmacs-office-available-p)
    (user-error "cmacs was not built with --with-cmacs-office")))

;;; Rendering

(defun cmacs-office--insert-header (handle)
  "Insert the org preamble describing HANDLE."
  (let* ((path (cmacs-office-path handle))
         (meta (cmacs-office-metadata handle))
         (title (or (plist-get meta :title)
                    (file-name-base path))))
    (insert (format "#+TITLE: %s\n" title))
    (insert (format "#+CMACS_OFFICE_SOURCE: %s\n" path))
    (insert (format "#+CMACS_OFFICE_FORMAT: %s\n" (cmacs-office-format handle)))
    (insert (format "#+CMACS_OFFICE_KIND: %s\n" (cmacs-office-kind handle)))
    (when-let* ((main (cmacs-office-main-part handle)))
      (insert (format "#+CMACS_OFFICE_MAIN_PART: %s\n" main)))
    (insert "#+STARTUP: showall\n")
    (insert "\n")
    (when (and cmacs-office-show-metadata meta)
      (insert "* Document properties\n:PROPERTIES:\n")
      (cl-loop for (k v) on meta by #'cddr
               do (insert (format ":%s: %s\n"
                                  (upcase (substring (symbol-name k) 1))
                                  v)))
      (insert ":END:\n\n"))))

(defun cmacs-office--block-properties (block)
  "Return the org property drawer text anchoring BLOCK, or nil."
  (let ((part (plist-get block :part))
        (id (plist-get block :id))
        (index (plist-get block :index)))
    (concat ":PROPERTIES:\n"
            (when part (format ":CMACS_OFFICE_PART: %s\n" part))
            (when id (format ":CMACS_OFFICE_ID: %s\n" id))
            (format ":CMACS_OFFICE_INDEX: %d\n" (or index 0))
            (when-let* ((style (plist-get block :style)))
              (format ":CMACS_OFFICE_STYLE: %s\n" style))
            ":END:\n")))

(defun cmacs-office--render-text (blocks)
  "Insert BLOCKS as an org document projection."
  (dolist (b blocks)
    (let ((level (or (plist-get b :level) 0))
          (text (or (plist-get b :text) "")))
      (cond
       ;; A heading becomes an org heading, and carries its anchor as
       ;; properties where they are visible and greppable.
       ((> level 0)
        (insert (make-string (min level 9) ?*) " " text "\n")
        (insert (cmacs-office--block-properties b)))
       ;; Blank paragraphs are structure in the original, so they are
       ;; preserved as blank lines rather than dropped.
       ((string-empty-p (string-trim text))
        (insert "\n"))
       (t (insert text "\n\n"))))))

(defun cmacs-office--render-slides (blocks)
  "Insert BLOCKS as an org outline, one heading per slide."
  (let ((current nil))
    (dolist (b blocks)
      (let ((slide (or (plist-get b :slide) 0))
            (text (or (plist-get b :text) "")))
        (unless (equal slide current)
          (setq current slide)
          (insert (format "* Slide %d\n" slide))
          (insert (cmacs-office--block-properties b)))
        (when-let* ((shape (plist-get b :shape)))
          (insert (format "** %s\n" shape)))
        (insert text "\n\n")))))

(defun cmacs-office--sheet-rows (cells sheet)
  "Return CELLS belonging to SHEET grouped into rows.
Each row is (ROW-NUMBER . ((COL . TEXT) ...))."
  (let ((rows (make-hash-table :test #'eql)))
    (dolist (c cells)
      (when (equal sheet (plist-get c :sheet))
        (push (cons (plist-get c :col)
                    (or (plist-get c :text) ""))
              (gethash (plist-get c :row) rows))))
    (sort (let (out)
            (maphash (lambda (row cols)
                       (push (cons row (sort cols #'car-less-than-car)) out))
                     rows)
            out)
          #'car-less-than-car)))

(defun cmacs-office--render-sheet (handle cells)
  "Insert CELLS from HANDLE as one org table per sheet."
  (dolist (sheet (cmacs-office-sheet-names handle))
    (let* ((rows (cmacs-office--sheet-rows cells sheet))
           (width (apply #'max 0 (mapcar (lambda (r)
                                           (apply #'max 0 (mapcar #'car (cdr r))))
                                         rows)))
           (shown (min width cmacs-office-max-cell-columns)))
      (insert (format "* %s\n" sheet))
      (insert ":PROPERTIES:\n")
      (insert (format ":CMACS_OFFICE_SHEET: %s\n" sheet))
      (insert (format ":CMACS_OFFICE_ROWS: %d\n" (length rows)))
      (insert (format ":CMACS_OFFICE_COLUMNS: %d\n" width))
      (insert ":END:\n\n")
      (if (null rows)
          (insert "(empty)\n\n")
        (when (> width shown)
          (insert (format "# %d of %d columns shown; see `cmacs-office-max-cell-columns'\n"
                          shown width)))
        (dolist (row rows)
          (insert "|")
          (dotimes (i shown)
            (let* ((col (1+ i))
                   (cell (assq col (cdr row)))
                   (start (point)))
              (insert (format " %s |"
                              (cmacs-office--escape-cell (if cell (cdr cell) ""))))
              ;; The address travels with the text, so editing can work
              ;; from point without re-deriving coordinates by counting
              ;; pipes -- which breaks the moment a value contains one.
              (put-text-property start (point) 'cmacs-office-cell
                                 (list sheet (car row) col))))
          (insert "\n"))
        (insert "\n")))))

(defun cmacs-office--escape-cell (text)
  "Return TEXT safe to place inside an org table cell."
  (replace-regexp-in-string
   "|" "\\\\vert{}"
   (replace-regexp-in-string "\n" " " (string-trim text))))

(defun cmacs-office--render (handle)
  "Render the projection of HANDLE into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (cmacs-office--insert-header handle)
    (pcase (cmacs-office-kind handle)
      ('sheet
       (setq cmacs-office--cells (cmacs-office-cells handle))
       (cmacs-office--render-sheet handle cmacs-office--cells))
      ('slides
       (setq cmacs-office--blocks (cmacs-office-blocks handle))
       (cmacs-office--render-slides cmacs-office--blocks))
      ('text
       (setq cmacs-office--blocks (cmacs-office-blocks handle))
       (cmacs-office--render-text cmacs-office--blocks))
      (_
       (insert "This package was not recognised as an Office document.\n\n")
       (insert "Its parts are still readable with `cmacs-office-part-names'\n")
       (insert "and `cmacs-office-part-bytes'.\n")))
    (goto-char (point-min))
    (set-buffer-modified-p nil)))

;;; Plain text

;;;###autoload
(defun cmacs-office-text (handle)
  "Return the readable text of the document HANDLE, as a string.

Spreadsheets come back row by row with cells separated by tabs;
everything else comes back paragraph by paragraph.  Intended for
searching, for yanking, and for handing to an agent."
  (cmacs-office--require)
  (if (eq 'sheet (cmacs-office-kind handle))
      (let ((cells (cmacs-office-cells handle))
            (out nil))
        (dolist (sheet (cmacs-office-sheet-names handle))
          (push sheet out)
          (dolist (row (cmacs-office--sheet-rows cells sheet))
            (push (mapconcat (lambda (c) (string-trim (cdr c))) (cdr row) "\t")
                  out)))
        (string-join (nreverse out) "\n"))
    (mapconcat (lambda (b) (or (plist-get b :text) ""))
               (cmacs-office-blocks handle)
               "\n")))

;;; Commands

;; Deliberately NOT `cmacs-office-revert': that name belongs to the C
;; primitive that drops queued part edits, and defining it here would
;; silently shadow it for every caller once this file loads.
(defun cmacs-office-refresh ()
  "Re-read the document from disk and redraw the projection."
  (interactive)
  (unless cmacs-office--handle
    (user-error "Not an Office projection buffer"))
  ;; Reopen rather than re-extract: the file may have changed underneath
  ;; us, and the handle holds the state it had at open time.
  (let ((path cmacs-office--source))
    (cmacs-office-close cmacs-office--handle)
    (setq cmacs-office--handle (cmacs-office-open path))
    (cmacs-office--render cmacs-office--handle))
  (message "Reverted %s" (file-name-nondirectory cmacs-office--source)))

(defun cmacs-office-export-org (file)
  "Write this projection to FILE."
  (interactive
   (list (read-file-name "Write org projection to: "
                         nil nil nil
                         (concat (file-name-nondirectory
                                  (or cmacs-office--source "office"))
                                 ".org"))))
  (unless cmacs-office--handle
    (user-error "Not an Office projection buffer"))
  (write-region (point-min) (point-max) file)
  (message "Wrote %s" file))

(defun cmacs-office-find-source ()
  "Visit the original document's directory in Dired."
  (interactive)
  (unless cmacs-office--source
    (user-error "Not an Office projection buffer"))
  (dired (file-name-directory cmacs-office--source)))

;;; Editing

(defun cmacs-office--cell-at-point ()
  "Return (SHEET ROW COL) for the spreadsheet cell at point, or nil."
  (get-text-property (point) 'cmacs-office-cell))

(defun cmacs-office-cell-info ()
  "Describe the cell at point, evaluating its formula if it has one."
  (interactive)
  (let ((at (cmacs-office--cell-at-point)))
    (unless at
      (user-error "Point is not on a spreadsheet cell"))
    (pcase-let ((`(,sheet ,row ,col) at))
      (let* ((cell (seq-find (lambda (c)
                               (and (equal sheet (plist-get c :sheet))
                                    (= row (plist-get c :row))
                                    (= col (plist-get c :col))))
                             cmacs-office--cells))
             (formula (and cell (plist-get cell :formula))))
        (if (null formula)
            (message "%s!%s%d = %s" sheet
                     (cmacs-office--column-name col) row
                     (if cell (plist-get cell :text) ""))
          (let ((computed (and (require 'cmacs-office-formula nil t)
                               (cmacs-office-formula-eval
                                formula cmacs-office--cells sheet))))
            (message "%s!%s%d = %s   [%s]%s" sheet
                     (cmacs-office--column-name col) row
                     (plist-get cell :text) formula
                     (if computed
                         (format " -> %s" computed)
                       "  (formula uses something this build does not evaluate)"))))))))

(defun cmacs-office--column-name (col)
  "Return the A1-style column name for the 1-based COL."
  (let ((out ""))
    (while (> col 0)
      (setq out (concat (char-to-string (+ ?A (mod (1- col) 26))) out)
            col (/ (1- col) 26)))
    out))

(defun cmacs-office-edit-cell (value)
  "Set the spreadsheet cell at point to VALUE.

The edit is queued, not written: `cmacs-office-save-document' is what
reaches the file.  A VALUE beginning with `=' is stored as a formula."
  (interactive
   (let ((at (or (cmacs-office--cell-at-point)
                 (user-error "Point is not on a spreadsheet cell"))))
     (pcase-let ((`(,sheet ,row ,col) at))
       (list (read-string
              (format "%s!%s%d: " sheet (cmacs-office--column-name col) row)
              (let ((cell (seq-find
                           (lambda (c)
                             (and (equal sheet (plist-get c :sheet))
                                  (= row (plist-get c :row))
                                  (= col (plist-get c :col))))
                           cmacs-office--cells)))
                (cond ((null cell) "")
                      ((plist-get cell :formula)
                       (concat "=" (plist-get cell :formula)))
                      (t (plist-get cell :text)))))))))
  (let ((at (or (cmacs-office--cell-at-point)
                (user-error "Point is not on a spreadsheet cell")))
        (line (line-number-at-pos))
        (column (current-column)))
    (pcase-let ((`(,sheet ,row ,col) at))
      (if (string-prefix-p "=" value)
          (cmacs-office-set-cell cmacs-office--handle sheet row col
                                 nil (substring value 1))
        (cmacs-office-set-cell cmacs-office--handle sheet row col value nil))
      ;; Re-render from the handle: queued edits read back as themselves,
      ;; so the projection updates without touching the file.
      (cmacs-office--render cmacs-office--handle)
      (goto-char (point-min))
      (forward-line (1- line))
      (move-to-column column)
      ;; After the redraw, because rendering clears the flag.
      (set-buffer-modified-p (cmacs-office-dirty-p cmacs-office--handle))
      (message "%s!%s%d set; %s" sheet
               (cmacs-office--column-name col) row
               (substitute-command-keys
                "\\[cmacs-office-save-document] to write it back")))))

(defun cmacs-office-save-document ()
  "Write queued edits back to the document this buffer projects.

Named apart from the `cmacs-office-save' primitive on purpose: an Elisp
function sharing a DEFUN's name would silently replace it."
  (interactive)
  (unless cmacs-office--handle
    (user-error "Not an Office projection buffer"))
  (if (not (cmacs-office-dirty-p cmacs-office--handle))
      (message "No unsaved changes")
    (cmacs-office-save cmacs-office--handle)
    (cmacs-office--render cmacs-office--handle)
    (message "Wrote %s" (file-name-nondirectory cmacs-office--source))))

(defun cmacs-office-discard-edits ()
  "Drop every queued edit and redraw from what is on disk."
  (interactive)
  (unless cmacs-office--handle
    (user-error "Not an Office projection buffer"))
  (cmacs-office-revert cmacs-office--handle)
  (cmacs-office--render cmacs-office--handle)
  (message "Discarded unsaved changes"))

(defun cmacs-office--cleanup ()
  "Release the handle backing this buffer."
  (when cmacs-office--handle
    (ignore-errors (cmacs-office-close cmacs-office--handle))
    (setq cmacs-office--handle nil)))

(defvar cmacs-office-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'cmacs-office-refresh)
    (define-key map (kbd "e") #'cmacs-office-edit-cell)
    (define-key map (kbd "RET") #'cmacs-office-edit-cell)
    (define-key map (kbd "=") #'cmacs-office-cell-info)
    (define-key map (kbd "C-x C-s") #'cmacs-office-save-document)
    (define-key map (kbd "C-c C-k") #'cmacs-office-discard-edits)
    (define-key map (kbd "C-c C-e") #'cmacs-office-export-org)
    (define-key map (kbd "C-c C-f") #'cmacs-office-find-source)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-office-mode'.")

;;;###autoload
(define-derived-mode cmacs-office-mode org-mode "Office"
  "Major mode for the org projection of an Office document.

The buffer is a projection: typing in it does not edit the document.
Edits go through the handle behind it -- \[cmacs-office-edit-cell] on a
spreadsheet cell -- and \[cmacs-office-save-document] writes them back.

\\{cmacs-office-mode-map}"
  (setq-local buffer-read-only t)
  (setq-local org-startup-folded nil)
  ;; The buffer still visits the document, so Emacs must be stopped from
  ;; ever writing this org text into it -- by `save-buffer' or by an
  ;; auto-save timer.
  (add-hook 'write-contents-functions #'cmacs-office--write-contents nil t)
  (setq-local revert-buffer-function #'cmacs-office--revert)
  (setq buffer-auto-save-file-name nil)
  (auto-save-mode -1)
  (setq-local header-line-format
              '(:eval (when cmacs-office--handle
                        (format " %s  %s  %s%s"
                                (cmacs-office-format cmacs-office--handle)
                                (cmacs-office-kind cmacs-office--handle)
                                (file-name-nondirectory
                                 (or cmacs-office--source ""))
                                (if (cmacs-office-dirty-p cmacs-office--handle)
                                    "  [unsaved]" "")))))
  (add-hook 'kill-buffer-hook #'cmacs-office--cleanup nil t))

(when (fboundp 'cmacs-evil-setup-mode-map)
  (cmacs-evil-setup-mode-map cmacs-office-mode-map 'cmacs-office-mode))

;;;###autoload
(defun cmacs-office-find-file (path)
  "Open the Office document at PATH as an org projection."
  (interactive "fOffice document: ")
  (cmacs-office--require)
  ;; Just visit it: `auto-mode-alist' routes to `cmacs-office--open-file',
  ;; which builds the projection in place.  Going through `find-file'
  ;; rather than around it means buffer reuse, `recentf', bookmarks and
  ;; everything else behave normally.
  (find-file (expand-file-name path)))

;;;###autoload
(defun cmacs-office--open-file ()
  "`auto-mode-alist' entry: turn the visited buffer into a projection.

Transforms the CURRENT buffer in place.  That matters more than it
sounds: minibuffer completion frameworks preview a candidate by
VISITING it, so a mode function that kills its own buffer and calls
`switch-to-buffer' splits windows and steals focus every time you move
the cursor over a file name -- without anyone pressing RET.

Emacs's own binary-ish modes all work this way (`doc-view-mode',
`archive-mode', `image-mode'): the visited buffer is where the new
presentation goes."
  (let ((file buffer-file-name))
    (when file
      (let ((inhibit-read-only t))
        (erase-buffer))
      ;; `cmacs-office-mode' runs `kill-all-local-variables', so the
      ;; handle has to be stashed after it, not before.
      (cmacs-office-mode)
      (setq cmacs-office--handle (cmacs-office-open file)
            cmacs-office--source file)
      (cmacs-office--render cmacs-office--handle))))

(defun cmacs-office--write-contents ()
  "Make \\[save-buffer] save the document rather than the projection.

Installed in `write-contents-functions', which runs before Emacs would
write the buffer text out.  Without it, saving a buffer still visiting
report.docx would put org text into report.docx.  Returns non-nil to
say the save is handled."
  (when cmacs-office--handle
    (cmacs-office-save-document)
    t))

(defun cmacs-office--revert (&rest _)
  "`revert-buffer-function': re-read the document and redraw."
  (cmacs-office-refresh))

(defconst cmacs-office-file-regexp
  "\\.\\(?:docx\\|xlsx\\|pptx\\|odt\\|ods\\|odp\\)\\'"
  "Files `cmacs-office' claims from `doc-view-mode'.")

;; The entry is a bare `add-to-list' rather than a call into this file,
;; because the autoloaded form runs during `loadup' -- before this file
;; is loadable.  Anything that calls a function defined here breaks the
;; dump.  `add-to-list' prepends, which is what matters: `lisp/files.el'
;; already maps these extensions to `doc-view-mode-maybe' and the first
;; match wins.
;;;###autoload
(add-to-list 'auto-mode-alist
             '("\\.\\(?:docx\\|xlsx\\|pptx\\|odt\\|ods\\|odp\\)\\'"
               . cmacs-office--open-file))

;; The cookie goes on the DEFUN, which only emits an `autoload' stub --
;; safe.  What broke the dump earlier was cookieing a top-level FORM
;; that CALLED this during `loadup', before the file was loadable.
;;;###autoload
(defun cmacs-office-install-auto-mode ()
  "Re-assert the `auto-mode-alist' entry for Office documents.

Normally unnecessary -- the entry is installed by the autoloads.  It is
needed in configurations that rebuild `auto-mode-alist' during startup
\(Doom does\), which drops entries added before the rebuild."
  (interactive)
  (setq auto-mode-alist
        (cons (cons cmacs-office-file-regexp #'cmacs-office--open-file)
              (assoc-delete-all cmacs-office-file-regexp auto-mode-alist)))
  auto-mode-alist)

(provide 'cmacs-office)
;;; cmacs-office.el ends here
