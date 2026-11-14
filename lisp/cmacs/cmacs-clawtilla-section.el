;;; cmacs-clawtilla-section.el --- Automation, Work and Library -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

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

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Automation (Routines, Triggers), Work (Tasks, Decisions, Flow,
;; Activity, Fleet) and Library (Skills, Memory) -- the three sections
;; that are a list of things and a few verbs each.
;;
;; Activity and Fleet are the two pages whose reply is more than rows:
;; Activity ages every running turn against the daemon's clock and sums
;; its recent steps through the library; Fleet draws the library's own
;; summary, budget line and fourteen-day strip beside each agent's cost.
;; Both fetch the raw reply and hand it to C, because the figures and
;; sentences are libclawt's and the reply must reach it as sent.
;;
;; One buffer kind serves all of them, and the grouping is not written
;; here: a section's pages come from `clawt_section_page_count' and its
;; labels from the library, so a page added to clawtilla appears here
;; with no edit.  What IS written here is a renderer and a verb list per
;; page, because those are genuinely per-page.
;;
;; A page nobody has taught this file about still appears in the tab row
;; and says so, rather than being silently absent -- which is the
;; failure mode `make parity' exists to catch, arriving one release
;; early.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-grok)

(declare-function cmacs-clawtilla--time-label "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--activity-elapsed "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--activity-stop-prompt
                  "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--step-summary "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--fleet-payload "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--fleet-view "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--format-cost "cmacs-clawtilla-defuns.c")

(defvar-local cmacs-clawtilla-section--nick nil)
(defvar-local cmacs-clawtilla-section--page nil)
(defvar-local cmacs-clawtilla-section--rows nil)
(defvar-local cmacs-clawtilla-section--agent nil
  "The agent this section is scoped to, when it is scoped to one.")
(defvar-local cmacs-clawtilla-section--reply nil
  "The whole reply the current page was drawn from.

Most pages need only their rows; Activity needs the daemon's `now' to
age its turns by, and Fleet needs the totals, the budget and the strip
that sit beside the rows.")
(defvar-local cmacs-clawtilla-section--period nil
  "The Fleet page's period, an index into the \"usage-period\" family.

nil is the library's own default, `CLAWT_USAGE_PERIOD_DEFAULT'.")
(defvar-local cmacs-clawtilla-section--settled nil
  "Non-nil when the Decisions page lists settled decisions too.")

(defvar cmacs-clawtilla-section--settled-how (make-hash-table :test 'equal)
  "How each decision this session saw settle ended, by decision id.

`decision.list' answers a decision's `state' and not how it got there;
the `how' -- answered, dismissed, defaulted or deleted -- arrives only on
the `decision.settled' event.  Kept here as it passes, so a settled row
can say which.")

(defun cmacs-clawtilla-section--need-agent ()
  "Return the agent this section is scoped to, asking if it is not.

Some pages have no fleet-wide answer -- an agent's memories are its
own, and which slash commands exist depends on which skills it has.
Asking is better than sending the frame without one and reporting the
daemon's \"which agent?\" back at somebody who never chose."
  (or cmacs-clawtilla-section--agent
      (setq cmacs-clawtilla-section--agent
            (read-string "Which agent? "))))

(defun cmacs-clawtilla-section--scope ()
  "Return the agent scope as a payload fragment, or nil."
  (when cmacs-clawtilla-section--agent
    (list (cons 'agent cmacs-clawtilla-section--agent))))


;;;; What each page is.

(defconst cmacs-clawtilla-section-pages
  `(("routines"
     :list "routine.list" :rows routines :type routine
     :row ,(lambda (row)
             (format "%-20s %-14s %-10s %s"
                     (or (alist-get 'id row) "?")
                     (or (alist-get 'schedule row) "manual")
                     ;; A routine that did not fire because the machine
                     ;; was asleep is MISSED, not failed.  Drawing it as
                     ;; broken trains you to ignore the one that is.
                     (propertize (or (alist-get 'state row) "")
                                 'face (pcase (alist-get 'state row)
                                         ("missed" 'cmacs-clawtilla-dim)
                                         ("failed" 'cmacs-clawtilla-error)
                                         (_ 'cmacs-clawtilla-running)))
                     (cmacs-clawtilla-dim
                      (concat
                       (or (cmacs-clawtilla--time-label
                            (or (alist-get 'last_run row) 0))
                           "never run")
                       (if (stringp (alist-get 'model row))
                           (unless (string-empty-p (alist-get 'model row))
                             (format " · on %s" (alist-get 'model row)))
                         "")
                       (if (eq t (alist-get 'read_only row)) " · read-only" "")
                       (if (eq t (alist-get 'proactive row)) " · proactive" "")
                       (if (eq t (alist-get 'locked row)) " · locked" ""))))))
    ("triggers"
     :list "trigger.list" :rows triggers :type trigger
     :row ,(lambda (row)
             (format "%-20s %-18s %s"
                     (or (alist-get 'id row) "?")
                     (or (alist-get 'kind row) "")
                     (cmacs-clawtilla-dim (or (alist-get 'agent row) "")))))
    ("tasks"
     :list "task.list" :rows tasks :type task
     :row ,(lambda (row)
             (format "%-12s %-12s %-10s %s"
                     (or (alist-get 'id row) "?")
                     (or (alist-get 'assignee row) "?")
                     (propertize (or (alist-get 'state row) "")
                                 'face (cmacs-clawtilla-state-face
                                        (alist-get 'state row)))
                     (or (alist-get 'title row) ""))))
    ("decisions"
     :list "decision.list" :rows decisions :type decision
     :payload ,(lambda ()
                 ;; Settled ones only when asked for: the inbox is what
                 ;; is still waiting, and a record of what was decided
                 ;; is a different question.
                 (when cmacs-clawtilla-section--settled
                   (list (cons 'open :false))))
     :row ,#'cmacs-clawtilla-section--decision-row)
    ("activity"
     :list "activity.list" :type turn
     :load ,#'cmacs-clawtilla-section--load-activity
     :draw ,#'cmacs-clawtilla-section--draw-activity)
    ("fleet"
     :list "usage.summary" :type fleet-agent
     :load ,#'cmacs-clawtilla-section--load-fleet
     :draw ,#'cmacs-clawtilla-section--draw-fleet)
    ("grok"
     ;; Two frames, bots and jobs, and a composer: cmacs-clawtilla-grok.el.
     :list "grok.jobs" :type grok-job
     :load ,#'cmacs-clawtilla-grok--load
     :draw ,#'cmacs-clawtilla-grok-draw)
    ("flow"
     :list "room.history" :rows messages :type message
     :payload ((room . "flow") (as . "user"))
     :row ,(lambda (row)
             (format "%-12s %s"
                     (or (alist-get 'sender row) "?")
                     (string-replace "\n" " " (or (alist-get 'body row) "")))))
    ("skills"
     :list "skill.list" :rows skills :type skill
     :row ,(lambda (row)
             (format "%-24s %-9s %s"
                     (or (alist-get 'id row) (alist-get 'name row) "?")
                     ;; An imported skill arrives switched off, and that
                     ;; is a state worth drawing rather than an absence.
                     (if (eq t (alist-get 'enabled row))
                         (propertize "enabled" 'face 'cmacs-clawtilla-running)
                       (propertize "off" 'face 'cmacs-clawtilla-stopped))
                     (cmacs-clawtilla-dim
                      (or (alist-get 'description row) "")))))
    ("memory"
     :list "memory.list" :rows memories :type memory :needs-agent t
     :row ,(lambda (row)
             ;; The scope says which store it came out of -- the agent's
             ;; own, its team's, or the fleet's.  A listing that mixed
             ;; them without saying so would turn two different claims
             ;; into the same row.
             (format "%-7s %-10s %s"
                     (or (alist-get 'scope row) "")
                     (or (alist-get 'category row) "")
                     (string-replace "\n" " "
                                     (or (alist-get 'summary row)
                                         (alist-get 'content row) ""))))))
  "How each page is fetched and drawn.

Only the parts that are genuinely per-page.  Which pages exist, what
they are called and which section they belong to all come from the
library.

A spec is `:list' (the frame), `:rows' (where the rows are in its
reply), `:type' (the section type rows are drawn as), `:row' (one
row's heading), and optionally `:payload' (an alist, or a function of
no arguments returning one, called in the buffer), `:needs-agent', and
`:load' / `:draw' -- functions that replace the generic fetch and the
generic row loop for a page whose reply is more than a list of rows.
`:load' is called with the buffer and its connection; `:draw' with
nothing, in the buffer.")

(defun cmacs-clawtilla-section--spec (page)
  "Return the spec for PAGE, or nil."
  (cdr (assoc page cmacs-clawtilla-section-pages)))

(defun cmacs-clawtilla-section--library-pages (nick)
  "Return the pages the library says section NICK has."
  (let ((section (seq-find (lambda (s) (equal (alist-get 'nick s) nick))
                           (cmacs-clawtilla-enum "section"))))
    (alist-get 'pages section)))


;;;; Drawing.

(defun cmacs-clawtilla-section--draw ()
  "Redraw the section buffer."
  (cmacs-clawtilla-ui-preserving
    (let ((pages (cmacs-clawtilla-section--library-pages
                  cmacs-clawtilla-section--nick)))
      (insert (propertize
               (or (alist-get 'label
                              (seq-find
                               (lambda (s)
                                 (equal (alist-get 'nick s)
                                        cmacs-clawtilla-section--nick))
                               (cmacs-clawtilla-enum "section")))
                   cmacs-clawtilla-section--nick)
               'face 'cmacs-clawtilla-heading))
      (when cmacs-clawtilla-section--agent
        (insert "  " (cmacs-clawtilla-dim
                      (format "for %s" cmacs-clawtilla-section--agent))))
      (insert "\n"
              (mapconcat
               (lambda (page)
                 (let* ((nick (alist-get 'nick page))
                        ;; The Grok tab carries the daemon's count of
                        ;; jobs that need somebody, like the GTK badge.
                        (count (and (equal nick "grok")
                                    (cmacs-clawtilla-grok-attention
                                     cmacs-clawtilla-connection)))
                        (label (concat (alist-get 'label page)
                                       (if (and count (> count 0))
                                           (format " (%d)" count) ""))))
                   (if (equal nick cmacs-clawtilla-section--page)
                       (propertize label 'face 'cmacs-clawtilla-heading)
                     (cmacs-clawtilla-dim label))))
               pages "  |  ")
              "\n\n")
      (let ((spec (cmacs-clawtilla-section--spec
                   cmacs-clawtilla-section--page)))
        (cond
         ((null spec)
          ;; The library grew a page this file has not been taught.  Said
          ;; out loud rather than left blank: a page that is silently
          ;; absent is the exact failure `make parity' exists to catch,
          ;; and this is that failure arriving a release early.
          (insert "  "
                  (propertize
                   (format "This build has no view for the %s page yet."
                           cmacs-clawtilla-section--page)
                   'face 'cmacs-clawtilla-error)
                  "\n"))
         ((and (plist-get spec :needs-agent)
               (not cmacs-clawtilla-section--agent))
          ;; An empty page and a page that cannot be filled look the
          ;; same, and only one of them is worth acting on.
          (insert "  "
                  (cmacs-clawtilla-dim
                   "This page is per-agent; open it from an agent, or press a.")
                  "\n"))
         ((plist-get spec :draw)
          (funcall (plist-get spec :draw)))
         ((null cmacs-clawtilla-section--rows)
          (insert "  " (cmacs-clawtilla-dim "nothing here") "\n"))
         (t
          (dolist (row cmacs-clawtilla-section--rows)
            (cmacs-clawtilla-insert-section
             :type (plist-get spec :type) :value row :level 1
             :heading (funcall (plist-get spec :row) row)))))))))


;;;; Loading.

(defun cmacs-clawtilla-section--load (&optional buffer)
  "Refetch the current page into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (page (buffer-local-value 'cmacs-clawtilla-section--page buffer))
         (spec (cmacs-clawtilla-section--spec page)))
    (if (or (null spec)
            (and (plist-get spec :needs-agent)
                 (not (buffer-local-value 'cmacs-clawtilla-section--agent
                                          buffer))))
        (with-current-buffer buffer (cmacs-clawtilla-section--draw))
      (if (plist-get spec :load)
          ;; A page whose reply is more than a list of rows fetches
          ;; itself: Activity wants the raw text for the step summary,
          ;; Fleet the raw text for the library's figures.
          (funcall (plist-get spec :load) buffer conn)
        (cmacs-clawtilla-request
         conn (plist-get spec :list)
         (with-current-buffer buffer
           (append (let ((payload (plist-get spec :payload)))
                     (if (functionp payload) (funcall payload) payload))
                   (cmacs-clawtilla-section--scope)))
         (lambda (data err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (if err
                   (message "clawtilla: %s" err)
                 (setq cmacs-clawtilla-section--reply data)
                 (setq cmacs-clawtilla-section--rows
                       (cmacs-clawtilla-get data (plist-get spec :rows)))
                 (cmacs-clawtilla-section--draw))))))))))


;;;; Acting.

(defun cmacs-clawtilla-section-next-page ()
  "Move to the next page of this section."
  (interactive)
  (let* ((nicks (mapcar (lambda (p) (alist-get 'nick p))
                        (cmacs-clawtilla-section--library-pages
                         cmacs-clawtilla-section--nick)))
         (rest (cdr (member cmacs-clawtilla-section--page nicks))))
    (setq cmacs-clawtilla-section--page (or (car rest) (car nicks)))
    (setq cmacs-clawtilla-section--rows nil)
    (setq cmacs-clawtilla-section--reply nil)
    (cmacs-clawtilla-section--load)))

(defun cmacs-clawtilla-section--row-id ()
  "Return the id of the row at point, or signal."
  (let ((row (cmacs-clawtilla-section-at-point)))
    (unless row (user-error "Nothing at point"))
    (or (alist-get 'id (plist-get row :value))
        (user-error "That row has no id"))))

(defun cmacs-clawtilla-section--send (kind payload)
  "Send KIND with PAYLOAD and reload."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind payload
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-section--load buffer)))))))

(defun cmacs-clawtilla-section-run ()
  "Run the routine at point, or a trigger's test."
  (interactive)
  (pcase cmacs-clawtilla-section--page
    ("routines" (cmacs-clawtilla-section--send
                 "routine.run" (list (cons 'id (cmacs-clawtilla-section--row-id)))))
    ("triggers" (cmacs-clawtilla-section--send
                 "trigger.test" (list (cons 'id (cmacs-clawtilla-section--row-id)))))
    ("skills" (cmacs-clawtilla-section--send
               "skill.enable"
               (list (cons 'id (cmacs-clawtilla-section--row-id))
                     (cons 'enabled t))))
    (_ (user-error "Nothing to run on this page"))))

(defun cmacs-clawtilla-section-remove ()
  "Remove the row at point."
  (interactive)
  (let ((id (cmacs-clawtilla-section--row-id)))
    (when (yes-or-no-p (format "Remove %s? " id))
      (pcase cmacs-clawtilla-section--page
        ("routines" (cmacs-clawtilla-section--send
                     "routine.remove" (list (cons 'id id))))
        ("triggers" (cmacs-clawtilla-section--send
                     "trigger.remove" (list (cons 'id id))))
        ("skills" (cmacs-clawtilla-section--send
                   "skill.remove" (list (cons 'id id))))
        ("tasks" (cmacs-clawtilla-section--send
                  "task.cancel" (list (cons 'id id))))
        (_ (user-error "Nothing to remove on this page"))))))

(defun cmacs-clawtilla-section-scope-to-agent (agent)
  "Scope this section to AGENT and reload."
  (interactive "sWhich agent? ")
  (setq cmacs-clawtilla-section--agent (and (not (string-empty-p agent))
                                            agent))
  (setq cmacs-clawtilla-section--rows nil)
  (cmacs-clawtilla-section--load))

(defun cmacs-clawtilla-section-answer (answer)
  "Answer the decision at point with ANSWER.

On a page that is per-agent rather than per-row this picks the agent
instead: `a' is the only spare key, and the two cases never apply at
once -- decisions are fleet-wide and memory is somebody's own."
  (interactive
   (list (when (equal cmacs-clawtilla-section--page "decisions")
           (read-string "Answer: "))))
  (if (not (equal cmacs-clawtilla-section--page "decisions"))
      (call-interactively #'cmacs-clawtilla-section-scope-to-agent)
    ;; The daemon reads the decision from `decision', not `id'
    ;; (daemon-misc.c); sending `id' was refused as "decision is
    ;; required" and no answer ever reached an agent from here.
    (cmacs-clawtilla-section--send
     "decision.answer" (list (cons 'decision (cmacs-clawtilla-section--row-id))
                             (cons 'answer answer)))))

(defun cmacs-clawtilla-section-dismiss ()
  "Dismiss the decision at point."
  (interactive)
  (unless (equal cmacs-clawtilla-section--page "decisions")
    (user-error "Not a decision"))
  (cmacs-clawtilla-section--send
   "decision.dismiss"
   (list (cons 'decision (cmacs-clawtilla-section--row-id)))))

(defun cmacs-clawtilla-section-show ()
  "Show the row at point in full."
  (interactive)
  (let* ((row (cmacs-clawtilla-value-at-point))
         (buffer (get-buffer-create "*clawtilla detail*")))
    (unless row (user-error "Nothing at point"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (pair row)
          (insert (propertize (format "%-18s " (car pair))
                              'face 'cmacs-clawtilla-heading)
                  (format "%s" (cdr pair)) "\n"))
        (goto-char (point-min))
        (special-mode)))
    (cmacs-clawtilla-display buffer)))


;;;; Decisions.

(defun cmacs-clawtilla-section--decision-state (row)
  "Return the nick of ROW's state: open, answered, defaulted or dismissed.

`decision.list' sends the state as the enum's integer; the words are
the library's (the \"decision-state\" family), never a table here."
  (let ((state (alist-get 'state row)))
    (if (stringp state)
        state
      (alist-get 'nick
                 (seq-find (lambda (entry) (eql (alist-get 'value entry) state))
                           (cmacs-clawtilla-enum "decision-state"))))))

(defun cmacs-clawtilla-section--decision-how (row)
  "Return how ROW settled, or nil while it is open.

The `how' of its `decision.settled' event when this session saw one --
it alone can say `deleted' -- otherwise the state the list reports."
  (let ((state (cmacs-clawtilla-section--decision-state row)))
    (or (gethash (alist-get 'id row) cmacs-clawtilla-section--settled-how)
        (and state (not (equal state "open")) state))))

(defun cmacs-clawtilla-section--decision-row (row)
  "Return the heading line for the decision ROW."
  (let ((how (cmacs-clawtilla-section--decision-how row)))
    (concat
     (format "%-12s " (or (alist-get 'agent row) "?"))
     (if how
         (propertize (format "%-10s " how) 'face 'cmacs-clawtilla-dim)
       (make-string 11 ?\s))
     ;; `urgent' is derived by the daemon (the deadline is inside a
     ;; day), so this only draws it.
     (if (eq t (alist-get 'urgent row))
         (propertize "urgent " 'face 'cmacs-clawtilla-error)
       "")
     (or (alist-get 'question row) (alist-get 'summary row) ""))))

(defun cmacs-clawtilla-section-toggle-settled ()
  "Show or hide settled decisions on the Decisions page."
  (interactive)
  (unless (equal cmacs-clawtilla-section--page "decisions")
    (user-error "Not the Decisions page"))
  (setq cmacs-clawtilla-section--settled (not cmacs-clawtilla-section--settled))
  (message "clawtilla: %s" (if cmacs-clawtilla-section--settled
                               "showing settled decisions too"
                             "showing what is still open"))
  (cmacs-clawtilla-section--load))

(defun cmacs-clawtilla-section-delete-decision ()
  "Delete the decision at point outright.

Not a dismissal: dismissing keeps the record and says you passed;
deleting is for an entry nobody wants to see again.  An open one is
withdrawn on the way out exactly as a dismissal would be."
  (interactive)
  (unless (equal cmacs-clawtilla-section--page "decisions")
    (user-error "Not a decision"))
  (let ((id (cmacs-clawtilla-section--row-id)))
    (when (yes-or-no-p (format "Delete decision %s for good? " id))
      ;; The key is `decision', as for answer and dismiss -- not `id'.
      (cmacs-clawtilla-section--send
       "decision.delete" (list (cons 'decision id))))))


;;;; Activity.

(defun cmacs-clawtilla-section--payload-text (json)
  "Return the payload of the reply text JSON, itself as JSON text.

A reply may arrive as the whole envelope or as its bare payload; either
way what comes back is the payload, re-encoded faithfully (see
`cmacs-clawtilla-member-json') so it can go back to C."
  (let ((parsed (and (stringp json) (cmacs-clawtilla--parse json))))
    (if (and (assq 'ok parsed) (assq 'payload parsed))
        (cmacs-clawtilla-member-json json 'payload)
      json)))

(defun cmacs-clawtilla-section--activity-turns (json)
  "Return the turns in the activity.list reply text JSON, ready to draw.

Each turn is the parsed object plus two members of this client's own:
`id', the agent and room together, which is what keeps point and the
fold on the same turn across a redraw; and `summary', the turn's
recent steps in the library's words (\"Read 3 files, Ran 1 command\").

The summary is built from each turn's steps as the daemon SENT them,
re-encoded with null and false kept distinct -- a step re-encoded from
the ordinary parse turns a null `failed' into an object, which the
library reads as true."
  (let* ((text (cmacs-clawtilla-section--payload-text json))
         (plain (cmacs-clawtilla-get (cmacs-clawtilla--parse text) 'turns))
         (faithful (and (stringp text)
                        (alist-get 'turns
                                   (json-parse-string
                                    text :object-type 'alist
                                    :array-type 'array
                                    :null-object :json-null
                                    :false-object :json-false))))
         (index 0)
         (turns nil))
    (dolist (turn plain)
      (let* ((agent (or (alist-get 'agent turn) ""))
             (raw (and (vectorp faithful) (< index (length faithful))
                       (alist-get 'steps (aref faithful index))))
             (summary (and (vectorp raw) (> (length raw) 0)
                           (fboundp 'cmacs-clawtilla--step-summary)
                           (cmacs-clawtilla--step-summary
                            (json-serialize raw :null-object :json-null
                                            :false-object :json-false)
                            agent))))
        (push (append (list (cons 'id (format "%s/%s" agent
                                              (or (alist-get 'room turn) "")))
                            (cons 'summary summary))
                      turn)
              turns))
      (setq index (1+ index)))
    (nreverse turns)))

(defun cmacs-clawtilla-section--load-activity (buffer conn)
  "Fetch `activity.list' on CONN into BUFFER."
  (cmacs-clawtilla-request-raw
   conn "activity.list" nil
   (lambda (json err)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (if err
             (message "clawtilla: %s" err)
           (setq cmacs-clawtilla-section--reply
                 (cmacs-clawtilla--parse
                  (cmacs-clawtilla-section--payload-text json)))
           (setq cmacs-clawtilla-section--rows
                 (cmacs-clawtilla-section--activity-turns json))
           (cmacs-clawtilla-section--draw)
           (cmacs-clawtilla-section--tick-arm)))))))

(defun cmacs-clawtilla-section--turn-heading (turn now)
  "Return the heading line for TURN, aged against NOW (microseconds)."
  (let* ((agent (or (alist-get 'agent turn) "?"))
         (room (or (alist-get 'room_name turn) (alist-get 'room turn) ""))
         (origin (alist-get 'origin turn))
         (task (alist-get 'task turn))
         (steps (or (alist-get 'step_count turn) 0)))
    (concat
     (propertize (or (alist-get 'agent_name turn) agent)
                 'face 'cmacs-clawtilla-agent)
     " in "
     (if (string-empty-p room) "an unnamed room" room)
     "  "
     (propertize (concat "running "
                         (cmacs-clawtilla--activity-elapsed
                          (or (alist-get 'started turn) 0) now))
                 'face 'cmacs-clawtilla-busy)
     (cmacs-clawtilla-dim
      (concat (if (and origin (not (equal origin "user")))
                  (format " · for %s" origin) "")
              (if task (format " · task %s" task) "")
              (format " · %d step%s" steps (if (= steps 1) "" "s"))))
     ;; Steering reaches only the agent's conversation with you, which
     ;; the daemon says per turn rather than this client guessing it
     ;; from the room's name.
     (if (eq t (alist-get 'steerable turn))
         (concat "  " (propertize "steerable" 'face 'cmacs-clawtilla-running))
       ""))))

(defun cmacs-clawtilla-section--draw-activity ()
  "Draw the Activity page: every turn running across the fleet."
  (let ((now (or (alist-get 'now cmacs-clawtilla-section--reply)
                 (truncate (* (float-time) 1000000)))))
    (if (null cmacs-clawtilla-section--rows)
        (insert "  " (propertize "Nothing is running" 'face 'bold) "\n  "
                (cmacs-clawtilla-dim
                 "Every agent is idle.  A turn appears here the moment one starts.")
                "\n")
      (dolist (turn cmacs-clawtilla-section--rows)
        (cmacs-clawtilla-insert-section
         :type 'turn :value turn :level 1
         :heading (cmacs-clawtilla-section--turn-heading turn now)
         :body (lambda ()
                 (when-let* ((summary (alist-get 'summary turn)))
                   (unless (string-empty-p summary)
                     (insert "      " (cmacs-clawtilla-dim summary) "\n")))
                 (unless (eq t (alist-get 'steerable turn))
                   (insert "      "
                           (cmacs-clawtilla-dim
                            "steering reaches only its conversation with you")
                           "\n")))))
      (insert "\n  " (cmacs-clawtilla-dim
                      "s stops the agent (every turn it has), c steers this turn")
              "\n"))))

(defun cmacs-clawtilla-section--turn-at-point ()
  "Return the turn at point, or signal."
  (or (cmacs-clawtilla-value-at-point 'turn)
      (user-error "No running turn at point")))

(defun cmacs-clawtilla-section-steer (text)
  "Send TEXT into the running turn at point.

`msg.send' to the agent folds it into the turn it is running with you;
an agent that finished meanwhile takes it as an ordinary message, and
the two are said apart because they read the text at different
moments.  Offered only on a turn the daemon marks steerable."
  (interactive
   (let ((turn (cmacs-clawtilla-section--turn-at-point)))
     (unless (eq t (alist-get 'steerable turn))
       (user-error "Steering reaches only its conversation with you; %s"
                   "message it there, or stop it"))
     (list (read-string (format "Steer %s: " (alist-get 'agent turn))))))
  (let ((agent (alist-get 'agent (cmacs-clawtilla-section--turn-at-point)))
        (buffer (current-buffer)))
    (when (string-empty-p (string-trim text))
      (user-error "Nothing to send"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "msg.send"
     (list (cons 'target agent) (cons 'body (string-trim text))
           (cons 'from "user"))
     (lambda (data err)
       (cond
        (err (message "clawtilla: %s" err))
        ((eq t (cmacs-clawtilla-get data 'steered))
         (message "clawtilla: steered; it reads this at its next step"))
        (t (message "clawtilla: it had finished, so this went as a new message")))
       (when (buffer-live-p buffer)
         (cmacs-clawtilla-section--load buffer))))))

(defun cmacs-clawtilla-section--interrupt (agent running)
  "Ask, then interrupt every turn AGENT has; RUNNING is how many."
  (let ((buffer (current-buffer)))
    (when (yes-or-no-p (concat (string-trim-right
                                (cmacs-clawtilla--activity-stop-prompt
                                 agent (max 1 (or running 1))))
                               " "))
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "agent.interrupt"
       (list (cons 'agent agent))
       (lambda (data err)
         (cond
          (err (message "clawtilla: %s" err))
          ;; Zero is not a failure: the turn ended before the ask did.
          ((> (or (cmacs-clawtilla-get data 'killed) 0) 0)
           (message "clawtilla: stopped %s" agent))
          (t (message "clawtilla: %s had nothing running by the time it was asked"
                      agent)))
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-section--load buffer)))))))


;;;; Fleet.

(defconst cmacs-clawtilla-section-fleet-days 14
  "How many days of daily figures the Fleet page asks for.

Two weeks of shape without the strip outgrowing a line -- the GTK
client's STRIP_DAYS.")

(defun cmacs-clawtilla-section--fleet-merge (json)
  "Return the Fleet page's model from the usage.summary reply text JSON.

An alist of `view' -- what the library says about the reply: the
summary, the budget line, the strip, and per agent its cost, share,
subtitle and daily strip -- and `agents', each parsed agent with its
own row of that view as a `view' member.  Both lists are in the
daemon's order (most expensive first), so they are zipped by position."
  (let* ((text (cmacs-clawtilla-section--payload-text json))
         (data (cmacs-clawtilla--parse text))
         (view (and (stringp text)
                    (cmacs-clawtilla--parse (cmacs-clawtilla--fleet-view text))))
         (rows (alist-get 'agents view))
         (agents nil))
    (dolist (agent (cmacs-clawtilla-get data 'agents))
      (push (append agent (list (cons 'view (pop rows)))) agents))
    (list (cons 'view view)
          (cons 'data data)
          (cons 'agents (nreverse agents)))))

(defun cmacs-clawtilla-section--load-fleet (buffer conn)
  "Fetch `usage.summary' on CONN into BUFFER for the Fleet page."
  (cmacs-clawtilla-request-raw
   conn "usage.summary"
   ;; The payload is the library's: the period's `since', the days and
   ;; `sort: cost', as every client's Fleet page asks it.
   (cmacs-clawtilla--fleet-payload
    (buffer-local-value 'cmacs-clawtilla-section--period buffer)
    cmacs-clawtilla-section-fleet-days)
   (lambda (json err)
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (if err
             (message "clawtilla: %s" err)
           (setq cmacs-clawtilla-section--reply
                 (cmacs-clawtilla-section--fleet-merge json))
           (setq cmacs-clawtilla-section--rows
                 (alist-get 'agents cmacs-clawtilla-section--reply))
           (cmacs-clawtilla-section--draw)))))))

(defun cmacs-clawtilla-section--tone-face (tone)
  "Return the face for a badge TONE the daemon sent (`idle_tone')."
  (pcase tone
    ("good" 'cmacs-clawtilla-running)
    ("warn" 'cmacs-clawtilla-busy)
    ("bad" 'cmacs-clawtilla-error)
    (_ 'cmacs-clawtilla-dim)))

(defun cmacs-clawtilla-section--period-label ()
  "Return the label of the Fleet page's current period."
  (let ((periods (cmacs-clawtilla-enum "usage-period")))
    (alist-get 'label
               (seq-find (lambda (p)
                           (if cmacs-clawtilla-section--period
                               (equal (alist-get 'nick p)
                                      (number-to-string
                                       cmacs-clawtilla-section--period))
                             (eq t (alist-get 'default p))))
                         periods))))

(defun cmacs-clawtilla-section--fleet-heading (agent)
  "Return the heading line for one AGENT row of the Fleet page."
  (let* ((view (alist-get 'view agent))
         (state (alist-get 'state agent))
         (idle (alist-get 'idle agent)))
    (concat
     (propertize (format "%-18s" (or (alist-get 'name agent)
                                     (alist-get 'id agent) "?"))
                 'face 'cmacs-clawtilla-agent)
     " "
     ;; The idle label and its colour are the daemon's
     ;; (clawt_usage_idle_label / _tone): what "idle" means is not this
     ;; client's to decide.
     (propertize (format "%-11s" (or idle ""))
                 'face (cmacs-clawtilla-section--tone-face
                        (alist-get 'idle_tone agent)))
     (format "%-10s " (or (alist-get 'cost view) ""))
     (cmacs-clawtilla-dim (format "%-5s " (or (alist-get 'share view) "")))
     (or (alist-get 'strip view) "")
     (if (eq t (alist-get 'asleep agent))
         (concat "  " (cmacs-clawtilla-dim "asleep"))
       "")
     (if (and state (not (equal state "running")))
         (concat "  " (propertize state 'face (cmacs-clawtilla-state-face state)))
       ""))))

(defun cmacs-clawtilla-section--draw-fleet ()
  "Draw the Fleet page: what each agent costs, and which sit idle."
  (let* ((model cmacs-clawtilla-section--reply)
         (view (alist-get 'view model))
         (data (alist-get 'data model))
         (stoppable (or (alist-get 'stoppable view) 0)))
    (insert "  " (propertize (or (alist-get 'summary view) "")
                             'face 'cmacs-clawtilla-heading)
            "  " (cmacs-clawtilla-dim
                  (or (cmacs-clawtilla-section--period-label) ""))
            "\n")
    (when-let* ((budget (alist-get 'budget view)))
      (insert "  " (cmacs-clawtilla-dim budget) "\n"))
    (when-let* ((cap (alist-get 'daily_fleet_budget_micros data)))
      (when (and (numberp cap) (> cap 0) (null (alist-get 'budget view)))
        (insert "  " (cmacs-clawtilla-dim
                      (format "daily fleet cap %s"
                              (cmacs-clawtilla--format-cost cap)))
                "\n")))
    (insert "  " (cmacs-clawtilla-dim
                  (format "The last %d days  " cmacs-clawtilla-section-fleet-days))
            (or (alist-get 'strip view) "") "\n")
    (when (> stoppable 0)
      (insert "  " (propertize
                    (format "%d running and idle; X stops them" stoppable)
                    'face 'cmacs-clawtilla-busy)
              "\n"))
    (insert "\n")
    (if (null cmacs-clawtilla-section--rows)
        (insert "  " (cmacs-clawtilla-dim "nothing spent in this period") "\n")
      (dolist (agent cmacs-clawtilla-section--rows)
        (cmacs-clawtilla-insert-section
         :type 'fleet-agent :value agent :level 1
         :heading (cmacs-clawtilla-section--fleet-heading agent)
         :body (lambda ()
                 (let ((last (alist-get 'last_turn_at agent)))
                   (insert "      "
                           (cmacs-clawtilla-dim
                            (concat
                             (or (alist-get 'subtitle (alist-get 'view agent))
                                 "")
                             (if (and (numberp last) (> last 0))
                                 (format " · %s"
                                         (or (cmacs-clawtilla--time-label last)
                                             ""))
                               "")))
                           "\n"))))))))

(defun cmacs-clawtilla-section-fleet-period (period)
  "Show the Fleet page over PERIOD, an index into the library's periods."
  (interactive
   (let* ((periods (cmacs-clawtilla-enum "usage-period"))
          (labels (mapcar (lambda (p)
                            (cons (alist-get 'label p) (alist-get 'nick p)))
                          periods))
          (choice (completing-read "Period: " labels nil t)))
     (list (string-to-number (cdr (assoc choice labels))))))
  (unless (equal cmacs-clawtilla-section--page "fleet")
    (user-error "Not the Fleet page"))
  (setq cmacs-clawtilla-section--period period)
  (cmacs-clawtilla-section--load))

(defun cmacs-clawtilla-section-fleet-stop-idle ()
  "Stop every agent the Fleet page offers Stop on: running and idle.

The ids are the ones the page was drawn for, not a fresh guess.  Each
one's process and computer stop; its mailbox keeps what arrives."
  (interactive)
  (unless (equal cmacs-clawtilla-section--page "fleet")
    (user-error "Not the Fleet page"))
  (let ((ids (delq nil
                   (mapcar (lambda (agent)
                             (and (eq t (alist-get 'stoppable
                                                   (alist-get 'view agent)))
                                  (alist-get 'id agent)))
                           cmacs-clawtilla-section--rows)))
        (buffer (current-buffer)))
    (unless ids (user-error "No agent is running idle"))
    (when (yes-or-no-p (format "Stop %d idle agent%s (%s)? " (length ids)
                               (if (= 1 (length ids)) "" "s")
                               (string-join ids ", ")))
      (dolist (id ids)
        (cmacs-clawtilla-request
         (cmacs-clawtilla-current) "agent.stop" (list (cons 'agent id))
         (lambda (_data err)
           (when err (message "clawtilla: %s: %s" id err))
           (when (buffer-live-p buffer)
             (cmacs-clawtilla-section--load buffer))))))))

(defun cmacs-clawtilla-section-stop ()
  "Stop the agent at point.

On Activity this is `agent.interrupt', which ends EVERY turn the agent
has and leaves it up -- asked first in the library's words, because a
key that does more than its row suggests must say so.  On Fleet it is
`agent.stop': the process and its computer."
  (interactive)
  (pcase cmacs-clawtilla-section--page
    ("activity"
     (let ((turn (cmacs-clawtilla-section--turn-at-point)))
       (cmacs-clawtilla-section--interrupt (alist-get 'agent turn)
                                           (alist-get 'running_turns turn))))
    ("fleet"
     (let ((agent (cmacs-clawtilla-value-at-point 'fleet-agent)))
       (unless agent (user-error "No agent at point"))
       (when (yes-or-no-p (format "Stop %s (its process and computer)? "
                                  (alist-get 'id agent)))
         (cmacs-clawtilla-section--send
          "agent.stop" (list (cons 'agent (alist-get 'id agent)))))))
    (_ (user-error "Nothing to stop on this page"))))


;;;; Keeping Activity, Fleet and Decisions current.

(defvar cmacs-clawtilla-section--tick nil
  "The timer that re-ages the Activity page while one is on screen.")

(defvar cmacs-clawtilla-section--pending nil
  "Section buffers with a coalesced reload waiting.")

(defun cmacs-clawtilla-section--visible-activity ()
  "Return the section buffers showing Activity in some window."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (and (derived-mode-p 'cmacs-clawtilla-section-mode)
                       (equal cmacs-clawtilla-section--page "activity")
                       (get-buffer-window buffer t))))
              (buffer-list)))

(defun cmacs-clawtilla-section--tick ()
  "Refetch every visible Activity page, or stop ticking if there is none.

Ages move whether anything else does or not: a turn sitting in one long
tool call produces no step for minutes, and a \"running 12s\" that never
changes reads as a stale page.  Asked only while the page is up."
  (let ((buffers (cmacs-clawtilla-section--visible-activity)))
    (if (null buffers)
        (progn (cancel-timer cmacs-clawtilla-section--tick)
               (setq cmacs-clawtilla-section--tick nil))
      (dolist (buffer buffers)
        (ignore-errors (cmacs-clawtilla-section--load buffer))))))

(defun cmacs-clawtilla-section--tick-arm ()
  "Start the Activity ticker if it is not running."
  (unless (timerp cmacs-clawtilla-section--tick)
    (setq cmacs-clawtilla-section--tick
          (run-at-time 10 10 #'cmacs-clawtilla-section--tick))))

(defun cmacs-clawtilla-section--reload-soon (buffer)
  "Reload BUFFER once, shortly, however many events asked.

A busy fleet publishes a step every few hundred milliseconds; a refetch
per event would be a request per step per open page."
  (unless (memq buffer cmacs-clawtilla-section--pending)
    (push buffer cmacs-clawtilla-section--pending)
    (run-at-time 0.5 nil
                 (lambda ()
                   (setq cmacs-clawtilla-section--pending
                         (delq buffer cmacs-clawtilla-section--pending))
                   (when (buffer-live-p buffer)
                     (ignore-errors (cmacs-clawtilla-section--load buffer)))))))

(defun cmacs-clawtilla-section--on-event (conn kind data)
  "Refresh section pages on CONN that the event KIND carrying DATA moves."
  (when (equal kind "decision.settled")
    ;; Remembered whether or not a page is open: the row may be drawn
    ;; later, and only this event can say `deleted' or `defaulted'.
    (when-let* ((id (cmacs-clawtilla-event-detail data 'decision)))
      (puthash id (cmacs-clawtilla-event-detail data 'how)
               cmacs-clawtilla-section--settled-how)))
  (let ((pages
         (cond
          ((string-match-p (rx bos (or "agent.typing" "agent.interrupted"
                                       "agent.started" "agent.stopped"
                                       "turn." "message"))
                           kind)
           ;; A stop or a start also moves Fleet's state column.
           (if (string-match-p (rx bos "agent.st") kind)
               '("activity" "fleet") '("activity")))
          ((string-match-p (rx bos (or "agent." "spending.")) kind) '("fleet"))
          ((string-match-p (rx bos "decision.") kind) '("decisions"))
          ((string-match-p (rx bos "routine.") kind) '("routines")))))
    (when pages
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'cmacs-clawtilla-section-mode)
                     (eq cmacs-clawtilla-connection conn)
                     (member cmacs-clawtilla-section--page pages))
            (cmacs-clawtilla-section--reload-soon buffer)))))))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-section--on-event)


;;;; Routines.

(defun cmacs-clawtilla-section--presets ()
  "Return the schedule presets, with cron behind Custom.

Most standing work is one of five shapes, and nobody should have to
write `0 9 * * 1-5' to get weekday mornings.  Cron is still there for
the sixth."
  '("manual" "hourly" "daily" "weekdays" "weekly" "custom"))

(defconst cmacs-clawtilla-section-routine-text-fields
  '("schedule" "prompt" "agent" "model")
  "The routine fields `routine.update' takes as text.

`model' (since clawtilla 0.7.7) runs the routine on a model other than
the agent's own -- a cheaper one for a check that compares a number.
Empty is the agent's own.")

(defconst cmacs-clawtilla-section-routine-flags
  '("enabled" "read_only" "proactive" "locked")
  "The routine fields `routine.update' takes as booleans.

`read_only' runs it unable to change anything, `proactive' lets it
start work rather than only report, and `locked' keeps the agent
itself from editing or removing it.  Sent as JSON true and false:
a string that is not a boolean is read as the default, which is the
worst failure a flag can have -- the request succeeds and does the
other thing.")

(defun cmacs-clawtilla-section--flag (value)
  "Return VALUE as a JSON boolean for a payload: t or :false.

nil would serialize as an empty object, not as false."
  (if value t :false))

(defun cmacs-clawtilla-section--routine-payload (id fields)
  "Return the routine payload for ID with FIELDS, an alist of name to value.

Text fields pass as they are; flags become JSON booleans.  The pure half
of `cmacs-clawtilla-section-routine-add' and `-update', so the encoding
can be tested without a daemon."
  (cons (cons 'id id)
        (mapcar (lambda (pair)
                  (let ((name (if (symbolp (car pair))
                                  (symbol-name (car pair))
                                (car pair))))
                    (cons (intern name)
                          (if (member name cmacs-clawtilla-section-routine-flags)
                              (cmacs-clawtilla-section--flag
                               (and (cdr pair) (not (eq (cdr pair) :false))))
                            (cdr pair)))))
                fields)))

(defun cmacs-clawtilla-section--read-schedule ()
  "Read a schedule: a preset, or cron behind Custom."
  (let ((preset (completing-read "When: "
                                 (cmacs-clawtilla-section--presets) nil t)))
    (if (equal preset "custom")
        (read-string "Cron: ")
      preset)))

(defun cmacs-clawtilla-section-routine-add (id schedule prompt &optional extra)
  "Add a routine ID running PROMPT on SCHEDULE.

EXTRA is an alist of further fields.  With a prefix argument the model
and the three flags (read-only, proactive, locked) are asked for too."
  (interactive
   (let* ((id (read-string "Routine id: "))
          (schedule (cmacs-clawtilla-section--read-schedule))
          (prompt (read-string "Do what: "))
          (extra (when current-prefix-arg
                   (list (cons "model"
                               (read-string "Model (empty: the agent's own): "))
                         (cons "read_only" (y-or-n-p "Read-only? "))
                         (cons "proactive" (y-or-n-p "Proactive? "))
                         (cons "locked"
                               (y-or-n-p "Locked against the agent? "))))))
     (list id schedule prompt extra)))
  (cmacs-clawtilla-section--send
   "routine.add"
   (append (cmacs-clawtilla-section--routine-payload
            id (append (list (cons "schedule" schedule)
                             (cons "prompt" prompt))
                       (seq-remove (lambda (pair)
                                     (and (equal (car pair) "model")
                                          (string-empty-p (cdr pair))))
                                   extra)))
           (cmacs-clawtilla-section--scope))))

(defun cmacs-clawtilla-section-routine-update ()
  "Change one field of the routine at point."
  (interactive)
  (let* ((id (cmacs-clawtilla-section--row-id))
         (row (cmacs-clawtilla-value-at-point))
         (field (completing-read
                 "Change: "
                 (append cmacs-clawtilla-section-routine-text-fields
                         cmacs-clawtilla-section-routine-flags)
                 nil t))
         (value (cond
                 ((equal field "schedule")
                  (cmacs-clawtilla-section--read-schedule))
                 ((member field cmacs-clawtilla-section-routine-flags)
                  (y-or-n-p (format "%s (now %s)? " field
                                    (if (eq t (alist-get (intern field) row))
                                        "on" "off"))))
                 (t (read-string (format "%s: " field)
                                 (let ((now (alist-get (intern field) row)))
                                   (and (stringp now) now)))))))
    (cmacs-clawtilla-section--send
     "routine.update"
     (cmacs-clawtilla-section--routine-payload id (list (cons field value))))))


;;;; Triggers.

(defun cmacs-clawtilla-section-trigger-add (id kind agent)
  "Add trigger ID of KIND delivering to AGENT."
  (interactive (list (read-string "Trigger id: ")
                     (read-string "Kind: ")
                     (read-string "Deliver to: ")))
  (cmacs-clawtilla-section--send
   "trigger.add" (list (cons 'id id) (cons 'kind kind) (cons 'agent agent))))

(defun cmacs-clawtilla-section-trigger-update ()
  "Change the trigger at point."
  (interactive)
  (let* ((id (cmacs-clawtilla-section--row-id))
         (field (read-string "Field: "))
         (value (read-string (format "%s: " field))))
    ;; The daemon reads each field by the type its schema gives it: an
    ;; integer (`organization_id', `rate_limit') sent as a string reads
    ;; as 0, and a boolean as false.  A list (`ignore_actors') may stay a
    ;; comma-separated string -- the daemon splits that itself.
    (cmacs-clawtilla-section--send
     "trigger.update"
     (list (cons 'id id)
           (cons (intern field)
                 (cond ((string-match-p "\\`-?[0-9]+\\'" value)
                        (string-to-number value))
                       ((member value '("true" "yes" "on")) t)
                       ((member value '("false" "no" "off")) :false)
                       (t value)))))))

(defun cmacs-clawtilla-section-trigger-capture ()
  "Capture the next event this trigger would match, without acting."
  (interactive)
  (cmacs-clawtilla-section--send
   "trigger.capture" (list (cons 'id (cmacs-clawtilla-section--row-id)))))

(defun cmacs-clawtilla-section-trigger-rotate ()
  "Rotate the webhook secret of the trigger at point."
  (interactive)
  (when (yes-or-no-p "Rotate this trigger's secret? ")
    (cmacs-clawtilla-section--send
     "trigger.rotate" (list (cons 'id (cmacs-clawtilla-section--row-id))))))

(defun cmacs-clawtilla-section-trigger-deliveries ()
  "Show what this trigger has delivered."
  (interactive)
  (let ((id (cmacs-clawtilla-section--row-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "trigger.deliveries" (list (cons 'id id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla deliveries: %s*" id))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (dolist (row (cmacs-clawtilla-get data 'deliveries))
               (insert (format "%-14s %-12s %-10s %s\n"
                               (or (alist-get 'receipt row) "?")
                               (or (alist-get 'agent row) "")
                               (or (alist-get 'state row) "")
                               (or (alist-get 'parent row) ""))))
             (goto-char (point-min))
             (special-mode)
             (setq-local cmacs-clawtilla-section--nick id))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-section-trigger-replay (receipt run)
  "Replay delivery RECEIPT of the trigger at point, running it if RUN.

Previewing and executing are one frame with a flag, and the flag
defaults to off: a replay that acts is indistinguishable from the
original event downstream, so it should never be the thing that happens
because somebody pressed the obvious key.

Execution needs a positive receipt.  A blank one previews the latest
snapshot instead, which is what the daemon does with zero."
  (interactive
   (list (read-number "Receipt (0 previews the latest): " 0)
         (and (yes-or-no-p "Actually run it? ")
              (yes-or-no-p "It will act as though the event just happened.  Sure? "))))
  (let ((id (cmacs-clawtilla-section--row-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "trigger.replay"
     (list (cons 'id id) (cons 'receipt receipt) (cons 'run (if run t :false)))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         ;; A successful envelope means the batch outcomes were
         ;; recorded, not that they all worked: `failed' and `results'
         ;; are where partial failure lives, and a client that read only
         ;; the envelope would report a success that was not one.
         (let ((failed (or (cmacs-clawtilla-get data 'failed) 0)))
           (message "clawtilla: %s%s"
                    (if (eq t (cmacs-clawtilla-get data 'matches))
                        "matched" "did not match")
                    (if (> failed 0)
                        (format "; %d recipient%s failed" failed
                                (if (= failed 1) "" "s"))
                      ""))))))))


;;;; Skills.

(defun cmacs-clawtilla-section-skill-create (id description)
  "Create skill ID described by DESCRIPTION."
  (interactive (list (read-string "Skill id: ")
                     (read-string "What it does: ")))
  (cmacs-clawtilla-section--send
   "skill.create" (list (cons 'id id) (cons 'description description))))

(defun cmacs-clawtilla-section-skill-import (from)
  "Import a skill from FROM.

It arrives switched OFF, which is the daemon's decision and worth
knowing: a skill that starts working the moment it lands is one nobody
read first."
  (interactive "sImport from: ")
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "skill.import" (list (cons 'from from))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (message "clawtilla: imported, and switched off until you enable it")
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-section--load buffer)))))))

(defun cmacs-clawtilla-section-skill-expand ()
  "Show the skill at point with everything it references pulled in."
  (interactive)
  (let ((id (cmacs-clawtilla-section--row-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "skill.expand"
     (list (cons 'agent (cmacs-clawtilla-section--need-agent))
           (cons 'name id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla skill: %s*" id))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (or (cmacs-clawtilla-get data 'text)
                         (cmacs-clawtilla-get data 'content) ""))
             (goto-char (point-min))
             (special-mode))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-section-skill-commands ()
  "Show the slash commands the skill at point adds.

These are why the slash-command parity check cannot see everything: a
command whose name comes from a skill exists in no client's source."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "skill.commands"
   ;; Per agent: which commands exist depends on which skills that agent
   ;; has, so there is no fleet-wide answer to give.
   (list (cons 'agent (cmacs-clawtilla-section--need-agent)))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (message "clawtilla: %s"
                (or (string-join
                     (mapcar (lambda (c)
                               (if (stringp c) c (or (alist-get 'name c) "")))
                             (cmacs-clawtilla-get data 'commands))
                     " ")
                    "no commands"))))))

(defun cmacs-clawtilla-section-skill-reload ()
  "Reread the skills from disk."
  (interactive)
  (cmacs-clawtilla-section--send "skill.reload" nil))

(defun cmacs-clawtilla-section-skill-assign (agent)
  "Give the skill at point to AGENT."
  (interactive "sGive it to: ")
  (cmacs-clawtilla-section--send
   "skill.assign" (list (cons 'id (cmacs-clawtilla-section--row-id))
                        (cons 'agent agent))))

(defun cmacs-clawtilla-section-skill-unassign (agent)
  "Take the skill at point away from AGENT."
  (interactive "sTake it from: ")
  (cmacs-clawtilla-section--send
   "skill.unassign" (list (cons 'id (cmacs-clawtilla-section--row-id))
                          (cons 'agent agent))))

;;;; The mode.

(transient-define-prefix cmacs-clawtilla-section-menu ()
  "What this page can do."
  ["Page"
   [("TAB" "next page" cmacs-clawtilla-section-next-page)
    ("gr" "refresh" cmacs-clawtilla-refresh)]]
  ["Row"
   [("RET" "show in full" cmacs-clawtilla-section-show)
    ("r" "run / enable" cmacs-clawtilla-section-run)
    ("s" "stop the agent" cmacs-clawtilla-section-stop)]
   [("a" "answer" cmacs-clawtilla-section-answer)
    ("d" "dismiss" cmacs-clawtilla-section-dismiss)
    ("D" "remove" cmacs-clawtilla-section-remove)]]
  ["Activity"
   [("c" "steer the turn" cmacs-clawtilla-section-steer)]]
  ["Fleet"
   [("p" "period" cmacs-clawtilla-section-fleet-period)
    ("X" "stop the idle ones" cmacs-clawtilla-section-fleet-stop-idle)]]
  ["Grok"
   [("i" "hand a bot some work" cmacs-clawtilla-grok-send)
    ("R" "routine prompt" cmacs-clawtilla-grok-routine-prompt)
    ("Y" "mint MCP key" cmacs-clawtilla-grok-mint-key)]]
  ["Decisions"
   [("o" "show settled too" cmacs-clawtilla-section-toggle-settled)
    ("x" "delete for good" cmacs-clawtilla-section-delete-decision)]]
  ["Routines"
   [("A" "add a routine (C-u: model, flags)"
     cmacs-clawtilla-section-routine-add)
    ("U" "change it" cmacs-clawtilla-section-routine-update)]]
  ["Triggers"
   [("T" "add a trigger" cmacs-clawtilla-section-trigger-add)
    ("E" "change it" cmacs-clawtilla-section-trigger-update)
    ("C" "capture the next" cmacs-clawtilla-section-trigger-capture)]
   [("V" "deliveries" cmacs-clawtilla-section-trigger-deliveries)
    ("P" "replay one" cmacs-clawtilla-section-trigger-replay)
    ("O" "rotate the secret" cmacs-clawtilla-section-trigger-rotate)]]
  ["Skills"
   [("N" "create" cmacs-clawtilla-section-skill-create)
    ("I" "import" cmacs-clawtilla-section-skill-import)
    ("X" "expand" cmacs-clawtilla-section-skill-expand)]
   [("M" "its commands" cmacs-clawtilla-section-skill-commands)
    ("L" "reload from disk" cmacs-clawtilla-section-skill-reload)]
   [("G" "give to an agent" cmacs-clawtilla-section-skill-assign)
    ("K" "take it away" cmacs-clawtilla-section-skill-unassign)]])

(defvar cmacs-clawtilla-section-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-section-next-page)
    (define-key map (kbd "RET") #'cmacs-clawtilla-section-show)
    (define-key map (kbd "r") #'cmacs-clawtilla-section-run)
    (define-key map (kbd "a") #'cmacs-clawtilla-section-answer)
    (define-key map (kbd "d") #'cmacs-clawtilla-section-dismiss)
    (define-key map (kbd "D") #'cmacs-clawtilla-section-remove)
    (define-key map (kbd "s") #'cmacs-clawtilla-section-stop)
    (define-key map (kbd "c") #'cmacs-clawtilla-section-steer)
    (define-key map (kbd "p") #'cmacs-clawtilla-section-fleet-period)
    (define-key map (kbd "X") #'cmacs-clawtilla-section-fleet-stop-idle)
    (define-key map (kbd "o") #'cmacs-clawtilla-section-toggle-settled)
    (define-key map (kbd "x") #'cmacs-clawtilla-section-delete-decision)
    (define-key map (kbd "i") #'cmacs-clawtilla-grok-send)
    (define-key map (kbd "R") #'cmacs-clawtilla-grok-routine-prompt)
    (define-key map (kbd "Y") #'cmacs-clawtilla-grok-mint-key)
    (define-key map (kbd "?") #'cmacs-clawtilla-section-menu)
    map)
  "Keymap for `cmacs-clawtilla-section-mode'.")

(define-derived-mode cmacs-clawtilla-section-mode special-mode
  "Clawtilla-Section"
  "Major mode for one clawtilla section."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-section--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-section (conn nick &optional agent)
  "Open section NICK on CONN, scoped to AGENT if given."
  (interactive
   (list (cmacs-clawtilla-current)
         (completing-read "Section: "
                          (cmacs-clawtilla-enum-nicks "section") nil t)))
  (let* ((buffer (get-buffer-create (format "*clawtilla %s*" nick)))
         (pages (cmacs-clawtilla-section--library-pages nick)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-section-mode)
        (cmacs-clawtilla-section-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-section--nick nick)
      (setq-local cmacs-clawtilla-section--agent agent)
      ;; The default page is the library's, not the first one drawn.
      (setq-local cmacs-clawtilla-section--page
                  (or (alist-get 'default-page
                                 (seq-find
                                  (lambda (s) (equal (alist-get 'nick s) nick))
                                  (cmacs-clawtilla-enum "section")))
                      (alist-get 'nick (car pages))))
      (cmacs-clawtilla-section--load buffer))
    (cmacs-clawtilla-display buffer)))

;;;###autoload
(defun cmacs-clawtilla-work (&optional conn)
  "Show tasks, decisions, flow, activity, the fleet's spending and Grok."
  (interactive)
  (cmacs-clawtilla-section (or conn (cmacs-clawtilla-current)) "work"))

;;;###autoload
(defun cmacs-clawtilla-automation (&optional conn)
  "Show routines and triggers."
  (interactive)
  (cmacs-clawtilla-section (or conn (cmacs-clawtilla-current)) "automation"))

;;;###autoload
(defun cmacs-clawtilla-library (&optional conn)
  "Show skills and memory."
  (interactive)
  (cmacs-clawtilla-section (or conn (cmacs-clawtilla-current)) "library"))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-section-mode-map 'cmacs-clawtilla-section-mode)

(provide 'cmacs-clawtilla-section)

;;; cmacs-clawtilla-section.el ends here
