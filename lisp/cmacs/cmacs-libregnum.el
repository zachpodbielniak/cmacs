;;; cmacs-libregnum.el --- libregnum 3D scene buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Major mode + entry points for cmacs-libregnum, the libregnum-
;; backed 3D scene subsystem.  Each `cmacs-libregnum-mode' buffer
;; owns a view that renders a libregnum scene into the full window
;; area via the C bridge in cmacs/libregnum/.

;;; Code:

(require 'subr-x)

(defgroup cmacs-libregnum nil
  "libregnum 3D scene subsystem for cmacs."
  :group 'cmacs
  :prefix "cmacs-libregnum-")

(defcustom cmacs-libregnum-default-size '(800 . 500)
  "Default (WIDTH . HEIGHT) pixels for a fresh libregnum view."
  :type '(cons integer integer)
  :group 'cmacs-libregnum)

(defcustom cmacs-libregnum-clear-color "#101015"
  "Background colour for libregnum scenes (informational; the C side
holds the active value)."
  :type 'color
  :group 'cmacs-libregnum)

(declare-function cmacs-libregnum-supported-p "cmacs-libregnum-defuns.c" ())
(declare-function cmacs-libregnum-attach "cmacs-libregnum-defuns.c"
                  (buffer &optional width height))
(declare-function cmacs-libregnum-detach "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-attached-p "cmacs-libregnum-defuns.c" (buffer))
(declare-function cmacs-libregnum-resize "cmacs-libregnum-defuns.c"
                  (buffer width height))
(declare-function cmacs-libregnum-redraw "cmacs-libregnum-defuns.c" (buffer))

;;;; Mode -------------------------------------------------------------

(defvar cmacs-libregnum-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "q")       #'kill-this-buffer)
    (define-key m (kbd "g r")     #'cmacs-libregnum-redraw-current)
    (define-key m (kbd "g g")     #'cmacs-libregnum-redraw-current)
    m)
  "Keymap for `cmacs-libregnum-mode'.")

(defun cmacs-libregnum-redraw-current ()
  "Force a redraw of the current libregnum buffer's scene."
  (interactive)
  (when (cmacs-libregnum-attached-p (current-buffer))
    (cmacs-libregnum-redraw (current-buffer))))

(defun cmacs-libregnum--on-kill ()
  "Tear down the view when the buffer is killed."
  (when (cmacs-libregnum-attached-p (current-buffer))
    (cmacs-libregnum-detach (current-buffer))))

;;;###autoload
(define-derived-mode cmacs-libregnum-mode special-mode "cmacs-3D"
  "Major mode for cmacs-libregnum 3D scene buffers.

The buffer IS the 3D view: cmacs's pgtk_handle_draw blits the
view's BGRA framebuffer across the window's text area every
redisplay.  Buffer text is the YAML serialisation of the scene
state (camera, layout options, selection).

\\{cmacs-libregnum-mode-map}"
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format
              '("%e" mode-line-front-space mode-line-buffer-identification
                "  cmacs-libregnum-mode"))
  (add-hook 'kill-buffer-hook #'cmacs-libregnum--on-kill nil t)
  ;; Attach the view (idempotent).
  (let ((sz cmacs-libregnum-default-size))
    (cmacs-libregnum-attach (current-buffer) (car sz) (cdr sz))))

;;;; Entry points ----------------------------------------------------

;;;###autoload
(defun cmacs-libregnum-demo ()
  "Open a blank cmacs-libregnum scene buffer (smoke test)."
  (interactive)
  (unless (cmacs-libregnum-supported-p)
    (user-error "cmacs-libregnum not built; reconfigure with \
--with-cmacs-libregnum"))
  (let ((buf (get-buffer-create "*cmacs-libregnum demo*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "# cmacs-libregnum demo scene\n")
        (insert "# (whole window is the 3D view; this text is hidden\n")
        (insert "#  behind the BGRA blit)\n"))
      (cmacs-libregnum-mode))
    (switch-to-buffer buf)
    buf))

(provide 'cmacs-libregnum)
;;; cmacs-libregnum.el ends here
