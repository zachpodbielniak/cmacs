;;; cmacs-calculator-tax-data.el --- Tax jurisdiction data -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Versioned tax tables for `cmacs-calculator-tax': the US federal
;; jurisdiction and all fifty states plus the District of Columbia.
;;
;; This file is DATA ONLY.  Not one line of arithmetic lives here -- the
;; math is in `cmacs-calculator-tax.el' and is year- and
;; jurisdiction-agnostic, so a new tax year means editing this file and
;; nothing else.  Each table is a plist registered with
;; `cmacs-calculator-tax-register'; see that function's docstring for the
;; full schema.
;;
;; Provenance rules (the point of this file)
;; -----------------------------------------
;; Wrong tax data is worse than absent tax data, because it looks like an
;; answer and nobody re-derives it.  So:
;;
;;   * Every table carries `:year', `:source' and `:retrieved'.  `:source'
;;     names the actual document the figures were read out of, not a
;;     summary of it.
;;   * `:verified t' means EVERY figure the calculator actually uses -- the
;;     brackets, rate, standard deduction and exemption -- was read from
;;     the document named in `:source' AND applies to the table's own
;;     `:year'.  Anything less is `:verified nil', and then `:note' MUST
;;     say precisely what is missing; `cmacs-calculator-tax-validate'
;;     enforces that pairing.  So a table whose brackets are solid but
;;     whose standard deduction had to be carried over from last year is
;;     unverified (Kansas, Oklahoma), as is one built from a source that
;;     disclaims use for real returns (Nebraska).
;;
;;     `:verified t' is NOT a promise the computed figure is a filer's
;;     true liability -- unmodeled credits, local taxes and recapture
;;     rules all still apply, and the `:note' says so.  It is a promise
;;     about PROVENANCE: these numbers came from that document, for that
;;     year.
;;   * `:year' is the year the figures actually apply to.  A state that has
;;     only published 2025 figures is recorded as `:year 2025', never
;;     relabelled 2026 to look current.  `cmacs-calculator-tax-vintage'
;;     reports the gap.
;;   * Nothing is inferred.  A bracket that could not be read from a source
;;     is not guessed from the previous year, from a neighbouring state, or
;;     from a secondary aggregator's summary.
;;
;; Primary sources are the IRS for federal and each state's Department of
;; Revenue/Taxation for states.  Where a secondary source (the Tax
;; Foundation's annual state-income-tax survey) was used, the table says so
;; in `:note' and is NOT marked `:verified t'.
;;
;; The federal tables
;; ------------------
;; Both federal years come from the IRS's annual inflation-adjustment
;; revenue procedures, which print the rate schedules directly.  One
;; wrinkle worth recording, since it is exactly the kind of thing that
;; silently corrupts a table: the 2025 STANDARD DEDUCTION in this file does
;; NOT come from Rev. Proc. 2024-40, the 2025 procedure.  The One Big
;; Beautiful Bill Act raised it after that document was published, and Rev.
;; Proc. 2025-32 section 3.01 removes the superseded figures and restates
;; 2025's deduction as $15,750/$31,500/$23,625.  The brackets in the older
;; procedure remain good; only the deduction moved.
;;
;; State coverage
;; --------------
;; The nine no-income-tax states are `:structure none' and yield a zero tax
;; cleanly.  Their nuances are recorded in `:note' rather than modeled:
;; New Hampshire's repealed interest-and-dividends tax and Washington's
;; capital-gains excise tax are real taxes that this subsystem does not
;; compute, and saying so is more useful than a silent zero.
;;
;; Local and municipal income taxes are FLAGGED (`:local-tax') but never
;; computed: they vary by city, county and school district, and a state
;; table cannot know which one applies.  Maryland, Ohio, Pennsylvania,
;; Indiana, New York and Michigan are the big ones -- in those states the
;; returned figure can understate the real burden substantially.
;;
;; Likewise `:federal-deduction-allowed' flags the handful of states that
;; let filers deduct federal income tax paid.  `cmacs-calculator-tax-state'
;; does not apply it, because doing so needs the federal liability and a
;; state-specific cap; the flag tells a caller the estimate is high.

;;; Code:

(require 'cmacs-calculator-tax)


;;; United States -- federal
;;
;; Brackets, standard deductions and capital-gain thresholds are read
;; verbatim from the IRS revenue procedure for each year.  The bracket
;; ladders are checked in the test suite against the cumulative "The Tax
;; Is" column the same documents print, which is an independent arithmetic
;; check on both the data and the walk.
;;
;; The payroll figures come from SSA rather than the IRS: the Social
;; Security wage cap is announced with the annual COLA.  The Additional
;; Medicare thresholds ($200k/$250k/$125k) are statutory -- Internal
;; Revenue Code section 3101(b)(2), added by the ACA -- and deliberately
;; NOT indexed for inflation, which is why they are identical in both
;; years while every other figure here moved.

(cmacs-calculator-tax-register
 '(:jurisdiction us-federal
   :name "United States (federal)"
   :year 2026
   :structure bracketed
   :source "IRS Rev. Proc. 2025-32, sections 4.01/4.03/4.14 (I.R.B. 2025-45), https://www.irs.gov/pub/irs-drop/rp-25-32.pdf; SSA 2026 COLA fact sheet (wage cap $184,500), https://www.ssa.gov/oact/cola/cbb.html; IRS Topic no. 560 (Additional Medicare); IRS Self-Employment Tax page"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)

   ;; Rev. Proc. 2025-32 section 4.01, Tables 1-4.
   :brackets-single ((0 . 0.10) (12400 . 0.12) (50400 . 0.22) (105700 . 0.24)
                     (201775 . 0.32) (256225 . 0.35) (640600 . 0.37))
   :brackets-married-joint ((0 . 0.10) (24800 . 0.12) (100800 . 0.22)
                            (211400 . 0.24) (403550 . 0.32) (512450 . 0.35)
                            (768700 . 0.37))
   :brackets-married-separate ((0 . 0.10) (12400 . 0.12) (50400 . 0.22)
                               (105700 . 0.24) (201775 . 0.32) (256225 . 0.35)
                               (384350 . 0.37))
   :brackets-head-of-household ((0 . 0.10) (17700 . 0.12) (67450 . 0.22)
                                (105700 . 0.24) (201750 . 0.32) (256200 . 0.35)
                                (640600 . 0.37))

   ;; Rev. Proc. 2025-32 section 4.14.
   :standard-deduction-single 16100
   :standard-deduction-married-joint 32200
   :standard-deduction-married-separate 16100
   :standard-deduction-head-of-household 24150

   ;; Personal exemptions are zero: repealed by the TCJA and made
   ;; permanent by the OBBBA (Rev. Proc. 2025-32 section 4.13).
   :personal-exemption 0

   ;; Rev. Proc. 2025-32 section 4.03: the maximum zero-rate and maximum
   ;; 15% amounts, expressed as a ladder.  "All Other Individuals" in the
   ;; document is the single filer.
   :capital-gains-brackets-single ((0 . 0.0) (49450 . 0.15) (545500 . 0.20))
   :capital-gains-brackets-married-joint ((0 . 0.0) (98900 . 0.15)
                                          (613700 . 0.20))
   :capital-gains-brackets-married-separate ((0 . 0.0) (49450 . 0.15)
                                             (306850 . 0.20))
   :capital-gains-brackets-head-of-household ((0 . 0.0) (66200 . 0.15)
                                              (579600 . 0.20))

   ;; SSA: 2026 contribution and benefit base $184,500 (2025: $176,100).
   :fica-rate 0.062
   :fica-wage-cap 184500
   :medicare-rate 0.0145
   :medicare-addl-rate 0.009
   :medicare-addl-threshold-single 200000
   :medicare-addl-threshold-married-joint 250000
   :medicare-addl-threshold-married-separate 125000
   :medicare-addl-threshold-head-of-household 200000

   :se-rate 0.124
   :se-medicare-rate 0.029
   :se-net-earnings-factor 0.9235

   :local-tax nil
   :federal-deduction-allowed nil
   :note "Estimates the modeled components only.  Credits (EITC, CTC),
itemized deductions, the AMT, QBI, phase-outs and the 3.8% net investment
income tax are not modeled.  The Additional Medicare thresholds are
statutory and not inflation-indexed."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-federal
   :name "United States (federal)"
   :year 2025
   :structure bracketed
   :source "IRS Rev. Proc. 2024-40, sections 2.01/2.03 (brackets, capital gains), https://www.irs.gov/pub/irs-drop/rp-24-40.pdf; IRS Rev. Proc. 2025-32 section 3.01 (2025 standard deduction as amended by the OBBBA), https://www.irs.gov/pub/irs-drop/rp-25-32.pdf; SSA (2025 wage cap $176,100)"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)

   ;; Rev. Proc. 2024-40 section 2.01, Tables 1-4.
   :brackets-single ((0 . 0.10) (11925 . 0.12) (48475 . 0.22) (103350 . 0.24)
                     (197300 . 0.32) (250525 . 0.35) (626350 . 0.37))
   :brackets-married-joint ((0 . 0.10) (23850 . 0.12) (96950 . 0.22)
                            (206700 . 0.24) (394600 . 0.32) (501050 . 0.35)
                            (751600 . 0.37))
   :brackets-married-separate ((0 . 0.10) (11925 . 0.12) (48475 . 0.22)
                               (103350 . 0.24) (197300 . 0.32) (250525 . 0.35)
                               (375800 . 0.37))
   :brackets-head-of-household ((0 . 0.10) (17000 . 0.12) (64850 . 0.22)
                                (103350 . 0.24) (197300 . 0.32) (250500 . 0.35)
                                (626350 . 0.37))

   ;; NOT from Rev. Proc. 2024-40: the OBBBA raised these after it was
   ;; published, and Rev. Proc. 2025-32 section 3.01 restates them.
   :standard-deduction-single 15750
   :standard-deduction-married-joint 31500
   :standard-deduction-married-separate 15750
   :standard-deduction-head-of-household 23625
   :personal-exemption 0

   ;; Rev. Proc. 2024-40 section 2.03.
   :capital-gains-brackets-single ((0 . 0.0) (48350 . 0.15) (533400 . 0.20))
   :capital-gains-brackets-married-joint ((0 . 0.0) (96700 . 0.15)
                                          (600050 . 0.20))
   :capital-gains-brackets-married-separate ((0 . 0.0) (48350 . 0.15)
                                             (300000 . 0.20))
   :capital-gains-brackets-head-of-household ((0 . 0.0) (64750 . 0.15)
                                              (566700 . 0.20))

   :fica-rate 0.062
   :fica-wage-cap 176100
   :medicare-rate 0.0145
   :medicare-addl-rate 0.009
   :medicare-addl-threshold-single 200000
   :medicare-addl-threshold-married-joint 250000
   :medicare-addl-threshold-married-separate 125000
   :medicare-addl-threshold-head-of-household 200000

   :se-rate 0.124
   :se-medicare-rate 0.029
   :se-net-earnings-factor 0.9235

   :local-tax nil
   :federal-deduction-allowed nil
   :note "Retained for comparison against 2026.  Same modeling limits as
the 2026 table.  The standard deduction here is the OBBBA-amended figure
from Rev. Proc. 2025-32, not the superseded one in Rev. Proc. 2024-40."))

;;; States without an income tax
;;
;; Nine states levy no individual income tax on wages in 2026.  They are
;; `:structure none' and return a zero tax, but the `:note' on each records
;; what a bare zero would hide -- these states are not uniformly "no tax on
;; anything", and two of them are actively changing.

(cmacs-calculator-tax-register
 '(:jurisdiction us-ak
   :name "Alaska"
   :year 2026
   :structure none
   :source "Alaska Department of Revenue, Tax Division, https://tax.alaska.gov/programs/programs/index.aspx?10001"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No individual income tax: \"The State of Alaska currently does
not have an individual income tax, therefore no employee withholding for
state income tax is required.\"  The Tax Division's index lists a
\"Personal Income Tax\" entry, but it links to a page stating the tax does
not exist."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-fl
   :name "Florida"
   :year 2026
   :structure none
   :source "Florida Department of Revenue, GT-800025 (rev. 2025-05-20), https://floridarevenue.com/Forms_library/current/brochure/gt800025.pdf"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No personal income tax; the DOR cites Art. VII sec. 5 of the
Florida Constitution as the bar.  No inheritance or gift tax either."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-nv
   :name "Nevada"
   :year 2026
   :structure none
   :source "Nevada Department of Taxation, https://tax.nv.gov/about-nevada-department-of-taxation/income-tax-in-nevada/"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No individual income tax: \"The State of Nevada does not impose
a state income tax on individuals.\""))

(cmacs-calculator-tax-register
 '(:jurisdiction us-nh
   :name "New Hampshire"
   :year 2026
   :structure none
   :source "New Hampshire General Court, RSA chapter 77 (repealed), https://gc.nh.gov/rsa/html/V/77/77-mrg.htm"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "New Hampshire never taxed wages.  Its interest-and-dividends tax
lived in RSA chapter 77, and the WHOLE CHAPTER is now repealed effective
January 1, 2025 (2021, 91:189, II), so from tax year 2025 onward there is
no individual income tax of any kind.  Tables before 2025 would need the
I&D tax modeled; this one does not."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-sd
   :name "South Dakota"
   :year 2026
   :structure none
   :source "South Dakota Department of Revenue, https://dor.sd.gov/individuals/taxes/"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No individual income tax, and no corporate income or
inheritance tax."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-tn
   :name "Tennessee"
   :year 2026
   :structure none
   :source "Tennessee Department of Revenue, HIT-3 and GEN-34, https://revenue.support.tn.gov/hc/en-us/articles/360057828631"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No tax on earned income, and the Hall income tax on interest and
dividends is \"fully repealed beginning January 1, 2021\" (HIT-3), having
phased down 4/3/2/1% over 2017-2020.  Tax years before 2021 would need the
Hall tax modeled."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-tx
   :name "Texas"
   :year 2026
   :structure none
   :source "Texas Constitution art. VIII secs. 24-a, 24-b, 25, https://tlc.texas.gov/docs/legref/TxConst.pdf; Texas Comptroller"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No individual income tax, and constitutionally prohibited rather
than merely unlegislated: art. VIII sec. 24-a, \"INDIVIDUAL INCOME TAX
PROHIBITED\" (added Nov. 5, 2019).  Capital gains taxes are likewise barred
by sec. 24-b (added Nov. 4, 2025), a wealth tax by sec. 25, and death
taxes by sec. 26."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-wa
   :name "Washington"
   :year 2026
   :structure none
   :source "Washington Department of Revenue, https://dor.wa.gov/taxes-rates/other-taxes/capital-gains-tax; ESSB 6346 (Ch. 238, Laws of 2026) bill report, https://lawfilesext.leg.wa.gov/biennium/2025-26/Pdf/Bill%20Reports/Senate/6346-S.E%20SBR%20FBR%2026.pdf"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "No income tax on WAGES in 2026, but Washington is the least
accurate of the nine to call a no-tax state, in two ways this subsystem
does NOT model:

 (1) A capital gains excise tax is in force now: 7% on Washington
     long-term capital gains above a standard deduction, plus an
     additional 2.9% (9.9% total) on the portion over $1,000,000, tiered
     since Jan 1 2025.  The deduction was $278,000 for tax year 2025; the
     2026 figure is inflation-adjusted but DOR had not published it as of
     the retrieval date, so it is deliberately absent here rather than
     estimated.  `cmacs-calculator-tax-capital-gains' computes FEDERAL tax
     only and does not add this.

 (2) A flat 9.90% individual income tax was enacted in 2026 (ESSB 6346)
     but does not begin until tax year 2028, with a $1,000,000 standard
     deduction.  It does not touch 2026 or 2027.  The bill report notes
     the whole act is void if a court of final jurisdiction invalidates
     the tax, so a future table must not assume it takes effect."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-wy
   :name "Wyoming"
   :year 2026
   :structure none
   :source "State of Wyoming official portal, https://www.wyo.gov/about-wyoming"
   :retrieved "2026-07-17"
   :verified t
   :local-tax nil
   :note "\"Wyoming does not possess an individual or corporate income
tax.\"  Sourcing caveat: this is the state portal rather than the
Department of Revenue, which administers no income tax and so publishes no
affirmative statement about one.  The absence is consistent across the
Department of Revenue and Department of Workforce Services."))

;;; States with an income tax
;;
;; A note on `:filing-statuses': it lists the statuses whose ladder this
;; table actually carries.  Several states publish only two schedules, and
;; asking `cmacs-calculator-tax-state' for a status a table does not cover
;; signals rather than guessing -- assuming a head of household uses the
;; single ladder is exactly the kind of plausible inference that produces a
;; wrong number with no warning.

(cmacs-calculator-tax-register
 '(:jurisdiction us-nj
   :name "New Jersey"
   :year 2025
   :structure bracketed
   :source "NJ Division of Taxation, 2025 Form NJ-1040 instructions p. 63, Tax Rate Schedules A and B, https://www.nj.gov/treasury/taxation/pdf/current/1040i.pdf"
   :retrieved "2026-07-17"
   :verified t
   ;; Schedule A covers single and married-filing-separately; Schedule B
   ;; covers married-joint.  Head of household is NOT listed here: the
   ;; researched source did not confirm which schedule it uses, so asking
   ;; for it signals instead of guessing.
   :filing-statuses (single married-separate married-joint)
   :brackets-single ((0 . 0.014) (20000 . 0.0175) (35000 . 0.035)
                     (40000 . 0.05525) (75000 . 0.0637) (500000 . 0.0897)
                     (1000000 . 0.1075))
   :brackets-married-separate ((0 . 0.014) (20000 . 0.0175) (35000 . 0.035)
                               (40000 . 0.05525) (75000 . 0.0637)
                               (500000 . 0.0897) (1000000 . 0.1075))
   :brackets-married-joint ((0 . 0.014) (20000 . 0.0175) (50000 . 0.0245)
                            (70000 . 0.035) (80000 . 0.05525) (150000 . 0.0637)
                            (500000 . 0.0897) (1000000 . 0.1075))
   ;; New Jersey has no standard deduction at all: the phrase does not
   ;; occur anywhere in the NJ-1040 instructions.
   :standard-deduction 0
   :personal-exemption-single 1000
   :personal-exemption-married-separate 1000
   :personal-exemption-married-joint 2000
   :federal-deduction-allowed nil
   :local-tax nil
   :note "New Jersey publishes rate-minus-constant schedules rather than a
marginal ladder; the ladder here is the equivalent marginal form, checked
for continuity at every breakpoint.  New Jersey's own constants are
internally inconsistent by $0.50 at the MFJ $70,000/$80,000 breakpoints.
Not modeled: the filing threshold that exempts gross income at or below
$10,000 (single) / $20,000 (joint) entirely, and the additional
exemptions for age 65+, blindness, veterans ($6,000) and dependents
($1,500 each) -- only the taxpayer/spouse exemption is applied."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-nm
   :name "New Mexico"
   :year 2025
   :structure bracketed
   :source "NM HB 252 (Laws 2024 ch. 67), enacting NMSA 1978 sec. 7-2-7 eff. 2025-01-01, https://www.nmlegis.gov/Sessions/24%20Regular/bills/house/HB0252.HTML; NM 2025 PIT-1 instructions, https://realfile.tax.newmexico.gov/2025pit-1-ins.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :brackets-single ((0 . 0.015) (5500 . 0.032) (16500 . 0.043) (33500 . 0.047)
                     (66500 . 0.049) (210000 . 0.059))
   :brackets-married-joint ((0 . 0.015) (8000 . 0.032) (25000 . 0.043)
                            (50000 . 0.047) (100000 . 0.049) (315000 . 0.059))
   ;; The PIT-1 instructions put heads of household and surviving spouses
   ;; on the married-joint schedule.
   :brackets-head-of-household ((0 . 0.015) (8000 . 0.032) (25000 . 0.043)
                                (50000 . 0.047) (100000 . 0.049)
                                (315000 . 0.059))
   :brackets-married-separate ((0 . 0.015) (4000 . 0.032) (12500 . 0.043)
                               (25000 . 0.047) (50000 . 0.049)
                               (157500 . 0.059))
   ;; New Mexico has no standard deduction of its own: PIT-1 line 12 says
   ;; to enter the federal standard deduction.  These are therefore the
   ;; IRS 2025 figures (Rev. Proc. 2025-32 sec. 3.01, as amended by the
   ;; OBBBA) carried across, not a New Mexico invention.
   :standard-deduction-single 15750
   :standard-deduction-married-joint 31500
   :standard-deduction-married-separate 15750
   :standard-deduction-head-of-household 23625
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "The 2025 restructuring (HB 252) went from five brackets to six.
The ladders come from the enacted statute: the PIT-1 instructions do not
print rate tables, and the separate look-up table they reference was not
retrievable from tax.newmexico.gov.  The statutory ladders reconcile to
the penny.  Personal exemptions are suspended (federal conformity).  The
$4,000-per-qualified-dependent deduction is not modeled.  Whether New
Mexico indexes these thresholds for inflation was not confirmed, so a
2026 table must not be assumed identical."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ny
   :name "New York"
   :year 2025
   :structure bracketed
   :source "NY Department of Taxation and Finance, 2025 Form IT-201-I, tax rate schedules pp. 33-34, https://www.tax.ny.gov/pdf/current_forms/it/it201i.pdf"
   :retrieved "2026-07-17"
   :verified t
   ;; Married-filing-separately is absent: its ladder was not confirmed.
   :filing-statuses (single married-joint head-of-household)
   :brackets-single ((0 . 0.04) (8500 . 0.045) (11700 . 0.0525) (13900 . 0.055)
                     (80650 . 0.06) (215400 . 0.0685) (1077550 . 0.0965)
                     (5000000 . 0.103) (25000000 . 0.109))
   :brackets-married-joint ((0 . 0.04) (17150 . 0.045) (23600 . 0.0525)
                            (27900 . 0.055) (161550 . 0.06) (323200 . 0.0685)
                            (2155350 . 0.0965) (5000000 . 0.103)
                            (25000000 . 0.109))
   :brackets-head-of-household ((0 . 0.04) (12800 . 0.045) (17650 . 0.0525)
                                (20900 . 0.055) (107650 . 0.06)
                                (269300 . 0.0685) (1616450 . 0.0965)
                                (5000000 . 0.103) (25000000 . 0.109))
   :standard-deduction-single 8000
   :standard-deduction-married-joint 16050
   :standard-deduction-head-of-household 11200
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax t
   :note "UNDERSTATES TAX ABOVE $107,650 OF NY AGI.  New York applies a
supplemental tax that recaptures the benefit of the lower brackets, via
worksheets in the IT-201-I; the ladder alone therefore under-taxes such
filers and this subsystem does not model the recapture.  The ladders
themselves are verified.  Also not modeled: the New York City and Yonkers
local income taxes (`:local-tax'), which are substantial for city
residents.  No taxpayer/spouse exemption exists; the $1,000 dependent
exemption is not modeled."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-nd
   :name "North Dakota"
   :year 2025
   :structure bracketed
   :source "ND Office of State Tax Commissioner, 2025 Individual Income Tax Booklet pp. 27-28, https://www.tax.nd.gov/sites/www/files/documents/forms/individual/2025-iit/2025-individual-income-tax-booklet.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; The 0% first bracket is real: HB 1158 zeroed the bottom bracket and
   ;; merged the top four into two.
   :brackets-single ((0 . 0.0) (48475 . 0.0195) (244825 . 0.025))
   :brackets-married-joint ((0 . 0.0) (80975 . 0.0195) (298075 . 0.025))
   :brackets-married-separate ((0 . 0.0) (40475 . 0.0195) (149025 . 0.025))
   :brackets-head-of-household ((0 . 0.0) (64950 . 0.0195) (271450 . 0.025))
   ;; North Dakota starts from FEDERAL TAXABLE INCOME, so the federal
   ;; standard deduction is already baked into its base.  Applying the
   ;; federal figures here lets a caller pass gross income and get the
   ;; right answer for a non-itemizer.  These are the IRS 2025 amounts.
   :standard-deduction-single 15750
   :standard-deduction-married-joint 31500
   :standard-deduction-married-separate 15750
   :standard-deduction-head-of-household 23625
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Ladders verified arithmetically against the booklet's published
base amounts: 1.95% x (244,825 - 48,475) = $3,828.83 single and 1.95% x
(298,075 - 80,975) = $4,233.45 joint both match to the cent.  That check
resolved a conflicting secondary claim that the joint top threshold was
$297,975.  Because North Dakota begins from federal taxable income, the
standard deduction above is the FEDERAL one; an itemizing filer should
pass their own reduced income instead."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-oh
   :name "Ohio"
   :year 2025
   :structure bracketed
   :source "Ohio Department of Taxation, 2025 IT-1040 booklet p. 18, https://dam.assets.ohio.gov/image/upload/tax.ohio.gov/forms/ohio_individual/individual/2025/it1040-booklet.pdf; Ohio Revised Code sec. 5747.02, https://codes.ohio.gov/ohio-revised-code/section-5747.02"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Ohio's brackets do not vary by filing status.
   :brackets ((0 . 0.0) (26050 . 0.0275) (100000 . 0.03125))
   :standard-deduction 0
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax t
   :note "VERIFIED FIGURES, BUT THIS TABLE CANNOT REPRESENT THEM, so it is
marked unverified rather than trusted.  Ohio's published schedule is not
a pure marginal ladder and a bracket walk cannot reproduce it:

 (1) The 2.75% bracket carries a $342.00 LUMP-SUM BASE -- the schedule is
     \"$342.00 plus 2.75% of the excess over $26,050\" -- so there is a
     cliff at $26,050 ($0 just below, ~$342 just above).  The walk here
     omits the base and so understates Ohio tax by about $342.
 (2) The schedule is DISCONTINUOUS at $100,000: the published base there
     is $2,394.32, but continuing the 2.75% bracket gives $2,375.63, an
     $18.69 jump.  Both artifacts appear identically in the booklet and
     in the statute, so they are real law, not transcription errors.

Representing Ohio faithfully needs a lump-sum-base concept this schema
does not have.  Until then, treat the figure as a known-low estimate.

Ohio also levies municipal and school-district income taxes
(`:local-tax'), neither modeled.  The personal exemption is MAGI-tiered
($2,400 / $2,150 / $1,900 / $0 as income rises) and is likewise not
modeled; it is set to 0 here.

For 2026, ORC 5747.02(A)(3)(c) as amended by H.B. 96 reads \"$332.00 plus
2.75% of the amount in excess of $26,050\" -- the base drops to $332 and
the 3.125% bracket disappears.  Secondary sources calling 2026 simply
\"flat 2.75% over $26,050\" omit the $332 base and are wrong.  The 2026
threshold is also subject to the Tax Commissioner's August GDP-deflator
adjustment, unpublished as of the retrieval date, so no 2026 table is
registered."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ok
   :name "Oklahoma"
   :year 2026
   :structure bracketed
   :source "Oklahoma Tax Commission, 2025 Legislative Update (HB 2764, 68 O.S. sec. 2355), https://oklahoma.gov/content/dam/ok/en/tax/documents/resources/publications/legislation/2025LegislativeUpdate.pdf; 2025 Form 511 packet (deduction/exemption), https://oklahoma.gov/content/dam/ok/en/tax/documents/forms/individuals/current/511-Pkt.pdf"
   :retrieved "2026-07-17"
   :verified nil
   ;; Married-separate and head-of-household ladders were not confirmed.
   :filing-statuses (single married-joint)
   ;; HB 2764 cut rates effective tax year 2026, adding a 0% bottom
   ;; bracket and lowering the top rate to 4.5%.
   :brackets-single ((0 . 0.0) (3750 . 0.025) (4900 . 0.035) (7200 . 0.045))
   :brackets-married-joint ((0 . 0.0) (7500 . 0.025) (9800 . 0.035)
                            (14400 . 0.045))
   :standard-deduction-single 6350
   :standard-deduction-married-joint 12700
   :personal-exemption 1000
   :federal-deduction-allowed nil
   :local-tax nil
   :note "MIXED VINTAGE, hence unverified.  The 2026 BRACKETS are verified
from HB 2764 and reconcile exactly against the Tax Commission's published
base amounts ($28.75 at $4,900 and $109.25 at $7,200 single; $57.50 and
$218.50 joint).  But the STANDARD DEDUCTION and PERSONAL EXEMPTION above
are the 2025 figures: Oklahoma had not published 2026 amounts as of the
retrieval date, and they are carried forward rather than left out so the
brackets remain usable.  They may be wrong for 2026.

Rates are also contingent: 62 O.S. sec. 34.103 lets them fall a further
0.25% across all brackets when revenue conditions are met, certified each
February, so 4.5%/3.5%/2.5% must not be treated as permanent.

No 2025 Oklahoma table is registered: the 2025 Form 511 packet publishes
only a look-up table and no explicit bracket ladder, and no primary
ladder was located.  A 2025 ladder could be derived from the look-up
anchors (tax on $100,000 is $4,562 single, $4,373 joint; top rate 4.75%)
but deriving one is exactly the guessing this file forbids."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ks
   :name "Kansas"
   :year 2026
   :structure bracketed
   :source "Kansas Department of Revenue, 2026 Form K-40ES, https://www.ksrevenue.gov/pdf/k-40es26.pdf; 2025 Income Tax Booklet (exemptions), https://www.ksrevenue.gov/pdf/ip25.pdf"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint)
   :brackets-single ((0 . 0.052) (23000 . 0.0558))
   :brackets-married-joint ((0 . 0.052) (46000 . 0.0558))
   :standard-deduction-single 3605
   :standard-deduction-married-joint 8240
   :personal-exemption-single 9160
   :personal-exemption-married-joint 18320
   :federal-deduction-allowed nil
   :local-tax nil
   :note "MIXED VINTAGE, hence unverified.  The two-bracket ladder and the
standard deduction are verified for 2026 from the K-40ES, but the
PERSONAL EXEMPTION above is the 2025 figure: the 2026 K-40ES defers to a
2026 K-40 booklet unpublished at the retrieval date.  Kansas amounts are
statutory (K.S.A. 79-32,119) and not inflation-indexed, and the standard
deduction is identical in the 2025 and 2026 forms, so the exemption very
likely carries too -- but 'very likely' is not verified.

Secondary sources reporting 3.10%/5.70% are stale: 2024 legislation
consolidated three brackets into two and cut the rates to 5.2%/5.58%.
Only single and married-joint ladders are carried; head-of-household and
married-separate were not confirmed.  Some counties levy a local
intangibles tax on interest and dividends, not on wages."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-me
   :name "Maine"
   :year 2026
   :structure bracketed
   :source "Maine Revenue Services, 2026 Individual Income Tax Rate Schedules (rev. 2026-05-05), https://www.maine.gov/revenue/sites/maine.gov.revenue/files/inline-files/ind_tax_rate_sched_2026.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint)
   ;; LD 2212 added a 2% millionaire surcharge retroactive to 2026-01-01,
   ;; taking the top rate from 7.15% to 9.15%.
   :brackets-single ((0 . 0.058) (27400 . 0.0675) (64850 . 0.0715)
                     (1000000 . 0.0915))
   :brackets-married-joint ((0 . 0.058) (54850 . 0.0675) (129750 . 0.0715)
                            (1500000 . 0.0915))
   :standard-deduction-single 15700
   :standard-deduction-married-joint 31400
   :personal-exemption-single 5300
   :personal-exemption-married-joint 10600
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Beware stale secondary data here: most aggregators -- INCLUDING
the Tax Foundation's 2026 table -- still show three brackets topping out
at 7.15% and a standard deduction of $8,350/$16,700.  Both are wrong for
2026.  The 9.15% top bracket (LD 2212) is enacted and retroactive to
January 1, 2026; its thresholds begin inflation-adjusting in 2027.  An
earlier revision of this same DOR PDF showed $15,300/$30,600; the figures
here are from the May 5, 2026 revision.

NOT modeled and NOT confirmed: Maine phases out the standard deduction
and personal exemption at higher incomes (36 M.R.S. secs. 5124-C,
5126-A).  Whether and how they apply was not verified, so this table may
over-deduct -- and therefore UNDER-TAX -- high earners."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-md
   :name "Maryland"
   :year 2026
   :structure bracketed
   :source "Comptroller of Maryland, Withholding Tax Facts 2026, https://www.marylandcomptroller.gov/content/dam/mdcomp/tax/legal-publications/facts/withholding-tax-facts-2026.pdf; 2026 PV worksheet, https://www.marylandcomptroller.gov/content/dam/mdcomp/tax/forms/worksheets/2026-pv-worksheet.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint)
   :brackets-single ((0 . 0.02) (1000 . 0.03) (2000 . 0.04) (3000 . 0.0475)
                     (100000 . 0.05) (125000 . 0.0525) (150000 . 0.055)
                     (250000 . 0.0575) (500000 . 0.0625) (1000000 . 0.065))
   :brackets-married-joint ((0 . 0.02) (1000 . 0.03) (2000 . 0.04)
                            (3000 . 0.0475) (150000 . 0.05) (175000 . 0.0525)
                            (225000 . 0.055) (300000 . 0.0575)
                            (600000 . 0.0625) (1200000 . 0.065))
   :standard-deduction-single 3350
   :standard-deduction-married-joint 6700
   :personal-exemption-single 3200
   :personal-exemption-married-joint 6400
   :federal-deduction-allowed nil
   :local-tax t
   :note "SUBSTANTIALLY UNDERSTATES THE REAL BURDEN: Maryland's county
income tax is MANDATORY, ranges from 2.25% to 3.30%, and is levied on
taxable income rather than on state tax -- so a Baltimore City resident
at 3.20% pays roughly half again the state figure computed here.  Anne
Arundel and Frederick use graduated local brackets.  None of it is
modeled (`:local-tax').

Also not modeled: the 2% additional tax on net capital gains when federal
AGI exceeds $350,000, and the personal-exemption phase-out (the $3,200
above drops to $1,600, then $800, then $0 as AGI rises past $100,000
single / $150,000 joint), so this over-deducts for higher earners.

The widely-circulated \"$4,100/$8,200 standard deduction for 2026\" comes
from HB 411, a proposed bill at First Reader -- NOT law.  Tax-General
sec. 10-217 and the Comptroller's own 2026 worksheet both give
$3,350/$6,700."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ma
   :name "Massachusetts"
   :year 2026
   :structure bracketed
   :source "Massachusetts DOR, Massachusetts tax rates and 4% surtax pages, https://www.mass.gov/info-details/massachusetts-tax-rates, https://www.mass.gov/info-details/massachusetts-4-surtax-on-taxable-income"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Massachusetts is a flat 5% plus the voter-approved 4% surtax above a
   ;; threshold, which is exactly a two-band ladder.  The threshold is NOT
   ;; doubled for joint filers -- it is the same for every status, so a
   ;; single shared ladder is correct here.
   :brackets ((0 . 0.05) (1107750 . 0.09))
   ;; Massachusetts has no standard deduction.
   :standard-deduction 0
   :personal-exemption-single 4400
   :personal-exemption-married-joint 8800
   :personal-exemption-married-separate 4400
   :personal-exemption-head-of-household 6800
   :federal-deduction-allowed nil
   :local-tax nil
   :note "The surtax threshold is inflation-adjusted yearly: $1,107,750
for 2026, $1,083,150 for 2025, $1,053,750 for 2024, $1,000,000 for 2023.
The Tax Foundation's 2026 table lists $1,083,150 -- that is the 2025
threshold mislabeled as 2026.

Sourcing caveat: mass.gov returns HTTP 403 to direct fetching, so these
figures were read from the same official mass.gov URLs through a reader
proxy.  The content is the Department of Revenue's, but it was not
fetched directly.

Not modeled: Massachusetts taxes short-term capital gains at 8.5% and
collectibles at 12% rather than 5%, with the 4% surtax applying on top of
all of them."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-mn
   :name "Minnesota"
   :year 2026
   :structure bracketed
   :source "Minnesota Department of Revenue, \"Minnesota income tax brackets, standard deduction and dependent exemption\" (2025-12-16), https://www.revenue.state.mn.us/press-release/2025-12-16/minnesota-income-tax-brackets-standard-deduction-and-dependent-exemption"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint)
   :brackets-single ((0 . 0.0535) (33310 . 0.068) (109430 . 0.0785)
                     (203150 . 0.0985))
   :brackets-married-joint ((0 . 0.0535) (48700 . 0.068) (193480 . 0.0785)
                            (337930 . 0.0985))
   :standard-deduction-single 15300
   :standard-deduction-married-joint 30600
   ;; Minnesota has no personal exemption; only a dependent exemption,
   ;; which is not modeled.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Brackets and the standard deduction are statutorily
inflation-adjusted every year (chained CPI-U, rounded to the nearest
$10); 2026 thresholds rose 2.369% over 2025 and the rates are unchanged
since 2023.  The $5,300 dependent exemption is not modeled."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-mo
   :name "Missouri"
   :year 2026
   :structure bracketed
   :source "Missouri Department of Revenue, 2026 Form MO-1040ES, https://dor.mo.gov/forms/MO-1040ES_2026.pdf; 2025 MO-1040 instructions (federal deduction mechanics), https://dor.mo.gov/forms/MO-1040%20Instructions_2025.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Missouri computes tax separately for each spouse on a combined
   ;; return, so the ladder is NOT doubled for joint filers -- it is
   ;; shared across statuses.
   :brackets ((0 . 0.0) (1348 . 0.02) (2696 . 0.025) (4044 . 0.03)
              (5392 . 0.035) (6740 . 0.04) (8088 . 0.045) (9436 . 0.047))
   ;; Missouri's standard deduction tracks the federal amounts.
   :standard-deduction-single 16100
   :standard-deduction-married-joint 32200
   :standard-deduction-married-separate 16100
   :standard-deduction-head-of-household 24150
   :personal-exemption 0
   :federal-deduction-allowed t
   :local-tax t
   :note "OVERSTATES TAX for filers who qualify for Missouri's federal
income tax deduction, which this subsystem does not apply
(`:federal-deduction-allowed').  It is a percentage of federal tax paid,
tiered by Missouri AGI -- 35% at or below $25,000, then 25%, 15%, 5%, and
0% at or above $125,001 -- and then capped at $5,000 ($10,000 married
filing combined).  Verified in the 2025 MO-1040 instructions; its
continuation into 2026 is NOT confirmed, because the 2026 MO-1040 is
unpublished.  The 2026 MO-1040ES omits it, but so does the 2025 MO-1040ES
while the 2025 return has it, so the omission is form simplification
rather than evidence of repeal.

The top rate fell 4.8% to 4.7% effective January 1, 2025, and the ladder
is inflation-indexed.  Not modeled: the $1,400 additional exemption for
heads of household and qualifying widow(er)s; Missouri's 100% capital
gains deduction (effective January 1, 2025), which makes this table
substantially overstate tax on gains; and the 1% earnings taxes levied by
Kansas City and St. Louis (`:local-tax')."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-mt
   :name "Montana"
   :year 2026
   :structure bracketed
   :source "Montana Department of Revenue, HB 337 rate page, https://revenue.mt.gov/news/recent-news/HB-337; Tax Simplification Resource Hub, https://revenue.mt.gov/montana-tax-simplification-resource-hub"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint head-of-household)
   :brackets-single ((0 . 0.047) (47500 . 0.0565))
   :brackets-married-joint ((0 . 0.047) (95000 . 0.0565))
   :brackets-head-of-household ((0 . 0.047) (71250 . 0.0565))
   ;; Montana has no standard deduction and no exemptions of its own: its
   ;; taxable income starts from FEDERAL taxable income (excluding the
   ;; federal QBI deduction), so the federal standard deduction is already
   ;; embedded.  These are the IRS 2026 figures, applied so that a caller
   ;; can pass gross income and get the right answer for a non-itemizer.
   :standard-deduction-single 16100
   :standard-deduction-married-joint 32200
   :standard-deduction-head-of-household 24150
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Two stale claims to watch for: secondary sources still showing a
5.9% top rate are describing 2025 -- HB 337 cut it to 5.65% for 2026 and
widened the lower bracket from $21,100 to $47,500 (single).  And sources
saying Montana allows a federal income tax deduction are out of date: SB
399 REPEALED it effective 2024, confirmed on the Department's own
repealed-deductions list.  It did not survive the restructuring.

Montana's official 2026 rate table was not yet posted at the retrieval
date; these figures come from the Department's HB 337 page.  A further
cut to 5.4% over $65,000 single / $130,000 joint is scheduled for 2027.
Not modeled: long-term capital gains are taxed separately at 3.0%/4.1%,
and there is a $5,500 subtraction for filers 65 and over."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ne
   :name "Nebraska"
   :year 2026
   :structure bracketed
   :source "Nebraska Department of Revenue, 2026 Form 1040N-ES booklet, \"2026 Nebraska Estimated Income Tax Rate Schedule\", https://revenue.nebraska.gov/sites/default/files/doc/tax-forms/2025/f_1040N-ES.pdf; Neb. Rev. Stat. sec. 77-2715.03"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint)
   ;; The published schedule nominally splits a fourth bracket at
   ;; 39,900/79,800, but both it and the third carry the same 4.55% rate,
   ;; so the ladder collapses to three bands.
   :brackets-single ((0 . 0.0246) (4130 . 0.0351) (24760 . 0.0455))
   :brackets-married-joint ((0 . 0.0246) (8250 . 0.0351) (49530 . 0.0455))
   :standard-deduction-single 8850
   :standard-deduction-married-joint 17700
   ;; Nebraska's personal exemption is a $176 CREDIT, not a deduction, and
   ;; this subsystem does not model credits -- so it is deliberately not
   ;; expressed as an exemption, which would wrongly reduce taxable income.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "PROVISIONAL FIGURES, hence unverified.  Nebraska had not
published a final 2026 Tax Calculation Schedule at the retrieval date;
these come from the official 2026 estimated-tax booklet, which itself
says \"Do not use it to compute an amount for any tax returns.\"
Thresholds are inflation-adjusted and may be restated in the final
schedule.

The 2025 figures ARE fully verified, if an authoritative number is needed
now: single (0, 2.46%), (4,030, 3.51%), (24,120, 5.01%), (38,870, 5.20%);
joint (0, 2.46%), (8,040, 3.51%), (48,250, 5.01%), (77,730, 5.20%);
standard deduction $8,600/$17,200.  They are not registered as a 2025
table only because no 2025 caller has been needed.

The top rate drops 5.20% to 4.55% for 2026; 3.99% is scheduled for 2027,
not 2026 -- sources conflate the two.  The $176-per-exemption credit is
not modeled, so this overstates tax slightly.  Do NOT substitute
Nebraska's Circular EN withholding tables for these brackets: they use
entirely different rates."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-or
   :name "Oregon"
   :year 2026
   :structure bracketed
   :source "Oregon DOR, 2026 Withholding Tax Formulas 150-206-436 (rev. 12-31-25), https://www.oregon.gov/dor/forms/FormsPubs/withholding-tax-formulas_206-436_2026.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint)
   :brackets-single ((0 . 0.0475) (4550 . 0.0675) (11400 . 0.0875)
                     (125000 . 0.099))
   :brackets-married-joint ((0 . 0.0475) (9100 . 0.0675) (22800 . 0.0875)
                            (250000 . 0.099))
   :standard-deduction-single 2910
   :standard-deduction-married-joint 5820
   ;; Oregon's personal exemption is a $263 CREDIT, not a deduction, and
   ;; credits are not modeled -- expressing it as an exemption would
   ;; wrongly reduce taxable income.
   :personal-exemption 0
   :federal-deduction-allowed t
   :local-tax t
   :note "OVERSTATES TAX for most filers, in two ways this subsystem does
not model.  (1) Oregon allows a subtraction for federal income tax paid,
capped at $8,750 for 2026 and phased out by income (single: full below
$125,000, then $7,000 / $5,250 / $3,500 / $1,750 in $5,000 steps, gone at
$145,000; joint: full below $250,000, gone at $290,000).  (2) The $263
per-exemption credit, which is itself $0 above $100,000 AGI ($200,000
joint).

Sourcing: Oregon had not published a filer-facing 2026 rate chart at the
retrieval date (the 2026 OR-40 arrives around December 2026), so these
come from the 2026 withholding formula.  That substitution was validated
rather than assumed: the 2025 withholding formula's brackets, standard
deduction and exemption credit match the 2025 statutory values in
Publication OR-17 exactly, so the 2026 formula carries the 2026 statutory
figures.  Note the 2026 PDF contains stale carry-over PROSE (it says
\"$8,500 per year in 2025\" and uses a $256 credit in an example); the
formula TABLES hold the real 2026 values used here.

Not verified: the 2026 married-separate federal-subtraction cap.  Local
transit taxes (statewide, TriMet, Lane) and the Multnomah County/Metro
income taxes are flagged but not modeled."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ri
   :name "Rhode Island"
   :year 2026
   :structure bracketed
   :source "RI Division of Taxation, ADV 2025-22 Inflation Adjustments (2025-11-03), https://tax.ri.gov/sites/g/files/xkgbur541/files/2025-11/ADV_2025_22_Inflation_Adjustments.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Rhode Island uses one uniform rate schedule for every filing status.
   :brackets ((0 . 0.0375) (82050 . 0.0475) (186450 . 0.0599))
   :standard-deduction-single 11200
   :standard-deduction-married-joint 22400
   :standard-deduction-married-separate 11200
   :standard-deduction-head-of-household 16800
   :personal-exemption 5250
   :federal-deduction-allowed nil
   :local-tax nil
   :note "The cleanest source of the fifty: Rhode Island publishes 2026
figures explicitly and says outright that they \"will not appear on tax
returns in 2026 covering Tax Year 2025\", removing the usual ambiguity
about which year a form describes.

Not modeled: the standard deduction and exemptions phase out over AGI
$261,000-$290,800 in $7,450 increments and vanish above the range, so
this over-deducts -- and under-taxes -- filers in and above that band."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-sc
   :name "South Carolina"
   :year 2026
   :structure bracketed
   :source "SC Act 110 of 2026 (H.4216), https://www.scstatehouse.gov/sess126_2025-2026/bills/4216.htm; SCDOR, Information about H.4216, https://dor.sc.gov/news/information-about-h-4216"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; One schedule for every status.  The statute states this as a
   ;; flat-style formula -- "5.21% of the amount minus $966" above
   ;; $30,000 -- but it is algebraically continuous at $30,000
   ;; (1.99% x 30,000 = $597 = 5.21% x 30,000 - 966), so this two-band
   ;; marginal ladder is exactly equivalent.
   :brackets ((0 . 0.0199) (30000 . 0.0521))
   :standard-deduction-single 15000
   :standard-deduction-married-joint 30000
   :standard-deduction-married-separate 15000
   :standard-deduction-head-of-household 22500
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "SOUTH CAROLINA'S 0% BRACKET IS GONE FOR 2026.  H.4216 was signed
March 30, 2026 and applies from tax year 2026; every description of a
zero-rate first bracket describes 2025 and earlier.

Thresholds ARE indexed under sec. 12-6-520, but SCDOR had published no
inflation-adjusted 2026 bracket table at the retrieval date (guidance
\"later this year\"), so the $30,000 above is the statutory base and the
final 2026 threshold may be higher.

Not modeled: the SCIAD standard deduction phases down with AGI -- reduced
by (AGI - 40,000)/55,000 of the base for single filers, gone at $95,000;
head of household (AGI - 60,000)/82,500, gone at $142,500; joint
(AGI - 80,000)/110,000, gone at $190,000 -- so this over-deducts, and
under-taxes, above those floors.  The dependent exemption (2026 amount
unpublished) is not modeled either."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-vt
   :name "Vermont"
   :year 2025
   :structure bracketed
   :source "Vermont Department of Taxes, 2025 Vermont Rate Schedules, https://tax.vermont.gov/sites/tax/files/documents/TaxRateSched-2025.pdf; 2025 Income Booklet, https://tax.vermont.gov/sites/tax/files/documents/Income-Booklet-2025.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint)
   :brackets-single ((0 . 0.0335) (49400 . 0.066) (119700 . 0.076)
                     (249700 . 0.0875))
   :brackets-married-joint ((0 . 0.0335) (82500 . 0.066) (199450 . 0.076)
                            (304000 . 0.0875))
   :standard-deduction-single 7650
   :standard-deduction-married-joint 15300
   :personal-exemption 5300
   :federal-deduction-allowed nil
   :local-tax nil
   :note "2025, NOT 2026 -- deliberately.  Vermont's TY2026 filer rate
schedules could not be verified and the gap is real rather than a search
failure: the Department's \"2026 VT Rate Schedules\" link serves a file
containing 2026 WITHHOLDING charts, its \"2026 VT Tax Tables\" link serves
the percentage-method withholding tables, and TaxRateSched-2026.pdf is a
404.  That this is anomalous was confirmed by checking 2024, whose
equivalent file IS a genuine filer schedule.  So Vermont has either
mis-uploaded its 2026 files or not yet published them.  Recording 2025
truthfully is better than relabelling it 2026; `cmacs-calculator-tax-vintage'
will report the age.

A commercial site's claim of 2026 brackets at $45,400/$229,550 was
rejected: those are LOWER than 2025's $49,400/$249,700, which an
inflation adjustment cannot produce.

Not modeled: Vermont's minimum tax -- above $150,000 of federal AGI the
tax is the GREATER of the schedule result or 3% of federal AGI less
interest on U.S. obligations -- which can bind for high earners.  The
$1,250 additional deduction per 65-or-older/blind box is not modeled."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-va
   :name "Virginia"
   :year 2026
   :structure bracketed
   :source "Virginia Tax, 2025 Form 760 instructions p. 35 rate schedule, https://www.tax.virginia.gov/sites/default/files/vatax-pdf/2025-760-instructions.pdf; Virginia Tax, New Virginia Tax Laws, https://www.tax.virginia.gov/news/new-virginia-tax-laws"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Virginia does not double its brackets for joint filers: one ladder
   ;; serves every status.
   :brackets ((0 . 0.02) (3000 . 0.03) (5000 . 0.05) (17000 . 0.0575))
   :standard-deduction-single 8750
   :standard-deduction-married-joint 17500
   :standard-deduction-married-separate 8750
   :standard-deduction-head-of-household 8750
   :personal-exemption-single 930
   :personal-exemption-married-joint 1860
   :personal-exemption-married-separate 930
   :personal-exemption-head-of-household 930
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Virginia's brackets have been static for decades and were
confirmed unchanged for 2026 against the Department's own \"New Virginia
Tax Laws\" page; the standard deduction is confirmed for 2026.  A
frequently-repeated claim that a 10% bracket over $1,000,000 begins in
2026 is FALSE -- it comes from HB1074/SB676, 2026-session bills that were
NOT enacted.  Do not add that bracket.

Not modeled: because joint filers share the single ladder, Virginia
grants a Spouse Tax Adjustment to offset the resulting marriage penalty,
so married-joint results here OVERSTATE tax for two-earner couples.  The
standard deduction rises beginning 2027 by an amount not yet stated."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-wv
   :name "West Virginia"
   :year 2026
   :structure bracketed
   :source "WV Tax Division, Personal Income Tax Reduction Bill (W. Va. Code sec. 11-21-4j), https://tax.wv.gov/Individuals/Pages/PersonalIncomeTaxReductionBill.aspx; 2025 IT-140 instructions (exemption), https://tax.wv.gov/Documents/PIT/2025/it140.PersonalIncomeTaxFormsAndInstructions.2025.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; One schedule serves single, joint and head of household; married
   ;; filing separately gets a halved ladder.
   :brackets ((0 . 0.0211) (10000 . 0.0281) (25000 . 0.0316) (40000 . 0.0422)
              (60000 . 0.0458))
   :brackets-married-separate ((0 . 0.0211) (5000 . 0.0281) (12500 . 0.0316)
                               (20000 . 0.0422) (30000 . 0.0458))
   ;; West Virginia has no standard deduction: the phrase does not occur
   ;; in the IT-140 instructions.
   :standard-deduction 0
   :personal-exemption 2000
   :federal-deduction-allowed nil
   :local-tax nil
   :note "The 2026 rates reflect a 5% across-the-board cut enacted June
12, 2026 and retroactive to January 1, 2026 (W. Va. Code sec. 11-21-4j).
West Virginia municipalities levy flat \"city service fees\", but those
are not income taxes -- the instructions state they cannot be claimed as
West Virginia income tax withheld -- so `:local-tax' is nil."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-wi
   :name "Wisconsin"
   :year 2026
   :structure bracketed
   :source "Wisconsin DOR, 2026 Form 1-ES instructions D-101A (R. 1-26, laws enacted as of 2026-01-16), https://www.revenue.wi.gov/TaxForms2026/2026-Form1-ES-Inst.pdf"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Schedule A serves single and head of household; Schedule B joint;
   ;; married-separate gets a third ladder.
   :brackets-single ((0 . 0.035) (15110 . 0.044) (51950 . 0.053)
                     (332720 . 0.0765))
   :brackets-head-of-household ((0 . 0.035) (15110 . 0.044) (51950 . 0.053)
                                (332720 . 0.0765))
   :brackets-married-joint ((0 . 0.035) (20150 . 0.044) (69260 . 0.053)
                            (443630 . 0.0765))
   :brackets-married-separate ((0 . 0.035) (10080 . 0.044) (34630 . 0.053)
                               (221820 . 0.0765))
   ;; Set to zero because Wisconsin's standard deduction is a SLIDING
   ;; SCALE this schema cannot express -- see the note.  Zero is the
   ;; conservative choice: it is exactly right for high earners, whose
   ;; deduction has phased out entirely, and overstates tax below that.
   :standard-deduction 0
   :personal-exemption-single 700
   :personal-exemption-married-joint 1400
   :personal-exemption-married-separate 700
   :personal-exemption-head-of-household 700
   :federal-deduction-allowed nil
   :local-tax nil
   :note "BRACKETS VERIFIED FOR 2026, BUT THE STANDARD DEDUCTION IS NOT
REPRESENTABLE, hence unverified.  Wisconsin's standard deduction slides
with income rather than being a fixed amount, and this schema has no way
to express that, so it is set to 0 and tax is OVERSTATED for anyone below
the phase-out ceiling.  The published 2026 scale, recorded here so a
future schema can implement it:

  single      $13,960 if income <= $20,119; above $20,120, $13,960 less
              12% of the excess; $0 at $136,453 and up
  joint       $25,840 if income <= $29,039; above $29,040, $25,840 less
              19.778% of the excess; $0 at $159,690 and up
  head of hh  $18,030 less 22.515% of the excess over $20,120, then
              joins the single schedule
  separate    $12,280 less 19.778% of the excess over $13,780

A widely-repeated claim that Wisconsin moves to a 3.25% flat tax in 2026
is FALSE: it traces to 2023 SB1, which did not become law.  The
Department's own 2026 form confirms four brackets remain.  The $250
additional exemption for filers 65 and over is not modeled."))

;;; Flat-rate states
;;
;; Two states widely described as flat are NOT, and are registered as
;; `bracketed' below: Idaho and Mississippi each pair a single positive
;; rate with a 0% zero-bracket.  Modeling either as a plain flat rate taxes
;; income that is exempt.

(cmacs-calculator-tax-register
 '(:jurisdiction us-az
   :name "Arizona"
   :year 2025
   :structure flat
   :source "Arizona DOR, Individual Income Tax Highlights, https://azdor.gov/forms/individual-income-tax-highlights"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.025
   ;; Arizona conforms to the federal standard deduction, which is why
   ;; these are the OBBBA-level 2025 federal amounts.
   :standard-deduction-single 15750
   :standard-deduction-married-joint 31500
   :standard-deduction-married-separate 15750
   :standard-deduction-head-of-household 23625
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Flat 2.5% since 2023.  Personal exemptions were eliminated in
2019 and replaced by a dependent credit ($100 under 17, $25 otherwise,
phasing out), which is not modeled.  2026 figures were not published on
the DOR highlights page at the retrieval date."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-co
   :name "Colorado"
   :year 2025
   :structure flat
   :source "Colorado DOR, Individual Income Tax Guide (rev. January 2026) p. 4, https://tax.colorado.gov/sites/tax/files/documents/Individual_Income_Tax_Guide_January_2026.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.044
   ;; Colorado has no standard deduction of its own: it starts from
   ;; FEDERAL taxable income, so the federal deduction flows through.
   ;; These are the IRS 2025 amounts.
   :standard-deduction-single 15750
   :standard-deduction-married-joint 31500
   :standard-deduction-married-separate 15750
   :standard-deduction-head-of-household 23625
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Colorado's rate genuinely MOVES year to year: a TABOR surplus
temporarily cuts it below the 4.40% baseline, and the Department's own
table reads 4.4% (2022), 4.4% (2023), 4.25% (2024), 4.4% (2025).  So last
year's rate is not a safe guess for this year's.

No 2026 rate is registered because none is published -- the January 2026
guide's table stops at 2025, and the figure is TABOR-dependent, so it is
genuinely not yet knowable rather than merely unfound.  AI search
summaries asserting 4.0% or a \"permanent 4.25%\" cite introduced bills
that did not become law in that form; the Department says 4.4%.

Denver and several other cities levy occupational privilege taxes, but
those are flat monthly head taxes rather than income taxes, so
`:local-tax' is nil."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ga
   :name "Georgia"
   :year 2026
   :structure flat
   :source "Georgia DOR, Important Tax Updates, https://dor.georgia.gov/taxes/important-tax-updates"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0499
   :standard-deduction-single 15000
   :standard-deduction-married-joint 30000
   :standard-deduction-married-separate 15000
   :standard-deduction-head-of-household 15000
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "UNRESOLVED SOURCE CONFLICT, hence unverified.  Two Georgia DOR
publications disagree about the 2026 rate: the \"Important Tax Updates\"
page says 4.99% (used here), while the 2026 Employer's Withholding Tax
Guide, revised December 2025, reportedly says 5.19% -- which is the
verified 2025 rate (HB 111, April 2025, cut 5.39% to 5.19%).  The likely
explanation is that the withholding guide predates a 2026 change, but the
PDF is JavaScript-gated and could not be fetched to confirm.  Resolve
against the DOR before relying on this figure.

The personal exemption could not be verified: the updates page does not
mention exemptions, so it is set to 0 and tax may be overstated."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-id
   :name "Idaho"
   :year 2025
   ;; NOT flat, despite the common description: a 0% zero-bracket sits
   ;; below the single positive rate.
   :structure bracketed
   :source "Idaho State Tax Commission, Individual Income Tax Rate Schedule, https://tax.idaho.gov/taxes/income-tax/individual-income/individual-income-tax-rate-schedule/"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint)
   :brackets-single ((0 . 0.0) (4811 . 0.053))
   :brackets-married-joint ((0 . 0.0) (9622 . 0.053))
   :standard-deduction 0
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "MISSING DEDUCTION DATA, hence unverified.  The rate schedule is
verified for 2025, but Idaho's standard deduction and personal exemption
could not be confirmed from a primary source.  Idaho is generally
federal-conformed, which would put the deduction at the federal amounts,
but that was not verified and so is NOT assumed -- the deduction is set
to 0, which OVERSTATES Idaho tax substantially (by roughly 5.3% of the
real deduction).  Do not rely on this figure without supplying the
deduction yourself.

HB 40 (2025) cut the rate from 5.695% to 5.3% effective January 1, 2025.
No 2026 rate is published and no evidence of a 2026 change was found."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-il
   :name "Illinois"
   :year 2026
   :structure flat
   :source "Illinois DOR, 2026 Booklet IL-700-T, https://tax.illinois.gov/content/dam/soi/en/web/tax/forms/withholding/documents/currentyear/il-700-t.pdf; Informational Bulletin FY 2026-15"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0495
   :standard-deduction 0
   :personal-exemption-single 2925
   :personal-exemption-married-joint 5850
   :personal-exemption-married-separate 2925
   :personal-exemption-head-of-household 2925
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Rate and exemption both confirmed for 2026 from official
documents (the exemption was $2,850 for 2025).  Illinois has no standard
deduction.  Not modeled: the exemption allowance is disallowed ENTIRELY
above $500,000 AGI joint / $250,000 otherwise, so this over-deducts for
high earners; and the additional $1,000 exemption for filers 65+ or
blind."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-in
   :name "Indiana"
   :year 2026
   :structure flat
   :source "Indiana DOR, Departmental Notice #1 (effective 2026-01-01), https://www.in.gov/dor/files/dn01.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0295
   :standard-deduction 0
   :personal-exemption-single 1000
   :personal-exemption-married-joint 2000
   :personal-exemption-married-separate 1000
   :personal-exemption-head-of-household 1000
   :federal-deduction-allowed nil
   :local-tax t
   :note "UNDERSTATES THE REAL BURDEN: every Indiana county levies its own
income tax on top of the state rate, and Departmental Notice #1 carries
the full per-county table.  County rates can change each January and
October.  None of it is modeled (`:local-tax').  The $1,500 qualifying
dependent exemption is not modeled either."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ia
   :name "Iowa"
   :year 2026
   :structure flat
   :source "Iowa DOR, \"IDR Announces 2026 Individual Income Tax and Interest Rates\" (2025-10-21), https://revenue.iowa.gov/press-release/2025-10-21/idr-announces-2026-individual-income-tax-and-interest-rates"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.038
   ;; Iowa has no standard deduction of its own: the IA 1040 starts from
   ;; FEDERAL taxable income.  These are the IRS 2026 amounts.
   :standard-deduction-single 16100
   :standard-deduction-married-joint 32200
   :standard-deduction-married-separate 16100
   :standard-deduction-head-of-household 24150
   ;; Iowa's exemptions are CREDITS ($40 personal, $40 per dependent), not
   ;; deductions, so they are not expressed as an exemption here.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax t
   :note "Iowa became flat at 3.8% from tax year 2025 under SF 2442 (May
2024), confirmed on the 2025 IA 1040 itself (\"Iowa tax.  Multiply line 4
by 3.8%\").  Federal deductibility is REPEALED: the 2025 IA 1040 has no
federal income tax deduction line and begins from federal taxable income.
The exact statutory repeal-year citation was not pinned down, though the
repeal itself is evident from the form's structure.

Not modeled (`:local-tax'): school district surtaxes, and county EMS
surtaxes in Appanoose, Cass, Pocahontas, Sac, Shelby and Winnebago.  The
$40 exemption credits are not modeled, so tax is slightly overstated."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ky
   :name "Kentucky"
   :year 2026
   :structure flat
   :source "Kentucky DOR, 2026 Withholding Formula, https://revenue.ky.gov/Forms/2026%20Withholding%20Formula.pdf; \"Kentucky DOR Announces 2026 Standard Deduction\", https://revenue.ky.gov/News/Pages/Kentucky-DOR-Announces-2026-Standard-Deduction.aspx"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.035
   ;; Kentucky's standard deduction is a single amount that does not vary
   ;; by filing status.
   :standard-deduction 3360
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax t
   :note "Rate and standard deduction each confirmed for 2026 from two
independent DOR documents; the deduction is inflation-adjusted annually
under KRS 141.081 (it was $3,270 for 2025).  Kentucky has no personal
exemption -- it uses a family size tax credit, which is a credit and so
is not modeled.

`:local-tax' is flagged from general knowledge of Kentucky's occupational
license taxes (cities, counties, school districts) but was NOT verified
against a primary source in this research."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-la
   :name "Louisiana"
   :year 2025
   :structure flat
   :source "Louisiana Department of Revenue, Income Tax Reform FAQs, https://revenue.louisiana.gov/tax-education-and-faqs/faqs/income-tax-reform/what-are-the-individual-income-tax-rates-and-brackets/"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.03
   ;; Louisiana merges the exemption and deduction into one "combined
   ;; personal exemption-standard deduction"; the joint amount is
   ;; statutorily 200% of the single one.
   :standard-deduction-single 12500
   :standard-deduction-married-joint 25000
   :standard-deduction-married-separate 12500
   :standard-deduction-head-of-household 25000
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Louisiana's federal income tax deduction is GONE, and -- a point
routinely got wrong -- its repeal is NOT part of the flat tax.  Act 395
of 2021 repealed it effective for periods beginning on or after January
1, 2022, contingent on voters passing Constitutional Amendment #2 on
November 13, 2021, trading the deduction for lower rates.  The flat 3%,
which replaced the graduated brackets, is a separate and later change
effective 2025.  Some sources conflate this repeal with the unrelated IRC
sec. 280C deduction repeal.

Note Louisiana's WITHHOLDING tables use 3.09%, not the 3.00% liability
rate used here."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-mi
   :name "Michigan"
   :year 2026
   :structure flat
   :source "Michigan Treasury, \"State Individual Income Tax Rate for 2026 Tax Year Determined\" (2026-04-15), https://www.michigan.gov/treasury/news/2026/04/15/state-individual-income-tax-rate-for-2026-tax-year-determined; Form 446 (rev. 02-26)"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0425
   :standard-deduction 0
   :personal-exemption-single 5900
   :personal-exemption-married-joint 11800
   :personal-exemption-married-separate 5900
   :personal-exemption-head-of-household 5900
   :federal-deduction-allowed nil
   :local-tax t
   :note "The 2026 rate is confirmed to REMAIN 4.25%: the statutory
rate-reduction trigger was not met, because FY2025 general fund revenue
fell 1.56% against 2.70% inflation.  Per a 2024 Court of Appeals
decision, any reduction the 2015 law triggers is temporary and lasts one
year, so the rate reverts rather than ratcheting down -- which is why a
past cut does not imply a lower rate now.  The exemption was $5,800 for
2025.

Not modeled (`:local-tax'): Michigan city income taxes, including Detroit
and Grand Rapids."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ms
   :name "Mississippi"
   :year 2026
   ;; NOT flat: the first $10,000 of taxable income is exempt.
   :structure bracketed
   :source "Mississippi DOR, 2024 Resident Individual Income Tax booklet (carries the official 2024-2026 rate schedule), https://www.dor.ms.gov/sites/default/files/tax-forms/individual/80100241.pdf; 2025 legislation page, https://www.dor.ms.gov/forms-resources/laws-regulations/2025-legislation"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint married-separate head-of-household)
   :brackets ((0 . 0.0) (10000 . 0.04))
   ;; TY2024 figures -- see the note.
   :standard-deduction-single 2300
   :standard-deduction-married-joint 4600
   :standard-deduction-married-separate 2300
   :standard-deduction-head-of-household 3400
   :personal-exemption-single 6000
   :personal-exemption-married-joint 12000
   :personal-exemption-married-separate 6000
   :personal-exemption-head-of-household 8000
   :federal-deduction-allowed nil
   :local-tax nil
   :note "MIXED VINTAGE AND A WEAK SOURCE, hence unverified.  The rate
schedule IS verified for 2026 -- the booklet states it verbatim, \"Tax
Year 2024 Excess of $10,000 @ 4.7% / Tax Year 2025 @ 4.4% / Tax Year 2026
@ 4%\" -- but the STANDARD DEDUCTION and PERSONAL EXEMPTION above are
TY2024 figures: the 2025 and 2026 booklet URLs 404, so they could not be
confirmed unchanged.

Sourcing caveat: dor.ms.gov serves an incomplete TLS certificate chain
and fails verification, so the document was fetched with verification
relaxed.  Treat its provenance as weaker than the other tables here.

Mississippi is NOT a flat-tax state: the first $10,000 of taxable income
is exempt.  Worse for a calculator, on a JOINT return the $10,000
exemption applies to EACH SPOUSE's income separately -- this table's
joint ladder exempts only one $10,000, and so overstates tax for
two-earner couples.

HB 1 (2025) does not touch 2025 or 2026; its schedule begins at 2027
(3.75%), then 3.5%, 3.25%, and 3% in 2030, with trigger-based cuts
thereafter."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-nc
   :name "North Carolina"
   :year 2026
   :structure flat
   :source "NCDOR, Tax Rate Schedules, https://www.ncdor.gov/taxes-forms/individual-income-tax/tax-rate-schedules; NCDOR, North Carolina Standard Deduction, https://www.ncdor.gov/taxes-forms/individual-income-tax/filing-topics/north-carolina-standard-deduction-or-north-carolina-itemized-deductions"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0399
   ;; TY2025 figures -- see the note.
   :standard-deduction-single 12750
   :standard-deduction-married-joint 25500
   :standard-deduction-married-separate 12750
   :standard-deduction-head-of-household 19125
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "MIXED VINTAGE, hence unverified.  The 3.99% rate is verified for
2026 and after (Session Law 2023-134; 2025 was 4.25%), but the STANDARD
DEDUCTION above is the TY2025 figure -- the 2026 amount was not verified.

Two quirks a calculator gets wrong by default: North Carolina grants NO
additional standard deduction for filers 65+ or blind, unlike the federal
system; and a filer not eligible for the federal standard deduction gets
a North Carolina standard deduction of ZERO (as does a married-separate
filer whose spouse itemizes).  Further trigger-based rate reductions may
apply from 2027."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-pa
   :name "Pennsylvania"
   :year 2025
   :structure flat
   :source "Pennsylvania DOR, 2025 PA-40 instructions, https://www.pa.gov/content/dam/copapwp-pagov/en/revenue/documents/formsandpublications/formsforindividuals/pit/documents/2025/2025_pa-40in.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0307
   ;; Pennsylvania has neither a standard deduction nor a personal
   ;; exemption: the rate applies to the first dollar.
   :standard-deduction 0
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax t
   :note "The PA-40 instructions state it plainly: \"The state income tax
rate for 2025 is 3.07 percent (0.0307).\"  The rate is statutory and has
been 3.07% since 2004, but 2026 was not separately verified, so this is
registered as 2025.

Not modeled: Pennsylvania's Tax Forgiveness (Schedule SP) can eliminate
liability for low-income filers entirely, so this materially OVERSTATES
their tax.  Municipal and school district earned income taxes, and the
Philadelphia wage tax, are flagged but not modeled (`:local-tax')."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ut
   :name "Utah"
   :year 2026
   :structure flat
   :source "Utah S.B. 60 (2026 General Session, enrolled), amending Utah Code sec. 59-10-104, https://le.utah.gov/Session/2026/bills/enrolled/SB0060.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   :rate 0.0445
   ;; Utah has no standard deduction or personal exemption: it uses a
   ;; taxpayer tax credit, phased out by 1.3% of income over a
   ;; status-dependent threshold.  Credits are not modeled.
   :standard-deduction 0
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "OVERSTATES TAX: Utah replaces the deduction and exemption with a
taxpayer tax credit (phased out by 1.3% of income above a filing-status
threshold), and credits are not modeled, so this taxes from the first
dollar.

Sourcing: the Tax Commission's own rate page still shows \"January 1,
2025 - current: 4.5%\", but that page is the 2025 edition and is stale.
Enrolled S.B. 60 (2026) amends section 59-10-104 to 4.45%, effective May
6, 2026, and expressly \"has retrospective operation for a taxable year
beginning on or after January 1, 2026\".  The statute, not the rate page,
is authoritative here.  (Utah's bill-status pages render via JavaScript
and their static HTML contains a commented-out placeholder reading \"House
file for bills not passed\" -- misleading if scraped.)"))

(cmacs-calculator-tax-register
 '(:jurisdiction us-al
   :name "Alabama"
   :year 2025
   :structure bracketed
   :source "Alabama DOR, individual income tax rate FAQ, https://www.revenue.alabama.gov/faqs/what-is-alabamas-individual-income-tax-rate/; 2025 Form 40 booklet, https://www.revenue.alabama.gov/wp-content/uploads/2026/01/25f40bk.pdf"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-joint married-separate head-of-household)
   :brackets-single ((0 . 0.02) (500 . 0.04) (3000 . 0.05))
   :brackets-married-separate ((0 . 0.02) (500 . 0.04) (3000 . 0.05))
   :brackets-head-of-household ((0 . 0.02) (500 . 0.04) (3000 . 0.05))
   :brackets-married-joint ((0 . 0.02) (1000 . 0.04) (6000 . 0.05))
   ;; The FLOOR of Alabama's AGI-phased deduction -- see the note.
   :standard-deduction-single 2500
   :standard-deduction-married-joint 5000
   :standard-deduction-married-separate 2500
   :standard-deduction-head-of-household 2500
   :personal-exemption-single 1500
   :personal-exemption-married-joint 3000
   :personal-exemption-married-separate 1500
   :personal-exemption-head-of-household 3000
   :federal-deduction-allowed t
   :local-tax t
   :note "TWO UNMODELED FEATURES, hence unverified.

 (1) Alabama's standard deduction PHASES DOWN with AGI rather than being
     fixed, and this schema cannot express that.  The figures above are
     the FLOOR (single $2,500 at AGI $35,500+, from a $3,000 maximum
     below $26,000; joint $5,000 from an $8,500 maximum), so tax is
     overstated by at most about $25 single / $175 joint for lower
     incomes.
 (2) Far more significant: Alabama lets filers DEDUCT FEDERAL INCOME TAX
     PAID (Form 40 line 12), which this subsystem does not apply.  At a
     $100,000 income that deduction is worth roughly $650 of Alabama
     tax, so this table OVERSTATES liability substantially for anyone
     with a real federal bill.

Alabama's rates are statutory and the DOR's rate page carries no tax
year.  The dependent exemption ($1,000/$500/$300 by AGI band) is not
modeled.  Municipal occupational taxes exist (`:local-tax') but no
specific rate was verified.

Two source traps: a search summary claims the single standard deduction
is $4,500 -- that is the gross-income FILING THRESHOLD, not a deduction.
And the official booklet's joint chart has a probable typo, reading
\"$26,000-$26,499\" then \"$25,500-$26,999\"; the second row's start is
almost certainly $26,500.  Do not encode the overlap literally."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ar
   :name "Arkansas"
   :year 2026
   :structure bracketed
   :source "Arkansas DFA, 2026 Form AR1000ES tax rate schedule, https://www.dfa.arkansas.gov/wp-content/uploads/2026_Final_AR1000ES_1.pdf; 2026 withholding formula, https://www.dfa.arkansas.gov/wp-content/uploads/whformula_2026.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; One ladder for every filing status -- Arkansas does NOT double for
   ;; joint filers.  Thresholds are the published "over $X.99" figures.
   :brackets ((0 . 0.0) (5599.99 . 0.02) (11199.99 . 0.03) (15999.99 . 0.034)
              (26399.99 . 0.039))
   :standard-deduction-single 2470
   :standard-deduction-married-joint 4940
   :standard-deduction-married-separate 2470
   :standard-deduction-head-of-household 2470
   ;; Arkansas's exemptions are CREDITS ($29 single, $58 joint), not
   ;; deductions.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Arkansas publishes its withholding as \"rate x income minus an
adjustment\" rather than a marginal ladder; the AR1000ES schedule is the
only genuinely marginal source and is what this ladder comes from.  The
adjustments were checked to be algebraically equivalent.

Not modeled: a real claw-back zone between $94,701 and $97,800 of income,
where the minus-adjustment shrinks from $399.30 to $89.30 in $10 steps
per $100 of income, recovering the benefit of the low brackets.  Filers
in that band are UNDER-taxed here.  The $29/$58 exemption credits are not
modeled either, so tax is slightly overstated elsewhere.

Arkansas published no standalone 2026 indexed-bracket sheet, but two
official 2026 documents carry brackets and a $2,470 deduction identical
to 2025, so 2026 shows no indexing change.  A search summary claiming a
$2,410 standard deduction for 2025 is wrong -- that is the 2024 figure."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ca
   :name "California"
   :year 2025
   :structure bracketed
   :source "California FTB, 2025 Form 540 Tax Rate Schedules, https://www.ftb.ca.gov/forms/2025/2025-540-tax-rate-schedules.pdf; 2025 Form 540 instructions, https://www.ftb.ca.gov/forms/2025/2025-540-instructions.html"
   :retrieved "2026-07-17"
   :verified t
   ;; Schedule X serves single and married-separate; Schedule Y joint.
   ;; The head-of-household schedule was not captured.
   :filing-statuses (single married-separate married-joint)
   ;; The final band is the 12.3% top bracket PLUS the 1% Behavioral
   ;; Health Services Tax on taxable income over $1,000,000.  The FTB
   ;; computes that separately on Form 540 line 62 rather than in the
   ;; schedule, but it is levied on the same marginal basis, so folding it
   ;; in as a 13.3% band above $1,000,000 is exactly equivalent.
   :brackets-single ((0 . 0.01) (11079 . 0.02) (26264 . 0.04) (41452 . 0.06)
                     (57542 . 0.08) (72724 . 0.093) (371479 . 0.103)
                     (445771 . 0.113) (742953 . 0.123) (1000000 . 0.133))
   :brackets-married-separate ((0 . 0.01) (11079 . 0.02) (26264 . 0.04)
                               (41452 . 0.06) (57542 . 0.08) (72724 . 0.093)
                               (371479 . 0.103) (445771 . 0.113)
                               (742953 . 0.123) (1000000 . 0.133))
   ;; For joint filers the 11.3% band spans $891,542-$1,485,906, so the
   ;; $1,000,000 surcharge threshold falls INSIDE it and splits it:
   ;; 11.3% + 1% up to $1,485,906, then 12.3% + 1% above.
   :brackets-married-joint ((0 . 0.01) (22158 . 0.02) (52528 . 0.04)
                            (82904 . 0.06) (115084 . 0.08) (145448 . 0.093)
                            (742958 . 0.103) (891542 . 0.113)
                            (1000000 . 0.123) (1485906 . 0.133))
   :standard-deduction-single 5706
   :standard-deduction-married-separate 5706
   :standard-deduction-married-joint 11412
   ;; California's exemption is a $153 CREDIT, not a deduction.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "2025, NOT 2026 -- California had published no 2026 schedules at
the retrieval date.  The trap here is that FTB's 2026 Form 540-ES
worksheet PRINTS 2025 amounts as estimation proxies and tells filers to
\"use the 2025 tax table\"; its footer even reads \"Form 540-ES
Instructions 2025\".  Taking those numbers as 2026 figures would be
wrong.  California indexes to the California CPI and publishes late in
the year.

The 1% surcharge over $1,000,000 is still in force but was RENAMED from
the Mental Health Services Tax to the BEHAVIORAL HEALTH SERVICES TAX; the
2025 instructions contain zero occurrences of the old name, so any code
or search keyed to \"Mental Health\" now silently misses it.  It is folded
into the top band here (12.3% + 1% = 13.3%).

Not modeled: the $153-per-exemption credit (itself phasing out above
$252,203 single / $504,411 joint), and California SDI, which is 1.3% for
2026 with NO taxable wage limit since SB 951 -- a real payroll cost that
`cmacs-calculator-paycheck' does not deduct."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-ct
   :name "Connecticut"
   :year 2025
   :structure bracketed
   :source "Connecticut DRS, 2025 Form CT-1040 Tax Calculation Schedule, https://portal.ct.gov/-/media/drs/forms/2025/income/ct-1040-tcs_1225.pdf; IP 2026(1), https://portal.ct.gov/-/media/drs/publications/pubsip/2026/ip-2026-1.pdf"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-separate married-joint)
   :brackets-single ((0 . 0.02) (10000 . 0.045) (50000 . 0.055) (100000 . 0.06)
                     (200000 . 0.065) (250000 . 0.069) (500000 . 0.0699))
   :brackets-married-separate ((0 . 0.02) (10000 . 0.045) (50000 . 0.055)
                               (100000 . 0.06) (200000 . 0.065)
                               (250000 . 0.069) (500000 . 0.0699))
   :brackets-married-joint ((0 . 0.02) (20000 . 0.045) (100000 . 0.055)
                            (200000 . 0.06) (400000 . 0.065) (500000 . 0.069)
                            (1000000 . 0.0699))
   ;; Connecticut has no standard deduction at all.
   :standard-deduction 0
   ;; The personal exemption phases out entirely and cannot be expressed
   ;; as a fixed amount -- see the note.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "FOUR UNMODELED MECHANISMS, hence unverified.  Connecticut layers
more corrections onto its ladder than any other state, and the bare
brackets are a poor estimate on their own:

 (1) The PERSONAL EXEMPTION phases out with AGI and this schema cannot
     express it: single $15,000 at AGI at or below $30,000, falling
     $1,000 per $1,000 of AGI to $0 above $44,000 (joint $24,000 to $0
     above $71,000).  Set to 0 here, so LOW earners are badly
     over-taxed.
 (2) Table C, a 2% rate phase-out ADD-BACK, up to $250 single / $500
     joint at higher incomes.
 (3) Table D, a TAX RECAPTURE, up to $3,400 single / $6,800 joint, which
     claws back the lower brackets entirely for high earners.
 (4) Table E, personal tax credits, a decimal multiplier (0.75 down to
     0.00) applied to the tax itself.

Items 2-4 are not modeled, so this UNDER-taxes high earners and
OVER-taxes low ones.  Connecticut has no standard deduction.

The 2025 ladders are verified, and DRS's IP 2026(1) (effective January 1,
2026) reproduces identical ladders, so the RATES are unchanged for 2026 --
but the 2026 return-level Table A/C/D/E amounts are unpublished, so this
is registered as 2025."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-de
   :name "Delaware"
   :year 2025
   :structure bracketed
   :source "Delaware Division of Revenue, tax rate changes (schedule for tax years 2014 and later), https://revenue.delaware.gov/software-developer/tax-rate-changes/; 2025 PIT-RES instructions, https://revenuefiles.delaware.gov/2025/PITForms_Instructions/Instructions/PIT-RES_Instructions_2025-01.pdf"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; Delaware applies one ladder to every filing status; only the
   ;; standard deduction differs.
   :brackets ((0 . 0.0) (2000 . 0.022) (5000 . 0.039) (10000 . 0.048)
              (20000 . 0.052) (25000 . 0.0555) (60000 . 0.066))
   :standard-deduction-single 3250
   :standard-deduction-married-joint 6500
   :standard-deduction-married-separate 3250
   :standard-deduction-head-of-household 3250
   ;; Delaware's exemption is a $110 CREDIT, not a deduction.
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax t
   :note "Delaware does NOT double its brackets for joint filers -- one
ladder serves all statuses, and only the standard deduction differs.  The
rate schedule is stated as applying to \"tax years 2014 and later\".

Two reasons this will not match a filer's return to the dollar: below
$60,000 of taxable income Delaware requires a lookup TABLE computed at
the midpoint of each $50 range, which no formula reproduces exactly; and
at or above $60,000 Delaware rounds the intermediate (income - 60,000) x
0.066 to the penny BEFORE adding $2,943.50, which can shift the result a
dollar (their own example: $80,106 gives $4,271, not $4,270).

Not modeled: the $110 personal credit (plus $110 more at 60+), the extra
standard deduction for 65+/blind (amount unverified), and Wilmington's
1.25% earned income tax on residents and on non-residents working in the
city (`:local-tax')."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-dc
   :name "District of Columbia"
   :year 2026
   :structure bracketed
   :source "DC OTR, 2026 Form D-40ES booklet (REV 03/2026), https://otr.cfo.dc.gov/sites/default/files/dc/sites/otr/publication/attachments/2026_D40ES_Book_wLinks04012026.pdf; DC Code sec. 47-1806.02"
   :retrieved "2026-07-17"
   :verified t
   :filing-statuses (single married-joint married-separate head-of-household)
   ;; One ladder for every filing status -- DC does NOT double for joint
   ;; filers, which is a structural marriage penalty.
   :brackets ((0 . 0.04) (10000 . 0.06) (40000 . 0.065) (60000 . 0.085)
              (250000 . 0.0925) (500000 . 0.0975) (1000000 . 0.1075))
   :standard-deduction-single 16100
   :standard-deduction-married-separate 16100
   :standard-deduction-married-joint 32200
   :standard-deduction-head-of-household 24150
   ;; DC Code sec. 47-1806.02 is titled "Personal exemptions. [Repealed]".
   :personal-exemption 0
   :federal-deduction-allowed nil
   :local-tax nil
   :note "Directly confirmed for 2026 rather than inferred: the ladder is
stated as applying to tax years beginning after 2021-12-31 and is
reproduced identically in the 2026 D-40ES.  DC decoupled from the federal
standard deduction in 2025, and the 2026 amounts happen to match the
federal ones ($16,100/$32,200/$24,150) while 2025's did not
($15,000/$30,000/$22,500) -- so they must not be assumed to track it.

DC does not double brackets for joint filers; it offers
married-filing-separately-on-the-same-return to mitigate the resulting
penalty.  Personal exemptions are repealed outright.  `:local-tax' is nil
because DC IS the local jurisdiction.

Source trap: searches surface a \"TY 2026 Pertinent Data Book\" for DC --
it is real-property assessment data (rents and cap rates), not income
tax.  Not usable here.  The additional deduction for aged or blind
filers ($1,650, or $2,050 if unmarried) is not modeled."))

(cmacs-calculator-tax-register
 '(:jurisdiction us-hi
   :name "Hawaii"
   :year 2026
   :structure bracketed
   :source "Hawaii DOTAX, Announcement 2024-03 (Act 46, SLH 2024), https://files.hawaii.gov/tax/news/announce/ann24-03.pdf; DOTAX rate schedules for taxable years beginning after 2024-12-31, https://tax.hawaii.gov/forms/d_25table-on/d_25table-on_p13/"
   :retrieved "2026-07-17"
   :verified nil
   :filing-statuses (single married-separate married-joint)
   :brackets-single ((0 . 0.014) (9600 . 0.032) (14400 . 0.055) (19200 . 0.064)
                     (24000 . 0.068) (36000 . 0.072) (48000 . 0.076)
                     (125000 . 0.079) (175000 . 0.0825) (225000 . 0.09)
                     (275000 . 0.10) (325000 . 0.11))
   :brackets-married-separate ((0 . 0.014) (9600 . 0.032) (14400 . 0.055)
                               (19200 . 0.064) (24000 . 0.068) (36000 . 0.072)
                               (48000 . 0.076) (125000 . 0.079)
                               (175000 . 0.0825) (225000 . 0.09)
                               (275000 . 0.10) (325000 . 0.11))
   :brackets-married-joint ((0 . 0.014) (19200 . 0.032) (28800 . 0.055)
                            (38400 . 0.064) (48000 . 0.068) (72000 . 0.072)
                            (96000 . 0.076) (250000 . 0.079) (350000 . 0.0825)
                            (450000 . 0.09) (550000 . 0.10) (650000 . 0.11))
   :standard-deduction-single 8000
   :standard-deduction-married-separate 8000
   :standard-deduction-married-joint 16000
   ;; 2025 figure -- see the note.
   :personal-exemption 1144
   :federal-deduction-allowed nil
   :local-tax nil
   :note "MIXED VINTAGE, hence unverified: the brackets and standard
deduction are verified for 2026, but the PERSONAL EXEMPTION above is the
2025 figure ($1,144), since no 2026 form confirming it was found.

The Act 46 staggering is the trap, and 2026 is exactly when it bites.
Act 46 (SLH 2024) moves the standard deduction in 2024, 2026, 2028, 2030
and 2031, but widens the BRACKETS in 2025, 2027 and 2029 -- different
years.  So tax year 2026 uses the 2025 BRACKETS together with a brand-new
and much larger standard deduction ($8,000/$16,000, nearly double 2025's
$4,400/$8,800).  Announcement 2024-03 says so explicitly: \"For tax year
2026... The income tax brackets will be the same as in tax year 2025.\"
Compounding it, DOTAX's rate page is titled \"For Taxable Years Beginning
After December 31, 2024\", which covers 2025 AND 2026 -- it looks stale
but is current.

Not modeled: the extra exemption at 65+, and the $7,000 disability
exemption granted in lieu of the ordinary one."))

(provide 'cmacs-calculator-tax-data)
;;; cmacs-calculator-tax-data.el ends here
