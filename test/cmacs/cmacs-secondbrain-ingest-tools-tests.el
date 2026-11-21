;;; cmacs-secondbrain-ingest-tools-tests.el --- The ingester's tools and secondbrain_search on the capability table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-secondbrain-ingest-tools.el registered four of the
;; second brain's tools before the capability table existed, and they
;; had drifted from the C tools of the same names
;; (cmacs/mcp/cmacs-mcp-tools-secondbrain.c).  They are the C's again;
;; the first test here is the guard that keeps it so: name, description,
;; parameters in order, types, enums and the required set, against the
;; frozen wire schema (test/cmacs/data/mcp-wire-schema.json, read
;; through cmacs-wire-schema.el).  The C itself has been deleted.
;;
;; lisp/cmacs/cmacs-secondbrain-search-tools.el is `secondbrain_search',
;; whose C called a function that does not exist.  It is tested against
;; a stubbed view: the substring tier answers at once, the semantic tier
;; answers from the embedding callback and never blocks, and the
;; similarity-edge tier adds the neighbours of what the second found.
;;
;; Everything runs against a private registry with the C mirror stubbed.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)
;; Beside this file, and named by its place: `make check' compiles
;; and runs the tests with test/cmacs off `load-path', where a bare
;; `require' of a helper fails the whole file -- silently for the count
;; of failed tests, which then covers every file but this one.
(require 'cmacs-wire-schema
         (expand-file-name
          "cmacs-wire-schema"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

;; Special here too, so the bindings below are dynamic in compiled code.
(defvar cmacs-secondbrain-buffer-name)
(defvar cmacs-secondbrain--graph)
(defvar cmacs-secondbrain--matches)
(defvar cmacs-secondbrain--match-index)
(defvar cmacs-secondbrain--search)
(defvar cmacs-brigade-embed-query-prefix)

(defconst cmacs-secondbrain-ingest-tools-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, captured at load time.")

(defun cmacs-secondbrain-ingest-tools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or cmacs-secondbrain-ingest-tools-tests--this-file
                  default-directory)
              "lisp/cmacs/cmacs-secondbrain-ingest-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun cmacs-secondbrain-ingest-tools-tests--literals (text)
  "Return the C string literals in TEXT, concatenated and unescaped."
  (let ((pos 0) (parts nil))
    (while (string-match "\"\\(\\(?:[^\"\\\\\n]\\|\\\\.\\)*\\)\"" text pos)
      (push (match-string 1 text) parts)
      (setq pos (match-end 0)))
    (replace-regexp-in-string
     "\\\\\\(.\\)" "\\1" (apply #'concat (nreverse parts)))))

(defmacro cmacs-secondbrain-ingest-tools-tests--with-family (file &rest body)
  "Run BODY with a private registry holding only the tools FILE registers."
  (declare (indent 1) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       (let ((load-prefer-newer t))
         (load (expand-file-name
                (concat "lisp/cmacs/" ,file)
                (cmacs-secondbrain-ingest-tools-tests--root))
               nil t))
       ,@body)))

(defun cmacs-secondbrain-ingest-tools-tests--check (names)
  "Assert each registry tool in NAMES is the tool the C published.
Name, description, and each parameter's name, type, required-ness and
enum, against the frozen wire schema (cmacs-wire-schema.el)."
  (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                               (cmacs-capability-describe))
                       #'string<)
                 (sort (copy-sequence names) #'string<)))
  (dolist (name names)
    (should (equal (alist-get 'source (cmacs-wire-schema-tool name))
                   "cmacs-mcp-tools-secondbrain.c"))
    (cmacs-wire-schema-should-match name :description t :enum t)))


;;;; The ingester's four tools

(ert-deftest cmacs-secondbrain-ingest-tools-test-family-matches-c ()
  "The four ingest tools are the C ones: nothing reduced, nothing renamed."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-ingest-tools"
    (cmacs-secondbrain-ingest-tools-tests--check
     '("secondbrain_ingest" "secondbrain_ingest_status" "secondbrain_tree"
       "secondbrain_find"))
    ;; The drift this file had: eight parameters of twenty-two, one of
    ;; them renamed, `input' required, and a wait.
    (let ((entry (cmacs-capability-describe-tool "secondbrain_ingest")))
      (should (= (length (plist-get entry :params)) 22))
      (should-not (cl-some (lambda (p) (plist-get p :required))
                           (plist-get entry :params)))
      (should-not (plist-get entry :async)))
    (should-not (plist-get
                 (car (plist-get (cmacs-capability-describe-tool
                                  "secondbrain_ingest_status")
                                 :params))
                 :required))))

(ert-deftest cmacs-secondbrain-ingest-tools-test-loads-nothing ()
  "The family file pulls in the registry and nothing of the ingester."
  (let ((root (cmacs-secondbrain-ingest-tools-tests--root)))
    (skip-unless root)
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "lisp/cmacs/cmacs-secondbrain-ingest-tools.el" root))
      ;; It is loaded at startup so its tools are listed; the ingester
      ;; (extractors, fetchers, the model plumbing) loads on first use.
      (should-not (re-search-forward "^(require 'cmacs-secondbrain-ingest"
                                     nil t))
      (goto-char (point-min))
      (should (re-search-forward "^(require 'cmacs-brigade-registry)" nil t)))))

(ert-deftest cmacs-secondbrain-ingest-tools-test-ingest-queues ()
  "`secondbrain_ingest' hands the C's JSON to the one parser and returns."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-ingest-tools"
    (cl-progv '(features) (list (cons 'cmacs-secondbrain-ingest features))
      (let ((calls nil))
        (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-from-json)
                   (lambda (inputs options &rest _)
                     (push (list inputs
                                 (json-parse-string options
                                                    :object-type 'alist
                                                    :false-object :false))
                           calls)
                     "[{\"id\":\"sbi-1\",\"stage\":\"queued\"}]")))
          ;; The reply is the queued jobs, straight away.
          (should (equal (cmacs-brigade-call-tool
                          "secondbrain_ingest"
                          "{\"input\":\"https://example.org/a\",\"para\":\"resources\",\"type\":\"book\",\"tags\":\"a,b\",\"depth\":2,\"crawl\":true,\"keep_source\":true}")
                         "[{\"id\":\"sbi-1\",\"stage\":\"queued\"}]"))
          (should (equal (car (car calls)) "[\"https://example.org/a\"]"))
          (let ((options (cadr (car calls))))
            (should (equal (alist-get 'para options) "resources"))
            ;; The C's name for it, which this file used to spell
            ;; `summary_type'.
            (should (equal (alist-get 'type options) "book"))
            (should (equal (alist-get 'tags options) "a,b"))
            (should (equal (alist-get 'depth options) 2))
            (should (eq (alist-get 'crawl options) t))
            ;; A string on the Elisp side, as the C spelt it.
            (should (equal (alist-get 'keep_source options) "copy"))
            ;; Absent means yes: nothing is passed on.
            (should-not (assq 'link options))
            (should-not (assq 'dry_run options)))
          ;; Text alone is a call; the inputs array is then empty.
          (cmacs-brigade-call-tool
           "secondbrain_ingest"
           "{\"text\":\"a note\",\"title\":\"T\",\"link\":false,\"dry_run\":true}")
          (should (equal (car (car calls)) "[]"))
          (let ((options (cadr (car calls))))
            (should (equal (alist-get 'text options) "a note"))
            (should (equal (alist-get 'title options) "T"))
            ;; The one boolean whose false is the message.
            (should (eq (alist-get 'link options) :false))
            (should (eq (alist-get 'dry_run options) t)))
          ;; An explicit true is the default, and says nothing.
          (cmacs-brigade-call-tool "secondbrain_ingest"
                                   "{\"text\":\"x\",\"link\":true}")
          (should-not (assq 'link (cadr (car calls))))
          ;; Neither input nor text: refused before the ingester loads.
          (setq calls nil)
          (should (string-prefix-p
                   "Error: secondbrain_ingest: give 'input'"
                   (cmacs-brigade-call-tool "secondbrain_ingest" "{}")))
          (should (string-prefix-p
                   "Error: secondbrain_ingest: give 'input'"
                   (cmacs-brigade-call-tool
                    "secondbrain_ingest" "{\"input\":\"\",\"text\":\"\"}")))
          (should-not calls)
          ;; A failure is a failure, not {"error": ...} as a result.
          (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-from-json)
                     (lambda (&rest _) (error "no such file"))))
            (should (equal (cmacs-brigade-call-tool
                            "secondbrain_ingest" "{\"input\":\"/nope\"}")
                           "Error: no such file"))))))))

(ert-deftest cmacs-secondbrain-ingest-tools-test-status-tree-find ()
  "Status lists every job without an id; tree and find pass values."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-ingest-tools"
    (cl-progv '(features) (list (cons 'cmacs-secondbrain-ingest features))
      (let ((log nil))
        (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-status-json)
                   (lambda (id &rest _) (format "{\"id\":\"%s\"}" id)))
                  ((symbol-function 'cmacs-secondbrain-ingest-list-json)
                   (lambda (&rest _) "[{\"id\":\"sbi-1\"},{\"id\":\"sbi-2\"}]"))
                  ((symbol-function 'cmacs-secondbrain-ingest-tree)
                   (lambda (&rest args) (push (cons 'tree args) log)
                     '("03_resources/" "03_resources/linux/")))
                  ((symbol-function 'cmacs-secondbrain-ingest-find-json)
                   (lambda (&rest args) (push (cons 'find args) log) "[]")))
          (should (equal (cmacs-brigade-call-tool
                          "secondbrain_ingest_status" "{\"id\":\"sbi-2\"}")
                         "{\"id\":\"sbi-2\"}"))
          ;; The drift: this used to demand an id.
          (dolist (json '(nil "{}" "{\"id\":\"\"}"))
            (should (equal (cmacs-brigade-call-tool
                            "secondbrain_ingest_status" json)
                           "[{\"id\":\"sbi-1\"},{\"id\":\"sbi-2\"}]")))
          (should (equal (cmacs-brigade-call-tool
                          "secondbrain_tree"
                          "{\"para\":\"resources\",\"files\":true}")
                         "[\"03_resources/\",\"03_resources/linux/\"]"))
          (should (equal (car log) '(tree nil "resources" nil t)))
          (cmacs-brigade-call-tool "secondbrain_tree" "{\"para\":\"\"}")
          (should (equal (car log) '(tree nil nil nil nil)))
          (cmacs-brigade-call-tool "secondbrain_find" "{\"query\":\"wayland\"}")
          (should (equal (car log) '(find "wayland" 10)))
          (cmacs-brigade-call-tool "secondbrain_find"
                                   "{\"query\":\"wayland\",\"limit\":3}")
          (should (equal (car log) '(find "wayland" 3)))
          ;; The C's rule: a limit that is not positive is the default.
          (cmacs-brigade-call-tool "secondbrain_find"
                                   "{\"query\":\"wayland\",\"limit\":0}")
          (should (equal (car log) '(find "wayland" 10)))
          (should (equal (cmacs-brigade-call-tool "secondbrain_find"
                                                  "{\"query\":\"\"}")
                         "Error: secondbrain_find: missing 'query'")))))))


;;;; secondbrain_search

(ert-deftest cmacs-secondbrain-search-tools-test-matches-c-schema ()
  "`secondbrain_search' keeps the C tool's name, description and schema."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-search-tools"
    (cmacs-secondbrain-ingest-tools-tests--check '("secondbrain_search"))
    (should (plist-get (cmacs-capability-describe-tool "secondbrain_search")
                       :async))))

(defmacro cmacs-secondbrain-search-tools-tests--with-view (&rest body)
  "Run BODY with a stand-in second-brain view.
BODY sees `view' (the buffer), `flagged' (the ids last highlighted, or
the symbol `unset'), and the embedding stub's `embed-ok' / `embed-fail'
callbacks once a semantic search has started."
  (declare (indent 0) (debug t))
  `(let* ((cmacs-secondbrain-buffer-name " *cmacs-secondbrain-search-tests*")
          (cmacs-brigade-embed-query-prefix "search_query: ")
          (view (get-buffer-create cmacs-secondbrain-buffer-name))
          (flagged 'unset) (embedded nil) (embed-ok nil) (embed-fail nil)
          (titles '(("n-wayland" . "wayland protocols")
                    ("n-gowl" . "gowl compositor")
                    ("n-tax" . "tax return 2025")
                    ("n-wl2" . "notes on wayland security"))))
     (ignore flagged embedded embed-ok embed-fail)
     (unwind-protect
         (cl-progv '(features)
             (list (append '(cmacs-secondbrain cmacs-secondbrain-search
                             cmacs-brigade-memory)
                           features))
           (with-current-buffer view
             (setq-local cmacs-secondbrain--graph
                         (list :nodes
                               (list '(:id "n-wayland" :file "/n/wayland.org")
                                     '(:id "n-gowl" :file "/n/gowl.org")
                                     '(:id "n-tax" :file "/n/tax.org")
                                     '(:id "n-wl2" :file "/n/wl2.org"))
                               :edges
                               (list '(:from "n-wayland" :to "n-gowl"
                                       :edge-kind link)
                                     '(:from "n-tax" :to "n-wl2"
                                       :edge-kind sim :weight 0.7))))
             (setq-local cmacs-secondbrain--matches nil)
             (setq-local cmacs-secondbrain--match-index 0)
             (setq-local cmacs-secondbrain--search nil))
           (cl-letf
               (((symbol-function 'cmacs-secondbrain--build-haystacks)
                 (lambda (&rest _) nil))
                ;; Tier 1's matcher: substring over the titles.
                ((symbol-function 'cmacs-secondbrain--matches-for)
                 (lambda (needle &rest _)
                   (vconcat (cl-loop for (id . title) in titles
                                     when (string-search (downcase needle) title)
                                     collect id))))
                ((symbol-function 'cmacs-secondbrain--flag-ids)
                 (lambda (ids &rest _) (setq flagged ids)))
                ((symbol-function 'cmacs-secondbrain--ids-for-paths)
                 (lambda (paths &rest _)
                   (cl-loop for n in (plist-get cmacs-secondbrain--graph :nodes)
                            when (member (plist-get n :file) paths)
                            collect (plist-get n :id))))
                ;; The embedder: records the request and returns.  The
                ;; test decides when, and whether, it answers.
                ((symbol-function 'cmacs-brigade-memory--embed-async)
                 (lambda (texts on-ok on-error &rest _)
                   (setq embedded texts embed-ok on-ok embed-fail on-error)
                   1))
                ((symbol-function 'cmacs-brigade-memory--ensure-open)
                 (lambda (&rest _) 7))
                ((symbol-function 'cmacs-brigade-memory--load-meta)
                 (lambda (&rest _)
                   (vector '(:path "/n/tax.org") '(:path "/n/elsewhere.org")
                           '(:path "/n/tax.org"))))
                ((symbol-function 'cmacs-brigade-index-search)
                 (lambda (&rest _) '((0 . 0.9) (1 . 0.8) (2 . 0.7) (99 . 0.1))))
                ;; Anything that waits is the bug this tool must not have.
                ((symbol-function 'cmacs-brigade-memory-search)
                 (lambda (&rest _) (error "the synchronous search was called")))
                ((symbol-function 'sit-for)
                 (lambda (&rest _) (error "a search tool called sit-for"))))
             ,@body))
       (kill-buffer view))))

(defun cmacs-secondbrain-search-tools-tests--call (json)
  "Start `secondbrain_search' with JSON; return a cell receiving the reply."
  (let ((cell (list nil)))
    (cmacs-brigade-call-tool-async
     "secondbrain_search" json
     (lambda (status text) (setcar cell (list status text))))
    cell))

(ert-deftest cmacs-secondbrain-search-tools-test-substring ()
  "Tier 1 answers before the call returns, and highlights what it found."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-search-tools"
    (cmacs-secondbrain-search-tools-tests--with-view
      (let ((reply (cmacs-secondbrain-search-tools-tests--call
                    "{\"query\":\"Wayland\"}")))
        (should (equal (car reply) '(ok "(\"n-wayland\" \"n-wl2\")")))
        (should (equal flagged '("n-wayland" "n-wl2")))
        ;; No embedding was asked for.
        (should-not embedded)
        ;; The state the interactive search leaves, so n / N walk it.
        (with-current-buffer view
          (should (equal cmacs-secondbrain--matches ["n-wayland" "n-wl2"]))
          (should (equal cmacs-secondbrain--search "Wayland"))))
      ;; Nothing matched: nil, and the highlight is cleared.
      (let ((reply (cmacs-secondbrain-search-tools-tests--call
                    "{\"query\":\"zzz\"}")))
        (should (equal (car reply) '(ok "nil")))
        (should (null flagged))
        (with-current-buffer view
          (should-not cmacs-secondbrain--search)))
      (should (equal (car (cmacs-secondbrain-search-tools-tests--call "{}"))
                     ;; The dispatcher's own missing-argument refusal.
                     (car (cmacs-secondbrain-search-tools-tests--call
                           "{\"semantic\":false}"))))
      (should (equal (car (cmacs-secondbrain-search-tools-tests--call
                           "{\"query\":\"\"}"))
                     '(error "secondbrain_search: missing 'query'"))))))

(ert-deftest cmacs-secondbrain-search-tools-test-view-must-be-open ()
  "With no view there is nothing to highlight, and the tool says so."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-search-tools"
    (cl-progv '(features) (list (cons 'cmacs-secondbrain features))
      (let ((cmacs-secondbrain-buffer-name " *no-such-second-brain*"))
        (should (equal (car (cmacs-secondbrain-search-tools-tests--call
                             "{\"query\":\"wayland\"}"))
                       '(error "The second brain is not open; call secondbrain_open")))))))

(ert-deftest cmacs-secondbrain-search-tools-test-semantic-is-async ()
  "Tiers 2 and 3: embedded once, off the dispatch, plus `sim' neighbours."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-search-tools"
    (cmacs-secondbrain-search-tools-tests--with-view
      (let ((reply (cmacs-secondbrain-search-tools-tests--call
                    "{\"query\":\"money owed\",\"semantic\":true}")))
        ;; Started and not answered: the call returned while the
        ;; embedder had not.
        (should-not (car reply))
        (should (eq flagged 'unset))
        (should (equal embedded '("search_query: money owed")))
        (funcall embed-ok (list [0.1 0.2]))
        ;; Tier 2 found the tax note (two chunks, one node; the chunk of
        ;; a file with no node and the out-of-range row are dropped);
        ;; tier 3 added the note a `sim' edge joins to it -- and not the
        ;; one a plain link does.
        (should (equal (car reply) '(ok "(\"n-tax\" \"n-wl2\")")))
        (should (equal flagged '("n-tax" "n-wl2")))
        ;; A second answer from the embedder changes nothing.
        (funcall embed-ok (list [0.1 0.2]))
        (should (equal (car reply) '(ok "(\"n-tax\" \"n-wl2\")"))))
      ;; The embedder failing is a failed call.
      (let ((reply (cmacs-secondbrain-search-tools-tests--call
                    "{\"query\":\"x\",\"semantic\":true}")))
        (funcall embed-fail "connection refused")
        (should (equal (car reply)
                       '(error "could not embed the query: connection refused"))))
      ;; No index: an answer now, not after a round trip.
      (setq embedded nil)
      (cl-letf (((symbol-function 'cmacs-brigade-memory--load-meta)
                 (lambda (&rest _) nil)))
        (let ((reply (cmacs-secondbrain-search-tools-tests--call
                      "{\"query\":\"x\",\"semantic\":true}")))
          (should (eq (car (car reply)) 'error))
          (should (string-match-p "No memory index" (cadr (car reply))))
          (should-not embedded))))))

(ert-deftest cmacs-secondbrain-search-tools-test-view-closed-meanwhile ()
  "A view killed while the query was being embedded is reported, not signalled."
  (skip-unless (cmacs-secondbrain-ingest-tools-tests--root))
  (cmacs-secondbrain-ingest-tools-tests--with-family
      "cmacs-secondbrain-search-tools"
    (cmacs-secondbrain-search-tools-tests--with-view
      (let ((reply (cmacs-secondbrain-search-tools-tests--call
                    "{\"query\":\"x\",\"semantic\":true}")))
        (let ((kill-buffer-query-functions nil))
          (kill-buffer view))
        (funcall embed-ok (list [0.1]))
        (should (equal (car reply)
                       '(error "the second brain was closed while searching")))
        ;; For the macro's own cleanup.
        (setq view (get-buffer-create cmacs-secondbrain-buffer-name))))))

(provide 'cmacs-secondbrain-ingest-tools-tests)

;;; cmacs-secondbrain-ingest-tools-tests.el ends here
