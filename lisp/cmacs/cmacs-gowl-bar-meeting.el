;;; cmacs-gowl-bar-meeting.el --- cmacs half of the gowl meeting-notes widget  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `meeting-notes' bar widget (deps/gowl/modules/bar/
;; bar-plugins-meeting.c) records a meeting: one 16 kHz mono WAV per
;; selected source (what the speakers play, the microphone, ...) in a
;; session directory.  Under `cmacs --gowl' it then hands the session
;; to cmacs:
;;
;;   emacsctl eval '(cmacs-gowl-bar-meeting-finish
;;                   "meeting-notes" "JOB-ID" "/session/dir"
;;                   (list "01-a.wav" "02-b.wav") "TITLE" "DESTINATION")'
;;
;; That call runs on Emacs's main thread, which under --gowl is the
;; compositor's, so it returns t AT ONCE and does everything else
;; asynchronously, pushing its progress back to the widget as settings
;; (`cmacs-gowl-bar-push'):
;;
;;   meeting-notes.job-id  the JOB-ID the widget sent (it ignores others)
;;   meeting-notes.state   mixing | transcribing | summarising | filing
;;                         | done | error
;;   meeting-notes.result  the notes file, when done
;;   meeting-notes.error   why, when the state is error
;;
;; The pipeline:
;;
;;   mixing        ffmpeg (a `make-process' with a sentinel) mixes the
;;                 recordings into one `meeting.wav' --- amix with
;;                 normalize=0, so a quiet remote voice is not divided
;;                 by the number of inputs.
;;   transcribing  `cmacs-transcribe' (whisper.cpp) in a PRIVATE queue
;;                 buffer, so the options this meeting needs (output
;;                 directory, summary type) never leak into the user's
;;                 own *cmacs-transcribe* session; its hooks are added
;;                 buffer-locally there, so only this meeting's job
;;                 fires them.
;;   summarising   cmacs-transcribe's own cmacs-ai summary with the
;;                 `meeting' template (decisions, action items with
;;                 owners, open questions).
;;   filing        routed by DESTINATION, or
;;                 `cmacs-gowl-bar-meeting-destination':
;;                   directory    keep transcribe's .txt/.org in
;;                                `cmacs-gowl-bar-meeting-directory'
;;                   secondbrain  `cmacs-secondbrain-ingest-run' with the
;;                                summary and transcript as text, type
;;                                `meeting' --- placed by the ingest
;;                                pipeline (or `cmacs-gowl-bar-meeting-para')
;;                   org-inbox    a notes file in the notes repository's
;;                                header convention, in
;;                                `cmacs-gowl-bar-meeting-inbox'
;;                   both         secondbrain, keeping the directory copy
;;
;; Failures never signal out of here: every stage pushes `error' with
;; the reason instead.  A watchdog notices the two outcomes
;; cmacs-transcribe has no hook for --- a failed transcription and a
;; summary that did not happen --- so the widget never waits forever.
;;
;; `cmacs-gowl-bar-meeting-push' tells the widget it is running under
;; cmacs (backend, AI backend, default destination); the --gowl startup
;; calls it once.
;;
;; Not here yet, deliberately: speaker separation (diarisation) and
;; recognising voices.  The transcript is one stream of speech.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-bar-ai)            ;`cmacs-gowl-bar-push', the group

(declare-function cmacs-transcribe-mode "cmacs-transcribe" ())
(declare-function cmacs-transcribe-start "cmacs-transcribe" ())
(declare-function cmacs-transcribe-supported-p "cmacs-transcribe" ())
(declare-function cmacs-transcribe--enqueue-file "cmacs-transcribe" (in-file))
(declare-function cmacs-transcribe--recompute-outputs "cmacs-transcribe" ())
(declare-function cmacs-transcribe--model "cmacs-transcribe" ())
(declare-function cmacs-transcribe-job-stage "cmacs-transcribe" (job))
(declare-function cmacs-transcribe-job-note "cmacs-transcribe" (job))
(declare-function cmacs-secondbrain-ingest-run "cmacs-secondbrain-ingest"
                  (inputs &rest opts))
(declare-function cmacs-secondbrain-ingest-job-plist "cmacs-secondbrain-ingest"
                  (job))
(defvar cmacs-transcribe--options)
(defvar cmacs-transcribe--jobs)
(defvar cmacs-transcribe-summary-templates)
(defvar cmacs-transcribe-after-transcription-functions)
(defvar cmacs-transcribe-after-summary-functions)

;;;; Customisation ----------------------------------------------------

(defcustom cmacs-gowl-bar-meeting-destination 'org-inbox
  "Where a recorded meeting's notes go when the bar does not say.
`directory'   keep cmacs-transcribe's transcript and summary in
              `cmacs-gowl-bar-meeting-directory'.
`secondbrain' ingest summary + transcript into the second brain.
`org-inbox'   write a notes file into `cmacs-gowl-bar-meeting-inbox'.
`both'        the second brain, keeping the directory copy too.
The panel's destination buttons override this per meeting."
  :type '(choice (const :tag "Directory" directory)
                 (const :tag "Second brain" secondbrain)
                 (const :tag "Org inbox" org-inbox)
                 (const :tag "Second brain + directory" both))
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-directory "~/Documents/recordings/meetings"
  "Directory the `directory' destination keeps transcripts in.
Each meeting gets a subdirectory named after its session; when the
widget's own recordings directory is inside this one (the default),
that is the session directory itself."
  :type 'directory
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-inbox "~/Documents/notes/00_inbox"
  "Directory the `org-inbox' destination writes notes files into."
  :type 'directory
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-para nil
  "PARA placement for the `secondbrain' destination, or nil.
nil lets `cmacs-secondbrain-ingest-run' place the note itself; a
symbol or string is passed as its `:para'."
  :type '(choice (const :tag "Let ingest decide" nil) symbol string)
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-tags '("meeting")
  "Tags given to a meeting ingested into the second brain."
  :type '(repeat string)
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-summary-type 'meeting
  "The `cmacs-transcribe-summary-templates' key used for meetings."
  :type 'symbol
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-summary-template nil
  "A system prompt for meeting summaries, or nil for the template.
When non-nil it replaces the `cmacs-gowl-bar-meeting-summary-type'
template, for the meeting's private transcription session only."
  :type '(choice (const :tag "cmacs-transcribe's template" nil) string)
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-ffmpeg "ffmpeg"
  "The ffmpeg used to mix a meeting's recordings."
  :type 'string
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-timeout (* 4 60 60)
  "Seconds a meeting may take to transcribe and file before giving up."
  :type 'integer
  :group 'cmacs-gowl-bar)

(defcustom cmacs-gowl-bar-meeting-watch-interval 2
  "Seconds between checks on a running transcription."
  :type 'number
  :group 'cmacs-gowl-bar)

;;;; Jobs -------------------------------------------------------------

(cl-defstruct (cmacs-gowl-bar-meeting-job
               (:constructor cmacs-gowl-bar-meeting-job-create)
               (:copier nil))
  widget id dir files title destination
  mixed            ; the WAV handed to cmacs-transcribe
  buffer           ; the private transcription queue buffer
  timer            ; the watchdog
  started          ; `float-time' at finish
  text txt-file    ; transcript, once transcribed
  summary org-file ; summary, once summarised
  routed           ; non-nil once filing has begun
  finished)        ; non-nil once done or error was pushed

(defvar cmacs-gowl-bar-meeting--jobs nil
  "Meetings in flight, newest first.")

(defun cmacs-gowl-bar-meeting--push (job state &optional result error)
  "Push STATE for JOB, with RESULT or ERROR.
All four keys go every time, so a result or error left over from an
earlier meeting can never be read as this one's."
  (cmacs-gowl-bar-push
   (cmacs-gowl-bar-meeting-job-widget job)
   (list (cons "job-id" (cmacs-gowl-bar-meeting-job-id job))
         (cons "state" state)
         (cons "result" (or result ""))
         (cons "error" (or error "")))))

(defun cmacs-gowl-bar-meeting--cleanup (job)
  "Stop JOB's watchdog and drop its private buffer, later.
Not from inside the buffer's own hook: the buffer is killed on the
next turn of the command loop."
  (when (timerp (cmacs-gowl-bar-meeting-job-timer job))
    (cancel-timer (cmacs-gowl-bar-meeting-job-timer job))
    (setf (cmacs-gowl-bar-meeting-job-timer job) nil))
  (let ((buf (cmacs-gowl-bar-meeting-job-buffer job)))
    (when (buffer-live-p buf)
      (run-at-time 0 nil (lambda ()
                           (when (buffer-live-p buf)
                             (let ((kill-buffer-query-functions nil))
                               (ignore-errors (kill-buffer buf))))))))
  (setq cmacs-gowl-bar-meeting--jobs
        (delq job cmacs-gowl-bar-meeting--jobs)))

(defun cmacs-gowl-bar-meeting--fail (job message)
  "End JOB in an error saying MESSAGE.  Never signals."
  (unless (cmacs-gowl-bar-meeting-job-finished job)
    (setf (cmacs-gowl-bar-meeting-job-finished job) t)
    (message "cmacs-gowl-bar-meeting: %s" message)
    (cmacs-gowl-bar-meeting--push job "error" nil message)
    (cmacs-gowl-bar-meeting--cleanup job)))

(defun cmacs-gowl-bar-meeting--done (job result)
  "End JOB successfully with RESULT, the notes file."
  (unless (cmacs-gowl-bar-meeting-job-finished job)
    (setf (cmacs-gowl-bar-meeting-job-finished job) t)
    (cmacs-gowl-bar-meeting--push job "done" result)
    (cmacs-gowl-bar-meeting--cleanup job)))

(defmacro cmacs-gowl-bar-meeting--guard (job &rest body)
  "Run BODY; any error fails JOB rather than escaping.
Sentinels, hooks and timers all run this: an error escaping one of them
would be logged and then forgotten, and the widget would wait forever."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (cmacs-gowl-bar-meeting--fail
             ,job (error-message-string err)))))

;;;; Mixing ------------------------------------------------------------

(defun cmacs-gowl-bar-meeting--mix-command (files output)
  "The ffmpeg command mixing FILES into OUTPUT, a 16 kHz mono WAV.
One file is only resampled; several are mixed with amix, normalize=0
so each keeps its own level."
  (append (list cmacs-gowl-bar-meeting-ffmpeg
                "-hide_banner" "-loglevel" "error" "-y")
          (apply #'append (mapcar (lambda (f) (list "-i" f)) files))
          (when (cdr files)
            (list "-filter_complex"
                  (format "amix=inputs=%d:duration=longest:normalize=0"
                          (length files))))
          (list "-ar" "16000" "-ac" "1" output)))

(defun cmacs-gowl-bar-meeting--mix (job)
  "Start mixing JOB's recordings; the sentinel continues the pipeline."
  (let* ((dir (cmacs-gowl-bar-meeting-job-dir job))
         (out (expand-file-name "meeting.wav" dir))
         (log (generate-new-buffer " *cmacs-gowl-bar-meeting-ffmpeg*")))
    (setf (cmacs-gowl-bar-meeting-job-mixed job) out)
    (cmacs-gowl-bar-meeting--push job "mixing")
    (condition-case err
        (make-process
         :name "cmacs-gowl-bar-meeting-mix"
         :buffer log
         :noquery t
         :connection-type 'pipe
         :command (cmacs-gowl-bar-meeting--mix-command
                   (cmacs-gowl-bar-meeting-job-files job) out)
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (cmacs-gowl-bar-meeting--guard job
               (let ((ok (and (eq (process-status proc) 'exit)
                              (zerop (process-exit-status proc))))
                     (tail (cmacs-gowl-bar-meeting--tail log)))
                 (when (buffer-live-p log) (kill-buffer log))
                 (if ok
                     (cmacs-gowl-bar-meeting--transcribe job)
                   (cmacs-gowl-bar-meeting--fail
                    job (format "mixing failed%s; the recordings are in %s"
                                (if (string-empty-p tail) ""
                                  (concat ": " tail))
                                dir))))))))
      (error
       (when (buffer-live-p log) (kill-buffer log))
       (cmacs-gowl-bar-meeting--fail
        job (format "cannot run %s (install ffmpeg-free): %s"
                    cmacs-gowl-bar-meeting-ffmpeg
                    (error-message-string err)))))))

(defun cmacs-gowl-bar-meeting--tail (buffer)
  "The last non-empty line of BUFFER, or \"\"."
  (if (not (buffer-live-p buffer))
      ""
    (with-current-buffer buffer
      (let ((lines (split-string (buffer-string) "\n" t "[ \t\r]+")))
        (truncate-string-to-width (or (car (last lines)) "") 300)))))

;;;; Transcription -----------------------------------------------------

(defun cmacs-gowl-bar-meeting--output-dir (job destination)
  "Where cmacs-transcribe writes JOB's transcript and summary.
For the `directory' and `both' destinations, a subdirectory of
`cmacs-gowl-bar-meeting-directory' (the session directory itself when
it is already inside it); otherwise the session directory, beside the
recordings."
  (let* ((dir (file-name-as-directory
               (expand-file-name (cmacs-gowl-bar-meeting-job-dir job))))
         (keep (file-name-as-directory
                (expand-file-name cmacs-gowl-bar-meeting-directory))))
    (cond
     ((not (memq destination '(directory both))) dir)
     ((string-prefix-p keep dir) dir)
     (t (file-name-as-directory
         (expand-file-name (file-name-nondirectory (directory-file-name dir))
                           keep))))))

(defun cmacs-gowl-bar-meeting--transcribe (job)
  "Hand JOB's mixed WAV to cmacs-transcribe in a private queue buffer.
Its hooks are added buffer-locally, so only this job fires them."
  (unless (fboundp 'cmacs-transcribe-start)
    (require 'cmacs-transcribe))
  (unless (cmacs-transcribe-supported-p)
    (error "cmacs-transcribe cannot run: this build has no whisper, or \
there is no ffmpeg backend"))
  (let ((model (ignore-errors (cmacs-transcribe--model))))
    (unless (and model (file-exists-p model))
      (error "the whisper model %s is not downloaded (M-x \
cmacs-whisper-download-model)" (or model "(unset)"))))
  (let* ((dest (cmacs-gowl-bar-meeting--destination job))
         (outdir (cmacs-gowl-bar-meeting--output-dir job dest))
         (buf (generate-new-buffer " *cmacs-gowl-bar-meeting*")))
    (make-directory outdir t)
    (setf (cmacs-gowl-bar-meeting-job-buffer job) buf)
    (with-current-buffer buf
      (cmacs-transcribe-mode)
      ;; This buffer's session only: the user's own *cmacs-transcribe*
      ;; keeps its options.
      (cl-loop for (k v) on (list :output-dir outdir :summary-dir nil
                                  :naming 'base :summarize t :parallel 1
                                  :summary-type cmacs-gowl-bar-meeting-summary-type
                                  :type "meeting"
                                  :tags cmacs-gowl-bar-meeting-tags)
               by #'cddr
               do (setq cmacs-transcribe--options
                        (plist-put cmacs-transcribe--options k v)))
      (when cmacs-gowl-bar-meeting-summary-template
        (setq-local cmacs-transcribe-summary-templates
                    (cons (cons cmacs-gowl-bar-meeting-summary-type
                                cmacs-gowl-bar-meeting-summary-template)
                          cmacs-transcribe-summary-templates)))
      (add-hook 'cmacs-transcribe-after-transcription-functions
                (lambda (info) (cmacs-gowl-bar-meeting--on-transcribed job info))
                nil t)
      (add-hook 'cmacs-transcribe-after-summary-functions
                (lambda (info) (cmacs-gowl-bar-meeting--on-summarised job info))
                nil t)
      (cmacs-transcribe--enqueue-file (cmacs-gowl-bar-meeting-job-mixed job))
      (cmacs-transcribe--recompute-outputs)
      ;; Under emacsctl an RPC already binds this; from a sentinel it
      ;; does not, and the preflight's y-or-n-p must not reach the user.
      (let ((inhibit-interaction t))
        (cmacs-transcribe-start)))
    (cmacs-gowl-bar-meeting--push job "transcribing")
    (setf (cmacs-gowl-bar-meeting-job-timer job)
          (run-at-time cmacs-gowl-bar-meeting-watch-interval
                       cmacs-gowl-bar-meeting-watch-interval
                       #'cmacs-gowl-bar-meeting--tick job))))

(defun cmacs-gowl-bar-meeting--transcribe-status (job)
  "JOB's transcription as (STAGE . NOTE), or (gone) when it vanished."
  (let ((buf (cmacs-gowl-bar-meeting-job-buffer job)))
    (if (not (buffer-live-p buf))
        (list 'gone)
      (with-current-buffer buf
        (let ((tj (car-safe cmacs-transcribe--jobs)))
          (if tj
              (cons (cmacs-transcribe-job-stage tj)
                    (cmacs-transcribe-job-note tj))
            (list 'gone)))))))

(defun cmacs-gowl-bar-meeting--tick (job)
  "The watchdog: notice what cmacs-transcribe has no hook for.
A failed transcription, a summary that did not happen (the job ends
`done' without the after-summary hook), a vanished queue, and the
overall timeout."
  (cmacs-gowl-bar-meeting--guard job
    (unless (or (cmacs-gowl-bar-meeting-job-finished job)
                (cmacs-gowl-bar-meeting-job-routed job))
      (let* ((status (cmacs-gowl-bar-meeting--transcribe-status job))
             (stage (car status)))
        (cond
         ((> (- (float-time) (cmacs-gowl-bar-meeting-job-started job))
             cmacs-gowl-bar-meeting-timeout)
          (cmacs-gowl-bar-meeting--fail
           job (format "gave up after %d s; the recordings are in %s"
                       cmacs-gowl-bar-meeting-timeout
                       (cmacs-gowl-bar-meeting-job-dir job))))
         ((memq stage '(failed skipped gone))
          (cmacs-gowl-bar-meeting--fail
           job (format "transcription failed%s; the recordings are in %s"
                       (if (cdr status) (concat ": " (cdr status)) "")
                       (cmacs-gowl-bar-meeting-job-dir job))))
         ((eq stage 'done)
          ;; Done with no after-summary: the summary failed or was
          ;; skipped.  The transcript is the deliverable; file it.
          (cmacs-gowl-bar-meeting--route job)))))))

(defun cmacs-gowl-bar-meeting--on-transcribed (job info)
  "cmacs-transcribe wrote JOB's transcript; INFO is its plist."
  (cmacs-gowl-bar-meeting--guard job
    (when (equal (plist-get info :input-file)
                 (expand-file-name (cmacs-gowl-bar-meeting-job-mixed job)))
      (setf (cmacs-gowl-bar-meeting-job-text job) (plist-get info :text)
            (cmacs-gowl-bar-meeting-job-txt-file job)
            (plist-get info :text-file))
      (unless (cmacs-gowl-bar-meeting-job-finished job)
        (cmacs-gowl-bar-meeting--push
         job (if (string-empty-p (or (plist-get info :text) ""))
                 "filing" "summarising"))))))

(defun cmacs-gowl-bar-meeting--on-summarised (job info)
  "cmacs-transcribe wrote JOB's summary; INFO is its plist."
  (cmacs-gowl-bar-meeting--guard job
    (when (equal (plist-get info :input-file)
                 (expand-file-name (cmacs-gowl-bar-meeting-job-mixed job)))
      (setf (cmacs-gowl-bar-meeting-job-summary job) (plist-get info :summary)
            (cmacs-gowl-bar-meeting-job-org-file job) (plist-get info :org-file))
      (unless (cmacs-gowl-bar-meeting-job-text job)
        (setf (cmacs-gowl-bar-meeting-job-text job) (plist-get info :text)))
      (cmacs-gowl-bar-meeting--route job))))

;;;; Filing ------------------------------------------------------------

(defun cmacs-gowl-bar-meeting--destination (job)
  "JOB's destination symbol: the bar's choice, else the defcustom."
  (let ((d (cmacs-gowl-bar-meeting-job-destination job)))
    (or (and (stringp d)
             (cdr (assoc d '(("directory" . directory)
                             ("secondbrain" . secondbrain)
                             ("second-brain" . secondbrain)
                             ("org-inbox" . org-inbox)
                             ("inbox" . org-inbox)
                             ("both" . both)))))
        cmacs-gowl-bar-meeting-destination)))

(defun cmacs-gowl-bar-meeting--session-time (dir)
  "The time a session directory DIR is named after, or now."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (if (string-match
         "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)_\
\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" name)
        (encode-time (list (string-to-number (match-string 6 name))
                           (string-to-number (match-string 5 name))
                           (string-to-number (match-string 4 name))
                           (string-to-number (match-string 3 name))
                           (string-to-number (match-string 2 name))
                           (string-to-number (match-string 1 name))
                           nil -1 nil))
      (current-time))))

(defun cmacs-gowl-bar-meeting--slug (title)
  "TITLE as lower-case ASCII words joined by underscores, at most 40."
  (let* ((s (downcase (or title "")))
         (s (replace-regexp-in-string "[^a-z0-9]+" "_" s))
         (s (string-trim s "_+" "_+")))
    (string-trim-right (truncate-string-to-width s 40) "_+")))

(defun cmacs-gowl-bar-meeting--notes-name (time title)
  "`YYYY-MM-DD_HH-MM_meeting[_slug].org' for TIME and TITLE."
  (let ((slug (cmacs-gowl-bar-meeting--slug title)))
    (concat (format-time-string "%Y-%m-%d_%H-%M" time) "_meeting"
            (if (string-empty-p slug) "" (concat "_" slug))
            ".org")))

(defun cmacs-gowl-bar-meeting--split-summary (summary)
  "SUMMARY split into (REST . ACTIONS).
ACTIONS is the body of its `Action items' heading or nil; a heading
that only says Summary or TL;DR is dropped, since the notes have one."
  (let (rest actions in-actions found)
    (dolist (line (split-string (or summary "") "\n"))
      (let ((heading (and (string-match "\\`[*#]+ +\\(.*?\\)[ :*]*\\'" line)
                          (downcase (match-string 1 line)))))
        (cond
         ((and heading (string-prefix-p "action item" heading))
          (setq in-actions t found t))
         ((and heading (member heading '("summary" "tl;dr")))
          (setq in-actions nil))
         (heading (setq in-actions nil) (push line rest))
         (in-actions (push line actions))
         (t (push line rest)))))
    (cons (string-trim (string-join (nreverse rest) "\n"))
          (and found
               (let ((a (string-trim (string-join (nreverse actions) "\n"))))
                 (unless (string-empty-p a) a))))))

(defun cmacs-gowl-bar-meeting--relevel (text)
  "TEXT with every heading moved to level 2, under the notes' sections."
  (mapconcat (lambda (line)
               (if (string-match "\\`[*#]+ +\\(.*\\)\\'" line)
                   (concat "** " (match-string 1 line))
                 line))
             (split-string text "\n") "\n"))

(defun cmacs-gowl-bar-meeting--escape-transcript (text)
  "TEXT with no line able to read as an Org heading or keyword.
One spoken sentence per line, blank lines dropped."
  (mapconcat (lambda (line)
               (if (string-match-p "\\`[*#]" line) (concat " " line) line))
             (split-string (or text "") "\n" t "[ \t]+")
             "\n"))

(defun cmacs-gowl-bar-meeting--org-document (job time)
  "The org-inbox notes file for JOB, a meeting that started at TIME.
Header in the notes repository's convention; one paragraph per line."
  (let* ((title (let ((tt (cmacs-gowl-bar-meeting-job-title job)))
                  (if (and tt (not (string-empty-p tt))) tt
                    (format-time-string "Meeting %Y-%m-%d %H:%M" time))))
         (iso (format-time-string "%FT%T%:z" time))
         (split (cmacs-gowl-bar-meeting--split-summary
                 (cmacs-gowl-bar-meeting-job-summary job)))
         (n (length (cmacs-gowl-bar-meeting-job-files job))))
    (concat
     (format "#+title: %s\n" title)
     (format "#+description: Meeting notes recorded from %d source%s\n"
             n (if (= n 1) "" "s"))
     (format "#+authors: %s\n" (if (string-empty-p user-full-name)
                                   user-login-name user-full-name))
     "#+categories: meeting\n"
     (format "#+created: %s\n#+updated: %s\n#+version: 1.0\n\n" iso iso)
     "* Summary\n"
     (if (string-empty-p (car split))
         "No summary was generated.\n"
       (concat (cmacs-gowl-bar-meeting--relevel (car split)) "\n"))
     "\n* Action items\n"
     (if (cdr split) (concat (cmacs-gowl-bar-meeting--relevel (cdr split)) "\n")
       "None captured.\n")
     "\n* Transcript\n"
     (let ((tx (cmacs-gowl-bar-meeting--escape-transcript
                (cmacs-gowl-bar-meeting-job-text job))))
       (if (string-empty-p tx) "(empty)\n" (concat tx "\n")))
     (format "\nRecordings: [[file:%s]]\n"
             (abbreviate-file-name
              (expand-file-name (cmacs-gowl-bar-meeting-job-dir job))))
     "\n* My notes\n\n")))

(defun cmacs-gowl-bar-meeting--unique (path)
  "PATH, or PATH with _2, _3 ... before the extension if it exists."
  (let ((n 2) (base (file-name-sans-extension path))
        (ext (file-name-extension path t)) (try path))
    (while (and (file-exists-p try) (< n 100))
      (setq try (format "%s_%d%s" base n ext) n (1+ n)))
    try))

(defun cmacs-gowl-bar-meeting--write-inbox (job)
  "Write JOB's notes into `cmacs-gowl-bar-meeting-inbox'; return the path."
  (let* ((time (cmacs-gowl-bar-meeting--session-time
                (cmacs-gowl-bar-meeting-job-dir job)))
         (dir (expand-file-name cmacs-gowl-bar-meeting-inbox))
         (path (cmacs-gowl-bar-meeting--unique
                (expand-file-name (cmacs-gowl-bar-meeting--notes-name
                                   time (cmacs-gowl-bar-meeting-job-title job))
                                  dir))))
    (make-directory dir t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (cmacs-gowl-bar-meeting--org-document job time)
                    nil path nil 'silent))
    path))

(defun cmacs-gowl-bar-meeting--ingest-text (job)
  "What the second brain is given for JOB: the summary, then the transcript."
  (let ((summary (cmacs-gowl-bar-meeting-job-summary job))
        (text (cmacs-gowl-bar-meeting-job-text job)))
    (concat (if (and summary (not (string-empty-p summary)))
                (concat "* Summary\n" summary "\n\n") "")
            "* Transcript\n"
            (cmacs-gowl-bar-meeting--escape-transcript text) "\n")))

(defun cmacs-gowl-bar-meeting--ingest (job keep)
  "Ingest JOB into the second brain; KEEP is a path for the toast if it fails."
  (unless (fboundp 'cmacs-secondbrain-ingest-run)
    (require 'cmacs-secondbrain-ingest))
  (let ((title (cmacs-gowl-bar-meeting-job-title job)))
    (apply #'cmacs-secondbrain-ingest-run nil
           :text (cmacs-gowl-bar-meeting--ingest-text job)
           :type 'meeting
           :title (if (and title (not (string-empty-p title))) title
                    (format-time-string
                     "Meeting %Y-%m-%d %H:%M"
                     (cmacs-gowl-bar-meeting--session-time
                      (cmacs-gowl-bar-meeting-job-dir job))))
           :tags (mapconcat #'identity cmacs-gowl-bar-meeting-tags ",")
           :callback
           (lambda (ingest-job)
             (cmacs-gowl-bar-meeting--guard job
               (let* ((pl (cmacs-secondbrain-ingest-job-plist ingest-job))
                      (stage (plist-get pl :stage)))
                 (if (equal stage "done")
                     (cmacs-gowl-bar-meeting--done
                      job (or (plist-get pl :note_file) keep ""))
                   (cmacs-gowl-bar-meeting--fail
                    job (format "the second brain did not take it (%s: %s)%s"
                                stage (or (plist-get pl :error) "no reason")
                                (if keep (format "; the transcript is %s" keep)
                                  "")))))))
           (when cmacs-gowl-bar-meeting-para
             (list :para cmacs-gowl-bar-meeting-para)))))

(defun cmacs-gowl-bar-meeting--route (job)
  "File JOB's notes where its destination says."
  (unless (or (cmacs-gowl-bar-meeting-job-routed job)
              (cmacs-gowl-bar-meeting-job-finished job))
    (setf (cmacs-gowl-bar-meeting-job-routed job) t)
    (when (timerp (cmacs-gowl-bar-meeting-job-timer job))
      (cancel-timer (cmacs-gowl-bar-meeting-job-timer job))
      (setf (cmacs-gowl-bar-meeting-job-timer job) nil))
    (cmacs-gowl-bar-meeting--push job "filing")
    (let ((kept (or (cmacs-gowl-bar-meeting-job-org-file job)
                    (cmacs-gowl-bar-meeting-job-txt-file job))))
      (pcase (cmacs-gowl-bar-meeting--destination job)
        ('directory
         (if kept (cmacs-gowl-bar-meeting--done job kept)
           (cmacs-gowl-bar-meeting--fail job "no transcript was written")))
        ('org-inbox
         (cmacs-gowl-bar-meeting--done
          job (cmacs-gowl-bar-meeting--write-inbox job)))
        ((or 'secondbrain 'both)
         (cmacs-gowl-bar-meeting--ingest job kept))
        (other
         (cmacs-gowl-bar-meeting--fail
          job (format "unknown destination %S" other)))))))

;;;; Entry points ------------------------------------------------------

;;;###autoload
(defun cmacs-gowl-bar-meeting-finish (widget id session-dir files title
                                             &optional destination)
  "Process a meeting the gowl bar recorded, asynchronously.

WIDGET is the bar widget's name (\"meeting-notes\"), ID its job id,
echoed back so it ignores pushes for other meetings.  SESSION-DIR holds
the recordings; FILES are their names (relative to SESSION-DIR, or
absolute).  TITLE is the meeting's title or nil.  DESTINATION is
\"directory\", \"secondbrain\", \"org-inbox\" or \"both\", or nil for
`cmacs-gowl-bar-meeting-destination'.

Returns t at once.  Progress, the result and any error arrive at the
widget as WIDGET.state / .result / .error settings (see the
Commentary).  Never prompts, never blocks and never signals: this runs
from emacsctl on the compositor's thread under --gowl."
  (let ((job (cmacs-gowl-bar-meeting-job-create
              :widget (if (and (stringp widget) (not (string-empty-p widget)))
                          widget "meeting-notes")
              :id (if (stringp id) id "")
              :dir (and (stringp session-dir) (expand-file-name session-dir))
              :title (and (stringp title) (not (string-empty-p title)) title)
              :destination destination
              :started (float-time))))
    (cmacs-gowl-bar-meeting--guard job
      (cond
       ((not (and (stringp id) (stringp session-dir)
                  (listp files) files (cl-every #'stringp files)))
        (cmacs-gowl-bar-meeting--fail
         job "cmacs-gowl-bar-meeting-finish: ID, SESSION-DIR and FILES \
must be strings"))
       ((not (file-directory-p (cmacs-gowl-bar-meeting-job-dir job)))
        (cmacs-gowl-bar-meeting--fail
         job (format "no session directory %s"
                     (cmacs-gowl-bar-meeting-job-dir job))))
       (t
        (setf (cmacs-gowl-bar-meeting-job-files job)
              (mapcar (lambda (f)
                        (expand-file-name f (cmacs-gowl-bar-meeting-job-dir job)))
                      files))
        (let ((missing (cl-remove-if #'file-readable-p
                                     (cmacs-gowl-bar-meeting-job-files job))))
          (if missing
              (cmacs-gowl-bar-meeting--fail
               job (format "recordings missing: %s"
                           (mapconcat #'identity missing ", ")))
            (push job cmacs-gowl-bar-meeting--jobs)
            (cmacs-gowl-bar-meeting--mix job))))))
    t))

;;;###autoload
(defun cmacs-gowl-bar-meeting-push (&optional widget)
  "Tell the meeting-notes WIDGET it is running under cmacs.
Sets its backend and AI backend to cmacs and its default destination to
`cmacs-gowl-bar-meeting-destination'.  WIDGET defaults to
\"meeting-notes\".  Never signals."
  (cmacs-gowl-bar-push
   (or widget "meeting-notes")
   (list (cons "backend" "cmacs")
         (cons "ai-backend" "cmacs")
         (cons "destination"
               (symbol-name cmacs-gowl-bar-meeting-destination))))
  nil)

(provide 'cmacs-gowl-bar-meeting)

;;; cmacs-gowl-bar-meeting.el ends here
