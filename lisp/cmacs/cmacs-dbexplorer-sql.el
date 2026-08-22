;;; cmacs-dbexplorer-sql.el --- The SQL editor  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A buffer you write SQL in, which happens to know where to send it.
;;
;; It derives from `sql-mode', not from `special-mode', and that is the
;; whole design.  `special-mode' makes a buffer read-only, and -- worse --
;; Evil gives its derivatives normal state, where the letters of the
;; statement you meant to type are motions and operators.  A buffer whose
;; entire purpose is typing must open ready to type, which is why it also
;; asks Evil for insert state, the same call eshell, vterm and a commit
;; message get.  Deriving from `sql-mode' also means the indentation, the
;; syntax table and the font-lock are the ones the rest of Emacs already
;; agreed on, rather than a second dialect of the same thing.
;;
;; For the same reason every binding is under `C-c'.  A single-letter key
;; in a buffer you type into is a key you cannot type, and the explorer's
;; other buffers -- which are read-only, and where single letters are
;; right -- are already where the single-letter vocabulary lives.
;;
;; History is per connection and survives a restart.  The useful unit of
;; recall is "that query I ran against staging", and a shared ring mixes
;; it with the one that was written for a different schema entirely.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'sql)
(require 'cmacs-dbexplorer)

(declare-function cmacs-dbexplorer-grid-show "cmacs-dbexplorer-grid"
                  (result &optional source connection))
(declare-function cmacs-dbexplorer-grid-buffer-name "cmacs-dbexplorer-grid"
                  (connection-name))
(declare-function cmacs-dbexplorer-schema "cmacs-dbexplorer-schema-ui"
                  (&optional connection))
(declare-function evil-set-initial-state "evil-core" (mode state))


;;;; Customization ------------------------------------------------------

(defcustom cmacs-dbexplorer-sql-history-size 200
  "How many statements are remembered per connection."
  :type 'integer
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-sql-history-file
  (locate-user-emacs-file "cmacs-dbexplorer-history.eld")
  "Where statement history is kept between sessions."
  :type 'file
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-sql-query-directory
  (locate-user-emacs-file "dbexplorer-queries/")
  "Where `cmacs-dbexplorer-sql-save-query' offers to write statements."
  :type 'directory
  :group 'cmacs-dbexplorer)


;;;; History ------------------------------------------------------------

(defvar cmacs-dbexplorer-sql--history nil
  "Alist of connection name to statements, newest first.")

(defvar cmacs-dbexplorer-sql--history-loaded nil
  "Non-nil once the history file has been read.")

(defun cmacs-dbexplorer-sql--history-load ()
  "Read the history file, once."
  (unless cmacs-dbexplorer-sql--history-loaded
    (setq cmacs-dbexplorer-sql--history-loaded t)
    (when (file-readable-p cmacs-dbexplorer-sql-history-file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents cmacs-dbexplorer-sql-history-file)
            (goto-char (point-min))
            (let ((data (read (current-buffer))))
              (when (listp data) (setq cmacs-dbexplorer-sql--history data))))
        ;; A corrupt history is an inconvenience, not a reason to refuse
        ;; to open a SQL buffer.
        (error (message "cmacs-dbexplorer: history unreadable: %s"
                        (error-message-string err)))))))

(defun cmacs-dbexplorer-sql--history-save ()
  "Write the history file."
  (when cmacs-dbexplorer-sql--history
    (condition-case err
        (let ((directory (file-name-directory
                          cmacs-dbexplorer-sql-history-file)))
          (when directory (make-directory directory t))
          (with-temp-file cmacs-dbexplorer-sql-history-file
            (let ((print-length nil) (print-level nil))
              (prin1 cmacs-dbexplorer-sql--history (current-buffer))
              (insert "\n"))))
      (error (message "cmacs-dbexplorer: history unwritable: %s"
                      (error-message-string err))))))

(defun cmacs-dbexplorer-sql--history-add (name sql)
  "Remember that SQL was run on the connection called NAME."
  (cmacs-dbexplorer-sql--history-load)
  (let* ((key (or name "?"))
         (entries (delete sql (alist-get key cmacs-dbexplorer-sql--history
                                         nil nil #'equal))))
    (setf (alist-get key cmacs-dbexplorer-sql--history nil nil #'equal)
          (seq-take (cons sql entries) cmacs-dbexplorer-sql-history-size))
    (cmacs-dbexplorer-sql--history-save)))

(defun cmacs-dbexplorer-sql-history ()
  "Insert a statement run earlier on this connection."
  (interactive)
  (cmacs-dbexplorer-sql--history-load)
  (let ((entries (alist-get (or cmacs-dbexplorer--connection-name "?")
                            cmacs-dbexplorer-sql--history nil nil #'equal)))
    (unless entries
      (user-error "cmacs-dbexplorer: nothing has been run on this connection"))
    (insert
     (completing-read
      "Statement: "
      ;; The table is consulted in order, and `completing-read' keeps it,
      ;; so newest-first stays newest-first however the completion UI
      ;; sorts equal candidates.
      (lambda (string predicate action)
        (if (eq action 'metadata)
            '(metadata (display-sort-function . identity)
                       (cycle-sort-function . identity))
          (complete-with-action action entries string predicate)))
      nil t))))

(add-hook 'kill-emacs-hook #'cmacs-dbexplorer-sql--history-save)


;;;; The statement at point ---------------------------------------------

(defun cmacs-dbexplorer-sql--terminators ()
  "Return the positions of every statement-ending semicolon.

Semicolons inside a string or a comment are not terminators, which is
what `syntax-ppss' is asked about; without the check, a statement holding
a literal like \\='a;b\\=' splits in the middle."
  (save-excursion
    (goto-char (point-min))
    (let ((out nil))
      (while (search-forward ";" nil t)
        (unless (nth 8 (syntax-ppss))
          (push (point) out)))
      (nreverse out))))

(defun cmacs-dbexplorer-sql--statement-bounds ()
  "Return the bounds of the statement point is in, as (START . END)."
  (let ((here (point))
        (start (point-min))
        (end (point-max)))
    (dolist (position (cmacs-dbexplorer-sql--terminators))
      (cond ((<= position here) (setq start position))
            ((> position here) (setq end (min end position)))))
    (cons start end)))

(defun cmacs-dbexplorer-sql-statement ()
  "Return the statement at point, without its terminator."
  (let* ((bounds (cmacs-dbexplorer-sql--statement-bounds))
         (text (string-trim (buffer-substring-no-properties
                             (car bounds) (cdr bounds)))))
    (setq text (string-trim (string-remove-suffix ";" text)))
    (when (string-empty-p text)
      (user-error "cmacs-dbexplorer: no statement at point"))
    text))

(defun cmacs-dbexplorer-sql--returns-rows-p (sql)
  "Return non-nil when SQL is the kind of statement that answers with rows.

A guess, and a cheap one: the difference decides which of two reports the
user gets, and the wrong guess costs a message rather than a row."
  (string-match-p
   "\\`[[:space:](]*\\(select\\|with\\|explain\\|show\\|pragma\\|values\\|desc\\)"
   (downcase sql)))


;;;; Running ------------------------------------------------------------

(defun cmacs-dbexplorer-sql--connection ()
  "Return this buffer's connection, asking for one if it has none."
  (unless cmacs-dbexplorer--connection-name
    (setq cmacs-dbexplorer--connection-name
          (cmacs-dbexplorer-read-connection-name "Run on: " t)))
  (cmacs-dbexplorer-buffer-connection-or-error))

(defvar-local cmacs-dbexplorer-sql--stream nil
  "The stream id of the statement this buffer is running, or nil.

Only ever set while a statement is actually in flight.  Both terminal
callbacks clear it, because a variable that means `something is running'
and is only ever cleared by cancelling would be a lie from the first
query onwards -- and `C-c C-k' reads it to decide whether there is
anything to cancel.")

(defun cmacs-dbexplorer-sql--forget-stream (buffer stream)
  "Record in BUFFER that STREAM is no longer running.

Cleared only when STREAM is still the one the buffer is tracking.  A
second statement sent while the first is in flight replaces the tracked
id, and the first statement's termination arriving afterwards must not
clear the second's -- that would resurrect exactly the `C-c C-k' means
nothing' failure this variable's contract exists to prevent, for the
overlapping-queries case."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eql cmacs-dbexplorer-sql--stream stream)
        (setq cmacs-dbexplorer-sql--stream nil)))))

(defun cmacs-dbexplorer-sql-send (sql)
  "Run SQL on this buffer's connection.

A statement that answers with rows goes to the grid; one that does not is
reported by how much it changed.  Either way it is remembered, and a
statement that can have changed the shape of the database drops the
schema cache -- a tree still showing a column that was just dropped is
worse than one that has to read the catalogue again."
  (interactive (list (cmacs-dbexplorer-sql-statement)))
  (let* ((connection (cmacs-dbexplorer-sql--connection))
         (name (cmacs-dbexplorer-connection-name connection)))
    (cmacs-dbexplorer-sql--history-add name sql)
    (if (cmacs-dbexplorer-sql--returns-rows-p sql)
        (let ((buffer (current-buffer))
              (stream nil))
          (require 'cmacs-dbexplorer-grid)
          ;; The callbacks close over STREAM, which is bound before the
          ;; query starts and set before any reply can be delivered --
          ;; replies only ever arrive through the event loop, never
          ;; synchronously from `cmacs-dbexplorer-query'.
          (setq stream
                (cmacs-dbexplorer-query
                 connection sql
                 :options (list :max-rows (1+ cmacs-dbexplorer-page-size))
                 :on-result
                 (lambda (result)
                   (cmacs-dbexplorer-sql--forget-stream buffer stream)
                   (cmacs-dbexplorer-grid-show
                    result (list :kind 'sql :sql sql) name))
                 :on-error
                 (lambda (message)
                   (cmacs-dbexplorer-sql--forget-stream buffer stream)
                   (message "cmacs-dbexplorer: %s" message))))
          (setq cmacs-dbexplorer-sql--stream stream)
          (message "cmacs-dbexplorer: running on %s..." name))
      (cmacs-dbexplorer-execute
       connection sql
       :on-done (lambda (reply)
                  (cmacs-dbexplorer-schema-forget connection)
                  (message "cmacs-dbexplorer: %s row(s) affected"
                           (or (alist-get :rows-affected reply) 0)))))))

(defun cmacs-dbexplorer-sql-send-dwim ()
  "Run the region when there is one, else the statement at point."
  (interactive)
  (cmacs-dbexplorer-sql-send
   (if (use-region-p)
       (string-trim (buffer-substring-no-properties
                     (region-beginning) (region-end)))
     (cmacs-dbexplorer-sql-statement))))

(defun cmacs-dbexplorer-sql-send-buffer ()
  "Run the whole buffer as one statement."
  (interactive)
  (cmacs-dbexplorer-sql-send
   (string-trim (buffer-substring-no-properties (point-min) (point-max)))))

(defun cmacs-dbexplorer-sql-explain ()
  "Ask the database how it would run the statement at point."
  (interactive)
  (cmacs-dbexplorer-sql-send (concat "EXPLAIN " (cmacs-dbexplorer-sql-statement))))

(defun cmacs-dbexplorer-sql-cancel ()
  "Stop the statement this buffer is running, or put this buffer away.

One key for `stop what I started'.  While a statement is in flight it is
the statement that stops; with nothing running there is nothing to stop
and this buffer is what you meant.

`quit-window', deliberately, and not `cmacs-dbexplorer-quit': this closes
one window and puts back whatever it was showing before.  The explorer's
own quit restores the window configuration the workbench replaced, which
from here would take down the connections list, the schema tree and the
grid too -- three windows nobody asked to close.  Leaving the SQL editor
is not leaving the explorer.

The buffer is buried and never killed, so a statement you were half-way
through writing is still there when you come back to it."
  (interactive)
  (if (null cmacs-dbexplorer-sql--stream)
      (quit-window)
    (cmacs-dbexplorer-cancel cmacs-dbexplorer-sql--stream)
    (setq cmacs-dbexplorer-sql--stream nil)
    (message "cmacs-dbexplorer: cancelled")))

;;;###autoload
(defun cmacs-dbexplorer-send-region (start end &optional connection)
  "Run the region between START and END on CONNECTION.

Autoloaded and connection-agnostic on purpose: a statement in any
`sql-mode' buffer, an org source block, a scratch file, is worth being
able to run without moving it into an explorer buffer first."
  (interactive "r")
  (cmacs-dbexplorer--require)
  (let ((sql (string-trim (buffer-substring-no-properties start end)))
        (name (or connection cmacs-dbexplorer--connection-name
                  (cmacs-dbexplorer-read-connection-name "Run on: " t))))
    (when (string-empty-p sql)
      (user-error "cmacs-dbexplorer: the region is empty"))
    (setq-local cmacs-dbexplorer--connection-name
                (if (stringp name) name
                  (cmacs-dbexplorer-connection-name name)))
    (cmacs-dbexplorer-sql-send sql)))


;;;; Transactions and navigation ----------------------------------------

(defun cmacs-dbexplorer-sql-begin ()
  "Open a transaction on this buffer's connection."
  (interactive)
  (cmacs-dbexplorer-begin (cmacs-dbexplorer-sql--connection)))

(defun cmacs-dbexplorer-sql-commit ()
  "Commit this buffer's transaction."
  (interactive)
  (cmacs-dbexplorer-commit (cmacs-dbexplorer-sql--connection)))

(defun cmacs-dbexplorer-sql-rollback (&optional savepoint)
  "Roll this buffer's transaction back, to SAVEPOINT when one is named."
  (interactive
   (list (let ((name (read-string
                      "Savepoint (empty for the whole transaction): ")))
           (unless (string-empty-p name) name))))
  (cmacs-dbexplorer-rollback (cmacs-dbexplorer-sql--connection) savepoint))

(defun cmacs-dbexplorer-sql-savepoint (name)
  "Create savepoint NAME on this buffer's connection."
  (interactive (list (read-string "Savepoint name: " "sp1")))
  (cmacs-dbexplorer-savepoint (cmacs-dbexplorer-sql--connection) name))

(defun cmacs-dbexplorer-sql-show-results ()
  "Show the grid this buffer sends its rows to."
  (interactive)
  (require 'cmacs-dbexplorer-grid)
  (let ((buffer (get-buffer (cmacs-dbexplorer-grid-buffer-name
                             (or cmacs-dbexplorer--connection-name "?")))))
    (unless buffer (user-error "cmacs-dbexplorer: no results yet"))
    (pop-to-buffer buffer)))

(defun cmacs-dbexplorer-sql-show-schema ()
  "Show the schema tree for this buffer's connection."
  (interactive)
  (require 'cmacs-dbexplorer-schema-ui)
  (cmacs-dbexplorer-schema (cmacs-dbexplorer-sql--connection)))

(defun cmacs-dbexplorer-sql-switch-connection ()
  "Point this buffer at a different connection."
  (interactive)
  (setq cmacs-dbexplorer--connection-name
        (cmacs-dbexplorer-read-connection-name "Run on: " t))
  (message "cmacs-dbexplorer: now running on %s"
           cmacs-dbexplorer--connection-name))

(defun cmacs-dbexplorer-sql-save-query (file)
  "Write the statement at point to FILE."
  (interactive
   (list (progn
           (make-directory cmacs-dbexplorer-sql-query-directory t)
           (read-file-name "Save statement to: "
                           cmacs-dbexplorer-sql-query-directory))))
  (let ((sql (if (use-region-p)
                 (buffer-substring-no-properties (region-beginning) (region-end))
               (cmacs-dbexplorer-sql-statement))))
    (with-temp-file file (insert sql "\n"))
    (message "cmacs-dbexplorer: wrote %s" (abbreviate-file-name file))))


;;;; Completion ---------------------------------------------------------

(defun cmacs-dbexplorer-sql--candidates ()
  "Return every table and column name cached for this connection.

Read from the model's schema cache, which the tree fills as it is
browsed.  Nothing is fetched here: completion that queried the catalogue
on each keystroke would make typing depend on the network."
  (let ((connection (cmacs-dbexplorer-buffer-connection))
        (names nil))
    (when connection
      (maphash
       (lambda (_key info)
         (dolist (relation (append (alist-get :relations info) nil))
           (push (format "%s" (if (plistp relation)
                                  (plist-get relation :name)
                                relation))
                 names))
         (dolist (column (append (alist-get :columns info) nil))
           (push (format "%s" (plist-get column :name)) names)))
       (cmacs-dbexplorer-connection-schema-cache connection)))
    (delete-dups names)))

(defun cmacs-dbexplorer-sql-completion-at-point ()
  "Complete a table or column name from the schema cache."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (list (car bounds) (cdr bounds)
            (completion-table-dynamic
             (lambda (_prefix) (cmacs-dbexplorer-sql--candidates)))
            :exclusive 'no))))


;;;; Mode ---------------------------------------------------------------

(defvar cmacs-dbexplorer-sql-transaction-map
  (let ((map (make-sparse-keymap)))
    (define-key map "b" #'cmacs-dbexplorer-sql-begin)
    (define-key map "c" #'cmacs-dbexplorer-sql-commit)
    (define-key map "r" #'cmacs-dbexplorer-sql-rollback)
    (define-key map "s" #'cmacs-dbexplorer-sql-savepoint)
    map)
  "Transaction keys, under `C-c t'.")

(defvar cmacs-dbexplorer-sql-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Everything under C-c.  A single-letter binding in a buffer you type
    ;; into is a letter you cannot type.
    (define-key map (kbd "C-c C-c") #'cmacs-dbexplorer-sql-send-dwim)
    (define-key map (kbd "C-c C-b") #'cmacs-dbexplorer-sql-send-buffer)
    (define-key map (kbd "C-c C-k") #'cmacs-dbexplorer-sql-cancel)
    (define-key map (kbd "C-c C-e") #'cmacs-dbexplorer-sql-explain)
    (define-key map (kbd "C-c t") cmacs-dbexplorer-sql-transaction-map)
    (define-key map (kbd "C-c C-o") #'cmacs-dbexplorer-sql-show-results)
    (define-key map (kbd "C-c C-s") #'cmacs-dbexplorer-sql-show-schema)
    (define-key map (kbd "C-c C-h") #'cmacs-dbexplorer-sql-history)
    (define-key map (kbd "C-c C-w") #'cmacs-dbexplorer-sql-switch-connection)
    (define-key map (kbd "C-c C-q") #'cmacs-dbexplorer-sql-save-query)
    map)
  "Keymap for `cmacs-dbexplorer-sql-mode'.")

(define-derived-mode cmacs-dbexplorer-sql-mode sql-mode "DB-SQL"
  "Write SQL and send it to an explorer connection.

\\{cmacs-dbexplorer-sql-mode-map}"
  (add-hook 'completion-at-point-functions
            #'cmacs-dbexplorer-sql-completion-at-point nil t)
  (setq-local mode-line-process
              '(:eval (concat " " (or cmacs-dbexplorer--connection-name
                                      "no connection")))))

;; Opens ready to type.  `with-eval-after-load' rather than an `fboundp'
;; guard: the guard silently does nothing when this file loads before
;; Evil, and the failure mode is landing in normal state where the
;; letters of your statement are operators.
(with-eval-after-load 'evil
  (evil-set-initial-state 'cmacs-dbexplorer-sql-mode 'insert))

(defun cmacs-dbexplorer-sql-ensure (connection)
  "Return CONNECTION's SQL buffer without displaying it."
  (cmacs-dbexplorer--require)
  (let* ((name (if (cmacs-dbexplorer-connection-p connection)
                   (cmacs-dbexplorer-connection-name connection)
                 connection))
         (buffer (get-buffer-create (format "*dbexplorer-sql: %s*" name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-dbexplorer-sql-mode)
        (cmacs-dbexplorer-sql-mode))
      (setq cmacs-dbexplorer--connection-name name))
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-sql (&optional connection)
  "Open the SQL buffer for CONNECTION."
  (interactive)
  (cmacs-dbexplorer--require)
  (pop-to-buffer
   (cmacs-dbexplorer-sql-ensure
    (or connection (cmacs-dbexplorer-read-connection-name "Connection: ")))))

(cmacs-dbexplorer-register-view
 'sql
 :open #'cmacs-dbexplorer-sql
 :label "SQL editor")

(provide 'cmacs-dbexplorer-sql)
;;; cmacs-dbexplorer-sql.el ends here
