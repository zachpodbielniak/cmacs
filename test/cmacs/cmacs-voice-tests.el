;;; cmacs-voice-tests.el --- ERT for the shared voice engine  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The engine's capture, arbitration, push-to-talk, transcription and
;; speech queue, with the audio, whisper and piper primitives stubbed
;; (C DEFUN stubs take &rest), plus the push-to-talk clients ported onto
;; it: cmacs-ai-voice, cmacs-brigade-voice and cmacs-lrg-vr-voice.  No
;; microphone is opened.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-voice)

(defmacro cmacs-voice-tests--with-mic (&rest body)
  "Run BODY with a fake microphone.
Inside BODY: `mic' is the list of chunks the next drains return (pop),
`opened'/`closed' count capture opens/closes, `whispered' collects PCM
sent to whisper and `whisper-reply' is the text it answers with."
  (declare (indent 0))
  `(let ((mic nil) (opened 0) (closed 0) (whispered nil)
         (whisper-reply " hello there ")
         (cmacs-voice--owners nil)
         (cmacs-voice--capture nil)
         (cmacs-voice--timer nil)
         (cmacs-voice--ptt nil)
         (cmacs-voice--tts-queue nil)
         (cmacs-voice--tts-synth nil)
         (cmacs-voice--tts-until 0.0)
         (cmacs-voice-owner-change-functions nil)
         (cmacs-voice-tick-functions nil))
     (cl-letf (((symbol-function 'cmacs-audio--capture-open-1)
                (lambda (&rest _) (cl-incf opened) 'fake-handle))
               ((symbol-function 'cmacs-audio-start) (lambda (&rest _) t))
               ((symbol-function 'cmacs-audio-close)
                (lambda (&rest _) (cl-incf closed) t))
               ((symbol-function 'cmacs-audio-read-pcm)
                (lambda (&rest _) (if mic (pop mic) "")))
               ((symbol-function 'cmacs-whisper-model-path)
                (lambda (&rest _) "/fake/model.bin"))
               ((symbol-function 'cmacs-whisper-transcribe-pcm-async)
                (lambda (_model pcm cb &rest _)
                  (push (copy-sequence pcm) whispered)
                  (funcall cb (list (cons :text whisper-reply))))))
       (unwind-protect (progn ,@body)
         (when (timerp cmacs-voice--timer) (cancel-timer cmacs-voice--timer))))))

(defun cmacs-voice-tests--pcm (n &optional byte)
  "N bytes of fake PCM filled with BYTE (default 7)."
  (make-string n (or byte 7)))

;;;; Arbitration

(ert-deftest cmacs-voice-test-one-capture-many-owners ()
  "The mic opens once for any number of owners and closes with the last."
  (cmacs-voice-tests--with-mic
    (cmacs-voice-acquire 'a :consumer #'ignore)
    (cmacs-voice-acquire 'b :consumer #'ignore)
    (should (= opened 1))
    (should (cmacs-voice-mic-open-p))
    (should (eq (cmacs-voice-owner) 'b))
    (cmacs-voice-release 'b)
    (should (eq (cmacs-voice-owner) 'a))
    (should (= closed 0))
    (cmacs-voice-release 'a)
    (should (= closed 1))
    (should-not (cmacs-voice-mic-open-p))
    (should-not (cmacs-voice-release 'a))))

(ert-deftest cmacs-voice-test-ptt-suspends-the-stream ()
  "Push-to-talk takes the mic from a streaming client and gives it back."
  (cmacs-voice-tests--with-mic
    (let ((stream nil) (events nil) (owners nil))
      (add-hook 'cmacs-voice-owner-change-functions
                (lambda (new _old) (push new owners)))
      (cmacs-voice-acquire 'loop
                           :consumer (lambda (p) (push p stream))
                           :suspend (lambda () (push 'suspend events))
                           :resume (lambda () (push 'resume events)))
      (setq mic (list (cmacs-voice-tests--pcm 100 1)))
      (cmacs-voice--tick)
      (should (= (length stream) 1))
      (cmacs-voice-ptt-start 'talk)
      (should (equal events '(suspend)))
      (should (eq (cmacs-voice-owner) 'talk))
      ;; While push-to-talk records, the stream gets nothing.
      (setq mic (list (cmacs-voice-tests--pcm 200 2) (cmacs-voice-tests--pcm 300 3)))
      (cmacs-voice--tick)
      (should (= (length stream) 1))
      ;; Stop drains the tail into the phrase, then resumes the stream.
      (let ((pcm (cmacs-voice-ptt-stop 'talk)))
        (should (= (length pcm) 500))
        (should (= (aref pcm 0) 2)))
      (should (equal events '(resume suspend)))
      (should (eq (cmacs-voice-owner) 'loop))
      (should (equal owners '(loop talk loop)))
      (should (= opened 1)))))

(ert-deftest cmacs-voice-test-stream-joining-under-ptt-waits ()
  "A streaming client acquiring during push-to-talk starts suspended."
  (cmacs-voice-tests--with-mic
    (let ((events nil))
      (cmacs-voice-ptt-start 'talk)
      (cmacs-voice-acquire 'loop :consumer #'ignore
                           :suspend (lambda () (push 'suspend events))
                           :resume (lambda () (push 'resume events)))
      (should (eq (cmacs-voice-owner) 'talk))
      (should (equal events '(suspend)))
      (cmacs-voice-ptt-cancel 'talk)
      (should (eq (cmacs-voice-owner) 'loop))
      (should (equal events '(resume suspend))))))

(ert-deftest cmacs-voice-test-ptt-preempts-ptt ()
  "A second push-to-talk preempts the first; the default preempt cancels."
  (cmacs-voice-tests--with-mic
    (let ((preempted nil))
      (cmacs-voice-ptt-start 'first :preempt (lambda ()
                                               (setq preempted t)
                                               (cmacs-voice-ptt-cancel 'first)))
      (cmacs-voice-ptt-start 'second)
      (should preempted)
      (should-not (cmacs-voice-ptt-active-p 'first))
      (should (equal (cmacs-voice-owners) '(second)))
      (cmacs-voice-ptt-start 'third)
      (should-not (cmacs-voice-ptt-active-p 'second))
      (should (equal (cmacs-voice-owners) '(third))))))

(ert-deftest cmacs-voice-test-ptt-time-limit ()
  "A push-to-talk past its limit runs its timeout function."
  (cmacs-voice-tests--with-mic
    (let ((timed-out nil))
      (cmacs-voice-ptt-start 'talk :max-seconds 5
                             :on-timeout (lambda () (setq timed-out t)
                                           (cmacs-voice-ptt-cancel 'talk)))
      (setf (plist-get (cdr (assq 'talk cmacs-voice--ptt)) :started)
            (- (float-time) 10))
      (cmacs-voice--tick)
      (should timed-out)
      (should-not (cmacs-voice-ptt-active-p)))))

(ert-deftest cmacs-voice-test-open-failure-leaves-no-owner ()
  "When the mic cannot open, acquiring signals and owns nothing."
  (cmacs-voice-tests--with-mic
    (cl-letf (((symbol-function 'cmacs-audio--capture-open-1)
               (lambda (&rest _) (error "No such device"))))
      (should-error (cmacs-voice-ptt-start 'talk))
      (should-not (cmacs-voice-owners))
      (should-not (cmacs-voice-mic-open-p)))))

(ert-deftest cmacs-voice-test-transcribe-wipes ()
  "Transcription hands whisper the audio and then overwrites it."
  (cmacs-voice-tests--with-mic
    (let ((pcm (cmacs-voice-tests--pcm 64 9)) (got nil))
      (cmacs-voice-transcribe pcm (lambda (r) (setq got r)))
      (should (equal (cdr (assq :text got)) " hello there "))
      (should (= (aref (car whispered) 0) 9))
      (should (cl-every #'zerop pcm)))))

;;;; Speech queue

(ert-deftest cmacs-voice-test-speech-in-order-and-stoppable ()
  "Sentences are synthesised one at a time and a stop drops late ones."
  (let ((pending nil) (played nil)
        (cmacs-voice--tts-queue nil) (cmacs-voice--tts-synth nil)
        (cmacs-voice--tts-until 0.0) (cmacs-voice-speech-functions nil))
    (cl-letf (((symbol-function 'cmacs-piper-supported-p) (lambda (&rest _) t))
              ((symbol-function 'cmacs-piper-voice-path) (lambda (&rest v) (car v)))
              ((symbol-function 'cmacs-piper--voice-sample-rate) (lambda (_) 16000))
              ((symbol-function 'cmacs-piper--ensure-playback) (lambda (_) 1))
              ((symbol-function 'cmacs-piper-stop) #'ignore)
              ((symbol-function 'cmacs-audio-push-pcm)
               (lambda (_h pcm &rest _) (push pcm played)))
              ((symbol-function 'cmacs-piper--synth-async-1)
               (lambda (v text cb &rest _) (push (list text v cb) pending))))
      (cmacs-voice-speak "one.")
      (cmacs-voice-speak "two." "other-voice")
      (should (= (length pending) 1))
      (funcall (nth 2 (pop pending)) "A")
      (should (equal (nth 1 (car pending)) "other-voice"))
      (funcall (nth 2 (pop pending)) "B")
      (should (cmacs-voice-speaking-p))
      (cmacs-voice-speak "three.")
      (cmacs-voice-stop-speaking)
      (funcall (nth 2 (pop pending)) "C")
      (should (equal (reverse played) '("A" "B")))
      (should-not (cmacs-voice-speaking-p)))))

(ert-deftest cmacs-voice-test-phrase-match ()
  "Fuzzy phrase matching is shared by the loop and command routing."
  (should (equal (cmacs-voice-phrase-match "Hey Jervis, lights" "jarvis" 0.75)
                 '(1 2 0.8333333333333334 "jarvis")))
  (should-not (cmacs-voice-phrase-match "travis" "jarvis" 0.75))
  (should (equal (cmacs-voice-words-after "Jarvis, open it." 1) "open it.")))

;;;; The push-to-talk clients

(ert-deftest cmacs-voice-test-brigade-listen-contract ()
  "`cmacs-brigade-voice-listen': one phrase in, one string out, via the engine."
  (skip-unless (require 'cmacs-brigade-voice nil t))
  (cmacs-voice-tests--with-mic
    (let ((heard nil))
      (cl-letf (((symbol-function 'cmacs-brigade-voice-available-p) (lambda () t))
                ((symbol-function 'file-exists-p) (lambda (&rest _) t)))
        (cmacs-brigade-voice-listen "Task" (lambda (s) (setq heard s)))
        (should (cmacs-brigade-voice-recording-p))
        (should (eq (cmacs-voice-owner) 'brigade))
        (setq mic (list (cmacs-voice-tests--pcm 4000)))
        (cmacs-voice--tick)
        (cmacs-brigade-voice-stop)
        (should (equal heard "hello there"))
        (should-not (cmacs-brigade-voice-recording-p))
        (should-not (cmacs-voice-mic-open-p))
        (should-error (cmacs-brigade-voice-stop) :type 'user-error)))))

(ert-deftest cmacs-voice-test-brigade-second-listen-stops-first ()
  "A second listen stops (and transcribes) the first, as before."
  (skip-unless (require 'cmacs-brigade-voice nil t))
  (cmacs-voice-tests--with-mic
    (let ((heard nil))
      (cl-letf (((symbol-function 'cmacs-brigade-voice-available-p) (lambda () t))
                ((symbol-function 'file-exists-p) (lambda (&rest _) t)))
        (cmacs-brigade-voice-listen "One" (lambda (s) (push (cons 1 s) heard)))
        (setq mic (list (cmacs-voice-tests--pcm 4000)))
        (cmacs-voice--tick)
        (cmacs-brigade-voice-listen "Two" (lambda (s) (push (cons 2 s) heard)))
        (should (equal heard '((1 . "hello there"))))
        (should (cmacs-brigade-voice-recording-p))
        (cmacs-voice-ptt-cancel 'brigade)))))

(ert-deftest cmacs-voice-test-ai-voice-dictate-sends ()
  "C-c v c in a voice chat: record, transcribe, send; the reply is queued in order."
  (skip-unless (require 'cmacs-ai-voice nil t))
  (cmacs-voice-tests--with-mic
    (let ((sent nil))
      (with-temp-buffer
        (cl-letf (((symbol-function 'cmacs-voice-available-p) (lambda () t))
                  ((symbol-function 'file-exists-p) (lambda (&rest _) t))
                  ((symbol-function 'cmacs-ai-voice-send)
                   (lambda (text buf) (push (cons text buf) sent))))
          (should (eq (lookup-key cmacs-ai-voice-mode-map (kbd "C-c v c"))
                      #'cmacs-ai-voice-dictate))
          (cmacs-ai-voice-dictate)
          (should (cmacs-ai-voice-recording-p))
          (setq mic (list (cmacs-voice-tests--pcm 8000)))
          (cmacs-voice--tick)
          (cmacs-ai-voice-dictate)
          (should-not (cmacs-ai-voice-recording-p))
          (should (equal (car sent) (cons "hello there" (current-buffer)))))))))

(ert-deftest cmacs-voice-test-ai-voice-speaks-through-the-queue ()
  "Streamed reply sentences go to the engine queue, not to separate piper jobs."
  (skip-unless (require 'cmacs-ai-voice nil t))
  (let ((queued nil) (cmacs-ai-voice-auto-speak t))
    (with-temp-buffer
      (cl-letf (((symbol-function 'cmacs-voice-speak)
                 (lambda (text &rest _) (push text queued)))
                ((symbol-function 'cmacs-ai-chat--stream-callback) #'ignore))
        (let ((b (current-buffer)))
          (cmacs-ai-voice--stream-callback-wrap b '(:start))
          (cmacs-ai-voice--stream-callback-wrap b '(:delta "First. Second! Thi"))
          (cmacs-ai-voice--stream-callback-wrap b '(:delta "rd"))
          (cmacs-ai-voice--stream-callback-wrap b '(:end)))
        (should (equal (reverse queued) '("First." "Second!" "Third")))))))

(ert-deftest cmacs-voice-test-vr-hold-uses-the-engine ()
  "VR push-to-talk records through the engine and keeps its state light."
  (skip-unless (require 'cmacs-lrg-vr-voice nil t))
  (cmacs-voice-tests--with-mic
    (let ((lights nil) (got nil) (cmacs-lrg-vr--deferred nil)
          (unread-command-events nil))
      (cl-letf (((symbol-function 'cmacs-lrg-vr-voice--check) #'ignore)
                ((symbol-function 'cmacs-lrg-vr-voice--light)
                 (lambda (c) (push c lights)))
                ((symbol-function 'cmacs-lrg-vr-voice--buzz) #'ignore))
        (cmacs-lrg-vr-voice-start 'command (lambda (s) (setq got s)) 'right)
        (should (cmacs-lrg-vr-voice-recording-p))
        (should (eq (cmacs-voice-owner) 'vr))
        (setq mic (list (cmacs-voice-tests--pcm 16000)))
        (cmacs-voice--tick)
        (cmacs-lrg-vr-voice-stop)
        (should-not (cmacs-lrg-vr-voice-recording-p))
        ;; red listening, amber transcribing, off when done
        (should (equal (reverse lights) '("#ff3030" "#ffb020" nil)))
        (cmacs-lrg-vr--run-deferred)
        (should (equal got "hello there"))
        ;; a brigade phrase preempts VR: VR's recording is cancelled
        (cmacs-lrg-vr-voice-start 'dictate #'ignore 'left)
        (cmacs-voice-ptt-start 'other)
        (should-not (cmacs-lrg-vr-voice-recording-p))
        (cmacs-voice-ptt-cancel 'other)))))

(provide 'cmacs-voice-tests)

;;; cmacs-voice-tests.el ends here
