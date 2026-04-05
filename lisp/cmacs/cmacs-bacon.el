;;; cmacs-bacon.el --- Bacon shell mode  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp interface for the Bacon shell, a Unix shell with integrated
;; C scripting via Crispy.
;;
;; C primitives available (for programmatic use from elisp):
;;   `bacon-start'       -- create and start a BaconShell
;;   `bacon-stop'        -- destroy the BaconShell
;;   `bacon-eval'        -- execute a command string, returns (RC . OUTPUT)
;;   `bacon-eval-c'      -- execute a C code block, returns (RC . OUTPUT)
;;   `bacon-complete'    -- get completion candidates
;;   `bacon-environment' -- get shell environment as alist
;;   `bacon-source'      -- source a file
;;   `bacon-alias'       -- get or set an alias
;;   `bacon-running-p'   -- check if shell is running
;;   `bacon-get-prompt'  -- get configured prompt string
;;
;; Interactive use:
;;   `M-x bacon'         -- open a Bacon shell in vterm
;;
;; From the bacon shell, use the `cmacsgi` builtin (GI over D-Bus):
;;   cmacsgi eval "(+ 1 2)"
;;   cmacsgi find-file /tmp/foo.txt
;;   cmacsgi message "hello from bacon"
;;   cmacsgi require GLib 2.0
;;   cmacsgi call GLib get_user_name
;;   cmacsgi list GLib

;;; Code:

;; Declare vterm variables as special so `let' bindings work
;; correctly under lexical-binding even before vterm is loaded.
(defvar vterm-shell)
(defvar vterm-buffer-name)

(defgroup bacon nil
  "Bacon shell integration."
  :group 'cmacs
  :prefix "bacon-")

(defcustom bacon-buffer-name "*bacon*"
  "Name of the Bacon shell buffer."
  :type 'string
  :group 'bacon)

(defcustom bacon-shell-program (or (executable-find "bacon") "bacon")
  "Path to the bacon shell binary."
  :type 'string
  :group 'bacon)

(defvar bacon--module-dir
  (expand-file-name "../../cmacs/bacon/modules/"
                    (file-name-directory
                     (or load-file-name
                         (locate-library "cmacs-bacon")
                         default-directory)))
  "Directory containing CMacs bacon modules.")

;;; Interactive shell via vterm

;;;###autoload
(defun bacon ()
  "Open (or switch to) the Bacon shell in a vterm buffer.
Starts the CMacs D-Bus service and loads the cmacsgi bacon module
so that `cmacsgi' commands in the shell can call back into CMacs
via GObject Introspection."
  (interactive)
  (require 'vterm)
  ;; Start the D-Bus service so cmacsgi can reach us.
  (let ((dbus-name (cmacs-dbus-start)))
    (setenv "CMACS_DBUS_NAME" dbus-name))
  ;; Set BACON_ARGS so bacon loads the cmacsgi module.
  (let ((module-so (expand-file-name "cmacs_gi.so" bacon--module-dir)))
    (when (file-exists-p module-so)
      (setenv "BACON_ARGS"
              (format "-M %s" (shell-quote-argument
                               (file-name-directory module-so))))))
  (let ((buf (get-buffer bacon-buffer-name)))
    (if (and buf (buffer-live-p buf)
             (get-buffer-process buf))
        (pop-to-buffer buf)
      (when (and buf (buffer-live-p buf))
        (kill-buffer buf))
      (let ((vterm-buffer-name bacon-buffer-name)
            (vterm-shell bacon-shell-program))
        (vterm)))))

;;; Programmatic interface

(defun bacon-shell-send (command)
  "Send COMMAND to the Bacon shell from elisp.
Returns (EXIT-CODE . OUTPUT)."
  (bacon-eval command))

(defun bacon-shell-running-p ()
  "Return non-nil if the Bacon shell backend is active."
  (bacon-running-p))

(provide 'cmacs-bacon)
;;; cmacs-bacon.el ends here
