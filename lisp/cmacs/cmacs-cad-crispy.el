;;; cmacs-cad-crispy.el --- crispy (.ccad) part editing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The crispy (C-like) part language: ordinary C with a main() calling
;; the flat cad-glib script API (cad_box, cad_union, cad_emit, ...).
;; This mode derives from `c-mode' for the C editing machinery and
;; layers the SAME shared eval loop / flymake / capf as the s-exp
;; mode (cmacs-cad.el).  Capability flags differ: crispy has no
;; static params, no form spans, no sketch write-back -- UIs degrade
;; accordingly (diagnostics are line-granular, the parameter panel
;; populates after the first evaluation).

;;; Code:

(require 'cmacs-cad)
(require 'cc-mode)

(defconst cmacs-cad-crispy-font-lock-keywords
  '(("\\_<\\(cad_[a-z_0-9]+\\)\\s-*(" (1 font-lock-builtin-face))
    ("\\_<\\(CadSolid\\)\\_>" (1 font-lock-type-face)))
  "Extra font-lock for the cad_* vocabulary in .ccad buffers.")

(defvar cmacs-cad-crispy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-cad-eval-buffer)
    (define-key map (kbd "C-c C-p") #'cmacs-cad-show-params)
    (define-key map (kbd "C-c C-i") #'cmacs-cad-show-inspect)
    (define-key map (kbd "C-c C-e") #'cmacs-cad-export-part)
    (define-key map (kbd "C-c C-v") #'cmacs-cad-workbench)
    map)
  "Keymap for `cmacs-cad-crispy-mode'.")

;;;###autoload
(define-derived-mode cmacs-cad-crispy-mode c-mode "CAD/C"
  "Major mode for .ccad parametric part source (crispy C).

\\{cmacs-cad-crispy-mode-map}"
  (setq cmacs-cad--language "crispy")
  (font-lock-add-keywords nil cmacs-cad-crispy-font-lock-keywords)
  (add-hook 'completion-at-point-functions #'cmacs-cad--capf nil t)
  (add-hook 'after-save-hook #'cmacs-cad--after-save nil t)
  (when (cmacs-cad-available-p)
    (add-hook 'flymake-diagnostic-functions
              #'cmacs-cad--flymake-backend nil t)
    (flymake-mode 1))
  (cmacs-cad--maybe-auto-workbench))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ccad\\'" . cmacs-cad-crispy-mode))

(provide 'cmacs-cad-crispy)
;;; cmacs-cad-crispy.el ends here
