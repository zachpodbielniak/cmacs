;;; cmacs-office-autoloads.el --- Office file-type associations -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Registers the Office subsystem's `auto-mode-alist' entries and
;; autoloads its entry points.
;;
;; Plain `src/emacs' already gets these from the dumped `loaddefs.el'
;; (vanilla `loaddefs-generate' copies the `;;;###autoload (add-to-list
;; ...)' cookie verbatim).  But environments that REGENERATE their own
;; autoloads -- notably Doom Emacs -- only emit autoload stubs for
;; definitions and silently DROP bare cookied forms; Doom also
;; reinitialises `auto-mode-alist' during startup, so the dumped entry
;; does not survive.
;;
;; The symptom is specific and confusing: a .docx opens as an `unzip'
;; listing.  That is `archive-mode', reached because `lisp/files.el'
;; maps these extensions to `doc-view-mode-maybe', doc-view finds no
;; converter, and its fallback re-runs `normal-mode' -- landing on the
;; "\\`PK\003\004" entry in `magic-fallback-mode-alist'.  Nothing errors;
;; the office entry was simply not in front any more.
;;
;; Requiring this file ONCE, after init, makes all six formats open in
;; the projection regardless of the autoload environment.  In Doom:
;;
;;   (when IS-CMACS-OFFICE (require 'cmacs-office-autoloads))  ;; config.el
;;
;; It is intentionally lightweight: only `autoload' declarations and
;; `add-to-list' calls; the modes pull in their dependencies on demand.

;;; Code:

(autoload 'cmacs-office-mode "cmacs-office"
  "Major mode for the org projection of an Office document." t)
(autoload 'cmacs-office-find-file "cmacs-office"
  "Open an Office document as an org projection." t)
(autoload 'cmacs-office--open-file "cmacs-office"
  "`auto-mode-alist' entry: reopen the visited file through the model layer.")
(autoload 'cmacs-office-text "cmacs-office"
  "Return the readable text of an Office document.")
(autoload 'cmacs-office-preview "cmacs-office-preview"
  "Show an Office document as laid-out pages." t)
(autoload 'cmacs-office-preview-install "cmacs-office-preview"
  "Point `doc-view' at the flatpak-aware LibreOffice converter." t)
(autoload 'cmacs-office-author "cmacs-office-author"
  "Write org content out as an Office document." t)
(autoload 'cmacs-office-author-docx "cmacs-office-author"
  "Write org content out as a Word document." t)

;; Pushed to the FRONT.  `lisp/files.el' already maps all six extensions
;; to `doc-view-mode-maybe' and the first match in `auto-mode-alist'
;; wins, so merely being present is not enough -- being earlier is.
;;;###autoload
(defun cmacs-office-claim-file-types ()
  "Claim the six Office extensions in `auto-mode-alist'.

Deliberately defined HERE rather than in `cmacs-office.el': it runs from
`emacs-startup-hook', and loading the projection (and Org behind it) on
every startup just to register six file associations would be rude.

Interactive because it is also the cheapest manual recovery: if a
document ever opens as an unzip listing, this puts it right without
loading anything heavy."
  (interactive)
  (dolist (entry '(("\\.docx\\'" . cmacs-office--open-file)
                   ("\\.xlsx\\'" . cmacs-office--open-file)
                   ("\\.pptx\\'" . cmacs-office--open-file)
                   ("\\.odt\\'"  . cmacs-office--open-file)
                   ("\\.ods\\'"  . cmacs-office--open-file)
                   ("\\.odp\\'"  . cmacs-office--open-file)))
    (setq auto-mode-alist (cons entry (delete entry auto-mode-alist)))))

(cmacs-office-claim-file-types)

;; And again after the user's init has run.  This is the part that makes
;; it work without anyone editing their config: `emacs-startup-hook'
;; fires AFTER the init files, so an association reinstalled here
;; survives a configuration that rebuilt `auto-mode-alist' during
;; startup.  Adding a named symbol to a hook is safe during `loadup' --
;; it registers the symbol without calling, and therefore without
;; autoloading anything.
;;;###autoload
(add-hook 'emacs-startup-hook #'cmacs-office-claim-file-types)

;; doc-view's own converter cannot find a flatpak LibreOffice, so page
;; preview would fail silently on a host that has one.  Installing the
;; replacement is cheap and only takes effect when a LibreOffice is
;; actually reachable.
(with-eval-after-load 'doc-view
  (ignore-errors (cmacs-office-preview-install)))

(provide 'cmacs-office-autoloads)
;;; cmacs-office-autoloads.el ends here
