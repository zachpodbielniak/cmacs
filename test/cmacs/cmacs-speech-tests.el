;;; cmacs-speech-tests.el --- ERT for the cmacs-speech dispatch layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The dispatch layer is pure Lisp: these tests register fake backends
;; and never touch an engine, so they run in any build.  Model-directory
;; recognition is tested on directories made here, laid out like
;; sherpa-onnx's release archives.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-speech)
(require 'cmacs-speech-sherpa)

(defmacro cmacs-speech-test--isolated (&rest body)
  "Run BODY with empty config layers, a private state file and test backends."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "cmacs-speech-test" t))
          (cmacs-speech-state-file (expand-file-name "speech.eld" dir))
          (cmacs-speech-config nil)
          (cmacs-speech-override nil)
          (cmacs-speech--session nil)
          (cmacs-speech--ui nil)
          (cmacs-speech--ui-loaded nil)
          (cmacs-speech-config-changed-hook nil)
          (cmacs-speech-event-functions nil)
          (cmacs-speech--backends (make-hash-table :test 'eq))
          (cmacs-speech-backend-order nil)
          (cmacs-speech-auto-preference '((stt alpha beta) (tts beta alpha))))
     (cmacs-speech-define-backend
      'alpha :components '(stt stt-live tts)
      :default-model (lambda (c) (format "alpha-%s" c))
      :models (lambda (c) (list (format "alpha-%s" c) "alpha-big"))
      :transcribe (lambda (r _pcm _rate cb)
                    (funcall cb (list (cons :text (format "alpha:%s" (plist-get r :model)))))))
     (cmacs-speech-define-backend
      'beta :components '(stt tts)
      :default-model (lambda (c) (format "beta-%s" c))
      :transcribe (lambda (r _pcm _rate cb)
                    (funcall cb (list (cons :text (format "beta:%s" (plist-get r :model))))))
      :synthesize (lambda (_r text cb _chunk)
                    (funcall cb (list (cons :pcm (make-string (* 2 (length text)) 0 t))
                                      (cons :sample-rate 16000)))
                    'tok))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

;;;; Resolution

(ert-deftest cmacs-speech-test-auto-picks-preference ()
  (cmacs-speech-test--isolated
    (let ((r (cmacs-speech-resolve 'stt)))
      (should (eq (plist-get r :backend) 'alpha))
      (should (equal (plist-get r :model) "alpha-stt"))
      (should (eq (plist-get r :source) 'auto)))
    (should (eq (plist-get (cmacs-speech-resolve 'tts) :backend) 'beta))))

(ert-deftest cmacs-speech-test-auto-skips-unavailable ()
  (cmacs-speech-test--isolated
    (cmacs-speech-define-backend 'alpha :components '(stt)
                                 :available-p (lambda (_c) nil)
                                 :default-model (lambda (_c) "x"))
    (should (eq (plist-get (cmacs-speech-resolve 'stt) :backend) 'beta))))

(ert-deftest cmacs-speech-test-auto-needs-a-model ()
  "A backend without an installed model is not chosen by `auto'."
  (cmacs-speech-test--isolated
    (cmacs-speech-define-backend 'alpha :components '(stt)
                                 :default-model (lambda (_c) nil))
    (should (eq (plist-get (cmacs-speech-resolve 'stt) :backend) 'beta))))

(ert-deftest cmacs-speech-test-nothing-serves ()
  (cmacs-speech-test--isolated
    (should (null (plist-get (cmacs-speech-resolve 'diarize) :backend)))
    (should-not (cmacs-speech-can-p 'diarize))))

(ert-deftest cmacs-speech-test-precedence ()
  "override > session > init > ui > auto."
  (cmacs-speech-test--isolated
    (cmacs-speech-ui-set 'stt 'beta :model "ui-model")
    (should (eq (plist-get (cmacs-speech-resolve 'stt) :source) 'ui))
    (should (equal (plist-get (cmacs-speech-resolve 'stt) :model) "ui-model"))
    (cmacs-speech-set 'stt 'alpha :model "init-model")
    (should (eq (plist-get (cmacs-speech-resolve 'stt) :source) 'init))
    (should (equal (plist-get (cmacs-speech-resolve 'stt) :model) "init-model"))
    (cmacs-speech-session-set 'stt 'beta :model "session-model")
    (should (eq (plist-get (cmacs-speech-resolve 'stt) :source) 'session))
    (cmacs-speech-with-config '((stt alpha :model "scoped"))
      (should (eq (plist-get (cmacs-speech-resolve 'stt) :source) 'override))
      (should (equal (plist-get (cmacs-speech-resolve 'stt) :model) "scoped")))
    (cmacs-speech-session-unset 'stt)
    (should (eq (plist-get (cmacs-speech-resolve 'stt) :source) 'init))))

(ert-deftest cmacs-speech-test-feature-beats-component ()
  "A feature entry wins over a component entry, whatever their layers."
  (cmacs-speech-test--isolated
    (cmacs-speech-set 'stt-live 'alpha :model "init-wide")
    (cmacs-speech-ui-set 'stt-live 'alpha :model "ui-dictate" :feature 'dictate)
    (should (equal (plist-get (cmacs-speech-resolve 'stt-live 'dictate) :model) "ui-dictate"))
    (should (equal (plist-get (cmacs-speech-resolve 'stt-live 'voice-loop) :model) "init-wide"))
    ;; ... but init naming the same feature beats the UI.
    (cmacs-speech-set 'stt-live 'alpha :model "init-dictate" :feature 'dictate)
    (should (equal (plist-get (cmacs-speech-resolve 'stt-live 'dictate) :model) "init-dictate"))))

(ert-deftest cmacs-speech-test-configured-auto ()
  "An entry may say `auto' and still carry options."
  (cmacs-speech-test--isolated
    (cmacs-speech-set 'tts 'auto :speed 1.3)
    (let ((r (cmacs-speech-resolve 'tts)))
      (should (eq (plist-get r :backend) 'beta))
      (should (eq (plist-get r :source) 'init))
      (should (plist-get r :auto))
      (should (= (cmacs-speech-option r :speed) 1.3)))))

(ert-deftest cmacs-speech-test-options-exclude-model-and-feature ()
  (cmacs-speech-test--isolated
    (cmacs-speech-set 'tts 'beta :model "m" :feature 'reader :speaker 3)
    (let ((r (cmacs-speech-resolve 'tts 'reader)))
      (should (equal (plist-get r :options) '(:speaker 3))))))

(ert-deftest cmacs-speech-test-set-validates-component ()
  (cmacs-speech-test--isolated
    (should-error (cmacs-speech-set 'nonsense 'alpha))))

(ert-deftest cmacs-speech-test-set-replaces-same-key ()
  (cmacs-speech-test--isolated
    (cmacs-speech-set 'stt 'alpha :model "a")
    (cmacs-speech-set 'stt 'beta :model "b")
    (cmacs-speech-set 'stt 'alpha :model "c" :feature 'transcribe)
    (should (= (length cmacs-speech-config) 2))
    (should (equal (plist-get (cmacs-speech-resolve 'stt) :model) "b"))))

;;;; State file

(ert-deftest cmacs-speech-test-state-file-round-trip ()
  (cmacs-speech-test--isolated
    (cmacs-speech-ui-set 'tts 'beta :model "v1" :speaker 2)
    (cmacs-speech-ui-set 'stt-live 'alpha :feature 'dictate)
    (should (file-exists-p cmacs-speech-state-file))
    ;; Forget the in-memory copy and read it back.
    (setq cmacs-speech--ui nil cmacs-speech--ui-loaded nil)
    (let ((r (cmacs-speech-resolve 'tts)))
      (should (eq (plist-get r :source) 'ui))
      (should (equal (plist-get r :model) "v1"))
      (should (= (cmacs-speech-option r :speaker) 2)))
    (cmacs-speech-ui-unset 'tts)
    (setq cmacs-speech--ui nil cmacs-speech--ui-loaded nil)
    (should (eq (plist-get (cmacs-speech-resolve 'tts) :source) 'auto))))

(ert-deftest cmacs-speech-test-init-never-persisted ()
  "init.el entries and session overrides never reach the state file."
  (cmacs-speech-test--isolated
    (cmacs-speech-set 'stt 'alpha :model "init-only")
    (cmacs-speech-session-set 'tts 'beta :model "session-only")
    (cmacs-speech-ui-set 'denoise 'beta)
    (let ((text (with-temp-buffer (insert-file-contents cmacs-speech-state-file)
                                  (buffer-string))))
      (should-not (string-match-p "init-only" text))
      (should-not (string-match-p "session-only" text))
      (should (string-match-p "denoise" text)))))

(ert-deftest cmacs-speech-test-unreadable-state-file ()
  "A corrupt state file is ignored, not fatal."
  (cmacs-speech-test--isolated
    (with-temp-file cmacs-speech-state-file (insert "((entries . (unclosed"))
    (let ((inhibit-message t))
      (should (eq (plist-get (cmacs-speech-resolve 'stt) :source) 'auto)))))

(ert-deftest cmacs-speech-test-init-owned-p ()
  (cmacs-speech-test--isolated
    (cmacs-speech-set 'tts 'beta)
    (should (cmacs-speech-init-owned-p 'tts))
    (should-not (cmacs-speech-init-owned-p 'tts 'reader))
    (should-not (cmacs-speech-init-owned-p 'stt))))

(ert-deftest cmacs-speech-test-changed-hook ()
  (cmacs-speech-test--isolated
    (let ((n 0))
      (add-hook 'cmacs-speech-config-changed-hook (lambda () (cl-incf n)))
      (cmacs-speech-set 'stt 'alpha)
      (cmacs-speech-ui-set 'tts 'beta)
      (cmacs-speech-session-set 'stt 'beta)
      (should (= n 3)))))

;;;; Dispatch

(ert-deftest cmacs-speech-test-transcribe-dispatches-and-decorates ()
  (cmacs-speech-test--isolated
    (let (res events)
      (add-hook 'cmacs-speech-event-functions (lambda (e p) (push (cons e p) events)))
      (cmacs-speech-transcribe "pcm" (lambda (r) (setq res r)))
      (should (equal (alist-get :text res) "alpha:alpha-stt"))
      (should (eq (alist-get :backend res) 'alpha))
      (should (eq (caar events) 'transcription))
      ;; A feature resolves stt-live, and BACKEND forces an engine.
      (cmacs-speech-transcribe "pcm" (lambda (r) (setq res r)) :backend 'beta :model "forced")
      (should (equal (alist-get :text res) "beta:forced")))))

(ert-deftest cmacs-speech-test-transcribe-never-signals ()
  (cmacs-speech-test--isolated
    (let (res)
      (cmacs-speech-define-backend 'alpha :components '(stt stt-live)
                                   :default-model (lambda (_c) "m")
                                   :transcribe (lambda (&rest _) (error "Boom")))
      (cmacs-speech-transcribe "pcm" (lambda (r) (setq res r)))
      (should (equal (alist-get :error res) "Boom")))))

(ert-deftest cmacs-speech-test-missing-op-is-clear ()
  (cmacs-speech-test--isolated
    (let (res)
      (cmacs-speech-set 'tts 'alpha)
      (cmacs-speech-synthesize "hi" (lambda (r) (setq res r)))
      (should (string-match-p "cannot do" (alist-get :error res))))))

(ert-deftest cmacs-speech-test-synthesize-to-file-writes-wav ()
  (cmacs-speech-test--isolated
    (let ((f (expand-file-name "out.wav" (file-name-directory cmacs-speech-state-file)))
          done)
      (cmacs-speech-synthesize-to-file "hello" f (lambda (x) (setq done x)))
      (should (equal done f))
      (let ((wav (cmacs-speech-read-wav f)))
        (should (= (cdr wav) 16000))
        (should (= (length (car wav)) 10))))))

(ert-deftest cmacs-speech-test-event-hook-errors-contained ()
  (cmacs-speech-test--isolated
    (let (res (inhibit-message t))
      (add-hook 'cmacs-speech-event-functions (lambda (&rest _) (error "Hook broke")))
      (cmacs-speech-transcribe "pcm" (lambda (r) (setq res r)))
      (should (alist-get :text res)))))

(ert-deftest cmacs-speech-test-wav-round-trip-without-sherpa ()
  "The Lisp WAV reader handles a 16-bit file and keeps the first channel."
  (let ((f (make-temp-file "w" nil ".wav")))
    (unwind-protect
        (progn
          (cmacs-speech-write-wav f (unibyte-string 1 2 3 4) 8000)
          (cl-letf (((symbol-function 'cmacs-sherpa-read-wav) nil))
            (fmakunbound 'cmacs-sherpa-read-wav)
            (let ((r (cmacs-speech-read-wav f)))
              (should (= (cdr r) 8000))
              (should (equal (car r) (unibyte-string 1 2 3 4))))))
      (delete-file f))))

;;;; Sherpa model directories

(defun cmacs-speech-test--model-dir (root name &rest files)
  "Make ROOT/NAME with empty FILES (a trailing / makes a directory)."
  (let ((d (expand-file-name name root)))
    (make-directory d t)
    (dolist (f files)
      (if (string-suffix-p "/" f)
          (make-directory (expand-file-name f d) t)
        (with-temp-file (expand-file-name f d))))
    d))

(ert-deftest cmacs-speech-test-sherpa-model-spec ()
  "Family recognition from file names, int8 preferred."
  (let ((root (make-temp-file "models" t))
        (cmacs-speech-sherpa-prefer-int8 t))
    (unwind-protect
        (cl-flet ((kind (name &rest files)
                    (car (cmacs-speech-sherpa-model-spec
                          (apply #'cmacs-speech-test--model-dir root name files)))))
          (should (eq (kind "silero_vad" "silero_vad.onnx") 'vad))
          (should (eq (kind "gtcrn_simple" "gtcrn_simple.onnx") 'denoise))
          (should (eq (kind "sherpa-onnx-kws-zipformer-x" "encoder-a.onnx" "decoder-a.onnx"
                            "joiner-a.onnx" "tokens.txt")
                      'kws))
          (should (eq (kind "sherpa-onnx-streaming-zipformer-en" "encoder-1.onnx"
                            "encoder-1.int8.onnx" "decoder-1.onnx" "joiner-1.onnx" "tokens.txt")
                      'stream-asr))
          (should (eq (kind "sherpa-onnx-whisper-tiny.en" "tiny.en-encoder.onnx"
                            "tiny.en-decoder.onnx" "tiny.en-tokens.txt")
                      'asr))
          (should (eq (kind "sherpa-onnx-moonshine-tiny" "preprocess.onnx" "encode.int8.onnx"
                            "uncached_decode.int8.onnx" "cached_decode.int8.onnx" "tokens.txt")
                      'asr))
          (should (eq (kind "vits-piper-en_US-amy-low" "en_US-amy-low.onnx" "tokens.txt"
                            "espeak-ng-data/")
                      'tts))
          (should (eq (kind "kokoro-en-v0_19" "model.onnx" "voices.bin" "tokens.txt"
                            "espeak-ng-data/")
                      'tts))
          (should (eq (kind "sherpa-onnx-pyannote-segmentation-3-0" "model.onnx") 'diarize))
          (should (eq (kind "3dspeaker_speech_campplus" "3dspeaker_speech_campplus.onnx")
                      'speaker))
          (should (null (kind "random-dir" "notes.txt")))
          ;; int8 is preferred, and paths are absolute.
          (let ((spec (cmacs-speech-sherpa-model-spec (expand-file-name "sherpa-onnx-streaming-zipformer-en" root))))
            (should (string-suffix-p "encoder-1.int8.onnx" (plist-get (cdr spec) :transducer.encoder)))
            (should (file-name-absolute-p (plist-get (cdr spec) :tokens))))
          ;; Piper voices: cmacs phonemizes, so the espeak data goes to
          ;; cmacs's own key, not the deprecated sherpa one.
          (let ((spec (cmacs-speech-sherpa-model-spec (expand-file-name "vits-piper-en_US-amy-low" root))))
            (should (plist-get (cdr spec) :espeak-data-dir))
            (should-not (plist-member (cdr spec) :vits.data-dir))))
      (delete-directory root t))))

(ert-deftest cmacs-speech-test-sherpa-models-by-component ()
  (let* ((root (make-temp-file "models" t))
         (cmacs-speech-models-directory (make-temp-file "store" t))
         (cmacs-speech-models-extra-directories nil)
         (cmacs-speech-system-models-directory "/nonexistent")
         (cmacs-speech-sherpa-models-directories (list root))
         (cmacs-speech-sherpa--spec-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (cmacs-speech-test--model-dir root "silero_vad" "silero_vad.onnx")
          (cmacs-speech-test--model-dir root "sherpa-onnx-moonshine-tiny" "preprocess.onnx"
                                        "encode.onnx" "uncached_decode.onnx"
                                        "cached_decode.onnx" "tokens.txt")
          (should (equal (mapcar #'car (cmacs-speech-sherpa-models 'vad)) '("silero_vad")))
          (should (equal (mapcar #'car (cmacs-speech-sherpa-models 'stt-live))
                         '("sherpa-onnx-moonshine-tiny")))
          (should (equal (cmacs-speech-sherpa-default-model 'stt) "sherpa-onnx-moonshine-tiny"))
          (should (null (cmacs-speech-sherpa-default-model 'tts))))
      (delete-directory root t))))

(ert-deftest cmacs-speech-test-sherpa-vad-probs-per-frame ()
  "TEN-VAD's 256-sample windows are folded into 512-sample frames."
  (should (equal (cmacs-speech-sherpa--vad-probs [0.0 1.0 0.0 0.0 1.0 1.0] 256)
                 [1.0 0.0 1.0]))
  (should (equal (cmacs-speech-sherpa--vad-probs [0.0 1.0] 512) [0.0 1.0])))

;;;; cmacs-voice routes through the speech layer

(ert-deftest cmacs-speech-test-voice-transcribe-uses-feature ()
  "`cmacs-voice-transcribe' asks the speech layer for FEATURE's engine,
and wipes the PCM only once the result is in."
  (require 'cmacs-voice)
  (cmacs-speech-test--isolated
    (let ((pcm (make-string 4 ?x t)) seen res)
      (cmacs-speech-define-backend
       'alpha :components '(stt-live)
       :default-model (lambda (_c) "m")
       :transcribe (lambda (r p _rate cb)
                     (setq seen (list (plist-get r :feature) (copy-sequence p)))
                     (funcall cb '((:text . "ok")))))
      (cmacs-voice-transcribe pcm (lambda (r) (setq res r)) :feature 'dictate)
      (should (equal seen (list 'dictate "xxxx")))
      (should (equal (alist-get :text res) "ok"))
      (should (equal pcm (make-string 4 0 t))))))

(ert-deftest cmacs-speech-test-dictate-streams ()
  "Dictation feeds a streaming engine: partials show, finals insert."
  (require 'cmacs-whisper-dictate)
  (cmacs-speech-test--isolated
    (let (consumer fed stream-cb
          (cmacs-whisper-dictate-auto-punctuate nil)
          (cmacs-whisper-dictate--stream nil)
          (cmacs-whisper-dictate--buffer nil)
          (cmacs-voice-tick-functions nil))
      (cmacs-speech-define-backend
       'alpha :components '(stt-stream)
       :default-model (lambda (_c) "streamer")
       :stream-open (lambda (_r on-result) (setq stream-cb on-result) 'obj)
       :stream-feed (lambda (_o pcm) (push pcm fed))
       :stream-finish #'ignore :stream-close #'ignore)
      (cl-letf (((symbol-function 'cmacs-voice-acquire)
                 (lambda (_id &rest keys) (setq consumer (plist-get keys :consumer))))
                ((symbol-function 'cmacs-voice-owners)
                 (lambda () (and consumer '(dictate))))
                ((symbol-function 'cmacs-voice-release)
                 (lambda (_id) (setq consumer nil)))
                ((symbol-function 'cmacs-voice--drain) #'ignore)
                ((symbol-function 'cmacs-whisper-dictate--set-state) #'ignore)
                ((symbol-function 'cmacs-voice-transcribe)
                 (lambda (&rest _) (error "The windowed whisper path ran"))))
        (with-temp-buffer
          (let ((inhibit-message t))
            (cmacs-whisper-dictate--start))
          (should cmacs-whisper-dictate--stream)
          (funcall consumer "pcm-1")
          (should (equal fed '("pcm-1")))
          (funcall stream-cb '((:partial . "HELLO THE")))
          (should (string-match-p "Hello the"
                                  (overlay-get cmacs-whisper-dictate--overlay 'after-string)))
          (funcall stream-cb '((:partial . "HELLO THERE") (:final . "HELLO THERE")
                               (:start . 0) (:end . 900)))
          (should (string-match-p "Hello there" (buffer-string)))
          (should-not cmacs-whisper-dictate--overlay)
          (let ((inhibit-message t))
            (cmacs-whisper-dictate--stop))
          (should-not cmacs-whisper-dictate--stream))))))

(ert-deftest cmacs-speech-test-now-variants ()
  "The synchronous layer RPC uses: same resolution, results returned."
  (cmacs-speech-test--isolated
    (cmacs-speech-define-backend
     'alpha :components '(stt tts diarize)
     :default-model (lambda (c) (format "alpha-%s" c))
     :transcribe-now (lambda (r _pcm rate)
                       (list (cons :text (format "%s@%d" (plist-get r :model) rate))
                             (cons :segments '(((:start . 0) (:end . 900) (:text . "hi"))))))
     :synthesize-now (lambda (_r text) (list (cons :pcm (make-string (length text) 0 t))
                                              (cons :sample-rate 22050)))
     :run-now (lambda (_r component _input)
                (if (eq component 'diarize)
                    '((:num-speakers . 1)
                      (:segments ((:start . 0) (:end . 1000) (:speaker . 7))))
                  '((:error . "nope")))))
    (let ((wav (expand-file-name "a.wav" (file-name-directory cmacs-speech-state-file))))
      (cmacs-speech-write-wav wav (make-string 3200 0 t) 8000)
      (should (equal (alist-get :text (cmacs-speech-transcribe-file-now wav)) "alpha-stt@8000"))
      (should (equal (alist-get :backend (cmacs-speech-transcribe-now "x")) 'alpha))
      (should (= (alist-get :sample-rate (cmacs-speech-synthesize-now "hello" :backend (quote alpha))) 22050))
      (should (equal (cmacs-speech-who-spoke-now wav)
                     "1 speakers\n\n- *Speaker 1* [00:00:00] hi"))
      (should-error (cmacs-speech-run-now 'nonsense "x")))))

(provide 'cmacs-speech-tests)
;;; cmacs-speech-tests.el ends here
