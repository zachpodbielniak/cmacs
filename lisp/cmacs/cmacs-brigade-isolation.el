;;; cmacs-brigade-isolation.el --- Where an agent may make a mess  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three shipped backends -- `none', `worktree' and `podman' -- all
;; registered through the same public API a user would use to add a
;; fourth.
;;
;; Worktrees go outside the repository being worked on.  A worktree under
;; the repo is walked by every other agent's `rg' and `find', which turns
;; every search into duplicate hits across sibling checkouts and quietly
;; degrades everything.
;;
;; Every teardown tolerates being called twice and being called after a
;; prepare that failed halfway, because it runs from an unwind path --
;; which is exactly when the state is least predictable, and a backend
;; that only cleans up after a tidy success is one that leaks after every
;; interesting failure.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)

(defcustom cmacs-brigade-podman-image "fedora:latest"
  "Container image used by the `podman' isolation backend."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-podman-program "podman"
  "Container program.  Podman rather than docker: rootless by default."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-worktree-build nil
  "Whether an agent worktree is expected to be buildable.

Off by default.  A fresh worktree of a large C project needs a full
rebuild before anything compiles, which for cmacs is roughly twenty
minutes -- worth paying deliberately, never by accident because an agent
happened to be given a worktree."
  :type 'boolean
  :group 'cmacs-brigade)


;;;; none

(defun cmacs-brigade-isolation--none-prepare (_agent-id)
  (list :cwd default-directory :env nil))

(cmacs-brigade-register-isolation
 :name 'none
 :prepare #'cmacs-brigade-isolation--none-prepare
 :teardown #'ignore
 :describe (lambda () "no isolation"))


;;;; worktree

(defun cmacs-brigade-isolation--worktree-path (agent-id)
  (expand-file-name (format "agent-%s" agent-id)
                    cmacs-brigade-worktree-root))

(defun cmacs-brigade-isolation--worktree-prepare (agent-id)
  "Create a git worktree for AGENT-ID and return where it should run."
  (let* ((repo (or (vc-root-dir) default-directory))
         (dest (cmacs-brigade-isolation--worktree-path agent-id))
         (branch (format "brigade/%s" agent-id)))
    (unless (executable-find "git")
      (user-error "cmacs-brigade: worktree isolation needs git"))
    (make-directory cmacs-brigade-worktree-root t)
    ;; Leftovers from an interrupted run would make `git worktree add'
    ;; fail on a path that already exists.
    (cmacs-brigade-isolation--worktree-teardown agent-id)
    (let ((default-directory repo))
      (unless (zerop (call-process "git" nil nil nil
                                   "worktree" "add" "-b" branch dest "HEAD"))
        (user-error "cmacs-brigade: could not create a worktree at %s" dest)))
    (list :cwd (file-name-as-directory dest)
          :env (list (cons "CMACS_BRIGADE_WORKTREE" dest)
                     (cons "CMACS_BRIGADE_BRANCH" branch)))))

(defun cmacs-brigade-isolation--worktree-teardown (agent-id)
  "Remove AGENT-ID's worktree.  Safe on a path that was never created."
  (let* ((repo (or (vc-root-dir) default-directory))
         (dest (cmacs-brigade-isolation--worktree-path agent-id)))
    (when (file-directory-p dest)
      (let ((default-directory repo))
        ;; `git worktree remove' refuses when the checkout is dirty, and
        ;; an agent's worktree usually is -- that is the point of it.
        ;; Force, then prune the administrative entry the removal leaves
        ;; behind.
        (ignore-errors
          (call-process "git" nil nil nil "worktree" "remove" "--force" dest))
        (when (file-directory-p dest) (delete-directory dest t))
        (ignore-errors (call-process "git" nil nil nil "worktree" "prune"))))))

(cmacs-brigade-register-isolation
 :name 'worktree
 :prepare #'cmacs-brigade-isolation--worktree-prepare
 :teardown #'cmacs-brigade-isolation--worktree-teardown
 :describe (lambda () "git worktree"))


;;;; podman

(defun cmacs-brigade-isolation--podman-name (agent-id)
  (format "cmacs-brigade-%s" agent-id))

(defun cmacs-brigade-isolation--podman-prepare (agent-id)
  "Start a container for AGENT-ID."
  (unless (executable-find cmacs-brigade-podman-program)
    (user-error "cmacs-brigade: container isolation needs %s"
                cmacs-brigade-podman-program))
  (let ((name (cmacs-brigade-isolation--podman-name agent-id)))
    (cmacs-brigade-isolation--podman-teardown agent-id)
    (unless (zerop (call-process cmacs-brigade-podman-program nil nil nil
                                 "run" "-d" "--name" name
                                 "--network" "none"
                                 cmacs-brigade-podman-image
                                 "sleep" "infinity"))
      (user-error "cmacs-brigade: could not start container %s" name))
    (list :cwd default-directory
          :env (list (cons "CMACS_BRIGADE_CONTAINER" name)))))

(defun cmacs-brigade-isolation--podman-teardown (agent-id)
  "Remove AGENT-ID's container if there is one."
  (when (executable-find cmacs-brigade-podman-program)
    (ignore-errors
      (call-process cmacs-brigade-podman-program nil nil nil
                    "rm" "-f" (cmacs-brigade-isolation--podman-name agent-id)))))

(cmacs-brigade-register-isolation
 :name 'podman
 :prepare #'cmacs-brigade-isolation--podman-prepare
 :teardown #'cmacs-brigade-isolation--podman-teardown
 :describe (lambda () "podman container"))


;;;; Dispatch

(defun cmacs-brigade-isolation-prepare (kind agent-id)
  "Prepare KIND isolation for AGENT-ID.  Returns a plist with :cwd/:env."
  (let ((iso (cmacs-brigade-registry-get 'isolation (or kind 'none))))
    (unless iso
      (user-error "cmacs-brigade: no isolation backend named %s" kind))
    (funcall (plist-get iso :prepare) agent-id)))

(defun cmacs-brigade-isolation-teardown (kind agent-id)
  "Tear down KIND isolation for AGENT-ID.  Never signals."
  (let ((iso (cmacs-brigade-registry-get 'isolation (or kind 'none))))
    (when iso
      (condition-case err
          (funcall (or (plist-get iso :teardown) #'ignore) agent-id)
        (error
         ;; Teardown failing must not mask whatever failure brought us
         ;; here; report and continue.
         (message "cmacs-brigade: %s teardown for %s failed: %s"
                  kind agent-id (error-message-string err)))))))

(defun cmacs-brigade-isolation-available-p (kind)
  "Return non-nil when KIND isolation can actually run here."
  (pcase kind
    ('none t)
    ('worktree (and (executable-find "git") t))
    ('podman (and (executable-find cmacs-brigade-podman-program) t))
    (_ (and (cmacs-brigade-registry-get 'isolation kind) t))))

(provide 'cmacs-brigade-isolation)

;;; cmacs-brigade-isolation.el ends here
