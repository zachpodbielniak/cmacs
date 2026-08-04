;;; cmacs-brigade.el --- AI brigade fabric: entry points and options  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The brigade is the layer every other cmacs subsystem -- and every
;; user's own config -- lays on top of to get AI capability, agent
;; orchestration, and memory.  Its primary deliverable is the extension
;; surface: registering a capability is one form in your init, and that
;; one form lights it up on all three delivery paths at once (in-process
;; HTTP agents, CLI agents over MCP, and external MCP clients).
;;
;; This file holds the customization group, the shared paths, and the
;; feature probes.  The registries live in `cmacs-brigade-registry',
;; memory in `cmacs-brigade-memory', and so on.
;;
;; A standing rule, enforced by an ERT test: no literal path, model id,
;; or endpoint appears anywhere in the brigade sources outside a
;; `defcustom' form.  Shipped values are defaults, never assumptions --
;; every one of them is meant to be overridden in user config.

;;; Code:

(require 'cmacs nil 'noerror)

;; Defined here rather than relying on the C DEFSYM so the Elisp layer
;; still has a usable error hierarchy in a build without the feature --
;; `define-error' with this as a parent would fail otherwise.  Harmless
;; when the C side already established it: define-error is idempotent
;; for an identical definition.
(define-error 'cmacs-brigade-error "CMacs brigade error")

(defconst cmacs-brigade-abi-expected 1
  "C ABI version this Elisp layer is written against.
Checked against `cmacs-brigade-abi-version' at load so a stale .elc
against a newer cmacs binary fails loudly rather than misbehaving at the
marshalling boundary.")

(defgroup cmacs-brigade nil
  "AI brigade: multi-agent orchestration, memory, and the tool fabric."
  :group 'cmacs
  :prefix "cmacs-brigade-")

(defgroup cmacs-brigade-memory nil
  "The brigade memory index over your notes and other corpora."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-memory-")


;;;; Paths
;;
;; Defaults follow the XDG base directory spec.  `locate-user-emacs-file'
;; is deliberately NOT used: brigade state is large (a memory index runs
;; to hundreds of megabytes) and rebuildable, so it does not belong in a
;; config directory people back up or sync.

(defcustom cmacs-brigade-state-dir
  (expand-file-name "cmacs/brigade"
                    (or (getenv "XDG_STATE_HOME")
                        (expand-file-name ".local/state" "~")))
  "Directory for brigade runtime state that should survive a restart.
Holds plan checkpoints and agent records.  Rebuildable in principle, but
losing it loses in-flight run history."
  :type 'directory
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-cache-dir
  (expand-file-name "cmacs/brigade"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Directory for brigade data that is cheap to throw away and rebuild."
  :type 'directory
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-worktree-root
  (expand-file-name "trees" cmacs-brigade-cache-dir)
  "Where `worktree' isolation creates per-agent git worktrees.

Deliberately outside the repository being worked on.  A worktree under
the repo (say ./trees/) is walked by every other agent's `rg' and
`find', which turns every search into duplicate hits across sibling
checkouts."
  :type 'directory
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-runtime-dir
  (expand-file-name "cmacs/brigade"
                    (or (getenv "XDG_RUNTIME_DIR")
                        (expand-file-name "cmacs-brigade" temporary-file-directory)))
  "Directory for per-agent capability tokens and MCP config files.

These are secrets with a session lifetime.  The directory is created
0700 and the files 0600.  When XDG_RUNTIME_DIR is unset the fallback is
under `temporary-file-directory', which may be world-readable -- the
file modes still apply, but a real XDG_RUNTIME_DIR is preferred."
  :type 'directory
  :group 'cmacs-brigade)


;;;; Feature probes

(defun cmacs-brigade-available-p ()
  "Return non-nil when this cmacs was built --with-cmacs-ai-brigade."
  (and (fboundp 'cmacs-brigade-supported-p)
       (cmacs-brigade-supported-p)))

(defun cmacs-brigade-capability (key)
  "Return the compile-time brigade capability KEY, a keyword.

Known keys are :libreclaw, :mcp and :f16c.  Returns nil when brigade is
not compiled in, so callers can probe without guarding first."
  (and (fboundp 'cmacs-brigade-capabilities)
       (plist-get (cmacs-brigade-capabilities) key)))

(defun cmacs-brigade--check-abi ()
  "Signal if the C ABI version is not the one this file expects."
  (when (fboundp 'cmacs-brigade-abi-version)
    (let ((got (cmacs-brigade-abi-version)))
      (unless (equal got cmacs-brigade-abi-expected)
        (error "cmacs-brigade: ABI mismatch (C reports %s, Lisp expects %s); \
recompile lisp/cmacs and clear native-lisp/"
               got cmacs-brigade-abi-expected)))))

;;;###autoload
(defun cmacs-brigade-version ()
  "Show the brigade ABI version and compiled-in capabilities."
  (interactive)
  (if (not (cmacs-brigade-available-p))
      (message "cmacs-brigade: not compiled in (needs --with-cmacs-ai-brigade)")
    (message "cmacs-brigade: ABI %s  libreclaw:%s  mcp:%s  f16c:%s"
             (cmacs-brigade-abi-version)
             (if (cmacs-brigade-capability :libreclaw) "yes" "no")
             (if (cmacs-brigade-capability :mcp) "yes" "no")
             (if (cmacs-brigade-capability :f16c) "yes" "no"))))

;;;###autoload
(defalias 'cmacs-ai-brigade #'cmacs-brigade-version
  "Alias so \\[execute-extended-command] cmacs-ai-<TAB> discovers the brigade.
The subsystem's own symbols use the shorter `cmacs-brigade-' prefix.")

(when (cmacs-brigade-available-p)
  (cmacs-brigade--check-abi))


(provide 'cmacs-brigade)

;; Load the rest of the fabric eagerly when brigade is compiled in.
;;
;; After `provide' rather than before, because every one of these
;; requires this file back -- they need the defgroup and the paths --
;; and doing it above would be a recursive require.
;;
;; Eager at all because the registries must be populated before cmacs's
;; MCP server publishes its tool set to a new session, and a session can
;; open before any user code has run; an external agent connecting at
;; startup would otherwise see the built-in tools and none of the
;; brigade's.
(when (cmacs-brigade-available-p)
  (require 'cmacs-brigade-registry)
  (require 'cmacs-brigade-tools)
  (require 'cmacs-brigade-memory nil 'noerror)
  (require 'cmacs-brigade-agent-def nil 'noerror)
  (require 'cmacs-brigade-isolation nil 'noerror)
  (require 'cmacs-brigade-host nil 'noerror)
  ;; The runner itself.  Nothing autoloads it and the dashboard and
  ;; scheduler both call into it, so leaving it out made `s' in the
  ;; dashboard and every scheduled fire die on a void
  ;; `cmacs-brigade-start-task'.
  (require 'cmacs-brigade-run nil 'noerror)
  (require 'cmacs-brigade-genmail nil 'noerror)
  (require 'cmacs-brigade-deliver nil 'noerror)
  ;; Eager for the same reason, and for one more: notification is only
  ;; useful if it is already listening when the run you walked away from
  ;; finishes.  Arming it on first use would mean it is never armed for
  ;; the run that most needed it.
  (require 'cmacs-brigade-notify nil 'noerror)
  (require 'cmacs-brigade-voice nil 'noerror)
  ;; Loaded so its tools and dashboard panel register; nothing is armed
  ;; until `cmacs-brigade-schedule-mode' is turned on.  Loading a file
  ;; must not start firing jobs.
  (require 'cmacs-brigade-schedule nil 'noerror))

;; The AI layers over imgedit and vidstudio are NOT loaded from here.
;; They depend on the brigade registry, not the other way round, and
;; requiring them here as well makes that a cycle.  Each one requires
;; what it needs and registers its own tools.

;;; cmacs-brigade.el ends here
