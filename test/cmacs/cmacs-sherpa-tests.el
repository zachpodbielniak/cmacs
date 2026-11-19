;;; cmacs-sherpa-tests.el --- ERT for the sherpa-onnx engine  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Two kinds of test.  The first kind needs only the C primitives:
;; kinds, generated config keys, config errors, the keyword tokenizer
;; (against a vocabulary written here).  The second runs real models
;; from the sherpa models directory and skips, by name, when a model is
;; not installed -- `cmacs-speech' downloads them; nothing here does.
;;
;; Gated on the primitive, not on a feature name (AGENTS.md: a suite
;; that skips on a misspelt feature proves nothing for months).

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar cmacs-sherpa-test-models
  (expand-file-name "cmacs/speech-models/sherpa"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Where the real-model tests look for models.")

(defmacro cmacs-sherpa-test--skip-unless-built ()
  "Skip unless sherpa is compiled in."
  `(skip-unless (fboundp 'cmacs-sherpa-supported-p)))

(defun cmacs-sherpa-test--model (id)
  "Path of model ID, or skip the test."
  (let ((p (expand-file-name id cmacs-sherpa-test-models)))
    ;; `skip-unless' exists only inside `ert-deftest' bodies.
    (unless (file-exists-p p) (ert-skip (format "model %s not installed" id)))
    p))

(defun cmacs-sherpa-test--wait (pred &optional secs)
  "Spin the event loop until PRED, at most SECS (default 60)."
  (let ((end (+ (float-time) (or secs 60))))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.02))
    (funcall pred)))

(defun cmacs-sherpa-test--run (handle op &rest args)
  "Submit OP on HANDLE and wait for its result.  ARGS: PCM TEXT PARAMS CHUNK RATE."
  (let (res)
    (cmacs-sherpa-submit handle op (lambda (r) (setq res r))
                         (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args) (nth 4 args))
    (unless (cmacs-sherpa-test--wait (lambda () res) 120)
      (ert-fail (list "no result for" op)))
    res))

;;;; Pure

(ert-deftest cmacs-sherpa-test-version ()
  (cmacs-sherpa-test--skip-unless-built)
  (should (string-match-p "\\`[0-9]+\\.[0-9]+" (cmacs-sherpa-version)))
  (should (string-match-p "\\`[0-9]+\\.[0-9]+" (cmacs-sherpa-onnxruntime-version)))
  (should (eq IS-CMACS-SHERPA t)))

(ert-deftest cmacs-sherpa-test-kinds ()
  (cmacs-sherpa-test--skip-unless-built)
  (should (equal (cmacs-sherpa-kinds)
                 '(asr stream-asr stream kws kws-stream vad tts diarize speaker
                       punct punct-online lid tag denoise denoise-stream separate))))

(ert-deftest cmacs-sherpa-test-config-keys-generated ()
  "The tables come from c-api.h; spot-check fields Lisp relies on."
  (cmacs-sherpa-test--skip-unless-built)
  (let ((asr (cmacs-sherpa-config-keys 'asr))
        (tts (cmacs-sherpa-config-keys 'tts)))
    (should (equal (assoc "model-config.whisper.encoder" asr)
                   '("model-config.whisper.encoder" . "string")))
    (should (equal (cdr (assoc "model-config.num-threads" asr)) "int"))
    (should (equal (cdr (assoc "model.vits.length-scale" tts)) "float"))
    (should (assoc "keywords" (cmacs-sherpa-config-keys 'kws-stream)))
    (should (assoc "buffer-size-in-seconds" (cmacs-sherpa-config-keys 'vad)))))

(ert-deftest cmacs-sherpa-test-unknown-config-key ()
  "A typo in a config key is an error naming the key, not a silent default."
  (cmacs-sherpa-test--skip-unless-built)
  (let ((err (should-error (cmacs-sherpa-open 'vad '(:silero-vad.modle "/x")))))
    (should (string-match-p "silero-vad.modle" (cadr err)))))

(ert-deftest cmacs-sherpa-test-bad-number ()
  (cmacs-sherpa-test--skip-unless-built)
  (let ((err (should-error (cmacs-sherpa-open 'vad '(:sample-rate "fast")))))
    (should (string-match-p "sample-rate" (cadr err)))))

(ert-deftest cmacs-sherpa-test-stream-needs-parent ()
  (cmacs-sherpa-test--skip-unless-built)
  (should-error (cmacs-sherpa-open 'stream nil))
  (should-error (cmacs-sherpa-open 'stream nil 999999)))

(ert-deftest cmacs-sherpa-test-unknown-handle ()
  (cmacs-sherpa-test--skip-unless-built)
  (should-error (cmacs-sherpa-submit 999999 'run #'ignore))
  (should-not (cmacs-sherpa-close 999999))
  (should-not (cmacs-sherpa-info 999999)))

(ert-deftest cmacs-sherpa-test-kws-tokenize ()
  "BPE merges by rank, vocabulary case, word marker, special symbols.
Ids are merge ranks: VI (3) merges before ▁J (4), then ▁JA (5).  A
greedy longest match would give the same here; the rank order matters
in the real-model oracle test."
  (cmacs-sherpa-test--skip-unless-built)
  (let ((tok (make-temp-file "tokens" nil ".txt"
                             (concat "<blk> 0\n<sos/eos> 1\n<unk> 2\n"
                                     "VI 3\n▁J 4\n▁JA 5\n▁H 6\n"
                                     "▁ 10\nJ 11\nA 12\nR 13\nV 14\nI 15\n"
                                     "S 16\nH 17\nE 18\nY 19\n"))))
    (unwind-protect
        (progn
          ;; Lower-case input, upper-case vocabulary: <blk> must not
          ;; make the vocabulary look mixed-case.
          (should (equal (cmacs-sherpa-kws-tokenize tok "jarvis")
                         "▁JA R VI S @jarvis"))
          (should (equal (cmacs-sherpa-kws-tokenize tok "hey jarvis")
                         "▁H E Y ▁JA R VI S @hey_jarvis"))
          (should-error (cmacs-sherpa-kws-tokenize tok "zebra"))
          (should-error (cmacs-sherpa-kws-tokenize tok "")))
      (delete-file tok))))

(ert-deftest cmacs-sherpa-test-kws-tokenize-matches-model ()
  "Our BPE spelling equals the model's own test_keywords.txt.
The spotter matches token paths, so only the trained segmentation fires."
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((dir (cmacs-sherpa-test--model "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"))
         (tokens (expand-file-name "tokens.txt" dir)))
    (should (equal (cmacs-sherpa-kws-tokenize tokens "light up") "▁ L IGHT ▁UP @light_up"))
    (should (equal (cmacs-sherpa-kws-tokenize tokens "lovely child")
                   "▁LOVE LY ▁CHI L D @lovely_child"))
    (should (equal (cmacs-sherpa-kws-tokenize tokens "forever") "▁FOR E VER @forever"))))

(ert-deftest cmacs-sherpa-test-kws-rejects-bad-keywords ()
  "A keyword line sherpa cannot encode is refused before sherpa sees it.
sherpa would hand back a stream that crashes the process at its first
decode."
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((dir (cmacs-sherpa-test--model "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"))
         (parent (cmacs-sherpa-open
                  'kws (list :transducer.encoder (expand-file-name "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" dir)
                             :transducer.decoder (expand-file-name "decoder-epoch-12-avg-2-chunk-16-left-64.onnx" dir)
                             :transducer.joiner (expand-file-name "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" dir)
                             :tokens (expand-file-name "tokens.txt" dir)
                             :keywords-file (expand-file-name "keywords.txt" dir)))))
    (unwind-protect
        (progn
          (should-error (cmacs-sherpa-open 'kws-stream '(:keywords "▁LI G H T ▁UP @light up") parent))
          (should-error (cmacs-sherpa-open 'kws-stream '(:keywords "notatoken @x") parent)))
      (cmacs-sherpa-close parent))))

(ert-deftest cmacs-sherpa-test-kws-tokenize-cjk ()
  (cmacs-sherpa-test--skip-unless-built)
  (let ((tok (make-temp-file "tokens" nil ".txt" "<blk> 0\n你 1\n好 2\n")))
    (unwind-protect
        (should (equal (cmacs-sherpa-kws-tokenize tok "你好" t) "你 好 @你好"))
      (delete-file tok))))

(ert-deftest cmacs-sherpa-test-read-wav ()
  (cmacs-sherpa-test--skip-unless-built)
  (let ((f (make-temp-file "w" nil ".wav")))
    (unwind-protect
        (progn
          (require 'cmacs-speech)
          (cmacs-speech-write-wav f (unibyte-string 0 0 255 127 0 128) 22050)
          (let ((r (cmacs-sherpa-read-wav f)))
            (should (= (cdr r) 22050))
            (should (= (length (car r)) 6))))
      (delete-file f))))

;;;; Real models (skip when not installed)

(defun cmacs-sherpa-test--wav (model-dir name)
  "PCM of test wav NAME shipped in MODEL-DIR."
  (let ((f (expand-file-name (concat "test_wavs/" name) model-dir)))
    (unless (file-exists-p f) (ert-skip (format "no %s" f)))
    (car (cmacs-sherpa-read-wav f))))

(ert-deftest cmacs-sherpa-test-offline-asr ()
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((dir (cmacs-sherpa-test--model "sherpa-onnx-moonshine-tiny-en-int8"))
         (h (cmacs-sherpa-open
             'asr (list :moonshine.preprocessor (expand-file-name "preprocess.onnx" dir)
                        :moonshine.encoder (expand-file-name "encode.int8.onnx" dir)
                        :moonshine.uncached-decoder (expand-file-name "uncached_decode.int8.onnx" dir)
                        :moonshine.cached-decoder (expand-file-name "cached_decode.int8.onnx" dir)
                        :tokens (expand-file-name "tokens.txt" dir)))))
    (unwind-protect
        (let ((r (cmacs-sherpa-test--run h 'run (cmacs-sherpa-test--wav dir "0.wav"))))
          (should (string-match-p "yellow lamps" (downcase (alist-get :text r))))
          ;; The whisper-compatible shape every consumer reads.
          (should (consp (alist-get :segments r)))
          (should (integerp (alist-get :end (car (alist-get :segments r))))))
      (cmacs-sherpa-close h))))

(ert-deftest cmacs-sherpa-test-streaming-asr ()
  "Partials arrive while feeding; an endpoint yields the final text."
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((dir (cmacs-sherpa-test--model "sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"))
         (parent (cmacs-sherpa-open
                  'stream-asr
                  (list :transducer.encoder (expand-file-name "encoder-epoch-99-avg-1.int8.onnx" dir)
                        :transducer.decoder (expand-file-name "decoder-epoch-99-avg-1.onnx" dir)
                        :transducer.joiner (expand-file-name "joiner-epoch-99-avg-1.int8.onnx" dir)
                        :tokens (expand-file-name "tokens.txt" dir))))
         (s (cmacs-sherpa-open 'stream nil parent))
         (pcm (cmacs-sherpa-test--wav dir "0.wav"))
         (partials 0) final)
    (unwind-protect
        (progn
          (cl-loop for i from 0 below (length pcm) by 6400
                   do (let ((r (cmacs-sherpa-test--run
                                s 'feed (substring pcm i (min (length pcm) (+ i 6400))))))
                        (when (> (length (alist-get :partial r)) 0) (cl-incf partials))
                        (when (alist-get :final r) (setq final (alist-get :final r)))))
          (let ((r (cmacs-sherpa-test--run s 'finish)))
            (setq final (or (alist-get :final r) final)))
          (should (> partials 3))
          (should (string-match-p "YELLOW LAMPS" final)))
      (cmacs-sherpa-close s)
      (cmacs-sherpa-close parent))))

(ert-deftest cmacs-sherpa-test-vad ()
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((model (expand-file-name "silero_vad.onnx" (cmacs-sherpa-test--model "silero_vad")))
         (pcm (cmacs-sherpa-test--wav (cmacs-sherpa-test--model "sherpa-onnx-moonshine-tiny-en-int8")
                                      "0.wav"))
         (h (cmacs-sherpa-open 'vad (list :silero-vad.model model))))
    (unwind-protect
        (let* ((r (cmacs-sherpa-test--run h 'feed (concat (make-string 32000 0) pcm)))
               (probs (alist-get :probs r)))
          (should (= (alist-get :window r) 512))
          (should (= (length probs) (/ (+ 32000 (length pcm)) 1024)))
          ;; Leading second of silence is not speech; the reading is.
          (should (zerop (aref probs 5)))
          (should (> (cl-count 1.0 probs) (/ (length probs) 2)))
          (let ((fin (cmacs-sherpa-test--run h 'finish)))
            (should (alist-get :segments fin))))
      (cmacs-sherpa-close h))))

(ert-deftest cmacs-sherpa-test-kws-detects ()
  "The spotter finds a phrase spelled by our tokenizer."
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((dir (cmacs-sherpa-test--model "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"))
         (tokens (expand-file-name "tokens.txt" dir))
         (parent (cmacs-sherpa-open
                  'kws (list :transducer.encoder (expand-file-name "encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx" dir)
                             :transducer.decoder (expand-file-name "decoder-epoch-12-avg-2-chunk-16-left-64.onnx" dir)
                             :transducer.joiner (expand-file-name "joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx" dir)
                             :tokens tokens
                             :keywords-file (expand-file-name "keywords.txt" dir))))
         (s (cmacs-sherpa-open 'kws-stream
                               (list :keywords (cmacs-sherpa-kws-tokenize tokens "light up"))
                               parent)))
    (unwind-protect
        (let* ((r1 (cmacs-sherpa-test--run s 'feed (cmacs-sherpa-test--wav dir "0.wav")))
               (r2 (cmacs-sherpa-test--run s 'finish))
               (hits (append (alist-get :detections r1) (alist-get :detections r2))))
          (should (member "light_up" (mapcar (lambda (d) (alist-get :keyword d)) hits))))
      (cmacs-sherpa-close s)
      (cmacs-sherpa-close parent))))

(ert-deftest cmacs-sherpa-test-tts-streams-and-cancels ()
  "Piper voice through sherpa: chunks before done; cancel stops it."
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((dir (cmacs-sherpa-test--model "vits-piper-en_US-amy-low"))
         (h (cmacs-sherpa-open 'tts (list :vits.model (expand-file-name "en_US-amy-low.onnx" dir)
                                          :vits.tokens (expand-file-name "tokens.txt" dir)
                                          :espeak-data-dir (expand-file-name "espeak-ng-data" dir))))
         chunks res)
    (unwind-protect
        (progn
          (should (= (alist-get :sample-rate (cmacs-sherpa-info h)) 16000))
          (cmacs-sherpa-submit h 'run (lambda (r) (setq res r)) nil
                               "First sentence here. And a second one follows it."
                               nil (lambda (c) (push c chunks)))
          (should (cmacs-sherpa-test--wait (lambda () res) 120))
          (should (>= (length chunks) 2))
          (should (> (alist-get :duration res) 1500))
          (should (= (length (alist-get :pcm res)) (* 2 (alist-get :samples res))))
          ;; Cancel before it can run: the callback still comes, cancelled.
          (setq res nil)
          (cmacs-sherpa-cancel
           (cmacs-sherpa-submit h 'run (lambda (r) (setq res r)) nil
                                (mapconcat #'identity (make-list 30 "Long text.") " ")))
          (should (cmacs-sherpa-test--wait (lambda () res) 120))
          (should (or (alist-get :cancelled res) (alist-get :samples res))))
      (cmacs-sherpa-close h))))

(ert-deftest cmacs-sherpa-test-speaker-enroll-identify ()
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((model (expand-file-name "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"
                                  (cmacs-sherpa-test--model "3dspeaker_speech_campplus_sv_en_voxceleb_16k")))
         (pcm (cmacs-sherpa-test--wav (cmacs-sherpa-test--model "sherpa-onnx-moonshine-tiny-en-int8")
                                      "1.wav"))
         (h (cmacs-sherpa-open 'speaker (list :model model))))
    (unwind-protect
        (let* ((half (* 2 (/ (length pcm) 4)))
               (enroll (cmacs-sherpa-test--run h 'enroll (substring pcm 0 half) "reader")))
          (should (alist-get :added enroll))
          (should (= (length (alist-get :embedding enroll)) (alist-get :dim enroll)))
          (should (equal (alist-get :speakers (cmacs-sherpa-test--run h 'list))
                         '("reader")))
          (let ((id (cmacs-sherpa-test--run h 'identify (substring pcm half) nil
                                            '(:threshold 0.3))))
            (should (equal (alist-get :name (car (alist-get :matches id))) "reader")))
          (should (alist-get :removed (cmacs-sherpa-test--run h 'remove nil "reader"))))
      (cmacs-sherpa-close h))))

(ert-deftest cmacs-sherpa-test-denoise ()
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((model (expand-file-name "gtcrn_simple.onnx" (cmacs-sherpa-test--model "gtcrn_simple")))
         (pcm (cmacs-sherpa-test--wav (cmacs-sherpa-test--model "sherpa-onnx-moonshine-tiny-en-int8")
                                      "0.wav"))
         (h (cmacs-sherpa-open 'denoise (list :gtcrn.model model))))
    (unwind-protect
        (let ((r (cmacs-sherpa-test--run h 'run pcm)))
          (should (= (alist-get :sample-rate r) 16000))
          (should (> (length (alist-get :pcm r)) (/ (length pcm) 2))))
      (cmacs-sherpa-close h))))

(ert-deftest cmacs-sherpa-test-loaded-lists-handles ()
  (cmacs-sherpa-test--skip-unless-built)
  (let* ((model (expand-file-name "silero_vad.onnx" (cmacs-sherpa-test--model "silero_vad")))
         (h (cmacs-sherpa-open 'vad (list :silero-vad.model model))))
    (unwind-protect
        (let ((row (cl-find h (cmacs-sherpa-loaded) :key (lambda (r) (alist-get :id r)))))
          (should row)
          (should (equal (alist-get :kind row) "vad"))
          (should (string-suffix-p "silero_vad.onnx" (alist-get :model row))))
      (cmacs-sherpa-close h))))

(provide 'cmacs-sherpa-tests)
;;; cmacs-sherpa-tests.el ends here
