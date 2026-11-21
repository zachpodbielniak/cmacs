;;; cmacs-lql-watch.el --- Standing LQL queries  -*- lexical-binding: t; -*-

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

;; A query run with `cmacs-lql-run' answers once.  A WATCH is a query
;; that is registered once and calls back when its answer changes:
;;
;;   (cmacs-lql-define-watch dead-processes
;;     "fetch processes | filter status == \"exit\" | fields name | sort name"
;;     :every 30 :key "name"
;;     :on-change (lambda (new _old diff) ...))
;;
;; A podomation trigger, a bar item and an agent's "tell me when X" are
;; then all the same thing: a query and what to do about a change
;; (cmacs-lql-watch-sinks.el, cmacs-lql-watch-tools.el).
;;
;; Change detection is on the RESULT, never on time: the result JSON is
;; hashed and a watch fires only when the hash differs from the last
;; one.  The first result is the baseline and does not fire unless the
;; watch says :immediate.
;;
;; Cost is the whole design.  LQL runs one query at a time on one worker
;; thread, and an Elisp-defined source is snapshotted to JSON on THIS
;; thread before the query is submitted.  A watch is therefore work the
;; user did not ask for at that moment, twice over, and the rules below
;; exist so that it never shows:
;;
;;   - One timer for every watch, armed for the earliest due one; no
;;     watches, no timer.
;;   - At most ONE watch query in flight, across all watches.  Queued
;;     watch queries would sit in front of the query the user is about
;;     to run; one cannot hold them up for longer than it takes itself.
;;   - A watch whose last run has not come back is never submitted
;;     again.
;;   - A tick is skipped while the engine is busy (the `cmacs-lql-busy'
;;     signal of the try-lock helpers): somebody is running a query, and
;;     they come first.
;;   - A watch naming an Elisp source waits for
;;     `cmacs-lql-watch-min-idle' seconds of idleness, because its
;;     snapshot runs on the thread the user is typing into.
;;   - When every source a watch names has a generation function
;;     (`cmacs-lql-set-source-generation') and none has moved, the tick
;;     is skipped outright: no snapshot, no submit, no hash.
;;   - A failing watch backs off exponentially, capped, and the error is
;;     kept for `M-x cmacs-lql-watches' -- one message when it starts
;;     failing, not one per tick.
;;   - Hard caps: watches in total, watches per owner, rows and bytes of
;;     a result.
;;
;; Callbacks run on the main thread, inside `condition-case' (an error
;; is recorded on the watch, never signalled into the timer or the GLib
;; dispatch that delivered the result) and with `inhibit-interaction'
;; bound to t.  That last one is deliberate: a watch fires at a moment
;; nobody chose, and a callback that opens the minibuffer then takes the
;; keyboard away from whatever the user was doing -- under `emacs
;; --gowl' from the whole desktop.  A callback that prompts gets an
;; `inhibited-interaction' error, recorded like any other.  What nothing
;; here can do is preempt a callback that computes for a long time, so:
;; a callback is quick, and long work is a process with a sentinel.
;;
;; Ownership.  A watch made by an agent (cmacs-lql-watch-tools.el) has an
;; OWNER.  Its query is submitted -- and so its Elisp sources are
;; snapshotted -- inside the same dynamic bindings a brigade tool call
;; runs in, so every source that withholds rows from agents (the
;; `activity' journal, unless `cmacs-journal-expose-to-agents') makes
;; the same decision for the watch that it makes for a one-shot
;; `lql_query'.  A watch is not a way around it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'cmacs-lql)

(declare-function cmacs-lql--sources "cmacs-lql-defuns.c" ())
(declare-function cmacs-lql--cancel "cmacs-lql-defuns.c" (id))
(declare-function cmacs-lql--referenced-sources "cmacs-lql" (query))

(defvar cmacs-lql--sources)
;; Bound (dynamically) around an owned watch's submit; see
;; `cmacs-lql-watch--as-owner'.  Declared special here so the `let'
;; below is a dynamic binding even when cmacs-journal.el is not loaded.
(defvar cmacs-journal--in-tool-call)

(defgroup cmacs-lql-watch nil
  "Standing LQL queries: called when a result changes."
  :group 'cmacs-lql
  :prefix "cmacs-lql-watch-")

;;;; Customization

(defcustom cmacs-lql-watch-default-interval 60
  "Seconds between runs of a watch that names no :every."
  :type 'number)

(defcustom cmacs-lql-watch-min-interval 5
  "Least interval, in seconds, a watch may poll at.
A smaller :every is raised to this.  A watch is a whole query each
time; anything that needs to react faster than this wants a hook, not a
poll."
  :type 'number)

(defcustom cmacs-lql-watch-min-idle 0.75
  "Seconds Emacs must have been idle before a watch snapshots a Lisp source.
An Elisp-defined source's rows are collected and serialised on the
editor thread; this keeps that work out from under your typing.  Watches
that name only engine sources (files, git, the journal, SQL, ...) are
not held back by it.  Zero disables the wait."
  :type 'number)

(defcustom cmacs-lql-watch-max 32
  "Most watches that may be registered at once."
  :type 'natnum)

(defcustom cmacs-lql-watch-max-per-owner 4
  "Most watches one owner (an agent's task) may hold at once."
  :type 'natnum)

(defcustom cmacs-lql-watch-max-rows 500
  "Most rows of a result a watch keeps and compares.
Never more than `cmacs-lql-max-rows'.  The result's `total' still counts
every row, so a change beyond the cap still changes the hash."
  :type 'natnum)

(defcustom cmacs-lql-watch-max-result-bytes (* 2 1024 1024)
  "Largest result JSON, in characters, a watch will keep.
A bigger one is an error on the watch (and backs it off), not a diff:
few rows can still be enormous when a column holds file contents."
  :type 'natnum)

(defcustom cmacs-lql-watch-timeout 30
  "Seconds a watch's query may run before it is given up on."
  :type 'natnum)

(defcustom cmacs-lql-watch-max-backoff 3600
  "Longest wait, in seconds, between runs of a watch that keeps failing.
The wait doubles with each failure in a row, starting from the watch's
own interval, up to this."
  :type 'number)

(defcustom cmacs-lql-watch-busy-retry 2
  "Seconds to wait before trying again after finding the engine busy."
  :type 'number)

(defcustom cmacs-lql-watch-max-generation-skips 20
  "Most ticks in a row a watch may skip because no source changed.
After that many it runs anyway.  The skip is an inference -- that the
query reads nothing but the Elisp sources it names -- and this bounds
what a wrong inference can cost: a late change, never a lost one.  Zero
disables skipping."
  :type 'natnum)

(defcustom cmacs-lql-watch-volatile-regexp
  "\\_<\\(?:now\\|today\\|yesterday\\|random\\|rand\\|uuid\\)\\_>"
  "Regexp matching query text whose result can change with no source changing.
A watch whose query matches is never skipped on unchanged source
generations (see `cmacs-lql-watch' :depends)."
  :type 'regexp)

(defcustom cmacs-lql-watch-agent-gated-sources
  '(("activity" . cmacs-journal-expose-to-agents))
  "Sources an owned (agent's) watch may name only when a variable allows.
An alist of (SOURCE . VARIABLE).  The source itself already withholds
its rows -- an owned watch is submitted in agent context -- so this is
the second lock, and the one that says why: registering such a watch is
refused with a sentence instead of producing a watch that is silently
always empty."
  :type '(alist :key-type string :value-type variable))

(defcustom cmacs-lql-watch-saved nil
  "Watches to restore with `cmacs-lql-watch-restore-saved'.
A list of (NAME QUERY . PLIST), the arguments of `cmacs-lql-watch'.
`cmacs-lql-watch-save' adds to it; only watches whose options are plain
data (no closures) can be saved.  Watches defined in your init file are
code and do not belong here."
  :type '(repeat (cons string (cons string plist))))

;;;; State

(cl-defstruct (cmacs-lql-watcher (:constructor cmacs-lql-watcher--make)
                                 (:copier nil))
  "One standing query."
  name query every owner key depends
  on-change on-rows immediate
  max-rows timeout
  props                 ; the option plist as given (for sinks and saving)
  paused
  in-flight             ; nil | t | the request id, while a run is out
  token                 ; identifies the run a callback belongs to
  started               ; when the run in flight was submitted
  next-due
  last-run last-change
  baseline              ; non-nil once a first result has been seen
  hash rows columns total
  (runs 0) (changes 0) (failures 0)
  (gen-skips 0)         ; consecutive ticks skipped on source generations
  (skipped 0)           ; every skipped tick, any reason
  last-skip             ; why the last tick was skipped (a symbol)
  generation pending-generation
  last-error callback-error callback-seconds)

(defvar cmacs-lql-watch--table (make-hash-table :test #'equal)
  "Watch name -> `cmacs-lql-watcher'.")

(defvar cmacs-lql-watch--timer nil
  "The one timer behind every watch, or nil.")

(defvar cmacs-lql-watch--sequence 0
  "Source of run tokens.")

(defvar cmacs-lql-watch--engine-sources nil
  "Cached names of every engine source, or nil when not yet known.")

(defvar cmacs-lql-watch--inhibit-timer nil
  "Non-nil means never arm the timer.  Tests drive ticks by hand.")

(defvar cmacs-lql-watch-extra-keys nil
  "Option keywords `cmacs-lql-watch' accepts beyond its own.
A consumer that gives a watch a new option (a bar item, a podomation
event) adds its keyword here; anything else is a typo and is refused.")

(defvar cmacs-lql-watch-change-functions nil
  "Abnormal hook run when a watch's result changes.
Each function is called with NAME, NEW-ROWS, OLD-ROWS and DIFF, exactly
what the watch's own :on-change receives, after it.  Functions run with
`inhibit-interaction' bound and an error in one is recorded on the watch
and does not stop the others.")

(defvar cmacs-lql-watch-baseline-functions nil
  "Abnormal hook run with NAME and ROWS when a watch gets its first result.
Not a change -- nothing fires -- but a consumer that DISPLAYS a watch
needs the first value too.")

(defvar cmacs-lql-watch-error-functions nil
  "Abnormal hook run with NAME and MESSAGE when a watch STARTS failing.
Once per run of failures, not once per failed tick.")

(defvar cmacs-lql-watch-removed-functions nil
  "Abnormal hook run with NAME and OWNER after a watch is removed.")

(define-error 'cmacs-lql-watch-error "LQL watch error")

;;;; Small helpers

(defun cmacs-lql-watch--now ()
  "The current time as a float.  A function so tests can move the clock."
  (float-time))

(defun cmacs-lql-watch--name (name)
  "NAME, a string or symbol, as the string watches are keyed by."
  (cond ((stringp name) name)
        ((and name (symbolp name)) (symbol-name name))
        (t (signal 'wrong-type-argument (list 'stringp name)))))

(defun cmacs-lql-watch--get (name)
  "The watcher called NAME, or nil."
  (gethash (cmacs-lql-watch--name name) cmacs-lql-watch--table))

(defun cmacs-lql-watch--all ()
  "Every watcher, sorted by name."
  (sort (hash-table-values cmacs-lql-watch--table)
        (lambda (a b) (string< (cmacs-lql-watcher-name a)
                               (cmacs-lql-watcher-name b)))))

(defmacro cmacs-lql-watch--as-owner (watch &rest body)
  "Run BODY as WATCH's owner would.

For a watch with no owner (yours) that is just BODY.  For an owned one,
BODY runs inside the two bindings that mark a brigade tool call --
`cmacs-journal--in-tool-call' and `inhibit-interaction' -- so that a
source deciding \"is an agent asking?\" at snapshot time gets the answer
it would get for the agent's own one-shot query.  The timer a watch
runs from would otherwise look like the user."
  (declare (indent 1) (debug t))
  `(if (cmacs-lql-watcher-owner ,watch)
       (let ((cmacs-journal--in-tool-call t)
             (inhibit-interaction t))
         ,@body)
     (progn ,@body)))

(defun cmacs-lql-watch--lisp-sources (query)
  "Names of the Elisp-defined sources QUERY mentions."
  (and (fboundp 'cmacs-lql--referenced-sources)
       (cmacs-lql--referenced-sources query)))

(defun cmacs-lql-watch--mentions-p (name query)
  "Non-nil when QUERY mentions NAME as a whole symbol.
In the standard syntax table, whatever buffer is current: what counts as
a symbol must not depend on where the timer happened to fire."
  (with-syntax-table (standard-syntax-table)
    (string-match-p (concat "\\_<" (regexp-quote name) "\\_>") query)))

;;;; Rows and diffs

(defun cmacs-lql-watch--rows (table)
  "The rows of a parsed result TABLE as alists of (COLUMN . VALUE).
COLUMN is the column's name, a string.  NULL is nil and false is
`:false', as `cmacs-lql-parse' has them."
  (let ((names (mapcar #'car (plist-get table :columns))))
    (mapcar (lambda (row)
              (cl-loop for name in names
                       for i from 0
                       collect (cons name (and (< i (length row))
                                               (aref row i)))))
            (plist-get table :rows))))

(defun cmacs-lql-watch--key-columns (key)
  "KEY (a string, a comma-separated string, or a list) as a list of names."
  (cond ((null key) nil)
        ((stringp key) (split-string key "[, \t]+" t))
        ((listp key) (mapcar (lambda (k) (format "%s" k)) key))
        (t (signal 'wrong-type-argument (list 'stringp key)))))

(defun cmacs-lql-watch-diff (old new &optional key)
  "What changed between the row lists OLD and NEW.

Returns a plist (:added ROWS :removed ROWS :changed PAIRS :reordered
BOOL).  With KEY -- a column name or a list of them -- rows are matched
by the values of those columns: a row whose key is new is added, one
whose key is gone is removed, and one whose key stayed but whose other
columns differ is in :changed as (OLD-ROW . NEW-ROW).  Without KEY rows
are compared whole, so a row that changed shows as one removed and one
added and :changed is always nil.  :reordered is t when the same rows
came back in a different order and nothing else differs."
  (let ((columns (cmacs-lql-watch--key-columns key))
        added removed changed)
    (if columns
        (let ((old-by (make-hash-table :test #'equal))
              (new-by (make-hash-table :test #'equal))
              (key-of (lambda (row)
                        (mapcar (lambda (c) (cdr (assoc c row))) columns))))
          (dolist (row old) (puthash (funcall key-of row) row old-by))
          (dolist (row new)
            (let* ((k (funcall key-of row))
                   (was (gethash k old-by 'cmacs-lql-watch--none)))
              (puthash k row new-by)
              (cond ((eq was 'cmacs-lql-watch--none) (push row added))
                    ((not (equal was row)) (push (cons was row) changed)))))
          (dolist (row old)
            (when (eq (gethash (funcall key-of row) new-by
                               'cmacs-lql-watch--none)
                      'cmacs-lql-watch--none)
              (push row removed))))
      ;; Whole rows, as a multiset: two identical rows in OLD and one in
      ;; NEW is one row removed.
      (let ((counts (make-hash-table :test #'equal)))
        (dolist (row old) (cl-incf (gethash row counts 0)))
        (dolist (row new)
          (if (> (gethash row counts 0) 0)
              (cl-decf (gethash row counts))
            (push row added)))
        (dolist (row old)
          (when (> (gethash row counts 0) 0)
            (cl-decf (gethash row counts))
            (push row removed)))))
    (list :added (nreverse added)
          :removed (nreverse removed)
          :changed (nreverse changed)
          :reordered (and (null added) (null removed) (null changed)
                          (not (equal old new))))))

(defun cmacs-lql-watch--jsonable (value)
  "VALUE, a parsed LQL value, as something `json-serialize' takes back.
`cmacs-lql-parse' reads NULL as nil, which `json-serialize' would write
as an empty object; this puts the null back, at any depth."
  (cond ((null value) :null)
        ((vectorp value) (vconcat (mapcar #'cmacs-lql-watch--jsonable value)))
        ((consp value)                  ; a record: an alist
         (let ((object (make-hash-table :test #'equal)))
           (dolist (cell value)
             (when (consp cell)
               (puthash (format "%s" (car cell))
                        (cmacs-lql-watch--jsonable (cdr cell)) object)))
           object))
        (t value)))

(defun cmacs-lql-watch-rows-json (rows &optional max-chars)
  "ROWS as a JSON array string, no longer than MAX-CHARS.
Rows are dropped from the end until it fits; nil MAX-CHARS means all."
  (let* ((rows (mapcar #'cmacs-lql-watch--jsonable rows))
         (json (json-serialize (vconcat rows))))
    (while (and max-chars rows (> (length json) max-chars))
      (setq rows (butlast rows (max 1 (/ (length rows) 2)))
            json (json-serialize (vconcat rows))))
    json))

(defun cmacs-lql-watch-diff-json (diff &optional max-chars)
  "DIFF as a JSON object string, bounded to MAX-CHARS (default 4096).

The object is {\"added\": [...], \"removed\": [...], \"changed\":
[{\"old\": ROW, \"new\": ROW}], \"counts\": {\"added\": N, ...}}.  When the
whole diff does not fit, each list is cut to its first rows -- halving
until it does -- and \"truncated\" is true; \"counts\" always tells the
real sizes."
  (let* ((max-chars (or max-chars 4096))
         (added (plist-get diff :added))
         (removed (plist-get diff :removed))
         (changed (plist-get diff :changed))
         (keep (max 1 (length added) (length removed) (length changed)))
         (build
          (lambda (n truncated)
            (let ((object (make-hash-table :test #'equal))
                  (counts (make-hash-table :test #'equal))
                  (take (lambda (rows) (cl-subseq rows 0 (min n (length rows))))))
              (puthash "added" (length added) counts)
              (puthash "removed" (length removed) counts)
              (puthash "changed" (length changed) counts)
              (puthash "counts" counts object)
              (puthash "added"
                       (vconcat (mapcar #'cmacs-lql-watch--jsonable
                                        (funcall take added)))
                       object)
              (puthash "removed"
                       (vconcat (mapcar #'cmacs-lql-watch--jsonable
                                        (funcall take removed)))
                       object)
              (puthash "changed"
                       (vconcat
                        (mapcar (lambda (pair)
                                  (let ((o (make-hash-table :test #'equal)))
                                    (puthash "old" (cmacs-lql-watch--jsonable
                                                    (car pair)) o)
                                    (puthash "new" (cmacs-lql-watch--jsonable
                                                    (cdr pair)) o)
                                    o))
                                (funcall take changed)))
                       object)
              (when (plist-get diff :reordered)
                (puthash "reordered" t object))
              (when truncated (puthash "truncated" t object))
              (json-serialize object))))
         (json (funcall build keep nil)))
    (while (and (> (length json) max-chars) (> keep 0))
      (setq keep (/ keep 2)
            json (funcall build keep t)))
    json))

;;;; The timer

(defun cmacs-lql-watch--arm (&optional soon)
  "Arm the one timer for the earliest thing that needs doing.
SOON non-nil means look again almost at once (a run just came back and
another watch may be due).  No watches, no timer."
  (when (timerp cmacs-lql-watch--timer)
    (cancel-timer cmacs-lql-watch--timer))
  (setq cmacs-lql-watch--timer nil)
  (unless cmacs-lql-watch--inhibit-timer
    (let ((now (cmacs-lql-watch--now))
          next)
      (maphash
       (lambda (_name w)
         (let ((at (cond
                    ;; A run in flight needs nothing from the timer but
                    ;; the watchdog.
                    ((cmacs-lql-watcher-in-flight w)
                     (+ (or (cmacs-lql-watcher-started w) now)
                        (cmacs-lql-watcher-timeout w) 10))
                    ((cmacs-lql-watcher-paused w) nil)
                    (t (cmacs-lql-watcher-next-due w)))))
           (when (and at (or (null next) (< at next)))
             (setq next at))))
       cmacs-lql-watch--table)
      (when next
        (setq cmacs-lql-watch--timer
              (run-at-time (if soon
                               (min 0.2 (max 0.05 (- next now)))
                             (max 0.2 (- next now)))
                           nil #'cmacs-lql-watch--tick))))))

(defun cmacs-lql-watch--idle-p ()
  "Non-nil when the user has been idle long enough to snapshot a Lisp source."
  (or noninteractive
      (<= cmacs-lql-watch-min-idle 0)
      (let ((idle (current-idle-time)))
        (and idle (>= (float-time idle) cmacs-lql-watch-min-idle)))))

(defun cmacs-lql-watch--engine-busy-p ()
  "Non-nil when a query holds the LQL environment right now.
Asks the cheapest try-lock helper there is and reads its
`cmacs-lql-busy' signal.  As a side effect a successful ask refreshes
the list of engine source names used by the generation skip."
  (condition-case nil
      (progn
        (when (fboundp 'cmacs-lql--sources)
          (setq cmacs-lql-watch--engine-sources (cmacs-lql--sources)))
        nil)
    (cmacs-lql-busy t)
    ;; Any other failure is not \"busy\"; let the run itself report it.
    (error nil)))

(defun cmacs-lql-watch--generations (watch sources)
  "The generation values of SOURCES for WATCH, or nil when one has none.
Called as the owner: a source's generation may depend on who asks."
  (catch 'none
    (cmacs-lql-watch--as-owner watch
      (mapcar
       (lambda (name)
         (let ((fn (plist-get (gethash name cmacs-lql--sources) :generation)))
           (unless fn (throw 'none nil))
           (cons name (condition-case nil (funcall fn)
                        (error (throw 'none nil))))))
       sources))))

(defun cmacs-lql-watch--closed-p (watch sources)
  "Non-nil when WATCH's result can only change if one of SOURCES does.
SOURCES are the Elisp sources its query names.  True by decree with
:depends `sources'; never with `always'; and with `auto' when the query
mentions no engine source or source command, nothing matching
`cmacs-lql-watch-volatile-regexp', and the engine's source list is
known -- so that \"it names no engine source\" is something checked, not
assumed."
  (let ((query (cmacs-lql-watcher-query watch)))
    (pcase (cmacs-lql-watcher-depends watch)
      ('always nil)
      ('sources t)
      (_ (and cmacs-lql-watch--engine-sources
              (not (string-match-p cmacs-lql-watch-volatile-regexp query))
              (not (cl-some (lambda (name)
                              (and (not (member name sources))
                                   (cmacs-lql-watch--mentions-p name query)))
                            cmacs-lql-watch--engine-sources)))))))

(defun cmacs-lql-watch--skip (watch reason delay)
  "Record that WATCH skipped a tick for REASON; look again in DELAY seconds."
  (cl-incf (cmacs-lql-watcher-skipped watch))
  (setf (cmacs-lql-watcher-last-skip watch) reason
        (cmacs-lql-watcher-next-due watch) (+ (cmacs-lql-watch--now) delay)))

(defun cmacs-lql-watch--tick ()
  "Run whichever watch is due, if now is a good moment.  Never signals."
  (setq cmacs-lql-watch--timer nil)
  (condition-case err
      (cmacs-lql-watch--tick-1)
    (error (message "cmacs-lql-watch: tick failed: %s"
                    (error-message-string err))))
  (cmacs-lql-watch--arm)
  (cmacs-lql-watch--refresh-list))

(defun cmacs-lql-watch--tick-1 ()
  "The body of `cmacs-lql-watch--tick'."
  (let ((now (cmacs-lql-watch--now))
        in-flight due)
    ;; The watchdog.  A callback always arrives -- the C side promises
    ;; one -- but a watch stuck `in flight' would stop every other watch
    ;; for good, so a run that outlives its own timeout by a margin is
    ;; cancelled and counted as a failure.
    (dolist (w (cmacs-lql-watch--all))
      (when (cmacs-lql-watcher-in-flight w)
        (if (> (- now (or (cmacs-lql-watcher-started w) now))
               (+ (cmacs-lql-watcher-timeout w) 10))
            (let ((id (cmacs-lql-watcher-in-flight w)))
              (when (and (integerp id) (fboundp 'cmacs-lql--cancel))
                (ignore-errors (cmacs-lql--cancel id)))
              (setf (cmacs-lql-watcher-token w) nil)
              (cmacs-lql-watch--fail w "the query never came back"))
          (setq in-flight t))))
    ;; One watch query at a time.  The one in flight re-arms when it
    ;; lands.
    (unless in-flight
      (dolist (w (cmacs-lql-watch--all))
        (when (and (not (cmacs-lql-watcher-paused w))
                   (<= (cmacs-lql-watcher-next-due w) now))
          (push w due)))
      ;; Longest overdue first, so a slow watch cannot starve the rest;
      ;; by name among equals (the sort is stable).
      (setq due (sort (nreverse due) (lambda (a b) (< (cmacs-lql-watcher-next-due a)
                                           (cmacs-lql-watcher-next-due b)))))
      (catch 'done
        (let ((busy 'unknown))
          (dolist (w due)
            (let* ((sources (cmacs-lql-watch--lisp-sources
                             (cmacs-lql-watcher-query w)))
                   (gens (and sources
                              (> cmacs-lql-watch-max-generation-skips 0)
                              (cmacs-lql-watch--generations w sources))))
              (cond
               ;; Its snapshot would run under the user's fingers.
               ((and sources (not (cmacs-lql-watch--idle-p)))
                (cmacs-lql-watch--skip w 'typing
                                       (max 0.25 cmacs-lql-watch-min-idle)))
               ;; Nothing it reads has moved: the answer is the one we
               ;; have.
               ((and gens
                     (cmacs-lql-watcher-baseline w)
                     (equal gens (cmacs-lql-watcher-generation w))
                     (< (cmacs-lql-watcher-gen-skips w)
                        cmacs-lql-watch-max-generation-skips)
                     (cmacs-lql-watch--closed-p w sources))
                (cl-incf (cmacs-lql-watcher-gen-skips w))
                (cmacs-lql-watch--skip w 'unchanged
                                       (cmacs-lql-watcher-every w)))
               (t
                (when (eq busy 'unknown)
                  (setq busy (cmacs-lql-watch--engine-busy-p)))
                (if busy
                    ;; Somebody's query is running.  Theirs comes first,
                    ;; and so does the next one they are about to run.
                    (progn
                      (dolist (v due)
                        (when (<= (cmacs-lql-watcher-next-due v) now)
                          (cmacs-lql-watch--skip v 'busy
                                                 cmacs-lql-watch-busy-retry)))
                      (throw 'done nil))
                  (setf (cmacs-lql-watcher-pending-generation w) gens)
                  (cmacs-lql-watch--submit w)
                  (throw 'done nil)))))))))))

(defun cmacs-lql-watch--submit (watch)
  "Submit WATCH's query.  Its result arrives in `cmacs-lql-watch--deliver'."
  (let ((name (cmacs-lql-watcher-name watch))
        (token (cl-incf cmacs-lql-watch--sequence)))
    (setf (cmacs-lql-watcher-in-flight watch) t
          (cmacs-lql-watcher-token watch) token
          (cmacs-lql-watcher-started watch) (cmacs-lql-watch--now)
          (cmacs-lql-watcher-last-skip watch) nil)
    (condition-case err
        (let ((id (cmacs-lql-watch--as-owner watch
                    (cmacs-lql-run
                     (cmacs-lql-watcher-query watch)
                     (lambda (payload)
                       (cmacs-lql-watch--deliver name token payload))
                     :max-rows (cmacs-lql-watcher-max-rows watch)
                     :timeout (cmacs-lql-watcher-timeout watch)))))
          ;; Still ours?  (A stub, or one day the engine, may have
          ;; called back before returning.)
          (when (and (eq (cmacs-lql-watcher-token watch) token)
                     (cmacs-lql-watcher-in-flight watch))
            (setf (cmacs-lql-watcher-in-flight watch) (or id t))))
      (error
       (setf (cmacs-lql-watcher-token watch) nil)
       (cmacs-lql-watch--fail watch (error-message-string err))))))

(defun cmacs-lql-watch--backoff (watch)
  "Seconds WATCH waits before its next run, given its failures in a row."
  (let ((every (cmacs-lql-watcher-every watch))
        (failures (cmacs-lql-watcher-failures watch)))
    (if (<= failures 0)
        every
      (min (max every cmacs-lql-watch-max-backoff)
           (* every (expt 2 (min failures 20)))))))

(defun cmacs-lql-watch--fail (watch message)
  "Record that WATCH's run failed with MESSAGE and back it off."
  (let ((first (zerop (cmacs-lql-watcher-failures watch))))
    (cl-incf (cmacs-lql-watcher-failures watch))
    (setf (cmacs-lql-watcher-in-flight watch) nil
          (cmacs-lql-watcher-started watch) nil
          (cmacs-lql-watcher-pending-generation watch) nil
          (cmacs-lql-watcher-last-run watch) (cmacs-lql-watch--now)
          (cmacs-lql-watcher-last-error watch) message
          (cmacs-lql-watcher-next-due watch)
          (+ (cmacs-lql-watch--now) (cmacs-lql-watch--backoff watch)))
    ;; Said once, when it starts.  After that the list buffer has it.
    (when first
      (unless (cmacs-lql-watcher-owner watch)
        (message "cmacs-lql-watch: %s failed: %s (M-x cmacs-lql-watches)"
                 (cmacs-lql-watcher-name watch) message))
      (cmacs-lql-watch--run-hook watch 'cmacs-lql-watch-error-functions
                                 (cmacs-lql-watcher-name watch) message))))

(defun cmacs-lql-watch--deliver (name token payload)
  "Take PAYLOAD, the result of the run TOKEN of the watch NAME.
Runs on the main thread, called from the GLib dispatch.  Never signals."
  (condition-case err
      (let ((watch (cmacs-lql-watch--get name)))
        ;; Removed, replaced, or given up on by the watchdog since: the
        ;; result belongs to nobody.
        (when (and watch (eq (cmacs-lql-watcher-token watch) token))
          (setf (cmacs-lql-watcher-token watch) nil)
          (pcase (car-safe payload)
            (:ok (cmacs-lql-watch--result
                  watch (plist-get (cdr payload) :json)))
            (:error (cmacs-lql-watch--fail
                     watch (format "%s" (cadr payload))))
            (_ (cmacs-lql-watch--fail watch "cancelled")))))
    (error (message "cmacs-lql-watch: %s: %s" name
                    (error-message-string err))))
  ;; Another watch may have been waiting on this one.
  (cmacs-lql-watch--arm t)
  (cmacs-lql-watch--refresh-list))

(defun cmacs-lql-watch--result (watch json)
  "Compare JSON, WATCH's new result, with its last one; fire on a change."
  (if (or (not (stringp json))
          (> (length json) cmacs-lql-watch-max-result-bytes))
      (cmacs-lql-watch--fail
       watch (if (stringp json)
                 (format "result too large (%d characters; the cap is %d)"
                         (length json) cmacs-lql-watch-max-result-bytes)
               "the engine returned no result"))
    (let* ((now (cmacs-lql-watch--now))
           (hash (secure-hash 'sha1 json))
           (first (not (cmacs-lql-watcher-baseline watch)))
           (changed (not (equal hash (cmacs-lql-watcher-hash watch)))))
      (cl-incf (cmacs-lql-watcher-runs watch))
      (setf (cmacs-lql-watcher-in-flight watch) nil
            (cmacs-lql-watcher-started watch) nil
            (cmacs-lql-watcher-last-run watch) now
            (cmacs-lql-watcher-last-error watch) nil
            (cmacs-lql-watcher-failures watch) 0
            (cmacs-lql-watcher-gen-skips watch) 0
            (cmacs-lql-watcher-generation watch)
            (cmacs-lql-watcher-pending-generation watch)
            (cmacs-lql-watcher-pending-generation watch) nil
            (cmacs-lql-watcher-next-due watch)
            (+ now (cmacs-lql-watcher-every watch)))
      ;; Parsing is the expensive half and an unchanged result -- the
      ;; common case by far -- never pays for it.
      (when (or first changed)
        (let* ((table (cmacs-lql-parse json))
               (new (cmacs-lql-watch--rows table))
               (old (cmacs-lql-watcher-rows watch)))
          (setf (cmacs-lql-watcher-hash watch) hash
                (cmacs-lql-watcher-baseline watch) t
                (cmacs-lql-watcher-rows watch) new
                (cmacs-lql-watcher-columns watch) (plist-get table :columns)
                (cmacs-lql-watcher-total watch) (plist-get table :total))
          (cond
           ((and first (not (cmacs-lql-watcher-immediate watch)))
            (cmacs-lql-watch--run-hook
             watch 'cmacs-lql-watch-baseline-functions
             (cmacs-lql-watcher-name watch) new))
           (t
            (when first
              (cmacs-lql-watch--run-hook
               watch 'cmacs-lql-watch-baseline-functions
               (cmacs-lql-watcher-name watch) new))
            (cl-incf (cmacs-lql-watcher-changes watch))
            (setf (cmacs-lql-watcher-last-change watch) now)
            (cmacs-lql-watch--fire
             watch new old
             (cmacs-lql-watch-diff old new
                                   (cmacs-lql-watcher-key watch))))))))))

(defun cmacs-lql-watch--call (watch function &rest args)
  "Call FUNCTION with ARGS for WATCH: guarded, and unable to prompt.
An error -- a prompt included -- is recorded on WATCH.  Returns non-nil
when FUNCTION returned normally."
  (condition-case err
      (let ((inhibit-interaction t))
        (apply function args)
        t)
    ((error quit)
     (setf (cmacs-lql-watcher-callback-error watch)
           (format "%s: %s" (if (symbolp function) function "callback")
                   (error-message-string err)))
     nil)))

(defun cmacs-lql-watch--run-hook (watch hook &rest args)
  "Run each function on HOOK with ARGS, each guarded on its own, for WATCH."
  (dolist (function (and (boundp hook) (symbol-value hook)))
    (when (functionp function)
      (apply #'cmacs-lql-watch--call watch function args))))

(defun cmacs-lql-watch--fire (watch new old diff)
  "Tell everyone WATCH changed from OLD rows to NEW rows by DIFF."
  (let ((start (float-time)))
    (setf (cmacs-lql-watcher-callback-error watch) nil)
    (when (cmacs-lql-watcher-on-change watch)
      (cmacs-lql-watch--call watch (cmacs-lql-watcher-on-change watch)
                             new old diff))
    (when (and new (cmacs-lql-watcher-on-rows watch))
      (cmacs-lql-watch--call watch (cmacs-lql-watcher-on-rows watch) new))
    (cmacs-lql-watch--run-hook watch 'cmacs-lql-watch-change-functions
                               (cmacs-lql-watcher-name watch) new old diff)
    (setf (cmacs-lql-watcher-callback-seconds watch)
          (- (float-time) start))))

;;;; The public API

(defconst cmacs-lql-watch--keys
  '(:every :on-change :on-rows :key :immediate :owner :depends
    :max-rows :timeout :paused)
  "Options `cmacs-lql-watch' itself understands.")

(defun cmacs-lql-watch--check-gated (owner query)
  "Signal unless a watch owned by OWNER may run QUERY."
  (when owner
    (dolist (cell cmacs-lql-watch-agent-gated-sources)
      (when (and (cmacs-lql-watch--mentions-p (car cell) query)
                 (not (and (boundp (cdr cell)) (symbol-value (cdr cell)))))
        (signal 'cmacs-lql-watch-error
                (list (format "the `%s' source is not exposed to agents (%s)"
                              (car cell) (cdr cell))))))))

;;;###autoload
(defun cmacs-lql-watch (name query &rest plist)
  "Register the standing LQL QUERY as the watch NAME.  Return NAME, a string.

The query is run every so often, and when its result differs from the
last one the watch fires.  The first result is the baseline: it fires
nothing unless :immediate.  A second watch with the same NAME replaces
the first.  PLIST:

:every SECONDS    How often to run (default
                  `cmacs-lql-watch-default-interval', never less than
                  `cmacs-lql-watch-min-interval').
:on-change FN     Called with (NEW-ROWS OLD-ROWS DIFF).  Rows are alists
                  of (COLUMN-NAME . VALUE), NULL being nil.  DIFF is
                  what `cmacs-lql-watch-diff' returns: a plist of
                  :added, :removed, :changed and :reordered.
:key COLUMN       A column name, or a list of them, that identifies a
                  row.  With it DIFF can tell a changed row from one
                  removed and one added.
:on-rows FN       Called with (NEW-ROWS) on a change that leaves the
                  result non-empty -- \"when there is something\".
:immediate BOOL   Fire on the first result too, with OLD-ROWS nil.
:depends HOW      When a tick may be skipped without running: `auto'
                  (the default; when the query names only Elisp sources
                  that have generation functions and none moved),
                  `sources' (trust that regardless of what else the
                  query reads), or `always' (never skip).
:max-rows N       Rows kept and compared (default and ceiling
                  `cmacs-lql-watch-max-rows').
:timeout SECONDS  Limit on one run (default `cmacs-lql-watch-timeout').
:paused BOOL      Register it paused.
:owner ID         Who the watch belongs to, for an agent's watch; see
                  cmacs-lql-watch-tools.el.  Yours have none.

Further keys belong to consumers (`cmacs-lql-watch-extra-keys'): :event,
:bar and :toast, see cmacs-lql-watch-sinks.el.

Callbacks run on the main thread with `inhibit-interaction' bound: one
that prompts gets an error, which is recorded on the watch like any
other error and shown by \\[cmacs-lql-watches].  Keep them quick.

A query that names an Elisp source (buffers, notes, activity, ...) runs
only once Emacs has been idle for `cmacs-lql-watch-min-idle' seconds."
  (let* ((name (cmacs-lql-watch--name name))
         (owner (plist-get plist :owner))
         (old (cmacs-lql-watch--get name))
         (every (max cmacs-lql-watch-min-interval
                     (or (plist-get plist :every)
                         cmacs-lql-watch-default-interval)))
         (depends (or (plist-get plist :depends) 'auto)))
    (unless (and (stringp query) (not (string-blank-p query)))
      (signal 'cmacs-lql-watch-error (list "a watch needs a query")))
    (unless (numberp every)
      (signal 'wrong-type-argument (list 'numberp every)))
    (unless (memq depends '(auto sources always))
      (signal 'cmacs-lql-watch-error
              (list (format ":depends is auto, sources or always, not %S"
                            depends))))
    (cl-loop for (key _value) on plist by #'cddr
             unless (or (memq key cmacs-lql-watch--keys)
                        (memq key cmacs-lql-watch-extra-keys))
             do (signal 'cmacs-lql-watch-error
                        (list (format "unknown watch option %S" key))))
    (dolist (key '(:on-change :on-rows))
      (let ((fn (plist-get plist key)))
        (unless (or (null fn) (functionp fn) (symbolp fn))
          (signal 'wrong-type-argument (list 'functionp fn)))))
    (unless (cmacs-lql-available-p)
      (signal 'cmacs-lql-unavailable (list "rebuild cmacs --with-cmacs-lql")))
    ;; A name is one owner's: an agent must not be able to replace your
    ;; watch (or another agent's) by choosing its name.
    (when (and old (not (equal (cmacs-lql-watcher-owner old) owner)))
      (signal 'cmacs-lql-watch-error
              (list (format "a watch called %s already exists" name))))
    (cmacs-lql-watch--check-gated owner query)
    ;; The run of the watch being replaced is nobody's now.
    (when-let* ((id (and old (cmacs-lql-watcher-in-flight old))))
      (when (and (integerp id) (fboundp 'cmacs-lql--cancel))
        (ignore-errors (cmacs-lql--cancel id))))
    (unless old
      (when (>= (hash-table-count cmacs-lql-watch--table) cmacs-lql-watch-max)
        (signal 'cmacs-lql-watch-error
                (list (format "there are already %d watches (`cmacs-lql-watch-max')"
                              cmacs-lql-watch-max))))
      (when (and owner
                 (>= (cl-count owner (hash-table-values cmacs-lql-watch--table)
                               :key #'cmacs-lql-watcher-owner :test #'equal)
                     cmacs-lql-watch-max-per-owner))
        (signal 'cmacs-lql-watch-error
                (list (format "%s already holds %d watches, the most one owner may"
                              owner cmacs-lql-watch-max-per-owner)))))
    (puthash
     name
     (cmacs-lql-watcher--make
      :name name :query query :every every :owner owner
      :key (plist-get plist :key) :depends depends
      :on-change (plist-get plist :on-change)
      :on-rows (plist-get plist :on-rows)
      :immediate (and (plist-get plist :immediate) t)
      :max-rows (max 1 (min (or (plist-get plist :max-rows)
                                cmacs-lql-watch-max-rows)
                            cmacs-lql-watch-max-rows
                            (or cmacs-lql-max-rows most-positive-fixnum)))
      :timeout (max 1 (or (plist-get plist :timeout) cmacs-lql-watch-timeout))
      :props (copy-sequence plist)
      :paused (and (plist-get plist :paused) t)
      ;; Due now: the baseline is wanted soon, and the tick decides
      ;; whether \"now\" is a good moment.
      :next-due (cmacs-lql-watch--now))
     cmacs-lql-watch--table)
    (cmacs-lql-watch--arm)
    (cmacs-lql-watch--refresh-list)
    name))

;;;###autoload
(defmacro cmacs-lql-define-watch (name query &rest plist)
  "Define the standing LQL QUERY as the watch NAME, for an init file.
NAME is an unquoted symbol; QUERY and PLIST are as for `cmacs-lql-watch'.
Does nothing, with a message, in a cmacs built without LQL -- an init
file should not fail to load over it.

  (cmacs-lql-define-watch big-buffers
    \"fetch buffers | filter size > 5000000 | fields name, size\"
    :every 300 :key \"name\"
    :on-change (lambda (_new _old diff)
                 (dolist (row (plist-get diff :added))
                   (message \"%s is large\" (cdr (assoc \"name\" row))))))"
  (declare (indent 2))
  `(condition-case err
       (cmacs-lql-watch ',name ,query ,@plist)
     (cmacs-lql-unavailable
      (message "cmacs-lql-watch: %s not defined: %s" ',name
               (error-message-string err))
      nil)))

;;;###autoload
(defun cmacs-lql-unwatch (name)
  "Remove the watch NAME.  Return non-nil when there was one.
A run of it still in flight is cancelled and its result ignored."
  (interactive (list (cmacs-lql-watch--read "Remove watch: ")))
  (let* ((name (cmacs-lql-watch--name name))
         (watch (cmacs-lql-watch--get name)))
    (when watch
      (let ((id (cmacs-lql-watcher-in-flight watch)))
        (when (and (integerp id) (fboundp 'cmacs-lql--cancel))
          (ignore-errors (cmacs-lql--cancel id))))
      (remhash name cmacs-lql-watch--table)
      (dolist (function cmacs-lql-watch-removed-functions)
        (condition-case nil
            (funcall function name (cmacs-lql-watcher-owner watch))
          (error nil)))
      (cmacs-lql-watch--arm)
      (cmacs-lql-watch--refresh-list)
      t)))

(defun cmacs-lql-unwatch-owner (owner)
  "Remove every watch belonging to OWNER.  Return how many there were."
  (let ((n 0))
    (when owner
      (dolist (w (cmacs-lql-watch--all))
        (when (equal (cmacs-lql-watcher-owner w) owner)
          (cmacs-lql-unwatch (cmacs-lql-watcher-name w))
          (cl-incf n))))
    n))

(defun cmacs-lql-watch-state (watch)
  "The state of WATCH, a watcher, as a symbol.
One of `paused', `running', `error', `waiting' (never run yet) or `ok'."
  (cond ((cmacs-lql-watcher-paused watch) 'paused)
        ((cmacs-lql-watcher-in-flight watch) 'running)
        ((cmacs-lql-watcher-last-error watch) 'error)
        ((not (cmacs-lql-watcher-baseline watch)) 'waiting)
        (t 'ok)))

(defun cmacs-lql-watch--describe (w)
  "A plist describing the watcher W."
  (list :name (cmacs-lql-watcher-name w)
        :query (cmacs-lql-watcher-query w)
        :every (cmacs-lql-watcher-every w)
        :owner (cmacs-lql-watcher-owner w)
        :key (cmacs-lql-watcher-key w)
        :state (cmacs-lql-watch-state w)
        :rows (length (cmacs-lql-watcher-rows w))
        :total (cmacs-lql-watcher-total w)
        :runs (cmacs-lql-watcher-runs w)
        :changes (cmacs-lql-watcher-changes w)
        :failures (cmacs-lql-watcher-failures w)
        :skipped (cmacs-lql-watcher-skipped w)
        :last-skip (cmacs-lql-watcher-last-skip w)
        :last-run (cmacs-lql-watcher-last-run w)
        :last-change (cmacs-lql-watcher-last-change w)
        :next-due (cmacs-lql-watcher-next-due w)
        :last-error (cmacs-lql-watcher-last-error w)
        :callback-error (cmacs-lql-watcher-callback-error w)
        :callback-seconds (cmacs-lql-watcher-callback-seconds w)))

(defun cmacs-lql-watch-list (&optional owner)
  "Every watch, as a list of plists, sorted by name.
With OWNER, only that owner's; the symbol `user' means yours (no owner).
Each plist has :name :query :every :owner :key :state :rows :total :runs
:changes :failures :skipped :last-skip :last-run :last-change :next-due
:last-error :callback-error and :callback-seconds."
  (cl-loop for w in (cmacs-lql-watch--all)
           when (or (null owner)
                    (and (eq owner 'user) (null (cmacs-lql-watcher-owner w)))
                    (equal owner (cmacs-lql-watcher-owner w)))
           collect (cmacs-lql-watch--describe w)))

(defun cmacs-lql-watch-get (name property)
  "PROPERTY of the watch NAME, or nil.
PROPERTY is a key of `cmacs-lql-watch-list's plists, or any option the
watch was registered with (:on-change, a consumer's :bar, ...)."
  (when-let* ((w (cmacs-lql-watch--get name)))
    (let ((described (cmacs-lql-watch--describe w)))
      (if (plist-member described property)
          (plist-get described property)
        (plist-get (cmacs-lql-watcher-props w) property)))))

(defun cmacs-lql-watch-rows (name)
  "The rows of the watch NAME's last result, as alists.  Nil before one."
  (when-let* ((w (cmacs-lql-watch--get name)))
    (cmacs-lql-watcher-rows w)))

(defun cmacs-lql-watch--read (prompt)
  "Read a watch name with PROMPT."
  (let ((names (mapcar #'cmacs-lql-watcher-name (cmacs-lql-watch--all))))
    (unless names (user-error "No watches"))
    (completing-read prompt names nil t)))

(defun cmacs-lql-watch--must (name)
  "The watcher NAME, or a `user-error'."
  (or (cmacs-lql-watch--get name)
      (user-error "No watch called %s" name)))

(defun cmacs-lql-watch-run-now (name)
  "Make the watch NAME due now.
It runs at the next good moment, not necessarily this instant: the
rules about a busy engine and a typing user still hold.  Clears a
backoff."
  (interactive (list (cmacs-lql-watch--read "Run watch: ")))
  (let ((w (cmacs-lql-watch--must name)))
    (setf (cmacs-lql-watcher-next-due w) (cmacs-lql-watch--now)
          (cmacs-lql-watcher-failures w) 0
          ;; Asked for by name: do not answer from source generations.
          (cmacs-lql-watcher-generation w) nil)
    (cmacs-lql-watch--arm)
    (cmacs-lql-watch--refresh-list)))

(defun cmacs-lql-watch-pause (name)
  "Stop running the watch NAME until it is resumed."
  (interactive (list (cmacs-lql-watch--read "Pause watch: ")))
  (setf (cmacs-lql-watcher-paused (cmacs-lql-watch--must name)) t)
  (cmacs-lql-watch--arm)
  (cmacs-lql-watch--refresh-list))

(defun cmacs-lql-watch-resume (name)
  "Run the watch NAME again, starting now."
  (interactive (list (cmacs-lql-watch--read "Resume watch: ")))
  (let ((w (cmacs-lql-watch--must name)))
    (setf (cmacs-lql-watcher-paused w) nil
          (cmacs-lql-watcher-next-due w) (cmacs-lql-watch--now))
    (cmacs-lql-watch--arm)
    (cmacs-lql-watch--refresh-list)))

;;;; Persistence -- deliberately small

(defun cmacs-lql-watch--data-p (value)
  "Non-nil when VALUE can be written to a custom file and read back."
  (cond ((or (stringp value) (numberp value) (symbolp value)) t)
        ((consp value) (and (cmacs-lql-watch--data-p (car value))
                            (cmacs-lql-watch--data-p (cdr value))))
        (t nil)))

(defun cmacs-lql-watch-save (name)
  "Save the watch NAME to `cmacs-lql-watch-saved' so it can be restored.
Only a watch whose options are plain data can be saved: a named
function is fine, a lambda is not -- define that one in your init file."
  (interactive (list (cmacs-lql-watch--read "Save watch: ")))
  (let* ((w (cmacs-lql-watch--must name))
         (props (cmacs-lql-watcher-props w)))
    (when (cmacs-lql-watcher-owner w)
      (user-error "%s belongs to an agent's task; it is not yours to save" name))
    (unless (cmacs-lql-watch--data-p props)
      (user-error "%s has options that are not plain data (a lambda?)" name))
    (customize-save-variable
     'cmacs-lql-watch-saved
     (cons (cons (cmacs-lql-watcher-name w)
                 (cons (cmacs-lql-watcher-query w) props))
           (cl-remove (cmacs-lql-watcher-name w) cmacs-lql-watch-saved
                      :key #'car :test #'equal)))
    (message "Saved the watch %s" name)))

(defun cmacs-lql-watch-forget (name)
  "Take the watch NAME out of `cmacs-lql-watch-saved'.  It keeps running."
  (interactive
   (list (completing-read "Forget saved watch: "
                          (mapcar #'car cmacs-lql-watch-saved) nil t)))
  (customize-save-variable
   'cmacs-lql-watch-saved
   (cl-remove (cmacs-lql-watch--name name) cmacs-lql-watch-saved
              :key #'car :test #'equal)))

;;;###autoload
(defun cmacs-lql-watch-restore-saved ()
  "Register every watch in `cmacs-lql-watch-saved'.  Return how many.
Call it from your init file.  One that cannot be registered is reported
and skipped; the rest still are."
  (interactive)
  (let ((n 0))
    (dolist (entry cmacs-lql-watch-saved)
      (condition-case err
          (progn (apply #'cmacs-lql-watch (car entry) (cadr entry) (cddr entry))
                 (cl-incf n))
        (error (message "cmacs-lql-watch: could not restore %s: %s"
                        (car-safe entry) (error-message-string err)))))
    n))

;;;###autoload
(defun cmacs-lql-watch-add (name query every)
  "Interactively watch QUERY as NAME every EVERY seconds.
A watch made this way announces a change with a toast (or a message
where there is no bar); \\[cmacs-lql-watches] then `s' saves it."
  (interactive
   (list (read-string "Watch name: ")
         (read-string "LQL query: " nil 'cmacs-lql-history)
         (read-number "Every (seconds): " cmacs-lql-watch-default-interval)))
  (when (string-blank-p name) (user-error "A watch needs a name"))
  (apply #'cmacs-lql-watch name query :every every
         (and (memq :toast cmacs-lql-watch-extra-keys) '(:toast t)))
  (message "Watching %s every %ss" name every))

;;;; The list buffer

(defconst cmacs-lql-watch--list-buffer "*LQL Watches*")

(defun cmacs-lql-watch--ago (time)
  "TIME, a float or nil, as a short \"how long ago\"."
  (if (null time)
      "-"
    (let ((s (max 0 (round (- (cmacs-lql-watch--now) time)))))
      (cond ((< s 90) (format "%ds" s))
            ((< s 5400) (format "%dm" (/ s 60)))
            ((< s 129600) (format "%dh" (/ s 3600)))
            (t (format "%dd" (/ s 86400)))))))

(defun cmacs-lql-watch--entries ()
  "The `tabulated-list-entries' of the watch list."
  (mapcar
   (lambda (w)
     (let* ((state (cmacs-lql-watch-state w))
            (info (or (cmacs-lql-watcher-last-error w)
                      (cmacs-lql-watcher-callback-error w)
                      (replace-regexp-in-string
                       "[ \t\n]+" " " (cmacs-lql-watcher-query w)))))
       (list (cmacs-lql-watcher-name w)
             (vector
              (cmacs-lql-watcher-name w)
              (propertize
               (if (and (eq state 'error)
                        (> (cmacs-lql-watcher-failures w) 1))
                   (format "error x%d" (cmacs-lql-watcher-failures w))
                 (symbol-name state))
               'face (pcase state
                       ('error 'error)
                       ('paused 'shadow)
                       ('running 'warning)
                       (_ 'success)))
              (format "%ss" (cmacs-lql-watcher-every w))
              (if (cmacs-lql-watcher-baseline w)
                  (number-to-string (length (cmacs-lql-watcher-rows w)))
                "-")
              (number-to-string (cmacs-lql-watcher-runs w))
              (number-to-string (cmacs-lql-watcher-changes w))
              (cmacs-lql-watch--ago (cmacs-lql-watcher-last-run w))
              (cmacs-lql-watch--ago (cmacs-lql-watcher-last-change w))
              (format "%s" (or (cmacs-lql-watcher-owner w) "-"))
              (if (or (cmacs-lql-watcher-last-error w)
                      (cmacs-lql-watcher-callback-error w))
                  (propertize info 'face 'error)
                info)))))
   (cmacs-lql-watch--all)))

(defun cmacs-lql-watch--refresh-list ()
  "Redraw the watch list, when somebody is looking at it."
  (let ((buffer (get-buffer cmacs-lql-watch--list-buffer)))
    (when (and buffer (get-buffer-window buffer t))
      (with-current-buffer buffer
        (ignore-errors (tabulated-list-print t))))))

(defun cmacs-lql-watch--at-point ()
  "The name of the watch on this line of the list, or a `user-error'."
  (or (tabulated-list-get-id) (user-error "No watch on this line")))

(defun cmacs-lql-watches-run-now ()
  "Make the watch at point due now."
  (interactive nil cmacs-lql-watches-mode)
  (cmacs-lql-watch-run-now (cmacs-lql-watch--at-point)))

(defun cmacs-lql-watches-toggle-pause ()
  "Pause the watch at point, or resume it."
  (interactive nil cmacs-lql-watches-mode)
  (let ((name (cmacs-lql-watch--at-point)))
    (if (cmacs-lql-watcher-paused (cmacs-lql-watch--must name))
        (cmacs-lql-watch-resume name)
      (cmacs-lql-watch-pause name))))

(defun cmacs-lql-watches-remove ()
  "Remove the watch at point."
  (interactive nil cmacs-lql-watches-mode)
  (let ((name (cmacs-lql-watch--at-point)))
    (when (yes-or-no-p (format "Remove the watch %s? " name))
      (cmacs-lql-unwatch name)
      (tabulated-list-print t))))

(defun cmacs-lql-watches-save ()
  "Save the watch at point to `cmacs-lql-watch-saved'."
  (interactive nil cmacs-lql-watches-mode)
  (cmacs-lql-watch-save (cmacs-lql-watch--at-point)))

(defun cmacs-lql-watches-describe ()
  "Show everything about the watch at point: query, errors, last rows."
  (interactive nil cmacs-lql-watches-mode)
  (let* ((name (cmacs-lql-watch--at-point))
         (w (cmacs-lql-watch--must name))
         (described (cmacs-lql-watch--describe w)))
    (with-help-window (format "*LQL Watch: %s*" name)
      (princ (format "Watch %s\n\n%s\n\n" name (cmacs-lql-watcher-query w)))
      (cl-loop for (key value) on described by #'cddr
               unless (memq key '(:name :query))
               do (princ (format "%-18s %s\n"
                                 (substring (symbol-name key) 1)
                                 (cond
                                  ((and value (memq key '(:last-run :last-change
                                                          :next-due)))
                                   (format-time-string "%F %T" value))
                                  ((null value) "-")
                                  (t value)))))
      (princ (format "\nLast result (%d rows shown):\n"
                     (min 20 (length (cmacs-lql-watcher-rows w)))))
      (dolist (row (cl-subseq (cmacs-lql-watcher-rows w) 0
                              (min 20 (length (cmacs-lql-watcher-rows w)))))
        (princ (format "  %s\n"
                       (mapconcat (lambda (cell)
                                    (format "%s=%s" (car cell)
                                            (if (null (cdr cell)) "null"
                                              (cdr cell))))
                                  row "  ")))))))

(defvar-keymap cmacs-lql-watches-mode-map
  :doc "Keymap of the LQL watch list."
  :parent tabulated-list-mode-map
  "r" #'cmacs-lql-watches-run-now
  "p" #'cmacs-lql-watches-toggle-pause
  "d" #'cmacs-lql-watches-remove
  "k" #'cmacs-lql-watches-remove
  "s" #'cmacs-lql-watches-save
  "a" #'cmacs-lql-watch-add
  "RET" #'cmacs-lql-watches-describe)

(define-derived-mode cmacs-lql-watches-mode tabulated-list-mode "LQL-Watches"
  "The standing LQL queries: state, last run, last change, last error.

\\{cmacs-lql-watches-mode-map}"
  (setq tabulated-list-format
        [("Name" 22 t) ("State" 10 t) ("Every" 7 nil) ("Rows" 6 nil)
         ("Runs" 6 nil) ("Chg" 5 nil) ("Ran" 6 nil) ("Changed" 8 nil)
         ("Owner" 14 t) ("Query / error" 0 nil)]
        tabulated-list-sort-key '("Name" . nil)
        tabulated-list-entries #'cmacs-lql-watch--entries)
  (tabulated-list-init-header))

;;;###autoload
(defun cmacs-lql-watches ()
  "List the standing LQL queries.
`r' runs one now, `p' pauses or resumes it, `d' removes it, `s' saves
it, `a' adds one, RET shows its query, errors and last rows, `g'
redraws."
  (interactive)
  (let ((buffer (get-buffer-create cmacs-lql-watch--list-buffer)))
    (with-current-buffer buffer
      (cmacs-lql-watches-mode)
      (tabulated-list-print))
    (pop-to-buffer buffer)))

(provide 'cmacs-lql-watch)

;; The shipped consumers.  After `provide', because they are written
;; against this file's public API and require it back.
(defvar cmacs-lql-watch-sinks--loading)
(unless (bound-and-true-p cmacs-lql-watch-sinks--loading)
  (require 'cmacs-lql-watch-sinks nil t))

;;; cmacs-lql-watch.el ends here
