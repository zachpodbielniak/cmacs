;;; cmacs-calculator-tests.el --- Tests for cmacs-calculator -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the CMacs calculator.
;;
;; Almost everything here is pure computation, so it runs headlessly in any
;; build with no display, no GL and no network.  The GPU chart tier is the one
;; exception and skips itself when there is no display.
;;
;; The first section is the most important: GNU Calc's defaults are wrong for
;; a desktop calculator, and the engine exists to correct them.  Each of those
;; corrections gets a regression test with the stock-Calc answer named in the
;; comment, because a silent revert would produce plausible-looking numbers
;; rather than an obvious failure.

;;; Code:

(require 'ert)
(require 'cmacs-calculator nil t)
(require 'cmacs-calculator-financial nil t)
(require 'cmacs-calculator-physics nil t)
(require 'cmacs-calculator-tax-data nil t)
(require 'cmacs-calculator-chart nil t)
(require 'cmacs-calculator-menu nil t)

(defmacro cmacs-calculator-tests--skip-unless-loaded ()
  "Skip the test unless `cmacs-calculator' loaded."
  '(skip-unless (featurep 'cmacs-calculator)))

(defmacro cmacs-calculator-tests--skip-unless-financial ()
  "Skip the test unless the financial family loaded."
  '(skip-unless (featurep 'cmacs-calculator-financial)))

(defmacro cmacs-calculator-tests--skip-unless-physics ()
  "Skip the test unless the physics family loaded."
  '(skip-unless (featurep 'cmacs-calculator-physics)))

(defmacro cmacs-calculator-tests--skip-unless-tax ()
  "Skip the test unless the tax family loaded."
  '(skip-unless (featurep 'cmacs-calculator-tax-data)))

(defun cmacs-calculator-tests--close (a b &optional tolerance)
  "Return non-nil if floats A and B agree within TOLERANCE (default 1e-6).
Relative for large values, absolute near zero."
  (let ((tolerance (or tolerance 1e-6)))
    (< (abs (- a b)) (* tolerance (max 1.0 (abs a) (abs b))))))

(defun cmacs-calculator-tests--num (expr)
  "Evaluate EXPR and return it as a float."
  (cmacs-calculator-eval-number expr))


;;; The five corrections to GNU Calc's defaults
;;
;; Every one of these returns a different, plausible number under stock Calc.

(ert-deftest cmacs-calculator-tests-trap-division-precedence ()
  "Division and multiplication associate left to right.
Stock Calc binds `*' tighter than `/', making 2/3*4 mean 2/(3*4) =
0.1667 and sqrt(5/3*3^4) = 0.1434."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "sqrt(5/3*3^4)") 11.6189500386 1e-9))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "2/3*4") 2.66666666667 1e-9))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "10/2/5") 1.0 1e-9))
  ;; The fix must not turn `^' into XOR, which is what calc-language `c'
  ;; would have done had it been used to fix precedence.
  (should (= (cmacs-calculator-tests--num "2^10") 1024.0)))

(ert-deftest cmacs-calculator-tests-trap-angle-mode ()
  "Trigonometry is in radians.  Stock Calc defaults to degrees, where
sin(90) is 1."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "sin(pi/2)") 1.0 1e-9))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "cos(0)") 1.0 1e-9))
  (should (cmacs-calculator-tests--close
           (abs (cmacs-calculator-tests--num "sin(pi)")) 0.0 1e-9))
  ;; sin(90) radians is NOT 1.
  (should-not (cmacs-calculator-tests--close
               (cmacs-calculator-tests--num "sin(90)") 1.0 1e-6)))

(ert-deftest cmacs-calculator-tests-trap-symbolic-folding ()
  "Symbolic constants fold to numbers.  Stock Calc leaves sin(pi/2) as
`sin(pi / 2)'."
  (cmacs-calculator-tests--skip-unless-loaded)
  ;; Euler's identity exercises folding, complex numbers and radians at once.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "e^(i*pi)") -1.0 1e-9))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "ln(e)") 1.0 1e-9)))

(ert-deftest cmacs-calculator-tests-trap-mode-override-takes-effect ()
  "Explicit mode overrides reach Calc.
`calc-eval' rebinds the mode variables internally, so an enclosing `let'
is silently ignored -- the modes have to travel in its list argument."
  (cmacs-calculator-tests--skip-unless-loaded)
  (let ((s (cmacs-calculator-eval "sqrt(2)" '(calc-internal-prec 30))))
    (should (string-prefix-p "1.41421356237309504880168872421" s)))
  ;; Degrees on request.
  (should (cmacs-calculator-tests--close
           (string-to-number
            (cmacs-calculator-eval "sin(90)" '(calc-angle-mode deg)))
           1.0 1e-9)))

(ert-deftest cmacs-calculator-tests-trap-strictness ()
  "Bad input signals.  Stock Calc returns it unevaluated: `foo(1)' comes
back as \"foo(1)\", and \"((1+2)\" is silently accepted as 3."
  (cmacs-calculator-tests--skip-unless-loaded)
  ;; Unbalanced delimiters.
  (should-error (cmacs-calculator-eval "((1+2)")
                :type 'cmacs-calculator-syntax-error)
  (should-error (cmacs-calculator-eval "1+2)")
                :type 'cmacs-calculator-syntax-error)
  ;; Unknown function.
  (should-error (cmacs-calculator-eval "foo(1)")
                :type 'cmacs-calculator-unknown-function)
  ;; Unbound variable in numeric evaluation.
  (should-error (cmacs-calculator-eval "x+1")
                :type 'cmacs-calculator-unbound-variable)
  ;; Empty and malformed input.
  (should-error (cmacs-calculator-eval "") :type 'cmacs-calculator-error)
  (should-error (cmacs-calculator-eval "   ") :type 'cmacs-calculator-error)
  (should-error (cmacs-calculator-eval "2+") :type 'cmacs-calculator-error))

(ert-deftest cmacs-calculator-tests-modes-do-not-leak ()
  "Evaluating must not change stock Calc's global mode variables.

`calc-do-calc-eval' applies its mode list with a plain `set' and relies
on an enclosing `let' to undo it -- but that `let' does not name
`calc-multiplication-has-precedence', so an unguarded call flips it
globally and forever, and the user's own \\[calc] silently inherits our
corrected precedence.  cmacs must not reach out and change how upstream
Calc behaves."
  (cmacs-calculator-tests--skip-unless-loaded)
  (let ((before (list calc-multiplication-has-precedence
                      calc-angle-mode
                      calc-internal-prec
                      calc-infinite-mode
                      calc-symbolic-mode
                      calc-language)))
    (cmacs-calculator-eval "2/3*4")
    (cmacs-calculator-eval "sin(pi/2)")
    (cmacs-calculator-eval "sqrt(2)" '(calc-internal-prec 30))
    (cmacs-calculator-eval-symbolic "deriv(x^2,x)")
    (ignore-errors (cmacs-calculator-eval "foo(1)"))
    (should (equal before
                   (list calc-multiplication-has-precedence
                         calc-angle-mode
                         calc-internal-prec
                         calc-infinite-mode
                         calc-symbolic-mode
                         calc-language)))))

(ert-deftest cmacs-calculator-tests-first-eval-is-correct ()
  "The very first evaluation in a session already has the right operator
table.  The mode list is applied after Calc has computed
`math-expr-opers', so a first call could in principle parse with the old
precedence and only appear correct once the global had leaked -- which
is exactly what stopping the leak could have exposed."
  (cmacs-calculator-tests--skip-unless-loaded)
  (let ((calc-multiplication-has-precedence t))
    (should (cmacs-calculator-tests--close
             (cmacs-calculator-tests--num "2/3*4") 2.66666666667 1e-9))))

(ert-deftest cmacs-calculator-tests-strict-can-be-disabled ()
  "With `cmacs-calculator-strict' nil, Calc's permissive behaviour returns."
  (cmacs-calculator-tests--skip-unless-loaded)
  (let ((cmacs-calculator-strict nil))
    (should (stringp (cmacs-calculator-eval "foo(1)")))))


;;; Numeric edge cases

(ert-deftest cmacs-calculator-tests-division-by-zero ()
  "Division by zero yields an infinity rather than being echoed back."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (equal (cmacs-calculator-eval "1/0") "uinf"))
  (should (equal (cmacs-calculator-eval "0/0") "nan"))
  (should (equal (cmacs-calculator-eval "ln(0)") "-inf"))
  ;; Not numbers, so they must not masquerade as one.
  (should-not (cmacs-calculator-eval-number "1/0"))
  (should-not (cmacs-calculator-eval-number "0/0")))

(ert-deftest cmacs-calculator-tests-complex-and-exact ()
  "Complex results and exact arithmetic survive."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (equal (cmacs-calculator-eval "sqrt(-4)") "(0, 2)"))
  ;; Complex is not a real number.
  (should-not (cmacs-calculator-eval-number "sqrt(-4)"))
  ;; Decimal arithmetic is exact, not binary-float lossy.
  (should (equal (cmacs-calculator-eval "0.1+0.2") "0.3"))
  (should (= (cmacs-calculator-tests--num "0^0") 1.0)))

(ert-deftest cmacs-calculator-tests-bignum ()
  "Arbitrary precision, not machine words."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (equal (cmacs-calculator-eval "2^64")
                 "18446744073709551616"))
  (should (= (length (cmacs-calculator-eval "1000!")) 2568))
  (should (string-prefix-p "1606938044258990275541962092341162602522202993782792835301376"
                           (cmacs-calculator-eval "2^200"))))

(ert-deftest cmacs-calculator-tests-precision-is-configurable ()
  "Precision is a knob, and a high setting really computes more digits."
  (cmacs-calculator-tests--skip-unless-loaded)
  (let ((cmacs-calculator-precision 50))
    (should (string-prefix-p
             "3.1415926535897932384626433832795028841971693993751"
             (cmacs-calculator-eval "evalv(pi)")))))

(ert-deftest cmacs-calculator-tests-number-parsing-is-strict ()
  "Non-numbers are reported as nil rather than coerced to 0."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (equal (cmacs-calculator-eval-number "2+2") 4.0))
  (should (equal (cmacs-calculator-eval-number "-1") -1.0))
  (should (equal (cmacs-calculator-eval-number "1e-6") 1e-6))
  ;; Always a float, never an integer -- callers do float-only arithmetic.
  (should (floatp (cmacs-calculator-eval-number "-1")))
  (should (floatp (cmacs-calculator-eval-number "2+2"))))

(ert-deftest cmacs-calculator-tests-deep-nesting ()
  "Deeply nested expressions do not blow up."
  (cmacs-calculator-tests--skip-unless-loaded)
  (let ((expr (concat (apply #'concat (make-list 50 "sqrt("))
                      "2"
                      (apply #'concat (make-list 50 ")")))))
    (should (cmacs-calculator-tests--close
             (cmacs-calculator-tests--num expr) 1.0 1e-9))))


;;; Symbolic algebra

(ert-deftest cmacs-calculator-tests-cas ()
  "The CAS path keeps free variables and returns symbolic results."
  (cmacs-calculator-tests--skip-unless-loaded)
  ;; Radians: in degrees this would gain a pi/180 factor.
  (should (equal (cmacs-calculator-eval-symbolic "deriv(x^3 + sin(x), x)")
                 "3 x^2 + cos(x)"))
  (should (equal (cmacs-calculator-eval-symbolic "integ(x^2, x)") "x^3 / 3"))
  (should (equal (cmacs-calculator-eval-symbolic "solve(x^2 - 4 = 0, x)")
                 "x = 2"))
  ;; Free variables are the point here, so they must not signal.
  (should (stringp (cmacs-calculator-eval-symbolic "x + 1"))))


;;; Units

(ert-deftest cmacs-calculator-tests-units ()
  "Unit conversion and CODATA constants.
Calc exposes only `usimplify' algebraically -- base-unit and unit
conversion are stack commands -- so these go through our own shim."
  (cmacs-calculator-tests--skip-unless-loaded)
  (should (equal (cmacs-calculator-to-base-units "2 km + 3 m") "2003 m"))
  (should (equal (cmacs-calculator-to-base-units "c") "299792458 m / s"))
  (should (cmacs-calculator-tests--close
           (string-to-number (cmacs-calculator-convert-units "60 mph" "m/s"))
           26.8224 1e-4))
  ;; Schwarzschild radius of the Sun; textbook value is about 2953 m.
  (should (cmacs-calculator-tests--close
           (string-to-number
            (cmacs-calculator-to-base-units "2 * G * 1.989e30 kg / c^2"))
           2954.13 1e-3)))


;;; Financial
;;
;; Checked against published reference values and, where possible, against
;; invariants -- an invariant is stronger evidence than a number I chose.

(ert-deftest cmacs-calculator-tests-interest ()
  (cmacs-calculator-tests--skip-unless-financial)
  (should (= (cmacs-calculator-tests--num "simpleint(1000, 0.05, 3)") 150.0))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "cagr(1000, 2000, 10)") 0.0717734625 1e-8))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "apr2apy(0.05, 12)") 0.0511618979 1e-8))
  ;; APR <-> APY round-trip.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "apy2apr(apr2apy(0.05, 12), 12)")
           0.05 1e-8))
  ;; compoundamt = principal + compoundint, by construction.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num
            "compoundamt(1000,0.05,12,10) - compoundint(1000,0.05,12,10)")
           1000.0 1e-6)))

(ert-deftest cmacs-calculator-tests-loans ()
  "A 300k loan at 6.5% over 30 years pays 1896.20/month."
  (cmacs-calculator-tests--skip-unless-financial)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "loanpmt(300000, 0.065, 30)")
           1896.20 1e-4))
  ;; total = principal + interest.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num
            "loantotal(300000,0.065,30) - loanint(300000,0.065,30)")
           300000.0 1e-3))
  ;; Zero interest: the payment is just principal/months.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "loanpmt(120000, 0, 10)") 1000.0 1e-9)))

(ert-deftest cmacs-calculator-tests-amortization ()
  "The schedule lands exactly on zero and agrees with the closed forms."
  (cmacs-calculator-tests--skip-unless-financial)
  (let* ((sched (cmacs-calculator-amortization 300000 0.065 30))
         (last (car (last sched))))
    (should (= (length sched) 360))
    ;; Exactly zero, not a rounding-drift residue.
    (should (= (plist-get last :balance) 0.0))
    ;; Cumulative interest ties to loanint.
    (should (cmacs-calculator-tests--close
             (plist-get last :cumulative-interest)
             (cmacs-calculator-tests--num "loanint(300000, 0.065, 30)")
             1e-6))
    ;; Balance is monotonically non-increasing.
    (let ((prev 300001.0))
      (dolist (row sched)
        (should (<= (plist-get row :balance) prev))
        (setq prev (plist-get row :balance))))
    ;; Interest falls and principal rises over the life of the loan.
    (should (< (plist-get (car (last sched)) :interest)
               (plist-get (car sched) :interest)))))

(ert-deftest cmacs-calculator-tests-amortization-extra-payment ()
  "Extra principal shortens the schedule and cuts total interest."
  (cmacs-calculator-tests--skip-unless-financial)
  (let ((plain (cmacs-calculator-amortization 300000 0.065 30))
        (extra (cmacs-calculator-amortization 300000 0.065 30 500)))
    (should (< (length extra) (length plain)))
    (should (= (plist-get (car (last extra)) :balance) 0.0))
    (should (< (plist-get (car (last extra)) :cumulative-interest)
               (plist-get (car (last plain)) :cumulative-interest)))))

(ert-deftest cmacs-calculator-tests-amortization-zero-rate ()
  "A zero-rate loan amortizes cleanly."
  (cmacs-calculator-tests--skip-unless-financial)
  (let ((sched (cmacs-calculator-amortization 12000 0 1)))
    (should (= (length sched) 12))
    (should (= (plist-get (car (last sched)) :balance) 0.0))
    (should (= (plist-get (car (last sched)) :cumulative-interest) 0.0))))

(ert-deftest cmacs-calculator-tests-bond-price-at-par ()
  "A bond priced at its coupon rate is worth par.  The standard check."
  (cmacs-calculator-tests--skip-unless-financial)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "bondprice(1000, 0.05, 0.05, 10, 2)")
           1000.0 1e-6))
  ;; Above par when the yield is below the coupon, below when above.
  (should (> (cmacs-calculator-tests--num "bondprice(1000, 0.05, 0.04, 10, 2)")
             1000.0))
  (should (< (cmacs-calculator-tests--num "bondprice(1000, 0.05, 0.06, 10, 2)")
             1000.0)))

(ert-deftest cmacs-calculator-tests-bond-ytm-roundtrip ()
  "Yield-to-maturity inverts pricing."
  (cmacs-calculator-tests--skip-unless-financial)
  (dolist (ytm '(0.03 0.05 0.06 0.09))
    (let ((price (cmacs-calculator--bond-price 1000 0.05 ytm 10 2)))
      (should (cmacs-calculator-tests--close
               (cmacs-calculator-bond-ytm 1000 0.05 price 10 2) ytm 1e-6))))
  ;; A price no yield can produce is an error, not a bracket endpoint.
  (should-error (cmacs-calculator-bond-ytm 1000 0.05 -5 10 2)
                :type 'cmacs-calculator-error))

(ert-deftest cmacs-calculator-tests-bond-duration ()
  "Duration and convexity behave as the theory says."
  (cmacs-calculator-tests--skip-unless-financial)
  (let ((d (cmacs-calculator-bond-duration 1000 0.05 0.06 10 2))
        (md (cmacs-calculator-bond-mduration 1000 0.05 0.06 10 2)))
    ;; Macaulay duration of a coupon bond is under its maturity.
    (should (and (> d 7.0) (< d 10.0)))
    ;; Modified = Macaulay / (1 + y/f).
    (should (cmacs-calculator-tests--close md (/ d 1.03) 1e-9))
    (should (> (cmacs-calculator-bond-convexity 1000 0.05 0.06 10 2) 0)))
  ;; A zero-coupon bond's Macaulay duration equals its maturity.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-bond-duration 1000 0 0.05 10 2) 10.0 1e-9)))

(ert-deftest cmacs-calculator-tests-black-scholes ()
  "Black-Scholes against the canonical at-the-money example."
  (cmacs-calculator-tests--skip-unless-financial)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "bscall(100, 100, 0.05, 0.2, 1)")
           10.4505835721 1e-9))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "bsput(100, 100, 0.05, 0.2, 1)")
           5.5735260223 1e-9))
  ;; d2 = d1 - sigma*sqrt(T).
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num
            "bsd1(100,100,0.05,0.2,1) - bsd2(100,100,0.05,0.2,1)")
           0.2 1e-9)))

(ert-deftest cmacs-calculator-tests-put-call-parity ()
  "Put-call parity: C - P = S - K*e^(-rT), for every strike."
  (cmacs-calculator-tests--skip-unless-financial)
  (dolist (k '(80 90 100 110 120))
    (let ((lhs (cmacs-calculator-tests--num
                (format "bscall(100,%d,0.05,0.2,1) - bsput(100,%d,0.05,0.2,1)" k k)))
          (rhs (cmacs-calculator-tests--num
                (format "100 - %d*exp(-0.05*1)" k))))
      (should (cmacs-calculator-tests--close lhs rhs 1e-8)))))

(ert-deftest cmacs-calculator-tests-greeks ()
  "The greeks, and the relations between them."
  (cmacs-calculator-tests--skip-unless-financial)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "bsgamma(100,100,0.05,0.2,1)")
           0.0187620173 1e-8))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "bsvega(100,100,0.05,0.2,1)")
           37.5240346917 1e-6))
  ;; Call delta - put delta = 1.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num
            "bscalldelta(100,100,0.05,0.2,1) - bsputdelta(100,100,0.05,0.2,1)")
           1.0 1e-9))
  ;; Deltas are bounded.
  (should (< 0 (cmacs-calculator-tests--num "bscalldelta(100,100,0.05,0.2,1)") 1))
  (should (< -1 (cmacs-calculator-tests--num "bsputdelta(100,100,0.05,0.2,1)") 0))
  ;; Long options decay.
  (should (< (cmacs-calculator-tests--num "bscalltheta(100,100,0.05,0.2,1)") 0)))

(ert-deftest cmacs-calculator-tests-implied-volatility ()
  "Implied volatility inverts Black-Scholes."
  (cmacs-calculator-tests--skip-unless-financial)
  (dolist (sigma '(0.1 0.2 0.45))
    (let ((price (cmacs-calculator--bs-price 'call 100 100 0.05 sigma 1)))
      (should (cmacs-calculator-tests--close
               (cmacs-calculator-implied-volatility 'call price 100 100 0.05 1)
               sigma 1e-4))))
  ;; Below intrinsic value is a no-arbitrage violation, and must be reported.
  (should-error (cmacs-calculator-implied-volatility 'call 0.0001 100 50 0.05 1)
                :type 'cmacs-calculator-error))

(ert-deftest cmacs-calculator-tests-binomial ()
  "The binomial lattice converges to Black-Scholes, and prices early exercise."
  (cmacs-calculator-tests--skip-unless-financial)
  ;; European call converges toward the closed form as steps grow.
  (let ((bs (cmacs-calculator-tests--num "bscall(100,100,0.05,0.2,1)"))
        (coarse (cmacs-calculator-binomial-option 'call 'european 100 100 0.05 0.2 1 10))
        (fine (cmacs-calculator-binomial-option 'call 'european 100 100 0.05 0.2 1 500)))
    (should (< (abs (- fine bs)) (abs (- coarse bs))))
    (should (< (abs (- fine bs)) 0.05)))
  ;; An American put is worth at least its European twin: early exercise has
  ;; value.  An American call on a non-dividend payer is worth the same.
  (let ((amer (cmacs-calculator-binomial-option 'put 'american 100 100 0.05 0.2 1 200))
        (euro (cmacs-calculator-binomial-option 'put 'european 100 100 0.05 0.2 1 200)))
    (should (> amer euro)))
  (let ((amer (cmacs-calculator-binomial-option 'call 'american 100 100 0.05 0.2 1 200))
        (euro (cmacs-calculator-binomial-option 'call 'european 100 100 0.05 0.2 1 200)))
    (should (cmacs-calculator-tests--close amer euro 1e-6)))
  (should-error (cmacs-calculator-binomial-option 'call 'european 100 100 0.05 0.2 1 0)
                :type 'cmacs-calculator-error))

(ert-deftest cmacs-calculator-tests-irr-dcf ()
  "IRR zeroes the NPV, and impossible flows are reported."
  (cmacs-calculator-tests--skip-unless-financial)
  (let* ((flows '(-1000 400 400 400))
         (irr (cmacs-calculator-irr flows)))
    (should (cmacs-calculator-tests--close irr 0.0970102574 1e-6))
    ;; The defining property.
    (should (< (abs (cmacs-calculator-dcf flows irr)) 1e-6)))
  ;; Flows that never change sign have no IRR; say so rather than guessing.
  (should-error (cmacs-calculator-irr '(100 200 300))
                :type 'cmacs-calculator-error)
  ;; Undiscounted NPV is just the sum.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-dcf '(-1000 400 400 400) 0.0) 200.0 1e-9)))

(ert-deftest cmacs-calculator-tests-retirement-drawdown ()
  "Drawdown reports depletion rather than running negative."
  (cmacs-calculator-tests--skip-unless-financial)
  (let ((ok (cmacs-calculator-retirement-drawdown 1000000 0.05 40000 30)))
    (should (= (length ok) 30))
    (should-not (plist-get (car (last ok)) :depleted))
    (should (> (plist-get (car (last ok)) :end) 0)))
  ;; Spending far beyond the return depletes the portfolio; it must be
  ;; flagged, and the balance must never go negative.
  (let ((broke (cmacs-calculator-retirement-drawdown 100000 0.01 50000 30)))
    (should (< (length broke) 30))
    (should (plist-get (car (last broke)) :depleted))
    (dolist (row broke)
      (should (>= (plist-get row :end) 0)))))


;;; Physics and relativity

(ert-deftest cmacs-calculator-tests-relativity ()
  "Relativistic quantities against known values."
  (cmacs-calculator-tests--skip-unless-physics)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "lorentz(0.9)") 2.29415733871 1e-9))
  ;; At rest, gamma is exactly 1.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "lorentz(0)") 1.0 1e-12))
  ;; Gamma grows without bound as v approaches c.
  (should (> (cmacs-calculator-tests--num "lorentz(0.999999)") 700))
  ;; Schwarzschild radius of the Sun; textbook value about 2953 m.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "schwarzschild(1.989e30)") 2954.13 1e-3)))

(ert-deftest cmacs-calculator-tests-relativity-rejects-superluminal ()
  "v >= c is rejected, not quietly turned into a complex number."
  (cmacs-calculator-tests--skip-unless-physics)
  (should-error (cmacs-calculator-eval "lorentz(1.5)")
                :type 'cmacs-calculator-error)
  (should-error (cmacs-calculator-eval "lorentz(1)")
                :type 'cmacs-calculator-error))

(ert-deftest cmacs-calculator-tests-physics ()
  "Mechanics against known values."
  (cmacs-calculator-tests--skip-unless-physics)
  ;; Escape velocity of Earth, about 11.19 km/s.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "escapevel(5.972e24, 6.371e6)")
           11185.98 1e-5))
  ;; A one-metre pendulum swings in about 2.006 s.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "pendulum(1)") 2.00640929259 1e-9))
  ;; 500 nm photon carries about 3.97e-19 J.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "photonenergywl(500e-9)")
           3.9728917143e-19 1e-6)))


;;; Tax

(ert-deftest cmacs-calculator-tests-tax-schema-valid ()
  "Every registered jurisdiction passes schema validation.
A malformed table must fail loudly here rather than quietly computing
the wrong tax."
  (cmacs-calculator-tests--skip-unless-tax)
  (skip-unless (fboundp 'cmacs-calculator-tax-validate))
  (let ((failures (cmacs-calculator-tax-validate)))
    (should (null failures))))

(ert-deftest cmacs-calculator-tests-tax-jurisdictions-present ()
  "Federal plus all fifty states are registered."
  (cmacs-calculator-tests--skip-unless-tax)
  (skip-unless (fboundp 'cmacs-calculator-tax-jurisdictions))
  (let ((js (cmacs-calculator-tax-jurisdictions)))
    (should (memq 'us-federal js))
    ;; 50 states + federal.
    (should (>= (length js) 51))))

(ert-deftest cmacs-calculator-tests-tax-brackets-are-progressive ()
  "The bracket walk is progressive: each rate applies only within its band.
The classic bug is applying the top rate to the whole income."
  (cmacs-calculator-tests--skip-unless-tax)
  (skip-unless (fboundp 'cmacs-calculator-tax-bracket-liability))
  (let ((brackets '((0 . 0.10) (10000 . 0.20) (50000 . 0.30))))
    ;; Wholly inside the first band.
    (should (cmacs-calculator-tests--close
             (cmacs-calculator-tax-bracket-liability 5000 brackets) 500.0 1e-9))
    ;; Exactly at a boundary.
    (should (cmacs-calculator-tests--close
             (cmacs-calculator-tax-bracket-liability 10000 brackets) 1000.0 1e-9))
    ;; Spanning two bands: 10000*0.10 + 10000*0.20 = 3000, NOT 20000*0.20.
    (should (cmacs-calculator-tests--close
             (cmacs-calculator-tax-bracket-liability 20000 brackets) 3000.0 1e-9))
    ;; Spanning all three: 1000 + 8000 + 15000 = 24000.
    (should (cmacs-calculator-tests--close
             (cmacs-calculator-tax-bracket-liability 100000 brackets) 24000.0 1e-9))
    ;; Degenerate income.
    (should (= (cmacs-calculator-tax-bracket-liability 0 brackets) 0))
    (should (= (cmacs-calculator-tax-bracket-liability -5000 brackets) 0))))

(ert-deftest cmacs-calculator-tests-tax-marginal-vs-effective ()
  "Marginal rate is never below the effective rate, at any income.
Under any ascending ladder the lower bands drag the average down, so
this has to hold everywhere -- if it ever fails, the bracket walk is
applying a rate outside its band."
  (cmacs-calculator-tests--skip-unless-tax)
  (skip-unless (and (fboundp 'cmacs-calculator-tax-marginal-rate)
                    (fboundp 'cmacs-calculator-tax-effective-rate)
                    (fboundp 'cmacs-calculator-tax-bracket-liability)))
  (let ((brackets '((0 . 0.10) (11925 . 0.12) (48475 . 0.22)
                    (103350 . 0.24) (197300 . 0.32))))
    (dolist (income '(1 1000 11925 15000 48475 50000 100000 500000 2000000))
      (let* ((tax (cmacs-calculator-tax-bracket-liability income brackets))
             (m (cmacs-calculator-tax-marginal-rate income brackets))
             (e (cmacs-calculator-tax-effective-rate tax income)))
        (should (>= m e))))))


;;; Charts
;;
;; The SVG and unicode tiers are pure and need no display.

(ert-deftest cmacs-calculator-tests-chart-unicode-fallback ()
  "Charts degrade to text rather than failing without a display."
  (skip-unless (featurep 'cmacs-calculator-chart))
  (let ((cmacs-calculator-chart-backend 'unicode))
    (let ((out (cmacs-calculator-chart
                'line (list (list :name "s" :points '((0 . 0) (1 . 1) (2 . 4)))))))
      (should (stringp out))
      (should (string-match-p "s" out)))))

(ert-deftest cmacs-calculator-tests-chart-rejects-empty ()
  "Empty and unplottable input is reported."
  (skip-unless (featurep 'cmacs-calculator-chart))
  (let ((cmacs-calculator-chart-backend 'unicode))
    (should-error (cmacs-calculator-chart 'line nil)
                  :type 'cmacs-calculator-error)
    (should-error (cmacs-calculator-chart 'line (list (list :name "x" :points nil)))
                  :type 'cmacs-calculator-error)))

(ert-deftest cmacs-calculator-tests-chart-sampling ()
  "Sampling runs through the engine and drops points with no real value."
  (skip-unless (featurep 'cmacs-calculator-chart))
  (let ((pts (cmacs-calculator-chart-sample "sin(x)" "x" 0 3.14159265 33)))
    (should (= (length pts) 33))
    ;; sin(0) = 0 and sin(pi/2) = 1.
    (should (cmacs-calculator-tests--close (cdr (car pts)) 0.0 1e-6))
    (should (cmacs-calculator-tests--close
             (apply #'max (mapcar #'cdr pts)) 1.0 1e-3)))
  ;; A pole is skipped, not fatal.
  (let ((pts (cmacs-calculator-chart-sample "1/x" "x" -2 2 41)))
    (should (< (length pts) 41))
    (should (> (length pts) 30)))
  ;; A half-complex domain yields only the real half.
  (let ((pts (cmacs-calculator-chart-sample "sqrt(x)" "x" -1 4 31)))
    (should (> (length pts) 10))
    (should (cl-every (lambda (p) (>= (car p) -1e-9)) pts))))

(ert-deftest cmacs-calculator-tests-chart-bounds ()
  "Bounds cover every series and pad a degenerate range."
  (skip-unless (featurep 'cmacs-calculator-chart))
  (pcase-let ((`(,xmin ,xmax ,ymin ,ymax)
               (cmacs-calculator-chart--bounds
                (list (list :points '((0 . 5) (10 . 15)))
                      (list :points '((-5 . -2) (3 . 30)))))))
    (should (= xmin -5)) (should (= xmax 10))
    (should (= ymin -2)) (should (= ymax 30)))
  ;; A constant series must not collapse to a zero-width range.
  (pcase-let ((`(,xmin ,xmax ,ymin ,ymax)
               (cmacs-calculator-chart--bounds
                (list (list :points '((1 . 7) (1 . 7)))))))
    (should (< xmin xmax))
    (should (< ymin ymax))))

(ert-deftest cmacs-calculator-tests-chart-gpu-tier ()
  "The GPU chart tier, when this build has libregnum and a display."
  (skip-unless (and (fboundp 'cmacs-calculator-chart-supported-p)
                    (cmacs-calculator-chart-supported-p)
                    (display-graphic-p)))
  (let ((buf (generate-new-buffer " *calc-chart-test*")))
    (unwind-protect
        (progn
          (should (cmacs-calculator-chart-attach buf 320 240))
          (should (memq 'line (cmacs-calculator-chart-types)))
          (should (cmacs-calculator-chart-set-type buf 'line))
          (should (cmacs-calculator-chart-set-title buf "test"))
          (should (cmacs-calculator-chart-add-series
                   buf "s" "#3b6fb0" '((0 . 0) (1 . 1) (2 . 4))))
          (should (cmacs-calculator-chart-refresh buf))
          ;; An unknown chart type is an error, not a silent default.
          (should-error (cmacs-calculator-chart-set-type buf 'nonesuch)
                        :type 'cmacs-calculator-error))
      (when (fboundp 'cmacs-calculator-chart-detach)
        (ignore-errors (cmacs-calculator-chart-detach buf)))
      (kill-buffer buf))))

(ert-deftest cmacs-calculator-tests-chart-requires-attach ()
  "Chart operations on an unattached buffer are reported, not crashes."
  (skip-unless (and (fboundp 'cmacs-calculator-chart-supported-p)
                    (cmacs-calculator-chart-supported-p)))
  (let ((buf (generate-new-buffer " *calc-chart-test2*")))
    (unwind-protect
        (should-error (cmacs-calculator-chart-set-title buf "x")
                      :type 'cmacs-calculator-error)
      (kill-buffer buf))))


;;; Registry

(ert-deftest cmacs-calculator-tests-registry ()
  "Registered calculators carry usable metadata."
  (cmacs-calculator-tests--skip-unless-financial)
  (let ((entry (cmacs-calculator-get 'bscall)))
    (should entry)
    (should (eq (plist-get entry :name) 'bscall))
    (should (eq (plist-get entry :category) 'financial))
    (should (stringp (plist-get entry :title)))
    (should (plist-get entry :args)))
  (should (memq 'financial (cmacs-calculator-categories)))
  (should (cmacs-calculator-list 'financial))
  ;; Filtering really filters.
  (should (cl-every (lambda (c) (eq (plist-get c :category) 'financial))
                    (cmacs-calculator-list 'financial))))

(ert-deftest cmacs-calculator-tests-registry-examples-are-correct ()
  "Every :examples pair in the registry actually evaluates to its answer.
This is what keeps the landing page and the reference documentation --
both generated from these -- from drifting away from the code."
  (cmacs-calculator-tests--skip-unless-financial)
  (dolist (entry (cmacs-calculator-list))
    (dolist (ex (plist-get entry :examples))
      (let* ((expr (car ex))
             (want (cdr ex))
             (got (ignore-errors (cmacs-calculator-eval expr))))
        (should got)
        ;; Compare numerically where both are numbers, so a shorter
        ;; documented value (1896.20) still matches a longer computed one.
        (let ((gn (cmacs-calculator--as-number got))
              (wn (cmacs-calculator--as-number want)))
          (if (and gn wn)
              (should (cmacs-calculator-tests--close
                       gn wn (if (string-match-p "\\." want) 1e-4 1e-9)))
            (should (equal got want))))))))


;;; Composition
;;
;; The property that makes the whole design worthwhile: every calculator is a
;; first-class Calc algebraic function.

(ert-deftest cmacs-calculator-tests-calculators-compose ()
  "Calculators compose inside larger expressions and with each other."
  (cmacs-calculator-tests--skip-unless-financial)
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "simpleint(1000,0.05,3) + 100")
           250.0 1e-9))
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "sqrt(simpleint(1000,0.05,3))")
           12.2474487139 1e-8))
  ;; A calculator's output feeding another calculator's input.
  (should (cmacs-calculator-tests--close
           (cmacs-calculator-tests--num "roi(fvlump(1000,0.05,10), 1000)")
           0.62889462678 1e-8)))


;;; Menu dispatch
;;
;; The landing page stores two kinds of action in a text property: surface
;; entries store an interactive command symbol, registry entries store a bare
;; closure with no `interactive' form.  `call-interactively' rejects the
;; latter (Wrong type argument: commandp), so the dispatch must guard on
;; `commandp'.  A silent revert here breaks every registry calculator (CAGR,
;; etc.) while the surfaces keep working.

(ert-deftest cmacs-calculator-tests-menu-invoke-closure ()
  "A registry-style closure action must be invoked, not rejected as non-command."
  (skip-unless (fboundp 'cmacs-calculator-menu--invoke))
  (let* ((called nil)
         (action (lambda () (setq called t))))
    (should-not (commandp action))
    (cmacs-calculator-menu--invoke action)
    (should called)))

(defvar cmacs-calculator-tests--menu-cmd-called nil
  "Set by `cmacs-calculator-tests--menu-cmd' when invoked.")

(defun cmacs-calculator-tests--menu-cmd ()
  "A trivial interactive command standing in for a surface action."
  (interactive)
  (setq cmacs-calculator-tests--menu-cmd-called t))

(ert-deftest cmacs-calculator-tests-menu-invoke-command ()
  "A surface-style interactive command symbol must still dispatch."
  (skip-unless (fboundp 'cmacs-calculator-menu--invoke))
  (setq cmacs-calculator-tests--menu-cmd-called nil)
  (should (commandp 'cmacs-calculator-tests--menu-cmd))
  (cmacs-calculator-menu--invoke 'cmacs-calculator-tests--menu-cmd)
  (should cmacs-calculator-tests--menu-cmd-called))

(provide 'cmacs-calculator-tests)
;;; cmacs-calculator-tests.el ends here
