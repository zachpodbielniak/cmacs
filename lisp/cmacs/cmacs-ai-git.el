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
(declare-function cmacs-ai-commit--diff "cmacs-ai-commit" ())
(declare-function cmacs-ai-commit--log "cmacs-ai-commit" ())
;; The diff-size bound is shared with the commit drafter rather than
;; duplicated; cmacs-ai-commit.el is loaded before any use of it.
(defvar cmacs-ai-commit-max-diff-bytes)

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

;;;; Running -------------------------------------------------------------

(defun cmacs-ai-git--diff-text ()
  "The staged diff, or the unstaged one, as (TEXT . STAGED-P).
Loads cmacs-ai-commit on demand -- this runs from an action, never from
a predicate."
  (require 'cmacs-ai-commit)
  (cmacs-ai-commit--diff))

(defun cmacs-ai-git--run-on-diff (title system)
  "Stream SYSTEM over the current diff into a result window called TITLE."
  (pcase-let* ((`(,diff . ,staged) (cmacs-ai-git--diff-text)))
    (when (string-empty-p (string-trim diff))
      (user-error "cmacs-ai: nothing staged and nothing changed"))
    (when (> (length diff) cmacs-ai-commit-max-diff-bytes)
      (setq diff (concat (substring diff 0 cmacs-ai-commit-max-diff-bytes)
                         "\n\n[diff truncated]")))
    (cmacs-ai-textops-stream
     title
     (if staged "the staged diff" "UNSTAGED changes -- nothing is staged")
     system
     (format "%s\n\n%s"
             (if staged "Staged diff:" "Diff (NOT yet staged):")
             diff)
     (lambda () (cmacs-ai-git--run-on-diff title system)))))

;;;; Commands ------------------------------------------------------------

(defun cmacs-ai-git--ensure ()
  "Signal unless this buffer is inside a repository."
  (unless (cmacs-ai-git--repo-p)
    (user-error "cmacs-ai: not inside a git worktree")))

;;;###autoload
(defun cmacs-ai-git-review ()
  "Review the staged changes the way a colleague would."
  (interactive)
  (cmacs-ai-git--ensure)
  (cmacs-ai-git--run-on-diff "review" cmacs-ai-git-review-system-prompt))

;;;###autoload
(defun cmacs-ai-git-summary ()
  "Summarize the staged changes for a release note or merge request."
  (interactive)
  (cmacs-ai-git--ensure)
  (cmacs-ai-git--run-on-diff "change summary"
                             cmacs-ai-git-summary-system-prompt))

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
 :label "Review these changes"
 :help "What a careful colleague would say before this lands"
 :applies #'cmacs-ai-git--available-p
 :run (lambda (target)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-git-review))))

(cmacs-ai-register-action
 :name 'cmacs-ai-git-summary
 :group 'git :order 30
 :label "Summarize the changes"
 :help "For a release note or a merge-request description"
 :applies #'cmacs-ai-git--available-p
 :run (lambda (target)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-ai-git-summary))))

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
