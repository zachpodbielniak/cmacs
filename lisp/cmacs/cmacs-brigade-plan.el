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
