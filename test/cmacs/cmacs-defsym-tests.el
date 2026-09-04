;;; cmacs-defsym-tests.el --- DEFSYM name collisions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; One test, guarding one whole class of failure.
;;
;; `DEFSYM (Qfoo, "foo")' does not look "foo" up -- it CREATES a symbol
;; and interns it.  DEFSYM'ing a name that some other compiled file
;; already DEFSYM'd therefore puts two distinct symbols with the same
;; name into the obarray, and from then on `EQ' against one of them
;; fails for every value Lisp produced through the other.
;;
;; Nothing warns.  The build is clean, the tests pass, and the damage is
;; wherever the shadowed symbol was load-bearing.  Doing it to "image"
;; broke every `(image ...)' display spec in xdisp.c: images stopped
;; rendering and their raw data leaked into the buffer as text -- which
;; is how it was eventually noticed, on a Doom dashboard.
;;
;; `src/globals.h' is generated from exactly the files this build
;; compiles, so its `defsym_name[]' table is the authoritative list.
;; Platform-specific upstream duplicates (xterm.c vs pgtkterm.c vs
;; w32*.c) never appear together there, which is why this can be a flat
;; "no duplicates at all" assertion rather than a curated allowlist.

;;; Code:

(require 'ert)
(require 'cmacs nil 'noerror)

(defun cmacs-defsym-tests--globals-h ()
  "Locate the built `src/globals.h', or nil.

Searched relative to this file and to `source-directory', so it works
from the test directory, the build tree root, and an in-tree run."
  (let ((roots (list (and load-file-name
                          (expand-file-name
                           "../.." (file-name-directory load-file-name)))
                     source-directory
                     default-directory)))
    (cl-loop for r in roots
             for f = (and r (expand-file-name "src/globals.h" r))
             when (and f (file-readable-p f)) return f)))

(defun cmacs-defsym-tests--names (file)
  "Return every symbol name in FILE's `defsym_name[]' table."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward "^static char const \\*const defsym_name\\[\\] = {"
                             nil t)
      (let ((end (save-excursion
                   (or (re-search-forward "^};" nil t) (point-max))))
            (names nil))
        (while (re-search-forward "\"\\([^\"]*\\)\"" end t)
          (push (match-string 1) names))
        (nreverse names)))))

(ert-deftest cmacs-defsym-test-no-duplicate-symbol-names ()
  "No two DEFSYMs in this build define the same symbol name.

A duplicate is never benign: it silently breaks `EQ' for whichever of
the two symbols the offending C file compares against."
  (let ((file (cmacs-defsym-tests--globals-h)))
    (skip-unless file)
    (let* ((names (cmacs-defsym-tests--names file))
           (seen (make-hash-table :test 'equal))
           (dups nil))
      (should names)
      (dolist (n names)
        (if (gethash n seen) (push n dups) (puthash n t seen)))
      (should (equal nil (delete-dups (nreverse dups)))))))

(ert-deftest cmacs-defsym-test-image-symbol-is-the-real-one ()
  "The `image' symbol Lisp interns is the one the display code uses.

`imagep' is the sharpest available probe for this: it is C, and it is
literally `CONSP (x) && EQ (XCAR (x), Qimage)' (see `IMAGEP' in
lisp.h).  So it returns nil for a list Lisp built with its own `image'
symbol exactly when a duplicate DEFSYM has split the two apart -- which
is the concrete regression this file exists for, and which presented as
images not rendering and their raw PBM data appearing as text."
  (should (eq (intern "image") 'image))
  (should (imagep '(image :type pbm :data "P1\n1 1\n0\n"))))

(provide 'cmacs-defsym-tests)

;;; cmacs-defsym-tests.el ends here
