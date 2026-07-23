;;; cmacs-lsp.el --- eglot client for the in-binary --cmacs-lsp servers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; cmacs compiles LSP language servers into the emacs binary itself
;; (--with-cmacs-lsp): `emacs --cmacs-lsp LANG' speaks JSON-RPC over
;; stdio with no editor and no Lisp VM (see doc_org/cmacs/lsp.org and
;; cmacs/lsp/).  This file is the generic client half: it spawns a
;; server as a subprocess call back to THIS running binary -- the
;; /proc/self/exe model, spelled portably with `invocation-directory'
;; -- registers major modes with eglot, and auto-starts on file visit.
;; Per-language glue lives with each subsystem; the calculator's `.calc'
;; sheets register the "gnucalc" server at the bottom of
;; cmacs-calculator-sheet.el.

;;; Code:

(defgroup cmacs-lsp nil
  "Clients for the LSP language servers compiled into cmacs."
  :group 'cmacs
  :prefix "cmacs-lsp-")

(defcustom cmacs-lsp-auto-start t
  "When non-nil, `cmacs-lsp-ensure' starts eglot automatically.
Set to nil to keep the registration (\\[eglot] still works by hand)
without auto-connecting on every file visit."
  :type 'boolean
  :group 'cmacs-lsp)

(defun cmacs-lsp-available-p ()
  "Non-nil when this build carries the in-binary LSP framework."
  (and (boundp 'is-cmacs-lsp) is-cmacs-lsp))

(defun cmacs-lsp-binary ()
  "This Emacs binary, for spawning --cmacs-lsp servers.
The server is always the very binary the client runs in, so the two
can never disagree about the language data compiled into them."
  (expand-file-name invocation-name invocation-directory))

(defun cmacs-lsp-server-command (lang)
  "The command list that runs the LANG language server."
  (list (cmacs-lsp-binary) "--cmacs-lsp" lang))

(defun cmacs-lsp-register-eglot (mode lang)
  "Register MODE with eglot to use the in-binary LANG server."
  (with-eval-after-load 'eglot
    (add-to-list 'eglot-server-programs
                 (cons mode (cmacs-lsp-server-command lang)))))

(defun cmacs-lsp-ensure ()
  "Start eglot for the current buffer when appropriate.
Intended for major-mode hooks of modes previously registered with
`cmacs-lsp-register-eglot'.  Does nothing unless `cmacs-lsp-auto-start'
is non-nil, the buffer visits a file, and this build has the framework."
  (when (and cmacs-lsp-auto-start
             buffer-file-name
             (cmacs-lsp-available-p))
    ;; Load eglot from a temp buffer first: on Emacs 30 the eglot
    ;; autoload firing under `delay-mode-hooks' in a derived-mode
    ;; buffer recursively expands macros (same workaround as
    ;; podomation-emacs).
    (unless (featurep 'eglot)
      (with-temp-buffer (require 'eglot nil t)))
    (when (fboundp 'eglot-ensure)
      (cmacs-lsp--setup-doc-frame)
      (eglot-ensure))))


;;; The at-point documentation frame
;;
;; Eldoc's default display is the echo area, which is easy to miss and
;; is nothing like the at-point signature popups of other editors.  So
;; cmacs-lsp buffers render eldoc docs -- most importantly the LSP
;; signature with its active argument highlighted, the moment you type
;; "(" -- in a small child frame right at the cursor: above the line,
;; so it never fights the completion popup that drops below it.  Falls
;; back to the echo area on a tty, under a display that cannot make
;; child frames, or whenever the frame cannot be positioned.

(defcustom cmacs-lsp-doc-frame t
  "When non-nil, show eldoc docs in a child frame at point.
The signature help for the call you are typing appears in a floating
panel above the cursor instead of the echo area.  Set to nil to keep
eldoc's normal display."
  :type 'boolean
  :group 'cmacs-lsp)

(defcustom cmacs-lsp-doc-idle-delay 0.1
  "Buffer-local `eldoc-idle-delay' for cmacs-lsp buffers, or nil.
The default 0.5 s makes the signature panel feel unresponsive after
typing \"(\"; nil leaves the user's global value alone."
  :type '(choice (const :tag "Leave eldoc-idle-delay alone" nil) number)
  :group 'cmacs-lsp)

(defcustom cmacs-lsp-doc-frame-max-lines 12
  "Maximum height of the doc frame, in lines."
  :type 'integer
  :group 'cmacs-lsp)

(defcustom cmacs-lsp-doc-frame-max-columns 78
  "Maximum width of the doc frame, in columns."
  :type 'integer
  :group 'cmacs-lsp)

(defvar cmacs-lsp--doc-frame nil
  "The shared child frame, or nil.  Recreated when the parent changes.")

(defconst cmacs-lsp--doc-frame-parameters
  '((no-accept-focus . t) (no-focus-on-map . t)
    (undecorated . t) (unsplittable . t)
    (min-width . 1) (min-height . 1)
    (internal-border-width . 1)
    (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
    (left-fringe . 4) (right-fringe . 4)
    (cursor-type . nil)
    (visibility . nil) (desktop-dont-save . t))
  "Frame parameters for the doc frame (parent added at creation).")

(defun cmacs-lsp--doc-frame-live (parent)
  "Return the doc frame for PARENT, creating or reparenting as needed."
  (unless (and (frame-live-p cmacs-lsp--doc-frame)
               (eq (frame-parameter cmacs-lsp--doc-frame 'parent-frame)
                   parent))
    (when (frame-live-p cmacs-lsp--doc-frame)
      (delete-frame cmacs-lsp--doc-frame))
    (setq cmacs-lsp--doc-frame
          (make-frame (cons (cons 'parent-frame parent)
                            cmacs-lsp--doc-frame-parameters))))
  cmacs-lsp--doc-frame)

(defun cmacs-lsp-doc-frame-hide (&rest _)
  "Hide the doc frame.  Safe to call from any buffer, any time."
  (when (and (frame-live-p cmacs-lsp--doc-frame)
             (frame-visible-p cmacs-lsp--doc-frame))
    (make-frame-invisible cmacs-lsp--doc-frame)))

(defun cmacs-lsp--doc-frame-show (doc-buffer)
  "Show DOC-BUFFER in the child frame at point.
Returns non-nil on success; nil means the caller should fall back."
  (let ((posn (posn-at-point))
        (parent (selected-frame)))
    (when posn
      (let* ((frame (cmacs-lsp--doc-frame-live parent))
             (window (frame-root-window frame)))
        (with-current-buffer doc-buffer
          (setq-local mode-line-format nil
                      header-line-format nil
                      truncate-lines nil
                      show-trailing-whitespace nil))
        (set-window-buffer window doc-buffer)
        (set-window-dedicated-p window t)
        (fit-frame-to-buffer frame
                             cmacs-lsp-doc-frame-max-lines 1
                             cmacs-lsp-doc-frame-max-columns 1)
        ;; Above the current line, so the completion popup (which drops
        ;; below point) never covers it; below only when there is no
        ;; room above.
        (let* ((edges (window-inside-pixel-edges))
               (xy (posn-x-y posn))
               (x (max 0 (min (+ (nth 0 edges) (car xy))
                              (- (frame-pixel-width parent)
                                 (frame-pixel-width frame)))))
               (line-px (or (cdr (posn-object-width-height posn))
                            (default-line-height)))
               (y-point (+ (nth 1 edges) (cdr xy)))
               (y-above (- y-point (frame-pixel-height frame) 2))
               (y (if (>= y-above 0) y-above (+ y-point line-px 2))))
          (set-frame-position frame x y))
        (make-frame-visible frame)
        t))))

(defun cmacs-lsp-display-in-frame (docs interactive)
  "Display eldoc DOCS in a child frame at point; eldoc display function.
Falls back to `eldoc-display-in-echo-area' whenever a child frame is
not possible (tty, batch, no window position).  INTERACTIVE is passed
through on fallback."
  (unless (and cmacs-lsp-doc-frame
               (display-graphic-p)
               (not (frame-parameter (selected-frame) 'parent-frame))
               (condition-case nil
                   (cmacs-lsp--doc-frame-show
                    (eldoc--format-doc-buffer docs))
                 (error nil)))
    (eldoc-display-in-echo-area docs interactive)))

(defun cmacs-lsp--setup-doc-frame ()
  "Wire the at-point doc frame into this buffer's eldoc."
  (when cmacs-lsp-doc-frame
    (setq-local eldoc-display-functions '(cmacs-lsp-display-in-frame))
    (when cmacs-lsp-doc-idle-delay
      (setq-local eldoc-idle-delay cmacs-lsp-doc-idle-delay))
    ;; Eldoc only calls display functions when it HAS docs; when there
    ;; are none it stays silent, which would leave a stale frame up.
    ;; Hide on every command; eldoc re-shows after its idle delay.
    (add-hook 'pre-command-hook #'cmacs-lsp-doc-frame-hide nil t)
    (add-hook 'kill-buffer-hook #'cmacs-lsp-doc-frame-hide nil t)))

(provide 'cmacs-lsp)
;;; cmacs-lsp.el ends here
