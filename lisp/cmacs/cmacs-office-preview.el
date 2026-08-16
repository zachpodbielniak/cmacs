;;; cmacs-office-preview.el --- laid-out page preview -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The org projection tells you what a document SAYS.  Sometimes you
;; need to see what it LOOKS like -- where the page breaks fall, what
;; the chart looks like, whether the table fits.  That is a layout
;; engine's job, not a parser's, so this delegates to LibreOffice.
;;
;; LibreOffice stays optional and is never authoritative: it renders
;; pictures, and nothing here ever writes back through it.
;;
;; Why this file exists at all: Emacs's own `doc-view' already knows how
;; to turn these formats into page images, and `lisp/files.el' already
;; routes all six extensions to it.  What it does NOT know is how to
;; find LibreOffice when it is installed as a flatpak -- it looks only
;; at `executable-find'.  On a host where LibreOffice is a flatpak (an
;; immutable OS, say) `doc-view' therefore does nothing at all, silently.
;;
;; No upstream change is needed to fix that: the converter is a
;; `defcustom', so pointing it at `cmacs-office-preview-convert' is
;; enough.
;;
;; The flatpak entry point is `libreoffice', NOT `soffice'.  soffice
;; exists inside the sandbox but is not on its PATH, so
;; `--command=soffice' fails with a bare "execvp: No such file or
;; directory" that looks like the app is missing.

;;; Code:

(require 'subr-x)

(defgroup cmacs-office-preview nil
  "Page preview for Office documents."
  :group 'cmacs-office
  :prefix "cmacs-office-preview-")

(defcustom cmacs-office-preview-flatpak-ids
  '(("org.libreoffice.LibreOffice" . "libreoffice")
    ("com.collaboraoffice.Office"  . "soffice"))
  "Flatpak applications that can convert Office documents.

Each entry is (APPLICATION-ID . COMMAND), where COMMAND is what to pass
to `flatpak run --command='.  It is not the same for every packaging:
the LibreOffice flatpak exports `libreoffice', while Collabora's default
command is a GUI launcher and the converter has to be named explicitly."
  :type '(alist :key-type string :value-type string)
  :group 'cmacs-office-preview)

(defcustom cmacs-office-preview-timeout 120
  "Seconds to wait for a conversion before giving up."
  :type 'integer
  :safe #'integerp
  :group 'cmacs-office-preview)

(defvar cmacs-office-preview--cache 'unset
  "Cached result of `cmacs-office-preview-converter'.")

(defun cmacs-office-preview--flatpak-installed-p (id)
  "Return non-nil when the flatpak application ID is installed.
Uses `flatpak info', which sees both user and system installations."
  (and (executable-find "flatpak")
       (eq 0 (call-process "flatpak" nil nil nil "info" id))))

(defun cmacs-office-preview-converter (&optional refresh)
  "Return how to run LibreOffice headlessly, or nil when it is absent.

The value is a list of program and leading arguments, ready to be
followed by the conversion arguments.  With REFRESH, re-detect rather
than using the cached answer.

Resolution order: a native binary on `exec-path' first, because it
starts faster and has no sandbox to negotiate; then the known flatpaks."
  (when (or refresh (eq cmacs-office-preview--cache 'unset))
    (setq cmacs-office-preview--cache
          (or (when-let* ((exe (or (executable-find "soffice")
                                  (executable-find "libreoffice"))))
                (list exe))
              (cl-loop for (id . command) in cmacs-office-preview-flatpak-ids
                       when (cmacs-office-preview--flatpak-installed-p id)
                       return (list "flatpak" "run"
                                    (concat "--command=" command) id)))))
  cmacs-office-preview--cache)

(defun cmacs-office-preview-available-p ()
  "Return non-nil when a page preview can be produced."
  (and (cmacs-office-preview-converter) t))

(defun cmacs-office-preview--profile-dir ()
  "Return a private LibreOffice profile directory.

Without one, a headless run collides with an interactive LibreOffice
already open and simply exits, which looks exactly like a conversion
failure."
  (let ((dir (expand-file-name "cmacs-office-lo-profile"
                               temporary-file-directory)))
    (make-directory dir t)
    dir))

(defun cmacs-office-preview-command (input format outdir)
  "Return the argument list converting INPUT to FORMAT inside OUTDIR."
  (let ((base (cmacs-office-preview-converter))
        (profile (cmacs-office-preview--profile-dir)))
    (unless base
      (user-error "No LibreOffice found (native or flatpak)"))
    (append
     base
     ;; A flatpak sees only what it is granted.  Both the staging
     ;; directory and the profile have to be reachable, or the
     ;; conversion fails with a permissions error that reads like a
     ;; missing file.
     (when (equal (car base) "flatpak")
       (list (concat "--filesystem=" (directory-file-name outdir))
             (concat "--filesystem=" (directory-file-name profile))
             (concat "--filesystem="
                     (directory-file-name (file-name-directory input)))))
     (list "--headless" "--norestore"
           (concat "-env:UserInstallation=file://" profile)
           "--convert-to" format
           "--outdir" (directory-file-name outdir)
           input))))

(defun cmacs-office-preview-convert (input format outdir &optional callback)
  "Convert INPUT to FORMAT in OUTDIR, asynchronously.

CALLBACK is called with the output file name on success, or nil on
failure.  Returns the process."
  (let* ((args (cmacs-office-preview-command input format outdir))
         (out (expand-file-name
               (concat (file-name-base input) "." format) outdir))
         (buffer (generate-new-buffer " *cmacs-office-convert*"))
         (proc (make-process
                :name "cmacs-office-convert"
                :buffer buffer
                :command args
                :noquery t
                :sentinel
                (lambda (p _event)
                  (when (memq (process-status p) '(exit signal))
                    (let ((ok (and (eq 0 (process-exit-status p))
                                   (file-exists-p out))))
                      (unless ok
                        (message "cmacs-office: conversion failed: %s"
                                 (with-current-buffer (process-buffer p)
                                   (string-trim (buffer-string)))))
                      (kill-buffer (process-buffer p))
                      (when callback (funcall callback (and ok out)))))))))
    proc))

;;; doc-view integration

(defvar doc-view--current-cache-dir)
;; Defined by doc-view, which is loaded on demand rather than required:
;; pulling it in at load time would drag image-mode and its dependencies
;; into every session that merely opens a document.
(defvar doc-view-odf->pdf-converter-function)

;;;###autoload
(defun cmacs-office-preview-doc-view-converter (source callback)
  "Convert SOURCE to PDF for `doc-view', then call CALLBACK.

Installed as `doc-view-odf->pdf-converter-function' so that page
preview works on hosts where LibreOffice is only available as a
flatpak -- which stock `doc-view' cannot see, and where it therefore
fails silently."
  (let ((dir (if (boundp 'doc-view--current-cache-dir)
                 doc-view--current-cache-dir
               temporary-file-directory)))
    (cmacs-office-preview-convert
     source "pdf" dir
     (lambda (out)
       (when out
         (let ((want (expand-file-name "doc.pdf" dir)))
           (unless (equal out want)
             (ignore-errors (rename-file out want t)))))
       (funcall callback)))))

;;;###autoload
(defun cmacs-office-preview-install ()
  "Point `doc-view' at the flatpak-aware converter.

Only takes effect when a LibreOffice is actually reachable, so a host
without one keeps whatever `doc-view' had configured."
  (interactive)
  (when (cmacs-office-preview-available-p)
    (setq doc-view-odf->pdf-converter-function
          #'cmacs-office-preview-doc-view-converter)
    t))

;;;###autoload
(defun cmacs-office-preview (&optional file)
  "Show FILE as laid-out pages, rather than as an org projection.

Defaults to the document the current projection buffer came from, so
\\<cmacs-office-mode-map>\\[cmacs-office-preview] answers \"what does
this actually look like\" without leaving the buffer."
  (interactive)
  (let ((file (or file
                  (and (boundp 'cmacs-office--source) cmacs-office--source)
                  buffer-file-name
                  (read-file-name "Preview document: "))))
    (unless (cmacs-office-preview-available-p)
      (user-error
       "Page preview needs LibreOffice; none found on PATH or as a flatpak"))
    (require 'doc-view)
    (cmacs-office-preview-install)
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'doc-view-mode)
          (doc-view-mode)))
      (switch-to-buffer buffer))))

(provide 'cmacs-office-preview)
;;; cmacs-office-preview.el ends here
