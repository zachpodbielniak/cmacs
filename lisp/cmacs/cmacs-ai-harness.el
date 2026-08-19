;;; cmacs-ai-harness.el --- ai-glib's agentic harness in a buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ai-glib models an agent session as a transcript: an ordered list of
;; blocks, each of which renders to text plus a list of style spans.  The
;; grouping, the summarising and the input pipeline all live in the
;; library, so an ncurses harness (`ai-tui') and this buffer are both thin
;; -- neither knows what a tool is.
;;
;; This is not `cmacs-ai-chat'.  A chat buffer is an Org document you can
;; edit and save; a harness buffer is a *rendered view* of a transcript the
;; library owns, with an editable prompt at the end.  That is why export to
;; org exists here and does not there: the buffer is not org to begin with,
;; and span-derived faces would fight Org's own fontification.
;;
;; Two things are easy to get wrong and both are handled in one place:
;;
;;   - Span offsets are BYTE offsets into UTF-8.  `byte-to-position'
;;     converts.  Skip it and every face after the first accented filename
;;     lands in the wrong place.
;;   - `:block-changed' is not optional.  Streaming mutates a block in
;;     place, which the insertion event does not cover; without it the
;;     buffer shows the first delta of each reply and then stops.

;;; Code:

(require 'cmacs-ai)
(require 'subr-x)
(require 'cl-lib)

(declare-function cmacs-ai-harness-new "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-free "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-set-callback "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-send-input "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-cancel "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-clear "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-busy-p "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-activity "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-block-count "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-block-at "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-block-render "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-set-expanded "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-export "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-export-extension "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-complete "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-commands "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-working-directory "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-set-working-directory "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-provider-name "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-model "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-executor "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-set-local-tools "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-local-tools-p "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-set-system-prompt "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-cli-p "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-set-mcp-config "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-revoke-mcp-config "cmacs-ai-harness.c")
(declare-function cmacs-ai-harness-todos "cmacs-ai-harness.c")
(declare-function cmacs-ai-tools-list "cmacs-ai-tools.c")
(declare-function cmacs-ai--configure-executor "cmacs-ai" (executor))
(declare-function cmacs-brigade-host-provision "cmacs-brigade-host")
(declare-function cmacs-brigade-host-revoke "cmacs-brigade-host")
(declare-function cmacs-brigade-host-format-for-provider "cmacs-brigade-host")
(declare-function cmacs-brigade-host-endpoint-kind "cmacs-brigade-host")
(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function vc-root-dir "vc" ())

(defgroup cmacs-ai-harness nil
  "An agentic AI harness in an Emacs buffer."
  :group 'cmacs-ai
  :prefix "cmacs-ai-harness-")

;;;; Faces ------------------------------------------------------------
;;
;; One per `ai_style_tag_to_string' name.  The library's tags are ROLES,
;; not colours -- `added' says "this run is an addition" and says nothing
;; about green -- so the mapping is ours to make and a theme can override
;; any of them without ai-glib knowing.

(defface cmacs-ai-harness-user-prompt '((t :inherit font-lock-string-face))
  "Face for text the user typed." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-heading '((t :inherit font-lock-function-name-face :weight bold))
  "Face for a section heading." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-dim '((t :inherit shadow))
  "Face for secondary detail: counts, timings, hints." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-tool-name '((t :inherit font-lock-keyword-face))
  "Face for the verb of a tool group." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-tool-target '((t :inherit font-lock-string-face))
  "Face for what a tool acted on." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-tool-pending '((t :inherit shadow :slant italic))
  "Face for a tool call still running." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-tool-ok '((t :inherit success))
  "Face for a tool call that succeeded." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-tool-failed '((t :inherit error))
  "Face for a tool call that failed or was refused." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-added '((t :inherit diff-added))
  "Face for the \"+21\" of a diff summary." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-removed '((t :inherit diff-removed))
  "Face for the \"-6\" of a diff summary." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-code '((t :inherit font-lock-constant-face))
  "Face for literal text: a command, a path, a snippet." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-thinking '((t :inherit shadow :slant italic))
  "Face for reasoning, which is not the answer." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-error '((t :inherit error))
  "Face for a failure message." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-status '((t :inherit font-lock-comment-face))
  "Face for an informational note." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-link '((t :inherit link))
  "Face for a URL." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-marker '((t :inherit shadow))
  "Face for the expand/collapse affordance." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-mention '((t :inherit font-lock-variable-name-face))
  "Face for an @path the user typed." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-command '((t :inherit font-lock-builtin-face))
  "Face for a /name the user typed." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-todo-pending '((t :inherit shadow))
  "Face for a todo item not started." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-todo-active '((t :inherit warning :weight bold))
  "Face for the todo item being worked on." :group 'cmacs-ai-harness)
(defface cmacs-ai-harness-todo-done '((t :inherit success :strike-through t))
  "Face for a finished todo item." :group 'cmacs-ai-harness)

(defun cmacs-ai-harness--face-for (tag)
  "Return the face for style role TAG, or nil when there is none.
TAG is a string from `ai_style_tag_to_string'.  A role with no face --
`default' -- deliberately returns nil rather than a face that inherits
from nothing, so the surrounding text is left alone."
  (and (stringp tag)
       (not (equal tag "default"))
       (let ((sym (intern-soft (format "cmacs-ai-harness-%s" tag))))
         (and sym (facep sym) sym))))

;;;; Customization ----------------------------------------------------

(defcustom cmacs-ai-harness-provider nil
  "Provider used by \\[cmacs-ai-harness], or nil for the configured default.
See `cmacs-ai-providers' for the symbols this accepts."
  :type 'symbol
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-model nil
  "Model used by \\[cmacs-ai-harness], or nil for the provider's own default."
  :type '(choice (const :tag "Provider default" nil) string)
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-enable-tools t
  "Whether a harness gives the agent cmacs's tools.

An HTTP model receives them as a tools array built from the
conversation's executor; a command-line agent is handed an MCP config
naming this cmacs instead, because it runs its own tools in its own
process and ignores the array.  Two mechanisms, one switch."
  :type 'boolean
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-system-prompt
  "You are running inside cmacs, a GNU Emacs fork, as an agent in the
user's editor.  You have tools; use them rather than describing what you
would do.  Prefer the editor-native tools over shelling out."
  "System prompt for a harness session, or nil for none.

A model handed a tool array and no instructions tends to narrate a tool
call instead of making one, which is exactly what an empty tool surface
produced before tools were wired at all."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-ai-harness)

(defvar cmacs-ai-harness-executor-functions nil
  "Hook run to add tools to a harness, as (EXECUTOR PROVIDER).

A sibling of `cmacs-ai-chat-executor-functions' rather than the same
hook.  That one's members were written for chat buffers and include the
brigade's agent-spawning tools; running them here would silently change
what every existing member is handed.  Set
`cmacs-ai-harness-run-chat-executor-functions' to opt into both.")

(defcustom cmacs-ai-harness-cli-tool-allowlist "*"
  "Tools a command-line agent started here may call.

A comma-separated list of tool names or group names, expanded by
`cmacs-brigade-allowlist-expand'.

A harness buffer is a person typing a prompt and watching every tool
call render in front of them.  That is the trust level of
\\[eval-expression], not of an unattended worker running against a
budget -- so the default is the same `*' the chat buffer uses.  Set
`cmacs-brigade-restrict-privileged-tools' to t to hold back eval, bash
and the C-patching tools from `*' here and everywhere else."
  :type 'string
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-run-chat-executor-functions nil
  "Whether a harness also runs `cmacs-ai-chat-executor-functions'.
For the user who genuinely wants one tool set in both frontends."
  :type 'boolean
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-dir
  (expand-file-name "cmacs-ai/"
                    (or (getenv "XDG_DATA_HOME")
                        (expand-file-name "~/.local/share/")))
  "Directory offered first when exporting a harness session.
Shared with `cmacs-ai-chat-dir' on purpose: a session is a session, and
splitting them across two directories only makes them harder to find."
  :type 'directory
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-export-name-format
  "%y%m%d-%H%M%S-harness-<provider>"
  "File-name template for an exported harness session, without extension.
Passed through `format-time-string' (resolved against the session's
creation time), after which the literal token `<provider>' is replaced
with the provider name.  The extension comes from ai-glib, so an org
export and `ai-tui''s agree.  Mirrors `cmacs-ai-chat-save-name-format',
with `harness' where a chat has nothing."
  :type 'string
  :group 'cmacs-ai-harness)

(defcustom cmacs-ai-harness-prompt "› "
  "String marking the start of the editable prompt region."
  :type 'string
  :group 'cmacs-ai-harness)

;;;; Buffer-local state -----------------------------------------------

(defvar-local cmacs-ai-harness--handle nil
  "Integer handle of this buffer's ai-glib harness.")

(defvar-local cmacs-ai-harness--tools nil
  "How this buffer got its tools: nil, `local' or `mcp'.")

(defvar-local cmacs-ai-harness--cli-endpoint nil
  "Provisioned MCP endpoint for a CLI agent in this buffer.")

(defvar-local cmacs-ai-harness--tool-count 0
  "How many tools the executor carries, for the mode line.")

(defvar-local cmacs-ai-harness--regions nil
  "Hash of block id to (START-MARKER . END-MARKER).
Keyed on the block ID, never on its position: positions shift when
blocks are removed and ids are stable for the life of the process.")

(defvar-local cmacs-ai-harness--prompt-marker nil
  "Marker at the first character of the editable prompt region.")

(defvar-local cmacs-ai-harness--transcript-end nil
  "Marker where new transcript content is inserted.

Insertion type t, so text inserted AT it lands before the separator and
the marker keeps pointing at the separator afterwards.  A computed
position -- \"one line back from the prompt\" -- would be one blank line
away from correct the moment the separator's shape changed.")

(defvar-local cmacs-ai-harness--created-at nil
  "When this session started, for the export file name.")

(defvar-local cmacs-ai-harness--provider nil "Provider symbol, for display.")
(defvar-local cmacs-ai-harness--activity nil "What the current turn is doing.")
(defvar-local cmacs-ai-harness--busy nil "Non-nil while a run is in flight.")

;;;; Rendering --------------------------------------------------------

(defun cmacs-ai-harness--apply-spans (origin spans)
  "Apply SPANS to the text inserted at ORIGIN.

SPANS come from the library as BYTE offsets into the block's UTF-8; Emacs
counts characters.  `byte-to-position' converts, and a span never begins
or ends inside a character, so the conversion is exact.  Doing this by
character arithmetic instead misplaces every face after the first
multi-byte character in the buffer."
  (let ((base (position-bytes origin)))
    (pcase-dolist (`(,start ,end ,tag) spans)
      (when-let* ((face (cmacs-ai-harness--face-for tag))
                  (beg (byte-to-position (+ base start)))
                  (fin (byte-to-position (+ base end))))
        (put-text-property beg fin 'face face)))))

(defun cmacs-ai-harness--insert-block (id)
  "Insert block ID at point and record the region it occupies."
  (when-let* ((rendered (cmacs-ai-harness-block-render
                         cmacs-ai-harness--handle id))
              (text (car rendered))
              (origin (point)))
    (insert text)
    (cmacs-ai-harness--apply-spans origin (cdr rendered))
    ;; The whole block carries its id, so a command acting on "the block
    ;; at point" is a text-property lookup rather than a search.
    (put-text-property origin (point) 'cmacs-ai-harness-block id)
    (insert "\n\n")
    ;; The transcript is the library's, not the user's: it is redrawn from
    ;; ai-glib's blocks on every change, so an edit here would be silently
    ;; discarded the next time the block grew.  `rear-nonsticky' keeps the
    ;; property from leaking onto whatever is inserted after it.
    (add-text-properties origin (point) '(read-only t rear-nonsticky t))
    ;; The two insertion types are deliberately opposite, and both
    ;; matter.  A block's region must be exactly that block: the END is
    ;; type nil so appending the next block -- which is inserted at
    ;; precisely this position -- does not drag the marker along and
    ;; make every block's region swallow the rest of the transcript.
    ;; The START is type t so that the block survives an *earlier*
    ;; block being re-rendered: `cmacs-ai-harness--replace-block'
    ;; deletes the old text and inserts the new at the same position,
    ;; and every later block's start sits on that boundary, so only a
    ;; type-t marker moves to the far side of the replacement instead
    ;; of collapsing onto its front.
    ;;
    ;; The asymmetry is safe for the block being replaced because
    ;; `cmacs-ai-harness--insert-block' always stores fresh markers for
    ;; the block it draws, so its own start advancing past the new text
    ;; is discarded a line later.
    (puthash id
             (cons (copy-marker origin t)
                   (copy-marker (point)))
             cmacs-ai-harness--regions)))

(defun cmacs-ai-harness--replace-block (id)
  "Re-render block ID in place, for a block that grew."
  (let ((region (gethash id cmacs-ai-harness--regions)))
    (if (null region)
        ;; Never seen it: a change can arrive for a block whose insertion
        ;; we have not drawn yet.  Appending is right; dropping it would
        ;; lose the block entirely.
        (save-excursion
          (goto-char (cmacs-ai-harness--transcript-end))
          (cmacs-ai-harness--insert-block id))
      (save-excursion
        (delete-region (car region) (cdr region))
        (goto-char (car region))
        (cmacs-ai-harness--insert-block id)))))

(defun cmacs-ai-harness--transcript-end ()
  "Position just past the transcript, before the prompt region."
  (or (and cmacs-ai-harness--transcript-end
           (marker-position cmacs-ai-harness--transcript-end))
      (point-max)))

;;;; The prompt region ------------------------------------------------

(defun cmacs-ai-harness--draw-prompt ()
  "Create the prompt region at the end of the buffer."
  (goto-char (point-max))
  (let ((start (point)))
    (insert "\n" cmacs-ai-harness-prompt)
    ;; The separator and the marker glyph belong to the transcript; only
    ;; what follows is the user's to edit.  `rear-nonsticky' is what lets
    ;; the first character of the prompt be typed at all -- without it the
    ;; read-only property is inherited by whatever is inserted after it.
    (add-text-properties start (point)
                         '(read-only t rear-nonsticky t
                                     face cmacs-ai-harness-dim))
    ;; Set AFTER the separator exists, pointing at where it begins.
    ;; Setting it before and inserting the separator at the same position
    ;; walked it: insertion type t means the marker advances past text
    ;; inserted at it, so in an empty buffer it ended up on the far side
    ;; of the separator, and every transcript block was then inserted
    ;; into the prompt line instead of above it.
    ;;
    ;; Type t is still right for what comes later, and is the whole point:
    ;; a block inserted here lands before the separator and pushes the
    ;; marker along, so it keeps pointing at the separator afterwards.
    (setq cmacs-ai-harness--transcript-end (copy-marker start t))
    (setq cmacs-ai-harness--prompt-marker (copy-marker (point) nil))))

(defun cmacs-ai-harness-prompt-string ()
  "Return the text currently in the prompt region."
  (if (and cmacs-ai-harness--prompt-marker
           (marker-position cmacs-ai-harness--prompt-marker))
      (buffer-substring-no-properties cmacs-ai-harness--prompt-marker
                                      (point-max))
    ""))

(defun cmacs-ai-harness-set-prompt (text)
  "Replace the prompt region's contents with TEXT."
  (let ((inhibit-read-only t))
    (delete-region cmacs-ai-harness--prompt-marker (point-max))
    (goto-char (point-max))
    (insert (or text ""))))

;;;; Events from the library ------------------------------------------

(defun cmacs-ai-harness--on-event (buffer payload)
  "Handle PAYLOAD, an event from the harness attached to BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (pcase payload
          (`(:items-changed ,position ,_removed ,added)
           (save-excursion
             (goto-char (cmacs-ai-harness--transcript-end))
             (dotimes (i added)
               (when-let* ((info (cmacs-ai-harness-block-at
                                  cmacs-ai-harness--handle (+ position i)))
                           (id (plist-get info :id)))
                 (cmacs-ai-harness--insert-block id)))))

          ;; Not optional: streaming mutates a block in place, which the
          ;; insertion event does not report.
          (`(:block-changed ,_position ,id)
           (cmacs-ai-harness--replace-block id))

          (`(:busy ,flag)
           (setq cmacs-ai-harness--busy flag)
           (force-mode-line-update))

          (`(:activity ,what)
           (setq cmacs-ai-harness--activity what)
           (force-mode-line-update))

          (`(:error ,message)
           (message "cmacs-ai-harness: %s" message))

          (`(:builtin ,name ,arguments)
           (cmacs-ai-harness--builtin name arguments)))))))

(defun cmacs-ai-harness--builtin (name arguments)
  "Act on built-in command NAME with ARGUMENTS.
The library resolves these and hands them back rather than sending them:
it cannot know what /clear means to a buffer."
  (pcase name
    ("clear"
     (cmacs-ai-harness-clear cmacs-ai-harness--handle)
     (cmacs-ai-harness--redraw))
    ("quit" (kill-buffer))
    ("cwd"
     (when (and arguments (not (string-empty-p arguments)))
       (cmacs-ai-harness-set-working-directory
        cmacs-ai-harness--handle arguments))
     (message "cmacs-ai-harness: %s"
              (cmacs-ai-harness-working-directory cmacs-ai-harness--handle)))
    ("export"
     ;; `/export FMT [PATH]' with no path prompts, which is the whole
     ;; advantage of running this inside an editor.
     (let* ((parts (split-string (or arguments "") " " t))
            (fmt (intern (or (car parts) "markdown"))))
       (if (cadr parts)
           (cmacs-ai-harness--write-export fmt (cadr parts))
         (cmacs-ai-harness-export-to-file fmt))))
    ("save"
     (if (and arguments (not (string-empty-p arguments)))
         (cmacs-ai-harness--write-export 'text arguments)
       (cmacs-ai-harness-export-to-file 'text)))
    ((or "help" "commands") (cmacs-ai-harness--show-commands))
    ("cd" (cmacs-ai-harness--builtin "cwd" arguments))
    ((or "model" "provider")
     (message "cmacs-ai-harness: %s / %s"
              (or (cmacs-ai-harness-provider-name cmacs-ai-harness--handle)
                  "?")
              (or (cmacs-ai-harness-model cmacs-ai-harness--handle)
                  "default")))
    ("tools" (cmacs-ai-harness--show-tools))
    ("todos" (cmacs-ai-harness--show-todos))
    ;; Everything else the library resolved but this frontend has no
    ;; screen for.  Said out loud rather than swallowed: a slash command
    ;; that silently did nothing reads as a broken harness.
    (_ (message "cmacs-ai-harness: /%s is not available in this buffer"
                name))))

(defun cmacs-ai-harness--show-tools ()
  "List the tools this session's agent can call.

/tools is ai-glib's own builtin and used to fall through to \"not
available in this buffer\" -- so the one command anybody would reach for
to check whether tools are on denied they existed."
  (let ((buf (get-buffer-create "*cmacs-ai-harness: tools*")))
    (with-help-window buf
      (with-current-buffer buf
        (pcase cmacs-ai-harness--tools
          ('local
           (insert (format "%d tools, run in this Emacs.\n\n"
                           cmacs-ai-harness--tool-count))
           (dolist (name (ignore-errors
                           (cmacs-ai-tools-list
                            (cmacs-ai-harness-executor
                             cmacs-ai-harness--handle))))
             (insert "  " name "\n")))
          ('mcp
           (insert (format "%s runs its own tools, and reaches cmacs's \
over MCP.\n\n" (or cmacs-ai-harness--provider "This agent")))
           (insert "  allowlist: " cmacs-ai-harness-cli-tool-allowlist "\n")
           (insert "  config:    "
                   (or (plist-get cmacs-ai-harness--cli-endpoint :path) "?")
                   "\n"))
          (_
           (insert "No tools in this session.\n\n")
           (insert (if cmacs-ai-harness-enable-tools
                       "Wiring them failed; see *Messages*.\n"
                     "`cmacs-ai-harness-enable-tools' is nil.\n"))))))))

(defun cmacs-ai-harness--show-todos ()
  "Show the agent's todo list."
  (let ((todos (and (fboundp 'cmacs-ai-harness-todos)
                    (cmacs-ai-harness-todos cmacs-ai-harness--handle))))
    (if (null todos)
        (message "cmacs-ai-harness: no todos")
      (let ((buf (get-buffer-create "*cmacs-ai-harness: todos*")))
        (with-help-window buf
          (with-current-buffer buf
            (pcase-dolist (`(,label . ,state) todos)
              (insert (pcase state
                        ("completed" "  [x] ")
                        ("in_progress" "  [>] ")
                        (_ "  [ ] "))
                      label "\n"))))))))

(defun cmacs-ai-harness--show-commands ()
  "List the slash commands this harness knows, in a help buffer."
  (let ((commands (cmacs-ai-harness-commands cmacs-ai-harness--handle)))
    (with-help-window "*cmacs-ai harness commands*"
      (princ "Slash commands\n==============\n\n")
      (pcase-dolist (`(,name ,desc ,hint ,origin) commands)
        (princ (format "  /%-12s %-16s %s%s\n"
                       name (or hint "")
                       (or desc "")
                       (if origin (format "  [%s]" origin) "")))))))

(defun cmacs-ai-harness--redraw ()
  "Rebuild the whole transcript region from the library's blocks."
  (let ((inhibit-read-only t))
    (clrhash cmacs-ai-harness--regions)
    (save-excursion
      (delete-region (point-min) (cmacs-ai-harness--transcript-end))
      (goto-char (point-min))
      (dotimes (i (cmacs-ai-harness-block-count cmacs-ai-harness--handle))
        (when-let* ((info (cmacs-ai-harness-block-at
                           cmacs-ai-harness--handle i))
                    (id (plist-get info :id)))
          (cmacs-ai-harness--insert-block id))))))

;;;; Commands ---------------------------------------------------------

(defun cmacs-ai-harness-send ()
  "Send the prompt region through the harness."
  (interactive)
  (let ((line (string-trim (cmacs-ai-harness-prompt-string))))
    (cond
     ((string-empty-p line) (message "cmacs-ai-harness: nothing to send"))
     ((cmacs-ai-harness-busy-p cmacs-ai-harness--handle)
      (message "cmacs-ai-harness: still working -- %s to stop it"
               (substitute-command-keys "\\[cmacs-ai-harness-kill]")))
     (t
      (cmacs-ai-harness-set-prompt "")
      (cmacs-ai-harness-send-input cmacs-ai-harness--handle line)
      ;; Blocks arrive above the separator and the handler restores point,
      ;; but only relative to where it was -- so land explicitly in the
      ;; prompt, which is where the next thing you type belongs.
      (goto-char (point-max))))))

(defun cmacs-ai-harness-kill ()
  "Cancel the run in flight, or clear the prompt when idle.

One key for both, because that is what the terminal harness's ^C does and
the two are never ambiguous: there is either a run to stop or there is
not."
  (interactive)
  (if (cmacs-ai-harness-busy-p cmacs-ai-harness--handle)
      (progn (cmacs-ai-harness-cancel cmacs-ai-harness--handle)
             (message "cmacs-ai-harness: cancelled"))
    (cmacs-ai-harness-set-prompt "")))

(defun cmacs-ai-harness-block-at-point ()
  "Return the id of the transcript block at point, or nil."
  (get-text-property (point) 'cmacs-ai-harness-block))

(defun cmacs-ai-harness-toggle-block ()
  "Expand or collapse the transcript block at point."
  (interactive)
  (if-let* ((id (cmacs-ai-harness-block-at-point))
            (info (cl-loop for i below (cmacs-ai-harness-block-count
                                        cmacs-ai-harness--handle)
                           for b = (cmacs-ai-harness-block-at
                                    cmacs-ai-harness--handle i)
                           when (eq (plist-get b :id) id) return b)))
      ;; The library emits block-changed, so the redraw happens through
      ;; the normal path rather than here.
      (cmacs-ai-harness-set-expanded cmacs-ai-harness--handle id
                                     (not (plist-get info :expanded)))
    (message "cmacs-ai-harness: no block here")))

;;;; The compose buffer -----------------------------------------------

(defvar-local cmacs-ai-harness--compose-origin nil
  "The harness buffer a compose buffer belongs to.")

(defvar cmacs-ai-harness-compose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cmacs-ai-harness-compose-commit)
    (define-key m (kbd "C-c C-k") #'cmacs-ai-harness-compose-abort)
    m)
  "Keymap for `cmacs-ai-harness-compose-mode'.")

(define-derived-mode cmacs-ai-harness-compose-mode text-mode "AI-Compose"
  "Write a harness prompt with the whole editor available.

\\<cmacs-ai-harness-compose-mode-map>
\\[cmacs-ai-harness-compose-commit] installs the text as the prompt and
closes this buffer; \\[cmacs-ai-harness-compose-abort] throws it away.

The terminal harness hands the prompt to $EDITOR for this.  Inside Emacs
that would be an editor inside an editor, so the buffer is just a buffer."
  (setq-local header-line-format
              (substitute-command-keys
               "Compose  \\[cmacs-ai-harness-compose-commit] to use it, \
\\[cmacs-ai-harness-compose-abort] to discard")))

(defun cmacs-ai-harness-compose ()
  "Write this harness's prompt in a dedicated buffer.
Seeded with whatever is already in the prompt region, so reaching for a
real buffer part-way through a long prompt does not lose it."
  (interactive)
  (let ((origin (current-buffer))
        (seed (cmacs-ai-harness-prompt-string)))
    ;; Same window as the harness, for the same reason the harness takes
    ;; its own: this is where you are writing, and a split halves it.
    ;; `quit-window' puts the harness back when you are done.
    (switch-to-buffer (get-buffer-create "*cmacs-ai harness compose*"))
    (cmacs-ai-harness-compose-mode)
    (setq cmacs-ai-harness--compose-origin origin)
    (erase-buffer)
    (insert seed)))

(defun cmacs-ai-harness-compose-commit ()
  "Install this buffer's text as the harness prompt and close it."
  (interactive)
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (origin cmacs-ai-harness--compose-origin))
    (unless (buffer-live-p origin)
      (user-error "That harness buffer is gone"))
    (quit-window t)
    ;; `quit-window' has already put the harness back in this window when
    ;; compose replaced it there; switch anyway, because it has not when
    ;; the user moved windows in between.
    (switch-to-buffer origin)
    (cmacs-ai-harness-set-prompt text)
    (goto-char (point-max))))

(defun cmacs-ai-harness-compose-abort ()
  "Discard the compose buffer, leaving the prompt as it was."
  (interactive)
  (let ((origin cmacs-ai-harness--compose-origin))
    (quit-window t)
    (when (buffer-live-p origin) (switch-to-buffer origin))))

;;;; Export -----------------------------------------------------------

(defun cmacs-ai-harness--default-export-name (format)
  "Default file name for exporting this session as FORMAT."
  (concat (string-replace
           "<provider>"
           (format "%s" (or cmacs-ai-harness--provider "ai"))
           (format-time-string cmacs-ai-harness-export-name-format
                               cmacs-ai-harness--created-at))
          "."
          (cmacs-ai-harness-export-extension format)))

(defun cmacs-ai-harness--write-export (format path)
  "Write this session as FORMAT to PATH."
  (let ((doc (cmacs-ai-harness-export cmacs-ai-harness--handle format)))
    (with-temp-file path (insert doc))
    (message "cmacs-ai-harness: wrote %s" path)))

(defun cmacs-ai-harness-export-to-file (format)
  "Export this session as FORMAT, prompting for the file.

The prompt is `read-file-name', so it is the same directory browsing and
completion as \\[find-file] rather than a bespoke picker."
  (interactive (list (intern (completing-read
                              "Format: " '("markdown" "org" "text")
                              nil t nil nil "markdown"))))
  (unless (file-directory-p cmacs-ai-harness-dir)
    (make-directory cmacs-ai-harness-dir t))
  (let* ((default (cmacs-ai-harness--default-export-name format))
         (path (read-file-name
                (format "Export as %s: " format)
                (file-name-as-directory cmacs-ai-harness-dir)
                nil nil default)))
    (when (or (not (file-exists-p path))
              (yes-or-no-p (format "%s exists.  Overwrite? " path)))
      (cmacs-ai-harness--write-export format path))))

(defun cmacs-ai-harness-export-markdown ()
  "Export this session as markdown, prompting for the file."
  (interactive)
  (cmacs-ai-harness-export-to-file 'markdown))

(defun cmacs-ai-harness-export-org ()
  "Export this session as Org, prompting for the file."
  (interactive)
  (cmacs-ai-harness-export-to-file 'org))

;;;; Completion -------------------------------------------------------

(defun cmacs-ai-harness-completion-at-point ()
  "Complete the slash command or @path before point.

Backed by ai-glib, so the same command files the terminal harness reads
complete here.  The library decides the range: recomputing it as \"the
word before point\" disagrees the first time somebody completes @src/co,
where the token includes a slash."
  (when (and cmacs-ai-harness--handle
             cmacs-ai-harness--prompt-marker
             (>= (point) cmacs-ai-harness--prompt-marker))
    (let* ((text (cmacs-ai-harness-prompt-string))
           (origin (marker-position cmacs-ai-harness--prompt-marker))
           ;; Byte offsets in both directions, 0-based in the library and
           ;; 1-based in Emacs -- hence the 1- and the 1+ below.
           (cursor (- (position-bytes (point)) (position-bytes origin)))
           (result (cmacs-ai-harness-complete
                    cmacs-ai-harness--handle text (max 0 cursor))))
      (when result
        (pcase-let ((`(,start ,end ,candidates) result))
          (list (byte-to-position (+ (position-bytes origin) start))
                (byte-to-position (+ (position-bytes origin) end))
                (mapcar (lambda (c)
                          (propertize (nth 0 c)
                                      'cmacs-ai-harness-annotation (nth 2 c)))
                        candidates)
                :annotation-function
                (lambda (c)
                  (when-let* ((a (get-text-property
                                  0 'cmacs-ai-harness-annotation c)))
                    (concat "  " a)))
                :exclusive 'no))))))

;;;; The mode ---------------------------------------------------------

(defvar cmacs-ai-harness-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cmacs-ai-harness-send)
    (define-key m (kbd "C-c C-k") #'cmacs-ai-harness-kill)
    (define-key m (kbd "C-c C-g") #'cmacs-ai-harness-compose)
    ;; `C-c C-E' is NOT a key.  Emacs cannot tell Control-Shift-letter
    ;; from Control-letter, so (kbd "C-c C-E") and (kbd "C-c C-e") are
    ;; the same sequence -- binding both meant the second define-key
    ;; silently ate the first and one of the two exports was unreachable.
    ;; `C-c E' is a distinct sequence and works on a tty, where
    ;; Control-Shift-e is not expressible at all.
    (define-key m (kbd "C-c C-e") #'cmacs-ai-harness-export-org)
    (define-key m (kbd "C-c E") #'cmacs-ai-harness-export-markdown)
    (define-key m (kbd "TAB") #'completion-at-point)
    (define-key m (kbd "C-c C-t") #'cmacs-ai-harness-toggle-block)
    m)
  "Keymap for `cmacs-ai-harness-mode'.")

(defun cmacs-ai-harness--tools-indicator ()
  "Mode-line fragment naming how this session got its tools.

Worth the space because the failure that matters most is invisible from
the transcript: a provider that silently took none.  A one-shot message
at startup is not enough for a buffer that stays open for hours."
  (pcase cmacs-ai-harness--tools
    ('local (propertize (format " %d tools" cmacs-ai-harness--tool-count)
                        'face 'cmacs-ai-harness-dim))
    ('mcp (propertize " mcp" 'face 'cmacs-ai-harness-dim))
    (_ (if cmacs-ai-harness-enable-tools
           (propertize " no tools" 'face 'cmacs-ai-harness-error)
         ""))))

(defun cmacs-ai-harness--mode-line ()
  "Mode-line tail: what the agent is doing, and what it can do."
  (concat
   (cond (cmacs-ai-harness--activity
          (format "  [%s]" cmacs-ai-harness--activity))
         (cmacs-ai-harness--busy "  [working]")
         (t ""))
   (cmacs-ai-harness--tools-indicator)))

(define-derived-mode cmacs-ai-harness-mode fundamental-mode "AI-Harness"
  "An ai-glib agent session in a buffer.

\\<cmacs-ai-harness-mode-map>
\\[cmacs-ai-harness-send] sends the prompt, \\[cmacs-ai-harness-kill]
cancels a run or clears the prompt, and \\[cmacs-ai-harness-compose]
opens a dedicated buffer to write a long one in.

\\[cmacs-ai-harness-export-org] exports the session as Org and
\\[cmacs-ai-harness-export-markdown] as markdown.  \\[completion-at-point]
completes slash commands and @paths from the same files the terminal
harness reads.

The transcript above the prompt is read-only and is owned by the library:
it is redrawn from ai-glib's blocks, not edited in place."
  (setq-local cmacs-ai-harness--regions (make-hash-table :test 'eql))
  (setq-local cmacs-ai-harness--created-at (current-time))
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  ;; Derived from `fundamental-mode', NOT `special-mode', and the
  ;; difference is the whole reason you can type here.  `special-mode'
  ;; makes the buffer read-only -- which is right for the transcript and
  ;; wrong for the prompt -- and, more to the point, Evil gives modes
  ;; derived from it normal state, where the letters you meant to type
  ;; into the prompt are motions and operators instead.  The transcript
  ;; is protected by a text property, which protects exactly the part
  ;; that needs it and leaves the prompt alone.
  (add-hook 'completion-at-point-functions
            #'cmacs-ai-harness-completion-at-point nil t)
  (setq-local mode-line-process '(:eval (cmacs-ai-harness--mode-line)))
  (add-hook 'kill-buffer-hook #'cmacs-ai-harness--cleanup nil t))

;; The buffer is a prompt you type into that happens to have a transcript
;; above it, so it opens ready to type -- the same call eshell, vterm and
;; a commit message get.  ESC still reaches normal state for navigating
;; the transcript with the motions you already know.
;;
;; `with-eval-after-load' rather than a bare `fboundp' guard, which the
;; other cmacs modes use: that guard silently does nothing when this file
;; loads before Evil, and the failure mode is landing in normal state
;; where the letters you type are operators -- which is not obviously an
;; Evil problem when you hit it.
(with-eval-after-load 'evil
  (evil-set-initial-state 'cmacs-ai-harness-mode 'insert)
  (evil-set-initial-state 'cmacs-ai-harness-compose-mode 'insert))

(defun cmacs-ai-harness--wire-cli-tools ()
  "Hand a command-line agent an MCP config naming this cmacs.

A CLI agent runs its own tools in its own process, so the executor is
useless to it; what it takes is a config file describing a server to
connect back to.  `cmacs-brigade-host-provision' mints one -- a random
token, a 0600 file under XDG_RUNTIME_DIR, the allowlist expanded here
where the tool registry lives -- and the provider decides how the path
is delivered.

The dialect is chosen by provider because the agents do not agree on
one; the kind string is what tells ai-glib which it is being handed."
  (cond
   ((not (fboundp 'cmacs-brigade-host-provision))
    (message "cmacs-ai-harness: %s takes tools over MCP; needs \
--with-cmacs-ai-brigade to provision one"
             (or cmacs-ai-harness--provider "this agent")))
   (t
    (let* ((fmt (cmacs-brigade-host-format-for-provider
                 cmacs-ai-harness--provider))
           (endpoint (cmacs-brigade-host-provision
                      (format "harness-%s" (buffer-name))
                      cmacs-ai-harness-cli-tool-allowlist
                      :format fmt)))
      (cond
       ((null endpoint)
        (message "cmacs-ai-harness: could not provision MCP tools for %s"
                 (or cmacs-ai-harness--provider "this agent")))
       ((not (cmacs-ai-harness-set-mcp-config
              cmacs-ai-harness--handle
              (plist-get endpoint :path)
              (cmacs-brigade-host-endpoint-kind fmt)))
        ;; Said out loud rather than swallowed: the buffer would
        ;; otherwise look tool-enabled and have none.
        (message "cmacs-ai-harness: %s did not accept an MCP config; \
this session has no cmacs tools"
                 (or cmacs-ai-harness--provider "this agent"))
        (ignore-errors
          (cmacs-brigade-host-revoke (format "harness-%s" (buffer-name)))))
       (t
        (setq cmacs-ai-harness--cli-endpoint endpoint
              cmacs-ai-harness--tools 'mcp)))))))

(defun cmacs-ai-harness--revoke-cli-tools ()
  "Drop this buffer's MCP credential when the buffer goes."
  (when (and cmacs-ai-harness--cli-endpoint
             (fboundp 'cmacs-brigade-host-revoke))
    (ignore-errors
      (cmacs-brigade-host-revoke (format "harness-%s" (buffer-name))))
    (setq cmacs-ai-harness--cli-endpoint nil)))

(defun cmacs-ai-harness--wire-tools ()
  "Give this buffer's agent cmacs's tools.

Two mechanisms, chosen by provider kind, because they genuinely differ.
An HTTP model is sent a tools array built from the conversation's
executor.  A command-line agent ignores that array entirely -- ai-glib
refuses local tools for one -- and instead takes an MCP config naming
this cmacs, which `cmacs-ai-harness--wire-cli-tools' provisions.

Says so out loud when it cannot: a session that looks tool-enabled and
has none is the failure this whole path exists to prevent, and it is
invisible from the transcript."
  (when cmacs-ai-harness-enable-tools
    (if (and (fboundp 'cmacs-ai-harness-cli-p)
             (cmacs-ai-harness-cli-p cmacs-ai-harness--handle))
        (cmacs-ai-harness--wire-cli-tools)
      (cmacs-ai-harness--wire-local-tools))))

(defun cmacs-ai-harness--wire-local-tools ()
  "Register cmacs's MCP tools on this harness's own executor."
  (when (fboundp 'cmacs-ai-harness-executor)
    (let ((executor (cmacs-ai-harness-executor cmacs-ai-harness--handle)))
      (cmacs-ai--configure-executor executor)
      (run-hook-with-args 'cmacs-ai-harness-executor-functions
                          executor cmacs-ai-harness--provider)
      (when cmacs-ai-harness-run-chat-executor-functions
        (run-hook-with-args 'cmacs-ai-chat-executor-functions
                            executor cmacs-ai-harness--provider))
      ;; Last, and not optional: without it the provider is sent no tools
      ;; array at all and everything above is decoration.
      (if (cmacs-ai-harness-set-local-tools cmacs-ai-harness--handle t)
          (setq cmacs-ai-harness--tools 'local
                cmacs-ai-harness--tool-count
                (length (ignore-errors (cmacs-ai-tools-list executor))))
        (message "cmacs-ai-harness: %s would not take local tools"
                 (or cmacs-ai-harness--provider "this provider"))))))

(defun cmacs-ai-harness--cleanup ()
  "Free this buffer's harness, cancelling anything in flight.

The order is load-bearing.  Cancel while the conversation is still
whole, so the provider can react to its own cancellable.  Free the
harness next, which drops the adopted executor handle and reaps any CLI
subprocess.  Revoke the MCP credential last: revoking first would delete
the config out from under an agent that is still shutting down, and its
final tool call would fail in a way that reads as a cmacs bug."
  (when cmacs-ai-harness--handle
    (when (ignore-errors
            (cmacs-ai-harness-busy-p cmacs-ai-harness--handle))
      (ignore-errors (cmacs-ai-harness-cancel cmacs-ai-harness--handle)))
    (ignore-errors (cmacs-ai-harness-free cmacs-ai-harness--handle))
    (setq cmacs-ai-harness--handle nil))
  (cmacs-ai-harness--revoke-cli-tools))

;;;; Entry points -----------------------------------------------------

(defun cmacs-ai-harness--start (provider model directory)
  "Open a harness buffer on PROVIDER/MODEL running in DIRECTORY."
  (unless (fboundp 'cmacs-ai-harness-new)
    (user-error "This cmacs was built without --with-cmacs-ai"))
  (let* ((dir (or directory default-directory))
         (buf (generate-new-buffer
               (format "*ai-harness: %s*"
                       (abbreviate-file-name (directory-file-name dir))))))
    (with-current-buffer buf
      (cmacs-ai-harness-mode)
      (setq cmacs-ai-harness--provider (or provider
                                           cmacs-ai-harness-provider))
      (setq default-directory (file-name-as-directory dir))
      (setq cmacs-ai-harness--handle
            (cmacs-ai-harness-new (or provider cmacs-ai-harness-provider)
                                  (or model cmacs-ai-harness-model)
                                  dir))
      ;; The provider symbol may have been nil ("use the default"); ask
      ;; what was actually built so the export file name says so.
      (unless cmacs-ai-harness--provider
        (setq cmacs-ai-harness--provider
              (or (cmacs-ai-harness-provider-name cmacs-ai-harness--handle)
                  "ai")))
      ;; After the provider is known, because which half of the tool
      ;; wiring applies is decided by provider kind.
      (when (and cmacs-ai-harness-system-prompt
                 (fboundp 'cmacs-ai-harness-set-system-prompt))
        (ignore-errors
          (cmacs-ai-harness-set-system-prompt
           cmacs-ai-harness--handle cmacs-ai-harness-system-prompt)))
      (cmacs-ai-harness--wire-tools)
      (let ((this buf))
        (cmacs-ai-harness-set-callback
         cmacs-ai-harness--handle
         (lambda (payload) (cmacs-ai-harness--on-event this payload))))
      (let ((inhibit-read-only t))
        (cmacs-ai-harness--draw-prompt))
      (goto-char (point-max)))
    ;; Takes the window, as a chat buffer does.  `pop-to-buffer' splits,
    ;; which is wrong for something you sit in front of and work in.
    (switch-to-buffer buf)
    (goto-char (point-max))
    buf))

(defun cmacs-ai-harness-project-or-default-directory ()
  "Return the project root of `default-directory', or that directory.

Falls back the same way `cmacs-ai-agent--project-root' does, so the two
agree about what \"this project\" means."
  (or (and (fboundp 'project-current)
           (let ((p (project-current))) (when p (project-root p))))
      (and (fboundp 'vc-root-dir) (vc-root-dir))
      default-directory))

(defcustom cmacs-ai-harness-default-directory-function
  #'cmacs-ai-harness-project-or-default-directory
  "How a new harness picks the directory it runs in.

The project root rather than `default-directory' because an agent's
directory is not cosmetic: CLAUDE.md, .claude, the project's own command
files and every relative path a tool touches resolve against it, and a
harness opened from a buffer three levels down would otherwise start
somewhere the project's own configuration is invisible.

Only supplies the default -- an explicit directory, as
\\[cmacs-ai-harness-with-provider-in-directory] takes, always wins."
  :type 'function
  :group 'cmacs-ai-harness)

(defun cmacs-ai-harness--default-directory ()
  "Directory a new harness runs in when none was given."
  (or (ignore-errors
        (funcall cmacs-ai-harness-default-directory-function))
      default-directory))

;;;###autoload
(defun cmacs-ai-harness ()
  "Open an agentic AI harness in a buffer.

Uses `cmacs-ai-harness-provider' and `cmacs-ai-harness-model', and runs
in the current project's root -- see
`cmacs-ai-harness-default-directory-function'.  For a different provider
see \\[cmacs-ai-harness-with-provider]; for a different directory see
\\[cmacs-ai-harness-with-provider-in-directory]."
  (interactive)
  (cmacs-ai-harness--start nil nil (cmacs-ai-harness--default-directory)))

;;;###autoload
(defun cmacs-ai-harness-with-provider (provider &optional model)
  "Open a harness on PROVIDER, optionally pinning MODEL.
Runs in the current project's root, as \\[cmacs-ai-harness] does."
  (interactive
   (let ((p (intern (completing-read
                     "Provider: "
                     (mapcar #'symbol-name (cmacs-ai-providers))
                     nil t))))
     (list p (cmacs-ai--read-model p))))
  (cmacs-ai-harness--start provider model
                           (cmacs-ai-harness--default-directory)))

;;;###autoload
(defun cmacs-ai-harness-with-provider-in-directory (provider directory
                                                             &optional model)
  "Open a harness on PROVIDER running in DIRECTORY, optionally pinning MODEL.

The directory is what CLAUDE.md, .claude, the project's own command files
and every relative path a tool touches resolve against -- an agent
started in the wrong one is a different agent."
  (interactive
   (let* ((p (intern (completing-read
                      "Provider: "
                      (mapcar #'symbol-name (cmacs-ai-providers))
                      nil t)))
          (d (read-directory-name "Run in: " default-directory nil t)))
     (list p d (cmacs-ai--read-model p))))
  (cmacs-ai-harness--start provider model directory))

;;;; Context-menu actions ---------------------------------------------
;;
;; These register into the same table `cmacs-ai-menu' reads, so they
;; appear on the right-click menu and under `cmacs-ai-menu-pick' with no
;; further wiring.  Every one is gated on `cmacs-ai-harness-mode', so they
;; cost nothing in any other buffer.

(declare-function cmacs-ai-register-action "cmacs-ai-actions")
(declare-function cmacs-ai-textops-stream "cmacs-ai-textops")
(declare-function cmacs-ai-make-session "cmacs-ai")
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c")

(defun cmacs-ai-harness--live-p (&optional _target)
  "Non-nil in a harness buffer with a session attached."
  (and (derived-mode-p 'cmacs-ai-harness-mode)
       cmacs-ai-harness--handle))

(defun cmacs-ai-harness--session-text ()
  "This session as a markdown document, for feeding back to a model."
  (cmacs-ai-harness-export cmacs-ai-harness--handle 'markdown))

(defun cmacs-ai-harness-summarize-session ()
  "Summarize this session in a result window.

Reads the exported transcript rather than the buffer text: the export
carries collapsed tool groups in full, so the summary can say what the
agent actually did rather than only what it narrated."
  (interactive)
  (require 'cmacs-ai-textops)
  (let ((doc (cmacs-ai-harness--session-text)))
    (when (string-empty-p (string-trim doc))
      (user-error "cmacs-ai-harness: nothing has happened yet"))
    (cmacs-ai-textops-stream
     "*cmacs-ai: session summary*"
     "summary of the harness session"
     "You are summarizing a transcript of an AI coding agent session.
Say what was asked, what the agent did (including tool calls), what
changed on disk, and what is left unfinished.  Be specific about file
names.  Do not invent anything that is not in the transcript."
     doc
     #'cmacs-ai-harness-summarize-session)))

(defun cmacs-ai-harness-next-steps ()
  "Ask what to do next, given everything in this session."
  (interactive)
  (require 'cmacs-ai-textops)
  (let ((doc (cmacs-ai-harness--session-text)))
    (when (string-empty-p (string-trim doc))
      (user-error "cmacs-ai-harness: nothing has happened yet"))
    (cmacs-ai-textops-stream
     "*cmacs-ai: next steps*"
     "next steps from the harness session"
     "You are reading a transcript of an AI coding agent session.
List the concrete next steps, most important first, as a short checklist.
Each item should be something a person could act on without re-reading
the transcript.  Say explicitly if something looks wrong or unverified."
     doc
     #'cmacs-ai-harness-next-steps)))

(defun cmacs-ai-harness--install-generated (buffer text)
  "Put TEXT in BUFFER's prompt region, if BUFFER is still a harness."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cmacs-ai-harness-set-prompt (string-trim text))
      (goto-char (point-max))
      (message "cmacs-ai-harness: prompt written -- %s to send"
               (substitute-command-keys "\\[cmacs-ai-harness-send]")))))

(defun cmacs-ai-harness--generate (system prompt)
  "Stream SYSTEM/PROMPT and install the answer as this buffer's prompt.

Async rather than a blocking call: writing a prompt is a model round
trip, and freezing the editor for it would make the feature worse than
typing the prompt by hand."
  (require 'cmacs-ai)
  (cmacs-ai--ensure)
  (let* ((buffer (current-buffer))
         (pair (cmacs-ai-make-session cmacs-ai-harness-provider
                                      cmacs-ai-harness-model
                                      system))
         (acc ""))
    (message "cmacs-ai-harness: writing a prompt...")
    (cmacs-ai-chat-stream
     (cdr pair) prompt
     (lambda (payload)
       (pcase (car-safe payload)
         (:delta (setq acc (concat acc (or (cadr payload) ""))))
         (:end
          ;; A non-streaming provider delivers the whole answer here and
          ;; nothing incrementally, so only fall back when nothing came.
          (let ((final (plist-get (cdr payload) :text)))
            (when (and final (string-empty-p acc)) (setq acc final)))
          (cmacs-ai-harness--install-generated buffer acc))
         (:error
          (message "cmacs-ai-harness: %s"
                   (or (cadr payload) "could not write a prompt"))))))))

(defun cmacs-ai-harness-generate-prompt (&optional description)
  "Write this buffer's prompt for you.

With the prompt region empty, asks what you are trying to do and turns
the answer into a prompt.  With something already there, rewrites what
you have into a stronger version of the same request rather than
replacing your intent with its own."
  (interactive)
  (unless (cmacs-ai-harness--live-p)
    (user-error "cmacs-ai-harness: not a harness buffer"))
  (let ((existing (string-trim (cmacs-ai-harness-prompt-string))))
    (if (string-empty-p existing)
        (let ((what (or description
                        (read-string "What do you want the agent to do? "))))
          (when (string-empty-p (string-trim what))
            (user-error "cmacs-ai-harness: nothing to work from"))
          (cmacs-ai-harness--generate
           "You write prompts for an autonomous coding agent that has
tools to read and write files and run commands.  Turn the user's
description into one clear, specific prompt.  State the goal, the
constraints, and what done looks like.  Do not ask questions, do not
explain yourself, and do not wrap the answer in quotes or code fences --
output only the prompt text."
           (format "Working directory: %s\n\nWhat I want: %s"
                   (cmacs-ai-harness-working-directory
                    cmacs-ai-harness--handle)
                   what)))
      (cmacs-ai-harness--generate
       "You strengthen prompts for an autonomous coding agent.  Keep the
user's intent exactly; make it specific and testable.  Add the
constraints and success criteria the request implies but does not say.
Do not broaden the scope, do not ask questions, and output only the
rewritten prompt with no preamble, quotes or code fences."
       (format "Working directory: %s\n\nDraft prompt:\n%s"
               (cmacs-ai-harness-working-directory cmacs-ai-harness--handle)
               existing)))))

(defun cmacs-ai-harness-copy-block ()
  "Copy the transcript block at point to the kill ring."
  (interactive)
  (if-let* ((id (cmacs-ai-harness-block-at-point))
            (region (gethash id cmacs-ai-harness--regions)))
      (progn
        (kill-new (buffer-substring-no-properties (car region) (cdr region)))
        (message "cmacs-ai-harness: block copied"))
    (user-error "cmacs-ai-harness: no block here")))

(defun cmacs-ai-harness-explain-block ()
  "Explain the transcript block at point in a result window."
  (interactive)
  (require 'cmacs-ai-textops)
  (if-let* ((id (cmacs-ai-harness-block-at-point))
            (region (gethash id cmacs-ai-harness--regions))
            (text (buffer-substring-no-properties (car region) (cdr region))))
      (cmacs-ai-textops-stream
       "*cmacs-ai: explain*"
       "one block of the harness session"
       "Explain what this fragment of an AI agent session means: what was
done, why it would have been done, and anything about it worth
questioning.  Be brief."
       text
       #'cmacs-ai-harness-explain-block)
    (user-error "cmacs-ai-harness: no block here")))

(dolist (spec
         `((harness-generate-prompt 10 "Write this prompt for me"
                                    cmacs-ai-harness-generate-prompt
                                    "Draft or strengthen the prompt")
           (harness-summarize 20 "Summarize this session"
                              cmacs-ai-harness-summarize-session
                              "What happened in this session")
           (harness-next-steps 30 "Next steps from this session"
                               cmacs-ai-harness-next-steps
                               "A checklist of what to do next")
           (harness-explain-block 40 "Explain this block"
                                  cmacs-ai-harness-explain-block
                                  "Explain the block under the pointer")
           (harness-copy-block 50 "Copy this block"
                               cmacs-ai-harness-copy-block
                               "Copy the block under the pointer")
           (harness-export-md 60 "Export session as markdown"
                              cmacs-ai-harness-export-markdown
                              "Write the session to a markdown file")
           (harness-export-org 70 "Export session as Org"
                               cmacs-ai-harness-export-org
                               "Write the session to an Org file")))
  (pcase-let ((`(,name ,order ,label ,fn ,help) spec))
    (cmacs-ai-register-action
     :name name
     :group 'harness
     :order order
     :label label
     :help help
     :applies #'cmacs-ai-harness--live-p
     :run (lambda (_target) (call-interactively fn)))))

(provide 'cmacs-ai-harness)

;;; cmacs-ai-harness.el ends here
