;;; cmacs-ai-context-menu.el --- Right-click AI menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Adds an "AI ..." submenu to the standard right-click context
;; menu via `context-menu-functions'.  Only active when there's a
;; region selected.  Auto-enables `context-menu-mode' (Emacs 28+).

;;; Code:

(require 'cmacs-ai)

(defun cmacs-ai-context-menu (menu click)
  "Augment context-menu MENU with cmacs-ai actions for CLICK."
  (when (use-region-p)
    (define-key-after menu [cmacs-ai-sep] menu-bar-separator)
    (define-key-after menu [cmacs-ai-explain]
      '(menu-item "AI: Explain region" cmacs-ai-explain-region
                  :help "Explain the selected code with cmacs-ai"))
    (define-key-after menu [cmacs-ai-rewrite]
      '(menu-item "AI: Rewrite region..."
                  (lambda () (interactive)
                    (call-interactively #'cmacs-ai-rewrite-region))
                  :help "Rewrite the selection with cmacs-ai"))
    (define-key-after menu [cmacs-ai-doc]
      '(menu-item "AI: Document region" cmacs-ai-doc-region
                  :help "Insert AI-written doc comment above region"))
    (define-key-after menu [cmacs-ai-test]
      '(menu-item "AI: Generate test for region" cmacs-ai-test-region
                  :help "Synthesize a unit test for the selection")))
  menu)

;;;###autoload
(defun cmacs-ai-context-menu-install ()
  "Install the cmacs-ai context-menu entries."
  (interactive)
  (require 'cmacs-ai-region)
  (unless (bound-and-true-p context-menu-mode)
    (context-menu-mode 1))
  (add-hook 'context-menu-functions #'cmacs-ai-context-menu 90))

(provide 'cmacs-ai-context-menu)
;;; cmacs-ai-context-menu.el ends here
