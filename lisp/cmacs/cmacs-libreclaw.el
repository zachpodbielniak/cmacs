;;; cmacs-libreclaw.el --- LibreClaw chat/Matrix integration  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; LibreClaw integration for cmacs.  Runs libreclaw (a GObject-native
;; Matrix/email/webhook/local AI agent gateway) inside Emacs, sharing
;; cmacs's existing podomation PodEngine and surfacing each "room"
;; (Matrix room, email inbox, etc.) as an org-mode buffer in the
;; style of ellama.
;;
;; Entry points:
;;
;;   M-x cmacs-libreclaw-start            ; bring up libreclaw
;;   M-x cmacs-libreclaw-stop             ; shut down
;;   M-x cmacs-libreclaw-hatch            ; run the workspace wizard
;;                                        ; (see cmacs-libreclaw-hatch.el)
;;
;; Buffers created by incoming channel `room-added' signals use
;; `cmacs-libreclaw-room-mode', which is derived from `org-mode'.
;; The buffer layout is:
;;
;;     #+TITLE: LibreClaw — <room-name>
;;     * Messages
;;     ** YYYY-MM-DD HH:MM:SS  <sender>
;;     <body>
;;     ...
;;     * Compose                                              :compose:
;;     <editable compose area — C-c C-c sends>
;;
;; History above the `* Compose' sentinel is read-only (enforced via
;; `before-change-functions').  `RET' is ordinary org-mode RET so the
;; user can write multi-line messages, source blocks, links, etc.
;; before pressing `C-c C-c' to send.
;;
;; Configuration: point `cmacs-libreclaw-config-file' at a libreclaw
;; YAML config (typically produced by the hatch wizard), then run
;; `cmacs-libreclaw-start'.

;;; Code:

(require 'org)
(require 'cl-lib)

;; Optional — load cmacs-gi if available so scripts can reach libreclaw
;; via `(gi-require "Lc" "1.0")`.  Don't hard-require: in tests or in
;; environments built --without-cmacs-gi this should degrade cleanly.
(defvar cmacs-libreclaw--have-gi (featurep 'cmacs-gi)
  "Non-nil if cmacs-gi was loaded at startup.")

;;;; Customisation ---------------------------------------------------

(defgroup cmacs-libreclaw nil
  "LibreClaw chat/Matrix client integration for cmacs."
  :group 'cmacs
  :prefix "cmacs-libreclaw-")

(defcustom cmacs-libreclaw-config-file nil
  "Path to the libreclaw YAML configuration file.
Set this before calling `cmacs-libreclaw-start'.  The hatch wizard
writes this path on finalize; you can also point at a hand-authored
config."
  :type '(choice (const :tag "None" nil) file)
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-auto-start nil
  "If non-nil, call `cmacs-libreclaw-start' on `after-init-hook'."
  :type 'boolean
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-buffer-name-format
  "*libreclaw:%s:%s*"
  "Format string for room buffer names.
First %s is the channel id, second %s is the room id."
  :type 'string
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-my-name "you"
  "Sender label used for locally-echoed outbound messages."
  :type 'string
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-timestamp-format "%Y-%m-%d %H:%M:%S"
  "Strftime-style format used for message heading timestamps."
  :type 'string
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-default-workspace
  (expand-file-name "~/.libreclaw")
  "Default workspace directory used by `cmacs-libreclaw-generate-default-config'.
This is where the auto-generated YAML and any supporting files
(SOUL.md, audit.sqlite, etc.) will live when the user hasn't
explicitly pointed `cmacs-libreclaw-config-file' somewhere else."
  :type 'directory
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-default-ai-provider 'claude
  "AI provider baked into the auto-generated default YAML config.
One of the symbols `claude', `openai', or `both'."
  :type '(choice (const :tag "Claude (Anthropic)"  claude)
                 (const :tag "OpenAI"               openai)
                 (const :tag "Both (smart routing)" both))
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-default-prompt "libreclaw> "
  "Prompt string for the local channel in the auto-generated config."
  :type 'string
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-auto-generate-config t
  "If non-nil, `cmacs-libreclaw-start' auto-creates a default config
at `cmacs-libreclaw-default-workspace' when `cmacs-libreclaw-config-file'
is not set and no existing file is found.  The user is still prompted
for confirmation before anything is written to disk."
  :type 'boolean
  :group 'cmacs-libreclaw)

;;;; Hooks -----------------------------------------------------------

(defvar cmacs-libreclaw-message-hook nil
  "Hook run when an inbound message arrives in any room.
Each function is called with three arguments:
  CHANNEL-ID ROOM-ID MESSAGE-PLIST
where MESSAGE-PLIST has keys :channel-id :sender-id :sender-name
:room-id :thread-id :body :timestamp.")

(defvar cmacs-libreclaw-room-added-hook nil
  "Hook run when a new room buffer is created.
Each function is called with three arguments:
  CHANNEL-ID ROOM-ID ROOM-BUFFER.")

;;;; State ----------------------------------------------------------

(defvar cmacs-libreclaw-rooms-alist nil
  "Alist of ((CHANNEL-ID . ROOM-ID) . BUFFER).
Updated by `cmacs-libreclaw--on-room-added' and
`cmacs-libreclaw--on-room-removed'.")

(defvar-local cmacs-libreclaw-room-channel nil
  "LibreClaw channel-id for this room buffer.")

(defvar-local cmacs-libreclaw-room-id nil
  "LibreClaw room-id for this buffer.")

(defvar-local cmacs-libreclaw-room-name nil
  "Human-readable room name for this buffer.")

(defvar-local cmacs-libreclaw-room--compose-marker nil
  "Marker pointing at the start of the compose region.
Everything before this marker is the read-only history section;
everything from here to `point-max' is the editable compose area.")

(defvar-local cmacs-libreclaw-room--pending nil
  "List of pending messages when the buffer is temporarily hidden.")

(defvar cmacs-libreclaw--allow-history-edit nil
  "Dynamic override for `cmacs-libreclaw--protect-history'.
Bound to non-nil around C-side dispatch paths that legitimately
need to insert headings above the compose sentinel (incoming
messages, room-closed notices, etc.).  User-initiated edits never
set this flag, so manual edits above the sentinel still error out
with `text-read-only'.")

;;;; Keymap / mode --------------------------------------------------

(defvar cmacs-libreclaw-room-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cmacs-libreclaw-send-compose)
    (define-key m (kbd "C-c C-k") #'cmacs-libreclaw-clear-compose)
    (define-key m (kbd "C-c C-x C-f") #'cmacs-libreclaw-attach-file)
    m)
  "Keymap for `cmacs-libreclaw-room-mode'.
Binds `C-c C-c' to send and leaves `RET' free for multi-line editing.")

(defun cmacs-libreclaw--protect-history (beg _end)
  "Reject edits BEG.._END that fall above the compose marker.
Skipped when `cmacs-libreclaw--allow-history-edit' is non-nil so
signal-dispatch code can legitimately insert history headings."
  (when (and (not cmacs-libreclaw--allow-history-edit)
             cmacs-libreclaw-room--compose-marker
             (< beg cmacs-libreclaw-room--compose-marker))
    (signal 'text-read-only
            (list "LibreClaw history is read-only; edit below the Compose heading"))))

(define-derived-mode cmacs-libreclaw-room-mode org-mode "LC-Room"
  "Major mode for cmacs-libreclaw chat room buffers.
Derived from `org-mode'.  Chat history lives above the `* Compose'
sentinel heading and is read-only; the region below is the compose
area.  `C-c C-c' sends the compose content as a new message.

\\{cmacs-libreclaw-room-mode-map}"
  (setq-local org-hide-emphasis-markers nil)
  (setq-local org-startup-folded 'showall)
  (setq-local org-adapt-indentation nil)
  (add-hook 'before-change-functions
            #'cmacs-libreclaw--protect-history nil t)
  (add-hook 'kill-buffer-hook
            #'cmacs-libreclaw--on-buffer-killed nil t))

;;;; Buffer construction / updates ----------------------------------

(defun cmacs-libreclaw--init-room-buffer (buf channel room-id room-name)
  "Initialize BUF as a libreclaw room buffer.
CHANNEL is the channel-id, ROOM-ID is the room identifier,
ROOM-NAME is a human-readable label (falls back to ROOM-ID)."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "#+TITLE: LibreClaw — %s\n"
                      (or room-name room-id)))
      (insert "#+STARTUP: showall indent\n")
      (insert "#+OPTIONS: toc:nil num:nil\n")
      (insert (format "#+PROPERTY: channel %s\n" channel))
      (insert (format "#+PROPERTY: room-id %s\n" room-id))
      (insert "\n")
      (insert "* Messages\n\n")
      (insert "* Compose                                              :compose:\n"))
    ;; Enter the mode AFTER the buffer is populated so org-mode
    ;; parses the final structure.  protect-history hook is then
    ;; installed on the full buffer.
    (cmacs-libreclaw-room-mode)
    (setq-local cmacs-libreclaw-room-channel channel)
    (setq-local cmacs-libreclaw-room-id room-id)
    (setq-local cmacs-libreclaw-room-name room-name)
    (setq-local cmacs-libreclaw-room--compose-marker
                (save-excursion
                  (goto-char (point-max))
                  (point-marker)))
    (set-marker-insertion-type cmacs-libreclaw-room--compose-marker nil)
    (goto-char (point-max))))

(defun cmacs-libreclaw--ensure-room-buffer (channel room-id &optional room-name)
  "Return (creating if necessary) the buffer for CHANNEL/ROOM-ID."
  (let* ((key (cons channel room-id))
         (existing (cdr (assoc key cmacs-libreclaw-rooms-alist))))
    (if (and existing (buffer-live-p existing))
        existing
      (let* ((buf-name (format cmacs-libreclaw-buffer-name-format
                               channel room-id))
             (buf (get-buffer-create buf-name)))
        (cmacs-libreclaw--init-room-buffer buf channel room-id
                                           (or room-name room-id))
        (setf (alist-get key cmacs-libreclaw-rooms-alist
                          nil nil #'equal) buf)
        (run-hook-with-args 'cmacs-libreclaw-room-added-hook
                            channel room-id buf)
        buf))))

(defun cmacs-libreclaw--insert-heading (buf sender body timestamp)
  "Insert a message heading into BUF inside the `* Messages' section.

The buffer layout is:

  * Messages
  ...                          <- past headings land here
  * Compose                   :compose:
  <compose body>

Previously this function inserted at the END of the `* Compose'
headline, which made the new `** ...' entry a level-2 child of
`* Compose' instead of `* Messages'.  The fix is to insert at
the BEGINNING of the `* Compose' line — so the new heading is
placed just before `* Compose' and becomes the last child of
the preceding `* Messages' section.

The inserted text always ends with a trailing blank line so
consecutive message entries are visually separated in the
rendered org buffer.

Binds `cmacs-libreclaw--allow-history-edit' around the inserts
so the history-protection hook lets the C-side dispatch path
through; user edits above the compose marker remain blocked."
  (with-current-buffer buf
    (save-excursion
      (goto-char cmacs-libreclaw-room--compose-marker)
      ;; Step back onto the `* Compose' sentinel line itself.
      (forward-line -1)
      (beginning-of-line)
      (let ((inhibit-read-only t)
            (cmacs-libreclaw--allow-history-edit t)
            (body* (or body "")))
        (insert (format "** %s  %s\n" timestamp sender))
        (insert body*)
        ;; Ensure the body ends with a newline ...
        (unless (and (> (length body*) 0)
                     (eq (aref body* (1- (length body*))) ?\n))
          (insert "\n"))
        ;; ... plus a blank line so the next heading (or the
        ;; `* Compose' sentinel) is visually separated.
        (insert "\n")))))

;;;; Signal dispatch entry points (called from C) -------------------

(defun cmacs-libreclaw--on-room-added (channel room-id &optional room-name)
  "Handle room-added signal.  Create the buffer if needed."
  (cmacs-libreclaw--ensure-room-buffer channel room-id room-name))

(defun cmacs-libreclaw--on-room-removed (channel room-id)
  "Handle room-removed signal.  Mark the buffer stale but preserve history."
  (let* ((key (cons channel room-id))
         (buf (cdr (assoc key cmacs-libreclaw-rooms-alist))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (cmacs-libreclaw--allow-history-edit t))
          (save-excursion
            (goto-char cmacs-libreclaw-room--compose-marker)
            (forward-line -1)
            (end-of-line)
            (insert "\n** (room closed)\n")))))))

(defun cmacs-libreclaw--on-message (channel room-id msg-plist &rest _)
  "Handle inbound message.  MSG-PLIST is a plist of message fields.

This generic handler is wired to every registered channel's
`message-received' signal via the C bridge in
`cmacs-libreclaw-room.c'.  It inserts the message as a new
heading and runs the public hook.

The `cmacs' channel is the exception: it has its own dedicated
flow in `cmacs-libreclaw-cmacs-channel.el' that handles both
the user's outbound message (echoed locally in
`cmacs-libreclaw-cmacs-channel-send-compose') and the AI
response (routed through `cmacs-libreclaw--on-cmacs-response'
via the channel's send_message_async vfunc).  If we let the
generic handler also fire for the cmacs channel we'd get
double-inserted user messages and the ordering would be
scrambled, because libreclaw's own command-handler path runs
synchronously during the inject and inserts the response
*before* the user's own message would be dispatched.  Skip the
cmacs channel here and let the dedicated flow handle it."
  (unless (equal channel "cmacs")
    (let* ((sender (or (plist-get msg-plist :sender-name)
                       (plist-get msg-plist :sender-id)
                       "?"))
           (body (or (plist-get msg-plist :body) ""))
           (ts (format-time-string cmacs-libreclaw-timestamp-format
                                   (seconds-to-time
                                    (or (plist-get msg-plist :timestamp)
                                        0))))
           (buf (cmacs-libreclaw--ensure-room-buffer channel room-id)))
      (cmacs-libreclaw--insert-heading buf sender body ts)
      (run-hook-with-args 'cmacs-libreclaw-message-hook
                          channel room-id msg-plist))))

(defun cmacs-libreclaw--on-message-sent (channel room-id msg-plist &rest _)
  "Handle locally-sent message echo from the C layer.
We already insert an optimistic heading on `cmacs-libreclaw-send-compose',
so for now we only run the hook — dedup-by-id is future work."
  (run-hook-with-args 'cmacs-libreclaw-message-hook
                      channel room-id msg-plist))

(defun cmacs-libreclaw--on-channel-state (channel connected &rest _)
  "Handle connection-changed.  Update modeline on any affected buffer."
  (dolist (entry cmacs-libreclaw-rooms-alist)
    (when (equal (caar entry) channel)
      (let ((buf (cdr entry)))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (setq mode-name (if connected "LC-Room" "LC-Room(off)"))
            (force-mode-line-update)))))))

(defun cmacs-libreclaw--on-session-created (session-key &rest _)
  (ignore session-key))

(defun cmacs-libreclaw--on-session-destroyed (session-key &rest _)
  (ignore session-key))

(defun cmacs-libreclaw--on-buffer-killed ()
  "Remove this buffer from `cmacs-libreclaw-rooms-alist' on kill."
  (when (and cmacs-libreclaw-room-channel cmacs-libreclaw-room-id)
    (setq cmacs-libreclaw-rooms-alist
          (cl-remove-if
           (lambda (entry)
             (equal (car entry)
                    (cons cmacs-libreclaw-room-channel
                          cmacs-libreclaw-room-id)))
           cmacs-libreclaw-rooms-alist))))

;;;; Compose / send -------------------------------------------------

(defun cmacs-libreclaw-send-compose ()
  "Send the compose region as a message and clear it."
  (interactive)
  (unless (and cmacs-libreclaw-room-channel cmacs-libreclaw-room-id)
    (user-error "Not in a cmacs-libreclaw room buffer"))
  (unless cmacs-libreclaw-room--compose-marker
    (user-error "No compose marker in this buffer"))
  (let* ((start (marker-position cmacs-libreclaw-room--compose-marker))
         (end   (point-max))
         (body  (string-trim (buffer-substring-no-properties start end))))
    (when (> (length body) 0)
      (cmacs-libreclaw-send-message
       cmacs-libreclaw-room-channel
       cmacs-libreclaw-room-id
       body)
      ;; Optimistic local echo.
      (let ((inhibit-read-only t))
        (delete-region start end))
      (cmacs-libreclaw--insert-heading
       (current-buffer)
       cmacs-libreclaw-my-name body
       (format-time-string cmacs-libreclaw-timestamp-format)))))

(defun cmacs-libreclaw-clear-compose ()
  "Clear the compose region without sending."
  (interactive)
  (when cmacs-libreclaw-room--compose-marker
    (let ((inhibit-read-only t))
      (delete-region cmacs-libreclaw-room--compose-marker (point-max)))))

(defun cmacs-libreclaw-attach-file (file)
  "Attach FILE to the next outgoing message as an org link."
  (interactive "fAttach file: ")
  (insert (format "[[file:%s][%s]]"
                  (expand-file-name file)
                  (file-name-nondirectory file))))

;;;; Default config generation -------------------------------------

(defun cmacs-libreclaw--hatch-build-default (handle workspace-dir ai-provider)
  "Populate HANDLE with a sensible default libreclaw config.
WORKSPACE-DIR determines the agent workspace path and doubles as
the default for the workspace name (basename).  AI-PROVIDER is
one of the symbols `claude', `openai', or `both'.

The generated config enables the native cmacs channel — an
in-process LcChannel that the Emacs host drives via
`cmacs-libreclaw-cmacs-channel-inject' and a response callback.
This is the channel `cmacs-libreclaw-open' uses to give each
project directory its own persistent chat buffer.

Also includes the Emacs-channel preamble — a CMACS_EMACS_CHANNEL.md
identity file baked into the workspace that tells the AI its
responses are rendered in an Emacs org-mode buffer and instructs
it to start headings at `***' so they don't collide with the
buffer's own `*' and `**' structural layout."
  (let ((name (file-name-nondirectory
               (directory-file-name workspace-dir))))
    ;; Workspace names must match ^[a-zA-Z][a-zA-Z0-9_-]*$ — fall
    ;; back to "default" if the directory basename doesn't qualify.
    (unless (and (> (length name) 0)
                 (string-match-p "\\`[a-zA-Z][a-zA-Z0-9_-]*\\'" name))
      (setq name "default"))
    (cmacs-libreclaw-hatch-set-name handle name)
    (cmacs-libreclaw-hatch-set-ai   handle ai-provider)
    ;; Default to the native cmacs channel — no credentials, no
    ;; stdin/stdout dependency, and it supports multiple rooms so
    ;; `cmacs-libreclaw-open' can give every project its own
    ;; buffer out of the box.
    (cmacs-libreclaw-hatch-add-cmacs handle)
    ;; Ship the org-mode-aware response preamble so the AI's
    ;; responses format cleanly inside cmacs buffers.
    (cmacs-libreclaw-hatch-include-emacs-preamble handle)))

;;;###autoload
(defun cmacs-libreclaw-generate-default-config
    (&optional workspace-dir ai-provider overwrite)
  "Write a minimal default libreclaw YAML config to disk.

The generated config enables a single Local (stdin/stdout) channel
with the AI provider chosen by AI-PROVIDER (defaults to
`cmacs-libreclaw-default-ai-provider').  Podomation and the audit
log are left disabled.  No secrets are required — the user can
later run `cmacs-libreclaw-hatch' for the full wizard or edit the
resulting YAML directly.

WORKSPACE-DIR defaults to `cmacs-libreclaw-default-workspace'.
With a non-nil prefix arg, OVERWRITE replaces any existing
`config.yaml' in the workspace.

Returns the path of the written config file.  Also sets
`cmacs-libreclaw-config-file' so `cmacs-libreclaw-start' picks it
up on the next call."
  (interactive
   (list (read-directory-name "Workspace directory: "
                              cmacs-libreclaw-default-workspace)
         (intern (completing-read "AI provider: "
                                  '("claude" "openai" "both") nil t
                                  (symbol-name
                                   cmacs-libreclaw-default-ai-provider)))
         current-prefix-arg))
  (let* ((ws (expand-file-name
              (or workspace-dir cmacs-libreclaw-default-workspace)))
         (ai (or ai-provider cmacs-libreclaw-default-ai-provider))
         (handle (cmacs-libreclaw-hatch-new ws))
         path)
    (unwind-protect
        (progn
          (cmacs-libreclaw--hatch-build-default handle ws ai)
          (setq path (cmacs-libreclaw-hatch-finalize handle
                                                     (not (null overwrite)))))
      (cmacs-libreclaw-hatch-free handle))
    (when path
      (setq cmacs-libreclaw-config-file path)
      ;; Also sync the C-side config path so a subsequent
      ;; `cmacs-libreclaw--start-internal' (bypassing the Elisp
      ;; wrapper) still sees the generated file.  The wrapper does
      ;; this via `cmacs-libreclaw-set-config-file' too, but
      ;; scripted callers shouldn't have to know about the two-side
      ;; sync dance.
      (cmacs-libreclaw-set-config-file path)
      (message "Wrote default libreclaw config to %s" path))
    path))

(defun cmacs-libreclaw-ensure-config ()
  "Ensure `cmacs-libreclaw-config-file' points at a readable YAML.

If it's already set and readable, do nothing.  If it's unset but
a config already exists at the default workspace location, adopt
that.  Otherwise, when `cmacs-libreclaw-auto-generate-config' is
non-nil, prompt the user and call
`cmacs-libreclaw-generate-default-config' to scaffold a minimal
working config.

Called automatically by `cmacs-libreclaw-start' so new users can
get from zero → running subsystem in one command."
  (interactive)
  (let ((default-path (expand-file-name
                       "config.yaml"
                       cmacs-libreclaw-default-workspace)))
    (cond
     ;; Explicitly-set config that already exists — nothing to do.
     ((and cmacs-libreclaw-config-file
           (file-readable-p cmacs-libreclaw-config-file))
      cmacs-libreclaw-config-file)

     ;; Adopt a pre-existing config at the default workspace.
     ((and (null cmacs-libreclaw-config-file)
           (file-readable-p default-path))
      (setq cmacs-libreclaw-config-file default-path)
      (message "Using existing libreclaw config at %s" default-path)
      default-path)

     ;; Auto-generate (with user consent) when the knob is enabled.
     ((and cmacs-libreclaw-auto-generate-config
           (or (null cmacs-libreclaw-config-file)
               (not (file-readable-p cmacs-libreclaw-config-file)))
           (yes-or-no-p
            (format "No libreclaw config found. Generate a default at %s? "
                    default-path)))
      (cmacs-libreclaw-generate-default-config
       cmacs-libreclaw-default-workspace
       cmacs-libreclaw-default-ai-provider))

     ;; Nothing to offer — let the caller handle the error.
     (t nil))))

;;;###autoload
(defun cmacs-libreclaw-load-config (file &optional restart)
  "Point cmacs-libreclaw at a specific YAML config FILE.

This is the one-command way to switch libreclaw to a different
configuration, from your init file or interactively.  It:

1. Expands FILE via `expand-file-name' (tilde + relative paths).
2. Asserts the file exists and is readable.
3. Sets `cmacs-libreclaw-config-file' to the expanded path.
4. If libreclaw is already running and RESTART is non-nil (or,
   interactively, the user confirms), stops and restarts the
   subsystem so the new config takes effect.  When RESTART is
   nil and libreclaw is already running, the new config is
   staged for the next `cmacs-libreclaw-start' / restart cycle
   and a message reminds the user.
5. If libreclaw is NOT running, the config is staged and
   `cmacs-libreclaw-start' will pick it up on the next call.

Return value: the expanded config file path.

Typical init-file usage:

  ;; Option A — declarative, picked up lazily at first use:
  (setq cmacs-libreclaw-config-file \"~/.libreclaw/work.yaml\")

  ;; Option B — imperative, one call:
  (cmacs-libreclaw-load-config \"~/.libreclaw/work.yaml\")

  ;; Option C — switch configs at runtime without restarting Emacs:
  (cmacs-libreclaw-load-config \"~/.libreclaw/home.yaml\" t)

Note: switching configs restarts libreclaw, which clears
in-memory session state.  libreclaw's own session persistence
(keyed on `channel:room:sender') is unaffected — opening a room
in the new config resumes any previously-persisted AI context
for the same session key.  To hot-reload edits to the SAME
config file without a full restart, use
`cmacs-libreclaw-reload-config' instead."
  (interactive
   (list (read-file-name "libreclaw config.yaml: "
                         (or (and cmacs-libreclaw-config-file
                                  (file-name-directory
                                   cmacs-libreclaw-config-file))
                             cmacs-libreclaw-default-workspace)
                         nil t)
         nil))
  (let ((path (expand-file-name file)))
    (unless (file-readable-p path)
      (user-error "Config file not readable: %s" path))
    (setq cmacs-libreclaw-config-file path)
    (cond
     ((not (cmacs-libreclaw-running-p))
      (message "cmacs-libreclaw: staged config %s (not running)" path))
     ((or restart
          (and (called-interactively-p 'interactive)
               (y-or-n-p
                (format "libreclaw is running — restart against %s? "
                        path))))
      (cmacs-libreclaw-stop)
      (cmacs-libreclaw-start)
      (message "cmacs-libreclaw: restarted with %s" path))
     (t
      (message "cmacs-libreclaw: staged config %s — %s to apply"
               path
               "restart via `cmacs-libreclaw-stop' + `cmacs-libreclaw-start'")))
    path))

;;;; Lifecycle wrappers ---------------------------------------------

(defun cmacs-libreclaw-start ()
  "Start libreclaw using `cmacs-libreclaw-config-file'.

If no config is set, `cmacs-libreclaw-ensure-config' is called
first, which adopts an existing default config or (with user
consent) auto-generates a minimal one via
`cmacs-libreclaw-generate-default-config'.

Also ensures cmacs-podomation is running (libreclaw shares its
PodEngine) and loads the Lc-1.0 GI typelib if cmacs-gi is
available."
  (interactive)
  (unless (cmacs-libreclaw-running-p)
    (cmacs-libreclaw-ensure-config)
    (unless cmacs-libreclaw-config-file
      (user-error "Set `cmacs-libreclaw-config-file' before starting"))
    (unless (file-readable-p cmacs-libreclaw-config-file)
      (user-error "Config file not readable: %s"
                  cmacs-libreclaw-config-file))
    ;; Ensure podomation is up first — libreclaw shares its engine.
    (when (and (fboundp 'cmacs-podomation-running-p)
               (not (cmacs-podomation-running-p)))
      (cmacs-podomation-start))
    (cmacs-libreclaw-set-config-file
     (expand-file-name cmacs-libreclaw-config-file))
    (cmacs-libreclaw--start-internal)
    (when (fboundp 'gi-require)
      (ignore-errors (gi-require "Lc" "1.0")))))

(defun cmacs-libreclaw-list-rooms (&optional channel)
  "Return a list of (CHANNEL . ROOM-ID . NAME) triples.
If CHANNEL is non-nil, filter to that channel."
  (cl-loop for entry in cmacs-libreclaw-rooms-alist
           for (ch . room) = (car entry)
           for buf = (cdr entry)
           when (or (null channel) (equal channel ch))
           collect (list ch room
                         (with-current-buffer buf
                           cmacs-libreclaw-room-name))))

(defun cmacs-libreclaw-show-room (channel room-id)
  "Switch to the room buffer for CHANNEL / ROOM-ID, creating if needed."
  (interactive
   (let* ((rooms (cmacs-libreclaw-list-rooms))
          (choices (mapcar
                    (lambda (r) (format "%s/%s" (nth 0 r) (nth 1 r)))
                    rooms))
          (pick (completing-read "Room: " choices nil t))
          (idx (cl-position pick choices :test #'equal))
          (row (nth idx rooms)))
     (list (nth 0 row) (nth 1 row))))
  (pop-to-buffer (cmacs-libreclaw--ensure-room-buffer channel room-id)))

;;;; Global minor mode ----------------------------------------------

;;;###autoload
(define-minor-mode cmacs-libreclaw-mode
  "Global minor mode toggling the libreclaw subsystem on/off."
  :global t
  :group 'cmacs-libreclaw
  (if cmacs-libreclaw-mode
      (cmacs-libreclaw-start)
    (cmacs-libreclaw-stop)))

(when cmacs-libreclaw-auto-start
  (add-hook 'after-init-hook #'cmacs-libreclaw-start))

;;; The companion cmacs channel layer lives in
;;; cmacs-libreclaw-cmacs-channel.el and is autoloaded on demand via
;;; its `;;;###autoload' cookies (notably `cmacs-libreclaw-open' and
;;; `cmacs-libreclaw-list-cmacs-rooms').  We do NOT require it here
;;; because it requires this file back — the autoload path keeps
;;; the dependency one-directional.

(provide 'cmacs-libreclaw)

;;; cmacs-libreclaw.el ends here
