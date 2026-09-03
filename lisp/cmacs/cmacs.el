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
FEATURE is a symbol naming a --with-cmacs-FEATURE subsystem, e.g.
`glib', `ai', `gowl', `gsurf', `org-ex', `video'.

Backed by the always-present compile-time `IS-CMACS-<NAME>' variables
\(see `cmacs-compiled-features').  For a few media subsystems that can be
compiled in yet unavailable at runtime (missing GStreamer element, no
GL, ...), a runtime availability check further refines the result.
Returns nil for an unknown or not-compiled-in FEATURE."
  (let ((flag (intern-soft (concat "IS-CMACS-"
                                    (upcase (symbol-name feature))))))
    (and flag (boundp flag) (symbol-value flag)
         (pcase feature
           ('video     (cmacs-video-supported-p))
           ('audio     (cmacs-audio-supported-p))
           ('piper     (cmacs-piper-supported-p))
           ('libregnum (cmacs-libregnum-supported-p))
           ('gnuseye   (cmacs-gnuseye-supported-p))
           ('roamgraph (cmacs-roamgraph-supported-p))
           ('secondbrain (cmacs-secondbrain-supported-p))
           ('cad       (cmacs-cad-supported-p))
           ;; No `calculator' branch: its engine is Elisp over GNU Calc, so
           ;; compiled-in means available -- and unlike the C-backed
           ;; subsystems above, `cmacs-calculator-supported-p' is an ordinary
           ;; function, so calling it here would signal `void-function' unless
           ;; cmacs-calculator.el happened to be loaded already.  The other
           ;; pure-Elisp subsystems (transcode, transcribe) are the same.
           (_ t)))))

(defun cmacs-features ()
  "Return the list of available CMacs feature symbols.
Derived from the compile-time set (`cmacs-compiled-features') filtered
through `cmacs-feature-p', so a subsystem that is compiled in but
unavailable at runtime is excluded."
  (let (out)
    (dolist (feat (if (fboundp 'cmacs-compiled-features)
                      (cmacs-compiled-features)
                    ;; Fallback if the C feature registry is absent.
                    '(glib gi crispy bacon gowl podomation libreclaw ai
                      ai-brigade
                      libregnum lrgterm imgedit vidstudio gnuseye
                      roamgraph secondbrain cad
                      screensaver org-ex mcp print video audio whisper
                      piper gsurf gsurf-lrg emacsctl cintrospect cpatch
                      calculator lsp transcode transcribe lrgscript
                      office)))
      (when (cmacs-feature-p feat)
        (push feat out)))
    (nreverse out)))

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

(defun cmacs--manual-topics ()
  "Return an alist of (TOPIC . FILE) for every CMacs manual doc.
Walks `cmacs-doc-org-directory' recursively, collecting every .org
and .md file (so embedded dependency docs under deps/<dep>/ are
included alongside the core manual).  TOPIC is the path relative to
the doc directory with the extension dropped; when an .org and .md
share the same stem the extension is kept to disambiguate."
  (let* ((dir (file-name-as-directory cmacs-doc-org-directory))
         (files (and (file-directory-p dir)
                     (directory-files-recursively
                      dir "\\.\\(org\\|md\\)\\'")))
         (stems (make-hash-table :test 'equal))
         result)
    ;; First pass: count how many files share each extension-less stem.
    (dolist (file files)
      (let ((stem (file-name-sans-extension
                   (file-relative-name file dir))))
        (puthash stem (1+ (gethash stem stems 0)) stems)))
    ;; Second pass: build display keys, keeping the extension only when a
    ;; stem is ambiguous (e.g. both foo.org and foo.md exist).
    (dolist (file files)
      (let* ((rel (file-relative-name file dir))
             (stem (file-name-sans-extension rel))
             (key (if (> (gethash stem stems 0) 1) rel stem)))
        (push (cons key file) result)))
    (nreverse result)))

;;;###autoload
(defun cmacs-manual-topic (topic)
  "Open a specific CMacs Org manual TOPIC.
TOPIC is a doc path relative to `cmacs-doc-org-directory' without
extension (e.g. \"cmacsgi\", \"api\", \"deps/ai-glib/architecture\").
The completion list is discovered dynamically, so core docs and
embedded dependency docs both appear."
  (interactive
   (let ((topics (cmacs--manual-topics)))
     (unless topics
       (user-error "No CMacs docs found in %s" cmacs-doc-org-directory))
     (list (completing-read "CMacs topic: " topics nil t))))
  (let* ((topics (cmacs--manual-topics))
         (file (cdr (assoc topic topics))))
    (cond
     ((and file (file-exists-p file)) (find-file file))
     ;; Fall back to a direct .org lookup for a hand-typed topic.
     ((file-exists-p (expand-file-name (concat topic ".org")
                                       cmacs-doc-org-directory))
      (find-file (expand-file-name (concat topic ".org")
                                   cmacs-doc-org-directory)))
     (t (user-error "Doc topic not found: %s" topic)))))

;;; Autoloads

(autoload 'cmacs-gi-require "cmacs-gi"
  "Load a GObject Introspection namespace and generate elisp bindings." t)

(autoload 'crispy-repl "cmacs-crispy"
  "Open a Crispy C REPL buffer." t)

(autoload 'crispy-eval-region "cmacs-crispy"
  "Evaluate the selected region as C code via Crispy." t)

(autoload 'crispy-eval-buffer "cmacs-crispy"
  "Evaluate the current buffer as a C script via Crispy." t)

(autoload 'cmacs-scratchpad-mode "cmacs-scratchpad"
  "Toggle polyglot eval (%crispy / %bacon blocks) in scratch buffers." t)

(autoload 'cmacs-scratchpad-eval-block "cmacs-scratchpad"
  "Evaluate the scratchpad block at point and insert its output." t)

(autoload 'bacon "cmacs-bacon"
  "Open a Bacon shell buffer." t)

(autoload 'cmacs-gowl-mode "cmacs-gowl"
  "Toggle Gowl compositor control minor mode." t)

(autoload 'cmacs-gowl-spawn-command "cmacs-gowl"
  "Launch a Wayland client in the Gowl compositor." t)

(autoload 'cmacs-gowl-attach "cmacs-gowl"
  "Bring up the embedded Gowl compositor in this Emacs on demand." t)

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

(autoload 'cmacs-ai-call "cmacs-ai-call"
  "Prompt the AI and return the answer string; supports tools.")
(autoload 'cmacs-ai-define-tool "cmacs-ai-call"
  "Define a tool spec for `cmacs-ai-call'.")

;;; Auto-enable gowl mode when started with --gowl
(when (bound-and-true-p gowl-early-started)
  (add-hook 'after-init-hook
            (lambda () (cmacs-gowl-mode 1))))

;;; Auto-enable org-ex mode — hook setup is in cmacs-org-ex.el via autoload.

(provide 'cmacs)
;;; cmacs.el ends here
