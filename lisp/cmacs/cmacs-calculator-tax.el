;;; cmacs-calculator-tax.el --- Tax and paycheck calculators -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tax and paycheck calculators for `cmacs-calculator': progressive bracket
;; liability, federal and state income tax, FICA, self-employment tax,
;; capital gains, and a full paycheck breakdown.
;;
;; Math here, data next door
;; -------------------------
;; Nothing in this file knows a single tax rate.  Every bracket, cap and
;; deduction lives in `cmacs-calculator-tax-data.el' as a versioned plist
;; registered through `cmacs-calculator-tax-register'.  The split is the
;; whole point: tax law changes every year in ways that are pure data --
;; new thresholds, a rate cut, a raised wage cap -- so a new tax year is a
;; data edit and never a code change.  It also means the functions here are
;; jurisdiction-agnostic: `cmacs-calculator-tax-bracket-liability' walks the
;; US federal ladder and a Hawaii ladder with the same code, and would walk
;; a German one if someone registered it.
;;
;; The progressive walk
;; --------------------
;; `cmacs-calculator-tax-bracket-liability' is the core, and the one place
;; a bug would be both easy and expensive.  Brackets are MARGINAL: a 22%
;; bracket starting at $50,400 does NOT mean someone earning $50,401 owes
;; 22% of $50,401.  It means they owe 22% of the ONE dollar above $50,400,
;; on top of the tax on the first $50,400.  Getting this wrong is the
;; classic tax-calculator bug ("a raise pushed me into a higher bracket and
;; I take home less"), and it is wrong by thousands of dollars, not cents.
;;
;; The implementation therefore sums each band separately, and the test
;; suite checks it against the IRS's own published cumulative figures: the
;; 2026 single ladder must produce exactly the $1,240 / $5,800 / $17,966 /
;; $41,024 / $58,448 / $192,979.25 that Rev. Proc. 2025-32 prints in its
;; "The Tax Is" column.  Those constants are an independent check on the
;; walk -- they were computed by the IRS, not by this file.
;;
;; A bracket list is ((THRESHOLD . MARGINAL-RATE) ...) ascending, with the
;; first threshold at 0, and each rate applying to income ABOVE its
;; threshold up to the next one.  The top band has no upper bound.
;;
;; Stacking capital gains on the same walk
;; ---------------------------------------
;; Long-term capital gains are taxed at 0/15/20% in bands that stack ON TOP
;; of ordinary income -- so the same gain is taxed differently depending on
;; what else was earned.  That turns out to be exactly a bracket walk run
;; twice: tax(ordinary + gain) - tax(ordinary) over the capital-gain
;; ladder.  `cmacs-calculator-tax-capital-gains' does that rather than
;; reimplementing the banding, so the 0/15/20 thresholds are ordinary data.
;;
;; Trust, but report
;; -----------------
;; Wrong tax data is worse than no tax data, because it looks like an
;; answer.  Every registered table carries `:year', `:source', `:retrieved'
;; and `:verified'; `cmacs-calculator-tax-vintage' reports how old a table
;; is, and `cmacs-calculator-tax-validate' checks every table's shape
;; (ascending brackets, rates in [0,1], required keys).  Tables whose
;; figures could not be confirmed against a primary source are registered
;; with `:verified nil' and a `:note' saying what is missing -- an honest
;; gap rather than a plausible invention.  Callers that must not act on
;; unconfirmed figures should check `:verified' via
;; `cmacs-calculator-tax-vintage'.
;;
;; What is deliberately NOT modeled
;; --------------------------------
;; This is a calculator, not a tax preparer.  It does not model credits
;; (EITC, CTC), itemized deductions, the AMT, the 3.8% net investment
;; income tax, phase-outs, local/municipal income taxes (only flagged as
;; `:local-tax'), or QBI.  Results are estimates of the modeled components
;; only, and the paycheck breakdown is not a substitute for a W-4
;; withholding calculation.
;;
;; The simple, jurisdiction-free relationships (effective rate, gross-up,
;; a flat tax, a capped FICA-style levy) are defined with
;; `cmacs-calculator-defcalc', so they are first-class Calc algebraic
;; functions and compose inside any larger expression:
;;
;;   effrate(fedtax, 100000) + effrate(statetax, 100000)
;;
;; The table-driven and multi-part calculations return Lisp plists instead,
;; so they are ordinary functions rather than algebraic ones.

;;; Code:

(require 'calc)
(require 'calc-ext)
(require 'cmacs-calculator)


;;; Errors

(define-error 'cmacs-calculator-tax-error
              "CMacs tax calculator error" 'cmacs-calculator-error)

(define-error 'cmacs-calculator-tax-unknown-jurisdiction
              "Unknown tax jurisdiction" 'cmacs-calculator-tax-error)

(define-error 'cmacs-calculator-tax-unknown-year
              "No tax table for that year" 'cmacs-calculator-tax-error)

(define-error 'cmacs-calculator-tax-invalid-table
              "Invalid tax table" 'cmacs-calculator-tax-error)


;;; Filing statuses

(defconst cmacs-calculator-tax-filing-statuses
  '(single married-joint married-separate head-of-household)
  "The filing statuses this subsystem understands.
Per-status data keys are formed by suffixing a base key with the status,
e.g. `:brackets-married-joint'.")

(defconst cmacs-calculator-tax--status-aliases
  '((mfj . married-joint)
    (married-filing-jointly . married-joint)
    (joint . married-joint)
    (mfs . married-separate)
    (married-filing-separately . married-separate)
    (separate . married-separate)
    (hoh . head-of-household)
    (household . head-of-household)
    (unmarried . single)
    (surviving-spouse . married-joint))
  "Accepted spellings of a filing status, mapped to the canonical symbol.
`surviving-spouse' maps to `married-joint' because the Internal Revenue
Code puts surviving spouses on the joint-return rate schedule
\(section 1(j)(2)(A)).")

(defun cmacs-calculator-tax-normalize-status (status)
  "Return the canonical filing-status symbol for STATUS.
Accepts the canonical names in `cmacs-calculator-tax-filing-statuses'
and the common spellings in `cmacs-calculator-tax--status-aliases'.
Signals `cmacs-calculator-tax-error' for anything else rather than
silently falling back to a status the caller did not ask for."
  (or (car (memq status cmacs-calculator-tax-filing-statuses))
      (cdr (assq status cmacs-calculator-tax--status-aliases))
      (signal 'cmacs-calculator-tax-error
              (list "unknown filing status" status
                    cmacs-calculator-tax-filing-statuses))))


;;; Registry
;;
;; Keyed by jurisdiction, holding every registered year, so a caller can ask
;; for a specific year and a stale table can be spotted rather than silently
;; used as if current.

(defvar cmacs-calculator-tax-registry (make-hash-table :test 'eq)
  "Map of jurisdiction symbol to its list of tax tables, newest year first.
See `cmacs-calculator-tax-register' for the table schema.")

(defun cmacs-calculator-tax-register (table)
  "Record TABLE, a tax-table plist, in `cmacs-calculator-tax-registry'.

TABLE describes one jurisdiction in one tax year.  Registering a
jurisdiction/year pair again replaces the previous table.  Recognized keys:

  :jurisdiction  symbol naming the jurisdiction, e.g. `us-federal', `us-ca'
  :year          integer tax year the figures apply to
  :structure     `none', `flat' or `bracketed'
  :source        URL or official document name the figures came from
  :retrieved     ISO date the figures were read from :source
  :verified      t if confirmed against :source, nil if not
  :note          free text; REQUIRED when :verified is nil
  :name          human-readable jurisdiction name

  :filing-statuses      statuses the table provides data for
  :brackets             ((THRESHOLD . RATE) ...) ascending, shared by all
                        statuses
  :brackets-STATUS      per-status ladder, overriding :brackets
  :rate                 flat rate, for `flat' structures
  :standard-deduction   shared standard deduction
  :standard-deduction-STATUS   per-status standard deduction
  :personal-exemption   shared personal exemption
  :personal-exemption-STATUS   per-status personal exemption
  :capital-gains-brackets-STATUS  long-term capital-gain ladder

  :fica-rate                 Social Security rate on the employee
  :fica-wage-cap             wage cap above which no Social Security is due
  :medicare-rate             Medicare rate, uncapped
  :medicare-addl-rate        Additional Medicare rate
  :medicare-addl-threshold-STATUS   where Additional Medicare starts
  :se-rate / :se-medicare-rate / :se-net-earnings-factor
                             self-employment equivalents

  :federal-deduction-allowed  non-nil if the state deducts federal tax paid
  :local-tax                  non-nil if localities levy their own income tax

Every key is optional except :jurisdiction, :year and :structure, which
`cmacs-calculator-tax-validate' enforces along with the shape of the rest."
  (let* ((jurisdiction (plist-get table :jurisdiction))
         (year (plist-get table :year)))
    (unless (symbolp jurisdiction)
      (signal 'cmacs-calculator-tax-invalid-table
              (list ":jurisdiction must be a symbol" jurisdiction)))
    (unless (integerp year)
      (signal 'cmacs-calculator-tax-invalid-table
              (list ":year must be an integer" jurisdiction year)))
    (let (tables)
      ;; Re-registering a jurisdiction/year replaces it rather than
      ;; shadowing it, so reloading this file twice cannot leave two
      ;; tables for the same year and a coin-flip about which wins.
      (dolist (existing (gethash jurisdiction cmacs-calculator-tax-registry))
        (unless (eql (plist-get existing :year) year)
          (push existing tables)))
      (puthash jurisdiction
               (sort (cons (copy-sequence table) tables)
                     (lambda (a b) (> (plist-get a :year) (plist-get b :year))))
               cmacs-calculator-tax-registry))
    jurisdiction))

(defun cmacs-calculator-tax-get (jurisdiction &optional year)
  "Return the tax table for JURISDICTION, or nil if there is none.
With YEAR, return that exact tax year's table, or nil if it was never
registered -- deliberately not the nearest year, since quietly answering
with the wrong year's rates is the failure mode this whole design exists
to prevent.  Without YEAR, return the most recent table on file, which
`cmacs-calculator-tax-vintage' can then be asked to date."
  (let ((tables (gethash jurisdiction cmacs-calculator-tax-registry)))
    (if (null year)
        (car tables)
      (let (found)
        (dolist (table tables)
          (when (and (null found) (eql (plist-get table :year) year))
            (setq found table)))
        found))))

(defun cmacs-calculator-tax-list (&optional jurisdiction)
  "Return every registered tax table, newest year first within each entry.
With JURISDICTION, return only that jurisdiction's tables.  Sorted by
jurisdiction name so callers render a stable order."
  (if jurisdiction
      (gethash jurisdiction cmacs-calculator-tax-registry)
    (let (out)
      (dolist (name (cmacs-calculator-tax-jurisdictions))
        (setq out (append out (gethash name cmacs-calculator-tax-registry))))
      out)))

(defun cmacs-calculator-tax-jurisdictions ()
  "Return the sorted list of registered jurisdiction symbols."
  (let (out)
    (maphash (lambda (k _v) (push k out)) cmacs-calculator-tax-registry)
    (sort out (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun cmacs-calculator-tax--table (jurisdiction &optional year)
  "Return the tax table for JURISDICTION and YEAR, or signal.
Unlike `cmacs-calculator-tax-get' this never returns nil: an absent
jurisdiction or an absent year is an error naming what IS available,
because the alternative is computing tax from nothing."
  (or (cmacs-calculator-tax-get jurisdiction year)
      (if (gethash jurisdiction cmacs-calculator-tax-registry)
          (signal 'cmacs-calculator-tax-unknown-year
                  (list jurisdiction year
                        (mapcar (lambda (table) (plist-get table :year))
                                (cmacs-calculator-tax-list jurisdiction))))
        (signal 'cmacs-calculator-tax-unknown-jurisdiction
                (list jurisdiction (cmacs-calculator-tax-jurisdictions))))))

(defun cmacs-calculator-tax--for-status (table base status)
  "Return TABLE's BASE value for STATUS, falling back to the shared key.
BASE is a key name without a leading colon, e.g. \"brackets\"; STATUS is
a canonical filing status.  Looks for `:BASE-STATUS' first so a table can
give per-status ladders, then plain `:BASE' for the many jurisdictions
whose figures do not vary by status."
  (or (plist-get table (intern (format ":%s-%s" base status)))
      (plist-get table (intern (format ":%s" base)))))

(defun cmacs-calculator-tax--brackets (table base status)
  "Return TABLE's BASE ladder for STATUS, or signal if there is none.

Never returns nil.  A missing ladder must not fall through to an empty
bracket list, because walking one yields a tax of zero -- a confident,
silent, catastrophically wrong answer for a state that certainly does
tax that filer.  Not every jurisdiction publishes a ladder for every
status, so the honest response to a gap is to say so and name the
statuses the table does cover (its `:filing-statuses')."
  (or (cmacs-calculator-tax--for-status table base status)
      (signal 'cmacs-calculator-tax-invalid-table
              (list (format "no %s ladder for this filing status" base)
                    (plist-get table :jurisdiction)
                    (plist-get table :year)
                    status
                    :covers (plist-get table :filing-statuses)))))


;;; The progressive bracket walk

(defun cmacs-calculator-tax-bracket-liability (taxable-income brackets)
  "Return the tax on TAXABLE-INCOME under BRACKETS, as a float.

BRACKETS is ((THRESHOLD . MARGINAL-RATE) ...) in ascending threshold
order, the first threshold being 0.  Each rate applies only to the income
falling WITHIN its band -- between its own threshold and the next one --
so the tax is the sum over bands of RATE * (band width occupied), and the
top band runs to infinity.

This is the marginal/progressive computation, not a flat rate on the
whole amount: at the 2026 federal single ladder, $50,401 owes $5,800.22
\(the full tax on the first $50,400, plus 22% of the single dollar above
it), not 22% of $50,401.

Income at or below zero yields zero, so a negative income -- a business
loss -- is not turned into a negative tax."
  (let ((income (max 0 taxable-income))
        (tax 0.0)
        (bands brackets))
    (while bands
      (let* ((band (car bands))
             (lower (car band))
             (rate (cdr band))
             (next (cadr bands))
             ;; The band ends where the next one starts; the last runs on.
             (upper (and next (car next))))
        (when (> income lower)
          (setq tax (+ tax (* rate (- (if upper (min income upper) income)
                                      lower)))))
        (setq bands (cdr bands))))
    tax))

(defun cmacs-calculator-tax-marginal-rate (taxable-income brackets)
  "Return the marginal rate on TAXABLE-INCOME under BRACKETS, as a number.

This is the rate that would apply to the NEXT dollar earned, so income
sitting exactly on a threshold gets the higher band's rate: the threshold
is where that band begins.  BRACKETS is as in
`cmacs-calculator-tax-bracket-liability'."
  (let ((income (max 0 taxable-income))
        (rate 0))
    (dolist (band brackets)
      (when (>= income (car band))
        (setq rate (cdr band))))
    rate))

(defun cmacs-calculator-tax-effective-rate (tax income)
  "Return TAX as a fraction of INCOME, as a float.

Zero for a non-positive INCOME rather than a division error, since an
effective rate on nothing is not meaningful.  The effective rate is
always at most the marginal rate under any ascending ladder -- the lower
bands drag the average down -- which is the sanity check to reach for
when a bracket walk looks wrong."
  (if (<= income 0) 0.0 (/ (float tax) income)))


;;; Algebraic helpers
;;
;; The relationships that hold in every jurisdiction and need no table, so
;; they can be first-class Calc functions and compose inside a formula.

(cmacs-calculator-defcalc effrate (tax income)
  :category tax
  :title "Effective tax rate"
  :doc "TAX as a fraction of INCOME -- the average rate actually paid,
as opposed to the marginal rate on the last dollar."
  :args ((tax "Tax owed")
         (income "Income the tax was computed on"))
  :returns "Effective rate as a fraction, e.g. 0.17 for 17%"
  :examples (("effrate(17000, 100000)" . "0.17"))
  (/ tax income))

(cmacs-calculator-defcalc aftertax (income tax)
  :category tax
  :title "After-tax income"
  :doc "Income remaining once TAX is paid."
  :args ((income "Gross income") (tax "Tax owed"))
  :returns "After-tax income"
  :examples (("aftertax(100000, 17000)" . "83000"))
  (- income tax))

(cmacs-calculator-defcalc flattax (income rate deduction)
  :category tax
  :title "Flat tax with a deduction"
  :doc "Tax at a single RATE on INCOME above DEDUCTION.  The structure
used by the flat-rate states; the deduction floor means a low income
owes zero rather than a negative tax."
  :args ((income "Gross income")
         (rate "Flat rate as a fraction, e.g. 0.0425")
         (deduction "Amount exempt from tax"))
  :returns "Tax owed"
  :examples (("flattax(100000, 0.0425, 15000)" . "3612.5"))
  (* rate (max 0 (- income deduction))))

(cmacs-calculator-defcalc ficatax (wages rate cap)
  :category tax
  :title "Capped payroll tax"
  :doc "Tax at RATE on WAGES up to CAP, and nothing above it.  The shape
of the Social Security tax: once wages pass the cap the levy stops, so
this flattens out rather than growing."
  :args ((wages "Wages subject to the tax")
         (rate "Rate as a fraction, e.g. 0.062")
         (cap "Wage cap above which no further tax is due"))
  :returns "Tax owed"
  :examples (("ficatax(200000, 0.062, 184500)" . "11439."))
  (* rate (min wages cap)))

(cmacs-calculator-defcalc grossup (net rate)
  :category tax
  :title "Gross-up"
  :doc "Gross amount needed to leave NET after tax at RATE.  Note this is
the inverse of a FLAT rate: grossing up through a progressive ladder
needs `cmacs-calculator-tax-federal', since the rate itself moves."
  :args ((net "Desired after-tax amount")
         (rate "Tax rate as a fraction"))
  :returns "Required gross amount"
  :examples (("grossup(1000, 0.22)" . "1282.05128205"))
  (/ net (- 1 rate)))


;;; Federal income tax

(defun cmacs-calculator-tax-federal (income status &optional year)
  "Return a plist breaking down US federal income tax on INCOME.

INCOME is gross income for the year; STATUS is a filing status (see
`cmacs-calculator-tax-filing-statuses').  YEAR selects the tax year's
table, defaulting to the most recent registered -- which is not
necessarily the current one, so consult `cmacs-calculator-tax-vintage'
if that matters.

The standard deduction for STATUS is subtracted to reach taxable income,
which the bracket ladder is then walked over.  Itemized deductions,
credits and the AMT are not modeled; pass a pre-reduced INCOME to
approximate itemizing.

Keys: :jurisdiction, :year, :status, :gross-income, :standard-deduction,
:taxable-income, :tax, :marginal-rate, :effective-rate, :verified,
:source.  The :effective-rate is measured against gross INCOME, not
taxable income, so it answers \"what share of what I earned went to
federal tax\"."
  (let* ((status (cmacs-calculator-tax-normalize-status status))
         (table (cmacs-calculator-tax--table 'us-federal year))
         (deduction (or (cmacs-calculator-tax--for-status
                         table "standard-deduction" status)
                        0))
         (brackets (cmacs-calculator-tax--brackets table "brackets" status))
         (taxable (max 0 (- income deduction)))
         (tax (cmacs-calculator-tax-bracket-liability taxable brackets)))
    (list :jurisdiction 'us-federal
          :year (plist-get table :year)
          :status status
          :gross-income income
          :standard-deduction deduction
          :taxable-income taxable
          :tax tax
          :marginal-rate (cmacs-calculator-tax-marginal-rate taxable brackets)
          :effective-rate (cmacs-calculator-tax-effective-rate tax income)
          :verified (plist-get table :verified)
          :source (plist-get table :source))))


;;; State income tax

(defun cmacs-calculator-tax-state (income status state &optional year)
  "Return a plist breaking down STATE income tax on INCOME.

STATE is a jurisdiction symbol such as `us-ca'; STATUS is a filing
status; YEAR selects the tax year, defaulting to the newest registered.

All three structures are handled from the table's `:structure':

  `none'       no state income tax on wages -- returns a zero tax
               cleanly rather than signalling, so callers can loop over
               all fifty states without special-casing the nine
  `flat'       a single `:rate' above the deductions
  `bracketed'  the progressive ladder walk

The standard deduction and personal exemption for STATUS are subtracted
where the table provides them.  A state's own credits, local/municipal
income taxes (only flagged as `:local-tax'), and any deduction for
federal tax paid (flagged as `:federal-deduction-allowed') are NOT
applied -- see the `:note' on the relevant tables.

Keys: :jurisdiction, :year, :status, :structure, :gross-income,
:standard-deduction, :personal-exemption, :taxable-income, :tax,
:marginal-rate, :effective-rate, :local-tax, :federal-deduction-allowed,
:verified, :source."
  (let* ((status (cmacs-calculator-tax-normalize-status status))
         (table (cmacs-calculator-tax--table state year))
         (structure (plist-get table :structure))
         (deduction (or (cmacs-calculator-tax--for-status
                         table "standard-deduction" status)
                        0))
         (exemption (or (cmacs-calculator-tax--for-status
                         table "personal-exemption" status)
                        0))
         (brackets (and (eq structure 'bracketed)
                        (cmacs-calculator-tax--brackets table "brackets"
                                                        status)))
         (taxable (if (eq structure 'none)
                      0
                    (max 0 (- income deduction exemption))))
         (tax (pcase structure
                ('none 0.0)
                ('flat (* (or (plist-get table :rate) 0) taxable))
                ('bracketed
                 (cmacs-calculator-tax-bracket-liability taxable brackets))
                (_ (signal 'cmacs-calculator-tax-invalid-table
                           (list "unknown :structure" state structure))))))
    (list :jurisdiction state
          :year (plist-get table :year)
          :status status
          :structure structure
          :gross-income income
          :standard-deduction deduction
          :personal-exemption exemption
          :taxable-income taxable
          :tax (float tax)
          ;; The rate on the next dollar of TAXABLE income, which for a
          ;; flat state is its rate and for a `none' state is nothing.
          ;; Consistent with the bracketed path, which likewise reports
          ;; the first band's rate at zero taxable income.
          :marginal-rate (pcase structure
                           ('none 0)
                           ('flat (or (plist-get table :rate) 0))
                           (_ (cmacs-calculator-tax-marginal-rate
                               taxable brackets)))
          :effective-rate (cmacs-calculator-tax-effective-rate tax income)
          :local-tax (plist-get table :local-tax)
          :federal-deduction-allowed (plist-get table :federal-deduction-allowed)
          :verified (plist-get table :verified)
          :source (plist-get table :source))))


;;; FICA

(defun cmacs-calculator-tax-fica (wages status &optional year)
  "Return a plist breaking down the employee's FICA tax on WAGES.

FICA is two taxes with three different shapes, which is why this cannot
be one multiplication:

  Social Security  a flat rate up to `:fica-wage-cap' and nothing above,
                   so it is CAPPED -- the same absolute amount for a
                   $200k and a $2M earner
  Medicare         the same flat rate on every dollar, uncapped
  Additional       a further rate on wages above a threshold that varies
    Medicare       by filing status, introduced by the ACA and NOT
                   indexed for inflation, so it catches more people yearly

Only the employee's share is returned; the employer pays a matching
Social Security and Medicare amount (but not the Additional Medicare).
STATUS is a filing status, YEAR the tax year.  Note that employers
withhold Additional Medicare on wages over $200,000 regardless of
status, so a joint filer's withholding and actual liability differ --
this returns the LIABILITY.

Keys: :jurisdiction, :year, :status, :wages, :social-security, :medicare,
:additional-medicare, :total, :effective-rate, :wage-cap, :verified,
:source."
  (let* ((status (cmacs-calculator-tax-normalize-status status))
         (table (cmacs-calculator-tax--table 'us-federal year))
         (wages (max 0 wages))
         (cap (or (plist-get table :fica-wage-cap) 0))
         (ss (* (or (plist-get table :fica-rate) 0) (min wages cap)))
         (medicare (* (or (plist-get table :medicare-rate) 0) wages))
         (threshold (or (cmacs-calculator-tax--for-status
                         table "medicare-addl-threshold" status)
                        0))
         (addl (* (or (plist-get table :medicare-addl-rate) 0)
                  (max 0 (- wages threshold))))
         (total (+ ss medicare addl)))
    (list :jurisdiction 'us-federal
          :year (plist-get table :year)
          :status status
          :wages wages
          :social-security (float ss)
          :medicare (float medicare)
          :additional-medicare (float addl)
          :total (float total)
          :effective-rate (cmacs-calculator-tax-effective-rate total wages)
          :wage-cap cap
          :verified (plist-get table :verified)
          :source (plist-get table :source))))


;;; Self-employment tax

(defun cmacs-calculator-tax-self-employment (net-earnings status &optional year)
  "Return a plist breaking down self-employment tax on NET-EARNINGS.

NET-EARNINGS is net profit from self-employment (business income less
business expenses), STATUS a filing status, YEAR the tax year.

The self-employed pay both halves of FICA, but not on everything: only
`:se-net-earnings-factor' of net earnings -- 92.35% -- is subject to the
tax.  That factor is not arbitrary; it removes the employer half from
the base, so a self-employed person and an employee earning the same
total compensation face the same effective burden.  Half of the
resulting tax is then deductible against income tax, which
`:deduction' reports; the Additional Medicare portion is excluded from
that deduction, matching the IRS treatment.

Keys: :jurisdiction, :year, :status, :net-earnings, :taxable-earnings,
:social-security, :medicare, :additional-medicare, :total, :deduction,
:effective-rate, :verified, :source."
  (let* ((status (cmacs-calculator-tax-normalize-status status))
         (table (cmacs-calculator-tax--table 'us-federal year))
         (net (max 0 net-earnings))
         (factor (or (plist-get table :se-net-earnings-factor) 1))
         (taxable (* net factor))
         (cap (or (plist-get table :fica-wage-cap) 0))
         (ss (* (or (plist-get table :se-rate) 0) (min taxable cap)))
         (medicare (* (or (plist-get table :se-medicare-rate) 0) taxable))
         (threshold (or (cmacs-calculator-tax--for-status
                         table "medicare-addl-threshold" status)
                        0))
         (addl (* (or (plist-get table :medicare-addl-rate) 0)
                  (max 0 (- taxable threshold))))
         (total (+ ss medicare addl)))
    (list :jurisdiction 'us-federal
          :year (plist-get table :year)
          :status status
          :net-earnings net
          :taxable-earnings (float taxable)
          :social-security (float ss)
          :medicare (float medicare)
          :additional-medicare (float addl)
          :total (float total)
          ;; The employer-equivalent half, deductible against income tax.
          ;; Additional Medicare has no employer half and is not deductible.
          :deduction (/ (+ ss medicare) 2.0)
          :effective-rate (cmacs-calculator-tax-effective-rate total net)
          :verified (plist-get table :verified)
          :source (plist-get table :source))))


;;; Capital gains

(defun cmacs-calculator-tax-capital-gains (gain income status
                                                &optional long-term year)
  "Return a plist breaking down federal tax on a capital GAIN.

INCOME is the other TAXABLE income for the year (already net of
deductions); STATUS is a filing status; YEAR the tax year.  LONG-TERM
non-nil prices the gain at the preferential 0/15/20% rates, which
require the asset to have been held more than one year; nil treats it as
short-term.

Both cases are the same computation -- the gain STACKS on top of
ordinary income, so an identical gain is taxed differently depending on
what else was earned, and the tax on it is the difference the gain makes
to the total:

  tax(income + gain) - tax(income)

over the relevant ladder.  Short-term gains use the ordinary bracket
ladder because they are ordinary income; long-term gains use the
capital-gain ladder.  This is why the answer needs INCOME at all: a
$50,000 long-term gain is free to someone with no other income and
taxed at 15% to someone already earning $200,000.

The 3.8% net investment income tax is NOT modeled and applies on top for
higher earners.

Keys: :jurisdiction, :year, :status, :gain, :other-income, :long-term,
:tax, :effective-rate, :marginal-rate, :verified, :source."
  (let* ((status (cmacs-calculator-tax-normalize-status status))
         (table (cmacs-calculator-tax--table 'us-federal year))
         (income (max 0 income))
         (gain (max 0 gain))
         (brackets (cmacs-calculator-tax--brackets
                    table (if long-term "capital-gains-brackets" "brackets")
                    status))
         (tax (- (cmacs-calculator-tax-bracket-liability (+ income gain)
                                                         brackets)
                 (cmacs-calculator-tax-bracket-liability income brackets))))
    (list :jurisdiction 'us-federal
          :year (plist-get table :year)
          :status status
          :gain gain
          :other-income income
          :long-term (and long-term t)
          :tax tax
          :effective-rate (cmacs-calculator-tax-effective-rate tax gain)
          :marginal-rate (cmacs-calculator-tax-marginal-rate (+ income gain)
                                                             brackets)
          :verified (plist-get table :verified)
          :source (plist-get table :source))))


;;; Paycheck

(defun cmacs-calculator-paycheck (gross status state periods &optional pretax
                                        year)
  "Return a plist breaking down a paycheck, per period and per year.

GROSS is annual gross pay, STATUS a filing status, STATE a jurisdiction
symbol such as `us-tx' (use `us-none' or any `none'-structure table for
no state tax), PERIODS the number of pay periods per year -- 26 for
biweekly, 24 semimonthly, 12 monthly, 52 weekly.  PRETAX is optional
annual pre-tax deductions.  YEAR selects the tax year.

How PRETAX is treated -- read this before trusting the number
--------------------------------------------------------------
PRETAX reduces income subject to FEDERAL AND STATE INCOME TAX but NOT
wages subject to FICA.  That is correct for the common case, a
traditional 401(k) deferral, which escapes income tax but is still
hit by Social Security and Medicare.  It is WRONG for Section 125
cafeteria-plan deductions -- health, dental, vision, FSA -- which escape
FICA too.  To model those, subtract them from GROSS yourself and pass
the remainder, rather than passing them as PRETAX.

This is an estimate of the modeled components, not a W-4 withholding
calculation: credits, additional withholding, local income taxes and
state disability levies are not included.

Keys: :gross-annual, :gross-per-period, :pretax-annual, :periods,
:federal-tax, :state-tax, :fica, :social-security, :medicare,
:additional-medicare, :total-tax, :net-annual, :net-per-period,
:effective-rate, :marginal-rate, :federal, :state -- the last two being
the full sub-plists from `cmacs-calculator-tax-federal' and
`cmacs-calculator-tax-state', so the caller can inspect the vintage and
sources behind the figures.

The :marginal-rate is the federal and state marginal rates ADDED, which
is the rate on the next dollar of salary.  It excludes FICA (the next
dollar may or may not be over the wage cap) and ignores that state tax
is deductible federally for itemizers, so treat it as an upper bound on
the income-tax bite rather than an exact figure."
  (unless (and (numberp periods) (> periods 0))
    (signal 'cmacs-calculator-tax-error
            (list "pay periods per year must be positive" periods)))
  (let* ((status (cmacs-calculator-tax-normalize-status status))
         (pretax (or pretax 0))
         (taxable-wages (max 0 (- gross pretax)))
         (federal (cmacs-calculator-tax-federal taxable-wages status year))
         (state-tax (cmacs-calculator-tax-state taxable-wages status state year))
         ;; FICA is levied on gross: a 401(k) deferral defers income tax,
         ;; not payroll tax.
         (fica (cmacs-calculator-tax-fica gross status year))
         (total (+ (plist-get federal :tax)
                   (plist-get state-tax :tax)
                   (plist-get fica :total)))
         (net (- gross total pretax)))
    (list :gross-annual gross
          :gross-per-period (/ (float gross) periods)
          :pretax-annual pretax
          :periods periods
          :federal-tax (plist-get federal :tax)
          :state-tax (plist-get state-tax :tax)
          :fica (plist-get fica :total)
          :social-security (plist-get fica :social-security)
          :medicare (plist-get fica :medicare)
          :additional-medicare (plist-get fica :additional-medicare)
          :total-tax total
          :net-annual net
          :net-per-period (/ (float net) periods)
          :effective-rate (cmacs-calculator-tax-effective-rate total gross)
          :marginal-rate (+ (plist-get federal :marginal-rate)
                            (plist-get state-tax :marginal-rate))
          :federal federal
          :state state-tax)))


;;; Vintage

(defun cmacs-calculator-tax-vintage (jurisdiction &optional year)
  "Return a plist describing the provenance and age of a tax table.

JURISDICTION names the table; YEAR selects a tax year, defaulting to the
newest registered.  Tax data goes stale annually and silently -- last
year's brackets still compute, they are just wrong -- so this reports
the table's own `:year' against the current one instead of leaving the
caller to assume it is current.

Keys: :jurisdiction, :name, :year, :current-year, :age -- years between
the table and now, 0 meaning current -- :stale (non-nil when :age is
positive), :verified, :source, :retrieved, :note, :structure."
  (let* ((table (cmacs-calculator-tax--table jurisdiction year))
         (table-year (plist-get table :year))
         (now (string-to-number (format-time-string "%Y")))
         (age (- now table-year)))
    (list :jurisdiction jurisdiction
          :name (plist-get table :name)
          :year table-year
          :current-year now
          :age age
          :stale (> age 0)
          :verified (plist-get table :verified)
          :source (plist-get table :source)
          :retrieved (plist-get table :retrieved)
          :note (plist-get table :note)
          :structure (plist-get table :structure))))


;;; Schema validation
;;
;; The tables are hand-entered from published documents, so the plausible
;; mistakes are transcription ones -- a bracket out of order, a rate typed
;; as 22 instead of 0.22, a missing source.  Each would produce a confident
;; wrong answer, so they are checked mechanically rather than by eye.

(defun cmacs-calculator-tax--validate-brackets (brackets label)
  "Return a list of problems with BRACKETS, describing them as LABEL."
  (let ((problems nil)
        (previous nil))
    (cond
     ((null brackets)
      (push (format "%s: empty bracket list" label) problems))
     ((not (listp brackets))
      (push (format "%s: not a list" label) problems))
     (t
      (unless (eql (car (car brackets)) 0)
        (push (format "%s: first threshold is %S, not 0"
                      label (car (car brackets)))
              problems))
      (dolist (band brackets)
        (if (not (consp band))
            (push (format "%s: band %S is not (THRESHOLD . RATE)" label band)
                  problems)
          (let ((threshold (car band))
                (rate (cdr band)))
            (cond
             ((not (numberp threshold))
              (push (format "%s: threshold %S is not a number" label threshold)
                    problems))
             ((< threshold 0)
              (push (format "%s: threshold %S is negative" label threshold)
                    problems))
             ((and previous (<= threshold previous))
              (push (format "%s: threshold %S does not exceed previous %S"
                            label threshold previous)
                    problems))
             (t (setq previous threshold)))
            (cond
             ((not (numberp rate))
              (push (format "%s: rate %S is not a number" label rate) problems))
             ;; A rate above 1 is nearly always a percentage typed as a
             ;; whole number -- 22 for 0.22 -- which would tax a $50k income
             ;; $1.1M.
             ((or (< rate 0) (> rate 1))
              (push (format "%s: rate %S is outside [0,1]" label rate)
                    problems))))))))
    problems))

(defun cmacs-calculator-tax--validate-table (table)
  "Return a list of problems with TABLE, a tax-table plist.
Empty when the table is well-formed.  This checks SHAPE, not truth: no
amount of validation can tell whether a bracket matches the statute, only
whether it is internally coherent."
  (let ((problems nil)
        (jurisdiction (plist-get table :jurisdiction))
        (structure (plist-get table :structure)))
    ;; Required keys.
    (dolist (key '(:jurisdiction :year :structure :source :retrieved))
      (when (null (plist-get table key))
        (push (format "missing required key %s" key) problems)))
    (unless (memq structure '(none flat bracketed))
      (push (format ":structure is %S, not one of none/flat/bracketed"
                    structure)
            problems))
    (let ((year (plist-get table :year)))
      (when (and (integerp year) (not (<= 1900 year 2100)))
        (push (format ":year %S is implausible" year) problems)))
    ;; A table nobody could confirm must say what is missing, so an
    ;; unverified figure can never be mistaken for an unremarkable one.
    (when (and (null (plist-get table :verified))
               (null (plist-get table :note)))
      (push ":verified is nil but no :note explains why" problems))
    ;; Structure-specific shape.
    (pcase structure
      ('flat
       (let ((rate (plist-get table :rate)))
         (cond
          ((not (numberp rate))
           (push (format "flat structure needs a numeric :rate, got %S" rate)
                 problems))
          ((or (< rate 0) (> rate 1))
           (push (format ":rate %S is outside [0,1]" rate) problems)))))
      ('bracketed
       (let ((found nil))
         (dolist (status cmacs-calculator-tax-filing-statuses)
           (let ((brackets (cmacs-calculator-tax--for-status
                            table "brackets" status)))
             (when brackets
               (setq found t)
               (setq problems
                     (append (cmacs-calculator-tax--validate-brackets
                              brackets (format "brackets-%s" status))
                             problems)))))
         (unless found
           (push "bracketed structure has no bracket list" problems))))
      ('none
       (when (plist-get table :rate)
         (push "structure is none but a :rate is set" problems))))
    ;; Capital-gain ladders, where present, are ordinary bracket lists.
    (dolist (status cmacs-calculator-tax-filing-statuses)
      (let ((brackets (plist-get table
                                 (intern (format ":capital-gains-brackets-%s"
                                                 status)))))
        (when brackets
          (setq problems
                (append (cmacs-calculator-tax--validate-brackets
                         brackets (format "capital-gains-brackets-%s" status))
                        problems)))))
    ;; Loose rates elsewhere in the table.
    (dolist (key '(:fica-rate :medicare-rate :medicare-addl-rate
                   :se-rate :se-medicare-rate :se-net-earnings-factor))
      (let ((rate (plist-get table key)))
        (when (and rate (or (not (numberp rate)) (< rate 0) (> rate 1)))
          (push (format "%s is %S, outside [0,1]" key rate) problems))))
    (when (and jurisdiction (not (symbolp jurisdiction)))
      (push ":jurisdiction is not a symbol" problems))
    (nreverse problems)))

(defun cmacs-calculator-tax-validate (&optional jurisdiction)
  "Check registered tax tables and return an alist of failures.

Each element is (JURISDICTION YEAR . PROBLEMS), where PROBLEMS is a list
of human-readable strings.  A nil return means every table checked is
well-formed.  With JURISDICTION, check only that one.

Verifies that required keys are present, `:structure' is one of
none/flat/bracketed, bracket ladders start at 0 and ascend with rates in
[0,1], flat tables carry a usable `:rate', and unverified tables explain
themselves with a `:note'.

This is a check on internal consistency and honesty of labelling.  It
cannot verify that a rate matches the law -- only a primary source can do
that, which is what `:source' records."
  (let (out)
    (dolist (table (cmacs-calculator-tax-list jurisdiction))
      (let ((problems (cmacs-calculator-tax--validate-table table)))
        (when problems
          (push (cons (plist-get table :jurisdiction)
                      (cons (plist-get table :year) problems))
                out))))
    (nreverse out)))

(provide 'cmacs-calculator-tax)
;;; cmacs-calculator-tax.el ends here
