;;; cmacs-journal-restore-tests.el --- ERT tests for journal checkpoints and restore  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Checkpoints and "put me back where I was" are Elisp over the journal,
;; so all of it runs here without a compositor:
;;
;;   * the time parser against a fixed present, as a table;
;;   * checkpoints in a private journal directory on a test clock, with
;;     the compositor played by stubs -- what the filters exclude must
;;     never reach the queue, an unusable rule set must record nothing,
;;     and `cmacs-journal-forget' must delete checkpoints;
;;   * plans built from synthetic events;
;;   * execution with every gowl and browser call stubbed and recorded.
;;
;; No test talks to a running gowl, starts a program or opens a page.
;; Stubs of C DEFUNs take &rest.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'warnings)
(require 'cmacs-journal)
(require 'cmacs-journal-report)
(require 'cmacs-journal-checkpoint)
(require 'cmacs-journal-restore)

(defvar cmacs-voice-confirm-destructive)
(defvar cmacs-voice-commands)

(defvar cmacs-journal-restore-tests--clock 1000000.0
  "The time the journal sees during a test.")

(defvar cmacs-journal-restore-tests--clients nil
  "The windows the stub compositor has: plists of
:id :app :title :tags (a bitmask) :pid :floating :embedded :geometry.")

(defvar cmacs-journal-restore-tests--monitors nil
  "The stub compositor's monitors: plists of :name :tags :layout :geometry.")

(defvar cmacs-journal-restore-tests--calls nil
  "Calls made to the stub compositor, newest first: (FUNCTION . ARGS).")

(defmacro cmacs-journal-restore-tests--with-journal (&rest body)
  "Run BODY with the journal recording in a temporary directory.
`root' is bound to the directory, for making files in."
  (declare (indent 0) (debug t))
  `(let* ((root (make-temp-file "cmacs-journal-restore-test" t))
          (cmacs-journal-directory (expand-file-name "state/journal" root))
          (cmacs-journal-filter-files nil)
          (cmacs-journal-default-filters nil)
          (cmacs-journal-filters nil)
          (cmacs-journal-min-span 2)
          (cmacs-journal-merge-gap 1.0)
          (cmacs-journal-retention-days nil)
          (cmacs-journal-expose-to-agents nil)
          (cmacs-journal-idle-threshold nil)
          (cmacs-journal-restore-tests--clock 1000000.0)
          (cmacs-journal-time-function
           (lambda () cmacs-journal-restore-tests--clock))
          (cmacs-journal--open nil)
          (cmacs-journal--queue nil)
          (cmacs-journal--paused nil)
          (cmacs-journal--locked nil)
          (cmacs-journal--pending nil)
          (cmacs-journal--external-focus nil)
          (cmacs-journal--focus-id nil)
          (cmacs-journal--in-tool-call nil)
          (cmacs-journal--file-cache (make-hash-table :test #'equal))
          (cmacs-journal-filter--rules nil)
          (cmacs-journal-filter--loaded nil)
          (cmacs-journal-filter--error nil)
          (cmacs-journal-filter-hash-key "test-key-0123456789abcdef0123456789")
          (cmacs-journal-filter-changed-functions nil)
          (cmacs-journal-mode t)
          (cmacs-journal-checkpoint--last-hash nil)
          (cmacs-journal-checkpoint--last-time nil)
          (cmacs-journal-checkpoint--commands (make-hash-table :test #'eql))
          (cmacs-journal-checkpoint-command-lines t)
          (cmacs-journal-checkpoint-max-age 3600)
          (cmacs-journal-restore--pending nil)
          (cmacs-journal-restore--poll-timer nil)
          (cmacs-journal-restore-app-commands nil)
          (cmacs-journal-restore-tests--clients nil)
          (cmacs-journal-restore-tests--monitors nil)
          (cmacs-journal-restore-tests--calls nil)
          (inhibit-interaction nil)
          (warning-minimum-log-level :emergency)
          (warning-minimum-level :emergency))
     (ignore root)
     (unwind-protect
         ;; No test opens a page: gsurf is "not built", and the browser
         ;; is a recorder.  A test that wants to see the URLs reads the
         ;; `browse-url' calls.
         (cl-letf (((symbol-function 'cmacs-journal-restore--gsurf-p)
                    (lambda (&rest _) nil))
                   ((symbol-function 'browse-url)
                    (cmacs-journal-restore-tests--record 'browse-url)))
           (cmacs-journal-filters-reload)
           ,@body)
       (when (timerp cmacs-journal-restore--poll-timer)
         (cancel-timer cmacs-journal-restore--poll-timer))
       (when (get-buffer "*cmacs-journal-restore*")
         (kill-buffer "*cmacs-journal-restore*"))
       (delete-directory root t))))

(defun cmacs-journal-restore-tests--client (object)
  "The stub client plist OBJECT (its :id) names."
  (or (cl-find object cmacs-journal-restore-tests--clients
               :key (lambda (c) (plist-get c :id)))
      (error "Not a GowlClient")))

(defun cmacs-journal-restore-tests--record (name)
  "A stub that records a call to NAME and returns t."
  (lambda (&rest args)
    (push (cons name args) cmacs-journal-restore-tests--calls)
    t))

(defmacro cmacs-journal-restore-tests--with-gowl (&rest body)
  "Run BODY with the compositor's DEFUNs replaced by stubs.
The stubs read `cmacs-journal-restore-tests--clients' and `--monitors';
a client or monitor object is its :id or :name."
  (declare (indent 0) (debug t))
  `(cl-letf*
       (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
        ((symbol-function 'gowl-list-clients)
         (lambda (&rest _)
           (mapcar (lambda (c) (plist-get c :id))
                   cmacs-journal-restore-tests--clients)))
        ((symbol-function 'gowl-client-info)
         (lambda (client &rest _)
           (let ((c (cmacs-journal-restore-tests--client client)))
             (list (cons 'id (plist-get c :id))
                   (cons 'title (or (plist-get c :title) ""))
                   (cons 'app-id (or (plist-get c :app) ""))
                   (cons 'tags (or (plist-get c :tags) 1))
                   (cons 'floating (plist-get c :floating))
                   (cons 'embedded (plist-get c :embedded))
                   (cons 'geometry (or (plist-get c :geometry)
                                       '(0 0 800 600)))))))
        ((symbol-function 'gowl-client-pid)
         (lambda (client &rest _)
           (plist-get (cmacs-journal-restore-tests--client client) :pid)))
        ((symbol-function 'gowl-focused-client)
         (lambda (&rest _)
           (plist-get (cl-find-if (lambda (c) (plist-get c :focused))
                                  cmacs-journal-restore-tests--clients)
                      :id)))
        ((symbol-function 'gowl-find-client) (lambda (&rest _) nil))
        ((symbol-function 'gowl-list-monitors)
         (lambda (&rest _)
           (mapcar (lambda (m) (plist-get m :name))
                   cmacs-journal-restore-tests--monitors)))
        ((symbol-function 'gowl-monitor-info)
         (lambda (&optional monitor &rest _)
           (let ((m (if monitor
                        (cl-find monitor cmacs-journal-restore-tests--monitors
                                 :key (lambda (m) (plist-get m :name))
                                 :test #'equal)
                      (car cmacs-journal-restore-tests--monitors))))
             (and m
                  (list (cons 'name (plist-get m :name))
                        (cons 'geometry (or (plist-get m :geometry)
                                            '(0 0 1920 1080)))
                        (cons 'tags (or (plist-get m :tags) 1))
                        (cons 'layout-symbol (plist-get m :layout)))))))
        ((symbol-function 'gowl-find-monitor)
         (lambda (name &rest _)
           (and (cl-find name cmacs-journal-restore-tests--monitors
                         :key (lambda (m) (plist-get m :name)) :test #'equal)
                name)))
        ((symbol-function 'gowl-list-layouts)
         (lambda (&rest _) '("tile" "monocle" "float")))
        ((symbol-function 'gowl-get-layout)
         (lambda (&optional monitor &rest _)
           (plist-get (cl-find monitor cmacs-journal-restore-tests--monitors
                               :key (lambda (m) (plist-get m :name))
                               :test #'equal)
                      :layout)))
        ((symbol-function 'gowl-spawn)
         (lambda (&rest args)
           (push (cons 'gowl-spawn args) cmacs-journal-restore-tests--calls)
           4242))
        ((symbol-function 'gowl-pretag-pid)
         (cmacs-journal-restore-tests--record 'gowl-pretag-pid))
        ((symbol-function 'gowl-set-tags)
         (cmacs-journal-restore-tests--record 'gowl-set-tags))
        ((symbol-function 'gowl-view-tags)
         (cmacs-journal-restore-tests--record 'gowl-view-tags))
        ((symbol-function 'gowl-set-layout)
         (cmacs-journal-restore-tests--record 'gowl-set-layout))
        ((symbol-function 'gowl-focus-client)
         (cmacs-journal-restore-tests--record 'gowl-focus-client))
        ((symbol-function 'gowl-set-client-floating)
         (cmacs-journal-restore-tests--record 'gowl-set-client-floating))
        ((symbol-function 'gowl-client-set-geometry)
         (cmacs-journal-restore-tests--record 'gowl-client-set-geometry)))
     ,@body))

(defun cmacs-journal-restore-tests--calls-to (name)
  "The argument lists of the recorded calls to NAME, oldest first."
  (nreverse (mapcar #'cdr (cl-remove-if-not
                           (lambda (c) (eq (car c) name))
                           cmacs-journal-restore-tests--calls))))

(defun cmacs-journal-restore-tests--advance (seconds)
  "Move the test clock on by SECONDS."
  (cl-incf cmacs-journal-restore-tests--clock seconds))

(defun cmacs-journal-restore-tests--queue-checkpoint (snapshot time)
  "Queue SNAPSHOT as a checkpoint event at TIME."
  (push (list :time time :end time :duration 0 :kind 'checkpoint
              :detail (cmacs-journal-checkpoint-encode snapshot))
        cmacs-journal--queue))

(defun cmacs-journal-restore-tests--queue-span (time duration &rest fields)
  "Queue a span starting at TIME lasting DURATION with FIELDS."
  (push (append (list :time time :end (+ time duration) :duration duration)
                fields)
        cmacs-journal--queue))

(defun cmacs-journal-restore-tests--items (plan section)
  "PLAN's items in SECTION."
  (cl-remove-if-not (lambda (i) (eq (plist-get i :section) section))
                    (plist-get plan :items)))

(defun cmacs-journal-restore-tests--item (plan label)
  "PLAN's item whose label contains LABEL."
  (cl-find-if (lambda (i) (string-search label (plist-get i :label)))
              (plist-get plan :items)))

;;;; The time parser

(defun cmacs-journal-restore-tests--local (year month day hour minute
                                                &optional second)
  "Local YEAR-MONTH-DAY HOUR:MINUTE:SECOND in seconds."
  (float-time (encode-time (list (or second 0) minute hour day month year
                                 nil -1 nil))))

(ert-deftest cmacs-journal-restore-test-parse-time-table ()
  "Every phrase resolves to the most recent past moment it can mean."
  ;; The present: Friday 2026-11-20 14:30, local time.
  (let* ((now (cmacs-journal-restore-tests--local 2026 11 20 14 30))
         (at (lambda (day hour minute &optional second)
               (cmacs-journal-restore-tests--local 2026 11 day hour minute
                                                   second))))
    (should (= 5 (decoded-time-weekday (decode-time now))))
    (pcase-dolist
        (`(,phrase ,expected)
         `(("now" ,now)
           ;; Relative.
           ("an hour ago" ,(- now 3600))
           ("1 hour ago" ,(- now 3600))
           ("two hours ago" ,(- now 7200))
           ("90 minutes ago" ,(- now 5400))
           ("10 min ago" ,(- now 600))
           ("half an hour ago" ,(- now 1800))
           ("an hour and a half ago" ,(- now 5400))
           ("a couple of hours ago" ,(- now 7200))
           ("about 20 minutes ago" ,(- now 1200))
           ("2 days ago" ,(- now 172800))
           ("2 days ago at 3pm" ,(funcall at 18 15 0))
           ("a week ago" ,(- now 604800))
           ;; A clock time alone: today's if it has passed.
           ("2pm" ,(funcall at 20 14 0))
           ("3pm" ,(funcall at 19 15 0))
           ("at 3:30 pm" ,(funcall at 19 15 30))
           ("15:00" ,(funcall at 19 15 0))
           ("09:15" ,(funcall at 20 9 15))
           ;; No am or pm: whichever happened last.
           ("3" ,(funcall at 20 3 0))
           ("9:15" ,(funcall at 20 9 15))
           ("2:15" ,(funcall at 20 14 15))
           ("12" ,(funcall at 20 12 0))
           ;; Parts of the day.
           ("noon" ,(funcall at 20 12 0))
           ("this morning" ,(funcall at 20 9 0))
           ("before lunch" ,(funcall at 20 12 0))
           ("after lunch" ,(funcall at 20 13 0))
           ("this evening" ,(funcall at 19 19 0))
           ("last night" ,(funcall at 19 22 0))
           ;; Days.
           ("today" ,now)
           ("yesterday" ,(funcall at 19 23 59 59))
           ("yesterday 3pm" ,(funcall at 19 15 0))
           ("yesterday at 3" ,(funcall at 19 15 0))
           ("yesterday afternoon" ,(funcall at 19 15 0))
           ("the day before yesterday" ,(funcall at 18 23 59 59))
           ;; Weekdays: the most recent one.
           ("Tuesday 3pm" ,(funcall at 17 15 0))
           ("3pm on tuesday" ,(funcall at 17 15 0))
           ("tue 15:00" ,(funcall at 17 15 0))
           ("Tuesday" ,(funcall at 17 23 59 59))
           ("monday morning" ,(funcall at 16 9 0))
           ;; Today is Friday: a time that has passed is today's, one
           ;; that has not is last week's, and the bare name is last
           ;; week's.
           ("friday 9am" ,(funcall at 20 9 0))
           ("friday 3pm" ,(funcall at 13 15 0))
           ("friday" ,(funcall at 13 23 59 59))
           ("last friday 9am" ,(funcall at 13 9 0))
           ;; ISO 8601.
           ("2026-11-18T15:00:00" ,(funcall at 18 15 0))
           ("2026-11-18 15:00" ,(funcall at 18 15 0))
           ("2026-11-18" ,(funcall at 18 23 59 59))
           ("2026-11-18T15:00:00Z"
            ,(float-time (encode-time '(0 0 15 18 11 2026 nil nil t))))
           ;; `parse-time-string' takes what is left.
           ("18 nov 15:00" ,(funcall at 18 15 0))
           ;; As a speech recogniser writes it.
           ("three thirty p.m." ,(funcall at 19 15 30))
           ("3 30 pm" ,(funcall at 19 15 30))
           ("Yesterday, at 3 p.m." ,(funcall at 19 15 0))
           ;; Not a past moment.
           ("" nil)
           ("banana" nil)
           ("tomorrow" nil)
           ("2027-01-01" nil)
           ("2026-11-20T18:00:00" nil)
           ("today 5pm" nil)
           ("3pm and some nonsense" nil)))
      (ert-info ((format "phrase: %S" phrase))
        (let ((got (cmacs-journal-restore-parse-time phrase now)))
          (if expected
              (progn (should (numberp got))
                     (should (= got expected)))
            (should (null got))))))))

(ert-deftest cmacs-journal-restore-test-parse-time-is-never-in-the-future ()
  (let ((now (cmacs-journal-restore-tests--local 2026 11 20 0 5)))
    (dolist (phrase '("3pm" "noon" "this morning" "friday" "friday 9am"
                      "tonight" "midnight" "23:59" "today" "3"))
      (ert-info ((format "phrase: %S" phrase))
        (let ((got (cmacs-journal-restore-parse-time phrase now)))
          (should (numberp got))
          (should (<= got now)))))))

(ert-deftest cmacs-journal-restore-test-day-parts-are-customizable ()
  (let ((now (cmacs-journal-restore-tests--local 2026 11 20 14 30))
        (cmacs-journal-restore-day-parts '(("standup" . "10:15"))))
    (should (= (cmacs-journal-restore-parse-time "standup" now)
               (cmacs-journal-restore-tests--local 2026 11 20 10 15)))
    (should (null (cmacs-journal-restore-parse-time "lunch" now)))))

;;;; Checkpoints

(ert-deftest cmacs-journal-restore-test-checkpoint-records-the-window-tree ()
  (cmacs-journal-restore-tests--with-journal
    (let ((a (generate-new-buffer "cp-left"))
          (b (generate-new-buffer "cp-right")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) a)
            (set-window-buffer (split-window nil nil 'right) b)
            (let* ((event (cmacs-journal-checkpoint-take))
                   (snapshot (cmacs-journal-checkpoint-decode event))
                   (tree (plist-get (car (plist-get snapshot :frames)) :tree)))
              (should (eq (plist-get event :kind) 'checkpoint))
              (should (memq event cmacs-journal--queue))
              (should (equal (plist-get tree :split) "h"))
              (should (equal (mapcar (lambda (c) (plist-get c :buffer))
                                     (plist-get tree :children))
                             '("cp-left" "cp-right")))
              (should (plist-get (car (plist-get tree :children)) :selected))
              ;; The shares of a split add up to the whole of it.
              (should (< (abs (- 1.0 (apply #'+ (mapcar
                                                 (lambda (c) (plist-get c :size))
                                                 (plist-get tree :children)))))
                         0.01))))
        (kill-buffer a)
        (kill-buffer b)))))

(ert-deftest cmacs-journal-restore-test-checkpoint-only-when-changed ()
  (cmacs-journal-restore-tests--with-journal
    (let ((a (generate-new-buffer "cp-a"))
          (b (generate-new-buffer "cp-b")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) a)
            (should (cmacs-journal-checkpoint-take))
            (cmacs-journal-restore-tests--advance 120)
            ;; Nothing changed: nothing written.
            (should (null (cmacs-journal-checkpoint-take)))
            ;; Point moving is not a change either.
            (with-current-buffer a (insert "one\ntwo\nthree\n"))
            (set-window-point (selected-window) (point-max))
            (should (null (cmacs-journal-checkpoint-take)))
            (should (= (length cmacs-journal--queue) 1))
            ;; A different buffer in the window is.
            (set-window-buffer (selected-window) b)
            (should (cmacs-journal-checkpoint-take))
            ;; And an unchanged one is written again once it is old.
            (cmacs-journal-restore-tests--advance 3601)
            (should (cmacs-journal-checkpoint-take))
            (should (= (length cmacs-journal--queue) 3)))
        (kill-buffer a)
        (kill-buffer b)))))

(ert-deftest cmacs-journal-restore-test-checkpoint-only-while-recording ()
  (cmacs-journal-restore-tests--with-journal
    (let ((cmacs-journal--paused 'user))
      (should (null (cmacs-journal-checkpoint-take t))))
    (let ((cmacs-journal--locked t))
      (should (null (cmacs-journal-checkpoint-take t))))
    (let ((cmacs-journal-mode nil))
      (should (null (cmacs-journal-checkpoint-take t))))
    (should (null cmacs-journal--queue))))

(ert-deftest cmacs-journal-restore-test-excluded-buffer-leaves-the-tree ()
  "An excluded window is absent, not blanked: its sibling takes the frame."
  (cmacs-journal-restore-tests--with-journal
    (let ((cmacs-journal-filters
           '((:match ((:buffer . "payroll")) :exclude t)))
          (a (generate-new-buffer "cp-kept"))
          (b (generate-new-buffer "cp-payroll-2026")))
      (unwind-protect
          (save-window-excursion
            (should (cmacs-journal-filters-reload))
            (delete-other-windows)
            (set-window-buffer (selected-window) a)
            (set-window-buffer (split-window nil nil 'below) b)
            (let* ((event (cmacs-journal-checkpoint-take))
                   (snapshot (cmacs-journal-checkpoint-decode event))
                   (tree (plist-get (car (plist-get snapshot :frames)) :tree)))
              (should event)
              (should-not (string-search "payroll" (plist-get event :detail)))
              ;; No split is left to say something else was there.
              (should (null (plist-get tree :children)))
              (should (equal (plist-get tree :buffer) "cp-kept"))
              (should-not (string-search "payroll"
                                         (prin1-to-string
                                          cmacs-journal--queue)))))
        (kill-buffer a)
        (kill-buffer b)))))

(ert-deftest cmacs-journal-restore-test-excluded-file-and-rewritten-names ()
  (cmacs-journal-restore-tests--with-journal
    (let* ((cmacs-journal-filters
            '((:match ((:file . "\\.gpg\\'")) :exclude t)
              (:match ((:file . "invoice")) :hash (:file :buffer))))
           (secret (find-file-noselect (expand-file-name "keys.gpg.txt.gpg" root)))
           (invoice (find-file-noselect (expand-file-name "invoice-7.txt" root)))
           (plain (find-file-noselect (expand-file-name "notes.txt" root))))
      (unwind-protect
          (save-window-excursion
            (should (cmacs-journal-filters-reload))
            (delete-other-windows)
            (set-window-buffer (selected-window) plain)
            (let* ((event (cmacs-journal-checkpoint-take))
                   (detail (plist-get event :detail))
                   (files (mapcar (lambda (b) (plist-get b :file))
                                  (plist-get (cmacs-journal-checkpoint-decode
                                              event)
                                             :buffers))))
              (should-not (string-search "keys.gpg" detail))
              (should-not (string-search "invoice" detail))
              (should (cl-some (lambda (f) (string-suffix-p "notes.txt" f))
                               files))
              ;; The hashed one is there as a hash, which no restore opens.
              (should (cl-some (lambda (f) (string-prefix-p "#" f)) files))))
        (dolist (buffer (list secret invoice plain))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

(ert-deftest cmacs-journal-restore-test-checkpoint-filters-each-client ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (let ((cmacs-journal-filters
             '((:match ((:app . "keepassxc")) :exclude t)
               (:match ((:title . "Private Browsing")) :exclude t)
               (:match ((:url . "bank\\.example")) :exclude t)
               (:match ((:app . "slack")) :drop (:title)))))
        (should (cmacs-journal-filters-reload))
        (setq cmacs-journal-restore-tests--monitors
              '((:name "DP-1" :tags 2 :layout "[]=" :geometry (0 0 1920 1080)))
              cmacs-journal-restore-tests--clients
              '((:id 1 :app "foot" :title "build" :tags 2 :pid 101 :focused t)
                (:id 2 :app "org.keepassxc.KeePassXC" :title "Passwords"
                 :tags 1 :pid 102)
                (:id 3 :app "firefox" :title "Money - Private Browsing"
                 :tags 1 :pid 103)
                (:id 4 :app "slack" :title "#secret-project" :tags 4 :pid 104
                 :floating t :geometry (10 20 640 480))
                (:id 5 :app "chromium" :title "Docs" :tags 1 :pid 105)))
        (cl-letf (((symbol-function 'cmacs-journal-checkpoint--read-cmdline)
                   (lambda (pid)
                     (pcase pid
                       (101 '("foot" "--title" "my build"))
                       (104 '("slack"))
                       (105 '("chromium" "https://bank.example/login"))
                       (_ '("something"))))))
          (let* ((event (cmacs-journal-checkpoint-take))
                 (detail (plist-get event :detail))
                 (snapshot (cmacs-journal-checkpoint-decode event))
                 (clients (plist-get snapshot :clients))
                 (by-app (lambda (app)
                           (cl-find app clients :test #'equal
                                    :key (lambda (c) (plist-get c :app))))))
            (should event)
            ;; Excluded windows are not in the queue in any form.
            (should-not (string-search "keepass" detail))
            (should-not (string-search "Passwords" detail))
            (should-not (string-search "Private" detail))
            (should-not (string-search "secret-project" detail))
            (should-not (string-search "bank.example" detail))
            (should (= (length clients) 3))
            ;; What is kept is what a restore needs.
            (let ((foot (funcall by-app "foot")))
              (should (equal (plist-get foot :tags) '(2)))
              (should (equal (plist-get foot :monitor) "DP-1"))
              (should (plist-get foot :focused))
              (should (equal (plist-get foot :command)
                             "foot --title my\\ build")))
            (let ((slack (funcall by-app "slack")))
              (should (null (plist-get slack :title)))
              (should (plist-get slack :floating))
              (should (equal (plist-get slack :geometry) '(10 20 640 480))))
            ;; A command naming an excluded page is withheld whole; the
            ;; window itself is still known.
            (let ((chromium (funcall by-app "chromium")))
              (should chromium)
              (should (null (plist-get chromium :command))))
            (should (equal (plist-get (car (plist-get snapshot :monitors))
                                      :tags)
                           '(2)))
            (should (equal (plist-get event :monitor) "DP-1"))))))))

(ert-deftest cmacs-journal-restore-test-checkpoint-fails-closed ()
  "With an unusable rule set there is no checkpoint, whoever asks."
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (setq cmacs-journal-restore-tests--clients
            '((:id 1 :app "foot" :title "build" :tags 1 :pid 101)))
      (let ((cmacs-journal-filters '((:match ((:app . "\\(unclosed")) :exclude t))))
        (should-not (cmacs-journal-filters-reload))
        (should-not (cmacs-journal-filter-ready-p))
        (should (null (cmacs-journal-checkpoint-take t)))
        (should (null (cmacs-journal-checkpoint-snapshot)))
        ;; Even past the recording check, every entry is refused.
        (cl-letf (((symbol-function 'cmacs-journal-recording-p)
                   (lambda (&rest _) t)))
          (should (null (cmacs-journal-checkpoint-take t))))
        (should (null (cmacs-journal-checkpoint--buffer-entry
                       (current-buffer))))
        (should (null cmacs-journal--queue))))))

(ert-deftest cmacs-journal-restore-test-a-kind-rule-turns-checkpoints-off ()
  (cmacs-journal-restore-tests--with-journal
    (let ((cmacs-journal-filters
           '((:match ((:kind . "\\`checkpoint\\'")) :exclude t))))
      (should (cmacs-journal-filters-reload))
      (should (null (cmacs-journal-checkpoint-take t)))
      (should (null cmacs-journal--queue)))))

(ert-deftest cmacs-journal-restore-test-tick-never-signals ()
  (cmacs-journal-restore-tests--with-journal
    (cl-letf (((symbol-function 'cmacs-journal-checkpoint-snapshot)
               (lambda (&rest _) (error "The compositor went away"))))
      (cmacs-journal-checkpoint--tick)
      (should (null cmacs-journal--queue)))))

(ert-deftest cmacs-journal-restore-test-forget-deletes-checkpoints ()
  (cmacs-journal-restore-tests--with-journal
    (let ((a (generate-new-buffer "cp-forget-me")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) a)
            ;; One written to its day file, one still queued.
            (should (cmacs-journal-checkpoint-take t))
            (cmacs-journal-flush)
            (cmacs-journal-restore-tests--advance 500)
            (should (cmacs-journal-checkpoint-take t))
            (let ((count (lambda ()
                           (cl-count 'checkpoint (cmacs-journal-events)
                                     :key (lambda (e) (plist-get e :kind))))))
              (should (= (funcall count) 2))
              ;; By time: the one in that stretch goes.
              (should (= (cmacs-journal-forget 999990.0 1000010.0) 1))
              (should (= (funcall count) 1))
              ;; By what it mentions: the other goes too, and with
              ;; nothing left in it the day file is deleted.
              (should (= (cmacs-journal-forget nil nil "cp-forget-me") 1))
              (should (= (funcall count) 0))
              (should (null cmacs-journal--queue))
              (should (null (cmacs-journal--day-files)))))
        (kill-buffer a)))))

(ert-deftest cmacs-journal-restore-test-retention-prunes-checkpoints ()
  (cmacs-journal-restore-tests--with-journal
    (should (cmacs-journal-checkpoint-take t))
    (cmacs-journal-flush)
    (should (= (length (cmacs-journal--day-files)) 1))
    (let ((cmacs-journal-retention-days 7))
      (cmacs-journal-restore-tests--advance (* 30 86400))
      (cmacs-journal--prune))
    (should (null (cmacs-journal--day-files)))
    (should (null (cmacs-journal-events)))))

(ert-deftest cmacs-journal-restore-test-checkpoints-are-activity-rows ()
  "The LQL source sees a checkpoint, and an agent sees none."
  (cmacs-journal-restore-tests--with-journal
    (should (cmacs-journal-checkpoint-take t))
    (should (cl-find 'checkpoint (cmacs-journal--lql-rows)
                     :key (lambda (r) (plist-get r :kind))))
    (let ((inhibit-interaction t))
      (should (null (cmacs-journal--lql-rows))))))

(ert-deftest cmacs-journal-restore-test-decode-refuses-what-is-not-a-checkpoint ()
  (should (null (cmacs-journal-checkpoint-decode
                 '(:kind focus :detail "{\"v\":1}"))))
  (should (null (cmacs-journal-checkpoint-decode
                 '(:kind checkpoint :detail "#a1b2c3d4e5f6"))))
  (should (null (cmacs-journal-checkpoint-decode
                 '(:kind checkpoint :detail "{\"v\":99}"))))
  (should (cmacs-journal-checkpoint-decode
           (list :kind 'checkpoint
                 :detail (cmacs-journal-checkpoint-encode
                          '(:buffers ((:buffer "x" :file "~/x"))))))))

;;;; Plans

(defun cmacs-journal-restore-tests--snapshot (root)
  "A hand-made snapshot whose files live under ROOT."
  (list
   :frames
   (list (list :selected t
               :tree (list :split "h" :size 1.0
                           :children
                           (list (list :buffer "main.c"
                                       :file (expand-file-name "main.c" root)
                                       :line 3 :size 0.6 :selected t)
                                 (list :buffer "*compilation*" :size 0.4)))))
   :buffers
   (list (list :buffer "main.c" :file (expand-file-name "main.c" root) :line 3)
         (list :buffer "gone.c" :file (expand-file-name "gone.c" root) :line 9)
         (list :buffer "far.c" :file "/ssh:build.example:/srv/far.c" :line 1)
         (list :buffer "#0123456789ab" :file "#ba9876543210" :line 1))
   :urls
   (list (list :url "https://example.org/docs" :title "Docs")
         (list :url "#ffffffffffff" :title "x"))
   :clients
   (list (list :app "foot" :title "build" :tags '(2) :monitor "DP-1"
               :command "foot")
         (list :app "firefox" :title "News" :tags '(3) :monitor "DP-1"
               :command "firefox" :focused t)
         (list :app "gimp" :title "poster.xcf" :tags '(4) :monitor "DP-1"
               :command "gimp poster.xcf" :floating t
               :geometry '(100 100 900 700))
         (list :app "mystery" :title "?" :tags '(5))
         (list :app "mpv" :title "talk.mkv" :tags '(1) :embedded t
               :command "mpv talk.mkv"))
   :monitors
   (list (list :name "DP-1" :tags '(2) :layout "[]=" :focused t)
         (list :name "HDMI-A-1" :tags '(1) :layout "[M]"))))

(defun cmacs-journal-restore-tests--running ()
  "Windows running now, as a plan is handed them."
  (list (list :obj 11 :id 11 :app "foot" :title "build" :tags '(2) :pid 501)
        (list :obj 12 :id 12 :app "Firefox" :title "Other" :tags '(1) :pid 502)))

(ert-deftest cmacs-journal-restore-test-plan-from-a-checkpoint ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (setq cmacs-journal-restore-tests--monitors
            '((:name "DP-1" :tags 1 :layout "[M]")))
      (with-temp-file (expand-file-name "main.c" root) (insert "a\nb\nc\nd\n"))
      (with-temp-file (expand-file-name "late.c" root) (insert "x\n"))
      (cmacs-journal-restore-tests--queue-checkpoint
       (cmacs-journal-restore-tests--snapshot root) 999000.0)
      ;; Opened after the checkpoint, before the moment.
      (cmacs-journal-restore-tests--queue-span
       999100.0 200 :kind 'buffer :app "emacs" :buffer "late.c"
       :file (expand-file-name "late.c" root))
      (cmacs-journal-restore-tests--queue-span
       999400.0 300 :kind 'focus :app "firefox" :title "News")
      (let* ((plan (cmacs-journal-restore-plan
                    999500.0 (cmacs-journal-restore-tests--running)))
             (item (lambda (label)
                     (cmacs-journal-restore-tests--item plan label))))
        (should (= (plist-get plan :checkpoint) 999000.0))
        ;; Files.
        (let ((main (funcall item "main.c")))
          (should (eq (plist-get main :section) 'files))
          (should (plist-get main :enabled))
          (should (= (plist-get main :line) 3)))
        (should (eq (plist-get (funcall item "late.c") :section) 'files))
        (let ((gone (funcall item "gone.c")))
          (should (eq (plist-get gone :section) 'skipped))
          (should (string-search "no longer exists" (plist-get gone :reason))))
        ;; Remote: there, off, and yours to turn on.
        (let ((far (funcall item "far.c")))
          (should (eq (plist-get far :section) 'files))
          (should-not (plist-get far :enabled))
          (should (plist-get far :toggle)))
        ;; Hashed names are listed as withheld and never as paths.
        (should-not (funcall item "#ba9876543210"))
        (should (cl-find-if (lambda (i) (string-search "withheld"
                                                       (or (plist-get i :reason) "")))
                            (cmacs-journal-restore-tests--items plan 'skipped)))
        ;; Pages.
        (should (equal (mapcar (lambda (i) (plist-get i :url))
                               (cmacs-journal-restore-tests--items plan 'urls))
                       '("https://example.org/docs")))
        ;; Applications.
        (let ((foot (funcall item "foot")))
          (should (eq (plist-get foot :type) 'place))
          (should-not (plist-get foot :enabled)))
        (let ((firefox (funcall item "firefox -- News")))
          (should (eq (plist-get firefox :type) 'move))
          (should (plist-get firefox :enabled)))
        (let ((gimp (funcall item "gimp")))
          (should (eq (plist-get gimp :type) 'launch))
          (should (equal (plist-get gimp :command) "gimp poster.xcf"))
          ;; The plan says, on the item, that its state is not restored.
          (should (string-search "not restored" (plist-get gimp :reason))))
        (let ((mystery (funcall item "mystery")))
          (should (eq (plist-get mystery :section) 'skipped))
          (should (string-search "command line" (plist-get mystery :reason))))
        (let ((mpv (funcall item "mpv")))
          (should (eq (plist-get mpv :section) 'skipped))
          (should (string-search "embedded" (plist-get mpv :reason))))
        ;; Layout: the tree, the connected monitor, not the missing one.
        (should (eq (plist-get (funcall item "Emacs window layout") :type)
                    'windows))
        (let ((view (funcall item "DP-1: view")))
          (should (equal (plist-get view :tags) '(2)))
          (should (equal (plist-get view :layout) "tile")))
        (should (eq (plist-get (funcall item "monitor HDMI-A-1") :section)
                    'skipped))
        (should (funcall item "*compilation*"))
        ;; Focus comes from the span around the moment.
        (let ((focus (funcall item "Focus firefox")))
          (should (eq (plist-get focus :type) 'focus)))
        ;; And the plan says what a restore is not.
        (should (cl-some (lambda (n) (string-search "not restored" n))
                         (plist-get plan :notes)))))))

(ert-deftest cmacs-journal-restore-test-plan-takes-the-checkpoint-at-or-before ()
  (cmacs-journal-restore-tests--with-journal
    (dolist (spec '((990000.0 . "old") (995000.0 . "nearest")
                    (999900.0 . "after")))
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :clients (list (list :app (cdr spec) :tags '(1)
                                  :command (cdr spec))))
       (car spec)))
    (let ((plan (cmacs-journal-restore-plan
                 999000.0 (list (list :obj 1 :id 1 :app "x" :tags '(1))))))
      (should (= (plist-get plan :checkpoint) 995000.0))
      (should (cmacs-journal-restore-tests--item plan "nearest"))
      (should-not (cmacs-journal-restore-tests--item plan "after"))
      (should-not (cmacs-journal-restore-tests--item plan "old")))
    ;; Exactly at a checkpoint's time is "at or before".
    (should (= (plist-get (cmacs-journal-restore-plan 999900.0) :checkpoint)
               999900.0))))

(ert-deftest cmacs-journal-restore-test-plan-without-a-checkpoint ()
  (cmacs-journal-restore-tests--with-journal
    (with-temp-file (expand-file-name "a.txt" root) (insert "a\n"))
    (cmacs-journal-restore-tests--queue-span
     999800.0 100 :kind 'buffer :app "emacs" :buffer "a.txt"
     :file (expand-file-name "a.txt" root))
    (cmacs-journal-restore-tests--queue-span
     999900.0 50 :kind 'focus :app "firefox" :title "News")
    (let ((plan (cmacs-journal-restore-plan 999960.0)))
      (should (null (plist-get plan :checkpoint)))
      (should (eq (plist-get (cmacs-journal-restore-tests--item plan "a.txt")
                             :section)
                  'files))
      ;; A title is not a command.
      (let ((firefox (cmacs-journal-restore-tests--item plan "firefox")))
        (should (eq (plist-get firefox :section) 'skipped))
        (should (string-search "no checkpoint" (plist-get firefox :reason))))
      (should (cl-some (lambda (n) (string-search "cmacs-journal-checkpoint-mode" n))
                       (plist-get plan :notes))))))

(ert-deftest cmacs-journal-restore-test-plan-is-empty-for-an-agent ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--queue-checkpoint
     (cmacs-journal-restore-tests--snapshot root) 999000.0)
    (let* ((inhibit-interaction t)
           (plan (cmacs-journal-restore-plan
                  999500.0 (cmacs-journal-restore-tests--running))))
      (should (null (plist-get plan :checkpoint)))
      (should (null (plist-get plan :items)))
      (should-error (cmacs-journal-restore-execute plan))
      (should-error (cmacs-journal-restore "an hour ago")))
    (let ((cmacs-journal--in-tool-call t))
      (should-error (cmacs-journal-restore-execute
                     (list :time 1.0 :items nil :log nil))))))

(ert-deftest cmacs-journal-restore-test-matching-claims-a-window-once ()
  (let* ((entries (list (list :app "foot" :title "a")
                        (list :app "foot" :title "b")
                        (list :app "foot" :title "c")))
         (running (list (list :id 1 :app "foot" :title "zzz")
                        (list :id 2 :app "foot" :title "b")))
         (pairs (cmacs-journal-restore--match entries running)))
    ;; The exact title wins its window; one is left for one other.
    (should (= (plist-get (cdr (nth 1 pairs)) :id) 2))
    (should (= (plist-get (cdr (nth 0 pairs)) :id) 1))
    (should (null (cdr (nth 2 pairs))))))

(ert-deftest cmacs-journal-restore-test-tag-masks ()
  (should (= (cmacs-journal-restore--mask '(1)) 1))
  (should (= (cmacs-journal-restore--mask '(2)) 2))
  (should (= (cmacs-journal-restore--mask '(1 3 9)) (logior 1 4 256)))
  (should (= (cmacs-journal-restore--mask nil) 0))
  (should (= (cmacs-journal-restore--mask '(0 "x")) 0)))

;;;; The plan buffer

(ert-deftest cmacs-journal-restore-test-plan-buffer-toggles ()
  (cmacs-journal-restore-tests--with-journal
    (with-temp-file (expand-file-name "main.c" root) (insert "a\n"))
    (cmacs-journal-restore-tests--queue-checkpoint
     (cmacs-journal-restore-tests--snapshot root) 999000.0)
    (save-window-excursion
      (let* ((plan (cmacs-journal-restore-plan
                    999500.0 (cmacs-journal-restore-tests--running)))
             (buffer (cmacs-journal-restore--show plan))
             (main (cmacs-journal-restore-tests--item plan "main.c")))
        (with-current-buffer buffer
          (should (derived-mode-p 'cmacs-journal-restore-mode))
          (should (string-search "Nothing has been changed" (buffer-string)))
          (should (string-search "Cannot be restored" (buffer-string)))
          (should (string-search "not restored" (buffer-string)))
          ;; Toggle the file off and on again.
          (goto-char (point-min))
          (should (search-forward "[x] " nil t))
          (should (eq (get-text-property (point) 'cmacs-journal-restore-item)
                      main))
          (cmacs-journal-restore-toggle)
          (should-not (plist-get main :enabled))
          (should (string-search "[ ] " (buffer-string)))
          ;; A whole section.
          (goto-char (point-min))
          (search-forward "- Applications")
          (cmacs-journal-restore-disable-section)
          (should (null (cmacs-journal-restore--enabled plan 'apps)))
          (cmacs-journal-restore-enable-section)
          (should (= (length (cmacs-journal-restore--enabled plan 'apps)) 2))
          ;; What cannot be restored cannot be ticked.
          (goto-char (point-min))
          (search-forward "gone.c")
          (should-error (cmacs-journal-restore-toggle) :type 'user-error)
          ;; Folding hides the items and keeps the heading.
          (goto-char (point-min))
          (search-forward "- Applications")
          (cmacs-journal-restore-fold)
          (should-not (string-search "gimp" (buffer-string)))
          (should (string-search "+ Applications" (buffer-string))))))))

(ert-deftest cmacs-journal-restore-test-nothing-runs-before-confirming ()
  "Showing a plan, and refusing it, change nothing."
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :clients (list (list :app "gimp" :tags '(4) :command "gimp")))
       999000.0)
      (cmacs-journal-restore-tests--advance -100)
      (save-window-excursion
        (let ((plan (cmacs-journal-restore 999500.0)))
          (should (cmacs-journal-restore-tests--item plan "gimp"))
          (should (null cmacs-journal-restore-tests--calls))
          (with-current-buffer "*cmacs-journal-restore*"
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
              (cmacs-journal-restore-confirm))
            (should (null cmacs-journal-restore-tests--calls))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
              (cmacs-journal-restore-confirm))
            (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-spawn)
                           '(("gimp"))))))))))

;;;; Execution

(ert-deftest cmacs-journal-restore-test-execute-files-and-windows ()
  (cmacs-journal-restore-tests--with-journal
    (with-temp-file (expand-file-name "main.c" root) (insert "a\nb\nc\nd\n"))
    (with-temp-file (expand-file-name "util.c" root) (insert "1\n2\n"))
    (let ((main (expand-file-name "main.c" root))
          (util (expand-file-name "util.c" root))
          (visited nil)
          (browsed nil))
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :frames
             (list (list :selected t
                         :tree (list :split "v" :size 1.0
                                     :children
                                     (list (list :buffer "main.c" :file main
                                                 :line 3 :size 0.5)
                                           (list :buffer "util.c" :file util
                                                 :line 2 :size 0.5
                                                 :selected t)))))
             :buffers (list (list :buffer "far.c"
                                  :file "/ssh:build.example:/srv/far.c"))
             :urls (list (list :url "https://example.org/docs")))
       999000.0)
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (cl-letf* ((real (symbol-function 'find-file-noselect))
                       ((symbol-function 'find-file-noselect)
                        (lambda (file &rest args)
                          (push file visited)
                          (when (file-remote-p file)
                            (error "A remote file was touched"))
                          (apply real file args)))
                       ((symbol-function 'browse-url)
                        (lambda (url &rest _) (push url browsed))))
              (let ((plan (cmacs-journal-restore-plan 999500.0)))
                (cmacs-journal-restore-execute plan)
                ;; Files: the local ones, never the remote one.
                (should (member main visited))
                (should (member util visited))
                (should-not (cl-some #'file-remote-p visited))
                ;; The page went to the browser, gsurf not being there.
                (should (equal browsed '("https://example.org/docs")))
                ;; The window tree: two windows, one above the other,
                ;; each at its line, the recorded one selected.
                (let ((windows (window-list nil 'no-minibuffer
                                            (frame-first-window))))
                  (should (= (length windows) 2))
                  (should (equal (mapcar (lambda (w)
                                           (buffer-file-name (window-buffer w)))
                                         windows)
                                 (list main util)))
                  (should (window-combination-p
                           (window-parent (car windows))))
                  (should (= (line-number-at-pos
                              (window-point (car windows)) t)
                             3))
                  (should (eq (selected-window) (cadr windows))))
                (should-not (cl-find "failed" (plist-get plan :log)
                                     :key #'car :test #'equal)))))
        (dolist (file (list main util))
          (let ((buffer (get-file-buffer file)))
            (when buffer (kill-buffer buffer))))))))

(ert-deftest cmacs-journal-restore-test-execute-skips-a-file-gone-since-the-plan ()
  (cmacs-journal-restore-tests--with-journal
    (let ((file (expand-file-name "brief.txt" root)))
      (with-temp-file file (insert "x\n"))
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :buffers (list (list :buffer "brief.txt" :file file))) 999000.0)
      (let ((plan (cmacs-journal-restore-plan 999500.0)))
        (should (plist-get (cmacs-journal-restore-tests--item plan "brief.txt")
                           :enabled))
        (delete-file file)
        (save-window-excursion (cmacs-journal-restore-execute plan))
        (should (null (get-file-buffer file)))
        (should (equal (caar (plist-get plan :log)) "skipped"))))))

(ert-deftest cmacs-journal-restore-test-execute-applications ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (setq cmacs-journal-restore-tests--monitors
            '((:name "HDMI-A-1" :tags 1 :layout "[]=")
              (:name "DP-1" :tags 1 :layout "[M]"))
            cmacs-journal-restore-tests--clients
            '((:id 11 :app "foot" :title "build" :tags 2 :pid 501)
              (:id 12 :app "firefox" :title "News" :tags 1 :pid 502)))
      (cmacs-journal-restore-tests--queue-checkpoint
       (cmacs-journal-restore-tests--snapshot root) 999000.0)
      (cmacs-journal-restore-tests--queue-span
       999400.0 300 :kind 'focus :app "gimp" :title "poster.xcf")
      (save-window-excursion
        (let ((plan (cmacs-journal-restore-plan 999500.0)))
          (cmacs-journal-restore-execute plan)
          ;; The running window on the wrong tag is moved: tag 3 is bit 2.
          (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-set-tags)
                         '((12 4))))
          ;; The missing one is started, and pre-tagged before it maps:
          ;; tag 4 is bit 3, DP-1 is monitor index 1.
          (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-spawn)
                         '(("gimp poster.xcf"))))
          (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-pretag-pid)
                         '((4242 8 1))))
          ;; Nothing was started for what could not be: no command, or
          ;; embedded, or already in place.
          (should (= (length cmacs-journal-restore--pending) 1))
          ;; The recorded tags are viewed, and the layout put back.
          ;; The focused monitor last, because viewing selects it.
          (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-view-tags)
                         '((1 "HDMI-A-1") (2 "DP-1"))))
          (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-set-layout)
                         '(("monocle" "HDMI-A-1") ("tile" "DP-1"))))
          ;; The page went to the browser stub, and only once.
          (should (equal (cmacs-journal-restore-tests--calls-to 'browse-url)
                         '(("https://example.org/docs"))))
          ;; The focused window is not there yet: nothing blocks, the
          ;; log says it is being waited for.
          (should (null (cmacs-journal-restore-tests--calls-to
                         'gowl-focus-client)))
          (should (cl-find "waiting" (plist-get plan :log)
                           :key #'car :test #'equal))
          (should (timerp cmacs-journal-restore--poll-timer))
          ;; A look that finds nothing new changes nothing.
          (cmacs-journal-restore--poll)
          (should (= (length cmacs-journal-restore--pending) 1))
          ;; Its window appears (under another pid: a wrapper started it).
          (setq cmacs-journal-restore-tests--clients
                (append cmacs-journal-restore-tests--clients
                        '((:id 13 :app "gimp" :title "GIMP" :tags 8
                           :pid 9000))))
          (cmacs-journal-restore--poll)
          (should (null cmacs-journal-restore--pending))
          (should (null cmacs-journal-restore--poll-timer))
          ;; It floated, so it floats again, where it was; and it had
          ;; the focus, so it gets it.
          (should (equal (cmacs-journal-restore-tests--calls-to
                          'gowl-set-client-floating)
                         '((13 t))))
          (should (equal (cmacs-journal-restore-tests--calls-to
                          'gowl-client-set-geometry)
                         '((13 100 100 900 700))))
          (should (equal (cmacs-journal-restore-tests--calls-to
                          'gowl-focus-client)
                         '((13))))
          (should (cl-find-if (lambda (e) (string-search "appeared" (cdr e)))
                              (plist-get plan :log))))))))

(ert-deftest cmacs-journal-restore-test-a-window-that-never-appears-times-out ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :clients (list (list :app "gimp" :tags '(4) :command "gimp")))
       999000.0)
      (save-window-excursion
        (let ((plan (cmacs-journal-restore-plan 999500.0)))
          (cmacs-journal-restore-execute plan)
          (should (= (length cmacs-journal-restore--pending) 1))
          ;; The deadline passes.
          (plist-put (car cmacs-journal-restore--pending) :deadline 0.0)
          (cmacs-journal-restore--poll)
          (should (null cmacs-journal-restore--pending))
          (should (null cmacs-journal-restore--poll-timer))
          (should (cl-find-if (lambda (e)
                                (and (equal (car e) "failed")
                                     (string-search "no window" (cdr e))))
                              (plist-get plan :log))))))))

(ert-deftest cmacs-journal-restore-test-unticked-items-are-not-run ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (setq cmacs-journal-restore-tests--monitors
            '((:name "DP-1" :tags 1 :layout "[]=")))
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :clients (list (list :app "gimp" :tags '(4) :command "gimp"))
             :monitors (list (list :name "DP-1" :tags '(4) :layout "[]="
                                   :focused t)))
       999000.0)
      (save-window-excursion
        (let ((plan (cmacs-journal-restore-plan 999500.0)))
          (dolist (item (plist-get plan :items))
            (plist-put item :enabled nil))
          (cmacs-journal-restore-execute plan)
          (should (null cmacs-journal-restore-tests--calls))
          (should (null cmacs-journal-restore--pending)))))))

(ert-deftest cmacs-journal-restore-test-a-failing-step-does-not-stop-the-rest ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (setq cmacs-journal-restore-tests--monitors
            '((:name "DP-1" :tags 1 :layout "[]=")))
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :clients (list (list :app "gimp" :tags '(4) :command "gimp"))
             :monitors (list (list :name "DP-1" :tags '(4) :layout "[]="
                                   :focused t)))
       999000.0)
      (cl-letf (((symbol-function 'gowl-spawn)
                 (lambda (&rest _) (error "No such program"))))
        (save-window-excursion
          (let ((plan (cmacs-journal-restore-plan 999500.0)))
            (cmacs-journal-restore-execute plan)
            (should (cl-find-if (lambda (e)
                                  (and (equal (car e) "failed")
                                       (string-search "No such program"
                                                      (cdr e))))
                                (plist-get plan :log)))
            (should (equal (cmacs-journal-restore-tests--calls-to
                            'gowl-view-tags)
                           '((8 "DP-1"))))))))))

(ert-deftest cmacs-journal-restore-test-app-commands-override ()
  (let ((cmacs-journal-restore-app-commands
         '(("\\`org\\.gimp" . "flatpak run org.gimp.GIMP")
           ("steam" . nil))))
    (should (equal (cmacs-journal-restore--command
                    '(:app "org.gimp.GIMP" :command "/app/bin/gimp"))
                   "flatpak run org.gimp.GIMP"))
    (should (null (cmacs-journal-restore--command
                   '(:app "steam" :command "steam"))))
    (should (equal (cmacs-journal-restore--command
                    '(:app "foot" :command "foot"))
                   "foot"))
    (should (null (cmacs-journal-restore--command
                   '(:app "foot" :command "#0123456789ab"))))))

;;;; The other doors

(ert-deftest cmacs-journal-restore-test-voice-shows-the-plan-and-asks ()
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--with-gowl
      (cmacs-journal-restore-tests--queue-checkpoint
       (list :clients (list (list :app "gimp" :tags '(4) :command "gimp")))
       (- cmacs-journal-restore-tests--clock 4000))
      (let ((asked nil) (cmacs-voice-confirm-destructive t))
        (cl-letf (((symbol-function 'cmacs-voice-confirm)
                   (lambda (prompt action &rest _)
                     (setq asked (cons prompt action))
                     'pending))
                  ((symbol-function 'cmacs-voice--say)
                   (lambda (&rest args) (apply #'format args))))
          (save-window-excursion
            (cmacs-journal-restore-voice "an hour ago")
            ;; The plan is up, the question is asked, nothing has run.
            (should (get-buffer "*cmacs-journal-restore*"))
            (should (string-search "1 application" (car asked)))
            (should (null cmacs-journal-restore-tests--calls))
            ;; "Yes."
            (funcall (cdr asked))
            (should (equal (cmacs-journal-restore-tests--calls-to 'gowl-spawn)
                           '(("gimp"))))
            ;; A phrase that is not a time asks nothing.
            (setq asked nil)
            (cmacs-journal-restore-voice "banana")
            (should (null asked)))
          ;; With voice confirmations off nothing is run from speech at
          ;; all: the plan waits for a hand.
          (setq asked nil
                cmacs-journal-restore-tests--calls nil
                cmacs-journal-restore--pending nil)
          (let ((cmacs-voice-confirm-destructive nil))
            (save-window-excursion
              (cmacs-journal-restore-voice "an hour ago")
              (should (null asked))
              (should (null cmacs-journal-restore-tests--calls)))))))))

(ert-deftest cmacs-journal-restore-test-voice-command-is-registered ()
  (skip-unless (require 'cmacs-voice-commands nil t))
  (let ((case-fold-search t)
        (hit nil))
    (dolist (entry cmacs-voice-commands)
      (when (and (null hit)
                 (string-match (concat "\\`\\(?:" (car entry) "\\)\\'")
                               "put me back where i was tuesday 3pm"))
        (setq hit (cons (nth 1 entry)
                        (match-string 1 "put me back where i was tuesday 3pm")))))
    (should (eq (car hit) 'cmacs-journal-restore-voice))
    (should (equal (cdr hit) "tuesday 3pm"))))

(ert-deftest cmacs-journal-restore-test-restore-to-here-from-the-journal ()
  "A line of `cmacs-journal-at' carries its moment and the key."
  (cmacs-journal-restore-tests--with-journal
    (cmacs-journal-restore-tests--queue-span
     999800.0 100 :kind 'focus :app "firefox" :title "News")
    (save-window-excursion
      (cmacs-journal-at 999850.0)
      (unwind-protect
          (with-current-buffer "*cmacs-journal-at*"
            (goto-char (point-min))
            (search-forward "firefox")
            (should (= (get-text-property (point) 'cmacs-journal-time)
                       999900.0))
            (should (eq (lookup-key (get-text-property (point) 'keymap) "R")
                        'cmacs-journal-restore-at-point))
            (let ((plan nil))
              (cl-letf (((symbol-function 'cmacs-journal-restore)
                         (lambda (time &rest _) (setq plan time))))
                (cmacs-journal-restore-at-point))
              (should (= plan 999900.0))))
        (kill-buffer "*cmacs-journal-at*")))))

(provide 'cmacs-journal-restore-tests)

;;; cmacs-journal-restore-tests.el ends here
