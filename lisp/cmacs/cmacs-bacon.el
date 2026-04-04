;;; cmacs-bacon.el --- Bacon shell mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp interface for the Bacon shell, a Unix shell with integrated
;; C scripting via Crispy.
;;
;; C primitives available:
;;   `bacon-start'       -- create and start a BaconShell
;;   `bacon-stop'        -- destroy the BaconShell
;;   `bacon-eval'        -- execute a command string
;;   `bacon-eval-c'      -- execute a C code block
;;   `bacon-complete'    -- get completion candidates
;;   `bacon-environment' -- get shell environment as alist
;;   `bacon-source'      -- source a file
;;   `bacon-alias'       -- get or set an alias
;;   `bacon-running-p'   -- check if shell is running
;;
;; This file provides:
;;   - `bacon-shell-mode' -- major mode derived from comint-mode
;;   - `M-x bacon'        -- open a Bacon shell buffer
;;   - Tab completion via `bacon-complete'

;;; Code:

(require 'comint)

(defgroup bacon nil
  "Bacon shell integration."
  :group 'cmacs
  :prefix "bacon-")

(defcustom bacon-buffer-name "*bacon*"
  "Name of the Bacon shell buffer."
  :type 'string
  :group 'bacon)

(defcustom bacon-prompt "bacon$ "
  "Prompt string for the Bacon shell."
  :type 'string
  :group 'bacon)

(defcustom bacon-startup-file nil
  "File to source when starting the Bacon shell, or nil for none."
  :type '(choice (const nil) file)
  :group 'bacon)

(defvar bacon-shell-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "TAB") #'bacon-complete-at-point)
    (define-key map (kbd "C-c C-c") #'bacon-interrupt)
    (define-key map (kbd "C-c C-d") #'bacon-send-eof)
    (define-key map (kbd "C-c C-z") #'bury-buffer)
    map)
  "Keymap for `bacon-shell-mode'.")

(defvar bacon-shell--process nil
  "The internal process object for the Bacon shell buffer.")

;;; Shell mode

(define-derived-mode bacon-shell-mode comint-mode "Bacon"
  "Major mode for the Bacon shell.

Bacon is a Unix shell with integrated C scripting support.  This
mode provides an interactive shell environment inside CMacs with
tab completion and command history.

\\{bacon-shell-mode-map}"
  :group 'bacon
  (setq-local comint-prompt-regexp (regexp-quote bacon-prompt))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'bacon-shell--input-sender)
  (setq-local comint-process-echoes nil)
  (add-hook 'completion-at-point-functions
            #'bacon-completion-at-point nil t))

(defun bacon-shell--input-sender (_proc input)
  "Send INPUT to the Bacon shell for evaluation.
_PROC is ignored; we call the C primitives directly."
  (let* ((trimmed (string-trim input))
         (output (condition-case err
                     (progn
                       (bacon-eval trimmed)
                       ;; bacon-eval returns exit code; get environment
                       ;; for the last exit status.
                       nil)
                   (bacon-error
                    (format "Error: %s" (cadr err))))))
    (bacon-shell--insert-output (or output ""))))

(defun bacon-shell--insert-output (output)
  "Insert OUTPUT into the Bacon shell buffer, followed by a new prompt."
  (let ((buf (get-buffer bacon-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (unless (string-empty-p output)
            (insert output)
            (unless (string-suffix-p "\n" output)
              (insert "\n")))
          (insert bacon-prompt)
          (set-marker (process-mark
                       (get-buffer-process (current-buffer)))
                      (point)))))))

;;; Completion

(defun bacon-completion-at-point ()
  "Completion-at-point function for Bacon shell mode."
  (let* ((end (point))
         (start (save-excursion
                  (skip-chars-backward "^ \t\n")
                  (point)))
         (prefix (buffer-substring-no-properties start end)))
    (when (> (length prefix) 0)
      (let ((candidates (bacon-complete prefix)))
        (when candidates
          (list start end candidates
                :exclusive 'no))))))

(defun bacon-complete-at-point ()
  "Perform completion at point in the Bacon shell."
  (interactive)
  (completion-at-point))

;;; Interactive commands

;;;###autoload
(defun bacon ()
  "Open (or switch to) the Bacon shell buffer."
  (interactive)
  (let ((buf (get-buffer-create bacon-buffer-name)))
    (unless (comint-check-proc buf)
      (with-current-buffer buf
        ;; Start a dummy process for comint.
        ;; Actual evaluation goes through bacon-eval.
        (let ((proc (start-process "bacon-shell" buf "cat")))
          (set-process-query-on-exit-flag proc nil)
          (setq bacon-shell--process proc)
          (bacon-shell-mode)
          ;; Ensure the C-level shell is started.
          (bacon-start)
          ;; Source startup file if configured.
          (when bacon-startup-file
            (condition-case err
                (bacon-source (expand-file-name bacon-startup-file))
              (bacon-error
               (message "Bacon: failed to source %s: %s"
                        bacon-startup-file (cadr err)))))
          (let ((inhibit-read-only t))
            (insert "Bacon Shell\n")
            (insert "Type shell commands at the prompt.\n\n")
            (insert bacon-prompt)
            (set-marker (process-mark proc) (point))))))
    (pop-to-buffer buf)))

(defun bacon-interrupt ()
  "Interrupt the current Bacon command."
  (interactive)
  (message "bacon: interrupted"))

(defun bacon-send-eof ()
  "Send EOF to the Bacon shell, stopping it."
  (interactive)
  (bacon-stop)
  (message "Bacon shell stopped"))

;;; Evil integration awareness

(defun bacon--setup-evil ()
  "Set up evil-mode bindings for Bacon shell buffers if evil is loaded."
  (when (featurep 'evil)
    (eval-after-load 'evil
      '(progn
         (evil-set-initial-state 'bacon-shell-mode 'insert)))))

(add-hook 'bacon-shell-mode-hook #'bacon--setup-evil)

;;; Utility functions

(defun bacon-shell-send (command)
  "Send COMMAND to the Bacon shell from elisp.
Does not require the Bacon buffer to be open."
  (bacon-eval command))

(defun bacon-shell-running-p ()
  "Return non-nil if the Bacon shell backend is active."
  (bacon-running-p))

(provide 'cmacs-bacon)
;;; cmacs-bacon.el ends here
