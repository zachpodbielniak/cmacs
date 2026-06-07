;;; cmacs-libregnum-tests.el --- ERT for cmacs-libregnum  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cmacs-libregnum)

(defun cmacs-libregnum-tests--gl-skip-or ()
  "Return non-nil and skip if there is no display to host a GL view."
  (unless (and (display-graphic-p)
               (fboundp 'cmacs-libregnum-supported-p)
               (cmacs-libregnum-supported-p))
    (ert-skip "no display / cmacs-libregnum not built")))

(ert-deftest cmacs-libregnum-tests-supported-p ()
  "cmacs-libregnum-supported-p returns a boolean at all times."
  (let ((r (and (fboundp 'cmacs-libregnum-supported-p)
                (cmacs-libregnum-supported-p))))
    (should (or (eq r t) (null r)))))

(ert-deftest cmacs-libregnum-tests-parse-buffer ()
  "Buffer YAML parser handles bare values + coordinate triples."
  (with-temp-buffer
    (insert "# -*- mode: cmacs-libregnum -*-\n")
    (insert "scene_type: project_tree\n")
    (insert "project_root: /tmp/example\n")
    (insert "position: [1.5, -2.0, 3.25]\n")
    (insert "fov: 60\n")
    (let ((a (cmacs-libregnum--parse-buffer)))
      (should (equal (cmacs-libregnum--alist-get 'scene_type a)
                     "project_tree"))
      (should (equal (cmacs-libregnum--alist-get 'project_root a)
                     "/tmp/example"))
      (should (equal (cmacs-libregnum--alist-get 'position a)
                     '(1.5 -2.0 3.25)))
      (should (= (cmacs-libregnum--alist-get 'fov a) 60)))))

(ert-deftest cmacs-libregnum-tests-serialise-roundtrip ()
  "Parse + serialise is a round-trip on the supported subset."
  (let ((in '((scene_type . "project_tree")
              (project_root . "/tmp/example")
              (position . (1.0 2.0 3.0))
              (target   . (0.0 0.0 0.0))
              (fov      . 60.0))))
    (with-temp-buffer
      (cmacs-libregnum--serialise-buffer in)
      (let ((out (cmacs-libregnum--parse-buffer)))
        (should (equal (cmacs-libregnum--alist-get 'scene_type out)
                       "project_tree"))
        (should (equal (cmacs-libregnum--alist-get 'position out)
                       '(1.0 2.0 3.0)))))))

(ert-deftest cmacs-libregnum-tests-attach-detach ()
  "Attach + detach a view to a temp buffer; check attached-p toggles."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (cmacs-libregnum-mode))
          (should (cmacs-libregnum-attached-p buf))
          (cmacs-libregnum-detach buf)
          (should-not (cmacs-libregnum-attached-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest cmacs-libregnum-tests-scene-tree ()
  "Building the project-tree scene over a small fixture succeeds."
  (cmacs-libregnum-tests--gl-skip-or)
  (let* ((dir (make-temp-file "cmacs-libregnum-fixture-" t))
         (buf (generate-new-buffer "*cmacs-libregnum tree test*")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.txt" dir) (insert "hi"))
          (with-temp-file (expand-file-name "b.org" dir) (insert "* h"))
          (with-current-buffer buf (cmacs-libregnum-mode))
          (should (eq (cmacs-libregnum-build-tree buf dir) t)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest cmacs-libregnum-tests-scene-gobject ()
  "Building the GObject hierarchy scene with a narrow namespace works."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum gobject test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (cmacs-libregnum-mode))
          (should (eq (cmacs-libregnum-build-gobject buf "G") t)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; ── Editor / level authoring ──────────────────────────────────────

(ert-deftest cmacs-libregnum-tests-editor-symbols ()
  "The editor commands and C primitives are all defined."
  (dolist (fn '(cmacs-libregnum-editor
                cmacs-libregnum-editor-mode
                cmacs-libregnum-editor-add-cube
                cmacs-libregnum-editor-add-sphere
                cmacs-libregnum-editor-delete-current
                cmacs-libregnum-editor-undo-edit
                cmacs-libregnum-editor-outliner
                ;; C primitives
                cmacs-libregnum-editor-new
                cmacs-libregnum-editor-open
                cmacs-libregnum-editor-save
                cmacs-libregnum-editor-active-p
                cmacs-libregnum-editor-add-primitive
                cmacs-libregnum-editor-delete
                cmacs-libregnum-editor-select
                cmacs-libregnum-editor-set-position
                cmacs-libregnum-editor-undo
                cmacs-libregnum-editor-redo
                cmacs-libregnum-editor-node-guid))
    (should (fboundp fn)))
  (should (= cmacs-libregnum-primitive-cube 1))
  (should (= cmacs-libregnum-primitive-uv-sphere 3)))

(ert-deftest cmacs-libregnum-tests-editor-lifecycle ()
  "Open an editor, place + select + move + delete + undo, then save/reopen."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum editor test*"))
        (path (make-temp-file "cmacs-lrg-" nil ".rlevel")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (cmacs-libregnum-editor-mode)
            (should (cmacs-libregnum-editor-new buf))
            (should (cmacs-libregnum-editor-active-p buf))
            ;; Place a cube; it becomes node 0 and the current selection.
            (let ((id (cmacs-libregnum-editor-add-primitive
                       buf cmacs-libregnum-primitive-cube "Cube")))
              (should (integerp id))
              (should (>= (length (cmacs-libregnum-tree-nodes buf)) 1))
              (should (stringp (cmacs-libregnum-editor-node-guid buf id)))
              ;; Move + undo.
              (cmacs-libregnum-editor-set-position buf id 5.0 0.0 0.0)
              (should (cmacs-libregnum-editor-can-undo-p buf))
              (cmacs-libregnum-editor-undo buf)
              ;; Save and reopen into a second view.
              (cmacs-libregnum-editor-save buf path)
              (should (file-exists-p path))
              (cmacs-libregnum-editor-open buf path)
              (should (>= (length (cmacs-libregnum-tree-nodes buf)) 1))
              ;; Delete it.
              (cmacs-libregnum-editor-delete buf 0))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (ignore-errors (delete-file path)))))

(ert-deftest cmacs-libregnum-tests-editor-render ()
  "A placed primitive changes the rendered frame (engine FBO snapshot)."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum render test*"))
        (empty (make-temp-file "lrg-empty-" nil ".png"))
        (full  (make-temp-file "lrg-full-" nil ".png")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (cmacs-libregnum-editor-new buf)
          ;; `cmacs-libregnum-snapshot' renders synchronously, so no
          ;; redisplay/sit-for is needed (and avoiding them keeps the test
          ;; from blocking under the batch runner on a windowed display).
          (cmacs-libregnum-snapshot buf empty)
          (cmacs-libregnum-editor-add-primitive
           buf cmacs-libregnum-primitive-cube "C")
          (cmacs-libregnum-snapshot buf full)
          (should (file-exists-p empty))
          (should (file-exists-p full))
          (should (> (file-attribute-size (file-attributes empty)) 0))
          ;; Placing a cube must alter the rendered frame.
          (should (/= (file-attribute-size (file-attributes empty))
                      (file-attribute-size (file-attributes full)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (ignore-errors (delete-file empty))
      (ignore-errors (delete-file full)))))

(ert-deftest cmacs-libregnum-tests-editor-move ()
  "Keyboard nudge, snap, mouse-drag, and drag undo-coalescing all move a node."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum move test*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (cmacs-libregnum-editor-new buf)
          (let ((id (cmacs-libregnum-editor-add-primitive
                     buf cmacs-libregnum-primitive-cube "Cube")))
            (should (integerp id))
            ;; The new node is the engine selection, so nudge/drag find it.
            (should (equal (cmacs-libregnum-editor-selected-id buf) id))
            ;; Keyboard nudge: +X twice == +2*step, Y/Z unchanged.
            (cmacs-libregnum-editor-set-position buf id 0.0 0.0 0.0)
            (cmacs-libregnum-editor-nudge-right)
            (cmacs-libregnum-editor-nudge-right)
            (let ((l (cmacs-libregnum-editor-node-location buf id)))
              (should (< (abs (- (nth 0 l)
                                 (* 2 cmacs-libregnum-editor-nudge-step)))
                         0.001))
              (should (< (abs (nth 1 l)) 0.001))
              (should (< (abs (nth 2 l)) 0.001)))
            ;; Snap: step 0.4 on a 0.5 grid snaps a single +X nudge to 0.5.
            (cmacs-libregnum-editor-set-position buf id 0.0 0.0 0.0)
            (setq-local cmacs-libregnum-editor--snap 0.5)
            (let ((cmacs-libregnum-editor-nudge-step 0.4))
              (cmacs-libregnum-editor-nudge-right))
            (should (< (abs (- (nth 0 (cmacs-libregnum-editor-node-location buf id))
                               0.5))
                       0.001))
            (setq-local cmacs-libregnum-editor--snap nil)
            ;; Mouse-drag pipeline: a horizontal screen drag moves the node on
            ;; its ground plane (Y invariant) and actually relocates it.
            (cmacs-libregnum-editor-set-position buf id 0.0 0.0 0.0)
            (should (cmacs-libregnum-editor-drag-begin buf id 400 300 800 600))
            (cmacs-libregnum-editor-drag-update buf 550 300 800 600)
            (cmacs-libregnum-editor-drag-end buf)
            (let ((l (cmacs-libregnum-editor-node-location buf id)))
              (should (> (abs (nth 0 l)) 0.01))   ;; moved
              (should (< (abs (nth 1 l)) 0.001)))  ;; stayed on the ground
            ;; One undo reverts the whole drag (commands are coalesced).
            (cmacs-libregnum-editor-undo buf)
            (let ((l (cmacs-libregnum-editor-node-location buf id)))
              (should (< (abs (nth 0 l)) 0.001))
              (should (< (abs (nth 2 l)) 0.001)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest cmacs-libregnum-tests-editor-primitive-shapes ()
  "Each primitive bakes its own geometry, so cylinder/cone/plane render
differently from a cube (regression: non-sphere prims all baked as cubes)."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((files '())
        (sizes '()))
    (unwind-protect
        (progn
          (dolist (p (list (cons "cube"     cmacs-libregnum-primitive-cube)
                           (cons "cylinder" cmacs-libregnum-primitive-cylinder)
                           (cons "cone"     cmacs-libregnum-primitive-cone)
                           (cons "plane"    cmacs-libregnum-primitive-plane)
                           (cons "ico"      cmacs-libregnum-primitive-ico-sphere)
                           (cons "torus"    cmacs-libregnum-primitive-torus)
                           (cons "circle"   cmacs-libregnum-primitive-circle)
                           (cons "grid"     cmacs-libregnum-primitive-grid)
                           (cons "rect2d"   cmacs-libregnum-primitive-rectangle-2d)
                           (cons "circle2d" cmacs-libregnum-primitive-circle-2d)))
            (let ((buf (generate-new-buffer "*cmacs-lrg shape test*"))
                  (png (make-temp-file "cmacs-lrg-shape-" nil ".png")))
              (push png files)
              (unwind-protect
                  (with-current-buffer buf
                    (cmacs-libregnum-editor-mode)
                    (cmacs-libregnum-editor-new buf)
                    (cmacs-libregnum-editor-add-primitive buf (cdr p) (car p))
                    (cmacs-libregnum-snapshot buf png)
                    (push (cons (car p)
                                (file-attribute-size (file-attributes png)))
                          sizes))
                (when (buffer-live-p buf) (kill-buffer buf)))))
          (let ((cube (cdr (assoc "cube" sizes))))
            (should (integerp cube))
            (should (> cube 0))
            (dolist (other '("cylinder" "cone" "plane" "ico" "torus" "circle"
                             "grid" "rect2d" "circle2d"))
              (should (/= cube (cdr (assoc other sizes)))))))
      (dolist (f files) (ignore-errors (delete-file f))))))

(ert-deftest cmacs-libregnum-tests-editor-rotate-scale-reparent ()
  "Rotation + scale write through (one undo each) and reparent re-nests."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg xform test*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (cmacs-libregnum-editor-new buf)
          (let ((id (cmacs-libregnum-editor-add-primitive
                     buf cmacs-libregnum-primitive-cube "C")))
            ;; Rotation.
            (cmacs-libregnum-editor-set-rotation buf id 0.0 0.6 0.0)
            (let ((r (cmacs-libregnum-editor-node-rotation buf id)))
              (should (< (abs (- (nth 1 r) 0.6)) 0.001)))
            ;; Scale.
            (cmacs-libregnum-editor-set-scale buf id 2.0 2.0 2.0)
            (let ((s (cmacs-libregnum-editor-node-scale buf id)))
              (should (< (abs (- (nth 0 s) 2.0)) 0.001)))
            ;; The scale edit undoes back to 1.0.
            (cmacs-libregnum-editor-undo buf)
            (let ((s (cmacs-libregnum-editor-node-scale buf id)))
              (should (< (abs (- (nth 0 s) 1.0)) 0.001))))
          ;; Reparent: B under A nests it one level deeper.
          (cmacs-libregnum-editor-new buf)
          (let ((a (cmacs-libregnum-editor-add-primitive
                    buf cmacs-libregnum-primitive-cube "A"))
                (b (cmacs-libregnum-editor-add-primitive
                    buf cmacs-libregnum-primitive-cube "B")))
            (should a) (should b)
            (should (cmacs-libregnum-editor-reparent buf b a))
            (let ((depths (mapcar (lambda (pl) (plist-get pl :depth))
                                  (append (cmacs-libregnum-tree-nodes buf) nil))))
              (should (member 1 depths)))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest cmacs-libregnum-tests-editor-inspector ()
  "The property inspector reads a node and applies edits through the editor."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg insp test*"))
        (insp nil))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (cmacs-libregnum-editor-new buf)
          (let ((id (cmacs-libregnum-editor-add-primitive
                     buf cmacs-libregnum-primitive-cube "I")))
            (setq insp (get-buffer-create "*cmacs-libregnum inspector*"))
            (with-current-buffer insp
              (cmacs-libregnum-inspector-mode)
              (setq cmacs-libregnum-editor--src-buffer buf)
              (cmacs-libregnum-inspector--rebuild)
              ;; 9 transform fields (pos/rot/scale x3).
              (should (= (length cmacs-libregnum-inspector--fields) 9))
              (widget-value-set
               (cdr (assq 'px cmacs-libregnum-inspector--fields)) "9")
              (widget-value-set
               (cdr (assq 'sx cmacs-libregnum-inspector--fields)) "3")
              (cmacs-libregnum-inspector-apply))
            (let ((loc (cmacs-libregnum-editor-node-location buf id))
                  (scl (cmacs-libregnum-editor-node-scale buf id)))
              (should (< (abs (- (nth 0 loc) 9.0)) 0.001))
              (should (< (abs (- (nth 0 scl) 3.0)) 0.001)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (buffer-live-p insp) (kill-buffer insp)))))

(ert-deftest cmacs-libregnum-tests-editor-nodes-mesh-scripts-play ()
  "Visual-kind nodes, mesh-asset load, script attach+persist, and play work."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg nodes test*"))
        (obj (make-temp-file "cmacs-lrg-" nil ".obj"))
        (rl  (make-temp-file "cmacs-lrg-" nil ".rlevel")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          ;; Light/camera/audio gizmo nodes.
          (cmacs-libregnum-editor-new buf)
          (should (cmacs-libregnum-editor-add-visual
                   buf cmacs-libregnum-visual-light "L"))
          (should (cmacs-libregnum-editor-add-visual
                   buf cmacs-libregnum-visual-camera "C"))
          (should (= (length (cmacs-libregnum-tree-nodes buf)) 2))
          ;; Mesh asset: write a minimal OBJ cube and load it.
          (with-temp-file obj
            (insert "v -0.5 -0.5 -0.5\nv 0.5 -0.5 -0.5\nv 0.5 0.5 -0.5\n"
                    "v -0.5 0.5 -0.5\nv -0.5 -0.5 0.5\nv 0.5 -0.5 0.5\n"
                    "v 0.5 0.5 0.5\nv -0.5 0.5 0.5\n"
                    "f 1 2 3\nf 1 3 4\nf 5 6 7\nf 5 7 8\nf 1 2 6\nf 1 6 5\n"
                    "f 2 3 7\nf 2 7 6\nf 3 4 8\nf 3 8 7\nf 4 1 5\nf 4 5 8\n"))
          (cmacs-libregnum-editor-new buf)
          (should (integerp (cmacs-libregnum-editor-add-visual
                             buf cmacs-libregnum-visual-mesh-asset "M" obj)))
          ;; Attach a script and round-trip it through the .rlevel.
          (cmacs-libregnum-editor-new buf)
          (let ((id (cmacs-libregnum-editor-add-primitive
                     buf cmacs-libregnum-primitive-cube "S")))
            (should (cmacs-libregnum-editor-attach-script
                     buf id 4 "scripts/foo.crispy"))
            (should (= (cmacs-libregnum-editor-node-script-count buf id) 1))
            (cmacs-libregnum-editor-save buf rl)
            (cmacs-libregnum-editor-open buf rl)
            (should (= (cmacs-libregnum-editor-node-script-count buf 0) 1)))
          ;; Play-in-editor: instantiate, tick, stop (must not crash).
          (cmacs-libregnum-editor-new buf)
          (cmacs-libregnum-editor-add-primitive
           buf cmacs-libregnum-primitive-cube "P")
          (should (cmacs-libregnum-editor-play buf))
          (should (cmacs-libregnum-editor-playing-p buf))
          (cmacs-libregnum-editor-play-tick buf 0.016)
          (cmacs-libregnum-editor-stop buf)
          (should-not (cmacs-libregnum-editor-playing-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (ignore-errors (delete-file obj))
      (ignore-errors (delete-file rl)))))

(ert-deftest cmacs-libregnum-tests-editor-gizmo ()
  "Transform gizmo handles drag axis-constrained translate/scale/rotate."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg gizmo test*"))
        (vw 800) (vh 600))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (cmacs-libregnum-editor-new buf)
          (let ((id (cmacs-libregnum-editor-add-primitive
                     buf cmacs-libregnum-primitive-cube "C")))
            (cmacs-libregnum-editor-select buf id)
            ;; Translate along X: the cube moves only in X.
            (cmacs-libregnum-editor-set-tool buf 1)
            (cmacs-libregnum-editor-set-position buf id 0.0 0.0 0.0)
            (let ((b (cmacs-libregnum-project buf 1.02 0.0 0.0 vw vh))
                  (d (cmacs-libregnum-project buf 2.5 0.0 0.0 vw vh)))
              (should b)
              (should (cmacs-libregnum-editor-gizmo-begin
                       buf (nth 0 b) (nth 1 b) vw vh))
              (cmacs-libregnum-editor-gizmo-drag buf (nth 0 d) (nth 1 d) vw vh)
              (cmacs-libregnum-editor-gizmo-end buf)
              (let ((l (cmacs-libregnum-editor-node-location buf id)))
                (should (> (nth 0 l) 0.1))
                (should (< (abs (nth 1 l)) 0.01))
                (should (< (abs (nth 2 l)) 0.01))))
            ;; Scale along X: only the X scale grows.
            (cmacs-libregnum-editor-set-tool buf 3)
            (cmacs-libregnum-editor-set-position buf id 0.0 0.0 0.0)
            (cmacs-libregnum-editor-set-scale buf id 1.0 1.0 1.0)
            (let ((b (cmacs-libregnum-project buf 1.02 0.0 0.0 vw vh))
                  (d (cmacs-libregnum-project buf 2.8 0.0 0.0 vw vh)))
              (should (cmacs-libregnum-editor-gizmo-begin
                       buf (nth 0 b) (nth 1 b) vw vh))
              (cmacs-libregnum-editor-gizmo-drag buf (nth 0 d) (nth 1 d) vw vh)
              (cmacs-libregnum-editor-gizmo-end buf)
              (let ((s (cmacs-libregnum-editor-node-scale buf id)))
                (should (> (nth 0 s) 1.1))
                (should (< (abs (- (nth 1 s) 1.0)) 0.01))))
            ;; Rotate about Y (drag the Y ring 45deg -> 90deg).
            (cmacs-libregnum-editor-set-tool buf 2)
            (cmacs-libregnum-editor-set-rotation buf id 0.0 0.0 0.0)
            (let ((b (cmacs-libregnum-project buf 1.2 0.0 1.2 vw vh))
                  (d (cmacs-libregnum-project buf 0.0 0.0 1.7 vw vh)))
              (should (cmacs-libregnum-editor-gizmo-begin
                       buf (nth 0 b) (nth 1 b) vw vh))
              (cmacs-libregnum-editor-gizmo-drag buf (nth 0 d) (nth 1 d) vw vh)
              (cmacs-libregnum-editor-gizmo-end buf)
              (let ((r (cmacs-libregnum-editor-node-rotation buf id)))
                (should (> (abs (nth 1 r)) 0.1))
                (should (< (abs (nth 0 r)) 0.01))
                (should (< (abs (nth 2 r)) 0.01))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest cmacs-libregnum-tests-editor-sprite-2d-drop ()
  "Sprite textures render, the 2D view toggles, and drop-at-point places."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg s2d test*"))
        (png (make-temp-file "cmacs-lrg-" nil ".png"))
        (empty (make-temp-file "cmacs-lrg-e-" nil ".png"))
        (full  (make-temp-file "cmacs-lrg-f-" nil ".png")))
    (unwind-protect
        (progn
          ;; A tiny 1x1 red PNG for the sprite texture.
          (with-temp-file png
            (set-buffer-multibyte nil)
            (insert (base64-decode-string
                     (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfF"
                             "cSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAA"
                             "BJRU5ErkJggg=="))))
          (with-current-buffer buf
            (cmacs-libregnum-editor-mode)
            ;; Sprite texture changes the frame.
            (cmacs-libregnum-editor-new buf)
            (cmacs-libregnum-snapshot buf empty)
            (cmacs-libregnum-editor-add-visual
             buf cmacs-libregnum-visual-sprite "S" png)
            (cmacs-libregnum-snapshot buf full)
            (should (/= (file-attribute-size (file-attributes empty))
                        (file-attribute-size (file-attributes full))))
            ;; 2D view toggles.
            (cmacs-libregnum-editor-set-view-2d buf t)
            (should (cmacs-libregnum-editor-view-2d-p buf))
            (cmacs-libregnum-editor-set-view-2d buf nil)
            (should-not (cmacs-libregnum-editor-view-2d-p buf))
            ;; Drop-at-point places at the given ground coordinate.
            (cmacs-libregnum-editor-new buf)
            (cmacs-libregnum-editor--arm
             buf (lambda (b wx wy wz)
                   (let ((id (cmacs-libregnum-editor-add-primitive
                              b cmacs-libregnum-primitive-cube "D")))
                     (cmacs-libregnum-editor-set-position b id wx wy wz)))
             "Cube")
            (cmacs-libregnum-editor--drop buf '(2.0 0.0 -2.0))
            (should-not cmacs-libregnum-editor--drop-thunk)
            (let* ((nodes (cmacs-libregnum-tree-nodes buf))
                   (loc (and (> (length nodes) 0)
                             (cmacs-libregnum-editor-node-location
                              buf (plist-get (aref nodes 0) :id)))))
              (should (< (abs (- (nth 0 loc) 2.0)) 0.001))
              (should (< (abs (- (nth 2 loc) -2.0)) 0.001)))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (dolist (f (list png empty full)) (ignore-errors (delete-file f))))))

(ert-deftest cmacs-libregnum-tests-editor-tilemap ()
  "Tilemap: configure, paint cells, render, and round-trip through .rlevel."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg tilemap test*"))
        (png (make-temp-file "cmacs-lrg-ts-" nil ".png"))
        (empty (make-temp-file "cmacs-lrg-e-" nil ".png"))
        (painted (make-temp-file "cmacs-lrg-p-" nil ".png"))
        (rl (make-temp-file "cmacs-lrg-" nil ".rlevel")))
    (unwind-protect
        (progn
          ;; A 4x4-px solid-red RGBA tileset (one tile, cols=1).
          (with-temp-file png
            (set-buffer-multibyte nil)
            (insert (base64-decode-string
                     (concat "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAF"
                             "UlEQVQI12P8z8DwnwEJMDGgAcICAIPRAgYt167zAAAAAElFTk"
                             "SuQmCC"))))
          (with-current-buffer buf
            (cmacs-libregnum-editor-mode)
            (cmacs-libregnum-editor-new buf)
            (cmacs-libregnum-snapshot buf empty)
            (let ((id (cmacs-libregnum-editor-add-visual
                       buf cmacs-libregnum-visual-tilemap "TM" png)))
              (cmacs-libregnum-editor-tilemap-config buf id png 2 2 1 4 4)
              ;; info reports the configured dimensions.
              (let ((info (cmacs-libregnum-editor-tilemap-info buf id)))
                (should (= (plist-get info :map-w) 4))
                (should (= (plist-get info :map-h) 4)))
              ;; Paint a diagonal, then it must change the frame.
              (dotimes (i 4)
                (cmacs-libregnum-editor-tilemap-set-tile buf id i i 0))
              (cmacs-libregnum-snapshot buf painted)
              (should (/= (file-attribute-size (file-attributes empty))
                          (file-attribute-size (file-attributes painted))))
              ;; Persist + reopen: the tilemap (dims) survives.
              (cmacs-libregnum-editor-save buf rl)
              (cmacs-libregnum-editor-open buf rl)
              (let ((info (cmacs-libregnum-editor-tilemap-info buf 0)))
                (should info)
                (should (= (plist-get info :map-w) 4))
                (should (= (plist-get info :map-h) 4)))
              ;; And the painted tiles still render (non-empty frame).
              (let ((re (make-temp-file "cmacs-lrg-r-" nil ".png")))
                (cmacs-libregnum-snapshot buf re)
                (should (/= (file-attribute-size (file-attributes empty))
                            (file-attribute-size (file-attributes re))))
                (ignore-errors (delete-file re))))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (dolist (f (list png empty painted rl)) (ignore-errors (delete-file f))))))

(provide 'cmacs-libregnum-tests)
;;; cmacs-libregnum-tests.el ends here
