;;; cmacs-journal-restore.el --- Put me back where I was  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Given a moment -- "Tuesday 3pm", "an hour ago", "before lunch", a
;; line picked in the journal -- rebuild the working context of that
;; moment from the activity journal:
;;
;;   M-x cmacs-journal-restore RET an hour ago RET
;;
;; Three parts, each usable on its own:
;;
;;   * A natural-time parser, `cmacs-journal-restore-parse-time'.  Every
;;     ambiguity resolves to the most recent PAST moment: "3" is the
;;     last three o'clock there was, "Tuesday" on a Tuesday is last
;;     week's.
;;
;;   * A plan, `cmacs-journal-restore-plan': the nearest checkpoint at
;;     or before the moment (cmacs-journal-checkpoint.el) plus the
;;     focus spans recorded since it, turned into a list of items --
;;     files, pages, applications, layout -- and a list of what cannot
;;     be put back, each with its reason.  Building a plan changes
;;     nothing.
;;
;;   * Execution, `cmacs-journal-restore-execute', which runs only from
;;     the plan buffer (or a spoken "yes" after the plan is shown).
;;     Files are visited, the Emacs window tree is rebuilt, pages are
;;     reopened, missing applications are started on their tags and
;;     running ones moved there, then the recorded tags are viewed and
;;     the recorded window focused.
;;
;; What this is honest about, here and in the plan buffer itself: an
;; application is STARTED AGAIN.  Its documents, tabs, scroll positions
;; and unsaved work are its own business and are not restored.  A page
;; is loaded again, not resumed.  A window that was embedded in an Emacs
;; window, a file that is gone, a name a filter withheld: listed, with
;; the reason, and left alone.
;;
;; Nothing here waits.  A started program's window is looked for from a
;; timer, with a deadline; under `emacs --gowl' Emacs is the compositor
;; and a wait for a window would be waiting for itself.
;;
;; Human-only on purpose.  A restore launches programs, so there is no
;; brigade tool, no MCP tool and no D-Bus method for it, and
;; `cmacs-journal-restore-execute' refuses to run for an agent or a
;; remote caller.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'text-property-search)
(require 'cmacs-journal)
(require 'cmacs-journal-checkpoint)
(require 'cmacs-journal-report)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-list-clients "cmacs-gowl.c" ())
(declare-function gowl-list-monitors "cmacs-gowl.c" ())
(declare-function gowl-list-layouts "cmacs-gowl.c" ())
(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-client-pid "cmacs-gowl.c" (client))
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function gowl-find-monitor "cmacs-gowl.c" (name))
(declare-function gowl-find-client "cmacs-gowl.c" (pattern &optional by))
(declare-function gowl-get-layout "cmacs-gowl.c" (&optional monitor))
(declare-function gowl-set-layout "cmacs-gowl.c" (layout &optional monitor))
(declare-function gowl-view-tags "cmacs-gowl.c" (tagmask &optional monitor))
(declare-function gowl-set-tags "cmacs-gowl.c" (client tags))
(declare-function gowl-focus-client "cmacs-gowl.c" (client))
(declare-function gowl-spawn "cmacs-gowl.c" (command))
(declare-function gowl-pretag-pid "cmacs-gowl.c" (pid tagmask &optional monitor))
(declare-function gowl-set-client-floating "cmacs-gowl.c" (client floating))
(declare-function gowl-client-set-geometry "cmacs-gowl.c" (client x y w h))
(declare-function cmacs-gsurf--open "cmacs-gsurf" (url &optional container opener))
(declare-function cmacs-gsurf-supported-p "cmacs-gsurf" ())
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-voice-define-command "cmacs-voice-commands"
                  (regexp function &optional doc append &rest props))
(declare-function cmacs-voice-confirm "cmacs-voice-commands" (prompt action))
(declare-function cmacs-voice--say "cmacs-voice-commands" (fmt &rest args))

(defvar IS-CMACS-GSURF)
(defvar cmacs-voice-confirm-destructive)

(defgroup cmacs-journal-restore nil
  "Rebuild the working context of a past moment from the journal."
  :group 'cmacs-journal
  :prefix "cmacs-journal-restore-")

(defcustom cmacs-journal-restore-day-parts
  '(("before lunch" . "12:00") ("after lunch" . "13:00")
    ("lunchtime" . "12:00") ("lunch" . "12:00")
    ("end of the day" . "17:30") ("end of day" . "17:30")
    ("start of the day" . "09:00") ("start of day" . "09:00")
    ("breakfast" . "08:00") ("dinner" . "18:30")
    ("midnight" . "00:00") ("midday" . "12:00") ("noon" . "12:00")
    ("morning" . "09:00") ("afternoon" . "15:00") ("evening" . "19:00")
    ("tonight" . "21:00") ("night" . "22:00"))
  "Named parts of a day and the clock time each one means.
An alist of (PHRASE . \"HH:MM\"), longer phrases first where one
contains another.  \"before lunch\" is the moment lunch started: a
restore takes the arrangement recorded at or before its moment, so that
is what was open going into it."
  :type '(alist :key-type string :value-type string)
  :group 'cmacs-journal-restore)

(defcustom cmacs-journal-restore-lookback (* 7 86400)
  "How far before a moment to look for its checkpoint, in seconds."
  :type 'number
  :group 'cmacs-journal-restore)

(defcustom cmacs-journal-restore-app-timeout 30
  "Seconds to wait for a started application's window to appear.
The wait is a timer, not a block; when it runs out the item is reported
as not having appeared and nothing more is done about it."
  :type 'number
  :group 'cmacs-journal-restore)

(defcustom cmacs-journal-restore-poll-interval 0.5
  "Seconds between looks for the windows of started applications."
  :type 'number
  :group 'cmacs-journal-restore)

(defcustom cmacs-journal-restore-app-commands nil
  "How to start applications, overriding the recorded command line.
An alist of (APP-ID-REGEXP . COMMAND).  COMMAND is a string handed to
`gowl-spawn', or nil to say this application is never started by a
restore.  The first matching entry wins."
  :type '(alist :key-type regexp
                :value-type (choice (const :tag "Never start" nil) string))
  :group 'cmacs-journal-restore)

(defcustom cmacs-journal-restore-layout-names
  '(("[]=" . "tile") ("[M]" . "monocle") ("><>" . "float")
    ("|M|" . "centeredmaster") ("[@]" . "fibonacci") ("|||" . "columns")
    ("HHH" . "grid") ("TTT" . "bstack") ("[D]" . "deck"))
  "Layout symbols and the gowl layout each one names.
A checkpoint records the symbol a monitor showed, which is all the
compositor reports; this says which layout to ask for.  Two layouts can
share a symbol, so this is a best guess you can correct.  A symbol not
listed here is not restored, and the plan says so."
  :type '(alist :key-type string :value-type string)
  :group 'cmacs-journal-restore)

(defface cmacs-journal-restore-heading
  '((t :inherit bold))
  "Face of a section heading in the restore plan."
  :group 'cmacs-journal-restore)

(defface cmacs-journal-restore-reason
  '((t :inherit shadow))
  "Face of the reason beside an item in the restore plan."
  :group 'cmacs-journal-restore)

;;;; Time

(defconst cmacs-journal-restore--number-words
  '(("forty[ -]five" . "45") ("twenty[ -]five" . "25")
    ("one" . "1") ("two" . "2") ("three" . "3") ("four" . "4")
    ("five" . "5") ("six" . "6") ("seven" . "7") ("eight" . "8")
    ("nine" . "9") ("ten" . "10") ("eleven" . "11") ("twelve" . "12")
    ("fifteen" . "15") ("twenty" . "20") ("thirty" . "30")
    ("forty" . "40") ("fifty" . "50") ("sixty" . "60") ("ninety" . "90"))
  "Spoken numbers a time phrase may hold, and their digits.")

(defconst cmacs-journal-restore--weekdays
  '(("sunday" . 0) ("monday" . 1) ("tuesday" . 2) ("wednesday" . 3)
    ("thursday" . 4) ("friday" . 5) ("saturday" . 6)
    ("sun" . 0) ("mon" . 1) ("tues" . 2) ("tue" . 2) ("wed" . 3)
    ("thurs" . 4) ("thur" . 4) ("thu" . 4) ("fri" . 5) ("sat" . 6))
  "Weekday names and their `decoded-time-weekday' numbers.")

(defconst cmacs-journal-restore--filler
  '("at" "on" "in" "the" "around" "about" "this" "from" "of" "to" "by"
    "back" "just" "right" "sharp" "oclock" "o'clock" "since" "last"
    "before" "after" "early" "late" "roughly")
  "Words a time phrase may hold that change nothing.")

(defconst cmacs-journal-restore--units
  '(("sec" . 1) ("min" . 60) ("hour" . 3600) ("hr" . 3600)
    ("day" . 86400) ("week" . 604800))
  "Prefixes of unit names and their seconds.")

(defun cmacs-journal-restore--normalize (text)
  "TEXT lower-cased, without punctuation, with number words as digits."
  (let ((s (downcase (string-trim (or text "")))))
    (setq s (replace-regexp-in-string "[,!?;]" " " s))
    ;; "p.m." and "a.m." before the full stops go.
    (setq s (replace-regexp-in-string "\\b\\([ap]\\)\\.? ?m\\b\\.?" "\\1m" s))
    (setq s (replace-regexp-in-string "\\.\\(?: \\|\\'\\)" " " s))
    (pcase-dolist (`(,word . ,digits) cmacs-journal-restore--number-words)
      (setq s (replace-regexp-in-string (concat "\\b" word "\\b") digits s)))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " s))))

(defun cmacs-journal-restore--at (now day-offset hour minute)
  "The time DAY-OFFSET days from NOW's date at HOUR:MINUTE, local.
Built from calendar fields, so a day is a day across a clock change."
  (let ((d (decode-time now)))
    (float-time
     (encode-time (list 0 minute hour
                        (+ (decoded-time-day d) day-offset)
                        (decoded-time-month d) (decoded-time-year d)
                        nil -1 nil)))))

(defun cmacs-journal-restore--end-of-day (now day-offset)
  "The last second of the day DAY-OFFSET days from NOW, but not after NOW.
A day named without a time means how that day ended."
  (min now (+ (cmacs-journal-restore--at now day-offset 23 59) 59)))

(defun cmacs-journal-restore--iso (s now)
  "The time the ISO 8601 string S means, or nil if it is not one.
A date alone is the end of that day.  NOW caps it."
  (when (string-match
         "\\`\\([0-9]\\{4\\}\\)-\\([0-9][0-9]\\)-\\([0-9][0-9]\\)\\(?:[t ]\\([0-9][0-9]?\\):\\([0-9][0-9]\\)\\(?::\\([0-9][0-9]\\)\\)?\\)?\\(z\\|[+-][0-9][0-9]:?[0-9][0-9]\\)?\\'"
         s)
    (let ((year (string-to-number (match-string 1 s)))
          (month (string-to-number (match-string 2 s)))
          (day (string-to-number (match-string 3 s)))
          (hour (match-string 4 s))
          (minute (match-string 5 s))
          (second (match-string 6 s))
          (zone (match-string 7 s)))
      (cond
       ((and hour zone)
        (ignore-errors
          (float-time (parse-iso8601-time-string (upcase s)))))
       (hour
        (float-time
         (encode-time (list (if second (string-to-number second) 0)
                            (string-to-number minute)
                            (string-to-number hour)
                            day month year nil -1 nil))))
       (t
        ;; A day that has not begun is the future, and stays there for
        ;; the caller to refuse.
        (let ((start (float-time (encode-time (list 0 0 0 day month year
                                                    nil -1 nil))))
              (end (float-time (encode-time (list 59 59 23 day month year
                                                  nil -1 nil)))))
          (if (> start now) start (min now end))))))))

(defun cmacs-journal-restore--ago (s now)
  "The time a phrase S of the form \"N UNITS ago [CLOCK]\" means, or nil.
\"a\", \"an\", \"half an\", \"a couple of\", \"a few\" and \"and a half\"
are understood.  Days and weeks ago may be followed by a clock time."
  (when (string-match
         (concat "\\`\\(?:about \\|around \\|roughly \\)?"
                 "\\(half an?\\|a couple of\\|a couple\\|a few\\|an?\\|[0-9]+\\(?:\\.[0-9]+\\)?\\) "
                 "\\(sec\\|min\\|hour\\|hr\\|day\\|week\\)[a-z]*"
                 "\\( and a half\\)? ago\\(?: \\(.+\\)\\)?\\'")
         s)
    (let* ((quantity (match-string 1 s))
           (unit (cdr (assoc (match-string 2 s) cmacs-journal-restore--units)))
           (half (match-string 3 s))
           (rest (match-string 4 s))
           (n (+ (pcase quantity
                   ((or "half a" "half an") 0.5)
                   ((or "a couple of" "a couple") 2)
                   ("a few" 3)
                   ((or "a" "an") 1)
                   (_ (string-to-number quantity)))
                 (if half 0.5 0))))
      (cond
       ((null rest) (- now (* n unit)))
       ;; "2 days ago at 3pm": the day comes from the count, the time
       ;; from the rest.  Only whole days make sense there.
       ((and (>= unit 86400) (= n (floor n)))
        (let* ((offset (- (* (floor n) (/ unit 86400))))
               (clock (cmacs-journal-restore--clock rest)))
          (and clock
               (null (cmacs-journal-restore--leftover (cdr clock)))
               (cmacs-journal-restore--pick now offset (car clock) nil))))))))

(defun cmacs-journal-restore--clock (s)
  "Find a clock time in S: ((CANDIDATE...) . REST), or nil.
Each CANDIDATE is (HOUR MINUTE); a time without am or pm has two, and
the caller picks.  REST is S with the time cut out."
  (let ((case-fold-search t))
    (cond
     ;; A named part of the day.
     ((cl-some
       (lambda (part)
         (when (string-match (concat "\\b" (regexp-quote (car part)) "\\b") s)
           (let ((rest (concat (substring s 0 (match-beginning 0)) " "
                               (substring s (match-end 0))))
                 (hm (mapcar #'string-to-number
                             (split-string (cdr part) ":"))))
             (cons (list (list (car hm) (or (cadr hm) 0))) rest))))
       cmacs-journal-restore-day-parts))
     ;; Digits: 3pm, 3:30pm, 3 30 pm, 15:00, 3, 3 o'clock.
     ((string-match
       "\\b\\([0-9][0-9]?\\)\\(?:[:. ]\\([0-9][0-9]\\)\\)? ?\\([ap]m\\)?\\b"
       s)
      (let* ((hour (string-to-number (match-string 1 s)))
             (minute (if (match-string 2 s)
                         (string-to-number (match-string 2 s))
                       0))
             (meridiem (match-string 3 s))
             (rest (concat (substring s 0 (match-beginning 0)) " "
                           (substring s (match-end 0)))))
        (when (and (<= hour 23) (<= minute 59))
          (cons
           (cond
            ((equal meridiem "am") (list (list (% hour 12) minute)))
            ((equal meridiem "pm") (list (list (+ 12 (% hour 12)) minute)))
            ;; 13..23 and 0 can only be one thing.
            ((or (> hour 12) (= hour 0)) (list (list hour minute)))
            ;; 1..12 with nothing said: morning or afternoon.
            (t (list (list (% hour 12) minute)
                     (list (+ 12 (% hour 12)) minute))))
           rest)))))))

(defun cmacs-journal-restore--leftover (s)
  "The words of S that are not filler, or nil when all of it is."
  (cl-remove-if (lambda (word) (member word cmacs-journal-restore--filler))
                (split-string s "[ \t]+" t)))

(defun cmacs-journal-restore--day (s now)
  "Find a day in S: (OFFSET WEEKLY REST), or nil.
OFFSET is days from NOW's date, zero or negative.  WEEKLY is non-nil
for a weekday name, which may be moved a week further back."
  (let ((today (decoded-time-weekday (decode-time now))))
    (cond
     ((string-match "\\bday before yesterday\\b" s)
      (list -2 nil (replace-match " " t t s)))
     ((string-match "\\byesterday\\b" s)
      (list -1 nil (replace-match " " t t s)))
     ((string-match "\\btoday\\b" s)
      (list 0 nil (replace-match " " t t s)))
     ;; "last night" is a day and a time; leave the time for the clock.
     ((string-match "\\blast night\\b" s)
      (list -1 nil (replace-match " night " t t s)))
     ((string-match
       (concat "\\b\\(last \\)?"
               (regexp-opt (mapcar #'car cmacs-journal-restore--weekdays) t)
               "\\b")
       s)
      (let* ((last (match-string 1 s))
             (dow (cdr (assoc (match-string 2 s)
                              cmacs-journal-restore--weekdays)))
             (rest (replace-match " " t t s))
             (delta (mod (- today dow) 7)))
        ;; "last Tuesday" is never today.
        (when (and last (= delta 0)) (setq delta 7))
        (list (- delta) t rest))))))

(defun cmacs-journal-restore--pick (now offset candidates weekly)
  "The latest of CANDIDATES on the day OFFSET from NOW that is not after NOW.
CANDIDATES are (HOUR MINUTE) pairs.  When none has happened yet and
WEEKLY is non-nil, the same day a week earlier is used; otherwise nil."
  (let ((times (cl-remove-if
                (lambda (time) (> time now))
                (mapcar (lambda (c)
                          (cmacs-journal-restore--at now offset
                                                     (car c) (cadr c)))
                        candidates))))
    (cond (times (apply #'max times))
          (weekly (cmacs-journal-restore--pick now (- offset 7)
                                               candidates nil)))))

(defun cmacs-journal-restore--fallback (s now)
  "Read S with `parse-time-string', for dates like \"18 nov 15:00\"."
  (pcase-let ((`(,_sec ,minute ,hour ,day ,month ,year . ,_)
               (ignore-errors (parse-time-string s))))
    (when (and day month)
      (let* ((this-year (decoded-time-year (decode-time now)))
             ;; A date with no time is the end of that day.
             (build (lambda (y)
                      (float-time
                       (encode-time (list (if hour 0 59) (or minute 59)
                                          (or hour 23) day month y
                                          nil -1 nil)))))
             (begun (lambda (time) (<= (if hour time (- time 86399)) now)))
             (time (funcall build (or year this-year))))
        ;; A date with no year that has not come yet this year was last
        ;; year's.
        (when (and (null year) (not (funcall begun time)))
          (setq time (funcall build (1- this-year))))
        (and (funcall begun time) (min now time))))))

;;;###autoload
(defun cmacs-journal-restore-parse-time (text &optional now)
  "The past moment TEXT means, in seconds, or nil when it is not one.

Understood: \"now\"; \"N minutes ago\", \"an hour ago\", \"half an hour
ago\", \"an hour and a half ago\", \"2 days ago at 3pm\"; \"3pm\",
\"3:30\", \"15:00\", \"noon\"; \"this morning\", \"before lunch\",
\"last night\" (see `cmacs-journal-restore-day-parts'); \"today\",
\"yesterday\", \"the day before yesterday\" and weekday names, alone or
with a time (\"Tuesday 3pm\", \"3pm on Tuesday\", \"yesterday
afternoon\"); ISO 8601 dates and timestamps; and whatever
`parse-time-string' reads as a date.  Number words work, for speech.

Every ambiguity resolves to the most recent past moment.  A time with
no am or pm is whichever of the two happened last.  A time with no day
is today's if that has passed and yesterday's if not.  A weekday is the
most recent one, today included when the time has passed -- a weekday
alone on that weekday is last week's.  A day with no time is how that
day ended (so \"yesterday\" is the last arrangement of yesterday).  A
moment that is still in the future is nil.

NOW (default the journal's clock) is the present, in seconds."
  (let* ((now (float (or now (cmacs-journal--now))))
         (s (cmacs-journal-restore--normalize text))
         ;; "put me back where I was" and its like can precede it.
         (s (string-trim
             (replace-regexp-in-string
              "\\`\\(?:\\(?:as of\\|at\\|to\\|from\\|around\\|about\\) \\)+" ""
              s))))
    (cond
     ((string-empty-p s) nil)
     ((member s '("now" "just now" "right now")) now)
     ((let ((iso (cmacs-journal-restore--iso s now)))
        (and iso (<= iso now) iso)))
     ((string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]" s) nil)
     ((string-match-p "\\bago\\b" s) (cmacs-journal-restore--ago s now))
     (t
      (let* ((day (cmacs-journal-restore--day s now))
             (clock (cmacs-journal-restore--clock (if day (nth 2 day) s)))
             (rest (cond (clock (cdr clock)) (day (nth 2 day)) (t s))))
        (cond
         ((or (cmacs-journal-restore--leftover rest)
              (and (null day) (null clock)))
          (cmacs-journal-restore--fallback s now))
         ((and day clock)
          (cmacs-journal-restore--pick now (car day) (car clock)
                                       (nth 1 day)))
         (day
          ;; A weekday alone, on that weekday: the one a week ago.
          (cmacs-journal-restore--end-of-day
           now (if (and (nth 1 day) (= (car day) 0)) -7 (car day))))
         (t
          ;; No day: today's if it has happened, else yesterday's.
          (or (cmacs-journal-restore--pick now 0 (car clock) nil)
              (cmacs-journal-restore--pick now -1 (car clock) nil)))))))))

(defun cmacs-journal-restore--read-time (value)
  "The seconds VALUE means: a number, or a phrase.  Signals if neither."
  (cond
   ((numberp value) (float value))
   ((stringp value)
    (or (cmacs-journal-restore-parse-time value)
        (user-error "Cannot read \"%s\" as a moment in the past" value)))
   (t (user-error "Not a time: %S" value))))

;;;; What is running now

(defun cmacs-journal-restore--gowl-p ()
  "Non-nil when this Emacs is running the gowl compositor."
  (and (fboundp 'gowl-running-p)
       (fboundp 'gowl-list-clients)
       (ignore-errors (gowl-running-p))))

(defun cmacs-journal-restore--mask (tags)
  "The tag bitmask for the list of tag numbers TAGS (tag 1 is bit 0)."
  (let ((mask 0))
    (dolist (tag tags)
      (when (and (integerp tag) (>= tag 1) (<= tag 31))
        (setq mask (logior mask (ash 1 (1- tag))))))
    mask))

(defun cmacs-journal-restore--running ()
  "The windows gowl has now: plists of :obj :id :app :title :tags :pid.
This Emacs's own frames and windows embedded in it are left out.  A
live read for the person at the keyboard; none of it is stored."
  (when (cmacs-journal-restore--gowl-p)
    (let (out)
      (dolist (client (ignore-errors (gowl-list-clients)))
        (let* ((info (ignore-errors (gowl-client-info client)))
               (pid (and info (ignore-errors (gowl-client-pid client)))))
          (when (and info
                     (not (alist-get 'embedded info))
                     (not (and (integerp pid) (= pid (emacs-pid)))))
            (push (list :obj client
                        :id (alist-get 'id info)
                        :app (alist-get 'app-id info)
                        :title (alist-get 'title info)
                        :tags (cmacs-journal--tag-list (alist-get 'tags info))
                        :pid pid)
                  out))))
      (nreverse out))))

(defun cmacs-journal-restore--same-app-p (a b)
  "Non-nil when app ids A and B name the same application."
  (and (stringp a) (stringp b) (not (string-empty-p a))
       (string= (downcase a) (downcase b))))

(defun cmacs-journal-restore--match (entries running)
  "Pair recorded client ENTRIES with RUNNING windows: ((ENTRY . WINDOW)...).
WINDOW is nil for an entry nothing running answers to.  A window is
claimed once: the same app and title first, then the same app, so two
recorded terminals need two running terminals."
  (let ((free (copy-sequence running))
        (pairs (mapcar #'list entries)))
    (dolist (exact '(t nil))
      (dolist (pair pairs)
        (unless (cdr pair)
          (let* ((entry (car pair))
                 (hit (cl-find-if
                       (lambda (w)
                         (and (cmacs-journal-restore--same-app-p
                               (plist-get entry :app) (plist-get w :app))
                              (or (not exact)
                                  (equal (plist-get entry :title)
                                         (plist-get w :title)))))
                       free)))
            (when hit
              (setcdr pair hit)
              (setq free (delq hit free)))))))
    pairs))

(defun cmacs-journal-restore--command (entry)
  "The command that starts recorded client ENTRY, or nil.
`cmacs-journal-restore-app-commands' first, then what was recorded."
  (let* ((app (plist-get entry :app))
         (override (and (stringp app)
                        (cl-assoc-if (lambda (re) (string-match-p re app))
                                     cmacs-journal-restore-app-commands))))
    (if override
        (cdr override)
      (let ((command (plist-get entry :command)))
        (and (stringp command) (not (string-empty-p command))
             ;; A hashed field is a hash, not a command.
             (not (string-prefix-p "#" command))
             command)))))

;;;; The plan

(defvar cmacs-journal-restore--item-id 0
  "Counter giving each plan item its :id.")

(defun cmacs-journal-restore--item (section type label &rest props)
  "A plan item in SECTION of TYPE shown as LABEL, with PROPS.
Every item has every key `plist-put' may later set, so setting one
changes the item in place wherever it is referenced."
  (append (list :id (cl-incf cmacs-journal-restore--item-id)
                :section section :type type :label label)
          props
          (unless (plist-member props :enabled) (list :enabled t))
          (unless (plist-member props :toggle) (list :toggle t))
          (unless (plist-member props :reason) (list :reason nil))))

(defun cmacs-journal-restore--skip (label reason)
  "An entry for the plan's list of what cannot be restored."
  (cmacs-journal-restore--item 'skipped 'skip label
                               :enabled nil :toggle nil :reason reason))

(defun cmacs-journal-restore--withheld-p (value)
  "Non-nil when VALUE is what a `hash' filter leaves: not a real name."
  (and (stringp value) (string-prefix-p "#" value)))

(defun cmacs-journal-restore--leaves (tree)
  "The leaf entries of window TREE, in order."
  (if (plist-get tree :children)
      (mapcan #'cmacs-journal-restore--leaves
              (copy-sequence (plist-get tree :children)))
    (and tree (list tree))))

(defun cmacs-journal-restore--tags-label (tags)
  "TAGS, a list of numbers, as \"tag 2\" or \"tags 2, 3\"."
  (format "tag%s %s" (if (cdr tags) "s" "")
          (mapconcat #'number-to-string tags ", ")))

(defun cmacs-journal-restore--client-label (entry)
  "A short name for recorded client ENTRY."
  (let ((app (plist-get entry :app))
        (title (plist-get entry :title)))
    (concat (or app "?")
            (if (and (stringp title) (not (string-empty-p title)))
                (concat " -- " (truncate-string-to-width title 50 nil nil t))
              ""))))

(defun cmacs-journal-restore--file-buffer (file)
  "The live buffer visiting FILE, or nil.
A remote FILE is compared as a string against what buffers say they
visit: `get-file-buffer' expands its argument, and expanding a remote
name is Tramp's business, which a plan must not start."
  (if (file-remote-p file)
      (cl-find file (buffer-list) :test #'equal
               :key (lambda (b) (buffer-local-value 'buffer-file-name b)))
    (get-file-buffer (expand-file-name file))))

(defun cmacs-journal-restore--file-items (entries)
  "Plan items for the file ENTRIES (plists with :file and :line)."
  (let ((seen nil) (items nil))
    (dolist (entry entries)
      (let ((file (plist-get entry :file)))
        (when (and (stringp file) (not (member file seen)))
          (push file seen)
          (push
           (cond
            ((cmacs-journal-restore--withheld-p file)
             (cmacs-journal-restore--skip
              "a file" "its name was withheld by a journal filter"))
            ;; `file-remote-p' on a string opens no connection.
            ((file-remote-p file)
             (cmacs-journal-restore--item
              'files 'file file :file file :line (plist-get entry :line)
              :enabled nil
              :reason "remote: not touched unless you turn this on"))
            ((not (file-exists-p file))
             (cmacs-journal-restore--skip file "the file no longer exists"))
            (t
             (cmacs-journal-restore--item
              'files 'file file :file file :line (plist-get entry :line)
              :reason (and (cmacs-journal-restore--file-buffer file)
                           "already open"))))
           items))))
    (nreverse items)))

(defun cmacs-journal-restore--open-urls ()
  "The URLs gsurf buffers show right now."
  (when (fboundp 'cmacs-gsurf-get-uri)
    (delq nil
          (mapcar (lambda (buffer)
                    (and (eq (buffer-local-value 'major-mode buffer)
                             'cmacs-gsurf-mode)
                         (ignore-errors (cmacs-gsurf-get-uri buffer))))
                  (buffer-list)))))

(defun cmacs-journal-restore--url-items (entries)
  "Plan items for the page ENTRIES (plists with :url)."
  (let ((seen nil) (items nil)
        (open (cmacs-journal-restore--open-urls)))
    (dolist (entry entries)
      (let ((url (plist-get entry :url)))
        (when (and (stringp url) (not (member url seen)))
          (push url seen)
          (push
           (cond
            ;; Hashed, blanked or rewritten into something else.
            ((not (string-match-p "\\`[a-z][a-z0-9+.-]*:" url))
             (cmacs-journal-restore--skip
              "a page" "its address was withheld by a journal filter"))
            ((member url open)
             (cmacs-journal-restore--item
              'urls 'url url :url url :enabled nil :toggle nil
              :reason "already open"))
            (t
             (cmacs-journal-restore--item
              'urls 'url url :url url
              :reason
              (concat "loaded again, not resumed"
                      (and (plist-get entry :container)
                           (format "; was in container %s, opens in the default one"
                                   (plist-get entry :container)))))))
           items))))
    (nreverse items)))

(defun cmacs-journal-restore--app-items (clients running gowl)
  "Plan items for the recorded CLIENTS against the RUNNING windows.
GOWL is non-nil when the compositor is there to act on."
  (let* ((usable nil) (items nil))
    (dolist (entry clients)
      (let ((label (cmacs-journal-restore--client-label entry)))
        (cond
         ((or (null (plist-get entry :app))
              (cmacs-journal-restore--withheld-p (plist-get entry :app)))
          (push (cmacs-journal-restore--skip
                 "a window" "its application was withheld by a journal filter")
                items))
         ((not gowl)
          (push (cmacs-journal-restore--skip
                 label "gowl is not running here, so windows cannot be placed")
                items))
         ((plist-get entry :embedded)
          (push (cmacs-journal-restore--skip
                 label "it was embedded in an Emacs window")
                items))
         ((= 0 (cmacs-journal-restore--mask (plist-get entry :tags)))
          (push (cmacs-journal-restore--skip
                 label "it was on no tag (a scratchpad or hidden window)")
                items))
         (t (push entry usable)))))
    (pcase-dolist (`(,entry . ,window)
                   (cmacs-journal-restore--match (nreverse usable) running))
      (let ((label (cmacs-journal-restore--client-label entry))
            (tags (plist-get entry :tags))
            (command (cmacs-journal-restore--command entry)))
        (push
         (cond
          ((and window (equal (plist-get window :tags) tags))
           (cmacs-journal-restore--item
            'apps 'place label :client entry :enabled nil :toggle nil
            :reason (format "already running on %s"
                            (cmacs-journal-restore--tags-label tags))))
          (window
           (cmacs-journal-restore--item
            'apps 'move label :client entry
            :reason (format "running; moves to %s"
                            (cmacs-journal-restore--tags-label tags))))
          (command
           (cmacs-journal-restore--item
            'apps 'launch label :client entry :command command
            :reason (format "starts `%s' on %s; its own state is not restored"
                            (truncate-string-to-width command 60 nil nil t)
                            (cmacs-journal-restore--tags-label tags))))
          (t
           (cmacs-journal-restore--skip
            label "not running, and no command line was recorded for it")))
         items)))
    (nreverse items)))

(defun cmacs-journal-restore--layout-name (symbol)
  "The gowl layout the layout SYMBOL names, or nil."
  (cdr (assoc symbol cmacs-journal-restore-layout-names)))

(defun cmacs-journal-restore--monitor-names ()
  "The names of the monitors connected now."
  (delq nil
        (mapcar (lambda (m)
                  (alist-get 'name (ignore-errors (gowl-monitor-info m))))
                (ignore-errors (gowl-list-monitors)))))

(defun cmacs-journal-restore--layout-items (snapshot gowl)
  "Plan items for SNAPSHOT's window tree and monitors.
GOWL is non-nil when the compositor is there to act on."
  (let* ((frames (plist-get snapshot :frames))
         (frame (or (cl-find-if (lambda (f) (plist-get f :selected)) frames)
                    (car frames)))
         (tree (plist-get frame :tree))
         (items nil))
    (when tree
      (let ((count (length (cmacs-journal-restore--leaves tree))))
        (push (cmacs-journal-restore--item
               'layout 'windows
               (format "Emacs window layout (%d window%s)" count
                       (if (= count 1) "" "s"))
               :tree tree
               :reason "replaces this frame's windows")
              items)))
    (when (cdr frames)
      (push (cmacs-journal-restore--skip
             (format "%d other Emacs frame%s" (1- (length frames))
                     (if (= (length frames) 2) "" "s"))
             "frames are not recreated; their files are still reopened")
            items))
    (when gowl
      (let ((connected (cmacs-journal-restore--monitor-names))
            (monitors (plist-get snapshot :monitors)))
        ;; The focused monitor last: viewing tags selects the monitor.
        (dolist (monitor (append (cl-remove-if (lambda (m) (plist-get m :focused))
                                               monitors)
                                 (cl-remove-if-not (lambda (m) (plist-get m :focused))
                                                   monitors)))
          (let* ((name (plist-get monitor :name))
                 (tags (plist-get monitor :tags))
                 (symbol (plist-get monitor :layout))
                 (layout (and symbol
                              (cmacs-journal-restore--layout-name symbol))))
            (cond
             ((not (member name connected))
              (push (cmacs-journal-restore--skip
                     (format "monitor %s" name) "it is not connected now")
                    items))
             ((= 0 (cmacs-journal-restore--mask tags)))
             (t
              (push (cmacs-journal-restore--item
                     'layout 'view
                     (format "%s: view %s%s" name
                             (cmacs-journal-restore--tags-label tags)
                             (if layout (format ", layout %s" layout) ""))
                     :monitor name :tags tags :layout layout)
                    items)
              (when (and symbol (not layout))
                (push (cmacs-journal-restore--skip
                       (format "layout %s on %s" symbol name)
                       "no layout is named for that symbol in `cmacs-journal-restore-layout-names'")
                      items))))))))
    (nreverse items)))

(defun cmacs-journal-restore--focus-item (snapshot span)
  "The plan item that puts the focus back, or nil.
SPAN, the focus span around the moment, wins over SNAPSHOT: the
checkpoint is from a little before, the span is from then."
  (let* ((client (cl-find-if (lambda (c) (plist-get c :focused))
                             (plist-get snapshot :clients)))
         (kind (plist-get span :kind)))
    (cond
     ((and (eq kind 'focus)
           (stringp (plist-get span :app))
           (not (cmacs-journal-restore--withheld-p (plist-get span :app))))
      (cmacs-journal-restore--item
       'layout 'focus
       (format "Focus %s" (cmacs-journal-restore--client-label span))
       :client (list :app (plist-get span :app)
                     :title (plist-get span :title))))
     ((and (memq kind '(buffer url))
           (or (plist-get span :file) (plist-get span :url)
               (plist-get span :buffer)))
      (cmacs-journal-restore--item
       'layout 'focus
       (format "Select %s" (or (plist-get span :file) (plist-get span :url)
                               (plist-get span :buffer)))
       :buffer (list :file (plist-get span :file)
                     :url (plist-get span :url)
                     :buffer (plist-get span :buffer))))
     (client
      (cmacs-journal-restore--item
       'layout 'focus
       (format "Focus %s" (cmacs-journal-restore--client-label client))
       :client client)))))

(defun cmacs-journal-restore--checkpoint (events time)
  "The latest decodable checkpoint in EVENTS at or before TIME.
Returns (EVENT . SNAPSHOT), or nil."
  (let (found)
    (dolist (event events)
      (when (and (eq (plist-get event :kind) 'checkpoint)
                 (<= (plist-get event :time) time))
        (let ((snapshot (cmacs-journal-checkpoint-decode event)))
          (when (and snapshot
                     (or (null found)
                         (>= (plist-get event :time)
                             (plist-get (car found) :time))))
            (setq found (cons event snapshot))))))
    found))

(defun cmacs-journal-restore--focus-span (spans time)
  "The span in SPANS that had the focus at TIME, or the last before it."
  (let ((candidates (cl-remove-if-not
                     (lambda (e) (memq (plist-get e :kind) '(focus buffer url)))
                     spans)))
    (or (cl-find-if (lambda (e)
                      (and (<= (plist-get e :time) time)
                           (>= (or (plist-get e :end) 0) time)))
                    candidates :from-end t)
        (car (last (cl-remove-if (lambda (e) (> (plist-get e :time) time))
                                 candidates))))))

;;;###autoload
(defun cmacs-journal-restore-plan (time &optional running)
  "Work out what restoring the moment TIME would do.  Changes nothing.

TIME is in seconds.  The plan is built from the nearest checkpoint at or
before TIME (within `cmacs-journal-restore-lookback') and the spans the
journal has between that checkpoint and TIME; with no checkpoint, from
the spans within `cmacs-journal-at-window' before TIME alone.  RUNNING
is the list of windows to match against, default what gowl has now.

Returns a plist: :time, :checkpoint (its time, or nil), :items, :notes
\(strings for the reader) and :log (filled in by an execution).  Each
item is a plist with :section (`files', `urls', `apps', `layout' or
`skipped'), :type, :label, :enabled, :toggle and :reason.  An item in
`skipped' is something that cannot be restored, and :reason says why.

Reads the journal through `cmacs-journal-events', so an agent or a
remote caller gets an empty plan."
  (let* ((gowl (cmacs-journal-restore--gowl-p))
         (running (or running (and gowl (cmacs-journal-restore--running))))
         (events (cmacs-journal-events
                  (- time cmacs-journal-restore-lookback) time))
         (found (cmacs-journal-restore--checkpoint events time))
         (snapshot (cdr found))
         (from (if found
                   (plist-get (car found) :time)
                 (- time cmacs-journal-at-window)))
         ;; What had the focus between the checkpoint and the moment:
         ;; things opened after the arrangement was last written down.
         (spans (cl-remove-if
                 (lambda (e)
                   (or (eq (plist-get e :kind) 'checkpoint)
                       (< (or (plist-get e :end) (plist-get e :time)) from)))
                 events))
         (span (cmacs-journal-restore--focus-span spans time))
         (leaves (mapcan (lambda (frame)
                           (cmacs-journal-restore--leaves
                            (plist-get frame :tree)))
                         (copy-sequence (plist-get snapshot :frames))))
         (notes nil)
         (items nil))
    (setq items
          (append
           (cmacs-journal-restore--file-items
            (append leaves (plist-get snapshot :buffers) spans))
           (cmacs-journal-restore--url-items
            (append leaves (plist-get snapshot :urls) spans))
           (if found
               (cmacs-journal-restore--app-items
                (plist-get snapshot :clients) running
                (or gowl running))
             ;; Spans alone know a title, not how to start it.
             (let (seen out)
               (dolist (e spans)
                 (when (eq (plist-get e :kind) 'focus)
                   (let ((label (cmacs-journal-restore--client-label e)))
                     (unless (member label seen)
                       (push label seen)
                       (push (cmacs-journal-restore--skip
                              label
                              "no checkpoint: the journal has its title, not its command or place")
                             out)))))
               (nreverse out)))
           (cmacs-journal-restore--layout-items snapshot (or gowl running))
           (let ((focus (cmacs-journal-restore--focus-item snapshot span)))
             (and focus (list focus)))))
    ;; Non-file buffers that were in a window and are gone.
    (dolist (leaf leaves)
      (let ((name (plist-get leaf :buffer)))
        (when (and (stringp name)
                   (null (plist-get leaf :file))
                   (null (plist-get leaf :url))
                   (not (get-buffer name)))
          (setq items
                (append items
                        (list (cmacs-journal-restore--skip
                               name "that buffer is gone and visits no file")))))))
    (cond
     ((null found)
      (push "No checkpoint at or before that time: turn on `cmacs-journal-checkpoint-mode' to record arrangements.  This plan is from focus spans only."
            notes))
     ((null spans)
      (push "The journal recorded nothing between that checkpoint and the moment asked for; it may have been off."
            notes)))
    (push "Applications are started again; their own state (documents, tabs, unsaved work) is not restored."
          notes)
    (list :time time
          :checkpoint (and found (plist-get (car found) :time))
          :items items
          :notes notes
          :log nil)))

(defun cmacs-journal-restore--enabled (plan &optional section)
  "The enabled items of PLAN, in SECTION if given."
  (cl-remove-if-not
   (lambda (item)
     (and (plist-get item :enabled)
          (not (eq (plist-get item :section) 'skipped))
          (or (null section) (eq (plist-get item :section) section))))
   (plist-get plan :items)))

;;;; The plan buffer

(defconst cmacs-journal-restore--sections
  '((files . "Emacs buffers and files")
    (urls . "Pages")
    (apps . "Applications")
    (layout . "Layout and focus")
    (skipped . "Cannot be restored"))
  "The plan's sections, in the order they are shown and executed.")

(defvar-local cmacs-journal-restore--plan nil
  "The plan this buffer shows.")

(defvar-local cmacs-journal-restore--folded nil
  "Sections folded in this buffer.")

(defvar cmacs-journal-restore-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-journal-restore-toggle)
    (define-key map (kbd "SPC") #'cmacs-journal-restore-toggle)
    (define-key map "t" #'cmacs-journal-restore-toggle)
    (define-key map "a" #'cmacs-journal-restore-enable-section)
    (define-key map "u" #'cmacs-journal-restore-disable-section)
    (define-key map (kbd "TAB") #'cmacs-journal-restore-fold)
    (define-key map "n" #'next-line)
    (define-key map "p" #'previous-line)
    (define-key map "c" #'cmacs-journal-restore-confirm)
    (define-key map (kbd "C-c C-c") #'cmacs-journal-restore-confirm)
    (define-key map "g" #'cmacs-journal-restore-refresh)
    (define-key map "T" #'cmacs-journal-restore)
    map)
  "Keymap of the restore plan buffer.")

(define-derived-mode cmacs-journal-restore-mode special-mode "Restore"
  "The plan for putting a past moment back, before anything is done.

Each line is something a restore would do; \\[cmacs-journal-restore-toggle] turns one on or off,
\\[cmacs-journal-restore-enable-section] and \\[cmacs-journal-restore-disable-section] a whole section, \\[cmacs-journal-restore-fold] folds a section.  The last
section lists what cannot be put back, and why.

Nothing has been changed by showing this.  \\[cmacs-journal-restore-confirm] does it;
\\[quit-window] walks away."
  (setq truncate-lines t))

(defun cmacs-journal-restore--insert-item (item)
  "Insert the line for plan ITEM."
  (let ((start (point))
        (reason (plist-get item :reason)))
    (insert (cond ((eq (plist-get item :section) 'skipped) "   -  ")
                  ((not (plist-get item :toggle)) "  ( ) ")
                  ((plist-get item :enabled) "  [x] ")
                  (t "  [ ] "))
            (plist-get item :label))
    (when reason
      (insert "  " (propertize (concat "(" reason ")")
                               'face 'cmacs-journal-restore-reason)))
    (insert "\n")
    (put-text-property start (point) 'cmacs-journal-restore-item item)))

(defun cmacs-journal-restore--render ()
  "Redraw the plan buffer from its plan, keeping point's line."
  (let* ((plan cmacs-journal-restore--plan)
         (inhibit-read-only t)
         (line (line-number-at-pos))
         (column (current-column)))
    (erase-buffer)
    (insert (propertize
             (format "Put me back where I was: %s\n"
                     (format-time-string "%A %Y-%m-%d %H:%M"
                                         (plist-get plan :time)))
             'face 'cmacs-journal-restore-heading))
    (insert (if (plist-get plan :checkpoint)
                (format "Arrangement recorded %s (%s before).\n"
                        (format-time-string "%Y-%m-%d %H:%M"
                                            (plist-get plan :checkpoint))
                        (cmacs-journal--format-duration
                         (- (plist-get plan :time)
                            (plist-get plan :checkpoint))))
              "No arrangement was recorded for this moment.\n"))
    (dolist (note (plist-get plan :notes))
      (insert note "\n"))
    (insert (substitute-command-keys
             "\nNothing has been changed.  \\<cmacs-journal-restore-mode-map>\\[cmacs-journal-restore-confirm] restores what is ticked, \\[cmacs-journal-restore-toggle] ticks, \\[quit-window] leaves.\n"))
    (pcase-dolist (`(,section . ,title) cmacs-journal-restore--sections)
      (let ((items (cl-remove-if-not
                    (lambda (i) (eq (plist-get i :section) section))
                    (plist-get plan :items))))
        (when items
          (insert "\n")
          (let ((start (point))
                (folded (memq section cmacs-journal-restore--folded)))
            (insert (propertize
                     (format "%s %s (%d)\n" (if folded "+" "-") title
                             (length items))
                     'face 'cmacs-journal-restore-heading))
            (put-text-property start (point)
                               'cmacs-journal-restore-section section)
            (unless folded
              (dolist (item items)
                (cmacs-journal-restore--insert-item item)
                (put-text-property (line-beginning-position 0) (point)
                                   'cmacs-journal-restore-section section)))))))
    (when (plist-get plan :log)
      (insert "\n" (propertize "Result\n" 'face
                               'cmacs-journal-restore-heading))
      (dolist (entry (reverse (plist-get plan :log)))
        (insert (format "  %-7s %s\n" (car entry) (cdr entry)))))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column column)))

(defun cmacs-journal-restore--show (plan)
  "Show PLAN in the plan buffer and return the buffer."
  (let ((buffer (get-buffer-create "*cmacs-journal-restore*")))
    (with-current-buffer buffer
      (cmacs-journal-restore-mode)
      (setq cmacs-journal-restore--plan plan
            cmacs-journal-restore--folded nil)
      (cmacs-journal-restore--render)
      (goto-char (point-min)))
    (pop-to-buffer buffer)
    buffer))

(defun cmacs-journal-restore--refresh-buffer (plan)
  "Redraw the plan buffer if it still shows PLAN."
  (let ((buffer (get-buffer "*cmacs-journal-restore*")))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq cmacs-journal-restore--plan plan)
          (cmacs-journal-restore--render))))))

(defun cmacs-journal-restore-toggle ()
  "Turn the item at point on or off."
  (interactive nil cmacs-journal-restore-mode)
  (let ((item (get-text-property (point) 'cmacs-journal-restore-item)))
    (cond
     ((null item)
      (if (get-text-property (point) 'cmacs-journal-restore-section)
          (cmacs-journal-restore-fold)
        (user-error "Nothing to toggle here")))
     ((not (plist-get item :toggle))
      (user-error "%s" (or (plist-get item :reason) "This cannot be changed")))
     (t
      (plist-put item :enabled (not (plist-get item :enabled)))
      (cmacs-journal-restore--render)
      (forward-line 1)))))

(defun cmacs-journal-restore--set-section (on)
  "Turn every item that can be toggled in the section at point ON or off."
  (let ((section (get-text-property (point) 'cmacs-journal-restore-section)))
    (unless section (user-error "Not in a section"))
    (dolist (item (plist-get cmacs-journal-restore--plan :items))
      (when (and (eq (plist-get item :section) section)
                 (plist-get item :toggle))
        (plist-put item :enabled on)))
    (cmacs-journal-restore--render)))

(defun cmacs-journal-restore-enable-section ()
  "Tick every item in the section at point."
  (interactive nil cmacs-journal-restore-mode)
  (cmacs-journal-restore--set-section t))

(defun cmacs-journal-restore-disable-section ()
  "Untick every item in the section at point."
  (interactive nil cmacs-journal-restore-mode)
  (cmacs-journal-restore--set-section nil))

(defun cmacs-journal-restore-fold ()
  "Fold or unfold the section at point."
  (interactive nil cmacs-journal-restore-mode)
  (let ((section (get-text-property (point) 'cmacs-journal-restore-section)))
    (unless section (user-error "Not in a section"))
    (setq cmacs-journal-restore--folded
          (if (memq section cmacs-journal-restore--folded)
              (delq section cmacs-journal-restore--folded)
            (cons section cmacs-journal-restore--folded)))
    (cmacs-journal-restore--render)
    ;; Point's line may be gone; land on the section's heading.
    (goto-char (point-min))
    (let ((match (text-property-search-forward
                  'cmacs-journal-restore-section section #'eq)))
      (when match (goto-char (prop-match-beginning match))))))

(defun cmacs-journal-restore-refresh ()
  "Build the plan again for the same moment."
  (interactive nil cmacs-journal-restore-mode)
  (setq cmacs-journal-restore--plan
        (cmacs-journal-restore-plan
         (plist-get cmacs-journal-restore--plan :time)))
  (cmacs-journal-restore--render))

(defun cmacs-journal-restore--summary (plan)
  "One line saying what PLAN would do as it stands."
  (let ((parts nil))
    (pcase-dolist (`(,section ,one ,many)
                   '((layout "layout step" "layout steps")
                     (apps "application" "applications")
                     (urls "page" "pages")
                     (files "file" "files")))
      (let ((n (length (cmacs-journal-restore--enabled plan section))))
        (when (> n 0)
          (push (format "%d %s" n (if (= n 1) one many)) parts))))
    (if parts (string-join parts ", ") "nothing")))

(defun cmacs-journal-restore-confirm ()
  "Do what the plan in this buffer says, after one last question."
  (interactive nil cmacs-journal-restore-mode)
  (let ((plan cmacs-journal-restore--plan))
    (unless plan (user-error "No plan in this buffer"))
    (unless (cmacs-journal-restore--enabled plan)
      (user-error "Nothing is ticked"))
    (when (y-or-n-p (format "Restore %s from %s? "
                            (cmacs-journal-restore--summary plan)
                            (format-time-string "%a %H:%M"
                                                (plist-get plan :time))))
      (cmacs-journal-restore-execute plan))))

;;;; Doing it

(defun cmacs-journal-restore--note (plan status text)
  "Add TEXT with STATUS (\"ok\", \"skipped\", \"failed\", \"waiting\") to PLAN's log."
  (plist-put plan :log (cons (cons status text) (plist-get plan :log)))
  nil)

(defun cmacs-journal-restore--buffer-for (entry urls)
  "The live buffer recorded window or span ENTRY means, or nil.
By file, then by page (URLS maps the addresses opened by this restore
to their buffers), then by name."
  (let ((file (plist-get entry :file))
        (url (plist-get entry :url))
        (name (plist-get entry :buffer)))
    (or (and (stringp file)
             (not (cmacs-journal-restore--withheld-p file))
             (cmacs-journal-restore--file-buffer file))
        (and (stringp url)
             (or (cdr (assoc url urls))
                 (and (fboundp 'cmacs-gsurf-get-uri)
                      (cl-find-if
                       (lambda (b)
                         (and (eq (buffer-local-value 'major-mode b)
                                  'cmacs-gsurf-mode)
                              (equal (ignore-errors (cmacs-gsurf-get-uri b))
                                     url)))
                       (buffer-list)))))
        (and (stringp name) (null file) (null url) (get-buffer name)))))

(defun cmacs-journal-restore--goto-line (line)
  "Move point in the current buffer to LINE, counted from its start."
  (when (and (integerp line) (> line 0))
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- line))
      (point))))

(defun cmacs-journal-restore--open-files (plan)
  "Visit PLAN's ticked files.  A file that fails is reported and passed over."
  (dolist (item (cmacs-journal-restore--enabled plan 'files))
    (let ((file (plist-get item :file)))
      (condition-case err
          (cond
           ;; Ticked remote files are the user's explicit say-so; local
           ;; ones may have gone since the plan was drawn.
           ((and (not (file-remote-p file)) (not (file-exists-p file)))
            (cmacs-journal-restore--note plan "skipped"
                                         (format "%s: no longer exists" file)))
           (t
            (let* ((had (cmacs-journal-restore--file-buffer file))
                   (buffer (find-file-noselect file)))
              ;; Only a buffer this restore opened is moved to the
              ;; recorded line: one already open is where you left it.
              (unless had
                (with-current-buffer buffer
                  (cmacs-journal-restore--goto-line (plist-get item :line))))
              (cmacs-journal-restore--note
               plan "ok" (format "%s%s" file (if had " (was open)" ""))))))
        (error
         (cmacs-journal-restore--note
          plan "failed" (format "%s: %s" file (error-message-string err))))))))

(defun cmacs-journal-restore--gsurf-p ()
  "Non-nil when pages can be opened in gsurf buffers."
  (and (bound-and-true-p IS-CMACS-GSURF)
       (require 'cmacs-gsurf nil t)
       (fboundp 'cmacs-gsurf--open)
       (or (not (fboundp 'cmacs-gsurf-supported-p))
           (ignore-errors (cmacs-gsurf-supported-p)))))

(defun cmacs-journal-restore--open-urls-now (plan)
  "Open PLAN's ticked pages; return an alist of (URL . BUFFER) for gsurf ones."
  (let ((gsurf (cmacs-journal-restore--gsurf-p))
        (opened nil))
    (dolist (item (cmacs-journal-restore--enabled plan 'urls))
      (let ((url (plist-get item :url)))
        (condition-case err
            (if gsurf
                (let ((buffer (cmacs-gsurf--open url)))
                  (when (bufferp buffer) (push (cons url buffer) opened))
                  (cmacs-journal-restore--note plan "ok" url))
              (browse-url url)
              (cmacs-journal-restore--note
               plan "ok" (format "%s (in your browser)" url)))
          (error
           (cmacs-journal-restore--note
            plan "failed" (format "%s: %s" url (error-message-string err)))))))
    opened))

(defun cmacs-journal-restore--build-windows (window node urls state)
  "Make WINDOW show the tree NODE, splitting as NODE says.
URLS maps reopened pages to buffers.  STATE is a plist updated in place:
:selected gets the window recorded as selected, :missing the names of
buffers that could not be shown, :cut non-nil when a split did not fit."
  (let ((children (plist-get node :children)))
    (if (null children)
        (let ((buffer (cmacs-journal-restore--buffer-for node urls)))
          (if (null buffer)
              (plist-put state :missing
                         (cons (or (plist-get node :file) (plist-get node :url)
                                   (plist-get node :buffer) "?")
                               (plist-get state :missing)))
            (set-window-buffer window buffer)
            (let ((position (with-current-buffer buffer
                              (save-excursion
                                (cmacs-journal-restore--goto-line
                                 (plist-get node :line))))))
              (when position (set-window-point window position))))
          (when (plist-get node :selected)
            (plist-put state :selected window)))
      (let* ((horizontal (equal (plist-get node :split) "h"))
             (side (if horizontal 'right 'below))
             (windows (list window))
             (remaining (apply #'+ (mapcar (lambda (c)
                                             (or (plist-get c :size) 0))
                                           children)))
             (rest children))
        ;; Split off one child at a time: the window being split keeps
        ;; this child's share of what is left, the new one is the rest.
        (while (and (cdr rest) (not (plist-get state :cut)))
          (let* ((current (car windows))
                 (total (window-total-size current horizontal))
                 (share (if (> remaining 0)
                            (/ (or (plist-get (car rest) :size) 0)
                               (float remaining))
                          (/ 1.0 (length rest))))
                 (size (max 2 (min (- total 2) (round (* total share))))))
            (condition-case nil
                (push (split-window current size side) windows)
              ;; Too small for this many windows on this frame: keep
              ;; what fits and say so, rather than fail half-built.
              (error (plist-put state :cut t)))
            (setq remaining (- remaining (or (plist-get (car rest) :size) 0))
                  rest (cdr rest))))
        (setq windows (nreverse windows))
        (cl-loop for child in children
                 for w in windows
                 do (cmacs-journal-restore--build-windows w child urls
                                                          state))))))

(defun cmacs-journal-restore--restore-windows (plan urls)
  "Rebuild the Emacs window tree PLAN recorded, in the selected frame."
  (let ((item (car (cl-remove-if-not
                    (lambda (i) (eq (plist-get i :type) 'windows))
                    (cmacs-journal-restore--enabled plan 'layout)))))
    (when item
      (condition-case err
          (let* ((window (frame-first-window))
                 (state (list :selected nil :missing nil :cut nil)))
            ;; The plan buffer's own window is one of the windows being
            ;; replaced; that is what was asked for.
            (let ((ignore-window-parameters t))
              (delete-other-windows window))
            (set-window-dedicated-p window nil)
            (cmacs-journal-restore--build-windows
             window (plist-get item :tree) urls state)
            (when (window-live-p (plist-get state :selected))
              (select-window (plist-get state :selected)))
            (cmacs-journal-restore--note
             plan (if (or (plist-get state :missing) (plist-get state :cut))
                      "partly" "ok")
             (concat "Emacs window layout"
                     (and (plist-get state :cut)
                          "; this frame is too small for all of it")
                     (and (plist-get state :missing)
                          (format "; not shown: %s"
                                  (string-join
                                   (reverse (plist-get state :missing))
                                   ", "))))))
        (error
         (cmacs-journal-restore--note
          plan "failed" (format "Emacs window layout: %s"
                                (error-message-string err))))))))

;;;;; Applications

(defvar cmacs-journal-restore--pending nil
  "Started applications whose windows have not appeared yet.
Each is a plist: :plan :entry :pid :mask :known (window ids that existed
before it was started) :deadline :focus.")

(defvar cmacs-journal-restore--poll-timer nil
  "The timer looking for the windows of started applications.")

(defun cmacs-journal-restore--monitor-index (name)
  "The 0-based index of the monitor called NAME, or nil."
  (and (stringp name)
       (cl-position name (cmacs-journal-restore--monitor-names)
                    :test #'equal)))

(defun cmacs-journal-restore--place (window entry)
  "Put running WINDOW where recorded client ENTRY was.
Tags always; floating and geometry when the window floated."
  (let ((mask (cmacs-journal-restore--mask (plist-get entry :tags)))
        (obj (plist-get window :obj)))
    (when (and (> mask 0)
               (not (equal (plist-get window :tags) (plist-get entry :tags))))
      (gowl-set-tags obj mask))
    (when (plist-get entry :floating)
      (when (fboundp 'gowl-set-client-floating)
        (gowl-set-client-floating obj t))
      (pcase (plist-get entry :geometry)
        ((and `(,x ,y ,w ,h) (guard (fboundp 'gowl-client-set-geometry)))
         (when (and (integerp w) (integerp h) (> w 0) (> h 0))
           (gowl-client-set-geometry obj x y w h)))))))

(defun cmacs-journal-restore--poll ()
  "Timer: place the windows of started applications that have appeared.
Never signals and never waits: one look, then it returns."
  (condition-case nil
      (let ((now (float-time))
            (running (cmacs-journal-restore--running))
            (claimed nil)
            (still nil))
        (dolist (pending cmacs-journal-restore--pending)
          (let* ((entry (plist-get pending :entry))
                 (plan (plist-get pending :plan))
                 (label (cmacs-journal-restore--client-label entry))
                 (window
                  (cl-find-if
                   (lambda (w)
                     (and (not (memq (plist-get w :id)
                                     (plist-get pending :known)))
                          (not (memq (plist-get w :id) claimed))
                          (or (equal (plist-get w :pid)
                                     (plist-get pending :pid))
                              (cmacs-journal-restore--same-app-p
                               (plist-get w :app) (plist-get entry :app)))))
                   running)))
            (cond
             (window
              (push (plist-get window :id) claimed)
              (condition-case err
                  (progn
                    (cmacs-journal-restore--place window entry)
                    (when (plist-get pending :focus)
                      (gowl-focus-client (plist-get window :obj)))
                    (cmacs-journal-restore--note
                     plan "ok" (format "%s: its window appeared" label)))
                (error
                 (cmacs-journal-restore--note
                  plan "failed" (format "%s: %s" label
                                        (error-message-string err)))))
              (cmacs-journal-restore--refresh-buffer plan))
             ((> now (plist-get pending :deadline))
              (cmacs-journal-restore--note
               plan "failed"
               (format "%s: no window within %d seconds" label
                       (round cmacs-journal-restore-app-timeout)))
              (cmacs-journal-restore--refresh-buffer plan))
             (t (push pending still)))))
        (setq cmacs-journal-restore--pending (nreverse still)))
    (error (setq cmacs-journal-restore--pending nil)))
  (when (and (null cmacs-journal-restore--pending)
             cmacs-journal-restore--poll-timer)
    (cancel-timer cmacs-journal-restore--poll-timer)
    (setq cmacs-journal-restore--poll-timer nil)))

(defun cmacs-journal-restore--focus-entry-p (plan entry)
  "Non-nil when PLAN's ticked focus item is for recorded client ENTRY."
  (let* ((item (cl-find-if (lambda (i) (eq (plist-get i :type) 'focus))
                           (cmacs-journal-restore--enabled plan 'layout)))
         (target (plist-get item :client)))
    (and target
         (cmacs-journal-restore--same-app-p (plist-get target :app)
                                            (plist-get entry :app)))))

(defun cmacs-journal-restore--restore-apps (plan)
  "Move PLAN's ticked running windows and start its ticked missing ones."
  (let* ((items (cmacs-journal-restore--enabled plan 'apps))
         (running (cmacs-journal-restore--running))
         (known (mapcar (lambda (w) (plist-get w :id)) running))
         ;; Matched again now: windows open and close while a plan is
         ;; being read.
         (pairs (cmacs-journal-restore--match
                 (mapcar (lambda (i) (plist-get i :client)) items)
                 running)))
    (dolist (item items)
      (let* ((entry (plist-get item :client))
             (label (cmacs-journal-restore--client-label entry))
             (window (cdr (assq entry pairs)))
             (mask (cmacs-journal-restore--mask (plist-get entry :tags))))
        (condition-case err
            (cond
             (window
              (cmacs-journal-restore--place window entry)
              (cmacs-journal-restore--note
               plan "ok"
               (format "%s: on %s" label
                       (cmacs-journal-restore--tags-label
                        (plist-get entry :tags)))))
             ((not (eq (plist-get item :type) 'launch))
              (cmacs-journal-restore--note
               plan "skipped" (format "%s: no longer running" label)))
             (t
              (let ((pid (gowl-spawn (plist-get item :command))))
                ;; Before its window maps, so it never flashes on the
                ;; tag in view.
                (when (and (integerp pid) (fboundp 'gowl-pretag-pid))
                  (ignore-errors
                    (gowl-pretag-pid pid mask
                                     (cmacs-journal-restore--monitor-index
                                      (plist-get entry :monitor)))))
                (push (list :plan plan :entry entry :pid pid :mask mask
                            :known known
                            :deadline (+ (float-time)
                                         cmacs-journal-restore-app-timeout)
                            :focus (cmacs-journal-restore--focus-entry-p
                                    plan entry))
                      cmacs-journal-restore--pending)
                (cmacs-journal-restore--note
                 plan "started"
                 (format "%s: `%s'; waiting for its window" label
                         (plist-get item :command))))))
          (error
           (cmacs-journal-restore--note
            plan "failed" (format "%s: %s" label
                                  (error-message-string err)))))))
    (when (and cmacs-journal-restore--pending
               (null cmacs-journal-restore--poll-timer))
      (setq cmacs-journal-restore--poll-timer
            (run-with-timer cmacs-journal-restore-poll-interval
                            cmacs-journal-restore-poll-interval
                            #'cmacs-journal-restore--poll)))))

(defun cmacs-journal-restore--restore-views (plan)
  "View the tags and set the layouts PLAN recorded, monitor by monitor."
  (dolist (item (cmacs-journal-restore--enabled plan 'layout))
    (when (eq (plist-get item :type) 'view)
      (let ((name (plist-get item :monitor)))
        (condition-case err
            (let ((monitor (gowl-find-monitor name))
                  (mask (cmacs-journal-restore--mask (plist-get item :tags)))
                  (layout (plist-get item :layout)))
              (if (null monitor)
                  (cmacs-journal-restore--note
                   plan "skipped" (format "%s: not connected" name))
                (gowl-view-tags mask monitor)
                (when (and layout
                           (member layout (ignore-errors (gowl-list-layouts)))
                           (not (equal (cmacs-journal-restore--layout-name
                                        (ignore-errors (gowl-get-layout monitor)))
                                       layout)))
                  (gowl-set-layout layout monitor))
                (cmacs-journal-restore--note plan "ok"
                                             (plist-get item :label))))
          (error
           (cmacs-journal-restore--note
            plan "failed" (format "%s: %s" name
                                  (error-message-string err)))))))))

(defun cmacs-journal-restore--restore-focus (plan urls)
  "Put the focus where PLAN recorded it."
  (let ((item (cl-find-if (lambda (i) (eq (plist-get i :type) 'focus))
                          (cmacs-journal-restore--enabled plan 'layout))))
    (when item
      (condition-case err
          (cond
           ((plist-get item :client)
            (let* ((target (plist-get item :client))
                   (window (cdar (cmacs-journal-restore--match
                                  (list target)
                                  (cmacs-journal-restore--running)))))
              (cond
               (window
                (gowl-focus-client (plist-get window :obj))
                (cmacs-journal-restore--note plan "ok"
                                             (plist-get item :label)))
               ((cl-some (lambda (p) (plist-get p :focus))
                         cmacs-journal-restore--pending)
                (cmacs-journal-restore--note
                 plan "waiting"
                 (format "%s: when its window appears"
                         (plist-get item :label))))
               (t
                (cmacs-journal-restore--note
                 plan "skipped"
                 (format "%s: not running" (plist-get item :label)))))))
           ((plist-get item :buffer)
            (let ((buffer (cmacs-journal-restore--buffer-for
                           (plist-get item :buffer) urls)))
              (if (null buffer)
                  (cmacs-journal-restore--note
                   plan "skipped"
                   (format "%s: not open" (plist-get item :label)))
                (let ((window (get-buffer-window buffer)))
                  (if window (select-window window)
                    (switch-to-buffer buffer)))
                ;; Under gowl the keyboard may be with another window;
                ;; focusing Emacs's own client also shows its tag.
                (when (and (cmacs-journal-restore--gowl-p)
                           (fboundp 'gowl-find-client))
                  (let ((self (ignore-errors
                                (gowl-find-client (emacs-pid) 'pid))))
                    (when self (ignore-errors (gowl-focus-client self)))))
                (cmacs-journal-restore--note plan "ok"
                                             (plist-get item :label))))))
        (error
         (cmacs-journal-restore--note
          plan "failed" (format "%s: %s" (plist-get item :label)
                                (error-message-string err))))))))

;;;###autoload
(defun cmacs-journal-restore-execute (plan)
  "Carry out PLAN, a plan from `cmacs-journal-restore-plan'.

In order: visit the ticked files; open the ticked pages; rebuild the
Emacs window tree; move running windows to their tags and start the
applications that are not running; view each monitor's recorded tags and
layout; focus what was focused.  Each step that fails is written to the
plan's log and the rest go on.

Nothing here blocks.  A started application's window is placed (and
focused, if it was the focused one) when it appears, by a timer, or
reported as missing after `cmacs-journal-restore-app-timeout' seconds.

An application is started again; whatever was open inside it is not
restored.  Returns PLAN, whose :log now says what happened.

Refuses to run for an agent or a remote caller: a restore launches
programs, and that takes a person."
  (when (cmacs-journal-agent-context-p)
    (error "cmacs-journal-restore is for the person at the keyboard, not for agents or remote callers"))
  (plist-put plan :log nil)
  (cmacs-journal-restore--open-files plan)
  (let ((urls (cmacs-journal-restore--open-urls-now plan)))
    (cmacs-journal-restore--restore-windows plan urls)
    (when (cmacs-journal-restore--gowl-p)
      (cmacs-journal-restore--restore-apps plan)
      (cmacs-journal-restore--restore-views plan))
    (cmacs-journal-restore--restore-focus plan urls))
  (cmacs-journal-restore--refresh-buffer plan)
  (let ((failed (cl-count "failed" (plist-get plan :log)
                          :key #'car :test #'equal)))
    (message "cmacs-journal: restored %s%s%s (details in *cmacs-journal-restore*)"
             (format-time-string "%a %H:%M" (plist-get plan :time))
             (if (> failed 0) (format ", %d failed" failed) "")
             (if cmacs-journal-restore--pending
                 "; waiting for application windows" "")))
  plan)

;;;; Commands

;;;###autoload
(defun cmacs-journal-restore (time)
  "Show the plan for putting the moment TIME back.  Changes nothing.

TIME is a phrase `cmacs-journal-restore-parse-time' reads -- \"an hour
ago\", \"Tuesday 3pm\", \"before lunch\", \"yesterday\", an ISO
timestamp -- or a number of seconds.  The plan buffer lists the files,
pages, applications and layout of that moment, each of which can be
turned off, and what cannot be put back and why.  Nothing happens until
you confirm there.

Applications are started again; their internal state is not restored."
  (interactive
   (list (read-string
          "Put me back where I was (\"an hour ago\", \"Tuesday 3pm\", \"before lunch\"): ")))
  (when (cmacs-journal-agent-context-p)
    (error "cmacs-journal-restore is for the person at the keyboard, not for agents or remote callers"))
  (let* ((time (cmacs-journal-restore--read-time time))
         (plan (cmacs-journal-restore-plan time)))
    (cmacs-journal-restore--show plan)
    plan))

;;;###autoload
(defun cmacs-journal-restore-at-point ()
  "Show the restore plan for the journal line at point.
In `cmacs-journal-at' output that is the span on the line; in a report
by day, the end of the day in the row.  Anywhere else, asks."
  (interactive)
  (let ((time (or (get-text-property (point) 'cmacs-journal-time)
                  (save-excursion
                    (beginning-of-line)
                    (and (looking-at
                          "| *\\([0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\) *|")
                         (cmacs-journal-restore-parse-time
                          (match-string 1)))))))
    (if time
        (cmacs-journal-restore time)
      (call-interactively #'cmacs-journal-restore))))

;;;; Voice

;;;###autoload
(defun cmacs-journal-restore-voice (&optional phrase)
  "Voice command: show the restore plan for PHRASE and ask before acting.

The plan buffer comes up first, always.  Then the question is asked the
voice way -- answered by saying yes or no, or by a key -- and only a yes
runs it.  When voice confirmations are turned off
\(`cmacs-voice-confirm-destructive' nil) nothing is run from here at
all: the plan stays up for you to confirm by hand."
  (let* ((phrase (if (or (null phrase) (string-empty-p (string-trim phrase)))
                     "now"
                   phrase))
         (time (cmacs-journal-restore-parse-time phrase)))
    (if (null time)
        (if (fboundp 'cmacs-voice--say)
            (cmacs-voice--say "I could not read \"%s\" as a time" phrase)
          (message "Could not read \"%s\" as a time" phrase))
      (let ((plan (cmacs-journal-restore-plan time)))
        (cmacs-journal-restore--show plan)
        (cond
         ((null (cmacs-journal-restore--enabled plan))
          (message "Nothing to restore from %s"
                   (format-time-string "%A %H:%M" time)))
         ((and (fboundp 'cmacs-voice-confirm)
               (bound-and-true-p cmacs-voice-confirm-destructive))
          (cmacs-voice-confirm
           (format "Restore %s from %s?"
                   (cmacs-journal-restore--summary plan)
                   (format-time-string "%A %H:%M" time))
           (lambda () (cmacs-journal-restore-execute plan))))
         (t
          (message "%s"
                   (substitute-command-keys
                    "The plan is up; \\<cmacs-journal-restore-mode-map>\\[cmacs-journal-restore-confirm] in it restores."))))))))

;; The registration is an autoload form so that the phrases exist as
;; soon as voice commands do, whether or not this file is loaded yet;
;; `cmacs-journal-restore-voice' is autoloaded above.
;;;###autoload
(defun cmacs-journal-restore-register-voice ()
  "Register the restore phrases with the voice-command registry.
A function of its own so the autoloaded form below is a call to an
autoloaded function: loaddefs.el is compiled without
cmacs-voice-commands, and naming `cmacs-voice-define-command' there is
a \"not known to be defined\" warning in every build."
  (cmacs-voice-define-command
   "put me back\\(?: to\\)? where i was\\(?: \\(.+\\)\\)?"
   #'cmacs-journal-restore-voice
   "put me back where I was TIME" nil :context 'desktop)
  (cmacs-voice-define-command
   "restore my \\(?:desktop\\|session\\|workspace\\|work\\)\\(?: from\\)?\\(?: \\(.+\\)\\)?"
   #'cmacs-journal-restore-voice
   "restore my desktop from TIME" nil :context 'desktop))

;;;###autoload
(with-eval-after-load 'cmacs-voice-commands
  (cmacs-journal-restore-register-voice))

(provide 'cmacs-journal-restore)

;;; cmacs-journal-restore.el ends here
