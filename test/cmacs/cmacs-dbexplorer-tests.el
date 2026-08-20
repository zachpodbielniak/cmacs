;;; cmacs-dbexplorer-tests.el --- Tests for the database explorer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the cmacs-dbexplorer subsystem.

;;; Code:

(require 'ert)
(require 'cmacs-dbexplorer-model nil t)

;; `fboundp' and `boundp', not `cmacs-feature-p': the latter lives in
;; lisp/cmacs/cmacs.el, which is not loaded when a test file is run on its
;; own.  Calling it there is a void-function error that ERT turns into a
;; skip, so every `skip-unless' in the file passes vacuously and the suite
;; reports green having executed nothing.
;;
;; Checking a concrete DEFUN as well as the flag matters: the flag says
;; the subsystem was compiled in, the DEFUN says its symbols actually
;; loaded.
(defun cmacs-dbexplorer-tests--available-p ()
  "Non-nil when this build compiled in the database explorer."
  (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer
       (fboundp 'cmacs-dbexplorer-supported-p)))

(ert-deftest cmacs-dbexplorer-feature-flag ()
  "The feature flag is always bound, and agrees with the primitives."
  ;; Bound in every build, including one without the subsystem -- that is
  ;; what lets a user config say (when IS-CMACS-DBEXPLORER ...) without a
  ;; void-variable error.
  (should (boundp 'is-cmacs-dbexplorer))
  (should (eq (and (boundp 'IS-CMACS-DBEXPLORER) IS-CMACS-DBEXPLORER)
              (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer)))
  (when (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer)
    (should (fboundp 'cmacs-dbexplorer-supported-p))))

(ert-deftest cmacs-dbexplorer-supported-p ()
  "The runtime predicate reports the subsystem as usable."
  (skip-unless (cmacs-dbexplorer-tests--available-p))
  (should (cmacs-dbexplorer-supported-p)))

(ert-deftest cmacs-dbexplorer-in-compiled-features ()
  "The subsystem appears in the compiled-feature list."
  (skip-unless (cmacs-dbexplorer-tests--available-p))
  (skip-unless (fboundp 'cmacs-compiled-features))
  (should (memq 'dbexplorer (cmacs-compiled-features))))


;;;; Model layer -------------------------------------------------------

;; These need no database and no C: the model is deliberately pure, which
;; is what lets a view be tested without one.

(defun cmacs-dbexplorer-tests--model-p ()
  "Non-nil when the model layer loaded."
  (featurep 'cmacs-dbexplorer-model))

(defun cmacs-dbexplorer-tests--result (columns pk rows)
  "Build a result over COLUMNS with primary key PK holding ROWS."
  (cmacs-dbexplorer-result-create
   :connection-name "test" :sql "SELECT" :table "t" :primary-key pk
   :columns (vconcat (mapcar (lambda (c) (list :name c)) columns))
   :rows (vconcat (mapcar #'vconcat rows))))

(ert-deftest cmacs-dbexplorer-registry-round-trip ()
  "A registered view is retrievable, listed, and replaceable by name."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (unwind-protect
      (progn
        (cmacs-dbexplorer-register-view 'ert-a :open #'ignore :label "A")
        (cmacs-dbexplorer-register-view 'ert-b :open #'ignore
                                        :supports '(result))
        (should (cmacs-dbexplorer-view 'ert-a))
        (should (member 'ert-a (mapcar #'car (cmacs-dbexplorer-views))))
        ;; Re-registering replaces rather than duplicating, so reloading a
        ;; file that registers a view is safe.
        (cmacs-dbexplorer-register-view 'ert-a :open #'ignore :label "A2")
        (should (equal "A2" (plist-get (cmacs-dbexplorer-view 'ert-a) :label)))
        (should (= 1 (cl-count 'ert-a (mapcar #'car (cmacs-dbexplorer-views)))))
        ;; A view that names no :supports supports everything.
        (should (cmacs-dbexplorer-view-supports-p
                 (cmacs-dbexplorer-view 'ert-a) 'schema))
        (should-not (cmacs-dbexplorer-view-supports-p
                     (cmacs-dbexplorer-view 'ert-b) 'schema)))
    (cmacs-dbexplorer-unregister-view 'ert-a)
    (cmacs-dbexplorer-unregister-view 'ert-b)))

(ert-deftest cmacs-dbexplorer-registry-requires-keys ()
  "A registration missing a required key is refused."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (should-error (cmacs-dbexplorer-register-view 'ert-bad :label "no open"))
  (should-not (cmacs-dbexplorer-view 'ert-bad)))

(ert-deftest cmacs-dbexplorer-row-key-complete ()
  "A row whose primary-key columns were all selected yields a key."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (let ((r (cmacs-dbexplorer-tests--result
            '("a" "b" "c") '("a" "b") '(("1" "2" "3")))))
    (should (cmacs-dbexplorer-result-editable-p r))
    (should (equal '(("a" . "1") ("b" . "2"))
                   (cmacs-dbexplorer-result-row-key r 0)))))

(ert-deftest cmacs-dbexplorer-row-key-partial-is-nil ()
  "A primary-key column missing from the SELECT yields NO key at all.

A partial key still builds a syntactically valid WHERE clause -- one that
matches more rows than the user pointed at -- so a half key is more
dangerous than none."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (let ((r (cmacs-dbexplorer-tests--result
            '("a" "c") '("a" "b") '(("1" "3")))))
    (should-not (cmacs-dbexplorer-result-row-key r 0))))

(ert-deftest cmacs-dbexplorer-not-editable-without-key ()
  "Rows of a keyless table or an arbitrary join are not editable."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (should-not (cmacs-dbexplorer-result-editable-p
               (cmacs-dbexplorer-tests--result '("a") nil '(("1")))))
  (should-not (cmacs-dbexplorer-result-editable-p
               (cmacs-dbexplorer-result-create
                :connection-name "t" :sql "SELECT"
                :columns (vector (list :name "a"))
                :rows (vector (vector "1"))))))

(ert-deftest cmacs-dbexplorer-edit-ops-carry-expect ()
  "Update and delete ops carry :expect 1; insert does not."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (let* ((edits (list (cmacs-dbexplorer-edit-create
                       :op 'update :table "t" :key '(("id" . "1"))
                       :values '(("n" . "x")))
                      (cmacs-dbexplorer-edit-create
                       :op 'insert :table "t" :values '(("n" . "y")))
                      (cmacs-dbexplorer-edit-create
                       :op 'delete :table "t" :key '(("id" . "2")))))
         (ops (cmacs-dbexplorer-edits-to-ops edits)))
    (should (= 3 (length ops)))
    (should (eq 1 (plist-get (nth 0 ops) :expect)))
    (should-not (plist-get (nth 1 ops) :expect))
    (should (eq 1 (plist-get (nth 2 ops) :expect)))
    (should (equal '(("id" . "1")) (plist-get (nth 0 ops) :where)))))

(ert-deftest cmacs-dbexplorer-hook-survives-a-bad-listener ()
  "One listener signalling does not stop the others being told."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (let ((seen nil)
        (cmacs-dbexplorer-schema-updated-functions nil))
    (add-hook 'cmacs-dbexplorer-schema-updated-functions
              (lambda (_p) (error "deliberate")))
    (add-hook 'cmacs-dbexplorer-schema-updated-functions
              (lambda (p) (setq seen p)) t)
    (cmacs-dbexplorer--run-hook 'cmacs-dbexplorer-schema-updated-functions
                                '(:connection "x"))
    (should (equal '(:connection "x") seen))))

(ert-deftest cmacs-dbexplorer-cell-display ()
  "NULL and oversized blobs render distinguishably from their text."
  (skip-unless (cmacs-dbexplorer-tests--model-p))
  (should (equal "NULL" (cmacs-dbexplorer-cell-display :null)))
  (should (equal "∅" (cmacs-dbexplorer-cell-display :null "∅")))
  (should (equal "<4096 bytes>" (cmacs-dbexplorer-cell-display '(:blob . 4096))))
  ;; The literal string "NULL" must not be confusable with a SQL NULL.
  (should (equal "NULL" (cmacs-dbexplorer-cell-display "NULL")))
  (should (equal "plain" (cmacs-dbexplorer-cell-display "plain"))))


;;;; View layer --------------------------------------------------------

;; None of these need a database, a window system or the C primitives:
;; the grid renders a `cmacs-dbexplorer-result' struct, and one can be
;; built by hand.  That is deliberate -- a table whose columns only line
;; up when a server is reachable is a table nobody can test.

(require 'cmacs-dbexplorer nil t)
(require 'cmacs-dbexplorer-grid nil t)
(require 'cmacs-dbexplorer-edit nil t)
(require 'cmacs-dbexplorer-export nil t)

(defun cmacs-dbexplorer-tests--ui-p ()
  "Non-nil when the view layer loaded."
  (and (featurep 'cmacs-dbexplorer-grid) (featurep 'cmacs-dbexplorer-edit)))

(defun cmacs-dbexplorer-tests--typed-result (columns pk rows)
  "Build a result over COLUMNS with primary key PK holding ROWS.

Like `cmacs-dbexplorer-tests--result' but naming a schema too, which is
what the generated SQL qualifies with."
  (cmacs-dbexplorer-result-create
   :connection-name "test" :sql "SELECT" :table "people" :schema "public"
   :primary-key pk
   :columns (vconcat (mapcar (lambda (c) (list :name c)) columns))
   :rows (vconcat (mapcar #'vconcat rows))))

(defmacro cmacs-dbexplorer-tests--with-grid (result &rest body)
  "Render RESULT in a temporary grid buffer and run BODY there."
  (declare (indent 1) (debug t))
  `(let ((cmacs-dbexplorer-unicode t))
     (with-temp-buffer
       (cmacs-dbexplorer-grid-mode)
       (setq cmacs-dbexplorer--connection-name "test")
       (setq cmacs-dbexplorer-grid--result ,result)
       (cmacs-dbexplorer-grid--render)
       ,@body)))

(defun cmacs-dbexplorer-tests--column-offsets ()
  "Return (COLUMN . OFFSET) for every column starting on the line at point.

The separator before a column carries the PREVIOUS column's index, so the
first position holding index N is exactly where column N's text begins."
  (let ((bol (line-beginning-position))
        (eol (line-end-position))
        (seen nil))
    (save-excursion
      (goto-char bol)
      (while (< (point) eol)
        (let ((column (get-text-property (point) 'cmacs-dbexplorer-column)))
          (when (and column (not (assq column seen)))
            (push (cons column (- (point) bol)) seen)))
        (forward-char 1)))
    (sort (nreverse seen) (lambda (a b) (< (car a) (car b))))))

(defun cmacs-dbexplorer-tests--cell-text (column widths)
  "Return the text of COLUMN on the line at point, given WIDTHS."
  (let* ((offset (alist-get column (cmacs-dbexplorer-tests--column-offsets)))
         (bol (line-beginning-position)))
    (buffer-substring-no-properties (+ bol offset)
                                    (+ bol offset (nth column widths)))))

(defun cmacs-dbexplorer-tests--goto-row (row)
  "Move point to the line rendering ROW."
  (goto-char (point-min))
  (while (and (not (eobp))
              (not (eql row (get-text-property (point) 'cmacs-dbexplorer-row))))
    (forward-line 1))
  (should-not (eobp)))

(ert-deftest cmacs-dbexplorer-grid-columns-line-up ()
  "Every row starts each column at the same display offset as the header.

The reason this is asserted rather than eyeballed: the columns are
anchored with `:align-to' AND padded, and the two agreeing is what makes
the plain text of the buffer line up as well as its display."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((result (cmacs-dbexplorer-tests--typed-result
                 '("id" "name" "note") '("id")
                 '(("1" "alpha" "hi")
                   ("2222" "b" "a longer note")
                   ("3" "gamma" "x")))))
    (cmacs-dbexplorer-tests--with-grid result
      (let* ((widths (cmacs-dbexplorer-grid--widths result))
             (expected (let ((index -1))
                         (mapcar (lambda (offset)
                                   (cons (setq index (1+ index)) offset))
                                 (cmacs-dbexplorer-grid--offsets widths)))))
        ;; The header row and every data row, measured the same way.
        (goto-char (point-min))
        (should (equal expected (cmacs-dbexplorer-tests--column-offsets)))
        (dotimes (row 3)
          (cmacs-dbexplorer-tests--goto-row row)
          (should (equal expected (cmacs-dbexplorer-tests--column-offsets))))
        ;; And the header names really are over their own columns.
        (goto-char (point-min))
        (should (equal "id" (string-trim (cmacs-dbexplorer-tests--cell-text
                                          0 widths))))
        (should (equal "name" (string-trim (cmacs-dbexplorer-tests--cell-text
                                            1 widths))))))))

(ert-deftest cmacs-dbexplorer-grid-null-is-not-the-string-null ()
  "A SQL NULL renders as the null glyph and is faced; the text is not.

A column may legitimately hold the string \"NULL\", and confusing it with
a missing value is the difference between a bug and a typo somebody
committed on purpose."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((result (cmacs-dbexplorer-tests--typed-result
                 '("id" "value") '("id")
                 '(("1" :null) ("2" "NULL")))))
    (cmacs-dbexplorer-tests--with-grid result
      (let ((widths (cmacs-dbexplorer-grid--widths result)))
        (cmacs-dbexplorer-tests--goto-row 0)
        (should (equal "∅" (string-trim
                            (cmacs-dbexplorer-tests--cell-text 1 widths))))
        (let ((offset (alist-get 1 (cmacs-dbexplorer-tests--column-offsets))))
          (should (eq 'cmacs-dbexplorer-null
                      (get-text-property (+ (line-beginning-position) offset)
                                         'face))))
        (cmacs-dbexplorer-tests--goto-row 1)
        (should (equal "NULL" (string-trim
                               (cmacs-dbexplorer-tests--cell-text 1 widths))))
        (let ((offset (alist-get 1 (cmacs-dbexplorer-tests--column-offsets))))
          (should-not (get-text-property (+ (line-beginning-position) offset)
                                         'face)))))))

(ert-deftest cmacs-dbexplorer-grid-truncates-wide-cells ()
  "A cell wider than the cap is cut to the cap and ends in the ellipsis."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((cmacs-dbexplorer-column-max-width 8)
        (result (cmacs-dbexplorer-tests--typed-result
                 '("id" "note") '("id")
                 '(("1" "a note far too long for the column")))))
    (cmacs-dbexplorer-tests--with-grid result
      (let ((widths (cmacs-dbexplorer-grid--widths result)))
        (should (= 8 (nth 1 widths)))
        (cmacs-dbexplorer-tests--goto-row 0)
        (let ((text (cmacs-dbexplorer-tests--cell-text 1 widths)))
          (should (= 8 (string-width text)))
          (should (string-suffix-p "…" text))
          ;; Truncated, not merely clipped by the window.
          (should-not (string-match-p "column" text)))))))

(ert-deftest cmacs-dbexplorer-grid-shows-the-staged-value ()
  "A staged edit draws its new value, faced, rather than the stored one."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((result (cmacs-dbexplorer-tests--typed-result
                 '("id" "name") '("id") '(("1" "alpha")))))
    (cmacs-dbexplorer-tests--with-grid result
      (cmacs-dbexplorer-tests--goto-row 0)
      (cmacs-dbexplorer-edit--set result 0 1 "ALPHA")
      (cmacs-dbexplorer-tests--goto-row 0)
      (let ((widths (cmacs-dbexplorer-grid--widths result)))
        (should (equal "ALPHA" (string-trim
                                (cmacs-dbexplorer-tests--cell-text 1 widths)))))
      ;; And the row is marked in the gutter.
      (should (equal "*" (buffer-substring-no-properties
                          (line-beginning-position)
                          (1+ (line-beginning-position))))))))

(ert-deftest cmacs-dbexplorer-staged-edits-round-trip-to-ops ()
  "Staging through the grid's own commands produces the right C ops."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((result (cmacs-dbexplorer-tests--typed-result
                 '("id" "name") '("id") '(("1" "alpha") ("2" "beta")))))
    (cmacs-dbexplorer-tests--with-grid result
      (cmacs-dbexplorer-tests--goto-row 0)
      (cmacs-dbexplorer-edit--set result 0 1 "ALPHA")
      (cmacs-dbexplorer-tests--goto-row 1)
      (cmacs-dbexplorer-edit-delete-row)
      (cmacs-dbexplorer-edit-insert-row)
      (setf (cmacs-dbexplorer-edit-values
             (car (cmacs-dbexplorer-edit-pending-inserts)))
            '(("name" . "gamma")))
      (let ((ops (cmacs-dbexplorer-edits-to-ops (cmacs-dbexplorer-edit-pending))))
        (should (= 3 (length ops)))
        (should (equal '(:op update :schema "public" :table "people"
                             :set (("name" . "ALPHA")) :where (("id" . "1"))
                             :expect 1)
                       (nth 0 ops)))
        (should (equal '(:op delete :schema "public" :table "people"
                             :where (("id" . "2")) :expect 1)
                       (nth 1 ops)))
        (should (equal '(:op insert :schema "public" :table "people"
                             :values (("name" . "gamma")))
                       (nth 2 ops))))
      ;; Unstaging everything really does empty the batch.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (cmacs-dbexplorer-edit-unstage-all))
      (should-not (cmacs-dbexplorer-edit-pending)))))

(ert-deftest cmacs-dbexplorer-edit-refuses-rows-it-cannot-name ()
  "Editing a keyless result is refused, and says why."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((cmacs-dbexplorer-allow-editing-without-pk nil)
        (result (cmacs-dbexplorer-tests--result '("a" "b") nil '(("1" "2")))))
    (should-error (cmacs-dbexplorer-edit--ensure-editable result)
                  :type 'user-error))
  ;; A statement's output has no table at all, which is a different
  ;; refusal with a different explanation.
  (let ((result (cmacs-dbexplorer-result-create
                 :connection-name "test" :sql "SELECT"
                 :columns (vector '(:name "a")) :rows (vector (vector "1")))))
    (should-error (cmacs-dbexplorer-edit--ensure-editable result)
                  :type 'user-error)))

(ert-deftest cmacs-dbexplorer-review-names-the-table-and-columns ()
  "The review buffer shows statements naming the right table and columns."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (let ((edits (list (cmacs-dbexplorer-edit-create
                      :op 'update :table "people" :schema "public"
                      :key '(("id" . "1")) :values '(("name" . "ALPHA")))
                     (cmacs-dbexplorer-edit-create
                      :op 'insert :table "people" :schema "public"
                      :values '(("name" . "gamma")))
                     (cmacs-dbexplorer-edit-create
                      :op 'delete :table "audit" :key '(("id" . "9"))))))
    (with-temp-buffer
      ;; No connection: quoting falls back to the standard form, which is
      ;; what makes the review readable in a buffer whose connection has
      ;; since closed.
      (cmacs-dbexplorer-review-render edits nil)
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "3 change(s) in 2 table(s)" text))
        (should (string-match-p
                 (regexp-quote
                  "UPDATE \"public\".\"people\" SET \"name\" = ? WHERE \"id\" = ?")
                 text))
        (should (string-match-p
                 (regexp-quote
                  "INSERT INTO \"public\".\"people\" (\"name\") VALUES (?)")
                 text))
        (should (string-match-p
                 (regexp-quote "DELETE FROM \"audit\" WHERE \"id\" = ?") text))
        ;; The bound values are shown next to the placeholders, not
        ;; interpolated into them.
        (should (string-match-p "with ALPHA, 1" text)))
      ;; Every line describing a change carries the change itself, which
      ;; is what `k' acts on.
      (goto-char (point-min))
      (should (search-forward "UPDATE" nil t))
      (should (cmacs-dbexplorer-review--edit-at-point)))))

(ert-deftest cmacs-dbexplorer-edit-indicator-says-which-mode ()
  "The staged and immediate indicators differ, loudly."
  (skip-unless (cmacs-dbexplorer-tests--ui-p))
  (with-temp-buffer
    (let* ((cmacs-dbexplorer-edit-mode 'staged)
           (staged (cmacs-dbexplorer-edit-indicator))
           (immediate (let ((cmacs-dbexplorer-edit-mode 'immediate))
                        (cmacs-dbexplorer-edit-indicator))))
      (should-not (equal (substring-no-properties staged)
                         (substring-no-properties immediate)))
      (should (string-match-p "STAGED: 0 pending"
                              (substring-no-properties staged)))
      (should (string-match-p "IMMEDIATE"
                              (substring-no-properties immediate)))
      ;; The immediate one is faced with something that inherits `error':
      ;; it is the only thing standing between a keystroke and a write.
      (should (eq 'cmacs-dbexplorer-immediate
                  (get-text-property 0 'face immediate)))
      (should (eq 'error (face-attribute 'cmacs-dbexplorer-immediate
                                         :inherit nil t))))))

(ert-deftest cmacs-dbexplorer-url-password-resolution ()
  "A URL is only completed from auth-source when it has something to complete."
  (skip-unless (featurep 'cmacs-dbexplorer))
  ;; Already has one: untouched, and auth-source is not consulted.
  (should (equal "postgresql://u:p@h:5432/db"
                 (cmacs-dbexplorer-resolve-url "postgresql://u:p@h:5432/db")))
  ;; Declared inline: untouched even though it has no password yet.
  (should (equal "postgresql://u@h/db"
                 (cmacs-dbexplorer-resolve-url "postgresql://u@h/db" t)))
  ;; No host to look one up by -- every sqlite URL.
  (should (equal "sqlite:///tmp/notes.db"
                 (cmacs-dbexplorer-resolve-url "sqlite:///tmp/notes.db")))
  ;; And a resolved URL is never shown with its secret in it.
  (should (equal "postgresql://u:***@h:5432/db"
                 (cmacs-dbexplorer-redact-url "postgresql://u:p@h:5432/db"))))

(ert-deftest cmacs-dbexplorer-exporters-round-trip ()
  "The shipped exporters write the rows they were given."
  (skip-unless (and (cmacs-dbexplorer-tests--ui-p)
                    (featurep 'cmacs-dbexplorer-export)))
  (let ((result (cmacs-dbexplorer-tests--typed-result
                 '("id" "note") '("id") '(("1" "a,b") ("2" :null))))
        (file (make-temp-file "cmacs-dbexplorer-test" nil ".csv")))
    (unwind-protect
        (progn
          (cmacs-dbexplorer-export-result result file 'csv t)
          (let ((text (with-temp-buffer (insert-file-contents file)
                                        (buffer-string))))
            (should (string-prefix-p "id,note\n" text))
            ;; A value holding the separator is quoted, not corrupted.
            (should (string-match-p "^1,\"a,b\"$" text)))
          (cmacs-dbexplorer-export-result result file 'json nil)
          (let ((parsed (json-parse-string
                         (with-temp-buffer (insert-file-contents file)
                                           (buffer-string)))))
            (should (= 2 (length parsed)))
            ;; JSON can say NULL and does; CSV cannot and does not.
            (should (eq :null (gethash "note" (aref parsed 1))))))
      (delete-file file))))

(provide 'cmacs-dbexplorer-tests)
;;; cmacs-dbexplorer-tests.el ends here
