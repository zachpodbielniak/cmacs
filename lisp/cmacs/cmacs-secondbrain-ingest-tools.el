;;; cmacs-secondbrain-ingest-tools.el --- The ingester as an agent capability  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The second-brain ingester published through the brigade registry, so
;; an in-process agent, a CLI agent over the MCP relay and an external
;; MCP client can all say "file this" and get the note back.  One
;; `cmacs-brigade-deftool' form per capability; the D-Bus interface and
;; `emacsctl sb' reach the same `cmacs-secondbrain-ingest-*' functions
;; directly, so there is one implementation behind four transports.
;;
;; `secondbrain-ingest' is asynchronous: the tool returns when the note
;; is written (or the job fails), not when the job is queued, because a
;; model that is told "queued" will poll.  The others are quick reads.
;;
;; Loaded lazily: this file requires the registry only when it is there,
;; so a build without ai-brigade still has the ingester -- just not as a
;; tool.

;;; Code:

(require 'cmacs-secondbrain-ingest)

(declare-function cmacs-brigade-deftool "cmacs-brigade-registry")

(when (and (require 'cmacs-brigade-registry nil t)
           (fboundp 'cmacs-brigade-deftool))

  (cmacs-brigade-deftool secondbrain-ingest
    "File a URL, a file (any format: PDF, Office, EPUB, mail, audio, video,
YouTube, HTML, Markdown, data) or literal text into the user's second brain
as an Org note: summarised, tagged, placed in the PARA tree, linked to
related notes and registered in its index.  Returns the job's final status
as JSON, including note_file.  Slow for media (transcription) and long
documents (summary); expect tens of seconds."
    ((input string "A URL, an absolute path, or empty when text is given")
     (text string "Literal text to ingest instead of a file or URL" :optional t)
     (para string "inbox, projects, areas, resources or detect (default: configured placement)" :optional t)
     (category string "Sub path under the PARA category, e.g. technical/linux" :optional t)
     (tags string "Comma-separated tags to add" :optional t)
     (summary_type string "Summary template: general, meeting, book, youtube, ... or auto" :optional t)
     (title string "Title to use instead of the material's own" :optional t)
     (no_summary boolean "Skip the AI summary" :optional t))
    :group 'secondbrain
    :async t
    :timeout 900
    (let* ((opts (delq nil
                       (append (and (not (string-empty-p (or text ""))) (list :text text))
                               (and para (not (string-empty-p para)) (list :para para))
                               (and category (not (string-empty-p category)) (list :category category))
                               (and tags (not (string-empty-p tags)) (list :tags tags))
                               (and summary_type (not (string-empty-p summary_type)) (list :type summary_type))
                               (and title (not (string-empty-p title)) (list :title title))
                               (and no_summary (list :no-summary t)))))
           (opts (append opts
                         (list :callback
                               (lambda (job)
                                 (funcall done (cmacs-secondbrain-ingest-status-json
                                                (cmacs-secondbrain-ingest-job-id job))))))))
      (condition-case err
          (let ((jobs (apply #'cmacs-secondbrain-ingest-run
                             (and (not (string-empty-p (or input ""))) input)
                             opts)))
            (unless jobs (funcall done "{\"error\": \"nothing to ingest\"}")))
        (error (funcall done (json-serialize
                              (list :error (error-message-string err))))))))

  (cmacs-brigade-deftool secondbrain-ingest-status
    "Status of an ingest job by id, as JSON."
    ((id string "Job id, e.g. sbi-3"))
    :group 'secondbrain
    (condition-case err (cmacs-secondbrain-ingest-status-json id)
      (error (json-serialize (list :error (error-message-string err))))))

  (cmacs-brigade-deftool secondbrain-tree
    "List the PARA notes tree as root-relative paths.  Use this to see where a
note could be filed before choosing a category."
    ((para string "Restrict to one category: inbox, projects, areas, resources, archives" :optional t)
     (category string "Sub path under that category" :optional t)
     (files boolean "Include .org files, not only directories" :optional t))
    :group 'secondbrain
    (condition-case err
        (json-serialize (vconcat (cmacs-secondbrain-ingest-tree
                                  nil (and para (not (string-empty-p para)) para)
                                  (and category (not (string-empty-p category)) category)
                                  files)))
      (error (json-serialize (list :error (error-message-string err))))))

  (cmacs-brigade-deftool secondbrain-find
    "Search the second brain for notes about a query: semantic when the memory
index exists, text search otherwise.  Returns paths, titles and snippets."
    ((query string "What to look for")
     (limit integer "Most results to return (default 10)" :optional t))
    :group 'secondbrain
    (condition-case err (cmacs-secondbrain-ingest-find-json query (or limit 10))
      (error (json-serialize (list :error (error-message-string err)))))))

(provide 'cmacs-secondbrain-ingest-tools)
;;; cmacs-secondbrain-ingest-tools.el ends here
