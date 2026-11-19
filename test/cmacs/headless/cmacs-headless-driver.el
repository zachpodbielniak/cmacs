;;; cmacs-headless-driver.el --- helpers for headless GUI scenarios  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Loaded by admin/cmacs-headless.sh before a scenario file, inside a
;; cmacs whose only display is a private headless gowl.  A scenario is a
;; plain Elisp file that drives the editor and calls
;; `cmacs-headless-shot' at each point worth seeing; it ends with
;; `cmacs-headless-done'.  Steps are run from a timer chain
;; (`cmacs-headless-steps') so redisplay happens between them -- a
;; screenshot taken in the same command as the change would show the
;; frame before it.

;;; Code:

(require 'cl-lib)

;; The tree's own Lisp, whatever -Q leaves on `load-path'.
(add-to-list 'load-path (expand-file-name "../../../lisp/cmacs"
                                          (file-name-directory
                                           (or load-file-name buffer-file-name))))

(defvar cmacs-headless-out (or (getenv "CMACS_HEADLESS_OUT") temporary-file-directory)
  "Directory screenshots are written to.")

(defvar cmacs-headless-step-delay 0.6
  "Seconds between scenario steps, so redisplay and async work land.")

(defvar cmacs-headless-failed nil
  "Non-nil once a step signalled; the run exits 1.")

(defun cmacs-headless-setup-frame ()
  "Make the frame fill the headless output, with a legible theme and font."
  (load-theme 'modus-vivendi t)
  (set-face-attribute 'default nil :height 130)
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (let ((w (string-to-number (or (getenv "CMACS_HEADLESS_WIDTH") "1920")))
        (h (string-to-number (or (getenv "CMACS_HEADLESS_HEIGHT") "1080"))))
    (set-frame-size (selected-frame) (- w 20) (- h 40) t)
    (set-frame-position (selected-frame) 0 0)))

(defun cmacs-headless-shot (name)
  "Screenshot the headless output to NAME.png in `cmacs-headless-out'."
  (redisplay t)
  ;; pgtk hands the frame to the compositor asynchronously: give the
  ;; commit a moment, or grim captures the frame before this one.
  (sit-for 0.35)
  (redisplay t)
  (let ((file (expand-file-name (concat name ".png") cmacs-headless-out)))
    (unless (eq 0 (call-process "grim" nil nil nil file))
      (error "grim failed for %s" file))
    (message "headless: wrote %s" file)
    file))

(defun cmacs-headless-log (fmt &rest args)
  "Log FMT/ARGS to stderr (a GUI Emacs sends `message' only to *Messages*)."
  (princ (concat (apply #'format fmt args) "\n") #'external-debugging-output))

(defvar cmacs-headless--menu nil "Keymap the F9 command pops.")
(defvar cmacs-headless--menu-done nil "Set once that menu has closed.")

(defun cmacs-headless--pop-menu ()
  "Pop `cmacs-headless--menu' (bound to F9 for the duration of a shot)."
  (interactive)
  (ignore-errors (cmacs-menu-popup-keymap cmacs-headless--menu
                                          (cmacs-media-menu-position)))
  (setq cmacs-headless--menu-done t))

(defun cmacs-headless-shot-menu (name keymap &optional keys)
  "Pop menu KEYMAP for real and screenshot it as NAME.png.
Returns `wait' until the menu has been shot and closed, so use it as
the whole body of a step.

A menu popped from a timer has no trigger event, so GTK cannot grab
the keyboard and nothing can navigate or close it.  So the menu is
popped by a KEY: an outside process presses F9 (bound to a command
that pops KEYMAP), types KEYS (wtype key names, e.g. (\"Down\" \"Right\")
to open a submenu), runs grim, and Escapes the menu."
  (require 'cmacs-menu)
  (cond
   ((and cmacs-headless--menu-done (eq cmacs-headless--menu keymap))
    (setq cmacs-headless--menu nil cmacs-headless--menu-done nil)
    (global-unset-key (kbd "<f9>"))
    (message "headless: wrote %s" (expand-file-name (concat name ".png") cmacs-headless-out))
    nil)
   ((eq cmacs-headless--menu keymap) 'wait)
   (t
    (let* ((file (expand-file-name (concat name ".png") cmacs-headless-out))
           (typing (mapconcat (lambda (k) (format "wtype -k %s; sleep 0.3; " k)) keys ""))
           (script (format "sleep 0.3; wtype -k F9; sleep 0.8; %sgrim %s; sleep 0.2; wtype -k Escape; sleep 0.2; wtype -k Escape; sleep 0.2; wtype -k Escape"
                           typing (shell-quote-argument file))))
      (setq cmacs-headless--menu keymap cmacs-headless--menu-done nil)
      (global-set-key (kbd "<f9>") #'cmacs-headless--pop-menu)
      (start-process "headless-menu-shot" nil "sh" "-c" script)
      'wait))))

(defun cmacs-headless-shot-menu-final (name keymap &optional hover)
  "Pop menu KEYMAP, screenshot it as NAME.png, and end the run.
pgtk anchors popups on the last real mouse click, which a headless
output never has, so the menu cannot grab the keyboard and nothing can
close it -- this is therefore the LAST step of a scenario.  HOVER, a
cons (X . Y) of layout pixels, warps the pointer there first through
gowl's JSON-RPC, which opens a submenu the way a user's hover does.  The
outside process marks the run as a deliberate finish and stops Emacs."
  (require 'cmacs-menu)
  (let* ((file (expand-file-name (concat name ".png") cmacs-headless-out))
         (sock (expand-file-name "gowl.sock" (getenv "XDG_RUNTIME_DIR")))
         (warp (if hover
                   (format "printf '%%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"pointer.warp\",\"params\":{\"x\":%d,\"y\":%d}}' | socat - UNIX-CONNECT:%s >/dev/null; sleep 0.9; "
                           (car hover) (cdr hover) (shell-quote-argument sock))
                 ""))
         (script (format "sleep 1.2; %sgrim %s; touch %s; kill -TERM %d"
                         warp (shell-quote-argument file)
                         (shell-quote-argument (expand-file-name ".final-ok" cmacs-headless-out))
                         (emacs-pid))))
    ;; The popup blocks redisplay: draw the buffer it belongs to first.
    (redisplay t)
    (sit-for 0.5)
    (redisplay t)
    (start-process "headless-menu-shot" nil "sh" "-c" script)
    (cmacs-menu-popup-keymap keymap (cmacs-media-menu-position))
    nil))

(defun cmacs-headless-done ()
  "End the run: exit 0, or 1 if any step failed (dumping *Messages*)."
  (when cmacs-headless-failed
    (with-current-buffer (messages-buffer)
      (cmacs-headless-log "---- *Messages* ----\n%s"
                          (buffer-substring-no-properties
                           (max (point-min) (- (point-max) 4000)) (point-max)))))
  (kill-emacs (if cmacs-headless-failed 1 0)))

(defun cmacs-headless-steps (&rest steps)
  "Run STEPS (functions) one per `cmacs-headless-step-delay', then exit.
A step returning the symbol `wait' is retried until it returns
something else (for async results), up to 60 seconds."
  (let ((deadline nil) (total (length steps)))
    (cl-labels
        ((next ()
           (if (null steps)
               (cmacs-headless-done)
             (let ((r (condition-case err
                          ;; Timers run in whatever buffer is current;
                          ;; a step means the one on screen.
                          (with-current-buffer (window-buffer (selected-window))
                            (funcall (car steps)))
                        (error
                         (setq cmacs-headless-failed t)
                         (cmacs-headless-log "headless: step %d failed: %S"
                                             (- total (length steps)) err)
                         nil))))
               (cond
                ((and (eq r 'wait)
                      (or (null deadline) (< (float-time) deadline)))
                 (unless deadline (setq deadline (+ (float-time) 60))))
                (t
                 (when (eq r 'wait)
                   (setq cmacs-headless-failed t)
                   (cmacs-headless-log "headless: step %d timed out"
                                       (- total (length steps))))
                 (setq deadline nil)
                 (pop steps)))
               (run-at-time cmacs-headless-step-delay nil #'next)))))
      (run-at-time 1.0 nil #'next))))

(add-hook 'emacs-startup-hook #'cmacs-headless-setup-frame)

(provide 'cmacs-headless-driver)
;;; cmacs-headless-driver.el ends here
