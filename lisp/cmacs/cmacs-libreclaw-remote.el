;;; cmacs-libreclaw-remote.el --- Remote-mode libreclaw bridge for cmacs  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Where `cmacs-libreclaw' starts a libreclaw LcApp in-process, this
;; module dials *out* to a separately-running libreclaw server's
;; /api/v1/bridge WebSocket and tunnels cmacs's own MCP tool surface
;; back across so the remote agent can drive the local editor as if
;; it were local to the server.
;;
;; Quick start:
;;
;;     M-x cmacs-libreclaw-remote-connect RET
;;       wss://server.example/api/v1/bridge RET
;;       <bridge-token>                     RET
;;
;; Rooms surfaced by the remote server appear as org-mode buffers in
;; the same `cmacs-libreclaw-room-mode' used by the embedded path —
;; the bridge synthesises a channel-id of "bridge" so the existing
;; `cmacs-libreclaw--on-message' machinery picks them up unchanged.

;;; Code:

(require 'auth-source)
(require 'cmacs-libreclaw)

;; ── Variable safety net ──────────────────────────────────────────
;;
;; Bind every user-visible variable up front via defvar so that:
;;   1. They exist even if a later top-level form in this file
;;      fails to load (defcustom is below — load failures before
;;      it leave the vars unbound, which causes the dreaded
;;      "Symbol's value as variable is void" when callers reference
;;      them in interactive commands).
;;   2. Doom's native-compile race that snapshots an intermediate
;;      version of the file can't strand consumers; defvar runs
;;      before any defun in this file.
;;
;; defvar with a default is idempotent — it does NOT overwrite an
;; existing value, so subsequent `defcustom' or user `setq' calls
;; still take effect and the customize metadata still attaches.

(defvar cmacs-libreclaw-remote-mcp-servers '(cmacs))
(defvar cmacs-libreclaw-remote-display-name nil)
(defvar cmacs-libreclaw-remote-local-room-id "local")
(defvar cmacs-libreclaw-remote-local-room-name "Bridge")
(defvar cmacs-libreclaw-remote-save-conversations-dir nil)
(defvar cmacs-libreclaw-remote-save-conversations-name-format
  "%y%m%d-%H%M%S-<agent-name>.org")

;; The C primitives below are provided by cmacs/libreclaw/cmacs-libreclaw-remote.c.
(declare-function cmacs-libreclaw-remote--connect-internal
                  "cmacs-libreclaw-remote.c"
                  (url token &optional display-name endpoints user-id))
(declare-function cmacs-libreclaw-remote-disconnect
                  "cmacs-libreclaw-remote.c" ())
(declare-function cmacs-libreclaw-remote-connected-p
                  "cmacs-libreclaw-remote.c" ())
(declare-function cmacs-libreclaw-remote-agent-name
                  "cmacs-libreclaw-remote.c" ())
(declare-function cmacs-libreclaw-remote-send-message
                  "cmacs-libreclaw-remote.c"
                  (room-id body &optional html-body))

(defgroup cmacs-libreclaw-remote nil
  "Remote-mode libreclaw bridge for cmacs."
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-remote-mcp-servers '(cmacs)
  "List of MCP endpoint specs to expose to the remote libreclaw.

Currently only the symbol `cmacs' is honoured by the C side: it
wraps cmacs's own MCP tool / resource / prompt surface as endpoint
id \"cmacs\".  Other spec kinds (`:stdio CMD', `:unix-socket PATH',
`:ws URL') are reserved for future versions; entries the C side
doesn't recognise are silently ignored."
  :type '(repeat sexp)
  :group 'cmacs-libreclaw-remote)

(defcustom cmacs-libreclaw-remote-display-name nil
  "Display name advertised to the remote libreclaw server.
nil sends a generic identifier."
  :type '(choice (const :tag "Generic" nil) string)
  :group 'cmacs-libreclaw-remote)

(defcustom cmacs-libreclaw-remote-user-id nil
  "Stable `sender_id' stamped on every outbound bridge chat message.

When non-nil, this value is sent as `sender_id' in every
`chat.message_out' frame the bridge client emits.  The libreclaw
server uses it to match against
`session.command_allowed_users' and `messages.command_allowed_users'
when deciding whether the sender may run `!session'-class or
`!message'-class bot commands (`!close_session', `!swap_model',
`!stop', `!status', etc.).

When nil, `cmacs-libreclaw-remote-connect' resolves the sender id
at connect time via `cmacs-libreclaw-remote--default-user-id',
which returns the $USER env var (falling back to
`user-login-name', then to nil).  If even that yields nil, the
server falls back to the bridge id (`bridge:<key-name>:<seq>') as
the sender, which changes on every reconnect and is therefore
awkward to reference in config.

Set this explicitly if your shell user does not match the identity
you want listed in the server's `command_allowed_users' (e.g. the
matrix-style \"@zach:matrix.example.com\" form).

Examples:
  \"zach\"
  \"@zach:matrix.example.com\""
  :type '(choice (const :tag "$USER (default)" nil) string)
  :group 'cmacs-libreclaw-remote)

(defun cmacs-libreclaw-remote--default-user-id ()
  "Resolve the default sender id when the defcustom is left nil.
Order: $USER env var, then `user-login-name', then nil.  Returns
nil only if both produce no usable value, in which case the
libreclaw server falls back to the bridge id as the sender."
  (let ((env (getenv "USER")))
    (cond
     ((and env (not (string-empty-p env))) env)
     ((let ((lname (user-login-name)))
        (and lname (not (string-empty-p lname)) lname)))
     (t nil))))

(defcustom cmacs-libreclaw-remote-local-room-id "local"
  "Room id used by `cmacs-libreclaw-remote-chat'.
This is an arbitrary string the cmacs side picks; the server-side
`LcBridgeChannel' decodes the resulting `chat.message_out' frame
and emits `LcChannel::message-received' with this id as the room.
The session manager keys sessions on (channel . room . sender), so
two cmacs instances both using \"local\" against the same bridge
get distinct sessions (their bridge ids differ)."
  :type 'string
  :group 'cmacs-libreclaw-remote)

(defcustom cmacs-libreclaw-remote-local-room-name "Bridge"
  "Display name for the `cmacs-libreclaw-remote-chat' buffer."
  :type 'string
  :group 'cmacs-libreclaw-remote)

(defcustom cmacs-libreclaw-remote-save-conversations-dir nil
  "Directory to which remote-bridge conversations are archived.

When non-nil, every remote-mode room buffer (channel id
\"bridge\") is mirrored to a standalone `.org' file in this
directory.  The file is rewritten as messages arrive and again
when the room buffer is killed, so it always reflects the full
conversation.

This setting is independent of the embedded-mode
`cmacs-libreclaw-save-conversations-dir' — point them at the
same directory or at different ones as you like.  Leave nil
\(the default) to disable archiving for remote mode.

The file name is built from
`cmacs-libreclaw-remote-save-conversations-name-format'."
  :type '(choice (const :tag "Disabled" nil) directory)
  :group 'cmacs-libreclaw-remote)

(defcustom cmacs-libreclaw-remote-save-conversations-name-format
  "%y%m%d-%H%M%S-<agent-name>.org"
  "File-name format for archived remote-bridge conversations.

Used only when `cmacs-libreclaw-remote-save-conversations-dir' is
set.  The string is first passed through `format-time-string'
with the conversation's start time (so the usual `%y', `%m',
`%d', `%H', `%M', `%S' directives all work), and then the
literal token `<agent-name>' is replaced with the remote agent's
name as reported by `cmacs-libreclaw-remote-agent-name' (the
`agent.name' from the remote server's config, queried over the
bridge API).

The default yields names like `260522-143015-claude.org'."
  :type 'string
  :group 'cmacs-libreclaw-remote)

(defvar cmacs-libreclaw-remote--last-url nil
  "URL of the most recently configured remote bridge, for redisplay.")

;;;; URL normalisation

(defun cmacs-libreclaw-remote--normalize-url (input)
  "Normalize bridge-connect shorthand INPUT to a full WebSocket URL.

Rules (applied in order):
- If INPUT has no scheme, prepend `ws://'.
- If the resulting scheme is `ws://' and no explicit port is
  given, append `:7077' (the libreclaw bridge default).  For
  `wss://' we do NOT add a port — the user is almost certainly
  going through a TLS-terminating reverse proxy on the standard
  443.
- If the URL has no path or only `/', append `/api/v1/bridge'
  (the libreclaw bridge default upgrade path).

Examples:
  \"libreclaw-00\"            → \"ws://libreclaw-00:7077/api/v1/bridge\"
  \"libreclaw-00:8888\"       → \"ws://libreclaw-00:8888/api/v1/bridge\"
  \"wss://bridge.example.com\" → \"wss://bridge.example.com/api/v1/bridge\"
  \"ws://host:9000/custom\"   → unchanged"
  (let ((s (string-trim input)))
    (unless (string-match-p "\\`[a-z][a-z0-9+.-]*://" s)
      (setq s (concat "ws://" s)))
    (string-match
     "\\`\\([a-z][a-z0-9+.-]*://\\)\\([^/]*\\)\\(/.*\\)?\\'" s)
    (let ((scheme   (match-string 1 s))
          (hostport (or (match-string 2 s) ""))
          (path     (or (match-string 3 s) "")))
      (when (and (string= scheme "ws://")
                 (not (string-match-p ":[0-9]+\\'" hostport)))
        (setq hostport (concat hostport ":7077")))
      (when (or (string-empty-p path) (string= path "/"))
        (setq path "/api/v1/bridge"))
      (concat scheme hostport path))))

;;;; Token storage via auth-source

(defun cmacs-libreclaw-remote--read-token (url)
  "Look up the bearer token for URL in `auth-source', prompting if absent.
URL should already be normalised (call
`cmacs-libreclaw-remote--normalize-url' first if needed)."
  (let* ((parsed (url-generic-parse-url url))
         (host (or (url-host parsed) "libreclaw-bridge"))
         (port (or (url-port parsed) "bridge"))
         (entry (car (auth-source-search :host host :port (format "%s" port)
                                         :require '(:secret)
                                         :max 1
                                         :create t)))
         (secret (plist-get entry :secret)))
    (when (functionp secret) (setq secret (funcall secret)))
    (or secret
        (read-passwd (format "Bridge token for %s: " host)))))

;;;; Public commands

;;;###autoload
(defun cmacs-libreclaw-remote-connect (url &optional token)
  "Open the remote libreclaw bridge.

URL may be a full WebSocket URL or a shorthand:
- bare host:        `libreclaw-00'
    → `ws://libreclaw-00:7077/api/v1/bridge'
- host:port:        `libreclaw-00:8888'
    → `ws://libreclaw-00:8888/api/v1/bridge'
- scheme + host:    `wss://bridge.example.com'
    → `wss://bridge.example.com/api/v1/bridge'
  (port stays at the scheme default for `wss://' — typical for a
  TLS-terminating reverse proxy on 443)
- full URL:         used verbatim.

See `cmacs-libreclaw-remote--normalize-url' for the full rule set.

TOKEN is the bearer token; when nil it is fetched via
`auth-source' keyed by the normalised URL's host and port (and
offered for interactive creation if the entry is absent).
Spawns the bridge connect asynchronously — completion is reported
via the `cmacs-libreclaw-remote--on-connected' hook."
  (interactive
   (list (read-string "Remote libreclaw URL or host: "
                      cmacs-libreclaw-remote--last-url)))
  (unless (fboundp 'cmacs-libreclaw-remote--connect-internal)
    (user-error
     "cmacs was built without libreclaw remote support; rebuild with --with-cmacs-libreclaw"))
  (let* ((normalised (cmacs-libreclaw-remote--normalize-url url))
         (tok (or token
                  (cmacs-libreclaw-remote--read-token normalised))))
    (setq cmacs-libreclaw-remote--last-url normalised)
    (message "cmacs-libreclaw-remote: connecting to %s" normalised)
    (cmacs-libreclaw-remote--connect-internal
     normalised tok
     cmacs-libreclaw-remote-display-name
     cmacs-libreclaw-remote-mcp-servers
     (or cmacs-libreclaw-remote-user-id
         (cmacs-libreclaw-remote--default-user-id)))))

;;;###autoload
(defun cmacs-libreclaw-remote-status ()
  "Show a one-line status line for the remote bridge."
  (interactive)
  (let ((up (and (fboundp 'cmacs-libreclaw-remote-connected-p)
                 (cmacs-libreclaw-remote-connected-p))))
    (message "cmacs-libreclaw-remote: %s%s"
             (if up "CONNECTED" "disconnected")
             (if cmacs-libreclaw-remote--last-url
                 (format " (%s)" cmacs-libreclaw-remote--last-url)
               ""))))

;;;###autoload
(defun cmacs-libreclaw-remote-chat ()
  "Open (or pop to) the bridge's local-style chat buffer.
Equivalent to libreclaw's built-in local CLI channel, but flowing
through the bridge to the remote libreclaw server.  Calling this
again reuses the same buffer.  Compose in the `* Compose'
section and `C-c C-c' to send."
  (interactive)
  (unless (cmacs-libreclaw-remote-connected-p)
    (user-error "Bridge not connected — M-x cmacs-libreclaw-remote-connect"))
  (let ((buf (cmacs-libreclaw--ensure-room-buffer
              "bridge"
              cmacs-libreclaw-remote-local-room-id
              cmacs-libreclaw-remote-local-room-name)))
    (pop-to-buffer buf)
    (goto-char (point-max))
    buf))

;;;###autoload
(defun cmacs-libreclaw-remote-open-room (room-id &optional room-name)
  "Open or create a bridge room buffer for ROOM-ID.
Use this when you want to chat in a specific room id on the
remote server (analogous to picking a Matrix room).
ROOM-NAME, if supplied, is the buffer's display label.

If you just want a single local-style chat buffer, prefer
`cmacs-libreclaw-remote-chat'."
  (interactive
   (list (read-string "Room id: ")
         (read-string "Friendly name (optional): " nil nil nil)))
  (unless (cmacs-libreclaw-remote-connected-p)
    (user-error "Bridge not connected — M-x cmacs-libreclaw-remote-connect"))
  (let ((buf (cmacs-libreclaw--ensure-room-buffer
              "bridge" room-id
              (if (and room-name (not (string-empty-p room-name)))
                  room-name room-id))))
    (pop-to-buffer buf)))

;;;; Signal handlers (invoked from C via cmacs-libreclaw-dispatch-to-lisp)
;;
;; The C-side dispatcher (`cmacs_libreclaw_dispatch_to_lisp' in
;; cmacs-libreclaw.c) always builds a 5-argument call, nil-padding any
;; slot the signal didn't fill in.  Each handler below MUST accept that
;; 5-arg shape or the C-side will log
;;   "cmacs-libreclaw dispatch failed: Wrong number of arguments"
;; and silently drop the signal.  `&rest _' absorbs the surplus.

(defun cmacs-libreclaw-remote--on-chat-message
    (_channel-id room-id &rest rest)
  "Forward a remote bridge chat message into the room-buffer machinery.

Backward-compatible with both C-side call shapes:
  - Old (5 args, pre-rebuild cmacs that uses the shared dispatch helper):
    (channel-id room-id sender-id body nil)
  - New (6 args, post-rebuild cmacs that builds a custom call expression):
    (channel-id room-id sender-id sender-name body timestamp)

The discriminator is the length of REST: 3 for old, 4 for new.  Without
this dual handling, restarting cmacs after editing only the Elisp side
would produce \"Wrong number of arguments\" errors on every inbound
bridge message until the C side is also rebuilt — a really annoying
foot-gun mid-iteration.

CHANNEL-ID is always \"bridge\" — `cmacs-libreclaw--on-message' is
keyed on (channel . room) so we get distinct buffers per remote room
automatically.

SENDER-NAME (new shape only) is the friendly display name (server-side
it's the agent.name from libreclaw's config.yaml, propagated through
the bridge via control.welcome + per-message sender_name).  Falls back
to SENDER-ID and then to \"?\" inside `cmacs-libreclaw--on-message'.

TIMESTAMP (new shape only) is unix seconds.  The server stamps this on
every chat.message_in frame; if it's missing or zero the bridge client
substitutes time-of-arrival, so the org heading never renders
1970-01-01."
  (let* ((n (length rest))
         (sender-id   (nth 0 rest))
         (sender-name (if (>= n 4) (nth 1 rest) nil))
         (body        (if (>= n 4) (nth 2 rest) (nth 1 rest)))
         (timestamp   (if (>= n 4) (nth 3 rest) nil)))
    (when (and room-id body
               (fboundp 'cmacs-libreclaw--on-message))
      (cmacs-libreclaw--on-message
       "bridge" room-id
       (list :sender-id   (and sender-id   (stringp sender-id)
                               (not (string-empty-p sender-id))
                               sender-id)
             :sender-name (and sender-name (stringp sender-name)
                               (not (string-empty-p sender-name))
                               sender-name)
             :body body
             :timestamp (and timestamp (integerp timestamp)
                             (> timestamp 0) timestamp))))))

(defun cmacs-libreclaw-remote--on-room-added (room-id &rest _)
  "Log when the remote bridge announces room ROOM-ID."
  (message "cmacs-libreclaw-remote: room added: %s" room-id))

(defun cmacs-libreclaw-remote--on-room-removed (room-id &rest _)
  "Log when the remote bridge announces ROOM-ID removal."
  (message "cmacs-libreclaw-remote: room removed: %s" room-id))

(defun cmacs-libreclaw-remote--on-connected (&rest _)
  "Hook: bridge handshake completed."
  (message "cmacs-libreclaw-remote: connected to %s"
           (or cmacs-libreclaw-remote--last-url "bridge")))

(defun cmacs-libreclaw-remote--on-disconnected (&rest _)
  "Hook: bridge connection torn down."
  (message "cmacs-libreclaw-remote: disconnected (%s)"
           (or cmacs-libreclaw-remote--last-url "bridge")))

(defun cmacs-libreclaw-remote--on-error (msg &rest _)
  "Hook: bridge surfaced an error MSG."
  (message "cmacs-libreclaw-remote ERROR: %s" msg))

(provide 'cmacs-libreclaw-remote)
;;; cmacs-libreclaw-remote.el ends here
