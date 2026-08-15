;;; cmacs-ai-errors.el --- AI actions for things that went wrong  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An Errors group, wherever something has failed: a flymake or flycheck
;; diagnostic in a source buffer, a compilation or grep buffer, a
;; backtrace, the debugger.
;;
;; "Explain this" is the weak version of what you actually want from an
;; error.  The real questions are why it happened here, what the fix is,
;; and whether the message is even pointing at the right place -- none of
;; which the general operations have vocabulary for.
;;
;; Everything here answers in a result window.  Nothing edits your
;; buffer and nothing runs a build, on the same reasoning the Brigade
;; group composes rather than fires: an error is exactly the situation
;; where you have least reason to trust a confident-sounding change you
;; did not read.  A suggested fix arrives as a diff you can read and
;; apply yourself.
;;
;; The one thing this group does beyond prompting is widen the context.
;; The diagnostic resolver captures a few lines around the error because
;; a MENU has to be cheap to build; by the time an action runs, the
;; enclosing function is worth reading, so it is fetched then.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-actions)

(defgroup cmacs-ai-errors nil
  "AI actions for diagnostics, build output and backtraces."
  :group 'cmacs-ai
  :prefix "cmacs-ai-errors-")

(defcustom cmacs-ai-errors-context-lines 40
  "Lines of surrounding source fetched when an Errors action runs.

Wider than the resolver's own window, deliberately.  The resolver runs
while a menu is being built and must stay cheap; this is paid only when
you have chosen to ask about the error."
  :type 'integer
  :safe #'integerp)

;;;; System prompts ------------------------------------------------------

(defcustom cmacs-ai-errors-explain-system-prompt
  "You explain compiler, linter and runtime errors to an engineer who
knows the language.  Use Org-mode markup.

Lead with one line: what the message actually means, in plain terms.
Then why it is firing HERE, referring to the code you were given.  Then,
only if it is not obvious from the above, what to look at next.

Do not restate the error text back.  Do not explain the language's
general semantics.  If the message is misleading -- pointing at a
symptom rather than the cause, as type errors and linker errors often do
-- say so plainly and say where the cause probably is."
  "System prompt for `cmacs-ai-errors-explain'."
  :type 'string)

(defcustom cmacs-ai-errors-fix-system-prompt
  "You propose a fix for an error, as a diff a human will apply by hand.

Output a unified diff in an Org source block, then at most three lines
saying what it changes and why.  Nothing else.

Fix the CAUSE.  Silencing a warning, widening a type, adding a cast or
wrapping in a try block to make a message go away is not a fix, and if
that is genuinely the right answer here, say why in those three lines.

You are working from an excerpt: if the fix depends on code you were not
shown, say exactly what you would need to see instead of guessing at
it.  A confident wrong patch costs more than an honest question."
  "System prompt for `cmacs-ai-errors-fix'."
  :type 'string)

(defcustom cmacs-ai-errors-cause-system-prompt
  "You work out the root cause of a failure from a backtrace or build
log.  Use Org-mode markup.

Lead with your best single hypothesis in one line, and say how confident
you are in it.  Then the chain: what called what, where the bad value or
state came from, and the first frame that is actually the project's own
code rather than a library's.

List the two or three things worth checking, most likely first, each
with what you would expect to see if it were the cause.  Where the
evidence does not decide between hypotheses, say so rather than picking
one to sound decisive."
  "System prompt for `cmacs-ai-errors-cause'."
  :type 'string)

;;;; Applicability -------------------------------------------------------

(defun cmacs-ai-errors--target-p (target)
  "Non-nil when TARGET is something that went wrong."
  (memq (cmacs-ai-target-kind target) '(diagnostic backtrace)))

(defun cmacs-ai-errors--available-p (target)
  "Non-nil when the Errors actions apply to TARGET."
  (and (cmacs-ai-actions--ai-p) (cmacs-ai-errors--target-p target)))

(defun cmacs-ai-errors--backtrace-p (target)
  "Non-nil when TARGET is a backtrace rather than a single diagnostic."
  (eq (cmacs-ai-target-kind target) 'backtrace))

;;;; Context -------------------------------------------------------------

(defun cmacs-ai-errors--wider-source (target)
  "More of the source around TARGET than the resolver captured, or nil.

Only meaningful for a diagnostic sitting in a source buffer; a
compilation buffer's \"source\" is its own output, which the target
already holds."
  (let ((buffer (cmacs-ai-target-buffer target))
        (line (cmacs-ai-target-plist-get target :line)))
    (when (and (buffer-live-p buffer) line
               (with-current-buffer buffer (buffer-file-name)))
      (with-current-buffer buffer
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- line))
          (let ((beg (save-excursion
                       (forward-line (- cmacs-ai-errors-context-lines))
                       (line-beginning-position)))
                (end (save-excursion
                       (forward-line cmacs-ai-errors-context-lines)
                       (line-end-position))))
            (buffer-substring-no-properties beg end)))))))

(defun cmacs-ai-errors--prompt (target)
  "The user message describing TARGET and its surroundings."
  (let ((wider (cmacs-ai-errors--wider-source target))
        (file (cmacs-ai-target-file target))
        (lang (cmacs-ai-target-lang target)))
    (concat
     (if (cmacs-ai-errors--backtrace-p target)
         "This backtrace:\n\n" "This failure:\n\n")
     (cmacs-ai-target-content target)
     (when wider
       (format "\n\nThe surrounding code in %s%s:\n\n%s"
               (if file (abbreviate-file-name file) "the buffer")
               (if lang (format " (%s)" lang) "")
               wider)))))

(defun cmacs-ai-errors--run (title system target)
  "Stream SYSTEM over TARGET into a result window called TITLE."
  (cmacs-ai-textops-stream
   title (cmacs-ai-target-describe target) system
   (cmacs-ai-errors--prompt target)
   (lambda () (cmacs-ai-errors--run title system target))))

;;;; Commands ------------------------------------------------------------

(defun cmacs-ai-errors--target ()
  "The error at point, or signal."
  (let ((target (cmacs-ai-target-at)))
    (unless (and target (cmacs-ai-errors--target-p target))
      (user-error "cmacs-ai: no error, diagnostic or backtrace here"))
    target))

;;;###autoload
(defun cmacs-ai-errors-explain ()
  "Explain the error, diagnostic or build failure at point."
  (interactive)
  (cmacs-ai-errors--run "error" cmacs-ai-errors-explain-system-prompt
                        (cmacs-ai-errors--target)))

;;;###autoload
(defun cmacs-ai-errors-fix ()
  "Propose a fix for the error at point, as a diff to read and apply."
  (interactive)
  (cmacs-ai-errors--run "fix" cmacs-ai-errors-fix-system-prompt
                        (cmacs-ai-errors--target)))

;;;###autoload
(defun cmacs-ai-errors-cause ()
  "Work out the root cause of the failure at point."
  (interactive)
  (cmacs-ai-errors--run "root cause" cmacs-ai-errors-cause-system-prompt
                        (cmacs-ai-errors--target)))

;;;; Menu actions --------------------------------------------------------

(cmacs-ai-register-action
 :name 'cmacs-ai-errors-explain
 :group 'errors :order 10
 :label "Explain this error"
 :help "What it means, and why it is firing here"
 :applies #'cmacs-ai-errors--available-p
 :run (lambda (target)
        (cmacs-ai-errors--run "error"
                              cmacs-ai-errors-explain-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-errors-fix
 :group 'errors :order 20
 :label "Suggest a fix"
 :help "A diff to read and apply yourself -- nothing is changed for you"
 :applies #'cmacs-ai-errors--available-p
 :run (lambda (target)
        (cmacs-ai-errors--run "fix" cmacs-ai-errors-fix-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-errors-cause
 :group 'errors :order 30
 :label (lambda (target)
          (if (cmacs-ai-errors--backtrace-p target)
              "Trace the root cause"
            "Why is this happening?"))
 :help "Hypotheses, ranked, with what to check for each"
 :applies #'cmacs-ai-errors--available-p
 :run (lambda (target)
        (cmacs-ai-errors--run "root cause"
                              cmacs-ai-errors-cause-system-prompt target)))

(provide 'cmacs-ai-errors)

;;; cmacs-ai-errors.el ends here
