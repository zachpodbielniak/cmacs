;;; cmacs-ink.el --- Wacom tablet integration for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; cmacs-ink is the top-level module for tablet ink in cmacs.  It
;; ships two complementary surfaces backed by a shared core:
;;
;;   * F1 — `#+BEGIN_INK' canvas blocks inside org files.  Strokes
;;     live inline in the block body so a single .org file is
;;     self-contained and git-friendly.  See `cmacs-org-ex-ink'.
;;
;;   * F2 — Marginalia: ink annotations stored in a sidecar file
;;     (`<source>.cmacs-ink') alongside any source you visit.  See
;;     `cmacs-ink-marginalia'.
;;
;; Both surfaces use the same modal capture window (`org-ex-ink-capture')
;; which reads pen, eraser, and pressure straight from GdkDeviceTool /
;; GDK_AXIS_PRESSURE — works out-of-the-box under standalone pgtk
;; Emacs on GNOME Wayland (the host compositor delivers wp_tablet_v2
;; events through GDK).  Under cmacs --gowl the tablet falls back to
;; mouse-only in v1; real wp_tablet_v2 server support is deferred.
;;
;; Core C primitives (DEFUNs in cmacs-org-ex.c):
;;   org-ex-ink-strokes-from-string  org-ex-ink-strokes-to-string
;;   org-ex-ink-strokes-to-svg       org-ex-ink-strokes-empty
;;   org-ex-ink-strokes-count        org-ex-ink-capture
;;
;; Default keymap (under `cmacs-ink-mode'):
;;   C-c i c   cmacs-org-ex-ink-insert        (canvas — insert block)
;;   C-c i e   cmacs-org-ex-ink-edit          (canvas — edit at point)
;;   C-c i t   cmacs-org-ex-ink-toggle-render (canvas — raw <-> SVG)
;;   C-c i a   cmacs-ink-marginalia-add      (marginalia — annotate)
;;   C-c i E   cmacs-ink-marginalia-edit-at-point
;;   C-c i d   cmacs-ink-marginalia-delete-at-point
;;   C-c i l   cmacs-ink-marginalia-list

;;; Code:

(require 'cmacs-org-ex-ink)
(require 'cmacs-ink-marginalia)

(defgroup cmacs-ink nil
  "Wacom tablet integration for cmacs."
  :group 'cmacs
  :prefix "cmacs-ink-")

;; ---------------------------------------------------------------------
;; Mode + keymap
;; ---------------------------------------------------------------------

(defvar cmacs-ink-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c i c") #'cmacs-org-ex-ink-insert)
    (define-key m (kbd "C-c i e") #'cmacs-org-ex-ink-edit)
    (define-key m (kbd "C-c i t") #'cmacs-org-ex-ink-toggle-render)
    (define-key m (kbd "C-c i a") #'cmacs-ink-marginalia-add)
    (define-key m (kbd "C-c i E") #'cmacs-ink-marginalia-edit-at-point)
    (define-key m (kbd "C-c i d") #'cmacs-ink-marginalia-delete-at-point)
    (define-key m (kbd "C-c i l") #'cmacs-ink-marginalia-list)
    m)
  "Keymap for `cmacs-ink-mode'.")

;;;###autoload
(define-minor-mode cmacs-ink-mode
  "Tablet ink minor mode.
Adds keybindings for `#+BEGIN_INK' canvas blocks and per-line ink
marginalia.  Also installs the `find-file' / `after-save' hooks
that auto-render canvases and load/save the marginalia sidecar."
  :lighter " Ink"
  :keymap cmacs-ink-mode-map
  (cond
   (cmacs-ink-mode
    (add-hook 'find-file-hook
              #'cmacs-org-ex-ink--maybe-render nil t)
    (add-hook 'find-file-hook
              #'cmacs-ink-marginalia--maybe-load nil t)
    (add-hook 'after-save-hook
              #'cmacs-ink-marginalia--maybe-save nil t)
    ;; If the buffer is already visiting a file, run the loaders now
    ;; so toggling the mode on works without a re-find.
    (when (buffer-file-name)
      (cmacs-org-ex-ink--maybe-render)
      (cmacs-ink-marginalia--maybe-load)))
   (t
    (remove-hook 'find-file-hook
                 #'cmacs-org-ex-ink--maybe-render t)
    (remove-hook 'find-file-hook
                 #'cmacs-ink-marginalia--maybe-load t)
    (remove-hook 'after-save-hook
                 #'cmacs-ink-marginalia--maybe-save t)
    (cmacs-org-ex-ink-unrender-buffer)
    (mapc (lambda (a)
            (when (cmacs-ink-marginalia-anchor-overlay a)
              (delete-overlay (cmacs-ink-marginalia-anchor-overlay a))))
          cmacs-ink-marginalia--anchors))))

;;;###autoload
(define-globalized-minor-mode global-cmacs-ink-mode
  cmacs-ink-mode
  (lambda ()
    (when (or (derived-mode-p 'org-mode 'prog-mode 'text-mode)
              (buffer-file-name))
      (cmacs-ink-mode 1)))
  :group 'cmacs-ink)

(provide 'cmacs-ink)
;;; cmacs-ink.el ends here
