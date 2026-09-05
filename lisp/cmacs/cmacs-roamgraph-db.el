;;; cmacs-roamgraph-db.el --- org-roam data sources for the graph -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Where the roam graph's nodes and edges come from.  Isolated in its own
;; file so the rest of the subsystem degrades gracefully when no source
;; is reachable.
;;
;; The primary backend reads `org-roam.db' directly through Emacs's
;; builtin SQLite, NOT through `org-roam-db-query'.  That deliberately
;; avoids depending on the org-roam package (and on emacsql) being
;; loaded: a native subsystem should not require a straight.el package
;; to be present, and the schema is simple enough that going direct
;; costs nothing.  The database remains authoritative when it exists --
;; it already knows about aliases, refs, tags and heading-level nodes,
;; and reimplementing org's ID semantics would only drift from the one
;; implementation Emacs already owns.
;;
;; THE PRIN1 TRAP: emacsql stores values printed, not raw.  Every text
;; column comes back with literal surrounding double quotes, and
;; `properties'/`olp' are printed sexps.  Read nothing from this
;; database without `cmacs-roamgraph-db--unwrap'.

;;; Code:

(require 'cl-lib)
(require 'cmacs-para)
(require 'subr-x)

(defgroup cmacs-roamgraph nil
  "Native org-roam knowledge-graph visualiser."
  :group 'cmacs
  :prefix "cmacs-roamgraph-")

(defcustom cmacs-roamgraph-source 'auto
  "Where the graph's nodes and edges come from.

`roam-db'  read `cmacs-roamgraph-db-location' directly (authoritative)
`scan'     scan `cmacs-roamgraph-directory' for :ID: and [[id:]] links
`auto'     use the database when it opens, else fall back to the scanner

Additional backends can be registered in `cmacs-roamgraph-sources'."
  :type '(choice (const auto) (const roam-db) (const scan) symbol)
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-db-location
  (or (and (boundp 'org-roam-db-location) (symbol-value 'org-roam-db-location))
      (expand-file-name "org-roam.db" user-emacs-directory))
  "Path to the org-roam SQLite database."
  :type 'file
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-directory
  (or (and (boundp 'org-roam-directory) (symbol-value 'org-roam-directory))
      (and (boundp 'org-directory) (symbol-value 'org-directory))
      "~/org")
  "Root of the notes tree.

Used to make file paths relative for the PARA colour grouping, and as
the scan root for the native scanner backend."
  :type 'directory
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-include-cite-links nil
  "When non-nil, citation links become edges alongside [[id:]] links."
  :type 'boolean
  :group 'cmacs-roamgraph)

(defcustom cmacs-roamgraph-max-nodes 4000
  "Cap on how many nodes are handed to the renderer.

When the source returns more, the highest-degree nodes are kept and the
rest dropped, with a message saying so -- silently truncating would read
as \"this is your whole graph\" when it is not."
  :type 'integer
  :group 'cmacs-roamgraph)

;;;; The prin1 trap ----------------------------------------------------

(defun cmacs-roamgraph-db--unwrap (v)
  "Decode V as emacsql stored it.
Text columns are printed, so they arrive wrapped in literal double
quotes; integers arrive as integers.  Returns nil for NULL."
  (cond
   ((null v) nil)
   ((numberp v) v)
   ((not (stringp v)) v)
   ((and (> (length v) 1) (eq (aref v 0) ?\"))
    (condition-case nil
        (car (read-from-string v))
      ;; A malformed printed value is not worth aborting a whole
      ;; rebuild over; fall back to the raw text.
      (error v)))
   (t v)))

;;;; PARA grouping and colours -----------------------------------------
;;
;; The taxonomy itself lives in `cmacs-para', so roamgraph and the
;; second-brain visualiser cannot disagree about which bucket a file is
;; in.  These two remain as the names the rest of this file already
;; uses, and because roamgraph classifies against its own
;; `cmacs-roamgraph-directory' when that has been pointed somewhere
;; other than the shared roots.

(defun cmacs-roamgraph-db--group (file)
  "Return the PARA grouping bucket for FILE, or nil."
  (when (stringp file)
    (or (cmacs-para-bucket file)
        ;; `cmacs-roamgraph-directory' may point outside
        ;; `cmacs-para-roots' -- a scratch tree, or a second graph.
        ;; Classify against it directly rather than reporting nil.
        (when (stringp cmacs-roamgraph-directory)
          (let ((cmacs-para-roots (list cmacs-roamgraph-directory)))
            (cmacs-para-bucket file))))))

(defun cmacs-roamgraph-db--color (group)
  "Return the 0xRRGGBBAA colour for GROUP."
  (cmacs-para-color group))

;;;; Backend A: org-roam.db --------------------------------------------

(defun cmacs-roamgraph-db-available-p ()
  "Return non-nil if the org-roam database can be read right now."
  (and (fboundp 'sqlite-available-p)
       (sqlite-available-p)
       (stringp cmacs-roamgraph-db-location)
       (file-readable-p cmacs-roamgraph-db-location)))

(defun cmacs-roamgraph-db--open ()
  "Open the org-roam database read-only, or signal.
A busy timeout matters: org-roam may hold a write lock during a sync,
and failing instantly there would look like a missing database."
  (let ((db (sqlite-open cmacs-roamgraph-db-location)))
    (ignore-errors (sqlite-execute db "PRAGMA busy_timeout = 2000"))
    db))

(defun cmacs-roamgraph-db--multi-map (rows)
  "Fold ROWS of (NODE-ID VALUE) into a hash of id -> list of values."
  (let ((h (make-hash-table :test #'equal)))
    (dolist (r rows h)
      (let ((id (cmacs-roamgraph-db--unwrap (nth 0 r)))
            (v  (cmacs-roamgraph-db--unwrap (nth 1 r))))
        (when (and id v)
          (puthash id (cons v (gethash id h)) h))))))

(defun cmacs-roamgraph-db-fetch ()
  "Read nodes and edges from the org-roam database.
Returns a plist (:nodes VECTOR :edges VECTOR)."
  (unless (cmacs-roamgraph-db-available-p)
    (user-error "cmacs-roamgraph: no readable org-roam database at %s"
                cmacs-roamgraph-db-location))
  (let ((db (cmacs-roamgraph-db--open)))
    (unwind-protect
        (let* ((tags    (cmacs-roamgraph-db--multi-map
                         (sqlite-select db "SELECT node_id, tag FROM tags")))
               (aliases (cmacs-roamgraph-db--multi-map
                         (sqlite-select db "SELECT node_id, alias FROM aliases")))
               (refs    (ignore-errors
                          (cmacs-roamgraph-db--multi-map
                           (sqlite-select db "SELECT node_id, ref FROM refs"))))
               (node-rows (sqlite-select
                           db "SELECT id, file, level, pos, title, properties
                               FROM nodes"))
               ;; Only id links are topology.  A live notes tree also
               ;; carries thousands of https/file/fuzzy links whose
               ;; endpoints are not nodes at all; including them would
               ;; produce a hairball of dangling edges.
               (link-rows (sqlite-select
                           db (if cmacs-roamgraph-include-cite-links
                                  "SELECT source, dest, type FROM links
                                   WHERE type IN ('\"id\"', '\"cite\"')"
                                "SELECT source, dest, type FROM links
                                 WHERE type = '\"id\"'")))
               (nodes '())
               (edges '()))
          (dolist (r node-rows)
            (let* ((id    (cmacs-roamgraph-db--unwrap (nth 0 r)))
                   (file  (cmacs-roamgraph-db--unwrap (nth 1 r)))
                   (level (or (cmacs-roamgraph-db--unwrap (nth 2 r)) 0))
                   (pos   (or (cmacs-roamgraph-db--unwrap (nth 3 r)) 1))
                   (title (cmacs-roamgraph-db--unwrap (nth 4 r)))
                   ;; `properties' is a prin1'd alist of the node's org
                   ;; properties; CATEGORY is the one worth surfacing.
                   ;; Guarded: a malformed value is one node without a
                   ;; category, not a failed fetch.
                   (props (ignore-errors
                            (cmacs-roamgraph-db--unwrap (nth 5 r))))
                   (category (and (listp props)
                                  (cdr (assoc "CATEGORY" props))))
                   (group (cmacs-roamgraph-db--group file)))
              (when id
                (push (list :id id
                            :title (or title (file-name-base (or file id)))
                            :file file
                            :level (if (numberp level) level 0)
                            :pos (if (numberp pos) pos 1)
                            :tags (nreverse (gethash id tags))
                            :category (and (stringp category) category)
                            :aliases (nreverse (gethash id aliases))
                            :refs (and refs (nreverse (gethash id refs)))
                            :group group
                            :color (cmacs-roamgraph-db--color group))
                      nodes))))
          (dolist (r link-rows)
            (let ((from (cmacs-roamgraph-db--unwrap (nth 0 r)))
                  (to   (cmacs-roamgraph-db--unwrap (nth 1 r)))
                  (type (cmacs-roamgraph-db--unwrap (nth 2 r))))
              (when (and from to)
                (push (list :from from :to to
                            :kind (if (equal type "cite") 'cite 'id))
                      edges))))
          (list :nodes (vconcat (nreverse nodes))
                :edges (vconcat (nreverse edges))))
      (ignore-errors (sqlite-close db)))))

;;;; Backend B: native scanner -----------------------------------------

(defun cmacs-roamgraph-scan-available-p ()
  "Return non-nil if the native org scanner backend is usable."
  (and (fboundp 'cmacs-roamgraph-scan-supported-p)
       (cmacs-roamgraph-scan-supported-p)
       (file-directory-p (expand-file-name cmacs-roamgraph-directory))))

(defun cmacs-roamgraph-scan-fetch ()
  "Scan `cmacs-roamgraph-directory' for :ID: properties and [[id:]] links."
  (unless (cmacs-roamgraph-scan-available-p)
    (user-error "cmacs-roamgraph: the native scanner is not available"))
  (funcall (intern "cmacs-roamgraph-scan-directory")
           (expand-file-name cmacs-roamgraph-directory)))

;;;; Source registry ---------------------------------------------------

(defvar cmacs-roamgraph-sources
  `((roam-db . ,(lambda () (cmacs-roamgraph-db-fetch)))
    (scan    . ,(lambda () (cmacs-roamgraph-scan-fetch))))
  "Alist of SYMBOL to a thunk returning (:nodes VECTOR :edges VECTOR).
Add an entry here to teach roamgraph a new place to get a graph from.")

(defun cmacs-roamgraph-db--resolve-source ()
  "Return the source symbol to actually use."
  (if (eq cmacs-roamgraph-source 'auto)
      (cond ((cmacs-roamgraph-db-available-p) 'roam-db)
            ((cmacs-roamgraph-scan-available-p) 'scan)
            (t (user-error
                "cmacs-roamgraph: no org-roam database at %s and no scanner"
                cmacs-roamgraph-db-location)))
    cmacs-roamgraph-source))

(defun cmacs-roamgraph-db--degree-table (edges)
  "Return a hash of node id to degree over EDGES."
  (let ((h (make-hash-table :test #'equal)))
    (mapc (lambda (e)
            (let ((a (plist-get e :from)) (b (plist-get e :to)))
              (puthash a (1+ (gethash a h 0)) h)
              (puthash b (1+ (gethash b h 0)) h)))
          edges)
    h))

(defun cmacs-roamgraph-db--cap (nodes edges)
  "Trim NODES to `cmacs-roamgraph-max-nodes', keeping the best-connected.
EDGES referring to dropped nodes are removed too.  Reports what it
dropped rather than truncating silently."
  (if (<= (length nodes) cmacs-roamgraph-max-nodes)
      (list :nodes nodes :edges edges)
    (let* ((deg (cmacs-roamgraph-db--degree-table (append edges nil)))
           (sorted (sort (append nodes nil)
                         (lambda (a b)
                           (> (gethash (plist-get a :id) deg 0)
                              (gethash (plist-get b :id) deg 0)))))
           (kept (cl-subseq sorted 0 cmacs-roamgraph-max-nodes))
           (live (let ((h (make-hash-table :test #'equal)))
                   (dolist (n kept h) (puthash (plist-get n :id) t h)))))
      (message "cmacs-roamgraph: showing the %d best-connected of %d nodes"
               cmacs-roamgraph-max-nodes (length nodes))
      (list :nodes (vconcat kept)
            :edges (vconcat
                    (cl-remove-if-not
                     (lambda (e) (and (gethash (plist-get e :from) live)
                                      (gethash (plist-get e :to) live)))
                     (append edges nil)))))))

(defun cmacs-roamgraph-fetch (&optional source)
  "Fetch the graph from SOURCE (default `cmacs-roamgraph-source').
Returns a plist (:nodes VECTOR :edges VECTOR :source SYMBOL)."
  (let* ((sym (or source (cmacs-roamgraph-db--resolve-source)))
         (thunk (cdr (assq sym cmacs-roamgraph-sources))))
    (unless thunk
      (user-error "cmacs-roamgraph: unknown source `%s'" sym))
    (let* ((raw (funcall thunk))
           (capped (cmacs-roamgraph-db--cap (plist-get raw :nodes)
                                            (plist-get raw :edges))))
      (list :nodes (plist-get capped :nodes)
            :edges (plist-get capped :edges)
            :source sym))))

;;;; Neighbourhood extraction ------------------------------------------

(defun cmacs-roamgraph-subgraph (graph root hops)
  "Return the sub-plist of GRAPH within HOPS of node id ROOT.
Used by the local-graph entry points.  Traverses links in both
directions: a note's backlinks are as much its neighbourhood as its
forward links are."
  (let* ((nodes (append (plist-get graph :nodes) nil))
         (edges (append (plist-get graph :edges) nil))
         (adj (make-hash-table :test #'equal))
         (seen (make-hash-table :test #'equal))
         (frontier (list root)))
    (dolist (e edges)
      (let ((a (plist-get e :from)) (b (plist-get e :to)))
        (puthash a (cons b (gethash a adj)) adj)
        (puthash b (cons a (gethash b adj)) adj)))
    (puthash root t seen)
    (dotimes (_ (max 0 hops))
      (let (next)
        (dolist (id frontier)
          (dolist (nb (gethash id adj))
            (unless (gethash nb seen)
              (puthash nb t seen)
              (push nb next))))
        (setq frontier next)))
    (list :nodes (vconcat (cl-remove-if-not
                           (lambda (n) (gethash (plist-get n :id) seen))
                           nodes))
          :edges (vconcat (cl-remove-if-not
                           (lambda (e) (and (gethash (plist-get e :from) seen)
                                            (gethash (plist-get e :to) seen)))
                           edges))
          :source (plist-get graph :source))))

(provide 'cmacs-roamgraph-db)

;;; cmacs-roamgraph-db.el ends here
