;;; cmacs-speech-models.el --- the speech model store: catalog and downloads  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What models exist, which are installed, and getting them.
;;
;; The catalog (etc/cmacs/speech-models.eld, generated from the YAML
;; seed beside it by admin/cmacs-speech-catalog.sh) lists curated models
;; with URL, size, SHA-256, languages and a rough quality/speed rating.
;; `cmacs-speech-models' merges it with what the backends find installed,
;; so a model dropped into the store by hand shows up too, marked local.
;;
;; Downloads never block and never start on their own -- only an explicit
;; command does (the same rule hand tracking follows).  Each one is a
;; pipeline of plain processes:
;;
;;   curl -L --fail -C -  -> <dest>.part   (resumable; progress is the
;;                                          .part's size, polled)
;;   sha256sum            -> must match the catalog, else the .part goes
;;   tar -x               -> into a staging directory beside the target
;;   rename               -> into place, atomically
;;
;; so a crash or cancel never leaves a half-model where a backend would
;; load it.  `cmacs-speech-models-download-parallel' downloads run at
;; once; the rest queue.  Progress and completion are announced through
;; hooks the settings buffer listens to, the mode line, and (under gowl)
;; a bar toast.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-speech)

(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(declare-function cmacs-piper-voice-path "cmacs-piper" (&optional name))
(declare-function cmacs-speech-sherpa-model-path "cmacs-speech-sherpa" (id))
(declare-function cmacs-speech-sherpa-unload-all "cmacs-speech-sherpa" ())
(declare-function gowl-bar-notify "cmacs-gowl.c")

(defgroup cmacs-speech-models nil
  "The speech model store."
  :group 'cmacs-speech
  :prefix "cmacs-speech-models-")

(defcustom cmacs-speech-models-catalog-file
  (expand-file-name "cmacs/speech-models.eld" data-directory)
  "The generated model catalog."
  :type 'file
  :group 'cmacs-speech-models)

(defcustom cmacs-speech-models-download-parallel 2
  "How many models download at the same time."
  :type 'integer
  :group 'cmacs-speech-models)

(defcustom cmacs-speech-models-retries 2
  "How many times a failed download is retried (resuming) before giving up."
  :type 'integer
  :group 'cmacs-speech-models)

(defcustom cmacs-speech-models-curl-program "curl"
  "curl, for downloads."
  :type 'string
  :group 'cmacs-speech-models)

(defcustom cmacs-speech-models-url-rewrites nil
  "Rewrite download URLs: ((REGEXP . REPLACEMENT) ...).
For a mirror, e.g. ((\"\\\\`https://huggingface.co/\" . \"https://hf-mirror.com/\"))."
  :type '(alist :key-type regexp :value-type string)
  :group 'cmacs-speech-models)

(defcustom cmacs-speech-models-gowl-toast t
  "Announce finished downloads with a gowl bar toast when under gowl."
  :type 'boolean
  :group 'cmacs-speech-models)

(defvar cmacs-speech-model-progress-functions nil
  "Abnormal hook: (ID STATUS) whenever a download's status changes.
STATUS is a `cmacs-speech-models-job'.")

(defvar cmacs-speech-model-installed-functions nil
  "Abnormal hook: (ID PATH) when a model finishes installing.")

;;;; Catalog

(defvar cmacs-speech-models--catalog nil "Parsed catalog, or nil.")
(defvar cmacs-speech-models--catalog-mtime nil "Catalog file mtime at parse.")

(defun cmacs-speech-models--load-catalog ()
  "The catalog's model plists, re-read when the file changes."
  (let ((mtime (file-attribute-modification-time
                (file-attributes cmacs-speech-models-catalog-file))))
    (unless (and cmacs-speech-models--catalog
                 (equal mtime cmacs-speech-models--catalog-mtime))
      (setq cmacs-speech-models--catalog
            (when (file-readable-p cmacs-speech-models-catalog-file)
              (with-temp-buffer
                (insert-file-contents cmacs-speech-models-catalog-file)
                (alist-get 'models (read (current-buffer)))))
            cmacs-speech-models--catalog-mtime mtime))
    cmacs-speech-models--catalog))

(cl-defun cmacs-speech-models-catalog (&key component backend language)
  "Catalog entries, filtered by COMPONENT, BACKEND and LANGUAGE."
  (cl-remove-if-not
   (lambda (m)
     (and (or (null component) (memq component (plist-get m :components)))
          (or (null backend) (eq backend (plist-get m :backend)))
          (or (null language)
              (member language (plist-get m :languages))
              (member "multi" (plist-get m :languages)))))
   (cmacs-speech-models--load-catalog)))

(defun cmacs-speech-models-entry (backend id)
  "The catalog entry for BACKEND's model ID, or nil."
  (cl-find-if (lambda (m) (and (eq (plist-get m :backend) backend)
                               (equal (plist-get m :id) id)))
              (cmacs-speech-models--load-catalog)))

;;;; Installed models

(defun cmacs-speech-models-install-path (entry)
  "Where ENTRY gets installed: a directory (sherpa) or a file."
  (let ((dir (car (cmacs-speech-model-dirs (plist-get entry :backend)))))
    (expand-file-name (plist-get entry :id) dir)))

(defun cmacs-speech-models-installed-path (backend id)
  "The installed path of BACKEND's model ID, or nil."
  (pcase backend
    ('sherpa (and (fboundp 'cmacs-speech-sherpa-model-path)
                  (cmacs-speech-sherpa-model-path id)))
    ('whisper (and (require 'cmacs-whisper nil t)
                   (let ((p (cmacs-whisper-model-path id))) (and (file-exists-p p) p))))
    ('piper (and (require 'cmacs-piper nil t)
                 (let ((p (cmacs-piper-voice-path id))) (and (file-exists-p p) p))))
    (_ (let ((p (expand-file-name id (car (cmacs-speech-model-dirs backend)))))
         (and (file-exists-p p) p)))))

(defun cmacs-speech-models--installed-ids (backend component)
  "Ids BACKEND reports installed for COMPONENT (or every component)."
  (delete-dups
   (cl-loop for c in (if component (list component)
                       (mapcar #'car cmacs-speech-components))
            append (and (cmacs-speech-backend backend)
                        (memq c (plist-get (cmacs-speech-backend backend) :components))
                        (cmacs-speech-backend-models backend c)))))

(cl-defun cmacs-speech-models (&key component backend language installed)
  "Every known model as a plist: catalog entries plus local installs.
Adds :installed (path or nil), :local (installed, not in the catalog)
and :job (a running download).  Filter by COMPONENT, BACKEND, LANGUAGE;
INSTALLED `only' or `none' restricts to installed or available."
  (let ((out nil) (seen (make-hash-table :test 'equal)))
    (dolist (m (cmacs-speech-models-catalog :component component :backend backend
                                            :language language))
      (let ((key (cons (plist-get m :backend) (plist-get m :id))))
        (puthash key t seen)
        (push (append (list :installed (cmacs-speech-models-installed-path
                                        (car key) (cdr key))
                            :job (cmacs-speech-models-job (cdr key)))
                      m)
              out)))
    ;; Installed models the catalog does not know: drop-ins.
    (unless language
      (dolist (b (if backend (list backend) cmacs-speech-backend-order))
        (dolist (id (cmacs-speech-models--installed-ids b component))
          (unless (gethash (cons b id) seen)
            (puthash (cons b id) t seen)
            (push (list :id id :backend b :local t
                        :components (if component (list component)
                                      (cl-loop for (c) in cmacs-speech-components
                                               when (member id (cmacs-speech-backend-models b c))
                                               collect c))
                        :installed (cmacs-speech-models-installed-path b id)
                        :description "installed locally (not in the catalog)")
                  out)))))
    (setq out (nreverse out))
    (pcase installed
      ('only (cl-remove-if-not (lambda (m) (plist-get m :installed)) out))
      ('none (cl-remove-if (lambda (m) (plist-get m :installed)) out))
      (_ out))))

(defun cmacs-speech-models-disk-usage ()
  "Bytes used by the store."
  (let ((total 0))
    (when (file-directory-p cmacs-speech-models-directory)
      (dolist (f (directory-files-recursively cmacs-speech-models-directory "" nil t))
        (when (file-regular-p f)
          (cl-incf total (or (file-attribute-size (file-attributes f)) 0)))))
    total))

;;;; Downloads

(cl-defstruct (cmacs-speech-models-job (:constructor cmacs-speech-models--job-make)
                                       (:copier nil))
  id entry state (bytes 0) total (speed 0.0) error process
  (tries 0) started part dest staging timer (last-bytes 0) (last-time 0.0))

(defvar cmacs-speech-models--jobs nil "Every job this session, newest first.")
(defvar cmacs-speech-models--mode-line nil "Mode-line text while downloading.")

(defun cmacs-speech-models-job (id)
  "The most recent download job for model ID, or nil."
  (cl-find id cmacs-speech-models--jobs :key #'cmacs-speech-models-job-id :test #'equal))

(defun cmacs-speech-models-active-jobs ()
  "Jobs queued or in progress."
  (cl-remove-if-not (lambda (j) (memq (cmacs-speech-models-job-state j)
                                      '(queued downloading verifying extracting)))
                    cmacs-speech-models--jobs))

(defun cmacs-speech-models--notify (job)
  "Run the progress hook and refresh the mode line for JOB."
  (let ((active (cmacs-speech-models-active-jobs)))
    (setq cmacs-speech-models--mode-line
          (when active
            (let ((done (apply #'+ (mapcar #'cmacs-speech-models-job-bytes active)))
                  (total (apply #'+ (mapcar (lambda (j) (or (cmacs-speech-models-job-total j) 0))
                                            active))))
              (format " ⬇%d%s" (length active)
                      (if (> total 0) (format " %d%%" (/ (* 100 done) total)) "")))))
    (force-mode-line-update t))
  (run-hook-with-args 'cmacs-speech-model-progress-functions
                      (cmacs-speech-models-job-id job) job))

(unless (assq 'cmacs-speech-models--mode-line mode-line-misc-info)
  (push '(cmacs-speech-models--mode-line cmacs-speech-models--mode-line)
        mode-line-misc-info))

(defun cmacs-speech-models--url (url)
  "URL after `cmacs-speech-models-url-rewrites'."
  (cl-loop for (re . to) in cmacs-speech-models-url-rewrites
           do (setq url (replace-regexp-in-string re to url t t)))
  url)

(defun cmacs-speech-models--toast (summary &optional body)
  "A gowl bar toast, when running under gowl and enabled."
  (when (and cmacs-speech-models-gowl-toast (fboundp 'gowl-bar-notify))
    (ignore-errors (gowl-bar-notify summary body))))

(cl-defun cmacs-speech-models-download (entry &key wait callback)
  "Download and install catalog ENTRY (a plist, or (BACKEND . ID)).
Returns the job.  CALLBACK gets (PATH) or (nil ERROR) when it ends.
WAIT blocks until then (redisplay continues) and returns the path or
signals.  Nothing is downloaded that is already installed."
  (when (consp (car-safe entry))
    (setq entry (cmacs-speech-models-entry (caar entry) (cdar entry))))
  (when (and (consp entry) (symbolp (car entry)) (not (keywordp (car entry))))
    (setq entry (or (cmacs-speech-models-entry (car entry) (cdr entry))
                    (user-error "No catalog entry for %s model %s" (car entry) (cdr entry)))))
  (let* ((id (plist-get entry :id))
         (existing (cmacs-speech-models-job id)))
    (when (cmacs-speech-models-installed-path (plist-get entry :backend) id)
      (user-error "%s is already installed" id))
    (let ((job (if (and existing (memq (cmacs-speech-models-job-state existing)
                                       '(queued downloading verifying extracting)))
                   existing
                 (let ((j (cmacs-speech-models--job-make
                           :id id :entry entry :state 'queued
                           :total (let ((s (plist-get entry :size))) (and s (> s 0) s))
                           :dest (cmacs-speech-models-install-path entry))))
                   (push j cmacs-speech-models--jobs)
                   j))))
      (when callback
        (let ((hook nil))
          (setq hook (lambda (jid j)
                       (when (and (equal jid id)
                                  (memq (cmacs-speech-models-job-state j) '(done failed cancelled)))
                         (remove-hook 'cmacs-speech-model-progress-functions hook)
                         (if (eq (cmacs-speech-models-job-state j) 'done)
                             (funcall callback (cmacs-speech-models-job-dest j))
                           (funcall callback nil (or (cmacs-speech-models-job-error j)
                                                     "cancelled"))))))
          (add-hook 'cmacs-speech-model-progress-functions hook)))
      (cmacs-speech-models--notify job)
      (cmacs-speech-models--pump)
      (if (not wait)
          job
        (while (memq (cmacs-speech-models-job-state job)
                     '(queued downloading verifying extracting))
          (accept-process-output nil 0.1))
        (if (eq (cmacs-speech-models-job-state job) 'done)
            (cmacs-speech-models-job-dest job)
          (error "Download of %s failed: %s" id (cmacs-speech-models-job-error job)))))))

(defun cmacs-speech-models--pump ()
  "Start queued jobs up to the parallel limit."
  (let ((running (cl-count-if (lambda (j) (memq (cmacs-speech-models-job-state j)
                                                '(downloading verifying extracting)))
                              cmacs-speech-models--jobs)))
    (dolist (job (reverse cmacs-speech-models--jobs))
      (when (and (eq (cmacs-speech-models-job-state job) 'queued)
                 (< running cmacs-speech-models-download-parallel))
        (cl-incf running)
        (cmacs-speech-models--fetch job)))))

(defun cmacs-speech-models--finish (job state &optional error)
  "End JOB in STATE (done/failed/cancelled) with ERROR."
  (when-let* ((tm (cmacs-speech-models-job-timer job))) (cancel-timer tm))
  (setf (cmacs-speech-models-job-state job) state
        (cmacs-speech-models-job-error job) error
        (cmacs-speech-models-job-process job) nil
        (cmacs-speech-models-job-timer job) nil)
  (when-let* ((st (cmacs-speech-models-job-staging job)))
    (when (file-exists-p st) (delete-directory st t)))
  (pcase state
    ('done
     (message "Speech model %s installed" (cmacs-speech-models-job-id job))
     (cmacs-speech-models--toast "Speech model installed" (cmacs-speech-models-job-id job))
     (run-hook-with-args 'cmacs-speech-model-installed-functions
                         (cmacs-speech-models-job-id job) (cmacs-speech-models-job-dest job))
     ;; New models change what `auto' resolves to.
     (run-hooks 'cmacs-speech-config-changed-hook))
    ('failed
     (message "Speech model %s failed: %s" (cmacs-speech-models-job-id job) error)
     (cmacs-speech-models--toast "Speech model download failed"
                                 (format "%s: %s" (cmacs-speech-models-job-id job) error))))
  (cmacs-speech-models--notify job)
  (cmacs-speech-models--pump))

(defun cmacs-speech-models--run (job name command next)
  "Run COMMAND for JOB; call NEXT with (OK OUTPUT)."
  (let ((buf (generate-new-buffer (format " *speech-model %s*" name))))
    (setf (cmacs-speech-models-job-process job)
          (make-process
           :name (format "speech-model-%s" name) :buffer buf :noquery t
           :connection-type 'pipe :command command
           :sentinel
           (lambda (proc _event)
             (unless (process-live-p proc)
               (let ((ok (and (eq (process-status proc) 'exit)
                              (zerop (process-exit-status proc))))
                     (out (with-current-buffer buf (string-trim (buffer-string)))))
                 (kill-buffer buf)
                 (unless (eq (cmacs-speech-models-job-state job) 'cancelled)
                   (funcall next ok out)))))))))

(defun cmacs-speech-models--tick (job)
  "Progress from the size of JOB's .part file."
  (when-let* ((part (cmacs-speech-models-job-part job))
              (attrs (file-attributes part)))
    (let* ((bytes (file-attribute-size attrs))
           (now (float-time))
           (dt (- now (cmacs-speech-models-job-last-time job))))
      (when (> dt 0.4)
        (setf (cmacs-speech-models-job-speed job)
              (/ (max 0 (- bytes (cmacs-speech-models-job-last-bytes job))) dt)
              (cmacs-speech-models-job-last-bytes job) bytes
              (cmacs-speech-models-job-last-time job) now))
      (setf (cmacs-speech-models-job-bytes job) bytes)
      (cmacs-speech-models--notify job))))

(defun cmacs-speech-models--fetch (job)
  "Start or resume JOB's download."
  (let* ((entry (cmacs-speech-models-job-entry job))
         (dest (cmacs-speech-models-job-dest job))
         (part (concat (directory-file-name dest) ".part"))
         (url (cmacs-speech-models--url (plist-get entry :url))))
    (make-directory (file-name-directory part) t)
    (setf (cmacs-speech-models-job-state job) 'downloading
          (cmacs-speech-models-job-part job) part
          (cmacs-speech-models-job-started job) (or (cmacs-speech-models-job-started job)
                                                    (float-time))
          (cmacs-speech-models-job-last-time job) (float-time)
          (cmacs-speech-models-job-timer job)
          (run-at-time 0.5 0.5 #'cmacs-speech-models--tick job))
    (cmacs-speech-models--notify job)
    (cmacs-speech-models--run
     job "curl"
     (list cmacs-speech-models-curl-program "-L" "--fail" "--silent" "--show-error"
           "-C" "-" "-o" part url)
     (lambda (ok out)
       (when-let* ((tm (cmacs-speech-models-job-timer job))) (cancel-timer tm))
       (setf (cmacs-speech-models-job-timer job) nil)
       (cmacs-speech-models--tick job)
       (cond
        (ok (cmacs-speech-models--verify job))
        ((< (cmacs-speech-models-job-tries job) cmacs-speech-models-retries)
         (cl-incf (cmacs-speech-models-job-tries job))
         ;; Back off, then resume where the .part left off.
         (run-at-time (* 2 (cmacs-speech-models-job-tries job)) nil
                      #'cmacs-speech-models--fetch job))
        (t (cmacs-speech-models--finish job 'failed (format "download failed: %s" out))))))))

(defun cmacs-speech-models--verify (job)
  "Check JOB's .part against the catalog's size and SHA-256."
  (let* ((entry (cmacs-speech-models-job-entry job))
         (part (cmacs-speech-models-job-part job))
         (size (plist-get entry :size))
         (have (file-attribute-size (file-attributes part)))
         (sha (plist-get entry :sha256)))
    (cond
     ((and size (> size 0) (/= size have))
      (delete-file part)
      (cmacs-speech-models--finish job 'failed
                                   (format "size %d, expected %d (removed; retry to fetch again)"
                                           have size)))
     ((null sha) (cmacs-speech-models--unpack job))
     (t
      (setf (cmacs-speech-models-job-state job) 'verifying)
      (cmacs-speech-models--notify job)
      (cmacs-speech-models--run
       job "sha256" (list "sha256sum" part)
       (lambda (ok out)
         (if (and ok (string-prefix-p (downcase sha) (downcase out)))
             (cmacs-speech-models--unpack job)
           (delete-file part)
           (cmacs-speech-models--finish
            job 'failed "checksum mismatch (removed; retry to fetch again)"))))))))

(defun cmacs-speech-models--unpack (job)
  "Extract (or place) JOB's verified download, then move it into place."
  (let* ((entry (cmacs-speech-models-job-entry job))
         (part (cmacs-speech-models-job-part job))
         (dest (cmacs-speech-models-job-dest job))
         (archive (plist-get entry :archive)))
    (cond
     ;; One sherpa .onnx file: it becomes <store>/sherpa/<id>/<file>, so
     ;; every sherpa model is a directory.
     ((and (null archive) (eq (plist-get entry :backend) 'sherpa))
      (let ((staging (concat dest ".staging")))
        (when (file-exists-p staging) (delete-directory staging t))
        (make-directory staging t)
        (rename-file part (expand-file-name (file-name-nondirectory
                                             (cmacs-speech-models--url-file (plist-get entry :url)))
                                            staging))
        (rename-file staging dest)
        (cmacs-speech-models--extra-files job)))
     ((null archive)
      (rename-file part dest t)
      (cmacs-speech-models--extra-files job))
     (t
      (let ((staging (concat dest ".staging")))
        (when (file-exists-p staging) (delete-directory staging t))
        (make-directory staging t)
        (setf (cmacs-speech-models-job-state job) 'extracting
              (cmacs-speech-models-job-staging job) staging)
        (cmacs-speech-models--notify job)
        (cmacs-speech-models--run
         job "tar" (list "tar" "-xf" part "-C" staging)
         (lambda (ok out)
           (if (not ok)
               (cmacs-speech-models--finish job 'failed (format "extract failed: %s" out))
             (delete-file part)
             ;; sherpa archives hold one top directory named like the
             ;; model; take its contents, whatever it is called.
             (let* ((kids (directory-files staging t "\\`[^.]"))
                    (root (if (and (= (length kids) 1) (file-directory-p (car kids)))
                              (car kids) staging)))
               (when (file-exists-p dest) (delete-directory dest t))
               (rename-file root dest)
               (cmacs-speech-models--finish job 'done))))))))))

(defun cmacs-speech-models--url-file (url)
  "The last path component of URL, without a query."
  (file-name-nondirectory (car (split-string url "[?#]"))))

(defun cmacs-speech-models--extra-files (job)
  "Fetch JOB's :extra-files (a piper voice's .onnx.json), then finish."
  (let ((extras (plist-get (cmacs-speech-models-job-entry job) :extra-files)))
    (if (null extras)
        (cmacs-speech-models--finish job 'done)
      (let* ((x (car extras))
             (dest (expand-file-name (plist-get x :name)
                                     (file-name-directory (cmacs-speech-models-job-dest job)))))
        (cmacs-speech-models--run
         job "extra" (list cmacs-speech-models-curl-program "-L" "--fail" "--silent"
                           "--show-error" "-o" dest
                           (cmacs-speech-models--url (plist-get x :url)))
         (lambda (ok out)
           (if ok
               (progn
                 (setf (cmacs-speech-models-job-entry job)
                       (plist-put (copy-sequence (cmacs-speech-models-job-entry job))
                                  :extra-files (cdr extras)))
                 (cmacs-speech-models--extra-files job))
             (cmacs-speech-models--finish job 'failed (format "%s: %s" (plist-get x :name)
                                                              out)))))))))

(defun cmacs-speech-models-cancel (id)
  "Cancel the download of model ID; its .part stays for a later resume."
  (interactive (list (completing-read "Cancel download: "
                                      (mapcar #'cmacs-speech-models-job-id
                                              (cmacs-speech-models-active-jobs))
                                      nil t)))
  (when-let* ((job (cmacs-speech-models-job id)))
    (when (memq (cmacs-speech-models-job-state job) '(queued downloading verifying extracting))
      (let ((proc (cmacs-speech-models-job-process job)))
        (setf (cmacs-speech-models-job-state job) 'cancelled)
        ;; Signal the process this job started, never anything by name.
        (when (process-live-p proc) (delete-process proc)))
      (cmacs-speech-models--finish job 'cancelled))))

(defun cmacs-speech-models-delete (backend id)
  "Move installed model ID of BACKEND to the trash."
  (let ((path (or (cmacs-speech-models-installed-path backend id)
                  (user-error "%s is not installed" id))))
    (unless (file-in-directory-p path (file-truename cmacs-speech-models-directory))
      (unless (file-in-directory-p (file-truename path)
                                   (file-truename cmacs-speech-models-directory))
        (user-error "%s is outside the model store; remove it yourself" path)))
    (move-file-to-trash path)
    (when (eq backend 'piper)
      (let ((json (concat path ".json")))
        (when (file-exists-p json) (move-file-to-trash json))))
    (when (eq backend 'sherpa)
      (when (fboundp 'cmacs-speech-sherpa-unload-all) (cmacs-speech-sherpa-unload-all)))
    (run-hooks 'cmacs-speech-config-changed-hook)
    path))

;;;###autoload
(defun cmacs-speech-models-get (backend id)
  "Download BACKEND's model ID from the catalog."
  (interactive
   (let* ((avail (cmacs-speech-models :installed 'none))
          (pick (completing-read
                 "Download speech model: "
                 (mapcar (lambda (m) (format "%s  [%s]" (plist-get m :id) (plist-get m :backend)))
                         avail)
                 nil t))
          (m (nth (cl-position pick (mapcar (lambda (m) (format "%s  [%s]" (plist-get m :id)
                                                                (plist-get m :backend)))
                                            avail)
                               :test #'equal)
                  avail)))
     (list (plist-get m :backend) (plist-get m :id))))
  (cmacs-speech-models-download (or (cmacs-speech-models-entry backend id)
                                    (user-error "No catalog entry for %s" id))))

(provide 'cmacs-speech-models)
;;; cmacs-speech-models.el ends here
