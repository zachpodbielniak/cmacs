;;; cmacs-env.el --- exec-path/PATH bootstrap for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; When cmacs is launched from a graphical session (a .desktop file,
;; emacsclient -c starting a fresh daemon, a Wayland session, a
;; systemd --user unit), it inherits a minimal PATH that typically
;; doesn't include the user-local bin dirs your shell adds via
;; ~/.profile / .bashrc / .zshrc.  That leaves binaries like piper
;; (installed via `pip install --user piper-tts' to ~/.local/bin),
;; cargo binaries, linuxbrew tools, npm globals, etc.  invisible to
;; `executable-find', `call-process', `g_find_program_in_path', and
;; everything in cmacs that resolves an external tool name.
;;
;; This module fixes that at `emacs-startup-hook' time by prepending
;; the well-known user-local bin dirs to `exec-path' and
;; `process-environment[PATH]'.  Only dirs that actually exist are
;; added.  Idempotent.  Customise `cmacs-env-extra-path-dirs' to add
;; more.
;;
;; Why not source ~/.bash_profile or shell out via exec-path-from-shell?
;;   - .bash_profile only runs in *login* shells, not all shells.
;;   - Distros differ wildly on which of .profile / .bash_profile /
;;     .zprofile / shell-init.d snippets actually set PATH.
;;   - Spawning a shell on every emacs start is slow and inherits all
;;     the fragility of the user's dotfiles.
;;   - exec-path-from-shell does the spawn-and-parse dance; users
;;     who need the full shell-env import can install it and we won't
;;     conflict.
;;
;; The lightweight "prepend known dirs that exist" approach covers
;; 95% of cases with zero subprocesses and zero variance.

;;; Code:

(defgroup cmacs-env nil
  "Environment / PATH bootstrap for cmacs."
  :group 'cmacs
  :prefix "cmacs-env-")

;;;###autoload
(defcustom cmacs-env-extra-path-dirs
  '(;; --- user-local bin dirs ---
    "~/.local/bin"            ; pip install --user, cargo install --root=~/.local, ...
    "~/bin"                   ; ad-hoc personal scripts
    "~/bin/scripts"           ; nested personal scripts dir (common convention)
    "~/.cargo/bin"            ; rustup-installed cargo binaries
    "~/.npm-global/bin"       ; npm global without sudo
    "~/.nimble/bin"           ; Nim's nimble package manager
    "~/.bun/bin"              ; Bun JS runtime
    "~/.deno/bin"             ; Deno JS runtime
    "~/go/bin"                ; Go `go install' destination
    "~/perl5/bin"             ; Perl local::lib
    "~/.poetry/bin"           ; Poetry Python pkg mgr
    ;; --- system-wide third-party ---
    "/home/linuxbrew/.linuxbrew/bin"
    "/home/linuxbrew/.linuxbrew/sbin"
    "/usr/local/bin"          ; usually inherited, kept defensively
    "/usr/local/sbin")
  "Directories to prepend to `exec-path' and PATH at cmacs startup.
Each entry is expanded with `expand-file-name' and added only if
it actually exists on disk.  Default covers the common Linux
developer layouts (pip --user, cargo, linuxbrew, go, etc.).  Add
your own dirs via M-x customize-variable."
  :type '(repeat directory)
  :group 'cmacs-env)

;;;###autoload
(defcustom cmacs-env-auto-bootstrap t
  "When non-nil, run `cmacs-env-bootstrap' at `emacs-startup-hook'.
Set to nil BEFORE init to opt out (and call
\\[cmacs-env-bootstrap] manually if you ever want it)."
  :type 'boolean
  :group 'cmacs-env)

;;;###autoload
(defcustom cmacs-env-prepend t
  "When non-nil, new dirs go at the FRONT of `exec-path' and PATH
(highest precedence), mirroring how user shells typically prepend.
When nil, append instead (lowest precedence) so a system tool of
the same name wins -- useful if you want to keep distro defaults
unconditionally."
  :type 'boolean
  :group 'cmacs-env)

(defun cmacs-env--ensure-on-path (dir)
  "If DIR (a string path, may begin with `~') exists, ensure it is
on both `exec-path' and the PATH env var.  Returns the
canonicalised DIR if it was newly added, nil if it didn't exist
or was already present."
  (let* ((abs   (expand-file-name dir))
         (clean (directory-file-name abs)))
    (when (file-directory-p clean)
      (let ((added nil))
        ;; exec-path uses paths without trailing slash.
        (unless (member clean exec-path)
          (setq exec-path (if cmacs-env-prepend
                              (cons clean exec-path)
                            (append exec-path (list clean))))
          (setq added t))
        ;; PATH env var.  TWO views to keep in sync:
        ;;   1. process-environment (the Lisp variable) -- used by
        ;;      Emacs's own subprocess machinery (make-process,
        ;;      call-process, ...).  Updated via Emacs's `setenv'.
        ;;   2. The libc environ.  Read by ANY C code that calls
        ;;      getenv(3) directly: glib's g_find_program_in_path,
        ;;      GStreamer plugins, libsoup, sqlite SQLITE_TMPDIR, ...
        ;;      Updated via the cmacs-setenv DEFUN (libc setenv(3)
        ;;      wrapper -- see cmacs/glib/cmacs-glib-loop.c).
        ;;
        ;; Emacs's `setenv' does NOT touch libc environ, so without
        ;; cmacs-setenv our added dirs would be invisible to e.g.
        ;; cmacs-piper-supported-p (which uses g_find_program_in_path).
        (let* ((path-env (or (getenv "PATH") ""))
               (parts (split-string path-env path-separator t)))
          (unless (member clean parts)
            (let ((newpath
                   (mapconcat #'identity
                              (if cmacs-env-prepend
                                  (cons clean parts)
                                (append parts (list clean)))
                              path-separator)))
              (setenv "PATH" newpath)
              (when (fboundp 'cmacs-setenv)
                (cmacs-setenv "PATH" newpath)))
            (setq added t)))
        (when added clean)))))

;;;###autoload
(defun cmacs-env-bootstrap ()
  "Prepend every dir in `cmacs-env-extra-path-dirs' that exists on
disk to `exec-path' and PATH.  Skips dirs that don't exist; safe
to run multiple times.

Honours `cmacs-env-auto-bootstrap' (opt-out from being run by the
startup hook) and `cmacs-env-prepend' (front vs back of the path).

Run automatically once via `emacs-startup-hook' (installed
through an autoload cookie in loaddefs.el).  Run it again by hand
after editing `cmacs-env-extra-path-dirs' to pick up the new
entries without restarting."
  (interactive)
  (when (or (called-interactively-p 'any) cmacs-env-auto-bootstrap)
    (let ((added (delq nil (mapcar #'cmacs-env--ensure-on-path
                                   cmacs-env-extra-path-dirs))))
      (when (and added (not noninteractive))
        (message "cmacs-env: %sed %d path dir%s (%s)"
                 (if cmacs-env-prepend "prepend" "append")
                 (length added)
                 (if (= 1 (length added)) "" "s")
                 (mapconcat #'identity added " ")))
      added)))

;;;###autoload
(add-hook 'emacs-startup-hook #'cmacs-env-bootstrap)

;; If this file is loaded AFTER `emacs-startup-hook' has already
;; fired (e.g. via M-x load-library mid-session), run the bootstrap
;; directly so the user sees the effect immediately.
(when (and after-init-time (not noninteractive))
  (cmacs-env-bootstrap))

(provide 'cmacs-env)

;;; cmacs-env.el ends here
