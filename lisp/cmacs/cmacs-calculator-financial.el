;;; cmacs-calculator-financial.el --- Financial calculators -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Financial calculators for `cmacs-calculator': interest, loans and
;; amortization, bonds, options, and investment analysis.
;;
;; GNU Calc already ships the time-value-of-money core in `calc-fin.el'
;; (pv, fv, pmt, nper, rate, npv, irr, sln, syd, ddb) and those are re-used
;; as-is rather than reimplemented.  This file adds what Calc lacks:
;; amortization schedules, bond pricing and risk measures, option pricing
;; and greeks, and the everyday ratios.
;;
;; Sign conventions
;; ----------------
;; Calc's `pv'/`fv'/`pmt' follow the cash-flow sign convention: money paid
;; out is negative, money received is positive, so `pv(0.05, 30, -1000)' is
;; -15372.45.  This differs from the Excel/HP-12C reading some users expect.
;; The wrappers here (`loanpmt', `loantotal', ...) instead return positive
;; magnitudes, which is what a loan calculator should print; the raw Calc
;; functions remain available for anyone who wants the signed convention.
;;
;; Everything defined with `cmacs-calculator-defcalc' is a first-class Calc
;; algebraic function, so it composes inside any larger expression:
;;
;;   bscall(100,100,0.05,0.2,1) - bsput(100,100,0.05,0.2,1)
;;
;; Schedules and iterative solvers (amortization, yield-to-maturity,
;; implied volatility) return Lisp data or use Newton iteration, so they are
;; plain functions rather than algebraic ones.

;;; Code:

(require 'calc)
(require 'calc-ext)
(require 'calc-fin)
(require 'cmacs-calculator)

(eval-when-compile (require 'cl-lib))

(declare-function calcFunc-pmt "calc-fin" (rate num amount &optional lump))
(declare-function calcFunc-irr "calc-fin" (&rest vecs))


;;; Interest and growth

(cmacs-calculator-defcalc simpleint (principal rate years)
  :category financial
  :title "Simple interest"
  :doc "Interest earned at RATE per year on PRINCIPAL for YEARS, with no
compounding."
  :args ((principal "Principal amount")
         (rate "Annual interest rate as a fraction, e.g. 0.05")
         (years "Number of years"))
  :returns "Interest earned (not including the principal)"
  :examples (("simpleint(1000, 0.05, 3)" . "150"))
  (* principal rate years))

(cmacs-calculator-defcalc compoundamt (principal rate periods years)
  :category financial
  :title "Compound interest -- final amount"
  :doc "Value of PRINCIPAL after YEARS at annual RATE compounded PERIODS
times per year."
  :args ((principal "Principal amount")
         (rate "Annual nominal rate as a fraction")
         (periods "Compounding periods per year, e.g. 12 for monthly")
         (years "Number of years"))
  :returns "Final amount, including principal"
  :examples (("compoundamt(1000, 0.05, 12, 10)" . "1647.00949769"))
  (* principal (^ (+ 1 (/ rate periods)) (* periods years))))

(cmacs-calculator-defcalc compoundint (principal rate periods years)
  :category financial
  :title "Compound interest -- interest earned"
  :doc "Interest earned on PRINCIPAL after YEARS at annual RATE compounded
PERIODS times per year."
  :args ((principal "Principal amount")
         (rate "Annual nominal rate as a fraction")
         (periods "Compounding periods per year")
         (years "Number of years"))
  :returns "Interest earned, excluding the principal"
  :examples (("compoundint(1000, 0.05, 12, 10)" . "647.009497690"))
  (- (compoundamt principal rate periods years) principal))

(cmacs-calculator-defcalc apr2apy (apr periods)
  :category financial
  :title "Nominal rate to effective annual rate"
  :doc "Convert nominal annual rate APR, compounded PERIODS times per year,
into the effective annual yield."
  :args ((apr "Nominal annual rate as a fraction")
         (periods "Compounding periods per year"))
  :returns "Effective annual rate as a fraction"
  :examples (("apr2apy(0.05, 12)" . "0.0511618978817"))
  (- (^ (+ 1 (/ apr periods)) periods) 1))

(cmacs-calculator-defcalc apy2apr (apy periods)
  :category financial
  :title "Effective annual rate to nominal rate"
  :doc "Convert effective annual yield APY into the nominal annual rate
compounded PERIODS times per year."
  :args ((apy "Effective annual rate as a fraction")
         (periods "Compounding periods per year"))
  :returns "Nominal annual rate as a fraction"
  :examples (("apy2apr(0.0511618978817, 12)" . "0.05"))
  (* periods (- (^ (+ 1 apy) (/ 1 periods)) 1)))

(cmacs-calculator-defcalc cagr (begin end years)
  :category financial
  :title "Compound annual growth rate"
  :doc "The constant annual rate that grows BEGIN into END over YEARS."
  :args ((begin "Starting value") (end "Ending value") (years "Number of years"))
  :returns "Annual growth rate as a fraction"
  :examples (("cagr(1000, 2000, 10)" . "0.0717734625363"))
  (- (^ (/ end begin) (/ 1 years)) 1))

(cmacs-calculator-defcalc roi (gain cost)
  :category financial
  :title "Return on investment"
  :doc "Net return as a fraction of COST.  GAIN is the final value."
  :args ((gain "Final value") (cost "Initial cost"))
  :returns "Return as a fraction, e.g. 0.5 for +50%"
  :examples (("roi(1500, 1000)" . "0.5"))
  (/ (- gain cost) cost))

(cmacs-calculator-defcalc rule72 (rate)
  :category financial
  :title "Rule of 72 doubling time"
  :doc "Approximate years to double at annual RATE.  A rule of thumb; use
`doubletime' for the exact figure."
  :args ((rate "Annual rate as a fraction"))
  :returns "Approximate years to double"
  :examples (("rule72(0.08)" . "9."))
  (/ 72 (* rate 100)))

(cmacs-calculator-defcalc doubletime (rate)
  :category financial
  :title "Exact doubling time"
  :doc "Years for a balance to double at annual RATE, compounded annually."
  :args ((rate "Annual rate as a fraction"))
  :returns "Years to double"
  :examples (("doubletime(0.08)" . "9.00646730713"))
  (/ (ln 2) (ln (+ 1 rate))))


;;; Loans

(cmacs-calculator-defcalc loanpmt (principal annrate years)
  :category financial
  :title "Loan payment (monthly)"
  :doc "Level monthly payment amortizing PRINCIPAL over YEARS at nominal
annual rate ANNRATE.  Returned as a positive amount; contrast Calc's
`pmt', which follows the signed cash-flow convention."
  :args ((principal "Loan amount")
         (annrate "Nominal annual interest rate as a fraction")
         (years "Loan term in years"))
  :returns "Monthly payment, positive"
  :examples (("loanpmt(300000, 0.065, 30)" . "1896.20"))
  (if (= annrate 0)
      (/ principal (* years 12))
    (let* ((r (/ annrate 12))
           (n (* years 12)))
      (/ (* principal r) (- 1 (^ (+ 1 r) (- n)))))))

(cmacs-calculator-defcalc loantotal (principal annrate years)
  :category financial
  :title "Loan total paid"
  :doc "Total of all payments over the life of the loan."
  :args ((principal "Loan amount")
         (annrate "Nominal annual rate as a fraction")
         (years "Loan term in years"))
  :returns "Total amount paid"
  :examples (("loantotal(300000, 0.065, 30)" . "682632.24"))
  (* (loanpmt principal annrate years) years 12))

(cmacs-calculator-defcalc loanint (principal annrate years)
  :category financial
  :title "Loan total interest"
  :doc "Total interest paid over the life of the loan."
  :args ((principal "Loan amount")
         (annrate "Nominal annual rate as a fraction")
         (years "Loan term in years"))
  :returns "Total interest paid"
  :examples (("loanint(300000, 0.065, 30)" . "382632.24"))
  (- (loantotal principal annrate years) principal))

(cmacs-calculator-defcalc loanbalance (principal annrate years paid)
  :category financial
  :title "Remaining loan balance"
  :doc "Outstanding principal after PAID monthly payments have been made."
  :args ((principal "Original loan amount")
         (annrate "Nominal annual rate as a fraction")
         (years "Original term in years")
         (paid "Number of payments already made"))
  :returns "Remaining principal balance"
  :examples (("loanbalance(300000, 0.065, 30, 60)" . "280832.932338"))
  (if (= annrate 0)
      (- principal (* (/ principal (* years 12)) paid))
    (let* ((r (/ annrate 12))
           (p (loanpmt principal annrate years)))
      (- (* principal (^ (+ 1 r) paid))
         (* p (/ (- (^ (+ 1 r) paid) 1) r))))))

(defun cmacs-calculator-amortization (principal annrate years &optional extra)
  "Return the amortization schedule for a loan, as a list of plists.

PRINCIPAL is the loan amount, ANNRATE the nominal annual rate as a
fraction, YEARS the term.  EXTRA is an optional additional principal
payment applied every month, which shortens the schedule.

Each entry is a plist with :period, :payment, :interest, :principal,
:extra, :balance and :cumulative-interest.  The final payment is
adjusted so the balance lands exactly on zero rather than drifting by a
rounding error, and the schedule stops early when EXTRA pays the loan
off ahead of term.

This returns Lisp data rather than a Calc value, so it is an ordinary
function and not an algebraic one."
  (let* ((extra (or extra 0))
         (rate (/ annrate 12.0))
         (n (round (* years 12)))
         (pmt (if (zerop annrate)
                  (/ (float principal) n)
                (/ (* principal rate) (- 1 (expt (+ 1 rate) (- n))))))
         (balance (float principal))
         (cum 0.0)
         (period 0)
         (out nil))
    (while (and (> balance 1e-8) (< period n))
      (setq period (1+ period))
      (let* ((interest (* balance rate))
             (principal-part (- pmt interest))
             (this-extra extra)
             (payment pmt))
        ;; Final payment: pay off exactly what is left instead of
        ;; overshooting into a negative balance.
        (when (>= (+ principal-part this-extra) balance)
          (setq principal-part balance
                this-extra 0
                payment (+ balance interest)))
        (setq balance (- balance principal-part this-extra))
        (when (< balance 1e-8) (setq balance 0.0))
        (setq cum (+ cum interest))
        (push (list :period period
                    :payment payment
                    :interest interest
                    :principal principal-part
                    :extra this-extra
                    :balance balance
                    :cumulative-interest cum)
              out)))
    (nreverse out)))


;;; Bonds

(cmacs-calculator-defcalc bondprice (face rate ytm years freq)
  :category financial
  :title "Bond price"
  :doc "Present value of a coupon bond.  When YTM equals RATE the price is
FACE, which is the standard check that the formula is right."
  :args ((face "Face (par) value")
         (rate "Annual coupon rate as a fraction")
         (ytm "Yield to maturity as a fraction")
         (years "Years to maturity")
         (freq "Coupon payments per year, e.g. 2 for semiannual"))
  :returns "Bond price"
  :examples (("bondprice(1000, 0.05, 0.05, 10, 2)" . "1000.")
             ("bondprice(1000, 0.05, 0.06, 10, 2)" . "925.61"))
  (let* ((n (* years freq))
         (c (/ (* face rate) freq))
         (y (/ ytm freq)))
    (if (= y 0)
        (+ (* c n) face)
      (+ (* c (/ (- 1 (^ (+ 1 y) (- n))) y))
         (* face (^ (+ 1 y) (- n)))))))

(cmacs-calculator-defcalc bondcurrentyield (face rate price)
  :category financial
  :title "Bond current yield"
  :doc "Annual coupon income divided by the market PRICE."
  :args ((face "Face value") (rate "Annual coupon rate as a fraction")
         (price "Market price"))
  :returns "Current yield as a fraction"
  :examples (("bondcurrentyield(1000, 0.05, 925.61)" . "0.0540185"))
  (/ (* face rate) price))

(defun cmacs-calculator--bond-price (face rate ytm years freq)
  "Bond price as an Emacs float.  Arguments as in `bondprice'."
  (let* ((n (* years freq))
         (c (/ (float (* face rate)) freq))
         (y (/ (float ytm) freq)))
    (if (zerop y)
        (+ (* c n) face)
      (+ (* c (/ (- 1 (expt (+ 1 y) (- n))) y))
         (* face (expt (+ 1 y) (- n)))))))

(defun cmacs-calculator-bond-ytm (face rate price years freq &optional tolerance)
  "Return the yield to maturity of a bond, as a float.

FACE, RATE, YEARS and FREQ are as in `bondprice'; PRICE is the observed
market price.  Solved by bisection, which cannot diverge the way Newton
can when the price is near the bounds.  TOLERANCE defaults to 1e-10.

Signals `cmacs-calculator-error' if PRICE is not attainable, e.g. a
price above the undiscounted sum of all cash flows."
  (let* ((tolerance (or tolerance 1e-10))
         (lo -0.99)
         (hi 10.0)
         (price (float price)))
    (when (<= price 0)
      (signal 'cmacs-calculator-error (list "bond price must be positive" price)))
    ;; Price decreases monotonically in yield, so bracket on that.
    (when (> price (cmacs-calculator--bond-price face rate lo years freq))
      (signal 'cmacs-calculator-error
              (list "price too high for any yield above -99%" price)))
    (when (< price (cmacs-calculator--bond-price face rate hi years freq))
      (signal 'cmacs-calculator-error
              (list "price too low for any yield below 1000%" price)))
    (let ((iterations 0))
      (while (and (> (- hi lo) tolerance) (< iterations 200))
        (setq iterations (1+ iterations))
        (let* ((mid (/ (+ lo hi) 2))
               (p (cmacs-calculator--bond-price face rate mid years freq)))
          (if (> p price) (setq lo mid) (setq hi mid))))
      (/ (+ lo hi) 2))))

(defun cmacs-calculator-bond-duration (face rate ytm years freq)
  "Return the Macaulay duration of a bond in years, as a float.
Arguments are as in `bondprice'.  Macaulay duration is the
present-value-weighted average time to receive the bond's cash flows."
  (let* ((n (round (* years freq)))
         (c (/ (float (* face rate)) freq))
         (y (/ (float ytm) freq))
         (price (cmacs-calculator--bond-price face rate ytm years freq))
         (weighted 0.0))
    (dotimes (k n)
      (let* ((period (1+ k))
             (cash (if (= period n) (+ c face) c))
             (pv (/ cash (expt (+ 1 y) period))))
        (setq weighted (+ weighted (* period pv)))))
    (/ weighted price freq)))

(defun cmacs-calculator-bond-mduration (face rate ytm years freq)
  "Return the modified duration of a bond, as a float.
Modified duration approximates the percentage price change for a one
percentage-point change in yield.  Arguments are as in `bondprice'."
  (/ (cmacs-calculator-bond-duration face rate ytm years freq)
     (+ 1 (/ (float ytm) freq))))

(defun cmacs-calculator-bond-convexity (face rate ytm years freq)
  "Return the convexity of a bond, as a float.
Convexity is the second-order sensitivity of price to yield, correcting
the linear estimate given by modified duration.  Arguments are as in
`bondprice'."
  (let* ((n (round (* years freq)))
         (c (/ (float (* face rate)) freq))
         (y (/ (float ytm) freq))
         (price (cmacs-calculator--bond-price face rate ytm years freq))
         (acc 0.0))
    (dotimes (k n)
      (let* ((period (1+ k))
             (cash (if (= period n) (+ c face) c))
             (pv (/ cash (expt (+ 1 y) period))))
        (setq acc (+ acc (* period (1+ period) pv)))))
    (/ acc price (expt (+ 1 y) 2) (* freq freq))))

(cmacs-calculator-defcalc accruedint (face rate days-since days-period freq)
  :category financial
  :title "Accrued bond interest"
  :doc "Coupon interest accrued since the last payment, on a simple
day-count basis."
  :args ((face "Face value") (rate "Annual coupon rate as a fraction")
         (days-since "Days since the last coupon")
         (days-period "Days in the full coupon period")
         (freq "Coupon payments per year"))
  :returns "Accrued interest"
  :examples (("accruedint(1000, 0.05, 90, 182, 2)" . "12.3626373626"))
  (* (/ (* face rate) freq) (/ days-since days-period)))


;;; Options

(cmacs-calculator-defcalc normpdf (x)
  :category financial
  :title "Standard normal density"
  :doc "Probability density of the standard normal distribution at X."
  :args ((x "Value"))
  :returns "Density"
  :examples (("normpdf(0)" . "0.398942280401"))
  (/ (exp (/ (- (^ x 2)) 2)) (sqrt (* 2 pi))))

(cmacs-calculator-defcalc normcdf (x)
  :category financial
  :title "Standard normal cumulative distribution"
  :doc "Probability that a standard normal variate is at most X.  A thin
name for Calc's `ltpn(x, 0, 1)'."
  :args ((x "Value"))
  :returns "Cumulative probability"
  :examples (("normcdf(1.96)" . "0.97500210485"))
  (ltpn x 0 1))

(cmacs-calculator-defcalc bsd1 (spot strike rate sigma term)
  :category financial
  :title "Black-Scholes d1"
  :doc "The d1 term of the Black-Scholes formula."
  :args ((spot "Current price of the underlying")
         (strike "Strike price")
         (rate "Risk-free rate as a fraction, annualized")
         (sigma "Volatility as a fraction, annualized")
         (term "Time to expiry in years"))
  :returns "d1"
  :examples (("bsd1(100, 100, 0.05, 0.2, 1)" . "0.35"))
  (/ (+ (ln (/ spot strike)) (* (+ rate (/ (^ sigma 2) 2)) term))
     (* sigma (sqrt term))))

(cmacs-calculator-defcalc bsd2 (spot strike rate sigma term)
  :category financial
  :title "Black-Scholes d2"
  :doc "The d2 term of the Black-Scholes formula, equal to d1 - sigma*sqrt(T)."
  :args ((spot "Current price of the underlying") (strike "Strike price")
         (rate "Risk-free rate as a fraction") (sigma "Volatility as a fraction")
         (term "Time to expiry in years"))
  :returns "d2"
  :examples (("bsd2(100, 100, 0.05, 0.2, 1)" . "0.15"))
  (- (bsd1 spot strike rate sigma term) (* sigma (sqrt term))))

(cmacs-calculator-defcalc bscall (spot strike rate sigma term)
  :category financial
  :title "Black-Scholes call price"
  :doc "Value of a European call option under Black-Scholes."
  :args ((spot "Current price of the underlying") (strike "Strike price")
         (rate "Risk-free rate as a fraction, annualized")
         (sigma "Volatility as a fraction, annualized")
         (term "Time to expiry in years"))
  :returns "Call price"
  :examples (("bscall(100, 100, 0.05, 0.2, 1)" . "10.4505835721"))
  (- (* spot (normcdf (bsd1 spot strike rate sigma term)))
     (* strike (exp (* (- rate) term))
        (normcdf (bsd2 spot strike rate sigma term)))))

(cmacs-calculator-defcalc bsput (spot strike rate sigma term)
  :category financial
  :title "Black-Scholes put price"
  :doc "Value of a European put option under Black-Scholes.  Satisfies
put-call parity with `bscall'."
  :args ((spot "Current price of the underlying") (strike "Strike price")
         (rate "Risk-free rate as a fraction") (sigma "Volatility as a fraction")
         (term "Time to expiry in years"))
  :returns "Put price"
  :examples (("bsput(100, 100, 0.05, 0.2, 1)" . "5.5735260223"))
  (- (* strike (exp (* (- rate) term))
        (normcdf (- (bsd2 spot strike rate sigma term))))
     (* spot (normcdf (- (bsd1 spot strike rate sigma term))))))

(cmacs-calculator-defcalc bscalldelta (spot strike rate sigma term)
  :category financial
  :title "Call delta"
  :doc "Sensitivity of a call price to the underlying price."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Delta, between 0 and 1"
  :examples (("bscalldelta(100, 100, 0.05, 0.2, 1)" . "0.636830651175"))
  (normcdf (bsd1 spot strike rate sigma term)))

(cmacs-calculator-defcalc bsputdelta (spot strike rate sigma term)
  :category financial
  :title "Put delta"
  :doc "Sensitivity of a put price to the underlying price."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Delta, between -1 and 0"
  :examples (("bsputdelta(100, 100, 0.05, 0.2, 1)" . "-0.363169348825"))
  (- (normcdf (bsd1 spot strike rate sigma term)) 1))

(cmacs-calculator-defcalc bsgamma (spot strike rate sigma term)
  :category financial
  :title "Gamma"
  :doc "Rate of change of delta with the underlying price.  Identical for
calls and puts."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Gamma"
  :examples (("bsgamma(100, 100, 0.05, 0.2, 1)" . "0.0187620173"))
  (/ (normpdf (bsd1 spot strike rate sigma term))
     (* spot sigma (sqrt term))))

(cmacs-calculator-defcalc bsvega (spot strike rate sigma term)
  :category financial
  :title "Vega"
  :doc "Sensitivity of the option price to volatility, per unit of sigma.
Identical for calls and puts."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Vega"
  :examples (("bsvega(100, 100, 0.05, 0.2, 1)" . "37.524034"))
  (* spot (normpdf (bsd1 spot strike rate sigma term)) (sqrt term)))

(cmacs-calculator-defcalc bscalltheta (spot strike rate sigma term)
  :category financial
  :title "Call theta"
  :doc "Time decay of a call price, per year."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Theta per year (negative for a long call)"
  :examples (("bscalltheta(100, 100, 0.05, 0.2, 1)" . "-6.414027546"))
  (- (- (/ (* spot (normpdf (bsd1 spot strike rate sigma term)) sigma)
           (* 2 (sqrt term))))
     (* rate strike (exp (* (- rate) term))
        (normcdf (bsd2 spot strike rate sigma term)))))

(cmacs-calculator-defcalc bsputtheta (spot strike rate sigma term)
  :category financial
  :title "Put theta"
  :doc "Time decay of a put price, per year."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Theta per year"
  :examples (("bsputtheta(100, 100, 0.05, 0.2, 1)" . "-1.657880423"))
  (+ (- (/ (* spot (normpdf (bsd1 spot strike rate sigma term)) sigma)
           (* 2 (sqrt term))))
     (* rate strike (exp (* (- rate) term))
        (normcdf (- (bsd2 spot strike rate sigma term))))))

(cmacs-calculator-defcalc bscallrho (spot strike rate sigma term)
  :category financial
  :title "Call rho"
  :doc "Sensitivity of a call price to the risk-free rate."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Rho"
  :examples (("bscallrho(100, 100, 0.05, 0.2, 1)" . "53.2324815"))
  (* strike term (exp (* (- rate) term))
     (normcdf (bsd2 spot strike rate sigma term))))

(cmacs-calculator-defcalc bsputrho (spot strike rate sigma term)
  :category financial
  :title "Put rho"
  :doc "Sensitivity of a put price to the risk-free rate."
  :args ((spot "Underlying price") (strike "Strike") (rate "Risk-free rate")
         (sigma "Volatility") (term "Years to expiry"))
  :returns "Rho"
  :examples (("bsputrho(100, 100, 0.05, 0.2, 1)" . "-41.890461"))
  (- (* strike term (exp (* (- rate) term))
        (normcdf (- (bsd2 spot strike rate sigma term))))))

(defun cmacs-calculator--bs-price (kind spot strike rate sigma term)
  "Black-Scholes price as an Emacs float.
KIND is `call' or `put'; other arguments are as in `bscall'."
  (let* ((d1 (/ (+ (log (/ (float spot) strike))
                   (* (+ rate (/ (* sigma sigma) 2.0)) term))
                (* sigma (sqrt (float term)))))
         (d2 (- d1 (* sigma (sqrt (float term)))))
         (nd (lambda (x) (/ (+ 1 (cmacs-calculator--erf (/ x (sqrt 2.0)))) 2.0))))
    (if (eq kind 'call)
        (- (* spot (funcall nd d1))
           (* strike (exp (* (- rate) term)) (funcall nd d2)))
      (- (* strike (exp (* (- rate) term)) (funcall nd (- d2)))
         (* spot (funcall nd (- d1)))))))

(defun cmacs-calculator--erf (x)
  "Error function of X, as an Emacs float.
Abramowitz & Stegun 7.1.26; accurate to about 1.5e-7, which is ample for
the implied-volatility search that uses it."
  (let* ((sign (if (< x 0) -1.0 1.0))
         (x (abs (float x)))
         (t- (/ 1.0 (+ 1.0 (* 0.3275911 x))))
         (y (- 1.0 (* (+ (* (+ (* (+ (* (+ (* 1.061405429 t-) -1.453152027) t-)
                                     1.421413741) t-) -0.284496736) t-)
                         0.254829592)
                      t- (exp (- (* x x)))))))
    (* sign y)))

(defun cmacs-calculator-implied-volatility
    (kind price spot strike rate term &optional tolerance)
  "Return the Black-Scholes implied volatility of an option, as a float.

KIND is `call' or `put'.  PRICE is the observed option price; SPOT,
STRIKE, RATE and TERM are as in `bscall'.  TOLERANCE defaults to 1e-8.

Solved by bisection over a wide volatility bracket.  Bisection rather
than Newton: vega collapses to nearly zero for deep in- or
out-of-the-money options, where a Newton step divides by it and
diverges.  Bisection is slower and cannot fail here, since price rises
monotonically with volatility.

Signals `cmacs-calculator-error' when PRICE lies outside the range
attainable by any volatility -- notably below the option's intrinsic
value, which is a genuine no-arbitrage violation rather than a
numerical problem."
  (let* ((tolerance (or tolerance 1e-8))
         (lo 1e-6)
         (hi 10.0)
         (price (float price))
         (price-lo (cmacs-calculator--bs-price kind spot strike rate lo term))
         (price-hi (cmacs-calculator--bs-price kind spot strike rate hi term)))
    (when (< price price-lo)
      (signal 'cmacs-calculator-error
              (list "option price below intrinsic value" price)))
    (when (> price price-hi)
      (signal 'cmacs-calculator-error
              (list "option price too high for any volatility" price)))
    (let ((iterations 0))
      (while (and (> (- hi lo) tolerance) (< iterations 200))
        (setq iterations (1+ iterations))
        (let* ((mid (/ (+ lo hi) 2))
               (p (cmacs-calculator--bs-price kind spot strike rate mid term)))
          (if (< p price) (setq lo mid) (setq hi mid))))
      (/ (+ lo hi) 2))))

(defun cmacs-calculator-binomial-option
    (kind style spot strike rate sigma term steps)
  "Price an option on a Cox-Ross-Rubinstein binomial lattice, as a float.

KIND is `call' or `put'; STYLE is `european' or `american'.  SPOT,
STRIKE, RATE, SIGMA and TERM are as in `bscall'.  STEPS is the number of
lattice steps -- more steps converge toward Black-Scholes for European
options, which is the natural test of this function.

American options are the reason this exists: they may be exercised
early, which Black-Scholes cannot express, so each node takes the
maximum of holding and exercising."
  (unless (and (integerp steps) (> steps 0))
    (signal 'cmacs-calculator-error (list "steps must be a positive integer" steps)))
  (let* ((dt (/ (float term) steps))
         (up (exp (* sigma (sqrt dt))))
         (down (/ 1.0 up))
         (disc (exp (* (- rate) dt)))
         (p (/ (- (exp (* rate dt)) down) (- up down)))
         (values (make-vector (1+ steps) 0.0)))
    (when (or (< p 0) (> p 1))
      (signal 'cmacs-calculator-error
              (list "no-arbitrage violated: risk-neutral probability out of range" p)))
    ;; Terminal payoffs.
    (dotimes (i (1+ steps))
      (let* ((s (* spot (expt up (- steps i)) (expt down i)))
             (payoff (if (eq kind 'call) (- s strike) (- strike s))))
        (aset values i (max 0.0 payoff))))
    ;; Roll back.
    (let ((step steps))
      (while (> step 0)
        (setq step (1- step))
        (dotimes (i (1+ step))
          (let ((hold (* disc (+ (* p (aref values i))
                                 (* (- 1 p) (aref values (1+ i)))))))
            (aset values i
                  (if (eq style 'american)
                      (let* ((s (* spot (expt up (- step i)) (expt down i)))
                             (exercise (if (eq kind 'call) (- s strike) (- strike s))))
                        (max hold exercise 0.0))
                    hold))))))
    (aref values 0)))


;;; Investment analysis

(cmacs-calculator-defcalc breakeven (fixed price varcost)
  :category financial
  :title "Break-even units"
  :doc "Units that must be sold to cover FIXED costs, given the per-unit
PRICE and VARCOST."
  :args ((fixed "Total fixed costs")
         (price "Selling price per unit")
         (varcost "Variable cost per unit"))
  :returns "Units to break even"
  :examples (("breakeven(10000, 25, 15)" . "1000"))
  (/ fixed (- price varcost)))

(cmacs-calculator-defcalc pvlump (amount rate years)
  :category financial
  :title "Present value of a lump sum"
  :doc "Value today of AMOUNT received in YEARS at discount RATE."
  :args ((amount "Future amount") (rate "Annual discount rate as a fraction")
         (years "Years until received"))
  :returns "Present value"
  :examples (("pvlump(1000, 0.05, 10)" . "613.913253541"))
  (/ amount (^ (+ 1 rate) years)))

(cmacs-calculator-defcalc fvlump (amount rate years)
  :category financial
  :title "Future value of a lump sum"
  :doc "Value of AMOUNT after YEARS of growth at RATE."
  :args ((amount "Present amount") (rate "Annual rate as a fraction")
         (years "Number of years"))
  :returns "Future value"
  :examples (("fvlump(1000, 0.05, 10)" . "1628.89462678"))
  (* amount (^ (+ 1 rate) years)))

(defun cmacs-calculator-dcf (flows rate)
  "Return the discounted present value of FLOWS at RATE, as a float.
FLOWS is a list of cash flows, the first at time zero (undiscounted)
and each subsequent one a period later.  This is net present value in
the textbook sense; Calc's `npv' discounts the first flow too."
  (let ((i -1))
    (apply #'+ (mapcar (lambda (f)
                         (setq i (1+ i))
                         (/ (float f) (expt (+ 1 rate) i)))
                       flows))))

(defun cmacs-calculator-irr (flows &optional tolerance)
  "Return the internal rate of return of FLOWS, as a float.
FLOWS is a list of cash flows starting at time zero.  TOLERANCE defaults
to 1e-10.  Solved by bisection over rates from -99% to 1000%.

Signals `cmacs-calculator-error' when no rate in that range zeroes the
NPV -- which happens for flows that never change sign (no IRR exists)
and is reported rather than silently returning a bracket endpoint."
  (let* ((tolerance (or tolerance 1e-10))
         (lo -0.99)
         (hi 10.0)
         (npv-lo (cmacs-calculator-dcf flows lo))
         (npv-hi (cmacs-calculator-dcf flows hi)))
    (when (> (* npv-lo npv-hi) 0)
      (signal 'cmacs-calculator-error
              (list "no internal rate of return in [-99%, 1000%]"
                    "cash flows may not change sign")))
    (let ((iterations 0))
      (while (and (> (- hi lo) tolerance) (< iterations 500))
        (setq iterations (1+ iterations))
        (let* ((mid (/ (+ lo hi) 2))
               (npv (cmacs-calculator-dcf flows mid)))
          (if (> (* npv npv-lo) 0)
              (setq lo mid npv-lo npv)
            (setq hi mid))))
      (/ (+ lo hi) 2))))


;;; Mortgage and retirement

(cmacs-calculator-defcalc mortgagepmt (price down annrate years taxrate insurance pmi)
  :category financial
  :title "Total monthly mortgage payment"
  :doc "Monthly housing payment including principal, interest, property
tax, insurance and PMI (PITI).  PMI is charged while the loan-to-value
ratio exceeds 80%, which is the usual lender rule."
  :args ((price "Purchase price") (down "Down payment")
         (annrate "Nominal annual mortgage rate as a fraction")
         (years "Loan term in years")
         (taxrate "Annual property tax rate as a fraction of price")
         (insurance "Annual homeowners insurance premium")
         (pmi "Annual PMI rate as a fraction of the loan amount"))
  :returns "Total monthly payment"
  :examples (("mortgagepmt(400000, 80000, 0.065, 30, 0.011, 1800, 0.005)" . "2539.28434144"))
  (let* ((loan (- price down))
         (ltv (/ loan price)))
    (+ (loanpmt loan annrate years)
       (/ (* price taxrate) 12)
       (/ insurance 12)
       ;; The LTV threshold is written 4/5, not 0.8, on purpose: `defmath'
       ;; passes an Emacs float literal straight through without converting it
       ;; to Calc's internal float form, and `math-lessp' then rejects it
       ;; against any non-integer Calc value.  The comparison would fail, the
       ;; whole call would come back unevaluated, and the only inputs that
       ;; appeared to work would be the ones where LTV happens to be an
       ;; integer (a zero down payment).  A fraction is exact and compares
       ;; cleanly.  Never put a bare float literal in a `defmath' comparison.
       (if (> ltv (/ 4 5)) (/ (* loan pmi) 12) 0))))

(defun cmacs-calculator-retirement-drawdown (balance annrate withdrawal years
                                                     &optional inflation)
  "Simulate a retirement drawdown, returning a list of yearly plists.

BALANCE is the starting portfolio, ANNRATE the expected annual return,
WITHDRAWAL the first year's spending, YEARS the horizon.  INFLATION
(default 0) grows the withdrawal each year.

Each entry is a plist with :year, :start, :withdrawal, :growth and
:end.  The simulation stops early if the money runs out, and the last
entry's :end is then zero with :depleted non-nil -- callers should check
for that rather than assuming YEARS entries."
  (let* ((inflation (or inflation 0))
         (balance (float balance))
         (draw (float withdrawal))
         (out nil))
    (cl-loop for year from 1 to years
             while (> balance 0)
             do (let* ((start balance)
                       (actual (min draw balance))
                       (after (- balance actual))
                       (growth (* after annrate))
                       (end (+ after growth))
                       (depleted (and (< actual draw) t)))
                  (push (list :year year
                              :start start
                              :withdrawal actual
                              :growth growth
                              :end (if depleted 0.0 end)
                              :depleted depleted)
                        out)
                  (setq balance (if depleted 0.0 end)
                        draw (* draw (+ 1 inflation)))))
    (nreverse out)))

(provide 'cmacs-calculator-financial)
;;; cmacs-calculator-financial.el ends here
