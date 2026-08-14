;;; cmacs-ai-context-menu.el --- Compatibility shim  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; This file used to hold a small "AI ..." context-menu entry that only
;; appeared over an active region -- and, because nothing ever called
;; `cmacs-ai-context-menu-install', never appeared at all: loading the
;; file added the entry to no hook.
;;
;; The feature it was reaching for is now cmacs-ai-menu.el, which covers
;; every buffer rather than only regions, works under `emacs --lrg' as
;; well as pgtk, and installs itself.  This file remains so that an init
;; calling `cmacs-ai-context-menu-install' keeps working.

;;; Code:

(require 'cmacs-ai-menu)

;;;###autoload
(defun cmacs-ai-context-menu-install ()
  "Install the cmacs AI context menu.
Obsolete alias for `cmacs-ai-menu-bootstrap', kept for existing configs."
  (interactive)
  (cmacs-ai-menu-bootstrap))

(define-obsolete-function-alias 'cmacs-ai-context-menu
  #'cmacs-ai-menu-populate "cmacs 32.0.50")

(provide 'cmacs-ai-context-menu)

;;; cmacs-ai-context-menu.el ends here
