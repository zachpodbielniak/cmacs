;;; cmacs-gowl-switcher.el --- Pick a window, with the compositor as the preview -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `switcher' plugin draws a strip of live window previews and
;; will take its orders from anywhere: the held-modifier alt-tab it
;; implements itself, or the `switcher-*' commands.  This file uses the
;; second door.
;;
;; THE POINT IS THE COMBINATION.  `completing-read' is the best
;; list-of-choices widget on the machine -- it has your history, your
;; completion style, your embark actions -- and the one thing it cannot
;; do is show you what a window LOOKS like.  The compositor can do
;; nothing but that.  So `cmacs-gowl-switch-window' runs an ordinary
;; completing-read while the strip follows the selection underneath it,
;; and picking a candidate lands on the window you were looking at.
;;
;; The preview is best-effort by design.  Reading "the candidate the user
;; is currently on" is not part of the completion API, so it is done
;; through whichever front end is installed and simply does not happen
;; when none of them is recognised.  Losing the preview costs a picture;
;; it never costs the command, which still selects the window you chose.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-list-clients "cmacs-gowl")
(declare-function gowl-client-info "cmacs-gowl")
(declare-function gowl-focus-client "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")

(defgroup cmacs-gowl-switcher nil
  "Window switching through gowl's preview strip."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-switcher-")

(defcustom cmacs-gowl-switcher-preview t
  "Whether `cmacs-gowl-switch-window' drives the compositor's strip.

With this off the command is a plain completing-read over the window
list, which is also what happens when the strip is unavailable -- under
a renderer whose GL context the plugin cannot borrow, for instance."
  :type 'boolean
  :group 'cmacs-gowl-switcher)

(defcustom cmacs-gowl-switcher-format "%-16s  %s"
  "Format for a candidate: the app id, then the title."
  :type 'string
  :group 'cmacs-gowl-switcher)

(defvar cmacs-gowl-switcher--candidates nil
  "Alist of candidate string to (INDEX . CLIENT) for the live read.")

(defvar cmacs-gowl-switcher--previewing nil
  "Non-nil while the compositor strip is following the minibuffer.")

(defvar cmacs-gowl-switcher--last nil
  "Last index sent to the compositor, so repeats are not re-sent.")

;;; Talking to the plugin

(defun cmacs-gowl-switcher--command (line)
  "Run LINE as a gowl command, returning its reply or nil.
Errors are swallowed: every caller here treats the strip as optional."
  (when (and (fboundp 'gowl-run-command) (fboundp 'gowl-running-p)
             (gowl-running-p))
    (ignore-errors (gowl-run-command line))))

(defun cmacs-gowl-switcher--ok (reply)
  "Non-nil when REPLY is a success line from the plugin."
  (and (stringp reply) (string-prefix-p "OK" reply)))

;;;###autoload
(defun cmacs-gowl-switcher-open ()
  "Open the compositor's window switcher."
  (interactive)
  (cmacs-gowl-switcher--command "switcher"))

;;;###autoload
(defun cmacs-gowl-switcher-next ()
  "Advance the compositor's window switcher, opening it if needed."
  (interactive)
  (cmacs-gowl-switcher--command "switcher-next"))

;;;###autoload
(defun cmacs-gowl-switcher-previous ()
  "Step the compositor's window switcher back."
  (interactive)
  (cmacs-gowl-switcher--command "switcher-prev"))

;;;###autoload
(defun cmacs-gowl-switcher-commit ()
  "Close the switcher, focusing the card it is showing."
  (interactive)
  (cmacs-gowl-switcher--command "switcher-close"))

;;;###autoload
(defun cmacs-gowl-switcher-cancel ()
  "Close the switcher without changing focus."
  (interactive)
  (cmacs-gowl-switcher--command "switcher-close cancel"))

;;; Reading the candidate under point

(defun cmacs-gowl-switcher--current-candidate ()
  "The candidate the minibuffer is currently on, or nil.

There is no portable way to ask this: completion front ends keep it in
their own state, so each one is asked in turn and an unrecognised one
simply yields nil.  That is the whole failure mode -- no preview, and a
command that still works."
  (cond
   ((and (bound-and-true-p vertico--index)
         (>= vertico--index 0)
         (fboundp 'vertico--candidate))
    (ignore-errors (vertico--candidate)))
   ((and (bound-and-true-p ivy-mode) (fboundp 'ivy-state-current))
    (ignore-errors (ivy-state-current ivy-last)))
   ((bound-and-true-p icomplete-mode)
    (car (completion-all-sorted-completions)))
   ((bound-and-true-p selectrum-active-p)
    (ignore-errors (selectrum-get-current-candidate)))
   (t
    ;; Bare completing-read shows no selection to follow, so the closest
    ;; honest answer is the unique completion of what has been typed.
    (let ((all (ignore-errors (completion-all-sorted-completions))))
      (and (= (safe-length all) 1) (car all))))))

(defun cmacs-gowl-switcher--follow ()
  "Move the compositor's strip to the candidate under point."
  (when cmacs-gowl-switcher--previewing
    (let* ((candidate (cmacs-gowl-switcher--current-candidate))
           (entry (and candidate
                       (assoc candidate cmacs-gowl-switcher--candidates)))
           (index (car-safe (cdr entry))))
      (when (and index (not (eql index cmacs-gowl-switcher--last)))
        (setq cmacs-gowl-switcher--last index)
        (cmacs-gowl-switcher--command
         (format "switcher-select %d" index))))))

;;; The candidate list

(defun cmacs-gowl-switcher--label (client)
  "A display string for CLIENT."
  (let* ((info (ignore-errors (gowl-client-info client)))
         (app (or (alist-get 'app-id info) ""))
         (title (or (alist-get 'title info) "")))
    (format cmacs-gowl-switcher-format app title)))

(defun cmacs-gowl-switcher--collect ()
  "Build the candidate alist from the plugin's own card order.

The plugin lists its cards most-recently-focused first, which is the
order that makes the first candidate the window you were in before this
one.  Falling back to `gowl-list-clients' loses that ordering, so it is
only used when the strip is not up."
  (let ((listing (cmacs-gowl-switcher--command "switcher-list"))
        (result nil))
    (if (and (stringp listing) (not (string-prefix-p "ERROR" listing)))
        (dolist (line (split-string listing "\n" t) (nreverse result))
          (let ((fields (split-string line "\t")))
            (when (= (length fields) 3)
              (push (cons (format cmacs-gowl-switcher-format
                                  (nth 1 fields) (nth 2 fields))
                          (cons (string-to-number (nth 0 fields)) nil))
                    result))))
      (let ((index 0))
        (dolist (client (ignore-errors (gowl-list-clients))
                        (nreverse result))
          (push (cons (cmacs-gowl-switcher--label client)
                      (cons index client))
                result)
          (setq index (1+ index)))))))

;;;###autoload
(defun cmacs-gowl-switch-window ()
  "Pick a window by name, with the compositor previewing the choice.

Opens gowl's window switcher and reads a candidate in the minibuffer,
moving the strip to follow the selection.  Choosing focuses that window;
quitting leaves focus where it was.

Works without the strip too: if the plugin is not loaded, or the
renderer is one whose context it cannot borrow, this is an ordinary
completing-read over the window list."
  (interactive)
  (let* ((opened (and cmacs-gowl-switcher-preview
                      (cmacs-gowl-switcher--ok
                       (cmacs-gowl-switcher--command "switcher"))))
         (cmacs-gowl-switcher--candidates (cmacs-gowl-switcher--collect))
         (cmacs-gowl-switcher--previewing opened)
         (cmacs-gowl-switcher--last nil)
         (chosen nil))
    (unless cmacs-gowl-switcher--candidates
      (when opened (cmacs-gowl-switcher-cancel))
      (user-error "No windows to switch to"))
    (unwind-protect
        (minibuffer-with-setup-hook
            (lambda ()
              (when cmacs-gowl-switcher--previewing
                (add-hook 'post-command-hook
                          #'cmacs-gowl-switcher--follow nil t)))
          (setq chosen
                (completing-read
                 "Window: "
                 (mapcar #'car cmacs-gowl-switcher--candidates)
                 nil t)))
      ;; The strip must come down on EVERY path, including a quit: it is
      ;; an opaque sheet over the whole output, and one left behind takes
      ;; the desktop with it.
      (when opened
        (let ((entry (and chosen
                          (assoc chosen cmacs-gowl-switcher--candidates))))
          (if entry
              (progn
                (cmacs-gowl-switcher--command
                 (format "switcher-select %d" (car (cdr entry))))
                (cmacs-gowl-switcher-commit))
            (cmacs-gowl-switcher-cancel)))))
    ;; With no strip, nothing has focused the window yet.
    (when (and chosen (not opened))
      (let ((client (cdr (cdr (assoc chosen
                                     cmacs-gowl-switcher--candidates)))))
        (when client (ignore-errors (gowl-focus-client client)))))
    chosen))

;;;###autoload
(defun cmacs-gowl-expo ()
  "Show every tag at once, as a grid of live thumbnails."
  (interactive)
  (cmacs-gowl-switcher--command "expo"))

(provide 'cmacs-gowl-switcher)
;;; cmacs-gowl-switcher.el ends here
