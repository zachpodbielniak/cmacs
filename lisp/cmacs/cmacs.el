;;; cmacs.el --- CMacs feature detection, autoloads, and version  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Core CMacs package.  Provides feature detection for optional CMacs
;; subsystems (glib, gi, crispy, bacon, gowl), platform detection,
;; version information, and autoloads for the rest of the CMacs elisp
;; layer.

;;; Code:

(defconst cmacs-version "0.1.0"
  "CMacs version string.")

(defconst cmacs-version-major 0
  "CMacs major version number.")

(defconst cmacs-version-minor 1
  "CMacs minor version number.")

(defconst cmacs-version-patch 0
  "CMacs patch version number.")

(defgroup cmacs nil
  "CMacs -- GLib-powered Emacs."
  :group 'environment
  :prefix "cmacs-")

;;; Feature detection

(defun cmacs-feature-p (feature)
  "Return non-nil if CMacs was built with FEATURE support.
FEATURE is a symbol: `glib', `gi', `crispy', `bacon', or `gowl'."
  (pcase feature
    ('glib   (fboundp 'gobject-p))
    ('gi     (fboundp 'gi-require))
    ('crispy (fboundp 'crispy-eval))
    ('bacon  (fboundp 'bacon-start))
    ('gowl   (fboundp 'gowl-start))
    (_ (error "Unknown CMacs feature: %S" feature))))

(defun cmacs-features ()
  "Return a list of available CMacs features."
  (let (features)
    (dolist (feat '(glib gi crispy bacon gowl))
      (when (cmacs-feature-p feat)
        (push feat features)))
    (nreverse features)))

;;; Platform detection

(defun cmacs-platform ()
  "Return the current platform as a symbol.
Possible values: `linux', `macos', `freebsd', or `unknown'."
  (pcase system-type
    ('gnu/linux  'linux)
    ('darwin     'macos)
    ('berkeley-unix
     (if (string-match-p "FreeBSD" (or (ignore-errors
                                         (shell-command-to-string "uname"))
                                       ""))
         'freebsd
       'bsd))
    (_ 'unknown)))

;;; Autoloads

(autoload 'cmacs-gi-require "cmacs-gi"
  "Load a GObject Introspection namespace and generate elisp bindings." t)

(autoload 'crispy-repl "cmacs-crispy"
  "Open a Crispy C REPL buffer." t)

(autoload 'crispy-eval-region "cmacs-crispy"
  "Evaluate the selected region as C code via Crispy." t)

(autoload 'crispy-eval-buffer "cmacs-crispy"
  "Evaluate the current buffer as a C script via Crispy." t)

(autoload 'bacon "cmacs-bacon"
  "Open a Bacon shell buffer." t)

(autoload 'cmacs-gowl-mode "cmacs-gowl"
  "Toggle Gowl compositor control minor mode." t)

(provide 'cmacs)
;;; cmacs.el ends here
