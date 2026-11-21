;;; cmacs-calculator-tools.el --- The calculator as a registered capability  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The calculator's five tools, written once.
;;
;; These used to exist three times over: as handlers in
;; cmacs/mcp/cmacs-mcp-tools-calculator.c, as methods of
;; org.cmacs.Editor1.Calc in cmacs/dbus/cmacs-dbus-iface-calculator.c,
;; and as `calc' rows in cmacs/emacsctl/ctl-cmd-subsys.c -- each building
;; the same Lisp form with printf, and each carrying a comment asking the
;; next person to keep the other two in step.
;;
;; This file is the worked example of moving such a family onto the
;; capability table (doc_org/cmacs/cmacs-capability.org has the recipe).
;; One `cmacs-brigade-deftool' per tool now reaches in-process agents,
;; MCP clients, org.cmacs.Editor1.Tools and `emacsctl tool calc ...'.
;; The wire names are the old MCP names, so nothing that called
;; `calc_eval' has to change.
;;
;; Of the three copies, the MCP one is gone: the C file is deleted, and
;; what it published is frozen in test/cmacs/data/mcp-wire-schema.json,
;; which test/cmacs/cmacs-capability-tests.el holds these tools to.  The
;; D-Bus interface remains as a public name.
;;
;; Two things differ from the C handlers, both on purpose:
;;
;;   - No argument is ever spliced into Lisp source, so there is nothing
;;     to escape and nothing to whitelist for safety.  Calculator and
;;     category names are still checked, because "no such calculator" is
;;     a better answer than a symbol interned from arbitrary text.
;;
;;   - A failure is a failure.  The C handlers caught the calculator's
;;     error and returned it as an ordinary result beginning "error:",
;;     which an MCP client could not tell from success.  Here the error
;;     propagates, and each surface reports it in its own way: isError
;;     over MCP, a D-Bus error, a non-zero exit from emacsctl.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-calculator-eval "cmacs-calculator"
                  (expr &optional modes))
(declare-function cmacs-calculator-eval-symbolic "cmacs-calculator"
                  (expr &optional modes))
(declare-function cmacs-calculator-to-base-units "cmacs-calculator"
                  (expr &optional modes))
(declare-function cmacs-calculator-convert-units "cmacs-calculator"
                  (expr units &optional modes))
(declare-function cmacs-calculator-get "cmacs-calculator" (name))
(declare-function cmacs-calculator-list "cmacs-calculator"
                  (&optional category))

(defun cmacs-calculator-tools--name (text what)
  "Return TEXT as a symbol if it is a well-formed WHAT name, else signal.
The calculator registry is keyed by symbols; this keeps arbitrary text
from being interned on the way to finding out it names nothing."
  (unless (and (stringp text)
               (string-match-p "\\`[a-z][a-z0-9-]*\\'" text))
    (error "%s must be a %s name ([a-z][a-z0-9-]*)"
           (if (stringp text) (format "`%s'" text) "It") what))
  (intern text))

(defun cmacs-calculator-tools--expression (expression)
  "Return EXPRESSION, or signal when it is empty."
  (when (or (null expression) (string-blank-p expression))
    (error "Missing expression"))
  expression)

;; The engine is loaded when a tool runs, not when this file is: this
;; file is loaded at startup so the tools are listed, and GNU Calc is not
;; something to pull in for a session that never calculates.

(cmacs-brigade-deftool calc-eval
  "Evaluate a calculator EXPRESSION numerically and return the result.  \
Uses desktop-calculator semantics: '/' and '*' associate left to right \
\(so 2/3*4 is 2.667), angles are radians, and symbolic constants fold \
\(e^(i*pi) is -1).  Arbitrary precision.  All registered calculators are \
callable as functions, e.g. 'bscall(100,100,0.05,0.2,1)' or \
'lorentz(0.9)'.  Bad input is reported as an error rather than echoed \
back unevaluated."
    ((expression string "Expression, e.g. sqrt(5/3*3^4)"))
  :group 'calc
  :example "emacsctl tool calc eval --expression 'sqrt(5/3*3^4)'"
  (require 'cmacs-calculator)
  (cmacs-calculator-eval (cmacs-calculator-tools--expression expression)))

(cmacs-brigade-deftool calc-eval-symbolic
  "Evaluate a calculator EXPRESSION symbolically, permitting free \
variables.  This is the computer-algebra path: deriv(x^3,x), \
integ(x^2,x), solve(x^2-4=0,x), taylor(sin(x),x,5), factor, expand.  \
Use calc_eval instead when a number is wanted."
    ((expression string "Expression, e.g. deriv(x^3 + sin(x), x)"))
  :group 'calc
  :example "emacsctl tool calc eval-symbolic --expression 'deriv(x^3, x)'"
  (require 'cmacs-calculator)
  (cmacs-calculator-eval-symbolic
   (cmacs-calculator-tools--expression expression)))

(cmacs-brigade-deftool calc-convert-units
  "Evaluate EXPRESSION and convert it to UNITS; with no UNITS, reduce it \
to base SI.  Knows CODATA physical constants (c, G, h, hbar, k, Nav, me, \
mp), so '2 * G * 1.989e30 kg / c^2' reduces to the Schwarzschild radius \
of the Sun in metres, and '60 mph' converts to 'm/s'."
    ((expression string "Expression with units, e.g. 60 mph")
     (units string "Target units, e.g. m/s; omit to reduce to base SI"
            :optional t))
  :group 'calc
  :example "emacsctl tool calc convert-units --expression '60 mph' --units m/s"
  (require 'cmacs-calculator)
  (let ((expression (cmacs-calculator-tools--expression expression)))
    (if (or (null units) (string-blank-p units))
        (cmacs-calculator-to-base-units expression)
      (cmacs-calculator-convert-units expression units))))

(cmacs-brigade-deftool calc-list
  "List the registered calculators, optionally only those in one \
CATEGORY (financial, physics, relativity, tax, ...).  Each is callable \
as a function from calc_eval."
    ((category string "Category to filter by" :optional t))
  :group 'calc
  :example "emacsctl tool calc list --category physics"
  (require 'cmacs-calculator)
  (mapconcat
   (lambda (c)
     (format "%s (%s) -- %s"
             (plist-get c :name) (plist-get c :category)
             (or (plist-get c :title) "")))
   (cmacs-calculator-list
    (and category (not (string-blank-p category))
         (cmacs-calculator-tools--name category "category")))
   "\n"))

(cmacs-brigade-deftool calc-describe
  "Describe one calculator by NAME: its title, category, arguments, \
return value and documentation."
    ((name string "Calculator name, e.g. bscall"))
  :group 'calc
  :example "emacsctl tool calc describe --name bscall"
  (require 'cmacs-calculator)
  (let ((c (cmacs-calculator-get
            (cmacs-calculator-tools--name name "calculator"))))
    (unless c
      (error "No such calculator: %s" name))
    (format "%s -- %s\ncategory: %s\nargs: %S\nreturns: %s\n%s"
            (plist-get c :name) (or (plist-get c :title) "")
            (plist-get c :category) (plist-get c :args)
            (or (plist-get c :returns) "") (or (plist-get c :doc) ""))))

(provide 'cmacs-calculator-tools)

;;; cmacs-calculator-tools.el ends here
