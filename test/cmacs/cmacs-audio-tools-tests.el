;;; cmacs-audio-tools-tests.el --- The migrated audio and speech tool family  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-audio-tools.el is the audio and speech MCP tool family.
;; The C handlers these tools replaced were deleted once the registry
;; was published by every build with an MCP server.  What they promised
;; a client -- frozen from a real tools/list beforehand, in
;; test/cmacs/data/mcp-wire-schema.json -- is what the first test holds
;; the family to, through cmacs-wire-schema.el: each tool's name, its
;; parameters in order, their types and the required set.
;;
;; The rest is behaviour with the speech engines stubbed: transcription,
;; diarisation and synthesis answer from the engine's callback and never
;; before it, an engine's (:error . MESSAGE) is a failed call, and a
;; backend or component name that names nothing never reaches an engine.
;;
;; Everything runs against a private registry with the C mirror stubbed,
;; so nothing registered here reaches the MCP surface of the Emacs
;; running the tests.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)
;; Beside this file, and named by its place: `make check' compiles
;; and runs the tests with test/cmacs off `load-path', where a bare
;; `require' of a helper fails the whole file -- silently for the count
;; of failed tests, which then covers every file but this one.
(require 'cmacs-wire-schema
         (expand-file-name
          "cmacs-wire-schema"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

(defconst cmacs-audio-tools-tests--migrated
  '("record_audio" "transcribe" "synthesize_speech" "speech_components"
    "speech_set" "speech_models" "speech_diarize" "speech_tag_audio"
    "speech_identify_speaker")
  "The C tools cmacs-audio-tools.el always provides.")

(defconst cmacs-audio-tools-tests--conditional
  '(("list_whisper_models" . IS-CMACS-WHISPER)
    ("list_voices" . IS-CMACS-PIPER))
  "The C tools registered only when a feature flag is set, as (NAME . FLAG).")

(defun cmacs-audio-tools-tests--expected ()
  "Return the wire names this build's cmacs-audio-tools.el registers."
  (append cmacs-audio-tools-tests--migrated
          (cl-loop for (name . flag) in cmacs-audio-tools-tests--conditional
                   when (and (boundp flag) (symbol-value flag))
                   collect name)))

(defun cmacs-audio-tools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-audio-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defmacro cmacs-audio-tools-tests--with-family (&rest body)
  "Run BODY with a private registry holding only the audio family."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       (let ((load-prefer-newer t))
         (load (expand-file-name "lisp/cmacs/cmacs-audio-tools"
                                 (cmacs-audio-tools-tests--root))
               nil t))
       ,@body)))

(defun cmacs-audio-tools-tests--call (name json)
  "Start the tool NAME with JSON; return a cell that receives the reply.
The cell's car becomes (STATUS TEXT) when the tool settles."
  (let ((cell (list nil)))
    (cmacs-brigade-call-tool-async
     name json (lambda (status text) (setcar cell (list status text))))
    cell))


;;;; The family is the C family

(defun cmacs-audio-tools-tests--check-against-c (names)
  "Assert each tool in NAMES matches its frozen wire schema."
  (dolist (name names)
    (cmacs-wire-schema-should-match name)))

(ert-deftest cmacs-audio-tools-test-family-matches-c ()
  "Every migrated tool keeps its frozen name, parameters, types and required set."
  (skip-unless (cmacs-audio-tools-tests--root))
  (cmacs-audio-tools-tests--with-family
    (let ((c (cmacs-wire-schema-names "cmacs-mcp-tools-audio.c"))
          (expected (cmacs-audio-tools-tests--expected)))
      ;; Every tool the C file had is accounted for.
      (should (equal (sort (copy-sequence c) #'string<)
                     (sort (append cmacs-audio-tools-tests--migrated
                                   (mapcar #'car
                                           cmacs-audio-tools-tests--conditional))
                           #'string<)))
      (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                   (cmacs-capability-describe))
                           #'string<)
                     (sort (copy-sequence expected) #'string<)))
      (cmacs-audio-tools-tests--check-against-c expected))))

(ert-deftest cmacs-audio-tools-test-async-and-surfaces ()
  "The engine-running tools are asynchronous; the microphone is not an agent tool."
  (skip-unless (cmacs-audio-tools-tests--root))
  (cmacs-audio-tools-tests--with-family
    (dolist (name '("transcribe" "synthesize_speech" "speech_diarize"
                    "speech_tag_audio" "speech_identify_speaker"))
      (should (plist-get (cmacs-capability-describe-tool name) :async)))
    (let ((surfaces (plist-get (cmacs-capability-describe-tool "record_audio")
                               :surfaces)))
      (should (memq 'mcp surfaces))
      (should-not (memq 'agents surfaces)))))


;;;; Behaviour

(defmacro cmacs-audio-tools-tests--with-speech (&rest body)
  "Run BODY with the speech engines stubbed.
BODY sees `log', a list of (FUNCTION . ARGS) for every stubbed call, and
may set `pcm', `turns', `transcript' and `spoken' to choose what the
decoder, the diariser, the recogniser and the synthesiser answer with."
  (declare (indent 0) (debug t))
  `(let ((log nil)
         (pcm '("PCM" . 16000))
         (turns '((:segments turn-1) (:num-speakers . 2)))
         (transcript '((:text . "hello there") (:segments seg-1)))
         (spoken '((:pcm . "WAVE") (:sample-rate . 22050))))
     (ignore log pcm turns transcript spoken)
     (cl-letf (((symbol-function 'cmacs-speech-backend)
                (lambda (name &rest _)
                  (and (memq name '(whisper sherpa piper)) (list :name name))))
               ((symbol-function 'cmacs-speech-file-pcm)
                (lambda (file callback &rest _)
                  (push (list 'file-pcm file) log)
                  (funcall callback pcm)))
               ((symbol-function 'cmacs-speech-transcribe-file)
                (lambda (file callback &rest keys)
                  (push (cons 'transcribe-file (cons file keys)) log)
                  (funcall callback transcript)))
               ((symbol-function 'cmacs-speech-transcribe)
                (lambda (data callback &rest keys)
                  (push (cons 'transcribe (cons data keys)) log)
                  (funcall callback transcript)))
               ((symbol-function 'cmacs-speech-diarize)
                (lambda (data callback &rest keys)
                  (push (cons 'diarize (cons data keys)) log)
                  (funcall callback turns)))
               ((symbol-function 'cmacs-speech-label-speakers)
                (lambda (&rest args)
                  (push (cons 'label args) log)
                  "Speaker 1: hello there"))
               ((symbol-function 'cmacs-speech-tag-audio)
                (lambda (data callback &rest keys)
                  (push (cons 'tag (cons data keys)) log)
                  (funcall callback
                           '((:events ((:name . "Speech") (:prob . 0.9))
                                      ((:name . "Music") (:prob . 0.1)))))))
               ((symbol-function 'cmacs-speech-synthesize)
                (lambda (text callback &rest keys)
                  (push (cons 'synthesize (cons text keys)) log)
                  (funcall callback spoken)
                  'token))
               ((symbol-function 'cmacs-speech-speak)
                (lambda (&rest args) (push (cons 'speak args) log) 'token))
               ((symbol-function 'cmacs-speech-write-wav)
                (lambda (file &rest args)
                  (push (cons 'write-wav (cons file args)) log)
                  file))
               ((symbol-function 'cmacs-speech-session-set)
                (lambda (&rest args) (push (cons 'session-set args) log) nil))
               ((symbol-function 'cmacs-speech-resolve)
                (lambda (component &rest _)
                  (list :component component :backend 'piper))))
       ,@body)))

(ert-deftest cmacs-audio-tools-test-transcribe-completes ()
  "`transcribe' hands its options to the asynchronous engine and returns the text."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-speech nil t)))
  (cmacs-audio-tools-tests--with-family
    (let ((pending nil))
      (cmacs-audio-tools-tests--with-speech
        ;; Hold the engine's answer back, to see that nothing waited.
        (cl-letf (((symbol-function 'cmacs-speech-transcribe-file)
                   (lambda (file callback &rest keys)
                     (push (cons 'transcribe-file (cons file keys)) log)
                     (setq pending callback))))
          (let ((reply (cmacs-audio-tools-tests--call
                        "transcribe"
                        "{\"audio_path\":\"/tmp/a.ogg\",\"language\":\"en\",\"backend\":\"whisper\",\"model\":\"base\"}")))
            (should pending)
            (should-not (car reply))
            (should (equal (assq 'transcribe-file log)
                           '(transcribe-file "/tmp/a.ogg" :feature rpc
                                             :language "en" :backend whisper
                                             :model "base")))
            (funcall pending '((:text . "hello there")))
            (should (equal (car reply) '(ok "hello there")))))))))

(ert-deftest cmacs-audio-tools-test-transcribe-fails ()
  "An engine error is a failed call; an unknown backend never reaches an engine."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-speech nil t)))
  (cmacs-audio-tools-tests--with-family
    (cmacs-audio-tools-tests--with-speech
      (setq transcript '((:error . "no model installed")))
      (should (equal (car (cmacs-audio-tools-tests--call
                           "transcribe" "{\"audio_path\":\"/tmp/a.wav\"}"))
                     '(error "no model installed")))
      (setq log nil)
      (let ((reply (cmacs-audio-tools-tests--call
                    "transcribe"
                    "{\"audio_path\":\"/tmp/a.wav\",\"backend\":\"no-such-engine-xyzzy\"}")))
        (should (eq (car (car reply)) 'error))
        (should (string-match-p "Unknown speech backend" (cadr (car reply))))
        (should-not log)
        (should-not (intern-soft "no-such-engine-xyzzy"))))))

(ert-deftest cmacs-audio-tools-test-diarize ()
  "Both diarising tools decode, find the turns, transcribe with `stt', and label."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-speech nil t)))
  (cmacs-audio-tools-tests--with-family
    (dolist (call '(("speech_diarize" . "{\"audio_path\":\"/tmp/m.m4a\"}")
                    ("transcribe"
                     . "{\"audio_path\":\"/tmp/m.m4a\",\"diarize\":true}")))
      (cmacs-audio-tools-tests--with-speech
        (ert-info ((car call))
          (should (equal (car (cmacs-audio-tools-tests--call
                               (car call) (cdr call)))
                         '(ok "2 speakers\n\nSpeaker 1: hello there")))
          (should (equal (assq 'file-pcm log) '(file-pcm "/tmp/m.m4a")))
          (should (equal (assq 'diarize log) '(diarize "PCM" :rate 16000)))
          ;; `stt', not the push-to-talk model a bare feature would pick.
          (should (eq (plist-get (cddr (assq 'transcribe log)) :component)
                      'stt))
          (should (equal (assq 'label log) '(label (turn-1) (seg-1)))))))
    ;; Each stage's failure is reported as that stage's.
    (cmacs-audio-tools-tests--with-speech
      (setq pcm '(:error . "cannot read /tmp/gone.wav"))
      (should (equal (car (cmacs-audio-tools-tests--call
                           "speech_diarize"
                           "{\"audio_path\":\"/tmp/gone.wav\"}"))
                     '(error "cannot read /tmp/gone.wav"))))
    (cmacs-audio-tools-tests--with-speech
      (setq turns '((:error . "no diarization model")))
      (should (equal (car (cmacs-audio-tools-tests--call
                           "speech_diarize" "{\"audio_path\":\"/tmp/m.wav\"}"))
                     '(error "Diarization: no diarization model")))
      (should-not (assq 'transcribe log)))))

(ert-deftest cmacs-audio-tools-test-tag-audio ()
  "`speech_tag_audio' prints one event and its probability per line."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-speech nil t)))
  (cmacs-audio-tools-tests--with-family
    (cmacs-audio-tools-tests--with-speech
      (should (equal (car (cmacs-audio-tools-tests--call
                           "speech_tag_audio" "{\"audio_path\":\"/tmp/c.wav\"}"))
                     '(ok "Speech 0.90\nMusic 0.10")))
      (should (equal (assq 'tag log) '(tag "PCM" :rate 16000))))))

(ert-deftest cmacs-audio-tools-test-synthesize ()
  "Without a path the text is spoken; with one a WAV is written and named."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-speech nil t)))
  (cmacs-audio-tools-tests--with-family
    (cmacs-audio-tools-tests--with-speech
      (should (equal (car (cmacs-audio-tools-tests--call
                           "synthesize_speech" "{\"text\":\"done\"}"))
                     '(ok "ok")))
      (should (equal (assq 'speak log) '(speak "done" :feature rpc)))
      (should-not (assq 'synthesize log)))
    (cmacs-audio-tools-tests--with-speech
      (should (equal (car (cmacs-audio-tools-tests--call
                           "synthesize_speech"
                           "{\"text\":\"done\",\"output_path\":\"/tmp/o.wav\",\"voice\":\"amy\",\"backend\":\"piper\"}"))
                     '(ok "/tmp/o.wav")))
      (should (equal (assq 'synthesize log)
                     '(synthesize "done" :feature rpc :voice "amy"
                                  :backend piper)))
      (should (equal (assq 'write-wav log)
                     '(write-wav "/tmp/o.wav" "WAVE" 22050)))
      (should-not (assq 'speak log)))
    (cmacs-audio-tools-tests--with-speech
      (setq spoken '((:error . "no voice installed")))
      (should (equal (car (cmacs-audio-tools-tests--call
                           "synthesize_speech"
                           "{\"text\":\"done\",\"output_path\":\"/tmp/o.wav\"}"))
                     '(error "no voice installed")))
      (should-not (assq 'write-wav log)))))

(ert-deftest cmacs-audio-tools-test-speech-set ()
  "`speech_set' changes the session only, and only for names that exist."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-speech nil t)))
  (cmacs-audio-tools-tests--with-family
    (cmacs-audio-tools-tests--with-speech
      (should (equal (car (cmacs-audio-tools-tests--call
                           "speech_set"
                           "{\"component\":\"tts\",\"backend\":\"piper\",\"model\":\"amy\",\"feature\":\"reader\"}"))
                     '(ok "(:component tts :backend piper)")))
      (should (equal (assq 'session-set log)
                     '(session-set tts piper :model "amy" :feature reader)))
      ;; `auto' is a backend here, though it is not a registered engine.
      (should (eq (car (car (cmacs-audio-tools-tests--call
                             "speech_set"
                             "{\"component\":\"stt\",\"backend\":\"auto\"}")))
                  'ok))
      (setq log nil)
      (dolist (bad '("{\"component\":\"no-such-part\",\"backend\":\"piper\"}"
                     "{\"component\":\"tts\",\"backend\":\"no-such-engine\"}"
                     "{\"component\":\"tts\",\"backend\":\"piper\",\"feature\":\"no-such-feature\"}"))
        (ert-info (bad)
          (should (eq (car (car (cmacs-audio-tools-tests--call
                                 "speech_set" bad)))
                      'error))))
      (should-not log))))

(ert-deftest cmacs-audio-tools-test-record-audio ()
  "`record_audio' starts the recorder and answers with the path."
  (skip-unless (and (cmacs-audio-tools-tests--root)
                    (require 'cmacs-audio nil t)))
  (cmacs-audio-tools-tests--with-family
    (let ((recorded nil)
          (cmacs-audio-output-dir "/tmp/cmacs-audio-tools-tests/"))
      (cl-letf (((symbol-function 'cmacs-audio-record-to-file)
                 (lambda (&rest args) (push args recorded) 1)))
        (should (equal (car (cmacs-audio-tools-tests--call
                             "record_audio"
                             "{\"seconds\":2.5,\"output_path\":\"/tmp/r.wav\"}"))
                       '(ok "/tmp/r.wav")))
        (should (equal (car recorded) '("/tmp/r.wav" 2.5)))
        ;; No path given: a timestamped file in the configured directory,
        ;; and the caller is told which.
        (let ((reply (car (cmacs-audio-tools-tests--call
                           "record_audio" "{\"seconds\":1}"))))
          (should (eq (car reply) 'ok))
          (should (string-match-p
                   "\\`/tmp/cmacs-audio-tools-tests/audio-[0-9]+-[0-9]+\\.wav\\'"
                   (cadr reply)))
          (should (equal (car (car recorded)) (cadr reply))))
        (setq recorded nil)
        (should (eq (car (car (cmacs-audio-tools-tests--call
                               "record_audio" "{\"seconds\":0}")))
                    'error))
        (should-not recorded)))))

(provide 'cmacs-audio-tools-tests)

;;; cmacs-audio-tools-tests.el ends here
