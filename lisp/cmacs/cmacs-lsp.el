;;; cmacs-lsp.el --- eglot client for the in-binary --cmacs-lsp servers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; cmacs compiles LSP language servers into the emacs binary itself
;; (--with-cmacs-lsp): `emacs --cmacs-lsp LANG' speaks JSON-RPC over
;; stdio with no editor and no Lisp VM (see doc_org/cmacs/lsp.org and
;; cmacs/lsp/).  This file is the generic client half: it spawns a
;; server as a subprocess call back to THIS running binary -- the
;; /proc/self/exe model, spelled portably with `invocation-directory'
;; -- registers major modes with eglot, and auto-starts on file visit.
;; Per-language glue lives with each subsystem; the calculator's `.calc'
;; sheets register the "gnucalc" server at the bottom of
;; cmacs-calculator-sheet.el.

;;; Code:

(defgroup cmacs-lsp nil
  "Clients for the LSP language servers compiled into cmacs."
  :group 'cmacs
  :prefix "cmacs-lsp-")

(defcustom cmacs-lsp-auto-start t
  "When non-nil, `cmacs-lsp-ensure' starts eglot automatically.
Set to nil to keep the registration (\\[eglot] still works by hand)
without auto-connecting on every file visit."
  :type 'boolean
  :group 'cmacs-lsp)

(defun cmacs-lsp-available-p ()
  "Non-nil when this build carries the in-binary LSP framework."
  (and (boundp 'is-cmacs-lsp) is-cmacs-lsp))

(defun cmacs-lsp-binary ()
  "This Emacs binary, for spawning --cmacs-lsp servers.
The server is always the very binary the client runs in, so the two
can never disagree about the language data compiled into them."
  (expand-file-name invocation-name invocation-directory))

(defun cmacs-lsp-server-command (lang)
  "The command list that runs the LANG language server."
  (list (cmacs-lsp-binary) "--cmacs-lsp" lang))

(defun cmacs-lsp-register-eglot (mode lang)
  "Register MODE with eglot to use the in-binary LANG server."
  (with-eval-after-load 'eglot
    (add-to-list 'eglot-server-programs
                 (cons mode (cmacs-lsp-server-command lang)))))

(defun cmacs-lsp-ensure ()
  "Start eglot for the current buffer when appropriate.
Intended for major-mode hooks of modes previously registered with
`cmacs-lsp-register-eglot'.  Does nothing unless `cmacs-lsp-auto-start'
is non-nil, the buffer visits a file, and this build has the framework."
  (when (and cmacs-lsp-auto-start
             buffer-file-name
             (cmacs-lsp-available-p))
    ;; Load eglot from a temp buffer first: on Emacs 30 the eglot
    ;; autoload firing under `delay-mode-hooks' in a derived-mode
    ;; buffer recursively expands macros (same workaround as
    ;; podomation-emacs).
    (unless (featurep 'eglot)
      (with-temp-buffer (require 'eglot nil t)))
    (when (fboundp 'eglot-ensure)
      (eglot-ensure))))

(provide 'cmacs-lsp)
;;; cmacs-lsp.el ends here
