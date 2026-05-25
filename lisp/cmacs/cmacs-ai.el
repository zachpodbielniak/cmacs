;;; cmacs-ai.el --- ai-glib AI subsystem for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; User-facing entry point for the cmacs-ai subsystem.  Loads the
;; chat / agent / region / completion / voice submodules on demand
;; and surfaces the shared defcustoms.  The C bridge (cmacs/ai/) is
;; compiled in unconditionally when --with-cmacs-ai is enabled; this
;; file is loaded lazily via autoload entries in cmacs-loaddefs or
;; via `require'.

;;; Code:

(require 'subr-x)
(require 'cl-lib)

(defgroup cmacs-ai nil
  "ai-glib AI subsystem for cmacs."
  :group 'cmacs
  :prefix "cmacs-ai-")

;;;; Defcustoms ------------------------------------------------------

(defcustom cmacs-ai-default-provider 'claude
  "Default provider symbol used by `cmacs-ai-chat'.
One of: claude openai gemini grok ollama claude-code opencode claude-tmux."
  :type '(choice (const claude) (const openai) (const gemini)
                 (const grok) (const ollama)
                 (const claude-code) (const opencode) (const claude-tmux))
  :group 'cmacs-ai)

(defcustom cmacs-ai-default-model nil
  "Default model string, or nil to use the provider default."
  :type '(choice (const :tag "Provider default" nil) string)
  :group 'cmacs-ai)

(defcustom cmacs-ai-completion-provider 'claude-code
  "Provider used for inline FIM completion.
CLI providers (claude-code, opencode) are recommended -- they avoid
per-keystroke API costs."
  :type 'symbol
  :group 'cmacs-ai)

(defcustom cmacs-ai-system-prompt
  "You are an AI coding assistant embedded in cmacs (GNU Emacs with
GLib/GObject integration).  Respond in Org-mode-friendly markup: use
code fences with the right language, lists with - or 1., headings
with *.  Be concise -- prefer concrete code over hedging."
  "Default system prompt for new chat sessions."
  :type 'string
  :group 'cmacs-ai)

(defcustom cmacs-ai-pre-prompt
  "Your output goes directly into an Emacs Org-mode buffer.  Respond
**ONLY** in pure Org markup -- NOT Markdown.  Rules:

- If you use section headings, start them at `***' (subsubsection)
  so they nest under the chat's `** assistant' heading.
- Code blocks: `#+BEGIN_SRC <lang> ... #+END_SRC' (NEVER ``` fences).
- Emphasis: `*bold*', `/italic/', `=verbatim=', `~code~'.
- Lists: lines starting with `- ' or `1. '.
- File links: `[[file:PATH]]' or `[[file:PATH][LABEL]]'.
- Tables: pipe-delimited rows `| col | col |' with a `|---|---|' rule.

Do NOT emit Markdown `#`, `##', triple-backtick fences, `**bold**`,
underscored italics, or any other non-Org syntax -- they render as
literal text in Org and look broken.

User's request follows."
  "Default per-turn pre-prompt prepended to every user message.
Sent invisibly: the chat buffer still shows only what the user typed.
Set to nil or the empty string to disable.  Per-buffer override via
\\='(setq-local cmacs-ai-pre-prompt \"...\")\\='."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'cmacs-ai)

(defcustom cmacs-ai-user-label nil
  "Label rendered for user messages in chat buffer headings.
If nil, uses the value of the $USER environment variable, falling
back to the literal string \"user\" if unset.  Set to a specific
string (e.g. your name) to override."
  :type '(choice (const :tag "Default ($USER or \"user\")" nil)
                 string)
  :group 'cmacs-ai)

(defcustom cmacs-ai-assistant-label-format "%s/%s"
  "Format string for assistant message headings.
Receives two arguments via `format': the ai-glib provider name
(e.g. \"Claude\") and the effective model (e.g. \"claude-sonnet-4-6\").
The default produces e.g. \"Claude/claude-sonnet-4-6\".  When the
model can't be determined (no client, provider has no default),
only the provider name is shown -- the format string is bypassed."
  :type 'string
  :group 'cmacs-ai)

(defcustom cmacs-ai-max-tokens 4096
  "Default max output tokens for chat completions."
  :type 'integer
  :group 'cmacs-ai)

(defcustom cmacs-ai-enabled-tools
  '(bash read write edit glob grep web_fetch)
  "Built-in ai-glib tools advertised to the model.
Per the project default the full set is enabled (full trust).
Per-buffer override via `(setq-local cmacs-ai-enabled-tools ...)'."
  :type '(repeat symbol)
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-enable-tools t
  "When non-nil, new chat buffers spawn a fresh tool-executor and
advertise ai-glib's built-in tools (bash, read, write, edit, glob,
grep, ls, web_fetch) to the model.  Per-buffer override via
\\='(setq-local cmacs-ai-chat-tool-executor nil)\\=' before the
first send.

When tool use is enabled, the chat loop drives execution
automatically: model emits tool_use blocks -> chat layer executes
each (showing both call and result in the buffer) -> model is
re-prompted with the results -> repeat until it stops.  Capped at
`cmacs-ai-chat-tool-loop-max-turns' to avoid runaway loops."
  :type 'boolean
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-tool-loop-max-turns 20
  "Hard cap on consecutive tool-use re-streams in a single chat turn.
Mirrors ai-glib's own AiToolExecutor turn cap.  When reached, the
chat layer renders a `tool-loop-aborted' heading and stops."
  :type 'integer
  :group 'cmacs-ai)

(defcustom cmacs-ai-tool-confirm nil
  "If non-nil, prompt before each tool call.
A function is called as (FN TOOL-NAME ARGS); return nil to abort.
Symbols 'destructive prompts only for bash/write/edit."
  :type '(choice (const :tag "Never prompt" nil)
                 (const :tag "Destructive only" destructive)
                 function)
  :group 'cmacs-ai)

(defcustom cmacs-ai-chat-dir
  (expand-file-name "cmacs-ai/"
                    (or (getenv "XDG_DATA_HOME")
                        (expand-file-name "~/.local/share/")))
  "Directory where chat buffers are auto-saved."
  :type 'directory
  :group 'cmacs-ai)

(defcustom cmacs-ai-config-file
  (expand-file-name "ai-glib/config.yaml"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name "~/.config")))
  "Optional YAML config file for ai-glib (API keys, base URLs, ...).
Honored by ai-glib's AiConfig singleton; this defcustom is only
informational and is not auto-loaded -- ai-glib reads it directly."
  :type 'file
  :group 'cmacs-ai)

;;;; Provider helpers -----------------------------------------------

(declare-function cmacs-ai-supported-p "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-providers "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-config-default-provider
                  "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-client-new "cmacs-ai-client.c" (provider &optional model))
(declare-function cmacs-ai-client-free "cmacs-ai-client.c" (handle))
(declare-function cmacs-ai-client-set-model "cmacs-ai-client.c" (handle model))
(declare-function cmacs-ai-client-set-system-prompt
                  "cmacs-ai-client.c" (handle prompt))
(declare-function cmacs-ai-client-set-max-tokens
                  "cmacs-ai-client.c" (handle n))
(declare-function cmacs-ai-session-new "cmacs-ai-session.c" (client-handle))
(declare-function cmacs-ai-session-free "cmacs-ai-session.c" (handle))
(declare-function cmacs-ai-session-clear "cmacs-ai-session.c" (handle))
(declare-function cmacs-ai-session-append-message
                  "cmacs-ai-session.c" (handle role text))
(declare-function cmacs-ai-chat-stream
                  "cmacs-ai-stream.c" (session prompt callback))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-prompt-sync
                  "cmacs-ai-stream.c" (prompt &optional provider system))

(defun cmacs-ai--available-p ()
  "Return non-nil when the cmacs-ai C subsystem is linked in."
  (and (fboundp 'cmacs-ai-supported-p) (cmacs-ai-supported-p)))

(defun cmacs-ai--ensure ()
  "Signal a user-error if cmacs-ai is unavailable."
  (unless (cmacs-ai--available-p)
    (user-error "cmacs-ai not built; reconfigure with --with-cmacs-ai")))

;;;; High-level helpers ----------------------------------------------

(defun cmacs-ai-make-session (&optional provider model system-prompt)
  "Create a new (client, session) pair and return (CLIENT . SESSION).
PROVIDER defaults to `cmacs-ai-default-provider'.  MODEL defaults to
`cmacs-ai-default-model'.  SYSTEM-PROMPT defaults to
`cmacs-ai-system-prompt'.  Caller is responsible for freeing both
handles (use `cmacs-ai-free-session')."
  (cmacs-ai--ensure)
  (let* ((p (or provider cmacs-ai-default-provider))
         (m (or model cmacs-ai-default-model))
         (sys (or system-prompt cmacs-ai-system-prompt))
         (client (cmacs-ai-client-new p m))
         (session (cmacs-ai-session-new client)))
    (when (and sys (not (string-empty-p sys)))
      (cmacs-ai-client-set-system-prompt client sys))
    (cmacs-ai-client-set-max-tokens client cmacs-ai-max-tokens)
    (cons client session)))

(defun cmacs-ai-free-session (pair)
  "Free a (CLIENT . SESSION) pair previously made by `cmacs-ai-make-session'."
  (when pair
    (when (cdr pair) (cmacs-ai-session-free (cdr pair)))
    (when (car pair) (cmacs-ai-client-free  (car pair)))))

;;;; Loaders ---------------------------------------------------------

(defvar cmacs-ai--submodules
  '(cmacs-ai-chat cmacs-ai-region cmacs-ai-commit
    cmacs-ai-completion cmacs-ai-org-block cmacs-ai-agent
    cmacs-ai-voice cmacs-ai-context-menu)
  "Submodules that ship with cmacs-ai.")

(defun cmacs-ai-load-all ()
  "Force-load all cmacs-ai submodules.
Called by `M-x cmacs-ai-chat' on first use; manual users typically
require only what they need."
  (interactive)
  (dolist (m cmacs-ai--submodules)
    (require m nil 'noerror)))

;;;###autoload
(defun cmacs-ai-list-providers ()
  "Display the supported cmacs-ai providers in a buffer.
Shows each provider symbol, whether ai-glib sees an API key for
it, and which one is the configured default (from ai-glib's
AiConfig singleton + the `cmacs-ai-default-provider' defcustom)."
  (interactive)
  (cmacs-ai--ensure)
  (let ((buf (get-buffer-create "*cmacs-ai providers*"))
        (cfg-default (cmacs-ai-config-default-provider))
        (envs '((claude       . ("ANTHROPIC_API_KEY" "CLAUDE_API_KEY"))
                (openai       . ("OPENAI_API_KEY"))
                (gemini       . ("GEMINI_API_KEY"))
                (grok         . ("XAI_API_KEY" "GROK_API_KEY"))
                (ollama       . ("OLLAMA_HOST"))
                (claude-code  . ("CLAUDE_CODE_PATH"))
                (opencode     . ("OPENCODE_PATH"))
                (claude-tmux  . ("CLAUDE_CODE_PATH")))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "cmacs-ai providers\n")
        (insert "==================\n\n")
        (insert (format "Elisp defcustom default : %s\n"
                        cmacs-ai-default-provider))
        (insert (format "ai-glib config default  : %s\n\n" cfg-default))
        (insert
         (format "%-14s %-9s %-7s %s\n" "PROVIDER" "DEFAULT?" "KEY?" "ENV VARS"))
        (insert (make-string 70 ?-)) (insert "\n")
        (dolist (p (cmacs-ai-providers))
          (let* ((vars (cdr (assq p envs)))
                 (have (cl-some (lambda (v) (and (getenv v) v)) vars))
                 (def-marks
                  (concat (if (eq p cmacs-ai-default-provider) "E" " ")
                          (if (eq p cfg-default) "C" " "))))
            (insert (format "%-14s %-9s %-7s %s\n"
                            p def-marks
                            (if have "yes" "no")
                            (mapconcat #'identity vars " "))))))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

;;;###autoload
(defun cmacs-ai-show-default-provider ()
  "Echo the configured default provider and key status."
  (interactive)
  (cmacs-ai--ensure)
  (message "cmacs-ai default: elisp=%s  ai-glib-config=%s"
           cmacs-ai-default-provider
           (cmacs-ai-config-default-provider)))

(defun cmacs-ai--read-provider (&optional prompt)
  "Read a provider symbol with tab-completion.
Default is `cmacs-ai-default-provider'."
  (intern (completing-read
           (or prompt "Provider: ")
           (mapcar #'symbol-name (cmacs-ai-providers))
           nil t nil nil
           (symbol-name cmacs-ai-default-provider))))

;;;###autoload
(defun cmacs-ai-chat (&optional provider)
  "Open a new cmacs-ai chat buffer with PROVIDER.
With no PROVIDER (the default M-x form), uses
`cmacs-ai-default-provider'.  With a prefix arg, prompts for a
provider.  Call from Lisp with an explicit PROVIDER symbol to skip
the prompt."
  (interactive
   (list (when current-prefix-arg (cmacs-ai--read-provider))))
  (require 'cmacs-ai-chat)
  (cmacs-ai-chat-open provider))

;;;###autoload
(defun cmacs-ai-chat-with-provider (provider)
  "Open a new cmacs-ai chat buffer, prompting for PROVIDER.
Like `cmacs-ai-chat' with a prefix arg, but always prompts so
the M-x discovery surface is uniform."
  (interactive (list (cmacs-ai--read-provider "Chat with provider: ")))
  (require 'cmacs-ai-chat)
  (cmacs-ai-chat-open provider))

(provide 'cmacs-ai)
;;; cmacs-ai.el ends here
