;;; cmacs-ai-output.el --- Throwaway result windows for AI actions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Where the answer goes.
;;
;; Almost every AI action that does not edit your buffer produces a block
;; of text you want to read, maybe copy a piece of, and then dismiss.
;; That wants a specific kind of window: opened beside what you were
;; reading (or below it, when the frame is too narrow for two columns),
;; showing output as it streams in, easy to select from, and gone again
;; on one keypress.
;;
;; So: `q' or `C-c C-k' closes it, and both cancel an in-flight request
;; rather than leaving a model generating into a window you have stopped
;; caring about.  `w' copies the whole answer.  The buffer is Org, like
;; the rest of cmacs-ai, so headings and code blocks in the reply render
;; as headings and code blocks.
;;
;; The split direction is chosen from the frame, not hardcoded: a wide
;; monitor gets a side-by-side window, a laptop in portrait or a narrow
;; tty gets one underneath.  Both are `display-buffer' actions, so a user
;; who disagrees can override the whole thing through
;; `display-buffer-alist' in the normal way.

;;; Code:

(require 'subr-x)

(declare-function org-mode "org" ())
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))

(defgroup cmacs-ai-output nil
  "Result windows for cmacs-ai actions."
  :group 'cmacs
  :prefix "cmacs-ai-output-")

(defcustom cmacs-ai-output-split-threshold 150
  "Frame width, in columns, at or above which results open side by side.

Below it the result window opens underneath instead.  150 columns is
about where two readable columns of prose stop fitting on one screen;
lower it if you run small fonts, raise it if you like wide code."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-output-width 0.42
  "Fraction of the frame given to a side-by-side result window."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ai-output-height 0.4
  "Fraction of the frame given to a result window opened underneath."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ai-output-select t
  "Whether to select the result window when it opens.
nil leaves point where it was and just shows the result."
  :type 'boolean
  :safe #'booleanp)

;;;; Buffer-local state ------------------------------------------------

(defvar-local cmacs-ai-output--session nil
  "The (CLIENT . SESSION) pair streaming into this buffer, if any.")

(defvar-local cmacs-ai-output--body-start nil
  "Where the answer starts, past the header, for `cmacs-ai-output-copy'.")

(defvar-local cmacs-ai-output--done nil
  "Non-nil once the request finished, failed, or was cancelled.")

;;;; Mode --------------------------------------------------------------

(defvar cmacs-ai-output-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q")       #'cmacs-ai-output-quit)
    (define-key map (kbd "C-c C-k") #'cmacs-ai-output-quit)
    (define-key map (kbd "w")       #'cmacs-ai-output-copy)
    (define-key map (kbd "g")       #'cmacs-ai-output-retry)
    map)
  "Keymap for `cmacs-ai-output-mode'.")

(define-derived-mode cmacs-ai-output-mode org-mode "cmacs-AI-Out"
  "Read-only Org buffer holding the result of an AI action.

\\{cmacs-ai-output-mode-map}"
  ;; Read-only so the single-letter keys are usable, but the text is
  ;; ordinary buffer text: select and copy exactly as anywhere else.
  (setq buffer-read-only t)
  (setq-local org-startup-folded nil)
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

;;;; Window placement --------------------------------------------------

(defun cmacs-ai-output--display-action ()
  "A `display-buffer' action placing results beside or below.

Beside when the frame is at least `cmacs-ai-output-split-threshold'
columns wide, below otherwise.  Uses a side window so the result never
steals the window you were working in and `quit-window' can take the
whole thing away again."
  (if (>= (frame-width) cmacs-ai-output-split-threshold)
      `(display-buffer-in-side-window
        (side . right) (slot . 0)
        (window-width . ,cmacs-ai-output-width)
        (preserve-size . (t . nil)))
    `(display-buffer-in-side-window
      (side . bottom) (slot . 0)
      (window-height . ,cmacs-ai-output-height)
      (preserve-size . (nil . t)))))

;;;; Public API --------------------------------------------------------

(defun cmacs-ai-output-buffer (title &optional subtitle)
  "Create (or reset) a result buffer called TITLE and return it.

SUBTITLE, when given, is shown under the heading -- normally what the
action was asked to do, so a window left open for a while still says what
produced it.  Any request still streaming into a buffer of the same name
is cancelled first."
  (let ((buf (get-buffer-create (format "*cmacs-ai: %s*" title))))
    (with-current-buffer buf
      (cmacs-ai-output--cancel)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless (derived-mode-p 'cmacs-ai-output-mode)
          (cmacs-ai-output-mode))
        (insert (format "#+title: %s\n" title))
        (when (and subtitle (not (string-empty-p subtitle)))
          (insert (format "#+subtitle: %s\n" subtitle)))
        (insert "\n")
        (setq cmacs-ai-output--body-start (point-marker))
        (set-marker-insertion-type cmacs-ai-output--body-start nil)
        (setq cmacs-ai-output--done nil)))
    buf))

(defun cmacs-ai-output-show (buf)
  "Display BUF in a result window, per `cmacs-ai-output-select'."
  (let ((win (display-buffer buf (cmacs-ai-output--display-action))))
    (when (and win cmacs-ai-output-select)
      (select-window win))
    win))

(defun cmacs-ai-output-append (buf text)
  "Append TEXT to result buffer BUF, keeping point at the end if it was.

Called from stream callbacks, which run inside a GLib dispatch: it must
never prompt, never signal into the caller, and never assume the window
still exists."
  (when (and (buffer-live-p buf) text)
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (win (get-buffer-window buf t))
             ;; Only auto-scroll when the user is already at the end;
             ;; scrolling out from under someone reading the top of a long
             ;; answer is infuriating.
             (follow (and win (>= (window-point win) (point-max)))))
        (save-excursion
          (goto-char (point-max))
          (insert text))
        (when follow
          (set-window-point win (point-max)))))))

(defun cmacs-ai-output-attach-session (buf session)
  "Record SESSION as the request streaming into BUF, so `q' can cancel it."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq cmacs-ai-output--session session))))

(defun cmacs-ai-output-finish (buf &optional error-message)
  "Mark BUF's request finished, noting ERROR-MESSAGE when it failed."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when error-message
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (format "\n\n* Failed\n%s\n" error-message)))))
      (setq cmacs-ai-output--done t)
      (cmacs-ai-output--release))))

;;;; Cancellation ------------------------------------------------------

(defun cmacs-ai-output--release ()
  "Free the session attached to this buffer, if any."
  (when cmacs-ai-output--session
    (when (fboundp 'cmacs-ai-free-session)
      (ignore-errors (cmacs-ai-free-session cmacs-ai-output--session)))
    (setq cmacs-ai-output--session nil)))

(defun cmacs-ai-output--cancel ()
  "Cancel any in-flight request streaming into this buffer."
  (when (and cmacs-ai-output--session (not cmacs-ai-output--done))
    (when (fboundp 'cmacs-ai-chat-cancel)
      (ignore-errors (cmacs-ai-chat-cancel (cdr cmacs-ai-output--session))))
    (setq cmacs-ai-output--done t))
  (cmacs-ai-output--release))

;;;; Commands ----------------------------------------------------------

(defun cmacs-ai-output-quit ()
  "Cancel any request still running and close the result window.

Bound to both `q' and `C-c C-k'.  Cancelling is the point: a result
window you have dismissed is one you have stopped reading, and a model
that keeps generating into it is spending money on nobody."
  (interactive)
  (cmacs-ai-output--cancel)
  (quit-window))

(defun cmacs-ai-output-copy ()
  "Copy the answer (without the header) to the kill ring."
  (interactive)
  (let ((beg (or (and cmacs-ai-output--body-start
                      (marker-position cmacs-ai-output--body-start))
                 (point-min))))
    (copy-region-as-kill beg (point-max))
    (message "cmacs-ai: copied %d characters" (- (point-max) beg))))

(defvar-local cmacs-ai-output--retry nil
  "A closure re-running whatever produced this buffer, for `g'.")

(defun cmacs-ai-output-set-retry (buf fn)
  "Record FN as the way to re-run whatever produced BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf (setq cmacs-ai-output--retry fn))))

(defun cmacs-ai-output-retry ()
  "Run the action that produced this buffer again."
  (interactive)
  (if (functionp cmacs-ai-output--retry)
      (funcall cmacs-ai-output--retry)
    (user-error "cmacs-ai: nothing to re-run here")))

;;;; Teardown ----------------------------------------------------------

(defun cmacs-ai-output--kill-hook ()
  "Cancel a request whose result buffer is being killed."
  (when (derived-mode-p 'cmacs-ai-output-mode)
    (cmacs-ai-output--cancel)))

(add-hook 'kill-buffer-hook #'cmacs-ai-output--kill-hook)

(provide 'cmacs-ai-output)

;;; cmacs-ai-output.el ends here
