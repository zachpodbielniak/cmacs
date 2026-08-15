;;; cmacs-ai-commit.el --- AI-suggested commit messages  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Draft a commit message from the diff, in the project's own voice.
;;
;; Two inputs, and the second is what makes it useful: the diff says
;; what changed, and the last N subject lines say how this project
;; writes about changes -- whether it uses scopes, how long its subjects
;; run, whether bodies explain why or just restate the diff.  A model
;; given both writes something that looks like it belongs; a model given
;; only the diff writes a generic summary of the patch.
;;
;; Conventional Commits is the default shape, but the log is shown last
;; and wins on style: if this project has never written `feat(scope):'
;; in its life, following its habits beats following the spec.
;;
;; Works from wherever you are.  In a commit buffer the message is
;; inserted at point, which is the whole point of being there.  Anywhere
;; else -- magit-status, a diff, a plain repo buffer -- it streams into a
;; result window you can read and copy from, because there is no commit
;; buffer yet to insert into.

;;; Code:

(require 'cmacs-ai)
(require 'cmacs-ai-output)

(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback))
(defvar cmacs-ai-textops-provider)
(defvar cmacs-ai-textops-model)

(defgroup cmacs-ai-commit nil
  "AI-drafted git commit messages."
  :group 'cmacs-ai
  :prefix "cmacs-ai-commit-")

(defcustom cmacs-ai-commit-log-lookback 30
  "Number of recent commits used as style reference.

The single most useful input after the diff itself.  Enough of them that
the model sees the project's habits rather than one author's last mood."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-commit-max-diff-bytes 32000
  "Maximum diff bytes sent to the model."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-commit-conventional t
  "When non-nil, ask for Conventional Commits shape by default.

The spec is given as the default shape, then the recent log is shown
after it and declared to win on style.  A project that plainly does not
use Conventional Commits should not have them forced on it by a
default, and the log is the evidence for that."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-ai-commit-wrap-column 72
  "Column the body should wrap at.

72 is the portable answer.  Note cmacs's own commit hook rejects lines
of 78 or more, so this must stay under that for this repository."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-commit-extra-instructions ""
  "Extra instructions appended to the commit-message system prompt.
Project-specific rules that the log alone will not convey."
  :type 'string)

(defcustom cmacs-ai-commit-provider nil
  "Provider symbol for commit drafting.  nil means `cmacs-ai-textops-provider'."
  :type '(choice (const :tag "Same as the text operations" nil) symbol))

(defcustom cmacs-ai-commit-model nil
  "Model for commit drafting.  nil means `cmacs-ai-textops-model'."
  :type '(choice (const :tag "Same as the text operations" nil) string))

;;;; Reading the repository ---------------------------------------------

(defun cmacs-ai-commit--root ()
  "The git worktree root for this buffer, or nil.

Deliberately NOT `vc-root-dir'.  That goes through
`vc-deduce-backend', which needs `vc-mode', a file-visiting buffer, or a
mode it recognises -- and a magit-status buffer has none of the three,
so it answers nil in the one place this command is most wanted.
`locate-dominating-file' just looks for `.git', which is also correct
for worktrees and submodules, where it is a file rather than a
directory."
  (or (ignore-errors (vc-root-dir))
      (when-let* ((dir (locate-dominating-file default-directory ".git")))
        (expand-file-name dir))))

(defun cmacs-ai-commit--shell (cmd)
  "Run CMD in the repository root and return its output."
  (with-temp-buffer
    (let ((default-directory (or (cmacs-ai-commit--root) default-directory)))
      (call-process-shell-command cmd nil t)
      (buffer-string))))

(defun cmacs-ai-commit--diff ()
  "Return (DIFF . STAGED-P) for the change to describe.

Staged if there is anything staged -- that is what a commit message is
about.  Otherwise the unstaged diff, flagged, so the prompt can say so
rather than the command failing at someone staring at real changes."
  (let ((staged (cmacs-ai-commit--shell "git diff --staged --no-color")))
    (if (not (string-empty-p (string-trim staged)))
        (cons staged t)
      (cons (cmacs-ai-commit--shell "git diff --no-color") nil))))

(defun cmacs-ai-commit--log ()
  "Recent commit subjects, as a style reference."
  (cmacs-ai-commit--shell
   (format "git log --pretty=format:'%%s' -n %d"
           cmacs-ai-commit-log-lookback)))

;;;; The prompt ----------------------------------------------------------

(defun cmacs-ai-commit--system ()
  "The system prompt for commit drafting."
  (concat
   "You write git commit messages for this project.\n\n"
   (when cmacs-ai-commit-conventional
     (concat
      "Default to Conventional Commits:\n"
      "  <type>[optional scope]: <description>\n"
      "  types: feat fix docs style refactor perf test chore ci build\n"
      "  a `!' after the type or scope marks a breaking change\n\n"))
   (format
    "Subject line in the imperative mood, no trailing period, under 70
characters.  Then a blank line, then a body wrapped at %d columns
explaining WHY the change was made and anything non-obvious about how --
not a restatement of the diff, which the reader can already see.  Omit
the body entirely for a change that genuinely needs none.\n\n"
    cmacs-ai-commit-wrap-column)
   "The recent commits shown below are the authority on style: if they
use scopes, use scopes; if they never use a type prefix, do not invent
one; match their length and tone.  Where they and the instructions above
disagree, follow them.\n\n"
   "Output ONLY the commit message.  No quotes, no code fences, no
preamble, no explanation of your choices."
   (unless (string-empty-p (string-trim cmacs-ai-commit-extra-instructions))
     (concat "\n\n" cmacs-ai-commit-extra-instructions))))

(defun cmacs-ai-commit--prompt (diff staged log)
  "The user message: LOG for style, then DIFF (STAGED or not)."
  (format "Recent commits in this project, newest first (style reference):
%s

%s
%s

Write the commit message."
          log
          (if staged "Staged diff:" "Diff (NOT yet staged):")
          diff))

;;;; The command ---------------------------------------------------------

(defun cmacs-ai-commit--commit-buffer-p ()
  "Non-nil when this buffer is a commit-message buffer."
  (or (bound-and-true-p git-commit-mode)
      (derived-mode-p 'git-commit-mode 'vc-git-log-edit-mode 'log-edit-mode)
      (string-match-p "COMMIT_EDITMSG\\'" (or (buffer-file-name) ""))))

;;;###autoload
(defun cmacs-ai-suggest-commit-message ()
  "Draft a commit message from the diff and this project's history.

Reads the staged diff (or the unstaged one, clearly flagged, when
nothing is staged) together with the last
`cmacs-ai-commit-log-lookback' commit subjects, and drafts a message in
the project's own style -- Conventional Commits by default, per
`cmacs-ai-commit-conventional'.

In a commit-message buffer the result is inserted at point.  Anywhere
else -- magit-status, a diff, any buffer inside the repository -- it
streams into a result window to read and copy from, since there is no
commit buffer to insert into yet."
  (interactive)
  (cmacs-ai--ensure)
  (unless (cmacs-ai-commit--root)
    (user-error "cmacs-ai: not inside a git worktree"))
  (pcase-let* ((`(,diff . ,staged) (cmacs-ai-commit--diff)))
    (when (string-empty-p (string-trim diff))
      (user-error "cmacs-ai: nothing staged and nothing changed"))
    (when (> (length diff) cmacs-ai-commit-max-diff-bytes)
      (setq diff (concat (substring diff 0 cmacs-ai-commit-max-diff-bytes)
                         "\n\n[diff truncated]")))
    (let* ((prompt (cmacs-ai-commit--prompt diff staged (cmacs-ai-commit--log)))
           (pair (cmacs-ai-make-session
                  (or cmacs-ai-commit-provider cmacs-ai-textops-provider)
                  (or cmacs-ai-commit-model cmacs-ai-textops-model)
                  (cmacs-ai-commit--system)))
           (into-buffer (cmacs-ai-commit--commit-buffer-p)))
      (if into-buffer
          (cmacs-ai-commit--stream-to-point pair prompt staged)
        (cmacs-ai-commit--stream-to-window pair prompt staged)))))

(defun cmacs-ai-commit--stream-to-point (pair prompt staged)
  "Stream PAIR's answer to PROMPT and insert it at point when it finishes.

Accumulated and inserted in one go rather than streamed into the buffer:
a commit buffer is a buffer you are editing, and text arriving under
your cursor in pieces makes a mess of both point and the undo history.
One insertion is one undo step."
  (let ((buffer (current-buffer))
        (marker (point-marker))
        (acc ""))
    (set-marker-insertion-type marker nil)
    (message "cmacs-ai: drafting a commit message%s..."
             (if staged "" " (from UNSTAGED changes)"))
    (cmacs-ai-chat-stream
     (cdr pair) prompt
     (lambda (payload)
       (pcase (car-safe payload)
         (:delta (setq acc (concat acc (or (cadr payload) ""))))
         (:end
          (let ((final (or (plist-get (cdr payload) :text) "")))
            (when (> (length (string-trim final)) (length (string-trim acc)))
              (setq acc final)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (save-excursion
                (goto-char marker)
                (insert (string-trim acc))
                (undo-boundary))))
          (ignore-errors (cmacs-ai-free-session pair))
          (message "cmacs-ai: commit message inserted"))
         (:error
          (ignore-errors (cmacs-ai-free-session pair))
          (message "cmacs-ai: commit draft failed: %s"
                   (or (cadr payload) "stream error"))))))))

(defun cmacs-ai-commit--stream-to-window (pair prompt staged)
  "Stream PAIR's answer to PROMPT into a result window."
  (let ((buf (cmacs-ai-output-buffer
              "commit message"
              (if staged "from the staged diff"
                "from UNSTAGED changes -- nothing is staged")))
        (streamed 0))
    (cmacs-ai-output-attach-session buf pair)
    (cmacs-ai-output-set-retry buf (lambda () (interactive)
                                     (cmacs-ai-suggest-commit-message)))
    (cmacs-ai-output-show buf)
    (cmacs-ai-chat-stream
     (cdr pair) prompt
     (lambda (payload)
       (pcase (car-safe payload)
         (:delta
          (let ((chunk (cadr payload)))
            (when chunk
              (setq streamed (+ streamed (length chunk)))
              (cmacs-ai-output-append buf chunk))))
         (:end
          (let ((final (plist-get (cdr payload) :text)))
            (when (and final (zerop streamed))
              (cmacs-ai-output-append buf final)))
          (cmacs-ai-output-finish buf nil))
         (:error
          (cmacs-ai-output-finish buf (or (cadr payload) "stream error"))))))))

(provide 'cmacs-ai-commit)
;;; cmacs-ai-commit.el ends here
