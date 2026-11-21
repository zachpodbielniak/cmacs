;;; cmacs-redact.el --- One redaction table for every model-facing surface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The activity journal has a rule set that says what must not be kept:
;; exclude this window, drop that title, rewrite account numbers, hash a
;; project name.  Until this file those rules protected the journal and
;; nothing else -- the same window title still reached a model through
;; the window list, the screen inventory, a screenshot, the clipboard.
;;
;; This file makes the journal's rule set the ONE policy for everything
;; a model is shown.  There is no second rule format and no second
;; matcher: every function here builds an event in the journal's own
;; shape and hands it to `cmacs-journal-filter-apply' (free text goes
;; through `cmacs-journal-filter-apply-text').  The rules come from
;; where they always did -- `cmacs-journal-default-filters',
;; `cmacs-journal-filters', and the YAML files in
;; `cmacs-journal-filter-files' -- and are loaded here on first use, so
;; they are in force whether or not `cmacs-journal-mode' is on.
;;
;; THE CONTRACT (other files only call these):
;;
;;   (cmacs-redact-window APP TITLE &optional PID)
;;       nil when the window must not be shown at all, else a cons
;;       (APP . TITLE) with replace/hash/drop applied; either half may
;;       be nil when dropped.
;;   (cmacs-redact-buffer-p BUFFER-OR-NAME)
;;       non-nil when the buffer must not be listed or read.
;;   (cmacs-redact-url URL)
;;       nil when excluded, else the URL, possibly rewritten.
;;   (cmacs-redact-text STRING)
;;       STRING with the free-text rules applied; never nil for a
;;       string, and "" stays "".
;;   (cmacs-redact-event PLIST)
;;       the general form: PLIST in the journal's fields; the filtered
;;       plist, or nil.
;;
;; THREE PROPERTIES THIS FILE KEEPS:
;;
;;   * FAIL CLOSED.  When the rule set is not usable (a YAML file that
;;     does not parse, an unknown key, an invalid regexp) a window, a
;;     buffer and a URL are all "excluded" and text becomes
;;     `cmacs-redact-withheld-text'.  A typo in a privacy rule must not
;;     become "show everything".
;;
;;   * NOTHING SAYS WHICH RULE MATCHED.  Not in a result, an error, a
;;     message or a log.  A refusal reads the same whatever caused it.
;;
;;   * CALLERS DO NOT DECIDE WHO IS ASKING.  They call; the policy in
;;     `cmacs-redact-active-p' decides whether the caller is
;;     model-facing.  When it is not, every function is the identity.
;;
;; WHO IS MODEL-FACING
;;
;; `cmacs-redact-mode' is on by default.  While it is on, the functions
;; act when any of these holds (each can be switched off in
;; `cmacs-redact-surfaces'):
;;
;;   tool    a brigade tool call is running -- inside the dynamic extent
;;           of `cmacs-brigade-call-tool' or
;;           `cmacs-brigade-call-tool-async', or while an asynchronous
;;           call has not delivered its result yet.  The second half
;;           matters: an async tool finishes in a process sentinel, far
;;           outside the call that started it, and that is exactly where
;;           OCR text or a clipboard entry gets redacted.
;;   rpc     `inhibit-interaction' is bound, which cmacs's RPC dispatch
;;           does around everything arriving over MCP, D-Bus, emacsctl
;;           and bacon.  Your own `emacsctl' from a terminal is in here
;;           too: over that channel you are indistinguishable from a
;;           program, and the program is assumed.
;;   prompt  the code composing a model prompt said so, with
;;           `cmacs-redact-as-model'.  `cmacs-ai-view' does.
;;
;; Otherwise -- a command you ran, your own Lisp -- nothing is redacted:
;; these rules are about what leaves for a model, not about what you may
;; see on your own machine.  The one deliberate imprecision: while an
;; async tool call is in flight, a call to these functions from anywhere
;; is treated as the tool's, because a sentinel cannot be told from a
;; timer.  It errs toward redacting, for a few seconds.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-journal-filter)
;; For the event shapes: a buffer is described to the rules by the same
;; function that describes it to the journal, so a rule written for one
;; matches in the other.  Loading the journal records nothing -- its
;; mode stays off.
(require 'cmacs-journal)

(declare-function gowl-list-clients "cmacs-gowl.c" ())
(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-client-pid "cmacs-gowl.c" (client))
(declare-function gowl-client-sticky-p "cmacs-gowl.c" (client))
(declare-function gowl-focused-client "cmacs-gowl.c" ())
(declare-function gowl-list-monitors "cmacs-gowl.c" ())
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function cmacs-gsurf--mcp-target "cmacs-gsurf" (&optional name))

(defgroup cmacs-redact nil
  "One redaction table for everything a model is shown."
  :group 'cmacs
  :prefix "cmacs-redact-")

;;;; Configuration

(defcustom cmacs-redact-surfaces '(tool rpc prompt)
  "Which callers `cmacs-redact-mode' treats as model-facing.

A list of symbols:

  `tool'    brigade tool calls, from any agent or MCP client, for as
            long as the call runs (an asynchronous one until it has
            delivered its result).
  `rpc'     everything arriving over cmacs's RPC dispatch (MCP, D-Bus,
            emacsctl, bacon), told by `inhibit-interaction'.
  `prompt'  text composed into a model prompt by code that says so with
            `cmacs-redact-as-model' -- the screen inventory of
            `cmacs-ai-view', which rides every chat turn.

Removing a symbol stops redaction for that kind of caller and nothing
else.  Removing all three is the same as turning the mode off."
  :type '(set (const :tag "Brigade tool calls" tool)
              (const :tag "RPC dispatch (MCP, D-Bus, emacsctl, bacon)" rpc)
              (const :tag "Composed model prompts" prompt)))

(defcustom cmacs-redact-text-field-rules t
  "Non-nil means rules written for a field also apply to free text.

Free text -- a clipboard entry, text read off the screen, a buffer
inlined into a prompt -- has no fields.  Rules that match on the `text'
field always apply to it.  With this non-nil, so does what every other
rule calls sensitive inside a field: each `replace' entry, and each
match regexp of a field the rule hashes, wherever it occurs in the
text.  So a rule that rewrites account numbers in window titles rewrites
them in a screenshot's text as well, without being written twice.

Set this to nil when a field rule is too broad to be searched for in
running text; then only `text' rules touch free text.  See
`cmacs-journal-filter-apply-text' for exactly what is applied."
  :type 'boolean)

(defcustom cmacs-redact-resolve-projects t
  "Non-nil means a buffer's project is looked up for the rules.

A rule may match on `project'.  Finding a buffer's project asks
`project-current', which looks at the filesystem, so it is done once per
buffer and directory and never for a remote one.  With this nil only a
project the journal already knows, or one read off a PARA path, is
used -- and a `project' rule may then miss a buffer it should hide."
  :type 'boolean)

(defcustom cmacs-redact-check-interval 2.0
  "Seconds between looks at whether a filter file changed.
The journal watches its filter files only while `cmacs-journal-mode' is
on; redaction works without it, so the files' times are compared at most
this often, when a redaction function runs."
  :type 'number)

(defconst cmacs-redact-withheld-text
  "[withheld: redaction rules failed to load]"
  "What `cmacs-redact-text' returns when there is no usable rule set.")

(defconst cmacs-redact-excluded-text
  "[withheld by your privacy rules]"
  "What `cmacs-redact-text' returns for text a rule excludes whole.")

(defconst cmacs-redact-capture-refusal
  "a window excluded by your privacy rules is visible; nothing was captured"
  "The one message every refused image capture carries.
The same words whatever was matched, so a refusal says nothing about
the rule set.")

;;;; Who is asking

(defvar cmacs-redact--as-model nil
  "Non-nil inside `cmacs-redact-as-model'.")

(defvar cmacs-redact--in-tool-call nil
  "Non-nil inside the dynamic extent of a brigade tool call.")

(defvar cmacs-redact--pending nil
  "Asynchronous tool calls that have not delivered a result yet.
A list of (TOKEN . START-TIME).  Non-empty means some agent is waiting
for output that will be produced in a sentinel or a timer, outside any
binding of `cmacs-redact--in-tool-call'.")

(defconst cmacs-redact--pending-max-age 900.0
  "Seconds after which a pending asynchronous call is forgotten.
`cmacs-brigade-call-tool-async' settles every call exactly once, timeout
included, so this is only the answer to a callback that was lost.")

(defmacro cmacs-redact-as-model (&rest body)
  "Run BODY as code composing something a model will read.
Inside BODY the redaction functions act (given `cmacs-redact-mode' and
the `prompt' surface) however BODY was reached -- including from a
command the user ran, which is how a chat turn is sent."
  (declare (indent 0) (debug t))
  `(let ((cmacs-redact--as-model t)) ,@body))

(defun cmacs-redact--pending-p ()
  "Non-nil while an asynchronous tool call is still in flight."
  (when cmacs-redact--pending
    (let ((oldest (- (float-time) cmacs-redact--pending-max-age)))
      (setq cmacs-redact--pending
            (cl-delete-if (lambda (entry) (< (cdr entry) oldest))
                          cmacs-redact--pending))))
  (and cmacs-redact--pending t))

(defun cmacs-redact--around-tool-call (function &rest args)
  "Around advice for `cmacs-brigade-call-tool': the call is an agent's."
  (let ((cmacs-redact--in-tool-call t))
    (apply function args)))

(defun cmacs-redact--around-async-tool-call (function wire-name json-args
                                                      callback &rest rest)
  "Around advice for `cmacs-brigade-call-tool-async'.
The call counts as in flight from now until CALLBACK is called, which
that function guarantees happens exactly once."
  (let* ((token (list wire-name))
         (wrapped
          (lambda (&rest results)
            (setq cmacs-redact--pending
                  (cl-delete token cmacs-redact--pending
                             :key #'car :test #'eq))
            (apply callback results))))
    (push (cons token (float-time)) cmacs-redact--pending)
    (let ((cmacs-redact--in-tool-call t))
      (apply function wire-name json-args wrapped rest))))

(with-eval-after-load 'cmacs-brigade-tools
  (advice-add 'cmacs-brigade-call-tool :around
              #'cmacs-redact--around-tool-call)
  (advice-add 'cmacs-brigade-call-tool-async :around
              #'cmacs-redact--around-async-tool-call))

;; Callers `require' this file inside the body that needs it.  The first
;; such body may be a tool handler, already running inside a call the
;; advice above was too late to wrap.  So look: when this file is being
;; loaded from inside a brigade tool call, count that call as in flight
;; for a while rather than let it be the one call that goes unredacted.
(let ((inside nil))
  (mapbacktrace
   (lambda (_evald function &rest _)
     (when (memq function '(cmacs-brigade-call-tool
                            cmacs-brigade-call-tool-async
                            cmacs-brigade--invoke))
       (setq inside t))))
  (when inside
    ;; Dated so that it lapses a minute from now.
    (push (cons (list 'load)
                (- (float-time) (- cmacs-redact--pending-max-age 60.0)))
          cmacs-redact--pending)))

;;;###autoload
(define-minor-mode cmacs-redact-mode
  "Apply the journal's privacy rules to everything a model is shown.

On by default.  While it is on, window titles, buffer names, file
names, URLs, clipboard entries and screen text pass through the rule set
of `cmacs-journal-filters' and `cmacs-journal-filter-files' before any
agent, MCP client or model prompt gets them; an excluded window or
buffer is not listed, cannot be read, and blocks a screenshot it would
appear in.  Your own commands are not affected -- see
`cmacs-redact-surfaces' for who counts as a model.

If the rules cannot be loaded, model-facing surfaces show nothing until
they can.  `cmacs-redact-test' shows what a model would be given of the
window or buffer you are looking at.

This is independent of `cmacs-journal-mode': the rules are the
journal's, but nothing is recorded by having this on."
  :global t
  :init-value t
  :group 'cmacs-redact)

(defun cmacs-redact-active-p ()
  "Non-nil when the current caller must be given redacted output.
See the commentary of cmacs-redact.el for the rule."
  (and cmacs-redact-mode
       (or (and cmacs-redact--as-model
                (memq 'prompt cmacs-redact-surfaces))
           (and (memq 'tool cmacs-redact-surfaces)
                (or cmacs-redact--in-tool-call
                    (cmacs-redact--pending-p)))
           (and (bound-and-true-p inhibit-interaction)
                (memq 'rpc cmacs-redact-surfaces)))
       t))

;;;; The rule set

(defvar cmacs-redact--last-check 0.0
  "When the filter files were last compared with what was loaded.")

(defvar cmacs-redact--session-key nil
  "A random key for `hash' actions when the journal has none loaded.
The journal's key is created when `cmacs-journal-mode' is first turned
on.  Without it a hashed field would be blanked; with this one it is
still a hash, stable for the life of this Emacs and meaningless outside
it.  Never written anywhere.")

(defun cmacs-redact--hash-key ()
  "The key `hash' actions use here: the journal's, else a session one."
  (or (and (stringp cmacs-journal-filter-hash-key)
           (not (string-empty-p cmacs-journal-filter-hash-key))
           cmacs-journal-filter-hash-key)
      cmacs-redact--session-key
      (setq cmacs-redact--session-key
            (secure-hash
             'sha256
             (concat
              (or (ignore-errors
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally "/dev/urandom"
                                                      nil 0 64)
                      (buffer-string)))
                  "")
              (format "%s%s%s" (emacs-pid) (current-time) (random)))))))

(defun cmacs-redact-ready-p ()
  "Non-nil when there is a rule set to redact under.

Loads the rules on first use, so they are in force without
`cmacs-journal-mode'; after that, notices a changed filter file at most
every `cmacs-redact-check-interval' seconds.  A rule set that failed to
load is not retried until a file changes or
`cmacs-journal-filters-reload' is run -- retrying on every call would
re-read a broken file thousands of times."
  (condition-case nil
      (cond
       ((and (not cmacs-journal-filter--loaded)
             (null cmacs-journal-filter--error))
        (setq cmacs-redact--last-check (float-time))
        (cmacs-journal-filters-reload))
       ((> (- (float-time) cmacs-redact--last-check)
           cmacs-redact-check-interval)
        (setq cmacs-redact--last-check (float-time))
        (cmacs-journal-filter-check)))
    (error nil))
  (cmacs-journal-filter-ready-p))

(defun cmacs-redact--apply (event)
  "EVENT through the rule set, unconditionally; nil when excluded.
Nil too when the rules are not usable."
  (and (cmacs-redact-ready-p)
       (let ((cmacs-journal-filter-hash-key (cmacs-redact--hash-key)))
         (cmacs-journal-filter-apply event))))

(defun cmacs-redact--string (value)
  "VALUE of a filtered field as a string, or nil."
  (cond ((null value) nil)
        ((stringp value) value)
        (t (format "%s" value))))

;;;; The contract

;;;###autoload
(defun cmacs-redact-event (plist)
  "Return PLIST as a model may be shown it, or nil when it is excluded.

PLIST uses the journal's filter fields: `:kind' `:app' `:title' `:pid'
`:tags' `:monitor' `:buffer' `:file' `:mode' `:project' `:url'
`:detail' (and `:text').  The result is a fresh plist with the `drop',
`replace' and `hash' actions of every matching rule applied.

Nil also when the rule set is not usable.  PLIST itself is returned when
the caller is not model-facing (`cmacs-redact-active-p')."
  (if (cmacs-redact-active-p)
      (cmacs-redact--apply plist)
    plist))

(defun cmacs-redact--emacs-frame-excluded-p (title)
  "Non-nil when TITLE names a frame of this Emacs showing a hidden buffer.
A frame of ours is one more window to the compositor, and its title is
usually the name of the buffer in it -- but the rules that hide that
buffer are written on its file or its mode, not on a window title."
  (cl-some
   (lambda (frame)
     (and (equal (frame-parameter frame 'name) title)
          (cl-some (lambda (window)
                     (null (cmacs-redact--buffer-event
                            (window-buffer window))))
                   (window-list frame 'no-minibuf))))
   (frame-list)))

;;;###autoload
(defun cmacs-redact-window (app title &optional pid)
  "Return (APP . TITLE) as a model may be shown that window, or nil.

APP is the window's app id, TITLE its title, PID its process when
known.  Nil means the window must not be shown at all -- not listed, not
focused by name, not captured.  Otherwise either half of the cons may
have been rewritten, hashed, or dropped (nil).

The window is put to the rules as the event the journal records for a
focused window (`:kind' `focus').  A window that is one of this Emacs's
own frames is also excluded when a buffer on that frame is."
  (if (not (cmacs-redact-active-p))
      (cons app title)
    (let ((event (cmacs-redact--apply
                  (list :kind 'focus :app app :title title
                        :pid (and (integerp pid) (> pid 0) pid)))))
      (and event
           (not (and (integerp pid) (= pid (emacs-pid)) (stringp title)
                     (cmacs-redact-ready-p)
                     (cmacs-redact--emacs-frame-excluded-p title)))
           (cons (cmacs-redact--string (plist-get event :app))
                 (cmacs-redact--string (plist-get event :title)))))))

(defun cmacs-redact--project (buffer)
  "The project name of BUFFER for the rules, or nil.
`cmacs-journal--buffer-project' does the lookup and keeps the answer per
buffer and directory, and refuses a remote directory; with
`cmacs-redact-resolve-projects' nil only what it already knows is used."
  (if cmacs-redact-resolve-projects
      (ignore-errors (cmacs-journal--buffer-project buffer))
    (let ((cached (buffer-local-value 'cmacs-journal--project buffer)))
      (and (consp cached) (cdr cached)))))

(defun cmacs-redact--buffer-raw-event (buffer)
  "The event describing live BUFFER to the rules, before any rule.

The journal's own description of the buffer (a gsurf buffer is a `url'
event, anything else a `buffer' event), with two additions the journal
has no use for: a Dired buffer's directory and an indirect buffer's base
file stand in as the `file', because a rule hiding a directory or a file
means every buffer that shows it."
  (let ((event (cmacs-journal--buffer-event buffer nil)))
    (with-current-buffer buffer
      (when (eq (plist-get event :kind) 'buffer)
        (unless (plist-get event :project)
          (setq event (plist-put event :project
                                 (cmacs-redact--project buffer))))
        (unless (plist-get event :file)
          (let ((file (or (and (buffer-base-buffer buffer)
                               (buffer-file-name (buffer-base-buffer buffer)))
                          (and (derived-mode-p 'dired-mode)
                               (stringp default-directory)
                               default-directory))))
            (when file
              (setq event (plist-put event :file
                                     (cmacs-journal--abbreviate
                                      (expand-file-name file)))))))))
    event))

(defun cmacs-redact--buffer-event (buffer)
  "Live BUFFER through the rule set, unconditionally; nil when excluded.
When a rule rewrote the page title of a web buffer, the same rewrite is
made in the buffer's name, which is where that title also appears."
  (let* ((raw (cmacs-redact--buffer-raw-event buffer))
         (event (cmacs-redact--apply raw)))
    (when event
      (let ((before (plist-get raw :title))
            (after (plist-get event :title))
            (name (plist-get event :buffer)))
        (when (and (stringp before) (not (string-empty-p before))
                   (stringp name)
                   (not (equal before after))
                   (string-search before name))
          (setq event
                (plist-put event :buffer
                           (string-replace before
                                           (if (stringp after) after "")
                                           name)))))
      event)))

;;;###autoload
(defun cmacs-redact-buffer (buffer-or-name)
  "Return the description of BUFFER-OR-NAME a model may be shown, or nil.

The result is a plist in the journal's fields -- `:buffer' `:file'
`:mode' `:project', and for a web buffer `:url' and `:title' -- with
every matching rule applied, so a caller listing buffers prints these
and not the buffer's real name and file.  Nil means the buffer is
excluded (or the rules are not usable, or there is no such buffer).

When the caller is not model-facing the description is returned
untouched."
  (let ((buffer (get-buffer buffer-or-name)))
    (and (buffer-live-p buffer)
         (if (cmacs-redact-active-p)
             (cmacs-redact--buffer-event buffer)
           (cmacs-redact--buffer-raw-event buffer)))))

;;;###autoload
(defun cmacs-redact-buffer-p (buffer-or-name)
  "Non-nil when BUFFER-OR-NAME must not be listed for, or read by, a model.

BUFFER-OR-NAME is a buffer or a buffer name.  It is judged by its name,
file (a Dired buffer's directory, an indirect buffer's base file), major
mode and project, and a web buffer by its URL and title.  A name with no
live buffer is judged by the name alone, so asking for an excluded
buffer by name is refused whether or not it exists.

Non-nil too when the rule set is not usable.  Always nil when the caller
is not model-facing."
  (and (cmacs-redact-active-p)
       (let ((buffer (get-buffer buffer-or-name)))
         (null
          (cond
           ((buffer-live-p buffer) (cmacs-redact--buffer-event buffer))
           ((stringp buffer-or-name)
            (cmacs-redact--apply (list :kind 'buffer :app "emacs"
                                       :buffer buffer-or-name)))
           ;; A killed buffer object: nothing to show either way.
           (t nil))))))

;;;###autoload
(defun cmacs-redact-file-p (file)
  "Non-nil when FILE must not be read for a model.

A buffer visiting FILE decides, with everything known about it.  With no
such buffer the file is judged by its name -- as given and, for a local
file, with symbolic links resolved, so a link into a hidden directory is
as hidden as the directory.  Non-nil too when the rules are not usable;
always nil when the caller is not model-facing."
  (and (cmacs-redact-active-p)
       (stringp file)
       (let* ((path (expand-file-name file))
              (true (and (not (file-remote-p path))
                         (ignore-errors (file-truename path))))
              (names (delete-dups (delq nil (list path true)))))
         (or (not (cmacs-redact-ready-p))
             (cl-some
              (lambda (name)
                (let ((buffer (get-file-buffer name)))
                  (null
                   (if (buffer-live-p buffer)
                       (cmacs-redact--buffer-event buffer)
                     (let ((para (cmacs-journal--para-project name)))
                       (cmacs-redact--apply
                        (list :kind 'buffer :app "emacs"
                              :buffer (file-name-nondirectory name)
                              :file (cmacs-journal--abbreviate name)
                              :project (car para)
                              :detail (and para
                                           (concat "para:" (cdr para))))))))))
              names)))))

;;;###autoload
(defun cmacs-redact-file (file)
  "Return the name of FILE as a model may be shown it, or nil.

For LISTING files -- a row of recent files, of notes, of bookmarks --
where `cmacs-redact-file-p' is for reading one.  FILE is judged by its
name alone: no buffer is consulted and the disk is never touched, so
this is safe to call thousands of times from a snapshot and gives the
same answer for the same name under the same rules.  (The price: a
symbolic link into a hidden directory is not seen through here.  Reading
it still is refused, by `cmacs-redact-file-p'.)

Nil means the file is excluded, or a rule dropped its name, or the rules
are not usable.  Otherwise FILE itself when no rule touched it, else the
rewritten name.  FILE itself when the caller is not model-facing."
  (cond
   ((not (cmacs-redact-active-p)) file)
   ((not (stringp file)) nil)
   (t
    (let* ((name (cmacs-journal--abbreviate file))
           (para (cmacs-journal--para-project file))
           (event (cmacs-redact--apply
                   (list :kind 'buffer :app "emacs"
                         :buffer (file-name-nondirectory name)
                         :file name
                         :project (car para)
                         :detail (and para (concat "para:" (cdr para))))))
           (shown (plist-get event :file)))
      (cond ((null event) nil)
            ((equal shown name) file)
            (t (cmacs-redact--string shown)))))))

;;;###autoload
(defun cmacs-redact-buffer-name (name)
  "Return buffer NAME as a model may be shown it, or nil when excluded.
A live buffer of that name is judged with everything known about it, as
`cmacs-redact-buffer' does; a name with no buffer by the name alone.
Nil too when a rule dropped the name or the rules are not usable.  NAME
itself when the caller is not model-facing."
  (cond
   ((not (cmacs-redact-active-p)) name)
   ((not (stringp name)) nil)
   (t
    (let* ((buffer (get-buffer name))
           (event (if (buffer-live-p buffer)
                      (cmacs-redact--buffer-event buffer)
                    (cmacs-redact--apply (list :kind 'buffer :app "emacs"
                                               :buffer name)))))
      (cmacs-redact--string (plist-get event :buffer))))))

(defvar cmacs-redact--rules-seen nil
  "The rule set `cmacs-redact-generation' last looked at, held by `eq'.")

(defvar cmacs-redact--rules-count 0
  "How many different rule sets `cmacs-redact-generation' has seen.")

(defun cmacs-redact-generation ()
  "A value that changes (under `equal') when redacted output could.

For a cache of something already redacted: which rule set is loaded,
whether it is usable, and the options that change what the rules do.  It
says nothing about the things being redacted -- that part of the key is
the caller's.

The rule set is told apart by identity, not by a hash of its contents:
every reload builds a new list, and `sxhash-equal' stops looking a few
levels down, which is above where one rule's regexp differs from
another's.  The list is kept referenced here so its address cannot be
given to a later one.  Only a counter reaches the caller, so a cache key
never holds the rules themselves."
  (let ((ready (and (cmacs-redact-ready-p) t)))
    (unless (eq cmacs-redact--rules-seen cmacs-journal-filter--rules)
      (setq cmacs-redact--rules-seen cmacs-journal-filter--rules
            cmacs-redact--rules-count (1+ cmacs-redact--rules-count)))
    (list ready
          cmacs-redact--rules-count
          cmacs-journal-filter-case-fold
          cmacs-redact-text-field-rules
          (sxhash-equal (cmacs-redact--hash-key)))))

;;;###autoload
(defun cmacs-redact-url (url)
  "Return URL as a model may be shown it, or nil when it is excluded.
The URL is put to the rules as a `url' event.  A rule that drops the URL
field excludes it as far as the caller can tell.  Nil too when the rules
are not usable; URL itself when the caller is not model-facing."
  (cond
   ((not (cmacs-redact-active-p)) url)
   ((not (stringp url)) nil)
   (t (let ((event (cmacs-redact--apply (list :kind 'url :url url))))
        (cmacs-redact--string (plist-get event :url))))))

;;;###autoload
(defun cmacs-redact-text (string)
  "Return STRING as a model may be shown it.

For free text: a clipboard entry, text read off the screen, a buffer
inlined into a prompt.  Applied to it are

  * every rule matching on the `text' field, with all four actions
    (`exclude' gives `cmacs-redact-excluded-text', `drop' the empty
    string); and
  * with `cmacs-redact-text-field-rules', what the other rules call
    sensitive inside a field: each `replace' entry whatever its field,
    and each match regexp of a field that rule hashes.

A string is always returned for a string: the empty string for the
empty string, `cmacs-redact-withheld-text' when the rule set is not
usable.  STRING itself when the caller is not model-facing, or when it
is not a string."
  (cond
   ((not (stringp string)) string)
   ((string-empty-p string) string)
   ((not (cmacs-redact-active-p)) string)
   ((not (cmacs-redact-ready-p)) cmacs-redact-withheld-text)
   (t
    (let* ((cmacs-journal-filter-hash-key (cmacs-redact--hash-key))
           (out (cmacs-journal-filter-apply-text
                 string cmacs-redact-text-field-rules)))
      (cond ((stringp out) out)
            ((eq out 'excluded) cmacs-redact-excluded-text)
            (t cmacs-redact-withheld-text))))))

;;;; What is on screen, for captures

(defun cmacs-redact--visible-buffer-excluded-p (&optional frame)
  "Non-nil when a window of FRAME (default: any visible frame) shows a
buffer the rules exclude."
  (cl-some (lambda (f)
             (cl-some (lambda (window)
                        (null (cmacs-redact--buffer-event
                               (window-buffer window))))
                      (window-list f 'no-minibuf)))
           (if frame (list frame) (visible-frame-list))))

(defun cmacs-redact--shown-tags ()
  "The union of the tags the monitors are showing, or nil when unknown."
  (ignore-errors
    (let ((mask 0) (known nil))
      (dolist (monitor (gowl-list-monitors))
        (let ((tags (alist-get 'tags (gowl-monitor-info monitor))))
          (when (integerp tags)
            (setq mask (logior mask tags) known t))))
      (and known mask))))

(defun cmacs-redact--client-excluded-p (client)
  "Non-nil when gowl CLIENT is a window the rules exclude.
Non-nil too when CLIENT cannot be read: an unknown window is not shown."
  (condition-case nil
      (let* ((info (gowl-client-info client))
             (pid (and (fboundp 'gowl-client-pid) (gowl-client-pid client))))
        (if (and (integerp pid) (= pid (emacs-pid)))
            ;; One of our own frames: it shows buffers, judged as such.
            (cmacs-redact--visible-buffer-excluded-p)
          (null (cmacs-redact--apply
                 (list :kind 'focus
                       :app (alist-get 'app-id info)
                       :title (alist-get 'title info)
                       :pid (and (integerp pid) (> pid 0) pid))))))
    (error t)))

(defun cmacs-redact--desktop-excluded-p ()
  "Non-nil when something on screen right now is excluded by the rules.
Windows on a tag no monitor is showing are not on screen.  When the
shown tags cannot be read, every window counts as on screen."
  (or (cmacs-redact--visible-buffer-excluded-p)
      (and (fboundp 'gowl-list-clients)
           (let ((shown (cmacs-redact--shown-tags)))
             (cl-some
              (lambda (client)
                (let ((tags (ignore-errors
                              (alist-get 'tags (gowl-client-info client)))))
                  (and (or (null shown)
                           (not (integerp tags))
                           (/= 0 (logand tags shown))
                           (and (fboundp 'gowl-client-sticky-p)
                                (ignore-errors
                                  (gowl-client-sticky-p client))))
                       (cmacs-redact--client-excluded-p client))))
              (ignore-errors (gowl-list-clients)))))))

(defun cmacs-redact--video-buffers (handle)
  "The live buffers a cmacs-video stream HANDLE is playing in."
  (cl-remove-if-not
   (lambda (buffer)
     (or (equal (buffer-local-value 'cmacs-video--standalone-handle buffer)
                handle)
         (memql handle
                (flatten-tree
                 (buffer-local-value 'cmacs-video--streams buffer)))))
   (cl-remove-if-not
    (lambda (buffer)
      (or (local-variable-p 'cmacs-video--standalone-handle buffer)
          (local-variable-p 'cmacs-video--streams buffer)))
    (buffer-list))))

(defun cmacs-redact-capture-refused-p (what &optional target)
  "Non-nil when an image of WHAT must not be captured for a model.

An image cannot be rewritten the way a title can, so the answer is whole:
if something the rules exclude would be in the picture, there is no
picture.  WHAT is

  `desktop', `all'  everything on screen: the windows on a shown tag
                    and the buffers in visible frames.
  `window'          the focused window only.
  `client'          TARGET, a gowl client object: that window only.
  `frame'           this Emacs's visible frames (TARGET: one frame).
  `buffer'          TARGET, a buffer or its name.
  `gsurf'           TARGET, a gsurf buffer name, or nil for the one
                    the gsurf tools default to: its URL and title.
  `video'           TARGET, a cmacs-video handle: the buffers it plays
                    in, or -- when those are unknown -- anything on
                    screen.

Non-nil too when the rules are not usable, and for a WHAT this function
does not know.  Always nil when the caller is not model-facing."
  (and (cmacs-redact-active-p)
       (or (not (cmacs-redact-ready-p))
           (condition-case nil
               (pcase what
                 ((or 'desktop 'all) (cmacs-redact--desktop-excluded-p))
                 ('window
                  (let ((client (and (fboundp 'gowl-focused-client)
                                     (gowl-focused-client))))
                    (if client
                        (cmacs-redact--client-excluded-p client)
                      (cmacs-redact--visible-buffer-excluded-p
                       (selected-frame)))))
                 ('client
                  (or (null target)
                      (cmacs-redact--client-excluded-p target)))
                 ('frame (cmacs-redact--visible-buffer-excluded-p
                          (and (framep target) target)))
                 ('buffer
                  (let ((buffer (and target (get-buffer target))))
                    (or (not (buffer-live-p buffer))
                        (null (cmacs-redact--buffer-event buffer)))))
                 ('gsurf
                  (let ((buffer (and (fboundp 'cmacs-gsurf--mcp-target)
                                     (cmacs-gsurf--mcp-target target))))
                    (or (not (buffer-live-p buffer))
                        (null (cmacs-redact--buffer-event buffer)))))
                 ('video
                  (let ((buffers (cmacs-redact--video-buffers target)))
                    (if buffers
                        (cl-some (lambda (buffer)
                                   (null (cmacs-redact--buffer-event buffer)))
                                 buffers)
                      (cmacs-redact--desktop-excluded-p))))
                 (_ t))
             ;; Anything that went wrong deciding is a refusal.
             (error t)))))

;;;###autoload
(defun cmacs-redact-capture-guard (what &optional target)
  "Signal an error unless an image of WHAT may be captured for a model.
WHAT and TARGET are as in `cmacs-redact-capture-refused-p'.  The error
carries `cmacs-redact-capture-refusal' and nothing else.  Returns nil
when the capture may go ahead.

This is what the image-returning MCP tools call first: their handlers
are C that evaluates a Lisp form, and this is the first thing in it."
  (when (cmacs-redact-capture-refused-p what target)
    (error "%s" cmacs-redact-capture-refusal))
  nil)

;;;; Sensitive variables

;; A variable has no window, buffer or file for a rule to name, so the
;; journal's rules cannot say "not this one".  Two kinds of variable must
;; never be printed for a model all the same:
;;
;;   * the rule set itself.  "What a person excludes" is exactly what the
;;     rule files are kept out of a dotfiles repository to protect, and
;;     the journal's invariant is that nothing reveals the rule set or
;;     which rule matched.  `describe_variable
;;     cmacs-journal-filter--rules' did.
;;   * holders of secrets: an API key in an option, an auth-source lookup
;;     kept in a variable, the process environment.
;;
;; So there is a registry of such variables here, and every surface that
;; can print a variable's value asks it: the `describe_variable' and
;; `list_hooks' tools, the `variable://' resource (through
;; `cmacs-redact-resource-guard').  `eval' is not such a surface -- it is
;; privileged, and an agent granted it can read anything.

(defcustom cmacs-redact-default-sensitive-variables
  '(;; The rule set, as the user wrote it and as it is compiled.
    cmacs-journal-default-filters
    cmacs-journal-filters
    cmacs-journal-filter-files
    cmacs-journal-filter-hash-key
    "\\`cmacs-journal-filter--"
    ;; This file's own copies: the rule list held by `eq' for the
    ;; generation counter, the session hash key, and these two lists
    ;; (what a person calls sensitive is a fact about that person).
    cmacs-redact--rules-seen
    cmacs-redact--session-key
    cmacs-redact-default-sensitive-variables
    cmacs-redact-sensitive-variables
    ;; Secrets held in cmacs's own variables.
    cmacs-ai-search-api-key
    cmacs-ai-openai-compatible-endpoints ; :api-key in each entry
    cmacs-gnuseye--keys
    cmacs-gnuseye--secret-memo         ; auth-source answers, memoised
    ;; The environment is where provider keys live (ANTHROPIC_API_KEY,
    ;; BRAVE_API_KEY, ...).
    process-environment
    initial-environment
    ;; auth-source and its caches.
    auth-sources
    "\\`auth-source-.*cache"
    password-data
    ;; And by the shape of the name, for everything not listed.
    "api[-_]?keys?\\(?:\\'\\|-\\)"
    "passw\\(?:or\\)?d"
    "secret"
    "credential"
    "\\(?:access\\|auth\\|bearer\\|refresh\\)[-_]token")
  "Variables shipped as never printed for a model.

A list whose elements are symbols (that variable) and strings (a regexp
matched, case-sensitively, against a variable's name).  A variable is
sensitive when it or the variable it is an alias of is listed here or in
`cmacs-redact-sensitive-variables'; see `cmacs-redact-variable-p' for
what follows from that.

Put your own in `cmacs-redact-sensitive-variables' and leave this list
to the shipped defaults, so that a later version's additions reach you."
  :type '(repeat (choice (symbol :tag "Variable")
                         (regexp :tag "Name regexp"))))

(defcustom cmacs-redact-sensitive-variables nil
  "Your own variables that must never be printed for a model.

Same form as `cmacs-redact-default-sensitive-variables', and consulted
together with it: symbols, and regexps matched against variable names.

  (setq cmacs-redact-sensitive-variables
        \\='(my-work-vpn-settings \"\\\\`my-private-\"))

A subsystem that keeps a secret in a variable adds it with `add-to-list'.
An entry that is neither a symbol nor a valid regexp makes EVERY
variable sensitive until it is fixed: a typo here must not become \"show
everything\"."
  :type '(repeat (choice (symbol :tag "Variable")
                         (regexp :tag "Name regexp"))))

(defconst cmacs-redact-variable-refusal
  "This variable is withheld by your privacy rules"
  "The one answer every surface gives for a sensitive variable.
The same words for a variable that is bound, void, or does not exist,
so the answer says nothing about what the session holds.")

;;;###autoload
(defun cmacs-redact-sensitive-variable-p (symbol)
  "Non-nil when SYMBOL is a variable that must not be printed for a model.

SYMBOL is a symbol or a variable name (a string; it is never interned).
It is sensitive when its name, or the name of the variable it is an
alias of, is listed in `cmacs-redact-default-sensitive-variables' or
`cmacs-redact-sensitive-variables'.

This is the registry alone: it does not ask who is calling.  Surfaces
call `cmacs-redact-variable-p', which does.  Non-nil too when a list
holds something that is neither a symbol nor a valid regexp."
  (let* ((name (cond ((stringp symbol) symbol)
                     ((symbolp symbol) (symbol-name symbol))))
         (sym (cond ((stringp symbol) (intern-soft symbol))
                    ((symbolp symbol) symbol)))
         ;; An alias is as sensitive as what it names.  A cyclic alias
         ;; chain signals; it is then judged by its own name.
         (target (and sym (ignore-errors (indirect-variable sym))))
         (names (delete-dups
                 (delq nil (list name (and target (symbolp target)
                                           (symbol-name target))))))
         (case-fold-search nil))
    (and
     names
     (condition-case nil
         (cl-some
          (lambda (entry)
            (cond
             ((null entry) nil)
             ((symbolp entry) (member (symbol-name entry) names))
             ((stringp entry)
              (cl-some (lambda (n) (string-match-p entry n)) names))
             ;; Fail closed on an entry of an unknown kind.
             (t t)))
          (append cmacs-redact-default-sensitive-variables
                  cmacs-redact-sensitive-variables))
       ;; An invalid regexp, a list that is not a list: fail closed.
       (error t))
     t)))

;;;###autoload
(defun cmacs-redact-variable-p (symbol)
  "Non-nil when variable SYMBOL must not be printed for a model.

SYMBOL is a symbol or a variable name.  Non-nil when the caller is
model-facing (`cmacs-redact-active-p') and the variable is sensitive
\(`cmacs-redact-sensitive-variable-p').  A surface that gets non-nil
answers with `cmacs-redact-variable-refusal' and nothing else: not the
value, not the documentation, not whether the variable is bound.

Always nil when the caller is not model-facing."
  (and (cmacs-redact-active-p)
       (cmacs-redact-sensitive-variable-p symbol)))

;;;###autoload
(defun cmacs-redact-variable-guard (symbol)
  "Signal an error unless variable SYMBOL may be printed for a model.
SYMBOL is a symbol or a variable name.  The error carries
`cmacs-redact-variable-refusal' and nothing else.  Returns nil when the
variable may be printed.  For handlers written in C, whose Lisp form
begins with this the way an image handler's begins with
`cmacs-redact-capture-guard'."
  (when (cmacs-redact-variable-p symbol)
    (error "%s" cmacs-redact-variable-refusal))
  nil)

;;;###autoload
(defun cmacs-redact-resource-guard (kind &optional name)
  "Signal an error unless the MCP resource KIND://NAME may be read.

KIND is a string: \"buffer\" (NAME a buffer name), \"file\" (a path),
\"process\" (a process name, judged by its buffer), \"messages\" (the
*Messages* buffer) or \"variable\".  A variable has no window, buffer
or file for a rule to name; it is refused when it is one of the
sensitive variables (`cmacs-redact-variable-p'), and what any other
variable holds is redacted as free text by `cmacs-redact-text'.

Returns nil when the read may go ahead.  The error says the resource is
withheld and never why."
  (when (and (cmacs-redact-active-p)
             (or (not (cmacs-redact-ready-p))
                 (pcase kind
                   ("buffer" (cmacs-redact-buffer-p (or name "")))
                   ("file" (cmacs-redact-file-p (or name "")))
                   ("messages" (cmacs-redact-buffer-p "*Messages*"))
                   ("process"
                    (let* ((process (and name (get-process name)))
                           (buffer (and process (process-buffer process))))
                      (and (buffer-live-p buffer)
                           (cmacs-redact-buffer-p buffer))))
                   ("variable" (cmacs-redact-variable-p (or name "")))
                   (_ t))))
    (error "This resource is withheld by your privacy rules"))
  nil)

;;;; Trying it out

(defun cmacs-redact--describe (event)
  "EVENT as lines of `field: value'."
  (mapconcat
   (lambda (field)
     (let ((value (plist-get event field)))
       (if value
           (format "  %-8s %s\n" (substring (symbol-name field) 1)
                   (cmacs-journal-filter--string value))
         "")))
   cmacs-journal-filter-fields ""))

;;;###autoload
(defun cmacs-redact-test (event &optional text)
  "Show what a model would be given of EVENT right now.

Interactively, EVENT is what you are looking at -- the focused window
under gowl, else the selected buffer.  With a prefix argument, type the
fields of a sample instead, and optionally a line of free TEXT to see
what `cmacs-redact-text' makes of it.

The answer is what an agent, an MCP client or a chat prompt would get,
whatever `cmacs-redact-surfaces' says about this command.  It shows the
result and never which rule produced it."
  (interactive
   (if current-prefix-arg
       (let (event)
         (dolist (field '(:kind :app :title :url :file :buffer :project))
           (let ((value (read-string
                         (format "%s (empty for none): "
                                 (substring (symbol-name field) 1)))))
             (unless (string-empty-p value)
               (setq event (plist-put event field value)))))
         (list event
               (let ((text (read-string "Free text (empty for none): ")))
                 (and (not (string-empty-p text)) text))))
     (list (let ((event (cmacs-journal-current-event)))
             ;; The selected buffer, described the way a buffer listing
             ;; would be (project, Dired directory), not just the way
             ;; the journal would record it.
             (if (memq (plist-get event :kind) '(buffer url))
                 (cmacs-redact--buffer-raw-event
                  (cmacs-journal--selected-buffer))
               event)))))
  (let* ((ready (cmacs-redact-ready-p))
         (shown (and ready (cmacs-redact--apply event)))
         (text-shown (and text
                          (let ((cmacs-redact-mode t)
                                (cmacs-redact-surfaces '(prompt)))
                            (cmacs-redact-as-model
                              (cmacs-redact-text text))))))
    (with-help-window "*cmacs-redact-test*"
      (princ (format "Redaction is %s.\n\n"
                     (cond ((not cmacs-redact-mode)
                            "OFF (cmacs-redact-mode): a model is shown everything")
                           ((null cmacs-redact-surfaces)
                            "on, but no surface is selected (cmacs-redact-surfaces)")
                           (t "on"))))
      (princ "As it is:\n")
      (princ (cmacs-redact--describe event))
      (princ "\nWhat a model would be given:\n")
      (princ (cond
              ((not ready)
               (format "  (nothing: the rules are not loaded, so everything is withheld)\n  %s\n"
                       (or (cmacs-journal-filter-error) "")))
              ((null shown)
               "  (nothing: it is not listed, cannot be read, and blocks a screenshot)\n")
              (t (cmacs-redact--describe shown))))
      (when text
        (princ "\nThe text as it is:\n  ")
        (princ text)
        (princ "\nThe text a model would be given:\n  ")
        (princ text-shown)
        (princ "\n"))))
  nil)

(provide 'cmacs-redact)

;;; cmacs-redact.el ends here
