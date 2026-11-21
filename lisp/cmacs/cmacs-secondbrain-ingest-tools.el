;;; cmacs-secondbrain-ingest-tools.el --- The ingester as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `secondbrain_ingest', `secondbrain_ingest_status', `secondbrain_tree'
;; and `secondbrain_find' of cmacs/mcp/cmacs-mcp-tools-secondbrain.c on
;; the capability table (doc_org/cmacs/cmacs-capability.org has the
;; recipe).  The rest of that C file's tools are in
;; cmacs-secondbrain-tools.el and cmacs-secondbrain-search-tools.el.
;; The C file is deleted; "the C" below is what it published, frozen in
;; test/cmacs/data/mcp-wire-schema.json.
;;
;; These four were registered here before the capability table existed,
;; and had drifted from the C tools of the same names -- which mattered
;; little while the C served MCP and this file served only in-process
;; agents, and matters now that one definition serves both:
;;
;;   - `secondbrain_ingest' took eight parameters where the C takes
;;     twenty-two, called one of them `summary_type' where the C says
;;     `type', required `input' where the C requires nothing (text alone
;;     is a valid call), and WAITED for the note to be written where the
;;     C queues the job and returns its id.  It is the C's now: every
;;     parameter, the same names, and an answer as soon as the jobs are
;;     queued.  The work was always asynchronous; what changed is that
;;     the tool no longer holds its caller for it.  Poll
;;     `secondbrain_ingest_status'.
;;
;;   - `secondbrain_ingest_status' required `id' where the C lists every
;;     job without one.
;;
;;   - All four returned {"error": ...} as an ordinary result.  They
;;     signal now, so each surface reports the failure as a failure.
;;
;; The options travel to `cmacs-secondbrain-ingest-from-json' as the
;; JSON object the C built, member for member, so there is one parser of
;; them (`cmacs-secondbrain-ingest-options-from-json') behind the tool,
;; the D-Bus method and `emacsctl sb'.
;;
;; `secondbrain_find' is still synchronous, as it was in C and here:
;; `cmacs-secondbrain-ingest-find' embeds the query through the brigade
;; memory index before it can rank, and has no non-blocking form.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-secondbrain-ingest-from-json
                  "cmacs-secondbrain-ingest" (inputs-json options-json))
(declare-function cmacs-secondbrain-ingest-status-json
                  "cmacs-secondbrain-ingest" (id))
(declare-function cmacs-secondbrain-ingest-list-json
                  "cmacs-secondbrain-ingest" ())
(declare-function cmacs-secondbrain-ingest-tree
                  "cmacs-secondbrain-ingest"
                  (&optional root para category files))
(declare-function cmacs-secondbrain-ingest-find-json
                  "cmacs-secondbrain-ingest" (query &optional k))

(defun cmacs-secondbrain-ingest-tools--text (value)
  "Return VALUE when it is a non-empty string, else nil.
The C's `sb_str_member': an empty string means what an absent one does."
  (and (stringp value) (not (string-empty-p value)) value))

(defun cmacs-secondbrain-ingest-tools--options (strings booleans integers
                                                        link keep-source)
  "Return the options object the C handler built, as JSON text.

STRINGS is an alist of (NAME . VALUE) copied when VALUE is a non-empty
string; BOOLEANS one copied as true when VALUE is non-nil; INTEGERS one
copied when VALUE is an integer.  LINK is the `link' argument as given:
only an explicit false is passed on, because absent means yes.
KEEP-SOURCE non-nil becomes the string \"copy\", which is how the
ingester spells it."
  (let ((out (make-hash-table :test 'equal)))
    (pcase-dolist (`(,name . ,value) strings)
      (when (cmacs-secondbrain-ingest-tools--text value)
        (puthash name value out)))
    (pcase-dolist (`(,name . ,value) booleans)
      (when value (puthash name t out)))
    (pcase-dolist (`(,name . ,value) integers)
      (when (integerp value) (puthash name value out)))
    (when (eq link :false) (puthash "link" :false out))
    (when keep-source (puthash "keep_source" "copy" out))
    (decode-coding-string (json-serialize out) 'utf-8 t)))

(cmacs-brigade-deftool secondbrain-ingest
  "File a URL, a file (PDF, Office, EPUB, mail, audio, video, YouTube, \
HTML, Markdown, data...) or literal text into the user's second brain \
as an Org note: summarised, tagged, placed in the PARA tree, linked to \
related notes and registered in its index.  Returns the QUEUED jobs \
with ids; the work runs asynchronously -- poll secondbrain_ingest_status \
until 'done' is true and read 'note_file'.  Set 'dry_run' to see the \
plan without doing anything.  Paths must be absolute."
    ((input string "URL or absolute path; omit when text is given"
            :optional t)
     (text string "Literal text to ingest" :optional t)
     (para string "inbox, projects, areas, resources or detect"
           :optional t
           :enum ("inbox" "projects" "areas" "resources" "detect"))
     (category string "Sub path under the category, e.g. technical/linux"
               :optional t)
     (directory string "Exact root-relative directory, overriding \
para/category" :optional t)
     (tags string "Comma-separated tags" :optional t)
     (type string "Summary template: auto, general, meeting, book, \
youtube, ..." :optional t)
     (prompt string "Extra summary instructions" :optional t)
     (principle boolean "File it as a principle" :optional t)
     (no_summary boolean "Skip the summary" :optional t)
     (no_ai boolean "Use no model at all" :optional t)
     (sanitize string "'t' for the default redaction rules, or a comma \
list of rule names" :optional t)
     (title string "Title to use instead of the material's own"
            :optional t)
     (name string "File name seed" :optional t)
     (format string "Format of text: org, markdown, text, json, csv, html"
             :optional t)
     (crawl boolean "Follow the links of a web page" :optional t)
     (depth integer "How many links deep to crawl" :optional t)
     (max_pages integer "Most pages a crawl may fetch" :optional t)
     (append boolean "Append to an existing note of the same name"
             :optional t)
     ;; :default t, and not only for the reader of the reference: a
     ;; boolean reaches the body as t or nil, and nil is also what an
     ;; absent argument would be.  With the default an absent `link'
     ;; arrives as t, which leaves nil to mean the caller said false --
     ;; the one answer this parameter exists to carry.
     (link boolean "false to skip related notes" :optional t :default t)
     (keep_source boolean "Copy the original beside the note" :optional t)
     (dry_run boolean "Plan only; write nothing" :optional t))
  :group 'secondbrain :returns 'json
  :destructive t
  :example "emacsctl tool secondbrain ingest --input https://example.org/a \
--para resources"
  (let ((input (cmacs-secondbrain-ingest-tools--text input))
        (text (cmacs-secondbrain-ingest-tools--text text)))
    (unless (or input text)
      (error "%s" "secondbrain_ingest: give 'input' (a URL or absolute path) \
or 'text'"))
    (require 'cmacs-secondbrain-ingest)
    ;; Queues and returns.  `cmacs-secondbrain-ingest-from-json' starts
    ;; each job and answers with their statuses as they stand, which is
    ;; "queued"; nothing here waits for a fetch, a transcription or a
    ;; model.
    (cmacs-secondbrain-ingest-from-json
     (decode-coding-string
      (json-serialize (if input (vector input) [])) 'utf-8 t)
     (cmacs-secondbrain-ingest-tools--options
      `(("para" . ,para) ("category" . ,category)
        ("directory" . ,directory) ("tags" . ,tags) ("type" . ,type)
        ("prompt" . ,prompt) ("name" . ,name) ("title" . ,title)
        ("format" . ,format) ("text" . ,text) ("sanitize" . ,sanitize))
      `(("principle" . ,principle) ("no_summary" . ,no_summary)
        ("no_ai" . ,no_ai) ("crawl" . ,crawl) ("append" . ,append)
        ("dry_run" . ,dry_run))
      `(("depth" . ,depth) ("max_pages" . ,max_pages))
      (if link nil :false) keep_source))))

(cmacs-brigade-deftool secondbrain-ingest-status
  "Status of an ingest job by 'id' (stage, progress, note_file, warnings, \
error, done); without an id, every job."
    ((id string "Job id, e.g. sbi-3; omit for every job" :optional t))
  :group 'secondbrain :returns 'json
  :example "emacsctl tool secondbrain ingest-status --id sbi-3"
  (require 'cmacs-secondbrain-ingest)
  (if (cmacs-secondbrain-ingest-tools--text id)
      (cmacs-secondbrain-ingest-status-json id)
    (cmacs-secondbrain-ingest-list-json)))

(cmacs-brigade-deftool secondbrain-tree
  "List the PARA notes tree as root-relative paths, optionally narrowed \
to one category and sub path, optionally with .org files.  Use it to \
see where a note could be filed."
    ((para string "Restrict to one category: inbox, projects, areas, \
resources, archives" :optional t)
     (category string "Sub path under that category" :optional t)
     (files boolean "Include .org files, not only directories" :optional t))
  :group 'secondbrain :returns 'json
  :example "emacsctl tool secondbrain tree --para resources"
  (require 'cmacs-secondbrain-ingest)
  (decode-coding-string
   (json-serialize
    (vconcat (cmacs-secondbrain-ingest-tree
              nil
              (cmacs-secondbrain-ingest-tools--text para)
              (cmacs-secondbrain-ingest-tools--text category)
              files)))
   'utf-8 t))

(cmacs-brigade-deftool secondbrain-find
  "Search the notes for a query: semantic (embeddings + lexical fusion) \
when the memory index exists, text search otherwise.  Returns path, \
title, score and snippet per hit."
    ((query string "What to look for")
     (limit integer "Most results to return (default 10)" :optional t))
  :group 'secondbrain :returns 'json
  :example "emacsctl tool secondbrain find --query \"wayland protocols\""
  (unless (cmacs-secondbrain-ingest-tools--text query)
    (error "%s" "secondbrain_find: missing 'query'"))
  (require 'cmacs-secondbrain-ingest)
  (cmacs-secondbrain-ingest-find-json
   query (if (and (integerp limit) (> limit 0)) limit 10)))

(provide 'cmacs-secondbrain-ingest-tools)

;;; cmacs-secondbrain-ingest-tools.el ends here
