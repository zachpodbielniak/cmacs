;;; cmacs-office-formula.el --- spreadsheet formulas via GNU Calc -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Evaluating a spreadsheet formula means bridging three languages:
;; Excel's (`=SUM(A1:A5)*2'), OpenFormula's (`of:=SUM([.A1:.A5])*2'),
;; and GNU Calc's.  They are genuinely different, and pretending
;; otherwise produces wrong numbers rather than errors.
;;
;; The division of labour here is deliberate:
;;
;;   Range functions -- SUM, AVERAGE, MIN, MAX, COUNT and friends --
;;   are computed in Elisp, straight from the cell values.  They are
;;   arithmetic over a list, and routing them through Calc would mean
;;   guessing at its vector function names and getting silent wrong
;;   answers when the guess is off.
;;
;;   Everything left over is scalar arithmetic, and THAT goes to
;;   `cmacs-calculator-eval' -- which is the real prize, because it
;;   brings Calc's arbitrary precision, units and CAS along with it.
;;
;; A formula using anything not in `cmacs-office-formula-functions' is
;; reported as unsupported rather than guessed at.  Callers fall back to
;; the value the file already cached, which is what a spreadsheet
;; application computed and is therefore right.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-calculator-eval "cmacs-calculator" (expr))
(declare-function cmacs-office-cells "src/cmacs-office-defuns.c" (handle))

(defgroup cmacs-office-formula nil
  "Spreadsheet formula evaluation."
  :group 'cmacs-office
  :prefix "cmacs-office-formula-")

(defconst cmacs-office-formula-functions
  '(("SUM"     . cmacs-office-formula--sum)
    ("AVERAGE" . cmacs-office-formula--average)
    ("MEAN"    . cmacs-office-formula--average)
    ("MIN"     . cmacs-office-formula--min)
    ("MAX"     . cmacs-office-formula--max)
    ("COUNT"   . cmacs-office-formula--count)
    ("COUNTA"  . cmacs-office-formula--counta)
    ("PRODUCT" . cmacs-office-formula--product))
  "Range functions this build evaluates, and the Elisp that does it.

Deliberately short.  A formula naming anything else is reported as
unsupported, so the caller keeps the value the file already cached
rather than showing a number nobody computed.")

(defun cmacs-office-formula--numbers (values)
  "Return the numeric members of VALUES, as floats."
  (delq nil (mapcar (lambda (v)
                      (and (stringp v)
                           (string-match-p
                            "\\`[ \t]*[-+]?[0-9.]+\\(?:[eE][-+]?[0-9]+\\)?[ \t]*\\'"
                            v)
                           (string-to-number v)))
                    values)))

(defun cmacs-office-formula--sum (values)
  (apply #'+ (cmacs-office-formula--numbers values)))

(defun cmacs-office-formula--product (values)
  (apply #'* (or (cmacs-office-formula--numbers values) '(0))))

(defun cmacs-office-formula--average (values)
  (let ((ns (cmacs-office-formula--numbers values)))
    (if ns (/ (apply #'+ ns) (float (length ns))) 0)))

(defun cmacs-office-formula--min (values)
  (let ((ns (cmacs-office-formula--numbers values)))
    (if ns (apply #'min ns) 0)))

(defun cmacs-office-formula--max (values)
  (let ((ns (cmacs-office-formula--numbers values)))
    (if ns (apply #'max ns) 0)))

(defun cmacs-office-formula--count (values)
  (length (cmacs-office-formula--numbers values)))

(defun cmacs-office-formula--counta (values)
  (length (delq nil (mapcar (lambda (v)
                              (and (stringp v)
                                   (not (string-empty-p (string-trim v)))
                                   v))
                            values))))

;;; Reference resolution

(defun cmacs-office-formula-normalise (formula)
  "Strip the format-specific decoration from FORMULA.

OpenDocument writes `of:=SUM([.A1:.A5])', wrapping every reference in
brackets and prefixing the sheet with a dot; Excel writes plain
`SUM(A1:A5)'.  Both reduce to the same thing once the decoration is
removed."
  (let ((s (string-trim (or formula ""))))
    (setq s (replace-regexp-in-string "\\`\\(?:of\\|oooc\\):" "" s))
    (setq s (replace-regexp-in-string "\\`=" "" s))
    ;; [.A1:.A5] -> A1:A5, and [.A1] -> A1
    (setq s (replace-regexp-in-string
             "\\[\\([^]]*\\)\\]"
             (lambda (m)
               (replace-regexp-in-string "\\." "" (match-string 1 m)))
             s))
    (string-trim s)))

(defun cmacs-office-formula--ref-to-rc (ref)
  "Return (ROW . COL) for the A1-style REF, or nil."
  (when (string-match "\\`\\$?\\([A-Za-z]+\\)\\$?\\([0-9]+\\)\\'" ref)
    (let ((letters (upcase (match-string 1 ref)))
          (row (string-to-number (match-string 2 ref)))
          (col 0))
      (dotimes (i (length letters))
        (setq col (+ (* col 26) (- (aref letters i) ?A -1))))
      (cons row col))))

(defun cmacs-office-formula--lookup (cells sheet row col)
  "Return the text of the cell at ROW and COL of SHEET in CELLS."
  (or (cl-loop for c in cells
               when (and (= row (plist-get c :row))
                         (= col (plist-get c :col))
                         (or (null sheet)
                             (equal sheet (plist-get c :sheet))))
               return (plist-get c :text))
      ""))

(defun cmacs-office-formula--range (cells sheet from to)
  "Return the texts of the cells in the FROM:TO rectangle of SHEET."
  (let* ((a (cmacs-office-formula--ref-to-rc from))
         (b (cmacs-office-formula--ref-to-rc to))
         (out nil))
    (when (and a b)
      (cl-loop for row from (min (car a) (car b)) to (max (car a) (car b)) do
               (cl-loop for col from (min (cdr a) (cdr b)) to (max (cdr a) (cdr b))
                        do (push (cmacs-office-formula--lookup cells sheet row col)
                                 out))))
    (nreverse out)))

;;; Evaluation

(defun cmacs-office-formula--replace-all (regexp string fn)
  "Replace every REGEXP match in STRING with the result of FN.

FN receives the list of capture groups 1..3 and returns a replacement
string, or nil to leave the match alone.

Written as an explicit loop rather than with `replace-regexp-in-string'
and a function, because the replacement here needs to look cells up --
and any `string-match' inside that callback clobbers the match data
`replace-regexp-in-string' still needs to splice with.  The symptom is
silent and strange: `SUM(A1:A3)' comes back as `6M(A1:A3)'."
  (let ((out "")
        (pos 0))
    (while (string-match regexp string pos)
      (let* ((mb (match-beginning 0))
             (me (match-end 0))
             (groups (list (match-string 1 string)
                           (match-string 2 string)
                           (match-string 3 string)))
             (rep (save-match-data (funcall fn groups))))
        (setq out (concat out (substring string pos mb)
                          (or rep (substring string mb me)))
              pos me)))
    (concat out (substring string pos))))

(defun cmacs-office-formula-eval (formula cells &optional sheet)
  "Evaluate FORMULA against CELLS and return its value as a string.

CELLS is what `cmacs-office-cells' returns; SHEET restricts unqualified
references to one sheet.

Returns nil when the formula uses anything outside
`cmacs-office-formula-functions', which is the signal to keep the value
the file already cached rather than display a guess."
  (let ((expr (cmacs-office-formula-normalise formula))
        (unsupported nil))
    ;; Range functions first: each collapses to a literal number, which
    ;; leaves plain scalar arithmetic behind.
    (setq expr
          (cmacs-office-formula--replace-all
           "\\([A-Za-z]+\\)(\\s-*\\(\\$?[A-Za-z]+\\$?[0-9]+\\)\\s-*:\\s-*\\(\\$?[A-Za-z]+\\$?[0-9]+\\)\\s-*)"
           expr
           (lambda (groups)
             (let* ((fn (upcase (or (nth 0 groups) "")))
                    (entry (assoc fn cmacs-office-formula-functions)))
               (if (null entry)
                   (progn (setq unsupported fn) nil)
                 (cmacs-office-formula--fmt
                  (funcall (cdr entry)
                           (cmacs-office-formula--range
                            cells sheet (nth 1 groups) (nth 2 groups)))))))))
    (if unsupported
        nil
      ;; Then bare references, each replaced by its value.  A reference
      ;; to an empty or non-numeric cell becomes 0, which is what
      ;; spreadsheets do in an arithmetic context.
      (setq expr
            (cmacs-office-formula--replace-all
             "\\(\\$?[A-Za-z]\\{1,3\\}\\$?[0-9]+\\)"
             expr
             (lambda (groups)
               (let* ((rc (cmacs-office-formula--ref-to-rc
                           (replace-regexp-in-string "\\$" "" (nth 0 groups))))
                      (text (and rc (cmacs-office-formula--lookup
                                     cells sheet (car rc) (cdr rc))))
                      (n (car (cmacs-office-formula--numbers (list text)))))
                 (if n (cmacs-office-formula--fmt n) "0")))))
      ;; Any function call left over is one we do not implement.
      (if (string-match-p "[A-Za-z]\\{2,\\}\\s-*(" expr)
          nil
        (cmacs-office-formula--calc expr)))))

(defun cmacs-office-formula--calc (expr)
  "Evaluate the scalar arithmetic EXPR through GNU Calc.

Prefers `cmacs-calculator-eval', which corrects several Calc defaults
that are wrong for this purpose -- notably that stock Calc reads
`2/3*4' as 2/(3*4).  Falls back to `calc-eval', which ships with Emacs,
so formulas still evaluate in a build without the calculator subsystem
\(with that division caveat)."
  (setq expr (string-trim expr))
  (cond
   ((string-empty-p expr) nil)
   ;; A range function that already collapsed to a literal needs no
   ;; evaluator at all.
   ((string-match-p "\\`[-+]?[0-9]*\\.?[0-9]+\\(?:[eE][-+]?[0-9]+\\)?\\'" expr)
    (cmacs-office-formula--fmt (string-to-number expr)))
   ((progn (require 'cmacs-calculator nil t)
           (fboundp 'cmacs-calculator-eval))
    (condition-case nil
        (let ((v (cmacs-calculator-eval expr)))
          (cond ((numberp v) (cmacs-office-formula--fmt v))
                ((stringp v) v)
                (t nil)))
      (error nil)))
   ((progn (require 'calc nil t) (fboundp 'calc-eval))
    (condition-case nil
        (let ((v (calc-eval expr)))
          ;; calc-eval reports failure as (POSITION . MESSAGE).
          (and (stringp v) v))
      (error nil)))
   (t nil)))

(defun cmacs-office-formula--fmt (n)
  "Render N the way a spreadsheet would.
An integral float prints as an integer: nobody wants SUM to say 6.0."
  (if (and (floatp n) (= n (truncate n)))
      (number-to-string (truncate n))
    (number-to-string n)))

(provide 'cmacs-office-formula)
;;; cmacs-office-formula.el ends here
