;;; cmacs-ai-region.el --- Region/buffer AI commands  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; M-x commands that act on the current region or surroundings via
;; one-shot synchronous prompts: rewrite, explain, document, test.
;; Uses `cmacs-ai-prompt-sync' (no chat-buffer overhead).

;;; Code:

(require 'cmacs-ai)

(defun cmacs-ai-region--get ()
  "Return (BEG END TEXT) for the active region or signal."
  (unless (use-region-p) (user-error "No region active"))
  (list (region-beginning) (region-end)
        (buffer-substring-no-properties
         (region-beginning) (region-end))))

(defun cmacs-ai-region--mode-label ()
  (let ((m (symbol-name major-mode)))
    (replace-regexp-in-string "-mode\\'" "" m)))

;;;###autoload
(defun cmacs-ai-rewrite-region (instruction)
  "Replace the active region with the AI rewrite for INSTRUCTION.
The current major mode is conveyed to the model so the output uses
the right syntax.  One undo step reverts the change."
  (interactive "sRewrite instruction: ")
  (cmacs-ai--ensure)
  (cl-destructuring-bind (beg end text) (cmacs-ai-region--get)
    (let* ((mode (cmacs-ai-region--mode-label))
           (system (format
                    "You are a precise %s code rewriter.  Output ONLY the
rewritten code -- no commentary, no fences, no headers." mode))
           (prompt (format "Instruction: %s\n\nCode:\n%s"
                           instruction text))
           (out (cmacs-ai-prompt-sync prompt nil system)))
      (save-excursion
        (delete-region beg end)
        (goto-char beg)
        (let ((p (point)))
          (insert out)
          (undo-boundary)
          (message "cmacs-ai: rewrote region (%d -> %d chars)"
                   (length text) (- (point) p)))))))

;;;###autoload
(defun cmacs-ai-explain-region ()
  "Open a side window with an org-mode explanation of the region."
  (interactive)
  (cmacs-ai--ensure)
  (cl-destructuring-bind (_b _e text) (cmacs-ai-region--get)
    (let* ((mode (cmacs-ai-region--mode-label))
           (system (format
                    "You are an experienced %s engineer explaining code
to a colleague.  Use Org-mode markup, be concise, focus on the
non-obvious bits." mode))
           (prompt (format "Explain this code:\n\n%s" text))
           (out (cmacs-ai-prompt-sync prompt nil system))
           (buf (get-buffer-create "*cmacs-ai: explain*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert out)
          (org-mode)
          (goto-char (point-min))))
      (display-buffer-in-side-window buf '((side . right) (slot . 0)
                                            (window-width . 0.4))))))

;;;###autoload
(defun cmacs-ai-doc-region ()
  "Wrap the active region with an AI-written documentation comment."
  (interactive)
  (cmacs-ai--ensure)
  (cl-destructuring-bind (beg _e text) (cmacs-ai-region--get)
    (let* ((mode (cmacs-ai-region--mode-label))
           (system (format
                    "You write %s documentation comments.  Output a SINGLE
documentation comment (no surrounding text) appropriate for this
language's idiom (docstring, /** */, ;; , #' etc).  Cover purpose,
parameters, return value, side effects." mode))
           (out (cmacs-ai-prompt-sync (format "Code:\n%s" text)
                                       nil system)))
      (save-excursion
        (goto-char beg)
        (insert out)
        (unless (eq (char-before) ?\n) (insert "\n"))))))

;;;###autoload
(defun cmacs-ai-test-region ()
  "Synthesize a test for the active region in a scratch buffer."
  (interactive)
  (cmacs-ai--ensure)
  (cl-destructuring-bind (_b _e text) (cmacs-ai-region--get)
    (let* ((mode (cmacs-ai-region--mode-label))
           (system (format
                    "You write idiomatic %s unit tests.  Output ONLY the
test code -- detect the project's test framework from imports if
visible, otherwise default to the language's most common one." mode))
           (out (cmacs-ai-prompt-sync (format "Write a test for:\n%s"
                                               text)
                                       nil system))
           (buf (get-buffer-create "*cmacs-ai: test*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert out)
          (when (fboundp (intern (format "%s-mode" mode)))
            (funcall (intern (format "%s-mode" mode))))
          (goto-char (point-min))))
      (pop-to-buffer buf))))

(provide 'cmacs-ai-region)
;;; cmacs-ai-region.el ends here
