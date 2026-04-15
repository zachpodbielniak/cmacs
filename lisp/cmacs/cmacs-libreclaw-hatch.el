;;; cmacs-libreclaw-hatch.el --- REPL-style workspace hatching  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An interactive, REPL-style org buffer that drives libreclaw's
;; `lc_hatch_*' library API through the `cmacs-libreclaw-hatch-*' C
;; DEFUNs.  The buffer reads like a conversation with the wizard:
;;
;;   * Welcome
;;   Hi, I'm the libreclaw hatch wizard.  I'll help you scaffold a
;;   new workspace at /home/me/.libreclaw.  Answer each question and
;;   press `C-c C-c' to submit.  `C-c C-k' aborts.
;;
;;   ** wizard: What should this workspace be called?
;;   Short identifier matching ^[a-zA-Z][a-zA-Z0-9_-]*$.
;;
;;   ** you
;;   my-bot                 <- typed by user, C-c C-c to submit
;;
;;   ** wizard: Which AI provider? claude, openai, or both.
;;
;;   ** you
;;   claude                 <- user's second answer
;;
;;   ...
;;
;; Everything above the current `** you' heading is the conversation
;; history and is read-only.  The region below `** you' is editable
;; — you can write multi-line answers (paths, source blocks, etc.).
;; `RET' stays native org-mode, so all the usual multi-line editing
;; works.  Only `C-c C-c' ends a turn.
;;
;; Secrets (Matrix access tokens, email passwords) are *never*
;; typed into the org buffer — those steps jump out to the
;; minibuffer `read-passwd' prompt and flow through `auth-source' so
;; the raw value never touches the file.
;;
;; Under the hood: each submitted answer is dispatched to a handler
;; keyed on `cmacs-libreclaw-hatch--step' (a symbol).  The handler
;; validates, calls the relevant C DEFUN, advances the step, and
;; calls `cmacs-libreclaw-hatch--ask' to insert the next wizard
;; prompt + a fresh `** you' compose region.  Rinse, repeat.

;;; Code:

(require 'org)
(require 'subr-x)
(require 'cl-lib)
(require 'auth-source)
(require 'cmacs-libreclaw)

;;;; Buffer-local state --------------------------------------------

(defvar-local cmacs-libreclaw-hatch--handle nil
  "Integer handle for the underlying `LcHatchContext'.")

(defvar-local cmacs-libreclaw-hatch--workspace nil
  "Target workspace directory for this wizard session.")

(defvar-local cmacs-libreclaw-hatch--step nil
  "Symbol identifying the current wizard step.
See `cmacs-libreclaw-hatch--handle-answer' for the state machine.")

(defvar-local cmacs-libreclaw-hatch--compose-marker nil
  "Marker at the start of the current `** you' compose region.
Everything from here to `point-max' is the user's pending answer;
everything before is locked-in conversation history.")

(defvar-local cmacs-libreclaw-hatch--channel-ctx nil
  "Plist of partial state for a multi-step channel flow.
For matrix: (:homeserver \"...\" :user-id \"...\").
For email:  (:imap \"...\" :smtp \"...\" :username \"...\").
For webhook:(:port N).  Cleared when the channel finishes.")

(defvar-local cmacs-libreclaw-hatch--channels-added 0
  "How many channels have been added so far.  Used to enforce the
minimum of one channel before the podomation step.")

(defvar cmacs-libreclaw-hatch--allow-history-edit nil
  "Dynamic override that lets the wizard write to history.
Same pattern as `cmacs-libreclaw--allow-history-edit' in
cmacs-libreclaw.el.  User edits never set this flag.")

;;;; Mode and keymap -----------------------------------------------

(defvar cmacs-libreclaw-hatch-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cmacs-libreclaw-hatch-submit)
    (define-key m (kbd "C-c C-k") #'cmacs-libreclaw-hatch-cancel)
    m)
  "Keymap for `cmacs-libreclaw-hatch-mode'.
`C-c C-c' submits the current answer, `C-c C-k' aborts.  `RET' is
the ordinary org-mode RET so multi-line answers work as expected.")

(defun cmacs-libreclaw-hatch--protect-history (beg _end)
  "Reject edits BEG.._END that fall above the compose marker."
  (when (and (not cmacs-libreclaw-hatch--allow-history-edit)
             cmacs-libreclaw-hatch--compose-marker
             (< beg cmacs-libreclaw-hatch--compose-marker))
    (signal 'text-read-only
            (list "Hatch wizard history is read-only; answer below the '** you' heading"))))

(define-derived-mode cmacs-libreclaw-hatch-mode org-mode "LC-Hatch"
  "Major mode for the REPL-style libreclaw hatch wizard.

\\{cmacs-libreclaw-hatch-mode-map}"
  (setq-local org-startup-folded 'showall)
  (setq-local org-adapt-indentation nil)
  (setq-local truncate-lines nil)
  ;; Never autosave a hatch buffer — secrets may transit through it
  ;; during a sub-step (even if we try to route them through
  ;; read-passwd) and we don't want them leaking to the filesystem.
  (setq-local auto-save-default nil)
  (setq-local make-backup-files nil)
  (add-hook 'before-change-functions
            #'cmacs-libreclaw-hatch--protect-history nil t)
  (add-hook 'kill-buffer-hook
            #'cmacs-libreclaw-hatch--on-kill nil t))

(defun cmacs-libreclaw-hatch--on-kill ()
  "Release the hatch context when the wizard buffer is killed."
  (when (and cmacs-libreclaw-hatch--handle
             (fboundp 'cmacs-libreclaw-hatch-free))
    (ignore-errors
      (cmacs-libreclaw-hatch-free cmacs-libreclaw-hatch--handle)
      (setq cmacs-libreclaw-hatch--handle nil))))

;;;; Entry point ---------------------------------------------------

;;;###autoload
(defun cmacs-libreclaw-hatch (workspace-dir)
  "Start the libreclaw workspace hatching wizard in WORKSPACE-DIR.
Opens a REPL-style org buffer where the wizard asks questions and
you type answers inline.  Press `C-c C-c' to submit an answer,
`C-c C-k' to abort the session."
  (interactive
   (list (read-directory-name "Workspace directory: "
                              cmacs-libreclaw-default-workspace)))
  (let* ((workspace-dir (expand-file-name workspace-dir))
         (buf (get-buffer-create
               (format "*libreclaw-hatch: %s*" workspace-dir))))
    (with-current-buffer buf
      (cmacs-libreclaw-hatch-mode)
      (setq-local cmacs-libreclaw-hatch--workspace workspace-dir)
      (setq-local cmacs-libreclaw-hatch--handle
                  (cmacs-libreclaw-hatch-new workspace-dir))
      (setq-local cmacs-libreclaw-hatch--channels-added 0)
      (setq-local cmacs-libreclaw-hatch--channel-ctx nil)
      (cmacs-libreclaw-hatch--render-welcome)
      (setq-local cmacs-libreclaw-hatch--step 'name)
      (cmacs-libreclaw-hatch--ask
       "What should this workspace be called?
Short identifier matching \"^[a-zA-Z][a-zA-Z0-9_-]*$\".
Example: my-bot"))
    (pop-to-buffer buf)))

(defun cmacs-libreclaw-hatch--render-welcome ()
  "Erase the buffer and write the welcome header."
  (let ((inhibit-read-only t)
        (cmacs-libreclaw-hatch--allow-history-edit t))
    (erase-buffer)
    (insert "#+TITLE: LibreClaw Workspace Hatching\n")
    (insert "#+STARTUP: showall indent\n")
    (insert "#+OPTIONS: toc:nil num:nil\n\n")
    (insert "* Welcome\n")
    (insert (format "I'll help you scaffold a new libreclaw workspace at\n=%s=.\n\n"
                    cmacs-libreclaw-hatch--workspace))
    (insert
     "Answer each question below the =** you= heading and press\n"
     "=C-c C-c= to submit.  =RET= is ordinary org-mode — feel free\n"
     "to write multi-line answers, paste paths, etc.  =C-c C-k=\n"
     "aborts the wizard without writing anything.\n\n"
     "Secrets (Matrix tokens, email passwords) are prompted via\n"
     "=read-passwd= in the minibuffer and stored through\n"
     "=auth-source= — they never appear in this buffer or on disk.\n\n")
    (insert "* Wizard                                              :wizard:\n\n")))

;;;; Ask/submit machinery -----------------------------------------

(defun cmacs-libreclaw-hatch--ask (prompt)
  "Insert PROMPT as a new wizard heading and set up a compose region."
  (let ((inhibit-read-only t)
        (cmacs-libreclaw-hatch--allow-history-edit t))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "** wizard: %s\n\n"
                    (replace-regexp-in-string "\n+\\'" "" prompt)))
    (insert "** you\n")
    (setq-local cmacs-libreclaw-hatch--compose-marker
                (point-marker))
    (set-marker-insertion-type
     cmacs-libreclaw-hatch--compose-marker nil)
    (goto-char (point-max))))

(defun cmacs-libreclaw-hatch--say (text)
  "Insert wizard-side narration TEXT into history without a prompt.
Used for status messages, errors, and final confirmations that
don't expect an answer."
  (let ((inhibit-read-only t)
        (cmacs-libreclaw-hatch--allow-history-edit t))
    (save-excursion
      (goto-char (or cmacs-libreclaw-hatch--compose-marker
                     (point-max)))
      (when cmacs-libreclaw-hatch--compose-marker
        ;; Step up above the "** you\n" headline we're parked inside.
        (forward-line -1))
      (unless (bolp) (insert "\n"))
      (insert (format "%s\n\n" text)))))

(defun cmacs-libreclaw-hatch--read-compose ()
  "Return the current compose region's trimmed contents."
  (if (not cmacs-libreclaw-hatch--compose-marker)
      ""
    (string-trim
     (buffer-substring-no-properties
      cmacs-libreclaw-hatch--compose-marker
      (point-max)))))

(defun cmacs-libreclaw-hatch--lock-compose ()
  "Freeze the current compose region.
The already-typed text stays in place as part of the locked-in
history; subsequent calls to `--ask' append below it.  Clears the
compose marker so `--protect-history' stops allowing edits to
this region."
  ;; Ensure a trailing newline so the next heading starts cleanly.
  (let ((inhibit-read-only t)
        (cmacs-libreclaw-hatch--allow-history-edit t))
    (goto-char (point-max))
    (unless (bolp) (insert "\n")))
  (when cmacs-libreclaw-hatch--compose-marker
    (set-marker cmacs-libreclaw-hatch--compose-marker nil))
  (setq-local cmacs-libreclaw-hatch--compose-marker nil))

(defun cmacs-libreclaw-hatch-submit ()
  "Submit the current compose region to the wizard.
Dispatches on `cmacs-libreclaw-hatch--step' and advances the
state machine."
  (interactive)
  (unless cmacs-libreclaw-hatch--step
    (user-error "No active wizard step — the session has finished"))
  (unless cmacs-libreclaw-hatch--compose-marker
    (user-error "No compose region — nothing to submit"))
  (let ((answer (cmacs-libreclaw-hatch--read-compose)))
    (cmacs-libreclaw-hatch--lock-compose)
    (condition-case err
        (cmacs-libreclaw-hatch--handle-answer
         cmacs-libreclaw-hatch--step answer)
      (cmacs-libreclaw-error
       ;; Re-ask the same step with the error inlined.
       (cmacs-libreclaw-hatch--ask
        (format "%s\n\n(Try again — previous answer rejected.)"
                (error-message-string err)))))))

(defun cmacs-libreclaw-hatch-cancel ()
  "Abort the wizard without writing anything."
  (interactive)
  (when (y-or-n-p "Abort hatch wizard and discard progress? ")
    (kill-buffer (current-buffer))))

;;;; State machine -------------------------------------------------

(defun cmacs-libreclaw-hatch--advance (step)
  "Set the current step to STEP (a symbol or `nil' to halt)."
  (setq-local cmacs-libreclaw-hatch--step step))

(defun cmacs-libreclaw-hatch--handle-answer (step answer)
  "Handle ANSWER submitted at STEP.  Dispatches on STEP."
  (pcase step
    ('name        (cmacs-libreclaw-hatch--step-name answer))
    ('identity    (cmacs-libreclaw-hatch--step-identity answer))
    ('ai          (cmacs-libreclaw-hatch--step-ai answer))
    ('channel     (cmacs-libreclaw-hatch--step-channel answer))
    ('chan-matrix-hs   (cmacs-libreclaw-hatch--step-matrix-hs answer))
    ('chan-matrix-user (cmacs-libreclaw-hatch--step-matrix-user answer))
    ('chan-local-prompt (cmacs-libreclaw-hatch--step-local-prompt answer))
    ('chan-email-imap  (cmacs-libreclaw-hatch--step-email-imap answer))
    ('chan-email-smtp  (cmacs-libreclaw-hatch--step-email-smtp answer))
    ('chan-email-user  (cmacs-libreclaw-hatch--step-email-user answer))
    ('chan-webhook-port  (cmacs-libreclaw-hatch--step-webhook-port answer))
    ('chan-webhook-path  (cmacs-libreclaw-hatch--step-webhook-path answer))
    ('podomation    (cmacs-libreclaw-hatch--step-podomation answer))
    ('podomation-dsl (cmacs-libreclaw-hatch--step-podomation-dsl answer))
    ('audit         (cmacs-libreclaw-hatch--step-audit answer))
    ('audit-path    (cmacs-libreclaw-hatch--step-audit-path answer))
    ('review        (cmacs-libreclaw-hatch--step-review answer))
    (_
     (user-error "Unknown wizard step: %S" step))))

(defun cmacs-libreclaw-hatch--yesno (answer)
  "Normalise yes/no answer to t, nil, or `bad'."
  (pcase (downcase (string-trim answer))
    ((or "y" "yes" "true" "t")  t)
    ((or "n" "no" "false" "nil") nil)
    (_                           'bad)))

;;;;; Step 1 — workspace name

(defun cmacs-libreclaw-hatch--step-name (answer)
  (cmacs-libreclaw-hatch-set-name cmacs-libreclaw-hatch--handle answer)
  (cmacs-libreclaw-hatch--advance 'identity)
  (cmacs-libreclaw-hatch--ask
   "Attach an identity file (SOUL.md)?
Type a path to a SOUL.md file, or \"skip\" to continue without one."))

;;;;; Step 2 — identity

(defun cmacs-libreclaw-hatch--step-identity (answer)
  (unless (string-equal (downcase answer) "skip")
    (cmacs-libreclaw-hatch-set-identity
     cmacs-libreclaw-hatch--handle (expand-file-name answer)))
  (cmacs-libreclaw-hatch--advance 'ai)
  (cmacs-libreclaw-hatch--ask
   "Which AI provider should this workspace use?
Type one of: claude, openai, both"))

;;;;; Step 3 — AI provider

(defun cmacs-libreclaw-hatch--step-ai (answer)
  (let ((sym (intern (downcase (string-trim answer)))))
    (unless (memq sym '(claude openai both))
      (user-error "AI provider must be claude, openai, or both (got %s)"
                  answer))
    (cmacs-libreclaw-hatch-set-ai cmacs-libreclaw-hatch--handle sym))
  (cmacs-libreclaw-hatch--advance 'channel)
  (cmacs-libreclaw-hatch--ask
   "Add a channel.  Type one of:
  cmacs      — in-process Emacs-native channel (RECOMMENDED)
               — one buffer per project, no credentials required
  matrix     — Matrix (homeserver + user + token)
  local      — stdin/stdout local channel (CLI only, not useful
               inside Emacs — use \"cmacs\" instead)
  email      — IMAP/SMTP (asks for host + username + password)
  webhook    — HTTP receiver (asks for port + path)
  done       — finish adding channels and continue

At least one channel is required.  For a typical in-Emacs
workflow, just type \"cmacs\" then \"done\"."))

;;;;; Step 4 — channel loop

(defun cmacs-libreclaw-hatch--step-channel (answer)
  (pcase (downcase (string-trim answer))
    ("cmacs"
     ;; Zero-parameter channel — just add it and loop back.
     (cmacs-libreclaw-hatch-add-cmacs cmacs-libreclaw-hatch--handle)
     (cmacs-libreclaw-hatch--channel-added "cmacs"))
    ("matrix"
     (cmacs-libreclaw-hatch--advance 'chan-matrix-hs)
     (cmacs-libreclaw-hatch--ask
      "Matrix homeserver URL?
Example: https://matrix.example.com"))
    ("local"
     (cmacs-libreclaw-hatch--advance 'chan-local-prompt)
     (cmacs-libreclaw-hatch--ask
      "Local channel prompt?
Type a prompt string or \"default\" for \"libreclaw> \".

NOTE: the local channel uses fd 0/1 (stdin/stdout), so it is
only useful for the standalone libreclaw CLI binary.  For
in-Emacs chat buffers use the cmacs channel instead."))
    ("email"
     (cmacs-libreclaw-hatch--advance 'chan-email-imap)
     (cmacs-libreclaw-hatch--ask "IMAP server hostname?"))
    ("webhook"
     (cmacs-libreclaw-hatch--advance 'chan-webhook-port)
     (cmacs-libreclaw-hatch--ask
      "Webhook port? (1–65535, e.g. 8080)"))
    ("done"
     (if (zerop cmacs-libreclaw-hatch--channels-added)
         (cmacs-libreclaw-hatch--ask
          "At least one channel is required.
Type: cmacs, matrix, local, email, or webhook.")
       (cmacs-libreclaw-hatch--advance 'podomation)
       (cmacs-libreclaw-hatch--ask
        "Enable podomation (event-driven automation)?  yes / no")))
    (_
     (cmacs-libreclaw-hatch--ask
      (format "Unknown channel kind: %s.
Type one of: cmacs, matrix, local, email, webhook, done" answer)))))

(defun cmacs-libreclaw-hatch--channel-added (label)
  "Mark a channel as successfully added and loop back to the channel prompt."
  (cl-incf cmacs-libreclaw-hatch--channels-added)
  (setq-local cmacs-libreclaw-hatch--channel-ctx nil)
  (cmacs-libreclaw-hatch--advance 'channel)
  (cmacs-libreclaw-hatch--ask
   (format "Added %s channel.  Add another channel or type \"done\" to continue."
           label)))

;;;;;; Matrix sub-flow

(defun cmacs-libreclaw-hatch--step-matrix-hs (answer)
  (unless (or (string-prefix-p "http://"  answer)
              (string-prefix-p "https://" answer))
    (user-error "Homeserver must start with http:// or https:// (got %s)"
                answer))
  (setq-local cmacs-libreclaw-hatch--channel-ctx
              (list :homeserver answer))
  (cmacs-libreclaw-hatch--advance 'chan-matrix-user)
  (cmacs-libreclaw-hatch--ask
   "Matrix user ID? (fully qualified, e.g. @bot:example.com)"))

(defun cmacs-libreclaw-hatch--step-matrix-user (answer)
  (unless (string-prefix-p "@" answer)
    (user-error "User ID must start with '@' (got %s)" answer))
  (let ((hs  (plist-get cmacs-libreclaw-hatch--channel-ctx :homeserver))
        (uid answer)
        (tok (read-passwd "Matrix access token (stored via auth-source, not shown): ")))
    (cmacs-libreclaw-hatch--store-secret uid tok)
    (cmacs-libreclaw-hatch-add-matrix
     cmacs-libreclaw-hatch--handle hs uid
     (format "${auth-source:matrix:%s}" uid))
    (cmacs-libreclaw-hatch--say
     (format "[token for %s stored via auth-source; YAML will reference ${auth-source:matrix:%s}]"
             uid uid)))
  (cmacs-libreclaw-hatch--channel-added "matrix"))

;;;;;; Local sub-flow

(defun cmacs-libreclaw-hatch--step-local-prompt (answer)
  (let ((prompt (if (string-equal (downcase answer) "default")
                    nil
                  answer)))
    (cmacs-libreclaw-hatch-add-local
     cmacs-libreclaw-hatch--handle prompt))
  (cmacs-libreclaw-hatch--channel-added "local"))

;;;;;; Email sub-flow

(defun cmacs-libreclaw-hatch--step-email-imap (answer)
  (setq-local cmacs-libreclaw-hatch--channel-ctx
              (list :imap answer))
  (cmacs-libreclaw-hatch--advance 'chan-email-smtp)
  (cmacs-libreclaw-hatch--ask "SMTP server hostname?"))

(defun cmacs-libreclaw-hatch--step-email-smtp (answer)
  (setq-local cmacs-libreclaw-hatch--channel-ctx
              (plist-put cmacs-libreclaw-hatch--channel-ctx
                         :smtp answer))
  (cmacs-libreclaw-hatch--advance 'chan-email-user)
  (cmacs-libreclaw-hatch--ask "Email username?"))

(defun cmacs-libreclaw-hatch--step-email-user (answer)
  (let* ((imap (plist-get cmacs-libreclaw-hatch--channel-ctx :imap))
         (smtp (plist-get cmacs-libreclaw-hatch--channel-ctx :smtp))
         (user answer)
         (pass (read-passwd "Email password (stored via auth-source, not shown): ")))
    (cmacs-libreclaw-hatch--store-secret user pass)
    (cmacs-libreclaw-hatch-add-email
     cmacs-libreclaw-hatch--handle imap smtp user
     (format "${auth-source:email:%s}" user))
    (cmacs-libreclaw-hatch--say
     (format "[password for %s stored via auth-source; YAML references ${auth-source:email:%s}]"
             user user)))
  (cmacs-libreclaw-hatch--channel-added "email"))

;;;;;; Webhook sub-flow

(defun cmacs-libreclaw-hatch--step-webhook-port (answer)
  (let ((port (string-to-number answer)))
    (unless (and (> port 0) (< port 65536))
      (user-error "Port out of range (1–65535): %s" answer))
    (setq-local cmacs-libreclaw-hatch--channel-ctx
                (list :port port)))
  (cmacs-libreclaw-hatch--advance 'chan-webhook-path)
  (cmacs-libreclaw-hatch--ask
   "Webhook path prefix?  (e.g. /libreclaw/webhooks)"))

(defun cmacs-libreclaw-hatch--step-webhook-path (answer)
  (let ((port (plist-get cmacs-libreclaw-hatch--channel-ctx :port)))
    (cmacs-libreclaw-hatch-add-webhook
     cmacs-libreclaw-hatch--handle port answer))
  (cmacs-libreclaw-hatch--channel-added "webhook"))

;;;;; Podomation

(defun cmacs-libreclaw-hatch--step-podomation (answer)
  (pcase (cmacs-libreclaw-hatch--yesno answer)
    ('bad
     (cmacs-libreclaw-hatch--ask
      "Please answer yes or no.  Enable podomation?"))
    ('nil
     (cmacs-libreclaw-hatch--advance 'audit)
     (cmacs-libreclaw-hatch--ask
      "Enable audit log (SQLite)?  yes / no"))
    ('t
     (cmacs-libreclaw-hatch--advance 'podomation-dsl)
     (cmacs-libreclaw-hatch--ask
      "Inline podomation DSL?
Paste a multi-line DSL block or type \"none\" to enable
podomation without any pre-declared pods.  You can write a
block like:

    pod lc = cmacs_libreclaw->new();
    lc->on_cm_lc_message
        => cmacs_libreclaw->send_message(
             channel = event->channel_id,
             room    = event->room_id,
             body    = \"ack\");"))))

(defun cmacs-libreclaw-hatch--step-podomation-dsl (answer)
  (let ((dsl (if (string-equal (downcase answer) "none") nil answer)))
    (cmacs-libreclaw-hatch-enable-podomation
     cmacs-libreclaw-hatch--handle dsl))
  (cmacs-libreclaw-hatch--advance 'audit)
  (cmacs-libreclaw-hatch--ask
   "Enable audit log (SQLite)?  yes / no"))

;;;;; Audit

(defun cmacs-libreclaw-hatch--step-audit (answer)
  (pcase (cmacs-libreclaw-hatch--yesno answer)
    ('bad
     (cmacs-libreclaw-hatch--ask
      "Please answer yes or no.  Enable audit log?"))
    ('nil
     (cmacs-libreclaw-hatch--goto-review))
    ('t
     (cmacs-libreclaw-hatch--advance 'audit-path)
     (cmacs-libreclaw-hatch--ask
      "Audit database path?
Type a path to a SQLite file or \"default\" to use
<workspace>/audit.sqlite."))))

(defun cmacs-libreclaw-hatch--step-audit-path (answer)
  (let ((path (if (string-equal (downcase answer) "default") nil answer)))
    (cmacs-libreclaw-hatch-enable-audit
     cmacs-libreclaw-hatch--handle path))
  (cmacs-libreclaw-hatch--goto-review))

;;;;; Review and finalize

(defun cmacs-libreclaw-hatch--goto-review ()
  "Render the YAML preview and ask for confirmation."
  (let ((yaml (cmacs-libreclaw-hatch-preview
               cmacs-libreclaw-hatch--handle)))
    (cmacs-libreclaw-hatch--say
     (format "Here's the YAML I'll write:\n\n#+begin_src yaml\n%s\n#+end_src"
             yaml)))
  (cmacs-libreclaw-hatch--advance 'review)
  (cmacs-libreclaw-hatch--ask
   "Write this workspace to disk?
Type \"yes\" to finalize, \"no\" to abort without writing."))

(defun cmacs-libreclaw-hatch--step-review (answer)
  (pcase (cmacs-libreclaw-hatch--yesno answer)
    ('bad
     (cmacs-libreclaw-hatch--ask
      "Please answer yes or no.  Write the workspace to disk?"))
    ('nil
     (cmacs-libreclaw-hatch--advance nil)
     (cmacs-libreclaw-hatch--say
      "Okay, not writing anything.  You can C-c C-k to close the buffer
when you're done reviewing.")
     (cmacs-libreclaw-hatch--lock-compose))
    ('t
     (let ((path (cmacs-libreclaw-hatch-finalize
                  cmacs-libreclaw-hatch--handle t)))
       (cmacs-libreclaw-hatch--advance nil)
       (cmacs-libreclaw-hatch--say
        (format "Wrote workspace to =%s=." path))
       (when (y-or-n-p "Start libreclaw with this config now? ")
         (setq cmacs-libreclaw-config-file path)
         (cmacs-libreclaw-start))
       (cmacs-libreclaw-hatch--say
        "All done.  You can kill this buffer with C-c C-k (or
C-x k) when you're finished reviewing."))
     (cmacs-libreclaw-hatch--lock-compose))))

;;;; Secret storage helper -----------------------------------------

(defun cmacs-libreclaw-hatch--store-secret (user token)
  "Best-effort auth-source store for USER => TOKEN.
Silently ignored when no auth-source backend supports creation."
  (ignore-errors
    (let ((auth-source-creation-prompts
           '((secret . "Store in auth-source? "))))
      (auth-source-search :host user :user user :secret token
                          :create t :save-function t))))

(provide 'cmacs-libreclaw-hatch)

;;; cmacs-libreclaw-hatch.el ends here
