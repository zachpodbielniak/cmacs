;;; cmacs-dbexplorer-tests.el --- Tests for the database explorer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the cmacs-dbexplorer subsystem.

;;; Code:

(require 'ert)

;; `fboundp' and `boundp', not `cmacs-feature-p': the latter lives in
;; lisp/cmacs/cmacs.el, which is not loaded when a test file is run on its
;; own.  Calling it there is a void-function error that ERT turns into a
;; skip, so every `skip-unless' in the file passes vacuously and the suite
;; reports green having executed nothing.
;;
;; Checking a concrete DEFUN as well as the flag matters: the flag says
;; the subsystem was compiled in, the DEFUN says its symbols actually
;; loaded.
(defun cmacs-dbexplorer-tests--available-p ()
  "Non-nil when this build compiled in the database explorer."
  (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer
       (fboundp 'cmacs-dbexplorer-supported-p)))

(ert-deftest cmacs-dbexplorer-feature-flag ()
  "The feature flag is always bound, and agrees with the primitives."
  ;; Bound in every build, including one without the subsystem -- that is
  ;; what lets a user config say (when IS-CMACS-DBEXPLORER ...) without a
  ;; void-variable error.
  (should (boundp 'is-cmacs-dbexplorer))
  (should (eq (and (boundp 'IS-CMACS-DBEXPLORER) IS-CMACS-DBEXPLORER)
              (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer)))
  (when (and (boundp 'is-cmacs-dbexplorer) is-cmacs-dbexplorer)
    (should (fboundp 'cmacs-dbexplorer-supported-p))))

(ert-deftest cmacs-dbexplorer-supported-p ()
  "The runtime predicate reports the subsystem as usable."
  (skip-unless (cmacs-dbexplorer-tests--available-p))
  (should (cmacs-dbexplorer-supported-p)))

(ert-deftest cmacs-dbexplorer-in-compiled-features ()
  "The subsystem appears in the compiled-feature list."
  (skip-unless (cmacs-dbexplorer-tests--available-p))
  (skip-unless (fboundp 'cmacs-compiled-features))
  (should (memq 'dbexplorer (cmacs-compiled-features))))

(provide 'cmacs-dbexplorer-tests)
;;; cmacs-dbexplorer-tests.el ends here
