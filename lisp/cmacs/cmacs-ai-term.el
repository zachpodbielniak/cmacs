;;; cmacs-ai-term.el --- AI actions for terminals and shells  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A Terminal group, in vterm, eshell, term, comint shells, the cmacs
;; REPLs, and bacon.
;;
;; What earns this a group is the destination.  Everywhere else in the
;; menu the answer is prose you read; here the useful answer is a command
;; line, and the useful place for it is your prompt.  So the result
;; window gains one key -- `C-c C-i' -- that sends the answer back to the
;; terminal it came from.
;;
;; It is SENT, not RUN.  The text lands at your prompt and stops; you
;; read it and press RET yourself, or edit it first, or delete it.  A
;; menu that could execute a shell command it had just invented would be
;; the single most dangerous thing in this whole feature.
;;
;; Bacon needs saying explicitly.  `M-x bacon' runs `cmacs --bacon'
;; inside vterm, so a bacon buffer IS a vterm buffer -- there is no
;; `cmacs-bacon-mode', and an earlier version of the terminal resolver
;; listed one that never existed.  Bacon is recognised by its buffer name
;; instead, and the prompts are told which shell they are looking at,
;; because advice about bash builtins is wrong in bacon and vice versa.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-actions)
(require 'cmacs-ai-output)

(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function eshell-bol "esh-mode" ())
(defvar bacon-buffer-name)
(defvar eshell-last-output-end)

(defgroup cmacs-ai-term nil
  "AI actions for terminal and shell buffers."
  :group 'cmacs-ai
  :prefix "cmacs-ai-term-")

;;;; Which shell is this? ------------------------------------------------

(defun cmacs-ai-term-bacon-buffer-p (&optional buffer)
  "Non-nil when BUFFER is a bacon shell.

Bacon runs inside vterm, so there is no major mode to test: `M-x bacon'
binds `vterm-buffer-name' to `bacon-buffer-name' and launches
`cmacs --bacon' there.  The buffer name is what identifies it."
  (with-current-buffer (or buffer (current-buffer))
    (let ((name (buffer-name))
          (bacon (or (and (boundp 'bacon-buffer-name) bacon-buffer-name)
                     "*bacon*")))
      (and name
           (or (equal name bacon)
               ;; vterm uniquifies duplicates as "*bacon*<2>".
               (string-prefix-p (concat bacon "<") name))
           t))))

(defun cmacs-ai-term-shell-name (&optional buffer)
  "A human name for the shell in BUFFER, for prompts."
  (with-current-buffer (or buffer (current-buffer))
    (cond
     ((cmacs-ai-term-bacon-buffer-p) "bacon")
     ((derived-mode-p 'eshell-mode) "eshell")
     ((derived-mode-p 'crispy-repl-mode) "the crispy REPL")
     ((derived-mode-p 'cmacs-podomation-repl-mode) "the podomation REPL")
     ((derived-mode-p 'cmacs-c-jit-repl-mode) "the cmacs C JIT REPL")
     ((derived-mode-p 'cmacs-calculator-repl-mode) "the cmacs calculator REPL")
     ((derived-mode-p 'vterm-mode 'term-mode 'shell-mode 'comint-mode)
      "a POSIX shell")
     (t "a shell"))))

(defun cmacs-ai-term--dialect-note (buffer)
  "A line telling the model what it is actually looking at."
  (with-current-buffer buffer
    (cond
     ((cmacs-ai-term-bacon-buffer-p)
      "This is BACON, the shell embedded in cmacs -- not bash.  It is a
POSIX-style shell with its own builtins, and it can evaluate Emacs Lisp
and drive the editor.  Do not suggest bash-specific syntax or bashisms
without saying that is what they are, and do not assume a bash builtin
exists here.")
     ((derived-mode-p 'eshell-mode)
      "This is eshell, Emacs's own shell -- not bash.  Elisp functions
are callable as commands, and many external tools are shadowed by Emacs
implementations.  Prefer eshell-idiomatic answers.")
     ((derived-mode-p 'crispy-repl-mode)
      "This is the crispy REPL: a C-like GObject scripting language
embedded in cmacs, not a shell.")
     ((derived-mode-p 'cmacs-calculator-repl-mode)
      "This is the cmacs calculator REPL, built on GNU Calc.")
     (t ""))))

;;;; System prompts ------------------------------------------------------

(defcustom cmacs-ai-term-explain-system-prompt
  "You explain what happened in a terminal session.
Use Org-mode markup.

Lead with one line: what failed, or what the output is telling the
reader.  Then why, referring to the actual command and its output.  Then
what to do about it, if that is not already obvious.

Assume competence: do not explain what `cd' is.  Spend the words on the
part that is surprising -- an exit status that does not match the
message, an error from a wrapper rather than the tool, a path that is
not what the reader thinks it is."
  "System prompt for `cmacs-ai-term-explain'."
  :type 'string)

(defcustom cmacs-ai-term-fix-system-prompt
  "You repair a command line that did not do what its author wanted.

Output the corrected command ALONE on the first line, with no prompt
character, no code fence and no commentary.  Then a blank line, then at
most two lines saying what was wrong.

The first line is pasted verbatim into a live shell prompt, so it must
be exactly one runnable command and nothing else.

If the command cannot be repaired without information you were not given
-- a filename, a host, which of several tools is meant -- put a clearly
bogus placeholder in capitals like FIXME-PATH rather than inventing a
plausible value.  A guess that looks right is worse than a blank that
does not."
  "System prompt for `cmacs-ai-term-fix'."
  :type 'string)

(defcustom cmacs-ai-term-write-system-prompt
  "You write a shell command from a description of what is wanted.

Output the command ALONE on the first line, with no prompt character, no
code fence and no commentary.  Then a blank line, then at most three
lines explaining it -- the flags worth knowing, and anything it will do
that the description did not ask for.

The first line is pasted verbatim into a live shell prompt, so it must
be exactly one runnable command and nothing else.

Prefer the obvious tool over the clever one.  Where a command is
destructive or hard to undo, say so in the explanation and prefer a form
that shows what it WOULD do first -- a --dry-run, a bare `find' before
the `-delete'.  Use capitalised placeholders for anything you had to
invent."
  "System prompt for `cmacs-ai-term-write'."
  :type 'string)

;;;; Applicability -------------------------------------------------------

(defun cmacs-ai-term--available-p (target)
  "Non-nil when the Terminal actions apply to TARGET."
  (and (cmacs-ai-actions--ai-p)
       (eq (cmacs-ai-target-kind target) 'terminal)))

;;;; Sending an answer back to the prompt ---------------------------------

(defvar-local cmacs-ai-term--origin nil
  "The terminal buffer a result window was produced from.")

(defun cmacs-ai-term--send (buffer text)
  "Put TEXT at BUFFER's prompt without running it."
  (with-current-buffer buffer
    (cond
     ((derived-mode-p 'vterm-mode)
      (unless (fboundp 'vterm-send-string)
        (user-error "cmacs-ai: vterm is not loaded"))
      ;; PASTE-P, so a shell with bracketed paste treats it as pasted
      ;; text: no history expansion, and above all no newline.
      (vterm-send-string text t))
     ((derived-mode-p 'eshell-mode)
      (goto-char (point-max))
      (insert text))
     ((derived-mode-p 'comint-mode 'term-mode)
      (goto-char (point-max))
      (insert text))
     (t (user-error "cmacs-ai: do not know how to type into %s" major-mode)))
    (goto-char (point-max))))

(defun cmacs-ai-term--first-line (text)
  "The first non-empty line of TEXT -- the command, by contract."
  (seq-find (lambda (l) (not (string-empty-p (string-trim l))))
            (split-string (or text "") "\n")))

(defun cmacs-ai-term-send-to-terminal ()
  "Send this result's command to the terminal it came from.

Bound to \\`C-c C-i' in a result window produced by the Terminal
actions.  The command is put at the prompt and NOT run: you read it and
press RET yourself.  Only the first line is sent, which is why those
prompts are told to put the command there and nothing else."
  (interactive)
  (let* ((origin cmacs-ai-term--origin)
         (command (cmacs-ai-term--first-line
                   (buffer-substring-no-properties (point-min) (point-max)))))
    (unless (buffer-live-p origin)
      (user-error "cmacs-ai: that terminal is gone"))
    (unless command
      (user-error "cmacs-ai: nothing to send yet"))
    ;; Confirmed, because this types into a live shell.  It still does
    ;; not press RET.
    (when (y-or-n-p (format "Put at %s's prompt: %s ? "
                            (buffer-name origin) (string-trim command)))
      (cmacs-ai-term--send origin (string-trim command))
      (pop-to-buffer origin)
      (message "cmacs-ai: at the prompt -- not run.  Press RET yourself."))))

;;;; Running -------------------------------------------------------------

(defun cmacs-ai-term--run (title system target &optional extra sendable)
  "Stream SYSTEM over TARGET into a result window called TITLE.

EXTRA is appended to the user message.  With SENDABLE, the window can
send its first line back to the originating terminal."
  (let* ((buffer (cmacs-ai-target-buffer target))
         (dialect (cmacs-ai-term--dialect-note buffer))
         (prompt (concat
                  (format "Shell: %s\nWorking directory: %s\n"
                          (cmacs-ai-term-shell-name buffer)
                          (or (cmacs-ai-target-plist-get target :cwd) "?"))
                  (unless (string-empty-p dialect) (concat "\n" dialect "\n"))
                  "\nThe session:\n\n"
                  (cmacs-ai-target-content target)
                  (when extra (concat "\n\n" extra))))
         (out (cmacs-ai-textops-stream
               title (cmacs-ai-target-describe target) system prompt
               (lambda ()
                 (cmacs-ai-term--run title system target extra sendable)))))
    (when (and sendable (buffer-live-p out))
      (with-current-buffer out
        (setq cmacs-ai-term--origin buffer)
        (local-set-key (kbd "C-c C-i") #'cmacs-ai-term-send-to-terminal)))
    out))

;;;; Commands ------------------------------------------------------------

(defun cmacs-ai-term--target ()
  "The terminal session at point, or signal."
  (let ((target (cmacs-ai-target-at)))
    (unless (and target (eq (cmacs-ai-target-kind target) 'terminal))
      (user-error "cmacs-ai: not in a terminal buffer"))
    target))

;;;###autoload
(defun cmacs-ai-term-explain ()
  "Explain what just happened in this terminal."
  (interactive)
  (cmacs-ai-term--run "terminal" cmacs-ai-term-explain-system-prompt
                      (cmacs-ai-term--target)))

;;;###autoload
(defun cmacs-ai-term-fix ()
  "Repair the last command.  \\`C-c C-i' puts the result at your prompt."
  (interactive)
  (cmacs-ai-term--run "fix command" cmacs-ai-term-fix-system-prompt
                      (cmacs-ai-term--target) nil t))

;;;###autoload
(defun cmacs-ai-term-write (what)
  "Write a command doing WHAT.  \\`C-c C-i' puts it at your prompt."
  (interactive "sCommand to do what: ")
  (cmacs-ai-term--run "write command" cmacs-ai-term-write-system-prompt
                      (cmacs-ai-term--target)
                      (format "Write a command that does this: %s" what)
                      t))

;;;; Menu actions --------------------------------------------------------

(cmacs-ai-register-action
 :name 'cmacs-ai-term-explain
 :group 'terminal :order 10
 :label "Explain what happened"
 :help "The last command and its output"
 :applies #'cmacs-ai-term--available-p
 :run (lambda (target)
        (cmacs-ai-term--run "terminal"
                            cmacs-ai-term-explain-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-term-fix
 :group 'terminal :order 20
 :label "Fix this command"
 :help "C-c C-i in the result puts it at your prompt, unrun"
 :applies #'cmacs-ai-term--available-p
 :run (lambda (target)
        (cmacs-ai-term--run "fix command" cmacs-ai-term-fix-system-prompt
                            target nil t)))

(cmacs-ai-register-action
 :name 'cmacs-ai-term-write
 :group 'terminal :order 30
 :label "Write a command..."
 :help "Describe what you want; C-c C-i puts it at your prompt, unrun"
 :applies #'cmacs-ai-term--available-p
 :run (lambda (target)
        (let ((what (read-string "Command to do what: ")))
          (cmacs-ai-term--run "write command"
                              cmacs-ai-term-write-system-prompt target
                              (format "Write a command that does this: %s" what)
                              t))))

(provide 'cmacs-ai-term)

;;; cmacs-ai-term.el ends here
