;;; cmacs-secondbrain.el --- The ARMS second-brain visualiser  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `M-x cmacs-secondbrain' draws your agentic workspace as four
;; concentric rings -- Applications, Routines, Memory, Skills -- around a
;; centre, as a live libregnum scene inside a cmacs buffer.
;;
;; The question it answers is operational.  roamgraph answers "how are my
;; notes linked?"; this answers "what does my system consist of?".  An
;; application you no longer use is standing trust you have not revoked;
;; a routine you have forgotten is unattended automation; a skill you
;; cannot see is one you will rewrite.
;;
;; Data comes from `cmacs-secondbrain-sources'; the rings, glyphs and
;; camera are C.  The shared graph engine is cmacs/graphcore, which
;; roamgraph also uses -- layouts, tweening and collapse arrive in both.
;;
;; Two views, one scene: `cmacs-secondbrain' is flat with orbit locked,
;; `cmacs-secondbrain-3d' frees the camera.  Both are perspective; see
;; the C side for why orthographic is unusable here.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-para)
(require 'cmacs-secondbrain-sources)

(declare-function cmacs-secondbrain-supported-p "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-attach "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-detach "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-set-graph "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-node-at "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-node-count "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-visible-count "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-set-layout "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-layout-kind "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-tween-step "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-tweening-p "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-layout-step "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-set-spin "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-set-collapsed "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-collapse-all "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-collapsed-p "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-set-projection "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-apply-flags "cmacs-secondbrain-defuns")
(declare-function cmacs-secondbrain-fit "cmacs-secondbrain-defuns")
(declare-function cmacs-libregnum-set-animated "cmacs-libregnum")
(declare-function cmacs-libregnum-popup-menu "cmacs-libregnum")
(declare-function cmacs-libregnum-set-match-set "cmacs-libregnum")
(declare-function cmacs-libregnum-focus-node "cmacs-libregnum")
(declare-function cmacs-ai-menu-scene-items "cmacs-ai-menu")

;;;; Customisation ----------------------------------------------------

(defcustom cmacs-secondbrain-buffer-name "*second brain*"
  "Name of the second-brain viewport buffer."
  :type 'string
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-default-size '(1200 . 800)
  "Initial framebuffer size, as (WIDTH . HEIGHT) in pixels."
  :type '(cons integer integer)
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-transition-frames 24
  "Frames a layout change, expand or collapse animates over.

0 switches instantly.  Animating is not decoration: a change that
teleports every node gives the eye no way to follow which node went
where, which is the whole reason to have a map."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-fps 30
  "Frames per second while a transition is in flight."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-default-layout 'rings
  "Layout used when the view opens.

`rings' is the ARMS layout and the reason this subsystem exists."
  :type '(choice (const rings) (const circle) (const hex) (const force))
  :group 'cmacs-secondbrain)

;;;; Buffer-local state -----------------------------------------------

(defvar-local cmacs-secondbrain--3d nil
  "Non-nil when this buffer is showing the free 3D view.")
(defvar-local cmacs-secondbrain--graph nil
  "The last collected (:nodes ... :edges ...) plist.")
(defvar-local cmacs-secondbrain--selected nil
  "Id string of the selected node, or nil.")
(defvar-local cmacs-secondbrain--anim-timer nil
  "Timer driving an in-flight transition.")
(defvar-local cmacs-secondbrain--spin 0.0
  "Current ring spin, in radians.")
(defvar-local cmacs-secondbrain--search nil
  "Active search string, or nil.")

;;;; Animation --------------------------------------------------------

(defun cmacs-secondbrain--stop-animation ()
  "Cancel any in-flight transition timer for the current buffer."
  (when (timerp cmacs-secondbrain--anim-timer)
    (cancel-timer cmacs-secondbrain--anim-timer))
  (setq cmacs-secondbrain--anim-timer nil)
  ;; Dropping the animation clock is best-effort: this also runs from
  ;; `kill-buffer-hook', by which point the view may already be gone --
  ;; and libregnum signals rather than shrugging when asked about a
  ;; buffer with no view.  An error there would escape the kill.
  (when (and (fboundp 'cmacs-libregnum-set-animated)
             (fboundp 'cmacs-secondbrain-attached-p)
             (ignore-errors (cmacs-secondbrain-attached-p (current-buffer))))
    (ignore-errors (cmacs-libregnum-set-animated (current-buffer) nil))))

(defun cmacs-secondbrain--animate ()
  "Drive the current transition to completion, then stop.

Stepped from a repeating timer rather than solved in one go: the point
of the animation is that it is watchable.  Equally, a permanently hot
render clock once it has settled is pure waste, so the timer cancels
itself -- and drops the libregnum animation clock with it."
  (let ((buf (current-buffer)))
    (cmacs-secondbrain--stop-animation)
    (when (fboundp 'cmacs-libregnum-set-animated)
      (cmacs-libregnum-set-animated buf t cmacs-secondbrain-fps))
    (setq cmacs-secondbrain--anim-timer
          (run-with-timer
           0.03 0.03
           (lambda ()
             (if (not (buffer-live-p buf))
                 (ignore)
               (with-current-buffer buf
                 (when (cmacs-secondbrain-tween-step buf)
                   (cmacs-secondbrain--stop-animation)))))))))

;;;; Data -------------------------------------------------------------

(defun cmacs-secondbrain-refresh ()
  "Re-read every enabled source and rebuild the graph."
  (interactive)
  (let ((buf (current-buffer)))
    (message "cmacs-secondbrain: reading…")
    (let* ((g (cmacs-secondbrain-collect))
           (nodes (plist-get g :nodes))
           (edges (plist-get g :edges)))
      (setq cmacs-secondbrain--graph g)
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vconcat edges)
                                   (if cmacs-secondbrain--3d 3 2))
      (cmacs-secondbrain-set-layout buf cmacs-secondbrain-default-layout 0)
      (cmacs-secondbrain-fit buf)
      (message "cmacs-secondbrain: %d nodes (%d shown), %d links"
               (length nodes)
               (or (cmacs-secondbrain-visible-count buf) 0)
               (length edges)))))

;;;; Layout -----------------------------------------------------------

(defun cmacs-secondbrain-set-layout-interactive (kind)
  "Switch the layout to KIND, animated."
  (interactive
   (list (intern (completing-read "Layout: " '("rings" "circle" "hex" "force")
                                  nil t nil nil "rings"))))
  (cmacs-secondbrain-set-layout (current-buffer) kind
                                cmacs-secondbrain-transition-frames)
  (if (eq kind 'force)
      ;; The solver needs stepping, not tweening.
      (let ((buf (current-buffer)))
        (cmacs-secondbrain--stop-animation)
        (when (fboundp 'cmacs-libregnum-set-animated)
          (cmacs-libregnum-set-animated buf t cmacs-secondbrain-fps))
        (setq cmacs-secondbrain--anim-timer
              (run-with-timer
               0.03 0.03
               (lambda ()
                 (if (not (buffer-live-p buf))
                     (ignore)
                   (with-current-buffer buf
                     (when (cmacs-secondbrain-layout-step buf 8)
                       (cmacs-secondbrain--stop-animation)
                       (cmacs-secondbrain-fit buf))))))))
    (cmacs-secondbrain--animate))
  (message "Layout: %s" kind))

(defun cmacs-secondbrain-layout-rings () (interactive)
  (cmacs-secondbrain-set-layout-interactive 'rings))
(defun cmacs-secondbrain-layout-circle () (interactive)
  (cmacs-secondbrain-set-layout-interactive 'circle))
(defun cmacs-secondbrain-layout-hex () (interactive)
  (cmacs-secondbrain-set-layout-interactive 'hex))
(defun cmacs-secondbrain-layout-force () (interactive)
  (cmacs-secondbrain-set-layout-interactive 'force))

(defun cmacs-secondbrain-spin (delta)
  "Rotate the rings by DELTA radians."
  (interactive (list 0.15))
  (setq cmacs-secondbrain--spin (+ cmacs-secondbrain--spin delta))
  (cmacs-secondbrain-set-spin (current-buffer) cmacs-secondbrain--spin 0))

(defun cmacs-secondbrain-spin-back ()
  "Rotate the rings the other way."
  (interactive)
  (cmacs-secondbrain-spin -0.15))

;;;; Selection and collapse -------------------------------------------

(defun cmacs-secondbrain--select (id)
  "Select node ID and report it."
  (setq cmacs-secondbrain--selected id)
  (when id
    (let ((node (cmacs-secondbrain-node-at (current-buffer) id)))
      (when node
        (message "%s%s"
                 (or (plist-get node :title) id)
                 (let ((c (plist-get node :department)))
                   (if c (format "  [%s]" c) "")))))))

(defun cmacs-secondbrain-toggle-collapse ()
  "Fold or unfold the selected node's subtree."
  (interactive)
  (unless cmacs-secondbrain--selected (user-error "Nothing selected"))
  (let* ((buf (current-buffer))
         (id cmacs-secondbrain--selected)
         (now (cmacs-secondbrain-collapsed-p buf id)))
    (if (cmacs-secondbrain-set-collapsed buf id (not now)
                                         cmacs-secondbrain-transition-frames)
        (cmacs-secondbrain--animate)
      (message "Nothing to expand there"))))

(defun cmacs-secondbrain-expand-all ()
  "Expand every department."
  (interactive)
  (cmacs-secondbrain-collapse-all (current-buffer) nil
                                  cmacs-secondbrain-transition-frames)
  (cmacs-secondbrain--animate))

(defun cmacs-secondbrain-collapse-all-cmd ()
  "Collapse every department."
  (interactive)
  (cmacs-secondbrain-collapse-all (current-buffer) t
                                  cmacs-secondbrain-transition-frames)
  (cmacs-secondbrain--animate))

;;;; Search -----------------------------------------------------------

(defun cmacs-secondbrain--match-ids (query)
  "Return ids whose title or path contains QUERY, case-insensitively."
  (let ((needle (downcase query)) (out nil))
    (dolist (n (plist-get cmacs-secondbrain--graph :nodes))
      (let ((hay (downcase (concat (or (plist-get n :title) "") " "
                                   (or (plist-get n :file) "")))))
        (when (string-search needle hay)
          (push (plist-get n :id) out))))
    (nreverse out)))

(defun cmacs-secondbrain-search (query)
  "Highlight nodes matching QUERY, dimming the rest.

Substring first, always: most of what you look for you already know the
name of, and a name match costs nothing.  `cmacs-secondbrain-search-semantic'
is the tier above."
  (interactive "sSearch: ")
  (setq cmacs-secondbrain--search (and (not (string-empty-p query)) query))
  (let ((ids (if cmacs-secondbrain--search
                 (cmacs-secondbrain--match-ids query)
               nil)))
    (cmacs-secondbrain--flag-ids ids)
    (message "%d match%s" (length ids) (if (= 1 (length ids)) "" "es"))))

(defun cmacs-secondbrain--flag-ids (ids)
  "Mark IDS as matches, dimming everything else."
  (when (fboundp 'cmacs-libregnum-set-match-set)
    ;; One bulk call, not one per node: the difference between a usable
    ;; incremental search and an unusable one.
    (cmacs-libregnum-set-match-set (current-buffer) ids (and ids t)))
  (cmacs-secondbrain-apply-flags (current-buffer)))

(defun cmacs-secondbrain-search-clear ()
  "Clear the search highlight."
  (interactive)
  (setq cmacs-secondbrain--search nil)
  (cmacs-secondbrain--flag-ids nil))

;;;; Visiting ---------------------------------------------------------

(defun cmacs-secondbrain-visit (&optional other-window)
  "Open the selected node's file.  With OTHER-WINDOW, in another window."
  (interactive "P")
  (unless cmacs-secondbrain--selected (user-error "Nothing selected"))
  (let* ((node (cmacs-secondbrain-node-at (current-buffer)
                                          cmacs-secondbrain--selected))
         (file (plist-get node :file)))
    (unless file (user-error "%s has no file" (or (plist-get node :title) "Node")))
    (if other-window (find-file-other-window file) (find-file file))))

(defun cmacs-secondbrain-copy-path ()
  "Copy the selected node's path to the kill ring."
  (interactive)
  (let* ((node (cmacs-secondbrain-node-at (current-buffer)
                                          cmacs-secondbrain--selected))
         (file (plist-get node :file)))
    (unless file (user-error "No path"))
    (kill-new file)
    (message "%s" file)))

;;;; Mode -------------------------------------------------------------

(defvar-keymap cmacs-secondbrain-mode-map
  :doc "Keymap for `cmacs-secondbrain-mode'."
  "1" #'cmacs-secondbrain-layout-force
  "2" #'cmacs-secondbrain-layout-circle
  "3" #'cmacs-secondbrain-layout-hex
  "4" #'cmacs-secondbrain-layout-rings
  "TAB" #'cmacs-secondbrain-toggle-collapse
  "e" #'cmacs-secondbrain-expand-all
  "c" #'cmacs-secondbrain-collapse-all-cmd
  "/" #'cmacs-secondbrain-search
  "?" #'cmacs-secondbrain-search-semantic
  "n" #'cmacs-secondbrain-search-clear
  "~" #'cmacs-secondbrain-find-similar
  "RET" #'cmacs-secondbrain-visit
  "O" (lambda () (interactive) (cmacs-secondbrain-visit t))
  "y" #'cmacs-secondbrain-copy-path
  "g" #'cmacs-secondbrain-refresh
  "0" #'cmacs-secondbrain-fit-cmd
  "s" #'cmacs-secondbrain-spin
  "S" #'cmacs-secondbrain-spin-back
  "v" #'cmacs-secondbrain-toggle-view
  "q" #'quit-window)

(defun cmacs-secondbrain-fit-cmd ()
  "Frame the whole graph."
  (interactive)
  (cmacs-secondbrain-fit (current-buffer)))

(defun cmacs-secondbrain-toggle-view ()
  "Switch between the flat and free 3D views."
  (interactive)
  (setq cmacs-secondbrain--3d (not cmacs-secondbrain--3d))
  (cmacs-secondbrain-set-projection (current-buffer)
                                    (not cmacs-secondbrain--3d))
  (message "%s view" (if cmacs-secondbrain--3d "3D" "Flat")))

(defun cmacs-secondbrain--ml-counts ()
  "Mode-line fragment: node counts."
  (let ((buf (current-buffer)))
    (condition-case nil
        (format "  %d/%d"
                (or (cmacs-secondbrain-visible-count buf) 0)
                (or (cmacs-secondbrain-node-count buf) 0))
      (error ""))))

(define-derived-mode cmacs-secondbrain-mode cmacs-libregnum-mode "SecondBrain"
  "Major mode for the ARMS second-brain viewport.

Deriving from `cmacs-libregnum-mode' inherits the view attach, the
teardown, the Evil `C-w' handoff and `<escape>'.

\\{cmacs-secondbrain-mode-map}"
  ;; Runtime require, not a top-level one: cmacs-secondbrain-search.el
  ;; reads this file's buffer-locals, so the dependency has to resolve
  ;; after this file has finished loading.
  (require 'cmacs-secondbrain-search)
  ;; Registers the AI actions.  Runtime require for the same reason, and
  ;; because an action registry that is only populated once someone opens
  ;; the view is exactly when it is needed.
  (require 'cmacs-secondbrain-ai)
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (setq-local mode-line-format
              '(" second brain  "
                (:eval (if cmacs-secondbrain--3d "3D" "2D"))
                (:eval (cmacs-secondbrain--ml-counts))
                "  [1-4]layout [TAB]expand [/]find [RET]open [g]refresh"))
  (add-hook 'kill-buffer-hook #'cmacs-secondbrain--on-kill nil t))

(defun cmacs-secondbrain--on-kill ()
  "Tear the view down with the buffer."
  (cmacs-secondbrain--stop-animation)
  (ignore-errors (cmacs-secondbrain-detach (current-buffer))))

;;;; Pick dispatch ----------------------------------------------------

(defun cmacs-secondbrain--on-pick (buffer _id _vx _vy path)
  "Handle a click on node PATH in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cmacs-secondbrain--select
       (and (stringp path) (> (length path) 0) path)))))

;;;; Context menu -----------------------------------------------------

(defun cmacs-secondbrain--menu-items (id)
  "Return (LABEL . THUNK) menu entries for node ID, nil for separators.

Entries adapt to the node's :kind, because the useful action differs
entirely: for an application the question is what it can reach, for a
routine it is when it runs, for a file it is open it."
  (let* ((buf (current-buffer))
         (node (and id (cmacs-secondbrain-node-at buf id)))
         (kind (plist-get node :kind))
         (file (plist-get node :file))
         (items nil))
    (when node
      (push (cons (format "── %s ──" (or (plist-get node :title) id)) #'ignore)
            items)
      (push nil items)
      (pcase kind
        ('hub
         (push (cons (if (cmacs-secondbrain-collapsed-p buf id)
                         "Expand" "Collapse")
                     (lambda () (cmacs-secondbrain--select id)
                       (cmacs-secondbrain-toggle-collapse)))
               items))
        ((or 'file 'skill 'routine)
         (when file
           (push (cons "Open" (lambda () (cmacs-secondbrain--select id)
                                (cmacs-secondbrain-visit)))
                 items)
           (push (cons "Open in other window"
                       (lambda () (cmacs-secondbrain--select id)
                         (cmacs-secondbrain-visit t)))
                 items)))
        ('app
         ;; The trust question this ring exists to make askable.
         (push (cons "What can this reach?"
                     (lambda ()
                       (message "%s: %s" (plist-get node :title)
                                (or (plist-get node :department) "unknown"))))
               items)))
      (when file
        (push (cons "Copy path" (lambda () (cmacs-secondbrain--select id)
                                  (cmacs-secondbrain-copy-path)))
              items))
      (push nil items)
      (push (cons "Fly to" (lambda ()
                             (when (fboundp 'cmacs-libregnum-focus-node)
                               (cmacs-libregnum-focus-node buf id))))
            items)
      (push (cons "Find similar"
                  (lambda () (cmacs-secondbrain-find-similar id)))
            items))
    (push nil items)
    (push (cons "Expand all" #'cmacs-secondbrain-expand-all) items)
    (push (cons "Collapse all" #'cmacs-secondbrain-collapse-all-cmd) items)
    (push (cons "Refresh" #'cmacs-secondbrain-refresh) items)
    (nreverse items)))

(defun cmacs-secondbrain--context-menu (buffer id path _vx _vy)
  "Pop the context menu for the node identified by PATH in BUFFER."
  (ignore id)
  (when (buffer-live-p buffer)
    ;; Re-scheduled onto the command loop: this arrives on the cmacs
    ;; GMainContext, inside the pselect wait, and opening a nested GTK
    ;; menu loop there re-enters the event machinery.
    (run-with-timer
     0 nil
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((node-id (and (stringp path) (> (length path) 0) path)))
             ;; Select first: the AI section resolves against the
             ;; buffer's current target, which for a graph IS the
             ;; selection.
             (when node-id (cmacs-secondbrain--select node-id))
             (let* ((items (cmacs-secondbrain--menu-items node-id))
                    (items (append items
                                   (and (fboundp 'cmacs-ai-menu-scene-items)
                                        (cmacs-ai-menu-scene-items))))
                    (choice (and items
                                 (cmacs-libregnum-popup-menu
                                  buffer "Second brain" items))))
               (when (functionp choice) (funcall choice))))))))))

;;;; Entry points -----------------------------------------------------

(defun cmacs-secondbrain--open (dims)
  "Open (or reuse) the second-brain buffer, in DIMS dimensions."
  (unless (and (fboundp 'cmacs-secondbrain-supported-p)
               (cmacs-secondbrain-supported-p))
    (user-error "cmacs-secondbrain not built; reconfigure with \
--with-cmacs-secondbrain"))
  (let ((buf (get-buffer-create cmacs-secondbrain-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-secondbrain-mode)
        (cmacs-secondbrain-mode))
      (let ((sz cmacs-secondbrain-default-size))
        (cmacs-secondbrain-attach buf (car sz) (cdr sz)))
      (setq cmacs-secondbrain--3d (= dims 3))
      (cmacs-secondbrain-refresh))
    ;; Reuse the current window rather than splitting: the viewport is a
    ;; picture that wants all the room it can get.
    (pop-to-buffer-same-window buf)
    buf))

;;;###autoload
(defun cmacs-secondbrain ()
  "Show the ARMS second brain, flat.
See `cmacs-secondbrain-3d' for the free three-dimensional view."
  (interactive)
  (cmacs-secondbrain--open 2))

;;;###autoload
(defun cmacs-secondbrain-3d ()
  "Show the ARMS second brain in three dimensions.
Drag to orbit, scroll to zoom."
  (interactive)
  (cmacs-secondbrain--open 3))

(provide 'cmacs-secondbrain)

;;; cmacs-secondbrain.el ends here
