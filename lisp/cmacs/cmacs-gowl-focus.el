;;; cmacs-gowl-focus.el --- Prefix-key focus redirection for --gowl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Replaces the old ESC-timer state machine in cmacs-gowl.c with an
;; Elisp-driven policy.  Three key flavours:
;;
;;   * `cmacs-gowl-prefix-keys' (C-x, C-c, M-x, ...) redirect focus
;;     to Emacs, let the key pass through, then `post-command-hook'
;;     pops focus back to the embed once the command finishes.
;;
;;   * Plain ESC is a hardcoded "sticky" redirect in the C intercept:
;;     it consumes the key, redirects focus to Emacs, and stays there
;;     until the user explicitly returns focus (clicks on the embed,
;;     presses one of the return bindings below, or calls
;;     `gowl-return-focus-to-embed').  This mirrors the pre-Wave-1b
;;     ESC escape-hatch without the 200 ms timer.
;;
;;   * Control+ESC is a regular prefix key that reaches Emacs so it
;;     can be bound to `cmacs-gowl-focus-send-escape-to-embed' — a
;;     command that forwards a literal ESC keypress to the embed.
;;     Use it to send ESC to an app (e.g. Firefox) when focus has
;;     been captured by Emacs.
;;
;; The policy is installed as a `GowlStaticPrefixKeyPolicy' GObject;
;; users who want richer logic can subclass the
;; `GowlPrefixKeyPolicy' interface and set it via
;; `(gobject-set (gowl-compositor) "prefix-key-policy" POLICY)'.

;;; Code:

(require 'cl-lib)

(defgroup cmacs-gowl-focus nil
  "Prefix-key focus redirection under --gowl."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-focus-")

(defcustom cmacs-gowl-prefix-keys
  '("Control+x"
    "Control+c"
    "Control+g"
    "Control+h"
    "Meta+x"
    "Control+Escape")
  "Key combinations that force focus back to Emacs during --gowl.
Each element is a keybind string parseable by the compositor's
`gowl_keybind_parse' (same grammar as YAML keybinds: modifier tokens
joined by `+', ending with an XKB key name).  When any embedded
Wayland client holds keyboard focus and one of these presses
arrives, the compositor pushes a seat focus redirect so the key
reaches the Emacs client instead.  `post-command-hook' then calls
`gowl-return-focus-to-embed' to restore the saved focus.

`Control+Escape' is included so the Emacs-side binding for that
combo (`cmacs-gowl-focus-send-escape-to-embed', bound globally by
`cmacs-gowl-focus-setup') runs and can forward a literal ESC to
the embed.  Plain `Escape' is NOT here — it's hardcoded in the C
intercept as a sticky redirect (no auto-pop); see the module
commentary.

Set to nil to disable prefix-key redirection entirely (embeds
own keyboard focus uninterrupted, matching standalone gowl)."
  :type '(repeat string)
  :group 'cmacs-gowl-focus)

(defvar cmacs-gowl-focus--installed nil
  "Non-nil when the prefix-key policy is currently installed.
Tracks install state so re-enabling the mode is idempotent.")

(defun cmacs-gowl-focus--install-policy ()
  "Push `cmacs-gowl-prefix-keys' into the compositor.
No-op when gowl isn't running."
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (gowl-set-prefix-key-policy cmacs-gowl-prefix-keys)
    (setq cmacs-gowl-focus--installed t)))

(defun cmacs-gowl-focus--uninstall-policy ()
  "Clear the compositor prefix-key policy."
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (gowl-set-prefix-key-policy nil))
  (setq cmacs-gowl-focus--installed nil))

(defun cmacs-gowl-focus--post-command ()
  "If a non-sticky focus redirect is active, restore the saved focus.
Called from `post-command-hook' after every command.  Sticky
redirects (plain ESC or explicit `gowl-grant-focus-to-emacs'
calls) are deliberately left alone — the user wanted to stay in
Emacs, not be bounced back to the embed after a single command.
No-op when no redirect is active."
  (when (and (fboundp 'gowl-focus-redirect-active-p)
             (gowl-focus-redirect-active-p)
             (not (and (fboundp 'gowl-focus-redirect-sticky-p)
                       (gowl-focus-redirect-sticky-p))))
    (gowl-return-focus-to-embed)))

;; XKB hardware keycode for the Escape key on PC keyboards
;; (evdev KEY_ESC = 1; wlroots uses the +8 convention, giving 9).
;; Hardcoded because `gowl-send-key' takes a keycode, not a keysym,
;; and ESC's position is stable across common keymaps.
(defconst cmacs-gowl-focus--escape-keycode 9
  "XKB hardware keycode for the Escape key.")

(defun cmacs-gowl-focus-send-escape-to-embed ()
  "Send a literal ESC keypress to the focused embed.
Bound to Control+Escape so the prefix-key policy steals focus
from the embed, Emacs receives the C-ESC, and this command
forwards a bare ESC to the app (e.g. Firefox) before handing
focus back.  No-op when no focus redirect is active and no
embed is focused."
  (interactive)
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    ;; Return focus to the embed first so gowl-send-key targets
    ;; the client that wanted the ESC, not the Emacs surface.
    (when (and (fboundp 'gowl-focus-redirect-active-p)
               (gowl-focus-redirect-active-p))
      (gowl-return-focus-to-embed))
    (gowl-send-key cmacs-gowl-focus--escape-keycode t)
    (gowl-send-key cmacs-gowl-focus--escape-keycode nil)))

(defun cmacs-gowl-focus-apply-prefix-keys ()
  "Re-push `cmacs-gowl-prefix-keys' into the compositor.
Call after `setq'-ing the defcustom at runtime."
  (interactive)
  (cmacs-gowl-focus--install-policy))

(defun cmacs-gowl-focus-setup ()
  "Install the prefix-key policy, post-command hook, and C-ESC bind.
Idempotent: safe to call multiple times."
  (cmacs-gowl-focus--install-policy)
  (add-hook 'post-command-hook #'cmacs-gowl-focus--post-command)
  ;; Global binding so the command runs regardless of which
  ;; buffer is current when C-ESC arrives at Emacs.
  (global-set-key (kbd "C-<escape>")
                  #'cmacs-gowl-focus-send-escape-to-embed))

(defun cmacs-gowl-focus-teardown ()
  "Uninstall the prefix-key policy, post-command hook, and C-ESC bind."
  (remove-hook 'post-command-hook #'cmacs-gowl-focus--post-command)
  (when (eq (global-key-binding (kbd "C-<escape>"))
            #'cmacs-gowl-focus-send-escape-to-embed)
    (global-unset-key (kbd "C-<escape>")))
  (cmacs-gowl-focus--uninstall-policy))

(provide 'cmacs-gowl-focus)
;;; cmacs-gowl-focus.el ends here
