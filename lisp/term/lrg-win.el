;;; lrg-win.el --- lrg (libregnum/raylib) window-system support  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Lisp glue for the independent libregnum/raylib display backend
;; (output_lrg), a peer to pgtk.  Selected with `emacs --lrg[=MODE]' or by
;; setting `initial-window-system' to `lrg'.  Plain `emacs' still uses pgtk.

;;; Code:

;; cl-defmethod comes from the preloaded cl-generic; cl-lib is only needed at
;; compile time (cl-assert, cl-letf).  A runtime (require 'cl-lib) is rejected
;; while dumping, so keep it compile-only.  frame/faces are already preloaded.
(eval-when-compile (require 'cl-lib))

(declare-function lrg-open-connection "cmacs-lrgfns.c"
                  (display &optional xrm-string must-succeed))
(declare-function lrg-create-frame "cmacs-lrgfns.c" (params))
(declare-function lrg-display-list "cmacs-lrgfns.c" ())
(declare-function x-handle-args "common-win" (args))
(declare-function x-create-frame-with-faces "faces" (&optional parameters))
(declare-function create-default-fontset "fontset" ())
(declare-function create-fontset-from-fontset-spec "fontset" (spec &optional style-variant))

(defvar x-display-name)
(defvar x-command-line-resources)
(defvar x-resource-name)
(defvar standard-fontset-spec)

(defvar lrg-initialized nil
  "Non-nil once the lrg window system has been initialized.")

(defgroup cmacs-lrg nil
  "The libregnum/raylib display backend (output_lrg)."
  :group 'environment)

(defcustom cmacs-lrg-render-mode "2d"
  "Render mode for the lrg backend.
Only \"2d\" is implemented; \"3d\" and \"3dvr\" are reserved.  The
`--lrg=MODE' command-line flag overrides this."
  :type '(choice (const "2d") (const "3d") (const "3dvr"))
  :group 'cmacs-lrg
  :version "31.1")

(cl-defmethod window-system-initialization (&context (window-system lrg)
                                            &optional display)
  "Initialize the lrg window system.
DISPLAY is the name of the display Emacs should connect to."
  (cl-assert (not lrg-initialized))

  (setq command-line-args (x-handle-args command-line-args))

  (when (boundp 'x-resource-name)
    (unless (stringp x-resource-name)
      (let (i)
        (setq x-resource-name (copy-sequence invocation-name))
        (while (setq i (string-match "[.*]" x-resource-name))
          (aset x-resource-name i ?-)))))

  ;; Fontsets: lrg reuses Emacs's FreeType/Cairo font machinery.
  (create-default-fontset)
  (condition-case err
      (create-fontset-from-fontset-spec standard-fontset-spec t)
    (error (display-warning
            'initialization
            (format "Creation of the standard fontset failed: %s" err)
            :error)))

  (lrg-open-connection (or display "lrg")
                       (and (boundp 'x-command-line-resources)
                            x-command-line-resources)
                       (= (length (frame-list)) 0))

  ;; No GUI menus/dialogs yet (Phase 7 interim): route dialogs to the
  ;; minibuffer and use `tmm-menubar' / F10 for keyboard menu access.
  (setq use-dialog-box nil
        use-file-dialog nil)

  (setq lrg-initialized t))

(cl-defmethod handle-args-function (args &context (window-system lrg))
  (x-handle-args args))

(cl-defmethod frame-creation-function (params &context (window-system lrg))
  ;; Reuse the generic face-aware frame builder, but redirect the actual
  ;; frame creation to lrg-create-frame (x-create-frame belongs to pgtk in
  ;; this build).
  (cl-letf (((symbol-function 'x-create-frame) #'lrg-create-frame))
    (x-create-frame-with-faces params)))

;; Clipboard/selection.  graylib (raylib/GLFW) exposes a single system
;; clipboard, which maps to Emacs's CLIPBOARD selection; PRIMARY and non-text
;; targets are not supported by the windowing layer, so they are no-ops.
(declare-function lrg-get-clipboard "cmacs-lrgterm.c" ())
(declare-function lrg-set-clipboard "cmacs-lrgterm.c" (text))

(cl-defmethod gui-backend-get-selection (selection-symbol target-type
                                         &context (window-system lrg))
  (when (and (eq selection-symbol 'CLIPBOARD)
             (memq target-type '(STRING UTF8_STRING TEXT text/plain
                                 text/plain\;charset=utf-8)))
    (let ((s (lrg-get-clipboard)))
      (and s (> (length s) 0) s))))

(cl-defmethod gui-backend-set-selection (selection value
                                         &context (window-system lrg))
  (when (and (eq selection 'CLIPBOARD) (stringp value))
    (lrg-set-clipboard value))
  ;; Returning non-nil tells the selection machinery we took ownership.
  (eq selection 'CLIPBOARD))

(cl-defmethod gui-backend-selection-owner-p (selection
                                             &context (window-system lrg))
  ;; GLFW cannot report clipboard ownership; assume we own CLIPBOARD if it
  ;; currently holds text.
  (and (eq selection 'CLIPBOARD)
       (let ((s (lrg-get-clipboard))) (and s (> (length s) 0) t))))

(cl-defmethod gui-backend-selection-exists-p (selection
                                              &context (window-system lrg))
  (and (eq selection 'CLIPBOARD)
       (let ((s (lrg-get-clipboard))) (and s (> (length s) 0) t))))

(provide 'lrg-win)
(provide 'term/lrg-win)

;;; lrg-win.el ends here
