;;; cmacs-transcribe-tests.el --- Tests for the batch transcriber -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-transcribe'.  Output-path naming, the srt/vtt/
;; timestamped segment formatters, the ffmpeg conversion-command builder,
;; kind detection, the process filter, and summary-template lookup are pure
;; functions, so these tests need no real ffmpeg/whisper/ai -- they run in
;; any build where cmacs-transcribe.el loaded.

;;; Code:

(require 'ert)
(require 'cmacs-transcribe nil t)

(defmacro cmacs-transcribe-tests--skip-unless-loaded ()
  "Skip the test unless `cmacs-transcribe' loaded."
  '(skip-unless (featurep 'cmacs-transcribe)))

(defmacro cmacs-transcribe-tests--with-options (opts &rest body)
  "Run BODY in a temp buffer whose session OPTS are set."
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local cmacs-transcribe--options ,opts)
     ,@body))

;;; ---------------------------------------------------------------------
;;; Output-path naming
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcribe-test-dest-append ()
  "`append' naming appends the suffix to the whole input name."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--dest "/a/talk.mp4" ".txt" 'append nil)
                 "/a/talk.mp4.txt")))

(ert-deftest cmacs-transcribe-test-dest-base ()
  "`base' naming replaces the extension."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--dest "/a/talk.mp4" ".txt" 'base nil)
                 "/a/talk.txt")))

(ert-deftest cmacs-transcribe-test-dest-dir-override ()
  "A DIR argument redirects the output while keeping the chosen name."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--dest "/a/talk.mp4" ".srt" 'base "/out")
                 "/out/talk.srt")))

(ert-deftest cmacs-transcribe-test-txt-org-sub ()
  "txt/org/subtitle helpers honour naming + the dir options."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (cmacs-transcribe-tests--with-options
      '(:naming append :subtitle-naming base
        :output-dir "/out" :summary-dir "/notes")
    (should (equal (cmacs-transcribe--txt-for "/a/talk.mp4") "/out/talk.mp4.txt"))
    (should (equal (cmacs-transcribe--org-for "/a/talk.mp4") "/notes/talk.mp4.org"))
    (should (equal (cmacs-transcribe--sub-for "/a/talk.mp4" ".srt")
                   "/out/talk.srt"))))

(ert-deftest cmacs-transcribe-test-org-follows-output-dir ()
  "A nil summary-dir makes the Org follow the output-dir."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (cmacs-transcribe-tests--with-options
      '(:naming append :output-dir "/out" :summary-dir nil)
    (should (equal (cmacs-transcribe--org-for "/a/talk.mp4") "/out/talk.mp4.org"))))

;;; ---------------------------------------------------------------------
;;; Kind detection + process filter
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcribe-test-kind-of ()
  "Video extensions map to `video', others to `audio'."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (eq (cmacs-transcribe--kind-of "/a/clip.MP4") 'video))
  (should (eq (cmacs-transcribe--kind-of "/a/song.mp3") 'audio))
  (should (eq (cmacs-transcribe--kind-of "/a/voice.ogg") 'audio)))

(ert-deftest cmacs-transcribe-test-filter-status ()
  "The process filter marks jobs queued/skipped by transcript existence."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (let ((present (make-temp-file "cmacs-transcribe-test-" nil ".txt"))
        (absent "/nonexistent/cmacs-transcribe-absent.txt"))
    (unwind-protect
        (progn
          (cmacs-transcribe-tests--with-options '(:process-filter missing)
            (should (eq (cmacs-transcribe--filter-status present) 'skipped))
            (should (eq (cmacs-transcribe--filter-status absent) 'queued)))
          (cmacs-transcribe-tests--with-options '(:process-filter existing)
            (should (eq (cmacs-transcribe--filter-status present) 'queued))
            (should (eq (cmacs-transcribe--filter-status absent) 'skipped)))
          (cmacs-transcribe-tests--with-options '(:process-filter nil)
            (should (eq (cmacs-transcribe--filter-status absent) 'queued))))
      (delete-file present))))

;;; ---------------------------------------------------------------------
;;; Conversion command builder
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcribe-test-convert-args ()
  "The conversion command extracts a 16 kHz mono S16LE WAV."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (let ((cmacs-transcribe-ffmpeg-extra-args nil))
    (should (equal (cmacs-transcribe--convert-args '(:in "/in/a.mp4" :out "/tmp/x.wav"))
                   '("-y" "-i" "/in/a.mp4" "-vn" "-ac" "1" "-ar" "16000"
                     "-c:a" "pcm_s16le" "-f" "wav" "/tmp/x.wav")))))

(ert-deftest cmacs-transcribe-test-convert-args-extra ()
  "Extra ffmpeg args are inserted before the output path."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (let ((cmacs-transcribe-ffmpeg-extra-args '("-af" "loudnorm")))
    (should (equal (cmacs-transcribe--convert-args '(:in "/in/a.wav" :out "/tmp/x.wav"))
                   '("-y" "-i" "/in/a.wav" "-vn" "-ac" "1" "-ar" "16000"
                     "-c:a" "pcm_s16le" "-f" "wav" "-af" "loudnorm" "/tmp/x.wav")))))

;;; ---------------------------------------------------------------------
;;; Segment formatters + duration
;;; ---------------------------------------------------------------------

(defconst cmacs-transcribe-tests--segments
  '(((:start . 0)    (:end . 1200) (:text . "hello"))
    ((:start . 1200) (:end . 2400) (:text . " world")))
  "A tiny two-segment result for the formatter tests.")

(ert-deftest cmacs-transcribe-test-ms-ts ()
  "Millisecond timestamps format with the requested separator."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--ms->ts 3661500 ",") "01:01:01,500"))
  (should (equal (cmacs-transcribe--ms->ts 3661500 ".") "01:01:01.500"))
  (should (equal (cmacs-transcribe--ms->clock 3661500) "01:01:01")))

(ert-deftest cmacs-transcribe-test-srt ()
  "SubRip output numbers cues and uses comma timestamps."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--segments->srt cmacs-transcribe-tests--segments)
                 (concat "1\n00:00:00,000 --> 00:00:01,200\nhello\n\n"
                         "2\n00:00:01,200 --> 00:00:02,400\nworld\n\n"))))

(ert-deftest cmacs-transcribe-test-vtt ()
  "WebVTT output has the header and dot timestamps."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--segments->vtt cmacs-transcribe-tests--segments)
                 (concat "WEBVTT\n\n"
                         "00:00:00.000 --> 00:00:01.200\nhello\n\n"
                         "00:00:01.200 --> 00:00:02.400\nworld\n\n"))))

(ert-deftest cmacs-transcribe-test-timestamped ()
  "Timestamped text prefixes each segment with an [HH:MM:SS] clock."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (equal (cmacs-transcribe--segments->timestamped cmacs-transcribe-tests--segments)
                 "[00:00:00] hello\n[00:00:01] world\n")))

(ert-deftest cmacs-transcribe-test-duration ()
  "Duration is the ceiling of the last segment end, in seconds."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (should (= (cmacs-transcribe--duration cmacs-transcribe-tests--segments) 3))
  (should (= (cmacs-transcribe--duration nil) 0)))

;;; ---------------------------------------------------------------------
;;; Summary template lookup
;;; ---------------------------------------------------------------------

(ert-deftest cmacs-transcribe-test-summary-prompt ()
  "The summary prompt resolves the session's template, falling back to general."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (cmacs-transcribe-tests--with-options '(:summary-type meeting)
    (should (equal (cmacs-transcribe--summary-prompt)
                   (cdr (assq 'meeting cmacs-transcribe-summary-templates)))))
  (cmacs-transcribe-tests--with-options '(:summary-type no-such-type)
    (should (equal (cmacs-transcribe--summary-prompt)
                   (cdr (assq 'general cmacs-transcribe-summary-templates))))))

;;; ---------------------------------------------------------------------
;;; Visit / retroactive-summary commands (operate on the job at point)
;;; ---------------------------------------------------------------------

(defun cmacs-transcribe-tests--goto-job-line ()
  "Move point onto the first job line in the current queue buffer."
  (goto-char (point-min))
  (while (and (not (cmacs-transcribe--job-at-point)) (not (eobp)))
    (forward-line 1)))

(ert-deftest cmacs-transcribe-test-visit-opens-done-txt ()
  "`cmacs-transcribe-visit' opens the transcript of a done job at point."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (let ((txt (make-temp-file "cmacs-transcribe-test-" nil ".txt"))
        opened)
    (unwind-protect
        (with-temp-buffer
          (cmacs-transcribe-mode)
          (setq-local cmacs-transcribe--jobs
                      (list (cmacs-transcribe-job-create
                             :input "/x/a.mp3" :kind 'audio :txt txt :stage 'done)))
          (cmacs-transcribe--render (current-buffer))
          (cmacs-transcribe-tests--goto-job-line)
          (should (cmacs-transcribe--job-at-point))
          (cl-letf (((symbol-function 'find-file-other-window)
                     (lambda (f) (setq opened f))))
            (cmacs-transcribe-visit))
          (should (equal opened txt)))
      (delete-file txt))))

(ert-deftest cmacs-transcribe-test-visit-rejects-unfinished ()
  "`cmacs-transcribe-visit' refuses a job that is not done."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (with-temp-buffer
    (cmacs-transcribe-mode)
    (setq-local cmacs-transcribe--jobs
                (list (cmacs-transcribe-job-create
                       :input "/x/a.mp3" :kind 'audio :txt "/x/a.txt" :stage 'queued)))
    (cmacs-transcribe--render (current-buffer))
    (cmacs-transcribe-tests--goto-job-line)
    (should-error (cmacs-transcribe-visit) :type 'user-error)))

(ert-deftest cmacs-transcribe-test-summarize-at-point-rejects-unfinished ()
  "`cmacs-transcribe-summarize-at-point' refuses a job that is not done."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (with-temp-buffer
    (cmacs-transcribe-mode)
    (setq-local cmacs-transcribe--jobs
                (list (cmacs-transcribe-job-create
                       :input "/x/a.mp3" :kind 'audio :txt "/x/a.txt" :stage 'transcribing)))
    (cmacs-transcribe--render (current-buffer))
    (cmacs-transcribe-tests--goto-job-line)
    (should-error (cmacs-transcribe-summarize-at-point) :type 'user-error)))

(ert-deftest cmacs-transcribe-test-retroactive-summary ()
  "Retroactive summary (stubbed AI) writes the .org and fires the hook."
  (cmacs-transcribe-tests--skip-unless-loaded)
  (let ((txt (make-temp-file "cmacs-transcribe-test-" nil ".txt"))
        (dir (make-temp-file "cmacs-transcribe-test-out-" t))
        hook-org)
    (unwind-protect
        (let ((cmacs-transcribe-after-summary-functions
               (list (lambda (info) (setq hook-org (plist-get info :org-file))))))
          (with-temp-buffer
            (cmacs-transcribe-mode)
            (setq-local cmacs-transcribe--options
                        (list :naming 'base :output-dir dir :summary-dir dir
                              :summary-type 'general))
            (let ((job (cmacs-transcribe-job-create
                        :input "/x/talk.mp3" :kind 'audio :txt txt :stage 'done
                        :text "hello world transcript" :duration 3)))
              (setq-local cmacs-transcribe--jobs (list job))
              (cmacs-transcribe--render (current-buffer))
              (cmacs-transcribe-tests--goto-job-line)
              (cl-letf (((symbol-function 'cmacs-transcribe--ai-available-p)
                         (lambda () t))
                        ((symbol-function 'cmacs-ai-make-session)
                         (lambda (&rest _) (cons 'client 'session)))
                        ((symbol-function 'cmacs-ai-free-session) #'ignore)
                        ((symbol-function 'cmacs-ai-chat-stream)
                         (lambda (_session _prompt cb)
                           (funcall cb '(:delta "* TL;DR\nStub summary."))
                           (funcall cb '(:end :text "* TL;DR\nStub summary." :stop end)))))
                (cmacs-transcribe-summarize-at-point))
              (let ((org (expand-file-name "talk.org" dir)))
                (should (equal (cmacs-transcribe-job-org job) org))
                (should (file-exists-p org))
                (should (equal hook-org org))
                (let ((content (with-temp-buffer (insert-file-contents org)
                                                 (buffer-string))))
                  (should (string-match-p "Stub summary" content))
                  (should (string-match-p "hello world transcript" content))
                  (should (string-match-p "^\\* Transcript" content)))
                (should (eq (cmacs-transcribe-job-stage job) 'done))))))
      (delete-file txt)
      (ignore-errors (delete-directory dir t)))))

(provide 'cmacs-transcribe-tests)
;;; cmacs-transcribe-tests.el ends here
