;;; cmacs-brigade-compose.el --- Composing a brigade task  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three ways to get a task, all landing in the same place.
;;
;; Writing one by hand meant knowing that a plan is an org file, where
;; plans live, which properties mean what, and that :MODEL: is spelled
;; "provider/model".  That is a lot to know before you can ask an agent
;; to do something, and it is why the dashboard mostly sat empty.
;;
;; So: a transient (`cmacs-brigade-compose') that shows every field with
;; its current value and lets you set them in any order, plus three ways
;; to arrive at it already filled in --
;;
;;   - `cmacs-brigade-compose-clone', from a task that already exists,
;;   - `cmacs-brigade-compose-quick', from a sentence you typed,
;;   - `cmacs-brigade-compose-voice', from a sentence you said.
;;
;; The last two hand what you wrote or said to a model and ask it to
;; propose the whole spec -- agent, provider, model, tools, budget.  The
;; result is *never* created directly: it fills the transient in and you
;; look at it first.  A misheard word is cheap to fix on screen and
;; expensive to fix after an agent has spent ten minutes acting on it.
;;
;; Nothing here is a second source of truth.  Creating writes an ordinary
;; org headline into an ordinary plan file through
;; `cmacs-brigade-plan-append-task' and adopts it, exactly as if you had
;; typed the headline yourself -- so a composed task is editable,
;; refilable, greppable and in git like every other one.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-plan)
(require 'cmacs-brigade-agent-def)
(require 'transient)
(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback &optional executor))
(declare-function cmacs-ai-list-models "cmacs-ai-stream.c" (&optional provider))
(declare-function cmacs-ai-providers "cmacs-ai-defuns.c" ())
(declare-function cmacs-brigade-start-task "cmacs-brigade-run" (task-id))
(declare-function cmacs-brigade-task-transition "cmacs-brigade-defuns.c"
                  (id state &optional reason))
(declare-function cmacs-brigade-dashboard-refresh "cmacs-brigade-dashboard" ())
(declare-function cmacs-brigade-voice-listen "cmacs-brigade-voice"
                  (label callback))
(declare-function cmacs-brigade-voice-available-p "cmacs-brigade-voice" ())
(declare-function cmacs-evil-setup-mode-map "cmacs-evil"
                  (map &optional mode states))

(defvar cmacs-ai-default-provider)

(defcustom cmacs-brigade-compose-author-provider 'claude-code
  "Provider asked to turn a plain-English request into a task spec.

Defaults to the local Claude Code CLI: the job is short, structured and
happens while you wait, and a CLI provider needs no API key configured
before the feature works at all."
  :type 'symbol
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-compose-author-model "sonnet"
  "Model used with `cmacs-brigade-compose-author-provider'.

Sonnet rather than a cheaper model on purpose: this call decides which
agent runs and with what tools, so a bad answer here costs far more than
the call itself."
  :type 'string
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-compose-author-timeout 120
  "Seconds to wait for a drafted spec before giving up on it.

A CLI provider that wedges would otherwise leave you with neither a menu
nor an error.  On expiry the request itself becomes the prompt and you
fill the rest in by hand."
  :type 'integer
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-compose-entry 'window
  "How `cmacs-brigade-compose-quick' asks what you want done.

`window' opens a small buffer at the bottom of the frame, submitted with
\\[cmacs-brigade-compose-entry-submit] -- which is what you want for
anything longer than a line, since a task description usually is.
`minibuffer' reads one line instead."
  :type '(choice (const :tag "Small window at the bottom" window)
                 (const :tag "One line in the minibuffer" minibuffer))
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-compose-entry-height 8
  "Height in lines of the compose entry window."
  :type 'integer
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-compose-plan-file nil
  "Plan file composed tasks are appended to.

nil means `compose.org' under `cmacs-brigade-plan-directory'.  One
predictable destination, on the same reasoning as an org capture target:
a task you dictated in a hurry is worth nothing if you cannot find it."
  :type '(choice (const :tag "compose.org in the plan directory" nil) file)
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-compose-start-immediately nil
  "Whether creating a task from the transient also starts it.

Off by default: the transient exists so you get a look at what is about
to run.  Turning this on makes RET mean go."
  :type 'boolean
  :group 'cmacs-brigade)


;;;; State
;;
;; One plist rather than transient's own argument parsing: several of
;; the values depend on each other (a model belongs to a provider), the
;; prompt is multi-line, and the whole thing has to be settable from
;; outside the menu when a clone or a model fills it in.

(defvar cmacs-brigade-compose--state nil
  "Plist of the task being composed.

Keys: :title :prompt :agent :provider :model :tools :budget :cwd :plan,
plus :source describing where it came from, for the header.")

(defun cmacs-brigade-compose--get (key)
  (plist-get cmacs-brigade-compose--state key))

(defun cmacs-brigade-compose--put (key value)
  "Set KEY to VALUE, removing it when VALUE is nil or empty."
  (if (or (null value) (equal value ""))
      (setq cmacs-brigade-compose--state
            (cmacs-brigade-compose--plist-delete
             cmacs-brigade-compose--state key))
    (setq cmacs-brigade-compose--state
          (plist-put cmacs-brigade-compose--state key value)))
  value)

(defun cmacs-brigade-compose--plist-delete (plist key)
  "PLIST without KEY.  Local so this file does not depend on org's copy."
  (let (out)
    (while plist
      (unless (eq (car plist) key)
        (setq out (plist-put out (car plist) (cadr plist))))
      (setq plist (cddr plist)))
    out))

(defun cmacs-brigade-compose--plan-file ()
  "The plan composed tasks go into."
  (or (cmacs-brigade-compose--get :plan)
      cmacs-brigade-compose-plan-file
      (expand-file-name "compose.org" cmacs-brigade-plan-directory)))


;;;; Reading a provider and a model
;;
;; Public because the dashboard's `m' wants exactly this, and because a
;; user config composing a task from Lisp should not have to reimplement
;; "which models does this provider have".

(defun cmacs-brigade-compose-providers ()
  "Every provider name cmacs can talk to, as strings."
  (if (fboundp 'cmacs-ai-providers)
      (mapcar #'symbol-name (cmacs-ai-providers))
    ;; A build without cmacs-ai still composes tasks; it just cannot ask
    ;; what providers exist, and a fixed list beats no completion.
    '("claude" "openai" "gemini" "grok" "ollama"
      "claude-code" "opencode" "claude-tmux")))

(defvar cmacs-brigade-compose--model-cache nil
  "Alist of PROVIDER symbol to its model list.

Model tables are static for CLI providers and near enough for the rest,
and the API providers cost a network round trip to ask -- which is not
something to repeat on every redisplay of a menu.")

(defun cmacs-brigade-compose-models (provider)
  "Return the models PROVIDER offers, as strings.  Cached, never signals."
  (let ((p (if (stringp provider) (intern provider) provider)))
    (or (cdr (assq p cmacs-brigade-compose--model-cache))
        (let ((models (and (fboundp 'cmacs-ai-list-models)
                           (ignore-errors
                             (mapcar (lambda (m) (format "%s" m))
                                     (cmacs-ai-list-models p))))))
          (when models
            (push (cons p models) cmacs-brigade-compose--model-cache))
          models))))

(defun cmacs-brigade-compose-read-model (&optional provider)
  "Read a provider and one of its models.  Returns \"provider/model\".

Returns nil if either is left empty, which is how you get back to
whatever the agent definition says.  Never returns a half-built
\"provider/\": the runner reads that as a model *name* on the default
provider, so the half-answer runs the wrong thing rather than nothing."
  (let* ((p (or provider
                (completing-read
                 "Provider (empty = agent default): "
                 (cmacs-brigade-compose-providers) nil nil
                 (and (boundp 'cmacs-ai-default-provider)
                      (format "%s" cmacs-ai-default-provider)))))
         (models (and p (not (string-empty-p p))
                      (cmacs-brigade-compose-models p))))
    (if (or (null p) (string-empty-p p))
        nil
      (let ((m (completing-read
                (format "Model for %s (empty = agent default): " p)
                models nil nil)))
        (if (string-empty-p m) nil (format "%s/%s" p m))))))

(defun cmacs-brigade-compose--model-string ()
  "The :MODEL: value for the composed state, or nil.

Only when both halves are known.  A provider with no model is completed
from that provider's own list rather than written half-formed -- which
is the shape a model's proposal usually arrives in."
  (let ((p (cmacs-brigade-compose--get :provider))
        (m (cmacs-brigade-compose--get :model)))
    (cond
     ((and p m) (format "%s/%s" p m))
     ;; A model with no provider is still meaningful: it pins the model
     ;; on the configured default provider, which is what a bare
     ;; "gpt-oss:20b" has always meant here.
     (m (format "%s" m))
     ((null p) nil)
     (t (when-let* ((first (car (cmacs-brigade-compose-models p))))
          (cmacs-brigade-compose--put :model first)
          (format "%s/%s" p first))))))


;;;; Turning the state into a task

(defun cmacs-brigade-compose-spec ()
  "The composed state as a spec for `cmacs-brigade-plan-append-task'."
  (list :title (or (cmacs-brigade-compose--get :title)
                   (cmacs-brigade-compose--summarize
                    (cmacs-brigade-compose--get :prompt)))
        :prompt (cmacs-brigade-compose--get :prompt)
        :agent (cmacs-brigade-compose--get :agent)
        :model (cmacs-brigade-compose--model-string)
        :budget (cmacs-brigade-compose--get :budget)
        :tools (cmacs-brigade-compose--get :tools)
        :cwd (cmacs-brigade-compose--get :cwd)))

(defun cmacs-brigade-compose--summarize (text)
  "A headline-length summary of TEXT."
  (let ((one (replace-regexp-in-string "[ \t\n]+" " " (string-trim (or text "")))))
    (cond ((string-empty-p one) "Untitled task")
          ((<= (length one) 60) one)
          (t (concat (substring one 0 57) "...")))))

(defun cmacs-brigade-compose-create (&optional start)
  "Create the composed task.  With START, queue and start it too.

Returns the new task id."
  (let ((prompt (cmacs-brigade-compose--get :prompt)))
    (when (or (null prompt) (string-empty-p (string-trim prompt)))
      (user-error "cmacs-brigade: a task needs a prompt -- press p"))
    (let* ((file (cmacs-brigade-compose--plan-file))
           (id (cmacs-brigade-plan-append-task
                file (cmacs-brigade-compose-spec))))
      (when start
        (cmacs-brigade-task-transition id 'queued)
        (cmacs-brigade-start-task id))
      (setq cmacs-brigade-compose--state nil)
      (when (fboundp 'cmacs-brigade-dashboard-refresh)
        (cmacs-brigade-dashboard-refresh))
      (message "cmacs-brigade: %s %s in %s"
               (if start "started" "created") id
               (file-name-nondirectory file))
      id)))


;;;; Filling it in from somewhere else

;;;###autoload
(defun cmacs-brigade-compose-set (spec)
  "Replace the composed state with SPEC, a plist, and show the transient.

The entry point for filling the menu in from your own code: everything
this file does to arrive at a pre-filled transient goes through here."
  (setq cmacs-brigade-compose--state (copy-sequence spec))
  ;; Through a timer rather than directly, because callers include
  ;; asynchronous callbacks that run inside a GLib dispatch -- where
  ;; `inhibit-interaction' is bound and re-entering the command loop is
  ;; exactly what must not happen.  A zero timer runs it from the
  ;; command loop instead, which is where a menu belongs.
  (run-at-time 0 nil #'cmacs-brigade-compose-show))

(defun cmacs-brigade-compose-show ()
  "Open the compose transient on whatever state is composed.

`transient-setup' rather than calling the prefix as a function: that is
the documented way in, and it is what keeps this callable from a timer
and from Lisp as well as from a key."
  (transient-setup 'cmacs-brigade-compose))

(defun cmacs-brigade-compose--from-record (record)
  "The composed state for a clone of RECORD, a runtime task plist."
  (let* ((id (plist-get record :id))
         (plan (plist-get record :plan))
         (entry (and plan id (cmacs-brigade-plan-read-task plan id)))
         (model (or (plist-get entry :model)
                    ;; Fall back to what the agent definition says, so a
                    ;; clone of a task that inherited its model still
                    ;; shows which model that was.
                    (plist-get (cmacs-brigade-agent-get
                                (cmacs-brigade-compose--base-agent record))
                               :model)))
         (split (and model (cmacs-brigade-compose--split model))))
    (list :title (format "Copy of %s"
                         (or (plist-get entry :title)
                             (plist-get record :title) id))
          :prompt (plist-get entry :prompt)
          ;; The base name, never the derived `researcher@b12c7a46' a
          ;; per-task override produced: cloning that would point the new
          ;; task at a definition belonging to the old one, and every
          ;; override would then be frozen where the transient cannot
          ;; reach it.
          :agent (cmacs-brigade-compose--base-agent record)
          :provider (car split)
          :model (cdr split)
          :tools (plist-get entry :tools)
          :budget (plist-get entry :budget)
          :cwd (plist-get entry :cwd)
          :plan plan
          :source (format "clone of %s" (or (plist-get record :id) "a task")))))

(defun cmacs-brigade-compose--base-agent (record)
  "RECORD's agent as written, not as derived."
  (when-let* ((a (plist-get record :agent)))
    (format "%s" (cmacs-brigade-agent-base-name
                  (if (stringp a) (intern a) a)))))

(defun cmacs-brigade-compose--split (model)
  "Split MODEL into a (PROVIDER . NAME) cons of strings.

A string with no slash is a model name with no provider, matching how
the runner reads :MODEL:."
  (if (string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" model)
      (cons (match-string 1 model) (match-string 2 model))
    (cons nil model)))

;;;###autoload
(defun cmacs-brigade-compose-clone (&optional record)
  "Compose a copy of RECORD as a new task, for tweaking before it runs.

Everything the original said is carried over -- agent, model, tools,
budget, working directory and the prompt itself -- and nothing it *did*
is: the copy gets its own id and starts as a draft.  Called from the
dashboard with the task under point."
  (interactive)
  (let ((r (or record
               (and (fboundp 'cmacs-brigade-dashboard--record-at-point)
                    (cmacs-brigade-dashboard--record-at-point)))))
    (unless r
      (user-error "cmacs-brigade: no task to clone"))
    (setq cmacs-brigade-compose--state (cmacs-brigade-compose--from-record r))
    (cmacs-brigade-compose-show)))


;;;; Asking a model to draft the spec

(defconst cmacs-brigade-compose--author-prompt
  "You turn a request into a definition for one AI agent task.

Reply with JSON only, no prose and no code fence, with these keys:
  title      a short headline, under 60 characters
  prompt     the instruction the agent runs -- write it as a standalone
             instruction, since the agent sees nothing but this
  agent      an agent name from the list given, or null
  provider   a provider name from the list given, or null
  model      a model name for that provider, or null
  tools      an array of tool names from the list given, or null
  budget     a spend ceiling in dollars as a number, or null for none
  directory  an absolute path the work belongs to, or null

Rules that matter:
- Use only names from the lists given.  If nothing fits, use null; do
  not invent an agent, a tool or a model that was not listed.
- The prompt is the whole brief.  Expand what the user said into
  something a stranger could act on, but do not add requirements they
  did not ask for.
- Prefer a coding CLI provider for work that edits files, and leave
  provider and model null when the request does not imply either.
- Say what to do, not how you decided."
  "System prompt used to turn a request into a task spec.")

(defun cmacs-brigade-compose--author-context (request)
  "The user turn for the authoring call about REQUEST."
  (let ((agents (mapcar #'symbol-name (cmacs-brigade-registry-list 'agent)))
        (tools (mapcar (lambda (n)
                         (cmacs-brigade-wire-name (symbol-name n)))
                       (cmacs-brigade-registry-list 'tool))))
    (format "Request: %s\n\nAvailable agents: %s\nAvailable tools: %s\n\
Available providers: %s\nCurrent directory: %s"
            request
            (if agents (string-join agents ", ") "none")
            (if tools (string-join tools ", ") "none")
            (string-join (cmacs-brigade-compose-providers) ", ")
            (abbreviate-file-name default-directory))))

(defun cmacs-brigade-compose--author-available-p ()
  "Whether a model can be asked to draft a spec in this build."
  (and (or (featurep 'cmacs-ai) (require 'cmacs-ai nil t))
       (fboundp 'cmacs-ai-make-session)
       (fboundp 'cmacs-ai-chat-stream)))

(defun cmacs-brigade-compose--author (request callback)
  "Ask a model to draft a spec for REQUEST, then call CALLBACK with it.

Asynchronous, because this is a CLI round trip by default and blocking
the editor for the twenty seconds it takes is not acceptable -- under
`emacs --gowl' the editor is the desktop session.

CALLBACK receives a state plist, exactly once.  Every way this can fail
-- no model in the build, no CLI on PATH, a reply that is not a spec, a
provider that never answers -- ends with the request itself as the
prompt, because a menu you still have to fill in beats an error and
beats waiting forever."
  (if (not (cmacs-brigade-compose--author-available-p))
      (funcall callback (cmacs-brigade-compose--fallback-state request))
    (let ((acc "") (pair nil) (timer nil) (done nil))
      (cl-labels
          ((finish (state why)
             ;; Once only: a stream that reports an error and then ends,
             ;; or ends just as the watchdog fires, must not fill the
             ;; menu in twice or free the session twice.
             (unless done
               (setq done t)
               (when timer (cancel-timer timer))
               (ignore-errors (cmacs-ai-free-session pair))
               (when why (message "cmacs-brigade: drafting failed: %s" why))
               (funcall callback state))))
        (condition-case err
            (progn
              (setq pair (cmacs-ai-make-session
                          cmacs-brigade-compose-author-provider
                          cmacs-brigade-compose-author-model
                          cmacs-brigade-compose--author-prompt))
              (message "cmacs-brigade: drafting with %s/%s..."
                       cmacs-brigade-compose-author-provider
                       cmacs-brigade-compose-author-model)
              ;; A CLI provider that never answers would otherwise leave
              ;; the request in limbo with no menu and no error -- and a
              ;; live session handle behind it.
              (setq timer
                    (run-at-time
                     cmacs-brigade-compose-author-timeout nil
                     (lambda ()
                       (finish (cmacs-brigade-compose--fallback-state request)
                               (format "no answer in %ds"
                                       cmacs-brigade-compose-author-timeout)))))
              (cmacs-ai-chat-stream
               (cdr pair) (cmacs-brigade-compose--author-context request)
               (lambda (payload)
                 (pcase (car-safe payload)
                   (:delta (setq acc (concat acc (or (cadr payload) ""))))
                   (:end
                    (let ((final (or (plist-get (cdr payload) :text) acc)))
                      (finish (or (cmacs-brigade-compose--state-from-json
                                   final request)
                                  (cmacs-brigade-compose--fallback-state
                                   request))
                              nil)))
                   (:error
                    (finish (cmacs-brigade-compose--fallback-state request)
                            (or (cadr payload) "unknown error")))
                   (_ nil)))))
          (error
           (finish (cmacs-brigade-compose--fallback-state request)
                   (error-message-string err))))))))

(defun cmacs-brigade-compose--fallback-state (request)
  "The state to compose when nothing drafted REQUEST for us."
  (list :title (cmacs-brigade-compose--summarize request)
        :prompt request
        :source "your words, undrafted"))

(defun cmacs-brigade-compose--state-from-json (answer request)
  "Read a composed state out of ANSWER, the model's reply about REQUEST.

Every name the model proposed is checked against what actually exists;
an agent or a tool it invented is dropped rather than written into a
plan that would then fail at start with a puzzling error."
  (when-let* ((spec (cmacs-brigade-parse-json-object answer)))
    (let* ((agent (cmacs-brigade-compose--known-agent (alist-get 'agent spec)))
           (tools (cmacs-brigade-compose--known-tools (alist-get 'tools spec)))
           (provider (cmacs-brigade-compose--known-provider
                      (alist-get 'provider spec)))
           (budget (alist-get 'budget spec))
           (dir (alist-get 'directory spec)))
      (list :title (or (alist-get 'title spec)
                       (cmacs-brigade-compose--summarize request))
            :prompt (or (alist-get 'prompt spec) request)
            :agent agent
            :provider provider
            ;; A model name is only meaningful with a provider to read
            ;; it against, and a model proposed for a provider that was
            ;; rejected is meaningless twice over.
            :model (and provider (alist-get 'model spec))
            :tools tools
            :budget (and (numberp budget) (> budget 0)
                         (format "%.2f" budget))
            :cwd (and (stringp dir) (file-directory-p (expand-file-name dir))
                      dir)
            :source "drafted from your request"))))

(defun cmacs-brigade-compose--known-agent (name)
  "NAME if an agent by that name is loaded, else nil."
  (when (and name (stringp name))
    (and (cmacs-brigade-agent-get (intern name)) name)))

(defun cmacs-brigade-compose--known-provider (name)
  "NAME if it is a provider cmacs can talk to, else nil."
  (when (and name (stringp name))
    (car (member name (cmacs-brigade-compose-providers)))))

(defun cmacs-brigade-compose--known-tools (names)
  "The subset of NAMES that are registered tools, as one string."
  (when (listp names)
    (let ((known (mapcar (lambda (n)
                           (cmacs-brigade-wire-name (symbol-name n)))
                         (cmacs-brigade-registry-list 'tool)))
          (kept nil))
      (dolist (n names)
        (let ((s (format "%s" n)))
          (when (member s known) (push s kept))))
      (when kept (string-join (nreverse kept) ", ")))))


;;;; Saying what you want: the small window at the bottom

(defvar cmacs-brigade-compose--entry-callback nil
  "What to call with the text of the entry buffer when it is submitted.")

(defvar cmacs-brigade-compose-entry-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-brigade-compose-entry-submit)
    (define-key map (kbd "C-c C-k") #'cmacs-brigade-compose-entry-abort)
    map)
  "Keymap for `cmacs-brigade-compose-entry-mode'.")

(define-derived-mode cmacs-brigade-compose-entry-mode text-mode "Brigade-Ask"
  "Describe a task in plain English, then \\[cmacs-brigade-compose-entry-submit].

Multi-line on purpose: a task worth handing to an agent rarely fits on
one line, and the minibuffer makes you pretend it does."
  (setq-local header-line-format
              (substitute-command-keys
               " Describe the task.  \\[cmacs-brigade-compose-entry-submit] \
to draft it, \\[cmacs-brigade-compose-entry-abort] to cancel."))
  ;; Under Evil this buffer is for typing prose, so start in insert
  ;; state rather than making the first keystroke a motion command.
  (when (and (fboundp 'evil-insert-state) (bound-and-true-p evil-mode))
    (evil-insert-state)))

(defun cmacs-brigade-compose-entry-submit ()
  "Take what is in the entry buffer and draft a task from it."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (callback cmacs-brigade-compose--entry-callback))
    (cmacs-brigade-compose-entry-abort)
    (if (string-empty-p text)
        (message "cmacs-brigade: nothing to do")
      (funcall callback text))))

(defun cmacs-brigade-compose-entry-abort ()
  "Close the entry window without doing anything."
  (interactive)
  (let ((buf (get-buffer "*brigade ask*")))
    (when-let* ((win (and buf (get-buffer-window buf))))
      (quit-window nil win))
    (when buf (kill-buffer buf))))

(defun cmacs-brigade-compose--read-request (callback)
  "Ask what should happen, then call CALLBACK with the answer."
  (pcase cmacs-brigade-compose-entry
    ('minibuffer
     (let ((text (string-trim (read-string "What should happen? "))))
       (if (string-empty-p text)
           (message "cmacs-brigade: nothing to do")
         (funcall callback text))))
    (_
     (let ((buf (get-buffer-create "*brigade ask*")))
       (with-current-buffer buf
         (erase-buffer)
         (cmacs-brigade-compose-entry-mode)
         (setq cmacs-brigade-compose--entry-callback callback))
       ;; A bottom side window, so it takes space from the frame rather
       ;; than splitting whatever you were reading.
       (select-window
        (display-buffer-in-side-window
         buf `((side . bottom)
               (window-height . ,cmacs-brigade-compose-entry-height)
               (preserve-size . (nil . t)))))))))

;;;###autoload
(defun cmacs-brigade-compose-quick ()
  "Describe a task in plain English and have one drafted for you.

Opens a small window (or the minibuffer, per
`cmacs-brigade-compose-entry'), hands what you wrote to a model, and
fills the compose transient in with what it proposes -- agent, provider,
model, tools and all.  Nothing is created until you say so."
  (interactive)
  (cmacs-brigade-compose--read-request
   (lambda (text)
     (cmacs-brigade-compose--author
      text #'cmacs-brigade-compose-set))))

;;;###autoload
(defun cmacs-brigade-compose-voice ()
  "Say what you want done and have a task drafted from it.

Records until `cmacs-brigade-voice-stop', transcribes, drafts, and shows
you the result in the compose transient.  It is never created straight
off a transcript: whisper is good, but the failure mode is an agent
spending real money on a misheard instruction."
  (interactive)
  (unless (and (require 'cmacs-brigade-voice nil t)
               (cmacs-brigade-voice-available-p))
    (user-error "cmacs-brigade: voice needs whisper and audio in this build"))
  (cmacs-brigade-voice-listen
   "Task"
   (lambda (text)
     (message "cmacs-brigade: heard %S" text)
     (cmacs-brigade-compose--author text #'cmacs-brigade-compose-set))))


;;;; The menu

(defun cmacs-brigade-compose--label (text key &optional value)
  "Menu label TEXT showing VALUE, or the state of KEY."
  (let ((v (or value (cmacs-brigade-compose--get key))))
    (if (and v (not (equal v "")))
        (format "%-12s %s" text
                (propertize (truncate-string-to-width (format "%s" v) 52)
                            'face 'transient-value))
      (format "%-12s %s" text
              (propertize "—" 'face 'transient-inactive-value)))))

(transient-define-suffix cmacs-brigade-compose-set-prompt ()
  "Set what the agent should do."
  :transient t
  :description (lambda ()
                 (cmacs-brigade-compose--label
                  "prompt" :prompt
                  (when-let* ((p (cmacs-brigade-compose--get :prompt)))
                    (car (split-string p "\n")))))
  (interactive)
  (cmacs-brigade-compose--put
   :prompt (read-string "Task: " (cmacs-brigade-compose--get :prompt))))

(transient-define-suffix cmacs-brigade-compose-set-title ()
  "Set the headline this task appears under."
  :transient t
  :description (lambda () (cmacs-brigade-compose--label "title" :title))
  (interactive)
  (cmacs-brigade-compose--put
   :title (read-string "Title: "
                       (or (cmacs-brigade-compose--get :title)
                           (cmacs-brigade-compose--summarize
                            (cmacs-brigade-compose--get :prompt))))))

(transient-define-suffix cmacs-brigade-compose-set-agent ()
  "Choose the agent definition to run."
  :transient t
  :description (lambda () (cmacs-brigade-compose--label "agent" :agent))
  (interactive)
  (let ((agents (mapcar #'symbol-name (cmacs-brigade-registry-list 'agent))))
    (unless agents
      (user-error "cmacs-brigade: no agent definitions loaded; \
M-x cmacs-brigade-agent-reload"))
    (cmacs-brigade-compose--put
     :agent (completing-read "Agent (empty = default): " agents nil nil))))

(transient-define-suffix cmacs-brigade-compose-set-model ()
  "Choose the provider and model, overriding the agent's own."
  :transient t
  :description
  (lambda ()
    (cmacs-brigade-compose--label
     "model" :model
     (let ((p (cmacs-brigade-compose--get :provider))
           (m (cmacs-brigade-compose--get :model)))
       (cond ((and p m) (format "%s/%s" p m))
             (m (format "%s" m))
             (p (format "%s/?" p))))))
  (interactive)
  (let ((full (cmacs-brigade-compose-read-model)))
    (if (null full)
        (progn (cmacs-brigade-compose--put :provider nil)
               (cmacs-brigade-compose--put :model nil))
      (let ((split (cmacs-brigade-compose--split full)))
        (cmacs-brigade-compose--put :provider (car split))
        (cmacs-brigade-compose--put :model (cdr split))))))

(transient-define-suffix cmacs-brigade-compose-set-tools ()
  "Choose which tools the agent may use."
  :transient t
  :description (lambda () (cmacs-brigade-compose--label "tools" :tools))
  (interactive)
  (let ((tools (completing-read-multiple
                "Tools (comma-separated, empty = agent default): "
                (mapcar (lambda (n)
                          (cmacs-brigade-wire-name (symbol-name n)))
                        (cmacs-brigade-registry-list 'tool)))))
    (cmacs-brigade-compose--put :tools (string-join tools ", "))))

(transient-define-suffix cmacs-brigade-compose-set-budget ()
  "Set a spend ceiling.  Empty or 0 means none."
  :transient t
  :description (lambda () (cmacs-brigade-compose--label "budget" :budget))
  (interactive)
  (cmacs-brigade-compose--put
   :budget (read-string "Budget in dollars (0 = no ceiling): "
                        (or (cmacs-brigade-compose--get :budget) "0.00"))))

(transient-define-suffix cmacs-brigade-compose-set-directory ()
  "Set the directory the work belongs to."
  :transient t
  :description (lambda () (cmacs-brigade-compose--label "directory" :cwd))
  (interactive)
  (cmacs-brigade-compose--put
   :cwd (let ((d (read-directory-name
                  "Run in (empty = wherever cmacs is): "
                  (or (cmacs-brigade-compose--get :cwd) default-directory)
                  nil t)))
          (and d (not (string-empty-p d)) (abbreviate-file-name d)))))

(transient-define-suffix cmacs-brigade-compose-set-plan ()
  "Choose which plan file the task is written into."
  :transient t
  :description (lambda ()
                 (cmacs-brigade-compose--label
                  "plan file" :plan
                  (file-name-nondirectory
                   (cmacs-brigade-compose--plan-file))))
  (interactive)
  (cmacs-brigade-compose--put
   :plan (read-file-name "Plan file: "
                         (file-name-as-directory cmacs-brigade-plan-directory)
                         nil nil
                         (file-name-nondirectory
                          (cmacs-brigade-compose--plan-file)))))

(transient-define-suffix cmacs-brigade-compose-redraft ()
  "Describe it again in plain English and re-draft everything."
  :description "re-draft from a description"
  (interactive)
  (cmacs-brigade-compose-quick))

(transient-define-suffix cmacs-brigade-compose-redraft-voice ()
  "Say it again and re-draft everything."
  :if (lambda () (and (fboundp 'cmacs-brigade-voice-available-p)
                      (cmacs-brigade-voice-available-p)))
  :description "re-draft from your voice"
  (interactive)
  (cmacs-brigade-compose-voice))

(transient-define-suffix cmacs-brigade-compose-reset ()
  "Clear everything composed so far."
  :transient t
  :description "reset"
  (interactive)
  (setq cmacs-brigade-compose--state nil)
  (message "cmacs-brigade: compose reset"))

(transient-define-suffix cmacs-brigade-compose-do-create ()
  "Create the task as a draft, without starting it."
  :description "create it"
  (interactive)
  (cmacs-brigade-compose-create cmacs-brigade-compose-start-immediately))

(transient-define-suffix cmacs-brigade-compose-do-start ()
  "Create the task and start it now."
  :description "create and start it"
  (interactive)
  (cmacs-brigade-compose-create t))

(transient-define-suffix cmacs-brigade-compose-do-edit ()
  "Create the task and open its headline, to edit the prompt in org."
  :description "create and open in the plan"
  (interactive)
  (let* ((file (cmacs-brigade-compose--plan-file))
         (id (cmacs-brigade-compose-create nil)))
    (find-file file)
    (when (fboundp 'org-id-goto) (ignore-errors (org-id-goto id)))))

(defun cmacs-brigade-compose--summary ()
  "Header saying what this is and where the draft came from."
  (concat
   (propertize "Compose a brigade task" 'face 'transient-heading)
   "\n "
   (let ((src (cmacs-brigade-compose--get :source)))
     (if src (propertize src 'face 'shadow)
       (propertize "empty -- press ! to describe it in words"
                   'face 'transient-inactive-value)))
   "\n "
   (format "into %s" (abbreviate-file-name
                      (cmacs-brigade-compose--plan-file)))))

;;;###autoload
(transient-define-prefix cmacs-brigade-compose ()
  "Compose one brigade task, then create it.

Every field shows what it is currently set to, and an unset field means
\"whatever the agent definition says\" rather than a hidden default.
Nothing is written to a plan until you choose to create it."
  [:description cmacs-brigade-compose--summary
   ["Task"
    ("p" cmacs-brigade-compose-set-prompt)
    ("T" cmacs-brigade-compose-set-title)]
   ["Who runs it"
    ("a" cmacs-brigade-compose-set-agent)
    ("m" cmacs-brigade-compose-set-model)
    ("t" cmacs-brigade-compose-set-tools)]]
  [["Where and how much"
    ("d" cmacs-brigade-compose-set-directory)
    ("b" cmacs-brigade-compose-set-budget)
    ("f" cmacs-brigade-compose-set-plan)]
   ["Draft"
    ("!" cmacs-brigade-compose-redraft)
    ("v" cmacs-brigade-compose-redraft-voice)
    ("r" cmacs-brigade-compose-reset)]]
  [["Create"
    ("RET" cmacs-brigade-compose-do-create)
    ("S" cmacs-brigade-compose-do-start)
    ("e" cmacs-brigade-compose-do-edit)]])

(provide 'cmacs-brigade-compose)

;;; cmacs-brigade-compose.el ends here
