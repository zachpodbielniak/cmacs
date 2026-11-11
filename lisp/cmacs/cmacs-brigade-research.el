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

(provide 'cmacs-brigade-research)
;;; cmacs-brigade-research.el ends here
