;;; cmacs-brigade-schedule.el --- Scheduled agent runs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Cron for agents: a prompt, a provider and model, a tool allowlist, and
;; a time to fire.
;;
;; Schedules are org headlines, for the same reason plans are.  The
;; headline is the description, the body is the prompt, and the
;; properties are the schedule -- so a schedule is greppable, refilable,
;; diffable and in git, and `org-agenda' can see it without being taught
;; anything.  A schedule is intent; the runs it produces are runtime.
;;
;;     * Weekday mail briefing                        :brigade_schedule:
;;       :PROPERTIES:
;;       :CRON:   0 8 * * 1-5
;;       :AGENT:  triage
;;       :MODEL:  claude/claude-sonnet-4-6
;;       :TOOLS:  mail_search, mail_read, memory_search
;;       :BUDGET: 0.25
;;       :END:
;;       Summarise anything that arrived overnight and flag what needs a
;;       reply today.
;;
;; Per-schedule model and tool selection works by deriving an agent from
;; the named one and registering it under a schedule-specific name.  That
;; is deliberately built on the public `cmacs-brigade-register-agent'
;; rather than a private path into the runner: a schedule can express
;; exactly what any hand-written agent definition can, and nothing more.
;;
;; The cron dialect is the ordinary five-field one -- ranges, lists,
;; steps, month and day names -- plus @daily and friends, and an @every
;; extension for intervals that do not fit a wall-clock grid.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
;; Firing a schedule starts a task, so the runner has to be present --
;; a `declare-function' alone silences the compiler without loading it.
(require 'cmacs-brigade-run)
(require 'cmacs-brigade-agent-def)
(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-brigade-schedule nil
  "Scheduled agent runs."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-schedule-")

(defcustom cmacs-brigade-schedule-file nil
  "Org file holding the schedules.

nil means `schedules.org' under `cmacs-brigade-plan-directory'."
  :type '(choice (const :tag "schedules.org in the plan directory" nil) file)
  :group 'cmacs-brigade-schedule)

(defcustom cmacs-brigade-schedule-tag "brigade_schedule"
  "Tag put on schedule headlines.

Underscore, not a hyphen: org tags are drawn from
[[:alnum:]_@#%], so a hyphenated tag silently is not one -- it stays
part of the heading text and turns up in the title."
  :type 'string
  :group 'cmacs-brigade-schedule)

(defcustom cmacs-brigade-schedule-log-file nil
  "Plan file that fired runs are appended to.

nil means `schedule-runs.org' beside the schedule file.  Kept separate
from the schedules themselves so a year of history does not bury the
half-dozen headlines you actually edit."
  :type '(choice (const :tag "schedule-runs.org beside the schedules" nil)
                 file)
  :group 'cmacs-brigade-schedule)

(defcustom cmacs-brigade-schedule-state-file nil
  "Where last-fire times are persisted.

nil means `schedules.eld' under `cmacs-brigade-state-dir'.  Without this
a restart would either re-run everything or silently lose the fact that
a run was missed."
  :type '(choice (const :tag "schedules.eld in the state directory" nil) file)
  :group 'cmacs-brigade-schedule)

(defcustom cmacs-brigade-schedule-catchup 'skip
  "What to do about a fire that was missed while cmacs was not running.

`skip' forgets it; `run' fires it once on startup, however many were
missed.  Per-schedule `:CATCHUP:' overrides this.

`skip' is the default because the common missed run is an overnight one
whose moment has passed -- an 8am briefing delivered at 6pm is noise.
Set `run' for jobs whose value does not expire."
  :type '(choice (const :tag "Forget it" skip)
                 (const :tag "Run once on startup" run))
  :group 'cmacs-brigade-schedule)

(defcustom cmacs-brigade-schedule-catchup-grace 86400
  "How stale a missed fire may be and still be caught up, in seconds.

A machine off for a month should not wake up and fire a month of
backlog.  Only misses newer than this run."
  :type 'integer
  :group 'cmacs-brigade-schedule)

(defcustom cmacs-brigade-schedule-max-horizon-days 1461
  "How far ahead to search for the next fire before giving up.

Four years, so that `0 0 29 2 *' -- the 29th of February -- resolves
rather than looping forever."
  :type 'integer
  :group 'cmacs-brigade-schedule)

(defvar cmacs-brigade-schedule-fired-functions nil
  "Abnormal hook run with the schedule plist and task id when one fires.")

(declare-function cmacs-brigade-plan-adopt "cmacs-brigade-plan")
(declare-function cmacs-brigade-plan-mode "cmacs-brigade-plan")
;; Private to the plan layer, but exactly the right primitives: one
;; reads an entry's body as the prompt, the other mints the stable id a
;; fired task is then started by.  Reimplementing either here would be a
;; second definition of what a task's identity and prompt are.
(declare-function cmacs-brigade-plan--entry-id "cmacs-brigade-plan")
(declare-function cmacs-brigade-plan--entry-body "cmacs-brigade-plan")
(declare-function cmacs-brigade-task-transition "cmacs-brigade-state.c")
(declare-function cmacs-brigade-agent-get "cmacs-brigade-agent-def")
(declare-function cmacs-ai-call "cmacs-ai-call")
(declare-function org-id-new "org-id")

(defvar cmacs-brigade-plan-directory)
(defvar cmacs-brigade-plan-todo-line)

(define-error 'cmacs-brigade-schedule-error "Brigade schedule error"
  'cmacs-brigade-error)


;;;; Cron parsing
;;
;; Fields are kept as sorted integer lists plus a "was it a star" flag.
;; The flag is not cosmetic: standard cron treats day-of-month and
;; day-of-week as a union when *both* are restricted, and there is no way
;; to reconstruct that from the expanded list alone -- `*' in day-of-week
;; expands to every day, which is indistinguishable from `0-6' written
;; out, and the two mean different things.

(defconst cmacs-brigade-schedule--months
  '(("january" . 1) ("february" . 2) ("march" . 3) ("april" . 4)
    ("may" . 5) ("june" . 6) ("july" . 7) ("august" . 8)
    ("september" . 9) ("october" . 10) ("november" . 11) ("december" . 12))
  "Month names.  Matched by prefix, so both `jan' and `january' work.")

(defconst cmacs-brigade-schedule--days
  '(("sunday" . 0) ("monday" . 1) ("tuesday" . 2) ("wednesday" . 3)
    ("thursday" . 4) ("friday" . 5) ("saturday" . 6))
  "Day names.  Matched by prefix, so both `mon' and `monday' work.")

(defconst cmacs-brigade-schedule--macros
  '(("@yearly"    . "0 0 1 1 *")
    ("@annually"  . "0 0 1 1 *")
    ("@monthly"   . "0 0 1 * *")
    ("@weekly"    . "0 0 * * 0")
    ("@daily"     . "0 0 * * *")
    ("@midnight"  . "0 0 * * *")
    ("@hourly"    . "0 * * * *"))
  "Named schedules, expanded before parsing.")

(defconst cmacs-brigade-schedule--units
  '(("s" . 1) ("m" . 60) ("h" . 3600) ("d" . 86400) ("w" . 604800))
  "Suffixes accepted by @every.")

(defun cmacs-brigade-schedule--field-names (field)
  "Name table for FIELD, or nil if it takes no names."
  (pcase field
    ('month cmacs-brigade-schedule--months)
    ('dow cmacs-brigade-schedule--days)
    (_ nil)))

(defun cmacs-brigade-schedule--field-range (field)
  "Return (MIN . MAX) for FIELD."
  (pcase field
    ('minute '(0 . 59))
    ('hour '(0 . 23))
    ('dom '(1 . 31))
    ('month '(1 . 12))
    ('dow '(0 . 6))))

(defun cmacs-brigade-schedule--atom (s field)
  "Resolve S -- a number or a name -- to an integer in FIELD.

Names are matched as a prefix of at least three letters, and the *whole*
atom has to be that prefix.  Truncating to three characters and looking
only at those would quietly accept `mon-\=' and `jan1\=' as Monday and
January, turning a typo into a schedule that runs at the wrong time
without ever saying so."
  (let* ((low (downcase s))
         (named (and (>= (length low) 3)
                     (string-match-p "\\`[a-z]+\\'" low)
                     (cl-find-if (lambda (cell)
                                   (string-prefix-p low (car cell)))
                                 (cmacs-brigade-schedule--field-names field)))))
    (cond
     ((and named (not (string-match-p "\\`[0-9]+\\'" s))) (cdr named))
     ((string-match-p "\\`[0-9]+\\'" s)
      (let ((n (string-to-number s)))
        ;; Both 0 and 7 are Sunday, everywhere cron is spoken.
        (if (and (eq field 'dow) (= n 7)) 0 n)))
     (t (signal 'cmacs-brigade-schedule-error
                (list (format "not a %s: %s" field s)))))))

(defun cmacs-brigade-schedule--parse-field (spec field)
  "Parse SPEC for FIELD.  Returns (VALUES . STARP)."
  (let* ((range (cmacs-brigade-schedule--field-range field))
         (lo (car range)) (hi (cdr range))
         (starp (or (string= spec "*") (string= spec "?")))
         values)
    (dolist (part (split-string spec "," t "[ \t]+"))
      (let* ((step 1) body)
        ;; A trailing /N is a step over whatever precedes it.
        (if (string-match "\\`\\(.*\\)/\\([0-9]+\\)\\'" part)
            (setq body (match-string 1 part)
                  step (string-to-number (match-string 2 part)))
          (setq body part))
        (when (< step 1)
          (signal 'cmacs-brigade-schedule-error
                  (list (format "step must be positive: %s" part))))
        (let (from to)
          (cond
           ((or (string= body "*") (string= body "?"))
            (setq from lo to hi))
           ((string-match "\\`\\([^-]+\\)-\\([^-]+\\)\\'" body)
            (setq from (cmacs-brigade-schedule--atom (match-string 1 body) field)
                  to (cmacs-brigade-schedule--atom (match-string 2 body) field)))
           (t (setq from (cmacs-brigade-schedule--atom body field)
                    ;; A bare value with a step means "from here on",
                    ;; which is what 5/10 means everywhere else.
                    to (if (> step 1) hi from))))
          (when (or (< from lo) (> to hi) (> from to))
            (signal 'cmacs-brigade-schedule-error
                    (list (format "%s out of range in %s field" part field))))
          (cl-loop for v from from to to by step do (push v values)))))
    (cons (sort (delete-dups values) #'<) starp)))

(defun cmacs-brigade-schedule-parse (expr)
  "Parse cron EXPR into a spec plist.

Accepts the five-field form, the @-macros, @reboot, and
@every N<s|m|h|d|w>.  Signals `cmacs-brigade-schedule-error' on
anything it cannot read, rather than quietly scheduling the wrong time."
  (let ((e (string-trim (or expr ""))))
    (when (string-empty-p e)
      (signal 'cmacs-brigade-schedule-error (list "empty schedule")))
    (cond
     ((string-prefix-p "@reboot" (downcase e)) (list :kind 'reboot))
     ((string-match "\\`@every[ \t]+\\([0-9]+\\)[ \t]*\\([smhdw]\\)?\\'"
                    (downcase e))
      (let* ((n (string-to-number (match-string 1 (downcase e))))
             (unit (or (match-string 2 (downcase e)) "m"))
             (secs (* n (cdr (assoc unit cmacs-brigade-schedule--units)))))
        (when (< secs 1)
          (signal 'cmacs-brigade-schedule-error (list "interval must be > 0")))
        (list :kind 'every :interval secs)))
     (t
      (let ((expanded (or (cdr (assoc (downcase e)
                                      cmacs-brigade-schedule--macros))
                          e)))
        (when (string-prefix-p "@" expanded)
          (signal 'cmacs-brigade-schedule-error
                  (list (format "unknown macro: %s" e))))
        (let ((fields (split-string expanded "[ \t]+" t)))
          (unless (= (length fields) 5)
            (signal 'cmacs-brigade-schedule-error
                    (list (format "expected 5 fields, got %d: %s"
                                  (length fields) expr))))
          (cl-destructuring-bind (fmin fhour fdom fmonth fdow) fields
            (let ((mi (cmacs-brigade-schedule--parse-field fmin 'minute))
                  (ho (cmacs-brigade-schedule--parse-field fhour 'hour))
                  (dm (cmacs-brigade-schedule--parse-field fdom 'dom))
                  (mo (cmacs-brigade-schedule--parse-field fmonth 'month))
                  (dw (cmacs-brigade-schedule--parse-field fdow 'dow)))
              (list :kind 'cron
                    :minute (car mi) :hour (car ho)
                    :dom (car dm) :month (car mo) :dow (car dw)
                    :dom-star (cdr dm) :dow-star (cdr dw))))))))))

(defun cmacs-brigade-schedule-valid-p (expr)
  "Non-nil if EXPR parses."
  (condition-case nil (and (cmacs-brigade-schedule-parse expr) t)
    (cmacs-brigade-schedule-error nil)))


;;;; Next fire
;;
;; Field-wise fast-forward rather than minute-stepping: a schedule like
;; "0 3 1 1 *" is one match in 525,600 minutes, and walking it a minute
;; at a time to find out would be absurd.  Advancing the coarsest field
;; that fails converges in a few hundred steps at worst.

(defun cmacs-brigade-schedule--encode (sec min hour day month year)
  (encode-time (list sec min hour day month year nil -1 nil)))

(defun cmacs-brigade-schedule--day-matches (spec dom dow)
  "Whether DOM/DOW satisfy SPEC's day fields.

When both day fields are restricted cron takes their union, not their
intersection -- \"1 * * 1 mon\" means the 1st *and* every Monday.  That
surprises people, but matching anything else would surprise everyone who
has used cron before."
  (let ((dom-ok (memq dom (plist-get spec :dom)))
        (dow-ok (memq dow (plist-get spec :dow)))
        (dom-star (plist-get spec :dom-star))
        (dow-star (plist-get spec :dow-star)))
    (cond
     ((and dom-star dow-star) t)
     ((and (not dom-star) (not dow-star)) (or dom-ok dow-ok))
     (dom-star dow-ok)
     (t dom-ok))))

(defun cmacs-brigade-schedule-next (spec &optional after)
  "Return the next time SPEC fires strictly after AFTER, or nil.

AFTER defaults to now.  nil means the search hit
`cmacs-brigade-schedule-max-horizon-days' without a match, which for a
cron expression means it can never fire."
  (let ((after (or after (current-time))))
    (pcase (plist-get spec :kind)
      ('reboot nil)
      ('every (time-add after (plist-get spec :interval)))
      (_
       ;; Start at the top of the next minute: firing is minute-grained,
       ;; and "strictly after" must not return the current minute again.
       (let* ((t0 (time-add after 60))
              (d (decode-time t0))
              (sec 0)
              (min (nth 1 d)) (hour (nth 2 d))
              (day (nth 3 d)) (month (nth 4 d)) (year (nth 5 d))
              (limit (* cmacs-brigade-schedule-max-horizon-days 24 60))
              (steps 0)
              result)
         (while (and (null result) (< steps limit))
           (setq steps (1+ steps))
           (let* ((now (cmacs-brigade-schedule--encode sec min hour day
                                                       month year))
                  (dd (decode-time now)))
             ;; Re-decode every iteration: arithmetic on the raw fields
             ;; can produce day 32, and only encode/decode knows what
             ;; that means in this month.
             (setq min (nth 1 dd) hour (nth 2 dd) day (nth 3 dd)
                   month (nth 4 dd) year (nth 5 dd))
             (cond
              ((not (memq month (plist-get spec :month)))
               ;; Skip to the first of next month.
               (setq month (1+ month) day 1 hour 0 min 0)
               (when (> month 12) (setq month 1 year (1+ year))))
              ((not (cmacs-brigade-schedule--day-matches
                     spec day (nth 6 dd)))
               (setq day (1+ day) hour 0 min 0))
              ((not (memq hour (plist-get spec :hour)))
               (setq hour (1+ hour) min 0))
              ((not (memq min (plist-get spec :minute)))
               (setq min (1+ min)))
              (t (setq result now)))))
         result)))))

(defun cmacs-brigade-schedule-next-runs (expr n &optional after)
  "Return the next N times EXPR fires."
  (let ((spec (cmacs-brigade-schedule-parse expr))
        (at (or after (current-time)))
        out)
    (dotimes (_ n)
      (let ((next (cmacs-brigade-schedule-next spec at)))
        (when next (push next out) (setq at next))))
    (nreverse out)))


;;;; Describing a schedule in English
;;
;; Both for the dashboard and for the model: an agent proposing a cron
;; expression should be able to read back what it just wrote, because
;; "0 0 * * 0" and "0 0 * * *" differ by one character and a factor of
;; seven.

(defun cmacs-brigade-schedule--list-english (values field)
  "Render VALUES of FIELD as English."
  (let* ((names (cmacs-brigade-schedule--field-names field))
         (label (lambda (v)
                  (or (car (rassq v names)) (number-to-string v))))
         (strs (mapcar (lambda (v) (capitalize (funcall label v))) values)))
    (pcase (length strs)
      (0 "")
      (1 (car strs))
      (2 (concat (nth 0 strs) " and " (nth 1 strs)))
      (_ (concat (string-join (butlast strs) ", ") " and " (car (last strs)))))))

(defun cmacs-brigade-schedule--every-p (values field)
  "Whether VALUES covers all of FIELD."
  (let ((r (cmacs-brigade-schedule--field-range field)))
    (= (length values) (1+ (- (cdr r) (car r))))))

(defun cmacs-brigade-schedule-describe (expr)
  "Describe cron EXPR in English."
  (condition-case err
      (let ((spec (cmacs-brigade-schedule-parse expr)))
        (pcase (plist-get spec :kind)
          ('reboot "when cmacs starts")
          ('every (format "every %s"
                          (cmacs-brigade-schedule--duration
                           (plist-get spec :interval))))
          (_
           (let* ((mins (plist-get spec :minute))
                  (hours (plist-get spec :hour))
                  (every-min (cmacs-brigade-schedule--every-p mins 'minute))
                  (every-hour (cmacs-brigade-schedule--every-p hours 'hour))
                  (time
                   (cond
                    ((and every-min every-hour) "every minute")
                    (every-min
                     (format "every minute during %s"
                             (cmacs-brigade-schedule--list-english
                              hours 'hour)))
                    (every-hour
                     (if (equal mins '(0)) "every hour on the hour"
                       (format "at %s minutes past every hour"
                               (cmacs-brigade-schedule--list-english
                                mins 'minute))))
                    (t
                     (format "at %s"
                             (string-join
                              (cl-loop for h in hours append
                                       (cl-loop for m in mins collect
                                                (format "%02d:%02d" h m)))
                              ", ")))))
                  (day
                   (cond
                    ((and (plist-get spec :dom-star)
                          (plist-get spec :dow-star))
                     "every day")
                    ((plist-get spec :dom-star)
                     (format "on %s"
                             (cmacs-brigade-schedule--list-english
                              (plist-get spec :dow) 'dow)))
                    ((plist-get spec :dow-star)
                     (format "on day %s of the month"
                             (cmacs-brigade-schedule--list-english
                              (plist-get spec :dom) 'dom)))
                    (t (format "on day %s of the month, or on %s"
                               (cmacs-brigade-schedule--list-english
                                (plist-get spec :dom) 'dom)
                               (cmacs-brigade-schedule--list-english
                                (plist-get spec :dow) 'dow)))))
                  (month
                   (if (cmacs-brigade-schedule--every-p
                        (plist-get spec :month) 'month)
                       ""
                     (format " in %s"
                             (cmacs-brigade-schedule--list-english
                              (plist-get spec :month) 'month)))))
             (concat time ", " day month)))))
    (cmacs-brigade-schedule-error
     (format "invalid (%s)" (cadr err)))))

(defun cmacs-brigade-schedule--duration (secs)
  "Render SECS as a short duration."
  (cond ((< secs 60) (format "%d seconds" secs))
        ((< secs 3600) (format "%d minutes" (/ secs 60)))
        ((< secs 86400) (format "%d hours" (/ secs 3600)))
        (t (format "%d days" (/ secs 86400)))))

;;;; Reading schedules out of org

(defun cmacs-brigade-schedule--file ()
  "The schedule file, created if absent."
  (require 'cmacs-brigade-plan)
  (let ((file (or cmacs-brigade-schedule-file
                  (expand-file-name "schedules.org"
                                    cmacs-brigade-plan-directory))))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+title: Brigade schedules\n\n"
                "# One headline per schedule.  The headline is the\n"
                "# description, the body is the prompt.\n")))
    file))

(defun cmacs-brigade-schedule--log-file ()
  "The plan file fired runs are appended to, created if absent."
  (require 'cmacs-brigade-plan)
  (let ((file (or cmacs-brigade-schedule-log-file
                  (expand-file-name "schedule-runs.org"
                                    (file-name-directory
                                     (cmacs-brigade-schedule--file))))))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (with-temp-file file
        (insert "#+title: Scheduled runs\n"
                cmacs-brigade-plan-todo-line "\n\n")))
    file))

(defun cmacs-brigade-schedule--split-tools (s)
  "Parse a :TOOLS: property S into a list of symbols."
  (when (and s (not (string-empty-p (string-trim s))))
    (mapcar #'intern (split-string s "[, \t]+" t))))

(defun cmacs-brigade-schedule--truthy (s default)
  "Read S as a boolean, DEFAULT when absent."
  (if (null s) default
    (not (member (downcase (string-trim s))
                 '("no" "nil" "false" "off" "0" "disabled")))))

(defun cmacs-brigade-schedule--entry-id ()
  "Return this schedule's stable id, creating one if needed.

Its own property rather than org's `:ID:': a schedule is not a task, and
giving it one would put it in `org-id''s index alongside things that
actually are."
  (or (org-entry-get nil "SCHEDULE-ID")
      (let ((id (format "sched-%s-%04x"
                        (format-time-string "%Y%m%d%H%M%S")
                        (random 65536))))
        (org-entry-put nil "SCHEDULE-ID" id)
        id)))

(defun cmacs-brigade-schedule--read-entry (file)
  "Read the schedule at point out of FILE."
  (let ((cron (org-entry-get nil "CRON")))
    (when cron
      (list :id (cmacs-brigade-schedule--entry-id)
            :title (org-get-heading t t t t)
            :cron cron
            :agent (org-entry-get nil "AGENT")
            :model (org-entry-get nil "MODEL")
            :provider (org-entry-get nil "PROVIDER")
            :tools (cmacs-brigade-schedule--split-tools
                    (org-entry-get nil "TOOLS"))
            :budget (org-entry-get nil "BUDGET")
            :isolation (org-entry-get nil "ISOLATION")
            :worker (org-entry-get nil "WORKER")
            :description (org-entry-get nil "DESC")
            :catchup (let ((c (org-entry-get nil "CATCHUP")))
                       (if c (intern (downcase c))
                           cmacs-brigade-schedule-catchup))
            :enabled (cmacs-brigade-schedule--truthy
                      (org-entry-get nil "ENABLED") t)
            :prompt (cmacs-brigade-plan--entry-body)
            :file file))))

(defun cmacs-brigade-schedule-list ()
  "Return every schedule, as plists."
  (require 'cmacs-brigade-plan)
  (let ((file (cmacs-brigade-schedule--file))
        out)
    (with-current-buffer (find-file-noselect file)
      (let ((was-modified (buffer-modified-p)))
        (org-map-entries
         (lambda ()
           (when-let* ((s (cmacs-brigade-schedule--read-entry file)))
             (push s out)))
         nil nil)
        ;; Reading can mint ids, which modifies the buffer.  Save only
        ;; when that is the only thing that changed, so a listing never
        ;; commits half-finished hand edits.
        (when (and (buffer-modified-p) (not was-modified))
          (save-buffer))))
    (nreverse out)))

(defun cmacs-brigade-schedule-get (id)
  "Return the schedule with ID, or nil."
  (cl-find id (cmacs-brigade-schedule-list)
           :key (lambda (s) (plist-get s :id)) :test #'equal))


;;;; Deriving an agent
;;
;; A schedule's model and tool choices are expressed by deriving an agent
;; from the named one and registering it under a schedule-specific name.
;; Built on the public registry rather than a private path into the
;; runner, so a schedule can say exactly what a hand-written agent
;; definition can, and nothing it could not.

(defun cmacs-brigade-schedule--agent-name (sched)
  "The registered agent name backing SCHED."
  (intern (format "schedule:%s" (plist-get sched :id))))

(defun cmacs-brigade-schedule-ensure-agent (sched)
  "Register the agent SCHED runs as, and return its name.

Delegates to `cmacs-brigade-agent-derive\=' -- the same primitive a plan
task with its own :MODEL: uses -- so there is one definition of what
overriding a model or a tool list means rather than two that drift."
  (condition-case err
      (cmacs-brigade-agent-derive
       (plist-get sched :agent)
       (plist-get sched :id)
       (list :model (plist-get sched :model)
             :tools (plist-get sched :tools)
             :budget-usd (when-let* ((b (plist-get sched :budget)))
                           (string-to-number b))
             :isolation (when-let* ((i (plist-get sched :isolation)))
                          (intern i))
             :worker (when-let* ((w (plist-get sched :worker)))
                       (intern w)))
       ;; Forced: a schedule needs an agent even when it names no base
       ;; and overrides nothing.
       t)
    (cmacs-brigade-agent-error
     (signal 'cmacs-brigade-schedule-error (cdr err)))))


;;;; Persisted last-fire times

(defun cmacs-brigade-schedule--state-file ()
  (or cmacs-brigade-schedule-state-file
      (expand-file-name "schedules.eld" cmacs-brigade-state-dir)))

(defvar cmacs-brigade-schedule--last nil
  "Alist of schedule id -> last fire time, as a float.")

(defun cmacs-brigade-schedule--load-state ()
  (let ((file (cmacs-brigade-schedule--state-file)))
    (setq cmacs-brigade-schedule--last
          (when (file-readable-p file)
            (ignore-errors
              (with-temp-buffer
                (insert-file-contents file)
                (read (current-buffer))))))))

(defun cmacs-brigade-schedule--save-state ()
  (let ((file (cmacs-brigade-schedule--state-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (prin1 cmacs-brigade-schedule--last (current-buffer)))))

(defun cmacs-brigade-schedule-last-fire (id)
  "When ID last fired, or nil."
  (cdr (assoc id cmacs-brigade-schedule--last)))

(defun cmacs-brigade-schedule--record-fire (id)
  (setf (alist-get id cmacs-brigade-schedule--last nil nil #'equal)
        (float-time))
  (cmacs-brigade-schedule--save-state))


;;;; Firing

(defun cmacs-brigade-schedule-fire (sched)
  "Run SCHED now.  Returns the task id."
  (let* ((agent (cmacs-brigade-schedule-ensure-agent sched))
         (log (cmacs-brigade-schedule--log-file))
         (stamp (format-time-string "%F %R"))
         task-id)
    (with-current-buffer (find-file-noselect log)
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* TODO %s (%s)  :brigade:\n"
                        (plist-get sched :title) stamp))
        (insert "  :PROPERTIES:\n"
                (format "  :AGENT:  %s\n" agent)
                (format "  :SCHEDULE: %s\n" (plist-get sched :id))
                "  :END:\n")
        (insert "  " (or (plist-get sched :prompt) "") "\n")
        ;; Mint the id while point is still on the new headline, so the
        ;; task can be started without having to work out which of the
        ;; file's entries was the one just added.
        (org-back-to-heading t)
        (setq task-id (cmacs-brigade-plan--entry-id 'create)))
      (save-buffer)
      (cmacs-brigade-plan-adopt))
    (cmacs-brigade-schedule--record-fire (plist-get sched :id))
    (cmacs-brigade-task-transition task-id 'queued)
    (cmacs-brigade-start-task task-id)
    (run-hook-with-args 'cmacs-brigade-schedule-fired-functions sched task-id)
    task-id))

;;;###autoload
(defun cmacs-brigade-schedule-run-now (id)
  "Run schedule ID immediately, without waiting for its next time."
  (interactive
   (list (completing-read "Schedule: "
                          (mapcar (lambda (s) (plist-get s :id))
                                  (cmacs-brigade-schedule-list))
                          nil t)))
  (let ((s (cmacs-brigade-schedule-get id)))
    (unless s (user-error "cmacs-brigade: no schedule %s" id))
    (let ((task (cmacs-brigade-schedule-fire s)))
      (message "cmacs-brigade: fired %s as %s" (plist-get s :title) task)
      task)))


;;;; The timer
;;
;; One timer for all schedules, aimed at the earliest next fire, rather
;; than one timer each.  Timers are the thing that leaks when a file is
;; reloaded, and there is exactly one here to cancel.

(defvar cmacs-brigade-schedule--timer nil)

(defun cmacs-brigade-schedule--due (sched &optional after)
  "When SCHED next fires after AFTER, or nil if it never does."
  (when (plist-get sched :enabled)
    (condition-case err
        (cmacs-brigade-schedule-next
         (cmacs-brigade-schedule-parse (plist-get sched :cron)) after)
      (cmacs-brigade-schedule-error
       ;; A typo in one schedule must not stop the others from running.
       (message "cmacs-brigade-schedule: %s: %s"
                (plist-get sched :title) (cadr err))
       nil))))

(defun cmacs-brigade-schedule--tick ()
  "Fire everything now due, then re-arm."
  (setq cmacs-brigade-schedule--timer nil)
  (let ((now (current-time)))
    (dolist (s (cmacs-brigade-schedule-list))
      (when (plist-get s :enabled)
        ;; Due means "the next fire computed from the last one has
        ;; arrived".  Anchoring on the last fire rather than on now is
        ;; what stops a timer that runs a few seconds early from
        ;; skipping the slot entirely.
        (let* ((last (cmacs-brigade-schedule-last-fire (plist-get s :id)))
               (from (if last (seconds-to-time last)
                       (time-subtract now 60)))
               (next (cmacs-brigade-schedule--due s from)))
          (when (and next (time-less-p next now))
            (condition-case err
                (cmacs-brigade-schedule-fire s)
              (error (message "cmacs-brigade-schedule: %s failed: %s"
                              (plist-get s :title)
                              (error-message-string err)))))))))
  (cmacs-brigade-schedule--rearm))

(defun cmacs-brigade-schedule--rearm ()
  "Aim the timer at the earliest upcoming fire."
  (when cmacs-brigade-schedule--timer
    (cancel-timer cmacs-brigade-schedule--timer)
    (setq cmacs-brigade-schedule--timer nil))
  (let ((soonest nil))
    (dolist (s (cmacs-brigade-schedule-list))
      (let ((next (cmacs-brigade-schedule--due s)))
        (when (and next (or (null soonest) (time-less-p next soonest)))
          (setq soonest next))))
    (when soonest
      ;; A second past the minute boundary, so the fire lands inside the
      ;; minute it was scheduled for rather than a hair before it.
      (setq cmacs-brigade-schedule--timer
            (run-at-time (time-add soonest 1) nil
                         #'cmacs-brigade-schedule--tick)))
    soonest))

(defun cmacs-brigade-schedule--catch-up ()
  "Fire anything missed while cmacs was not running."
  (let ((now (current-time)))
    (dolist (s (cmacs-brigade-schedule-list))
      (let ((last (cmacs-brigade-schedule-last-fire (plist-get s :id))))
        (when (and (plist-get s :enabled) last
                   (eq (plist-get s :catchup) 'run))
          (let ((next (cmacs-brigade-schedule--due s (seconds-to-time last))))
            (when (and next (time-less-p next now)
                       ;; A machine off for a month must not wake up and
                       ;; fire a month of backlog.
                       (< (float-time (time-subtract now next))
                          cmacs-brigade-schedule-catchup-grace))
              (message "cmacs-brigade-schedule: catching up %s"
                       (plist-get s :title))
              (ignore-errors (cmacs-brigade-schedule-fire s)))))))))

;;;###autoload
(define-minor-mode cmacs-brigade-schedule-mode
  "Run brigade schedules at their appointed times."
  :global t
  :group 'cmacs-brigade-schedule
  (if cmacs-brigade-schedule-mode
      (progn
        (cmacs-brigade-schedule--load-state)
        (cmacs-brigade-schedule--catch-up)
        ;; @reboot means now, once, at startup.
        (dolist (s (cmacs-brigade-schedule-list))
          (when (and (plist-get s :enabled)
                     (eq 'reboot (ignore-errors
                                   (plist-get (cmacs-brigade-schedule-parse
                                               (plist-get s :cron))
                                              :kind))))
            (ignore-errors (cmacs-brigade-schedule-fire s))))
        (cmacs-brigade-schedule--rearm))
    (when cmacs-brigade-schedule--timer
      (cancel-timer cmacs-brigade-schedule--timer)
      (setq cmacs-brigade-schedule--timer nil))))

;;;###autoload
(defun cmacs-brigade-schedule-reload ()
  "Re-read the schedule file and re-aim the timer."
  (interactive)
  (when cmacs-brigade-schedule-mode
    (let ((next (cmacs-brigade-schedule--rearm)))
      (message "cmacs-brigade: %d schedule(s), next %s"
               (length (cmacs-brigade-schedule-list))
               (if next (format-time-string "%F %R" next) "never")))))


;;;; Writing a schedule

(defun cmacs-brigade-schedule-add (title cron prompt &rest props)
  "Append a schedule to the schedule file and return its id.

PROPS may carry :agent, :model, :tools, :budget, :isolation, :worker,
:catchup and :description."
  (unless (cmacs-brigade-schedule-valid-p cron)
    (signal 'cmacs-brigade-schedule-error
            (list (format "not a valid schedule: %s" cron))))
  (require 'cmacs-brigade-plan)
  (let ((file (cmacs-brigade-schedule--file))
        id)
    (with-current-buffer (find-file-noselect file)
      (save-excursion
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "* %s\n" title))
        (insert "  :PROPERTIES:\n")
        (insert (format "  :CRON:   %s\n" cron))
        (dolist (pair '((:agent . "AGENT") (:model . "MODEL")
                        (:provider . "PROVIDER") (:budget . "BUDGET")
                        (:isolation . "ISOLATION") (:worker . "WORKER")
                        (:catchup . "CATCHUP") (:description . "DESC")))
          (when-let* ((v (plist-get props (car pair))))
            (insert (format "  :%s: %s\n" (cdr pair) v))))
        (when-let* ((tools (plist-get props :tools)))
          (insert (format "  :TOOLS:  %s\n"
                          (mapconcat (lambda (x) (format "%s" x))
                                     (if (listp tools) tools (list tools))
                                     ", "))))
        (insert "  :END:\n")
        (insert "  " (string-trim (or prompt "")) "\n")
        (org-back-to-heading t)
        ;; Set through org rather than written into the headline text:
        ;; org tags may not contain a hyphen, so a hand-written
        ;; ":brigade-schedule:" is not a tag at all -- it is just words
        ;; on the end of the title, which is where it then shows up.
        (org-set-tags (list cmacs-brigade-schedule-tag))
        (setq id (cmacs-brigade-schedule--entry-id)))
      (save-buffer))
    (cmacs-brigade-schedule-reload)
    id))

(defun cmacs-brigade-schedule-set-property (id property value)
  "Set PROPERTY of schedule ID to VALUE.  VALUE nil deletes it."
  (require 'cmacs-brigade-plan)
  (let ((found nil))
    (with-current-buffer (find-file-noselect (cmacs-brigade-schedule--file))
      (save-excursion
        (org-map-entries
         (lambda ()
           (when (equal id (org-entry-get nil "SCHEDULE-ID"))
             (setq found t)
             (if value
                 (org-entry-put nil property (format "%s" value))
               (org-entry-delete nil property))))
         nil nil))
      (when found (save-buffer)))
    (cmacs-brigade-schedule-reload)
    found))

;;;###autoload
(defun cmacs-brigade-schedule-set-enabled (id enabled)
  "Enable or disable schedule ID."
  (interactive
   (list (completing-read "Schedule: "
                          (mapcar (lambda (s) (plist-get s :id))
                                  (cmacs-brigade-schedule-list))
                          nil t)
         (y-or-n-p "Enabled? ")))
  (cmacs-brigade-schedule-set-property id "ENABLED" (if enabled "yes" "no")))

;;;###autoload
(defun cmacs-brigade-schedule-delete (id)
  "Delete schedule ID from the schedule file."
  (interactive
   (list (completing-read "Delete schedule: "
                          (mapcar (lambda (s) (plist-get s :id))
                                  (cmacs-brigade-schedule-list))
                          nil t)))
  (require 'cmacs-brigade-plan)
  (let ((killed nil))
    (with-current-buffer (find-file-noselect (cmacs-brigade-schedule--file))
      (save-excursion
        (goto-char (point-min))
        (org-map-entries
         (lambda ()
           (when (and (not killed)
                      (equal id (org-entry-get nil "SCHEDULE-ID")))
             (org-cut-subtree)
             (setq killed t)))
         nil nil))
      (when killed (save-buffer)))
    (setq cmacs-brigade-schedule--last
          (assoc-delete-all id cmacs-brigade-schedule--last))
    (cmacs-brigade-schedule--save-state)
    (cmacs-brigade-schedule-reload)
    killed))


;;;; Listing

;;;###autoload
(defun cmacs-brigade-schedules ()
  "Show every schedule, when it next runs, and when it last ran."
  (interactive)
  (let ((schedules (cmacs-brigade-schedule-list)))
    (with-current-buffer (get-buffer-create "*brigade schedules*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null schedules)
            (insert "No schedules.\n\nAdd one with "
                    "M-x cmacs-brigade-schedule-from-prompt, or edit\n"
                    (cmacs-brigade-schedule--file) "\n")
          (dolist (s schedules)
            (let ((next (cmacs-brigade-schedule--due s))
                  (last (cmacs-brigade-schedule-last-fire (plist-get s :id))))
              (insert (propertize (plist-get s :title) 'face 'bold)
                      (if (plist-get s :enabled) ""
                        (propertize "  [disabled]" 'face 'shadow))
                      "\n")
              (insert (format "    %-22s %s\n" (plist-get s :cron)
                              (cmacs-brigade-schedule-describe
                               (plist-get s :cron))))
              (insert (format "    agent %-14s model %s\n"
                              (or (plist-get s :agent) "-")
                              (or (plist-get s :model) "default")))
              (insert (format "    next  %-22s last  %s\n\n"
                              (if next (format-time-string "%F %R" next)
                                "never")
                              (if last (format-time-string
                                        "%F %R" (seconds-to-time last))
                                "never"))))))
        (goto-char (point-min)))
      (special-mode)
      (display-buffer (current-buffer)))))

;; Also as a dashboard panel, through the same public registry a user
;; would use.
(cmacs-brigade-register-panel
 :name 'schedules
 :title "Schedules"
 :order 60
 :render
 (lambda ()
   (let ((schedules (ignore-errors (cmacs-brigade-schedule-list))))
     (when schedules
       (mapcar
        (lambda (s)
          (let ((next (cmacs-brigade-schedule--due s)))
            (format "%-28s %-16s %s"
                    (truncate-string-to-width (plist-get s :title) 28)
                    (plist-get s :cron)
                    (cond ((not (plist-get s :enabled)) "disabled")
                          (next (format-time-string "next %F %R" next))
                          (t "never")))))
        schedules)))))


;;;; Tools, so the model can set these up

(when (fboundp 'cmacs-brigade-deftool)

  (cmacs-brigade-deftool schedule-list
    "List the user's scheduled agent tasks: what each one runs, on what
cron expression, and when it next fires."
    ()
    :group 'schedule
    (let ((schedules (cmacs-brigade-schedule-list)))
      (if (null schedules) "No schedules are configured."
        (mapconcat
         (lambda (s)
           (let ((next (cmacs-brigade-schedule--due s)))
             (format "%s [%s]\n  cron: %s (%s)\n  agent: %s  model: %s\n\
  enabled: %s  next: %s"
                     (plist-get s :title) (plist-get s :id)
                     (plist-get s :cron)
                     (cmacs-brigade-schedule-describe (plist-get s :cron))
                     (or (plist-get s :agent) "-")
                     (or (plist-get s :model) "default")
                     (if (plist-get s :enabled) "yes" "no")
                     (if next (format-time-string "%F %R" next) "never"))))
         schedules "\n\n"))))

  (cmacs-brigade-deftool schedule-preview
    "Check a cron expression before using it: returns it in plain English
plus the next few times it would fire.  Use this to confirm an expression
means what you intended."
    ((cron string "Cron expression, e.g. '0 8 * * 1-5', '@daily', '@every 30m'")
     (count integer "How many upcoming times to show" :optional t))
    :group 'schedule
    (condition-case err
        (let* ((n (or count 5))
               (runs (cmacs-brigade-schedule-next-runs cron n)))
          (format "%s means: %s\nNext %d:\n%s"
                  cron (cmacs-brigade-schedule-describe cron) (length runs)
                  (mapconcat (lambda (tm)
                               (concat "  " (format-time-string "%F %a %R" tm)))
                             runs "\n")))
      (error (format "Invalid: %s" (error-message-string err)))))

  (cmacs-brigade-deftool schedule-create
    "Create a scheduled task that runs a prompt on a cron schedule.
Always call schedule_preview first and show the user what the expression
means before creating it."
    ((title string "Short description, used as the headline")
     (cron string "Cron expression, e.g. '0 8 * * 1-5' or '@daily'")
     (prompt string "The prompt the agent runs each time it fires")
     (agent string "Agent definition to base it on" :optional t)
     (model string "Provider/model, e.g. 'claude/claude-sonnet-4-6'"
            :optional t)
     (tools string "Comma-separated tools the agent may use" :optional t)
     (budget string "Spend ceiling per run, in dollars" :optional t))
    :group 'schedule
    ;; Destructive and confirmed: this commits the user to recurring
    ;; spend on a timer, which is exactly the kind of thing that should
    ;; not happen because a model thought it sounded helpful.
    :destructive t :confirm 'ask
    (condition-case err
        (let ((id (apply #'cmacs-brigade-schedule-add
                         title cron prompt
                         (append
                          (when (and agent (not (string-empty-p agent)))
                            (list :agent agent))
                          (when (and model (not (string-empty-p model)))
                            (list :model model))
                          (when (and tools (not (string-empty-p tools)))
                            (list :tools
                                  (cmacs-brigade-schedule--split-tools tools)))
                          (when (and budget (not (string-empty-p budget)))
                            (list :budget budget))))))
          (format "Created %s (%s): %s\nNext run: %s"
                  title id (cmacs-brigade-schedule-describe cron)
                  (let ((n (car (cmacs-brigade-schedule-next-runs cron 1))))
                    (if n (format-time-string "%F %a %R" n) "never"))))
      (error (format "Error: %s" (error-message-string err)))))

  (cmacs-brigade-deftool schedule-set-enabled
    "Enable or disable an existing schedule without deleting it."
    ((id string "Schedule id, from schedule_list")
     (enabled boolean "Whether it should run"))
    :group 'schedule
    :destructive t :confirm 'ask
    (if (cmacs-brigade-schedule-set-enabled id enabled)
        (format "%s is now %s" id (if enabled "enabled" "disabled"))
      (format "No schedule with id %s" id)))

  (cmacs-brigade-deftool schedule-delete
    "Delete a schedule permanently."
    ((id string "Schedule id, from schedule_list"))
    :group 'schedule
    :destructive t :confirm 'ask
    (if (cmacs-brigade-schedule-delete id)
        (format "Deleted %s" id)
      (format "No schedule with id %s" id))))


;;;; Setting one up by asking

(defconst cmacs-brigade-schedule--author-prompt
  "You turn a request into a scheduled task definition.

Reply with JSON only, no prose and no code fence, with these keys:
  title   a short headline, under 60 characters
  cron    a 5-field cron expression, or @daily/@hourly/@weekly, or
          @every N followed by s/m/h/d/w
  prompt  the instruction the agent runs each time -- write it as a
          standalone instruction, since nobody will be present to
          clarify it
  agent   an agent name from the list given, or null
  tools   an array of tool names from the list given, or null

Rules that matter:
- Cron minute comes first.  \"8am on weekdays\" is \"0 8 * * 1-5\", not
  \"8 0 * * 1-5\".
- Prefer a specific time over @daily when the user named one.
- If the request has no sensible recurring time, use \"0 9 * * *\" and
  say so in the title."
  "System prompt used to turn a request into a schedule.")

;;;###autoload
(defun cmacs-brigade-schedule-from-prompt (request)
  "Set up a schedule from REQUEST, described in your own words.

Asks a model to turn it into a cron expression and a prompt, shows what
that would actually do, and creates it only if you agree.  The
confirmation is the point: a wrong cron expression is silent, and you
find out weeks later."
  (interactive "sWhat should happen, and when? ")
  (unless (fboundp 'cmacs-ai-call)
    (user-error "cmacs-brigade: cmacs-ai is not available in this build"))
  (let* ((agents (mapcar #'symbol-name (cmacs-brigade-registry-list 'agent)))
         (tools (mapcar #'symbol-name (cmacs-brigade-registry-list 'tool)))
         (answer (cmacs-ai-call
                  (format "Request: %s\n\nAvailable agents: %s\n\
Available tools: %s"
                          request
                          (if agents (string-join agents ", ") "none")
                          (if tools (string-join tools ", ") "none"))
                  :system cmacs-brigade-schedule--author-prompt))
         (spec (cmacs-brigade-schedule--parse-json answer)))
    (unless spec
      (user-error "cmacs-brigade: could not read a schedule out of that"))
    (let* ((cron (alist-get 'cron spec))
           (title (alist-get 'title spec))
           (prompt (alist-get 'prompt spec)))
      (unless (cmacs-brigade-schedule-valid-p cron)
        (user-error "cmacs-brigade: the model proposed an invalid cron: %s"
                    cron))
      (if (not (cmacs-brigade-schedule--confirm spec))
          (message "cmacs-brigade: not created")
        (let ((id (apply #'cmacs-brigade-schedule-add
                         title cron prompt
                         (append
                          (when-let* ((a (alist-get 'agent spec)))
                            (list :agent a))
                          (when-let* ((tl (alist-get 'tools spec)))
                            (list :tools tl))))))
          (message "cmacs-brigade: created %s (%s)" title id)
          id)))))

(defun cmacs-brigade-schedule--parse-json (answer)
  "Extract the schedule object from ANSWER.

Models wrap JSON in prose and fences however firmly they are asked not
to, so the object is located rather than assumed to be the whole reply."
  (cmacs-brigade-parse-json-object answer))

(defun cmacs-brigade-schedule--confirm (spec)
  "Show SPEC and ask whether to create it."
  (let ((cron (alist-get 'cron spec)))
    (with-current-buffer (get-buffer-create "*brigade schedule proposal*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (alist-get 'title spec) 'face 'bold) "\n\n")
        (insert (format "  cron    %s\n" cron))
        (insert (format "  means   %s\n" (cmacs-brigade-schedule-describe cron)))
        (insert (format "  agent   %s\n" (or (alist-get 'agent spec) "-")))
        (insert (format "  tools   %s\n"
                        (let ((tl (alist-get 'tools spec)))
                          (if tl (string-join
                                  (mapcar (lambda (x) (format "%s" x)) tl) ", ")
                            "-"))))
        (insert "\n  next runs\n")
        (dolist (tm (cmacs-brigade-schedule-next-runs cron 5))
          (insert "    " (format-time-string "%F %a %R" tm) "\n"))
        (insert "\n  prompt\n")
        (dolist (line (split-string (or (alist-get 'prompt spec) "") "\n"))
          (insert "    " line "\n"))
        (goto-char (point-min)))
      (special-mode)
      (display-buffer (current-buffer)))
    (unwind-protect
        (y-or-n-p "Create this schedule? ")
      (quit-window nil (get-buffer-window "*brigade schedule proposal*")))))

(provide 'cmacs-brigade-schedule)

;;; cmacs-brigade-schedule.el ends here
