;;; cmacs-speech-doc-tests.el --- the speech manuals cover the speech code  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; doc_org/ and doc/cmacs/cmacs.texi are maintained in parallel, and the
;; speech layer has many small entry points: every sherpa DEFUN, every
;; speech command, minor mode and transient, and every speech
;; defcustom must be mentioned in both, so neither manual falls behind
;; the code.  The symbols are read from the sources, not listed here, so
;; a new one fails this test until it is documented.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst cmacs-speech-doc-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "The top of the source tree.")

(defun cmacs-speech-doc-tests--file (rel)
  "Contents of REL under the source tree, or nil."
  (let ((f (expand-file-name rel cmacs-speech-doc-tests--root)))
    (and (file-readable-p f)
         (with-temp-buffer (insert-file-contents f) (buffer-string)))))

(defun cmacs-speech-doc-tests--files (glob)
  "Concatenated contents of the files matching GLOB under the tree."
  (mapconcat (lambda (f) (with-temp-buffer (insert-file-contents f) (buffer-string)))
             (file-expand-wildcards (expand-file-name glob cmacs-speech-doc-tests--root))
             "\n"))

(defun cmacs-speech-doc-tests--lisp-symbols ()
  "User-facing symbols of lisp/cmacs/cmacs-speech*.el: commands, minor
modes, transients and defcustoms, without internal (--) names."
  (let (out)
    (dolist (f (file-expand-wildcards
                (expand-file-name "lisp/cmacs/cmacs-speech*.el"
                                  cmacs-speech-doc-tests--root)))
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (condition-case nil
            (while t
              (let ((form (read (current-buffer))))
                (when (and (consp form) (symbolp (nth 1 form))
                           (not (string-match-p "--" (symbol-name (nth 1 form)))))
                  (when (or (memq (car form) '(defcustom define-minor-mode
                                                transient-define-prefix))
                            (and (memq (car form) '(defun cl-defun))
                                 (cl-some (lambda (x) (eq (car-safe x) 'interactive))
                                          (nthcdr 3 form))))
                    (push (nth 1 form) out)))))
          (end-of-file nil))))
    (delete-dups out)))

(defun cmacs-speech-doc-tests--defuns ()
  "The Lisp names of every DEFUN in cmacs/sherpa/."
  (let ((text (cmacs-speech-doc-tests--files "cmacs/sherpa/*.c"))
        (pos 0) out)
    (while (string-match "DEFUN (\"\\([^\"]+\\)\"" text pos)
      (push (intern (match-string 1 text)) out)
      (setq pos (match-end 0)))
    out))

(defun cmacs-speech-doc-tests--missing (symbols text)
  "SYMBOLS whose name does not occur as a whole word in TEXT.
TEXT is indexed once (every run of name characters), so a large manual
costs one pass rather than one regexp search per symbol."
  (let ((words (make-hash-table :test 'equal :size 65536))
        (pos 0))
    (while (string-match "[a-z0-9-]+" text pos)
      (puthash (match-string 0 text) t words)
      (setq pos (match-end 0)))
    (cl-remove-if (lambda (s) (gethash (symbol-name s) words)) symbols)))

(ert-deftest cmacs-speech-doc-test-both-manuals ()
  "Every public speech symbol is in doc_org/ and in cmacs.texi."
  (let ((org (mapconcat (lambda (f) (with-temp-buffer (insert-file-contents f) (buffer-string)))
                        (directory-files-recursively
                         (expand-file-name "doc_org/cmacs" cmacs-speech-doc-tests--root)
                         "\\.org\\'")
                        "\n"))
        (texi (cmacs-speech-doc-tests--file "doc/cmacs/cmacs.texi"))
        (syms (append (cmacs-speech-doc-tests--defuns)
                      (cmacs-speech-doc-tests--lisp-symbols))))
    (unless (and texi (> (length org) 0))
      (ert-skip "manual sources not in this tree"))
    (should (> (length syms) 40))
    (should (equal (cmacs-speech-doc-tests--missing syms org) nil))
    (should (equal (cmacs-speech-doc-tests--missing syms texi) nil))))

(ert-deftest cmacs-speech-doc-test-chapters ()
  "Both manuals have the speech and sherpa chapters, cross-linked."
  (let ((texi (cmacs-speech-doc-tests--file "doc/cmacs/cmacs.texi")))
    (unless texi (ert-skip "no texi"))
    (dolist (node '("CMacs Speech" "CMacs Sherpa"))
      (should (string-match-p (concat "^@node " node "$") texi))
      (should (string-match-p (concat "^\\* " node "::") texi)))
    (should (cmacs-speech-doc-tests--file "doc_org/cmacs/cmacs-speech.org"))
    (should (cmacs-speech-doc-tests--file "doc_org/cmacs/cmacs-sherpa.org"))))

(provide 'cmacs-speech-doc-tests)
;;; cmacs-speech-doc-tests.el ends here
