;;; cmacs-brigade-research.el --- libresearch as brigade tools  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; libresearch's cited answers and LQL queries, published to agents:
;; `web_research' and `web_lql'.  One registration reaches in-process
;; agents, CLI agents over the MCP relay and external MCP clients.
;;
;; Not `ai_research': the brigade allowlist refuses every `ai_' name
;; outright, and cmacs's own MCP tool of that name (cmacs-mcp-tools-ai.c)
;; is for external clients driving cmacs.  The two run the same request
;; through `cmacs-ai-research-sync-text'.
;;
;; The tools wait for their answer rather than returning a job id: a
;; research run is minutes, which is long, but an agent that asked a
;; question wants the answer and has nothing better to do meanwhile.
;; The request runs on a worker thread, and the wait polls instead of
;; reading events, so it neither freezes the editor's I/O nor trips
;; `inhibit-interaction' when the call arrives over MCP.

;;; Code:

(require 'cmacs-brigade-registry)
(require 'cmacs-ai-research)

(cmacs-brigade-deftool web-research
  "Research a question on the web and return a cited answer.  A
libresearch server searches, reads the most relevant pages and answers
with numbered citations [n], followed by the sources it cites (title
and URL).  Use it for questions that need current or external facts;
cite the sources you rely on.  Slow: a run takes one to several
minutes, longer with deep."
  ((question string "The question to answer, as a full sentence")
   (deep boolean "Let the server run follow-up searches (slower, more thorough)"
         :optional t)
   (pages integer "Pages to read, 1-20; omit for the server's default"
          :optional t))
  :group 'web
  (if (not (cmacs-ai-research-available-p))
      "Error: libresearch is not available in this cmacs build."
    (condition-case err
        (apply #'cmacs-ai-research-sync-text 'research question
               (append (and deep (not (eq deep :false)) (list :deep t))
                       (and (integerp pages) (> pages 0)
                            (list :pages (min pages 20)))))
      (error (format "Error: %s" (error-message-string err))))))

(cmacs-brigade-deftool web-lql
  "Run an LQL query on the libresearch metasearch server and return the
rows.  LQL is a pipeline over search results, e.g.
`search \"glib\", category: CODE | filter extra.stars > 100 | fields title, url'
or the shorthand `gtk docs | filter site(\"docs.gtk.org\")'.  With
explain, return the plan without running it.  Use web_research instead
for a plain question."
  ((query string "The LQL query")
   (explain boolean "Plan the query without running it" :optional t))
  :group 'web
  (if (not (cmacs-ai-research-available-p))
      "Error: libresearch is not available in this cmacs build."
    (condition-case err
        (apply #'cmacs-ai-research-sync-text 'lql query
               (append (and explain (not (eq explain :false))
                            (list :explain t))
                       (list :max-rows 100)))
      (error (format "Error: %s" (error-message-string err))))))

(declare-function cmacs-libresearch-search "cmacs-libresearch" (query &optional category))

(cmacs-brigade-deftool web-search-show
  "Open a libresearch web search in a results grid in the user's editor,
for the USER to read, sort, mark and act on.  Returns at once; it does
not return the results to you (use web_research or web_lql for that).
Use it when the user asks to see or browse search results."
  ((query string "What to search for")
   (category string "A category: general, news, code, science, it, ..."
             :optional t))
  :group 'web
  (if (not (and (cmacs-ai-research-available-p)
                (require 'cmacs-libresearch nil t)))
      "Error: libresearch is not available in this cmacs build."
    (condition-case err
        (progn
          (cmacs-libresearch-search query (and (stringp category)
                                               (not (string-empty-p category))
                                               category))
          (format "Opened a search for %S in the editor." query))
      (error (format "Error: %s" (error-message-string err))))))

;;;; LQL in cmacs itself (cmacs-lql.el): the same language over local
;;;; data -- files of any format, git, the journal, SQL, and the
;;;; editor's own state.  Read-only by construction.

(declare-function cmacs-lql-available-p "cmacs-lql" ())
(declare-function cmacs-lql-run-sync "cmacs-lql" (query &rest options))
(declare-function cmacs-lql-source-names "cmacs-lql" ())
(declare-function cmacs-lql--sources "cmacs-lql-defuns.c" ())

(defun cmacs-brigade-research--lql-available-p ()
  "Non-nil when local LQL is built in and loadable."
  (and (require 'cmacs-lql nil t) (cmacs-lql-available-p)))

(cmacs-brigade-deftool lql-query
  "Run an LQL query inside the editor and return the rows as a text
table.  LQL is a pipeline language: `fetch SOURCE | filter EXPR |
fields a, b | sort a DESC | summarize n = count(), by: {a} | limit N'.
Sources include files of any format (read \"path\"), git_log and the
other git_* sources, exec, journal, coredumps, sql, Kubernetes, and the
editor's own state: buffers, windows, processes, recentf, kill_ring,
bookmarks, org_headings, and the user's org notes repository: notes
(one row per file: para, scope, area, title, tags, created/updated,
todos, backlinks), note_headings, note_links and note_properties.  NULL
is three-valued: test presence with is_not_null(x), never x != null.
Call lql_sources for the full list.  Read-only."
  ((query string "The LQL query")
   (max_rows integer "Most rows to return (default 100)" :optional t))
  :group 'data
  (if (not (cmacs-brigade-research--lql-available-p))
      "Error: LQL is not built into this cmacs (--with-cmacs-lql)."
    (let ((p (cmacs-lql-run-sync query
                                 :max-rows (if (and (integerp max_rows) (> max_rows 0))
                                               (min max_rows 2000) 100)
                                 :text-width 160)))
      (pcase (car p)
        (:ok (format "%s\n(%d rows, %.3fs)"
                     (or (plist-get (cdr p) :text) "")
                     (plist-get (cdr p) :rows) (plist-get (cdr p) :elapsed)))
        (:error (concat "Error: " (cadr p)))
        (_ "Error: cancelled")))))

(cmacs-brigade-deftool lql-sources
  "List every LQL source lql_query can fetch from, including the
editor-state sources cmacs defines."
  ()
  :group 'data
  (if (not (cmacs-brigade-research--lql-available-p))
      "Error: LQL is not built into this cmacs (--with-cmacs-lql)."
    (condition-case nil
        (format "All sources: %s\nEditor sources: %s"
                (string-join (cmacs-lql--sources) ", ")
                (string-join (cmacs-lql-source-names) ", "))
      (error "Error: a query is running; try again"))))

(provide 'cmacs-brigade-research)
;;; cmacs-brigade-research.el ends here
