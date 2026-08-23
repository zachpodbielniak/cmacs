;;; cmacs-libreclaw-cmacs-channel.el --- Native cmacs channel UI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Emacs-native frontend for libreclaw's LcCmacsChannel.  Provides:
;;
;; - `cmacs-libreclaw-open' — the primary entry point.  Creates or
;;   switches to a libreclaw room buffer for the *current project*
;;   (detected via `project-current', `vc-root-dir', or the current
;;   `default-directory' as a fallback).  The room is keyed on the
;;   absolute path of the project root, so two different projects
;;   get two different buffers with two different AI session
;;   contexts automatically.
;;
;; - `cmacs-libreclaw--on-cmacs-response' — signal dispatch target
;;   that C calls when an outbound message arrives from libreclaw.
;;   Routes the response into the matching buffer's history.
;;
;; - `cmacs-libreclaw-cmacs-channel-room-mode' — major mode
;;   derived from `cmacs-libreclaw-room-mode' but with a send path
;;   that goes through `cmacs-libreclaw-cmacs-channel-inject'
;;   (pushing into libreclaw's inbound pipeline) instead of
;;   `lc_channel_send_message_async' (which would round-trip
;;   externally).
;;
;; - Per-project persistence: when a room buffer is saved or
;;   killed, its org history is written to a stable file under
;;   `cmacs-libreclaw-cmacs-channel-history-dir' (by default
;;   ~/.libreclaw/cmacs-sessions/<sha>.org where <sha> is a
;;   deterministic hash of the absolute project root).  When the
;;   same project is re-opened, the history is restored.  Libreclaw's
;;   own session manager persists the AI *context* under the key
;;   "cmacs:<project-root>:<user>" independently, so AI memory and
;;   buffer history stay aligned.

;;; Code:

(require 'org)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-libreclaw)

;;;; Customisation ---------------------------------------------------

(defgroup cmacs-libreclaw-cmacs-channel nil
  "Native cmacs channel integration for libreclaw."
  :group 'cmacs-libreclaw
  :prefix "cmacs-libreclaw-cmacs-channel-")

(defcustom cmacs-libreclaw-cmacs-channel-history-dir
  (expand-file-name "~/.libreclaw/cmacs-sessions")
  "Directory where per-project libreclaw buffer history is persisted.
Each project gets a file named <sha>.org inside this directory, where
<sha> is a deterministic hash of the project's absolute root path.
The file stores the buffer's conversation history so that re-opening
the same project's libreclaw buffer restores prior messages."
  :type 'directory
  :group 'cmacs-libreclaw-cmacs-channel)

(defcustom cmacs-libreclaw-cmacs-channel-buffer-name-format
  "*libreclaw: %s*"
  "Format string for native cmacs channel buffer names.
%s is replaced with a short label derived from the project root
(typically its basename).  Conflicts between two projects that
share a basename are disambiguated by the full project path in
the buffer's `default-directory' and persistence file hash, not
the name itself — so collisions are harmless."
  :type 'string
  :group 'cmacs-libreclaw-cmacs-channel)

(defcustom cmacs-libreclaw-cmacs-channel-sender
  (or (getenv "USER") (user-login-name) "user")
  "Sender identifier used when injecting messages on the cmacs channel.
This flows into libreclaw's session key as the sender component —
sessions are keyed on \"cmacs:<project-root>:<sender>\", so changing
this value in an existing project starts a fresh AI session
context for that project."
  :type 'string
  :group 'cmacs-libreclaw-cmacs-channel)

(defcustom cmacs-libreclaw-cmacs-channel-autosave-history t
  "When non-nil, persist room buffer history on save and on kill.
Disabling this is useful for ephemeral sessions or when you don't
want cross-Emacs-session memory — libreclaw's AI session manager
still persists independently unless you also clear
~/.libreclaw/sessions/."
  :type 'boolean
  :group 'cmacs-libreclaw-cmacs-channel)

;;;; Project detection ---------------------------------------------

(defun cmacs-libreclaw-cmacs-channel--project-root (&optional directory)
  "Return the absolute root directory of the project containing DIRECTORY.
Falls back to the current `default-directory' when DIRECTORY is nil,
and to the user's home when no project marker is found — so every
buffer always resolves to *some* room, even in scratch buffers."
  (let* ((start (expand-file-name (or directory default-directory)))
         (root
          (or
           ;; Modern project.el
           (when-let* ((proj (with-temp-buffer
                               (setq default-directory start)
                               (ignore-errors (project-current nil)))))
             (when (fboundp 'project-root)
               (ignore-errors (project-root proj))))
           ;; Older vc-root-dir path
           (when (fboundp 'vc-root-dir)
             (let ((default-directory start))
               (ignore-errors (vc-root-dir))))
           ;; Common manual markers
           (locate-dominating-file start ".git")
           (locate-dominating-file start ".hg")
           (locate-dominating-file start ".svn")
           (locate-dominating-file start "Makefile")
           (locate-dominating-file start "Cargo.toml")
           (locate-dominating-file start "pyproject.toml")
           ;; Last resort — the starting directory itself
           start)))
    (file-name-as-directory (expand-file-name root))))

(defun cmacs-libreclaw-cmacs-channel--room-id (&optional directory)
  "Return the libreclaw room-id for DIRECTORY's project.
Room-id is the absolute project root, which libreclaw uses
directly in its session key."
  (directory-file-name
   (cmacs-libreclaw-cmacs-channel--project-root directory)))

(defun cmacs-libreclaw-cmacs-channel--project-label (room-id)
  "Return a short, readable label for ROOM-ID (the project basename)."
  (let ((base (file-name-nondirectory (directory-file-name room-id))))
    (if (string-empty-p base) "home" base)))

(defun cmacs-libreclaw-cmacs-channel--history-file (room-id)
  "Return the persistence file path for ROOM-ID."
  (let* ((hash (secure-hash 'sha1 room-id))
         (dir  (expand-file-name cmacs-libreclaw-cmacs-channel-history-dir)))
    (make-directory dir t)
    (expand-file-name (format "%s.org" hash) dir)))

(defun cmacs-libreclaw-cmacs-channel--buffer-name (room-id)
  "Return the buffer name for ROOM-ID."
  (format cmacs-libreclaw-cmacs-channel-buffer-name-format
          (cmacs-libreclaw-cmacs-channel--project-label room-id)))

;;;; Rooms tracking -------------------------------------------------

(defvar cmacs-libreclaw-cmacs-channel-rooms nil
  "Alist mapping ROOM-ID string to its buffer.
Kept in sync with `cmacs-libreclaw-rooms-alist' — an entry is
added when a new buffer is created and pruned when a buffer is
killed.")

(defvar-local cmacs-libreclaw-cmacs-channel-room-id nil
  "Room-id (absolute project root) for this buffer.")

;;;; Mode -----------------------------------------------------------

(defvar cmacs-libreclaw-cmacs-channel-room-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m cmacs-libreclaw-room-mode-map)
    (define-key m (kbd "C-c C-c") #'cmacs-libreclaw-cmacs-channel-send-compose)
    (define-key m (kbd "C-c C-s") #'cmacs-libreclaw-cmacs-channel-save-history)
    m)
  "Keymap for `cmacs-libreclaw-cmacs-channel-room-mode'.
Overrides `C-c C-c' from the parent room mode so sends go through
the cmacs channel's inject path instead of the generic
`lc_channel_send_message_async' call.")

(define-derived-mode cmacs-libreclaw-cmacs-channel-room-mode
  cmacs-libreclaw-room-mode "LC-Cmacs"
  "Major mode for libreclaw room buffers routed through the cmacs channel.
Derived from `cmacs-libreclaw-room-mode' so history protection,
compose region, and org-mode rendering all inherit.  Only the
send path (`C-c C-c') is different: it injects the compose
contents into libreclaw's inbound pipeline via
`cmacs-libreclaw-cmacs-channel-inject', and the AI response is
delivered back through `cmacs-libreclaw--on-cmacs-response'.

\\{cmacs-libreclaw-cmacs-channel-room-mode-map}"
  (setq-local auto-save-default nil)
  (setq-local make-backup-files nil)
  (when cmacs-libreclaw-cmacs-channel-autosave-history
    (add-hook 'kill-buffer-hook
              #'cmacs-libreclaw-cmacs-channel--on-kill nil t)
    (add-hook 'after-save-hook
              #'cmacs-libreclaw-cmacs-channel-save-history nil t)))

;;;; Buffer creation + restore -------------------------------------

(defun cmacs-libreclaw-cmacs-channel--init-buffer (buf room-id)
  "Populate BUF with the standard libreclaw room skeleton for ROOM-ID."
  (with-current-buffer buf
    (let ((inhibit-read-only t)
          (cmacs-libreclaw--allow-history-edit t))
      (erase-buffer)
      (insert (format "#+TITLE: LibreClaw — %s\n"
                      (cmacs-libreclaw-cmacs-channel--project-label room-id)))
      (insert "#+STARTUP: showall indent\n")
      (insert "#+OPTIONS: toc:nil num:nil\n")
      (insert (format "#+PROPERTY: channel cmacs\n"))
      (insert (format "#+PROPERTY: room-id %s\n" room-id))
      (insert (format "#+PROPERTY: project-root %s\n" room-id))
      (insert "\n")
      (insert "* Messages\n\n")
      (insert "* Compose                                              :compose:\n"))
    (cmacs-libreclaw-cmacs-channel-room-mode)
    (setq-local cmacs-libreclaw-cmacs-channel-room-id room-id)
    (setq-local cmacs-libreclaw-room-channel "cmacs")
    (setq-local cmacs-libreclaw-room-id      room-id)
    (setq-local cmacs-libreclaw-room-name
                (cmacs-libreclaw-cmacs-channel--project-label room-id))
    (setq-local cmacs-libreclaw-room--compose-marker
                (save-excursion
                  (goto-char (point-max))
                  (point-marker)))
    (set-marker-insertion-type cmacs-libreclaw-room--compose-marker nil)
    (cmacs-libreclaw--seal-history)
    (goto-char (point-max))))

(defun cmacs-libreclaw-cmacs-channel--restore-history (buf room-id)
  "Insert persisted history for ROOM-ID into BUF, above the compose sentinel."
  (let ((file (cmacs-libreclaw-cmacs-channel--history-file room-id)))
    (when (file-readable-p file)
      (with-current-buffer buf
        (save-excursion
          (let ((inhibit-read-only t)
                (cmacs-libreclaw--allow-history-edit t))
            (goto-char cmacs-libreclaw-room--compose-marker)
            ;; Step above the * Compose sentinel.
            (forward-line -1)
            (end-of-line)
            (insert "\n")
            (insert-file-contents file))
          ;; Restored history is finished text like any other.
          (cmacs-libreclaw--seal-history))))))

(defun cmacs-libreclaw-cmacs-channel--ensure-buffer (room-id)
  "Return (creating if necessary) the libreclaw buffer for ROOM-ID.
Restores persisted history on first creation.  Also registers the
room with the C-side cmacs channel."
  (let* ((key room-id)
         (existing (cdr (assoc key cmacs-libreclaw-cmacs-channel-rooms))))
    (cond
     ((and existing (buffer-live-p existing))
      existing)
     (t
      (let ((buf (get-buffer-create
                  (cmacs-libreclaw-cmacs-channel--buffer-name room-id))))
        (cmacs-libreclaw-cmacs-channel--init-buffer buf room-id)
        (cmacs-libreclaw-cmacs-channel--restore-history buf room-id)
        ;; Tell the C side this room exists so injects route correctly.
        (when (cmacs-libreclaw-cmacs-channel-available-p)
          (cmacs-libreclaw-cmacs-channel-register-room room-id))
        ;; Track both locally and in the parent alist so
        ;; cmacs-libreclaw-list-rooms / show-room still work.
        (setf (alist-get key cmacs-libreclaw-cmacs-channel-rooms
                          nil nil #'equal) buf)
        (setf (alist-get (cons "cmacs" room-id)
                          cmacs-libreclaw-rooms-alist
                          nil nil #'equal) buf)
        buf)))))

(defun cmacs-libreclaw-cmacs-channel--on-kill ()
  "Persist buffer history, if enabled, and prune the rooms alist."
  (when (and cmacs-libreclaw-cmacs-channel-room-id
             cmacs-libreclaw-cmacs-channel-autosave-history)
    (ignore-errors
      (cmacs-libreclaw-cmacs-channel-save-history)))
  (when cmacs-libreclaw-cmacs-channel-room-id
    (let ((room-id cmacs-libreclaw-cmacs-channel-room-id))
      (setq cmacs-libreclaw-cmacs-channel-rooms
            (cl-remove-if (lambda (cell) (equal (car cell) room-id))
                          cmacs-libreclaw-cmacs-channel-rooms))
      (setq cmacs-libreclaw-rooms-alist
            (cl-remove-if (lambda (cell)
                            (equal (car cell) (cons "cmacs" room-id)))
                          cmacs-libreclaw-rooms-alist)))))

;;;; Persistence ---------------------------------------------------

(defun cmacs-libreclaw-cmacs-channel--extract-history (buffer)
  "Return the history region (above * Compose) of BUFFER as a string."
  (with-current-buffer buffer
    (when cmacs-libreclaw-room--compose-marker
      (let ((beg (save-excursion
                   (goto-char (point-min))
                   (if (re-search-forward "^\\* Messages[ \t]*$" nil t)
                       (line-beginning-position 2)
                     (point-min))))
            (end (save-excursion
                   (goto-char cmacs-libreclaw-room--compose-marker)
                   (forward-line -1)
                   (line-beginning-position))))
        (when (and (numberp beg) (numberp end) (< beg end))
          (buffer-substring-no-properties beg end))))))

(defun cmacs-libreclaw-cmacs-channel-save-history ()
  "Persist the current buffer's history region to disk.
No-op when called outside a cmacs channel room buffer, or when
`cmacs-libreclaw-cmacs-channel-autosave-history' is nil."
  (interactive)
  (when (and cmacs-libreclaw-cmacs-channel-room-id
             cmacs-libreclaw-cmacs-channel-autosave-history)
    (let* ((file (cmacs-libreclaw-cmacs-channel--history-file
                  cmacs-libreclaw-cmacs-channel-room-id))
           (body (cmacs-libreclaw-cmacs-channel--extract-history
                  (current-buffer))))
      (when body
        (make-directory (file-name-directory file) t)
        (with-temp-file file
          (insert body))
        (when (called-interactively-p 'interactive)
          (message "libreclaw: persisted history to %s" file))))))

;;;; Send path (overrides the parent mode's send-compose) ----------

(defun cmacs-libreclaw-cmacs-channel-send-compose ()
  "Send the current compose region as an inbound cmacs-channel message.

Flow:

1. Grab the compose region contents (via the live marker, not a
   cached integer — the marker shifts forward as headings are
   inserted above it).
2. Insert a local echo `** TIMESTAMP SENDER' heading for the
   user's message.  This guarantees the user's message appears
   BEFORE any AI response that libreclaw produces synchronously
   during the inject call below — libreclaw's command handler
   runs inside the signal emission and, for commands like
   `!help', calls `lc_channel_send_message_async' immediately,
   which dispatches back to
   `cmacs-libreclaw--on-cmacs-response' and inserts a second
   heading.  Without the local echo first the buffer ordering
   would come out reversed.
3. Inject the message into libreclaw's inbound pipeline.
4. Clear the compose region on success.

The duplication we used to hit when *both* this local echo AND
the generic `cmacs-libreclaw--on-message' dispatch fired is now
avoided: `cmacs-libreclaw--on-message' explicitly short-circuits
for the cmacs channel, leaving this function as the only source
of user-message headings."
  (interactive)
  (unless cmacs-libreclaw-cmacs-channel-room-id
    (user-error "Not in a cmacs channel room buffer"))
  (unless (cmacs-libreclaw-running-p)
    (user-error "libreclaw is not running — call `cmacs-libreclaw-start' first"))
  (unless (cmacs-libreclaw-cmacs-channel-available-p)
    (user-error "cmacs channel not bound — is `channels.cmacs.enabled: true' in config.yaml?"))
  (unless cmacs-libreclaw-room--compose-marker
    (user-error "No compose marker in this buffer"))
  (let ((body (string-trim
               (buffer-substring-no-properties
                cmacs-libreclaw-room--compose-marker
                (point-max)))))
    (when (> (length body) 0)
      ;; Clear the compose region first so the local echo
      ;; inserts at the right spot and the user's draft doesn't
      ;; get doubled when the bot echoes it back.
      (let ((inhibit-read-only t))
        (delete-region cmacs-libreclaw-room--compose-marker
                       (point-max)))
      ;; Local echo — user message heading shows up FIRST.
      (cmacs-libreclaw--insert-heading
       (current-buffer)
       cmacs-libreclaw-cmacs-channel-sender
       body
       (format-time-string cmacs-libreclaw-timestamp-format))
      ;; Push into libreclaw's inbound pipeline.  libreclaw's
      ;; command handlers (built-in !help, !version, plugin
      ;; commands, etc.) fire synchronously during this call; any
      ;; response flows back through the cmacs channel's
      ;; send_message_async vfunc and lands in this buffer via
      ;; `cmacs-libreclaw--on-cmacs-response', inserted AFTER the
      ;; local echo we just wrote.
      ;;
      ;; The screen context rides the injected body and NOT the local
      ;; echo above: the agent needs to know what you were looking at,
      ;; and the room needs to read as the conversation you had.
      (cmacs-libreclaw-cmacs-channel-inject
       cmacs-libreclaw-cmacs-channel-room-id
       cmacs-libreclaw-cmacs-channel-sender
       (cmacs-libreclaw--outgoing-body body)
       cmacs-libreclaw-cmacs-channel-sender))))

;;;; Response dispatch target (called from C) ----------------------

(defcustom cmacs-libreclaw-cmacs-channel-bot-name-fallback "libreclaw"
  "Sender label used for AI responses when `agent.name' is unavailable.
The handler asks libreclaw for the currently-loaded
`agent.name' from the YAML config and uses that as the heading
sender.  If libreclaw is not running, has no agent.name set, or
`cmacs-libreclaw-agent-name' isn't bound (older cmacs without
the DEFUN), this fallback is used instead."
  :type 'string
  :group 'cmacs-libreclaw-cmacs-channel)

(defun cmacs-libreclaw-cmacs-channel--bot-sender ()
  "Return the sender label to use for AI responses.
Prefers the running LcApp's `agent.name', falls back to
`cmacs-libreclaw-cmacs-channel-bot-name-fallback'."
  (or (and (fboundp 'cmacs-libreclaw-agent-name)
           (cmacs-libreclaw-agent-name))
      cmacs-libreclaw-cmacs-channel-bot-name-fallback))

(defun cmacs-libreclaw--on-cmacs-response (channel room-id body
                                                    &optional _html _thread)
  "C-dispatched handler for an outbound cmacs channel message.
CHANNEL is always \"cmacs\", ROOM-ID is the absolute project root,
BODY is the AI response text.  Finds the matching buffer and
inserts a new `** <agent-name>' heading above the compose
sentinel, where `<agent-name>' is read live from the YAML via
`cmacs-libreclaw-agent-name' so hot-reloads take effect without
a restart."
  (ignore channel)
  (let ((buf (cdr (assoc room-id cmacs-libreclaw-cmacs-channel-rooms)))
        (sender (cmacs-libreclaw-cmacs-channel--bot-sender)))
    (when (buffer-live-p buf)
      (cmacs-libreclaw--insert-heading
       buf
       sender
       (or body "")
       (format-time-string cmacs-libreclaw-timestamp-format)))
    (run-hook-with-args 'cmacs-libreclaw-message-hook
                        channel room-id
                        (list :sender-name sender :body body))))

;;;; Entry point ---------------------------------------------------

;;;###autoload
(defun cmacs-libreclaw-open (&optional directory)
  "Open the libreclaw chat buffer for the project containing DIRECTORY.
Interactively, DIRECTORY defaults to the current buffer's
`default-directory', so calling this from anywhere inside a
project opens that project's libreclaw buffer.

Each project root gets its own buffer.  Different project roots
get independent buffers with independent AI session contexts,
persisted across Emacs restarts via
`cmacs-libreclaw-cmacs-channel-history-dir' and libreclaw's own
session-key persistence.

If libreclaw isn't running, starts it first (auto-generating a
default config if necessary, per `cmacs-libreclaw-start')."
  (interactive)
  (unless (cmacs-libreclaw-running-p)
    (cmacs-libreclaw-start))
  (unless (cmacs-libreclaw-cmacs-channel-available-p)
    (user-error
     "cmacs channel not bound. Ensure your libreclaw config has:

  channels:
    cmacs:
      enabled: true

Re-run M-x cmacs-libreclaw-generate-default-config to regenerate."))
  (let* ((room-id (cmacs-libreclaw-cmacs-channel--room-id directory))
         (buf     (cmacs-libreclaw-cmacs-channel--ensure-buffer room-id)))
    (pop-to-buffer buf)
    (goto-char (point-max))
    buf))

;;;###autoload
(defun cmacs-libreclaw-list-cmacs-rooms ()
  "Return the list of open cmacs channel room buffers as an alist.
Each entry is (ROOM-ID . BUFFER).  Useful for scripts and tests."
  cmacs-libreclaw-cmacs-channel-rooms)

(provide 'cmacs-libreclaw-cmacs-channel)

;;; cmacs-libreclaw-cmacs-channel.el ends here
