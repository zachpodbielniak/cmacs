;;; cmacs-piper-context-menu.el --- PGTK right-click TTS menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Adds entries to `context-menu-functions' (Emacs 28+, used by
;; `context-menu-mode' / mouse-3) that contextually show:
;;
;;   "Speak selection (Piper)"  -- active region
;;   "Speak sentence (Piper)"   -- no region, sentence-at-point
;;   "Stop speaking"            -- playback in flight
;;
;; The integration installs itself at startup via `after-init-hook'
;; (bootstrapped from an autoload cookie in loaddefs.el), so the menu
;; entry is available before the user calls any `cmacs-piper-*'
;; command for the first time.  When the entry is clicked, it
;; autoloads `cmacs-piper' on demand.
;;
;; Doom Emacs awareness: Doom leaves `mouse-3' bound to
;; `mouse-save-then-kill' and does NOT enable `context-menu-mode' by
;; default, so the right-click never reaches `context-menu-map' and
;; our entry is invisible.  The bootstrap detects this (and also any
;; other config where mouse-3 isn't routed through context-menu-mode)
;; and (a) turns on `context-menu-mode' and (b) -- only when needed --
;; rebinds mouse-3 globally.

;;; Code:

;; Do NOT (require 'cmacs-piper) at load time -- cmacs-piper.el is
;; what loads us, and we want this file safe to autoload before any
;; piper command has run.  Forward-declare what we touch.
(require 'mouse)
(require 'menu-bar)
(declare-function cmacs-piper-speak-region "cmacs-piper" (beg end))
(declare-function cmacs-piper-stop         "cmacs-piper" ())
(defvar cmacs-piper--playback-stack)

;;;###autoload
(defvar cmacs-piper-auto-enable-context-menu t
  "When non-nil, install the cmacs-piper context-menu entry at startup
and enable `context-menu-mode' globally.  Set to nil BEFORE init to
opt out.  Toggle later with \\[cmacs-piper-context-menu-mode].")

;;;###autoload
(defvar cmacs-piper-override-mouse-3 t
  "When non-nil, the startup bootstrap rebinds `mouse-3' to
`context-menu-map' if it's currently bound to something else (e.g.
Doom's default `mouse-save-then-kill').  Without this, our context-
menu entry is unreachable in Doom and similar configs.

Set to nil if you want to keep your existing mouse-3 binding.")

;; ── Menu entry ─────────────────────────────────────────────────────

(defun cmacs-piper-context-menu-entry (menu _click)
  "Append cmacs-piper TTS entries to MENU based on current context."
  (when (display-graphic-p)
    (define-key-after menu [separator-cmacs-piper] menu-bar-separator)
    (cond
     ((use-region-p)
      (define-key-after menu [cmacs-piper-speak-selection]
        '(menu-item "Speak selection (Piper)"
                    cmacs-piper-speak-region
                    :help "Synthesise the highlighted text and play it")))
     (t
      (define-key-after menu [cmacs-piper-speak-sentence]
        `(menu-item "Speak sentence (Piper)"
                    (lambda () (interactive)
                      (require 'cmacs-piper)
                      (save-excursion
                        (let* ((beg (progn (backward-sentence) (point)))
                               (end (progn (forward-sentence) (point))))
                          (cmacs-piper-speak-region beg end))))
                    :help "Synthesise the sentence at point"))))
    (when (and (boundp 'cmacs-piper--playback-stack)
               cmacs-piper--playback-stack)
      (define-key-after menu [cmacs-piper-stop]
        '(menu-item "Stop speaking"
                    cmacs-piper-stop
                    :help "Interrupt the most recent in-flight playback"))))
  menu)

;; ── Minor mode (interactive toggle) ────────────────────────────────

;;;###autoload
(define-minor-mode cmacs-piper-context-menu-mode
  "Add Piper TTS entries to the right-click context menu.

Enables `context-menu-mode' as a side effect; without it the entry
in `context-menu-functions' is never invoked."
  :global t
  :init-value nil
  (if cmacs-piper-context-menu-mode
      (progn
        (add-to-list 'context-menu-functions
                     #'cmacs-piper-context-menu-entry 'append)
        (unless (bound-and-true-p context-menu-mode)
          (context-menu-mode 1)))
    (setq context-menu-functions
          (delq #'cmacs-piper-context-menu-entry context-menu-functions))))

;; ── Startup bootstrap (Doom-aware) ─────────────────────────────────

;;;###autoload
(defun cmacs-piper-context-menu-bootstrap ()
  "Install the Piper context-menu entry + enable context-menu-mode.

Run automatically from `after-init-hook'.  Idempotent; safe to call
manually with \\[cmacs-piper-context-menu-bootstrap].

Honours `cmacs-piper-auto-enable-context-menu' (opt-out for the
whole bootstrap) and `cmacs-piper-override-mouse-3' (opt-out for the
Doom-aware mouse-3 rebind specifically)."
  (interactive)
  (cond
   ;; --batch and other non-interactive sessions: no display, no menus,
   ;; no point.  Also avoids spurious noise during autoloads generation.
   ((and noninteractive (not (called-interactively-p 'any))) nil)
   ((not cmacs-piper-auto-enable-context-menu)
    (when (called-interactively-p 'any)
      (user-error
       "cmacs-piper-auto-enable-context-menu is nil; opting out")))
   (t
    (cmacs-piper-context-menu--bootstrap-1))))

(defun cmacs-piper-context-menu--bootstrap-1 ()
  "Actual bootstrap work; gated by `cmacs-piper-context-menu-bootstrap'."
  (cmacs-piper-context-menu-mode 1)
  ;; Doom-aware fallback.  context-menu-mode installs a remap on
  ;; mouse-3 in `context-menu-mode-map' which usually wins, but Doom
  ;; (and a few other configs) bind mouse-3 in a more specific keymap
  ;; that shadows it -- typically `mouse-save-then-kill' from
  ;; global-map left over from when context-menu-mode wasn't enabled.
  ;; Detect and rebind only when actually needed.
  (when (and cmacs-piper-override-mouse-3
             ;; context-menu-map is only defvar'd once context-menu-mode
             ;; runs; without it the global-set-key below would error.
             ;; context-menu-mode 1 above should have done that, but
             ;; tolerate weird load orders.
             (boundp 'context-menu-map))
    (let* ((after-toggle (lookup-key global-map [mouse-3]))
           (looks-like-context (or (eq after-toggle 'context-menu-map)
                                   (keymapp after-toggle))))
      (unless looks-like-context
        (let ((was after-toggle))
          (global-set-key [mouse-3] context-menu-map)
          (when (or (featurep 'doom) (boundp 'doom-version))
            (message
             "cmacs-piper: Doom detected with mouse-3 -> %s; rebound to context-menu-map.  (Set cmacs-piper-override-mouse-3 to nil to keep your original binding.)"
             was)))))))

;;;###autoload
(add-hook 'after-init-hook #'cmacs-piper-context-menu-bootstrap)

;; If this file is loaded AFTER init has already finished (e.g. user
;; required cmacs-piper mid-session), the after-init-hook above will
;; never fire.  Bootstrap directly in that case.  Skip in --batch.
(when (and after-init-time (not noninteractive))
  (cmacs-piper-context-menu-bootstrap))

(provide 'cmacs-piper-context-menu)

;;; cmacs-piper-context-menu.el ends here
