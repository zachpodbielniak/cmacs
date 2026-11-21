;;; cmacs-describe-tools.el --- The describe tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The four read-only tools of cmacs/mcp/cmacs-mcp-tools-eval.c, written
;; once (doc_org/cmacs/cmacs-capability.org has the recipe):
;; `describe_function', `describe_variable', `apropos' and `completions'.
;; `eval' itself is the head of the privileged set and stays in C.
;;
;; Same wire names, same parameters, same `prin1'-printed result text.
;; One difference in how the answer is reached: the C handlers called
;; `intern' on the name they were given, so asking about a symbol that
;; did not exist created it.  These look the name up with `intern-soft'
;; and give the same "is not a known function" / "is void" answer.
;;
;; Redaction (cmacs-redact.el): `describe_variable' prints a variable's
;; value, which can be anything the session holds, so its answer goes
;; through the free-text rules.  And some variables are never printed:
;; the privacy rule set itself, and holders of secrets.  Which ones is
;; the registry's business (`cmacs-redact-variable-p'), not a list here;
;; for those the answer is one fixed sentence that does not say whether
;; the variable is even bound.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-text "cmacs-core-tools" (string))
(declare-function help-function-arglist "help"
                  (def &optional preserve-names))
(declare-function cmacs-redact-variable-p "cmacs-redact" (symbol))
(defvar cmacs-redact-variable-refusal)

(defconst cmacs-describe-tools-completions-limit 100
  "The most candidates `completions' returns, as in the C handler.")

(defun cmacs-describe-tools--name (text what)
  "Return TEXT, or signal that the WHAT argument is missing."
  (unless (and (stringp text) (not (string-empty-p text)))
    (error "Missing required argument: %s" what))
  text)

(cmacs-brigade-deftool describe-function
  "Describe an Emacs Lisp function: arglist, docstring, and source location."
    ((symbol string "Function symbol name"))
  :group 'elisp
  :example "emacsctl tool elisp describe-function --symbol car"
  (require 'cmacs-core-tools)
  (require 'help)
  (let* ((name (cmacs-describe-tools--name symbol "symbol"))
         (sym (intern-soft name)))
    (cmacs-core-tools-print
     (if (and sym (fboundp sym))
         (format "%s\n\nArgs: %s\n\n%s"
                 sym
                 (or (help-function-arglist sym t) "()")
                 (or (documentation sym t) "No documentation."))
       (format "%s is not a known function" name)))))

(cmacs-brigade-deftool describe-variable
  "Describe an Emacs Lisp variable: current value and docstring."
    ((symbol string "Variable symbol name"))
  :group 'elisp
  (require 'cmacs-core-tools)
  (require 'cmacs-redact)
  (let* ((name (cmacs-describe-tools--name symbol "symbol"))
         (sym (intern-soft name)))
    (cmacs-core-tools-print
     (cond
      ;; Asked by NAME, before anything is looked at: the answer for a
      ;; sensitive variable is the same bound, void or never interned.
      ((cmacs-redact-variable-p name) cmacs-redact-variable-refusal)
      ((and sym (boundp sym))
       (cmacs-core-tools-text
        (format "%s\n\nValue: %S\n\n%s"
                sym
                (symbol-value sym)
                (or (documentation-property
                     sym 'variable-documentation t)
                    "No documentation."))))
      (t (format "%s is void" name))))))

(cmacs-brigade-deftool apropos
  "Search for Emacs symbols matching a pattern. Returns one symbol per line."
    ((pattern string "Regexp pattern to match against symbol names"))
  :group 'elisp
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (mapconcat #'symbol-name
              (apropos-internal
               (cmacs-describe-tools--name pattern "pattern"))
              "\n")))

(cmacs-brigade-deftool completions
  "Get completion candidates for a symbol name prefix. Returns up to 100 matches."
    ((prefix string "Symbol name prefix to complete"))
  :group 'elisp
  (require 'cmacs-core-tools)
  (unless (stringp prefix)
    (error "Missing required argument: prefix"))
  (cmacs-core-tools-print
   (mapconcat #'identity
              (seq-take (all-completions prefix obarray)
                        cmacs-describe-tools-completions-limit)
              "\n")))

(provide 'cmacs-describe-tools)

;;; cmacs-describe-tools.el ends here
