;;; cmacs-journal.el --- Local, structured activity journal  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A journal of what had the user's attention: which window was focused,
;; which buffer was selected, which page a browser buffer showed, which
;; agent run finished.  Text only -- names and titles, never screen
;; contents, never keystrokes -- kept on this machine in plain files, and
;; OFF until `cmacs-journal-mode' is turned on.
;;
;; What is recorded is a SPAN, not a sample.  "Firefox, this title, from
;; 10:02:11 for 340 seconds" is one line; nothing polls.  A span opens
;; when something takes the focus and closes when something else does.
;;
;; The pipeline, and the two rules that shape it:
;;
;;   hook --> raw event --> FILTERS --> open span --> queue --> files
;;                                                        \--> LQL source
;;
;;   1. Hook functions are O(1), never signal and never do I/O.  They run
;;      on `cmacs-gowl-focus-changed-functions' and friends, where under
;;      `emacs --gowl' Emacs is the desktop: a hook that signals or waits
;;      there is a frozen session, not a missing journal line.  So a hook
;;      builds a small plist and returns.  Anything that touches the disk
;;      -- finding a buffer's project, writing the day's file -- happens
;;      in a timer.
;;
;;   2. Filters run BEFORE the open span.  The privacy rules in
;;      cmacs-journal-filter.el see the raw event and what comes out is
;;      all the journal ever holds.  An excluded event closes the open
;;      span and leaves a gap; there is no placeholder, no counter, and no
;;      note of which rule it was.
;;
;; Storage is JSON Lines, one file per day, in `cmacs-journal-directory'
;; (mode 0700, files 0600).  JSON Lines because the files are meant to be
;; read, grepped and deleted by the person they are about.
;;
;; Everything works without gowl.  On a plain pgtk or tty Emacs there are
;; no `focus' events; buffers, URLs and agent runs are still recorded.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'cmacs-journal-filter)

(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-client-pid "cmacs-gowl.c" (client))
(declare-function gowl-focused-client "cmacs-gowl.c" ())
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function gowl-locked-p "cmacs-gowl.c" ())
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-container-id "cmacs-gsurf-control.c" (buffer))
(declare-function cmacs-gsurf-containers "cmacs-gsurf-control.c" ())
(declare-function cmacs-brigade-task-get "cmacs-brigade-state.c" (id))
(declare-function cmacs-para-classify "cmacs-para" (file))
(declare-function cmacs-lql-available-p "cmacs-lql" ())
(declare-function cmacs-lql-define-source "cmacs-lql"
                  (name columns function &optional description))
(declare-function cmacs-lql-set-source-generation "cmacs-lql" (name function))
(declare-function cmacs-lql-set-source-redaction "cmacs-lql" (name redaction))
(declare-function project-root "project" (project))
(declare-function project-name "project" (project))
(declare-function org-read-date "org" (&rest args))

(defgroup cmacs-journal nil
  "A local, structured, text-only journal of what had your attention."
  :group 'cmacs
  :prefix "cmacs-journal-")

(defcustom cmacs-journal-directory
  (expand-file-name "cmacs/journal"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Directory the journal's day files live in.
Created with mode 0700; each `YYYY-MM-DD.jsonl' in it is 0600.  The
per-install secret that `hash' filters are keyed with sits beside them
in the file `secret', also 0600, and is never written into the journal."
  :type 'directory
  :group 'cmacs-journal)

(defcustom cmacs-journal-min-span 2
  "Spans shorter than this many seconds are dropped.
Passing through a window on the way to another is not attention."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-merge-gap 1.0
  "Rejoin a span reopened within this many seconds of closing.
Focus is briefly nowhere while a workspace switches, which would
otherwise cut one stretch of work into two lines."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-flush-idle 10
  "Seconds of Emacs idle time after which queued spans are written."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-flush-interval 300
  "Write queued spans at least this often, in seconds.
The idle timer alone is not enough under gowl: hours spent in another
window are hours in which Emacs is never idle-then-busy again."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-idle-threshold 300
  "Seconds without input after which an `idle' span starts, or nil.
Only applies while Emacs itself has the focus: Emacs cannot see input
going to another window, so it does not guess.  A locked session always
closes the open span, whatever this is."
  :type '(choice (const :tag "Never" nil) number)
  :group 'cmacs-journal)

(defcustom cmacs-journal-retention-days nil
  "Delete day files older than this many days, or nil to keep them all."
  :type '(choice (const :tag "Keep everything" nil) integer)
  :group 'cmacs-journal)

(defcustom cmacs-journal-lql-days 14
  "How many days of the journal the LQL `activity' source reads."
  :type 'integer
  :group 'cmacs-journal)

(defcustom cmacs-journal-expose-to-agents nil
  "Non-nil lets agents and remote callers read the journal.

When nil (the default) the LQL `activity' source and
`cmacs-journal-events' return no rows to a brigade tool call or to
anything arriving over cmacs's RPC surfaces (MCP, D-Bus, emacsctl,
bacon).  Your own interactive queries always see it.  See
`cmacs-journal-agent-context-p' for how the two are told apart, and for
what this is not: an agent allowed to evaluate Lisp or read files can
read the day files directly."
  :type 'boolean
  :group 'cmacs-journal)

(defcustom cmacs-journal-mode-line-recording " ●JRNL"
  "Mode-line text shown while the journal is recording."
  :type 'string
  :group 'cmacs-journal)

(defcustom cmacs-journal-mode-line-paused " ○jrnl"
  "Mode-line text shown while the journal is on but not recording."
  :type 'string
  :group 'cmacs-journal)

(declare-function cmacs-journal-attribute-contexts "cmacs-journal-report"
                  (events &optional initial no-split))
(declare-function cmacs-journal-context-at "cmacs-journal-report" (time))

(defvar cmacs-journal-time-function #'float-time
  "Function returning the current time in seconds.  Tests rebind it.")

(defconst cmacs-journal-fields
  '(:time :end :duration :kind :app :title :pid :tags :monitor :buffer
    :file :mode :project :url :detail)
  "Every field of a journal event, in the order it is written.")

;;;; State

(defvar cmacs-journal--open nil
  "The open span: a filtered event plist with :time and no :end, or nil.")

(defvar cmacs-journal--queue nil
  "Closed spans not yet written, newest first.")

(defvar cmacs-journal--generation 0
  "Bumped whenever the set of closed spans changes.")

(defvar cmacs-journal--paused nil
  "Why the journal is on but not recording: nil, `user' or `filter'.")

(defvar cmacs-journal--locked nil
  "Non-nil while the session is locked.")

(defvar cmacs-journal--external-focus nil
  "Non-nil while a window that is not this Emacs has the focus.
Buffer changes inside Emacs are not attention then.")

(defvar cmacs-journal--focus-id nil
  "The gowl id of the client the open `focus' span is for.")

(defvar cmacs-journal--pending nil
  "Start time of a buffer observation waiting for its timer, or nil.")

(defvar cmacs-journal--timers nil
  "Timers `cmacs-journal-mode' started.")

(defvar cmacs-journal--idle nil
  "Non-nil while an `idle' span is open.")

(defvar cmacs-journal--file-cache (make-hash-table :test #'equal)
  "Day file -> ((MTIME SIZE) . EVENTS).")

(defvar cmacs-journal--in-tool-call nil
  "Non-nil inside a brigade tool call.  See `cmacs-journal-agent-context-p'.")

(defvar-local cmacs-journal--project 'unset
  "Cached (DIRECTORY . PROJECT) for this buffer, or `unset'.")

(defsubst cmacs-journal--now ()
  "The current time, in seconds."
  (funcall cmacs-journal-time-function))

(defun cmacs-journal-recording-p ()
  "Non-nil when the journal is recording right now."
  (and (bound-and-true-p cmacs-journal-mode)
       (null cmacs-journal--paused)
       (not cmacs-journal--locked)
       (cmacs-journal-filter-ready-p)))

;;;; Spans

(defun cmacs-journal--key (event)
  "EVENT without its times: what makes two observations the same span."
  (let (key)
    (dolist (field cmacs-journal-fields)
      (unless (memq field '(:time :end :duration))
        (push (plist-get event field) key)))
    key))

(defun cmacs-journal--close (&optional time)
  "Close the open span at TIME (default now) and queue it.
A span shorter than `cmacs-journal-min-span' is dropped."
  (let ((span cmacs-journal--open))
    (setq cmacs-journal--open nil)
    (when span
      (let* ((end (or time (cmacs-journal--now)))
             (duration (- end (plist-get span :time))))
        (when (>= duration cmacs-journal-min-span)
          (setq span (plist-put span :end end))
          (setq span (plist-put span :duration duration))
          (push span cmacs-journal--queue)
          (cl-incf cmacs-journal--generation))))))

(defun cmacs-journal--observe (raw &optional time)
  "Take RAW, what has the focus now, and start, extend or end a span.

RAW is an event plist without times, or nil for \"nothing\".  It goes
through the filters first; an event they exclude ends the open span and
starts none, which leaves a gap exactly as if nothing had been focused.
TIME is when it happened (default now)."
  (when (cmacs-journal-recording-p)
    (let* ((now (or time (cmacs-journal--now)))
           (event (and raw (cmacs-journal-filter-apply raw))))
      (cond
       ((null event) (cmacs-journal--close now))
       ;; The same thing again: the open span simply goes on.
       ((and cmacs-journal--open
             (equal (cmacs-journal--key event)
                    (cmacs-journal--key cmacs-journal--open))))
       (t
        (cmacs-journal--close now)
        ;; Reopened straight after closing?  Carry on from where it
        ;; started instead of writing two lines.
        (let ((last (car cmacs-journal--queue)))
          (if (and last
                   (<= (- now (plist-get last :end)) cmacs-journal-merge-gap)
                   (equal (cmacs-journal--key last)
                          (cmacs-journal--key event)))
              (progn
                (pop cmacs-journal--queue)
                (cl-incf cmacs-journal--generation)
                (setq now (plist-get last :time)))))
        (setq cmacs-journal--open (plist-put event :time now)))))))

(defun cmacs-journal--record-point (raw &optional time duration)
  "Queue RAW as a finished event of DURATION seconds ending at TIME.
For things that are not a stretch of focus -- an agent run finishing.
It goes through the filters like everything else."
  (when (cmacs-journal-recording-p)
    (let ((event (cmacs-journal-filter-apply raw))
          (end (or time (cmacs-journal--now)))
          (duration (or duration 0)))
      (when event
        (setq event (plist-put event :time (- end duration)))
        (setq event (plist-put event :end end))
        (setq event (plist-put event :duration duration))
        (push event cmacs-journal--queue)
        (cl-incf cmacs-journal--generation)))))

;;;; What Emacs itself is showing

(defun cmacs-journal--abbreviate (file)
  "FILE with the home directory as ~, without touching the filesystem."
  (let ((home (expand-file-name "~")))
    (if (string-prefix-p (file-name-as-directory home) file)
        (concat "~/" (substring file (length (file-name-as-directory home))))
      file)))

(defun cmacs-journal--para-project (file)
  "A (PROJECT . BUCKET) pair for FILE inside a PARA tree, or nil.
Pure string work on the path; see `cmacs-para-classify'."
  (when (and file (fboundp 'cmacs-para-classify))
    (let ((class (cmacs-para-classify file)))
      (when (and class (plist-get class :bucket))
        (let* ((rel (plist-get class :rel))
               (dirs (butlast (split-string rel "/" t))))
          (cons (mapconcat #'identity (seq-take dirs 3) "/")
                (plist-get class :bucket)))))))

(defun cmacs-journal--buffer-project (buffer)
  "The project name of BUFFER, or nil.  Cached per buffer and directory.

This asks `project-current', which looks at the filesystem, so it is
only ever called from a timer -- never from a hook -- and never for a
remote directory: a journal must not open a Tramp connection."
  (with-current-buffer buffer
    (let ((dir default-directory))
      (if (and (consp cmacs-journal--project)
               (equal (car cmacs-journal--project) dir))
          (cdr cmacs-journal--project)
        (let ((name
               (and (stringp dir)
                    (not (file-remote-p dir))
                    (or buffer-file-name
                        (derived-mode-p '(dired-mode vc-dir-mode
                                          magit-mode compilation-mode
                                          comint-mode eshell-mode
                                          term-mode)))
                    (condition-case nil
                        (let* ((inhibit-message t)
                               (project (and (fboundp 'project-current)
                                             (project-current nil dir))))
                          (and project
                               (if (fboundp 'project-name)
                                   (project-name project)
                                 (file-name-nondirectory
                                  (directory-file-name
                                   (project-root project))))))
                      (error nil)))))
          (setq cmacs-journal--project (cons dir name))
          name)))))

(defun cmacs-journal--gsurf-container (buffer)
  "The `container:NAME' detail of gsurf BUFFER, or nil for the default."
  (when (fboundp 'cmacs-gsurf-container-id)
    (let ((id (ignore-errors (cmacs-gsurf-container-id buffer))))
      (when id
        (let ((spec (and (fboundp 'cmacs-gsurf-containers)
                         (cl-find id (ignore-errors (cmacs-gsurf-containers))
                                  :key (lambda (c) (plist-get c :id))
                                  :test #'equal))))
          (concat "container:"
                  (cond ((plist-get spec :temporary) "temporary")
                        ((plist-get spec :name))
                        (t id))))))))

(defun cmacs-journal--buffer-event (buffer &optional with-project)
  "The raw event for BUFFER being the selected buffer.
WITH-PROJECT non-nil means look its project up, which may touch the
disk; only a timer passes it."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((name (buffer-name))
             (mode (symbol-name major-mode))
             (uri (and (eq major-mode 'cmacs-gsurf-mode)
                       (fboundp 'cmacs-gsurf-get-uri)
                       (ignore-errors (cmacs-gsurf-get-uri buffer)))))
        (if (and (stringp uri) (not (string-empty-p uri)))
            (list :kind 'url :app "gsurf"
                  :title (and (fboundp 'cmacs-gsurf-get-title)
                              (ignore-errors (cmacs-gsurf-get-title buffer)))
                  :buffer name :mode mode :url uri
                  :detail (cmacs-journal--gsurf-container buffer))
          (let* ((file (and buffer-file-name
                            (cmacs-journal--abbreviate buffer-file-name)))
                 (para (cmacs-journal--para-project buffer-file-name)))
            (list :kind 'buffer :app "emacs" :pid (emacs-pid)
                  :buffer name :file file :mode mode
                  :project (or (car para)
                               (and with-project
                                    (cmacs-journal--buffer-project buffer))
                               (and (consp cmacs-journal--project)
                                    (cdr cmacs-journal--project)))
                  :detail (and para (concat "para:" (cdr para))))))))))

(defun cmacs-journal--selected-buffer ()
  "The buffer the user is looking at: never the minibuffer."
  (let ((window (or (and (minibufferp (window-buffer (selected-window)))
                         (minibuffer-selected-window))
                    (selected-window))))
    (window-buffer window)))

(defun cmacs-journal--resolve-buffer ()
  "Timer: turn a pending buffer observation into a span.
Runs outside every hook, so this is where the project lookup lives."
  (let ((time cmacs-journal--pending))
    (setq cmacs-journal--pending nil)
    (when (and time (not cmacs-journal--external-focus))
      (condition-case nil
          (cmacs-journal--observe
           (cmacs-journal--buffer-event (cmacs-journal--selected-buffer) t)
           time)
        (error nil)))))

(defun cmacs-journal--note-buffer ()
  "Remember that the selected buffer changed now; resolve it in a timer.
This is all a hook does about a buffer: one timestamp and one timer."
  (unless cmacs-journal--pending
    (setq cmacs-journal--pending (cmacs-journal--now))
    (run-with-timer 0 nil #'cmacs-journal--resolve-buffer)))

(defun cmacs-journal--on-window-change (&rest _)
  "Hook: the selected window or its buffer changed."
  (condition-case nil
      (when (and (cmacs-journal-recording-p)
                 (not cmacs-journal--external-focus))
        (cmacs-journal--leave-idle)
        (cmacs-journal--note-buffer))
    (error nil)))

(defun cmacs-journal--on-gsurf-change (buffer &rest _)
  "Hook: gsurf BUFFER navigated or its title changed."
  (condition-case nil
      (when (and (cmacs-journal-recording-p)
                 (not cmacs-journal--external-focus)
                 (eq buffer (cmacs-journal--selected-buffer)))
        (cmacs-journal--note-buffer))
    (error nil)))

;;;; Idle

(defun cmacs-journal--leave-idle ()
  "End an open `idle' span: the user is back."
  (when cmacs-journal--idle
    (setq cmacs-journal--idle nil)
    (remove-hook 'pre-command-hook #'cmacs-journal--on-activity)))

(defun cmacs-journal--on-activity ()
  "One-shot `pre-command-hook': input arrived while idle."
  (condition-case nil
      (progn
        (cmacs-journal--leave-idle)
        (when (cmacs-journal-recording-p)
          (cmacs-journal--note-buffer)))
    (error nil)))

(defun cmacs-journal--on-idle ()
  "Idle timer: nothing typed for `cmacs-journal-idle-threshold' seconds."
  (condition-case nil
      (when (and (cmacs-journal-recording-p)
                 (not cmacs-journal--external-focus)
                 (not cmacs-journal--idle)
                 (numberp cmacs-journal-idle-threshold))
        ;; The idle span starts when the input stopped, not when this
        ;; timer noticed.
        (let ((since (- (cmacs-journal--now) cmacs-journal-idle-threshold)))
          (when (and cmacs-journal--open
                     (< since (plist-get cmacs-journal--open :time)))
            (setq since (cmacs-journal--now)))
          (cmacs-journal--observe (list :kind 'idle) since)
          (setq cmacs-journal--idle t)
          (add-hook 'pre-command-hook #'cmacs-journal--on-activity)))
    (error nil)))

;;;; The compositor

(defun cmacs-journal--tag-list (mask)
  "The tag numbers set in the bitmask MASK, lowest first."
  (when (and (integerp mask) (> mask 0))
    (cl-loop for i from 0 below 32
             when (/= 0 (logand mask (ash 1 i))) collect (1+ i))))

(defun cmacs-journal--client-event (client)
  "The raw event for gowl CLIENT having the focus, or the symbol `emacs'.
`emacs' means CLIENT is one of this Emacs's own frames, which is recorded
as the buffer it shows.  Everything here reads compositor memory under
the gowl lock: no I/O, no waiting."
  (let* ((info (gowl-client-info client))
         (pid (and (fboundp 'gowl-client-pid) (gowl-client-pid client))))
    (setq cmacs-journal--focus-id (alist-get 'id info))
    (if (and (integerp pid) (= pid (emacs-pid)))
        'emacs
      (list :kind 'focus
            :app (alist-get 'app-id info)
            :title (alist-get 'title info)
            :pid (and (integerp pid) (> pid 0) pid)
            :tags (cmacs-journal--tag-list (alist-get 'tags info))
            :monitor (and (fboundp 'gowl-monitor-info)
                          (alist-get 'name (gowl-monitor-info)))))))

(defun cmacs-journal--observe-client (client)
  "Record gowl CLIENT (or nil for none) as what has the focus."
  (let ((event (and client (cmacs-journal--client-event client))))
    (cond
     ((eq event 'emacs)
      (setq cmacs-journal--external-focus nil)
      (cmacs-journal--note-buffer))
     (event
      (setq cmacs-journal--external-focus t)
      (cmacs-journal--leave-idle)
      (cmacs-journal--observe event))
     (t
      ;; Focus is nowhere.  Buffer changes do not count until it is back.
      (setq cmacs-journal--external-focus t
            cmacs-journal--focus-id nil)
      (cmacs-journal--observe nil)))))

(defun cmacs-journal--on-focus (client &rest _)
  "Hook: gowl's focus moved to CLIENT, or to nothing."
  (condition-case nil
      (when (cmacs-journal-recording-p)
        (cmacs-journal--observe-client client))
    ;; A client that vanished between the signal and now, or anything
    ;; else: the honest record is that nothing is known to be focused.
    (error (ignore-errors (cmacs-journal--close)))))

(defun cmacs-journal--on-title (client &rest _)
  "Hook: gowl CLIENT's title or app id changed."
  (condition-case nil
      (when (and (cmacs-journal-recording-p)
                 cmacs-journal--focus-id
                 (equal (alist-get 'id (gowl-client-info client))
                        cmacs-journal--focus-id))
        (cmacs-journal--observe-client client))
    (error nil)))

(defun cmacs-journal--refocus (&rest _)
  "Hook: re-read what has the focus (a tag switch, an unlock)."
  (condition-case nil
      (when (cmacs-journal-recording-p)
        (if (fboundp 'gowl-focused-client)
            (cmacs-journal--observe-client (gowl-focused-client))
          (cmacs-journal--note-buffer)))
    (error (ignore-errors (cmacs-journal--close)))))

(defun cmacs-journal--on-lock (locked &rest _)
  "Hook: the session locked (LOCKED non-nil) or unlocked.
A lock closes the open span, and nothing is recorded until the unlock."
  (condition-case nil
      (if locked
          (progn
            (when (cmacs-journal-recording-p) (cmacs-journal--close))
            (setq cmacs-journal--open nil
                  cmacs-journal--pending nil
                  cmacs-journal--locked t))
        (setq cmacs-journal--locked nil)
        (cmacs-journal--refocus))
    (error nil)))

;;;; Agents

(defun cmacs-journal--on-agent-run (task-id state &rest _)
  "Hook: the brigade run TASK-ID ended in STATE.
The run's output is not recorded -- only that it happened."
  (condition-case nil
      (when (cmacs-journal-recording-p)
        (let ((task (and (fboundp 'cmacs-brigade-task-get)
                         (stringp task-id)
                         (ignore-errors (cmacs-brigade-task-get task-id)))))
          (cmacs-journal--record-point
           (list :kind 'agent
                 :app (or (plist-get task :agent) "brigade")
                 :title (plist-get task :title)
                 :detail (format "%s" state)))))
    (error nil)))

(defun cmacs-journal--around-tool-call (function &rest args)
  "Around advice for `cmacs-brigade-call-tool': mark the call as an agent's."
  (let ((cmacs-journal--in-tool-call t))
    (apply function args)))

(with-eval-after-load 'cmacs-brigade-tools
  (advice-add 'cmacs-brigade-call-tool :around
              #'cmacs-journal--around-tool-call))

(defun cmacs-journal-agent-context-p ()
  "Non-nil when the caller is an agent or a remote client, not the user.

Two signals, either of which is enough:

  * `cmacs-journal--in-tool-call', bound by an around advice on
    `cmacs-brigade-call-tool' -- the one function every brigade tool
    call goes through, whichever agent or MCP client made it.  It is a
    dynamic binding, so it covers exactly the extent of the call and
    cannot be left set by a tool that signals.

  * `inhibit-interaction', which cmacs's RPC dispatch binds around
    everything arriving over MCP, D-Bus, emacsctl and bacon.  This also
    catches your own `emacsctl lql' from a terminal: over that channel
    you are indistinguishable from a program, and the journal assumes
    the program.

An LQL source's rows are snapshotted on the editor thread when the query
is submitted, inside the dynamic extent of whichever of these applies,
so this is the moment the decision is made."
  (or cmacs-journal--in-tool-call
      (bound-and-true-p inhibit-interaction)))

(defun cmacs-journal--readable-p ()
  "Non-nil when the caller may be shown journal rows."
  (or cmacs-journal-expose-to-agents
      (not (cmacs-journal-agent-context-p))))

;;;; Files

(defun cmacs-journal--ensure-directory ()
  "Create `cmacs-journal-directory' with mode 0700 and return it."
  (let ((dir (file-name-as-directory
              (expand-file-name cmacs-journal-directory))))
    (unless (file-directory-p dir)
      (with-file-modes #o700 (make-directory dir t)))
    ;; Explicitly, every time: the umask, or a directory someone made by
    ;; hand, must not decide who can read this.
    (unless (= (logand (file-modes dir) #o777) #o700)
      (set-file-modes dir #o700))
    dir))

(defun cmacs-journal--day (time)
  "The local date of TIME as YYYY-MM-DD."
  (format-time-string "%Y-%m-%d" time))

(defun cmacs-journal--day-file (day)
  "The journal file for DAY (a YYYY-MM-DD string)."
  (expand-file-name (concat day ".jsonl") cmacs-journal-directory))

(defun cmacs-journal--iso (time)
  "TIME as ISO 8601 with a numeric offset."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z" time))

(defun cmacs-journal--parse-time (value)
  "The seconds VALUE means: a number, or an ISO 8601 string."
  (cond ((numberp value) (float value))
        ((stringp value)
         (float-time (or (ignore-errors (parse-iso8601-time-string value))
                         (date-to-time value))))))

(defun cmacs-journal--encode (event)
  "EVENT as one line of JSON, without the newline."
  (let (object)
    (dolist (field cmacs-journal-fields)
      (let ((value (plist-get event field))
            (key (intern (substring (symbol-name field) 1))))
        (when value
          (push (cons key
                      (pcase field
                        ((or :time :end) (cmacs-journal--iso value))
                        (:duration (/ (fround (* 10.0 value)) 10.0))
                        (:tags (vconcat value))
                        (_ (cond ((stringp value)
                                  (substring-no-properties value))
                                 ((numberp value) value)
                                 (t (format "%s" value))))))
                object))))
    (json-serialize (nreverse object))))

(defun cmacs-journal--decode (line)
  "The event plist LINE (one JSON object) holds, or nil if it is not one."
  (condition-case nil
      (let ((object (json-parse-string line :object-type 'alist
                                       :array-type 'list
                                       :null-object nil :false-object nil))
            event)
        (dolist (field cmacs-journal-fields)
          (let ((value (alist-get (intern (substring (symbol-name field) 1))
                                  object)))
            (when value
              (setq event
                    (plist-put event field
                               (pcase field
                                 ((or :time :end)
                                  (cmacs-journal--parse-time value))
                                 (:kind (intern value))
                                 (_ value)))))))
        (and (plist-get event :time) event))
    (error nil)))

(defun cmacs-journal--write-lines (file events append)
  "Write EVENTS to FILE as JSON Lines, mode 0600.  APPEND non-nil appends."
  (let ((coding-system-for-write 'utf-8-unix)
        (write-region-inhibit-fsync nil)
        (text (mapconcat (lambda (e) (concat (cmacs-journal--encode e) "\n"))
                         events "")))
    (with-file-modes #o600
      (write-region text nil file append 'silent))
    (unless (= (logand (file-modes file) #o777) #o600)
      (set-file-modes file #o600))))

;;;###autoload
(defun cmacs-journal-flush ()
  "Write the journal's queued spans to their day files.
The open span stays open; it is written when it closes."
  (interactive)
  (when cmacs-journal--queue
    (let ((events (nreverse cmacs-journal--queue))
          (by-day nil))
      (setq cmacs-journal--queue nil)
      (condition-case err
          (progn
            (cmacs-journal--ensure-directory)
            (dolist (event events)
              (let* ((day (cmacs-journal--day (plist-get event :time)))
                     (cell (assoc day by-day)))
                (if cell (push event (cdr cell))
                  (push (list day event) by-day))))
            (pcase-dolist (`(,day . ,day-events) by-day)
              (cmacs-journal--write-lines (cmacs-journal--day-file day)
                                          (nreverse day-events) t))
            (cl-incf cmacs-journal--generation))
        (error
         ;; Could not write: keep the spans for the next try rather than
         ;; lose them, and say so once.
         (setq cmacs-journal--queue
               (append cmacs-journal--queue (nreverse events)))
         (display-warning 'cmacs-journal
                          (format "Could not write the journal: %s"
                                  (error-message-string err))
                          :warning)))))
  (when (called-interactively-p 'interactive)
    (message "cmacs-journal: flushed")))

(defun cmacs-journal--tick ()
  "Timer: write queued spans, notice changed filter files, prune."
  (condition-case nil
      (progn
        (cmacs-journal-filter-check)
        (cmacs-journal-flush)
        (cmacs-journal--prune))
    (error nil)))

(defun cmacs-journal--day-files ()
  "Every day file in the journal directory as (DAY . FILE), oldest first."
  (let ((dir (expand-file-name cmacs-journal-directory)))
    (when (file-directory-p dir)
      (mapcar (lambda (f) (cons (file-name-base f) f))
              (directory-files
               dir t "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\.jsonl\\'")))))

(defun cmacs-journal--prune ()
  "Delete day files older than `cmacs-journal-retention-days'."
  (when (and (integerp cmacs-journal-retention-days)
             (> cmacs-journal-retention-days 0))
    (let ((cutoff (cmacs-journal--day
                   (- (cmacs-journal--now)
                      (* 86400 cmacs-journal-retention-days)))))
      (pcase-dolist (`(,day . ,file) (cmacs-journal--day-files))
        (when (string< day cutoff)
          (delete-file file)
          (remhash file cmacs-journal--file-cache)
          (cl-incf cmacs-journal--generation))))))

(defun cmacs-journal--read-file (file)
  "The events in day FILE, oldest first.  Cached until the file changes."
  (let* ((attrs (file-attributes file))
         (sig (and attrs (list (file-attribute-modification-time attrs)
                               (file-attribute-size attrs))))
         (hit (gethash file cmacs-journal--file-cache)))
    (cond
     ((null attrs) nil)
     ((and hit (equal (car hit) sig)) (cdr hit))
     (t
      (let (events)
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents file))
          (goto-char (point-min))
          (while (not (eobp))
            (let ((event (cmacs-journal--decode
                          (buffer-substring-no-properties
                           (point) (line-end-position)))))
              (when event (push event events)))
            (forward-line 1)))
        (setq events (nreverse events))
        (puthash file (cons sig events) cmacs-journal--file-cache)
        events)))))

(defun cmacs-journal-events (&optional from to)
  "The journal's events overlapping FROM..TO, oldest first.

FROM and TO are times in seconds; nil leaves that end open.  Stored
spans and those not yet written are both included; the span still open
is not.  Returns nil to an agent unless
`cmacs-journal-expose-to-agents' is set."
  (when (cmacs-journal--readable-p)
    (let ((from-day (and from (cmacs-journal--day (- from 86400))))
          (to-day (and to (cmacs-journal--day to)))
          (events nil))
      (pcase-dolist (`(,day . ,file) (cmacs-journal--day-files))
        (when (and (or (null from-day) (not (string< day from-day)))
                   (or (null to-day) (not (string< to-day day))))
          (setq events (append events (cmacs-journal--read-file file)))))
      (setq events (append events (reverse cmacs-journal--queue)))
      (sort
       (cl-remove-if-not
        (lambda (e)
          (and (or (null to) (<= (plist-get e :time) to))
               (or (null from)
                   (>= (or (plist-get e :end) (plist-get e :time)) from))))
        events)
       (lambda (a b) (< (plist-get a :time) (plist-get b :time)))))))

;;;; Forgetting

(defun cmacs-journal--forget-p (event from to regexp)
  "Non-nil when EVENT is one FROM, TO and REGEXP say to forget."
  (and (or (null to) (<= (plist-get event :time) to))
       (or (null from)
           (>= (or (plist-get event :end) (plist-get event :time)) from))
       (or (null regexp)
           (let ((case-fold-search t))
             (cl-some (lambda (field)
                        (let ((s (cmacs-journal-filter--string
                                  (plist-get event field))))
                          (and s (string-match-p regexp s))))
                      cmacs-journal-filter-fields)))))

(defun cmacs-journal--rewrite (file events)
  "Replace day FILE's contents with EVENTS, atomically; none deletes it."
  (if (null events)
      (delete-file file)
    (let ((temp (make-temp-name (concat file ".tmp"))))
      (unwind-protect
          (progn
            (cmacs-journal--write-lines temp events nil)
            (rename-file temp file t)
            (setq temp nil))
        (when (and temp (file-exists-p temp)) (delete-file temp)))))
  (remhash file cmacs-journal--file-cache))

(defun cmacs-journal--read-time (prompt)
  "Read a date and time with PROMPT; return seconds, or nil for empty."
  (require 'org)
  (let ((s (read-string (concat prompt " (empty for open-ended): "))))
    (unless (string-empty-p s)
      (float-time (org-read-date t t s)))))

;;;###autoload
(defun cmacs-journal-forget (from to &optional regexp)
  "Delete journal events from the stored files, the queue and the open span.

An event goes when it overlaps FROM..TO (times in seconds, nil for an
open end) and, when REGEXP is given, some field of it matches REGEXP.
So FROM and TO alone forget a stretch of time, and REGEXP with both nil
forgets everything that mentions something.  A span partly inside the
range goes whole.  Each day file is rewritten through a temporary file
and a rename, so an interruption leaves the old file or the new one,
never half of one.

Interactively, asks which, counts what would go, and asks again.
Returns the number of events deleted."
  (interactive
   (let* ((how (read-multiple-choice
                "Forget by"
                '((?t "time range") (?r "regexp") (?b "both"))))
          (timep (memq (car how) '(?t ?b)))
          (from (and timep (cmacs-journal--read-time "From")))
          (to (and timep (cmacs-journal--read-time "To")))
          (regexp (and (memq (car how) '(?r ?b))
                       (read-regexp "Forget events matching regexp: "))))
     (list from to regexp)))
  (when (and (null from) (null to) (or (null regexp) (string-empty-p regexp)))
    (user-error "Nothing to forget: give a time range or a regexp"))
  (when (and regexp (string-empty-p regexp)) (setq regexp nil))
  (cmacs-journal-flush)
  (let ((plan nil) (count 0)
        (from-day (and from (cmacs-journal--day (- from 86400))))
        (to-day (and to (cmacs-journal--day to))))
    (pcase-dolist (`(,day . ,file) (cmacs-journal--day-files))
      (when (and (or (null from-day) (not (string< day from-day)))
                 (or (null to-day) (not (string< to-day day))))
        (let* ((events (cmacs-journal--read-file file))
               (keep (cl-remove-if
                      (lambda (e) (cmacs-journal--forget-p e from to regexp))
                      events))
               (gone (- (length events) (length keep))))
          (when (> gone 0)
            (setq count (+ count gone))
            (push (cons file keep) plan)))))
    (when (or (not (called-interactively-p 'interactive))
              (and (> count 0)
                   (yes-or-no-p
                    (format "Permanently delete %d journal event%s? "
                            count (if (= count 1) "" "s")))))
      (pcase-dolist (`(,file . ,keep) plan)
        (cmacs-journal--rewrite file keep))
      ;; Whatever was not written yet, and the span still open.
      (setq cmacs-journal--queue
            (cl-remove-if
             (lambda (e) (cmacs-journal--forget-p e from to regexp))
             cmacs-journal--queue))
      (when (and cmacs-journal--open
                 (cmacs-journal--forget-p
                  (append (list :end (cmacs-journal--now))
                          cmacs-journal--open)
                  from to regexp))
        (setq cmacs-journal--open nil))
      (cl-incf cmacs-journal--generation))
    (when (called-interactively-p 'interactive)
      (message "cmacs-journal: %d event%s deleted" count
               (if (= count 1) "" "s")))
    count))

;;;; The hash key

(defun cmacs-journal--load-secret ()
  "Load, or create, the per-install key `hash' filters use.
It lives in the file `secret' beside the day files, mode 0600, and is
never written into the journal itself."
  (let* ((file (expand-file-name "secret" (cmacs-journal--ensure-directory)))
         (key (and (file-readable-p file)
                   (with-temp-buffer
                     (insert-file-contents-literally file)
                     (string-trim (buffer-string))))))
    (when (or (null key) (< (length key) 32))
      (setq key
            (secure-hash
             'sha256
             (concat
              (or (ignore-errors
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally "/dev/urandom" nil 0 64)
                      (buffer-string)))
                  "")
              ;; Only what is left when there is no /dev/urandom.
              (format "%s%s%s%s" (random t) (emacs-pid) (current-time)
                      (random t)))))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-file-modes #o600
          (write-region (concat key "\n") nil file nil 'silent))))
    (unless (= (logand (file-modes file) #o777) #o600)
      (set-file-modes file #o600))
    (setq cmacs-journal-filter-hash-key key)))

;;;; Pause, resume, the mode

(defun cmacs-journal--stop-span ()
  "Close the open span and forget where the focus was."
  (cmacs-journal--close)
  (cmacs-journal--leave-idle)
  (setq cmacs-journal--pending nil))

(defun cmacs-journal--start-span ()
  "Start recording whatever has the focus now."
  (setq cmacs-journal--locked
        (and (fboundp 'gowl-locked-p) (ignore-errors (gowl-locked-p)) t))
  (setq cmacs-journal--external-focus nil)
  (let ((client (and (fboundp 'gowl-focused-client)
                     (ignore-errors (gowl-focused-client)))))
    (condition-case nil
        (if client
            (cmacs-journal--observe-client client)
          (cmacs-journal--note-buffer))
      (error nil))))

(defun cmacs-journal-pause ()
  "Stop recording until `cmacs-journal-resume'.  The open span closes."
  (interactive)
  (when (cmacs-journal-recording-p) (cmacs-journal--stop-span))
  (setq cmacs-journal--open nil
        cmacs-journal--paused 'user)
  (force-mode-line-update t)
  (when (called-interactively-p 'interactive)
    (message "cmacs-journal: paused")))

(defun cmacs-journal-resume ()
  "Start recording again after `cmacs-journal-pause'."
  (interactive)
  (unless (bound-and-true-p cmacs-journal-mode)
    (user-error "The journal is off; turn on `cmacs-journal-mode'"))
  (unless (cmacs-journal-filter-ready-p)
    (unless (cmacs-journal-filters-reload)
      (user-error "The journal's filters are not usable: %s"
                  (cmacs-journal-filter-error))))
  (setq cmacs-journal--paused nil)
  (cmacs-journal--start-span)
  (force-mode-line-update t)
  (when (called-interactively-p 'interactive)
    (message "cmacs-journal: recording")))

(defun cmacs-journal--filters-changed (ok)
  "React to a (re)load of the filter rules; OK non-nil means usable.
Unusable rules stop the recording.  Usable ones start it again, but only
if it was the filters that stopped it -- never over a user's pause."
  (when (bound-and-true-p cmacs-journal-mode)
    (cond
     ((not ok)
      (cmacs-journal--stop-span)
      (setq cmacs-journal--open nil)
      (unless cmacs-journal--paused (setq cmacs-journal--paused 'filter)))
     ((eq cmacs-journal--paused 'filter)
      (setq cmacs-journal--paused nil)
      (cmacs-journal--start-span))
     ((null cmacs-journal--paused)
      ;; New rules apply from now: the open span was admitted under the
      ;; old ones, so it ends here and is looked at again.
      (cmacs-journal--stop-span)
      (cmacs-journal--start-span)))
    (force-mode-line-update t)))

(defun cmacs-journal--mode-line ()
  "The journal's mode-line indicator."
  (if (cmacs-journal-recording-p)
      (propertize cmacs-journal-mode-line-recording
                  'face 'error
                  'help-echo "cmacs-journal is recording window and buffer names")
    (propertize cmacs-journal-mode-line-paused
                'help-echo
                (cond (cmacs-journal--locked "cmacs-journal: session locked")
                      ((eq cmacs-journal--paused 'filter)
                       "cmacs-journal: stopped, the filters did not load")
                      (t "cmacs-journal: paused")))))

(defconst cmacs-journal--mode-line-entry
  '(cmacs-journal-mode (:eval (cmacs-journal--mode-line)))
  "The journal's element of `mode-line-misc-info'.")

(defconst cmacs-journal--hooks
  '((cmacs-gowl-focus-changed-functions . cmacs-journal--on-focus)
    (cmacs-gowl-client-title-changed-functions . cmacs-journal--on-title)
    (cmacs-gowl-tag-changed-functions . cmacs-journal--refocus)
    (cmacs-gowl-lock-changed-functions . cmacs-journal--on-lock)
    (window-selection-change-functions . cmacs-journal--on-window-change)
    (window-buffer-change-functions . cmacs-journal--on-window-change)
    (cmacs-gsurf-uri-changed-functions . cmacs-journal--on-gsurf-change)
    (cmacs-gsurf-title-changed-functions . cmacs-journal--on-gsurf-change)
    (cmacs-brigade-run-finished-functions . cmacs-journal--on-agent-run))
  "Hook -> function for everything the journal listens to.
The hooks of subsystems that are not built are simply never run.")

(defun cmacs-journal--shutdown ()
  "`kill-emacs-hook': close the open span and write everything."
  (condition-case nil
      (progn
        (when (cmacs-journal-recording-p) (cmacs-journal--close))
        (cmacs-journal-flush))
    (error nil)))

;;;###autoload
(define-minor-mode cmacs-journal-mode
  "Record what has your attention in a local, text-only journal.

Off by default: nothing is recorded, and nothing is listened to, until
you turn this on.  While it is on the mode line shows an indicator, and
`cmacs-journal-pause' / `cmacs-journal-resume' stop and start it.

Recorded: the app id and title of the focused window (under gowl), the
name, file, major mode and project of the selected buffer, the URL and
title of a gsurf buffer, and the fact that an agent run finished -- each
as a span with a start and a duration.  Not recorded: screen contents,
keystrokes, clipboard, buffer text, anything while the session is
locked, anything a filter excludes.

Everything goes through `cmacs-journal-filters' and the YAML files in
`cmacs-journal-filter-files' first.  If those cannot be loaded the mode
turns on but records nothing until they can.

The day files are in `cmacs-journal-directory'; `cmacs-journal-forget'
deletes from them."
  :global t
  :group 'cmacs-journal
  (dolist (timer cmacs-journal--timers) (cancel-timer timer))
  (setq cmacs-journal--timers nil)
  (if cmacs-journal-mode
      (progn
        (setq cmacs-journal--paused nil
              cmacs-journal--open nil
              cmacs-journal--pending nil)
        (require 'cmacs-para nil t)
        (add-hook 'cmacs-journal-filter-changed-functions
                  #'cmacs-journal--filters-changed)
        (pcase-dolist (`(,hook . ,function) cmacs-journal--hooks)
          (add-hook hook function))
        (add-hook 'kill-emacs-hook #'cmacs-journal--shutdown)
        (add-to-list 'mode-line-misc-info cmacs-journal--mode-line-entry)
        (push (run-with-idle-timer cmacs-journal-flush-idle t
                                   #'cmacs-journal--tick)
              cmacs-journal--timers)
        (push (run-with-timer cmacs-journal-flush-interval
                              cmacs-journal-flush-interval
                              #'cmacs-journal--tick)
              cmacs-journal--timers)
        (when (numberp cmacs-journal-idle-threshold)
          (push (run-with-idle-timer cmacs-journal-idle-threshold t
                                     #'cmacs-journal--on-idle)
                cmacs-journal--timers))
        ;; The key before the rules: a `hash' action with no key blanks
        ;; its field, which is safe but not what was asked for.
        (condition-case err
            (cmacs-journal--load-secret)
          (error (display-warning
                  'cmacs-journal
                  (format "No hash key (%s); hashed fields will be blank"
                          (error-message-string err))
                  :warning)))
        (cmacs-journal-filter-watch)
        ;; Fail closed: this either yields a rule set or leaves the mode
        ;; on, paused, with a warning saying why.  The changed-functions
        ;; hook it runs is what starts the first span.
        (setq cmacs-journal--paused 'filter)
        (cmacs-journal-filters-reload))
    (cmacs-journal--shutdown)
    (setq cmacs-journal--open nil
          cmacs-journal--paused nil
          cmacs-journal--pending nil)
    (cmacs-journal-filter-unwatch)
    (remove-hook 'cmacs-journal-filter-changed-functions
                 #'cmacs-journal--filters-changed)
    (pcase-dolist (`(,hook . ,function) cmacs-journal--hooks)
      (remove-hook hook function))
    (remove-hook 'kill-emacs-hook #'cmacs-journal--shutdown)
    (remove-hook 'pre-command-hook #'cmacs-journal--on-activity)
    (setq mode-line-misc-info
          (delete cmacs-journal--mode-line-entry mode-line-misc-info)))
  (force-mode-line-update t))

(defun cmacs-journal-current-event ()
  "The raw event the journal would record right now, before filtering.
For `cmacs-journal-filter-test'; nothing is recorded by calling it."
  (let* ((client (and (fboundp 'gowl-focused-client)
                      (ignore-errors (gowl-focused-client))))
         (cmacs-journal--focus-id cmacs-journal--focus-id)
         (event (and client
                     (ignore-errors (cmacs-journal--client-event client)))))
    (if (and event (not (eq event 'emacs)))
        event
      (cmacs-journal--buffer-event (cmacs-journal--selected-buffer) t))))

;;;; LQL

(defconst cmacs-journal--lql-columns
  '(("time" timestamp) ("end" timestamp) ("duration" duration)
    ("kind" string) ("app" string) ("title" string) ("buffer" string)
    ("file" string) ("mode" string) ("project" string) ("url" string)
    ("tags" array) ("monitor" string) ("detail" string)
    ("context" string))
  "Columns of the LQL `activity' source.")

(defun cmacs-journal--lql-rows ()
  "Rows of the LQL `activity' source.
The last `cmacs-journal-lql-days' days of stored spans plus those not
yet written.  No rows for an agent unless
`cmacs-journal-expose-to-agents' is set."
  (mapcar
   (lambda (event)
     (let ((time (plist-get event :time)))
       (list :time time
             :end (or (plist-get event :end) time)
             :duration (or (plist-get event :duration) 0)
             :kind (plist-get event :kind)
             :app (plist-get event :app)
             :title (plist-get event :title)
             :buffer (plist-get event :buffer)
             :file (plist-get event :file)
             :mode (plist-get event :mode)
             :project (plist-get event :project)
             :url (plist-get event :url)
             ;; A row always has the array, so a query can test it
             ;; without a null check.
             :tags (vconcat (plist-get event :tags))
             :monitor (plist-get event :monitor)
             :detail (plist-get event :detail)
             ;; The named context active when the row began (nil for
             ;; none).  It is the title of a `context' event, which went
             ;; through the filters when it was recorded like every
             ;; other field here.
             :context (plist-get event :context))))
   (let* ((from (- (cmacs-journal--now)
                   (* 86400 (max 1 cmacs-journal-lql-days))))
          (events (cmacs-journal-events from)))
     ;; Rows are not split at a switch: a row stays the span that was
     ;; recorded, in the context it started in.  The report file
     ;; requires this one, so it is loaded here and not at top level.
     (if (and events (require 'cmacs-journal-report nil t))
         (cmacs-journal-attribute-contexts
          events (cmacs-journal-context-at from) t)
       events))))

(defun cmacs-journal--lql-generation ()
  "What the `activity' source's cached snapshot is keyed on.
Who is asking is part of the key: a snapshot made for the user must
never be the one handed to an agent."
  (list cmacs-journal--generation
        (cmacs-journal--readable-p)
        cmacs-journal-lql-days
        (cmacs-journal--day (cmacs-journal--now))))

(defun cmacs-journal--define-lql-source ()
  "Define the LQL `activity' source, when this cmacs has LQL."
  (when (and (fboundp 'cmacs-lql-available-p) (cmacs-lql-available-p))
    (cmacs-lql-define-source
     "activity" cmacs-journal--lql-columns #'cmacs-journal--lql-rows
     "The activity journal: spans of focused windows, buffers and URLs.")
    (cmacs-lql-set-source-generation
     "activity" #'cmacs-journal--lql-generation)
    ;; CMACS redact: these rows went through the rule set when they were
    ;; recorded, and an agent gets none of them unless allowed.  Putting
    ;; them through it again would apply every `replace' twice.
    (when (fboundp 'cmacs-lql-set-source-redaction)
      (cmacs-lql-set-source-redaction "activity" 'none))))

(with-eval-after-load 'cmacs-lql
  (cmacs-journal--define-lql-source))

(provide 'cmacs-journal)

;;; cmacs-journal.el ends here
