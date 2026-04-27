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
FEATURE is a symbol: `glib', `gi', `crispy', `bacon', `gowl', or `org-ex'."
  (pcase feature
    ('glib   (fboundp 'gobject-p))
    ('gi     (fboundp 'gi-require))
    ('crispy (fboundp 'crispy-eval))
    ('bacon  (fboundp 'bacon-start))
    ('gowl   (fboundp 'gowl-start))
    ('org-ex (fboundp 'org-ex-document-create))
    (_ (error "Unknown CMacs feature: %S" feature))))

(defun cmacs-features ()
  "Return a list of available CMacs features."
  (let (features)
    (dolist (feat '(glib gi crispy bacon gowl org-ex))
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

;;; Documentation

(defvar cmacs-doc-org-directory
  (expand-file-name "../doc_org/cmacs/" data-directory)
  "Directory containing CMacs Org documentation files.")

;;;###autoload
(defun cmacs-manual ()
  "Open the CMacs Org manual index."
  (interactive)
  (let ((index (expand-file-name "cmacs.org" cmacs-doc-org-directory)))
    (if (file-exists-p index)
        (find-file index)
      (info "(cmacs)"))))

;;;###autoload
(defun cmacs-manual-topic (topic)
  "Open a specific CMacs Org manual TOPIC.
TOPIC is a filename without extension (e.g., \"cmacsgi\", \"api\")."
  (interactive
   (list (completing-read "CMacs topic: "
                          '("overview" "glib" "gobject" "gi" "dbus"
                            "bacon" "cmacsgi" "api" "crispy" "build"
                            "org-ex")
                          nil t)))
  (let ((file (expand-file-name (concat topic ".org")
                                cmacs-doc-org-directory)))
    (if (file-exists-p file)
        (find-file file)
      (user-error "Doc file not found: %s" file))))

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

(autoload 'cmacs-gowl-spawn-command "cmacs-gowl"
  "Launch a Wayland client in the Gowl compositor." t)

(autoload 'cmacs-org-ex-mode "cmacs-org-ex"
  "Toggle org-ex interactive widget mode." t)

(autoload 'cmacs-ink-mode "cmacs-ink"
  "Toggle Wacom tablet ink minor mode." t)
(autoload 'global-cmacs-ink-mode "cmacs-ink"
  "Toggle global Wacom tablet ink mode." t)
(autoload 'cmacs-org-ex-ink-insert "cmacs-org-ex-ink"
  "Insert a #+BEGIN_INK canvas block at point." t)
(autoload 'cmacs-org-ex-ink-edit "cmacs-org-ex-ink"
  "Edit the #+BEGIN_INK block at point in the capture window." t)
(autoload 'cmacs-ink-marginalia-add "cmacs-ink-marginalia"
  "Annotate the current line with an ink note." t)
(autoload 'cmacs-ink-region-annotate "cmacs-ink-region"
  "Annotate the active region with a transparent ink layer." t)
(autoload 'cmacs-ink-overlay-mode "cmacs-ink-region"
  "Render region ink annotations on top of buffer text." t)
(autoload 'cmacs-ink-region-reload "cmacs-ink-region"
  "Force-reload region annotations from disk." t)
(autoload 'cmacs-ink-region-debug "cmacs-ink-region"
  "Print diagnostic info for region annotations." t)
(autoload 'cmacs-ink-redraw "cmacs-ink-region"
  "Force a full redraw of all region overlays." t)
(autoload 'cmacs-ink-migrate-to-inline "cmacs-ink-storage"
  "Migrate sidecar annotations into an inline org section." t)

(autoload 'cmacs-config-load-all "cmacs-config"
  "Load bacon and C config files after elisp init.")

;;; Auto-enable gowl mode when started with --gowl
(when (bound-and-true-p gowl-early-started)
  (add-hook 'after-init-hook
            (lambda () (cmacs-gowl-mode 1))))

;;; Auto-enable org-ex mode — hook setup is in cmacs-org-ex.el via autoload.

(provide 'cmacs)
;;; cmacs.el ends here
