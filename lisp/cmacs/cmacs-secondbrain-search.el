;;; cmacs-secondbrain-search.el --- semantic search and similarity edges  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The second and third tiers of finding something in the brain.  The
;; first -- substring over the loaded node set -- lives in
;; `cmacs-secondbrain' and costs nothing; this is what you reach for when
;; you do not know the name.
;;
;; The ordering is the point, and it is the same argument the deterministic
;; retrieval path makes: most of a lookup needs no intelligence at all, so
;; spend none.  A substring match over a few thousand titles is
;; instantaneous and answers most questions.  Only when it does not do you
;; pay for an embedding.
;;
;;   1. substring          (cmacs-secondbrain-search, elsewhere)
;;   2. semantic           embed the query once, rank against the index
;;   3. similarity edges   materialise "these are about the same thing"
;;                         as edges you can see
;;
;; All of it reuses `cmacs-brigade-memory' rather than rebuilding it: the
;; fp16 index, the query embedding and the reciprocal-rank fusion already
;; exist and are already tuned.
;;
;; Similarity edges are also offered to roamgraph, which has carried the
;; `sim' edge kind -- parsed, weighted 0.35 in the solver, rendered violet,
;; excluded from link navigation -- since before anything emitted one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Declared, not required: cmacs-secondbrain.el pulls this file in from
;; its mode body, so requiring it back would be circular.
(defvar cmacs-secondbrain--graph)
(defvar cmacs-secondbrain--selected)
(defvar cmacs-secondbrain--3d)

(declare-function cmacs-secondbrain-node-at "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-set-graph "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-apply-flags "cmacs-secondbrain-defuns")
(declare-function cmacs-brigade-memory-search "cmacs-brigade-memory")
(declare-function cmacs-brigade-memory-embed-query "cmacs-brigade-memory")
(declare-function cmacs-libregnum-set-match-set "cmacs-libregnum")
(declare-function cmacs-ai-embed "cmacs-ai-embed")
(declare-function cmacs-ai-embed-cosine "cmacs-ai-embed")

(defcustom cmacs-secondbrain-similar-count 8
  "How many neighbours `cmacs-secondbrain-find-similar' surfaces."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-sim-threshold 0.62
  "Minimum cosine for a similarity edge.

Deliberately high.  Below roughly this, an embedding model will relate
almost any two pieces of prose in the same corpus, and an edge that
means \"both of these are in English\" is worse than no edge -- it adds
ink and removes signal."
  :type 'float
  :group 'cmacs-secondbrain)

(defun cmacs-secondbrain--memory-available-p ()
  "Return non-nil when the brigade memory index can answer a query."
  (and (fboundp 'cmacs-brigade-memory-search)
       (fboundp 'cmacs-brigade-memory-embed-query)))

;;;; Tier 2: semantic search ------------------------------------------

(defun cmacs-secondbrain--ids-for-paths (paths)
  "Return graph ids whose :file is in PATHS."
  (let ((want (make-hash-table :test 'equal)) (out nil))
    (dolist (p paths) (puthash (expand-file-name p) t want))
    (dolist (n (plist-get cmacs-secondbrain--graph :nodes))
      (let ((f (plist-get n :file)))
        (when (and f (gethash (expand-file-name f) want))
          (push (plist-get n :id) out))))
    (nreverse out)))

;;;###autoload
(defun cmacs-secondbrain-search-semantic (query)
  "Highlight nodes semantically close to QUERY.

Unlike the substring search this costs an embedding round trip, so it is
a deliberate second step rather than something that runs as you type.
The call is synchronous -- fine for one query off a keystroke, and
exactly what you must not do per node or inside a layout loop."
  (interactive "sSemantic search: ")
  (unless (cmacs-secondbrain--memory-available-p)
    (user-error "cmacs-secondbrain: the brigade memory index is not available"))
  (message "Embedding query…")
  (let* ((hits (cmacs-brigade-memory-search query 40))
         (paths (delete-dups (mapcar (lambda (h) (plist-get h :path)) hits)))
         (ids (cmacs-secondbrain--ids-for-paths paths)))
    (when (fboundp 'cmacs-libregnum-set-match-set)
      (cmacs-libregnum-set-match-set (current-buffer) ids (and ids t)))
    (cmacs-secondbrain-apply-flags (current-buffer))
    (message "%d semantic match%s from %d chunk%s"
             (length ids) (if (= 1 (length ids)) "" "es")
             (length hits) (if (= 1 (length hits)) "" "s"))
    ids))

;;;###autoload
(defun cmacs-secondbrain-find-similar (&optional id)
  "Highlight the nodes most similar to ID (default: the selection)."
  (interactive)
  (let* ((id (or id cmacs-secondbrain--selected))
         (node (and id (cmacs-secondbrain-node-at (current-buffer) id)))
         (file (plist-get node :file)))
    (unless node (user-error "Nothing selected"))
    (unless (cmacs-secondbrain--memory-available-p)
      (user-error "cmacs-secondbrain: the brigade memory index is not available"))
    ;; Query by the node's own text when it has a file, by its title when
    ;; it does not -- an application or a routine still has a name worth
    ;; matching against the corpus.
    (let ((query (if (and file (file-readable-p file))
                     (with-temp-buffer
                       (insert-file-contents file nil 0 2000)
                       (buffer-string))
                   (or (plist-get node :title) id))))
      (let* ((hits (cmacs-brigade-memory-search
                    query cmacs-secondbrain-similar-count))
             (paths (delete-dups (mapcar (lambda (h) (plist-get h :path)) hits)))
             (ids (cl-remove id (cmacs-secondbrain--ids-for-paths paths)
                             :test #'equal)))
        (when (fboundp 'cmacs-libregnum-set-match-set)
          (cmacs-libregnum-set-match-set (current-buffer) ids (and ids t)))
        (cmacs-secondbrain-apply-flags (current-buffer))
        (message "%d similar to %s" (length ids)
                 (or (plist-get node :title) id))
        ids))))

;;;; Tier 3: similarity edges -----------------------------------------

(defun cmacs-secondbrain--sim-edges-for (nodes k)
  "Return `sim' edge plists among NODES, K neighbours each.

Only nodes backed by a readable file participate: the index is built
over file chunks, so an application node has nothing to match on."
  (let ((edges nil)
        (seen (make-hash-table :test 'equal))
        (by-path (make-hash-table :test 'equal)))
    (dolist (n nodes)
      (let ((f (plist-get n :file)))
        (when f (puthash (expand-file-name f) (plist-get n :id) by-path))))
    (dolist (n nodes)
      (let ((f (plist-get n :file))
            (id (plist-get n :id)))
        (when (and f (file-readable-p f))
          (let* ((text (with-temp-buffer
                         (insert-file-contents f nil 0 2000)
                         (buffer-string)))
                 (hits (ignore-errors (cmacs-brigade-memory-search text k))))
            (dolist (h hits)
              (let* ((score (plist-get h :score))
                     (other (gethash (expand-file-name
                                      (or (plist-get h :path) ""))
                                     by-path)))
                (when (and other
                           (not (equal other id))
                           (numberp score)
                           (>= score cmacs-secondbrain-sim-threshold))
                  ;; Undirected: A~B and B~A are one edge.  The graph
                  ;; would dedup them anyway, but emitting both doubles
                  ;; the work for nothing.
                  (let ((key (if (string< id other)
                                 (concat id "\0" other)
                               (concat other "\0" id))))
                    (unless (gethash key seen)
                      (puthash key t seen)
                      (push (list :from id :to other
                                  :edge-kind 'sim :weight score)
                            edges))))))))))
    (nreverse edges)))

;;;###autoload
(defun cmacs-secondbrain-add-similarity-edges (&optional k)
  "Overlay similarity edges on the current graph.

K neighbours per node, default 4.  Slow and deliberate: one index query
per file-backed node, run once rather than on every rebuild.  The edges
land as kind `sim', which the solver weights at 0.35 so they nudge the
layout without competing with real structure, and which link navigation
ignores."
  (interactive "P")
  (unless (cmacs-secondbrain--memory-available-p)
    (user-error "cmacs-secondbrain: the brigade memory index is not available"))
  (let* ((k (if (numberp k) k 4))
         (g cmacs-secondbrain--graph)
         (nodes (plist-get g :nodes)))
    (message "cmacs-secondbrain: computing similarity edges…")
    (let* ((sim (cmacs-secondbrain--sim-edges-for nodes k))
           (edges (append (plist-get g :edges) sim)))
      (setq cmacs-secondbrain--graph (plist-put (copy-sequence g) :edges edges))
      (cmacs-secondbrain-set-graph (current-buffer)
                                   (vconcat nodes) (vconcat edges)
                                   (if cmacs-secondbrain--3d 3 2))
      (message "cmacs-secondbrain: %d similarity edge%s added"
               (length sim) (if (= 1 (length sim)) "" "s")))))

;;;; The same capability, for roamgraph -------------------------------

;;;###autoload
(defun cmacs-roamgraph-similarity-edges (&optional k)
  "Overlay similarity edges on the roamgraph view.

roamgraph has carried the `sim' edge kind since before anything emitted
one: it is parsed, weighted 0.35 in the solver so it nudges without
competing with real structure, rendered violet so it is never mistaken
for a link you wrote, and excluded from `[' / `]' navigation.  This is
the caller it was waiting for."
  (interactive "P")
  (unless (derived-mode-p 'cmacs-roamgraph-mode)
    (user-error "Not in a roamgraph buffer"))
  (unless (cmacs-secondbrain--memory-available-p)
    (user-error "The brigade memory index is not available"))
  (let* ((k (if (numberp k) k 4))
         (g (and (boundp 'cmacs-roamgraph--full-graph)
                 (symbol-value 'cmacs-roamgraph--full-graph)))
         (nodes (append (plist-get g :nodes) nil)))
    (unless nodes (user-error "No graph loaded"))
    (message "cmacs-roamgraph: computing similarity edges…")
    (let* ((sim (cmacs-secondbrain--sim-edges-for nodes k))
           ;; roamgraph spells the edge-kind key `:kind'.
           (sim (mapcar (lambda (e)
                          (list :from (plist-get e :from)
                                :to (plist-get e :to)
                                :kind 'sim
                                :weight (plist-get e :weight)))
                        sim))
           (edges (append (plist-get g :edges) sim)))
      (set (intern "cmacs-roamgraph--full-graph")
           (plist-put (copy-sequence g) :edges edges))
      (when (fboundp 'cmacs-roamgraph--apply-filter)
        (funcall (intern "cmacs-roamgraph--apply-filter")))
      (message "cmacs-roamgraph: %d similarity edge%s added"
               (length sim) (if (= 1 (length sim)) "" "s")))))

(provide 'cmacs-secondbrain-search)

;;; cmacs-secondbrain-search.el ends here
