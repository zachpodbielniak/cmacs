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

;;;; The engine is the only microphone owner

(defconst cmacs-voice-tests--lisp-dir
  (expand-file-name "../../lisp/cmacs/"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "lisp/cmacs/, found from this file.")

(defun cmacs-voice-tests--calls (file fn)
  "Positions in FILE where code (not a comment or string) calls FN."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (let ((re (concat "(" (regexp-quote (symbol-name fn)) "[ \t\n)]"))
          (found nil))
      (goto-char (point-min))
      (while (re-search-forward re nil t)
        (let ((ppss (save-excursion (syntax-ppss (match-beginning 0)))))
          (unless (or (nth 3 ppss) (nth 4 ppss))
            (push (line-number-at-pos (match-beginning 0)) found))))
      (nreverse found))))

(ert-deftest cmacs-voice-test-engine-is-the-only-mic-owner ()
  "No lisp/cmacs file opens or reads a capture stream but the engine.
The one exception is cmacs-audio.el's file recorder, which records at
any rate and channel count -- and it must hold the engine's mic while
it does.  A voice feature that opens its own capture fights every
other one for the device and lets the always-on loop hear it."
  (let ((offenders nil))
    (dolist (file (directory-files cmacs-voice-tests--lisp-dir t "\\.el\\'"))
      (let ((base (file-name-nondirectory file)))
        (dolist (fn '(cmacs-audio--capture-open-1 cmacs-audio-read-pcm))
          (let ((lines (cmacs-voice-tests--calls file fn)))
            (when (and lines
                       (not (equal base "cmacs-voice.el"))
                       (not (and (equal base "cmacs-audio.el")
                                 (eq fn 'cmacs-audio--capture-open-1))))
              (push (list base fn lines) offenders))))))
    (should-not offenders))
  ;; The recorder holds the engine's mic, and only the recorder opens one.
  (let ((audio (expand-file-name "cmacs-audio.el" cmacs-voice-tests--lisp-dir)))
    (should (= (length (cmacs-voice-tests--calls
                        audio 'cmacs-audio--capture-open-1))
               1))
    (should (cmacs-voice-tests--calls audio 'cmacs-voice-acquire))
    (should (cmacs-voice-tests--calls audio 'cmacs-voice-release))))

(ert-deftest cmacs-voice-test-external-recorder-pauses-the-loop ()
  "A file recording holds the mic: the loop pauses, no engine capture opens."
  (cmacs-voice-tests--with-mic
    (let ((events nil))
      (cmacs-voice-acquire 'loop :consumer #'ignore
                           :suspend (lambda () (push 'suspend events))
                           :resume (lambda () (push 'resume events)))
      (should (= opened 1))
      (cmacs-voice-acquire 'recorder-1 :external t)
      (should (equal events '(suspend)))
      ;; the loop's capture keeps draining, to nobody
      (setq mic (list (cmacs-voice-tests--pcm 100)))
      (cmacs-voice--tick)
      ;; a push-to-talk does not preempt the recorder and is fed
      (cmacs-voice-ptt-start 'talk)
      (should (memq 'recorder-1 (cmacs-voice-owners)))
      (setq mic (list (cmacs-voice-tests--pcm 300)))
      (cmacs-voice--tick)
      (should (= (length (cmacs-voice-ptt-stop 'talk)) 300))
      (should (equal events '(suspend)))
      (cmacs-voice-release 'recorder-1)
      (should (equal events '(resume suspend)))
      (cmacs-voice-release 'loop)
      ;; alone, a recorder opens no engine capture
      (setq opened 0)
      (cmacs-voice-acquire 'recorder-2 :external t)
      (should (= opened 0))
      (should-not (cmacs-voice-mic-open-p))
      (cmacs-voice-release 'recorder-2))))

(ert-deftest cmacs-voice-test-audio-recorder-holds-the-engine ()
  "`cmacs-audio-open-recorder' holds the engine's mic until closed."
  (skip-unless (require 'cmacs-audio nil t))
  (cmacs-voice-tests--with-mic
    (let ((h (cmacs-audio-open-recorder)))
      (should (eq h 'fake-handle))
      (should (memq 'recorder-fake-handle (cmacs-voice-owners)))
      (cmacs-audio-close-recorder h)
      (should-not (cmacs-voice-owners)))))

;;;; Dictation on the engine

(ert-deftest cmacs-voice-test-dictate-inserts-in-order ()
  "C-c v d: windows are transcribed one at a time and inserted in order;
the window in progress shows as a partial overlay meanwhile."
  (skip-unless (require 'cmacs-whisper-dictate nil t))
  (cmacs-voice-tests--with-mic
    (let ((replies (list " Hello there." " General Kenobi." " the rest"
                         " partial words"))
          (pending nil)
          (cmacs-whisper-dictate-window-seconds 1.0)
          (cmacs-whisper-dictate-partial-interval 0.0)
          (cmacs-whisper-dictate--queue nil)
          (cmacs-whisper-dictate--busy nil)
          (cmacs-whisper-dictate--buffer nil))
      (cl-letf (((symbol-function 'file-exists-p) (lambda (&rest _) t))
                ((symbol-function 'cmacs-whisper-dictate--silent-p) #'ignore)
                ((symbol-function 'cmacs-whisper-transcribe-pcm-async)
                 (lambda (_m _pcm cb &rest _) (setq pending (append pending (list cb))))))
        (with-temp-buffer
          (insert "Start.")
          (should (eq (lookup-key cmacs-voice-map "d") #'cmacs-whisper-dictate))
          (cmacs-whisper-dictate)
          (should (memq 'dictate (cmacs-voice-owners)))
          (should (eq cmacs-whisper-dictate--state 'recording))
          ;; two full windows arrive: only one goes to whisper at a time
          (setq mic (list (cmacs-voice-tests--pcm 32000) (cmacs-voice-tests--pcm 32000)))
          (cmacs-voice--tick)
          (should (= (length pending) 1))
          (funcall (pop pending) (list (cons :text (pop replies))))
          (should (= (length pending) 1))
          (funcall (pop pending) (list (cons :text (pop replies))))
          (should (equal (buffer-string) "Start. Hello there. General Kenobi."))
          ;; half a window: a partial shows, not text
          (setq mic (list (cmacs-voice-tests--pcm 20000)))
          (cmacs-voice--tick)
          (should (= (length pending) 1))
          (funcall (pop pending) '((:text . " partial words")))
          (should (string-match-p "partial words"
                                  (overlay-get cmacs-whisper-dictate--overlay
                                               'after-string)))
          (should (equal (buffer-string) "Start. Hello there. General Kenobi."))
          ;; stopping transcribes what is left, then the mic is free
          (cmacs-whisper-dictate)
          (should-not (cmacs-voice-owners))
          (should-not cmacs-whisper-dictate--overlay)
          (funcall (pop pending) (list (cons :text (pop replies))))
          (should (equal (buffer-string)
                         "Start. Hello there. General Kenobi. The rest"))
          (should (eq cmacs-whisper-dictate--state 'idle)))))))

(ert-deftest cmacs-voice-test-dictate-command-words-and-preempt ()
  "Command words still run; a push-to-talk elsewhere ends dictation."
  (skip-unless (require 'cmacs-whisper-dictate nil t))
  (cmacs-voice-tests--with-mic
    (let ((cmacs-whisper-dictate-window-seconds 1.0)
          (cmacs-whisper-dictate-partial-interval nil)
          (cmacs-whisper-dictate--queue nil)
          (cmacs-whisper-dictate--busy nil))
      (cl-letf (((symbol-function 'file-exists-p) (lambda (&rest _) t))
                ((symbol-function 'cmacs-whisper-dictate--silent-p) #'ignore)
                ((symbol-function 'cmacs-whisper-transcribe-pcm-async)
                 (lambda (_m _pcm cb &rest _) (funcall cb '((:text . " New line."))))))
        (with-temp-buffer
          (insert "a")
          (cmacs-whisper-dictate)
          (setq mic (list (cmacs-voice-tests--pcm 32000)))
          (cmacs-voice--tick)
          (should (equal (buffer-string) "a\n"))
          (cmacs-voice-ptt-start 'other)
          (should-not (memq 'dictate (cmacs-voice-owners)))
          (cmacs-voice-ptt-cancel 'other))))))

;;;; Brigade confirmation without blocking

(ert-deftest cmacs-voice-test-brigade-confirm-non-blocking ()
  "With voice in use, a dictated task is confirmed by a spoken yes, not y-or-n-p."
  (skip-unless (and (require 'cmacs-brigade-voice nil t)
                    (require 'cmacs-voice-commands nil t)))
  (let ((queued nil) (asked nil)
        (cmacs-brigade-voice-confirm t)
        (cmacs-voice--confirm nil)
        (cmacs-voice-confirm-destructive t))
    (cl-letf (((symbol-function 'cmacs-brigade-voice--queue)
               (lambda (text agent) (push (list text agent) queued)))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked t) t))
              ((symbol-function 'cmacs-voice-speak) #'ignore))
      ;; voice on: never blocks
      (let ((cmacs-brigade-voice-confirm-style 'voice))
        (cmacs-brigade-voice--confirm-and-queue "survey the notes" 'researcher)
        (should-not asked)
        (should-not queued)
        (should (cmacs-voice-confirm-pending-p))
        (should (eq (cmacs-voice-command-run "yes") 'confirm))
        (should (equal queued '(("survey the notes" researcher))))
        ;; "no" discards
        (cmacs-brigade-voice--confirm-and-queue "something else" nil)
        (cmacs-voice-command-run "no")
        (should (= (length queued) 1)))
      ;; voice off, auto: the old blocking prompt
      (let ((cmacs-brigade-voice-confirm-style 'auto)
            (cmacs-voice-loop-mode nil))
        (cl-letf (((symbol-function 'cmacs-voice-mic-open-p) #'ignore))
          (cmacs-brigade-voice--confirm-and-queue "typed task" nil)
          (should asked)
          (should (= (length queued) 2))))
      ;; auto with the loop on: non-blocking
      (setq asked nil)
      (let ((cmacs-brigade-voice-confirm-style 'auto)
            (cmacs-voice-loop-mode t))
        (cl-letf (((symbol-function 'cmacs-voice-loop--arm) #'ignore))
          (cmacs-brigade-voice--confirm-and-queue "loop task" nil)
          (should-not asked)
          (should (cmacs-voice-confirm-pending-p))
          (setq cmacs-voice--confirm nil))))))

(provide 'cmacs-voice-tests)

;;; cmacs-voice-tests.el ends here
