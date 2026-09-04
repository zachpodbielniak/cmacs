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

(ert-deftest cmacs-secondbrain-test-hubs-carry-their-count ()
  "A collapsed department reports how much it is hiding.

Without it a folded hub says only its name, which answers none of the
question you fold for: whether it holds four notes or four thousand.
The count rides in `:count' so the inspector and the AI target can read
it, and in `:title' because the title is what renders in-scene."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'memory '("m1" "m2" "m3")))
    (let ((hub (cl-find-if (lambda (n) (eq (plist-get n :kind) 'hub))
                           (plist-get (cmacs-secondbrain-collect) :nodes))))
      (should hub)
      (should (= 3 (plist-get hub :count)))
      (should (string-match-p "3\\'" (plist-get hub :title))))))

(ert-deftest cmacs-secondbrain-test-hub-counts-are-per-department ()
  "Counts are per hub, not a single total sprayed across every hub."
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'memory '("m1" "m2"))
            (cmacs-secondbrain-tests--fixture 'b 'skills '("n1")))
    (let* ((hubs (cl-remove-if-not
                  (lambda (n) (eq (plist-get n :kind) 'hub))
                  (plist-get (cmacs-secondbrain-collect) :nodes)))
           (counts (sort (mapcar (lambda (h) (plist-get h :count)) hubs) #'<)))
      (should (equal '(1 2) counts)))))

(ert-deftest cmacs-secondbrain-test-view-configuration-is-applied ()
  "Every call `cmacs-secondbrain--configure-view' makes must resolve.

Each is wrapped in `fboundp', which is right -- libregnum may be built
without them -- but it also means a renamed DEFUN degrades to silence:
labels, the halo and the map-style navigation would simply not happen,
with no error to notice.  This test is what turns that back into a
failure."
  (cmacs-secondbrain-tests--skip)
  (dolist (f '(cmacs-libregnum-resize
               cmacs-libregnum-set-label-font
               cmacs-libregnum-set-label-style
               cmacs-libregnum-set-label-decor
               cmacs-libregnum-set-right-drag-pans
               cmacs-libregnum-set-wheel-up-zooms-in
               cmacs-libregnum-set-selection-style
               cmacs-libregnum-set-inscene-labels))
    (should (fboundp f))))

(ert-deftest cmacs-secondbrain-test-fit-window-survives-no-window ()
  "Refitting a buffer nobody is displaying is a no-op, not an error.

The refit runs off an idle timer, so it routinely fires after the
window it was scheduled for has gone."
  (cmacs-secondbrain-tests--skip)
  (let ((buf (get-buffer-create " *sb-fit-test*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-secondbrain-mode)
          (should-not (cmacs-secondbrain--fit-window-now buf)))
      (kill-buffer buf))))

(ert-deftest cmacs-secondbrain-test-hover-groups-index-by-department ()
  "The hover lookup tables map every node to its department and back.

They are precomputed because `cmacs-secondbrain--on-hover' runs on the
pointer's hot path -- walking the node list per motion event is how a
hover effect becomes a stutter."
  (skip-unless (fboundp 'cmacs-secondbrain--build-groups))
  (with-temp-buffer
    (let ((nodes '((:id "a" :ring memory :department "01_projects")
                   (:id "b" :ring memory :department "01_projects")
                   (:id "c" :ring memory :department "02_areas")
                   (:id "centre" :ring skills))))
      (cmacs-secondbrain--build-groups nodes)
      (should (equal "memory/01_projects"
                     (gethash "a" cmacs-secondbrain--group-of)))
      (should (equal 2 (length (gethash "memory/01_projects"
                                        cmacs-secondbrain--groups))))
      (should (equal 1 (length (gethash "memory/02_areas"
                                        cmacs-secondbrain--groups))))
      ;; A node with no department joins no group: giving the centre one
      ;; would make hovering it light up an arbitrary ring.
      (should-not (gethash "centre" cmacs-secondbrain--group-of)))))

(ert-deftest cmacs-secondbrain-test-hover-lights-the-whole-department ()
  "Hovering one member flags every member of its department."
  (skip-unless (fboundp 'cmacs-secondbrain--on-hover))
  (with-temp-buffer
    (let ((flagged 'unset))
      (cl-letf (((symbol-function 'cmacs-secondbrain--flag-ids)
                 (lambda (ids) (setq flagged ids))))
        (cmacs-secondbrain--build-groups
         '((:id "a" :ring memory :department "d")
           (:id "b" :ring memory :department "d")
           (:id "z" :ring skills :department "other")))
        (cmacs-secondbrain--on-hover (current-buffer) 1 "a")
        (should (equal 2 (length flagged)))
        (should (member "b" flagged))
        ;; Leaving every node clears it, rather than leaving a
        ;; department lit that reads as a search nobody ran.
        (cmacs-secondbrain--on-hover (current-buffer) -1 nil)
        (should-not flagged)
        (should-not cmacs-secondbrain--hovered)))))

(ert-deftest cmacs-secondbrain-test-hover-does-not-clobber-a-search ()
  "A search survives the pointer moving over the graph.

A search is a deliberate question; a stray pointer movement must not
silently replace its answer."
  (skip-unless (fboundp 'cmacs-secondbrain--on-hover))
  (with-temp-buffer
    (let ((calls 0))
      (cl-letf (((symbol-function 'cmacs-secondbrain--flag-ids)
                 (lambda (_ids) (cl-incf calls))))
        (cmacs-secondbrain--build-groups
         '((:id "a" :ring memory :department "d")))
        (setq cmacs-secondbrain--search "query")
        (cmacs-secondbrain--on-hover (current-buffer) 1 "a")
        (should (= 0 calls))
        (setq cmacs-secondbrain--search nil)
        (cmacs-secondbrain--on-hover (current-buffer) 1 "a")
        (should (= 1 calls))))))

(ert-deftest cmacs-secondbrain-test-hover-respects-its-defcustom ()
  "Hover highlighting can be turned off."
  (skip-unless (fboundp 'cmacs-secondbrain--on-hover))
  (with-temp-buffer
    (let ((calls 0)
          (cmacs-secondbrain-hover-highlights-group nil))
      (cl-letf (((symbol-function 'cmacs-secondbrain--flag-ids)
                 (lambda (_ids) (cl-incf calls))))
        (cmacs-secondbrain--build-groups
         '((:id "a" :ring memory :department "d")))
        (cmacs-secondbrain--on-hover (current-buffer) 1 "a")
        (should (= 0 calls))))))

(ert-deftest cmacs-secondbrain-test-everything-is-visible-by-default ()
  "Nothing arrives folded unless asked for.

A map that shows only the folder names is a table of contents you have
to click through, not a view of the graph."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'memory '("m1" "m2" "m3")))
    (cmacs-secondbrain-tests--with-view buf
      (with-current-buffer buf
        (cmacs-secondbrain-mode)
        (let ((cmacs-secondbrain-start-collapsed nil))
          (cmacs-secondbrain-refresh))
        (should (= (cmacs-secondbrain-node-count buf)
                   (cmacs-secondbrain-visible-count buf)))
        (let ((cmacs-secondbrain-start-collapsed t))
          (cmacs-secondbrain-refresh))
        (should (< (cmacs-secondbrain-visible-count buf)
                   (cmacs-secondbrain-node-count buf)))))))

(ert-deftest cmacs-secondbrain-test-particle-burst-emits ()
  "A burst puts particles in the pool; with particles off it does not."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-particles-burst))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-libregnum-particles-enable buf t)
    (should (cmacs-libregnum-particles-burst buf 0 0 0 12))
    (should (>= (cmacs-libregnum-particles-count buf) 1))
    ;; Off means off: no emitters, no live particles, nothing drawn.
    (cmacs-libregnum-particles-enable buf nil)
    (should (= 0 (cmacs-libregnum-particles-count buf)))
    (should-not (cmacs-libregnum-particles-burst buf 0 0 0 12))))

(ert-deftest cmacs-secondbrain-test-particles-actually-render ()
  "Particles reach the framebuffer, not just the pool.

This is the test that matters, and it is why it snapshots rather than
counting.  `lrg_particle_system_draw' is a documented no-op -- it walks
the live particles and draws nothing, because rendering \"depends on the
graphics backend\".  An implementation built on it simulates correctly,
reports a healthy live count, and puts not one pixel on screen.  A test
that only asserted the count would have passed against exactly that.

`cmacs-libregnum-ink-bbox' cannot do the job either: the viewport paints
a background, so the ink box is already the whole frame before a single
particle exists."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-particles-burst))
  (let ((before (make-temp-file "sb-p-" nil ".png"))
        (after  (make-temp-file "sb-p-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph buf (vector) (vector) 2)
          (cmacs-secondbrain-fit buf)
          (cmacs-libregnum-snapshot buf before)
          (cmacs-libregnum-particles-enable buf t)
          (cmacs-libregnum-particles-burst buf 0 0 0 150 #xFFFFFFFF 0.6 0.2)
          (cmacs-libregnum-snapshot buf after)
          (should (file-exists-p before))
          (should (file-exists-p after))
          (should-not
           (equal (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally before) (buffer-string))
                  (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally after) (buffer-string)))))
      (ignore-errors (delete-file before))
      (ignore-errors (delete-file after)))))

(ert-deftest cmacs-secondbrain-test-context-menu-call-shape ()
  "The context menu calls `cmacs-libregnum-popup-menu' correctly.

It takes (POSITION MENU) -- two arguments -- and MENU is an
x-popup-menu alist, not a bare item list.  Passing a buffer, a title and
the items instead is a `wrong-number-of-arguments' the moment anything
is right-clicked, and no amount of testing `--menu-items' in isolation
catches it, because the mistake is at the call site."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (with-current-buffer buf
      (cmacs-secondbrain-mode)
      (cmacs-secondbrain-set-graph
       buf (vector (list :id "n1" :title "One" :kind 'file :ring 'memory))
       (vector) 2)
      (let ((seen nil))
        (cl-letf (((symbol-function 'cmacs-libregnum-popup-menu)
                   ;; Strictly two arguments: a third signals, which is
                   ;; the regression this exists for.
                   (lambda (position menu) (setq seen (list position menu)) nil)))
          (cmacs-secondbrain--context-menu buf 0 "n1" 0 0)
          ;; The handler defers onto the command loop, so let it run.
          (sit-for 0.2)
          (should seen)
          ;; MENU is (TITLE (PANE ITEM...)); a nil item must have become
          ;; a separator, because x-popup-menu chokes on a bare nil.
          (let* ((menu (nth 1 seen))
                 (pane (nth 1 menu)))
            (should (stringp (car menu)))
            (should (consp pane))
            (should (cl-every #'consp (cdr pane)))))))))

(ert-deftest cmacs-secondbrain-test-particles-off-is-a-no-op ()
  "With `cmacs-secondbrain-particles' nil nothing reaches libregnum."
  (skip-unless (fboundp 'cmacs-secondbrain--burst-at))
  (with-temp-buffer
    (let ((cmacs-secondbrain-particles nil) (calls 0))
      (cl-letf (((symbol-function 'cmacs-libregnum-particles-burst)
                 (lambda (&rest _) (cl-incf calls) t)))
        (cmacs-secondbrain--burst-at "x")
        (should (= 0 calls))))))

(ert-deftest cmacs-secondbrain-test-background-kinds-render ()
  "Every procedural background reaches the framebuffer, and differs.

Rendering each and comparing bytes, because \"the setter returned the
symbol I gave it\" proves only that the symbol was recognised -- it says
nothing about whether a single pixel changed."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-background))
  (let ((files nil))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph buf (vector) (vector) 2)
          (cmacs-secondbrain-fit buf)
          (dolist (kind '(none gradient starfield nebula))
            (should (eq kind (cmacs-libregnum-set-background
                              buf kind #x2A3A6BFF #x05050AFF)))
            (let ((f (make-temp-file "sb-bg-" nil ".png")))
              (push f files)
              (cmacs-libregnum-snapshot buf f)
              (should (file-exists-p f))))
          (let ((bytes (mapcar (lambda (f)
                                 (with-temp-buffer
                                   (set-buffer-multibyte nil)
                                   (insert-file-contents-literally f)
                                   (buffer-string)))
                               files)))
            ;; Four kinds, four distinct frames.
            (should (= 4 (length (delete-dups (copy-sequence bytes)))))))
      (dolist (f files) (ignore-errors (delete-file f))))))

(ert-deftest cmacs-secondbrain-test-background-bad-image-is-refused ()
  "An unreadable image is refused rather than blanking the viewport.

A background that silently goes to nothing is a worse answer than one
that keeps what it had and says the path is bad."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-background))
  (cmacs-secondbrain-tests--with-view buf
    (should-not (cmacs-libregnum-set-background
                 buf 'image 0 0 "/nonexistent/nope.png"))
    ;; And with no path at all, which is the other way to get here.
    (should-not (cmacs-libregnum-set-background buf 'image 0 0 nil))))

(ert-deftest cmacs-secondbrain-test-click-does-not-move-the-camera ()
  "Clicking selects without flying the camera.

The libregnum input layer flies to whatever a left click hits, which is
right for a scene you navigate BY clicking and wrong here: a click
starts an expand animation, and the camera landing on the hub hides the
very thing the click was for.  `cmacs-secondbrain--configure-view' turns
it off, and this pins that it stays off."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-focus-policy))
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture 'a 'memory '("m1" "m2" "m3")))
    (cmacs-secondbrain-tests--with-view buf
      (with-current-buffer buf
        (cmacs-secondbrain-mode)
        (let ((cmacs-secondbrain-start-collapsed nil))
          (cmacs-secondbrain-refresh))
        (let ((before (cmacs-libregnum-camera-state buf)))
          (cmacs-secondbrain--on-pick buf 1 0 0 "m1")
          (should (equal before (cmacs-libregnum-camera-state buf))))))))

(ert-deftest cmacs-secondbrain-test-fly-to-moves-and-keeps-context ()
  "`cmacs-secondbrain-focus' moves the camera, and not too close.

The distance floor is the point: with it removed the camera frames the
node by the node's OWN size, which in this graph means one sphere
filling the view."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-focus))
  (cmacs-secondbrain-tests--with-sources
      (list (cmacs-secondbrain-tests--fixture
             'a 'memory '("m1" "m2" "m3" "m4" "m5" "m6")))
    (cmacs-secondbrain-tests--with-view buf
      (with-current-buffer buf
        (cmacs-secondbrain-mode)
        ;; Flying to a node needs the node ON SCREEN, and departments now
        ;; open folded -- so this asks for the open map explicitly rather
        ;; than depending on whichever way the default happens to point.
        (let ((cmacs-secondbrain-start-collapsed nil))
          (cmacs-secondbrain-refresh))
        ;; An id nobody has is nil, not an error and not a camera move.
        (should-not (cmacs-secondbrain-focus buf "no-such-node"))
        (let ((before (cmacs-libregnum-camera-state buf)))
          (should (cmacs-secondbrain-focus buf "m1"))
          (dotimes (_ 40) (ignore-errors (cmacs-libregnum-ink-bbox buf)))
          (should-not (equal before (cmacs-libregnum-camera-state buf))))
        ;; A bigger context fraction must end up further away.
        (let (near far)
          (dolist (frac '(0.1 0.8))
            (cmacs-secondbrain-fit buf)
            (cmacs-libregnum-set-focus-policy buf nil frac)
            (cmacs-secondbrain-focus buf "m1")
            (dotimes (_ 60) (ignore-errors (cmacs-libregnum-ink-bbox buf)))
            (let* ((cam (cmacs-libregnum-camera-state buf))
                   (p (plist-get cam :position))
                   (tg (plist-get cam :target))
                   (d (sqrt (apply #'+ (cl-mapcar (lambda (a b) (* (- a b) (- a b)))
                                                  p tg)))))
              (if near (setq far d) (setq near d))))
          (should (> far near)))))))

(ert-deftest cmacs-secondbrain-test-label-size-scales-with-viewport ()
  "Label size tracks the viewport, clamped at both ends.

A fixed pixel size cannot be right for both a half-screen window and a
maximised one on a large display, and since the framebuffer now tracks
the window exactly, the number that reads well in one is unreadably
small in the other."
  (skip-unless (fboundp 'cmacs-secondbrain--label-px))
  (with-temp-buffer
    (let ((cmacs-secondbrain-label-size 15)
          (cmacs-secondbrain-label-reference-height 800)
          (cmacs-secondbrain-label-scale-max 2.2))
      ;; At the reference height it is exactly the base.
      (should (= 15 (cmacs-secondbrain--label-px nil 800)))
      ;; Bigger viewport, bigger text.
      (should (> (cmacs-secondbrain--label-px nil 1300)
                 (cmacs-secondbrain--label-px nil 800)))
      ;; Never SMALLER than the base, however short the window: a
      ;; split-window viewport is where legibility matters most.
      (should (= 15 (cmacs-secondbrain--label-px nil 200)))
      ;; And capped, because past a point bigger labels stop adding
      ;; legibility and start hiding the graph behind them.
      (should (= (cmacs-secondbrain--label-px nil 100000)
                 (round (* 15 2.2)))))))

(ert-deftest cmacs-secondbrain-test-apply-label-size-without-a-window ()
  "Applying the label size is safe for a buffer nobody is displaying.

It runs from an idle timer, so it routinely fires for a buffer whose
window has gone."
  (skip-unless (fboundp 'cmacs-secondbrain--apply-label-size))
  (with-temp-buffer
    (should-not (cmacs-secondbrain--apply-label-size (current-buffer)))))

(ert-deftest cmacs-secondbrain-test-screensaver-background-falls-back ()
  "An unavailable screensaver falls back instead of blanking the view.

The subsystem is optional and off in many builds, and a background that
silently renders nothing is worse than one that quietly picks another."
  (skip-unless (fboundp 'cmacs-secondbrain--apply-screensaver-background))
  (with-temp-buffer
    (cl-letf (((symbol-function 'cmacs-secondbrain--screensaver-available-p)
               (lambda () nil))
              (applied nil))
      (cl-letf (((symbol-function 'cmacs-secondbrain--apply-texture-background)
                 (lambda (_buf) (setq applied t))))
        (setq-local cmacs-secondbrain-background 'screensaver)
        (cmacs-secondbrain--apply-screensaver-background (current-buffer))
        (should (eq 'nebula cmacs-secondbrain-background))
        (should-not cmacs-secondbrain--screensaver-on)))))

(ert-deftest cmacs-secondbrain-test-screensaver-start-error-falls-back ()
  "A module that will not load falls back rather than propagating."
  (skip-unless (fboundp 'cmacs-secondbrain--apply-screensaver-background))
  (with-temp-buffer
    (cl-letf (((symbol-function 'cmacs-secondbrain--screensaver-available-p)
               (lambda () t))
              ((symbol-function 'cmacs-screensaver-attach-background)
               (lambda (&rest _) (error "no such module")))
              ((symbol-function 'cmacs-secondbrain--apply-texture-background)
               #'ignore))
      (setq-local cmacs-secondbrain-background 'screensaver)
      (cmacs-secondbrain--apply-screensaver-background (current-buffer))
      (should (eq 'nebula cmacs-secondbrain-background))
      (should-not cmacs-secondbrain--screensaver-on))))

(ert-deftest cmacs-secondbrain-test-screensaver-background-round-trip ()
  "A screensaver really does render behind the graph, and detaches.

The interesting assertion is that the frame CHANGES between two
snapshots taken a moment apart: a static background would be identical,
so this is what distinguishes a live frame source from a texture that
was uploaded once."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-screensaver-supported-p)
                    (cmacs-screensaver-supported-p)
                    (fboundp 'cmacs-screensaver-attach-background)
                    (getenv "CMACS_SCREENSAVER_MODULE_DIR")))
  (let ((a (make-temp-file "sb-ss-" nil ".png"))
        (b (make-temp-file "sb-ss-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph buf (vector) (vector) 2)
          (condition-case err
              (progn
                (cmacs-screensaver-attach-background
                 buf cmacs-secondbrain-screensaver 400 300)
                ;; Give the child time to spawn, load and produce frames.
                (dotimes (_ 60) (sleep-for 0.05)
                         (ignore-errors (cmacs-libregnum-ink-bbox buf)))
                (cmacs-libregnum-snapshot buf a)
                (dotimes (_ 20) (sleep-for 0.05)
                         (ignore-errors (cmacs-libregnum-ink-bbox buf)))
                (cmacs-libregnum-snapshot buf b)
                (let ((read (lambda (f)
                              (with-temp-buffer
                                (set-buffer-multibyte nil)
                                (insert-file-contents-literally f)
                                (buffer-string)))))
                  (should-not (equal (funcall read a) (funcall read b))))
                (cmacs-screensaver-detach-background buf))
            (error (ignore-errors (cmacs-screensaver-detach-background buf))
                   (signal (car err) (cdr err)))))
      (ignore-errors (delete-file a))
      (ignore-errors (delete-file b)))))

(ert-deftest cmacs-secondbrain-test-screensaver-frame-byte-order ()
  "A cool screensaver renders cool, not warm.

A channel-order regression test, and it exists because the bug it guards
is invisible to every cheaper check.  The shm frames arrive in
ARGB8888 == GL_BGRA order; raylib has no BGRA format, so they are
swizzled before upload.  Skip the swizzle and red and blue trade places
-- which on a space scene is not a corrupt picture but a perfectly
plausible one in the wrong palette.  It passed a round-trip test, an
ink-bbox test and a frames-differ test while doing exactly that, and the
symptom was mistaken for a bug in the screensaver's own --profile flag.

So this asserts the palette: `blackhole --profile cool' must come out
blue, and blue means the frame's mean blue beats its mean red."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-screensaver-supported-p)
                    (cmacs-screensaver-supported-p)
                    (fboundp 'cmacs-screensaver-attach-background)
                    (fboundp 'cmacs-libregnum-mean-color)
                    (getenv "CMACS_SCREENSAVER_MODULE_DIR")))
  (cmacs-secondbrain-tests--with-view buf
    ;; No graph: the frame is then the screensaver and nothing else.
    (cmacs-secondbrain-set-graph buf (vector) (vector) 2)
    (unwind-protect
        (progn
          (cmacs-screensaver-attach-background
           buf 'blackhole-cool-orbit 320 240)
          (dotimes (_ 80) (sleep-for 0.05)
                   (ignore-errors (cmacs-libregnum-ink-bbox buf)))
          (let ((mean (cmacs-libregnum-mean-color buf)))
            (should mean)
            ;; Something was actually drawn.
            (should (> (apply #'+ mean) 0))
            ;; And it is cool: blue over red.  Swap the channels and this
            ;; is the assertion that fails.
            (should (> (nth 2 mean) (nth 0 mean)))))
      (ignore-errors (cmacs-screensaver-detach-background buf)))))

(ert-deftest cmacs-secondbrain-test-pin-survives-a-relayout ()
  "A dragged node stays where it was dropped, through a re-layout.

`pinned' used to mean only \"the force solver must not move this\", which
was enough while the solver was the only thing that moved anything.  The
closed-form layouts re-place every node from scratch, so a drag was
silently undone by the next layout switch -- or by anything else that
re-placed.  Unpinning must hand the node back."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-move-node))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                 (list :id "b" :title "B" :kind 'file :ring 'memory))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (let ((home (cmacs-secondbrain-node-position buf "a")))
      (should home)
      (should (cmacs-secondbrain-move-node buf "a" 5.0 6.0 0.0 t))
      (should (equal '(5.0 6.0 0.0) (cmacs-secondbrain-node-position buf "a")))
      ;; The pin holds through a re-place.
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (equal '(5.0 6.0 0.0) (cmacs-secondbrain-node-position buf "a")))
      ;; And releasing it gives the node back to the layout.
      (should (= 1 (cmacs-secondbrain-set-pinned buf "a" nil)))
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (equal home (cmacs-secondbrain-node-position buf "a"))))))

(ert-deftest cmacs-secondbrain-test-unpin-all ()
  "`cmacs-secondbrain-set-pinned' with a nil id reaches every node."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-pinned))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                 (list :id "b" :title "B" :kind 'file :ring 'memory))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cmacs-secondbrain-move-node buf "a" 1.0 1.0 0.0 t)
    (cmacs-secondbrain-move-node buf "b" 2.0 2.0 0.0 t)
    (should (= 2 (cmacs-secondbrain-set-pinned buf nil nil)))
    ;; Idempotent: nothing left to change.
    (should (= 0 (cmacs-secondbrain-set-pinned buf nil nil)))))

(ert-deftest cmacs-secondbrain-test-select-reaches-the-scene ()
  "Selecting from Lisp sets the SCENE's selection, not just a variable.

The halo and the lit links come from the scene's own selection, which a
click sets in C.  Keyboard navigation, search and the inspector all
select from Lisp, and used to leave the scene none the wiser -- so those
paths got no halo and no lit links at all."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-select))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (should (equal "a" (cmacs-secondbrain-select buf "a")))
    (should-not (cmacs-secondbrain-select buf "no-such-node"))
    (should-not (cmacs-secondbrain-select buf nil))))

(ert-deftest cmacs-secondbrain-test-link-pulse-changes-the-frame ()
  "Advancing the link phase repaints the selected node's links.

Asserts the picture, not the setter: the whole point is that the light
moves, and a phase stored but never used would pass any check that only
looked at return values."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-link-phase))
  (let ((p0 (make-temp-file "sb-ph-" nil ".png"))
        (p1 (make-temp-file "sb-ph-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph
           buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                       (list :id "b" :title "B" :kind 'file :ring 'memory)
                       (list :id "c" :title "C" :kind 'file :ring 'memory))
           (vector (list :from "a" :to "b") (list :from "a" :to "c"))
           2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (should (cmacs-secondbrain-select buf "a"))
          (cmacs-secondbrain-set-link-phase buf 0.0)
          (cmacs-secondbrain-apply-flags buf)
          (cmacs-libregnum-snapshot buf p0)
          ;; Half a bead-span, deliberately.  The beads are identical and
          ;; evenly spaced, so the pattern REPEATS every whole span --
          ;; advancing by one produces a pixel-identical frame and this
          ;; test would pass or fail on arithmetic rather than on whether
          ;; anything moved.  Verified: a whole-span delta gives 405/405
          ;; identical pixels, a half-span delta does not.
          (cmacs-secondbrain-set-link-phase buf 1.665)
          (cmacs-secondbrain-apply-flags buf)
          (cmacs-libregnum-snapshot buf p1)
          ;; Snapshots, not `cmacs-libregnum-mean-color': a spark covers
          ;; a few dozen pixels of a hundred thousand, so it moves the
          ;; frame mean by less than a single unit and rounds away.  The
          ;; mean is the right probe for a palette and the wrong one for
          ;; a handful of bright pixels changing place.
          (let ((read (lambda (f)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally f)
                          (buffer-string)))))
            (should-not (equal (funcall read p0) (funcall read p1)))))
      (ignore-errors (delete-file p0))
      (ignore-errors (delete-file p1)))))

(ert-deftest cmacs-secondbrain-test-auto-rotate-turns-the-rings ()
  "Auto-rotation moves the nodes, rather than only the camera.

Picking follows the nodes precisely because it is the layout that turns;
a camera trick would look the same and leave every pick box behind."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain--rotate-step))
  (cmacs-secondbrain-tests--with-view buf
    (with-current-buffer buf
      (cmacs-secondbrain-mode)
      (cmacs-secondbrain-set-graph
       buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                   (list :id "b" :title "B" :kind 'file :ring 'memory))
       (vector) 2)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (let ((before (cmacs-secondbrain-node-position buf "a"))
            (cmacs-secondbrain-auto-rotate 90.0))
        (cmacs-secondbrain--rotate-step buf 1.0)
        (should-not (equal before (cmacs-secondbrain-node-position buf "a"))))
      ;; Off means off.
      (let ((now (cmacs-secondbrain-node-position buf "a"))
            (cmacs-secondbrain-auto-rotate 0.0))
        (cmacs-secondbrain--rotate-step buf 1.0)
        (should (equal now (cmacs-secondbrain-node-position buf "a")))))))

(ert-deftest cmacs-secondbrain-test-hub-selection-lights-its-members ()
  "Selecting a department lights what the department connects to.

A hub carries no org-roam links of its own -- only its members do -- so
matching against the selected node alone lit nothing at all, which is
exactly how selecting a department looked.  Membership walks the parent
chain, so a note nested below a folder below a hub still counts."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-link-phase))
  (let ((p0 (make-temp-file "sb-hub-" nil ".png"))
        (p1 (make-temp-file "sb-hub-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph
           buf (vector (list :id "h" :title "H" :kind 'hub :ring 'memory)
                       (list :id "a" :title "A" :kind 'file :ring 'memory
                             :parent "h")
                       (list :id "b" :title "B" :kind 'file :ring 'memory))
           (vector (list :from "a" :to "b"))
           2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (cmacs-secondbrain-apply-flags buf)
          (cmacs-libregnum-snapshot buf p0)
          ;; Selecting the HUB must change the picture, because its
          ;; member's link is now lit.
          (should (cmacs-secondbrain-select buf "h"))
          (cmacs-secondbrain-apply-flags buf)
          (cmacs-libregnum-snapshot buf p1)
          (let ((read (lambda (f)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally f)
                          (buffer-string)))))
            (should-not (equal (funcall read p0) (funcall read p1)))))
      (ignore-errors (delete-file p0))
      (ignore-errors (delete-file p1)))))

(provide 'cmacs-secondbrain-tests)

;;; cmacs-secondbrain-tests.el ends here
