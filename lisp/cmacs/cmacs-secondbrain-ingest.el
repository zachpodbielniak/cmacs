;;; cmacs-secondbrain-ingest.el --- Ingest anything into the second brain  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The front door of the second brain.  Hand it a file, a URL, a
;; recording, a web page, a mail, a spreadsheet, a YouTube video or a
;; paragraph of text and it comes out the other side as ONE Org note:
;; a real org-roam node with an `:ID:', the standard header keywords, an
;; AI summary, the extracted content, related notes linked by id, and a
;; bullet in the `00_index.org' of the directory it landed in -- a
;; directory chosen by the PARA rules of the notes repository, by you or
;; by the model.
;;
;; This is the port of `sbi', the 7 000-line shell script that did the
;; same job for a Neovim-and-Markdown second brain, onto what cmacs
;; already has: cmacs-office for Office packages, the embedded whisper
;; for speech, libxml and shr for HTML, cmacs-ai for the model, the
;; brigade memory index for similarity, and D-Bus, MCP and emacsctl for
;; the surfaces.  Nothing here writes Markdown, and nothing here shells
;; out to another AI wrapper.
;;
;; The pipeline is a small state machine per job:
;;
;;   queued -> acquiring -> extracting -> analysing -> summarising
;;          -> linking -> reviewing -> writing -> done | failed | cancelled
;;
;; Every stage that can take time is asynchronous -- a subprocess with a
;; sentinel, a `url-retrieve' callback, a whisper callback, a cmacs-ai
;; stream -- and the stage that follows is kicked from the callback.
;; That is not a stylistic choice.  The same code runs when an agent
;; calls the `secondbrain_ingest' MCP tool or a shell runs `emacsctl sb
;; ingest', and those requests are dispatched on the main thread of a
;; cmacs that may be someone's Wayland compositor.  A blocking model
;; call there freezes the desktop for a minute; a subprocess with a
;; sentinel does not.  (Emacs threads would not help: they hold the
;; global Lisp lock while blocked in C.)
;;
;; The queue is global, not buffer-local, because jobs are addressed by
;; id from outside Emacs.  `*second brain: ingest*' is a VIEW of that
;; queue.
;;
;; What the model is trusted with, and what it is not.  It writes the
;; summary, proposes a title, tags and a directory.  The directory is
;; checked against the filesystem -- it must exist under the root, must
;; be a PARA category, must not be the archive -- and a proposal below
;; `cmacs-secondbrain-ingest-placement-min-confidence' goes to the inbox
;; with the model's reason recorded.  Related notes come from the
;; similarity index, not from the model; a model asked to name related
;; notes invents plausible ones, and a dangling id is worse than no
;; link.  When the model is unavailable the note is still written, with
;; the source's own title and no summary, because the material is the
;; point and the summary is a convenience.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'org)
(require 'org-id)
(require 'filenotify)
(require 'cmacs-para)
(require 'cmacs-secondbrain-ingest-extract)
(require 'cmacs-secondbrain-ingest-ai)

(declare-function cmacs-whisper-supported-p "cmacs-whisper-defuns.c" ())
(declare-function cmacs-whisper-transcribe-async "cmacs-whisper-defuns.c"
                  (model-path wav-path callback &optional language threads))
(declare-function cmacs-whisper-model-path "cmacs-whisper" (&optional name))
(declare-function cmacs-brigade-memory-search "cmacs-brigade-memory" (query &optional k))
(declare-function cmacs-secondbrain-refresh "cmacs-secondbrain" ())
(declare-function cmacs-evil-setup-mode-map "cmacs-evil" (map mode))
(declare-function cmacs-audio-record-to-file "cmacs-audio" (path &optional seconds))
(declare-function cmacs-audio-finish-recording "cmacs-audio" ())
(declare-function cmacs-gsurf-attach "cmacs-gsurf-defuns.c" (buffer &optional hidden))
(declare-function cmacs-gsurf-detach "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-load-uri "cmacs-gsurf-defuns.c" (buffer uri))
(declare-function cmacs-gsurf-run-javascript-async "cmacs-gsurf-defuns.c" (buffer script callback))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-supported-p "cmacs-gsurf-defuns.c" ())
(declare-function org-roam-db-update-file "org-roam-db" (&optional file-path no-require))
(declare-function dired-get-marked-files "dired" (&optional localp arg filter distinguish-one-marked error))

(defvar cmacs-whisper-language)
(defvar cmacs-brigade-memory-index-dir)
(defvar cmacs-secondbrain-buffer-name)
(defvar cmacs-secondbrain-mode-map)
(defvar cmacs-gsurf-load-changed-functions)

;;;; Where notes go -------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-root nil
  "Root of the notes tree to ingest into, or nil for the first PARA root.
See `cmacs-para-roots'.  A job's `:root' or `:branch' option overrides
this for that job."
  :type '(choice (const :tag "First cmacs-para root" nil) directory)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-placement 'detect
  "Where a note goes when no PARA category is given.

`detect' asks the model to choose a directory from the real tree and
files to the inbox when it is unsure; `inbox' skips the model and files
everything to `00_inbox' for triage by hand.  An explicit `:para' or
`:directory' on a job always wins."
  :type '(choice (const detect) (const inbox))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-placement-min-confidence 0.6
  "Below this confidence a model's placement is ignored and the inbox used.
The model's reason is recorded in the note either way."
  :type 'number
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-placement-depth 4
  "How deep into the tree the model may file: 4 allows
category/scope/topic/subtopic, e.g. 03_resources/personal/finance/investing."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-placement-max-dirs 400
  "Largest directory list offered to the model.  The shallowest win."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-placement-exclude
  '("/\\.[^/]" "/trees/" "\\`04_archives" "/dailies\\'" "/dailies/"
    "ai_chats" "libreclaw_chats" "cmacs_ai_chats" "/repos/[^/]+/docs"
    "/attachments" "/journal/")
  "Regexps matched against a directory's root-relative path.
A match removes it from the model's choices and from `:directory'.
Generated mirrors, chat logs and dailies are not places to file a note."
  :type '(repeat regexp)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-default-scope "personal"
  "Subdirectory used under a PARA category when none is given.
The repository's own rule: default to personal/ unless the material is
clearly work.  Set to nil to file directly under the category."
  :type '(choice (const nil) string)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-create-directories t
  "Allow `:category' and `:directory' to name a directory that does not exist yet.
A created directory gets its own `00_index.org', linked from its parent."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

;;;; What the note looks like ---------------------------------------------

(defcustom cmacs-secondbrain-ingest-author (or user-login-name "unknown")
  "Value of the `#+authors:' keyword."
  :type 'string
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-filename-style 'slug
  "How a note is named: `slug' is title_as_slug.org, `date-slug' prefixes
the date as 2026-09-05_title_as_slug.org."
  :type '(choice (const slug) (const date-slug))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-slug-max-length 80
  "Longest filename slug generated from a title."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-on-collision 'unique
  "What to do when the target file already exists.

`unique' adds _2, _3 ...; `append' adds a dated section to the existing
note (what `sbi' did); `overwrite' replaces it; `error' fails the job.
A job's `:append' option forces `append'."
  :type '(choice (const unique) (const append) (const overwrite) (const error))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-include-content t
  "Include the extracted content in the note, not only the summary.
The content is the point; the summary is the convenience.  Set to nil
for a summary-only note that records where the original lives."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-max-content-chars 2000000
  "Content longer than this is cut, with a line saying so."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-keep-source nil
  "Whether to keep a copy of the original file next to the note.
nil records the original path only; `copy' copies it into a hidden
`.attachments/' directory beside the note and links it."
  :type '(choice (const nil) (const copy))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-summarize t
  "Generate an AI summary by default.  A job's `:no-summary' disables it."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-summary-type 'auto
  "Default summary type; `auto' lets the model choose from
`cmacs-secondbrain-ingest-summary-templates'."
  :type 'symbol
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-suggest-tags t
  "Ask the model for tags.  They are merged with any the user gave."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-link-related t
  "Add a `* See also' section of related notes found by similarity.
Needs the brigade memory index; silently skipped without it."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-related-count 5
  "How many related notes to link."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-related-min-score 0.0
  "Minimum fused score for a related note to be linked."
  :type 'number
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-register-index t
  "Add the note to its directory's `00_index.org', creating one if needed."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-update-roam-db t
  "Tell org-roam about the new file when org-roam is loaded."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-refresh-view t
  "Refresh an open second-brain visualiser after a note is written."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-sanitize nil
  "Redact sensitive strings before the model sees the material and before
it is stored.  t uses the default-on rules of
`cmacs-secondbrain-ingest-redaction-rules'; a list names rules."
  :type '(choice (const nil) (const t) (repeat symbol))
  :group 'cmacs-secondbrain-ingest)

;;;; Media and web ---------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-youtube-strategy 'subtitles-then-audio
  "How a YouTube video becomes text.

`subtitles-then-audio' asks yt-dlp for captions and falls back to
downloading the audio and running whisper; `subtitles' never downloads
audio; `audio' always transcribes.  Captions are cheap and usually
good; the fallback exists for videos without them."
  :type '(choice (const subtitles-then-audio) (const subtitles) (const audio))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-whisper-model nil
  "Whisper model file for transcription, or nil for cmacs-whisper's default."
  :type '(choice (const nil) file)
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-whisper-threads 4
  "CPU threads whisper may use."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-web-backend 'url
  "How pages are fetched: `url' with url.el, `gsurf' through an offscreen
WebKit view so JavaScript runs and logged-in sessions apply.  A job's
`:web-backend' overrides."
  :type '(choice (const url) (const gsurf))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-gsurf-settle 1.5
  "Seconds after a gsurf page finishes loading before its DOM is read."
  :type 'number
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-crawl-depth 1
  "Default link depth for `:crawl'; 0 is only the page itself."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-crawl-max-pages 50
  "Hard cap on pages fetched by one crawl."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-crawl-wait 1.0
  "Seconds between requests during a crawl."
  :type 'number
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-crawl-respect-robots t
  "Honour robots.txt Disallow rules for `User-agent: *' while crawling."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

;;;; Machinery ------------------------------------------------------------

(defcustom cmacs-secondbrain-ingest-parallel-jobs 2
  "How many jobs run at once.  Model calls and transcriptions are the
expensive stages; two keeps a batch moving without saturating either."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-verbose nil
  "Echo every stage transition in the echo area as well as the log."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-log-file nil
  "Also append the log to this file, when non-nil."
  :type '(choice (const nil) file)
  :group 'cmacs-secondbrain-ingest)

(defvar cmacs-secondbrain-ingest-before-write-functions nil
  "Abnormal hook run with the JOB just before its note is written.
A function may edit the job's `analysis', `summary' or `tags' slots.")

(defvar cmacs-secondbrain-ingest-after-note-functions nil
  "Abnormal hook run after a note is written, with an INFO plist:
  :file :id :title :kind :source :dir :tags :summary :warnings :job-id
  :extractor :related (list of linked ids) :append (non-nil if appended)")

(defvar cmacs-secondbrain-ingest-after-job-functions nil
  "Abnormal hook run when a job reaches done, failed or cancelled, with the JOB.")

;;;; Jobs ----------------------------------------------------------------

(cl-defstruct (cmacs-secondbrain-ingest-job
               (:constructor cmacs-secondbrain-ingest-job--create)
               (:copier nil))
  id            ; "sbi-N"
  input         ; the path, URL, or "<text>"
  kind          ; content kind symbol
  options       ; normalised plist
  (stage 'queued)
  (progress "")
  (log nil)     ; reversed list of strings
  started finished
  doc           ; extracted document plist
  analysis      ; normalised analysis plist
  summary       ; summary string
  summary-type  ; resolved symbol
  title tags description
  target-dir target-file
  note-id note-file
  related       ; list of (ID TITLE PATH SCORE)
  (warnings nil)
  error
  process       ; live subprocess for the current stage, or nil
  cancel-fn     ; closure that aborts the current async stage, or nil
  tmpdir
  cancelled
  appended
  pages         ; for crawls and site exports: list of docs
  crawl         ; crawler state plist
  written       ; every file this job created or changed (notes, indices)
  callbacks)    ; functions of (JOB) called at the end

(defvar cmacs-secondbrain-ingest--jobs nil
  "Every job this session, newest first.")

(defvar cmacs-secondbrain-ingest--counter 0)

(defconst cmacs-secondbrain-ingest-buffer-name "*second brain: ingest*")
(defconst cmacs-secondbrain-ingest-log-buffer-name "*second brain: ingest log*")

(defun cmacs-secondbrain-ingest-jobs () "Return every job, newest first." cmacs-secondbrain-ingest--jobs)

(defun cmacs-secondbrain-ingest-job (id)
  "Return the job with ID (a string or a job), or nil."
  (if (cmacs-secondbrain-ingest-job-p id) id
    (cl-find id cmacs-secondbrain-ingest--jobs
             :key #'cmacs-secondbrain-ingest-job-id :test #'equal)))

(defun cmacs-secondbrain-ingest--active-p (job)
  (not (memq (cmacs-secondbrain-ingest-job-stage job) '(queued done failed cancelled))))

(defun cmacs-secondbrain-ingest--finished-p (job)
  (memq (cmacs-secondbrain-ingest-job-stage job) '(done failed cancelled)))

(defun cmacs-secondbrain-ingest--log (job fmt &rest args)
  "Log a line for JOB (or nil for the queue itself)."
  (let* ((msg (apply #'format fmt args))
         (line (format "%s %s %s" (format-time-string "%T")
                       (if job (cmacs-secondbrain-ingest-job-id job) "queue") msg)))
    (when job (push msg (cmacs-secondbrain-ingest-job-log job)))
    (with-current-buffer (get-buffer-create cmacs-secondbrain-ingest-log-buffer-name)
      (goto-char (point-max))
      (let ((inhibit-read-only t)) (insert line "\n")))
    (when cmacs-secondbrain-ingest-log-file
      (ignore-errors
        (write-region (concat line "\n") nil cmacs-secondbrain-ingest-log-file t 'silent)))
    (when cmacs-secondbrain-ingest-verbose (message "sb ingest: %s" msg))))

(defun cmacs-secondbrain-ingest--warn (job fmt &rest args)
  (let ((msg (apply #'format fmt args)))
    (push msg (cmacs-secondbrain-ingest-job-warnings job))
    (cmacs-secondbrain-ingest--log job "warning: %s" msg)))

(defun cmacs-secondbrain-ingest--set-stage (job stage &optional progress)
  (setf (cmacs-secondbrain-ingest-job-stage job) stage
        (cmacs-secondbrain-ingest-job-progress job) (or progress ""))
  (cmacs-secondbrain-ingest--log job "%s%s" stage (if progress (concat ": " progress) ""))
  (cmacs-secondbrain-ingest--render))

(defun cmacs-secondbrain-ingest--opt (job key &optional default)
  "Return option KEY of JOB, or DEFAULT when it is absent."
  (let ((opts (cmacs-secondbrain-ingest-job-options job)))
    (if (plist-member opts key) (plist-get opts key) default)))

;;;; Options -------------------------------------------------------------

(defconst cmacs-secondbrain-ingest--para-aliases
  '(("inbox" . inbox) ("project" . projects) ("projects" . projects)
    ("area" . areas) ("areas" . areas) ("resource" . resources)
    ("resources" . resources) ("archive" . archives) ("archives" . archives)
    ("detect" . detect) ("auto" . detect))
  "What the user may type for a PARA category.")

(defun cmacs-secondbrain-ingest--para-symbol (value)
  "Normalise VALUE to a PARA category symbol, `detect', or nil."
  (cond ((null value) nil)
        ((memq value '(inbox projects areas resources archives detect)) value)
        ((symbolp value) (cmacs-secondbrain-ingest--para-symbol (symbol-name value)))
        ((stringp value)
         (or (cdr (assoc (downcase (string-trim value)) cmacs-secondbrain-ingest--para-aliases))
             (cdr (assoc (string-trim value) cmacs-para-category-symbols))
             (error "unknown PARA category %S" value)))
        (t (error "unknown PARA category %S" value))))

(defun cmacs-secondbrain-ingest--para-dir (category)
  "Return the directory name for CATEGORY symbol."
  (car (cl-find category cmacs-para-category-symbols :key #'cdr)))

(defun cmacs-secondbrain-ingest--split-tags (value)
  "Return VALUE (a list, or a comma/space separated string) as a list of tag slugs."
  (let ((items (cond ((null value) nil)
                     ((stringp value) (split-string value "[,;: ]+" t))
                     ((listp value) (mapcar (lambda (x) (format "%s" x)) value))
                     (t (list (format "%s" value))))))
    (delete-dups
     (delq nil (mapcar (lambda (tg)
                         (let ((s (cmacs-secondbrain-ingest-slug-tag tg)))
                           (and (not (string-empty-p s)) s)))
                       items)))))

(defun cmacs-secondbrain-ingest-normalize-options (opts)
  "Return OPTS (a plist) normalised and validated.

Understood keys: :para :category :directory :scope :root :branch :tags
:type :prompt :principle :no-summary :no-ai :sanitize :provider :model
:name :title :description :format :text :crawl :depth :max-pages :include
:exclude :wait :recursive :append :review :dry-run :keep-source :link
:web-backend :whisper-model :language :callback."
  (let ((out (copy-sequence opts)))
    (when (plist-member out :para)
      (setq out (plist-put out :para (cmacs-secondbrain-ingest--para-symbol (plist-get out :para)))))
    (when (plist-member out :tags)
      (setq out (plist-put out :tags (cmacs-secondbrain-ingest--split-tags (plist-get out :tags)))))
    (when (plist-member out :type)
      (let ((ty (plist-get out :type)))
        (when (stringp ty) (setq ty (intern (downcase (string-trim ty)))))
        (unless (or (null ty) (memq ty (cmacs-secondbrain-ingest-summary-types)))
          (error "unknown summary type %s (one of %s)" ty
                 (mapconcat #'symbol-name (cmacs-secondbrain-ingest-summary-types) ", ")))
        (setq out (plist-put out :type ty))))
    (dolist (k '(:provider :web-backend :keep-source))
      (when (stringp (plist-get out k))
        (setq out (plist-put out k (intern (plist-get out k))))))
    (when (plist-member out :sanitize)
      (let ((v (plist-get out :sanitize)))
        (setq out (plist-put out :sanitize
                             (cond ((stringp v)
                                    (if (member (downcase v) '("t" "true" "yes" "1")) t
                                      (mapcar #'intern (split-string v "[, ]+" t))))
                                   (t v))))))
    (dolist (k '(:depth :max-pages))
      (when (stringp (plist-get out k))
        (setq out (plist-put out k (string-to-number (plist-get out k))))))
    (when (stringp (plist-get out :wait))
      (setq out (plist-put out :wait (string-to-number (plist-get out :wait)))))
    (when (and (plist-get out :branch) (not (plist-get out :root)))
      (setq out (plist-put out :root
                           (expand-file-name (concat "trees/" (plist-get out :branch))
                                             (cmacs-secondbrain-ingest-root)))))
    (when (plist-get out :root)
      (let ((r (expand-file-name (plist-get out :root))))
        (unless (file-directory-p r) (error "root %s does not exist" r))
        (setq out (plist-put out :root r))))
    out))

(defun cmacs-secondbrain-ingest-options-from-json (json)
  "Turn a JSON object string of options (as the D-Bus and MCP surfaces send)
into a normalised plist.  Keys are snake_case strings matching the plist
keywords with underscores for hyphens; unknown keys are ignored."
  (let ((obj (or (cmacs-secondbrain-ingest-json-parse (if (or (null json) (string-blank-p json)) "{}" json))
                 (error "options are not a JSON object")))
        (out nil))
    (maphash (lambda (k v)
               (let ((key (intern (concat ":" (replace-regexp-in-string "_" "-" k)))))
                 (when (memq key '(:para :category :directory :scope :root :branch :tags
                                   :type :prompt :principle :no-summary :no-ai :sanitize
                                   :provider :model :name :title :description :format :text
                                   :crawl :depth :max-pages :include :exclude :wait
                                   :recursive :append :dry-run :keep-source :link
                                   :web-backend :whisper-model :language :id :created))
                   (setq out (plist-put out key v)))))
             obj)
    (cmacs-secondbrain-ingest-normalize-options out)))

;;;; The tree ------------------------------------------------------------

(defun cmacs-secondbrain-ingest-root (&optional job)
  "Return the notes root for JOB, or the configured default, as a directory name."
  (file-name-as-directory
   (expand-file-name
    (or (and job (cmacs-secondbrain-ingest--opt job :root))
        cmacs-secondbrain-ingest-root
        (car cmacs-para-roots)
        "~/Documents/notes"))))

(defun cmacs-secondbrain-ingest--rel (root path)
  "Return PATH relative to ROOT without a trailing slash."
  (string-remove-suffix "/" (file-relative-name (expand-file-name path) root)))

(defun cmacs-secondbrain-ingest--excluded-p (rel)
  "Non-nil when root-relative REL matches an exclusion."
  (let ((probe (concat "/" rel)))
    (cl-some (lambda (re) (or (string-match-p re rel) (string-match-p re probe)))
             cmacs-secondbrain-ingest-placement-exclude)))

(defun cmacs-secondbrain-ingest--subdirs (dir)
  "Visible subdirectories of DIR, sorted."
  (sort (cl-remove-if-not #'file-directory-p
                          (directory-files dir t "\\`[^.]" t))
        #'string<))

(defun cmacs-secondbrain-ingest-tree (&optional root para category files)
  "List the notes tree under ROOT as root-relative paths.

PARA (a category symbol or name) and CATEGORY (a sub path) narrow the
listing; with FILES non-nil `.org' files are listed too.  Hidden entries
and `00_index.org' are skipped.  This is `sbi --list'."
  (let* ((root (file-name-as-directory (expand-file-name (or root (cmacs-secondbrain-ingest-root)))))
         (para (and para (cmacs-secondbrain-ingest--para-symbol para)))
         (start (cond ((and para (not (eq para 'detect)))
                       (expand-file-name
                        (concat (cmacs-secondbrain-ingest--para-dir para)
                                (if (and category (not (string-empty-p category)))
                                    (concat "/" (string-trim category "/+" "/+")) ""))
                        root))
                      (t root)))
         (out nil))
    (unless (file-directory-p start)
      (error "no such directory in the notes tree: %s" (cmacs-secondbrain-ingest--rel root start)))
    (cl-labels ((walk (dir)
                  (dolist (d (cmacs-secondbrain-ingest--subdirs dir))
                    (let ((rel (cmacs-secondbrain-ingest--rel root d)))
                      (unless (string-match-p "\\`trees\\(/\\|\\'\\)" rel)
                        (push (concat rel "/") out)
                        (walk d))))
                  (when files
                    (dolist (f (directory-files dir t "\\.org\\'" t))
                      (unless (equal (file-name-nondirectory f) "00_index.org")
                        (push (cmacs-secondbrain-ingest--rel root f) out))))))
      (walk start))
    (sort out #'string<)))

(defun cmacs-secondbrain-ingest-candidate-dirs (&optional root within)
  "Return the directories the model may file into, as root-relative paths.

Depth-limited by `cmacs-secondbrain-ingest-placement-depth', filtered by
`cmacs-secondbrain-ingest-placement-exclude', never the archive, capped
at `cmacs-secondbrain-ingest-placement-max-dirs' shallowest-first.  WITHIN
restricts the list to one PARA category directory."
  (let* ((root (file-name-as-directory (expand-file-name (or root (cmacs-secondbrain-ingest-root)))))
         (tops (if within (list within)
                 (cl-remove-if (lambda (d) (equal d "04_archives")) cmacs-para-categories)))
         (out nil))
    (cl-labels ((walk (dir depth)
                  (when (< depth cmacs-secondbrain-ingest-placement-depth)
                    (dolist (d (cmacs-secondbrain-ingest--subdirs dir))
                      (let ((rel (cmacs-secondbrain-ingest--rel root d)))
                        (unless (cmacs-secondbrain-ingest--excluded-p rel)
                          (push (cons (1+ depth) rel) out)
                          (walk d (1+ depth))))))))
      (dolist (top tops)
        (let ((dir (expand-file-name top root)))
          (when (file-directory-p dir)
            (push (cons 0 top) out)
            (walk dir 0)))))
    (mapcar #'cdr
            (seq-take (sort (nreverse out)
                            (lambda (a b) (or (< (car a) (car b))
                                              (and (= (car a) (car b)) (string< (cdr a) (cdr b))))))
                      cmacs-secondbrain-ingest-placement-max-dirs))))

(defun cmacs-secondbrain-ingest--note-count (dir)
  (length (directory-files dir nil "\\.org\\'" t)))

(defun cmacs-secondbrain-ingest--tree-for-model (root &optional within)
  "Render the candidate directories for the analysis prompt."
  (mapconcat (lambda (rel)
               (format "%s  (%d notes)" rel
                       (cmacs-secondbrain-ingest--note-count (expand-file-name rel root))))
             (cmacs-secondbrain-ingest-candidate-dirs root within)
             "\n"))

(defun cmacs-secondbrain-ingest-validate-path (root path &optional allow-new allow-archive)
  "Return the absolute directory for root-relative PATH, or nil if it is not
an acceptable place for a note.

Acceptable means: relative, no `..', a PARA category first (not the
archive unless ALLOW-ARCHIVE), not excluded, and existing unless
ALLOW-NEW (in which case an existing parent is enough)."
  (when (and (stringp path) (not (string-blank-p path)))
    (let* ((rel (string-trim (string-trim path) "/+" "/+"))
           (parts (split-string rel "/" t)))
      (when (and parts
                 (not (member ".." parts))
                 (not (string-prefix-p "~" rel))
                 (member (car parts) cmacs-para-categories)
                 (or allow-archive (not (equal (car parts) "04_archives")))
                 ;; The archive is on the exclusion list so the model never
                 ;; files there; an explicit `:directory' into it is the
                 ;; user's call and only that check is waived.
                 (or (and allow-archive (equal (car parts) "04_archives"))
                     (not (cmacs-secondbrain-ingest--excluded-p rel))))
        (let ((abs (expand-file-name rel root)))
          (cond ((file-directory-p abs) (file-name-as-directory abs))
                ((and allow-new
                      (file-directory-p (expand-file-name (car parts) root)))
                 (file-name-as-directory abs))))))))

;;;; Resolving where a job's note goes --------------------------------------

(defun cmacs-secondbrain-ingest--explicit-dir (job)
  "Return the directory JOB's options pin it to, or nil when the model may choose.
Signals when an explicit option names somewhere unacceptable."
  (let* ((root (cmacs-secondbrain-ingest-root job))
         (directory (cmacs-secondbrain-ingest--opt job :directory))
         (para (cmacs-secondbrain-ingest--opt job :para))
         (category (cmacs-secondbrain-ingest--opt job :category))
         (allow-new cmacs-secondbrain-ingest-create-directories))
    (cond
     (directory
      (let ((rel (if (file-name-absolute-p directory)
                     (cmacs-secondbrain-ingest--rel root directory)
                   directory)))
        (or (cmacs-secondbrain-ingest-validate-path root rel allow-new t)
            (error "directory %s is not an acceptable place in %s" directory root))))
     ((and para (not (eq para 'detect)))
      (let* ((pdir (cmacs-secondbrain-ingest--para-dir para))
             (rel (cond
                   ((and category (not (string-empty-p category)))
                    (concat pdir "/" (string-trim category "/+" "/+")))
                   ((and (not (eq para 'inbox)) cmacs-secondbrain-ingest-default-scope
                         (file-directory-p (expand-file-name
                                            (concat pdir "/" cmacs-secondbrain-ingest-default-scope) root)))
                    (concat pdir "/" cmacs-secondbrain-ingest-default-scope))
                   (t pdir))))
        (or (cmacs-secondbrain-ingest-validate-path root rel allow-new t)
            (error "%s is not an acceptable place in %s" rel root))))
     (t nil))))

(defun cmacs-secondbrain-ingest--inbox-dir (job)
  (file-name-as-directory (expand-file-name "00_inbox" (cmacs-secondbrain-ingest-root job))))

(defun cmacs-secondbrain-ingest--placement-wanted-p (job)
  "Non-nil when the model should be asked where JOB's note belongs."
  (and (null (cmacs-secondbrain-ingest--explicit-dir job))
       (or (eq (cmacs-secondbrain-ingest--opt job :para) 'detect)
           (eq cmacs-secondbrain-ingest-placement 'detect))))

(defun cmacs-secondbrain-ingest--resolve-target-dir (job)
  "Decide JOB's target directory from its options and analysis."
  (or (cmacs-secondbrain-ingest--explicit-dir job)
      (let* ((root (cmacs-secondbrain-ingest-root job))
             (a (cmacs-secondbrain-ingest-job-analysis job))
             (path (plist-get a :path))
             (conf (or (plist-get a :confidence) 0.0))
             (within (let ((p (cmacs-secondbrain-ingest--opt job :para)))
                       (and p (not (eq p 'detect)) (cmacs-secondbrain-ingest--para-dir p))))
             (valid (and path (cmacs-secondbrain-ingest-validate-path root path nil nil))))
        (cond
         ((and valid (>= conf cmacs-secondbrain-ingest-placement-min-confidence)
               (or (null within) (string-prefix-p within (cmacs-secondbrain-ingest--rel root valid))))
          (cmacs-secondbrain-ingest--log job "placed by model: %s (%.2f) %s"
                                         (cmacs-secondbrain-ingest--rel root valid) conf
                                         (or (plist-get a :reason) ""))
          valid)
         (t
          (when path
            (cmacs-secondbrain-ingest--warn
             job "model proposed %s%s; filed to the inbox instead"
             path (cond ((not valid) " (not an existing directory)")
                        ((< conf cmacs-secondbrain-ingest-placement-min-confidence)
                         (format " (confidence %.2f)" conf))
                        (t " (outside the chosen category)"))))
          (cmacs-secondbrain-ingest--inbox-dir job))))))

;;;; Naming -----------------------------------------------------------------

(defun cmacs-secondbrain-ingest--title (job)
  "Return the best title for JOB's note."
  (let ((doc (cmacs-secondbrain-ingest-job-doc job)))
    (or (cmacs-secondbrain-ingest--opt job :title)
        (plist-get (cmacs-secondbrain-ingest-job-analysis job) :title)
        (let ((tt (plist-get doc :title))) (and tt (not (string-blank-p tt)) (string-trim tt)))
        (let ((in (cmacs-secondbrain-ingest-job-input job)))
          (cond ((cmacs-secondbrain-ingest-url-p in)
                 (replace-regexp-in-string "_" " " (cmacs-secondbrain-ingest-filename-from-url in)))
                ((and (stringp in) (file-exists-p in))
                 (replace-regexp-in-string "[_-]+" " " (file-name-base in)))
                (t (format "Ingested %s" (format-time-string "%F %R"))))))))

(defun cmacs-secondbrain-ingest--filename (job dir title)
  "Return the file JOB's note should be written to under DIR."
  (let* ((seed (or (cmacs-secondbrain-ingest--opt job :name) title))
         (slug (cmacs-secondbrain-ingest-slugify seed cmacs-secondbrain-ingest-slug-max-length))
         (base (if (eq cmacs-secondbrain-ingest-filename-style 'date-slug)
                   (concat (format-time-string "%F") "_" slug)
                 slug))
         (file (expand-file-name (concat base ".org") dir))
         (mode (if (cmacs-secondbrain-ingest--opt job :append) 'append
                 cmacs-secondbrain-ingest-on-collision)))
    (cond
     ((not (file-exists-p file)) file)
     ((eq mode 'append) (setf (cmacs-secondbrain-ingest-job-appended job) t) file)
     ((eq mode 'overwrite) file)
     ((eq mode 'error) (error "%s already exists" file))
     (t (let ((n 2))
          (while (file-exists-p (expand-file-name (format "%s_%d.org" base n) dir))
            (cl-incf n))
          (expand-file-name (format "%s_%d.org" base n) dir))))))

;;;; Rendering the note -------------------------------------------------

(defun cmacs-secondbrain-ingest--timestamp ()
  (format-time-string "%FT%T%z"))

(defun cmacs-secondbrain-ingest--categories (job dir)
  "Return the `#+categories:' value: the PARA path words and the kind."
  (let* ((root (cmacs-secondbrain-ingest-root job))
         (rel (cmacs-secondbrain-ingest--rel root dir))
         (parts (cdr (split-string rel "/" t)))
         (cat (cdr (assoc (car (split-string rel "/" t)) cmacs-para-category-symbols))))
    (string-join (delete-dups
                  (delq nil (append (list (and cat (symbol-name cat)))
                                    parts
                                    (list (symbol-name (cmacs-secondbrain-ingest-job-kind job))))))
                 ", ")))

(defun cmacs-secondbrain-ingest--tags (job)
  "Return the merged tag list for JOB."
  (let ((doc (cmacs-secondbrain-ingest-job-doc job)))
    (delete-dups
     (append (cmacs-secondbrain-ingest--opt job :tags)
             (and cmacs-secondbrain-ingest-suggest-tags
                  (plist-get (cmacs-secondbrain-ingest-job-analysis job) :tags))
             (and (plist-get doc :filetags)
                  (cmacs-secondbrain-ingest--split-tags (plist-get doc :filetags)))))))

(defun cmacs-secondbrain-ingest--org-link (target &optional label)
  "Return an Org link to TARGET (a URL or file) with LABEL."
  (let ((dest (if (cmacs-secondbrain-ingest-url-p target) target (concat "file:" target))))
    (if label (format "[[%s][%s]]" dest label) (format "[[%s]]" dest))))

(defun cmacs-secondbrain-ingest--metadata-lines (job)
  "Return the `* Metadata' list lines for JOB."
  (let* ((doc (cmacs-secondbrain-ingest-job-doc job))
         (in (cmacs-secondbrain-ingest-job-input job))
         (source (or (plist-get doc :source) in))
         (lines nil))
    (cl-flet ((add (label value)
                (when (and value (not (equal value "")))
                  (push (format "- %s :: %s" label value) lines))))
      (add "Source" (cond ((cmacs-secondbrain-ingest-url-p source) source)
                          ((and (stringp source) (file-name-absolute-p source))
                           (cmacs-secondbrain-ingest--org-link source (abbreviate-file-name source)))
                          (t source)))
      (add "Kind" (symbol-name (cmacs-secondbrain-ingest-job-kind job)))
      (add "Ingested" (cmacs-secondbrain-ingest--timestamp))
      (add "Extractor" (and (plist-get doc :extractor) (format "%s" (plist-get doc :extractor))))
      (when (cmacs-secondbrain-ingest-job-summary job)
        (add "Model" (format "%s/%s"
                             (or (cmacs-secondbrain-ingest--opt job :provider)
                                 cmacs-secondbrain-ingest-provider "default")
                             (or (cmacs-secondbrain-ingest--opt job :model)
                                 cmacs-secondbrain-ingest-model "default")))
        (add "Summary type" (and (cmacs-secondbrain-ingest-job-summary-type job)
                                 (symbol-name (cmacs-secondbrain-ingest-job-summary-type job)))))
      (dolist (kv (plist-get doc :meta))
        (unless (or (member (car kv) '("id" "title" "description" "tags" "chapters"))
                    (and (equal (car kv) "URL") (equal (cdr kv) source)))
          (add (car kv) (if (cmacs-secondbrain-ingest-url-p (format "%s" (cdr kv)))
                            (format "%s" (cdr kv))
                          (format "%s" (cdr kv))))))
      (let ((a (cmacs-secondbrain-ingest-job-analysis job)))
        (when (plist-get a :reason)
          (add "Placement" (format "%s (%.2f)" (or (plist-get a :path) "inbox")
                                   (or (plist-get a :confidence) 0.0)))))
      (when (cmacs-secondbrain-ingest--opt job :sanitize (and cmacs-secondbrain-ingest-sanitize t))
        (add "Redactions" (format "%d" (or (plist-get doc :redactions) 0))))
      (when (cmacs-secondbrain-ingest-job-warnings job)
        (add "Warnings" (string-join (reverse (cmacs-secondbrain-ingest-job-warnings job)) "; "))))
    (nreverse lines)))

(defun cmacs-secondbrain-ingest--content-heading (job)
  (pcase (cmacs-secondbrain-ingest-job-kind job)
    ((or 'audio 'video 'youtube) "Transcript")
    ('email "Message")
    ('data "Data")
    (_ "Content")))

(defun cmacs-secondbrain-ingest--body (job)
  "Return the content body for JOB's note, demoted under its heading and capped."
  (let* ((doc (cmacs-secondbrain-ingest-job-doc job))
         (body (or (plist-get doc :body) "")))
    (when (> (length body) cmacs-secondbrain-ingest-max-content-chars)
      (setq body (concat (substring body 0 cmacs-secondbrain-ingest-max-content-chars)
                         (format "\n\n[content cut at %d characters]"
                                 cmacs-secondbrain-ingest-max-content-chars))))
    (cmacs-secondbrain-ingest-demote body 1)))

(defun cmacs-secondbrain-ingest--extra-sections (job)
  "Return kind-specific sections (description, chapters) as one string, or nil."
  (let* ((doc (cmacs-secondbrain-ingest-job-doc job))
         (meta (plist-get doc :meta))
         (desc (cdr (assoc "description" meta)))
         (chapters (cdr (assoc "chapters" meta)))
         (parts nil))
    (when (and (stringp desc) (not (string-blank-p desc)))
      (push (concat "* Description\n#+begin_quote\n" (string-trim desc) "\n#+end_quote") parts))
    (when (and (listp chapters) chapters)
      (push (concat "* Chapters\n"
                    (mapconcat (lambda (c)
                                 (format "- [%s] %s"
                                         (cmacs-secondbrain-ingest-ms->clock
                                          (round (* 1000 (or (car c) 0))))
                                         (or (cdr c) "")))
                               chapters "\n"))
            parts))
    (and parts (string-join (nreverse parts) "\n\n"))))

(defun cmacs-secondbrain-ingest--header (id title description categories tags &optional created)
  "Return the file header: property drawer and the standard keywords.
CREATED, when given, is the ISO 8601 timestamp for `#+created:' -- a
migrated note keeps the date it was really written."
  (let ((now (cmacs-secondbrain-ingest--timestamp)))
    (concat
     ":PROPERTIES:\n:ID:       " id "\n:END:\n"
     "#+title: " title "\n"
     "#+description: " (or description "") "\n"
     "#+authors: " cmacs-secondbrain-ingest-author "\n"
     "#+categories: " (or categories "") "\n"
     (if tags (concat "#+filetags: :" (string-join tags ":") ":\n") "")
     "#+created: " (or created now) "\n"
     "#+updated: " now "\n"
     "#+version: 1.0.0\n")))

(defun cmacs-secondbrain-ingest--see-also (related)
  "Return the `* See also' section for RELATED, or nil."
  (when related
    (concat "* See also\n"
            (mapconcat (lambda (r)
                         (format "- [[id:%s][%s]]" (nth 0 r) (nth 1 r)))
                       related "\n"))))

(defun cmacs-secondbrain-ingest-render-note (job)
  "Return the full Org text of JOB's note."
  (let* ((title (cmacs-secondbrain-ingest-job-title job))
         (dir (cmacs-secondbrain-ingest-job-target-dir job))
         (summary (cmacs-secondbrain-ingest-job-summary job))
         (sections
          (delq nil
                (list (and summary (not (string-blank-p summary))
                           (concat "* Summary\n" (string-trim summary)))
                      (concat "* Metadata\n"
                              (string-join (cmacs-secondbrain-ingest--metadata-lines job) "\n"))
                      (cmacs-secondbrain-ingest--extra-sections job)
                      (and cmacs-secondbrain-ingest-include-content
                           (not (string-blank-p (or (plist-get (cmacs-secondbrain-ingest-job-doc job) :body) "")))
                           (concat "* " (cmacs-secondbrain-ingest--content-heading job) "\n"
                                   (cmacs-secondbrain-ingest--body job)))
                      (cmacs-secondbrain-ingest--see-also (cmacs-secondbrain-ingest-job-related job))))))
    (concat (cmacs-secondbrain-ingest--header
             (cmacs-secondbrain-ingest-job-note-id job) title
             (cmacs-secondbrain-ingest-job-description job)
             (cmacs-secondbrain-ingest--categories job dir)
             (cmacs-secondbrain-ingest-job-tags job)
             (cmacs-secondbrain-ingest--opt job :created))
            "\n"
            (string-join sections "\n\n")
            "\n")))

(defun cmacs-secondbrain-ingest-render-append (job)
  "Return the section appended to an existing note for JOB."
  (let ((summary (cmacs-secondbrain-ingest-job-summary job)))
    (concat "\n* Ingested " (format-time-string "%F %R") "\n"
            (cmacs-secondbrain-ingest-demote
             (string-join
              (delq nil
                    (list (and summary (concat "* Summary\n" (string-trim summary)))
                          (concat "* Metadata\n"
                                  (string-join (cmacs-secondbrain-ingest--metadata-lines job) "\n"))
                          (and cmacs-secondbrain-ingest-include-content
                               (concat "* " (cmacs-secondbrain-ingest--content-heading job) "\n"
                                       (cmacs-secondbrain-ingest--body job)))
                          (cmacs-secondbrain-ingest--see-also (cmacs-secondbrain-ingest-job-related job))))
              "\n\n")
             1)
            "\n")))

;;;; org-roam: ids, indices, related notes ---------------------------------

(defun cmacs-secondbrain-ingest-file-id (file)
  "Return the `:ID:' of the top property drawer in FILE, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 2000)
      (goto-char (point-min))
      (when (re-search-forward "^[ \t]*:ID:[ \t]+\\([^ \t\n]+\\)" nil t)
        (match-string 1)))))

(defun cmacs-secondbrain-ingest-file-title (file)
  "Return the `#+title:' of FILE, or its base name."
  (or (and (file-readable-p file)
           (with-temp-buffer
             (insert-file-contents file nil 0 4000)
             (goto-char (point-min))
             (when (re-search-forward "^#\\+[Tt][Ii][Tt][Ll][Ee]:[ \t]*\\(.+\\)$" nil t)
               (string-trim (match-string 1)))))
      (replace-regexp-in-string "[_-]+" " " (file-name-base file))))

(defun cmacs-secondbrain-ingest--dir-title (dir)
  "A human title for DIR's index: \"linux\" -> \"Linux Index\"."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (concat (capitalize (replace-regexp-in-string "^[0-9]+_" "" (replace-regexp-in-string "_" " " name)))
            " Index")))

(defun cmacs-secondbrain-ingest-ensure-index (dir root)
  "Return DIR's `00_index.org', creating it (and linking it from the parent
index, recursively up to ROOT) when it does not exist."
  (let ((index (expand-file-name "00_index.org" dir)))
    (unless (file-exists-p index)
      (let ((id (org-id-new))
            (title (cmacs-secondbrain-ingest--dir-title dir)))
        (make-directory dir t)
        (with-temp-file index
          (insert (cmacs-secondbrain-ingest--header
                   id title (format "Index of %s" (cmacs-secondbrain-ingest--rel root dir))
                   "index" nil)
                  "\n* Contents\n"))
        (let ((parent (file-name-directory (directory-file-name dir))))
          (when (and (file-in-directory-p parent root)
                     (not (equal (file-truename parent) (file-truename (directory-file-name dir)))))
            (cmacs-secondbrain-ingest-register-in-index parent id title root)))))
    index))

(defun cmacs-secondbrain-ingest-register-in-index (dir id title root)
  "Add a bullet linking ID as TITLE to DIR's `00_index.org'.

The bullet goes at the end of the first `[[id:' list under a `Contents'
heading when there is one, else after the last such bullet in the file,
else at the end.  A link to ID already present is left alone.  Returns
the index path, or nil when DIR has no index and one could not be made."
  (let ((index (cmacs-secondbrain-ingest-ensure-index dir root))
        (bullet (format "- [[id:%s][%s]]" id (replace-regexp-in-string "[][]" "" title))))
    (with-temp-buffer
      (insert-file-contents index)
      (goto-char (point-min))
      (unless (search-forward (format "[[id:%s]" id) nil t)
        (goto-char (point-min))
        (cond
         ;; Under a Contents heading: after the last bullet of its list.
         ((re-search-forward "^\\*+ Contents[ \t]*$" nil t)
          (let ((section-end (save-excursion
                               (or (and (re-search-forward "^\\* " nil t) (match-beginning 0))
                                   (point-max)))))
            (forward-line 1)
            (let ((last nil))
              (while (and (< (point) section-end) (re-search-forward "^- \\[\\[id:" section-end t))
                (setq last (line-end-position)))
              (if last (progn (goto-char last) (insert "\n" bullet))
                (goto-char section-end)
                (skip-chars-backward " \t\n")
                (insert "\n" bullet)))))
         ;; Anywhere: after the last id bullet.
         ((progn (goto-char (point-max))
                 (re-search-backward "^- \\[\\[id:" nil t))
          (end-of-line) (insert "\n" bullet))
         (t (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert "\n" bullet "\n")))
        ;; Touch #+updated: so the index says when it last changed.
        (goto-char (point-min))
        (when (re-search-forward "^#\\+updated:.*$" nil t)
          (replace-match (concat "#+updated: " (cmacs-secondbrain-ingest--timestamp))))
        (write-region (point-min) (point-max) index nil 'silent)))
    index))

(defun cmacs-secondbrain-ingest--memory-index-p ()
  "Non-nil when the brigade memory index exists and can be searched."
  (and (or (featurep 'cmacs-brigade-memory) (require 'cmacs-brigade-memory nil t))
       (fboundp 'cmacs-brigade-memory-search)
       (boundp 'cmacs-brigade-memory-index-dir)
       (file-directory-p cmacs-brigade-memory-index-dir)
       (directory-files cmacs-brigade-memory-index-dir nil "\\`[^.]" t)))

(defun cmacs-secondbrain-ingest-related-notes (text &optional k exclude root)
  "Return up to K notes related to TEXT as (ID TITLE PATH SCORE), best first.

Uses the brigade memory index (semantic + lexical fusion) and keeps only
hits that are org-roam nodes under ROOT: a hit without an `:ID:' cannot
be linked, and a hit in another tree would be a link into a different
graph.  EXCLUDE is a list of paths to leave out (the note itself, indices)."
  (when (and (stringp text) (not (string-blank-p text))
             (cmacs-secondbrain-ingest--memory-index-p))
    (let* ((k (or k cmacs-secondbrain-ingest-related-count))
           (root (and root (file-name-as-directory (expand-file-name root))))
           (query (cmacs-secondbrain-ingest-sample text 4000))
           (hits (cmacs-brigade-memory-search query (* k 3)))
           (seen (make-hash-table :test 'equal))
           (out nil))
      (dolist (h hits)
        (let ((path (plist-get h :path))
              (score (or (plist-get h :score) 0.0)))
          (when (and path (< (length out) k)
                     (not (gethash path seen))
                     (or (null root) (string-prefix-p root (expand-file-name path)))
                     (not (member path exclude))
                     (not (equal (file-name-nondirectory path) "00_index.org"))
                     (>= score cmacs-secondbrain-ingest-related-min-score))
            (puthash path t seen)
            (let ((id (cmacs-secondbrain-ingest-file-id path)))
              (when id
                (push (list id (cmacs-secondbrain-ingest-file-title path) path score) out))))))
      (nreverse out))))

(defun cmacs-secondbrain-ingest--roam-update (file)
  "Tell org-roam about FILE when it is loaded."
  (when (and cmacs-secondbrain-ingest-update-roam-db
             (fboundp 'org-roam-db-update-file))
    (ignore-errors (org-roam-db-update-file (expand-file-name file)))))

;;;; Text input: stdin, region, clipboard -------------------------------------

(defun cmacs-secondbrain-ingest-text->doc (text &optional format source)
  "Build a document from literal TEXT in FORMAT (a kind or extension)."
  (let* ((kind (plist-get (cmacs-secondbrain-ingest-classify "stdin" (or format 'text)) :kind))
         (text (or text "")))
    (pcase kind
      ('org
       (let* ((parsed (cmacs-secondbrain-ingest-strip-org-header text))
              (kws (car parsed)) (body (cdr parsed)))
         (list :kind 'org :source (or source "text") :title (cdr (assoc "title" kws))
               :description (cdr (assoc "description" kws))
               :filetags (cdr (assoc "filetags" kws))
               :body body :text (cmacs-secondbrain-ingest-org-text body) :extractor 'text)))
      ('markdown
       (list :kind 'markdown :source (or source "text")
             :title (cmacs-secondbrain-ingest--md-title text)
             :body (if (cmacs-secondbrain-ingest-tool-p 'pandoc)
                       (condition-case nil (cmacs-secondbrain-ingest-pandoc "gfm" nil text)
                         (error (cmacs-secondbrain-ingest-markdown->org text)))
                     (cmacs-secondbrain-ingest-markdown->org text))
             :text text :extractor 'text))
      ('data
       (list :kind 'data :source (or source "text")
             :body (cmacs-secondbrain-ingest-data->org text (if (stringp format) format "json"))
             :text (cmacs-secondbrain-ingest-sample-lines text 400) :extractor 'text))
      ('html (let ((d (cmacs-secondbrain-ingest-html->doc text nil (or source "text"))))
               (plist-put d :kind 'html) d))
      (_
       (list :kind 'text :source (or source "text")
             :body (if (cmacs-secondbrain-ingest-looks-like-prose-p text)
                       (cmacs-secondbrain-ingest-paragraphs->org text)
                     (cmacs-secondbrain-ingest-src-block "text" text))
             :text text :extractor 'text)))))

(defun cmacs-secondbrain-ingest-guess-text-format (text)
  "Guess whether TEXT is org, markdown, json, html or plain text."
  (let ((head (string-trim-left (substring text 0 (min 2000 (length text))))))
    (cond ((string-match-p "\\`\\(?:#\\+[a-zA-Z_]+:\\|:PROPERTIES:\\|\\*+ \\)" head) 'org)
          ((string-match-p "\\`\\(?:<!DOCTYPE html\\|<html\\)" head) 'html)
          ((string-match-p "\\`[{[]" head) 'data)
          ((string-match-p "\\(?:\\`\\|\n\\)\\(?:#\\{1,6\\} \\|```\\|- \\[[ x]\\] \\)\\|\\*\\*[^*]+\\*\\*\\|\\[[^]]+\\]([^)]+)" head) 'markdown)
          (t 'text))))

;;;; The pipeline -------------------------------------------------------------

(defun cmacs-secondbrain-ingest--fail (job fmt &rest args)
  "Mark JOB failed with a message and finish it."
  (let ((msg (apply #'format fmt args)))
    (setf (cmacs-secondbrain-ingest-job-error job) msg)
    (cmacs-secondbrain-ingest--log job "FAILED: %s" msg)
    (cmacs-secondbrain-ingest--finish job 'failed)))

(defun cmacs-secondbrain-ingest--finish (job stage)
  "Move JOB to terminal STAGE, clean up, notify, and schedule the next job."
  (setf (cmacs-secondbrain-ingest-job-stage job) stage
        (cmacs-secondbrain-ingest-job-finished job) (current-time)
        (cmacs-secondbrain-ingest-job-process job) nil
        (cmacs-secondbrain-ingest-job-cancel-fn job) nil)
  (when (and (cmacs-secondbrain-ingest-job-tmpdir job)
             (file-directory-p (cmacs-secondbrain-ingest-job-tmpdir job)))
    (ignore-errors (delete-directory (cmacs-secondbrain-ingest-job-tmpdir job) t)))
  (cmacs-secondbrain-ingest--log job "%s%s" stage
                                 (if (cmacs-secondbrain-ingest-job-note-file job)
                                     (concat " -> " (abbreviate-file-name
                                                     (cmacs-secondbrain-ingest-job-note-file job)))
                                   ""))
  (unless cmacs-secondbrain-ingest-verbose
    (message "sb ingest: %s %s%s" (cmacs-secondbrain-ingest-job-id job) stage
             (pcase stage
               ('done (concat " -> " (abbreviate-file-name (cmacs-secondbrain-ingest-job-note-file job))))
               ('failed (concat ": " (or (cmacs-secondbrain-ingest-job-error job) "")))
               (_ ""))))
  (dolist (cb (cmacs-secondbrain-ingest-job-callbacks job))
    (ignore-errors (funcall cb job)))
  (ignore-errors (run-hook-with-args 'cmacs-secondbrain-ingest-after-job-functions job))
  (cmacs-secondbrain-ingest--render)
  (cmacs-secondbrain-ingest--schedule))

(defmacro cmacs-secondbrain-ingest--guard (job &rest body)
  "Run BODY; a Lisp error fails JOB instead of escaping into the main loop."
  (declare (indent 1))
  `(condition-case err
       (progn ,@body)
     (error (cmacs-secondbrain-ingest--fail ,job "%s" (error-message-string err)))))

(defun cmacs-secondbrain-ingest--advance (job stage)
  "Run STAGE of JOB, unless it was cancelled meanwhile."
  (unless (cmacs-secondbrain-ingest-job-cancelled job)
    (cmacs-secondbrain-ingest--set-stage job stage)
    (cmacs-secondbrain-ingest--guard job
      (pcase stage
        ('acquiring (cmacs-secondbrain-ingest--stage-acquire job))
        ('extracting (cmacs-secondbrain-ingest--stage-extract job))
        ('analysing (cmacs-secondbrain-ingest--stage-analyse job))
        ('summarising (cmacs-secondbrain-ingest--stage-summarise job))
        ('linking (cmacs-secondbrain-ingest--stage-link job))
        ('reviewing (cmacs-secondbrain-ingest--stage-review job))
        ('writing (cmacs-secondbrain-ingest--stage-write job))
        (_ (error "unknown stage %s" stage))))))

(defun cmacs-secondbrain-ingest--tmpdir (job)
  (or (cmacs-secondbrain-ingest-job-tmpdir job)
      (setf (cmacs-secondbrain-ingest-job-tmpdir job)
            (make-temp-file "cmacs-sbi-" t))))

(defun cmacs-secondbrain-ingest--run-process (job name argv callback)
  "Run ARGV for JOB; CALLBACK gets (EXIT-CODE OUTPUT-STRING) when it ends."
  (let ((buf (generate-new-buffer (format " *sbi %s %s*" (cmacs-secondbrain-ingest-job-id job) name))))
    (cmacs-secondbrain-ingest--log job "$ %s" (mapconcat #'shell-quote-argument argv " "))
    (let ((proc (make-process
                 :name (format "sbi-%s-%s" (cmacs-secondbrain-ingest-job-id job) name)
                 :buffer buf :command argv :noquery t
                 :stderr buf
                 :sentinel
                 (lambda (p _event)
                   (unless (process-live-p p)
                     (let ((code (process-exit-status p))
                           (out (and (buffer-live-p buf)
                                     (with-current-buffer buf (buffer-string)))))
                       (when (buffer-live-p buf) (kill-buffer buf))
                       (when (eq (cmacs-secondbrain-ingest-job-process job) p)
                         (setf (cmacs-secondbrain-ingest-job-process job) nil))
                       (unless (cmacs-secondbrain-ingest-job-cancelled job)
                         (cmacs-secondbrain-ingest--guard job
                           (funcall callback code (or out ""))))))))))
      (setf (cmacs-secondbrain-ingest-job-process job) proc)
      proc)))

;;;;; Acquire

(defun cmacs-secondbrain-ingest--stage-acquire (job)
  "Fetch what JOB needs from the network or from media, then extract."
  (let ((kind (cmacs-secondbrain-ingest-job-kind job))
        (in (cmacs-secondbrain-ingest-job-input job)))
    (cond
     ((cmacs-secondbrain-ingest--opt job :text)
      (cmacs-secondbrain-ingest--advance job 'extracting))
     ((eq kind 'youtube) (cmacs-secondbrain-ingest--youtube-start job in))
     ((and (eq kind 'url) (cmacs-secondbrain-ingest--opt job :crawl))
      (cmacs-secondbrain-ingest--crawl-start job in))
     ((eq kind 'url) (cmacs-secondbrain-ingest--web-fetch job in
                                                          (lambda (doc) (cmacs-secondbrain-ingest--got-doc job doc))))
     ((memq kind '(audio video)) (cmacs-secondbrain-ingest--media-start job in))
     ((eq kind 'archive) (cmacs-secondbrain-ingest--site-export-start job in))
     (t (cmacs-secondbrain-ingest--advance job 'extracting)))))

(defun cmacs-secondbrain-ingest--got-doc (job doc)
  "Store DOC as JOB's document and move on to analysis."
  (setf (cmacs-secondbrain-ingest-job-doc job) doc)
  (dolist (w (plist-get doc :warnings)) (cmacs-secondbrain-ingest--warn job "%s" w))
  (cmacs-secondbrain-ingest--advance job 'analysing))

(defun cmacs-secondbrain-ingest--web-fetch (job url on-doc)
  "Fetch URL for JOB and call ON-DOC with the document."
  (let ((backend (cmacs-secondbrain-ingest--opt job :web-backend cmacs-secondbrain-ingest-web-backend)))
    (if (and (eq backend 'gsurf)
             (fboundp 'cmacs-gsurf-supported-p) (ignore-errors (cmacs-gsurf-supported-p)))
        (cmacs-secondbrain-ingest--gsurf-fetch job url on-doc)
      (when (eq backend 'gsurf)
        (cmacs-secondbrain-ingest--warn job "gsurf backend requested but not built; using url.el"))
      (setf (cmacs-secondbrain-ingest-job-progress job) (format "fetching %s" url))
      (cmacs-secondbrain-ingest--render)
      (setf (cmacs-secondbrain-ingest-job-cancel-fn job)
            (cmacs-secondbrain-ingest-fetch-url
             url
             (lambda (res)
               (unless (cmacs-secondbrain-ingest-job-cancelled job)
                 (cmacs-secondbrain-ingest--guard job
                   (unless (plist-get res :ok)
                     (error "%s: %s" url (plist-get res :error)))
                   (when (>= (plist-get res :status) 400)
                     (error "%s: HTTP %s" url (plist-get res :status)))
                   (funcall on-doc (cmacs-secondbrain-ingest--response->doc
                                    job url res))))))))))

(defun cmacs-secondbrain-ingest--response->doc (job url res)
  "Turn a fetch RES for URL into a document, by content type."
  (let* ((ctype (or (plist-get res :content-type) ""))
         (body (plist-get res :body))
         (final (or (plist-get res :url) url)))
    (cond
     ((string-match-p "\\`\\(?:text/html\\|application/xhtml\\)" ctype)
      (cmacs-secondbrain-ingest-html->doc body final url))
     ((string-match-p "\\`application/pdf" ctype)
      (let ((file (expand-file-name (concat (cmacs-secondbrain-ingest-filename-from-url url) ".pdf")
                                    (cmacs-secondbrain-ingest--tmpdir job))))
        (with-temp-file file (set-buffer-multibyte nil) (insert body))
        (let ((d (cmacs-secondbrain-ingest-extract-file file 'pdf)))
          (setf (cmacs-secondbrain-ingest-job-kind job) 'pdf)
          (plist-put d :source url)
          (plist-put d :meta (cons (cons "URL" url) (plist-get d :meta)))
          d)))
     ((string-match-p "\\`\\(?:application/json\\|text/csv\\|application/xml\\|text/xml\\|application/x-yaml\\|text/yaml\\)" ctype)
      (let ((ext (cond ((string-match-p "json" ctype) "json")
                       ((string-match-p "csv" ctype) "csv")
                       ((string-match-p "yaml" ctype) "yaml")
                       (t "xml"))))
        (setf (cmacs-secondbrain-ingest-job-kind job) 'data)
        (list :kind 'data :source url :body (cmacs-secondbrain-ingest-data->org body ext)
              :text (cmacs-secondbrain-ingest-sample-lines body 400)
              :meta (list (cons "URL" url) (cons "Content-Type" ctype)) :extractor 'url)))
     ((string-match-p "\\`text/" ctype)
      (let ((fmt (cmacs-secondbrain-ingest-guess-text-format body)))
        (let ((d (cmacs-secondbrain-ingest-text->doc body fmt url)))
          (plist-put d :meta (list (cons "URL" url)))
          d)))
     (t (error "unsupported content type %s at %s" ctype url)))))

(defun cmacs-secondbrain-ingest--gsurf-fetch (job url on-doc)
  "Render URL in an offscreen gsurf view and read its DOM back."
  (require 'cmacs-gsurf)
  (let* ((buf (generate-new-buffer (format " *sbi gsurf %s*" (cmacs-secondbrain-ingest-job-id job))))
         (done nil) (hook nil) (timer nil)
         (cleanup (lambda ()
                    (when hook (remove-hook 'cmacs-gsurf-load-changed-functions hook))
                    (when (timerp timer) (cancel-timer timer))
                    (when (buffer-live-p buf)
                      (ignore-errors (cmacs-gsurf-detach buf))
                      (kill-buffer buf))))
         (finish (lambda (thunk)
                   (unless done
                     (setq done t)
                     (funcall cleanup)
                     (unless (cmacs-secondbrain-ingest-job-cancelled job)
                       (cmacs-secondbrain-ingest--guard job (funcall thunk)))))))
    (setq hook (lambda (b event)
                 (when (and (eq b buf) (eq event 'finished) (not done))
                   (run-at-time cmacs-secondbrain-ingest-gsurf-settle nil
                                (lambda ()
                                  (when (and (buffer-live-p buf) (not done))
                                    (cmacs-gsurf-run-javascript-async
                                     buf "document.documentElement.outerHTML"
                                     (lambda (html)
                                       (let ((final (or (ignore-errors (cmacs-gsurf-get-uri buf)) url)))
                                         (funcall finish
                                                  (lambda ()
                                                    (funcall on-doc (cmacs-secondbrain-ingest-html->doc
                                                                     html final url)))))))))))))
    (add-hook 'cmacs-gsurf-load-changed-functions hook)
    (setq timer (run-at-time cmacs-secondbrain-ingest-fetch-timeout nil
                             (lambda () (funcall finish (lambda () (error "gsurf: %s timed out" url))))))
    (setf (cmacs-secondbrain-ingest-job-cancel-fn job) (lambda () (funcall finish (lambda () nil))))
    (cmacs-gsurf-attach buf t)
    (cmacs-gsurf-load-uri buf url)))

;;;;; YouTube

(defun cmacs-secondbrain-ingest--youtube-start (job url)
  (unless (cmacs-secondbrain-ingest-tool-p 'yt-dlp)
    (error "yt-dlp is not installed (Fedora package: yt-dlp)"))
  (setf (cmacs-secondbrain-ingest-job-progress job) "reading video metadata")
  (cmacs-secondbrain-ingest--render)
  (cmacs-secondbrain-ingest--run-process
   job "yt-dlp-meta" (cmacs-secondbrain-ingest-ytdlp-metadata-command url)
   (lambda (code out)
     (let ((meta (and (eq code 0) (cmacs-secondbrain-ingest-ytdlp-meta->alist out))))
       (unless meta
         (error "yt-dlp could not read %s: %s" url (string-trim (cmacs-secondbrain-ingest-sample out 400))))
       (let ((strategy (cmacs-secondbrain-ingest--opt job :youtube-strategy
                                                       cmacs-secondbrain-ingest-youtube-strategy)))
         (if (eq strategy 'audio)
             (cmacs-secondbrain-ingest--youtube-audio job url meta)
           (cmacs-secondbrain-ingest--youtube-subs job url meta)))))))

(defun cmacs-secondbrain-ingest--youtube-subs (job url meta)
  (let ((dir (cmacs-secondbrain-ingest--tmpdir job)))
    (setf (cmacs-secondbrain-ingest-job-progress job) "fetching captions")
    (cmacs-secondbrain-ingest--render)
    (cmacs-secondbrain-ingest--run-process
     job "yt-dlp-subs" (cmacs-secondbrain-ingest-ytdlp-subtitles-command url dir)
     (lambda (_code _out)
       (let* ((files (directory-files dir t "\\.\\(?:vtt\\|srt\\)\\'"))
              ;; Prefer an exact `en' over a regional variant.
              (best (or (cl-find-if (lambda (f) (string-match-p "\\.en\\.\\(?:vtt\\|srt\\)\\'" f)) files)
                        (car files)))
              (segments (and best (cmacs-secondbrain-ingest-parse-vtt
                                   (cmacs-secondbrain-ingest--read-file best)))))
         (cond
          (segments
           (cmacs-secondbrain-ingest--got-doc
            job (cmacs-secondbrain-ingest--transcript-doc job url meta segments
                                                          (if (string-match-p "\\.srt\\'" best) 'yt-dlp-srt 'yt-dlp-captions))))
          ((eq (cmacs-secondbrain-ingest--opt job :youtube-strategy cmacs-secondbrain-ingest-youtube-strategy)
               'subtitles)
           (error "%s has no captions and audio transcription is disabled" url))
          (t
           (cmacs-secondbrain-ingest--log job "no captions; falling back to audio + whisper")
           (cmacs-secondbrain-ingest--youtube-audio job url meta))))))))

(defun cmacs-secondbrain-ingest--youtube-audio (job url meta)
  (cmacs-secondbrain-ingest--require-whisper)
  (let ((dir (cmacs-secondbrain-ingest--tmpdir job)))
    (setf (cmacs-secondbrain-ingest-job-progress job) "downloading audio")
    (cmacs-secondbrain-ingest--render)
    (cmacs-secondbrain-ingest--run-process
     job "yt-dlp-audio" (cmacs-secondbrain-ingest-ytdlp-audio-command url dir)
     (lambda (code out)
       (let ((file (car (cl-remove-if (lambda (f) (string-match-p "\\.\\(?:vtt\\|srt\\|json\\|part\\)\\'" f))
                                      (directory-files dir t "\\`[^.]")))))
         (unless (and (eq code 0) file)
           (error "yt-dlp could not download audio: %s" (string-trim (cmacs-secondbrain-ingest-sample out 400))))
         (cmacs-secondbrain-ingest--transcribe
          job file
          (lambda (segments)
            (cmacs-secondbrain-ingest--got-doc
             job (cmacs-secondbrain-ingest--transcript-doc job url meta segments 'yt-dlp+whisper)))))))))

(defun cmacs-secondbrain-ingest--transcript-doc (job source meta segments extractor)
  "Build the document for a transcript of SOURCE with METADATA and SEGMENTS."
  (let* ((stamps (cmacs-secondbrain-ingest--opt job :timestamps 'default))
         (body (cmacs-secondbrain-ingest-segments->paragraphs segments stamps))
         (text (cmacs-secondbrain-ingest-segments->paragraphs segments t))
         (title (cdr (assoc "title" meta)))
         (kind (cmacs-secondbrain-ingest-job-kind job)))
    (list :kind kind :source source :title title
          :body body :text text
          :meta (cl-remove-if (lambda (kv) (member (car kv) '("id" "title")))
                              (append meta
                                      (list (cons "Transcript duration"
                                                  (cmacs-secondbrain-ingest-ms->clock
                                                   (* 1000 (cmacs-secondbrain-ingest-segments-duration segments)))))))
          :segments segments
          :extractor extractor
          :warnings (and (null segments) '("empty transcript")))))

;;;;; Local media

(defun cmacs-secondbrain-ingest--require-whisper ()
  (unless (and (fboundp 'cmacs-whisper-supported-p) (cmacs-whisper-supported-p))
    (error "transcription needs cmacs built --with-cmacs-whisper"))
  (unless (cmacs-secondbrain-ingest-tool-p 'ffmpeg)
    (error "ffmpeg is not installed (Fedora package: ffmpeg)")))

(defun cmacs-secondbrain-ingest--media-start (job file)
  (cmacs-secondbrain-ingest--require-whisper)
  (let ((meta (or (cmacs-secondbrain-ingest-ffprobe file) nil)))
    (cmacs-secondbrain-ingest--transcribe
     job file
     (lambda (segments)
       (cmacs-secondbrain-ingest--got-doc
        job (cmacs-secondbrain-ingest--transcript-doc job file meta segments 'ffmpeg+whisper))))))

(defun cmacs-secondbrain-ingest--transcribe (job file on-segments)
  "Convert FILE to WAV, run whisper, call ON-SEGMENTS with the segments."
  (require 'cmacs-whisper)
  (let* ((wav (expand-file-name "audio.wav" (cmacs-secondbrain-ingest--tmpdir job)))
         (model (or (cmacs-secondbrain-ingest--opt job :whisper-model)
                    cmacs-secondbrain-ingest-whisper-model
                    (cmacs-whisper-model-path)))
         (lang (or (cmacs-secondbrain-ingest--opt job :language)
                   (and (boundp 'cmacs-whisper-language) cmacs-whisper-language))))
    (unless (file-exists-p model)
      (error "whisper model %s is missing (M-x cmacs-whisper-download-model)" model))
    (setf (cmacs-secondbrain-ingest-job-progress job) "extracting audio")
    (cmacs-secondbrain-ingest--render)
    (cmacs-secondbrain-ingest--run-process
     job "ffmpeg" (cmacs-secondbrain-ingest-ffmpeg-wav-command file wav)
     (lambda (code out)
       (unless (and (eq code 0) (file-exists-p wav))
         (error "ffmpeg could not decode %s: %s" (file-name-nondirectory file)
                (string-trim (cmacs-secondbrain-ingest-sample out 400))))
       (setf (cmacs-secondbrain-ingest-job-progress job)
             (format "transcribing with %s" (file-name-nondirectory model)))
       (cmacs-secondbrain-ingest--render)
       (cmacs-whisper-transcribe-async
        model wav
        (lambda (result)
          (unless (cmacs-secondbrain-ingest-job-cancelled job)
            (cmacs-secondbrain-ingest--guard job
              (let ((err (cdr (assq :error result))))
                (when err (error "whisper: %s" err))
                (funcall on-segments
                         (mapcar (lambda (seg)
                                   (list (cons :start (cdr (assq :start seg)))
                                         (cons :end (cdr (assq :end seg)))
                                         (cons :text (cdr (assq :text seg)))))
                                 (cdr (assq :segments result))))))))
        lang cmacs-secondbrain-ingest-whisper-threads)))))

;;;;; Crawling

(defun cmacs-secondbrain-ingest--same-site-p (a b)
  "Non-nil when URLs A and B share a host, ignoring a www. prefix."
  (let ((ha (url-host (url-generic-parse-url a)))
        (hb (url-host (url-generic-parse-url b))))
    (and ha hb (equal (string-remove-prefix "www." (downcase ha))
                      (string-remove-prefix "www." (downcase hb))))))

(defun cmacs-secondbrain-ingest-parse-robots (text)
  "Return the Disallow path prefixes for `User-agent: *' in robots.txt TEXT."
  (let ((ours nil) (out nil))
    (dolist (line (split-string (or text "") "\n"))
      (let ((l (string-trim (car (split-string line "#")))))
        (cond ((string-match "\\`User-agent:[ \t]*\\(.*\\)\\'" l)
               (setq ours (equal (string-trim (match-string 1 l)) "*")))
              ((and ours (string-match "\\`Disallow:[ \t]*\\(.*\\)\\'" l))
               (let ((p (string-trim (match-string 1 l))))
                 (unless (string-empty-p p) (push p out)))))))
    (nreverse out)))

(defun cmacs-secondbrain-ingest--robots-allow-p (url disallow)
  (let ((path (or (car (url-path-and-query (url-generic-parse-url url))) "/")))
    (not (cl-some (lambda (p) (string-prefix-p p path)) disallow))))

(defun cmacs-secondbrain-ingest--crawl-start (job url)
  (let* ((state (list :queue (list (cons url 0)) :seen (make-hash-table :test 'equal)
                      :pages nil :start url
                      :depth (cmacs-secondbrain-ingest--opt job :depth cmacs-secondbrain-ingest-crawl-depth)
                      :max (cmacs-secondbrain-ingest--opt job :max-pages cmacs-secondbrain-ingest-crawl-max-pages)
                      :wait (cmacs-secondbrain-ingest--opt job :wait cmacs-secondbrain-ingest-crawl-wait)
                      :include (cmacs-secondbrain-ingest--opt job :include)
                      :exclude (cmacs-secondbrain-ingest--opt job :exclude)
                      :same-site (not (cmacs-secondbrain-ingest--opt job :no-domain-restrict))
                      :disallow nil)))
    (setf (cmacs-secondbrain-ingest-job-kind job) 'crawl
          (cmacs-secondbrain-ingest-job-crawl job) state)
    (puthash url t (plist-get state :seen))
    (if cmacs-secondbrain-ingest-crawl-respect-robots
        (let* ((u (url-generic-parse-url url))
               (robots (format "%s://%s/robots.txt" (url-type u) (url-host u))))
          (setf (cmacs-secondbrain-ingest-job-cancel-fn job)
                (cmacs-secondbrain-ingest-fetch-url
                 robots
                 (lambda (res)
                   (unless (cmacs-secondbrain-ingest-job-cancelled job)
                     (when (and (plist-get res :ok) (< (plist-get res :status) 400)
                                (stringp (plist-get res :body)))
                       (plist-put state :disallow
                                  (cmacs-secondbrain-ingest-parse-robots (plist-get res :body))))
                     (cmacs-secondbrain-ingest--crawl-next job))))))
      (cmacs-secondbrain-ingest--crawl-next job))))

(defun cmacs-secondbrain-ingest--crawl-next (job)
  "Fetch the next queued page of JOB's crawl, or finish."
  (let* ((state (cmacs-secondbrain-ingest-job-crawl job))
         (queue (plist-get state :queue))
         (pages (plist-get state :pages)))
    (cond
     ((or (null queue) (>= (length pages) (plist-get state :max)))
      (when (and queue (>= (length pages) (plist-get state :max)))
        (cmacs-secondbrain-ingest--warn job "crawl stopped at %d pages; %d links unvisited"
                                        (plist-get state :max) (length queue)))
      (cmacs-secondbrain-ingest--crawl-finish job))
     (t
      (let* ((entry (pop queue)) (url (car entry)) (depth (cdr entry)))
        (plist-put state :queue queue)
        (setf (cmacs-secondbrain-ingest-job-progress job)
              (format "crawling %d/%d: %s" (1+ (length pages)) (plist-get state :max) url))
        (cmacs-secondbrain-ingest--render)
        (setf (cmacs-secondbrain-ingest-job-cancel-fn job)
              (cmacs-secondbrain-ingest-fetch-url
               url
               (lambda (res)
                 (unless (cmacs-secondbrain-ingest-job-cancelled job)
                   (cmacs-secondbrain-ingest--guard job
                     (if (and (plist-get res :ok) (< (plist-get res :status) 400)
                              (string-match-p "\\`text/html" (or (plist-get res :content-type) "")))
                         (let* ((html (plist-get res :body))
                                (final (or (plist-get res :url) url))
                                (doc (cmacs-secondbrain-ingest-html->doc html final url)))
                           (plist-put doc :depth depth)
                           (plist-put state :pages (append (plist-get state :pages) (list doc)))
                           (when (< depth (plist-get state :depth))
                             (dolist (link (cmacs-secondbrain-ingest-html-links html final))
                               (when (cmacs-secondbrain-ingest--crawl-wanted-p state link)
                                 (puthash link t (plist-get state :seen))
                                 (plist-put state :queue
                                            (append (plist-get state :queue)
                                                    (list (cons link (1+ depth)))))))))
                       (cmacs-secondbrain-ingest--warn job "skipped %s: %s" url
                                                       (or (plist-get res :error)
                                                           (format "HTTP %s %s" (plist-get res :status)
                                                                   (plist-get res :content-type)))))
                     (run-at-time (plist-get state :wait) nil
                                  (lambda ()
                                    (unless (cmacs-secondbrain-ingest-job-cancelled job)
                                      (cmacs-secondbrain-ingest--guard job
                                        (cmacs-secondbrain-ingest--crawl-next job)))))))))))))))

(defun cmacs-secondbrain-ingest--crawl-wanted-p (state link)
  (and (not (gethash link (plist-get state :seen)))
       (or (not (plist-get state :same-site))
           (cmacs-secondbrain-ingest--same-site-p (plist-get state :start) link))
       (or (null (plist-get state :include)) (string-match-p (plist-get state :include) link))
       (or (null (plist-get state :exclude)) (not (string-match-p (plist-get state :exclude) link)))
       (not (string-match-p "\\.\\(?:png\\|jpe?g\\|gif\\|svg\\|webp\\|css\\|js\\|ico\\|woff2?\\|zip\\|mp[34]\\|pdf\\)\\(?:\\?.*\\)?\\'" link))
       (cmacs-secondbrain-ingest--robots-allow-p link (plist-get state :disallow))))

(defun cmacs-secondbrain-ingest--crawl-finish (job)
  (let* ((state (cmacs-secondbrain-ingest-job-crawl job))
         (pages (plist-get state :pages)))
    (unless pages (error "the crawl fetched no pages"))
    (cmacs-secondbrain-ingest--got-doc job (cmacs-secondbrain-ingest--site-doc job (plist-get state :start) pages))))

(defun cmacs-secondbrain-ingest--site-doc (job source pages)
  "Build the site-level document for a crawl or export from PAGES."
  (setf (cmacs-secondbrain-ingest-job-pages job) pages)
  (let ((first (car pages)))
    (list :kind (cmacs-secondbrain-ingest-job-kind job) :source source
          :title (or (plist-get first :title) source)
          :body (concat "* Pages\n"
                        (mapconcat (lambda (p)
                                     (format "- %s" (or (plist-get p :title) (plist-get p :source))))
                                   pages "\n"))
          :text (mapconcat (lambda (p)
                             (concat (or (plist-get p :title) "") "\n"
                                     (or (plist-get p :text) "")))
                           pages "\n\n-----\n\n")
          :meta (list (cons "URL" source) (cons "Pages" (number-to-string (length pages))))
          :extractor 'crawl)))

(defun cmacs-secondbrain-ingest--site-export-start (job file)
  "Unpack an archive of saved pages and treat it as a site."
  (let* ((dir (cmacs-secondbrain-ingest-unpack-archive file))
         (files (cmacs-secondbrain-ingest-find-html-files dir))
         (pages nil))
    (setf (cmacs-secondbrain-ingest-job-tmpdir job) dir)
    (unless files (error "%s contains no HTML pages" (file-name-nondirectory file)))
    (dolist (f (seq-take files cmacs-secondbrain-ingest-crawl-max-pages))
      (let* ((html (cmacs-secondbrain-ingest--read-file f))
             (saved (cmacs-secondbrain-ingest-html-saved-from html))
             (d (cmacs-secondbrain-ingest-html->doc html saved (file-relative-name f dir))))
        (push d pages)))
    (setf (cmacs-secondbrain-ingest-job-kind job) 'site-export)
    (cmacs-secondbrain-ingest--got-doc
     job (cmacs-secondbrain-ingest--site-doc job file (nreverse pages)))))

;;;;; Extract

(defun cmacs-secondbrain-ingest--stage-extract (job)
  (if (cmacs-secondbrain-ingest-job-doc job)
      (cmacs-secondbrain-ingest--advance job 'analysing)
    (let ((text (cmacs-secondbrain-ingest--opt job :text)))
      (cmacs-secondbrain-ingest--got-doc
       job
       (if text
           (cmacs-secondbrain-ingest-text->doc
            text (or (cmacs-secondbrain-ingest--opt job :format)
                     (cmacs-secondbrain-ingest-guess-text-format text))
            (cmacs-secondbrain-ingest--opt job :source "text"))
         (cmacs-secondbrain-ingest-extract-file (cmacs-secondbrain-ingest-job-input job)
                                                (cmacs-secondbrain-ingest-job-kind job)))))))

;;;;; Analyse

(defun cmacs-secondbrain-ingest--sanitize-doc (job)
  "Redact JOB's document in place when asked."
  (let ((rules (cmacs-secondbrain-ingest--opt job :sanitize cmacs-secondbrain-ingest-sanitize)))
    (when rules
      (let* ((doc (cmacs-secondbrain-ingest-job-doc job))
             (total 0))
        ;; Every field is redacted; only the stored body is counted, so
        ;; the note reports how many secrets IT would have carried.
        (dolist (key '(:body :text :title))
          (let ((r (cmacs-secondbrain-ingest-redact-count (plist-get doc key) rules)))
            (plist-put doc key (car r))
            (when (eq key :body) (cl-incf total (cdr r)))))
        (dolist (p (cmacs-secondbrain-ingest-job-pages job))
          (dolist (key '(:body :text :title))
            (let ((r (cmacs-secondbrain-ingest-redact-count (plist-get p key) rules)))
              (plist-put p key (car r))
              (when (eq key :body) (cl-incf total (cdr r))))))
        (plist-put doc :redactions total)
        (cmacs-secondbrain-ingest--log job "redacted %d matches" total)))))

(defun cmacs-secondbrain-ingest--ai-enabled-p (job)
  (and (not (cmacs-secondbrain-ingest--opt job :no-ai))
       (cmacs-secondbrain-ingest-ai-available-p)))

(defun cmacs-secondbrain-ingest--summary-wanted-p (job)
  (and (not (cmacs-secondbrain-ingest--opt job :no-summary (not cmacs-secondbrain-ingest-summarize)))
       (cmacs-secondbrain-ingest--ai-enabled-p job)
       (not (string-blank-p (or (plist-get (cmacs-secondbrain-ingest-job-doc job) :text) "")))))

(defun cmacs-secondbrain-ingest--analysis-wanted-p (job)
  "Non-nil when the analysis call would tell us something we do not know."
  (and (cmacs-secondbrain-ingest--ai-enabled-p job)
       (not (string-blank-p (or (plist-get (cmacs-secondbrain-ingest-job-doc job) :text) "")))
       (or (cmacs-secondbrain-ingest--placement-wanted-p job)
           (and (cmacs-secondbrain-ingest--summary-wanted-p job)
                (eq (cmacs-secondbrain-ingest--opt job :type cmacs-secondbrain-ingest-summary-type) 'auto))
           (null (cmacs-secondbrain-ingest--opt job :title))
           cmacs-secondbrain-ingest-suggest-tags)))

(defun cmacs-secondbrain-ingest--stage-analyse (job)
  (cmacs-secondbrain-ingest--sanitize-doc job)
  (if (not (cmacs-secondbrain-ingest--analysis-wanted-p job))
      (cmacs-secondbrain-ingest--advance job 'summarising)
    (let* ((root (cmacs-secondbrain-ingest-root job))
           (para (cmacs-secondbrain-ingest--opt job :para))
           (within (and para (not (eq para 'detect)) (cmacs-secondbrain-ingest--para-dir para)))
           (tree (cmacs-secondbrain-ingest--tree-for-model root within))
           (prompt (cmacs-secondbrain-ingest-analysis-prompt
                    (cmacs-secondbrain-ingest-job-doc job) tree
                    (list :para within
                          :tags (cmacs-secondbrain-ingest--opt job :tags)
                          :title (cmacs-secondbrain-ingest--opt job :title)))))
      (setq prompt (concat "Answer with ONE JSON object and nothing else.\n\n" prompt))
      (setf (cmacs-secondbrain-ingest-job-progress job) "asking the model where this belongs")
      (cmacs-secondbrain-ingest--render)
      (setf (cmacs-secondbrain-ingest-job-cancel-fn job)
            (cmacs-secondbrain-ingest-ai-request
             cmacs-secondbrain-ingest--analysis-system prompt
             (lambda (res)
               (unless (cmacs-secondbrain-ingest-job-cancelled job)
                 (cmacs-secondbrain-ingest--guard job
                   (pcase (car res)
                     (:ok
                      (let ((a (cmacs-secondbrain-ingest-normalize-analysis
                                (cmacs-secondbrain-ingest-parse-json (cadr res)))))
                        (if a
                            (progn (setf (cmacs-secondbrain-ingest-job-analysis job) a)
                                   (cmacs-secondbrain-ingest--log job "analysis: %S"
                                                                  (list :title (plist-get a :title)
                                                                        :type (plist-get a :summary-type)
                                                                        :path (plist-get a :path)
                                                                        :confidence (plist-get a :confidence))))
                          (cmacs-secondbrain-ingest--warn job "model analysis was not JSON; using defaults"))))
                     (_ (cmacs-secondbrain-ingest--warn job "analysis failed: %s" (cadr res))))
                   (cmacs-secondbrain-ingest--advance job 'summarising))))
             (cmacs-secondbrain-ingest--opt job :provider)
             (cmacs-secondbrain-ingest--opt job :model))))))

;;;;; Summarise

(defun cmacs-secondbrain-ingest--resolve-summary-type (job)
  (let ((ty (cmacs-secondbrain-ingest--opt job :type cmacs-secondbrain-ingest-summary-type)))
    (if (and ty (not (eq ty 'auto))) ty
      (or (plist-get (cmacs-secondbrain-ingest-job-analysis job) :summary-type)
          (cmacs-secondbrain-ingest-default-summary-type (cmacs-secondbrain-ingest-job-kind job))))))

(defun cmacs-secondbrain-ingest--stage-summarise (job)
  (setf (cmacs-secondbrain-ingest-job-summary-type job) (cmacs-secondbrain-ingest--resolve-summary-type job))
  (if (not (cmacs-secondbrain-ingest--summary-wanted-p job))
      (cmacs-secondbrain-ingest--advance job 'linking)
    (let* ((doc (cmacs-secondbrain-ingest-job-doc job))
           (type (cmacs-secondbrain-ingest-job-summary-type job))
           (system (cmacs-secondbrain-ingest-summary-system
                    type (cmacs-secondbrain-ingest--opt job :principle)
                    (cmacs-secondbrain-ingest--opt job :prompt)))
           (prompt (concat (format "Title: %s\nSource: %s\nKind: %s\n\nThe material follows the line of dashes.\n----------\n"
                                   (cmacs-secondbrain-ingest--title job)
                                   (or (plist-get doc :source) (cmacs-secondbrain-ingest-job-input job))
                                   (cmacs-secondbrain-ingest-job-kind job))
                           (cmacs-secondbrain-ingest-sample (plist-get doc :text)
                                                            cmacs-secondbrain-ingest-summary-max-chars))))
      (setf (cmacs-secondbrain-ingest-job-progress job) (format "summarising as %s" type))
      (cmacs-secondbrain-ingest--render)
      (setf (cmacs-secondbrain-ingest-job-cancel-fn job)
            (cmacs-secondbrain-ingest-ai-request
             system prompt
             (lambda (res)
               (unless (cmacs-secondbrain-ingest-job-cancelled job)
                 (cmacs-secondbrain-ingest--guard job
                   (pcase (car res)
                     (:ok (setf (cmacs-secondbrain-ingest-job-summary job)
                                (cmacs-secondbrain-ingest--clean-summary (cadr res))))
                     (_ (cmacs-secondbrain-ingest--warn job "summary failed: %s" (cadr res))))
                   (cmacs-secondbrain-ingest--advance job 'linking))))
             (cmacs-secondbrain-ingest--opt job :provider)
             (cmacs-secondbrain-ingest--opt job :model))))))

(defun cmacs-secondbrain-ingest--clean-summary (text)
  "Normalise a model summary.
Strips stray fences and makes every heading level two or deeper."
  (let ((s (string-trim (or text ""))))
    (setq s (replace-regexp-in-string "\\````[a-z]*\n\\|\n```\\'" "" s))
    ;; Markdown headings that slipped through.
    (setq s (replace-regexp-in-string "^#\\{1,6\\} " "** " s))
    ;; Level-one headings would break out of `* Summary'.
    (setq s (replace-regexp-in-string "^\\* " "** " s))
    (string-trim s)))

;;;;; Link

(defun cmacs-secondbrain-ingest--stage-link (job)
  (when (and (cmacs-secondbrain-ingest--opt job :link cmacs-secondbrain-ingest-link-related)
             (cmacs-secondbrain-ingest--memory-index-p))
    (setf (cmacs-secondbrain-ingest-job-progress job) "finding related notes")
    (cmacs-secondbrain-ingest--render)
    (condition-case err
        (setf (cmacs-secondbrain-ingest-job-related job)
              (cmacs-secondbrain-ingest-related-notes
               (concat (cmacs-secondbrain-ingest--title job) "\n\n"
                       (or (cmacs-secondbrain-ingest-job-summary job)
                           (plist-get (cmacs-secondbrain-ingest-job-doc job) :text)))
               (cmacs-secondbrain-ingest--opt job :related-count cmacs-secondbrain-ingest-related-count)
               nil (cmacs-secondbrain-ingest-root job)))
      (error (cmacs-secondbrain-ingest--warn job "related-note search failed: %s"
                                             (error-message-string err))))
    (cmacs-secondbrain-ingest--log job "%d related notes" (length (cmacs-secondbrain-ingest-job-related job))))
  ;; Everything the writer needs is now known; fix the title, tags and target.
  (setf (cmacs-secondbrain-ingest-job-title job) (cmacs-secondbrain-ingest--title job)
        (cmacs-secondbrain-ingest-job-tags job) (cmacs-secondbrain-ingest--tags job)
        (cmacs-secondbrain-ingest-job-description job)
        (or (cmacs-secondbrain-ingest--opt job :description)
            (plist-get (cmacs-secondbrain-ingest-job-analysis job) :description)
            (plist-get (cmacs-secondbrain-ingest-job-doc job) :description)
            (cmacs-secondbrain-ingest--fallback-description job))
        (cmacs-secondbrain-ingest-job-target-dir job) (cmacs-secondbrain-ingest--resolve-target-dir job)
        (cmacs-secondbrain-ingest-job-note-id job)
        (or (cmacs-secondbrain-ingest--opt job :id)
            (and (plist-get (cmacs-secondbrain-ingest-job-doc job) :id)
                 (cmacs-secondbrain-ingest--opt job :preserve-id t)
                 (plist-get (cmacs-secondbrain-ingest-job-doc job) :id))
            (org-id-new)))
  (cmacs-secondbrain-ingest--advance job (if (cmacs-secondbrain-ingest--opt job :review) 'reviewing 'writing)))

(defun cmacs-secondbrain-ingest--one-line (text &optional max)
  "Collapse TEXT to one plain line of at most MAX (default 160) characters."
  (let* ((s (replace-regexp-in-string "^#\\{1,6\\} \\|^\\*+ " "" (or text "")))
         (s (replace-regexp-in-string "[ \t\n]+" " " s))
         (s (replace-regexp-in-string "\\[\\[[^]]*\\]\\[\\([^]]*\\)\\]\\]" "\\1" s))
         (s (replace-regexp-in-string "\\(?:\\`\\| \\)[*/=~_+]\\([^*/=~_+]+\\)[*/=~_+]\\(?:\\'\\|[ .,;:!?]\\)"
                                      (lambda (m) (replace-regexp-in-string "[*/=~_+]" "" m)) s))
         (s (string-trim s))
         (max (or max 160)))
    (if (> (length s) max)
        (concat (string-trim (substring s 0 (- max 1))) "…")
      s)))

(defun cmacs-secondbrain-ingest--fallback-description (job)
  "A one-line description of JOB's note when no one supplied one.
Prose kinds use their first sentence; structured kinds describe what
they are, because the first line of a CSV or a mail header is not a
description of anything."
  (let* ((doc (cmacs-secondbrain-ingest-job-doc job))
         (kind (cmacs-secondbrain-ingest-job-kind job))
         (meta (plist-get doc :meta))
         (get (lambda (k) (cdr (assoc k meta)))))
    (cmacs-secondbrain-ingest--one-line
     (pcase kind
       ('email (format "Email from %s: %s" (or (funcall get "From") "unknown sender")
                       (or (plist-get doc :title) "(no subject)")))
       ('data (format "%s data from %s%s" (upcase (or (funcall get "Format") "structured"))
                      (file-name-nondirectory (or (plist-get doc :source) "input"))
                      (if (funcall get "Size") (format " (%s)" (funcall get "Size")) "")))
       ((or 'youtube 'video 'audio)
        (format "%s%s%s" (if (eq kind 'youtube) "Video" (capitalize (symbol-name kind)))
                (if (funcall get "Channel") (format " by %s" (funcall get "Channel")) "")
                (if (funcall get "Duration") (format ", %s" (funcall get "Duration")) "")))
       ((or 'crawl 'site-export)
        (format "%s pages from %s" (or (funcall get "Pages") "several") (or (plist-get doc :source) "a site")))
       (_
        (let* ((text (replace-regexp-in-string "[ \t\n]+" " " (or (plist-get doc :text) "")))
               (text (replace-regexp-in-string "\\`\\(?:\\[[0-9:]+\\] \\)" "" (string-trim text)))
               (end (and (string-match "[.!?]\\(?: \\|\\'\\)" text) (match-end 0)))
               (first (string-trim (if (and end (< end 200)) (substring text 0 end) text))))
          (if (string-empty-p first)
              (format "Ingested %s" kind)
            first)))))))

;;;;; Review

(defvar-local cmacs-secondbrain-ingest--review-job nil)

(defvar cmacs-secondbrain-ingest-review-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cmacs-secondbrain-ingest-review-accept)
    (define-key m (kbd "C-c C-k") #'cmacs-secondbrain-ingest-review-discard)
    m)
  "Keys active in a draft buffer while a note awaits review.")

(define-minor-mode cmacs-secondbrain-ingest-review-mode
  "Review a note before it is written.  \\[cmacs-secondbrain-ingest-review-accept] writes it, \\[cmacs-secondbrain-ingest-review-discard] drops it."
  :lighter " sb-review" :keymap cmacs-secondbrain-ingest-review-map)

(defun cmacs-secondbrain-ingest--stage-review (job)
  (let ((buf (generate-new-buffer (format "*second brain: draft %s*" (cmacs-secondbrain-ingest-job-title job)))))
    (with-current-buffer buf
      (insert (cmacs-secondbrain-ingest-render-note job))
      (goto-char (point-min))
      (org-mode)
      (cmacs-secondbrain-ingest-review-mode 1)
      (setq cmacs-secondbrain-ingest--review-job job)
      (setq header-line-format
            (format " Draft -> %s   C-c C-c write   C-c C-k discard"
                    (abbreviate-file-name (cmacs-secondbrain-ingest-job-target-dir job)))))
    (setf (cmacs-secondbrain-ingest-job-progress job) "awaiting your review")
    (cmacs-secondbrain-ingest--render)
    (pop-to-buffer buf)))

(defun cmacs-secondbrain-ingest-review-accept ()
  "Write the reviewed draft as the note."
  (interactive)
  (let ((job cmacs-secondbrain-ingest--review-job)
        (text (buffer-substring-no-properties (point-min) (point-max))))
    (unless job (user-error "not a second-brain draft"))
    (setf (cmacs-secondbrain-ingest-job-options job)
          (plist-put (cmacs-secondbrain-ingest-job-options job) :final-text text))
    (kill-buffer)
    (cmacs-secondbrain-ingest--advance job 'writing)))

(defun cmacs-secondbrain-ingest-review-discard ()
  "Drop the reviewed draft; the job is cancelled."
  (interactive)
  (let ((job cmacs-secondbrain-ingest--review-job))
    (unless job (user-error "not a second-brain draft"))
    (kill-buffer)
    (cmacs-secondbrain-ingest-cancel job)))

;;;;; Write

(defun cmacs-secondbrain-ingest--copy-source (job dir)
  "Copy JOB's original file into DIR/.attachments when asked.
Returns the copy's path, or nil when nothing was copied."
  (let ((in (cmacs-secondbrain-ingest-job-input job)))
    (when (and (eq (cmacs-secondbrain-ingest--opt job :keep-source cmacs-secondbrain-ingest-keep-source) 'copy)
               (stringp in) (file-regular-p in))
      (let* ((adir (expand-file-name ".attachments" dir))
             (dest (expand-file-name
                    (concat (file-name-base (cmacs-secondbrain-ingest-job-target-file job))
                            "." (or (file-name-extension in) "bin"))
                    adir)))
        (make-directory adir t)
        (copy-file in dest t)
        (plist-put (cmacs-secondbrain-ingest-job-doc job) :meta
                   (append (plist-get (cmacs-secondbrain-ingest-job-doc job) :meta)
                           (list (cons "Copy" (format "[[file:%s]]" (file-relative-name dest dir))))))
        dest))))

(defun cmacs-secondbrain-ingest--stage-write (job)
  (let* ((root (cmacs-secondbrain-ingest-root job))
         (dir (cmacs-secondbrain-ingest-job-target-dir job)))
    (make-directory dir t)
    (run-hook-with-args 'cmacs-secondbrain-ingest-before-write-functions job)
    (if (cmacs-secondbrain-ingest-job-pages job)
        (cmacs-secondbrain-ingest--write-site job root dir)
      (cmacs-secondbrain-ingest--write-note job root dir))
    (cmacs-secondbrain-ingest--finish job 'done)))

(defun cmacs-secondbrain-ingest--write-note (job root dir)
  (let* ((title (cmacs-secondbrain-ingest-job-title job))
         (file (cmacs-secondbrain-ingest--filename job dir title)))
    (setf (cmacs-secondbrain-ingest-job-target-file job) file)
    (cmacs-secondbrain-ingest--copy-source job dir)
    (cond
     ((cmacs-secondbrain-ingest-job-appended job)
      ;; Keep the existing node's identity; add to it.
      (setf (cmacs-secondbrain-ingest-job-note-id job)
            (or (cmacs-secondbrain-ingest-file-id file) (cmacs-secondbrain-ingest-job-note-id job)))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward "^#\\+updated:.*$" nil t)
          (replace-match (concat "#+updated: " (cmacs-secondbrain-ingest--timestamp))))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (cmacs-secondbrain-ingest-render-append job))
        (write-region (point-min) (point-max) file nil 'silent)))
     (t
      (with-temp-file file
        (insert (or (cmacs-secondbrain-ingest--opt job :final-text)
                    (cmacs-secondbrain-ingest-render-note job))))))
    (setf (cmacs-secondbrain-ingest-job-note-file job) file)
    (when (and cmacs-secondbrain-ingest-register-index
               (not (cmacs-secondbrain-ingest-job-appended job)))
      (cmacs-secondbrain-ingest-register-in-index
       dir (cmacs-secondbrain-ingest-job-note-id job) title root)
      (cmacs-secondbrain-ingest--note-written job (expand-file-name "00_index.org" dir))
      (cmacs-secondbrain-ingest--roam-update (expand-file-name "00_index.org" dir)))
    (cmacs-secondbrain-ingest--roam-update file)
    (cmacs-secondbrain-ingest--after-note job file)))

(defun cmacs-secondbrain-ingest--write-site (job root dir)
  "Write a crawl or export: a subdirectory with an index and one note per page."
  (let* ((title (cmacs-secondbrain-ingest-job-title job))
         (site-dir (file-name-as-directory
                    (expand-file-name (cmacs-secondbrain-ingest-slugify
                                       (or (cmacs-secondbrain-ingest--opt job :name) title)
                                       cmacs-secondbrain-ingest-slug-max-length)
                                      dir)))
         (index (progn (make-directory site-dir t)
                       (expand-file-name "00_index.org" site-dir)))
         (pages (cmacs-secondbrain-ingest-job-pages job))
         (page-links nil))
    ;; One note per page, each its own node.
    (dolist (p pages)
      (let* ((ptitle (or (plist-get p :title) (plist-get p :source) "page"))
             (pfile (let ((f (expand-file-name (concat (cmacs-secondbrain-ingest-slugify ptitle 80) ".org") site-dir))
                          (n 2))
                      (while (file-exists-p f)
                        (setq f (expand-file-name (format "%s_%d.org" (cmacs-secondbrain-ingest-slugify ptitle 80) n) site-dir))
                        (cl-incf n))
                      f))
             (pid (org-id-new)))
        (with-temp-file pfile
          (insert (cmacs-secondbrain-ingest--header
                   pid ptitle (or (plist-get p :description) (format "Page from %s" title))
                   (cmacs-secondbrain-ingest--categories job dir)
                   (cmacs-secondbrain-ingest-job-tags job))
                  "\n* Metadata\n"
                  (mapconcat (lambda (kv) (format "- %s :: %s" (car kv) (cdr kv)))
                             (plist-get p :meta) "\n")
                  "\n\n* Content\n"
                  (cmacs-secondbrain-ingest-demote (or (plist-get p :body) "") 1)
                  "\n"))
        (push (cons pid ptitle) page-links)
        (cmacs-secondbrain-ingest--note-written job pfile)
        (cmacs-secondbrain-ingest--roam-update pfile)))
    ;; The site index carries the summary and lists the pages.
    (setf (cmacs-secondbrain-ingest-job-target-file job) index)
    (with-temp-file index
      (insert (cmacs-secondbrain-ingest--header
               (cmacs-secondbrain-ingest-job-note-id job) title
               (cmacs-secondbrain-ingest-job-description job)
               (cmacs-secondbrain-ingest--categories job dir)
               (cmacs-secondbrain-ingest-job-tags job))
              "\n"
              (if (cmacs-secondbrain-ingest-job-summary job)
                  (concat "* Summary\n" (string-trim (cmacs-secondbrain-ingest-job-summary job)) "\n\n")
                "")
              "* Metadata\n" (string-join (cmacs-secondbrain-ingest--metadata-lines job) "\n") "\n\n"
              "* Contents\n"
              (mapconcat (lambda (l) (format "- [[id:%s][%s]]" (car l) (cdr l)))
                         (nreverse page-links) "\n")
              "\n"
              (or (and (cmacs-secondbrain-ingest-job-related job)
                       (concat "\n" (cmacs-secondbrain-ingest--see-also (cmacs-secondbrain-ingest-job-related job)) "\n"))
                  "")))
    (setf (cmacs-secondbrain-ingest-job-note-file job) index)
    (when cmacs-secondbrain-ingest-register-index
      (cmacs-secondbrain-ingest-register-in-index dir (cmacs-secondbrain-ingest-job-note-id job) title root)
      (cmacs-secondbrain-ingest--note-written job (expand-file-name "00_index.org" dir)))
    (cmacs-secondbrain-ingest--roam-update index)
    (cmacs-secondbrain-ingest--after-note job index)))

(defcustom cmacs-secondbrain-ingest-reindex-memory t
  "Re-index each written note in the brigade memory index, incrementally.

Uses `cmacs-brigade-memory-update-files', which re-embeds only the new
note (and the index it was added to) and copies every other row of the
index verbatim -- seconds, against the hours of a rebuild.  Skipped when
there is no committed index yet; build one first with
`cmacs-brigade-memory-build'.  The effect is that `sb find' and the
related-notes step of the NEXT ingest already know about this one."
  :type 'boolean
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-reindex-delay 2
  "Seconds of idle time before the incremental re-index starts.
Lets the note be written and the job reported before the embedder is
asked for anything."
  :type 'number
  :group 'cmacs-secondbrain-ingest)

(declare-function cmacs-brigade-memory-update-files "cmacs-brigade-memory" (files &optional callback))
(declare-function cmacs-brigade-memory-index-exists-p "cmacs-brigade-memory" ())

(defun cmacs-secondbrain-ingest--note-written (job file)
  "Record FILE as written by JOB."
  (cl-pushnew (expand-file-name file) (cmacs-secondbrain-ingest-job-written job)
              :test #'equal))

(defun cmacs-secondbrain-ingest--reindex (job)
  "Queue an incremental memory re-index of what JOB wrote."
  (when (and cmacs-secondbrain-ingest-reindex-memory
             (cmacs-secondbrain-ingest-job-written job)
             (or (featurep 'cmacs-brigade-memory) (require 'cmacs-brigade-memory nil t))
             (fboundp 'cmacs-brigade-memory-update-files)
             (fboundp 'cmacs-brigade-memory-index-exists-p)
             (ignore-errors (cmacs-brigade-memory-index-exists-p)))
    (let ((files (cmacs-secondbrain-ingest-job-written job)))
      (run-with-idle-timer
       cmacs-secondbrain-ingest-reindex-delay nil
       (lambda ()
         (condition-case err
             (cmacs-brigade-memory-update-files files)
           (error (cmacs-secondbrain-ingest--log job "reindex failed: %s"
                                                 (error-message-string err)))))))))

(defun cmacs-secondbrain-ingest--after-note (job file)
  "Run the after-note hook and refresh the visualiser."
  (cmacs-secondbrain-ingest--note-written job file)
  (ignore-errors
    (run-hook-with-args
     'cmacs-secondbrain-ingest-after-note-functions
     (list :file file
           :id (cmacs-secondbrain-ingest-job-note-id job)
           :title (cmacs-secondbrain-ingest-job-title job)
           :kind (cmacs-secondbrain-ingest-job-kind job)
           :source (plist-get (cmacs-secondbrain-ingest-job-doc job) :source)
           :dir (cmacs-secondbrain-ingest-job-target-dir job)
           :tags (cmacs-secondbrain-ingest-job-tags job)
           :summary (cmacs-secondbrain-ingest-job-summary job)
           :warnings (reverse (cmacs-secondbrain-ingest-job-warnings job))
           :job-id (cmacs-secondbrain-ingest-job-id job)
           :extractor (plist-get (cmacs-secondbrain-ingest-job-doc job) :extractor)
           :related (mapcar #'car (cmacs-secondbrain-ingest-job-related job))
           :append (cmacs-secondbrain-ingest-job-appended job))))
  (when (and cmacs-secondbrain-ingest-refresh-view
             (boundp 'cmacs-secondbrain-buffer-name)
             (get-buffer cmacs-secondbrain-buffer-name)
             (fboundp 'cmacs-secondbrain-refresh))
    (ignore-errors
      (with-current-buffer cmacs-secondbrain-buffer-name
        (cmacs-secondbrain-refresh))))
  (cmacs-secondbrain-ingest--reindex job))

;;;; The pool -------------------------------------------------------------

(defvar cmacs-secondbrain-ingest--scheduling nil)

(defun cmacs-secondbrain-ingest--schedule ()
  "Start queued jobs while fewer than the parallel cap are active."
  (unless cmacs-secondbrain-ingest--scheduling
    (let ((cmacs-secondbrain-ingest--scheduling t))
      (let ((active (cl-count-if #'cmacs-secondbrain-ingest--active-p cmacs-secondbrain-ingest--jobs)))
        (dolist (job (reverse cmacs-secondbrain-ingest--jobs))
          (when (and (< active cmacs-secondbrain-ingest-parallel-jobs)
                     (eq (cmacs-secondbrain-ingest-job-stage job) 'queued)
                     (cmacs-secondbrain-ingest--opt job :started))
            (cl-incf active)
            (setf (cmacs-secondbrain-ingest-job-started job) (current-time))
            (cmacs-secondbrain-ingest--advance job 'acquiring)))))))

;;;; Public API -------------------------------------------------------------

(defun cmacs-secondbrain-ingest--expand-input (input opts)
  "Return the list of inputs INPUT stands for: itself, or a directory's files."
  (cond
   ((cmacs-secondbrain-ingest-url-p input) (list input))
   ((and (stringp input) (file-directory-p input))
    (let ((files (if (plist-get opts :recursive)
                     (directory-files-recursively input "\\`[^.]" nil)
                   (directory-files input t "\\`[^.]" t))))
      (cl-remove-if-not
       (lambda (f) (and (file-regular-p f)
                        (not (equal (file-name-nondirectory f) "00_index.org"))
                        (memq (plist-get (cmacs-secondbrain-ingest-classify f) :kind)
                              (cl-remove 'unknown cmacs-secondbrain-ingest-kinds))))
       files)))
   (t (list input))))

(defun cmacs-secondbrain-ingest-enqueue (input &rest opts)
  "Create a job for INPUT (a path, URL, or nil with `:text') and queue it.

OPTS are the keys of `cmacs-secondbrain-ingest-normalize-options'.  The
job is not started until `cmacs-secondbrain-ingest-start' (or `:start t')
so a batch can be assembled first.  Returns the job."
  (let* ((opts (cmacs-secondbrain-ingest-normalize-options opts))
         (text (plist-get opts :text))
         (input (or input (and text "<text>")))
         (cls (if text
                  (list :kind (plist-get (cmacs-secondbrain-ingest-classify
                                          "stdin" (or (plist-get opts :format)
                                                      (cmacs-secondbrain-ingest-guess-text-format text)))
                                         :kind)
                        :input input)
                (cmacs-secondbrain-ingest-classify input (plist-get opts :format))))
         (kind (plist-get cls :kind)))
    (when (and (not text) (not (plist-get cls :url-p)) (not (file-exists-p (plist-get cls :input))))
      (error "%s is neither a file nor a URL" input))
    (when (eq kind 'unknown)
      (error "%s: cannot tell what kind of file this is" input))
    (let ((job (cmacs-secondbrain-ingest-job--create
                :id (format "sbi-%d" (cl-incf cmacs-secondbrain-ingest--counter))
                :input (plist-get cls :input)
                :kind kind
                :options (plist-put opts :started (plist-get opts :start)))))
      (when (functionp (plist-get opts :callback))
        (push (plist-get opts :callback) (cmacs-secondbrain-ingest-job-callbacks job)))
      (push job cmacs-secondbrain-ingest--jobs)
      (cmacs-secondbrain-ingest--log job "queued %s as %s" (cmacs-secondbrain-ingest-job-input job) kind)
      (cmacs-secondbrain-ingest--render)
      (when (plist-get opts :start) (cmacs-secondbrain-ingest--schedule))
      job)))

(defun cmacs-secondbrain-ingest-start (&optional jobs)
  "Start JOBS (default: every queued job)."
  (dolist (job (or jobs (cl-remove-if-not (lambda (j) (eq (cmacs-secondbrain-ingest-job-stage j) 'queued))
                                          cmacs-secondbrain-ingest--jobs)))
    (setf (cmacs-secondbrain-ingest-job-options job)
          (plist-put (cmacs-secondbrain-ingest-job-options job) :started t)))
  (cmacs-secondbrain-ingest--schedule))

(defun cmacs-secondbrain-ingest-run (inputs &rest opts)
  "Queue and start a job for each of INPUTS (a string or list); return the jobs.
A directory expands to the supported files inside it."
  (let ((jobs nil))
    (dolist (in (if (listp inputs) inputs (list inputs)))
      (dolist (one (cmacs-secondbrain-ingest--expand-input in opts))
        (push (apply #'cmacs-secondbrain-ingest-enqueue one :start t opts) jobs)))
    (when (and (null jobs) (plist-get opts :text))
      (push (apply #'cmacs-secondbrain-ingest-enqueue nil :start t opts) jobs))
    (nreverse jobs)))

(defun cmacs-secondbrain-ingest-cancel (job)
  "Cancel JOB (a job or id) wherever it is."
  (let ((job (or (cmacs-secondbrain-ingest-job job) (error "no such job %s" job))))
    (unless (cmacs-secondbrain-ingest--finished-p job)
      (setf (cmacs-secondbrain-ingest-job-cancelled job) t)
      (when (process-live-p (cmacs-secondbrain-ingest-job-process job))
        (ignore-errors (delete-process (cmacs-secondbrain-ingest-job-process job))))
      (when (functionp (cmacs-secondbrain-ingest-job-cancel-fn job))
        (ignore-errors (funcall (cmacs-secondbrain-ingest-job-cancel-fn job))))
      (cmacs-secondbrain-ingest--finish job 'cancelled))
    job))

(defun cmacs-secondbrain-ingest-wait (jobs &optional timeout)
  "Block until JOBS (a job, id, or list) finish or TIMEOUT seconds pass.

Pumps the main loop while waiting, so subprocess sentinels, fetch
callbacks and model streams run.  For batch use and tests -- never call
this from a D-Bus or MCP handler, which already sits on the main thread.
Returns non-nil when every job finished."
  (let ((jobs (mapcar #'cmacs-secondbrain-ingest-job (if (listp jobs) jobs (list jobs))))
        (deadline (and timeout (time-add (current-time) timeout))))
    (while (and (cl-some (lambda (j) (and j (not (cmacs-secondbrain-ingest--finished-p j)))) jobs)
                (or (null deadline) (time-less-p (current-time) deadline)))
      (accept-process-output nil 0.1)
      (sit-for 0.05))
    (cl-every (lambda (j) (and j (cmacs-secondbrain-ingest--finished-p j))) jobs)))

(defun cmacs-secondbrain-ingest-job-plist (job)
  "Return JOB's state as a plist of strings and numbers, for JSON."
  (let ((job (or (cmacs-secondbrain-ingest-job job) (error "no such job %s" job))))
    (list :id (cmacs-secondbrain-ingest-job-id job)
          :input (cmacs-secondbrain-ingest-job-input job)
          :kind (symbol-name (cmacs-secondbrain-ingest-job-kind job))
          :stage (symbol-name (cmacs-secondbrain-ingest-job-stage job))
          :progress (or (cmacs-secondbrain-ingest-job-progress job) "")
          :title (or (cmacs-secondbrain-ingest-job-title job)
                     (plist-get (cmacs-secondbrain-ingest-job-doc job) :title))
          :note_file (cmacs-secondbrain-ingest-job-note-file job)
          :note_id (cmacs-secondbrain-ingest-job-note-id job)
          :target_dir (cmacs-secondbrain-ingest-job-target-dir job)
          :tags (or (cmacs-secondbrain-ingest-job-tags job) [])
          :warnings (or (reverse (cmacs-secondbrain-ingest-job-warnings job)) [])
          :error (cmacs-secondbrain-ingest-job-error job)
          :started (and (cmacs-secondbrain-ingest-job-started job)
                        (format-time-string "%FT%T%z" (cmacs-secondbrain-ingest-job-started job)))
          :finished (and (cmacs-secondbrain-ingest-job-finished job)
                         (format-time-string "%FT%T%z" (cmacs-secondbrain-ingest-job-finished job)))
          :seconds (and (cmacs-secondbrain-ingest-job-started job)
                        (float-time (time-subtract (or (cmacs-secondbrain-ingest-job-finished job) (current-time))
                                                   (cmacs-secondbrain-ingest-job-started job))))
          :done (and (cmacs-secondbrain-ingest--finished-p job) t))))

(defun cmacs-secondbrain-ingest--plist->json (plist)
  "Serialise PLIST (keyword keys) to JSON, nil as null and lists as arrays."
  (let ((h (make-hash-table :test 'equal)))
    (cl-loop for (k v) on plist by #'cddr
             do (puthash (substring (symbol-name k) 1)
                         (cond ((null v) :null)
                               ((eq v t) t)
                               ((and (listp v) (not (stringp v))) (vconcat v))
                               (t v))
                         h))
    (json-serialize h)))

(defun cmacs-secondbrain-ingest-status-json (id)
  "Return the status of job ID as a JSON string."
  (cmacs-secondbrain-ingest--plist->json (cmacs-secondbrain-ingest-job-plist id)))

(defun cmacs-secondbrain-ingest-list-json ()
  "Return every job's status as a JSON array string."
  (concat "[" (mapconcat #'cmacs-secondbrain-ingest-status-json
                         (mapcar #'cmacs-secondbrain-ingest-job-id (reverse cmacs-secondbrain-ingest--jobs))
                         ",")
          "]"))

(defun cmacs-secondbrain-ingest-from-json (inputs-json options-json)
  "Queue and start jobs from JSON: INPUTS-JSON is an array of paths/URLs (or
a single string), OPTIONS-JSON an object.  Returns a JSON array of job
statuses.  This is what the D-Bus `Ingest' method and the MCP tool call."
  (let* ((inputs (cmacs-secondbrain-ingest-json-parse inputs-json))
         (inputs (cond ((stringp inputs) (list inputs))
                       ((listp inputs) inputs)
                       (t (error "inputs must be a JSON array of strings"))))
         (opts (cmacs-secondbrain-ingest-options-from-json options-json)))
    (if (plist-get opts :dry-run)
        (concat "[" (mapconcat (lambda (in) (cmacs-secondbrain-ingest--plist->json
                                              (cmacs-secondbrain-ingest-plan in opts)))
                               inputs ",")
                "]")
      (let ((jobs (apply #'cmacs-secondbrain-ingest-run inputs opts)))
        (concat "[" (mapconcat (lambda (j) (cmacs-secondbrain-ingest-status-json
                                             (cmacs-secondbrain-ingest-job-id j)))
                               jobs ",")
                "]")))))

(defun cmacs-secondbrain-ingest-plan (input &optional opts)
  "Return what ingesting INPUT with OPTS would do, without doing it.
A plist: :input :kind :strategies (available ones, in order) :missing
:target (the directory, or \"detect\") :ai (whether the model would be
used) :root."
  (let* ((opts (cmacs-secondbrain-ingest-normalize-options opts))
         (cls (cmacs-secondbrain-ingest-classify (or input "<text>") (plist-get opts :format)))
         (kind (plist-get cls :kind))
         (strategies (cdr (assq kind cmacs-secondbrain-ingest-strategies)))
         (job (cmacs-secondbrain-ingest-job--create :id "plan" :input input :kind kind :options opts))
         (explicit (condition-case err (cmacs-secondbrain-ingest--explicit-dir job)
                     (error (format "error: %s" (error-message-string err))))))
    (list :input (plist-get cls :input)
          :kind (symbol-name kind)
          :strategies (mapcar #'symbol-name
                              (cl-remove-if-not #'cmacs-secondbrain-ingest-strategy-available-p strategies))
          :missing (mapcar #'symbol-name
                           (cl-remove-if #'cmacs-secondbrain-ingest-strategy-available-p strategies))
          :target (cond ((stringp explicit) (abbreviate-file-name explicit))
                        ((cmacs-secondbrain-ingest--placement-wanted-p job) "detect")
                        (t (abbreviate-file-name (cmacs-secondbrain-ingest--inbox-dir job))))
          :ai (and (cmacs-secondbrain-ingest--ai-enabled-p job) t)
          :provider (format "%s/%s" (or (plist-get opts :provider) cmacs-secondbrain-ingest-provider)
                            (or (plist-get opts :model) cmacs-secondbrain-ingest-model "default"))
          :root (abbreviate-file-name (cmacs-secondbrain-ingest-root job)))))

;;;; Find (the sbf port) ---------------------------------------------------

(defun cmacs-secondbrain-ingest-find (query &optional k root)
  "Search the notes for QUERY; return up to K results as plists
\(:path :title :score :snippet).  Uses the brigade memory index when it
exists and falls back to ripgrep/grep over ROOT."
  (let* ((k (or k 10))
         (root (file-name-as-directory (expand-file-name (or root (cmacs-secondbrain-ingest-root))))))
    (or (and (cmacs-secondbrain-ingest--memory-index-p)
             (ignore-errors
               (mapcar (lambda (h)
                         (list :path (plist-get h :path)
                               :title (cmacs-secondbrain-ingest-file-title (plist-get h :path))
                               :score (plist-get h :score)
                               :snippet (cmacs-secondbrain-ingest-sample (or (plist-get h :text) "") 240)))
                       (seq-take (cmacs-brigade-memory-search query k) k))))
        (let* ((rg (or (executable-find "rg") (executable-find "grep")))
               (args (if (string-suffix-p "rg" rg)
                         (list "--files-with-matches" "--smart-case" "--glob" "*.org" "--" query root)
                       (list "-r" "-l" "-i" "--include=*.org" "--" query root)))
               (res (and rg (cmacs-secondbrain-ingest--run (cons rg args)))))
          (when (and res (member (car res) '(0 1)))
            (mapcar (lambda (path)
                      (list :path path :title (cmacs-secondbrain-ingest-file-title path)
                            :score nil :snippet nil))
                    (seq-take (split-string (cdr res) "\n" t) k)))))))

(defun cmacs-secondbrain-ingest-find-json (query &optional k)
  "`cmacs-secondbrain-ingest-find' as a JSON array string."
  (concat "[" (mapconcat #'cmacs-secondbrain-ingest--plist->json
                         (cmacs-secondbrain-ingest-find query k) ",")
          "]"))

;;;; Interactive commands ---------------------------------------------------

(defun cmacs-secondbrain-ingest--read-para ()
  "Read a PARA choice; empty means the configured default placement."
  (let ((c (completing-read "PARA (empty = detect/inbox per config): "
                            '("inbox" "projects" "areas" "resources" "detect") nil nil)))
    (and (not (string-empty-p c)) c)))

(defun cmacs-secondbrain-ingest--read-tags ()
  (let ((s (read-string "Tags (comma separated, empty for none): ")))
    (and (not (string-blank-p s)) s)))

;;;###autoload
(defun cmacs-secondbrain-ingest (input &optional para tags)
  "Ingest INPUT -- a file, directory or URL -- into the second brain.
Interactively prompts for the input, a PARA category and TAGS; with a
prefix argument also asks for the summary type and opens the queue."
  (interactive
   (list (let ((s (read-string "File, directory or URL: " nil nil (thing-at-point 'url t))))
           (if (cmacs-secondbrain-ingest-url-p s) s (expand-file-name s)))
         (cmacs-secondbrain-ingest--read-para)
         (cmacs-secondbrain-ingest--read-tags)))
  (let ((opts (delq nil (append (and para (list :para para)) (and tags (list :tags tags))
                                (and current-prefix-arg
                                     (list :type (intern (completing-read
                                                          "Summary type: "
                                                          (mapcar #'symbol-name (cmacs-secondbrain-ingest-summary-types))
                                                          nil t nil nil "auto"))))))))
    (let ((jobs (apply #'cmacs-secondbrain-ingest-run input opts)))
      (when (or current-prefix-arg (> (length jobs) 1)) (cmacs-secondbrain-ingest-queue))
      (message "sb ingest: queued %d job%s" (length jobs) (if (= (length jobs) 1) "" "s"))
      jobs)))

;;;###autoload
(defun cmacs-secondbrain-ingest-file (file &rest opts)
  "Ingest FILE with OPTS (see `cmacs-secondbrain-ingest-normalize-options')."
  (interactive (list (read-file-name "Ingest file: " nil nil t)))
  (apply #'cmacs-secondbrain-ingest-run file opts))

;;;###autoload
(defun cmacs-secondbrain-ingest-url (url &rest opts)
  "Ingest URL with OPTS."
  (interactive (list (read-string "Ingest URL: " (thing-at-point 'url t))))
  (unless (cmacs-secondbrain-ingest-url-p url) (user-error "%s is not an http(s) URL" url))
  (apply #'cmacs-secondbrain-ingest-run url opts))

;;;###autoload
(defun cmacs-secondbrain-ingest-region (beg end &optional para)
  "Ingest the text between BEG and END as a note.
The format (org, markdown, json, text) is guessed from the text and the
buffer's major mode."
  (interactive (list (region-beginning) (region-end) (cmacs-secondbrain-ingest--read-para)))
  (let ((text (buffer-substring-no-properties beg end))
        (fmt (pcase major-mode
               ('org-mode 'org) ('markdown-mode 'markdown) ('gfm-mode 'markdown)
               ('json-mode 'data) ('js-json-mode 'data) ('html-mode 'html)
               (_ nil))))
    (cmacs-secondbrain-ingest-run nil :text text :format fmt
                                  :source (or (buffer-file-name) (buffer-name))
                                  :title (and fmt (not (eq fmt 'org)) nil)
                                  :para para)))

;;;###autoload
(defun cmacs-secondbrain-ingest-buffer (&optional buffer para)
  "Ingest the whole of BUFFER (default: current) as a note."
  (interactive (list (current-buffer) (cmacs-secondbrain-ingest--read-para)))
  (with-current-buffer (or buffer (current-buffer))
    (cmacs-secondbrain-ingest-region (point-min) (point-max) para)))

;;;###autoload
(defun cmacs-secondbrain-ingest-clipboard (&optional para)
  "Ingest the clipboard: a URL is fetched, anything else is text.
The port of `clip2brain'."
  (interactive (list (cmacs-secondbrain-ingest--read-para)))
  (let ((text (or (ignore-errors (gui-get-selection 'CLIPBOARD 'UTF8_STRING))
                  (ignore-errors (current-kill 0 t)))))
    (when (or (null text) (string-blank-p text)) (user-error "the clipboard is empty"))
    (setq text (string-trim text))
    (if (cmacs-secondbrain-ingest-url-p text)
        (cmacs-secondbrain-ingest-run text :para para)
      (cmacs-secondbrain-ingest-run nil :text text :source "clipboard" :para para))))

;;;###autoload
(defun cmacs-secondbrain-ingest-dired (&optional para)
  "Ingest the marked files in Dired (or the file at point)."
  (interactive (list (cmacs-secondbrain-ingest--read-para)))
  (require 'dired)
  (let ((files (dired-get-marked-files)))
    (unless files (user-error "no files marked"))
    (cmacs-secondbrain-ingest-run files :para para)
    (cmacs-secondbrain-ingest-queue)))

(defvar cmacs-secondbrain-ingest--recording nil)

;;;###autoload
(defun cmacs-secondbrain-ingest-record (&optional para)
  "Record from the microphone; when stopped, transcribe and ingest the recording.
Call again (or `cmacs-secondbrain-ingest-record-stop') to stop.  The port
of `record_audio_and_ingest'."
  (interactive (list (cmacs-secondbrain-ingest--read-para)))
  (unless (fboundp 'cmacs-audio-record-to-file)
    (unless (require 'cmacs-audio nil t) (user-error "cmacs was built without --with-cmacs-audio")))
  (if cmacs-secondbrain-ingest--recording
      (cmacs-secondbrain-ingest-record-stop)
    (let ((path (expand-file-name (format-time-string "recording_%Y-%m-%d_%H-%M-%S.wav")
                                  (expand-file-name "~/Documents/recordings/"))))
      (cmacs-audio-record-to-file path)
      (setq cmacs-secondbrain-ingest--recording (cons path para))
      (message "sb ingest: recording -> %s; M-x cmacs-secondbrain-ingest-record-stop to finish" path))))

(defun cmacs-secondbrain-ingest-record-stop ()
  "Stop the recording started by `cmacs-secondbrain-ingest-record' and ingest it."
  (interactive)
  (unless cmacs-secondbrain-ingest--recording (user-error "no recording in progress"))
  (pcase-let ((`(,path . ,para) cmacs-secondbrain-ingest--recording))
    (setq cmacs-secondbrain-ingest--recording nil)
    (cmacs-audio-finish-recording)
    (cmacs-secondbrain-ingest-run path :para para :type 'meeting)))

;;;; The drop folder -----------------------------------------------------------
;;
;; A directory you save things into and forget about.  Two watchers feed
;; it: a podomation rule (inotify -> the editor over D-Bus, so it works
;; for a headless cmacs and survives the visualiser never being opened)
;; and Emacs's own `file-notify' for the case where podomation is not
;; running.  Both end up in `cmacs-secondbrain-ingest-drop', which is the
;; only place that decides what a dropped file means.
;;
;; A file that has just appeared is often still being written -- a
;; browser download, a scanner, `cp' of something large -- so the drop
;; handler waits until its size stops changing before it ingests.  Hidden
;; and partial names are ignored, and a file that has already been picked
;; up is not picked up twice when a second event fires for it.

(defcustom cmacs-secondbrain-ingest-drop-directory "~/Documents/inbox"
  "The drop folder: anything saved here is ingested.
Created on demand by `cmacs-secondbrain-ingest-watch-mode' and by the
podomation rule installer."
  :type 'directory
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-drop-options '(:para detect)
  "Options for every file the drop folder ingests, as a plist.
The keys of `cmacs-secondbrain-ingest-normalize-options'.  The default
lets the model place each note; `(:para inbox)' would only collect."
  :type 'sexp
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-drop-after 'move
  "What happens to a dropped file once its note is written.

`move' puts it in a `.ingested/' subdirectory of the drop folder, so the
folder stays a queue and nothing is lost; `trash' uses the system trash;
`keep' leaves it where it is (and it will not be ingested again until it
changes)."
  :type '(choice (const move) (const trash) (const keep))
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-drop-settle 2.0
  "Seconds a dropped file's size must hold still before it is read."
  :type 'number
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-drop-max-wait 300
  "Give up waiting for a dropped file to finish writing after this long."
  :type 'integer
  :group 'cmacs-secondbrain-ingest)

(defcustom cmacs-secondbrain-ingest-drop-ignore-regexp
  "\\`\\.\\|~\\'\\|\\.\\(?:part\\|crdownload\\|tmp\\|swp\\|download\\)\\'\\|\\`00_index\\.org\\'"
  "File names (not paths) matching this are never ingested from the drop folder.
Hidden files, editor backups and the partial-download names browsers use."
  :type 'regexp
  :group 'cmacs-secondbrain-ingest)

(defvar cmacs-secondbrain-ingest--drop-pending (make-hash-table :test 'equal)
  "PATH -> plist (:size :since :started) for files waiting to settle.")

(defun cmacs-secondbrain-ingest--drop-dir ()
  (file-name-as-directory (expand-file-name cmacs-secondbrain-ingest-drop-directory)))

(defun cmacs-secondbrain-ingest--drop-ignored-p (path)
  (or (string-match-p cmacs-secondbrain-ingest-drop-ignore-regexp (file-name-nondirectory path))
      (string-match-p "/\\.ingested/" path)))

(defun cmacs-secondbrain-ingest-drop (path)
  "Ingest PATH, which just appeared in a drop folder, once it stops changing.
Safe to call more than once for the same PATH.  Returns non-nil when the
file was accepted for ingestion."
  (let ((path (expand-file-name path)))
    (cond
     ((cmacs-secondbrain-ingest--drop-ignored-p path) nil)
     ((not (file-regular-p path)) nil)
     ((gethash path cmacs-secondbrain-ingest--drop-pending) t)
     (t
      (puthash path (list :size -1 :since (float-time) :started (float-time))
               cmacs-secondbrain-ingest--drop-pending)
      (cmacs-secondbrain-ingest--log nil "drop: %s appeared" (abbreviate-file-name path))
      (cmacs-secondbrain-ingest--drop-poll path)
      t))))

(defun cmacs-secondbrain-ingest--drop-poll (path)
  "Check whether PATH has stopped growing; ingest it when it has."
  (let ((st (gethash path cmacs-secondbrain-ingest--drop-pending)))
    (when st
      (let* ((attrs (file-attributes path))
             (size (and attrs (file-attribute-size attrs)))
             (now (float-time)))
        (cond
         ((null attrs)
          ;; Gone before it settled -- renamed away or deleted.
          (remhash path cmacs-secondbrain-ingest--drop-pending))
         ((/= size (plist-get st :size))
          (plist-put st :size size)
          (plist-put st :since now)
          (run-at-time cmacs-secondbrain-ingest-drop-settle nil
                       #'cmacs-secondbrain-ingest--drop-poll path))
         ((and (>= (- now (plist-get st :since)) cmacs-secondbrain-ingest-drop-settle)
               (> size 0))
          (remhash path cmacs-secondbrain-ingest--drop-pending)
          (cmacs-secondbrain-ingest--drop-ingest path))
         ((> (- now (plist-get st :started)) cmacs-secondbrain-ingest-drop-max-wait)
          (remhash path cmacs-secondbrain-ingest--drop-pending)
          (cmacs-secondbrain-ingest--log nil "drop: gave up waiting for %s" path))
         (t (run-at-time cmacs-secondbrain-ingest-drop-settle nil
                         #'cmacs-secondbrain-ingest--drop-poll path)))))))

(defun cmacs-secondbrain-ingest--drop-url-file (path)
  "If PATH is a small text file holding one URL, return the URL."
  (when (and (member (downcase (or (file-name-extension path) "")) '("url" "txt" "webloc" ""))
             (< (file-attribute-size (file-attributes path)) 4096))
    (let ((text (string-trim (with-temp-buffer (insert-file-contents path) (buffer-string)))))
      (cond ((cmacs-secondbrain-ingest-url-p text) text)
            ;; A Windows/GNOME .url file: URL=... on one of its lines.
            ((string-match "^URL=\\(https?://[^\n]+\\)" text) (match-string 1 text))))))

(defun cmacs-secondbrain-ingest--drop-ingest (path)
  "Queue PATH (or the URL it names) with the drop options; tidy it afterwards."
  (let* ((url (ignore-errors (cmacs-secondbrain-ingest--drop-url-file path)))
         (opts (append cmacs-secondbrain-ingest-drop-options
                       (list :callback (lambda (job) (cmacs-secondbrain-ingest--drop-finished job path))))))
    (condition-case err
        (progn
          (cmacs-secondbrain-ingest--log nil "drop: ingesting %s%s" (abbreviate-file-name path)
                                         (if url (format " (URL %s)" url) ""))
          (apply #'cmacs-secondbrain-ingest-run (or url path) opts))
      (error (cmacs-secondbrain-ingest--log nil "drop: %s: %s" path (error-message-string err))))))

(defun cmacs-secondbrain-ingest--drop-finished (job path)
  "After JOB for dropped PATH ends, move, trash or keep the original."
  (when (and (eq (cmacs-secondbrain-ingest-job-stage job) 'done)
             (file-exists-p path))
    (pcase cmacs-secondbrain-ingest-drop-after
      ('move
       (let ((dest (expand-file-name (file-name-nondirectory path)
                                     (expand-file-name ".ingested" (file-name-directory path)))))
         (make-directory (file-name-directory dest) t)
         (when (file-exists-p dest)
           (setq dest (concat dest "." (format-time-string "%Y%m%d%H%M%S"))))
         (ignore-errors (rename-file path dest))))
      ('trash (ignore-errors (move-file-to-trash path)))
      (_ nil))))

;;;;; Emacs's own watcher

(defvar cmacs-secondbrain-ingest--watch-descriptor nil)

(defun cmacs-secondbrain-ingest--watch-event (event)
  "Handle a `file-notify' EVENT on the drop folder."
  (pcase-let ((`(,_desc ,action ,file . ,rest) event))
    (pcase action
      ((or 'created 'changed)
       (cmacs-secondbrain-ingest-drop file))
      ('renamed
       ;; A move INTO the folder arrives as a rename whose new name is
       ;; inside it; the first arg is the old name.
       (let ((new (car rest)))
         (when (and new (string-prefix-p (cmacs-secondbrain-ingest--drop-dir) (expand-file-name new)))
           (cmacs-secondbrain-ingest-drop new))))
      (_ nil))))

(defun cmacs-secondbrain-ingest-drop-sweep ()
  "Ingest whatever is already sitting in the drop folder."
  (interactive)
  (let ((dir (cmacs-secondbrain-ingest--drop-dir)) (n 0))
    (when (file-directory-p dir)
      (dolist (f (directory-files dir t "\\`[^.]" t))
        (when (and (file-regular-p f) (cmacs-secondbrain-ingest-drop f))
          (cl-incf n))))
    (message "sb ingest: %d file%s picked up from %s" n (if (= n 1) "" "s")
             (abbreviate-file-name dir))
    n))

;;;###autoload
(define-minor-mode cmacs-secondbrain-ingest-watch-mode
  "Watch `cmacs-secondbrain-ingest-drop-directory' and ingest whatever lands in it.

Uses Emacs's `file-notify'.  This is the watcher for a session without
podomation; with podomation running, install the rule from
`cmacs-secondbrain-ingest-podomation-rule' instead (or as well -- the
drop handler ignores a file it has already picked up).  Turning the mode
on also sweeps what is already in the folder."
  :global t
  :group 'cmacs-secondbrain-ingest
  (when cmacs-secondbrain-ingest--watch-descriptor
    (ignore-errors (file-notify-rm-watch cmacs-secondbrain-ingest--watch-descriptor))
    (setq cmacs-secondbrain-ingest--watch-descriptor nil))
  (when cmacs-secondbrain-ingest-watch-mode
    (let ((dir (cmacs-secondbrain-ingest--drop-dir)))
      (make-directory dir t)
      (setq cmacs-secondbrain-ingest--watch-descriptor
            (file-notify-add-watch dir '(change) #'cmacs-secondbrain-ingest--watch-event))
      (cmacs-secondbrain-ingest-drop-sweep))))

;;;;; The podomation rule

(defcustom cmacs-secondbrain-ingest-podomation-instance nil
  "D-Bus name of the cmacs the podomation rule should drive.
nil targets THIS instance by its per-PID name, which is right for an
in-process engine; \"org.cmacs.Editor\" targets whichever instance owns
the well-known name, which is right for a standalone podomation daemon."
  :type '(choice (const :tag "This instance" nil) string)
  :group 'cmacs-secondbrain-ingest)

(defun cmacs-secondbrain-ingest-podomation-rule (&optional dir instance)
  "Return the podomation DSL for a drop-folder rule watching DIR.

The rule fires `cmacs-secondbrain-ingest-drop' in INSTANCE (a D-Bus
name; default per `cmacs-secondbrain-ingest-podomation-instance') for
every file created in or moved into DIR.  The Elisp side does the
filtering and the settle wait, so the rule itself stays one line per
event and needs no DSL string matching."
  (let* ((dir (directory-file-name (expand-file-name (or dir cmacs-secondbrain-ingest-drop-directory))))
         (instance (or instance cmacs-secondbrain-ingest-podomation-instance
                       (format "org.cmacs.Editor.Pid%d" (emacs-pid))))
         (q (lambda (s) (replace-regexp-in-string "\"" "\\\\\"" s))))
    (concat
     "# Second-brain drop folder: anything saved here becomes an Org note.\n"
     "# Generated by cmacs-secondbrain-ingest-podomation-rule; the filtering,\n"
     "# settle wait and tidy-up live in Elisp (cmacs-secondbrain-ingest-drop).\n"
     (format "pod sb_drop = inotify_event->new(\"%s\");\n" (funcall q dir))
     (format "pod sb_editor = cmacs->new(\"%s\");\n" (funcall q instance))
     "sb_drop->on_create => sb_editor->eval(\"(cmacs-secondbrain-ingest-drop \\\"{event->path}\\\")\");\n"
     "sb_drop->on_move   => sb_editor->eval(\"(cmacs-secondbrain-ingest-drop \\\"{event->other_path}\\\")\");\n"
     "sb_drop->on_modify => sb_editor->eval(\"(cmacs-secondbrain-ingest-drop \\\"{event->path}\\\")\");\n")))

(declare-function cmacs-podomation-running-p "cmacs-podomation.c" ())
(declare-function cmacs-podomation-start "cmacs-podomation.c" ())
(declare-function cmacs-podomation-eval-dsl "cmacs-podomation.c" (dsl))

;;;###autoload
(defun cmacs-secondbrain-ingest-podomation-install (&optional dir)
  "Install the drop-folder rule into the running podomation engine.
Starts the engine if it is not running and creates DIR (default
`cmacs-secondbrain-ingest-drop-directory').  Returns the DSL loaded.
Interactively, with a prefix argument, only shows the rule."
  (interactive (list nil))
  (let ((dsl (cmacs-secondbrain-ingest-podomation-rule dir)))
    (if current-prefix-arg
        (with-current-buffer (get-buffer-create "*second brain: podomation rule*")
          (erase-buffer) (insert dsl) (pop-to-buffer (current-buffer)))
      (unless (fboundp 'cmacs-podomation-eval-dsl)
        (user-error "cmacs was built without --with-cmacs-podomation"))
      (make-directory (cmacs-secondbrain-ingest--drop-dir) t)
      (unless (cmacs-podomation-running-p) (cmacs-podomation-start))
      (cmacs-podomation-eval-dsl dsl)
      (message "sb ingest: podomation is watching %s"
               (abbreviate-file-name (cmacs-secondbrain-ingest--drop-dir))))
    dsl))

;;;; The queue buffer -------------------------------------------------------

(defun cmacs-secondbrain-ingest--stage-icon (stage)
  (pcase stage
    ('queued "·") ('done "✓") ('failed "✗") ('cancelled "⊘") ('reviewing "?") (_ "▶")))

(defun cmacs-secondbrain-ingest--render ()
  "Redraw the queue buffer if it exists."
  (let ((buf (get-buffer cmacs-secondbrain-ingest-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (line (line-number-at-pos)))
          (erase-buffer)
          (insert (propertize "Second brain ingest\n" 'face 'bold))
          (insert (format "  provider %s/%s   placement %s   summaries %s   parallel %d   root %s\n\n"
                          cmacs-secondbrain-ingest-provider (or cmacs-secondbrain-ingest-model "default")
                          cmacs-secondbrain-ingest-placement
                          (if cmacs-secondbrain-ingest-summarize "on" "off")
                          cmacs-secondbrain-ingest-parallel-jobs
                          (abbreviate-file-name (cmacs-secondbrain-ingest-root))))
          (if (null cmacs-secondbrain-ingest--jobs)
              (insert "  Nothing queued.  a: add file   u: add URL   p: paste clipboard   ?: help\n")
            (dolist (job cmacs-secondbrain-ingest--jobs)
              (let* ((stage (cmacs-secondbrain-ingest-job-stage job))
                     (face (pcase stage ('done 'success) ('failed 'error) ('cancelled 'shadow)
                                  ('queued 'shadow) (_ 'warning))))
                (insert (propertize
                         (format "  %s %-8s %-11s %s\n"
                                 (cmacs-secondbrain-ingest--stage-icon stage)
                                 (cmacs-secondbrain-ingest-job-id job)
                                 stage
                                 (cmacs-secondbrain-ingest-sample
                                  (or (cmacs-secondbrain-ingest-job-title job)
                                      (cmacs-secondbrain-ingest-job-input job))
                                  80))
                         'face face 'cmacs-secondbrain-ingest-job job))
                (let ((detail (pcase stage
                                ('done (and (cmacs-secondbrain-ingest-job-note-file job)
                                            (abbreviate-file-name (cmacs-secondbrain-ingest-job-note-file job))))
                                ('failed (cmacs-secondbrain-ingest-job-error job))
                                (_ (cmacs-secondbrain-ingest-job-progress job)))))
                  (when (and detail (not (string-empty-p detail)))
                    (insert (propertize (format "             %s\n" (cmacs-secondbrain-ingest-sample detail 120))
                                        'face 'shadow 'cmacs-secondbrain-ingest-job job)))))))
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun cmacs-secondbrain-ingest--job-at-point ()
  (or (get-text-property (point) 'cmacs-secondbrain-ingest-job)
      (user-error "no job on this line")))

(defun cmacs-secondbrain-ingest-queue-add-file (file)
  "Queue FILE from the queue buffer."
  (interactive (list (read-file-name "Add file or directory: " nil nil t)))
  (cmacs-secondbrain-ingest-run file))

(defun cmacs-secondbrain-ingest-queue-add-url (url)
  "Queue URL from the queue buffer."
  (interactive (list (read-string "Add URL: ")))
  (cmacs-secondbrain-ingest-url url))

(defun cmacs-secondbrain-ingest-queue-cancel ()
  "Cancel the job at point."
  (interactive)
  (cmacs-secondbrain-ingest-cancel (cmacs-secondbrain-ingest--job-at-point)))

(defun cmacs-secondbrain-ingest-queue-remove ()
  "Forget the finished job at point."
  (interactive)
  (let ((job (cmacs-secondbrain-ingest--job-at-point)))
    (unless (cmacs-secondbrain-ingest--finished-p job) (user-error "cancel it first (k)"))
    (setq cmacs-secondbrain-ingest--jobs (delq job cmacs-secondbrain-ingest--jobs))
    (cmacs-secondbrain-ingest--render)))

(defun cmacs-secondbrain-ingest-queue-clear ()
  "Forget every finished job."
  (interactive)
  (setq cmacs-secondbrain-ingest--jobs
        (cl-remove-if #'cmacs-secondbrain-ingest--finished-p cmacs-secondbrain-ingest--jobs))
  (cmacs-secondbrain-ingest--render))

(defun cmacs-secondbrain-ingest-queue-visit (&optional other-window)
  "Open the note written by the job at point."
  (interactive "P")
  (let* ((job (cmacs-secondbrain-ingest--job-at-point))
         (file (cmacs-secondbrain-ingest-job-note-file job)))
    (unless file (user-error "no note yet"))
    (if other-window (find-file-other-window file) (find-file file))))

(defun cmacs-secondbrain-ingest-queue-log ()
  "Show the log of the job at point."
  (interactive)
  (let ((job (cmacs-secondbrain-ingest--job-at-point)))
    (with-current-buffer (get-buffer-create (format "*second brain: log %s*" (cmacs-secondbrain-ingest-job-id job)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (string-join (reverse (cmacs-secondbrain-ingest-job-log job)) "\n") "\n")
        (special-mode))
      (pop-to-buffer (current-buffer)))))

(defun cmacs-secondbrain-ingest-queue-retry ()
  "Queue the failed job at point again with the same options."
  (interactive)
  (let ((job (cmacs-secondbrain-ingest--job-at-point)))
    (unless (memq (cmacs-secondbrain-ingest-job-stage job) '(failed cancelled))
      (user-error "only a failed or cancelled job can be retried"))
    (let ((opts (cl-copy-list (cmacs-secondbrain-ingest-job-options job))))
      (setq opts (plist-put opts :started nil))
      (apply #'cmacs-secondbrain-ingest-enqueue (cmacs-secondbrain-ingest-job-input job)
             :start t opts))))

(defun cmacs-secondbrain-ingest-queue-toggle-summaries ()
  "Toggle AI summaries for jobs queued from now on."
  (interactive)
  (setq cmacs-secondbrain-ingest-summarize (not cmacs-secondbrain-ingest-summarize))
  (cmacs-secondbrain-ingest--render))

(defun cmacs-secondbrain-ingest-queue-toggle-placement ()
  "Toggle between model placement and the inbox."
  (interactive)
  (setq cmacs-secondbrain-ingest-placement
        (if (eq cmacs-secondbrain-ingest-placement 'detect) 'inbox 'detect))
  (cmacs-secondbrain-ingest--render))

(defun cmacs-secondbrain-ingest-queue-doctor ()
  "Show which programs and features the ingester can use."
  (interactive)
  (with-current-buffer (get-buffer-create "*second brain: ingest doctor*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dolist (e (cmacs-secondbrain-ingest-doctor))
        (insert (format "  %s %-14s %s\n" (if (nth 1 e) "✓" "✗") (nth 0 e) (nth 2 e))))
      (special-mode))
    (pop-to-buffer (current-buffer))))

(defun cmacs-secondbrain-ingest-queue-help ()
  "Describe the queue keys."
  (interactive)
  (message "a add file  u add URL  p clipboard  RET visit  o visit other  l log  k cancel  r retry  d remove  D clear  s summaries  P placement  w watch drop folder  ! doctor  g refresh  q quit"))

(defvar cmacs-secondbrain-ingest-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m "a" #'cmacs-secondbrain-ingest-queue-add-file)
    (define-key m "u" #'cmacs-secondbrain-ingest-queue-add-url)
    (define-key m "p" #'cmacs-secondbrain-ingest-clipboard)
    (define-key m (kbd "RET") #'cmacs-secondbrain-ingest-queue-visit)
    (define-key m "o" (lambda () (interactive) (cmacs-secondbrain-ingest-queue-visit t)))
    (define-key m "l" #'cmacs-secondbrain-ingest-queue-log)
    (define-key m "k" #'cmacs-secondbrain-ingest-queue-cancel)
    (define-key m "r" #'cmacs-secondbrain-ingest-queue-retry)
    (define-key m "d" #'cmacs-secondbrain-ingest-queue-remove)
    (define-key m "D" #'cmacs-secondbrain-ingest-queue-clear)
    (define-key m "s" #'cmacs-secondbrain-ingest-queue-toggle-summaries)
    (define-key m "P" #'cmacs-secondbrain-ingest-queue-toggle-placement)
    (define-key m "!" #'cmacs-secondbrain-ingest-queue-doctor)
    (define-key m "w" #'cmacs-secondbrain-ingest-watch-mode)
    (define-key m "g" (lambda () (interactive) (cmacs-secondbrain-ingest--render)))
    (define-key m "?" #'cmacs-secondbrain-ingest-queue-help)
    m)
  "Keys in the ingest queue buffer.")

(define-derived-mode cmacs-secondbrain-ingest-mode special-mode "sb-ingest"
  "The second-brain ingest queue."
  (setq-local truncate-lines t))

(when (require 'cmacs-evil nil t)
  (when (fboundp 'cmacs-evil-setup-mode-map)
    (cmacs-evil-setup-mode-map cmacs-secondbrain-ingest-mode-map 'cmacs-secondbrain-ingest-mode)))

;;;###autoload
(defun cmacs-secondbrain-ingest-queue ()
  "Show the ingest queue."
  (interactive)
  (let ((buf (get-buffer-create cmacs-secondbrain-ingest-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-secondbrain-ingest-mode)
        (cmacs-secondbrain-ingest-mode)))
    (cmacs-secondbrain-ingest--render)
    (pop-to-buffer buf)))

;; The visualiser gets an `I' for the front door.
(with-eval-after-load 'cmacs-secondbrain
  (when (boundp 'cmacs-secondbrain-mode-map)
    (define-key cmacs-secondbrain-mode-map "I" #'cmacs-secondbrain-ingest)))

(provide 'cmacs-secondbrain-ingest)
;;; cmacs-secondbrain-ingest.el ends here
