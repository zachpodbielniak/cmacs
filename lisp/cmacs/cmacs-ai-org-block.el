;;; cmacs-ai-org-block.el --- #+BEGIN_AI org babel block  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Lightweight org-babel "ai" backend.  In an org buffer:
;;
;;   #+BEGIN_SRC ai :provider claude :system "Be brief"
;;   Explain the GIL.
;;   #+END_SRC
;;
;; `C-c C-c' evaluates the block; the response lands in #+RESULTS:.
;; Header args:
;;   :provider   claude / openai / gemini / ...
;;   :model      string
;;   :system     system prompt

;;; Code:

(require 'cmacs-ai)
(require 'ob)

(defun org-babel-execute:ai (body params)
  "Send BODY to ai-glib using PARAMS header args."
  (cmacs-ai--ensure)
  (let* ((provider (cdr (assq :provider params)))
         (system   (cdr (assq :system params)))
         (model    (cdr (assq :model params)))
         (prov (and provider (intern (format "%s" provider))))
         (cmacs-ai-default-model (or model cmacs-ai-default-model)))
    (cmacs-ai-prompt-sync body prov system)))

;;;###autoload
(defun cmacs-ai-org-block-register ()
  "Register the ai org-babel backend.  Safe to call multiple times."
  (interactive)
  (add-to-list 'org-babel-load-languages '(ai . t))
  (org-babel-do-load-languages 'org-babel-load-languages
                                org-babel-load-languages))

(provide 'cmacs-ai-org-block)
;;; cmacs-ai-org-block.el ends here
