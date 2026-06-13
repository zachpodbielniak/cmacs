;;; cmacs-cad-autoloads.el --- CAD file-type associations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Registers the CAD subsystem's `auto-mode-alist' entries and autoloads
;; its mode entry points.
;;
;; Plain `src/emacs' already gets these from the dumped `loaddefs.el'
;; (vanilla `loaddefs-generate' copies the `;;;###autoload (add-to-list
;; ...)' cookies verbatim).  But environments that REGENERATE their own
;; autoloads -- notably Doom Emacs -- only emit autoload stubs for
;; definitions (`define-derived-mode' &c.) and silently DROP bare cookied
;; forms like `(add-to-list 'auto-mode-alist ...)'; Doom also reinitialises
;; `auto-mode-alist' during startup, so the dumped entries don't survive.
;;
;; Requiring this file ONCE, after init, makes `.cad'/`.gcode'/`.stl'/…
;; open in their viewers regardless of the autoload environment.  In Doom:
;;
;;   (when IS-CMACS (require 'cmacs-cad-autoloads))   ;; in config.el
;;
;; It is intentionally lightweight: only `autoload' declarations and
;; `add-to-list' calls; the modes pull in their dependencies on demand.

;;; Code:

(autoload 'cmacs-cad-mode "cmacs-cad"
  "Major mode for .cad parametric part source." t)
(autoload 'cmacs-cad-crispy-mode "cmacs-cad-crispy"
  "Major mode for .ccad crispy part source." t)
(autoload 'cmacs-cad-gcode-mode "cmacs-cad-gcode"
  "View a sliced G-code file's toolpath in 3-D." t)
(autoload 'cmacs-cad-model-mode "cmacs-cad-model"
  "View an STL/OBJ/STEP/IGES/3MF model in libregnum." t)
(autoload 'cmacs-cad-workbench "cmacs-cad-editor"
  "Open the libregnum workbench for the current part." t)
(autoload 'cmacs-cad-sketch "cmacs-cad-sketch"
  "Open the interactive 2D constraint sketcher." t)
(autoload 'cmacs-cad-new-part "cmacs-cad-project"
  "Scaffold a new .cad part." t)
(autoload 'cmacs-cad-new-project "cmacs-cad-project"
  "Scaffold a new CAD project." t)
(autoload 'cmacs-cad-part-browser "cmacs-cad-project"
  "Browse the project's CAD parts with thumbnails." t)

(dolist (entry '(("\\.cad\\'"   . cmacs-cad-mode)
                 ("\\.ccad\\'"  . cmacs-cad-crispy-mode)
                 ("\\.gcode\\'" . cmacs-cad-gcode-mode)
                 ("\\.gco\\'"   . cmacs-cad-gcode-mode)
                 ("\\.stl\\'"   . cmacs-cad-model-mode)
                 ("\\.obj\\'"   . cmacs-cad-model-mode)
                 ("\\.step\\'"  . cmacs-cad-model-mode)
                 ("\\.stp\\'"   . cmacs-cad-model-mode)
                 ("\\.iges\\'"  . cmacs-cad-model-mode)
                 ("\\.igs\\'"   . cmacs-cad-model-mode)
                 ("\\.3mf\\'"   . cmacs-cad-model-mode)))
  (add-to-list 'auto-mode-alist entry))

(provide 'cmacs-cad-autoloads)
;;; cmacs-cad-autoloads.el ends here
