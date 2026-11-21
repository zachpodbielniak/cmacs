;;; cmacs-secondbrain-tools-tests.el --- The migrated second-brain tool family  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; lisp/cmacs/cmacs-secondbrain-tools.el is part of the second brain's
;; MCP tools.
;; The C handlers these tools replaced were deleted once the registry
;; was published by every build with an MCP server.  What they promised
;; a client -- frozen from a real tools/list beforehand, in
;; test/cmacs/data/mcp-wire-schema.json -- is what the first test holds
;; the family to, through cmacs-wire-schema.el: each tool's name, its
;; parameters in order, their types and the required set.
;; Every tool the C file had is accounted for as migrated here,
;; registered elsewhere, or (none now) left in C.
;;
;; The rest is behaviour with the view's primitives stubbed: the tools
;; act on the one second-brain buffer and say so when it is not open, a
;; layout name that is not a layout is refused before it is interned,
;; and the JSON the ingester's tools return is JSON a client can read.
;;
;; Everything runs against a private registry with the C mirror stubbed,
;; so nothing registered here reaches the MCP surface of the Emacs
;; running the tests.

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

(defconst cmacs-secondbrain-tools-tests--migrated
  '("secondbrain_open" "secondbrain_set_layout" "secondbrain_expand"
    "secondbrain_node_info" "secondbrain_stats" "secondbrain_sources"
    "secondbrain_refresh" "secondbrain_ingest_cancel" "secondbrain_migrate"
    "secondbrain_doctor")
  "The C tools cmacs-secondbrain-tools.el provides.")

(defconst cmacs-secondbrain-tools-tests--elsewhere
  '("secondbrain_ingest" "secondbrain_ingest_status" "secondbrain_tree"
    "secondbrain_find")
  "The C tools cmacs-secondbrain-ingest-tools.el already registers.")

(defconst cmacs-secondbrain-tools-tests--left-in-c
  '("secondbrain_search")
  "The C tools neither file above provides.
`secondbrain_search' is cmacs-secondbrain-search-tools.el's, tested in
cmacs-secondbrain-ingest-tools-tests.el.")

(defun cmacs-secondbrain-tools-tests--root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-secondbrain-tools.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defmacro cmacs-secondbrain-tools-tests--with-family (&rest body)
  "Run BODY with a private registry holding only the secondbrain family."
  (declare (indent 0) (debug t))
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
         (load (expand-file-name "lisp/cmacs/cmacs-secondbrain-tools"
                                 (cmacs-secondbrain-tools-tests--root))
               nil t))
       ,@body)))

(defun cmacs-secondbrain-tools-tests--call (name json)
  "Start the tool NAME with JSON; return a cell that receives the reply.
The cell's car becomes (STATUS TEXT) when the tool settles."
  (let ((cell (list nil)))
    (cmacs-brigade-call-tool-async
     name json (lambda (status text) (setcar cell (list status text))))
    cell))


;;;; The family is the C family

(ert-deftest cmacs-secondbrain-tools-test-family-matches-c ()
  "Every migrated tool keeps its frozen name, parameters, types and required set."
  (skip-unless (cmacs-secondbrain-tools-tests--root))
  (cmacs-secondbrain-tools-tests--with-family
    (let ((c (cmacs-wire-schema-names "cmacs-mcp-tools-secondbrain.c")))
      (should (equal (sort (copy-sequence c) #'string<)
                     (sort (append cmacs-secondbrain-tools-tests--migrated
                                   cmacs-secondbrain-tools-tests--elsewhere
                                   cmacs-secondbrain-tools-tests--left-in-c
                                   nil)
                           #'string<)))
      ;; Exactly the migrated ones: this file must not register a name
      ;; the ingest tools own, because the later registration wins.
      (should (equal (sort (mapcar (lambda (e) (plist-get e :name))
                                   (cmacs-capability-describe))
                           #'string<)
                     (sort (copy-sequence
                            cmacs-secondbrain-tools-tests--migrated)
                           #'string<)))
      (dolist (name cmacs-secondbrain-tools-tests--migrated)
        (cmacs-wire-schema-should-match name)))))

(ert-deftest cmacs-secondbrain-tools-test-migrate-is-gated ()
  "`secondbrain_migrate' is destructive, confirmed, and not on D-Bus by default."
  (skip-unless (cmacs-secondbrain-tools-tests--root))
  (cmacs-secondbrain-tools-tests--with-family
    (let ((entry (cmacs-capability-describe-tool "secondbrain_migrate")))
      (should (plist-get entry :destructive))
      (should (eq (plist-get entry :confirm) 'ask))
      (should (memq 'mcp (plist-get entry :surfaces)))
      (should-not (memq 'dbus (plist-get entry :surfaces))))
    ;; Asked for confirmation with nobody to ask: declined, not run.
    (let ((cmacs-brigade-auto-approve nil) (ran nil))
      (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-migrate-from-json)
                 (lambda (&rest _) (setq ran t) "{}")))
        (should (eq (car (car (cmacs-secondbrain-tools-tests--call
                               "secondbrain_migrate" "{\"apply\":true}")))
                    'error))
        (should-not ran)))))


;;;; Behaviour

(defmacro cmacs-secondbrain-tools-tests--with-view (open &rest body)
  "Run BODY with the view primitives stubbed; with OPEN, the view exists.
BODY sees `log', a list of (FUNCTION . ARGS) for every stubbed call, and
`view', the stand-in second-brain buffer (nil when not OPEN)."
  (declare (indent 1) (debug t))
  `(let* ((cmacs-secondbrain-buffer-name " *cmacs-secondbrain-tools-tests*")
          (view (and ,open (get-buffer-create cmacs-secondbrain-buffer-name)))
          (log nil))
     (ignore log view)
     (unwind-protect
         (cl-letf (((symbol-function 'cmacs-secondbrain-node-count)
                    (lambda (&rest _) 120))
                   ((symbol-function 'cmacs-secondbrain-visible-count)
                    (lambda (&rest _) 14))
                   ((symbol-function 'cmacs-secondbrain-edge-count)
                    (lambda (&rest _) 200))
                   ((symbol-function 'cmacs-secondbrain-layout-kind)
                    (lambda (&rest _) 'hex))
                   ((symbol-function 'cmacs-secondbrain-set-layout-interactive)
                    (lambda (&rest args) (push (cons 'layout args) log) nil))
                   ((symbol-function 'cmacs-secondbrain-set-collapsed)
                    (lambda (&rest args) (push (cons 'collapsed args) log) t))
                   ((symbol-function 'cmacs-secondbrain-collapse-all)
                    (lambda (&rest args) (push (cons 'collapse-all args) log) t))
                   ((symbol-function 'cmacs-secondbrain-node-at)
                    (lambda (_buffer id)
                      (list :id id :title "Areas" :ring 'memory)))
                   ((symbol-function 'cmacs-secondbrain-refresh)
                    (lambda (&rest _) (push (list 'refresh (current-buffer)) log))))
           ,@body)
       (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest cmacs-secondbrain-tools-test-view-tools ()
  "The view tools act on the second-brain buffer and report as the C ones did."
  (skip-unless (and (cmacs-secondbrain-tools-tests--root)
                    (require 'cmacs-secondbrain nil t)))
  (cmacs-secondbrain-tools-tests--with-family
    (cmacs-secondbrain-tools-tests--with-view t
      (should (equal (car (cmacs-secondbrain-tools-tests--call
                           "secondbrain_stats" "{}"))
                     '(ok "nodes=120 visible=14 edges=200 layout=hex")))
      (should (equal (car (cmacs-secondbrain-tools-tests--call
                           "secondbrain_node_info" "{\"id\":\"memory/areas\"}"))
                     '(ok "(:id \"memory/areas\" :title \"Areas\" :ring memory)")))
      (should (equal (car (cmacs-secondbrain-tools-tests--call
                           "secondbrain_refresh" "{}"))
                     '(ok "refreshed")))
      (should (equal (assq 'refresh log) (list 'refresh view)))
      ;; One node, then every department.
      (should (equal (car (cmacs-secondbrain-tools-tests--call
                           "secondbrain_expand"
                           "{\"id\":\"memory/areas\",\"collapse\":true}"))
                     '(ok "changed")))
      (should (equal (assq 'collapsed log)
                     (list 'collapsed view "memory/areas" t 0)))
      (should (equal (car (cmacs-secondbrain-tools-tests--call
                           "secondbrain_expand" "{}"))
                     '(ok "ok")))
      (should (equal (assq 'collapse-all log)
                     (list 'collapse-all view nil 0))))))

(ert-deftest cmacs-secondbrain-tools-test-set-layout ()
  "A layout is one of four names; anything else is refused before `intern'."
  (skip-unless (and (cmacs-secondbrain-tools-tests--root)
                    (require 'cmacs-secondbrain nil t)))
  (cmacs-secondbrain-tools-tests--with-family
    (cmacs-secondbrain-tools-tests--with-view t
      (should (equal (car (cmacs-secondbrain-tools-tests--call
                           "secondbrain_set_layout" "{\"kind\":\"hex\"}"))
                     '(ok "hex")))
      (should (equal (assq 'layout log) '(layout hex)))
      (setq log nil)
      (let ((reply (car (cmacs-secondbrain-tools-tests--call
                         "secondbrain_set_layout"
                         "{\"kind\":\"no-such-layout-xyzzy\"}"))))
        (should (eq (car reply) 'error))
        (should (string-match-p "rings, circle, hex, force" (cadr reply))))
      (should-not log)
      (should-not (intern-soft "no-such-layout-xyzzy")))))

(ert-deftest cmacs-secondbrain-tools-test-view-not-open ()
  "With no view, a view tool fails and names the tool that opens one."
  (skip-unless (and (cmacs-secondbrain-tools-tests--root)
                    (require 'cmacs-secondbrain nil t)))
  (cmacs-secondbrain-tools-tests--with-family
    (cmacs-secondbrain-tools-tests--with-view nil
      (dolist (call '(("secondbrain_stats" . "{}")
                      ("secondbrain_refresh" . "{}")
                      ("secondbrain_expand" . "{}")
                      ("secondbrain_set_layout" . "{\"kind\":\"rings\"}")
                      ("secondbrain_node_info" . "{\"id\":\"x\"}")))
        (let ((reply (car (cmacs-secondbrain-tools-tests--call
                           (car call) (cdr call)))))
          (ert-info ((car call))
            (should (eq (car reply) 'error))
            (should (string-match-p "secondbrain_open" (cadr reply))))))
      (should-not log))))

(ert-deftest cmacs-secondbrain-tools-test-open ()
  "`secondbrain_open' opens the flat view, or the 3D one when asked."
  (skip-unless (and (cmacs-secondbrain-tools-tests--root)
                    (require 'cmacs-secondbrain nil t)))
  (cmacs-secondbrain-tools-tests--with-family
    (let ((opened nil))
      (cl-letf (((symbol-function 'cmacs-secondbrain)
                 (lambda (&rest _) (push 'flat opened)))
                ((symbol-function 'cmacs-secondbrain-3d)
                 (lambda (&rest _) (push '3d opened))))
        (should (equal (car (cmacs-secondbrain-tools-tests--call
                             "secondbrain_open" "{}"))
                       '(ok "opened")))
        (should (equal (car (cmacs-secondbrain-tools-tests--call
                             "secondbrain_open" "{\"three_d\":true}"))
                       '(ok "opened")))
        (should (equal opened '(3d flat)))))))

(ert-deftest cmacs-secondbrain-tools-test-ingester-tools ()
  "Cancel, migrate and doctor return the JSON a client parses."
  (skip-unless (and (cmacs-secondbrain-tools-tests--root)
                    (require 'cmacs-secondbrain-ingest nil t)
                    (require 'cmacs-secondbrain-ingest-migrate nil t)))
  (cmacs-secondbrain-tools-tests--with-family
    (let ((log nil))
      (cl-letf (((symbol-function 'cmacs-secondbrain-ingest-cancel)
                 (lambda (&rest args) (push (cons 'cancel args) log) nil))
                ((symbol-function 'cmacs-secondbrain-ingest-status-json)
                 (lambda (id) (format "{\"id\":\"%s\",\"done\":true}" id)))
                ((symbol-function 'cmacs-secondbrain-ingest-doctor)
                 (lambda (&rest _)
                   '((pandoc t "/usr/bin/pandoc")
                     (yt-dlp nil "not found (yt-dlp)"))))
                ((symbol-function 'cmacs-secondbrain-ingest-migrate-from-json)
                 (lambda (&rest args) (push (cons 'migrate args) log)
                   "{\"count\":3}")))
        (should (equal (car (cmacs-secondbrain-tools-tests--call
                             "secondbrain_ingest_cancel" "{\"id\":\"sbi-3\"}"))
                       '(ok "{\"id\":\"sbi-3\",\"done\":true}")))
        (should (equal (assq 'cancel log) '(cancel "sbi-3")))
        ;; An unavailable program is false, not the {} that nil
        ;; serialises to.
        (let* ((reply (car (cmacs-secondbrain-tools-tests--call
                            "secondbrain_doctor" "{}")))
               (rows (json-parse-string (cadr reply) :object-type 'alist
                                        :array-type 'list
                                        :false-object :false)))
          (should (eq (car reply) 'ok))
          (should (equal rows
                         '(((name . "pandoc") (available . t)
                            (detail . "/usr/bin/pandoc"))
                           ((name . "yt-dlp") (available . :false)
                            (detail . "not found (yt-dlp)"))))))
        ;; The options reach the one parser of them as a JSON object,
        ;; and only the literal "trash" is a removal policy.
        (should (equal (car (cmacs-secondbrain-tools-tests--call
                             "secondbrain_migrate"
                             "{\"dir\":\"03_resources\",\"apply\":true,\"remove\":\"rm -rf\"}"))
                       '(ok "{\"count\":3}")))
        (pcase-let ((`(migrate ,dir ,options) (assq 'migrate log)))
          (should (equal dir "03_resources"))
          (should (equal (json-parse-string options :object-type 'alist
                                            :false-object :false)
                         '((apply . t) (include_archives . :false)
                           (ai . :false) (remove . "")))))
        (cmacs-secondbrain-tools-tests--call
         "secondbrain_migrate" "{\"remove\":\"trash\"}")
        (pcase-let ((`(migrate ,dir ,options) (assq 'migrate log)))
          (should-not dir)
          (should (equal (alist-get 'remove
                                    (json-parse-string options
                                                       :object-type 'alist
                                                       :false-object :false))
                         "trash"))
          (should (eq (alist-get 'apply
                                 (json-parse-string options
                                                    :object-type 'alist
                                                    :false-object :false))
                      :false)))))))

(provide 'cmacs-secondbrain-tools-tests)

;;; cmacs-secondbrain-tools-tests.el ends here
