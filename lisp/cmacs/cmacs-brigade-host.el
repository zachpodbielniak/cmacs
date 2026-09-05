;;; cmacs-brigade-host.el --- Scoped tool access for agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Gives an agent a way to reach cmacs's tools, scoped to what it is
;; allowed, and takes it away again when the run ends.
;;
;; The arrangement: open a per-agent *scoped socket* in cmacs that
;; serves only the agent's expanded allowlist (`cmacs-brigade-scope-open',
;; enforced by the C gate inside the editor), write a 0600 `.mcp.json'
;; naming `emacs --mcp-relay' with that socket, the allowlist and the
;; gate's policy in its env block, and hand the path to the worker.  The
;; relay applies the same allowlist again in a process with no Lisp VM;
;; the socket is what makes the provision a capability rather than a
;; suggestion, because an agent that reaches it directly still gets only
;; the scoped surface.
;;
;; Three decisions worth knowing:
;;
;;   - The capability is the socket, not a string.  An earlier version
;;     minted a random token that nothing ever verified, next to the
;;     path of the unrestricted cmacs-mcp-<pid>.sock: a shell was all it
;;     took to walk around the relay.  A token is still minted and
;;     exported (CMACS_BRIGADE_TOKEN) for callers that key on it, but
;;     nothing about access depends on it.
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

(defun cmacs-brigade-host--config-claude (command args env)
  "Claude Code's .mcp.json shape."
  (list :mcpServers
        (list :cmacs
              (list :command command
                    :args (vconcat args)
                    :env env))))

(defun cmacs-brigade-host--config-opencode (command args env)
  "opencode's own shape, which is not Claude's.

Servers nest under `mcp', a local one is spelled with an explicit
`type', and the whole command lives in one array rather than being split
into command and args.  A Claude-shaped file handed to opencode is
silently ignored, which is why the dialect is chosen per provider rather
than written once and hoped over."
  (list :$schema "https://opencode.ai/config.json"
        :mcp
        (list :cmacs
              (list :type "local"
                    :command (vconcat (cons command args))
                    :enabled t
                    :environment env))))

(defun cmacs-brigade-host--config-grok (command args env)
  "A TOML fragment declaring one [mcp_servers.*] table.

The server is named `cmacs-brigade\=' here and plain `cmacs\=' in the
claude and opencode emitters.  That reads as gratuitous inconsistency
and is not.  grok resolves its config sources by merging them per server
NAME, and a name that also appears in a project-scoped source -- a
repository\='s own .mcp.json -- makes the merged entry repo-local even
when the surviving definition came from the global config.  Repo-local
servers are not started in a folder absent from
~/.grok/trusted_folders.toml, silently and with no error anyone can see.
cmacs\='s own repository ships a git-tracked .mcp.json whose server is
spelled exactly `cmacs\=', and the harness runs the agent in the project
root -- so the obvious name is the one name guaranteed to fail there.

claude and opencode are unaffected: they read a dedicated config file,
which is neither merged by name nor subject to a trust gate.

A mitigation, not a guarantee -- a project whose .mcp.json happens to
use `cmacs-brigade\=' reintroduces it.  Nothing on this side can detect
that; only `grok mcp doctor NAME --json\=' reports the truth.

Returned as a string rather than a plist: grok reads TOML, and the
provider appends this to a copy of the user's own config."
  (concat "\n[mcp_servers.cmacs-brigade]\n"
          (format "command = %S\n" command)
          (format "args = [%s]\n"
                  (mapconcat (lambda (a) (format "%S" a)) args ", "))
          (if env
              (concat "\n[mcp_servers.cmacs-brigade.env]\n"
                      (mapconcat
                       (lambda (pair)
                         (format "%s = %S" (car pair) (cdr pair)))
                       env "\n")
                      "\n")
            "")))

(defconst cmacs-brigade-host-config-formats
  '((claude   . cmacs-brigade-host--config-claude)
    (opencode . cmacs-brigade-host--config-opencode)
    (grok     . cmacs-brigade-host--config-grok))
  "Dialect emitters, keyed by format symbol.

This table is the registration: teaching the host about another agent's
config schema is one entry and one function.  The *delivery* -- which
flag or variable carries the file -- belongs to ai-glib's provider, not
here.")

(defun cmacs-brigade-host-format-for-provider (provider)
  "Return the config format symbol PROVIDER reads."
  (pcase (and provider (intern (format "%s" provider)))
    ((or 'opencode 'open-code) 'opencode)
    ((or 'grok-build 'grok_build) 'grok)
    (_ 'claude)))

(defun cmacs-brigade-host-endpoint-kind (format)
  "Return the ai-glib endpoint kind naming FORMAT's dialect."
  (pcase format
    ('opencode "mcp-config-opencode")
    ('grok     "mcp-config-grok")
    (_         "mcp-config")))

(cl-defun cmacs-brigade-host-provision (agent-id allowlist &key format)
  "Provision scoped tool access for AGENT-ID limited to ALLOWLIST.

Returns a plist with :path (the MCP config), :token and :format, or nil
when the MCP server is unavailable.  ALLOWLIST is expanded here, in the
process that owns the tool registry -- the relay has none of its own, so
a group name reaching it would match nothing, silently.

FORMAT names the config dialect to emit, defaulting to `claude'.  It
exists because the agents do not agree on one: opencode nests servers
under `mcp' with a different server shape, grok reads TOML.  The dialect
belongs here, with the credential lifecycle, rather than in each
frontend -- a second writer would be a second place that has to agree
about the 0600 write, the revoke-before-provision and the sweep."
  (unless (and (fboundp 'cmacs-mcp-socket-path) (cmacs-mcp-socket-path))
    (cl-return-from cmacs-brigade-host-provision nil))
  (cmacs-brigade-host-sweep-stale)
  ;; Revoke first: a half-finished provision must not leave the old
  ;; token live with nothing naming it.
  (cmacs-brigade-host-revoke agent-id)
  (let* ((dir cmacs-brigade-runtime-dir)
         ;; Filename is a random uuid rather than the agent id: ids end
         ;; up in prompts and logs, and a path is a disclosure.
         ;; The pid is in the name so a crash leaves something a later
         ;; session can identify as dead and remove.  It is not a secret,
         ;; is not derived from the agent, and the uuid still carries all
         ;; the unguessability -- which is why the uuid is there at all:
         ;; ids reach prompts and logs, and a path is a disclosure.
         (path (expand-file-name (format "mcp-%d-%s.json"
                                         (emacs-pid) (cmacs-brigade--uuid))
                                 dir))
         (token (cmacs-brigade--uuid))
         (expanded (if (fboundp 'cmacs-brigade-allowlist-expand)
                       (cmacs-brigade-allowlist-expand (or allowlist ""))
                     (or allowlist "")))
         (fmt (or format 'claude))
         (emit (or (alist-get fmt cmacs-brigade-host-config-formats)
                   #'cmacs-brigade-host--config-claude))
         ;; The scoped socket is the enforcement; the relay's copy of the
         ;; allowlist below is defence in depth.  Without the DEFUN (an
         ;; MCP-less build) the plain socket is used and the relay is the
         ;; only gate, which is what it always was.
         (scope (cmacs-brigade-host--open-scope expanded))
         (socket (or scope (cmacs-mcp-socket-path)))
         ;; The gate's two settings travel with the allowlist so the
         ;; relay -- which has no Lisp VM and cannot read them -- reaches
         ;; the same answers the editor does.
         (restrict (if (bound-and-true-p cmacs-brigade-restrict-privileged-tools)
                       "1" "0"))
         (block (if (and (boundp 'cmacs-brigade-block-recursive-tools)
                         (not cmacs-brigade-block-recursive-tools))
                    "0" "1"))
         (env (list :CMACS_BRIGADE_SOCKET socket
                    :CMACS_BRIGADE_ALLOW expanded
                    :CMACS_BRIGADE_TOKEN token
                    :CMACS_BRIGADE_RESTRICT_PRIVILEGED restrict
                    :CMACS_BRIGADE_BLOCK_RECURSIVE block))
         (config (funcall emit (cmacs-brigade--relay-command)
                          (list "--mcp-relay")
                          (if (eq fmt 'grok)
                              ;; TOML wants an alist, not a plist.
                              (list (cons "CMACS_BRIGADE_SOCKET" socket)
                                    (cons "CMACS_BRIGADE_ALLOW" expanded)
                                    (cons "CMACS_BRIGADE_TOKEN" token)
                                    (cons "CMACS_BRIGADE_RESTRICT_PRIVILEGED"
                                          restrict)
                                    (cons "CMACS_BRIGADE_BLOCK_RECURSIVE"
                                          block))
                            env))))
    (make-directory dir t)
    (set-file-modes dir #o700)
    ;; `with-file-modes' sets the umask for the duration, so the file is
    ;; created 0600 rather than created world-readable and tightened a
    ;; moment later.  That moment is when a token is readable by anything
    ;; on the machine, and it is entirely avoidable.
    (with-file-modes #o600
      (with-temp-file path
        (insert (if (stringp config) config (json-serialize config)))))
    (puthash agent-id (list :path path :token token :format fmt
                            :scope scope :socket socket)
             cmacs-brigade--provisions)
    (list :path path :token token :format fmt :scope scope :socket socket)))

(defun cmacs-brigade-host--open-scope (allowlist)
  "Open a scoped socket serving ALLOWLIST, or nil when unavailable.
Failure is reported, not signalled: a provision without a scope still
works through the relay, and refusing to run an agent because a socket
could not be bound would be the wrong trade."
  (when (fboundp 'cmacs-brigade-scope-open)
    (condition-case err
        (cmacs-brigade-scope-open allowlist)
      (error
       (message "cmacs-brigade: scoped socket unavailable, relay-only: %s"
                (error-message-string err))
       nil))))

(defun cmacs-brigade-host-revoke (agent-id)
  "Withdraw AGENT-ID's tool access.  Returns non-nil if there was any."
  (let ((p (gethash agent-id cmacs-brigade--provisions)))
    (when p
      (ignore-errors (delete-file (plist-get p :path)))
      (when (and (plist-get p :scope) (fboundp 'cmacs-brigade-scope-close))
        (ignore-errors (cmacs-brigade-scope-close (plist-get p :scope))))
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

(defcustom cmacs-brigade-host-stale-age 300
  "Seconds before an orphaned MCP config may be swept.

`process-attributes' returning nil is a weaker liveness signal than
kill(2)'s EPERM rule -- it cannot distinguish a dead pid from one this
Emacs may not inspect -- so age is required as well.  A live provision
is rewritten on every run, so a file this old whose owner is gone is
genuinely abandoned."
  :type 'integer
  :group 'cmacs-brigade)

(defvar cmacs-brigade-host--swept nil
  "Whether the stale sweep has run in this session.")

(defun cmacs-brigade-host-sweep-stale ()
  "Remove MCP configs left by cmacs processes that are gone.

`cmacs-brigade--provisions' is in-memory only, so a crash -- or, under
--gowl, a compositor death -- leaves 0600 files naming a socket nobody
is listening on.  Each is a live capability token that no longer has an
owner, and a harness that provisions per buffer multiplies them.

Mirrors `cmacs_mcp_sweep_stale_sockets', which solves the same problem
for the sockets themselves by reading a pid out of the filename.
Deliberately ignores the older uuid-only shape, which carries no pid to
judge by."
  (unless cmacs-brigade-host--swept
    (setq cmacs-brigade-host--swept t)
    (let ((dir cmacs-brigade-runtime-dir)
          (now (float-time))
          (n 0))
      (when (file-directory-p dir)
        ;; Configs and scoped sockets share the mcp-<pid>-<uuid> shape;
        ;; a socket whose owner is gone has nobody listening on it.
        (dolist (f (directory-files dir t "\\`mcp-[0-9]+-.*\\.\\(?:json\\|sock\\)\\'"))
          (when (string-match "mcp-\\([0-9]+\\)-" (file-name-nondirectory f))
            (let ((pid (string-to-number (match-string 1 (file-name-nondirectory f))))
                  (age (- now (float-time (file-attribute-modification-time
                                           (file-attributes f))))))
              (when (and (/= pid (emacs-pid))
                         (null (process-attributes pid))
                         (> age cmacs-brigade-host-stale-age))
                (ignore-errors (delete-file f))
                (setq n (1+ n)))))))
      n)))

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
