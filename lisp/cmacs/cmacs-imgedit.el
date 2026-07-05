;;; cmacs-imgedit.el --- 2D image / sprite editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A 2D raster image / sprite editor built on the cmacs-imgedit-* C primitives
;; (an LrgImageDocument with layers, blend modes, undo, and CPU drawing).
;;
;; This mode displays the composited document as a native Emacs image and
;; supports both command-driven editing and direct mouse painting.  It works
;; under pgtk and the terminal; an in-engine libregnum viewport (smooth
;; real-time brush + the GTK/lrg right-click menus) is a separate layer.
;;
;; The model is also fully scriptable / MCP-driveable through the
;; `cmacs-imgedit-*' primitives, independent of this UI.

;;; Code:

(require 'cl-lib)
(require 'cmacs-libregnum)  ; for cmacs-libregnum-popup-menu (GTK vs --lrg routing)

(defgroup cmacs-imgedit nil
  "2D image / sprite editor."
  :group 'cmacs
  :prefix "cmacs-imgedit-")

(defcustom cmacs-imgedit-default-width 64
  "Default width (px) for a new image."
  :type 'integer)

(defcustom cmacs-imgedit-default-height 64
  "Default height (px) for a new image."
  :type 'integer)

(defcustom cmacs-imgedit-default-zoom 8
  "Default integer zoom factor for the displayed image."
  :type 'integer)

(defcustom cmacs-imgedit-canvas-background "#bfbfbf"
  "Backdrop colour shown behind transparent canvas areas.
Without it a transparent canvas renders as the frame background, so dark
strokes are invisible on dark themes.  Set to nil for the frame background."
  :type '(choice (const :tag "Frame background" nil) color))

(defconst cmacs-imgedit--ui-version 5
  "Bumped when the interactive UI changes; shown in the header line so a
stale loaded copy of this file is recognisable at a glance.")

(defvar cmacs-imgedit-debug nil
  "When non-nil, log mouse-mapping diagnostics to *Messages*.")

(defvar-local cmacs-imgedit--handle nil
  "Opaque C handle for this buffer's image document.")
(defvar-local cmacs-imgedit--path nil
  "File the document was loaded from / last saved to.")
(defvar-local cmacs-imgedit--color '(0 0 0 255)
  "Current foreground colour as (R G B A), 0..255.")
(defvar-local cmacs-imgedit--brush-size 1
  "Brush / stroke thickness in pixels.")
(defvar-local cmacs-imgedit--zoom 8
  "Integer zoom factor for display.")
(defvar-local cmacs-imgedit--tool 'brush
  "Active tool: one of brush line rectangle circle fill eyedropper.")
(defvar-local cmacs-imgedit--shape-fill nil
  "When non-nil, the rectangle/circle tools fill instead of stroke.")
(defvar-local cmacs-imgedit--live nil
  "Non-nil when this buffer displays through a live libregnum GL viewport
instead of a native Emacs image.  Set at setup when a display + the
libregnum backend are available; nil falls back to the insert-image path.")
(defvar-local cmacs-imgedit--vp-prev nil
  "Previous document pixel of an in-progress viewport brush stroke.")
(defvar-local cmacs-imgedit--vp-start nil
  "Start document pixel of an in-progress viewport shape drag.")
(defvar-local cmacs-imgedit--canvas-buffer nil
  "In a panel buffer, the editor canvas buffer it controls.")
(defvar-local cmacs-imgedit--tools-panel nil
  "The tools/palette side-window buffer for this canvas.")
(defvar-local cmacs-imgedit--layers-panel nil
  "The layers side-window buffer for this canvas.")

(defconst cmacs-imgedit-tools
  '((brush      . "Brush")
    (line       . "Line")
    (arrow      . "Arrow")
    (rectangle  . "Rectangle")
    (circle     . "Circle")
    (ellipse    . "Ellipse")
    (text       . "Text")
    (fill       . "Bucket")
    (eyedropper . "Pick"))
  "Tools and their display labels.")

(defcustom cmacs-imgedit-text-size 16
  "Font height (px) used by the text tool."
  :type 'integer)

;; --------------------------------------------------------------------------
;; Rendering (composited document -> native Emacs image)
;; --------------------------------------------------------------------------

(defun cmacs-imgedit--checkerboard-p ()
  "Return non-nil if the display backend can show PNG images."
  (image-type-available-p 'png))

(defvar cmacs-imgedit--canvas-map (make-sparse-keymap)
  "Keymap applied as a text property over the rendered canvas.
A position `keymap' property outranks emulation maps (Evil state maps,
which bind down-mouse-1 to `evil-mouse-drag-region' under Doom) and
minor-mode maps (`context-menu-mode' binds down-mouse-3), so canvas
clicks reach the editor no matter what the surrounding config binds.")
;; Bound on every load, mutating the same object (the defvar body is a
;; no-op on reload) so already-rendered buffers pick up changes too.
(let ((map cmacs-imgedit--canvas-map))
  (define-key map [down-mouse-1] #'cmacs-imgedit-mouse-1)
  (define-key map [double-down-mouse-1] #'cmacs-imgedit-mouse-1)
  (define-key map [triple-down-mouse-1] #'cmacs-imgedit-mouse-1)
  ;; Swallow the stroke's residual click/drag events so Evil or global
  ;; bindings don't act on them after the tool handler returns.
  (define-key map [mouse-1] #'ignore)
  (define-key map [double-mouse-1] #'ignore)
  (define-key map [triple-mouse-1] #'ignore)
  (define-key map [drag-mouse-1] #'ignore)
  (define-key map [down-mouse-3] #'cmacs-imgedit-context-menu)
  (define-key map [mouse-3] #'ignore))

(defun cmacs-imgedit--render (&optional no-panels)
  "Redraw the buffer from the current document state.
With NO-PANELS non-nil, skip refreshing the side panels (used for fast
per-motion redraws while painting)."
  (when cmacs-imgedit--handle
    (if cmacs-imgedit--live
        ;; Live GL viewport: the document is bound zero-copy, so a refresh
        ;; re-flattens + re-uploads it and redraws the FBO -- no PNG encode,
        ;; no insert-image (the viewport blits over the whole window).
        (ignore-errors (cmacs-libregnum-image-refresh (current-buffer)))
      (let ((inhibit-read-only t)
            (png (cmacs-imgedit-export-png-bytes cmacs-imgedit--handle)))
        (erase-buffer)
        (if (cmacs-imgedit--checkerboard-p)
            (insert-image (apply #'create-image png 'png t
                                 :scale cmacs-imgedit--zoom
                                 :ascent 'center
                                 (and cmacs-imgedit-canvas-background
                                      (list :background
                                            cmacs-imgedit-canvas-background))))
          (insert (format "[%dx%d image; install PNG support to view]"
                          (cmacs-imgedit-width cmacs-imgedit--handle)
                          (cmacs-imgedit-height cmacs-imgedit--handle))))
        (insert "\n")
        ;; Claim the mouse over the whole canvas (replaces image.el's
        ;; `image-map' prop): a position keymap outranks Evil states and
        ;; context-menu-mode, which otherwise steal the clicks (Doom).
        (add-text-properties (point-min) (point-max)
                             (list 'keymap cmacs-imgedit--canvas-map))
        (goto-char (point-min))))
    (when (and (not no-panels) (fboundp 'cmacs-imgedit--refresh-panels))
      (cmacs-imgedit--refresh-panels))))

(defun cmacs-imgedit--event-doc-xy (event)
  "Return (X . Y) document pixel coords for mouse EVENT, clamped, or nil.

Scale-independent: the document pixel is derived from the click's fractional
position within the displayed image (object-x / object-width), so it is
correct regardless of how Emacs reports image pixel units for a scaled image.
Falls back to window-relative coordinates if the object geometry is missing."
  (when cmacs-imgedit--handle
    (let* ((posn (event-start event))
           (w (cmacs-imgedit-width cmacs-imgedit--handle))
           (h (cmacs-imgedit-height cmacs-imgedit--handle))
           (ox (ignore-errors (posn-object-x-y posn)))
           (wh (ignore-errors (posn-object-width-height posn)))
           (fx nil) (fy nil))
      (cond
       ;; Preferred: fraction within the image object (unit-agnostic).
       ((and ox wh (> (car wh) 0) (> (cdr wh) 0))
        (setq fx (/ (float (car ox)) (car wh))
              fy (/ (float (cdr ox)) (cdr wh))))
       ;; Fallback: window pixels minus the image's window origin, over the
       ;; displayed size (doc * zoom).
       (t
        (let* ((click (ignore-errors (posn-x-y posn)))
               (origin (ignore-errors (posn-x-y (posn-at-point (point-min)))))
               (zoom (max 1 cmacs-imgedit--zoom)))
          (when (and click origin)
            (setq fx (/ (float (- (car click) (car origin))) (* w zoom))
                  fy (/ (float (- (cdr click) (cdr origin))) (* h zoom)))))))
      (when cmacs-imgedit-debug
        (message "imgedit click: obj-xy=%s obj-wh=%s frac=(%s . %s)"
                 ox wh fx fy))
      (when (and fx fy)
        (cons (max 0 (min (1- w) (floor (* fx w))))
              (max 0 (min (1- h) (floor (* fy h)))))))))

;; --------------------------------------------------------------------------
;; Colour helpers
;; --------------------------------------------------------------------------

(defun cmacs-imgedit--apply-color ()
  "Push `cmacs-imgedit--color' to the document's draw colour."
  (apply #'cmacs-imgedit-set-color cmacs-imgedit--handle cmacs-imgedit--color))

(defun cmacs-imgedit-set-foreground-color (color)
  "Set the foreground COLOR (a name or #rrggbb), keeping current alpha."
  (interactive (list (read-color "Foreground colour: ")))
  (let ((rgb (color-values color)))
    (when rgb
      (setq cmacs-imgedit--color
            (list (/ (nth 0 rgb) 256) (/ (nth 1 rgb) 256) (/ (nth 2 rgb) 256)
                  (nth 3 cmacs-imgedit--color)))
      (cmacs-imgedit--apply-color)
      (message "Foreground: %s" cmacs-imgedit--color))))

(defun cmacs-imgedit-set-alpha (alpha)
  "Set the foreground ALPHA (0..255)."
  (interactive (list (read-number "Alpha (0..255): " 255)))
  (setf (nth 3 cmacs-imgedit--color) (max 0 (min 255 alpha)))
  (cmacs-imgedit--apply-color))

(defun cmacs-imgedit-set-brush-size (n)
  "Set the brush/stroke thickness to N pixels."
  (interactive (list (read-number "Brush size: " cmacs-imgedit--brush-size)))
  (setq cmacs-imgedit--brush-size (max 1 n)))

;; --------------------------------------------------------------------------
;; Drawing commands
;; --------------------------------------------------------------------------

(defun cmacs-imgedit--with-undo (fn)
  "Snapshot for undo, run FN, then re-render."
  (cmacs-imgedit-push-undo cmacs-imgedit--handle)
  (funcall fn)
  (cmacs-imgedit--render))

(defun cmacs-imgedit-fill-layer ()
  "Fill the active layer with the foreground colour."
  (interactive)
  (cmacs-imgedit--with-undo
   (lambda () (apply #'cmacs-imgedit-fill cmacs-imgedit--handle
                     cmacs-imgedit--color))))

(defun cmacs-imgedit-pencil (x y)
  "Set the pixel at X,Y to the foreground colour."
  (interactive (list (read-number "x: ") (read-number "y: ")))
  (cmacs-imgedit--with-undo
   (lambda () (apply #'cmacs-imgedit-set-pixel cmacs-imgedit--handle x y
                     cmacs-imgedit--color))))

(defun cmacs-imgedit-flood-fill-at (x y &optional tolerance)
  "Flood-fill from X,Y with the foreground colour and TOLERANCE."
  (interactive (list (read-number "x: ") (read-number "y: ")
                     (read-number "tolerance: " 0)))
  (cmacs-imgedit--with-undo
   (lambda () (apply #'cmacs-imgedit-flood-fill cmacs-imgedit--handle x y
                     (append cmacs-imgedit--color (list (or tolerance 0)))))))

(defun cmacs-imgedit-draw-line-cmd (x1 y1 x2 y2)
  "Draw a line from X1,Y1 to X2,Y2 in the foreground colour."
  (interactive (list (read-number "x1: ") (read-number "y1: ")
                     (read-number "x2: ") (read-number "y2: ")))
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit--with-undo
   (lambda () (cmacs-imgedit-draw-line cmacs-imgedit--handle x1 y1 x2 y2
                                       cmacs-imgedit--brush-size))))

(defun cmacs-imgedit-draw-rect-cmd (x y w h filled)
  "Draw rectangle X Y W H; FILLED with prefix arg."
  (interactive (list (read-number "x: ") (read-number "y: ")
                     (read-number "width: ") (read-number "height: ")
                     current-prefix-arg))
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit--with-undo
   (lambda () (cmacs-imgedit-draw-rect cmacs-imgedit--handle x y w h
                                       (and filled t)
                                       cmacs-imgedit--brush-size))))

(defun cmacs-imgedit-draw-circle-cmd (cx cy radius filled)
  "Draw circle centred CX CY of RADIUS; FILLED with prefix arg."
  (interactive (list (read-number "cx: ") (read-number "cy: ")
                     (read-number "radius: ") current-prefix-arg))
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit--with-undo
   (lambda () (cmacs-imgedit-draw-circle cmacs-imgedit--handle cx cy radius
                                         (and filled t)
                                         cmacs-imgedit--brush-size))))

(defun cmacs-imgedit-draw-arrow-cmd (x1 y1 x2 y2)
  "Draw an arrow from X1,Y1 to X2,Y2 (head at the end point)."
  (interactive (list (read-number "x1: ") (read-number "y1: ")
                     (read-number "x2: ") (read-number "y2: ")))
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit--with-undo
   (lambda () (cmacs-imgedit-draw-arrow cmacs-imgedit--handle x1 y1 x2 y2
                                        cmacs-imgedit--brush-size))))

(defun cmacs-imgedit-draw-ellipse-cmd (cx cy rx ry filled)
  "Draw an ellipse centred CX CY with radii RX RY; FILLED with prefix arg."
  (interactive (list (read-number "cx: ") (read-number "cy: ")
                     (read-number "rx: ") (read-number "ry: ")
                     current-prefix-arg))
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit--with-undo
   (lambda () (cmacs-imgedit-draw-ellipse cmacs-imgedit--handle cx cy rx ry
                                          (and filled t)
                                          cmacs-imgedit--brush-size))))

(defun cmacs-imgedit-draw-text-cmd (x y text)
  "Draw TEXT at X,Y in the foreground colour (`cmacs-imgedit-text-size')."
  (interactive (list (read-number "x: ") (read-number "y: ")
                     (read-string "Text: ")))
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit--with-undo
   (lambda () (cmacs-imgedit-draw-text cmacs-imgedit--handle x y text
                                       cmacs-imgedit-text-size))))

(defun cmacs-imgedit-eyedropper (x y)
  "Pick the foreground colour from the pixel at X,Y."
  (interactive (list (read-number "x: ") (read-number "y: ")))
  (let ((px (cmacs-imgedit-pixel-at cmacs-imgedit--handle x y)))
    (when px
      (setq cmacs-imgedit--color px)
      (cmacs-imgedit--apply-color)
      (message "Picked %s" px))))

;; --------------------------------------------------------------------------
;; Tool selection
;; --------------------------------------------------------------------------

(defun cmacs-imgedit-set-tool (tool)
  "Set the active TOOL (a symbol from `cmacs-imgedit-tools')."
  (interactive
   (list (intern (completing-read
                  "Tool: " (mapcar (lambda (c) (symbol-name (car c)))
                                   cmacs-imgedit-tools)
                  nil t))))
  (setq cmacs-imgedit--tool tool)
  (cmacs-imgedit--refresh-panels)
  (force-mode-line-update)
  (message "Tool: %s" (alist-get tool cmacs-imgedit-tools)))

(defun cmacs-imgedit-use-brush () (interactive) (cmacs-imgedit-set-tool 'brush))
(defun cmacs-imgedit-use-line () (interactive) (cmacs-imgedit-set-tool 'line))
(defun cmacs-imgedit-use-arrow () (interactive) (cmacs-imgedit-set-tool 'arrow))
(defun cmacs-imgedit-use-rectangle () (interactive)
       (cmacs-imgedit-set-tool 'rectangle))
(defun cmacs-imgedit-use-circle () (interactive)
       (cmacs-imgedit-set-tool 'circle))
(defun cmacs-imgedit-use-ellipse () (interactive)
       (cmacs-imgedit-set-tool 'ellipse))
(defun cmacs-imgedit-use-text () (interactive) (cmacs-imgedit-set-tool 'text))
(defun cmacs-imgedit-use-bucket () (interactive) (cmacs-imgedit-set-tool 'fill))
(defun cmacs-imgedit-use-eyedropper () (interactive)
       (cmacs-imgedit-set-tool 'eyedropper))

(defun cmacs-imgedit-set-text-size (n)
  "Set the text tool's font height to N pixels."
  (interactive (list (read-number "Text size (px): " cmacs-imgedit-text-size)))
  (setq cmacs-imgedit-text-size (max 4 n))
  (cmacs-imgedit--refresh-panels))

(defun cmacs-imgedit-toggle-shape-fill ()
  "Toggle whether the rectangle/circle tools fill or stroke."
  (interactive)
  (setq cmacs-imgedit--shape-fill (not cmacs-imgedit--shape-fill))
  (cmacs-imgedit--refresh-panels)
  (message "Shapes: %s" (if cmacs-imgedit--shape-fill "filled" "outline")))

;; --------------------------------------------------------------------------
;; Mouse interaction (tool-aware: drag shapes, continuous brush, click ops)
;; --------------------------------------------------------------------------

(defun cmacs-imgedit--brush-dab (xy)
  "Paint a single brush dab (current colour/size) at XY on the active layer."
  (if (> cmacs-imgedit--brush-size 1)
      (cmacs-imgedit-draw-circle cmacs-imgedit--handle (car xy) (cdr xy)
                                 (max 1 (/ cmacs-imgedit--brush-size 2)) t 1)
    (apply #'cmacs-imgedit-set-pixel cmacs-imgedit--handle
           (car xy) (cdr xy) cmacs-imgedit--color)))

;; ── Live GL viewport: availability, hooks, tool dispatch ────────────────

(defun cmacs-imgedit--viewport-available-p ()
  "Non-nil when a live libregnum GL viewport can be used here.
Requires a graphical display and the libregnum backend; nil on tty /
headless / no-GL, where the native insert-image path is used instead."
  (and (fboundp 'cmacs-libregnum-supported-p)
       (cmacs-libregnum-supported-p)
       (fboundp 'cmacs-imgedit-viewport-bind)
       (or (display-graphic-p) (eq (framep-on-display) 'lrg))))

(defun cmacs-imgedit--vp-refresh ()
  "Re-upload the document to the viewport (cheap; no PNG round-trip)."
  (when cmacs-imgedit--live
    (ignore-errors (cmacs-libregnum-image-refresh (current-buffer)))))

(defun cmacs-imgedit--vp-commit-shape (tool start end)
  "Commit shape TOOL from doc point START to END (one undo step)."
  (cmacs-imgedit--apply-color)
  (cmacs-imgedit-push-undo cmacs-imgedit--handle)
  (let ((sx (car start)) (sy (cdr start)) (ex (car end)) (ey (cdr end)))
    (pcase tool
      ('line (cmacs-imgedit-draw-line cmacs-imgedit--handle sx sy ex ey
                                      cmacs-imgedit--brush-size))
      ('arrow (cmacs-imgedit-draw-arrow cmacs-imgedit--handle sx sy ex ey
                                        cmacs-imgedit--brush-size))
      ('rectangle (cmacs-imgedit-draw-rect cmacs-imgedit--handle
                    (min sx ex) (min sy ey)
                    (max 1 (abs (- ex sx))) (max 1 (abs (- ey sy)))
                    cmacs-imgedit--shape-fill cmacs-imgedit--brush-size))
      ('circle (let ((dx (- ex sx)) (dy (- ey sy)))
                 (cmacs-imgedit-draw-circle cmacs-imgedit--handle sx sy
                   (max 1 (round (sqrt (+ (* dx dx) (* dy dy)))))
                   cmacs-imgedit--shape-fill cmacs-imgedit--brush-size)))
      ('ellipse (cmacs-imgedit-draw-ellipse cmacs-imgedit--handle sx sy
                  (max 1 (abs (- ex sx))) (max 1 (abs (- ey sy)))
                  cmacs-imgedit--shape-fill cmacs-imgedit--brush-size)))))

(defun cmacs-imgedit--vp-press (buffer dx dy _button _mods)
  "Viewport left-press at doc (DX DY): brush dabs, shapes record the start."
  (with-current-buffer buffer
    (when cmacs-imgedit--handle
      (cmacs-imgedit--apply-color)
      (pcase cmacs-imgedit--tool
        ('brush
         (cmacs-imgedit-push-undo cmacs-imgedit--handle)
         (cmacs-imgedit--brush-dab (cons dx dy))
         (setq cmacs-imgedit--vp-prev (cons dx dy))
         (cmacs-imgedit--vp-refresh))
        ((or 'line 'arrow 'rectangle 'circle 'ellipse)
         (setq cmacs-imgedit--vp-start (cons dx dy)))
        (_ nil)))))          ; fill / eyedropper / text act on click

(defun cmacs-imgedit--vp-drag (buffer dx dy _button _mods)
  "Viewport left-drag to doc (DX DY): brush paints a segment."
  (with-current-buffer buffer
    (when (and cmacs-imgedit--handle (eq cmacs-imgedit--tool 'brush)
               cmacs-imgedit--vp-prev)
      (cmacs-imgedit-draw-line cmacs-imgedit--handle
                               (car cmacs-imgedit--vp-prev)
                               (cdr cmacs-imgedit--vp-prev) dx dy
                               cmacs-imgedit--brush-size)
      (setq cmacs-imgedit--vp-prev (cons dx dy))
      (cmacs-imgedit--vp-refresh))
    ;; brush-cursor overlay follows the pointer, zero Elisp-render latency
    (ignore-errors
      (cmacs-libregnum-image-set-cursor
       buffer dx dy (max 0.5 (/ cmacs-imgedit--brush-size 2.0))))))

(defun cmacs-imgedit--vp-release (buffer dx dy _button _mods)
  "Viewport left-release at doc (DX DY): commit a shape / finish a stroke."
  (with-current-buffer buffer
    (when cmacs-imgedit--handle
      (pcase cmacs-imgedit--tool
        ('brush (setq cmacs-imgedit--vp-prev nil) (cmacs-imgedit--vp-refresh))
        ((and (or 'line 'arrow 'rectangle 'circle 'ellipse) tool)
         (when cmacs-imgedit--vp-start
           (cmacs-imgedit--vp-commit-shape tool cmacs-imgedit--vp-start
                                           (cons dx dy))
           (setq cmacs-imgedit--vp-start nil)
           (cmacs-imgedit--vp-refresh)))
        (_ nil)))))

(defun cmacs-imgedit--vp-click (buffer dx dy _button _mods)
  "Viewport click at doc (DX DY): fill / eyedropper / text act here."
  (with-current-buffer buffer
    (when cmacs-imgedit--handle
      (cmacs-imgedit--apply-color)
      (pcase cmacs-imgedit--tool
        ('fill
         (cmacs-imgedit-push-undo cmacs-imgedit--handle)
         (apply #'cmacs-imgedit-flood-fill cmacs-imgedit--handle dx dy
                (append cmacs-imgedit--color '(0)))
         (cmacs-imgedit--vp-refresh))
        ('eyedropper
         (let ((px (cmacs-imgedit-pixel-at cmacs-imgedit--handle dx dy)))
           (when px
             (setq cmacs-imgedit--color px)
             (cmacs-imgedit--apply-color)
             (cmacs-imgedit--refresh-panels))))
        ('text
         (let ((str (read-string "Text: ")))
           (unless (string-empty-p str)
             (cmacs-imgedit-push-undo cmacs-imgedit--handle)
             (cmacs-imgedit-draw-text cmacs-imgedit--handle dx dy str
                                      cmacs-imgedit-text-size)
             (cmacs-imgedit--vp-refresh))))
        (_ (cmacs-imgedit--vp-refresh))))))

(defun cmacs-imgedit--vp-context-menu (buffer _dx _dy fx fy)
  "Pop the imgedit context menu for a viewport right-click at frame (FX FY).
Runs deferred inside the pselect wait, so schedule the pop onto the command
loop with a 0-delay timer (the 3D editor does the same)."
  (run-at-time
   0 nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         (let ((choice (cmacs-libregnum-popup-menu
                        (list (list fx fy) (selected-window))
                        (cmacs-imgedit--menu))))
           (when (commandp choice) (call-interactively choice))))))))

(defun cmacs-imgedit--install-image-hooks (buffer)
  "Install the viewport input hook functions in BUFFER."
  (with-current-buffer buffer
    (setq cmacs-libregnum-image-press-function #'cmacs-imgedit--vp-press
          cmacs-libregnum-image-drag-function #'cmacs-imgedit--vp-drag
          cmacs-libregnum-image-release-function #'cmacs-imgedit--vp-release
          cmacs-libregnum-image-click-function #'cmacs-imgedit--vp-click
          cmacs-libregnum-image-context-menu-function
          #'cmacs-imgedit--vp-context-menu)))

(defun cmacs-imgedit--select-event-window (event)
  "Select the window EVENT happened in and return it.

CRITICAL: a mouse command is looked up in the *clicked* buffer's keymap but
runs with the *selected* window's buffer current.  After clicking any side
panel (a tool button, Pick colour…), the panel window is selected, so canvas
clicks used to run with the panel buffer current — where the buffer-local
document handle is nil — and silently did nothing.  Selecting the clicked
window first (standard mouse-command behaviour) puts the canvas buffer's
state in scope."
  (let ((win (posn-window (event-start event))))
    (when (and (windowp win) (window-live-p win))
      (select-window win)
      ;; select-window normally does this, but be explicit so the buffer is
      ;; right even when WIN was already selected with another buffer current.
      (set-buffer (window-buffer win)))
    win))

(defun cmacs-imgedit--event-end-xy (event win)
  "Document coords where mouse EVENT ENDED, when that is in WIN, else nil.
Used for the button-release that ends a drag.  CRITICAL: a cross-canvas
drag arrives as `drag-mouse-1' carrying TWO posns — `event-start' is the
PRESS point and `event-end' the release — so this must read `event-end'
(which equals `event-start' for plain clicks).  Reading the start posn
here silently rewound every drag to its press point.  Because Emacs
synthesizes the drag event from the two positions, this also reports the
true endpoint on backends that deliver no motion during `track-mouse'."
  (let ((posn (and (consp event) (ignore-errors (event-end event)))))
    (and posn
         (ignore-errors (eq (posn-window posn) win))
         ;; Re-wrap so --event-doc-xy (which reads `event-start') sees
         ;; the END posn.
         (ignore-errors
           (cmacs-imgedit--event-doc-xy (list 'mouse-1 posn))))))

(defun cmacs-imgedit--stroke-feedback (xy)
  "Echo what the last edit at XY produced, for instant triage."
  (let ((px (cmacs-imgedit-pixel-at cmacs-imgedit--handle (car xy) (cdr xy))))
    (message "imgedit: %s painted %S at %S (layer %d/%d)"
             cmacs-imgedit--tool px xy
             (cmacs-imgedit-active-layer cmacs-imgedit--handle)
             (cmacs-imgedit-n-layers cmacs-imgedit--handle))))

(defun cmacs-imgedit-mouse-1 (event)
  "Apply the active tool with the mouse, starting at EVENT.
Brush draws continuously while dragging; line/rectangle/circle draw on
release; bucket/eyedropper act on the click."
  (interactive "e")
  (let ((win (cmacs-imgedit--select-event-window event)))
    (unless cmacs-imgedit--handle
      (user-error "imgedit: this click did not land on an editor canvas"))
    (let ((start (cmacs-imgedit--event-doc-xy event)))
      (if (null start)
          (message "imgedit: click landed off the image")
        (cmacs-imgedit--apply-color)
        (pcase cmacs-imgedit--tool
        ('eyedropper
         (let ((px (cmacs-imgedit-pixel-at cmacs-imgedit--handle
                                           (car start) (cdr start))))
           (when px
             (setq cmacs-imgedit--color px)
             (cmacs-imgedit--apply-color)
             (cmacs-imgedit--refresh-panels)
             (message "Picked %s" px))))
        ('fill
         (cmacs-imgedit-push-undo cmacs-imgedit--handle)
         (apply #'cmacs-imgedit-flood-fill cmacs-imgedit--handle
                (car start) (cdr start) (append cmacs-imgedit--color '(0)))
         (cmacs-imgedit--render)
         (cmacs-imgedit--stroke-feedback start))
        ('text
         (let ((str (read-string "Text: ")))
           (unless (string-empty-p str)
             (cmacs-imgedit-push-undo cmacs-imgedit--handle)
             (cmacs-imgedit-draw-text cmacs-imgedit--handle
                                      (car start) (cdr start) str
                                      cmacs-imgedit-text-size)
             (cmacs-imgedit--render)
             (cmacs-imgedit--stroke-feedback start))))
        ('brush
         (cmacs-imgedit-push-undo cmacs-imgedit--handle)
         (let ((prev start) (n 0) (done nil))
           (cmacs-imgedit--brush-dab prev)
           (cmacs-imgedit--render t)        ; live feedback (skip panels)
           (track-mouse
             (while (not done)
               (let ((e (read-event)) cur)
                 (if (mouse-movement-p e)
                     ;; Only track motion over the canvas window; the coord
                     ;; fallback would misread panel-relative positions if
                     ;; the pointer strays.
                     (setq cur (and (eq (posn-window (event-start e)) win)
                                    (cmacs-imgedit--event-doc-xy e)))
                   ;; Button release ends the stroke; its own position is
                   ;; the last segment (and the only one on backends that
                   ;; deliver no motion during track-mouse).
                   (setq done t
                         cur (cmacs-imgedit--event-end-xy e win)))
                 (when (and prev cur (not (equal prev cur)))
                   (cmacs-imgedit-draw-line
                    cmacs-imgedit--handle (car prev) (cdr prev)
                    (car cur) (cdr cur) cmacs-imgedit--brush-size)
                   (setq prev cur)
                   ;; Throttle the live redraw (full-image PNG re-encode
                   ;; is costly for large canvases).
                   (when (and (not done) (zerop (mod (cl-incf n) 3)))
                     (cmacs-imgedit--render t))))))
           (cmacs-imgedit--render)
           (cmacs-imgedit--stroke-feedback prev)))
        ((or 'line 'arrow 'rectangle 'circle 'ellipse)
         ;; Drag to define the shape; commit on release.
         (let ((end start))
           (track-mouse
             (while (let ((e (read-event)))
                      (cond
                       ((mouse-movement-p e)
                        (let ((cur (and (eq (posn-window (event-start e)) win)
                                        (cmacs-imgedit--event-doc-xy e))))
                          (when cur (setq end cur)))
                        t)
                       ;; Button-up stops the drag; its position is the
                       ;; exact endpoint (and the only one on backends
                       ;; with no motion events during track-mouse).
                       (t (let ((cur (cmacs-imgedit--event-end-xy e win)))
                            (when cur (setq end cur)))
                          nil)))))
           (cmacs-imgedit-push-undo cmacs-imgedit--handle)
           (pcase cmacs-imgedit--tool
             ('line
              (cmacs-imgedit-draw-line cmacs-imgedit--handle
                                       (car start) (cdr start)
                                       (car end) (cdr end)
                                       cmacs-imgedit--brush-size))
             ('arrow
              (cmacs-imgedit-draw-arrow cmacs-imgedit--handle
                                        (car start) (cdr start)
                                        (car end) (cdr end)
                                        cmacs-imgedit--brush-size))
             ('ellipse
              (cmacs-imgedit-draw-ellipse cmacs-imgedit--handle
                                          (car start) (cdr start)
                                          (max 1 (abs (- (car end) (car start))))
                                          (max 1 (abs (- (cdr end) (cdr start))))
                                          cmacs-imgedit--shape-fill
                                          cmacs-imgedit--brush-size))
             ('rectangle
              (cmacs-imgedit-draw-rect cmacs-imgedit--handle
                                       (min (car start) (car end))
                                       (min (cdr start) (cdr end))
                                       (max 1 (abs (- (car end) (car start))))
                                       (max 1 (abs (- (cdr end) (cdr start))))
                                       cmacs-imgedit--shape-fill
                                       cmacs-imgedit--brush-size))
             ('circle
              (let ((dx (- (car end) (car start)))
                    (dy (- (cdr end) (cdr start))))
                (cmacs-imgedit-draw-circle cmacs-imgedit--handle
                                           (car start) (cdr start)
                                           (max 1 (round (sqrt (+ (* dx dx)
                                                                  (* dy dy)))))
                                           cmacs-imgedit--shape-fill
                                           cmacs-imgedit--brush-size))))
           (cmacs-imgedit--render)
           (cmacs-imgedit--stroke-feedback end))))))))

(defun cmacs-imgedit-diagnose ()
  "Report everything relevant to \"the mouse is not drawing\" in one line.
Run it (key `D' or \\[execute-extended-command]) inside an editor buffer.
Never signals; each probe reports OK or its failure."
  (interactive)
  (let ((parts '()))
    (cl-flet ((add (fmt &rest args) (push (apply #'format fmt args) parts)))
      (add "ui=v%d" cmacs-imgedit--ui-version)
      ;; Resolve the binding AT THE CANVAS position: Evil state maps and
      ;; minor modes can shadow the mode map, and the canvas text-property
      ;; keymap is position-dependent.
      (add "binding@canvas=%s"
           (let ((b (key-binding [down-mouse-1] nil nil (point-min))))
             (if (eq b 'cmacs-imgedit-mouse-1) "OK"
               (format "SHADOWED by %S (reload cmacs-imgedit.el)" b))))
      (when (and (boundp 'evil-state) evil-state)
        (add "evil-state=%s" evil-state))
      (if (null cmacs-imgedit--handle)
          (add "canvas=NO (run this in the *imgedit* canvas buffer)")
        (condition-case err
            (let* ((h cmacs-imgedit--handle)
                   (n (cmacs-imgedit-n-layers h))
                   (a (cmacs-imgedit-active-layer h)))
              (add "canvas=%dx%d zoom=%d tool=%s color=%s"
                   (cmacs-imgedit-width h) (cmacs-imgedit-height h)
                   cmacs-imgedit--zoom cmacs-imgedit--tool cmacs-imgedit--color)
              (add "layers=%d active=%d(%s%s)" n a
                   (or (cmacs-imgedit-layer-name h a) "?")
                   (if (cmacs-imgedit-layer-visible-p h a) "" " HIDDEN")))
          (error (add "canvas-probe=ERROR %S" err))))
      ;; End-to-end C draw probe on a throwaway 2x2 document.
      (condition-case err
          (let ((h (cmacs-imgedit-new 2 2)))
            (unwind-protect
                (progn
                  (cmacs-imgedit-set-color h 255 0 0 255)
                  (cmacs-imgedit-set-pixel h 0 0 255 0 0 255)
                  (add "C-draw=%s"
                       (if (equal (cmacs-imgedit-pixel-at h 0 0)
                                  '(255 0 0 255))
                           "OK" "BROKEN (rebuilt emacs needed?)")))
              (cmacs-imgedit-free h)))
        (error (add "C-draw=ERROR %S (session binary predates imgedit rework \
— restart the cmacs session)" err)))
      (add "loaded=%s" (or (locate-library "cmacs-imgedit") "??")))
    (message "imgedit-diagnose: %s" (string-join (nreverse parts) " | "))))

;; --------------------------------------------------------------------------
;; Layer commands
;; --------------------------------------------------------------------------

(defun cmacs-imgedit-add-layer-cmd (name)
  "Add a new transparent layer NAME on top."
  (interactive "sLayer name: ")
  ;; NOTE: distinct from the `cmacs-imgedit-add-layer' C primitive.
  (cmacs-imgedit-add-layer cmacs-imgedit--handle
                           (if (string-empty-p name) nil name))
  (cmacs-imgedit--render)
  (message "Layers: %d" (cmacs-imgedit-n-layers cmacs-imgedit--handle)))

(defun cmacs-imgedit-remove-active-layer ()
  "Remove the active layer."
  (interactive)
  (if (cmacs-imgedit-remove-layer
       cmacs-imgedit--handle (cmacs-imgedit-active-layer cmacs-imgedit--handle))
      (cmacs-imgedit--render)
    (message "Cannot remove the only layer")))

(defun cmacs-imgedit-set-active-layer-cmd (index)
  "Make layer INDEX active."
  (interactive (list (read-number "Active layer: "
                                  (cmacs-imgedit-active-layer
                                   cmacs-imgedit--handle))))
  (cmacs-imgedit-set-active-layer cmacs-imgedit--handle index)
  (message "Active layer: %d (%s)" index
           (cmacs-imgedit-layer-name cmacs-imgedit--handle index)))

(defun cmacs-imgedit-toggle-layer-visible ()
  "Toggle visibility of the active layer."
  (interactive)
  (let ((i (cmacs-imgedit-active-layer cmacs-imgedit--handle)))
    (cmacs-imgedit-set-layer-visible
     cmacs-imgedit--handle i
     (not (cmacs-imgedit-layer-visible-p cmacs-imgedit--handle i)))
    (cmacs-imgedit--render)))

(defun cmacs-imgedit-set-layer-opacity-cmd (opacity)
  "Set the active layer OPACITY (0.0..1.0)."
  (interactive (list (read-number "Opacity (0..1): " 1.0)))
  (cmacs-imgedit-set-layer-opacity
   cmacs-imgedit--handle (cmacs-imgedit-active-layer cmacs-imgedit--handle)
   opacity)
  (cmacs-imgedit--render))

(defun cmacs-imgedit-list-layers ()
  "Echo the layer stack."
  (interactive)
  (let ((n (cmacs-imgedit-n-layers cmacs-imgedit--handle))
        (active (cmacs-imgedit-active-layer cmacs-imgedit--handle))
        (out '()))
    (dotimes (i n)
      (push (format "%s%d:%s%s o=%.2f"
                    (if (= i active) "*" " ") i
                    (cmacs-imgedit-layer-name cmacs-imgedit--handle i)
                    (if (cmacs-imgedit-layer-visible-p cmacs-imgedit--handle i)
                        "" " (hidden)")
                    (cmacs-imgedit-layer-opacity cmacs-imgedit--handle i))
            out))
    (message "%s" (string-join (nreverse out) "  "))))

;; --------------------------------------------------------------------------
;; Undo / save / zoom
;; --------------------------------------------------------------------------

(defun cmacs-imgedit-undo-cmd ()
  "Undo the last edit."
  (interactive)
  ;; NOTE: distinct from the `cmacs-imgedit-undo' C primitive.
  (if (cmacs-imgedit-undo cmacs-imgedit--handle)
      (cmacs-imgedit--render)
    (message "Nothing to undo")))

(defun cmacs-imgedit-redo-cmd ()
  "Redo the last undone edit."
  (interactive)
  (if (cmacs-imgedit-redo cmacs-imgedit--handle)
      (cmacs-imgedit--render)
    (message "Nothing to redo")))

(defvar cmacs-imgedit-after-save-functions nil
  "Abnormal hook run after saving, with the saved file path.
Buffer-local additions fire only for that editor buffer.  The 3D editor
uses this to reload a sprite/tilemap texture after \"Edit sprite image…\".")

(defun cmacs-imgedit-save-cmd (&optional path)
  "Save the document to PATH (prompting if needed)."
  (interactive)
  ;; NOTE: distinct from the `cmacs-imgedit-save' C primitive.
  (let ((p (or path cmacs-imgedit--path
               (read-file-name "Save image to: "))))
    (cmacs-imgedit-save cmacs-imgedit--handle p)
    (setq cmacs-imgedit--path p)
    (set-buffer-modified-p nil)
    (message "Wrote %s" p)
    (run-hook-with-args 'cmacs-imgedit-after-save-functions
                        (expand-file-name p))))

(defun cmacs-imgedit-zoom-in ()
  "Increase the zoom factor."
  (interactive)
  (setq cmacs-imgedit--zoom (1+ cmacs-imgedit--zoom))
  (cmacs-imgedit--render))

(defun cmacs-imgedit-zoom-out ()
  "Decrease the zoom factor (min 1)."
  (interactive)
  (setq cmacs-imgedit--zoom (max 1 (1- cmacs-imgedit--zoom)))
  (cmacs-imgedit--render))

;; --------------------------------------------------------------------------
;; Clipboard + screenshot
;; --------------------------------------------------------------------------

(defun cmacs-imgedit--gtk-clipboard-p ()
  "Non-nil when Emacs's own GTK clipboard is usable (pgtk session)."
  (and (fboundp 'cmacs-imgedit-clipboard-available-p)
       (cmacs-imgedit-clipboard-available-p)))

(defun cmacs-imgedit-copy-to-clipboard ()
  "Copy the flattened image to the system clipboard as PNG.

Backend order: gowl's native image clipboard when present, else Emacs's
own in-process GTK clipboard (works identically under gowl, GNOME/Mutter,
KDE or X11 — no external tools), else `wl-copy'."
  (interactive)
  (let ((png (cmacs-imgedit-export-png-bytes cmacs-imgedit--handle)))
    (cond
     ((fboundp 'gowl-clipboard-set-image)
      (gowl-clipboard-set-image png)
      (message "Copied image to clipboard (gowl)"))
     ((cmacs-imgedit--gtk-clipboard-p)
      (cmacs-imgedit-clipboard-set-png png)
      (message "Copied image to clipboard (GTK)"))
     ((executable-find "wl-copy")
      (let ((tmp (make-temp-file "cmacs-imgedit-copy-" nil ".png"))
            (coding-system-for-write 'binary))
        (unwind-protect
            (progn
              (write-region png nil tmp nil 'silent)
              (unless (zerop (call-process "wl-copy" tmp nil nil
                                           "--type" "image/png"))
                (user-error "wl-copy failed (no Wayland session?)")))
          (delete-file tmp)))
      (message "Copied image to clipboard (wl-copy)"))
     (t (user-error "No image-clipboard backend (install wl-clipboard)")))))

(defun cmacs-imgedit--write-png-bytes (bytes dest)
  "Write unibyte PNG BYTES to DEST; non-nil when non-empty."
  (when (and (stringp bytes) (> (length bytes) 0))
    (let ((coding-system-for-write 'binary))
      (write-region bytes nil dest nil 'silent))
    t))

(defun cmacs-imgedit--read-clipboard-png (dest)
  "Write a clipboard image to DEST as PNG.  Return non-nil on success.

Tries each backend in turn: gowl's native image clipboard, Emacs's own
GTK clipboard (any compositor / X11), then `wl-paste'."
  (or
   ;; gowl native (when the compositor-side DEFUN exists).
   (and (fboundp 'gowl-clipboard-get-image)
        (cmacs-imgedit--write-png-bytes
         (ignore-errors (gowl-clipboard-get-image)) dest))
   ;; In-process GTK clipboard: portable across compositors.
   (and (cmacs-imgedit--gtk-clipboard-p)
        (cmacs-imgedit--write-png-bytes
         (ignore-errors (cmacs-imgedit-clipboard-get-png)) dest))
   ;; wl-clipboard fallback (--lrg / tty Wayland sessions).
   (and (executable-find "wl-paste")
        (progn
          (ignore-errors
            (call-process "wl-paste" nil (list :file dest) nil
                          "--type" "image/png"))
          (and (file-exists-p dest)
               (> (file-attribute-size (file-attributes dest)) 0))))))

(defun cmacs-imgedit--paste-png-file (png-file name)
  "Add PNG-FILE as a new layer named NAME, then re-render."
  (when (and (file-exists-p png-file)
             (> (file-attribute-size (file-attributes png-file)) 0))
    (cmacs-imgedit-add-layer-from-file cmacs-imgedit--handle png-file name)
    (cmacs-imgedit--render)
    t))

(defun cmacs-imgedit-paste-from-clipboard ()
  "Paste an image from the clipboard as a new layer."
  (interactive)
  (let ((tmp (make-temp-file "cmacs-imgedit-paste-" nil ".png")))
    (unwind-protect
        (unless (and (cmacs-imgedit--read-clipboard-png tmp)
                     (cmacs-imgedit--paste-png-file tmp "Pasted"))
          (user-error "No image on the clipboard"))
      (delete-file tmp))))

(defun cmacs-imgedit-paste-screenshot ()
  "Capture a screenshot (gowl) and add it as a new layer."
  (interactive)
  (unless (fboundp 'gowl-screenshot-monitor)
    (user-error "Screenshot needs the gowl compositor (emacs --gowl)"))
  (let ((shot (gowl-screenshot-monitor)))
    (unless shot
      (user-error "Screenshot failed"))
    (cmacs-imgedit-add-layer-rgba cmacs-imgedit--handle
                                  (nth 0 shot) (nth 1 shot) (nth 2 shot)
                                  "Screenshot")
    (cmacs-imgedit--render)
    (message "Pasted %dx%d screenshot" (nth 0 shot) (nth 1 shot))))

;;;###autoload
(defun cmacs-imgedit-from-clipboard ()
  "Open the image on the system clipboard in a new image editor buffer."
  (interactive)
  (unless (and (fboundp 'cmacs-imgedit-supported-p)
               (cmacs-imgedit-supported-p))
    (user-error "cmacs was not built with --with-cmacs-imgedit"))
  (let ((tmp (make-temp-file "cmacs-imgedit-clip-" nil ".png")))
    (unwind-protect
        (progn
          (unless (cmacs-imgedit--read-clipboard-png tmp)
            (user-error "No image on the clipboard"))
          (cmacs-imgedit-open-file tmp))
      (delete-file tmp))))

;;;###autoload
(defun cmacs-imgedit-from-screenshot ()
  "Capture a screenshot (gowl) and open it in a new image editor buffer."
  (interactive)
  (unless (and (fboundp 'cmacs-imgedit-supported-p)
               (cmacs-imgedit-supported-p))
    (user-error "cmacs was not built with --with-cmacs-imgedit"))
  (unless (fboundp 'gowl-screenshot-monitor)
    (user-error "Screenshot needs the gowl compositor (emacs --gowl)"))
  (let ((shot (gowl-screenshot-monitor)))
    (unless shot
      (user-error "Screenshot failed"))
    (let* ((w (nth 0 shot)) (h (nth 1 shot))
           (handle (cmacs-imgedit-new w h))
           (buffer (generate-new-buffer "*imgedit: screenshot*")))
      (cmacs-imgedit-add-layer-rgba handle w h (nth 2 shot) "Screenshot")
      (cmacs-imgedit--setup-buffer buffer handle nil))))

;; --------------------------------------------------------------------------
;; Side panels (tools palette + layers) — opened like the 3D editor's panels
;; --------------------------------------------------------------------------

(require 'button)

(defun cmacs-imgedit--color-hex (rgba)
  "Return a #rrggbb string for the RGBA list."
  (format "#%02x%02x%02x" (nth 0 rgba) (nth 1 rgba) (nth 2 rgba)))

(defun cmacs-imgedit--panel-act (canvas fn)
  "Run FN in the CANVAS buffer, then re-render + refresh panels."
  (when (buffer-live-p canvas)
    (with-current-buffer canvas
      (funcall fn)
      (cmacs-imgedit--render))))

(defun cmacs-imgedit--build-tools-panel (canvas)
  "Render the tools palette for CANVAS into the current (panel) buffer."
  (let ((inhibit-read-only t)
        (tool  (buffer-local-value 'cmacs-imgedit--tool canvas))
        (color (buffer-local-value 'cmacs-imgedit--color canvas))
        (brush (buffer-local-value 'cmacs-imgedit--brush-size canvas))
        (fill  (buffer-local-value 'cmacs-imgedit--shape-fill canvas)))
    (erase-buffer)
    (insert (propertize " Tools\n" 'face 'bold))
    (dolist (tc cmacs-imgedit-tools)
      (let ((sym (car tc)))
        (insert " ")
        (insert-text-button
         (format "%s %s" (if (eq sym tool) "●" "○") (cdr tc))
         'action (lambda (_)
                   (cmacs-imgedit--panel-act
                    canvas (lambda () (cmacs-imgedit-set-tool sym))))
         'follow-link t 'help-echo (format "Use the %s tool" (cdr tc)))
        (insert "\n")))
    (insert "\n ")
    (insert-text-button (format "Shapes: %s" (if fill "filled" "outline"))
                        'action (lambda (_)
                                  (cmacs-imgedit--panel-act
                                   canvas #'cmacs-imgedit-toggle-shape-fill))
                        'follow-link t)
    (insert "\n\n")
    (insert (propertize " Colour " 'face 'bold))
    (insert (propertize "      " 'face `(:background ,(cmacs-imgedit--color-hex color))))
    (insert (format " %s a=%d\n " (cmacs-imgedit--color-hex color) (nth 3 color)))
    (insert-text-button "Pick colour…"
                        'action (lambda (_)
                                  (cmacs-imgedit--panel-act
                                   canvas
                                   (lambda ()
                                     (call-interactively
                                      #'cmacs-imgedit-set-foreground-color))))
                        'follow-link t)
    (insert "\n ")
    (insert-text-button (format "Brush: %d px" brush)
                        'action (lambda (_)
                                  (cmacs-imgedit--panel-act
                                   canvas
                                   (lambda ()
                                     (call-interactively
                                      #'cmacs-imgedit-set-brush-size))))
                        'follow-link t)
    (insert "\n ")
    (insert-text-button (format "Text: %d px" cmacs-imgedit-text-size)
                        'action (lambda (_)
                                  (cmacs-imgedit--panel-act
                                   canvas
                                   (lambda ()
                                     (call-interactively
                                      #'cmacs-imgedit-set-text-size))))
                        'follow-link t)
    (insert "\n\n")
    (insert (propertize " Edit\n" 'face 'bold))
    (dolist (b '(("Undo" . cmacs-imgedit-undo-cmd)
                 ("Redo" . cmacs-imgedit-redo-cmd)
                 ("Fill layer" . cmacs-imgedit-fill-layer)
                 ("Paste screenshot" . cmacs-imgedit-paste-screenshot)
                 ("Copy → clipboard" . cmacs-imgedit-copy-to-clipboard)
                 ("Save…" . cmacs-imgedit-save-cmd)))
      (let ((cmd (cdr b)))
        (insert " ")
        (insert-text-button (car b)
                            'action (lambda (_)
                                      (cmacs-imgedit--panel-act
                                       canvas (lambda () (call-interactively cmd))))
                            'follow-link t)
        (insert "\n")))))

(defun cmacs-imgedit--build-layers-panel (canvas)
  "Render the layers list for CANVAS into the current (panel) buffer."
  (let* ((inhibit-read-only t)
         (h (buffer-local-value 'cmacs-imgedit--handle canvas))
         (n (cmacs-imgedit-n-layers h))
         (active (cmacs-imgedit-active-layer h)))
    (erase-buffer)
    (insert (propertize " Layers\n" 'face 'bold))
    ;; Top layer first (like real editors).
    (cl-loop for i from (1- n) downto 0 do
      (let ((idx i))
        (insert " ")
        (insert-text-button
         (format "%s%s %-10s o=%.2f"
                 (if (= idx active) "▶" " ")
                 (if (cmacs-imgedit-layer-visible-p h idx) "◉" "○")
                 (cmacs-imgedit-layer-name h idx)
                 (cmacs-imgedit-layer-opacity h idx))
         'action (lambda (_)
                   (cmacs-imgedit--panel-act
                    canvas (lambda () (cmacs-imgedit-set-active-layer h idx))))
         'follow-link t 'help-echo "Select this layer")
        (insert " ")
        (insert-text-button "[v]"
                            'action (lambda (_)
                                      (cmacs-imgedit--panel-act
                                       canvas
                                       (lambda ()
                                         (cmacs-imgedit-set-active-layer h idx)
                                         (cmacs-imgedit-toggle-layer-visible))))
                            'follow-link t 'help-echo "Toggle visibility")
        (insert "\n")))
    (insert "\n")
    (dolist (b '(("+ Add layer" . cmacs-imgedit-add-layer-cmd)
                 ("- Remove" . cmacs-imgedit-remove-active-layer)
                 ("Opacity…" . cmacs-imgedit-set-layer-opacity-cmd)))
      (let ((cmd (cdr b)))
        (insert " ")
        (insert-text-button (car b)
                            'action (lambda (_)
                                      (cmacs-imgedit--panel-act
                                       canvas (lambda () (call-interactively cmd))))
                            'follow-link t)
        (insert "\n")))))

(defun cmacs-imgedit--refresh-panels ()
  "Rebuild the side panels from the current canvas buffer's state."
  (let ((canvas (current-buffer)))
    (when (buffer-live-p cmacs-imgedit--tools-panel)
      (with-current-buffer cmacs-imgedit--tools-panel
        (cmacs-imgedit--build-tools-panel canvas)))
    (when (buffer-live-p cmacs-imgedit--layers-panel)
      (with-current-buffer cmacs-imgedit--layers-panel
        (cmacs-imgedit--build-layers-panel canvas)))))

(defun cmacs-imgedit--open-panels ()
  "Create + display the tools and layers side windows for this canvas."
  (let* ((canvas (current-buffer))
         (tbuf (get-buffer-create (format "*imgedit-tools[%s]*"
                                          (buffer-name canvas))))
         (lbuf (get-buffer-create (format "*imgedit-layers[%s]*"
                                          (buffer-name canvas)))))
    (setq cmacs-imgedit--tools-panel tbuf
          cmacs-imgedit--layers-panel lbuf)
    (dolist (b (list tbuf lbuf))
      (with-current-buffer b
        (unless (derived-mode-p 'special-mode) (special-mode))
        (setq-local cmacs-imgedit--canvas-buffer canvas)
        (setq-local cursor-type nil)))
    (cmacs-imgedit--refresh-panels)
    (display-buffer-in-side-window tbuf '((side . left) (window-width . 22)
                                          (slot . 0)))
    (display-buffer-in-side-window lbuf '((side . right) (window-width . 30)
                                          (slot . 0)))))

;; --------------------------------------------------------------------------
;; Right-click context menu (GTK under pgtk, in-engine under --lrg)
;; --------------------------------------------------------------------------

;; ── Adjustments / filters / flip (active layer, one undo step) ──────────

(defmacro cmacs-imgedit--with-edit (&rest body)
  "Push an undo snapshot, run BODY, then re-render."
  `(when cmacs-imgedit--handle
     (cmacs-imgedit-push-undo cmacs-imgedit--handle)
     ,@body
     (cmacs-imgedit--render)))

(defun cmacs-imgedit-flip-horizontal ()
  "Flip the whole image left-to-right."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-flip cmacs-imgedit--handle t)))

(defun cmacs-imgedit-flip-vertical ()
  "Flip the whole image top-to-bottom."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-flip cmacs-imgedit--handle nil)))

(defun cmacs-imgedit-adjust-brightness (amount)
  "Adjust active-layer brightness by AMOUNT (-255..255)."
  (interactive (list (read-number "Brightness (-255..255): " 20)))
  (cmacs-imgedit--with-edit
   (cmacs-imgedit-brightness cmacs-imgedit--handle amount)))

(defun cmacs-imgedit-adjust-contrast (amount)
  "Adjust active-layer contrast by AMOUNT (-100..100)."
  (interactive (list (read-number "Contrast (-100..100): " 20)))
  (cmacs-imgedit--with-edit
   (cmacs-imgedit-contrast cmacs-imgedit--handle amount)))

(defun cmacs-imgedit-invert-colors ()
  "Invert the active layer's colours."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-invert cmacs-imgedit--handle)))

(defun cmacs-imgedit-desaturate ()
  "Desaturate the active layer to grayscale."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-grayscale cmacs-imgedit--handle)))

(defun cmacs-imgedit-tint-layer (color)
  "Multiply the active layer by tint COLOR."
  (interactive (list (read-color "Tint colour: ")))
  (let ((rgb (color-values color)))
    (cmacs-imgedit--with-edit
     (cmacs-imgedit-tint cmacs-imgedit--handle
                         (/ (nth 0 rgb) 256) (/ (nth 1 rgb) 256)
                         (/ (nth 2 rgb) 256) 255))))

(defun cmacs-imgedit-blur-layer (radius)
  "Box-blur the active layer by RADIUS pixels."
  (interactive (list (read-number "Blur radius: " 2)))
  (cmacs-imgedit--with-edit (cmacs-imgedit-blur cmacs-imgedit--handle radius)))

(defun cmacs-imgedit-bloom-layer ()
  "Apply a bloom glow to the active layer."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-bloom cmacs-imgedit--handle)))

(defun cmacs-imgedit-noise-layer (amplitude)
  "Overlay noise of AMPLITUDE on the active layer."
  (interactive (list (read-number "Noise amplitude (0..1): " 0.2)))
  (cmacs-imgedit--with-edit
   (cmacs-imgedit-noise cmacs-imgedit--handle amplitude 1.0 1)))

(defun cmacs-imgedit-threshold-layer (level)
  "Threshold the active layer to black/white at LEVEL."
  (interactive (list (read-number "Threshold (0..255): " 128)))
  (cmacs-imgedit--with-edit (cmacs-imgedit-threshold cmacs-imgedit--handle level)))

(defun cmacs-imgedit-posterize-layer (levels)
  "Reduce the active layer to LEVELS colours per channel."
  (interactive (list (read-number "Levels per channel: " 4)))
  (cmacs-imgedit--with-edit (cmacs-imgedit-posterize cmacs-imgedit--handle levels)))

(defun cmacs-imgedit-pixelate-layer (size)
  "Pixelate the active layer into SIZE-pixel blocks."
  (interactive (list (read-number "Block size: " 8)))
  (cmacs-imgedit--with-edit (cmacs-imgedit-pixelate cmacs-imgedit--handle size)))

(defun cmacs-imgedit-sharpen-layer ()
  "Sharpen the active layer."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-sharpen cmacs-imgedit--handle)))

(defun cmacs-imgedit-edge-detect-layer ()
  "Edge-detect the active layer."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-edge-detect cmacs-imgedit--handle)))

(defun cmacs-imgedit-emboss-layer ()
  "Emboss the active layer."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-emboss cmacs-imgedit--handle)))

(defun cmacs-imgedit-adjust-saturation (factor)
  "Scale active-layer saturation by FACTOR."
  (interactive (list (read-number "Saturation (0..2): " 1.5)))
  (cmacs-imgedit--with-edit (cmacs-imgedit-saturation cmacs-imgedit--handle factor)))

;; ── Geometric transforms + gradient ────────────────────────────────────

(defun cmacs-imgedit-resize-image (width height)
  "Resize the whole document to WIDTH x HEIGHT."
  (interactive (list (read-number "New width: " (cmacs-imgedit-width
                                                 cmacs-imgedit--handle))
                     (read-number "New height: " (cmacs-imgedit-height
                                                  cmacs-imgedit--handle))))
  (cmacs-imgedit--with-edit
   (cmacs-imgedit-resize cmacs-imgedit--handle width height
                         (<= (cmacs-imgedit-width cmacs-imgedit--handle) 128)))
  (cmacs-imgedit--maybe-refit))

(defun cmacs-imgedit-crop-image (x y width height)
  "Crop the whole document to rectangle X Y WIDTH HEIGHT."
  (interactive
   (list (read-number "Crop x: " 0) (read-number "Crop y: " 0)
         (read-number "Crop width: " (cmacs-imgedit-width cmacs-imgedit--handle))
         (read-number "Crop height: " (cmacs-imgedit-height
                                       cmacs-imgedit--handle))))
  (cmacs-imgedit--with-edit
   (cmacs-imgedit-crop cmacs-imgedit--handle x y width height))
  (cmacs-imgedit--maybe-refit))

(defun cmacs-imgedit-rotate-cw ()
  "Rotate the whole document 90 degrees clockwise."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-rotate cmacs-imgedit--handle t))
  (cmacs-imgedit--maybe-refit))

(defun cmacs-imgedit-rotate-ccw ()
  "Rotate the whole document 90 degrees counter-clockwise."
  (interactive)
  (cmacs-imgedit--with-edit (cmacs-imgedit-rotate cmacs-imgedit--handle nil))
  (cmacs-imgedit--maybe-refit))

(defun cmacs-imgedit--maybe-refit ()
  "Re-fit the viewport after a document-size change (live mode)."
  (when cmacs-imgedit--live
    (ignore-errors (cmacs-libregnum-image-fit (current-buffer)))))

(defun cmacs-imgedit-gradient-fill (a b radial)
  "Fill the active layer with a gradient from colour A to B (RADIAL if set)."
  (interactive
   (list (read-color "From colour: ") (read-color "To colour: ")
         (y-or-n-p "Radial? ")))
  (let ((ca (color-values a)) (cb (color-values b)))
    (cmacs-imgedit--with-edit
     (cmacs-imgedit-gradient
      cmacs-imgedit--handle
      (list (/ (nth 0 ca) 256) (/ (nth 1 ca) 256) (/ (nth 2 ca) 256) 255)
      (list (/ (nth 0 cb) 256) (/ (nth 1 cb) 256) (/ (nth 2 cb) 256) 255)
      radial))))

;; ── Layer operations (expose the existing model DEFUNs) ─────────────────

(defun cmacs-imgedit--active ()
  "Index of the active layer."
  (cmacs-imgedit-active-layer cmacs-imgedit--handle))

(defun cmacs-imgedit-move-layer-up ()
  "Move the active layer up one (towards the top of the stack)."
  (interactive)
  (let* ((i (cmacs-imgedit--active))
         (n (cmacs-imgedit-n-layers cmacs-imgedit--handle)))
    (when (< (1+ i) n)
      (cmacs-imgedit-move-layer cmacs-imgedit--handle i (1+ i))
      (cmacs-imgedit-set-active-layer cmacs-imgedit--handle (1+ i))
      (cmacs-imgedit--render))))

(defun cmacs-imgedit-move-layer-down ()
  "Move the active layer down one (towards the bottom)."
  (interactive)
  (let ((i (cmacs-imgedit--active)))
    (when (> i 0)
      (cmacs-imgedit-move-layer cmacs-imgedit--handle i (1- i))
      (cmacs-imgedit-set-active-layer cmacs-imgedit--handle (1- i))
      (cmacs-imgedit--render))))

(defun cmacs-imgedit-rename-layer (name)
  "Rename the active layer to NAME."
  (interactive (list (read-string "Layer name: ")))
  (cmacs-imgedit-set-layer-name cmacs-imgedit--handle (cmacs-imgedit--active)
                                name)
  (cmacs-imgedit--render))

(defun cmacs-imgedit-duplicate-active-layer ()
  "Duplicate the active layer and select the copy."
  (interactive)
  (let ((idx (cmacs-imgedit-duplicate-layer cmacs-imgedit--handle
                                            (cmacs-imgedit--active))))
    (when (>= idx 0)
      (cmacs-imgedit-set-active-layer cmacs-imgedit--handle idx))
    (cmacs-imgedit--render)))

(defun cmacs-imgedit-toggle-layer-lock ()
  "Toggle the lock on the active layer."
  (interactive)
  (let ((i (cmacs-imgedit--active)))
    (cmacs-imgedit-set-layer-locked
     cmacs-imgedit--handle i
     (not (cmacs-imgedit-layer-locked-p cmacs-imgedit--handle i)))
    (message "Layer %d %s" i
             (if (cmacs-imgedit-layer-locked-p cmacs-imgedit--handle i)
                 "locked" "unlocked"))
    (cmacs-imgedit--render)))

(defconst cmacs-imgedit--blend-modes
  '(("Replace" . 0) ("Over" . 1) ("Add" . 2) ("Multiply" . 3) ("Subtract" . 4))
  "Blend-mode names to `GrlImageBlendMode' ints.")

(defun cmacs-imgedit-set-layer-blend-mode (mode)
  "Set the active layer's blend MODE (completing-read)."
  (interactive
   (list (cdr (assoc (completing-read "Blend mode: "
                                      cmacs-imgedit--blend-modes nil t)
                     cmacs-imgedit--blend-modes))))
  (cmacs-imgedit-set-layer-blend cmacs-imgedit--handle (cmacs-imgedit--active)
                                 mode)
  (cmacs-imgedit--render))

(defun cmacs-imgedit--menu ()
  "Return the image-editor context-menu alist (shared by native + viewport)."
  '("Image editor"
            ("Tools"
             ("Fill layer" . cmacs-imgedit-fill-layer)
             ("Flood fill…" . cmacs-imgedit-flood-fill-at)
             ("Pencil…" . cmacs-imgedit-pencil)
             ("Line…" . cmacs-imgedit-draw-line-cmd)
             ("Arrow…" . cmacs-imgedit-draw-arrow-cmd)
             ("Rectangle…" . cmacs-imgedit-draw-rect-cmd)
             ("Circle…" . cmacs-imgedit-draw-circle-cmd)
             ("Ellipse…" . cmacs-imgedit-draw-ellipse-cmd)
             ("Text…" . cmacs-imgedit-draw-text-cmd)
             ("Eyedropper…" . cmacs-imgedit-eyedropper)
             ("Foreground colour…" . cmacs-imgedit-set-foreground-color)
             ("Brush size…" . cmacs-imgedit-set-brush-size)
             ("Text size…" . cmacs-imgedit-set-text-size))
            ("Layer"
             ("Add layer…" . cmacs-imgedit-add-layer-cmd)
             ("Remove active layer" . cmacs-imgedit-remove-active-layer)
             ("Duplicate layer" . cmacs-imgedit-duplicate-active-layer)
             ("Rename layer…" . cmacs-imgedit-rename-layer)
             ("Move layer up" . cmacs-imgedit-move-layer-up)
             ("Move layer down" . cmacs-imgedit-move-layer-down)
             ("Blend mode…" . cmacs-imgedit-set-layer-blend-mode)
             ("Toggle lock" . cmacs-imgedit-toggle-layer-lock)
             ("Select layer…" . cmacs-imgedit-set-active-layer-cmd)
             ("Toggle visibility" . cmacs-imgedit-toggle-layer-visible)
             ("Opacity…" . cmacs-imgedit-set-layer-opacity-cmd)
             ("List layers" . cmacs-imgedit-list-layers))
            ("Adjust"
             ("Brightness…" . cmacs-imgedit-adjust-brightness)
             ("Contrast…" . cmacs-imgedit-adjust-contrast)
             ("Saturation…" . cmacs-imgedit-adjust-saturation)
             ("Invert" . cmacs-imgedit-invert-colors)
             ("Grayscale" . cmacs-imgedit-desaturate)
             ("Threshold…" . cmacs-imgedit-threshold-layer)
             ("Posterize…" . cmacs-imgedit-posterize-layer)
             ("Tint…" . cmacs-imgedit-tint-layer))
            ("Filter"
             ("Blur…" . cmacs-imgedit-blur-layer)
             ("Bloom" . cmacs-imgedit-bloom-layer)
             ("Sharpen" . cmacs-imgedit-sharpen-layer)
             ("Edge detect" . cmacs-imgedit-edge-detect-layer)
             ("Emboss" . cmacs-imgedit-emboss-layer)
             ("Pixelate…" . cmacs-imgedit-pixelate-layer)
             ("Noise…" . cmacs-imgedit-noise-layer))
            ("Transform"
             ("Flip horizontal" . cmacs-imgedit-flip-horizontal)
             ("Flip vertical" . cmacs-imgedit-flip-vertical)
             ("Rotate CW" . cmacs-imgedit-rotate-cw)
             ("Rotate CCW" . cmacs-imgedit-rotate-ccw)
             ("Resize…" . cmacs-imgedit-resize-image)
             ("Crop…" . cmacs-imgedit-crop-image)
             ("Gradient fill…" . cmacs-imgedit-gradient-fill))
            ("Clipboard"
             ("Copy image" . cmacs-imgedit-copy-to-clipboard)
             ("Paste image" . cmacs-imgedit-paste-from-clipboard)
             ("Paste screenshot" . cmacs-imgedit-paste-screenshot))
            ("Edit"
             ("Undo" . cmacs-imgedit-undo-cmd)
             ("Redo" . cmacs-imgedit-redo-cmd)
             ("Zoom in" . cmacs-imgedit-zoom-in)
             ("Zoom out" . cmacs-imgedit-zoom-out)
             ("Save…" . cmacs-imgedit-save-cmd))))

(defun cmacs-imgedit-context-menu (event)
  "Pop the image-editor context menu for mouse EVENT (native path).
Routes through `cmacs-libregnum-popup-menu' so it is a native GTK menu under
pgtk and the in-engine libregnum menu under the --lrg backend."
  (interactive "e")
  (cmacs-imgedit--select-event-window event)  ; commands need the canvas buffer
  (let ((choice (cmacs-libregnum-popup-menu event (cmacs-imgedit--menu))))
    (when (commandp choice)
      (call-interactively choice))))

;; --------------------------------------------------------------------------
;; Mode
;; --------------------------------------------------------------------------

(defvar cmacs-imgedit-mode-map (make-sparse-keymap)
  "Keymap for `cmacs-imgedit-mode'.")

;; Bind on EVERY load (not just the first), reusing the same keymap object, so
;; reloading the file refreshes the keys even in already-open editor buffers.
;; The `defvar' above is a no-op once the symbol is bound, which is why the
;; bindings must live in a separate top-level form.
(let ((map cmacs-imgedit-mode-map))
    ;; Tool selection (the mouse then draws with the active tool).
    (define-key map (kbd "b") #'cmacs-imgedit-use-brush)
    (define-key map (kbd "l") #'cmacs-imgedit-use-line)
    (define-key map (kbd ">") #'cmacs-imgedit-use-arrow)
    (define-key map (kbd "r") #'cmacs-imgedit-use-rectangle)
    (define-key map (kbd "c") #'cmacs-imgedit-use-circle)
    (define-key map (kbd "E") #'cmacs-imgedit-use-ellipse)
    (define-key map (kbd "t") #'cmacs-imgedit-use-text)
    (define-key map (kbd "T") #'cmacs-imgedit-set-text-size)
    (define-key map (kbd "k") #'cmacs-imgedit-use-bucket)
    (define-key map (kbd "e") #'cmacs-imgedit-use-eyedropper)
    (define-key map (kbd "x") #'cmacs-imgedit-toggle-shape-fill)
    (define-key map (kbd "C") #'cmacs-imgedit-set-foreground-color)
    (define-key map (kbd "A") #'cmacs-imgedit-set-alpha)
    (define-key map (kbd "z") #'cmacs-imgedit-set-brush-size)
    (define-key map (kbd "f") #'cmacs-imgedit-fill-layer)
    (define-key map (kbd "p") #'cmacs-imgedit-pencil)
    (define-key map (kbd "G") #'cmacs-imgedit-flood-fill-at)
    (define-key map (kbd "L") #'cmacs-imgedit-add-layer-cmd)
    (define-key map (kbd "K") #'cmacs-imgedit-remove-active-layer)
    (define-key map (kbd "a") #'cmacs-imgedit-set-active-layer-cmd)
    (define-key map (kbd "v") #'cmacs-imgedit-toggle-layer-visible)
    (define-key map (kbd "o") #'cmacs-imgedit-set-layer-opacity-cmd)
    (define-key map (kbd "?") #'cmacs-imgedit-list-layers)
    (define-key map (kbd "u") #'cmacs-imgedit-undo-cmd)
    (define-key map (kbd "U") #'cmacs-imgedit-redo-cmd)
    (define-key map (kbd "C-/") #'cmacs-imgedit-undo-cmd)
    (define-key map (kbd "s") #'cmacs-imgedit-save-cmd)
    ;; `y' = yank the image ONTO the clipboard (evil semantics: y = copy):
    ;; the annotation round-trip is  -from-clipboard -> mark up -> y -> paste
    ;; into the chat/mail.  C-y (Emacs yank) pastes an image as a new layer.
    (define-key map (kbd "y") #'cmacs-imgedit-copy-to-clipboard)
    (define-key map (kbd "w") #'cmacs-imgedit-copy-to-clipboard)
    (define-key map (kbd "C-y") #'cmacs-imgedit-paste-from-clipboard)
    (define-key map (kbd "P") #'cmacs-imgedit-paste-screenshot)
    (define-key map (kbd "+") #'cmacs-imgedit-zoom-in)
    (define-key map (kbd "-") #'cmacs-imgedit-zoom-out)
    (define-key map (kbd "<down-mouse-1>") #'cmacs-imgedit-mouse-1)
    (define-key map (kbd "<mouse-3>") #'cmacs-imgedit-context-menu)
    (define-key map (kbd "D") #'cmacs-imgedit-diagnose))

(defun cmacs-imgedit--cleanup ()
  "Free the document handle + panel buffers when the buffer is killed."
  (when (buffer-live-p cmacs-imgedit--tools-panel)
    (kill-buffer cmacs-imgedit--tools-panel))
  (when (buffer-live-p cmacs-imgedit--layers-panel)
    (kill-buffer cmacs-imgedit--layers-panel))
  ;; Detach the viewport BEFORE freeing the document: the render ctx holds a
  ;; borrowed pointer to the document, so tearing the view down first avoids a
  ;; use-after-free on the next frame.
  (when (and cmacs-imgedit--live
             (fboundp 'cmacs-libregnum-attached-p)
             (cmacs-libregnum-attached-p (current-buffer)))
    (ignore-errors (cmacs-libregnum-detach (current-buffer))))
  (when (and cmacs-imgedit--handle (fboundp 'cmacs-imgedit-free))
    (ignore-errors (cmacs-imgedit-free cmacs-imgedit--handle))
    (setq cmacs-imgedit--handle nil)))

(define-derived-mode cmacs-imgedit-mode special-mode "ImgEdit"
  "Major mode for the 2D image / sprite editor."
  (setq-local cursor-type nil)
  (setq-local cmacs-imgedit--zoom cmacs-imgedit-default-zoom)
  (buffer-disable-undo)
  (add-hook 'kill-buffer-hook #'cmacs-imgedit--cleanup nil t))

;; --------------------------------------------------------------------------
;; Entry points
;; --------------------------------------------------------------------------

(defun cmacs-imgedit--fit-zoom (handle)
  "Pick an integer zoom so HANDLE's image is a sensible on-screen size.
Big images (e.g. a clipboard screenshot) would be unusable at the default
sprite zoom, so scale down as the image grows."
  (let ((maxdim (max (cmacs-imgedit-width handle)
                     (cmacs-imgedit-height handle))))
    (cond ((<= maxdim 64) 8)
          ((<= maxdim 128) 4)
          ((<= maxdim 256) 2)
          (t 1))))

(defun cmacs-imgedit--setup-buffer (buffer handle path)
  "Initialise BUFFER as an image editor for HANDLE loaded from PATH."
  (with-current-buffer buffer
    (cmacs-imgedit-mode)
    (setq cmacs-imgedit--handle handle
          cmacs-imgedit--path path
          cmacs-imgedit--zoom (cmacs-imgedit--fit-zoom handle))
    (cmacs-imgedit--apply-color)
    (setq header-line-format
          '(:eval (format " imgedit v%d %dx%d  tool=%s  fg=%s  brush=%d  zoom=%dx  [mouse-1 draw, mouse-3 menu, D diagnose]"
                          cmacs-imgedit--ui-version
                          (cmacs-imgedit-width cmacs-imgedit--handle)
                          (cmacs-imgedit-height cmacs-imgedit--handle)
                          (alist-get cmacs-imgedit--tool cmacs-imgedit-tools)
                          (cmacs-imgedit--color-hex cmacs-imgedit--color)
                          cmacs-imgedit--brush-size cmacs-imgedit--zoom))))
  (switch-to-buffer buffer)
  ;; Open the tools + layers side panels (like the 3D editor's panels).
  (with-current-buffer buffer
    (cmacs-imgedit--open-panels)
    ;; Try the live GL viewport (gnuseye/CAD hosting pattern); on any failure
    ;; or no display, fall back to the native insert-image path.
    (cmacs-imgedit--maybe-attach-viewport buffer handle)
    (cmacs-imgedit--render))
  buffer)

(defun cmacs-imgedit--maybe-attach-viewport (buffer handle)
  "Attach a live libregnum viewport to BUFFER for HANDLE, if available.
Sets `cmacs-imgedit--live' on success; leaves it nil (native path) otherwise."
  (when (cmacs-imgedit--viewport-available-p)
    (condition-case _err
        (let ((win (get-buffer-window buffer)))
          (cmacs-libregnum-attach
           buffer
           (max 64 (if win (window-pixel-width win) 640))
           (max 64 (if win (window-pixel-height win) 480)))
          (when (cmacs-imgedit-viewport-bind handle buffer)
            (cmacs-libregnum-image-enter buffer t)
            (cmacs-libregnum-image-set-checker buffer t)
            (cmacs-libregnum-image-set-grid buffer t)
            (cmacs-imgedit--install-image-hooks buffer)
            (cmacs-libregnum-image-fit buffer)
            (setq cmacs-imgedit--live t)
            ;; refit when the window is resized (the shared size-change hook
            ;; drives cmacs-libregnum-resize; refit keeps the image centred).
            (add-hook 'window-size-change-functions
                      #'cmacs-imgedit--on-size-change nil t)))
      (error (setq cmacs-imgedit--live nil)))))

(defun cmacs-imgedit--on-size-change (&rest _)
  "Refit the image to the (resized) viewport window."
  (when (and cmacs-imgedit--live (get-buffer-window (current-buffer)))
    (ignore-errors (cmacs-libregnum-image-fit (current-buffer)))))

;;;###autoload
(defun cmacs-imgedit-new-image (width height)
  "Create a new WIDTH x HEIGHT image editor buffer."
  (interactive (list (read-number "Width: " cmacs-imgedit-default-width)
                     (read-number "Height: " cmacs-imgedit-default-height)))
  (unless (and (fboundp 'cmacs-imgedit-supported-p)
               (cmacs-imgedit-supported-p))
    (user-error "cmacs was not built with --with-cmacs-imgedit"))
  (let ((handle (cmacs-imgedit-new width height))
        (buffer (generate-new-buffer "*imgedit*")))
    (cmacs-imgedit--setup-buffer buffer handle nil)))

;;;###autoload
(defun cmacs-imgedit-open-file (file)
  "Open image FILE in a new image editor buffer."
  (interactive "fOpen image: ")
  (unless (and (fboundp 'cmacs-imgedit-supported-p)
               (cmacs-imgedit-supported-p))
    (user-error "cmacs was not built with --with-cmacs-imgedit"))
  (let ((handle (cmacs-imgedit-open (expand-file-name file)))
        (buffer (generate-new-buffer
                 (format "*imgedit: %s*" (file-name-nondirectory file)))))
    (cmacs-imgedit--setup-buffer buffer handle (expand-file-name file))))

;;;###autoload
(defun cmacs-imgedit (&optional file)
  "Open the image editor.  With FILE (or prefix arg) open an existing image."
  (interactive
   (list (when current-prefix-arg (read-file-name "Open image: "))))
  (if file
      (cmacs-imgedit-open-file file)
    (call-interactively #'cmacs-imgedit-new-image)))

;; Under Evil (Doom), the motion/normal state maps shadow the mode map
;; (emulation maps outrank major modes): down-mouse-1 runs
;; `evil-mouse-drag-region' and the tool letters run motions.  Give this
;; mode's map precedence in every state.  Canvas mouse clicks are further
;; protected by the `keymap' text property, which outranks Evil regardless.
(with-eval-after-load 'evil
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map cmacs-imgedit-mode-map)))

(provide 'cmacs-imgedit)
;;; cmacs-imgedit.el ends here
