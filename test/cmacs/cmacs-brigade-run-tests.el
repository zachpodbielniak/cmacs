;;; cmacs-brigade-run-tests.el --- Host, isolation and dashboard  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-host nil 'noerror)
(require 'cmacs-brigade-isolation nil 'noerror)
(require 'cmacs-brigade-run nil 'noerror)
(require 'cmacs-brigade-agent-def nil 'noerror)
(require 'cmacs-brigade-dashboard nil 'noerror)

(defun cmacs-brigade-run-tests--available-p ()
  (and (featurep 'cmacs-brigade-run) (fboundp 'cmacs-brigade-task-adopt)))


;;;; Isolation

(ert-deftest cmacs-brigade-isolation-backends-registered ()
  "All three shipped backends go through the public registry."
  (skip-unless (featurep 'cmacs-brigade-isolation))
  (dolist (k '(none worktree podman))
    (should (cmacs-brigade-registry-get 'isolation k))
    (should (functionp (plist-get (cmacs-brigade-registry-get 'isolation k)
                                  :prepare)))))

(ert-deftest cmacs-brigade-isolation-none ()
  "The `none' backend runs in place and tears down to nothing."
  (skip-unless (featurep 'cmacs-brigade-isolation))
  (let ((p (cmacs-brigade-isolation-prepare 'none "t")))
    (should (plist-get p :cwd)))
  (cmacs-brigade-isolation-teardown 'none "t"))

(ert-deftest cmacs-brigade-isolation-worktree-round-trip ()
  "A worktree is created, and removed even when dirty.

`git worktree remove' refuses a dirty checkout by default, and an
agent's worktree is dirty by definition -- that is what it is for."
  (skip-unless (and (featurep 'cmacs-brigade-isolation) (executable-find "git")))
  (let* ((repo (make-temp-file "brigade-repo" t))
         (default-directory (file-name-as-directory repo))
         (cmacs-brigade-worktree-root (expand-file-name "wt" repo)))
    (unwind-protect
        (progn
          (call-process "git" nil nil nil "init" "-q")
          (call-process "git" nil nil nil "config" "user.email" "t@t")
          (call-process "git" nil nil nil "config" "user.name" "t")
          (with-temp-file (expand-file-name "f.txt" repo) (insert "hi\n"))
          (call-process "git" nil nil nil "add" "-A")
          (call-process "git" nil nil nil "commit" "-qm" "init")
          (let* ((p (cmacs-brigade-isolation-prepare 'worktree "ag1"))
                 (cwd (plist-get p :cwd)))
            (should (file-directory-p cwd))
            (should (file-exists-p (expand-file-name "f.txt" cwd)))
            (with-temp-file (expand-file-name "dirty" cwd) (insert "x"))
            (cmacs-brigade-isolation-teardown 'worktree "ag1")
            (should-not (file-directory-p cwd))
            ;; twice is safe: teardown runs from an unwind path
            (cmacs-brigade-isolation-teardown 'worktree "ag1")))
      (delete-directory repo t))))

(ert-deftest cmacs-brigade-isolation-teardown-never-signals ()
  "A failing teardown reports and continues.

It runs while something else is already going wrong; masking that
failure with its own would lose the original."
  (skip-unless (featurep 'cmacs-brigade-isolation))
  (cmacs-brigade-register-isolation
   :name 'test-explodes
   :prepare (lambda (_id) (list :cwd default-directory))
   :teardown (lambda (_id) (error "boom")))
  (cmacs-brigade-isolation-teardown 'test-explodes "x")
  (should t))


;;;; Host provisioning

(ert-deftest cmacs-brigade-host-provision-round-trip ()
  "A provision writes a 0600 config with an expanded allowlist."
  (skip-unless (and (featurep 'cmacs-brigade-host)
                    (fboundp 'cmacs-mcp-start)))
  (cmacs-mcp-start)
  (skip-unless (cmacs-mcp-socket-path))
  (let ((p (cmacs-brigade-host-provision "test-agent" "memory")))
    (should p)
    (unwind-protect
        (progn
          (should (file-exists-p (plist-get p :path)))
          ;; The token is a credential; the file must never be readable
          ;; by anything else on the machine, not even briefly.
          (should (equal "-rw-------"
                         (file-attribute-modes
                          (file-attributes (plist-get p :path)))))
          ;; and it must not be derivable from anything the agent knows
          ;; about itself, since agents quote their own context freely
          (should-not (equal (plist-get p :token) "test-agent"))
          (let* ((cfg (with-temp-buffer
                        (insert-file-contents (plist-get p :path))
                        (json-parse-buffer :object-type 'plist)))
                 (srv (plist-get (plist-get cfg :mcpServers) :cmacs))
                 (env (plist-get srv :env)))
            (should (plist-get srv :command))
            ;; groups are expanded here because the relay has no registry
            (should (string-match-p "memory_search"
                                    (plist-get env :CMACS_BRIGADE_ALLOW)))
            (should (plist-get env :CMACS_BRIGADE_SOCKET))))
      (cmacs-brigade-host-revoke "test-agent"))
    (should-not (file-exists-p (plist-get p :path)))))

(ert-deftest cmacs-brigade-host-revoke-is-idempotent ()
  "Revoking twice is not an error."
  (skip-unless (featurep 'cmacs-brigade-host))
  (should-not (cmacs-brigade-host-revoke "never-provisioned")))


;;;; Concurrency

(ert-deftest cmacs-brigade-concurrency-cap-is-honest ()
  "A task that cannot start stays queued rather than starting anyway."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (let ((cmacs-brigade-max-concurrent 0))
    (should (cmacs-brigade-can-start-p)))     ; 0 means unlimited
  (let ((cmacs-brigade-max-concurrent 1))
    ;; no live runs in a batch test, so a slot is free
    (should (cmacs-brigade-can-start-p))))

(ert-deftest cmacs-brigade-start-unknown-agent-fails-loudly ()
  "A task naming a nonexistent agent fails with a readable reason."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (let ((id (format "test-%s" (random 100000))))
    (unwind-protect
        (progn
          (cmacs-brigade-task-adopt id "p.org" "no-such-agent" "T")
          (should-not (cmacs-brigade-start-task id))
          (let ((rec (cmacs-brigade-task-get id)))
            (should (eq 'failed (plist-get rec :state)))
            (should (string-match-p "no-such-agent" (plist-get rec :error)))))
      (cmacs-brigade-task-forget id))))


;;;; Dashboard

(ert-deftest cmacs-brigade-dashboard-renders ()
  "The dashboard renders with and without tasks, and shows the numbers."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let ((id (format "test-%s" (random 100000))))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*brigade*")
          (cmacs-brigade-dashboard-mode)
          (cmacs-brigade-dashboard--render)
          (should (string-match-p "No tasks" (buffer-string)))

          (cmacs-brigade-task-adopt id "/tmp/p.org" "researcher" "Do a thing")
          (cmacs-brigade-task-transition id 'queued)
          (cmacs-brigade-task-transition id 'starting)
          (cmacs-brigade-task-transition id 'running)
          (cmacs-brigade-task-progress id 4 900 210 5400)
          (cmacs-brigade-dashboard--render)
          (let ((s (buffer-string)))
            (should (string-match-p "Do a thing" s))
            (should (string-match-p "researcher" s))
            ;; 5400 micro-dollars rendered as dollars
            (should (string-match-p "0\\.0054" s))
            (should (string-match-p "live 1" s))))
      (cmacs-brigade-task-forget id)
      (when (get-buffer "*brigade*") (kill-buffer "*brigade*")))))

(ert-deftest cmacs-brigade-dashboard-ascii-fallback ()
  "Glyphs degrade to ASCII where Unicode cannot be displayed."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let ((cmacs-brigade-dashboard-unicode nil))
    (should (equal ">" (cmacs-brigade-dashboard--glyph 'running)))
    (should (equal "+" (cmacs-brigade-dashboard--glyph 'done))))
  (let ((cmacs-brigade-dashboard-unicode t))
    (should (equal "▶" (cmacs-brigade-dashboard--glyph 'running)))))

(ert-deftest cmacs-brigade-dashboard-panel-failure-is-contained ()
  "A user panel that signals does not take the dashboard with it.

The dashboard is how someone would notice the panel is broken."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (cmacs-brigade-register-panel
   :name 'test-explodes :title "Boom" :render (lambda () (error "nope")))
  (unwind-protect
      (with-current-buffer (get-buffer-create "*brigade*")
        (cmacs-brigade-dashboard-mode)
        (cmacs-brigade-dashboard--render)
        (should (string-match-p "panel test-explodes failed" (buffer-string))))
    (remhash 'test-explodes (cmacs-brigade--registry 'panel))
    (when (get-buffer "*brigade*") (kill-buffer "*brigade*"))))


;;;; Workers
;;
;; `inproc' is the default in every agent definition, and the runner used
;; to pcase over a hardcoded list that did not include it -- so a stock
;; agent failed with "unknown worker inproc".  These pin the dispatch
;; rather than the list.

(ert-deftest cmacs-brigade-workers-registered ()
  "Every shipped worker goes through the public registry, inproc included."
  (skip-unless (featurep 'cmacs-brigade-run))
  (dolist (w '(inproc claude-code opencode shell))
    (let ((def (cmacs-brigade-registry-get 'worker w)))
      (should def)
      (should (functionp (plist-get def :start)))
      (should (functionp (plist-get def :cancel))))))

(ert-deftest cmacs-brigade-default-agent-worker-is-runnable ()
  "The worker an agent gets by default must actually be registered.

The two defaults are set in different files; nothing otherwise notices
when they stop agreeing."
  (skip-unless (featurep 'cmacs-brigade-run))
  (let ((agent (cmacs-brigade-agent--from-text
                "---\nname: worker-default-test\n---\nbody" nil)))
    (should (cmacs-brigade-registry-get 'worker (plist-get agent :worker))))
  (should (cmacs-brigade-registry-get 'worker cmacs-brigade-worker)))

(ert-deftest cmacs-brigade-start-dispatches-to-the-worker ()
  "Starting a task calls the registered worker's :start."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (let ((called nil))
    (cmacs-brigade-register-worker
     :name 'test-worker
     :start (lambda (task-id &rest _) (setq called task-id) (list :fake t))
     :cancel #'ignore)
    (cmacs-brigade-register-agent :name 'worker-test-agent :prompt "p"
                                  :worker 'test-worker :isolation 'none)
    (let ((id "worker-dispatch-1"))
      (cmacs-brigade-task-adopt id "plan.org" "worker-test-agent" "t")
      (cmacs-brigade-task-transition id 'queued)
      (unwind-protect
          (progn
            (should (cmacs-brigade-start-task id))
            (should (equal called id))
            (should (eq 'running (plist-get (cmacs-brigade-task-get id)
                                            :state))))
        (ignore-errors (cmacs-brigade-cancel-task id))
        (ignore-errors (cmacs-brigade-task-forget id))))))

(ert-deftest cmacs-brigade-cancel-dispatches-to-the-worker ()
  "Cancelling calls the worker's own :cancel, not delete-process.

A user-registered worker whose run is not a process would otherwise get
a `delete-process' aimed at whatever it did return."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (let ((cancelled nil))
    (cmacs-brigade-register-worker
     :name 'test-worker-2
     :start (lambda (&rest _) (list :fake t))
     :cancel (lambda (task-id _run) (setq cancelled task-id)))
    (cmacs-brigade-register-agent :name 'worker-test-agent-2 :prompt "p"
                                  :worker 'test-worker-2 :isolation 'none)
    (let ((id "worker-dispatch-2"))
      (cmacs-brigade-task-adopt id "plan.org" "worker-test-agent-2" "t")
      (cmacs-brigade-task-transition id 'queued)
      (unwind-protect
          (progn
            (cmacs-brigade-start-task id)
            (cmacs-brigade-cancel-task id)
            (should (equal cancelled id)))
        (ignore-errors (cmacs-brigade-task-forget id))))))

(ert-deftest cmacs-brigade-unknown-worker-says-what-is-known ()
  "An unknown worker fails the task with a message naming the real ones."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (cmacs-brigade-register-agent :name 'bad-worker-agent :prompt "p"
                                :worker 'no-such-worker :isolation 'none)
  (let ((id "worker-dispatch-3"))
    (cmacs-brigade-task-adopt id "plan.org" "bad-worker-agent" "t")
    (cmacs-brigade-task-transition id 'queued)
    (unwind-protect
        (progn
          (should-not (cmacs-brigade-start-task id))
          (let ((rec (cmacs-brigade-task-get id)))
            (should (eq 'failed (plist-get rec :state)))
            (should (string-match-p "unknown worker" (plist-get rec :error)))
            ;; and it says what would have worked
            (should (string-match-p "inproc" (plist-get rec :error)))))
      (ignore-errors (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-splits-provider-from-model ()
  "\"provider/model\" splits; a bare name keeps the default provider."
  (skip-unless (featurep 'cmacs-brigade-run))
  (should (equal (cmacs-brigade--split-model "claude/claude-sonnet-4-6")
                 '(claude . "claude-sonnet-4-6")))
  (should (equal (cmacs-brigade--split-model "ollama/gpt-oss:20b")
                 '(ollama . "gpt-oss:20b")))
  ;; Only the first slash separates, so a model name may contain one.
  (should (equal (cmacs-brigade--split-model "openai/org/model-x")
                 '(openai . "org/model-x")))
  (should (equal (cdr (cmacs-brigade--split-model "gpt-oss:20b"))
                 "gpt-oss:20b")))

(provide 'cmacs-brigade-run-tests)

;;; cmacs-brigade-run-tests.el ends here
