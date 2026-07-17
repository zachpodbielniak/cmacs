;;; cmacs-calculator.el --- Calculator engine (GNU Calc wrapper) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The evaluation core of `cmacs-calculator'.  Everything else in the
;; subsystem -- the financial/physics/relativity families, the sheet buffer,
;; inline evaluation, the landing page, the REPL, the D-Bus/MCP surface --
;; goes through `cmacs-calculator-eval' here.
;;
;; The engine is GNU Calc (`lisp/calc/'), which Emacs already ships: an
;; arbitrary-precision CAS with symbolic algebra, a units table with CODATA
;; physical constants, matrices and complex numbers.  We wrap it additively
;; and never modify `lisp/calc/' -- cmacs tracks upstream Emacs, so upstream
;; files stay untouched.
;;
;; Why a wrapper is needed at all
;; ------------------------------
;; Calc's defaults are tuned for the interactive RPN Calculator, not for a
;; desktop calculator, and piping a string straight to `calc-eval' gives
;; WRONG ANSWERS.  Five specific traps, each corrected below:
;;
;;   1. Multiplication binds tighter than division, so "2/3*4" means
;;      2/(3*4) = 0.1667, and "sqrt(5/3*3^4)" = 0.1434 rather than the
;;      11.6189... every pocket calculator prints.  Corrected with
;;      `calc-multiplication-has-precedence' = nil.
;;
;;   2. The angle mode defaults to degrees, so "sin(90)" = 1.  Corrected
;;      with `calc-angle-mode' = `rad' (see `cmacs-calculator-angle-mode').
;;
;;   3. `calc-eval' re-binds the mode variables itself, so an enclosing
;;      `let' over `calc-angle-mode' is silently ignored.  Modes must be
;;      passed through `calc-eval's documented list form,
;;      (calc-eval (list EXPR 'calc-angle-mode 'rad ...)) -- which is what
;;      `cmacs-calculator--modes' builds.  Org does the same thing with
;;      `org-calc-default-modes'.
;;
;;   4. Symbolic constants do not fold: "sin(pi/2)" stays `sin(pi / 2)'.
;;      Wrapping the expression in Calc's `evalv()' forces evaluation, so
;;      "e^(i*pi)" correctly gives -1.  `evalv' is safe for symbolic work
;;      too: evalv(deriv(x^3,x)) is still 3 x^2.
;;
;;   5. Calc reports bad input by returning it UNEVALUATED rather than
;;      signalling: "1/0" => "1/0", "foo(1)" => "foo(1)", "ln(0)" =>
;;      "ln(0)", and "((1+2)" is silently accepted as 3.  For a calculator
;;      that is a footgun, so `calc-infinite-mode' turns division by zero
;;      into uinf/nan/-inf and `cmacs-calculator--validate' rejects
;;      unbalanced parens, unknown functions and unbound variables before
;;      the caller ever sees a result.
;;
;; Note that `calc-eval' signals nothing on error either: it returns a
;; (POSITION MESSAGE) list.  `cmacs-calculator-eval' normalises that into a
;; real `cmacs-calculator-error' signal.

;;; Code:

(require 'calc)
(require 'calc-ext)
(require 'calc-units)
(require 'seq)

(eval-when-compile (require 'cl-lib))

(declare-function math-read-expr "calc-aent" (str))
(declare-function math-format-value "calc-ext" (a &optional prec))
(declare-function math-check-unit-name "calc-units" (v))
(declare-function math-build-units-table "calc-units" ())
(declare-function math-to-standard-units "calc-units" (expr which-standard))
(declare-function math-simplify-units "calc-units" (a))


;;; Errors

(define-error 'cmacs-calculator-error "CMacs calculator error")

(define-error 'cmacs-calculator-syntax-error
              "Syntax error" 'cmacs-calculator-error)

(define-error 'cmacs-calculator-unknown-function
              "Unknown function" 'cmacs-calculator-error)

(define-error 'cmacs-calculator-unbound-variable
              "Unbound variable" 'cmacs-calculator-error)


;;; Customization

(defgroup cmacs-calculator nil
  "Calculator for CMacs: desktop, financial, physics, relativity and CAS."
  :group 'cmacs
  :prefix "cmacs-calculator-")

(defcustom cmacs-calculator-precision 12
  "Number of significant digits Calc computes with.
Calc is arbitrary-precision; raising this costs time, not accuracy.
Twelve matches Calc's own default and Org's `org-calc-default-modes'."
  :type 'integer
  :group 'cmacs-calculator)

(defcustom cmacs-calculator-angle-mode 'rad
  "Angle unit for trigonometric functions.
Calc itself defaults to `deg', which surprises anyone doing physics or
calculus: with `deg', d/dx sin(x) picks up a pi/180 factor.  CMacs
defaults to `rad' instead."
  :type '(choice (const :tag "Radians" rad)
                 (const :tag "Degrees" deg)
                 (const :tag "Hours-minutes-seconds" hms))
  :group 'cmacs-calculator)

(defcustom cmacs-calculator-infinite-mode t
  "When non-nil, division by zero yields an infinity instead of an error.
With this enabled 1/0 is `uinf', 0/0 is `nan' and ln(0) is `-inf'.
When nil those expressions signal a `cmacs-calculator-error'."
  :type 'boolean
  :group 'cmacs-calculator)

(defcustom cmacs-calculator-multiplication-has-precedence nil
  "When non-nil, `*' binds tighter than `/', as in stock GNU Calc.
Calc's default (t) makes \"2/3*4\" mean 2/(3*4) = 0.1667.  Every
pocket calculator, spreadsheet and programming language instead gives
(2/3)*4 = 2.667, which is what nil produces.  Leave this nil unless you
specifically want Calc's traditional reading."
  :type 'boolean
  :group 'cmacs-calculator)

(defcustom cmacs-calculator-strict t
  "When non-nil, reject input Calc would silently accept.
Calc answers \"((1+2)\" with 3 and \"foo(1)\" with `foo(1)'.  With this
enabled, unbalanced delimiters, unknown functions and unbound variables
signal a `cmacs-calculator-error' instead."
  :type 'boolean
  :group 'cmacs-calculator)


;;; Mode context

(defconst cmacs-calculator--fixed-modes
  '(calc-symbolic-mode nil
    calc-prefer-frac nil
    calc-number-radix 10
    calc-group-digits nil
    calc-point-char "."
    calc-language nil
    ;; `calc-eval' turns progress reporting ON (`lots'), which is right for
    ;; the interactive Calculator and wrong everywhere we are used: an
    ;; iterative function such as nroot or solve would spray "Working...
    ;; root = 10" through the --calc REPL and into every D-Bus and MCP reply.
    calc-display-working-message nil)
  "Calc modes pinned regardless of user customization.
`calc-language' must stay nil: the `c' language would fix the division
precedence (trap 1) but redefines `^' as bitwise XOR, so \"2^10\" would
stop meaning 1024.")

(defun cmacs-calculator--modes (&optional overrides)
  "Return the Calc mode plist for `calc-eval', with OVERRIDES applied.
OVERRIDES is a flat list of VARIABLE VALUE pairs taking precedence over
the customized defaults.  The result is spliced after the expression
string to form `calc-eval's list argument -- the only mechanism Calc
honours, since `calc-eval' rebinds these variables internally and so
ignores any surrounding `let'.

OVERRIDES must come LAST.  `calc-do-calc-eval' walks the list front to
back doing a plain `set' on each pair, so a later pair overwrites an
earlier one -- put the defaults after the overrides and the defaults
quietly win, which is the opposite of what the caller asked for."
  (append (list 'calc-internal-prec cmacs-calculator-precision
                'calc-angle-mode cmacs-calculator-angle-mode
                'calc-infinite-mode cmacs-calculator-infinite-mode
                'calc-multiplication-has-precedence
                cmacs-calculator-multiplication-has-precedence)
          cmacs-calculator--fixed-modes
          overrides))


;;; Validation
;;
;; Calc is permissive by design: unparsable tails are ignored and unknown
;; names stay symbolic.  That is right for an algebra system and wrong for a
;; calculator, so we check the input ourselves before trusting a result.

(defconst cmacs-calculator--constants
  '(pi e i phi gamma inf uinf nan)
  "Calc variable names that are constants rather than free variables.")

(defun cmacs-calculator--ensure-units-table ()
  "Build Calc's units table if it is not built yet, without announcing it.
`math-build-units-table' says \"Building units table...\" -- which is
fine in the interactive Calculator and noise everywhere we are used: it
would land in the middle of the `--calc' REPL and in D-Bus and MCP
replies.  Calc caches the table, so the message appears only on the
first unit expression of a session, which makes it exactly the sort of
thing that never shows up in testing."
  (let ((inhibit-message t))
    (math-build-units-table)))

(defun cmacs-calculator--balanced-p (str)
  "Return non-nil if parentheses and brackets in STR are balanced.
Calc's parser stops at the first complete expression and ignores the
rest, so it reads \"((1+2)\" as 3 rather than reporting the missing
paren.  Quoted strings are skipped."
  (let ((depth 0) (i 0) (n (length str)) (in-string nil) (ok t))
    (while (and ok (< i n))
      (let ((c (aref str i)))
        (cond
         (in-string
          (cond ((eq c ?\\) (setq i (1+ i)))
                ((eq c ?\") (setq in-string nil))))
         ((eq c ?\") (setq in-string t))
         ((memq c '(?\( ?\[)) (setq depth (1+ depth)))
         ((memq c '(?\) ?\]))
          (setq depth (1- depth))
          (when (< depth 0) (setq ok nil)))))
      (setq i (1+ i)))
    (and ok (zerop depth) (not in-string))))

(defun cmacs-calculator--known-var-p (name)
  "Return non-nil if NAME is a constant, a unit, or a stored Calc variable.
NAME is the bare symbol from a Calc (var NAME var-NAME) form.  Units are
resolved through Calc's own table, so prefixed units such as `km' and
constants such as `c' are recognized."
  (or (memq name cmacs-calculator--constants)
      (boundp (intern (concat "var-" (symbol-name name))))
      (progn
        (cmacs-calculator--ensure-units-table)
        (ignore-errors
          (math-check-unit-name
           (list 'var name (intern (concat "var-" (symbol-name name)))))))))

(defun cmacs-calculator--walk (form fn)
  "Call FN on FORM and every sub-form of the Calc expression FORM."
  (funcall fn form)
  (when (consp form)
    (dolist (sub (cdr form))
      (cmacs-calculator--walk sub fn))))

(defun cmacs-calculator--validate (form &optional allow-vars)
  "Signal an error if the parsed Calc FORM is not safe to evaluate.
Rejects calls to functions Calc does not define -- Calc would leave
`foo(1)' symbolic and the caller could not tell it apart from a real
result.  Unless ALLOW-VARS is non-nil (symbolic/CAS evaluation, where
free variables are the whole point), unbound variables are rejected too.
Does nothing when `cmacs-calculator-strict' is nil."
  (when cmacs-calculator-strict
    (cmacs-calculator--walk
     form
     (lambda (f)
       (cond
        ((and (consp f) (symbolp (car f))
              (string-prefix-p "calcFunc-" (symbol-name (car f)))
              (not (fboundp (car f)))
              ;; Before calling it unknown, load the families -- a bare
              ;; instance may hold only the engine, and every calculator
              ;; (bscall, lorentz, ...) arrives with them.  This runs at most
              ;; once per session and only on the path that was about to
              ;; error, so plain arithmetic never pays for it.
              (progn (cmacs-calculator-load-families)
                     (not (fboundp (car f)))))
         (signal 'cmacs-calculator-unknown-function
                 (list (substring (symbol-name (car f)) 9))))
        ((and (not allow-vars)
              (eq (car-safe f) 'var)
              (not (cmacs-calculator--known-var-p (nth 1 f))))
         (signal 'cmacs-calculator-unbound-variable
                 (list (symbol-name (nth 1 f))))))))))

(defun cmacs-calculator--parse (expr)
  "Parse EXPR, a string, into a Calc internal form.
Signals `cmacs-calculator-syntax-error' rather than returning Calc's
in-band (POSITION MESSAGE) error list."
  (unless (and (stringp expr) (not (string-blank-p expr)))
    (signal 'cmacs-calculator-syntax-error (list "empty expression")))
  (when (and cmacs-calculator-strict
             (not (cmacs-calculator--balanced-p expr)))
    (signal 'cmacs-calculator-syntax-error
            (list "unbalanced parentheses or brackets" expr)))
  (let ((form (math-read-expr expr)))
    (when (eq (car-safe form) 'error)
      (signal 'cmacs-calculator-syntax-error
              (list (or (nth 2 form) "cannot parse") expr)))
    form))


;;; Evaluation

(defun cmacs-calculator--calc-eval (expr modes)
  "Run EXPR through `calc-eval' with MODES, normalizing Calc's error form.
`calc-eval' reports failure by returning a (POSITION MESSAGE) list
instead of signalling, which is easy to mistake for a result.

MODES is applied without leaking.  `calc-do-calc-eval' implements the
mode list with a plain `set' per pair, relying on an enclosing `let' to
undo it -- but that `let' names only the modes Calc knew about, and
`calc-multiplication-has-precedence' is not among them.  Left alone, one
call would flip it globally and permanently, so a user's later
\\[calc] would silently inherit our corrected precedence.  cmacs must not
reach out and change how stock Calc behaves, so every variable the mode
list names is saved and restored here."
  (let ((vars nil)
        (saved nil)
        (tail modes))
    (while tail
      (push (car tail) vars)
      (push (and (boundp (car tail)) (symbol-value (car tail))) saved)
      (setq tail (cddr tail)))
    (unwind-protect
        (let ((res (calc-eval (cons expr modes))))
          (if (and (consp res) (integerp (car res)))
              (signal 'cmacs-calculator-error (list (cadr res) expr))
            res))
      ;; VARS and SAVED were pushed together, so they stay aligned; walking
      ;; them in push order is fine since each variable appears once.
      (while vars
        (set (car vars) (car saved))
        (setq vars (cdr vars)
              saved (cdr saved))))))

(defun cmacs-calculator-eval (expr &optional modes)
  "Evaluate EXPR, a string, numerically and return the result as a string.
MODES is an optional flat list of Calc VARIABLE VALUE overrides.

The expression is evaluated with the corrected desktop-calculator
semantics described in the Commentary: `/' and `*' associate left to
right, angles are radians by default, and symbolic constants fold, so

  (cmacs-calculator-eval \"sqrt(5/3*3^4)\") => \"11.6189500386\"
  (cmacs-calculator-eval \"evalv(e^(i*pi))\") => \"-1.\"

Signals `cmacs-calculator-error' (or a subtype) on bad input rather
than returning it unevaluated the way Calc does."
  (let* ((form (cmacs-calculator--parse expr))
         (res (progn
                (cmacs-calculator--validate form)
                (cmacs-calculator--calc-eval
                 (format "evalv(%s)" expr)
                 (cmacs-calculator--modes modes)))))
    (cmacs-calculator--check-evaluated res expr)
    res))

(defun cmacs-calculator--check-evaluated (res expr)
  "Signal unless RES, the result of evaluating EXPR, is fully evaluated.

Calc reports a domain error by returning the call UNEVALUATED: with the
argument out of range, `lorentz(1.5)' comes back as the string
\"lorentz(1.5)\", exactly as stock Calc's own `pmt(0,5,100)' does.
`cmacs-calculator--validate' cannot catch that -- it inspects the input,
where the function is perfectly well-formed and defined -- so numeric
evaluation checks the output too.  Without this the caller cannot tell a
rejected argument from a result.

Symbolic evaluation deliberately skips this: an unevaluated form is the
whole point there."
  (when cmacs-calculator-strict
    (let ((parsed (ignore-errors (math-read-expr res))))
      (when (and parsed (not (eq (car-safe parsed) 'error)))
        (cmacs-calculator--walk
         parsed
         (lambda (f)
           (when (and (consp f) (symbolp (car f))
                      (string-prefix-p "calcFunc-" (symbol-name (car f))))
             (signal 'cmacs-calculator-error
                     (list (format "%s did not evaluate: argument out of range\
 or unsupported"
                                   (substring (symbol-name (car f)) 9))
                           expr)))))))))

(defun cmacs-calculator-eval-symbolic (expr &optional modes)
  "Evaluate EXPR, a string, symbolically and return the result as a string.
Unlike `cmacs-calculator-eval', free variables are permitted and the
result is not forced to a number, so algebra survives:

  (cmacs-calculator-eval-symbolic \"deriv(x^3 + sin(x), x)\")
  (cmacs-calculator-eval-symbolic \"solve(x^2 - 4 = 0, x)\")

MODES is as in `cmacs-calculator-eval'."
  (let ((form (cmacs-calculator--parse expr)))
    (cmacs-calculator--validate form 'allow-vars)
    (cmacs-calculator--calc-eval expr (cmacs-calculator--modes modes))))

(defconst cmacs-calculator--number-re
  "\\`[-+]?\\(?:[0-9]+\\.?[0-9]*\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?\\'"
  "Regexp matching a Calc result that is a plain real number.
Deliberately strict: Calc also prints `uinf', `nan', `(0, 2)' for a
complex value and `sin(x)' for an unevaluated form, none of which are
numbers, and a loose pattern would silently turn them into 0.")

(defun cmacs-calculator--as-number (res)
  "Return RES, a Calc result string, as an Emacs float, or nil.
Nil means RES is not a plain real number -- infinite, complex, symbolic
or an error.  Always a float, never an integer: callers do float-only
arithmetic on the result (`isnan' among others), and \"-1\" would
otherwise come back as an integer and break them."
  (and (stringp res)
       (string-match-p cmacs-calculator--number-re res)
       (float (string-to-number res))))

(defun cmacs-calculator-eval-number (expr &optional modes)
  "Evaluate EXPR and return an Emacs float, or nil if it is not numeric.
Convenience for callers that need to compute with the result rather
than display it.  Nil is returned for infinite, complex or symbolic
results as well as non-numbers.  MODES is as in `cmacs-calculator-eval'."
  (cmacs-calculator--as-number (cmacs-calculator-eval expr modes)))

(defun cmacs-calculator-eval-symbolic-number (expr &optional modes)
  "Evaluate EXPR permitting free variables; return an Emacs float or nil.
For callers that substitute variables themselves and then want a number
back -- notably plotting, where \"subst(sin(x), x, 1.5)\" is numeric
even though the expression mentions `x' and so would be rejected by
`cmacs-calculator-eval's strict check.  MODES is as in
`cmacs-calculator-eval'."
  (cmacs-calculator--as-number (cmacs-calculator-eval-symbolic expr modes)))


;;; Units
;;
;; Calc exposes only `usimplify' as an algebraic function; converting to base
;; SI units or to a named unit is implemented solely as interactive stack
;; commands (`calc-base-units', `calc-convert-units').  These wrap the
;; underlying machinery so both are callable from Lisp.

(defmacro cmacs-calculator--with-modes (modes &rest body)
  "Evaluate BODY with the Calc mode variables in MODES bound.
MODES is a flat VARIABLE VALUE list as built by `cmacs-calculator--modes'.
Needed for the direct `math-*' entry points, which -- unlike `calc-eval'
-- honour ordinary dynamic bindings."
  (declare (indent 1) (debug (form body)))
  (let ((ms (make-symbol "modes")))
    `(let* ((,ms ,modes)
            (calc-internal-prec (or (plist-get ,ms 'calc-internal-prec)
                                    cmacs-calculator-precision))
            (calc-angle-mode (or (plist-get ,ms 'calc-angle-mode)
                                 cmacs-calculator-angle-mode))
            (calc-infinite-mode (plist-get ,ms 'calc-infinite-mode))
            (calc-multiplication-has-precedence
             (plist-get ,ms 'calc-multiplication-has-precedence))
            (calc-symbolic-mode nil)
            (calc-prefer-frac nil)
            (calc-language nil))
       ,@body)))

(defun cmacs-calculator-to-base-units (expr &optional modes)
  "Evaluate EXPR and express the result in base SI units, as a string.
Constants from Calc's CODATA table expand, so

  (cmacs-calculator-to-base-units \"2 G * 1.989e30 kg / c^2\")

gives the Schwarzschild radius of the Sun in metres.  MODES is as in
`cmacs-calculator-eval'."
  (cmacs-calculator--with-modes (cmacs-calculator--modes modes)
    (let ((form (cmacs-calculator--parse expr)))
      (cmacs-calculator--validate form 'allow-vars)
      (cmacs-calculator--ensure-units-table)
      (math-format-value
       (math-simplify-units (math-to-standard-units form nil))
       1000))))

(defun cmacs-calculator-convert-units (expr units &optional modes)
  "Evaluate EXPR and convert the result to UNITS, returning a string.
UNITS is a unit expression such as \"km\" or \"m/s\".  MODES is as in
`cmacs-calculator-eval'."
  (cmacs-calculator--with-modes (cmacs-calculator--modes modes)
    (let ((form (cmacs-calculator--parse expr))
          (target (cmacs-calculator--parse units)))
      (cmacs-calculator--validate form 'allow-vars)
      (cmacs-calculator--ensure-units-table)
      (math-format-value
       (math-simplify-units
        (math-div (math-to-standard-units form nil)
                  (math-to-standard-units target nil)))
       1000))))


;;; Calculator registry
;;
;; One table behind the landing page, completion, ElDoc, the reference
;; documentation and the MCP tool schema, so none of them can drift from the
;; functions actually defined.

(defcustom cmacs-calculator-families
  '(cmacs-calculator-financial
    cmacs-calculator-physics
    cmacs-calculator-relativity
    ;; The data file, not `cmacs-calculator-tax': loading it pulls in the
    ;; math and additionally registers the jurisdiction tables, without
    ;; which the tax calculators have no rates to work from.
    cmacs-calculator-tax-data)
  "Calculator family features providing the registered calculators.
Each is soft-required: a family this build does not ship is skipped
rather than raising an error.  Loading a family is what registers its
calculators, so anything missing here is invisible everywhere."
  :type '(repeat symbol)
  :group 'cmacs-calculator)

(defvar cmacs-calculator--families-loaded nil
  "Non-nil once `cmacs-calculator-load-families' has run.")

(defun cmacs-calculator-load-families (&optional force)
  "Load every available feature in `cmacs-calculator-families'.
Returns the list actually loaded.  Soft-requires throughout: a family
this build lacks is not an error, it is just absent.  Does nothing after
the first call unless FORCE is non-nil.

This is what populates the registry, and it is deliberately lazy.  The
engine alone is enough for plain arithmetic -- `emacs --calc \"2+2\"'
should not pay to load bond maths and fifty tax tables -- so the
families load on first need instead: when the registry is read, or when
an expression names a function the engine has not seen.  Callers that
arrive without having required a family (the D-Bus and MCP surfaces
both do) therefore still find `bscall' and `lorentz'."
  (when (or force (not cmacs-calculator--families-loaded))
    (setq cmacs-calculator--families-loaded t)
    (let (loaded)
      (dolist (family cmacs-calculator-families)
        ;; Runtime, not load-time: each family requires this file back, so a
        ;; top-level require here would be circular.
        (when (require family nil t)
          (push family loaded)))
      (nreverse loaded))))

(defvar cmacs-calculator-registry (make-hash-table :test 'eq)
  "Map of calculator NAME symbol to its metadata plist.
See `cmacs-calculator-defcalc' for the plist keys.")

(defun cmacs-calculator-register (name plist)
  "Record calculator NAME with metadata PLIST in `cmacs-calculator-registry'."
  (puthash name (plist-put (copy-sequence plist) :name name)
           cmacs-calculator-registry))

(defun cmacs-calculator-get (name)
  "Return the metadata plist for calculator NAME, or nil.
Loads the calculator families first, so this answers the same on a bare
instance as in a session that happens to have used a sheet."
  (cmacs-calculator-load-families)
  (gethash name cmacs-calculator-registry))

(defun cmacs-calculator-list (&optional category)
  "Return calculator metadata plists, optionally only those in CATEGORY.
Sorted by name so callers render a stable order.  Loads the calculator
families first."
  (cmacs-calculator-load-families)
  (let (out)
    (maphash (lambda (_k v)
               (when (or (null category) (eq (plist-get v :category) category))
                 (push v out)))
             cmacs-calculator-registry)
    (sort out (lambda (a b) (string< (symbol-name (plist-get a :name))
                                     (symbol-name (plist-get b :name)))))))

(defun cmacs-calculator-categories ()
  "Return the list of categories that have registered calculators.
Loads the calculator families first."
  (cmacs-calculator-load-families)
  (let (out)
    (maphash (lambda (_k v)
               (cl-pushnew (plist-get v :category) out))
             cmacs-calculator-registry)
    (sort out (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(eval-and-compile
  (defun cmacs-calculator--quote-plist (plist)
    "Return PLIST as a list of forms suitable for splicing into `list'."
    (let (out)
      (while plist
        (push (car plist) out)
        (push (list 'quote (cadr plist)) out)
        (setq plist (cddr plist)))
      (nreverse out))))

(defmacro cmacs-calculator-defcalc (name arglist &rest body)
  "Define calculator NAME over ARGLIST and register its metadata.

BODY may open with these keyword/value pairs, which are stripped before
the remaining forms become the function body:

  :category  symbol grouping the calculator (financial, physics, ...)
  :title     one-line human-readable name
  :doc       longer description
  :args      list of (SYMBOL DESCRIPTION . PLIST) documenting each argument
  :returns   description of the result
  :examples  list of (EXPRESSION . EXPECTED-RESULT) strings

The function is defined with Calc's `defmath', so it becomes a
first-class algebraic function usable anywhere an expression is: in a
sheet, in the REPL, inline in another buffer, and composed inside a
larger formula such as \"simpleint(1000,0.05,3) + 100\"."
  (declare (indent 2) (doc-string 3))
  (let ((meta nil))
    (while (keywordp (car body))
      (setq meta (plist-put meta (pop body) (pop body))))
    `(progn
       (defmath ,name ,arglist ,@body)
       (cmacs-calculator-register ',name (list ,@(cmacs-calculator--quote-plist meta)))
       ',name)))


;;; Availability

(defun cmacs-calculator-supported-p ()
  "Return non-nil if the calculator engine is usable in this session.
The engine is pure Lisp over GNU Calc, so this is true whenever Calc
loaded.  Chart rendering has its own availability checks; see
`cmacs-calculator-chart-backend'."
  (and (fboundp 'calc-eval) (featurep 'calc-ext) t))

(provide 'cmacs-calculator)
;;; cmacs-calculator.el ends here
