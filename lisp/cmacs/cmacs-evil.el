;;; cmacs-evil.el --- Evil/Doom keymap compatibility for cmacs modes -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Several cmacs major modes are read-only "console" buffers driven by
;; single-letter keys (`cmacs-transcribe', `cmacs-transcode', ...).  Under
;; Evil -- and therefore under Doom Emacs, which enables Evil plus a stack
;; of Evil add-ons -- a plain major-mode keymap is not enough to make those
;; keys fire, because Evil resolves keys through `evil-mode-map-alist',
;; which sits in `emulation-mode-map-alists' *ahead of* the major-mode map.
;;
;; Evil's precedence stack, highest first (see `evil-state-keymaps' in
;; evil-core.el):
;;
;;   1. intercept keymaps        `evil-make-intercept-map'
;;   2. the state's local keymap `evil-normal-state-local-map'
;;   3. minor-mode state keymaps `evil-define-minor-mode-key' (evil-snipe!)
;;   4. auxiliary keymaps        `evil-define-key' on a keymap
;;   5. overriding keymaps       `evil-make-overriding-map'
;;   6. the state's global map   `evil-normal-state-map'
;;
;; `evil-make-overriding-map' alone -- the obvious fix, and what these modes
;; used to do -- only wins against level 6.  In Doom it still loses `s', `S'
;; (evil-snipe-local-mode, normal + motion state) and `f', `F', `t', `T'
;; (evil-snipe-override-local-mode, motion state), because those live in
;; level 3.  That is the "s/S do nothing in the transcribe menu" bug.
;;
;; `cmacs-evil-setup-mode-map' fixes it structurally instead of
;; package-by-package: it copies the mode map's *own* bindings into the
;; auxiliary keymap for each requested state and marks that auxiliary map as
;; an intercept map, i.e. level 1.  Nothing an Evil add-on binds can shadow
;; them any more, and only the keys the mode actually binds are affected --
;; keys it does not bind (`SPC' for the Doom leader, `C-w', `ESC', `:', `/',
;; digit arguments, ...) still fall through to Evil untouched.  As a
;; courtesy it also registers the mode in `evil-snipe-disabled-modes', so
;; evil-snipe does not light up its lighter in a buffer where its keys can
;; never fire.
;;
;; Nothing here requires Evil: with plain Emacs the call is a no-op, and if
;; Evil loads later the work is deferred with `with-eval-after-load'.  A
;; user config that rebinds keys after load still wins, because
;; `evil-define-key' on the same mode map writes into the very keymap this
;; file marks as intercept.

;;; Code:

(defconst cmacs-evil-intercept-states '(normal motion)
  "Evil states in which a cmacs single-key mode map is made to win.
Normal and motion cover every state such a read-only buffer is entered
in; insert, visual, replace and Emacs state are deliberately left alone
so Evil behaves normally there.")

;; Evil is an external package: it may be absent at byte-compile time.
(declare-function evil-make-overriding-map "evil-core" (keymap &optional state copy))
(declare-function evil-make-intercept-map "evil-core" (keymap &optional state aux))
(declare-function evil-get-auxiliary-keymap "evil-core"
                  (map state &optional create ignore-parent))
(declare-function evil-normalize-keymaps "evil-core" (&optional state))
(defvar evil-snipe-disabled-modes)

(defun cmacs-evil--own-bindings (map)
  "Return MAP's own bindings as an alist of (EVENT . DEFINITION).
Only what MAP itself binds is returned.  Two classes of entry are
skipped:

- bindings inherited from MAP's parent -- for a `define-derived-mode'
  keymap the parent is `special-mode-map', and promoting its keys (`SPC',
  `DEL', `n', `p', ...) to intercept precedence would shadow Evil and the
  Doom leader;
- Evil's own bookkeeping, which it stores inside the keymap itself: the
  `[override-state]' / `[intercept-state]' markers and the per-state
  auxiliary keymaps (`[normal-state]' and friends), so that re-running
  the setup does not copy a previous run's scaffolding.

The definition is looked up in MAP rather than taken from the temporary
parentless copy used for the walk, so a prefix keymap is returned as the
live object, not a snapshot."
  (let ((copy (copy-keymap map))
        (result nil))
    (set-keymap-parent copy nil)
    (map-keymap
     (lambda (event _definition)
       (unless (or (consp event)          ;a character range from a char-table
                   (and (symbolp event)
                        (string-suffix-p "-state" (symbol-name event))))
         (push (cons event (lookup-key map (vector event))) result)))
     copy)
    (nreverse result)))

(defun cmacs-evil--install (map states copy)
  "Give MAP precedence over Evil in each state in STATES.
When COPY is non-nil the map's own bindings are copied into each state's
auxiliary keymap first; otherwise only the auxiliary keymaps the mode has
already filled in with `evil-define-key*' are promoted."
  ;; Layer 1: the whole map outranks Evil's global state keymaps in every
  ;; state.  This is what these modes used to do on its own; it is kept as a
  ;; floor for the states not listed in STATES (visual, replace, operator).
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map map))
  ;; Layer 2: per state, copy the mode's own bindings into that state's
  ;; auxiliary keymap and mark the auxiliary keymap as an intercept map.
  ;; Intercept maps top Evil's precedence stack, so minor-mode maps such as
  ;; evil-snipe's (which owns `s'/`S' in normal+motion and `f'/`F'/`t'/`T'
  ;; in motion) can no longer swallow the mode's keys.
  (when (and (fboundp 'evil-get-auxiliary-keymap)
             (fboundp 'evil-make-intercept-map))
    (let ((bindings (and copy (cmacs-evil--own-bindings map))))
      (dolist (state states)
        (let ((aux (evil-get-auxiliary-keymap map state t t)))
          (dolist (binding bindings)
            (define-key aux (vector (car binding)) (cdr binding))))
        (evil-make-intercept-map map state t))))
  ;; Evil caches the resolved keymap list per buffer in `evil-mode-map-alist',
  ;; built when the major mode was entered.  Buffers that already run MAP --
  ;; the queue buffer a user left open while Evil or this file loaded -- must
  ;; be rebuilt or they keep the stale, pre-intercept order.
  (when (fboundp 'evil-normalize-keymaps)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (bound-and-true-p evil-local-mode)
                   (eq (current-local-map) map))
          (evil-normalize-keymaps))))))

;;;###autoload
(defun cmacs-evil-setup-mode-map (map &optional mode states)
  "Make the single-key bindings in MAP win under Evil, and so under Doom.

MAP is a major-mode keymap whose own bindings should fire verbatim in a
read-only cmacs buffer.  They are installed as an Evil intercept map for
every state in STATES (default `cmacs-evil-intercept-states'), which puts
them above Evil's state maps *and* above minor-mode maps such as
evil-snipe -- the reason `s' and `S' would otherwise do nothing.  Keys
MAP does not bind are untouched, so the Doom leader, `C-w', `ESC' and
friends keep working.

MODE, when non-nil, is the major mode owning MAP.  It is added to
`evil-snipe-disabled-modes' so evil-snipe does not turn on in those
buffers at all (no stray lighter, no `;'/`,' transient map).

Calling this with Evil absent is a no-op, and calling it before Evil
loads defers the work; it is safe to call repeatedly, so a file may run
it at load time.  A user config that binds keys afterwards still wins,
because `evil-define-key' writes into the same auxiliary keymap."
  (cmacs-evil--setup map mode states t))

;;;###autoload
(defun cmacs-evil-intercept-mode-map (map &optional mode states)
  "Give MAP's existing Evil auxiliary keymaps intercept precedence.

This is `cmacs-evil-setup-mode-map' minus the copying step, for a mode
that already installs its keys per state with `evil-define-key*' and
wants exactly those bindings kept: only the auxiliary keymaps that
already exist are promoted, so minor-mode maps such as evil-snipe's stop
shadowing them.  MODE and STATES mean the same as in
`cmacs-evil-setup-mode-map'.

The auxiliary keymap is created if it does not exist yet, so the call
order relative to the `evil-define-key*' block does not matter; keeping
the two together just makes the intent obvious."
  (cmacs-evil--setup map mode states nil))

(defun cmacs-evil--setup (map mode states copy)
  "Shared body of the two entry points above; COPY selects which one.
The work is deferred with `with-eval-after-load' when Evil has not
loaded yet, which is the normal case at file-load time."
  (let ((states (or states cmacs-evil-intercept-states)))
    (if (featurep 'evil)
        (cmacs-evil--install map states copy)
      (with-eval-after-load 'evil
        (cmacs-evil--install map states copy))))
  (when mode
    (with-eval-after-load 'evil-snipe
      (add-to-list 'evil-snipe-disabled-modes mode))))

(provide 'cmacs-evil)
;;; cmacs-evil.el ends here
