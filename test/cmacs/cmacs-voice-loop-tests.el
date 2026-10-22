;;; cmacs-voice-loop-tests.el --- ERT for the duplex voice loop  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The loop is driven through `cmacs-voice-loop--ingest' with synthetic
;; PCM -- silence and tones -- so no microphone is needed.  Whisper and
;; piper are stubbed for the state-machine tests; the tests that use
;; the real engines skip when the models are not installed, and nothing
;; here downloads anything.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(when (cmacs-feature-p 'whisper)
  (require 'cmacs-whisper)
  (require 'cmacs-voice-loop))

(defun cmacs-voice-loop-tests--available-p ()
  "Non-nil when the loop and its C primitives are in this build."
  (and (featurep 'cmacs-voice-loop) (fboundp 'cmacs-whisper-pcm-levels)))

;;;; Synthetic audio

(defun cmacs-voice-loop-tests--silence (ms)
  "MS milliseconds of digital silence at 16 kHz, S16LE."
  (make-string (* 2 (/ (* 16 ms) 1)) 0))

(defun cmacs-voice-loop-tests--tone (ms &optional amplitude hz)
  "MS milliseconds of a sine at HZ (440) and AMPLITUDE (0.3), S16LE 16 kHz."
  (let* ((n (* 16 ms))
         (amp (or amplitude 0.3))
         (hz (or hz 440))
         (s (make-string (* 2 n) 0)))
    (dotimes (i n)
      (let* ((v (round (* amp 32767 (sin (/ (* 2 float-pi hz i) 16000.0)))))
             (u (logand v #xffff)))
        (aset s (* 2 i) (logand u 255))
        (aset s (1+ (* 2 i)) (ash u -8))))
    s))

(defun cmacs-voice-loop-tests--feed (&rest pieces)
  "Ingest PIECES of PCM in 100 ms slices, as the drain timer would."
  (dolist (p pieces)
    (let ((i 0) (step 3200))
      (while (< i (length p))
        (cmacs-voice-loop--ingest (substring p i (min (length p) (+ i step))))
        (cmacs-voice-loop--housekeeping)
        (setq i (+ i step))))))

;;;; Harness

(defmacro cmacs-voice-loop-tests--with-loop (replies &rest body)
  "Run BODY with the loop in `listening' and the engines stubbed.
REPLIES maps a model role (`wake', `partial', `final') to the text the
stubbed whisper returns.  Inside BODY: `sent' collects what the loop
sent, `transcribed' the roles it asked whisper for, `states' every
state change (newest first), `stopped' whether piper was stopped."
  (declare (indent 1))
  `(let ((sent nil) (transcribed nil) (states nil) (stopped nil)
         (cmacs-voice-loop-mode t)
         (cmacs-voice-loop-wake-phrase "jarvis")
         (cmacs-voice-loop-partial-interval nil)
         (cmacs-voice-loop-partial-display nil)
         (cmacs-voice-loop-save-directory nil)
         (cmacs-voice-loop-tts-gating 'threshold)
         (cmacs-voice-loop-barge-in t)
         (cmacs-voice-loop-state-change-functions nil)
         (cmacs-voice-loop--state 'listening)
         (cmacs-voice-loop--vad nil)
         (cmacs-voice-loop--last-sent-seg 0)
         (cmacs-voice-loop--tts-until 0.0)
         (cmacs-voice-loop--tts-queue nil)
         (cmacs-voice-loop--chat-buffer nil))
     (cmacs-voice-loop--reset-state)
     (add-hook 'cmacs-voice-loop-state-change-functions
               (lambda (new _old) (push new states)))
     (cl-letf* ((cmacs-voice-loop-send-function
                 (lambda (text) (push text sent)))
                ((symbol-function 'cmacs-voice-loop--model-path)
                 (lambda (which) (symbol-name which)))
                ((symbol-function 'cmacs-whisper-transcribe-pcm-async)
                 (lambda (model pcm callback &rest _)
                   (should (> (length pcm) 0))
                   (push (intern model) transcribed)
                   (funcall callback
                            (list (cons :text (or (alist-get (intern model) ,replies)
                                                  ""))))))
                ((symbol-function 'cmacs-piper-stop)
                 (lambda (&rest _) (setq stopped t))))
       (unwind-protect (progn ,@body)
         (cmacs-voice-loop--reset-state)))))

;;;; Wake phrase

(ert-deftest cmacs-voice-loop-test-wake-match ()
  "The wake phrase is found fuzzily, by word, and glued across a split."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((cmacs-voice-loop-wake-phrase "jarvis")
        (cmacs-voice-loop-wake-threshold 0.75))
    (should (equal (butlast (cmacs-voice-loop-wake-match "Jarvis, what time is it?")) '(0 1)))
    (should (equal (butlast (cmacs-voice-loop-wake-match "hey jervis open it")) '(1 2)))
    (should (equal (butlast (cmacs-voice-loop-wake-match "Jar vis, lights on")) '(0 2)))
    (should-not (cmacs-voice-loop-wake-match "travis scott is playing"))
    (should-not (cmacs-voice-loop-wake-match "what time is it"))
    (should-not (cmacs-voice-loop-wake-match ""))
    (should (equal (cmacs-voice-loop-strip-wake "Jarvis, what time is it?")
                   "what time is it?"))
    (should (equal (cmacs-voice-loop-strip-wake "OK. Jarvis... open the door.")
                   "open the door."))
    (should-not (cmacs-voice-loop-strip-wake "Jarvis."))
    ;; Final model spelled it differently: drop the words the wake model
    ;; said the phrase covered.
    (should (equal (cmacs-voice-loop-strip-wake "Charles, what is it" 1)
                   "what is it"))))

(ert-deftest cmacs-voice-loop-test-wake-phrase-multiword ()
  "A two-word phrase matches as a run of two words."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((cmacs-voice-loop-wake-phrase "hey computer"))
    (should (equal (butlast (cmacs-voice-loop-wake-match "Hey, computer! Status.")) '(0 2)))
    (should-not (cmacs-voice-loop-wake-match "computer status"))
    (should (equal (cmacs-voice-loop-strip-wake "hey computer status report")
                   "status report"))))

(ert-deftest cmacs-voice-loop-test-clean ()
  "Whisper's annotations are not words."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (should (equal (cmacs-voice-loop--clean " [BLANK_AUDIO] (music)  hello\n there ")
                 "hello there")))

;;;; PCM primitives

(ert-deftest cmacs-voice-loop-test-pcm-levels ()
  "Silence is -120 dBFS, a 0.5 sine about -9 dBFS, one value per window."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((sil (cmacs-whisper-pcm-levels (cmacs-voice-loop-tests--silence 64)))
        (tone (cmacs-whisper-pcm-levels (cmacs-voice-loop-tests--tone 64 0.5))))
    (should (= (length sil) 2))
    (should (= (aref sil 0) -120.0))
    (should (= (length tone) 2))
    (should (< -10.0 (aref tone 0) -8.0))
    ;; A trailing partial window is ignored; a custom window size works.
    (should (= (length (cmacs-whisper-pcm-levels (make-string 1500 0))) 1))
    (should (= (length (cmacs-whisper-pcm-levels (make-string 1600 0) 100)) 8))
    (should-error (cmacs-whisper-pcm-levels "" 0))))

(ert-deftest cmacs-voice-loop-test-pcm-resample ()
  "Resampling scales the length and keeps a constant signal constant."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let* ((in (apply #'unibyte-string (cl-loop repeat 2205 append '(#x10 #x27))))
         (out (cmacs-whisper-pcm-resample in 22050 16000)))
    (should (= (length out) (* 2 1600)))
    (should (equal (substring out 100 104) (unibyte-string #x10 #x27 #x10 #x27)))
    (should (equal (cmacs-whisper-pcm-resample in 16000 16000) in))
    (should-error (cmacs-whisper-pcm-resample in 0 16000))))

(ert-deftest cmacs-voice-loop-test-vad-api-errors ()
  "A missing VAD model or an unknown handle is an error, not a crash."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (should-error (cmacs-whisper-vad-open "/nonexistent/ggml-silero.bin"))
  (should-error (cmacs-whisper-vad-feed 987654 (make-string 1024 0) #'ignore))
  (should-not (cmacs-whisper-vad-close 987654))
  (should-not (cmacs-whisper-vad-reset 987654)))

;;;; The segmenter and the wake word

(ert-deftest cmacs-voice-loop-test-energy-detector ()
  "The energy detector calls a tone speech and silence not."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((cmacs-voice-loop--noise-db -70.0))
    (should (= (cmacs-voice-loop--energy-prob -120.0) 0.0))
    (should (>= (cmacs-voice-loop--energy-prob -12.0) 0.99))
    ;; The floor adapts to steady quiet noise rather than calling it speech.
    (dotimes (_ 200) (cmacs-voice-loop--energy-prob -45.0))
    (should (< (cmacs-voice-loop--energy-prob -45.0) 0.5))))

(ert-deftest cmacs-voice-loop-test-wake-then-send ()
  "\"Jarvis, ...\" in one breath: wake model hears it, final model's text goes."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop
      '((wake . " Jarvis, what is the time?")
        (final . " Jarvis, what is the time?"))
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--silence 500)
                                  (cmacs-voice-loop-tests--tone 1200)
                                  (cmacs-voice-loop-tests--silence 1000))
    (should (equal transcribed '(final wake)))
    (should (equal sent '("what is the time?")))
    (should (memq 'hearing states))
    (should (memq 'thinking states))
    ;; The stub sender started no reply, so the loop is back to
    ;; listening -- with the follow-up window open.
    (should (eq (car states) 'listening))
    (should (cmacs-voice-loop--armed-p))))

(ert-deftest cmacs-voice-loop-test-no-wake-is-dropped ()
  "Speech without the wake phrase is transcribed once, then forgotten."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((wake . " pass the salt please"))
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 900)
                                  (cmacs-voice-loop-tests--silence 1000))
    (should (equal transcribed '(wake)))
    (should-not sent)
    (should (eq (cmacs-voice-loop-state) 'listening))
    (should-not cmacs-voice-loop--segment)))

(ert-deftest cmacs-voice-loop-test-noise-burst-ignored ()
  "A burst shorter than `cmacs-voice-loop-min-speech-ms' never reaches whisper."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((wake . "jarvis"))
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 96)
                                  (cmacs-voice-loop-tests--silence 1000))
    (should-not transcribed)
    (should (eq (cmacs-voice-loop-state) 'listening))))

(ert-deftest cmacs-voice-loop-test-bare-wake-arms ()
  "A bare \"Jarvis\" arms the loop; the next utterance needs no phrase."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop
      '((wake . "Jarvis.") (final . " Turn on the lights."))
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 600)
                                  (cmacs-voice-loop-tests--silence 1000))
    (should-not sent)
    (should (cmacs-voice-loop--armed-p))
    (setq transcribed nil)
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 900)
                                  (cmacs-voice-loop-tests--silence 1000))
    ;; Armed: straight to the final model, the wake model is not asked.
    (should (equal transcribed '(final)))
    (should (equal sent '("Turn on the lights.")))))

(ert-deftest cmacs-voice-loop-test-follow-up-window ()
  "After a reply no wake phrase is needed until the window closes."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((final . " and tomorrow?"))
    (cmacs-voice-loop--arm 5)
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 700)
                                  (cmacs-voice-loop-tests--silence 1000))
    (should (equal sent '("and tomorrow?")))
    ;; An expired window closes.
    (setq cmacs-voice-loop--armed-until (- (float-time) 1))
    (cmacs-voice-loop--housekeeping)
    (should-not (cmacs-voice-loop--armed-p))))

(ert-deftest cmacs-voice-loop-test-open-mic ()
  "With no wake phrase every utterance is sent."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((final . " hello there"))
    (let ((cmacs-voice-loop-wake-phrase nil))
      (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 700)
                                    (cmacs-voice-loop-tests--silence 1000))
      (should (equal sent '("hello there"))))))

(ert-deftest cmacs-voice-loop-test-max-utterance ()
  "An utterance that never pauses is cut at the limit and still handled."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((final . " a very long ramble"))
    (let ((cmacs-voice-loop-max-utterance-seconds 1))
      (cmacs-voice-loop--arm 30)
      (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 1500))
      (should (equal sent '("a very long ramble"))))))

(ert-deftest cmacs-voice-loop-test-partial-spots-wake ()
  "A partial transcript that holds the phrase addresses the segment early."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop
      '((partial . " Jarvis open the") (final . " Jarvis, open the pod bay doors."))
    (let ((cmacs-voice-loop-partial-interval 0.0)
          (partials nil))
      (add-hook 'cmacs-voice-loop-partial-functions
                (lambda (p) (push p partials)))
      (unwind-protect
          (progn
            (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 1500))
            (should cmacs-voice-loop--addressed)
            (should (member "open the" partials))
            (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--silence 1000))
            ;; Addressed during speech: the final model alone decides.
            (should (equal (car transcribed) 'final))
            (should-not (memq 'wake transcribed))
            (should (equal sent '("open the pod bay doors."))))
        (setq cmacs-voice-loop-partial-functions nil)))))

;;;; Barge-in and self-echo gating

(ert-deftest cmacs-voice-loop-test-barge-in ()
  "Talking over the reply stops piper and starts a new utterance."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((final . " no, stop, the other one"))
    (setq cmacs-voice-loop--state 'speaking
          cmacs-voice-loop--tts-until (+ (float-time) 30))
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 500 0.5))
    (should stopped)
    (should cmacs-voice-loop--barged)
    (should (eq (cmacs-voice-loop-state) 'hearing))
    (should-not (cmacs-voice-loop--tts-active-p))
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--silence 1000))
    ;; Interrupting counts as addressing the loop.
    (should (equal sent '("no, stop, the other one")))))

(ert-deftest cmacs-voice-loop-test-tts-threshold-gates-echo ()
  "Under `threshold' gating a quiet echo of the reply does not barge in."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((final . "echo"))
   (let ((cmacs-voice-loop-energy-floor-db cmacs-voice-loop-energy-floor-db))
    (setq cmacs-voice-loop--state 'speaking
          cmacs-voice-loop--tts-until (+ (float-time) 30)
          cmacs-voice-loop--noise-db -70.0
          cmacs-voice-loop-energy-floor-db -70.0)
    ;; -70 + 12 = -58 dB is p 0.5; an echo near -53 dB is p ~0.75, over
    ;; the normal threshold but under the raised one.
    (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 800 0.003))
    (should-not stopped)
    (should (eq (cmacs-voice-loop-state) 'speaking))
    (should-not transcribed))))

(ert-deftest cmacs-voice-loop-test-mute-gating ()
  "Under `mute' gating the microphone is ignored while the loop speaks."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cmacs-voice-loop-tests--with-loop '((final . "x"))
    (let ((cmacs-voice-loop-tts-gating 'mute))
      (setq cmacs-voice-loop--state 'speaking
            cmacs-voice-loop--tts-until (+ (float-time) 30))
      (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 800 0.5)
                                    (cmacs-voice-loop-tests--silence 800))
      (should-not stopped)
      (should-not cmacs-voice-loop--in-speech)
      (should-not transcribed))))

;;;; Speaking the reply

(ert-deftest cmacs-voice-loop-test-reply-spoken-in-order ()
  "Streamed sentences are synthesised one at a time and played in order."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((pushed nil) (pending nil)
        (cmacs-voice-loop-mode t)
        (cmacs-voice-loop-speak t)
        (cmacs-voice-loop--state 'thinking)
        (cmacs-voice-loop--tts-queue nil)
        (cmacs-voice-loop--tts-synth nil)
        (cmacs-voice-loop--tts-until 0.0)
        (cmacs-voice-loop--tts-tail "")
        (buf (generate-new-buffer " *voice-chat*")))
    (unwind-protect
        (cl-letf (((symbol-function 'cmacs-piper-supported-p) (lambda () t))
                  ((symbol-function 'cmacs-piper-voice-path) (lambda (&rest _) "v"))
                  ((symbol-function 'cmacs-piper--voice-sample-rate) (lambda (_) 16000))
                  ((symbol-function 'cmacs-piper--ensure-playback) (lambda (_) 1))
                  ((symbol-function 'cmacs-piper-stop) #'ignore)
                  ((symbol-function 'cmacs-audio-push-pcm)
                   (lambda (_h pcm) (push pcm pushed)))
                  ;; Synthesis completes when the test says so, out of order
                  ;; if it were allowed to overlap.
                  ((symbol-function 'cmacs-piper--synth-async-1)
                   (lambda (_v text cb &rest _) (push (cons text cb) pending))))
          (let ((cmacs-voice-loop--chat-buffer buf))
            (cmacs-voice-loop--stream-tap buf '(:start))
            (cmacs-voice-loop--stream-tap buf '(:delta "First one. Second"))
            (cmacs-voice-loop--stream-tap buf '(:delta " one! Third"))
            (cmacs-voice-loop--stream-tap buf '(:end :stop end-turn))
            ;; One synthesis at a time.
            (should (= (length pending) 1))
            (should (equal (caar pending) "First one."))
            (funcall (cdr (pop pending)) "A")
            (should (eq (cmacs-voice-loop-state) 'speaking))
            (should (equal (caar pending) "Second one!"))
            (funcall (cdr (pop pending)) "B")
            (should (equal (caar pending) "Third"))
            ;; A barge-in now: the late result must not play.
            (cmacs-voice-loop-stop-speaking)
            (funcall (cdr (pop pending)) "C")
            (should (equal (reverse pushed) '("A" "B")))
            (should-not cmacs-voice-loop--stream-open)))
      (kill-buffer buf))))

(ert-deftest cmacs-voice-loop-test-speakable ()
  "Org/markdown markup is not read aloud."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (should (equal (cmacs-voice-loop--speakable "*Bold* and =code= [[https://x][a link]].")
                 "Bold and code a link.")))

;;;; Helpers

(ert-deftest cmacs-voice-loop-test-echo-cancel-config ()
  "The echo-cancel helper describes a PipeWire module and writes nothing."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((text (cmacs-voice-loop-echo-cancel-config)))
    (should (string-match-p "libpipewire-module-echo-cancel" text))
    (should (string-match-p "cmacs-echo-cancel-source" text))
    (should (string-match-p "monitor.mode = true" text))
    (should-not (file-exists-p
                 (expand-file-name cmacs-voice-loop-echo-cancel-file)))
    (when (get-buffer "*cmacs-voice-loop echo-cancel*")
      (kill-buffer "*cmacs-voice-loop echo-cancel*"))))

(ert-deftest cmacs-voice-loop-test-wav-writer ()
  "A saved utterance is a 16 kHz mono 16-bit WAV."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((f (make-temp-file "voice-loop" nil ".wav")))
    (unwind-protect
        (progn
          (cmacs-voice-loop--write-wav (make-string 3200 0) f)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally f)
            (should (= (buffer-size) (+ 44 3200)))
            (should (equal (buffer-substring 1 5) "RIFF"))
            (should (equal (buffer-substring 9 17) "WAVEfmt "))
            ;; sample rate field: 16000 = 0x3e80
            (should (equal (buffer-substring 25 29) (unibyte-string #x80 #x3e 0 0)))))
      (delete-file f))))

(ert-deftest cmacs-voice-loop-test-refuses-without-model ()
  "Enabling with no whisper model fails cleanly and leaves the mode off."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (cl-letf (((symbol-function 'cmacs-voice-loop--model-path)
             (lambda (_) "/nonexistent/ggml-none.bin")))
    (should-error (cmacs-voice-loop-mode 1) :type 'user-error)
    (should-not cmacs-voice-loop-mode)
    (should (eq (cmacs-voice-loop-state) 'idle))
    (should-not cmacs-voice-loop--capture)))

;;;; Real engines (skip when models are absent)

(ert-deftest cmacs-voice-loop-test-vad-worker-bad-model ()
  "The VAD worker round-trip: a file that is not a model reports :error.
Exercises the queue, the off-thread load, the main-thread callback and
close, which need no real model; and the loop then falls back to the
energy detector rather than going deaf."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((f (make-temp-file "not-a-vad-model" nil ".bin" "garbage, not ggml")))
    (unwind-protect
        (let* ((h (cmacs-whisper-vad-open f))
               (results nil))
          (should (memq h (cmacs-whisper-vad-list)))
          ;; Two feeds and a reset, answered in order; empty PCM is fine.
          (cmacs-whisper-vad-feed h "" (lambda (r) (push (cons 'empty r) results)))
          (cmacs-whisper-vad-reset h)
          (cmacs-whisper-vad-feed h (cmacs-voice-loop-tests--silence 64)
                                  (lambda (r) (push (cons 'pcm r) results)))
          (should (cmacs-voice-loop-tests--wait (lambda () (= (length results) 2)) 30))
          (should (equal (mapcar #'car results) '(pcm empty)))
          (should (equal (cdr (assq :probs (cdr (assq 'empty results)))) []))
          (should (assq :error (cdr (assq 'pcm results))))
          (should (cmacs-whisper-vad-close h))
          (should-not (memq h (cmacs-whisper-vad-list)))
          (should-error (cmacs-whisper-vad-feed h "" #'ignore))
          ;; The loop: a VAD that fails hands its audio to the energy path.
          (cmacs-voice-loop-tests--with-loop '((final . " still hears you"))
            (setq cmacs-voice-loop--vad (cmacs-whisper-vad-open f))
            (cmacs-voice-loop--arm 30)
            (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--tone 700))
            (should (cmacs-voice-loop-tests--wait
                     (lambda () (null cmacs-voice-loop--vad)) 30))
            (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--silence 1000))
            (should (cmacs-voice-loop-tests--wait (lambda () sent) 30))
            (should (equal sent '("still hears you")))))
      (delete-file f))))

(defun cmacs-voice-loop-tests--wait (pred seconds)
  "Spin the event loop until PRED is non-nil or SECONDS pass."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest cmacs-voice-loop-test-real-vad ()
  "Silero answers one probability per window, low for silence."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((model (cmacs-whisper-model-path cmacs-whisper-default-vad-model)))
    (skip-unless (file-exists-p model))
    (let* ((h (cmacs-whisper-vad-open model))
           (res nil))
      (unwind-protect
          (progn
            (cmacs-whisper-vad-feed h (cmacs-voice-loop-tests--silence 320)
                                    (lambda (r) (setq res r)))
            (should (cmacs-voice-loop-tests--wait (lambda () res) 30))
            (should-not (assq :error res))
            (should (= (length (cdr (assq :probs res))) 10))
            (should (< (aref (cdr (assq :probs res)) 0) 0.5)))
        (cmacs-whisper-vad-close h)))))

(ert-deftest cmacs-voice-loop-test-parallel-transcriptions ()
  "Overlapping transcriptions on one model both complete (private states)."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (let ((model (cmacs-whisper-model-path)))
    (skip-unless (file-exists-p model))
    (let ((done nil)
          (pcm (cmacs-voice-loop-tests--silence 1000)))
      (dotimes (_ 3)
        (cmacs-whisper-transcribe-pcm-async
         model pcm (lambda (r) (push r done)) "en" 2))
      (should (cmacs-voice-loop-tests--wait (lambda () (= (length done) 3)) 180))
      (dolist (r done) (should-not (assq :error r))))))

(ert-deftest cmacs-voice-loop-test-end-to-end-speech ()
  "Piper says \"Jarvis, ...\"; the real loop hears it and sends the request."
  (skip-unless (cmacs-voice-loop-tests--available-p))
  (skip-unless (and (fboundp 'cmacs-piper-supported-p) (cmacs-piper-supported-p)
                    (require 'cmacs-piper nil t)))
  (skip-unless (file-exists-p (cmacs-piper-voice-path)))
  (skip-unless (file-exists-p (cmacs-whisper-model-path)))
  (let* ((voice (cmacs-piper-voice-path))
         (raw (condition-case nil
                  (cmacs-piper--synth-sync-1
                   voice "Jarvis, what is the capital of France?")
                (error nil))))
    (skip-unless (and raw (> (length raw) 0)))
    (let* ((speech (cmacs-whisper-pcm-resample
                    raw (cmacs-piper--voice-sample-rate voice) 16000))
           (sent nil)
           (cmacs-voice-loop-mode t)
           (cmacs-voice-loop-wake-phrase "jarvis")
           (cmacs-voice-loop-partial-interval nil)
           (cmacs-voice-loop-partial-display nil)
           (cmacs-voice-loop-send-function (lambda (text) (push text sent)))
           (cmacs-voice-loop--state 'listening)
           (cmacs-voice-loop--vad nil)
           (cmacs-voice-loop--last-sent-seg 0))
      (cmacs-voice-loop--reset-state)
      (unwind-protect
          (progn
            (cmacs-voice-loop-tests--feed (cmacs-voice-loop-tests--silence 600)
                                          speech
                                          (cmacs-voice-loop-tests--silence 1200))
            (should (cmacs-voice-loop-tests--wait (lambda () sent) 240))
            (should (string-match-p "capital" (downcase (car sent))))
            (should-not (string-match-p "jarvis" (downcase (car sent)))))
        (cmacs-voice-loop--reset-state)))))

(provide 'cmacs-voice-loop-tests)

;;; cmacs-voice-loop-tests.el ends here
