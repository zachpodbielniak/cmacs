;;; cmacs-cpatch.el --- Runtime C hot-patching UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:
;;
;; High-level Lisp surface for cpatch.  Compiled in only when cmacs
;; was built with `--enable-cmacs-cpatch'.  Phase 1 covers the safe
;; atomic DEFUN-pointer swap; trampoline detours for arbitrary C
;; functions are Phase 3.

;;; Code:

(require 'tabulated-list)
(require 'cl-lib)

(defgroup cmacs-cpatch nil
  "Runtime C hot-patching for cmacs."
  :group 'cmacs
  :prefix "cmacs-c-")

(defcustom cmacs-c-cpatch-confirm-each t
  "If non-nil, prompt interactively before applying any patch."
  :type 'boolean)

(defcustom cmacs-mcp-cintrospect-enable-patching nil
  "If non-nil, the MCP server is allowed to apply C hot-patches.
Default nil --- the M-x user trusting their own commands is NOT the
same trust level as a remote MCP client.  Flip this only when you
explicitly want LLM-driven mutation of the running C layer."
  :type 'boolean)

(defvar cmacs-cintrospect-patch-applied-hook nil
  "Hook run after a successful C hot-patch.
Each hook function receives one argument: a plist describing the
patch.  For DEFUN swaps the plist is
  (:kind defun-swap :symbol SYM :original-addr A :patched-addr B)
For trampoline detours:
  (:kind detour :symbol \"name\" :target-addr A :replacement-addr B)

Use this for auto-rollback automations, audit logging, or to drive
podomation rules.")

;; ─── *cmacs-c-patches* browser ────────────────────────────────────

(define-derived-mode cmacs-c-patches-mode tabulated-list-mode "C-Patches"
  "Browse currently-applied C hot-patches."
  (setq tabulated-list-format
        [("Symbol"        45 t)
         ("Original addr" 20 t)
         ("Patched addr"  20 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-sort-key (cons "Symbol" nil))
  (tabulated-list-init-header))

;;;###autoload
(defun cmacs-c-list-patches-buffer ()
  "Open the *cmacs-c-patches* browser."
  (interactive)
  (unless (fboundp 'cmacs-c-patch-list)
    (user-error "cpatch not available --- rebuild with --enable-cmacs-cpatch"))
  (let ((buf (get-buffer-create "*cmacs-c-patches*")))
    (with-current-buffer buf
      (cmacs-c-patches-mode)
      (setq tabulated-list-entries
            (mapcar
             (lambda (p)
               (let ((sym (plist-get p :symbol)))
                 (list (symbol-name sym)
                       (vector (symbol-name sym)
                               (format "0x%x" (or (plist-get p :original-addr) 0))
                               (format "0x%x" (or (plist-get p :patched-addr) 0))))))
             (cmacs-c-patch-list)))
      (tabulated-list-print)
      (local-set-key (kbd "u") #'cmacs-c--patches-unpatch-at-point)
      (local-set-key (kbd "U")
                     (lambda () (interactive)
                       (when (yes-or-no-p "Unpatch ALL? ")
                         (let ((n (cmacs-c-unpatch-all)))
                           (message "Restored %d patch(es)" n)
                           (cmacs-c-list-patches-buffer))))))
    (pop-to-buffer buf)))

(defun cmacs-c--patches-unpatch-at-point ()
  "Unpatch the DEFUN at point in *cmacs-c-patches*."
  (interactive)
  (let ((sym (tabulated-list-get-id)))
    (when (and sym
               (or (not cmacs-c-cpatch-confirm-each)
                   (yes-or-no-p (format "Unpatch %s? " sym))))
      (cmacs-c-unpatch-defun (intern sym))
      (cmacs-c-list-patches-buffer))))

(provide 'cmacs-cpatch)
;;; cmacs-cpatch.el ends here
