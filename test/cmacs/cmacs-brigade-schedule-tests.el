;;; cmacs-brigade-schedule-tests.el --- Tests for scheduled runs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A wrong cron expression is silent.  Nothing errors, nothing warns, the
;; job simply never runs -- or runs seven times more often than intended
;; -- and you find out weeks later.  So the parser and the next-fire
;; search get the bulk of these tests, including the cases that are easy
;; to get subtly wrong: the day-of-month/day-of-week union, leap years,
;; step syntax, and 0-versus-7 for Sunday.
;;
;; Nothing here starts a real agent.  `cmacs-brigade-start-task' is
;; stubbed throughout: firing a schedule for real would spawn a provider
;; subprocess and spend money, which is not a thing a test suite should
;; do.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
;; Needed at compile time, not just at run time: the fixture rebinds
;; `cmacs-brigade-plan-directory', and without the defcustom in scope the
;; compiler makes it lexical while the loaded file makes it dynamic.
(require 'cmacs-brigade-plan nil 'noerror)
(require 'cmacs-brigade-schedule nil 'noerror)
(require 'cl-lib)

(defun cmacs-brigade-schedule-tests--available-p ()
  (featurep 'cmacs-brigade-schedule))

(defun cmacs-brigade-schedule-tests--at (y mo d h mi)
  (encode-time (list 0 mi h d mo y nil -1 nil)))

(defun cmacs-brigade-schedule-tests--fmt (time)
  (and time (format-time-string "%F %a %R" time)))

(defmacro cmacs-brigade-schedule-tests--with-tmp (&rest body)
  "Run BODY against throwaway schedule, log and state files."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "brigade-sched" t))
          (cmacs-brigade-plan-directory dir)
          (cmacs-brigade-state-dir dir)
          (cmacs-brigade-schedule-file (expand-file-name "s.org" dir))
          (cmacs-brigade-schedule-log-file (expand-file-name "runs.org" dir))
          (cmacs-brigade-schedule-state-file (expand-file-name "s.eld" dir))
          (cmacs-brigade-schedule--last nil)
          (cmacs-brigade-schedule--timer nil))
     (unwind-protect (progn ,@body)
       (dolist (f (directory-files dir t "\\.\\(org\\|eld\\)\\'"))
         (when-let* ((b (find-buffer-visiting f)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory dir t))))


;;;; Parsing

(ert-deftest cmacs-brigade-schedule-parses-plain-fields ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let ((s (cmacs-brigade-schedule-parse "30 4 1 6 2")))
    (should (equal (plist-get s :minute) '(30)))
    (should (equal (plist-get s :hour) '(4)))
    (should (equal (plist-get s :dom) '(1)))
    (should (equal (plist-get s :month) '(6)))
    (should (equal (plist-get s :dow) '(2)))))

(ert-deftest cmacs-brigade-schedule-parses-ranges-lists-and-steps ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0,30 * * * *")
                            :minute)
                 '(0 30)))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "*/15 * * * *")
                            :minute)
                 '(0 15 30 45)))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 9-17 * * *")
                            :hour)
                 '(9 10 11 12 13 14 15 16 17)))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 0-12/6 * * *")
                            :hour)
                 '(0 6 12)))
  ;; A bare value with a step means "from here on", as it does elsewhere.
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 5/6 * * *")
                            :hour)
                 '(5 11 17 23))))

(ert-deftest cmacs-brigade-schedule-parses-names ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 0 * jan,jul *")
                            :month)
                 '(1 7)))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 0 * * mon-fri")
                            :dow)
                 '(1 2 3 4 5)))
  ;; Case and long names both work.
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 0 * * SUNDAY")
                            :dow)
                 '(0))))

(ert-deftest cmacs-brigade-schedule-sunday-is-both-0-and-7 ()
  "Cron accepts either; a schedule written with 7 must not vanish."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 0 * * 7") :dow)
                 '(0)))
  (should (equal (plist-get (cmacs-brigade-schedule-parse "0 0 * * 0") :dow)
                 '(0))))

(ert-deftest cmacs-brigade-schedule-parses-macros ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (equal (cmacs-brigade-schedule-parse "@daily")
                 (cmacs-brigade-schedule-parse "0 0 * * *")))
  (should (equal (cmacs-brigade-schedule-parse "@hourly")
                 (cmacs-brigade-schedule-parse "0 * * * *")))
  (should (equal (cmacs-brigade-schedule-parse "@weekly")
                 (cmacs-brigade-schedule-parse "0 0 * * 0")))
  (should (eq 'every (plist-get (cmacs-brigade-schedule-parse "@every 30m")
                                :kind)))
  (should (= 1800 (plist-get (cmacs-brigade-schedule-parse "@every 30m")
                             :interval)))
  (should (= 7200 (plist-get (cmacs-brigade-schedule-parse "@every 2h")
                             :interval)))
  (should (eq 'reboot (plist-get (cmacs-brigade-schedule-parse "@reboot")
                                 :kind))))

(ert-deftest cmacs-brigade-schedule-question-mark-is-a-star ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (plist-get (cmacs-brigade-schedule-parse "0 0 ? * *") :dom-star)))

(ert-deftest cmacs-brigade-schedule-rejects-nonsense ()
  "Bad input must signal, not schedule something plausible-looking."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (dolist (bad '("" "   " "0 8 * *" "0 8 * * * *" "99 * * * *"
                 "* 25 * * *" "0 0 32 * *" "0 0 * 13 *" "@bogus"
                 "0 8 * * xyz" "0 0 * * mon-" "*/0 * * * *" "0 9-5 * * *"
                 ;; Truncating a name to three characters would take all
                 ;; of these for real ones.
                 "0 0 * * monkey" "0 0 * jan1 *" "0 0 * * mo"))
    (should-error (cmacs-brigade-schedule-parse bad)
                  :type 'cmacs-brigade-schedule-error))
  (should-not (cmacs-brigade-schedule-valid-p "nope"))
  (should (cmacs-brigade-schedule-valid-p "0 8 * * 1-5")))


;;;; Next fire

(ert-deftest cmacs-brigade-schedule-next-is-strictly-after ()
  "A schedule that just fired must not immediately fire again."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let* ((now (cmacs-brigade-schedule-tests--at 2026 8 4 8 0))
         (next (cmacs-brigade-schedule-next
                (cmacs-brigade-schedule-parse "0 8 * * *") now)))
    (should (equal (cmacs-brigade-schedule-tests--fmt next)
                   "2026-08-05 Wed 08:00"))))

(ert-deftest cmacs-brigade-schedule-next-weekday-skips-the-weekend ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  ;; Friday 2026-08-07, after the fire: next is Monday.
  (let* ((fri (cmacs-brigade-schedule-tests--at 2026 8 7 9 0))
         (next (cmacs-brigade-schedule-next
                (cmacs-brigade-schedule-parse "0 8 * * 1-5") fri)))
    (should (equal (cmacs-brigade-schedule-tests--fmt next)
                   "2026-08-10 Mon 08:00"))))

(ert-deftest cmacs-brigade-schedule-next-handles-leap-day ()
  "0 0 29 2 * must resolve to a real 29th of February.

The case that turns a naive search into an infinite loop."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let* ((start (cmacs-brigade-schedule-tests--at 2026 3 1 0 0))
         (next (cmacs-brigade-schedule-next
                (cmacs-brigade-schedule-parse "0 0 29 2 *") start)))
    (should (equal (cmacs-brigade-schedule-tests--fmt next)
                   "2028-02-29 Tue 00:00"))))

(ert-deftest cmacs-brigade-schedule-day-fields-are-a-union ()
  "With both day fields restricted, cron matches either.

Surprising, but it is what every other cron does, and quietly using
intersection instead would make \"1 * * 1 mon\" fire almost never."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let* ((spec (cmacs-brigade-schedule-parse "0 0 1 * mon"))
         (start (cmacs-brigade-schedule-tests--at 2026 8 26 0 0))
         (next (cmacs-brigade-schedule-next spec start)))
    ;; 2026-08-31 is a Monday, and comes before the 1st of September.
    (should (equal (cmacs-brigade-schedule-tests--fmt next)
                   "2026-08-31 Mon 00:00"))
    ;; ...and the 1st still matches even though it is a Tuesday.
    (should (equal (cmacs-brigade-schedule-tests--fmt
                    (cmacs-brigade-schedule-next spec next))
                   "2026-09-01 Tue 00:00"))))

(ert-deftest cmacs-brigade-schedule-restricted-dom-only ()
  "With day-of-week a star, only day-of-month gates."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let* ((spec (cmacs-brigade-schedule-parse "0 0 15 * *"))
         (start (cmacs-brigade-schedule-tests--at 2026 8 4 0 0)))
    (should (equal (cmacs-brigade-schedule-tests--fmt
                    (cmacs-brigade-schedule-next spec start))
                   "2026-08-15 Sat 00:00"))))

(ert-deftest cmacs-brigade-schedule-month-restriction ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let* ((spec (cmacs-brigade-schedule-parse "0 3 1 jan *"))
         (start (cmacs-brigade-schedule-tests--at 2026 8 4 0 0)))
    (should (equal (cmacs-brigade-schedule-tests--fmt
                    (cmacs-brigade-schedule-next spec start))
                   "2027-01-01 Fri 03:00"))))

(ert-deftest cmacs-brigade-schedule-next-runs-are-ordered-and-distinct ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let ((runs (cmacs-brigade-schedule-next-runs
               "*/15 * * * *" 5
               (cmacs-brigade-schedule-tests--at 2026 8 4 10 0))))
    (should (= 5 (length runs)))
    (should (equal (mapcar #'cmacs-brigade-schedule-tests--fmt runs)
                   '("2026-08-04 Tue 10:15" "2026-08-04 Tue 10:30"
                     "2026-08-04 Tue 10:45" "2026-08-04 Tue 11:00"
                     "2026-08-04 Tue 11:15")))))

(ert-deftest cmacs-brigade-schedule-every-is-relative ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let* ((start (cmacs-brigade-schedule-tests--at 2026 8 4 10 7))
         (next (cmacs-brigade-schedule-next
                (cmacs-brigade-schedule-parse "@every 45m") start)))
    (should (equal (cmacs-brigade-schedule-tests--fmt next)
                   "2026-08-04 Tue 10:52"))))

(ert-deftest cmacs-brigade-schedule-reboot-has-no-next ()
  "@reboot fires at startup and never on a clock."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should-not (cmacs-brigade-schedule-next
               (cmacs-brigade-schedule-parse "@reboot"))))


;;;; Description

(ert-deftest cmacs-brigade-schedule-describes-in-english ()
  "The description is what a human confirms against, so it must be right."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (string-match-p "08:00" (cmacs-brigade-schedule-describe
                                   "0 8 * * 1-5")))
  (should (string-match-p "Mon" (cmacs-brigade-schedule-describe
                                 "0 8 * * 1-5")))
  (should (string-match-p "every day" (cmacs-brigade-schedule-describe
                                       "@daily")))
  (should (string-match-p "every hour" (cmacs-brigade-schedule-describe
                                        "0 * * * *")))
  (should (string-match-p "30 minutes" (cmacs-brigade-schedule-describe
                                        "@every 30m")))
  (should (string-match-p "Jan" (cmacs-brigade-schedule-describe
                                 "0 0 1 jan *"))))

(ert-deftest cmacs-brigade-schedule-describes-invalid-without-signalling ()
  "A bad expression in a list must render, not take the buffer down."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (should (string-match-p "invalid" (cmacs-brigade-schedule-describe "nope"))))


;;;; Reading and writing org

(ert-deftest cmacs-brigade-schedule-add-and-read-round-trip ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let ((id (cmacs-brigade-schedule-add
               "Morning briefing" "0 8 * * 1-5" "Summarise the mail."
               :model "claude/claude-sonnet-4-6"
               :tools '(mail_search memory_search) :budget "0.25")))
      (let ((s (cmacs-brigade-schedule-get id)))
        (should s)
        ;; The title must not carry the tag: org tags cannot contain a
        ;; hyphen, so a hand-written one ends up in the heading text.
        (should (equal (plist-get s :title) "Morning briefing"))
        (should (equal (plist-get s :cron) "0 8 * * 1-5"))
        (should (equal (plist-get s :model) "claude/claude-sonnet-4-6"))
        (should (equal (plist-get s :tools) '(mail_search memory_search)))
        (should (equal (plist-get s :budget) "0.25"))
        (should (plist-get s :enabled))
        (should (string-match-p "Summarise" (plist-get s :prompt)))))))

(ert-deftest cmacs-brigade-schedule-ids-are-stable-across-reads ()
  "Re-reading must not mint a new id, or last-fire state is orphaned."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-schedule-add "A" "@daily" "x")
    (let ((first (mapcar (lambda (s) (plist-get s :id))
                         (cmacs-brigade-schedule-list)))
          (second (mapcar (lambda (s) (plist-get s :id))
                          (cmacs-brigade-schedule-list))))
      (should (equal first second)))))

(ert-deftest cmacs-brigade-schedule-rejects-invalid-cron-on-add ()
  "Refuse at write time; a bad schedule that lands in the file is silent."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (should-error (cmacs-brigade-schedule-add "Bad" "not a cron" "x")
                  :type 'cmacs-brigade-schedule-error)
    (should (null (cmacs-brigade-schedule-list)))))

(ert-deftest cmacs-brigade-schedule-enable-disable-and-delete ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let ((id (cmacs-brigade-schedule-add "A" "@daily" "x")))
      (should (plist-get (cmacs-brigade-schedule-get id) :enabled))
      (cmacs-brigade-schedule-set-enabled id nil)
      (should-not (plist-get (cmacs-brigade-schedule-get id) :enabled))
      ;; A disabled schedule has no next fire.
      (should-not (cmacs-brigade-schedule--due
                   (cmacs-brigade-schedule-get id)))
      (cmacs-brigade-schedule-set-enabled id t)
      (should (plist-get (cmacs-brigade-schedule-get id) :enabled))
      (should (cmacs-brigade-schedule-delete id))
      (should (null (cmacs-brigade-schedule-get id)))
      (should-not (cmacs-brigade-schedule-delete id)))))

(ert-deftest cmacs-brigade-schedule-delete-removes-only-its-own ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let ((a (cmacs-brigade-schedule-add "A" "@daily" "x"))
          (b (cmacs-brigade-schedule-add "B" "@hourly" "y")))
      (cmacs-brigade-schedule-delete a)
      (should (null (cmacs-brigade-schedule-get a)))
      (should (cmacs-brigade-schedule-get b))
      (should (= 1 (length (cmacs-brigade-schedule-list)))))))

(ert-deftest cmacs-brigade-schedule-headline-without-cron-is-not-one ()
  "A schedule file is still an org file; prose headings are not schedules."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-schedule-add "Real" "@daily" "x")
    (with-current-buffer (find-file-noselect (cmacs-brigade-schedule--file))
      (goto-char (point-max))
      (insert "\n* Just a note about these\n  Some prose.\n")
      (save-buffer))
    (should (= 1 (length (cmacs-brigade-schedule-list))))))


;;;; Derived agents

(ert-deftest cmacs-brigade-schedule-derives-an-agent-with-overrides ()
  "Model, tools and budget on the schedule beat the base agent's."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-register-agent
     :name 'sched-base :prompt "base prompt"
     :model "base/model" :tools '(a b) :budget-usd 9.0 :isolation 'none)
    (let* ((id (cmacs-brigade-schedule-add
                "S" "@daily" "do it"
                :agent "sched-base" :model "over/model"
                :tools '(c) :budget "0.5"))
           (s (cmacs-brigade-schedule-get id))
           (name (cmacs-brigade-schedule-ensure-agent s))
           (ag (cmacs-brigade-agent-get name)))
      (should (equal (plist-get ag :model) "over/model"))
      (should (equal (plist-get ag :tools) '(c)))
      (should (= (plist-get ag :budget-usd) 0.5))
      ;; The base agent's own prompt is what it stays; the schedule's
      ;; prompt is the task, not the system prompt.
      (should (equal (plist-get ag :prompt) "base prompt")))))

(ert-deftest cmacs-brigade-schedule-inherits-what-it-does-not-override ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-register-agent
     :name 'sched-base2 :prompt "p" :model "base/model"
     :tools '(a) :budget-usd 3.0 :isolation 'worktree)
    (let* ((id (cmacs-brigade-schedule-add "S" "@daily" "x"
                                           :agent "sched-base2"))
           (ag (cmacs-brigade-agent-get
                (cmacs-brigade-schedule-ensure-agent
                 (cmacs-brigade-schedule-get id)))))
      (should (equal (plist-get ag :model) "base/model"))
      (should (equal (plist-get ag :tools) '(a)))
      (should (eq (plist-get ag :isolation) 'worktree)))))

(ert-deftest cmacs-brigade-schedule-works-without-a-base-agent ()
  "A schedule that names no agent still runs, with a default prompt."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let* ((id (cmacs-brigade-schedule-add "S" "@daily" "x"
                                           :model "m/n"))
           (ag (cmacs-brigade-agent-get
                (cmacs-brigade-schedule-ensure-agent
                 (cmacs-brigade-schedule-get id)))))
      (should (equal (plist-get ag :model) "m/n"))
      ;; A definition of its own, with a usable system prompt, even
      ;; though the schedule named no base agent.
      (should (stringp (plist-get ag :prompt)))
      (should-not (string-empty-p (plist-get ag :prompt))))))

(ert-deftest cmacs-brigade-schedule-unknown-base-agent-is-an-error ()
  "Fail loudly at fire time rather than running with the wrong model."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let* ((id (cmacs-brigade-schedule-add "S" "@daily" "x"
                                           :agent "no-such-agent-here")))
      (should-error (cmacs-brigade-schedule-ensure-agent
                     (cmacs-brigade-schedule-get id))
                    :type 'cmacs-brigade-schedule-error))))


;;;; Firing

(ert-deftest cmacs-brigade-schedule-fire-creates-and-starts-a-task ()
  (skip-unless (and (cmacs-brigade-schedule-tests--available-p)
                    (fboundp 'cmacs-brigade-task-get)))
  (cmacs-brigade-schedule-tests--with-tmp
    (let ((started nil))
      (cl-letf (((symbol-function 'cmacs-brigade-start-task)
                 (lambda (id) (push id started) t)))
        (let* ((id (cmacs-brigade-schedule-add
                    "Nightly" "@daily" "Do the nightly thing."))
               (task (cmacs-brigade-schedule-fire
                      (cmacs-brigade-schedule-get id))))
          (should task)
          (should (equal started (list task)))
          (let* ((rec (cmacs-brigade-task-get task))
                 (agent (plist-get rec :agent)))
            (should rec)
            ;; Runs as a derived agent -- asserted through the registry
            ;; rather than by matching its generated name, which is an
            ;; internal detail.
            (should agent)
            (should (cmacs-brigade-agent-get (intern agent))))
          ;; and the fire is remembered, so a restart does not repeat it
          (should (cmacs-brigade-schedule-last-fire id)))))))

(ert-deftest cmacs-brigade-schedule-fire-runs-the-hook ()
  (skip-unless (and (cmacs-brigade-schedule-tests--available-p)
                    (fboundp 'cmacs-brigade-task-get)))
  (cmacs-brigade-schedule-tests--with-tmp
    (let (seen)
      (cl-letf (((symbol-function 'cmacs-brigade-start-task) #'ignore))
        (let ((cmacs-brigade-schedule-fired-functions
               (list (lambda (s task) (push (cons (plist-get s :title) task)
                                            seen)))))
          (cmacs-brigade-schedule-fire
           (cmacs-brigade-schedule-get
            (cmacs-brigade-schedule-add "H" "@daily" "x")))
          (should (= 1 (length seen)))
          (should (equal (caar seen) "H")))))))

(ert-deftest cmacs-brigade-schedule-fire-writes-the-prompt-into-the-task ()
  "The task body is the prompt; an empty one would run a blank agent."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cl-letf (((symbol-function 'cmacs-brigade-start-task) #'ignore))
      (cmacs-brigade-schedule-fire
       (cmacs-brigade-schedule-get
        (cmacs-brigade-schedule-add "H" "@daily" "Distinctive prompt text.")))
      (with-temp-buffer
        (insert-file-contents (cmacs-brigade-schedule--log-file))
        (should (string-match-p "Distinctive prompt text"
                                (buffer-string)))))))


;;;; State and catch-up

(ert-deftest cmacs-brigade-schedule-state-survives-a-reload ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-schedule--record-fire "abc")
    (setq cmacs-brigade-schedule--last nil)
    (cmacs-brigade-schedule--load-state)
    (should (cmacs-brigade-schedule-last-fire "abc"))))

(ert-deftest cmacs-brigade-schedule-catchup-respects-the-grace-window ()
  "A machine off for a month must not wake up and fire a month of backlog."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let ((fired 0))
      (cl-letf (((symbol-function 'cmacs-brigade-schedule-fire)
                 (lambda (_s) (setq fired (1+ fired)) "t1")))
        (let ((id (cmacs-brigade-schedule-add "A" "@hourly" "x"
                                              :catchup "run")))
          ;; Last fired a year ago: far outside the grace window.
          (setf (alist-get id cmacs-brigade-schedule--last nil nil #'equal)
                (- (float-time) (* 365 86400)))
          (cmacs-brigade-schedule--catch-up)
          (should (= fired 0))
          ;; Two hours ago, with an hourly schedule: inside the window.
          (setf (alist-get id cmacs-brigade-schedule--last nil nil #'equal)
                (- (float-time) 7200))
          (cmacs-brigade-schedule--catch-up)
          (should (= fired 1)))))))

(ert-deftest cmacs-brigade-schedule-catchup-skips-by-default ()
  "The default must not surprise anyone with a stale 8am briefing at 6pm."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (let ((fired 0))
      (cl-letf (((symbol-function 'cmacs-brigade-schedule-fire)
                 (lambda (_s) (setq fired (1+ fired)) "t1")))
        (let ((id (cmacs-brigade-schedule-add "A" "@hourly" "x")))
          (setf (alist-get id cmacs-brigade-schedule--last nil nil #'equal)
                (- (float-time) 7200))
          (cmacs-brigade-schedule--catch-up)
          (should (= fired 0)))))))


;;;; Timer

(ert-deftest cmacs-brigade-schedule-rearm-picks-the-earliest ()
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-schedule-add "Yearly" "0 0 1 1 *" "x")
    (cmacs-brigade-schedule-add "Soon" "@every 60s" "x")
    (let ((soonest (cmacs-brigade-schedule--rearm)))
      (unwind-protect
          (progn
            (should soonest)
            ;; The one-minute schedule, not the yearly one.
            (should (< (float-time (time-subtract soonest (current-time)))
                       120)))
        (when cmacs-brigade-schedule--timer
          (cancel-timer cmacs-brigade-schedule--timer))))))

(ert-deftest cmacs-brigade-schedule-broken-entry-does-not-stop-the-rest ()
  "One typo must not silently stop every other schedule from running."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (cmacs-brigade-schedule-tests--with-tmp
    (cmacs-brigade-schedule-add "Good" "@daily" "x")
    ;; Corrupt one by hand, the way a person editing the file would.
    (with-current-buffer (find-file-noselect (cmacs-brigade-schedule--file))
      (goto-char (point-max))
      (insert "\n* Broken\n  :PROPERTIES:\n  :CRON: 99 99 * * *\n  :END:\n  x\n")
      (save-buffer))
    (should (= 2 (length (cmacs-brigade-schedule-list))))
    (let ((soonest (cmacs-brigade-schedule--rearm)))
      (unwind-protect (should soonest)
        (when cmacs-brigade-schedule--timer
          (cancel-timer cmacs-brigade-schedule--timer))))))


;;;; Tools

(ert-deftest cmacs-brigade-schedule-publishes-its-tools ()
  "The model can only set these up if the tools are actually registered."
  (skip-unless (and (cmacs-brigade-schedule-tests--available-p)
                    (fboundp 'cmacs-brigade-deftool)))
  (let ((tools (cmacs-brigade-registry-list 'tool)))
    (dolist (n '(schedule-list schedule-preview schedule-create
                 schedule-set-enabled schedule-delete))
      (should (memq n tools)))))

(ert-deftest cmacs-brigade-schedule-mutating-tools-are-gated ()
  "Creating a recurring paid job must not happen because it sounded good.

schedule_create commits the user to spend on a timer; that is exactly the
shape of thing that has to be confirmed rather than merely logged."
  (skip-unless (and (cmacs-brigade-schedule-tests--available-p)
                    (fboundp 'cmacs-brigade-deftool)))
  (dolist (n '(schedule-create schedule-delete schedule-set-enabled))
    (let ((tool (cmacs-brigade-registry-get 'tool n)))
      (should tool)
      (should (cmacs-brigade-tool-destructive tool))
      (should (cmacs-brigade-tool-confirm tool))))
  ;; ...while the read-only ones are not gated, or they would be useless.
  (dolist (n '(schedule-list schedule-preview))
    (should-not (cmacs-brigade-tool-destructive
                 (cmacs-brigade-registry-get 'tool n)))))

(ert-deftest cmacs-brigade-schedule-parses-a-model-proposal ()
  "JSON arrives wrapped in prose and fences however firmly we ask."
  (skip-unless (cmacs-brigade-schedule-tests--available-p))
  (let ((spec (cmacs-brigade-schedule--parse-json
               "Sure! Here you go:\n```json\n{\"title\": \"T\", \
\"cron\": \"0 8 * * 1-5\", \"prompt\": \"p\"}\n```\nHope that helps.")))
    (should (equal (alist-get 'title spec) "T"))
    (should (equal (alist-get 'cron spec) "0 8 * * 1-5")))
  (should-not (cmacs-brigade-schedule--parse-json "no json at all")))

(provide 'cmacs-brigade-schedule-tests)

;;; cmacs-brigade-schedule-tests.el ends here
