;;; cmacs-voice-loop.el --- Always-on duplex voice loop ("Jarvis")  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is part of cmacs, a fork of GNU Emacs.

;;; Commentary:

;; `cmacs-voice-loop-mode' keeps the microphone open and holds a
;; spoken conversation with a cmacs-ai chat:
;;
;;   mic --(cmacs-audio, 16 kHz)--> VAD --> speech segments
;;     segment containing the wake phrase ("jarvis, ...")
;;       --> partial transcripts while you talk (echo area + chat)
;;       --> final transcript at end of speech --> cmacs-ai chat
;;     reply streams in --> spoken sentence by sentence (piper)
;;     talk over the reply --> it stops (barge-in) and listens
;;     for `cmacs-voice-loop-follow-up-seconds' after a reply, no
;;     wake word is needed
;;
;; Voice activity detection is whisper.cpp's Silero VAD
;; (`cmacs-whisper-vad-feed', on a worker thread).  Without the VAD
;; model it falls back to an adaptive energy detector
;; (`cmacs-whisper-pcm-levels').  The wake word is plain whisper on
;; the segment with a small model, matched fuzzily -- no extra
;; dependency.  Partial transcripts re-transcribe the last few seconds
;; of the segment every `cmacs-voice-loop-partial-interval', the
;; sliding-window scheme of whisper.cpp's `stream' example.
;;
;; Nothing runs Lisp off the main thread and nothing here blocks: the
;; microphone is drained by a timer, and every model call is async.
;;
;; The microphone, the detector, transcription and the speech queue
;; belong to the shared engine in cmacs-voice.el.  The loop is its
;; streaming client: a push-to-talk client (C-c v c in a voice chat,
;; holding A or Y in VR, a brigade dictation) takes the mic from it for
;; the length of a phrase, and the loop picks up where it left off --
;; state `paused' meanwhile.
;;
;; Privacy: the mode is off by default.  Audio lives only in memory,
;; only for as long as a segment is being transcribed, and the
;; segment's bytes are overwritten when it is done.  Nothing is
;; written to disk unless `cmacs-voice-loop-save-directory' is set.
;; Speech that does not contain the wake phrase (outside a follow-up
;; window) is transcribed once by the wake model and dropped.
;;
;; Self-echo: when the reply plays through speakers the microphone
;; hears it.  The loop raises the VAD threshold while it speaks
;; (`cmacs-voice-loop-tts-gating'); real echo cancellation is
;; PipeWire's echo-cancel module -- see
;; `cmacs-voice-loop-echo-cancel-config'.
;;
;; Entry points: `cmacs-voice-loop-mode' (C-c v l),
;; `cmacs-voice-loop-listen-now' (C-c v j, skip the wake word once),
;; `cmacs-voice-loop-status'.  Full reference:
;; doc_org/cmacs/cmacs-voice-loop.org.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-voice)

(declare-function cmacs-audio--capture-open-1 "cmacs-audio-defuns.c" (&rest plist))
(declare-function cmacs-audio-start "cmacs-audio-defuns.c" (handle))
(declare-function cmacs-audio-stop "cmacs-audio-defuns.c" (handle))
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
(declare-function cmacs-ai-chat-open "cmacs-ai-chat" (&optional provider model directory))
(declare-function cmacs-ai-chat-send-compose "cmacs-ai-chat")
(declare-function cmacs-ai-chat-cancel-stream "cmacs-ai-chat")
(defvar cmacs-audio-capture-source)
(defvar cmacs-audio-default-device)
(defvar cmacs-whisper-language)
(defvar cmacs-whisper-default-model)
(defvar cmacs-whisper-default-vad-model)


;;;; Customization

(defgroup cmacs-voice-loop nil
  "Always-on duplex voice conversation with cmacs-ai."
  :group 'cmacs-whisper
  :prefix "cmacs-voice-loop-")

(defcustom cmacs-voice-loop-wake-phrase "jarvis"
  "Phrase that addresses the loop, matched fuzzily anywhere in a segment.
May be several words (\"hey computer\").  nil means no wake word:
every utterance is sent (an open mic -- mind what it hears)."
  :type '(choice (const :tag "No wake word" nil) string))

(defcustom cmacs-voice-loop-wake-threshold 0.75
  "Similarity (0..1) a heard word needs to count as the wake phrase.
Similarity is 1 minus the Levenshtein distance over the longer length,
on lower-cased words with punctuation removed, so with the default
\"jervis\" and \"jarvis.\" match while \"travis\" (0.67) does not.
Lower it if your accent or the small model mangles the phrase."
  :type 'number)

(defcustom cmacs-voice-loop-wake-model "ggml-tiny.en.bin"
  "Whisper model used to look for the wake phrase and for partials.
A basename resolved by `cmacs-whisper-model-path'.  Small and fast is
the point; when it is not installed `cmacs-whisper-default-model' is
used instead."
  :type '(choice (const :tag "Default model" nil) string))

(defcustom cmacs-voice-loop-model nil
  "Whisper model for the final transcript of an utterance.
nil means `cmacs-whisper-default-model'."
  :type '(choice (const :tag "Default model" nil) string))

(defcustom cmacs-voice-loop-vad-threshold 0.5
  "Speech probability at which a frame counts as speech.
Speech then continues while frames stay above this minus 0.15, the
usual Silero hysteresis.  The energy detector maps its levels onto the
same scale: 0.5 is `cmacs-voice-energy-margin-db' above the
noise floor."
  :type 'number)

(defcustom cmacs-voice-loop-tts-gating 'threshold
  "How the loop keeps its own voice from triggering it.
`threshold'  raise the speech threshold to
             `cmacs-voice-loop-tts-vad-threshold' while it speaks;
             you can still talk over it, louder.
`mute'       ignore the microphone while it speaks (no barge-in).
`none'       no gating -- for headsets or echo cancellation."
  :type '(choice (const threshold) (const mute) (const none)))

(defcustom cmacs-voice-loop-tts-vad-threshold 0.85
  "Speech threshold while the loop is speaking, under `threshold' gating."
  :type 'number)

(defcustom cmacs-voice-loop-barge-in t
  "Non-nil: speaking over a reply stops it and starts listening.
nil ignores the microphone while a reply is spoken."
  :type 'boolean)

(defcustom cmacs-voice-loop-barge-in-min-ms 250
  "Speech, in milliseconds, that has to be heard before a barge-in.
Shorter bursts -- a cough, a door -- leave the reply playing."
  :type 'integer)

(defcustom cmacs-voice-loop-barge-in-cancels-stream t
  "Non-nil: a barge-in also cancels a reply that is still streaming."
  :type 'boolean)

(defcustom cmacs-voice-loop-barge-in-requires-wake nil
  "Non-nil: what you say over a reply needs the wake phrase too.
nil treats interrupting as addressing the loop."
  :type 'boolean)

(defcustom cmacs-voice-loop-follow-up-seconds 8
  "Seconds after a reply during which no wake phrase is needed."
  :type 'number)

(defcustom cmacs-voice-loop-armed-seconds 6
  "Seconds to wait for the request after a bare wake phrase."
  :type 'number)

(defcustom cmacs-voice-loop-min-speech-ms 200
  "Speech segments shorter than this are dropped as noise."
  :type 'integer)

(defcustom cmacs-voice-loop-end-silence-ms 640
  "Silence, in milliseconds, that ends an utterance."
  :type 'integer)

(defcustom cmacs-voice-loop-pre-roll-ms 320
  "Audio kept from before speech starts, so the first syllable survives."
  :type 'integer)

(defcustom cmacs-voice-loop-max-utterance-seconds 30
  "An utterance longer than this is cut and transcribed as it is."
  :type 'number)

(defcustom cmacs-voice-loop-partial-interval 0.8
  "Seconds between partial transcripts while you speak; nil disables them."
  :type '(choice (const :tag "No partials" nil) number))

(defcustom cmacs-voice-loop-partial-window-seconds 10
  "Partials transcribe at most this many trailing seconds of speech."
  :type 'number)

(defcustom cmacs-voice-loop-partial-display '(echo buffer)
  "Where partial transcripts show: `echo' area and/or the chat `buffer'."
  :type '(set (const echo) (const buffer)))

(defcustom cmacs-voice-loop-speak t
  "Non-nil: replies are spoken with piper."
  :type 'boolean)

(defcustom cmacs-voice-loop-wake-acknowledgement nil
  "Text spoken after a bare wake phrase (\"Yes?\"), or nil to stay quiet."
  :type '(choice (const nil) string))

(defcustom cmacs-voice-loop-send-function #'cmacs-voice-loop-send-to-chat
  "Function called with the final text of each utterance.
The default sends it to the loop's cmacs-ai chat buffer and speaks the
reply.  Any function works; one that wants to answer aloud calls
`cmacs-voice-loop-speak'."
  :type 'function)

(defcustom cmacs-voice-loop-display-chat t
  "Non-nil: show the loop's chat buffer (without selecting it) when used."
  :type 'boolean)

(defcustom cmacs-voice-loop-save-directory nil
  "Directory to keep each final utterance in, as a WAV, or nil (the default).
Off unless you set it: the loop otherwise never writes audio to disk."
  :type '(choice (const :tag "Never save audio" nil) directory))

(defcustom cmacs-voice-loop-lighters
  '((idle . "")
    (listening . " Voice")
    (hearing . " Voice:hearing")
    (thinking . " Voice:thinking")
    (speaking . " Voice:speaking")
    (paused . " Voice:paused"))
  "Mode-line text per loop state.  A trailing `+' marks a follow-up window."
  :type '(alist :key-type symbol :value-type string))

(defvar cmacs-voice-loop-state-change-functions nil
  "Abnormal hook run with (NEW-STATE OLD-STATE) when the loop changes state.
States: `idle' (mode off), `listening', `hearing' (speech in progress),
`thinking' (transcribing / waiting for the reply), `speaking', and
`paused' (a push-to-talk client has the microphone).")

(defvar cmacs-voice-loop-partial-functions nil
  "Abnormal hook run with the current partial transcript (a string).")

(defvar cmacs-voice-loop-utterance-functions nil
  "Abnormal hook run with each final utterance, before it is sent.")

(defface cmacs-voice-loop-partial
  '((t :inherit shadow :slant italic))
  "Face for partial transcripts.")

(defface cmacs-voice-loop-heard
  '((t :inherit success))
  "Face for the final transcript in the echo area.")

(defface cmacs-voice-loop-active
  '((t :inherit warning :weight bold))
  "Mode-line face while the loop hears, thinks or speaks.")


;;;; Constants

(defconst cmacs-voice-loop--frame-bytes cmacs-voice-frame-bytes "Bytes per frame.")
(defconst cmacs-voice-loop--frame-ms cmacs-voice-frame-ms "Milliseconds per frame.")
(defconst cmacs-voice-loop--onset-frames 2
  "Consecutive speech frames that start a segment (64 ms).")


;;;; State

(defvar cmacs-voice-loop--state 'idle "Current loop state.")
(defvar cmacs-voice-loop--session 0
  "Bumped on every start/stop; async results from an old session are dropped.")

(defvar cmacs-voice-loop--preroll nil "Recent frames before speech, newest first.")
(defvar cmacs-voice-loop--onset 0 "Consecutive speech frames while not in speech.")
(defvar cmacs-voice-loop--in-speech nil "Non-nil while a segment is open.")
(defvar cmacs-voice-loop--segment nil "Frames of the open segment, newest first.")
(defvar cmacs-voice-loop--seg-frames 0 "Frames in the open segment.")
(defvar cmacs-voice-loop--speech-frames 0 "Speech frames in the open segment.")
(defvar cmacs-voice-loop--silence 0 "Trailing silent frames in the open segment.")
(defvar cmacs-voice-loop--seg-id 0 "Id of the newest segment.")
(defvar cmacs-voice-loop--addressed nil "Non-nil when the open segment is for us.")
(defvar cmacs-voice-loop--barged nil "Non-nil once the open segment barged in.")
(defvar cmacs-voice-loop--armed-until 0.0
  "Until this `float-time', speech needs no wake phrase.")
(defvar cmacs-voice-loop--last-sent-seg 0 "Id of the last segment sent on.")

(defvar cmacs-voice-loop--partial-busy nil "Non-nil while a partial is transcribing.")
(defvar cmacs-voice-loop--partial-at 0.0 "When the last partial was started.")
(defvar cmacs-voice-loop--partial-text nil "The partial transcript on display.")
(defvar cmacs-voice-loop--partial-overlay nil "Overlay showing the partial in chat.")
(defvar cmacs-voice-loop--finals 0 "Final/wake transcriptions in flight.")

(defvar cmacs-voice-loop--chat-buffer nil "The chat buffer the loop talks to.")
(defvar cmacs-voice-loop--stream-open nil "Non-nil while a reply streams in.")
(defvar cmacs-voice-loop--tts-tail "" "Reply text not yet a whole sentence.")


;;;; Text: cleaning and the wake phrase

(defalias 'cmacs-voice-loop--clean #'cmacs-voice-clean)
(defalias 'cmacs-voice-loop--tokens #'cmacs-voice-tokens)

(defun cmacs-voice-loop-wake-match (text &optional phrase threshold)
  "Find the wake PHRASE in TEXT; return (START END SCORE PHRASE) or nil.
START and END index the words of TEXT (END exclusive) covered by the
match.  PHRASE defaults to `cmacs-voice-loop-wake-phrase' and THRESHOLD
to `cmacs-voice-loop-wake-threshold'.  A heard word matches when 1 minus
its Levenshtein distance over the longer length reaches THRESHOLD; a
run of one word more glued together is tried too, so \"jar vis\" still
matches \"jarvis\".  The earliest match wins."
  (cmacs-voice-phrase-match text (or phrase cmacs-voice-loop-wake-phrase)
                            (or threshold cmacs-voice-loop-wake-threshold)))

(defalias 'cmacs-voice-loop--after #'cmacs-voice-words-after)

(defun cmacs-voice-loop-strip-wake (text &optional fallback-words)
  "TEXT after the wake phrase, or nil when TEXT holds only the phrase.
When the phrase is not found in TEXT and FALLBACK-WORDS is a number,
that many leading words are dropped instead (the wake model heard the
phrase; the final model spelled it differently).  Otherwise TEXT is
returned whole."
  (let* ((m (and cmacs-voice-loop-wake-phrase
                 (cmacs-voice-loop-wake-match text)))
         (rest (cond (m (cmacs-voice-loop--after text (nth 1 m)))
                     (fallback-words (cmacs-voice-loop--after text fallback-words))
                     (t (cmacs-voice-loop--clean text)))))
    (unless (string-empty-p rest) rest)))


;;;; State changes and the mode line

(defun cmacs-voice-loop--set-state (new)
  "Enter state NEW, running `cmacs-voice-loop-state-change-functions'."
  (let ((old cmacs-voice-loop--state))
    (unless (eq new old)
      (setq cmacs-voice-loop--state new)
      (run-hook-with-args 'cmacs-voice-loop-state-change-functions new old)
      (force-mode-line-update t))))

(defun cmacs-voice-loop-state ()
  "The loop's state: `idle', `listening', `hearing', `thinking', `speaking'
or `paused'."
  cmacs-voice-loop--state)

(defun cmacs-voice-loop--armed-p ()
  "Non-nil while speech needs no wake phrase."
  (or (null cmacs-voice-loop-wake-phrase)
      (< (float-time) cmacs-voice-loop--armed-until)))

(defun cmacs-voice-loop--lighter ()
  "Mode-line string for the current state."
  (let ((s (or (alist-get cmacs-voice-loop--state cmacs-voice-loop-lighters) "")))
    (when (and (eq cmacs-voice-loop--state 'listening)
               cmacs-voice-loop-wake-phrase
               (cmacs-voice-loop--armed-p))
      (setq s (concat s "+")))
    (if (memq cmacs-voice-loop--state '(hearing thinking speaking))
        (propertize s 'face 'cmacs-voice-loop-active)
      s)))

(defun cmacs-voice-loop--busy-p ()
  "Non-nil while a reply is pending or being spoken."
  (memq cmacs-voice-loop--state '(thinking speaking)))


;;;; Speaking (piper), in order, interruptible

(defalias 'cmacs-voice-loop--tts-active-p #'cmacs-voice-speaking-p
  "Non-nil while the engine's speech is queued, synthesising or playing.")

(defun cmacs-voice-loop--speakable (text)
  "TEXT with markup that reads badly aloud removed."
  (let ((s (or text "")))
    (setq s (replace-regexp-in-string "\\[\\[[^]]*\\]\\[\\([^]]*\\)\\]\\]" "\\1" s))
    (setq s (replace-regexp-in-string "\\[\\[\\([^]]*\\)\\]\\]" "\\1" s))
    (setq s (replace-regexp-in-string "\\[\\([^]]*\\)\\]([^)]*)" "\\1" s))
    (setq s (replace-regexp-in-string "[*`#~_=]+" "" s))
    (string-trim (replace-regexp-in-string "[ \t\n]+" " " s))))

(defun cmacs-voice-loop-speak (text)
  "Queue TEXT to be spoken by the loop, after anything already queued.
Speech goes through the shared engine's queue (`cmacs-voice-speak'),
so it is in order and stops on a barge-in."
  (when cmacs-voice-loop-speak
    (cmacs-voice-speak (cmacs-voice-loop--speakable text))))

(defun cmacs-voice-loop--on-speech (_text _seconds)
  "Engine speech started playing: a pending reply is now being spoken."
  (when (and cmacs-voice-loop-mode (eq cmacs-voice-loop--state 'thinking))
    (cmacs-voice-loop--set-state 'speaking)))

(defun cmacs-voice-loop-stop-speaking ()
  "Stop the loop's speech now, dropping anything queued."
  (interactive)
  (setq cmacs-voice-loop--tts-tail "")
  (cmacs-voice-stop-speaking))

(defun cmacs-voice-loop--feed-reply (chunk)
  "Accumulate streamed reply CHUNK; queue each completed sentence."
  (setq cmacs-voice-loop--tts-tail (concat cmacs-voice-loop--tts-tail chunk))
  (let ((s cmacs-voice-loop--tts-tail))
    (while (string-match "\\([^.?!\n]*[.?!:]\\)[\n\t ]+\\|\\([^\n]+\\)\n" s)
      (let ((sent (or (match-string 1 s) (match-string 2 s))))
        (setq s (substring s (match-end 0)))
        (cmacs-voice-loop-speak sent)))
    (setq cmacs-voice-loop--tts-tail s)))


;;;; The chat side

(defun cmacs-voice-loop--ensure-chat-buffer ()
  "Return the loop's chat buffer, opening one without selecting it."
  (unless (buffer-live-p cmacs-voice-loop--chat-buffer)
    (require 'cmacs-ai)
    (require 'cmacs-ai-chat)
    (setq cmacs-voice-loop--chat-buffer
          (save-window-excursion (cmacs-ai-chat-open))))
  (when (and cmacs-voice-loop-display-chat
             (not (get-buffer-window cmacs-voice-loop--chat-buffer t)))
    (display-buffer cmacs-voice-loop--chat-buffer))
  cmacs-voice-loop--chat-buffer)

(defun cmacs-voice-loop-send-to-chat (text)
  "Send TEXT as a turn of the loop's chat; the reply is spoken.
The default `cmacs-voice-loop-send-function'."
  (let ((buf (cmacs-voice-loop--ensure-chat-buffer)))
    (setq cmacs-voice-loop--stream-open t
          cmacs-voice-loop--tts-tail "")
    (condition-case err
        (with-current-buffer buf
          (goto-char (point-max))
          (insert text)
          (cmacs-ai-chat-send-compose))
      (error
       (setq cmacs-voice-loop--stream-open nil)
       (message "Voice: could not send: %s" (error-message-string err))))))

(defun cmacs-voice-loop--stream-tap (buf payload)
  "Advice before `cmacs-ai-chat--stream-callback': speak the loop's replies.
Only BUF = the loop's chat buffer is touched; PAYLOAD is the stream
event.  Being advice, it also hears the continuation after a tool
call, which a callback wrapped at send time would miss."
  (when (and cmacs-voice-loop-mode (eq buf cmacs-voice-loop--chat-buffer))
    (pcase (car-safe payload)
      (:start (setq cmacs-voice-loop--stream-open t))
      ;; A delta that lands after a barge-in cancelled the stream is
      ;; not spoken: `--stream-open' went nil with the cancel.
      (:delta (let ((chunk (cadr payload)))
                (when (and (stringp chunk) cmacs-voice-loop-speak
                           cmacs-voice-loop--stream-open)
                  (cmacs-voice-loop--feed-reply chunk))))
      (:end (unless (eq (plist-get (cdr payload) :stop) 'tool-use)
              (let ((tail cmacs-voice-loop--tts-tail))
                (setq cmacs-voice-loop--tts-tail "")
                (when cmacs-voice-loop-speak (cmacs-voice-loop-speak tail)))
              (setq cmacs-voice-loop--stream-open nil)))
      (:error (setq cmacs-voice-loop--stream-open nil
                    cmacs-voice-loop--tts-tail "")))))

(defun cmacs-voice-loop--cancel-reply ()
  "Cancel the reply still streaming into the loop's chat, if any."
  (when (and cmacs-voice-loop--stream-open
             (buffer-live-p cmacs-voice-loop--chat-buffer)
             (fboundp 'cmacs-ai-chat-cancel-stream))
    (with-current-buffer cmacs-voice-loop--chat-buffer
      (ignore-errors (cmacs-ai-chat-cancel-stream))))
  (setq cmacs-voice-loop--stream-open nil))


;;;; Partial transcripts

(defun cmacs-voice-loop--show-partial (text)
  "Display partial TEXT where `cmacs-voice-loop-partial-display' says."
  (setq cmacs-voice-loop--partial-text text)
  (run-hook-with-args 'cmacs-voice-loop-partial-functions text)
  (when (memq 'echo cmacs-voice-loop-partial-display)
    (let ((message-log-max nil))
      (message "%s" (propertize (concat text " ...") 'face 'cmacs-voice-loop-partial))))
  (when (and (memq 'buffer cmacs-voice-loop-partial-display)
             (buffer-live-p cmacs-voice-loop--chat-buffer))
    (with-current-buffer cmacs-voice-loop--chat-buffer
      (unless (overlayp cmacs-voice-loop--partial-overlay)
        (setq cmacs-voice-loop--partial-overlay
              (make-overlay (point-max) (point-max) nil nil t)))
      (move-overlay cmacs-voice-loop--partial-overlay (point-max) (point-max))
      ;; An after-string, not text: the chat's history is sealed, and a
      ;; partial is never part of the transcript.
      (overlay-put cmacs-voice-loop--partial-overlay 'after-string
                   (propertize (concat text " ...")
                               'face 'cmacs-voice-loop-partial)))))

(defun cmacs-voice-loop--clear-partial ()
  "Remove the partial transcript from display."
  (when cmacs-voice-loop--partial-text
    (setq cmacs-voice-loop--partial-text nil)
    (when (memq 'echo cmacs-voice-loop-partial-display)
      (let ((message-log-max nil)) (message nil))))
  (when (overlayp cmacs-voice-loop--partial-overlay)
    (delete-overlay cmacs-voice-loop--partial-overlay)
    (setq cmacs-voice-loop--partial-overlay nil)))

(defun cmacs-voice-loop--recent-pcm (seconds)
  "The last SECONDS of the open segment, as one PCM string."
  (let* ((n (max 1 (round (/ (* seconds 1000.0) cmacs-voice-loop--frame-ms))))
         (frames (cl-subseq cmacs-voice-loop--segment
                            0 (min n (length cmacs-voice-loop--segment)))))
    (apply #'concat (reverse frames))))

(defun cmacs-voice-loop--maybe-partial ()
  "Start a partial transcript of the open segment when one is due."
  (when (and cmacs-voice-loop-partial-interval
             cmacs-voice-loop--in-speech
             (not cmacs-voice-loop--partial-busy)
             (>= (* cmacs-voice-loop--seg-frames cmacs-voice-loop--frame-ms) 500)
             (>= (- (float-time) cmacs-voice-loop--partial-at)
                 cmacs-voice-loop-partial-interval)
             ;; While a reply plays, a partial would only transcribe the
             ;; echo; wait for the barge-in to decide it is really you.
             (or (not (cmacs-voice-loop--busy-p)) cmacs-voice-loop--barged))
    (let ((pcm (cmacs-voice-loop--recent-pcm
                cmacs-voice-loop-partial-window-seconds))
          (seg cmacs-voice-loop--seg-id)
          (session cmacs-voice-loop--session))
      (setq cmacs-voice-loop--partial-busy t
            cmacs-voice-loop--partial-at (float-time))
      (cmacs-voice-loop--transcribe
       pcm 'partial
       (lambda (result)
         (when (= session cmacs-voice-loop--session)
           (setq cmacs-voice-loop--partial-busy nil)
           (when (and cmacs-voice-loop--in-speech
                      (= seg cmacs-voice-loop--seg-id))
             (cmacs-voice-loop--on-partial
              (cmacs-voice-loop--clean (cdr (assq :text result)))))))))))

(defun cmacs-voice-loop--on-partial (text)
  "Handle partial TEXT of the open segment: spot the wake phrase, show it."
  (unless (string-empty-p text)
    (if cmacs-voice-loop--addressed
        (cmacs-voice-loop--show-partial
         (or (cmacs-voice-loop-strip-wake text) text))
      (when-let* ((m (cmacs-voice-loop-wake-match text)))
        (setq cmacs-voice-loop--addressed t)
        (let ((rest (cmacs-voice-loop--after text (nth 1 m))))
          (cmacs-voice-loop--show-partial
           (if (string-empty-p rest) "..." rest)))))))


;;;; Transcription

(defun cmacs-voice-loop--model-path (which)
  "Resolve the whisper model for WHICH: `wake', `partial' or `final'."
  (let* ((default cmacs-whisper-default-model)
         (name (if (eq which 'final)
                   (or cmacs-voice-loop-model default)
                 (or cmacs-voice-loop-wake-model default)))
         (path (cmacs-whisper-model-path name)))
    (if (file-exists-p path) path (cmacs-whisper-model-path default))))

(defun cmacs-voice-loop--transcribe (pcm which callback)
  "Transcribe PCM with the model for WHICH; CALLBACK gets the result alist.
PCM is wiped once whisper has its copy."
  (cmacs-voice-transcribe pcm callback
                          :model (cmacs-voice-loop--model-path which)))


;;;; Utterances

(defun cmacs-voice-loop--write-wav (pcm file)
  "Write mono 16 kHz PCM to FILE as a WAV."
  (let ((n (length pcm)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (cl-flet ((u32 (v) (insert (logand v 255) (logand (ash v -8) 255)
                                 (logand (ash v -16) 255) (logand (ash v -24) 255)))
                (u16 (v) (insert (logand v 255) (logand (ash v -8) 255))))
        (insert "RIFF") (u32 (+ 36 n)) (insert "WAVEfmt ")
        (u32 16) (u16 1) (u16 1) (u32 cmacs-voice-rate)
        (u32 (* 2 cmacs-voice-rate)) (u16 2) (u16 16)
        (insert "data") (u32 n))
      (insert pcm)
      (let ((coding-system-for-write 'binary))
        (write-region nil nil file nil 'silent)))))

(defun cmacs-voice-loop--maybe-save (pcm)
  "Keep a copy of PCM when `cmacs-voice-loop-save-directory' asks for it."
  (when cmacs-voice-loop-save-directory
    (make-directory cmacs-voice-loop-save-directory t)
    (cmacs-voice-loop--write-wav
     pcm (expand-file-name (format-time-string "voice-%Y%m%d-%H%M%S.wav")
                           cmacs-voice-loop-save-directory))))

(defun cmacs-voice-loop--dispatch (text seg)
  "Send final TEXT of segment SEG on, unless a newer one already went."
  (when (> seg cmacs-voice-loop--last-sent-seg)
    (setq cmacs-voice-loop--last-sent-seg seg)
    (cmacs-voice-loop--clear-partial)
    (message "%s" (propertize text 'face 'cmacs-voice-loop-heard))
    (run-hook-with-args 'cmacs-voice-loop-utterance-functions text)
    (cmacs-voice-loop--set-state 'thinking)
    (setq cmacs-voice-loop--armed-until 0.0)
    (condition-case err
        (funcall cmacs-voice-loop-send-function text)
      (error (message "Voice: %s" (error-message-string err))))))

(defun cmacs-voice-loop--arm (seconds)
  "Need no wake phrase for the next SECONDS."
  (setq cmacs-voice-loop--armed-until (+ (float-time) seconds))
  (force-mode-line-update t))

(defun cmacs-voice-loop--settle ()
  "Return to listening when nothing is pending."
  (when (and cmacs-voice-loop-mode
             (not cmacs-voice-loop--in-speech)
             (zerop cmacs-voice-loop--finals)
             (not (cmacs-voice-loop--busy-p)))
    (cmacs-voice-loop--set-state 'listening)))

(defun cmacs-voice-loop--on-final (result seg wake-words)
  "Final transcript RESULT of segment SEG arrived; send what was asked.
WAKE-WORDS is the word count up to the end of the wake phrase as the
wake model heard it, or nil when the segment needed no phrase."
  (let* ((err (cdr (assq :error result)))
         (text (cmacs-voice-loop--clean (cdr (assq :text result))))
         (rest (cond ((or err (string-empty-p text)) nil)
                     (wake-words (cmacs-voice-loop-strip-wake text wake-words))
                     ((and cmacs-voice-loop-wake-phrase
                           (cmacs-voice-loop-wake-match text))
                      (cmacs-voice-loop-strip-wake text))
                     (t text))))
    (cond
     (err (message "Voice: %s" err)
          (cmacs-voice-loop--clear-partial))
     ((string-empty-p text)
      ;; Heard nothing after all (a breath, a click).
      (cmacs-voice-loop--clear-partial))
     ((null rest)
      ;; Only the phrase: wait for the request.
      (cmacs-voice-loop--clear-partial)
      (cmacs-voice-loop--arm cmacs-voice-loop-armed-seconds)
      (when cmacs-voice-loop-wake-acknowledgement
        (cmacs-voice-loop-speak cmacs-voice-loop-wake-acknowledgement))
      (message "Voice: listening..."))
     (t (cmacs-voice-loop--dispatch rest seg)))))

(defun cmacs-voice-loop--segment-done (pcm addressed seg)
  "Speech segment SEG ended with audio PCM; ADDRESSED if it was for us."
  (let ((session cmacs-voice-loop--session))
    (cl-flet ((finish (fn)
                (lambda (result)
                  (when (= session cmacs-voice-loop--session)
                    (cl-decf cmacs-voice-loop--finals)
                    (funcall fn result)
                    (cmacs-voice-loop--settle)))))
      (cond
       (addressed
        (cmacs-voice-loop--maybe-save pcm)
        (cl-incf cmacs-voice-loop--finals)
        (unless (cmacs-voice-loop--busy-p)
          (cmacs-voice-loop--set-state 'thinking))
        (cmacs-voice-loop--transcribe
         pcm 'final (finish (lambda (r) (cmacs-voice-loop--on-final r seg nil)))))
       (t
        ;; Not (yet) known to be for us: the wake model decides.  A copy
        ;; is kept for the final model only when the two differ.
        (let ((keep (and (not (equal (cmacs-voice-loop--model-path 'wake)
                                     (cmacs-voice-loop--model-path 'final)))
                         (copy-sequence pcm))))
          (cl-incf cmacs-voice-loop--finals)
          (cmacs-voice-loop--transcribe
           pcm 'wake
           (finish
            (lambda (r)
              (let* ((text (cmacs-voice-loop--clean (cdr (assq :text r))))
                     (m (and (not (assq :error r))
                             (cmacs-voice-loop-wake-match text))))
                (cond
                 ((null m)
                  (when keep (fillarray keep 0))
                  (cmacs-voice-loop--clear-partial))
                 ;; Same model, or nothing after the phrase: the wake
                 ;; transcript already says all there is.
                 ((or (null keep)
                      (string-empty-p (cmacs-voice-loop--after text (nth 1 m))))
                  (when keep (fillarray keep 0))
                  (cmacs-voice-loop--on-final r seg nil))
                 (t
                  (cmacs-voice-loop--maybe-save keep)
                  (cmacs-voice-loop--set-state 'thinking)
                  (cl-incf cmacs-voice-loop--finals)
                  (cmacs-voice-loop--transcribe
                   keep 'final
                   (finish (lambda (r2)
                             (cmacs-voice-loop--on-final
                              r2 seg (nth 1 m)))))))))))))))))


;;;; Frames: the segmenter

(defun cmacs-voice-loop--threshold ()
  "The speech threshold that applies right now."
  (if (and (eq cmacs-voice-loop-tts-gating 'threshold)
           (cmacs-voice-loop--tts-active-p))
      cmacs-voice-loop-tts-vad-threshold
    cmacs-voice-loop-vad-threshold))

(defun cmacs-voice-loop--ignore-mic-p ()
  "Non-nil while the loop speaks and must not listen at all."
  (and (cmacs-voice-loop--tts-active-p)
       (or (eq cmacs-voice-loop-tts-gating 'mute)
           (not cmacs-voice-loop-barge-in))))

(defun cmacs-voice-loop--wipe (frames)
  "Overwrite every PCM string in FRAMES."
  (dolist (f frames) (fillarray f 0)))

(defun cmacs-voice-loop--drop-segment ()
  "Forget the open segment without transcribing it."
  (cmacs-voice-loop--wipe cmacs-voice-loop--segment)
  (setq cmacs-voice-loop--segment nil
        cmacs-voice-loop--in-speech nil
        cmacs-voice-loop--seg-frames 0
        cmacs-voice-loop--speech-frames 0
        cmacs-voice-loop--silence 0
        cmacs-voice-loop--barged nil
        cmacs-voice-loop--addressed nil))

(defun cmacs-voice-loop--start-segment (frame)
  "Open a segment with the pre-roll and FRAME."
  (cl-incf cmacs-voice-loop--seg-id)
  (setq cmacs-voice-loop--in-speech t
        cmacs-voice-loop--segment (cons frame cmacs-voice-loop--preroll)
        cmacs-voice-loop--preroll nil
        cmacs-voice-loop--seg-frames (length cmacs-voice-loop--segment)
        cmacs-voice-loop--speech-frames cmacs-voice-loop--onset-frames
        cmacs-voice-loop--silence 0
        cmacs-voice-loop--barged nil
        cmacs-voice-loop--addressed (cmacs-voice-loop--armed-p)
        cmacs-voice-loop--partial-at (float-time))
  (unless (cmacs-voice-loop--busy-p)
    (cmacs-voice-loop--set-state 'hearing)))

(defun cmacs-voice-loop--barge-in ()
  "The user is talking over the reply: stop it and listen."
  (setq cmacs-voice-loop--barged t)
  (cmacs-voice-loop-stop-speaking)
  (when cmacs-voice-loop-barge-in-cancels-stream
    (cmacs-voice-loop--cancel-reply))
  (unless cmacs-voice-loop-barge-in-requires-wake
    (setq cmacs-voice-loop--addressed t))
  (cmacs-voice-loop--set-state 'hearing))

(defun cmacs-voice-loop--end-segment ()
  "Close the open segment and hand its audio on."
  (let ((frames cmacs-voice-loop--segment)
        (addressed cmacs-voice-loop--addressed)
        (speech-ms (* cmacs-voice-loop--speech-frames cmacs-voice-loop--frame-ms))
        (seg cmacs-voice-loop--seg-id)
        (busy (and (cmacs-voice-loop--busy-p) (not cmacs-voice-loop--barged))))
    ;; Drop the trailing silence, all but a little.
    (let ((trim (max 0 (- cmacs-voice-loop--silence 6))))
      (cmacs-voice-loop--wipe (cl-subseq frames 0 (min trim (length frames))))
      (setq frames (nthcdr trim frames)))
    (setq cmacs-voice-loop--segment nil)
    (cmacs-voice-loop--drop-segment)
    (cond
     ;; Too short to be speech, or heard over our own reply without
     ;; amounting to a barge-in: noise or echo.
     ((or busy (< speech-ms cmacs-voice-loop-min-speech-ms))
      (cmacs-voice-loop--wipe frames)
      (cmacs-voice-loop--clear-partial)
      (unless (cmacs-voice-loop--busy-p)
        (cmacs-voice-loop--settle)))
     (t
      (let ((pcm (apply #'concat (nreverse frames))))
        (cmacs-voice-loop--wipe frames)
        (unless (cmacs-voice-loop--busy-p)
          (cmacs-voice-loop--set-state 'listening))
        (cmacs-voice-loop--segment-done pcm addressed seg))))))

(defun cmacs-voice-loop--frame (frame prob)
  "Advance the segmenter by one 32 ms FRAME with speech probability PROB."
  (if (cmacs-voice-loop--ignore-mic-p)
      (progn
        (when cmacs-voice-loop--in-speech (cmacs-voice-loop--drop-segment))
        (setq cmacs-voice-loop--onset 0)
        (fillarray frame 0))
    (let ((on (cmacs-voice-loop--threshold)))
      (if (not cmacs-voice-loop--in-speech)
          (progn
            (setq cmacs-voice-loop--onset
                  (if (>= prob on) (1+ cmacs-voice-loop--onset) 0))
            (if (>= cmacs-voice-loop--onset cmacs-voice-loop--onset-frames)
                (progn
                  (setq cmacs-voice-loop--onset 0)
                  (cmacs-voice-loop--start-segment frame))
              (push frame cmacs-voice-loop--preroll)
              (let ((keep (max 1 (round (/ cmacs-voice-loop-pre-roll-ms
                                           cmacs-voice-loop--frame-ms)))))
                (when (> (length cmacs-voice-loop--preroll) keep)
                  (let ((tail (nthcdr (1- keep) cmacs-voice-loop--preroll)))
                    (cmacs-voice-loop--wipe (cdr tail))
                    (setcdr tail nil))))))
        (push frame cmacs-voice-loop--segment)
        (cl-incf cmacs-voice-loop--seg-frames)
        (if (>= prob (- on 0.15))
            (progn (setq cmacs-voice-loop--silence 0)
                   (cl-incf cmacs-voice-loop--speech-frames))
          (cl-incf cmacs-voice-loop--silence))
        (when (and (cmacs-voice-loop--busy-p)
                   (not cmacs-voice-loop--barged)
                   cmacs-voice-loop-barge-in
                   (zerop cmacs-voice-loop--silence)
                   (>= (* cmacs-voice-loop--speech-frames cmacs-voice-loop--frame-ms)
                       cmacs-voice-loop-barge-in-min-ms))
          (cmacs-voice-loop--barge-in))
        (when (or (>= (* cmacs-voice-loop--silence cmacs-voice-loop--frame-ms)
                      cmacs-voice-loop-end-silence-ms)
                  (>= (* cmacs-voice-loop--seg-frames cmacs-voice-loop--frame-ms)
                      (* 1000 cmacs-voice-loop-max-utterance-seconds)))
          (cmacs-voice-loop--end-segment))))))

(defun cmacs-voice-loop--ingest (pcm)
  "Take newly captured PCM (S16LE mono 16 kHz) into the loop.
The engine's detector splits it into frames and calls
`cmacs-voice-loop--frame' with each.  The test suite drives the loop
through here with synthetic audio."
  (cmacs-voice-detect pcm))

(defun cmacs-voice-loop--housekeeping ()
  "Per-tick upkeep: partials, the end of a reply, the mode line."
  (cmacs-voice-loop--maybe-partial)
  (when (and (eq cmacs-voice-loop--state 'speaking)
             (not cmacs-voice-loop--stream-open)
             (not (cmacs-voice-loop--tts-active-p)))
    (cmacs-voice-loop--arm cmacs-voice-loop-follow-up-seconds)
    (cmacs-voice-loop--set-state 'listening))
  (when (and (eq cmacs-voice-loop--state 'thinking)
             (zerop cmacs-voice-loop--finals)
             (not cmacs-voice-loop--stream-open)
             (not (cmacs-voice-loop--tts-active-p)))
    ;; A reply that was not spoken (speech off, or a custom sender).
    (cmacs-voice-loop--arm cmacs-voice-loop-follow-up-seconds)
    (cmacs-voice-loop--set-state 'listening))
  (when (and (eq cmacs-voice-loop--state 'listening)
             cmacs-voice-loop-wake-phrase
             (> cmacs-voice-loop--armed-until 0)
             (>= (float-time) cmacs-voice-loop--armed-until))
    (setq cmacs-voice-loop--armed-until 0.0)
    (force-mode-line-update t)))

;;;; Mode

(defun cmacs-voice-loop--reset-state ()
  "Forget all audio and per-utterance state."
  (cmacs-voice-loop--drop-segment)
  (cmacs-voice-loop--wipe cmacs-voice-loop--preroll)
  (cmacs-voice-detector-reset)
  (setq cmacs-voice-loop--preroll nil
        cmacs-voice-loop--onset 0
        cmacs-voice-loop--armed-until 0.0
        cmacs-voice-loop--partial-busy nil
        cmacs-voice-loop--finals 0
        cmacs-voice-loop--stream-open nil)
  (cmacs-voice-loop--clear-partial))

(defun cmacs-voice-loop--check ()
  "Signal a `user-error' naming what this build or machine lacks."
  (unless (and (cmacs-voice-available-p) (fboundp 'cmacs-whisper-pcm-levels))
    (user-error "The voice loop needs cmacs built with audio and whisper"))
  (unless (file-exists-p (cmacs-voice-loop--model-path 'final))
    (user-error "No whisper model at %s: M-x cmacs-whisper-download-model"
                (abbreviate-file-name (cmacs-voice-loop--model-path 'final)))))

(defun cmacs-voice-loop--suspend ()
  "A push-to-talk client took the mic: drop what was being heard."
  (cmacs-voice-loop--drop-segment)
  (cmacs-voice-loop--clear-partial)
  (cmacs-voice-detector-reset)
  (cmacs-voice-loop--set-state 'paused))

(defun cmacs-voice-loop--resume ()
  "The mic came back from a push-to-talk client."
  (when cmacs-voice-loop-mode
    (cmacs-voice-loop--set-state
     (if (cmacs-voice-speaking-p) 'speaking 'listening))))

(defun cmacs-voice-loop--open ()
  "Take the microphone from the engine and start the detector."
  (cl-incf cmacs-voice-loop--session)
  (cmacs-voice-loop--reset-state)
  (cmacs-voice-loop--set-state 'listening)
  (cmacs-voice-acquire 'loop
                       :consumer #'cmacs-voice-loop--ingest
                       :suspend #'cmacs-voice-loop--suspend
                       :resume #'cmacs-voice-loop--resume)
  (when (eq (cmacs-voice-detector-start #'cmacs-voice-loop--frame) 'energy)
    (message "Voice: no VAD model, using the energy detector (%s)"
             (substitute-command-keys "\\[cmacs-whisper-download-vad-model]")))
  (when (and (derived-mode-p 'cmacs-ai-chat-mode)
             (not (buffer-live-p cmacs-voice-loop--chat-buffer)))
    (setq cmacs-voice-loop--chat-buffer (current-buffer)))
  (advice-add 'cmacs-ai-chat--stream-callback :before
              #'cmacs-voice-loop--stream-tap)
  (add-hook 'cmacs-voice-tick-functions #'cmacs-voice-loop--housekeeping)
  (add-hook 'cmacs-voice-speech-functions #'cmacs-voice-loop--on-speech))

(defun cmacs-voice-loop--close ()
  "Stop listening and speaking; give the mic back and drop all audio."
  (cl-incf cmacs-voice-loop--session)
  (remove-hook 'cmacs-voice-tick-functions #'cmacs-voice-loop--housekeeping)
  (remove-hook 'cmacs-voice-speech-functions #'cmacs-voice-loop--on-speech)
  (cmacs-voice-release 'loop)
  (cmacs-voice-detector-stop)
  (cmacs-voice-loop-stop-speaking)
  (cmacs-voice-loop--reset-state)
  (advice-remove 'cmacs-ai-chat--stream-callback #'cmacs-voice-loop--stream-tap)
  (cmacs-voice-loop--set-state 'idle))

;;;###autoload
(define-minor-mode cmacs-voice-loop-mode
  "Always-on voice conversation with cmacs-ai (the \"Jarvis\" loop).
The microphone stays open; speech that starts with
`cmacs-voice-loop-wake-phrase' is transcribed and sent to a cmacs-ai
chat, and the reply is spoken.  Speak over the reply to interrupt it.
After a reply, `cmacs-voice-loop-follow-up-seconds' need no wake
phrase.  Audio stays in memory and is discarded after use.

The mode line shows the state: listening (a trailing + means no wake
phrase is needed right now), hearing, thinking, speaking, paused
\(a push-to-talk command has the microphone)."
  :global t
  :group 'cmacs-voice-loop
  :lighter (:eval (cmacs-voice-loop--lighter))
  (if cmacs-voice-loop-mode
      (condition-case err
          (progn (cmacs-voice-loop--check)
                 (cmacs-voice-loop--open)
                 (message "Voice loop on%s"
                          (if cmacs-voice-loop-wake-phrase
                              (format " -- say \"%s\"" cmacs-voice-loop-wake-phrase)
                            "")))
        (error
         (setq cmacs-voice-loop-mode nil)
         (cmacs-voice-loop--close)
         (signal (car err) (cdr err))))
    (cmacs-voice-loop--close)))

;;;###autoload
(defun cmacs-voice-loop-start ()
  "Turn the voice loop on."
  (interactive)
  (cmacs-voice-loop-mode 1))

;;;###autoload
(defun cmacs-voice-loop-stop ()
  "Turn the voice loop off, discarding any audio it holds."
  (interactive)
  (cmacs-voice-loop-mode -1))

;;;###autoload
(defun cmacs-voice-loop-listen-now ()
  "Address the loop without the wake phrase: the next utterance is sent.
Stops any reply being spoken.  Starts the loop if it is off."
  (interactive)
  (unless cmacs-voice-loop-mode (cmacs-voice-loop-mode 1))
  (when (cmacs-voice-loop--tts-active-p) (cmacs-voice-loop-stop-speaking))
  (when cmacs-voice-loop--in-speech (setq cmacs-voice-loop--addressed t))
  (cmacs-voice-loop--arm cmacs-voice-loop-armed-seconds)
  (message "Voice: listening..."))

(defun cmacs-voice-loop-status ()
  "Describe the loop: state, detector, models, chat buffer."
  (interactive)
  (message "Voice loop: %s; detector %s; wake %s; final %s; chat %s"
           cmacs-voice-loop--state
           (if (eq (cmacs-voice-detector-kind) 'vad) "Silero VAD" "energy")
           (if cmacs-voice-loop-wake-phrase
               (format "\"%s\" (%s)" cmacs-voice-loop-wake-phrase
                       (file-name-nondirectory (cmacs-voice-loop--model-path 'wake)))
             "off")
           (file-name-nondirectory (cmacs-voice-loop--model-path 'final))
           (if (buffer-live-p cmacs-voice-loop--chat-buffer)
               (buffer-name cmacs-voice-loop--chat-buffer)
             "none yet")))


;;;; Echo cancellation (PipeWire)

(defconst cmacs-voice-loop-echo-cancel-file
  "~/.config/pipewire/pipewire.conf.d/60-cmacs-echo-cancel.conf"
  "Where `cmacs-voice-loop-echo-cancel-config' offers to write its config.")

(defun cmacs-voice-loop-echo-cancel-text ()
  "The PipeWire drop-in that defines an echo-cancelled microphone."
  "# cmacs voice loop: acoustic echo cancellation.
# Written by M-x cmacs-voice-loop-echo-cancel-config.  Restart PipeWire
# to load it:  systemctl --user restart pipewire pipewire-pulse
# Then point the loop at the new source:
#   (setq cmacs-voice-device \"cmacs-echo-cancel-source\")
#
# monitor.mode makes the canceller use the monitor of the default sink
# as its reference, so whatever plays -- piper included -- is removed
# from the microphone without rerouting any playback.
context.modules = [
  { name = libpipewire-module-echo-cancel
    args = {
      library.name = aec/libspa-aec-webrtc
      monitor.mode = true
      capture.props = {
        node.name    = \"cmacs-echo-cancel-capture\"
        node.passive = true
      }
      source.props = {
        node.name        = \"cmacs-echo-cancel-source\"
        node.description = \"Echo-cancelled microphone (cmacs)\"
      }
    }
  }
]
")

;;;###autoload
(defun cmacs-voice-loop-echo-cancel-config (&optional write)
  "Show a PipeWire config that adds an echo-cancelled microphone.
With prefix argument WRITE, offer to save it as
`cmacs-voice-loop-echo-cancel-file' (never overwriting a file there).
Nothing about the running system is changed: restarting PipeWire is
left to you."
  (interactive "P")
  (let ((text (cmacs-voice-loop-echo-cancel-text))
        (file (expand-file-name cmacs-voice-loop-echo-cancel-file)))
    (if (and write (called-interactively-p 'any))
        (cond
         ((file-exists-p file)
          (user-error "%s already exists; not overwriting it" file))
         ((y-or-n-p (format "Write %s? " file))
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert text))
          (message "Wrote %s -- restart PipeWire, then set cmacs-voice-device"
                   file)))
      (with-current-buffer (get-buffer-create "*cmacs-voice-loop echo-cancel*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert text)
          (goto-char (point-min)))
        (conf-unix-mode)
        (view-mode 1)
        (display-buffer (current-buffer))))
    text))


;;;; Keys

;;;###autoload (define-key cmacs-voice-map (kbd "l") #'cmacs-voice-loop-mode)
;;;###autoload (define-key cmacs-voice-map (kbd "j") #'cmacs-voice-loop-listen-now)

(provide 'cmacs-voice-loop)

;;; cmacs-voice-loop.el ends here
