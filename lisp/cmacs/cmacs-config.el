;;; cmacs-config.el --- Load user config written in Bacon or C  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; CMacs allows writing Emacs configuration in three languages:
;;
;;   1. Emacs Lisp (init.el) -- standard, always loaded first
;;   2. Bacon shell (init.bacon) -- shell-style config via `bacon-eval'
;;   3. C code (init.c) -- compiled+executed via `crispy-run'
;;
;; Bacon and C configs are loaded AFTER init.el so they can
;; override or extend elisp settings.  They live in the same
;; directory as init.el (user-emacs-directory).
;;
;; Bacon configs are useful for shell-like setup: setting env vars,
;; sourcing dotfiles, defining aliases.
;;
;; C configs are useful for performance-critical initialization or
;; direct GObject manipulation from init.

;;; Code:

(defcustom cmacs-config-load-bacon t
  "Whether to load init.bacon from `user-emacs-directory' at startup."
  :type 'boolean
  :group 'cmacs)

(defcustom cmacs-config-load-crispy t
  "Whether to load init.c from `user-emacs-directory' at startup."
  :type 'boolean
  :group 'cmacs)

(defvar cmacs-config-bacon-file nil
  "Path to the loaded bacon config file, or nil if none was loaded.")

(defvar cmacs-config-crispy-file nil
  "Path to the loaded C config file, or nil if none was loaded.")

(defun cmacs-config--bacon-init-file ()
  "Return the path to init.bacon if it exists."
  (let ((file (expand-file-name "init.bacon" user-emacs-directory)))
    (when (file-exists-p file) file)))

(defun cmacs-config--crispy-init-file ()
  "Return the path to init.c if it exists."
  (let ((file (expand-file-name "init.c" user-emacs-directory)))
    (when (file-exists-p file) file)))

(defun cmacs-config-load-bacon-init ()
  "Load init.bacon from `user-emacs-directory' if it exists.
The file is sourced via `bacon-source', which executes it in the
bacon shell environment.  The shell is started automatically if needed."
  (when (and cmacs-config-load-bacon
             (fboundp 'bacon-source))
    (let ((file (cmacs-config--bacon-init-file)))
      (when file
        (condition-case err
            (progn
              (bacon-source file)
              (setq cmacs-config-bacon-file file)
              (message "Loaded %s" file))
          (error
           (display-warning 'cmacs
                            (format "Error loading %s: %s" file
                                    (error-message-string err))
                            :error)))))))

(defun cmacs-config-load-crispy-init ()
  "Load init.c from `user-emacs-directory' if it exists.
The file is compiled and executed via `crispy-run'."
  (when (and cmacs-config-load-crispy
             (fboundp 'crispy-run))
    (let ((file (cmacs-config--crispy-init-file)))
      (when file
        (condition-case err
            (progn
              (crispy-run file)
              (setq cmacs-config-crispy-file file)
              (message "Loaded %s" file))
          (error
           (display-warning 'cmacs
                            (format "Error loading %s: %s" file
                                    (error-message-string err))
                            :error)))))))

(defun cmacs-config-load-all ()
  "Load bacon and C config files after elisp init.
Called automatically during startup if CMacs features are available."
  (cmacs-config-load-bacon-init)
  (cmacs-config-load-crispy-init))

(provide 'cmacs-config)
;;; cmacs-config.el ends here
