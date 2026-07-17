;;; cmacs-calculator-tax-tests.el --- ERT tests for cmacs-calculator-tax  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the tax/paycheck calculator family.  Pure Elisp over GNU
;; Calc, so nothing here needs a C subsystem or a network.
;;
;; The centrepiece is `cmacs-calculator-tax-bracket-liability', checked
;; against GOLDEN VALUES THE IRS COMPUTED ITSELF: every rate schedule in
;; Rev. Proc. 2025-32 (2026) and Rev. Proc. 2024-40 (2025) prints a
;; cumulative "The Tax Is" column -- "$17,966 plus 24% of the excess over
;; $105,700" -- so the tax at each bracket threshold is published.  Those
;; numbers are an independent arithmetic check on both the walk and the
;; transcribed data: if a threshold or a rate were mistyped, the
;; cumulative total at the next threshold would not land on the IRS's
;; figure.  They are quoted here to the cent.
;;
;; Run with: make -C test check-cmacs TESTS=cmacs-calculator-tax-tests

;;; Code:

(require 'ert)
(require 'cmacs-calculator-tax)
(require 'cmacs-calculator-tax-data)

(defconst cmacs-calculator-tax-tests--epsilon 0.005
  "Tolerance in dollars when comparing against published figures.
Half a cent: the IRS figures are exact, so anything larger would hide a
real transcription error.")

(defun cmacs-calculator-tax-tests--close (a b)
  "Return non-nil if A and B agree to within half a cent."
  (< (abs (- a b)) cmacs-calculator-tax-tests--epsilon))

(defun cmacs-calculator-tax-tests--statuses (table)
  "Return the filing statuses TABLE actually carries data for.
Tables that do not narrow it are assumed to cover all four."
  (or (plist-get table :filing-statuses)
      cmacs-calculator-tax-filing-statuses))


;;;; The progressive walk ------------------------------------------

(ert-deftest cmacs-calculator-tax-bracket-liability-matches-irs-2026 ()
  "The 2026 walk reproduces the IRS's own cumulative tax figures.
Each pair is (THRESHOLD . TAX-AT-THAT-THRESHOLD) as printed in the \"The
Tax Is\" column of Rev. Proc. 2025-32 section 4.01."
  (pcase-dolist (`(,status . ,cases)
                 '((single . ((12400 . 1240.0) (50400 . 5800.0)
                              (105700 . 17966.0) (201775 . 41024.0)
                              (256225 . 58448.0) (640600 . 192979.25)))
                   (married-joint . ((24800 . 2480.0) (100800 . 11600.0)
                                     (211400 . 35932.0) (403550 . 82048.0)
                                     (512450 . 116896.0) (768700 . 206583.50)))
                   (married-separate . ((12400 . 1240.0) (50400 . 5800.0)
                                        (105700 . 17966.0) (201775 . 41024.0)
                                        (256225 . 58448.0) (384350 . 103291.75)))
                   (head-of-household . ((17700 . 1770.0) (67450 . 7740.0)
                                         (105700 . 16155.0) (201750 . 39207.0)
                                         (256200 . 56631.0) (640600 . 191171.0)))))
    (let ((brackets (cmacs-calculator-tax--for-status
                     (cmacs-calculator-tax-get 'us-federal 2026)
                     "brackets" status)))
      (pcase-dolist (`(,income . ,expected) cases)
        (should (cmacs-calculator-tax-tests--close
                 (cmacs-calculator-tax-bracket-liability income brackets)
                 expected))))))

(ert-deftest cmacs-calculator-tax-bracket-liability-matches-irs-2025 ()
  "The 2025 walk reproduces the IRS's cumulative figures too.
From Rev. Proc. 2024-40 section 2.01.  A second year guards against a
walk that happens to fit one ladder."
  (pcase-dolist (`(,status . ,cases)
                 '((single . ((11925 . 1192.50) (48475 . 5578.50)
                              (103350 . 17651.0) (197300 . 40199.0)
                              (250525 . 57231.0) (626350 . 188769.75)))
                   (married-joint . ((23850 . 2385.0) (96950 . 11157.0)
                                     (206700 . 35302.0) (394600 . 80398.0)
                                     (501050 . 114462.0) (751600 . 202154.50)))
                   (married-separate . ((11925 . 1192.50) (48475 . 5578.50)
                                        (103350 . 17651.0) (197300 . 40199.0)
                                        (250525 . 57231.0) (375800 . 101077.25)))
                   (head-of-household . ((17000 . 1700.0) (64850 . 7442.0)
                                         (103350 . 15912.0) (197300 . 38460.0)
                                         (250500 . 55484.0) (626350 . 187031.50)))))
    (let ((brackets (cmacs-calculator-tax--for-status
                     (cmacs-calculator-tax-get 'us-federal 2025)
                     "brackets" status)))
      (pcase-dolist (`(,income . ,expected) cases)
        (should (cmacs-calculator-tax-tests--close
                 (cmacs-calculator-tax-bracket-liability income brackets)
                 expected))))))

(ert-deftest cmacs-calculator-tax-bracket-liability-is-progressive ()
  "Only the income INSIDE a band is taxed at that band's rate.
The classic bug is taxing the whole income at the top rate reached.  One
dollar over the 22% threshold must add 22 cents, not reprice the other
$50,400."
  (let ((brackets '((0 . 0.10) (12400 . 0.12) (50400 . 0.22))))
    ;; A dollar into the 22% band.
    (should (cmacs-calculator-tax-tests--close
             (cmacs-calculator-tax-bracket-liability 50401 brackets)
             5800.22))
    ;; Not 22% of the whole amount, which is the wrong answer this test
    ;; exists to exclude.
    (should-not (cmacs-calculator-tax-tests--close
                 (cmacs-calculator-tax-bracket-liability 50401 brackets)
                 (* 0.22 50401)))
    ;; Earning more never leaves you with less after tax: the after-tax
    ;; income must strictly increase across a bracket boundary.
    (should (> (- 50401 (cmacs-calculator-tax-bracket-liability 50401 brackets))
               (- 50400 (cmacs-calculator-tax-bracket-liability 50400 brackets))))))

(ert-deftest cmacs-calculator-tax-bracket-liability-edge-cases ()
  "Zero, negative, boundary and above-top-bracket incomes behave."
  (let ((brackets '((0 . 0.10) (12400 . 0.12) (50400 . 0.22))))
    ;; Zero income, zero tax.
    (should (= 0 (cmacs-calculator-tax-bracket-liability 0 brackets)))
    ;; A loss is not a negative tax (that would be a refund this
    ;; subsystem has no business inventing).
    (should (= 0 (cmacs-calculator-tax-bracket-liability -5000 brackets)))
    ;; Exactly on a boundary: the band above contributes nothing yet.
    (should (cmacs-calculator-tax-tests--close
             (cmacs-calculator-tax-bracket-liability 12400 brackets) 1240.0))
    ;; Above the top bracket, the top rate runs on without an upper bound.
    (should (cmacs-calculator-tax-tests--close
             (cmacs-calculator-tax-bracket-liability 1050400 brackets)
             (+ 5800.0 (* 0.22 1000000))))
    ;; A single-band ladder is a flat tax.
    (should (cmacs-calculator-tax-tests--close
             (cmacs-calculator-tax-bracket-liability 1000 '((0 . 0.05))) 50.0))))

(ert-deftest cmacs-calculator-tax-marginal-rate-boundaries ()
  "The marginal rate is the rate on the NEXT dollar."
  (let ((brackets '((0 . 0.10) (12400 . 0.12) (50400 . 0.22))))
    (should (= 0.10 (cmacs-calculator-tax-marginal-rate 0 brackets)))
    (should (= 0.10 (cmacs-calculator-tax-marginal-rate 12399 brackets)))
    ;; On the threshold the next dollar is taxed in the higher band.
    (should (= 0.12 (cmacs-calculator-tax-marginal-rate 12400 brackets)))
    (should (= 0.22 (cmacs-calculator-tax-marginal-rate 999999 brackets)))
    ;; A negative income is floored, not extrapolated below the ladder.
    (should (= 0.10 (cmacs-calculator-tax-marginal-rate -100 brackets)))))

(ert-deftest cmacs-calculator-tax-marginal-never-below-effective ()
  "Marginal rate >= effective rate, at every income, for every table.
A mathematical property of any ascending ladder: the lower bands always
drag the average below the rate on the last dollar.  A violation means
the ladder is out of order or the walk is charging a band's rate on
income outside it.  Swept across all registered bracketed jurisdictions
rather than a chosen few."
  (dolist (table (cmacs-calculator-tax-list))
    (when (eq (plist-get table :structure) 'bracketed)
      (dolist (status (cmacs-calculator-tax-tests--statuses table))
        (let ((brackets (cmacs-calculator-tax--for-status
                         table "brackets" status)))
          (when brackets
            (dolist (income '(0 1 5000 11925 12400 50400 50401 83900 100000
                              150000 200000 250000 500000 1000000 5000000))
              (let* ((tax (cmacs-calculator-tax-bracket-liability
                           income brackets))
                     (marginal (cmacs-calculator-tax-marginal-rate
                                income brackets))
                     (effective (cmacs-calculator-tax-effective-rate
                                 tax income)))
                (should (>= (+ marginal 1e-9) effective))
                ;; And tax never exceeds income, nor goes negative.
                (should (<= tax income))
                (should (>= tax 0))))))))))

(ert-deftest cmacs-calculator-tax-monotonic-after-tax-income ()
  "After-tax income rises monotonically with gross, for every table.
The user-visible promise of a progressive system: a raise can never
reduce take-home pay.  If a bracket list were mis-ordered this fails."
  (dolist (table (cmacs-calculator-tax-list))
    (when (eq (plist-get table :structure) 'bracketed)
      (dolist (status (cmacs-calculator-tax-tests--statuses table))
        (let ((brackets (cmacs-calculator-tax--for-status
                         table "brackets" status)))
          (when brackets
            (let ((previous -1.0)
                  (income 0))
              (while (< income 700000)
                (let ((net (- income (cmacs-calculator-tax-bracket-liability
                                      income brackets))))
                  (should (> net previous))
                  (setq previous net))
                (setq income (+ income 971))))))))))

(ert-deftest cmacs-calculator-tax-effective-rate-zero-income ()
  "An effective rate on no income is zero, not a division error."
  (should (= 0.0 (cmacs-calculator-tax-effective-rate 0 0)))
  (should (= 0.0 (cmacs-calculator-tax-effective-rate 100 0)))
  (should (= 0.0 (cmacs-calculator-tax-effective-rate 100 -500)))
  (should (cmacs-calculator-tax-tests--close
           0.17 (cmacs-calculator-tax-effective-rate 17000 100000))))


;;;; Federal -------------------------------------------------------

(ert-deftest cmacs-calculator-tax-federal-hand-computed ()
  "$100,000 single, 2026, checked against a hand-walked ladder.
  gross 100,000 - standard deduction 16,100 = 83,900 taxable
  10% x 12,400            =  1,240
  12% x (50,400 - 12,400) =  4,560
  22% x (83,900 - 50,400) =  7,370
                            -------
                            13,170"
  (let ((result (cmacs-calculator-tax-federal 100000 'single 2026)))
    (should (= 83900 (plist-get result :taxable-income)))
    (should (= 16100 (plist-get result :standard-deduction)))
    (should (cmacs-calculator-tax-tests--close
             13170.0 (plist-get result :tax)))
    (should (= 0.22 (plist-get result :marginal-rate)))
    (should (cmacs-calculator-tax-tests--close
             0.1317 (plist-get result :effective-rate)))
    (should (eq 2026 (plist-get result :year)))
    (should (plist-get result :verified))))

(ert-deftest cmacs-calculator-tax-federal-below-standard-deduction ()
  "Income under the standard deduction owes nothing, not a negative tax."
  (let ((result (cmacs-calculator-tax-federal 10000 'single 2026)))
    (should (= 0 (plist-get result :taxable-income)))
    (should (= 0.0 (plist-get result :tax)))
    (should (= 0.0 (plist-get result :effective-rate)))))

(ert-deftest cmacs-calculator-tax-federal-status-aliases ()
  "Common spellings of a filing status resolve to the canonical one."
  (should (equal (cmacs-calculator-tax-federal 100000 'married-joint 2026)
                 (cmacs-calculator-tax-federal 100000 'mfj 2026)))
  ;; Surviving spouses use the joint schedule per IRC 1(j)(2)(A).
  (should (equal (cmacs-calculator-tax-federal 100000 'married-joint 2026)
                 (cmacs-calculator-tax-federal 100000 'surviving-spouse 2026)))
  (should-error (cmacs-calculator-tax-federal 100000 'nonsense 2026)
                :type 'cmacs-calculator-tax-error))

(ert-deftest cmacs-calculator-tax-federal-marriage-comparison ()
  "A joint filer never pays more than two separate filers on split income.
The 2026 joint ladder is exactly twice the separate ladder up to the 35%
band, so this is an identity there rather than an approximation."
  (let ((joint (plist-get (cmacs-calculator-tax-federal 200000 'married-joint 2026)
                          :tax))
        (separate (* 2 (plist-get (cmacs-calculator-tax-federal
                                   100000 'married-separate 2026)
                                  :tax))))
    (should (cmacs-calculator-tax-tests--close joint separate))))

(ert-deftest cmacs-calculator-tax-federal-unknown-year-signals ()
  "Asking for a year with no table is an error, never a silent fallback.
Quietly answering with a different year's rates is the exact failure
this subsystem is built to prevent."
  (should-error (cmacs-calculator-tax-federal 100000 'single 1999)
                :type 'cmacs-calculator-tax-unknown-year)
  (should-error (cmacs-calculator-tax-state 100000 'single 'us-atlantis)
                :type 'cmacs-calculator-tax-unknown-jurisdiction))


;;;; FICA ----------------------------------------------------------

(ert-deftest cmacs-calculator-tax-fica-wage-cap ()
  "Social Security stops at the wage cap; Medicare does not.
At the 2026 cap of $184,500 the employee owes 6.2% x 184,500 = $11,439,
which is the figure SSA itself publishes as the per-party maximum."
  (let ((at-cap (cmacs-calculator-tax-fica 184500 'single 2026))
        (over-cap (cmacs-calculator-tax-fica 300000 'single 2026))
        (under-cap (cmacs-calculator-tax-fica 184499 'single 2026)))
    (should (cmacs-calculator-tax-tests--close
             11439.0 (plist-get at-cap :social-security)))
    ;; Just below the cap: one dollar less of Social Security base.
    (should (cmacs-calculator-tax-tests--close
             (- 11439.0 0.062) (plist-get under-cap :social-security)))
    ;; Above the cap, Social Security is frozen at the maximum.
    (should (cmacs-calculator-tax-tests--close
             11439.0 (plist-get over-cap :social-security)))
    ;; Medicare keeps going.
    (should (cmacs-calculator-tax-tests--close
             (* 0.0145 300000) (plist-get over-cap :medicare)))))

(ert-deftest cmacs-calculator-tax-fica-additional-medicare-threshold ()
  "Additional Medicare starts exactly at the status threshold."
  (let ((below (cmacs-calculator-tax-fica 199999 'single 2026))
        (at (cmacs-calculator-tax-fica 200000 'single 2026))
        (above (cmacs-calculator-tax-fica 250000 'single 2026))
        (joint (cmacs-calculator-tax-fica 200000 'married-joint 2026)))
    (should (= 0.0 (plist-get below :additional-medicare)))
    (should (= 0.0 (plist-get at :additional-medicare)))
    (should (cmacs-calculator-tax-tests--close
             (* 0.009 50000) (plist-get above :additional-medicare)))
    ;; A joint filer's threshold is $250,000, so nothing is due at $200k.
    (should (= 0.0 (plist-get joint :additional-medicare)))
    ;; A separate filer's is only $125,000.
    (should (cmacs-calculator-tax-tests--close
             (* 0.009 75000)
             (plist-get (cmacs-calculator-tax-fica 200000 'married-separate 2026)
                        :additional-medicare)))))

(ert-deftest cmacs-calculator-tax-fica-zero-and-negative ()
  "No wages, no FICA."
  (should (= 0.0 (plist-get (cmacs-calculator-tax-fica 0 'single 2026) :total)))
  (should (= 0.0 (plist-get (cmacs-calculator-tax-fica -100 'single 2026)
                            :total))))

(ert-deftest cmacs-calculator-tax-fica-total-is-the-sum ()
  "The reported total is exactly its three parts."
  (let ((fica (cmacs-calculator-tax-fica 300000 'single 2026)))
    (should (cmacs-calculator-tax-tests--close
             (plist-get fica :total)
             (+ (plist-get fica :social-security)
                (plist-get fica :medicare)
                (plist-get fica :additional-medicare))))))


;;;; Self-employment -----------------------------------------------

(ert-deftest cmacs-calculator-tax-self-employment-hand-computed ()
  "$100,000 net earnings, 2026, hand-walked.
  100,000 x 0.9235       = 92,350 subject to the tax
  12.4% x 92,350         = 11,451.40  (below the 184,500 cap)
   2.9% x 92,350         =  2,678.15
                           ----------
                           14,129.55, half of which is deductible."
  (let ((result (cmacs-calculator-tax-self-employment 100000 'single 2026)))
    (should (cmacs-calculator-tax-tests--close
             92350.0 (plist-get result :taxable-earnings)))
    (should (cmacs-calculator-tax-tests--close
             11451.40 (plist-get result :social-security)))
    (should (cmacs-calculator-tax-tests--close
             2678.15 (plist-get result :medicare)))
    (should (cmacs-calculator-tax-tests--close
             14129.55 (plist-get result :total)))
    (should (cmacs-calculator-tax-tests--close
             (/ 14129.55 2) (plist-get result :deduction)))))

(ert-deftest cmacs-calculator-tax-self-employment-cap-applies ()
  "The Social Security half of SE tax is capped like an employee's.
The cap applies to the 92.35% base, not to raw net earnings."
  (let ((result (cmacs-calculator-tax-self-employment 500000 'single 2026)))
    (should (cmacs-calculator-tax-tests--close
             (* 0.124 184500) (plist-get result :social-security)))
    ;; Medicare is uncapped and rides the full 92.35% base.
    (should (cmacs-calculator-tax-tests--close
             (* 0.029 (* 500000 0.9235)) (plist-get result :medicare)))))

(ert-deftest cmacs-calculator-tax-self-employment-deduction-excludes-addl ()
  "Additional Medicare is not part of the deductible employer half."
  (let ((result (cmacs-calculator-tax-self-employment 400000 'single 2026)))
    (should (> (plist-get result :additional-medicare) 0))
    (should (cmacs-calculator-tax-tests--close
             (plist-get result :deduction)
             (/ (+ (plist-get result :social-security)
                   (plist-get result :medicare))
                2.0)))))


;;;; Capital gains -------------------------------------------------

(ert-deftest cmacs-calculator-tax-capital-gains-stacks-on-income ()
  "The same gain is taxed differently depending on other income.
2026 single: the 0% band runs to $49,450 of total taxable income."
  ;; No other income: a $40,000 gain fits entirely inside the 0% band.
  (should (= 0.0 (plist-get (cmacs-calculator-tax-capital-gains
                             40000 0 'single t 2026)
                            :tax)))
  ;; Already at $200,000: the whole gain sits in the 15% band.
  (should (cmacs-calculator-tax-tests--close
           (* 0.15 40000)
           (plist-get (cmacs-calculator-tax-capital-gains
                       40000 200000 'single t 2026)
                      :tax))))

(ert-deftest cmacs-calculator-tax-capital-gains-straddles-a-band ()
  "A gain crossing the 0%/15% boundary is split across both bands.
2026 single, $30,000 other income, $40,000 gain: total $70,000, so
$19,450 of the gain fills the 0% band (up to $49,450) and the remaining
$20,550 is taxed at 15%."
  (should (cmacs-calculator-tax-tests--close
           (* 0.15 20550)
           (plist-get (cmacs-calculator-tax-capital-gains
                       40000 30000 'single t 2026)
                      :tax))))

(ert-deftest cmacs-calculator-tax-capital-gains-short-term-is-ordinary ()
  "A short-term gain is taxed as ordinary income, so it costs more.
It is the incremental tax the gain adds on top of existing income."
  (let ((short (plist-get (cmacs-calculator-tax-capital-gains
                           40000 200000 'single nil 2026)
                          :tax))
        (long (plist-get (cmacs-calculator-tax-capital-gains
                          40000 200000 'single t 2026)
                         :tax)))
    (should (> short long))
    ;; Equals tax(240,000) - tax(200,000) on the ordinary ladder.
    (let ((brackets (cmacs-calculator-tax--for-status
                     (cmacs-calculator-tax-get 'us-federal 2026)
                     "brackets" 'single)))
      (should (cmacs-calculator-tax-tests--close
               short
               (- (cmacs-calculator-tax-bracket-liability 240000 brackets)
                  (cmacs-calculator-tax-bracket-liability 200000 brackets)))))))

(ert-deftest cmacs-calculator-tax-capital-gains-top-band ()
  "A gain above the 15% ceiling reaches 20%."
  (let ((result (cmacs-calculator-tax-capital-gains
                 100000 600000 'single t 2026)))
    (should (= 0.20 (plist-get result :marginal-rate)))
    (should (cmacs-calculator-tax-tests--close
             (* 0.20 100000) (plist-get result :tax)))))

(ert-deftest cmacs-calculator-tax-capital-gains-zero-gain ()
  "No gain, no tax, and no division blow-up in the effective rate."
  (let ((result (cmacs-calculator-tax-capital-gains 0 100000 'single t 2026)))
    (should (= 0.0 (plist-get result :tax)))
    (should (= 0.0 (plist-get result :effective-rate)))))


;;;; States --------------------------------------------------------

(ert-deftest cmacs-calculator-tax-state-none-returns-zero ()
  "A no-income-tax state yields zero cleanly rather than signalling."
  (dolist (state '(us-tx us-fl us-wa us-nv us-ak us-sd us-wy us-tn us-nh))
    (let ((result (cmacs-calculator-tax-state 250000 'single state)))
      (should (eq 'none (plist-get result :structure)))
      (should (= 0.0 (plist-get result :tax)))
      (should (= 0 (plist-get result :marginal-rate)))
      (should (= 0.0 (plist-get result :effective-rate))))))

(ert-deftest cmacs-calculator-tax-state-every-jurisdiction-computes ()
  "Every registered state computes a sane tax for a range of incomes.
A blanket sweep: whatever the structure, the result must be a
non-negative number no larger than the income, with the effective rate
never exceeding the marginal one."
  (dolist (state (cmacs-calculator-tax-jurisdictions))
    (unless (eq state 'us-federal)
      (let ((table (cmacs-calculator-tax-get state)))
        (dolist (status (cmacs-calculator-tax-tests--statuses table))
          (dolist (income '(0 25000 60000 150000 1000000))
            (let* ((result (cmacs-calculator-tax-state income status state))
                   (tax (plist-get result :tax)))
              (should (numberp tax))
              (should (>= tax 0))
              (should (<= tax income))
              (should (>= (+ (plist-get result :marginal-rate) 1e-9)
                          (plist-get result :effective-rate))))))))))

(ert-deftest cmacs-calculator-tax-state-uncovered-status-signals ()
  "A status a table has no ladder for signals, never returns zero tax.
New Jersey's table carries no head-of-household schedule, so asking for
one must say so rather than quietly reporting that a New Jersey head of
household owes nothing."
  (should-error (cmacs-calculator-tax-state 100000 'head-of-household 'us-nj)
                :type 'cmacs-calculator-tax-invalid-table)
  ;; The statuses it does cover work normally.
  (should (> (plist-get (cmacs-calculator-tax-state 100000 'single 'us-nj) :tax)
             0)))

(ert-deftest cmacs-calculator-tax-state-flat-structure ()
  "A flat state taxes income above its deductions at one rate."
  (dolist (table (cmacs-calculator-tax-list))
    (when (eq (plist-get table :structure) 'flat)
      (let* ((state (plist-get table :jurisdiction))
             (rate (plist-get table :rate))
             (result (cmacs-calculator-tax-state 100000 'single state
                                                 (plist-get table :year))))
        ;; Tax equals rate times the reported taxable income, exactly.
        (should (cmacs-calculator-tax-tests--close
                 (plist-get result :tax)
                 (* rate (plist-get result :taxable-income))))
        (should (= rate (plist-get result :marginal-rate)))))))


;;;; Paycheck ------------------------------------------------------

(ert-deftest cmacs-calculator-tax-paycheck-components-reconcile ()
  "Net + every tax + pretax adds back up to gross, exactly."
  (let ((check (cmacs-calculator-paycheck 120000 'single 'us-tx 26 10000 2026)))
    (should (cmacs-calculator-tax-tests--close
             120000.0
             (+ (plist-get check :net-annual)
                (plist-get check :total-tax)
                (plist-get check :pretax-annual))))
    ;; The per-period figures are the annual ones divided by the periods.
    (should (cmacs-calculator-tax-tests--close
             (plist-get check :net-per-period)
             (/ (plist-get check :net-annual) 26.0)))
    (should (cmacs-calculator-tax-tests--close
             (plist-get check :gross-per-period) (/ 120000.0 26)))))

(ert-deftest cmacs-calculator-tax-paycheck-pretax-cuts-income-tax-not-fica ()
  "A pre-tax deferral lowers income tax but not payroll tax.
This is the documented 401(k) treatment, and the reason the FICA figure
must not move when PRETAX does."
  (let ((without (cmacs-calculator-paycheck 120000 'single 'us-tx 26 0 2026))
        (with (cmacs-calculator-paycheck 120000 'single 'us-tx 26 20000 2026)))
    (should (< (plist-get with :federal-tax) (plist-get without :federal-tax)))
    ;; FICA is charged on gross either way.
    (should (cmacs-calculator-tax-tests--close
             (plist-get with :fica) (plist-get without :fica)))))

(ert-deftest cmacs-calculator-tax-paycheck-state-matters ()
  "A state with an income tax leaves less than one without."
  (let ((texas (cmacs-calculator-paycheck 150000 'single 'us-tx 26 nil 2026))
        (california (cmacs-calculator-paycheck 150000 'single 'us-ca 26 nil)))
    (should (= 0.0 (plist-get texas :state-tax)))
    (should (> (plist-get california :state-tax) 0))
    (should (> (plist-get texas :net-annual)
               (plist-get california :net-annual)))))

(ert-deftest cmacs-calculator-tax-paycheck-rejects-bad-periods ()
  "Zero or negative pay periods is an error, not a division by zero."
  (should-error (cmacs-calculator-paycheck 100000 'single 'us-tx 0)
                :type 'cmacs-calculator-tax-error)
  (should-error (cmacs-calculator-paycheck 100000 'single 'us-tx -1)
                :type 'cmacs-calculator-tax-error))


;;;; Registry, vintage and validation ------------------------------

(ert-deftest cmacs-calculator-tax-registry-lookup ()
  "Year selection returns the requested year, and nil when absent."
  (should (eq 2026 (plist-get (cmacs-calculator-tax-get 'us-federal 2026) :year)))
  (should (eq 2025 (plist-get (cmacs-calculator-tax-get 'us-federal 2025) :year)))
  ;; Absent year: nil rather than the nearest match.
  (should (null (cmacs-calculator-tax-get 'us-federal 1999)))
  (should (null (cmacs-calculator-tax-get 'us-atlantis)))
  ;; Without a year, the newest registered table wins.
  (should (eq 2026 (plist-get (cmacs-calculator-tax-get 'us-federal) :year)))
  (should (memq 'us-federal (cmacs-calculator-tax-jurisdictions))))

(ert-deftest cmacs-calculator-tax-registry-replaces-same-year ()
  "Re-registering a jurisdiction/year replaces rather than duplicates."
  (let ((cmacs-calculator-tax-registry (make-hash-table :test 'eq)))
    (cmacs-calculator-tax-register
     '(:jurisdiction us-test :year 2026 :structure flat :rate 0.05
       :source "test" :retrieved "2026-07-17" :verified t))
    (cmacs-calculator-tax-register
     '(:jurisdiction us-test :year 2026 :structure flat :rate 0.07
       :source "test" :retrieved "2026-07-17" :verified t))
    (should (= 1 (length (cmacs-calculator-tax-list 'us-test))))
    (should (= 0.07 (plist-get (cmacs-calculator-tax-get 'us-test 2026) :rate)))))

(ert-deftest cmacs-calculator-tax-vintage-reports-age ()
  "Vintage dates a table against the current year."
  (let ((vintage (cmacs-calculator-tax-vintage 'us-federal 2025))
        (now (string-to-number (format-time-string "%Y"))))
    (should (eq 2025 (plist-get vintage :year)))
    (should (= (- now 2025) (plist-get vintage :age)))
    (should (eq (> now 2025) (and (plist-get vintage :stale) t)))
    (should (plist-get vintage :source))
    (should (plist-get vintage :retrieved))))

(ert-deftest cmacs-calculator-tax-all-tables-are-valid ()
  "Every registered table passes schema validation.
Brackets ascending from zero, rates in [0,1], required keys present,
structure recognized, and any unverified table carrying a note."
  (let ((failures (cmacs-calculator-tax-validate)))
    (should-not failures)))

(ert-deftest cmacs-calculator-tax-validate-catches-bad-tables ()
  "Validation actually rejects the mistakes it claims to catch.
Without this, a passing `cmacs-calculator-tax-validate' would prove
nothing -- a checker that accepts everything also accepts every table."
  (let ((cmacs-calculator-tax-registry (make-hash-table :test 'eq)))
    ;; A rate typed as a percentage instead of a fraction.
    (cmacs-calculator-tax-register
     '(:jurisdiction bad-rate :year 2026 :structure bracketed
       :source "x" :retrieved "2026-07-17" :verified t
       :brackets ((0 . 10) (10000 . 22))))
    ;; Brackets out of order.
    (cmacs-calculator-tax-register
     '(:jurisdiction bad-order :year 2026 :structure bracketed
       :source "x" :retrieved "2026-07-17" :verified t
       :brackets ((0 . 0.10) (50000 . 0.22) (10000 . 0.24))))
    ;; Ladder not starting at zero.
    (cmacs-calculator-tax-register
     '(:jurisdiction bad-start :year 2026 :structure bracketed
       :source "x" :retrieved "2026-07-17" :verified t
       :brackets ((5000 . 0.10) (50000 . 0.22))))
    ;; Missing :source and :retrieved.
    (cmacs-calculator-tax-register
     '(:jurisdiction bad-keys :year 2026 :structure bracketed
       :verified t :brackets ((0 . 0.10))))
    ;; Unverified with no explanation.
    (cmacs-calculator-tax-register
     '(:jurisdiction bad-silent :year 2026 :structure flat :rate 0.05
       :source "x" :retrieved "2026-07-17" :verified nil))
    ;; An unknown structure.
    (cmacs-calculator-tax-register
     '(:jurisdiction bad-structure :year 2026 :structure sideways
       :source "x" :retrieved "2026-07-17" :verified t))
    (let ((failures (cmacs-calculator-tax-validate)))
      (should (= 6 (length failures)))
      (dolist (jurisdiction '(bad-rate bad-order bad-start bad-keys
                              bad-silent bad-structure))
        (should (assq jurisdiction failures))))))

(ert-deftest cmacs-calculator-tax-every-table-has-provenance ()
  "Every shipped table names a source, a retrieval date and a year.
The data-integrity contract: no figure without a citation, and no
unverified figure without a note saying what is missing."
  (dolist (table (cmacs-calculator-tax-list))
    (let ((jurisdiction (plist-get table :jurisdiction)))
      (should (integerp (plist-get table :year)))
      (should (stringp (plist-get table :source)))
      (should (equal "2026-07-17" (plist-get table :retrieved)))
      (should (memq (plist-get table :structure) '(none flat bracketed)))
      ;; An unverified table must explain itself.
      (unless (plist-get table :verified)
        (should (stringp (plist-get table :note)))
        (should (> (length (plist-get table :note)) 0)))
      (ignore jurisdiction))))


;;;; Algebraic functions -------------------------------------------

(ert-deftest cmacs-calculator-tax-algebraic-functions ()
  "The defcalc helpers evaluate inside a Calc expression."
  (should (cmacs-calculator-tax-tests--close
           0.17 (cmacs-calculator-eval-number "effrate(17000, 100000)")))
  (should (cmacs-calculator-tax-tests--close
           83000.0 (cmacs-calculator-eval-number "aftertax(100000, 17000)")))
  (should (cmacs-calculator-tax-tests--close
           3612.5 (cmacs-calculator-eval-number "flattax(100000, 0.0425, 15000)")))
  ;; The capped payroll shape: at and above the cap the answer freezes.
  (should (cmacs-calculator-tax-tests--close
           11439.0 (cmacs-calculator-eval-number "ficatax(200000, 0.062, 184500)")))
  (should (cmacs-calculator-tax-tests--close
           11439.0 (cmacs-calculator-eval-number "ficatax(184500, 0.062, 184500)")))
  ;; A low income is under the cap and pays the plain rate.
  (should (cmacs-calculator-tax-tests--close
           6200.0 (cmacs-calculator-eval-number "ficatax(100000, 0.062, 184500)")))
  ;; flattax floors at zero rather than going negative.
  (should (= 0.0 (cmacs-calculator-eval-number "flattax(10000, 0.05, 15000)")))
  (should (cmacs-calculator-tax-tests--close
           1282.05128205 (cmacs-calculator-eval-number "grossup(1000, 0.22)"))))

(ert-deftest cmacs-calculator-tax-algebraic-functions-compose ()
  "They are first-class Calc functions, so they nest in a formula."
  (should (cmacs-calculator-tax-tests--close
           0.03 (cmacs-calculator-eval-number
                 "effrate(flattax(100000, 0.0425, 15000) - 612.5, 100000)")))
  ;; A gross-up round-trips through the flat rate it inverts.
  (should (cmacs-calculator-tax-tests--close
           1000.0 (cmacs-calculator-eval-number
                   "aftertax(grossup(1000, 0.22), grossup(1000, 0.22) * 0.22)"))))

(ert-deftest cmacs-calculator-tax-registered-in-calculator-registry ()
  "The tax calculators show up under the `tax' category."
  (let ((names (mapcar (lambda (meta) (plist-get meta :name))
                       (cmacs-calculator-list 'tax))))
    (dolist (name '(effrate aftertax flattax ficatax grossup))
      (should (memq name names)))
    (should (memq 'tax (cmacs-calculator-categories)))))

(provide 'cmacs-calculator-tax-tests)
;;; cmacs-calculator-tax-tests.el ends here
