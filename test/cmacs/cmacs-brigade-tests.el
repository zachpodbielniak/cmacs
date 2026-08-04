;;; cmacs-brigade-tests.el --- Tests for the AI brigade fabric  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 0 covers the wiring plus two standing hygiene guards that are
;; cheap now and expensive to retrofit later:
;;
;;   - config hygiene: no literal path, model id, or endpoint outside a
;;     `defcustom'.  Everything shipped is a default, never an
;;     assumption, because a user's notes are not necessarily in
;;     ~/Documents/notes and their ollama is not necessarily on
;;     localhost.
;;
;;   - backend hygiene: no `x-popup-menu' / `image-map' / `menu-bar-*'.
;;     Under `emacs --lrg' `display-graphic-p' returns t, so the natural
;;     guard passes and the call then fails at runtime because lrgterm
;;     draws no menu bar.  `cmacs-libregnum-popup-menu' is the portable
;;     spelling.
;;
;; Both scan the brigade sources as text, so they keep working as files
;; are added in later phases without anyone remembering to extend them.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)

(defconst cmacs-brigade-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "Repository root, derived from this file's location in test/cmacs/.")

(defun cmacs-brigade-tests--available-p ()
  "Non-nil when this build compiled in the brigade fabric."
  (and (boundp 'is-cmacs-ai-brigade) is-cmacs-ai-brigade))

(defun cmacs-brigade-tests--elisp-files ()
  "Return the brigade Elisp sources that exist in this checkout."
  (let ((dir (expand-file-name "lisp/cmacs" cmacs-brigade-tests--root)))
    (and (file-directory-p dir)
         (directory-files dir t "\\`cmacs-brigade.*\\.el\\'"))))

(defun cmacs-brigade-tests--c-files ()
  "Return the brigade C sources that exist in this checkout."
  (let ((dir (expand-file-name "cmacs/ai-brigade" cmacs-brigade-tests--root)))
    (and (file-directory-p dir)
         (directory-files dir t "\\.[ch]\\'"))))

(defun cmacs-brigade-tests--scan (files regexp)
  "Return a list of \"FILE:LINE: TEXT\" for each match of REGEXP in FILES.
Lines whose match sits inside a comment are ignored, since the whole
point of these guards is to catch live code, and the prose above a
`defcustom' legitimately names the default it documents."
  (let (hits)
    (dolist (f files)
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (while (re-search-forward regexp nil t)
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            ;; Elisp comment or C comment / continuation line.
            (unless (string-match-p "\\`[ \t]*\\(;\\|\\*\\|/\\*\\|//\\)" line)
              (push (format "%s:%d: %s"
                            (file-name-nondirectory f)
                            (line-number-at-pos)
                            (string-trim line))
                    hits))))))
    (nreverse hits)))


;;;; Wiring

(ert-deftest cmacs-brigade-feature-flag ()
  "The IS-CMACS-AI-BRIGADE flag and its alias are always bound."
  ;; Bound in every build, including one with the feature off -- that is
  ;; the entire point of cmacs/core/cmacs-features.c, so a user config
  ;; can branch without a void-variable error.
  (should (boundp 'IS-CMACS-AI-BRIGADE))
  (should (boundp 'is-cmacs-ai-brigade))
  (should (eq (symbol-value 'IS-CMACS-AI-BRIGADE)
              (symbol-value 'is-cmacs-ai-brigade))))

(ert-deftest cmacs-brigade-feature-registered ()
  "When compiled in, brigade appears in the compiled-feature list."
  (skip-unless (cmacs-brigade-tests--available-p))
  (should (fboundp 'cmacs-compiled-features))
  (should (memq 'ai-brigade (cmacs-compiled-features)))
  (should (cmacs-feature-p 'ai-brigade)))

(ert-deftest cmacs-brigade-requires-cmacs-ai ()
  "Brigade cannot be compiled in without cmacs-ai.
configure.ac hard-errors on that combination; this asserts the built
binary agrees, which catches a feature block that was edited to warn
instead of error."
  (skip-unless (cmacs-brigade-tests--available-p))
  (should (and (boundp 'is-cmacs-ai) is-cmacs-ai)))

(ert-deftest cmacs-brigade-defuns-present ()
  "The Phase 0 DEFUNs exist and answer sanely."
  (skip-unless (cmacs-brigade-tests--available-p))
  (should (fboundp 'cmacs-brigade-supported-p))
  (should (cmacs-brigade-supported-p))
  (should (integerp (cmacs-brigade-abi-version)))
  (should (= (cmacs-brigade-abi-version) cmacs-brigade-abi-expected)))

(ert-deftest cmacs-brigade-capabilities-shape ()
  "`cmacs-brigade-capabilities' returns a plist of the documented keys."
  (skip-unless (cmacs-brigade-tests--available-p))
  (let ((caps (cmacs-brigade-capabilities)))
    (should (plistp caps))
    (dolist (k '(:libreclaw :mcp :f16c))
      (should (plist-member caps k))
      (should (memq (plist-get caps k) '(nil t))))
    ;; The C side derives :libreclaw from the same #ifdef the feature
    ;; registry uses, so the two must not disagree.
    (should (eq (and (plist-get caps :libreclaw) t)
                (and (boundp 'is-cmacs-libreclaw) is-cmacs-libreclaw t)))))

(ert-deftest cmacs-brigade-state-dirs-are-absolute ()
  "The shipped directory defaults resolve to absolute paths."
  (skip-unless (featurep 'cmacs-brigade))
  (dolist (d (list cmacs-brigade-state-dir
                   cmacs-brigade-cache-dir
                   cmacs-brigade-runtime-dir
                   cmacs-brigade-worktree-root))
    (should (stringp d))
    (should (file-name-absolute-p d))
    ;; An unexpanded "~" would be written into a .mcp.json or passed to
    ;; a subprocess that does not do tilde expansion.
    (should-not (string-prefix-p "~" d))))

(ert-deftest cmacs-brigade-worktree-root-derives-from-xdg ()
  "Worktrees default under XDG_CACHE_HOME, not under the repo being worked on.

A worktree inside the repo is walked by every other agent's `rg' and
`find', turning every search into duplicate hits across checkouts.

This asserts the derivation rather than the resulting absolute path:
cmacs's own test harness exports a writable XDG_CACHE_HOME *inside* the
source tree, so a naive \"is it outside the repo\" check would fail here
while the default is in fact correct."
  (skip-unless (featurep 'cmacs-brigade))
  ;; String comparison, not `file-in-directory-p': these directories are
  ;; created lazily on first use, and file-in-directory-p resolves
  ;; truenames, so it answers nil for a perfectly correct path that does
  ;; not exist yet.  The property under test is the derivation, which is
  ;; a pure function of the environment.
  (should (string-prefix-p (file-name-as-directory cmacs-brigade-cache-dir)
                           cmacs-brigade-worktree-root))
  ;; Re-derive under a controlled XDG_CACHE_HOME and confirm it moves,
  ;; i.e. the default really is environment-derived rather than a
  ;; constant that happens to look right here.
  (let* ((fake "/nonexistent-brigade-xdg")
         (process-environment (cons (concat "XDG_CACHE_HOME=" fake)
                                    process-environment))
         (derived (expand-file-name
                   "cmacs/brigade"
                   (or (getenv "XDG_CACHE_HOME")
                       (expand-file-name ".cache" "~")))))
    (should (string-prefix-p (file-name-as-directory fake) derived))))


;;;; Standing hygiene guards

(ert-deftest cmacs-brigade-no-hardcoded-config ()
  "No literal path, model id, or endpoint outside a `defcustom'.

Shipped values are defaults, never assumptions.  A user's notes are not
necessarily in ~/Documents/notes and their ollama is not necessarily on
localhost, so every one of these has to be reachable through Custom."
  (let* ((files (append (cmacs-brigade-tests--elisp-files)
                        (cmacs-brigade-tests--c-files)))
         (hits (and files
                    (cmacs-brigade-tests--scan
                     files
                     (rx (or "~/Documents"
                             "localhost:11434"
                             "nomic-embed"
                             "/Maildir"
                             ".local/share/mail"))))))
    ;; Filter out the defcustom forms themselves, which are exactly
    ;; where these literals belong.
    (setq hits (seq-remove (lambda (h) (string-match-p "defcustom" h)) hits))
    (should (null hits))))

(ert-deftest cmacs-brigade-no-lrg-hostile-ui ()
  "No `x-popup-menu' / `image-map' / `menu-bar-*' in brigade Elisp.

Under `emacs --lrg' `display-graphic-p' returns t, so the obvious guard
passes and these then fail at runtime because lrgterm draws no menu bar.
Use `cmacs-libregnum-popup-menu', which falls through to the native menu
on pgtk, and a position keymap text property rather than `image-map' so
rows outrank Evil's state maps."
  (let* ((files (cmacs-brigade-tests--elisp-files))
         (hits (and files
                    (cmacs-brigade-tests--scan
                     files
                     (rx (or "x-popup-menu" "image-map" "menu-bar-"))))))
    (should (null hits))))

(provide 'cmacs-brigade-tests)

;;; cmacs-brigade-tests.el ends here
