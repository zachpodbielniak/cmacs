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

(ert-deftest cmacs-secondbrain-test-neighbours-are-flagged-for-labelling ()
  "A selected node's linked nodes are flagged, so their names are drawn.

Eligibility alone was not enough: labels are capped, and the cap ranks
by node SIZE, so a linked note loses to every hub in the scene and its
label is dropped.  A lit rope running off to an unlabelled dot says
something is connected without saying what.  The flag buys the label a
priority tier of its own.

Also asserts the flag is CLEARED when the selection moves -- stale
neighbours keeping their labels is its own kind of wrong answer."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-node-flags))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                 (list :id "b" :title "B" :kind 'file :ring 'memory)
                 (list :id "c" :title "C" :kind 'file :ring 'memory))
     (vector (list :from "a" :to "b"))
     2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (let* ((emit (lambda (id)
                   ;; Scene indices are emission order; find each node's.
                   (cl-loop for i from 0 below (cmacs-secondbrain-node-count buf)
                            when (equal id (plist-get
                                            (cmacs-secondbrain-node-at buf id)
                                            :id))
                            return i)))
           (nbr 8))                     ; CMACS_LIBREGNUM_NODE_NEIGHBOUR
      (ignore emit)
      (should (cmacs-secondbrain-select buf "a"))
      (cmacs-secondbrain-apply-flags buf)
      ;; Exactly one node is a neighbour of "a": "b".
      (let ((flagged
             (cl-loop for i from 0 below 8
                      when (and (cmacs-libregnum-node-flags buf i)
                                (/= 0 (logand nbr
                                              (cmacs-libregnum-node-flags buf i))))
                      count 1)))
        (should (= 1 flagged)))
      ;; Selecting the unconnected node leaves nobody flagged.
      (should (cmacs-secondbrain-select buf "c"))
      (cmacs-secondbrain-apply-flags buf)
      (let ((flagged
             (cl-loop for i from 0 below 8
                      when (and (cmacs-libregnum-node-flags buf i)
                                (/= 0 (logand nbr
                                              (cmacs-libregnum-node-flags buf i))))
                      count 1)))
        (should (= 0 flagged))))))

(ert-deftest cmacs-secondbrain-test-defaults-are-cheap ()
  "The out-of-the-box view does not opt you into a standing cost.

Three settings hold a clock up or a process open for as long as the
buffer lives, and each should be something you choose rather than
something you inherit.  A default that quietly runs a second process is
the kind of thing nobody notices until they wonder why the machine is
warm."
  (skip-unless (boundp 'cmacs-secondbrain-background))
  ;; A screensaver background means a second process rendering
  ;; continuously; the procedural backgrounds are cached textures.
  (should-not (eq 'screensaver (default-value 'cmacs-secondbrain-background)))
  ;; Rotation costs a layout pass per tick.
  (should (= 0.0 (default-value 'cmacs-secondbrain-auto-rotate))))

(ert-deftest cmacs-secondbrain-test-every-setting-is-customizable ()
  "Every knob is a defcustom in the `cmacs-secondbrain' group.

So `M-x customize-group' shows the whole surface with its documentation,
rather than half of it plus some variables a reader has to find by
grepping."
  (skip-unless (boundp 'cmacs-secondbrain-background))
  (let ((members (mapcar #'car (get 'cmacs-secondbrain 'custom-group)))
        (missing nil))
    (should members)
    (dolist (sym '(cmacs-secondbrain-background
                   cmacs-secondbrain-background-colors
                   cmacs-secondbrain-background-image
                   cmacs-secondbrain-screensaver
                   cmacs-secondbrain-wallpaper-dirs
                   cmacs-secondbrain-particles
                   cmacs-secondbrain-particle-fps
                   cmacs-secondbrain-link-pulse
                   cmacs-secondbrain-link-pulse-speed
                   cmacs-secondbrain-auto-rotate
                   cmacs-secondbrain-rotate-speed
                   cmacs-secondbrain-drag-nodes
                   cmacs-secondbrain-hover-highlights-group
                   cmacs-secondbrain-fly-context
                   cmacs-secondbrain-start-collapsed
                   cmacs-secondbrain-label-size
                   cmacs-secondbrain-max-labels
                   cmacs-secondbrain-label-reference-height
                   cmacs-secondbrain-label-scale-max))
      (unless (and (custom-variable-p sym) (memq sym members))
        (push sym missing)))
    (should (equal nil (nreverse missing)))))

(ert-deftest cmacs-secondbrain-test-node-shading-changes-the-frame ()
  "Shading actually reaches the picture, and can be turned off.

The failure this guards is specific and was real: the highlight is a
small sphere placed toward the light, and at any offset under 1.0 node
radius it sits INSIDE an opaque sphere -- perfectly computed, completely
invisible.  A test that only checked the setter returned t would have
been happy with that."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-shading))
  (let ((on (make-temp-file "sb-sh-" nil ".png"))
        (off (make-temp-file "sb-sh-" nil ".png"))
        (nodes (vector (list :id "a" :title "A" :kind 'hub :ring 'memory
                             :count 40))))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (should (cmacs-secondbrain-set-shading buf t))
          (cmacs-secondbrain-set-graph buf nodes (vector) 2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (cmacs-libregnum-snapshot buf on)
          ;; Read at build time, so rebuild after changing it.
          (should-not (cmacs-secondbrain-set-shading buf nil))
          (cmacs-secondbrain-set-graph buf nodes (vector) 2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (cmacs-libregnum-snapshot buf off)
          (let ((read (lambda (f)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally f)
                          (buffer-string)))))
            (should-not (equal (funcall read on) (funcall read off)))))
      (ignore-errors (delete-file on))
      (ignore-errors (delete-file off)))))

(ert-deftest cmacs-secondbrain-test-double-click-flies-to-the-node ()
  "A double click focuses the node it hit.

The single click still fires first -- the two arrive in order, so
selecting and then flying is one gesture rather than two competing
ones."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain--on-double-click))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                 (list :id "b" :title "B" :kind 'file :ring 'memory))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cmacs-secondbrain-fit buf)
    (let ((before (cmacs-libregnum-camera-state buf)))
      (cmacs-secondbrain--on-double-click buf 0 "a")
      (dotimes (_ 40) (ignore-errors (cmacs-libregnum-ink-bbox buf)))
      (should-not (equal before (cmacs-libregnum-camera-state buf))))
    ;; An id nobody has is reported, not an error.
    (cmacs-secondbrain--on-double-click buf 0 "no-such-node")))

(ert-deftest cmacs-secondbrain-test-node-lighting-is-camera-relative ()
  "A node looks lit from every camera angle, not just one.

This is the whole reason the nodes are impostors -- camera-facing quads
carrying a pre-lit sphere -- rather than a small bright sphere offset in
world space.  The offset version worked only because the flat view's
camera happens to sit on +Z: orbit into the 3D view and the highlight
slides round to the back of the node and disappears.  Shading that holds
for one camera angle is a coincidence, not shading.

So: orbit a full turn and the frame must stay put."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-libregnum-mean-color)
                    (fboundp 'cmacs-libregnum-orbit)))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-libregnum-set-background buf 'solid #x0A0A10FF #x0A0A10FF)
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'hub :ring 'memory
                       :count 200))
     (vector) 3)
    (cmacs-secondbrain-set-projection buf nil)      ; free 3D
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cmacs-secondbrain-fit buf)
    (let ((first (cmacs-libregnum-mean-color buf)))
      (should first)
      (should (> (apply #'+ first) 0))            ; something is drawn
      (dolist (_ '(1 2 3))
        (cmacs-libregnum-orbit buf 300.0 0.0)
        (dotimes (_ 3) (ignore-errors (cmacs-libregnum-ink-bbox buf)))
        (let ((now (cmacs-libregnum-mean-color buf)))
          ;; Within a unit or two per channel: the orb is identical, and
          ;; only the band guide behind it moves.
          (cl-loop for a in first for b in now
                   do (should (< (abs (- a b)) 4))))))))

(ert-deftest cmacs-secondbrain-test-impostors-do-not-accumulate ()
  "Rebuilding the scene does not leave the old node impostors behind.

`clear-drawables' does not clear billboards, so a scene that adds one
per node has to clear them itself.  Forgetting grows the list by one per
node on every refresh -- thousands of stale quads sitting where the
nodes used to be, which a screenshot of a freshly built scene hides
completely because the newest ones are drawn in the right places."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-billboard-count))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                         (list :id "b" :title "B" :kind 'file :ring 'memory)))
          counts)
      (dotimes (_ 4)
        (cmacs-secondbrain-set-graph buf nodes (vector) 2)
        (push (cmacs-libregnum-billboard-count buf) counts))
      (should (= 1 (length (delete-dups (copy-sequence counts)))))
      (should (> (car counts) 0)))))

(ert-deftest cmacs-secondbrain-test-glow-adds-halo-billboards ()
  "With glow on, every node carries a halo billboard; with it off, none.

Counted, not screenshotted: an additive halo at rest alpha moves a
frame mean by almost nothing, but each one is an entry in the billboard
list, and the delta must be exactly one per node -- a delta of zero
means the feature is dead, more means something else leaked in with it."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-secondbrain-set-glow)
                    (fboundp 'cmacs-libregnum-billboard-count)))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                         (list :id "b" :title "B" :kind 'file :ring 'memory)
                         (list :id "c" :title "C" :kind 'skill :ring 'skills)))
          with without)
      (cmacs-secondbrain-set-glow buf t)
      (cmacs-secondbrain-set-graph buf nodes (vector) 2)
      (setq with (cmacs-libregnum-billboard-count buf))
      (cmacs-secondbrain-set-glow buf nil)
      (cmacs-secondbrain-set-graph buf nodes (vector) 2)
      (setq without (cmacs-libregnum-billboard-count buf))
      ;; One halo per visible node -- including the skill gem, which
      ;; keeps its geometry but still glows.
      (should (= (- with without) 3))
      ;; And with the halos off there are no billboards left at all.
      ;; Round nodes used to be impostor billboards, so this number was
      ;; once non-zero; they are real lit geometry now and the billboard
      ;; list is the halos and nothing else.
      (should (= without 0)))))

(ert-deftest cmacs-secondbrain-test-round-nodes-are-real-geometry ()
  "Round nodes are lit sphere GEOMETRY, not camera-facing impostors.

They used to be impostors: a flat quad wearing a picture of a sphere,
with its highlight baked into screen space, so orbiting never changed
how anything was lit and a field of them read as stickers on a sheet.
Counting is the only way to tell from the outside -- both look round in
a still -- so count: one orb per round node, no impostor billboards, and
nothing left over."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-libregnum-orb-count)
                    (fboundp 'cmacs-secondbrain-set-shading)))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (vector (list :id "a" :title "A" :kind 'file  :ring 'memory)
                         (list :id "b" :title "B" :kind 'hub   :ring 'memory)
                         (list :id "c" :title "C" :kind 'skill :ring 'skills)
                         (list :id "d" :title "D" :kind 'app   :ring
                               'applications))))
      (cmacs-secondbrain-set-glow buf nil)
      (cmacs-secondbrain-set-shading buf t)
      (cmacs-secondbrain-set-graph buf nodes (vector) 3)
      ;; Two round ones (the file and the hub).  The gem and the prism
      ;; keep their own geometry: their shape is what they mean.
      (should (= 2 (cmacs-libregnum-orb-count buf)))
      (should (= 0 (cmacs-libregnum-billboard-count buf)))
      ;; Shading off drops back to plain unlit geometry for everything.
      (cmacs-secondbrain-set-shading buf nil)
      (cmacs-secondbrain-set-graph buf nodes (vector) 3)
      (should (= 0 (cmacs-libregnum-orb-count buf))))))

(ert-deftest cmacs-secondbrain-test-orbs-do-not-accumulate ()
  "Rebuilding keeps the orb count flat.

The same trap billboards fall into, and for the same reason: orbs are
not cleared by `clear-drawables\=', so a rebuild that forgets them leaves
every previous copy behind at the position its node used to be in.  That
is invisible in a screenshot -- the stale orbs sit under the live ones --
and obvious in this number."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-orb-count))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                         (list :id "b" :title "B" :kind 'file :ring 'memory)))
          counts)
      (dotimes (_ 4)
        (cmacs-secondbrain-set-graph buf nodes (vector) 3)
        (push (cmacs-libregnum-orb-count buf) counts))
      (should (= 1 (length (delete-dups (copy-sequence counts)))))
      (should (= 2 (car counts))))))

(ert-deftest cmacs-secondbrain-test-orbiting-relights-the-nodes ()
  "Orbiting changes how a node is lit, because the key light is fixed.

The trap this catches is a pure headlight.  It looks like the obvious
choice -- a light attached to the camera can never leave a node in
shadow -- and it makes real geometry pointless: a sphere lit from
wherever you are standing is IDENTICAL from every angle, so the render
would be real and the picture would still read as a sticker.

A sphere\='s silhouette does not change under orbit either, so any change
in the frame at all is the shading and nothing else."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-libregnum-mean-color)
                    (fboundp 'cmacs-libregnum-orbit)))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-glow buf nil)
    (cmacs-secondbrain-set-shading buf t)
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'hub :ring 'memory))
     (vector) 3)
    ;; Aim at the node explicitly rather than through `fit', and stand
    ;; close.  A ring layout is framed on the ORIGIN and this node sits
    ;; out on its band, so `fit' would leave it a speck: a real shading
    ;; change would then move the frame mean by less than one level and
    ;; the test would pass on a renderer that does no lighting at all.
    (let* ((p (cmacs-secondbrain-node-position buf "a")))
      (cmacs-libregnum-set-camera
       buf (list (nth 0 p) (nth 1 p) (+ (nth 2 p) 1.4)) p 45.0)
      ;; Half a turn in AZIMUTH.  Elevation is the wrong axis for this:
      ;; the default orbit clamps ten degrees short of the pole, so a
      ;; vertical drag pins after two steps and stops producing any
      ;; change to measure.
      (let ((before (cmacs-libregnum-mean-color buf)))
        (cmacs-libregnum-orbit buf (* 200 float-pi) 0)
        (let ((after (cmacs-libregnum-mean-color buf)))
          (should before)
          (should after)
          ;; A real difference, not one level of rounding: a headlight
          ;; would give exactly zero here.
          (should (> (apply #'max (cl-mapcar (lambda (a b) (abs (- a b)))
                                             before after))
                     8)))))))

(ert-deftest cmacs-secondbrain-test-glow-does-not-accumulate ()
  "Rebuilding with glow on keeps the billboard count flat.

The same trap the impostors fell into: billboards are not cleared by
`clear-drawables', so every per-node addition must be cleared by the
build itself or it stacks one copy per refresh."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-secondbrain-set-glow)
                    (fboundp 'cmacs-libregnum-billboard-count)))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (vector (list :id "a" :title "A" :kind 'file :ring 'memory)))
          counts)
      (cmacs-secondbrain-set-glow buf t)
      (dotimes (_ 4)
        (cmacs-secondbrain-set-graph buf nodes (vector) 2)
        (push (cmacs-libregnum-billboard-count buf) counts))
      (should (= 1 (length (delete-dups (copy-sequence counts))))))))

(ert-deftest cmacs-secondbrain-test-isolate-dims-the-far-field ()
  "Isolate mode visibly recedes everything outside the neighbourhood.

Snapshot-compared, because isolate is a paint-time decision that writes
no flags: a check on `get-node-flags' would pass with the feature
entirely disconnected from the framebuffer."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-isolate))
  (let ((p0 (make-temp-file "sb-iso-" nil ".png"))
        (p1 (make-temp-file "sb-iso-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph
           buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                       (list :id "b" :title "B" :kind 'file :ring 'memory)
                       (list :id "far" :title "Far" :kind 'file :ring 'skills))
           (vector (list :from "a" :to "b"))
           2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (should (cmacs-secondbrain-select buf "a"))
          (cmacs-secondbrain-apply-flags buf)
          (cmacs-libregnum-snapshot buf p0)
          (cmacs-secondbrain-set-isolate buf t)
          (cmacs-libregnum-snapshot buf p1)
          (let ((read (lambda (f)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally f)
                          (buffer-string)))))
            (should-not (equal (funcall read p0) (funcall read p1)))))
      (ignore-errors (delete-file p0))
      (ignore-errors (delete-file p1)))))

(ert-deftest cmacs-secondbrain-test-ring-filter-round-trips ()
  "The ring filter dims the other rings, and nil restores them.

The off state is asserted byte-for-byte: \='looks about the same\=' is
exactly how a filter that never fully clears would slip through."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-ring-filter))
  (let ((p0 (make-temp-file "sb-rf-" nil ".png"))
        (p1 (make-temp-file "sb-rf-" nil ".png"))
        (p2 (make-temp-file "sb-rf-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph
           buf (vector (list :id "m" :title "M" :kind 'file :ring 'memory)
                       (list :id "s" :title "S" :kind 'skill :ring 'skills))
           (vector)
           2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (cmacs-libregnum-snapshot buf p0)
          (should (eq 'memory (cmacs-secondbrain-set-ring-filter buf 'memory)))
          (cmacs-libregnum-snapshot buf p1)
          (should-not (cmacs-secondbrain-set-ring-filter buf nil))
          (cmacs-libregnum-snapshot buf p2)
          (should-error (cmacs-secondbrain-set-ring-filter buf 'nonsense))
          (let ((read (lambda (f)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally f)
                          (buffer-string)))))
            (should-not (equal (funcall read p0) (funcall read p1)))
            (should (equal (funcall read p0) (funcall read p2)))))
      (ignore-errors (delete-file p0))
      (ignore-errors (delete-file p1))
      (ignore-errors (delete-file p2)))))

(ert-deftest cmacs-secondbrain-test-age-fade-math ()
  "The fade curve: fresh keeps the colour, undatable counts as fresh,
stale lands most of the way to grey with alpha untouched."
  (skip-unless (fboundp 'cmacs-secondbrain--age-blend))
  ;; Undatable is fresh, not stale.
  (should (= 0.0 (cmacs-secondbrain--age-factor nil)))
  ;; Fresh: mtime of right now.
  (should (< (cmacs-secondbrain--age-factor (float-time)) 0.01))
  ;; Past the horizon it clamps.
  (let ((cmacs-secondbrain-age-fade-days 10.0))
    (should (= 1.0 (cmacs-secondbrain--age-factor
                    (- (float-time) (* 400 86400))))))
  ;; Factor 0 is the identity.
  (should (= #x40C080FF (cmacs-secondbrain--age-blend #x40C080FF 0.0)))
  ;; Factor 1 moves every channel toward grey 64 and leaves alpha alone.
  (let* ((faded (cmacs-secondbrain--age-blend #x00FF00FF 1.0))
         (r (logand (ash faded -24) #xFF))
         (g (logand (ash faded -16) #xFF))
         (b (logand (ash faded -8) #xFF))
         (a (logand faded #xFF)))
    (should (> r 0))                    ; lifted off black, toward grey
    (should (< g 255))                  ; pulled down from full
    (should (> b 0))
    (should (= a #xFF))
    ;; Hue survives: green stays the strongest channel.
    (should (> g r))
    (should (> g b))))

(ert-deftest cmacs-secondbrain-test-age-fade-reaches-the-hubs ()
  "With the fade on, a department hub wears its members' mean age.

The default map is fully collapsed, so a fade that only touched leaf
nodes would render the DEFAULT view pixel-identical with the feature on
and off -- which is exactly how it first shipped, and exactly what this
test exists to prevent."
  (skip-unless (fboundp 'cmacs-secondbrain-collect))
  (cmacs-secondbrain-tests--with-sources
      (list (list :name 'stale-fixture :ring 'memory :label "stale"
                  :enumerate
                  (lambda ()
                    (list (list :id "old" :title "Old" :kind 'file
                                :department "02_areas"
                                :mtime (- (float-time) (* 400 86400)))))))
    (let* ((faded (let ((cmacs-secondbrain-age-fade t))
                    (cmacs-secondbrain-collect)))
           (plain (let ((cmacs-secondbrain-age-fade nil))
                    (cmacs-secondbrain-collect)))
           (hub-of (lambda (g)
                     (seq-find (lambda (n)
                                 (equal (plist-get n :id)
                                        "hub:memory/02_areas"))
                               (plist-get g :nodes)))))
      ;; Fade on: the hub carries an explicit, blended colour.
      (should (plist-get (funcall hub-of faded) :color))
      ;; And it is not the raw PARA colour -- 400 days is fully stale.
      (should-not (equal (plist-get (funcall hub-of faded) :color)
                         (cmacs-para-color "02_areas")))
      ;; Fade off: the hub is left colourless for the ring default.
      (should-not (plist-get (funcall hub-of plain) :color)))))

(ert-deftest cmacs-secondbrain-test-pick-agrees-with-projection ()
  "A pick at a node's projected centre selects that node, and the pick
region is centred on the projection rather than offset into a quadrant.

The projection and the pick can each be self-consistent and still
disagree with each other -- and the window-layer bug this guards
against (paint at the full window rect, pick at the text area) lived
exactly in that gap: every node had to be clicked above and to the
right of where it was drawn."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-pick-at))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory))
     (vector) 2)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cmacs-secondbrain-fit buf)
    (let* ((pos (cmacs-secondbrain-node-position buf "a"))
           (proj (apply #'cmacs-libregnum-project
                        buf (append pos (list 400 300))))
           (sx (car proj)) (sy (cadr proj)))
      ;; Dead centre must hit.
      (should (cmacs-libregnum-pick-at buf sx sy))
      ;; And the hit region must be symmetric about the projection: find
      ;; its extent along each axis and require the centre to sit within
      ;; a couple of pixels of the projected point.
      (let ((minx sx) (maxx sx) (miny sy) (maxy sy))
        (cl-loop for d from 2 to 120 by 2 do
          (when (cmacs-libregnum-pick-at buf (- sx d) sy)
            (setq minx (- sx d)))
          (when (cmacs-libregnum-pick-at buf (+ sx d) sy)
            (setq maxx (+ sx d)))
          (when (cmacs-libregnum-pick-at buf sx (- sy d))
            (setq miny (- sy d)))
          (when (cmacs-libregnum-pick-at buf sx (+ sy d))
            (setq maxy (+ sy d))))
        (should (< (abs (- (/ (+ minx maxx) 2.0) sx)) 3.0))
        (should (< (abs (- (/ (+ miny maxy) 2.0) sy)) 3.0))))))

(ert-deftest cmacs-secondbrain-test-match-set-takes-ids ()
  "The match set is addressed by id string, and actually flags nodes.

The regression this pins: the libregnum setter keeps only the FIXNUMS
it is handed and silently drops everything else, so passing it ids --
which is what every caller here has -- flagged zero nodes while the
caller reported a match count.  Search highlighted nothing, confidently."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-match-set))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "alpha" :title "Alpha" :kind 'file :ring 'memory)
                 (list :id "beta"  :title "Beta"  :kind 'file :ring 'memory))
     (vector) 2)
    ;; One id in, one node flagged.
    (should (= 1 (cmacs-secondbrain-set-match-set buf '("alpha") t)))
    ;; A vector works too, and both ids resolve.
    (should (= 2 (cmacs-secondbrain-set-match-set buf ["alpha" "beta"] t)))
    ;; An unknown id is skipped rather than counted.
    (should (= 1 (cmacs-secondbrain-set-match-set buf '("alpha" "nope") t)))
    ;; nil clears.
    (should (= 0 (cmacs-secondbrain-set-match-set buf nil nil)))))

(ert-deftest cmacs-secondbrain-test-match-set-changes-the-frame ()
  "Flagging a match visibly changes the picture.

Counting flagged nodes proves the ids resolved; only the frame proves
the colour reached the screen."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-match-set))
  (let ((p0 (make-temp-file "sb-ms-" nil ".png"))
        (p1 (make-temp-file "sb-ms-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-view buf
          (cmacs-secondbrain-set-graph
           buf (vector (list :id "alpha" :title "Alpha" :kind 'file :ring 'memory)
                       (list :id "beta"  :title "Beta"  :kind 'file :ring 'memory))
           (vector) 2)
          (cmacs-secondbrain-set-layout buf 'rings 0)
          (cmacs-secondbrain-fit buf)
          (cmacs-libregnum-snapshot buf p0)
          (cmacs-secondbrain-set-match-set buf '("alpha") t)
          (cmacs-libregnum-snapshot buf p1)
          (let ((read (lambda (f)
                        (with-temp-buffer
                          (set-buffer-multibyte nil)
                          (insert-file-contents-literally f)
                          (buffer-string)))))
            (should-not (equal (funcall read p0) (funcall read p1)))))
      (ignore-errors (delete-file p0))
      (ignore-errors (delete-file p1)))))

(ert-deftest cmacs-secondbrain-test-scene-index-round-trips ()
  "An id maps to a scene index and back, and a hidden node has none.

The two halves of the id<->index bridge the keyboard navigation stands
on: libregnum answers in scene indices, everything here keys on ids."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-scene-index))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "hub" :title "Hub" :kind 'hub :ring 'memory)
                 (list :id "kid" :title "Kid" :kind 'file :ring 'memory
                       :parent "hub"))
     (vector) 2)
    (let ((i (cmacs-secondbrain-scene-index buf "hub")))
      (should (integerp i))
      (should (equal "hub" (cmacs-secondbrain-node-id-at buf i))))
    ;; Unknown ids have no index, and neither does a collapsed member.
    (should-not (cmacs-secondbrain-scene-index buf "nope"))
    (cmacs-secondbrain-set-collapsed buf "hub" t 0)
    (should-not (cmacs-secondbrain-scene-index buf "kid"))
    ;; Expanding brings it back -- which is what `--nav-reveal' relies on.
    (cmacs-secondbrain-set-collapsed buf "hub" nil 0)
    (should (integerp (cmacs-secondbrain-scene-index buf "kid")))))

(ert-deftest cmacs-secondbrain-test-nav-reveals-before-selecting ()
  "Jumping to a node inside a collapsed department expands it first.

Without this a keyboard jump into the default (fully collapsed) map
selects something with no scene entry: no halo, no camera move, no
error -- indistinguishable from the key doing nothing."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain--nav-goto))
  (cmacs-secondbrain-tests--with-view buf
    (with-current-buffer buf
      (cmacs-secondbrain-mode)
      (setq cmacs-secondbrain--graph
            (list :nodes (list (list :id "hub" :title "Hub" :kind 'hub
                                     :ring 'memory)
                               (list :id "kid" :title "Kid" :kind 'file
                                     :ring 'memory :parent "hub"))
                  :edges nil))
      (cmacs-secondbrain-set-graph
       buf (vector (list :id "hub" :title "Hub" :kind 'hub :ring 'memory)
                   (list :id "kid" :title "Kid" :kind 'file :ring 'memory
                         :parent "hub"))
       (vector) 2)
      (cmacs-secondbrain-set-collapsed buf "hub" t 0)
      (should-not (cmacs-secondbrain-scene-index buf "kid"))
      (cmacs-secondbrain--nav-goto "kid")
      ;; Revealed, and really selected in the scene.
      (should (cmacs-secondbrain-scene-index buf "kid"))
      (should (equal "kid" cmacs-secondbrain--selected)))))

(ert-deftest cmacs-secondbrain-test-nav-siblings-and-links ()
  "Sibling and link walks are ordered, deduplicated and undirected."
  (skip-unless (fboundp 'cmacs-secondbrain--nav-siblings))
  (with-temp-buffer
    (setq-local cmacs-secondbrain--graph
                (list :nodes (list (list :id "hub" :title "Hub")
                                   (list :id "b" :title "Beta" :parent "hub")
                                   (list :id "a" :title "Alpha" :parent "hub")
                                   (list :id "c" :title "Gamma" :parent "hub"))
                      :edges (list (list :from "hub" :to "a")
                                   (list :from "b" :to "a")
                                   ;; A duplicate, and the reverse direction.
                                   (list :from "a" :to "b"))))
    ;; Siblings come back in TITLE order, not insertion order.
    (should (equal '("a" "b" "c") (cmacs-secondbrain--nav-siblings "a")))
    ;; Links are undirected and deduplicated: a is linked to hub and b once.
    (should (equal '("b" "hub")
                   (sort (copy-sequence (cmacs-secondbrain--nav-links "a"))
                         (lambda (x y) (string-lessp x y)))))
    ;; A top-level node's peers are the other top-level nodes.
    (should (equal '("hub") (cmacs-secondbrain--nav-siblings "hub")))))

(ert-deftest cmacs-secondbrain-test-nav-search-matches ()
  "The incremental matcher honours its style and orders hits by title."
  (skip-unless (fboundp 'cmacs-secondbrain--matches-for))
  (with-temp-buffer
    (setq-local cmacs-secondbrain--graph
                (list :nodes (list (list :id "1" :title "Zeta project"
                                         :file "/n/01_projects/zeta.org")
                                   (list :id "2" :title "Alpha project"
                                         :file "/n/01_projects/alpha.org")
                                   (list :id "3" :title "Notes"
                                         :file "/n/02_areas/notes.org"))
                      :edges nil))
    (cmacs-secondbrain--build-haystacks)
    (let ((cmacs-secondbrain-search-style 'literal))
      ;; Alphabetical by title, so cycling is stable across rebuilds.
      (should (equal ["2" "1"] (cmacs-secondbrain--matches-for "project"))))
    (let ((cmacs-secondbrain-search-style 'orderless))
      ;; Words may appear in any order, and the path is part of the hay.
      (should (equal ["2"] (cmacs-secondbrain--matches-for "alpha proj"))))
    ;; An empty needle is not a match-everything.
    (should-not (cmacs-secondbrain--matches-for ""))))

(ert-deftest cmacs-secondbrain-test-every-key-is-bound-to-a-command ()
  "Every key in the map runs a real, interactive command.

A keymap entry naming a function that never got defined -- or that
lives in a file nobody requires -- fails only when a user presses that
key, which is the worst possible time to find out."
  (skip-unless (boundp 'cmacs-secondbrain-mode-map))
  (require 'cmacs-secondbrain-nav)
  (let ((missing nil))
    (map-keymap
     (lambda (_event def)
       (when (and (symbolp def) def (not (keymapp def)))
         (unless (commandp def) (push def missing))))
     cmacs-secondbrain-mode-map)
    (should-not missing)))

(defun cmacs-secondbrain-tests--cam-dist (buf)
  "Distance from BUF's camera to its target."
  (let* ((st (cmacs-libregnum-camera-state buf))
         (p (plist-get st :position))
         (tg (plist-get st :target)))
    (sqrt (apply #'+ (cl-mapcar (lambda (a b) (* (- a b) (- a b))) p tg)))))

(defmacro cmacs-secondbrain-tests--with-live-graph (buf &rest body)
  "Attach BUF with a three-ring graph and both graph halves populated.

The Lisp-side `cmacs-secondbrain--graph\=' matters as much as the scene:
the navigation layer reads topology from it, and a test that sets only
the scene passes while every keyboard command sees an empty map."
  (declare (indent 1) (debug t))
  `(cmacs-secondbrain-tests--with-view ,buf
     (with-current-buffer ,buf
       (cmacs-secondbrain-mode)
       (let ((g (list :nodes (list (list :id "a" :title "A" :kind 'file
                                         :ring 'memory)
                                   (list :id "b" :title "B" :kind 'file
                                         :ring 'skills)
                                   (list :id "c" :title "C" :kind 'file
                                         :ring 'applications))
                      :edges nil)))
         (setq cmacs-secondbrain--graph g)
         (cmacs-secondbrain-set-graph ,buf (vconcat (plist-get g :nodes))
                                      (vector) 2))
       (cmacs-secondbrain-set-layout ,buf 'rings 0)
       (cmacs-secondbrain-fit ,buf)
       ,@body)))

(ert-deftest cmacs-secondbrain-test-zoom-moves-the-camera ()
  "`+\=' closes the distance to the target and `-\=' opens it.

Asserts the DIRECTION, because the sign convention is easy to invert:
the underlying call scales by 0.9^amount, so positive means closer --
and roamgraph\'s docstring claimed the opposite for years while its own
zoom-in passed a positive amount."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-zoom))
  (cmacs-secondbrain-tests--with-live-graph buf
    (let ((start (cmacs-secondbrain-tests--cam-dist buf)))
      (cmacs-secondbrain-zoom-in)
      (let ((closer (cmacs-secondbrain-tests--cam-dist buf)))
        (should (< closer start))
        (cmacs-secondbrain-zoom-out)
        (cmacs-secondbrain-zoom-out)
        (should (> (cmacs-secondbrain-tests--cam-dist buf) closer))))))

(ert-deftest cmacs-secondbrain-test-recenter-repivots-on-the-selection ()
  "`f\=' aims the camera TARGET at the selection, not just the position.

That is what makes zooming and orbiting afterwards revolve around the
node you chose.  Moving only the position would look identical in a
still frame and behave wrongly the moment you orbit."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-recenter))
  (let ((shot (make-temp-file "sb-rc-" nil ".png")))
    (unwind-protect
        (cmacs-secondbrain-tests--with-live-graph buf
          (cmacs-secondbrain--nav-goto "c")
          (cmacs-secondbrain-recenter)
          ;; Focus eases inside the RENDER pass, so it needs frames --
          ;; stepping the layout tween would prove nothing.
          (dotimes (_ 40) (cmacs-libregnum-snapshot buf shot))
          (let ((target (plist-get (cmacs-libregnum-camera-state buf) :target))
                (pos (cmacs-secondbrain-node-position buf "c")))
            (should pos)
            (cl-loop for a in target for b in pos
                     do (should (< (abs (- a b)) 0.01))))
          ;; And a zoom from there closes on that node.
          (let ((d (cmacs-secondbrain-tests--cam-dist buf)))
            (cmacs-secondbrain-zoom-in)
            (should (< (cmacs-secondbrain-tests--cam-dist buf) d))))
      (ignore-errors (delete-file shot)))))

(ert-deftest cmacs-secondbrain-test-recenter-needs-a-selection ()
  "With nothing selected it says so rather than moving the camera."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-recenter))
  (cmacs-secondbrain-tests--with-live-graph buf
    (setq cmacs-secondbrain--selected nil)
    (should-error (cmacs-secondbrain-recenter) :type 'user-error)))

(ert-deftest cmacs-secondbrain-test-spatial-move-follows-offscreen ()
  "A spatial step that lands off-screen brings the camera along.

Zoom in far enough that the neighbours are outside the viewport, then
step: without the follow the selection moves to a node the user cannot
see, and every further step is blind."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (and (fboundp 'cmacs-secondbrain-move-right)
                    (fboundp 'cmacs-libregnum-node-onscreen-p)))
  (cmacs-secondbrain-tests--with-live-graph buf
    (let ((shot (make-temp-file "sb-fol-" nil ".png")))
      (unwind-protect
          (progn
            (cmacs-secondbrain--nav-goto "a")
            ;; Close in hard so the rest of the map leaves the viewport.
            (dotimes (_ 12) (cmacs-secondbrain-zoom-in))
            (cmacs-secondbrain-move-right)
            ;; The step either found nothing (selection unchanged) or it
            ;; moved -- and then the camera must end up showing it.
            (unless (equal "a" cmacs-secondbrain--selected)
              ;; A fly is a GOAL that the render pass eases toward, so it
              ;; needs frames.  Asserting the camera moved the instant
              ;; the command returned would fail on working code -- which
              ;; is exactly how this test was first written.
              (dotimes (_ 60) (cmacs-libregnum-snapshot buf shot))
              (should (cmacs-secondbrain--nav-onscreen-p
                       cmacs-secondbrain--selected))))
        (ignore-errors (delete-file shot))))))

(defun cmacs-secondbrain-tests--ring-nodes (n)
  "N node plists spread over the four rings."
  (cl-loop for i from 0 below n
           collect (list :id (format "g%d" i) :title (format "G%d" i)
                         :kind 'file
                         :ring (nth (mod i 4)
                                    '(skills memory routines applications)))))

(defun cmacs-secondbrain-tests--zs (buf nodes)
  "The out-of-plane height of every node in NODES.

That is Y, not Z: a 3D planar layout lies in the world\='s GROUND plane
so that the Y-up orbit camera\='s two drag gestures mean \"spin the
galaxy\" and \"raise your eye above it\".  Laid out in XY instead, the
elevation drag walks along the disc\='s own plane and jams against the
pole clamp edge-on.  In the flat view the height axis is Z and is
always zero, which is what every caller here is really asserting."
  (mapcar (lambda (n)
            (let ((p (cmacs-secondbrain-node-position
                      buf (plist-get n :id))))
              (if (cmacs-secondbrain-tests--3d-p buf) (nth 1 p) (nth 2 p))))
          nodes))

(defun cmacs-secondbrain-tests--3d-p (buf)
  "Non-nil when BUF\='s layout was placed in three dimensions."
  (not (cmacs-secondbrain-flat-p buf)))

(ert-deftest cmacs-secondbrain-test-band-guide-matches-its-band ()
  "A ring guide is drawn where that ring actually is.

The band radius is NOT a function of the ring index -- it grows with the
band\='s population, so a department of a thousand notes gets the
circumference to spread over.  The guides were computed from the index
instead, which is a perfectly plausible number and the wrong one: on a
real map they landed at 6/12/18/24 while the bands sat at 6/29/41/45,
four small hoops adrift in the middle of a map five times their size.

Asserted against the HUBS, because that is the observable version of the
claim: the guide passes through the hubs of the ring it names."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-band-radius))
  (cmacs-secondbrain-tests--with-view buf
    ;; A lopsided map, which is the case that broke: one ring holding
    ;; over a thousand nodes next to rings holding a handful.  The
    ;; population has to be big enough that the band OUTGROWS its index
    ;; -- under a few hundred the two formulas agree, and the test would
    ;; pass against the bug.
    (let ((nodes (vector (list :id "big"  :title "big"  :kind 'hub
                               :ring 'memory)
                         (list :id "few"  :title "few"  :kind 'hub
                               :ring 'applications))))
      (setq nodes
            (vconcat nodes
                     (cl-loop for i below 1200
                              collect (list :id (format "m%d" i) :title ""
                                            :kind 'file :parent "big"
                                            :ring 'memory))
                     (cl-loop for i below 3
                              collect (list :id (format "a%d" i) :title ""
                                            :kind 'file :parent "few"
                                            :ring 'applications))))
      (cmacs-secondbrain-set-graph buf nodes (vector) 3)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (cl-labels ((hub-radius (id)
                    (let ((p (cmacs-secondbrain-node-position buf id)))
                      (sqrt (+ (* (nth 0 p) (nth 0 p))
                               (* (nth 2 p) (nth 2 p)))))))
        (let ((mem (cmacs-secondbrain-band-radius buf 'memory))
              (app (cmacs-secondbrain-band-radius buf 'applications)))
          (should mem)
          (should app)
          (should (< (abs (- mem (hub-radius "big"))) 0.01))
          (should (< (abs (- app (hub-radius "few"))) 0.01))
          ;; And the populous ring really did outgrow its index: were
          ;; the radius still a function of the index, memory (index 1)
          ;; would sit at 12 and this would fail, which is what makes the
          ;; test discriminate rather than merely pass.
          (should (> mem 14.0))
          ;; The sparse outer ring is still outside it: growing a band
          ;; must push everything beyond it out too, not let a populous
          ;; inner ring swallow its neighbours.
          (should (> app mem)))))))

(ert-deftest cmacs-secondbrain-test-galaxy-warp-bends-rather-than-tilts ()
  "The warp BENDS the disc; it is not a rigid tilt of the plane.

This is the trap the first implementation fell into, and it is invisible
in the code: with height = r*tan(t)*sin(a) and the in-plane coordinate
v = r*sin(a), the height is exactly tan(t)*v -- a PLANE.  Every node
moves, nothing bends, and orbiting reveals the flat disc the warp
existed to get rid of.

The signature of a plane is that the ratio of height to radius is the
SAME at every radius.  A real warp turns up toward the rim, so the outer
band must be steeper than the inner one."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-galaxy-tilt))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (cmacs-secondbrain-tests--ring-nodes 200)))
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      (cmacs-secondbrain-set-galaxy-tilt buf 32 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (cl-labels ((steepness (ring)
                    ;; max |height| / radius over one ring: tan(t) at
                    ;; every radius if the disc is a plane.
                    (let ((best 0.0))
                      (dolist (n (append nodes nil) best)
                        (when (eq (plist-get n :ring) ring)
                          (let* ((p (cmacs-secondbrain-node-position
                                     buf (plist-get n :id)))
                                 (r (sqrt (+ (* (nth 0 p) (nth 0 p))
                                             (* (nth 2 p) (nth 2 p))))))
                            (when (> r 0.5)
                              (setq best (max best (/ (abs (nth 1 p)) r))))))))))
        (let ((inner (steepness 'skills))
              (outer (steepness 'applications)))
          (should (> inner 0.0))
          (should (> outer 0.0))
          ;; Comfortably more than measurement noise, and impossible for
          ;; a plane, where the two are equal by construction.
          (should (> outer (* 1.5 inner))))))))

(ert-deftest cmacs-secondbrain-test-fit-centres-a-ring-layout-on-the-origin ()
  "Framing a ring layout aims at the origin, not at the bounding box.

They are not the same point.  A department\='s members fan outward from
wherever its wedge happens to be and the outermost ring may hold four
nodes at four arbitrary angles, so the box is lopsided -- and framing it
slides the concentric structure the whole map is built around off into a
corner of its own cloud."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-camera-state))
  (cmacs-secondbrain-tests--with-view buf
    ;; Deliberately lopsided: one heavy department and one stray node far
    ;; out on the rim.
    (let ((nodes (vconcat
                  (vector (list :id "hub" :title "hub" :kind 'hub
                                :ring 'memory)
                          (list :id "stray" :title "s" :kind 'app
                                :ring 'applications))
                  (cl-loop for i below 300
                           collect (list :id (format "m%d" i) :title ""
                                         :kind 'file :parent "hub"
                                         :ring 'memory)))))
      (cmacs-secondbrain-set-graph buf nodes (vector) 3)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (cmacs-secondbrain-fit buf)
      (let ((target (plist-get (cmacs-libregnum-camera-state buf) :target)))
        (should target)
        (dotimes (i 3)
          (should (< (abs (nth i target)) 0.001)))))))

(ert-deftest cmacs-secondbrain-test-3d-layout-is-in-the-ground-plane ()
  "In 3D the disc lies in XZ, with height on Y; in 2D it lies in XY.

This is not cosmetic bookkeeping, it is the fix for a map that came up
as a flat streak you could not turn.  The renderer\='s world is Y-up and
so is its orbit camera, whose two drag gestures are azimuth about Y and
elevation from the XZ plane.  Lay the disc in XY instead and neither
gesture means anything sensible: the elevation drag walks the camera
along the disc\='s OWN plane until it jams against the pole clamp
edge-on, so the galaxy presents as a line and the drag appears to stop
for no reason the picture explains.

Asserted as extents rather than as one node\='s coordinates, because that
is the actual claim -- the whole disc is wide in two axes and thin in
the third."
  (cmacs-secondbrain-tests--skip)
  (cmacs-secondbrain-tests--with-view buf
    (let* ((nodes (cmacs-secondbrain-tests--ring-nodes 40))
           (extent
            (lambda (axis)
              (let ((vals (mapcar
                           (lambda (n)
                             (nth axis (cmacs-secondbrain-node-position
                                        buf (plist-get n :id))))
                           nodes)))
                (- (apply #'max vals) (apply #'min vals))))))
      ;; 3D: wide in X and Z, thin in Y.
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      (cmacs-secondbrain-set-galaxy-tilt buf 32 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (> (funcall extent 0) 1.0))
      (should (> (funcall extent 2) 1.0))
      (should (< (funcall extent 1) (funcall extent 0)))
      (should (< (funcall extent 1) (funcall extent 2)))
      ;; ... and thin does not mean flat: the warp is what makes the
      ;; third dimension worth having.
      (should (> (funcall extent 1) 1.0))
      ;; 2D: wide in X and Y, exactly zero in Z.
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 2)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (> (funcall extent 0) 1.0))
      (should (> (funcall extent 1) 1.0))
      (should (= 0.0 (funcall extent 2))))))

(ert-deftest cmacs-secondbrain-test-galaxy-tilt-lifts-the-rings ()
  "In 3D the rings warp out of the plane; at tilt 0 they stay coplanar.

The point of the feature: concentric rings viewed in 3D are coplanar,
so orbiting them only proves they are flat."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-galaxy-tilt))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (cmacs-secondbrain-tests--ring-nodes 40)))
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      ;; Flat: every z is exactly zero.
      (cmacs-secondbrain-set-galaxy-tilt buf 0 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (cl-every #'zerop (cmacs-secondbrain-tests--zs buf nodes)))
      ;; Warped: heights spread out, and they are not all the same.
      (cmacs-secondbrain-set-galaxy-tilt buf 24 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (let ((zs (cmacs-secondbrain-tests--zs buf nodes)))
        (should (> (apply #'max (mapcar #'abs zs)) 1.0))
        ;; Both signs: the warp lifts one side and drops the other, which
        ;; is what makes it a warp rather than a cone.
        (should (cl-some (lambda (z) (> z 0.5)) zs))
        (should (cl-some (lambda (z) (< z -0.5)) zs))))))

(ert-deftest cmacs-secondbrain-test-galaxy-tilt-respects-the-angle ()
  "The warp reaches about the requested elevation, and no more.

Asserts a BOUND, not an exact value: the per-node thickness rides on top
of the warp crest, so a node may sit beyond the angle.  The bound is not
a guess -- both terms scale with the same r*tan(TILT), so the ceiling is
exactly atan(1.34 * tan TILT), which for 24 degrees is 30.7."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-galaxy-tilt))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (cmacs-secondbrain-tests--ring-nodes 40)))
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      (cmacs-secondbrain-set-galaxy-tilt buf 24 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (let ((elevations
             (delq nil
                   (mapcar
                    (lambda (n)
                      ;; In 3D the disc is in XZ and the height is Y.
                      (let* ((p (cmacs-secondbrain-node-position
                                 buf (plist-get n :id)))
                             (r (sqrt (+ (* (nth 0 p) (nth 0 p))
                                         (* (nth 2 p) (nth 2 p))))))
                        (and (> r 0.01)
                             (radians-to-degrees
                              (atan (abs (nth 1 p)) r)))))
                    nodes))))
        (should elevations)
        ;; It actually gets up there ...
        (should (> (apply #'max elevations) 18.0))
        ;; ... and does not run away past the stated ceiling.
        (should (< (apply #'max elevations)
                   (radians-to-degrees
                    (atan (* 1.34 (tan (degrees-to-radians 24.0)))))))))))

(ert-deftest cmacs-secondbrain-test-galaxy-tilt-is-inert-in-2d ()
  "The flat view stays flat however the tilt is set.

`place_set\=' zeroes z for a 2D layout, which is what lets one setting be
correct in both views instead of the caller branching on the view --
and branching is how a toggle back to 2D ends up with a bent map."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-galaxy-tilt))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (cmacs-secondbrain-tests--ring-nodes 24)))
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 2)
      (cmacs-secondbrain-set-galaxy-tilt buf 30 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (cl-every #'zerop (cmacs-secondbrain-tests--zs buf nodes))))))

(ert-deftest cmacs-secondbrain-test-galaxy-tilt-is-deterministic ()
  "The same graph warps the same way every time it is rebuilt.

The per-node thickness is hashed from the node ID rather than its
index precisely for this: index order churns on every rebuild, so
hashing it would reshuffle every height on refresh and the map would
twitch for no reason."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-galaxy-tilt))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (cmacs-secondbrain-tests--ring-nodes 24)) first)
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      (cmacs-secondbrain-set-galaxy-tilt buf 24 0)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (setq first (cmacs-secondbrain-tests--zs buf nodes))
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (equal first (cmacs-secondbrain-tests--zs buf nodes))))))

(ert-deftest cmacs-secondbrain-test-galaxy-tilt-is-rings-only ()
  "Only the rings layout warps; the other closed-form ones stay flat.

Scope worth pinning: the warp is a property of a RING layout -- a hex
lattice bent along an azimuth it does not have would just be crooked."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain-set-galaxy-tilt))
  (cmacs-secondbrain-tests--with-view buf
    (let ((nodes (cmacs-secondbrain-tests--ring-nodes 24)))
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vector) 3)
      (cmacs-secondbrain-set-galaxy-tilt buf 24 0)
      (dolist (kind '(circle hex))
        (cmacs-secondbrain-set-layout buf kind 0)
        (should (cl-every #'zerop (cmacs-secondbrain-tests--zs buf nodes))))
      ;; ... and rings still does.
      (cmacs-secondbrain-set-layout buf 'rings 0)
      (should (cl-some (lambda (z) (> (abs z) 1.0))
                       (cmacs-secondbrain-tests--zs buf nodes))))))

(ert-deftest cmacs-secondbrain-test-animation-stops-when-unseen ()
  "The animation clock disarms itself when no window shows the buffer.

The hang this guards against: a tick renders the whole scene
synchronously, and Emacs runs timers whenever it WAITS -- including
inside `accept-process-output\=' during startup.  A clock left running
for an invisible buffer therefore renders on top of whatever Emacs is
trying to do, indefinitely.  A selected node with the link pulse on
kept it alive forever, which is exactly the state that wedged a
session."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain--animate))
  (cmacs-secondbrain-tests--with-view buf
    (with-current-buffer buf
      (cmacs-secondbrain-mode)
      (setq cmacs-secondbrain--graph
            (list :nodes (list (list :id "a" :title "A" :kind 'file
                                     :ring 'memory))
                  :edges nil))
      (cmacs-secondbrain-set-graph
       buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory))
       (vector) 2)
      ;; The state that used to run forever: a selection, pulse on.
      (setq cmacs-secondbrain--selected "a"
            cmacs-secondbrain-link-pulse t)
      (cmacs-secondbrain--animate)
      (should (timerp cmacs-secondbrain--anim-timer))
      ;; Nothing displays this buffer, so one tick must shut it down --
      ;; even though the pulse would otherwise keep it alive.
      (should (cmacs-secondbrain--wants-animation-p))
      (funcall (timer--function cmacs-secondbrain--anim-timer))
      (should-not (timerp cmacs-secondbrain--anim-timer)))))

(ert-deftest cmacs-secondbrain-test-wants-animation-covers-each-reason ()
  "Each thing with no end state keeps the clock, and nothing else does."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-secondbrain--wants-animation-p))
  (cmacs-secondbrain-tests--with-view buf
    (with-current-buffer buf
      (cmacs-secondbrain-mode)
      (cmacs-secondbrain-set-graph
       buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory))
       (vector) 2)
      (let ((cmacs-secondbrain-auto-rotate 0.0)
            (cmacs-secondbrain-link-pulse nil))
        (setq cmacs-secondbrain--selected nil)
        (should-not (cmacs-secondbrain--wants-animation-p))
        ;; A selection alone is not enough -- the pulse has to be on.
        (setq cmacs-secondbrain--selected "a")
        (should-not (cmacs-secondbrain--wants-animation-p)))
      (let ((cmacs-secondbrain-link-pulse t))
        (setq cmacs-secondbrain--selected "a")
        (should (cmacs-secondbrain--wants-animation-p)))
      (let ((cmacs-secondbrain-auto-rotate 3.0)
            (cmacs-secondbrain-link-pulse nil))
        (setq cmacs-secondbrain--selected nil)
        (should (cmacs-secondbrain--wants-animation-p))))))

(ert-deftest cmacs-secondbrain-test-render-is-not-frame-paced ()
  "A render must not pay a windowed present.

The offscreen path renders into an FBO and reads it back; it must not
go through the renderer\'s FRAME bracket, which presents and PACES the
hidden shared window -- raylib\'s EndDrawing sleeps in WaitTime to hold
the 60 FPS cap.  That put a hard 16.7 ms floor under every redraw, so a
30 ms animation timer spent most of the main thread asleep and the
session stopped responding.

A trivial scene is the probe: it has no real work to do, so anything
near a frame period is the cap rather than the drawing."
  (cmacs-secondbrain-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-mean-color))
  (cmacs-secondbrain-tests--with-view buf
    (cmacs-secondbrain-set-graph
     buf (vector (list :id "a" :title "A" :kind 'file :ring 'memory)
                 (list :id "b" :title "B" :kind 'file :ring 'skills))
     (vector) 3)
    (cmacs-secondbrain-set-layout buf 'rings 0)
    (cmacs-secondbrain-fit buf)
    (cmacs-libregnum-mean-color buf)    ; warm up
    (let* ((n 20)
           (t0 (float-time))
           (_ (dotimes (_ n) (cmacs-libregnum-mean-color buf)))
           (ms (/ (* 1000.0 (- (float-time) t0)) n)))
      ;; Measured 16.66 ms/frame with the frame bracket and 0.70 without,
      ;; so 8 ms separates the two by a wide margin either way and does
      ;; not make the test a benchmark of the GPU.
      (should (< ms 8.0)))))

(provide 'cmacs-secondbrain-tests)

;;; cmacs-secondbrain-tests.el ends here
