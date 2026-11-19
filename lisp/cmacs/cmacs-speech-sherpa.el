;;; cmacs-speech-sherpa.el --- sherpa-onnx backend for cmacs-speech  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Adapts the `cmacs-sherpa-*' primitives (cmacs/sherpa) to the
;; `cmacs-speech' backend protocol.  Three jobs:
;;
;; 1. Model directories.  A sherpa model is a directory (or a single
;;    .onnx file) laid out the way sherpa-onnx's release archives are.
;;    `cmacs-speech-sherpa-model-spec' recognises the family from file
;;    names alone -- transducer, whisper, moonshine, sense-voice,
;;    paraformer, NeMo, VITS/Piper, Kokoro, Matcha, KWS, Silero/TEN VAD,
;;    pyannote, speaker embeddings, punctuation, tagging, GTCRN,
;;    spleeter -- and returns the handle kind and config plist.  So a
;;    model dropped into the models directory works without a catalog
;;    entry.
;;
;; 2. Handles.  Loading a model takes from milliseconds to seconds, so
;;    handles are opened asynchronously and cached by (kind . config);
;;    requests that arrive while one loads queue behind it.  Beyond
;;    `cmacs-speech-sherpa-cache-limit' the least recently used idle
;;    handle is closed.
;;
;; 3. The operations themselves, shaped like the whisper backend's so
;;    every consumer is engine-blind.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-speech)

(declare-function cmacs-sherpa-open-async "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-open "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-close "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-submit "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-run "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-cancel "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-version "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-onnxruntime-version "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-kws-tokenize "cmacs-sherpa-defuns.c")
(declare-function cmacs-sherpa-info "cmacs-sherpa-defuns.c")

(defgroup cmacs-speech-sherpa nil
  "The sherpa-onnx speech engine."
  :group 'cmacs-speech
  :prefix "cmacs-speech-sherpa-")

(defcustom cmacs-speech-sherpa-models-directories nil
  "Extra directories holding sherpa-onnx models, one model per entry.
Searched after the speech model store (`cmacs-speech-model-dirs':
<store>/sherpa, the extra trees, the system tree).  Earlier
directories win when two hold the same model id."
  :type '(repeat directory)
  :group 'cmacs-speech-sherpa)

(defun cmacs-speech-sherpa--roots ()
  "Every sherpa model root, in search order; downloads go to the first."
  (let ((store (cmacs-speech-model-dirs 'sherpa)))
    (delete-dups (append (butlast store) cmacs-speech-sherpa-models-directories
                         (last store)))))

(defcustom cmacs-speech-sherpa-prefer-int8 t
  "Prefer int8-quantised model files when a model ships both.
Smaller and faster on CPU, at a small accuracy cost."
  :type 'boolean
  :group 'cmacs-speech-sherpa)

(defcustom cmacs-speech-sherpa-threads nil
  "Inference threads per model.
nil lets the engine pick: half the cores, at most 4."
  :type '(choice (const :tag "Automatic" nil) integer)
  :group 'cmacs-speech-sherpa)

(defcustom cmacs-speech-sherpa-provider "cpu"
  "onnxruntime execution provider: \"cpu\", or \"cuda\" on a GPU build."
  :type 'string
  :group 'cmacs-speech-sherpa)

(defcustom cmacs-speech-sherpa-cache-limit 6
  "How many sherpa models stay loaded; the least recently used idle one goes."
  :type 'integer
  :group 'cmacs-speech-sherpa)

(defcustom cmacs-speech-sherpa-speakers-file
  (expand-file-name "cmacs/speech/speakers.eld"
                    (or (getenv "XDG_DATA_HOME") "~/.local/share"))
  "Where enrolled speaker voiceprints are kept (per embedding model)."
  :type 'file
  :group 'cmacs-speech-sherpa)

(defun cmacs-speech-sherpa-available-p ()
  "Non-nil when sherpa-onnx is compiled in."
  (and (fboundp 'cmacs-sherpa-supported-p) (cmacs-sherpa-supported-p)))

;;;; Model directories

(defun cmacs-speech-sherpa--files (dir)
  "Regular files directly in DIR (names only)."
  (and (file-directory-p dir)
       (cl-remove-if-not (lambda (f) (file-regular-p (expand-file-name f dir)))
                         (directory-files dir nil "\\`[^.]"))))

(defun cmacs-speech-sherpa--pick (files regexp)
  "The file in FILES matching REGEXP, int8 first when preferred."
  (let* ((hits (cl-remove-if-not (lambda (f) (string-match-p regexp f)) files))
         (int8 (cl-remove-if-not (lambda (f) (string-match-p "\\.int8\\.onnx\\'" f)) hits))
         (fp (cl-remove-if (lambda (f) (string-match-p "\\.int8\\.onnx\\'" f)) hits)))
    (car (if cmacs-speech-sherpa-prefer-int8 (or int8 fp) (or fp int8)))))

(defun cmacs-speech-sherpa-model-spec (path)
  "Recognise the sherpa model at PATH; return (KIND . CONFIG-PLIST) or nil.
PATH is a model directory, or a single .onnx file (VAD, speaker
embedding, GTCRN, UVR).  KIND is the `cmacs-sherpa-open' kind;
CONFIG holds absolute paths.  Also returns :component in CONFIG's
metadata via `cmacs-speech-sherpa-model-components'."
  (let* ((path (directory-file-name (expand-file-name path)))
         (dir (if (file-directory-p path) path (file-name-directory path)))
         (name (downcase (file-name-nondirectory path)))
         (files (if (file-directory-p path)
                    (cmacs-speech-sherpa--files path)
                  (list (file-name-nondirectory path))))
         (single (and (= (length (cl-remove-if-not
                                  (lambda (f) (string-match-p "\\.onnx\\'" f)) files))
                         1)
                      (cl-find-if (lambda (f) (string-match-p "\\.onnx\\'" f)) files)))
         (f (lambda (re) (when-let* ((x (cmacs-speech-sherpa--pick files re)))
                           (expand-file-name x dir))))
         (tokens (and (member "tokens.txt" files) (expand-file-name "tokens.txt" dir)))
         (espeak (let ((e (expand-file-name "espeak-ng-data" dir)))
                   (and (file-directory-p e) e))))
    (cond
     ;; --- single-file models ---
     ((and single (string-match-p "silero" (concat name single)))
      (list 'vad :silero-vad.model (funcall f "silero.*\\.onnx\\'")))
     ((and single (string-match-p "ten-vad" (concat name single)))
      (list 'vad :ten-vad.model (funcall f "ten-vad.*\\.onnx\\'")))
     ((and single (string-match-p "gtcrn" (concat name single)))
      (list 'denoise :gtcrn.model (funcall f "gtcrn.*\\.onnx\\'")))
     ((and single (string-match-p "dpdfnet" (concat name single)))
      (list 'denoise :dpdfnet.model (funcall f "dpdfnet.*\\.onnx\\'")))
     ((and single (string-match-p "uvr\\|mdx" (concat name single)))
      (list 'separate :uvr.model (funcall f "\\.onnx\\'")))
     ((and single (string-match-p "3dspeaker\\|wespeaker\\|nemo_en_\\|speaker" (concat name single)))
      (list 'speaker :model (funcall f "\\.onnx\\'")))

     ;; --- keyword spotting (before transducers: same file shapes) ---
     ((and (string-match-p "kws" name) (funcall f "\\`encoder.*\\.onnx\\'"))
      (list 'kws
            :transducer.encoder (funcall f "\\`encoder.*\\.onnx\\'")
            :transducer.decoder (funcall f "\\`decoder.*\\.onnx\\'")
            :transducer.joiner (funcall f "\\`joiner.*\\.onnx\\'")
            :tokens tokens
            :keywords-file (and (member "keywords.txt" files)
                                (expand-file-name "keywords.txt" dir))))

     ;; --- TTS ---
     ((member "voices.bin" files)
      (list 'tts
            (if (string-match-p "kitten" name) :kitten.model :kokoro.model)
            (funcall f "\\`model.*\\.onnx\\'")
            (if (string-match-p "kitten" name) :kitten.voices :kokoro.voices)
            (expand-file-name "voices.bin" dir)
            (if (string-match-p "kitten" name) :kitten.tokens :kokoro.tokens) tokens
            :espeak-data-dir espeak))
     ((and (string-match-p "matcha" name) (funcall f "model.*\\.onnx\\'"))
      (list 'tts :matcha.acoustic-model (funcall f "model.*\\.onnx\\'")
            :matcha.vocoder (or (funcall f "vocos.*\\.onnx\\'") (funcall f "hifigan.*\\.onnx\\'"))
            :matcha.tokens tokens :espeak-data-dir espeak))
     ((and (string-match-p "vits\\|piper" name) tokens)
      (append (list 'tts :vits.model (funcall f "\\.onnx\\'") :vits.tokens tokens)
              ;; sherpa 2.0 no longer phonemizes; cmacs does, with
              ;; the voice's own espeak data.
              (and espeak (list :espeak-data-dir espeak))
              (and (member "lexicon.txt" files)
                   (list :vits.lexicon (expand-file-name "lexicon.txt" dir)))))

     ;; --- analysis ---
     ((string-match-p "pyannote\\|segmentation\\|diarization" name)
      (list 'diarize :segmentation.pyannote.model (funcall f "\\`model.*\\.onnx\\'")))
     ((string-match-p "punct.*ct-transformer\\|ct-transformer" name)
      (list 'punct :ct-transformer (funcall f "\\`model.*\\.onnx\\'")))
     ((string-match-p "cnn-bilstm\\|online-punct" name)
      (list 'punct-online :cnn-bilstm (funcall f "\\`model.*\\.onnx\\'")
            :bpe-vocab (and (member "bpe.vocab" files) (expand-file-name "bpe.vocab" dir))))
     ((string-match-p "audio-tagging" name)
      (list 'tag
            (if (string-match-p "ced" name) :ced :zipformer.model)
            (funcall f "\\`model.*\\.onnx\\'")
            :labels (and (member "class_labels_indices.csv" files)
                         (expand-file-name "class_labels_indices.csv" dir))))
     ((member "vocals.onnx" files)
      (list 'separate :spleeter.vocals (expand-file-name "vocals.onnx" dir)
            :spleeter.accompaniment (expand-file-name "accompaniment.onnx" dir)))

     ;; --- streaming recognizers ---
     ((and (string-match-p "streaming" name) (funcall f "\\`encoder.*\\.onnx\\'")
           (funcall f "\\`joiner.*\\.onnx\\'"))
      (list 'stream-asr
            :transducer.encoder (funcall f "\\`encoder.*\\.onnx\\'")
            :transducer.decoder (funcall f "\\`decoder.*\\.onnx\\'")
            :transducer.joiner (funcall f "\\`joiner.*\\.onnx\\'")
            :tokens tokens))
     ((and (string-match-p "streaming.*paraformer" name) (funcall f "\\`encoder.*\\.onnx\\'"))
      (list 'stream-asr :paraformer.encoder (funcall f "\\`encoder.*\\.onnx\\'")
            :paraformer.decoder (funcall f "\\`decoder.*\\.onnx\\'") :tokens tokens))
     ((and (string-match-p "streaming.*ctc" name) (funcall f "\\.onnx\\'"))
      (list 'stream-asr :zipformer2-ctc.model (funcall f "\\.onnx\\'") :tokens tokens))

     ;; --- offline recognizers ---
     ((and (string-match-p "whisper" name) (funcall f "encoder.*\\.onnx\\'"))
      (list 'asr :whisper.encoder (funcall f "encoder.*\\.onnx\\'")
            :whisper.decoder (funcall f "decoder.*\\.onnx\\'")
            :tokens (or tokens (funcall f "tokens\\.txt\\'")
                        (cl-find-if (lambda (x) (string-match-p "tokens\\.txt\\'" x))
                                    (mapcar (lambda (x) (expand-file-name x dir)) files)))))
     ((and (member "preprocess.onnx" files) (funcall f "\\`encode.*\\.onnx\\'"))
      (append (list 'asr :moonshine.preprocessor (expand-file-name "preprocess.onnx" dir)
                    :moonshine.encoder (funcall f "\\`encode.*\\.onnx\\'")
                    :tokens tokens)
              (if-let* ((merged (funcall f "merged_decode.*\\.onnx\\'")))
                  (list :moonshine.merged-decoder merged)
                (list :moonshine.uncached-decoder (funcall f "\\`uncached_decode.*\\.onnx\\'")
                      :moonshine.cached-decoder (funcall f "\\`cached_decode.*\\.onnx\\'")))))
     ((and (funcall f "\\`encoder.*\\.onnx\\'") (funcall f "\\`joiner.*\\.onnx\\'"))
      (append (list 'asr
                    :transducer.encoder (funcall f "\\`encoder.*\\.onnx\\'")
                    :transducer.decoder (funcall f "\\`decoder.*\\.onnx\\'")
                    :transducer.joiner (funcall f "\\`joiner.*\\.onnx\\'")
                    :tokens tokens)
              (and (string-match-p "nemo\\|parakeet" name)
                   (list :model-type "nemo_transducer"))))
     ((string-match-p "sense-voice\\|sensevoice" name)
      (list 'asr :sense-voice.model (funcall f "\\`model.*\\.onnx\\'")
            :sense-voice.use-itn 1 :tokens tokens))
     ((string-match-p "paraformer" name)
      (list 'asr :paraformer.model (funcall f "\\`model.*\\.onnx\\'") :tokens tokens))
     ((string-match-p "dolphin" name)
      (list 'asr :dolphin.model (funcall f "\\`model.*\\.onnx\\'") :tokens tokens))
     ((string-match-p "fire-?red" name)
      (list 'asr :fire-red-asr.encoder (funcall f "encoder.*\\.onnx\\'")
            :fire-red-asr.decoder (funcall f "decoder.*\\.onnx\\'") :tokens tokens))
     ((string-match-p "canary" name)
      (list 'asr :canary.encoder (funcall f "encoder.*\\.onnx\\'")
            :canary.decoder (funcall f "decoder.*\\.onnx\\'") :tokens tokens))
     ((and (string-match-p "nemo.*ctc\\|ctc.*nemo" name) tokens)
      (list 'asr :nemo-ctc.model (funcall f "\\`model.*\\.onnx\\'") :tokens tokens))
     ((and (string-match-p "zipformer.*ctc\\|ctc" name) tokens (funcall f "\\.onnx\\'"))
      (list 'asr :zipformer-ctc.model (funcall f "\\.onnx\\'") :tokens tokens)))))

(defconst cmacs-speech-sherpa--kind-components
  '((asr stt stt-live)
    (stream-asr stt-stream)
    (kws wake)
    (vad vad)
    (tts tts)
    (diarize diarize)
    (speaker speaker-id)
    (punct punctuate)
    (punct-online punctuate)
    (lid lang-id)
    (tag audio-tag)
    (denoise denoise)
    (separate separate))
  "Which speech components a handle kind serves.")

(defun cmacs-speech-sherpa-model-components (spec)
  "Components SPEC (from `cmacs-speech-sherpa-model-spec') can serve.
A multilingual whisper model also serves `lang-id'."
  (let ((comps (copy-sequence (alist-get (car spec) cmacs-speech-sherpa--kind-components))))
    (when (and (eq (car spec) 'asr) (plist-get (cdr spec) :whisper.encoder)
               (not (string-match-p "\\.en\\b\\|-en\\b" (plist-get (cdr spec) :whisper.encoder))))
      (setq comps (append comps '(lang-id))))
    comps))

(defun cmacs-speech-sherpa-models (&optional component)
  "Installed sherpa models as ((ID . PATH) ...), serving COMPONENT if given.
IDs are directory (or file) names; the first directory in
`cmacs-speech-sherpa-models-directories' wins on a clash."
  (let (seen out)
    (dolist (root (cmacs-speech-sherpa--roots))
      (when (file-directory-p root)
        (dolist (id (directory-files root nil "\\`[^.]"))
          (let* ((path (expand-file-name id root))
                 ;; A download in flight is not a model.
                 (id (if (string-match-p "\\.\\(part\\|staging\\)\\'" id) nil id))
                 (spec (and id (not (member id seen))
                            (ignore-errors (cmacs-speech-sherpa--spec-cached path)))))
            (when (and spec (or (null component)
                                (memq component (cmacs-speech-sherpa-model-components spec))))
              (push id seen)
              (push (cons id path) out))))))
    (nreverse out)))

(defvar cmacs-speech-sherpa--spec-cache (make-hash-table :test 'equal)
  "PATH -> (MTIME . SPEC), so listing models does not re-scan unchanged dirs.")

(defun cmacs-speech-sherpa--spec-cached (path)
  "`cmacs-speech-sherpa-model-spec' of PATH, cached by modification time."
  (let ((mtime (file-attribute-modification-time (file-attributes path)))
        (hit (gethash path cmacs-speech-sherpa--spec-cache)))
    (if (and hit (equal (car hit) mtime))
        (cdr hit)
      (let ((spec (cmacs-speech-sherpa-model-spec path)))
        (puthash path (cons mtime spec) cmacs-speech-sherpa--spec-cache)
        spec))))

(defun cmacs-speech-sherpa-model-path (id)
  "Absolute path of installed sherpa model ID (an id, a path, or nil)."
  (cond
   ((null id) nil)
   ((file-name-absolute-p id) (and (file-exists-p id) id))
   (t (cl-loop for root in (cmacs-speech-sherpa--roots)
               for p = (expand-file-name id root)
               when (file-exists-p p) return p))))

(defcustom cmacs-speech-sherpa-default-models nil
  "Preferred sherpa model id per component, when installed: ((COMPONENT . ID) ...).
Without an entry the first installed model serving the component is used."
  :type '(alist :key-type symbol :value-type string)
  :group 'cmacs-speech-sherpa)

(defun cmacs-speech-sherpa-default-model (component)
  "The sherpa model id `auto' uses for COMPONENT, or nil."
  (let ((models (cmacs-speech-sherpa-models component))
        (want (alist-get component cmacs-speech-sherpa-default-models)))
    (or (and want (assoc want models) want)
        (car (car models)))))

;;;; Handle cache

(cl-defstruct (cmacs-speech-sherpa--slot (:constructor cmacs-speech-sherpa--slot-make))
  key handle waiters (busy 0) (used 0.0) error)

(defvar cmacs-speech-sherpa--slots (make-hash-table :test 'equal)
  "(KIND . CONFIG) -> slot.")

(defun cmacs-speech-sherpa--common-config (kind config)
  "CONFIG with thread and provider defaults for KIND filled in."
  (let ((c (copy-sequence config)))
    (when (and cmacs-speech-sherpa-threads
               (memq kind '(asr stream-asr kws tts lid tag denoise separate punct punct-online))
               (not (plist-member c :num-threads)))
      (setq c (plist-put c :num-threads cmacs-speech-sherpa-threads)))
    (when (and cmacs-speech-sherpa-provider
               (not (equal cmacs-speech-sherpa-provider "cpu"))
               (memq kind '(asr stream-asr kws tts))
               (not (plist-member c :provider)))
      (setq c (plist-put c :provider cmacs-speech-sherpa-provider)))
    ;; Drop nil values: the engine reads a missing key as "default".
    (let (out)
      (while c
        (when (cadr c) (setq out (plist-put out (car c) (cadr c))))
        (setq c (cddr c)))
      out)))

(defun cmacs-speech-sherpa--evict ()
  "Close least recently used idle handles beyond the cache limit."
  (let ((slots (cl-remove-if-not
                (lambda (s) (and (cmacs-speech-sherpa--slot-handle s)
                                 (zerop (cmacs-speech-sherpa--slot-busy s))))
                (hash-table-values cmacs-speech-sherpa--slots))))
    (when (> (hash-table-count cmacs-speech-sherpa--slots) cmacs-speech-sherpa-cache-limit)
      (dolist (s (seq-take (sort slots (lambda (a b) (< (cmacs-speech-sherpa--slot-used a)
                                                        (cmacs-speech-sherpa--slot-used b))))
                           (- (hash-table-count cmacs-speech-sherpa--slots)
                              cmacs-speech-sherpa-cache-limit)))
        (ignore-errors (cmacs-sherpa-close (cmacs-speech-sherpa--slot-handle s)))
        (remhash (cmacs-speech-sherpa--slot-key s) cmacs-speech-sherpa--slots)))))

(defun cmacs-speech-sherpa-with-handle (kind config fn &optional parent)
  "Call FN with the handle for KIND/CONFIG, loading it first if needed.
FN gets the handle, or (:error . MESSAGE).  PARENT is a parent handle
(streams); parented handles are never cached."
  (let* ((config (cmacs-speech-sherpa--common-config kind config))
         (key (cons kind config)))
    (if parent
        (cmacs-sherpa-open-async
         kind config
         (lambda (r) (funcall fn (or (alist-get :handle r) (cons :error (alist-get :error r)))))
         parent)
      (let ((slot (gethash key cmacs-speech-sherpa--slots)))
        (cond
         ((and slot (cmacs-speech-sherpa--slot-handle slot))
          (setf (cmacs-speech-sherpa--slot-used slot) (float-time))
          (funcall fn (cmacs-speech-sherpa--slot-handle slot)))
         (slot
          (push fn (cmacs-speech-sherpa--slot-waiters slot)))
         (t
          (setq slot (cmacs-speech-sherpa--slot-make :key key :waiters (list fn)
                                                     :used (float-time)))
          (puthash key slot cmacs-speech-sherpa--slots)
          (cmacs-sherpa-open-async
           kind config
           (lambda (r)
             (let ((h (alist-get :handle r))
                   (waiters (reverse (cmacs-speech-sherpa--slot-waiters slot))))
               (setf (cmacs-speech-sherpa--slot-waiters slot) nil)
               (if h
                   (progn (setf (cmacs-speech-sherpa--slot-handle slot) h)
                          (cmacs-speech-sherpa--evict))
                 ;; A failed load is not cached: the next request retries
                 ;; (the user may have just fixed the model directory).
                 (remhash key cmacs-speech-sherpa--slots))
               (dolist (w waiters)
                 (funcall w (or h (cons :error (or (alist-get :error r) "load failed")))))
               (when h (cmacs-speech-sherpa--after-open kind config h)))))))))))

(defun cmacs-speech-sherpa--busy (handle delta)
  "Adjust the in-flight count of HANDLE's slot by DELTA."
  (maphash (lambda (_k s)
             (when (eql (cmacs-speech-sherpa--slot-handle s) handle)
               (cl-incf (cmacs-speech-sherpa--slot-busy s) delta)
               (setf (cmacs-speech-sherpa--slot-used s) (float-time))))
           cmacs-speech-sherpa--slots))

(defun cmacs-speech-sherpa-unload-all ()
  "Close every cached sherpa model."
  (interactive)
  (maphash (lambda (_k s) (when (cmacs-speech-sherpa--slot-handle s)
                            (ignore-errors (cmacs-sherpa-close (cmacs-speech-sherpa--slot-handle s)))))
           cmacs-speech-sherpa--slots)
  (clrhash cmacs-speech-sherpa--slots))

(add-hook 'cmacs-speech-config-changed-hook #'cmacs-speech-sherpa--evict)

(defun cmacs-speech-sherpa--submit (handle op callback &rest args)
  "Submit OP on HANDLE, tracking busy; ARGS are PCM TEXT PARAMS CHUNK RATE."
  (cmacs-speech-sherpa--busy handle 1)
  (condition-case err
      (cmacs-sherpa-submit handle op
                           (lambda (r)
                             (cmacs-speech-sherpa--busy handle -1)
                             (funcall callback r))
                           (nth 0 args) (nth 1 args) (nth 2 args) (nth 3 args) (nth 4 args))
    (error (cmacs-speech-sherpa--busy handle -1)
           (funcall callback (list (cons :error (error-message-string err))))
           nil)))

;;;; Resolving a model to a handle

(defun cmacs-speech-sherpa--spec-for (resolved &optional want-kind)
  "(KIND . CONFIG) for RESOLVED's model, checked against WANT-KIND."
  (let* ((id (plist-get resolved :model))
         (path (or (cmacs-speech-sherpa-model-path id)
                   (user-error "sherpa model %s is not installed (M-x cmacs-speech to get it)" id)))
         (spec (or (cmacs-speech-sherpa--spec-cached path)
                   (user-error "%s is not a sherpa model cmacs recognises" path))))
    (when (and want-kind (not (memq (car spec) (ensure-list want-kind))))
      (user-error "%s is a %s model, not %s" id (car spec) want-kind))
    spec))

(defun cmacs-speech-sherpa--with-spec (resolved kind fn)
  "Call FN with the handle for RESOLVED's model (of KIND), or (:error . M)."
  (let ((spec (cmacs-speech-sherpa--spec-for resolved kind)))
    (cmacs-speech-sherpa-with-handle (car spec) (cdr spec) fn)))

(defun cmacs-speech-sherpa--error-p (h)
  "Non-nil when H is an (:error . MESSAGE) instead of a handle."
  (eq (car-safe h) :error))

;;;; Operations

(defun cmacs-speech-sherpa--transcribe (resolved pcm rate callback)
  "Offline transcription of PCM for RESOLVED."
  (cmacs-speech-sherpa--with-spec
   resolved 'asr
   (lambda (h)
     (if (cmacs-speech-sherpa--error-p h)
         (funcall callback (list h))
       (cmacs-speech-sherpa--submit
        h 'run callback pcm nil
        (when-let* ((hot (cmacs-speech-option resolved :hotwords)))
          (list :hotwords hot))
        nil rate)))))

(cl-defstruct (cmacs-speech-sherpa--stream (:constructor cmacs-speech-sherpa--stream-make))
  handle pending closed on-result (queue nil))

(defun cmacs-speech-sherpa--stream-open (resolved on-result)
  "Open a streaming recognizer for RESOLVED; results go to ON-RESULT."
  (let ((s (cmacs-speech-sherpa--stream-make :on-result on-result :pending t))
        (spec (cmacs-speech-sherpa--spec-for resolved 'stream-asr)))
    (cmacs-speech-sherpa-with-handle
     (car spec) (cdr spec)
     (lambda (parent)
       (if (cmacs-speech-sherpa--error-p parent)
           (funcall on-result (list parent))
         (cmacs-speech-sherpa-with-handle
          'stream (when-let* ((hot (cmacs-speech-option resolved :hotwords)))
                    (list :hotwords hot))
          (lambda (h)
            (if (cmacs-speech-sherpa--error-p h)
                (funcall on-result (list h))
              (if (cmacs-speech-sherpa--stream-closed s)
                  (cmacs-sherpa-close h)
                (setf (cmacs-speech-sherpa--stream-handle s) h
                      (cmacs-speech-sherpa--stream-pending s) nil)
                ;; Audio that arrived while the model loaded.
                (dolist (item (nreverse (cmacs-speech-sherpa--stream-queue s)))
                  (cmacs-speech-sherpa--stream-op s (car item) (cdr item)))
                (setf (cmacs-speech-sherpa--stream-queue s) nil))))
          parent))))
    s))

(defun cmacs-speech-sherpa--stream-op (s op pcm)
  "Run OP (feed/finish) on stream S, queueing until it has a handle."
  (cond
   ((cmacs-speech-sherpa--stream-closed s))
   ((cmacs-speech-sherpa--stream-pending s)
    ;; A copy: the microphone engine wipes its chunks once the consumer
    ;; returns, and this one waits for the model to load.
    (push (cons op (and pcm (copy-sequence pcm))) (cmacs-speech-sherpa--stream-queue s)))
   (t
    (cmacs-sherpa-submit (cmacs-speech-sherpa--stream-handle s) op
                         (lambda (r)
                           (unless (or (cmacs-speech-sherpa--stream-closed s)
                                       (assq :cancelled r))
                             (funcall (cmacs-speech-sherpa--stream-on-result s) r)))
                         pcm))))

(defun cmacs-speech-sherpa--stream-feed (s pcm)
  "Feed PCM to stream S."
  (cmacs-speech-sherpa--stream-op s 'feed pcm))

(defun cmacs-speech-sherpa--stream-finish (s)
  "Flush stream S."
  (cmacs-speech-sherpa--stream-op s 'finish nil))

(defun cmacs-speech-sherpa--stream-close (s)
  "Close stream S."
  (setf (cmacs-speech-sherpa--stream-closed s) t)
  (when-let* ((h (cmacs-speech-sherpa--stream-handle s)))
    (cmacs-sherpa-close h)))

(defun cmacs-speech-sherpa--keywords (resolved phrases tokens)
  "The keyword spotter line for PHRASES with the model's TOKENS file."
  (let ((score (cmacs-speech-option resolved :keyword-score))
        (thr (cmacs-speech-option resolved :keyword-threshold)))
    (mapconcat
     (lambda (p)
       (let ((line (cmacs-sherpa-kws-tokenize tokens p)))
         ;; sherpa's per-keyword boost (:N) and threshold (#T) go before
         ;; the @display-name.
         (if (or score thr)
             (replace-regexp-in-string
              " @" (concat (if score (format " :%s" score) "")
                           (if thr (format " #%s" thr) "")
                           " @")
              line t t)
           line)))
     phrases "/")))

(defun cmacs-speech-sherpa--wake-open (resolved phrases on-hit)
  "Start keyword spotting for PHRASES; ON-HIT gets the phrase."
  (let* ((spec (cmacs-speech-sherpa--spec-for resolved 'kws))
         (phrases (or phrases (cmacs-speech-option resolved :phrases) '("jarvis")))
         (keywords (cmacs-speech-sherpa--keywords resolved phrases (plist-get (cdr spec) :tokens)))
         (s (cmacs-speech-sherpa--stream-make :pending t)))
    (setf (cmacs-speech-sherpa--stream-on-result s)
          (lambda (r)
            (dolist (d (alist-get :detections r))
              ;; Display names travel with `_' for spaces (sherpa's
              ;; parser ends them at whitespace).
              (funcall on-hit (subst-char-in-string
                               ?_ ?\s (alist-get :keyword d))))))
    (cmacs-speech-sherpa-with-handle
     'kws (cdr spec)
     (lambda (parent)
       (unless (cmacs-speech-sherpa--error-p parent)
         (cmacs-speech-sherpa-with-handle
          'kws-stream (list :keywords keywords)
          (lambda (h)
            (unless (cmacs-speech-sherpa--error-p h)
              (if (cmacs-speech-sherpa--stream-closed s)
                  (cmacs-sherpa-close h)
                (setf (cmacs-speech-sherpa--stream-handle s) h
                      (cmacs-speech-sherpa--stream-pending s) nil)
                (setf (cmacs-speech-sherpa--stream-queue s) nil))))
          parent))))
    s))

(defun cmacs-speech-sherpa--wake-feed (s pcm)
  "Feed wake stream S."
  ;; Wake audio is live and disposable: while the model loads, drop it
  ;; rather than queue seconds of it.
  (unless (cmacs-speech-sherpa--stream-pending s)
    (cmacs-speech-sherpa--stream-op s 'feed pcm)))

(defun cmacs-speech-sherpa--vad-open (resolved)
  "A VAD object for RESOLVED: a handle, opened synchronously (VAD models are tiny)."
  (let ((spec (cmacs-speech-sherpa--spec-for resolved 'vad)))
    (cmacs-sherpa-open 'vad (cmacs-speech-sherpa--common-config 'vad (cdr spec)))))

(defun cmacs-speech-sherpa--vad-probs (probs window)
  "PROBS per WINDOW-sample window as one value per 512-sample frame.
cmacs-voice frames are 512 samples (Silero's window); TEN-VAD steps by
256, so its decisions are combined, a frame counting as speech when
any of its windows is."
  (if (or (null window) (= window 512) (zerop (length probs)))
      probs
    (let* ((per (max 1 (/ 512 window)))
           (n (/ (length probs) per))
           (out (make-vector n 0.0)))
      (dotimes (i n)
        (dotimes (j per)
          (aset out i (max (aref out i) (aref probs (+ (* i per) j))))))
      out)))

(defun cmacs-speech-sherpa--vad-feed (h pcm callback)
  "Feed PCM to VAD handle H; CALLBACK gets ((:probs . VECTOR) ...).
The vector has one value per 512-sample frame of PCM."
  (cmacs-sherpa-submit
   h 'feed
   (lambda (r)
     (funcall callback
              (if (assq :probs r)
                  (cons (cons :probs (cmacs-speech-sherpa--vad-probs
                                      (alist-get :probs r) (alist-get :window r)))
                        (assq-delete-all :probs (copy-sequence r)))
                r)))
   pcm))

(defun cmacs-speech-sherpa--synthesize (resolved text callback chunk-fn)
  "Speak TEXT with RESOLVED's model."
  (let ((spec (cmacs-speech-sherpa--spec-for resolved 'tts))
        (token (list nil)))
    (cmacs-speech-sherpa-with-handle
     (car spec) (cdr spec)
     (lambda (h)
       (cond
        ((cmacs-speech-sherpa--error-p h) (funcall callback (list h)))
        ((eq (car token) 'cancelled) (funcall callback '((:cancelled . t))))
        (t
         (setcar token
                 (cmacs-speech-sherpa--submit
                  h 'run callback nil text
                  (append
                   (when-let* ((sp (cmacs-speech-option resolved :speaker))) (list :sid sp))
                   (when-let* ((sp (cmacs-speech-option resolved :speed))) (list :speed sp))
                   (when chunk-fn (list :collect nil)))
                  chunk-fn))))))
    token))

(defun cmacs-speech-sherpa--cancel (token)
  "Cancel synthesis TOKEN."
  (if (integerp (car token))
      (cmacs-sherpa-cancel (car token))
    (setcar token 'cancelled)))

;;;; Speakers (persisted voiceprints)

(defun cmacs-speech-sherpa--speakers-read ()
  "((EMBEDDING-MODEL . ((NAME . VECTOR) ...)) ...) from the speakers file."
  (when (file-readable-p cmacs-speech-sherpa-speakers-file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents cmacs-speech-sherpa-speakers-file)
        (read (current-buffer))))))

(defun cmacs-speech-sherpa--speakers-write (data)
  "Persist speaker DATA."
  (make-directory (file-name-directory cmacs-speech-sherpa-speakers-file) t)
  (let ((print-length nil) (print-level nil))
    (with-temp-file cmacs-speech-sherpa-speakers-file
      (insert ";; -*- mode: lisp-data -*-\n;; cmacs speaker voiceprints, per embedding model.\n")
      (prin1 data (current-buffer)))))

(defun cmacs-speech-sherpa--after-open (kind config handle)
  "Restore persisted state into a freshly opened HANDLE of KIND."
  (when (eq kind 'speaker)
    (dolist (entry (alist-get (plist-get config :model)
                              (cmacs-speech-sherpa--speakers-read) nil nil #'equal))
      (cmacs-sherpa-submit handle 'add-embedding #'ignore (cdr entry) (car entry)))))

(defun cmacs-speech-sherpa-speakers (&optional model)
  "Names enrolled for embedding MODEL (default: all)."
  (let ((data (cmacs-speech-sherpa--speakers-read)))
    (delete-dups
     (mapcar #'car (if model
                       (alist-get model data nil nil #'equal)
                     (apply #'append (mapcar #'cdr data)))))))

(defun cmacs-speech-sherpa-forget-speaker (name)
  "Forget speaker NAME everywhere (file and loaded handles)."
  (let ((data (mapcar (lambda (e) (cons (car e) (cl-remove name (cdr e) :key #'car :test #'equal)))
                      (cmacs-speech-sherpa--speakers-read))))
    (cmacs-speech-sherpa--speakers-write data))
  (maphash (lambda (k s)
             (when (and (eq (car k) 'speaker) (cmacs-speech-sherpa--slot-handle s))
               (cmacs-sherpa-submit (cmacs-speech-sherpa--slot-handle s) 'remove #'ignore nil name)))
           cmacs-speech-sherpa--slots))

;;;; Analysis dispatch

(defun cmacs-speech-sherpa--diarize-config (resolved spec)
  "Diarization config: SPEC's segmentation plus a speaker embedding model."
  (let* ((emb-id (or (cmacs-speech-option resolved :embedding)
                     (cmacs-speech-sherpa-default-model 'speaker-id)))
         (emb (and emb-id (cmacs-speech-sherpa-model-path emb-id)))
         (emb-spec (and emb (cmacs-speech-sherpa--spec-cached emb))))
    (unless emb-spec
      (user-error "Diarization also needs a speaker-embedding model; get one with M-x cmacs-speech"))
    (append (cdr spec) (list :embedding.model (plist-get (cdr emb-spec) :model)))))

(defun cmacs-speech-sherpa--run (resolved component input callback chunk-fn)
  "Analysis COMPONENT of INPUT for RESOLVED."
  (let* ((rate (cmacs-speech-option resolved :rate))
         (kind (pcase component
                 ('diarize 'diarize) ('speaker-id 'speaker) ('punctuate '(punct punct-online))
                 ('lang-id '(lid asr)) ('audio-tag 'tag) ('denoise 'denoise)
                 ('separate 'separate)
                 (_ (user-error "sherpa cannot run %s" component))))
         (spec (cmacs-speech-sherpa--spec-for resolved kind))
         (config (pcase component
                   ('diarize (cmacs-speech-sherpa--diarize-config resolved spec))
                   ('lang-id (list :whisper.encoder (plist-get (cdr spec) :whisper.encoder)
                                   :whisper.decoder (plist-get (cdr spec) :whisper.decoder)))
                   (_ (cdr spec))))
         (open-kind (if (eq component 'lang-id) 'lid (car spec))))
    (cmacs-speech-sherpa-with-handle
     open-kind config
     (lambda (h)
       (if (cmacs-speech-sherpa--error-p h)
           (funcall callback (list h))
         (pcase component
           ('punctuate
            (cmacs-speech-sherpa--submit h 'run callback nil input))
           ('speaker-id
            (let ((op (or (cmacs-speech-option resolved :op) 'identify))
                  (name (cmacs-speech-option resolved :name)))
              (cmacs-speech-sherpa--submit
               h op
               (lambda (r)
                 (when (and (eq op 'enroll) (alist-get :embedding r))
                   (let* ((model (plist-get config :model))
                          (data (cmacs-speech-sherpa--speakers-read))
                          (cell (assoc model data)))
                     (unless cell (setq cell (list model)) (push cell data))
                     (setcdr cell (cons (cons name (alist-get :embedding r))
                                        (cl-remove name (cdr cell) :key #'car :test #'equal)))
                     (cmacs-speech-sherpa--speakers-write data)))
                 (funcall callback r))
               input name
               (append (when-let* ((t1 (cmacs-speech-option resolved :threshold)))
                         (list :threshold t1))
                       (when-let* ((n (cmacs-speech-option resolved :n))) (list :n n)))
               nil rate)))
           (_
            (cmacs-speech-sherpa--submit
             h 'run callback input nil
             (append (when-let* ((n (cmacs-speech-option resolved :num-speakers)))
                       (list :num-speakers n))
                     (when-let* ((x (cmacs-speech-option resolved :threshold)))
                       (list :threshold x))
                     (when-let* ((k (cmacs-speech-option resolved :top-k))) (list :top-k k)))
             chunk-fn rate))))))))

;;;; Synchronous variants (RPC)

(defun cmacs-speech-sherpa--handle-now (kind config)
  "A loaded handle for KIND/CONFIG, opening it synchronously if needed."
  (let* ((config (cmacs-speech-sherpa--common-config kind config))
         (key (cons kind config))
         (slot (gethash key cmacs-speech-sherpa--slots)))
    (or (and slot (cmacs-speech-sherpa--slot-handle slot))
        (let ((h (cmacs-sherpa-open kind config)))
          (puthash key (cmacs-speech-sherpa--slot-make :key key :handle h :used (float-time))
                   cmacs-speech-sherpa--slots)
          (cmacs-speech-sherpa--after-open kind config h)
          (cmacs-speech-sherpa--evict)
          h))))

(defun cmacs-speech-sherpa--transcribe-now (resolved pcm rate)
  "Offline transcription of PCM, synchronously."
  (let ((spec (cmacs-speech-sherpa--spec-for resolved 'asr)))
    (cmacs-sherpa-run (cmacs-speech-sherpa--handle-now (car spec) (cdr spec))
                      'run pcm nil
                      (when-let* ((hot (cmacs-speech-option resolved :hotwords)))
                        (list :hotwords hot))
                      rate)))

(defun cmacs-speech-sherpa--synthesize-now (resolved text)
  "Speak TEXT with RESOLVED's model, synchronously."
  (let ((spec (cmacs-speech-sherpa--spec-for resolved 'tts)))
    (cmacs-sherpa-run (cmacs-speech-sherpa--handle-now (car spec) (cdr spec))
                      'run nil text
                      (append
                       (when-let* ((sp (cmacs-speech-option resolved :speaker))) (list :sid sp))
                       (when-let* ((sp (cmacs-speech-option resolved :speed))) (list :speed sp))))))

(defun cmacs-speech-sherpa--run-now (resolved component input)
  "Analysis COMPONENT of INPUT, synchronously."
  (let ((result nil) (done nil))
    ;; Reuse the async router's config logic, but on a handle opened now
    ;; and run on this thread.
    (cl-letf (((symbol-function 'cmacs-speech-sherpa-with-handle)
               (lambda (kind config fn &optional _parent)
                 (funcall fn (cmacs-speech-sherpa--handle-now kind config))))
              ((symbol-function 'cmacs-speech-sherpa--submit)
               (lambda (handle op callback &rest args)
                 (funcall callback
                          (condition-case err
                              (cmacs-sherpa-run handle op (nth 0 args) (nth 1 args)
                                                (nth 2 args) (nth 4 args))
                            (error (list (cons :error (error-message-string err)))))))))
      (cmacs-speech-sherpa--run resolved component input
                                (lambda (r) (setq result r done t)) nil))
    (if done result (list (cons :error "no result")))))

;;;; Registration

(defun cmacs-speech-sherpa--describe ()
  "Version line for the settings buffer."
  (if (cmacs-speech-sherpa-available-p)
      (format "sherpa-onnx %s on onnxruntime %s (%s), %d models installed"
              (cmacs-sherpa-version) (cmacs-sherpa-onnxruntime-version)
              cmacs-speech-sherpa-provider (length (cmacs-speech-sherpa-models)))
    "not built in (configure --with-cmacs-sherpa; needs onnxruntime-devel)"))

(cmacs-speech-define-backend
 'sherpa
 :label "sherpa-onnx"
 :components '(stt stt-live stt-stream wake vad tts diarize speaker-id
               punctuate lang-id audio-tag denoise separate)
 :available-p (lambda (_c) (cmacs-speech-sherpa-available-p))
 :models (lambda (c) (mapcar #'car (cmacs-speech-sherpa-models c)))
 :default-model #'cmacs-speech-sherpa-default-model
 :describe #'cmacs-speech-sherpa--describe
 :transcribe #'cmacs-speech-sherpa--transcribe
 :transcribe-now #'cmacs-speech-sherpa--transcribe-now
 :synthesize-now #'cmacs-speech-sherpa--synthesize-now
 :run-now #'cmacs-speech-sherpa--run-now
 :stream-open #'cmacs-speech-sherpa--stream-open
 :stream-feed #'cmacs-speech-sherpa--stream-feed
 :stream-finish #'cmacs-speech-sherpa--stream-finish
 :stream-close #'cmacs-speech-sherpa--stream-close
 :wake-open #'cmacs-speech-sherpa--wake-open
 :wake-feed #'cmacs-speech-sherpa--wake-feed
 :wake-close #'cmacs-speech-sherpa--stream-close
 :vad-open #'cmacs-speech-sherpa--vad-open
 :vad-feed #'cmacs-speech-sherpa--vad-feed
 :vad-close #'cmacs-sherpa-close
 :synthesize #'cmacs-speech-sherpa--synthesize
 :cancel #'cmacs-speech-sherpa--cancel
 :run #'cmacs-speech-sherpa--run)

(provide 'cmacs-speech-sherpa)
;;; cmacs-speech-sherpa.el ends here
