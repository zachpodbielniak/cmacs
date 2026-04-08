;;; cmacs-podomation.el --- Podomation automation engine integration  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp convenience layer for the podomation automation engine.
;; Provides configuration via customize, an Emacs hook bridge that
;; fires podomation events, a comint-based REPL, and GI fallback
;; for advanced access.

;;; Code:

(require 'comint)

;;;; Configuration

(defgroup cmacs-podomation nil
  "Podomation automation engine."
  :group 'cmacs
  :prefix "cmacs-podomation-")

(defcustom cmacs-podomation-auto-start nil
  "Start the podomation engine automatically during init."
  :type 'boolean
  :group 'cmacs-podomation)

(defcustom cmacs-podomation-pod-files nil
  "List of .pod files to load when the engine starts."
  :type '(repeat file)
  :group 'cmacs-podomation)

(defcustom cmacs-podomation-module-dirs nil
  "Additional directories to scan for podomation module .so files."
  :type '(repeat directory)
  :group 'cmacs-podomation)

;;;; Hook bridge

(defvar cmacs-podomation--hook-alist
  '((after-save-hook      . "on_buffer_save")
    (kill-buffer-hook      . "on_buffer_kill")
    (after-init-hook       . "on_after_init")
    (post-command-hook     . "on_post_command"))
  "Mapping from Emacs hooks to podomation event names.")

(defun cmacs-podomation--gather-event-data (event-name)
  "Gather context data for EVENT-NAME as an alist."
  (pcase event-name
    ("on_buffer_save"
     `((buffer_name . ,(buffer-name))
       (file_name   . ,(or (buffer-file-name) ""))
       (major_mode  . ,(symbol-name major-mode))))
    ("on_buffer_kill"
     `((buffer_name . ,(buffer-name))))
    ("on_after_init" nil)
    ("on_post_command"
     `((command_name . ,(symbol-name (or this-command 'self-insert-command)))))
    (_ nil)))

(defun cmacs-podomation--install-hooks ()
  "Wire Emacs hooks to fire podomation events."
  (dolist (pair cmacs-podomation--hook-alist)
    (let ((hook (car pair))
          (event (cdr pair)))
      (add-hook hook
                (lambda (&rest _args)
                  (when (and (fboundp 'cmacs-podomation-running-p)
                             (cmacs-podomation-running-p))
                    (cmacs-podomation-emit-event
                     event
                     (cmacs-podomation--gather-event-data event))))))))

(defun cmacs-podomation--remove-hooks ()
  "Remove podomation hook functions."
  (dolist (pair cmacs-podomation--hook-alist)
    (remove-hook (car pair) #'cmacs-podomation--hook-fn)))

;;;; Dynamic hook wrapper

(defun cmacs-podomation-hook (hook-name)
  "Register Emacs HOOK-NAME as a podomation event source.
HOOK-NAME is a string naming any Emacs hook.
When the hook fires, emits an on_hook event with hook_name data."
  (let ((hook-sym (intern hook-name)))
    (add-hook hook-sym
              (lambda (&rest _args)
                (when (and (fboundp 'cmacs-podomation-running-p)
                           (cmacs-podomation-running-p))
                  (cmacs-podomation-emit-event
                   "on_hook"
                   `((hook_name . ,hook-name))))))))

;;;; GI fallback

(defun cmacs-podomation--gi-available-p ()
  "Return non-nil if GI bridge is loaded and Podomation typelib available."
  (and (fboundp 'gi-require)
       (condition-case nil
           (progn (gi-require "Podomation" "1.0") t)
         (error nil))))

;;;; Comint REPL

(defvar cmacs-podomation-repl-buffer-name "*podomation*"
  "Name of the podomation REPL buffer.")

(defun cmacs-podomation--repl-input-sender (_proc input)
  "Send INPUT to the podomation REPL engine."
  (let* ((result (cmacs-podomation-repl-eval input))
         (kind (car result))
         (text (cdr result))
         (buf (current-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (when text
          (insert text "\n"))
        (unless (eq kind 'continue)
          (insert (cmacs-podomation-repl-prompt)))
        (set-marker (process-mark
                     (get-buffer-process (current-buffer)))
                    (point))))))

(defun cmacs-podomation--repl-completion ()
  "Completion function for the podomation REPL."
  (let* ((line (buffer-substring
                (save-excursion (comint-bol) (point))
                (point)))
         (completions (cmacs-podomation-repl-complete line)))
    (when completions
      (list (save-excursion (comint-bol) (point))
            (point)
            completions))))

(define-derived-mode cmacs-podomation-repl-mode comint-mode "Pod-REPL"
  "Major mode for the podomation REPL."
  (setq-local comint-prompt-regexp
              "^\\(podomation> \\|       \\.\\.\\.> \\)")
  (setq-local comint-input-sender
              #'cmacs-podomation--repl-input-sender)
  (setq-local comint-process-echoes nil)
  (add-hook 'completion-at-point-functions
            #'cmacs-podomation--repl-completion nil t))

;;;###autoload
(defun podomation-repl ()
  "Open the podomation REPL in a comint buffer."
  (interactive)
  (unless (and (fboundp 'cmacs-podomation-running-p)
               (cmacs-podomation-running-p))
    (cmacs-podomation-start))
  (let ((buf (get-buffer-create cmacs-podomation-repl-buffer-name)))
    (unless (comint-check-proc buf)
      (with-current-buffer buf
        (let ((fake-proc (start-process "podomation-repl" buf "cat")))
          (set-process-query-on-exit-flag fake-proc nil)
          (cmacs-podomation-repl-mode)
          (goto-char (point-max))
          (let ((inhibit-read-only t))
            (insert (cmacs-podomation-repl-prompt)))
          (set-marker (process-mark fake-proc) (point)))))
    (pop-to-buffer buf)))

;;;; Convenience functions

;;;###autoload
(defun cmacs-podomation-load (file)
  "Load a .pod FILE into the running engine."
  (interactive "fPod file: ")
  (unless (and (fboundp 'cmacs-podomation-running-p)
               (cmacs-podomation-running-p))
    (cmacs-podomation-start))
  (cmacs-podomation-load-file (expand-file-name file)))

(defun cmacs-podomation-start-with-config ()
  "Start the engine and load all configured .pod files."
  (interactive)
  (cmacs-podomation-start)
  (cmacs-podomation--install-hooks)
  (dolist (f cmacs-podomation-pod-files)
    (cmacs-podomation-load-file (expand-file-name f))))

;;;; Auto-start

(defun cmacs-podomation--maybe-auto-start ()
  "Start podomation if `cmacs-podomation-auto-start' is non-nil."
  (when cmacs-podomation-auto-start
    (cmacs-podomation-start-with-config)))

(add-hook 'emacs-startup-hook #'cmacs-podomation--maybe-auto-start)

(provide 'cmacs-podomation)
;;; cmacs-podomation.el ends here
