;;; cmacs-dbexplorer-grid.el --- The result grid  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Rows on screen.  This is the view everything else exists to feed.
;;
;; Three decisions shape the file.
;;
;; The table is laid out with `:align-to' display specifications and not
;; with padding alone.  A space is one column wide; a glyph is whatever
;; the font says it is, and the NULL glyph in particular is
;; East-Asian-Ambiguous, so `string-width' says one and a graphical frame
;; draws two.  Padding by a width that is wrong cannot produce a straight
;; edge.  Each column is therefore padded *and* anchored: the padding is
;; what makes the plain text line up when the buffer is copied out, the
;; anchor is what makes the display line up when the two disagree.  The
;; brigade dashboard learned this the hard way and the technique is lifted
;; from it wholesale.
;;
;; Sorting, filtering and paging are re-queries, never Elisp.  The grid
;; holds one page; sorting the page in Lisp would sort the five hundred
;; rows the database happened to hand over first and present the answer as
;; if it were the table's order, which is a lie that looks exactly like
;; the truth.  Identifiers going into the ORDER BY are quoted by the
;; dialect, through `cmacs-dbexplorer-quote'.
;;
;; And an arbitrary statement is never rewritten.  Browse results know
;; their table, so the grid composes their SQL and may page, sort and
;; filter it.  A statement the user wrote is theirs: it is sent as
;; written, capped with `:max-rows', and the cap is shown rather than
;; papered over.  Wrapping someone's SQL in a subquery to sort it is how
;; you turn their query into a different query with the same name.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-dbexplorer)
(require 'cmacs-evil)

(declare-function cmacs-dbexplorer--table-info-async
                  "src/cmacs-dbexplorer-defuns.c" (handle schema table cb))

;; The editing layer decorates rows and owns the staged/immediate
;; indicator.  It requires this file, so it cannot be required back at top
;; level; the grid asks for it when it opens a buffer and calls into it
;; only through these four functions.
(declare-function cmacs-dbexplorer-edit-indicator "cmacs-dbexplorer-edit" ())
(declare-function cmacs-dbexplorer-edit-cell-override "cmacs-dbexplorer-edit"
                  (result row column))
(declare-function cmacs-dbexplorer-edit-row-decoration "cmacs-dbexplorer-edit"
                  (result row))
(declare-function cmacs-dbexplorer-edit-pending-inserts "cmacs-dbexplorer-edit"
                  ())
(declare-function cmacs-dbexplorer-export-menu "cmacs-dbexplorer-export" ())
(declare-function cmacs-dbexplorer-sql "cmacs-dbexplorer-sql"
                  (&optional connection))


;;;; Customization ------------------------------------------------------

(defcustom cmacs-dbexplorer-column-max-width 40
  "Widest a grid column is drawn, in display columns.

A column of paragraphs would otherwise push every column after it off
the screen; the whole value is still one `RET' away in the cell buffer."
  :type 'integer
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-column-min-width 3
  "Narrowest a grid column is drawn, in display columns."
  :type 'integer
  :group 'cmacs-dbexplorer)

(defconst cmacs-dbexplorer-grid--gutter 2
  "Display columns reserved before the first column for row markers.")


;;;; Buffer state -------------------------------------------------------

(defvar-local cmacs-dbexplorer-grid--result nil
  "The `cmacs-dbexplorer-result' this buffer is showing.")

(defvar-local cmacs-dbexplorer-grid--source nil
  "How to run this buffer's query again, as a plist.

`:kind' is `browse' -- with `:schema', `:table' and `:primary-key' -- or
`sql', with `:sql' and `:params'.  The difference decides whether the
grid may compose ORDER BY, WHERE and LIMIT around it.")

(defvar-local cmacs-dbexplorer-grid--sort nil
  "The active sort, as (COLUMN-NAME . `asc'/`desc'), or nil.")

(defvar-local cmacs-dbexplorer-grid--filter nil
  "The active WHERE fragment, or nil.")

(defvar-local cmacs-dbexplorer-grid--offset 0
  "The row offset of the page being shown.")

(defvar-local cmacs-dbexplorer-grid--column 0
  "The column the cursor is in, as an index into the result's columns.")

(defvar-local cmacs-dbexplorer-grid--stream nil
  "The id of the query currently filling this buffer, or nil.")

(defvar-local cmacs-dbexplorer-grid--status nil
  "A one-line status shown under the header, or nil.")

(defun cmacs-dbexplorer-grid-result ()
  "Return the result this buffer is showing, or signal."
  (or cmacs-dbexplorer-grid--result
      (user-error "cmacs-dbexplorer: this grid has no rows yet")))

(defun cmacs-dbexplorer-grid-buffer-name (connection-name)
  "Return the grid buffer name for CONNECTION-NAME."
  (format "*dbexplorer-results: %s*" connection-name))


;;;; Layout -------------------------------------------------------------

(defun cmacs-dbexplorer-grid--cell-string (cell)
  "Return CELL as display text."
  (cmacs-dbexplorer-cell-display cell (cmacs-dbexplorer-glyph 'null)))

(defun cmacs-dbexplorer-grid--numeric-p (column)
  "Return non-nil when COLUMN holds numbers and reads better flush right."
  (let ((type (plist-get column :type)))
    (and type
         (string-match-p "int\\|num\\|dec\\|real\\|float\\|double\\|serial"
                         (downcase (format "%s" type)))
         t)))

(defun cmacs-dbexplorer-grid--cell (result row column)
  "Return (VALUE . FACE) for the cell shown at ROW and COLUMN of RESULT.

A staged edit's value stands in for the stored one, so what is measured,
what is drawn and what is about to be committed are all the same string."
  (let ((staged (and (fboundp 'cmacs-dbexplorer-edit-cell-override)
                     (cmacs-dbexplorer-edit-cell-override result row column))))
    (or staged (cons (cmacs-dbexplorer-result-cell result row column) nil))))

(defun cmacs-dbexplorer-grid--widths (result)
  "Return the display width of each of RESULT's columns.

Measured over the page actually being shown, so the table is as narrow as
this page allows rather than as wide as the schema permits."
  (let ((columns (cmacs-dbexplorer-result-columns result))
        (rows (cmacs-dbexplorer-result-rows result))
        (widths nil))
    (dotimes (column (length columns))
      (let ((width (string-width
                    (format "%s" (plist-get (aref columns column) :name)))))
        (dotimes (row (length rows))
          (let ((cells (aref rows row)))
            (when (< column (length cells))
              (setq width (max width (string-width
                                      (cmacs-dbexplorer-grid--cell-string
                                       (car (cmacs-dbexplorer-grid--cell
                                             result row column)))))))))
        (push (max cmacs-dbexplorer-column-min-width
                   (min cmacs-dbexplorer-column-max-width width))
              widths)))
    (nreverse widths)))

(defun cmacs-dbexplorer-grid--offsets (widths)
  "Return the display column each of WIDTHS starts at.

One space separates columns, and the gutter comes first, so the offsets
are exactly the character offsets of the padded text as well -- which is
what lets the anchors and the padding agree."
  (let ((at cmacs-dbexplorer-grid--gutter)
        (out nil))
    (dolist (width widths)
      (push at out)
      (setq at (+ at width 1)))
    (nreverse out)))

(defun cmacs-dbexplorer-grid--fit (text width)
  "Return TEXT truncated to WIDTH display columns, with an ellipsis."
  (if (<= (string-width text) width)
      text
    (truncate-string-to-width text width nil nil
                              (cmacs-dbexplorer-glyph 'ellipsis))))

(defun cmacs-dbexplorer-grid--row (widths cells &optional right marker)
  "Lay CELLS out in columns of WIDTHS, returning one line.

RIGHT is a list of booleans, one per column, saying which are flush
right.  MARKER is the gutter text.

Each cell is padded to its nominal width and also anchored to its
absolute display column: the padding is what makes the text line up when
the buffer is copied out or read by something that ignores display
properties, and the anchor is what makes the display line up when a glyph
turns out to be wider than its character count claims.  Where the two
disagree the anchor absorbs the difference."
  (let ((offsets (cmacs-dbexplorer-grid--offsets widths))
        (parts (list (cmacs-dbexplorer-grid--gutter-text marker)))
        (index 0))
    (dolist (width widths)
      (let* ((raw (or (nth index cells) ""))
             (text (cmacs-dbexplorer-grid--fit raw width))
             (pad (make-string (max 0 (- width (string-width text))) ?\s))
             (at (nth index offsets)))
        (setq text (if (nth index right) (concat pad text) (concat text pad)))
        ;; The separator carries the PREVIOUS column's index, so the
        ;; position where the column property changes is exactly where
        ;; that column's text begins -- which is what cell navigation
        ;; and the alignment test both key on.
        (when (> index 0)
          (push (propertize " " 'display `(space :align-to ,at)
                            'cmacs-dbexplorer-column (1- index))
                parts))
        (push (propertize text 'cmacs-dbexplorer-column index) parts)
        (setq index (1+ index))))
    (apply #'concat (nreverse parts))))

(defun cmacs-dbexplorer-grid--gutter-text (marker)
  "Return the gutter for MARKER, padded to the gutter width."
  (let ((text (or marker "")))
    (concat text (make-string (max 0 (- cmacs-dbexplorer-grid--gutter
                                        (string-width text)))
                              ?\s))))


;;;; Rendering ----------------------------------------------------------

(defun cmacs-dbexplorer-grid--header-line ()
  "Return the header line: which rows these are and how they may be written."
  (let* ((result cmacs-dbexplorer-grid--result)
         (connection (cmacs-dbexplorer-buffer-connection))
         (source cmacs-dbexplorer-grid--source))
    (concat
     " " (propertize (or cmacs-dbexplorer--connection-name "?")
                     'face 'cmacs-dbexplorer-header)
     (when (eq (plist-get source :kind) 'browse)
       (concat "  " (propertize (format "%s%s"
                                        (if (plist-get source :schema)
                                            (concat (plist-get source :schema) ".")
                                          "")
                                        (or (plist-get source :table) ""))
                                'face 'cmacs-dbexplorer-table)))
     (when result
       (format "  %d row%s%s" (cmacs-dbexplorer-result-row-count result)
               (if (= 1 (cmacs-dbexplorer-result-row-count result)) "" "s")
               (if (cmacs-dbexplorer-result-truncated result)
                   (concat " " (cmacs-dbexplorer-glyph 'more))
                 "")))
     (when (and result (cmacs-dbexplorer-result-elapsed-ms result))
       (format "  %sms" (cmacs-dbexplorer-result-elapsed-ms result)))
     (when (and connection (cmacs-dbexplorer-connection-read-only connection))
       (concat "  " (propertize "[READ-ONLY]"
                                'face 'cmacs-dbexplorer-read-only)))
     (when (and connection
                (cmacs-dbexplorer-connection-in-transaction connection))
       (concat "  " (propertize "[TXN]" 'face 'cmacs-dbexplorer-read-only)))
     (when (fboundp 'cmacs-dbexplorer-edit-indicator)
       (concat "  " (cmacs-dbexplorer-edit-indicator))))))

(defun cmacs-dbexplorer-grid--insert-header (result widths)
  "Insert the column header row for RESULT over columns of WIDTHS."
  (let* ((columns (cmacs-dbexplorer-result-columns result))
         (primary-key (cmacs-dbexplorer-result-primary-key result))
         (names nil)
         (right nil))
    (dotimes (index (length columns))
      (let* ((column (aref columns index))
             (name (format "%s" (plist-get column :name)))
             (sort (and (equal name (car cmacs-dbexplorer-grid--sort))
                        (cdr cmacs-dbexplorer-grid--sort))))
        (push (propertize (concat name (pcase sort ('asc " ^") ('desc " v") (_ "")))
                          'face (if (member name primary-key)
                                    'cmacs-dbexplorer-key
                                  'cmacs-dbexplorer-header))
              names)
        (push (cmacs-dbexplorer-grid--numeric-p column) right)))
    (insert (cmacs-dbexplorer-grid--row widths (nreverse names)
                                        (nreverse right))
            "\n")
    ;; The rule matches the table it underlines, derived from the same
    ;; widths rather than from a constant that stops matching the moment
    ;; a column changes: gutter, every column, and one separator between
    ;; each pair of them.
    (insert (make-string (+ cmacs-dbexplorer-grid--gutter
                            (apply #'+ widths)
                            (max 0 (1- (length widths))))
                         (string-to-char (cmacs-dbexplorer-glyph 'rule)))
            "\n")))

(defun cmacs-dbexplorer-grid--row-cells (result row widths)
  "Return RESULT's ROW as display strings, faced, for columns of WIDTHS."
  (let ((out nil))
    (dotimes (column (length widths))
      (let* ((pair (cmacs-dbexplorer-grid--cell result row column))
             (cell (car pair))
             (text (cmacs-dbexplorer-grid--cell-string cell))
             (face (or (cdr pair)
                       (and (eq cell :null) 'cmacs-dbexplorer-null)
                       ;; A blob was never sent; its size stands in for it
                       ;; and is not data to be read as data.
                       (and (consp cell) 'shadow))))
        (push (if face (propertize text 'face face) text) out)))
    (nreverse out)))

(defun cmacs-dbexplorer-grid--insert-row (result row widths right)
  "Insert RESULT's ROW using WIDTHS and the RIGHT alignment flags."
  (let* ((decoration (and (fboundp 'cmacs-dbexplorer-edit-row-decoration)
                          (cmacs-dbexplorer-edit-row-decoration result row)))
         (line (cmacs-dbexplorer-grid--row
                widths (cmacs-dbexplorer-grid--row-cells result row widths)
                right (car decoration))))
    (when (cdr decoration)
      (setq line (propertize line 'face (cdr decoration))))
    ;; The row index and its key travel with the line: a command acts on
    ;; what the cursor is on, and a redraw finds the same row again by
    ;; key rather than by counting lines.
    (insert (propertize line
                        'cmacs-dbexplorer-row row
                        'cmacs-dbexplorer-row-key
                        (cmacs-dbexplorer-result-row-key result row))
            "\n")))

(defun cmacs-dbexplorer-grid--insert-inserts (result widths right)
  "Insert the rows staged for insertion into RESULT."
  (when (fboundp 'cmacs-dbexplorer-edit-pending-inserts)
    (dolist (edit (cmacs-dbexplorer-edit-pending-inserts))
      (let* ((columns (cmacs-dbexplorer-result-column-names result))
             (values (cmacs-dbexplorer-edit-values edit))
             (cells (mapcar (lambda (name)
                              (let ((cell (assoc name values)))
                                (if cell
                                    (cmacs-dbexplorer-grid--cell-string (cdr cell))
                                  (propertize (cmacs-dbexplorer-glyph 'null)
                                              'face 'cmacs-dbexplorer-null))))
                            columns)))
        (insert (propertize
                 (propertize (cmacs-dbexplorer-grid--row
                              widths cells right
                              (cmacs-dbexplorer-glyph 'inserted))
                             'face 'cmacs-dbexplorer-staged-insert)
                 'cmacs-dbexplorer-edit edit)
                "\n")))))

(defun cmacs-dbexplorer-grid--render ()
  "Redraw this grid, keeping the cursor on the row and column it was on."
  (let* ((result cmacs-dbexplorer-grid--result)
         (inhibit-read-only t)
         (line (line-number-at-pos))
         (column cmacs-dbexplorer-grid--column)
         ;; Per window: each shows its own point, and the buffer's own is
         ;; stale whenever the grid is visible but not selected -- which
         ;; is exactly the case while a prompt is open.
         (saved (mapcar (lambda (window)
                          (cons window (cmacs-dbexplorer-grid--key-at
                                        (window-point window))))
                        (get-buffer-window-list (current-buffer) nil t)))
         (here (cmacs-dbexplorer-grid--key-at (point))))
    (erase-buffer)
    (if (null result)
        (cmacs-dbexplorer-grid--insert-empty)
      (let* ((widths (cmacs-dbexplorer-grid--widths result))
             (right (mapcar #'cmacs-dbexplorer-grid--numeric-p
                            (append (cmacs-dbexplorer-result-columns result)
                                    nil))))
        (cmacs-dbexplorer-grid--insert-header result widths)
        (dotimes (row (cmacs-dbexplorer-result-row-count result))
          (cmacs-dbexplorer-grid--insert-row result row widths right))
        (cmacs-dbexplorer-grid--insert-inserts result widths right)
        (when (cmacs-dbexplorer-result-truncated result)
          (insert (propertize
                   (format "  %s more rows; ] for the next page\n"
                           (cmacs-dbexplorer-glyph 'more))
                   'face 'shadow)))))
    (when cmacs-dbexplorer-grid--status
      (insert "\n " (propertize cmacs-dbexplorer-grid--status 'face 'shadow)
              "\n"))
    (insert "\n" (cmacs-dbexplorer-grid--legend))
    (goto-char (or (cmacs-dbexplorer-grid--pos-of-key here)
                   (progn (goto-char (point-min))
                          (forward-line (1- line))
                          (point))))
    (cmacs-dbexplorer-grid-goto-column column)
    (dolist (cell saved)
      (when (window-live-p (car cell))
        (set-window-point (car cell)
                          (or (cmacs-dbexplorer-grid--pos-of-key (cdr cell))
                              (point)))))))

(defun cmacs-dbexplorer-grid--insert-empty ()
  "Say what an empty grid is waiting for."
  (insert "\n  No rows yet.\n\n")
  (insert "    Open a table from the schema tree, or write a statement\n")
  (insert "    in the SQL buffer and press C-c C-c.\n"))

(defun cmacs-dbexplorer-grid-refresh ()
  "Redraw the grid from the result it already has."
  (interactive)
  (cmacs-dbexplorer-grid--render))


;;;; Point, rows and cells ----------------------------------------------

(defun cmacs-dbexplorer-grid--key-at (position)
  "Return the row key at POSITION, or nil."
  (when (and position (<= (point-min) position) (<= position (point-max)))
    (get-text-property (save-excursion (goto-char position)
                                       (line-beginning-position))
                       'cmacs-dbexplorer-row-key)))

(defun cmacs-dbexplorer-grid--pos-of-key (key)
  "Return where the row named by KEY begins after a redraw, or nil."
  (when key
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (not (eobp))
          (when (equal key (get-text-property (point) 'cmacs-dbexplorer-row-key))
            (throw 'found (point)))
          (forward-line 1))
        nil))))

(defun cmacs-dbexplorer-grid-row-at-point ()
  "Return the result row index at point, or nil."
  (get-text-property (line-beginning-position) 'cmacs-dbexplorer-row))

(defun cmacs-dbexplorer-grid-row-at-point-or-error ()
  "Return the result row index at point, or signal."
  (or (cmacs-dbexplorer-grid-row-at-point)
      (user-error "No row on this line")))

(defun cmacs-dbexplorer-grid-edit-at-point ()
  "Return the staged insert on this line, or nil."
  (get-text-property (line-beginning-position) 'cmacs-dbexplorer-edit))

(defun cmacs-dbexplorer-grid-column-at-point ()
  "Return the column index at point, defaulting to the tracked column."
  (or (get-text-property (point) 'cmacs-dbexplorer-column)
      cmacs-dbexplorer-grid--column))

(defun cmacs-dbexplorer-grid-column-count ()
  "Return how many columns this grid has."
  (if cmacs-dbexplorer-grid--result
      (length (cmacs-dbexplorer-result-columns cmacs-dbexplorer-grid--result))
    0))

(defun cmacs-dbexplorer-grid-goto-column (column)
  "Move point to COLUMN on this line, as far as the line allows."
  (let ((target (min (max 0 column)
                     (1- (max 1 (cmacs-dbexplorer-grid-column-count)))))
        (start (line-beginning-position))
        (end (line-end-position)))
    (when (get-text-property start 'cmacs-dbexplorer-row-key)
      (goto-char start))
    (let ((position start))
      (while (and (< position end)
                  (not (eql target (get-text-property
                                    position 'cmacs-dbexplorer-column))))
        (setq position (or (next-single-property-change
                            position 'cmacs-dbexplorer-column nil end)
                           end)))
      (when (< position end)
        (goto-char position)
        (setq cmacs-dbexplorer-grid--column target)))))

(defun cmacs-dbexplorer-grid-next-cell ()
  "Move to the next cell on this line."
  (interactive)
  (cmacs-dbexplorer-grid-goto-column
   (1+ (cmacs-dbexplorer-grid-column-at-point))))

(defun cmacs-dbexplorer-grid-previous-cell ()
  "Move to the previous cell on this line."
  (interactive)
  (cmacs-dbexplorer-grid-goto-column
   (1- (cmacs-dbexplorer-grid-column-at-point))))

(defun cmacs-dbexplorer-grid-next-row ()
  "Move to the next row, keeping the column."
  (interactive)
  (let ((column (cmacs-dbexplorer-grid-column-at-point)))
    (forward-line 1)
    (cmacs-dbexplorer-grid-goto-column column)))

(defun cmacs-dbexplorer-grid-previous-row ()
  "Move to the previous row, keeping the column."
  (interactive)
  (let ((column (cmacs-dbexplorer-grid-column-at-point)))
    (forward-line -1)
    (cmacs-dbexplorer-grid-goto-column column)))

(defun cmacs-dbexplorer-grid-cell-value ()
  "Return the raw cell at point."
  (let ((row (cmacs-dbexplorer-grid-row-at-point))
        (column (cmacs-dbexplorer-grid-column-at-point)))
    (if row
        (cmacs-dbexplorer-result-cell (cmacs-dbexplorer-grid-result) row column)
      (let ((edit (cmacs-dbexplorer-grid-edit-at-point)))
        (when edit
          (cdr (assoc (nth column (cmacs-dbexplorer-result-column-names
                                   (cmacs-dbexplorer-grid-result)))
                      (cmacs-dbexplorer-edit-values edit))))))))


;;;; Querying -----------------------------------------------------------

(defun cmacs-dbexplorer-grid--order-by (connection)
  "Return the ORDER BY clause for the active sort on CONNECTION, or \"\"."
  (if (null cmacs-dbexplorer-grid--sort)
      ""
    (format " ORDER BY %s %s"
            (cmacs-dbexplorer-quote connection (car cmacs-dbexplorer-grid--sort))
            (if (eq (cdr cmacs-dbexplorer-grid--sort) 'desc) "DESC" "ASC"))))

(defun cmacs-dbexplorer-grid--where ()
  "Return the WHERE clause for the active filter, or \"\"."
  (if (or (null cmacs-dbexplorer-grid--filter)
          (string-empty-p cmacs-dbexplorer-grid--filter))
      ""
    (format " WHERE %s" cmacs-dbexplorer-grid--filter)))

(defun cmacs-dbexplorer-grid--browse-sql (connection)
  "Return the SQL for this buffer's browse source on CONNECTION.

One more row than a page is asked for, so a full page and a full page
with more behind it are distinguishable."
  (let ((source cmacs-dbexplorer-grid--source))
    (format "SELECT * FROM %s%s%s LIMIT %d OFFSET %d"
            (cmacs-dbexplorer-qualified-name connection
                                             (plist-get source :schema)
                                             (plist-get source :table))
            (cmacs-dbexplorer-grid--where)
            (cmacs-dbexplorer-grid--order-by connection)
            (1+ cmacs-dbexplorer-page-size)
            cmacs-dbexplorer-grid--offset)))

(defun cmacs-dbexplorer-grid-sql ()
  "Return the statement this grid is showing the result of."
  (let ((source cmacs-dbexplorer-grid--source))
    (pcase (plist-get source :kind)
      ('browse (cmacs-dbexplorer-grid--browse-sql
                (cmacs-dbexplorer-buffer-connection)))
      ('sql (plist-get source :sql))
      (_ (and cmacs-dbexplorer-grid--result
              (cmacs-dbexplorer-result-sql cmacs-dbexplorer-grid--result))))))

(defun cmacs-dbexplorer-grid--trim (result)
  "Cut RESULT down to one page, marking it truncated when it was longer."
  (let ((rows (cmacs-dbexplorer-result-rows result)))
    (when (> (length rows) cmacs-dbexplorer-page-size)
      (setf (cmacs-dbexplorer-result-rows result)
            (substring rows 0 cmacs-dbexplorer-page-size))
      (setf (cmacs-dbexplorer-result-truncated result) t)))
  result)

(defun cmacs-dbexplorer-grid--receive (buffer result)
  "Show RESULT in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cmacs-dbexplorer-grid--stream nil)
      (setq cmacs-dbexplorer-grid--status nil)
      (setq cmacs-dbexplorer-grid--result (cmacs-dbexplorer-grid--trim result))
      (cmacs-dbexplorer-grid--render))))

(defun cmacs-dbexplorer-grid--failed (buffer message)
  "Report that BUFFER's query failed with MESSAGE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cmacs-dbexplorer-grid--stream nil)
      (setq cmacs-dbexplorer-grid--status (concat "error: " message))
      (cmacs-dbexplorer-grid--render)))
  (message "cmacs-dbexplorer: %s" message))

(defun cmacs-dbexplorer-grid-run ()
  "Run this buffer's query again, with the current sort, filter and page."
  (interactive)
  (let* ((connection (cmacs-dbexplorer-buffer-connection-or-error))
         (source cmacs-dbexplorer-grid--source)
         (buffer (current-buffer)))
    (unless source
      (user-error "cmacs-dbexplorer: this grid has no query to run"))
    (cmacs-dbexplorer-cancel cmacs-dbexplorer-grid--stream)
    (setq cmacs-dbexplorer-grid--status "running...")
    (setq cmacs-dbexplorer-grid--stream
          (pcase (plist-get source :kind)
            ('browse
             (cmacs-dbexplorer-query
              connection (cmacs-dbexplorer-grid--browse-sql connection)
              :schema (plist-get source :schema)
              :table (plist-get source :table)
              :primary-key (plist-get source :primary-key)
              :offset cmacs-dbexplorer-grid--offset
              :on-result (lambda (result)
                           (cmacs-dbexplorer-grid--receive buffer result))
              :on-error (lambda (message)
                          (cmacs-dbexplorer-grid--failed buffer message))))
            (_
             (cmacs-dbexplorer-query
              connection (plist-get source :sql)
              :params (plist-get source :params)
              :options (list :max-rows (1+ cmacs-dbexplorer-page-size))
              :on-result (lambda (result)
                           (cmacs-dbexplorer-grid--receive buffer result))
              :on-error (lambda (message)
                          (cmacs-dbexplorer-grid--failed buffer message))))))
    (cmacs-dbexplorer-grid--render)))

(defun cmacs-dbexplorer-grid-cancel ()
  "Cancel the query filling this grid."
  (interactive)
  (if (null cmacs-dbexplorer-grid--stream)
      (message "cmacs-dbexplorer: nothing running")
    (cmacs-dbexplorer-cancel cmacs-dbexplorer-grid--stream)
    (setq cmacs-dbexplorer-grid--stream nil)
    (setq cmacs-dbexplorer-grid--status "cancelled")
    (cmacs-dbexplorer-grid--render)))

(defun cmacs-dbexplorer-grid--browse-only ()
  "Signal unless this grid is showing one table's rows."
  (unless (eq (plist-get cmacs-dbexplorer-grid--source :kind) 'browse)
    (user-error
     "cmacs-dbexplorer: this is your statement's result; add ORDER BY, \
WHERE or LIMIT to it yourself")))


;;;; Sorting, filtering, paging -----------------------------------------

(defun cmacs-dbexplorer-grid-sort ()
  "Cycle the sort on the column at point: ascending, descending, none."
  (interactive)
  (cmacs-dbexplorer-grid--browse-only)
  (let* ((result (cmacs-dbexplorer-grid-result))
         (name (nth (cmacs-dbexplorer-grid-column-at-point)
                    (cmacs-dbexplorer-result-column-names result))))
    (unless name (user-error "No column here"))
    (setq cmacs-dbexplorer-grid--sort
          (cond
           ((not (equal name (car cmacs-dbexplorer-grid--sort)))
            (cons name 'asc))
           ((eq (cdr cmacs-dbexplorer-grid--sort) 'asc) (cons name 'desc))
           (t nil)))
    ;; A new sort re-orders the whole table, so the page you were on is
    ;; not the page you want; start again from the top.
    (setq cmacs-dbexplorer-grid--offset 0)
    (cmacs-dbexplorer-grid-run)))

(defun cmacs-dbexplorer-grid-filter (fragment)
  "Restrict the browse to rows matching the WHERE FRAGMENT.

The fragment is SQL and is sent as written -- it is your predicate on
your database, not something to be escaped into meaninglessness."
  (interactive
   (list (read-string "WHERE: " (or cmacs-dbexplorer-grid--filter ""))))
  (cmacs-dbexplorer-grid--browse-only)
  (setq cmacs-dbexplorer-grid--filter
        (unless (string-empty-p (string-trim fragment)) fragment))
  (setq cmacs-dbexplorer-grid--offset 0)
  (cmacs-dbexplorer-grid-run))

(defun cmacs-dbexplorer-grid-filter-clear ()
  "Drop the active filter."
  (interactive)
  (cmacs-dbexplorer-grid--browse-only)
  (setq cmacs-dbexplorer-grid--filter nil)
  (setq cmacs-dbexplorer-grid--offset 0)
  (cmacs-dbexplorer-grid-run))

(defun cmacs-dbexplorer-grid-next-page ()
  "Show the next page of rows."
  (interactive)
  (cmacs-dbexplorer-grid--browse-only)
  (unless (and cmacs-dbexplorer-grid--result
               (cmacs-dbexplorer-result-truncated cmacs-dbexplorer-grid--result))
    (user-error "cmacs-dbexplorer: this is the last page"))
  (cl-incf cmacs-dbexplorer-grid--offset cmacs-dbexplorer-page-size)
  (cmacs-dbexplorer-grid-run))

(defun cmacs-dbexplorer-grid-previous-page ()
  "Show the previous page of rows."
  (interactive)
  (cmacs-dbexplorer-grid--browse-only)
  (when (zerop cmacs-dbexplorer-grid--offset)
    (user-error "cmacs-dbexplorer: this is the first page"))
  (setq cmacs-dbexplorer-grid--offset
        (max 0 (- cmacs-dbexplorer-grid--offset cmacs-dbexplorer-page-size)))
  (cmacs-dbexplorer-grid-run))


;;;; Looking at one value -----------------------------------------------

(define-derived-mode cmacs-dbexplorer-cell-mode special-mode "DB-Cell"
  "One database value, whole.

\\{cmacs-dbexplorer-cell-mode-map}"
  (setq-local truncate-lines nil))

(defun cmacs-dbexplorer-grid-show-cell ()
  "Show the whole value of the cell at point.

The grid truncates to keep the table readable; this is where the rest of
a value lives, and the only place a multi-line one is legible."
  (interactive)
  (let* ((result (cmacs-dbexplorer-grid-result))
         (row (cmacs-dbexplorer-grid-row-at-point-or-error))
         (column (cmacs-dbexplorer-grid-column-at-point))
         (cell (cmacs-dbexplorer-result-cell result row column))
         (name (nth column (cmacs-dbexplorer-result-column-names result)))
         (buffer (get-buffer-create "*dbexplorer-cell*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cmacs-dbexplorer-cell-mode)
        (insert (propertize (format "%s\n" name) 'face 'cmacs-dbexplorer-header))
        (insert (propertize
                 (format "%s\n\n"
                         (or (cmacs-dbexplorer--pairs
                              (cmacs-dbexplorer-result-row-key result row))
                             "no key"))
                 'face 'shadow))
        (insert (if (eq cell :null)
                    (propertize (cmacs-dbexplorer-glyph 'null)
                                'face 'cmacs-dbexplorer-null)
                  (cmacs-dbexplorer-cell-display cell)))
        (goto-char (point-min))))
    (display-buffer buffer)))


;;;; Copying out --------------------------------------------------------

(defun cmacs-dbexplorer-grid--csv-field (cell)
  "Return CELL as a CSV field, quoted when it has to be."
  (let ((text (if (eq cell :null) "" (cmacs-dbexplorer-cell-display cell))))
    (if (string-match-p "[\",\n\r]" text)
        (concat "\"" (replace-regexp-in-string "\"" "\"\"" text) "\"")
      text)))

(defun cmacs-dbexplorer-grid-yank-cell ()
  "Copy the cell at point to the kill ring."
  (interactive)
  (let ((cell (cmacs-dbexplorer-grid-cell-value)))
    (kill-new (if (eq cell :null) "" (cmacs-dbexplorer-cell-display cell)))
    (message "cmacs-dbexplorer: copied")))

(defun cmacs-dbexplorer-grid-yank-row ()
  "Copy the row at point to the kill ring as CSV."
  (interactive)
  (let* ((result (cmacs-dbexplorer-grid-result))
         (row (cmacs-dbexplorer-grid-row-at-point-or-error))
         (cells (append (aref (cmacs-dbexplorer-result-rows result) row) nil)))
    (kill-new (mapconcat #'cmacs-dbexplorer-grid--csv-field cells ","))
    (message "cmacs-dbexplorer: copied one row as CSV")))

(defun cmacs-dbexplorer-grid-yank-sql ()
  "Copy the statement behind this grid to the kill ring."
  (interactive)
  (let ((sql (cmacs-dbexplorer-grid-sql)))
    (unless sql (user-error "cmacs-dbexplorer: no statement to copy"))
    (kill-new sql)
    (message "%s" sql)))

(defun cmacs-dbexplorer-grid-export ()
  "Export this result."
  (interactive)
  (cmacs-dbexplorer-grid-result)
  (require 'cmacs-dbexplorer-export)
  (cmacs-dbexplorer-export-menu))

(defun cmacs-dbexplorer-grid-open-sql ()
  "Open a SQL buffer on this grid's connection."
  (interactive)
  (require 'cmacs-dbexplorer-sql)
  (cmacs-dbexplorer-sql (cmacs-dbexplorer-buffer-connection-or-error)))


;;;; Result actions -----------------------------------------------------

(defun cmacs-dbexplorer-grid--action-command (name)
  "Return a command running the registered result action NAME."
  (lambda ()
    (interactive)
    (let* ((action (cmacs-dbexplorer-result-action name))
           (result (cmacs-dbexplorer-grid-result))
           (predicate (plist-get action :pred)))
      (unless action (user-error "cmacs-dbexplorer: %s is gone" name))
      (unless (or (null predicate) (funcall predicate result))
        (user-error "cmacs-dbexplorer: %s does not apply to these rows"
                    (plist-get action :label)))
      (funcall (plist-get action :run) result
               (cmacs-dbexplorer-grid-row-at-point)
               (cmacs-dbexplorer-grid-column-at-point)))))

(defconst cmacs-dbexplorer-grid--built-in-legend
  '(("n/p" . "row") ("TAB" . "cell") ("RET" . "value") ("o" . "sort")
    ("f/F" . "filter") ("[/]" . "page") ("g" . "re-run") ("K" . "cancel")
    ("y/Y" . "copy cell/row") ("w" . "copy SQL") ("e" . "edit")
    ("i" . "insert") ("D" . "delete") ("u/U" . "unstage")
    ("C-c C-c" . "commit") ("R" . "edit mode") ("E" . "export")
    ("s" . "SQL") ("q" . "quit"))
  "The keys the grid binds itself, as (KEY . LABEL).")

(defun cmacs-dbexplorer-grid--legend ()
  "Return the key legend, including every registered result action.

Generated from the same list the keys are installed from, so a key that
works and a key that is documented cannot drift apart."
  (let ((entries (append cmacs-dbexplorer-grid--built-in-legend
                         (mapcar (lambda (entry)
                                   (cons (plist-get (cdr entry) :key)
                                         (plist-get (cdr entry) :label)))
                                 (cmacs-dbexplorer-result-actions))))
        (lines nil)
        (line " "))
    (dolist (entry entries)
      (let ((text (format "%s %s   " (car entry) (cdr entry))))
        (when (> (+ (length line) (length text)) 76)
          (push line lines)
          (setq line " "))
        (setq line (concat line text))))
    (push line lines)
    (propertize (concat (string-join (nreverse lines) "\n") "\n") 'face 'shadow)))


;;;; Mode ---------------------------------------------------------------

(defvar cmacs-dbexplorer-grid-mode-map
  (let ((map (make-sparse-keymap)))
    ;; hjkl is bound explicitly: the Evil intercept promotion below takes
    ;; the buffer over completely, so motion that is not in this map is
    ;; motion that does not happen.  SPC is deliberately absent -- it is
    ;; the Doom leader, and a grid that swallowed it would be the one
    ;; buffer where the user's own bindings stop working.
    (define-key map "j" #'cmacs-dbexplorer-grid-next-row)
    (define-key map "k" #'cmacs-dbexplorer-grid-previous-row)
    (define-key map "h" #'cmacs-dbexplorer-grid-previous-cell)
    (define-key map "l" #'cmacs-dbexplorer-grid-next-cell)
    (define-key map "n" #'cmacs-dbexplorer-grid-next-row)
    (define-key map "p" #'cmacs-dbexplorer-grid-previous-row)
    (define-key map (kbd "TAB") #'cmacs-dbexplorer-grid-next-cell)
    (define-key map (kbd "<backtab>") #'cmacs-dbexplorer-grid-previous-cell)
    (define-key map (kbd "RET") #'cmacs-dbexplorer-grid-show-cell)
    (define-key map "o" #'cmacs-dbexplorer-grid-sort)
    (define-key map "f" #'cmacs-dbexplorer-grid-filter)
    (define-key map "F" #'cmacs-dbexplorer-grid-filter-clear)
    (define-key map "]" #'cmacs-dbexplorer-grid-next-page)
    (define-key map "[" #'cmacs-dbexplorer-grid-previous-page)
    (define-key map "g" #'cmacs-dbexplorer-grid-run)
    (define-key map "K" #'cmacs-dbexplorer-grid-cancel)
    (define-key map "y" #'cmacs-dbexplorer-grid-yank-cell)
    (define-key map "Y" #'cmacs-dbexplorer-grid-yank-row)
    (define-key map "w" #'cmacs-dbexplorer-grid-yank-sql)
    (define-key map "E" #'cmacs-dbexplorer-grid-export)
    (define-key map "s" #'cmacs-dbexplorer-grid-open-sql)
    (define-key map "q" #'cmacs-dbexplorer-quit)
    map)
  "Keymap for `cmacs-dbexplorer-grid-mode'.")

(defun cmacs-dbexplorer-grid-install-actions ()
  "Bind every registered result action in the grid's keymaps.

Installed into the mode map and into Evil's auxiliary maps together: a
registered `a' that only reached the mode map would be `evil-append'
under Doom, which is the sort of half-working extension point that
teaches people not to use it.  Re-run whenever a grid buffer is made, so
an action registered after this file loaded is still reachable."
  (dolist (entry (cmacs-dbexplorer-result-actions))
    (let ((key (plist-get (cdr entry) :key))
          (command (cmacs-dbexplorer-grid--action-command (car entry))))
      (define-key cmacs-dbexplorer-grid-mode-map (kbd key) command)
      (when (fboundp 'evil-define-key*)
        (evil-define-key* '(normal motion) cmacs-dbexplorer-grid-mode-map
          (kbd key) command))))
  (cmacs-evil-setup-mode-map cmacs-dbexplorer-grid-mode-map
                             'cmacs-dbexplorer-grid-mode))

(define-derived-mode cmacs-dbexplorer-grid-mode special-mode "DB-Grid"
  "Query results, one page at a time.

\\{cmacs-dbexplorer-grid-mode-map}"
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq-local header-line-format '(:eval (cmacs-dbexplorer-grid--header-line))))

(defun cmacs-dbexplorer-grid--buffer (connection)
  "Return CONNECTION's grid buffer, creating it if needed."
  (let* ((connection (cmacs-dbexplorer-resolve connection))
         (name (cmacs-dbexplorer-connection-name connection))
         (buffer (get-buffer-create (cmacs-dbexplorer-grid-buffer-name name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-dbexplorer-grid-mode)
        (cmacs-dbexplorer-grid-mode))
      (setq cmacs-dbexplorer--connection-name name)
      ;; Loaded here rather than required at the top, because the editing
      ;; layer requires this file; by the time anyone has a grid buffer
      ;; this file is fully loaded and the dependency is one-way again.
      (require 'cmacs-dbexplorer-edit)
      (cmacs-dbexplorer-grid-install-actions))
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-grid-show (result &optional source connection)
  "Show RESULT, produced by SOURCE, on CONNECTION.

SOURCE is the plist that says how to run the query again; without one
the grid shows the rows but cannot sort, filter or page them."
  (cmacs-dbexplorer--require)
  (let* ((name (or connection (cmacs-dbexplorer-result-connection-name result)))
         (buffer (cmacs-dbexplorer-grid--buffer name)))
    (with-current-buffer buffer
      (setq cmacs-dbexplorer-grid--source
            (or source (list :kind 'sql
                             :sql (cmacs-dbexplorer-result-sql result))))
      (setq cmacs-dbexplorer-grid--result (cmacs-dbexplorer-grid--trim result))
      (setq cmacs-dbexplorer-grid--status nil)
      (cmacs-dbexplorer-grid--render))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-grid-open (&optional connection)
  "Show CONNECTION's grid buffer, empty if it has no rows yet."
  (interactive)
  (cmacs-dbexplorer--require)
  (let ((buffer (cmacs-dbexplorer-grid--buffer
                 (or connection
                     (cmacs-dbexplorer-read-connection-name "Connection: " t)))))
    (with-current-buffer buffer
      (unless cmacs-dbexplorer-grid--result (cmacs-dbexplorer-grid--render)))
    (display-buffer buffer)
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-browse (connection schema table)
  "Browse TABLE in SCHEMA on CONNECTION.

The primary key is fetched first and carried into the result, because it
is what makes the rows editable: without it the grid can show the table
but has no way to name a row it is asked to change."
  (interactive
   (list (cmacs-dbexplorer-read-connection-name "Connection: " t)
         (read-string "Schema (empty for the default): ")
         (read-string "Table: ")))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--table-info-async)
  (let* ((connection (cmacs-dbexplorer-resolve connection))
         (schema (if (and schema (string-empty-p schema)) nil schema))
         (buffer (cmacs-dbexplorer-grid--buffer connection)))
    (cmacs-dbexplorer--table-info-async
     (cmacs-dbexplorer--handle connection) schema table
     (lambda (reply)
       (let ((error-message (cmacs-dbexplorer--reply-error reply)))
         (if error-message
             (cmacs-dbexplorer-grid--failed buffer error-message)
           (when (buffer-live-p buffer)
             (cmacs-dbexplorer-schema-put connection schema table reply)
             (with-current-buffer buffer
               (setq cmacs-dbexplorer-grid--source
                     (list :kind 'browse :schema schema :table table
                           :primary-key
                           (append (alist-get :primary-key reply) nil)))
               (setq cmacs-dbexplorer-grid--offset 0)
               (setq cmacs-dbexplorer-grid--sort nil)
               (setq cmacs-dbexplorer-grid--filter nil)
               (cmacs-dbexplorer-grid-run)))))))
    (display-buffer buffer)
    buffer))

;; The grid registers itself rather than being wired in.  A second view --
;; a libregnum scene, a chart, something nobody has written yet -- arrives
;; the same way and is reachable from the same picker.
(cmacs-dbexplorer-register-view
 'grid
 :open #'cmacs-dbexplorer-grid-open
 :render #'cmacs-dbexplorer-grid-show
 :supports '(result)
 :label "Result grid")

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-dbexplorer-grid-mode 'motion)
    (evil-set-initial-state 'cmacs-dbexplorer-cell-mode 'motion)))

(cmacs-evil-setup-mode-map cmacs-dbexplorer-grid-mode-map
                           'cmacs-dbexplorer-grid-mode)

(provide 'cmacs-dbexplorer-grid)
;;; cmacs-dbexplorer-grid.el ends here
