;;; cmacs-dbexplorer-connections.el --- The connection list  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A table of every connection the explorer knows about, whether or not it
;; is open.
;;
;; The list deliberately shows configured connections and live ones in one
;; table rather than two.  The question being answered here is "which
;; database am I about to touch, and is it writable" -- and a view that
;; only listed open connections would answer it after the fact.  So a
;; configured connection appears greyed with state `closed', a live one
;; carries its dialect, its transaction and its read-only flag, and `RET'
;; means the same thing on both: get me into that database.
;;
;; This is `tabulated-list-mode', unlike the grid and the tree, because the
;; content really is a fixed five-column table with sortable columns and
;; nothing tabulated-list does badly.  That choice has one consequence
;; worth knowing: its keymap inherits keys this mode does not bind, so the
;; Evil integration is `cmacs-evil-intercept-mode-map' rather than
;; `cmacs-evil-setup-mode-map' -- promoting inherited keys to intercept
;; precedence would shadow the Doom leader.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'transient)
(require 'cmacs-dbexplorer)
(require 'cmacs-evil)

(declare-function cmacs-dbexplorer--connection-list
                  "src/cmacs-dbexplorer-defuns.c" ())
(declare-function cmacs-dbexplorer-schema "cmacs-dbexplorer-schema-ui"
                  (&optional connection))
(declare-function cmacs-dbexplorer-sql "cmacs-dbexplorer-sql"
                  (&optional connection))
(declare-function cmacs-dbexplorer-browse "cmacs-dbexplorer-grid"
                  (connection schema table))
(declare-function cmacs-dbexplorer-schema-browse-prompt
                  "cmacs-dbexplorer-schema-ui" (connection))

(defconst cmacs-dbexplorer-connections-buffer "*dbexplorer-connections*"
  "Name of the connection-list buffer.")


;;;; Rows ---------------------------------------------------------------

(defun cmacs-dbexplorer-connections--state-string (connection)
  "Return CONNECTION's state as a propertized string."
  (let ((state (if connection
                   (cmacs-dbexplorer-connection-state connection)
                 'closed)))
    (propertize (symbol-name state)
                'face (pcase state
                        ('idle 'success)
                        ('busy 'cmacs-dbexplorer-header)
                        ('connecting 'shadow)
                        (_ 'shadow)))))

(defun cmacs-dbexplorer-connections--entry (name spec connection)
  "Return the tabulated-list entry for NAME, from SPEC and CONNECTION."
  (list name
        (vector
         (propertize name 'face 'cmacs-dbexplorer-table)
         (or (and connection (cmacs-dbexplorer-connection-dialect connection))
             ;; Before the first connection the dialect is only a guess
             ;; from the URL scheme, and is shown as one.
             (cmacs-dbexplorer-connections--scheme spec)
             "—")
         (cmacs-dbexplorer-connections--state-string connection)
         (if (if connection
                 (cmacs-dbexplorer-connection-read-only connection)
               (plist-get spec :read-only))
             (propertize "yes" 'face 'cmacs-dbexplorer-read-only)
           "no")
         (if (and connection
                  (cmacs-dbexplorer-connection-in-transaction connection))
             (propertize "open" 'face 'cmacs-dbexplorer-read-only)
           "—"))))

(defun cmacs-dbexplorer-connections--scheme (spec)
  "Return the URL scheme SPEC names, in lower case, or nil."
  (let ((url (plist-get spec :url)))
    (when (and url (string-match "\\`\\([a-zA-Z0-9+.-]+\\):" url))
      (downcase (match-string 1 url)))))

(defun cmacs-dbexplorer-connections--entries ()
  "Return every configured and live connection as list entries."
  (let* ((specs (cmacs-dbexplorer-connection-specs))
         (names (delete-dups
                 (append (mapcar #'car specs)
                         (mapcar #'cmacs-dbexplorer-connection-name
                                 (cmacs-dbexplorer-connections))))))
    (mapcar (lambda (name)
              (cmacs-dbexplorer-connections--entry
               name (cdr (assoc name specs))
               (cmacs-dbexplorer-connection name)))
            (sort names #'string<))))

(defun cmacs-dbexplorer-connections--reconcile ()
  "Drop live connections the C layer no longer has.

The model can outlive the truth: a connection dropped by the server, or
by a C-side error that never reached a callback, leaves a struct claiming
to be open.  Asking C what it actually holds is cheap and is the only way
to notice."
  (when (fboundp 'cmacs-dbexplorer--connection-list)
    (let ((handles (mapcar (lambda (entry) (alist-get :handle entry))
                           (cmacs-dbexplorer--connection-list))))
      (dolist (connection (cmacs-dbexplorer-connections))
        (let ((handle (cmacs-dbexplorer-connection-handle connection)))
          (when (and handle (not (memq handle handles)))
            (cmacs-dbexplorer--drop-connection
             (cmacs-dbexplorer-connection-name connection))))))))


;;;; Commands -----------------------------------------------------------

(defun cmacs-dbexplorer-connections--name ()
  "Return the connection name on this line, or signal."
  (or (tabulated-list-get-id)
      (user-error "No connection on this line")))

(defun cmacs-dbexplorer-connections-refresh ()
  "Rebuild the connection list."
  (interactive)
  (let ((buffer (get-buffer cmacs-dbexplorer-connections-buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (cmacs-dbexplorer-connections--reconcile)
        (setq tabulated-list-entries (cmacs-dbexplorer-connections--entries))
        ;; `remember-pos' keeps the cursor on the same connection rather
        ;; than the same line, which matters because the list re-sorts.
        (tabulated-list-print t)))))

(defun cmacs-dbexplorer-connections-connect ()
  "Open the connection on this line."
  (interactive)
  (cmacs-dbexplorer-connect (cmacs-dbexplorer-connections--name)))

(defun cmacs-dbexplorer-connections-disconnect ()
  "Close the connection on this line."
  (interactive)
  (cmacs-dbexplorer-disconnect (cmacs-dbexplorer-connections--name)))

(defun cmacs-dbexplorer-connections-toggle-read-only ()
  "Flip whether the connection on this line accepts writes."
  (interactive)
  (cmacs-dbexplorer-toggle-read-only (cmacs-dbexplorer-connections--name)))

(defun cmacs-dbexplorer-connections-visit ()
  "Connect if needed, then show the connection's schema tree."
  (interactive)
  (let ((name (cmacs-dbexplorer-connections--name)))
    ;; Watcher first, connect second, in all three of these: registering
    ;; after the call would be a race if connecting ever answered
    ;; synchronously, and the order costs nothing.
    (cmacs-dbexplorer-when-connected
     name (lambda (connection)
            (require 'cmacs-dbexplorer-schema-ui)
            (cmacs-dbexplorer-schema connection)))
    (unless (cmacs-dbexplorer-connection-open-p
             (cmacs-dbexplorer-connection name))
      (cmacs-dbexplorer-connect name))))

(defun cmacs-dbexplorer-connections-sql ()
  "Open a SQL buffer on the connection at point."
  (interactive)
  (let ((name (cmacs-dbexplorer-connections--name)))
    (cmacs-dbexplorer-when-connected
     name (lambda (connection)
            (require 'cmacs-dbexplorer-sql)
            (cmacs-dbexplorer-sql connection)))
    (unless (cmacs-dbexplorer-connection-open-p
             (cmacs-dbexplorer-connection name))
      (cmacs-dbexplorer-connect name))))

(defun cmacs-dbexplorer-connections-tables ()
  "Browse a table on the connection at point."
  (interactive)
  (let ((name (cmacs-dbexplorer-connections--name)))
    (cmacs-dbexplorer-when-connected
     name (lambda (connection)
            (require 'cmacs-dbexplorer-schema-ui)
            (cmacs-dbexplorer-schema-browse-prompt connection)))
    (unless (cmacs-dbexplorer-connection-open-p
             (cmacs-dbexplorer-connection name))
      (cmacs-dbexplorer-connect name))))

(defun cmacs-dbexplorer-connections-delete ()
  "Forget the saved settings for the connection on this line."
  (interactive)
  (let ((name (cmacs-dbexplorer-connections--name)))
    (unless (assoc name cmacs-dbexplorer-connections)
      (user-error "cmacs-dbexplorer: %s is not saved in this configuration"
                  name))
    (when (yes-or-no-p (format "Forget the saved connection %s? " name))
      (cmacs-dbexplorer-connections--save
       (assoc-delete-all name (copy-alist cmacs-dbexplorer-connections))
       ;; Persisted only if it was already persisted; a connection that
       ;; came from a source or from `setq' is not the custom file's to
       ;; write about.
       (and (get 'cmacs-dbexplorer-connections 'saved-value) t))
      (cmacs-dbexplorer-connections-refresh))))

(defun cmacs-dbexplorer-connections--save (value persist)
  "Set `cmacs-dbexplorer-connections' to VALUE, writing it out when PERSIST."
  (if persist
      (customize-save-variable 'cmacs-dbexplorer-connections value)
    (customize-set-variable 'cmacs-dbexplorer-connections value)))


;;;; Adding and editing a connection ------------------------------------

(transient-define-prefix cmacs-dbexplorer-connection-menu ()
  "Describe a saved connection.

The URL is the whole specification; leave the password out of it and put
it in auth-source, which is what `p' opts out of."
  :value '("--save")
  ["Connection"
   ("n" "name" "--name=" :always-read t)
   ("u" "url" "--url=" :always-read t)]
  ["Flags"
   ("r" "refuse writes" "--read-only")
   ("A" "connect when the workbench opens" "--auto-connect")
   ("p" "the URL already carries its password" "--inline-password")
   ("s" "write it to the custom file" "--save")]
  ["Act"
   ("c" "save it" cmacs-dbexplorer-connection-menu-save)
   ("C" "save and connect" cmacs-dbexplorer-connection-menu-connect)])

(defun cmacs-dbexplorer-connection-menu--spec (arguments)
  "Return (NAME . PLIST) from transient ARGUMENTS."
  (let ((name (transient-arg-value "--name=" arguments))
        (url (transient-arg-value "--url=" arguments)))
    (when (or (null name) (string-empty-p name))
      (user-error "cmacs-dbexplorer: the connection needs a name"))
    (when (or (null url) (string-empty-p url))
      (user-error "cmacs-dbexplorer: the connection needs a URL"))
    (cons name
          (append (list :url url)
                  (when (member "--read-only" arguments) '(:read-only t))
                  (when (member "--auto-connect" arguments) '(:auto-connect t))
                  (when (member "--inline-password" arguments)
                    '(:inline-password t))))))

(defun cmacs-dbexplorer-connection-menu--store (arguments)
  "Store the connection ARGUMENTS describe and return its name."
  (let* ((spec (cmacs-dbexplorer-connection-menu--spec arguments))
         (value (cons spec (assoc-delete-all
                            (car spec)
                            (copy-alist cmacs-dbexplorer-connections)))))
    (cmacs-dbexplorer-connections--save
     (sort value (lambda (a b) (string< (car a) (car b))))
     (and (member "--save" arguments) t))
    (car spec)))

(defun cmacs-dbexplorer-connection-menu-save (&optional arguments)
  "Save the connection described by ARGUMENTS."
  (interactive (list (transient-args 'cmacs-dbexplorer-connection-menu)))
  (message "cmacs-dbexplorer: saved %s"
           (cmacs-dbexplorer-connection-menu--store arguments))
  (cmacs-dbexplorer-connections-refresh))

(defun cmacs-dbexplorer-connection-menu-connect (&optional arguments)
  "Save the connection described by ARGUMENTS and open it."
  (interactive (list (transient-args 'cmacs-dbexplorer-connection-menu)))
  (let ((name (cmacs-dbexplorer-connection-menu--store arguments)))
    (cmacs-dbexplorer-connections-refresh)
    (cmacs-dbexplorer-connect name)))

(defun cmacs-dbexplorer-connections-add ()
  "Describe a new saved connection."
  (interactive)
  (transient-setup 'cmacs-dbexplorer-connection-menu))

(defun cmacs-dbexplorer-connections-edit ()
  "Edit the saved connection on this line."
  (interactive)
  (let* ((name (cmacs-dbexplorer-connections--name))
         (spec (cmacs-dbexplorer-connection-spec name)))
    (unless spec
      (user-error "cmacs-dbexplorer: %s has no saved settings" name))
    (transient-setup
     'cmacs-dbexplorer-connection-menu nil nil
     :value (append (list (concat "--name=" name)
                          (concat "--url=" (or (plist-get spec :url) "")))
                    (when (plist-get spec :read-only) '("--read-only"))
                    (when (plist-get spec :auto-connect) '("--auto-connect"))
                    (when (plist-get spec :inline-password)
                      '("--inline-password"))
                    (when (get 'cmacs-dbexplorer-connections 'saved-value)
                      '("--save"))))))


;;;; Mode ---------------------------------------------------------------

(defvar cmacs-dbexplorer-connections-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-dbexplorer-connections-visit)
    (define-key map "c" #'cmacs-dbexplorer-connections-connect)
    (define-key map "d" #'cmacs-dbexplorer-connections-disconnect)
    (define-key map "a" #'cmacs-dbexplorer-connections-add)
    (define-key map "e" #'cmacs-dbexplorer-connections-edit)
    (define-key map "x" #'cmacs-dbexplorer-connections-delete)
    (define-key map "r" #'cmacs-dbexplorer-connections-toggle-read-only)
    (define-key map "s" #'cmacs-dbexplorer-connections-sql)
    (define-key map "t" #'cmacs-dbexplorer-connections-tables)
    (define-key map "g" #'cmacs-dbexplorer-connections-refresh)
    (define-key map "q" #'cmacs-dbexplorer-quit)
    map)
  "Keymap for `cmacs-dbexplorer-connections-mode'.")

(define-derived-mode cmacs-dbexplorer-connections-mode tabulated-list-mode
  "DB-Connections"
  "Every database the explorer knows about.

\\{cmacs-dbexplorer-connections-mode-map}"
  (setq tabulated-list-format
        [("Name" 24 t) ("Dialect" 12 t) ("State" 12 t) ("RO" 4 nil)
         ("Txn" 5 nil)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key '("Name" . nil))
  (tabulated-list-init-header))

(defun cmacs-dbexplorer-connections--on-state (_payload)
  "Redraw the list when any connection changes state."
  (let ((buffer (get-buffer cmacs-dbexplorer-connections-buffer)))
    (when (buffer-live-p buffer)
      (cmacs-dbexplorer-mark-dirty buffer #'cmacs-dbexplorer-connections-refresh))))

(add-hook 'cmacs-dbexplorer-connection-state-functions
          #'cmacs-dbexplorer-connections--on-state)

(defun cmacs-dbexplorer-connections-ensure ()
  "Return the connection-list buffer, up to date, without displaying it.

Separate from the command because the workbench places this buffer in a
side window itself, and a function that displayed it on the way would
have to be undone before it could be placed."
  (cmacs-dbexplorer--require)
  (let ((buffer (get-buffer-create cmacs-dbexplorer-connections-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-dbexplorer-connections-mode)
        (cmacs-dbexplorer-connections-mode))
      (setq tabulated-list-entries (cmacs-dbexplorer-connections--entries))
      (tabulated-list-print t))
    buffer))

;;;###autoload
(defun cmacs-dbexplorer-connections-list ()
  "Show the list of database connections."
  (interactive)
  (pop-to-buffer (cmacs-dbexplorer-connections-ensure)))

(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-dbexplorer-connections-mode 'motion))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* 'motion cmacs-dbexplorer-connections-mode-map
      (kbd "RET") #'cmacs-dbexplorer-connections-visit
      "c" #'cmacs-dbexplorer-connections-connect
      "d" #'cmacs-dbexplorer-connections-disconnect
      "a" #'cmacs-dbexplorer-connections-add
      "e" #'cmacs-dbexplorer-connections-edit
      "x" #'cmacs-dbexplorer-connections-delete
      "r" #'cmacs-dbexplorer-connections-toggle-read-only
      ;; `s' is evil-snipe's in normal and motion state; the intercept
      ;; promotion below is what makes this one win.
      "s" #'cmacs-dbexplorer-connections-sql
      "t" #'cmacs-dbexplorer-connections-tables
      "g" #'cmacs-dbexplorer-connections-refresh
      "q" #'cmacs-dbexplorer-quit)))

;; Intercept rather than setup: this is a tabulated-list derivative, and
;; copying the keys it inherits into an intercept map would put `SPC' --
;; the Doom leader -- above Evil.
(cmacs-evil-intercept-mode-map cmacs-dbexplorer-connections-mode-map
                               'cmacs-dbexplorer-connections-mode)

(provide 'cmacs-dbexplorer-connections)
;;; cmacs-dbexplorer-connections.el ends here
