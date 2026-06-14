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

;;; ─── Right-click context menu (pure, batch-safe) ───────────────────────

(defun cmacs-libregnum-tests--ctx-labels (items)
  "Return the clickable labels of menu ITEMS (dropping (:sep) markers)."
  (delq nil (mapcar (lambda (it) (and (not (plist-member it :sep))
                                      (plist-get it :label)))
                    items)))

(defun cmacs-libregnum-tests--menu-keymap-leaves (km)
  "Collect (LABEL . BINDING) leaves of menu keymap KM, recursing into submenus.
Separators (whose real binding is nil) are skipped."
  (let (out)
    (map-keymap
     (lambda (_ev binding)
       (when (and (consp binding) (eq (car binding) 'menu-item))
         (let ((label (nth 1 binding)) (real (nth 2 binding)))
           (cond
            ((keymapp real)
             (setq out (append out
                               (cmacs-libregnum-tests--menu-keymap-leaves real))))
            ((functionp real) (push (cons label real) out))))))
     km)
    out))

(ert-deftest cmacs-libregnum-tests-context-menu-symbols ()
  "The context-menu functions and the node-kind primitive are all defined."
  (dolist (fn '(cmacs-libregnum-editor-node-kind
                cmacs-libregnum-editor-node-primitive
                cmacs-libregnum-editor-set-name
                cmacs-libregnum-editor--kind-symbol
                cmacs-libregnum-editor--type-label
                cmacs-libregnum-editor--outliner-label
                cmacs-libregnum-editor--filter-menu-items
                cmacs-libregnum-editor--menu-keymap
                cmacs-libregnum-editor--context-menu
                cmacs-libregnum-editor--popup-context-menu
                cmacs-libregnum-editor--popup-add-menu
                cmacs-libregnum-editor--place-item
                cmacs-libregnum-editor--ctx-rename
                cmacs-libregnum-editor--ctx-rotate
                cmacs-libregnum-editor--ctx-reset-transform
                cmacs-libregnum-editor--ctx-toggle
                cmacs-libregnum-editor--ctx-open-asset
                cmacs-libregnum-editor--ctx-duplicate
                cmacs-libregnum-editor--ctx-new-script
                cmacs-libregnum-editor--ctx-existing-script))
    (should (fboundp fn)))
  (should (listp cmacs-libregnum-editor-context-menu-items))
  (should (listp cmacs-libregnum-editor-rotate-menu-items))
  (should (listp cmacs-libregnum-editor-script-menu-items)))

(ert-deftest cmacs-libregnum-tests-context-menu-kind-symbol ()
  "Integer visual kinds map to the expected menu node-kind symbols."
  (should (eq (cmacs-libregnum-editor--kind-symbol nil) 'group))
  (should (eq (cmacs-libregnum-editor--kind-symbol 1) 'primitive))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-mesh-asset) 'mesh))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-sprite) 'sprite))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-tilemap) 'tilemap))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-light) 'light))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-camera) 'camera))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-audio) 'audio))
  (should (eq (cmacs-libregnum-editor--kind-symbol
               cmacs-libregnum-visual-prefab) 'prefab))
  (should (eq (cmacs-libregnum-editor--kind-symbol 999) 'unknown)))

(ert-deftest cmacs-libregnum-tests-context-menu-filter ()
  "Menu filtering keeps the common items and only the matching kind items."
  (let ((common (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'group)))
        (lightl (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'light)))
        (meshl  (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'mesh))))
    ;; Common (t) items appear for every kind, incl. a node with no visual.
    (should (member "Rename…" common))
    (should (member "Delete" common))
    (should (member "Duplicate" common))
    ;; A group node shows no kind-specific items.
    (should-not (member "Set light range/color…" common))
    (should-not (member "Open asset file" common))
    ;; Light shows its own item but not camera/audio/asset items.
    (should (member "Set light range/color…" lightl))
    (should-not (member "Set camera FOV…" lightl))
    (should-not (member "Open asset file" lightl))
    ;; Mesh assets expose the asset-open item.
    (should (member "Open asset file" meshl))
    (should-not (member "Set light range/color…" meshl))))

(ert-deftest cmacs-libregnum-tests-context-menu-submenus ()
  "The rotate + attach-script submenus are well-formed and wired into the spec."
  ;; 12 axis rotations (±45/±90 over X/Y/Z) + reset = 13 action items.
  (let ((acts (delq nil (mapcar (lambda (it) (plist-get it :action))
                                cmacs-libregnum-editor-rotate-menu-items))))
    (should (= (length acts) 13))
    (should-not (memq nil (mapcar #'functionp acts))))
  ;; New + Existing script.
  (let ((acts (delq nil (mapcar (lambda (it) (plist-get it :action))
                                cmacs-libregnum-editor-script-menu-items))))
    (should (= (length acts) 2))
    (should-not (memq nil (mapcar #'functionp acts))))
  ;; The main spec references both submenus by symbol.
  (should (seq-find (lambda (it)
                      (eq (plist-get it :submenu)
                          'cmacs-libregnum-editor-rotate-menu-items))
                    cmacs-libregnum-editor-context-menu-items))
  (should (seq-find (lambda (it)
                      (eq (plist-get it :submenu)
                          'cmacs-libregnum-editor-script-menu-items))
                    cmacs-libregnum-editor-context-menu-items)))

(ert-deftest cmacs-libregnum-tests-context-menu-keymap ()
  "The menu keymap is well-formed: leaves are callable and submenus nest.
This is the dispatch-correctness invariant — `lookup-key' on the chosen event
path must resolve to a callable action closure."
  (dolist (ksym '(group primitive mesh light camera audio tilemap sprite prefab))
    (let* ((items  (cmacs-libregnum-editor--filter-menu-items ksym))
           (km     (cmacs-libregnum-editor--menu-keymap items (current-buffer) 0))
           (leaves (cmacs-libregnum-tests--menu-keymap-leaves km))
           (labels (mapcar #'car leaves)))
      (should (keymapp km))
      ;; every reached leaf binding is callable.
      (should-not (memq nil (mapcar (lambda (l) (functionp (cdr l))) leaves)))
      ;; top-level command items.
      (should (member "Rename…" labels))
      (should (member "Delete" labels))
      ;; rotate submenu leaves were reached (recursion into submenus works).
      (should (member "X axis +90°" labels))
      (should (member "Reset rotation" labels))
      ;; attach-script submenu leaves.
      (should (member "New script…" labels))
      (should (member "Existing script…" labels)))))

(ert-deftest cmacs-libregnum-tests-context-menu-by-node ()
  "End-to-end: the C node-kind getter + filter yield per-kind item sets."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum ctx test*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (should (cmacs-libregnum-editor-new buf))
          (let ((cube  (cmacs-libregnum-editor-add-primitive
                        buf cmacs-libregnum-primitive-cube "Cube"))
                (light (cmacs-libregnum-editor-add-visual
                        buf cmacs-libregnum-visual-light "Light")))
            (should (= (cmacs-libregnum-editor-node-kind buf cube) 1))
            (should (= (cmacs-libregnum-editor-node-kind buf light)
                       cmacs-libregnum-visual-light))
            (should (eq (cmacs-libregnum-editor--kind-symbol
                         (cmacs-libregnum-editor-node-kind buf cube)) 'primitive))
            (should (eq (cmacs-libregnum-editor--kind-symbol
                         (cmacs-libregnum-editor-node-kind buf light)) 'light))
            (let ((ll (cmacs-libregnum-tests--ctx-labels
                       (cmacs-libregnum-editor--filter-menu-items
                        (cmacs-libregnum-editor--kind-symbol
                         (cmacs-libregnum-editor-node-kind buf light)))))
                  (cl (cmacs-libregnum-tests--ctx-labels
                       (cmacs-libregnum-editor--filter-menu-items
                        (cmacs-libregnum-editor--kind-symbol
                         (cmacs-libregnum-editor-node-kind buf cube))))))
              (should (member "Set light range/color…" ll))
              (should-not (member "Set light range/color…" cl))
              (should (member "Delete" cl)))
            ;; Type labels are name-independent (primitive reports its shape).
            (should (string= (cmacs-libregnum-editor--type-label buf cube) "Cube"))
            (should (string= (cmacs-libregnum-editor--type-label buf light) "Light"))
            ;; Rename re-bakes so the outliner label shows the name in parens.
            (cmacs-libregnum-editor-set-name buf cube "Player")
            (should (= (cmacs-libregnum-editor-node-kind buf cube) 1))
            (should (string= (cmacs-libregnum-editor--outliner-label
                              buf cube "Player")
                             "Cube (Player)"))
            ;; A default-named node shows just its type (no redundant parens).
            (should (string= (cmacs-libregnum-editor--outliner-label
                              buf light "Light")
                             "Light"))
            ;; End-to-end keymap dispatch: resolve the rotate leaf and run it.
            (let* ((km (cmacs-libregnum-editor--menu-keymap
                        (cmacs-libregnum-editor--filter-menu-items 'primitive)
                        buf cube))
                   (leaves (cmacs-libregnum-tests--menu-keymap-leaves km))
                   (x90 (cdr (assoc "X axis +90°" leaves)))
                   (r0  (cmacs-libregnum-editor-node-rotation buf cube)))
              (should (functionp x90))
              (funcall x90)
              (let ((r1 (cmacs-libregnum-editor-node-rotation buf cube)))
                (should (> (- (nth 0 r1) (nth 0 r0)) 1.0))))))  ; ~+pi/2
      (when (buffer-live-p buf) (kill-buffer buf)))))

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

(ert-deftest cmacs-libregnum-tests-scripting-languages ()
  "The available scripting backends are reported (crispy at minimum)."
  (skip-unless (fboundp 'cmacs-libregnum-scripting-languages))
  (let ((langs (cmacs-libregnum-scripting-languages)))
    (should (listp langs))
    ;; cmacs builds libregnum with CRISPY=1, so crispy must be present.
    (should (rassq 4 langs))))

(ert-deftest cmacs-libregnum-tests-editor-inspector-props-prefab ()
  "The node->GObject bridge enumerates properties and prefabs round-trip."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg insp test*"))
        (pf (make-temp-file "cmacs-lrg-" nil ".rprefab")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (cmacs-libregnum-editor-new buf)
          (let* ((id (cmacs-libregnum-editor-add-primitive
                      buf cmacs-libregnum-primitive-cube "Cube"))
                 (obj (cmacs-libregnum-editor-node-object buf id)))
            ;; gi bridge: the node exposes its GObject properties.
            (should obj)
            (should (member "name" (gobject-list-properties obj)))
            (should (member "visible" (gobject-list-properties obj)))
            (should (string= (plist-get (gobject-property-info obj "name") :type)
                             "gchararray"))
            (should (equal (gobject-get obj "name") "Cube"))
            ;; prefab save + instantiate round-trip.
            (should (cmacs-libregnum-editor-save-prefab buf id pf))
            (should (file-exists-p pf))
            (let ((before (length (cmacs-libregnum-tree-nodes buf)))
                  (newid (cmacs-libregnum-editor-instantiate-prefab buf pf nil)))
              (should (integerp newid))
              (should (= (length (cmacs-libregnum-tree-nodes buf))
                         (1+ before))))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (ignore-errors (delete-file pf)))))

(ert-deftest cmacs-libregnum-tests-project-and-assetdb ()
  "Project manifest round-trips and the asset database classifies files.
Display-free (no GL)."
  (skip-unless (fboundp 'cmacs-libregnum-project-create))
  (let* ((root (make-temp-file "cmacs-lrg-proj-" t))
         (assets (expand-file-name "assets" root)))
    (unwind-protect
        (progn
          (make-directory assets t)
          ;; a texture + a model so the classifier has something typed to find
          (with-temp-file (expand-file-name "m.obj" assets) (insert "o c\n"))
          (with-temp-file (expand-file-name "readme.txt" assets) (insert "x"))
          ;; project manifest
          (should (cmacs-libregnum-project-create
                   root "Test" "levels/main.rlevel" "build/game.so"))
          (should (file-exists-p (expand-file-name "project.ryaml" root)))
          ;; asset database scan + classification
          (let* ((entries (cmacs-libregnum-assetdb-scan assets))
                 (obj (seq-find (lambda (e) (equal (plist-get e :name) "m.obj"))
                                entries)))
            (should obj)
            (should (= (plist-get obj :type) 2))))   ;; 2 = MODEL
      (ignore-errors (delete-directory root t)))))

;;; ─── New right-click menu tests (pure, batch-safe) ──────────────────────────

(ert-deftest cmacs-libregnum-tests-context-menu-new-symbols ()
  "All new helper commands and submenu vars are defined after the expansion."
  (dolist (fn '(cmacs-libregnum-editor--ctx-set-color
                cmacs-libregnum-editor--ctx-set-roughness
                cmacs-libregnum-editor--ctx-set-metallic
                cmacs-libregnum-editor--ctx-scale-x2
                cmacs-libregnum-editor--ctx-scale-half
                cmacs-libregnum-editor--ctx-reset-scale
                cmacs-libregnum-editor--ctx-set-scale
                cmacs-libregnum-editor--ctx-drop-to-ground
                cmacs-libregnum-editor--ctx-snap-to-grid
                cmacs-libregnum-editor--ctx-reset-position
                cmacs-libregnum-editor--ctx-duplicate-native
                cmacs-libregnum-editor--ctx-copy
                cmacs-libregnum-editor--ctx-cut
                cmacs-libregnum-editor--ctx-paste
                cmacs-libregnum-editor--ctx-copy-guid
                cmacs-libregnum-editor--ctx-reparent-under
                cmacs-libregnum-editor--ctx-add-child
                cmacs-libregnum-editor--ctx-add-empty-group-under
                cmacs-libregnum-editor--ctx-replace-asset
                cmacs-libregnum-editor--ctx-manage-scripts-items-fn
                cmacs-libregnum-editor--ctx-set-light-intensity
                cmacs-libregnum-editor--ctx-align-camera-to-view
                cmacs-libregnum-editor--ctx-enter-paint-mode
                cmacs-libregnum-editor--ctx-clear-tilemap
                cmacs-libregnum-editor--ctx-resize-tilemap
                cmacs-libregnum-editor--ctx-unpack-prefab
                cmacs-libregnum-editor--ctx-select-add
                cmacs-libregnum-editor--ctx-select-remove
                cmacs-libregnum-editor--ctx-select-clear
                cmacs-libregnum-editor--ctx-select-parent
                cmacs-libregnum-editor--ctx-delete-selected
                cmacs-libregnum-editor--ctx-group-selected))
    (should (fboundp fn)))
  ;; New submenu vars.
  (dolist (v '(cmacs-libregnum-editor-material-menu-items
               cmacs-libregnum-editor-scale-menu-items
               cmacs-libregnum-editor-tool-menu-items
               cmacs-libregnum-editor-light-type-menu-items
               cmacs-libregnum-editor-selection-menu-items))
    (should (boundp v))
    (should (listp (symbol-value v)))))

(ert-deftest cmacs-libregnum-tests-context-menu-new-submenus ()
  "New submenus are well-formed lists with functionp actions."
  ;; Material submenu: 3 items (set-color, set-roughness, set-metallic).
  (let ((acts (delq nil
                    (mapcar (lambda (it) (plist-get it :action))
                            cmacs-libregnum-editor-material-menu-items))))
    (should (= (length acts) 3))
    (should-not (memq nil (mapcar #'functionp acts))))
  ;; Scale submenu: 3 action items + sep + 1 action item = 4 actions.
  (let ((acts (delq nil
                    (mapcar (lambda (it) (plist-get it :action))
                            cmacs-libregnum-editor-scale-menu-items))))
    (should (= (length acts) 4))
    (should-not (memq nil (mapcar #'functionp acts))))
  ;; Tool submenu: 4 actions (Translate/Rotate/Scale/Select).
  (let ((acts (delq nil
                    (mapcar (lambda (it) (plist-get it :action))
                            cmacs-libregnum-editor-tool-menu-items))))
    (should (= (length acts) 4))
    (should-not (memq nil (mapcar #'functionp acts))))
  ;; Light-type submenu: 3 actions (Point/Spot/Directional).
  (let ((acts (delq nil
                    (mapcar (lambda (it) (plist-get it :action))
                            cmacs-libregnum-editor-light-type-menu-items))))
    (should (= (length acts) 3))
    (should-not (memq nil (mapcar #'functionp acts))))
  ;; Selection submenu: at least 4 action items.
  (let ((acts (delq nil
                    (mapcar (lambda (it) (plist-get it :action))
                            cmacs-libregnum-editor-selection-menu-items))))
    (should (>= (length acts) 4))
    (should-not (memq nil (mapcar #'functionp acts)))))

(ert-deftest cmacs-libregnum-tests-context-menu-per-kind-filter ()
  "New per-kind items appear only for the expected node kinds."
  (let ((priml  (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'primitive)))
        (meshl  (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'mesh)))
        (lightl (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'light)))
        (caml   (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'camera)))
        (tilem  (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'tilemap)))
        (audioL (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'audio)))
        (prefabl (cmacs-libregnum-tests--ctx-labels
                  (cmacs-libregnum-editor--filter-menu-items 'prefab)))
        (grpl   (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'group))))
    ;; Material shows for primitive and mesh, not for light/camera/audio/group.
    (should (member "Material" priml))
    (should (member "Material" meshl))
    (should-not (member "Material" lightl))
    (should-not (member "Material" grpl))
    ;; Replace asset for mesh/sprite/audio only.
    (should (member "Replace asset…" meshl))
    (should (member "Replace asset…" audioL))
    (should-not (member "Replace asset…" priml))
    (should-not (member "Replace asset…" grpl))
    ;; Light type submenu only for light.
    (should (member "Light type" lightl))
    (should-not (member "Light type" caml))
    ;; Set intensity only for light.
    (should (member "Set intensity…" lightl))
    (should-not (member "Set intensity…" caml))
    ;; Align to view only for camera.
    (should (member "Align to view" caml))
    (should-not (member "Align to view" lightl))
    ;; Tilemap specific items.
    (should (member "Enter paint mode" tilem))
    (should (member "Clear tilemap" tilem))
    (should (member "Resize tilemap…" tilem))
    (should-not (member "Enter paint mode" grpl))
    ;; Prefab: unpack only for prefab.
    (should (member "Unpack prefab" prefabl))
    (should-not (member "Unpack prefab" grpl))
    ;; Common items appear everywhere.
    (should (member "Duplicate" grpl))
    (should (member "Scale" grpl))
    (should (member "Tool" grpl))
    (should (member "Select" grpl))
    (should (member "Drop to ground" grpl))
    (should (member "Snap to grid" grpl))
    (should (member "Reset position" grpl))
    (should (member "Reparent under…" grpl))
    (should (member "Copy GUID" grpl))
    (should (member "Manage scripts" grpl))))

(ert-deftest cmacs-libregnum-tests-context-menu-keymap-new-items ()
  "New items/submenus are reachable in the built keymap for every kind."
  (dolist (ksym '(group primitive mesh light camera audio tilemap sprite prefab))
    (let* ((items  (cmacs-libregnum-editor--filter-menu-items ksym))
           (km     (cmacs-libregnum-editor--menu-keymap
                    items (current-buffer) 0))
           (leaves (cmacs-libregnum-tests--menu-keymap-leaves km))
           (labels (mapcar #'car leaves)))
      (should (keymapp km))
      ;; All leaf bindings must be callable.
      (should-not (memq nil (mapcar (lambda (l) (functionp (cdr l))) leaves)))
      ;; Common items.
      (should (member "Drop to ground" labels))
      (should (member "Snap to grid" labels))
      (should (member "Reset position" labels))
      (should (member "Copy GUID" labels))
      (should (member "Translate" labels))   ; from Tool submenu
      (should (member "Add to selection" labels))  ; from Select submenu
      ;; Scale submenu.
      (should (member "2×" labels))
      (should (member "0.5×" labels))
      (should (member "Reset scale" labels))
      (should (member "Set scale…" labels)))))

(ert-deftest cmacs-libregnum-tests-context-menu-enable-keys ()
  "The :enable and :keys fields round-trip through --menu-keymap build."
  ;; Build a minimal item list with :enable and :keys.
  (let* ((pred-called nil)
         (items
          `((:label "With Enable"
             :kinds t
             :action ,(lambda (_b _i) t)
             :enable ,(lambda (_b _i) (setq pred-called t) t)
             :keys "x")
            (:label "Always On"
             :kinds t
             :action ,(lambda (_b _i) t))))
         (km    (cmacs-libregnum-editor--menu-keymap
                 items (current-buffer) 0))
         (leaves (cmacs-libregnum-tests--menu-keymap-leaves km)))
    ;; Keymap builds without error.
    (should (keymapp km))
    ;; The :enable pred was called during build.
    (should pred-called)
    ;; Both items are reachable as callable leaves.
    (should (member "With Enable" (mapcar #'car leaves)))
    (should (member "Always On"   (mapcar #'car leaves)))))

(ert-deftest cmacs-libregnum-tests-context-menu-items-fn ()
  "A dynamic :items-fn entry builds a nested sub-keymap at pop time."
  (let* ((called-with nil)
         (stub-fn (lambda (buf id)
                    (setq called-with (list buf id))
                    `((:label "Dyn item A"
                       :action ,(lambda (_b _i) 'a))
                      (:label "Dyn item B"
                       :action ,(lambda (_b _i) 'b)))))
         (items
          `((:label "Manage scripts"
             :kinds t
             :items-fn ,stub-fn)
            (:label "Static"
             :kinds t
             :action ,(lambda (_b _i) t))))
         (km (cmacs-libregnum-editor--menu-keymap
              items (current-buffer) 42))
         (leaves (cmacs-libregnum-tests--menu-keymap-leaves km)))
    ;; stub-fn was called with (current-buffer) and id 42.
    (should (equal called-with (list (current-buffer) 42)))
    ;; Dynamic items appear as leaves.
    (should (member "Dyn item A" (mapcar #'car leaves)))
    (should (member "Dyn item B" (mapcar #'car leaves)))
    ;; Static item also present.
    (should (member "Static" (mapcar #'car leaves)))))

(ert-deftest cmacs-libregnum-tests-context-menu-clipboard ()
  "Clipboard defvar exists and starts nil; --ctx-paste guards when empty."
  (should (boundp 'cmacs-libregnum-editor--clipboard))
  (let ((cmacs-libregnum-editor--clipboard nil))
    ;; Paste with empty clipboard signals user-error.
    (should-error
     (cmacs-libregnum-editor--ctx-paste (current-buffer) 0)
     :type 'user-error)))

(ert-deftest cmacs-libregnum-tests-context-menu-outliner-cmd ()
  "The outliner context-menu command is defined and bound."
  (should (fboundp 'cmacs-libregnum-outliner-context-menu))
  (should (keymapp cmacs-libregnum-outliner-mode-map))
  (should (commandp (lookup-key cmacs-libregnum-outliner-mode-map
                                [mouse-3])))
  (should (commandp (lookup-key cmacs-libregnum-outliner-mode-map
                                [down-mouse-3]))))

(ert-deftest cmacs-libregnum-tests-context-menu-by-node-extended ()
  "Display-guarded: new filter items appear per-kind via real node-kind."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-lrg ext ctx test*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-libregnum-editor-mode)
          (should (cmacs-libregnum-editor-new buf))
          (let* ((prim  (cmacs-libregnum-editor-add-primitive
                         buf cmacs-libregnum-primitive-cube "P"))
                 (light (cmacs-libregnum-editor-add-visual
                         buf cmacs-libregnum-visual-light "L"))
                 (mesh  (cmacs-libregnum-editor-add-visual
                         buf cmacs-libregnum-visual-mesh-asset "M"))
                 (cam   (cmacs-libregnum-editor-add-visual
                         buf cmacs-libregnum-visual-camera "C"))
                 (priml (cmacs-libregnum-tests--ctx-labels
                         (cmacs-libregnum-editor--filter-menu-items
                          (cmacs-libregnum-editor--kind-symbol
                           (cmacs-libregnum-editor-node-kind buf prim)))))
                 (lightl (cmacs-libregnum-tests--ctx-labels
                          (cmacs-libregnum-editor--filter-menu-items
                           (cmacs-libregnum-editor--kind-symbol
                            (cmacs-libregnum-editor-node-kind buf light)))))
                 (meshl (cmacs-libregnum-tests--ctx-labels
                         (cmacs-libregnum-editor--filter-menu-items
                          (cmacs-libregnum-editor--kind-symbol
                           (cmacs-libregnum-editor-node-kind buf mesh)))))
                 (caml  (cmacs-libregnum-tests--ctx-labels
                         (cmacs-libregnum-editor--filter-menu-items
                          (cmacs-libregnum-editor--kind-symbol
                           (cmacs-libregnum-editor-node-kind buf cam))))))
            (ignore prim light mesh cam)
            ;; Material for primitive and mesh.
            (should (member "Material" priml))
            (should (member "Material" meshl))
            (should-not (member "Material" lightl))
            ;; Light type for light, align-to-view for camera.
            (should (member "Light type" lightl))
            (should (member "Set intensity…" lightl))
            (should (member "Align to view" caml))
            ;; Replace asset for mesh but not primitive.
            (should (member "Replace asset…" meshl))
            (should-not (member "Replace asset…" priml))
            ;; Keymap for every kind builds without error.
            (dolist (id (list prim light mesh cam))
              (let* ((ksym (cmacs-libregnum-editor--kind-symbol
                             (cmacs-libregnum-editor-node-kind buf id)))
                     (items (cmacs-libregnum-editor--filter-menu-items ksym))
                     (km    (cmacs-libregnum-editor--menu-keymap
                             items buf id)))
                (should (keymapp km))
                (let ((leaves (cmacs-libregnum-tests--menu-keymap-leaves km)))
                  (should-not (memq nil
                                    (mapcar (lambda (l) (functionp (cdr l)))
                                            leaves))))))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; ─── New feature tests: audio rewrite, shading, look-through, wireframe ─────

(ert-deftest cmacs-libregnum-tests-new-commands-fboundp ()
  "All new Elisp commands and variables from the feature branch are defined."
  (dolist (fn '(cmacs-libregnum-editor-stop-audio
                cmacs-libregnum-editor-set-audio-volume
                cmacs-libregnum-editor-toggle-shading
                cmacs-libregnum-editor-stop-look-through
                cmacs-libregnum-editor--ctx-toggle-wireframe
                cmacs-libregnum-editor--ctx-toggle-cast-shadow))
    (should (fboundp fn)))
  ;; Buffer-local audio handle var.
  (should (boundp 'cmacs-libregnum-editor--audio-handle))
  ;; Display submenu var.
  (should (boundp 'cmacs-libregnum-editor-display-menu-items))
  (should (listp cmacs-libregnum-editor-display-menu-items)))

(ert-deftest cmacs-libregnum-tests-display-submenu-shape ()
  "Display submenu has exactly 2 action items (wireframe + cast-shadow)."
  (let ((acts (delq nil
                    (mapcar (lambda (it) (plist-get it :action))
                            cmacs-libregnum-editor-display-menu-items))))
    (should (= (length acts) 2))
    (should-not (memq nil (mapcar #'functionp acts)))))

(ert-deftest cmacs-libregnum-tests-audio-fallback-defined ()
  "play-audio is defined and does not error when cmacs-audio is absent.
The test just checks the function is fboundp; it does NOT call it (doing so
would open a real audio device / file, which is unsafe in batch mode)."
  (should (fboundp 'cmacs-libregnum-editor-play-audio)))

(ert-deftest cmacs-libregnum-tests-audio-handle-local ()
  "The audio-handle var is declared (defvar-local), has a nil default,
and becomes buffer-local once set in any buffer."
  ;; The variable must be bound (declared by defvar-local).
  (should (boundp 'cmacs-libregnum-editor--audio-handle))
  ;; The global default is nil.
  (should (null (default-value 'cmacs-libregnum-editor--audio-handle)))
  ;; Setting it in a temp buffer makes it buffer-local in that buffer.
  (with-temp-buffer
    (setq cmacs-libregnum-editor--audio-handle 42)
    (should (local-variable-p 'cmacs-libregnum-editor--audio-handle
                              (current-buffer)))
    (should (= cmacs-libregnum-editor--audio-handle 42)))
  ;; The global default is still nil (we didn't stomp it).
  (should (null (default-value 'cmacs-libregnum-editor--audio-handle))))

(ert-deftest cmacs-libregnum-tests-stop-audio-no-handle ()
  "stop-audio signals user-error when no handle is live."
  (with-temp-buffer
    (setq cmacs-libregnum-editor--audio-handle nil)
    (should-error (cmacs-libregnum-editor-stop-audio) :type 'user-error)))

(ert-deftest cmacs-libregnum-tests-context-menu-new-audio-camera ()
  "New audio and camera items appear in the context-menu filter."
  (let ((audioL (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'audio)))
        (caml   (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'camera))))
    ;; Audio: existing items still present.
    (should (member "Set audio range…" audioL))
    (should (member "Play audio" audioL))
    ;; Audio: new items.
    (should (member "Set volume…" audioL))
    (should (member "Stop audio" audioL))
    ;; Camera: existing items.
    (should (member "Set camera FOV…" caml))
    (should (member "Align to view" caml))
    ;; Camera: new look-through item.
    (should (member "Look through this camera" caml))
    ;; Stop look-through is :kinds t so appears everywhere.
    (let ((grpl (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'group))))
      (should (member "Stop look-through" grpl)))))

(ert-deftest cmacs-libregnum-tests-context-menu-wireframe-filter ()
  "Wireframe and cast-shadow items appear for primitive and mesh, not others."
  (let ((priml  (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'primitive)))
        (meshl  (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'mesh)))
        (lightl (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'light)))
        (grpl   (cmacs-libregnum-tests--ctx-labels
                 (cmacs-libregnum-editor--filter-menu-items 'group))))
    ;; Display submenu for primitive and mesh.
    (should (member "Display" priml))
    (should (member "Display" meshl))
    ;; Not for light, group, etc.
    (should-not (member "Display" lightl))
    (should-not (member "Display" grpl))))

(ert-deftest cmacs-libregnum-tests-context-menu-wireframe-keymap ()
  "Toggle wireframe and cast-shadow are reachable in the built keymap."
  (dolist (ksym '(primitive mesh))
    (let* ((items  (cmacs-libregnum-editor--filter-menu-items ksym))
           (km     (cmacs-libregnum-editor--menu-keymap
                    items (current-buffer) 0))
           (leaves (cmacs-libregnum-tests--menu-keymap-leaves km))
           (labels (mapcar #'car leaves)))
      (should (keymapp km))
      (should-not (memq nil (mapcar (lambda (l) (functionp (cdr l))) leaves)))
      ;; Display submenu leaves are reachable.
      (should (member "Toggle wireframe" labels))
      (should (member "Toggle cast shadow" labels)))))

(ert-deftest cmacs-libregnum-tests-context-menu-new-audio-keymap ()
  "New audio menu items are reachable in the built keymap for audio nodes."
  (let* ((items  (cmacs-libregnum-editor--filter-menu-items 'audio))
         (km     (cmacs-libregnum-editor--menu-keymap
                  items (current-buffer) 0))
         (leaves (cmacs-libregnum-tests--menu-keymap-leaves km))
         (labels (mapcar #'car leaves)))
    (should (keymapp km))
    (should-not (memq nil (mapcar (lambda (l) (functionp (cdr l))) leaves)))
    (should (member "Set volume…" labels))
    (should (member "Stop audio" labels))))

(ert-deftest cmacs-libregnum-tests-context-menu-look-through-keymap ()
  "Look-through camera item is reachable in the built keymap for cameras."
  (let* ((items  (cmacs-libregnum-editor--filter-menu-items 'camera))
         (km     (cmacs-libregnum-editor--menu-keymap
                  items (current-buffer) 0))
         (leaves (cmacs-libregnum-tests--menu-keymap-leaves km))
         (labels (mapcar #'car leaves)))
    (should (keymapp km))
    (should-not (memq nil (mapcar (lambda (l) (functionp (cdr l))) leaves)))
    (should (member "Look through this camera" labels))))

(ert-deftest cmacs-libregnum-tests-shading-toggle-guarded ()
  "toggle-shading is a no-op (not an error) when the C DEFUN is absent."
  ;; We cannot test the actual toggle without a running engine, but we can
  ;; confirm the command does not signal when the DEFUN is absent.
  (skip-unless (not (fboundp 'cmacs-libregnum-editor-set-shading)))
  ;; Even without the C DEFUN, calling it in an editor buffer must not signal.
  (with-temp-buffer
    ;; Pretend we are in an editor buffer by satisfying the buffer check.
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'cmacs-libregnum-editor--buffer)
                 (lambda () buf)))
        (should-not (condition-case nil
                        (progn (cmacs-libregnum-editor-toggle-shading) nil)
                      (error t)))))))

(ert-deftest cmacs-libregnum-tests-wireframe-toggle-logic ()
  "Wireframe toggle flips 0.0->1.0 and 1.0->0.0 using set-visual-param.
Batch-safe: stubs out the C DEFUNs with Lisp flets."
  (let ((buf (current-buffer))
        (last-set nil))
    ;; Stub: get returns 0.0 (wireframe off), set records the value.
    (cl-letf (((symbol-function 'cmacs-libregnum-editor-get-visual-param)
               (lambda (_b _i _n _d) 0.0))
              ((symbol-function 'cmacs-libregnum-editor-set-visual-param)
               (lambda (_b _i _n v) (setq last-set v)))
              ((symbol-function 'cmacs-libregnum-editor--sync-panels)
               (lambda (&rest _) nil)))
      (cmacs-libregnum-editor--ctx-toggle-wireframe buf 0)
      (should (= last-set 1.0)))
    ;; Now get returns 1.0 (wireframe on) -> toggling sets to 0.0.
    (setq last-set nil)
    (cl-letf (((symbol-function 'cmacs-libregnum-editor-get-visual-param)
               (lambda (_b _i _n _d) 1.0))
              ((symbol-function 'cmacs-libregnum-editor-set-visual-param)
               (lambda (_b _i _n v) (setq last-set v)))
              ((symbol-function 'cmacs-libregnum-editor--sync-panels)
               (lambda (&rest _) nil)))
      (cmacs-libregnum-editor--ctx-toggle-wireframe buf 0)
      (should (= last-set 0.0)))))

(ert-deftest cmacs-libregnum-tests-cast-shadow-toggle-logic ()
  "Cast-shadow toggle flips 1.0->0.0 and 0.0->1.0 (default is on)."
  (let ((buf (current-buffer))
        (last-set nil))
    ;; Default 1.0 (shadow on) -> toggling sets to 0.0.
    (cl-letf (((symbol-function 'cmacs-libregnum-editor-get-visual-param)
               (lambda (_b _i _n _d) 1.0))
              ((symbol-function 'cmacs-libregnum-editor-set-visual-param)
               (lambda (_b _i _n v) (setq last-set v)))
              ((symbol-function 'cmacs-libregnum-editor--sync-panels)
               (lambda (&rest _) nil)))
      (cmacs-libregnum-editor--ctx-toggle-cast-shadow buf 0)
      (should (= last-set 0.0)))
    ;; 0.0 (shadow off) -> toggling sets to 1.0.
    (setq last-set nil)
    (cl-letf (((symbol-function 'cmacs-libregnum-editor-get-visual-param)
               (lambda (_b _i _n _d) 0.0))
              ((symbol-function 'cmacs-libregnum-editor-set-visual-param)
               (lambda (_b _i _n v) (setq last-set v)))
              ((symbol-function 'cmacs-libregnum-editor--sync-panels)
               (lambda (&rest _) nil)))
      (cmacs-libregnum-editor--ctx-toggle-cast-shadow buf 0)
      (should (= last-set 1.0)))))

(ert-deftest cmacs-libregnum-tests-context-menu-keymap-all-kinds-new ()
  "The full keymap builds without error for all kinds including new items."
  (dolist (ksym '(group primitive mesh light camera audio tilemap sprite prefab))
    (let* ((items  (cmacs-libregnum-editor--filter-menu-items ksym))
           (km     (cmacs-libregnum-editor--menu-keymap
                    items (current-buffer) 0))
           (leaves (cmacs-libregnum-tests--menu-keymap-leaves km)))
      (should (keymapp km))
      (should-not (memq nil
                        (mapcar (lambda (l) (functionp (cdr l)))
                                leaves))))))

;;; ── Popup menu backend dispatch (native vs --lrg tmm fallback) ──────

(ert-deftest cmacs-libregnum-tests-lrg-frame-p ()
  "`cmacs-libregnum--lrg-frame-p' is nil off an lrg frame, t on one."
  (should-not (cmacs-libregnum--lrg-frame-p))
  ;; Simulate an lrg frame: framep returns the backend symbol.
  (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg)))
    (should (cmacs-libregnum--lrg-frame-p))))

(ert-deftest cmacs-libregnum-tests-popup-menu-lrg-in-engine ()
  "Under --lrg, `cmacs-libregnum-popup-menu' uses the in-engine `lrg-popup-menu'
and maps the returned item index back to the chosen item's VALUE -- so the
context-menu callers, which funcall the returned closure, keep working."
  (skip-unless (fboundp 'lrg-popup-menu))
  (let* ((menu '("Title" ("" ("Item A" . a) ("Item B" . b))))
         (got nil))
    (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg))
              ((symbol-function 'lrg-popup-menu)
               (lambda (items &optional _x _y) (setq got items) 1)))  ; pick idx 1
      (should (eq (cmacs-libregnum-popup-menu t menu) 'b))
      ;; Flattened to the nested tree: leaves as (LABEL . INDEX).
      (should (equal got '(("Item A" . 0) ("Item B" . 1)))))
    ;; A dismissed menu (nil index) yields nil.
    (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg))
              ((symbol-function 'lrg-popup-menu) (lambda (&rest _) nil)))
      (should (null (cmacs-libregnum-popup-menu t menu))))))

(ert-deftest cmacs-libregnum-tests-popup-menu-native-off-lrg ()
  "Off an lrg frame, `cmacs-libregnum-popup-menu' uses the native popup."
  (let ((menu '("Title" ("" ("Item A" . a)))))
    (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'pgtk))
              ((symbol-function 'x-popup-menu)
               (lambda (_pos _menu) 'native-value)))
      (should (eq (cmacs-libregnum-popup-menu t menu) 'native-value)))))

(ert-deftest cmacs-libregnum-tests-alist-menu-flatten ()
  "Alist menus flatten to a tree of (LABEL . INDEX) leaves + a value vector."
  ;; Single empty-titled pane: leaves with indices, in-pane separators kept.
  (let ((r (cmacs-libregnum--alist-menu-to-lrg
            '("T" ("" ("A" . fa) ("--") ("B" . fb))))))
    (should (equal (car r) '(("A" . 0) nil ("B" . 1))))
    (should (equal (cdr r) [fa fb])))
  ;; Multiple panes are joined by a separator row (no header text).
  (let ((r (cmacs-libregnum--alist-menu-to-lrg
            '("T" ("Sec1" ("A" . 10)) ("Sec2" ("B" . 20))))))
    (should (equal (car r) '(("A" . 0) nil ("B" . 1))))
    (should (equal (cdr r) [10 20]))))

(ert-deftest cmacs-libregnum-tests-keymap-menu-flatten ()
  "A menu keymap flattens to (LABEL . INDEX) leaf nodes with closure values."
  (let ((km (make-sparse-keymap)))
    (define-key km [a] '(menu-item "Alpha" (lambda () 'A)))
    (define-key km [b] '(menu-item "Beta"  (lambda () 'B)))
    (let* ((r (cmacs-libregnum--keymap-menu-to-lrg km))
           (tree (car r))
           (vals (append (cdr r) nil)))
      ;; Two leaf nodes (LABEL . integer-index).
      (should (= 2 (seq-count (lambda (it) (and (consp it) (integerp (cdr it))))
                              tree)))
      (should (= (length vals) 2))
      (should (seq-every-p #'functionp vals)))))

(ert-deftest cmacs-libregnum-tests-keymap-submenu-flatten ()
  "Submenus become real nested nodes (LABEL CHILD...), not inlined headers;
leaf indices span parent + submenu and round-trip through the value vector."
  (let ((km (make-sparse-keymap)) (sub (make-sparse-keymap)))
    (define-key sub [x] '(menu-item "X" (lambda () 'X)))
    (define-key sub [y] '(menu-item "Y" (lambda () 'Y)))
    (define-key km [a] '(menu-item "Alpha" (lambda () 'A)))
    (define-key km [s] (list 'menu-item "Sub" sub))
    (let* ((r (cmacs-libregnum--keymap-menu-to-lrg km))
           (tree (car r))
           (vals (cdr r))
           ;; submenu node = a cons whose cdr is a list (children), not an int.
           (subnode (seq-find (lambda (it) (and (consp it) (consp (cdr it))))
                              tree)))
      (should (= (length vals) 3))                 ; Alpha + X + Y
      (should (seq-every-p #'functionp (append vals nil)))
      (should subnode)
      (should (equal (car subnode) "Sub"))
      (should (= 2 (length (cdr subnode))))         ; X, Y children
      (should (seq-every-p (lambda (c) (and (consp c) (integerp (cdr c))))
                           (cdr subnode)))
      ;; Every leaf index across the whole tree is a valid VALS slot.
      (should (functionp (aref vals (cdr (car (cdr subnode)))))))))

(ert-deftest cmacs-libregnum-tests-collapse-separators ()
  "Runs of separators collapse to one; leading/trailing trimmed; recurses."
  ;; consecutive + leading + trailing separators -> single internal one
  (should (equal (cmacs-libregnum--collapse-separators
                  '(nil ("A" . 0) nil nil ("B" . 1) nil))
                 '(("A" . 0) nil ("B" . 1))))
  ;; all-separator list collapses to empty
  (should (equal (cmacs-libregnum--collapse-separators '(nil nil)) nil))
  ;; recurse into a submenu node's children (cdr is a list)
  (should (equal (cmacs-libregnum--collapse-separators
                  '(("Sub" ("X" . 0) nil nil ("Y" . 1))))
                 '(("Sub" ("X" . 0) nil ("Y" . 1))))))

(ert-deftest cmacs-libregnum-tests-menu-xy ()
  "POSITION parsing for the in-engine menu: explicit point vs mouse fallback."
  (should (equal (cmacs-libregnum--menu-xy '((10 20) some-frame)) '(10 . 20)))
  (should (equal (cmacs-libregnum--menu-xy t) (cons nil nil))))

(ert-deftest cmacs-libregnum-tests-evil-normal-state-no-evil ()
  "`cmacs-libregnum-evil-normal-state' is a harmless no-op without Evil."
  (skip-unless (not (fboundp 'evil-normal-state)))
  (should-not (cmacs-libregnum-evil-normal-state)))

(provide 'cmacs-libregnum-tests)
;;; cmacs-libregnum-tests.el ends here
