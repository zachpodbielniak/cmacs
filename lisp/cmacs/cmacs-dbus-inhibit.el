;;; cmacs-dbus-inhibit.el --- Block sleep / idle via systemd-logind  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 5 sleep / idle inhibitor.  Wraps
;; org.freedesktop.login1.Manager.Inhibit so cmacs can:
;;
;;   - Block the system from suspending while there are unsaved
;;     buffers (delay-suspend).
;;   - Block the screen-locker while a long compile is running
;;     (block-idle).
;;
;; Inhibitors are released by closing the fd login1 returns.  The
;; wrapper here owns the fd via Emacs's `dbus-call-method' which
;; internally dispatches through file-descriptor passing.

;;; Code:

(require 'dbus)
(require 'cl-lib)

(defcustom cmacs-dbus-inhibit-suspend-when-modified nil
  "Non-nil to block system suspend while any buffer is modified."
  :type 'boolean :group 'cmacs-dbus)

(defcustom cmacs-dbus-inhibit-idle-during-compile nil
  "Non-nil to block screen-locker idle while compilation is running."
  :type 'boolean :group 'cmacs-dbus)

(defvar cmacs-dbus-inhibit--active-fds nil
  "Alist of (TAG . FD) for currently-held inhibitors.")

(defun cmacs-dbus-inhibit (what who why mode)
  "Take an inhibitor lock from systemd-logind.
WHAT is a colon-separated list of: shutdown, sleep, idle,
handle-power-key, handle-suspend-key, handle-hibernate-key,
handle-lid-switch.  WHO is the application name (string).  WHY is
the human-readable reason (string).  MODE is `block' or `delay'.

Returns the inhibitor file descriptor.  Closing it releases the
lock.  Stores the fd in `cmacs-dbus-inhibit--active-fds' under TAG
keyed by WHAT for later release."
  (let ((fd (dbus-call-method
             :system "org.freedesktop.login1"
             "/org/freedesktop/login1"
             "org.freedesktop.login1.Manager"
             "Inhibit"
             what who why mode)))
    (push (cons what fd) cmacs-dbus-inhibit--active-fds)
    fd))

(defun cmacs-dbus-inhibit-release (what)
  "Release the inhibitor previously taken for WHAT.
Closes the held fd; logind drops the lock."
  (when-let ((entry (assoc what cmacs-dbus-inhibit--active-fds)))
    (ignore-errors (delete-process (cdr entry)))
    (setq cmacs-dbus-inhibit--active-fds
          (delq entry cmacs-dbus-inhibit--active-fds))))

(defun cmacs-dbus-inhibit--update-suspend ()
  "Take or release the suspend inhibitor based on buffer modification."
  (when cmacs-dbus-inhibit-suspend-when-modified
    (let ((any-modified (cl-some (lambda (b)
                                   (and (buffer-file-name b)
                                        (buffer-modified-p b)))
                                 (buffer-list)))
          (held (assoc "sleep" cmacs-dbus-inhibit--active-fds)))
      (cond
       ((and any-modified (not held))
        (cmacs-dbus-inhibit "sleep" "cmacs"
                            "Unsaved buffers" "delay"))
       ((and (not any-modified) held)
        (cmacs-dbus-inhibit-release "sleep"))))))

;;;###autoload
(define-minor-mode cmacs-dbus-inhibit-mode
  "Global mode for D-Bus-driven sleep/idle inhibition.
While enabled, hooks watch for unsaved buffers / running compiles
and take logind inhibitor locks accordingly.  See
`cmacs-dbus-inhibit-suspend-when-modified' and
`cmacs-dbus-inhibit-idle-during-compile' for the policies."
  :global t :group 'cmacs-dbus
  (if cmacs-dbus-inhibit-mode
      (progn
        (add-hook 'after-change-functions
                  (lambda (&rest _) (cmacs-dbus-inhibit--update-suspend)))
        (add-hook 'after-save-hook #'cmacs-dbus-inhibit--update-suspend)
        (when cmacs-dbus-inhibit-idle-during-compile
          (add-hook 'compilation-start-hook
                    (lambda (_p)
                      (cmacs-dbus-inhibit "idle" "cmacs"
                                          "compilation in progress"
                                          "block")))
          (add-hook 'compilation-finish-functions
                    (lambda (_b _msg)
                      (cmacs-dbus-inhibit-release "idle")))))
    (mapc #'cmacs-dbus-inhibit-release
          (mapcar #'car cmacs-dbus-inhibit--active-fds))))

(provide 'cmacs-dbus-inhibit)
;;; cmacs-dbus-inhibit.el ends here
