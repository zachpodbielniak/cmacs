;;; cmacs-calculator-sheet.el --- Calculator sheet buffers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The primary calculator surface: a `.calc' sheet, which is a plain-text
;; buffer of expressions, one per line, that annotates itself with results.
;;
;;   # a mortgage
;;   price := 400000                          ⇒ 400000
;;   loanpmt(price * 0.8, 0.065, 30)          ⇒ 1684.62
;;
;; Nothing here is a widget: the file is text, so it diffs, greps and travels
;; over email.  \\[cmacs-calculator-sheet-eval-buffer] evaluates the whole
;; buffer, \\[cmacs-calculator-sheet-eval-line] one line, and
;; \\[cmacs-calculator-sheet-clear] strips every result.
;;
;; Results are idempotent
;; ----------------------
;; A result is appended to its own line as "  => VALUE" (with a real ⇒).
;; Every evaluation first REMOVES the previous annotation and then re-adds
;; one, so evaluating ten times leaves exactly one result per line rather
;; than ten.  That is what makes eval-on-idle safe to run continuously.
;;
;; A failing line annotates as "⇒ error: MESSAGE" and evaluation carries on:
;; one bad line in the middle of a sheet must not cost you the other forty.
;;
;; Variables are sheet-local
;; -------------------------
;; "NAME := EXPR" stores a value later lines can use.  Calc looks variables up
;; through the global symbol `var-NAME', so the obvious implementation --
;; `(set (intern "var-NAME") ...)' -- would leak every sheet's bindings into
;; every other sheet and into the REPL.  Instead the bindings are collected in
;; `cmacs-calculator-sheet--vars' (buffer-local) and established with
;; `cl-progv' around each evaluation, which binds them dynamically for exactly
;; the duration of that call.  A side benefit: the engine's strict check
;; (`cmacs-calculator--known-var-p', which asks `boundp') sees them and so
;; accepts the names, while an actual typo is still rejected.
;;
;; Symbolic sheets
;; ---------------
;; Evaluation is strict by default: a free variable is a typo and is reported.
;; That rejects CAS work like `deriv(x^3, x)', whose whole point is a free
;; variable, so \\[cmacs-calculator-sheet-toggle-symbolic] switches the sheet
;; to `cmacs-calculator-eval-symbolic'.  The trade is the engine's: symbolic
;; evaluation does not force constants, so `sin(pi/2)' stays `sin(pi / 2)'
;; until wrapped in `evalv()' by hand.

;;; Code:

(require 'cmacs-calculator)
(require 'cmacs-calculator-chart)
(require 'cmacs-calculator-inline)       ; `cmacs-calculator-error-message'
(require 'flymake)
(require 'subr-x)

(eval-when-compile (require 'cl-lib))

;; Families self-register into the registry; soft-required so font-lock and
;; completion see them even when a sheet is opened without the landing page.
(require 'cmacs-calculator-financial nil t)


;;; Customization

(defgroup cmacs-calculator-sheet nil
  "Calculator sheet buffers."
  :group 'cmacs-calculator
  :prefix "cmacs-calculator-sheet-")

(defcustom cmacs-calculator-sheet-eval-idle t
  "When non-nil, a sheet re-evaluates itself after you stop typing.
Evaluation is debounced by `cmacs-calculator-sheet-eval-debounce' and
never overlaps itself.  Because results are idempotent this only ever
rewrites the annotations, but a half-typed expression does annotate as
an error until it is finished; set this to nil to evaluate only on
demand."
  :type 'boolean
  :group 'cmacs-calculator-sheet)

(defcustom cmacs-calculator-sheet-eval-debounce 0.6
  "Idle seconds before a sheet re-evaluates itself."
  :type 'number
  :group 'cmacs-calculator-sheet)

(defcustom cmacs-calculator-sheet-eval-on-save t
  "When non-nil, saving a sheet evaluates it."
  :type 'boolean
  :group 'cmacs-calculator-sheet)

(defcustom cmacs-calculator-sheet-plot-range '(-10 . 10)
  "Default (FROM . TO) range for \\[cmacs-calculator-sheet-plot]."
  :type '(cons number number)
  :group 'cmacs-calculator-sheet)

(defface cmacs-calculator-sheet-result-face
  '((t :inherit font-lock-string-face))
  "Face for a computed result annotation."
  :group 'cmacs-calculator-sheet)

(defface cmacs-calculator-sheet-error-face
  '((t :inherit font-lock-warning-face))
  "Face for a failed line's error annotation."
  :group 'cmacs-calculator-sheet)


;;; Syntax

(defconst cmacs-calculator-sheet-result-marker "⇒"
  "String introducing a result annotation.")

(defconst cmacs-calculator-sheet--result-re
  "[ \t]*⇒.*$"
  "Regexp matching a result annotation and the whitespace before it.
Anchored to the line end; used both to strip a stale result and to find
where a line's expression stops.")

(defconst cmacs-calculator-sheet--assign-re
  "\\`[ \t]*\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*:=[ \t]*\\(.+\\)\\'"
  "Regexp matching a \"NAME := EXPR\" assignment line.")

(defconst cmacs-calculator-sheet--comment-re
  "\\`[ \t]*#"
  "Regexp matching a comment line.")

(defvar cmacs-calculator-sheet-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?. "." table)
    (modify-syntax-entry ?, "." table)
    (modify-syntax-entry ?: "." table)
    (modify-syntax-entry ?= "." table)
    table)
  "Syntax table for `cmacs-calculator-sheet-mode'.")


;;; Vocabulary (drives font-lock, completion and eldoc)

(defconst cmacs-calculator-sheet--calc-functions
  '("abs" "abssqr" "accum" "add" "afixp" "agmean" "alog" "and" "anest" "apart"
    "append" "appendrev" "apply" "arccos" "arccosh" "arcsin" "arcsincos"
    "arcsinh" "arctan" "arctan2" "arctanh" "arg" "arrange" "ash" "asum" "badd"
    "bern" "besJ" "besY" "beta" "betaB" "betaI" "bsub" "call" "cascent"
    "cdescent" "ceil" "cheight" "choose" "clean" "clip" "cnorm" "collect"
    "conj" "cons" "constant" "cos" "cosh" "cot" "coth" "cross" "csc" "csch"
    "ctrn" "cvec" "cwidth" "date" "day" "dbfield" "dbpower" "ddb" "decr" "deg"
    "deriv" "det" "deven" "dfact" "diag" "diff" "dimag" "dint" "div" "dnatnum"
    "dneg" "dnonneg" "dnonzero" "dnumint" "dodd" "dpos" "drange" "drat"
    "dreal" "dsadj" "dscalar" "efit" "egcd" "eq" "erf" "erfc" "esimplify"
    "euler" "evalv" "evalvn" "exp" "exp10" "expand" "expandpow" "expm1" "fact"
    "factor" "factors" "fceil" "fdiv" "ffinv" "ffloor" "find" "finv" "fit"
    "fitdummy" "fitparam" "fitvar" "fixp" "float" "floor" "frac" "freq"
    "fround" "frounde" "froundu" "fsolve" "ftrunc" "fv" "fvb" "fvl" "gamma"
    "gammaG" "gammaP" "gammaQ" "gammag" "gcd" "geq" "getdiag" "gpoly" "grade"
    "gt" "hasfitparams" "hasfitvars" "head" "histogram" "hms" "holiday" "hour"
    "hypot" "idiv" "idn" "if" "ilog" "im" "in" "incmonth" "incr" "incyear"
    "index" "inner" "integ" "integer" "intv" "inv" "irr" "irrb" "islin"
    "islinnt" "isqrt" "istrue" "julian" "kron" "land" "lcm" "ldiv" "leq" "lin"
    "linnt" "ln" "lnot" "lnp1" "log" "log10" "lor" "lsh" "lt" "ltpb" "ltpc"
    "ltpf" "ltpn" "ltpp" "ltpt" "lud" "lufadd" "lufdiv" "lufmul" "lufquant"
    "lufsub" "lupadd" "lupdiv" "lupmul" "lupquant" "lupsub" "makemod" "mant"
    "map" "mapa" "mapc" "mapd" "mapeq" "mapeqp" "mapeqr" "mapr" "match"
    "matches" "matchnot" "max" "maximize" "mcol" "mdims" "midi" "min"
    "minimize" "minute" "mod" "moebius" "month" "mrcol" "mrow" "mrrow" "mul"
    "neg" "negative" "neq" "nest" "newmonth" "newweek" "newyear" "nextprime"
    "ninteg" "nonvar" "not" "now" "nper" "nperb" "nperl" "npfield" "nppower"
    "npv" "npvb" "nrat" "nroot" "or" "outer" "pack" "pclean" "pcont" "pdeg"
    "pdiv" "pdivide" "pdivrem" "percent" "perm" "pfloat" "pfrac" "pgcd"
    "plead" "pmt" "pmtb" "polar" "polint" "poly" "pow" "powerexpand" "pprim"
    "prem" "prevprime" "prfac" "prime" "prod" "pv" "pvb" "pvl" "pwday"
    "raccum" "rad" "random" "rash" "rate" "rateb" "ratel" "ratint" "rcons"
    "rdup" "re" "real" "rect" "reduce" "reducea" "reducec" "reduced" "reducer"
    "refers" "relch" "rev" "rewrite" "rgrade" "rhead" "rmeq" "rms" "rnorm"
    "root" "roots" "rot" "round" "rounde" "roundu" "rreduce" "rreducea"
    "rreducec" "rreduced" "rreducer" "rsh" "rsort" "rsubvec" "rtail" "scf"
    "sdev" "sec" "sech" "second" "shuffle" "sign" "simplify" "sin" "sincos"
    "sinh" "sln" "solve" "sort" "spn" "sqr" "sqrt" "stir1" "stir2" "sub"
    "subscr" "subst" "subvec" "sum" "syd" "table" "tail" "tan" "tanh" "taylor"
    "tderiv" "time" "totient" "tr" "trn" "trunc" "typeof" "tzconv" "tzone"
    "unixtime" "unpack" "unpackt" "usimplify" "utpb" "utpc" "utpf" "utpn"
    "utpp" "utpt" "variable" "vcard" "vcompl" "vconcat" "vconcatrev" "vcorr"
    "vcount" "vcov" "vdiff" "vec" "venum" "vexp" "vflat" "vfloor" "vgmean"
    "vhmean" "vint" "vlen" "vmask" "vmatches" "vmax" "vmean" "vmeane"
    "vmedian" "vmin" "vpack" "vpcov" "vprod" "vpsdev" "vpvar" "vsdev" "vspan"
    "vsum" "vunion" "vunpack" "vvar" "vxor" "weekday" "wmaximize" "wminimize"
    "wroot" "xfit" "xor" "xpon" "year" "yearday")
  "Every GNU Calc built-in function, one name per calcFunc-.
Generated by admin/cmacs-calc-builtins-catalog.el (M-x
cmacs-calc-builtins-completion-list); regenerate there after an
upstream merge changes Calc.  The registry covers what cmacs adds;
this covers what Calc already had, so completion and font-lock do
not pretend `sqrt' is unknown.")

(defun cmacs-calculator-sheet--registry-names ()
  "Return the names of every registered calculator, as strings."
  (mapcar (lambda (entry) (symbol-name (plist-get entry :name)))
          (cmacs-calculator-list)))

(defun cmacs-calculator-sheet--names ()
  "Return every function name a sheet knows, as strings."
  (delete-dups (append (cmacs-calculator-sheet--registry-names)
                       (copy-sequence cmacs-calculator-sheet--calc-functions))))


;;; Font lock

(defvar-local cmacs-calculator-sheet--keywords nil
  "Font-lock keywords for this sheet.
Computed per buffer because the registry is populated by whichever
calculator families happen to be loaded, which is not known when this
file is.")

(defun cmacs-calculator-sheet--font-lock-keywords ()
  "Build the font-lock keyword list for a sheet."
  `(;; Error annotations before result annotations: both start with the
    ;; marker, and the first match wins.
    (,(concat "[ \t]*" cmacs-calculator-sheet-result-marker
              "[ \t]*error:.*$")
     0 'cmacs-calculator-sheet-error-face t)
    (,cmacs-calculator-sheet--result-re 0 'cmacs-calculator-sheet-result-face t)
    ("^[ \t]*\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*:="
     1 font-lock-variable-name-face)
    (,(regexp-opt (cmacs-calculator-sheet--names) 'symbols)
     1 font-lock-function-name-face)
    ("\\_<[0-9]+\\(?:\\.[0-9]*\\)?\\(?:[eE][-+]?[0-9]+\\)?\\_>"
     0 font-lock-constant-face)
    ("[-+*/^%!<>=]" 0 font-lock-operator-face)))


;;; Line analysis

(defun cmacs-calculator-sheet--expression-end ()
  "Return the position where the current line's expression stops.
That is the start of any result annotation, else the line end."
  (save-excursion
    (goto-char (line-beginning-position))
    (if (re-search-forward cmacs-calculator-sheet--result-re
                           (line-end-position) t)
        (match-beginning 0)
      (line-end-position))))

(defun cmacs-calculator-sheet--line-parts ()
  "Return (BEG END NAME EXPR) for the current line, or nil to skip it.

BEG and END bound the expression text in the buffer, NAME is the `:='
target as a string (nil for a bare expression) and EXPR is the
expression text.  Blank lines, comment lines and lines holding only a
result annotation return nil.  Purely analytical: the buffer is not
modified, which is what lets flymake use it."
  (let* ((line-beg (line-beginning-position))
         (limit (cmacs-calculator-sheet--expression-end))
         (text (buffer-substring-no-properties line-beg limit)))
    (unless (or (string-blank-p text)
                (string-match-p cmacs-calculator-sheet--comment-re text))
      (if (string-match cmacs-calculator-sheet--assign-re text)
          (list (+ line-beg (match-beginning 2))
                (+ line-beg (match-end 2))
                (match-string 1 text)
                (string-trim (match-string 2 text)))
        (let ((start (or (string-match "[^ \t]" text) 0)))
          (list (+ line-beg start) limit nil (string-trim text)))))))


;;; Evaluation

(defvar-local cmacs-calculator-sheet--vars nil
  "Alist of (NAME . CALC-FORM) for this sheet's `:=' assignments.
Rebuilt from scratch by every whole-buffer evaluation, so deleting an
assignment line actually unbinds it.")

(defvar-local cmacs-calculator-sheet-symbolic nil
  "When non-nil, evaluate this sheet with free variables permitted.
See the Commentary; toggled by \\[cmacs-calculator-sheet-toggle-symbolic].")

(defvar-local cmacs-calculator-sheet--eval-timer nil)
(defvar-local cmacs-calculator-sheet--evaluating nil
  "Non-nil while an evaluation is in flight, to keep them from overlapping.")
(defvar-local cmacs-calculator-sheet--tick nil
  "Value of `buffer-chars-modified-tick' after the last evaluation.
Lets the idle timer skip a buffer nothing has changed in.")

(defun cmacs-calculator-sheet--eval-string (expr)
  "Evaluate EXPR with this sheet's variables bound; return a string.
Signals `cmacs-calculator-error' like the engine does."
  (cl-progv
      (mapcar (lambda (v) (intern (concat "var-" (car v))))
              cmacs-calculator-sheet--vars)
      (mapcar #'cdr cmacs-calculator-sheet--vars)
    (if cmacs-calculator-sheet-symbolic
        (cmacs-calculator-eval-symbolic expr)
      (cmacs-calculator-eval expr))))

(defun cmacs-calculator-sheet--strip-result ()
  "Remove any result annotation from the current line."
  (save-excursion
    (goto-char (line-beginning-position))
    (when (re-search-forward cmacs-calculator-sheet--result-re
                             (line-end-position) t)
      (replace-match ""))))

(defun cmacs-calculator-sheet--annotate (text)
  "Append TEXT to the current line as a result annotation."
  (save-excursion
    (goto-char (line-end-position))
    (insert "  " cmacs-calculator-sheet-result-marker " " text)))

(defun cmacs-calculator-sheet--eval-line-at-point ()
  "Evaluate the current line in place; return `ok', `error' or nil.
Nil means the line was skipped (blank or a comment).  Any prior result
is removed first, which is what keeps repeated evaluation idempotent."
  (let ((raw (buffer-substring-no-properties (line-beginning-position)
                                             (line-end-position))))
    ;; Skip comments before touching the line, so a `#'-prefixed chart or
    ;; note is never rewritten.
    (if (or (string-blank-p raw)
            (string-match-p cmacs-calculator-sheet--comment-re raw))
        nil
      (cmacs-calculator-sheet--strip-result)
      (let ((parts (cmacs-calculator-sheet--line-parts)))
        (when parts
          (let ((name (nth 2 parts))
                (expr (nth 3 parts)))
            (condition-case err
                (let ((result (cmacs-calculator-sheet--eval-string expr)))
                  (when name
                    ;; Store the evaluated value, not the source text, so a
                    ;; later line referring to NAME does not re-do the work
                    ;; and cannot see a half-updated sheet.
                    (setf (alist-get name cmacs-calculator-sheet--vars
                                     nil nil #'equal)
                          (math-read-expr result)))
                  (cmacs-calculator-sheet--annotate result)
                  'ok)
              (error
               (cmacs-calculator-sheet--annotate
                (concat "error: " (cmacs-calculator-error-message err)))
               'error))))))))

(defun cmacs-calculator-sheet-eval-line ()
  "Evaluate the expression on the current line.
Variables assigned by earlier lines are visible only if the buffer has
been evaluated at least once; use \\[cmacs-calculator-sheet-eval-buffer]
to rebuild them."
  (interactive)
  (cmacs-calculator-sheet--ensure-mode)
  (pcase (cmacs-calculator-sheet--eval-line-at-point)
    ('nil (message "Nothing to evaluate on this line"))
    ('error (message "Line failed; see the annotation"))
    (_ (setq cmacs-calculator-sheet--tick (buffer-chars-modified-tick))
       (message "Evaluated"))))

(defun cmacs-calculator-sheet-eval-buffer ()
  "Evaluate every expression line in the sheet, top to bottom.

Assignments are rebuilt from scratch, so the sheet is a function of its
text alone.  A line that fails annotates its error and evaluation
continues with the next one."
  (interactive)
  (cmacs-calculator-sheet--ensure-mode)
  (if cmacs-calculator-sheet--evaluating
      ;; Re-entered from a timer while a pass is running; the pending pass
      ;; will pick up the current text anyway.
      nil
    (let ((cmacs-calculator-sheet--evaluating t)
          (evaluated 0)
          (failed 0))
      (setq cmacs-calculator-sheet--vars nil)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (pcase (cmacs-calculator-sheet--eval-line-at-point)
            ('ok (setq evaluated (1+ evaluated)))
            ('error (setq evaluated (1+ evaluated)
                          failed (1+ failed)))
            (_ nil))
          (forward-line 1)))
      (setq cmacs-calculator-sheet--tick (buffer-chars-modified-tick))
      (when (called-interactively-p 'interactive)
        (message "%d line%s evaluated%s"
                 evaluated (if (= evaluated 1) "" "s")
                 (if (zerop failed) "" (format ", %d failed" failed))))
      (list evaluated failed))))

(defun cmacs-calculator-sheet-clear ()
  "Remove every result annotation from the sheet."
  (interactive)
  (cmacs-calculator-sheet--ensure-mode)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (unless (string-match-p
               cmacs-calculator-sheet--comment-re
               (buffer-substring-no-properties (line-beginning-position)
                                               (line-end-position)))
        (cmacs-calculator-sheet--strip-result))
      (forward-line 1)))
  (setq cmacs-calculator-sheet--vars nil
        cmacs-calculator-sheet--tick (buffer-chars-modified-tick))
  (message "Results cleared"))

(defun cmacs-calculator-sheet-toggle-symbolic ()
  "Toggle symbolic evaluation for this sheet and re-evaluate it."
  (interactive)
  (cmacs-calculator-sheet--ensure-mode)
  (setq cmacs-calculator-sheet-symbolic (not cmacs-calculator-sheet-symbolic))
  (cmacs-calculator-sheet-eval-buffer)
  (force-mode-line-update)
  (message "Symbolic evaluation %s"
           (if cmacs-calculator-sheet-symbolic "on (free variables allowed)"
             "off (strict)")))


;;; Debounced, single-flight re-evaluation

(defun cmacs-calculator-sheet--schedule-eval ()
  "Debounce a whole-sheet re-evaluation."
  (when (timerp cmacs-calculator-sheet--eval-timer)
    (cancel-timer cmacs-calculator-sheet--eval-timer))
  (setq cmacs-calculator-sheet--eval-timer
        (run-with-idle-timer
         cmacs-calculator-sheet-eval-debounce nil
         #'cmacs-calculator-sheet--idle-eval (current-buffer))))

(defun cmacs-calculator-sheet--idle-eval (buffer)
  "Re-evaluate BUFFER if it still needs it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cmacs-calculator-sheet--eval-timer nil)
      ;; Nothing changed since the last pass (the last pass's own edits
      ;; included), or one is already running: do not churn.
      (unless (or cmacs-calculator-sheet--evaluating
                  (eql cmacs-calculator-sheet--tick
                       (buffer-chars-modified-tick)))
        (cmacs-calculator-sheet-eval-buffer)))))

(defun cmacs-calculator-sheet--after-change (&rest _)
  "Schedule an idle re-evaluation after an edit."
  (when (and cmacs-calculator-sheet-eval-idle
             (not cmacs-calculator-sheet--evaluating))
    (cmacs-calculator-sheet--schedule-eval)))

(defun cmacs-calculator-sheet--after-save ()
  "Evaluate the sheet on save, if configured."
  (when cmacs-calculator-sheet-eval-on-save
    (cmacs-calculator-sheet--schedule-eval)))

(defun cmacs-calculator-sheet--cleanup ()
  "Cancel this sheet's pending timer."
  (when (timerp cmacs-calculator-sheet--eval-timer)
    (cancel-timer cmacs-calculator-sheet--eval-timer)))


;;; Flymake

(defun cmacs-calculator-sheet--flymake-backend (report-fn &rest _)
  "Report syntax errors in the sheet to REPORT-FN.

Only PARSING is checked, not evaluation: parsing is cheap enough to run
on every keystroke, whereas evaluating a sheet of options pricing is not.
Evaluation failures are reported by the `⇒ error:' annotations instead."
  (let ((diagnostics nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when-let* ((parts (cmacs-calculator-sheet--line-parts)))
          (condition-case err
              (cmacs-calculator--parse (nth 3 parts))
            (cmacs-calculator-error
             (push (flymake-make-diagnostic
                    (current-buffer) (nth 0 parts) (nth 1 parts) :error
                    (cmacs-calculator-error-message err))
                   diagnostics))))
        (forward-line 1)))
    (funcall report-fn (nreverse diagnostics))))


;;; Completion and eldoc

(defun cmacs-calculator-sheet--capf ()
  "Complete calculator function names from the registry."
  (when-let* ((bounds (bounds-of-thing-at-point 'symbol)))
    (list (car bounds) (cdr bounds)
          (completion-table-dynamic
           (lambda (_) (cmacs-calculator-sheet--names)))
          :annotation-function
          (lambda (name)
            (when-let* ((entry (cmacs-calculator-get (intern name)))
                        (title (plist-get entry :title)))
              (concat "  " title)))
          :company-doc-buffer
          (lambda (name)
            (when-let* ((entry (cmacs-calculator-get (intern name))))
              (company-doc-buffer (cmacs-calculator-sheet--describe entry))))
          :exclusive 'no)))

(declare-function company-doc-buffer "company" (&optional string))

(defun cmacs-calculator-sheet--signature (entry)
  "Return the call signature of registry ENTRY as a string."
  (format "%s(%s)"
          (plist-get entry :name)
          (mapconcat (lambda (arg) (format "%s" (car arg)))
                     (plist-get entry :args) ", ")))

(defun cmacs-calculator-sheet--describe (entry)
  "Return a multi-line description of registry ENTRY."
  (string-join
   (delq nil
         (list (cmacs-calculator-sheet--signature entry)
               (plist-get entry :title)
               (plist-get entry :doc)
               (when-let* ((r (plist-get entry :returns)))
                 (concat "Returns: " r))))
   "\n\n"))

(defun cmacs-calculator-sheet--function-at-point ()
  "Return the registry entry for the function at or enclosing point, or nil.
Prefers the symbol under point; failing that, the head of the call point
sits inside, so eldoc keeps describing `loanpmt' while you fill in its
arguments."
  (or (when-let* ((symbol (thing-at-point 'symbol t)))
        (cmacs-calculator-get (intern symbol)))
      (save-excursion
        (condition-case nil
            (progn
              (up-list -1 t t)
              (skip-chars-backward "A-Za-z0-9_")
              (when-let* ((symbol (thing-at-point 'symbol t)))
                (cmacs-calculator-get (intern symbol))))
          (error nil)))))

(defun cmacs-calculator-sheet--eldoc (callback &rest _)
  "Describe the calculator function at point via CALLBACK."
  (when-let* ((entry (cmacs-calculator-sheet--function-at-point)))
    (funcall callback
             (format "%s -- %s"
                     (cmacs-calculator-sheet--signature entry)
                     (or (plist-get entry :title) ""))
             :thing (symbol-name (plist-get entry :name))
             :face 'font-lock-function-name-face)))


;;; Plotting

(defun cmacs-calculator-sheet--free-vars (expr)
  "Return the free variable symbols in EXPR, innermost first.
A variable is free when it is neither a Calc constant or unit nor
assigned by this sheet."
  (let ((form (cmacs-calculator--parse expr))
        (out nil))
    (cmacs-calculator--walk
     form
     (lambda (f)
       (when (eq (car-safe f) 'var)
         (let ((name (nth 1 f)))
           (unless (or (assoc (symbol-name name) cmacs-calculator-sheet--vars)
                       (cmacs-calculator--known-var-p name))
             (cl-pushnew name out))))))
    (nreverse out)))

(defun cmacs-calculator-sheet--insert-chart (chart)
  "Insert CHART below the current line, one `#'-prefixed line at a time.
Comment prefixes keep the chart out of the evaluator's way: a chart is
not an expression, and an un-prefixed SVG token or the multi-line unicode
fallback would be re-parsed as one on the next pass."
  (save-excursion
    (goto-char (line-end-position))
    (insert "\n")
    (let ((lines (split-string chart "\n")))
      (insert (mapconcat (lambda (line) (concat "# " line)) lines "\n")))))

(defun cmacs-calculator-sheet-plot (from to)
  "Plot the expression on the current line over its one free variable.

FROM and TO bound the variable; they default to
`cmacs-calculator-sheet-plot-range'.  The chart is inserted below the
line as comment-prefixed text.

The line must name exactly one free variable -- \"sin(x)\" plots,
\"2+2\" has nothing to vary and \"x*y\" is a surface, not a curve."
  (interactive
   (let ((default cmacs-calculator-sheet-plot-range))
     (list (read-number "From: " (car default))
           (read-number "To: " (cdr default)))))
  (cmacs-calculator-sheet--ensure-mode)
  (let ((parts (cmacs-calculator-sheet--line-parts)))
    (unless parts
      (user-error "Nothing to plot on this line"))
    (let* ((expr (nth 3 parts))
           (vars (condition-case err
                     (cmacs-calculator-sheet--free-vars expr)
                   (cmacs-calculator-error
                    (user-error "Cannot plot: %s"
                                (cmacs-calculator-error-message err))))))
      (cond
       ((null vars)
        (user-error "Nothing to plot: `%s' has no free variable" expr))
       ((cdr vars)
        (user-error "Cannot plot: `%s' has %d free variables (%s)"
                    expr (length vars)
                    (mapconcat #'symbol-name vars ", ")))
       (t
        (condition-case err
            (let ((chart (cmacs-calculator-plot
                          expr (symbol-name (car vars)) from to)))
              (cmacs-calculator-sheet--insert-chart chart)
              (message "Plotted %s over %s in [%s, %s]"
                       expr (car vars) from to))
          (cmacs-calculator-error
           (user-error "Cannot plot: %s"
                       (cmacs-calculator-error-message err)))))))))


;;; Mode

(defvar cmacs-calculator-sheet-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-calculator-sheet-eval-buffer)
    (define-key map (kbd "C-c C-e") #'cmacs-calculator-sheet-eval-line)
    (define-key map (kbd "C-c C-k") #'cmacs-calculator-sheet-clear)
    (define-key map (kbd "C-c C-p") #'cmacs-calculator-sheet-plot)
    (define-key map (kbd "C-c C-s") #'cmacs-calculator-sheet-toggle-symbolic)
    map)
  "Keymap for `cmacs-calculator-sheet-mode'.")

(defun cmacs-calculator-sheet--ensure-mode ()
  "Signal unless the current buffer is a calculator sheet."
  (unless (derived-mode-p 'cmacs-calculator-sheet-mode)
    (user-error "Not in a calculator sheet")))

;;;###autoload
(define-derived-mode cmacs-calculator-sheet-mode prog-mode "Calc-Sheet"
  "Major mode for `.calc' calculator sheets.

One expression per line; `#' starts a comment; \"NAME := EXPR\" assigns a
sheet-local variable that later lines may use.  Evaluating annotates each
line in place with its result, replacing any previous one.

\\{cmacs-calculator-sheet-mode-map}"
  :syntax-table cmacs-calculator-sheet-mode-syntax-table
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local cmacs-calculator-sheet--keywords
              (cmacs-calculator-sheet--font-lock-keywords))
  (setq-local font-lock-defaults '(cmacs-calculator-sheet--keywords))
  (setq-local mode-line-process
              '(:eval (when cmacs-calculator-sheet-symbolic " [sym]")))
  (add-hook 'completion-at-point-functions
            #'cmacs-calculator-sheet--capf nil t)
  (add-hook 'eldoc-documentation-functions
            #'cmacs-calculator-sheet--eldoc nil t)
  (add-hook 'flymake-diagnostic-functions
            #'cmacs-calculator-sheet--flymake-backend nil t)
  (add-hook 'after-change-functions
            #'cmacs-calculator-sheet--after-change nil t)
  (add-hook 'after-save-hook #'cmacs-calculator-sheet--after-save nil t)
  (add-hook 'kill-buffer-hook #'cmacs-calculator-sheet--cleanup nil t)
  (unless noninteractive
    (flymake-mode 1)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.calc\\'" . cmacs-calculator-sheet-mode))

(provide 'cmacs-calculator-sheet)
;;; cmacs-calculator-sheet.el ends here
