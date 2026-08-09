;;; cmacs-brigade-plan.el --- Org files as brigade plans  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A plan is an org file.  Headlines are tasks, the body is the prompt,
;; properties carry the agent and its budget, and the TODO keyword shows
;; what is happening.  org-agenda, org-clock, refile, capture, export and
;; git history then work on it for free -- which is the whole reason the
;; plan is a file and not a data structure.
;;
;; The risk with two representations is drift, and the design that avoids
;; it is *disjoint field ownership*:
;;
;;   Org owns INTENT   title, body, :AGENT:, :MODEL:, :BUDGET:, :TOOLS:,
;;                     :ISOLATION:, :DEPENDS:, tags, priority.
;;                     C never writes these.
;;
;;   C owns RUNTIME    state, turns, tokens, cost, timestamps, error.
;;                     Rendered into :BRIGADE-*: properties.
;;                     Elisp never sets these except through a DEFUN.
;;
;; Nothing is owned twice, so there is no merge and no last-write-wins.
;;
;; The TODO keyword looks like an exception and is not.  Outbound it is a
;; projection of the C state.  Inbound it is a *command*: a human typing
;; C-c C-t is requesting a transition, and the C state machine decides
;; whether that request is legal.  Marking a running task DONE is refused
;; and the keyword restored, because obeying it would orphan a live agent
;; that is still spending money.
;;
;; Three rules that came out of thinking about what a person is actually
;; doing when this fires:
;;
;;   - Renders are queued, never applied mid-keystroke.  An idle timer
;;     drains them, and an entry the user is editing is deferred.
;;   - Headlines are never reordered.  Order is human-owned, permanently;
;;     re-sorting someone's buffer under them is the most destructive
;;     thing this code could do.
;;   - A stale buffer refuses to render.  If the file changed on disk --
;;     git pull, another machine -- writing into it would silently
;;     discard whatever arrived.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-agent-def)
(require 'cmacs-brigade-agent-def)
(require 'org)
(require 'org-id nil 'noerror)
(require 'cl-lib)
(require 'subr-x)

(defcustom cmacs-brigade-plan-directory
  (expand-file-name "brigade" cmacs-brigade-state-dir)
  "Default directory for new plan files."
  :type 'directory
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-plan-render-idle 0.4
  "Seconds of idle time before queued renders are applied.

Renders wait rather than landing immediately so nothing rewrites the
buffer between two keystrokes."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-plan-write-when-closed t
  "Whether to write runtime updates into a plan file that is not open.

The common case once agents are running is that the buffer has been
killed.  With this off, the org file simply stops reflecting reality --
which is drift by another name."
  :type 'boolean
  :group 'cmacs-brigade)

(define-error 'cmacs-brigade-plan-error
  "Brigade plan error" 'cmacs-brigade-error)


;;;; Keywords
;;
;; A plan file declares its own #+TODO line so these never collide with
;; whatever `org-todo-keywords' the user has globally.

(defconst cmacs-brigade-plan-todo-line
  "#+TODO: TODO(t) NEXT(n) INPROGRESS(i) WAIT(w) HOLD(h) | DONE(d) FAILED(f) CANCELLED(c)"
  "The TODO declaration written into every plan file.")

(defconst cmacs-brigade-plan-state->keyword
  '((draft         . "TODO")
    (queued        . "NEXT")
    (starting      . "INPROGRESS")
    (running       . "INPROGRESS")
    (waiting-input . "WAIT")
    (blocked       . "HOLD")
    (interrupted   . "HOLD")
    (done          . "DONE")
    (failed        . "FAILED")
    (over-budget   . "FAILED")
    (cancelled     . "CANCELLED"))
  "How a runtime state is shown.  Several states share a keyword; the
exact one is always in :BRIGADE-STATE:, which is what the dashboard and
any program should read.")

(defconst cmacs-brigade-plan-keyword->command
  '(("NEXT"       . queued)
    ("TODO"       . draft)
    ("CANCELLED"  . cancelled)
    ("HOLD"       . blocked)
    ("INPROGRESS" . running)
    ("WAIT"       . waiting-input)
    ("DONE"       . done)
    ("FAILED"     . failed))
  "What a human means by setting each keyword.

The C state machine decides whether the request is legal from where the
task actually is; this table only says what was asked for.")

(defun cmacs-brigade-plan--keyword-for (state)
  (or (alist-get state cmacs-brigade-plan-state->keyword) "TODO"))


;;;; Reading intent out of the buffer

(defun cmacs-brigade-plan--entry-id (&optional create)
  "Return this entry's stable id, creating one with CREATE.

Prefers org's own :ID:, so `org-id-goto', `org-store-link' and refile all
keep working; falls back to :BRIGADE-ID: when org-id is unavailable."
  (or (org-entry-get nil "ID")
      (org-entry-get nil "BRIGADE-ID")
      (when create
        (if (fboundp 'org-id-get-create)
            (org-id-get-create)
          (let ((id (format "brigade-%s" (substring (org-id-uuid) 0 8))))
            (org-entry-put nil "BRIGADE-ID" id)
            id)))))

(defun cmacs-brigade-plan--read-entry ()
  "Return the intent fields of the entry at point, as a plist."
  (list :id       (cmacs-brigade-plan--entry-id)
        :title    (org-get-heading t t t t)
        :keyword  (org-get-todo-state)
        :agent    (org-entry-get nil "AGENT")
        :model    (org-entry-get nil "MODEL")
        :budget   (org-entry-get nil "BUDGET")
        :tools    (org-entry-get nil "TOOLS")
        :isolation (org-entry-get nil "ISOLATION")
        :depends  (org-entry-get nil "DEPENDS")
        :prompt   (cmacs-brigade-plan--entry-body)))

(defun cmacs-brigade-plan--entry-body ()
  "Return the entry's body text, without drawers or child headlines."
  (save-excursion
    (org-back-to-heading t)
    (let ((end (save-excursion (org-end-of-subtree t t)))
          (start (progn (forward-line 1)
                        (while (looking-at-p "^[ \t]*\\(:[A-Z]+:\\|CLOCK:\\|SCHEDULED:\\|DEADLINE:\\)")
                          (if (looking-at-p "^[ \t]*:\\(PROPERTIES\\|LOGBOOK\\):")
                              (re-search-forward "^[ \t]*:END:" nil t)
                            (forward-line 1))
                          (forward-line 0))
                        (point))))
      (save-restriction
        (narrow-to-region start end)
        (goto-char (point-min))
        ;; stop at the first child headline
        (let ((stop (if (re-search-forward "^\\*+ " nil t)
                        (match-beginning 0)
                      (point-max))))
          (string-trim (buffer-substring-no-properties (point-min) stop)))))))


;;;; Adopt: org -> C

(defvar-local cmacs-brigade-plan--suppress nil
  "Bound while rendering, so the save hook does not bounce back.")

(defun cmacs-brigade-plan-adopt (&optional buffer)
  "Register every task in BUFFER with the runtime, and apply any commands.

Returns a list of per-task results.  Each is a plist with :id and either
:state or :rejected plus a :reason.

Duplicate ids -- which happen the moment someone copies a subtree -- get
a fresh id for the second occurrence in buffer order.  That matches what
the person meant: they wanted another task, not a second view of the
same one."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (unless (derived-mode-p 'org-mode)
      (signal 'cmacs-brigade-plan-error (list "not an org buffer")))
    (let ((plan (or (buffer-file-name) (buffer-name)))
          (seen (make-hash-table :test 'equal))
          results)
      (org-map-entries
       (lambda ()
         (when (cmacs-brigade-plan--task-p)
           (let* ((id (cmacs-brigade-plan--entry-id 'create)))
             (when (gethash id seen)
               ;; A copied subtree brought its id along.  Mint a new one
               ;; rather than letting two headlines share runtime state.
               (org-entry-delete nil "ID")
               (org-entry-delete nil "BRIGADE-ID")
               (setq id (cmacs-brigade-plan--entry-id 'create)))
             (puthash id t seen)
             (push (cmacs-brigade-plan--adopt-entry id plan) results))))
       nil 'file)
      (nreverse results))))

(defun cmacs-brigade-plan--task-p ()
  "Non-nil if the entry at point is a brigade task.

A plan file is still an org file: prose headlines, notes and headings
that merely group things are not tasks, and treating them as such would
put a runtime record behind every heading someone wrote."
  (or (org-entry-get nil "AGENT")
      (member "brigade" (org-get-tags nil t))))

(defun cmacs-brigade-plan--effective-agent (entry id)
  "Return the agent name for ENTRY, deriving one if it overrides anything.

A string, not a symbol: `cmacs-brigade-task-adopt\=' is a C DEFUN that
takes the agent as a string, and handing it a symbol stores nil -- the
task then runs with no agent at all, which looks exactly like having
forgotten to set one."
  (let* ((base (plist-get entry :agent))
         (name
    (condition-case err
        (cmacs-brigade-agent-derive
         base (substring id 0 (min 8 (length id)))
         (list :model (plist-get entry :model)
               :tools (cmacs-brigade-plan--tools (plist-get entry :tools))
               ;; 0 means "no ceiling", which is what not setting one
               ;; means too -- so it is not an override, and treating it
               ;; as one would derive an agent for every task the
               ;; template produces.
               :budget-usd (when-let* ((b (plist-get entry :budget))
                                       (n (string-to-number b))
                                       ((> n 0)))
                             n)
               :isolation (when-let* ((i (plist-get entry :isolation)))
                            (intern i))))
      ;; An unknown base agent is reported by the runner with a clear
      ;; message; refusing to adopt here would hide the task entirely and
      ;; leave nothing on screen to fix.
      (cmacs-brigade-agent-error
       (ignore err)
       (and base (if (stringp base) (intern base) base))))))
    (and name (format "%s" name))))

(defun cmacs-brigade-plan--tools (s)
  "Parse a :TOOLS: property S into a list of symbols."
  (when (and s (not (string-empty-p (string-trim s))))
    (mapcar #'intern (split-string s "[, \t]+" t))))

(defvar cmacs-brigade-plan--prompt-cache (make-hash-table :test 'equal)
  "Task id -> prompt, filled at adopt.

A cache, not the record: the plan file owns the prompt.  This only
covers plans that have no file to re-read -- an adopted buffer that was
never saved -- and saves a file read on the common path.")

(defun cmacs-brigade-plan-task-property (plan id property)
  "Return PROPERTY of task ID in PLAN, or nil.

Read back from the org file for the same reason the prompt is: the
runtime record is C-owned and holds runtime fields only, and anything the
human wrote is intent."
  (when (and plan (stringp plan) (file-readable-p plan))
    (with-current-buffer (find-file-noselect plan)
      (save-excursion
        (when-let* ((marker (gethash id (cmacs-brigade-plan--id-index))))
          (goto-char marker)
          (org-entry-get nil property))))))

(defun cmacs-brigade-plan-task-prompt (plan id)
  "Return the prompt body for task ID in PLAN.

Read back from the org file rather than carried on the runtime record:
the record is C-owned and holds runtime fields only, and the prompt is
intent.  Falls back to what adopt saw, for a plan with no file."
  (or (and plan (stringp plan) (file-readable-p plan)
           (with-current-buffer (find-file-noselect plan)
             (save-excursion
               (let ((marker (gethash id (cmacs-brigade-plan--id-index))))
                 (when marker
                   (goto-char marker)
                   (cmacs-brigade-plan--entry-body))))))
      (gethash id cmacs-brigade-plan--prompt-cache)))

(defun cmacs-brigade-plan--number (raw)
  "RAW as an integer, or nil when it is missing or not a number."
  (and (stringp raw) (string-match-p "\\`[0-9.]+\\'" raw)
       (truncate (string-to-number raw))))

(defun cmacs-brigade-plan--restore-entry (id)
  "Put the runtime figures recorded on the entry at point back into ID.

Returns the restored record, or nil when the entry carries no
`:BRIGADE-STATE:' -- which is the normal case for a task nobody has run
yet, and means there is nothing to restore."
  (when-let* ((shown (org-entry-get nil "BRIGADE-STATE"))
              (state (intern (string-trim shown))))
    (let* ((tokens (org-entry-get nil "BRIGADE-TOKENS"))
           (split (and tokens (string-match "\\`\\([0-9]+\\)/\\([0-9]+\\)\\'"
                                            tokens)))
           (in (and split (string-to-number (match-string 1 tokens))))
           (out (and split (string-to-number (match-string 2 tokens))))
           (cost (org-entry-get nil "BRIGADE-COST")))
      (cmacs-brigade-task-restore
       id state
       (cmacs-brigade-plan--number (org-entry-get nil "BRIGADE-TURNS"))
       in out
       ;; Written as dollars with four decimals; the runtime counts
       ;; integer micro-dollars, because a figure a budget acts on must
       ;; not drift.
       (and (stringp cost) (round (* 1000000 (string-to-number cost))))
       (org-entry-get nil "BRIGADE-ERROR")))))

(defun cmacs-brigade-plan--adopt-entry (id plan)
  "Adopt the entry at point under ID, applying any pending command."
  (let* ((entry (cmacs-brigade-plan--read-entry))
         ;; :MODEL:, :TOOLS:, :BUDGET: and :ISOLATION: on the headline are
         ;; intent, and have to reach the runner.  The runtime record
         ;; carries only an agent name, so the overrides are baked into a
         ;; derived agent and the record points at that.  With no
         ;; overrides this returns the plain agent name and registers
         ;; nothing.
         (agent (cmacs-brigade-plan--effective-agent entry id))
         (record (cmacs-brigade-task-adopt id plan agent
                                           (plist-get entry :title)))
         (_ (puthash id (plist-get entry :prompt)
                     cmacs-brigade-plan--prompt-cache))
         ;; A record this call created has no runtime history, so the
         ;; state recorded in the file is the best -- and only -- account
         ;; of where the task got to.  Restore it before looking at the
         ;; keyword at all.
         ;;
         ;; Without this, reopening cmacs was destructive: a finished
         ;; task came back as a fresh `draft', its DONE keyword was read
         ;; as a *request* to finish a task that had not started, the
         ;; state machine refused, and the refusal path rewrote the
         ;; headline back to TODO.  The plan lost the outcome it existed
         ;; to record.
         (record (if (plist-get record :created)
                     (or (cmacs-brigade-plan--restore-entry id) record)
                   record))
         (current (plist-get record :state))
         (wanted (alist-get (or (plist-get entry :keyword) "TODO")
                            cmacs-brigade-plan-keyword->command
                            nil nil #'equal)))
    (if (or (null wanted) (eq wanted current))
        (list :id id :state current)
      ;; The keyword differs from the runtime state, so the human asked
      ;; for something.  Ask C; it may say no.
      (let ((res (cmacs-brigade-task-transition id wanted)))
        (if (plist-get res :rejected)
            (progn
              ;; Put the keyword back.  Leaving it would show a state the
              ;; task is not in, which is worse than refusing the edit.
              (cmacs-brigade-plan--set-keyword current)
              (list :id id :rejected t :reason (plist-get res :reason)
                    :state current))
          (list :id id :state (plist-get res :state)))))))

(defun cmacs-brigade-plan--set-keyword (state)
  "Set the TODO keyword at point to STATE's projection, quietly."
  (let ((org-after-todo-state-change-hook nil)
        (cmacs-brigade-plan--suppress t))
    (org-todo (cmacs-brigade-plan--keyword-for state))))


;;;; Writing a task into a plan
;;
;; The one place a new task headline is composed.  Voice dictation, the
;; compose transient and a clone all arrive here, so the shape of a task
;; on disk is decided once rather than in each caller -- three
;; hand-written copies of this had already drifted apart on whether the
;; tag went on, how the body was indented, and whether the file was
;; created if missing.

(defun cmacs-brigade-plan-ensure-file (file &optional title)
  "Return plan FILE, creating an empty plan titled TITLE if it is absent.

The `#+TODO\=' line goes in at creation so a plan's keywords never depend
on the reader\='s global `org-todo-keywords\='."
  (unless (file-exists-p file)
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert "#+title: " (or title (file-name-base file)) "\n"
              cmacs-brigade-plan-todo-line "\n\n")))
  file)

(defun cmacs-brigade-plan--headline-text (title)
  "TITLE reduced to something that can be one org headline.

Newlines and leading stars are the two characters that would turn a
title into structure rather than text; a title long enough to hide the
properties after it is truncated."
  (let ((one (string-trim
              (replace-regexp-in-string
               "\\`\\*+" "" (replace-regexp-in-string
                             "[ \t\n\r]+" " " (or title ""))))))
    (cond ((string-empty-p one) "Untitled task")
          ((<= (length one) 70) one)
          (t (concat (substring one 0 67) "...")))))

(defun cmacs-brigade-plan--body-text (prompt)
  "PROMPT indented so no line of it can be read as org structure.

A prompt is prose the user wrote, and prose contains lines starting with
`*\=' -- a bullet list, a shell glob, a footnote.  At column zero org
reads that as a headline and the rest of the prompt silently becomes a
separate task."
  (mapconcat (lambda (line) (concat "  " line))
             (split-string (string-trim (or prompt "")) "\n")
             "\n"))

(defun cmacs-brigade-plan-append-task (file spec)
  "Append SPEC to plan FILE as a new task, adopt it, and return its id.

SPEC is a plist of intent: :title and :prompt, plus any of :agent,
:model, :budget, :tools, :isolation, :cwd, and :properties (an alist of
further PROPERTY . VALUE pairs written verbatim).  :tools may be a list
or an already-joined string.

The id is minted by org, so the task is addressable by `org-id-goto\=' and
survives a refile."
  (cmacs-brigade-plan-ensure-file file (plist-get spec :title))
  (let ((props (cmacs-brigade-plan--task-properties spec))
        (id nil))
    (with-current-buffer (find-file-noselect file)
      (unless (derived-mode-p 'org-mode)
        (signal 'cmacs-brigade-plan-error (list "not an org file" file)))
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* TODO %s  :brigade:\n"
                        (cmacs-brigade-plan--headline-text
                         (plist-get spec :title))))
        (when props
          (insert "  :PROPERTIES:\n")
          (dolist (p props)
            (insert (format "  :%s:  %s\n" (car p) (cdr p))))
          (insert "  :END:\n"))
        (let ((body (cmacs-brigade-plan--body-text (plist-get spec :prompt))))
          (unless (string-empty-p (string-trim body))
            (insert body "\n")))
        (org-back-to-heading t)
        (setq id (cmacs-brigade-plan--entry-id 'create)))
      (save-buffer)
      (cmacs-brigade-plan-adopt))
    id))

(defun cmacs-brigade-plan--task-properties (spec)
  "The property drawer entries SPEC asks for, as an alist.

An empty value is left out entirely rather than written blank: an empty
:MODEL: is not the same request as no :MODEL:, and the runner reads the
absent one as \"whatever the agent definition says\"."
  (let ((out nil))
    (dolist (pair '((:agent . "AGENT") (:model . "MODEL")
                    (:budget . "BUDGET") (:isolation . "ISOLATION")))
      (let ((v (plist-get spec (car pair))))
        (when (and v (not (equal v "")))
          (push (cons (cdr pair) (format "%s" v)) out))))
    (let ((tools (plist-get spec :tools)))
      (when tools
        (let ((s (if (stringp tools)
                     tools
                   (mapconcat (lambda (x) (format "%s" x)) tools ", "))))
          (unless (string-empty-p (string-trim s))
            (push (cons "TOOLS" s) out)))))
    ;; Abbreviated on the way in, expanded on the way out (see
    ;; `cmacs-brigade--task-cwd'), so the plan stays readable.
    (when-let* ((cwd (plist-get spec :cwd)))
      (unless (string-empty-p (format "%s" cwd))
        (push (cons "CWD" (abbreviate-file-name
                           (file-name-as-directory
                            (expand-file-name (format "%s" cwd)))))
              out)))
    (dolist (extra (plist-get spec :properties))
      (when (and (cdr extra) (not (equal (cdr extra) "")))
        (push (cons (car extra) (format "%s" (cdr extra))) out)))
    (nreverse out)))

(defun cmacs-brigade-plan-read-task (plan id)
  "Return the intent fields of task ID in PLAN, as a plist, or nil.

What a human wrote, not what the runtime made of it -- so a task whose
per-task overrides produced a derived agent reads back as the base agent
it was written with.  This is what a clone copies."
  (when (and plan (stringp plan) (file-readable-p plan))
    (with-current-buffer (find-file-noselect plan)
      (save-excursion
        (when-let* ((marker (gethash id (cmacs-brigade-plan--id-index))))
          (goto-char marker)
          (append (cmacs-brigade-plan--read-entry)
                  (list :cwd (org-entry-get nil "CWD")
                        :plan (buffer-file-name))))))))


;;;; Render: C -> org
;;
;; C never touches the buffer.  It hands over records and this applies
;; them, to the runtime properties only.

(defvar cmacs-brigade-plan--pending (make-hash-table :test 'equal)
  "PLAN -> list of records waiting to be rendered.")

(defvar cmacs-brigade-plan--timer nil)

(defun cmacs-brigade-plan-queue-render (plan records)
  "Queue RECORDS to be rendered into PLAN when the user is idle."
  (puthash plan (append (gethash plan cmacs-brigade-plan--pending) records)
           cmacs-brigade-plan--pending)
  (unless cmacs-brigade-plan--timer
    (setq cmacs-brigade-plan--timer
          (run-with-idle-timer cmacs-brigade-plan-render-idle nil
                               #'cmacs-brigade-plan--drain))))

(defun cmacs-brigade-plan--drain ()
  "Apply every queued render."
  (setq cmacs-brigade-plan--timer nil)
  (let ((plans (hash-table-keys cmacs-brigade-plan--pending)))
    (dolist (plan plans)
      (let ((records (gethash plan cmacs-brigade-plan--pending)))
        (remhash plan cmacs-brigade-plan--pending)
        (condition-case err
            (cmacs-brigade-plan-render plan records)
          (error
           (message "cmacs-brigade: render of %s failed: %s"
                    (file-name-nondirectory plan)
                    (error-message-string err))))))))

(cl-defun cmacs-brigade-plan-render (plan records)
  "Write RECORDS' runtime fields into PLAN.  Returns the number applied."
  (let ((buf (or (find-buffer-visiting plan)
                 (and cmacs-brigade-plan-write-when-closed
                      (file-exists-p plan)
                      (find-file-noselect plan)))))
    (unless buf (cl-return-from cmacs-brigade-plan-render 0))
    (with-current-buffer buf
      ;; A buffer whose file changed underneath us must not be written:
      ;; saving would discard whatever arrived from git or another
      ;; machine, and the runtime data is reconstructible while the
      ;; user's edits are not.
      (when (and (buffer-file-name) (not (verify-visited-file-modtime buf)))
        (message "cmacs-brigade: %s changed on disk; revert to resume updates"
                 (file-name-nondirectory plan))
        (cl-return-from cmacs-brigade-plan-render 0))
      (when (save-excursion (goto-char (point-min))
                            (re-search-forward "^<<<<<<< " nil t))
        (message "cmacs-brigade: %s has conflict markers; not writing"
                 (file-name-nondirectory plan))
        (cl-return-from cmacs-brigade-plan-render 0))
      (let ((applied 0)
            (index (cmacs-brigade-plan--id-index))
            (cmacs-brigade-plan--suppress t))
        (atomic-change-group
          (dolist (r records)
            (let ((marker (gethash (plist-get r :id) index)))
              (when (and marker (marker-position marker))
                (save-excursion
                  (goto-char marker)
                  (cmacs-brigade-plan--apply-record r)
                  (setq applied (1+ applied)))))))
        (when (and (> applied 0) (buffer-file-name) (buffer-modified-p))
          (save-buffer))
        applied))))

(defun cmacs-brigade-plan--id-index ()
  "Return a hash of task id -> marker for the current buffer."
  (let ((index (make-hash-table :test 'equal)))
    (org-map-entries
     (lambda ()
       (let ((id (cmacs-brigade-plan--entry-id)))
         (when id (puthash id (point-marker) index))))
     nil 'file)
    index))

(defun cmacs-brigade-plan--apply-record (record)
  "Write RECORD's runtime fields into the entry at point.

Only :BRIGADE-* properties and the TODO keyword are touched.  Headlines
are never moved or reordered -- order is the human's."
  (let ((state (plist-get record :state)))
    (org-entry-put nil "BRIGADE-STATE" (format "%s" state))
    (org-entry-put nil "BRIGADE-TURNS" (format "%s" (plist-get record :turns)))
    (org-entry-put nil "BRIGADE-TOKENS"
                   (format "%s/%s" (plist-get record :in-tokens)
                           (plist-get record :out-tokens)))
    (org-entry-put nil "BRIGADE-COST"
                   (format "%.4f" (/ (or (plist-get record :cost-micros) 0)
                                     1000000.0)))
    (when (and (plist-get record :started-at)
               (> (plist-get record :started-at) 0))
      (org-entry-put nil "BRIGADE-STARTED"
                     (format-time-string "%FT%T%z"
                                         (plist-get record :started-at))))
    (if (plist-get record :error)
        (org-entry-put nil "BRIGADE-ERROR" (plist-get record :error))
      (org-entry-delete nil "BRIGADE-ERROR"))
    (let ((want (cmacs-brigade-plan--keyword-for state)))
      (unless (equal want (org-get-todo-state))
        (let ((org-after-todo-state-change-hook nil))
          (org-todo want))))))


;;;; Mode

(defun cmacs-brigade-plan--after-save ()
  (unless cmacs-brigade-plan--suppress
    (condition-case err
        (cmacs-brigade-plan-adopt)
      (error (message "cmacs-brigade: %s" (error-message-string err))))))

(defun cmacs-brigade-plan--after-todo ()
  "Translate a manual keyword change into a transition request."
  (unless cmacs-brigade-plan--suppress
    (let ((id (cmacs-brigade-plan--entry-id)))
      (when (and id (cmacs-brigade-plan--task-p))
        (let ((res (cmacs-brigade-plan--adopt-entry
                    id (or (buffer-file-name) (buffer-name)))))
          (when (plist-get res :rejected)
            (message "cmacs-brigade: %s" (plist-get res :reason))))))))

;;;###autoload
(define-minor-mode cmacs-brigade-plan-mode
  "Treat this org buffer as a brigade plan.

Saving adopts the file's tasks into the runtime, and changing a TODO
keyword requests the corresponding transition -- which the state machine
may refuse."
  :lighter " Brigade"
  :group 'cmacs-brigade
  (if cmacs-brigade-plan-mode
      (progn
        (add-hook 'after-save-hook #'cmacs-brigade-plan--after-save nil t)
        (add-hook 'org-after-todo-state-change-hook
                  #'cmacs-brigade-plan--after-todo nil t))
    (remove-hook 'after-save-hook #'cmacs-brigade-plan--after-save t)
    (remove-hook 'org-after-todo-state-change-hook
                 #'cmacs-brigade-plan--after-todo t)))

;;;###autoload
(defun cmacs-brigade-plan-create (file title)
  "Create a plan FILE with TITLE and open it."
  (interactive
   (list (read-file-name "New plan: " (file-name-as-directory
                                       cmacs-brigade-plan-directory))
         (read-string "Plan title: ")))
  (make-directory (file-name-directory file) t)
  (find-file file)
  (when (zerop (buffer-size))
    (insert "#+title: " title "\n"
            cmacs-brigade-plan-todo-line "\n\n"
            "* TODO Example task                                    :brigade:\n"
            "  :PROPERTIES:\n"
            "  :AGENT:  researcher\n"
            "  :BUDGET: 0.00\n"
            "  :END:\n"
            "  Describe what this agent should do.  This body is the prompt.\n")
    (save-buffer))
  (cmacs-brigade-plan-mode 1))

;;;; Finding the plans again after a restart
;;
;; The runtime task table is a C hash that does not survive the process.
;; The plans do -- they are org files -- but nothing used to go looking
;; for them, so a fresh cmacs showed an empty dashboard until you
;; happened to open a plan and save it.  Every task you had ever run was
;; still on disk and simply unmentioned.

(defcustom cmacs-brigade-plan-restore-on-start t
  "Whether to adopt the plans on disk when the brigade loads.

Off means the dashboard starts empty until a plan buffer is saved, which
is the behaviour that made finished work look lost."
  :type 'boolean
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-plan-restore-max 200
  "Most plan files to adopt in one restore.

A bound rather than a limit anyone should reach: adopting parses org, and
a directory that has accumulated hundreds of plans should not make
opening the dashboard feel broken.  What was skipped is reported."
  :type 'integer
  :group 'cmacs-brigade)

(defvar cmacs-brigade-plan--restored nil
  "Non-nil once `cmacs-brigade-plan-restore' has run this session.")

(defun cmacs-brigade-plan--well-formed-p ()
  "Whether the current buffer's property drawers are all terminated.

Only the one structural check, and it earns its place: adopting a file
whose `:PROPERTIES:' drawer has no `:END:' -- what a crash or a half
finished sync leaves behind -- does not fail, it *hangs*, somewhere
inside org while an id is being written into a drawer that has no end.
On the startup path that would be indistinguishable from cmacs refusing
to boot, over one truncated file."
  (let ((opens 0) (closes 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*:\\(PROPERTIES\\|END\\):[ \t]*$" nil t)
        (if (equal "END" (match-string 1))
            (setq closes (1+ closes))
          (setq opens (1+ opens)))))
    (= opens closes)))

(defun cmacs-brigade-plan-files (&optional dir)
  "Return the plan files under DIR, or `cmacs-brigade-plan-directory'.

A plan is an org file containing a `:brigade:'-tagged headline whose
property drawers are intact.  Matched by reading the file rather than by
opening it in org-mode: the directory may hold notes, exports and
READMEs, and parsing all of them to discover that they are not plans is
the expensive way to find out.

A file that looks like a plan but is structurally broken is skipped with
a message rather than adopted -- see `cmacs-brigade-plan--well-formed-p'
for why that is not merely tidiness."
  (let ((dir (or dir cmacs-brigade-plan-directory))
        out)
    (when (file-directory-p dir)
      (dolist (f (directory-files-recursively dir "\\.org\\'"))
        (with-temp-buffer
          ;; The tag lives on a headline, so a bounded read from the
          ;; front is enough for any plan that has one.
          (insert-file-contents f nil 0 200000)
          (goto-char (point-min))
          (when (re-search-forward "^\\*+ .*:brigade:" nil t)
            (if (cmacs-brigade-plan--well-formed-p)
                (push f out)
              (message "cmacs-brigade: %s has an unterminated property drawer; skipped"
                       (file-name-nondirectory f)))))))
    (nreverse out)))

;;;###autoload
(defun cmacs-brigade-plan-restore (&optional force)
  "Adopt every plan on disk, restoring each task's recorded state.

Runs once per session; FORCE (interactively, a prefix argument) rescans.
Returns the number of tasks adopted.

Errors in one plan do not stop the others: a single malformed file must
not be able to hide every other task you have."
  (interactive "P")
  (if (and cmacs-brigade-plan--restored (not force))
      0
    (setq cmacs-brigade-plan--restored t)
    (let ((files (cmacs-brigade-plan-files))
          (tasks 0)
          (plans 0))
      (when (> (length files) cmacs-brigade-plan-restore-max)
        (message "cmacs-brigade: %d plan files, adopting the first %d"
                 (length files) cmacs-brigade-plan-restore-max)
        (setq files (seq-take files cmacs-brigade-plan-restore-max)))
      (dolist (file files)
        (condition-case err
            ;; org-id's global tracking is off for the duration.
            ;; Adopting mints an ID for any entry that lacks one, and
            ;; minting one with tracking on sends org-id away to rebuild
            ;; `org-id-locations' -- which means opening and scanning
            ;; every agenda file.  For anyone whose agenda is a notes
            ;; repository that turns starting the editor into a
            ;; minutes-long stall, triggered by nothing more than a plan
            ;; entry with a missing id.  Entries that already have one --
            ;; which is all of them, once a plan has been adopted once --
            ;; are unaffected either way.
            (let ((buf (find-buffer-visiting file))
                  (org-id-track-globally nil)
                  (org-agenda-files nil))
              (with-current-buffer (or buf (find-file-noselect file t))
                (unless (derived-mode-p 'org-mode) (org-mode))
                ;; Adopting must not look like an edit: it writes ids
                ;; into entries that lack them, and a plan the user never
                ;; touched should not come back modified.
                (let ((cmacs-brigade-plan--suppress t))
                  (setq tasks (+ tasks (length (cmacs-brigade-plan-adopt))))
                  (when (buffer-modified-p) (save-buffer)))
                (setq plans (1+ plans))
                ;; Only close what we opened.  Killing a buffer the user
                ;; already had open would be a surprising thing for a
                ;; refresh to do.
                (unless buf (kill-buffer))))
          (error (message "cmacs-brigade: could not adopt %s: %s"
                          (file-name-nondirectory file)
                          (error-message-string err)))))
      (when (called-interactively-p 'any)
        (message "cmacs-brigade: %d task(s) from %d plan(s)" tasks plans))
      tasks)))


;;;; Keeping the plan up to date
;;
;; The render machinery below existed in full -- modtime checks, conflict
;; markers, atomic writes, closed-file handling -- and had no callers, so
;; a plan never learned what became of its tasks.  Advice on the
;; transition point rather than a call at each site: the runner, the
;; dashboard and the plan buffer all transition tasks, and observing the
;; one function covers callers added later too.

(defun cmacs-brigade-plan--note-transition (result &rest _)
  "Queue a render of the plan RESULT belongs to."
  (when (and (listp result) (plist-get result :id) (plist-get result :plan))
    (cmacs-brigade-plan-queue-render (plist-get result :plan) (list result)))
  result)

(advice-add 'cmacs-brigade-task-transition :filter-return
            #'cmacs-brigade-plan--note-transition)
(advice-add 'cmacs-brigade-task-progress :filter-return
            #'cmacs-brigade-plan--note-transition)
(advice-add 'cmacs-brigade-task-progress-add :filter-return
            #'cmacs-brigade-plan--note-transition)

;;;###autoload
(defun cmacs-brigade-plan-lint (&optional buffer)
  "Report disagreements between BUFFER and the runtime.

Answers the question \"has this drifted\" directly, rather than leaving
it to be inferred from a dashboard that looks wrong."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (let (issues)
      (org-map-entries
       (lambda ()
         (when (cmacs-brigade-plan--task-p)
           (let* ((id (cmacs-brigade-plan--entry-id))
                  (rec (and id (cmacs-brigade-task-get id)))
                  (shown (org-entry-get nil "BRIGADE-STATE"))
                  (kw (org-get-todo-state)))
             (cond
              ((null id) (push (format "%s: no id" (org-get-heading t t t t))
                               issues))
              ((null rec) (push (format "%s: not adopted" id) issues))
              ((and shown (not (equal shown (format "%s" (plist-get rec :state)))))
               (push (format "%s: property says %s, runtime says %s"
                             id shown (plist-get rec :state)) issues))
              ((not (equal kw (cmacs-brigade-plan--keyword-for
                               (plist-get rec :state))))
               (push (format "%s: keyword %s does not match state %s"
                             id kw (plist-get rec :state)) issues))))))
       nil 'file)
      (setq issues (nreverse issues))
      (if (null issues)
          (progn (when (called-interactively-p 'any)
                   (message "cmacs-brigade: plan and runtime agree"))
                 nil)
        (when (called-interactively-p 'any)
          (message "cmacs-brigade: %d disagreement(s):\n%s"
                   (length issues) (string-join issues "\n")))
        issues))))

(provide 'cmacs-brigade-plan)

;;; cmacs-brigade-plan.el ends here
