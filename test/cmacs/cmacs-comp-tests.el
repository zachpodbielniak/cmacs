;;; cmacs-comp-tests.el --- native-comp loader regressions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Covers the cmacs patch to `load_comp_unit' in src/comp.c.
;;
;; A stale `.eln' -- one compiled by a binary with a different ABI hash
;; -- must be an ERROR every time it is loaded, never a crash.  It used
;; to be a crash the SECOND time: the loader published the unit into the
;; eln's own `comp_unit' slot before validating it, so the failing first
;; load left the file marked "already loaded" with its relocations
;; unset, and the next load skipped validation entirely and jumped
;; straight into `top_level_run'.
;;
;; That matters here more than most places because this tree rebuilds
;; constantly: adding a single DEFUN changes `comp-abi-hash' (it is
;; hashed over the whole subr list), so any Emacs left running across a
;; rebuild can be handed an eln from the wrong binary.  And cmacs
;; deliberately CATCHES that error in a few places -- MCP tool
;; registration warns and carries on -- which is exactly the pattern
;; that turned the second load into a segfault.
;;
;; The load has to happen in a subprocess: the bug being tested for kills
;; the process, and a dead test runner reports nothing at all.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defun cmacs-comp-tests--emacs ()
  "Path to the Emacs under test."
  (or (and invocation-directory
           (expand-file-name invocation-name invocation-directory))
      "emacs"))

(defun cmacs-comp-tests--some-eln ()
  "Return an .eln that is VALID for the running binary, or nil.

Specifically one under this runtime\'s own ABI directory.  The tree
accumulates a directory per ABI hash -- and this tree has dozens,
because adding one DEFUN changes the hash -- so \"any .eln under
native-lisp/\" is overwhelmingly likely to hand back a file from some
older binary, which is exactly the stale case rather than the valid
one.  (That mistake is how this helper was first written, and the
happy-path test duly failed with `native-lisp-file-inconsistent\'.)"
  (let ((dir (and (boundp 'comp-native-version-dir)
                  (expand-file-name
                   (concat "../native-lisp/" comp-native-version-dir)
                   invocation-directory))))
    (and dir (file-directory-p dir)
         (car (ignore-errors
                (directory-files dir t "\\.eln\\'"))))))

(defun cmacs-comp-tests--make-stale (src dst)
  "Copy SRC to DST with its embedded ABI hash corrupted.

Returns non-nil when the hash was found and changed.  The hash is
stored as a plain 8-character hex string, so flipping it is the
cheapest possible way to manufacture the situation a rebuild creates
for real."
  (let* ((hash (and (boundp 'comp-abi-hash) comp-abi-hash))
         (coding-system-for-read 'binary)
         (coding-system-for-write 'binary))
    (and (stringp hash)
         (= (length hash) 8)
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (insert-file-contents-literally src)
           (goto-char (point-min))
           (prog1 (when (search-forward hash nil t)
                    (replace-match (if (equal hash "deadbeef")
                                       "feedface" "deadbeef")
                                   t t)
                    t)
             (write-region (point-min) (point-max) dst nil 'silent))))))

(ert-deftest cmacs-comp-test-stale-eln-errors-twice-and-does-not-crash ()
  "Loading a stale .eln twice signals twice; it must never segfault.

The regression: the second load used to skip validation and crash, so
any code that caught the first error -- which cmacs does on purpose --
would take the process down on its next attempt."
  (skip-unless (and (fboundp 'native-comp-available-p)
                    (native-comp-available-p)
                    (boundp 'comp-abi-hash)))
  (let ((src (cmacs-comp-tests--some-eln)))
    (skip-unless src)
    (let* ((dir (make-temp-file "cmacs-comp-" t))
           (dst (expand-file-name "stale.eln" dir))
           (script (expand-file-name "load.el" dir)))
      (unwind-protect
          (progn
            (skip-unless (cmacs-comp-tests--make-stale src dst))
            (with-temp-file script
              (insert (format "%S"
                              `(dotimes (i 2)
                                 (message
                                  "attempt %d: %s" (1+ i)
                                  (condition-case e
                                      (progn (native-elisp-load ,dst) "loaded")
                                    (error (format "%S" (car e)))))))))
            (with-temp-buffer
              (let ((status (call-process (cmacs-comp-tests--emacs) nil t nil
                                          "--batch" "-Q" "-l" script)))
                ;; A signal comes back as a string ("Segmentation fault"),
                ;; an orderly exit as an integer.  That distinction IS the
                ;; test: the old loader died here with SIGSEGV.
                (should (integerp status))
                (should (= 0 status))
                ;; And both attempts must have refused the file, rather
                ;; than one refusing and the next quietly "succeeding".
                (goto-char (point-min))
                (should (= 2 (count-matches
                              "native-lisp-file-inconsistent"))))))
        (ignore-errors (delete-directory dir t))))))

(ert-deftest cmacs-comp-test-valid-eln-still-loads ()
  "The guard must not break loading a GOOD .eln.

The fix moves where the unit is published; if that were wrong, every
native-compiled file in the build would stop loading -- so assert the
happy path explicitly rather than trusting that something else would
have noticed."
  (skip-unless (and (fboundp 'native-comp-available-p)
                    (native-comp-available-p)))
  (let ((src (cmacs-comp-tests--some-eln)))
    (skip-unless src)
    ;; Loading an eln that is already loaded is the ordinary case (it is
    ;; how a `require' of an already-loaded feature behaves), and must
    ;; stay quiet.
    (should (native-elisp-load src))
    (should (native-elisp-load src))))

(provide 'cmacs-comp-tests)

;;; cmacs-comp-tests.el ends here
