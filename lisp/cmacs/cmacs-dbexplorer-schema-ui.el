;;; cmacs-dbexplorer-schema-ui.el --- The schema tree  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What is in the database, as a tree you open one level at a time.
;;
;; The tree is drawn from the model's schema cache and nothing else.  A
;; node that is collapsed costs no query; expanding one fetches its level
;; and caches it; a redraw -- which happens on every keystroke that moves
;; the cursor between windows -- reads the cache and never asks the
;; database anything.  That is the whole reason the cache lives in the
;; model rather than here: the SQL buffer's completion reads the same
;; entries, so opening a table in the tree makes its columns completable
;; in the editor, without either half knowing about the other.
;;
;; Fetches are fire-and-forget: the expansion is recorded immediately, the
;; node draws as pending, and the reply arrives later and triggers a
;; redraw through the model's schema hook.  Nothing blocks, so a slow
;; catalogue query on a large database cannot wedge the editor.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-dbexplorer)
(require 'cmacs-evil)

(declare-function cmacs-dbexplorer--schemas-async
                  "src/cmacs-dbexplorer-defuns.c" (handle cb))
(declare-function cmacs-dbexplorer--tables-async
                  "src/cmacs-dbexplorer-defuns.c" (handle schema cb))
(declare-function cmacs-dbexplorer--table-info-async
                  "src/cmacs-dbexplorer-defuns.c" (handle schema table cb))
(declare-function cmacs-dbexplorer-browse "cmacs-dbexplorer-grid"
                  (connection schema table))
(declare-function cmacs-dbexplorer-sql "cmacs-dbexplorer-sql"
                  (&optional connection))


;;;; Buffer state -------------------------------------------------------

(defvar-local cmacs-dbexplorer-schema--schemas nil
  "The schema names on this connection, in order.")

(defvar-local cmacs-dbexplorer-schema--expanded nil
  "Hash of node id to non-nil for every node the user has opened.")

(defvar-local cmacs-dbexplorer-schema--pending nil
  "Hash of node id to non-nil for every fetch that has not answered.")

(defun cmacs-dbexplorer-schema-buffer-name (connection-name)
  "Return the schema-tree buffer name for CONNECTION-NAME."
  (format "*dbexplorer-schema: %s*" connection-name))

(defun cmacs-dbexplorer-schema--expanded-p (id)
  "Return non-nil when the node called ID is open."
  (and cmacs-dbexplorer-schema--expanded
       (gethash id cmacs-dbexplorer-schema--expanded)))


;;;; Opening the obvious schema -----------------------------------------

(defcustom cmacs-dbexplorer-schema-auto-expand t
  "Whether the tree opens the obvious schema for you when it first appears.

Everything in the tree is lazy, which is what keeps a database with
thousands of relations cheap to open.  Taken literally that means the
first thing you see is a single collapsed node called `public', which
reads as an empty database rather than as a closed door -- so one node,
the one you were going to open anyway, opens itself.

The cost is one catalogue query on connect.  Set this to nil on a
database where even that is unwelcome, and the tree stays fully closed."
  :type 'boolean
  :group 'cmacs-dbexplorer)

(defcustom cmacs-dbexplorer-schema-default-names '("public" "main" "dbo")
  "Schema names that count as the obvious one to open.

Consulted only when a connection has several schemas; a connection with
just one has no ambiguity to resolve and that one is opened whatever it
is called.  Matched case-insensitively."
  :type '(repeat string)
  :group 'cmacs-dbexplorer)

(defun cmacs-dbexplorer-schema--default-schema ()
  "Return the schema to open unasked, or nil when none is obvious.

A sole schema is opened whatever its name -- including the nil node that
stands in for a dialect with no schemas at all, which is how SQLite gets
its tables on screen.  With several, only a conventionally-default name
qualifies, because guessing wrong means firing a catalogue query at a
schema the user never asked about."
  (if (null (cdr cmacs-dbexplorer-schema--schemas))
      (car cmacs-dbexplorer-schema--schemas)
    (cl-find-if (lambda (schema)
                  (and schema
                       (member (downcase schema)
                               cmacs-dbexplorer-schema-default-names)))
                cmacs-dbexplorer-schema--schemas)))

(defun cmacs-dbexplorer-schema--auto-expand ()
  "Open the default schema, but only while nothing has been opened yet.

Guarded on the expansion set being empty rather than on a first-time
flag, so it stays out of the way of the user: collapsing `public' and
pressing `g' leaves it collapsed, because by then the set is no longer
empty and this does nothing."
  (when (and cmacs-dbexplorer-schema-auto-expand
             cmacs-dbexplorer-schema--expanded
             (zerop (hash-table-count cmacs-dbexplorer-schema--expanded))
             ;; A one-schema connection returns nil for the SQLite node,
             ;; which is a legitimate schema to open -- so the emptiness
             ;; of the list, not the nil-ness of the answer, is the test.
             (or (null (cdr cmacs-dbexplorer-schema--schemas))
                 (cmacs-dbexplorer-schema--default-schema)))
    (puthash (cmacs-dbexplorer-schema--node-id
              (cmacs-dbexplorer-schema--default-schema))
             t cmacs-dbexplorer-schema--expanded)))


;;;; Reading the C replies ----------------------------------------------

(defun cmacs-dbexplorer-schema--entry-name (entry)
  "Return ENTRY's name, whether it is a string or a plist."
  (cond ((stringp entry) entry)
        ((plistp entry) (format "%s" (plist-get entry :name)))
        (t (format "%s" entry))))

(defun cmacs-dbexplorer-schema--vector (reply key)
  "Return REPLY's KEY as a list, whatever sequence it arrived as."
  (append (alist-get key reply) nil))


;;;; Fetching -----------------------------------------------------------

(defun cmacs-dbexplorer-schema--fetch-schemas (buffer connection)
  "Fetch CONNECTION's schema list into BUFFER."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--schemas-async)
  (cmacs-dbexplorer--schemas-async
   (cmacs-dbexplorer--handle connection)
   (lambda (reply)
     (let ((error-message (cmacs-dbexplorer--reply-error reply)))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if error-message
               (message "cmacs-dbexplorer: %s" error-message)
             (setq cmacs-dbexplorer-schema--schemas
                   (or (mapcar #'cmacs-dbexplorer-schema--entry-name
                               (cmacs-dbexplorer-schema--vector reply :schemas))
                       ;; A dialect with no schemas at all -- sqlite --
                       ;; still needs one node to hang its tables from.
                       (list nil)))
             (cmacs-dbexplorer-schema--auto-expand)
             (cmacs-dbexplorer-schema--render))))))))

(defun cmacs-dbexplorer-schema--fetch-tables (connection schema id)
  "Fetch SCHEMA's relations on CONNECTION, marking ID pending until they land."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--tables-async)
  (puthash id t cmacs-dbexplorer-schema--pending)
  (let ((buffer (current-buffer)))
    (cmacs-dbexplorer--tables-async
     (cmacs-dbexplorer--handle connection) schema
     (lambda (reply)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (remhash id cmacs-dbexplorer-schema--pending)
           (let ((error-message (cmacs-dbexplorer--reply-error reply)))
             (if error-message
                 (message "cmacs-dbexplorer: %s" error-message)
               (cmacs-dbexplorer-schema-put connection schema nil reply)))
           (cmacs-dbexplorer-schema--render)))))))

(defun cmacs-dbexplorer-schema--fetch-table (connection schema table id)
  "Fetch TABLE's details in SCHEMA on CONNECTION, marking ID pending."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--table-info-async)
  (puthash id t cmacs-dbexplorer-schema--pending)
  (let ((buffer (current-buffer)))
    (cmacs-dbexplorer--table-info-async
     (cmacs-dbexplorer--handle connection) schema table
     (lambda (reply)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (remhash id cmacs-dbexplorer-schema--pending)
           (let ((error-message (cmacs-dbexplorer--reply-error reply)))
             (if error-message
                 (message "cmacs-dbexplorer: %s" error-message)
               (cmacs-dbexplorer-schema-put connection schema table reply)))
           (cmacs-dbexplorer-schema--render)))))))


;;;; Rendering ----------------------------------------------------------

(defun cmacs-dbexplorer-schema--node-id (schema &optional table group item)
  "Return the tree id for SCHEMA, TABLE, GROUP and ITEM.

A tree position, not an object identity: expansion state survives a
refresh precisely because the id is derived from the names, which do not
churn, rather than from the position, which does."
  (mapconcat (lambda (part) (or part "")) (list schema table group item) "\0"))

(defun cmacs-dbexplorer-schema--marker (id children)
  "Return the expander glyph for node ID, which has CHILDREN or not."
  (cond
   ((not children) (cmacs-dbexplorer-glyph 'leaf))
   ((cmacs-dbexplorer-schema--expanded-p id) (cmacs-dbexplorer-glyph 'expanded))
   (t (cmacs-dbexplorer-glyph 'collapsed))))

(defun cmacs-dbexplorer-schema--insert (node depth marker label &optional face)
  "Insert a tree line for NODE at DEPTH, showing MARKER and LABEL."
  (insert (propertize (concat (make-string (* 2 depth) ?\s)
                              marker " "
                              (if face (propertize label 'face face) label))
                      'cmacs-dbexplorer-node node
                      'cmacs-dbexplorer-depth depth)
          "\n"))

(defun cmacs-dbexplorer-schema--column-label (column primary-key)
  "Return a display label for COLUMN, marking it when it is in PRIMARY-KEY."
  (let ((name (format "%s" (plist-get column :name))))
    (concat (propertize name 'face (if (member name primary-key)
                                       'cmacs-dbexplorer-key
                                     'default))
            " "
            (propertize (format "%s" (or (plist-get column :type-name)
                                         (plist-get column :type) "?"))
                        'face 'cmacs-dbexplorer-type)
            (if (plist-get column :nullable) "" " NOT NULL")
            (if (plist-get column :default)
                (format " = %s" (plist-get column :default))
              ""))))

(defun cmacs-dbexplorer-schema--insert-group (connection schema table group info)
  "Insert GROUP of TABLE in SCHEMA from INFO, for CONNECTION."
  (let* ((id (cmacs-dbexplorer-schema--node-id schema table group))
         (items (pcase group
                  ("columns" (cmacs-dbexplorer-schema--vector info :columns))
                  ("indexes" (cmacs-dbexplorer-schema--vector info :indexes))
                  (_ (cmacs-dbexplorer-schema--vector info :foreign-keys))))
         (primary-key (mapcar #'cmacs-dbexplorer-schema--entry-name
                              (cmacs-dbexplorer-schema--vector
                               info :primary-key))))
    (cmacs-dbexplorer-schema--insert
     (list :kind 'group :id id :schema schema :table table :group group)
     2 (cmacs-dbexplorer-schema--marker id items)
     (format "%s (%d)" group (length items)) 'cmacs-dbexplorer-header)
    (when (cmacs-dbexplorer-schema--expanded-p id)
      (dolist (item items)
        (let ((name (cmacs-dbexplorer-schema--entry-name item)))
          (cmacs-dbexplorer-schema--insert
           (list :kind 'item :id (cmacs-dbexplorer-schema--node-id
                                  schema table group name)
                 :schema schema :table table :group group :name name
                 :connection connection)
           3 (cmacs-dbexplorer-glyph 'leaf)
           (if (equal group "columns")
               (cmacs-dbexplorer-schema--column-label item primary-key)
             (cmacs-dbexplorer-schema--describe item))))))))

(defun cmacs-dbexplorer-schema--describe (item)
  "Return a one-line description of an index or foreign key ITEM."
  (if (not (plistp item))
      (format "%s" item)
    (let ((name (plist-get item :name))
          (columns (cmacs-dbexplorer-schema--vector-of item :columns))
          (target (or (plist-get item :references) (plist-get item :table))))
      (concat (format "%s" (or name "?"))
              (when columns (format " (%s)" (string-join columns ", ")))
              (when (plist-get item :unique) " UNIQUE")
              (when target (format " -> %s" target))))))

(defun cmacs-dbexplorer-schema--vector-of (plist key)
  "Return PLIST's KEY as a list of strings."
  (mapcar #'cmacs-dbexplorer-schema--entry-name
          (append (plist-get plist key) nil)))

(defun cmacs-dbexplorer-schema--insert-table (connection schema relation)
  "Insert RELATION of SCHEMA on CONNECTION, and its groups when it is open."
  (let* ((name (cmacs-dbexplorer-schema--entry-name relation))
         (kind (or (and (plistp relation) (plist-get relation :kind)) 'table))
         (id (cmacs-dbexplorer-schema--node-id schema name))
         (info (cmacs-dbexplorer-schema-get connection schema name)))
    (cmacs-dbexplorer-schema--insert
     (list :kind 'relation :id id :schema schema :table name :relation-kind kind)
     1 (cmacs-dbexplorer-schema--marker id t)
     (format "%s%s" name (if (eq kind 'view) " (view)" ""))
     'cmacs-dbexplorer-table)
    (when (cmacs-dbexplorer-schema--expanded-p id)
      (cond
       ((gethash id cmacs-dbexplorer-schema--pending)
        (cmacs-dbexplorer-schema--insert nil 2 " " "reading..." 'shadow))
       ((null info)
        (cmacs-dbexplorer-schema--fetch-table connection schema name id)
        (cmacs-dbexplorer-schema--insert nil 2 " " "reading..." 'shadow))
       (t
        (dolist (group '("columns" "indexes" "foreign-keys"))
          (cmacs-dbexplorer-schema--insert-group connection schema name
                                                 group info)))))))

(defun cmacs-dbexplorer-schema--insert-schema (connection schema)
  "Insert SCHEMA on CONNECTION, and its relations when it is open."
  (let* ((id (cmacs-dbexplorer-schema--node-id schema))
         (cached (cmacs-dbexplorer-schema-get connection schema nil)))
    (cmacs-dbexplorer-schema--insert
     (list :kind 'schema :id id :schema schema)
     0 (cmacs-dbexplorer-schema--marker id t)
     (or schema "(default)") 'cmacs-dbexplorer-header)
    (when (cmacs-dbexplorer-schema--expanded-p id)
      (cond
       ((gethash id cmacs-dbexplorer-schema--pending)
        (cmacs-dbexplorer-schema--insert nil 1 " " "reading..." 'shadow))
       ((null cached)
        (cmacs-dbexplorer-schema--fetch-tables connection schema id)
        (cmacs-dbexplorer-schema--insert nil 1 " " "reading..." 'shadow))
       (t
        (let ((relations (cmacs-dbexplorer-schema--vector cached :relations)))
          (if (null relations)
              (cmacs-dbexplorer-schema--insert nil 1 " " "(no tables)" 'shadow)
            (dolist (relation relations)
              (cmacs-dbexplorer-schema--insert-table connection schema
                                                     relation)))))))))

(defun cmacs-dbexplorer-schema--render ()
  "Redraw the tree, keeping the cursor on the node it was on."
  (let* ((inhibit-read-only t)
         (connection (cmacs-dbexplorer-buffer-connection))
         (line (line-number-at-pos))
         (saved (mapcar (lambda (window)
                          (cons window (cmacs-dbexplorer-schema--id-at
                                        (window-point window))))
                        (get-buffer-window-list (current-buffer) nil t)))
         (here (cmacs-dbexplorer-schema--id-at (point))))
    (erase-buffer)
    (if (null connection)
        (insert "\n  Not connected.\n")
      (dolist (schema cmacs-dbexplorer-schema--schemas)
        (cmacs-dbexplorer-schema--insert-schema connection schema)))
    (insert "\n" (propertize
                  (concat " TAB open/close   RET browse   c columns   "
                          "I indexes   F keys\n"
                          " s SQL   y copy name   ^ parent   n/p sibling   "
                          "g refresh   q quit\n")
                  'face 'shadow))
    (goto-char (or (cmacs-dbexplorer-schema--pos-of-id here)
                   (progn (goto-char (point-min))
                          (forward-line (1- line))
                          (point))))
    (dolist (cell saved)
      (when (window-live-p (car cell))
        (set-window-point (car cell)
                          (or (cmacs-dbexplorer-schema--pos-of-id (cdr cell))
                              (point)))))))


;;;; Point --------------------------------------------------------------

(defun cmacs-dbexplorer-schema--node ()
  "Return the node on this line, or nil."
  (get-text-property (line-beginning-position) 'cmacs-dbexplorer-node))

(defun cmacs-dbexplorer-schema--node-or-error ()
  "Return the node on this line, or signal."
  (or (cmacs-dbexplorer-schema--node) (user-error "No node on this line")))

(defun cmacs-dbexplorer-schema--id-at (position)
  "Return the node id at POSITION, or nil."
  (when (and position (<= (point-min) position) (<= position (point-max)))
    (let ((node (get-text-property
                 (save-excursion (goto-char position) (line-beginning-position))
                 'cmacs-dbexplorer-node)))
      (plist-get node :id))))

(defun cmacs-dbexplorer-schema--pos-of-id (id)
  "Return where the node called ID begins after a redraw, or nil."
  (when id
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (not (eobp))
          (let ((node (get-text-property (point) 'cmacs-dbexplorer-node)))
            (when (equal id (plist-get node :id))
              (throw 'found (point))))
          (forward-line 1))
        nil))))

(defun cmacs-dbexplorer-schema--depth ()
  "Return the depth of the line at point, or nil."
  (get-text-property (line-beginning-position) 'cmacs-dbexplorer-depth))


;;;; Commands -----------------------------------------------------------

(defun cmacs-dbexplorer-schema-toggle ()
  "Open or close the node at point."
  (interactive)
  (let* ((node (cmacs-dbexplorer-schema--node-or-error))
         (id (plist-get node :id)))
    (if (cmacs-dbexplorer-schema--expanded-p id)
        (remhash id cmacs-dbexplorer-schema--expanded)
      (puthash id t cmacs-dbexplorer-schema--expanded))
    (cmacs-dbexplorer-schema--render)))

(defun cmacs-dbexplorer-schema-expand ()
  "Open the node at point, or move into it when it is already open."
  (interactive)
  (let* ((node (cmacs-dbexplorer-schema--node-or-error))
         (id (plist-get node :id)))
    (if (cmacs-dbexplorer-schema--expanded-p id)
        (forward-line 1)
      (puthash id t cmacs-dbexplorer-schema--expanded)
      (cmacs-dbexplorer-schema--render))))

(defun cmacs-dbexplorer-schema-collapse ()
  "Close the node at point, or move to its parent when it is already closed."
  (interactive)
  (let* ((node (cmacs-dbexplorer-schema--node-or-error))
         (id (plist-get node :id)))
    (if (cmacs-dbexplorer-schema--expanded-p id)
        (progn (remhash id cmacs-dbexplorer-schema--expanded)
               (cmacs-dbexplorer-schema--render))
      (cmacs-dbexplorer-schema-parent))))

(defun cmacs-dbexplorer-schema-parent ()
  "Move to the parent of the node at point."
  (interactive)
  (let ((depth (cmacs-dbexplorer-schema--depth)))
    (when (and depth (> depth 0))
      (let ((target (1- depth)))
        (while (and (not (bobp))
                    (not (eql target (cmacs-dbexplorer-schema--depth))))
          (forward-line -1))))))

(defun cmacs-dbexplorer-schema-next-sibling ()
  "Move to the next node at this depth."
  (interactive)
  (let ((depth (cmacs-dbexplorer-schema--depth))
        (start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (eql depth (cmacs-dbexplorer-schema--depth))))
      (forward-line 1))
    (when (eobp) (goto-char start))))

(defun cmacs-dbexplorer-schema-previous-sibling ()
  "Move to the previous node at this depth."
  (interactive)
  (let ((depth (cmacs-dbexplorer-schema--depth))
        (start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (eql depth (cmacs-dbexplorer-schema--depth))))
      (forward-line -1))
    (when (bobp) (goto-char start))))

(defun cmacs-dbexplorer-schema-visit ()
  "Browse the table at point, or open the node at point."
  (interactive)
  (let ((node (cmacs-dbexplorer-schema--node-or-error)))
    (if (eq (plist-get node :kind) 'relation)
        (progn
          (require 'cmacs-dbexplorer-grid)
          (cmacs-dbexplorer-browse (cmacs-dbexplorer-buffer-connection-or-error)
                                   (plist-get node :schema)
                                   (plist-get node :table)))
      (cmacs-dbexplorer-schema-toggle))))

(defun cmacs-dbexplorer-schema--show-group (group)
  "Open the GROUP of the table at point."
  (let ((node (cmacs-dbexplorer-schema--node-or-error)))
    (unless (plist-get node :table)
      (user-error "cmacs-dbexplorer: no table on this line"))
    (let ((schema (plist-get node :schema))
          (table (plist-get node :table)))
      (puthash (cmacs-dbexplorer-schema--node-id schema table) t
               cmacs-dbexplorer-schema--expanded)
      (puthash (cmacs-dbexplorer-schema--node-id schema table group) t
               cmacs-dbexplorer-schema--expanded)
      (cmacs-dbexplorer-schema--render)
      (let ((position (cmacs-dbexplorer-schema--pos-of-id
                       (cmacs-dbexplorer-schema--node-id schema table group))))
        (when position (goto-char position))))))

(defun cmacs-dbexplorer-schema-columns ()
  "Open the columns of the table at point."
  (interactive)
  (cmacs-dbexplorer-schema--show-group "columns"))

(defun cmacs-dbexplorer-schema-indexes ()
  "Open the indexes of the table at point."
  (interactive)
  (cmacs-dbexplorer-schema--show-group "indexes"))

(defun cmacs-dbexplorer-schema-foreign-keys ()
  "Open the foreign keys of the table at point."
  (interactive)
  (cmacs-dbexplorer-schema--show-group "foreign-keys"))

(defun cmacs-dbexplorer-schema-copy-name ()
  "Copy the quoted name of the node at point."
  (interactive)
  (let* ((node (cmacs-dbexplorer-schema--node-or-error))
         (connection (cmacs-dbexplorer-buffer-connection))
         (text (cond
                ((plist-get node :name)
                 (cmacs-dbexplorer-quote connection (plist-get node :name)))
                ((plist-get node :table)
                 (cmacs-dbexplorer-qualified-name connection
                                                  (plist-get node :schema)
                                                  (plist-get node :table)))
                (t (cmacs-dbexplorer-quote connection
                                           (plist-get node :schema))))))
    (kill-new text)
    (message "%s" text)))

(defun cmacs-dbexplorer-schema-open-sql ()
  "Open a SQL buffer on this tree's connection."
  (interactive)
  (require 'cmacs-dbexplorer-sql)
  (cmacs-dbexplorer-sql (cmacs-dbexplorer-buffer-connection-or-error)))

(defun cmacs-dbexplorer-schema-refresh ()
  "Forget every cached detail and read the tree again."
  (interactive)
  (let ((connection (cmacs-dbexplorer-buffer-connection-or-error)))
    (cmacs-dbexplorer-schema-forget connection)
    (cmacs-dbexplorer-schema--fetch-schemas (current-buffer) connection)
    (cmacs-dbexplorer-schema--render)))

(defun cmacs-dbexplorer-schema-browse-prompt (connection)
  "Read a table on CONNECTION and browse it.

Used from the connection list, where there is no tree to point at yet.

The prompt runs on a zero-delay timer rather than in the reply callback
itself.  Replies are delivered through the C dispatch, which binds
`inhibit-interaction' -- so a `completing-read' there does not prompt,
it signals `inhibited-interaction', the dispatch swallows it, and the
key that started all this appears to do nothing, every time.  The timer
callback runs from the ordinary command loop, where prompting is legal."
  (cmacs-dbexplorer--need 'cmacs-dbexplorer--tables-async)
  (let ((connection (cmacs-dbexplorer-resolve connection)))
    (cmacs-dbexplorer--tables-async
     (cmacs-dbexplorer--handle connection) nil
     (lambda (reply)
       (let ((error-message (cmacs-dbexplorer--reply-error reply)))
         (if error-message
             (message "cmacs-dbexplorer: %s" error-message)
           (let ((names (mapcar #'cmacs-dbexplorer-schema--entry-name
                                (cmacs-dbexplorer-schema--vector
                                 reply :relations))))
             (if (null names)
                 ;; `message', not `user-error': a signal raised inside
                 ;; the dispatch unwinds the dispatch, not the user.
                 (message "cmacs-dbexplorer: no tables")
               (run-at-time
                0 nil
                (lambda ()
                  (require 'cmacs-dbexplorer-grid)
                  (cmacs-dbexplorer-browse
                   connection nil
                   (completing-read "Table: " names nil t))))))))))))


;;;; Mode ---------------------------------------------------------------

(defvar cmacs-dbexplorer-schema-mode-map
  (let ((map (make-sparse-keymap)))
    ;; hjkl explicitly: the Evil intercept promotion below takes the
    ;; buffer over, and SPC stays unbound so the Doom leader survives.
    (define-key map "j" #'next-line)
    (define-key map "k" #'previous-line)
    (define-key map "h" #'cmacs-dbexplorer-schema-collapse)
    (define-key map "l" #'cmacs-dbexplorer-schema-expand)
    (define-key map (kbd "TAB") #'cmacs-dbexplorer-schema-toggle)
    (define-key map (kbd "RET") #'cmacs-dbexplorer-schema-visit)
    (define-key map "c" #'cmacs-dbexplorer-schema-columns)
    (define-key map "I" #'cmacs-dbexplorer-schema-indexes)
    (define-key map "F" #'cmacs-dbexplorer-schema-foreign-keys)
    (define-key map "s" #'cmacs-dbexplorer-schema-open-sql)
    (define-key map "y" #'cmacs-dbexplorer-schema-copy-name)
    (define-key map "^" #'cmacs-dbexplorer-schema-parent)
    (define-key map "n" #'cmacs-dbexplorer-schema-next-sibling)
    (define-key map "p" #'cmacs-dbexplorer-schema-previous-sibling)
    (define-key map "g" #'cmacs-dbexplorer-schema-refresh)
    (define-key map "q" #'cmacs-dbexplorer-quit)
    map)
  "Keymap for `cmacs-dbexplorer-schema-mode'.")

(define-derived-mode cmacs-dbexplorer-schema-mode special-mode "DB-Schema"
  "What is in the database.

\\{cmacs-dbexplorer-schema-mode-map}"
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq cmacs-dbexplorer-schema--expanded (make-hash-table :test 'equal))
  (setq cmacs-dbexplorer-schema--pending (make-hash-table :test 'equal)))

(defun cmacs-dbexplorer-schema-ensure (connection)
  "Return CONNECTION's schema-tree buffer without displaying it."
  (cmacs-dbexplorer--require)
  (let* ((connection (cmacs-dbexplorer-resolve connection))
         (name (cmacs-dbexplorer-connection-name connection))
         (buffer (get-buffer-create
                  (cmacs-dbexplorer-schema-buffer-name name))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-dbexplorer-schema-mode)
        (cmacs-dbexplorer-schema-mode))
      (setq cmacs-dbexplorer--connection-name name)
      (unless cmacs-dbexplorer-schema--schemas
        (cmacs-dbexplorer-schema--fetch-schemas buffer connection))
      (cmacs-dbexplorer-schema--render))
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-schema (&optional connection)
  "Show the schema tree for CONNECTION."
  (interactive)
  (let ((buffer (cmacs-dbexplorer-schema-ensure
                 (or connection
                     (cmacs-dbexplorer-read-connection-name "Connection: " t)))))
    (display-buffer buffer)
    buffer))

(defun cmacs-dbexplorer-schema--on-update (payload)
  "Redraw the tree for the connection PAYLOAD names."
  (let ((buffer (get-buffer (cmacs-dbexplorer-schema-buffer-name
                             (plist-get payload :connection)))))
    (when (buffer-live-p buffer)
      (cmacs-dbexplorer-mark-dirty buffer #'cmacs-dbexplorer-schema--render))))

(add-hook 'cmacs-dbexplorer-schema-updated-functions
          #'cmacs-dbexplorer-schema--on-update)

(cmacs-dbexplorer-register-view
 'tree
 :open #'cmacs-dbexplorer-schema
 :supports '(schema)
 :label "Schema tree")

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-dbexplorer-schema-mode 'motion)))

(cmacs-evil-setup-mode-map cmacs-dbexplorer-schema-mode-map
                           'cmacs-dbexplorer-schema-mode)

(provide 'cmacs-dbexplorer-schema-ui)
;;; cmacs-dbexplorer-schema-ui.el ends here
