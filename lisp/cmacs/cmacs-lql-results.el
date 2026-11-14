;;; cmacs-lql-results.el --- Grid buffers for LQL query results  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: data, tools
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; One results buffer per query: a sortable grid (`tabulated-list-mode')
;; of whatever a query returned, whichever engine ran it -- the LQL
;; linked into cmacs (`local'), a libresearch server (`libresearch'), or
;; a caller-supplied function.  It is meant for combing through rows:
;;
;;   RET   visit what the row names (a file and line, a URL, a buffer,
;;         an org ID) -- `cmacs-lql-results-visit-functions' decides
;;   v     the whole row as a record
;;   /     narrow: add `| filter EXPR' and re-run against the source
;;   R     refine locally: run LQL over the rows shown, no refetch
;;   e     edit the query and re-run         g  re-run
;;   m u U mark, unmark, unmark all          w W  copy cell / row
;;   E     export (org table, CSV, JSON)     x  explain the plan
;;   t     switch target (local/libresearch) c  hide or show a column
;;
;; Derived modes (the libresearch results buffer) reuse all of it and
;; add their own keys.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'cmacs-lql)

(declare-function cmacs-evil-setup-mode-map "cmacs-evil" (map mode &optional states))
(declare-function cmacs-ai-research-request "cmacs-ai-research" (kind arg callback &rest options))
(declare-function cmacs-ai-research-payload-document "cmacs-ai-research" (payload))
(declare-function cmacs-gsurf-open "cmacs-gsurf" (url &rest _))
(declare-function org-id-goto "org-id" (id))

(defgroup cmacs-lql-results nil
  "Grid buffers for LQL query results."
  :group 'cmacs-lql
  :prefix "cmacs-lql-results-")

(defcustom cmacs-lql-results-max-column-width 60
  "Widest a results column is drawn; longer cells are truncated."
  :type 'natnum)

(defcustom cmacs-lql-results-null-string "·"
  "How a NULL cell is drawn."
  :type 'string)

(defcustom cmacs-lql-results-visit-functions
  '(cmacs-lql-results-visit-file
    cmacs-lql-results-visit-url
    cmacs-lql-results-visit-buffer
    cmacs-lql-results-visit-org-id)
  "Functions RET tries on a row, in order, until one returns non-nil.
Each takes the row as an alist of (COLUMN-NAME . VALUE) with string
names.  Add your own to make RET understand a new kind of row."
  :type 'hook)

(defcustom cmacs-lql-results-url-function
  (lambda (url) (if (fboundp 'cmacs-gsurf-open) (cmacs-gsurf-open url) (browse-url url)))
  "Function RET calls with a row's URL."
  :type 'function)

(defface cmacs-lql-results-null '((t :inherit shadow))
  "Face of NULL cells.")

(defface cmacs-lql-results-number '((t :inherit font-lock-constant-face))
  "Face of numeric cells.")

(defface cmacs-lql-results-mark '((t :inherit dired-marked))
  "Face of marked rows.")

;;;; Buffer state

(defvar-local cmacs-lql-results--query nil "The query this buffer shows.")
(defvar-local cmacs-lql-results--target 'local
  "Where the query runs: `local', `libresearch', or a function.
A function is called with the query and a callback taking the parsed
table plist (or (:error MSG)).")
(defvar-local cmacs-lql-results--columns nil "((NAME . TYPE) ...).")
(defvar-local cmacs-lql-results--rows nil "List of row vectors.")
(defvar-local cmacs-lql-results--rowvec [] "The rows as a vector, by id.")
(defvar-local cmacs-lql-results--total nil "Rows the query produced.")
(defvar-local cmacs-lql-results--elapsed nil "Seconds the run took.")
(defvar-local cmacs-lql-results--status nil "Status line text.")
(defvar-local cmacs-lql-results--request nil "Pending local request id.")
(defvar-local cmacs-lql-results--hidden nil "Hidden column names.")
(defvar-local cmacs-lql-results--marks nil "Marked row indices.")
(defvar-local cmacs-lql-results--parent nil
  "For a locally refined buffer: (COLUMNS . ROWS) it was refined from.")

;;;; Cells

(defun cmacs-lql-results--jsonable (value)
  "VALUE as something `json-serialize' takes.
Parsed JSON arrives with arrays as lists and objects as plists; both
are turned back into what the serializer wants."
  (cond ((and (consp value) (keywordp (car value)))
         (cl-loop for (k v) on value by #'cddr
                  collect (cons (intern (substring (symbol-name k) 1))
                                (cmacs-lql-results--jsonable v))))
        ((and (consp value) (consp (car value)) (symbolp (caar value)))
         (mapcar (lambda (p) (cons (car p) (cmacs-lql-results--jsonable (cdr p)))) value))
        ((listp value) (if (null value) :null
                         (vconcat (mapcar #'cmacs-lql-results--jsonable value))))
        ((vectorp value) (vconcat (mapcar #'cmacs-lql-results--jsonable value)))
        (t value)))

(defun cmacs-lql-results--cell-string (value)
  "VALUE as the text of one grid cell."
  (cond
   ((null value) (propertize cmacs-lql-results-null-string
                             'face 'cmacs-lql-results-null))
   ((eq value t) "true")
   ((eq value :false) "false")
   ((numberp value) (propertize (number-to-string value)
                                'face 'cmacs-lql-results-number))
   ((stringp value) (replace-regexp-in-string "[\n\r\t]+" " " value))
   ((and (consp value) (cl-every #'atom value) (not (keywordp (car value))))
    ;; A list of scalars (engines, tags): the common case reads best plain.
    (mapconcat (lambda (v) (format "%s" v)) value ", "))
   (t (replace-regexp-in-string
       "[\n\r]+" " "
       (json-serialize (cmacs-lql-results--jsonable value)
                       :null-object :null :false-object :false)))))

(defun cmacs-lql-results--sort-key (value)
  "VALUE as something `cmacs-lql-results--sorter' compares."
  (cond ((numberp value) value)
        ((null value) "")
        (t (cmacs-lql-results--cell-string value))))

(defun cmacs-lql-results--sorter (index)
  "A `tabulated-list' sort predicate for column INDEX.
Entries carry only the drawn cells, so the full row -- and the typed
value, not its text -- is found by the entry's id."
  (lambda (a b)
    (let ((x (cmacs-lql-results--sort-key
              (aref (aref cmacs-lql-results--rowvec (car a)) index)))
          (y (cmacs-lql-results--sort-key
              (aref (aref cmacs-lql-results--rowvec (car b)) index))))
      (cond ((and (numberp x) (numberp y)) (< x y))
            ((numberp x) t)
            ((numberp y) nil)
            (t (string< x y))))))

;;;; Rendering

(defun cmacs-lql-results--visible-indices ()
  "Indices of the columns not hidden."
  (cl-loop for c in cmacs-lql-results--columns for i from 0
           unless (member (car c) cmacs-lql-results--hidden) collect i))

(defun cmacs-lql-results--width (index)
  "Display width of column INDEX."
  (min cmacs-lql-results-max-column-width
       (max 3 (string-width (car (nth index cmacs-lql-results--columns)))
            (cl-loop for row in cmacs-lql-results--rows
                     maximize (string-width
                               (cmacs-lql-results--cell-string (aref row index)))))))

(defun cmacs-lql-results--render ()
  "Redraw the grid from the buffer's columns and rows."
  (let ((visible (cmacs-lql-results--visible-indices)))
    (setq cmacs-lql-results--rowvec (vconcat cmacs-lql-results--rows))
    (setq tabulated-list-format
          (vconcat
           (mapcar (lambda (i)
                     (let ((name (car (nth i cmacs-lql-results--columns))))
                       (list name (cmacs-lql-results--width i)
                             (cmacs-lql-results--sorter i)
                             :right-align (member (cdr (nth i cmacs-lql-results--columns))
                                                  '("Int" "Double" "Duration")))))
                   visible)))
    (setq tabulated-list-entries
          (cl-loop for row in cmacs-lql-results--rows for n from 0
                   collect (list n
                                 (vconcat
                                  (mapcar (lambda (i)
                                            (let ((s (cmacs-lql-results--cell-string
                                                      (aref row i))))
                                              (if (memq n cmacs-lql-results--marks)
                                                  (propertize s 'face 'cmacs-lql-results-mark)
                                                s)))
                                          visible)))))
    (setq tabulated-list-padding 2)
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (save-excursion
      (dolist (n cmacs-lql-results--marks)
        (goto-char (point-min))
        (while (and (not (eobp)) (not (eql (tabulated-list-get-id) n)))
          (forward-line 1))
        (unless (eobp) (tabulated-list-put-tag "*"))))
    (cmacs-lql-results--update-mode-line)))

(defun cmacs-lql-results--update-mode-line ()
  "Show the row count, timing and target in the mode line."
  (setq mode-line-process
        (list (format " [%s%s%s]"
                      (cond (cmacs-lql-results--status)
                            (t (format "%d%s rows"
                                       (length cmacs-lql-results--rows)
                                       (if (and cmacs-lql-results--total
                                                (> cmacs-lql-results--total
                                                   (length cmacs-lql-results--rows)))
                                           (format "/%d" cmacs-lql-results--total)
                                         ""))))
                      (if cmacs-lql-results--elapsed
                          (format " %.2fs" cmacs-lql-results--elapsed) "")
                      (if (eq cmacs-lql-results--target 'local) ""
                        (format " @%s" cmacs-lql-results--target)))))
  (force-mode-line-update))

;;;; Mode

(defvar-keymap cmacs-lql-results-mode-map
  :doc "Keymap for `cmacs-lql-results-mode'."
  :parent tabulated-list-mode-map
  "RET" #'cmacs-lql-results-visit
  "v"   #'cmacs-lql-results-show-row
  "/"   #'cmacs-lql-results-narrow
  "R"   #'cmacs-lql-results-refine
  "e"   #'cmacs-lql-results-edit-query
  "g"   #'cmacs-lql-results-rerun
  "m"   #'cmacs-lql-results-mark
  "u"   #'cmacs-lql-results-unmark
  "U"   #'cmacs-lql-results-unmark-all
  "w"   #'cmacs-lql-results-copy-cell
  "W"   #'cmacs-lql-results-copy-row
  "E"   #'cmacs-lql-results-export
  "x"   #'cmacs-lql-results-explain
  "t"   #'cmacs-lql-results-toggle-target
  "c"   #'cmacs-lql-results-toggle-column
  "C-c C-k" #'cmacs-lql-results-cancel)

(define-derived-mode cmacs-lql-results-mode tabulated-list-mode "LQL"
  "Major mode for LQL query results.

\\{cmacs-lql-results-mode-map}"
  :group 'cmacs-lql-results
  (setq-local revert-buffer-function
              (lambda (&rest _) (cmacs-lql-results-rerun)))
  (setq-local tabulated-list-sort-key nil)
  (setq truncate-lines t)
  (hl-line-mode 1))

(with-eval-after-load 'cmacs-evil
  (cmacs-evil-setup-mode-map cmacs-lql-results-mode-map 'cmacs-lql-results-mode))

;;;; Showing results

(defun cmacs-lql-results--buffer-name (query)
  "Buffer name for QUERY."
  (format "*LQL: %s*" (truncate-string-to-width
                       (replace-regexp-in-string "[ \t\n]+" " " query) 60 nil nil "…")))

(defun cmacs-lql-results--libresearch-table (payload)
  "Parse a libresearch LQL PAYLOAD into the table plist, or (:error MSG)."
  (require 'cmacs-ai-research)
  (pcase (car payload)
    (:ok
     (let* ((doc (cmacs-ai-research-payload-document payload))
            (cols (mapcar (lambda (c) (cons (plist-get c :name)
                                            (or (plist-get c :type) "Any")))
                          (plist-get doc :columns)))
            (keys (mapcar (lambda (c) (intern (concat ":" (car c)))) cols)))
       (if (plist-get doc :explain)
           (list :error (concat "plan:\n" (plist-get doc :explain)))
         (list :columns cols
               :rows (mapcar (lambda (r) (vconcat (mapcar (lambda (k) (plist-get r k)) keys)))
                             (plist-get doc :rows))
               :total (length (plist-get doc :rows))))))
    (:error payload)
    (_ (list :error "cancelled"))))

(defun cmacs-lql-results--start (buffer)
  "Run BUFFER's query against its target, filling BUFFER when done."
  (with-current-buffer buffer
    (let ((query cmacs-lql-results--query)
          (target cmacs-lql-results--target))
      (setq cmacs-lql-results--status "running…")
      (cmacs-lql-results--update-mode-line)
      (cond
       ((eq target 'local)
        (setq cmacs-lql-results--request
              (cmacs-lql-run query
                             (lambda (payload)
                               (when (buffer-live-p buffer)
                                 (with-current-buffer buffer
                                   (setq cmacs-lql-results--request nil)
                                   (cmacs-lql-results--fill
                                    (if (eq (car payload) :ok)
                                        (append (cmacs-lql-payload-table payload)
                                                (list :elapsed (plist-get (cdr payload) :elapsed)))
                                      (if (eq (car payload) :error) payload
                                        (list :error "cancelled"))))))))))
       ((eq target 'libresearch)
        (require 'cmacs-ai-research)
        (let ((started (float-time)))
          (cmacs-ai-research-request
           'lql query
           (lambda (payload)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (let ((table (cmacs-lql-results--libresearch-table payload)))
                   (cmacs-lql-results--fill
                    (if (eq (car table) :error) table
                      (append table (list :elapsed (- (float-time) started))))))))))))
       ((functionp target)
        (funcall target query
                 (lambda (table)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (cmacs-lql-results--fill table))))))
       (t (error "cmacs-lql: unknown target %S" target))))))

(defun cmacs-lql-results--fill (table)
  "Fill the current results buffer from TABLE, or report its error."
  (if (eq (car table) :error)
      (progn
        (setq cmacs-lql-results--status "error")
        (cmacs-lql-results--update-mode-line)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (propertize (format "%s\n\n" cmacs-lql-results--query) 'face 'shadow)
                  (propertize (format "%s\n" (cadr table)) 'face 'error)
                  (substitute-command-keys
                   "\n\\[cmacs-lql-results-edit-query] edit the query, \
\\[cmacs-lql-results-rerun] run it again.\n")))
        (message "LQL: %s" (cadr table)))
    (setq cmacs-lql-results--status nil
          cmacs-lql-results--columns (plist-get table :columns)
          cmacs-lql-results--rows (plist-get table :rows)
          cmacs-lql-results--total (plist-get table :total)
          cmacs-lql-results--elapsed (plist-get table :elapsed)
          cmacs-lql-results--marks nil)
    (cmacs-lql-results--render)
    (goto-char (point-min))))

;;;###autoload
(cl-defun cmacs-lql-results--loading (query &key (target 'local) buffer mode parent)
  "Open a results buffer for QUERY and run it against TARGET.
BUFFER reuses an existing buffer, MODE is the major mode (a mode
derived from `cmacs-lql-results-mode'), PARENT the (COLUMNS . ROWS) a
local refinement reads.  Returns the buffer."
  (let ((buf (or buffer (get-buffer-create (cmacs-lql-results--buffer-name query)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-lql-results-mode)
        (funcall (or mode #'cmacs-lql-results-mode)))
      (setq cmacs-lql-results--query query
            cmacs-lql-results--target target
            cmacs-lql-results--hidden nil
            cmacs-lql-results--parent parent))
    (pop-to-buffer buf)
    (cmacs-lql-results--start buf)
    buf))

;;;###autoload
(cl-defun cmacs-lql-results-show (query table &key (target 'local) mode buffer)
  "Show TABLE, already computed for QUERY, in a results buffer.
TABLE is (:columns ((NAME . TYPE)...) :rows (VECTOR...) :total N).
Returns the buffer."
  (let ((buf (or buffer (get-buffer-create (cmacs-lql-results--buffer-name query)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-lql-results-mode)
        (funcall (or mode #'cmacs-lql-results-mode)))
      (setq cmacs-lql-results--query query
            cmacs-lql-results--target target)
      (cmacs-lql-results--fill table))
    (pop-to-buffer buf)
    buf))

;;;; Rows

(defun cmacs-lql-results-row-at-point ()
  "The row at point as an alist of (COLUMN-NAME . VALUE), or nil."
  (when-let* ((entry (tabulated-list-get-entry))
              (id (tabulated-list-get-id))
              (row (nth id cmacs-lql-results--rows)))
    (cl-loop for c in cmacs-lql-results--columns for i from 0
             collect (cons (car c) (aref row i)))))

(defun cmacs-lql-results--row-or-error ()
  "The row at point, or a `user-error'."
  (or (cmacs-lql-results-row-at-point) (user-error "No row at point")))

(defun cmacs-lql-results--value (row &rest names)
  "The first non-empty value in ROW among column NAMES."
  (cl-loop for n in names
           for v = (cdr (assoc n row))
           when (and v (not (eq v :false)) (not (equal v "")))
           return v))

(defun cmacs-lql-results-visit-file (row)
  "Visit the file ROW names (file/path/filename), at its line if it has one."
  (when-let* ((file (cmacs-lql-results--value row "file" "path" "filename" "file_name")))
    (when (and (stringp file) (or (file-remote-p file) (file-exists-p file)))
      (find-file-other-window file)
      (when-let* ((line (cmacs-lql-results--value row "line" "line_number" "lineno")))
        (when (numberp line)
          (goto-char (point-min))
          (forward-line (1- line))))
      t)))

(defun cmacs-lql-results-visit-url (row)
  "Open the URL ROW names (url/link/href/uri)."
  (when-let* ((url (cmacs-lql-results--value row "url" "link" "href" "uri")))
    (when (and (stringp url) (string-match-p "\\`[a-z][a-z0-9+.-]*://" url))
      (funcall cmacs-lql-results-url-function url)
      t)))

(defun cmacs-lql-results-visit-buffer (row)
  "Switch to the buffer ROW names (buffer/name of a live buffer)."
  (when-let* ((name (cmacs-lql-results--value row "buffer" "name")))
    (when-let* ((buf (and (stringp name) (get-buffer name))))
      (pop-to-buffer buf)
      t)))

(defun cmacs-lql-results-visit-org-id (row)
  "Go to the org entry whose ID ROW carries."
  (when-let* ((id (cmacs-lql-results--value row "id" "org_id")))
    (when (and (stringp id) (require 'org-id nil t))
      (condition-case nil (progn (org-id-goto id) t) (error nil)))))

(defun cmacs-lql-results-visit ()
  "Visit what the row at point names; else show the row."
  (interactive)
  (let ((row (cmacs-lql-results--row-or-error)))
    (unless (run-hook-with-args-until-success 'cmacs-lql-results-visit-functions row)
      (cmacs-lql-results-show-row))))

(defun cmacs-lql-results-show-row ()
  "Show the row at point as a record, one field per line."
  (interactive)
  (let ((row (cmacs-lql-results--row-or-error))
        (width 0))
    (dolist (f row) (setq width (max width (string-width (car f)))))
    (with-help-window "*LQL row*"
      (with-current-buffer standard-output
        (dolist (f row)
          (insert (propertize (string-pad (car f) width) 'face 'font-lock-property-name-face)
                  "  "
                  (let ((v (cdr f)))
                    (if (stringp v) v (cmacs-lql-results--cell-string v)))
                  "\n"))))))

;;;; Query editing

(defun cmacs-lql-results-rerun ()
  "Run this buffer's query again."
  (interactive)
  (if cmacs-lql-results--parent
      (cmacs-lql-results--refine-run (current-buffer))
    (cmacs-lql-results--start (current-buffer))))

(defun cmacs-lql-results-cancel ()
  "Cancel the query this buffer is waiting for."
  (interactive)
  (when cmacs-lql-results--request
    (cmacs-lql--cancel cmacs-lql-results--request)))

(defun cmacs-lql-results-edit-query (query)
  "Replace this buffer's query with QUERY and run it."
  (interactive (list (read-string "LQL: " cmacs-lql-results--query 'cmacs-lql-history)))
  (setq cmacs-lql-results--query query)
  (rename-buffer (cmacs-lql-results--buffer-name query) t)
  (cmacs-lql-results-rerun))

(defun cmacs-lql-results-narrow (expr)
  "Add `| filter EXPR' to the query and run it again."
  (interactive
   (list (read-string "filter: "
                      (when-let* ((row (cmacs-lql-results-row-at-point))
                                  (col (cmacs-lql-results--column-at-point)))
                        (let ((v (cdr (assoc col row))))
                          (format "%s == %s" col
                                  (if (stringp v) (prin1-to-string v)
                                    (cmacs-lql-results--cell-string v))))))))
  (cmacs-lql-results-edit-query
   (format "%s\n| filter %s" (string-trim-right cmacs-lql-results--query) expr)))

(defun cmacs-lql-results--column-at-point ()
  "Name of the column at point, or nil."
  (when-let* ((name (get-text-property (point) 'tabulated-list-column-name)))
    name))

(defun cmacs-lql-results-toggle-target ()
  "Switch where this buffer's query runs, local or libresearch, and re-run."
  (interactive)
  (setq cmacs-lql-results--target
        (if (eq cmacs-lql-results--target 'local) 'libresearch 'local))
  (cmacs-lql-results-rerun))

(defun cmacs-lql-results-explain ()
  "Show the plan for this buffer's query (local target)."
  (interactive)
  (let ((plan (condition-case err (cmacs-lql--explain cmacs-lql-results--query)
                (cmacs-lql-busy (user-error "A query is running; try again"))
                (cmacs-lql-error (user-error "%s" (cadr err))))))
    (with-help-window "*LQL plan*"
      (princ cmacs-lql-results--query) (princ "\n\n") (princ plan))))

;;;; Local refinement: LQL over the rows already here

(defun cmacs-lql-results--refine-run (buffer)
  "Run BUFFER's query over its parent rows (the `results' source)."
  (with-current-buffer buffer
    (let ((cols (car cmacs-lql-results--parent))
          (rows (cdr cmacs-lql-results--parent)))
      (cmacs-lql-define-source
       "results"
       (mapcar (lambda (c)
                 (list (car c)
                       (or (car (rassoc (cdr c) cmacs-lql--types)) 'any)))
               cols)
       (lambda ()
         (mapcar (lambda (row)
                   (cl-loop for c in cols for i from 0
                            collect (cons (car c) (aref row i))))
                 rows))
       "The rows of the results buffer being refined.")
      (cmacs-lql-results--start buffer))))

(defun cmacs-lql-results-refine (pipeline)
  "Run LQL PIPELINE over the rows shown here, in a new buffer.
The rows become the source `results', so PIPELINE is what follows
`fetch results' -- e.g. \"filter engine == \\\"brave\\\" | sort score DESC\".
Nothing is fetched again."
  (interactive (list (read-string "fetch results | ")))
  (cmacs-lql--ensure)
  (let* ((parent (cons cmacs-lql-results--columns cmacs-lql-results--rows))
         (query (format "fetch results | %s" pipeline))
         (buf (get-buffer-create (cmacs-lql-results--buffer-name query))))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-lql-results-mode)
        (cmacs-lql-results-mode))
      (setq cmacs-lql-results--query query
            cmacs-lql-results--target 'local
            cmacs-lql-results--parent parent))
    (pop-to-buffer buf)
    (cmacs-lql-results--refine-run buf)
    buf))

;;;; Marks, copying, columns

(defun cmacs-lql-results-mark ()
  "Mark the row at point and move down."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (cl-pushnew id cmacs-lql-results--marks)
    (tabulated-list-put-tag "*" t)))

(defun cmacs-lql-results-unmark ()
  "Unmark the row at point and move down."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (setq cmacs-lql-results--marks (delq id cmacs-lql-results--marks))
    (tabulated-list-put-tag " " t)))

(defun cmacs-lql-results-unmark-all ()
  "Unmark every row."
  (interactive)
  (setq cmacs-lql-results--marks nil)
  (cmacs-lql-results--render))

(defun cmacs-lql-results-marked-rows ()
  "The marked rows as alists, else the row at point as a one-item list."
  (if cmacs-lql-results--marks
      (cl-loop for n in (sort (copy-sequence cmacs-lql-results--marks) #'<)
               for row = (nth n cmacs-lql-results--rows)
               collect (cl-loop for c in cmacs-lql-results--columns for i from 0
                                collect (cons (car c) (aref row i))))
    (list (cmacs-lql-results--row-or-error))))

(defun cmacs-lql-results-copy-cell ()
  "Copy the cell at point."
  (interactive)
  (let* ((row (cmacs-lql-results--row-or-error))
         (col (or (cmacs-lql-results--column-at-point) (caar row)))
         (v (cdr (assoc col row)))
         (s (if (stringp v) v (cmacs-lql-results--cell-string v))))
    (kill-new (substring-no-properties s))
    (message "Copied %s" (truncate-string-to-width s 60 nil nil "…"))))

(defun cmacs-lql-results--row-json (row)
  "ROW (an alist) as a JSON object string."
  (json-serialize (mapcar (lambda (f) (cons (intern (car f))
                                           (if (cdr f) (cmacs-lql-results--jsonable (cdr f)) :null)))
                          row)
                  :null-object :null :false-object :false))

(defun cmacs-lql-results-copy-row ()
  "Copy the marked rows (or the row at point) as JSON."
  (interactive)
  (let ((rows (cmacs-lql-results-marked-rows)))
    (kill-new (if (cdr rows)
                  (concat "[" (mapconcat #'cmacs-lql-results--row-json rows ",") "]")
                (cmacs-lql-results--row-json (car rows))))
    (message "Copied %d row%s as JSON" (length rows) (if (cdr rows) "s" ""))))

(defun cmacs-lql-results-toggle-column (name)
  "Hide column NAME, or show it again if hidden."
  (interactive
   (list (completing-read "Toggle column: "
                          (mapcar #'car cmacs-lql-results--columns) nil t
                          (cmacs-lql-results--column-at-point))))
  (setq cmacs-lql-results--hidden
        (if (member name cmacs-lql-results--hidden)
            (delete name cmacs-lql-results--hidden)
          (cons name cmacs-lql-results--hidden)))
  (cmacs-lql-results--render))

;;;; Export

(defun cmacs-lql-results--org-cell (value)
  "VALUE as an org table cell."
  (replace-regexp-in-string
   "|" "\\\\vert{}"
   (substring-no-properties
    (if (null value) "" (if (stringp value) value
                          (cmacs-lql-results--cell-string value))))))

(defun cmacs-lql-results-org-table (&optional rows)
  "The results (or ROWS, a list of alists) as an org table string."
  (let ((rows (or rows
                  (mapcar (lambda (row)
                            (cl-loop for c in cmacs-lql-results--columns for i from 0
                                     collect (cons (car c) (aref row i))))
                          cmacs-lql-results--rows))))
    (concat "| " (mapconcat #'car cmacs-lql-results--columns " | ") " |\n|-\n"
            (mapconcat (lambda (row)
                         (concat "| " (mapconcat (lambda (f) (cmacs-lql-results--org-cell (cdr f)))
                                                 row " | ")
                                 " |"))
                       rows "\n")
            "\n")))

(defun cmacs-lql-results--csv ()
  "The results as CSV."
  (let ((field (lambda (v)
                 (let ((s (substring-no-properties
                           (if (null v) "" (if (stringp v) v (cmacs-lql-results--cell-string v))))))
                   (if (string-match-p "[,\"\n]" s)
                       (concat "\"" (string-replace "\"" "\"\"" s) "\"")
                     s)))))
    (concat (mapconcat (lambda (c) (funcall field (car c))) cmacs-lql-results--columns ",")
            "\n"
            (mapconcat (lambda (row) (mapconcat field (append row nil) ","))
                       cmacs-lql-results--rows "\n")
            "\n")))

(defun cmacs-lql-results-export (format destination)
  "Export the results as FORMAT (org, csv or json) to DESTINATION.
DESTINATION is `kill' (the kill ring), `buffer' (a new buffer), or a
file name."
  (interactive
   (let ((fmt (intern (completing-read "Export as: " '("org" "csv" "json") nil t))))
     (list fmt
           (pcase (read-char-choice "To: (k)ill ring, (b)uffer, (f)ile? " '(?k ?b ?f))
             (?k 'kill) (?b 'buffer)
             (?f (read-file-name "Export to file: " nil nil nil
                                 (format "lql-results.%s" fmt)))))))
  (let ((text (pcase format
                ('org (cmacs-lql-results-org-table))
                ('csv (cmacs-lql-results--csv))
                ('json (concat "["
                               (mapconcat
                                (lambda (row)
                                  (cmacs-lql-results--row-json
                                   (cl-loop for c in cmacs-lql-results--columns for i from 0
                                            collect (cons (car c) (aref row i)))))
                                cmacs-lql-results--rows ",\n")
                               "]\n"))
                (_ (user-error "Unknown export format %s" format))))
        (query cmacs-lql-results--query))
    (pcase destination
      ('kill (kill-new text) (message "Results copied as %s" format))
      ('buffer
       (with-current-buffer (generate-new-buffer (format "*LQL %s*" format))
         (insert (if (eq format 'org) (format "#+caption: %s\n" query) "") text)
         (pcase format
           ('org (when (fboundp 'org-mode) (org-mode)))
           ('json (when (fboundp 'js-json-mode) (js-json-mode))))
         (goto-char (point-min))
         (pop-to-buffer (current-buffer))))
      ((pred stringp)
       (with-temp-file destination (insert text))
       (message "Wrote %s" destination)))))

(provide 'cmacs-lql-results)

;;; cmacs-lql-results.el ends here
