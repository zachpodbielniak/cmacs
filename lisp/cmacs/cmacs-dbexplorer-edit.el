;;; cmacs-dbexplorer-edit.el --- Staged and immediate editing  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Changing rows, and being unable to do it by accident.
;;
;; Editing defaults to staged: a keystroke marks a cell, nothing reaches
;; the database, and the whole batch is reviewed as SQL before it is sent
;; as one call.  Immediate mode exists because a throwaway local database
;; does not deserve a two-step ceremony -- but the difference between the
;; two is the difference between a typo and a production incident, so it
;; is never quiet.  The header line says which mode is on at all times,
;; the immediate one in a face that inherits `error', and every toggle
;; says so in the echo area as well.  A mode you can be in without
;; noticing is a mode that will eventually surprise someone.
;;
;; The other half of the safety is inherited from the model: a row is
;; editable only when the result names a table AND every primary-key
;; column was selected.  Editing without that is refused with the reason,
;; not merely disabled -- "no primary key" is a fact about the schema, and
;; a user who knows it can turn on
;; `cmacs-dbexplorer-allow-editing-without-pk' to match on every column
;; instead, which is then confirmed at every single commit.  The C batch
;; carries `:expect 1' either way, so a WHERE clause that turned out to
;; match two rows rolls the batch back rather than committing half of it.
;;
;; The SQL shown in the review buffer is generated here for reading.  It
;; is not what is sent: the C layer builds the statement and binds the
;; values, which is what keeps a value containing a quote a value.  The
;; two are built from the same ops, so what is read is what happens.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-dbexplorer)
(require 'cmacs-dbexplorer-grid)

(declare-function cmacs-dbexplorer--apply-edits-async
                  "src/cmacs-dbexplorer-defuns.c" (handle ops cb))
(declare-function evil-set-initial-state "evil-core" (mode state))


;;;; Customization ------------------------------------------------------

(defcustom cmacs-dbexplorer-edit-mode 'staged
  "How a cell edit reaches the database.

`staged' collects changes and sends them as one reviewed batch.
`immediate' sends each change as it is made.

Set per buffer with \\[cmacs-dbexplorer-edit-toggle-mode]; this variable
is the default a new grid starts in."
  :type '(choice (const :tag "Collect and review" staged)
                 (const :tag "Write each change straight through" immediate))
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-allow-editing-without-pk nil
  "Whether a row with no primary key may be edited by matching every column.

Off, and deliberately so.  Without a key there is no way to name one row:
the fallback WHERE clause lists every column of the row you pointed at,
which names it only as long as no other row happens to be identical.  In
a table with duplicate rows it names all of them -- and the `:expect 1'
the batch carries is what turns that into a rollback rather than a
silent multi-row update.

Turning this on makes each commit ask for confirmation, every time."
  :type 'boolean
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-edit-long-value 120
  "Length beyond which a cell is edited in a buffer rather than the minibuffer."
  :type 'integer
  :group 'cmacs-dbexplorer)


;;;; State --------------------------------------------------------------

(defvar-local cmacs-dbexplorer-edit--edits nil
  "The `cmacs-dbexplorer-edit' structs staged in this grid, oldest first.")

(defun cmacs-dbexplorer-edit-pending ()
  "Return this buffer's staged edits."
  cmacs-dbexplorer-edit--edits)

(defun cmacs-dbexplorer-edit-pending-inserts ()
  "Return this buffer's staged insertions."
  (seq-filter (lambda (edit) (eq (cmacs-dbexplorer-edit-op edit) 'insert))
              cmacs-dbexplorer-edit--edits))

(defun cmacs-dbexplorer-edit-indicator ()
  "Return the header-line segment naming the active editing mode.

Impossible to miss on purpose: in immediate mode every keystroke that
touches a cell is a write, and the only thing standing between the user
and that fact is this string."
  (if (eq cmacs-dbexplorer-edit-mode 'immediate)
      (propertize "[IMMEDIATE WRITES]" 'face 'cmacs-dbexplorer-immediate)
    (let ((pending (length cmacs-dbexplorer-edit--edits)))
      (propertize (format "[STAGED: %d pending]" pending)
                  'face (if (zerop pending) 'shadow 'cmacs-dbexplorer-staged)))))

(defun cmacs-dbexplorer-edit-toggle-mode ()
  "Switch this grid between staged and immediate editing."
  (interactive)
  (when (and (eq cmacs-dbexplorer-edit-mode 'staged)
             cmacs-dbexplorer-edit--edits)
    (user-error
     "cmacs-dbexplorer: commit or drop the %d staged change(s) first"
     (length cmacs-dbexplorer-edit--edits)))
  (setq-local cmacs-dbexplorer-edit-mode
              (if (eq cmacs-dbexplorer-edit-mode 'immediate) 'staged 'immediate))
  (cmacs-dbexplorer-grid-refresh)
  (message "cmacs-dbexplorer: %s"
           (if (eq cmacs-dbexplorer-edit-mode 'immediate)
               "IMMEDIATE -- every edit is written straight to the database"
             "staged -- edits collect until C-c C-c")))


;;;; Naming a row -------------------------------------------------------

(defun cmacs-dbexplorer-edit--all-columns-key (result row)
  "Return a WHERE alist matching ROW of RESULT on every column."
  (let ((names (cmacs-dbexplorer-result-column-names result))
        (key nil)
        (index 0))
    (dolist (name names)
      (push (cons name (cmacs-dbexplorer-result-cell result row index)) key)
      (setq index (1+ index)))
    (nreverse key)))

(defun cmacs-dbexplorer-edit--ensure-editable (result)
  "Signal unless RESULT's rows can be written back.

The refusal explains itself: \"editing is disabled\" leaves the user
guessing, and the answer -- there is no way to name this row -- is a fact
about their schema that they can act on."
  (cond
   ((cmacs-dbexplorer-result-editable-p result) t)
   ((null (cmacs-dbexplorer-result-table result))
    (user-error
     "cmacs-dbexplorer: these rows are a statement's output, not one \
table's, so there is no row to write back to"))
   ((not cmacs-dbexplorer-allow-editing-without-pk)
    (user-error
     "cmacs-dbexplorer: %s has no primary key here, so there is no way to \
name the row you mean; set cmacs-dbexplorer-allow-editing-without-pk to \
match on every column instead"
     (cmacs-dbexplorer-result-table result)))
   (t t)))

(defun cmacs-dbexplorer-edit--row-key (result row)
  "Return the WHERE alist naming ROW of RESULT."
  (or (cmacs-dbexplorer-result-row-key result row)
      (and cmacs-dbexplorer-allow-editing-without-pk
           (cmacs-dbexplorer-edit--all-columns-key result row))
      (user-error "cmacs-dbexplorer: this row cannot be named")))

(defun cmacs-dbexplorer-edit--check-writable ()
  "Signal unless this grid's connection accepts writes."
  (let ((connection (cmacs-dbexplorer-buffer-connection)))
    (when (and connection (cmacs-dbexplorer-connection-read-only connection))
      (user-error "cmacs-dbexplorer: %s is open read-only"
                  (cmacs-dbexplorer-connection-name connection)))))


;;;; Finding and staging ------------------------------------------------

(defun cmacs-dbexplorer-edit--find (op key)
  "Return the staged OP edit for KEY in this buffer, or nil."
  (seq-find (lambda (edit)
              (and (eq (cmacs-dbexplorer-edit-op edit) op)
                   (equal (cmacs-dbexplorer-edit-key edit) key)))
            cmacs-dbexplorer-edit--edits))

(defun cmacs-dbexplorer-edit--stage (edit)
  "Add EDIT to this buffer's staged changes and redraw."
  (setq cmacs-dbexplorer-edit--edits
        (append cmacs-dbexplorer-edit--edits (list edit)))
  (cmacs-dbexplorer-grid-refresh)
  edit)

(defun cmacs-dbexplorer-edit--drop (edit)
  "Remove EDIT from this buffer's staged changes."
  (setq cmacs-dbexplorer-edit--edits
        (delq edit cmacs-dbexplorer-edit--edits))
  (cmacs-dbexplorer-grid-refresh))

(defun cmacs-dbexplorer-edit--update-for (result row)
  "Return the staged update for ROW of RESULT, creating one if needed."
  (let ((key (cmacs-dbexplorer-edit--row-key result row)))
    (or (cmacs-dbexplorer-edit--find 'update key)
        (cmacs-dbexplorer-edit--stage
         (cmacs-dbexplorer-edit-create
          :op 'update
          :table (cmacs-dbexplorer-result-table result)
          :schema (cmacs-dbexplorer-result-schema result)
          :key key :values nil)))))


;;;; Decoration ---------------------------------------------------------

(defun cmacs-dbexplorer-edit-cell-override (result row column)
  "Return (VALUE . FACE) for a staged cell at ROW and COLUMN of RESULT.

The value, not just the face: a staged edit that drew the old value in a
different colour would be showing what the row used to be while claiming
to be a change, and the point of staging is seeing what you are about to
commit before you commit it."
  (when cmacs-dbexplorer-edit--edits
    (let* ((key (cmacs-dbexplorer-result-row-key result row))
           (key (or key (and cmacs-dbexplorer-allow-editing-without-pk
                             (cmacs-dbexplorer-edit--all-columns-key result row))))
           (edit (and key (cmacs-dbexplorer-edit--find 'update key)))
           (name (nth column (cmacs-dbexplorer-result-column-names result)))
           (staged (and edit (assoc name (cmacs-dbexplorer-edit-values edit)))))
      (when staged (cons (cdr staged) 'cmacs-dbexplorer-staged)))))

(defun cmacs-dbexplorer-edit-row-decoration (result row)
  "Return (MARKER . FACE) for ROW of RESULT, or nil when it is untouched."
  (when cmacs-dbexplorer-edit--edits
    (let* ((key (cmacs-dbexplorer-result-row-key result row))
           (key (or key (and cmacs-dbexplorer-allow-editing-without-pk
                             (cmacs-dbexplorer-edit--all-columns-key result row)))))
      (when key
        (cond
         ((cmacs-dbexplorer-edit--find 'delete key)
          (cons (cmacs-dbexplorer-glyph 'staged) 'cmacs-dbexplorer-staged-delete))
         ((cmacs-dbexplorer-edit--find 'update key)
          (cons (cmacs-dbexplorer-glyph 'staged) nil)))))))

(defun cmacs-dbexplorer-edit--display-value (value)
  "Return VALUE as text for a prompt or a review line."
  (if (eq value :null) "" (cmacs-dbexplorer-cell-display value)))


;;;; Editing one cell ---------------------------------------------------

(defun cmacs-dbexplorer-edit--set (result row column value)
  "Stage or apply VALUE for COLUMN of ROW in RESULT."
  (let* ((name (nth column (cmacs-dbexplorer-result-column-names result)))
         (insert-edit (cmacs-dbexplorer-grid-edit-at-point)))
    (unless name (user-error "cmacs-dbexplorer: no column here"))
    (cond
     ;; A staged insert is edited in place: it has no row in the database
     ;; yet, so there is nothing to write through even in immediate mode.
     (insert-edit
      (setf (cmacs-dbexplorer-edit-values insert-edit)
            (cons (cons name value)
                  (assoc-delete-all name
                                    (cmacs-dbexplorer-edit-values insert-edit))))
      (cmacs-dbexplorer-grid-refresh))
     ((eq cmacs-dbexplorer-edit-mode 'immediate)
      (cmacs-dbexplorer-edit--apply
       (list (cmacs-dbexplorer-edit-create
              :op 'update
              :table (cmacs-dbexplorer-result-table result)
              :schema (cmacs-dbexplorer-result-schema result)
              :key (cmacs-dbexplorer-edit--row-key result row)
              :values (list (cons name value))))))
     (t
      (let ((edit (cmacs-dbexplorer-edit--update-for result row)))
        (setf (cmacs-dbexplorer-edit-values edit)
              (cons (cons name value)
                    (assoc-delete-all name (cmacs-dbexplorer-edit-values edit))))
        (cmacs-dbexplorer-grid-refresh))))))

(defun cmacs-dbexplorer-edit-cell (&optional null)
  "Edit the cell at point.  With a prefix argument, set it to NULL.

A short single-line value is read in the minibuffer.  Anything longer, or
anything with a newline in it, opens a buffer instead: a JSON document or
a paragraph of prose is not editable in a one-line prompt, and quietly
truncating it would be worse than refusing."
  (interactive "P")
  (cmacs-dbexplorer-edit--check-writable)
  (let* ((result (cmacs-dbexplorer-grid-result))
         (row (cmacs-dbexplorer-grid-row-at-point))
         (column (cmacs-dbexplorer-grid-column-at-point))
         (insert-edit (cmacs-dbexplorer-grid-edit-at-point)))
    (unless (or row insert-edit) (user-error "No row on this line"))
    (when row (cmacs-dbexplorer-edit--ensure-editable result))
    (if null
        (cmacs-dbexplorer-edit--set result row column :null)
      (let* ((current (cmacs-dbexplorer-edit--current-value result row column))
             (text (cmacs-dbexplorer-edit--display-value current)))
        (if (or (string-match-p "\n" text)
                (> (length text) cmacs-dbexplorer-edit-long-value))
            (cmacs-dbexplorer-edit--open-cell-buffer result row column text)
          (cmacs-dbexplorer-edit--set
           result row column
           (read-string (format "%s: "
                                (nth column (cmacs-dbexplorer-result-column-names
                                             result)))
                        text)))))))

(defun cmacs-dbexplorer-edit--current-value (result row column)
  "Return the value COLUMN of ROW currently shows, staged or stored."
  (let* ((name (nth column (cmacs-dbexplorer-result-column-names result)))
         (insert-edit (cmacs-dbexplorer-grid-edit-at-point)))
    (cond
     (insert-edit (cdr (assoc name (cmacs-dbexplorer-edit-values insert-edit))))
     (t
      (let* ((key (ignore-errors (cmacs-dbexplorer-edit--row-key result row)))
             (edit (and key (cmacs-dbexplorer-edit--find 'update key)))
             (staged (and edit (assoc name (cmacs-dbexplorer-edit-values edit)))))
        (if staged (cdr staged)
          (cmacs-dbexplorer-result-cell result row column)))))))


;;;; Editing a long value in its own buffer -----------------------------

(defvar-local cmacs-dbexplorer-cell-edit--grid nil
  "The grid buffer this cell belongs to.")

(defvar-local cmacs-dbexplorer-cell-edit--row nil
  "The row index this cell belongs to.")

(defvar-local cmacs-dbexplorer-cell-edit--column nil
  "The column index this cell belongs to.")

(defvar cmacs-dbexplorer-cell-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-dbexplorer-cell-edit-finish)
    (define-key map (kbd "C-c C-k") #'cmacs-dbexplorer-cell-edit-abort)
    map)
  "Keymap for `cmacs-dbexplorer-cell-edit-mode'.")

(define-derived-mode cmacs-dbexplorer-cell-edit-mode text-mode "DB-Value"
  "Edit one database value.

\\[cmacs-dbexplorer-cell-edit-finish] takes the value back to the grid,
\\[cmacs-dbexplorer-cell-edit-abort] throws it away.

\\{cmacs-dbexplorer-cell-edit-mode-map}"
  (setq-local truncate-lines nil))

;; Text, in a buffer, to be typed into: insert state, for the same reason
;; the SQL editor gets it.
(with-eval-after-load 'evil
  (evil-set-initial-state 'cmacs-dbexplorer-cell-edit-mode 'insert))

(defun cmacs-dbexplorer-edit--open-cell-buffer (result row column text)
  "Open a buffer holding TEXT for COLUMN of ROW in RESULT."
  (let* ((name (nth column (cmacs-dbexplorer-result-column-names result)))
         (grid (current-buffer))
         (buffer (get-buffer-create
                  (format "*dbexplorer-edit: %s.%s*"
                          (or (cmacs-dbexplorer-result-table result) "?") name))))
    (with-current-buffer buffer
      (cmacs-dbexplorer-cell-edit-mode)
      (erase-buffer)
      (insert text)
      (goto-char (point-min))
      (setq cmacs-dbexplorer-cell-edit--grid grid)
      (setq cmacs-dbexplorer-cell-edit--row row)
      (setq cmacs-dbexplorer-cell-edit--column column)
      (setq header-line-format
            (format " %s -- C-c C-c to stage, C-c C-k to abandon" name)))
    (pop-to-buffer buffer)))

(defun cmacs-dbexplorer-cell-edit-finish ()
  "Take this buffer's value back to the grid."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (grid cmacs-dbexplorer-cell-edit--grid)
        (row cmacs-dbexplorer-cell-edit--row)
        (column cmacs-dbexplorer-cell-edit--column)
        (buffer (current-buffer)))
    (unless (buffer-live-p grid)
      (user-error "cmacs-dbexplorer: the grid this value came from is gone"))
    (with-current-buffer grid
      (cmacs-dbexplorer-edit--set (cmacs-dbexplorer-grid-result)
                                  row column text))
    (kill-buffer buffer)
    (pop-to-buffer grid)))

(defun cmacs-dbexplorer-cell-edit-abort ()
  "Throw this value away."
  (interactive)
  (let ((grid cmacs-dbexplorer-cell-edit--grid))
    (kill-buffer (current-buffer))
    (when (buffer-live-p grid) (pop-to-buffer grid))))


;;;; Whole rows ---------------------------------------------------------

(defun cmacs-dbexplorer-edit-insert-row ()
  "Stage a new, empty row.

Empty rather than prompted: a table with thirty columns would otherwise
mean thirty prompts, most of which want the default.  The row appears at
the bottom of the grid and its cells are filled in with \\[cmacs-dbexplorer-edit-cell]
like any others."
  (interactive)
  (cmacs-dbexplorer-edit--check-writable)
  (let ((result (cmacs-dbexplorer-grid-result)))
    (unless (cmacs-dbexplorer-result-table result)
      (user-error
       "cmacs-dbexplorer: these rows are a statement's output; there is no \
table to insert into"))
    (cmacs-dbexplorer-edit--stage
     (cmacs-dbexplorer-edit-create
      :op 'insert
      :table (cmacs-dbexplorer-result-table result)
      :schema (cmacs-dbexplorer-result-schema result)
      :key nil :values nil))
    (message "cmacs-dbexplorer: new row staged; fill it in with e")))

(defun cmacs-dbexplorer-edit-delete-row ()
  "Stage the row at point for deletion."
  (interactive)
  (cmacs-dbexplorer-edit--check-writable)
  (let ((insert-edit (cmacs-dbexplorer-grid-edit-at-point)))
    (if insert-edit
        ;; Deleting a row that only ever existed as a staged insert is
        ;; unstaging it, not a DELETE against a row that is not there.
        (cmacs-dbexplorer-edit--drop insert-edit)
      (let* ((result (cmacs-dbexplorer-grid-result))
             (row (cmacs-dbexplorer-grid-row-at-point-or-error)))
        (cmacs-dbexplorer-edit--ensure-editable result)
        (let* ((key (cmacs-dbexplorer-edit--row-key result row))
               (existing (cmacs-dbexplorer-edit--find 'delete key)))
          (if existing
              (cmacs-dbexplorer-edit--drop existing)
            ;; A row being deleted has no use for a pending update of the
            ;; same row; keeping both would send two statements whose
            ;; order decides whether the update succeeds.
            (let ((update (cmacs-dbexplorer-edit--find 'update key)))
              (when update (cmacs-dbexplorer-edit--drop update)))
            (if (eq cmacs-dbexplorer-edit-mode 'immediate)
                (cmacs-dbexplorer-edit--apply
                 (list (cmacs-dbexplorer-edit-create
                        :op 'delete
                        :table (cmacs-dbexplorer-result-table result)
                        :schema (cmacs-dbexplorer-result-schema result)
                        :key key)))
              (cmacs-dbexplorer-edit--stage
               (cmacs-dbexplorer-edit-create
                :op 'delete
                :table (cmacs-dbexplorer-result-table result)
                :schema (cmacs-dbexplorer-result-schema result)
                :key key)))))))))

(defun cmacs-dbexplorer-edit-unstage ()
  "Drop the staged change on the row at point."
  (interactive)
  (let ((insert-edit (cmacs-dbexplorer-grid-edit-at-point)))
    (if insert-edit
        (cmacs-dbexplorer-edit--drop insert-edit)
      (let* ((result (cmacs-dbexplorer-grid-result))
             (row (cmacs-dbexplorer-grid-row-at-point-or-error))
             (key (ignore-errors (cmacs-dbexplorer-edit--row-key result row)))
             (edits (seq-filter
                     (lambda (edit)
                       (equal key (cmacs-dbexplorer-edit-key edit)))
                     cmacs-dbexplorer-edit--edits)))
        (unless edits (user-error "cmacs-dbexplorer: nothing staged on this row"))
        (dolist (edit edits) (cmacs-dbexplorer-edit--drop edit))))))

(defun cmacs-dbexplorer-edit-unstage-all ()
  "Drop every staged change in this grid."
  (interactive)
  (unless cmacs-dbexplorer-edit--edits
    (user-error "cmacs-dbexplorer: nothing is staged"))
  (when (yes-or-no-p (format "Drop %d staged change(s)? "
                             (length cmacs-dbexplorer-edit--edits)))
    (setq cmacs-dbexplorer-edit--edits nil)
    (cmacs-dbexplorer-grid-refresh)))


;;;; Generated SQL, for reading -----------------------------------------

(defun cmacs-dbexplorer-edit-sql (edit &optional connection)
  "Return (SQL . VALUES) describing EDIT as it will be run on CONNECTION.

For display only.  The statement that actually runs is built in C from
the same op, with the values bound rather than interpolated -- which is
why the placeholders are shown here instead of the data."
  (let* ((table (cmacs-dbexplorer-qualified-name
                 connection (cmacs-dbexplorer-edit-schema edit)
                 (cmacs-dbexplorer-edit-table edit)))
         (values (cmacs-dbexplorer-edit-values edit))
         (key (cmacs-dbexplorer-edit-key edit))
         (quoted (lambda (pair)
                   (format "%s = ?" (cmacs-dbexplorer-quote connection
                                                            (car pair))))))
    (pcase (cmacs-dbexplorer-edit-op edit)
      ('update
       (cons (format "UPDATE %s SET %s WHERE %s" table
                     (mapconcat quoted values ", ")
                     (mapconcat quoted key " AND "))
             (append (mapcar #'cdr values) (mapcar #'cdr key))))
      ('insert
       (cons (format "INSERT INTO %s (%s) VALUES (%s)" table
                     (mapconcat (lambda (pair)
                                  (cmacs-dbexplorer-quote connection (car pair)))
                                values ", ")
                     (mapconcat (lambda (_pair) "?") values ", "))
             (mapcar #'cdr values)))
      ('delete
       (cons (format "DELETE FROM %s WHERE %s" table
                     (mapconcat quoted key " AND "))
             (mapcar #'cdr key)))
      (op (cons (format "%s %s" op table) nil)))))


;;;; Review -------------------------------------------------------------

(defvar-local cmacs-dbexplorer-review--grid nil
  "The grid buffer whose edits this review is about.")

(defun cmacs-dbexplorer-review-buffer-name (connection-name)
  "Return the review buffer name for CONNECTION-NAME."
  (format "*dbexplorer-review: %s*" connection-name))

(defun cmacs-dbexplorer-review-render (edits &optional connection)
  "Fill the current buffer with EDITS as they will run on CONNECTION.

Grouped by table, because a batch that touches three tables is read one
table at a time, and because the grouping is the fastest way to notice
that a change landed on the table you did not mean."
  (let ((inhibit-read-only t)
        (tables nil))
    (erase-buffer)
    (dolist (edit edits)
      (let ((table (cmacs-dbexplorer-edit-table edit)))
        (setf (alist-get table tables nil nil #'equal)
              (append (alist-get table tables nil nil #'equal) (list edit)))))
    (insert (propertize
             (format " %d change(s) in %d table(s)\n\n"
                     (length edits) (length tables))
             'face 'cmacs-dbexplorer-header))
    (dolist (group tables)
      (insert (propertize (format " %s\n" (car group))
                          'face 'cmacs-dbexplorer-table))
      (dolist (edit (cdr group))
        (let* ((pair (cmacs-dbexplorer-edit-sql edit connection))
               (face (pcase (cmacs-dbexplorer-edit-op edit)
                       ('insert 'cmacs-dbexplorer-staged-insert)
                       ('delete 'cmacs-dbexplorer-staged-delete)
                       (_ 'cmacs-dbexplorer-staged))))
          (insert (propertize (format "   %s\n" (car pair))
                              'face face
                              'cmacs-dbexplorer-review-edit edit))
          (insert (propertize
                   (format "     with %s\n"
                           (if (cdr pair)
                               (mapconcat #'cmacs-dbexplorer-cell-display
                                          (cdr pair) ", ")
                             "no values"))
                   'face 'shadow
                   'cmacs-dbexplorer-review-edit edit))))
      (insert "\n"))
    (when (null edits)
      (insert "  Nothing staged.\n\n"))
    (insert (propertize
             " c apply as one batch   k drop this one   q leave it staged\n"
             'face 'shadow))
    (goto-char (point-min))))

(defun cmacs-dbexplorer-review--edit-at-point ()
  "Return the edit described on this line, or signal."
  (or (get-text-property (line-beginning-position)
                         'cmacs-dbexplorer-review-edit)
      (user-error "No change on this line")))

(defun cmacs-dbexplorer-review-drop ()
  "Drop the change on this line from the batch."
  (interactive)
  (let ((edit (cmacs-dbexplorer-review--edit-at-point))
        (grid cmacs-dbexplorer-review--grid))
    (unless (buffer-live-p grid)
      (user-error "cmacs-dbexplorer: the grid this batch came from is gone"))
    (with-current-buffer grid (cmacs-dbexplorer-edit--drop edit))
    (cmacs-dbexplorer-review-refresh)))

(defun cmacs-dbexplorer-review-refresh ()
  "Redraw the review from the grid's current batch."
  (interactive)
  (let ((grid cmacs-dbexplorer-review--grid))
    (when (buffer-live-p grid)
      (cmacs-dbexplorer-review-render
       (with-current-buffer grid cmacs-dbexplorer-edit--edits)
       (cmacs-dbexplorer-buffer-connection)))))

(defun cmacs-dbexplorer-review-apply ()
  "Send the whole batch as one call."
  (interactive)
  (let ((grid cmacs-dbexplorer-review--grid))
    (unless (buffer-live-p grid)
      (user-error "cmacs-dbexplorer: the grid this batch came from is gone"))
    (let ((edits (with-current-buffer grid cmacs-dbexplorer-edit--edits)))
      (with-current-buffer grid
        (cmacs-dbexplorer-edit--apply edits))
      (quit-window t))))

(defvar cmacs-dbexplorer-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "j" #'next-line)
    (define-key map "k" #'cmacs-dbexplorer-review-drop)
    (define-key map "c" #'cmacs-dbexplorer-review-apply)
    (define-key map "g" #'cmacs-dbexplorer-review-refresh)
    (define-key map "q" #'quit-window)
    map)
  "Keymap for `cmacs-dbexplorer-review-mode'.")

(define-derived-mode cmacs-dbexplorer-review-mode special-mode "DB-Review"
  "What is about to be sent to the database.

\\{cmacs-dbexplorer-review-mode-map}"
  (buffer-disable-undo)
  (setq-local truncate-lines nil))

(defun cmacs-dbexplorer-edit-commit ()
  "Review the staged changes before sending them."
  (interactive)
  (unless cmacs-dbexplorer-edit--edits
    (user-error "cmacs-dbexplorer: nothing is staged"))
  (let* ((grid (current-buffer))
         (name (or cmacs-dbexplorer--connection-name "?"))
         (connection (cmacs-dbexplorer-buffer-connection))
         (edits cmacs-dbexplorer-edit--edits)
         (buffer (get-buffer-create (cmacs-dbexplorer-review-buffer-name name))))
    (with-current-buffer buffer
      (cmacs-dbexplorer-review-mode)
      (setq cmacs-dbexplorer--connection-name name)
      (setq cmacs-dbexplorer-review--grid grid)
      (cmacs-dbexplorer-review-render edits connection))
    (pop-to-buffer buffer)))


;;;; Sending ------------------------------------------------------------

(defun cmacs-dbexplorer-edit--inexact-p (edits)
  "Return non-nil when any of EDITS names its row without a primary key."
  (and cmacs-dbexplorer-allow-editing-without-pk
       cmacs-dbexplorer-grid--result
       (not (cmacs-dbexplorer-result-editable-p cmacs-dbexplorer-grid--result))
       (seq-some (lambda (edit)
                   (memq (cmacs-dbexplorer-edit-op edit) '(update delete)))
                 edits)
       t))

(defun cmacs-dbexplorer-edit--apply (edits)
  "Send EDITS to the database as one batch.

Confirmed first when any of them names its row by matching every column
rather than by a key: that WHERE clause is only as unique as the data
happens to be, and the confirmation is per commit rather than once per
session because the risk is per batch."
  (cmacs-dbexplorer-edit--check-writable)
  (dolist (edit edits)
    (when (and (eq (cmacs-dbexplorer-edit-op edit) 'insert)
               (null (cmacs-dbexplorer-edit-values edit)))
      (user-error "cmacs-dbexplorer: a staged row has no values in it yet")))
  (when (and (cmacs-dbexplorer-edit--inexact-p edits)
             (not (yes-or-no-p
                   "These rows have no primary key; match on every column \
instead?  A duplicate row would match too. ")))
    (user-error "cmacs-dbexplorer: not applied"))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--apply-edits-async)
  (let* ((connection (cmacs-dbexplorer-buffer-connection-or-error))
         (grid (current-buffer))
         (ops (cmacs-dbexplorer-edits-to-ops edits)))
    (cmacs-dbexplorer--apply-edits-async
     (cmacs-dbexplorer--handle connection) ops
     (lambda (reply)
       (cmacs-dbexplorer-edit--applied grid connection edits reply)))))

(defun cmacs-dbexplorer-edit--applied (grid connection edits reply)
  "Handle REPLY to sending EDITS from GRID on CONNECTION."
  (let ((error-message (cmacs-dbexplorer--reply-error reply))
        (failed (alist-get :failed-index reply)))
    (cmacs-dbexplorer--run-hook
     'cmacs-dbexplorer-edits-applied-functions
     (list :connection (cmacs-dbexplorer-connection-name connection)
           :applied (alist-get :applied reply)
           :edits edits
           :error error-message))
    (if error-message
        ;; Nothing is unstaged on failure.  The batch is applied as one
        ;; unit, so a failure means none of it happened, and dropping the
        ;; edits would lose work that is still valid.
        (message "cmacs-dbexplorer: not applied%s: %s"
                 (if failed (format " (change %s)" failed) "")
                 error-message)
      (when (buffer-live-p grid)
        (with-current-buffer grid
          (setq cmacs-dbexplorer-edit--edits nil)
          (when cmacs-dbexplorer-grid--source
            (cmacs-dbexplorer-grid-run))
          (cmacs-dbexplorer-grid-refresh)))
      (message "cmacs-dbexplorer: %s change(s) applied"
               (or (alist-get :applied reply) (length edits))))))


;;;; Keys ---------------------------------------------------------------

;; Installed into the grid's map from here, so that the grid does not have
;; to know the editing layer exists in order to load.
(let ((map cmacs-dbexplorer-grid-mode-map))
  (define-key map "e" #'cmacs-dbexplorer-edit-cell)
  (define-key map "i" #'cmacs-dbexplorer-edit-insert-row)
  (define-key map "D" #'cmacs-dbexplorer-edit-delete-row)
  (define-key map "u" #'cmacs-dbexplorer-edit-unstage)
  (define-key map "U" #'cmacs-dbexplorer-edit-unstage-all)
  (define-key map "R" #'cmacs-dbexplorer-edit-toggle-mode)
  (define-key map (kbd "C-c C-c") #'cmacs-dbexplorer-edit-commit))

;; The grid's map was already promoted to Evil intercept precedence when
;; it loaded, and the copy that promotion makes was of the keys as they
;; were then -- so the ones added above need it run again.
(cmacs-evil-setup-mode-map cmacs-dbexplorer-grid-mode-map
                           'cmacs-dbexplorer-grid-mode)

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-dbexplorer-review-mode 'motion)))

(cmacs-evil-setup-mode-map cmacs-dbexplorer-review-mode-map
                           'cmacs-dbexplorer-review-mode)

(provide 'cmacs-dbexplorer-edit)
;;; cmacs-dbexplorer-edit.el ends here
