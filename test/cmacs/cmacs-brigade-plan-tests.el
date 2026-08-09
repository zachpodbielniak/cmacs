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


;;;; Surviving a restart
;;
;; The runtime task table is a C hash that dies with the process; the
;; plans are org files that do not.  Nothing used to go looking for them,
;; so a fresh cmacs showed an empty dashboard while every task ever run
;; sat on disk unmentioned.

(defmacro cmacs-brigade-plan-tests--with-plan-dir (files &rest body)
  "Run BODY with `cmacs-brigade-plan-directory' holding FILES.
FILES is a list of (NAME . TEXT)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "cmacs-brigade-plans" t))
          (cmacs-brigade-plan-directory dir)
          (cmacs-brigade-plan--restored nil))
     (unwind-protect
         (progn
           (dolist (f ,files)
             (with-temp-file (expand-file-name (car f) dir)
               (insert (cdr f))))
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))

(defconst cmacs-brigade-plan-tests--finished-plan
  (concat "#+title: Old work\n"
          "#+TODO: TODO(t) NEXT(n) INPROGRESS(i) WAIT(w) HOLD(h) | \
DONE(d) FAILED(f) CANCELLED(c)\n\n"
          "* DONE Audit the config loader  :brigade:\n"
          "  :PROPERTIES:\n"
          "  :ID:  plan-restore-done\n"
          "  :AGENT: general\n"
          "  :BRIGADE-STATE: done\n"
          "  :BRIGADE-TURNS: 4\n"
          "  :BRIGADE-TOKENS: 1200/340\n"
          "  :BRIGADE-COST: 0.0250\n"
          "  :END:\n"
          "  Go and audit it.\n\n"
          "* INPROGRESS Was running when we quit  :brigade:\n"
          "  :PROPERTIES:\n"
          "  :ID:  plan-restore-live\n"
          "  :AGENT: general\n"
          "  :BRIGADE-STATE: running\n"
          "  :END:\n"
          "  Something long.\n")
  "A plan as it looks after a run, with state written back into it.")

(ert-deftest cmacs-brigade-plan-files-finds-plans-not-notes ()
  "Only org files with a brigade-tagged headline count as plans."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan-dir
      (list (cons "p.org" cmacs-brigade-plan-tests--finished-plan)
            (cons "notes.org" "#+title: Just notes\n* A heading\nText.\n")
            (cons "readme.txt" "not org at all\n"))
    (let ((files (cmacs-brigade-plan-files)))
      (should (= 1 (length files)))
      (should (equal "p.org" (file-name-nondirectory (car files)))))))

(ert-deftest cmacs-brigade-plan-restore-brings-back-state-and-figures ()
  "A finished task returns as finished, with its counters."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan-dir
      (list (cons "p.org" cmacs-brigade-plan-tests--finished-plan))
    (unwind-protect
        (progn
          (should (= 2 (cmacs-brigade-plan-restore)))
          (let ((r (cmacs-brigade-task-get "plan-restore-done")))
            (should (eq 'done (plist-get r :state)))
            (should (= 4 (plist-get r :turns)))
            (should (= 1200 (plist-get r :in-tokens)))
            (should (= 340 (plist-get r :out-tokens)))
            ;; Dollars in the file, integer micro-dollars in the runtime.
            (should (= 25000 (plist-get r :cost-micros)))))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-done"))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-live")))))

(ert-deftest cmacs-brigade-plan-restore-does-not-resurrect-live-states ()
  "A task that was running at exit comes back `interrupted'.

Nothing is running -- the process died with the editor -- and presenting
it as `running' would have the dashboard, the concurrency cap and the
notifier all believing in an agent that is not there."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan-dir
      (list (cons "p.org" cmacs-brigade-plan-tests--finished-plan))
    (unwind-protect
        (progn
          (cmacs-brigade-plan-restore)
          (should (eq 'interrupted
                      (plist-get (cmacs-brigade-task-get "plan-restore-live")
                                 :state))))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-done"))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-live")))))

(ert-deftest cmacs-brigade-plan-restore-does-not-rewrite-the-keyword ()
  "Restoring must not read DONE as a request to finish a fresh task.

Before the recorded state was restored first, adoption saw a brand-new
`draft' record, read the DONE keyword as a *command*, had it refused by
the state machine, and rewrote the headline back to TODO -- so reopening
cmacs destroyed the outcome the plan existed to record."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan-dir
      (list (cons "p.org" cmacs-brigade-plan-tests--finished-plan))
    (unwind-protect
        (progn
          (cmacs-brigade-plan-restore)
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "p.org" cmacs-brigade-plan-directory))
            (should (string-match-p "^\\* DONE Audit" (buffer-string)))))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-done"))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-live")))))

(ert-deftest cmacs-brigade-plan-restore-runs-once-unless-forced ()
  "Opening the dashboard repeatedly must not rescan the disk each time."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan-dir
      (list (cons "p.org" cmacs-brigade-plan-tests--finished-plan))
    (unwind-protect
        (progn
          (should (= 2 (cmacs-brigade-plan-restore)))
          (should (= 0 (cmacs-brigade-plan-restore)))
          (should (= 2 (cmacs-brigade-plan-restore t))))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-done"))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-live")))))

(ert-deftest cmacs-brigade-plan-restore-skips-a-truncated-plan ()
  "A plan with an unterminated drawer is skipped, and the others load.

Not merely tidiness: adopting such a file does not fail, it hangs --
somewhere inside org, writing an id into a drawer with no end.  Since
restore runs when the brigade loads, that turned one truncated file into
an editor that would not finish starting."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan-dir
      (list (cons "bad.org" "* TODO broken  :brigade:\n  :PROPERTIES:\n  :ID:\n")
            (cons "good.org" cmacs-brigade-plan-tests--finished-plan))
    (unwind-protect
        (progn
          (should (= 1 (length (cmacs-brigade-plan-files))))
          (cmacs-brigade-plan-restore)
          (should (cmacs-brigade-task-get "plan-restore-done")))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-done"))
      (ignore-errors (cmacs-brigade-task-forget "plan-restore-live")))))

(ert-deftest cmacs-brigade-plan-well-formed-detects-truncation ()
  "The structural check accepts intact drawers and rejects a truncated one."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (with-temp-buffer
    (insert "* A\n  :PROPERTIES:\n  :ID: x\n  :END:\n* B\n  :PROPERTIES:\n  :ID: y\n  :END:\n")
    (should (cmacs-brigade-plan--well-formed-p)))
  (with-temp-buffer
    (insert "* A\n  :PROPERTIES:\n  :ID: x\n  :END:\n* B\n  :PROPERTIES:\n  :ID: y\n")
    (should-not (cmacs-brigade-plan--well-formed-p)))
  (with-temp-buffer
    (insert "* A with no drawer at all\n  text\n")
    (should (cmacs-brigade-plan--well-formed-p))))

(ert-deftest cmacs-brigade-plan-render-writes-runtime-state-back ()
  "Runtime state reaches the plan file.

The render machinery existed in full and had no callers, so a plan never
learned what became of its tasks -- which is why nothing could be
restored from one."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (cmacs-brigade-plan-tests--with-plan
      "* TODO Do the thing  :brigade:\n  :PROPERTIES:\n  :ID: render-back-1\n  :AGENT: general\n  :END:\n  Body.\n"
    (unwind-protect
        (progn
          (cmacs-brigade-plan-adopt)
          (cmacs-brigade-task-transition "render-back-1" 'queued)
          (cmacs-brigade-plan-render
           (buffer-file-name)
           (list (cmacs-brigade-task-get "render-back-1")))
          ;; From the headline, not from `point-min': that is the
          ;; `#+title:' line, which is outside any entry, and
          ;; `org-entry-get' there answers about the file rather than
          ;; the task.
          (save-excursion
            (goto-char (point-min))
            (re-search-forward "^\\* ")
            (should (equal "queued" (org-entry-get nil "BRIGADE-STATE")))
            (should (equal "0/0" (org-entry-get nil "BRIGADE-TOKENS")))
            (should (equal "NEXT" (org-get-todo-state)))))
      (ignore-errors (cmacs-brigade-task-forget "render-back-1")))))

(ert-deftest cmacs-brigade-plan-transition-queues-a-render ()
  "Transitioning a task asks for its plan to be updated."
  (skip-unless (cmacs-brigade-plan-tests--available-p))
  (let ((seen nil))
    (cl-letf (((symbol-function 'cmacs-brigade-plan-queue-render)
               (lambda (plan records) (push (cons plan records) seen))))
      (cmacs-brigade-task-adopt "queue-render-1" "some-plan.org" "general" "t")
      (unwind-protect
          (progn
            (cmacs-brigade-task-transition "queue-render-1" 'queued)
            (should seen)
            (should (equal "some-plan.org" (car (car seen)))))
        (ignore-errors (cmacs-brigade-task-forget "queue-render-1"))))))
