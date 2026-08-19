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

(provide 'cmacs-dbexplorer-tests)
;;; cmacs-dbexplorer-tests.el ends here
