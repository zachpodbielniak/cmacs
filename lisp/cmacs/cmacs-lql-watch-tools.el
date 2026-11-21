;;; cmacs-lql-watch-tools.el --- "Tell me when X": watches for agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; Author: Zach Podbielniak
;; Keywords: data, tools
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `lql_watch', `lql_unwatch' and `lql_watches': an agent registers a
;; standing LQL query and is told when its result changes, instead of
;; polling `lql_query' in a loop and paying a turn each time to learn
;; that nothing happened.
;;
;; Who owns a watch is not something the model says.  The owner is the
;; brigade TASK the tool call arrived on behalf of -- the executor's own
;; task for an in-process agent, the task a CLI agent's scoped socket
;; was opened for -- noted from `cmacs-brigade-before-tool-call-functions'
;; exactly as the desktop tools do.  From that follow the rules:
;;
;;   - A call from no task is refused.  There would be nobody to tell
;;     and no run whose end removes the watch.
;;   - A watch's real name is TASK/NAME, so an agent can neither replace
;;     nor remove a watch that is not its own, whatever it calls it.
;;   - `cmacs-lql-watch-max-per-owner' bounds how many one task holds,
;;     `cmacs-lql-watch-tools-min-interval' how often they run.
;;   - When the task's run ends, its watches are removed.
;;   - The query is submitted in agent context by cmacs-lql-watch.el, so
;;     a source that hides rows from agents (the `activity' journal,
;;     unless `cmacs-journal-expose-to-agents') hides them here too, and
;;     a watch naming one is refused outright with the reason.
;;   - An agent's watch gets no callbacks, no podomation event, no bar
;;     item: only this file's delivery.
;;
;; A change is delivered to the task's mailbox (`cmacs-brigade-mailbox-
;; send'), which steers a running agent and wakes a parked one.  At most
;; ONE undelivered message per watch is ever queued: a watch that
;; changes ten times while its agent is busy costs it one message, and
;; `lql_watches' has the current state.  A task whose worker cannot be
;; sent to keeps the change for `lql_watches' to return.
;;
;; This file is loaded at startup, so the tools are listed; the watch
;; machinery and LQL load when a tool runs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-brigade-registry)

(declare-function cmacs-lql-watch "cmacs-lql-watch" (name query &rest plist))
(declare-function cmacs-lql-unwatch "cmacs-lql-watch" (name))
(declare-function cmacs-lql-unwatch-owner "cmacs-lql-watch" (owner))
(declare-function cmacs-lql-watch-list "cmacs-lql-watch" (&optional owner))
(declare-function cmacs-lql-watch-get "cmacs-lql-watch" (name property))
(declare-function cmacs-lql-watch-diff-json "cmacs-lql-watch"
                  (diff &optional max-chars))
(declare-function cmacs-lql-available-p "cmacs-lql" ())
(declare-function cmacs-brigade-mailbox-send "cmacs-brigade-mailbox"
                  (id text &optional from))
(declare-function cmacs-brigade-mailbox-list "cmacs-brigade-mailbox" (id))

(defcustom cmacs-lql-watch-tools-min-interval 30
  "Least interval, in seconds, an agent's watch may poll at."
  :type 'number
  :group 'cmacs-lql-watch)

(defcustom cmacs-lql-watch-tools-default-interval 120
  "Interval, in seconds, of an agent's watch that names none."
  :type 'number
  :group 'cmacs-lql-watch)

(defcustom cmacs-lql-watch-tools-max-chars 4000
  "Most characters of diff in one change message to an agent."
  :type 'natnum
  :group 'cmacs-lql-watch)

(defvar cmacs-lql-watch-tools--pending (make-hash-table :test #'equal)
  "Full watch name -> a change message its owner has not been given.")

;;;; Who is calling

(defvar cmacs-lql-watch-tools--caller nil
  "(TASK . AGENT) of the watch tool call being dispatched, or nil.
Set immediately before the handler runs and taken by the handler as its
first act; see `cmacs-brigade-desktop--caller' for why it is done so.")

(defconst cmacs-lql-watch-tools--wire-names
  '("lql_watch" "lql_unwatch" "lql_watches")
  "The wire names of this file's tools.")

(defun cmacs-lql-watch-tools--note-caller (request)
  "Remember who is making the watch tool call REQUEST.  Never vetoes."
  (when (member (plist-get request :tool) cmacs-lql-watch-tools--wire-names)
    (setq cmacs-lql-watch-tools--caller
          (cons (plist-get request :task) (plist-get request :agent))))
  t)

(add-hook 'cmacs-brigade-before-tool-call-functions
          #'cmacs-lql-watch-tools--note-caller)

(defun cmacs-lql-watch-tools--task ()
  "The calling task's id, taken (and cleared) from the noted caller.
Signals when the call came from no task."
  (let ((task (car (prog1 cmacs-lql-watch-tools--caller
                     (setq cmacs-lql-watch-tools--caller nil)))))
    (unless (and task (not (equal task "")))
      (error "This call came from no brigade task, so there is nobody to tell and no run whose end would remove the watch.  Use lql_query"))
    (format "%s" task)))

(defun cmacs-lql-watch-tools--full-name (task name)
  "The registered name of TASK's watch NAME, checking NAME's shape."
  (unless (and (stringp name)
               (string-match-p "\\`[A-Za-z0-9_-]\\{1,40\\}\\'" name))
    (error "A watch name is 1-40 letters, digits, `-' or `_'"))
  (format "%s/%s" task name))

(defun cmacs-lql-watch-tools--short-name (full)
  "The name the agent gave the watch registered as FULL."
  (if (string-match "/\\([^/]+\\)\\'" full) (match-string 1 full) full))

;;;; The tool bodies, as functions (so tests can call them)

(defun cmacs-lql-watch-tools--watch (task name query every key)
  "Register TASK's watch NAME on QUERY every EVERY seconds, keyed by KEY."
  (unless (and (require 'cmacs-lql nil t) (cmacs-lql-available-p))
    (error "LQL is not built into this cmacs (--with-cmacs-lql)"))
  (require 'cmacs-lql-watch)
  (let* ((full (cmacs-lql-watch-tools--full-name task name))
         (every (max cmacs-lql-watch-tools-min-interval
                     (if (and (numberp every) (> every 0))
                         every
                       cmacs-lql-watch-tools-default-interval))))
    (when (or (null query) (string-blank-p query))
      (error "Missing query"))
    ;; Exactly these options and no others: an agent's watch has no
    ;; callbacks and no sinks, and is always owned.
    (cmacs-lql-watch full query
                     :every every
                     :key (and (stringp key) (not (string-blank-p key)) key)
                     :owner task)
    (remhash full cmacs-lql-watch-tools--pending)
    (format "Watching `%s' every %ds.  You will get a message when the result changes; the first result is the baseline and is not reported.  lql_watches shows its state, lql_unwatch removes it, and it is removed when this run ends."
            name (round every))))

(defun cmacs-lql-watch-tools--unwatch (task name)
  "Remove TASK's watch NAME."
  (require 'cmacs-lql-watch)
  (let ((full (cmacs-lql-watch-tools--full-name task name)))
    (remhash full cmacs-lql-watch-tools--pending)
    (if (cmacs-lql-unwatch full)
        (format "Removed the watch `%s'." name)
      (error "You have no watch called `%s'" name))))

(defun cmacs-lql-watch-tools--time (time)
  "TIME, a float or nil, for a listing."
  (if time (format-time-string "%F %T" time) "never"))

(defun cmacs-lql-watch-tools--watches (task)
  "Describe TASK's watches, handing over any change it has not been given."
  (require 'cmacs-lql-watch)
  (let ((watches (cmacs-lql-watch-list task)))
    (if (null watches)
        "You have no watches."
      (mapconcat
       (lambda (w)
         (let* ((full (plist-get w :name))
                (pending (gethash full cmacs-lql-watch-tools--pending)))
           (remhash full cmacs-lql-watch-tools--pending)
           (concat
            (format "%s: %s, every %ds, %d rows, %d changes, last run %s, last change %s\n  query: %s"
                    (cmacs-lql-watch-tools--short-name full)
                    (plist-get w :state)
                    (round (plist-get w :every))
                    (plist-get w :rows)
                    (plist-get w :changes)
                    (cmacs-lql-watch-tools--time (plist-get w :last-run))
                    (cmacs-lql-watch-tools--time (plist-get w :last-change))
                    (plist-get w :query))
            (and (plist-get w :last-error)
                 (format "\n  error: %s" (plist-get w :last-error)))
            (and pending (format "\n  undelivered: %s" pending)))))
       watches "\n"))))

;;;; Delivery

(defun cmacs-lql-watch-tools--queued-p (task from)
  "Non-nil when TASK's mailbox already holds a message from FROM."
  (and (fboundp 'cmacs-brigade-mailbox-list)
       (cl-some (lambda (message) (equal (plist-get message :from) from))
                (cmacs-brigade-mailbox-list task))))

(defun cmacs-lql-watch-tools--tell (full text)
  "Give TEXT, news of the watch FULL, to the task that owns it.
Queued to its mailbox unless a message about this watch is already
waiting there; kept for `lql_watches' when it cannot be sent."
  (when-let* ((task (cmacs-lql-watch-get full :owner)))
    (let ((from (concat "lql-watch:" (cmacs-lql-watch-tools--short-name full))))
      (puthash full text cmacs-lql-watch-tools--pending)
      (when (and (or (fboundp 'cmacs-brigade-mailbox-send)
                     (require 'cmacs-brigade-mailbox nil t))
                 (not (cmacs-lql-watch-tools--queued-p task from)))
        (condition-case nil
            (progn
              (cmacs-brigade-mailbox-send task text from)
              (remhash full cmacs-lql-watch-tools--pending))
          ;; No such task any more, a worker with no session, a full
          ;; mailbox: the text stays pending and the list shows it.
          (error nil))))))

(defun cmacs-lql-watch-tools--on-change (full new _old diff)
  "Tell the owner of the watch FULL that its result is now NEW, by DIFF."
  (when (cmacs-lql-watch-get full :owner)
    (cmacs-lql-watch-tools--tell
     full
     (format "[lql watch `%s' changed] %d rows now (%d added, %d removed, %d changed).  Diff: %s"
             (cmacs-lql-watch-tools--short-name full)
             (length new)
             (length (plist-get diff :added))
             (length (plist-get diff :removed))
             (length (plist-get diff :changed))
             (cmacs-lql-watch-diff-json diff cmacs-lql-watch-tools-max-chars)))))

(defun cmacs-lql-watch-tools--on-error (full message)
  "Tell the owner of the watch FULL that it started failing with MESSAGE."
  (when (cmacs-lql-watch-get full :owner)
    (cmacs-lql-watch-tools--tell
     full
     (format "[lql watch `%s' is failing] %s.  It will be retried less and less often; fix the query with lql_watch under the same name, or lql_unwatch it."
             (cmacs-lql-watch-tools--short-name full) message))))

(defun cmacs-lql-watch-tools--on-removed (full _owner)
  "Forget what was pending for the removed watch FULL."
  (remhash full cmacs-lql-watch-tools--pending))

(defun cmacs-lql-watch-tools--on-run-finished (task-id &rest _)
  "Remove the watches of the task TASK-ID, whose run has ended."
  (when (and task-id (featurep 'cmacs-lql-watch))
    (cmacs-lql-unwatch-owner (format "%s" task-id)))
  nil)

(add-hook 'cmacs-lql-watch-change-functions #'cmacs-lql-watch-tools--on-change)
(add-hook 'cmacs-lql-watch-error-functions #'cmacs-lql-watch-tools--on-error)
(add-hook 'cmacs-lql-watch-removed-functions
          #'cmacs-lql-watch-tools--on-removed)
(add-hook 'cmacs-brigade-run-finished-functions
          #'cmacs-lql-watch-tools--on-run-finished)

;;;; The tools

(cmacs-brigade-deftool lql-watch
  "Register a standing LQL query and be told when its result changes: \
\"tell me when X\".  The query (same language and sources as lql_query) \
is re-run every EVERY seconds; the first result is the baseline, and \
after that you receive a message, with a diff, only when the result \
differs from the last one.  Prefer this to calling lql_query in a loop.  \
Give KEY, the column(s) identifying a row, to have changed rows told \
apart from removed-and-added ones.  Write a query whose result is small \
and stable -- filter, summarize, sort -- because any difference fires.  \
A watch is yours alone, you may hold only a few, and all of them are \
removed when your run ends.  Registering under a NAME you already use \
replaces that watch."
    ((name string "A short name for the watch: letters, digits, - or _")
     (query string "The LQL query to watch")
     (every integer "Seconds between runs (default 120, minimum 30)"
            :optional t)
     (key string "Column, or comma-separated columns, identifying a row"
          :optional t))
  :group 'data
  (cmacs-lql-watch-tools--watch (cmacs-lql-watch-tools--task)
                                name query every key))

(cmacs-brigade-deftool lql-unwatch
  "Remove one of your standing LQL queries, by the NAME you gave lql_watch."
    ((name string "The watch's name"))
  :group 'data
  (cmacs-lql-watch-tools--unwatch (cmacs-lql-watch-tools--task) name))

(cmacs-brigade-deftool lql-watches
  "List your standing LQL queries: state, interval, row count, when each \
last ran and last changed, its last error, and any change you have not \
yet been told about."
    ()
  :group 'data
  (cmacs-lql-watch-tools--watches (cmacs-lql-watch-tools--task)))

(provide 'cmacs-lql-watch-tools)

;;; cmacs-lql-watch-tools.el ends here
