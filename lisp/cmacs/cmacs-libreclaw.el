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

(defcustom cmacs-libreclaw-save-conversations-dir nil
  "Directory to which embedded-mode conversations are archived.

When non-nil, every embedded libreclaw room buffer (Matrix,
email, webhook, the Local channel, and the native cmacs channel)
is mirrored to a standalone `.org' file in this directory.  The
file is rewritten as messages arrive and again when the room
buffer is killed, so it always reflects the full conversation.

This is independent of the remote-mode
`cmacs-libreclaw-remote-save-conversations-dir' — the two modes
keep separate settings so they can archive to different places.
Leave nil (the default) to disable archiving for embedded mode.

Note: this is additive — the native cmacs channel keeps its own
per-project session persistence under `~/.libreclaw/' regardless.

The file name is built from
`cmacs-libreclaw-save-conversations-name-format'."
  :type '(choice (const :tag "Disabled" nil) directory)
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-save-conversations-name-format
  "%y%m%d-%H%M%S-<agent-name>.org"
  "File-name format for archived embedded-mode conversations.

Used only when `cmacs-libreclaw-save-conversations-dir' is set.
The string is first passed through `format-time-string' with the
conversation's start time (so the usual `%y', `%m', `%d', `%H',
`%M', `%S' directives all work), and then the literal token
`<agent-name>' is replaced with the agent name returned by
`cmacs-libreclaw-agent-name' (the `agent.name' field from the
loaded libreclaw config.yaml).

The default yields names like `260522-143015-claude.org'."
  :type 'string
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

(defvar-local cmacs-libreclaw-room--view nil
  "Signature of the screen as of the last message that described it.
Compared against `cmacs-ai-view-signature' so an unchanged screen is
not listed again on every message.")

(defvar-local cmacs-libreclaw-room--hinted nil
  "Non-nil once this room has been told what the screen listing means.
The standing explanation rides the first outgoing message; libreclaw
owns the agent\'s system prompt (it is assembled from the workspace
identity files by `LcApp\'), so there is nowhere else to put it.")

(defvar-local cmacs-libreclaw-room--created-at nil
  "Time the room buffer was created.
Used as the timestamp portion of the archived-conversation file
name (see `cmacs-libreclaw-save-conversations-dir').  Captured
once so the file name stays stable as the file is rewritten.")

(defvar-local cmacs-libreclaw-room--save-file nil
  "Absolute path of this room's archived-conversation file.
Resolved lazily on the first save (so the agent name is known)
and then cached, so subsequent saves rewrite the same file.")

(declare-function cmacs-libreclaw-agent-name "cmacs-libreclaw.c" ())

;; Soft: cmacs-ai-view is pure Elisp and always present in a normal
;; tree, but libreclaw must still build and run in a --without-cmacs-ai
;; checkout, so every call is guarded rather than assumed.
(require 'cmacs-ai-view nil t)
(declare-function cmacs-ai-view-attach "cmacs-ai-view" (&optional arg))
(declare-function cmacs-ai-view-hint "cmacs-ai-view" (mode))
(declare-function cmacs-ai-view-turn-block "cmacs-ai-view"
                  (mode &optional last-signature))

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
    ;; Shadows `org-attach' here, deliberately: in a chat buffer
    ;; "attach" means the buffers you are looking at.
    (define-key m (kbd "C-c C-a") #'cmacs-ai-view-attach)
    m)
  "Keymap for `cmacs-libreclaw-room-mode'.
Binds `C-c C-c' to send and leaves `RET' free for multi-line editing.")

(defconst cmacs-libreclaw--seal-props '(read-only t front-sticky t)
  "Text properties making a delivered message unmodifiable.

`front-sticky\' is load-bearing and the comint idiom is a trap: with
`(read-only t rear-nonsticky t)\' Emacs decides inserted text would join
neither neighbouring interval and PERMITS insertion in the middle of the
sealed text -- the one place it must not.

Nothing is needed at the trailing edge: the blank separator line above
`* Compose\' is left unsealed, so the characters between the transcript
and the compose region carry no property to inherit.")

(defun cmacs-libreclaw--seal-history ()
  "Seal the delivered messages, and re-arm the change guard.

The transcript is protected by a `read-only\' TEXT PROPERTY, applied
here after each message lands.  `cmacs-libreclaw--protect-history\'
alone is not enough and cannot be made enough: Emacs CLEARS
`before-change-functions\' when a function on it signals, so a guard
that signals `text-read-only\' protects the buffer exactly once -- after
the first stray keypress above `* Compose\', every edit lands.  The
property is enforced in C and cannot be disarmed that way.

Re-adding the guard here means a clearing heals itself at the next
message rather than lasting for the rest of the session."
  (when cmacs-libreclaw-room--compose-marker
    (let ((end (save-excursion
                 (goto-char cmacs-libreclaw-room--compose-marker)
                 (forward-line -1)
                 (max (point-min) (1- (line-beginning-position))))))
      (when (> end (point-min))
        (let ((inhibit-read-only t)
              (cmacs-libreclaw--allow-history-edit t))
          (add-text-properties (point-min) end
                               cmacs-libreclaw--seal-props)))))
  (add-hook 'before-change-functions
            #'cmacs-libreclaw--protect-history nil t))

(defun cmacs-libreclaw--protect-history (beg _end)
  "Reject edits BEG.._END that fall above the compose marker.
Skipped when `cmacs-libreclaw--allow-history-edit' is non-nil so
signal-dispatch code can legitimately insert history headings.

The second line of defence, not the first: see
`cmacs-libreclaw--seal-history\' for why a signalling change hook cannot
protect a buffer more than once, and what actually does."
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
    (setq-local cmacs-libreclaw-room--created-at (current-time))
    (setq-local cmacs-libreclaw-room--compose-marker
                (save-excursion
                  (goto-char (point-max))
                  (point-marker)))
    (set-marker-insertion-type cmacs-libreclaw-room--compose-marker nil)
    (cmacs-libreclaw--seal-history)
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
        (insert "\n")))
    ;; A delivered message is finished text.
    (cmacs-libreclaw--seal-history)))

;;;; Conversation archiving -----------------------------------------

(defun cmacs-libreclaw--sanitize-file-component (s)
  "Return S made safe for use as a single file-name component.
Runs of characters outside [A-Za-z0-9._-] collapse to a single
hyphen; an empty result falls back to \"agent\"."
  (let ((clean (replace-regexp-in-string
                "[^A-Za-z0-9._-]+" "-" (or s ""))))
    (setq clean (replace-regexp-in-string "\\`-+\\|-+\\'" "" clean))
    (if (string-empty-p clean) "agent" clean)))

(defun cmacs-libreclaw--conversation-agent-name (channel)
  "Return the agent name for CHANNEL, for archive file naming.
Embedded channels use `cmacs-libreclaw-agent-name'; the remote
\"bridge\" channel uses `cmacs-libreclaw-remote-agent-name'.
Falls back to the room name, then to \"agent\"."
  (let ((name (if (equal channel "bridge")
                  (and (fboundp 'cmacs-libreclaw-remote-agent-name)
                       (cmacs-libreclaw-remote-agent-name))
                (and (fboundp 'cmacs-libreclaw-agent-name)
                     (cmacs-libreclaw-agent-name)))))
    (or (and (stringp name) (not (string-empty-p name)) name)
        (and (stringp cmacs-libreclaw-room-name)
             (not (string-empty-p cmacs-libreclaw-room-name))
             cmacs-libreclaw-room-name)
        "agent")))

(defun cmacs-libreclaw--conversation-archive-dir (channel)
  "Return the configured archive directory for CHANNEL, or nil.
The remote \"bridge\" channel and embedded channels have separate
settings so they can be archived independently."
  (if (equal channel "bridge")
      (bound-and-true-p cmacs-libreclaw-remote-save-conversations-dir)
    cmacs-libreclaw-save-conversations-dir))

(defun cmacs-libreclaw--conversation-name-format (channel)
  "Return the archive file-name format string for CHANNEL."
  (if (equal channel "bridge")
      (or (bound-and-true-p
           cmacs-libreclaw-remote-save-conversations-name-format)
          "%y%m%d-%H%M%S-<agent-name>.org")
    cmacs-libreclaw-save-conversations-name-format))

(defun cmacs-libreclaw--conversation-save-file ()
  "Return (resolving and caching) the archive path for the current buffer.
Returns nil when archiving is not configured for this buffer's
channel.  The resolved path is cached in
`cmacs-libreclaw-room--save-file' so later saves rewrite it."
  (or cmacs-libreclaw-room--save-file
      (let ((dir (cmacs-libreclaw--conversation-archive-dir
                  cmacs-libreclaw-room-channel)))
        (when dir
          (let* ((fmt (cmacs-libreclaw--conversation-name-format
                       cmacs-libreclaw-room-channel))
                 (agent (cmacs-libreclaw--sanitize-file-component
                         (cmacs-libreclaw--conversation-agent-name
                          cmacs-libreclaw-room-channel)))
                 (stamped (format-time-string
                           fmt (or cmacs-libreclaw-room--created-at
                                   (current-time))))
                 ;; LITERAL replacement (the t t args) so agent
                 ;; names containing %, \\, etc. are safe.
                 (name (replace-regexp-in-string
                        "<agent-name>" agent stamped t t)))
            (setq-local cmacs-libreclaw-room--save-file
                        (expand-file-name name dir)))))))

(defun cmacs-libreclaw--save-conversation (&optional buf)
  "Write BUF's conversation history to its archive file.
BUF defaults to the current buffer.  A no-op unless BUF is a
libreclaw room buffer whose channel has an archive directory
configured.  The editable `* Compose' region is excluded, so the
result is a self-contained, readable org file."
  (with-current-buffer (or buf (current-buffer))
    (when (and cmacs-libreclaw-room-channel
               (markerp cmacs-libreclaw-room--compose-marker))
      (let ((file (cmacs-libreclaw--conversation-save-file)))
        (when file
          (let ((end (save-excursion
                       (goto-char cmacs-libreclaw-room--compose-marker)
                       (forward-line -1)
                       (point))))
            (condition-case err
                (progn
                  (make-directory (file-name-directory file) t)
                  (write-region (point-min) end file nil 'nomessage))
              (error
               (message "cmacs-libreclaw: archive write failed: %s"
                        (error-message-string err))))))))))

(defun cmacs-libreclaw--save-conversation-on-message (channel room-id &rest _)
  "Archive the CHANNEL/ROOM-ID room buffer after a message.
Wired into `cmacs-libreclaw-message-hook' so the archive file
tracks the live conversation."
  (let ((buf (cdr (assoc (cons channel room-id)
                         cmacs-libreclaw-rooms-alist))))
    (when (buffer-live-p buf)
      (cmacs-libreclaw--save-conversation buf))))

(add-hook 'cmacs-libreclaw-message-hook
          #'cmacs-libreclaw--save-conversation-on-message)

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
  "Archive this buffer, then remove it from `cmacs-libreclaw-rooms-alist'."
  (ignore-errors (cmacs-libreclaw--save-conversation))
  (when (and cmacs-libreclaw-room-channel cmacs-libreclaw-room-id)
    (setq cmacs-libreclaw-rooms-alist
          (cl-remove-if
           (lambda (entry)
             (equal (car entry)
                    (cons cmacs-libreclaw-room-channel
                          cmacs-libreclaw-room-id)))
           cmacs-libreclaw-rooms-alist))))

;;;; Compose / send -------------------------------------------------

(defcustom cmacs-libreclaw-view-mode 'tools
  "How a libreclaw agent is expected to read the user\'s buffers.

`tools\' -- the agent can call cmacs\'s MCP tools, so outgoing messages
carry a listing of what is on screen and the agent fetches what it
needs.  Correct for the remote bridge, which tunnels the whole cmacs
MCP surface to the agent (see `build_self_mcp_server\' in
cmacs/libreclaw/cmacs-libreclaw-remote.c), and for any hatched agent
whose MCP config includes the cmacs server.

`inline\' -- the agent has no way to read the editor, so the visible
buffers\' text is sent with the message instead.  Change to this if
the agent keeps saying it cannot see your screen."
  :type '(choice (const :tag "The agent has cmacs\'s MCP tools" tools)
                 (const :tag "Send the text instead" inline))
  :group 'cmacs-libreclaw)

(defun cmacs-libreclaw-default-context ()
  "The default screen-context prelude for an outgoing message, or nil.

Assembled from `cmacs-ai-view\': the standing explanation on the first
message of a room, then a listing of the visible buffers whenever the
screen has changed since the last one."
  (when (fboundp 'cmacs-ai-view-turn-block)
    (let* ((result (cmacs-ai-view-turn-block cmacs-libreclaw-view-mode
                                             cmacs-libreclaw-room--view))
           (block (car result))
           (hint (unless cmacs-libreclaw-room--hinted
                   (cmacs-ai-view-hint cmacs-libreclaw-view-mode))))
      (setq cmacs-libreclaw-room--view (cdr result))
      (when (or block hint)
        (setq cmacs-libreclaw-room--hinted t)
        (string-join (delq nil (list hint block)) "\n\n")))))

(defcustom cmacs-libreclaw-context-function #'cmacs-libreclaw-default-context
  "Function returning the invisible prelude for an outgoing message.

Called with no arguments, in the room buffer, just before a message is
sent; a non-empty string is prepended to what actually goes out while
the room still shows exactly what you typed.  nil disables the whole
mechanism."
  :type '(choice (const :tag "Send nothing extra" nil) function)
  :group 'cmacs-libreclaw)

(defcustom cmacs-libreclaw-command-prefixes '("!")
  "Prefixes that mean a message is a command, not something to talk about.

Messages starting with one of these are sent EXACTLY as typed, with no
screen-context prelude in front of them.

This is not cosmetic.  libreclaw dispatches commands by looking at the
first character of the message body -- `cmd_body[0] == \='!\=''
in `lc-app.c\=' -- so anything prepended to `!help\=' stops it being a
command at all, and it is delivered to the model as prose instead.  The
symptom is a bot command that silently does nothing."
  :type '(repeat string)
  :group 'cmacs-libreclaw)

(defun cmacs-libreclaw--command-p (body)
  "Non-nil when BODY is a bot command rather than a message."
  (let ((text (string-trim-left (or body ""))))
    (seq-some (lambda (prefix)
                (and (not (string-empty-p prefix))
                     (string-prefix-p prefix text)))
              cmacs-libreclaw-command-prefixes)))

(defun cmacs-libreclaw--compose-context ()
  "The invisible prelude for the next outgoing message, or nil."
  (when (functionp cmacs-libreclaw-context-function)
    (condition-case err
        (funcall cmacs-libreclaw-context-function)
      (error
       ;; Context is a convenience; failing to build it must never stop
       ;; a message the user has already pressed C-c C-c on.
       (message "cmacs-libreclaw: context unavailable: %s"
                (error-message-string err))
       nil))))

(defun cmacs-libreclaw--outgoing-body (body)
  "BODY with the screen-context prelude prepended, for sending.

Only what BODY holds is echoed into the room: the prelude is for the
agent, and a transcript full of machine-generated preamble is not a
conversation anyone can read afterwards."
  (if (cmacs-libreclaw--command-p body)
      ;; A command is parsed from the first character of the body, so
      ;; there is nothing that may go in front of it.  Returning early
      ;; also leaves the room's hint and screen signature untouched, so
      ;; the next real message still carries them.
      body
    (let ((context (cmacs-libreclaw--compose-context)))
      (if (and context (not (string-empty-p context)))
          (concat context "\n\n---\n\n" body)
        body))))

(defun cmacs-libreclaw-send-compose ()
  "Send the compose region as a message and clear it.
Routes through the remote bridge when the room channel is
\"bridge\" (so chat buffers created by `cmacs-libreclaw-remote-chat'
and friends just work), otherwise through the embedded LcApp's
`cmacs-libreclaw-send-message' DEFUN."
  (interactive)
  (unless (and cmacs-libreclaw-room-channel cmacs-libreclaw-room-id)
    (user-error "Not in a cmacs-libreclaw room buffer"))
  (unless cmacs-libreclaw-room--compose-marker
    (user-error "No compose marker in this buffer"))
  (let* ((start (marker-position cmacs-libreclaw-room--compose-marker))
         (end   (point-max))
         (body  (string-trim (buffer-substring-no-properties start end))))
    (when (> (length body) 0)
      (cond
       ((string= cmacs-libreclaw-room-channel "bridge")
        (unless (and (fboundp 'cmacs-libreclaw-remote-connected-p)
                     (cmacs-libreclaw-remote-connected-p))
          (user-error
           "Bridge not connected — M-x cmacs-libreclaw-remote-connect"))
        (cmacs-libreclaw-remote-send-message
         cmacs-libreclaw-room-id (cmacs-libreclaw--outgoing-body body)))
       (t
        ;; Only cmacs\'s own agent rooms get the screen context: a
        ;; matrix room or a mailing list is other people, and what is
        ;; on your screen is none of their business.
        (cmacs-libreclaw-send-message
         cmacs-libreclaw-room-channel
         cmacs-libreclaw-room-id
         body)))
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

;;;; Voice messages -------------------------------------------------
;;
;; When `cmacs-audio' is built, M-x cmacs-libreclaw-send-voice-message
;; records a short utterance, transcribes it via cmacs-whisper (when
;; built), and sends the transcript as the message body.  Future
;; iterations will attach the WAV itself to the bridge frame; for now
;; the transcript-only path makes the cross-subsystem composition
;; usable end-to-end without altering the libreclaw wire protocol.

(defvar cmacs-libreclaw--pending-voice nil)

(declare-function cmacs-audio--capture-open-1 "cmacs-audio" (&rest plist))
(declare-function cmacs-audio-start "cmacs-audio" (handle))
(declare-function cmacs-audio-close "cmacs-audio" (handle))
(declare-function cmacs-audio-write-file "cmacs-audio" (handle path))
(declare-function cmacs-whisper-transcribe-file "cmacs-whisper" (model path &optional lang))
(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(defvar cmacs-audio-output-dir)
(defvar cmacs-whisper-language)

;;;###autoload
(defun cmacs-libreclaw-send-voice-message (channel room-id)
  "Record a voice message and send it (transcribed) to CHANNEL ROOM-ID."
  (interactive
   (let* ((rooms (cmacs-libreclaw-list-rooms))
          (choices (mapcar (lambda (r)
                             (format "%s / %s" (nth 0 r) (or (nth 2 r) (nth 1 r))))
                           rooms))
          (pick (completing-read "Voice -> Room: " choices nil t))
          (idx (cl-position pick choices :test #'equal))
          (row (nth idx rooms)))
     (list (nth 0 row) (nth 1 row))))
  (unless (and (featurep 'cmacs-audio) (fboundp 'cmacs-audio--capture-open-1))
    (user-error "cmacs-audio not built"))
  (let* ((wav (expand-file-name
               (format-time-string "voice-%Y%m%d-%H%M%S.wav")
               (or (bound-and-true-p cmacs-audio-output-dir) "/tmp/")))
         (h (cmacs-audio--capture-open-1)))
    (cmacs-audio-start h)
    (message "cmacs-libreclaw: recording voice message (M-x cmacs-libreclaw-finish-voice-message to stop)")
    (setq cmacs-libreclaw--pending-voice (list h wav channel room-id))))

;;;###autoload
(defun cmacs-libreclaw-finish-voice-message ()
  "Stop recording started by `cmacs-libreclaw-send-voice-message' and dispatch."
  (interactive)
  (pcase cmacs-libreclaw--pending-voice
    (`(,h ,wav ,channel ,room-id)
     (cmacs-audio-write-file h wav)
     (cmacs-audio-close h)
     (setq cmacs-libreclaw--pending-voice nil)
     (let ((body (cond
                  ((and (featurep 'cmacs-whisper)
                        (fboundp 'cmacs-whisper-transcribe-file))
                   (let* ((res (cmacs-whisper-transcribe-file
                                (cmacs-whisper-model-path) wav
                                (or (bound-and-true-p cmacs-whisper-language) "en")))
                          (text (cdr (assq :text res))))
                     (or text "(voice transcription unavailable)")))
                  (t (format "[voice message: %s]" (file-name-nondirectory wav))))))
       (cmacs-libreclaw-send-message channel room-id (string-trim body))
       (message "cmacs-libreclaw: voice message sent")))
    (_ (user-error "cmacs-libreclaw: no voice recording in progress"))))

(provide 'cmacs-libreclaw)

;;; cmacs-libreclaw.el ends here
