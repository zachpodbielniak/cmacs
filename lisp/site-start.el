;;; site-start.el --- bootstrap embedded Doom on Android first launch  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Loaded automatically by Emacs during startup, BEFORE
;; `early-init.el' and `user-init-file' (see `site-run-file' in
;; lisp/startup.el; the load is at line ~1525, after
;; `user-emacs-directory' and `startup-init-directory' are set but
;; before any user file runs).
;;
;; Sole responsibility on Android builds: if HOME has no Doom config
;; yet AND the APK shipped a Doom bundle under /assets/doom-bundle/,
;; copy `/assets/doom-bundle/emacs/' → `~/.config/emacs/' and
;; `/assets/doom-bundle/doom/' → `~/.config/doom/', then re-point
;; `user-emacs-directory' and `startup-init-directory' so the
;; subsequent early-init / init load picks up Doom.
;;
;; On every other build (host pgtk/Wayland, GUI Linux desktop) the
;; `system-configuration' string does not contain "android", so the
;; whole file short-circuits to a no-op.  Safe to ship in lisp/
;; unconditionally.
;;
;; Idempotent: subsequent launches see early-init.el / init.el
;; already in place and skip the copy.  The user is free to edit
;; their config on-device — we never overwrite an existing file.

;;; Code:

(defvar cmacs-android--asset-root
  (when (and (boundp 'system-configuration)
             (stringp system-configuration)
             (string-match-p "android" system-configuration))
    ;; The Android build extracts assets into a virtual filesystem
    ;; rooted at `/assets'; build-aux/android-build.sh stages the
    ;; bundle into build-aux/android-doom-bundle/ and the patched
    ;; java/Makefile.in copies that into `assets/doom-bundle/' under
    ;; the APK.  Allow an env-var override for testing.
    (or (getenv "EMACS_ANDROID_DOOM_BUNDLE")
        "/assets/doom-bundle"))
  "Root of the bundled Doom Emacs tree shipped inside the APK.
Nil on every non-Android build.  Two subdirectories are expected:

  emacs/ — copy of the host user's `~/.config/emacs' (Doom core).
  doom/  — copy of the host user's `~/.config/doom'  (private).")

(defun cmacs-android--seed-tree (src-rel target-abs marker-rel)
  "Copy SRC-REL (under the bundle root) into TARGET-ABS, once.
The copy is skipped when TARGET-ABS already contains MARKER-REL —
that's how we detect a previously-seeded HOME and avoid clobbering
the user's edits on subsequent launches.

Returns t if a copy happened, nil otherwise."
  (let ((src (expand-file-name src-rel cmacs-android--asset-root)))
    (cond
     ;; Already seeded → leave the user's tree alone.
     ((file-exists-p (expand-file-name marker-rel target-abs))
      nil)
     ;; Bundle entry missing → nothing to do (e.g. user built APK
     ;; without their private config — that's fine).
     ((not (file-directory-p src))
      nil)
     (t
      (make-directory target-abs t)
      ;; copy-directory args: SRC TARGET KEEP-TIME PARENTS COPY-CONTENTS
      ;; The fifth arg t flattens — we want SRC's *contents* under
      ;; TARGET, not SRC nested inside it.
      (copy-directory src target-abs nil t t)
      t))))

(defun cmacs-android--seed-doom ()
  "Seed `~/.config/{emacs,doom}' from the bundled Doom tree.
Updates `user-emacs-directory' and `startup-init-directory' so the
subsequent early-init / init load resolves to the seeded tree.

A no-op when the bundle isn't shipped or HOME already has a Doom
core (detected by presence of `early-init.el')."
  (let* ((home          (or (getenv "HOME") "~"))
         (target-emacs  (file-name-as-directory
                         (expand-file-name ".config/emacs" home)))
         (target-doom   (file-name-as-directory
                         (expand-file-name ".config/doom"  home)))
         (seeded-core
          (cmacs-android--seed-tree "emacs" target-emacs "early-init.el"))
         (seeded-priv
          (cmacs-android--seed-tree "doom"  target-doom  "init.el")))
    (when (or seeded-core seeded-priv)
      (message "cmacs-android: seeded Doom from /assets (core=%s priv=%s)"
               (if seeded-core "yes" "skip")
               (if seeded-priv "yes" "skip")))
    ;; Re-point load resolution at `~/.config/emacs/' regardless of
    ;; whether we just seeded or the user already had it: on Android
    ;; with no `~/.emacs.d', `startup--xdg-or-homedot' (called
    ;; before site-start runs, see startup.el:1502) defaults to
    ;; `~/.emacs.d/' on a virgin HOME.  Override now so early-init
    ;; / init.el load from the right place.
    (when (file-directory-p target-emacs)
      (setq user-emacs-directory   target-emacs)
      (when (boundp 'startup-init-directory)
        (setq startup-init-directory target-emacs)))))

(when cmacs-android--asset-root
  ;; Wrap in condition-case so a malformed bundle never bricks
  ;; startup — fall through to whatever Emacs would have done
  ;; without us, with a Messages-buffer trace.
  (condition-case err
      (cmacs-android--seed-doom)
    (error
     (message "cmacs-android: seeding failed: %S" err))))

(provide 'site-start)

;;; site-start.el ends here
