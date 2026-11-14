;;; cmacs-lql-repl.el --- An interactive LQL REPL  -*- lexical-binding: t; -*-

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

;; `M-x cmacs-lql-repl': a comint buffer that evaluates LQL in the
;; linked liblql (or on a libresearch server, `:target libresearch').
;;
;; - Queries run asynchronously on the LQL worker; the prompt comes back
;;   when the rows do, and typing never waits on a slow source.
;; - RET sends when the query is complete; a line ending in `|' or `,'
;;   continues it, as does C-j.
;; - TAB completes from liblql's own assist code (sources, commands,
;;   functions, columns -- cmacs's editor sources included); eldoc shows
;;   the signature of the call at point.
;; - Every table prints as aligned text with a [grid] button that opens
;;   it in a results buffer to sort, filter and export.
;; - Colon commands: type :help.
;;
;; Like crispy's REPL it runs no subprocess of its own: a `cat' process
;; carries comint's state and `comint-input-sender' evaluates in-process.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'comint)
(require 'cmacs-lql)

(declare-function cmacs-lql-results-show "cmacs-lql-results" (query table &rest props))
(declare-function cmacs-lql-results--libresearch-table "cmacs-lql-results" (payload))
(declare-function cmacs-ai-research-request "cmacs-ai-research" (kind arg callback &rest options))

(defgroup cmacs-lql-repl nil
  "The LQL REPL."
  :group 'cmacs-lql
  :prefix "cmacs-lql-repl-")

(defcustom cmacs-lql-repl-buffer-name "*LQL*"
  "Name of the LQL REPL buffer."
  :type 'string)

(defcustom cmacs-lql-repl-prompt "lql> "
  "The LQL REPL prompt."
  :type 'string)

(defcustom cmacs-lql-repl-max-rows 200
  "Most rows the REPL prints; the [grid] button has them all."
  :type 'natnum)

(defface cmacs-lql-repl-meta '((t :inherit shadow))
  "Face of the row count and timing after a result.")

(defvar-local cmacs-lql-repl--target 'local
  "Where the REPL runs queries: `local' or `libresearch'.")
(defvar-local cmacs-lql-repl--last nil
  "(QUERY . TABLE) of the last result, for :grid.")
(defvar-local cmacs-lql-repl--pending nil
  "Id of the local request the REPL is waiting for.")

;;;; Output

(defun cmacs-lql-repl--send-output (buffer string)
  "Insert STRING and a fresh prompt into REPL BUFFER via comint."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((proc (get-buffer-process buffer)))
        (when proc
          (comint-output-filter
           proc
           (concat string
                   (if (or (string-empty-p string) (string-suffix-p "\n" string)) "" "\n")
                   cmacs-lql-repl-prompt)))))))

(defun cmacs-lql-repl--grid-button (buffer query table)
  "A [grid] button opening TABLE for QUERY, from REPL BUFFER."
  (ignore buffer)
  (let ((s (copy-sequence "[grid]")))
    (make-text-button s nil
                      'action (lambda (_)
                                (require 'cmacs-lql-results)
                                (cmacs-lql-results-show query table))
                      'help-echo "Open these rows in a results grid"
                      'follow-link t)
    s))

(defun cmacs-lql-repl--text-table (table max-rows)
  "TABLE (the parsed plist) as aligned text, at most MAX-ROWS rows."
  (let* ((cols (plist-get table :columns))
         (rows (seq-take (plist-get table :rows) max-rows))
         (cell (lambda (v) (cond ((null v) "null") ((eq v t) "true")
                                 ((eq v :false) "false")
                                 ((stringp v) (replace-regexp-in-string "\n" " " v))
                                 ((numberp v) (number-to-string v))
                                 (t (json-serialize v :null-object nil :false-object :false)))))
         (widths (cl-loop for c in cols for i from 0
                          collect (min 50 (apply #'max (string-width (car c))
                                                 (mapcar (lambda (r) (string-width (funcall cell (aref r i))))
                                                         rows))))))
    (mapconcat
     #'identity
     (append
      (list (mapconcat (lambda (p) (string-pad (car p) (cdr p)))
                       (cl-mapcar #'cons (mapcar #'car cols) widths) "  ")
            (mapconcat (lambda (w) (make-string w ?─)) widths "  "))
      (mapcar (lambda (r)
                (string-trim-right
                 (mapconcat #'identity
                            (cl-loop for w in widths for i from 0
                                     collect (string-pad (truncate-string-to-width
                                                          (funcall cell (aref r i)) w nil nil "…")
                                                         w))
                            "  ")))
              rows))
     "\n")))

(defun cmacs-lql-repl--report (buffer query table text elapsed)
  "Print TABLE for QUERY in REPL BUFFER (TEXT is a pre-rendered table)."
  (let* ((shown (min (length (plist-get table :rows)) cmacs-lql-repl-max-rows))
         (total (or (plist-get table :total) shown)))
    (with-current-buffer buffer
      (setq cmacs-lql-repl--last (cons query table)))
    (cmacs-lql-repl--send-output
     buffer
     (concat (string-trim-right (or text (cmacs-lql-repl--text-table table cmacs-lql-repl-max-rows)))
             "\n"
             (propertize (format "(%d row%s%s%s) " total (if (= total 1) "" "s")
                                 (if (< shown total) (format ", %d shown" shown) "")
                                 (if elapsed (format ", %.3fs" elapsed) ""))
                         'face 'cmacs-lql-repl-meta)
             (cmacs-lql-repl--grid-button buffer query table)
             "\n"))))

;;;; Evaluation

(defun cmacs-lql-repl--eval (buffer query)
  "Run QUERY for REPL BUFFER; print the result when it arrives."
  (let ((target (buffer-local-value 'cmacs-lql-repl--target buffer))
        (width (max 40 (- (or (let ((w (get-buffer-window buffer)))
                                 (and w (window-width w)))
                               100)
                           2))))
    (if (eq target 'libresearch)
        (progn
          (require 'cmacs-lql-results)
          (let ((started (float-time)))
            (cmacs-ai-research-request
             'lql query
             (lambda (payload)
               (let ((table (cmacs-lql-results--libresearch-table payload)))
                 (if (eq (car table) :error)
                     (cmacs-lql-repl--send-output
                      buffer (propertize (format "error: %s" (cadr table)) 'face 'error))
                   (cmacs-lql-repl--report buffer query table nil
                                           (- (float-time) started))))))))
      (with-current-buffer buffer
        (setq cmacs-lql-repl--pending
              (cmacs-lql-run
               query
               (lambda (payload)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer (setq cmacs-lql-repl--pending nil)))
                 (pcase (car payload)
                   (:ok (cmacs-lql-repl--report
                         buffer query (cmacs-lql-payload-table payload)
                         (and (<= (plist-get (cdr payload) :rows) cmacs-lql-repl-max-rows)
                              (plist-get (cdr payload) :text))
                         (plist-get (cdr payload) :elapsed)))
                   (:error (cmacs-lql-repl--send-output
                            buffer (propertize (format "error: %s" (cadr payload))
                                               'face 'error)))
                   (_ (cmacs-lql-repl--send-output buffer "cancelled"))))
               :text-width width))))))

;;;; Colon commands

(defconst cmacs-lql-repl-commands
  '((":help" "show this help")
    (":sources" "list every source (cmacs's editor sources included)")
    (":explain" "QUERY -- show the plan instead of running it")
    (":format" "QUERY -- show QUERY formatted")
    (":describe" "write the environment file the language server reads")
    (":target" "local|libresearch -- where queries run")
    (":grid" "open the last result in a results grid")
    (":clear" "clear the buffer"))
  "The REPL's colon commands.")

(defun cmacs-lql-repl--command (buffer input)
  "Run colon command INPUT in REPL BUFFER; return text to print."
  (let* ((parts (split-string input "[ \t]+" t))
         (cmd (car parts))
         (arg (string-trim (substring input (length cmd)))))
    (condition-case err
        (pcase cmd
          (":help"
           (mapconcat (lambda (c) (format "  %-10s %s" (car c) (cadr c)))
                      cmacs-lql-repl-commands "\n"))
          (":sources" (string-join (cmacs-lql--sources) "  "))
          (":explain" (cmacs-lql--explain arg))
          (":format" (cmacs-lql--format arg))
          (":describe" (format "wrote %s" (cmacs-lql-write-environment)))
          (":target"
           (let ((tgt (intern (if (string-empty-p arg) "local" arg))))
             (unless (memq tgt '(local libresearch))
               (user-error "target is local or libresearch"))
             (with-current-buffer buffer (setq cmacs-lql-repl--target tgt))
             (format "target: %s" tgt)))
          (":grid"
           (let ((last (buffer-local-value 'cmacs-lql-repl--last buffer)))
             (unless last (user-error "no result yet"))
             (require 'cmacs-lql-results)
             (cmacs-lql-results-show (car last) (cdr last))
             ""))
          (":clear"
           (with-current-buffer buffer
             (let ((inhibit-read-only t)) (erase-buffer)))
           "")
          (_ (format "unknown command %s (try :help)" cmd)))
      (cmacs-lql-busy "busy: a query is running")
      (error (propertize (format "error: %s" (error-message-string err)) 'face 'error)))))

(defun cmacs-lql-repl--input-sender (proc input)
  "Evaluate INPUT for the REPL whose dummy process is PROC."
  (let ((buffer (process-buffer proc))
        (input (string-trim input)))
    (cond
     ((string-empty-p input) (cmacs-lql-repl--send-output buffer ""))
     ((string-prefix-p ":" input)
      (cmacs-lql-repl--send-output buffer (cmacs-lql-repl--command buffer input)))
     (t (cmacs-lql-repl--eval buffer input)))))

;;;; Input

(defun cmacs-lql-repl--input ()
  "The text of the current input."
  (buffer-substring-no-properties
   (process-mark (get-buffer-process (current-buffer))) (point-max)))

(defun cmacs-lql-repl-return ()
  "Send the input, unless it plainly continues on the next line."
  (interactive)
  (let ((input (string-trim-right (cmacs-lql-repl--input))))
    (if (and (> (point) (process-mark (get-buffer-process (current-buffer))))
             (string-match-p "[|,(]\\'" input))
        (insert "\n")
      (comint-send-input))))

(defun cmacs-lql-repl-newline ()
  "Insert a newline without sending."
  (interactive)
  (insert "\n"))

(defun cmacs-lql-repl-cancel ()
  "Cancel the query the REPL is waiting for."
  (interactive)
  (when cmacs-lql-repl--pending
    (cmacs-lql--cancel cmacs-lql-repl--pending)))

(defun cmacs-lql-repl--capf ()
  "Complete LQL at point in the REPL input, from liblql's assist code."
  (let* ((proc (get-buffer-process (current-buffer)))
         (start (and proc (marker-position (process-mark proc)))))
    (when (and start (>= (point) start))
      (let* ((text (buffer-substring-no-properties start (point-max)))
             (pos (- (point) start)))
        (if (string-prefix-p ":" text)
            (when (< pos (or (string-search " " text) (length text)))
              (list start (+ start (or (string-search " " text) (length text)))
                    (mapcar #'car cmacs-lql-repl-commands)))
          (when-let* ((cands (cmacs-lql-completions text pos)))
            (let ((beg (+ start (nth 4 (car cands))))
                  (end (+ start (nth 5 (car cands)))))
              (list beg (max end (point))
                    (mapcar (lambda (c)
                              (propertize (nth 0 c) 'cmacs-lql-kind (nth 1 c)
                                          'cmacs-lql-detail (nth 2 c)
                                          'cmacs-lql-doc (nth 3 c)))
                            cands)
                    :exclusive 'no
                    :annotation-function
                    (lambda (c) (concat " " (or (get-text-property 0 'cmacs-lql-kind c) "")))
                    :company-docsig
                    (lambda (c) (get-text-property 0 'cmacs-lql-detail c))
                    :company-doc-buffer
                    (lambda (c)
                      (when-let* ((doc (get-text-property 0 'cmacs-lql-doc c)))
                        (with-current-buffer (get-buffer-create " *lql-doc*")
                          (erase-buffer) (insert doc) (current-buffer))))))))))))

(defun cmacs-lql-repl--eldoc (callback &rest _)
  "Report the signature of the LQL call at point to eldoc's CALLBACK."
  (let* ((proc (get-buffer-process (current-buffer)))
         (start (and proc (marker-position (process-mark proc)))))
    (when (and start (>= (point) start))
      (let ((sig (cmacs-lql-signature-text
                  (buffer-substring-no-properties start (point-max))
                  (- (point) start))))
        (when sig (funcall callback sig))))))

;;;; Mode

(defvar-keymap cmacs-lql-repl-mode-map
  :doc "Keymap for `cmacs-lql-repl-mode'."
  :parent comint-mode-map
  "RET"     #'cmacs-lql-repl-return
  "M-RET"   #'comint-send-input
  "C-j"     #'cmacs-lql-repl-newline
  "TAB"     #'completion-at-point
  "C-c C-k" #'cmacs-lql-repl-cancel
  "C-c C-z" #'bury-buffer)

(define-derived-mode cmacs-lql-repl-mode comint-mode "LQL-REPL"
  "Major mode for the LQL REPL.

\\{cmacs-lql-repl-mode-map}"
  :group 'cmacs-lql-repl
  (setq-local comint-prompt-regexp (concat "^" (regexp-quote cmacs-lql-repl-prompt)))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'cmacs-lql-repl--input-sender)
  (setq-local comint-process-echoes nil)
  (setq-local comment-start "# ")
  (when (cmacs-lql--load-lql-mode)
    (setq-local font-lock-defaults
                (list (symbol-value 'lql-font-lock-keywords))))
  (add-hook 'completion-at-point-functions #'cmacs-lql-repl--capf nil t)
  (add-hook 'eldoc-documentation-functions #'cmacs-lql-repl--eldoc nil t)
  (eldoc-mode 1))

;;;###autoload
(defun cmacs-lql-repl ()
  "Open (or switch to) the LQL REPL."
  (interactive)
  (cmacs-lql--ensure)
  (let ((buf (get-buffer-create cmacs-lql-repl-buffer-name)))
    (unless (comint-check-proc buf)
      (with-current-buffer buf
        (let ((proc (start-process "cmacs-lql-repl" buf "cat")))
          (set-process-query-on-exit-flag proc nil)
          (cmacs-lql-repl-mode)
          (insert
           (propertize
            (format "LQL %s in cmacs -- sources: files, git, exec, journal, sql, k8s, \
and the editor (%s).\nRET runs a complete query; a line ending in | continues.  \
TAB completes.  :help for commands.\n\n"
                    (cmacs-lql--version)
                    (string-join (cmacs-lql-source-names) ", "))
            'font-lock-face 'font-lock-comment-face))
          (set-marker (process-mark proc) (point))
          (cmacs-lql-repl--send-output buf ""))))
    (pop-to-buffer buf)))

(provide 'cmacs-lql-repl)

;;; cmacs-lql-repl.el ends here
