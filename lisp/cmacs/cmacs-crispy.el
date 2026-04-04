;;; cmacs-crispy.el --- Crispy C scripting elisp layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp interface for Crispy, the runtime C scripting engine.
;;
;; C primitives available:
;;   `crispy-eval'         -- compile and execute inline C code
;;   `crispy-eval-string'  -- execute C code, return stdout as string
;;   `crispy-compile'      -- compile a .c file, return cached binary path
;;   `crispy-run'          -- compile and execute a .c script with args
;;   `crispy-repl-eval'    -- evaluate C code in persistent REPL
;;   `crispy-repl-reset'   -- reset the persistent REPL state
;;   `crispy-cache-status' -- return the cache directory path
;;
;; This file provides:
;;   - `crispy-repl-mode'   -- major mode for interactive C REPL
;;   - `crispy-eval-region' -- evaluate selected C code
;;   - `crispy-eval-buffer' -- evaluate current buffer as C
;;   - `M-x crispy-repl'    -- open the REPL

;;; Code:

(require 'comint)

(defgroup crispy nil
  "Crispy C scripting integration."
  :group 'cmacs
  :prefix "crispy-")

(defcustom crispy-repl-buffer-name "*crispy*"
  "Name of the Crispy REPL buffer."
  :type 'string
  :group 'crispy)

(defcustom crispy-repl-prompt "crispy> "
  "Prompt string for the Crispy REPL."
  :type 'string
  :group 'crispy)

(defvar crispy-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map (kbd "C-c C-c") #'crispy-repl-send-input)
    (define-key map (kbd "C-c C-r") #'crispy-repl-reset)
    (define-key map (kbd "C-c C-z") #'bury-buffer)
    map)
  "Keymap for `crispy-repl-mode'.")

(defvar crispy-repl--process nil
  "The internal process object for the Crispy REPL buffer.")

;;; REPL mode

(define-derived-mode crispy-repl-mode comint-mode "Crispy"
  "Major mode for the Crispy C REPL.

This mode provides an interactive C evaluation environment powered
by the Crispy runtime compiler.  C code entered at the prompt is
compiled and executed on the fly.

\\{crispy-repl-mode-map}"
  :group 'crispy
  (setq-local comint-prompt-regexp (regexp-quote crispy-repl-prompt))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'crispy-repl--input-sender)
  (setq-local comint-process-echoes nil))

(defun crispy-repl--input-sender (_proc input)
  "Send INPUT to the Crispy REPL for evaluation.
_PROC is ignored; we call the C primitive directly."
  (let ((output (condition-case err
                    (crispy-eval-string input)
                  (crispy-error
                   (format "Error: %s" (cadr err))))))
    (crispy-repl--insert-output output)))

(defun crispy-repl--insert-output (output)
  "Insert OUTPUT into the REPL buffer, followed by a new prompt."
  (let ((buf (get-buffer crispy-repl-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (unless (string-empty-p output)
            (insert output)
            (unless (string-suffix-p "\n" output)
              (insert "\n")))
          (insert crispy-repl-prompt)
          (set-marker (process-mark
                       (get-buffer-process (current-buffer)))
                      (point)))))))

(defun crispy-repl-send-input ()
  "Send the current input to the Crispy REPL."
  (interactive)
  (comint-send-input))

;;;###autoload
(defun crispy-repl ()
  "Open (or switch to) the Crispy C REPL buffer."
  (interactive)
  (let ((buf (get-buffer-create crispy-repl-buffer-name)))
    (unless (comint-check-proc buf)
      (with-current-buffer buf
        ;; Start a dummy process for comint to hang its state on.
        ;; Actual evaluation goes through crispy-eval-string.
        (let ((proc (start-process "crispy-repl" buf "cat")))
          (set-process-query-on-exit-flag proc nil)
          (setq crispy-repl--process proc)
          (crispy-repl-mode)
          (let ((inhibit-read-only t))
            (insert (format "Crispy C REPL [CMacs %s]\n"
                            (if (boundp 'cmacs-version)
                                cmacs-version
                              "0.1.0")))
            (insert "Type C code at the prompt.  Statements are compiled and executed.\n")
            (insert "Use C-c C-r to reset REPL state.\n\n")
            (insert crispy-repl-prompt)
            (set-marker (process-mark proc) (point))))))
    (pop-to-buffer buf)))

;;; Evaluation commands

;;;###autoload
(defun crispy-eval-region (start end)
  "Evaluate the region from START to END as C code via Crispy.
Displays the result in the echo area."
  (interactive "r")
  (let* ((code (buffer-substring-no-properties start end))
         (result (crispy-eval-string code)))
    (if (string-empty-p result)
        (message "(crispy: no output)")
      (message "%s" result))))

;;;###autoload
(defun crispy-eval-buffer ()
  "Evaluate the current buffer as a C script via Crispy.
If the buffer is visiting a file, uses `crispy-run' on the file.
Otherwise, sends the buffer contents to `crispy-eval-string'."
  (interactive)
  (if buffer-file-name
      (let ((rc (crispy-run buffer-file-name)))
        (message "crispy: exit code %d" rc))
    (let ((result (crispy-eval-string
                   (buffer-substring-no-properties
                    (point-min) (point-max)))))
      (if (string-empty-p result)
          (message "(crispy: no output)")
        (message "%s" result)))))

;;;###autoload
(defun crispy-eval-defun ()
  "Evaluate the C function at point.
Attempts to find the enclosing function definition and evaluate it."
  (interactive)
  (save-excursion
    (let (start end)
      ;; Find function start: line matching a return type + name pattern
      ;; or an opening brace at column 0.
      (beginning-of-defun)
      (setq start (point))
      (end-of-defun)
      (setq end (point))
      (crispy-eval-region start end))))

;;; Minor mode for C buffers

(defvar crispy-minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'crispy-eval-defun)
    (define-key map (kbd "C-c C-r") #'crispy-eval-region)
    (define-key map (kbd "C-c C-b") #'crispy-eval-buffer)
    (define-key map (kbd "C-c C-z") #'crispy-repl)
    map)
  "Keymap for `crispy-minor-mode'.")

;;;###autoload
(define-minor-mode crispy-minor-mode
  "Minor mode for evaluating C code via Crispy.

Provides keybindings for sending C code from the current buffer
to the Crispy runtime compiler.

\\{crispy-minor-mode-map}"
  :lighter " Crispy"
  :keymap crispy-minor-mode-map
  :group 'crispy)

(provide 'cmacs-crispy)
;;; cmacs-crispy.el ends here
