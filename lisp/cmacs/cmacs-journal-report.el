;;; cmacs-journal-report.el --- Reports and recall over the activity journal  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What the journal is for, once it has been kept:
;;
;;   `cmacs-journal-report'      time by project, app, day or kind, as
;;                               an Org table.
;;   #+BEGIN: cmacs-journal      the same table as an Org dynamic block.
;;   `cmacs-journal-at'          what was focused and open at a moment.
;;   `cmacs-journal-reopen'      reopen that moment's files and pages.
;;   `cmacs-journal-org-clock'   insert CLOCK lines for a project and a
;;                               day under the heading at point.
;;
;; Nothing here writes anything on its own.  The Org clock command in
;; particular inserts lines only when you run it: a journal that edited
;; your Org files unasked would be a second, worse time tracker.
;;
;; These are the user's own commands, so they read the journal through
;; `cmacs-journal-events', which already returns nothing to an agent
;; unless `cmacs-journal-expose-to-agents' is set.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-journal)

(declare-function org-read-date "org" (&rest args))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-table-align "org-table" ())
(declare-function org-mode "org" ())
(declare-function cmacs-journal-restore-at-point "cmacs-journal-restore" ())
(declare-function cmacs-journal-daily "cmacs-journal-daily" (&optional day))

(defvar cmacs-journal-moment-map
  (let ((map (make-sparse-keymap)))
    (define-key map "R" #'cmacs-journal-restore-at-point)
    map)
  "Keymap on a journal line that stands for a moment.
\\`R' there shows the plan for restoring that moment
\(`cmacs-journal-restore-at-point'); nothing is changed until the plan
is confirmed.")

(defcustom cmacs-journal-at-window 600
  "Seconds either side of a moment `cmacs-journal-at' also shows."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-clock-merge-gap 300
  "Join spans closer than this many seconds into one CLOCK line.
A look at another window for a minute is not a new stretch of work."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-report-kinds '(focus buffer url)
  "Event kinds a report counts.  Idle time and agent runs are left out."
  :type '(repeat symbol)
  :group 'cmacs-journal)

;;;; Time ranges

(defun cmacs-journal--day-start (&optional time)
  "Local midnight at the start of TIME's day, in seconds."
  (let ((d (decode-time (or time (cmacs-journal--now)))))
    (float-time (encode-time (list 0 0 0 (decoded-time-day d)
                                   (decoded-time-month d)
                                   (decoded-time-year d) nil -1 nil)))))

(defun cmacs-journal--span-range (span)
  "The (FROM . TO) seconds SPAN means.
SPAN is `today', `yesterday', `week' (the last 7 days), `month' (the
last 30), a number of days back, a YYYY-MM-DD string, or a cons of two
times already."
  (let* ((span (if (and (stringp span)
                        (not (string-match-p "\\`[0-9]\\{4\\}-" span)))
                   (if (string-match-p "\\`[0-9]+\\'" span)
                       (string-to-number span)
                     (intern span))
                 span))
         (now (cmacs-journal--now))
         (today (cmacs-journal--day-start now)))
    (pcase span
      ((or 'nil 'today) (cons today now))
      ('yesterday (cons (cmacs-journal--day-start (- today 3600)) today))
      ('week (cons (- today (* 6 86400)) now))
      ('month (cons (- today (* 29 86400)) now))
      ((pred numberp) (cons (- today (* (max 0 (1- span)) 86400)) now))
      ((pred stringp)
       (let ((start (cmacs-journal--day-start
                     (float-time (date-to-time (concat span " 12:00:00"))))))
         (cons start (+ start 86400))))
      (`(,from . ,to) (cons from to))
      (_ (user-error "Unknown span %S" span)))))

(defun cmacs-journal--format-duration (seconds)
  "SECONDS as H:MM."
  (let ((minutes (round seconds 60)))
    (format "%d:%02d" (/ minutes 60) (% minutes 60))))

;;;; Named contexts

(defcustom cmacs-journal-context-lookback-days 7
  "Days before a range that are searched for the context already active.
A report over today starts in whatever context was switched to last --
perhaps yesterday, perhaps last week.  Only this many days of the
journal are read to find it; with nothing there the range starts in no
context.  The whole journal is never read for this."
  :type 'integer
  :group 'cmacs-journal)

(defun cmacs-journal--context-label (event)
  "The context a `context' EVENT switches to, or nil for an unnamed one.
Nil when a filter dropped the title: time after it is in no named
context, which is what the rule asked for."
  (let ((title (plist-get event :title)))
    (and (stringp title) (not (string-empty-p title)) title)))

(defun cmacs-journal-attribute-contexts (events &optional initial no-split)
  "Return EVENTS with each one's active named context as `:context'.

EVENTS is oldest first and may hold `context' events -- the one point
event cmacs-context.el writes per switch.  Every other event gets a
`:context': the title of the switch that most recently precedes its
start, INITIAL (a string or nil) before the first switch.  A span that
crosses a switch is split at the switch into parts, each with its own
context, times and duration, unless NO-SPLIT, in which case it is one
event in the context it started in.  The `context' events themselves
are left out unless NO-SPLIT: they have no duration and are not time.

An event that already has a `:context' is returned as it is, so
attributing twice changes nothing.  The switches are searched by
bisection: O(n log n) in the events, plus the splits."
  (let* ((switches
          (vconcat
           (sort (delq nil
                       (mapcar (lambda (e)
                                 (and (eq (plist-get e :kind) 'context)
                                      (cons (plist-get e :time)
                                            (cmacs-journal--context-label e))))
                               events))
                 (lambda (a b) (< (car a) (car b))))))
         (count (length switches))
         ;; Index of the last switch at or before TIME, or -1.
         (before (lambda (time)
                   (let ((lo 0) (hi count))
                     (while (< lo hi)
                       (let ((mid (/ (+ lo hi) 2)))
                         (if (<= (car (aref switches mid)) time)
                             (setq lo (1+ mid))
                           (setq hi mid))))
                     (1- lo))))
         (label (lambda (index)
                  (if (< index 0) initial (cdr (aref switches index)))))
         (out nil))
    (dolist (event events)
      (cond
       ((eq (plist-get event :kind) 'context)
        ;; Kept as a row only where rows are wanted: in the context it
        ;; switches to.
        (when no-split
          (push (append (list :context (cmacs-journal--context-label event))
                        event)
                out)))
       ((plist-member event :context) (push event out))
       (t
        (let* ((start (plist-get event :time))
               (end (or (plist-get event :end) start))
               (index (funcall before start)))
          (if (or no-split
                  (>= (1+ index) count)
                  (>= (car (aref switches (1+ index))) end))
              ;; The common case: no switch inside the span.
              (push (append (list :context (funcall label index)) event) out)
            (let ((from start))
              (while (< from end)
                (let* ((next (and (< (1+ index) count)
                                  (car (aref switches (1+ index)))))
                       (to (if (and next (< next end)) next end))
                       (part (copy-sequence event)))
                  (setq part (plist-put part :time from))
                  (setq part (plist-put part :end to))
                  (setq part (plist-put part :duration (- to from)))
                  (push (append (list :context (funcall label index)) part)
                        out)
                  (setq from to index (1+ index))))))))))
    (nreverse out)))

(defun cmacs-journal-context-at (time)
  "The named context active at TIME according to the journal, or nil.
The last `context' event in the `cmacs-journal-context-lookback-days'
days up to TIME.  Nil to an agent, like every read of the journal."
  (let ((found nil))
    (dolist (event (cmacs-journal-events
                    (- time (* 86400 (max 0 cmacs-journal-context-lookback-days)))
                    time))
      (when (and (eq (plist-get event :kind) 'context)
                 (<= (plist-get event :time) time))
        (setq found event)))
    (and found (cmacs-journal--context-label found))))

(defun cmacs-journal-context-events (from to)
  "The journal's events in FROM..TO, each with its `:context'.
As `cmacs-journal-events', then `cmacs-journal-attribute-contexts'
starting from the context that was already active at FROM."
  (cmacs-journal-attribute-contexts
   (cmacs-journal-events from to)
   (and from (cmacs-journal-context-at from))))

;;;; Aggregation

(defun cmacs-journal--group-key (event by)
  "The group EVENT falls in when summarising BY."
  (pcase by
    ('day (cmacs-journal--day (plist-get event :time)))
    ('kind (symbol-name (plist-get event :kind)))
    ('context (or (plist-get event :context) "(none)"))
    ('app (or (plist-get event :app) "(none)"))
    ('project (or (plist-get event :project)
                  ;; Time outside any project is still time; say where
                  ;; it went instead of one big "none".
                  (and (plist-get event :app)
                       (not (equal (plist-get event :app) "emacs"))
                       (format "(%s)" (plist-get event :app)))
                  "(no project)"))
    (_ (format "%s" (or (plist-get event (intern (format ":%s" by)))
                        "(none)")))))

(defun cmacs-journal-summarize (events by)
  "Total the durations of EVENTS grouped BY; return ((KEY . SECONDS) ...).
BY is `project', `app', `day', `kind', `context' or any other event
field.  Largest first, except by day, which is in date order.  Only
kinds in `cmacs-journal-report-kinds' count.

By `context', time goes to the named context that was active (see
`cmacs-journal-attribute-contexts'): EVENTS should hold the `context'
events of the range, or already carry `:context' as
`cmacs-journal-context-events' returns them.  Time before the first
switch known is under \"(none)\"."
  (let ((totals (make-hash-table :test #'equal)) out)
    (when (eq by 'context)
      (setq events (cmacs-journal-attribute-contexts events)))
    (dolist (event events)
      (when (memq (plist-get event :kind) cmacs-journal-report-kinds)
        (let ((key (cmacs-journal--group-key event by)))
          (puthash key (+ (gethash key totals 0)
                          (or (plist-get event :duration) 0))
                   totals))))
    (maphash (lambda (k v) (push (cons k v) out)) totals)
    (if (eq by 'day)
        (sort out (lambda (a b) (string< (car a) (car b))))
      (sort out (lambda (a b) (> (cdr a) (cdr b)))))))

(defun cmacs-journal--insert-table (span by)
  "Insert an Org table of the journal over SPAN grouped BY at point."
  (let* ((range (cmacs-journal--span-range span))
         (rows (cmacs-journal-summarize
                (if (eq by 'context)
                    ;; With the context that was active before the
                    ;; range began.
                    (cmacs-journal-context-events (car range) (cdr range))
                  (cmacs-journal-events (car range) (cdr range)))
                by))
         (total (apply #'+ (mapcar #'cdr rows)))
         (start nil))
    (setq start (point))
    (insert (format "| %s | Time | %% |\n|-\n" (capitalize (format "%s" by))))
    (pcase-dolist (`(,key . ,seconds) rows)
      (insert (format "| %s | %s | %d |\n"
                      ;; A `|' in a title would split the cell.
                      (string-replace "|" "\\vert{}" key)
                      (cmacs-journal--format-duration seconds)
                      (if (> total 0) (round (* 100.0 (/ seconds total))) 0))))
    (insert (format "|-\n| Total | %s | |\n"
                    (cmacs-journal--format-duration total)))
    ;; Align from inside the table, then come back to its end: aligning
    ;; rewrites the rows, which is no place to trust point.
    (when (and (derived-mode-p 'org-mode) (fboundp 'org-table-align))
      (let ((end (copy-marker (point) t)))
        (goto-char start)
        (org-table-align)
        (goto-char end)
        (set-marker end nil)))))

(defconst cmacs-journal--report-bys '("project" "app" "day" "kind" "context")
  "Groupings `cmacs-journal-report' offers.")

(defconst cmacs-journal--report-spans '("today" "yesterday" "week" "month")
  "Spans `cmacs-journal-report' offers (a number of days also works).")

;;;###autoload
(defun cmacs-journal-report (span by)
  "Show time by project, app, day, kind or context over SPAN as an Org table.
SPAN is `today', `yesterday', `week', `month', a number of days or a
YYYY-MM-DD date; BY is `project', `app', `day', `kind' or `context' (the
named context of cmacs-context.el that was active)."
  (interactive
   (list (completing-read "Span (or days, or a date): "
                          cmacs-journal--report-spans nil nil nil nil "today")
         (intern (completing-read "By: " cmacs-journal--report-bys
                                  nil t nil nil "project"))))
  (require 'org)
  (cmacs-journal-flush)
  (let ((buffer (get-buffer-create "*cmacs-journal*"))
        (range (cmacs-journal--span-range span)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (format "#+title: Journal by %s\n# %s -- %s\n\n" by
                        (format-time-string "%Y-%m-%d %H:%M" (car range))
                        (format-time-string "%Y-%m-%d %H:%M" (cdr range))))
        (cmacs-journal--insert-table range by))
      ;; "Restore to here": on a row of a report by day, the plan for
      ;; the end of that day.  A map of this buffer's own, so Org's is
      ;; left as it was.
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map (current-local-map))
        (define-key map (kbd "C-c C-r") #'cmacs-journal-restore-at-point)
        ;; The day's note (cmacs-journal-daily.el): today's, or with a
        ;; prefix argument the note of a date that is asked for.
        (define-key map (kbd "C-c C-d") #'cmacs-journal-daily)
        (use-local-map map))
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (pop-to-buffer buffer)))

;;;###autoload
(defun org-dblock-write:cmacs-journal (params)
  "Write the Org dynamic block `cmacs-journal'.

  #+BEGIN: cmacs-journal :span today :by project
  #+END:

PARAMS holds :span (default today; as `cmacs-journal-report') and :by
\(default project)."
  (let ((by (plist-get params :by)))
    (cmacs-journal--insert-table
     (or (plist-get params :span) 'today)
     (cond ((null by) 'project)
           ((stringp by) (intern by))
           (t by)))
    ;; The block's #+END: follows on its own line.
    (when (bolp) (delete-char -1))))

;;;; Recall

(defun cmacs-journal--read-moment (prompt)
  "Read a date and time with PROMPT; return seconds."
  (require 'org)
  (float-time (org-read-date t t nil prompt)))

(defun cmacs-journal--around (time)
  "Events within `cmacs-journal-at-window' of TIME, oldest first."
  (cmacs-journal-events (- time cmacs-journal-at-window)
                        (+ time cmacs-journal-at-window)))

(defun cmacs-journal--describe (event)
  "One line saying what EVENT was."
  (let ((what (or (plist-get event :url)
                  (plist-get event :file)
                  (plist-get event :buffer)
                  (plist-get event :title)
                  "")))
    (format "%s  %6s  %-6s %-18s %s%s"
            (format-time-string "%H:%M:%S" (plist-get event :time))
            (cmacs-journal--format-duration (or (plist-get event :duration) 0))
            (plist-get event :kind)
            (truncate-string-to-width (or (plist-get event :app) "") 18)
            what
            (if (plist-get event :project)
                (format "  [%s]" (plist-get event :project))
              ""))))

;;;###autoload
(defun cmacs-journal-at (time)
  "Show what was focused, and what else was open, around TIME.
TIME is in seconds; interactively, a date and time read the Org way."
  (interactive (list (cmacs-journal--read-moment "Journal at")))
  (cmacs-journal-flush)
  (let ((events (cmacs-journal--around time)))
    (with-help-window "*cmacs-journal-at*"
      (princ (format "The journal around %s\n"
                     (format-time-string "%Y-%m-%d %H:%M" time)))
      (let ((context (cmacs-journal-context-at time)))
        (when context (princ (format "Context: %s\n" context))))
      (princ "\n")
      (if (null events)
          (princ "Nothing recorded: the journal was off, paused, locked, or a filter excluded it.\n")
        (dolist (event events)
          (let ((start (with-current-buffer standard-output (point))))
            (princ (if (and (<= (plist-get event :time) time)
                            (>= (or (plist-get event :end) 0) time))
                       "> " "  "))
            (princ (cmacs-journal--describe event))
            (princ "\n")
            ;; Each line is a moment `R' can restore to: the last one
            ;; at which this span had the focus.
            (with-current-buffer standard-output
              (let ((inhibit-read-only t))
                (add-text-properties
                 start (point)
                 (list 'cmacs-journal-time (or (plist-get event :end)
                                               (plist-get event :time))
                       'keymap cmacs-journal-moment-map))))))
        (princ "\nR on a line shows the plan for restoring that moment.\n")))
    events))

;;;###autoload
(defun cmacs-journal-reopen (time)
  "Reopen the files and pages the journal has around TIME.

Files that still exist are visited and URLs are handed to `browse-url'.
Windows of other programs are listed, not started again: the journal
knows a title, not a command line."
  (interactive (list (cmacs-journal--read-moment "Reopen from")))
  (cmacs-journal-flush)
  (let ((events (cmacs-journal--around time))
        files urls apps)
    (dolist (event events)
      (let ((file (plist-get event :file))
            (url (plist-get event :url)))
        (cond
         ;; A hashed or blanked field is not something to open.
         ((and url (string-match-p "\\`[a-z][a-z0-9+.-]*:" url))
          (cl-pushnew url urls :test #'equal))
         ((and file (not (string-prefix-p "#" file)))
          (cl-pushnew file files :test #'equal))
         ((eq (plist-get event :kind) 'focus)
          (cl-pushnew (format "%s -- %s" (or (plist-get event :app) "?")
                              (or (plist-get event :title) ""))
                      apps :test #'equal)))))
    (setq files (cl-remove-if-not
                 (lambda (f) (and (not (file-remote-p f)) (file-exists-p f)))
                 (nreverse files))
          urls (nreverse urls)
          apps (nreverse apps))
    (when (and (or files urls)
               (or (not (called-interactively-p 'interactive))
                   (y-or-n-p (format "Reopen %d file%s and %d page%s? "
                                     (length files)
                                     (if (= (length files) 1) "" "s")
                                     (length urls)
                                     (if (= (length urls) 1) "" "s")))))
      (dolist (file files) (find-file-noselect file))
      (dolist (url urls) (browse-url url))
      (when files (switch-to-buffer (find-file-noselect (car files)))))
    (when apps
      (with-help-window "*cmacs-journal-reopen*"
        (princ "Other windows that were open then (not restarted):\n\n")
        (dolist (app apps) (princ (format "  %s\n" app)))))
    (list :files files :urls urls :apps apps)))

;;;; Org clock

(defun cmacs-journal--clock-ranges (events)
  "Merge EVENTS into (START . END) stretches for CLOCK lines.
Spans closer than `cmacs-journal-clock-merge-gap' become one stretch."
  (let (ranges)
    (dolist (event events)
      (let ((start (plist-get event :time))
            (end (plist-get event :end)))
        (when (and start end)
          (if (and ranges
                   (<= (- start (cdar ranges)) cmacs-journal-clock-merge-gap))
              (setcdr (car ranges) (max end (cdar ranges)))
            (push (cons start end) ranges)))))
    (nreverse ranges)))

(defun cmacs-journal--clock-line (start end)
  "An Org CLOCK line from START to END, or nil for under a minute."
  (let ((minutes (floor (- end start) 60)))
    (when (>= minutes 1)
      (format "CLOCK: %s--%s => %2d:%02d\n"
              (format-time-string "[%Y-%m-%d %a %H:%M]" start)
              (format-time-string "[%Y-%m-%d %a %H:%M]" end)
              (/ minutes 60) (% minutes 60)))))

;;;###autoload
(defun cmacs-journal-org-clock (project day)
  "Insert CLOCK lines for PROJECT on DAY under the Org heading at point.

PROJECT is a project name as the journal has it; DAY is a YYYY-MM-DD
string.  This is the only way the journal reaches an Org file, and it
happens only when you run it.  Returns the number of lines inserted."
  (interactive
   (let* ((day (progn (require 'org) (org-read-date nil nil nil "Day")))
          (range (cmacs-journal--span-range day))
          (projects (delete-dups
                     (delq nil (mapcar (lambda (e) (plist-get e :project))
                                       (cmacs-journal-events
                                        (car range) (cdr range)))))))
     (unless projects
       (user-error "The journal has no project time on %s" day))
     (list (completing-read "Project: " projects nil t) day)))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (let* ((range (cmacs-journal--span-range day))
         (events (cl-remove-if-not
                  (lambda (e) (equal (plist-get e :project) project))
                  (cmacs-journal-events (car range) (cdr range))))
         (lines (delq nil
                      (mapcar (lambda (r)
                                (cmacs-journal--clock-line (car r) (cdr r)))
                              (cmacs-journal--clock-ranges events)))))
    (when lines
      (save-excursion
        (org-back-to-heading t)
        (org-end-of-meta-data)
        (dolist (line lines) (insert line))))
    (when (called-interactively-p 'interactive)
      (message "cmacs-journal: %d CLOCK line%s inserted" (length lines)
               (if (= (length lines) 1) "" "s")))
    (length lines)))

(provide 'cmacs-journal-report)

;;; cmacs-journal-report.el ends here
