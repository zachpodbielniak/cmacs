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


;;;; The C layer -------------------------------------------------------

;; These do talk to a database: an in-memory SQLite one, which every
;; build has, because Emacs already requires SQLite and orm-glib is built
;; with that driver unconditionally.  They are the only tests here that
;; need the primitives, and they are what covers the two things the model
;; and view layers cannot check for themselves -- that a read-only
;; connection really does refuse writes, and that a batch of edits really
;; is all-or-nothing.

(require 'seq)

(defconst cmacs-dbexplorer-tests--timeout 15.0
  "Seconds to wait for a database reply before failing.

A timeout rather than an unbounded spin: a primitive that never calls
back is a bug, and a suite that hangs on it reports nothing at all,
whereas one that fails on it names the test that broke.")

(defun cmacs-dbexplorer-tests--c-p ()
  "Non-nil when the C primitives are present in this build."
  (and (cmacs-dbexplorer-tests--available-p)
       (fboundp 'cmacs-dbexplorer--connect-async)
       (fboundp 'cmacs-dbexplorer--query-async)))

(defun cmacs-dbexplorer-tests--wait (predicate what)
  "Spin until PREDICATE returns non-nil, failing after the timeout.
WHAT names what was being waited for, for the failure message."
  (let ((deadline (+ (float-time) cmacs-dbexplorer-tests--timeout))
        (value nil))
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      ;; `sit-for' is what runs Emacs's select loop, and the select loop
      ;; is what dispatches cmacs's GMainContext -- so this is not idling
      ;; while the answer arrives, it is what lets the answer arrive.
      (sit-for 0.01))
    (unless value
      (ert-fail (format "timed out after %ss waiting for %s"
                        cmacs-dbexplorer-tests--timeout what)))
    value))

(defun cmacs-dbexplorer-tests--call (fn &rest args)
  "Call FN with ARGS and a callback, and return the reply it was given."
  (let ((reply 'cmacs-dbexplorer-tests--pending))
    (apply fn (append args (list (lambda (r) (setq reply r)))))
    (cmacs-dbexplorer-tests--wait
     (lambda ()
       (unless (eq reply 'cmacs-dbexplorer-tests--pending)
         (or reply t)))
     (format "%s" fn))
    reply))

(defvar cmacs-dbexplorer-tests--events nil
  "Stream events seen so far, as (ID . PAYLOAD), newest first.")

(defun cmacs-dbexplorer-tests--collect (id payload)
  "Record PAYLOAD as an event of stream ID."
  (push (cons id payload) cmacs-dbexplorer-tests--events))

(defun cmacs-dbexplorer-tests--events-for (id)
  "Return the payloads seen for stream ID, oldest first."
  (mapcar #'cdr (reverse (seq-filter (lambda (event) (eql id (car event)))
                                     cmacs-dbexplorer-tests--events))))

(defun cmacs-dbexplorer-tests--terminated-p (id)
  "Return the terminating payload of stream ID, or nil."
  (seq-find (lambda (payload) (memq (car payload) '(:end :error)))
            (cmacs-dbexplorer-tests--events-for id)))

(defun cmacs-dbexplorer-tests--stream (handle sql &optional params options)
  "Run SQL on HANDLE and return its events, oldest first."
  (setq cmacs-dbexplorer-tests--events nil)
  (cmacs-dbexplorer--set-stream-callback #'cmacs-dbexplorer-tests--collect)
  (let ((id (cmacs-dbexplorer--query-async handle sql params options)))
    (cmacs-dbexplorer-tests--wait
     (lambda () (cmacs-dbexplorer-tests--terminated-p id))
     (format "the query %S to finish" sql))
    (cmacs-dbexplorer-tests--events-for id)))

(defun cmacs-dbexplorer-tests--rows (handle sql)
  "Return the rows SQL selects on HANDLE, as a list of vectors."
  (let ((rows nil))
    (dolist (payload (cmacs-dbexplorer-tests--stream handle sql))
      (when (eq :rows (car payload))
        (setq rows (append rows (append (nth 1 payload) nil)))))
    rows))

(defun cmacs-dbexplorer-tests--scalar (handle sql)
  "Return the first cell of the first row SQL selects on HANDLE."
  (let ((rows (cmacs-dbexplorer-tests--rows handle sql)))
    (and rows (aref (car rows) 0))))

(defun cmacs-dbexplorer-tests--exec (handle sql &optional params)
  "Run SQL on HANDLE for its effect, failing if it errors."
  (let ((reply (cmacs-dbexplorer-tests--call
                #'cmacs-dbexplorer--execute-async handle sql params)))
    (when (alist-get :error reply)
      (ert-fail (format "%s: %s" sql (alist-get :error reply))))
    reply))

(defun cmacs-dbexplorer-tests--open (&optional url)
  "Open URL, or an in-memory database, and return the handle."
  (let ((reply (cmacs-dbexplorer-tests--call
                #'cmacs-dbexplorer--connect-async
                (or url "sqlite:///:memory:") nil)))
    (when (alist-get :error reply)
      (ert-fail (format "cannot connect: %s" (alist-get :error reply))))
    (alist-get :handle reply)))

(defmacro cmacs-dbexplorer-tests--with-db (handle &rest body)
  "Open an in-memory database, bind HANDLE to it, and run BODY."
  (declare (indent 1) (debug t))
  `(let ((,handle (cmacs-dbexplorer-tests--open)))
     (unwind-protect
         (progn
           (cmacs-dbexplorer-tests--exec
            ,handle "CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT)")
           ,@body)
       (cmacs-dbexplorer--disconnect ,handle))))

(ert-deftest cmacs-dbexplorer-c-connection-lifecycle ()
  "A connection opens, appears in the listing, and stops existing on close."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (let* ((file (make-temp-file "cmacs-dbexplorer-test" nil ".db"))
         (handle (cmacs-dbexplorer-tests--open (concat "sqlite://" file))))
    (unwind-protect
        (progn
          (should (integerp handle))
          (let ((info (cmacs-dbexplorer--connection-info handle)))
            (should (equal handle (alist-get :handle info)))
            (should (stringp (alist-get :dialect info)))
            (should-not (alist-get :read-only info)))
          (should (memq handle (mapcar (lambda (entry) (alist-get :handle entry))
                                       (cmacs-dbexplorer--connection-list))))
          ;; The flag really is a property of the connection, not of a
          ;; struct somewhere above it.
          (cmacs-dbexplorer--set-read-only handle t)
          (should (alist-get :read-only
                             (cmacs-dbexplorer--connection-info handle)))
          (cmacs-dbexplorer--set-read-only handle nil)
          (cmacs-dbexplorer--disconnect handle)
          (should-not (memq handle
                            (mapcar (lambda (entry) (alist-get :handle entry))
                                    (cmacs-dbexplorer--connection-list))))
          ;; Closing twice is not an error; the second one has nothing to
          ;; do, which is what a `q' in two views amounts to.
          (should-not (cmacs-dbexplorer--disconnect handle)))
      (ignore-errors (delete-file file)))))

(ert-deftest cmacs-dbexplorer-c-stale-handle-signals ()
  "A handle that was never issued, or has been closed, signals.

This is the one class of failure that IS a signal: it is a bug in the
caller rather than something the database said, and the backtrace is
what fixes it.  Everything the database reports arrives in a reply
instead, because it is produced inside a GLib callback where a signal
would abort Emacs."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (should-error (cmacs-dbexplorer--connection-info 999999)
                :type 'cmacs-dbexplorer-error)
  (should-error (cmacs-dbexplorer--quote-identifier -1 "x")
                :type 'cmacs-dbexplorer-error)
  (let ((handle (cmacs-dbexplorer-tests--open)))
    (cmacs-dbexplorer--disconnect handle)
    (should-error (cmacs-dbexplorer--schemas-async handle #'ignore)
                  :type 'cmacs-dbexplorer-error)
    (should-error (cmacs-dbexplorer--query-async handle "SELECT 1" nil nil)
                  :type 'cmacs-dbexplorer-error)))

(ert-deftest cmacs-dbexplorer-c-stream-event-order ()
  "A query reports its columns, then its rows, then exactly one ending."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES (?)"
                                  (list "alpha"))
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES (?)"
                                  (list :null))
    (let* ((events (cmacs-dbexplorer-tests--stream
                    handle "SELECT id, n FROM t ORDER BY id"))
           (kinds (mapcar #'car events)))
      (should (eq :meta (car kinds)))
      (should (eq :end (car (last kinds))))
      (should (= 1 (seq-count (lambda (k) (memq k '(:end :error))) kinds)))
      ;; The column metadata arrives before any row, which is what lets a
      ;; grid draw its header while the rows are still coming.
      (should (< (seq-position kinds :meta) (seq-position kinds :rows)))
      (let ((columns (nth 1 (car events))))
        (should (equal '("id" "n")
                       (mapcar (lambda (c) (plist-get c :name))
                               (append columns nil)))))
      (let ((rows (cmacs-dbexplorer-tests--rows
                   handle "SELECT id, n FROM t ORDER BY id")))
        (should (= 2 (length rows)))
        (should (equal "alpha" (aref (nth 0 rows) 1)))
        ;; A SQL NULL is the keyword, never the string "NULL".
        (should (eq :null (aref (nth 1 rows) 1))))
      (let ((end (car (last events))))
        (should-not (plist-get (cdr end) :truncated))
        (should (eq 2 (plist-get (cdr end) :row-count)))
        (should (numberp (plist-get (cdr end) :elapsed-ms)))))))

(ert-deftest cmacs-dbexplorer-c-stream-truncation ()
  "A query capped by :max-rows stops there and says it was capped."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (dotimes (i 5)
      (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES (?)"
                                    (list (number-to-string i))))
    (let* ((events (cmacs-dbexplorer-tests--stream
                    handle "SELECT id FROM t ORDER BY id" nil '(:max-rows 2)))
           (end (cdr (car (last events))))
           (rows (seq-mapcat (lambda (payload)
                               (when (eq :rows (car payload))
                                 (append (nth 1 payload) nil)))
                             events)))
      (should (= 2 (length rows)))
      (should (eq 2 (plist-get end :row-count)))
      ;; The cap being reached is reported, because a view that silently
      ;; showed two of five rows would be lying about the table.
      (should (plist-get end :truncated)))))

(ert-deftest cmacs-dbexplorer-c-cancel ()
  "A cancelled stream stops reporting, and cancelling twice is harmless."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (dotimes (i 20)
      (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES (?)"
                                    (list (number-to-string i))))
    (setq cmacs-dbexplorer-tests--events nil)
    (cmacs-dbexplorer--set-stream-callback #'cmacs-dbexplorer-tests--collect)
    (let ((id (cmacs-dbexplorer--query-async handle "SELECT * FROM t" nil nil)))
      ;; Cancelled before the loop has run once, so nothing can have been
      ;; delivered yet -- payloads only arrive from the event loop, and
      ;; this has not yielded to it.
      (cmacs-dbexplorer--cancel id)
      (dotimes (_ 50) (sit-for 0.01))
      (should-not (cmacs-dbexplorer-tests--terminated-p id))
      ;; Cancelling an id that is already gone is the normal case, not a
      ;; mistake: a view quits while a batch is in flight.
      (should-not (cmacs-dbexplorer--cancel id))
      (should-not (cmacs-dbexplorer--cancel 999999)))
    ;; And the connection is usable straight afterwards.
    (should (equal "20" (cmacs-dbexplorer-tests--scalar
                         handle "SELECT count(*) FROM t")))))

(ert-deftest cmacs-dbexplorer-c-read-only-classifier ()
  "A read-only connection allows reads and refuses writes, on both paths.

The matrix matters more than any single case.  A guard that classified
statements one way for `cmacs-dbexplorer--query-async' and another for
`cmacs-dbexplorer--execute-async' would look like a guard and be a hole,
so every statement here is put through both."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES ('a')")
    (cmacs-dbexplorer--set-read-only handle t)
    (let ((reads '("SELECT 1"
                   "  select 1"
                   "WITH c AS (SELECT 1) SELECT * FROM c"
                   "EXPLAIN SELECT 1"
                   "PRAGMA table_info(t)"
                   "PRAGMA foreign_keys"
                   "-- a comment\nSELECT 1"
                   "/* a comment */ SELECT 1"))
          (writes '("INSERT INTO t (n) VALUES ('x')"
                    "UPDATE t SET n = 'x'"
                    "DELETE FROM t"
                    "DROP TABLE t"
                    "WITH c AS (SELECT 1) DELETE FROM t"
                    "/*c*/DELETE FROM t"
                    "-- c\nDELETE FROM t"
                    "PRAGMA journal_mode = WAL"
                    "CREATE TABLE u (a INTEGER)"
                    "ATTACH DATABASE ':memory:' AS other")))
      (dolist (sql writes)
        (let ((reply (cmacs-dbexplorer-tests--call
                      #'cmacs-dbexplorer--execute-async handle sql nil)))
          (should (string-match-p "read-only"
                                  (or (alist-get :error reply) ""))))
        (let* ((events (cmacs-dbexplorer-tests--stream handle sql))
               (last-event (car (last events))))
          (should (eq :error (car last-event)))
          (should (string-match-p "read-only" (nth 1 last-event)))))
      (dolist (sql reads)
        (let ((reply (cmacs-dbexplorer-tests--call
                      #'cmacs-dbexplorer--execute-async handle sql nil)))
          (should-not (string-match-p "read-only"
                                      (or (alist-get :error reply) ""))))
        (let ((last-event (car (last (cmacs-dbexplorer-tests--stream
                                      handle sql)))))
          (should-not (and (eq :error (car last-event))
                           (string-match-p "read-only" (nth 1 last-event)))))))
    ;; The table is still there, and still holds exactly what it did.
    (cmacs-dbexplorer--set-read-only handle nil)
    (should (equal "1" (cmacs-dbexplorer-tests--scalar
                        handle "SELECT count(*) FROM t")))
    ;; And with the flag off the same statements go through, which is
    ;; what proves the guard is the flag and not the classifier refusing
    ;; everything.
    (cmacs-dbexplorer-tests--exec handle "DELETE FROM t")
    (should (equal "0" (cmacs-dbexplorer-tests--scalar
                        handle "SELECT count(*) FROM t")))))

(ert-deftest cmacs-dbexplorer-c-transactions ()
  "BEGIN, ROLLBACK, SAVEPOINT and COMMIT do what they say."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    ;; A rolled-back transaction leaves nothing behind.
    (should-not (alist-get :error (cmacs-dbexplorer-tests--call
                                   #'cmacs-dbexplorer--begin-async handle)))
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES ('gone')")
    (should-not (alist-get
                 :error (cmacs-dbexplorer-tests--call
                         #'cmacs-dbexplorer--rollback-async handle nil)))
    (should (equal "0" (cmacs-dbexplorer-tests--scalar
                        handle "SELECT count(*) FROM t")))

    ;; A savepoint rolls back only what happened after it, and leaves the
    ;; transaction it is inside open.
    (cmacs-dbexplorer-tests--call #'cmacs-dbexplorer--begin-async handle)
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES ('kept')")
    (should-not (alist-get
                 :error (cmacs-dbexplorer-tests--call
                         #'cmacs-dbexplorer--savepoint-async handle "sp1")))
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES ('undone')")
    (should-not (alist-get
                 :error (cmacs-dbexplorer-tests--call
                         #'cmacs-dbexplorer--rollback-async handle "sp1")))
    (should-not (alist-get :error (cmacs-dbexplorer-tests--call
                                   #'cmacs-dbexplorer--commit-async handle)))
    (should (equal "1" (cmacs-dbexplorer-tests--scalar
                        handle "SELECT count(*) FROM t")))
    (should (equal "kept" (cmacs-dbexplorer-tests--scalar
                           handle "SELECT n FROM t")))))

(ert-deftest cmacs-dbexplorer-c-apply-edits ()
  "A batch of edits is applied whole, or not at all."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle
                                  "INSERT INTO t (id, n) VALUES (1, 'one')")
    (cmacs-dbexplorer-tests--exec handle
                                  "INSERT INTO t (id, n) VALUES (2, 'two')")

    ;; The success path: an update, an insert and a delete in one batch.
    (let ((reply (cmacs-dbexplorer-tests--call
                  #'cmacs-dbexplorer--apply-edits-async handle
                  (list (list :op 'update :table "t"
                              :set '(("n" . "ONE")) :where '(("id" . 1))
                              :expect 1)
                        (list :op 'insert :table "t"
                              :values '(("id" . 3) ("n" . "three")))
                        (list :op 'delete :table "t"
                              :where '(("id" . 2)) :expect 1)))))
      (should-not (alist-get :error reply))
      (should (eq 3 (alist-get :applied reply))))
    (should (equal "ONE" (cmacs-dbexplorer-tests--scalar
                          handle "SELECT n FROM t WHERE id = 1")))
    (should (equal "2" (cmacs-dbexplorer-tests--scalar
                        handle "SELECT count(*) FROM t")))

    ;; The guard: an :expect that does not match rolls the WHOLE batch
    ;; back, including the statements that already succeeded.  This is
    ;; the case the feature exists for -- a WHERE matching the wrong
    ;; number of rows means the row identity the view used is not the one
    ;; the database has, and committing on that edits the wrong row.
    (let ((reply (cmacs-dbexplorer-tests--call
                  #'cmacs-dbexplorer--apply-edits-async handle
                  (list (list :op 'update :table "t"
                              :set '(("n" . "clobbered")) :where '(("id" . 1))
                              :expect 1)
                        (list :op 'update :table "t"
                              :set '(("n" . "nope")) :where '(("id" . 999))
                              :expect 1)))))
      (should (alist-get :error reply))
      (should (eq 1 (alist-get :failed-index reply)))
      ;; The message names what actually happened, not just that it did.
      (should (string-match-p "touched 0" (alist-get :error reply))))
    (should (equal "ONE" (cmacs-dbexplorer-tests--scalar
                          handle "SELECT n FROM t WHERE id = 1")))

    ;; An update with no WHERE is every row in the table, so it is
    ;; refused before it runs rather than caught by :expect afterwards.
    (let ((reply (cmacs-dbexplorer-tests--call
                  #'cmacs-dbexplorer--apply-edits-async handle
                  (list (list :op 'update :table "t"
                              :set '(("n" . "all")) :where nil)))))
      (should (string-match-p "WHERE" (or (alist-get :error reply) ""))))
    (should (equal "ONE" (cmacs-dbexplorer-tests--scalar
                          handle "SELECT n FROM t WHERE id = 1")))))

(ert-deftest cmacs-dbexplorer-c-apply-edits-nests-in-a-transaction ()
  "A failed batch inside an open transaction undoes itself and no more.

SQL has no nested BEGIN, so the batch wraps itself in a savepoint when
one is already open.  Rolling back to that savepoint has to leave what
the user did before it alone -- otherwise applying a bad batch would
silently discard the rest of their transaction."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle
                                  "INSERT INTO t (id, n) VALUES (1, 'one')")
    (cmacs-dbexplorer-tests--call #'cmacs-dbexplorer--begin-async handle)
    (cmacs-dbexplorer-tests--exec handle
                                  "INSERT INTO t (id, n) VALUES (2, 'mine')")
    (let ((reply (cmacs-dbexplorer-tests--call
                  #'cmacs-dbexplorer--apply-edits-async handle
                  (list (list :op 'delete :table "t"
                              :where '(("id" . 1)) :expect 1)
                        (list :op 'delete :table "t"
                              :where '(("id" . 999)) :expect 1)))))
      (should (alist-get :error reply)))
    ;; The transaction is still open and still usable.
    (should-not (alist-get :error (cmacs-dbexplorer-tests--call
                                   #'cmacs-dbexplorer--commit-async handle)))
    ;; Both rows survive: the batch's delete was undone, the user's
    ;; insert was not.
    (should (equal "2" (cmacs-dbexplorer-tests--scalar
                        handle "SELECT count(*) FROM t")))))

(ert-deftest cmacs-dbexplorer-c-hostile-identifiers ()
  "A table named like an injection is a table name, not three statements."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (let* ((table "a\";DROP TABLE x;--")
           (column "n\";DROP TABLE x;--")
           (quoted-table (cmacs-dbexplorer--quote-identifier handle table))
           (quoted-column (cmacs-dbexplorer--quote-identifier handle column)))
      ;; The dialect doubles its own quote character, which is what keeps
      ;; the rest of the name inside the identifier.
      (should (equal "\"a\"\";DROP TABLE x;--\"" quoted-table))

      (cmacs-dbexplorer-tests--exec handle "CREATE TABLE x (a INTEGER)")
      (cmacs-dbexplorer-tests--exec
       handle (format "CREATE TABLE %s (id INTEGER PRIMARY KEY, %s TEXT)"
                      quoted-table quoted-column))
      (cmacs-dbexplorer-tests--exec
       handle (format "INSERT INTO %s (id, %s) VALUES (1, 'before')"
                      quoted-table quoted-column))

      ;; Both halves of a staged edit go through the quoting: the table
      ;; name and the column name.
      (let ((reply (cmacs-dbexplorer-tests--call
                    #'cmacs-dbexplorer--apply-edits-async handle
                    (list (list :op 'update :table table
                                :set (list (cons column "after"))
                                :where '(("id" . 1)) :expect 1)))))
        (should-not (alist-get :error reply))
        (should (eq 1 (alist-get :applied reply))))

      (should (equal "after"
                     (cmacs-dbexplorer-tests--scalar
                      handle (format "SELECT %s FROM %s WHERE id = 1"
                                     quoted-column quoted-table))))
      ;; The sentinel the injection would have dropped is still there.
      (should (equal "1" (cmacs-dbexplorer-tests--scalar
                          handle (concat "SELECT count(*) FROM sqlite_master"
                                         " WHERE name = 'x'"))))
      ;; And the hostile name survives a round trip through introspection.
      (let ((info (cmacs-dbexplorer-tests--call
                   #'cmacs-dbexplorer--table-info-async handle nil table)))
        (should-not (alist-get :error info))
        (should (member column
                        (mapcar (lambda (c) (plist-get c :name))
                                (append (alist-get :columns info) nil))))
        (should (equal ["id"] (alist-get :primary-key info)))))))

(ert-deftest cmacs-dbexplorer-c-introspection ()
  "The schema reader answers with the shapes the tree and the editor read."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle "CREATE INDEX t_n ON t (n)")
    (cmacs-dbexplorer-tests--exec
     handle "CREATE TABLE child (id INTEGER PRIMARY KEY,
                                 parent INTEGER REFERENCES t (id))")
    (cmacs-dbexplorer-tests--exec handle "CREATE VIEW v AS SELECT id FROM t")

    (let ((schemas (cmacs-dbexplorer-tests--call
                    #'cmacs-dbexplorer--schemas-async handle)))
      (should-not (alist-get :error schemas))
      (should (vectorp (alist-get :schemas schemas))))

    (let* ((tables (cmacs-dbexplorer-tests--call
                    #'cmacs-dbexplorer--tables-async handle nil))
           (relations (append (alist-get :relations tables) nil)))
      (should-not (alist-get :error tables))
      (should (member "t" (mapcar (lambda (r) (plist-get r :name)) relations)))
      ;; A view is reported as one, so the tree can say so.
      (should (eq 'view (plist-get (seq-find (lambda (r)
                                               (equal "v" (plist-get r :name)))
                                             relations)
                                   :kind))))

    (let ((info (cmacs-dbexplorer-tests--call
                 #'cmacs-dbexplorer--table-info-async handle nil "t")))
      (should-not (alist-get :error info))
      (should (equal '("id" "n")
                     (mapcar (lambda (c) (plist-get c :name))
                             (append (alist-get :columns info) nil))))
      (should (equal ["id"] (alist-get :primary-key info)))
      (should (plist-get (aref (alist-get :columns info) 0) :primary-key))
      (should (member "t_n" (mapcar (lambda (i) (plist-get i :name))
                                    (append (alist-get :indexes info) nil)))))

    (let ((info (cmacs-dbexplorer-tests--call
                 #'cmacs-dbexplorer--table-info-async handle nil "child")))
      (should (equal "t" (plist-get (aref (alist-get :foreign-keys info) 0)
                                    :references))))

    ;; A table that is not there is a reply carrying an error, not a
    ;; signal: it is something the database said.
    (let ((info (cmacs-dbexplorer-tests--call
                 #'cmacs-dbexplorer--table-info-async handle nil "nope")))
      (should (or (alist-get :error info)
                  (equal [] (alist-get :columns info)))))))

(ert-deftest cmacs-dbexplorer-c-export ()
  "An export writes the rows to the file and reports that it finished."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES ('a,b')")
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (n) VALUES ('c')")
    (let ((file (make-temp-file "cmacs-dbexplorer-export" nil ".csv")))
      (unwind-protect
          (progn
            (setq cmacs-dbexplorer-tests--events nil)
            (cmacs-dbexplorer--set-stream-callback
             #'cmacs-dbexplorer-tests--collect)
            (let ((id (cmacs-dbexplorer--export-async
                       handle "SELECT id, n FROM t ORDER BY id"
                       "csv" file nil)))
              (cmacs-dbexplorer-tests--wait
               (lambda () (cmacs-dbexplorer-tests--terminated-p id))
               "the export to finish")
              (let ((events (cmacs-dbexplorer-tests--events-for id)))
                (should (eq :end (car (car (last events)))))
                ;; Rows go to the file, not to the views: publishing them
                ;; twice would be a result nobody asked to see.
                (should-not (seq-find (lambda (p) (eq :rows (car p))) events))
                (should (seq-find (lambda (p) (eq :progress (car p))) events))))
            (let ((text (with-temp-buffer (insert-file-contents file)
                                          (buffer-string))))
              (should (string-match-p "id,n" text))
              ;; A value holding the separator is quoted, not corrupted.
              (should (string-match-p "\"a,b\"" text))))
        (ignore-errors (delete-file file)))
      ;; An unknown format is refused, and says so as a stream error
      ;; rather than by writing a file nobody can read.
      (setq cmacs-dbexplorer-tests--events nil)
      (let ((id (cmacs-dbexplorer--export-async
                 handle "SELECT 1" "parquet" file nil)))
        (cmacs-dbexplorer-tests--wait
         (lambda () (cmacs-dbexplorer-tests--terminated-p id))
         "the refused export to report")
        (should (eq :error (car (cmacs-dbexplorer-tests--terminated-p id))))))))

;;;; Export through the C streamer -------------------------------------

;; `cmacs-dbexplorer-run-export' is the only export path that does not
;; pull every row into Emacs first, so these check the thing that makes
;; it worth having: the file on disk, and the fact that the caller is
;; told what happened.

(defun cmacs-dbexplorer-tests--connection-for (handle)
  "Wrap a raw C HANDLE in the struct the Elisp layer passes around.

The C tests deal in handles because that is what the DEFUNs take, while
`cmacs-dbexplorer-run-export' takes a connection so it can name it in
the events it emits.  This bridges the two without opening a second
connection to the same database."
  (cmacs-dbexplorer-connection-create
   :name (format "ert-%s" handle) :handle handle :state 'idle
   :dialect "SQLite"))

(defun cmacs-dbexplorer-tests--export-temp (suffix)
  "Return a temporary file name ending in SUFFIX, deleted if it exists."
  (let ((path (make-temp-file "cmacs-dbexplorer-export-" nil suffix)))
    (delete-file path)
    path))

(defun cmacs-dbexplorer-tests--run-export (handle sql format path &rest options)
  "Export SQL to PATH through the C streamer and return its summary."
  (let ((summary nil) (failure nil))
    (cmacs-dbexplorer-run-export
     (cmacs-dbexplorer-tests--connection-for handle) sql format path
     :options options
     :on-done (lambda (s) (setq summary s))
     :on-error (lambda (m) (setq failure m)))
    (cmacs-dbexplorer-tests--wait (lambda () (or summary failure))
                                  (format "export to %s" path))
    (when failure (ert-fail (format "export failed: %s" failure)))
    summary))

(ert-deftest cmacs-dbexplorer-c-export-writes-a-file ()
  "An export streams rows to disk and reports how many it wrote."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec
     handle "INSERT INTO t (id, n) VALUES (1,'one'),(2,'two'),(3,'three')")
    (let ((path (cmacs-dbexplorer-tests--export-temp ".csv")))
      (unwind-protect
          (let ((summary (cmacs-dbexplorer-tests--run-export
                          handle "SELECT id, n FROM t ORDER BY id" "csv" path
                          :header t)))
            (should (file-exists-p path))
            (should (eq 3 (plist-get summary :row-count)))
            (should (equal path (plist-get summary :path)))
            (let ((text (with-temp-buffer
                          (insert-file-contents path) (buffer-string))))
              ;; Header first, then the rows in order.
              (should (string-match-p "\\`id,n" text))
              (should (string-match-p "1,one" text))
              (should (string-match-p "3,three" text))))
        (ignore-errors (delete-file path))))))

(ert-deftest cmacs-dbexplorer-c-export-json ()
  "The json format is accepted and produces parseable output."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec handle "INSERT INTO t (id, n) VALUES (1,'one')")
    (let ((path (cmacs-dbexplorer-tests--export-temp ".json")))
      (unwind-protect
          (progn
            (cmacs-dbexplorer-tests--run-export
             handle "SELECT id, n FROM t" "json" path)
            (should (file-exists-p path))
            (let ((parsed (with-temp-buffer
                            (insert-file-contents path)
                            (json-parse-buffer :array-type 'list))))
              (should (listp parsed))
              (should (= 1 (length parsed)))))
        (ignore-errors (delete-file path))))))

(ert-deftest cmacs-dbexplorer-c-export-reports-failure ()
  "A statement that cannot run reports an error rather than a summary.

Without the stream being registered this is exactly the case that used
to pass in silence: the terminating event arrived for an id nobody was
listening to, and the caller saw a successful-looking nothing."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (let ((path (cmacs-dbexplorer-tests--export-temp ".csv"))
          (summary nil) (failure nil))
      (unwind-protect
          (progn
            (cmacs-dbexplorer-run-export
             (cmacs-dbexplorer-tests--connection-for handle)
             "SELECT * FROM no_such_table" "csv" path
             :on-done (lambda (s) (setq summary s))
             :on-error (lambda (m) (setq failure m)))
            (cmacs-dbexplorer-tests--wait (lambda () (or summary failure))
                                          "the failing export to report")
            (should failure)
            (should-not summary))
        (ignore-errors (delete-file path))))))

(ert-deftest cmacs-dbexplorer-c-export-honours-max-rows ()
  "An export stops at :max-rows and says the output was truncated."
  (skip-unless (cmacs-dbexplorer-tests--c-p))
  (cmacs-dbexplorer-tests--with-db handle
    (cmacs-dbexplorer-tests--exec
     handle "INSERT INTO t (id, n) VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d')")
    (let ((path (cmacs-dbexplorer-tests--export-temp ".csv")))
      (unwind-protect
          (let ((summary (cmacs-dbexplorer-tests--run-export
                          handle "SELECT id FROM t ORDER BY id" "csv" path
                          :max-rows 2)))
            (should (eq 2 (plist-get summary :row-count))))
        (ignore-errors (delete-file path))))))

;;;; Schema tree: opening the obvious schema ---------------------------

;; No database and no C: the choice of which schema to open is a decision
;; over a list of names, so it is tested as one.

(defun cmacs-dbexplorer-tests--schema-ui-p ()
  "Non-nil when the schema tree loaded."
  (require 'cmacs-dbexplorer-schema-ui nil t)
  (featurep 'cmacs-dbexplorer-schema-ui))

(defmacro cmacs-dbexplorer-tests--with-tree (schemas &rest body)
  "Run BODY in a schema-tree buffer whose schema list is SCHEMAS."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (setq-local cmacs-dbexplorer-schema--schemas ,schemas)
     (setq-local cmacs-dbexplorer-schema--expanded
                 (make-hash-table :test 'equal))
     ,@body))

(ert-deftest cmacs-dbexplorer-tree-opens-the-only-schema ()
  "A connection with one schema opens it, whatever it is called."
  (skip-unless (cmacs-dbexplorer-tests--schema-ui-p))
  (cmacs-dbexplorer-tests--with-tree '("weird_name")
    (should (equal "weird_name" (cmacs-dbexplorer-schema--default-schema)))
    (cmacs-dbexplorer-schema--auto-expand)
    (should (cmacs-dbexplorer-schema--expanded-p
             (cmacs-dbexplorer-schema--node-id "weird_name")))))

(ert-deftest cmacs-dbexplorer-tree-opens-the-schemaless-node ()
  "SQLite's nil stand-in schema is opened like any other sole schema.

The nil node is exactly the case a naive `if the answer is nil, do
nothing' guard would drop, leaving SQLite -- which has no schemas at all
-- as the one dialect whose tables stay hidden."
  (skip-unless (cmacs-dbexplorer-tests--schema-ui-p))
  (cmacs-dbexplorer-tests--with-tree (list nil)
    (cmacs-dbexplorer-schema--auto-expand)
    (should (cmacs-dbexplorer-schema--expanded-p
             (cmacs-dbexplorer-schema--node-id nil)))))

(ert-deftest cmacs-dbexplorer-tree-picks-the-default-of-many ()
  "With several schemas only a conventionally-default name is opened."
  (skip-unless (cmacs-dbexplorer-tests--schema-ui-p))
  (cmacs-dbexplorer-tests--with-tree '("audit" "public" "staging")
    (cmacs-dbexplorer-schema--auto-expand)
    (should (cmacs-dbexplorer-schema--expanded-p
             (cmacs-dbexplorer-schema--node-id "public")))
    (should-not (cmacs-dbexplorer-schema--expanded-p
                 (cmacs-dbexplorer-schema--node-id "audit")))
    (should-not (cmacs-dbexplorer-schema--expanded-p
                 (cmacs-dbexplorer-schema--node-id "staging")))))

(ert-deftest cmacs-dbexplorer-tree-opens-nothing-when-ambiguous ()
  "Several schemas and no conventional name means none is opened."
  (skip-unless (cmacs-dbexplorer-tests--schema-ui-p))
  (cmacs-dbexplorer-tests--with-tree '("audit" "staging")
    (should-not (cmacs-dbexplorer-schema--default-schema))
    (cmacs-dbexplorer-schema--auto-expand)
    (should (zerop (hash-table-count cmacs-dbexplorer-schema--expanded)))))

(ert-deftest cmacs-dbexplorer-tree-respects-a-closed-schema ()
  "Closing the default schema and refreshing leaves it closed.

The guard is the emptiness of the expansion set, so anything the user has
touched -- including a different node entirely -- stops this reaching in
and reopening what they closed."
  (skip-unless (cmacs-dbexplorer-tests--schema-ui-p))
  (cmacs-dbexplorer-tests--with-tree '("public")
    (puthash (cmacs-dbexplorer-schema--node-id "public" "t") t
             cmacs-dbexplorer-schema--expanded)
    (cmacs-dbexplorer-schema--auto-expand)
    (should-not (cmacs-dbexplorer-schema--expanded-p
                 (cmacs-dbexplorer-schema--node-id "public")))))

(ert-deftest cmacs-dbexplorer-tree-auto-expand-is-optional ()
  "Setting the defcustom to nil leaves the tree fully closed."
  (skip-unless (cmacs-dbexplorer-tests--schema-ui-p))
  (cmacs-dbexplorer-tests--with-tree '("public")
    (let ((cmacs-dbexplorer-schema-auto-expand nil))
      (cmacs-dbexplorer-schema--auto-expand))
    (should (zerop (hash-table-count cmacs-dbexplorer-schema--expanded)))))

;;;; The SQL buffer's two workhorse keys -------------------------------

(defun cmacs-dbexplorer-tests--sql-p ()
  "Non-nil when the SQL buffer loaded."
  (require 'cmacs-dbexplorer-sql nil t)
  (featurep 'cmacs-dbexplorer-sql))

(ert-deftest cmacs-dbexplorer-sql-keys-survive-the-parent-mode ()
  "C-c C-c runs and C-c C-k stops, over whatever `sql-mode' binds.

The mode derives from `sql-mode', which binds C-c C-c to
`sql-send-paragraph' -- a command that would look like it worked and send
the statement to a comint buffer that is not our connection."
  (skip-unless (cmacs-dbexplorer-tests--sql-p))
  (with-temp-buffer
    (cmacs-dbexplorer-sql-mode)
    (should (eq (key-binding (kbd "C-c C-c"))
                #'cmacs-dbexplorer-sql-send-dwim))
    (should (eq (key-binding (kbd "C-c C-k"))
                #'cmacs-dbexplorer-sql-cancel))
    (should (eq (key-binding (kbd "C-c C-b"))
                #'cmacs-dbexplorer-sql-send-buffer))))

(ert-deftest cmacs-dbexplorer-sql-cancel-closes-when-idle ()
  "With nothing running, C-c C-k puts the buffer away."
  (skip-unless (cmacs-dbexplorer-tests--sql-p))
  (with-temp-buffer
    (cmacs-dbexplorer-sql-mode)
    (setq cmacs-dbexplorer-sql--stream nil)
    (let ((quit nil))
      (cl-letf (((symbol-function 'cmacs-dbexplorer-quit)
                 (lambda () (setq quit t))))
        (cmacs-dbexplorer-sql-cancel))
      (should quit))))

(ert-deftest cmacs-dbexplorer-sql-cancel-cancels-when-running ()
  "With a statement in flight, C-c C-k cancels it and does not close."
  (skip-unless (cmacs-dbexplorer-tests--sql-p))
  (with-temp-buffer
    (cmacs-dbexplorer-sql-mode)
    (setq cmacs-dbexplorer-sql--stream 4242)
    (let ((quit nil) (cancelled nil))
      (cl-letf (((symbol-function 'cmacs-dbexplorer-quit)
                 (lambda () (setq quit t)))
                ((symbol-function 'cmacs-dbexplorer-cancel)
                 (lambda (id) (setq cancelled id))))
        (cmacs-dbexplorer-sql-cancel))
      (should (eq 4242 cancelled))
      (should-not quit)
      (should-not cmacs-dbexplorer-sql--stream))))

(ert-deftest cmacs-dbexplorer-sql-forgets-a-finished-statement ()
  "A statement that finishes leaves nothing to cancel.

The regression this pins: the stream id was recorded when a query started
and cleared only by cancelling it, so from the first successful query
onwards the buffer claimed to be running one forever -- and C-c C-k spent
the rest of the session cancelling a stream that had already ended
instead of closing the buffer."
  (skip-unless (cmacs-dbexplorer-tests--sql-p))
  (with-temp-buffer
    (cmacs-dbexplorer-sql-mode)
    (setq cmacs-dbexplorer-sql--stream 99)
    (cmacs-dbexplorer-sql--forget-stream (current-buffer))
    (should-not cmacs-dbexplorer-sql--stream)))

(ert-deftest cmacs-dbexplorer-sql-forget-tolerates-a-dead-buffer ()
  "A reply landing after its buffer is gone is not an error.

Both terminal callbacks close over the buffer, and a query outliving the
buffer that started it is ordinary rather than exceptional."
  (skip-unless (cmacs-dbexplorer-tests--sql-p))
  (let ((buffer (generate-new-buffer " *dbexplorer-sql-test*")))
    (kill-buffer buffer)
    (should-not (cmacs-dbexplorer-sql--forget-stream buffer))))

(provide 'cmacs-dbexplorer-tests)
;;; cmacs-dbexplorer-tests.el ends here
