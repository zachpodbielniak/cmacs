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

(defun cmacs-brigade-memory--embed (texts)
  "Embed TEXTS, a list of strings, and return a list of vectors.

Uses the batch endpoint and keeps exactly one request in flight."
  (unless texts (cl-return-from cmacs-brigade-memory--embed nil))
  (let* ((url (concat (string-remove-suffix "/" cmacs-brigade-embed-endpoint)
                      "/api/embed"))
         (payload (json-serialize
                   (list :model cmacs-brigade-embed-model
                         :input (vconcat texts))))
         (tmp (make-temp-file "cmacs-brigade-embed" nil ".json"))
         (out (generate-new-buffer " *brigade-embed*")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8))
            (with-temp-file tmp (insert payload)))
          (let ((status (call-process "curl" nil out nil
                                      "-sS" "--max-time" "300"
                                      "-H" "Content-Type: application/json"
                                      "--data-binary" (concat "@" tmp)
                                      url)))
            (unless (eq status 0)
              (signal 'cmacs-brigade-embed-error
                      (list (format "curl exited %s talking to %s"
                                    status url))))
            (with-current-buffer out
              (goto-char (point-min))
              (let* ((json-object-type 'plist)
                     (reply (condition-case err
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
                (mapcar #'vconcat embeddings)))))
      (delete-file tmp)
      (kill-buffer out))))

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

(defvar cmacs-brigade-memory--build-state nil
  "Plist describing an in-progress build, or nil.")

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

;;;###autoload
(defun cmacs-brigade-memory-build (&optional force)
  "Build the memory index over `cmacs-brigade-memory-roots'.

With FORCE, rebuild even when the manifest already matches.

Runs to completion in this Emacs.  On a large corpus that is a long time,
so progress is reported and the partial index is committed at the end;
interrupting with \\[keyboard-quit] leaves the previous index intact
because the new one is written to a temporary until it is complete."
  (interactive "P")
  (unless (fboundp 'cmacs-brigade-index-writer-new)
    (user-error "This cmacs was built without --with-cmacs-ai-brigade"))
  (let ((m (cmacs-brigade-memory-manifest)))
    (when (and (not force) (cmacs-brigade-memory--manifest-matches-p m))
      (message "cmacs-brigade: index is current (%s chunks); C-u to force"
               (plist-get m :count))
      (cl-return-from cmacs-brigade-memory-build nil)))
  (let* ((catalog (cmacs-brigade-memory--catalog))
         (writer (cmacs-brigade-index-writer-new
                  cmacs-brigade-memory-index-dir cmacs-brigade-embed-dim))
         (meta nil)
         (nfiles (length catalog))
         (fileno 0)
         (total 0)
         (t0 (float-time))
         (committed nil))
    (message "cmacs-brigade: indexing %d files..." nfiles)
    (unwind-protect
        (progn
          (dolist (entry catalog)
            (let* ((file (car entry))
                   (kind (cmacs-brigade-memory--kind-for file))
                   (src (cmacs-brigade-registry-get 'memory-source kind))
                   (chunks (funcall (plist-get src :read-chunk) file)))
              (setq fileno (1+ fileno))
              ;; Batch across chunks, not across files: a file with one
              ;; chunk would otherwise make a request per file.
              (while chunks
                (let* ((batch (seq-take chunks cmacs-brigade-embed-batch))
                       (rest (seq-drop chunks cmacs-brigade-embed-batch))
                       (texts (mapcar #'cmacs-brigade-memory--embed-text batch))
                       (vecs (cmacs-brigade-memory--embed texts)))
                  (cl-loop for c in batch
                           for v in vecs
                           do (cmacs-brigade-index-writer-add writer v)
                              (push (list :path file
                                          :display (cmacs-brigade-memory--display-path file)
                                          :heading (plist-get c :heading)
                                          :text (plist-get c :text))
                                    meta)
                              (setq total (1+ total)))
                  (setq chunks rest)))
              (when (zerop (% fileno 25))
                (message "cmacs-brigade: %d/%d files, %d chunks, %.0fs"
                         fileno nfiles total (- (float-time) t0)))))
          (cmacs-brigade-index-writer-commit writer)
          (setq committed t)
          (cmacs-brigade-memory--write-meta (nreverse meta))
          (cmacs-brigade-memory--write-manifest
           (list :version 1
                 :model cmacs-brigade-embed-model
                 :dim cmacs-brigade-embed-dim
                 :chunk-target cmacs-brigade-chunk-target-bytes
                 :chunk-overlap cmacs-brigade-chunk-overlap
                 :count total
                 :files nfiles
                 :built-at (format-time-string "%FT%T%z")))
          (message "cmacs-brigade: indexed %d chunks from %d files in %.0fs"
                   total nfiles (- (float-time) t0))
          total)
      (unless committed
        ;; Abort discards the temporary; the live index is untouched.
        (ignore-errors (cmacs-brigade-index-writer-abort writer))))))

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
