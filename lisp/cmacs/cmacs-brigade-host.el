;;; cmacs-brigade-host.el --- Scoped tool access for agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Gives an agent a way to reach cmacs's tools, scoped to what it is
;; allowed, and takes it away again when the run ends.
;;
;; The arrangement: mint a random token, write a 0600 `.mcp.json' naming
;; `emacs --mcp-relay' with that token and the agent's expanded
;; allowlist, and hand the path to the worker.  The relay enforces the
;; allowlist in a process with no Lisp VM.
;;
;; Three decisions worth knowing:
;;
;;   - The token is random, never derived from the agent's name or id.
;;     Agents quote their own context into prompts and logs constantly;
;;     a secret derived from something they know about themselves is a
;;     secret by construction only.
;;
;;   - The config goes in XDG_RUNTIME_DIR, not the workspace.  A
;;     `.mcp.json' in a project is user-authored, usually git-tracked,
;;     and shared by every agent -- writing there would clobber it and
;;     make concurrent agents race.
;;
;;   - Revoke runs before provision, not only at teardown.  A partial
;;     failure would otherwise leave the previous token valid with no
;;     file naming it, which is a credential nobody can find to remove.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-agent-def)
(require 'json)
(require 'cl-lib)

(defcustom cmacs-brigade-relay-command nil
  "Command the generated MCP config tells an agent to run.
Defaults to this cmacs binary with `--mcp-relay'."
  :type '(choice (const :tag "This cmacs binary" nil) string)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-token-ttl 3600
  "Seconds an agent's capability token remains valid.
Zero means it lasts as long as the run."
  :type 'integer
  :group 'cmacs-brigade)

(defvar cmacs-brigade--provisions (make-hash-table :test 'equal)
  "AGENT-ID -> plist of :path and :token for live provisions.")

(defun cmacs-brigade--relay-command ()
  "Return the command an agent should run to reach cmacs's tools."
  (or cmacs-brigade-relay-command
      (expand-file-name invocation-name invocation-directory)))

(cl-defun cmacs-brigade-host-provision (agent-id allowlist)
  "Provision scoped tool access for AGENT-ID limited to ALLOWLIST.

Returns a plist with :path (the MCP config) and :token, or nil when the
MCP server is unavailable.  ALLOWLIST is expanded here, in the process
that owns the tool registry -- the relay has none of its own, so a group
name reaching it would match nothing, silently."
  (unless (and (fboundp 'cmacs-mcp-socket-path) (cmacs-mcp-socket-path))
    (cl-return-from cmacs-brigade-host-provision nil))
  ;; Revoke first: a half-finished provision must not leave the old
  ;; token live with nothing naming it.
  (cmacs-brigade-host-revoke agent-id)
  (let* ((dir cmacs-brigade-runtime-dir)
         ;; Filename is a random uuid rather than the agent id: ids end
         ;; up in prompts and logs, and a path is a disclosure.
         (path (expand-file-name (format "mcp-%s.json" (cmacs-brigade--uuid))
                                 dir))
         (token (cmacs-brigade--uuid))
         (expanded (if (fboundp 'cmacs-brigade-allowlist-expand)
                       (cmacs-brigade-allowlist-expand (or allowlist ""))
                     (or allowlist "")))
         (config
          (list :mcpServers
                (list :cmacs
                      (list :command (cmacs-brigade--relay-command)
                            :args (vector "--mcp-relay")
                            :env (list :CMACS_BRIGADE_SOCKET
                                       (cmacs-mcp-socket-path)
                                       :CMACS_BRIGADE_ALLOW expanded
                                       :CMACS_BRIGADE_TOKEN token))))))
    (make-directory dir t)
    (set-file-modes dir #o700)
    ;; `with-file-modes' sets the umask for the duration, so the file is
    ;; created 0600 rather than created world-readable and tightened a
    ;; moment later.  That moment is when a token is readable by anything
    ;; on the machine, and it is entirely avoidable.
    (with-file-modes #o600
      (with-temp-file path
        (insert (json-serialize config))))
    (puthash agent-id (list :path path :token token)
             cmacs-brigade--provisions)
    (list :path path :token token)))

(defun cmacs-brigade-host-revoke (agent-id)
  "Withdraw AGENT-ID's tool access.  Returns non-nil if there was any."
  (let ((p (gethash agent-id cmacs-brigade--provisions)))
    (when p
      (ignore-errors (delete-file (plist-get p :path)))
      (remhash agent-id cmacs-brigade--provisions)
      t)))

(defun cmacs-brigade-host-revoke-all ()
  "Withdraw every live provision.  Returns how many."
  (interactive)
  (let ((n 0))
    (dolist (id (hash-table-keys cmacs-brigade--provisions))
      (when (cmacs-brigade-host-revoke id) (setq n (1+ n))))
    (when (called-interactively-p 'any)
      (message "cmacs-brigade: revoked %d provision(s)" n))
    n))

(defun cmacs-brigade--uuid ()
  "Return a random identifier."
  (if (fboundp 'org-id-uuid)
      (org-id-uuid)
    (format "%04x%04x-%04x-%04x-%04x-%06x%06x"
            (random 65536) (random 65536) (random 65536)
            (random 65536) (random 65536)
            (random 16777216) (random 16777216))))

;; Live provisions are credentials with a session lifetime; leaving the
;; files behind on exit would scatter tokens across XDG_RUNTIME_DIR.
(add-hook 'kill-emacs-hook #'cmacs-brigade-host-revoke-all)

(provide 'cmacs-brigade-host)

;;; cmacs-brigade-host.el ends here
