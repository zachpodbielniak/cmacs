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

(defgroup cmacs-whisper nil
  "Offline speech-to-text via whisper.cpp."
  :group 'cmacs
  :prefix "cmacs-whisper-")

(defcustom cmacs-whisper-models-directory
  (expand-file-name ".local/share/cmacs/whisper-models/" "~")
  "Directory where `cmacs-whisper-download-model' writes new models.
This is the user-writable location; system-installed models under
`cmacs-whisper-system-models-directory' are also searched (see
`cmacs-whisper-models-search-path')."
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

(defun cmacs-whisper-model-path (&optional name)
  "Resolve NAME (or `cmacs-whisper-default-model') to an absolute path.
Walks `cmacs-whisper-models-search-path' and returns the first
existing match.  If none is found, returns the path under
`cmacs-whisper-models-directory' (the download target)."
  (let ((basename (or name cmacs-whisper-default-model)))
    (or (cl-some
         (lambda (dir)
           (let ((p (expand-file-name basename dir)))
             (and (file-exists-p p) p)))
         cmacs-whisper-models-search-path)
        (expand-file-name basename cmacs-whisper-models-directory))))

(defun cmacs-whisper-list-models ()
  "Return basenames of every .bin model visible via the search path."
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (dir cmacs-whisper-models-search-path)
      (when (file-directory-p dir)
        (dolist (f (directory-files dir))
          (when (string-match-p "\\.bin\\'" f)
            (puthash f t seen)))))
    (sort (hash-table-keys seen) #'string<)))

;;;###autoload
(defun cmacs-whisper-download-model (model)
  "Download MODEL (basename) from `cmacs-whisper-download-base-url'."
  (interactive
   (list (read-string "Model basename (e.g. ggml-base.en.bin): "
                      cmacs-whisper-default-model)))
  (unless (file-directory-p cmacs-whisper-models-directory)
    (make-directory cmacs-whisper-models-directory t))
  (let* ((url  (concat cmacs-whisper-download-base-url model))
         (dest (expand-file-name model cmacs-whisper-models-directory)))
    (when (file-exists-p dest)
      (user-error "Model already present: %s" dest))
    (message "cmacs-whisper: downloading %s ..." url)
    (url-copy-file url dest)
    (message "cmacs-whisper: wrote %s" dest)
    dest))

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
