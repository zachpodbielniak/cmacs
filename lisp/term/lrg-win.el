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

;;; Frame geometry --------------------------------------------------
;;
;; `frame-geometry'/`frame-edges' (frame.el) dispatch per backend.  The
;; pgtk implementations read GTK widgets an lrg frame doesn't have, and the
;; tty fallback aborts on a non-tty frame (FRAME_TTY -> emacs_abort) -- which
;; crashed cmacs when e.g. corfu asked an lrg child frame for its edges.  lrg
;; frames carry real pixel geometry, so derive edges/geometry from the generic
;; frame fields here and let frame.el route 'lrg through these.

(defun cmacs-lrg--frame-left-top (frame)
  "Return (LEFT . TOP), FRAME's pixel position, for geometry computations.
Handles the integer and (+ N)/(- N) forms of the `left'/`top' frame
parameters; a top-level lrg frame reports (0 . 0) (its OS-window position is
not tracked, matching the tty geometry convention)."
  (let ((left (frame-parameter frame 'left))
        (top  (frame-parameter frame 'top)))
    (cons
     (cond ((integerp left) left)
           ((and (consp left) (integerp (cadr left)))
            (if (eq (car left) '-) (- (cadr left)) (cadr left)))
           (t 0))
     (cond ((integerp top) top)
           ((and (consp top) (integerp (cadr top)))
            (if (eq (car top) '-) (- (cadr top)) (cadr top)))
           (t 0)))))

(defun cmacs-lrg-frame-edges (&optional frame type)
  "Return the edges of lrg FRAME as (LEFT TOP RIGHT BOTTOM).
TYPE is `outer-edges', `native-edges' (the default) or `inner-edges', as for
`frame-edges'.  Outer and native edges coincide (lrg draws no window-manager
border); inner edges inset by the internal border width."
  (let* ((frame (window-normalize-frame frame))
         (lt   (cmacs-lrg--frame-left-top frame))
         (left (car lt)) (top (cdr lt))
         (w    (frame-pixel-width frame))
         (h    (frame-pixel-height frame))
         (ibw  (or (frame-parameter frame 'internal-border-width) 0)))
    (if (eq type 'inner-edges)
        (list (+ left ibw) (+ top ibw) (- (+ left w) ibw) (- (+ top h) ibw))
      (list left top (+ left w) (+ top h)))))

(defun cmacs-lrg-frame-geometry (&optional frame)
  "Return geometric attributes of lrg FRAME (see `frame-geometry').
Computed from the frame's generic pixel geometry; lrg has no external
border, title bar, menu bar or tool bar."
  (let* ((frame (window-normalize-frame frame))
         (lt   (cmacs-lrg--frame-left-top frame))
         (left (car lt)) (top (cdr lt))
         (w    (frame-pixel-width frame))
         (h    (frame-pixel-height frame))
         (ibw  (or (frame-parameter frame 'internal-border-width) 0)))
    (list (cons 'outer-position (cons left top))
          (cons 'outer-size (cons w h))
          (cons 'outer-border-width 0)
          (cons 'external-border-size (cons 0 0))
          (cons 'title-bar-size (cons 0 0))
          (cons 'menu-bar-external nil)
          (cons 'menu-bar-size (cons 0 0))
          (cons 'tab-bar-size (cons 0 0))
          (cons 'tool-bar-external nil)
          (cons 'tool-bar-position 'top)
          (cons 'tool-bar-size (cons 0 0))
          (cons 'internal-border-width ibw))))

(provide 'lrg-win)
(provide 'term/lrg-win)

;;; lrg-win.el ends here
