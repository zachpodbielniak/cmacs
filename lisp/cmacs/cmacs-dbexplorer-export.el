;;; cmacs-dbexplorer-export.el --- Writing results out  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Getting rows out of the explorer and into a file.
;;
;; Two paths, and the difference matters.  The exporters registered here
;; write the result the grid is *showing* -- one page, in Lisp, instantly,
;; with no database involved.  That is what "export this table" usually
;; means, and it is what the transient defaults to.  The server-side
;; export runs the statement again through C and streams the whole answer
;; to a file, which is the only way to write out something larger than a
;; page and is correspondingly slower.
;;
;; Exporters are registry entries with the contract the model documents:
;; `:label', `:run' called with the result and a path, an optional
;; `:extension'.  The header switch reaches them through a dynamic
;; variable rather than a fourth argument, so a user-written exporter
;; implementing the two-argument contract keeps working and can consult
;; the switch if it has an opinion about headers.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'transient)
(require 'cmacs-dbexplorer)
(require 'cmacs-dbexplorer-grid)

(declare-function cmacs-dbexplorer-run-export "cmacs-dbexplorer"
                  (connection sql format path &rest keys))
(declare-function cmacs-dbexplorer--export-async
                  "src/cmacs-dbexplorer-defuns.c" (handle sql format path options))

(defvar cmacs-dbexplorer-export-header t
  "Whether the running exporter should write a header row.

Bound around `:run' rather than passed to it, so the registry contract
stays the two-argument one the model documents.")


;;;; Shipped exporters --------------------------------------------------

(defun cmacs-dbexplorer-export--text (cell)
  "Return CELL as plain text, with NULL as the empty string.

A NULL and an empty string are genuinely different, and CSV cannot say
so; the file format is the limitation, not the choice.  JSON can, and
does."
  (if (eq cell :null) "" (cmacs-dbexplorer-cell-display cell)))

(defun cmacs-dbexplorer-export--csv-field (cell)
  "Return CELL quoted as a CSV field when it needs to be."
  (let ((text (cmacs-dbexplorer-export--text cell)))
    (if (string-match-p "[\",\n\r]" text)
        (concat "\"" (replace-regexp-in-string "\"" "\"\"" text) "\"")
      text)))

(defun cmacs-dbexplorer-export-csv (result path)
  "Write RESULT to PATH as CSV."
  (with-temp-file path
    (when cmacs-dbexplorer-export-header
      (insert (mapconcat #'cmacs-dbexplorer-export--csv-field
                         (cmacs-dbexplorer-result-column-names result) ",")
              "\n"))
    (dotimes (row (cmacs-dbexplorer-result-row-count result))
      (insert (mapconcat #'cmacs-dbexplorer-export--csv-field
                         (append (aref (cmacs-dbexplorer-result-rows result) row)
                                 nil)
                         ",")
              "\n"))))

(defun cmacs-dbexplorer-export-json (result path)
  "Write RESULT to PATH as an array of JSON objects.

Hash tables rather than alists because `json-serialize' takes string keys
from a hash table without argument, and a column called `type' is not
something to convert into a symbol and hope."
  (let ((names (cmacs-dbexplorer-result-column-names result))
        (rows nil))
    (dotimes (row (cmacs-dbexplorer-result-row-count result))
      (let ((object (make-hash-table :test 'equal))
            (cells (aref (cmacs-dbexplorer-result-rows result) row))
            (index 0))
        (dolist (name names)
          (let ((cell (and (< index (length cells)) (aref cells index))))
            ;; `:null' is `json-serialize's own null object, so a SQL
            ;; NULL comes out as JSON null rather than as "".
            (puthash name (if (eq cell :null) :null
                            (cmacs-dbexplorer-cell-display cell))
                     object))
          (setq index (1+ index)))
        (push object rows)))
    (with-temp-file path
      (insert (json-serialize (vconcat (nreverse rows))) "\n"))))

(defun cmacs-dbexplorer-export--org-field (cell)
  "Return CELL as an org table field, with pipes escaped."
  (replace-regexp-in-string
   "|" "\\\\vert{}" (cmacs-dbexplorer-export--text cell)))

(defun cmacs-dbexplorer-export-org (result path)
  "Write RESULT to PATH as an org table."
  (with-temp-file path
    (when cmacs-dbexplorer-export-header
      (insert "| " (mapconcat #'cmacs-dbexplorer-export--org-field
                              (cmacs-dbexplorer-result-column-names result)
                              " | ")
              " |\n|---\n"))
    (dotimes (row (cmacs-dbexplorer-result-row-count result))
      (insert "| " (mapconcat #'cmacs-dbexplorer-export--org-field
                              (append (aref (cmacs-dbexplorer-result-rows result)
                                            row)
                                      nil)
                              " | ")
              " |\n"))))

(cmacs-dbexplorer-register-exporter
 'csv :label "CSV" :extension "csv" :run #'cmacs-dbexplorer-export-csv)
(cmacs-dbexplorer-register-exporter
 'json :label "JSON" :extension "json" :run #'cmacs-dbexplorer-export-json)
(cmacs-dbexplorer-register-exporter
 'org :label "Org table" :extension "org" :run #'cmacs-dbexplorer-export-org)


;;;; Running an export --------------------------------------------------

(defun cmacs-dbexplorer-export-result (result path format &optional header)
  "Write RESULT to PATH in FORMAT, including a header row when HEADER.

FORMAT is a registered exporter's name."
  (let ((exporter (cmacs-dbexplorer-exporter format)))
    (unless exporter
      (user-error "cmacs-dbexplorer: no exporter called %s" format))
    (let ((cmacs-dbexplorer-export-header header))
      (funcall (plist-get exporter :run) result (expand-file-name path)))
    path))

(defun cmacs-dbexplorer-export--names ()
  "Return every registered exporter's name, as strings."
  (mapcar (lambda (entry) (symbol-name (car entry)))
          (cmacs-dbexplorer-exporters)))

(defun cmacs-dbexplorer-export--default-path (format)
  "Return a default file name for FORMAT."
  (let* ((exporter (cmacs-dbexplorer-exporter (intern format)))
         (extension (or (plist-get exporter :extension) format))
         (source cmacs-dbexplorer-grid--source)
         (base (or (plist-get source :table) "result")))
    (expand-file-name (format "%s.%s" base extension) default-directory)))


;;;; The menu -----------------------------------------------------------

(transient-define-infix cmacs-dbexplorer-export--format-infix ()
  "The export format."
  :class 'transient-option
  :argument "--format="
  :description "format"
  :always-read t
  :choices (lambda (&rest _) (cmacs-dbexplorer-export--names)))

(transient-define-infix cmacs-dbexplorer-export--file-infix ()
  "Where to write it."
  :class 'transient-option
  :argument "--file="
  :description "file"
  :always-read t
  :reader (lambda (prompt initial _history)
            (read-file-name prompt nil nil nil initial)))

;;;###autoload (autoload 'cmacs-dbexplorer-export-menu "cmacs-dbexplorer-export" nil t)
(transient-define-prefix cmacs-dbexplorer-export-menu ()
  "Write these rows to a file."
  :value '("--format=csv" "--header")
  ["Export"
   ("f" cmacs-dbexplorer-export--format-infix)
   ("o" cmacs-dbexplorer-export--file-infix)
   ("h" "write a header row" "--header")]
  ["Act"
   ("x" "write this page" cmacs-dbexplorer-export-run)
   ("S" "write the whole query (runs it again)"
    cmacs-dbexplorer-export-run-server)])

(defun cmacs-dbexplorer-export-run (&optional arguments)
  "Write the grid's current page out, as ARGUMENTS describe."
  (interactive (list (transient-args 'cmacs-dbexplorer-export-menu)))
  (let* ((format (or (transient-arg-value "--format=" arguments) "csv"))
         (path (or (transient-arg-value "--file=" arguments)
                   (cmacs-dbexplorer-export--default-path format))))
    (cmacs-dbexplorer-export-result (cmacs-dbexplorer-grid-result) path
                                    (intern format)
                                    (and (member "--header" arguments) t))
    (message "cmacs-dbexplorer: wrote %s" (abbreviate-file-name path))))

(defun cmacs-dbexplorer-export-run-server (&optional arguments)
  "Re-run the statement through C and stream every row to a file.

The only way to export more than the page on screen, and the reason it is
a separate key: it runs the query again, which on a large table is not
the instant operation the other one is."
  (interactive (list (transient-args 'cmacs-dbexplorer-export-menu)))
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--export-async)
  (let* ((format (or (transient-arg-value "--format=" arguments) "csv"))
         (path (or (transient-arg-value "--file=" arguments)
                   (cmacs-dbexplorer-export--default-path format)))
         (sql (cmacs-dbexplorer-grid-sql))
         (connection (cmacs-dbexplorer-buffer-connection-or-error)))
    (unless sql (user-error "cmacs-dbexplorer: no statement to export"))
    (cmacs-dbexplorer-run-export
     connection sql format path
     :options (list :header (and (member "--header" arguments) t))
     :on-done (lambda (summary)
                (message "cmacs-dbexplorer: wrote %s rows to %s"
                         (plist-get summary :row-count)
                         (abbreviate-file-name (plist-get summary :path))))
     :on-error (lambda (message)
                 (message "cmacs-dbexplorer: export failed: %s" message)))
    (message "cmacs-dbexplorer: exporting to %s..." (abbreviate-file-name path))))

(provide 'cmacs-dbexplorer-export)
;;; cmacs-dbexplorer-export.el ends here
