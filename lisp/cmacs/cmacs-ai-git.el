;;; cmacs-ai-git.el --- AI actions for magit and diffs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A Git group on the AI menu, present only when you are looking at a
;; repository -- magit, a diff, a commit buffer.  The sibling of
;; cmacs-ai-mail.el, and for the same reason: the useful questions here
;; ("what would a reviewer say", "write the commit message") have no
;; vocabulary in the general groups.
;;
;; One rule this file exists to enforce: every :applies here is cheap and
;; SELF-CONTAINED.  The first version of the commit entry tested
;; `fboundp' on a private function in cmacs-ai-commit.el -- a file
;; nothing loads until an action runs -- so the entry was invisible in
;; every real session and visible only in a test that had required the
;; file first.  Predicates test `locate-dominating-file' and the major
;; mode, both of which need nothing loaded; :run does the requiring.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-actions)

(declare-function cmacs-ai-suggest-commit-message "cmacs-ai-commit" ())

(defgroup cmacs-ai-git nil
  "AI actions for magit, diffs and commit buffers."
  :group 'cmacs-ai
  :prefix "cmacs-ai-git-")

;;;; System prompts ------------------------------------------------------

(defcustom cmacs-ai-git-review-system-prompt
  "You review a diff the way a careful colleague would, before it lands.
Use Org-mode markup.  Report only things worth a comment, most serious
first, one line each with the file and what is wrong:

* Bugs and correctness
* Risk: data loss, security, performance, compatibility
* Worth a second look

Judge the change as written -- do not ask for tests, docs or renames as
a reflex, and do not restate what the diff plainly does.  Say so
explicitly, in one line, when the change looks fine; a review that
manufactures findings to look thorough is worse than no review."
  "System prompt for `cmacs-ai-git-review'."
  :type 'string)

(defcustom cmacs-ai-git-summary-system-prompt
  "You summarize a diff for people who will not read it.
Use Org-mode markup.  Lead with one line saying what the change does as
a whole.  Then the substance as a short bullet list, grouped by area,
naming anything a reader would need to act on: behaviour changes,
new or removed options, migrations, breaking changes.

Write for a release note or a merge-request description: what changed
and what it means for someone using this, not a file-by-file recital."
  "System prompt for `cmacs-ai-git-summary'."
  :type 'string)

(defcustom cmacs-ai-git-hunk-system-prompt
  "You explain a single diff hunk to someone who knows the language but
not this code.  Use Org-mode markup.  Say what the change does, what it
is for as far as the hunk shows, and anything subtle about it -- an
off-by-one, a changed default, a swapped condition.  Be brief.  Say
plainly if the hunk looks wrong."
  "System prompt for `cmacs-ai-git-hunk'."
  :type 'string)

;;;; Predicates ----------------------------------------------------------
;;
;; Cheap, and dependent on nothing being loaded.  See the Commentary.

(defun cmacs-ai-git--repo-p ()
  "Non-nil when this buffer sits inside a git worktree.

`locate-dominating-file', not `vc-root-dir': the latter goes through
`vc-deduce-backend', which needs `vc-mode', a file-visiting buffer or a
mode it recognises, and a magit-status buffer is none of the three."
  (and default-directory
       (locate-dominating-file default-directory ".git")
       t))

(defun cmacs-ai-git--vc-buffer-p ()
  "Non-nil in a magit, diff, vc or commit buffer."
  (or (derived-mode-p 'magit-status-mode 'magit-diff-mode 'magit-revision-mode
                      'magit-stash-mode 'magit-log-mode 'diff-mode
                      'vc-dir-mode 'vc-diff-mode 'log-edit-mode
                      'vc-git-log-edit-mode)
      (bound-and-true-p git-commit-mode)))

(defun cmacs-ai-git--available-p (target)
  "Non-nil when the Git actions apply to TARGET."
  (and (cmacs-ai-actions--ai-p)
       (buffer-live-p (cmacs-ai-target-buffer target))
       (with-current-buffer (cmacs-ai-target-buffer target)
         (and (cmacs-ai-git--vc-buffer-p) (cmacs-ai-git--repo-p)))))

(defcustom cmacs-ai-git-max-diff-bytes 32000
  "Maximum diff bytes sent to the model."
  :type 'integer
  :safe #'integerp)

;;;; Reading the diff ----------------------------------------------------
;;
;; Scope is explicit, because the default everywhere else -- "staged if
;; anything is staged" -- is right for a commit message and wrong for a
;; summary.  A summary of only what you happened to stage describes a
;; slice of your work and reads as though it described all of it.

(defun cmacs-ai-git--shell (cmd)
  "Run CMD in the repository root and return its output."
  (with-temp-buffer
    (let ((default-directory (or (locate-dominating-file default-directory ".git")
                                 default-directory)))
      (call-process-shell-command cmd nil t)
      (buffer-string))))

(defun cmacs-ai-git--has-head-p ()
  "Non-nil when the repository has at least one commit."
  (not (string-empty-p
        (string-trim (cmacs-ai-git--shell
                      "git rev-parse --verify --quiet HEAD")))))

(defun cmacs-ai-git--untracked ()
  "Names of untracked, non-ignored files."
  (seq-remove #'string-empty-p
              (split-string
               (cmacs-ai-git--shell "git ls-files --others --exclude-standard")
               "\n")))

(defun cmacs-ai-git--diff (scope)
  "Return (TEXT . LABEL) for SCOPE, one of `all\=' or `staged\='.

`all\=' is the working tree against HEAD -- staged and unstaged together,
which is what \"what have I changed\" means to a person looking at a magit
buffer.  Untracked files cannot appear in a diff at all, so they are
listed by name; a summary that silently omitted a whole new file would
be worse than one that mentions it without its contents.

In a repository with no commits yet there is no HEAD to diff against, so
the staged and unstaged diffs are concatenated instead."
  (let* ((staged-only (eq scope 'staged))
         (diff
          (cond
           (staged-only (cmacs-ai-git--shell "git diff --staged --no-color"))
           ((cmacs-ai-git--has-head-p)
            (cmacs-ai-git--shell "git diff HEAD --no-color"))
           (t (concat (cmacs-ai-git--shell "git diff --staged --no-color")
                      (cmacs-ai-git--shell "git diff --no-color")))))
         (untracked (unless staged-only (cmacs-ai-git--untracked))))
    (when (> (length diff) cmacs-ai-git-max-diff-bytes)
      (setq diff (concat (substring diff 0 cmacs-ai-git-max-diff-bytes)
                         "\n\n[diff truncated]")))
    (cons (concat diff
                  (when untracked
                    (concat "\n\nUntracked files (contents not shown):\n"
                            (mapconcat (lambda (f) (concat "  " f))
                                       untracked "\n"))))
          (if staged-only
              "staged changes only"
            "all changes: staged, unstaged and untracked"))))

(defun cmacs-ai-git--partially-staged-p ()
  "Non-nil when staging splits the work: something staged, something not.

The condition under which \"staged only\" is a different answer from \"all
changes\".  When it is false the two scopes produce identical output, and
offering both is noise."
  (and (not (string-empty-p
             (string-trim (cmacs-ai-git--shell
                           "git diff --staged --name-only"))))
       (or (not (string-empty-p
                 (string-trim (cmacs-ai-git--shell "git diff --name-only"))))
           (cmacs-ai-git--untracked))
       t))

(defun cmacs-ai-git--run-on-diff (title system scope)
  "Stream SYSTEM over the SCOPE diff into a result window called TITLE."
  (pcase-let* ((`(,diff . ,label) (cmacs-ai-git--diff scope)))
    (when (string-empty-p (string-trim diff))
      (user-error "cmacs-ai: no %s to look at"
                  (if (eq scope 'staged) "staged changes" "changes")))
    (cmacs-ai-textops-stream
     title label system
     (format "The %s in this repository:\n\n%s" label diff)
     (lambda () (cmacs-ai-git--run-on-diff title system scope)))))

;;;; Commands ------------------------------------------------------------

(defun cmacs-ai-git--ensure ()
  "Signal unless this buffer is inside a repository."
  (unless (cmacs-ai-git--repo-p)
    (user-error "cmacs-ai: not inside a git worktree")))

;;;###autoload
(defun cmacs-ai-git-review (&optional staged-only)
  "Review your changes the way a colleague would.

Everything you have changed by default -- staged, unstaged and the names
of untracked files.  With a prefix argument, STAGED-ONLY, look at just
what is staged."
  (interactive "P")
  (cmacs-ai-git--ensure)
  (cmacs-ai-git--run-on-diff "review" cmacs-ai-git-review-system-prompt
                             (if staged-only 'staged 'all)))

;;;###autoload
(defun cmacs-ai-git-summary (&optional staged-only)
  "Summarize your changes for a release note or merge request.

Everything you have changed by default: a summary of only what happened
to be staged describes a slice of the work and reads as though it
described all of it.  With a prefix argument, STAGED-ONLY, summarize
just the staged changes."
  (interactive "P")
  (cmacs-ai-git--ensure)
  (cmacs-ai-git--run-on-diff "change summary"
                             cmacs-ai-git-summary-system-prompt
                             (if staged-only 'staged 'all)))

;;;###autoload
(defun cmacs-ai-git-explain-hunk ()
  "Explain the diff hunk at point."
  (interactive)
  (let ((target (cmacs-ai-target-at)))
    (unless (and target (eq (cmacs-ai-target-kind target) 'hunk))
      (user-error "cmacs-ai: point is not on a diff hunk"))
    (cmacs-ai-textops-stream
     "hunk" (cmacs-ai-target-describe target)
     cmacs-ai-git-hunk-system-prompt
     (format "This diff hunk:\n\n%s" (cmacs-ai-target-content target))
     #'cmacs-ai-git-explain-hunk)))

;;;; Menu actions --------------------------------------------------------

(cmacs-ai-register-action
 :name 'cmacs-ai-git-commit
 :group 'git :order 10
 :label "Draft a commit message"
 :help "From the diff and this project's recent commit style"
 :applies #'cmacs-ai-git--available-p
 :run (lambda (target)
        (require 'cmacs-ai-commit)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-suggest-commit-message))))

(cmacs-ai-register-action
 :name 'cmacs-ai-git-review
 :group 'git :order 20
 :label "Review all changes"
 :help "Staged and unstaged together -- what a colleague would say"
 :applies #'cmacs-ai-git--available-p
 :run (lambda (target)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-git--run-on-diff
           "review" cmacs-ai-git-review-system-prompt 'all))))

(cmacs-ai-register-action
 :name 'cmacs-ai-git-summary
 :group 'git :order 30
 :label "Summarize all changes"
 :help "Staged, unstaged and untracked -- everything you have changed"
 :applies #'cmacs-ai-git--available-p
 :run (lambda (target)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-git--run-on-diff
           "change summary" cmacs-ai-git-summary-system-prompt 'all))))

;; The staged-only variants, offered only when staging actually splits
;; the work in two.  With nothing staged, or with everything staged, they
;; would say the same thing as the entries above and be pure noise.

(cmacs-ai-register-action
 :name 'cmacs-ai-git-summary-staged
 :group 'git :order 35
 :label "Summarize staged changes only"
 :applies (lambda (target)
            (and (cmacs-ai-git--available-p target)
                 (with-current-buffer (cmacs-ai-target-buffer target)
                   (cmacs-ai-git--partially-staged-p))))
 :run (lambda (target)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-git--run-on-diff
           "change summary" cmacs-ai-git-summary-system-prompt 'staged))))

(cmacs-ai-register-action
 :name 'cmacs-ai-git-review-staged
 :group 'git :order 25
 :label "Review staged changes only"
 :applies (lambda (target)
            (and (cmacs-ai-git--available-p target)
                 (with-current-buffer (cmacs-ai-target-buffer target)
                   (cmacs-ai-git--partially-staged-p))))
 :run (lambda (target)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-git--run-on-diff
           "review" cmacs-ai-git-review-system-prompt 'staged))))

(cmacs-ai-register-action
 :name 'cmacs-ai-git-hunk
 :group 'git :order 40
 :label "Explain this hunk"
 :applies (lambda (target)
            (and (cmacs-ai-git--available-p target)
                 (eq (cmacs-ai-target-kind target) 'hunk)))
 :run (lambda (target)
        (cmacs-ai-textops-stream
         "hunk" (cmacs-ai-target-describe target)
         cmacs-ai-git-hunk-system-prompt
         (format "This diff hunk:\n\n%s" (cmacs-ai-target-content target))
         nil)))

(provide 'cmacs-ai-git)

;;; cmacs-ai-git.el ends here
