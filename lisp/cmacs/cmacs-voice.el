;;; cmacs-voice.el --- One voice engine: the microphone, the speaker  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of cmacs, a fork of GNU Emacs.

;;; Commentary:

;; The machinery every voice feature in cmacs shares, so that there is
;; exactly one owner of the microphone and one queue in front of the
;; speaker:
;;
;; - Capture with arbitration.  `cmacs-voice-acquire' takes the mic for
;;   a client; the engine opens one 16 kHz capture stream and hands each
;;   drained chunk to the client on top.  A push-to-talk client
;;   (`:exclusive') takes the mic from a streaming one -- the always-on
;;   loop -- which is told to `:suspend' and later to `:resume' when the
;;   push-to-talk client releases it.  A second push-to-talk client
;;   preempts the first (`:preempt'), which is what a push-to-talk key is
;;   expected to do.
;; - Push-to-talk on top of that: `cmacs-voice-ptt-start' /
;;   `-ptt-stop' (returns the audio) / `-ptt-cancel', with a backstop
;;   length.
;; - Transcription: `cmacs-voice-transcribe', async whisper that wipes
;;   the audio once whisper has its copy.
;; - Detection: one VAD stream (Silero through `cmacs-whisper-vad-feed')
;;   or an adaptive energy detector, turning PCM into 32 ms frames with
;;   a speech probability each.
;; - Speech: `cmacs-voice-speak' queues text for piper, synthesising one
;;   sentence at a time so they play in order, and
;;   `cmacs-voice-stop-speaking' drops everything queued -- including a
;;   sentence still being synthesised -- for barge-in.
;;
;; Clients: `cmacs-voice-loop-mode' (streaming), and push-to-talk in
;; cmacs-ai-voice.el, cmacs-lrg-vr-voice.el and cmacs-brigade-voice.el.
;; `cmacs-whisper-dictate' keeps its own capture on purpose: it streams
;; text into a buffer and predates this engine.
;;
;; Everything here runs on the main thread: timers drain the mic, and
;; whisper/VAD/piper results arrive through their async callbacks.
;; Audio is held only in memory and overwritten once used.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-audio--capture-open-1 "cmacs-audio-defuns.c" (&rest plist))
(declare-function cmacs-audio-start "cmacs-audio-defuns.c" (handle))
(declare-function cmacs-audio-close "cmacs-audio-defuns.c" (handle))
(declare-function cmacs-audio-read-pcm "cmacs-audio-defuns.c" (handle n))
(declare-function cmacs-audio-push-pcm "cmacs-audio-defuns.c" (handle pcm))
(declare-function cmacs-whisper-supported-p "cmacs-whisper-defuns.c")
(declare-function cmacs-whisper-transcribe-pcm-async "cmacs-whisper-defuns.c"
                  (model pcm callback &optional language threads))
(declare-function cmacs-whisper-vad-open "cmacs-whisper-defuns.c"
                  (model &optional threads))
(declare-function cmacs-whisper-vad-feed "cmacs-whisper-defuns.c"
                  (handle pcm callback))
(declare-function cmacs-whisper-vad-close "cmacs-whisper-defuns.c" (handle))
(declare-function cmacs-whisper-pcm-levels "cmacs-whisper-defuns.c"
                  (pcm &optional window))
(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(declare-function cmacs-piper-supported-p "cmacs-piper-defuns.c")
(declare-function cmacs-piper--synth-async-1 "cmacs-piper-defuns.c"
                  (model text callback &optional binary))
(declare-function cmacs-piper-voice-path "cmacs-piper" (&optional name))
(declare-function cmacs-piper--voice-sample-rate "cmacs-piper" (voice))
(declare-function cmacs-piper--ensure-playback "cmacs-piper" (rate))
(declare-function cmacs-piper-stop "cmacs-piper")
(defvar cmacs-audio-capture-source)
(defvar cmacs-audio-default-device)
(defvar cmacs-whisper-language)
(defvar cmacs-whisper-default-vad-model)


;;;; Customization
;;
;; Several of these were `cmacs-voice-loop-*' options before the engine
;; was shared.  The aliases come first so a value set under the old name
;; before this file loaded is carried over.

(define-obsolete-variable-alias 'cmacs-voice-loop-device
  'cmacs-voice-device "cmacs 2026-10")
(define-obsolete-variable-alias 'cmacs-voice-loop-poll-interval
  'cmacs-voice-poll-interval "cmacs 2026-10")
(define-obsolete-variable-alias 'cmacs-voice-loop-threads
  'cmacs-voice-threads "cmacs 2026-10")
(define-obsolete-variable-alias 'cmacs-voice-loop-vad-model
  'cmacs-voice-vad-model "cmacs 2026-10")
(define-obsolete-variable-alias 'cmacs-voice-loop-energy-floor-db
  'cmacs-voice-energy-floor-db "cmacs 2026-10")
(define-obsolete-variable-alias 'cmacs-voice-loop-energy-margin-db
  'cmacs-voice-energy-margin-db "cmacs 2026-10")
(define-obsolete-variable-alias 'cmacs-voice-loop-voice
  'cmacs-voice-voice "cmacs 2026-10")

(defgroup cmacs-voice nil
  "The shared voice engine: one microphone owner, one speech queue."
  :group 'cmacs-whisper
  :prefix "cmacs-voice-")

(defcustom cmacs-voice-device nil
  "Capture device for every voice feature, or nil for `cmacs-audio-default-device'.
Under PipeWire this is a node name -- \"cmacs-echo-cancel-source\" once
the config from `cmacs-voice-loop-echo-cancel-config' is installed."
  :type '(choice (const nil) string))

(defcustom cmacs-voice-poll-interval 0.1
  "Seconds between microphone drains."
  :type 'number)

(defcustom cmacs-voice-threads nil
  "CPU threads whisper may use per transcription, or nil for all."
  :type '(choice (const :tag "All" nil) integer))

(defcustom cmacs-voice-vad-model nil
  "Silero VAD model (ggml) basename, resolved like whisper models.
nil means `cmacs-whisper-default-vad-model'.  When the file is absent
the energy detector is used; get the model with
\\[cmacs-whisper-download-vad-model]."
  :type '(choice (const :tag "Default VAD model" nil) string))

(defcustom cmacs-voice-energy-floor-db -50.0
  "Energy detector: frames quieter than this (dBFS) are never speech."
  :type 'number)

(defcustom cmacs-voice-energy-margin-db 12.0
  "Energy detector: how far above the noise floor speech must be."
  :type 'number)

(defcustom cmacs-voice-voice nil
  "Piper voice basename for spoken output, or nil for `cmacs-piper-default-voice'."
  :type '(choice (const nil) string))

(defcustom cmacs-voice-ptt-stops-speech t
  "Non-nil: starting push-to-talk silences whatever is being spoken."
  :type 'boolean)

(defvar cmacs-voice-owner-change-functions nil
  "Abnormal hook run with (NEW-OWNER OLD-OWNER) when the mic changes hands.
Owners are the symbols clients acquire with; nil means nobody.")

(defvar cmacs-voice-tick-functions nil
  "Functions run after every microphone drain, while the mic is open.")

(defvar cmacs-voice-speech-functions nil
  "Abnormal hook run with (TEXT SECONDS) when speech starts playing.")


;;;; Constants

(defconst cmacs-voice-rate 16000 "Capture rate; whisper wants 16 kHz.")
(defconst cmacs-voice-window 512 "Samples per detection frame.")
(defconst cmacs-voice-frame-bytes (* 2 512) "Bytes per detection frame.")
(defconst cmacs-voice-frame-ms 32.0 "Milliseconds per detection frame.")


;;;; Availability

(defun cmacs-voice-available-p ()
  "Non-nil when this build can capture and transcribe speech."
  (and (fboundp 'cmacs-audio--capture-open-1)
       (fboundp 'cmacs-whisper-supported-p)
       (cmacs-whisper-supported-p)
       (or (fboundp 'cmacs-whisper-model-path) (require 'cmacs-whisper nil t))
       (or (boundp 'cmacs-audio-capture-source) (require 'cmacs-audio nil t))
       t))

(defun cmacs-voice-speech-available-p ()
  "Non-nil when piper can speak."
  (and (fboundp 'cmacs-piper-supported-p)
       (cmacs-piper-supported-p)
       (or (fboundp 'cmacs-piper-voice-path) (require 'cmacs-piper nil t))
       t))


;;;; Wiping

(defun cmacs-voice-wipe (&rest strings)
  "Overwrite each PCM string in STRINGS (lists of strings are walked)."
  (dolist (s strings)
    (cond ((stringp s) (fillarray s 0))
          ((consp s) (apply #'cmacs-voice-wipe s)))))


;;;; Capture and arbitration

(defvar cmacs-voice--owners nil
  "Mic owners, the current one first.  Each is a plist with :id,
:consumer, :suspend, :resume, :preempt and :exclusive.")
(defvar cmacs-voice--capture nil "The one capture handle, while anyone owns the mic.")
(defvar cmacs-voice--timer nil "The drain timer.")

(defun cmacs-voice-owner ()
  "The id of the client the microphone feeds right now, or nil."
  (plist-get (car cmacs-voice--owners) :id))

(defun cmacs-voice-owners ()
  "Every client holding the mic, the one being fed first."
  (mapcar (lambda (o) (plist-get o :id)) cmacs-voice--owners))

(defun cmacs-voice-mic-open-p ()
  "Non-nil while the microphone is open."
  (and cmacs-voice--capture t))

(defun cmacs-voice--entry (id)
  "The owner entry for ID, or nil."
  (cl-find id cmacs-voice--owners :key (lambda (o) (plist-get o :id))))

(defun cmacs-voice--call (entry key)
  "Call ENTRY's KEY function, if any, never letting it signal."
  (when-let* ((fn (plist-get entry key)))
    (condition-case err (funcall fn)
      (error (message "Voice: %s %s: %s" (plist-get entry :id) key
                      (error-message-string err))))))

(defun cmacs-voice--open-capture ()
  "Open the capture stream and the drain timer, if not open already."
  (unless cmacs-voice--capture
    (require 'cmacs-audio)
    (let ((h (cmacs-audio--capture-open-1
              :source cmacs-audio-capture-source
              :rate cmacs-voice-rate
              :channels 1
              :device (or cmacs-voice-device cmacs-audio-default-device))))
      (condition-case err
          (cmacs-audio-start h)
        (error (ignore-errors (cmacs-audio-close h))
               (signal (car err) (cdr err))))
      (setq cmacs-voice--capture h)))
  (unless (timerp cmacs-voice--timer)
    (setq cmacs-voice--timer
          (run-with-timer cmacs-voice-poll-interval cmacs-voice-poll-interval
                          #'cmacs-voice--tick))))

(defun cmacs-voice--close-capture ()
  "Close the capture stream and stop draining."
  (when (timerp cmacs-voice--timer) (cancel-timer cmacs-voice--timer))
  (setq cmacs-voice--timer nil)
  (when cmacs-voice--capture
    (ignore-errors (cmacs-audio-close cmacs-voice--capture)))
  (setq cmacs-voice--capture nil))

(defun cmacs-voice--changed (old)
  "Run the owner hook when the current owner is no longer OLD."
  (let ((new (cmacs-voice-owner)))
    (unless (eq new old)
      (run-hook-with-args 'cmacs-voice-owner-change-functions new old))))

(cl-defun cmacs-voice-acquire (id &key consumer suspend resume preempt exclusive)
  "Take the microphone for client ID; CONSUMER is called with each PCM chunk.
PCM is unibyte S16LE mono at `cmacs-voice-rate'.

EXCLUSIVE marks a push-to-talk client: it is fed ahead of every
streaming client, whose SUSPEND function is called (and RESUME later,
when the mic comes back).  Another exclusive client already holding the
mic is preempted: its PREEMPT function runs -- it should release, by
stopping or cancelling -- and if it does not, it is removed.

A non-exclusive client acquiring while a push-to-talk client holds the
mic waits below it, suspended.  Re-acquiring with the same ID replaces
the entry.  Signals when the microphone cannot be opened, leaving the
owners as they were."
  (let* ((old (cmacs-voice-owner))
         (entry (list :id id :consumer consumer :suspend suspend
                      :resume resume :preempt preempt :exclusive exclusive))
         (saved cmacs-voice--owners))
    (setq cmacs-voice--owners (cl-remove id cmacs-voice--owners
                                         :key (lambda (o) (plist-get o :id))))
    (if exclusive
        (progn
          ;; Another push-to-talk: preempt it.
          (dolist (o (cl-remove-if-not (lambda (o) (plist-get o :exclusive))
                                       cmacs-voice--owners))
            (cmacs-voice--call o :preempt)
            (setq cmacs-voice--owners (delq o cmacs-voice--owners)))
          ;; A streaming client on top: suspend it.
          (when-let* ((top (car cmacs-voice--owners)))
            (cmacs-voice--call top :suspend))
          (push entry cmacs-voice--owners))
      (if (and (car cmacs-voice--owners)
               (plist-get (car cmacs-voice--owners) :exclusive))
          (progn
            (setq cmacs-voice--owners
                  (append (cl-remove-if-not (lambda (o) (plist-get o :exclusive))
                                            cmacs-voice--owners)
                          (list entry)
                          (cl-remove-if (lambda (o) (plist-get o :exclusive))
                                        cmacs-voice--owners)))
            (cmacs-voice--call entry :suspend))
        (when-let* ((top (car cmacs-voice--owners)))
          (cmacs-voice--call top :suspend))
        (push entry cmacs-voice--owners)))
    (condition-case err
        (cmacs-voice--open-capture)
      (error
       (setq cmacs-voice--owners
             (cl-remove id saved :key (lambda (o) (plist-get o :id))))
       (unless cmacs-voice--owners (cmacs-voice--close-capture))
       (signal (car err) (cdr err))))
    (when (and exclusive cmacs-voice-ptt-stops-speech)
      (cmacs-voice-stop-speaking))
    (cmacs-voice--changed old)
    id))

(defun cmacs-voice-release (id)
  "Give the microphone back from client ID.
The client below, if any, resumes; with nobody left the mic closes.
Returns non-nil when ID held it."
  (let* ((old (cmacs-voice-owner))
         (entry (cmacs-voice--entry id)))
    (when entry
      (setq cmacs-voice--owners (delq entry cmacs-voice--owners))
      (when (and (eq old id) (car cmacs-voice--owners))
        (cmacs-voice--call (car cmacs-voice--owners) :resume))
      (unless cmacs-voice--owners (cmacs-voice--close-capture))
      (cmacs-voice--changed old)
      t)))

(defun cmacs-voice--deliver (pcm)
  "Hand PCM to the current owner, or wipe it when there is none."
  (let ((top (car cmacs-voice--owners)))
    (if (and top (plist-get top :consumer))
        (condition-case err (funcall (plist-get top :consumer) pcm)
          (error (message "Voice: %s: %s" (plist-get top :id)
                          (error-message-string err))))
      (fillarray pcm 0))))

(defun cmacs-voice--drain ()
  "Read what the capture holds and deliver it."
  (when cmacs-voice--capture
    (let ((pcm (ignore-errors
                 (cmacs-audio-read-pcm cmacs-voice--capture (* 2 cmacs-voice-rate)))))
      (when (and pcm (> (length pcm) 0))
        (cmacs-voice--deliver pcm)))))

(defun cmacs-voice--tick ()
  "Timer: drain the mic, check push-to-talk limits, run the tick hook."
  (condition-case err
      (progn
        (cmacs-voice--drain)
        (cmacs-voice--ptt-check-limits)
        (run-hooks 'cmacs-voice-tick-functions))
    (error (message "Voice: %s" (error-message-string err)))))


;;;; Push to talk

(defvar cmacs-voice--ptt nil
  "Alist of (ID . STATE) for push-to-talk recordings in progress.
STATE is a plist: :chunks (newest first), :started, :max, :on-timeout.")

(defun cmacs-voice-ptt-active-p (&optional id)
  "Non-nil while push-to-talk ID (any, when nil) is recording."
  (if id (and (assq id cmacs-voice--ptt) t) (and cmacs-voice--ptt t)))

(defun cmacs-voice-ptt-seconds (id)
  "Seconds of audio push-to-talk ID has recorded so far."
  (let ((st (cdr (assq id cmacs-voice--ptt))))
    (/ (apply #'+ (mapcar #'length (plist-get st :chunks)))
       (* 2.0 cmacs-voice-rate))))

(cl-defun cmacs-voice-ptt-start (id &key max-seconds on-timeout preempt)
  "Start recording a phrase for push-to-talk client ID.
Takes the mic exclusively (suspending the always-on loop).  After
MAX-SECONDS ON-TIMEOUT is called (default: `cmacs-voice-ptt-cancel').
PREEMPT runs when another push-to-talk client starts; by default the
recording is cancelled.  Finish with `cmacs-voice-ptt-stop'."
  (when (assq id cmacs-voice--ptt) (cmacs-voice-ptt-cancel id))
  (let ((state (list :chunks nil :started (float-time)
                     :max max-seconds :on-timeout on-timeout)))
    (cmacs-voice-acquire
     id :exclusive t
     :consumer (lambda (pcm)
                 (when-let* ((cell (assq id cmacs-voice--ptt)))
                   (setcdr cell (plist-put (cdr cell) :chunks
                                           (cons pcm (plist-get (cdr cell) :chunks))))))
     :preempt (or preempt (lambda () (cmacs-voice-ptt-cancel id))))
    (push (cons id state) cmacs-voice--ptt)
    id))

(defun cmacs-voice--ptt-check-limits ()
  "Stop any push-to-talk that ran past its limit."
  (dolist (cell cmacs-voice--ptt)
    (let ((st (cdr cell)))
      (when (and (plist-get st :max)
                 (> (- (float-time) (plist-get st :started)) (plist-get st :max)))
        (message "Voice: stopped after %ds" (plist-get st :max))
        (funcall (or (plist-get st :on-timeout)
                     (lambda () (cmacs-voice-ptt-cancel (car cell)))))))))

(defun cmacs-voice-ptt-stop (id)
  "Stop push-to-talk ID; return its audio as one unibyte PCM string.
The caller owns the string (pass it to `cmacs-voice-transcribe', which
wipes it).  Returns nil when ID was not recording."
  (when (assq id cmacs-voice--ptt)
    ;; The tail since the last tick belongs to this phrase.
    (when (eq (cmacs-voice-owner) id) (cmacs-voice--drain))
    (let* ((cell (assq id cmacs-voice--ptt))
           (chunks (plist-get (cdr cell) :chunks))
           (pcm (apply #'concat (reverse chunks))))
      (cmacs-voice-wipe chunks)
      (setq cmacs-voice--ptt (delq cell cmacs-voice--ptt))
      (cmacs-voice-release id)
      pcm)))

(defun cmacs-voice-ptt-cancel (id)
  "Stop push-to-talk ID and throw its audio away."
  (when-let* ((cell (assq id cmacs-voice--ptt)))
    (cmacs-voice-wipe (plist-get (cdr cell) :chunks))
    (setq cmacs-voice--ptt (delq cell cmacs-voice--ptt)))
  (cmacs-voice-release id))


;;;; Transcription

(cl-defun cmacs-voice-transcribe (pcm callback &key model threads language)
  "Transcribe PCM asynchronously; CALLBACK gets whisper's result alist.
MODEL is a model file (default: `cmacs-whisper-model-path').  THREADS
defaults to `cmacs-voice-threads', LANGUAGE to `cmacs-whisper-language'.
PCM is wiped once whisper has its copy.  A failure to start reaches
CALLBACK as ((:error . MESSAGE)), never as a signal."
  (condition-case err
      (progn
        (unless (fboundp 'cmacs-whisper-model-path) (require 'cmacs-whisper))
        (cmacs-whisper-transcribe-pcm-async
         (or model (cmacs-whisper-model-path)) pcm callback
         (or language (and (boundp 'cmacs-whisper-language) cmacs-whisper-language))
         (or threads cmacs-voice-threads)))
    (error (funcall callback (list (cons :error (error-message-string err))))))
  ;; The C side converted the samples to floats before returning.
  (fillarray pcm 0))


;;;; Text

(defun cmacs-voice-clean (text)
  "TEXT without whisper's [annotations] and (sounds), trimmed, single-spaced."
  (let ((s (replace-regexp-in-string
            "\\[[^]]*\\]\\|([^)]*)\\|\\*[^*]*\\*" " " (or text ""))))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " s))))

(defun cmacs-voice-norm (token)
  "TOKEN lower-cased with everything but letters, digits and \\=' removed."
  (replace-regexp-in-string "[^[:alnum:]']" "" (downcase token)))

(defun cmacs-voice-tokens (text)
  "Words of TEXT as a vector of (NORMALIZED . ORIGINAL), skipping punctuation."
  (vconcat
   (cl-loop for tok in (split-string (or text "") "[ \t\n]+" t)
            for n = (cmacs-voice-norm tok)
            unless (string-empty-p n) collect (cons n tok))))

(defun cmacs-voice-similarity (a b)
  "Similarity of strings A and B in [0, 1]: 1 - Levenshtein / longer length."
  (let ((len (max (length a) (length b))))
    (if (zerop len) 1.0
      (- 1.0 (/ (float (string-distance a b)) len)))))

(defun cmacs-voice-phrase-match (text phrase threshold)
  "Find PHRASE in TEXT; return (START END SCORE PHRASE) or nil.
START and END index the words of TEXT (as `cmacs-voice-tokens' splits
them, END exclusive).  Each run of as many words as PHRASE has is
compared whole, and each run of one word more glued together, so
\"jar vis\" still matches \"jarvis\".  The earliest run scoring at
least THRESHOLD wins."
  (let* ((pw (cl-remove-if #'string-empty-p
                           (mapcar #'cmacs-voice-norm
                                   (split-string (or phrase "") nil t))))
         (target (string-join pw " "))
         (glued (string-join pw ""))
         (words (cmacs-voice-tokens text))
         (n (length pw))
         (len (length words)))
    (when (and (> n 0) (> len 0))
      (catch 'found
        (dotimes (i len)
          (dolist (k (list n (1+ n)))
            (when (<= (+ i k) len)
              (let* ((run (cl-loop for j from i below (+ i k)
                                   collect (car (aref words j))))
                     (score (cmacs-voice-similarity
                             (string-join run (if (= k n) " " ""))
                             (if (= k n) target glued))))
                (when (>= score threshold)
                  (throw 'found (list i (+ i k) score phrase)))))))
        nil))))

(defun cmacs-voice-words-after (text end)
  "The words of TEXT from word index END on, joined, leading punctuation gone."
  (let ((words (cmacs-voice-tokens text)))
    (string-trim-left
     (mapconcat #'cdr (cl-subseq words (min end (length words))) " ")
     "[[:punct:][:space:]]+")))


;;;; Detection: 32 ms frames with a speech probability

(defvar cmacs-voice--frame-fn nil "Called with (FRAME PROB) for each frame.")
(defvar cmacs-voice--vad nil "The VAD handle, or nil for the energy detector.")
(defvar cmacs-voice--vad-busy nil "Non-nil while a VAD feed is queued.")
(defvar cmacs-voice--vad-backlog "" "PCM waiting for the VAD.")
(defvar cmacs-voice--residue "" "PCM short of a whole frame.")
(defvar cmacs-voice--noise-db -70.0 "Energy detector noise floor.")
(defvar cmacs-voice--detect-session 0 "Bumped by start/stop; stale VAD answers are dropped.")

(defun cmacs-voice-vad-model-path ()
  "The VAD model file, or nil when it is not installed."
  (when (or (fboundp 'cmacs-whisper-model-path) (require 'cmacs-whisper nil t))
    (let ((p (cmacs-whisper-model-path
              (or cmacs-voice-vad-model cmacs-whisper-default-vad-model))))
      (and (file-exists-p p) p))))

(defun cmacs-voice-detector-reset ()
  "Forget partial frames, queued VAD audio and the learned noise floor."
  (cmacs-voice-wipe cmacs-voice--residue cmacs-voice--vad-backlog)
  (setq cmacs-voice--residue ""
        cmacs-voice--vad-backlog ""
        cmacs-voice--vad-busy nil
        cmacs-voice--noise-db -70.0))

(defun cmacs-voice-detector-start (frame-fn &optional energy-only)
  "Start detection, calling FRAME-FN with (FRAME PROB) for each frame.
Uses the Silero VAD when its model is installed (and ENERGY-ONLY is
nil), else the energy detector.  Returns `vad' or `energy'."
  (cmacs-voice-detector-stop)
  (setq cmacs-voice--frame-fn frame-fn)
  (let ((model (and (not energy-only) (cmacs-voice-vad-model-path))))
    (setq cmacs-voice--vad (and model (ignore-errors (cmacs-whisper-vad-open model)))))
  (if cmacs-voice--vad 'vad 'energy))

(defun cmacs-voice-detector-stop ()
  "Stop detection and release the VAD."
  (cl-incf cmacs-voice--detect-session)
  (when cmacs-voice--vad
    (ignore-errors (cmacs-whisper-vad-close cmacs-voice--vad)))
  (setq cmacs-voice--vad nil
        cmacs-voice--frame-fn nil)
  (cmacs-voice-detector-reset))

(defun cmacs-voice-detector-kind ()
  "`vad' or `energy', whichever detector is running."
  (if cmacs-voice--vad 'vad 'energy))

(defun cmacs-voice-energy-prob (db)
  "Map frame level DB (dBFS) to a speech probability; track the noise floor."
  (let* ((floor cmacs-voice--noise-db)
         (on (+ floor cmacs-voice-energy-margin-db)))
    ;; The floor follows quiet frames quickly and loud ones slowly
    ;; (a time constant of about 6 s), so it settles on the room -- a
    ;; fan that never stops -- and not on a speaker, who pauses.
    (setq cmacs-voice--noise-db
          (max -90.0 (if (< db on)
                         (+ (* 0.95 floor) (* 0.05 db))
                       (+ (* 0.995 floor) (* 0.005 db)))))
    (if (< db cmacs-voice-energy-floor-db)
        0.0
      (min 1.0 (max 0.0 (+ 0.5 (/ (- db on) 20.0)))))))

(defun cmacs-voice--frames (pcm probs)
  "Call the frame function on each 1024-byte frame of PCM with PROBS."
  (let ((n (min (length probs) (/ (length pcm) cmacs-voice-frame-bytes))))
    (dotimes (i n)
      (when cmacs-voice--frame-fn
        (funcall cmacs-voice--frame-fn
                 (substring pcm (* i cmacs-voice-frame-bytes)
                            (* (1+ i) cmacs-voice-frame-bytes))
                 (aref probs i))))
    (fillarray pcm 0)))

(defun cmacs-voice--energy-frames (pcm)
  "Classify PCM by frame energy alone."
  (cmacs-voice--frames
   pcm (vconcat (mapcar #'cmacs-voice-energy-prob
                        (cmacs-whisper-pcm-levels pcm cmacs-voice-window)))))

(defun cmacs-voice--vad-feed (pcm)
  "Hand whole-frame PCM to the VAD, or queue it behind the feed in flight."
  (if cmacs-voice--vad-busy
      (let ((backlog (concat cmacs-voice--vad-backlog pcm))
            ;; Never let a stalled VAD hoard more than ~5 s of audio.
            (cap (* 160 cmacs-voice-frame-bytes)))
        (cmacs-voice-wipe pcm cmacs-voice--vad-backlog)
        (setq cmacs-voice--vad-backlog
              (if (> (length backlog) cap)
                  (prog1 (substring backlog (- (length backlog) cap))
                    (fillarray backlog 0))
                backlog)))
    (let ((session cmacs-voice--detect-session))
      (setq cmacs-voice--vad-busy t)
      (cmacs-whisper-vad-feed
       cmacs-voice--vad pcm
       (lambda (result)
         (if (/= session cmacs-voice--detect-session)
             (fillarray pcm 0)
           (setq cmacs-voice--vad-busy nil)
           (if-let* ((probs (cdr (assq :probs result))))
               (cmacs-voice--frames pcm probs)
             ;; No usable model after all: carry on by energy.
             (message "Voice: VAD failed (%s); using the energy detector"
                      (cdr (assq :error result)))
             (ignore-errors (cmacs-whisper-vad-close cmacs-voice--vad))
             (setq cmacs-voice--vad nil)
             (cmacs-voice--energy-frames pcm))
           (let ((next cmacs-voice--vad-backlog))
             (setq cmacs-voice--vad-backlog "")
             (unless (string-empty-p next)
               (cmacs-voice--classify next)))))))))

(defun cmacs-voice--classify (pcm)
  "Classify whole-frame PCM with the VAD, or the energy detector."
  (if cmacs-voice--vad
      (cmacs-voice--vad-feed pcm)
    (cmacs-voice--energy-frames pcm)))

(defun cmacs-voice-detect (pcm)
  "Take PCM into the detector; frames go to the frame function in order.
Whole frames are classified; a ragged tail waits for the next call.
The answer may come later (the VAD runs on a worker thread)."
  (let* ((all (concat cmacs-voice--residue pcm))
         (whole (* cmacs-voice-frame-bytes
                   (/ (length all) cmacs-voice-frame-bytes))))
    (fillarray cmacs-voice--residue 0)
    (setq cmacs-voice--residue (substring all whole))
    (when (> whole 0)
      (cmacs-voice--classify (substring all 0 whole)))
    (fillarray all 0)))


;;;; Speaking, in order, interruptible

(defvar cmacs-voice--tts-queue nil "Pending (TEXT . VOICE), in order.")
(defvar cmacs-voice--tts-synth nil "Non-nil while piper synthesises.")
(defvar cmacs-voice--tts-gen 0 "Bumped by a stop; stale speech is dropped.")
(defvar cmacs-voice--tts-until 0.0 "When queued playback should be done.")

(defun cmacs-voice-speaking-p ()
  "Non-nil while speech is queued, synthesising or playing."
  (or cmacs-voice--tts-queue cmacs-voice--tts-synth
      (< (float-time) cmacs-voice--tts-until)))

(defun cmacs-voice-speak (text &optional voice)
  "Queue TEXT to be spoken with piper VOICE, after anything already queued.
VOICE defaults to `cmacs-voice-voice'.  Sentences are synthesised one at
a time so they play in the order queued.  Returns non-nil when queued."
  (let ((s (string-trim (or text ""))))
    (when (and (not (string-empty-p s)) (cmacs-voice-speech-available-p))
      (setq cmacs-voice--tts-queue
            (append cmacs-voice--tts-queue (list (cons s (or voice cmacs-voice-voice)))))
      (cmacs-voice--tts-pump)
      t)))

(defun cmacs-voice--tts-pump ()
  "Synthesise the next queued sentence."
  (when (and cmacs-voice--tts-queue (not cmacs-voice--tts-synth))
    (let* ((item (pop cmacs-voice--tts-queue))
           (gen cmacs-voice--tts-gen)
           (voice (cmacs-piper-voice-path (cdr item))))
      (setq cmacs-voice--tts-synth t)
      (condition-case err
          (cmacs-piper--synth-async-1
           voice (car item)
           (lambda (result)
             (when (= gen cmacs-voice--tts-gen)
               (setq cmacs-voice--tts-synth nil)
               (if (stringp result)
                   (cmacs-voice--tts-play result voice (car item))
                 (message "Voice: %s" (or (cdr-safe (car-safe result))
                                          "speech synthesis failed")))
               (cmacs-voice--tts-pump))))
        (error
         (setq cmacs-voice--tts-synth nil
               cmacs-voice--tts-queue nil)
         (message "Voice: %s" (error-message-string err)))))))

(defun cmacs-voice--tts-play (pcm voice text)
  "Play PCM synthesised from TEXT with VOICE; note when it will be done."
  (let* ((rate (cmacs-piper--voice-sample-rate voice))
         (h (cmacs-piper--ensure-playback rate))
         (secs (/ (length pcm) (* 2.0 rate))))
    (cmacs-audio-push-pcm h pcm)
    (setq cmacs-voice--tts-until
          (+ (max (float-time) cmacs-voice--tts-until) secs))
    (run-hook-with-args 'cmacs-voice-speech-functions text secs)))

(defun cmacs-voice-stop-speaking ()
  "Stop speaking now, dropping everything queued.
A sentence still being synthesised is dropped when it arrives."
  (interactive)
  (cl-incf cmacs-voice--tts-gen)
  (setq cmacs-voice--tts-queue nil
        cmacs-voice--tts-synth nil
        cmacs-voice--tts-until 0.0)
  (when (fboundp 'cmacs-piper-stop)
    (ignore-errors (cmacs-piper-stop))))


;;;; Running things from the command loop

(defvar cmacs-voice--deferred nil "Thunks waiting for the command loop.")

(defun cmacs-voice-run-later (fn)
  "Call FN from the command loop, as a command would run.
Voice results arrive in timer and process callbacks; a command that
selects windows or reads the minibuffer belongs in the command loop.
In batch, FN simply runs now."
  (if noninteractive
      (funcall fn)
    (setq cmacs-voice--deferred (append cmacs-voice--deferred (list fn)))
    (push 'cmacs-voice-deferred unread-command-events)))

(defun cmacs-voice--run-deferred ()
  "Run the voice actions waiting for the command loop."
  (interactive)
  (let ((fns cmacs-voice--deferred))
    (setq cmacs-voice--deferred nil)
    (dolist (fn fns)
      (condition-case err (funcall fn)
        ((quit user-error) (message "%s" (error-message-string err)))
        (error (message "Voice: %s" (error-message-string err)))))))

(define-key global-map [cmacs-voice-deferred] #'cmacs-voice--run-deferred)

(provide 'cmacs-voice)

;;; cmacs-voice.el ends here
