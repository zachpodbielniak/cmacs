;;; cmacs-brigade-plan-tests.el --- Plan model tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The plan layer is where drift would live, so these lean on properties
;; rather than examples: adopt/render idempotence, keyword refusal, and
;; the cases that only show up when a human is in the middle of editing
;; the same buffer the runtime wants to write to.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-plan nil 'noerror)
(require 'cmacs-brigade-agent-def nil 'noerror)
(require 'cmacs-brigade-run nil 'noerror)

(defun cmacs-brigade-plan-tests--available-p ()
  (and (featurep 'cmacs-brigade-plan)
       (fboundp 'cmacs-brigade-task-adopt)))

(defmacro cmacs-brigade-plan-tests--with-plan (body-text &rest body)
  "Create a plan file containing BODY-TEXT, visit it, and run BODY.
Binds FILE and BUF."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "cmacs-brigade-plan" t))
          (file (expand-file-name "plan.org" dir))
          buf)
     (unwind-protect
         (progn
           (with-temp-file file
             (insert "#+title: Test\n" cmacs-brigade-plan-todo-line "\n\n"
                     ,body-text))
           (setq buf (find-file-noselect file))
           (with-current-buffer buf ,@body))
       (when (buffer-live-p buf)
         (with-current-buffer buf (set-buffer-modified-p nil))
         (kill-buffer buf))
       (delete-directory dir t))))

(defconst cmacs-brigade-plan-tests--one-task
  "* TODO Do the thing                                     :brigade:
  :PROPERTIES:
  :AGENT: researcher
  :END:
  The prompt body.
")


;;;; Agent definitions

(ert-deftest cmacs-brigade-agent-frontmatter ()
  "Frontmatter parses into a definition with defaults filled in."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (let ((def (cmacs-brigade-agent--from-text
              "---\nname: r\nmodel: m\ntools: [a, b]\nbudget-usd: 0.25\nisolation: worktree\n---\nPrompt here.\n"
              "r.md")))
    (should (eq 'r (plist-get def :name)))
    (should (equal '("a" "b") (plist-get def :tools)))
    (should (equal 0.25 (plist-get def :budget-usd)))
    (should (eq 'worktree (plist-get def :isolation)))
    (should (equal "Prompt here." (plist-get def :prompt)))
    ;; defaults apply where the file is silent
    (should (plist-get def :max-turns))
    ;; No worker unless the definition names one: the resolver picks
    ;; from the provider instead, so a claude-code model does not end up
    ;; in the in-process loop where its tools would be dropped.
    (should (null (plist-get def :worker)))
    (should (eq 'inproc (cmacs-brigade-resolve-worker def)))))

(ert-deftest cmacs-brigade-agent-keeps-unknown-keys ()
  "A key the parser does not recognise is carried, not discarded.

Whoever added it is presumably using it; refusing or dropping it would
make the format hostile to the experimentation it exists to support."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (let ((def (cmacs-brigade-agent--from-text
              "---\nname: r\nsome-future-key: 42\n---\nP\n" "r.md")))
    (should (equal 42 (alist-get 'some-future-key (plist-get def :extra))))))

(ert-deftest cmacs-brigade-agent-without-frontmatter ()
  "A plain markdown file still yields a usable agent.

This is the ~/.claude/agents import path: those files have no
frontmatter, and rejecting them would make the search path advertise
more than it delivers."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (let ((def (cmacs-brigade-agent--from-text "Just a prompt.\n" "/x/helper.md")))
    (should (eq 'helper (plist-get def :name)))
    (should (equal "Just a prompt." (plist-get def :prompt)))))

(ert-deftest cmacs-brigade-agent-block-lists ()
  "Both inline and block YAML list syntax parse."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (let ((def (cmacs-brigade-agent--from-text
              "---\nname: r\ntools:\n  - alpha\n  - beta\n---\nP\n" "r.md")))
    (should (equal '("alpha" "beta") (plist-get def :tools)))))

(ert-deftest cmacs-brigade-agent-allowlist-is-wire-names ()
  "An agent's tool list converts to snake_case for the C gate."
  (skip-unless (featurep 'cmacs-brigade-agent-def))
  (let ((def (cmacs-brigade-agent--from-text
              "---\nname: r\ntools: [call-for-me, memory]\n---\nP\n" "r.md")))
    (should (equal "call_for_me,memory" (cmacs-brigade-agent-allowlist def)))))


;;;; State machine

(ert-deftest cmacs-brigade-state-transitions-legal ()
  "The machine permits the moves a run actually makes."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (should (cmacs-brigade-state-can-transition-p 'draft 'queued))
  (should (cmacs-brigade-state-can-transition-p 'queued 'starting))
  (should (cmacs-brigade-state-can-transition-p 'starting 'running))
  (should (cmacs-brigade-state-can-transition-p 'running 'waiting-input))
  (should (cmacs-brigade-state-can-transition-p 'waiting-input 'running))
  (should (cmacs-brigade-state-can-transition-p 'running 'done))
  (should (cmacs-brigade-state-can-transition-p 'running 'over-budget))
  ;; retry from any terminal state
  (dolist (s '(done failed cancelled over-budget interrupted))
    (should (cmacs-brigade-state-can-transition-p s 'queued))))

(ert-deftest cmacs-brigade-state-transitions-refused ()
  "The machine refuses the moves that would lose track of a live agent."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  ;; unqueueing something that is already running would orphan it
  (should-not (cmacs-brigade-state-can-transition-p 'running 'draft))
  (should-not (cmacs-brigade-state-can-transition-p 'running 'queued))
  ;; a draft has not run, so it cannot have finished
  (should-not (cmacs-brigade-state-can-transition-p 'draft 'done))
  (should-not (cmacs-brigade-state-can-transition-p 'draft 'running))
  ;; nothing resumes from interrupted: nobody watched it stop
  (should-not (cmacs-brigade-state-can-transition-p 'interrupted 'running)))

(ert-deftest cmacs-brigade-state-cancel-always-available ()
  "A user who wants to stop an agent is never told they may not."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (dolist (s '(draft queued starting running waiting-input blocked))
    (should (cmacs-brigade-state-can-transition-p s 'cancelled))))

(ert-deftest cmacs-brigade-task-lifecycle ()
  "Adopt, transition, record progress, and forget."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (let ((id (format "test-%s" (random 100000))))
    (unwind-protect
        (progn
          (let ((rec (cmacs-brigade-task-adopt id "p.org" "researcher")))
            (should (eq 'draft (plist-get rec :state)))
            (should (equal "researcher" (plist-get rec :agent))))
          ;; adopting twice does not reset runtime state
          (cmacs-brigade-task-transition id 'queued)
          (should (eq 'queued (plist-get (cmacs-brigade-task-adopt id "p.org" nil)
                                         :state)))
          (cmacs-brigade-task-transition id 'starting)
          (cmacs-brigade-task-transition id 'running)
          (let ((rec (cmacs-brigade-task-progress id 3 100 50 1234)))
            (should (= 3 (plist-get rec :turns)))
            (should (= 1234 (plist-get rec :cost-micros))))
          ;; a start timestamp appears exactly once running
          (should (> (plist-get (cmacs-brigade-task-get id) :started-at) 0))
          (let ((res (cmacs-brigade-task-transition id 'draft)))
            (should (plist-get res :rejected))
            (should (string-match-p "running" (plist-get res :reason))))
          (cmacs-brigade-task-transition id 'done)
          (should (> (plist-get (cmacs-brigade-task-get id) :ended-at) 0)))
      (cmacs-brigade-task-forget id))))

(ert-deftest cmacs-brigade-task-retry-clears-outcome ()
  "Requeuing clears the previous run's error and end time.

Leaving them would make a fresh failure indistinguishable from a stale
one, which is exactly when someone stops trusting the display."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (let ((id (format "test-%s" (random 100000))))
    (unwind-protect
        (progn
          (cmacs-brigade-task-adopt id "p.org" nil)
          (cmacs-brigade-task-transition id 'queued)
          (cmacs-brigade-task-transition id 'starting)
          (cmacs-brigade-task-transition id 'failed "it broke")
          (should (equal "it broke" (plist-get (cmacs-brigade-task-get id) :error)))
          (cmacs-brigade-task-transition id 'queued)
          (let ((rec (cmacs-brigade-task-get id)))
            (should-not (plist-get rec :error))
            (should (= 0 (plist-get rec :ended-at)))))
      (cmacs-brigade-task-forget id))))

(ert-deftest cmacs-brigade-state-interrupt-on-restart ()
  "Live tasks become interrupted, and interrupted never auto-resumes."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (let ((id (format "test-%s" (random 100000))))
    (unwind-protect
        (progn
          (cmacs-brigade-task-adopt id "p.org" nil)
          (cmacs-brigade-task-transition id 'queued)
          (cmacs-brigade-task-transition id 'starting)
          (cmacs-brigade-task-transition id 'running)
          (should (>= (cmacs-brigade-state-interrupt-live) 1))
          (should (eq 'interrupted (plist-get (cmacs-brigade-task-get id) :state)))
          ;; only retry or abandon; resuming would pretend someone was
          ;; watching when the agent stopped
          (should (plist-get (cmacs-brigade-task-transition id 'running) :rejected)))
      (cmacs-brigade-task-forget id))))


;;;; Plan round trip

(ert-deftest cmacs-brigade-plan-adopt-only-tasks ()
  "Prose headlines are not tasks.

A plan file is still an org file; putting a runtime record behind every
heading someone wrote would make the dashboard meaningless."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan
      (concat cmacs-brigade-plan-tests--one-task
              "* Just some prose\n  Not a task at all.\n"
              "* Tagged task                                          :brigade:\n  Body.\n")
    (let ((res (cmacs-brigade-plan-adopt)))
      ;; the :AGENT: one and the :brigade:-tagged one, not the prose
      (should (= 2 (length res)))
      (dolist (r res) (cmacs-brigade-task-forget (plist-get r :id))))))

(ert-deftest cmacs-brigade-plan-adopt-is-idempotent ()
  "Adopting twice yields the same ids and the same states."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan cmacs-brigade-plan-tests--one-task
    (let* ((a (cmacs-brigade-plan-adopt))
           (b (cmacs-brigade-plan-adopt))
           (c (cmacs-brigade-plan-adopt)))
      (should (equal (mapcar (lambda (r) (plist-get r :id)) a)
                     (mapcar (lambda (r) (plist-get r :id)) b)))
      (should (equal b c))
      (dolist (r a) (cmacs-brigade-task-forget (plist-get r :id))))))

(ert-deftest cmacs-brigade-plan-render-is-idempotent ()
  "Rendering the same record twice leaves the buffer byte-identical."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan cmacs-brigade-plan-tests--one-task
    (let* ((res (cmacs-brigade-plan-adopt))
           (id (plist-get (car res) :id)))
      (unwind-protect
          (progn
            (cmacs-brigade-task-transition id 'queued)
            (cmacs-brigade-task-transition id 'starting)
            (cmacs-brigade-task-transition id 'running)
            (cmacs-brigade-task-progress id 2 10 5 999)
            (let ((rec (cmacs-brigade-task-get id)))
              (cmacs-brigade-plan-render file (list rec))
              (let ((first (buffer-string)))
                (cmacs-brigade-plan-render file (list rec))
                (should (equal first (buffer-string))))))
        (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-plan-duplicate-ids-get-fresh-ones ()
  "A copied subtree becomes a second task, not a second view of one.

Copying a subtree brings its :ID: along, and this happens constantly.
Two headlines sharing one runtime record would show one agent's progress
in two places."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan
      (concat "* TODO A                                               :brigade:\n"
              "  :PROPERTIES:\n  :ID: duplicated-id\n  :END:\n  Body.\n"
              "* TODO B                                               :brigade:\n"
              "  :PROPERTIES:\n  :ID: duplicated-id\n  :END:\n  Body.\n")
    (let* ((res (cmacs-brigade-plan-adopt))
           (ids (mapcar (lambda (r) (plist-get r :id)) res)))
      (should (= 2 (length ids)))
      (should-not (equal (nth 0 ids) (nth 1 ids)))
      (dolist (i ids) (cmacs-brigade-task-forget i)))))

(ert-deftest cmacs-brigade-plan-rejects-illegal-keyword ()
  "A refused keyword change is restored, with a reason.

Leaving the keyword where the human put it would display a state the
task is not in, which is worse than declining the edit."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan cmacs-brigade-plan-tests--one-task
    (let* ((res (cmacs-brigade-plan-adopt))
           (id (plist-get (car res) :id)))
      (unwind-protect
          (progn
            (cmacs-brigade-task-transition id 'queued)
            (cmacs-brigade-task-transition id 'starting)
            (cmacs-brigade-task-transition id 'running)
            (goto-char (point-min))
            (re-search-forward "^\\* ")
            (let ((cmacs-brigade-plan--suppress t)) (org-todo "TODO"))
            (let ((r (cmacs-brigade-plan--adopt-entry id file)))
              (should (plist-get r :rejected))
              (should (string-match-p "running" (plist-get r :reason))))
            (should (equal "INPROGRESS" (org-get-todo-state))))
        (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-plan-refuses-stale-buffer ()
  "A file changed on disk is not written to.

Saving would discard whatever arrived from git or another machine, and
the runtime data is reconstructible while the user's edits are not."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan cmacs-brigade-plan-tests--one-task
    (let* ((res (cmacs-brigade-plan-adopt))
           (id (plist-get (car res) :id)))
      (unwind-protect
          (progn
            (save-buffer)
            ;; someone else edits the file
            (sleep-for 0.05)
            (let ((coding-system-for-write 'utf-8))
              (write-region "#+title: changed elsewhere\n" nil file nil 'silent))
            (should (= 0 (cmacs-brigade-plan-render file
                                                    (list (cmacs-brigade-task-get id))))))
        (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-plan-refuses-conflict-markers ()
  "A buffer mid-merge is not written to."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan cmacs-brigade-plan-tests--one-task
    (let* ((res (cmacs-brigade-plan-adopt))
           (id (plist-get (car res) :id)))
      (unwind-protect
          (progn
            (goto-char (point-min))
            (insert "<<<<<<< HEAD\n")
            (save-buffer)
            (should (= 0 (cmacs-brigade-plan-render file
                                                    (list (cmacs-brigade-task-get id))))))
        (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-plan-never-reorders ()
  "Rendering leaves headline order exactly as the human left it.

Order is human-owned, permanently.  Re-sorting someone's buffer under
them is the most destructive thing this code could do."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan
      (concat "* TODO Zebra                                           :brigade:\n  Body.\n"
              "* TODO Apple                                           :brigade:\n  Body.\n")
    (let* ((res (cmacs-brigade-plan-adopt))
           (ids (mapcar (lambda (r) (plist-get r :id)) res)))
      (unwind-protect
          (progn
            (dolist (i ids)
              (cmacs-brigade-task-transition i 'queued))
            (cmacs-brigade-plan-render
             file (mapcar #'cmacs-brigade-task-get ids))
            (goto-char (point-min))
            (should (re-search-forward "^\\* NEXT Zebra" nil t))
            (should (re-search-forward "^\\* NEXT Apple" nil t)))
        (dolist (i ids) (cmacs-brigade-task-forget i))))))

(ert-deftest cmacs-brigade-plan-lint-detects-drift ()
  "The lint reports a property that disagrees with the runtime."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan cmacs-brigade-plan-tests--one-task
    (let* ((res (cmacs-brigade-plan-adopt))
           (id (plist-get (car res) :id)))
      (unwind-protect
          (progn
            (cmacs-brigade-plan-render file (list (cmacs-brigade-task-get id)))
            (should-not (cmacs-brigade-plan-lint))
            ;; forge a disagreement the way a bad merge would
            (goto-char (point-min))
            (re-search-forward "^\\* ")
            (org-entry-put nil "BRIGADE-STATE" "running")
            (should (cmacs-brigade-plan-lint)))
        (cmacs-brigade-task-forget id)))))

(provide 'cmacs-brigade-plan-tests)

;;; cmacs-brigade-plan-tests.el ends here
