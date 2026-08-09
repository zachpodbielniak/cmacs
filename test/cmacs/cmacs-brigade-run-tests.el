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
(require 'cmacs-brigade-plan nil 'noerror)
(require 'cmacs-brigade-output nil 'noerror)
(require 'cmacs-brigade-subagent nil 'noerror)
(require 'cmacs-ai-chat nil 'noerror)
(require 'cmacs-brigade-subagent nil 'noerror)
(require 'cl-lib)

(defconst cmacs-brigade-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "Repository root, for the cross-surface parity checks.")
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

(ert-deftest cmacs-brigade-dashboard-hints-mention-every-action-key ()
  "Every key the dashboard binds to one of its own commands is on screen.

The hints line is the only discovery path short of `?', so a key that is
bound but missing from it may as well not exist.  That is not
hypothetical: the conversation keys shipped working and unfindable
because updating this string was not part of adding them."
  (skip-unless (and (featurep 'cmacs-brigade-dashboard)
                    (fboundp 'cmacs-brigade-dashboard--hints)))
  (let ((hints (cmacs-brigade-dashboard--hints))
        ;; Case matters: `X' and `x' are different commands, and with
        ;; folding on -- the default -- a missing `X' matches `x compose'
        ;; and the check passes on a key that is not there.
        (case-fold-search nil)
        missing)
    (map-keymap
     (lambda (event def)
       (when (and (characterp event)
                  (symbolp def)
                  (string-prefix-p "cmacs-brigade-dashboard-"
                                   (symbol-name def)))
         (let ((key (key-description (vector event))))
           ;; Matched as a whole token, not a substring: a bare "i" is
           ;; inside "list", so a loose search would pass on a key that
           ;; is nowhere to be seen.
           (unless (string-match-p
                    (concat "\\(?:^\\|[ \n]\\)" (regexp-quote key) "[ \n]")
                    hints)
             (push key missing)))))
     cmacs-brigade-dashboard-mode-map)
    (should (equal nil (nreverse missing)))))

(ert-deftest cmacs-brigade-dashboard-binds-the-conversation-keys ()
  "`i', `I' and `X' reach the mailbox commands."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (should (eq 'cmacs-brigade-dashboard-send
              (lookup-key cmacs-brigade-dashboard-mode-map "i")))
  (should (eq 'cmacs-brigade-dashboard-inbox
              (lookup-key cmacs-brigade-dashboard-mode-map "I")))
  (should (eq 'cmacs-brigade-dashboard-close
              (lookup-key cmacs-brigade-dashboard-mode-map "X"))))

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
  "Whatever worker an agent resolves to must actually be registered.

A definition naming none leaves :worker nil on purpose, so the resolver
gets to pick from the provider; the thing that must hold is that the
answer exists, whichever way it was reached."
  (skip-unless (featurep 'cmacs-brigade-run))
  (dolist (front '("" "model: claude/sonnet\n" "model: claude-code/opus\n"
                   "worker: shell\n"))
    (let ((agent (cmacs-brigade-agent--from-text
                  (format "---\nname: worker-default-test\n%s---\nbody" front)
                  nil)))
      (should (cmacs-brigade-registry-get
               'worker (cmacs-brigade-resolve-worker agent)))))
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
  ;; Unlimited: earlier tests leave entries in the run table, and the
  ;; concurrency cap would refuse the start before the worker is ever
  ;; looked up -- which is not what this asserts.
  (let ((cmacs-brigade-max-concurrent 0)
        (id "worker-dispatch-3"))
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


;;;; End to end
;;
;; The unit tests above all passed while the pipeline was broken in three
;; separate places, because each half worked in isolation.  These run a
;; task the whole way through: adopt the org, resolve the agent, dispatch
;; to a worker, run it, and come back out through the finished hook.

(defmacro cmacs-brigade-run-tests--with-plan (body-text &rest forms)
  "Adopt a one-task plan whose prompt is BODY-TEXT, then run FORMS.
Binds `id' to the task id and `plan-file' to the file."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "brigade-e2e" t))
          (plan-file (expand-file-name "p.org" dir))
          (cmacs-brigade-plan-directory dir))
     (unwind-protect
         (progn
           (with-temp-file plan-file
             (insert "#+title: e2e\n" cmacs-brigade-plan-todo-line "\n\n"
                     "* TODO Smoke  :brigade:\n  :PROPERTIES:\n"
                     "  :AGENT: e2e-agent\n  :END:\n  " ,body-text "\n"))
           (with-current-buffer (find-file-noselect plan-file)
             (let ((id (plist-get (car (cmacs-brigade-plan-adopt)) :id)))
               (ignore id)
               ,@forms)))
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b)
                    (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))

(ert-deftest cmacs-brigade-e2e-shell-worker-runs-a-task ()
  "Adopt a plan, start it, and get the task's own output back.

The marker is the point: it can only appear if the *task* prompt reached
the worker.  It did not for a long time -- `cmacs-brigade--build-prompt'
read :prompt off the C runtime record, which has no such field, so every
agent ran with its standing instructions and no work to do, exited 0, and
reported success."
  (skip-unless (and (cmacs-brigade-run-tests--available-p)
                    (executable-find "bash")))
  (cmacs-brigade-register-agent
   :name 'e2e-agent :prompt "# standing instructions"
   :worker 'shell :isolation 'none)
  (let (finished)
    (let ((cmacs-brigade-run-finished-functions
           (list (lambda (i st out) (setq finished (list i st out))))))
      (cmacs-brigade-run-tests--with-plan "echo BRIGADE_E2E_OK"
        (cmacs-brigade-task-transition id 'queued)
        (should (cmacs-brigade-start-task id))
        (let ((deadline (+ (float-time) 20)))
          (while (and (null finished) (< (float-time) deadline))
            (accept-process-output nil 0.05)))
        (should finished)
        (should (equal id (nth 0 finished)))
        (should (eq 'done (nth 1 finished)))
        (should (string-match-p "BRIGADE_E2E_OK" (or (nth 2 finished) "")))
        (should (eq 'done (plist-get (cmacs-brigade-task-get id) :state)))
        ;; and it cleaned up after itself.  This task specifically:
        ;; the global count picks up runs other tests left behind.
        (should-not (gethash id cmacs-brigade--runs))))))

(ert-deftest cmacs-brigade-task-prompt-comes-from-the-plan ()
  "The prompt is read back from the org file, not from the record."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (cmacs-brigade-register-agent :name 'e2e-agent :prompt "sys"
                                :worker 'shell :isolation 'none)
  (cmacs-brigade-run-tests--with-plan "the actual task text"
    (let ((rec (cmacs-brigade-task-get id)))
      (should (equal "the actual task text"
                     (cmacs-brigade--task-prompt rec)))
      ;; the blob a CLI worker gets carries both, in that order
      (let ((blob (cmacs-brigade--build-prompt
                   rec (cmacs-brigade-agent-get 'e2e-agent))))
        (should (string-match-p "sys" blob))
        (should (string-match-p "the actual task text" blob))
        (should (< (string-match "sys" blob)
                   (string-match "the actual" blob)))))))

(ert-deftest cmacs-brigade-e2e-inproc-splits-system-from-task ()
  "The inproc worker sends standing instructions as the system prompt.

Concatenating them into the user turn as well is not merely untidy: the
agent then reads its own instructions as part of the request."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (cmacs-brigade-register-agent
   :name 'e2e-agent :prompt "standing instructions"
   :model "claude/some-model" :worker 'inproc :isolation 'none)
  (let (system-got user-got finished)
    (cl-letf (((symbol-function 'cmacs-ai-make-session)
               (lambda (_p _m &optional sys) (setq system-got sys) (cons 1 2)))
              ((symbol-function 'cmacs-ai-free-session) #'ignore)
              ((symbol-function 'cmacs-ai-tools-new) (lambda () 99))
              ((symbol-function 'cmacs-ai-tools-free) #'ignore)
              ;; The worker now points the built-in tools at the task's
              ;; directory; the real DEFUN would reject this stub handle.
              ((symbol-function 'cmacs-ai-tools-set-working-directory)
               #'ignore)
              ((symbol-function 'cmacs-brigade-install-tools)
               (lambda (&rest _) 0))
              ((symbol-function 'cmacs-ai-session-append-message)
               (lambda (_s _role text) (setq user-got text)))
              ((symbol-function 'cmacs-ai-tools-run-async)
               (lambda (_s _e cb) (funcall cb '(:text "stub reply")))))
      (let ((cmacs-brigade-run-finished-functions
             (list (lambda (i st out) (setq finished (list i st out))))))
        (cmacs-brigade-run-tests--with-plan "do the task"
          (cmacs-brigade-task-transition id 'queued)
          (should (cmacs-brigade-start-task id))
          (should (equal system-got "standing instructions"))
          (should (equal user-got "do the task"))
          (should (eq 'done (nth 1 finished)))
          (should (equal "stub reply" (nth 2 finished))))))))

(ert-deftest cmacs-brigade-e2e-inproc-reports-a-failure ()
  "An error from the tool loop fails the task with its message."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (cmacs-brigade-register-agent :name 'e2e-agent :prompt "s"
                                :model "claude/m" :worker 'inproc
                                :isolation 'none)
  (let (finished)
    (cl-letf (((symbol-function 'cmacs-ai-make-session)
               (lambda (&rest _) (cons 1 2)))
              ((symbol-function 'cmacs-ai-free-session) #'ignore)
              ((symbol-function 'cmacs-ai-tools-new) (lambda () 99))
              ((symbol-function 'cmacs-ai-tools-free) #'ignore)
              ;; The worker now points the built-in tools at the task's
              ;; directory; the real DEFUN would reject this stub handle.
              ((symbol-function 'cmacs-ai-tools-set-working-directory)
               #'ignore)
              ((symbol-function 'cmacs-brigade-install-tools) (lambda (&rest _) 0))
              ((symbol-function 'cmacs-ai-session-append-message) #'ignore)
              ((symbol-function 'cmacs-ai-tools-run-async)
               (lambda (_s _e cb) (funcall cb '(:error "no API key")))))
      (let ((cmacs-brigade-run-finished-functions
             (list (lambda (i st out) (setq finished (list i st out))))))
        (cmacs-brigade-run-tests--with-plan "x"
          (cmacs-brigade-task-transition id 'queued)
          (cmacs-brigade-start-task id)
          (should (eq 'failed (nth 1 finished)))
          (should (eq 'failed (plist-get (cmacs-brigade-task-get id) :state)))
          (should (string-match-p "no API key"
                                  (plist-get (cmacs-brigade-task-get id)
                                             :error))))))))


;;;; Worker resolution

(ert-deftest cmacs-brigade-provider-picks-the-cli-worker ()
  "A CLI provider implies its own worker.

Running a CLI provider through the in-process tool loop silently drops
every tool -- the CLI clients ignore the tools argument and take them
over MCP -- so picking `claude-code' as the provider has to pick the
claude-code worker too."
  (skip-unless (featurep 'cmacs-brigade-run))
  (should (eq 'claude-code
              (cmacs-brigade-resolve-worker '(:model "claude-code/opus"))))
  (should (eq 'opencode
              (cmacs-brigade-resolve-worker '(:model "opencode/gpt-5"))))
  ;; An HTTP provider keeps the in-process worker.
  (should (eq 'inproc
              (cmacs-brigade-resolve-worker '(:model "claude/sonnet"))))
  ;; An explicit worker always wins.
  (should (eq 'shell
              (cmacs-brigade-resolve-worker
               '(:model "claude-code/opus" :worker shell))))
  ;; Every worker a provider can imply must actually exist.
  (dolist (cell cmacs-brigade-cli-providers)
    (should (cmacs-brigade-registry-get 'worker (cdr cell)))))

(ert-deftest cmacs-brigade-cli-model-arg-is-the-bare-name ()
  "The provider prefix is ours, not the CLI's."
  (skip-unless (featurep 'cmacs-brigade-run))
  (let ((argv (cmacs-brigade--worker-command
               'claude-code '(:model "claude-code/opus") "/tmp/p" nil)))
    (should (member "--model" argv))
    (should (member "opus" argv))
    (should-not (member "claude-code/opus" argv)))
  ;; opencode spells its own models "vendor/model"; only our prefix goes.
  (let ((argv (cmacs-brigade--worker-command
               'opencode '(:model "opencode/anthropic/claude-3") "/tmp/p" nil)))
    (should (member "anthropic/claude-3" argv))))

(ert-deftest cmacs-brigade-ollama-transport-model-is-recognised ()
  "Only `PROVIDER/ollama/NAME' is an Ollama-transport model."
  (skip-unless (featurep 'cmacs-brigade-run))
  (should (equal "qwen3.5:9b"
                 (cmacs-brigade--ollama-transport-model
                  "claude-code/ollama/qwen3.5:9b")))
  (should (equal "gemma4:12b"
                 (cmacs-brigade--ollama-transport-model
                  "claude-tmux/ollama/gemma4:12b")))
  ;; the plain ollama provider is a different thing -- it talks HTTP to
  ;; the ollama server, and never launches a CLI
  (should-not (cmacs-brigade--ollama-transport-model "ollama/qwen3.5:9b"))
  (should-not (cmacs-brigade--ollama-transport-model "claude-code/opus"))
  (should-not (cmacs-brigade--ollama-transport-model nil))
  ;; "ollama/" with nothing after it names no model
  (should-not (cmacs-brigade--ollama-transport-model "claude-code/ollama/")))

(ert-deftest cmacs-brigade-cli-runs-ollama-models-through-the-launcher ()
  "An `ollama/' model execs the launcher, not claude directly.

The claude CLI has no such model; ai-glib runs the same model as
\"ollama launch claude --model NAME --\" in the in-process path, and the
subprocess worker has to build the identical command or a model that
works one way silently fails the other."
  (skip-unless (featurep 'cmacs-brigade-run))
  (let ((argv (cmacs-brigade--worker-command
               'claude-code '(:model "claude-code/ollama/qwen3.5:9b")
               "/tmp/p" nil)))
    (should (equal '("launch" "claude" "--model" "qwen3.5:9b" "--")
                   (seq-subseq argv 1 6)))
    (should (string-match-p "ollama\\'" (car argv)))
    ;; claude's own --model must not also be passed: ollama supplies it
    (should-not (member "--model" (seq-drop argv 6)))
    (should-not (member "ollama/qwen3.5:9b" argv))
    ;; and the claude arguments still ride after the "--"
    (should (member "--print" argv))
    (should (member "--output-format" argv)))
  ;; a plain model is untouched
  (let ((argv (cmacs-brigade--worker-command
               'claude-code '(:model "claude-code/opus") "/tmp/p" nil)))
    (should (equal cmacs-brigade-claude-program (car argv)))
    (should-not (member "launch" argv))))


;;;; Output

(defmacro cmacs-brigade-run-tests--with-output-dir (&rest body)
  (declare (indent 0))
  `(let* ((dir (make-temp-file "brigade-out" t))
          (cmacs-brigade-output-dir dir)
          (cmacs-brigade-output--cache (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest cmacs-brigade-output-round-trips ()
  (skip-unless (featurep 'cmacs-brigade-output))
  (cmacs-brigade-run-tests--with-output-dir
    (cmacs-brigade-output-put "t1" "the answer")
    (should (equal "the answer" (cmacs-brigade-output-get "t1")))
    ;; and again with the session cache gone, which is the case that
    ;; matters: the usual question is what last night's run said.
    (let ((cmacs-brigade-output--cache (make-hash-table :test 'equal)))
      (should (equal "the answer" (cmacs-brigade-output-get "t1"))))))

(ert-deftest cmacs-brigade-output-is-recorded-by-the-finished-hook ()
  "Output is captured without anyone remembering to capture it."
  (skip-unless (featurep 'cmacs-brigade-output))
  (cmacs-brigade-run-tests--with-output-dir
    (run-hook-with-args 'cmacs-brigade-run-finished-functions
                        "t-hooked" 'done "hook output")
    (should (equal "hook output" (cmacs-brigade-output-get "t-hooked")))))

(ert-deftest cmacs-brigade-output-missing-is-not-an-empty-buffer ()
  "Nothing-produced and not-started must not look identical."
  (skip-unless (featurep 'cmacs-brigade-output))
  (cmacs-brigade-run-tests--with-output-dir
    (let ((buf (cmacs-brigade-output-show "never-ran")))
      (unwind-protect
          (should (string-match-p "no output"
                                  (with-current-buffer buf (buffer-string))))
        (kill-buffer buf)))))

(ert-deftest cmacs-brigade-output-shows-text-and-usage ()
  (skip-unless (and (featurep 'cmacs-brigade-output)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (cmacs-brigade-run-tests--with-output-dir
    (let ((id "out-show-1"))
      (cmacs-brigade-task-adopt id "p.org" nil "Some task")
      (cmacs-brigade-task-progress id 3 100 200 45000)
      (cmacs-brigade-output-put id "the produced answer")
      (let ((buf (cmacs-brigade-output-show id)))
        (unwind-protect
            (let ((text (with-current-buffer buf (buffer-string))))
              (should (string-match-p "Some task" text))
              (should (string-match-p "the produced answer" text))
              (should (string-match-p "3 turns" text))
              (should (string-match-p "100/200 tokens" text))
              (should (string-match-p "0\\.0450" text)))
          (kill-buffer buf)
          (ignore-errors (cmacs-brigade-task-forget id)))))))

(ert-deftest cmacs-brigade-dashboard-binds-output ()
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (should (eq 'cmacs-brigade-dashboard-output
              (lookup-key cmacs-brigade-dashboard-mode-map (kbd "o")))))


;;;; Reading a CLI's report

(ert-deftest cmacs-brigade-parses-a-cli-report ()
  "Text comes out and usage is recorded, which is why JSON is asked for."
  (skip-unless (and (featurep 'cmacs-brigade-run)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (let ((id "report-1"))
    (cmacs-brigade-task-adopt id "p.org" nil "t")
    (unwind-protect
        (let ((text (cmacs-brigade--parse-cli-report
                     (concat "{\"result\":\"Paris.\",\"num_turns\":2,"
                             "\"total_cost_usd\":0.0329,"
                             "\"usage\":{\"input_tokens\":10,"
                             "\"output_tokens\":78}}")
                     id)))
          (should (equal "Paris." text))
          (let ((r (cmacs-brigade-task-get id)))
            (should (= 2 (plist-get r :turns)))
            (should (= 10 (plist-get r :in-tokens)))
            (should (= 78 (plist-get r :out-tokens)))
            ;; integer micro-dollars, so repeated sums do not drift
            (should (= 32900 (plist-get r :cost-micros)))))
      (ignore-errors (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-non-report-output-is-passed-through ()
  "A worker that prints prose must not have it swallowed."
  (skip-unless (featurep 'cmacs-brigade-run))
  (should (equal "just some text"
                 (cmacs-brigade--parse-cli-report "just some text" "x")))
  ;; JSON that is not a report keeps its raw form rather than vanishing
  (should (equal "{\"unrelated\":1}"
                 (cmacs-brigade--parse-cli-report "{\"unrelated\":1}" "x")))
  ;; and a report with no usage block still yields its text
  (should (equal "hi" (cmacs-brigade--parse-cli-report
                       "{\"result\":\"hi\"}" "x"))))

(ert-deftest cmacs-brigade-report-survives-a-preamble ()
  "A CLI warning printed before the JSON must not break parsing."
  (skip-unless (featurep 'cmacs-brigade-run))
  (should (equal "ok" (cmacs-brigade--parse-cli-report
                       "warning: something\n{\"result\":\"ok\"}" "x"))))

(ert-deftest cmacs-brigade-subprocess-argv-uses-the-resolved-worker ()
  "The argv comes from the resolved worker, not a second copy of the rule.

Computing the worker again inside the spawn path is how a run dispatched
to claude-code ended up asking for inproc's argv and failing with
\"inproc has no subprocess form\"."
  (skip-unless (featurep 'cmacs-brigade-run))
  (let ((argv nil)
        (orig (symbol-function 'make-process)))
    ;; Capture the argv, then delegate to the real `make-process' with a
    ;; harmless command.  Calling `start-process' from the stub instead
    ;; recurses, since that is implemented in terms of `make-process'.
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq argv (plist-get args :command))
                 (apply orig (plist-put (copy-sequence args)
                                        :command (list "true"))))))
      (cmacs-brigade--start-process
       "argv-test" '(:name argv-agent :model "claude-code/opus") "prompt"
       nil nil nil))
    (should (equal (car argv) cmacs-brigade-claude-program))
    (should (member "--print" argv))
    (should (member "opus" argv))))


;;;; Subagents

(ert-deftest cmacs-brigade-subagent-tools-are-registered ()
  "The five spawn tools exist.

They were specified in the design and never implemented, so an agent had
no way to hand work to another agent and a chat buffer had nothing to
show."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (dolist (n '(agent-spawn agent-status agent-result agent-cancel agent-list))
    (should (cmacs-brigade-registry-get 'tool n))
    (should (eq 'agent (cmacs-brigade-tool-group
                        (cmacs-brigade-registry-get 'tool n)))))
  ;; Spawning spends money on a schedule the user did not choose.
  (should (cmacs-brigade-tool-destructive
           (cmacs-brigade-registry-get 'tool 'agent-spawn)))
  (should (cmacs-brigade-tool-confirm
           (cmacs-brigade-registry-get 'tool 'agent-spawn)))
  ;; Reading status must not be gated, or polling becomes unusable.
  (should-not (cmacs-brigade-tool-destructive
               (cmacs-brigade-registry-get 'tool 'agent-status))))

(ert-deftest cmacs-brigade-subagent-tools-are-not-blocked-by-the-gate ()
  "`agent_*' has to pass the allowlist, unlike `brigade_*' and `ai_*'.

Those two prefixes are refused outright so an agent cannot reach the
orchestrator directly; these five are the sanctioned way through, and a
gate that blocked them too would make spawning impossible."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (should (cmacs-brigade-tool-allowed-p "agent" "agent_spawn"))
  (should (cmacs-brigade-tool-allowed-p "*" "agent_status"))
  (should-not (cmacs-brigade-tool-allowed-p "*" "brigade_start"))
  (should-not (cmacs-brigade-tool-allowed-p "*" "ai_call")))

(ert-deftest cmacs-brigade-subagent-spawn-checks-its-agent ()
  "An unknown agent is reported with what would have worked."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((err (should-error (cmacs-brigade-subagent-spawn
                            'definitely-no-such-agent "do a thing")
                           :type 'cmacs-brigade-error)))
    (should (string-match-p "no agent named" (format "%s" err)))))

(ert-deftest cmacs-brigade-subagent-depth-is-bounded ()
  "Spawning cannot nest without limit.

A subagent that can spawn can spawn something that spawns, and a runaway
tree is expensive in a way that is not noticed until the bill."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((cmacs-brigade-subagent--parent (make-hash-table :test 'equal))
        (cmacs-brigade-subagent-max-depth 2))
    (cmacs-brigade-register-agent :name 'depth-agent :prompt "p")
    (puthash "b" "a" cmacs-brigade-subagent--parent)
    (puthash "c" "b" cmacs-brigade-subagent--parent)
    (should (= 0 (cmacs-brigade-subagent-depth "a")))
    (should (= 2 (cmacs-brigade-subagent-depth "c")))
    (should (equal '("b") (cmacs-brigade-subagent-children "a")))
    ;; spawning from c would be depth 3
    (should-error (cmacs-brigade-subagent-spawn 'depth-agent "x" nil "c")
                  :type 'cmacs-brigade-error)))

(ert-deftest cmacs-brigade-subagent-result-waits-for-the-run ()
  "Collecting early says so instead of returning an empty answer."
  (skip-unless (and (featurep 'cmacs-brigade-subagent)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (let ((id "subagent-result-1"))
    (cmacs-brigade-task-adopt id "p.org" nil "t")
    (unwind-protect
        (let ((tool (cmacs-brigade-registry-get 'tool 'agent-result)))
          ;; The handler's arity is the tool's full parameter list, so
          ;; the optional turn is passed explicitly.  Real dispatch goes
          ;; through `cmacs-brigade--tool-args', which fills in the
          ;; missing ones; calling the handler directly is a test-only
          ;; shortcut and has to do that job itself.
          (should (string-match-p
                   "Still draft"
                   (funcall (cmacs-brigade-tool-handler tool) id nil))))
      (ignore-errors (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-chat-executor-hook-installs-tools ()
  "A cmacs-ai chat buffer gets the brigade's tools through the hook.

The hook is on cmacs-ai's side and the brigade adds to it, because the
brigade requires cmacs-ai and the reverse would be a cycle."
  (skip-unless (and (featurep 'cmacs-brigade-subagent)
                    (fboundp 'cmacs-ai-tools-new)))
  (should (memq 'cmacs-brigade-chat-install-tools
                cmacs-ai-chat-executor-functions))
  (let ((ex (cmacs-ai-tools-new)))
    (unwind-protect
        (should (> (cmacs-brigade-install-tools ex "agent") 0))
      (cmacs-ai-tools-free ex))))


(ert-deftest cmacs-brigade-cli-workers-can-use-their-tools ()
  "A CLI worker is told not to ask before using what it was granted.

Without this the agent sees the tools its MCP config grants and cannot
call one of them: there is no human at a prompt to approve them.  What it
may reach is bounded by the capability token in that config, which is the
gate that actually matters."
  (skip-unless (featurep 'cmacs-brigade-run))
  (let ((argv (cmacs-brigade--worker-command
               'claude-code '(:model "claude-code/opus") "/tmp/p"
               '(:path "/run/x.json"))))
    (should (member "--dangerously-skip-permissions" argv)))
  ;; opencode spells the same thing as an environment variable.
  (should (equal cmacs-brigade-opencode-allow-all
                 (cdr (assoc "OPENCODE_PERMISSION"
                             (cmacs-brigade--worker-env 'opencode nil)))))
  ;; and a plain shell worker gets neither
  (should-not (assoc "OPENCODE_PERMISSION"
                     (cmacs-brigade--worker-env 'shell nil)))
  (should-not (member "--dangerously-skip-permissions"
                      (cmacs-brigade--worker-command
                       'shell '(:model nil) "/tmp/p" nil))))


;;;; Subagent controls on every surface
;;
;; One registration is supposed to light up in-process agents, CLI agents
;; over MCP, external MCP clients, a chat buffer, D-Bus and emacsctl.
;; These check the ones reachable from Elisp; the D-Bus and emacsctl
;; halves are C and are covered by the parity test below.

(ert-deftest cmacs-brigade-subagent-tools-reach-the-mcp-mirror ()
  "The C mirror is what the MCP server publishes from.

An Elisp tool that never reaches the mirror is invisible to every MCP
client, which is the whole external surface."
  (skip-unless (and (featurep 'cmacs-brigade-subagent)
                    (fboundp 'cmacs-brigade--mirror-names)))
  (let ((mirrored (cmacs-brigade--mirror-names)))
    (dolist (n '("agent_spawn" "agent_status" "agent_result"
                 "agent_cancel" "agent_list"))
      (should (member n mirrored)))))

(ert-deftest cmacs-brigade-chat-can-spawn-not-just-watch ()
  "A chat buffer gets the destructive agent tools too.

`cmacs-brigade-install-tools' filters destructive tools by default, which
left a chat able to inspect subagents and never start one.  A chat has a
human in it and these carry :confirm, so the confirmation is the gate."
  (skip-unless (and (featurep 'cmacs-brigade-subagent)
                    (fboundp 'cmacs-ai-tools-new)))
  (let ((ex (cmacs-ai-tools-new)))
    (unwind-protect
        (progn
          (cmacs-brigade-chat-install-tools ex 'claude)
          (let ((installed (cmacs-ai-tools-list ex)))
            (dolist (n '("agent_spawn" "agent_cancel"
                         "agent_status" "agent_result" "agent_list"))
              (should (member n installed)))))
      (cmacs-ai-tools-free ex))))

(ert-deftest cmacs-brigade-dbus-and-mcp-agree-on-the-verbs ()
  "The D-Bus interface exposes a method per subagent tool.

Read out of the C source rather than a live bus so it holds in batch:
the point is the sync discipline, not the transport."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((file (expand-file-name "cmacs/dbus/cmacs-dbus-iface-brigade.c"
                                cmacs-brigade-tests--root)))
    (skip-unless (file-readable-p file))
    (let ((text (with-temp-buffer (insert-file-contents file)
                                  (buffer-string))))
      (dolist (m '("Spawn" "Status" "Result" "Cancel" "List"))
        (should (string-match-p (format "name='%s'" m) text)))
      ;; and each routes to the matching tool
      (dolist (tool '("agent_spawn" "agent_status" "agent_result"
                      "agent_cancel" "agent_list"))
        (should (string-search tool text))))))

(ert-deftest cmacs-brigade-emacsctl-exposes-the-verbs ()
  "emacsctl has a brigade command per D-Bus method."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((file (expand-file-name "cmacs/emacsctl/ctl-cmd-subsys.c"
                                cmacs-brigade-tests--root)))
    (skip-unless (file-readable-p file))
    (let ((text (with-temp-buffer (insert-file-contents file)
                                  (buffer-string))))
      (dolist (verb '("brigade spawn" "brigade status" "brigade result"
                      "brigade cancel" "brigade list" "brigade agents"))
        (should (string-search verb text))))))


(ert-deftest cmacs-brigade-chat-hook-is-armed-without-loading-the-fabric ()
  "The executor hook is in place at startup, before the brigade loads.

Nothing requires `cmacs-brigade' -- its eager-load block sits inside the
file -- so in a real session none of it existed until a brigade command
was run by hand.  A chat therefore saw no brigade tools, and neither did
an MCP client.  The hook is now a bare form in loaddefs and the handler
is autoloaded, so opening a chat is what pulls the fabric in."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (should (memq 'cmacs-brigade-chat-install-tools
                cmacs-ai-chat-executor-functions))
  ;; and it is registered through an autoload cookie, so a cold session
  ;; has it too -- asserted against the source, since this session has
  ;; the file loaded already
  (let ((file (expand-file-name "lisp/cmacs/cmacs-brigade-subagent.el"
                                cmacs-brigade-tests--root)))
    (skip-unless (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (should (string-match-p
               ";;;###autoload (add-hook 'cmacs-ai-chat-executor-functions"
               (buffer-string))))))

(ert-deftest cmacs-brigade-mcp-publication-loads-the-lisp-side ()
  "The MCP publisher pulls in the Elisp registry before reading the mirror.

The mirror is filled by `cmacs-brigade-register-tool'; with nothing
requiring the brigade it was empty at server start, so every MCP client
saw a brigade with no tools."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((file (expand-file-name "cmacs/mcp/cmacs-mcp-tools-brigade.c"
                                cmacs-brigade-tests--root)))
    (skip-unless (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((text (buffer-string)))
        (should (string-search "(require 'cmacs-brigade nil t)" text))
        ;; before the mirror is walked, not after
        (should (< (string-search "(require 'cmacs-brigade nil t)" text)
                   (string-search "cmacs_brigade_registry_foreach" text)))))))


;;;; Confirmation must never prompt from a dispatch
;;
;; A chat model called a :confirm tool, the handler reached
;; `yes-or-no-p', and the whole editor wedged with C-g dead.  The
;; minibuffer's read_char calls wait_reading_process_output, which calls
;; xg_select, which dispatches the same GMainContext the tool call was
;; already running inside -- a recursive edit underneath a live dispatch,
;; entered with waiting_for_input cleared so quitting could not break it.

(ert-deftest cmacs-brigade-tool-dispatch-cannot-prompt ()
  "Lisp reached through the dispatch wrappers has interaction inhibited.

Tested through the same frames as the hang -- execute-into-session down
to the tool handler -- rather than by calling the handler directly,
because it is the wrappers in between that do the binding."
  (skip-unless (and (fboundp 'cmacs-ai-tools-execute-into-session)
                    (fboundp 'cmacs-brigade-install-tools)))
  (cmacs-brigade-deftool dispatch-probe "probe" ()
    (format "%S" inhibit-interaction))
  (let* ((pair (cmacs-ai-make-session 'claude "x"))
         (ex (cmacs-ai-tools-new)))
    (unwind-protect
        (progn
          (cmacs-brigade-install-tools ex "*" nil t)
          (should (equal "t" (cmacs-ai-tools-execute-into-session
                              (cdr pair) ex "dispatch_probe" "{}" "c1"))))
      (cmacs-ai-tools-free ex)
      (cmacs-ai-free-session pair))))

(ert-deftest cmacs-brigade-confirm-declines-when-it-cannot-ask ()
  "A gated tool is declined, with a message naming the way to allow it.

Declining is the only safe answer: there is nowhere to ask, and \"could
not ask\" must not become \"went ahead anyway\" for a tool whose author
asked for a prompt."
  (skip-unless (fboundp 'cmacs-brigade-call-tool))
  (cmacs-brigade-deftool confirm-probe "probe" ()
    :destructive t :confirm 'ask
    "should not run")
  (let ((cmacs-brigade-auto-approve nil)
        (cmacs-brigade-confirm-function nil))
    (let ((out (cmacs-brigade-call-tool "confirm_probe" "{}" "grok")))
      (should (string-match-p "needs approval" out))
      (should (string-match-p "cmacs-brigade-auto-approve" out))
      (should-not (string-match-p "should not run" out)))))

(ert-deftest cmacs-brigade-auto-approve-allows-a-named-tool ()
  "Pre-authorising is how a gated tool runs where nothing can ask."
  (skip-unless (fboundp 'cmacs-brigade-call-tool))
  (cmacs-brigade-deftool approve-probe "probe" ()
    :destructive t :confirm 'ask
    "it ran")
  (let ((cmacs-brigade-confirm-function nil))
    ;; named
    (let ((cmacs-brigade-auto-approve '("approve_probe")))
      (should (equal "it ran"
                     (cmacs-brigade-call-tool "approve_probe" "{}" "grok"))))
    ;; everything
    (let ((cmacs-brigade-auto-approve t))
      (should (equal "it ran"
                     (cmacs-brigade-call-tool "approve_probe" "{}" "grok"))))
    ;; a different tool named does not approve this one
    (let ((cmacs-brigade-auto-approve '("something_else")))
      (should (string-match-p "needs approval"
                              (cmacs-brigade-call-tool "approve_probe" "{}"
                                                       "grok"))))))

(ert-deftest cmacs-brigade-ungated-tools-are-unaffected ()
  "A tool with no :confirm still runs without any of this applying."
  (skip-unless (fboundp 'cmacs-brigade-call-tool))
  (cmacs-brigade-deftool ungated-probe "probe" () "fine")
  (let ((cmacs-brigade-auto-approve nil))
    (should (equal "fine" (cmacs-brigade-call-tool "ungated_probe" "{}" "x")))))


;;;; Table layout

(ert-deftest cmacs-brigade-dashboard-columns-fit-real-values ()
  "Every column is wide enough for what actually goes in it.

The reported symptom was a table whose fields were all clipped: a uuid
cut to ten characters, `agent-code-r', `claude/claude-sonn'.  An id you
cannot match against the one an agent printed is not an id."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let ((c (cmacs-brigade-dashboard--columns)))
    ;; a uuid is 36
    (should (>= (plist-get c :id) 36))
    (should (>= (plist-get c :agent) (length "agent-code-reviewer")))
    (should (>= (plist-get c :model) (length "claude/claude-sonnet-4-6")))
    (should (>= (plist-get c :task) 24))))

(ert-deftest cmacs-brigade-dashboard-rule-matches-the-table ()
  "The horizontal rule is as wide as the row, not a stale constant."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let* ((c (cmacs-brigade-dashboard--columns))
         ;; Plain text: the anchors are display properties and contribute
         ;; one character each, which is what the widths already allow
         ;; for as the inter-column space.
         (row (substring-no-properties
               (cmacs-brigade-dashboard--row
                c (list :st "ST" :id "ID" :agent "AGENT" :model "MODEL"
                        :task "TASK" :turns "T" :tokens "TOK" :cost "C")))))
    (should (= (length row) (plist-get c :total)))))

(ert-deftest cmacs-brigade-dashboard-row-shows-values-whole ()
  "A realistic row is not truncated."
  (skip-unless (and (featurep 'cmacs-brigade-dashboard)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (cmacs-brigade-register-agent :name 'layout-probe-agent :prompt "p"
                                :model "claude/claude-sonnet-4-6")
  (let ((id "04987c35-9c3f-4a1b-8e2d-000000000000"))
    (cmacs-brigade-task-adopt id "p.org" "layout-probe-agent"
                              "test pwd via subagent")
    (unwind-protect
        (with-temp-buffer
          (cmacs-brigade-dashboard--insert-row (cmacs-brigade-task-get id))
          (let ((line (buffer-string)))
            (should (string-match-p (regexp-quote id) line))
            (should (string-match-p "layout-probe-agent" line))
            (should (string-match-p "claude/claude-sonnet-4-6" line))
            (should (string-match-p "test pwd via subagent" line))))
      (ignore-errors (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-dashboard-binds-delete-and-new-agent ()
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (dolist (cell '(("d" . cmacs-brigade-dashboard-delete)
                  ("N" . cmacs-brigade-dashboard-new-agent)
                  ("T" . cmacs-brigade-dashboard-list-tools)))
    (should (eq (cdr cell)
                (lookup-key cmacs-brigade-dashboard-mode-map
                            (kbd (car cell)))))))


;;;; Provider and model selection

(ert-deftest cmacs-brigade-provider-and-model-tools-exist ()
  "An agent can find out what it may spawn with, on every surface."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (dolist (n '(agent-providers agent-models))
    (should (cmacs-brigade-registry-get 'tool n))
    ;; read-only: gating these would make choosing a model impossible
    (should-not (cmacs-brigade-tool-destructive
                 (cmacs-brigade-registry-get 'tool n)))))

(ert-deftest cmacs-brigade-spawn-takes-an-optional-model ()
  "The model is optional and defaults to the agent's own."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let* ((tool (cmacs-brigade-registry-get 'tool 'agent-spawn))
         (params (cmacs-brigade-tool-params tool))
         (model (cl-find "model" params
                         :key (lambda (p) (format "%s" (plist-get p :name)))
                         :test #'equal)))
    (should model)
    (should-not (plist-get model :required))))

(ert-deftest cmacs-brigade-spawn-model-reaches-the-plan ()
  "A model passed to spawn is written as :MODEL: on the task.

Through the plan rather than held in memory, so the override is visible,
editable and survives a restart like a hand-written one."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let* ((dir (file-name-as-directory (make-temp-file "brigade-spawn" t)))
         (cmacs-brigade-plan-directory dir)
         (cmacs-brigade-subagent-plan (expand-file-name "s.org" dir)))
    (unwind-protect
        (progn
          (cmacs-brigade-register-agent :name 'spawn-model-agent :prompt "p"
                                        :model "base/model")
          (cl-letf (((symbol-function 'cmacs-brigade-start-task) #'ignore))
            (cmacs-brigade-subagent-spawn 'spawn-model-agent "do it" nil nil
                                          "ollama/gpt-oss:20b"))
          (with-temp-buffer
            (insert-file-contents cmacs-brigade-subagent-plan)
            (should (string-match-p ":MODEL:  ollama/gpt-oss:20b"
                                    (buffer-string)))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p dir (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-dbus-and-emacsctl-offer-provider-and-model ()
  "The same two lookups exist off-editor, and spawn takes a model there."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((dbus (expand-file-name "cmacs/dbus/cmacs-dbus-iface-brigade.c"
                                cmacs-brigade-tests--root))
        (ctl (expand-file-name "cmacs/emacsctl/ctl-cmd-subsys.c"
                               cmacs-brigade-tests--root)))
    (skip-unless (and (file-readable-p dbus) (file-readable-p ctl)))
    (let ((d (with-temp-buffer (insert-file-contents dbus) (buffer-string)))
          (k (with-temp-buffer (insert-file-contents ctl) (buffer-string))))
      (dolist (m '("Providers" "Models"))
        (should (string-match-p (format "name='%s'" m) d)))
      ;; Spawn's XML and its g_variant_get must agree, or every call fails
      (should (string-match-p "name='model' direction='in'" d))
      (should (string-search "\"(&s&s&s&s)\"" d))
      (dolist (v '("brigade providers" "brigade models"))
        (should (string-search v k)))
      (should (string-search "s?:model" k)))))

(ert-deftest cmacs-brigade-agent-skeleton-is-loadable ()
  "The skeleton `cmacs-brigade-new-agent' writes parses as a definition.

Writing a template that the parser then rejects would be worse than no
template at all."
  (skip-unless (fboundp 'cmacs-brigade-new-agent))
  (let* ((dir (file-name-as-directory (make-temp-file "brigade-agent" t)))
         (cmacs-brigade-agent-path (list dir dir)))
    (unwind-protect
        (let ((file (cmacs-brigade-new-agent "skeleton-probe")))
          (with-current-buffer (find-buffer-visiting file)
            (save-buffer))
          (let ((def (cmacs-brigade-agent-load-file file)))
            (should def)
            (should (cmacs-brigade-agent-get 'skeleton-probe))
            ;; and the worker resolves, since the skeleton leaves it out
            (should (cmacs-brigade-registry-get
                     'worker (cmacs-brigade-resolve-worker
                              (cmacs-brigade-agent-get 'skeleton-probe))))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p dir (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))


(ert-deftest cmacs-brigade-tools-run-unprompted-by-default ()
  "Nothing asks for confirmation out of the box.

The prompt was mostly unanswerable anyway: a call arriving from a chat
runs inside a GLib dispatch where Lisp cannot prompt, so a gated tool was
declined rather than asked about, and every `:confirm' tool silently
failed on the surface that most used it."
  (skip-unless (featurep 'cmacs-brigade-tools))
  (should (eq t cmacs-brigade-auto-approve))
  (dolist (n '("agent_spawn" "agent_cancel" "project_write_file" "eval"))
    (should (cmacs-brigade--auto-approved-p n))))

(ert-deftest cmacs-brigade-wildcard-grants-everything-by-default ()
  "`*' hands over every tool, including the dangerous ones.

Shipped that way deliberately: it is the user's editor and their agents,
and the confirmation prompt that used to stand in front of these was
unanswerable anyway on the surface that reaches them."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (should-not cmacs-brigade-restrict-privileged-tools)
  (dolist (n '("eval" "shell" "bash" "execute_command" "send_keys"
               "crispy_eval" "bacon_eval" "cmacs_c_patch_defun"
               "project_write_file"))
    (should (cmacs-brigade-tool-allowed-p "*" n))))

(ert-deftest cmacs-brigade-privileged-restriction-is-available ()
  "Setting the variable puts the dangerous tools back behind naming.

The mechanism has to still work, or the escape hatch documented in the
docstring would be a lie."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (let ((cmacs-brigade-restrict-privileged-tools t))
    (dolist (n '("eval" "shell" "bash" "cmacs_c_patch_defun"))
      (should-not (cmacs-brigade-tool-allowed-p "*" n))
      ;; naming it outright is what grants it
      (should (cmacs-brigade-tool-allowed-p n n)))
    ;; ordinary tools are unaffected either way
    (should (cmacs-brigade-tool-allowed-p "*" "memory_search"))))

(ert-deftest cmacs-brigade-recursion-guard-is-separate-and-on ()
  "`ai_*' and `brigade_*' stay blocked, and are their own switch.

A different thing from the privileged set: those names re-enter the
orchestrator, so an agent that can call them starts work outside its own
budget accounting and can recurse into itself through `ai_call'.  The
`agent_*' tools are the sanctioned way through and are unaffected."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (should cmacs-brigade-block-recursive-tools)
  (should-not (cmacs-brigade-tool-allowed-p "*" "ai_call"))
  (should-not (cmacs-brigade-tool-allowed-p "*" "brigade_start"))
  (should (cmacs-brigade-tool-allowed-p "*" "agent_spawn"))
  ;; and it can be lifted on its own, without touching the other switch
  (let ((cmacs-brigade-block-recursive-tools nil))
    (should (cmacs-brigade-tool-allowed-p "*" "ai_call"))))

(ert-deftest cmacs-brigade-auto-approve-remains-a-user-choice ()
  "Narrowing to a list puts the confirmation back on what it omits."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let ((cmacs-brigade-auto-approve '("agent_status" "agent_result"))
        (cmacs-brigade-confirm-function nil))
    (should-not (cmacs-brigade--auto-approved-p "agent_spawn"))
    (let ((out (cmacs-brigade-call-tool "agent_spawn"
                                        "{\"task\":\"x\"}" "grok")))
      (should (string-match-p "needs approval" out)))))


;;;; The default agent, and where a spawn runs

(ert-deftest cmacs-brigade-ships-a-neutral-default-agent ()
  "An unqualified spawn gets `general', not whatever sorts first.

The fallback used to be the alphabetically first registered agent, so on
a machine with ~/.claude/agents every unqualified spawn silently
inherited a code reviewer's system prompt."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (should (eq 'general cmacs-brigade-subagent-default-agent))
  (let ((def (cmacs-brigade-agent-get 'general)))
    (should def)
    (should (equal "claude-code/sonnet" (plist-get def :model)))
    ;; neutral: it must not read as any particular speciality
    (should-not (string-match-p "review\\|critic\\|librarian"
                                (downcase (plist-get def :prompt))))))

(ert-deftest cmacs-brigade-default-agent-is-not-alphabetical-luck ()
  "`general' is chosen because it is named, not because it sorts first."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (cmacs-brigade-register-agent :name 'aaa-would-sort-first :prompt "p")
  ;; This one now sorts first, so the old fallback would pick it.  What
  ;; must hold is that the spawn still uses the named default.
  (should (eq 'aaa-would-sort-first
              (car (cmacs-brigade-registry-list 'agent))))
  (let ((dir (file-name-as-directory (make-temp-file "brigade-def" t))))
    (unwind-protect
        (let ((cmacs-brigade-plan-directory dir)
              (cmacs-brigade-subagent-plan (expand-file-name "s.org" dir)))
          (cl-letf (((symbol-function 'cmacs-brigade-start-task) #'ignore))
            (let ((id (cmacs-brigade-subagent-spawn nil "x")))
              (should (equal "general"
                             (plist-get (cmacs-brigade-task-get id) :agent))))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p dir (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory dir t))))

(ert-deftest cmacs-brigade-spawn-records-where-it-came-from ()
  "The spawn's directory is recorded, not the plan file's.

Captured before the plan buffer is opened: inside that
`with-current-buffer', `default-directory' is the notes tree, which is
what a spawn was previously recording and running in."
  (skip-unless (featurep 'cmacs-brigade-subagent))
  (let* ((root (file-name-as-directory (make-temp-file "brigade-cwd" t)))
         (plans (expand-file-name "plans/" root))
         (proj (expand-file-name "proj/" root)))
    (unwind-protect
        (progn
          (make-directory plans t)
          (make-directory proj t)
          (let ((cmacs-brigade-plan-directory plans)
                (cmacs-brigade-subagent-plan (expand-file-name "s.org" plans)))
            (cl-letf (((symbol-function 'cmacs-brigade-start-task) #'ignore))
              (let* ((default-directory proj)
                     (id (cmacs-brigade-subagent-spawn nil "x"))
                     (rec (cmacs-brigade-task-get id)))
                (should (equal (file-truename proj)
                               (file-truename (cmacs-brigade--task-cwd rec))))
                ;; and it is read from the record, so the buffer that
                ;; happens to be current when the task starts is
                ;; irrelevant -- which is the actual bug
                (let ((default-directory temporary-file-directory))
                  (should (equal (file-truename proj)
                                 (file-truename
                                  (cmacs-brigade--task-cwd rec)))))))))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b)
                   (string-prefix-p root (buffer-file-name b)))
          (with-current-buffer b (set-buffer-modified-p nil))
          (kill-buffer b)))
      (delete-directory root t))))

(ert-deftest cmacs-brigade-usage-counts-cache-tokens ()
  "Cache creation and reads are billed, so they are counted.

A \"say ok\" turn reports ten input tokens against twenty-eight thousand
cache-creation and twenty-two thousand cache-read.  Counting only
input_tokens made the cost look two orders of magnitude wrong when it
was the token figure that was incomplete."
  (skip-unless (and (featurep 'cmacs-brigade-run)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (let ((id "usage-cache-probe"))
    (cmacs-brigade-task-adopt id "p.org" nil "t")
    (unwind-protect
        (progn
          (cmacs-brigade--parse-cli-report
           (concat "{\"result\":\"ok\",\"num_turns\":1,"
                   "\"total_cost_usd\":0.0587,"
                   "\"usage\":{\"input_tokens\":10,\"output_tokens\":48,"
                   "\"cache_creation_input_tokens\":28123,"
                   "\"cache_read_input_tokens\":21739}}")
           id)
          (let ((r (cmacs-brigade-task-get id)))
            (should (= 49872 (plist-get r :in-tokens)))
            (should (= 48 (plist-get r :out-tokens)))
            (should (= 58700 (plist-get r :cost-micros)))))
      (ignore-errors (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-usage-without-cache-fields-still-works ()
  "A provider that reports no cache figures is unaffected."
  (skip-unless (and (featurep 'cmacs-brigade-run)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (let ((id "usage-plain-probe"))
    (cmacs-brigade-task-adopt id "p.org" nil "t")
    (unwind-protect
        (progn
          (cmacs-brigade--parse-cli-report
           "{\"result\":\"ok\",\"usage\":{\"input_tokens\":7,\"output_tokens\":9}}"
           id)
          (let ((r (cmacs-brigade-task-get id)))
            (should (= 7 (plist-get r :in-tokens)))
            (should (= 9 (plist-get r :out-tokens)))))
      (ignore-errors (cmacs-brigade-task-forget id)))))

(ert-deftest cmacs-brigade-e2e-inproc-points-tools-at-the-task-directory ()
  "The in-process worker runs the built-in tools where the task lives.

The cwd argument used to be ignored outright, so an agent told to work
in one tree resolved every relative path -- and ran every shell command
-- against whatever directory Emacs happened to be in.  That is how a
`bash' tool came to run a build in the wrong repository."
  (skip-unless (cmacs-brigade-run-tests--available-p))
  (cmacs-brigade-register-agent
   :name 'e2e-cwd-agent :prompt "p" :model "claude/some-model"
   :worker 'inproc :isolation 'none)
  (let ((where (make-temp-file "brigade-cwd" t))
        got)
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-ai-make-session)
                   (lambda (&rest _) (cons 1 2)))
                  ((symbol-function 'cmacs-ai-free-session) #'ignore)
                  ((symbol-function 'cmacs-ai-tools-new) (lambda () 99))
                  ((symbol-function 'cmacs-ai-tools-free) #'ignore)
                  ((symbol-function 'cmacs-brigade-install-tools)
                   (lambda (&rest _) 0))
                  ((symbol-function 'cmacs-ai-session-append-message) #'ignore)
                  ((symbol-function 'cmacs-ai-tools-set-working-directory)
                   (lambda (_e dir) (setq got dir)))
                  ((symbol-function 'cmacs-ai-tools-run-async)
                   (lambda (_s _e cb) (funcall cb '(:text "ok")))))
          (cmacs-brigade--worker-inproc
           "t1" (cmacs-brigade-agent-get 'e2e-cwd-agent) "do it"
           where nil nil)
          (should (equal got where)))
      (delete-directory where t))))

(provide 'cmacs-brigade-run-tests)

;;; cmacs-brigade-run-tests.el ends here

(ert-deftest cmacs-brigade-dashboard-render-follows-the-task-not-the-line ()
  "Point stays on the same task when a redraw renumbers the rows.

Rows are sorted with live tasks first, so a task changing state moves the
others under the cursor.  Restoring by line number put the cursor on
whatever had taken that row -- and then a command acted on the wrong
task, or on none."
  (skip-unless (and (featurep 'cmacs-brigade-dashboard)
                    (fboundp 'cmacs-brigade-task-adopt)))
  (let ((a "dash-follow-a") (b "dash-follow-b"))
    (unwind-protect
        (progn
          (cmacs-brigade-task-adopt a "p.org" "general" "Aaa")
          (cmacs-brigade-task-adopt b "p.org" "general" "Bbb")
          (with-current-buffer (get-buffer-create "*brigade*")
            (cmacs-brigade-dashboard-mode)
            (cmacs-brigade-dashboard--render)
            (goto-char (cmacs-brigade-dashboard--pos-of-id b))
            (should (equal b (plist-get (cmacs-brigade-dashboard--record-at-point)
                                        :id)))
            ;; Make the other one live, which sorts it above and shifts
            ;; every row below it.
            (cmacs-brigade-task-transition a 'queued)
            (cmacs-brigade-task-transition a 'starting)
            (cmacs-brigade-task-transition a 'running)
            (cmacs-brigade-dashboard--render)
            (should (equal b (plist-get (cmacs-brigade-dashboard--record-at-point)
                                        :id)))))
      (ignore-errors (cmacs-brigade-task-forget a))
      (ignore-errors (cmacs-brigade-task-forget b))
      (when (get-buffer "*brigade*") (kill-buffer "*brigade*")))))

(ert-deftest cmacs-brigade-dashboard-render-defers-under-a-prompt ()
  "A redraw never erases the buffer while a prompt is open.

The heartbeat fires every couple of seconds regardless of what you are
doing.  Redrawing under an open minibuffer moved point out from under the
command about to act on it, so answering a prompt ended in \"No task on
this line\"."
  (skip-unless (featurep 'cmacs-brigade-dashboard))
  (let ((id "dash-defer-1"))
    (unwind-protect
        (progn
          (cmacs-brigade-task-adopt id "p.org" "general" "Ccc")
          (with-current-buffer (get-buffer-create "*brigade*")
            (cmacs-brigade-dashboard-mode)
            (cmacs-brigade-dashboard--render)
            (let ((before (buffer-string)))
              (cl-letf (((symbol-function 'minibuffer-window-active-p)
                         (lambda (&rest _) t)))
                (cmacs-brigade-task-forget id)
                (cmacs-brigade-dashboard--render))
              ;; Untouched: the row for a task that no longer exists is
              ;; still there, because nothing was allowed to redraw.
              (should (equal before (buffer-string))))))
      (ignore-errors (cmacs-brigade-task-forget id))
      (when (get-buffer "*brigade*") (kill-buffer "*brigade*")))))

(ert-deftest cmacs-brigade-dashboard-send-acts-on-the-task-it-asked-about ()
  "The id is carried from the prompt, not re-read from point afterwards."
  (skip-unless (and (featurep 'cmacs-brigade-dashboard)
                    (fboundp 'cmacs-brigade-mailbox-send)))
  (let ((sent nil))
    (cl-letf (((symbol-function 'cmacs-brigade-mailbox-send)
               (lambda (id text &rest _) (push (cons id text) sent)))
              ((symbol-function 'cmacs-brigade-mailbox-count) (lambda (_) 1))
              ((symbol-function 'cmacs-brigade-dashboard-refresh) #'ignore)
              ;; Point is nowhere useful, as it would be after the rows
              ;; moved while the prompt was open.
              ((symbol-function 'cmacs-brigade-dashboard--record-or-error)
               (lambda () (error "should not be consulted"))))
      (cmacs-brigade-dashboard-send "carry on" "explicit-id")
      (should (equal '(("explicit-id" . "carry on")) sent)))))
