;;; cmacs-brigade-log.el --- What an agent did, turn by turn  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An agent used to produce exactly one thing: the text of its single
;; run, in `<id>.txt'.  That was enough when a task ran once and stopped.
;; A task that can be spoken to again produces a conversation, and a flat
;; file that each turn overwrites is worse than useless -- it looks like a
;; complete record while being only the last fragment of one.
;;
;; So: an append-only log, one JSON object per line, at `<id>.jsonl'.
;; JSONL rather than org because the primary reader is another agent.
;; `agent_log' hands this to a model, which needs to filter by turn and by
;; kind without being handed a document to parse; and appending a line is
;; atomic enough to survive the editor dying mid-run, which rewriting a
;; document is not.
;;
;; Four kinds, deliberately few:
;;
;;   message  something said TO the agent -- the original task, or any
;;            later mailbox delivery, with `from' recording who said it
;;   reply    what the agent said back at the end of a turn, with that
;;            turn's usage
;;   tool     a tool the agent called, with arguments and result
;;   state    a lifecycle transition, so a log read on its own explains
;;            gaps without needing the dashboard
;;
;; The log is deliberately *richer* than what the model gets replayed on
;; its next turn.  Replay compacts tool traffic away to keep a long
;; conversation affordable; the log keeps all of it, because the whole
;; point of the sidecar-debugging case is reading what an agent actually
;; did, not the tidied version it would tell you about.
;;
;; Tool entries are recorded for in-process agents.  A CLI agent reaches
;; its tools over the MCP relay, which does not currently carry the task
;; id, so its log has messages, replies and state but not individual tool
;; calls -- see `cmacs-brigade-log-tool-attribution' for the details.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-output)
(require 'json)
(require 'cl-lib)
(require 'subr-x)

(defcustom cmacs-brigade-log-max-field 20000
  "Longest a single text field may be before it is truncated in the log.

A tool that returns a megabyte of output would otherwise put a megabyte
on every line of the log, and the log is read whole.  Truncation is
marked in the text so a reader can tell it happened; nil disables it."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'cmacs-brigade)

(defconst cmacs-brigade-log-tool-attribution 'inproc
  "Which workers produce per-tool log entries.

`inproc' agents call tools through `cmacs-brigade-call-tool' in this
process, which knows the task and records each call.  CLI agents reach
the same tools over the MCP relay, whose protocol carries the capability
token but not the task id, so a call arriving from one cannot be
attributed to the task that made it.  Their logs still carry every
message, reply and state change.")

(defun cmacs-brigade-log-file (id)
  "Path of task ID's transaction log."
  (expand-file-name (format "%s.jsonl" id) cmacs-brigade-output-dir))

(defun cmacs-brigade-log--clip (text)
  "Return TEXT, shortened to `cmacs-brigade-log-max-field' if need be."
  (cond
   ((not (stringp text)) text)
   ((or (null cmacs-brigade-log-max-field)
        (<= (length text) cmacs-brigade-log-max-field))
    text)
   (t (concat (substring text 0 cmacs-brigade-log-max-field)
              (format "\n[... %d more characters elided by cmacs-brigade-log]"
                      (- (length text) cmacs-brigade-log-max-field))))))

(defun cmacs-brigade-log--plist->object (plist)
  "Turn PLIST into an alist `json-serialize' accepts.

Keys are interned without their leading colon -- symbols, not strings,
because `json-serialize' takes an alist keyed by symbols and rejects
string keys outright.  Every string value is clipped, and a key whose
value is nil is dropped: a log line should say what happened, not
enumerate what did not."
  (let (out)
    (while plist
      (let ((k (pop plist))
            (v (pop plist)))
        (when v
          (push (cons (intern (substring (symbol-name k) 1))
                      (cond ((stringp v) (cmacs-brigade-log--clip v))
                            ((symbolp v) (symbol-name v))
                            (t v)))
                out))))
    (nreverse out)))

(defun cmacs-brigade-log-append (id kind &rest fields)
  "Append an entry of KIND for task ID.  Returns the entry, or nil.

FIELDS is a plist; `:turn' and `:at' are supplied here when absent so
every entry can be ordered and filtered without the caller remembering
to.  Never signals: a run whose log cannot be written is still a run, and
failing the task over its own bookkeeping would be the wrong trade."
  (when (and id kind)
    (condition-case err
        (let* ((entry (append (list :kind kind
                                    :at (floor (float-time)))
                              (unless (plist-member fields :turn)
                                (list :turn 0))
                              fields))
               (line (json-serialize
                      (cmacs-brigade-log--plist->object entry))))
          (make-directory cmacs-brigade-output-dir t)
          (let ((coding-system-for-write 'utf-8))
            ;; Append, not rewrite: this is called from a process
            ;; sentinel and from tool dispatch, and a rewrite that is
            ;; interrupted loses the whole history rather than one line.
            (write-region (concat line "\n") nil (cmacs-brigade-log-file id)
                          'append 'silent))
          entry)
      (error (message "cmacs-brigade: could not log %s for %s: %s"
                      kind id (error-message-string err))
             nil))))

(defun cmacs-brigade-log-read (id &optional from-turn kinds)
  "Return task ID's log entries as a list of alists, oldest first.

FROM-TURN, when given, drops entries from earlier turns -- the argument
an agent polling a long-running sibling actually wants, so it can read
only what is new.  KINDS is a list of kind strings to keep.

A line that does not parse is skipped rather than fatal.  The log is
appended to from a sentinel, so a truncated final line is a normal
consequence of a crash, and refusing to read the other nine hundred
entries because of it would be perverse."
  (let ((file (cmacs-brigade-log-file id))
        out)
    (when (file-readable-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file))
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p (string-trim line))
              (when-let* ((e (condition-case nil
                                 (json-parse-string line :object-type 'alist
                                                    :array-type 'list
                                                    :null-object nil
                                                    :false-object nil)
                               (error nil))))
                (when (and (or (null from-turn)
                               (>= (or (alist-get 'turn e) 0) from-turn))
                           (or (null kinds)
                               (member (alist-get 'kind e) kinds)))
                  (push e out)))))
          (forward-line 1))))
    (nreverse out)))

(defun cmacs-brigade-log-turns (id)
  "Highest turn number recorded for task ID, or 0."
  (let ((n 0))
    (dolist (e (cmacs-brigade-log-read id) n)
      (setq n (max n (or (alist-get 'turn e) 0))))))

(defun cmacs-brigade-log--render-entry (e)
  "Render one log entry E as text."
  (let* ((kind (alist-get 'kind e))
         (turn (or (alist-get 'turn e) 0))
         (at (alist-get 'at e))
         (stamp (if at (format-time-string "%H:%M:%S" (seconds-to-time at)) "")))
    (pcase kind
      ("message"
       (format "[%s] turn %d  <- %s\n%s\n"
               stamp turn (or (alist-get 'from e) "?")
               (or (alist-get 'text e) "")))
      ("reply"
       (format "[%s] turn %d  -> %s%s\n%s\n"
               stamp turn (or (alist-get 'state e) "done")
               (let ((in (alist-get 'in_tokens e))
                     (out (alist-get 'out_tokens e))
                     (cost (alist-get 'cost_micros e)))
                 (if (or in out cost)
                     (format "  (%s/%s tokens, $%.4f)"
                             (or in 0) (or out 0) (/ (or cost 0) 1000000.0))
                   ""))
               (or (alist-get 'text e) "")))
      ("tool"
       (format "[%s] turn %d  .. %s %s\n%s\n"
               stamp turn (or (alist-get 'tool e) "?")
               (or (alist-get 'args e) "")
               (or (alist-get 'error e) (alist-get 'result e) "")))
      ("state"
       (format "[%s] turn %d  == %s%s\n"
               stamp turn (or (alist-get 'state e) "?")
               (if-let* ((r (alist-get 'reason e))) (format ": %s" r) "")))
      (_ (format "[%s] turn %d  %s\n" stamp turn kind)))))

(defun cmacs-brigade-log-render (id &optional from-turn kinds)
  "Return task ID's log as readable text, or nil when there is none.

Falls back to the legacy flat `<id>.txt' when no JSONL log exists, so a
run recorded before this file existed still reads."
  (let ((entries (cmacs-brigade-log-read id from-turn kinds)))
    (if entries
        (mapconcat #'cmacs-brigade-log--render-entry entries "\n")
      (and (null from-turn) (null kinds)
           (cmacs-brigade-output-get id)))))


;;;; Recording

(declare-function cmacs-brigade-conversation-turn "cmacs-brigade-run")

(defun cmacs-brigade-log-current-turn (id)
  "Which turn of task ID's conversation is in progress, or 0.

Resolved through the run layer rather than tracked here: the turn counter
belongs to the conversation, and duplicating it would give two answers
that drift.  Guarded with `fboundp' so this file stays loadable on its
own -- the log has to be readable even in a session where nothing runs."
  (or (and (fboundp 'cmacs-brigade-conversation-turn)
           (cmacs-brigade-conversation-turn id))
      0))

(defun cmacs-brigade-log--on-tool-call (req)
  "Record REQ, a finished tool call, against the task that made it.

Attribution comes from `:task' in the request, which only the in-process
worker sets -- see `cmacs-brigade-log-tool-attribution'.  A call with no
task is a chat buffer's or an external MCP client's and belongs to no
run, so it is dropped rather than guessed at."
  (when-let* ((task (plist-get req :task)))
    (cmacs-brigade-log-append
     task "tool"
     :turn (cmacs-brigade-log-current-turn task)
     :tool (plist-get req :tool)
     :args (let ((a (plist-get req :args)))
             (and a (condition-case nil (json-serialize
                                         (cmacs-brigade-log--plist->object
                                          (cl-loop for (k . v) in a
                                                   append (list (intern (concat ":" k))
                                                                v))))
                      (error (format "%S" a)))))
     :result (plist-get req :result)
     :error (when-let* ((e (plist-get req :error)))
              (error-message-string e)))))

(add-hook 'cmacs-brigade-after-tool-call-functions
          #'cmacs-brigade-log--on-tool-call)

(provide 'cmacs-brigade-log)

;;; cmacs-brigade-log.el ends here
