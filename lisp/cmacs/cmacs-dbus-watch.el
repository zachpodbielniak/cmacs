;;; cmacs-dbus-watch.el --- Lisp side of the BufferWatch iface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 5 observable form watcher.  The C side
;; (cmacs/dbus/cmacs-dbus-watch.c) registers
;; org.cmacs.Editor1.Watch.Add / Remove / List on the root path, and
;; calls back into the helpers here to actually evaluate, diff, and
;; signal.

;;; Code:

(defvar cmacs-dbus-watch--state (make-hash-table :test 'equal)
  "Hash table: object-path -> (expr . last-printed-value).")

(defvar cmacs-dbus-watch--paths nil
  "List of currently-active watch object paths (sorted by id).")

(defun cmacs-dbus-watch--register (path id expr)
  "Register a new watch.  Called from C side on Watch.Add."
  (puthash path (cons expr nil) cmacs-dbus-watch--state)
  (cl-pushnew path cmacs-dbus-watch--paths :test #'equal)
  (unless (memq #'cmacs-dbus-watch--poll post-command-hook)
    (add-hook 'post-command-hook #'cmacs-dbus-watch--poll))
  t)

(defun cmacs-dbus-watch--unregister (path)
  "Drop a watch.  Called from C side on Watch.Remove."
  (remhash path cmacs-dbus-watch--state)
  (setq cmacs-dbus-watch--paths
        (delete path cmacs-dbus-watch--paths))
  (when (zerop (hash-table-count cmacs-dbus-watch--state))
    (remove-hook 'post-command-hook #'cmacs-dbus-watch--poll))
  t)

(defun cmacs-dbus-watch--poll ()
  "Re-evaluate every watch; emit Changed if value differs."
  (maphash
   (lambda (path entry)
     (let* ((expr (car entry))
            (prev (cdr entry))
            (new  (condition-case err
                      (format "%S" (eval (read expr) t))
                    (error (format "<error: %s>" err)))))
       (unless (equal new prev)
         (puthash path (cons expr new) cmacs-dbus-watch--state)
         (cmacs-dbus-emit-signal
          path "org.cmacs.Editor1.WatchHandle"
          "Changed" (list new)))))
   cmacs-dbus-watch--state))

(provide 'cmacs-dbus-watch)
;;; cmacs-dbus-watch.el ends here
