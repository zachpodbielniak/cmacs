;;; cmacs-ai-commit.el --- AI-suggested commit messages  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'cmacs-ai)

(defcustom cmacs-ai-commit-log-lookback 30
  "Number of recent commits used as style reference."
  :type 'integer
  :group 'cmacs-ai)

(defcustom cmacs-ai-commit-max-diff-bytes 32000
  "Maximum staged-diff bytes sent to the model."
  :type 'integer
  :group 'cmacs-ai)

(defun cmacs-ai-commit--shell (cmd)
  (with-temp-buffer
    (let ((default-directory (or (vc-root-dir) default-directory)))
      (call-process-shell-command cmd nil t)
      (buffer-string))))

;;;###autoload
(defun cmacs-ai-suggest-commit-message ()
  "Insert an AI-drafted commit message at point.
Use inside a *vc-log-edit* (or git-commit-mode) buffer.  Reads the
staged diff and last `cmacs-ai-commit-log-lookback' commits to learn
the project's style, then drafts a Conventional-Commits-style
message."
  (interactive)
  (cmacs-ai--ensure)
  (let* ((diff (cmacs-ai-commit--shell "git diff --staged --no-color"))
         (log  (cmacs-ai-commit--shell
                (format "git log --pretty=format:'%%s' -n %d"
                        cmacs-ai-commit-log-lookback))))
    (when (string-empty-p (string-trim diff))
      (user-error "Nothing staged"))
    (when (> (length diff) cmacs-ai-commit-max-diff-bytes)
      (setq diff (substring diff 0 cmacs-ai-commit-max-diff-bytes)))
    (let* ((system "You write git commit messages that match the
project's existing style.  Output ONLY the commit message -- subject
line under 70 chars on line 1, blank line, then a wrapped body if
needed.  Focus on the WHY, not the what.  No quotes, no fences.")
           (prompt (format "Recent commits (style reference):
%s

Staged diff:
%s

Write a commit message." log diff))
           (msg (cmacs-ai-prompt-sync prompt nil system)))
      (insert msg))))

(provide 'cmacs-ai-commit)
;;; cmacs-ai-commit.el ends here
