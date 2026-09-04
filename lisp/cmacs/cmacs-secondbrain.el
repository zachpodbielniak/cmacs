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
(declare-function cmacs-libregnum-resize "cmacs-libregnum")
(declare-function cmacs-libregnum-default-font-file "cmacs-libregnum")
(declare-function cmacs-libregnum-set-label-font "cmacs-libregnum")
(declare-function cmacs-libregnum-set-label-style "cmacs-libregnum")
(declare-function cmacs-libregnum-set-label-decor "cmacs-libregnum")
(declare-function cmacs-libregnum-set-right-drag-pans "cmacs-libregnum")
(declare-function cmacs-libregnum-set-wheel-up-zooms-in "cmacs-libregnum")
(declare-function cmacs-libregnum-set-selection-style "cmacs-libregnum")
(declare-function cmacs-libregnum-set-inscene-labels "cmacs-libregnum")
(declare-function cmacs-libregnum-set-background "cmacs-libregnum")
(declare-function cmacs-libregnum-set-focus-policy "cmacs-libregnum")
(declare-function cmacs-libregnum-particles-enable "cmacs-libregnum")
(declare-function cmacs-libregnum-particles-clear "cmacs-libregnum")
(declare-function cmacs-libregnum-particles-emitter "cmacs-libregnum")
(declare-function cmacs-libregnum-particles-burst "cmacs-libregnum")
(declare-function cmacs-para-color "cmacs-para")
(declare-function cmacs-screensaver-attach-background "cmacs-screensaver")
(declare-function cmacs-screensaver-detach-background "cmacs-screensaver")
(declare-function cmacs-screensaver-background-resize "cmacs-screensaver")
(declare-function cmacs-screensaver-supported-p "cmacs-screensaver")
(declare-function cmacs-libregnum-popup-menu "cmacs-libregnum")
(declare-function cmacs-libregnum-set-match-set "cmacs-libregnum")
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

(defcustom cmacs-secondbrain-start-collapsed nil
  "Whether departments start folded.

Nil -- the default -- opens the whole map: every ring shows its files
and the links between them, which is the view the thing exists to give
you.  Folding is then something you reach for on a department too big to
read, not the state you have to dig your way out of every time.

Set it to t on a very large tree, where drawing everything at once costs
more than it tells you."
  :type 'boolean
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-background 'screensaver
  "What fills the viewport behind the graph.

One of `none' (the flat default clear colour), `solid', `gradient',
`starfield', `nebula', `screensaver' -- a live screensaver from
`cmacs-secondbrain-screensaver', which falls back to `nebula' when the
screensaver subsystem is not built -- or `image', which draws
`cmacs-secondbrain-background-image', cover-fit so a wallpaper of any
shape fills the viewport without being squashed.

The procedural kinds are generated once into a texture and cached, so
they cost one blit per frame and nothing else.  They are also
deterministic: the same viewport gives the same sky every session, which
is both less distracting and what makes them testable."
  :type '(choice (const none) (const solid) (const gradient)
                 (const starfield) (const nebula) (const image)
                 (const screensaver))
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-screensaver 'blackhole-cool-orbit
  "Screensaver config drawn behind the graph when the background is
`screensaver'.

A name from `cmacs-screensaver-configs'.  It renders in the same
out-of-process renderer the animated wallpaper uses -- so none of its GL
runs on Emacs's thread -- and needs no gowl.

Pick a dark one.  The graph is drawn over the top of it, and a
screensaver that fills the frame with bright detail leaves the nodes
nowhere to be read against; `blackhole-cool-orbit' is pulled far enough
back to be mostly dark field."
  :type 'symbol
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-background-colors '(#x2A3A6BFF . #x05050AFF)
  "Top and bottom background colours, as 0xRRGGBBAA.
`solid' uses only the top; the rest blend down the viewport."
  :type '(cons integer integer)
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-background-image nil
  "Image file drawn behind the graph when the background is `image'."
  :type '(choice (const nil) file)
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-wallpaper-dirs
  '("~/Pictures/wallpapers" "~/Pictures" "~/.local/share/backgrounds")
  "Directories offered when picking a background image.

A convenience, not a restriction: the picker always accepts any path you
type, and a directory that does not exist is skipped rather than being
an error."
  :type '(repeat directory)
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-particle-fps 24
  "Redraw rate, in frames per second, kept up for particles alone.

Lower than `cmacs-secondbrain-fps': a transition is watched closely and
wants to be smooth, while ambient drift only has to not look like a
slideshow.  It is a standing cost on an otherwise idle buffer, which is
the honest price of the effect -- turn particles off and the clock stops
with them."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-fly-context 0.4
  "How much of the scene to keep in view when flying to a node.

A fraction of the whole graph's extent, used as a floor under the camera
distance.  Without it the distance comes from the clicked node's own
size, which says nothing about the scale of the graph around it: a file
sphere here is a fifth of a world unit in a graph seventy across, so the
camera ends up close enough to show that one dot and nothing else.

At the default the view holds a whole department plus its neighbours,
which is the scale at which \"fly to this\" is a useful answer."
  :type 'number
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-hover-highlights-group t
  "Whether hovering a node lights up everything in its department.

This is the cheapest way to answer \"what is in here?\" -- no click, no
state change, just move the pointer.  It is suppressed while a search is
active, because a search is a deliberate question and a stray pointer
movement must not silently answer a different one."
  :type 'boolean
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-particles t
  "Whether to draw ambient particles and event bursts.

Purely decorative, and deliberately so: nothing about the map's meaning
depends on them.  They are on because a system you are meant to feel
ownership of should look alive, and off is one setq away."
  :type 'boolean
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-label-size 15
  "Base on-screen height, in pixels, of an in-scene node label.

A base, not the final size: it is what you get in a viewport
`cmacs-secondbrain-label-reference-height' tall, and the drawn size
scales with the actual viewport from there.  A fixed pixel size cannot
be right for both a half-screen window and a maximised one on a large
display -- and since the framebuffer now tracks the window exactly, the
same number that reads well in one is unreadably small in the other."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-label-reference-height 800
  "Viewport height, in pixels, at which labels are drawn at their base size."
  :type 'integer
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-label-scale-max 2.2
  "Most that viewport size may enlarge a label.
A cap, because past a point bigger labels stop adding legibility and
start hiding the graph behind them."
  :type 'number
  :group 'cmacs-secondbrain)

(defcustom cmacs-secondbrain-max-labels 160
  "How many labels to draw at once.

A cap rather than \"all of them\": with every department expanded this
graph is over a thousand nodes, and a thousand labels is an unreadable
grey mat that also costs a screen-space pass each.  The nearest N to the
camera are drawn, so zooming in is what reveals names."
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
(defvar-local cmacs-secondbrain--resize-timer nil
  "Idle timer coalescing window size changes.")
(defvar-local cmacs-secondbrain--groups nil
  "Hash of group key -> list of node ids, for hover highlighting.
Precomputed at graph-build time because the hover handler runs on the
pointer's hot path and must not walk the node list.")
(defvar-local cmacs-secondbrain--group-of nil
  "Hash of node id -> its group key.")
(defvar-local cmacs-secondbrain--hovered nil
  "Group key currently lit by hover, or nil.")

;;;; View setup -------------------------------------------------------

(defun cmacs-secondbrain--fit-window-now (buf)
  "Resize BUF's framebuffer to its window's pixel size.

Mandatory, not cosmetic.  The framebuffer is blitted 1:1 across the
window rectangle, so a mismatch stretches the picture -- and, worse,
puts every click somewhere other than where it was aimed, because the
pick maps view pixels against the framebuffer's dimensions.  A view
that never fits its window is a view where nothing is clickable."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq cmacs-secondbrain--resize-timer nil)
      (let ((win (get-buffer-window buf t)))
        (when (window-live-p win)
          (let ((w (window-pixel-width win)) (h (window-pixel-height win)))
            (when (and (> w 1) (> h 1))
              (ignore-errors (cmacs-libregnum-resize buf w h))
              ;; The viewport just changed, so the scaled label size did
              ;; too -- this is the only place that knows that.
              (cmacs-secondbrain--apply-label-size buf h)
              ;; A screensaver renders at a fixed size in another
              ;; process, so it has to be told the new one or it stays
              ;; at whatever the window was when it started.
              (when (cmacs-secondbrain--screensaver-running-p)
                (ignore-errors (cmacs-screensaver-background-resize w h)))
              (ignore-errors (cmacs-secondbrain-fit buf)))))))))

(defun cmacs-secondbrain--on-size-change (&optional _frame)
  "Coalesce window size changes into one refit."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (derived-mode-p 'cmacs-secondbrain-mode)
                   (not cmacs-secondbrain--resize-timer))
          (setq cmacs-secondbrain--resize-timer
                (run-with-idle-timer
                 0.06 nil #'cmacs-secondbrain--fit-window-now buf)))))))

(defun cmacs-secondbrain--configure-view ()
  "Set up labels, selection marker and navigation for this buffer.

In-scene labels rather than the cairo overlay, because the overlay only
exists under pgtk and a map with no names under `emacs --lrg' would be
useless."
  (let ((buf (current-buffer)))
    (when (fboundp 'cmacs-libregnum-set-label-font)
      (let ((ff (and (fboundp 'cmacs-libregnum-default-font-file)
                     (cmacs-libregnum-default-font-file))))
        ;; Baked large and drawn smaller: downscaling through the
        ;; bilinear filter is what makes the text look right.  Baked at
        ;; 48 rather than 32 because the drawn size now scales with the
        ;; viewport, and a label drawn ABOVE the baked size is upscaled
        ;; -- which is exactly the blur this is meant to avoid.
        (when ff (ignore-errors (cmacs-libregnum-set-label-font buf ff 48)))))
    (cmacs-secondbrain--apply-label-size buf)
    (when (fboundp 'cmacs-libregnum-set-label-decor)
      ;; A plate behind the text -- edges run straight through it
      ;; otherwise -- and screen-space rings on selection and hover.
      (cmacs-libregnum-set-label-decor buf t t))
    (when (fboundp 'cmacs-libregnum-set-right-drag-pans)
      ;; Map profile: left-drag orbits (in 3D), right-drag moves the
      ;; view.  The default CAD profile puts panning on the middle
      ;; button, which plenty of pointing devices do not have.
      (cmacs-libregnum-set-right-drag-pans buf t))
    (when (fboundp 'cmacs-libregnum-set-wheel-up-zooms-in)
      (cmacs-libregnum-set-wheel-up-zooms-in buf t))
    (when (fboundp 'cmacs-libregnum-set-selection-style)
      ;; A halo, not the default wireframe cube: these are round.
      (cmacs-libregnum-set-selection-style buf 'halo))
    (when (fboundp 'cmacs-libregnum-set-inscene-labels)
      (cmacs-libregnum-set-inscene-labels buf t))
    (when (fboundp 'cmacs-libregnum-set-focus-policy)
      ;; A click must NOT fly the camera here.  Clicking a department
      ;; starts an animation worth watching, and the default behaviour
      ;; -- fly to whatever was hit -- lands the camera on top of the
      ;; hub before the fan has moved, so the thing the click was for is
      ;; the one thing you cannot see.  `f' flies deliberately instead,
      ;; and keeps `cmacs-secondbrain-fly-context' of the scene extent
      ;; between camera and node, so it frames the department rather
      ;; than filling the view with a dot.
      (cmacs-libregnum-set-focus-policy
       buf nil cmacs-secondbrain-fly-context))
    (cmacs-secondbrain--apply-background buf)))

(defun cmacs-secondbrain--viewport-height (buf)
  "Return BUF's viewport height in pixels.

Read off the window rather than the render context, because the
framebuffer is resized to match the window and the window is the thing
that exists first.  Falls back to the configured framebuffer height for
a buffer nobody is displaying yet."
  (let ((win (get-buffer-window buf t)))
    (or (and (window-live-p win) (window-pixel-height win))
        (cdr cmacs-secondbrain-default-size)
        cmacs-secondbrain-label-reference-height)))

(defun cmacs-secondbrain--label-px (&optional buf height)
  "Return the label pixel height to draw in BUF, scaled to its viewport.
HEIGHT overrides the measured viewport height."
  (let* ((buf (or buf (current-buffer)))
         (h (or height (cmacs-secondbrain--viewport-height buf)))
         (ref (max 1 cmacs-secondbrain-label-reference-height))
         (k (max 1.0 (min cmacs-secondbrain-label-scale-max
                          (/ (float h) ref)))))
    (max 8 (round (* cmacs-secondbrain-label-size k)))))

(defun cmacs-secondbrain--apply-label-size (&optional buf height)
  "Set BUF's label size from its viewport height (or HEIGHT)."
  (let ((buf (or buf (current-buffer))))
    (when (fboundp 'cmacs-libregnum-set-label-style)
      (ignore-errors
        (cmacs-libregnum-set-label-style
         buf (cmacs-secondbrain--label-px buf height)
         t t cmacs-secondbrain-max-labels)))))

(defun cmacs-secondbrain--screensaver-available-p ()
  "Return non-nil when a screensaver background can be started."
  (and (fboundp 'cmacs-screensaver-supported-p)
       (cmacs-screensaver-supported-p)
       (fboundp 'cmacs-screensaver-attach-background)))

(defun cmacs-secondbrain--apply-background (&optional buf)
  "Push the configured background into BUF's viewport."
  (let ((buf (or buf (current-buffer))))
    ;; The screensaver background is a live frame source rather than a
    ;; texture, so it goes through its own subsystem instead of
    ;; `cmacs-libregnum-set-background'.
    (if (eq cmacs-secondbrain-background 'screensaver)
        (cmacs-secondbrain--apply-screensaver-background buf)
      (when (cmacs-secondbrain--screensaver-running-p)
        (ignore-errors (cmacs-screensaver-detach-background buf)))
      (cmacs-secondbrain--apply-texture-background buf))))

(defvar-local cmacs-secondbrain--screensaver-on nil
  "Non-nil when this buffer has a screensaver background attached.")

(defun cmacs-secondbrain--screensaver-running-p ()
  "Return non-nil when this buffer has a screensaver background."
  (and cmacs-secondbrain--screensaver-on
       (fboundp 'cmacs-screensaver-detach-background)))

(defun cmacs-secondbrain--apply-screensaver-background (buf)
  "Start the configured screensaver behind BUF."
  (setq-local cmacs-secondbrain--screensaver-on nil)
  (if (not (cmacs-secondbrain--screensaver-available-p))
      (progn
        ;; Fall back rather than leaving a blank viewport: a missing
        ;; optional subsystem is not a reason to show nothing.
        (message "cmacs-secondbrain: screensaver support is not built; \
using the nebula background")
        (setq-local cmacs-secondbrain-background 'nebula)
        (cmacs-secondbrain--apply-texture-background buf))
    (let* ((win (get-buffer-window buf t))
           (w (if (window-live-p win) (window-pixel-width win)
                (car cmacs-secondbrain-default-size)))
           (h (if (window-live-p win) (window-pixel-height win)
                (cdr cmacs-secondbrain-default-size))))
      (condition-case err
          (progn
            (cmacs-screensaver-attach-background
             buf cmacs-secondbrain-screensaver (max 16 w) (max 16 h))
            (setq-local cmacs-secondbrain--screensaver-on t))
        (error
         (message "cmacs-secondbrain: %s; using the nebula background"
                  (error-message-string err))
         (setq-local cmacs-secondbrain-background 'nebula)
         (cmacs-secondbrain--apply-texture-background buf))))))

(defun cmacs-secondbrain--apply-texture-background (buf)
  "Push a non-screensaver background into BUF's viewport."
  (let ((buf (or buf (current-buffer))))
    (when (fboundp 'cmacs-libregnum-set-background)
      (unless (cmacs-libregnum-set-background
               buf cmacs-secondbrain-background
               (car cmacs-secondbrain-background-colors)
               (cdr cmacs-secondbrain-background-colors)
               (and (eq cmacs-secondbrain-background 'image)
                    cmacs-secondbrain-background-image
                    (expand-file-name cmacs-secondbrain-background-image)))
        ;; Only `image' can fail, and only on an unreadable path.  Say so
        ;; rather than leaving the user wondering why nothing changed.
        (message "cmacs-secondbrain: cannot read %s"
                 (or cmacs-secondbrain-background-image "(no image set)"))))))

(defun cmacs-secondbrain--wallpapers ()
  "Return image files found under `cmacs-secondbrain-wallpaper-dirs'."
  (let ((out nil))
    (dolist (d cmacs-secondbrain-wallpaper-dirs)
      (let ((dir (expand-file-name d)))
        (when (file-directory-p dir)
          (dolist (f (ignore-errors
                       (directory-files
                        dir t "\\.\\(png\\|jpe?g\\|bmp\\|tga\\)\\'" t)))
            (push f out)))))
    (nreverse out)))

(defun cmacs-secondbrain-set-background-interactive (kind)
  "Choose the viewport background.

Offers the procedural kinds plus `image', which then offers whatever is
in `cmacs-secondbrain-wallpaper-dirs' and still accepts any path you
type."
  (interactive
   (list (intern (completing-read
                  "Background: "
                  '("nebula" "starfield" "gradient" "solid" "screensaver"
                    "image" "none")
                  nil t nil nil
                  (symbol-name cmacs-secondbrain-background)))))
  (setq-local cmacs-secondbrain-background kind)
  (when (eq kind 'screensaver)
    (setq-local cmacs-secondbrain-screensaver
                (intern (completing-read
                         "Screensaver: "
                         (mapcar (lambda (c) (symbol-name (car c)))
                                 (bound-and-true-p cmacs-screensaver-configs))
                         nil nil
                         (symbol-name cmacs-secondbrain-screensaver)))))
  (when (eq kind 'image)
    (let* ((found (cmacs-secondbrain--wallpapers))
           (pick (completing-read
                  "Wallpaper: " found nil nil
                  (and cmacs-secondbrain-background-image
                       (expand-file-name
                        cmacs-secondbrain-background-image)))))
      (setq-local cmacs-secondbrain-background-image
                  (and (not (string-empty-p pick)) pick))))
  (cmacs-secondbrain--apply-background (current-buffer))
  (message "Background: %s" kind))

;;;; Animation --------------------------------------------------------

(defun cmacs-secondbrain--stop-animation (&optional hard)
  "Cancel any in-flight transition timer for the current buffer.

With HARD, drop the render clock unconditionally.  Without it the clock
survives when particles are on, because they need one.  Teardown must
pass HARD: re-arming a clock for a view that is about to be detached
leaves it flagged animated with nothing to draw."
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
    ;; But NOT while particles are drawing.  They advance on wall-clock
    ;; time inside the render pass, so a view that only redraws on input
    ;; would show them frozen mid-flight -- worse than not having them.
    (ignore-errors
      (if (and cmacs-secondbrain-particles (not hard))
          (cmacs-libregnum-set-animated (current-buffer) t
                                        cmacs-secondbrain-particle-fps)
        (cmacs-libregnum-set-animated (current-buffer) nil)))))

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
      (cmacs-secondbrain--configure-view)
      (cmacs-secondbrain-set-graph buf (vconcat nodes) (vconcat edges)
                                   (if cmacs-secondbrain--3d 3 2))
      ;; Open by default.  A map that shows only the folder names is
      ;; not showing you your second brain; it is showing you a table of
      ;; contents you then have to click your way through.
      (unless cmacs-secondbrain-start-collapsed
        (cmacs-secondbrain-collapse-all buf nil 0))
      (cmacs-secondbrain-set-layout buf cmacs-secondbrain-default-layout 0)
      (cmacs-secondbrain-fit buf)
      (cmacs-secondbrain--build-groups nodes)
      (setq cmacs-secondbrain--hovered nil)
      ;; After the scene, always: icons and emitters both key on world
      ;; positions and live in lists cleared with the drawables.
      (ignore-errors (cmacs-secondbrain-apply-icons buf nodes))
      (cmacs-secondbrain--particles-refresh buf nodes)
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
  "Select node ID, report it, and refresh any open pane."
  (setq cmacs-secondbrain--selected id)
  (cmacs-secondbrain--burst-at id)
  ;; An inspector showing the previous node is worse than no inspector:
  ;; it is confidently wrong about what you just clicked.
  (when (and (fboundp 'cmacs-secondbrain-inspector-render)
             (get-buffer-window "*second brain: inspector*"))
    (ignore-errors (cmacs-secondbrain-inspector-render)))
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
        (progn
          ;; Bigger and bluer than a selection burst: an expand moves the
          ;; whole department, and the burst is what marks where from.
          (cmacs-secondbrain--burst-at id #x8FD4FFFF 44)
          (cmacs-secondbrain--animate))
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

;;;; Hover ------------------------------------------------------------

(defun cmacs-secondbrain--build-groups (nodes)
  "Index NODES by department into the hover lookup tables."
  (setq cmacs-secondbrain--groups (make-hash-table :test 'equal)
        cmacs-secondbrain--group-of (make-hash-table :test 'equal))
  (dolist (n nodes)
    (let* ((ring (plist-get n :ring))
           (dept (plist-get n :department))
           (id   (plist-get n :id))
           ;; The centre belongs to no department; giving it one would
           ;; make hovering it light up an arbitrary ring.
           (key (and dept ring (format "%s/%s" ring dept))))
      (when (and key id)
        (puthash id key cmacs-secondbrain--group-of)
        (puthash key (cons id (gethash key cmacs-secondbrain--groups))
                 cmacs-secondbrain--groups)))))

(defun cmacs-secondbrain--on-hover (buffer _id path)
  "Light up the department under the pointer in BUFFER.

PATH is the node's id string, or nil when the pointer left every node.
Runs on the cmacs GMainContext on the pointer's hot path, so it does
exactly two hash lookups and one bulk flag call -- no node-list walk, no
consing per node, and nothing that can prompt."
  (when (and (buffer-live-p buffer) cmacs-secondbrain-hover-highlights-group)
    (with-current-buffer buffer
      ;; A search is a deliberate question; a stray pointer movement must
      ;; not silently replace its answer.
      (unless cmacs-secondbrain--search
        (let ((key (and path cmacs-secondbrain--group-of
                        (gethash path cmacs-secondbrain--group-of))))
          (unless (equal key cmacs-secondbrain--hovered)
            (setq cmacs-secondbrain--hovered key)
            (cmacs-secondbrain--flag-ids
             (and key (gethash key cmacs-secondbrain--groups)))))))))

;;;; Particles --------------------------------------------------------

(defun cmacs-secondbrain--particle-color (node)
  "Return the 0xRRGGBBAA particle colour for NODE."
  (or (and (fboundp 'cmacs-para-color)
           (plist-get node :bucket)
           (cmacs-para-color (plist-get node :bucket)))
      (pcase (plist-get node :ring)
        ('applications #x7FC8FFFF)
        ('routines     #x9C8FE0FF)
        ('memory       #x6FD98AFF)
        ('skills       #xE8A33DFF)
        (_             #xB0B8C8FF))))

(defun cmacs-secondbrain--particles-refresh (buf nodes)
  "Re-seed BUF's ambient emitters, one per department hub in NODES.

Emitters are attached to hubs only.  One per file would be a thousand
emitters fighting over a four-thousand particle budget, which looks like
nothing at all -- the departments are what should read as alive."
  (when (and cmacs-secondbrain-particles
             (fboundp 'cmacs-libregnum-particles-enable))
    (ignore-errors
      (cmacs-libregnum-particles-enable buf t)
      ;; Emitters are anchored at world positions, so a rebuild that
      ;; moved the hubs must drop the old ones.
      (cmacs-libregnum-particles-clear buf)
      ;; And keep a redraw clock up, or they are drawn once and freeze.
      (when (fboundp 'cmacs-libregnum-set-animated)
        (cmacs-libregnum-set-animated buf t cmacs-secondbrain-particle-fps))
      (dolist (n nodes)
        (when (eq (plist-get n :kind) 'hub)
          (let ((pos (cmacs-secondbrain-node-position buf (plist-get n :id))))
            (when pos
              (cmacs-libregnum-particles-emitter
               buf (nth 0 pos) (nth 1 pos) (nth 2 pos)
               ;; Bigger departments breathe wider and faster, so the
               ;; motion carries the same information the size does.
               (+ 0.5 (* 0.02 (sqrt (float (or (plist-get n :count) 1)))))
               (min 14.0 (+ 2.0 (* 0.4 (sqrt (float (or (plist-get n :count) 1))))))
               (cmacs-secondbrain--particle-color n)
               0.09))))))))

(defun cmacs-secondbrain--burst-at (id &optional color count)
  "Fire a particle burst at node ID, if particles are on."
  (when (and cmacs-secondbrain-particles id
             (fboundp 'cmacs-libregnum-particles-burst))
    (let* ((buf (current-buffer))
           (pos (ignore-errors (cmacs-secondbrain-node-position buf id))))
      (when pos
        (ignore-errors
          (cmacs-libregnum-particles-burst
           buf (nth 0 pos) (nth 1 pos) (nth 2 pos)
           (or count 28) (or color #xFFE58CFF) 0.14 3.0))))))

(defun cmacs-secondbrain-toggle-particles ()
  "Turn particle effects on or off for this buffer."
  (interactive)
  (setq-local cmacs-secondbrain-particles (not cmacs-secondbrain-particles))
  (if cmacs-secondbrain-particles
      (cmacs-secondbrain--particles-refresh
       (current-buffer) (plist-get cmacs-secondbrain--graph :nodes))
    (when (fboundp 'cmacs-libregnum-particles-enable)
      (ignore-errors (cmacs-libregnum-particles-enable (current-buffer) nil))))
  ;; Start or stop the standing render clock with them.
  (unless (timerp cmacs-secondbrain--anim-timer)
    (cmacs-secondbrain--stop-animation (not cmacs-secondbrain-particles)))
  (message "Particles %s" (if cmacs-secondbrain-particles "on" "off")))

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
  "i" #'cmacs-secondbrain-inspector
  "p" #'cmacs-secondbrain-preview
  "W" #'cmacs-secondbrain-close-panes
  "v" #'cmacs-secondbrain-toggle-view
  "f" #'cmacs-secondbrain-fly-to-selected
  "b" #'cmacs-secondbrain-set-background-interactive
  "P" #'cmacs-secondbrain-toggle-particles
  "H" #'cmacs-secondbrain-toggle-hover-highlight
  "q" #'quit-window)

(defun cmacs-secondbrain-toggle-hover-highlight ()
  "Turn hover department-highlighting on or off."
  (interactive)
  (setq-local cmacs-secondbrain-hover-highlights-group
              (not cmacs-secondbrain-hover-highlights-group))
  (unless cmacs-secondbrain-hover-highlights-group
    ;; Leaving the last hovered department lit would be worse than not
    ;; highlighting at all: it reads as a search nobody ran.
    (setq cmacs-secondbrain--hovered nil)
    (unless cmacs-secondbrain--search (cmacs-secondbrain--flag-ids nil)))
  (message "Hover highlight %s"
           (if cmacs-secondbrain-hover-highlights-group "on" "off")))

(defun cmacs-secondbrain-fly-to-selected ()
  "Fly the camera to the selected node.

Deliberate, because clicking does not: a click starts an animation and
moving the camera at the same time hides it."
  (interactive)
  (unless cmacs-secondbrain--selected (user-error "Nothing selected"))
  (unless (cmacs-secondbrain-focus (current-buffer)
                                   cmacs-secondbrain--selected)
    (user-error "That node is not on screen to fly to")))

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
  (require 'cmacs-secondbrain-panes)
  (setq-local cursor-type nil)
  (buffer-disable-undo)
  (setq-local mode-line-format
              '(" second brain  "
                (:eval (if cmacs-secondbrain--3d "3D" "2D"))
                (:eval (cmacs-secondbrain--ml-counts))
                "  [1-4]layout [TAB]expand [/]find [i]nspect [RET]open [g]refresh"))
  (add-hook 'kill-buffer-hook #'cmacs-secondbrain--on-kill nil t)
  (add-hook 'window-size-change-functions #'cmacs-secondbrain--on-size-change))

(defun cmacs-secondbrain--on-kill ()
  "Tear the view down with the buffer."
  (cmacs-secondbrain--stop-animation t)
  ;; The screensaver is a separate process rendering for this buffer;
  ;; killing the buffer without stopping it leaves it rendering frames
  ;; nobody will ever read.
  (when (cmacs-secondbrain--screensaver-running-p)
    (ignore-errors (cmacs-screensaver-detach-background (current-buffer))))
  (ignore-errors (cmacs-secondbrain-detach (current-buffer))))

;;;; Pick dispatch ----------------------------------------------------

(defun cmacs-secondbrain--on-pick (buffer _id _vx _vy path)
  "Handle a click on node PATH in BUFFER.

Clicking a department expands it, because that is the whole
interaction: the rings show you what exists and a click shows you what
is inside.  Making expand a second, separate keystroke would mean the
obvious gesture on the obvious target does nothing."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((id (and (stringp path) (> (length path) 0) path)))
        (cmacs-secondbrain--select id)
        (when id
          (let ((node (cmacs-secondbrain-node-at buffer id)))
            (when (eq (plist-get node :kind) 'hub)
              (cmacs-secondbrain-toggle-collapse))))))))

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
      ;; Was guarded on `cmacs-libregnum-focus-node', which does not
      ;; exist -- so this menu entry had always been a silent no-op.
      (push (cons "Fly to"
                  (lambda () (cmacs-secondbrain-focus buf id)))
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
             (let* ((node (and node-id
                               (cmacs-secondbrain-node-at buffer node-id)))
                    (title (or (plist-get node :title) "Second brain"))
                    (items (append (cmacs-secondbrain--menu-items node-id)
                                   (and (fboundp 'cmacs-ai-menu-scene-items)
                                        (cmacs-ai-menu-scene-items))))
                    ;; `cmacs-libregnum-popup-menu' takes (POSITION MENU),
                    ;; and MENU is an x-popup-menu alist: a title plus one
                    ;; pane of (LABEL . VALUE).  A nil item is a separator
                    ;; and must become ("--"), not stay nil.
                    (choice (and items
                                 (cmacs-libregnum-popup-menu
                                  t (list title
                                          (cons ""
                                                (mapcar (lambda (it)
                                                          (or it '("--")))
                                                        items)))))))
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
    ;; And fit the framebuffer to it, or nothing is clickable.
    (cmacs-secondbrain--fit-window-now buf)
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
