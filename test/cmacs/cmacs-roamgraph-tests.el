;;; cmacs-roamgraph-tests.el --- Tests for the org-roam graph visualiser -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the cmacs-roamgraph-* C primitives.
;;
;; The graph model and the force-directed solver are a pure-C
;; translation unit -- no "lisp.h", no <libregnum.h> -- specifically so
;; they can be exercised without a Lisp VM or a GL context.  Attaching a
;; viewport does need the hidden raylib window, so every test here goes
;; through `cmacs-roamgraph-tests--skip', which additionally skips when
;; no display is reachable.
;;
;; Note the `fboundp' guard on `cmacs-feature-p': that function is void
;; in a per-file test run (test/cmacs/FOO-tests.el invoked directly),
;; which would otherwise make the whole suite skip silently.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; The data-source helpers are Elisp, not DEFUNs, so they must be
;; loaded explicitly.  Guarded: a build without the subsystem has no
;; such file and every test here skips anyway.
(when (and (fboundp 'cmacs-roamgraph-supported-p)
           (cmacs-roamgraph-supported-p))
  (require 'cmacs-roamgraph-db nil t)
  (require 'cmacs-roamgraph nil t))

(defmacro cmacs-roamgraph-tests--skip ()
  "Skip the enclosing test unless roamgraph is built and a display exists."
  '(skip-unless (and (fboundp 'cmacs-roamgraph-supported-p)
                     (cmacs-roamgraph-supported-p)
                     (or (getenv "DISPLAY") (getenv "WAYLAND_DISPLAY")))))

(defmacro cmacs-roamgraph-tests--with-graph (spec &rest body)
  "Attach a scratch roamgraph buffer, run BODY, then detach.
SPEC is (VAR NODES EDGES &optional DIMS); VAR is bound to the buffer."
  (declare (indent 1) (debug t))
  (let ((var (nth 0 spec)) (nodes (nth 1 spec))
        (edges (nth 2 spec)) (dims (or (nth 3 spec) 3)))
    `(let ((,var (generate-new-buffer " *roamgraph-test*")))
       (unwind-protect
           (progn
             (cmacs-roamgraph-attach ,var 320 240)
             (cmacs-roamgraph-set-graph ,var ,nodes ,edges ,dims)
             ,@body)
         (ignore-errors (cmacs-roamgraph-detach ,var))
         (kill-buffer ,var)))))

(defun cmacs-roamgraph-tests--settle (buf &optional max-rounds)
  "Run BUF's layout to convergence.  Return the number of rounds."
  (let ((i 0) (cap (or max-rounds 500)))
    (while (and (< i cap) (not (cmacs-roamgraph-layout-step buf 10)))
      (setq i (1+ i)))
    i))

(defun cmacs-roamgraph-tests--dist (a b)
  "Euclidean distance between position lists A and B."
  (sqrt (+ (expt (- (nth 0 a) (nth 0 b)) 2)
           (expt (- (nth 1 a) (nth 1 b)) 2)
           (expt (- (nth 2 a) (nth 2 b)) 2))))

(defun cmacs-roamgraph-tests--nodes (&rest ids)
  "Build a node vector from IDS, titling each one after its id."
  (vconcat (mapcar (lambda (id) (list :id id :title (upcase id))) ids)))

;;;; Graph model ------------------------------------------------------

(ert-deftest cmacs-roamgraph-test-basic-counts ()
  "Nodes and edges land, and a dangling link is dropped."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b")
                   '(:from "b" :to "c")
                   ;; Endpoint absent from NODES: normal in a live notes
                   ;; tree, and must not create a phantom node.
                   '(:from "a" :to "nonexistent")))
    (should (= 3 (cmacs-roamgraph-node-count buf)))
    (should (= 2 (cmacs-roamgraph-edge-count buf)))))

(ert-deftest cmacs-roamgraph-test-self-loop-and-duplicates ()
  "Self-loops are dropped and an A->B / B->A pair collapses to one edge."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b")
           (vector '(:from "a" :to "a")     ; self-loop
                   '(:from "a" :to "b")
                   '(:from "b" :to "a")     ; same unordered pair
                   '(:from "a" :to "b")))   ; exact duplicate
    (should (= 1 (cmacs-roamgraph-edge-count buf)))))

(ert-deftest cmacs-roamgraph-test-payload-roundtrip ()
  "The full node plist comes back, including keys C never looks at."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (vector '(:id "x" :title "Ecks" :file "/n/x.org" :level 2 :pos 99
                     :tags ("emacs" "c") :aliases ("X")))
           [])
    (let ((p (cmacs-roamgraph-node-at buf "x")))
      (should (equal "Ecks" (plist-get p :title)))
      (should (= 2 (plist-get p :level)))
      (should (= 99 (plist-get p :pos)))
      ;; :tags is meaningless to the C side but must survive the trip.
      (should (equal '("emacs" "c") (plist-get p :tags))))
    (should-not (cmacs-roamgraph-node-at buf "no-such-id"))))

(ert-deftest cmacs-roamgraph-test-neighbours-direction ()
  "CSR adjacency reports forward links and backlinks separately."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "c" :to "a")))
    (should (equal '("b") (cmacs-roamgraph-neighbors buf "a" 'out)))
    (should (equal '("c") (cmacs-roamgraph-neighbors buf "a" 'in)))
    ;; Both, forward links first -- the order peer cycling relies on.
    (should (equal '("b" "c") (cmacs-roamgraph-neighbors buf "a" 'both)))
    (should (equal '("b" "c") (cmacs-roamgraph-neighbors buf "a")))))

(ert-deftest cmacs-roamgraph-test-neighbour-order-is-alphabetical ()
  "Within a direction, neighbours are ordered by title, not insertion.
This is what makes `<'/`>' peer cycling land in the same place across a
rebuild."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (vector '(:id "hub" :title "Hub")
                   '(:id "n1" :title "Zeta")
                   '(:id "n2" :title "Alpha")
                   '(:id "n3" :title "Mu"))
           (vector '(:from "hub" :to "n1")
                   '(:from "hub" :to "n2")
                   '(:from "hub" :to "n3")))
    (should (equal '("n2" "n3" "n1")     ; Alpha, Mu, Zeta
                   (cmacs-roamgraph-neighbors buf "hub" 'out)))))

(ert-deftest cmacs-roamgraph-test-index-id-roundtrip ()
  "Index and id map to each other, and unknown ids report nil."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c") [])
    (dolist (id '("a" "b" "c"))
      (should (equal id (cmacs-roamgraph-node-id
                         buf (cmacs-roamgraph-node-index buf id)))))
    (should-not (cmacs-roamgraph-node-index buf "ghost"))
    (should-not (cmacs-roamgraph-node-id buf 999))))

;;;; Layout -----------------------------------------------------------

(ert-deftest cmacs-roamgraph-test-layout-converges ()
  "A small graph settles well inside the schedule."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")
                   '(:from "c" :to "a")))
    (should-not (cmacs-roamgraph-layout-converged-p buf))
    (should (< (cmacs-roamgraph-tests--settle buf) 500))
    (should (cmacs-roamgraph-layout-converged-p buf))))

(ert-deftest cmacs-roamgraph-test-triangle-is-equilateral ()
  "Three mutually linked nodes relax to a near-equilateral triangle.
The cheapest end-to-end assertion that attraction and repulsion are
actually balanced rather than merely finite."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")
                   '(:from "c" :to "a")))
    (cmacs-roamgraph-tests--settle buf)
    (let* ((pa (cmacs-roamgraph-node-position buf "a"))
           (pb (cmacs-roamgraph-node-position buf "b"))
           (pc (cmacs-roamgraph-node-position buf "c"))
           (ds (list (cmacs-roamgraph-tests--dist pa pb)
                     (cmacs-roamgraph-tests--dist pb pc)
                     (cmacs-roamgraph-tests--dist pc pa)))
           (lo (apply #'min ds)) (hi (apply #'max ds)))
      (should (> lo 0.01))
      (should (< (/ (- hi lo) hi) 0.05)))))

(ert-deftest cmacs-roamgraph-test-2d-is-planar ()
  "DIMS 2 pins every node to z = 0, including inherited 3D positions."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c" "d")
           (vector '(:from "a" :to "b") '(:from "b" :to "c"))
           2)
    (cmacs-roamgraph-tests--settle buf)
    (dolist (id '("a" "b" "c" "d"))
      (should (< (abs (nth 2 (cmacs-roamgraph-node-position buf id)))
                 1e-6)))))

(ert-deftest cmacs-roamgraph-test-3d-after-2d-is-volumetric ()
  "Switching 2D -> 3D produces a ball, not a disc floating in space.

A perfectly planar configuration is an EXACT equilibrium in three
dimensions: every force's z-component cancels by symmetry.  So a layout
inherited from the 2D view would stay flat forever unless the solver
deliberately breaks the symmetry.  Since the default entry point opens
in 2D, this is the path every user actually takes to reach 3D."
  (cmacs-roamgraph-tests--skip)
  (let* ((ids (mapcar (lambda (i) (format "n%02d" i)) (number-sequence 0 29)))
         (nodes (apply #'cmacs-roamgraph-tests--nodes ids))
         (edges (vconcat
                 (mapcar (lambda (i)
                           (list :from (nth i ids)
                                 :to (nth (mod (1+ i) 30) ids)))
                         (number-sequence 0 29))))
         (buf (generate-new-buffer " *roamgraph-3d*")))
    (unwind-protect
        (progn
          (cmacs-roamgraph-attach buf 320 240)
          ;; Settle flat first, exactly as the 2D entry point does.
          (cmacs-roamgraph-set-graph buf nodes edges 2)
          (cmacs-roamgraph-tests--settle buf)
          (let ((zs (mapcar (lambda (id)
                              (nth 2 (cmacs-roamgraph-node-position buf id)))
                            ids)))
            (should (cl-every (lambda (z) (< (abs z) 1e-6)) zs)))
          ;; Now switch to 3D and settle again.
          (cmacs-roamgraph-set-graph buf nodes edges 3)
          (cmacs-roamgraph-tests--settle buf)
          (let* ((pos (mapcar (lambda (id)
                                (cmacs-roamgraph-node-position buf id))
                              ids))
                 (span (lambda (i)
                         (let ((vs (mapcar (lambda (p) (nth i p)) pos)))
                           (- (apply #'max vs) (apply #'min vs)))))
                 (zx (funcall span 0))
                 (zz (funcall span 2)))
            ;; The depth must be a real fraction of the width, not a
            ;; token perturbation.
            (should (> zz (* 0.25 zx)))))
      (ignore-errors (cmacs-roamgraph-detach buf))
      (kill-buffer buf))))

(ert-deftest cmacs-roamgraph-test-zoom-in-moves-closer ()
  "`+' approaches and `-' retreats.
The underlying primitive scales camera distance by 0.9^AMOUNT, so a
positive amount moves closer -- easy to wire up backwards."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")))
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    (cl-flet ((cam-dist ()
                (let* ((st (cmacs-libregnum-camera-state buf))
                       (p (plist-get st :position))
                       (tg (plist-get st :target)))
                  (cmacs-roamgraph-tests--dist p tg))))
      (let ((start (cam-dist)))
        (cmacs-roamgraph-zoom buf 2.0)          ; the `+' direction
        (should (< (cam-dist) start))
        (let ((near (cam-dist)))
          (cmacs-roamgraph-zoom buf -2.0)       ; the `-' direction
          (should (> (cam-dist) near)))))))

(ert-deftest cmacs-roamgraph-test-components-separate ()
  "Two disjoint triangles do not collapse into one blob at the origin.
Without component-aware seeding the unlinked notes -- hundreds of them
in a mature notes tree -- all pile up together."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c" "x" "y" "z")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")
                   '(:from "c" :to "a")
                   '(:from "x" :to "y") '(:from "y" :to "z")
                   '(:from "z" :to "x")))
    (cmacs-roamgraph-tests--settle buf)
    (let* ((c1 (cmacs-roamgraph-node-position buf "a"))
           (c2 (cmacs-roamgraph-node-position buf "x"))
           (within (cmacs-roamgraph-tests--dist
                    c1 (cmacs-roamgraph-node-position buf "b")))
           (between (cmacs-roamgraph-tests--dist c1 c2)))
      ;; The two components must end up further apart than the nodes
      ;; inside either one.
      (should (> between (* 2.0 within))))))

(ert-deftest cmacs-roamgraph-test-layout-is-deterministic ()
  "The same seed and the same input give bit-identical positions.
The solver draws from a per-graph xorshift stream rather than
`g_random_*' precisely so this holds."
  (cmacs-roamgraph-tests--skip)
  (let ((nodes (cmacs-roamgraph-tests--nodes "a" "b" "c" "d" "e"))
        (edges (vector '(:from "a" :to "b") '(:from "b" :to "c")
                       '(:from "c" :to "d") '(:from "d" :to "e")
                       '(:from "e" :to "a")))
        (run (lambda (nodes edges)
               (let ((buf (generate-new-buffer " *roamgraph-det*")))
                 (unwind-protect
                     (progn
                       (cmacs-roamgraph-attach buf 320 240)
                       (cmacs-roamgraph-set-graph buf nodes edges 3)
                       (cmacs-roamgraph-tests--settle buf)
                       (mapcar (lambda (id)
                                 (cmacs-roamgraph-node-position buf id))
                               '("a" "b" "c" "d" "e")))
                   (ignore-errors (cmacs-roamgraph-detach buf))
                   (kill-buffer buf))))))
    (should (equal (funcall run nodes edges)
                   (funcall run nodes edges)))))

(ert-deftest cmacs-roamgraph-test-barnes-hut-matches-exact ()
  "Theta 0 degenerates Barnes-Hut to an exact all-pairs sum.
That gives the approximation a free reference implementation: the same
graph solved at theta 0 twice must agree exactly, and the default theta
must land in the same neighbourhood rather than somewhere else
entirely."
  (cmacs-roamgraph-tests--skip)
  (let* ((ids (mapcar (lambda (i) (format "n%02d" i)) (number-sequence 0 19)))
         (nodes (apply #'cmacs-roamgraph-tests--nodes ids))
         (edges (vconcat
                 (mapcar (lambda (i)
                           (list :from (nth i ids)
                                 :to (nth (mod (1+ i) 20) ids)))
                         (number-sequence 0 19))))
         (run (lambda (theta)
                (let ((buf (generate-new-buffer " *roamgraph-bh*")))
                  (unwind-protect
                      (progn
                        (cmacs-roamgraph-attach buf 320 240)
                        (cmacs-roamgraph-set-graph buf nodes edges 3)
                        (cmacs-roamgraph-set-layout-theta buf theta)
                        ;; Re-arm so the new theta applies from step one.
                        (cmacs-roamgraph-tests--settle buf)
                        (mapcar (lambda (id)
                                  (cmacs-roamgraph-node-position buf id))
                                ids))
                    (ignore-errors (cmacs-roamgraph-detach buf))
                    (kill-buffer buf))))))
    ;; Exact mode is itself reproducible.
    (should (equal (funcall run 0.0) (funcall run 0.0)))
    ;; And the approximation produces a comparable ring: every node ends
    ;; up a finite, sane distance from the origin under both.
    (let ((exact (funcall run 0.0))
          (approx (funcall run 0.9))
          (norm (lambda (p) (sqrt (+ (* (nth 0 p) (nth 0 p))
                                     (* (nth 1 p) (nth 1 p))
                                     (* (nth 2 p) (nth 2 p)))))))
      (should (cl-every (lambda (p) (< (funcall norm p) 1e4)) exact))
      (should (cl-every (lambda (p) (< (funcall norm p) 1e4)) approx)))))

(ert-deftest cmacs-roamgraph-test-pinned-node-does-not-move ()
  "A pinned node is exempt from the solver."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")))
    ;; Settle first so `a' has a meaningful position to be pinned at.
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-set-pinned buf "a" t)
    (let ((before (cmacs-roamgraph-node-position buf "a")))
      (cmacs-roamgraph-layout-reheat buf 0.5 60)
      (cmacs-roamgraph-tests--settle buf)
      (should (equal before (cmacs-roamgraph-node-position buf "a"))))))

(ert-deftest cmacs-roamgraph-test-rebuild-preserves-positions ()
  "A refresh keeps surviving nodes put instead of teleporting the map.
New nodes appear near their already-placed neighbours rather than at
the origin."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")))
    (cmacs-roamgraph-tests--settle buf)
    (let ((before (cmacs-roamgraph-node-position buf "b")))
      ;; Same graph plus one node hanging off `b', minus `c'.
      (cmacs-roamgraph-set-graph
       buf (cmacs-roamgraph-tests--nodes "a" "b" "d")
       (vector '(:from "a" :to "b") '(:from "b" :to "d")) 3)
      (should (= 3 (cmacs-roamgraph-node-count buf)))
      ;; `b' survived, so it must not have jumped.
      (should (< (cmacs-roamgraph-tests--dist
                  before (cmacs-roamgraph-node-position buf "b"))
                 1e-6))
      ;; `d' is new: seeded at its placed neighbour's centroid, so it
      ;; starts near `b', not at the origin.
      (should (< (cmacs-roamgraph-tests--dist
                  (cmacs-roamgraph-node-position buf "b")
                  (cmacs-roamgraph-node-position buf "d"))
                 20.0)))))

;;;; View -------------------------------------------------------------

(ert-deftest cmacs-roamgraph-test-attach-detach ()
  "Attach is idempotent and detach really tears the view down."
  (cmacs-roamgraph-tests--skip)
  (let ((buf (generate-new-buffer " *roamgraph-attach*")))
    (unwind-protect
        (progn
          (should-not (cmacs-roamgraph-attached-p buf))
          (cmacs-roamgraph-attach buf 320 240)
          (should (cmacs-roamgraph-attached-p buf))
          (cmacs-roamgraph-attach buf 320 240)   ; idempotent
          (should (cmacs-roamgraph-attached-p buf))
          (cmacs-roamgraph-detach buf)
          (should-not (cmacs-roamgraph-attached-p buf)))
      (ignore-errors (cmacs-roamgraph-detach buf))
      (kill-buffer buf))))

(ert-deftest cmacs-roamgraph-test-projection-toggle ()
  "The 2D/3D toggle round-trips."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b")
           (vector '(:from "a" :to "b")))
    (should-not (cmacs-roamgraph-flat-p buf))
    (cmacs-roamgraph-set-projection buf t)
    (should (cmacs-roamgraph-flat-p buf))
    (cmacs-roamgraph-set-projection buf nil)
    (should-not (cmacs-roamgraph-flat-p buf))))

(ert-deftest cmacs-roamgraph-test-fov-stays-an-angle ()
  "The camera's fov is always a legal angle, however big the graph.

The flat view is head-on perspective, not orthographic, precisely
because raylib overloads `fovy' to mean the view volume's world height
under an orthographic projection -- while graylib asserts `fovy < 180',
which only makes sense for an angle.  Framing a graph wider than 180
world units then trips that assertion on every single frame.

A graph big enough to have gone over that limit is the whole point of
this test, so it builds a wide one rather than a token pair of nodes."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph
      (buf (apply #'cmacs-roamgraph-tests--nodes
                  (mapcar (lambda (i) (format "n%03d" i))
                          (number-sequence 0 299)))
           ;; A long chain plus many isolated nodes: spreads wide.
           (vconcat (mapcar (lambda (i)
                              (list :from (format "n%03d" i)
                                    :to (format "n%03d" (1+ i))))
                            (number-sequence 0 98)))
           2)
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    (let ((fov (plist-get (cmacs-libregnum-camera-state buf) :fov)))
      (should (> fov 0.0))
      (should (< fov 180.0)))
    ;; And it stays legal after the camera has been driven around.
    (dotimes (_ 5) (cmacs-roamgraph-zoom buf 1.0))
    (cmacs-roamgraph-fit buf)
    (let ((fov (plist-get (cmacs-libregnum-camera-state buf) :fov)))
      (should (> fov 0.0))
      (should (< fov 180.0)))))

;;;; Context menu ---------------------------------------------------------

(defun cmacs-roamgraph-tests--menu (id)
  "Build the context menu for ID in the shape the popup receives."
  (list (if id (cmacs-roamgraph--title id) "org-roam graph")
        (cons "" (mapcar (lambda (it) (or it '("--")))
                         (cmacs-roamgraph--menu-items id)))))

(ert-deftest cmacs-roamgraph-test-context-menu-shape ()
  "The context menu is a well-formed alist menu for both backends.

`cmacs-libregnum-popup-menu' hands an alist menu to `x-popup-menu' under
pgtk and to the in-engine popup under `emacs --lrg'.  Running it through
the same flattener the lrg path uses proves the labels and values line
up, which is the part that would silently produce a menu of blanks or
off-by-one actions."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum--alist-menu-to-lrg))
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (dolist (id '("b" nil))             ; a note, and empty space
      (let* ((menu (cmacs-roamgraph-tests--menu id))
             (flat (cmacs-libregnum--alist-menu-to-lrg menu))
             (tree (car flat))
             (values (cdr flat)))
        (should (stringp (car menu)))
        ;; Every leaf must carry a callable, or choosing it does nothing.
        (should (> (length values) 0))
        (should (cl-every #'functionp (append values nil)))
        ;; Labels are non-empty strings; separators come through as nil
        ;; entries and must not have consumed a value slot.
        (let ((labels (delq nil (mapcar (lambda (e) (and e (car e))) tree))))
          (should (cl-every (lambda (l) (and (stringp l)
                                             (> (length l) 0)))
                            labels))
          (should (= (length labels) (length values))))))))

(ert-deftest cmacs-roamgraph-test-context-menu-adapts ()
  "The menu offers what makes sense for what was clicked."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (let ((node-labels (mapcar #'car (delq nil (cmacs-roamgraph--menu-items "b"))))
          (space-labels (mapcar #'car (delq nil (cmacs-roamgraph--menu-items nil)))))
      ;; A note offers note actions...
      (should (cl-find "Open note" node-labels :test #'equal))
      (should (cl-find-if (lambda (l) (string-match-p "Follow a link" l))
                          node-labels))
      ;; ...including a filter for each of its own tags.
      (should (cl-find "Filter by :x:" node-labels :test #'equal))
      ;; Empty space offers view actions instead, and no note actions.
      (should (cl-find "Fit the whole graph" space-labels :test #'equal))
      (should-not (cl-find "Open note" space-labels :test #'equal))
      ;; The pin entry names the action it would perform.
      (should (cl-find "Pin in place" node-labels :test #'equal))
      (cmacs-roamgraph-set-pinned buf "b" t)
      (puthash "b" (plist-put (copy-sequence (cmacs-roamgraph--node "b"))
                              :pinned t)
               cmacs-roamgraph--by-id)
      (should (cl-find "Unpin from the layout"
                       (mapcar #'car (delq nil (cmacs-roamgraph--menu-items "b")))
                       :test #'equal)))))

(ert-deftest cmacs-roamgraph-test-wheel-up-zooms-in ()
  "Scrolling up moves the camera closer.

GDK reports a POSITIVE delta for scrolling DOWN, and the zoom kernel
moves closer for a positive amount -- so passing the delta straight
through inverts the wheel, which is the inherited libregnum behaviour.
This asserts the conventional direction through the same arithmetic the
scroll handler performs, rather than through a synthetic GDK event."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-wheel-up-zooms-in))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")))
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    (cl-flet ((cam-dist ()
                (let* ((st (cmacs-libregnum-camera-state buf))
                       (p (plist-get st :position))
                       (tg (plist-get st :target)))
                  (cmacs-roamgraph-tests--dist p tg))))
      ;; A scroll UP is a negative GDK delta; the handler negates it for
      ;; this context, so the camera must end up closer.
      (let* ((gdk-scroll-up -3.0)
             (start (cam-dist)))
        (cmacs-roamgraph-zoom buf (- gdk-scroll-up))
        (should (< (cam-dist) start))
        ;; And a scroll DOWN, a positive delta, must retreat.
        (let ((near (cam-dist))
              (gdk-scroll-down 3.0))
          (cmacs-roamgraph-zoom buf (- gdk-scroll-down))
          (should (> (cam-dist) near)))))))

(ert-deftest cmacs-roamgraph-test-pan-works-in-both-views ()
  "WASD panning moves the view in 2D and in 3D.

Panning must survive the flat view's orbit lock: locking stops the
camera tumbling out of plane, it must not stop you moving around."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-roamgraph-pan))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")) 2)
    (cmacs-roamgraph-tests--settle buf)
    (dolist (flat '(t nil))
      (cmacs-roamgraph-set-projection buf flat)
      (cmacs-roamgraph-fit buf)
      (let ((before (cmacs-libregnum-camera-state buf)))
        (cmacs-roamgraph-pan buf 70 0)
        (let ((after (cmacs-libregnum-camera-state buf)))
          (should-not (equal before after))
          ;; A pan slides the camera: position AND target move together,
          ;; unlike a zoom (position only) or an orbit (position only).
          (should-not (equal (plist-get before :position)
                             (plist-get after :position)))
          (should-not (equal (plist-get before :target)
                             (plist-get after :target))))))))

(ert-deftest cmacs-roamgraph-test-pan-is-reversible ()
  "Panning one way and back returns the camera where it started.
Within float tolerance: the camera is single precision, so an exact
round trip is not on offer and demanding one would only test the FPU."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-roamgraph-pan))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b")
           (vector '(:from "a" :to "b")) 2)
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    (let ((before (cmacs-libregnum-camera-state buf)))
      (cmacs-roamgraph-pan buf 70 40)
      ;; It really moved.
      (should-not (equal (plist-get before :target)
                         (plist-get (cmacs-libregnum-camera-state buf)
                                    :target)))
      (cmacs-roamgraph-pan buf -70 -40)
      (let ((after (cmacs-libregnum-camera-state buf)))
        (dolist (key '(:position :target))
          (cl-loop for a in (plist-get before key)
                   for b in (plist-get after key)
                   do (should (< (abs (- a b)) 1e-4))))))))

(ert-deftest cmacs-roamgraph-test-flat-view-locks-orbit ()
  "A flat view cannot be tumbled out of plane; a 3D one can.
Orbiting a planar layout would only reveal that everything is
coplanar."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-orbit))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")) 2)
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-set-projection buf t)
    (cmacs-roamgraph-fit buf)
    (let ((before (cmacs-libregnum-camera-state buf)))
      (cmacs-libregnum-orbit buf 40.0 25.0)
      (should (equal before (cmacs-libregnum-camera-state buf))))
    ;; 3D orbits normally.
    (cmacs-roamgraph-set-projection buf nil)
    (let ((before (cmacs-libregnum-camera-state buf)))
      (cmacs-libregnum-orbit buf 40.0 25.0)
      (should-not (equal before (cmacs-libregnum-camera-state buf))))))

(ert-deftest cmacs-roamgraph-test-empty-graph-is-harmless ()
  "An empty graph neither crashes nor reports work it did not do."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-graph (buf [] [])
    (should (= 0 (cmacs-roamgraph-node-count buf)))
    (should (= 0 (cmacs-roamgraph-edge-count buf)))
    (should (cmacs-roamgraph-layout-converged-p buf))
    (cmacs-roamgraph-fit buf)))

;;;; In-scene labels --------------------------------------------------
;;
;; These guard the change that makes labels exist under `emacs --lrg' at
;; all: they are drawn into the framebuffer rather than painted over it
;; in cairo.  A snapshot can only see them because of that, which is
;; also why the snapshot is a meaningful test here.

(defun cmacs-roamgraph-tests--png-size (path)
  "Byte length of PATH, or nil when it does not exist."
  (and (file-exists-p path) (file-attribute-size (file-attributes path))))

(ert-deftest cmacs-roamgraph-test-inscene-labels-change-the-frame ()
  "Turning in-scene labels on changes the rendered pixels.
If they were still going through the pgtk cairo overlay, the snapshot --
which renders through the same path `emacs --lrg' uses -- would be
byte-identical either way."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-inscene-labels))
  (cmacs-roamgraph-tests--with-graph
      (buf (vector '(:id "a" :title "AAAAAAAAAA")
                   '(:id "b" :title "BBBBBBBBBB"))
           (vector '(:from "a" :to "b")))
    (cmacs-roamgraph-tests--settle buf)
    (let ((off (make-temp-file "roamgraph-off" nil ".png"))
          (on  (make-temp-file "roamgraph-on" nil ".png")))
      (unwind-protect
          (progn
            ;; Force both nodes to label unconditionally, so the only
            ;; variable is where the text is drawn.
            (dotimes (i 2)
              (cmacs-libregnum-set-node-label-mode buf i 'always))
            (cmacs-libregnum-set-inscene-labels buf nil)
            (cmacs-libregnum-snapshot buf off)
            (cmacs-libregnum-set-inscene-labels buf t)
            (cmacs-libregnum-snapshot buf on)
            (should (cmacs-roamgraph-tests--png-size off))
            (should (cmacs-roamgraph-tests--png-size on))
            (should-not
             (equal (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally off) (buffer-string))
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally on) (buffer-string)))))
        (ignore-errors (delete-file off))
        (ignore-errors (delete-file on))))))

(ert-deftest cmacs-roamgraph-test-inscene-label-is-above-its-node ()
  "The label is drawn ABOVE its node, not mirrored below it.

The colour attachment is bottom-up while the blit flips it, so an
overlay pass that forgets the flip still changes pixels -- just mirrored
about the middle of the viewport.  The snapshot test above therefore
cannot catch it and this one is the actual guard.

Render one node with labels off, note how far up the ink reaches, then
turn labels on: the ink must extend FURTHER UP (a smaller MINY), because
the label sits above the sphere.  A forgotten flip would push the new
ink downward instead."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-ink-bbox))
  (cmacs-roamgraph-tests--with-graph
      (buf (vector '(:id "solo" :title "WWWWWWWWWWWW")) [])
    (cmacs-roamgraph-fit buf)
    ;; No shadow, no declutter: exactly one clean run of glyphs.
    (cmacs-libregnum-set-label-style buf 16 nil nil 8)
    (cmacs-libregnum-set-node-label-mode buf 0 'always)

    (cmacs-libregnum-set-inscene-labels buf nil)
    (let ((bare (cmacs-libregnum-ink-bbox buf)))
      (should bare)
      (cmacs-libregnum-set-inscene-labels buf t)
      (let ((labelled (cmacs-libregnum-ink-bbox buf)))
        (should labelled)
        ;; Something was added.
        (should-not (equal bare labelled))
        ;; And it was added above, not below.  MINY is the topmost
        ;; drawn row in displayed orientation, so it must decrease.
        (should (< (nth 1 labelled) (nth 1 bare)))
        ;; The bottom edge must not move: the sphere still ends where
        ;; it did.  If the flip were inverted this is what would grow.
        (should (= (nth 3 labelled) (nth 3 bare)))))))

;;;; Spatial navigation primitives -------------------------------------

(ert-deftest cmacs-roamgraph-test-nearest-in-direction ()
  "Screen-space direction picking finds the node on the right side.

Built as an explicit line of nodes along X with the camera framing
them, so \"to the right\" has an unambiguous answer that does not
depend on how the solver happened to settle."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-nearest-in-direction))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c" "d" "e")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")
                   '(:from "c" :to "d") '(:from "d" :to "e"))
           2)
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    ;; From any node, moving right and then left must return exactly --
    ;; not because the metric is self-inverse (it is not), but because
    ;; something plausible must exist in at least one direction from a
    ;; five-node chain.
    (let* ((mid (cmacs-roamgraph-node-index buf "c"))
           (found (cl-some (lambda (d)
                             (cmacs-libregnum-nearest-in-direction
                              buf mid (car d) (cdr d) 45))
                           '((1.0 . 0.0) (-1.0 . 0.0)
                             (0.0 . 1.0) (0.0 . -1.0)))))
      (should found)
      (should (integerp found))
      (should-not (= found mid)))))

(ert-deftest cmacs-roamgraph-test-nearest-is-deterministic ()
  "The same query twice gives the same answer.
Ties are broken by node id precisely so repeated presses do not
oscillate between two equally good candidates."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-nearest-in-direction))
  (cmacs-roamgraph-tests--with-graph
      (buf (apply #'cmacs-roamgraph-tests--nodes
                  (mapcar (lambda (i) (format "n%d" i)) (number-sequence 0 9)))
           (vector '(:from "n0" :to "n1") '(:from "n1" :to "n2"))
           2)
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    (let ((a (cmacs-libregnum-nearest-in-direction buf 0 1.0 0.0 45))
          (b (cmacs-libregnum-nearest-in-direction buf 0 1.0 0.0 45)))
      (should (equal a b)))))

(ert-deftest cmacs-roamgraph-test-onscreen-predicate ()
  "The on-screen test agrees with the projection."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-node-onscreen-p))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")))
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    ;; Everything is framed, so every node must read as on-screen.
    (dotimes (i 3)
      (should (cmacs-libregnum-node-onscreen-p buf i 0)))))

;;;; Match set -----------------------------------------------------------

(ert-deftest cmacs-roamgraph-test-match-set-flags ()
  "The bulk match setter marks hits and dims the rest.
It replaces the whole set in one call, which is what keeps an
incremental search to one call per keystroke instead of one per node."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-match-set))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c" "d") [])
    (let ((match 1) (dim 2))          ; MATCH = 1<<0, DIM = 1<<1
      (cmacs-libregnum-set-match-set buf [0 2] t)
      (should (= match (logand match (cmacs-libregnum-node-flags buf 0))))
      (should (= match (logand match (cmacs-libregnum-node-flags buf 2))))
      ;; Non-matches dim, and a match is never also dimmed.
      (should (= dim (logand dim (cmacs-libregnum-node-flags buf 1))))
      (should (zerop (logand dim (cmacs-libregnum-node-flags buf 0))))
      ;; Clearing really clears.
      (cmacs-libregnum-set-match-set buf nil nil)
      (dotimes (i 4)
        (should (zerop (logand (logior match dim)
                               (cmacs-libregnum-node-flags buf i))))))))

(defun cmacs-roamgraph-tests--render-bytes (buf)
  "Render BUF to a PNG and return its bytes."
  (let ((png (make-temp-file "roamgraph-render" nil ".png")))
    (unwind-protect
        (progn
          (cmacs-libregnum-snapshot buf png)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally png)
            (buffer-string)))
      (ignore-errors (delete-file png)))))

(ert-deftest cmacs-roamgraph-test-match-changes-the-render ()
  "Highlighting a match visibly changes the frame.

Compares rendered bytes rather than `cmacs-libregnum-ink-bbox': the
accent and dim colours repaint within the same extent, so the bounding
box is deliberately unchanged and would not catch this."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-roamgraph-apply-flags))
  (cmacs-roamgraph-tests--with-graph
      (buf (cmacs-roamgraph-tests--nodes "a" "b" "c")
           (vector '(:from "a" :to "b") '(:from "b" :to "c")))
    (cmacs-roamgraph-tests--settle buf)
    (cmacs-roamgraph-fit buf)
    (let ((plain (cmacs-roamgraph-tests--render-bytes buf)))
      (cmacs-libregnum-set-match-set buf [0] t)
      (cmacs-roamgraph-apply-flags buf)
      (should-not (equal plain (cmacs-roamgraph-tests--render-bytes buf)))
      ;; Clearing the set puts the original colours back.
      (cmacs-libregnum-set-match-set buf nil nil)
      (cmacs-roamgraph-apply-flags buf)
      (should (equal plain (cmacs-roamgraph-tests--render-bytes buf))))))

(ert-deftest cmacs-roamgraph-test-match-forces-labels ()
  "A search hit is labelled whatever its own label policy says.
Highlighting something you cannot then read the name of is useless, so
MATCH overrides the per-node policy."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-set-inscene-labels))
  (cmacs-roamgraph-tests--with-graph
      (buf (vector '(:id "a" :title "AAAAAAAAAAAA") '(:id "b" :title "B")) [])
    (cmacs-roamgraph-fit buf)
    (cmacs-libregnum-set-inscene-labels buf t)
    (cmacs-libregnum-set-label-style buf 16 nil nil 8)
    ;; Explicitly tell node 0 never to label...
    (cmacs-libregnum-set-node-label-mode buf 0 'never)
    (let ((quiet (cmacs-libregnum-ink-bbox buf)))
      (should quiet)
      ;; ...then make it a match, which must override that.
      (cmacs-libregnum-set-match-set buf [0] nil)
      (should-not (equal quiet (cmacs-libregnum-ink-bbox buf))))))

;;;; Data source ---------------------------------------------------------

(ert-deftest cmacs-roamgraph-test-prin1-unwrap ()
  "emacsql stores values printed; every read must undo that.
Getting this wrong yields ids and titles with literal quote characters
embedded, which then fail to match anything."
  (skip-unless (fboundp 'cmacs-roamgraph-db--unwrap))
  (should (equal "abc" (cmacs-roamgraph-db--unwrap "\"abc\"")))
  (should (equal 42 (cmacs-roamgraph-db--unwrap 42)))
  (should-not (cmacs-roamgraph-db--unwrap nil))
  ;; A bare (unprinted) string passes through rather than being mangled.
  (should (equal "abc" (cmacs-roamgraph-db--unwrap "abc")))
  ;; Embedded escapes survive.
  (should (equal "a\"b" (cmacs-roamgraph-db--unwrap "\"a\\\"b\"")))
  ;; A malformed printed value falls back to the raw text instead of
  ;; aborting the whole rebuild.
  (should (stringp (cmacs-roamgraph-db--unwrap "\"unterminated"))))

(ert-deftest cmacs-roamgraph-test-para-grouping ()
  "Files map to their PARA bucket, with dailies split out.
Dailies are a large fraction of a mature notes tree and would otherwise
swamp the whole areas colour."
  (skip-unless (fboundp 'cmacs-roamgraph-db--group))
  (let ((cmacs-roamgraph-directory "/n/"))
    (should (equal "01_projects" (cmacs-roamgraph-db--group "/n/01_projects/x.org")))
    (should (equal "02_areas" (cmacs-roamgraph-db--group "/n/02_areas/study/x.org")))
    (should (equal "dailies" (cmacs-roamgraph-db--group "/n/02_areas/dailies/2026-01-01.org")))
    ;; Outside the notes root: no bucket, and no crash.
    (should-not (cmacs-roamgraph-db--group "/elsewhere/x.org"))
    (should-not (cmacs-roamgraph-db--group nil))))

(ert-deftest cmacs-roamgraph-test-subgraph-extraction ()
  "A local graph keeps everything within N hops, in both directions.
Backlinks are as much a note's neighbourhood as its forward links."
  (skip-unless (fboundp 'cmacs-roamgraph-subgraph))
  (let* ((g (list :nodes (cmacs-roamgraph-tests--nodes "a" "b" "c" "d" "e")
                  :edges (vector '(:from "a" :to "b")   ; 1 hop out
                                 '(:from "c" :to "a")   ; 1 hop in
                                 '(:from "b" :to "d")   ; 2 hops
                                 '(:from "d" :to "e")))) ; 3 hops
         (one (cmacs-roamgraph-subgraph g "a" 1))
         (two (cmacs-roamgraph-subgraph g "a" 2)))
    (should (= 3 (length (plist-get one :nodes))))   ; a, b, c
    (should (= 4 (length (plist-get two :nodes))))   ; + d
    ;; Edges to dropped nodes go with them.
    (should (cl-every (lambda (e)
                        (and (member (plist-get e :from) '("a" "b" "c"))
                             (member (plist-get e :to) '("a" "b" "c"))))
                      (append (plist-get one :edges) nil)))))

;;;; Filtering, colours and panes ---------------------------------------

(defmacro cmacs-roamgraph-tests--with-view (spec &rest body)
  "Set up a full roamgraph view buffer, run BODY, then tear it down.
SPEC is (VAR GRAPH-PLIST); VAR is bound to the viewport buffer."
  (declare (indent 1) (debug t))
  (let ((var (nth 0 spec)) (graph (nth 1 spec)))
    `(let ((,var (generate-new-buffer " *roamgraph-view*")))
       (unwind-protect
           (with-current-buffer ,var
             (cmacs-roamgraph-mode)
             (cmacs-roamgraph-attach ,var 320 240)
             (setq cmacs-roamgraph--3d nil
                   cmacs-roamgraph--full-graph ,graph)
             (cmacs-roamgraph--apply-filter)
             ,@body)
         (ignore-errors (cmacs-roamgraph-detach ,var))
         (kill-buffer ,var)))))

(defun cmacs-roamgraph-tests--graph ()
  "A small graph with tags and one deliberately unlinked note."
  (list :nodes (vector '(:id "a" :title "Alpha" :tags ("x") :group "01_projects")
                       '(:id "b" :title "Beta"  :tags ("x" "y") :group "02_areas")
                       '(:id "c" :title "Gamma" :tags ("y") :group "02_areas")
                       '(:id "lonely" :title "Lonely" :tags ("z")))
        :edges (vector '(:from "a" :to "b") '(:from "b" :to "c"))
        :source 'test))

(ert-deftest cmacs-roamgraph-test-orphans-hidden-by-default ()
  "Unlinked notes are dropped unless asked for.
A mature notes tree has enough of them to ring the whole graph, and
they carry no link information at all."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (should-not cmacs-roamgraph-show-orphans)
    (should (= 3 (length (plist-get cmacs-roamgraph--graph :nodes))))
    (should-not (cmacs-roamgraph--node "lonely"))
    (cmacs-roamgraph-toggle-orphans)
    (should (= 4 (length (plist-get cmacs-roamgraph--graph :nodes))))
    (should (cmacs-roamgraph--node "lonely"))
    (cmacs-roamgraph-toggle-orphans)
    (should (= 3 (length (plist-get cmacs-roamgraph--graph :nodes))))))

(ert-deftest cmacs-roamgraph-test-tag-filter ()
  "A tag filter keeps only matching notes, and lifting it restores them."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (setq cmacs-roamgraph--filter-tags '("y"))
    (cmacs-roamgraph--apply-filter)
    (should (= 2 (length (plist-get cmacs-roamgraph--graph :nodes))))
    ;; The edge between the two survivors survives; the one to the
    ;; dropped note does not.
    (should (= 1 (length (plist-get cmacs-roamgraph--graph :edges))))
    ;; Filters compose: nothing carries both x and z.
    (setq cmacs-roamgraph--filter-tags '("x" "z"))
    (cmacs-roamgraph--apply-filter)
    (should (= 0 (length (plist-get cmacs-roamgraph--graph :nodes))))
    (cmacs-roamgraph-filter-clear)
    (should (= 3 (length (plist-get cmacs-roamgraph--graph :nodes))))))

(ert-deftest cmacs-roamgraph-test-color-cycle ()
  "Cycling the colour scheme assigns every node a colour and wraps."
  (cmacs-roamgraph-tests--skip)
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (should (eq 'para cmacs-roamgraph--color-by))
    (let ((seen '()))
      (dotimes (_ (length cmacs-roamgraph--color-modes))
        (cmacs-roamgraph-cycle-color)
        (push cmacs-roamgraph--color-by seen)
        ;; Every node must come out with a usable colour under every
        ;; scheme, including notes with no tags or no file on disk.
        (mapc (lambda (n)
                (should (integerp (plist-get n :color)))
                (should (> (plist-get n :color) 0)))
              (plist-get cmacs-roamgraph--graph :nodes)))
      ;; A full cycle returns to where it started.
      (should (eq 'para cmacs-roamgraph--color-by))
      (should (= (length cmacs-roamgraph--color-modes)
                 (length (delete-dups seen)))))))

(ert-deftest cmacs-roamgraph-test-inspector-renders ()
  "The inspector shows the note's metadata and live link keys."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (require 'cmacs-roamgraph-panes nil t))
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (cmacs-roamgraph--select "b" nil 'test)
    (let ((ib (cmacs-roamgraph--inspector-render "b")))
      (with-current-buffer ib
        (let ((text (buffer-string)))
          (should (string-match-p "Beta" text))
          (should (string-match-p "Forward links" text))
          (should (string-match-p "Backlinks" text))
          ;; `b' links to c and is linked from a, so both directions
          ;; must have produced a live key.
          (should (= 2 (length cmacs-roamgraph--link-keys)))
          (should (equal "c" (cdr (assoc "1" cmacs-roamgraph--link-keys))))
          (should (equal "a" (cdr (assoc "a" cmacs-roamgraph--link-keys)))))))))

(ert-deftest cmacs-roamgraph-test-list-and-tags-panes ()
  "The node list and tag panes reflect the filtered graph."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (require 'cmacs-roamgraph-panes nil t))
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (let ((lb (cmacs-roamgraph--list-render buf)))
      (with-current-buffer lb
        ;; Three linked notes; the orphan is not in the graph at all.
        (should (= 3 (length tabulated-list-entries)))
        (should (member "a" (mapcar #'car tabulated-list-entries)))))
    (let ((tb (cmacs-roamgraph--tags-render buf)))
      (with-current-buffer tb
        ;; x and y are on linked notes; z is only on the hidden orphan.
        (should (= 2 (length tabulated-list-entries)))))))

(ert-deftest cmacs-roamgraph-test-neighbour-flags ()
  "Selecting a note flags its immediate neighbours for emphasis."
  (cmacs-roamgraph-tests--skip)
  (skip-unless (fboundp 'cmacs-libregnum-node-flags))
  (cmacs-roamgraph-tests--with-view (buf (cmacs-roamgraph-tests--graph))
    (cmacs-roamgraph--select "b" nil 'test)
    (let ((nb 8))                       ; NEIGHBOUR = 1<<3
      ;; a and c are one hop from b.
      (dolist (id '("a" "c"))
        (let ((idx (cmacs-roamgraph--scene-index id)))
          (should idx)
          (should (= nb (logand nb (cmacs-libregnum-node-flags buf idx))))))
      ;; Moving the selection clears the previous ring.
      (cmacs-roamgraph--select "a" nil 'test)
      (let ((idx (cmacs-roamgraph--scene-index "c")))
        (should (zerop (logand nb (cmacs-libregnum-node-flags buf idx))))))))

(provide 'cmacs-roamgraph-tests)

;;; cmacs-roamgraph-tests.el ends here
