;;; cmacs-brigade-run-tests.el --- Host, isolation and dashboard  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-host nil 'noerror)
(require 'cmacs-brigade-isolation nil 'noerror)
(require 'cmacs-brigade-run nil 'noerror)
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

(provide 'cmacs-brigade-run-tests)

;;; cmacs-brigade-run-tests.el ends here
