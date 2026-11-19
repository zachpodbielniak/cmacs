;;; cmacs-whisper.el --- whisper.cpp offline STT for cmacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Lisp layer for cmacs-whisper.  Provides the user-facing model-
;; management commands, the M-x transcribe wrappers, and the
;; defcustoms used by `cmacs-whisper-dictate' (live STT into the
;; current buffer).
;;
;; Models live in `cmacs-whisper-models-directory' (default
;; ~/.local/share/cmacs/whisper-models/).  Download one with
;; M-x cmacs-whisper-download-model; the small/base/tiny variants
;; come from the upstream ggerganov/whisper.cpp huggingface mirror.

;;; Code:

(require 'cl-lib)
(require 'url-handlers nil 'noerror)

(declare-function cmacs-speech-model-dirs "cmacs-speech" (backend))
(declare-function cmacs-speech-models-catalog "cmacs-speech-models" (&rest keys))
(declare-function cmacs-speech-models-entry "cmacs-speech-models" (backend id))
(declare-function cmacs-speech-models-download "cmacs-speech-models" (entry &rest keys))

(defgroup cmacs-whisper nil
  "Offline speech-to-text via whisper.cpp."
  :group 'cmacs
  :prefix "cmacs-whisper-")

(defcustom cmacs-whisper-models-directory
  (expand-file-name ".local/share/cmacs/whisper-models/" "~")
  "The older per-user whisper model directory, still searched.
New downloads go to the speech model store (`cmacs-speech-models-directory',
whisper/ inside it) through `cmacs-whisper-download-model'.  System
models under `cmacs-whisper-system-models-directory' are searched too
\(see `cmacs-whisper--search-path')."
  :type 'directory
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-system-models-directory
  "/usr/share/cmacs/whisper-models/"
  "Read-only directory for system-installed whisper models.
Populated by image builds (Containerfile stages the default English
model here).  User-installed models take precedence."
  :type 'directory
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-models-search-path
  (list cmacs-whisper-models-directory
        cmacs-whisper-system-models-directory)
  "Ordered list of directories searched for whisper model files.
Earlier entries win.  Default: user dir first, then the system
location bundled by image builds."
  :type '(repeat directory)
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-default-model "ggml-base.en.bin"
  "Default model filename inside `cmacs-whisper-models-directory'.
Tiny/base/small are good real-time choices.  Medium and large
trade latency for accuracy."
  :type 'string
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-language "en"
  "Default 2-letter ISO language code (`en', `de', `fr', ...)."
  :type 'string
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-download-base-url
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
  "Base URL where `cmacs-whisper-download-model' fetches models from."
  :type 'string
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-default-vad-model "ggml-silero-v6.2.0.bin"
  "Basename of the Silero voice-activity model (ggml form).
Resolved through `cmacs-whisper-models-search-path' like a whisper
model; used by `cmacs-whisper-vad-open' callers such as
`cmacs-voice-loop-mode'.  Fetch it with
\\[cmacs-whisper-download-vad-model]."
  :type 'string
  :group 'cmacs-whisper)

(defcustom cmacs-whisper-vad-download-base-url
  "https://huggingface.co/ggml-org/whisper-vad/resolve/main/"
  "Base URL `cmacs-whisper-download-vad-model' fetches VAD models from.
The VAD models live in a different repository from the whisper models
\(the one whisper.cpp's models/download-vad-model.sh uses)."
  :type 'string
  :group 'cmacs-whisper)

(defun cmacs-whisper--search-path ()
  "Every directory whisper models are looked for in, first match wins:
the speech model store (and its extra trees), then
`cmacs-whisper-models-search-path', then the system store."
  (let ((store (and (require 'cmacs-speech nil t)
                    (cmacs-speech-model-dirs 'whisper))))
    (delete-dups (append (butlast store) cmacs-whisper-models-search-path
                         (last store)))))

(defun cmacs-whisper--download-dir ()
  "Where downloaded whisper models go: the speech model store."
  (if (require 'cmacs-speech nil t)
      (car (cmacs-speech-model-dirs 'whisper))
    cmacs-whisper-models-directory))

(defun cmacs-whisper-model-path (&optional name)
  "Resolve NAME (or `cmacs-whisper-default-model') to an absolute path.
Walks `cmacs-whisper--search-path' and returns the first existing
match.  If none is found, returns the path in the store, where a
download would put it."
  (let ((basename (or name cmacs-whisper-default-model)))
    (or (cl-some
         (lambda (dir)
           (let ((p (expand-file-name basename dir)))
             (and (file-exists-p p) p)))
         (cmacs-whisper--search-path))
        (expand-file-name basename (cmacs-whisper--download-dir)))))

(defun cmacs-whisper-list-models ()
  "Return basenames of every .bin model visible via the search path."
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (dir (cmacs-whisper--search-path))
      (when (file-directory-p dir)
        (dolist (f (directory-files dir))
          (when (string-match-p "\\.bin\\'" f)
            (puthash f t seen)))))
    (sort (hash-table-keys seen) #'string<)))

;;;###autoload
(defun cmacs-whisper-download-model (model &optional base-url)
  "Download MODEL (basename) into the speech model store.
Goes through `cmacs-speech-models-download': in the background with
progress and a checksum when called interactively, and waiting for the
file (while Emacs keeps redisplaying) when called from Lisp, which is
what callers that use the model straight after expect.  Optional
BASE-URL fetches from somewhere other than the catalog's source.
Returns the installed path."
  (interactive
   (list (completing-read "Model: "
                          (and (require 'cmacs-speech-models nil t)
                               (mapcar (lambda (m) (plist-get m :id))
                                       (cmacs-speech-models-catalog :backend 'whisper)))
                          nil nil cmacs-whisper-default-model)))
  (require 'cmacs-speech-models)
  (let ((dest (expand-file-name model (cmacs-whisper--download-dir))))
    (when (file-exists-p dest)
      (user-error "Model already present: %s" dest))
    (cmacs-speech-models-download
     (or (and (null base-url) (cmacs-speech-models-entry 'whisper model))
         (list :id model :backend 'whisper
               :url (concat (or base-url cmacs-whisper-download-base-url) model)))
     :wait (not (called-interactively-p 'any)))
    dest))

;;;###autoload
(defun cmacs-whisper-download-vad-model (model)
  "Download the Silero VAD MODEL (basename) into the models directory.
Defaults to `cmacs-whisper-default-vad-model', from
`cmacs-whisper-vad-download-base-url'.  About 1 MB."
  (interactive
   (list (read-string "VAD model basename: " cmacs-whisper-default-vad-model)))
  (cmacs-whisper-download-model model cmacs-whisper-vad-download-base-url))

;;;###autoload
(defun cmacs-whisper-transcribe-region (beg end)
  "Treat the region as a WAV file path and transcribe it.
Inserts the resulting text below the region."
  (interactive "r")
  (let* ((path (string-trim (buffer-substring-no-properties beg end)))
         (model (cmacs-whisper-model-path))
         (result (cmacs-whisper-transcribe-file model path cmacs-whisper-language))
         (text   (cdr (assq :text result)))
         (err    (cdr (assq :error result))))
    (cond
     (err (user-error "cmacs-whisper: %s" err))
     (t   (save-excursion
            (goto-char end)
            (insert "\n" (string-trim text) "\n"))
          (message "cmacs-whisper: %d chars" (length text))))))

(provide 'cmacs-whisper)

;;; cmacs-whisper.el ends here
