;;; cmacs-imgedit-menu-tests.el --- imgedit right-click menu tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the context-built right-click menu of the image editor, and
;; for the shared builder in cmacs-media-menu.el it is made with.
;;
;; The menu is built for synthetic click contexts against a REAL headless
;; document (the cmacs-imgedit-* DEFUNs need no display), its items and
;; their enabled state are asserted, and a handful of items are run to
;; prove the model actually changed.  The display paths are covered by
;; standing in for the two popup primitives: `x-popup-menu' (pgtk) and
;; `lrg-popup-menu' (--lrg), so the test proves both receive the same
;; menu and that the chosen entry runs.
;;
;; Gated on the primitives (`cmacs-imgedit-new'), never on a feature
;; name: the builder tests need no imgedit at all and always run.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-media-menu)
(require 'cmacs-imgedit nil t)

;;;; Helpers ------------------------------------------------------------

(defmacro cmacs-imgedit-menu-tests--skip-unless ()
  "Skip unless the imgedit primitives are compiled in."
  '(skip-unless (and (fboundp 'cmacs-imgedit-new)
                     (fboundp 'cmacs-imgedit-context-menu-keymap))))

(defmacro cmacs-imgedit-menu-tests--with-editor (spec &rest body)
  "Run BODY in an imgedit buffer over a fresh document.
SPEC is (HANDLE-VAR W H).  The buffer is not displayed and opens no
panels; menu items run synchronously."
  (declare (indent 1))
  (let ((h (nth 0 spec)))
    `(let ((,h (cmacs-imgedit-new ,(nth 1 spec) ,(nth 2 spec)))
           (buf (generate-new-buffer " *imgedit-menu-test*"))
           (cmacs-media-menu--defer nil)
           (cmacs-media-menu-use-context-menu-mode nil)
           (cmacs-imgedit-confirm-layer-delete nil))
       (unwind-protect
           (with-current-buffer buf
             (cmacs-imgedit-mode)
             (setq cmacs-imgedit--handle ,h)
             ,@body)
         (with-current-buffer buf (setq cmacs-imgedit--handle nil))
         (kill-buffer buf)
         (ignore-errors (cmacs-imgedit-free ,h))))))

(defun cmacs-imgedit-menu-tests--menu (&rest ctx-args)
  "The menu keymap for a context built from CTX-ARGS in this buffer."
  (cmacs-imgedit-context-menu-keymap
   (apply #'cmacs-imgedit-menu-context ctx-args)))

(defun cmacs-imgedit-menu-tests--enabled (map &rest path)
  "Enabled state of the entry at PATH in MAP; fail if it is missing."
  (let ((e (apply #'cmacs-media-menu-lookup map path)))
    (should e)
    (plist-get e :enabled)))

(defun cmacs-imgedit-menu-tests--run (map &rest path)
  "Run the leaf at PATH in MAP (it must exist and be enabled)."
  (let ((e (apply #'cmacs-media-menu-lookup map path)))
    (should e)
    (should (plist-get e :enabled))
    (funcall (plist-get e :binding))))

(defun cmacs-imgedit-menu-tests--event-path (map label)
  "The event path to the top-level or nested leaf LABEL in MAP."
  (catch 'found
    (map-keymap
     (lambda (ev def)
       (when (and (consp def) (eq (car def) 'menu-item))
         (cond
          ((equal (nth 1 def) label) (throw 'found (list ev)))
          ((keymapp (nth 2 def))
           (let ((sub (cmacs-imgedit-menu-tests--event-path (nth 2 def) label)))
             (when sub (throw 'found (cons ev sub))))))))
     map)
    nil))

(defun cmacs-imgedit-menu-tests--tree-index (tree label)
  "Leaf index of LABEL in an `lrg-popup-menu' TREE, or nil."
  (catch 'found
    (dolist (node tree)
      (cond
       ((and (consp node) (equal (car node) label) (integerp (cdr node)))
        (throw 'found (cdr node)))
       ((and (consp node) (consp (cdr node)))
        (let ((i (cmacs-imgedit-menu-tests--tree-index (cdr node) label)))
          (when i (throw 'found i))))))
    nil))

;;;; The shared builder (no imgedit needed) ------------------------------

(defvar cmacs-media-menu-tests--hook nil
  "Scratch provider hook for the builder tests.")

(ert-deftest cmacs-media-menu-test-providers-compose ()
  "Providers contribute in hook order; :in targets a submenu by :id."
  (let ((cmacs-media-menu-tests--hook nil))
    (add-hook 'cmacs-media-menu-tests--hook
              (lambda (_c) '((:id tools :label "Tools"
                              :items ((:label "Brush" :action ignore))))))
    (add-hook 'cmacs-media-menu-tests--hook
              (lambda (_c) '((:in tools :label "Spray" :action ignore)
                             (:label "Later" :action ignore)))
              90)
    (let* ((ctx (list :buffer (current-buffer)))
           (map (cmacs-media-menu-keymap
                 "T" (cmacs-media-menu-collect 'cmacs-media-menu-tests--hook
                                               ctx)
                 ctx)))
      (should (equal (cmacs-media-menu-labels map) '("Tools" "Later")))
      (should (cmacs-media-menu-lookup map "Tools" "Brush"))
      (should (cmacs-media-menu-lookup map "Tools" "Spray")))))

(ert-deftest cmacs-media-menu-test-orphan-in-lands-on-top ()
  "An :in item whose submenu never appears is kept, at the top level."
  (let* ((ctx (list :buffer (current-buffer)))
         (map (cmacs-media-menu-keymap
               "T" '((:label "A" :action ignore)
                     (:in nowhere :label "Kept" :action ignore))
               ctx)))
    (should (equal (cmacs-media-menu-labels map) '("A" "Kept")))))

(ert-deftest cmacs-media-menu-test-enable-visible-and-pruning ()
  ":enable/:visible may be functions of the context; empty submenus and
stray separators disappear."
  (let* ((ctx (list :buffer (current-buffer) :flag nil))
         (map (cmacs-media-menu-keymap
               "T"
               `((:sep)
                 (:label "Off" :enable ,(lambda (c) (plist-get c :flag))
                  :action ignore)
                 (:sep) (:sep)
                 (:label "Gone" :visible nil :action ignore)
                 (:label "Empty" :items ((:label "x" :visible nil
                                          :action ignore)))
                 (:label "On" :action ignore)
                 (:sep))
               ctx))
         (tree (car (cmacs-menu-keymap-to-tree map))))
    (should (equal (cmacs-media-menu-labels map) '("Off" "On")))
    (should-not (cmacs-imgedit-menu-tests--enabled map "Off"))
    (should (cmacs-imgedit-menu-tests--enabled map "On"))
    ;; One separator between the two, none at either end.
    (should (equal (mapcar (lambda (n) (and n (car n))) tree)
                   '("Off" nil "On")))))

(ert-deftest cmacs-media-menu-test-failing-provider-costs-only-itself ()
  "A provider that signals loses its own items, not the whole menu."
  (let ((cmacs-media-menu-tests--hook nil)
        (inhibit-message t))
    (add-hook 'cmacs-media-menu-tests--hook
              (lambda (_c) '((:label "Survivor" :action ignore))))
    (add-hook 'cmacs-media-menu-tests--hook
              (lambda (_c) (error "Provider exploded")) 90)
    (should (equal (mapcar (lambda (i) (plist-get i :label))
                           (cmacs-media-menu-collect
                            'cmacs-media-menu-tests--hook nil))
                   '("Survivor")))))

(ert-deftest cmacs-media-menu-test-leaf-runs-in-context-buffer ()
  "A chosen leaf runs in the context's buffer with the context bound,
whichever buffer is current when it is chosen."
  (let* ((target (generate-new-buffer " *mm-target*"))
         (seen nil)
         (ctx (list :buffer target :tag 'hello))
         (map (cmacs-media-menu-keymap
               "T" `((:label "Go"
                      :action ,(lambda (c)
                                 (setq seen (list (current-buffer)
                                                  (plist-get c :tag)
                                                  cmacs-media-menu-context)))))
               ctx)))
    (unwind-protect
        (with-temp-buffer
          (funcall (plist-get (cmacs-media-menu-lookup map "Go") :binding))
          (should (eq (nth 0 seen) target))
          (should (eq (nth 1 seen) 'hello))
          (should (eq (nth 2 seen) ctx)))
      (kill-buffer target))))

;;;; Menus for synthetic click contexts ---------------------------------

(ert-deftest cmacs-imgedit-menu-test-layer-under-pointer ()
  "The menu is about the layer PAINTED under the pointer, not the
active one, and its layer entries are enabled from the real stack."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 8 8)
    (cmacs-imgedit-fill h 0 0 255 255)                 ; layer 0: blue
    (cmacs-imgedit-add-layer h "Top")
    (cmacs-imgedit-set-active-layer h 1)
    (cmacs-imgedit-set-pixel h 2 2 255 0 0 255)        ; layer 1: one dot
    (cmacs-imgedit-set-active-layer h 0)               ; active: bottom
    ;; On the dot: layer 1, though layer 0 is active.
    (let ((map (cmacs-imgedit-menu-tests--menu 2 2)))
      (should (cmacs-media-menu-lookup map "Layer 1: Top"))
      (should (cmacs-imgedit-menu-tests--enabled map "Select"))
      (should (cmacs-imgedit-menu-tests--enabled map "Merge down"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Move up"))
      (should (cmacs-imgedit-menu-tests--enabled map "Move down"))
      (should (cmacs-imgedit-menu-tests--enabled map "Delete layer…"))
      (should (cmacs-media-menu-lookup map "Opacity" "100% (current)"))
      (should (cmacs-media-menu-lookup map "Blend mode" "Normal (current)"))
      (should (cmacs-imgedit-menu-tests--enabled map "Tools" "Pick colour here")))
    ;; Off the dot: the bottom layer shows through, so it is layer 0.
    (let ((map (cmacs-imgedit-menu-tests--menu 6 6)))
      (should (cmacs-media-menu-lookup map "Layer 0: Layer 1"))
      (should (cmacs-media-menu-lookup map "Select (active)"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Select (active)"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Merge down"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Move down")))
    ;; The hit test must leave every layer's visibility as it found it.
    (should (cmacs-imgedit-layer-visible-p h 0))
    (should (cmacs-imgedit-layer-visible-p h 1))))

(ert-deftest cmacs-imgedit-menu-test-keyboard-context ()
  "Opened without a pixel (keyboard, panel), the menu is about the
active layer and pixel-anchored entries are disabled."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 8 8)
    (cmacs-imgedit-add-layer h "Top")
    (cmacs-imgedit-set-active-layer h 1)
    (let ((map (cmacs-imgedit-menu-tests--menu nil nil 'keyboard)))
      (should (cmacs-media-menu-lookup map "Layer 1: Top"))
      (should-not (cmacs-imgedit-menu-tests--enabled
                   map "Tools" "Pick colour here"))
      (should-not (cmacs-imgedit-menu-tests--enabled
                   map "Select" "Magic wand here"))
      (should-not (cmacs-imgedit-menu-tests--enabled
                   map "Draw" "Flood fill here")))))

(ert-deftest cmacs-imgedit-menu-test-nothing-undoable ()
  "Undo/Redo are enabled from the model's real history."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (let ((map (cmacs-imgedit-menu-tests--menu 1 1)))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Undo"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Redo")))
    (cmacs-imgedit-push-undo h)
    (cmacs-imgedit-fill h 255 0 0 255)
    (let ((map (cmacs-imgedit-menu-tests--menu 1 1)))
      (should (cmacs-imgedit-menu-tests--enabled map "Undo"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Redo"))
      ;; Running Undo from the menu reverts the model...
      (cmacs-imgedit-menu-tests--run map "Undo"))
    (should-not (equal (cmacs-imgedit-pixel-at h 1 1) '(255 0 0 255)))
    ;; ...and a rebuilt menu now offers Redo.
    (should (cmacs-imgedit-menu-tests--enabled
             (cmacs-imgedit-menu-tests--menu 1 1) "Redo"))))

(ert-deftest cmacs-imgedit-menu-test-selection-and-lock-state ()
  "Selection entries follow the selection; pixel edits follow the lock."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 8 8)
    (let ((map (cmacs-imgedit-menu-tests--menu nil nil 'keyboard)))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Select" "Deselect"))
      (should-not (cmacs-imgedit-menu-tests--enabled
                   map "Transform" "Crop to selection"))
      (should (cmacs-imgedit-menu-tests--enabled map "Adjust" "Invert")))
    (cmacs-imgedit-select-rect h 1 1 3 3)
    (cmacs-imgedit-set-layer-locked h 0 t)
    (let ((map (cmacs-imgedit-menu-tests--menu nil nil 'keyboard)))
      (should (cmacs-imgedit-menu-tests--enabled map "Select" "Deselect"))
      (should (cmacs-imgedit-menu-tests--enabled
               map "Transform" "Crop to selection"))
      (should (cmacs-media-menu-lookup map "Unlock"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Adjust" "Invert"))
      (should-not (cmacs-imgedit-menu-tests--enabled map "Filter" "Sharpen")))))

(ert-deftest cmacs-imgedit-menu-test-hook-adds-items ()
  "`cmacs-imgedit-context-menu-functions' is the extension point: a
provider adds a top-level item and extends a built-in submenu."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (let ((cmacs-imgedit-context-menu-functions
           (copy-sequence cmacs-imgedit-context-menu-functions))
          (ran nil))
      (add-hook 'cmacs-imgedit-context-menu-functions
                (lambda (ctx)
                  `((:label "Count layers"
                     :action ,(lambda (c)
                                (setq ran (cmacs-imgedit-n-layers
                                           (plist-get c :handle)))))
                    (:in filter :label "My filter" :action ignore
                     :enable ,(plist-get ctx :layer-hit))))
                95)
      (let ((map (cmacs-imgedit-menu-tests--menu nil nil 'keyboard)))
        (should (member "Count layers" (cmacs-media-menu-labels map)))
        (should (cmacs-media-menu-lookup map "Filter" "My filter"))
        (should-not (cmacs-imgedit-menu-tests--enabled
                     map "Filter" "My filter"))
        (cmacs-imgedit-menu-tests--run map "Count layers")
        (should (eql ran 1))))))

(ert-deftest cmacs-imgedit-menu-test-ai-registers-through-the-hook ()
  "The AI entries arrive through the hook, gated on the C DEFUN that
says AI is built -- never on `fboundp' of lazily loaded Elisp."
  (cmacs-imgedit-menu-tests--skip-unless)
  (skip-unless (locate-library "cmacs-imgedit-ai"))
  (require 'cmacs-imgedit-ai)
  (should (memq 'cmacs-imgedit-ai-context-menu-items
                cmacs-imgedit-context-menu-functions))
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (cl-letf (((symbol-function 'cmacs-ai-supported-p) (lambda () t)))
      (let ((map (cmacs-imgedit-menu-tests--menu nil nil 'keyboard)))
        (should (cmacs-media-menu-lookup map "AI" "Edit by instruction…"))
        (should (cmacs-media-menu-lookup map "AI" "Describe this image"))))
    (cl-letf (((symbol-function 'cmacs-ai-supported-p) (lambda () nil)))
      (should-not (member "AI" (cmacs-media-menu-labels
                                (cmacs-imgedit-menu-tests--menu
                                 nil nil 'keyboard)))))))

;;;; Display paths --------------------------------------------------------

(ert-deftest cmacs-imgedit-menu-test-lrg-and-pgtk-get-the-same-menu ()
  "--lrg and pgtk are handed the same menu, and the pick runs.
Under --lrg `x-popup-menu' is a silent no-op, so the in-engine
`lrg-popup-menu' must receive the flattened tree; under pgtk
`x-popup-menu' gets the keymap itself.  Both trees must agree."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 1)
    (cmacs-imgedit-set-pixel h 0 0 255 0 0 255)
    (let* ((ctx (cmacs-imgedit-menu-context 0 0))
           ;; What each path should be handed, built before anything runs
           ;; (running an item changes the state, and so the menu).
           (want (car (cmacs-menu-keymap-to-tree
                       (cmacs-imgedit-context-menu-keymap ctx))))
           (want2 nil) (lrg-tree nil) (gtk-tree nil))
      ;; --lrg: pick "Flip horizontal" by its leaf index.
      (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg))
                ((symbol-function 'lrg-popup-menu)
                 (lambda (tree &rest _)
                   (setq lrg-tree tree)
                   (cmacs-imgedit-menu-tests--tree-index
                    tree "Flip horizontal"))))
        (cmacs-media-menu-show ctx #'cmacs-imgedit-context-menu-keymap
                               (list '(10 10) (selected-frame))))
      (should (equal (cmacs-imgedit-pixel-at h 3 0) '(255 0 0 255)))
      ;; pgtk, same context: pick it again (flipping back) by event path.
      (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'pgtk))
                ((symbol-function 'x-popup-menu)
                 (lambda (_pos map)
                   (setq gtk-tree (car (cmacs-menu-keymap-to-tree map)))
                   (cmacs-imgedit-menu-tests--event-path
                    map "Flip horizontal"))))
        (setq want2 (car (cmacs-menu-keymap-to-tree
                          (cmacs-imgedit-context-menu-keymap ctx))))
        (cmacs-media-menu-show ctx #'cmacs-imgedit-context-menu-keymap
                               (list '(10 10) (selected-frame))))
      (should (equal (cmacs-imgedit-pixel-at h 0 0) '(255 0 0 255)))
      (should (equal lrg-tree want))
      (should (equal gtk-tree want2))
      ;; Same entries in the same places; only Undo's state moved on.
      (should (equal (mapcar #'car-safe lrg-tree)
                     (mapcar #'car-safe gtk-tree))))))

(ert-deftest cmacs-imgedit-menu-test-context-menu-mode-path ()
  "With `context-menu-mode' on, the menu goes through `context-menu-map'
-- via the buffer-local `context-menu-functions' -- and still runs."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (set-window-buffer (selected-window) (current-buffer))
    (should (equal context-menu-functions
                   '(cmacs-imgedit--context-menu-function)))
    (let ((cmacs-media-menu-use-context-menu-mode t)
          (context-menu-mode t)
          (popped nil))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat fn &rest args) (apply fn args)))
                ((symbol-function 'framep) (lambda (&rest _) 'lrg))
                ((symbol-function 'lrg-popup-menu)
                 (lambda (tree &rest _)
                   (setq popped tree)
                   (cmacs-imgedit-menu-tests--tree-index tree "Line"))))
        (cmacs-media-menu-show (cmacs-imgedit-menu-context nil nil 'keyboard)
                               #'cmacs-imgedit-context-menu-keymap
                               (cmacs-media-menu-position)))
      (should popped)
      (should (eq cmacs-imgedit--tool 'line)))))

(ert-deftest cmacs-imgedit-menu-test-bindings ()
  "mouse-3 on the canvas beats emulation maps; the menu key opens it."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (cmacs-imgedit--render)
    (let* ((shadow (make-sparse-keymap))
           (emulation-mode-map-alists
            (cons (list (cons t shadow)) emulation-mode-map-alists)))
      (define-key shadow [down-mouse-3] #'ignore)
      (should (eq (key-binding [down-mouse-3] nil nil (point-min))
                  'cmacs-imgedit-context-menu)))
    (should (eq (lookup-key cmacs-imgedit-mode-map [menu])
                'cmacs-imgedit-context-menu-at-point))
    (should (eq (lookup-key cmacs-imgedit-mode-map [S-f10])
                'cmacs-imgedit-context-menu-at-point))))

(ert-deftest cmacs-imgedit-menu-test-click-context-from-events ()
  "A real click resolves to a context: the canvas pixel and the layer
painted there, or the layers-panel row that was clicked."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 64 64)
    (cmacs-imgedit-add-layer h "Top")
    (let* ((canvas (current-buffer))
           (win (selected-window))
           (panel (generate-new-buffer " *imgedit-menu-panel*")))
      (unwind-protect
          (progn
            (set-window-buffer win canvas)
            ;; Canvas: the existing mouse tests' posn shape; -> pixel 32,32.
            (let* ((posn (list win 1 (cons 256 256) 0 nil 1 (cons 1 1) nil
                               (cons 256 256) (cons 512 512)))
                   (ctx (cmacs-imgedit--click-context
                         (list 'down-mouse-3 posn))))
              (should (eq (plist-get ctx :buffer) canvas))
              (should (equal (list (plist-get ctx :x) (plist-get ctx :y))
                             '(32 32)))
              (should (eq (plist-get ctx :source) 'canvas)))
            ;; Layers panel: a click on layer 0's row.
            (with-current-buffer panel
              (special-mode)
              (setq-local cmacs-imgedit--canvas-buffer canvas)
              (cmacs-imgedit--build-layers-panel canvas)
              (cmacs-imgedit--claim-panel-mouse-3))
            (set-window-buffer win panel)
            (let* ((pos (with-current-buffer panel
                          (text-property-any (point-min) (point-max)
                                             'cmacs-imgedit-layer 0)))
                   (posn (list win pos (cons 0 0) 0 nil pos (cons 0 0) nil
                               (cons 0 0) (cons 1 1)))
                   (ctx (cmacs-imgedit--click-context
                         (list 'down-mouse-3 posn))))
              (should pos)
              (should (eq (plist-get ctx :buffer) canvas))
              (should (eql (plist-get ctx :layer) 0))
              (should (eq (plist-get ctx :source) 'layers-panel))
              ;; The row's mouse-3 reaches the menu; so do the gaps.
              (with-current-buffer panel
                (should (eq (key-binding [down-mouse-3] nil nil pos)
                            'cmacs-imgedit-context-menu))
                (should (eq (key-binding [down-mouse-3] nil nil (point-max))
                            'cmacs-imgedit-context-menu)))))
        (set-window-buffer win canvas)
        (kill-buffer panel)))))

;;;; Items run against the real model ------------------------------------

(ert-deftest cmacs-imgedit-menu-test-layer-items-change-the-model ()
  "Hide, opacity, blend, adjust-on-clicked-layer and delete all reach
the document."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (cmacs-imgedit-fill h 100 100 100 255)
    (cmacs-imgedit-add-layer h "Top")
    (cmacs-imgedit-set-active-layer h 1)
    (cmacs-imgedit-set-pixel h 0 0 10 20 30 255)
    (cmacs-imgedit-menu-tests--run (cmacs-imgedit-menu-tests--menu 0 0)
                                   "Opacity" "50%")
    (should (< (abs (- (cmacs-imgedit-layer-opacity h 1) 0.5)) 0.001))
    (cmacs-imgedit-menu-tests--run (cmacs-imgedit-menu-tests--menu 0 0)
                                   "Blend mode" "Multiply")
    (should (= (cmacs-imgedit-layer-blend h 1) 3))
    ;; Adjust acts on the layer CLICKED (layer 0 at 3,3) and selects it.
    (cmacs-imgedit-menu-tests--run (cmacs-imgedit-menu-tests--menu 3 3)
                                   "Adjust" "Invert")
    (should (= (cmacs-imgedit-active-layer h) 0))
    (cmacs-imgedit-set-layer-visible h 1 nil)
    (should (equal (cmacs-imgedit-pixel-at h 3 3) '(155 155 155 255)))
    (cmacs-imgedit-set-layer-visible h 1 t)
    (cmacs-imgedit-menu-tests--run (cmacs-imgedit-menu-tests--menu 0 0) "Hide")
    (should-not (cmacs-imgedit-layer-visible-p h 1))
    (cmacs-imgedit-menu-tests--run
     (cmacs-imgedit-menu-tests--menu nil nil 'layers-panel 1)
     "Delete layer…")
    (should (= (cmacs-imgedit-n-layers h) 1))))

(ert-deftest cmacs-imgedit-menu-test-merge-down ()
  "Merge down composites the pair into one layer in the lower slot."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 4)
    (cmacs-imgedit-set-layer-name h 0 "Base")
    (cmacs-imgedit-fill h 0 255 0 255)                 ; base: green
    (cmacs-imgedit-add-layer h "Ink")
    (cmacs-imgedit-set-active-layer h 1)
    (cmacs-imgedit-set-pixel h 1 1 255 0 0 255)        ; ink: one red dot
    (cmacs-imgedit-add-layer h "Above")                ; untouched, stays
    (cmacs-imgedit-menu-tests--run (cmacs-imgedit-menu-tests--menu 1 1)
                                   "Merge down")
    (should (= (cmacs-imgedit-n-layers h) 2))
    (should (equal (cmacs-imgedit-layer-name h 0) "Base"))
    (should (equal (cmacs-imgedit-layer-name h 1) "Above"))
    (should (= (cmacs-imgedit-active-layer h) 0))
    ;; Layer 0 alone now holds both: red dot over green.
    (cmacs-imgedit-set-layer-visible h 1 nil)
    (should (equal (cmacs-imgedit-pixel-at h 1 1) '(255 0 0 255)))
    (should (equal (cmacs-imgedit-pixel-at h 2 2) '(0 255 0 255)))))

(ert-deftest cmacs-imgedit-menu-test-tool-and-transform-items ()
  "Tool choices set editor state; transforms change the document."
  (cmacs-imgedit-menu-tests--skip-unless)
  (cmacs-imgedit-menu-tests--with-editor (h 4 2)
    (let ((map (cmacs-imgedit-menu-tests--menu nil nil 'keyboard)))
      (cmacs-imgedit-menu-tests--run map "Tools" "Rectangle")
      (cmacs-imgedit-menu-tests--run map "Tools" "Brush size" "8 px"))
    (should (eq cmacs-imgedit--tool 'rectangle))
    (should (= cmacs-imgedit--brush-size 8))
    (should (cmacs-media-menu-lookup (cmacs-imgedit-menu-tests--menu 0 0)
                                     "Tools" "Rectangle (current)"))
    (cmacs-imgedit-menu-tests--run (cmacs-imgedit-menu-tests--menu 0 0)
                                   "Transform" "Rotate 90° clockwise")
    (should (= (cmacs-imgedit-width h) 2))
    (should (= (cmacs-imgedit-height h) 4))))

(provide 'cmacs-imgedit-menu-tests)

;;; cmacs-imgedit-menu-tests.el ends here
