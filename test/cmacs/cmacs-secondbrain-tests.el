;;; cmacs-secondbrain-tests.el --- ERT tests for the ARMS second brain  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three tiers, ordered by how universally they run.
;;
;;   - Source registry and collection.  Pure data transforms over
;;     fixture providers: no display, no C, no filesystem.
;;   - The scanner.  Real files, but a temporary tree we build here.
;;   - The viewport.  Needs the C subsystem and a live display, and
;;     skips without them.
;;
;; The `fboundp' guard on `cmacs-feature-p' is deliberate: that function
;; is void in a per-file test run, and `skip-unless' turns a signalling
;; guard into a skip -- which reads as success.  That is how twenty
;; suites once went unnoticed.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cl-lib)
(require 'cmacs-para)
(require 'cmacs-secondbrain-sources)
(require 'cmacs-secondbrain nil 'noerror)

(defmacro cmacs-secondbrain-tests--skip ()
  "Skip unless the subsystem is built and a display exists."
  '(skip-unless (and (fboundp 'cmacs-secondbrain-supported-p)
                     (cmacs-secondbrain-supported-p)
                     (or (getenv "DISPLAY") (getenv "WAYLAND_DISPLAY")))))

(defmacro cmacs-secondbrain-tests--with-sources (sources &rest body)
  "Run BODY with only SOURCES registered."
  (declare (indent 1) (debug t))
  `(let ((cmacs-secondbrain--sources (make-hash-table :test 'eq))
         (cmacs-secondbrain-enabled-sources t))
     (dolist (s ,sources) (apply #'cmacs-secondbrain-register-source s))
     ,@body))

(defmacro cmacs-secondbrain-tests--with-view (var &rest body)
  "Attach a scratch second-brain buffer as VAR, run BODY, then detach."
  (declare (indent 1) (debug t))
  `(let ((,var (generate-new-buffer " *secondbrain-test*")))
     (unwind-protect
         (progn (cmacs-secondbrain-attach ,var 400 300) ,@body)
       (ignore-errors (cmacs-secondbrain-detach ,var))
       (kill-buffer ,var))))

(defun cmacs-secondbrain-tests--fixture (name ring ids)
  "Return a source plist called NAME on RING enumerating IDS."
  (list :name name :ring ring :label (symbol-name name)
        :enumerate (lambda ()
                     (mapcar (lambda (id)
                               (list :id id :title id :kind 'file
                                     :department "Fixture"))
                             ids))))

;;;; Source registry

(ert-deftest cmacs-secondbrain-test-register-and-list ()
  "A registered source is listed and retrievable."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'f1 'skills '("a")))
    (should (memq 'f1 (cmacs-secondbrain-sources)))
    (should (cmacs-secondbrain-source-get 'f1))
    (cmacs-secondbrain-unregister-source 'f1)
    (should-not (cmacs-secondbrain-source-get 'f1))))

(ert-deftest cmacs-secondbrain-test-register-validates ()
  "A source without a symbol name or an :enumerate function is refused."
  (should-error (cmacs-secondbrain-register-source :name "string"
                                                   :enumerate #'ignore))
  (should-error (cmacs-secondbrain-register-source :name 'x)))

(ert-deftest cmacs-secondbrain-test-reregistering-replaces ()
  "Re-registering a name replaces it -- that is how a reload works."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'f 'skills '("a"))
            (cmacs-secondbrain-tests--fixture 'f 'memory '("b" "c")))
    (should (= 1 (length (cmacs-secondbrain-sources))))
    (should (eq 'memory (plist-get (cmacs-secondbrain-source-get 'f) :ring)))))

(ert-deftest cmacs-secondbrain-test-enabled-sources-filter ()
  "`cmacs-secondbrain-enabled-sources' selects which contribute."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'on 'skills '("a"))
            (cmacs-secondbrain-tests--fixture 'off 'skills '("b")))
    (let* ((cmacs-secondbrain-enabled-sources '(on))
           (ids (mapcar (lambda (n) (plist-get n :id))
                        (plist-get (cmacs-secondbrain-collect) :nodes))))
      (should (member "a" ids))
      (should-not (member "b" ids)))))

(ert-deftest cmacs-secondbrain-test-failing-source-is-contained ()
  "A source that signals costs one ring member, not the graph.

The whole point of the registry is that it is open: a provider reading
somebody's config file will eventually hit one it cannot parse, and
that must not take the map down."
  (cmacs-secondbrain-tests--with-sources
      (list (list :name 'boom :ring 'skills
                  :enumerate (lambda () (error "deliberate")))
            (cmacs-secondbrain-tests--fixture 'ok 'memory '("survivor")))
    (let ((ids (mapcar (lambda (n) (plist-get n :id))
                       (plist-get (cmacs-secondbrain-collect) :nodes))))
      (should (member "survivor" ids)))))

(ert-deftest cmacs-secondbrain-test-source-ring-is-inherited ()
  "A node without :ring inherits it from its source."
  (cmacs-secondbrain-tests--with-sources
      (list (list :name 'r :ring 'routines
                  :enumerate (lambda () (list (list :id "x" :title "x")))))
    (let ((node (cl-find "x" (plist-get (cmacs-secondbrain-collect) :nodes)
                         :key (lambda (n) (plist-get n :id)) :test #'equal)))
      (should (eq 'routines (plist-get node :ring))))))

;;;; Collection shape

(ert-deftest cmacs-secondbrain-test-collect-adds-centre-and-hubs ()
  "Collection synthesises a centre and one hub per (ring, department)."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'skills '("s1" "s2"))
            (cmacs-secondbrain-tests--fixture 'b 'memory '("m1")))
    (let* ((g (cmacs-secondbrain-collect))
           (nodes (plist-get g :nodes))
           (kinds (mapcar (lambda (n) (plist-get n :kind)) nodes)))
      (should (memq 'centre kinds))
      (should (= 2 (cl-count 'hub kinds)))   ; one per ring, same dept name
      ;; Every leaf is parented to a hub, or collapse has nothing to fold.
      (dolist (n nodes)
        (when (eq (plist-get n :kind) 'file)
          (should (plist-get n :parent)))))))

(ert-deftest cmacs-secondbrain-test-hubs-start-collapsed ()
  "Departments arrive folded.

A ring that opens showing every one of four thousand notes is not a
map; the reference design shows a handful of sized circles."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'memory '("m1" "m2")))
    (let ((hubs (cl-remove-if-not
                 (lambda (n) (eq (plist-get n :kind) 'hub))
                 (plist-get (cmacs-secondbrain-collect) :nodes))))
      (should hubs)
      (dolist (h hubs) (should (plist-get h :collapsed))))))

(ert-deftest cmacs-secondbrain-test-hubs-hang-off-the-centre ()
  "Every hub is linked to the centre, so the rings read as one system."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'skills '("s1")))
    (let* ((g (cmacs-secondbrain-collect))
           (edges (plist-get g :edges))
           (hubs (cl-remove-if-not
                  (lambda (n) (eq (plist-get n :kind) 'hub))
                  (plist-get g :nodes))))
      (dolist (h hubs)
        (should (cl-find-if
                 (lambda (e)
                   (and (equal (plist-get e :from) cmacs-secondbrain-centre-id)
                        (equal (plist-get e :to) (plist-get h :id))))
                 edges))))))

;;;; The scanner fallback

(ert-deftest cmacs-secondbrain-test-scanner-reads-ids-and-links ()
  "The scanner finds roam nodes with no database present.

This is not a nicety: org-roam builds its database on demand, a fresh
checkout has never had one, and roamgraph's native C scanner is a stub
that returns nil.  Without this the Memory ring -- the largest of the
four -- comes up empty on a machine whose notes are perfectly fine."
  (let* ((dir (make-temp-file "cmacs-sb-scan" t))
         (a (expand-file-name "01_projects/a.org" dir))
         (b (expand-file-name "02_areas/b.org" dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory a) t)
          (make-directory (file-name-directory b) t)
          (with-temp-file a
            (insert ":PROPERTIES:\n:ID:       aaaaaaaa-0000-0000-0000-000000000001\n"
                    ":END:\n#+title: Alpha\n\nSee [[id:aaaaaaaa-0000-0000-0000-000000000002][B]].\n"))
          (with-temp-file b
            (insert ":PROPERTIES:\n:ID:       aaaaaaaa-0000-0000-0000-000000000002\n"
                    ":END:\n#+title: Beta\n"))
          (let* ((cmacs-para-roots (list dir))
                 (g (cmacs-secondbrain--scan-org-tree))
                 (nodes (plist-get g :nodes))
                 (edges (plist-get g :edges)))
            (should (= 2 (length nodes)))
            (should (member "Alpha" (mapcar (lambda (n) (plist-get n :title)) nodes)))
            (should (= 1 (length edges)))
            (should (equal (plist-get (car edges) :to)
                           "aaaaaaaa-0000-0000-0000-000000000002"))))
      (delete-directory dir t))))

(ert-deftest cmacs-secondbrain-test-scanner-drops-dangling-links ()
  "A link to an id that does not exist is dropped, not emitted.

Dangling links are normal in a live tree; an edge to a node that is not
in the graph would be a line to nowhere."
  (let* ((dir (make-temp-file "cmacs-sb-scan" t))
         (a (expand-file-name "a.org" dir)))
    (unwind-protect
        (progn
          (with-temp-file a
            (insert ":PROPERTIES:\n:ID:       bbbbbbbb-0000-0000-0000-000000000001\n"
                    ":END:\n#+title: Alpha\n\n[[id:deadbeef-0000-0000-0000-000000000000]]\n"))
          (let* ((cmacs-para-roots (list dir))
                 (g (cmacs-secondbrain--scan-org-tree)))
            (should (= 1 (length (plist-get g :nodes))))
            (should (null (plist-get g :edges)))))
      (delete-directory dir t))))

(ert-deftest cmacs-secondbrain-test-scanner-ignores-non-roam-files ()
  "An org file without an :ID: is not a node."
  (let* ((dir (make-temp-file "cmacs-sb-scan" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "plain.org" dir)
            (insert "#+title: Just a file\n\nNo id drawer here.\n"))
          (let ((cmacs-para-roots (list dir)))
            (should (null (plist-get (cmacs-secondbrain--scan-org-tree) :nodes)))))
      (delete-directory dir t))))

;;;; PARA is the Memory taxonomy

(ert-deftest cmacs-secondbrain-test-memory-departments-are-para ()
  "Memory nodes are grouped by PARA bucket, not by an invented taxonomy.

The tree is already organised; grouping it by anything else would be
inventing a second organisation on top of the real one."
  (let ((cmacs-para-roots '("/n")))
    (should (equal (cmacs-para-bucket "/n/01_projects/x.org") "01_projects"))
    (should (equal (cmacs-para-bucket "/n/02_areas/dailies/d.org") "dailies"))))

;;;; The viewport (needs C + a display)

(ert-deftest cmacs-secondbrain-test-attach-detach ()
  "Attach and detach are idempotent."
  (cmacs-secondbrain-tests--skip)
  (let ((buf (generate-new-buffer " *sb-test*")))
    (unwind-protect
        (progn
          (should (cmacs-secondbrain-attach buf 320 240))
          (should (cmacs-secondbrain-attached-p buf))
          (cmacs-secondbrain-attach buf 320 240)   ; again: no-op
          (should (cmacs-secondbrain-attached-p buf))
          (cmacs-secondbrain-detach buf)
          (should-not (cmacs-secondbrain-attached-p buf)))
      (kill-buffer buf))))

(ert-deftest cmacs-secondbrain-test-set-graph-counts ()
  "set-graph reports what it emitted, and hides collapsed subtrees."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (vector
                  (list :id "hub" :title "Hub" :kind 'hub :ring 'memory
                        :collapsed t)
                  (list :id "n1" :title "One" :kind 'file :ring 'memory
                        :parent "hub")
                  (list :id "n2" :title "Two" :kind 'file :ring 'memory
                        :parent "hub")))
          (edges (vector (list :from "hub" :to "n1"))))
      (cmacs-secondbrain-set-graph buf nodes edges 2)
      (should (= 3 (cmacs-secondbrain-node-count buf)))
      ;; The hub is visible; its two children are not.
      (should (= 1 (cmacs-secondbrain-visible-count buf))))))

(ert-deftest cmacs-secondbrain-test-expand-and-collapse ()
  "Expanding a hub reveals its subtree, and collapsing hides it again."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf
     (vector (list :id "hub" :title "Hub" :kind 'hub :ring 'memory :collapsed t)
             (list :id "n1" :title "One" :kind 'file :ring 'memory :parent "hub"))
     (vector) 2)
    (should (= 1 (cmacs-secondbrain-visible-count buf)))
    (should (cmacs-secondbrain-collapsed-p buf "hub"))
    (cmacs-secondbrain-set-collapsed buf "hub" nil 0)
    (should (= 2 (cmacs-secondbrain-visible-count buf)))
    (should-not (cmacs-secondbrain-collapsed-p buf "hub"))
    (cmacs-secondbrain-set-collapsed buf "hub" t 0)
    (should (= 1 (cmacs-secondbrain-visible-count buf)))))

(ert-deftest cmacs-secondbrain-test-node-payload-round-trips ()
  "Unknown plist keys survive and come back from a pick.

The contract promises it, and the whole Elisp layer depends on it: the
context menu reads :kind and :department off the node it was handed."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf
     (vector (list :id "x" :title "X" :kind 'skill :ring 'skills
                   :department "Fixture" :custom-key 42))
     (vector) 2)
    (let ((node (cmacs-secondbrain-node-at buf "x")))
      (should (equal (plist-get node :title) "X"))
      (should (equal (plist-get node :department) "Fixture"))
      (should (= 42 (plist-get node :custom-key))))
    ;; Numeric scene ids are deliberately not accepted.
    (should-error (cmacs-secondbrain-node-at buf 0))))

(ert-deftest cmacs-secondbrain-test-layouts-switch ()
  "Every layout kind is accepted and reported back."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :ring 'skills) (list :id "b" :ring 'memory))
     (vector) 2)
    (dolist (kind '(rings circle hex force))
      (cmacs-secondbrain-set-layout buf kind 0)
      (should (eq kind (cmacs-secondbrain-layout-kind buf))))))

(ert-deftest cmacs-secondbrain-test-rings-are-ordered-outward ()
  "A node's distance from the centre follows its ring.

Skills innermost, Applications outermost -- that ordering IS the ARMS
framework, so it is worth asserting rather than assuming."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf
     (vector (list :id "s" :ring 'skills)
             (list :id "m" :ring 'memory)
             (list :id "r" :ring 'routines)
             (list :id "a" :ring 'applications))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cl-labels ((radius (id)
                  (let ((p (cmacs-secondbrain-node-position buf id)))
                    (sqrt (+ (* (nth 0 p) (nth 0 p))
                             (* (nth 1 p) (nth 1 p)))))))
      (should (< (radius "s") (radius "m")))
      (should (< (radius "m") (radius "r")))
      (should (< (radius "r") (radius "a"))))))

(ert-deftest cmacs-secondbrain-test-tween-completes ()
  "A transition runs to completion and then reports done."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :ring 'skills) (list :id "b" :ring 'memory))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'circle 5)
    (should (cmacs-secondbrain-tweening-p buf))
    (let ((guard 0))
      (while (and (not (cmacs-secondbrain-tween-step buf)) (< guard 50))
        (cl-incf guard))
      (should (< guard 50)))
    (should-not (cmacs-secondbrain-tweening-p buf))))

(ert-deftest cmacs-secondbrain-test-projection-toggles ()
  "The flat and free views round-trip."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph buf (vector (list :id "a")) (vector) 2)
    (cmacs-secondbrain-set-projection buf t)
    (should (cmacs-secondbrain-flat-p buf))
    (cmacs-secondbrain-set-projection buf nil)
    (should-not (cmacs-secondbrain-flat-p buf))))

(ert-deftest cmacs-secondbrain-test-empty-graph-is-safe ()
  "An empty graph attaches, lays out and fits without erroring."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (should (= 0 (cmacs-secondbrain-set-graph buf (vector) (vector) 2)))
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cmacs-secondbrain-fit buf)
    (should (= 0 (cmacs-secondbrain-visible-count buf)))))

(ert-deftest cmacs-secondbrain-test-ring-names ()
  "The ring vocabulary is innermost-first and complete."
  (skip-unless (fboundp 'cmacs-secondbrain-ring-names))
  (should (equal (cmacs-secondbrain-ring-names)
                 '(skills memory routines applications))))

(ert-deftest cmacs-secondbrain-test-icon-lookup ()
  "An application icon resolves by name, case- and separator-insensitively.

Nothing ships icons with cmacs -- application logos are other people's
trademarks -- so a missing one must simply return nil and leave the node
its glyph."
  (let* ((dir (make-temp-file "cmacs-sb-icons" t))
         (cmacs-secondbrain-icon-dirs (list dir)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "google-drive.svg" dir)
            (insert "<svg/>"))
          (should (cmacs-secondbrain-icon-for "Google Drive"))
          (should (cmacs-secondbrain-icon-for "google-drive"))
          (should (cmacs-secondbrain-icon-for "Google_Drive"))
          (should-not (cmacs-secondbrain-icon-for "nothing-here"))
          (should-not (cmacs-secondbrain-icon-for nil)))
      (delete-directory dir t))))

(ert-deftest cmacs-secondbrain-test-icon-failure-is-not-fatal ()
  "An unreadable or malformed SVG returns nil rather than signalling."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'app :ring 'applications))
     (vector) 2)
    (should-not (cmacs-secondbrain-add-icon buf "a" "/nonexistent/x.svg"))
    ;; And an id that is not in the graph is nil, not an error.
    (should-not (cmacs-secondbrain-add-icon buf "nope" "/nonexistent/x.svg"))
    ;; Clearing is always safe.
    (should (cmacs-secondbrain-clear-icons buf))))

;;;; Panes

(ert-deftest cmacs-secondbrain-test-inspector-renders ()
  "The inspector renders for a selection, and says so when there is none."
  (cmacs-secondbrain-tests--skip)
  (require 'cmacs-secondbrain-panes)
  (let ((buf (generate-new-buffer " *sb-panes-test*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-secondbrain-mode)
          (cmacs-secondbrain-attach buf 400 300)
          (cmacs-secondbrain-set-graph
           buf
           (vector (list :id "s" :title "A Skill" :kind 'skill :ring 'skills
                         :department "Skills"))
           (vector) 2)
          ;; Nothing selected yet.
          (with-current-buffer (cmacs-secondbrain-inspector-render)
            (should (string-match-p "Nothing selected" (buffer-string))))
          (setq cmacs-secondbrain--selected "s")
          (with-current-buffer (cmacs-secondbrain-inspector-render)
            (should (string-match-p "A Skill" (buffer-string)))
            (should (string-match-p "skill" (buffer-string)))
            (should (string-match-p "Connections" (buffer-string)))))
      (ignore-errors (cmacs-secondbrain-detach buf))
      (kill-buffer buf))))

(ert-deftest cmacs-secondbrain-test-inspector-action-registry ()
  "A registered inspector action is listed and bound."
  (require 'cmacs-secondbrain-panes)
  (let ((cmacs-secondbrain-inspector-actions nil))
    (cmacs-secondbrain-register-inspector-action
     "Q" "test action" (lambda (_id) t))
    (should (assoc "Q" cmacs-secondbrain-inspector-actions))
    (should (keymapp cmacs-secondbrain-inspector-mode-map))
    (should (lookup-key cmacs-secondbrain-inspector-mode-map (kbd "Q")))))

(ert-deftest cmacs-secondbrain-test-connections-are-bidirectional ()
  "The inspector's connection list counts both directions."
  (require 'cmacs-secondbrain-panes)
  (let ((cmacs-secondbrain--graph
         (list :edges (list (list :from "a" :to "b")
                            (list :from "c" :to "a")))))
    (let ((conn (cmacs-secondbrain--connections "a")))
      (should (equal (car conn) '("c")))     ; incoming
      (should (equal (cdr conn) '("b"))))))  ; outgoing

;;;; Context menu

(ert-deftest cmacs-secondbrain-test-menu-adapts-to-kind ()
  "The menu offers what makes sense for the node's role.

An application's useful question is what it can reach; a hub's is
whether to expand it.  Offering \"Open\" on an MCP server would be
noise."
  (cmacs-secondbrain-tests--skip)
  ;; Mode first, then attach: `cmacs-secondbrain-mode' re-initialises the
  ;; buffer, which drops a view attached before it.
  (let ((buf (generate-new-buffer " *sb-menu-test*")))
    (unwind-protect
     (with-current-buffer buf
      (cmacs-secondbrain-mode)
      (cmacs-secondbrain-attach buf 400 300)
      (cmacs-secondbrain-set-graph
       buf
       (vector (list :id "hub" :title "H" :kind 'hub :ring 'memory)
               (list :id "app" :title "A" :kind 'app :ring 'applications))
       (vector) 2)
      (let ((hub-labels (mapcar #'car (delq nil (cmacs-secondbrain--menu-items "hub"))))
            (app-labels (mapcar #'car (delq nil (cmacs-secondbrain--menu-items "app")))))
        (should (cl-find-if (lambda (l) (string-match-p "xpand\\|ollapse" l))
                            hub-labels))
        (should (cl-find-if (lambda (l) (string-match-p "reach" l)) app-labels))
        ;; Both always offer the global actions.
        (should (member "Refresh" hub-labels))
        (should (member "Refresh" app-labels))))
     (ignore-errors (cmacs-secondbrain-detach buf))
     (kill-buffer buf))))

(provide 'cmacs-secondbrain-tests)

;;; cmacs-secondbrain-tests.el ends here
