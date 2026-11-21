;;; cmacs-secondbrain-search-tools.el --- secondbrain_search over the tiers that exist  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `secondbrain_search' of cmacs/mcp/cmacs-mcp-tools-secondbrain.c, on
;; the capability table (doc_org/cmacs/cmacs-capability.org has the
;; recipe).  It is the one tool of that file whose C never worked:
;;
;;   - Its plain form evaluated `(cmacs-secondbrain-search QUERY)', a
;;     function no file defines.  Every call answered void-function.
;;
;;   - Its semantic form called `cmacs-secondbrain-search-semantic',
;;     which embeds the query SYNCHRONOUSLY -- a network round trip on
;;     the dispatch thread, which under `emacs --gowl' is the
;;     compositor's.
;;
;; So this is not a port.  It is the tool the schema describes, built on
;; the three search tiers the view really has, cheapest first:
;;
;;   1. substring   over the loaded nodes' titles, departments, kinds and
;;                  paths -- the matcher behind the interactive
;;                  `cmacs-secondbrain-find' (cmacs-secondbrain-nav.el),
;;                  so the tool and the `/' key agree on what matches,
;;                  including `cmacs-secondbrain-search-style'.  Instant.
;;
;;   2. semantic    the query is embedded ONCE, asynchronously
;;                  (`cmacs-brigade-memory--embed-async'), and ranked
;;                  against the notes index; the files that come back are
;;                  mapped to the nodes that stand for them.
;;
;;   3. sim edges   every node joined to a tier-2 hit by a `sim' edge is
;;                  added -- the similarity edges
;;                  `cmacs-secondbrain-add-similarity-edges' materialised,
;;                  if it was run.  They are already in the graph, so
;;                  this costs a walk of the edge list and nothing more.
;;
;; Without `semantic' only tier 1 runs and the tool answers at once.
;; With it, tiers 2 and 3 run and the answer comes from the embedding
;; callback.  Either way the result is highlighted in the view exactly as
;; the interactive search highlights it (`cmacs-secondbrain--flag-ids',
;; the one place that decides what a match looks like), and `n' / `N'
;; walk it.
;;
;; The answer is the list of matching node ids, printed as Lisp --
;; ("id-a" "id-b"), or nil -- which is what the C's semantic form
;; returned and what its plain form would have.
;;
;; Tier 2 ranks by the vectors alone.  `cmacs-brigade-memory-search'
;; also fuses in a ripgrep pass, run with `call-process'; a synchronous
;; subprocess is the thing a tool body must not start, and tier 1 has
;; already answered the "I know the name" question that pass exists for.

;;; Code:

(require 'cmacs-brigade-registry)

(defvar cmacs-secondbrain-buffer-name)
(defvar cmacs-secondbrain--graph)
(defvar cmacs-secondbrain--matches)
(defvar cmacs-secondbrain--match-index)
(defvar cmacs-secondbrain--search)
(defvar cmacs-brigade-embed-query-prefix)

(declare-function cmacs-secondbrain--build-haystacks "cmacs-secondbrain-nav" ())
(declare-function cmacs-secondbrain--matches-for "cmacs-secondbrain-nav"
                  (needle))
(declare-function cmacs-secondbrain--flag-ids "cmacs-secondbrain" (ids))
(declare-function cmacs-secondbrain--ids-for-paths "cmacs-secondbrain-search"
                  (paths))
(declare-function cmacs-brigade-memory--embed-async "cmacs-brigade-memory"
                  (texts on-ok on-error))
(declare-function cmacs-brigade-memory--ensure-open "cmacs-brigade-memory" ())
(declare-function cmacs-brigade-memory--load-meta "cmacs-brigade-memory" ())
(declare-function cmacs-brigade-index-search "cmacs-brigade-memory-defuns.c"
                  (handle vector k))

(defconst cmacs-secondbrain-search-tools--chunks 160
  "How many index rows the semantic tier ranks before mapping to nodes.
The interactive `cmacs-secondbrain-search-semantic' asks for 40 fused
results, which the memory layer over-fetches fourfold; this is that
same pool, taken straight from the index.")

(defun cmacs-secondbrain-search-tools--buffer ()
  "Return the second-brain buffer, or signal when the view is not open."
  (require 'cmacs-secondbrain)
  (or (get-buffer cmacs-secondbrain-buffer-name)
      (error "The second brain is not open; call secondbrain_open")))

(defun cmacs-secondbrain-search-tools--show (buffer query ids)
  "Highlight IDS in BUFFER as the result of QUERY; return them printed.
Sets the same state the interactive search leaves behind, so the match
set can be walked with `n' and `N' and a hover does not silently
replace a deliberate question."
  (with-current-buffer buffer
    (setq cmacs-secondbrain--matches (and ids (vconcat ids))
          cmacs-secondbrain--match-index 0
          cmacs-secondbrain--search (and ids query))
    (cmacs-secondbrain--flag-ids ids))
  (prin1-to-string ids))

(defun cmacs-secondbrain-search-tools--substring (buffer query)
  "Tier 1: return the ids in BUFFER's graph that match QUERY as text."
  (with-current-buffer buffer
    ;; Rebuilt each time: the graph may have been refreshed since the
    ;; last search, and stale haystacks name nodes that are gone.
    (cmacs-secondbrain--build-haystacks)
    (append (cmacs-secondbrain--matches-for query) nil)))

(defun cmacs-secondbrain-search-tools--sim-neighbours (buffer ids)
  "Tier 3: return the ids joined to any of IDS by a `sim' edge in BUFFER.
Ids already in IDS are not repeated.  nil when the graph carries no
similarity edges, which is the usual case until
`cmacs-secondbrain-add-similarity-edges' has been run."
  (let ((have (make-hash-table :test 'equal))
        (out nil))
    (dolist (id ids) (puthash id t have))
    (dolist (edge (plist-get (buffer-local-value 'cmacs-secondbrain--graph
                                                 buffer)
                             :edges))
      (when (eq (plist-get edge :edge-kind) 'sim)
        (let ((from (plist-get edge :from))
              (to (plist-get edge :to)))
          ;; Undirected: a hit at either end brings in the other.
          (pcase-dolist (`(,near . ,far) (list (cons from to) (cons to from)))
            (when (and (gethash near have) (not (gethash far have))
                       (not (member far out)))
              (push far out))))))
    (nreverse out)))

(defun cmacs-secondbrain-search-tools--semantic (done buffer query)
  "Tiers 2 and 3: rank QUERY against the notes index; answer through DONE.
Returns at once.  The embedding request is the only thing that can take
time, and it is asynchronous; ranking is a scan of an mmap'd array."
  (require 'cmacs-secondbrain-search)
  (unless (and (require 'cmacs-brigade-memory nil t)
               (fboundp 'cmacs-brigade-memory--embed-async)
               (fboundp 'cmacs-brigade-index-search))
    (error "%s" "The brigade memory index is not available; search without \
'semantic'"))
  ;; Opened before the request goes out, so "there is no index" is an
  ;; answer now rather than after a round trip to the embedder.
  (let ((handle (cmacs-brigade-memory--ensure-open))
        (meta (cmacs-brigade-memory--load-meta)))
    (unless (and handle meta)
      (error "%s" "No memory index (M-x cmacs-brigade-memory-build); search \
without 'semantic'"))
    (cmacs-brigade-memory--embed-async
     (list (concat cmacs-brigade-embed-query-prefix query))
     (lambda (vectors)
       (funcall
        done
        (condition-case err
            (if (not (buffer-live-p buffer))
                "Error: the second brain was closed while searching"
              (let* ((raw (cmacs-brigade-index-search
                           handle (car vectors)
                           cmacs-secondbrain-search-tools--chunks))
                     (paths (delete-dups
                             (delq nil
                                   (mapcar
                                    (lambda (hit)
                                      (let ((id (car hit)))
                                        (and (< id (length meta))
                                             (plist-get (aref meta id)
                                                        :path))))
                                    raw))))
                     (ids (with-current-buffer buffer
                            (cmacs-secondbrain--ids-for-paths paths))))
                (cmacs-secondbrain-search-tools--show
                 buffer query
                 (append ids
                         (cmacs-secondbrain-search-tools--sim-neighbours
                          buffer ids)))))
          (error (format "Error: %s" (error-message-string err))))))
     (lambda (message)
       (funcall done (format "Error: could not embed the query: %s"
                             message))))))

(cmacs-brigade-deftool secondbrain-search
  "Highlight nodes matching QUERY, dimming the rest.  By default a \
substring match over names and paths, which is instant.  Set \
'semantic' to embed the query and rank against the notes index \
instead -- slower, and worth it only when you do not know the name."
    ((query string "What to look for")
     (semantic boolean "Rank by meaning against the notes index"
               :optional t))
  ;; :async for the semantic tier; the substring tier calls `done'
  ;; before the body returns.
  :group 'secondbrain :async t :timeout 120
  :example "emacsctl tool secondbrain search --query wayland"
  (unless (and (stringp query) (not (string-empty-p query)))
    (error "%s" "secondbrain_search: missing 'query'"))
  (let ((buffer (cmacs-secondbrain-search-tools--buffer)))
    (if semantic
        (cmacs-secondbrain-search-tools--semantic done buffer query)
      (funcall done
               (cmacs-secondbrain-search-tools--show
                buffer query
                (cmacs-secondbrain-search-tools--substring buffer query))))))

(provide 'cmacs-secondbrain-search-tools)

;;; cmacs-secondbrain-search-tools.el ends here
