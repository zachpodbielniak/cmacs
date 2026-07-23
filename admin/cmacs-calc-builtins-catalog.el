;;; cmacs-calc-builtins-catalog.el --- Calc built-ins catalog data + generator -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Single source of truth for the cmacs calculator's catalog of GNU Calc
;; built-in functions.  The wrapper's validator accepts any function Calc
;; defines (`fboundp' on the `calcFunc-' symbol, no whitelist), so the
;; catalog below enumerates every one of them with a description, argument
;; docs and a live-verified example, and the generator emits BOTH doc
;; formats from this one file so they cannot diverge:
;;
;;   doc_org/cmacs/calculator/builtins.org
;;   doc/cmacs/calculator/builtins.texi
;;
;; Usage, from the repo root:
;;
;;   src/emacs -Q -batch -L lisp/cmacs -L admin \
;;     -l cmacs-calc-builtins-catalog -f cmacs-calc-builtins-verify
;;   src/emacs -Q -batch -L lisp/cmacs -L admin \
;;     -l cmacs-calc-builtins-catalog -f cmacs-calc-builtins-generate
;;   src/emacs -Q -batch -L lisp/cmacs -L admin \
;;     -l cmacs-calc-builtins-catalog -f cmacs-calc-builtins-completion-list
;;   src/emacs -Q -batch -L lisp/cmacs -L admin \
;;     -l cmacs-calc-builtins-catalog -f cmacs-calc-builtins-generate-lsp-data
;;
;; `verify' checks the data (schema, coverage against the live Calc symbol
;; table, every example evaluates and matches its recorded output) and
;; exits non-zero on any failure.  `generate' re-evaluates every example
;; and writes both catalog files -- each printed result is real engine
;; output at generation time.  `completion-list' prints the defconst for
;; `cmacs-calculator-sheet--calc-functions' (lisp/cmacs/
;; cmacs-calculator-sheet.el), which must be regenerated here whenever an
;; upstream Emacs merge changes Calc's function set -- the ERT test
;; cmacs-calculator-tests-builtins-documented in
;; test/cmacs/cmacs-calculator-tests.el fails when the two drift.
;; `generate-lsp-data' writes cmacs/lsp/cmacs-lsp-gnucalc-data.h, the C
;; data table behind `emacs --cmacs-lsp gnucalc' (built-ins + registered
;; cmacs calculators + constants + Calc units); regenerate it alongside
;; the other two whenever the catalog or the registry changes -- the ERT
;; test cmacs-lsp-tests-gnucalc-data-in-sync fails when it drifts.
;;
;; Entry schema (a plist per function):
;;   :name     function name as typed in expressions, e.g. "deriv"
;;   :category key from `cmacs-calc-builtins--categories'
;;   :args     display signature, e.g. "(expr, var, value?)"; a trailing
;;             `?' marks an optional argument, `...' a &rest tail
;;   :desc     prose; arguments in UPPERCASE, identifiers quoted `so'
;;             (rendered =so= in org, @code{so} in texi)
;;   :arg-docs alist of (NAME . DOC), NAME without ?/... markers
;;   :returns  short noun phrase
;;   :examples list of expression strings
;;   :expect   recorded outputs, same order (nil for a volatile example)
;;   :eval     num -> `cmacs-calculator-eval' (strict numeric path)
;;             sym -> `cmacs-calculator-eval-symbolic'
;;   :volatile non-nil when output varies run to run (random, now, ...)
;;   :note     optional extra paragraph after the Returns line

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-calculator)

(defconst cmacs-calc-builtins--root
  (expand-file-name ".." (file-name-directory
                          (or load-file-name buffer-file-name)))
  "Repository root, derived from this file's location in admin/.")

(defconst cmacs-calc-builtins--categories
  '((arith-round    "Arithmetic and rounding")
    (exp-log        "Exponentials and logarithms")
    (trig           "Trigonometry")
    (hyperbolic     "Hyperbolic functions")
    (complex        "Complex numbers")
    (comb-nt        "Combinatorics and number theory")
    (random         "Random numbers")
    (binary         "Binary and word operations")
    (vec-mat        "Vectors and matrices")
    (sets           "Sets")
    (map-reduce     "Mapping and reduction")
    (statistics     "Statistics")
    (special        "Special functions")
    (distributions  "Probability distributions")
    (algebra        "Algebra and simplification")
    (polynomials    "Polynomials")
    (calculus       "Calculus")
    (solving        "Equation solving")
    (numerical      "Numerical methods")
    (fitting        "Curve fitting and interpolation")
    (rewrite        "Rewrite rules and pattern matching")
    (date-time      "Date and time")
    (forms          "HMS, error, interval and modulo forms")
    (financial      "Financial")
    (units-db-music "Units, decibels and music")
    (logical        "Logical operations")
    (declarations   "Declarations")
    (internals      "Evaluation and display internals"))
  "Catalog categories, in document order.")

(defconst cmacs-calc-builtins--entries
  '(
    (:name "abs" :category arith-round
     :args "(a)"
     :desc "Absolute value of A.  For a complex A this is the complex
magnitude; for a vector or matrix it is the Frobenius norm, the
square root of the sum of the squared element magnitudes."
     :arg-docs (("a" . "Number, complex number, vector, or matrix"))
     :returns "A nonnegative real number"
     :examples ("abs(-3.5)" "abs((3, 4))")
     :expect ("3.5" "5")
     :eval num :volatile nil
     :note nil)
    (:name "abssqr" :category arith-round
     :args "(a)"
     :desc "Absolute value squared of A.  For a complex number this is
`re(a)^2 + im(a)^2', computed without the square root that
squaring `abs' would need.  Vectors, matrices, and error forms
are also accepted."
     :arg-docs (("a" . "Number, complex number, vector, or matrix"))
     :returns "The squared magnitude of A"
     :examples ("abssqr((3, 4))")
     :expect ("25")
     :eval num :volatile nil
     :note nil)
    (:name "add" :category arith-round
     :args "(objs...)"
     :desc "Sum of all the arguments, the function form of the `+'
operator.  Anything `+' accepts may be mixed in: numbers,
vectors, matrices, HMS forms, date forms, intervals."
     :arg-docs (("objs" . "Terms to sum"))
     :returns "The sum of OBJS"
     :examples ("add(1, 2, 3)")
     :expect ("6")
     :eval num :volatile nil
     :note nil)
    (:name "ceil" :category arith-round
     :args "(a, prec?)"
     :desc "Round A up to an integer, toward plus infinity: `ceil(3.2)' is
4 and `ceil(-3.2)' is -3.  With PREC, round at PREC digits after
the decimal point instead; a negative PREC rounds to the left of
the point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "The smallest integer not less than A"
     :examples ("ceil(3.2)")
     :expect ("4")
     :eval num :volatile nil
     :note nil)
    (:name "clean" :category arith-round
     :args "(a, prec?)"
     :desc "Round off accumulated floating-point error in A.  With PREC,
the value is re-rounded to PREC significant digits, values whose
exponent falls below -PREC collapse to zero, and integer-valued
floats become true integers: `clean(sqrt(2)^2, 10)' repairs
1.99999999999 to 2.  Without PREC it merely re-rounds to the
current precision.  Works on the top level of a number or
vector; `pclean' is the pervasive version."
     :arg-docs (("a" . "Value to clean, typically a float or vector of floats") ("prec" . "Optional; digits to keep, an integer of at least 3"))
     :returns "A with floating-point cruft rounded away"
     :examples ("clean(sqrt(2)^2, 10)")
     :expect ("2")
     :eval num :volatile nil
     :note nil)
    (:name "decr" :category arith-round
     :args "(x, step?, relative-to?)"
     :desc "Decrease X by one unit, or by STEP units.  An integer decreases
by STEP itself; a float decreases by STEP units in its last
significant digit at the working precision, so at the default 12
digits `decr(12.3456)' perturbs the twelfth digit.  `decr(x, n)'
is exactly `incr(x, -n)'; see `incr' for the remaining details."
     :arg-docs (("x" . "Integer, float, or date form") ("step" . "Optional; integer number of units (default 1)") ("relative-to" . "Optional; float whose last place defines the unit when X is 0.0"))
     :returns "X reduced by STEP units in the last place"
     :examples ("decr(12.3456)")
     :expect ("12.3455999999")
     :eval num :volatile nil
     :note nil)
    (:name "div" :category arith-round
     :args "(a, objs...)"
     :desc "Divide A by each of OBJS in turn, the function form of the `/'
operator: `div(a, b, c)' is `(a / b) / c'.  Dividing two
integers that do not divide evenly yields a float; use `fdiv'
for an exact fraction."
     :arg-docs (("a" . "Dividend") ("objs" . "One or more divisors"))
     :returns "The quotient"
     :examples ("div(10, 4)")
     :expect ("2.5")
     :eval num :volatile nil
     :note nil)
    (:name "fceil" :category arith-round
     :args "(a, prec?)"
     :desc "Like `ceil', rounding A up toward plus infinity, but the
result is an integer-valued float rather than an integer.  With
PREC, rounding happens PREC digits after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "The ceiling of A, as a float"
     :examples ("fceil(3.2)")
     :expect ("4.")
     :eval num :volatile nil
     :note nil)
    (:name "fdiv" :category arith-round
     :args "(a, b)"
     :desc "Divide the integers A and B, producing an exact fraction in
lowest terms, as if Fraction mode were temporarily in effect:
`fdiv(8, 6)' is `4:3' where plain `/' would give a float.
Arguments must be integer-valued (fractions are also accepted);
other floats are rejected."
     :arg-docs (("a" . "Integer numerator") ("b" . "Integer denominator, nonzero"))
     :returns "The fraction A:B in lowest terms"
     :examples ("fdiv(8, 6)")
     :expect ("4:3")
     :eval num :volatile nil
     :note nil)
    (:name "ffloor" :category arith-round
     :args "(a, prec?)"
     :desc "Like `floor', rounding A down toward minus infinity, but the
result is an integer-valued float rather than an integer.  With
PREC, rounding happens PREC digits after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "The floor of A, as a float"
     :examples ("ffloor(-3.6)")
     :expect ("-4.")
     :eval num :volatile nil
     :note nil)
    (:name "float" :category arith-round
     :args "(a)"
     :desc "Convert A to floating-point form: `float(3:2)' is 1.5.  Only a
number or the elements of a top-level vector are converted;
applied to a formula like `a + 1' the call stays unevaluated,
guaranteeing a float only once the variables get values.  Use
`pfloat' to convert the numbers inside a formula right away."
     :arg-docs (("a" . "Number or vector to convert"))
     :returns "A as a float"
     :examples ("float(3:2)")
     :expect ("1.5")
     :eval num :volatile nil
     :note nil)
    (:name "floor" :category arith-round
     :args "(a, prec?)"
     :desc "Round A down to an integer, toward minus infinity, so negative
numbers round away from zero: `floor(-3.6)' is -4.  With PREC,
round at PREC digits after the decimal point instead."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "The largest integer not exceeding A"
     :examples ("floor(-3.6)")
     :expect ("-4")
     :eval num :volatile nil
     :note nil)
    (:name "frac" :category arith-round
     :args "(a, tol?)"
     :desc "Convert the float A to an exact fraction that reproduces A to
within the current precision, or to within TOL: `frac(3.14159,
5)' finds the classic 355:113.  A positive integer TOL means
that many significant figures, zero or a negative integer means
that many digits fewer than the current precision, and a float
TOL is an absolute error bound.  Like `float', this is
non-pervasive; `pfrac' reaches inside formulas."
     :arg-docs (("a" . "Float (or vector) to convert") ("tol" . "Optional; significant figures, precision offset, or absolute error"))
     :returns "A fraction approximating A"
     :examples ("frac(3.14159, 5)")
     :expect ("355:113")
     :eval num :volatile nil
     :note nil)
    (:name "fround" :category arith-round
     :args "(a, prec?)"
     :desc "Like `round', rounding A to the nearest integer with exact
halves going away from zero, but the result is an integer-valued
float rather than an integer.  With PREC, rounding happens PREC
digits after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "A rounded to the nearest integer, as a float"
     :examples ("fround(3.5)")
     :expect ("4.")
     :eval num :volatile nil
     :note nil)
    (:name "frounde" :category arith-round
     :args "(a, prec?)"
     :desc "Like `rounde' — round A to the nearest integer with ties going
to the even neighbor — but the result is an integer-valued float
rather than an integer.  With PREC, rounding happens PREC digits
after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "A banker's-rounded, as a float"
     :examples ("frounde(2.5)")
     :expect ("2.")
     :eval num :volatile nil
     :note nil)
    (:name "froundu" :category arith-round
     :args "(a, prec?)"
     :desc "Like `roundu' — round A to the nearest integer with exact
halves going upward, toward plus infinity — but the result is an
integer-valued float rather than an integer.  With PREC,
rounding happens PREC digits after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "A rounded half-up, as a float"
     :examples ("froundu(-2.5)")
     :expect ("-2.")
     :eval num :volatile nil
     :note nil)
    (:name "ftrunc" :category arith-round
     :args "(a, prec?)"
     :desc "Like `trunc', chopping the fractional part of A (rounding
toward zero), but the result is an integer-valued float rather
than an integer.  With PREC, truncation happens PREC digits
after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to truncate (default 0)"))
     :returns "A truncated toward zero, as a float"
     :examples ("ftrunc(-3.6)")
     :expect ("-3.")
     :eval num :volatile nil
     :note nil)
    (:name "idiv" :category arith-round
     :args "(a, b)"
     :desc "Integer quotient of A by B, dividing and rounding down toward
minus infinity in one exact operation, so integer arguments
never suffer floating-point roundoff.  The floor convention
means `idiv(-17, 5)' is -4, not -3.  In algebraic notation the
`\\' operator is shorthand: `17 \\ 5' parses as `idiv(17, 5)'."
     :arg-docs (("a" . "Dividend") ("b" . "Divisor, nonzero"))
     :returns "floor(A / B)"
     :examples ("idiv(17, 5)" "idiv(-17, 5)")
     :expect ("3" "-4")
     :eval num :volatile nil
     :note nil)
    (:name "incr" :category arith-round
     :args "(x, step?, relative-to?)"
     :desc "Increase X by one unit, or by STEP units.  An integer increases
by STEP itself; a float increases by STEP units in its last
significant digit at the working precision, so at the default 12
digits `incr(12.3456)' changes the twelfth digit, not the fifth.
Incrementing the float 0.0 yields one unit at 10^-precision
unless RELATIVE-TO supplies the float whose last place defines
the unit.  Date/time forms advance by seconds, pure dates by
days."
     :arg-docs (("x" . "Integer, float, or date form") ("step" . "Optional; integer number of units (default 1)") ("relative-to" . "Optional; float whose last place defines the unit when X is 0.0"))
     :returns "X advanced by STEP units in the last place"
     :examples ("incr(12.3456)")
     :expect ("12.3456000001")
     :eval num :volatile nil
     :note nil)
    (:name "inv" :category arith-round
     :args "(m)"
     :desc "Reciprocal `1 / M' of a number, or the inverse of a square
matrix M."
     :arg-docs (("m" . "Number or square matrix"))
     :returns "The reciprocal or matrix inverse of M"
     :examples ("inv(4)" "inv([[1, 2], [3, 4]])")
     :expect ("0.25" "[[-2, 1], [1.5, -0.5]]")
     :eval num :volatile nil
     :note nil)
    (:name "ldiv" :category arith-round
     :args "(a, b)"
     :desc "Left division: the solution X of `a * x = b'.  For scalar A
this is simply `B / A'; for a matrix A it is `inv(A) * B', where
the operand order matters."
     :arg-docs (("a" . "Scalar or square matrix to divide by") ("b" . "Value on the right-hand side"))
     :returns "The solution of A * x = B"
     :examples ("ldiv(4, 12)" "ldiv([[2, 0], [0, 4]], [6, 8])")
     :expect ("3" "[3., 2.]")
     :eval num :volatile nil
     :note nil)
    (:name "mant" :category arith-round
     :args "(x)"
     :desc "Mantissa part M of the float X, the M in `x = m * 10^e' with M
in the interval [1, 10): `mant(3721.5)' is 3.7215.  Integers and
fractions are returned unchanged, and the mantissa of zero is 0.
`xpon' extracts the matching exponent."
     :arg-docs (("x" . "Float (integers and fractions pass through unchanged)"))
     :returns "The mantissa, in the interval [1, 10)"
     :examples ("mant(3721.5)")
     :expect ("3.7215")
     :eval num :volatile nil
     :note nil)
    (:name "max" :category arith-round
     :args "(objs...)"
     :desc "Maximum of all the arguments.  Arguments may be real numbers,
HMS forms, date forms, intervals, or infinities, in any
combination that is mutually comparable."
     :arg-docs (("objs" . "Values to compare"))
     :returns "The largest argument"
     :examples ("max(1, 5, 3)")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "min" :category arith-round
     :args "(objs...)"
     :desc "Minimum of all the arguments.  Arguments may be real numbers,
HMS forms, date forms, intervals, or infinities, in any
combination that is mutually comparable."
     :arg-docs (("objs" . "Values to compare"))
     :returns "The smallest argument"
     :examples ("min(1, 5, 3)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "mod" :category arith-round
     :args "(a, b)"
     :desc "Remainder of A modulo B: `a - floor(a/b) * b', defined for all
real A and nonzero real B.  For positive B the result always
lies in [0, B) whatever the sign of A, so `mod(-4, 3)' is 2.
Applied to a modulo-form A, it re-targets the form to modulus
B."
     :arg-docs (("a" . "Dividend") ("b" . "Modulus, nonzero"))
     :returns "The remainder of A modulo B"
     :examples ("mod(-4, 3)")
     :expect ("2")
     :eval num :volatile nil
     :note nil)
    (:name "mul" :category arith-round
     :args "(objs...)"
     :desc "Product of all the arguments, the function form of the `*'
operator.  Anything `*' accepts is allowed, including matrices,
where the left-to-right multiplication order matters."
     :arg-docs (("objs" . "Factors to multiply"))
     :returns "The product of OBJS"
     :examples ("mul(2, 3, 4)")
     :expect ("24")
     :eval num :volatile nil
     :note nil)
    (:name "neg" :category arith-round
     :args "(a)"
     :desc "Negation of A, the function form of unary minus.  Works on
numbers, vectors and matrices, HMS forms, date forms, error
forms, intervals, and modulo forms."
     :arg-docs (("a" . "Value to negate"))
     :returns "A with its sign flipped"
     :examples ("neg(5)")
     :expect ("-5")
     :eval num :volatile nil
     :note nil)
    (:name "pclean" :category arith-round
     :args "(a, prec?)"
     :desc "Pervasive version of `clean': every float anywhere inside the
formula or vector A is re-rounded to PREC digits, sub-precision
values collapse to zero, and integer-valued floats become true
integers.  Handy for stripping roundoff noise from a whole
symbolic result at once."
     :arg-docs (("a" . "Value or formula to clean") ("prec" . "Optional; digits to keep, an integer of at least 3"))
     :returns "A with every embedded float cleaned"
     :examples ("pclean(2.0000000001 x + 3.0, 6)")
     :expect ("2 x + 3")
     :eval sym :volatile nil
     :note nil)
    (:name "percent" :category arith-round
     :args "(x)"
     :desc "X taken as a percentage, i.e. simply `X / 100'.  This is the
function behind the postfix `%' operator, so `5.4%' evaluates to
0.054; the operator binds very tightly, making `1 + 8%' parse as
`1 + percent(8)'."
     :arg-docs (("x" . "Percentage value"))
     :returns "X divided by 100"
     :examples ("percent(5.4)")
     :expect ("0.054")
     :eval num :volatile nil
     :note nil)
    (:name "pfloat" :category arith-round
     :args "(a)"
     :desc "Pervasive float conversion: every number inside the formula or
object A becomes a float immediately — `pfloat(a + 1)' turns
into `a + 1.' as soon as it is evaluated, unlike `float', which
waits until its argument is a plain number."
     :arg-docs (("a" . "Value or formula whose numbers to convert"))
     :returns "A with all its numbers floated"
     :examples ("pfloat(a + 1)")
     :expect ("a + 1.")
     :eval sym :volatile nil
     :note nil)
    (:name "pfrac" :category arith-round
     :args "(a, tol?)"
     :desc "Pervasive version of `frac': every float inside the formula or
object A becomes an exact fraction, correct to the current
precision or to the tolerance TOL.  The conversion happens
immediately even in symbolic expressions: `pfrac(x + 0.5)' is
`x + 1:2'."
     :arg-docs (("a" . "Value or formula whose floats to convert") ("tol" . "Optional; significant figures, precision offset, or absolute error"))
     :returns "A with embedded floats turned into fractions"
     :examples ("pfrac(x + 0.5)")
     :expect ("x + 1:2")
     :eval sym :volatile nil
     :note nil)
    (:name "pow" :category arith-round
     :args "(a, b)"
     :desc "Raise A to the power B, the function form of the `^' operator.
Integer powers are computed exactly, including integer powers of
square matrices; other powers go through logs and exponentials
and can produce complex results for negative A."
     :arg-docs (("a" . "Base") ("b" . "Exponent"))
     :returns "A raised to the power B"
     :examples ("pow(2, 10)")
     :expect ("1024")
     :eval num :volatile nil
     :note nil)
    (:name "relch" :category arith-round
     :args "(x, y)"
     :desc "Relative change from X to Y: `(y - x) / x'.  Positive means an
increase, negative a decrease; `relch(40, 50)' is 0.25, a 25
percent rise.  The result is a plain ratio, not a percent form."
     :arg-docs (("x" . "Starting value, nonzero") ("y" . "Ending value"))
     :returns "The relative change (Y - X) / X"
     :examples ("relch(40, 50)")
     :expect ("0.25")
     :eval num :volatile nil
     :note nil)
    (:name "round" :category arith-round
     :args "(a, prec?)"
     :desc "Round A to the nearest integer, exact halves rounding away
from zero: `round(2.5)' is 3 and `round(-2.5)' is -3.  With
PREC, round at PREC digits after the decimal point —
`round(123.4567, 2)' is 123.46 — and a negative PREC rounds to
the left of the point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "A rounded to the nearest integer or decimal place"
     :examples ("round(2.5)" "round(123.4567, 2)")
     :expect ("3" "123.46")
     :eval num :volatile nil
     :note nil)
    (:name "rounde" :category arith-round
     :args "(a, prec?)"
     :desc "Round A to the nearest integer with ties going to the even
neighbor (banker's rounding): `rounde(4.5)' is 4 but
`rounde(5.5)' is 6.  Over a long calculation the tie-breaking
errors tend to cancel rather than accumulate.  With PREC,
rounding happens PREC digits after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "A rounded to the nearest integer, ties to even"
     :examples ("rounde(4.5)" "rounde(5.5)")
     :expect ("4" "6")
     :eval num :volatile nil
     :note "A is itself rounded to the working precision before `rounde'
looks at it, so a tie-breaking digit beyond the precision limit
is lost and the value is treated as an exact tie.")
    (:name "roundu" :category arith-round
     :args "(a, prec?)"
     :desc "Round A to the nearest integer with exact halves rounding
upward, toward plus infinity.  This differs from `round' only
for negative ties: `roundu(-2.5)' is -2 where `round' gives -3.
With PREC, rounding happens PREC digits after the decimal
point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to round (default 0)"))
     :returns "A rounded to the nearest integer, ties upward"
     :examples ("roundu(-2.5)")
     :expect ("-2")
     :eval num :volatile nil
     :note nil)
    (:name "scf" :category arith-round
     :args "(x, n)"
     :desc "Scale X by a power of ten: `X * 10^N', computed exactly, so
`scf(mant(x), xpon(x))' reconstructs any real X.  N must be an
integer; X may be any numeric value."
     :arg-docs (("x" . "Value to scale") ("n" . "Integer power of ten"))
     :returns "X times 10^N"
     :examples ("scf(5, -2)")
     :expect ("0.05")
     :eval num :volatile nil
     :note nil)
    (:name "sign" :category arith-round
     :args "(a, x?)"
     :desc "Sign of A: 1 if positive, -1 if negative, 0 if zero.  The
two-argument form `sign(a, x)' stands for `x * sign(a)',
yielding X, `-X', or 0 according to the sign of A."
     :arg-docs (("a" . "Value whose sign to take") ("x" . "Optional; value to multiply by the sign"))
     :returns "-1, 0, or 1 (times X in the two-argument form)"
     :examples ("sign(-3.5)")
     :expect ("-1")
     :eval num :volatile nil
     :note nil)
    (:name "sub" :category arith-round
     :args "(objs...)"
     :desc "Subtract each later argument from the first, the function form
of the `-' operator: `sub(10, 3, 2)' is `10 - 3 - 2'."
     :arg-docs (("objs" . "Minuend followed by one or more subtrahends"))
     :returns "The difference"
     :examples ("sub(10, 3, 2)")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "trunc" :category arith-round
     :args "(a, prec?)"
     :desc "Truncate A toward zero, chopping off the fractional part:
`trunc(3.6)' is 3 and `trunc(-3.6)' is -3.  With PREC,
truncation happens PREC digits after the decimal point."
     :arg-docs (("a" . "Real number, or vector of them") ("prec" . "Optional; decimal place at which to truncate (default 0)"))
     :returns "The integer part of A"
     :examples ("trunc(-3.6)")
     :expect ("-3")
     :eval num :volatile nil
     :note nil)
    (:name "xpon" :category arith-round
     :args "(x)"
     :desc "Exponent part E of the float X, the E in `x = m * 10^e' with
the mantissa M in [1, 10): `xpon(3721.5)' is 3 and
`xpon(0.0042)' is -3.  Integers, fractions, and zero all give
0."
     :arg-docs (("x" . "Float (integers and fractions give 0)"))
     :returns "The base-10 exponent of X"
     :examples ("xpon(3721.5)")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "alog" :category exp-log
     :args "(x, b?)"
     :desc "Antilogarithm of X in base B: `B^X', the inverse of `log' with
its arguments swapped.  With B omitted the base is `e', so
`alog(x)' equals `exp(x)' — pass 10 explicitly for the common
antilog."
     :arg-docs (("x" . "The logarithm value") ("b" . "Optional; base (default e)"))
     :returns "B raised to the power X"
     :examples ("alog(3, 2)" "alog(3)")
     :expect ("8" "20.0855369232")
     :eval num :volatile nil
     :note nil)
    (:name "exp" :category exp-log
     :args "(x)"
     :desc "The exponential function `e^X'.  Complex arguments are
accepted; `exp(1)' gives Euler's number to the working
precision."
     :arg-docs (("x" . "Real or complex exponent"))
     :returns "e raised to the power X"
     :examples ("exp(1)")
     :expect ("2.71828182846")
     :eval num :volatile nil
     :note nil)
    (:name "exp10" :category exp-log
     :args "(x)"
     :desc "Raise ten to the power X.  Apart from the exact case
`exp10(0)' = 1, the result is always computed as a float, so
`exp10(2)' is `100.' rather than the integer 100."
     :arg-docs (("x" . "Real or complex exponent"))
     :returns "10 raised to the power X, as a float"
     :examples ("exp10(2)")
     :expect ("100.")
     :eval num :volatile nil
     :note nil)
    (:name "expm1" :category exp-log
     :args "(x)"
     :desc "Compute `exp(x) - 1' with an algorithm that stays accurate for
X near zero, where `exp(x)' is so close to 1 that the literal
subtraction would cancel away most significant digits."
     :arg-docs (("x" . "Real or complex exponent"))
     :returns "exp(X) - 1, computed accurately near zero"
     :examples ("expm1(1e-10)")
     :expect ("1.00000000005e-10")
     :eval num :volatile nil
     :note "Compare `exp(1e-10) - 1', which collapses to exactly 1e-10:
the true value's trailing digits are lost to cancellation.")
    (:name "ilog" :category exp-log
     :args "(x, b)"
     :desc "Integer logarithm of X in base B: the true logarithm rounded
down to an integer, so `ilog(x, 10)' is 3 for every X from 1000
through 9999.  For positive integer arguments the computation
uses exact integer arithmetic; otherwise it is equivalent to
`floor(log(x, b))'."
     :arg-docs (("x" . "Positive value") ("b" . "Base, an integer greater than 1"))
     :returns "The floor of the base-B logarithm of X"
     :examples ("ilog(5000, 10)")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "isqrt" :category exp-log
     :args "(a)"
     :desc "Integer square root of A: the true square root rounded down to
an integer, computed with exact integer arithmetic so even huge
integers suffer no roundoff.  For a non-integer A this equals
`floor(sqrt(a))'."
     :arg-docs (("a" . "Nonnegative number"))
     :returns "The integer square root of A"
     :examples ("isqrt(10)")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "ln" :category exp-log
     :args "(x)"
     :desc "Natural (base-e) logarithm of X.  Complex arguments are
accepted, and a negative real X gives a complex result.  The
constant `e' is recognized, so `ln(e)' is exactly 1."
     :arg-docs (("x" . "Real or complex value, nonzero"))
     :returns "The natural logarithm of X"
     :examples ("ln(e)" "ln(2)")
     :expect ("1" "0.69314718056")
     :eval num :volatile nil
     :note nil)
    (:name "lnp1" :category exp-log
     :args "(x)"
     :desc "Compute `ln(1 + x)' with an algorithm that stays accurate for
X near zero, avoiding the cancellation the literal `ln(1 + x)'
would suffer when `1 + x' rounds to 1."
     :arg-docs (("x" . "Real or complex value greater than -1"))
     :returns "ln(1 + X), computed accurately near zero"
     :examples ("lnp1(1e-10)")
     :expect ("9.9999999995e-11")
     :eval num :volatile nil
     :note nil)
    (:name "log" :category exp-log
     :args "(x, b?)"
     :desc "Logarithm of X in base B, exact when possible: `log(1024, 2)'
is the integer 10.  With B omitted this is the natural
logarithm, identical to `ln'; pass 10 explicitly, or use
`log10', for the common log."
     :arg-docs (("x" . "Real or complex value, nonzero") ("b" . "Optional; base (default e)"))
     :returns "The base-B logarithm of X"
     :examples ("log(1024, 2)")
     :expect ("10")
     :eval num :volatile nil
     :note "One-argument `log' is the natural log, not base 10 as on many
calculators: `log(100)' is 4.60517018599, not 2.")
    (:name "log10" :category exp-log
     :args "(x)"
     :desc "Common (base-10) logarithm of X.  For a complex X it is
computed as `ln(x) / ln(10)'."
     :arg-docs (("x" . "Real or complex value, nonzero"))
     :returns "The base-10 logarithm of X"
     :examples ("log10(10000)")
     :expect ("4")
     :eval num :volatile nil
     :note nil)
    (:name "nroot" :category exp-log
     :args "(x, n)"
     :desc "Principal Nth root of X, computed as `x ^ (1:n)' with an exact
fractional power, so perfect powers come out exact:
`nroot(125, 3)' is the integer 5."
     :arg-docs (("x" . "The radicand") ("n" . "Root index"))
     :returns "The Nth root of X"
     :examples ("nroot(125, 3)")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "sqr" :category exp-log
     :args "(x)"
     :desc "Square of X, i.e. `x * x'.  Anything `^' accepts works,
including square matrices."
     :arg-docs (("x" . "Value to square"))
     :returns "X squared"
     :examples ("sqr(9)")
     :expect ("81")
     :eval num :volatile nil
     :note nil)
    (:name "sqrt" :category exp-log
     :args "(a)"
     :desc "Principal square root of A.  A negative real A gives a complex
result rather than an error: `sqrt(-4)' is `(0, 2)' in the
default rectangular format."
     :arg-docs (("a" . "The radicand"))
     :returns "The square root of A"
     :examples ("sqrt(2)" "sqrt(-4)")
     :expect ("1.41421356237" "(0, 2)")
     :eval num :volatile nil
     :note nil)
    (:name "arccos" :category trig
     :args "(x)"
     :desc "Inverse cosine of X.  The result is an angle in radians (the
engine's corrected default mode), in the range 0 to pi for real X
in [-1, 1].  An X outside that interval yields a complex result
rather than an error."
     :arg-docs (("x" . "Cosine value to invert"))
     :returns "The angle whose cosine is X, in radians"
     :examples ("arccos(0.5)")
     :expect ("1.0471975512")
     :eval num :volatile nil
     :note nil)
    (:name "arcsin" :category trig
     :args "(x)"
     :desc "Inverse sine of X.  The result is an angle in radians, in the
range -pi/2 to pi/2 for real X in [-1, 1].  An X outside that
interval yields a complex result rather than an error."
     :arg-docs (("x" . "Sine value to invert"))
     :returns "The angle whose sine is X, in radians"
     :examples ("arcsin(1)")
     :expect ("1.57079632679")
     :eval num :volatile nil
     :note nil)
    (:name "arcsincos" :category trig
     :args "(x)"
     :desc "Inverse of `sincos'.  X must be a two-element vector [C, S]
holding the cosine and sine of an angle; the result is the angle
`arctan2(S, C)' in radians, covering the full range -pi (exclusive)
to pi (inclusive)."
     :arg-docs (("x" . "Two-element vector [cos, sin]"))
     :returns "The angle encoded by the [cos, sin] pair, in radians"
     :examples ("arcsincos([0, 1])")
     :expect ("1.57079632679")
     :eval num :volatile nil
     :note "The element order matches `sincos' output: cosine first, sine
second.  Any other vector length is rejected.")
    (:name "arctan" :category trig
     :args "(x)"
     :desc "Inverse tangent of X.  The result is an angle in radians in
the range -pi/2 to pi/2.  Complex X is accepted."
     :arg-docs (("x" . "Tangent value to invert"))
     :returns "The angle whose tangent is X, in radians"
     :examples ("arctan(1)")
     :expect ("0.785398163397")
     :eval num :volatile nil
     :note nil)
    (:name "arctan2" :category trig
     :args "(y, x)"
     :desc "Angle of the point (X, Y) measured from the positive x-axis,
in radians.  Because the signs of both arguments are known, the
result covers the full circle, -pi (exclusive) to pi (inclusive),
where `arctan(y/x)' alone cannot distinguish opposite quadrants.
By (arbitrary) definition `arctan2(0, 0)' is 0."
     :arg-docs (("y" . "Vertical component; note it comes first") ("x" . "Horizontal component"))
     :returns "The full-circle polar angle of (X, Y), in radians"
     :examples ("arctan2(1, -1)")
     :expect ("2.35619449019")
     :eval num :volatile nil
     :note nil)
    (:name "cos" :category trig
     :args "(x)"
     :desc "Cosine of X, an angle in radians (the engine corrects Calc's
degree default).  X may also be a complex number, or an HMS form
interpreted as degrees-minutes-seconds."
     :arg-docs (("x" . "Angle in radians"))
     :returns "The cosine of X"
     :examples ("cos(pi)")
     :expect ("-1.")
     :eval num :volatile nil
     :note nil)
    (:name "cot" :category trig
     :args "(x)"
     :desc "Cotangent of X, the reciprocal of `tan'; X is an angle in
radians."
     :arg-docs (("x" . "Angle in radians"))
     :returns "The cotangent of X"
     :examples ("cot(1)")
     :expect ("0.642092615934")
     :eval num :volatile nil
     :note nil)
    (:name "csc" :category trig
     :args "(x)"
     :desc "Cosecant of X, the reciprocal of `sin'; X is an angle in
radians."
     :arg-docs (("x" . "Angle in radians"))
     :returns "The cosecant of X"
     :examples ("csc(1)")
     :expect ("1.18839510578")
     :eval num :volatile nil
     :note nil)
    (:name "deg" :category trig
     :args "(a)"
     :desc "Convert the angle A to degrees.  A real A is always taken to
be in radians, regardless of the current angular mode; an HMS form
is taken as degrees-minutes-seconds and flattened to a plain degree
count."
     :arg-docs (("a" . "Angle in radians, or an HMS form"))
     :returns "The same angle expressed in degrees"
     :examples ("deg(pi)")
     :expect ("180.")
     :eval num :volatile nil
     :note nil)
    (:name "hypot" :category trig
     :args "(a, b)"
     :desc "Length of the hypotenuse of a right triangle with legs A and
B, i.e. `sqrt(a^2 + b^2)'.  For complex arguments the squared
magnitudes are used."
     :arg-docs (("a" . "First leg") ("b" . "Second leg"))
     :returns "The Euclidean length sqrt(A^2 + B^2)"
     :examples ("hypot(3, 4)")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "rad" :category trig
     :args "(a)"
     :desc "Convert the angle A to radians.  A real A is taken to be in
degrees; an HMS form is taken as degrees-minutes-seconds."
     :arg-docs (("a" . "Angle in degrees, or an HMS form"))
     :returns "The same angle expressed in radians"
     :examples ("rad(180)")
     :expect ("3.14159265359")
     :eval num :volatile nil
     :note nil)
    (:name "sec" :category trig
     :args "(x)"
     :desc "Secant of X, the reciprocal of `cos'; X is an angle in
radians."
     :arg-docs (("x" . "Angle in radians"))
     :returns "The secant of X"
     :examples ("sec(0)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "sin" :category trig
     :args "(x)"
     :desc "Sine of X, an angle in radians (the engine corrects Calc's
degree default).  X may also be a complex number, or an HMS form
interpreted as degrees-minutes-seconds."
     :arg-docs (("x" . "Angle in radians"))
     :returns "The sine of X"
     :examples ("sin(pi/2)")
     :expect ("1.")
     :eval num :volatile nil
     :note "`pi' folds to a float before the sine is taken, so exact points
come back as floats: `sin(pi/2)' is `1.', not the integer 1.")
    (:name "sincos" :category trig
     :args "(x)"
     :desc "Sine and cosine of X computed together, returned as the vector
`[cos(x), sin(x)]'.  X is an angle in radians."
     :arg-docs (("x" . "Angle in radians"))
     :returns "A two-element vector [cos(X), sin(X)]"
     :examples ("sincos(1)")
     :expect ("[0.540302305868, 0.841470984808]")
     :eval num :volatile nil
     :note "The [cos, sin] order holds for numeric X only: Calc's symbolic
fallback builds the REVERSED vector, so `sincos(pi/3)' comes back as
[0.866..., 0.5], i.e. [sin, cos], because `pi/3' reaches the
function before folding.  Pass a plain number to get the documented
order.")
    (:name "tan" :category trig
     :args "(x)"
     :desc "Tangent of X, an angle in radians.  X may also be a complex
number."
     :arg-docs (("x" . "Angle in radians"))
     :returns "The tangent of X"
     :examples ("tan(pi/4)")
     :expect ("1.")
     :eval num :volatile nil
     :note nil)
    (:name "arccosh" :category hyperbolic
     :args "(x)"
     :desc "Inverse hyperbolic cosine of X.  Real results require X >= 1;
a smaller X yields a complex result rather than an error."
     :arg-docs (("x" . "Value to invert"))
     :returns "The value whose hyperbolic cosine is X"
     :examples ("arccosh(2)")
     :expect ("1.31695789692")
     :eval num :volatile nil
     :note nil)
    (:name "arcsinh" :category hyperbolic
     :args "(x)"
     :desc "Inverse hyperbolic sine of X, defined for all real X."
     :arg-docs (("x" . "Value to invert"))
     :returns "The value whose hyperbolic sine is X"
     :examples ("arcsinh(1)")
     :expect ("0.88137358702")
     :eval num :volatile nil
     :note nil)
    (:name "arctanh" :category hyperbolic
     :args "(x)"
     :desc "Inverse hyperbolic tangent of X.  Real results require
-1 < X < 1; a real X outside that interval yields a complex result
rather than an error."
     :arg-docs (("x" . "Value to invert"))
     :returns "The value whose hyperbolic tangent is X"
     :examples ("arctanh(0.5)")
     :expect ("0.549306144334")
     :eval num :volatile nil
     :note nil)
    (:name "cosh" :category hyperbolic
     :args "(x)"
     :desc "Hyperbolic cosine of X, `(exp(x) + exp(-x)) / 2'.  Always at
least 1 for real X."
     :arg-docs (("x" . "Real or complex argument"))
     :returns "The hyperbolic cosine of X"
     :examples ("cosh(1)")
     :expect ("1.54308063482")
     :eval num :volatile nil
     :note nil)
    (:name "coth" :category hyperbolic
     :args "(x)"
     :desc "Hyperbolic cotangent of X, the reciprocal of `tanh'.  At X = 0
the result is `uinf' (unsigned infinity)."
     :arg-docs (("x" . "Real or complex argument"))
     :returns "The hyperbolic cotangent of X"
     :examples ("coth(1)")
     :expect ("1.3130352855")
     :eval num :volatile nil
     :note nil)
    (:name "csch" :category hyperbolic
     :args "(x)"
     :desc "Hyperbolic cosecant of X, the reciprocal of `sinh'.  At X = 0
the result is `uinf' (unsigned infinity)."
     :arg-docs (("x" . "Real or complex argument"))
     :returns "The hyperbolic cosecant of X"
     :examples ("csch(1)")
     :expect ("0.850918128239")
     :eval num :volatile nil
     :note nil)
    (:name "sech" :category hyperbolic
     :args "(x)"
     :desc "Hyperbolic secant of X, the reciprocal of `cosh'.  Values lie
in (0, 1] for real X."
     :arg-docs (("x" . "Real or complex argument"))
     :returns "The hyperbolic secant of X"
     :examples ("sech(0)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "sinh" :category hyperbolic
     :args "(x)"
     :desc "Hyperbolic sine of X, `(exp(x) - exp(-x)) / 2'."
     :arg-docs (("x" . "Real or complex argument"))
     :returns "The hyperbolic sine of X"
     :examples ("sinh(1)")
     :expect ("1.17520119364")
     :eval num :volatile nil
     :note nil)
    (:name "tanh" :category hyperbolic
     :args "(x)"
     :desc "Hyperbolic tangent of X, `sinh(x) / cosh(x)'.  Real results
lie strictly between -1 and 1."
     :arg-docs (("x" . "Real or complex argument"))
     :returns "The hyperbolic tangent of X"
     :examples ("tanh(1)")
     :expect ("0.761594155956")
     :eval num :volatile nil
     :note nil)
    (:name "arg" :category complex
     :args "(a)"
     :desc "Polar angle (the \"argument\") of the complex number A, in
radians under the engine's default mode, in the range -pi
(exclusive) to pi (inclusive).  For a polar-form number this is
simply its angle component; a positive real gives 0 and a negative
real gives pi."
     :arg-docs (("a" . "Complex or real number"))
     :returns "The polar angle of A, in radians"
     :examples ("arg(3 + 4i)")
     :expect ("0.927295218002")
     :eval num :volatile nil
     :note nil)
    (:name "conj" :category complex
     :args "(a)"
     :desc "Complex conjugate of A: for `a + bi' the result is `a - bi'.
Real numbers are returned unchanged; a vector or matrix is
conjugated elementwise."
     :arg-docs (("a" . "Number, vector, or matrix"))
     :returns "The complex conjugate of A"
     :examples ("conj(3 + 4i)")
     :expect ("(3, -4)")
     :eval num :volatile nil
     :note "Rectangular complex results display as `(re, im)' pairs, so
`conj(3 + 4i)' prints as `(3, -4)'.")
    (:name "im" :category complex
     :args "(a)"
     :desc "Imaginary part of A.  A real A gives 0; vectors and matrices
are handled elementwise."
     :arg-docs (("a" . "Number, vector, or matrix"))
     :returns "The imaginary part of A"
     :examples ("im(3 + 4i)")
     :expect ("4")
     :eval num :volatile nil
     :note nil)
    (:name "polar" :category complex
     :args "(a)"
     :desc "Convert the complex number A to polar form, displayed as
`(r; theta)' where R is the magnitude and THETA the angle in the
current angular mode (radians by default).  Real numbers pass
through unchanged."
     :arg-docs (("a" . "Complex or real number"))
     :returns "A as a polar complex number (r; theta)"
     :examples ("polar(3 + 4i)")
     :expect ("(5; 0.927295218002)")
     :eval num :volatile nil
     :note nil)
    (:name "re" :category complex
     :args "(a)"
     :desc "Real part of A.  Real numbers are returned unchanged; applied
to a modulo form it extracts the value part; vectors and matrices
are handled elementwise."
     :arg-docs (("a" . "Number, vector, or matrix"))
     :returns "The real part of A"
     :examples ("re(3 + 4i)")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "rect" :category complex
     :args "(a)"
     :desc "Convert the complex number A from polar to rectangular form,
displayed as an `(re, im)' pair.  Rectangular input and real
numbers pass through unchanged."
     :arg-docs (("a" . "Complex or real number"))
     :returns "A as a rectangular complex number"
     :examples ("rect((5; 0.927295218002))")
     :expect ("(3., 4.)")
     :eval num :volatile nil
     :note nil)
    (:name "choose" :category comb-nt
     :args "(n, m)"
     :desc "Binomial coefficient N-choose-M, the number of ways to pick M
of N items: `n! / (m! (n-m)!)'.  Exact when both arguments are
integers; otherwise a floating-point approximation, defined for all
real arguments."
     :arg-docs (("n" . "Number of items to choose from") ("m" . "Number of items chosen"))
     :returns "The binomial coefficient C(N, M)"
     :examples ("choose(5, 2)" "choose(52, 5)")
     :expect ("10" "2598960")
     :eval num :volatile nil
     :note nil)
    (:name "dfact" :category comb-nt
     :args "(n)"
     :desc "Double factorial N!!.  For even N this is `2*4*...*n'; for odd
N it is `1*3*...*n'; `dfact(0)' is 1.  An integer-valued float
gives a float approximation; negative even integers are undefined."
     :arg-docs (("n" . "Integer, or integer-valued float"))
     :returns "The double factorial of N"
     :examples ("dfact(7)" "dfact(8)")
     :expect ("105" "384")
     :eval num :volatile nil
     :note nil)
    (:name "egcd" :category comb-nt
     :args "(a, b)"
     :desc "Extended greatest common divisor of A and B.  Returns the
vector `[g, s, t]' where G = gcd(A, B) and the Bezout coefficients
satisfy `g = s a + t b'."
     :arg-docs (("a" . "First integer") ("b" . "Second integer"))
     :returns "A vector [g, s, t] with G = S*A + T*B"
     :examples ("egcd(240, 46)")
     :expect ("[2, -9, 47]")
     :eval num :volatile nil
     :note nil)
    (:name "fact" :category comb-nt
     :args "(n)"
     :desc "Factorial of N.  An integer N gives an exact integer; an
integer-valued float gives a float approximation; a non-integral
real N is evaluated through the Euler Gamma function,
`fact(n) = gamma(n+1)'.  Large exact factorials can be slow; floats
keep fewer digits and are faster."
     :arg-docs (("n" . "Real number; integers give exact results"))
     :returns "The factorial of N"
     :examples ("fact(10)" "fact(5.5)")
     :expect ("3628800" "287.885277816")
     :eval num :volatile nil
     :note nil)
    (:name "gcd" :category comb-nt
     :args "(a, b)"
     :desc "Greatest common divisor of A and B.  Fractions are accepted:
the GCD of two fractions is the GCD of the numerators over the LCM
of the denominators, so `a / gcd(a, x)' is always an integer.
Other argument types stay symbolic."
     :arg-docs (("a" . "First integer or fraction") ("b" . "Second integer or fraction"))
     :returns "The greatest common divisor of A and B"
     :examples ("gcd(12, 18)" "gcd(2:3, 1:2)")
     :expect ("6" "1:6")
     :eval num :volatile nil
     :note nil)
    (:name "lcm" :category comb-nt
     :args "(a, b)"
     :desc "Least common multiple of A and B, integers or fractions.  The
product of `lcm(a, b)' and `gcd(a, b)' equals the absolute value of
`a b'."
     :arg-docs (("a" . "First integer or fraction") ("b" . "Second integer or fraction"))
     :returns "The least common multiple of A and B"
     :examples ("lcm(4, 6)")
     :expect ("12")
     :eval num :volatile nil
     :note nil)
    (:name "moebius" :category comb-nt
     :args "(n)"
     :desc "Moebius mu function of N.  If N is a product of K distinct
primes the result is (-1)^K; if N is divisible by the square of a
prime the result is 0."
     :arg-docs (("n" . "Positive integer"))
     :returns "-1, 0, or 1 according to N's prime factorization"
     :examples ("moebius(30)" "moebius(12)")
     :expect ("-1" "0")
     :eval num :volatile nil
     :note nil)
    (:name "nextprime" :category comb-nt
     :args "(n, iters?)"
     :desc "Smallest prime larger than N.  Below eight million primality
is decided exactly; above, a probabilistic test is used, and ITERS
extra iterations may be requested to raise confidence."
     :arg-docs (("n" . "Starting point; the result is strictly greater") ("iters" . "Optional; probabilistic-test iterations for large N"))
     :returns "The next prime above N"
     :examples ("nextprime(100)")
     :expect ("101")
     :eval num :volatile nil
     :note nil)
    (:name "perm" :category comb-nt
     :args "(n, m)"
     :desc "Number of permutations of N items taken M at a time,
`n! / (n-m)!'."
     :arg-docs (("n" . "Number of items to choose from") ("m" . "Length of each arrangement"))
     :returns "The permutation count P(N, M)"
     :examples ("perm(5, 2)")
     :expect ("20")
     :eval num :volatile nil
     :note nil)
    (:name "prevprime" :category comb-nt
     :args "(n, iters?)"
     :desc "Largest prime smaller than N.  Same behavior as `nextprime':
exact below eight million, probabilistic with ITERS iterations
above."
     :arg-docs (("n" . "Starting point; the result is strictly smaller") ("iters" . "Optional; probabilistic-test iterations for large N"))
     :returns "The nearest prime below N"
     :examples ("prevprime(100)")
     :expect ("97")
     :eval num :volatile nil
     :note nil)
    (:name "prfac" :category comb-nt
     :args "(n)"
     :desc "Prime factorization of the integer N, as a vector of prime
factors in increasing order, with multiplicity.  For a negative N
the first element is -1; for -1, 0, and 1 the result is just [N].
Factorization is exact up to 25 million; beyond that, factors above
5000 may be left as one large unfactored final element."
     :arg-docs (("n" . "Integer to factor"))
     :returns "A vector of prime factors whose product is N"
     :examples ("prfac(360)")
     :expect ("[2, 2, 2, 3, 3, 5]")
     :eval num :volatile nil
     :note nil)
    (:name "prime" :category comb-nt
     :args "(n, iters?)"
     :desc "Primality test: 1 if N is (probably) prime, 0 if it is not.
Below eight million the answer is exact; above, a probabilistic
test runs for ITERS iterations, each of which sharply reduces the
chance of a composite slipping through."
     :arg-docs (("n" . "Integer to test") ("iters" . "Optional; probabilistic-test iterations for large N"))
     :returns "1 for (probably) prime, 0 for composite"
     :examples ("prime(97)" "prime(98)")
     :expect ("1" "0")
     :eval num :volatile nil
     :note nil)
    (:name "stir1" :category comb-nt
     :args "(n, m)"
     :desc "Stirling number of the first kind for N and M.  The value is
SIGNED, with sign (-1)^(n-m); its absolute value counts the
permutations of N objects having exactly M cycles."
     :arg-docs (("n" . "Number of objects") ("m" . "Number of cycles"))
     :returns "The signed Stirling number of the first kind s(N, M)"
     :examples ("stir1(5, 2)")
     :expect ("-50")
     :eval num :volatile nil
     :note "The Calc manual describes the unsigned counting interpretation,
but the value actually returned is signed: `stir1(5, 2)' is -50,
while the number of 2-cycle permutations of 5 objects is 50.")
    (:name "stir2" :category comb-nt
     :args "(n, m)"
     :desc "Stirling number of the second kind for N and M: the number of
ways to partition N objects into M non-empty sets."
     :arg-docs (("n" . "Number of objects") ("m" . "Number of sets"))
     :returns "The Stirling number of the second kind S(N, M)"
     :examples ("stir2(5, 2)")
     :expect ("15")
     :eval num :volatile nil
     :note nil)
    (:name "totient" :category comb-nt
     :args "(n)"
     :desc "Euler totient function phi(N): how many integers between 1
and N are relatively prime to N."
     :arg-docs (("n" . "Positive integer"))
     :returns "The count of integers in 1..N coprime to N"
     :examples ("totient(36)")
     :expect ("12")
     :eval num :volatile nil
     :note nil)
    (:name "random" :category random
     :args "(max)"
     :desc "A uniformly distributed random value.  For a positive integer
MAX, an integer between 0 and MAX-1 inclusive; for a real MAX, a
real in the same range; for a vector MAX, a random element of the
vector.  MAX may also be an interval form, an error form (Gaussian
with that mean and spread), or 0 for a standard Gaussian real."
     :arg-docs (("max" . "Range specifier: integer, real, interval, error form, or vector"))
     :returns "A random value drawn from the range MAX describes"
     :examples ("random(100)")
     :expect (nil)
     :eval num :volatile t
     :note "Each evaluation yields a fresh value; store an integer in the
Calc variable `RandSeed' to get a reproducible sequence.")
    (:name "shuffle" :category random
     :args "(n, max?)"
     :desc "A vector of N distinct random values drawn from the set MAX
describes (any range accepted by `random': integer, interval, or
vector).  With a single argument the whole set it describes is
drawn exactly once, giving a random permutation."
     :arg-docs (("n" . "How many distinct values to draw") ("max" . "Optional; range specifier, as for `random'"))
     :returns "A vector of N distinct draws from MAX"
     :examples ("shuffle(3, 100)")
     :expect (nil)
     :eval num :volatile t
     :note "Outputs vary run to run.  Draws are distinct, so N must not
exceed the size of the set; `shuffle(10)' permutes the full set
0..9.")
    (:name "and" :category binary
     :args "(a, b, w?)"
     :desc "Bitwise AND of A and B: a result bit is 1 only where both
inputs have a 1.  Operates on a word of W bits if given, else the
current word size (default 32); negative inputs are first reduced
modulo 2^w."
     :arg-docs (("a" . "First integer operand") ("b" . "Second integer operand") ("w" . "Optional; word size for this call (default 32)"))
     :returns "The bitwise conjunction, clipped to the word"
     :examples ("and(12, 10)")
     :expect ("8")
     :eval num :volatile nil
     :note nil)
    (:name "ash" :category binary
     :args "(a, n?, w?)"
     :desc "Arithmetic shift of A by N bits (default 1).  Positive N
shifts left, exactly like `lsh'; negative N shifts right while
duplicating the leftmost (sign) bit of the W-bit word (default
32)."
     :arg-docs (("a" . "Integer to shift") ("n" . "Optional; bit count, default 1 (negative shifts right)") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A arithmetically shifted within the word"
     :examples ("ash(1, 4)" "ash(clip(-8), -1)")
     :expect ("16" "4294967292")
     :eval num :volatile nil
     :note nil)
    (:name "clip" :category binary
     :args "(a, w?)"
     :desc "Reduce A into the current word.  A positive W (or the default
word size of 32) clips modulo 2^w to the unsigned range 0 to
2^w-1; a negative W clips to the signed two's-complement range
-(2^(-w-1)) to 2^(-w-1)-1; W = 0 leaves A unclipped.  The other
binary functions clip their results like this automatically;
ordinary arithmetic never does."
     :arg-docs (("a" . "Integer to reduce") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A reduced into the word's range"
     :examples ("clip(-1)" "clip(-1, 8)")
     :expect ("4294967295" "255")
     :eval num :volatile nil
     :note nil)
    (:name "diff" :category binary
     :args "(a, b, w?)"
     :desc "Bit difference of A and B: the bits of A that are not set in
B, defined as `and(a, not(b))'.  This is set difference on bit
sets; it has nothing to do with calculus."
     :arg-docs (("a" . "Integer whose bits are kept") ("b" . "Integer whose bits are removed") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A with B's bits cleared, clipped to the word"
     :examples ("diff(12, 10)")
     :expect ("4")
     :eval num :volatile nil
     :note nil)
    (:name "lsh" :category binary
     :args "(a, n?, w?)"
     :desc "Logical left shift of A by N bits (default 1), zero-filling on
the right; bits pushed past the top of the W-bit word (default 32)
are lost.  A negative N shifts right instead, inserting zeros."
     :arg-docs (("a" . "Integer to shift") ("n" . "Optional; bit count, default 1 (negative shifts right)") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A logically shifted left within the word"
     :examples ("lsh(1, 4)")
     :expect ("16")
     :eval num :volatile nil
     :note nil)
    (:name "not" :category binary
     :args "(a, w?)"
     :desc "Bitwise complement of A within the word: every bit flips, so
`not(0)' is the all-ones word.  The word is W bits when given, else
the current word size (default 32)."
     :arg-docs (("a" . "Integer to complement") ("w" . "Optional; word size for this call (default 32)"))
     :returns "The bitwise complement of A within the word"
     :examples ("not(0)" "not(0, 8)")
     :expect ("4294967295" "255")
     :eval num :volatile nil
     :note nil)
    (:name "or" :category binary
     :args "(a, b, w?)"
     :desc "Bitwise inclusive OR of A and B: a result bit is 1 where
either input, or both, has a 1.  Clipped to W bits if given, else
the current word size (default 32)."
     :arg-docs (("a" . "First integer operand") ("b" . "Second integer operand") ("w" . "Optional; word size for this call (default 32)"))
     :returns "The bitwise disjunction, clipped to the word"
     :examples ("or(12, 10)")
     :expect ("14")
     :eval num :volatile nil
     :note nil)
    (:name "rash" :category binary
     :args "(a, n?, w?)"
     :desc "Arithmetic right shift of A by N bits (default 1): the
leftmost bit of the W-bit word (default 32) is duplicated as bits
shift in, which matches dividing a two's-complement value by 2^N.
A negative N shifts left.  Contrast `rsh', which always inserts
zeros."
     :arg-docs (("a" . "Integer to shift") ("n" . "Optional; bit count, default 1 (negative shifts left)") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A arithmetically shifted right within the word"
     :examples ("rash(clip(-8), 1)")
     :expect ("4294967292")
     :eval num :volatile nil
     :note nil)
    (:name "rot" :category binary
     :args "(a, n?, w?)"
     :desc "Rotate A left by N bits (default 1) within the W-bit word
(default 32): bits leaving the top re-enter at bit 0.  A negative N
rotates right.  Rotation is impossible with a word size of zero."
     :arg-docs (("a" . "Integer to rotate") ("n" . "Optional; bit count, default 1 (negative rotates right)") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A rotated within the word"
     :examples ("rot(2147483648, 1)")
     :expect ("1")
     :eval num :volatile nil
     :note "2147483648 is 2^31, the top bit of the default 32-bit word; one
left rotation wraps it around to bit 0.")
    (:name "rsh" :category binary
     :args "(a, n?, w?)"
     :desc "Logical right shift of A by N bits (default 1), inserting
zeros at the top of the W-bit word (default 32); `rsh(a, n)' is the
same as `lsh(a, -n)'.  A negative N shifts left."
     :arg-docs (("a" . "Integer to shift") ("n" . "Optional; bit count, default 1 (negative shifts left)") ("w" . "Optional; word size for this call (default 32)"))
     :returns "A logically shifted right within the word"
     :examples ("rsh(16, 2)")
     :expect ("4")
     :eval num :volatile nil
     :note nil)
    (:name "xor" :category binary
     :args "(a, b, w?)"
     :desc "Bitwise exclusive OR of A and B: a result bit is 1 where
exactly one of the inputs has a 1.  Clipped to W bits if given,
else the current word size (default 32)."
     :arg-docs (("a" . "First integer operand") ("b" . "Second integer operand") ("w" . "Optional; word size for this call (default 32)"))
     :returns "The bitwise exclusive disjunction, clipped to the word"
     :examples ("xor(12, 10)")
     :expect ("6")
     :eval num :volatile nil
     :note nil)
    (:name "append" :category vec-mat
     :args "(v1, v2)"
     :desc "Concatenate the vectors V1 and V2 into a single vector.  Unlike
the `vconcat' operator there are no special cases: both arguments
must be vectors, and a scalar argument leaves the call in symbolic
form."
     :arg-docs (("v1" . "First vector") ("v2" . "Second vector"))
     :returns "The concatenation of V1 and V2"
     :examples ("append([1, 2], [3, 4])")
     :expect ("[1, 2, 3, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "appendrev" :category vec-mat
     :args "(v1, v2)"
     :desc "Concatenate V2 followed by V1 — `append' with its arguments
swapped.  Useful as a mapping or reduction target when the reversed
argument order is the one you need."
     :arg-docs (("v1" . "Vector placed second in the result") ("v2" . "Vector placed first in the result"))
     :returns "The concatenation of V2 and V1"
     :examples ("appendrev([1, 2], [3, 4])")
     :expect ("[3, 4, 1, 2]")
     :eval num :volatile nil
     :note nil)
    (:name "arrange" :category vec-mat
     :args "(vec, cols)"
     :desc "Reshape VEC into a matrix with COLS columns.  The input is first
flattened into a plain vector, then regrouped into successive rows
of COLS elements.  If COLS does not evenly divide the element
count the final row is short and the result is not a true matrix;
a COLS of zero simply returns the flattened vector."
     :arg-docs (("vec" . "Vector or matrix to reshape") ("cols" . "Number of columns per row; 0 to flatten"))
     :returns "A matrix with COLS columns (or a flat vector for COLS = 0)"
     :examples ("arrange([1, 2, 3, 4, 5, 6], 2)")
     :expect ("[[1, 2], [3, 4], [5, 6]]")
     :eval num :volatile nil
     :note nil)
    (:name "cnorm" :category vec-mat
     :args "(a)"
     :desc "One-norm of the vector A: the sum of the absolute values of its
elements.  For a matrix, the column norm — the maximum over the
columns of each column's absolute-value sum."
     :arg-docs (("a" . "Vector or matrix"))
     :returns "The one-norm (column norm) of A"
     :examples ("cnorm([1, -2, 3])")
     :expect ("6")
     :eval num :volatile nil
     :note nil)
    (:name "cons" :category vec-mat
     :args "(head, tail)"
     :desc "Vector whose first element is HEAD and whose remaining elements
are the vector TAIL.  Unlike concatenation, a vector HEAD is
inserted as a single leading element rather than spliced in."
     :arg-docs (("head" . "Value to place first") ("tail" . "Vector of the remaining elements"))
     :returns "A vector one longer than TAIL"
     :examples ("cons(1, [2, 3])")
     :expect ("[1, 2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "cross" :category vec-mat
     :args "(a, b)"
     :desc "Right-handed cross product of A and B.  Both arguments must be
vectors of exactly three elements."
     :arg-docs (("a" . "First 3-element vector") ("b" . "Second 3-element vector"))
     :returns "A 3-element vector perpendicular to A and B"
     :examples ("cross([1, 0, 0], [0, 1, 0])")
     :expect ("[0, 0, 1]")
     :eval num :volatile nil
     :note nil)
    (:name "ctrn" :category vec-mat
     :args "(mat)"
     :desc "Conjugate transpose of MAT: the transpose with every element
replaced by its complex conjugate, i.e. `conj(trn(mat))'.  Complex
entries in the result display as rectangular pairs `(re, im)'."
     :arg-docs (("mat" . "Matrix (or vector) to conjugate-transpose"))
     :returns "The conjugate transpose of MAT"
     :examples ("ctrn([[1 + 2i, 3], [0, 4 - i]])")
     :expect ("[[(1, -2), 0], [3, (4, 1)]]")
     :eval num :volatile nil
     :note nil)
    (:name "cvec" :category vec-mat
     :args "(obj, dims...)"
     :desc "Vector or matrix filled with copies of OBJ.  `cvec(x, n)' builds
an N-element vector of X's; `cvec(x, n, m)' builds an N-by-M
matrix; further dimensions nest correspondingly deeper."
     :arg-docs (("obj" . "Value to replicate") ("dims" . "One or more dimension sizes"))
     :returns "A vector or matrix of copies of OBJ"
     :examples ("cvec(7, 3)" "cvec(0, 2, 3)")
     :expect ("[7, 7, 7]" "[[0, 0, 0], [0, 0, 0]]")
     :eval num :volatile nil
     :note nil)
    (:name "det" :category vec-mat
     :args "(m)"
     :desc "Determinant of the square matrix M."
     :arg-docs (("m" . "Square matrix"))
     :returns "The determinant of M"
     :examples ("det([[1, 2], [3, 4]])")
     :expect ("-2")
     :eval num :volatile nil
     :note nil)
    (:name "diag" :category vec-mat
     :args "(a, n?)"
     :desc "Diagonal matrix built from A.  If A is a vector its elements
become the diagonal of a square matrix; if A is a scalar it is
repeated along the diagonal and N is required.  When both are
given, N must match the length of A or the call stays symbolic."
     :arg-docs (("a" . "Vector of diagonal elements, or a scalar to repeat") ("n" . "Optional; size of the resulting square matrix"))
     :returns "A square matrix with A on the diagonal"
     :examples ("diag([1, 2, 3])")
     :expect ("[[1, 0, 0], [0, 2, 0], [0, 0, 3]]")
     :eval num :volatile nil
     :note nil)
    (:name "find" :category vec-mat
     :args "(vec, x, start?)"
     :desc "Index of the first element of VEC equal to X, searching from
position START (default 1).  Indices are 1-based; when no element
matches, the result is 0 rather than an error."
     :arg-docs (("vec" . "Vector to search") ("x" . "Target value") ("start" . "Optional; 1-based index to start searching from"))
     :returns "The 1-based index of the first match, or 0 if none"
     :examples ("find([5, 7, 9], 9)" "find([5, 7, 9], 4)")
     :expect ("3" "0")
     :eval num :volatile nil
     :note nil)
    (:name "getdiag" :category vec-mat
     :args "(mat)"
     :desc "Diagonal elements of the square matrix MAT, collected into a
vector."
     :arg-docs (("mat" . "Square matrix"))
     :returns "A vector of the diagonal elements of MAT"
     :examples ("getdiag([[1, 2], [3, 4]])")
     :expect ("[1, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "grade" :category vec-mat
     :args "(vec)"
     :desc "Permutation vector that sorts VEC into increasing order: element
K of the result is the index in VEC of the K-th smallest element.
Applying the result as a vector index (e.g. via `mrow') sorts VEC.
The sort is stable, and grading a permutation vector yields its
inverse permutation."
     :arg-docs (("vec" . "Vector to grade"))
     :returns "A permutation vector that sorts VEC ascending"
     :examples ("grade([30, 10, 20])")
     :expect ("[2, 3, 1]")
     :eval num :volatile nil
     :note nil)
    (:name "head" :category vec-mat
     :args "(vec)"
     :desc "First element of the non-empty vector VEC."
     :arg-docs (("vec" . "Non-empty vector"))
     :returns "The first element of VEC"
     :examples ("head([1, 2, 3])")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "histogram" :category vec-mat
     :args "(vec, wts?, n)"
     :desc "Bin counts for the data in VEC.  With an integer N, elements are
floored and counted into bins 0 through N-1; values outside that
range are silently ignored.  If N is a vector it lists bin
centers, and each datum counts toward the bin with the nearest
center.  With three arguments, WTS gives per-element weights that
are added in place of 1."
     :arg-docs (("vec" . "Vector of data values") ("wts" . "Optional; vector of per-element weights") ("n" . "Bin count, or vector of bin centers"))
     :returns "A vector of bin counts (or weight totals)"
     :examples ("histogram([0, 1, 1, 2, 1], 3)" "histogram([0, 1, 1, 2, 1], [2, 1, 1, 1, 1], 3)")
     :expect ("[1, 3, 1]" "[2, 3, 1]")
     :eval num :volatile nil
     :note "The optional argument sits in the middle: with two arguments
the second is N, not WTS.  Weights exist only in the
three-argument form.")
    (:name "idn" :category vec-mat
     :args "(a, n?)"
     :desc "Identity matrix scaled by A: `idn(a, n)' is A times the N-by-N
identity matrix.  With N omitted the result is a generic identity
matrix of unknown size, which stays symbolic until it is combined
with a matrix whose dimensions are known."
     :arg-docs (("a" . "Scalar diagonal value") ("n" . "Optional; matrix size"))
     :returns "A scaled identity matrix, or a generic `idn' form without N"
     :examples ("idn(1, 3)" "idn(2, 3)")
     :expect ("[[1, 0, 0], [0, 1, 0], [0, 0, 1]]" "[[2, 0, 0], [0, 2, 0], [0, 0, 2]]")
     :eval num :volatile nil
     :note "`idn(3)' is not a 3x3 identity — it is a generic identity
scaled by 3, and it evaluates to itself symbolically.  Write
`idn(1, 3)' to get the actual 3x3 identity matrix.")
    (:name "index" :category vec-mat
     :args "(n, start?, incr?)"
     :desc "Vector of N sequence values.  `index(n)' is [1 .. N]; with START
and INCR the sequence is arithmetic, beginning at START and
stepping by INCR (default 1).  A negative N combined with START
produces a geometric sequence instead, multiplying by INCR
(default 2) at each step."
     :arg-docs (("n" . "Element count; negative with START for geometric") ("start" . "Optional; first element value") ("incr" . "Optional; step (default 1) or ratio (default 2)"))
     :returns "A vector of N sequence values"
     :examples ("index(5)" "index(4, 10, 10)")
     :expect ("[1, 2, 3, 4, 5]" "[10, 20, 30, 40]")
     :eval num :volatile nil
     :note nil)
    (:name "kron" :category vec-mat
     :args "(x, y, nocheck?)"
     :desc "Kronecker product of X and Y.  Operands may be scalars, vectors,
or matrices, and the result type follows them: two vectors give a
vector, anything involving a matrix gives a matrix.  NOCHECK
skips the shape-promotion checks and is mainly internal."
     :arg-docs (("x" . "First operand") ("y" . "Second operand") ("nocheck" . "Optional; nonzero skips operand shape promotion"))
     :returns "The Kronecker product of X and Y"
     :examples ("kron([1, 2], [10, 20])" "kron([[0, 1], [1, 0]], [[1, 2], [3, 4]])")
     :expect ("[10, 20, 20, 40]" "[[0, 0, 1, 2], [0, 0, 3, 4], [1, 2, 0, 0], [3, 4, 0, 0]]")
     :eval num :volatile nil
     :note nil)
    (:name "lud" :category vec-mat
     :args "(m)"
     :desc "LU decomposition of the square matrix M.  The result is a vector
of three matrices [P, L, U] whose left-to-right product is M: a
permutation matrix arising from pivoting, a lower-triangular
matrix with unit diagonal, and an upper-triangular matrix.  The
factorization is numeric, so the factors generally contain
floats."
     :arg-docs (("m" . "Square matrix"))
     :returns "A vector of three matrices [P, L, U]"
     :examples ("lud([[2, 3], [6, 4]])")
     :expect ("[[[0, 1], [1, 0]], [[1, 0], [0.333333333333, 1]], [[6, 4], [0, 1.66666666667]]]")
     :eval num :volatile nil
     :note nil)
    (:name "mcol" :category vec-mat
     :args "(mat, n)"
     :desc "Column N of the matrix MAT, as a vector.  For a plain vector it
extracts one element.  A vector of indices selects (and possibly
permutes) several columns as a submatrix, and an interval index
selects a range of columns."
     :arg-docs (("mat" . "Matrix (or plain vector)") ("n" . "Column index, index vector, or interval"))
     :returns "The selected column(s)"
     :examples ("mcol([[1, 2], [3, 4]], 2)")
     :expect ("[2, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "mdims" :category vec-mat
     :args "(m)"
     :desc "Dimension vector of M.  A plain N-element vector gives [N]; an
N-by-M matrix gives [N, M]; deeper nestings add further entries."
     :arg-docs (("m" . "Vector or matrix"))
     :returns "A vector of the dimensions of M"
     :examples ("mdims([[1, 2, 3], [4, 5, 6]])")
     :expect ("[2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "mrcol" :category vec-mat
     :args "(mat, n)"
     :desc "MAT with column N removed.  Given a plain vector, removes one
element instead."
     :arg-docs (("mat" . "Matrix (or plain vector)") ("n" . "Column index to remove"))
     :returns "MAT without its N-th column"
     :examples ("mrcol([[1, 2, 3], [4, 5, 6]], 2)")
     :expect ("[[1, 3], [4, 6]]")
     :eval num :volatile nil
     :note nil)
    (:name "mrow" :category vec-mat
     :args "(mat, n)"
     :desc "Row N of the matrix MAT, or element N of a plain vector.  A
vector of indices yields the corresponding rows or elements — any
permutation of the input can be produced this way — and an
interval of integers yields that range of rows.  Subscript
notation `m_i' is shorthand for the same operation."
     :arg-docs (("mat" . "Matrix or vector") ("n" . "Row index, index vector, or interval"))
     :returns "The selected row(s) or element(s)"
     :examples ("mrow([[1, 2], [3, 4]], 2)")
     :expect ("[3, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "mrrow" :category vec-mat
     :args "(mat, n)"
     :desc "MAT with row N removed (element N, for a plain vector)."
     :arg-docs (("mat" . "Matrix or vector") ("n" . "Row index to remove"))
     :returns "MAT without its N-th row"
     :examples ("mrrow([[1, 2], [3, 4], [5, 6]], 2)")
     :expect ("[[1, 2], [5, 6]]")
     :eval num :volatile nil
     :note nil)
    (:name "pack" :category vec-mat
     :args "(mode, els)"
     :desc "Rebuild a composite object from the parts in the vector ELS,
according to the packing MODE.  A vector MODE gives matrix
dimensions; negative integer modes build special forms — for
example -4 packs a value and a tolerance into an error form.  An
invalid MODE, or an ELS count that does not match what the mode
requires, leaves the call in symbolic form."
     :arg-docs (("mode" . "Packing mode: integer code or dimension vector") ("els" . "Vector of components to pack"))
     :returns "The packed composite object"
     :examples ("pack(-4, [3, 5])" "pack([2, 2], [1, 2, 3, 4])")
     :expect ("3 +/- 5" "[[1, 2], [3, 4]]")
     :eval num :volatile nil
     :note "The MODE codes are Calc's packing modes (Calc manual, node
`Packing and Unpacking'): -1 complex, -4 error form, -5 modulo
form, -10 fraction, and more.")
    (:name "rcons" :category vec-mat
     :args "(head, tail)"
     :desc "Vector whose initial elements are the vector HEAD and whose last
element is TAIL.  The mirror image of `cons': the single element
is attached at the end."
     :arg-docs (("head" . "Vector of all elements but the last") ("tail" . "Value to append as the final element"))
     :returns "A vector one longer than HEAD"
     :examples ("rcons([1, 2], 3)")
     :expect ("[1, 2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "rev" :category vec-mat
     :args "(vec)"
     :desc "VEC reversed end for end.  For a matrix, the order of the rows is
reversed; transpose first (and after) to reverse columns instead."
     :arg-docs (("vec" . "Vector or matrix"))
     :returns "VEC in reverse order"
     :examples ("rev([1, 2, 3])")
     :expect ("[3, 2, 1]")
     :eval num :volatile nil
     :note nil)
    (:name "rgrade" :category vec-mat
     :args "(vec)"
     :desc "Permutation vector that sorts VEC into decreasing order — the
descending counterpart of `grade'.  The sort is stable: equal
elements keep their original relative order."
     :arg-docs (("vec" . "Vector to grade"))
     :returns "A permutation vector that sorts VEC descending"
     :examples ("rgrade([30, 10, 20])")
     :expect ("[1, 3, 2]")
     :eval num :volatile nil
     :note nil)
    (:name "rhead" :category vec-mat
     :args "(vec)"
     :desc "All elements of the non-empty vector VEC except the last."
     :arg-docs (("vec" . "Non-empty vector"))
     :returns "VEC without its last element"
     :examples ("rhead([1, 2, 3])")
     :expect ("[1, 2]")
     :eval num :volatile nil
     :note nil)
    (:name "rnorm" :category vec-mat
     :args "(a)"
     :desc "Infinity-norm of the vector A: the maximum absolute value among
its elements.  For a matrix, the row norm — the maximum over the
rows of each row's absolute-value sum."
     :arg-docs (("a" . "Vector or matrix"))
     :returns "The infinity-norm (row norm) of A"
     :examples ("rnorm([1, -5, 3])")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "rsort" :category vec-mat
     :args "(vec)"
     :desc "Elements of VEC sorted into decreasing order, using the same
canonical ordering as `sort'."
     :arg-docs (("vec" . "Vector to sort"))
     :returns "VEC sorted into decreasing order"
     :examples ("rsort([2, 5, 1])")
     :expect ("[5, 2, 1]")
     :eval num :volatile nil
     :note nil)
    (:name "rsubvec" :category vec-mat
     :args "(vec, start, end?)"
     :desc "VEC with the elements from START up to (but not including) END
removed — exactly the elements `subvec' would keep.  The two
functions always return complementary parts of VEC, and the index
conventions (zero/negative counts from the end, END omitted means
through the last element) are the same."
     :arg-docs (("vec" . "Vector to remove a range from") ("start" . "First index to remove") ("end" . "Optional; first index past the removed range"))
     :returns "VEC with the range removed"
     :examples ("rsubvec([1, 2, 3, 4, 5], 2, 4)")
     :expect ("[1, 4, 5]")
     :eval num :volatile nil
     :note nil)
    (:name "rtail" :category vec-mat
     :args "(vec)"
     :desc "Last element of the non-empty vector VEC."
     :arg-docs (("vec" . "Non-empty vector"))
     :returns "The last element of VEC"
     :examples ("rtail([1, 2, 3])")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "sort" :category vec-mat
     :args "(vec)"
     :desc "Elements of VEC sorted into increasing order.  Calc's canonical
ordering puts real numbers and constant intervals first, then
other kinds of numbers, then variables in alphabetical order, then
formulas and other objects.  The sort is stable."
     :arg-docs (("vec" . "Vector to sort"))
     :returns "VEC sorted into increasing order"
     :examples ("sort([2, 5, 1])")
     :expect ("[1, 2, 5]")
     :eval num :volatile nil
     :note nil)
    (:name "subscr" :category vec-mat
     :args "(mat, n, m?)"
     :desc "Element of MAT selected by 1-based subscript — the function
behind Calc's `m_i' notation and a synonym for `mrow'.  With both
indices, `subscr(mat, n, m)' picks the element at row N, column
M."
     :arg-docs (("mat" . "Matrix or vector") ("n" . "Row (or element) index") ("m" . "Optional; column index"))
     :returns "The selected element or row"
     :examples ("subscr([10, 20, 30], 2)" "subscr([[1, 2], [3, 4]], 2, 1)")
     :expect ("20" "3")
     :eval num :volatile nil
     :note nil)
    (:name "subvec" :category vec-mat
     :args "(vec, start, end?)"
     :desc "Subvector of VEC from index START up to, but not including, index
END.  A zero or negative index counts from the end of the vector;
omitting END (or passing `inf') takes everything through the last
element."
     :arg-docs (("vec" . "Vector to extract from") ("start" . "First index to take") ("end" . "Optional; first index past the range"))
     :returns "The subvector from START to END"
     :examples ("subvec([1, 2, 3, 4, 5], 2, 4)")
     :expect ("[2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "tail" :category vec-mat
     :args "(vec)"
     :desc "The non-empty vector VEC with its first element removed."
     :arg-docs (("vec" . "Non-empty vector"))
     :returns "VEC without its first element"
     :examples ("tail([1, 2, 3])")
     :expect ("[2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "tr" :category vec-mat
     :args "(mat)"
     :desc "Trace of the square matrix MAT: the sum of its diagonal
elements."
     :arg-docs (("mat" . "Square matrix"))
     :returns "The trace of MAT"
     :examples ("tr([[1, 2], [3, 4]])")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "trn" :category vec-mat
     :args "(mat)"
     :desc "Transpose of MAT.  A plain vector is treated as a row vector and
becomes a one-column matrix."
     :arg-docs (("mat" . "Matrix or plain vector"))
     :returns "The transpose of MAT"
     :examples ("trn([[1, 2], [3, 4]])")
     :expect ("[[1, 3], [2, 4]]")
     :eval num :volatile nil
     :note nil)
    (:name "unpack" :category vec-mat
     :args "(mode, thing)"
     :desc "Components of the composite object THING, as a vector.  MODE is
an integer Calc packing code selecting how THING is taken apart:
for example -4 splits an error form into value and tolerance, -1
splits a complex number, and mode 1 splits any composite object
generically.  Unlike `pack', a vector MODE is not allowed."
     :arg-docs (("mode" . "Integer packing code") ("thing" . "Composite object to take apart"))
     :returns "A vector of the components of THING"
     :examples ("unpack(-4, 3 +/- 5)" "unpack(-1, (3, 4))")
     :expect ("[3, 5]" "[3, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "unpackt" :category vec-mat
     :args "(mode, thing)"
     :desc "Like `unpack', but the result also carries the mode needed to
rebuild the original: a two-element vector of the repacking mode
and the vector of components.  The identity
`apply(pack, unpackt(n, x)) = x' always holds."
     :arg-docs (("mode" . "Integer packing code") ("thing" . "Composite object to take apart"))
     :returns "A vector [REPACK-MODE, ITEMS]"
     :examples ("unpackt(1, 3 +/- 5)")
     :expect ("[-4, [3, 5]]")
     :eval num :volatile nil
     :note nil)
    (:name "vconcat" :category vec-mat
     :args "(a, b)"
     :desc "Concatenate A and B — the function form of Calc's `|' operator.
A scalar argument is treated as a one-element vector, and a plain
vector alongside a matrix is promoted to a one-row matrix, so
mixed inputs merge without complaint."
     :arg-docs (("a" . "First operand (vector or scalar)") ("b" . "Second operand (vector or scalar)"))
     :returns "The concatenation of A and B"
     :examples ("vconcat([1, 2], [3, 4])" "vconcat(1, [2, 3])")
     :expect ("[1, 2, 3, 4]" "[1, 2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "vconcatrev" :category vec-mat
     :args "(a, b)"
     :desc "Concatenate B followed by A — `vconcat' with the argument order
reversed, including its scalar and matrix promotions."
     :arg-docs (("a" . "Operand placed second in the result") ("b" . "Operand placed first in the result"))
     :returns "The concatenation of B and A"
     :examples ("vconcatrev([1, 2], [3, 4])")
     :expect ("[3, 4, 1, 2]")
     :eval num :volatile nil
     :note nil)
    (:name "vec" :category vec-mat
     :args "(objs...)"
     :desc "Build a vector containing the arguments OBJS, in order.  The
function-call form of the `[a, b, c]' bracket notation."
     :arg-docs (("objs" . "Values to collect into a vector"))
     :returns "A vector of the arguments"
     :examples ("vec(1, 2, 3)")
     :expect ("[1, 2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "vexp" :category vec-mat
     :args "(mask, vec, filler?)"
     :desc "Expand VEC into the nonzero slots of MASK.  The result has the
length of MASK; each nonzero mask element is replaced by the next
element of VEC, and zero positions stay zero unless FILLER
supplies a replacement.  A vector FILLER is consumed element by
element, interleaving the two vectors.  If VEC runs out early,
the remaining nonzero mask elements are kept as they are."
     :arg-docs (("mask" . "Mask vector of zeros and nonzeros") ("vec" . "Vector of replacement elements") ("filler" . "Optional; value or vector used where MASK is zero"))
     :returns "A vector the same length as MASK"
     :examples ("vexp([2, 0, 3, 0, 7], [10, 20])" "vexp([2, 0, 3, 0, 7], [10, 20], 99)")
     :expect ("[10, 0, 20, 0, 7]" "[10, 99, 20, 99, 7]")
     :eval num :volatile nil
     :note nil)
    (:name "vlen" :category vec-mat
     :args "(v)"
     :desc "Number of elements in V.  A matrix counts as a vector of its
rows, so an N-by-M matrix has length N; a non-vector argument has
length 0."
     :arg-docs (("v" . "Vector, matrix, or scalar"))
     :returns "The number of elements (0 for a non-vector)"
     :examples ("vlen([1, 2, 3])")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "vmask" :category vec-mat
     :args "(mask, vec)"
     :desc "Elements of VEC in the positions where MASK is nonzero.  The two
vectors must have equal length; positions whose mask element is
zero are dropped from the result."
     :arg-docs (("mask" . "Mask vector of zeros and nonzeros") ("vec" . "Vector to filter"))
     :returns "A vector of the unmasked elements"
     :examples ("vmask([1, 0, 1, 0, 1], [1, 2, 3, 4, 5])")
     :expect ("[1, 3, 5]")
     :eval num :volatile nil
     :note nil)
    (:name "rdup" :category sets
     :args "(a)"
     :desc "Canonical set form of the vector A: the elements are sorted and
duplicates removed.  Numerically equal values such as 4 and 4.0
count as duplicates, and overlapping intervals are merged.  The
other set operations apply this normalization to their inputs
automatically, so calling it yourself is rarely necessary."
     :arg-docs (("a" . "Vector to canonicalize"))
     :returns "The set form of A: sorted, duplicates removed"
     :examples ("rdup([3, 1, 2, 3, 1])")
     :expect ("[1, 2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "vcard" :category sets
     :args "(a)"
     :desc "Number of integers in the set A.  Interval members contribute
every integer they enclose, so the result equals the length of the
vector `venum' would build — without actually building it.  The
set must be finite."
     :arg-docs (("a" . "Finite set of integers or integer intervals"))
     :returns "The count of integers in A"
     :examples ("vcard([1, 3, [5 .. 7]])")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "vcompl" :category sets
     :args "(a)"
     :desc "Complement of the set A with respect to the real numbers —
equivalent to `vdiff([-inf .. inf], a)'.  The result is expressed
as a vector of interval forms."
     :arg-docs (("a" . "Set of reals"))
     :returns "A vector of intervals covering the reals outside A"
     :examples ("vcompl([2])")
     :expect ("[[-inf .. 2), (2 .. inf]]")
     :eval num :volatile nil
     :note nil)
    (:name "vdiff" :category sets
     :args "(a, b)"
     :desc "Set difference: the elements of A that are not in B.  Both
inputs are canonicalized with `rdup' first, and removing elements
that were never in A is harmless.  `vdiff(a, b) = []' is the
standard test that A is a subset of B."
     :arg-docs (("a" . "Set to subtract from") ("b" . "Set of elements to remove"))
     :returns "The set of elements of A not in B"
     :examples ("vdiff([1, 2, 3, 4], [2, 4])")
     :expect ("[1, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "venum" :category sets
     :args "(a)"
     :desc "Explicit vector of every integer in the set A, with interval
members expanded to the integers they contain.  Only finite sets —
no `inf' or `-inf' endpoints — can be enumerated."
     :arg-docs (("a" . "Finite set of integers or integer intervals"))
     :returns "A vector listing every integer in A"
     :examples ("venum([[1 .. 3], 5])")
     :expect ("[1, 2, 3, 5]")
     :eval num :volatile nil
     :note nil)
    (:name "vfloor" :category sets
     :args "(a, always-vec?)"
     :desc "Reinterpret the set A as a set of integers.  Non-integer members
and intervals that enclose no integer are dropped, open interval
endpoints are closed, and runs of consecutive integers coalesce
into integer intervals.  A set that reduces to a single interval
is returned as a bare interval unless ALWAYS-VEC is nonzero, which
forces a vector result."
     :arg-docs (("a" . "Set of reals") ("always-vec" . "Optional; nonzero forces a vector result"))
     :returns "The integer set (a bare interval if it reduces to one)"
     :examples ("vfloor([1.5, 2, 3, 4])" "vfloor([1.5, 2, 3, 4], 1)")
     :expect ("[2 .. 4]" "[[2 .. 4]]")
     :eval num :volatile nil
     :note nil)
    (:name "vint" :category sets
     :args "(a, b)"
     :desc "Intersection of the sets A and B: the elements present in both
inputs.  Disjoint sets give the empty vector `[]'."
     :arg-docs (("a" . "First set") ("b" . "Second set"))
     :returns "The set of elements common to A and B"
     :examples ("vint([1, 2, 3, 4], [2, 4, 6])")
     :expect ("[2, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "vpack" :category sets
     :args "(a)"
     :desc "Binary encoding of a set of nonnegative integers: bit K of the
result is 1 exactly when K is a member of A.  The input is read as
an integer set in the sense of `vfloor' and may include `inf'
(producing a negative result), but no negative members.  Beware
that modest-looking members make huge integers: `vpack([100])' is
2^100, a 31-digit number."
     :arg-docs (("a" . "Set of nonnegative integers (may include `inf')"))
     :returns "An integer encoding the set in binary"
     :examples ("vpack([[0 .. 1], 6])")
     :expect ("67")
     :eval num :volatile nil
     :note nil)
    (:name "vspan" :category sets
     :args "(a)"
     :desc "Smallest single interval that covers every element of the set A,
running from the least element to the greatest.  The empty set
gives the empty interval `[0 .. 0)'."
     :arg-docs (("a" . "Set of reals"))
     :returns "A single interval covering all of A"
     :examples ("vspan([2, 5, 9])")
     :expect ("[2 .. 9]")
     :eval num :volatile nil
     :note nil)
    (:name "vunion" :category sets
     :args "(a, b)"
     :desc "Union of the sets A and B: every element that appears in either
input, in canonical sorted-set form with duplicates removed."
     :arg-docs (("a" . "First set") ("b" . "Second set"))
     :returns "The set of elements in A or B"
     :examples ("vunion([1, 3], [2, 3])")
     :expect ("[1, 2, 3]")
     :eval num :volatile nil
     :note nil)
    (:name "vunpack" :category sets
     :args "(a, w?)"
     :desc "Set described by the bits of the integer A: bit K being set means
the integer K is a member.  Runs of adjacent set bits come back as
integer intervals.  A negative A denotes a semi-infinite set
reaching `inf'.  With W, A is first clipped to a W-bit word."
     :arg-docs (("a" . "Integer whose binary bits describe the set") ("w" . "Optional; word size to clip A to first"))
     :returns "The set in vector/interval notation"
     :examples ("vunpack(67)" "vunpack(-4)")
     :expect ("[[0 .. 1], 6]" "[2 .. inf)")
     :eval num :volatile nil
     :note nil)
    (:name "vxor" :category sets
     :args "(a, b)"
     :desc "Symmetric difference of the sets A and B: the elements that
appear in exactly one of the two inputs.  Members common to both
cancel out."
     :arg-docs (("a" . "First set") ("b" . "Second set"))
     :returns "The set of elements in exactly one of A and B"
     :examples ("vxor([1, 2, 3], [2, 3, 4])")
     :expect ("[1, 4]")
     :eval num :volatile nil
     :note nil)
    (:name "accum" :category map-reduce
     :args "(func, vec)"
     :desc "Left-to-right accumulation of the binary function FUNC over VEC.
This performs the same fold as `reduce', but keeps every
intermediate value: accumulating `add' over [a, b, c] gives
[a, a + b, a + b + c]."
     :arg-docs (("func" . "Binary function to accumulate, by name") ("vec" . "Vector of values"))
     :returns "A vector of the running reduction results"
     :examples ("accum(add, [1, 2, 3, 4])")
     :expect ("[1, 3, 6, 10]")
     :eval sym :volatile nil
     :note nil)
    (:name "afixp" :category map-reduce
     :args "(func, base, iters?, tol?)"
     :desc "Accumulating version of `fixp'.  FUNC is applied repeatedly
starting from BASE, and the whole trajectory is returned: the
first element is BASE itself, the last is the value `fixp' would
have returned.  ITERS caps the number of steps; with TOL given,
iteration stops once successive values differ by at most TOL."
     :arg-docs (("func" . "Function to iterate, by name") ("base" . "Starting value") ("iters" . "Optional; maximum number of steps, default unlimited") ("tol" . "Optional; convergence tolerance on successive results"))
     :returns "A vector of all iterates, from BASE to the final value"
     :examples ("afixp(cos, 1.0, 4)")
     :expect ("[1., 0.540302305868, 0.857553215846, 0.654289790498, 0.793480358743]")
     :eval sym :volatile nil
     :note nil)
    (:name "anest" :category map-reduce
     :args "(func, base, iters)"
     :desc "Accumulating version of `nest'.  FUNC is applied to BASE exactly
ITERS times, and the result is the vector of all ITERS+1 values
[BASE, FUNC(BASE), FUNC(FUNC(BASE)), ...].  A negative ITERS uses
the inverse of FUNC when Calc knows one."
     :arg-docs (("func" . "Function to iterate, by name") ("base" . "Starting value") ("iters" . "Number of applications; an integer"))
     :returns "A vector of BASE and its ITERS successive images"
     :examples ("anest(sqr, 2, 3)")
     :expect ("[2, 4, 16, 256]")
     :eval sym :volatile nil
     :note nil)
    (:name "apply" :category map-reduce
     :args "(f, args)"
     :desc "Build and evaluate a call to F with the elements of the vector
ARGS as its arguments: apply(f, [x, y]) becomes f(x, y).  F is a
function named by a bare word such as `gcd'; operators go by their
word names `add', `sub', `mul', `div', `pow', `neg', `mod' and
`vconcat'."
     :arg-docs (("f" . "Function to call, by name") ("args" . "Vector holding the arguments"))
     :returns "The result of calling F with the vector's elements"
     :examples ("apply(gcd, [12, 18])")
     :expect ("6")
     :eval sym :volatile nil
     :note nil)
    (:name "call" :category map-reduce
     :args "(f, args...)"
     :desc "Build and evaluate a call to F, passing the remaining arguments
directly: call(f, x, y) becomes f(x, y).  Identical to `apply'
except that the arguments are listed individually instead of
packed into a vector."
     :arg-docs (("f" . "Function to call, by name") ("args" . "Arguments to pass to F"))
     :returns "The result of calling F on ARGS"
     :examples ("call(gcd, 12, 18)")
     :expect ("6")
     :eval sym :volatile nil
     :note nil)
    (:name "fixp" :category map-reduce
     :args "(func, base, iters?, tol?)"
     :desc "Apply FUNC repeatedly starting from BASE until two successive
results agree to the current precision, i.e. until a fixed point
is reached.  ITERS bounds the number of steps; with TOL given,
every iterate must be numeric and iteration stops when successive
values differ by at most TOL.  Nothing stops a non-converging
FUNC, so supply ITERS when convergence is not certain."
     :arg-docs (("func" . "Function to iterate, by name") ("base" . "Starting value") ("iters" . "Optional; maximum number of steps, default unlimited") ("tol" . "Optional; convergence tolerance on successive results"))
     :returns "The fixed point, or the last iterate if ITERS ran out"
     :examples ("fixp(cos, 1.0)")
     :expect ("0.739085133215")
     :eval sym :volatile nil
     :note "Calc's nameless-function notation `<...>' is rejected by the
wrapper's validator (unknown function `lambda'), so FUNC must be a
named function, built-in or user-defined.")
    (:name "inner" :category map-reduce
     :args "(mul-func, add-func, a, b)"
     :desc "Generalized inner product of A and B.  Element (r, c) of the
result is formed by mapping MUL-FUNC across row r of A and column
c of B, then reducing with ADD-FUNC; with `mul' and `add' this is
exactly the standard matrix product.  Vector-matrix and
vector-vector combinations work as for ordinary multiplication."
     :arg-docs (("mul-func" . "Multiplicative binary function, by name") ("add-func" . "Additive binary function, by name") ("a" . "Left vector or matrix") ("b" . "Right vector or matrix"))
     :returns "The generalized product matrix, vector, or scalar"
     :examples ("inner(mul, add, [[1, 2], [3, 4]], [[5, 6], [7, 8]])")
     :expect ("[[19, 22], [43, 50]]")
     :eval sym :volatile nil
     :note nil)
    (:name "map" :category map-reduce
     :args "(func, args...)"
     :desc "Apply the function FUNC to each element of a vector, collecting
the results.  With several vectors, FUNC is applied to
corresponding elements of each; a non-vector argument is held
constant across the mapping.  A matrix argument is mapped over
every element."
     :arg-docs (("func" . "Function to apply, by name") ("args" . "One or more vectors of arguments"))
     :returns "A vector of FUNC applied elementwise"
     :examples ("map(sqrt, [1, 4, 9])")
     :expect ("[1, 2, 3]")
     :eval sym :volatile nil
     :note nil)
    (:name "mapa" :category map-reduce
     :args "(func, arg)"
     :desc "Map FUNC ``across'' the matrix ARG: the elements of each row
become the arguments of one FUNC call, so a two-row matrix gives
the 2-vector of FUNC applied to each row's elements in turn."
     :arg-docs (("func" . "Function to apply to each row's elements, by name") ("arg" . "Matrix of arguments"))
     :returns "A vector with one result per row of ARG"
     :examples ("mapa(add, [[1, 2], [3, 4]])")
     :expect ("[3, 7]")
     :eval sym :volatile nil
     :note "ARG must be an actual matrix; applied to a plain vector, `mapa'
is left unevaluated.  This is an older interface kept for
compatibility; `map' and `mapr' cover the common cases.")
    (:name "mapc" :category map-reduce
     :args "(func, args...)"
     :desc "Map by columns: each column of a matrix argument is handed to
FUNC as a single vector, and the results are reassembled
column-wise (transpose, map by rows, transpose back).  Reversing
each two-element column of a 2x3 matrix therefore swaps its rows.
Non-matrix arguments are unaffected by the column treatment and
map elementwise."
     :arg-docs (("func" . "Function to apply to each column, by name") ("args" . "One or more matrices (or vectors) of arguments"))
     :returns "The result of FUNC applied to each column"
     :examples ("mapc(rev, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[[4, 5, 6], [1, 2, 3]]")
     :eval sym :volatile nil
     :note nil)
    (:name "mapd" :category map-reduce
     :args "(func, arg)"
     :desc "Map FUNC ``down'' the matrix ARG: the elements of each column
become the arguments of one FUNC call, so mapd(add, m) yields the
vector of column sums of `m'."
     :arg-docs (("func" . "Function to apply to each column's elements, by name") ("arg" . "Matrix of arguments"))
     :returns "A vector with one result per column of ARG"
     :examples ("mapd(add, [[1, 2], [3, 4]])")
     :expect ("[4, 6]")
     :eval sym :volatile nil
     :note "ARG must be an actual matrix; applied to a plain vector, `mapd'
is left unevaluated.  This is an older interface kept for
compatibility; `map' and `mapc' cover the common cases.")
    (:name "mapeq" :category map-reduce
     :args "(func, args...)"
     :desc "Apply FUNC to both sides of an equation or inequality among
ARGS; additional scalar ARGS are passed along to FUNC on both
sides.  Multiplying or dividing an inequality by a negative value
reverses its direction automatically.  No other correctness
adjustments are made: mapping a decreasing function keeps the
original direction even when that is not mathematically sound."
     :arg-docs (("func" . "Function to apply to both sides, by name") ("args" . "Equations or inequalities, plus any constant arguments"))
     :returns "A new equation or inequality of the mapped sides"
     :examples ("mapeq(add, x = y + 1, 6)" "mapeq(mul, x < y, -1)")
     :expect ("x + 6 = y + 7" "-x > -y")
     :eval sym :volatile nil
     :note nil)
    (:name "mapeqp" :category map-reduce
     :args "(func, args...)"
     :desc "Plain variant of `mapeq': FUNC is applied to both sides without
ever reversing an inequality, even where multiplying by a negative
value would normally flip it.  Occasionally useful for repairing
an inequality that was already stated backwards."
     :arg-docs (("func" . "Function to apply to both sides, by name") ("args" . "Equations or inequalities, plus any constant arguments"))
     :returns "A new equation or inequality, direction untouched"
     :examples ("mapeqp(mul, x < y, -1)")
     :expect ("-x < -y")
     :eval sym :volatile nil
     :note nil)
    (:name "mapeqr" :category map-reduce
     :args "(func, args...)"
     :desc "Reversing variant of `mapeq': the direction of the inequality is
always flipped while FUNC is applied to both sides.  Use it when
FUNC is known to be decreasing on the domain of interest, such as
mapping `cos' over small positive angles."
     :arg-docs (("func" . "Function to apply to both sides, by name") ("args" . "Equations or inequalities, plus any constant arguments"))
     :returns "A new equation or inequality with reversed direction"
     :examples ("mapeqr(sqrt, x < y)")
     :expect ("sqrt(x) > sqrt(y)")
     :eval sym :volatile nil
     :note nil)
    (:name "mapr" :category map-reduce
     :args "(func, args...)"
     :desc "Map by rows: each row of a matrix argument is handed to FUNC as
a single vector and the results are collected.  Use this when a
matrix really represents a list of row objects (strings, sets,
lists) that FUNC should see whole rather than elementwise."
     :arg-docs (("func" . "Function to apply to each row, by name") ("args" . "One or more matrices (or vectors) of arguments"))
     :returns "A vector of FUNC applied to each row"
     :examples ("mapr(rev, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[[3, 2, 1], [6, 5, 4]]")
     :eval sym :volatile nil
     :note nil)
    (:name "nest" :category map-reduce
     :args "(func, base, iters)"
     :desc "Apply FUNC to BASE nested ITERS times: nest(f, a, 3) computes
f(f(f(a))).  ITERS may be negative if Calc knows an inverse for
FUNC; nest(sin, a, -2) gives arcsin(arcsin(a))."
     :arg-docs (("func" . "Function to iterate, by name") ("base" . "Starting value") ("iters" . "Number of applications; an integer"))
     :returns "FUNC composed with itself ITERS times, applied to BASE"
     :examples ("nest(sqr, 2, 3)")
     :expect ("256")
     :eval sym :volatile nil
     :note nil)
    (:name "outer" :category map-reduce
     :args "(func, a, b)"
     :desc "Generalized outer product: the binary FUNC is applied to every
pair of one element from A and one from B, producing a matrix
whose (r, c) entry is FUNC applied to element r of A and element c
of B.  With `mul' this is the ordinary outer product, a
multiplication table."
     :arg-docs (("func" . "Binary function to apply to the pairs, by name") ("a" . "Vector supplying the row elements") ("b" . "Vector supplying the column elements"))
     :returns "A matrix of FUNC over all element pairs"
     :examples ("outer(mul, [1, 2], [10, 20, 30])")
     :expect ("[[10, 20, 30], [20, 40, 60]]")
     :eval sym :volatile nil
     :note nil)
    (:name "raccum" :category map-reduce
     :args "(func, vec)"
     :desc "Right-to-left accumulation of the binary function FUNC over VEC.
Element i of the result is the right fold (as by `rreduce') of the
elements from position i to the end, so the first entry is the
full reduction and the last is the final element unchanged."
     :arg-docs (("func" . "Binary function to accumulate, by name") ("vec" . "Vector of values"))
     :returns "A vector of right-fold results for each suffix of VEC"
     :examples ("raccum(add, [1, 2, 3, 4])")
     :expect ("[10, 9, 7, 4]")
     :eval sym :volatile nil
     :note nil)
    (:name "reduce" :category map-reduce
     :args "(func, vec)"
     :desc "Fold the binary function FUNC left-to-right across the elements
of VEC: reducing `f' over [a, b, c, d] computes f(f(f(a, b), c),
d).  A matrix is reduced over all its elements in row-major order.
Operators are named by word: `add', `mul', `max', and so on."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Vector or matrix of values"))
     :returns "The single accumulated result"
     :examples ("reduce(add, [1, 2, 3, 4])")
     :expect ("10")
     :eval sym :volatile nil
     :note nil)
    (:name "reducea" :category map-reduce
     :args "(func, vec)"
     :desc "Reduce ``across'': fold FUNC separately over each row of the
matrix VEC and collect the row results into a vector.  For a plain
vector this is the same as `reduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "A vector with one reduction result per row"
     :examples ("reducea(add, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[6, 15]")
     :eval sym :volatile nil
     :note nil)
    (:name "reducec" :category map-reduce
     :args "(func, vec)"
     :desc "Fold FUNC over the columns of the matrix VEC taken as whole
vectors, i.e. `reducer' applied to the transpose.  With `add' the
column vectors sum elementwise, which coincides with the row
totals of `reducea'; a function like `mul' instead combines
successive columns by dot products.  For a plain vector this is
the same as `reduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "The result of folding the column vectors together"
     :examples ("reducec(add, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[6, 15]")
     :eval sym :volatile nil
     :note nil)
    (:name "reduced" :category map-reduce
     :args "(func, vec)"
     :desc "Reduce ``down'': fold FUNC separately over each column of the
matrix VEC and collect the column results, so reducing `add' down
a matrix yields its vector of column sums.  For a plain vector
this is the same as `reduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "A vector with one reduction result per column"
     :examples ("reduced(add, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[5, 7, 9]")
     :eval sym :volatile nil
     :note nil)
    (:name "reducer" :category map-reduce
     :args "(func, vec)"
     :desc "Reduce ``by rows'': fold FUNC over the rows of the matrix VEC
taken as whole vectors.  With `add' this matches `reduced', since
adding row vectors adds their elements, but with `mul' the rows
combine by dot products.  For a plain vector this is the same as
`reduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "The result of folding the row vectors together"
     :examples ("reducer(mul, [[1, 2, 3], [4, 5, 6]])")
     :expect ("32")
     :eval sym :volatile nil
     :note nil)
    (:name "rreduce" :category map-reduce
     :args "(func, vec)"
     :desc "Fold the binary function FUNC right-to-left across VEC: reducing
`f' over [a, b, c, d] computes f(a, f(b, f(c, d))).  With `sub'
this produces the alternating sum a - b + c - d, a pattern common
in power-series work."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Vector or matrix of values"))
     :returns "The single accumulated result"
     :examples ("rreduce(sub, [1, 2, 3, 4])")
     :expect ("-2")
     :eval sym :volatile nil
     :note nil)
    (:name "rreducea" :category map-reduce
     :args "(func, vec)"
     :desc "Right-to-left `reducea': fold FUNC through each row of the
matrix VEC from its last element back to its first, collecting one
result per row.  For a plain vector this is the same as
`rreduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "A vector with one right-fold result per row"
     :examples ("rreducea(sub, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[2, 5]")
     :eval sym :volatile nil
     :note nil)
    (:name "rreducec" :category map-reduce
     :args "(func, vec)"
     :desc "Right-to-left `reducec': fold FUNC through the columns of the
matrix VEC taken as whole vectors, from the last column back to
the first (equivalently, `rreducer' on the transpose).  For a
plain vector this is the same as `rreduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "The result of right-folding the column vectors"
     :examples ("rreducec(sub, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[2, 5]")
     :eval sym :volatile nil
     :note nil)
    (:name "rreduced" :category map-reduce
     :args "(func, vec)"
     :desc "Right-to-left `reduced': fold FUNC through each column of the
matrix VEC from the bottom element up, collecting one result per
column.  For a plain vector this is the same as `rreduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "A vector with one right-fold result per column"
     :examples ("rreduced(sub, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[-3, -3, -3]")
     :eval sym :volatile nil
     :note nil)
    (:name "rreducer" :category map-reduce
     :args "(func, vec)"
     :desc "Right-to-left `reducer': fold FUNC through the rows of the
matrix VEC taken as whole vectors, last row first.  For a plain
vector this is the same as `rreduce'."
     :arg-docs (("func" . "Binary function to fold, by name") ("vec" . "Matrix (or vector) of values"))
     :returns "The result of right-folding the row vectors"
     :examples ("rreducer(sub, [[1, 2, 3], [4, 5, 6]])")
     :expect ("[-3, -3, -3]")
     :eval sym :volatile nil
     :note nil)
    (:name "agmean" :category statistics
     :args "(a, b)"
     :desc "Arithmetic-geometric mean of A and B.  The two values are
repeatedly replaced by their arithmetic mean and their geometric
mean until the pair converges to a common limit."
     :arg-docs (("a" . "First value") ("b" . "Second value"))
     :returns "The common limit of the arithmetic/geometric iteration"
     :examples ("agmean(2, 4)")
     :expect ("2.91358206209")
     :eval num :volatile nil
     :note nil)
    (:name "rms" :category statistics
     :args "(a)"
     :desc "Root-mean-square of the data values in A: the square root of the
mean of the squares of the values."
     :arg-docs (("a" . "Vector of data values"))
     :returns "The RMS of the values"
     :examples ("rms([3, 4])")
     :expect ("3.53553390593")
     :eval num :volatile nil
     :note nil)
    (:name "vcorr" :category statistics
     :args "(vec1, vec2?)"
     :desc "Linear correlation coefficient of two data vectors: their
covariance divided by the product of their standard deviations.
Sample versus population statistics make no difference here.  With
VEC2 omitted, VEC1 must be an Nx2 matrix of data pairs."
     :arg-docs (("vec1" . "First data vector, or an Nx2 matrix of pairs") ("vec2" . "Optional; second data vector"))
     :returns "The correlation coefficient, between -1 and 1"
     :examples ("vcorr([1, 2, 3], [2, 4, 6])")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "vcount" :category statistics
     :args "(vecs...)"
     :desc "Count of the data values across all of VECS, descending into
nested vectors; a bare number counts as one value.  With a single
flat vector this is simply its length."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The number of data values"
     :examples ("vcount(1, [2, 3], [[4, 5], [6]])")
     :expect ("6")
     :eval num :volatile nil
     :note nil)
    (:name "vcov" :category statistics
     :args "(vec1, vec2?)"
     :desc "Sample covariance of two data vectors, dividing by N-1: the sum
of products of the deviations of paired elements from their
respective means.  With VEC2 omitted, VEC1 must be an Nx2 matrix
of data pairs.  Error-form inputs contribute with their errors as
weights."
     :arg-docs (("vec1" . "First data vector, or an Nx2 matrix of pairs") ("vec2" . "Optional; second data vector"))
     :returns "The sample covariance"
     :examples ("vcov([1, 2, 3], [2, 4, 6])")
     :expect ("2")
     :eval num :volatile nil
     :note nil)
    (:name "vflat" :category statistics
     :args "(vecs...)"
     :desc "Flatten all of VECS into a single vector, interpreting the
arguments the same way as the other statistical functions: nested
vectors are descended and bare numbers are included as single
values."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "A flat vector of all the data values"
     :examples ("vflat(1, [2, [3, 4]], 5)")
     :expect ("[1, 2, 3, 4, 5]")
     :eval num :volatile nil
     :note nil)
    (:name "vgmean" :category statistics
     :args "(vecs...)"
     :desc "Geometric mean of the data values: the Nth root of the product
of the N values, equivalently the exponential of the mean of their
logarithms."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The geometric mean"
     :examples ("vgmean([1, 3, 9])")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "vhmean" :category statistics
     :args "(vecs...)"
     :desc "Harmonic mean of the data values: the reciprocal of the
arithmetic mean of the reciprocals of the values."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The harmonic mean"
     :examples ("vhmean([1, 2, 4])")
     :expect ("1.71428571429")
     :eval num :volatile nil
     :note nil)
    (:name "vmax" :category statistics
     :args "(vecs...)"
     :desc "Maximum of the data values in VECS, descending nested vectors.
An interval argument yields the largest value in the interval; an
interval with integer limits is treated as the integers it
contains, so the maximum of `[2 .. 6)' is 5."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The largest data value"
     :examples ("vmax([3, 1, 4, 1, 5])")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "vmean" :category statistics
     :args "(vecs...)"
     :desc "Arithmetic mean of the data values.  Error-form inputs combine
as a weighted mean with weights 1/sigma^2; a mixture of plain
numbers and error forms ignores the error forms entirely, since a
plain number has effectively infinite weight.  The mean of a
single error form is its mean part; of an interval, the mean of
its two endpoints."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The mean of the values"
     :examples ("vmean([1, 2, 3, 4])")
     :expect ("2.5")
     :eval num :volatile nil
     :note nil)
    (:name "vmeane" :category statistics
     :args "(vecs...)"
     :desc "Mean of the data values expressed as an error form that includes
the estimated error of the mean.  For plain numbers the error is
the sample standard deviation divided by the square root of the
count; for error-form inputs the variance of the mean is the
reciprocal of the sum of the reciprocals of the input variances."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "An error form, the mean plus or minus its estimated error"
     :examples ("vmeane([10, 20, 30, 40])")
     :expect ("25 +/- 6.45497224368")
     :eval num :volatile nil
     :note nil)
    (:name "vmedian" :category statistics
     :args "(vecs...)"
     :desc "Median of the data values: the middle value after sorting, or
the average of the two middle values when the count is even.  All
values must be real numbers; variables are rejected even inside
vectors, and the error parts of error forms are ignored."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The median of the values"
     :examples ("vmedian([5, 1, 3, 4])")
     :expect ("3.5")
     :eval num :volatile nil
     :note nil)
    (:name "vmin" :category statistics
     :args "(vecs...)"
     :desc "Minimum of the data values in VECS, descending nested vectors.
An interval argument yields the smallest value in the interval,
with integer-limit intervals treated as the integers they contain."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The smallest data value"
     :examples ("vmin([3, 1, 4, 1, 5])")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "vpcov" :category statistics
     :args "(vec1, vec2?)"
     :desc "Population covariance of two data vectors: computed like `vcov'
but dividing by N instead of N-1.  With VEC2 omitted, VEC1 must be
an Nx2 matrix of data pairs."
     :arg-docs (("vec1" . "First data vector, or an Nx2 matrix of pairs") ("vec2" . "Optional; second data vector"))
     :returns "The population covariance"
     :examples ("vpcov([1, 2, 3], [2, 4, 6])")
     :expect ("1.33333333333")
     :eval num :volatile nil
     :note nil)
    (:name "vprod" :category statistics
     :args "(vecs...)"
     :desc "Product of all the data values in VECS, descending nested
vectors.  On a single flat vector this is the same as reducing
`mul' over it."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The product of the values"
     :examples ("vprod([1, 2, 3, 4])")
     :expect ("24")
     :eval num :volatile nil
     :note nil)
    (:name "vpsdev" :category statistics
     :args "(vecs...)"
     :desc "Population standard deviation of the data values, dividing the
summed squared deviations by N.  Use it when the data is the
entire population rather than a sample of one.  For error forms
and continuous intervals it behaves like `vsdev'; an integer
interval is treated as the vector of its integers."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The population standard deviation"
     :examples ("vpsdev([1, 2, 3, 4])")
     :expect ("1.11803398875")
     :eval num :volatile nil
     :note nil)
    (:name "vpvar" :category statistics
     :args "(vecs...)"
     :desc "Population variance of the data values: the square of `vpsdev',
i.e. the mean squared deviation from the mean with divisor N."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The population variance"
     :examples ("vpvar([1, 2, 3, 4])")
     :expect ("1.25")
     :eval num :volatile nil
     :note nil)
    (:name "vsdev" :category statistics
     :args "(vecs...)"
     :desc "Sample standard deviation of the data values, dividing the
summed squared deviations from the mean by N-1.  Error-form inputs
are weighted by their errors, as for `vmean'.  The standard
deviation of a single error form is its error part; of a
continuous interval, its width divided by sqrt(12)."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The sample standard deviation"
     :examples ("vsdev([1, 2, 3, 4])")
     :expect ("1.29099444874")
     :eval num :volatile nil
     :note nil)
    (:name "vsum" :category statistics
     :args "(vecs...)"
     :desc "Sum of all the data values in VECS, descending nested vectors.
On a single flat vector this is the same as reducing `add' over
it."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The sum of the values"
     :examples ("vsum([1, 2, 3, 4])")
     :expect ("10")
     :eval num :volatile nil
     :note nil)
    (:name "vvar" :category statistics
     :args "(vecs...)"
     :desc "Sample variance of the data values: the square of `vsdev',
dividing the summed squared deviations from the mean by N-1.  Also
applies to distributions, i.e. error forms and intervals."
     :arg-docs (("vecs" . "Data values: numbers, vectors, or nested vectors"))
     :returns "The sample variance"
     :examples ("vvar([1, 2, 3, 4])")
     :expect ("1.66666666667")
     :eval num :volatile nil
     :note nil)
    (:name "bern" :category special
     :args "(n, x?)"
     :desc "The Nth Bernoulli number, computed exactly as a rational.  With X,
the Nth Bernoulli polynomial evaluated at X instead; a rational X
keeps the result exact.  Odd N greater than 1 gives zero."
     :arg-docs (("n" . "Index of the Bernoulli number or polynomial (nonnegative integer)") ("x" . "Optional; evaluation point for the Bernoulli polynomial"))
     :returns "The Bernoulli number, or the polynomial value at X"
     :examples ("bern(6)" "bern(4, 1:2)")
     :expect ("1:42" "7:240")
     :eval num :volatile nil
     :note nil)
    (:name "besJ" :category special
     :args "(v, x)"
     :desc "Bessel function of the first kind, of order V, evaluated at X.
The order V is typically an integer but need not be.  Calc computes
Bessel functions to only about 8 significant digits regardless of
the display precision, so do not lean on the trailing digits."
     :arg-docs (("v" . "Order of the Bessel function") ("x" . "Point at which to evaluate"))
     :returns "J(V,X), accurate to roughly 8 significant digits"
     :examples ("besJ(0, 2)")
     :expect ("0.22389078")
     :eval num :volatile nil
     :note nil)
    (:name "besY" :category special
     :args "(v, x)"
     :desc "Bessel function of the second kind, of order V, evaluated at X.
Like `besJ', the implementation carries only about 8 significant
digits of accuracy, and it may be slow for awkward arguments."
     :arg-docs (("v" . "Order of the Bessel function") ("x" . "Point at which to evaluate"))
     :returns "Y(V,X), accurate to roughly 8 significant digits"
     :examples ("besY(0, 2)")
     :expect ("0.51037567")
     :eval num :volatile nil
     :note nil)
    (:name "beta" :category special
     :args "(a, b)"
     :desc "The complete Euler beta function, equal to
`gamma(a) gamma(b) / gamma(a+b)', or equivalently the integral of
`t^(a-1) (1-t)^(b-1)' for `t' from 0 to 1.  The result is computed
in floating point even for integer arguments."
     :arg-docs (("a" . "First shape argument") ("b" . "Second shape argument"))
     :returns "B(A,B) as a float"
     :examples ("beta(3, 4)")
     :expect ("0.0166666666667")
     :eval num :volatile nil
     :note "The example value is 1/60, i.e. `2! 3! / 6!', but it is returned
as a float rather than an exact rational.")
    (:name "betaB" :category special
     :args "(x, a, b)"
     :desc "Unnormalized incomplete beta function: the integral of
`t^(a-1) (1-t)^(b-1)' for `t' from 0 to X, with X between 0 and 1.
At X = 1 it equals the complete `beta(a,b)'.  Use `betaI' for the
version normalized to run from 0 to 1."
     :arg-docs (("x" . "Upper limit of integration, between 0 and 1") ("a" . "First shape argument") ("b" . "Second shape argument"))
     :returns "The unnormalized incomplete beta integral"
     :examples ("betaB(0.5, 2, 3)")
     :expect ("0.0572916666668")
     :eval num :volatile nil
     :note nil)
    (:name "betaI" :category special
     :args "(x, a, b)"
     :desc "Regularized incomplete beta function: the `betaB' integral
divided by the complete `beta(a,b)', so it rises from 0 at X = 0 to
1 at X = 1.  This is the CDF of the beta distribution, and it is
the kernel behind the binomial, F and Student's t tail functions."
     :arg-docs (("x" . "Upper limit of integration, between 0 and 1") ("a" . "First shape argument") ("b" . "Second shape argument"))
     :returns "I(X,A,B), between 0 and 1"
     :examples ("betaI(0.5, 2, 3)")
     :expect ("0.687500000002")
     :eval num :volatile nil
     :note "The exact value of the example is 11/16 = 0.6875; the trailing
digits are round-off from the numerical integration.")
    (:name "erf" :category special
     :args "(x)"
     :desc "The error function: `2/sqrt(pi)' times the integral of
`exp(-t^2)' from 0 to X.  It is odd in X and satisfies
`erf(x) + erfc(x) = 1'.  Complex arguments are accepted."
     :arg-docs (("x" . "Upper limit of the error-function integral"))
     :returns "erf(X), between -1 and 1 for real X"
     :examples ("erf(1)")
     :expect ("0.842700792945")
     :eval num :volatile nil
     :note nil)
    (:name "erfc" :category special
     :args "(x)"
     :desc "The complementary error function: the `erf' integral taken from
X to infinity instead, so `erfc(x) = 1 - erf(x)'.  This is the form
that appears in upper tails of the normal distribution."
     :arg-docs (("x" . "Lower limit of the complementary integral"))
     :returns "erfc(X) = 1 - erf(X)"
     :examples ("erfc(1)")
     :expect ("0.157299207052")
     :eval num :volatile nil
     :note nil)
    (:name "euler" :category special
     :args "(n, x?)"
     :desc "The Nth Euler number.  With X, the Nth Euler polynomial
evaluated at X instead.  Unlike `bern', the computation runs in
floating point: integer Euler numbers come back as floats and can
carry visible round-off (`euler(6)' displays as -60.9999999999
rather than -61)."
     :arg-docs (("n" . "Index of the Euler number or polynomial (nonnegative integer)") ("x" . "Optional; evaluation point for the Euler polynomial"))
     :returns "The Euler number, or the polynomial value at X, as a float"
     :examples ("euler(4)" "euler(2, 0.25)")
     :expect ("5." "-0.1875")
     :eval num :volatile nil
     :note "Odd-index Euler numbers are zero.  The second example is the
Euler polynomial `x^2 - x' at 0.25, giving -3/16.")
    (:name "gamma" :category special
     :args "(x)"
     :desc "The Euler gamma function.  For a positive integer X it reduces
to the factorial `fact(x-1)'; general real and complex arguments
are supported.  `gamma(0.5)' is `sqrt(pi)'."
     :arg-docs (("x" . "Point at which to evaluate the gamma function"))
     :returns "gamma(X)"
     :examples ("gamma(5)" "gamma(0.5)")
     :expect ("24" "1.77245385091")
     :eval num :volatile nil
     :note nil)
    (:name "gammag" :category special
     :args "(a, x)"
     :desc "Lower incomplete gamma function (lower-case gamma): the integral
of `t^(a-1) exp(-t)' for `t' from 0 to X, with no normalization.
It grows from 0 toward the complete `gamma(a)' as X increases, and
`gammag(a,x) + gammaG(a,x) = gamma(a)'."
     :arg-docs (("a" . "Shape argument of the incomplete gamma integral") ("x" . "Upper limit of integration"))
     :returns "The lower incomplete gamma integral"
     :examples ("gammag(3, 1)")
     :expect ("0.160602794143")
     :eval num :volatile nil
     :note "Compare `gammaG(3, 1)': the two example values sum to
`gamma(3)' = 2.")
    (:name "gammaG" :category special
     :args "(a, x)"
     :desc "Upper incomplete gamma function (capital Gamma): the integral of
`t^(a-1) exp(-t)' for `t' from X to infinity, with no
normalization.  It is the complement of `gammag'; the two sum to
the complete `gamma(a)'."
     :arg-docs (("a" . "Shape argument of the incomplete gamma integral") ("x" . "Lower limit of integration"))
     :returns "The upper incomplete gamma integral"
     :examples ("gammaG(3, 1)")
     :expect ("1.83939720586")
     :eval num :volatile nil
     :note nil)
    (:name "gammaP" :category special
     :args "(a, x)"
     :desc "Regularized lower incomplete gamma function:
`gammag(a,x) / gamma(a)', rising from 0 at X = 0 toward 1 as X
grows.  This is the CDF of the gamma distribution, and the
chi-square and Poisson tail functions are built on it."
     :arg-docs (("a" . "Shape argument of the incomplete gamma integral") ("x" . "Upper limit of integration"))
     :returns "P(A,X), between 0 and 1"
     :examples ("gammaP(3, 1)")
     :expect ("0.080301397071")
     :eval num :volatile nil
     :note nil)
    (:name "gammaQ" :category special
     :args "(a, x)"
     :desc "Regularized upper incomplete gamma function
`Q(a,x) = 1 - P(a,x)', equal to `gammaG(a,x) / gamma(a)'.  It falls
from 1 at X = 0 toward 0 as X grows; the chi-square upper tail
`utpc' is a thin wrapper around it."
     :arg-docs (("a" . "Shape argument of the incomplete gamma integral") ("x" . "Lower limit of integration"))
     :returns "Q(A,X), between 0 and 1"
     :examples ("gammaQ(3, 1)")
     :expect ("0.919698602929")
     :eval num :volatile nil
     :note nil)
    (:name "ltpb" :category distributions
     :args "(x, n, p)"
     :desc "Lower tail of the binomial distribution: the probability of
fewer than X successes in N independent trials, each succeeding
with probability P.  The bound is exclusive - outcomes 0 through
X-1 are summed - so `ltpb(x,n,p) + utpb(x,n,p) = 1'."
     :arg-docs (("x" . "Success-count cutoff (itself excluded from the sum)") ("n" . "Number of trials") ("p" . "Probability of success on each trial"))
     :returns "The probability of fewer than X successes"
     :examples ("ltpb(3, 10, 0.5)")
     :expect ("0.054687500003")
     :eval num :volatile nil
     :note "The example is the chance of at most 2 heads in 10 fair coin
flips; the exact value is 56/1024 = 0.0546875.")
    (:name "ltpc" :category distributions
     :args "(chisq, v)"
     :desc "Lower tail of the chi-square distribution with V degrees of
freedom: the probability that the statistic is at most CHISQ.
Implemented as `gammaP(v/2, chisq/2)'.  With 2 degrees of freedom
the CDF is `1 - exp(-chisq/2)', which the example illustrates."
     :arg-docs (("chisq" . "Value of the chi-square statistic") ("v" . "Degrees of freedom"))
     :returns "The probability of a statistic at most CHISQ"
     :examples ("ltpc(2, 2)")
     :expect ("0.632120558829")
     :eval num :volatile nil
     :note nil)
    (:name "ltpf" :category distributions
     :args "(f, v1, v2)"
     :desc "Lower tail of the F distribution with V1 and V2 degrees of
freedom in the numerator and denominator.  When V1 = V2 the median
sits exactly at F = 1, so the example evaluates to one half (up to
round-off)."
     :arg-docs (("f" . "Value of the F statistic") ("v1" . "Numerator degrees of freedom") ("v2" . "Denominator degrees of freedom"))
     :returns "The probability of a statistic at most F"
     :examples ("ltpf(1, 5, 5)")
     :expect ("0.499999999999")
     :eval num :volatile nil
     :note nil)
    (:name "ltpn" :category distributions
     :args "(x, mean, sdev)"
     :desc "Lower tail of the normal distribution: the probability that a
Gaussian random variable with mean MEAN and standard deviation SDEV
is at most X.  One standard deviation above the mean gives the
familiar 84.1%."
     :arg-docs (("x" . "Value of the random variable") ("mean" . "Mean of the distribution") ("sdev" . "Standard deviation of the distribution"))
     :returns "The probability of a value at most X"
     :examples ("ltpn(3, 2, 1)")
     :expect ("0.84134474607")
     :eval num :volatile nil
     :note nil)
    (:name "ltpp" :category distributions
     :args "(n, x)"
     :desc "Lower tail of the Poisson distribution: the probability that
fewer than X events occur when the mean number of events is N.
Beware the argument order: unlike the other tail functions, the
distribution parameter (the mean N) comes first and the count X
second."
     :arg-docs (("n" . "Mean of the Poisson distribution") ("x" . "Event-count cutoff (itself excluded from the sum)"))
     :returns "The probability of fewer than X events"
     :examples ("ltpp(2.5, 1)")
     :expect ("0.0820849986239")
     :eval num :volatile nil
     :note "The example is the probability of zero events at mean 2.5,
i.e. `exp(-2.5)'.  Like `ltpb', the bound is exclusive.")
    (:name "ltpt" :category distributions
     :args "(t, v)"
     :desc "Two-sided lower tail for Student's t with V degrees of freedom:
the probability that the variable lies strictly inside (-T, T).
Like `utpt' this is a two-sided quantity - `ltpt(0,v)' is 0, not
0.5.  The example gives the 95% confidence level at the classic
critical value 2.571 for 5 degrees of freedom."
     :arg-docs (("t" . "Magnitude bound on the t statistic") ("v" . "Degrees of freedom"))
     :returns "The probability of a magnitude below T"
     :examples ("ltpt(2.571, 5)")
     :expect ("0.950025365316")
     :eval num :volatile nil
     :note nil)
    (:name "utpb" :category distributions
     :args "(x, n, p)"
     :desc "Upper tail of the binomial distribution: the probability of X or
more successes in N independent trials, each succeeding with
probability P.  The bound is inclusive, complementing the exclusive
lower tail `ltpb'."
     :arg-docs (("x" . "Success-count cutoff (itself included in the sum)") ("n" . "Number of trials") ("p" . "Probability of success on each trial"))
     :returns "The probability of X or more successes"
     :examples ("utpb(3, 10, 0.5)")
     :expect ("0.945312499997")
     :eval num :volatile nil
     :note nil)
    (:name "utpc" :category distributions
     :args "(chisq, v)"
     :desc "Upper tail of the chi-square distribution with V degrees of
freedom: the probability that the statistic exceeds CHISQ.  This is
the usual goodness-of-fit p-value; under the hood it is
`gammaQ(v/2, chisq/2)'."
     :arg-docs (("chisq" . "Value of the chi-square statistic") ("v" . "Degrees of freedom"))
     :returns "The probability of a statistic exceeding CHISQ"
     :examples ("utpc(2, 2)")
     :expect ("0.367879441171")
     :eval num :volatile nil
     :note "With 2 degrees of freedom the upper tail is `exp(-chisq/2)';
the example value is `1/e'.")
    (:name "utpf" :category distributions
     :args "(f, v1, v2)"
     :desc "Upper tail of the F distribution: the probability that an F
statistic with V1 numerator and V2 denominator degrees of freedom
exceeds F.  This is the p-value reported by ANOVA and
variance-ratio tests.  When V1 = V2 the median sits at F = 1, so
the example evaluates to one half."
     :arg-docs (("f" . "Value of the F statistic") ("v1" . "Numerator degrees of freedom") ("v2" . "Denominator degrees of freedom"))
     :returns "The probability of a statistic exceeding F"
     :examples ("utpf(1, 5, 5)")
     :expect ("0.500000000001")
     :eval num :volatile nil
     :note nil)
    (:name "utpn" :category distributions
     :args "(x, mean, sdev)"
     :desc "Upper tail of the normal distribution: the probability that a
Gaussian random variable with mean MEAN and standard deviation SDEV
exceeds X.  At X = MEAN it is exactly one half.  Subtract two calls
to get the probability of landing in a finite interval."
     :arg-docs (("x" . "Value of the random variable") ("mean" . "Mean of the distribution") ("sdev" . "Standard deviation of the distribution"))
     :returns "The probability of a value exceeding X"
     :examples ("utpn(2, 2, 1)")
     :expect ("0.5")
     :eval num :volatile nil
     :note nil)
    (:name "utpp" :category distributions
     :args "(n, x)"
     :desc "Upper tail of the Poisson distribution: the probability that X
or more events occur when the mean number of events is N.  Beware
the argument order: the mean N comes first and the count X second,
opposite to the value-first convention of the other tail functions."
     :arg-docs (("n" . "Mean of the Poisson distribution") ("x" . "Event-count cutoff (itself included in the sum)"))
     :returns "The probability of X or more events"
     :examples ("utpp(2.5, 1)")
     :expect ("0.917915001376")
     :eval num :volatile nil
     :note "The example is the chance of at least one event at mean 2.5,
i.e. `1 - exp(-2.5)'.")
    (:name "utpt" :category distributions
     :args "(t, v)"
     :desc "Two-sided tail probability for Student's t with V degrees of
freedom: the probability that the variable exceeds T in absolute
value.  `utpt(0,v)' is therefore 1, and the one-sided upper tail is
half this value.  The example reproduces the classic 5% two-sided
critical value 2.571 for 5 degrees of freedom."
     :arg-docs (("t" . "Magnitude bound on the t statistic") ("v" . "Degrees of freedom"))
     :returns "The probability of a magnitude of at least T"
     :examples ("utpt(2.571, 5)")
     :expect ("0.0499746346838")
     :eval num :volatile nil
     :note "Many references and the HP-48 define the t upper tail
one-sidedly; their value is exactly half of this function's.")
    (:name "collect" :category algebra
     :args "(expr, base)"
     :desc "Rearrange EXPR as a polynomial in BASE, in decreasing powers with
like powers gathered together.  BASE may be any sub-expression, not
just a variable; terms free of BASE are collected into the constant
part, and only terms involving BASE are expanded as needed."
     :arg-docs (("expr" . "Expression to reorganize") ("base" . "Variable or sub-expression to collect on"))
     :returns "EXPR arranged as a polynomial in BASE"
     :examples ("collect(1 + 2 x + 3 y + 4 x y^2, x)")
     :expect ("(2 + 4 y^2) x + (1 + 3 y)")
     :eval sym :volatile nil
     :note nil)
    (:name "esimplify" :category algebra
     :args "(a)"
     :desc "Simplify A using Calc's extended, `unsafe' rules on top of the
standard set.  These assume values lie in principal ranges: for
example `ln(exp(x))' and `sqrt(x^2)' both collapse to `x', which is
only valid for suitable real `x'.  Use plain `simplify' when such
assumptions are not acceptable."
     :arg-docs (("a" . "Expression to simplify"))
     :returns "A with extended simplifications applied"
     :examples ("esimplify(ln(exp(x)))" "esimplify(sqrt(x^2))")
     :expect ("x" "x")
     :eval sym :volatile nil
     :note nil)
    (:name "islin" :category algebra
     :args "(expr, var?)"
     :desc "Test whether EXPR is linear in VAR, i.e. has the form a + b VAR
for constant `a' and `b'.  Returns 1 when it is.  VAR may itself be
a sub-formula such as `sin(x)'.  With VAR omitted, EXPR must be
linear in some non-constant sub-formula with constant coefficients."
     :arg-docs (("expr" . "Expression to test") ("var" . "Optional; variable or sub-formula of linearity"))
     :returns "1 if EXPR is linear in VAR"
     :examples ("islin(x y / 3 - 2, x)" "islin(3, x)")
     :expect ("1" "1")
     :eval sym :volatile nil
     :note "A non-linear EXPR leaves the call unevaluated rather than
returning 0: `islin(x^2, x)' comes back unchanged.  Constants count
as linear when VAR is given, but not in the one-argument form.")
    (:name "islinnt" :category algebra
     :args "(expr, var?)"
     :desc "Like `islin', but the linear form must be non-trivial: the
coefficient of VAR has to be nonzero.  `islinnt(y, x)' is left
unevaluated because `y' is only trivially linear in `x'.  In the
one-argument form the bare decomposition a = 0, b = 1 is also
rejected."
     :arg-docs (("expr" . "Expression to test") ("var" . "Optional; variable or sub-formula of linearity"))
     :returns "1 if EXPR is non-trivially linear in VAR"
     :examples ("islinnt(2 x + 5, x)")
     :expect ("1")
     :eval sym :volatile nil
     :note nil)
    (:name "lin" :category algebra
     :args "(expr, var?)"
     :desc "Decompose EXPR as a + b VAR and return the vector [a, b, VAR].
With VAR omitted, EXPR must be linear in some non-constant
sub-formula with constant `a' and `b', and that base is returned as
the third element."
     :arg-docs (("expr" . "Expression to decompose") ("var" . "Optional; variable or sub-formula of linearity"))
     :returns "The vector [a, b, VAR] with EXPR = a + b VAR"
     :examples ("lin(x y / 3 - 2, x)" "lin(x, x)")
     :expect ("[-2, y / 3, x]" "[0, 1, x]")
     :eval sym :volatile nil
     :note "Non-linear input leaves the call unevaluated instead of
signalling: `lin(2 x^2, x)' comes back unchanged.")
    (:name "linnt" :category algebra
     :args "(expr, var?)"
     :desc "Like `lin', but only accepts a non-trivial linear form: the
coefficient `b' must be nonzero, so `linnt(y, x)' stays unevaluated.
In the one-argument form the trivial a = 0, b = 1 decomposition is
rejected as well."
     :arg-docs (("expr" . "Expression to decompose") ("var" . "Optional; variable or sub-formula of linearity"))
     :returns "The vector [a, b, VAR] with EXPR = a + b VAR, b nonzero"
     :examples ("linnt(2 x + 5, x)" "linnt(2 - x y)")
     :expect ("[5, 2, x]" "[2, -1, x y]")
     :eval sym :volatile nil
     :note nil)
    (:name "powerexpand" :category algebra
     :args "(expr)"
     :desc "Rewrite integer powers in EXPR as explicit repeated products and
renormalize.  The visible effect is to distribute powers across
products, turning `(a b)^3' into `a^3 b^3'.  Powers of sums are
rebuilt unchanged by the normalizer; use `expand' or `expandpow' to
multiply those out."
     :arg-docs (("expr" . "Expression whose powers to expand"))
     :returns "EXPR with powers of products distributed"
     :examples ("powerexpand((a b)^3)")
     :expect ("a^3 b^3")
     :eval sym :volatile nil
     :note nil)
    (:name "simplify" :category algebra
     :args "(expr)"
     :desc "Apply Calc's standard algebraic simplifications to EXPR, the same
set as the interactive `a s' command: like terms combine, and safe
identities such as `e^ln(x)' to `x' are applied.  Simplifications
that are valid only on restricted domains are left to `esimplify'."
     :arg-docs (("expr" . "Expression to simplify"))
     :returns "The simplified expression"
     :examples ("simplify(e^ln(x))" "simplify(x + x + 2 - 3)")
     :expect ("x" "2 x - 1")
     :eval sym :volatile nil
     :note nil)
    (:name "subst" :category algebra
     :args "(expr, old, new)"
     :desc "Replace every occurrence of the sub-expression OLD in EXPR with
NEW.  Matching is purely structural: `sin(2 x)' does not literally
contain `sin(x)', so substituting for `sin(x)' leaves it untouched.
For pattern-based replacement use `rewrite'."
     :arg-docs (("expr" . "Expression to transform") ("old" . "Variable or sub-expression to replace") ("new" . "Replacement expression"))
     :returns "EXPR with all copies of OLD replaced by NEW"
     :examples ("subst(2 sin(x)^2 + sin(2 x), sin(x), cos(y))")
     :expect ("2 cos(y)^2 + sin(2 x)")
     :eval sym :volatile nil
     :note nil)
    (:name "apart" :category polynomials
     :args "(expr, var?)"
     :desc "Expand the rational function EXPR into partial fractions: a sum
of rational terms with simple denominators.  VAR selects the base
variable of the decomposition; by default Calc chooses it
automatically."
     :arg-docs (("expr" . "Quotient of two polynomials") ("var" . "Optional; base variable for the decomposition"))
     :returns "The partial-fraction expansion of EXPR"
     :examples ("apart((5 x + 7)/(x^2 + 3 x + 2))")
     :expect ("2 / (x + 1) + 3 / (x + 2)")
     :eval sym :volatile nil
     :note nil)
    (:name "expand" :category polynomials
     :args "(expr, many?)"
     :desc "Expand EXPR by applying the distributive law everywhere: to
products, quotients, and powers involving sums.  With MANY, only
that many expansion steps are applied and a partially expanded form
is returned."
     :arg-docs (("expr" . "Expression to expand") ("many" . "Optional; number of distributive steps to apply"))
     :returns "The fully (or partially) expanded expression"
     :examples ("expand((x + 1)^3)")
     :expect ("x^3 + 3 x^2 + 3 x + 1")
     :eval sym :volatile nil
     :note "A small MANY can be folded straight back by the default
simplifications (the first step of expanding `(x+1)^3' is
`(x+1) (x+1)^2', which renormalizes to the input), so the full
expansion is usually what you see.")
    (:name "expandpow" :category polynomials
     :args "(x, n)"
     :desc "Expand the power X^N by the binomial (multinomial) theorem, for
integer N and a sum X."
     :arg-docs (("x" . "Base expression, typically a sum") ("n" . "Integer exponent"))
     :returns "The expanded form of X^N"
     :examples ("expandpow(a + b, 3)")
     :expect ("a^3 + 3 b a^2 + 3 b^2 a + b^3")
     :eval sym :volatile nil
     :note nil)
    (:name "factor" :category polynomials
     :args "(expr, var?)"
     :desc "Factor the polynomial EXPR into a product of irreducible factors
with integer or rational coefficients.  With VAR, factoring is done
with respect to that variable only; the default considers all
variables appearing in EXPR."
     :arg-docs (("expr" . "Polynomial to factor") ("var" . "Optional; variable to factor with respect to"))
     :returns "EXPR as a product of irreducible factors"
     :examples ("factor(x^2 + 3 x + 2)")
     :expect ("(x + 1) (x + 2)")
     :eval sym :volatile nil
     :note nil)
    (:name "factors" :category polynomials
     :args "(expr, var?)"
     :desc "Like `factor', but return the factorization as a vector of
[factor, power] pairs instead of a product.  Any overall numeric
factor always comes first in the list."
     :arg-docs (("expr" . "Polynomial to factor") ("var" . "Optional; variable to factor with respect to"))
     :returns "A vector of [factor, multiplicity] pairs"
     :examples ("factors(x^5 + x^4 - 33 x^3 + 63 x^2)")
     :expect ("[[x, 2], [x + 7, 1], [x - 3, 2]]")
     :eval sym :volatile nil
     :note nil)
    (:name "nrat" :category polynomials
     :args "(expr)"
     :desc "Normalize EXPR into a single quotient of two polynomials,
combining nested fractions and cancelling any common polynomial
factor between numerator and denominator."
     :arg-docs (("expr" . "Expression to normalize"))
     :returns "EXPR as one reduced polynomial quotient"
     :examples ("nrat((x^2 + 2 x + 1)/(x^2 - 1))" "nrat(1 + (a + b/c)/d)")
     :expect ("(x + 1) / (x - 1)" "(c d + a c + b) / (c d)")
     :eval sym :volatile nil
     :note nil)
    (:name "pcont" :category polynomials
     :args "(expr, var?)"
     :desc "Content of the polynomial EXPR.  With VAR, this is the polynomial
GCD of the coefficients of EXPR viewed in VAR, with the sign taken
from the leading coefficient.  With one argument, it is the numeric
content: the `gcd' of the numerators over the `lcm' of the
denominators of all coefficients, so dividing by it clears all
fractions."
     :arg-docs (("expr" . "Polynomial to analyze") ("var" . "Optional; variable EXPR is viewed in"))
     :returns "The content of EXPR"
     :examples ("pcont(4 x y^2 + 6 x^2 y, x)" "pcont(4:3 x y^2 + 6 x^2 y)")
     :expect ("2 y" "2:3")
     :eval sym :volatile nil
     :note nil)
    (:name "pdeg" :category polynomials
     :args "(expr, var?)"
     :desc "Degree of EXPR as a polynomial in VAR: the highest power of VAR
that appears.  Nonzero constants have degree 0, and the zero
polynomial reports `-inf'.  With VAR omitted, the highest total
degree over all variables is returned.  A non-polynomial input
leaves the call unevaluated."
     :arg-docs (("expr" . "Polynomial to measure") ("var" . "Optional; variable EXPR is viewed in"))
     :returns "The degree as an integer (or -inf for zero)"
     :examples ("pdeg(x^3 + 2 x, x)" "pdeg(x^2 y^3 + x y)")
     :expect ("3" "5")
     :eval sym :volatile nil
     :note nil)
    (:name "pdiv" :category polynomials
     :args "(pn, pd, base?)"
     :desc "Polynomial quotient of PN divided by PD, discarding any
remainder.  BASE names the division variable; without it a
multivariate division is performed, choosing the variable with the
largest power in PN first (alphabetical order breaks ties)."
     :arg-docs (("pn" . "Dividend polynomial") ("pd" . "Divisor polynomial") ("base" . "Optional; variable to divide with respect to"))
     :returns "The quotient polynomial q with PN = q PD + r"
     :examples ("pdiv(x^2 + 3 x + 2, x + 2)")
     :expect ("x + 1")
     :eval sym :volatile nil
     :note nil)
    (:name "pdivide" :category polynomials
     :args "(pn, pd, base?)"
     :desc "Divide PN by PD and return the combined form q + r/PD: the
quotient plus the remainder over the divisor.  When the remainder
is zero this reduces to the plain quotient."
     :arg-docs (("pn" . "Dividend polynomial") ("pd" . "Divisor polynomial") ("base" . "Optional; variable to divide with respect to"))
     :returns "The expression q + r/PD"
     :examples ("pdivide(x^2 + 5, x + 1)")
     :expect ("x - 1 + 6 / (x + 1)")
     :eval sym :volatile nil
     :note nil)
    (:name "pdivrem" :category polynomials
     :args "(pn, pd, base?)"
     :desc "Divide the polynomial PN by PD and return both parts as the
vector [q, r], satisfying PN = q PD + r."
     :arg-docs (("pn" . "Dividend polynomial") ("pd" . "Divisor polynomial") ("base" . "Optional; variable to divide with respect to"))
     :returns "The vector [quotient, remainder]"
     :examples ("pdivrem(x^2 + 5, x + 1)")
     :expect ("[x - 1, 6]")
     :eval sym :volatile nil
     :note nil)
    (:name "pgcd" :category polynomials
     :args "(pn, pd)"
     :desc "Greatest common divisor of the polynomials PN and PD.  The GCD is
unique only up to a constant multiplier; Calc chooses an
unsurprising normalization.  Coefficients need not be integers:
rationals and floats are handled too."
     :arg-docs (("pn" . "First polynomial") ("pd" . "Second polynomial"))
     :returns "A greatest common divisor of PN and PD"
     :examples ("pgcd(x^2 + 3 x + 2, x^2 + 5 x + 6)")
     :expect ("x + 2")
     :eval sym :volatile nil
     :note nil)
    (:name "plead" :category polynomials
     :args "(expr, var)"
     :desc "Leading coefficient of EXPR viewed as a polynomial in VAR: the
coefficient of the highest power.  It is computed without expanding
the full coefficient list, so `plead((2 x + 1)^10, x)' finds 1024
directly.  The result is zero only for the zero polynomial."
     :arg-docs (("expr" . "Polynomial to analyze") ("var" . "Variable EXPR is viewed in"))
     :returns "The leading coefficient of EXPR in VAR"
     :examples ("plead((2 x + 1)^10, x)")
     :expect ("1024")
     :eval sym :volatile nil
     :note nil)
    (:name "pprim" :category polynomials
     :args "(expr, var?)"
     :desc "Primitive part of the polynomial EXPR: the polynomial divided by
its content (see `pcont').  Rational coefficients come out as
integer coefficients in lowest terms."
     :arg-docs (("expr" . "Polynomial to reduce") ("var" . "Optional; variable EXPR is viewed in"))
     :returns "EXPR divided by its content"
     :examples ("pprim(4 x y^2 + 6 x^2 y, x)")
     :expect ("3 x^2 + 2 y x")
     :eval sym :volatile nil
     :note nil)
    (:name "prem" :category polynomials
     :args "(pn, pd, base?)"
     :desc "Remainder from dividing the polynomial PN by PD; the quotient is
discarded.  Together with `pdiv' the results satisfy
PN = q PD + r."
     :arg-docs (("pn" . "Dividend polynomial") ("pd" . "Divisor polynomial") ("base" . "Optional; variable to divide with respect to"))
     :returns "The remainder polynomial r"
     :examples ("prem(x^2 + 5, x + 1)")
     :expect ("6")
     :eval sym :volatile nil
     :note nil)
    (:name "asum" :category calculus
     :args "(expr, var, low, high?, step?, no-mul-flag?)"
     :desc "Alternating sum of EXPR as VAR runs from LOW to HIGH by STEP:
successive terms get alternating signs, with the LOW term positive.
Internally the sum is converted to an ordinary `sum' carrying an
extra factor of the form `(-1)^(VAR-LOW)', adjusted for STEP."
     :arg-docs (("expr" . "Term of the sum") ("var" . "Summation index variable") ("low" . "Lower index bound") ("high" . "Optional; upper index bound") ("step" . "Optional; index increment, default 1") ("no-mul-flag" . "Optional; internal recursion flag that suppresses the sign prefactor"))
     :returns "The alternating sum, in closed form when possible"
     :examples ("asum(k, k, 1, 4)")
     :expect ("-2")
     :eval sym :volatile nil
     :note nil)
    (:name "deriv" :category calculus
     :args "(expr, var, value?, symb?)"
     :desc "Derivative of EXPR with respect to VAR, treating all other
variables as constants (use `tderiv' for the total derivative).
With VALUE, VAR is replaced by that point in the result."
     :arg-docs (("expr" . "Expression to differentiate") ("var" . "Variable of differentiation") ("value" . "Optional; point substituted for VAR in the result") ("symb" . "Optional; if non-nil, fail on unknown derivatives instead of embedding symbolic `deriv' sub-calls"))
     :returns "The derivative, simplified"
     :examples ("deriv(x^3 + sin(x), x)")
     :expect ("3 x^2 + cos(x)")
     :eval sym :volatile nil
     :note "The VALUE substitution is textual and is not re-evaluated:
`deriv(sin(x), x, 0)' displays as `cos(0)'.  Wrap the call in
`evalv(...)' to force the substituted form to a number.")
    (:name "integ" :category calculus
     :args "(expr, var, low?, high?)"
     :desc "Integral of EXPR with respect to VAR.  Without bounds an
antiderivative is returned (no constant of integration); with LOW
and HIGH, the definite integral.  Results pass through the
extended (`unsafe') simplifications, so domain conditions are not
attached.  If no closed form is found the call stays unevaluated;
use `ninteg' for a numeric answer."
     :arg-docs (("expr" . "Integrand") ("var" . "Variable of integration") ("low" . "Optional; lower limit of a definite integral") ("high" . "Optional; upper limit of a definite integral"))
     :returns "The antiderivative, or the definite integral with bounds"
     :examples ("integ(x^2, x)" "integ(sin(x), x, 0, pi)")
     :expect ("x^3 / 3" "2")
     :eval sym :volatile nil
     :note nil)
    (:name "prod" :category calculus
     :args "(expr, var, low?, high?, step?)"
     :desc "Product of EXPR as VAR steps from LOW to HIGH by STEP (default
1).  Calc knows closed forms for some symbolic products, so
`prod(k, k, 1, n)' evaluates to `n!'."
     :arg-docs (("expr" . "Term of the product") ("var" . "Index variable") ("low" . "Optional; lower index bound") ("high" . "Optional; upper index bound") ("step" . "Optional; index increment, default 1"))
     :returns "The product, in closed form when possible"
     :examples ("prod(2 k, k, 1, 4)" "prod(k, k, 1, n)")
     :expect ("384" "n!")
     :eval sym :volatile nil
     :note nil)
    (:name "sum" :category calculus
     :args "(expr, var, low?, high?, step?)"
     :desc "Sum of EXPR as VAR steps from LOW to HIGH by STEP (default 1).
Symbolic bounds give a closed form when Calc knows one.  With a
single bound N, the index runs from 1 to N."
     :arg-docs (("expr" . "Term of the sum") ("var" . "Summation index variable") ("low" . "Optional; lower index bound") ("high" . "Optional; upper index bound") ("step" . "Optional; index increment, default 1"))
     :returns "The sum, in closed form when possible"
     :examples ("sum(k^2, k, 1, 10)" "sum(k, k, 1, n)")
     :expect ("385" "1:2 n^2 + 1:2 n")
     :eval sym :volatile nil
     :note nil)
    (:name "table" :category calculus
     :args "(expr, var, low?, high?, step?)"
     :desc "Tabulate EXPR at the index values VAR = LOW, LOW+STEP, ..., HIGH,
returning the vector of individual results instead of combining
them like `sum' or `prod'."
     :arg-docs (("expr" . "Expression to evaluate at each index") ("var" . "Index variable") ("low" . "Optional; lower index bound") ("high" . "Optional; upper index bound") ("step" . "Optional; index increment, default 1"))
     :returns "A vector of EXPR evaluated at each index value"
     :examples ("table(k^2, k, 1, 5)" "table(a_i, i, 1, 7, 2)")
     :expect ("[1, 4, 9, 16, 25]" "[a_1, a_3, a_5, a_7]")
     :eval sym :volatile nil
     :note nil)
    (:name "taylor" :category calculus
     :args "(expr, var, num)"
     :desc "Power series expansion of EXPR in VAR through degree NUM.  VAR
may also be an equation `VAR = a' (or the form `VAR - a') to expand
about the point `a'.  Terms with zero coefficients are dropped, so
fewer than NUM terms may appear."
     :arg-docs (("expr" . "Expression to expand") ("var" . "Expansion variable, optionally as `var = point'") ("num" . "Highest degree to keep"))
     :returns "The truncated power series"
     :examples ("taylor(exp(x), x, 4)")
     :expect ("1 + x + x^2 / 2 + x^3 / 6 + x^4 / 24")
     :eval sym :volatile nil
     :note nil)
    (:name "tderiv" :category calculus
     :args "(expr, var, value?, symb?)"
     :desc "Total derivative of EXPR with respect to VAR: other variables are
treated as unspecified functions of VAR, contributing chain-rule
terms like `tderiv(y, x)' rather than vanishing as they do under
`deriv'."
     :arg-docs (("expr" . "Expression to differentiate") ("var" . "Variable of differentiation") ("value" . "Optional; point substituted for VAR in the result") ("symb" . "Optional; if non-nil, fail on unknown derivatives instead of embedding symbolic sub-calls"))
     :returns "The total derivative"
     :examples ("tderiv(x y, x)")
     :expect ("y + x tderiv(y, x)")
     :eval sym :volatile nil
     :note nil)
    (:name "ffinv" :category solving
     :args "(expr, var)"
     :desc "Fully general functional inverse of EXPR viewed as a function of
VAR.  Like `finv', but multiple-valued inverses carry
arbitrary-sign variables `s1', `s2', ... and arbitrary-integer
variables `n1', `n2', ... so that every branch is represented."
     :arg-docs (("expr" . "Function of VAR to invert") ("var" . "The function's variable"))
     :returns "The general inverse function, written in terms of VAR"
     :examples ("ffinv(x^2, x)")
     :expect ("s1 sqrt(x)")
     :eval sym :volatile nil
     :note nil)
    (:name "finv" :category solving
     :args "(expr, var)"
     :desc "Functional inverse: solve EXPR = y for VAR and express the result
as a function written in terms of VAR again, so inverting `2 x + 6'
gives `x / 2 - 3'.  Only the principal branch is returned; use
`ffinv' for the full family."
     :arg-docs (("expr" . "Function of VAR to invert") ("var" . "The function's variable"))
     :returns "The inverse function, written in terms of VAR"
     :examples ("finv(2 x + 6, x)")
     :expect ("x / 2 - 3")
     :eval sym :volatile nil
     :note nil)
    (:name "fsolve" :category solving
     :args "(expr, var)"
     :desc "Solve the equation EXPR for VAR, reporting the fully general
family of solutions.  Arbitrary integers appear as `n1', `n2', ...
and arbitrary signs (+1 or -1) as `s1', `s2', ..., so all branches
are covered; plain `solve' picks only the principal one."
     :arg-docs (("expr" . "Equation (or expression treated as EXPR = 0)") ("var" . "Variable to solve for"))
     :returns "An equation VAR = general solution"
     :examples ("fsolve(x^2 = y, x)" "fsolve(sin(x) = 0, x)")
     :expect ("x = s1 sqrt(y)" "x = pi n1")
     :eval sym :volatile nil
     :note nil)
    (:name "gpoly" :category solving
     :args "(expr, var, degree?)"
     :desc "Recognize EXPR as a generalized polynomial in VAR.  Returns
[base, coefs, mult] such that EXPR = mult (coefs_1 + coefs_2 base +
coefs_3 base^2 + ...), where BASE is some sub-formula involving VAR
(possibly a power of VAR, so a quartic in `x' can report a
quadratic in `x^2').  Trivial decompositions such as a bare
variable or constant are not recognized.  With DEGREE, only
coefficient vectors of length DEGREE+1 or less are accepted."
     :arg-docs (("expr" . "Expression to analyze") ("var" . "Variable the polynomial is based on") ("degree" . "Optional; largest acceptable polynomial degree"))
     :returns "The vector [base, coefficient vector, multiplier]"
     :examples ("gpoly((x - 2)^2, x)" "gpoly(x^4 + x^2 - 1, x)")
     :expect ("[x, [4, -4, 1], 1]" "[x^2, [-1, 1, 1], 1]")
     :eval sym :volatile nil
     :note nil)
    (:name "poly" :category solving
     :args "(expr, var, degree?)"
     :desc "Coefficient vector of EXPR as a polynomial in VAR, constant term
first; the last element is the leading coefficient and is
guaranteed nonzero.  VAR may be any sub-formula, e.g. `sin(x)'.  A
non-polynomial EXPR leaves the call unevaluated, and with DEGREE
polynomials of higher degree are rejected the same way."
     :arg-docs (("expr" . "Polynomial to decompose") ("var" . "Variable or sub-formula the polynomial is in") ("degree" . "Optional; largest acceptable degree"))
     :returns "The vector of coefficients, constant term first"
     :examples ("poly(x^3 + 2 x, x)" "poly((x + 1)^4, x)")
     :expect ("[0, 2, 0, 1]" "[1, 4, 6, 4, 1]")
     :eval sym :volatile nil
     :note nil)
    (:name "roots" :category solving
     :args "(expr, var)"
     :desc "All solutions of the polynomial equation EXPR in VAR, collected
into a vector by expanding the arbitrary signs and integers of the
general solution.  An Nth-degree polynomial yields its N complex
roots: exactly through degree 4 (and higher when the polynomial
factors), numerically otherwise."
     :arg-docs (("expr" . "Polynomial equation (or expression treated as = 0)") ("var" . "Variable to solve for"))
     :returns "A vector of all roots"
     :examples ("roots(x^4 = 1, x)")
     :expect ("[1, -1, (0, 1), (0, -1)]")
     :eval sym :volatile nil
     :note nil)
    (:name "solve" :category solving
     :args "(expr, var)"
     :desc "Solve the equation EXPR for VAR; a lone formula is treated as
EXPR = 0.  Only one principal solution is returned: `fsolve' gives
the general family and `roots' collects all of them.  Systems work
too: pass a vector of equations and a vector of variables."
     :arg-docs (("expr" . "Equation or vector of equations") ("var" . "Variable or vector of variables to solve for"))
     :returns "An equation VAR = solution, or a vector of them"
     :examples ("solve(x^2 + 3 x + 2 = 0, x)" "solve([x + y = 5, x - y = 1], [x, y])")
     :expect ("x = -1" "[x = 3, y = 2]")
     :eval sym :volatile nil
     :note nil)
    (:name "maximize" :category numerical
     :args "(expr, var, guess)"
     :desc "Numerically locate a local maximum of EXPR in VAR near GUESS,
returning the vector [location, maximum].  GUESS may be a number or
an interval enclosing the maximum.  The search is derivative-free,
and the location is only determined to about half the working
precision because the function is flat near an extremum."
     :arg-docs (("expr" . "Expression to maximize") ("var" . "Variable to vary") ("guess" . "Starting point or bracketing interval"))
     :returns "The vector [location, maximum value]"
     :examples ("maximize(sin(x), x, 1)")
     :expect ("[1.5708, 1.]")
     :eval sym :volatile nil
     :note "A plain GUESS of 0 can fail silently: the internal bracket widens
multiplicatively from the guess, so starting at 0 it never moves and
the guess comes straight back as the answer.  Use a nonzero guess or
an interval.")
    (:name "minimize" :category numerical
     :args "(expr, var, guess)"
     :desc "Numerically locate a local minimum of EXPR in VAR near GUESS,
returning the vector [location, minimum].  GUESS may be a number or
an interval enclosing the minimum; Calc walks downhill from the
guess without using derivatives.  The location is only good to
about half the working precision, so raise the precision if you
need more digits."
     :arg-docs (("expr" . "Expression to minimize") ("var" . "Variable to vary") ("guess" . "Starting point or bracketing interval"))
     :returns "The vector [location, minimum value]"
     :examples ("minimize(x^2 - 2 x, x, [0 .. 4])")
     :expect ("[1., -1.]")
     :eval sym :volatile nil
     :note "A plain GUESS of 0 can fail silently: the internal bracket widens
multiplicatively from the guess, so starting at 0 it never moves and
the guess comes straight back as the answer.  Use a nonzero guess or
an interval.")
    (:name "ninteg" :category numerical
     :args "(expr, var, lo, hi)"
     :desc "Numerically integrate EXPR over VAR from LO to HI with an open
Romberg method.  The endpoints themselves are never evaluated, so
integrands like `sin(x)/x' starting at 0 are safe, and `-inf' or
`inf' bounds are allowed.  Integrating across a singularity is not
supported, and non-smooth integrands may need many evaluations."
     :arg-docs (("expr" . "Integrand") ("var" . "Variable of integration") ("lo" . "Lower limit, possibly -inf") ("hi" . "Upper limit, possibly inf"))
     :returns "The definite integral as a float"
     :examples ("ninteg(sin(x), x, 0, pi)" "ninteg(exp(-x^2), x, -inf, inf)")
     :expect ("2." "1.77245385091")
     :eval sym :volatile nil
     :note nil)
    (:name "root" :category numerical
     :args "(expr, var, guess)"
     :desc "Numerically find a root of EXPR (a bare formula is treated as
EXPR = 0) for VAR near GUESS, returning [root, value] where VALUE
is EXPR at the root, essentially zero.  GUESS may be a real number,
a complex number to search the complex plane, or an interval
bracketing a real root.  Newton's method is used when EXPR is
differentiable, bisection otherwise."
     :arg-docs (("expr" . "Equation or expression to zero") ("var" . "Variable to solve for") ("guess" . "Starting point or bracketing interval"))
     :returns "The vector [root, residual value]"
     :examples ("root(x^2 - 2, x, 1)" "root(cos(x) = x, x, 1)")
     :expect ("[1.41421356237, 0.]" "[0.739085133215, 0.]")
     :eval sym :volatile nil
     :note nil)
    (:name "wmaximize" :category numerical
     :args "(expr, var, guess)"
     :desc "Like `maximize', but an interval GUESS that does not already
enclose a maximum is widened until it does, instead of the search
staying inside it.  In the example the peak of `sin(x)' at pi/2
lies outside [0 .. 0.5]; widening finds it anyway."
     :arg-docs (("expr" . "Expression to maximize") ("var" . "Variable to vary") ("guess" . "Starting point or interval to widen"))
     :returns "The vector [location, maximum value]"
     :examples ("wmaximize(sin(x), x, [0 .. 0.5])")
     :expect ("[1.5708, 1.]")
     :eval sym :volatile nil
     :note nil)
    (:name "wminimize" :category numerical
     :args "(expr, var, guess)"
     :desc "Like `minimize', but an interval GUESS that does not already
enclose a minimum is widened until it does.  In the example the
minimum of `x^2 - 2 x' at x = 1 lies outside [5 .. 6]; the widening
search still finds it."
     :arg-docs (("expr" . "Expression to minimize") ("var" . "Variable to vary") ("guess" . "Starting point or interval to widen"))
     :returns "The vector [location, minimum value]"
     :examples ("wminimize(x^2 - 2 x, x, [5 .. 6])")
     :expect ("[1., -1.]")
     :eval sym :volatile nil
     :note nil)
    (:name "wroot" :category numerical
     :args "(expr, var, guess)"
     :desc "Like `root', but an interval GUESS whose endpoints give the same
sign is widened until it encloses a sign change, rather than being
subdivided in place.  Use it when you are not sure the interval
actually contains a root; in the example the root sqrt(2) lies
outside [3 .. 4]."
     :arg-docs (("expr" . "Equation or expression to zero") ("var" . "Variable to solve for") ("guess" . "Starting point or interval to widen"))
     :returns "The vector [root, residual value]"
     :examples ("wroot(x^2 - 2, x, [3 .. 4])")
     :expect ("[1.41421356237, 0.]")
     :eval sym :volatile nil
     :note nil)
    (:name "efit" :category fitting
     :args "(expr, vars, coefs?, data?)"
     :desc "Least-squares fit like `fit', but the fitted parameters are
reported as error forms `value +/- sigma' giving each coefficient's
statistical uncertainty.  A perfect fit reports zero errors and the
error forms collapse to plain numbers.  DATA rows may themselves
contain error forms to weight the fit."
     :arg-docs (("expr" . "Model formula, e.g. `a x + b'") ("vars" . "Independent variable or vector of them") ("coefs" . "Optional; parameter or vector of parameters to fit") ("data" . "Optional; data matrix [[x values], [y values]]"))
     :returns "The fitted model with error-form coefficients"
     :examples ("efit(a x + b, [x], [a, b], [[1, 2, 3], [3, 5, 8]])")
     :expect ("(2.5 +/- 0.288675134595) x + 0.333333333333 +/- 0.623609564462")
     :eval sym :volatile nil
     :note nil)
    (:name "fit" :category fitting
     :args "(expr, vars, coefs?, data?)"
     :desc "Least-squares fit of the model EXPR to DATA, returning the model
with the fitted parameter values substituted in.  DATA is a matrix
with one row per independent variable and the dependent values
last, e.g. [[x values], [y values]].  When COEFS is omitted the
parameters are the model's variables not listed in VARS.  If the
model cannot be linearized the call is left unevaluated with an
explanatory message."
     :arg-docs (("expr" . "Model formula, e.g. `a x + b'") ("vars" . "Independent variable or vector of them") ("coefs" . "Optional; parameter or vector of parameters to fit") ("data" . "Optional; data matrix [[x values], [y values]]"))
     :returns "The model with fitted parameter values"
     :examples ("fit(a x + b, [x], [a, b], [[0, 1, 2], [1, 3, 5]])" "fit(a x + b, [x], [a, b], [[1, 2, 3], [3, 5, 8]])")
     :expect ("2. x + 1." "2.5 x + 0.333333333333")
     :eval sym :volatile nil
     :note nil)
    (:name "fitdummy" :category fitting
     :args "(x)"
     :desc "Placeholder used by the `FitRules' rewrite set while a fitting
model is massaged into linear form: `fitdummy(N)' stands for the
Nth linearized unknown.  It computes nothing on its own and simply
stays symbolic."
     :arg-docs (("x" . "Placeholder index"))
     :returns "The call itself, unevaluated"
     :examples ("fitdummy(3)")
     :expect ("fitdummy(3)")
     :eval sym :volatile nil
     :note "Only meaningful inside the model set-up machinery of `fit',
`efit' and `xfit' (the `FitRules' rewrites); calling it directly
just returns the call.")
    (:name "fitparam" :category fitting
     :args "(x)"
     :desc "Placeholder that `fit' and friends substitute for the Nth model
parameter while a fit is being set up: parameters `a', `b', ...
become `fitparam(1)', `fitparam(2)', ... inside `FitRules'.  Stays
symbolic when called directly."
     :arg-docs (("x" . "Parameter index"))
     :returns "The call itself, unevaluated"
     :examples ("fitparam(2)")
     :expect ("fitparam(2)")
     :eval sym :volatile nil
     :note "Only meaningful inside `fit'/`efit'/`xfit' model rewriting; see
also `hasfitparams' for testing a formula for these placeholders.")
    (:name "fitvar" :category fitting
     :args "(x)"
     :desc "Placeholder that `fit' and friends substitute for the Nth
independent variable while a fit is being set up; the dependent
variable becomes the highest-numbered `fitvar'.  Stays symbolic
when called directly."
     :arg-docs (("x" . "Variable index"))
     :returns "The call itself, unevaluated"
     :examples ("fitvar(1)")
     :expect ("fitvar(1)")
     :eval sym :volatile nil
     :note "Only meaningful inside `fit'/`efit'/`xfit' model rewriting; see
also `hasfitvars' for testing a formula for these placeholders.")
    (:name "hasfitparams" :category fitting
     :args "(expr)"
     :desc "Test whether EXPR contains any `fitparam(n)' placeholders.
Returns the largest such N (a true value) when present, or 0 when
none.  Useful in the condition clauses of `FitRules' rewrites."
     :arg-docs (("expr" . "Formula to inspect"))
     :returns "The highest fitparam index in EXPR, or 0"
     :examples ("hasfitparams(fitparam(1) x + fitparam(2))" "hasfitparams(a x + b)")
     :expect ("2" "0")
     :eval sym :volatile nil
     :note nil)
    (:name "hasfitvars" :category fitting
     :args "(expr)"
     :desc "Test whether EXPR contains any `fitvar(n)' placeholders.  Returns
the largest such N (a true value) when present, or 0 when none.
Useful in the condition clauses of `FitRules' rewrites."
     :arg-docs (("expr" . "Formula to inspect"))
     :returns "The highest fitvar index in EXPR, or 0"
     :examples ("hasfitvars(fitvar(1) + fitvar(2))")
     :expect ("2")
     :eval sym :volatile nil
     :note nil)
    (:name "polint" :category fitting
     :args "(data, x)"
     :desc "Polynomial interpolation: evaluate the exact polynomial through
the points of DATA at X, returning [y, dy] where DY estimates the
probable interpolation error.  DATA is a matrix [[x values],
[y values]].  If X equals one of the data abscissas, Y is the
tabulated value and DY is exactly 0.  A vector X yields a matrix of
results; a symbolic X leaves the call unevaluated."
     :arg-docs (("data" . "Data matrix [[x values], [y values]]") ("x" . "Abscissa at which to interpolate"))
     :returns "The vector [interpolated y, error estimate]"
     :examples ("polint([[1, 2, 3], [2, 4, 6]], 1.5)")
     :expect ("[3., 0.]")
     :eval sym :volatile nil
     :note nil)
    (:name "ratint" :category fitting
     :args "(data, x)"
     :desc "Rational-function interpolation through the points of DATA,
evaluated at X; the result is [y, dy] as for `polint'.  The
implicit model is a quotient of two polynomials of roughly equal
degree, which can describe functions with poles; evaluating at a
pole of the fitted function divides by zero."
     :arg-docs (("data" . "Data matrix [[x values], [y values]]") ("x" . "Abscissa at which to interpolate"))
     :returns "The vector [interpolated y, error estimate]"
     :examples ("ratint([[1, 2, 3], [2, 4, 6]], 1.5)")
     :expect ("[3., 0.333333333333]")
     :eval sym :volatile nil
     :note nil)
    (:name "xfit" :category fitting
     :args "(expr, vars, coefs?, data?)"
     :desc "Extended least-squares fit.  Like `efit' but returns the
six-element vector [model, params, covar, filters, chi2, q]: the
fitted model with error-form coefficients, the raw parameter
values, the parameter covariance matrix, a vector of parameter
filter functions (empty for polynomial and multilinear models), the
chi-square of the fit, and a goodness-of-fit probability Q."
     :arg-docs (("expr" . "Model formula, e.g. `a x + b'") ("vars" . "Independent variable or vector of them") ("coefs" . "Optional; parameter or vector of parameters to fit") ("data" . "Optional; data matrix [[x values], [y values]]"))
     :returns "The vector [model, params, covar, filters, chi2, q]"
     :examples ("xfit(a x + b, [x], [a, b], [[1, 2, 3], [3, 5, 8]])")
     :expect ("[(2.5 +/- 0.288675134595) x + 0.333333333333 +/- 0.623609564462, [2.5, 0.333333333333], [[0.5, -1], [-1, 2.33333333333]], [], 0.166666666667, nan]")
     :eval sym :volatile nil
     :note "Q is computed only when the input DATA carries `y +/- sigma'
error forms; with plain numbers the chi-square has been used up
estimating the input errors and Q is reported as `nan'.")
    (:name "match" :category rewrite
     :args "(pat, vec)"
     :desc "Select the elements of VEC that match the rewrite pattern PAT,
preserving their order.  Matching is syntactic, with pattern
variables free: matching `a^2' against [x^2, 3, y^2, x] keeps just
the literal squares.  PAT may also be a vector of patterns; an
element is kept if any of them matches."
     :arg-docs (("pat" . "Rewrite pattern or vector of patterns") ("vec" . "Vector of formulas to filter"))
     :returns "A vector of the matching elements"
     :examples ("match(a^2, [x^2, 3, y^2, x])")
     :expect ("[x^2, y^2]")
     :eval sym :volatile nil
     :note "Conditional patterns (`PAT :: COND') parse but never fire in this
Calc version (see `matches'), so selections like `x :: x > 0'
quietly return `[]'.  Also, VEC is normalized first: `sin(2)' is
already a float before matching happens.")
    (:name "matches" :category rewrite
     :args "(expr, pat)"
     :desc "Test whether EXPR matches the rewrite pattern PAT: returns 1 on a
match and 0 otherwise.  Intended as a predicate inside the
condition clauses of other rewrite rules."
     :arg-docs (("expr" . "Formula to test") ("pat" . "Rewrite pattern"))
     :returns "1 if EXPR matches PAT, else 0"
     :examples ("matches(x^2 + 1, a^2 + b)" "matches(2 x, a^2 + b)")
     :expect ("1" "0")
     :eval sym :volatile nil
     :note "A `PAT :: COND' pattern is accepted syntactically, but this Calc
version files the compiled rule under the `::' operator's own head,
so it can never fire against ordinary data: `matches(5, x :: x > 0)'
returns 0, and wrapping the pattern in a vector does not help.
Attach conditions to `rewrite' rules instead, where they do work:
`rewrite(5, [x := 99 :: x > 0])' yields 99.")
    (:name "matchnot" :category rewrite
     :args "(pat, vec)"
     :desc "Complement of `match': return the elements of VEC that do not
match the rewrite pattern PAT, preserving their order."
     :arg-docs (("pat" . "Rewrite pattern or vector of patterns") ("vec" . "Vector of formulas to filter"))
     :returns "A vector of the non-matching elements"
     :examples ("matchnot(a^2, [x^2, 3, y])")
     :expect ("[3, y]")
     :eval sym :volatile nil
     :note "Conditional patterns (`PAT :: COND') never fire here (see
`matches'), so `matchnot' with such a pattern keeps every element.")
    (:name "rewrite" :category rewrite
     :args "(expr, rules, many?)"
     :desc "Apply rewrite RULES to EXPR.  Rules are written `LHS := RHS',
optionally with a `:: COND' condition, and are usually collected in
a vector; pattern variables in LHS bind to arbitrary
sub-expressions.  MANY limits the number of rewriting passes: the
default is a single pass over the whole expression, an integer N
allows N passes, and `inf' repeats until no rule fires."
     :arg-docs (("expr" . "Expression to rewrite") ("rules" . "Rule or vector of rules `LHS := RHS :: COND'") ("many" . "Optional; pass limit, default 1, `inf' until stable"))
     :returns "The rewritten expression"
     :examples ("rewrite(a + a + b, [x + x := 2 x])" "rewrite(10, [x := x - 1 :: x > 0], inf)")
     :expect ("2 a + b" "0")
     :eval sym :volatile nil
     :note "One pass rewrites every eligible site once, so
`rewrite(a + a + b + b, [x + x := 2 x])' already gives `2 a + 2 b';
the MANY limit matters for rules that re-trigger on their own
output, like the countdown example.")
    (:name "vmatches" :category rewrite
     :args "(expr, pat)"
     :desc "Like `matches', but a successful match returns the vector of
meta-variable assignments, e.g. `[b := 1, a := x]', instead of 1.
A failed match still returns 0."
     :arg-docs (("expr" . "Formula to test") ("pat" . "Rewrite pattern"))
     :returns "A vector of `var := value' bindings, or 0 on failure"
     :examples ("vmatches(x^2 + 1, a^2 + b)")
     :expect ("[b := 1, a := x]")
     :eval sym :volatile nil
     :note "Arguments are normalized before matching: `vmatches(sin(3),
sin(a))' returns 0 because `sin(3)' has already collapsed to a
float (radians) by the time the pattern sees it.")
    (:name "badd" :category date-time
     :args "(a, b)"
     :desc "Business-day addition.  A is a date form and B a real number of
business days (or an HMS form of business time); weekends and any
dates listed in the `Holidays' variable are skipped.  If A falls on
a weekend or holiday it is treated as the most recent business day,
so adding one day to a Friday, Saturday, or Sunday yields Monday.
A non-integer B advances by a fraction of a business day as well."
     :arg-docs (("a" . "Date form to advance") ("b" . "Business days to add: a real number or an HMS form"))
     :returns "A date form B business days past A"
     :examples ("badd(date(2026, 7, 22), 5)")
     :expect ("<Wed Jul 29, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "bsub" :category date-time
     :args "(a, b)"
     :desc "Business-day subtraction.  With a date form A and a number or HMS
form B, steps A back B business days.  With two date forms, the
result is the number of business days between them, skipping
weekends and the holidays defined in the `Holidays' variable."
     :arg-docs (("a" . "Date form to step back, or the later of two dates") ("b" . "Business days to subtract, or an earlier date form"))
     :returns "A date form, or the count of business days between two dates"
     :examples ("bsub(date(2026, 7, 27), date(2026, 7, 20))" "bsub(date(2026, 7, 22), 5)")
     :expect ("5" "<Wed Jul 15, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "date" :category date-time
     :args "(date, month?, day?, hour?, minute?, second?)"
     :desc "Convert between date forms and day numbers, or build a date form.
A single date form yields its day count since Jan 1, 1 AD (an
integer for a pure date, a fraction or float for a date/time form);
a single number converts the other way.  With MONTH and DAY, the
first argument acts as a year number (2026, not 26) and a pure date
form is built; adding HOUR, MINUTE, and SECOND builds a date/time
form."
     :arg-docs (("date" . "Date form, day number, or year number when building") ("month" . "Optional; month number, 1 to 12") ("day" . "Optional; day of month, 1 to 31") ("hour" . "Optional; hour, 0 to 23") ("minute" . "Optional; minute, 0 to 59") ("second" . "Optional; second, a real in [0 .. 60)"))
     :returns "A date form, or the day number of DATE"
     :examples ("date(2026, 7, 22)" "date(739819)")
     :expect ("<Wed Jul 22, 2026>" "<Wed Jul 22, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "day" :category date-time
     :args "(date)"
     :desc "Day-of-month number of a date form, an integer from 1 to 31.
A plain real number is also accepted and treated as a Calc day
number."
     :arg-docs (("date" . "Date form (or day number)"))
     :returns "The day of the month of DATE"
     :examples ("day(date(2026, 7, 22))")
     :expect ("22")
     :eval num :volatile nil
     :note nil)
    (:name "dsadj" :category date-time
     :args "(date, zone?)"
     :desc "Daylight saving adjustment for DATE in time zone ZONE, in hours:
0 when standard time applies, -1 when daylight saving is in effect.
An explicit zone such as `est' or `pdt' fixes the answer regardless
of DATE; a generalized zone such as `egt' or `pgt' applies Calc's
North American rule (second Sunday of March through first Sunday of
November).  With ZONE omitted, the current time zone is consulted,
so the answer then depends on the environment."
     :arg-docs (("date" . "Date form to examine") ("zone" . "Optional; time zone name, defaulting to the current zone"))
     :returns "0 or -1, the daylight saving adjustment in hours"
     :examples ("dsadj(date(2026, 7, 22), egt)" "dsadj(date(2026, 1, 15), egt)")
     :expect ("-1" "0")
     :eval sym :volatile nil
     :note "Zone names like `egt' are Calc variables, so this function is
evaluated on the symbolic path; the numeric path rejects them as
unbound variables.")
    (:name "holiday" :category date-time
     :args "(a)"
     :desc "Test whether a date falls on a holiday.  Returns 1 if A is a
weekend or holiday according to the `Holidays' variable, or 0 if it
is a business day.  Out of the box `Holidays' contains only
`[sat, sun]', so exactly Saturdays and Sundays count as holidays."
     :arg-docs (("a" . "Date form to test"))
     :returns "1 for a weekend or holiday, 0 for a business day"
     :examples ("holiday(date(2026, 7, 25))" "holiday(date(2026, 7, 22))")
     :expect ("1" "0")
     :eval num :volatile nil
     :note nil)
    (:name "hour" :category date-time
     :args "(date)"
     :desc "Hour of a date/time form, an integer from 0 (midnight) to 23;
24-hour time is always used.  A pure date form yields 0."
     :arg-docs (("date" . "Date form (or date/time form)"))
     :returns "The hour of DATE"
     :examples ("hour(date(2026, 7, 22, 14, 30, 45))")
     :expect ("14")
     :eval num :volatile nil
     :note "Calc also accepts HMS forms here, but under the wrapper's radians
mode an `hms(h, m, s)' call is first rescaled as an angle, so
extracting fields from one gives surprising results.  Extract from
date forms instead.")
    (:name "incmonth" :category date-time
     :args "(date, step?)"
     :desc "Advance DATE by STEP months (default 1; negative steps go
backward).  The day of month and any time portion are preserved,
except that the day is clamped when the target month is shorter."
     :arg-docs (("date" . "Date form to advance") ("step" . "Optional; number of months, default 1"))
     :returns "A date form STEP months past DATE"
     :examples ("incmonth(date(2026, 1, 31))" "incmonth(date(2026, 7, 22), 3)")
     :expect ("<Sat Feb 28, 2026>" "<Thu Oct 22, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "incyear" :category date-time
     :args "(date, step?)"
     :desc "Advance DATE by STEP years (default 1; negative steps go
backward), keeping the month and day.  Equivalent to
`incmonth(date, 12 * step)', so a Feb 29 date is clamped to Feb 28
in a non-leap target year."
     :arg-docs (("date" . "Date form to advance") ("step" . "Optional; number of years, default 1"))
     :returns "A date form STEP years past DATE"
     :examples ("incyear(date(2026, 7, 22), 4)")
     :expect ("<Mon Jul 22, 2030>")
     :eval num :volatile nil
     :note nil)
    (:name "julian" :category date-time
     :args "(date, zone?)"
     :desc "Julian day count of DATE: the number of days since noon GMT on
Jan 1, 4713 BC.  A pure date form gives an integer count for noon
of that day and is never time-zone adjusted.  A date/time form
gives an exact floating-point count, interpreting DATE in the
current (or given) zone and the count in GMT.  A number as DATE
converts back into a date form."
     :arg-docs (("date" . "Date form (or Julian day count to convert back)") ("zone" . "Optional; time zone for date/time conversions"))
     :returns "The Julian day count, or a date form when DATE is a number"
     :examples ("julian(date(2026, 7, 22))")
     :expect ("2461244")
     :eval num :volatile nil
     :note nil)
    (:name "minute" :category date-time
     :args "(date)"
     :desc "Minute of a date/time form, an integer from 0 to 59.  A pure
date form yields 0."
     :arg-docs (("date" . "Date form (or date/time form)"))
     :returns "The minute of DATE"
     :examples ("minute(date(2026, 7, 22, 14, 30, 45))")
     :expect ("30")
     :eval num :volatile nil
     :note nil)
    (:name "month" :category date-time
     :args "(date)"
     :desc "Month number of a date form, an integer from 1 to 12.  A plain
real number is also accepted and treated as a Calc day number."
     :arg-docs (("date" . "Date form (or day number)"))
     :returns "The month of DATE"
     :examples ("month(date(2026, 7, 22))")
     :expect ("7")
     :eval num :volatile nil
     :note nil)
    (:name "newmonth" :category date-time
     :args "(date, day?)"
     :desc "The first day of the month DATE lies in, as a pure date form; any
day and time portions of DATE are discarded.  With DAY, the DAYth
day of that month instead; a DAY of zero, or one past the length of
the month, selects the last day."
     :arg-docs (("date" . "Date form supplying the year and month") ("day" . "Optional; day of month, 1 to 31 (0 for the last day)"))
     :returns "A pure date form in the month of DATE"
     :examples ("newmonth(date(2026, 7, 22))" "newmonth(date(2026, 2, 10), 31)")
     :expect ("<Wed Jul 1, 2026>" "<Sat Feb 28, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "newweek" :category date-time
     :args "(date, weekday?)"
     :desc "The Sunday on or before DATE, as a pure date form.  WEEKDAY
(0 = Sunday .. 6 = Saturday) selects a different starting day.
Between 0 and 6 days are always subtracted, so a DATE already on
the requested weekday is returned unchanged; use
`newweek(d + 7, w)' for the next such weekday strictly after a
given day."
     :arg-docs (("date" . "Date form to step back from") ("weekday" . "Optional; weekday to find, 0 (Sunday) to 6 (Saturday)"))
     :returns "A pure date form on the requested weekday, at most 6 days before DATE"
     :examples ("newweek(date(2026, 7, 22))")
     :expect ("<Sun Jul 19, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "newyear" :category date-time
     :args "(date, day?)"
     :desc "The first day of the year DATE lies in, as a pure date form.
With DAY from 1 to 366, the DAYth day of that year (366 acts as 365
in non-leap years); 0 selects Dec 31, and a negative DAY from -1 to
-12 selects the first day of that month number."
     :arg-docs (("date" . "Date form supplying the year") ("day" . "Optional; day of year, 0 for Dec 31, or -1 to -12 for a month start"))
     :returns "A pure date form in the year of DATE"
     :examples ("newyear(date(2026, 7, 22))")
     :expect ("<Thu Jan 1, 2026>")
     :eval num :volatile nil
     :note nil)
    (:name "now" :category date-time
     :args "(zone?)"
     :desc "The current date and time as a date/time form, reported in the
current time zone, or in ZONE if given."
     :arg-docs (("zone" . "Optional; time zone to report in"))
     :returns "A date/time form for the present moment"
     :examples ("now()")
     :expect (nil)
     :eval num :volatile t
     :note "Each call reads the real-time clock, so the result changes from
run to run.")
    (:name "pwday" :category date-time
     :args "(date, day?, weekday?)"
     :desc "Day-of-month number of the Sunday on or before day DAY of the
month DATE lies in.  DAY must be 7 to 31 (0 selects the end of the
month); values past the month's length are clamped, so
`pwday(d, 7)' finds the first Sunday of the month and
`pwday(d, 31)' the last."
     :arg-docs (("date" . "Date form supplying the year and month") ("day" . "Optional; day of month to search back from, 7 to 31 (0 for last)") ("weekday" . "Optional; nominally a weekday to find, but ignored"))
     :returns "The day-of-month number of the found Sunday"
     :examples ("pwday(date(2026, 7, 22), 7)" "pwday(date(2026, 7, 22), 31)")
     :expect ("5" "26")
     :eval num :volatile nil
     :note "Two quirks of the current Calc implementation: the one-argument
call `pwday(d)' is rejected with an argument-type error even though
DAY is nominally optional, and the WEEKDAY argument is accepted but
ignored -- the search is always for Sunday.")
    (:name "second" :category date-time
     :args "(date)"
     :desc "Second of a date/time form, an integer from 0 to 59 at the
default precision (higher precisions can yield a float).  A pure
date form yields 0."
     :arg-docs (("date" . "Date form (or date/time form)"))
     :returns "The second of DATE"
     :examples ("second(date(2026, 7, 22, 14, 30, 45))")
     :expect ("45")
     :eval num :volatile nil
     :note nil)
    (:name "time" :category date-time
     :args "(date)"
     :desc "Time portion of a date form, extracted as an HMS form.  A pure
date form (midnight) yields the zero HMS form."
     :arg-docs (("date" . "Date form (or date/time form)"))
     :returns "An HMS form holding the time of day of DATE"
     :examples ("time(date(2026, 7, 22, 14, 30, 45))")
     :expect ("14@ 30' 45\"")
     :eval num :volatile nil
     :note nil)
    (:name "tzconv" :category date-time
     :args "(date, z1, z2)"
     :desc "Convert the date/time form DATE from time zone Z1 to time zone
Z2.  Zones may be given by name (`est', `pst', `gmt', ...) or as
numbers of hours west of Greenwich."
     :arg-docs (("date" . "Date/time form to convert") ("z1" . "Time zone DATE is currently expressed in") ("z2" . "Time zone to convert into"))
     :returns "DATE re-expressed in zone Z2"
     :examples ("tzconv(date(2026, 7, 22, 12, 0, 0), est, pst)")
     :expect ("<9:00am Wed Jul 22, 2026>")
     :eval sym :volatile nil
     :note "Zone names are Calc variables, so this function is evaluated on
the symbolic path; the numeric path rejects `est' and friends as
unbound variables.")
    (:name "tzone" :category date-time
     :args "(zone?, date?)"
     :desc "Time zone ZONE as a number of seconds difference from Greenwich
Mean Time; positive values lie west of Greenwich.  A numeric ZONE
is simply multiplied by 3600, while a name such as `est' or `pdt'
is looked up in Calc's zone table.  DATE matters only for
generalized zones like `egt', whose daylight saving state depends
on the date.  With no arguments the current time zone is reported,
which depends on the environment."
     :arg-docs (("zone" . "Optional; zone name or hours west of Greenwich") ("date" . "Optional; date consulted for generalized zones"))
     :returns "The zone offset in seconds from GMT"
     :examples ("tzone(est)" "tzone(5)")
     :expect ("18000" "18000")
     :eval sym :volatile nil
     :note "Zone names are Calc variables, so this entry evaluates on the
symbolic path.  Only the zero-argument form is environment
dependent; give an explicit ZONE for reproducible results.")
    (:name "unixtime" :category date-time
     :args "(date, zone?)"
     :desc "Convert the date form DATE into a Unix time value: seconds since
midnight GMT on Jan 1, 1970.  DATE is interpreted in the current
time zone unless ZONE is given (as in `tzone', hours west of
Greenwich; use 0 for GMT/UTC).  A number as DATE converts back into
a date/time form."
     :arg-docs (("date" . "Date form (or Unix time value to convert back)") ("zone" . "Optional; time zone DATE is expressed in"))
     :returns "Seconds since the Unix epoch, or a date/time form for numeric DATE"
     :examples ("unixtime(date(2026, 1, 1), 0)")
     :expect ("1767225600")
     :eval num :volatile nil
     :note "Without ZONE the answer shifts with the machine's local time
zone; pass an explicit ZONE for reproducible output.")
    (:name "weekday" :category date-time
     :args "(date)"
     :desc "Weekday number of a date form, an integer from 0 (Sunday) to 6
(Saturday).  A plain real number is also accepted and treated as a
Calc day number."
     :arg-docs (("date" . "Date form (or day number)"))
     :returns "The weekday of DATE, 0 through 6"
     :examples ("weekday(date(2026, 7, 22))")
     :expect ("3")
     :eval num :volatile nil
     :note nil)
    (:name "year" :category date-time
     :args "(date)"
     :desc "Year number of a date form as an integer, e.g. 2026.  Never
returns zero: the year 1 BC immediately precedes 1 AD."
     :arg-docs (("date" . "Date form (or day number)"))
     :returns "The year of DATE"
     :examples ("year(date(2026, 7, 22))")
     :expect ("2026")
     :eval num :volatile nil
     :note nil)
    (:name "yearday" :category date-time
     :args "(date)"
     :desc "Day-of-year number of a date form, from 1 (January 1) to 366
(December 31 of a leap year)."
     :arg-docs (("date" . "Date form (or day number)"))
     :returns "The ordinal day of the year of DATE"
     :examples ("yearday(date(2026, 7, 22))")
     :expect ("203")
     :eval num :volatile nil
     :note nil)
    (:name "hms" :category forms
     :args "(h, m?, s?)"
     :desc "Build an hours-minutes-seconds form, also used for
degrees-minutes-seconds angles.  With one argument, H is an angle
in the current angular mode converted to HMS notation.  With M and
S in the range [0, 60), the result is that conversion of H plus a
literal M minutes and S seconds; an out-of-range M or S instead
normalizes H + M/60 + S/3600 as degrees."
     :arg-docs (("h" . "Angle in the current angular mode (whole-degrees part)") ("m" . "Optional; minutes, taken literally when in [0, 60)") ("s" . "Optional; seconds, taken literally when in [0, 60)"))
     :returns "An HMS form"
     :examples ("hms(1, 30, 0)" "hms(0, 90, 0)")
     :expect ("57@ 47' 44.806248\"" "1@ 30' 0.\"")
     :eval num :volatile nil
     :note "The wrapper's corrected default angular mode is radians, so H is
read as radians even in the three-argument call: `hms(1, 30, 0)'
converts 1 radian to 57@ 17' 44.8\" and then attaches the literal
30'.  To write a literal angle, force the degree-normalization
path with an out-of-range component, as in `hms(0, 90, 0)'.")
    (:name "intv" :category forms
     :args "(mask, lo, hi)"
     :desc "Build an interval form spanning LO to HI.  MASK is an integer
code from 0 to 3 selecting which endpoints are closed: 0 gives
(LO .. HI), 1 gives (LO .. HI], 2 gives [LO .. HI), and 3 gives
[LO .. HI]."
     :arg-docs (("mask" . "Endpoint closure code, 0 to 3") ("lo" . "Lower limit") ("hi" . "Upper limit"))
     :returns "An interval form"
     :examples ("intv(3, 1, 5)")
     :expect ("[1 .. 5]")
     :eval num :volatile nil
     :note nil)
    (:name "makemod" :category forms
     :args "(n, m)"
     :desc "Build the modulo form N mod M, representing a value reduced
modulo M.  Arithmetic between modulo forms and with plain integers
stays reduced modulo M; division succeeds only when a unique
inverse exists, which is guaranteed when M is prime.  Components
must be numbers: variables and formulas cannot be carried inside a
modulo form."
     :arg-docs (("n" . "Value to reduce") ("m" . "Modulus"))
     :returns "A modulo form"
     :examples ("makemod(3, 10)")
     :expect ("3 mod 10")
     :eval num :volatile nil
     :note nil)
    (:name "sdev" :category forms
     :args "(x, sigma)"
     :desc "Build the error form X +/- SIGMA: an uncertain value following a
normal distribution with mean X and standard deviation SIGMA.
Arithmetic and transcendental functions propagate the error by
first-order analysis, assuming errors are small and uncorrelated.
A negative or complex SIGMA is replaced by its absolute value, and
a zero SIGMA collapses the form to a plain number."
     :arg-docs (("x" . "Mean value") ("sigma" . "Standard deviation (error) part"))
     :returns "An error form"
     :examples ("sdev(10, 2)")
     :expect ("10 +/- 2")
     :eval num :volatile nil
     :note nil)
    (:name "ddb" :category financial
     :args "(cost, salvage, life, period)"
     :desc "Double-declining-balance depreciation: the amount an asset worth
COST new and SALVAGE after LIFE periods loses in period PERIOD
(1 to LIFE).  Each period writes off a fixed fraction of the
remaining book value, so early periods bear the most; once the book
value reaches SALVAGE no further depreciation occurs, so late
periods (and out-of-range PERIODs) can yield 0."
     :arg-docs (("cost" . "Original cost of the asset") ("salvage" . "Value remaining at the end of the useful life") ("life" . "Number of periods of useful life") ("period" . "Period to compute the depreciation for, 1 to LIFE"))
     :returns "The depreciation amount for PERIOD"
     :examples ("ddb(12000, 2000, 5, 1)" "ddb(12000, 2000, 5, 5)")
     :expect ("4800" "0")
     :eval num :volatile nil
     :note nil)
    (:name "fv" :category financial
     :args "(rate, num, amount, initial?)"
     :desc "Future value of a savings plan: what NUM regular payments of
AMOUNT are worth after NUM periods when money earns RATE per
period, with each payment made at the end of its period.  RATE is a
per-period fraction (0.054, not 5.4).  Optional INITIAL is a lump
sum already invested at time zero, contributing
`fvl(rate, num, initial)' on top.  Signs follow Calc's cash-flow
convention -- the result carries the sign of AMOUNT -- unlike the
`loanpmt' family, which always reports positive magnitudes."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of payments/periods") ("amount" . "Payment made each period") ("initial" . "Optional; lump sum invested at time zero"))
     :returns "The value of the investment after NUM periods"
     :examples ("fv(0.054, 5, 1000)")
     :expect ("5569.95582306")
     :eval num :volatile nil
     :note nil)
    (:name "fvb" :category financial
     :args "(rate, num, amount, initial?)"
     :desc "Future value of NUM payments of AMOUNT at RATE per period, with
payments at the beginning of each period, so every payment earns
one more period of interest than under `fv'.  Optional INITIAL is a
time-zero lump sum exactly as in `fv'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of payments/periods") ("amount" . "Payment made at the start of each period") ("initial" . "Optional; lump sum invested at time zero"))
     :returns "The value of the investment after NUM periods"
     :examples ("fvb(0.054, 5, 1000)")
     :expect ("5870.7334375")
     :eval num :volatile nil
     :note nil)
    (:name "fvl" :category financial
     :args "(rate, num, amount)"
     :desc "Future value of a lump sum: AMOUNT invested once at RATE per
period grows to `amount * (1 + rate)^num' after NUM periods.  Exact
inverse of `pvl'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of periods") ("amount" . "Lump sum invested at time zero"))
     :returns "The value of the lump sum after NUM periods"
     :examples ("fvl(0.054, 5, 5000)")
     :expect ("6503.88807223")
     :eval num :volatile nil
     :note nil)
    (:name "irr" :category financial
     :args "(v...)"
     :desc "Internal rate of return of the cash-flow vector V: the rate at
which `npv(rate, v)' is zero, found by numeric root search.  Flows
follow the signed convention -- outlays negative, receipts positive
-- and the result is a per-period fraction.  Several vector or
scalar arguments are collected left to right into one flow list,
as in `vsum'."
     :arg-docs (("v" . "One or more vectors (or numbers) of signed period cash flows"))
     :returns "The internal rate of return as a per-period fraction"
     :examples ("irr([-1000, 300, 400, 500])")
     :expect ("0.0889633946934")
     :eval num :volatile nil
     :note "Flows without a sign change have no root; the call then stays
unevaluated, an error on the numeric path.")
    (:name "irrb" :category financial
     :args "(v...)"
     :desc "Internal rate of return with cash flows at the beginning of each
period: the rate at which `npvb(rate, v)' is zero.  Since `npvb' is
just `npv' scaled by `(1 + rate)', the root -- and hence the result
-- is the same as `irr' on the same flows."
     :arg-docs (("v" . "One or more vectors (or numbers) of signed period cash flows"))
     :returns "The internal rate of return as a per-period fraction"
     :examples ("irrb([-1000, 300, 400, 500])")
     :expect ("0.0889633946934")
     :eval num :volatile nil
     :note nil)
    (:name "nper" :category financial
     :args "(rate, pmt, amount, lump?)"
     :desc "Number of end-of-period payments of PMT needed to amortize a
present value of AMOUNT at RATE per period: the N solving
`pv(rate, n, pmt) = amount'.  The result is generally fractional.
If PMT is too small ever to pay off AMOUNT, the call stays in
symbolic form, which the numeric path reports as an error."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("pmt" . "Payment made each period") ("amount" . "Present value to amortize") ("lump" . "Optional; balloon amount still due at the end (slow to solve)"))
     :returns "The number of periods, usually fractional"
     :examples ("nper(0.08, 100, 500)")
     :expect ("6.637457293")
     :eval num :volatile nil
     :note nil)
    (:name "nperb" :category financial
     :args "(rate, pmt, amount, lump?)"
     :desc "Like `nper' but with payments at the beginning of each period:
the N solving `pvb(rate, n, pmt) = amount'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("pmt" . "Payment made at the start of each period") ("amount" . "Present value to amortize") ("lump" . "Optional; balloon amount still due at the end (slow to solve)"))
     :returns "The number of periods, usually fractional"
     :examples ("nperb(0.08, 100, 500)")
     :expect ("6.01113907918")
     :eval num :volatile nil
     :note nil)
    (:name "nperl" :category financial
     :args "(rate, pmt, amount)"
     :desc "Number of periods for a single lump sum to grow: the N solving
`pvl(rate, n, pmt) = amount', so AMOUNT is the present value and
PMT the target future value.  For example, 1000 grows to 2000 at 8%
per period in about nine periods."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("pmt" . "Target future value") ("amount" . "Present value invested today"))
     :returns "The number of periods, usually fractional"
     :examples ("nperl(0.08, 2000, 1000)")
     :expect ("9.006468342")
     :eval num :volatile nil
     :note nil)
    (:name "npv" :category financial
     :args "(rate, flows...)"
     :desc "Net present value at RATE per period of a series of irregular
cash flows, one at the end of each period.  Flows follow the signed
convention: outlays negative, receipts positive.  FLOWS may be any
mix of vectors and plain numbers, collected left to right into the
payment list."
     :arg-docs (("rate" . "Discount rate per period, as a fraction") ("flows" . "Signed cash flows, as vectors and/or numbers"))
     :returns "The discounted value of the flows at time zero"
     :examples ("npv(0.09, [2000, 2000, 2000, 2000])" "npv(0.08, [-10000, 3000, 4200, 6800])")
     :expect ("6479.43975411" "1645.05561295")
     :eval num :volatile nil
     :note nil)
    (:name "npvb" :category financial
     :args "(rate, flows...)"
     :desc "Net present value with each cash flow at the beginning of its
period rather than the end; equal to `npv' scaled by
`(1 + rate)'."
     :arg-docs (("rate" . "Discount rate per period, as a fraction") ("flows" . "Signed cash flows, as vectors and/or numbers"))
     :returns "The discounted value of the flows at time zero"
     :examples ("npvb(0.09, [2000, 2000, 2000, 2000])")
     :expect ("7062.58933198")
     :eval num :volatile nil
     :note nil)
    (:name "pmt" :category financial
     :args "(rate, num, amount, lump?)"
     :desc "Periodic payment that amortizes a loan: the payment P solving
`pv(rate, num, p) = amount', due at the end of each period.  RATE
is per period, so a monthly loan wants the annual rate divided by
12, and the result carries the sign of AMOUNT under Calc's
cash-flow convention.  Compare `loanpmt', which takes the annual
rate and a term in years and always returns the positive payment a
borrower makes.  Optional LUMP is a balloon amount still due at the
end of the term; its discounted value reduces what the payments
must cover."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of payments/periods") ("amount" . "Present value (loan principal)") ("lump" . "Optional; balloon amount still due after the last payment"))
     :returns "The payment per period, signed like AMOUNT"
     :examples ("pmt(0.005, 360, 300000)" "pmt(0.065 / 12, 360, 300000)")
     :expect ("1798.65157546" "1896.20407048")
     :eval num :volatile nil
     :note "The second example reproduces `loanpmt(300000, 0.065, 30)' --
same mathematics, different argument conventions.")
    (:name "pmtb" :category financial
     :args "(rate, num, amount, lump?)"
     :desc "Periodic payment with payments at the beginning of each period:
the payment P solving `pvb(rate, num, p) = amount'.  Slightly
smaller than `pmt' because each payment starts earning interest one
period sooner.  LUMP is a balloon amount as in `pmt'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of payments/periods") ("amount" . "Present value (loan principal)") ("lump" . "Optional; balloon amount still due after the last payment"))
     :returns "The payment per period, signed like AMOUNT"
     :examples ("pmtb(0.005, 360, 300000)")
     :expect ("1789.70306016")
     :eval num :volatile nil
     :note nil)
    (:name "pv" :category financial
     :args "(rate, num, amount, lump?)"
     :desc "Present value of NUM end-of-period payments of AMOUNT when money
earns RATE per period: the break-even sum you could take today
instead of the payment stream.  Signs pass straight through under
Calc's cash-flow convention, so a stream of -1000 payments has a
negative present value; the `loanpmt' family instead reports
positive magnitudes.  Optional LUMP is an extra amount received at
the end of the term, adding `pvl(rate, num, lump)'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of payments/periods") ("amount" . "Payment received each period") ("lump" . "Optional; extra lump sum received at the end"))
     :returns "The value of the payment stream at time zero, signed like AMOUNT"
     :examples ("pv(0.09, 4, 2000)" "pv(0.05, 30, -1000)")
     :expect ("6479.43975411" "-15372.4510269")
     :eval num :volatile nil
     :note nil)
    (:name "pvb" :category financial
     :args "(rate, num, amount, lump?)"
     :desc "Present value of NUM payments of AMOUNT at RATE per period, with
payments at the beginning of each period; larger than `pv' because
each payment is discounted one period less.  LUMP is as in `pv'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of payments/periods") ("amount" . "Payment received at the start of each period") ("lump" . "Optional; extra lump sum received at the end"))
     :returns "The value of the payment stream at time zero, signed like AMOUNT"
     :examples ("pvb(0.09, 4, 2000)")
     :expect ("7062.58933198")
     :eval num :volatile nil
     :note nil)
    (:name "pvl" :category financial
     :args "(rate, num, amount)"
     :desc "Present value of a lump sum AMOUNT received after NUM periods at
RATE per period: `amount * (1 + rate)^-num'.  Exact inverse of
`fvl'."
     :arg-docs (("rate" . "Interest rate per period, as a fraction") ("num" . "Number of periods") ("amount" . "Lump sum received after NUM periods"))
     :returns "The discounted value of AMOUNT at time zero"
     :examples ("pvl(0.09, 4, 8000)")
     :expect ("5667.40168852")
     :eval num :volatile nil
     :note nil)
    (:name "rate" :category financial
     :args "(num, pmt, amount, lump?)"
     :desc "Per-period rate of return implied by NUM end-of-period payments
of PMT with present value AMOUNT: solves
`pv(rate, num, pmt) = amount' numerically.  Raw Calc displays the
result as a percent form such as `9%'; the wrapper folds it to a
plain fraction."
     :arg-docs (("num" . "Number of payments/periods") ("pmt" . "Payment received each period") ("amount" . "Present value of the payment stream") ("lump" . "Optional; extra lump sum received at the end"))
     :returns "The interest rate per period, as a fraction"
     :examples ("rate(4, 2000, 6479.44)")
     :expect ("0.0899999827105")
     :eval num :volatile nil
     :note nil)
    (:name "rateb" :category financial
     :args "(num, pmt, amount, lump?)"
     :desc "Like `rate' but for beginning-of-period payments: solves
`pvb(rate, num, pmt) = amount' numerically.  Accepts the same
optional LUMP argument."
     :arg-docs (("num" . "Number of payments/periods") ("pmt" . "Payment received at the start of each period") ("amount" . "Present value of the payment stream") ("lump" . "Optional; extra lump sum received at the end"))
     :returns "The interest rate per period, as a fraction"
     :examples ("rateb(4, 2000, 7062.59)")
     :expect ("0.0899999259615")
     :eval num :volatile nil
     :note nil)
    (:name "ratel" :category financial
     :args "(num, pmt, amount)"
     :desc "Rate at which a lump sum grows: solves
`pvl(rate, num, pmt) = amount', with AMOUNT the present value and
PMT the future value it becomes after NUM periods.  For example,
doubling money in nine periods takes just over 8% per period."
     :arg-docs (("num" . "Number of periods") ("pmt" . "Target future value") ("amount" . "Present value invested today"))
     :returns "The interest rate per period, as a fraction"
     :examples ("ratel(9, 2000, 1000)")
     :expect ("0.0800597388923")
     :eval num :volatile nil
     :note nil)
    (:name "sln" :category financial
     :args "(cost, salvage, life, period?)"
     :desc "Straight-line depreciation: an asset worth COST new and SALVAGE
after LIFE periods loses the same `(cost - salvage) / life' in
every period.  PERIOD is accepted for symmetry with `syd' and `ddb'
and is otherwise ignored, except that an out-of-range PERIOD yields
0."
     :arg-docs (("cost" . "Original cost of the asset") ("salvage" . "Value remaining at the end of the useful life") ("life" . "Number of periods of useful life") ("period" . "Optional; period number, checked for range only"))
     :returns "The depreciation amount per period"
     :examples ("sln(12000, 2000, 5)")
     :expect ("2000")
     :eval num :volatile nil
     :note nil)
    (:name "syd" :category financial
     :args "(cost, salvage, life, period)"
     :desc "Sum-of-years'-digits depreciation of an asset worth COST new and
SALVAGE after LIFE periods, for period PERIOD (1 to LIFE).
Depreciation is heaviest in the first period and declines linearly;
a PERIOD outside the range yields 0."
     :arg-docs (("cost" . "Original cost of the asset") ("salvage" . "Value remaining at the end of the useful life") ("life" . "Number of periods of useful life") ("period" . "Period to compute the depreciation for, 1 to LIFE"))
     :returns "The depreciation amount for PERIOD"
     :examples ("syd(12000, 2000, 5, 1)" "syd(12000, 2000, 5, 5)")
     :expect ("3333.33333333" "666.666666667")
     :eval num :volatile nil
     :note nil)
    (:name "dbfield" :category units-db-music
     :args "(val, ref?)"
     :desc "Decibel level of the field quantity VAL, computed as
`20 log10(val/ref) dB'.  REF defaults to `20 uPa', the standard
acoustic sound-pressure reference (customizable via
`calc-lu-field-reference').  Give VAL units compatible with the
reference; a bare number is divided by the united default and the
result carries odd units like `dB / uPa'."
     :arg-docs (("val" . "Field quantity, e.g. a sound pressure") ("ref" . "Optional; reference field quantity (default 20 uPa)"))
     :returns "The level of VAL in decibels"
     :examples ("dbfield(2 Pa)")
     :expect ("100. dB")
     :eval num :volatile nil
     :note nil)
    (:name "dbpower" :category units-db-music
     :args "(val, ref?)"
     :desc "Decibel level of the power quantity VAL, computed as
`10 log10(val/ref) dB'.  REF defaults to one milliwatt
(customizable via `calc-lu-power-reference')."
     :arg-docs (("val" . "Power quantity whose level is wanted") ("ref" . "Optional; reference power quantity (default 1 mW)"))
     :returns "The level of VAL in decibels"
     :examples ("dbpower(1 W)" "dbpower(100 mW, 1 mW)")
     :expect ("30 dB" "20 dB")
     :eval num :volatile nil
     :note nil)
    (:name "freq" :category units-db-music
     :args "(expr)"
     :desc "Frequency of the musical note EXPR, which may be a midi note
number or a note in scientific pitch notation.  Concert A (midi 69,
`A_4') is 440 Hz; most other notes come out as irrational
frequencies."
     :arg-docs (("expr" . "Note as a midi number or in scientific pitch notation"))
     :returns "The note's frequency in Hz"
     :examples ("freq(69)" "freq(55)")
     :expect ("440 Hz" "195.99771799 Hz")
     :eval num :volatile nil
     :note "Scientific-pitch input such as `freq(A_4)' works too, but the
subscripted note name only survives the symbolic evaluation path.")
    (:name "lufadd" :category units-db-music
     :args "(a, b)"
     :desc "Add two field-quantity levels A and B: the underlying field
quantities are combined and the result re-expressed as a level,
`20 log10(10^(a/20) + 10^(b/20)) dB'.  Both arguments must carry
`dB' or `Np' units; bare numbers leave the form symbolic.
Reference levels play no role in this arithmetic."
     :arg-docs (("a" . "First level, in dB or Np") ("b" . "Second level, in dB or Np"))
     :returns "The combined level"
     :examples ("lufadd(20 dB, 20 dB)")
     :expect ("26.0205999132 dB")
     :eval num :volatile nil
     :note "Sound-pressure levels, although field quantities, usually
combine through the power formula (`lupadd'), because it is the
underlying sound powers that add.")
    (:name "lufdiv" :category units-db-music
     :args "(a, b)"
     :desc "Divide the field-quantity level A by the plain number B: the
underlying field quantity is divided by B, so the level drops by
`20 log10(b)'.  A must carry `dB' or `Np' units; reference levels
play no role."
     :arg-docs (("a" . "Level, in dB or Np") ("b" . "Plain number to divide the underlying quantity by"))
     :returns "The reduced level"
     :examples ("lufdiv(60 dB, 10)")
     :expect ("40 dB")
     :eval num :volatile nil
     :note nil)
    (:name "lufmul" :category units-db-music
     :args "(a, b)"
     :desc "Multiply the field-quantity level A by the plain number B: the
underlying field quantity is scaled by B, raising the level by
`20 log10(b)'.  A must carry `dB' or `Np' units; reference levels
play no role."
     :arg-docs (("a" . "Level, in dB or Np") ("b" . "Plain number to scale the underlying quantity by"))
     :returns "The raised level"
     :examples ("lufmul(20 dB, 10)")
     :expect ("40 dB")
     :eval num :volatile nil
     :note nil)
    (:name "lufquant" :category units-db-music
     :args "(val, ref?)"
     :desc "Field quantity corresponding to the level VAL, relative to the
reference REF.  This inverts `dbfield'/`npfield': 20 dB above the
default `20 uPa' reference is `200 uPa'."
     :arg-docs (("val" . "Level in dB or Np") ("ref" . "Optional; reference field quantity (default 20 uPa)"))
     :returns "The field quantity VAL describes"
     :examples ("lufquant(20 dB)")
     :expect ("200 uPa")
     :eval num :volatile nil
     :note nil)
    (:name "lufsub" :category units-db-music
     :args "(a, b)"
     :desc "Subtract the field-quantity level B from A: the underlying
field quantities are subtracted and the difference re-expressed as
a level, `20 log10(10^(a/20) - 10^(b/20)) dB'.  Both arguments must
carry `dB' or `Np' units; bare numbers leave the form symbolic."
     :arg-docs (("a" . "Level to subtract from, in dB or Np") ("b" . "Level to subtract, in dB or Np"))
     :returns "The level of the difference"
     :examples ("lufsub(30 dB, 20 dB)")
     :expect ("26.6982292274 dB")
     :eval num :volatile nil
     :note nil)
    (:name "lupadd" :category units-db-music
     :args "(a, b)"
     :desc "Add two power-quantity levels A and B: the underlying powers
are summed and the result re-expressed as a level,
`10 log10(10^(a/10) + 10^(b/10)) dB'.  Both arguments must carry
`dB' or `Np' units; bare numbers leave the form symbolic.
Reference levels play no role in this arithmetic."
     :arg-docs (("a" . "First level, in dB or Np") ("b" . "Second level, in dB or Np"))
     :returns "The combined level"
     :examples ("lupadd(20 dB, 20 dB)")
     :expect ("23.0102999566 dB")
     :eval num :volatile nil
     :note nil)
    (:name "lupdiv" :category units-db-music
     :args "(a, b)"
     :desc "Divide the power-quantity level A by the plain number B: the
underlying power is divided by B, so the level drops by
`10 log10(b)'.  A must carry `dB' or `Np' units; reference levels
play no role."
     :arg-docs (("a" . "Level, in dB or Np") ("b" . "Plain number to divide the underlying power by"))
     :returns "The reduced level"
     :examples ("lupdiv(20 dB, 10)")
     :expect ("10 dB")
     :eval num :volatile nil
     :note nil)
    (:name "lupmul" :category units-db-music
     :args "(a, b)"
     :desc "Multiply the power-quantity level A by the plain number B: the
underlying power is scaled by B, raising the level by
`10 log10(b)'.  A must carry `dB' or `Np' units; reference levels
play no role."
     :arg-docs (("a" . "Level, in dB or Np") ("b" . "Plain number to scale the underlying power by"))
     :returns "The raised level"
     :examples ("lupmul(20 dB, 10)")
     :expect ("30 dB")
     :eval num :volatile nil
     :note nil)
    (:name "lupquant" :category units-db-music
     :args "(val, ref?)"
     :desc "Power quantity corresponding to the level VAL, relative to the
reference REF.  This inverts `dbpower'/`nppower': 20 dB above the
default one-milliwatt reference is `100 mW'."
     :arg-docs (("val" . "Level in dB or Np") ("ref" . "Optional; reference power quantity (default 1 mW)"))
     :returns "The power quantity VAL describes"
     :examples ("lupquant(20 dB)" "lupquant(20 dB, 4 W)")
     :expect ("100 mW" "400 W")
     :eval num :volatile nil
     :note nil)
    (:name "lupsub" :category units-db-music
     :args "(a, b)"
     :desc "Subtract the power-quantity level B from A: the underlying
powers are subtracted and the difference re-expressed as a level,
`10 log10(10^(a/10) - 10^(b/10)) dB'.  Both arguments must carry
`dB' or `Np' units; bare numbers leave the form symbolic."
     :arg-docs (("a" . "Level to subtract from, in dB or Np") ("b" . "Level to subtract, in dB or Np"))
     :returns "The level of the difference"
     :examples ("lupsub(30 dB, 20 dB)")
     :expect ("29.5424250944 dB")
     :eval num :volatile nil
     :note nil)
    (:name "midi" :category units-db-music
     :args "(expr)"
     :desc "Midi note number of EXPR, which may be a frequency or a note in
scientific pitch notation.  Midi numbers run from 0 (`C_-1') to 127
(`G_9'); concert A at 440 Hz is note 69.  Composes with `spn' and
`freq' for round trips like `midi(spn(440 Hz))'."
     :arg-docs (("expr" . "Frequency or note in scientific pitch notation"))
     :returns "The midi note number"
     :examples ("midi(440 Hz)")
     :expect ("69")
     :eval num :volatile nil
     :note nil)
    (:name "npfield" :category units-db-music
     :args "(val, ref?)"
     :desc "Neper level of the field quantity VAL, computed as
`ln(val/ref) Np'.  REF defaults to `20 uPa' (customizable via
`calc-lu-field-reference').  Nepers are the natural-log siblings of
decibels; VAL should carry units compatible with the reference."
     :arg-docs (("val" . "Field quantity, e.g. a sound pressure") ("ref" . "Optional; reference field quantity (default 20 uPa)"))
     :returns "The level of VAL in nepers"
     :examples ("npfield(2 Pa)")
     :expect ("11.512925465 Np")
     :eval num :volatile nil
     :note nil)
    (:name "nppower" :category units-db-music
     :args "(val, ref?)"
     :desc "Neper level of the power quantity VAL, computed as
`(1/2) ln(val/ref) Np'.  REF defaults to one milliwatt
(customizable via `calc-lu-power-reference')."
     :arg-docs (("val" . "Power quantity whose level is wanted") ("ref" . "Optional; reference power quantity (default 1 mW)"))
     :returns "The level of VAL in nepers"
     :examples ("nppower(1 W)")
     :expect ("3.45387763949 Np")
     :eval num :volatile nil
     :note nil)
    (:name "spn" :category units-db-music
     :args "(expr)"
     :desc "Scientific pitch notation for EXPR, a frequency or midi note
number.  The result is a note name with an octave subscript
(`A_4'), plus an offset in `cents' when the frequency falls between
notes; a cent is one hundredth of a semitone."
     :arg-docs (("expr" . "Frequency or midi note number"))
     :returns "The note in scientific pitch notation"
     :examples ("spn(440 Hz)" "spn(500 Hz)")
     :expect ("A_4" "B_4 + 21.3094853649 cents")
     :eval sym :volatile nil
     :note "The subscripted note name is not a plain number, so `spn' only
works on the symbolic evaluation path.  The variable
`calc-note-threshold' (default 1 cent) controls how close a
frequency must be to a note to be reported as exactly that note.")
    (:name "usimplify" :category units-db-music
     :args "(a)"
     :desc "Simplify the units expression A, converting compatible units so
they combine.  When mixed but compatible units are added, the
right-hand term is converted to the left-hand term's units.
Quotients of same-dimension units cancel, fractional powers of unit
expressions resolve, and rounding functions applied to united
values act on the numeric part only."
     :arg-docs (("a" . "Units expression to simplify"))
     :returns "The simplified units expression"
     :examples ("usimplify(5 m + 23 mm)" "usimplify(sqrt(9 mm^2))")
     :expect ("5.023 m" "3 mm")
     :eval num :volatile nil
     :note nil)
    (:name "constant" :category logical
     :args "(a)"
     :desc "True (1) if A is a constant object: a number, or a composite
such as a vector or error form all of whose components are
constants.  Variables do not qualify, and neither do symbolic
constants like `pi' or infinities.  When the answer cannot be
decided the call stays symbolic."
     :arg-docs (("a" . "Object to test for constancy"))
     :returns "1 if A is constant, 0 if not"
     :examples ("constant([1, 2, 3])")
     :expect ("1")
     :eval num :volatile nil
     :note "On the numeric path the wrapper replaces `pi' with its float
value before `constant' sees it; evaluated symbolically,
`constant(pi)' stays unevaluated.")
    (:name "eq" :category logical
     :args "(a, b, more...)"
     :desc "Equality test: 1 if the arguments are all equal, 0 if provably
unequal, and symbolic when the engine cannot decide.  Numbers are
compared by value, so the integer 3 equals the float 3.0.  Also
written `a = b'; with more than two arguments, every argument must
match."
     :arg-docs (("a" . "First value") ("b" . "Second value") ("more" . "Further values that must also be equal"))
     :returns "1, 0, or a symbolic equation"
     :examples ("eq(3, 3.0)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "geq" :category logical
     :args "(a, b)"
     :desc "True (1) if A is greater than or equal to B, 0 otherwise;
comparisons the engine cannot decide stay symbolic.  Also written
`a >= b'."
     :arg-docs (("a" . "Left-hand value") ("b" . "Right-hand value"))
     :returns "1, 0, or a symbolic inequality"
     :examples ("geq(3, 3)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "gt" :category logical
     :args "(a, b)"
     :desc "True (1) if A is strictly greater than B, 0 otherwise;
comparisons the engine cannot decide stay symbolic.  Also written
`a > b'."
     :arg-docs (("a" . "Left-hand value") ("b" . "Right-hand value"))
     :returns "1, 0, or a symbolic inequality"
     :examples ("gt(3, 2)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "if" :category logical
     :args "(c, e1, e2)"
     :desc "If C is a nonzero number the result is E1; if C is zero it is
E2.  When C is not a number the whole form stays symbolic and
neither branch is touched -- `if' is one of the few Calc functions
whose arguments are not evaluated up front.  A vector C selects
elementwise between E1 and E2."
     :arg-docs (("c" . "Condition: a number, or a vector of numbers") ("e1" . "Result when C is nonzero") ("e2" . "Result when C is zero"))
     :returns "E1 or E2, chosen by C"
     :examples ("if(2 < 3, 10, 20)")
     :expect ("10")
     :eval num :volatile nil
     :note nil)
    (:name "in" :category logical
     :args "(a, b)"
     :desc "Set membership: 1 if the number A lies in the set B, 0 if not.
B may be an interval form, a vector of numbers and/or intervals, or
a plain number (which tests numeric equality)."
     :arg-docs (("a" . "Number to look for") ("b" . "Set: an interval, a vector, or a single number"))
     :returns "1 if A is in B, else 0"
     :examples ("in(3, [1 .. 5])")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "integer" :category logical
     :args "(a)"
     :desc "True (1) if A is literally an integer constant, 0 otherwise.
Only actual integers qualify -- to recognize provably
integer-valued formulas such as `floor(x)', use the declaration
test `dint' instead."
     :arg-docs (("a" . "Object to test"))
     :returns "1 if A is an integer, else 0"
     :examples ("integer(5)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "istrue" :category logical
     :args "(a)"
     :desc "1 if A is a nonzero number or a provably nonzero formula, else
0.  Unlike most predicates it never stays symbolic: anything not
provably true counts as false, so `istrue(x)' is 0 for an
undeclared X."
     :arg-docs (("a" . "Value or formula to test for truth"))
     :returns "1 if A is provably true, else 0"
     :examples ("istrue(5)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "land" :category logical
     :args "(a, b)"
     :desc "Logical AND: zero if either argument is zero; if both are
nonzero the result is one of the two (true) arguments.  Non-numeric
arguments leave the form symbolic.  Also written `a && b'."
     :arg-docs (("a" . "First operand") ("b" . "Second operand"))
     :returns "A true (nonzero) value, or 0"
     :examples ("land(1, 1)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "leq" :category logical
     :args "(a, b)"
     :desc "True (1) if A is less than or equal to B, 0 otherwise;
comparisons the engine cannot decide stay symbolic.  Also written
`a <= b'."
     :arg-docs (("a" . "Left-hand value") ("b" . "Right-hand value"))
     :returns "1, 0, or a symbolic inequality"
     :examples ("leq(2, 2)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "lnot" :category logical
     :args "(a)"
     :desc "Logical NOT: 1 if A is zero, 0 if A is a nonzero number.  A
non-numeric argument leaves the form symbolic.  Also written `!a'."
     :arg-docs (("a" . "Operand"))
     :returns "1 if A is zero, 0 if nonzero"
     :examples ("lnot(0)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "lor" :category logical
     :args "(a, b)"
     :desc "Logical OR: whichever argument is nonzero (chosen arbitrarily
when both are), or zero when both arguments are zero.  Note that
the true result is the nonzero VALUE itself, not necessarily 1.
Also written `a || b'."
     :arg-docs (("a" . "First operand") ("b" . "Second operand"))
     :returns "A nonzero operand, or 0"
     :examples ("lor(0, 5)")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "lt" :category logical
     :args "(a, b)"
     :desc "True (1) if A is strictly less than B, 0 otherwise; comparisons
the engine cannot decide stay symbolic.  Also written `a < b'.
Chained forms like `a <= b < c' parse into an equivalent `in' test
on an interval."
     :arg-docs (("a" . "Left-hand value") ("b" . "Right-hand value"))
     :returns "1, 0, or a symbolic inequality"
     :examples ("lt(2, 3)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "negative" :category logical
     :args "(a)"
     :desc "1 if A looks negative: a negative number, a form `-x', or a
product or quotient containing a negative-looking factor.  It
returns 1 or 0 for ANY argument, so outside an unevaluated context
it immediately collapses; its natural habitat is rewrite-rule
conditions, where the literal-appearance test is exactly what is
wanted."
     :arg-docs (("a" . "Expression to inspect"))
     :returns "1 if A looks negative, else 0"
     :examples ("negative(-4)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "neq" :category logical
     :args "(a, b, more...)"
     :desc "Inequality test: 1 if the arguments are pairwise distinct, 0 if
any two are provably equal, and symbolic when the engine cannot
decide.  Also written `a != b'; with more arguments, all of them
must differ from each other."
     :arg-docs (("a" . "First value") ("b" . "Second value") ("more" . "Further values that must all be distinct"))
     :returns "1, 0, or a symbolic form"
     :examples ("neq(1, 2, 3)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "nonvar" :category logical
     :args "(a)"
     :desc "1 if A is anything other than a variable.  When A is a variable
the call simply stays unevaluated -- it never actually returns 0 --
which still reads as false in rewrite-rule conditions, its intended
use."
     :arg-docs (("a" . "Object to test"))
     :returns "1 if A is not a variable; otherwise unevaluated"
     :examples ("nonvar(3)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "real" :category logical
     :args "(a)"
     :desc "True (1) if A is a real number -- an integer, fraction, or
float -- and 0 for anything else, including complex numbers and
vectors.  Use the declaration test `dreal' to recognize
provably-real formulas rather than literal numbers."
     :arg-docs (("a" . "Object to test"))
     :returns "1 if A is a real number, else 0"
     :examples ("real(1.5)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "refers" :category logical
     :args "(a, b)"
     :desc "1 if the variable or sub-expression B occurs anywhere inside A,
else 0.  Unlike most predicates it gives a definite no even for
symbolic arguments; the only unevaluated case is when A is itself a
plain variable different from B.  Meant mainly for rewrite-rule
conditions."
     :arg-docs (("a" . "Expression to search") ("b" . "Variable or sub-expression to look for"))
     :returns "1 if B appears in A, else 0"
     :examples ("refers(x + 2 y, y)" "refers(x + 2 y, z)")
     :expect ("1" "0")
     :eval sym :volatile nil
     :note nil)
    (:name "rmeq" :category logical
     :args "(a)"
     :desc "Strip an equation or inequality down to its interesting side:
for `x = 5' the right-hand side 5.  If the right side is the
variable, as in `2.34 = x', the left side is kept instead;
assignments `x := v' yield V, and `=>' forms yield their left side.
Works elementwise on vectors of equations."
     :arg-docs (("a" . "Equation, inequality, assignment, or vector of them"))
     :returns "The value side of A"
     :examples ("rmeq(x = 5)")
     :expect ("5")
     :eval sym :volatile nil
     :note nil)
    (:name "typeof" :category logical
     :args "(a)"
     :desc "Integer code classifying A: 1 integer, 2 fraction, 3 float,
100 variable, 101 vector, 102 matrix; HMS, complex, error,
interval, modulo, date, and infinity forms take codes 4 through 12.
For any other formula the result is instead a variable naming the
top-level function call."
     :arg-docs (("a" . "Object to classify"))
     :returns "A type code, or a variable naming A's head function"
     :examples ("typeof(3)" "typeof([1, 2])")
     :expect ("1" "101")
     :eval num :volatile nil
     :note nil)
    (:name "variable" :category logical
     :args "(a)"
     :desc "1 if A is a variable, 0 if it is a number or other non-variable
object.  A function-call argument leaves the test symbolic.
Built-in symbolic constants such as `pi' count as variables here."
     :arg-docs (("a" . "Object to test"))
     :returns "1 if A is a variable, else 0"
     :examples ("variable(x)")
     :expect ("1")
     :eval sym :volatile nil
     :note nil)
    (:name "deven" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is known to be an even integer (an
integer-valued float counts), 0 if known to be odd or a
non-integer, and unevaluated when neither can be proved.
Declarations recorded in the `Decls' matrix are consulted, which
makes it useful in rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test for evenness"))
     :returns "1, 0, or the unevaluated call"
     :examples ("deven(4)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dimag" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably imaginary, i.e. equal
to a real number times `i', 0 if provably not, and unevaluated
otherwise.  Consults declarations in the `Decls' matrix; designed
for rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dimag(3 i)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dint" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably an integer, 0 if
provably not, and unevaluated otherwise.  Calc reasons from its
built-in functions and from `Decls' declarations, so
`dint(floor(x))' is 1 even though X is unknown -- contrast
`integer', which accepts only literal integer constants.  Real
infinities count as integers here."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dint(2.5)" "dint(floor(x))")
     :expect ("0" "1")
     :eval sym :volatile nil
     :note nil)
    (:name "dnatnum" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably a natural number, i.e.
a nonnegative integer, 0 if provably not, and unevaluated
otherwise.  Consults declarations in the `Decls' matrix; designed
for rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dnatnum(5)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dneg" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably a negative real, 0 if
provably not, and unevaluated otherwise.  Since Calc's
simplifications already turn `x < 0' into this test where possible,
direct calls are rarely needed outside rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dneg(-2)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dnonneg" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably a nonnegative real,
i.e. greater than or equal to zero, 0 if provably not, and
unevaluated otherwise.  Consults declarations in the `Decls'
matrix; designed for rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dnonneg(0)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dnonzero" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably nonzero -- a nonzero
real or complex number, an interval excluding zero, a nonzero
modulo form, a vector of nonzero elements, or a formula deducibly
nonzero.  Error forms never qualify, since they could hide any
value.  This is exactly the set Calc treats as true in conditional
contexts."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dnonzero(5)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dnumint" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably numerically an integer
-- an actual integer or an integer-valued float such as 4.0 -- 0 if
provably not, and unevaluated otherwise.  Consults declarations in
the `Decls' matrix; designed for rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dnumint(4.0)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dodd" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is known to be an odd integer, 0 if
known to be even or a non-integer, and unevaluated when neither can
be proved.  Declarations recorded in the `Decls' matrix are
consulted, which makes it useful in rewrite-rule conditions."
     :arg-docs (("expr" . "Value or formula to test for oddness"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dodd(7)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dpos" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably a positive (strictly
nonzero) real, 0 if provably not, and unevaluated otherwise.  Since
Calc's simplifications already turn `x > 0' into this test where
possible, direct calls are rarely needed outside rewrite-rule
conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dpos(3)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "drange" :category declarations
     :args "(expr)"
     :desc "The set of possible values of EXPR, as an interval or a vector
of intervals and numbers.  Ranges come from `Decls' declarations
when available; otherwise the possible signs of EXPR are analyzed
as for `dpos' and a set like `[0 .. inf]' is produced.  If EXPR is
not provably real the call stays unevaluated -- `drange(x)' does,
for an undeclared X."
     :arg-docs (("expr" . "Value or formula whose range is wanted"))
     :returns "A set (interval or vector) covering EXPR's possible values"
     :examples ("drange(abs(x))")
     :expect ("[0 .. inf]")
     :eval sym :volatile nil
     :note nil)
    (:name "drat" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably rational -- an integer
or a fraction -- 0 if provably not, and unevaluated otherwise.
Infinities count as rational; intervals and error forms do not."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("drat(3:4)")
     :expect ("1")
     :eval num :volatile nil
     :note "Under the wrapper's standard `/' precedence, `3/4' evaluates to
the float 0.75, for which `drat' answers 0.  Enter fractions in
Calc's `3:4' notation, or produce one with `frac'.")
    (:name "dreal" :category declarations
     :args "(expr)"
     :desc "Declaration test: 1 if EXPR is provably real -- integers,
fractions, floats, real error forms, and intervals all qualify --
0 if provably not, and unevaluated otherwise.  Consults
declarations in the `Decls' matrix; designed for rewrite-rule
conditions."
     :arg-docs (("expr" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dreal(1.5)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "dscalar" :category declarations
     :args "(a)"
     :desc "Declaration test: 1 if A is provably a scalar (a non-vector),
0 if provably a vector or matrix, and unevaluated when neither can
be shown.  Under Calc's Matrix or Scalar modes the undecided case
answers 0 or 1 respectively.  In conditional contexts an
unevaluated call reads as false, so `dscalar(a)' is true only for a
provably scalar A."
     :arg-docs (("a" . "Value or formula to test"))
     :returns "1, 0, or the unevaluated call"
     :examples ("dscalar(7)")
     :expect ("1")
     :eval num :volatile nil
     :note nil)
    (:name "cascent" :category internals
     :args "(a, prec?)"
     :desc "Rows of A's printed form at or above the baseline -- a layout
metric for Calc's composition (display) engine.  In the wrapper's
normal display language nearly everything renders on one line, so
ordinary formulas have ascent 1; `cascent(x) + cdescent(x)' always
equals `cheight(x)'.  Rarely useful outside custom display code."
     :arg-docs (("a" . "Formula whose printed form is measured") ("prec" . "Optional; surrounding operator precedence for the composition"))
     :returns "Ascent of the printed form, in lines"
     :examples ("cascent(a / b)")
     :expect ("1")
     :eval sym :volatile nil
     :note "A bare number as A trips an internal type check (the function
inspects the head of a composite argument), so the call stays
unevaluated on atoms -- pass a formula.")
    (:name "cdescent" :category internals
     :args "(a, prec?)"
     :desc "Rows of A's printed form strictly below the baseline -- a
layout metric for Calc's composition (display) engine.  One-line
formulas have descent 0; only display languages with stacked output
(such as Big mode) produce more.  Rarely useful outside custom
display code."
     :arg-docs (("a" . "Formula whose printed form is measured") ("prec" . "Optional; surrounding operator precedence for the composition"))
     :returns "Descent of the printed form, in lines"
     :examples ("cdescent(a / b)")
     :expect ("0")
     :eval sym :volatile nil
     :note nil)
    (:name "cheight" :category internals
     :args "(a, prec?)"
     :desc "Total height in lines of A's printed form under the current
display language -- a layout metric for Calc's composition engine.
The wrapper's normal language renders `a / b' flat, so its height
is 1; multi-line output only arises in languages like Big mode.
Rarely useful outside custom display code."
     :arg-docs (("a" . "Formula whose printed form is measured") ("prec" . "Optional; surrounding operator precedence for the composition"))
     :returns "Height of the printed form, in lines"
     :examples ("cheight(a / b)")
     :expect ("1")
     :eval sym :volatile nil
     :note "A bare number as A trips an internal type check (the function
inspects the head of a composite argument), so the call stays
unevaluated on atoms -- pass a formula.")
    (:name "cwidth" :category internals
     :args "(a, prec?)"
     :desc "Width in characters of A's printed form under the current
display language -- `a + b' composes to five characters.  A layout
metric for Calc's composition (display) engine; rarely useful
outside custom display code."
     :arg-docs (("a" . "Formula whose printed form is measured") ("prec" . "Optional; surrounding operator precedence for the composition"))
     :returns "Width of the printed form, in characters"
     :examples ("cwidth(a + b)")
     :expect ("5")
     :eval sym :volatile nil
     :note nil)
    (:name "evalv" :category internals
     :args "(x)"
     :desc "Evaluate X: apply Calc's default simplifications and substitute
the stored values of any variables.  The cmacs wrapper already
wraps every numeric evaluation in `evalv', so calling it explicitly
matters mainly inside larger symbolic forms or rewrite machinery."
     :arg-docs (("x" . "Expression to evaluate"))
     :returns "X fully evaluated"
     :examples ("evalv(2 + 3)")
     :expect ("5")
     :eval num :volatile nil
     :note nil)
    (:name "evalvn" :category internals
     :args "(x, prec?)"
     :desc "Evaluate X numerically: like `evalv' but forcing symbolic
constants and exact forms to floats.  PREC selects a working
precision -- an integer sets it absolutely, while a one-element
vector like `[-2]' adjusts it relative to the current precision.
Results computed at higher precision are rounded back to the
display precision afterward."
     :arg-docs (("x" . "Expression to evaluate") ("prec" . "Optional; working precision: an integer, or [n] for relative"))
     :returns "X evaluated to a numeric result"
     :examples ("evalvn(pi)" "evalvn(pi - 3.1415, 30)")
     :expect ("3.14159265359" "9.26535897932e-5")
     :eval num :volatile nil
     :note nil)
    )
  "One plist per GNU Calc built-in; see the Commentary for the schema.")


;;; Shared helpers

(defun cmacs-calc-builtins--eval (entry example)
  "Evaluate EXAMPLE on the path ENTRY's :eval selects; return the string."
  (if (eq (plist-get entry :eval) 'sym)
      (cmacs-calculator-eval-symbolic example)
    (cmacs-calculator-eval example)))

(defun cmacs-calc-builtins--arg-names (args)
  "Argument names in the display signature ARGS, markers stripped."
  (let ((inner (string-trim args "(" ")")))
    (if (string-empty-p (string-trim inner)) nil
      (mapcar (lambda (a)
                (string-remove-suffix
                 "?" (string-remove-suffix "..." (string-trim a))))
              (split-string inner "," t)))))

(defun cmacs-calc-builtins--calc-builtin-names ()
  "Every function name GNU Calc itself defines, sorted.
Must be called before any calculator family is loaded, so the bound
`calcFunc-' set is pure Calc."
  (require 'calc-ext)
  (calc-load-everything)
  (let (names)
    (mapatoms
     (lambda (s)
       (let ((n (symbol-name s)))
         (when (and (fboundp s) (string-prefix-p "calcFunc-" n))
           (push (substring n 9) names)))))
    (sort names #'string<)))


;;; Verification

(defun cmacs-calc-builtins--schema-errors ()
  "Validate the static shape of the data; return a list of error strings."
  (let ((cats (mapcar #'car cmacs-calc-builtins--categories))
        (seen (make-hash-table :test 'equal))
        errors)
    (dolist (e cmacs-calc-builtins--entries)
      (let ((name (plist-get e :name)))
        (when (gethash name seen)
          (push (format "%s: duplicate entry" name) errors))
        (puthash name t seen)
        (unless (memq (plist-get e :category) cats)
          (push (format "%s: unknown category %s" name
                        (plist-get e :category))
                errors))
        (unless (memq (plist-get e :eval) '(num sym))
          (push (format "%s: bad :eval %S" name (plist-get e :eval)) errors))
        (dolist (key '(:args :desc :returns))
          (unless (and (stringp (plist-get e key))
                       (not (string-empty-p (plist-get e key))))
            (push (format "%s: missing %s" name key) errors)))
        (unless (consp (plist-get e :examples))
          (push (format "%s: no examples" name) errors))
        (unless (= (length (plist-get e :examples))
                   (length (plist-get e :expect)))
          (push (format "%s: :expect length mismatch" name) errors))
        (let ((sig (cmacs-calc-builtins--arg-names (plist-get e :args)))
              (docs (mapcar #'car (plist-get e :arg-docs))))
          (unless (equal sig docs)
            (push (format "%s: :args %S vs :arg-docs %S" name sig docs)
                  errors)))))
    errors))

(defun cmacs-calc-builtins-verify ()
  "Verify schema, coverage against live Calc, and every example.
Exits non-zero on any failure; for batch use."
  (let ((errors (cmacs-calc-builtins--schema-errors))
        (builtins (cmacs-calc-builtins--calc-builtin-names))
        (documented (sort (mapcar (lambda (e) (plist-get e :name))
                                  cmacs-calc-builtins--entries)
                          #'string<))
        (n 0))
    (let ((missing (cl-set-difference builtins documented :test #'equal))
          (extra (cl-set-difference documented builtins :test #'equal)))
      (when missing
        (push (format "undocumented Calc built-ins: %S" missing) errors))
      (when extra
        (push (format "documented but not defined by Calc: %S" extra)
              errors)))
    (dolist (e cmacs-calc-builtins--entries)
      (let ((name (plist-get e :name))
            (expects (plist-get e :expect))
            (i 0))
        (dolist (ex (plist-get e :examples))
          (setq n (1+ n))
          (condition-case err
              (let ((res (cmacs-calc-builtins--eval e ex))
                    (want (nth i expects)))
                (when (and want (not (plist-get e :volatile))
                           (not (equal res want)))
                  (push (format "%s: %s => %S, recorded %S" name ex res want)
                        errors)))
            (error
             (push (format "%s: %s signalled %S" name ex err) errors)))
          (setq i (1+ i)))))
    (if errors
        (progn
          (dolist (err (nreverse errors)) (message "FAIL %s" err))
          (message "cmacs-calc-builtins-verify: %d failure(s)" (length errors))
          (kill-emacs 1))
      (message "cmacs-calc-builtins-verify: OK -- %d entries, %d examples"
               (length cmacs-calc-builtins--entries) n))))


;;; Generation

(defun cmacs-calc-builtins--org-markup (s)
  "Render docstring-style `quoting' in S as org =verbatim=."
  (replace-regexp-in-string "`\\([^']+\\)'" "=\\1=" s t))

(defun cmacs-calc-builtins--texi-markup (s)
  "Escape S for texinfo and render `quoting' as @code{}.
FIXEDCASE is essential: an upper-case match would otherwise
case-convert the replacement into an unknown @CODE command."
  (let ((esc (replace-regexp-in-string "\\([@{}]\\)" "@\\1" s t)))
    (replace-regexp-in-string "`\\([^']+\\)'" "@code{\\1}" esc t)))

(defun cmacs-calc-builtins--grouped ()
  "Entries grouped by category, both in document order.
Returns a list of (KEY TITLE ENTRIES...)."
  (mapcar (lambda (cat)
            (append cat
                    (cl-remove-if-not
                     (lambda (e) (eq (plist-get e :category) (car cat)))
                     cmacs-calc-builtins--entries)))
          cmacs-calc-builtins--categories))

(defun cmacs-calc-builtins--results ()
  "Evaluate every example; return hash of (NAME . EXAMPLE) -> output.
Signals on the first failure -- run `cmacs-calc-builtins-verify' first."
  (let ((results (make-hash-table :test 'equal)))
    (dolist (e cmacs-calc-builtins--entries)
      (dolist (ex (plist-get e :examples))
        (puthash (cons (plist-get e :name) ex)
                 (cmacs-calc-builtins--eval e ex)
                 results)))
    results))

(defun cmacs-calc-builtins--trim-final-newlines ()
  "Leave exactly one newline at the end of the current buffer.
The commit hook rejects blank lines at EOF."
  (goto-char (point-max))
  (skip-chars-backward "\n")
  (delete-region (point) (point-max))
  (insert "\n"))

(defun cmacs-calc-builtins--write-org (grouped results file)
  "Write the org catalog for GROUPED entries with RESULTS to FILE."
  (with-temp-file file
    (insert "#+TITLE: CMacs Calculator — GNU Calc Built-ins\n"
            "#+AUTHOR: Zach Podbielniak\n"
            "#+OPTIONS: toc:2 num:nil\n"
            "# SPDX-License-Identifier: AGPL-3.0-or-later\n"
            "# Generated by admin/cmacs-calc-builtins-catalog.el."
            "  Edit the data there, then regenerate.\n\n"
            (format
             "Every GNU Calc algebraic function is callable from calculator
expressions: the strict validator checks a name against Calc itself,
not a whitelist, so the %d built-ins below compose freely with the
[[file:catalog.org][cmacs calculators]] in any expression -- from a sheet, the REPL, inline
=C-c ==, and =emacs --calc=.  Each example is *real output* from the
engine under the corrected semantics of [[file:index.org][the guide]]: radians, standard
=/= precedence, 12-digit float display.  A trailing =?= marks an
optional argument, =...= a function taking any number of arguments.
For =pi=, =e=, =i= and the CODATA physical constants, see
[[file:constants.org][the constants reference]].\n\n"
             (length cmacs-calc-builtins--entries)))
    (dolist (group grouped)
      (let ((title (nth 1 group))
            (entries (cddr group)))
        (insert (format "* %s (%d)\n\n" title (length entries)))
        (dolist (e entries)
          (let ((name (plist-get e :name)))
            (insert (format "** =%s%s=\n" name (plist-get e :args))
                    (cmacs-calc-builtins--org-markup (plist-get e :desc))
                    "\n\n")
            (when (plist-get e :arg-docs)
              (dolist (ad (plist-get e :arg-docs))
                (insert (format "- =%s= :: %s\n" (car ad)
                                (cmacs-calc-builtins--org-markup (cdr ad)))))
              (insert "\n"))
            (insert "Returns :: "
                    (cmacs-calc-builtins--org-markup (plist-get e :returns))
                    "\n\n")
            (when (plist-get e :note)
              (insert (cmacs-calc-builtins--org-markup (plist-get e :note))
                      "\n\n"))
            (dolist (ex (plist-get e :examples))
              (insert (format ": %s  ⇒  %s\n" ex
                              (gethash (cons name ex) results))))
            (insert "\n")))))
    (cmacs-calc-builtins--trim-final-newlines)))

(defun cmacs-calc-builtins--write-texi (grouped results file)
  "Write the texinfo catalog for GROUPED entries with RESULTS to FILE."
  (with-temp-file file
    (insert "@c Generated by admin/cmacs-calc-builtins-catalog.el."
            "  Do not edit by hand;\n"
            "@c edit the data there and rerun cmacs-calc-builtins-generate.\n"
            "@node Calculator Builtins\n"
            "@section Built-in Function Catalog\n\n"
            "@cindex built-in functions\n"
            "@cindex GNU Calc built-ins\n\n"
            (format
             "Every GNU Calc algebraic function is callable from calculator
expressions: the strict validator checks a name against Calc itself, not
a whitelist, so the %d built-ins below compose freely with the cmacs
calculators of @ref{Calculator Catalog} in any expression --- from a
sheet, the REPL, inline @kbd{C-c =}, and @code{emacs --calc}.  Each
example is @emph{real output} from the engine under the corrected
semantics of @ref{Calculator Semantics}: radians, standard @code{/}
precedence, 12-digit float display.  A trailing @code{?} marks an
optional argument, @code{...} a function taking any number of
arguments.  For @code{pi}, @code{e}, @code{i} and the CODATA physical
constants, see @ref{Calculator Constants}.\n\n"
             (length cmacs-calc-builtins--entries)))
    (dolist (group grouped)
      (let ((title (nth 1 group))
            (entries (cddr group)))
        (insert (format "@subsection %s\n\n@table @code\n\n" title))
        (dolist (e entries)
          (let ((name (plist-get e :name)))
            (insert (format "@item %s%s\n" name (plist-get e :args))
                    (cmacs-calc-builtins--texi-markup (plist-get e :desc))
                    "\n\n")
            (when (plist-get e :arg-docs)
              (insert "@table @code\n")
              (dolist (ad (plist-get e :arg-docs))
                (insert (format "@item %s\n%s\n" (car ad)
                                (cmacs-calc-builtins--texi-markup (cdr ad)))))
              (insert "@end table\n\n"))
            (insert "Returns: "
                    (cmacs-calc-builtins--texi-markup (plist-get e :returns))
                    "\n\n")
            (when (plist-get e :note)
              (insert (cmacs-calc-builtins--texi-markup (plist-get e :note))
                      "\n\n"))
            (insert "@example\n")
            (dolist (ex (plist-get e :examples))
              (insert (format "%s  =>  %s\n"
                              (cmacs-calc-builtins--texi-markup ex)
                              (cmacs-calc-builtins--texi-markup
                               (gethash (cons name ex) results)))))
            (insert "@end example\n\n")))
        (insert "@end table\n\n")))
    (cmacs-calc-builtins--trim-final-newlines)))

(defun cmacs-calc-builtins-generate ()
  "Re-evaluate every example and write both catalog files."
  (let ((grouped (cmacs-calc-builtins--grouped))
        (results (cmacs-calc-builtins--results)))
    (cmacs-calc-builtins--write-org
     grouped results
     (expand-file-name "doc_org/cmacs/calculator/builtins.org"
                       cmacs-calc-builtins--root))
    (cmacs-calc-builtins--write-texi
     grouped results
     (expand-file-name "doc/cmacs/calculator/builtins.texi"
                       cmacs-calc-builtins--root))
    (message "cmacs-calc-builtins-generate: wrote builtins.org + builtins.texi (%d entries)"
             (length cmacs-calc-builtins--entries))))


;;; Completion list

(defun cmacs-calc-builtins-completion-list ()
  "Print the defconst for `cmacs-calculator-sheet--calc-functions'."
  (let ((names (sort (mapcar (lambda (e) (plist-get e :name))
                             cmacs-calc-builtins--entries)
                     #'string<))
        (col 3))
    (princ "(defconst cmacs-calculator-sheet--calc-functions\n  '(")
    (setq col 4)
    (let ((first t))
      (dolist (name names)
        (let ((s (format "%S" name)))
          (cond
           (first (setq first nil))
           ((> (+ col 1 (length s)) 78)
            (princ "\n    ")
            (setq col 4))
           (t (princ " ") (setq col (1+ col))))
          (princ s)
          (setq col (+ col (length s))))))
    (princ ")\n")
    (princ "  \"Every GNU Calc built-in function, one name per calcFunc-.
Generated by admin/cmacs-calc-builtins-catalog.el (M-x
cmacs-calc-builtins-completion-list); regenerate there after an
upstream merge changes Calc.  The registry covers what cmacs adds;
this covers what Calc already had, so completion and font-lock do
not pretend `sqrt' is unknown.\")\n")))

;;; LSP data table (emacs --cmacs-lsp gnucalc)

(defconst cmacs-calc-builtins--lsp-constants
  '(("e"     . "Euler's number, the base of natural logarithms, 2.71828182846.")
    ("gamma" . "The Euler-Mascheroni constant, 0.577215664902.")
    ("i"     . "The imaginary unit: i^2 = -1.")
    ("inf"   . "Positive infinity.")
    ("nan"   . "Indeterminate result (not a number).")
    ("phi"   . "The golden ratio, (1 + sqrt(5))/2, 1.61803398875.")
    ("pi"    . "The ratio of a circle's circumference to its diameter, 3.14159265359.")
    ("uinf"  . "Infinity of unknown direction."))
  "Docs for the symbolic constants, sorted by name.
The generator errors if the key set drifts from
`cmacs-calculator--constants' (the validator's whitelist).")

(defun cmacs-calc-builtins--md-markup (s)
  "Render docstring-style `quoting' in S as markdown `code`."
  (replace-regexp-in-string "`\\([^']+\\)'" "`\\1`" s t))

(defun cmacs-calc-builtins--c-string (s indent)
  "Render S as adjacent C string literals, each line at column INDENT.
Escapes backslash, quote, newline and tab; splits long strings across
adjacent literals (concatenated by the compiler) so the generated file
stays diffable."
  (let ((pad (make-string indent ?\s))
        (lines nil)
        (cur ""))
    (dolist (ch (string-to-list s))
      (let ((tok (pcase ch
                   (?\\ "\\\\")
                   (?\" "\\\"")
                   (?\n "\\n")
                   (?\t "\\t")
                   (_ (char-to-string ch)))))
        (when (> (+ (length cur) (length tok)) 68)
          (push cur lines)
          (setq cur ""))
        (setq cur (concat cur tok))))
    (push cur lines)
    (mapconcat (lambda (l) (concat pad "\"" l "\""))
               (nreverse lines) "\n")))

(defun cmacs-calc-builtins--lsp-examples (pairs)
  "Markdown example block for PAIRS, a list of (EXPR . RESULT-or-nil)."
  (when pairs
    (concat "\n\n```\n"
            (mapconcat (lambda (p)
                         (if (cdr p)
                             (format "%s  ⇒  %s" (car p) (cdr p))
                           (car p)))
                       pairs "\n")
            "\n```")))

(defun cmacs-calc-builtins--lsp-sig-info (args)
  "Parse a display signature ARGS: return (N-ARGS N-REQUIRED REST-P).
A trailing `?' marks an optional argument, `...' a &rest tail."
  (let* ((inner (string-trim (string-trim args "(" ")")))
         (parts (and (not (string-empty-p inner))
                     (mapcar #'string-trim (split-string inner "," t))))
         (n (length parts))
         (required 0)
         (seen-opt nil))
    (dolist (p parts)
      (if (string-suffix-p "?" (string-remove-suffix "..." p))
          (setq seen-opt t)
        (unless seen-opt
          (setq required (1+ required)))))
    (list n required
          (and parts (string-suffix-p "..." (car (last parts))) t))))

(defun cmacs-calc-builtins--lsp-model ()
  "Unified entry plists for the gnucalc LSP data table, in emitted order.
Each entry: (:name :kind :category :args :detail :arg-docs
:n-required :rest), where :kind is the C enum suffix string, :args and
:arg-docs may be nil, and :arg-docs is a list of (NAME . DOC).
Returns (ENTRIES . SKIPPED-UNIT-NAMES)."
  (let ((entries nil)
        (skipped nil))
    ;; Built-ins, from the catalog.
    (dolist (e (sort (copy-sequence cmacs-calc-builtins--entries)
                     (lambda (a b) (string< (plist-get a :name)
                                            (plist-get b :name)))))
      (let* ((cat (cadr (assq (plist-get e :category)
                              cmacs-calc-builtins--categories)))
             (detail
              (concat
               (cmacs-calc-builtins--md-markup (plist-get e :desc))
               "\n\n**Returns:** "
               (cmacs-calc-builtins--md-markup (plist-get e :returns))
               (when (plist-get e :note)
                 (concat "\n\n**Note:** "
                         (cmacs-calc-builtins--md-markup
                          (plist-get e :note))))
               (cmacs-calc-builtins--lsp-examples
                (cl-mapcar #'cons (plist-get e :examples)
                           (plist-get e :expect))))))
        (push (append (list :name (plist-get e :name)
                            :kind "BUILTIN"
                            :category cat
                            :args (plist-get e :args)
                            :detail detail
                            :arg-docs (plist-get e :arg-docs))
                      (let ((sig (cmacs-calc-builtins--lsp-sig-info
                                  (plist-get e :args))))
                        (list :n-required (nth 1 sig) :rest (nth 2 sig))))
              entries)))
    ;; Registered cmacs calculators.  `cmacs-calculator-list' loads the
    ;; families and sorts by name.
    (dolist (c (cmacs-calculator-list))
      (let* ((arg-docs (mapcar (lambda (a)
                                 (cons (symbol-name (car a)) (cadr a)))
                               (plist-get c :args)))
             (args (concat "(" (mapconcat #'car arg-docs ", ") ")"))
             (detail
              (concat
               "**" (plist-get c :title) "**\n\n"
               (cmacs-calc-builtins--md-markup (or (plist-get c :doc) ""))
               "\n\n**Returns:** "
               (cmacs-calc-builtins--md-markup
                (or (plist-get c :returns) ""))
               (cmacs-calc-builtins--lsp-examples (plist-get c :examples)))))
        (push (list :name (symbol-name (plist-get c :name))
                    :kind "DEFCALC"
                    :category (symbol-name (plist-get c :category))
                    :args args
                    :detail detail
                    :arg-docs arg-docs
                    :n-required (length arg-docs)
                    :rest nil)
              entries)))
    ;; Symbolic constants.
    (let ((want (sort (mapcar #'symbol-name cmacs-calculator--constants)
                      #'string<))
          (have (mapcar #'car cmacs-calc-builtins--lsp-constants)))
      (unless (equal want have)
        (error "LSP constants drift: registry %S vs docs %S" want have)))
    (dolist (c cmacs-calc-builtins--lsp-constants)
      (push (list :name (car c) :kind "CONSTANT" :category "Constants"
                  :args nil :detail (cdr c) :arg-docs nil
                  :n-required 0 :rest nil)
            entries))
    ;; Calc units.  Only identifier-shaped names -- the non-ASCII ones
    ;; (α, Ω, μ0, ...) all have ASCII aliases that are kept.
    (require 'calc-units)
    (dolist (u (sort (copy-sequence math-standard-units)
                     (lambda (a b) (string< (symbol-name (car a))
                                            (symbol-name (car b))))))
      (let ((name (symbol-name (nth 0 u)))
            (def (nth 1 u))
            (desc (nth 2 u)))
        (if (not (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" name))
            (push name skipped)
          (push (list :name name :kind "UNIT" :category "Units"
                      :args nil
                      :detail
                      (concat (string-remove-prefix "*" (or desc name))
                              (when def
                                (format "\n\nDefinition: `%s`" def))
                              "\n\nCalc unit; SI prefix letters generally"
                              " apply (k, M, m, u, ...).")
                      :arg-docs nil :n-required 0 :rest nil)
                entries))))
    (cons (nreverse entries) (nreverse skipped))))

(defun cmacs-calc-builtins--lsp-data-string ()
  "The complete generated cmacs-lsp-gnucalc-data.h as a string."
  (let* ((model (cmacs-calc-builtins--lsp-model))
         (entries (car model))
         (out nil)
         (idx 0))
    (push "\
/* cmacs-lsp-gnucalc-data.h --- GENERATED gnucalc language-server data

Copyright (C) 2026 Zach Podbielniak

SPDX-License-Identifier: AGPL-3.0-or-later

This file is part of CMacs.

Generated by admin/cmacs-calc-builtins-catalog.el
(cmacs-calc-builtins-generate-lsp-data); do not edit by hand.
Regenerate from the repo root:

  src/emacs -Q -batch -L lisp/cmacs -L admin \\
    -l cmacs-calc-builtins-catalog -f cmacs-calc-builtins-generate-lsp-data

Included by exactly one TU: cmacs/lsp/cmacs-lsp-gnucalc.c.  */

#ifndef CMACS_LSP_GNUCALC_DATA_H
#define CMACS_LSP_GNUCALC_DATA_H

#include <stddef.h>

typedef enum
{
  CMACS_LSP_GNUCALC_BUILTIN,
  CMACS_LSP_GNUCALC_DEFCALC,
  CMACS_LSP_GNUCALC_CONSTANT,
  CMACS_LSP_GNUCALC_UNIT
} CmacsLspGnucalcKind;

typedef struct
{
  const char *name;
  const char *doc;
} CmacsLspGnucalcArg;

typedef struct
{
  const char *name;
  CmacsLspGnucalcKind kind;
  const char *category;         /* display string */
  const char *args;             /* \"(a, b?)\", NULL for constants/units */
  const char *detail;           /* pre-rendered markdown body */
  const CmacsLspGnucalcArg *arg_docs;   /* NULL when no documented args */
  unsigned int n_args;
  unsigned char n_required;     /* args before the first optional */
  unsigned char rest;           /* signature ends with \"...\" */
} CmacsLspGnucalcEntry;
" out)
    ;; Per-entry argument arrays.
    (dolist (e entries)
      (when (plist-get e :arg-docs)
        (push (format "\nstatic const CmacsLspGnucalcArg %s[] =\n{\n%s\n};\n"
                      (format "cmacs_lsp_gnucalc_args_%d" idx)
                      (mapconcat
                       (lambda (ad)
                         (format "  { %s,\n%s },"
                                 (concat "\"" (car ad) "\"")
                                 (cmacs-calc-builtins--c-string (cdr ad) 4)))
                       (plist-get e :arg-docs) "\n"))
              out))
      (setq idx (1+ idx)))
    ;; The entry table.
    (push "\nstatic const CmacsLspGnucalcEntry cmacs_lsp_gnucalc_entries[] =\n{\n"
          out)
    (setq idx 0)
    (dolist (e entries)
      (push (format "  { \"%s\", CMACS_LSP_GNUCALC_%s,\n%s,\n%s,\n%s,\n    %s, %d, %d, %d },\n"
                    (plist-get e :name)
                    (plist-get e :kind)
                    (cmacs-calc-builtins--c-string (plist-get e :category) 4)
                    (if (plist-get e :args)
                        (cmacs-calc-builtins--c-string (plist-get e :args) 4)
                      "    NULL")
                    (cmacs-calc-builtins--c-string (plist-get e :detail) 4)
                    (if (plist-get e :arg-docs)
                        (format "cmacs_lsp_gnucalc_args_%d" idx)
                      "NULL")
                    (length (plist-get e :arg-docs))
                    (plist-get e :n-required)
                    (if (plist-get e :rest) 1 0))
            out)
      (setq idx (1+ idx)))
    (push "};\n
static const size_t cmacs_lsp_gnucalc_n_entries =
  sizeof cmacs_lsp_gnucalc_entries / sizeof cmacs_lsp_gnucalc_entries[0];

#endif /* CMACS_LSP_GNUCALC_DATA_H */\n" out)
    (apply #'concat (nreverse out))))

(defun cmacs-calc-builtins-generate-lsp-data ()
  "Write cmacs/lsp/cmacs-lsp-gnucalc-data.h from the catalog + registry."
  (let ((file (expand-file-name "cmacs/lsp/cmacs-lsp-gnucalc-data.h"
                                cmacs-calc-builtins--root))
        (model (cmacs-calc-builtins--lsp-model)))
    (with-temp-file file
      (insert (cmacs-calc-builtins--lsp-data-string)))
    (message
     "cmacs-calc-builtins-generate-lsp-data: wrote %s (%d entries%s)"
     file (length (car model))
     (if (cdr model)
         (format "; skipped non-identifier units %S" (cdr model))
       ""))))

(provide 'cmacs-calc-builtins-catalog)

;;; cmacs-calc-builtins-catalog.el ends here
