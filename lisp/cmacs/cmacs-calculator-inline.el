;;; cmacs-calculator-inline.el --- Inline calculator evaluation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Evaluate a calculator expression in ANY major mode, without switching to a
;; dedicated surface.  Point sits inside `sqrt(5/3*3^4)' anywhere -- an org
;; note, a C comment, an email -- and \\[cmacs-calculator-eval-dwim] answers
;; 11.6189500386.
;;
;; Finding the expression
;; ---------------------
;; With an active region, the region is the expression and no guessing
;; happens.  Otherwise the expression is the maximal run of
;; calculator-expression characters around point.  Whitespace is deliberately
;; NOT part of that character set: including it would swallow the prose around
;; the expression, so "the answer is sqrt(4) here" would evaluate the whole
;; sentence.
;;
;; Excluding whitespace outright would however break "2 + 3", which every user
;; expects to work, so a run is extended across whitespace only when an
;; operator sits on one side of the gap (`cmacs-calculator-inline--joins-p').
;; In "is sqrt(4)" the gap is bounded by `s' and `s', neither an operator, so
;; the prose is left alone; in "2 + 3" the gap is bounded by `+', so the run
;; grows.  Scanning is confined to the current line.
;;
;; Trailing sentence punctuation ("... is 2+2.") is trimmed only when it stops
;; the expression from parsing, so the decimal point in "3.14" survives.
;;
;; This file also owns `cmacs-calculator-error-message', the one place that
;; turns a `cmacs-calculator-error' signal into a sentence fit for the echo
;; area.  Reporting a result or a clean failure to the user from wherever they
;; happen to be is exactly this file's concern, so the sheet, the menu and the
;; REPL reuse it rather than each dumping a raw signal.

;;; Code:

(require 'cmacs-calculator)
(require 'subr-x)

;; Calculator families self-register into `cmacs-calculator-registry' when
;; loaded.  Soft-required so a build with only some families still works.
(require 'cmacs-calculator-financial nil t)


;;; Customization

(defgroup cmacs-calculator-inline nil
  "Inline calculator evaluation in arbitrary buffers."
  :group 'cmacs-calculator
  :prefix "cmacs-calculator-inline-")

(defcustom cmacs-calculator-inline-kill-result t
  "When non-nil, a plain \\[cmacs-calculator-eval-dwim] also copies the result.
The result is pushed onto the kill ring, so it can be yanked straight
back into the buffer."
  :type 'boolean
  :group 'cmacs-calculator-inline)


;;; Error reporting

(defun cmacs-calculator-error-message (err)
  "Return ERR, a caught error object, as a plain one-line sentence.

ERR is the (SYMBOL . DATA) object from `condition-case'.  A subtype
carries a meaningful headline, so it is kept: an unknown-function signal
reads \"Unknown function: foo\".  The root `cmacs-calculator-error' does
not -- its message is the generic \"CMacs calculator error\" banner and
its data is already a full sentence -- so the banner is dropped and
\":bogus\" reads \"unknown command `:bogus'\" rather than \"CMacs
calculator error: unknown command `:bogus'\".

`error-message-string' is the fallback for anything else; it is not used
for calculator errors because it renders their data quoted as Lisp,
which is noise in the echo area."
  (let ((symbol (car-safe err))
        (data (cdr-safe err)))
    (if (and symbol
             (memq 'cmacs-calculator-error (get symbol 'error-conditions)))
        (let ((detail (mapconcat (lambda (d) (format "%s" d)) data ": "))
              (base (if (eq symbol 'cmacs-calculator-error)
                        nil
                      (get symbol 'error-message))))
          (cond ((string-empty-p detail)
                 (or base (get 'cmacs-calculator-error 'error-message)))
                ((null base) detail)
                (t (format "%s: %s" base detail))))
      (error-message-string err))))


;;; Expression discovery

(defconst cmacs-calculator-inline--expr-chars
  "A-Za-z0-9_.,+*/%!()^-"
  "Characters that may appear in an expression run, as a `skip-chars' set.
Whitespace is excluded on purpose; see the Commentary.  `-' is last so
`skip-chars-forward' reads it as a literal rather than a range.")

(defconst cmacs-calculator-inline--wants-right-operand
  '(?+ ?- ?* ?/ ?^ ?% ?, ?\()
  "Characters that are incomplete without something to their RIGHT.
A gap after one of these is internal to the expression: the `+' in
\"2 + 3\" cannot be the end of anything.")

(defconst cmacs-calculator-inline--wants-left-operand
  '(?+ ?- ?* ?/ ?^ ?% ?, ?\))
  "Characters that are incomplete without something to their LEFT.
A gap before one of these is internal to the expression.

Note which paren is in which list.  `)' closes an expression, so it never
licenses bridging to its RIGHT -- were it in the other list, \"the answer
is sqrt(4) here\" would bridge the gap after `)' and swallow `here'.  By
the same argument `(' opens one and never licenses bridging to its LEFT.")

(defun cmacs-calculator-inline--joins-p (gap-start gap-end)
  "Return non-nil if the whitespace from GAP-START to GAP-END is internal.

The gap belongs to the expression when the token on either side of it
demands an operand across it: \"2 + 3\" is one expression because `+'
wants something on its right, while \"is sqrt(4)\" is prose followed by
an expression because nothing reaches across that gap."
  (or (memq (char-before gap-start) cmacs-calculator-inline--wants-right-operand)
      (memq (char-after gap-end) cmacs-calculator-inline--wants-left-operand)))

(defconst cmacs-calculator-inline--constants
  '("pi" "e" "phi" "gamma" "inf" "uinf" "nan")
  "Bare names that are expressions in their own right.
Used to tell `pi' (worth evaluating) from `some' (a word that happens to
sit under point).")

(defun cmacs-calculator-inline--plausible-p (str)
  "Return non-nil if STR is arithmetic rather than a stray word.

A run of letters with no digit, no operator and no call is prose --
point resting on the word \"some\" should report that there is nothing
to evaluate, not that `some' is an unbound variable."
  (or (string-match-p "[0-9]" str)
      (string-match-p "[-+*/^%(),]" str)
      (member str cmacs-calculator-inline--constants)))

(defun cmacs-calculator-inline--extend-backward ()
  "Move point back over expression runs joined by operator-bridged gaps.
Point must start at the beginning of a run."
  (catch 'done
    (while t
      (let ((start (point)))
        (skip-chars-backward " \t")
        (let ((gap-start (point)))
          ;; No gap, or a gap that prose owns: stop where we were.
          (when (or (= gap-start start)
                    (not (cmacs-calculator-inline--joins-p gap-start start)))
            (goto-char start)
            (throw 'done (point)))
          (skip-chars-backward cmacs-calculator-inline--expr-chars)
          ;; Gap with nothing before it: stop where we were.
          (when (= (point) gap-start)
            (goto-char start)
            (throw 'done (point))))))))

(defun cmacs-calculator-inline--extend-forward ()
  "Move point forward over expression runs joined by operator-bridged gaps.
Point must start at the end of a run."
  (catch 'done
    (while t
      (let ((end (point)))
        (skip-chars-forward " \t")
        (let ((gap-end (point)))
          (when (or (= gap-end end)
                    (not (cmacs-calculator-inline--joins-p end gap-end)))
            (goto-char end)
            (throw 'done (point)))
          (skip-chars-forward cmacs-calculator-inline--expr-chars)
          (when (= (point) gap-end)
            (goto-char end)
            (throw 'done (point))))))))

(defun cmacs-calculator-inline--bounds ()
  "Return the (BEG . END) bounds of the expression around point, or nil.
Scanning never leaves the current line."
  (save-excursion
    (save-restriction
      ;; Narrowing keeps every `skip-chars' call on this line, so a run
      ;; cannot swallow the line above or below.
      (narrow-to-region (line-beginning-position) (line-end-position))
      (let* ((beg (save-excursion
                    (skip-chars-backward cmacs-calculator-inline--expr-chars)
                    (cmacs-calculator-inline--extend-backward)))
             (end (save-excursion
                    (skip-chars-forward cmacs-calculator-inline--expr-chars)
                    (cmacs-calculator-inline--extend-forward))))
        (and (< beg end) (cons beg end))))))

(defun cmacs-calculator-inline--parses-p (str)
  "Return non-nil if STR parses as a calculator expression."
  (condition-case nil
      (progn (cmacs-calculator--parse str) t)
    (error nil)))

(defun cmacs-calculator-inline--trim (str)
  "Return STR with trailing punctuation that is not part of it removed.

Two different rules, because the two characters differ in kind:

`.' and `,' are dropped unconditionally.  A trailing one is never
meaningful arithmetic -- \"2+2.\" and \"2+2\" are the same value -- so in
\"the result is 2+2.\" the full stop can go without asking.  This has to
happen even though \"2+2.\" parses, or \\[universal-argument]
\\[cmacs-calculator-eval-dwim] would replace the sentence's punctuation
along with the expression.  A decimal point inside a number (\"3.14\") is
not trailing and is untouched.

`)' is dropped only when it blocks parsing, since `sqrt(4)' ends in one
legitimately.  That covers prose parens: the run found in \"(see 2+2)\"
is \"2+2)\", which does not parse until the stray `)' goes."
  (let ((s (string-trim str)))
    (while (and (not (string-empty-p s))
                (memq (aref s (1- (length s))) '(?. ?,)))
      (setq s (string-trim (substring s 0 (1- (length s))))))
    (let ((attempts 0))
      (while (and (not (string-empty-p s))
                  (< attempts 3)
                  (eq (aref s (1- (length s))) ?\))
                  (not (cmacs-calculator-inline--parses-p s)))
        (setq s (string-trim (substring s 0 (1- (length s))))
              attempts (1+ attempts))))
    s))

(defun cmacs-calculator-inline-expression ()
  "Return the calculator expression at point as a string, or nil.

The active region wins and is taken at its word: selecting a bare name
is an explicit request, and being told it is an unbound variable is a
useful answer to it.  Otherwise the expression is discovered by the scan
described in the Commentary, and must additionally look like arithmetic
\(`cmacs-calculator-inline--plausible-p') -- point idling on a word in a
paragraph should report nothing to evaluate rather than guess."
  (if (use-region-p)
      (let ((expr (cmacs-calculator-inline--trim
                   (buffer-substring-no-properties (region-beginning)
                                                   (region-end)))))
        (unless (string-empty-p expr) expr))
    (when-let* ((bounds (cmacs-calculator-inline--bounds))
                (expr (cmacs-calculator-inline--trim
                       (buffer-substring-no-properties (car bounds)
                                                       (cdr bounds)))))
      (and (not (string-empty-p expr))
           (cmacs-calculator-inline--plausible-p expr)
           expr))))

(defun cmacs-calculator-inline--region ()
  "Return the (BEG . END) region the expression occupies, or nil.
Mirrors `cmacs-calculator-inline-expression' so the replace and append
variants edit exactly the text that was evaluated."
  (if (use-region-p)
      (cons (region-beginning) (region-end))
    (when-let* ((bounds (cmacs-calculator-inline--bounds)))
      ;; `--trim' may have dropped trailing punctuation; shrink END to match
      ;; so replacing does not eat the sentence's full stop.
      (let* ((raw (buffer-substring-no-properties (car bounds) (cdr bounds)))
             (trimmed (cmacs-calculator-inline--trim raw))
             (dropped (- (length (string-trim-right raw))
                         (length trimmed))))
        (cons (car bounds) (- (cdr bounds) (max 0 dropped)))))))


;;; Commands

;;;###autoload
(defun cmacs-calculator-eval-dwim (&optional arg)
  "Evaluate the calculator expression at point or in the region.

Works in any major mode.  Returns the result as a string.

With no prefix ARG the result is shown in the echo area and, when
`cmacs-calculator-inline-kill-result' is non-nil, pushed onto the kill
ring.  With \\[universal-argument] the expression is replaced in the
buffer by its result.  With \\[universal-argument] \\[universal-argument]
the result is appended after the expression as \" = RESULT\".

Errors are reported as a plain message rather than a raw signal, so a
typo in a buffer of prose does not drop into the debugger."
  (interactive "P")
  (let ((expr (cmacs-calculator-inline-expression)))
    (if (null expr)
        (progn (message "No calculator expression at point") nil)
      (condition-case err
          (let ((result (cmacs-calculator-eval expr)))
            (cond
             ((equal arg '(4))
              (when-let* ((region (cmacs-calculator-inline--region)))
                (delete-region (car region) (cdr region))
                (goto-char (car region)))
              (insert result)
              (when (use-region-p) (deactivate-mark))
              (message "%s = %s" expr result))
             ((equal arg '(16))
              (when-let* ((region (cmacs-calculator-inline--region)))
                (goto-char (cdr region)))
              (insert " = " result)
              (when (use-region-p) (deactivate-mark))
              (message "%s = %s" expr result))
             (t
              (when cmacs-calculator-inline-kill-result
                (kill-new result))
              (message "%s = %s%s" expr result
                       (if cmacs-calculator-inline-kill-result " (copied)" ""))))
            result)
        (cmacs-calculator-error
         (message "Calculator: %s" (cmacs-calculator-error-message err))
         nil)))))


;;; Global minor mode

(defvar cmacs-calculator-inline-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c =") #'cmacs-calculator-eval-dwim)
    map)
  "Keymap for `cmacs-calculator-inline-mode'.")

;;;###autoload
(define-minor-mode cmacs-calculator-inline-mode
  "Global minor mode binding \\[cmacs-calculator-eval-dwim] in every buffer.

With it on, \\<cmacs-calculator-inline-mode-map>\\[cmacs-calculator-eval-dwim]
evaluates the expression at point wherever you are, so no buffer needs to
be a calculator buffer to do arithmetic in.

\\{cmacs-calculator-inline-mode-map}"
  :global t
  :group 'cmacs-calculator-inline
  :keymap cmacs-calculator-inline-mode-map
  :lighter " Calc=")

(provide 'cmacs-calculator-inline)
;;; cmacs-calculator-inline.el ends here
