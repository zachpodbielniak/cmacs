;;; cmacs-ai-agent.el --- Project-aware tool-using coding agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A higher-level wrapper around `cmacs-ai-chat' that:
;;   - prefixes a project-aware system prompt (CLAUDE.md / AGENTS.md
;;     content auto-attached, root listing, recent buffers)
;;   - enables tool use by default
;;   - persists one agent chat per project root

;;; Code:

(require 'cmacs-ai)
(require 'cmacs-ai-chat)
(require 'project nil 'noerror)

(defcustom cmacs-ai-agent-project-files
  '("CLAUDE.md" "AGENTS.md" "README.org" "README.md")
  "Files at the project root attached to the agent system prompt.
First existing match wins."
  :type '(repeat string)
  :group 'cmacs-ai)

(defcustom cmacs-ai-agent-system-prompt
  "You are a senior software engineer embedded in cmacs.  When asked
to write code, you respond in Org-mode-friendly markup and use
code fences with the correct language.  When given a project
context (CLAUDE.md / AGENTS.md), you take its conventions as
ground truth and prefer to reuse existing functions over writing
new ones.  Cite file paths with file:line notation."
  "System prompt prefix for `cmacs-ai-agent-open'."
  :type 'string
  :group 'cmacs-ai)

(defun cmacs-ai-agent--project-root ()
  (or (and (fboundp 'project-current)
           (let ((p (project-current))) (when p (project-root p))))
      (and (fboundp 'vc-root-dir) (vc-root-dir))
      default-directory))

(defun cmacs-ai-agent--read-project-doc (root)
  "Return the first existing project doc as a string, or nil."
  (cl-loop for f in cmacs-ai-agent-project-files
           for path = (expand-file-name f root)
           when (file-readable-p path)
           return (with-temp-buffer
                    (insert-file-contents path)
                    (let ((body (buffer-string)))
                      ;; Cap absurdly long docs.
                      (if (> (length body) 20000)
                          (substring body 0 20000)
                        body)))))

(defun cmacs-ai-agent--system-prompt (root)
  (let* ((doc (cmacs-ai-agent--read-project-doc root))
         (parts (list cmacs-ai-agent-system-prompt
                       (format "Project root: %s" root)
                       (and doc (format "Project agent contract:\n%s"
                                         doc)))))
    (mapconcat #'identity (delq nil parts) "\n\n")))

;;;###autoload
(defun cmacs-ai-agent-open ()
  "Open or resume the cmacs-ai agent chat for the current project."
  (interactive)
  (cmacs-ai--ensure)
  (let* ((root (cmacs-ai-agent--project-root))
         (name (format "*cmacs-ai-agent: %s*" (abbreviate-file-name root)))
         (buf  (get-buffer name)))
    (if (buffer-live-p buf)
        (switch-to-buffer buf)
      (let ((cmacs-ai-system-prompt
              (cmacs-ai-agent--system-prompt root)))
        (setq buf (cmacs-ai-chat-open cmacs-ai-default-provider))
        (with-current-buffer buf
          (rename-buffer name 'unique))
        (switch-to-buffer buf)))))

;;;###autoload
(defun cmacs-ai-agent-explain-this ()
  "Send the current defun (or region) to the project agent with an explain prompt."
  (interactive)
  (cmacs-ai-agent-open)
  (let* ((src-buf (other-buffer (current-buffer) t))
         (text (with-current-buffer src-buf
                 (cond ((use-region-p)
                        (buffer-substring-no-properties
                         (region-beginning) (region-end)))
                       (t (let ((b (save-excursion
                                     (beginning-of-defun) (point)))
                                (e (save-excursion
                                     (end-of-defun) (point))))
                            (buffer-substring-no-properties b e)))))))
    (goto-char (point-max))
    (insert (format "Explain this code from %s:\n\n#+BEGIN_SRC %s\n%s\n#+END_SRC"
                    (buffer-name src-buf)
                    (replace-regexp-in-string
                     "-mode\\'" ""
                     (symbol-name
                      (buffer-local-value 'major-mode src-buf)))
                    text))
    (cmacs-ai-chat-send-compose)))

(provide 'cmacs-ai-agent)
;;; cmacs-ai-agent.el ends here
