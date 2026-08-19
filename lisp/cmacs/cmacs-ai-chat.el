;;; cmacs-ai-chat.el --- Org-buffer chat UI for cmacs-ai  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Each chat is one buffer in `cmacs-ai-chat-mode' (a derived
;; `org-mode').  Layout mirrors `cmacs-libreclaw-room-mode':
;;
;;   #+TITLE: cmacs-ai -- <timestamp>
;;   * Conversation
;;   ** YYYY-MM-DD HH:MM:SS user
;;   <prompt>
;;   ** YYYY-MM-DD HH:MM:SS assistant
;;   <streaming response>
;;   * Compose                                              :compose:
;;   <editable area>
;;
;; History above the `* Compose' sentinel is read-only.  `C-c C-c'
;; sends the compose body.  Streaming deltas land in the active
;; `** assistant' heading inserted at send time.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'cmacs-ai)

(declare-function cmacs-ai-client-effective-model
                  "cmacs-ai-client.c" (handle))
(declare-function cmacs-ai-client-provider-name
                  "cmacs-ai-client.c" (handle))
(declare-function cmacs-ai-tools-new "cmacs-ai-tools.c" ())
;; Loaded lazily with `require ... noerror', so these may legitimately be
;; absent (a build without image support, or a stripped lisp/cmacs).
(declare-function cmacs-ai-image-chat-register "cmacs-ai-image-chat"
                  (executor))
(declare-function cmacs-ai-image-chat-slash-command "cmacs-ai-image-chat"
                  (line))
(declare-function cmacs-ai-tools-free "cmacs-ai-tools.c" (handle))
(declare-function cmacs-ai-tools-register-mcp-bridge
                  "cmacs-ai-tools.c"
                  (executor &optional allowlist denylist readonly-only))
(declare-function cmacs-ai-chat-continue-stream
                  "cmacs-ai-stream.c" (session callback &optional executor))
(declare-function cmacs-ai-tools-execute-into-session
                  "cmacs-ai-tools.c"
                  (session executor tool-name tool-input-json tool-id))

;;;; State ----------------------------------------------------------

(defvar cmacs-ai-chat--buffers nil
  "List of live cmacs-ai-chat buffers.")

(defvar-local cmacs-ai-chat-session-pair nil
  "Cons (CLIENT-HANDLE . SESSION-HANDLE) for this chat buffer.")

(defvar-local cmacs-ai-chat-provider nil
  "Provider symbol for this chat buffer.")

(defvar-local cmacs-ai-chat--compose-marker nil
  "Marker at the start of the editable compose region.")

(defvar-local cmacs-ai-chat--assistant-marker nil
  "Marker where the current assistant segment appends, or nil.

Opened by the first text of a segment rather than by the stream, and
cleared at the end of each segment.  Nil therefore does *not* mean the
turn is over -- see `cmacs-ai-chat--turn-open'.")

(defvar-local cmacs-ai-chat--turn-open nil
  "Non-nil while an assistant turn is in progress.

A turn spans every stream a single user message produces, tool loop and
all, so the transcript gets one heading per exchange instead of one per
model segment.  This is also what tells anything asking whether the
chat is busy that a tool loop is still running, since the segment
marker is nil in the gaps between streams.")

(defvar-local cmacs-ai-chat--assistant-start nil
  "Non-advancing marker at the start of the current assistant body.
Paired with `cmacs-ai-chat--assistant-marker' (which tracks the end)
to delimit the just-rendered region for inline image preview.")

(defvar-local cmacs-ai-chat--created-at nil)
(defvar-local cmacs-ai-chat--save-file nil)

(defvar-local cmacs-ai-chat-tool-executor nil
  "Tool-executor handle for this chat buffer, or nil to disable tools.
A fresh executor (with all ai-glib built-ins: bash, read, write,
edit, glob, grep, ls, web_fetch) is created on buffer init by
default.  Bind to nil before opening a chat to disable tool use.")

(defvar-local cmacs-ai-chat--pending-tool-uses nil
  "List of (NAME INPUT-JSON ID) triples accumulated during the current stream.
Drained on `:end stop=tool-use' to drive the tool execution loop.")

(defvar-local cmacs-ai-chat--tool-loop-depth 0
  "Number of consecutive tool-use re-streams in flight.
Capped by `cmacs-ai-chat-tool-loop-max-turns' to prevent runaways.")

(defvar cmacs-ai-chat--allow-history-edit nil
  "Dynamic override for `cmacs-ai-chat--protect-history'.
Set non-nil by stream callbacks so they can insert above the marker.")

;;;; Keymap / mode --------------------------------------------------

(defvar cmacs-ai-chat-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cmacs-ai-chat-send-compose)
    (define-key m (kbd "C-c C-k") #'cmacs-ai-chat-cancel-stream)
    (define-key m (kbd "C-c C-l") #'cmacs-ai-chat-clear-history)
    (define-key m (kbd "C-c C-s") #'cmacs-ai-chat-save)
    (define-key m (kbd "C-c C-o") #'cmacs-ai-chat-resume)
    m)
  "Keymap for `cmacs-ai-chat-mode'.")

(defun cmacs-ai-chat--protect-history (beg _end)
  "Block edits at BEG that fall above the compose marker."
  (when (and (not cmacs-ai-chat--allow-history-edit)
             cmacs-ai-chat--compose-marker
             (< beg cmacs-ai-chat--compose-marker))
    (signal 'text-read-only
            (list "cmacs-ai history is read-only; edit below * Compose"))))

(define-derived-mode cmacs-ai-chat-mode org-mode "cmacs-AI"
  "Major mode for cmacs-ai chat buffers.
Derived from `org-mode'.  History above the `* Compose' sentinel is
read-only; the region below is the editable prompt area.  `C-c C-c'
sends the compose body and streams the response into a fresh
`** assistant' heading.

\\{cmacs-ai-chat-mode-map}"
  (setq-local org-startup-folded 'showall)
  (setq-local org-adapt-indentation nil)
  (add-hook 'before-change-functions
            #'cmacs-ai-chat--protect-history nil t)
  (add-hook 'kill-buffer-hook
            #'cmacs-ai-chat--on-buffer-killed nil t)
  ;; A capability token must not outlive the buffer that needed it.
  (add-hook 'kill-buffer-hook
            #'cmacs-ai-chat--revoke-cli-tools nil t)
  (push (current-buffer) cmacs-ai-chat--buffers))

;;;; Buffer construction --------------------------------------------

(defun cmacs-ai-chat--ts ()
  (format-time-string "%Y-%m-%d %H:%M:%S"))

(defun cmacs-ai-chat--buffer-name (provider &optional directory)
  "Name for a chat buffer on PROVIDER, in DIRECTORY.

The directory is in the name because it is the thing that makes two
otherwise identical chats different agents, and picking the wrong buffer
sends work to the wrong project."
  (format "*cmacs-ai: %s [%s]%s*"
          (format-time-string "%H:%M:%S")
          (or provider cmacs-ai-default-provider)
          (if directory
              (format " %s" (file-name-nondirectory
                             (directory-file-name
                              (expand-file-name directory))))
            "")))

(defcustom cmacs-ai-cli-skip-permissions t
  "Whether a CLI agent may use its tools without asking first.

On by default, and effectively required: a command-line agent run
non-interactively has nobody to ask, so every tool needing approval is
simply unavailable to it.  The symptom is an agent that can see cmacs's
tools listed and says it has no way to call them.

What it may reach is already bounded by the capability token in its MCP
config, which is the gate that matters; this only stops it asking about
the tools it was granted.  libreclaw does the same for all three CLI
providers."
  :type 'boolean
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-cli-tool-allowlist "*"
  "Tools a CLI provider may reach over MCP in a chat buffer.

Comma-separated names or groups; `*' is everything the gate permits.

As shipped that includes the privileged set -- eval, shell, bash,
execute_command, send_keys, crispy_eval, bacon_eval and the C-patching
tools -- because `cmacs-brigade-restrict-privileged-tools' defaults to
nil.  Set that to t to put them back behind a deliberate naming, here
and everywhere else."
  :type 'string
  :group 'cmacs-ai)

;; Genuinely optional, and guarded at every call site with a message
;; when absent: cmacs-ai cannot require the brigade, because the brigade
;; requires cmacs-ai.
(declare-function cmacs-brigade-host-provision "cmacs-brigade-host")
(declare-function cmacs-brigade-host-revoke "cmacs-brigade-host")

(defcustom cmacs-ai-chat-default-directory nil
  "Directory new chats run in.  nil means wherever the buffer was opened.

Chiefly for the CLI providers: a command-line agent finds its project by
where its process starts, so this is what decides whether it sees a
repository, a CLAUDE.md and a .claude directory or none of them."
  :type '(choice (const :tag "Current directory" nil) directory)
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-directories nil
  "Project roots offered when prompting for a chat directory.

A list of directories you start agents in often, so the prompt completes
on them instead of making you type the path each time.  For example, set
it to a list containing \"~/Documents/gnuisaince\" and your source
checkouts."
  :type '(repeat directory)
  :group 'cmacs-ai)

(defvar cmacs-ai-chat-executor-functions nil
  "Abnormal hook run with a new tool executor and the session's provider.

Called as (EXECUTOR PROVIDER) once the executor exists, so a subsystem
can add its own tools to a chat session without cmacs-ai having to know
about it.  The brigade uses this to publish its tool registry -- the
dependency runs that way round, since the brigade requires cmacs-ai and
not the other way about.")

(defun cmacs-ai-chat--setup-executor ()
  "Create and configure this buffer's tool executor.
Sets the buffer-local `cmacs-ai-chat-tool-executor' (nil when tools
are disabled), augments it with cmacs's MCP tool surface, and wires
ai-glib's web_search backend.  Shared by `cmacs-ai-chat--init' and
`cmacs-ai-chat--restore'."
  (setq-local cmacs-ai-chat-tool-executor
              (when cmacs-ai-chat-enable-tools
                (cmacs-ai-tools-new)))
  ;; Augment the executor with cmacs's own MCP tool surface so the
  ;; model gets buffer / file / project / eval / apropos / describe
  ;; on top of ai-glib's filesystem-level built-ins.  Silently
  ;; skipped if cmacs was built --without-cmacs-mcp.
  (when (and cmacs-ai-chat-tool-executor
             cmacs-ai-mcp-bridge-enable
             (fboundp 'cmacs-ai-tools-register-mcp-bridge))
    (condition-case err
        (cmacs-ai-tools-register-mcp-bridge
         cmacs-ai-chat-tool-executor
         cmacs-ai-mcp-bridge-allowlist
         cmacs-ai-mcp-bridge-denylist
         cmacs-ai-mcp-bridge-readonly-only)
      (error
       (message "cmacs-ai: MCP bridge unavailable: %S" err))))
  ;; Offer the model a generate_image tool, so it can draw something
  ;; mid-conversation.  Deliberately not `ai_'-prefixed: the MCP bridge
  ;; hides "^ai_" tools from in-process chat buffers, which is exactly
  ;; where this one has to be visible.
  (when cmacs-ai-chat-tool-executor
    (when (require 'cmacs-ai-image-chat nil 'noerror)
      (cmacs-ai-image-chat-register cmacs-ai-chat-tool-executor)))
  ;; Enable ai-glib's web_search tool with the configured backend.
  ;; `auto' never fails (keyless DuckDuckGo fallback); a keyed
  ;; provider with no key just logs and leaves web_search off.
  (when (and cmacs-ai-chat-tool-executor
             cmacs-ai-search-provider
             (fboundp 'cmacs-ai-tools-set-search-provider))
    (condition-case err
        (cmacs-ai-tools-set-search-provider
         cmacs-ai-chat-tool-executor
         cmacs-ai-search-provider
         cmacs-ai-search-api-key)
      (error
       (message "cmacs-ai: web_search unavailable: %S" err))))
  ;; Let other subsystems contribute tools.  Runs last so a subsystem
  ;; can see, and deliberately shadow, what is already installed.
  (when cmacs-ai-chat-tool-executor
    (run-hook-with-args 'cmacs-ai-chat-executor-functions
                        cmacs-ai-chat-tool-executor
                        cmacs-ai-chat-provider))
  ;; A CLI provider ignores the tools argument entirely -- ai-glib
  ;; discards it (`(void)tools' in the claude-code and claude-tmux
  ;; clients) -- so everything registered above would silently not exist
  ;; for the model.  Hand it an MCP config instead, which is how those
  ;; agents take tools.
  (cmacs-ai-chat--wire-cli-tools))

(defun cmacs-ai-chat--wire-cli-tools ()
  "Give a CLI provider its tools over MCP, since it ignores the executor."
  (let ((client (car-safe cmacs-ai-chat-session-pair)))
    (when (and client
               cmacs-ai-chat-enable-tools
               (fboundp 'cmacs-ai-client-cli-p)
               (cmacs-ai-client-cli-p client))
      ;; First, and regardless of whether cmacs can provision anything:
      ;; this governs the agent's own built-in tools too, not just the
      ;; ones cmacs grants, and tying it to provisioning left an agent
      ;; unable to so much as read a file whenever the MCP server was
      ;; not up.
      (when cmacs-ai-cli-skip-permissions
        (cmacs-ai-client-set-skip-permissions client t))
      ;; Same reason as the harness: guarding on `fboundp' alone makes
      ;; tool provisioning depend on load order rather than on the build.
      (require 'cmacs-brigade-host nil 'noerror)
      (cond
       ((not (fboundp 'cmacs-brigade-host-provision))
        ;; Said out loud rather than skipped quietly: without this the
        ;; session looks tool-enabled and has none.
        (message "cmacs-ai: %s takes tools over MCP; needs --with-cmacs-ai-brigade to provision one"
                 cmacs-ai-chat-provider))
       (t
        (let ((endpoint (cmacs-brigade-host-provision
                         (format "chat-%s" (buffer-name))
                         cmacs-ai-chat-cli-tool-allowlist)))
          (cond
           ((null endpoint)
            (message "cmacs-ai: could not provision MCP tools for %s"
                     cmacs-ai-chat-provider))
           ((not (cmacs-ai-client-set-mcp-config client
                                                 (plist-get endpoint :path)))
            (message "cmacs-ai: %s does not accept an MCP config; this session has no tools" cmacs-ai-chat-provider))
           (t (setq-local cmacs-ai-chat--cli-endpoint endpoint)))))))))

(defvar-local cmacs-ai-chat--cli-endpoint nil
  "Provisioned MCP endpoint for a CLI provider in this buffer.")

(defun cmacs-ai-chat--revoke-cli-tools ()
  "Drop this buffer's MCP credential when the buffer goes."
  (when (and cmacs-ai-chat--cli-endpoint
             (fboundp 'cmacs-brigade-host-revoke))
    (ignore-errors
      (cmacs-brigade-host-revoke (format "chat-%s" (buffer-name))))
    (setq cmacs-ai-chat--cli-endpoint nil)))

(defun cmacs-ai-chat--init (buf provider &optional model directory)
  (with-current-buffer buf
    (let ((inhibit-read-only t)
          (m (or model cmacs-ai-default-model)))
      (erase-buffer)
      (insert (format "#+TITLE: cmacs-ai -- %s\n"
                      (format-time-string "%Y-%m-%d %H:%M:%S")))
      (insert "#+STARTUP: showall indent\n")
      (insert "#+OPTIONS: toc:nil num:nil\n")
      (insert (format "#+PROPERTY: provider %s\n" provider))
      (when m
        (insert (format "#+PROPERTY: model %s\n" m)))
      (when directory
        (insert (format "#+PROPERTY: directory %s\n"
                        (abbreviate-file-name directory))))
      (insert "\n")
      (insert "* Conversation\n\n")
      (insert "* Compose                                              :compose:\n"))
    (cmacs-ai-chat-mode)
    (setq-local cmacs-ai-chat-provider provider)
    ;; Set before the session exists so anything the setup consults --
    ;; the MCP bridge's project tools, a shell tool -- already resolves
    ;; against the right tree rather than wherever the buffer was opened.
    (when directory
      (setq-local default-directory (file-name-as-directory
                                     (expand-file-name directory))))
    (setq-local cmacs-ai-chat-session-pair
                (cmacs-ai-make-session provider model))
    ;; A CLI agent finds its project by where its process starts:
    ;; CLAUDE.md, .claude/, a project MCP config and the repository are
    ;; all resolved from there, so this is what makes it *that* agent
    ;; rather than a generic one.
    (when directory
      (cmacs-ai-client-set-working-directory
       (car cmacs-ai-chat-session-pair) default-directory)
      ;; Noted, not read: the file is only worth sending if a
      ;; conversation actually happens.  Skipped for the CLI providers,
      ;; which read it themselves from their working directory -- an
      ;; injected copy would be the same instructions twice.
      (unless (cmacs-ai-client-cli-p (car cmacs-ai-chat-session-pair))
        (setq-local cmacs-ai-chat--bootstrap-file
                    (cmacs-ai-chat--find-bootstrap default-directory))))
    (cmacs-ai-chat--setup-executor)
    (setq-local cmacs-ai-chat--created-at (current-time))
    (setq-local cmacs-ai-chat--compose-marker
                (save-excursion (goto-char (point-max)) (point-marker)))
    (set-marker-insertion-type cmacs-ai-chat--compose-marker nil)
    (goto-char (point-max))))

(defun cmacs-ai-chat-open (&optional provider model directory)
  "Open a fresh chat buffer with PROVIDER (default
`cmacs-ai-default-provider').  Optional MODEL overrides the
provider's default model for this chat's session.

Optional DIRECTORY runs the conversation there: a CLI agent's
subprocess starts in it, and the buffer's `default-directory' follows,
so filesystem tools resolve against the same tree."
  (interactive)
  (cmacs-ai--ensure)
  (let* ((p (or provider cmacs-ai-default-provider))
         (d (or directory cmacs-ai-chat-default-directory))
         ;; `generate-new-buffer', not `get-buffer-create': the name is
         ;; second-granular, so two chats opened in the same second
         ;; resolved to one buffer -- and `cmacs-ai-chat--init' erasing
         ;; it then hit the read-only history guard, so the second open
         ;; failed outright rather than merely reusing the first.
         (buf (generate-new-buffer (cmacs-ai-chat--buffer-name p d))))
    (cmacs-ai-chat--init buf p model d)
    (switch-to-buffer buf)
    buf))

(defun cmacs-ai-chat-set-search-provider (provider &optional api-key)
  "Switch the web_search backend for the current chat buffer to PROVIDER.
Interactively prompts for PROVIDER (auto/brave/bing/duckduckgo).
Re-registers ai-glib's web_search tool on this buffer's executor;
takes effect on the next send.  Optional API-KEY overrides
`cmacs-ai-search-api-key' / the environment for keyed providers."
  (interactive
   (list (intern (completing-read
                  "web_search provider: "
                  '("auto" "brave" "bing" "duckduckgo") nil t))))
  (unless cmacs-ai-chat-tool-executor
    (user-error "This chat buffer has no tool executor"))
  (unless (fboundp 'cmacs-ai-tools-set-search-provider)
    (user-error "cmacs was built without web_search support"))
  (cmacs-ai-tools-set-search-provider
   cmacs-ai-chat-tool-executor provider
   (or api-key cmacs-ai-search-api-key))
  (setq-local cmacs-ai-search-provider provider)
  (message "cmacs-ai: web_search now uses %s" provider))

;;;; Label resolution ------------------------------------------------

(defun cmacs-ai-chat--user-label ()
  "Resolve the user-side heading label.
Honors `cmacs-ai-user-label' first, then $USER, then \"user\"."
  (or (and cmacs-ai-user-label
           (not (string-empty-p cmacs-ai-user-label))
           cmacs-ai-user-label)
      (and (getenv "USER")
           (not (string-empty-p (getenv "USER")))
           (getenv "USER"))
      "user"))

(defun cmacs-ai-chat--assistant-label ()
  "Resolve the assistant-side heading label as \"provider/model\".
Pulls the provider name and effective model from ai-glib so the
label reflects what's actually answering (including model defaults).
The provider half is the symbol you selected -- `claude-code', not
ai-glib's display name -- so it matches what the Elisp API and the
provider prompt use.  The model half is left
untouched -- ai-glib's strings tend to be the provider's own
canonical model id (e.g. `claude-sonnet-5', `gpt-oss:20b').
Falls back to the buffer-local provider symbol when no client is
available."
  (let* ((client (car-safe cmacs-ai-chat-session-pair))
         ;; The symbol first, ai-glib's display name only as a fallback.
         ;; ai-glib returns prose -- "Claude Code", "Claude (TUI via
         ;; tmux)" -- and downcasing that gives "claude code", which is
         ;; not a provider you can name anywhere in the Elisp API.
         (provider (or (and cmacs-ai-chat-provider
                            (symbol-name cmacs-ai-chat-provider))
                       (and client
                            (cmacs-ai-chat--provider-slug
                             (cmacs-ai-client-provider-name client)))
                       "assistant"))
         (model (and client (cmacs-ai-client-effective-model client))))
    (if (and model (not (string-empty-p model)))
        (format cmacs-ai-assistant-label-format provider model)
      provider)))

(defun cmacs-ai-chat--provider-slug (name)
  "Turn ai-glib display NAME into something shaped like a provider symbol."
  (when name
    (let ((s (downcase name)))
      ;; Drop parenthetical asides, then collapse whatever is left into
      ;; hyphens: "Claude (TUI via tmux)" is a label, not an identifier.
      (setq s (replace-regexp-in-string "(.*)" "" s))
      (setq s (replace-regexp-in-string "[^a-z0-9]+" "-" s))
      (string-trim s "-+" "-+"))))

;;;; History rendering ----------------------------------------------

(defun cmacs-ai-chat--insert-heading (buf role body &optional level)
  "Insert a heading above the compose marker in BUF.
LEVEL is the org outline depth (number of leading `*'); defaults to 2.
Use 3 (`***') for tool-use / tool-result entries so they nest under
the preceding assistant `**' heading in the org outline.

Returns a marker positioned ON the body line, with insertion-type t,
so streaming inserts accumulate in order on that line and the
trailing blank separator stays pinned between the body and the
`* Compose' sentinel.

The character layout produced is:

  STARS TIMESTAMP role\\n          <- heading line
  BODY\\n                          <- body line (empty for streaming)
  \\n                              <- separator blank line, never consumed
  * Compose ...

Streaming chunks insert at the marker (which sits at the position of
the body line's terminator-newline) and push that \\n forward — so the
separator below it always remains intact."
  (with-current-buffer buf
    (save-excursion
      (goto-char cmacs-ai-chat--compose-marker)
      ;; Step back to the `* Compose' sentinel line itself.
      (forward-line -1)
      (beginning-of-line)
      (let ((inhibit-read-only t)
            (cmacs-ai-chat--allow-history-edit t)
            (body* (or body ""))
            (stars (make-string (or level 2) ?*)))
        ;; Heading.
        (insert (format "%s %s  %s\n" stars (cmacs-ai-chat--ts) role))
        ;; Reserve TWO newlines: the body line's terminator + the
        ;; separator blank line below it.  Walk back two lines so
        ;; point lands at the start of the (empty) body line; any
        ;; body text we insert next will sit on that line, and the
        ;; marker we capture stays at the body terminator so
        ;; streaming text pushes it (and the separator below)
        ;; forward without ever consuming the separator.
        (insert "\n\n")
        (forward-line -2)
        (when (> (length body*) 0)
          (let ((body-trimmed
                 (if (eq (aref body* (1- (length body*))) ?\n)
                     (substring body* 0 (1- (length body*)))
                   body*)))
            (insert body-trimmed)))
        (let ((m (point-marker)))
          (set-marker-insertion-type m t)
          m)))))

(defun cmacs-ai-chat--open-continuation (buf)
  "Open a body region above the compose sentinel in BUF, with no heading.

Where an assistant turn resumes after tool calls.  The same character
layout `cmacs-ai-chat--insert-heading' produces, minus the heading line,
so the continued prose lands *below* the tool blocks under the one
heading this turn already has, and the separator stays pinned."
  (with-current-buffer buf
    (save-excursion
      (goto-char cmacs-ai-chat--compose-marker)
      (forward-line -1)
      (beginning-of-line)
      (let ((inhibit-read-only t)
            (cmacs-ai-chat--allow-history-edit t))
        (insert "\n\n")
        (forward-line -2)
        (let ((m (point-marker)))
          (set-marker-insertion-type m t)
          m)))))

(defun cmacs-ai-chat--ensure-segment (buf)
  "Return the marker the current assistant segment appends at.

Opened lazily, on the first text of a segment: a segment that only
calls tools produces no text, and creating its heading up front is what
littered the transcript with empty ones.  The first text of a turn
opens the heading; text after a tool call continues underneath it."
  (with-current-buffer buf
    (or cmacs-ai-chat--assistant-marker
        (setq cmacs-ai-chat--assistant-marker
              (if cmacs-ai-chat--turn-open
                  (cmacs-ai-chat--open-continuation buf)
                (setq cmacs-ai-chat--turn-open t)
                (let ((m (cmacs-ai-chat--insert-heading
                          buf (cmacs-ai-chat--assistant-label) "")))
                  ;; Pins the start of the whole turn, so the image
                  ;; preview at the end covers everything it produced.
                  (setq cmacs-ai-chat--assistant-start
                        (and m (copy-marker m nil)))
                  m))))))

(defun cmacs-ai-chat--close-turn (buf)
  "Finish the assistant turn in BUF: preview images and clear the state."
  (with-current-buffer buf
    (cmacs-ai-chat--preview-images cmacs-ai-chat--assistant-start
                                   cmacs-ai-chat--assistant-marker)
    (setq cmacs-ai-chat--assistant-marker nil
          cmacs-ai-chat--assistant-start nil
          cmacs-ai-chat--turn-open nil)))

(defun cmacs-ai-chat--append-at-marker (marker text)
  "Insert TEXT at MARKER (assistant streaming) in MARKER's buffer."
  (when (and marker (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (let ((inhibit-read-only t)
              (cmacs-ai-chat--allow-history-edit t))
          (insert text))))))

;;;; Send / receive -------------------------------------------------

(defun cmacs-ai-chat--read-compose ()
  "Return the trimmed compose-region content and clear it.
Returns nil if the region is empty."
  (let* ((beg cmacs-ai-chat--compose-marker)
         (end (point-max))
         (raw (buffer-substring-no-properties beg end))
         (trimmed (string-trim raw)))
    (unless (string-empty-p trimmed)
      (let ((inhibit-read-only t)
            (cmacs-ai-chat--allow-history-edit t))
        (delete-region beg end))
      trimmed)))

(defconst cmacs-ai-show-tool-calls-env "CMACS_AI_SHOW_TOOL_CALLS"
  "Environment variable that turns tool-call rendering on.

Accepts `true', `TRUE' or `1'.  An environment variable rather than only
a `defcustom' so a single debugging session can be started with them
visible -- `CMACS_AI_SHOW_TOOL_CALLS=1 emacs' -- without editing config
that then has to be edited back.")

(defun cmacs-ai--env-truthy (name)
  "Whether environment variable NAME is set to something meaning yes."
  (let ((v (getenv name)))
    (and v (member (downcase (string-trim v)) '("true" "1" "yes" "on")) t)))

(defcustom cmacs-ai-chat-show-tool-calls
  (cmacs-ai--env-truthy cmacs-ai-show-tool-calls-env)
  "Whether tool calls and their results appear in the chat buffer.

Off by default.  A tool loop can run a dozen calls whose arguments and
output are each a JSON block, which buries the conversation those calls
were in service of -- the transcript stops being readable as a
conversation and becomes a log.

The tools still run when this is nil; only the rendering is suppressed,
and the model's own account of what it did is unaffected.  Turn it on
for a session with `CMACS_AI_SHOW_TOOL_CALLS=1', or set this."
  :type 'boolean
  :group 'cmacs-ai)

(defun cmacs-ai-chat-toggle-tool-calls ()
  "Show or hide tool calls in new turns of this chat."
  (interactive)
  (setq-local cmacs-ai-chat-show-tool-calls
              (not cmacs-ai-chat-show-tool-calls))
  (message "cmacs-ai: tool calls %s"
           (if cmacs-ai-chat-show-tool-calls "shown" "hidden")))

(defun cmacs-ai-chat--render-tool-result (buf name id result)
  "Render a tool RESULT for tool NAME / ID as a nested `***' heading.
Nests under the assistant `**' turn that requested the call so the
org outline groups call-and-result with the response that drove them."
  (when cmacs-ai-chat-show-tool-calls
    (cmacs-ai-chat--insert-heading
     buf (format "tool-result/%s" name)
     (format ":PROPERTIES:\n:tool: %s\n:id: %s\n:END:\n#+BEGIN_SRC text\n%s\n#+END_SRC"
             name id (or result ""))
     3)))

(defun cmacs-ai-chat--drive-tool-loop (buf)
  "Drain pending tool-use requests for BUF and re-stream.
Called after a stream ends with stop=tool-use.  Each pending tool
is executed via `cmacs-ai-tools-execute-into-session' (which
appends a tool_result message to the session), the result is
rendered in the chat buffer, then `cmacs-ai-chat-continue-stream'
re-invokes the model with the augmented context.  Loops via the
stream-end callback until the model produces a non-tool stop
reason or `cmacs-ai-chat-tool-loop-max-turns' is reached."
  (with-current-buffer buf
    (let ((executor cmacs-ai-chat-tool-executor)
          (session  (cdr cmacs-ai-chat-session-pair))
          (pending  (nreverse cmacs-ai-chat--pending-tool-uses)))
      (setq cmacs-ai-chat--pending-tool-uses nil)
      (cond
       ((null executor)
        ;; Tools disabled but model emitted tool_use anyway -- show as error.
        (cmacs-ai-chat--insert-heading
         buf "error"
         "model emitted tool_use but no executor is configured"))
       ((>= cmacs-ai-chat--tool-loop-depth
            cmacs-ai-chat-tool-loop-max-turns)
        (cmacs-ai-chat--insert-heading
         buf "tool-loop-aborted"
         (format "Reached %d turns; abandoning tool loop."
                 cmacs-ai-chat-tool-loop-max-turns))
        (setq cmacs-ai-chat--tool-loop-depth 0))
       (t
        (cl-incf cmacs-ai-chat--tool-loop-depth)
        ;; Execute each pending tool and render its result.
        (dolist (tu pending)
          (let* ((name (nth 0 tu))
                 (input (nth 1 tu))
                 (id (nth 2 tu))
                 (result (condition-case err
                             (cmacs-ai-tools-execute-into-session
                              session executor name input id)
                           (error (format "tool error: %S" err)))))
            (cmacs-ai-chat--render-tool-result buf name id result)))
        ;; Re-stream so the model sees the new tool_result messages.
        (cmacs-ai-chat-continue-stream
         session
         (lambda (payload)
           (cmacs-ai-chat--stream-callback buf payload))
         executor))))))

(defun cmacs-ai-chat--stream-callback (buf payload)
  "Dispatch a streaming PAYLOAD plist into BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (pcase (car payload)
        (:start
         ;; Nothing is rendered here.  A stream that only calls tools
         ;; would otherwise leave a heading with no body behind it, and
         ;; a tool loop produced one of those per round.
         nil)
        (:delta
         (let ((chunk (cadr payload)))
           (when (and chunk (> (length chunk) 0))
             (cmacs-ai-chat--append-at-marker
              (cmacs-ai-chat--ensure-segment buf) chunk))))
        (:tool-use
         (let ((name (nth 1 payload))
               (input (nth 2 payload))
               (id (nth 3 payload)))
           ;; Dedup by id: the streaming `tool-use' signal and the
           ;; end-of-stream response pass both deliver the same blocks
           ;; for providers (like Claude) that fire both.  Only the
           ;; first occurrence gets rendered + queued.
           (unless (cl-some (lambda (tu) (equal (nth 2 tu) id))
                            cmacs-ai-chat--pending-tool-uses)
             ;; Rendering only.  The queueing below is what makes the
             ;; call happen, and must not depend on whether it is shown.
             (when cmacs-ai-chat-show-tool-calls
               (cmacs-ai-chat--insert-heading
                buf (format "tool-use/%s" name)
                (format ":PROPERTIES:\n:tool: %s\n:id: %s\n:END:\n#+BEGIN_SRC json\n%s\n#+END_SRC"
                        name id input)
                3))
             (push (list name input id) cmacs-ai-chat--pending-tool-uses))))
        (:end
         (when cmacs-ai-chat-autosave (cmacs-ai-chat-save-quietly))
         ;; If the model stopped to call tools and we have any pending,
         ;; drive the loop.  The turn stays *open* across that: the tool
         ;; results and whatever the model says afterwards belong to the
         ;; exchange the user started, not to a new one.  Only the
         ;; segment marker is released, so the next text opens a
         ;; continuation under the same heading.
         (if (and (eq (plist-get (cdr payload) :stop) 'tool-use)
                  cmacs-ai-chat--pending-tool-uses)
             (progn
               (setq cmacs-ai-chat--assistant-marker nil)
               (cmacs-ai-chat--drive-tool-loop buf))
           (cmacs-ai-chat--close-turn buf)
           (setq cmacs-ai-chat--tool-loop-depth 0)))
        (:error
         (cmacs-ai-chat--insert-heading
          buf "error" (cadr payload))
         (cmacs-ai-chat--close-turn buf)
         (setq cmacs-ai-chat--tool-loop-depth 0)
         (setq cmacs-ai-chat--pending-tool-uses nil))))))

;;;; Inline image preview ------------------------------------------
;;
;; Assistant responses often embed image links.  Local/file images are
;; rendered synchronously via Org (fast); remote http(s) images are
;; fetched ASYNCHRONOUSLY so Emacs never blocks on the network (Org's
;; own remote-image download is synchronous and would freeze the UI).
;; Remote images are decoded and shown as overlays registered with Org's
;; preview machinery so `org-link-preview' toggling clears them too.

(defun cmacs-ai-chat--image-max-width ()
  "Pixel cap for inline images, sized to the chat window when possible."
  (let ((win (get-buffer-window (current-buffer) t)))
    (max 200 (min cmacs-ai-chat-image-max-width
                  (if win (floor (* 0.92 (window-body-width win t)))
                    cmacs-ai-chat-image-max-width)))))

(defun cmacs-ai-chat--place-image (beg end data)
  "Overlay an image decoded from DATA (raw bytes) on region [BEG,END).
No-op when DATA is not a decodable image."
  (when (and (markerp beg) (markerp end)
             (marker-position beg) (marker-position end)
             (display-images-p))
    (let ((img (ignore-errors
                 (create-image data nil t
                               :max-width (cmacs-ai-chat--image-max-width)))))
      (when img
        (let ((ov (make-overlay beg end)))
          (overlay-put ov 'display img)
          (overlay-put ov 'cmacs-ai-image t)
          (overlay-put ov 'keymap image-map)
          (overlay-put ov 'evaporate t)
          ;; Hook into Org's preview list so org-link-preview toggling
          ;; clears our overlays alongside its own.
          (when (boundp 'org-link-preview-overlays)
            (push ov org-link-preview-overlays)))))))

(defun cmacs-ai-chat--http-image-bytes ()
  "In a `url-retrieve' result buffer, return image body bytes, or nil.
Requires an HTTP 2xx status and an image (or absent) Content-Type."
  (goto-char (point-min))
  (when (re-search-forward "\\`HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
    (let ((code (string-to-number (match-string 1)))
          (ct nil))
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^[Cc]ontent-[Tt]ype:[ \t]*\\([^ \t\r\n;]+\\)"
                                 nil t)
          (setq ct (match-string 1))))
      (when (and (>= code 200) (< code 300)
                 (or (null ct) (string-prefix-p "image/" ct)))
        (goto-char (point-min))
        (when (re-search-forward "\r?\n\r?\n" nil t)
          (buffer-substring-no-properties (point) (point-max)))))))

(defun cmacs-ai-chat--fetch-image-async (url buf beg end)
  "Fetch image URL asynchronously and overlay it on [BEG,END) in BUF."
  (condition-case nil
      (url-retrieve
       url
       (lambda (status)
         (let ((rbuf (current-buffer)))
           (unwind-protect
               (unless (plist-get status :error)
                 (let ((data (cmacs-ai-chat--http-image-bytes)))
                   (when (and data (buffer-live-p buf))
                     (with-current-buffer buf
                       (cmacs-ai-chat--place-image beg end data)))))
             (when (buffer-live-p rbuf) (kill-buffer rbuf)))))
       nil t t)
    (error nil)))

(defun cmacs-ai-chat--preview-images (start endm)
  "Preview image links between markers START and ENDM.
Local images via Org (synchronous); remote http(s) images fetched
async.  No-op unless `cmacs-ai-chat-inline-images' is set."
  (when (and cmacs-ai-chat-inline-images
             (markerp start) (markerp endm)
             (marker-position start) (marker-position endm)
             (< (marker-position start) (marker-position endm)))
    (let ((b (marker-position start))
          (e (marker-position endm))
          (img-re (image-file-name-regexp)))
      ;; Local/file links now -- bind remote to skip so Org never blocks.
      (when (fboundp 'org-link-preview-region)
        (let ((org-display-remote-inline-images 'skip))
          (ignore-errors (org-link-preview-region nil nil b e))))
      ;; Remote image links: dispatch async fetches.
      (save-excursion
        (goto-char b)
        (while (re-search-forward org-link-bracket-re e t)
          (let ((url  (match-string-no-properties 1))
                (lbeg (match-beginning 0))
                (lend (match-end 0)))
            (when (and (string-match-p "\\`https?://" url)
                       (string-match-p img-re url))
              (cmacs-ai-chat--fetch-image-async
               url (current-buffer)
               (copy-marker lbeg) (copy-marker lend)))))))))

(defun cmacs-ai-chat--apply-pre-prompt (text)
  "Return TEXT with `cmacs-ai-pre-prompt' prepended (if set).
The pre-prompt is sent to the model on every user turn but is not
rendered in the chat buffer -- the user heading always shows just
what the user typed."
  (let ((pre cmacs-ai-pre-prompt))
    (if (and pre (stringp pre) (not (string-empty-p pre)))
        (concat pre "\n\n---\n\n" text)
      text)))

(defcustom cmacs-ai-chat-bootstrap-files '("CLAUDE.md" "AGENTS.md")
  "Files that bootstrap an HTTP provider on a project directory.

When a chat is opened in a directory and one of these is there, its
contents are added to the session's system prompt on the first send.
When several are present the largest one wins, on the assumption that
the fuller document is the one being maintained.

Only for the HTTP providers.  The CLI agents read these files
themselves, from the directory their process starts in, so injecting a
copy would send it twice."
  :type '(repeat string)
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-bootstrap t
  "Whether to bootstrap an HTTP chat from the project's agent file."
  :type 'boolean
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-bootstrap-max-bytes 200000
  "Largest bootstrap file that will be sent.

A big one is a real cost on every turn of the conversation, not just the
first, because it stays in the system prompt.  Past this the file is
skipped and said so rather than truncated: half a document of
instructions is worse than none."
  :type 'integer
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-bootstrap-directive
  "Before replying, carry out any startup or bootstrap steps %s specifies \
above -- reading the files it points at, loading memory, whatever it \
asks for.  Do that first, report only what matters about it, then answer \
what follows.\n\n"
  "Instruction prepended to the first message after a bootstrap.

A format string; %s is the file the instructions came from.  Set to nil
to send nothing.

The file alone is not enough.  Put in the system prompt it reads as
background -- a description of the project rather than something to act
on -- so a model given a startup ritual will happily answer \"hey there\"
with \"hey!\" and perform none of it.  Saying so in the user turn, which
is where a model looks for what it is being asked to do, is what
actually gets it done.

Prepended invisibly, like `cmacs-ai-pre-prompt': the buffer still shows
exactly what was typed."
  :type '(choice (const :tag "Say nothing" nil) string)
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-bootstrap-announce t
  "Whether to say in the echo area that a project file was sent.

Nothing is added to the conversation either way -- this is only a note
in *Messages*.  On by default because the alternative is silently
shipping a file from your disk to a remote API, which you should be able
to find out about after the fact."
  :type 'boolean
  :group 'cmacs-ai)

(defvar-local cmacs-ai-chat--bootstrap-file nil
  "Project file to fold into the system prompt on the first send.")

(defun cmacs-ai-chat--find-bootstrap (directory)
  "Return the bootstrap file in DIRECTORY, or nil.

The largest candidate wins when more than one is present."
  (when (and cmacs-ai-chat-bootstrap directory)
    (let (best best-size)
      (dolist (name cmacs-ai-chat-bootstrap-files)
        (let ((path (expand-file-name name directory)))
          (when (file-readable-p path)
            (let ((size (file-attribute-size (file-attributes path))))
              (when (or (null best-size) (> size best-size))
                (setq best path best-size size))))))
      best)))

(defcustom cmacs-ai-chat-bootstrap-expand-imports t
  "Whether to expand `@file' references inside a bootstrap file.

The convention comes from Claude Code: a line naming `@SOUL.org' means
\"read that file here\".  A CLI agent resolves them itself because it can
open files; an HTTP model cannot, so without expansion it receives a
manifest of filenames it has no way to follow and behaves as though the
project said nothing.  A CLAUDE.md that is only a list of imports -- a
common shape -- is then worth exactly nothing to it."
  :type 'boolean
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-bootstrap-max-depth 5
  "How deep `@file' imports may nest.

An imported file may import others.  Bounded because a cycle would
otherwise not terminate, and because depth is a decent proxy for
\"nobody meant to send this much\"."
  :type 'integer
  :group 'cmacs-ai)

(defun cmacs-ai-chat--expand-imports (text dir depth seen)
  "Replace `@file' references in TEXT with those files' contents.

DIR is what relative references resolve against -- the directory of the
file being expanded, not the chat's, so a nested import means what it
says.  DEPTH is the remaining budget and SEEN is a hash of already
expanded truenames.

A reference is only expanded when it resolves to a readable file, which
is what keeps `foo@example.com' and an `@' inside prose from being
mistaken for one.  Anything unresolved is left exactly as written, so
the model still sees that a file was meant even when it is missing."
  (if (<= depth 0)
      text
    (let ((case-fold-search nil))
      (replace-regexp-in-string
       "\\(^\\|[[:space:]]\\)@\\([^[:space:]]+\\)"
       (lambda (m)
         (let* ((lead (match-string 1 m))
                (ref (match-string 2 m))
                ;; Trailing punctuation is sentence, not filename.
                (ref (replace-regexp-in-string "[.,;:)]+\\'" "" ref))
                (path (expand-file-name ref dir)))
           (cond
            ((not (and (file-readable-p path) (file-regular-p path)))
             m)
            ((gethash (file-truename path) seen)
             ;; Named twice.  The content is already above; repeating it
             ;; is only cost.
             (format "%s[%s: included above]" lead
                     (file-name-nondirectory path)))
            (t
             (puthash (file-truename path) t seen)
             (condition-case err
                 (let ((body (with-temp-buffer
                               (insert-file-contents path)
                               (buffer-string))))
                   (format "%s\n\n===== BEGIN %s =====\n%s\n===== END %s =====\n"
                           lead
                           (file-name-nondirectory path)
                           (cmacs-ai-chat--expand-imports
                            body (file-name-directory path) (1- depth) seen)
                           (file-name-nondirectory path)))
               (error
                (format "%s[%s: unreadable: %s]" lead
                        (file-name-nondirectory path)
                        (error-message-string err))))))))
       text t t))))

(defun cmacs-ai-chat--apply-bootstrap ()
  "Fold this buffer's bootstrap file into the session's system prompt.

Done on the first send rather than when the chat opens: opening a chat
should cost nothing, and a directory's instructions are only worth
sending if the conversation actually happens.

The contents go in the system prompt rather than the visible transcript,
so the conversation reads as what was typed."
  (when-let* ((path cmacs-ai-chat--bootstrap-file)
              (client (car-safe cmacs-ai-chat-session-pair)))
    ;; Once only, whatever happens below: a file that is too big or has
    ;; gone away must not be reconsidered on every turn.
    (setq cmacs-ai-chat--bootstrap-file nil)
    (condition-case err
        (let* ((raw (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string)))
               ;; Imports first, then measure.  A manifest of @references
               ;; is a couple of hundred bytes and means nothing on its
               ;; own, so the size worth checking is what actually gets
               ;; sent.
               (text (if cmacs-ai-chat-bootstrap-expand-imports
                         (cmacs-ai-chat--expand-imports
                          raw (file-name-directory path)
                          cmacs-ai-chat-bootstrap-max-depth
                          (let ((h (make-hash-table :test 'equal)))
                            (puthash (file-truename path) t h)
                            h))
                       raw))
               (size (string-bytes text)))
          (if (> size cmacs-ai-chat-bootstrap-max-bytes)
              (message "cmacs-ai: %s expands to %dkB, over the bootstrap \
limit; not sent"
                       (file-name-nondirectory path) (/ size 1024))
            (cmacs-ai-client-set-system-prompt
             client
             (string-join
              (delq nil
                    (list (and cmacs-ai-system-prompt
                               (not (string-empty-p cmacs-ai-system-prompt))
                               cmacs-ai-system-prompt)
                          (format "The following is %s from the project \
directory you are working in.  Treat it as standing instructions.\n\n%s"
                                  (file-name-nondirectory path) text)))
              "\n\n"))
            (when cmacs-ai-chat-bootstrap-announce
              (message "cmacs-ai: bootstrapped from %s (%dkB)"
                       (file-name-nondirectory path) (/ size 1024)))
            ;; The caller prepends a directive to this turn only when a
            ;; bootstrap actually happened.
            (file-name-nondirectory path)))
      (error
       (message "cmacs-ai: could not read %s: %s"
                path (error-message-string err))))))

(defun cmacs-ai-chat-send-compose ()
  "Send the contents of the compose region and stream the reply.

The user heading is rendered with `cmacs-ai-user-label' (default
$USER); the assistant heading is rendered as
\\='<provider>/<model>\\=' sourced from ai-glib (see
`cmacs-ai-assistant-label-format').  `cmacs-ai-pre-prompt' is
silently prepended to the text actually sent to the model -- the
buffer always shows exactly what the user typed.

When `cmacs-ai-chat-tool-executor' is non-nil, ai-glib's built-in
tool set is advertised to the model and the chat layer auto-runs
the tool-use loop: model emits tool_use -> we execute, render the
result, and continue the stream until the model stops."
  (interactive)
  (let ((text (cmacs-ai-chat--read-compose)))
    (unless text (user-error "Compose is empty"))
    (if (and (require 'cmacs-ai-image-chat nil 'noerror)
             (cmacs-ai-image-chat-slash-command text))
        ;; `/image PROMPT' generates directly, with no model turn: the
        ;; compose text was a command to us, not something to send on.
        ;; `cmacs-ai-chat--read-compose' has already emptied the region.
        (message "cmacs-ai-image: generating...")
      (cmacs-ai-chat--insert-heading
       (current-buffer) (cmacs-ai-chat--user-label) text)
      ;; Persist the user turn before the network round-trip, so the
      ;; message survives a crash / cancel before the model replies.
      (when cmacs-ai-chat-autosave (cmacs-ai-chat-save-quietly))
      ;; Reset per-turn state.
      (setq cmacs-ai-chat--pending-tool-uses nil
            cmacs-ai-chat--tool-loop-depth 0)
      (let* ((buf (current-buffer))
             (session (cdr cmacs-ai-chat-session-pair))
             (executor cmacs-ai-chat-tool-executor)
             ;; Before the first request only, and invisible in the
             ;; buffer.  Returns the file it injected, if any.
             (bootstrapped (cmacs-ai-chat--apply-bootstrap))
             ;; Directive immediately before what was typed, and inside
             ;; the pre-prompt rather than ahead of it: "then answer what
             ;; follows" has to point at the user's message, not at the
             ;; formatting rules.
             (body (if (and bootstrapped cmacs-ai-chat-bootstrap-directive)
                       (concat (format cmacs-ai-chat-bootstrap-directive
                                       bootstrapped)
                               text)
                     text))
             (sent (cmacs-ai-chat--apply-pre-prompt body)))
        (cmacs-ai-chat-stream
         session sent
         (lambda (payload)
           (cmacs-ai-chat--stream-callback buf payload))
         executor)))))

(defun cmacs-ai-chat-cancel-stream ()
  "Cancel any in-flight chat request on this buffer."
  (interactive)
  (when-let* ((session (cdr cmacs-ai-chat-session-pair)))
    (cmacs-ai-chat-cancel session)
    (setq cmacs-ai-chat--assistant-marker nil)
    (message "cmacs-ai: cancelled")))

(defun cmacs-ai-chat-clear-history ()
  "Clear conversation history (server-side and visible)."
  (interactive)
  (when-let* ((session (cdr cmacs-ai-chat-session-pair)))
    (cmacs-ai-session-clear session))
  (let ((inhibit-read-only t)
        (cmacs-ai-chat--allow-history-edit t))
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "^\\* Conversation$" nil t)
        (forward-line 1)
        (let ((b (point))
              (e (save-excursion
                   (when (re-search-forward "^\\* Compose" nil t)
                     (line-beginning-position)))))
          (when (and b e)
            (delete-region b e)
            (insert "\n")))))))

;;;; Saving ---------------------------------------------------------

(defun cmacs-ai-chat--history-end ()
  "Return the position just before the `* Compose' sentinel.
Everything from `point-min' up to here is the conversation history
\(preamble + turns); the editable compose region below is excluded
from archives, mirroring
`cmacs-libreclaw-cmacs-channel--extract-history'."
  (if cmacs-ai-chat--compose-marker
      (save-excursion
        (goto-char cmacs-ai-chat--compose-marker)
        (forward-line -1)
        (line-beginning-position))
    (point-max)))

(defun cmacs-ai-chat--save-path ()
  "Resolve (and cache) this buffer's archive file under `cmacs-ai-chat-dir'.
The name comes from `cmacs-ai-chat-save-name-format': a
`format-time-string' template (resolved against the buffer's
creation time) whose literal `<provider>' token is replaced with
the provider name."
  (unless (file-directory-p cmacs-ai-chat-dir)
    (make-directory cmacs-ai-chat-dir t))
  (or cmacs-ai-chat--save-file
      (setq cmacs-ai-chat--save-file
            (expand-file-name
             (string-replace
              "<provider>"
              (format "%s" (or cmacs-ai-chat-provider "ai"))
              (format-time-string cmacs-ai-chat-save-name-format
                                  cmacs-ai-chat--created-at))
             cmacs-ai-chat-dir))))

(defun cmacs-ai-chat-save ()
  "Archive the chat history to `cmacs-ai-chat-dir'.  Interactive.
Writes the conversation above `* Compose' (the editable compose
region is excluded).  Always writes, regardless of
`cmacs-ai-chat-autosave'."
  (interactive)
  (let ((p (cmacs-ai-chat--save-path)))
    (write-region (point-min) (cmacs-ai-chat--history-end) p nil 'quiet)
    (message "cmacs-ai: saved %s" p)))

(defun cmacs-ai-chat-save-quietly ()
  "Archive the chat history without echoing the path.
Like `cmacs-ai-chat-save' but silent; used by the automatic save
triggers (which gate on `cmacs-ai-chat-autosave')."
  (let ((p (cmacs-ai-chat--save-path)))
    (write-region (point-min) (cmacs-ai-chat--history-end) p nil 'quiet)))

;;;; Resuming -------------------------------------------------------
;;
;; A saved chat is a self-contained Org transcript (preamble +
;; `* Conversation' turns, no `* Compose').  Resuming reopens it and
;; rebuilds the ai-glib session by replaying the visible turns as
;; user/assistant messages, so the next send carries full context.
;; The C side streams the WHOLE session message list each turn
;; (cmacs/ai/cmacs-ai-stream.c), so a replayed history is real context.
;;
;; Nested `*** tool-use'/`*** tool-result' blocks are NOT replayed:
;; the rebuilt turns are text-only.  This keeps the message list clean
;; (no orphaned tool_result without its tool_use, which providers
;; reject) at the cost of the model not seeing prior tool I/O verbatim.

(defconst cmacs-ai-chat--skip-roles '("error" "tool-loop-aborted")
  "Level-2 heading roles ignored when rebuilding a session.")

(defun cmacs-ai-chat--transcript-property (key)
  "Return the `#+PROPERTY: KEY VALUE' value in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (format "^#\\+PROPERTY: %s[ \t]+\\(.+\\)$" (regexp-quote key))
           nil t)
      (string-trim (match-string 1)))))

(defun cmacs-ai-chat--classify-role (role provider)
  "Classify a level-2 heading ROLE string given PROVIDER (a name string).
Returns the symbol `user' or `assistant', or nil to skip the turn.
Assistant headings render as the downcased provider, optionally
`provider/model' (see `cmacs-ai-chat--assistant-label'); everything
else at level 2 is a user turn."
  (cond
   ((member role cmacs-ai-chat--skip-roles) nil)
   ((string-prefix-p "tool-" role) nil)
   ((or (string-search "/" role)
        (and provider (string= role (downcase provider))))
    'assistant)
   (t 'user)))

(defun cmacs-ai-chat--parse-transcript (&optional provider)
  "Parse the current buffer's chat transcript into session messages.
Returns an ordered list of (ROLE . BODY) cons cells where ROLE is
`user' or `assistant'.  Empty turns are dropped and consecutive
same-role turns are coalesced (bodies joined by a blank line) so the
result strictly alternates -- required by providers like Claude that
reject two same-role messages in a row (the tool loop emits several
`** assistant' headings per user turn).  Nested `*** tool-…' blocks
and `error' headings are skipped.  PROVIDER (a name string)
classifies assistant headings; defaults to the buffer's
`#+PROPERTY: provider'."
  (let ((prov (or provider (cmacs-ai-chat--transcript-property "provider")))
        (turns nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\*\\* +\\(.*\\)$" nil t)
        (let* ((heading (match-string 1))
               (role (if (string-match "  +\\(.*\\)\\'" heading)
                         (string-trim (match-string 1 heading))
                       (string-trim heading)))
               (kind (cmacs-ai-chat--classify-role role prov))
               (body-beg (line-beginning-position 2))
               (body-end (save-excursion
                           (goto-char body-beg)
                           (if (re-search-forward "^\\*+ " nil t)
                               (line-beginning-position)
                             (point-max))))
               (body (string-trim
                      (buffer-substring-no-properties body-beg body-end))))
          (when (and kind (not (string-empty-p body)))
            (push (cons kind body) turns)))))
    ;; Coalesce consecutive same-role turns so roles alternate.
    (let ((acc nil))
      (dolist (turn (nreverse turns))
        (if (and acc (eq (caar acc) (car turn)))
            (setcdr (car acc) (concat (cdar acc) "\n\n" (cdr turn)))
          (push (cons (car turn) (cdr turn)) acc)))
      (nreverse acc))))

(defun cmacs-ai-chat--rebuild-session (session turns)
  "Append parsed TURNS (a list of (ROLE . BODY)) to SESSION.
ROLE is the symbol `user' or `assistant'.  Returns the count appended."
  (let ((n 0))
    (dolist (turn turns n)
      (cmacs-ai-session-append-message session (car turn) (cdr turn))
      (setq n (1+ n)))))

(defun cmacs-ai-chat--restore (buf file)
  "Populate BUF from archived chat FILE and rebuild its ai-glib session.
Loads the saved transcript, appends a fresh `* Compose' sentinel,
enables `cmacs-ai-chat-mode', recreates the session for the saved
provider/model, and replays the conversation into it so the next
turn carries full context.  Subsequent autosaves append to FILE."
  (with-current-buffer buf
    (let ((inhibit-read-only t)
          (cmacs-ai-chat--allow-history-edit t))
      (erase-buffer)
      (insert-file-contents file)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      ;; Ensure a blank separator precedes the compose sentinel, as in
      ;; `cmacs-ai-chat--init'.
      (unless (looking-back "\n\n" (max (point-min) (- (point) 2)))
        (insert "\n"))
      (insert "* Compose                                              :compose:\n"))
    (let* ((provider-str (cmacs-ai-chat--transcript-property "provider"))
           (model-str    (cmacs-ai-chat--transcript-property "model"))
           (provider     (intern (or provider-str
                                      (symbol-name cmacs-ai-default-provider))))
           (turns        (cmacs-ai-chat--parse-transcript provider-str)))
      (cmacs-ai-chat-mode)
      (setq-local cmacs-ai-chat-provider provider)
      (setq-local cmacs-ai-chat-session-pair
                  (cmacs-ai-make-session provider model-str))
      (cmacs-ai-chat--setup-executor)
      (setq-local cmacs-ai-chat--created-at (current-time))
      ;; Continue appending to the SAME archive file.
      (setq-local cmacs-ai-chat--save-file file)
      (setq-local cmacs-ai-chat--compose-marker
                  (save-excursion (goto-char (point-max)) (point-marker)))
      (set-marker-insertion-type cmacs-ai-chat--compose-marker nil)
      (cmacs-ai-chat--rebuild-session (cdr cmacs-ai-chat-session-pair) turns)
      (goto-char (point-max)))))

(defun cmacs-ai-chat--saved-files ()
  "Return archived chat files under `cmacs-ai-chat-dir', newest first."
  (when (file-directory-p cmacs-ai-chat-dir)
    (sort (directory-files cmacs-ai-chat-dir t "\\.org\\'") #'string>)))

(defun cmacs-ai-chat-resume (file)
  "Resume the archived chat FILE, rebuilding its ai-glib session.
Interactively, prompts for one of the `*.org' files in
`cmacs-ai-chat-dir' (newest first).  Reopening an already-resumed
chat just switches to its live buffer."
  (interactive
   (let ((files (cmacs-ai-chat--saved-files)))
     (unless files
       (user-error "No archived chats in %s" cmacs-ai-chat-dir))
     (let ((alist (mapcar (lambda (f)
                            (cons (file-name-nondirectory f) f))
                          files)))
       (list (cdr (assoc (completing-read "Resume chat: "
                                          (mapcar #'car alist) nil t)
                         alist))))))
  (cmacs-ai--ensure)
  (setq file (expand-file-name file))
  (unless (file-readable-p file)
    (user-error "Cannot read %s" file))
  (let* ((name (format "*cmacs-ai: %s*" (file-name-base file)))
         (existing (get-buffer name)))
    (if (and existing (buffer-live-p existing)
             (buffer-local-value 'cmacs-ai-chat-session-pair existing))
        (progn (switch-to-buffer existing) existing)
      (let ((buf (get-buffer-create name)))
        (cmacs-ai-chat--restore buf file)
        (switch-to-buffer buf)
        buf))))

;;;; Cleanup --------------------------------------------------------

(defun cmacs-ai-chat--on-buffer-killed ()
  "Free session resources when the chat buffer is killed.
Archives the conversation first (when `cmacs-ai-chat-autosave') so a
closed chat can be resumed with `cmacs-ai-resume-chat'."
  (when (and cmacs-ai-chat-autosave cmacs-ai-chat--compose-marker)
    (ignore-errors (cmacs-ai-chat-save-quietly)))
  (when cmacs-ai-chat-session-pair
    (cmacs-ai-free-session cmacs-ai-chat-session-pair)
    (setq cmacs-ai-chat-session-pair nil))
  (when cmacs-ai-chat-tool-executor
    (cmacs-ai-tools-free cmacs-ai-chat-tool-executor)
    (setq cmacs-ai-chat-tool-executor nil))
  (setq cmacs-ai-chat--buffers
        (delq (current-buffer) cmacs-ai-chat--buffers)))

;;;; Buffer listing ------------------------------------------------

(defun cmacs-ai-list-chats ()
  "Switch to one of the live cmacs-ai chat buffers."
  (interactive)
  (setq cmacs-ai-chat--buffers
        (cl-remove-if-not #'buffer-live-p cmacs-ai-chat--buffers))
  (let ((bufs (mapcar #'buffer-name cmacs-ai-chat--buffers)))
    (unless bufs (user-error "No cmacs-ai chat buffers"))
    (switch-to-buffer
     (completing-read "cmacs-ai chat: " bufs nil t))))

(provide 'cmacs-ai-chat)
;;; cmacs-ai-chat.el ends here
