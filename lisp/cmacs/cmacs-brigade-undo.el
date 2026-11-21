;;; cmacs-brigade-undo.el --- Undo for agent actions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; "Undo what the agent just did."
;;
;; Every capability runs through one dispatch point,
;; `cmacs-brigade-call-tool' / `cmacs-brigade-call-tool-async'
;; (cmacs-brigade-tools.el), which is reached from MCP, D-Bus
;; forwarding, the `emacsctl tool' verbs, in-process agents and bacon.
;; That is where this file hooks in, and it does three things there:
;;
;;   1. BEFORE the handler, it asks the tool's `:undo' declaration
;;      (`cmacs-brigade-deftool') for an UNDO RECORD: plain data about
;;      the state the call is about to change, plus the functions that
;;      check and restore it.  Capturing before is the only general
;;      way: the result of a call rarely says what was there before it.
;;
;;   2. Around the handler, every buffer the record names gets a change
;;      group (`prepare-change-group' ... `undo-amalgamate-change-group'),
;;      so the agent's edit is ONE entry in that buffer's own undo list
;;      and a plain C-/ there takes it back as a unit.
;;
;;   3. AFTER a successful call, the record is completed (what the
;;      agent left: a hash, a marker range, a geometry) and the call is
;;      put in the ACTION LOG, a bounded in-memory ring.
;;
;; Undoing an entry checks STALENESS first: the world must still be
;; what the agent left (the text between the markers is what it wrote,
;; the file's hash is what it wrote, the window is where it put it).
;; When it is not, the undo is refused with a sentence saying what
;; changed, rather than clobbering the user's later work.  The user (and
;; only the user) has a FORCE variant.
;;
;; What the log never does: write to disk.  Records hold buffer and
;; file contents.  `cmacs-brigade-undo-persist-metadata' opts into a
;; metadata-only journal (ids, times, tools, states), and
;; `cmacs-brigade-undo-backup-large-files' into backup copies of files
;; too large to keep in memory, both under $XDG_STATE_HOME/cmacs/undo
;; (0700).  Both are off by default.
;;
;; A record is a plist.  Keys the machinery reads:
;;
;;   :summary   one line: what undoing this call would do
;;   :object    what the call changed, compared with `equal' -- two
;;              entries with the same object must be undone newest
;;              first (an older one refuses while a newer is undone)
;;   :buffers   buffers to wrap in a change group around the handler
;;   :after     (RECORD RESULT) -> RECORD, nil ("nothing changed after
;;              all") or (irreversible REASON); completes the record
;;   :stale     (RECORD) -> nil when the world is as the agent left it,
;;              else a string saying what changed
;;   :inverse   (RECORD) -> performs the undo; signals on failure
;;   :cleanup   (RECORD) -> releases what the record holds (a backup)
;;
;; plus whatever data its own functions need.  `:groups' is added by
;; the dispatch: (BUFFER TAIL . HEAD) for each change group.
;;
;; Redo is out of scope.  It falls out for free in one place only: an
;; undone buffer edit is itself a change group in that buffer, so C-/
;; there (or `undo-redo') re-applies the agent's edit.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'cmacs-brigade-registry)

(declare-function cmacs-redact-text "cmacs-redact" (string))
(declare-function cmacs-brigade--tool-by-wire "cmacs-brigade-tools"
                  (wire-name))
(declare-function cmacs-capability-load-shipped "cmacs-capability"
                  (lisp-dir))
(declare-function cmacs-brigade-dashboard--record-at-point
                  "cmacs-brigade-dashboard" ())

(defvar cmacs-brigade-current-call)

(defgroup cmacs-brigade-undo nil
  "The action log of agent tool calls, and undoing them."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-undo-")

(defcustom cmacs-brigade-undo-log-size 200
  "How many tool calls the action log keeps.
The oldest entry is dropped (and whatever its undo record held is
released) when a new one would exceed this."
  :type 'integer)

(defcustom cmacs-brigade-undo-max-bytes (* 1024 1024)
  "Largest buffer or file an undo record keeps a copy of, in bytes.
A buffer edit beyond it can still be undone through the buffer's own
undo list while nothing else has changed the buffer; a file beyond it
is irreversible unless `cmacs-brigade-undo-backup-large-files'."
  :type 'integer)

(defcustom cmacs-brigade-undo-backup-large-files nil
  "Non-nil keeps a backup copy of a file too large to hold in memory.
The copy goes to $XDG_STATE_HOME/cmacs/undo (mode 0700, file 0600) and
is deleted when the entry is undone or leaves the log.  Off by default
because the log otherwise never writes anything to disk."
  :type 'boolean)

(defcustom cmacs-brigade-undo-persist-metadata nil
  "Non-nil appends each entry's METADATA to a journal on disk.
One JSON line per event in $XDG_STATE_HOME/cmacs/undo/actions.jsonl:
id, time, tool, agent, task and state.  Never the arguments, the
result or the undo record, which hold buffer and file contents.  Nothing
can be undone from the journal; it is for knowing what happened."
  :type 'boolean)

(defcustom cmacs-brigade-undo-log-all-callers nil
  "Agent names and task ids that `action_log' may show EVERY caller's actions to.
Everyone else sees only their own.  An entry is matched against the
calling agent's name and against its task id."
  :type '(repeat string))

(defvar cmacs-brigade-undo-changed-hook nil
  "Normal hook run when an entry is added to the log or changes state.")

(define-error 'cmacs-brigade-undo-error "Cannot undo")
(define-error 'cmacs-brigade-undo-stale
  "The world changed since; not undoing" 'cmacs-brigade-undo-error)


;;;; The log

(cl-defstruct (cmacs-brigade-action
               (:constructor cmacs-brigade-undo--make-action)
               (:copier nil))
  "One tool call in the action log."
  id         ; integer, increasing
  time       ; `current-time' when the call returned
  tool       ; wire name
  agent      ; the dispatch's AGENT string ("mcp", "dbus", a name...), or nil
  task       ; the brigade task the call belonged to, or nil
  surface    ; mcp | dbus | cli | agent | lisp
  args       ; the argument alist as the caller sent it
  result     ; the result text
  record     ; the undo record plist, or nil
  state      ; done | undone | failed | irreversible | stale | nothing
  reason     ; why it is irreversible / stale / failed, or nil
  object)    ; the record's :object

(defvar cmacs-brigade-undo--log nil
  "The action log, newest first.")

(defvar cmacs-brigade-undo--next-id 0
  "The id the next entry gets.")

(defun cmacs-brigade-undo-log ()
  "Return the action log, newest first (a list of `cmacs-brigade-action')."
  cmacs-brigade-undo--log)

(defun cmacs-brigade-undo-entry (id)
  "Return the log entry with ID, or nil."
  (cl-find id cmacs-brigade-undo--log :key #'cmacs-brigade-action-id))

(defun cmacs-brigade-undo-clear ()
  "Empty the action log, releasing what every record holds."
  (interactive)
  (mapc #'cmacs-brigade-undo--release cmacs-brigade-undo--log)
  (setq cmacs-brigade-undo--log nil)
  (run-hooks 'cmacs-brigade-undo-changed-hook))

(defun cmacs-brigade-undo--release (entry)
  "Run ENTRY's :cleanup, once, ignoring errors."
  (let ((record (cmacs-brigade-action-record entry)))
    (when-let* ((fn (plist-get record :cleanup)))
      (with-demoted-errors "cmacs-brigade-undo: cleanup: %S"
        (funcall fn record))
      (setf (cmacs-brigade-action-record entry)
            (plist-put (copy-sequence record) :cleanup nil)))))

(defun cmacs-brigade-undo--state-dir ()
  "Return $XDG_STATE_HOME/cmacs/undo/, created 0700 on first use."
  (let ((dir (expand-file-name
              "cmacs/undo/"
              (or (getenv "XDG_STATE_HOME") "~/.local/state"))))
    (unless (file-directory-p dir)
      (with-file-modes #o700 (make-directory dir t)))
    (set-file-modes dir #o700)
    dir))

(defun cmacs-brigade-undo--persist (entry)
  "Append ENTRY's metadata to the journal, when that is enabled."
  (when cmacs-brigade-undo-persist-metadata
    (with-demoted-errors "cmacs-brigade-undo: journal: %S"
      (let ((file (expand-file-name "actions.jsonl"
                                    (cmacs-brigade-undo--state-dir)))
            (line (json-serialize
                   (list :id (cmacs-brigade-action-id entry)
                         :time (format-time-string
                                "%FT%T%z" (cmacs-brigade-action-time entry))
                         :tool (cmacs-brigade-action-tool entry)
                         :agent (or (cmacs-brigade-action-agent entry) :null)
                         :task (if (cmacs-brigade-action-task entry)
                                   (format "%s" (cmacs-brigade-action-task
                                                 entry))
                                 :null)
                         :state (symbol-name
                                 (cmacs-brigade-action-state entry))))))
        (with-file-modes #o600
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (concat line "\n") nil file 'append 'silent)))))))

(defun cmacs-brigade-undo--push (entry)
  "Add ENTRY to the log, dropping the oldest beyond the bound."
  (push entry cmacs-brigade-undo--log)
  (let ((keep (max 1 cmacs-brigade-undo-log-size)))
    (when (> (length cmacs-brigade-undo--log) keep)
      (mapc #'cmacs-brigade-undo--release (nthcdr keep cmacs-brigade-undo--log))
      (setq cmacs-brigade-undo--log (take keep cmacs-brigade-undo--log))))
  (cmacs-brigade-undo--persist entry)
  (run-hooks 'cmacs-brigade-undo-changed-hook)
  entry)

(defun cmacs-brigade-undo--set-state (entry state &optional reason)
  "Move ENTRY to STATE with REASON, and tell whoever is watching."
  (setf (cmacs-brigade-action-state entry) state
        (cmacs-brigade-action-reason entry) reason)
  (cmacs-brigade-undo--persist entry)
  (run-hooks 'cmacs-brigade-undo-changed-hook))


;;;; Decisions
;;
;; Every :destructive tool has a decision: an inverse, or a reason it
;; cannot have one.  Most are written on the tool's own deftool form
;; (`:undo').  The tools below are defined in files this round of work
;; did not touch; their decisions live here, keyed by wire name, until
;; their files carry them.  `cmacs-brigade-undo-decision-table' is the
;; generated view of all of it and a test fails on any destructive tool
;; that has none.

(defconst cmacs-brigade-undo-decisions
  '(;; cmacs-brigade-subagent.el / cmacs-brigade-mailbox.el
    ("agent_spawn" . "a started run has already spent its tokens; cancel it with agent_cancel")
    ("agent_cancel" . "a cancelled run cannot be resumed where it stopped")
    ("agent_close" . "a closed conversation cannot be reopened")
    ("agent_drop" . "a dropped run's record is gone")
    ("agent_send" . "a delivered message cannot be taken back")
    ;; cmacs-ai-tools.el
    ("ai_call" . "a model call cannot be taken back (its own tool calls are logged one by one)")
    ("ai_open_chat" . "opens a chat buffer; close it like any other")
    ("ai_prompt" . "a model call cannot be taken back")
    ("generate_image" . "a generated image is a new file; nothing it replaced")
    ;; cmacs-brigade-deliver.el
    ("deliverable_emit" . "a deliverable is delivered once it is emitted")
    ;; cmacs-brigade-desktop.el: input into another program
    ("desktop_click" . "input delivered to another program cannot be taken back")
    ("desktop_key" . "input delivered to another program cannot be taken back")
    ("desktop_launch" . "a started program is not stopped by undo; close its window")
    ("desktop_scroll" . "input delivered to another program cannot be taken back")
    ("desktop_type" . "input delivered to another program cannot be taken back")
    ;; cmacs-imgedit-ai.el
    ("imgedit_prompt" . "a model-driven edit is several edits; use imgedit_undo on the document")
    ;; cmacs-brigade-schedule.el
    ("schedule_create" . "remove the schedule with schedule_delete")
    ("schedule_delete" . "a deleted schedule's definition is gone")
    ("schedule_set_enabled" . "set it back with schedule_set_enabled"))
  "Alist of (WIRE-NAME . REASON): irreversible tools whose files carry no :undo.")

(defun cmacs-brigade-undo--irreversible-reason (decision)
  "If DECISION says irreversible, return its reason (a string); else nil."
  (cond ((eq decision 'irreversible) "irreversible")
        ((and (consp decision) (eq (car decision) 'irreversible))
         (let ((r (cdr decision)))
           (cond ((stringp r) r)
                 ((stringp (car-safe r)) (car r))
                 (t "irreversible"))))))

(defun cmacs-brigade-undo-decision (tool)
  "Return TOOL's undo decision: a function, (irreversible REASON) or nil."
  (or (ignore-errors (cmacs-brigade-tool-undo tool))
      (when-let* ((reason (cdr (assoc (cmacs-brigade-tool-wire-name tool)
                                      cmacs-brigade-undo-decisions))))
        (list 'irreversible reason))))


;;;; Records: helpers every capture uses

(defun cmacs-brigade-undo-compose (&rest records)
  "Return one record doing what all of RECORDS do.
nil elements are dropped; an irreversible one makes the whole
irreversible.  :after and :stale apply to each in turn; :inverse undoes
them in reverse order; the summary joins theirs."
  (let ((records (delq nil records)))
    (cond
     ((null records) nil)
     ((cl-find-if #'cmacs-brigade-undo--irreversible-p records))
     ((null (cdr records)) (car records))
     (t
      (list
       :summary (mapconcat (lambda (r) (plist-get r :summary)) records "; ")
       :object (plist-get (car records) :object)
       :buffers (delete-dups
                 (apply #'append
                        (mapcar (lambda (r) (plist-get r :buffers)) records)))
       :parts records
       :after (lambda (rec result)
                (let ((parts (delq nil
                                   (mapcar
                                    (lambda (r)
                                      (let ((r (plist-put
                                                (copy-sequence r) :groups
                                                (plist-get rec :groups))))
                                        (if-let* ((fn (plist-get r :after)))
                                            (funcall fn r result)
                                          r)))
                                    (plist-get rec :parts)))))
                  (cond ((null parts) nil)
                        ((cl-find-if #'cmacs-brigade-undo--irreversible-p
                                     parts))
                        (t (plist-put rec :parts parts)))))
       :stale (lambda (rec)
                (cl-some (lambda (r)
                           (and (plist-get r :stale)
                                (funcall (plist-get r :stale) r)))
                         (plist-get rec :parts)))
       :inverse (lambda (rec)
                  (dolist (r (reverse (plist-get rec :parts)))
                    (funcall (plist-get r :inverse) r)))
       :cleanup (lambda (rec)
                  (dolist (r (plist-get rec :parts))
                    (when-let* ((fn (plist-get r :cleanup)))
                      (funcall fn r)))))))))

(defun cmacs-brigade-undo--irreversible-p (record)
  "Non-nil when RECORD is an (irreversible ...) answer rather than a record."
  (cmacs-brigade-undo--irreversible-reason record))

(defun cmacs-brigade-undo--stale (fmt &rest args)
  "Signal `cmacs-brigade-undo-stale' with the message FMT and ARGS."
  (signal 'cmacs-brigade-undo-stale (list (apply #'format fmt args))))

(defun cmacs-brigade-undo--bufname (buffer)
  "BUFFER's name, or \"(killed buffer)\"."
  (if (buffer-live-p buffer) (buffer-name buffer) "(killed buffer)"))

(defmacro cmacs-brigade-undo--as-one-change (buffer &rest body)
  "Run BODY in BUFFER as one amalgamated change group.
So the undo itself is one entry in BUFFER's undo list, which C-/ there
re-applies -- the redo that falls out for free."
  (declare (indent 1) (debug t))
  (let ((h (make-symbol "handle")))
    `(with-current-buffer ,buffer
       (let ((,h (prepare-change-group)))
         (unwind-protect
             (progn (activate-change-group ,h) ,@body)
           (accept-change-group ,h)
           (undo-amalgamate-change-group ,h)
           (undo-boundary))))))


;;;;; Change groups around the handler

(defun cmacs-brigade-undo--open-groups (buffers)
  "Start a change group in each live buffer of BUFFERS.
Returns ((BUFFER . HANDLE) ...)."
  (let ((out nil))
    (dolist (b (delete-dups (copy-sequence buffers)))
      (when (buffer-live-p b)
        (with-current-buffer b
          ;; A boundary first, so the agent's group never merges with
          ;; whatever the user typed just before.
          (when (listp buffer-undo-list) (undo-boundary))
          (let ((h (prepare-change-group b)))
            (activate-change-group h)
            (push (cons b h) out)))))
    (nreverse out)))

(defun cmacs-brigade-undo--close-groups (groups)
  "Finish GROUPS from `cmacs-brigade-undo--open-groups'.
Each becomes one amalgamated entry in its buffer's undo list followed
by a boundary.  Returns ((BUFFER TAIL . HEAD) ...): HEAD is the undo
list right after the group, TAIL what it was before -- the group is
everything from HEAD up to (not including) TAIL."
  (let ((out nil))
    (pcase-dolist (`(,b . ,h) groups)
      (when (buffer-live-p b)
        (with-current-buffer b
          (with-demoted-errors "cmacs-brigade-undo: change group: %S"
            (accept-change-group h)
            (undo-amalgamate-change-group h)
            (when (listp buffer-undo-list)
              (let ((head buffer-undo-list))
                (undo-boundary)
                (push (cons b (cons (cdr (assq b h)) head)) out)))))))
    (nreverse out)))

(defun cmacs-brigade-undo--skip-boundaries (list)
  "LIST with its leading nil boundaries removed."
  (while (and (consp list) (null (car list))) (setq list (cdr list)))
  list)

(defun cmacs-brigade-undo--group-segment (buffer group)
  "Return the undo entries of GROUP if BUFFER's undo list still has it intact.
GROUP is (TAIL . HEAD).  Intact means nothing was recorded in BUFFER
since (the list, boundaries aside, still starts at HEAD) and the list
still reaches TAIL (it was not truncated by `undo-limit').  Returns nil
otherwise, and for an empty group."
  (with-current-buffer buffer
    (let ((tail (car group))
          (head (cdr group)))
      (when (and (listp buffer-undo-list)
                 (eq (cmacs-brigade-undo--skip-boundaries buffer-undo-list)
                     (cmacs-brigade-undo--skip-boundaries head)))
        (let ((p head) (seg nil))
          (while (and (consp p) (not (eq p tail)))
            (when (car p) (push (car p) seg))
            (setq p (cdr p)))
          (when (and seg (eq p tail))
            (nreverse seg)))))))


;;;;; Buffer edits

(defun cmacs-brigade-undo--diff-bounds (before after)
  "Return (PREFIX . SUFFIX): how much BEFORE and AFTER share at each end.
The two never overlap, so the changed region of BEFORE is
\[PREFIX, length-SUFFIX) and likewise for AFTER."
  (let* ((lb (length before))
         (la (length after))
         (cmp (compare-strings before nil nil after nil nil))
         (prefix (if (eq cmp t) (min lb la) (1- (abs cmp))))
         (room (- (min lb la) prefix))
         (suffix 0))
    (while (and (< suffix room)
                (eq (aref before (- lb suffix 1))
                    (aref after (- la suffix 1))))
      (setq suffix (1+ suffix)))
    (cons prefix suffix)))

(defun cmacs-brigade-undo-buffer-record (buffer-or-name)
  "Return an undo record for a call about to edit BUFFER-OR-NAME's text.

Keeps the buffer's whole text (up to `cmacs-brigade-undo-max-bytes')
and point.  After the call it narrows that to the region the call
changed, between two markers, so the staleness check is \"the text
between the markers is still what the agent wrote\" -- the user may
edit elsewhere in the buffer meanwhile.  The inverse prefers the
buffer's own undo list, when the change group the dispatch wrapped the
call in is still intact there, and falls back to the snapshot.

nil when there is no such buffer (the call will fail on its own)."
  (when-let* ((buffer (get-buffer buffer-or-name)))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (list :kind 'buffer-edit
              :buffer buffer
              :object (cons 'buffer buffer)
              :buffers (list buffer)
              :summary (format "restore the text of buffer %s"
                               (buffer-name))
              :before (and (<= (buffer-size) cmacs-brigade-undo-max-bytes)
                           (buffer-substring-no-properties
                            (point-min) (point-max)))
              :was-modified (buffer-modified-p)
              :point (point)
              :after #'cmacs-brigade-undo--buffer-after
              :stale #'cmacs-brigade-undo--buffer-stale
              :inverse #'cmacs-brigade-undo--buffer-inverse
              :cleanup #'cmacs-brigade-undo--buffer-cleanup)))))

(defun cmacs-brigade-undo--buffer-after (record _result)
  "Complete the buffer-edit RECORD with what the call left."
  (let ((buffer (plist-get record :buffer)))
    (cond
     ((not (buffer-live-p buffer))
      '(irreversible "the buffer was killed by the call"))
     (t
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (let ((before (plist-get record :before))
                (after (and (plist-get record :before)
                            (buffer-substring-no-properties
                             (point-min) (point-max)))))
            (cond
             ;; Too big to snapshot: the change group is all there is.
             ((null before)
              (append (list :tick (buffer-chars-modified-tick)) record))
             ((equal before after) nil)
             (t
              (pcase-let* ((`(,prefix . ,suffix)
                            (cmacs-brigade-undo--diff-bounds before after))
                           (start (copy-marker (+ (point-min) prefix)))
                           (end (copy-marker (- (point-max) suffix) t)))
                (append
                 (list :tick (buffer-chars-modified-tick)
                       :start start :end end
                       :old-text (substring before prefix
                                            (- (length before) suffix))
                       :new-text (substring after prefix
                                            (- (length after) suffix))
                       :summary
                       (format "restore the text of buffer %s at line %d"
                               (buffer-name)
                               (line-number-at-pos start t)))
                 record)))))))))))

(defun cmacs-brigade-undo--buffer-stale (record)
  "Nil when RECORD's buffer still holds what the call wrote, else why not."
  (let ((buffer (plist-get record :buffer)))
    (cond
     ((not (buffer-live-p buffer))
      (format "buffer %s was killed since"
              (cmacs-brigade-undo--bufname buffer)))
     ((eql (plist-get record :tick)
           (with-current-buffer buffer (buffer-chars-modified-tick)))
      nil)
     ((null (plist-get record :start))
      (format "buffer %s changed since, and is too large to have been \
kept (over %d bytes)" (buffer-name buffer) cmacs-brigade-undo-max-bytes))
     (t
      (with-current-buffer buffer
        (save-restriction
          (widen)
          (let ((start (plist-get record :start))
                (end (plist-get record :end)))
            (unless (and (<= start end)
                         (equal (buffer-substring-no-properties start end)
                                (plist-get record :new-text)))
              (format "the text the agent wrote in buffer %s (line %d) \
was changed since" (buffer-name buffer)
                      (line-number-at-pos start t))))))))))

(defun cmacs-brigade-undo--buffer-inverse (record)
  "Undo the buffer edit RECORD describes."
  (let* ((buffer (plist-get record :buffer))
         (group (cdr (assq buffer (plist-get record :groups))))
         (segment (and (buffer-live-p buffer) group
                       (cmacs-brigade-undo--group-segment buffer group))))
    (unless (buffer-live-p buffer)
      (cmacs-brigade-undo--stale "buffer %s was killed since"
                                 (cmacs-brigade-undo--bufname buffer)))
    (cmacs-brigade-undo--as-one-change buffer
      (save-restriction
        (widen)
        (cond
         ;; The buffer's own undo list still ends with the agent's
         ;; group: undo exactly that, as C-/ would.
         (segment (primitive-undo 1 segment))
         ((plist-get record :start)
          (let ((start (plist-get record :start))
                (end (plist-get record :end)))
            (save-excursion
              (goto-char start)
              (delete-region start end)
              (insert (plist-get record :old-text)))))
         (t (cmacs-brigade-undo--stale
             "buffer %s's undo list no longer ends with the agent's edit, \
and the buffer is too large to have been kept" (buffer-name buffer)))))
      (goto-char (min (max (point-min) (plist-get record :point))
                      (point-max)))
      ;; Back to unmodified when the text is the unmodified text again.
      (when (and (not (plist-get record :was-modified))
                 (plist-get record :before)
                 (= (buffer-size) (length (plist-get record :before)))
                 (save-restriction
                   (widen)
                   (equal (buffer-substring-no-properties
                           (point-min) (point-max))
                          (plist-get record :before))))
        (set-buffer-modified-p nil)))))

(defun cmacs-brigade-undo--buffer-cleanup (record)
  "Release RECORD's markers."
  (dolist (k '(:start :end))
    (when (markerp (plist-get record k))
      (set-marker (plist-get record k) nil))))

(defun cmacs-brigade-undo-created-buffer-record (name)
  "Return a record for a call about to create the buffer NAME.
nil when NAME already exists -- the call does not create it then.  The
inverse kills the buffer, provided nothing changed it after the call."
  (unless (get-buffer name)
    (list :kind 'buffer-created
          :name name
          :object (cons 'buffer-name name)
          :summary (format "kill the buffer %s it created" name)
          :after (lambda (rec _result)
                   (let ((b (get-buffer (plist-get rec :name))))
                     (and b
                          (append (list :buffer b
                                        :tick (buffer-chars-modified-tick b))
                                  rec))))
          :stale (lambda (rec)
                   (let ((b (plist-get rec :buffer)))
                     (cond
                      ((not (buffer-live-p b))
                       (format "buffer %s was already killed"
                               (plist-get rec :name)))
                      ((/= (buffer-chars-modified-tick b) (plist-get rec :tick))
                       (format "buffer %s was changed since it was created"
                               (buffer-name b))))))
          :inverse (lambda (rec)
                     (let ((inhibit-interaction t)
                           (b (plist-get rec :buffer)))
                       (with-current-buffer b (set-buffer-modified-p nil))
                       (unless (kill-buffer b)
                         (error "buffer %s refused to be killed"
                                (plist-get rec :name))))))))

(defun cmacs-brigade-undo-killed-buffer-record (buffer-or-name)
  "Return a record for a call about to kill BUFFER-OR-NAME.
Keeps its name, file, major mode, point, modified flag and -- when it
has unsaved text or no file -- the text itself (up to
`cmacs-brigade-undo-max-bytes').  The inverse visits the file again (or
recreates the buffer), puts unsaved text back and restores point."
  (when-let* ((buffer (get-buffer buffer-or-name)))
    (with-current-buffer buffer
      (let* ((file buffer-file-name)
             (modified (buffer-modified-p))
             (keep-text (or modified (null file))))
        (if (and keep-text (> (buffer-size) cmacs-brigade-undo-max-bytes))
            (list 'irreversible
                  (format "buffer %s has %s and is over %d bytes"
                          (buffer-name)
                          (if file "unsaved changes" "no file")
                          cmacs-brigade-undo-max-bytes))
          (list :kind 'buffer-killed
                :name (buffer-name)
                :file file
                :mode major-mode
                :directory default-directory
                :point (point)
                :modified modified
                :text (and keep-text
                           (save-restriction
                             (widen)
                             (buffer-substring-no-properties
                              (point-min) (point-max))))
                :object (cons 'buffer-name (buffer-name))
                :summary (if file
                             (format "visit %s again%s"
                                     (abbreviate-file-name file)
                                     (if modified ", with its unsaved text"
                                       ""))
                           (format "recreate buffer %s" (buffer-name)))
                :after (lambda (rec _result)
                         ;; `kill-buffer' may have been refused.
                         (and (not (get-buffer (plist-get rec :name)))
                              rec))
                :stale #'cmacs-brigade-undo--killed-stale
                :inverse #'cmacs-brigade-undo--killed-inverse))))))

(defun cmacs-brigade-undo--killed-stale (record)
  "Nil when the buffer of RECORD can be brought back, else why not."
  (let ((name (plist-get record :name))
        (file (plist-get record :file)))
    (cond
     ((get-buffer name) (format "a buffer named %s exists again" name))
     ((and file (null (plist-get record :text))
           (not (file-exists-p file)))
      (format "%s no longer exists" (abbreviate-file-name file))))))

(defun cmacs-brigade-undo--killed-inverse (record)
  "Bring back the buffer RECORD describes."
  (let* ((inhibit-interaction t)
         (file (plist-get record :file))
         (text (plist-get record :text))
         (buffer (if file
                     (find-file-noselect file)
                   (get-buffer-create (plist-get record :name)))))
    (with-current-buffer buffer
      (unless file
        (setq default-directory (plist-get record :directory))
        (let ((mode (plist-get record :mode)))
          (when (and (fboundp mode) (not (eq mode major-mode)))
            (with-demoted-errors "cmacs-brigade-undo: mode: %S"
              (funcall mode)))))
      (when text
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text)))
      (unless (equal (buffer-name) (plist-get record :name))
        (ignore-errors (rename-buffer (plist-get record :name) t)))
      (goto-char (min (max (point-min) (plist-get record :point))
                      (point-max)))
      (set-buffer-modified-p (and (plist-get record :modified) t)))))

(defun cmacs-brigade-undo-point-record (buffer-or-name)
  "Return a record for a call about to move point in BUFFER-OR-NAME.
The inverse moves point back -- in the buffer and in the windows
showing it -- unless point was moved again since."
  (when-let* ((buffer (get-buffer buffer-or-name)))
    (list :kind 'point
          :buffer buffer
          :point (with-current-buffer buffer (point))
          :object (cons 'point buffer)
          :summary (format "move point in %s back" (buffer-name buffer))
          :after (lambda (rec _result)
                   (let ((b (plist-get rec :buffer)))
                     (and (buffer-live-p b)
                          (append (list :point-after
                                        (with-current-buffer b (point)))
                                  rec))))
          :stale (lambda (rec)
                   (let ((b (plist-get rec :buffer)))
                     (cond ((not (buffer-live-p b))
                            (format "buffer %s was killed since"
                                    (cmacs-brigade-undo--bufname b)))
                           ((/= (with-current-buffer b (point))
                                (plist-get rec :point-after))
                            (format "point in %s moved since"
                                    (buffer-name b))))))
          :inverse (lambda (rec)
                     (let ((b (plist-get rec :buffer))
                           (p (plist-get rec :point)))
                       (with-current-buffer b
                         (goto-char (min (max (point-min) p) (point-max))))
                       (dolist (w (get-buffer-window-list b nil t))
                         (set-window-point w p)))))))


;;;;; Files

(defun cmacs-brigade-undo--file-hash (file)
  "The sha256 of FILE's bytes, or nil when it does not exist."
  (when (file-regular-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha256 (current-buffer)))))

(defun cmacs-brigade-undo-file-record (file &optional no-revert)
  "Return a record for a call about to write FILE.

Keeps FILE's previous bytes and modes (or that it did not exist) when
it is no larger than `cmacs-brigade-undo-max-bytes'; beyond that, a
backup copy if `cmacs-brigade-undo-backup-large-files', else the call
is irreversible with a reason.  After the call the record holds the
hash of what the call wrote, and the undo refuses if FILE no longer has
that hash.  The inverse writes the old bytes back (or moves a file the
call created to the trash), then reverts an unmodified buffer visiting
it unless NO-REVERT."
  (let ((file (expand-file-name file)))
    (cond
     ((file-directory-p file)
      (list 'irreversible (format "%s is a directory" file)))
     ((not (file-exists-p file))
      (cmacs-brigade-undo--file-base file nil nil nil no-revert))
     ((not (file-readable-p file))
      (list 'irreversible (format "%s cannot be read to keep a copy" file)))
     (t
      (let ((size (file-attribute-size (file-attributes file))))
        (cond
         ((<= size cmacs-brigade-undo-max-bytes)
          (cmacs-brigade-undo--file-base
           file t
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file)
             (buffer-string))
           nil no-revert))
         (cmacs-brigade-undo-backup-large-files
          (let ((copy (expand-file-name
                       (format "backup-%s-%s"
                               (format-time-string "%s")
                               (md5 (format "%s%s" file (random))))
                       (cmacs-brigade-undo--state-dir))))
            (with-file-modes #o600 (copy-file file copy t))
            (set-file-modes copy #o600)
            (cmacs-brigade-undo--file-base file t nil copy no-revert)))
         (t
          (list 'irreversible
                (format "%s is %d bytes, more than \
`cmacs-brigade-undo-max-bytes' (%d); set \
`cmacs-brigade-undo-backup-large-files' to keep a copy"
                        (abbreviate-file-name file) size
                        cmacs-brigade-undo-max-bytes)))))))))

(defun cmacs-brigade-undo--file-base (file existed bytes backup no-revert)
  "Build the file record for FILE.  See `cmacs-brigade-undo-file-record'.
EXISTED, BYTES (the old content, unibyte), BACKUP (a copy's path) and
NO-REVERT are the captured facts."
  (list :kind 'file
        :file file
        :existed existed
        :bytes bytes
        :backup backup
        :modes (and existed (file-modes file))
        :no-revert no-revert
        :object (cons 'file file)
        :summary (if existed
                     (format "put the previous contents of %s back"
                             (abbreviate-file-name file))
                   (format "move %s, which the call created, to the trash"
                           (abbreviate-file-name file)))
        :after (lambda (rec _result)
                 (append (list :hash (cmacs-brigade-undo--file-hash
                                      (plist-get rec :file)))
                         rec))
        :stale (lambda (rec)
                 (let ((f (plist-get rec :file)))
                   (cond
                    ((not (file-exists-p f))
                     (format "%s was deleted since" (abbreviate-file-name f)))
                    ((not (equal (cmacs-brigade-undo--file-hash f)
                                 (plist-get rec :hash)))
                     (format "%s was changed since the agent wrote it"
                             (abbreviate-file-name f))))))
        :inverse #'cmacs-brigade-undo--file-inverse
        :cleanup (lambda (rec)
                   (when-let* ((copy (plist-get rec :backup)))
                     (when (file-exists-p copy) (delete-file copy))))))

(defun cmacs-brigade-undo--file-inverse (record)
  "Put RECORD's file back as it was."
  (let ((file (plist-get record :file)))
    (cond
     ((not (plist-get record :existed))
      ;; Created by the call: to the trash, not gone -- reversible.
      (let ((delete-by-moving-to-trash t))
        (delete-file file t)))
     ((plist-get record :backup)
      (copy-file (plist-get record :backup) file t))
     (t
      (let ((coding-system-for-write 'no-conversion)
            (write-region-inhibit-fsync t))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert (plist-get record :bytes))
          (write-region (point-min) (point-max) file nil 'silent)))))
    (when (and (plist-get record :existed) (plist-get record :modes))
      (set-file-modes file (plist-get record :modes)))
    (unless (plist-get record :no-revert)
      (when-let* ((b (find-buffer-visiting file)))
        (with-current-buffer b
          (unless (buffer-modified-p)
            (if (file-exists-p file)
                (let ((inhibit-interaction t))
                  (revert-buffer t t t))
              ;; The file is gone; the buffer is now an unsaved copy.
              (set-buffer-modified-p t))))))))


;;;;; Window layout

(defun cmacs-brigade-undo--window-fingerprint (frame)
  "A comparable description of FRAME's window layout."
  (when (frame-live-p frame)
    (mapcar (lambda (w)
              (list (window-buffer w) (window-edges w)
                    (eq w (frame-selected-window frame))))
            (window-list frame 'nomini (frame-first-window frame)))))

(defun cmacs-brigade-undo-window-record (&optional frame)
  "Return a record for a call about to change FRAME's windows.
The layout is kept as data (`window-state-get'); the inverse puts it
back unless the layout was changed again since."
  (let ((frame (or frame (selected-frame))))
    (list :kind 'windows
          :frame frame
          :state (window-state-get (frame-root-window frame) t)
          :object (cons 'frame frame)
          :summary "put the window layout back"
          :after (lambda (rec _result)
                   (append (list :fingerprint
                                 (cmacs-brigade-undo--window-fingerprint
                                  (plist-get rec :frame)))
                           rec))
          :stale (lambda (rec)
                   (let ((f (plist-get rec :frame)))
                     (cond
                      ((not (frame-live-p f)) "the frame was deleted since")
                      ((not (equal (cmacs-brigade-undo--window-fingerprint f)
                                   (plist-get rec :fingerprint)))
                       "the window layout was changed since"))))
          :inverse (lambda (rec)
                     (let ((f (plist-get rec :frame)))
                       (window-state-put (plist-get rec :state)
                                         (frame-root-window f) 'safe))))))


;;;; The dispatch side

(defun cmacs-brigade-undo--surface (agent)
  "The surface a call with the dispatch's AGENT string arrived on."
  (pcase agent
    ("mcp" 'mcp)
    ("dbus" 'dbus)
    ((or "cli" "bacon") 'cli)
    ("menu" 'menu)
    ('nil 'lisp)
    (_ 'agent)))

(defun cmacs-brigade-undo--capture (tool decision args)
  "Run TOOL's capture DECISION on ARGS; return a record or (irreversible ...)."
  (condition-case err
      (let* ((params (cmacs-brigade-tool-params tool))
             (fn (lambda (&rest a) (apply decision a)))
             ;; Structured arguments in the shape the handler gets.
             (fn (if (cl-some #'cmacs-brigade-param-structured-p params)
                     (cmacs-brigade--structured-handler fn params nil)
                   fn)))
        (apply fn args))
    (error
     (list 'irreversible
           (format "the state before the call could not be captured: %s"
                   (error-message-string err))))))

(defun cmacs-brigade-undo--begin (tool args req)
  "Start logging a call of TOOL with the positional ARGS; REQ is its plist.
Called by the dispatch BEFORE the handler.  Returns the pending action
for `cmacs-brigade-undo--end', or nil when the call is not logged at
all: a non-destructive tool with no :undo is a read, and reads are not
actions.  Never signals."
  (condition-case err
      (let* ((decision (cmacs-brigade-undo-decision tool))
             (reason (cmacs-brigade-undo--irreversible-reason decision))
             (fn (and decision (not reason) decision)))
        (when (or fn (cmacs-brigade-tool-destructive tool))
          (let* ((record
                  (cond
                   (fn (let ((cmacs-brigade-current-call req))
                         (cmacs-brigade-undo--capture tool fn args)))
                   (reason (list 'irreversible reason))
                   (t (list 'irreversible "no undo declared"))))
                 (groups (and record
                              (not (cmacs-brigade-undo--irreversible-p record))
                              (cmacs-brigade-undo--open-groups
                               (plist-get record :buffers)))))
            (list :tool tool :req req :record record :groups groups))))
    (error
     (message "cmacs-brigade-undo: not logging %s: %s"
              (cmacs-brigade-tool-wire-name tool)
              (error-message-string err))
     nil)))

(defun cmacs-brigade-undo--summarise-result (result)
  "One line of RESULT, at most 120 characters."
  (let ((line (car (split-string (or result "") "\n"))))
    (truncate-string-to-width (string-trim (or line "")) 120 nil nil "...")))

(defun cmacs-brigade-undo--end (pending result failure)
  "Finish the call PENDING stands for.
With FAILURE non-nil the call failed: its change groups are closed and
nothing is logged.  Otherwise the record is completed with RESULT and
the call joins the log.  Idempotent, and never signals."
  (when (and pending (not (plist-get pending :ended)))
    (nconc pending (list :ended t))
    (condition-case err
        (let ((groups (cmacs-brigade-undo--close-groups
                       (plist-get pending :groups))))
          (unless failure
            (let* ((req (plist-get pending :req))
                   (tool (plist-get pending :tool))
                   (record (plist-get pending :record))
                   (record
                    (if (or (null record)
                            (cmacs-brigade-undo--irreversible-p record))
                        record
                      (let ((rec (append (list :groups groups) record)))
                        (if-let* ((after (plist-get rec :after)))
                            (condition-case e (funcall after rec result)
                              (error
                               (list 'irreversible
                                     (format "the state after the call could \
not be recorded: %s" (error-message-string e)))))
                          rec))))
                   (reason (cmacs-brigade-undo--irreversible-reason record))
                   (agent (plist-get req :agent)))
              (cmacs-brigade-undo--push
               (cmacs-brigade-undo--make-action
                :id (cl-incf cmacs-brigade-undo--next-id)
                :time (current-time)
                :tool (cmacs-brigade-tool-wire-name tool)
                :agent agent
                :task (plist-get req :task)
                :surface (cmacs-brigade-undo--surface agent)
                :args (plist-get req :args)
                :result (cmacs-brigade-undo--summarise-result result)
                :record (and (not reason) record)
                :state (cond (reason 'irreversible)
                             ((null record) 'nothing)
                             (t 'done))
                :reason reason
                :object (and (not reason) (plist-get record :object)))))))
      (error
       (message "cmacs-brigade-undo: could not log a call: %s"
                (error-message-string err))))))


;;;; Who may undo what

(defun cmacs-brigade-undo--caller-label (entry)
  "A short description of who made the call ENTRY records."
  (let ((agent (cmacs-brigade-action-agent entry))
        (task (cmacs-brigade-action-task entry)))
    (concat (or agent "lisp")
            (if task (format " (task %s)" task) ""))))

(defun cmacs-brigade-undo-own-p (entry &optional req)
  "Non-nil when ENTRY was made by the caller REQ describes.
REQ is a dispatch plist (:agent :task), by default the call being
dispatched.  A caller with a task owns exactly that task's entries --
a task id is the editor's own record, never one a client supplies.
Without a task, entries with the same agent and no task: every
external MCP client that is not on a scoped socket shares the agent
\"mcp\", and so shares an identity."
  (let* ((req (or req cmacs-brigade-current-call))
         (task (plist-get req :task))
         (etask (cmacs-brigade-action-task entry)))
    (if (or task etask)
        (and task etask (equal (format "%s" task) (format "%s" etask)))
      (equal (plist-get req :agent) (cmacs-brigade-action-agent entry)))))

(defun cmacs-brigade-undo--newer-conflict (entry)
  "A newer entry, still done, that changed the same object as ENTRY."
  (let ((object (cmacs-brigade-action-object entry)))
    (when object
      (cl-find-if (lambda (e)
                    (and (> (cmacs-brigade-action-id e)
                            (cmacs-brigade-action-id entry))
                         (eq (cmacs-brigade-action-state e) 'done)
                         (equal (cmacs-brigade-action-object e) object)))
                  cmacs-brigade-undo--log))))


;;;; Undoing

(defun cmacs-brigade-undo-describe-entry (entry)
  "One line naming ENTRY: \"#ID TOOL\"."
  (format "#%d %s" (cmacs-brigade-action-id entry)
          (cmacs-brigade-action-tool entry)))

(defun cmacs-brigade-undo-run (entry &optional force)
  "Undo ENTRY and return a message saying so.

Refuses -- signalling `cmacs-brigade-undo-error' (or its child
`cmacs-brigade-undo-stale') with a sentence saying why -- when ENTRY is
already undone, irreversible or had nothing to undo, when a newer
action changed the same thing and is not undone, or when the world no
longer matches what the call left.  FORCE skips those last two checks
and is for the user only: no tool passes it."
  (let ((name (cmacs-brigade-undo-describe-entry entry))
        (record (cmacs-brigade-action-record entry)))
    (pcase (cmacs-brigade-action-state entry)
      ('undone (signal 'cmacs-brigade-undo-error
                       (list (format "%s is already undone" name))))
      ('irreversible
       (signal 'cmacs-brigade-undo-error
               (list (format "%s cannot be undone: %s" name
                             (cmacs-brigade-action-reason entry)))))
      ('nothing (signal 'cmacs-brigade-undo-error
                        (list (format "%s had nothing to undo" name)))))
    (unless force
      (when-let* ((newer (cmacs-brigade-undo--newer-conflict entry)))
        (let ((why (format "%s changed the same thing later; undo it first"
                           (cmacs-brigade-undo-describe-entry newer))))
          (cmacs-brigade-undo--set-state entry 'stale why)
          (signal 'cmacs-brigade-undo-stale
                  (list (format "Not undoing %s: %s" name why)))))
      (when-let* ((check (plist-get record :stale))
                  (why (condition-case err (funcall check record)
                         (error (format "the check failed: %s"
                                        (error-message-string err))))))
        (cmacs-brigade-undo--set-state entry 'stale why)
        (signal 'cmacs-brigade-undo-stale
                (list (format "Not undoing %s: %s" name why)))))
    (condition-case err
        (funcall (plist-get record :inverse) record)
      (cmacs-brigade-undo-stale
       (cmacs-brigade-undo--set-state entry 'stale (cadr err))
       (signal 'cmacs-brigade-undo-stale
               (list (format "Not undoing %s: %s" name (cadr err)))))
      (error
       (let ((why (error-message-string err)))
         (cmacs-brigade-undo--set-state entry 'failed why)
         (signal 'cmacs-brigade-undo-error
                 (list (format "Undoing %s failed: %s" name why))))))
    (cmacs-brigade-undo--set-state entry 'undone (and force "forced"))
    (cmacs-brigade-undo--release entry)
    (format "Undid %s: %s" name (plist-get record :summary))))

(defun cmacs-brigade-undo-run-list (entries &optional stop-at-irreversible)
  "Undo ENTRIES in order; stop at the first that cannot be undone.
Entries that are undone already or had nothing to undo are passed over.
An irreversible one stops the run when STOP-AT-IRREVERSIBLE, and is
passed over (and counted) otherwise.  Returns (MESSAGES . FAILURE):
one message per undone entry, and the sentence that stopped the run,
or nil when every entry was undone."
  (let ((done nil) (failure nil) (skipped 0))
    (catch 'stop
      (dolist (e entries)
        (pcase (cmacs-brigade-action-state e)
          ((or 'undone 'nothing) nil)
          ('irreversible
           (if stop-at-irreversible
               (progn
                 (setq failure
                       (format "Stopped at %s, which cannot be undone: %s"
                               (cmacs-brigade-undo-describe-entry e)
                               (cmacs-brigade-action-reason e)))
                 (throw 'stop nil))
             (setq skipped (1+ skipped))))
          (_
           (condition-case err
               (push (cmacs-brigade-undo-run e) done)
             (cmacs-brigade-undo-error
              (setq failure (cadr err))
              (throw 'stop nil)))))))
    (when (and (> skipped 0) (null failure))
      (push (format "(passed over %d irreversible action%s)"
                    skipped (if (= skipped 1) "" "s"))
            done))
    (cons (nreverse done) failure)))

(defun cmacs-brigade-undo--report (outcome what)
  "Show OUTCOME of `cmacs-brigade-undo-run-list' for WHAT; return it."
  (let ((msgs (car outcome)) (failure (cdr outcome)))
    (cond
     ((and (null msgs) (null failure))
      (message "Nothing to undo for %s" what))
     (failure
      (message "%s%s" (if msgs (concat (string-join msgs "\n") "\n") "")
               failure))
     (t (message "%s" (string-join msgs "\n"))))
    outcome))

(defun cmacs-brigade-undo--undoable (entries)
  "ENTRIES with an undo record that is not undone yet."
  (cl-remove-if-not (lambda (e)
                      (memq (cmacs-brigade-action-state e)
                            '(done stale failed)))
                    entries))

;;;###autoload
(defun cmacs-brigade-undo (&optional n)
  "Undo the last undoable agent action; with prefix N, the last N.
Newest first, stopping at the first that refuses -- because the world
changed since, most often; the message says what changed.  Irreversible
actions in between are passed over and counted.  See
`cmacs-brigade-actions' for the whole log."
  (interactive "p")
  (let ((targets (take (max 1 (or n 1))
                       (cmacs-brigade-undo--undoable
                        cmacs-brigade-undo--log))))
    (cmacs-brigade-undo--report
     (if targets
         (cmacs-brigade-undo-run-list targets)
       (cons nil nil))
     "the action log")))

;;;###autoload
(defun cmacs-brigade-undo-force (id)
  "Undo the logged action ID even though the world changed since.
For the user only, and asks first: this clobbers whatever was done
after the agent's action."
  (interactive
   (list (read-number "Force-undo action #: "
                      (and cmacs-brigade-undo--log
                           (cmacs-brigade-action-id
                            (car cmacs-brigade-undo--log))))))
  (let ((entry (or (cmacs-brigade-undo-entry id)
                   (user-error "No action #%d in the log" id))))
    (when (or (not (called-interactively-p 'any))
              (yes-or-no-p
               (format "Force-undo %s, overwriting what changed since? "
                       (cmacs-brigade-undo-describe-entry entry))))
      (condition-case err
          (message "%s" (cmacs-brigade-undo-run entry 'force))
        (cmacs-brigade-undo-error (user-error "%s" (cadr err)))))))

(defun cmacs-brigade-undo--read-key (prompt key)
  "Read one of the KEY values (agent or task) present in the log, with PROMPT."
  (let ((choices (delete-dups
                  (delq nil
                        (mapcar (lambda (e)
                                  (let ((v (funcall key e)))
                                    (and v (format "%s" v))))
                                cmacs-brigade-undo--log)))))
    (unless choices (user-error "The action log is empty"))
    (completing-read prompt choices nil t)))

;;;###autoload
(defun cmacs-brigade-undo-task (task)
  "Undo everything the brigade task TASK did, newest first.
Stops at the first action that cannot be undone, and says which."
  (interactive (list (cmacs-brigade-undo--read-key
                      "Undo the actions of task: "
                      #'cmacs-brigade-action-task)))
  (cmacs-brigade-undo--report
   (cmacs-brigade-undo-run-list
    (cl-remove-if-not (lambda (e)
                        (equal (format "%s" (cmacs-brigade-action-task e))
                               (format "%s" task)))
                      cmacs-brigade-undo--log)
    'stop)
   (format "task %s" task)))

;;;###autoload
(defun cmacs-brigade-undo-agent (name)
  "Undo everything the agent NAME did, newest first.
NAME is the dispatch's agent string: an in-process agent's name, or
\"mcp\", \"dbus\"... for a surface.  Stops at the first action that
cannot be undone, and says which."
  (interactive (list (cmacs-brigade-undo--read-key
                      "Undo the actions of agent: "
                      #'cmacs-brigade-action-agent)))
  (cmacs-brigade-undo--report
   (cmacs-brigade-undo-run-list
    (cl-remove-if-not (lambda (e)
                        (equal (cmacs-brigade-action-agent e) name))
                      cmacs-brigade-undo--log)
    'stop)
   (format "agent %s" name)))

;;;###autoload
(defun cmacs-brigade-undo-dashboard-task ()
  "In the brigade dashboard, undo everything the task on this line did."
  (interactive)
  (let ((r (and (fboundp 'cmacs-brigade-dashboard--record-at-point)
                (cmacs-brigade-dashboard--record-at-point))))
    (unless r (user-error "No task on this line"))
    (cmacs-brigade-undo-task (plist-get r :id))))


;;;; Showing the log

(defun cmacs-brigade-undo--redact (text strict)
  "TEXT through `cmacs-redact-text'.
With STRICT (a model may read this), a missing redaction file is an
error -- fail closed.  Otherwise it shows TEXT as it is: the user's own
log, in a buffer the user opened."
  (if (if strict (require 'cmacs-redact) (require 'cmacs-redact nil t))
      (cmacs-redact-text text)
    text))

(defun cmacs-brigade-undo--args-text (entry &optional strict width)
  "ENTRY's arguments as one line, redacted; each value cut to WIDTH chars.
STRICT is as for `cmacs-brigade-undo--redact'."
  (mapconcat
   (lambda (cell)
     (format "%s=%s" (car cell)
             (cmacs-brigade-undo--redact
              (truncate-string-to-width
               (replace-regexp-in-string
                "[\n\r\t]+" " "
                (if (stringp (cdr cell)) (cdr cell) (format "%S" (cdr cell))))
               (or width 60) nil nil "...")
              strict)))
   (cmacs-brigade-action-args entry) " "))

(defun cmacs-brigade-undo--state-name (entry)
  "ENTRY's state as a word."
  (pcase (cmacs-brigade-action-state entry)
    ('failed "failed-to-undo")
    ('nothing "nothing-to-undo")
    (s (symbol-name s))))

(defun cmacs-brigade-undo-entry-line (entry &optional strict)
  "ENTRY as one line of text, for `action_log' and the echo area.
STRICT is as for `cmacs-brigade-undo--redact'."
  (let ((record (cmacs-brigade-action-record entry)))
    (format "#%d %s %s %s [%s] %s -> %s%s"
            (cmacs-brigade-action-id entry)
            (format-time-string "%T" (cmacs-brigade-action-time entry))
            (cmacs-brigade-undo--caller-label entry)
            (cmacs-brigade-action-tool entry)
            (cmacs-brigade-undo--state-name entry)
            (cmacs-brigade-undo--args-text entry strict)
            (cmacs-brigade-undo--redact
             (cmacs-brigade-action-result entry) strict)
            (cond
             ((cmacs-brigade-action-reason entry)
              (format " (%s)" (cmacs-brigade-undo--redact
                               (cmacs-brigade-action-reason entry) strict)))
             ((and record (eq (cmacs-brigade-action-state entry) 'done))
              (format " (undo would %s)"
                      (cmacs-brigade-undo--redact
                       (plist-get record :summary) strict)))
             (t "")))))

(defvar cmacs-brigade-actions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'cmacs-brigade-actions-inspect)
    (define-key map (kbd "u") #'cmacs-brigade-actions-undo)
    (define-key map (kbd "U") #'cmacs-brigade-actions-undo-from-here)
    (define-key map (kbd "F") #'cmacs-brigade-actions-force)
    map)
  "Keymap for `cmacs-brigade-actions-mode'.")

(define-derived-mode cmacs-brigade-actions-mode tabulated-list-mode
  "Agent actions"
  "The action log: every destructive tool call agents made, newest first.

\\{cmacs-brigade-actions-mode-map}"
  (setq tabulated-list-format
        [("#" 5 (lambda (a b) (< (car a) (car b))) :right-align t)
         ("Time" 9 t)
         ("Caller" 22 t)
         ("Tool" 26 t)
         ("State" 15 t)
         ("Undo" 0 nil)])
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'cmacs-brigade-actions--refresh nil t)
  (tabulated-list-init-header))

(defun cmacs-brigade-actions--refresh ()
  "Fill `tabulated-list-entries' from the log."
  (setq tabulated-list-entries
        (mapcar
         (lambda (e)
           (let ((record (cmacs-brigade-action-record e)))
             (list (cmacs-brigade-action-id e)
                   (vector (number-to-string (cmacs-brigade-action-id e))
                           (format-time-string
                            "%T" (cmacs-brigade-action-time e))
                           (cmacs-brigade-undo--caller-label e)
                           (cmacs-brigade-action-tool e)
                           (cmacs-brigade-undo--state-name e)
                           (or (cmacs-brigade-action-reason e)
                               (and record (plist-get record :summary))
                               "")))))
         cmacs-brigade-undo--log)))

(defun cmacs-brigade-actions--refresh-buffers ()
  "Refresh every live action-log buffer."
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'cmacs-brigade-actions-mode)
      (with-current-buffer b
        (cmacs-brigade-actions--refresh)
        (tabulated-list-print t)))))

(add-hook 'cmacs-brigade-undo-changed-hook
          #'cmacs-brigade-actions--refresh-buffers)

;;;###autoload
(defun cmacs-brigade-actions ()
  "Show the action log: what agents did, and what undoing each would do."
  (interactive)
  (let ((buf (get-buffer-create "*cmacs agent actions*")))
    (with-current-buffer buf
      (cmacs-brigade-actions-mode)
      (cmacs-brigade-actions--refresh)
      (tabulated-list-print))
    (pop-to-buffer buf)))

(defun cmacs-brigade-actions--entry ()
  "The log entry on this line, or a user error."
  (or (and (tabulated-list-get-id)
           (cmacs-brigade-undo-entry (tabulated-list-get-id)))
      (user-error "No action on this line")))

(defun cmacs-brigade-actions-inspect ()
  "Show everything about the action on this line."
  (interactive)
  (let* ((e (cmacs-brigade-actions--entry))
         (record (cmacs-brigade-action-record e)))
    (with-help-window "*cmacs agent action*"
      (princ (format "Action #%d: %s\n\n" (cmacs-brigade-action-id e)
                     (cmacs-brigade-action-tool e)))
      (princ (format "When:    %s\n" (format-time-string
                                       "%F %T" (cmacs-brigade-action-time e))))
      (princ (format "Caller:  %s (surface %s)\n"
                     (cmacs-brigade-undo--caller-label e)
                     (cmacs-brigade-action-surface e)))
      (princ (format "State:   %s%s\n" (cmacs-brigade-undo--state-name e)
                     (if (cmacs-brigade-action-reason e)
                         (format " -- %s" (cmacs-brigade-action-reason e))
                       "")))
      (princ "\nArguments:\n")
      (dolist (cell (cmacs-brigade-action-args e))
        (princ (format "  %s: %s\n" (car cell)
                       (cmacs-brigade-undo--redact
                        (truncate-string-to-width
                         (if (stringp (cdr cell)) (cdr cell)
                           (format "%S" (cdr cell)))
                         2000 nil nil "...")
                        nil))))
      (princ (format "\nResult:  %s\n" (cmacs-brigade-action-result e)))
      (princ (format "\nUndo:    %s\n"
                     (cond ((eq (cmacs-brigade-action-state e) 'done)
                            (format "would %s" (plist-get record :summary)))
                           (record (plist-get record :summary))
                           (t "nothing to run")))))))

(defun cmacs-brigade-actions-undo ()
  "Undo the action on this line."
  (interactive)
  (condition-case err
      (message "%s" (cmacs-brigade-undo-run (cmacs-brigade-actions--entry)))
    (cmacs-brigade-undo-error (user-error "%s" (cadr err)))))

(defun cmacs-brigade-actions-undo-from-here ()
  "Undo the action on this line and everything its caller did after it.
Newest first, stopping at the first that cannot be undone."
  (interactive)
  (let* ((e (cmacs-brigade-actions--entry))
         (req (list :agent (cmacs-brigade-action-agent e)
                    :task (cmacs-brigade-action-task e))))
    (cmacs-brigade-undo--report
     (cmacs-brigade-undo-run-list
      (cl-remove-if-not
       (lambda (x)
         (and (>= (cmacs-brigade-action-id x) (cmacs-brigade-action-id e))
              (cmacs-brigade-undo-own-p x req)))
       cmacs-brigade-undo--log)
      'stop)
     (cmacs-brigade-undo--caller-label e))))

(defun cmacs-brigade-actions-force ()
  "Force-undo the action on this line, after asking."
  (interactive)
  (let ((e (cmacs-brigade-actions--entry)))
    (when (yes-or-no-p
           (format "Force-undo %s, overwriting what changed since? "
                   (cmacs-brigade-undo-describe-entry e)))
      (condition-case err
          (message "%s" (cmacs-brigade-undo-run e 'force))
        (cmacs-brigade-undo-error (user-error "%s" (cadr err)))))))


;;;; The decision table (generated documentation)

(defun cmacs-brigade-undo--decision-text (decision)
  "Describe DECISION, a tool's undo decision, in a few words."
  (cond
   ((null decision) nil)
   ((cmacs-brigade-undo--irreversible-reason decision))
   ((and (symbolp decision) (fboundp decision))
    (car (split-string (or (documentation decision t) (symbol-name decision))
                       "\n")))
   ((symbolp decision) (symbol-name decision))
   (t (let ((doc (ignore-errors
                   (let ((text-quoting-style 'grave))
                     (documentation decision)))))
        (if (and doc (string-prefix-p "Undo: " doc))
            (substring doc (length "Undo: "))
          "captured by its :undo form")))))

(defun cmacs-brigade-undo-decision-table ()
  "Return every destructive tool's undo decision as data.
A list of (WIRE GROUP KIND TEXT), sorted by wire name: KIND is
`inverse', `nothing' (the capture function carries the
`cmacs-brigade-undo-kind' property `nothing': the call leaves no state
to undo), `irreversible' or `undecided' (a destructive tool with no
:undo and no entry in `cmacs-brigade-undo-decisions', which the tests
refuse)."
  (let ((rows nil))
    (dolist (name (cmacs-brigade-registry-list 'tool))
      (let ((tool (cmacs-brigade-registry-get 'tool name)))
        (when (cmacs-brigade-tool-destructive tool)
          (let* ((decision (cmacs-brigade-undo-decision tool))
                 (reason (cmacs-brigade-undo--irreversible-reason decision)))
            (push (list (cmacs-brigade-tool-wire-name tool)
                        (format "%s" (or (cmacs-brigade-tool-group tool) "-"))
                        (cond ((null decision) 'undecided)
                              (reason 'irreversible)
                              ((and (symbolp decision)
                                    (get decision 'cmacs-brigade-undo-kind)))
                              (t 'inverse))
                        (or (cmacs-brigade-undo--decision-text decision)
                            "NO DECISION"))
                  rows)))))
    (sort rows (lambda (a b) (string< (car a) (car b))))))

(defun cmacs-brigade-undo-table-org (&optional table)
  "Render TABLE (default: the live one) as an org table."
  (with-temp-buffer
    (insert "| Tool | Group | Undo | What |\n|------+-------+------+------|\n")
    (pcase-dolist (`(,wire ,group ,kind ,text)
                   (or table (cmacs-brigade-undo-decision-table)))
      (insert (format "| =%s= | %s | %s | %s |\n" wire group kind
                      (replace-regexp-in-string "|" "\\\\vert{}" text))))
    (buffer-string)))

(defun cmacs-brigade-undo-table-texi (&optional table)
  "Render TABLE (default: the live one) as a Texinfo multitable."
  (let ((q (lambda (s) (replace-regexp-in-string "[@{}]" "@\\&" s))))
    (with-temp-buffer
      (insert "@multitable @columnfractions .28 .12 .12 .48\n"
              "@headitem Tool @tab Group @tab Undo @tab What\n")
      (pcase-dolist (`(,wire ,group ,kind ,text)
                     (or table (cmacs-brigade-undo-decision-table)))
        (insert (format "@item @code{%s} @tab %s @tab %s @tab %s\n"
                        (funcall q wire) (funcall q group) kind
                        (funcall q text))))
      (insert "@end multitable\n")
      (buffer-string))))

(defconst cmacs-brigade-undo-doc-files
  '(("doc_org/cmacs/cmacs-brigade-undo.org" . cmacs-brigade-undo-table-org)
    ("doc/cmacs/brigade-undo.texi" . cmacs-brigade-undo-table-texi))
  "The documents holding the generated table, and their renderers.")

(defconst cmacs-brigade-undo-doc-markers
  '("GENERATED UNDO TABLE BEGIN" . "GENERATED UNDO TABLE END")
  "Text on the comment lines that bracket the generated table.")

(defun cmacs-brigade-undo--splice (text table)
  "Return TEXT with the region between the markers replaced by TABLE.
nil when TEXT has no markers."
  (let ((begin (car cmacs-brigade-undo-doc-markers))
        (end (cdr cmacs-brigade-undo-doc-markers)))
    (when (string-match (concat "^.*" (regexp-quote begin) ".*\n") text)
      (let ((from (match-end 0)))
        (when (string-match (concat "^.*" (regexp-quote end)) text from)
          (concat (substring text 0 from) table
                  (substring text (match-beginning 0))))))))

(defun cmacs-brigade-undo-batch-write-table ()
  "Batch entry point: regenerate the undo table in the two documents.

  emacs --batch -Q -L lisp/cmacs -l cmacs-brigade-tools \\
        -f cmacs-brigade-undo-batch-write-table ROOT [--check]

Loads every shipped tool file first.  With --check nothing is written
and the exit status is 1 when a document is stale."
  (require 'cmacs-capability)
  (let* ((root (file-name-as-directory
                (expand-file-name (or (pop command-line-args-left) "."))))
         (check (equal (car command-line-args-left) "--check"))
         (failed (progn (setq command-line-args-left nil)
                        (cmacs-capability-load-shipped
                         (expand-file-name "lisp/cmacs" root))))
         (stale nil))
    (when failed
      (message "cmacs-brigade-undo: tool files would not load: %S" failed)
      (kill-emacs 2))
    (pcase-dolist (`(,rel . ,render) cmacs-brigade-undo-doc-files)
      (let* ((file (expand-file-name rel root))
             (old (with-temp-buffer (insert-file-contents file)
                                    (buffer-string)))
             (new (cmacs-brigade-undo--splice old (funcall render))))
        (unless new (message "cmacs-brigade-undo: no markers in %s" rel)
                (kill-emacs 2))
        (unless (equal old new)
          (setq stale t)
          (if check
              (message "cmacs-brigade-undo: %s is stale" rel)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region new nil file nil 'silent))
            (message "cmacs-brigade-undo: wrote %s" rel)))))
    (kill-emacs (if (and check stale) 1 0))))

;;;; A desktop key

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-add-keybind "cmacs-gowl.c"
                  (key action &optional arg description))
(declare-function gowl-remove-keybind "cmacs-gowl.c" (key))

(defcustom cmacs-brigade-undo-key "Super+Ctrl+z"
  "gowl key that undoes the last action an agent took, or nil for none.
Bound by `cmacs-brigade-undo-setup', and by nothing else.  Under
`--gowl' an agent may have moved a window or typed into a buffer you
are not looking at; the key works from anywhere on the desktop."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-brigade)

;;;###autoload
(defun cmacs-brigade-undo-setup ()
  "Bind `cmacs-brigade-undo-key' to `cmacs-brigade-undo' in gowl.
Does nothing when the compositor is not running or the key is nil.
Safe to call again: the key is unbound before it is bound."
  (interactive)
  (when (and cmacs-brigade-undo-key
             (fboundp 'gowl-running-p)
             (ignore-errors (gowl-running-p))
             (fboundp 'gowl-add-keybind))
    (condition-case err
        (progn
          ;; gowl runs the first bind that matches, so one left by an
          ;; earlier call would shadow this one.
          (ignore-errors (gowl-remove-keybind cmacs-brigade-undo-key))
          (gowl-add-keybind cmacs-brigade-undo-key 'custom
                            "(cmacs-brigade-undo)"
                            "Undo the last agent action")
          t)
      (error (message "cmacs-brigade-undo: cannot bind %s: %s"
                      cmacs-brigade-undo-key (error-message-string err))
             nil))))

(provide 'cmacs-brigade-undo)

;; The per-tool capture functions the families' :undo declarations name.
(require 'cmacs-brigade-undo-capture nil 'noerror)

;;; cmacs-brigade-undo.el ends here
