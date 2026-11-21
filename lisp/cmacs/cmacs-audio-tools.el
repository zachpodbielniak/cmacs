;;; cmacs-audio-tools.el --- Audio and speech tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The tools of cmacs/mcp/cmacs-mcp-tools-audio.c, moved onto the
;; capability table (doc_org/cmacs/cmacs-capability.org has the recipe).
;; Wire names, parameter names and the required/optional split are the C
;; ones.  That C file is deleted; the schema these tools must keep is
;; what it published, frozen in test/cmacs/data/mcp-wire-schema.json.
;;
;; What changed, on purpose:
;;
;;   - The engines no longer run on the dispatch thread.  The C called
;;     the `cmacs-speech-*-now' functions, which decode with a
;;     synchronous ffmpeg and then run whisper or sherpa to completion
;;     on the calling thread -- the compositor's, under `emacs --gowl'.
;;     Transcription, diarisation, tagging, speaker identification and
;;     synthesis to a file are :async tools here, built on the
;;     asynchronous half of cmacs-speech.el (`cmacs-speech-file-pcm',
;;     `cmacs-speech-transcribe-file', `cmacs-speech-diarize', ...),
;;     whose engines work on their own threads and answer through a
;;     callback.
;;
;;   - No argument is spliced into Lisp source.  The C wrote a backend
;;     as "'%s" and a component as (intern "%s"); here both are looked up
;;     with `intern-soft' and have to name something cmacs-speech knows.
;;
;;   - A failure is signalled, or handed to `done' in the registry's
;;     "Error: ..." form, rather than returned as ordinary text.
;;
;;   - `record_audio' answers with the path it is recording to, which is
;;     what its description always said.  The C answered with the number
;;     of seconds, leaving a caller that took the default path no way to
;;     learn where the file went.
;;
;; `list_whisper_models' and `list_voices' are registered only by a build
;; with whisper and piper, as in C.
;;
;; The group is `audio', not `speech': cmacs-speech-brigade.el already
;; publishes `speech_transcribe', `speech_who_spoke' and `speech_say' to
;; agents under `speech', and an agent granted that group was not thereby
;; granted the microphone or the session's engine settings.

;;; Code:

(require 'cmacs-brigade-registry)

(defvar cmacs-audio-output-dir)
(defvar cmacs-speech-components)
(defvar cmacs-speech-features)
(defvar IS-CMACS-WHISPER)
(defvar IS-CMACS-PIPER)

(declare-function cmacs-audio-record-to-file "cmacs-audio"
                  (path &optional seconds))
(declare-function cmacs-speech-backend "cmacs-speech" (name))
(declare-function cmacs-speech-file-pcm "cmacs-speech" (file callback))
(declare-function cmacs-speech-transcribe "cmacs-speech"
                  (pcm callback &rest keys))
(declare-function cmacs-speech-transcribe-file "cmacs-speech"
                  (file callback &rest keys))
(declare-function cmacs-speech-diarize "cmacs-speech"
                  (pcm callback &rest keys))
(declare-function cmacs-speech-tag-audio "cmacs-speech"
                  (pcm callback &rest keys))
(declare-function cmacs-speech-identify-speaker "cmacs-speech"
                  (pcm callback &rest keys))
(declare-function cmacs-speech-label-speakers "cmacs-speech" (turns segments))
(declare-function cmacs-speech-synthesize "cmacs-speech"
                  (text callback &rest keys))
(declare-function cmacs-speech-speak "cmacs-speech" (text &rest keys))
(declare-function cmacs-speech-write-wav "cmacs-speech" (file pcm rate))
(declare-function cmacs-speech-describe-resolution "cmacs-speech" ())
(declare-function cmacs-speech-session-set "cmacs-speech"
                  (component backend &rest plist))
(declare-function cmacs-speech-resolve "cmacs-speech"
                  (component &optional feature))
(declare-function cmacs-speech-models "cmacs-speech-models" (&rest keys))
(declare-function cmacs-whisper-list-models "cmacs-whisper" ())
(declare-function cmacs-piper-list-voices "cmacs-piper" ())


;;;; Arguments

(defun cmacs-audio-tools--text (value)
  "Return VALUE when it is a non-empty string, else nil."
  (and (stringp value) (not (string-empty-p value)) value))

(defun cmacs-audio-tools--required (value what)
  "Return VALUE, or signal that the required argument WHAT is missing."
  (or (cmacs-audio-tools--text value)
      (error "Missing required argument: %s" what)))

(defun cmacs-audio-tools--failure (message)
  "Return MESSAGE in the form the registry reads as a failed call."
  (concat "Error: " (if (stringp message) message (format "%s" message))))

(defun cmacs-audio-tools--known (name table what)
  "Return NAME as the symbol that heads an entry of TABLE, or signal.
TABLE is `cmacs-speech-components' or `cmacs-speech-features'; WHAT
says which, for the error.  nil when NAME is blank."
  (when (cmacs-audio-tools--text name)
    (let ((symbol (intern-soft name)))
      (unless (and symbol (assq symbol table))
        (error "Unknown speech %s `%s' (one of: %s)" what name
               (mapconcat (lambda (e) (symbol-name (car e))) table ", ")))
      symbol)))

(defun cmacs-audio-tools--backend (name &optional allow-auto)
  "Return NAME as a registered speech backend symbol; nil when blank.
With ALLOW-AUTO, `auto' is accepted as well."
  (when (cmacs-audio-tools--text name)
    (let ((symbol (intern-soft name)))
      (unless (and symbol
                   (or (and allow-auto (eq symbol 'auto))
                       (cmacs-speech-backend symbol)))
        (error "Unknown speech backend `%s'" name))
      symbol)))

(defun cmacs-audio-tools--answer (done result render)
  "Settle DONE from RESULT, an engine's result alist.
An (:error . MESSAGE) entry is a failure.  Otherwise RENDER is called
with RESULT and its value is the answer; an error it signals is a
failure too.  These run in engine callbacks, where a signal would leave
the caller waiting for its timeout instead of hearing what went wrong."
  (funcall done
           (condition-case err
               (if (assq :error result)
                   (cmacs-audio-tools--failure (alist-get :error result))
                 (funcall render result))
             (error (cmacs-audio-tools--failure (error-message-string err))))))

(defun cmacs-audio-tools--with-pcm (done path function)
  "Decode the audio or video file PATH, then call FUNCTION with PCM and RATE.
A file that cannot be read or decoded settles DONE with the reason."
  (cmacs-speech-file-pcm
   path
   (lambda (got)
     (if (eq (car-safe got) :error)
         (funcall done (cmacs-audio-tools--failure (cdr got)))
       (condition-case err
           (funcall function (car got) (cdr got))
         (error (funcall done (cmacs-audio-tools--failure
                               (error-message-string err)))))))))

(defun cmacs-audio-tools--who-spoke (done path)
  "Settle DONE with a speaker-labelled transcript of the file PATH.
The asynchronous form of `cmacs-speech-who-spoke-now': decode, find the
speaker turns, transcribe, then label the transcript's segments."
  (cmacs-audio-tools--with-pcm
   done path
   (lambda (pcm rate)
     (cmacs-speech-diarize
      pcm
      (lambda (turns)
        (if (assq :error turns)
            (funcall done (cmacs-audio-tools--failure
                           (format "Diarization: %s"
                                   (alist-get :error turns))))
          (cmacs-speech-transcribe
           pcm
           (lambda (transcript)
             (if (assq :error transcript)
                 (funcall done (cmacs-audio-tools--failure
                                (format "Transcription: %s"
                                        (alist-get :error transcript))))
               (cmacs-audio-tools--answer
                done transcript
                (lambda (tr)
                  (format "%d speakers\n\n%s"
                          (alist-get :num-speakers turns)
                          (cmacs-speech-label-speakers
                           (alist-get :segments turns)
                           (alist-get :segments tr)))))))
           ;; `stt' explicitly: with a feature and no component the
           ;; asynchronous function picks `stt-live', the push-to-talk
           ;; model, which is the wrong one for a recording.
           :component 'stt :feature 'rpc :rate rate)))
      :rate rate))))


;;;; Recording

(cmacs-brigade-deftool record-audio
  "Capture microphone audio for SECONDS into OUTPUT_PATH (WAV). \
Returns the output path on success."
    ((seconds number "Duration in seconds")
     (output_path string "Optional WAV path" :optional t))
  ;; Not on the `agents' surface: the C tool was reachable over MCP
  ;; only, and the microphone is not something an in-process agent
  ;; holding a wildcard allowlist should acquire by a migration.
  :group 'audio :surfaces '(mcp dbus cli) :cli "audio record"
  :destructive t
  :undo '(irreversible "what the microphone heard is a new recording")
  :example "emacsctl tool audio record --seconds 5"
  (require 'cmacs-audio)
  (unless (and (numberp seconds) (> seconds 0))
    (error "record_audio: 'seconds' must be a positive number"))
  (let ((path (or (cmacs-audio-tools--text output_path)
                  (expand-file-name
                   (format-time-string "audio-%Y%m%d-%H%M%S.wav")
                   cmacs-audio-output-dir))))
    ;; Returns at once; the recorder writes PATH from a timer when
    ;; SECONDS have passed.
    (cmacs-audio-record-to-file path seconds)
    path))


;;;; Speech, through cmacs-speech: whichever engine M-x cmacs-speech chose

(cmacs-brigade-deftool transcribe
  "Transcribe an audio or video file with the engine M-x cmacs-speech \
chose (whisper.cpp or sherpa-onnx).  Returns the transcript; with \
diarize, a speaker-labelled one."
    ((audio_path string "Audio or video file (any format ffmpeg reads)")
     (language string "ISO 2-letter code hint" :optional t)
     (backend string "whisper or sherpa (default: as configured)" :optional t)
     (model string "Installed model id (see speech_models)" :optional t)
     (diarize boolean "Label who spoke when" :optional t))
  :group 'audio :async t :timeout 1200
  :example "emacsctl tool audio transcribe --audio-path ~/meeting.m4a"
  (require 'cmacs-speech)
  (let ((path (cmacs-audio-tools--required audio_path "audio_path"))
        (backend (cmacs-audio-tools--backend backend)))
    (if diarize
        (cmacs-audio-tools--who-spoke done path)
      (apply #'cmacs-speech-transcribe-file
             path
             (lambda (result)
               (cmacs-audio-tools--answer
                done result
                (lambda (r) (or (alist-get :text r)
                                (error "The engine returned no text")))))
             :feature 'rpc
             (append (and (cmacs-audio-tools--text language)
                          (list :language language))
                     (and backend (list :backend backend))
                     (and (cmacs-audio-tools--text model)
                          (list :model model)))))))

(cmacs-brigade-deftool synthesize-speech
  "Speak TEXT with the configured voice, or write it to OUTPUT_PATH as \
a WAV file.  VOICE picks an installed voice (see speech_models)."
    ((text string "Text to speak")
     (output_path string "Optional WAV path" :optional t)
     (voice string "Installed voice id" :optional t)
     (backend string "sherpa or piper" :optional t))
  :group 'audio :async t :timeout 300 :cli "audio synthesize"
  :destructive t
  :undo '(irreversible "spoken audio cannot be taken back")
  :example "emacsctl tool audio synthesize --text 'Build finished'"
  (require 'cmacs-speech)
  (let ((text (cmacs-audio-tools--required text "text"))
        (output (cmacs-audio-tools--text output_path))
        (backend (cmacs-audio-tools--backend backend)))
    (if (not output)
        ;; Speaking is already asynchronous: this starts it and answers.
        ;; VOICE and BACKEND apply to the file form only, as in C.
        (progn
          (cmacs-speech-speak text :feature 'rpc)
          (funcall done "ok"))
      (apply #'cmacs-speech-synthesize
             text
             (lambda (result)
               (cmacs-audio-tools--answer
                done result
                (lambda (r)
                  ;; A real WAV (header and rate), not raw PCM.
                  (cmacs-speech-write-wav output (alist-get :pcm r)
                                          (alist-get :sample-rate r)))))
             :feature 'rpc
             (append (and (cmacs-audio-tools--text voice) (list :voice voice))
                     (and backend (list :backend backend)))))))

(cmacs-brigade-deftool speech-components
  "Which engine and model serve each speech component and feature, and \
why (tab-separated: component[/feature], backend, model, source)."
    ()
  :group 'audio :cli "audio components"
  :example "emacsctl tool audio components"
  (require 'cmacs-speech)
  (mapconcat
   (lambda (r)
     (format "%s%s\t%s\t%s\t%s"
             (plist-get r :component)
             (if (plist-get r :feature)
                 (format "/%s" (plist-get r :feature))
               "")
             (or (plist-get r :backend) "-")
             (or (plist-get r :model) "-")
             (plist-get r :source)))
   (cmacs-speech-describe-resolution) "\n"))

(cmacs-brigade-deftool speech-set
  "Choose the engine (and model) for a speech component, for this \
session only -- the user's saved choices are never changed."
    ((component string "stt, stt-live, stt-stream, wake, vad, tts, diarize, \
speaker-id, punctuate, lang-id, audio-tag, denoise, separate")
     (backend string "whisper, sherpa, piper, or auto")
     (model string "Installed model id" :optional t)
     (feature string "Limit to one feature (dictate, voice-loop, ...)"
              :optional t))
  :group 'audio :cli "audio set"
  ;; Changes this session's engine choice, so it is not read-only; but
  ;; `emacsctl speech set' has always reached it, and a destructive
  ;; tool is off dbus/cli unless it says otherwise.
  :destructive t :surfaces '(agents mcp dbus cli menu)
  :undo '(irreversible "the previous speech setting is not kept")
  :example "emacsctl tool audio set --component tts --backend piper"
  (require 'cmacs-speech)
  (unless (and (cmacs-audio-tools--text component)
               (cmacs-audio-tools--text backend))
    (error "Missing required argument: component and backend"))
  (let ((component (cmacs-audio-tools--known
                    component cmacs-speech-components "component"))
        (backend (cmacs-audio-tools--backend backend t))
        (feature (cmacs-audio-tools--known
                  feature cmacs-speech-features "feature")))
    ;; Session only: an agent never rewrites the user's saved choices.
    (apply #'cmacs-speech-session-set component backend
           (append (and (cmacs-audio-tools--text model) (list :model model))
                   (and feature (list :feature feature))))
    (format "%S" (cmacs-speech-resolve component))))

(cmacs-brigade-deftool speech-models
  "Installed and downloadable speech models (tab-separated: state, \
backend, id, components, description).  Downloads are started by the \
user in M-x cmacs-speech."
    ((component string "Only models serving this component" :optional t))
  :group 'audio :cli "audio models"
  :example "emacsctl tool audio models --component tts"
  (require 'cmacs-speech)
  (require 'cmacs-speech-models)
  (let ((component (cmacs-audio-tools--known
                    component cmacs-speech-components "component")))
    (mapconcat
     (lambda (m)
       (format "%s\t%s\t%s\t%s\t%s"
               (if (plist-get m :installed) "installed" "available")
               (plist-get m :backend) (plist-get m :id)
               (mapconcat #'symbol-name (plist-get m :components) ",")
               (or (plist-get m :description) "")))
     (if component
         (cmacs-speech-models :component component)
       (cmacs-speech-models))
     "\n")))

(cmacs-brigade-deftool speech-diarize
  "Who spoke when in an audio or video file: a speaker-labelled transcript."
    ((audio_path string "Audio or video file"))
  :group 'audio :async t :timeout 1200 :cli "audio diarize"
  :example "emacsctl tool audio diarize --audio-path ~/meeting.m4a"
  (require 'cmacs-speech)
  (cmacs-audio-tools--who-spoke
   done (cmacs-audio-tools--required audio_path "audio_path")))

(cmacs-brigade-deftool speech-tag-audio
  "What sounds are in an audio file (speech, music, laughter, ...), with probabilities."
    ((audio_path string "Audio or video file"))
  :group 'audio :async t :timeout 600 :cli "audio tag"
  :example "emacsctl tool audio tag --audio-path ~/clip.wav"
  (require 'cmacs-speech)
  (cmacs-audio-tools--with-pcm
   done (cmacs-audio-tools--required audio_path "audio_path")
   (lambda (pcm rate)
     (cmacs-speech-tag-audio
      pcm
      (lambda (result)
        (cmacs-audio-tools--answer
         done result
         (lambda (r)
           (mapconcat (lambda (e)
                        (format "%s %.2f" (alist-get :name e)
                                (alist-get :prob e)))
                      (alist-get :events r) "\n"))))
      :rate rate))))

(cmacs-brigade-deftool speech-identify-speaker
  "Which enrolled speaker an audio file sounds like, best matches first."
    ((audio_path string "Audio or video file"))
  :group 'audio :async t :timeout 600 :cli "audio identify-speaker"
  :example "emacsctl tool audio identify-speaker --audio-path ~/clip.wav"
  (require 'cmacs-speech)
  (cmacs-audio-tools--with-pcm
   done (cmacs-audio-tools--required audio_path "audio_path")
   (lambda (pcm rate)
     (cmacs-speech-identify-speaker
      pcm
      (lambda (result)
        (cmacs-audio-tools--answer
         done result
         (lambda (r)
           (mapconcat (lambda (m)
                        (format "%s %.2f" (alist-get :name m)
                                (alist-get :score m)))
                      (alist-get :matches r) "\n"))))
      :rate rate))))


;;;; Model listings, for the engines this build has

(when (bound-and-true-p IS-CMACS-WHISPER)
  (cmacs-brigade-deftool list-whisper-models
    "List whisper.cpp models available in cmacs-whisper-models-directory."
      ()
    :group 'audio :cli "audio whisper-models"
    :example "emacsctl tool audio whisper-models"
    (require 'cmacs-whisper)
    (format "%S" (cmacs-whisper-list-models))))

(when (bound-and-true-p IS-CMACS-PIPER)
  (cmacs-brigade-deftool list-voices
    "List Piper voice .onnx files in cmacs-piper-voices-directory."
      ()
    :group 'audio :cli "audio voices"
    :example "emacsctl tool audio voices"
    (require 'cmacs-piper)
    (format "%S" (cmacs-piper-list-voices))))

(provide 'cmacs-audio-tools)

;;; cmacs-audio-tools.el ends here
