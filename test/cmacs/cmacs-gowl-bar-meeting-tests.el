;;; cmacs-gowl-bar-meeting-tests.el --- Tests for the gowl meeting-notes contract  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The cmacs half of gowl's `meeting-notes' widget:
;; `cmacs-gowl-bar-meeting-finish' returns at once, mixes, transcribes,
;; summarises and files, pushing meeting-notes.state/.result/.error/
;; .job-id as it goes.  gowl's tests/test-bar-meeting-notes.c holds the
;; widget side to the same names.
;;
;; No bar, no ffmpeg, no whisper, no model: `cmacs-gowl-bar-push-function'
;; records pushes, `make-process' records its plist so the test can run
;; the sentinel itself, and the transcription and ingest entry points are
;; stubbed with &rest (the ERT stub arity trap).
;;
;; What these catch:
;;
;;   - the finish call doing work before returning (under --gowl that is
;;     a frozen desktop);
;;   - an error signalled out of a sentinel, hook or timer instead of
;;     pushed (the widget would wait forever);
;;   - a push without the job id, or one carrying an earlier meeting's
;;     result;
;;   - a destination routed to the wrong place, or the second brain
;;     given the wrong type, title or tags;
;;   - an inbox note that breaks the notes repository's header
;;     convention, its file-name shape, or lets speech become a heading;
;;   - amix's default normalisation, and re-encoding one recording;
;;   - a WAV made and kept where Opus was asked for;
;;   - opening notes from the bar doing the work on the compositor's
;;     thread, or signalling on a file that is gone.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-bar-ai)
(require 'cmacs-gowl-bar-meeting)
;; Loaded now, not by the code under test: a `require' inside a test
;; would redefine the functions the test has just stubbed.
(require 'cmacs-transcribe nil t)
(require 'cmacs-secondbrain-ingest nil t)

(defvar cmacs-gowl-bar-meeting-tests--pushes nil
  "Every alist pushed, oldest first.")

(defun cmacs-gowl-bar-meeting-tests--states ()
  "The `meeting-notes.state' values pushed, oldest first."
  (delq nil (mapcar (lambda (alist)
                      (cdr (assoc "meeting-notes.state" alist)))
                    cmacs-gowl-bar-meeting-tests--pushes)))

(defun cmacs-gowl-bar-meeting-tests--last (key)
  "The last value pushed for meeting-notes.KEY."
  (cdr (assoc (concat "meeting-notes." key)
              (car (last cmacs-gowl-bar-meeting-tests--pushes)))))

(defmacro cmacs-gowl-bar-meeting-tests--with (&rest body)
  "Run BODY in a scratch session with every outside call stubbed.
Binds SESSION (a session directory holding 01-a.wav and 02-b.wav),
INBOX, PROCS (the plists `make-process' was called with, newest
first), TRANSCRIBED (jobs handed to transcription) and INGESTS (the
argument lists of `cmacs-secondbrain-ingest-run')."
  (declare (indent 0))
  `(let* ((root (make-temp-file "cmacs-meeting-test-" t))
          (session (expand-file-name "2026-10-16_14-05-09" root))
          (inbox (expand-file-name "inbox" root))
          (procs nil)
          (transcribed nil)
          (ingests nil)
          (exit-code 0)
          (cmacs-gowl-bar-meeting-tests--pushes nil)
          (cmacs-gowl-bar-push-function
           (lambda (alist)
             (setq cmacs-gowl-bar-meeting-tests--pushes
                   (append cmacs-gowl-bar-meeting-tests--pushes
                           (list alist)))))
          (cmacs-gowl-bar-meeting-inbox inbox)
          (cmacs-gowl-bar-meeting-directory root)
          (cmacs-gowl-bar-meeting-destination 'org-inbox)
          (cmacs-gowl-bar-meeting-para nil)
          (cmacs-gowl-bar-meeting--jobs nil)
          (user-full-name "Zach Podbielniak"))
     (ignore procs transcribed ingests exit-code)
     (make-directory session t)
     (dolist (f '("01-a.wav" "02-b.wav"))
       (with-temp-file (expand-file-name f session) (insert "RIFF....")))
     (unwind-protect
         (cl-letf (((symbol-function 'make-process)
                    (lambda (&rest plist) (push plist procs) 'fake-proc))
                   ((symbol-function 'process-status)
                    (lambda (&rest _) 'exit))
                   ((symbol-function 'process-exit-status)
                    (lambda (&rest _) exit-code))
                   ((symbol-function 'cmacs-gowl-bar-meeting--transcribe)
                    (lambda (job &rest _)
                      (push job transcribed)
                      (cmacs-gowl-bar-meeting--push job "transcribing")))
                   ((symbol-function 'cmacs-secondbrain-ingest-run)
                    (lambda (&rest args) (push args ingests) (list 'sbi))))
           ,@body)
       (delete-directory root t))))

(defun cmacs-gowl-bar-meeting-tests--finish (session &optional dest title)
  "Call the finish entry point for SESSION; return the job it made."
  (should (eq t (cmacs-gowl-bar-meeting-finish
                 "meeting-notes" "mn-7-abc" session
                 (list "01-a.wav" "02-b.wav") title dest)))
  (car cmacs-gowl-bar-meeting--jobs))

(defun cmacs-gowl-bar-meeting-tests--run-sentinel (plist)
  "Run the sentinel `make-process' was given in PLIST."
  (funcall (plist-get plist :sentinel) 'fake-proc "finished\n"))

(defun cmacs-gowl-bar-meeting-tests--transcribe-and-summarise (job)
  "Fire JOB's two transcribe hooks as cmacs-transcribe would."
  (let ((mixed (cmacs-gowl-bar-meeting-job-mixed job)))
    (cmacs-gowl-bar-meeting--on-transcribed
     job (list :input-file mixed
               :text "Welcome.\n* not a heading\nWe ship Friday."
               :text-file (concat (file-name-sans-extension mixed) ".txt")))
    (cmacs-gowl-bar-meeting--on-summarised
     job (list :input-file mixed
               :summary "*TL;DR* We ship.\n** Decisions\n- Ship Friday\n\
** Action items\n- [ ] Zach: write docs\n** Open questions\n- Who tests?"
               :org-file (concat (file-name-sans-extension mixed) ".org")))))

;;;; The entry point ----------------------------------------------------

(ert-deftest cmacs-gowl-bar-meeting-test-finish-returns-at-once ()
  "The finish call starts the mix and returns t before anything else."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session)))
      (should job)
      (should (equal (cmacs-gowl-bar-meeting-tests--states) '("mixing")))
      (should (= (length procs) 1))
      (should-not transcribed)
      ;; Every push names the job, top and bottom bar alike.
      (let ((alist (car cmacs-gowl-bar-meeting-tests--pushes)))
        (should (equal (cdr (assoc "meeting-notes.job-id" alist))
                       "mn-7-abc"))
        (should (equal (cdr (assoc "bottom-meeting-notes.job-id" alist))
                       "mn-7-abc"))
        (should (equal (cdr (assoc "meeting-notes.result" alist)) ""))))))

(ert-deftest cmacs-gowl-bar-meeting-test-mix-command ()
  "Several are mixed without normalisation, into 16 kHz mono Opus."
  (let ((cmacs-gowl-bar-meeting-ffmpeg "ffmpeg")
        (cmacs-gowl-bar-meeting-bitrate "24k"))
    (should (equal (cmacs-gowl-bar-meeting--mix-command
                    '("/s/a.ogg" "/s/b c.ogg" "/s/d.ogg") "/s/m.ogg")
                   '("ffmpeg" "-hide_banner" "-loglevel" "error" "-y"
                     "-i" "/s/a.ogg" "-i" "/s/b c.ogg" "-i" "/s/d.ogg"
                     "-filter_complex"
                     "amix=inputs=3:duration=longest:normalize=0"
                     "-ar" "16000" "-ac" "1" "-c:a" "libopus" "-b:a" "24k"
                     "-application" "voip" "/s/m.ogg")))))

(ert-deftest cmacs-gowl-bar-meeting-test-one-recording-is-not-mixed ()
  "One recording goes to transcription as it is, from a timer.
No ffmpeg, no second copy, and nothing done inside the finish call."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((timers nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args)
                   (push (cons fn args) timers) 'fake-timer)))
        (should (eq t (cmacs-gowl-bar-meeting-finish
                       "meeting-notes" "id" session (list "01-a.wav") nil)))
        (should-not procs)
        (should-not transcribed)
        (should (= (length timers) 1))
        (apply (caar timers) (cdar timers)))
      (should (= (length transcribed) 1))
      (should (equal (cmacs-gowl-bar-meeting-job-mixed (car transcribed))
                     (expand-file-name "01-a.wav" session)))
      (should-not (file-exists-p (expand-file-name "meeting.ogg" session)))
      (should-not procs))))

(ert-deftest cmacs-gowl-bar-meeting-test-mix-is-the-real-argv ()
  "The process is given the mix command, with the session's files."
  (cmacs-gowl-bar-meeting-tests--with
    (cmacs-gowl-bar-meeting-tests--finish session)
    (let ((cmd (plist-get (car procs) :command)))
      (should (member (expand-file-name "01-a.wav" session) cmd))
      (should (member (expand-file-name "02-b.wav" session) cmd))
      (should (equal (car (last cmd))
                     (expand-file-name "meeting.ogg" session)))
      (should-not (cl-find-if (lambda (a) (string-suffix-p ".wav" a))
                              (last cmd 1)))
      (should (member "amix=inputs=2:duration=longest:normalize=0" cmd)))))

;;;; The state sequence and the destinations ---------------------------

(ert-deftest cmacs-gowl-bar-meeting-test-directory-route ()
  "mixing, transcribing, summarising, filing, done: transcribe's .org."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session "directory")))
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (should (eq (car transcribed) job))
      (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)
      (should (equal (cmacs-gowl-bar-meeting-tests--states)
                     '("mixing" "transcribing" "summarising" "filing"
                       "done")))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "result")
                     (expand-file-name "meeting.org" session)))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "job-id")
                     "mn-7-abc"))
      (should-not cmacs-gowl-bar-meeting--jobs)
      (should-not ingests))))

(ert-deftest cmacs-gowl-bar-meeting-test-org-inbox-route ()
  "The inbox note: name, the seven header keys, sections, escaping."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish
                session "org-inbox" "Q4 Planning!"))
          path text)
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)
      (setq path (cmacs-gowl-bar-meeting-tests--last "result"))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "done"))
      (should (equal path (expand-file-name
                           "2026-10-16_14-05_meeting_q4_planning.org"
                           inbox)))
      (setq text (with-temp-buffer (insert-file-contents path)
                                   (buffer-string)))
      (should (string-prefix-p "#+title: Q4 Planning!\n" text))
      (should (string-match-p
               "^#\\+description: Meeting notes recorded from 2 sources$"
               text))
      (should (string-match-p "^#\\+authors: Zach Podbielniak$" text))
      (should (string-match-p "^#\\+categories: meeting$" text))
      (should (string-match-p
               "^#\\+created: 2026-10-16T14:05:09[-+][0-9][0-9]:[0-9][0-9]$"
               text))
      (should (string-match-p "^#\\+updated: 2026-10-16T14:05:09" text))
      (should (string-match-p "^#\\+version: 1\\.0$" text))
      ;; Sections in order; action items moved out of the summary.
      (let ((s (string-search "\n* Summary\n" text))
            (a (string-search "\n* Action items\n" text))
            (tr (string-search "\n* Transcript\n" text))
            (n (string-search "\n* My notes\n" text)))
        (should (and s a tr n (< s a tr n))))
      (should (string-match-p "\\* Summary\n\\*TL;DR\\* We ship\\." text))
      (should (string-match-p "^\\*\\* Decisions$" text))
      (should (string-match-p "\\* Action items\n- \\[ \\] Zach: write docs"
                              text))
      (should-not (string-match-p "Summary\n[^*]*\n\\*\\* Action" text))
      ;; Speech never becomes a heading.
      (should (string-match-p "^ \\* not a heading$" text))
      (should (string-match-p "^Recordings: \\[\\[file:" text)))))

(ert-deftest cmacs-gowl-bar-meeting-test-inbox-name-never-overwrites ()
  "A second meeting with the same minute and title gets _2."
  (cmacs-gowl-bar-meeting-tests--with
    (make-directory inbox t)
    (with-temp-file (expand-file-name "2026-10-16_14-05_meeting.org" inbox)
      (insert "earlier"))
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session "org-inbox")))
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)
      (should (equal (cmacs-gowl-bar-meeting-tests--last "result")
                     (expand-file-name "2026-10-16_14-05_meeting_2.org"
                                       inbox))))))

(ert-deftest cmacs-gowl-bar-meeting-test-secondbrain-route ()
  "Ingest gets the summary and transcript as text, type meeting."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish
                session "secondbrain" "Standup"))
          args)
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)
      (should (= (length ingests) 1))
      (setq args (car ingests))
      (should (null (car args)))
      (let ((opts (cdr args)))
        (should (eq (plist-get opts :type) 'meeting))
        (should (equal (plist-get opts :title) "Standup"))
        (should (equal (plist-get opts :tags) "meeting"))
        (should-not (plist-member opts :para))
        (should (string-match-p "We ship\\." (plist-get opts :text)))
        (should (string-match-p "We ship Friday\\." (plist-get opts :text)))
        ;; Filing, not done, until the ingest says so.
        (should (equal (cmacs-gowl-bar-meeting-tests--last "state")
                       "filing"))
        (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-job-plist)
                   (lambda (&rest _)
                     (list :stage "done"
                           :note_file "/notes/02_areas/standup.org"))))
          (funcall (plist-get opts :callback) 'sbi-job)))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "done"))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "result")
                     "/notes/02_areas/standup.org")))))

(ert-deftest cmacs-gowl-bar-meeting-test-secondbrain-para-and-failure ()
  "`:para' is passed when configured; a failed ingest is an error."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((cmacs-gowl-bar-meeting-para 'areas)
          (job (cmacs-gowl-bar-meeting-tests--finish session "secondbrain")))
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)
      (should (eq (plist-get (cdr (car ingests)) :para) 'areas))
      (should (string-prefix-p "Meeting 2026-10-16 14:05"
                               (plist-get (cdr (car ingests)) :title)))
      (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-job-plist)
                 (lambda (&rest _)
                   (list :stage "failed" :error "no model"))))
        (should-not
         (condition-case nil
             (progn (funcall (plist-get (cdr (car ingests)) :callback) 'j)
                    nil)
           (error t))))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
      (should (string-match-p "no model"
                              (cmacs-gowl-bar-meeting-tests--last "error"))))))

(ert-deftest cmacs-gowl-bar-meeting-test-both-route ()
  "`both': ingested, and the directory copy is kept where it was."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session "both")))
      (should (equal (cmacs-gowl-bar-meeting--output-dir job 'both)
                     (file-name-as-directory session)))
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)
      (should (= (length ingests) 1))
      (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-job-plist)
                 (lambda (&rest _) (list :stage "done" :note_file "/n.org"))))
        (funcall (plist-get (cdr (car ingests)) :callback) 'j))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "result") "/n.org")))))

(ert-deftest cmacs-gowl-bar-meeting-test-default-destination ()
  "No destination from the bar: the defcustom decides."
  (cmacs-gowl-bar-meeting-tests--with
    (let* ((cmacs-gowl-bar-meeting-destination 'secondbrain)
           (job (cmacs-gowl-bar-meeting-tests--finish session nil)))
      (should (eq (cmacs-gowl-bar-meeting--destination job) 'secondbrain)))))

(ert-deftest cmacs-gowl-bar-meeting-test-output-dir ()
  "Transcripts land in the session, or under the meetings directory."
  (let* ((cmacs-gowl-bar-meeting-directory "/keep")
         (job (cmacs-gowl-bar-meeting-job-create :dir "/rec/2026-01-01_00-00-00")))
    (should (equal (cmacs-gowl-bar-meeting--output-dir job 'org-inbox)
                   "/rec/2026-01-01_00-00-00/"))
    (should (equal (cmacs-gowl-bar-meeting--output-dir job 'directory)
                   "/keep/2026-01-01_00-00-00/"))))

;;;; Errors are pushed, never signalled --------------------------------

(ert-deftest cmacs-gowl-bar-meeting-test-bad-arguments ()
  "Nonsense from the bar is an error state, and still returns t."
  (cmacs-gowl-bar-meeting-tests--with
    (should (eq t (cmacs-gowl-bar-meeting-finish "meeting-notes" "id"
                                                 session nil nil)))
    (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
    (should (eq t (cmacs-gowl-bar-meeting-finish
                   "meeting-notes" "id" (expand-file-name "nope" session)
                   (list "a.wav") nil)))
    (should (string-match-p "no session directory"
                            (cmacs-gowl-bar-meeting-tests--last "error")))
    (should (eq t (cmacs-gowl-bar-meeting-finish
                   "meeting-notes" "id" session (list "missing.wav") nil)))
    (should (string-match-p "recordings missing"
                            (cmacs-gowl-bar-meeting-tests--last "error")))
    (should-not procs)))

(ert-deftest cmacs-gowl-bar-meeting-test-ffmpeg-missing ()
  "`make-process' failing names the package."
  (cmacs-gowl-bar-meeting-tests--with
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (signal 'file-missing '("Searching" "ffmpeg")))))
      (should (eq t (cmacs-gowl-bar-meeting-finish
                     "meeting-notes" "id" session
                     (list "01-a.wav" "02-b.wav") nil))))
    (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
    (should (string-match-p "ffmpeg-free"
                            (cmacs-gowl-bar-meeting-tests--last "error")))))

(ert-deftest cmacs-gowl-bar-meeting-test-ffmpeg-fails ()
  "A failing mix pushes its last words and where the recordings are."
  (cmacs-gowl-bar-meeting-tests--with
    (cmacs-gowl-bar-meeting-tests--finish session)
    (setq exit-code 1)
    (with-current-buffer (plist-get (car procs) :buffer)
      (insert "warming up\nInvalid data found when processing input\n"))
    (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
    (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
    (should (string-match-p "Invalid data found"
                            (cmacs-gowl-bar-meeting-tests--last "error")))
    (should (string-match-p (regexp-quote session)
                            (cmacs-gowl-bar-meeting-tests--last "error")))
    (should-not transcribed)))

(ert-deftest cmacs-gowl-bar-meeting-test-transcribe-cannot-start ()
  "A transcription that cannot start (no whisper model) is pushed."
  (cmacs-gowl-bar-meeting-tests--with
    (cl-letf (((symbol-function 'cmacs-gowl-bar-meeting--transcribe)
               (lambda (&rest _) (error "the whisper model x is not downloaded"))))
      (cmacs-gowl-bar-meeting-tests--finish session)
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs)))
    (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
    (should (string-match-p "not downloaded"
                            (cmacs-gowl-bar-meeting-tests--last "error")))
    (should-not cmacs-gowl-bar-meeting--jobs)))

(ert-deftest cmacs-gowl-bar-meeting-test-ingest-signals ()
  "An ingest that refuses outright is an error, not a signal."
  (cmacs-gowl-bar-meeting-tests--with
    (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-run)
               (lambda (&rest _) (error "unknown summary type"))))
      (let ((job (cmacs-gowl-bar-meeting-tests--finish session "secondbrain")))
        (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
        (cmacs-gowl-bar-meeting-tests--transcribe-and-summarise job)))
    (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
    (should (string-match-p "unknown summary type"
                            (cmacs-gowl-bar-meeting-tests--last "error")))))

;;;; The watchdog --------------------------------------------------------

(ert-deftest cmacs-gowl-bar-meeting-test-watchdog-failed-transcription ()
  "A transcription that failed (no hook fires) is noticed and pushed."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session)))
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cl-letf (((symbol-function 'cmacs-gowl-bar-meeting--transcribe-status)
                 (lambda (&rest _) '(failed . "whisper: bad WAV"))))
        (cmacs-gowl-bar-meeting--tick job))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "error"))
      (should (string-match-p "bad WAV"
                              (cmacs-gowl-bar-meeting-tests--last "error"))))))

(ert-deftest cmacs-gowl-bar-meeting-test-watchdog-summary-missing ()
  "Done without a summary: the transcript is filed anyway."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session "org-inbox"))
          text)
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting--on-transcribed
       job (list :input-file (cmacs-gowl-bar-meeting-job-mixed job)
                 :text "Only speech." :text-file "/x.txt"))
      (cl-letf (((symbol-function 'cmacs-gowl-bar-meeting--transcribe-status)
                 (lambda (&rest _) '(done))))
        (cmacs-gowl-bar-meeting--tick job))
      (should (equal (cmacs-gowl-bar-meeting-tests--last "state") "done"))
      (setq text (with-temp-buffer
                   (insert-file-contents
                    (cmacs-gowl-bar-meeting-tests--last "result"))
                   (buffer-string)))
      (should (string-match-p "\\* Summary\nNo summary was generated\\." text))
      (should (string-match-p "\\* Transcript\nOnly speech\\." text)))))

(ert-deftest cmacs-gowl-bar-meeting-test-hook-for-another-input ()
  "A hook for a different input file is not taken as this meeting's."
  (cmacs-gowl-bar-meeting-tests--with
    (let ((job (cmacs-gowl-bar-meeting-tests--finish session)))
      (cmacs-gowl-bar-meeting-tests--run-sentinel (car procs))
      (cmacs-gowl-bar-meeting--on-summarised
       job (list :input-file "/elsewhere/talk.wav" :summary "x"))
      (should-not (member "done" (cmacs-gowl-bar-meeting-tests--states))))))

;;;; Opening notes ---------------------------------------------------------

(ert-deftest cmacs-gowl-bar-meeting-test-open-returns-at-once ()
  "The open call only schedules the visit, and never signals."
  (let ((timers nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_time _repeat fn &rest args)
                 (push (cons fn args) timers) 'fake-timer))
              ((symbol-function 'find-file-noselect)
               (lambda (&rest _) (error "Must not visit synchronously"))))
      (should (eq t (cmacs-gowl-bar-meeting-open "/notes/x.org")))
      (should (eq t (cmacs-gowl-bar-meeting-open "")))
      (should (eq t (cmacs-gowl-bar-meeting-open nil)))
      (should (eq t (cmacs-gowl-bar-meeting-open 42))))
    (should (= (length timers) 1))
    (should (equal (cdar timers) '("/notes/x.org")))))

(ert-deftest cmacs-gowl-bar-meeting-test-visit ()
  "The visit shows the notes in the selected window; a gone file is said."
  (let* ((dir (make-temp-file "cmacs-meeting-open-" t))
         (file (expand-file-name "2026-10-16_14-05_meeting.org" dir))
         (raised nil)
         (cmacs-gowl-bar-meeting-raise-frame t))
    (unwind-protect
        (progn
          (with-temp-file file (insert "#+title: Q4\n"))
          (cl-letf (((symbol-function 'select-frame-set-input-focus)
                     (lambda (&rest _) (setq raised t))))
            (save-window-excursion
              (cmacs-gowl-bar-meeting--visit file)
              (should (equal (buffer-file-name
                              (window-buffer (selected-window)))
                             file))
              (should raised)
              (kill-buffer (get-file-buffer file)))
            (setq raised nil)
            (let ((messages nil))
              (cl-letf (((symbol-function 'message)
                         (lambda (fmt &rest args)
                           (push (apply #'format fmt args) messages))))
                (cmacs-gowl-bar-meeting--visit
                 (expand-file-name "gone.org" dir)))
              (should (string-match-p "not there any more" (car messages)))
              (should-not raised))))
      (delete-directory dir t))))

;;;; Startup push ---------------------------------------------------------

(ert-deftest cmacs-gowl-bar-meeting-test-push ()
  "The startup push selects the cmacs backend and the destination."
  (let* ((pushed nil)
         (cmacs-gowl-bar-push-function (lambda (alist) (setq pushed alist)))
         (cmacs-gowl-bar-meeting-destination 'both))
    (should-not (cmacs-gowl-bar-meeting-push))
    (should (equal (cdr (assoc "meeting-notes.backend" pushed)) "cmacs"))
    (should (equal (cdr (assoc "meeting-notes.ai-backend" pushed)) "cmacs"))
    (should (equal (cdr (assoc "meeting-notes.destination" pushed)) "both"))
    (should (equal (cdr (assoc "bottom-meeting-notes.backend" pushed))
                   "cmacs"))))

(ert-deftest cmacs-gowl-bar-meeting-test-slug-and-split ()
  "File-name slugs and the summary split, directly."
  (should (equal (cmacs-gowl-bar-meeting--slug "../../etc/passwd; rm -rf ~")
                 "etc_passwd_rm_rf"))
  (should (<= (length (cmacs-gowl-bar-meeting--slug (make-string 90 ?a)))
              40))
  (let ((split (cmacs-gowl-bar-meeting--split-summary
                "* Summary\nShort.\n## Action Items:\n- [ ] A: b\n## Risks\n- r")))
    (should (equal (cdr split) "- [ ] A: b"))
    (should (string-match-p "Short\\." (car split)))
    (should (string-match-p "## Risks" (car split)))
    (should-not (string-match-p "Summary" (car split)))))

(provide 'cmacs-gowl-bar-meeting-tests)

;;; cmacs-gowl-bar-meeting-tests.el ends here
