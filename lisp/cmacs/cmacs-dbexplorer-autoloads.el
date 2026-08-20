;;; cmacs-dbexplorer-autoloads.el --- Database explorer entry points -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Hand-written autoloads for the database explorer.
;;
;; Plain `src/emacs' already has these from the dumped `loaddefs.el', so
;; this file is redundant there.  It exists for the environments that
;; REGENERATE their own autoloads -- Doom Emacs above all -- which emit
;; stubs only for definitions they scanned themselves and drop everything
;; the dump knew.  In such a configuration `M-x cmacs-dbexplorer' is
;; simply `void-function' until something has required the right file, and
;; the natural conclusion is that the subsystem was not built.
;;
;; Requiring this file once, after init, makes every entry point reachable
;; whatever the autoload environment.  In Doom:
;;
;;   (when IS-CMACS-DBEXPLORER (require 'cmacs-dbexplorer-autoloads))
;;
;; It stays deliberately cheap: `autoload' declarations only, no `require'
;; of anything that would pull in the model, the grid or transient at
;; startup.  Each entry point loads its own file when it is first called.

;;; Code:

(autoload 'cmacs-dbexplorer "cmacs-dbexplorer-workbench"
  "Open the database workbench." t)
(autoload 'cmacs-dbexplorer-open-view "cmacs-dbexplorer-workbench"
  "Open a registered database explorer view." t)

(autoload 'cmacs-dbexplorer-connect "cmacs-dbexplorer"
  "Open a saved database connection." t)
(autoload 'cmacs-dbexplorer-connect-url "cmacs-dbexplorer"
  "Connect to a database URL." t)
(autoload 'cmacs-dbexplorer-disconnect "cmacs-dbexplorer"
  "Close a database connection." t)
(autoload 'cmacs-dbexplorer-reconnect "cmacs-dbexplorer"
  "Close and reopen a database connection." t)
(autoload 'cmacs-dbexplorer-available-p "cmacs-dbexplorer-model"
  "Return non-nil if this build has the database explorer compiled in.")

(autoload 'cmacs-dbexplorer-connections-list "cmacs-dbexplorer-connections"
  "Show the list of database connections." t)
(autoload 'cmacs-dbexplorer-schema "cmacs-dbexplorer-schema-ui"
  "Show a connection's schema tree." t)
(autoload 'cmacs-dbexplorer-sql "cmacs-dbexplorer-sql"
  "Open a SQL buffer on a connection." t)
(autoload 'cmacs-dbexplorer-sql-mode "cmacs-dbexplorer-sql"
  "Major mode for writing SQL bound to an explorer connection." t)
(autoload 'cmacs-dbexplorer-send-region "cmacs-dbexplorer-sql"
  "Run the region as SQL on a connection." t)
(autoload 'cmacs-dbexplorer-grid-open "cmacs-dbexplorer-grid"
  "Show a connection's result grid." t)
(autoload 'cmacs-dbexplorer-browse "cmacs-dbexplorer-grid"
  "Browse one table's rows." t)

;; The transient is autoloaded by name rather than by cookie on the
;; `transient-define-prefix' form.  A bare cookie copies the whole prefix
;; definition into the generated loaddefs, where it is evaluated during
;; the dump -- which drags transient into the pdump and breaks it.
(autoload 'cmacs-dbexplorer-export-menu "cmacs-dbexplorer-export"
  "Write a result out to a file." t)

;; Register the file extension the SQL editor saves to, so a query saved
;; with `C-c C-q' opens in a mode that knows how to run it again.
;;;###autoload
(defun cmacs-dbexplorer-claim-file-types ()
  "Claim the explorer's saved-query directory in `auto-mode-alist'.

Defined here rather than in `cmacs-dbexplorer-sql.el' because it runs
from `emacs-startup-hook', and loading the SQL editor -- and `sql' behind
it -- on every startup just to register one association would be rude."
  (interactive)
  (let ((entry (cons (concat "\\`"
                             (regexp-quote
                              (expand-file-name
                               (if (boundp 'cmacs-dbexplorer-sql-query-directory)
                                   cmacs-dbexplorer-sql-query-directory
                                 (locate-user-emacs-file "dbexplorer-queries/"))))
                             ".*\\.sql\\'")
                     'cmacs-dbexplorer-sql-mode)))
    (setq auto-mode-alist (cons entry (delete entry auto-mode-alist)))))

;;;###autoload
(add-hook 'emacs-startup-hook #'cmacs-dbexplorer-claim-file-types)

(provide 'cmacs-dbexplorer-autoloads)
;;; cmacs-dbexplorer-autoloads.el ends here
