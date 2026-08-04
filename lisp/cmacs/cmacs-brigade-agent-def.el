;;; cmacs-brigade-agent-def.el --- Agent definitions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An agent is a markdown file with YAML frontmatter: metadata above,
;; the system prompt below.
;;
;;     ---
;;     name: researcher
;;     model: claude/claude-sonnet-4-6
;;     tools: [memory_search, web_search]
;;     budget-usd: 0.50
;;     ---
;;     You are a research analyst...
;;
;; Not org, even though everything else here is: agent definitions would
;; otherwise be indexed as part of the notes corpus and retrieved as
;; "knowledge", so a question about research methodology would surface
;; the researcher's own prompt.  Not a `defcustom' either -- the body is
;; prose, and prose in a customization string is miserable to edit and
;; diffs badly.
;;
;; Markdown with frontmatter is also the interop surface: `worker:
;; claude-code' hands the file to an external CLI more or less verbatim,
;; and the same format already sits in ~/.claude/agents.
;;
;; The parser is deliberately small.  It handles the subset of YAML that
;; frontmatter actually uses -- scalars, inline lists, comments -- rather
;; than pulling in a full parser for a dozen keys.  Anything it does not
;; recognise is carried through untouched so a future key is not an
;; error today.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)
(require 'subr-x)

(defcustom cmacs-brigade-agent-path
  (list (expand-file-name "cmacs/brigade/agents" data-directory)
        (expand-file-name "cmacs/brigade/agents"
                          (or (getenv "XDG_CONFIG_HOME")
                              (expand-file-name ".config" "~")))
        (expand-file-name ".claude/agents" "~"))
  "Directories searched for agent definitions, earliest to latest.

A later definition of the same name replaces an earlier one, so a user
copy overrides a shipped agent by name alone.  The project-local
directory is consulted separately per project and always wins."
  :type '(repeat directory)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-agent-project-dir ".cmacs/agents"
  "Per-project agent directory, relative to the project root."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-default-model "claude/claude-sonnet-4-6"
  "Model used by an agent that does not name one."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-default-budget-usd 0.00
  "Spend ceiling, in US dollars, for an agent that does not set one.

Zero means no ceiling, matching ai-glib\='s `AiBudget\=' convention, where
every limit is tested only when it is greater than zero -- so a zero
input-token, turn or wall-clock limit is likewise unlimited.

Note that nothing enforces this yet on the worker paths cmacs currently
ships.  `cmacs-brigade-run\=' spawns claude-code, opencode or a shell as a
subprocess, and a subprocess spends what it spends; the `AiBudget\='
ceiling lives in ai-glib\='s in-process agent runtime, which the Elisp
runner does not drive.  The value is carried on the agent definition and
reported, but it does not stop a run, and the `over-budget\=' state is
currently unreachable."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-default-max-turns 40
  "Turn ceiling for an agent that does not set one."
  :type 'integer
  :group 'cmacs-brigade)

(define-error 'cmacs-brigade-agent-error
  "Invalid agent definition" 'cmacs-brigade-error)


;;;; Frontmatter

(defun cmacs-brigade-agent--split (text)
  "Split TEXT into (FRONTMATTER . BODY).

Returns (nil . TEXT) when there is no frontmatter, which is how a plain
markdown file -- an imported ~/.claude/agents entry, say -- still parses
into something usable."
  (if (string-prefix-p "---" text)
      (let* ((after (string-remove-prefix "---" text))
             (end (string-match "^---[ \t]*$" after)))
        (if end
            (cons (substring after 0 end)
                  (string-trim-left (substring after (match-end 0))))
          (cons nil text)))
    (cons nil text)))

(defun cmacs-brigade-agent--parse-scalar (s)
  "Parse one YAML scalar S into a Lisp value."
  (let ((v (string-trim s)))
    (cond
     ((string-empty-p v) nil)
     ;; inline list: [a, b, c]
     ((and (string-prefix-p "[" v) (string-suffix-p "]" v))
      (let ((inner (string-trim (substring v 1 -1))))
        (if (string-empty-p inner) nil
          (mapcar (lambda (e) (cmacs-brigade-agent--parse-scalar e))
                  (split-string inner "," t "[ \t]+")))))
     ((and (string-prefix-p "\"" v) (string-suffix-p "\"" v) (> (length v) 1))
      (substring v 1 -1))
     ((and (string-prefix-p "'" v) (string-suffix-p "'" v) (> (length v) 1))
      (substring v 1 -1))
     ((member v '("true" "yes" "on")) t)
     ((member v '("false" "no" "off")) nil)
     ((string-match-p "\\`-?[0-9]+\\'" v) (string-to-number v))
     ((string-match-p "\\`-?[0-9]*\\.[0-9]+\\'" v) (string-to-number v))
     (t v))))

(defun cmacs-brigade-agent--parse-frontmatter (text)
  "Parse frontmatter TEXT into an alist of (KEY . VALUE).

Supports `key: value', inline lists, and block lists written as
indented `- item' lines.  Comments and blank lines are skipped."
  (let (out key items)
    (dolist (line (split-string (or text "") "\n"))
      (cond
       ((string-match-p "\\`[ \t]*#" line))            ; comment
       ((string-match-p "\\`[ \t]*\\'" line))          ; blank
       ;; a block-list item belonging to the previous key
       ((and key (string-match "\\`[ \t]+-[ \t]+\\(.*\\)\\'" line))
        (push (cmacs-brigade-agent--parse-scalar (match-string 1 line)) items))
       ((string-match "\\`\\([A-Za-z0-9_-]+\\)[ \t]*:[ \t]*\\(.*\\)\\'" line)
        (when key
          (push (cons key (if items (nreverse items)
                            (cdr (assq :pending out))))
                out)
          (setq out (assq-delete-all :pending out)))
        (setq key (intern (match-string 1 line))
              items nil)
        (let ((v (match-string 2 line)))
          (if (string-empty-p (string-trim v))
              ;; value is on the following indented lines
              (push (cons :pending nil) out)
            (push (cons key (cmacs-brigade-agent--parse-scalar v)) out)
            (setq key nil))))))
    (when key
      (push (cons key (nreverse items)) out))
    (setq out (assq-delete-all :pending out))
    (nreverse out)))


;;;; Definitions

(defun cmacs-brigade-agent--from-text (text file)
  "Parse an agent definition from TEXT, originating in FILE."
  (let* ((split (cmacs-brigade-agent--split text))
         (fm (cmacs-brigade-agent--parse-frontmatter (car split)))
         (body (string-trim (cdr split)))
         (name (or (alist-get 'name fm)
                   ;; A file without frontmatter -- an imported
                   ;; ~/.claude/agents entry -- still has a usable name
                   ;; in its filename.  Rejecting it would make the
                   ;; import path advertise more than it delivers.
                   (and file (file-name-base file)))))
    (unless name
      (signal 'cmacs-brigade-agent-error (list "definition has no name" file)))
    (list :name (if (stringp name) (intern name) name)
          :description (alist-get 'description fm)
          :model (or (alist-get 'model fm) cmacs-brigade-default-model)
          :fallback-model (alist-get 'fallback-model fm)
          :tools (cmacs-brigade-agent--as-list (alist-get 'tools fm))
          :isolation (or (cmacs-brigade-agent--as-symbol
                          (alist-get 'isolation fm))
                         'none)
          :worker (or (cmacs-brigade-agent--as-symbol (alist-get 'worker fm))
                      'inproc)
          :budget-usd (or (alist-get 'budget-usd fm)
                          cmacs-brigade-default-budget-usd)
          :max-turns (or (alist-get 'max-turns fm)
                         cmacs-brigade-default-max-turns)
          :max-tokens (alist-get 'max-tokens fm)
          :emits (cmacs-brigade-agent--as-list (alist-get 'emits fm))
          :prompt body
          :file file
          ;; Everything the parser did not claim, so an unrecognised key
          ;; is available to whoever added it rather than discarded.
          :extra (cl-remove-if (lambda (c) (memq (car c) '(name description
                                                           model fallback-model
                                                           tools isolation worker
                                                           budget-usd max-turns
                                                           max-tokens emits)))
                               fm))))

(defun cmacs-brigade-agent--as-list (v)
  (cond ((null v) nil)
        ((listp v) v)
        (t (list v))))

(defun cmacs-brigade-agent--as-symbol (v)
  (cond ((null v) nil)
        ((symbolp v) v)
        ((stringp v) (intern v))
        (t v)))

(defun cmacs-brigade-agent-load-file (file)
  "Parse and register the agent defined in FILE.  Returns its name."
  (let* ((text (with-temp-buffer (insert-file-contents file) (buffer-string)))
         (def (cmacs-brigade-agent--from-text text file)))
    (apply #'cmacs-brigade-register-agent def)
    (plist-get def :name)))

;;;###autoload
(defun cmacs-brigade-agent-reload (&optional project-root)
  "Load every agent definition on `cmacs-brigade-agent-path'.

Later directories override earlier ones by name; PROJECT-ROOT's
definitions, if given, win over all of them.  Returns the list of names.

A definition that fails to parse is reported and skipped rather than
aborting the scan: one malformed file in a directory should not cost you
every other agent in it."
  (interactive)
  (let ((dirs (append cmacs-brigade-agent-path
                      (when project-root
                        (list (expand-file-name
                               cmacs-brigade-agent-project-dir project-root)))))
        (loaded nil))
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (f (directory-files dir t "\\.\\(md\\|markdown\\)\\'"))
          (condition-case err
              (push (cmacs-brigade-agent-load-file f) loaded)
            (error
             (message "cmacs-brigade: skipping %s: %s"
                      (file-name-nondirectory f)
                      (error-message-string err)))))))
    (when (called-interactively-p 'any)
      (message "cmacs-brigade: %d agents" (length (delete-dups loaded))))
    (nreverse (delete-dups loaded))))

(defun cmacs-brigade-agent-get (name)
  "Return the agent definition NAME, or nil.
NAME may be a symbol or a string."
  (cmacs-brigade-registry-get 'agent (if (stringp name) (intern name) name)))

(defun cmacs-brigade-agent-allowlist (agent)
  "Return AGENT's tool list as an allowlist string for the C gate."
  (let ((tools (plist-get agent :tools)))
    (if (null tools) ""
      (mapconcat (lambda (tv)
                   (cmacs-brigade-wire-name
                    (if (symbolp tv) (symbol-name tv) tv)))
                 tools ","))))


;;;; Deriving an agent
;;
;; A task or a schedule that names its own model, tools or budget needs
;; those to actually reach the runner.  The runtime record carries only
;; an agent *name* -- adding fields to it would mean a C change and an
;; ABI bump every time a new knob appears -- so instead the overrides are
;; baked into a derived agent registered under its own name, through the
;; same public registry a user would use.  The record then points at
;; that, and every path downstream works unchanged.

(defconst cmacs-brigade-agent-generic-prompt
  "You are running as part of a brigade task.  Do the work described
below, make the most reasonable choice when something is ambiguous rather
than stopping to ask, and finish with a short summary of what you did."
  "System prompt for a derived agent with no base definition.")

(defun cmacs-brigade-agent-base-name (name)
  "Return the definition NAME was derived from, or NAME itself.

What the UI should show: `researcher\=' rather than the internal
`researcher@b12c7a46\=' a per-task model override produces."
  (let ((def (cmacs-brigade-agent-get name)))
    (or (plist-get def :base) name)))

(defun cmacs-brigade-agent-derive (base-name suffix overrides &optional force)
  "Register an agent deriving from BASE-NAME with OVERRIDES, and return its name.

SUFFIX distinguishes it from its base and from other derivations.
OVERRIDES is a plist of :model, :tools, :budget-usd, :isolation and
:worker; a nil or absent value inherits from the base.

Returns BASE-NAME unchanged when there is nothing to override, so the
common case adds no registry entry and the dashboard shows the plain
name.  With FORCE, always registers a derivation -- what a schedule
wants, since it needs a definition of its own even when it names no
base agent and overrides nothing."
  (let* ((base (and base-name (cmacs-brigade-agent-get base-name)))
         (model (plist-get overrides :model))
         (tools (plist-get overrides :tools))
         (budget (plist-get overrides :budget-usd))
         (isolation (plist-get overrides :isolation))
         (worker (plist-get overrides :worker)))
    (when (and base-name (null base))
      (signal 'cmacs-brigade-agent-error
              (list (format "no agent definition named %s" base-name)
                    (format "known: %s"
                            (or (cmacs-brigade-registry-list 'agent) "none")))))
    (if (and (not force) (not (or model tools budget isolation worker)))
        ;; Nothing to override.  Returning the base name keeps the
        ;; registry free of one entry per task that changed nothing.
        (and base-name (if (stringp base-name) (intern base-name) base-name))
      (let ((name (intern (format "%s@%s" (or base-name "task") suffix))))
        (apply #'cmacs-brigade-register-agent
               (append
                (list :name name
                      :base (and base-name
                                 (if (stringp base-name)
                                     (intern base-name) base-name))
                      :prompt (or (plist-get base :prompt)
                                  cmacs-brigade-agent-generic-prompt)
                      :isolation (or isolation (plist-get base :isolation) 'none)
                      :description (format "derived from %s"
                                           (or base-name "no base")))
                (when-let* ((m (or model (plist-get base :model))))
                  (list :model m))
                (when-let* ((tl (or tools (plist-get base :tools))))
                  (list :tools tl))
                (when-let* ((b (or budget (plist-get base :budget-usd))))
                  (list :budget-usd b))
                (when-let* ((w (or worker (plist-get base :worker))))
                  (list :worker w))
                (when-let* ((mt (plist-get base :max-turns)))
                  (list :max-turns mt))
                (when-let* ((fm (plist-get base :fallback-model)))
                  (list :fallback-model fm))))
        name))))

(provide 'cmacs-brigade-agent-def)

;;; cmacs-brigade-agent-def.el ends here
