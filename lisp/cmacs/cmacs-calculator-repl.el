;;; cmacs-calculator-repl.el --- Calculator REPL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The calculator's line-oriented surface, in two shapes over one core.
;;
;; `cmacs-calculator-repl' is a BATCH loop: read a line from stdin, evaluate,
;; print, repeat.  It is what `emacs --calc' runs, so it must work both with a
;; tty and with piped stdin, and it must come up before much of Emacs exists.
;; It therefore requires nothing beyond the engine -- no comint, no cl-lib at
;; runtime, no display.  `cmacs-calculator-cli' is its one-shot sibling, for
;; `emacs --calc "2+2"'.
;;
;; `cmacs-calculator-repl-buffer' is the same core inside a running Emacs,
;; where the batch loop cannot be used: the batch loop owns stdin and would
;; block the editor.
;;
;; A bad line never kills the loop
;; -------------------------------
;; Every line is evaluated inside a `condition-case' that catches `error'
;; wholesale, not just `cmacs-calculator-error': Calc reaches into a lot of
;; code and a malformed expression can surface as an arithmetic or wrong-type
;; error from deep inside it.  A REPL that exits on a typo is not a REPL, so
;; anything that goes wrong prints "error: MESSAGE" and the loop continues.
;;
;; Where the output goes
;; ---------------------
;; In batch, `princ' and the `read-string' prompt go to stdout while `message'
;; goes to stderr.  That split is load-bearing: Calc chatters ("Building units
;; table...") through `message' during evaluation, and it lands on stderr
;; where a caller piping stdout never sees it.
;;
;; Modes are session state
;; -----------------------
;; `:prec', `:deg' and `:rad' set the engine's customization variables
;; buffer-locally.  Buffer-local rather than global so a REPL buffer in a
;; running Emacs cannot silently re-configure the user's other calculator
;; surfaces; in batch there is only ever the one buffer, so the effect is the
;; session-wide one you want.

;;; Code:

(require 'cmacs-calculator)
(require 'cmacs-calculator-inline)       ; `cmacs-calculator-error-message'
(require 'subr-x)

;; Families self-register into the registry, which `:list' reads.  Soft so a
;; partial build still starts.
(require 'cmacs-calculator-financial nil t)

;; The REPL BUFFER reuses the sheet's completion, eldoc and result faces, but
;; the batch loop must not drag in flymake and the chart tier to answer
;; "2+2".  So the sheet is required lazily, from the mode body, and only
;; declared here.
(declare-function cmacs-calculator-sheet--capf "cmacs-calculator-sheet")
(declare-function cmacs-calculator-sheet--eldoc "cmacs-calculator-sheet"
                  (callback &rest _))


;;; Customization

(defgroup cmacs-calculator-repl nil
  "Calculator REPL."
  :group 'cmacs-calculator
  :prefix "cmacs-calculator-repl-")

(defcustom cmacs-calculator-repl-prompt "calc> "
  "Prompt string for the calculator REPL."
  :type 'string
  :group 'cmacs-calculator-repl)

(defconst cmacs-calculator-repl-buffer-name "*cmacs-calculator-repl*"
  "Name of the interactive REPL buffer.")

(defface cmacs-calculator-repl-prompt-face
  '((t :inherit minibuffer-prompt))
  "Face for the REPL buffer's prompt.
Its own face rather than comint's: this REPL is not a comint (see
`cmacs-calculator-repl-buffer'), so comint's face may not be defined."
  :group 'cmacs-calculator-repl)


;;; Meta-commands

(defconst cmacs-calculator-repl--help
  "Enter an expression, or one of:

  :help              show this help
  :quit              leave the REPL
  :mode              show the current evaluation modes
  :prec N            set precision to N significant digits
  :deg               use degrees for trigonometry
  :rad               use radians for trigonometry
  :symbolic EXPR     evaluate EXPR allowing free variables (CAS)
  :units EXPR        express EXPR in base SI units
  :units EXPR -> U   convert EXPR to the units U
  :list [CATEGORY]   list the registered calculators

Anything else is evaluated as an expression."
  "Help text for the REPL's meta-commands.")

(defun cmacs-calculator-repl--modes-description ()
  "Return a description of the current evaluation modes."
  (format (concat "precision %d significant digits\n"
                  "angles     %s\n"
                  "strict     %s\n"
                  "infinite   %s\n"
                  "* binds tighter than /  %s")
          cmacs-calculator-precision
          cmacs-calculator-angle-mode
          (if cmacs-calculator-strict "on" "off")
          (if cmacs-calculator-infinite-mode "on" "off")
          (if cmacs-calculator-multiplication-has-precedence "yes" "no")))

(defun cmacs-calculator-repl--list (category)
  "Return a listing of registered calculators in CATEGORY, or all of them.
CATEGORY is a string, or nil for a listing grouped by category."
  (let ((categories (if category
                        (list (intern category))
                      (cmacs-calculator-categories))))
    (if (null categories)
        "No calculators are registered."
      (string-join
       (delq nil
             (mapcar
              (lambda (cat)
                (let ((entries (cmacs-calculator-list cat)))
                  (when entries
                    (concat
                     (format "%s:\n" cat)
                     (mapconcat
                      (lambda (entry)
                        (format "  %-18s %s"
                                (plist-get entry :name)
                                (or (plist-get entry :title) "")))
                      entries "\n")))))
              categories))
       "\n\n"))))

(defun cmacs-calculator-repl--units (argument)
  "Handle the `:units' meta-command for ARGUMENT.
ARGUMENT is either an expression, or \"EXPR -> UNITS\"."
  (if (string-match "\\`\\(.+?\\)[ \t]*->[ \t]*\\(.+\\)\\'" argument)
      (cmacs-calculator-convert-units (string-trim (match-string 1 argument))
                                      (string-trim (match-string 2 argument)))
    (cmacs-calculator-to-base-units argument)))

(defun cmacs-calculator-repl--set-precision (argument)
  "Handle the `:prec' meta-command for ARGUMENT."
  (let ((n (and (string-match-p "\\`[0-9]+\\'" (string-trim argument))
                (string-to-number (string-trim argument)))))
    (unless (and n (> n 0))
      (signal 'cmacs-calculator-error
              (list "precision must be a positive integer" argument)))
    (setq-local cmacs-calculator-precision n)
    (format "precision set to %d significant digits" n)))

(defun cmacs-calculator-repl--meta (line)
  "Handle LINE, a `:'-prefixed meta-command.
Returns a string to print, or the symbol `quit'.  Signals like the engine
does on bad input, so the caller's one error path covers meta-commands
too."
  (let* ((space (string-match "[ \t]" line))
         (command (if space (substring line 0 space) line))
         (argument (string-trim (if space (substring line space) ""))))
    (pcase command
      (":help" cmacs-calculator-repl--help)
      ((or ":quit" ":exit" ":q") 'quit)
      (":mode" (cmacs-calculator-repl--modes-description))
      (":prec" (cmacs-calculator-repl--set-precision argument))
      (":deg" (setq-local cmacs-calculator-angle-mode 'deg) "angle mode: degrees")
      (":rad" (setq-local cmacs-calculator-angle-mode 'rad) "angle mode: radians")
      (":symbolic"
       (if (string-empty-p argument)
           (signal 'cmacs-calculator-error (list ":symbolic needs an expression"))
         (cmacs-calculator-eval-symbolic argument)))
      (":units"
       (if (string-empty-p argument)
           (signal 'cmacs-calculator-error (list ":units needs an expression"))
         (cmacs-calculator-repl--units argument)))
      (":list" (cmacs-calculator-repl--list
                (if (string-empty-p argument) nil argument)))
      (_ (signal 'cmacs-calculator-error
                 (list (format "unknown command `%s'; try :help" command)))))))


;;; Shared core

(defun cmacs-calculator-repl--handle (line)
  "Evaluate LINE and return what to print: a string, `quit', or nil.

Nil means the line was blank and there is nothing to say.  Errors are
returned as an \"error: ...\" string rather than signalled: this is the
single point that guarantees a bad line cannot kill either REPL."
  (let ((line (string-trim line)))
    (cond
     ((string-empty-p line) nil)
     (t
      (condition-case err
          (if (string-prefix-p ":" line)
              (cmacs-calculator-repl--meta line)
            (cmacs-calculator-eval line))
        (quit "error: interrupted")
        (error (concat "error: " (cmacs-calculator-error-message err))))))))


;;; Batch REPL

(defun cmacs-calculator-repl--read-line ()
  "Read one line from stdin, or return nil at end of file.
`read-string' prints the prompt on stdout in batch and signals
`end-of-file' when stdin runs out, which is a clean exit rather than a
failure."
  (condition-case nil
      (read-string cmacs-calculator-repl-prompt)
    (end-of-file nil)
    ;; A tty user pressing C-c gets `quit'; treat it as end of input rather
    ;; than letting it escape as a backtrace.
    (quit nil)))

;;;###autoload
(defun cmacs-calculator-repl ()
  "Run the calculator REPL over stdin and stdout.

This is the batch loop behind `emacs --calc'.  It works with a tty and
with piped stdin alike, prompts with `cmacs-calculator-repl-prompt',
prints one result per line, and exits cleanly at end of input or on
`:quit'.  A line that fails prints \"error: MESSAGE\" and the loop
continues.

Use `cmacs-calculator-repl-buffer' inside a running Emacs; this loop
owns stdin and would block the editor."
  (interactive)
  (when (and (not noninteractive) (called-interactively-p 'interactive))
    (user-error "This is the batch loop; use `cmacs-calculator-repl-buffer'"))
  (let ((running t))
    (while running
      (let ((line (cmacs-calculator-repl--read-line)))
        (if (null line)
            ;; End of file: newline so a tty session's shell prompt starts
            ;; on a fresh line.
            (progn (princ "\n") (setq running nil))
          (let ((output (cmacs-calculator-repl--handle line)))
            (cond
             ((eq output 'quit) (setq running nil))
             ((null output) nil)
             (t (princ output) (princ "\n")))))))))

;;;###autoload
(defun cmacs-calculator-cli (expr)
  "Evaluate EXPR, print the result, and return it.

The one-shot behind `emacs --calc \"2+2\"'.  Prints \"error: MESSAGE\"
on bad input rather than signalling, so a shell caller sees a sentence
instead of a backtrace."
  (let ((output (cmacs-calculator-repl--handle expr)))
    (when (and output (not (eq output 'quit)))
      (princ output)
      (princ "\n")
      output)))


;;; Interactive REPL buffer
;;
;; Deliberately not comint: comint needs a live subprocess to anchor input
;; (ielm famously starts a `hexl' it never speaks to), and there is no process
;; here -- evaluation is a Lisp call.  Rather than spawn a decoy, this is a
;; small prompt-and-history buffer with comint's keys.

(defvar-local cmacs-calculator-repl--prompt-end nil
  "Marker at the end of the last prompt; input starts here.")

(defvar-local cmacs-calculator-repl--history nil
  "Input history for this REPL buffer, most recent first.")

(defvar-local cmacs-calculator-repl--history-index nil
  "Position in `cmacs-calculator-repl--history' while browsing it.")

(defun cmacs-calculator-repl--insert-prompt ()
  "Insert a prompt at the end of the REPL buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (propertize cmacs-calculator-repl-prompt
                        'read-only t
                        'rear-nonsticky t
                        'front-sticky '(read-only)
                        'field 'prompt
                        'face 'cmacs-calculator-repl-prompt-face))
    (setq cmacs-calculator-repl--prompt-end (point-max-marker))
    (set-marker-insertion-type cmacs-calculator-repl--prompt-end nil)
    (goto-char (point-max))))

(defun cmacs-calculator-repl--current-input ()
  "Return the text typed after the current prompt."
  (if (and cmacs-calculator-repl--prompt-end
           (marker-position cmacs-calculator-repl--prompt-end))
      (buffer-substring-no-properties cmacs-calculator-repl--prompt-end
                                      (point-max))
    ""))

(defun cmacs-calculator-repl--replace-input (text)
  "Replace the text after the prompt with TEXT."
  (let ((inhibit-read-only t))
    (delete-region cmacs-calculator-repl--prompt-end (point-max))
    (goto-char (point-max))
    (insert text)))

(defun cmacs-calculator-repl-send-input ()
  "Evaluate the input after the prompt and print the result."
  (interactive)
  (let ((input (string-trim (cmacs-calculator-repl--current-input)))
        (inhibit-read-only t))
    (goto-char (point-max))
    (insert "\n")
    (unless (string-empty-p input)
      (push input cmacs-calculator-repl--history))
    (setq cmacs-calculator-repl--history-index nil)
    (let ((output (cmacs-calculator-repl--handle input)))
      (cond
       ((eq output 'quit)
        (insert "Use `q' or kill the buffer to leave.\n"))
       ((null output) nil)
       (t (insert (propertize output 'face
                              (if (string-prefix-p "error: " output)
                                  'cmacs-calculator-sheet-error-face
                                'cmacs-calculator-sheet-result-face))
                  "\n"))))
    (cmacs-calculator-repl--insert-prompt)))

(defun cmacs-calculator-repl--browse-history (delta)
  "Move DELTA steps through the input history and show the entry."
  (let* ((history cmacs-calculator-repl--history)
         (length (length history)))
    (when (zerop length) (user-error "No history"))
    (let ((index (cond ((null cmacs-calculator-repl--history-index)
                        (if (> delta 0) 0 (user-error "End of history")))
                       (t (+ cmacs-calculator-repl--history-index delta)))))
      (cond
       ((< index 0)
        (setq cmacs-calculator-repl--history-index nil)
        (cmacs-calculator-repl--replace-input ""))
       ((>= index length) (user-error "Beginning of history"))
       (t
        (setq cmacs-calculator-repl--history-index index)
        (cmacs-calculator-repl--replace-input (nth index history)))))))

(defun cmacs-calculator-repl-previous-input ()
  "Insert the previous history entry at the prompt."
  (interactive)
  (cmacs-calculator-repl--browse-history 1))

(defun cmacs-calculator-repl-next-input ()
  "Insert the next history entry at the prompt."
  (interactive)
  (cmacs-calculator-repl--browse-history -1))

(defun cmacs-calculator-repl-beginning-of-line ()
  "Move to the start of the input, after the prompt."
  (interactive)
  (if (and cmacs-calculator-repl--prompt-end
           (>= (point) cmacs-calculator-repl--prompt-end))
      (goto-char cmacs-calculator-repl--prompt-end)
    (beginning-of-line)))

(defun cmacs-calculator-repl-clear ()
  "Erase the REPL buffer, keeping the prompt and the history."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (cmacs-calculator-repl--insert-prompt)))

(defvar cmacs-calculator-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-calculator-repl-send-input)
    (define-key map (kbd "M-p") #'cmacs-calculator-repl-previous-input)
    (define-key map (kbd "M-n") #'cmacs-calculator-repl-next-input)
    (define-key map (kbd "C-a") #'cmacs-calculator-repl-beginning-of-line)
    (define-key map (kbd "C-c M-o") #'cmacs-calculator-repl-clear)
    map)
  "Keymap for `cmacs-calculator-repl-mode'.")

(define-derived-mode cmacs-calculator-repl-mode fundamental-mode "Calc-REPL"
  "Major mode for the interactive calculator REPL buffer.

Type an expression and press RET.  \\[cmacs-calculator-repl-previous-input]
and \\[cmacs-calculator-repl-next-input] browse the input history.  The
meta-commands are the batch REPL's; `:help' lists them.

\\{cmacs-calculator-repl-mode-map}"
  ;; Lazy on purpose: this is the interactive path, so the sheet's
  ;; completion, eldoc and faces are worth loading here and nowhere near the
  ;; batch loop.
  (require 'cmacs-calculator-sheet)
  (setq-local comment-start "# ")
  (add-hook 'completion-at-point-functions
            #'cmacs-calculator-sheet--capf nil t)
  (add-hook 'eldoc-documentation-functions
            #'cmacs-calculator-sheet--eldoc nil t))

;;;###autoload
(defun cmacs-calculator-repl-buffer ()
  "Open the interactive calculator REPL buffer.

The batch `cmacs-calculator-repl' cannot run inside a live Emacs -- it
reads stdin -- so this is the in-editor equivalent, over the same
evaluation core and the same meta-commands."
  (interactive)
  (let ((buffer (get-buffer-create cmacs-calculator-repl-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-calculator-repl-mode)
        (cmacs-calculator-repl-mode)
        (let ((inhibit-read-only t))
          (insert (substitute-command-keys
                   (concat "CMacs calculator.  Type an expression and press RET;"
                           " `:help' for commands.\n")))
          (cmacs-calculator-repl--insert-prompt))))
    (pop-to-buffer buffer)
    (goto-char (point-max))
    buffer))

(provide 'cmacs-calculator-repl)
;;; cmacs-calculator-repl.el ends here
