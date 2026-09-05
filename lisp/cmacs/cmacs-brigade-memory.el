;;; cmacs-brigade-memory.el --- The brigade memory index  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Semantic search over your own corpora, so an agent can answer "what
;; did I decide about X" from your notes instead of guessing.
;;
;; The notes repository is the source of truth and the index is a
;; disposable derivative -- delete it and rebuild, nothing is lost.  That
;; is deliberate: an index that is authoritative for anything becomes a
;; thing you have to back up, migrate and trust.
;;
;; Corpora are pluggable.  `cmacs-brigade-register-memory-source' takes
;; an `enumerate' and a `read-chunk' function, so a Postgres table, a
;; code tree or an IMAP folder joins the same index and every agent's
;; `memory_search' covers it with no further work.  The shipped `org'
;; source is registered through that same public API, not around it.
;;
;; Retrieval is hybrid.  Pure cosine loses badly to grep on exact
;; identifiers -- a search for a ticket number or an unusual surname is a
;; lexical question, not a semantic one -- so a ripgrep pass runs
;; alongside the vector scan and the two rankings are fused.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)
(require 'subr-x)
(require 'json)

;;;; Options

(defcustom cmacs-brigade-memory-enabled nil
  "Whether the memory index is used and kept up to date.

Off by default, and deliberately so: the first build of a large notes
repository embeds every chunk, which on a local model takes hours.  That
is a fine thing to ask for and a terrible thing to inflict on someone who
merely installed a new cmacs.  Turn it on, then run
\\[cmacs-brigade-memory-build]."
  :type 'boolean
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-memory-roots
  (list (list :path "~/Documents/notes" :kind 'org
              :exclude '("/.git/" "/04_archives/")))
  "Corpora to index, as a list of plists.

Each entry accepts:

  :path     directory to walk
  :kind     source name, matching a registered memory source
  :exclude  list of substrings; a path containing one is skipped
  :glob     file name regexp (defaults to the source's own)

The shipped default points at a notes repository laid out in PARA, which
is where the author keeps theirs.  It is a default, not an assumption --
point it anywhere, or at several places."
  :type '(repeat plist)
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-memory-index-dir
  (expand-file-name "memory" cmacs-brigade-state-dir)
  "Directory holding the vector index.
Disposable: delete it and rebuild."
  :type 'directory
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-embed-endpoint "http://localhost:11434"
  "Base URL of the embedding service (an Ollama-compatible API)."
  :type 'string
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-embed-backend 'ai-glib
  "How chunks and queries reach the embedding service.

`ai-glib' calls `cmacs-ai-embed-async', ai-glib\='s AiEmbedder
interface, in process.  `curl' posts JSON with the curl binary, which
is what this did before ai-glib served embeddings.

They are interchangeable: both speak the same /api/embed endpoint to
the same model, so vectors from one are valid in an index built by the
other and switching does not require a rebuild.  ai-glib is preferred
because it drops the curl dependency and the temporary request files,
reports real errors instead of an exit status, and can be cancelled.

Falls back to `curl' automatically when cmacs was built without
--with-cmacs-ai, so this stays correct on a build with no AI support."
  :type '(choice (const :tag "ai-glib (in process)" ai-glib)
                 (const :tag "curl subprocess" curl))
  :group 'cmacs-brigade-memory)

(defun cmacs-brigade-memory--embed-backend ()
  "Return the embedding backend actually usable in this build."
  (if (and (eq cmacs-brigade-embed-backend 'ai-glib)
           (fboundp 'cmacs-ai-embed-async))
      'ai-glib
    'curl))

(defun cmacs-brigade-memory--embed-sync-ai-glib (texts)
  "Embed TEXTS through ai-glib, blocking.  Returns a list of vectors."
  (cmacs-brigade-memory--embed-apply-endpoint)
  (condition-case err
      (cmacs-ai-embed texts 'ollama cmacs-brigade-embed-model)
    (error
     (signal 'cmacs-brigade-embed-error (list (error-message-string err))))))

(defun cmacs-brigade-memory--embed-apply-endpoint ()
  "Point ai-glib\='s ollama client at `cmacs-brigade-embed-endpoint'.

ai-glib reads the base URL from its own AiConfig singleton, which knows
nothing about this package\='s defcustom.  Without this the endpoint
setting would silently stop working the moment the backend changed."
  (when (fboundp 'cmacs-ai-config-set-base-url)
    (cmacs-ai-config-set-base-url
     'ollama (string-remove-suffix "/" cmacs-brigade-embed-endpoint))))

(defun cmacs-brigade-memory--embed-async-ai-glib (texts on-ok on-error)
  "Embed TEXTS through ai-glib, without blocking.
Returns the integer request id, which `cmacs-brigade-memory-build-cancel'
passes to `cmacs-ai-embed-cancel'."
  (cmacs-brigade-memory--embed-apply-endpoint)
  (cmacs-ai-embed-async
   texts
   (lambda (reply)
     (pcase reply
       (`(:ok ,vectors)
        ;; As in the curl sentinel: an error raised by ON-OK is the
        ;; caller's problem, but it must not escape this callback, or
        ;; the build stops with nothing said.
        (condition-case err
            (funcall on-ok vectors)
          (error (funcall on-error (error-message-string err)))))
       (`(:cancelled) nil)          ; asked for; not a failure to report
       (`(:error ,msg) (funcall on-error msg))
       (_ (funcall on-error (format "unexpected embed reply: %S" reply)))))
   'ollama
   cmacs-brigade-embed-model))

(defcustom cmacs-brigade-embed-model "nomic-embed-text:v1.5"
  "Model used to embed chunks and queries.

Changing this invalidates the index: vectors from two models occupy
different spaces and comparing them yields confident nonsense.  The model
name is recorded in the manifest and a mismatch forces a rebuild rather
than silently mixing them."
  :type 'string
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-embed-dim 768
  "Dimensionality of `cmacs-brigade-embed-model' output."
  :type 'integer
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-embed-batch 32
  "How many chunks to embed per request.

Measured on the author's machine, batching to 32 is about 45% faster than
one-at-a-time, while running several requests concurrently is *slower*
than one at a time -- the server serialises embedding work, so
concurrency buys nothing and costs scheduler overhead.  One request in
flight, batched."
  :type 'integer
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-embed-query-prefix "search_query: "
  "String prepended to a query before embedding.

Asymmetric-retrieval models are trained with distinct prefixes for
queries and documents, and omitting them costs recall silently -- results
still come back, just worse.  Both are options because another model
wants different ones, or none."
  :type 'string
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-embed-document-prefix "search_document: "
  "String prepended to a chunk before embedding.
See `cmacs-brigade-embed-query-prefix'."
  :type 'string
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-chunk-target-bytes 1400
  "Soft chunk size in bytes.

The single biggest lever on retrieval quality.  Smaller chunks are more
precise and more numerous; larger ones keep an argument together but
dilute it.  Recorded in the manifest so a change is visible as an index
mismatch rather than as unexplained drift in result quality."
  :type 'integer
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-chunk-overlap 200
  "Bytes of the previous chunk repeated at the head of a split one."
  :type 'integer
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-memory-max-file-bytes (* 2 1024 1024)
  "Files larger than this are skipped and logged."
  :type 'integer
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-memory-lexical-program "rg"
  "Program used for the lexical half of hybrid retrieval.
Set to nil to disable the lexical pass."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-memory-rrf-k 60
  "Constant in the reciprocal-rank fusion score, 1/(k + rank).

Larger values flatten the contribution of rank, so a result has to appear
in both lists to win rather than merely place highly in one.  60 is the
value from the original RRF paper and works well here."
  :type 'integer
  :group 'cmacs-brigade-memory)


;;;; Manifest
;;
;; Plain elisp data on disk, readable with `read'.  A binary manifest
;; would save nothing and cost the ability to look at it when something
;; is wrong.

(defun cmacs-brigade-memory--manifest-file ()
  (expand-file-name "manifest.eld" cmacs-brigade-memory-index-dir))

(defun cmacs-brigade-memory-manifest ()
  "Return the index manifest as a plist, or nil if there is none."
  (let ((f (cmacs-brigade-memory--manifest-file)))
    (when (file-readable-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (condition-case nil (read (current-buffer)) (error nil))))))

(defun cmacs-brigade-memory--write-manifest (plist)
  (make-directory cmacs-brigade-memory-index-dir t)
  (with-temp-file (cmacs-brigade-memory--manifest-file)
    (let ((print-length nil) (print-level nil))
      (prin1 plist (current-buffer))
      (insert "\n"))))

(defun cmacs-brigade-memory--manifest-matches-p (m)
  "Return non-nil when manifest M was built the way we would build now.

A mismatch is not a warning, it is a rebuild: vectors from a different
model or a different chunk size are not merely stale, they are
incomparable."
  (and m
       (equal (plist-get m :model) cmacs-brigade-embed-model)
       (equal (plist-get m :dim) cmacs-brigade-embed-dim)
       (equal (plist-get m :chunk-target) cmacs-brigade-chunk-target-bytes)))


;;;; Embedding

(define-error 'cmacs-brigade-embed-error
  "Embedding request failed" 'cmacs-brigade-error)

(defun cmacs-brigade-memory--embed-url ()
  (concat (string-remove-suffix "/" cmacs-brigade-embed-endpoint) "/api/embed"))

(defun cmacs-brigade-memory--embed-payload-file (texts)
  "Write the request body for TEXTS to a temporary file and return it.

Through a file rather than an argument because a batch of 32 chunks is
tens of kilobytes of JSON, which is a long way past what belongs on a
command line."
  (let ((tmp (make-temp-file "cmacs-brigade-embed" nil ".json"))
        (coding-system-for-write 'utf-8))
    (with-temp-file tmp
      (insert (json-serialize (list :model cmacs-brigade-embed-model
                                    :input (vconcat texts)))))
    tmp))

(defun cmacs-brigade-memory--embed-argv (tmp)
  "The curl command line posting TMP to the embedding endpoint."
  (list "curl" "-sS" "--max-time" "300"
        "-H" "Content-Type: application/json"
        "--data-binary" (concat "@" tmp)
        (cmacs-brigade-memory--embed-url)))

(defun cmacs-brigade-memory--embed-parse (buffer)
  "Return the vectors in BUFFER's embedding reply, or signal."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let* ((reply (condition-case err
                      (json-parse-buffer :object-type 'plist
                                         :array-type 'list)
                    (error
                     (signal 'cmacs-brigade-embed-error
                             (list "unparseable reply"
                                   (error-message-string err))))))
           (embeddings (plist-get reply :embeddings)))
      (unless embeddings
        (signal 'cmacs-brigade-embed-error
                (list (or (plist-get reply :error)
                          "no embeddings in reply"))))
      (mapcar #'vconcat embeddings))))

(cl-defun cmacs-brigade-memory--embed (texts)
  "Embed TEXTS, a list of strings, and return a list of vectors.

Synchronous, and therefore only for a single query: this blocks Emacs
for as long as the server takes.  Indexing uses
`cmacs-brigade-memory--embed-async', which does not.

Routes through `cmacs-brigade-embed-backend'."
  (unless texts (cl-return-from cmacs-brigade-memory--embed nil))
  (if (eq (cmacs-brigade-memory--embed-backend) 'ai-glib)
      (cmacs-brigade-memory--embed-sync-ai-glib texts)
    (cmacs-brigade-memory--embed-curl texts)))

(cl-defun cmacs-brigade-memory--embed-curl (texts)
  "Embed TEXTS by posting JSON with the curl binary."
  (unless texts (cl-return-from cmacs-brigade-memory--embed-curl nil))
  (let ((tmp (cmacs-brigade-memory--embed-payload-file texts))
        (out (generate-new-buffer " *brigade-embed*")))
    (unwind-protect
        (let ((status (apply #'call-process (car (cmacs-brigade-memory--embed-argv tmp))
                             nil out nil
                             (cdr (cmacs-brigade-memory--embed-argv tmp)))))
          (unless (eq status 0)
            (signal 'cmacs-brigade-embed-error
                    (list (format "curl exited %s talking to %s" status
                                  (cmacs-brigade-memory--embed-url)))))
          (cmacs-brigade-memory--embed-parse out))
      (delete-file tmp)
      (kill-buffer out))))

(defun cmacs-brigade-memory--embed-async (texts on-ok on-error)
  "Embed TEXTS, calling ON-OK with the vectors or ON-ERROR with a message.

Routes through `cmacs-brigade-embed-backend'.  Returns a handle for
`cmacs-brigade-memory--embed-abort': a process for the curl backend, an
integer request id for ai-glib."
  (if (eq (cmacs-brigade-memory--embed-backend) 'ai-glib)
      (cmacs-brigade-memory--embed-async-ai-glib texts on-ok on-error)
    (cmacs-brigade-memory--embed-async-curl texts on-ok on-error)))

(defun cmacs-brigade-memory--embed-abort (handle)
  "Abandon the in-flight embed HANDLE, whichever backend produced it."
  (cond
   ((null handle) nil)
   ((processp handle) (when (process-live-p handle) (delete-process handle)))
   ((integerp handle) (when (fboundp 'cmacs-ai-embed-cancel)
                        (cmacs-ai-embed-cancel handle)))))

(defun cmacs-brigade-memory--embed-async-curl (texts on-ok on-error)
  "Embed TEXTS with a curl subprocess.

Returns the process.  The whole reason indexing does not halt Emacs: a
thread would not have helped, because a thread sitting in `call-process'
holds the global Lisp lock and the main thread cannot run at all until it
returns.  Waiting on a process object releases it."
  (let* ((tmp (cmacs-brigade-memory--embed-payload-file texts))
         (out (generate-new-buffer " *brigade-embed*")))
    (make-process
     :name "brigade-embed"
     :buffer out
     :noquery t
     :connection-type 'pipe
     :command (cmacs-brigade-memory--embed-argv tmp)
     :sentinel
     (lambda (proc _event)
       (unless (process-live-p proc)
         (let ((status (process-exit-status proc)))
           (unwind-protect
               (if (not (eq status 0))
                   (funcall on-error
                            (format "curl exited %s talking to %s" status
                                    (cmacs-brigade-memory--embed-url)))
                 (condition-case err
                     (funcall on-ok (cmacs-brigade-memory--embed-parse out))
                   ;; An error raised by ON-OK itself is the caller's
                   ;; problem, but it must not escape a sentinel -- an
                   ;; error there is swallowed by the command loop and
                   ;; the build would simply stop, silently.
                   (error (funcall on-error (error-message-string err)))))
             (ignore-errors (delete-file tmp))
             (when (buffer-live-p out) (kill-buffer out)))))))))

(defun cmacs-brigade-memory-embed-query (text)
  "Embed TEXT as a query and return one vector."
  (car (cmacs-brigade-memory--embed
        (list (concat cmacs-brigade-embed-query-prefix text)))))


;;;; Sources
;;
;; Registered through the same public API a user would use.

(defun cmacs-brigade-memory--org-enumerate (root)
  "Return the org files under ROOT's :path, honouring :exclude."
  (let* ((path (expand-file-name (plist-get root :path)))
         (glob (or (plist-get root :glob) "\\.org\\'"))
         (excl (plist-get root :exclude)))
    (when (file-directory-p path)
      (cl-remove-if
       (lambda (f)
         (or (cl-some (lambda (e) (string-search e f)) excl)
             (> (or (file-attribute-size (file-attributes f)) 0)
                cmacs-brigade-memory-max-file-bytes)))
       (directory-files-recursively path glob)))))

(defun cmacs-brigade-memory--org-read-chunks (file)
  "Return FILE's chunks as plists, via the C chunker."
  (when (file-readable-p file)
    (let ((text (with-temp-buffer
                  (insert-file-contents file)
                  (buffer-substring-no-properties (point-min) (point-max)))))
      (cmacs-brigade-chunk-string
       text
       ;; Relative to the root so a breadcrumb reads
       ;; "02_areas/finance/plan.org > Decisions" rather than repeating
       ;; a long absolute prefix in every single chunk.
       (cmacs-brigade-memory--display-path file)
       cmacs-brigade-chunk-target-bytes
       cmacs-brigade-chunk-overlap))))

(defun cmacs-brigade-memory--display-path (file)
  "Return FILE relative to whichever configured root contains it."
  (let ((best file))
    (dolist (root cmacs-brigade-memory-roots)
      (let ((p (file-name-as-directory
                (expand-file-name (plist-get root :path)))))
        (when (string-prefix-p p file)
          (setq best (substring file (length p))))))
    best))

(cmacs-brigade-register-memory-source
 :name 'org :kind 'org
 :enumerate #'cmacs-brigade-memory--org-enumerate
 :read-chunk #'cmacs-brigade-memory--org-read-chunks)


;;;; Build
;;
;; State is a sidecar so a build can resume.  A full first build of a
;; large corpus runs for hours; losing it to a restart would mean nobody
;; ever finishes one.

(defvar cmacs-brigade-memory--build nil
  "Plist describing an in-progress build, or nil.

Keys: :writer :catalog :pending :file :meta :nfiles :fileno :total :t0
:last-report :proc.  Read and written from a process sentinel as well as
from commands, which is why every access goes through
`cmacs-brigade-memory--bget' and `-bset'.")

(defun cmacs-brigade-memory--catalog ()
  "Return a list of (FILE . MTIME), newest first.

Newest first is what makes a long build useful early: after a few minutes
the last month of notes is searchable, which is most of what anyone asks
about, and the decade-old material fills in behind it."
  (let (files)
    (dolist (root cmacs-brigade-memory-roots)
      (let* ((kind (or (plist-get root :kind) 'org))
             (src (cmacs-brigade-registry-get 'memory-source kind)))
        (unless src
          (user-error "No memory source registered for :kind %s" kind))
        (dolist (f (funcall (plist-get src :enumerate) root))
          (push (cons f (float-time
                         (file-attribute-modification-time
                          (file-attributes f))))
                files))))
    (sort files (lambda (a b) (> (cdr a) (cdr b))))))

(defcustom cmacs-brigade-memory-build-report-interval 10
  "Seconds between build progress reports.

Reports go through `message', so they accumulate in *Messages* whether
or not you were looking at the echo area when one landed -- which is the
point, since the build outlives your attention span by some hours."
  :type 'number
  :group 'cmacs-brigade-memory)

(defcustom cmacs-brigade-memory-build-scan-budget 200
  "Files examined per turn before handing control back to Emacs.

Only reached by files that produce no chunks at all; a run of thousands
of them would otherwise be one long uninterruptible scan."
  :type 'integer
  :group 'cmacs-brigade-memory)

(defun cmacs-brigade-memory-build-running-p ()
  "Whether an index build is in progress."
  (and cmacs-brigade-memory--build t))

;; The build state is one plist in one global, read and written from a
;; process sentinel as well as from commands.  Accessors rather than
;; open-coded `plist-put', because `plist-put' only mutates in place when
;; the key is already there -- and a build that quietly dropped a field
;; the first time it was set would be a very confusing bug to find.

(defun cmacs-brigade-memory--bget (key)
  (plist-get cmacs-brigade-memory--build key))

(defun cmacs-brigade-memory--bset (key value)
  (setq cmacs-brigade-memory--build
        (plist-put cmacs-brigade-memory--build key value))
  value)

(defun cmacs-brigade-memory--report (format &rest args)
  "Log a build message, without stealing a minibuffer you are using.

`inhibit-message' suppresses only the echo area; the text still reaches
*Messages*, which is where a report from four hours ago has to be."
  (let ((inhibit-message (and (active-minibuffer-window) t)))
    (apply #'message format args)))

(defun cmacs-brigade-memory-build-progress ()
  "Return how far the running build has got, as a plist, or nil.

Keys: :files :nfiles :chunks :elapsed :percent.  The public view of the
build for anything that wants to display it -- the dashboard reads this
rather than the state plist, so the state stays private."
  (when cmacs-brigade-memory--build
    (let ((n (cmacs-brigade-memory--bget :nfiles))
          (i (cmacs-brigade-memory--bget :fileno)))
      (list :files i :nfiles n
            :chunks (cmacs-brigade-memory--bget :total)
            :elapsed (- (float-time) (cmacs-brigade-memory--bget :t0))
            :percent (if (> n 0) (/ (* 100 i) n) 0)))))

(defun cmacs-brigade-memory-build-status ()
  "Report how far the running build has got."
  (interactive)
  (if (not cmacs-brigade-memory--build)
      (message "cmacs-brigade: no build running")
    (let* ((st cmacs-brigade-memory--build)
           (n (plist-get st :nfiles))
           (i (plist-get st :fileno)))
      (message "cmacs-brigade: %d/%d files (%d%%), %d chunks, %s elapsed"
               i n (if (> n 0) (/ (* 100 i) n) 0) (plist-get st :total)
               (format-seconds "%h:%.2m:%.2s"
                               (- (float-time) (plist-get st :t0)))))))

;;;###autoload
(defun cmacs-brigade-memory-build-cancel ()
  "Stop the running build.  The existing index is left as it was."
  (interactive)
  (if (not cmacs-brigade-memory--build)
      (message "cmacs-brigade: no build running")
    (let ((st cmacs-brigade-memory--build))
      ;; Cleared *before* the process is killed.  `delete-process' can
      ;; run the sentinel then and there, and a sentinel that still saw a
      ;; live build would abort the writer a second time and report a
      ;; failure for something that was cancelled on purpose.
      (setq cmacs-brigade-memory--build nil)
      (when-let* ((p (plist-get st :proc)))
        (cmacs-brigade-memory--embed-abort p))
      ;; Abort discards the temporary; the live index never saw any of it.
      (ignore-errors (cmacs-brigade-index-writer-abort (plist-get st :writer)))
      (message "cmacs-brigade: build cancelled after %d chunks"
               (plist-get st :total)))))

;;;###autoload
(defun cmacs-brigade-memory-build (&optional force)
  "Build the memory index over `cmacs-brigade-memory-roots'.

With FORCE, rebuild even when the manifest already matches.

Runs in the background and returns immediately.  Emacs stays usable
throughout: the time is spent waiting on the embedding server, and that
wait happens on a process object rather than inside a blocking call, so
the main loop keeps running.  Progress goes to *Messages* every
`cmacs-brigade-memory-build-report-interval' seconds.

A first build of a large corpus runs for hours.  Nothing is written to
the live index until it finishes -- the new one is assembled in a
temporary -- so \\[cmacs-brigade-memory-build-cancel], a crash, or
quitting Emacs all leave the index you already had.

Note that a thread would not have helped here, whatever it looks like:
an Emacs thread sitting in `call-process' holds the global Lisp lock, so
the main thread cannot run until the call returns.  Measured on this
machine, one second of main-thread work took 3.95 seconds alongside such
a thread, and 1.00 seconds alongside one waiting on a process."
  (interactive "P")
  (unless (fboundp 'cmacs-brigade-index-writer-new)
    (user-error "This cmacs was built without --with-cmacs-ai-brigade"))
  (when cmacs-brigade-memory--build
    (user-error "cmacs-brigade: a build is already running (%d/%d files); \
M-x cmacs-brigade-memory-build-cancel"
                (plist-get cmacs-brigade-memory--build :fileno)
                (plist-get cmacs-brigade-memory--build :nfiles)))
  (let ((m (cmacs-brigade-memory-manifest)))
    (if (and (not force) (cmacs-brigade-memory--manifest-matches-p m))
        (progn (message "cmacs-brigade: index is current (%s chunks); \
C-u to force" (plist-get m :count))
               nil)
      (let ((catalog (cmacs-brigade-memory--catalog)))
        (setq cmacs-brigade-memory--build
              (list :writer (cmacs-brigade-index-writer-new
                             cmacs-brigade-memory-index-dir
                             cmacs-brigade-embed-dim)
                    :catalog catalog
                    :pending nil
                    :file nil
                    :meta nil
                    :nfiles (length catalog)
                    :fileno 0
                    :total 0
                    :t0 (float-time)
                    :last-report (float-time)
                    :proc nil))
        (cmacs-brigade-memory--report
         "cmacs-brigade: indexing %d files in the background (\
M-x cmacs-brigade-memory-build-status)" (length catalog))
        (cmacs-brigade-memory--build-step)
        t))))

;;;###autoload
(defun cmacs-brigade-memory-build-sync (&optional force)
  "Build the index and wait for it, pumping the event loop.

For batch use and tests, where nothing else would ever drive the
sentinels.  Interactively you want `cmacs-brigade-memory-build', which
does not block."
  (interactive "P")
  (when (cmacs-brigade-memory-build force)
    (while cmacs-brigade-memory--build
      (accept-process-output nil 0.1))
    t))

(defun cmacs-brigade-memory--build-next-batch ()
  "Return the next batch of chunks to embed, advancing the catalog.

Returns nil when the corpus is exhausted, and `:yield' when it has
looked at as many chunkless files as it is willing to in one turn."
  (let ((scanned 0)
        (result nil)
        (done nil))
    (while (not done)
      (let ((pending (cmacs-brigade-memory--bget :pending)))
        (cond
         (pending
          ;; Batch across chunks rather than files: most notes are one
          ;; chunk, and a request per file would waste most of the
          ;; batching win the endpoint exists to give.
          (setq result (seq-take pending cmacs-brigade-embed-batch))
          (cmacs-brigade-memory--bset
           :pending (seq-drop pending cmacs-brigade-embed-batch))
          (setq done t))
         ;; Nothing pending and nothing left to read: the corpus is done.
         ((null (cmacs-brigade-memory--bget :catalog))
          (setq result nil done t))
         ((>= scanned cmacs-brigade-memory-build-scan-budget)
          (setq result :yield done t))
         (t
          (let* ((catalog (cmacs-brigade-memory--bget :catalog))
                 (file (car (car catalog)))
                 (kind (cmacs-brigade-memory--kind-for file))
                 (src (cmacs-brigade-registry-get 'memory-source kind)))
            (cmacs-brigade-memory--bset :catalog (cdr catalog))
            (cmacs-brigade-memory--bset
             :fileno (1+ (cmacs-brigade-memory--bget :fileno)))
            (cmacs-brigade-memory--bset :file file)
            (setq scanned (1+ scanned))
            (cmacs-brigade-memory--bset
             :pending
             (condition-case err
                 (and src (funcall (plist-get src :read-chunk) file))
               ;; One unreadable file must not end a four-hour build.
               (error
                (cmacs-brigade-memory--report
                 "cmacs-brigade: skipping %s: %s" file
                 (error-message-string err))
                nil))))))))
    result))

(defun cmacs-brigade-memory--build-step ()
  "Embed the next batch, or finish.  Returns immediately."
  (when cmacs-brigade-memory--build
    (let ((batch (cmacs-brigade-memory--build-next-batch)))
      (cond
       ((eq batch :yield)
        ;; Back to the command loop, then carry on.  A zero timer, not a
        ;; recursive call: recursion here would rebuild the whole stack
        ;; depth of a 24,000-file corpus.
        (run-at-time 0 nil #'cmacs-brigade-memory--build-step))
       ((null batch) (cmacs-brigade-memory--build-finish))
       (t
        (let ((file (cmacs-brigade-memory--bget :file)))
          (cmacs-brigade-memory--bset
           :proc (cmacs-brigade-memory--embed-async
                  (mapcar #'cmacs-brigade-memory--embed-text batch)
                  (lambda (vecs)
                    (cmacs-brigade-memory--build-absorb batch vecs file))
                  #'cmacs-brigade-memory--build-failed))))))))

(defun cmacs-brigade-memory--build-absorb (batch vecs file)
  "Add VECS for BATCH from FILE to the index being built, then continue."
  (when cmacs-brigade-memory--build
    (let ((writer (cmacs-brigade-memory--bget :writer)))
      (cl-loop for c in batch
               for v in vecs
               do (cmacs-brigade-index-writer-add writer v)
                  (cmacs-brigade-memory--bset
                   :meta (cons (list :path file
                                     :display
                                     (cmacs-brigade-memory--display-path file)
                                     :heading (plist-get c :heading)
                                     :text (plist-get c :text))
                               (cmacs-brigade-memory--bget :meta)))
                  (cmacs-brigade-memory--bset
                   :total (1+ (cmacs-brigade-memory--bget :total)))))
    (let ((elapsed (- (float-time) (cmacs-brigade-memory--bget :t0))))
      (when (>= (- (float-time) (cmacs-brigade-memory--bget :last-report))
                cmacs-brigade-memory-build-report-interval)
        (cmacs-brigade-memory--bset :last-report (float-time))
        (cmacs-brigade-memory--report
         "cmacs-brigade: indexing %d/%d files, %d chunks, %.1f/s, %s elapsed"
         (cmacs-brigade-memory--bget :fileno)
         (cmacs-brigade-memory--bget :nfiles)
         (cmacs-brigade-memory--bget :total)
         (/ (cmacs-brigade-memory--bget :total) (max 1.0 elapsed))
         (format-seconds "%h:%.2m:%.2s" elapsed))))
    (cmacs-brigade-memory--build-step)))

(defun cmacs-brigade-memory--build-failed (why)
  "Abandon the build because WHY.  The existing index is untouched."
  (when cmacs-brigade-memory--build
    (let ((st cmacs-brigade-memory--build))
      (setq cmacs-brigade-memory--build nil)
      (ignore-errors (cmacs-brigade-index-writer-abort (plist-get st :writer)))
      (message "cmacs-brigade: build failed after %d chunks: %s"
               (plist-get st :total) why))))

(defun cmacs-brigade-memory--build-finish ()
  "Commit the built index and record what it was built from."
  (let ((st cmacs-brigade-memory--build))
    (setq cmacs-brigade-memory--build nil)
    (condition-case err
        (progn
          (cmacs-brigade-index-writer-commit (plist-get st :writer))
          (cmacs-brigade-memory--write-meta (nreverse (plist-get st :meta)))
          (cmacs-brigade-memory--write-manifest
           (list :version 1
                 :model cmacs-brigade-embed-model
                 :dim cmacs-brigade-embed-dim
                 :chunk-target cmacs-brigade-chunk-target-bytes
                 :chunk-overlap cmacs-brigade-chunk-overlap
                 :count (plist-get st :total)
                 :files (plist-get st :nfiles)
                 :built-at (format-time-string "%FT%T%z")))
          ;; The open index is the pre-build one; drop it so the next
          ;; search maps what was just committed.
          (ignore-errors (cmacs-brigade-memory-close))
          (message "cmacs-brigade: indexed %d chunks from %d files in %s"
                   (plist-get st :total) (plist-get st :nfiles)
                   (format-seconds "%h:%.2m:%.2s"
                                   (- (float-time) (plist-get st :t0))))
          (plist-get st :total))
      (error
       (ignore-errors (cmacs-brigade-index-writer-abort (plist-get st :writer)))
       (message "cmacs-brigade: could not commit the index: %s"
                (error-message-string err))
       nil))))

;; A build in flight owns a temporary index directory.  Exiting without
;; discarding it leaves that behind to be found later and puzzled over.
(add-hook 'kill-emacs-hook
          (lambda ()
            (when cmacs-brigade-memory--build
              (ignore-errors
                (cmacs-brigade-index-writer-abort
                 (plist-get cmacs-brigade-memory--build :writer))))))

(defun cmacs-brigade-memory--embed-text (chunk)
  "Return the string actually embedded for CHUNK.

The breadcrumb goes in: a chunk reading \"yes, Tuesday works\" has no
content words of its own, and everything that makes it findable is in the
heading path above it."
  (concat cmacs-brigade-embed-document-prefix
          (plist-get chunk :heading) "\n\n"
          (plist-get chunk :text)))

(defun cmacs-brigade-memory--kind-for (file)
  "Return the source kind configured for FILE."
  (or (cl-loop for root in cmacs-brigade-memory-roots
               for p = (file-name-as-directory
                        (expand-file-name (plist-get root :path)))
               when (string-prefix-p p file)
               return (or (plist-get root :kind) 'org))
      'org))

(defun cmacs-brigade-memory--meta-file ()
  (expand-file-name "meta.eld" cmacs-brigade-memory-index-dir))

(defun cmacs-brigade-memory--write-meta (meta)
  (with-temp-file (cmacs-brigade-memory--meta-file)
    (let ((print-length nil) (print-level nil))
      (prin1 (vconcat meta) (current-buffer))
      (insert "\n"))))

(defvar cmacs-brigade-memory--meta nil
  "Cached chunk metadata vector, parallel to the index rows.")

(defun cmacs-brigade-memory--load-meta ()
  (or cmacs-brigade-memory--meta
      (let ((f (cmacs-brigade-memory--meta-file)))
        (when (file-readable-p f)
          (setq cmacs-brigade-memory--meta
                (with-temp-buffer
                  (insert-file-contents f)
                  (read (current-buffer))))))))


;;;; Search

(defvar cmacs-brigade-memory--handle nil
  "Open index handle, or nil.")

(defun cmacs-brigade-memory--ensure-open ()
  "Open the index if it is not already, and return the handle."
  (or cmacs-brigade-memory--handle
      (setq cmacs-brigade-memory--handle
            (cmacs-brigade-index-open cmacs-brigade-memory-index-dir))))

(defun cmacs-brigade-memory-close ()
  "Release the index mapping and cached metadata."
  (interactive)
  (when cmacs-brigade-memory--handle
    (cmacs-brigade-index-close cmacs-brigade-memory--handle)
    (setq cmacs-brigade-memory--handle nil))
  (setq cmacs-brigade-memory--meta nil))


;;;; Incremental update
;;
;; A full build re-embeds the corpus, which for a large tree is hours.
;; Changing one note should cost one embedding call.  The index is a flat
;; array of rows with a metadata vector parallel to it, so replacing a
;; file's rows is: copy every row that is not the file's (a memcpy in C,
;; `cmacs-brigade-index-writer-copy'), append the file's new vectors,
;; commit, and rewrite the metadata in the same order.  The writer still
;; assembles a temporary and renames over the live index, so a crash
;; mid-update leaves the previous index intact, exactly as a build does.
;;
;; The same routine handles a deleted file: it has no chunks, so its
;; rows are dropped and nothing is appended.

(defvar cmacs-brigade-memory--update nil
  "Plist describing an in-progress incremental update, or nil.")

(defvar cmacs-brigade-memory--update-queue nil
  "Files waiting for the next incremental update, as an alist of
(FILE . CALLBACKS).  Requests that arrive while an update or a build is
running are coalesced here and run when it finishes.")

(defun cmacs-brigade-memory-index-exists-p ()
  "Non-nil when there is a committed index matching the current settings."
  (and (file-readable-p (expand-file-name "vectors.f16" cmacs-brigade-memory-index-dir))
       (file-readable-p (cmacs-brigade-memory--meta-file))
       (cmacs-brigade-memory--manifest-matches-p (cmacs-brigade-memory-manifest))))

(defun cmacs-brigade-memory--indexable-p (file)
  "Non-nil when FILE is under a configured root and its source would index it."
  (let ((f (expand-file-name file)))
    (cl-some (lambda (root)
               (let* ((p (file-name-as-directory (expand-file-name (plist-get root :path))))
                      (excl (plist-get root :exclude))
                      (glob (or (plist-get root :glob) "\\.org\\'")))
                 (and (string-prefix-p p f)
                      (string-match-p glob f)
                      (not (cl-some (lambda (e) (string-search e f)) excl)))))
             cmacs-brigade-memory-roots)))

;;;###autoload
(defun cmacs-brigade-memory-update-files (files &optional callback)
  "Re-index FILES in the memory index without rebuilding it.

FILES is a file name or a list.  Each is re-chunked and re-embedded, its
old rows are dropped and the new ones appended; a file that no longer
exists simply loses its rows.  Files outside every configured root, or
excluded by one, are ignored.  Runs in the background; CALLBACK, when
given, is called with the number of rows written (or nil on failure).

Needs a committed index that matches the current embedding settings --
there is nothing to update otherwise -- and defers behind a running
build or update rather than fighting it for the writer lock.  Returns
non-nil when an update was started or queued."
  (let ((files (cl-remove-if-not #'cmacs-brigade-memory--indexable-p
                                 (mapcar #'expand-file-name
                                         (if (listp files) files (list files))))))
    (cond
     ((null files) (when callback (funcall callback 0)) nil)
     ((not (fboundp 'cmacs-brigade-index-writer-copy))
      (message "cmacs-brigade: this build cannot update the index incrementally")
      nil)
     ((not (cmacs-brigade-memory-index-exists-p))
      (message "cmacs-brigade: no matching index to update; run M-x cmacs-brigade-memory-build")
      nil)
     ((or cmacs-brigade-memory--build cmacs-brigade-memory--update)
      (dolist (f files)
        (let ((cell (assoc f cmacs-brigade-memory--update-queue)))
          (if cell (when callback (push callback (cdr cell)))
            (push (cons f (and callback (list callback))) cmacs-brigade-memory--update-queue))))
      t)
     (t
      (setq cmacs-brigade-memory--update
            (list :files files
                  :callbacks (and callback (list callback))
                  :pending nil        ; chunks still to embed: (FILE . CHUNK)
                  :rows nil           ; (META . VECTOR) accumulated, reversed
                  :t0 (float-time)
                  :proc nil))
      (dolist (f files)
        (let* ((kind (cmacs-brigade-memory--kind-for f))
               (src (cmacs-brigade-registry-get 'memory-source kind))
               (chunks (and src (file-readable-p f)
                            (condition-case err
                                (funcall (plist-get src :read-chunk) f)
                              (error (message "cmacs-brigade: skipping %s: %s" f
                                              (error-message-string err))
                                     nil)))))
          (plist-put cmacs-brigade-memory--update :pending
                     (append (plist-get cmacs-brigade-memory--update :pending)
                             (mapcar (lambda (c) (cons f c)) chunks)))))
      (cmacs-brigade-memory--update-step)
      t))))

(defun cmacs-brigade-memory--update-step ()
  "Embed the next batch of the running update, or commit it."
  (when cmacs-brigade-memory--update
    (let* ((st cmacs-brigade-memory--update)
           (pending (plist-get st :pending)))
      (if (null pending)
          (cmacs-brigade-memory--update-commit)
        (let ((batch (seq-take pending cmacs-brigade-embed-batch)))
          (plist-put st :pending (seq-drop pending cmacs-brigade-embed-batch))
          (plist-put st :proc
                     (cmacs-brigade-memory--embed-async
                      (mapcar (lambda (fc) (cmacs-brigade-memory--embed-text (cdr fc))) batch)
                      (lambda (vecs)
                        (when cmacs-brigade-memory--update
                          (cl-loop for (file . chunk) in batch
                                   for v in vecs
                                   do (plist-put st :rows
                                                 (cons (cons (list :path file
                                                                   :display (cmacs-brigade-memory--display-path file)
                                                                   :heading (plist-get chunk :heading)
                                                                   :text (plist-get chunk :text))
                                                             v)
                                                       (plist-get st :rows))))
                          (cmacs-brigade-memory--update-step)))
                      (lambda (why) (cmacs-brigade-memory--update-done nil (format "%s" why))))))))))

(defun cmacs-brigade-memory--update-commit ()
  "Write the updated index: old rows minus the files', plus the new rows."
  (let* ((st cmacs-brigade-memory--update)
         (files (plist-get st :files))
         (writer nil))
    (condition-case err
        (let* ((ix (cmacs-brigade-memory--ensure-open))
               (meta (or (cmacs-brigade-memory--load-meta) []))
               (skip nil) (kept nil))
          ;; Rows belonging to the files go; everything else is kept in
          ;; its original order so the metadata stays parallel.
          (cl-loop for m across meta
                   for i from 0
                   do (if (member (plist-get m :path) files)
                          (push i skip)
                        (push m kept)))
          (setq writer (cmacs-brigade-index-writer-new cmacs-brigade-memory-index-dir
                                                       cmacs-brigade-embed-dim))
          (cmacs-brigade-index-writer-copy writer ix (nreverse skip))
          (let ((new (nreverse (plist-get st :rows))))
            (dolist (r new)
              (cmacs-brigade-index-writer-add writer (cdr r)))
            (cmacs-brigade-index-writer-commit writer)
            (setq writer nil)
            (cmacs-brigade-memory--write-meta (append (nreverse kept) (mapcar #'car new)))
            (let ((m (cmacs-brigade-memory-manifest)))
              (cmacs-brigade-memory--write-manifest
               (plist-put (plist-put m :count (+ (length kept) (length new)))
                          :updated-at (format-time-string "%FT%T%z"))))
            ;; The mapping is the pre-update file; the next search reopens.
            (cmacs-brigade-memory-close)
            (cmacs-brigade-memory--update-done (length new) nil)))
      (error
       (when writer (ignore-errors (cmacs-brigade-index-writer-abort writer)))
       (cmacs-brigade-memory--update-done nil (error-message-string err))))))

(defun cmacs-brigade-memory--update-done (n why)
  "Finish the running update with N rows written, or the failure WHY."
  (let ((st cmacs-brigade-memory--update))
    (setq cmacs-brigade-memory--update nil)
    (if why
        (message "cmacs-brigade: incremental update failed: %s" why)
      (message "cmacs-brigade: re-indexed %d file%s (%d chunks) in %.1fs"
               (length (plist-get st :files))
               (if (= 1 (length (plist-get st :files))) "" "s")
               n (- (float-time) (plist-get st :t0))))
    (dolist (cb (plist-get st :callbacks))
      (ignore-errors (funcall cb n)))
    ;; Anything that arrived meanwhile.
    (when cmacs-brigade-memory--update-queue
      (let ((queue cmacs-brigade-memory--update-queue))
        (setq cmacs-brigade-memory--update-queue nil)
        (cmacs-brigade-memory-update-files
         (mapcar #'car queue)
         (let ((cbs (apply #'append (mapcar #'cdr queue))))
           (and cbs (lambda (k) (dolist (cb cbs) (ignore-errors (funcall cb k)))))))))))

(defun cmacs-brigade-memory--lexical (query limit)
  "Return paths matching QUERY literally, best first, via ripgrep.

The lexical half of hybrid retrieval.  A vector search is hopeless at
exact identifiers -- ticket numbers, unusual surnames, function names --
because an embedding of a token it has never seen is noise, while grep
finds it instantly."
  (when (and cmacs-brigade-memory-lexical-program
             (executable-find cmacs-brigade-memory-lexical-program))
    (let ((dirs (cl-remove-if-not
                 #'file-directory-p
                 (mapcar (lambda (r) (expand-file-name (plist-get r :path)))
                         cmacs-brigade-memory-roots))))
      (when dirs
        (with-temp-buffer
          (apply #'call-process cmacs-brigade-memory-lexical-program nil t nil
                 (append (list "--no-heading" "--line-number" "--fixed-strings"
                               "--ignore-case" "--max-count" "3"
                               "-m" (number-to-string limit) "--" query)
                         dirs))
          (let (hits)
            (goto-char (point-min))
            (while (and (not (eobp)) (< (length hits) limit))
              (let ((line (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))))
                (when (string-match "\\`\\([^:]+\\):" line)
                  (push (match-string 1 line) hits)))
              (forward-line 1))
            (nreverse (delete-dups hits))))))))

(defun cmacs-brigade-memory--fuse (semantic lexical k)
  "Fuse SEMANTIC and LEXICAL rankings by reciprocal rank, keep K.

SEMANTIC is a list of result plists; LEXICAL a list of paths.  A document
appearing in both rises above one that merely ranked highly in either,
which is exactly the behaviour that makes hybrid retrieval better than
its halves."
  (let ((scores (make-hash-table :test 'equal))
        (best (make-hash-table :test 'equal))
        (kk cmacs-brigade-memory-rrf-k))
    (cl-loop for r in semantic
             for i from 0
             for key = (format "%s#%s" (plist-get r :path)
                               (plist-get r :heading))
             do (puthash key (+ (gethash key scores 0.0)
                                (/ 1.0 (+ kk i 1)))
                         scores)
                (puthash key r best))
    (cl-loop for p in lexical
             for i from 0
             do (cl-loop for r in semantic
                         for key = (format "%s#%s" (plist-get r :path)
                                           (plist-get r :heading))
                         when (equal (plist-get r :path) p)
                         do (puthash key (+ (gethash key scores 0.0)
                                            (/ 1.0 (+ kk i 1)))
                                     scores)))
    (let (out)
      (maphash (lambda (key _v) (push (gethash key best) out)) scores)
      (setq out (sort (delq nil out)
                      (lambda (a b)
                        (> (gethash (format "%s#%s" (plist-get a :path)
                                            (plist-get a :heading))
                                    scores 0.0)
                           (gethash (format "%s#%s" (plist-get b :path)
                                            (plist-get b :heading))
                                    scores 0.0)))))
      (seq-take out k))))

(defun cmacs-brigade-memory-search (query &optional k)
  "Return the K chunks most relevant to QUERY, best first.

Each result is a plist with :path, :display, :heading, :text and :score."
  (let* ((k (or k 8))
         (handle (cmacs-brigade-memory--ensure-open))
         (meta (cmacs-brigade-memory--load-meta))
         (vec (cmacs-brigade-memory-embed-query query))
         ;; Over-fetch before fusion: a document the lexical pass will
         ;; promote has to be present in the semantic list for its rank
         ;; to count, so taking exactly K here would discard the very
         ;; candidates fusion exists to rescue.
         (raw (cmacs-brigade-index-search handle vec (* k 4)))
         (semantic
          (cl-loop for (id . score) in raw
                   for m = (and meta (< id (length meta)) (aref meta id))
                   when m
                   collect (append (list :score score) m))))
    (cmacs-brigade-memory--fuse
     semantic (cmacs-brigade-memory--lexical query (* k 2)) k)))

;;;###autoload
(defun cmacs-brigade-memory-find (query)
  "Search the memory index for QUERY and show the results."
  (interactive "sMemory search: ")
  (let ((results (cmacs-brigade-memory-search query 12)))
    (if (null results)
        (message "cmacs-brigade: nothing found for %S" query)
      (with-current-buffer (get-buffer-create "*brigade memory*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Memory search: %s\n" query)
                  (make-string 64 ?-) "\n\n")
          (dolist (r results)
            (insert (propertize (format "%s\n" (plist-get r :heading))
                                'face 'bold))
            (insert (format "  %.3f  %s\n" (plist-get r :score)
                            (plist-get r :display)))
            (insert "  " (string-replace
                          "\n" "\n  "
                          (truncate-string-to-width
                           (plist-get r :text) 400 nil nil t))
                    "\n\n"))
          (goto-char (point-min)))
        (special-mode)
        (display-buffer (current-buffer))))))

;;;###autoload
(defun cmacs-brigade-memory-stats ()
  "Report what the memory index currently covers."
  (interactive)
  (let ((m (cmacs-brigade-memory-manifest)))
    (if (null m)
        (message "cmacs-brigade: no index (M-x cmacs-brigade-memory-build)")
      (message "cmacs-brigade: %s chunks from %s files, model %s, built %s%s"
               (plist-get m :count) (plist-get m :files)
               (plist-get m :model) (plist-get m :built-at)
               (if (cmacs-brigade-memory--manifest-matches-p m) ""
                 "  [STALE: settings changed, rebuild]")))))


;;;; Tools
;;
;; Registered through the public API like anything else, so they arrive
;; on all three agent surfaces at once.

(cmacs-brigade-deftool memory-search
  "Search the user's notes and other indexed corpora for material
relevant to a question.  Returns ranked excerpts with their source
paths.  Use this before answering anything about the user's own
decisions, projects, or history."
  ((query string "What to look for, phrased as a question or topic")
   (k integer "How many results to return" :optional t :default 8))
  :group 'memory
  (let ((results (cmacs-brigade-memory-search query (or k 8))))
    (if (null results)
        "No matching material in the index."
      (mapconcat
       (lambda (r)
         (format "## %s\n(%s, score %.3f)\n\n%s"
                 (plist-get r :heading) (plist-get r :display)
                 (plist-get r :score) (plist-get r :text)))
       results "\n\n---\n\n"))))

(cmacs-brigade-deftool memory-get
  "Read a file from the indexed corpora in full, by its path as reported
by memory_search.  Use this when an excerpt is not enough."
  ((path string "Path as shown in a memory_search result"))
  :group 'memory
  (let ((full (cmacs-brigade-memory--resolve-path path)))
    (cond
     ((null full) (format "Error: %s is not under an indexed root" path))
     ((not (file-readable-p full)) (format "Error: cannot read %s" path))
     (t (with-temp-buffer (insert-file-contents full) (buffer-string))))))

(cmacs-brigade-deftool memory-stats
  "Report how much of the user's corpora the memory index currently
covers.  Call this before concluding that something is absent from the
notes -- an empty result from a partial index means nothing."
  ()
  :group 'memory
  (let ((m (cmacs-brigade-memory-manifest)))
    (if (null m) "No index has been built yet."
      (format "%s chunks from %s files, model %s, built %s%s"
              (plist-get m :count) (plist-get m :files)
              (plist-get m :model) (plist-get m :built-at)
              (if (cmacs-brigade-memory--manifest-matches-p m) ""
                " (STALE: settings changed since the build)")))))

(defun cmacs-brigade-memory--resolve-path (path)
  "Resolve a display PATH to an absolute file under a configured root.

Returns nil when it escapes every root.  This is the containment check:
an agent naming \"../../.ssh/id_ed25519\" must not get it, and the test
has to be on the *resolved* path because that is what the filesystem
will act on."
  (let ((expanded (expand-file-name path)))
    (cl-loop for root in cmacs-brigade-memory-roots
             for base = (file-name-as-directory
                         (expand-file-name (plist-get root :path)))
             for candidate = (expand-file-name path base)
             ;; Either an absolute path already inside a root, or a
             ;; display path resolved against one.
             thereis (cond
                      ((string-prefix-p base expanded) expanded)
                      ((string-prefix-p base candidate) candidate)))))

(provide 'cmacs-brigade-memory)

;;; cmacs-brigade-memory.el ends here
