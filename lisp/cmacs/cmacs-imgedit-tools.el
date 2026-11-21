;;; cmacs-imgedit-tools.el --- The image editor as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The twelve `imgedit_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-imgedit.c that
;; evaluated a printf-built Lisp form.  Here they are
;; `cmacs-brigade-deftool' forms (doc_org/cmacs/cmacs-capability.org has
;; the recipe), reaching in-process agents, MCP clients,
;; org.cmacs.Editor1.Tools and `emacsctl tool imgedit ...' from one
;; definition.  Wire names, parameter names and the required/optional
;; split are the C ones.  The C file is deleted; the schema it
;; published is frozen in test/cmacs/data/mcp-wire-schema.json, and
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when these
;; tools drift from it.
;;
;; Every tool works on a document HANDLE, the integer `imgedit_new' or
;; `imgedit_open' returned, so the model layer is driven headlessly: no
;; buffer, no window.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - No argument is spliced into Lisp source.  The shape and kind
;;     names select from a fixed table here exactly as they selected a
;;     branch in C.
;;
;;   - A failure is a failure, on every surface.
;;
;;   - A string result is the string, not its `prin1' form in quotes.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-imgedit-new "cmacs-imgedit-defuns.c" (width height))
(declare-function cmacs-imgedit-open "cmacs-imgedit-defuns.c" (path))
(declare-function cmacs-imgedit-save "cmacs-imgedit-defuns.c" (handle path))
(declare-function cmacs-imgedit-width "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-height "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-n-layers "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-active-layer "cmacs-imgedit-defuns.c"
                  (handle))
(declare-function cmacs-imgedit-layer-name "cmacs-imgedit-defuns.c"
                  (handle index))
(declare-function cmacs-imgedit-layer-visible-p "cmacs-imgedit-defuns.c"
                  (handle index))
(declare-function cmacs-imgedit-layer-opacity "cmacs-imgedit-defuns.c"
                  (handle index))
(declare-function cmacs-imgedit-add-layer "cmacs-imgedit-defuns.c"
                  (handle &optional name))
(declare-function cmacs-imgedit-set-color "cmacs-imgedit-defuns.c"
                  (handle r g b &optional a))
(declare-function cmacs-imgedit-push-undo "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-undo "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-draw-line "cmacs-imgedit-defuns.c"
                  (handle x1 y1 x2 y2 &optional thickness))
(declare-function cmacs-imgedit-draw-arrow "cmacs-imgedit-defuns.c"
                  (handle x1 y1 x2 y2 &optional thickness))
(declare-function cmacs-imgedit-draw-rect "cmacs-imgedit-defuns.c"
                  (handle x y w h &optional filled thickness))
(declare-function cmacs-imgedit-draw-circle "cmacs-imgedit-defuns.c"
                  (handle cx cy radius &optional filled thickness))
(declare-function cmacs-imgedit-draw-ellipse "cmacs-imgedit-defuns.c"
                  (handle cx cy rx ry &optional filled thickness))
(declare-function cmacs-imgedit-draw-text "cmacs-imgedit-defuns.c"
                  (handle x y text &optional size))
(declare-function cmacs-imgedit-brightness "cmacs-imgedit-defuns.c"
                  (handle amount))
(declare-function cmacs-imgedit-contrast "cmacs-imgedit-defuns.c"
                  (handle amount))
(declare-function cmacs-imgedit-saturation "cmacs-imgedit-defuns.c"
                  (handle amount))
(declare-function cmacs-imgedit-threshold "cmacs-imgedit-defuns.c"
                  (handle amount))
(declare-function cmacs-imgedit-posterize "cmacs-imgedit-defuns.c"
                  (handle amount))
(declare-function cmacs-imgedit-invert "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-grayscale "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-blur "cmacs-imgedit-defuns.c"
                  (handle radius))
(declare-function cmacs-imgedit-pixelate "cmacs-imgedit-defuns.c"
                  (handle radius))
(declare-function cmacs-imgedit-sharpen "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-edge-detect "cmacs-imgedit-defuns.c"
                  (handle))
(declare-function cmacs-imgedit-emboss "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-bloom "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-flip "cmacs-imgedit-defuns.c"
                  (handle horizontal))
(declare-function cmacs-imgedit-rotate "cmacs-imgedit-defuns.c"
                  (handle clockwise))

(defun cmacs-imgedit-tools--int (value what &optional default)
  "Return VALUE as an integer, DEFAULT when it is nil, else signal for WHAT."
  (cond ((integerp value) value)
        ((and (null value) default) default)
        (t (error "%s must be an integer" what))))

(defun cmacs-imgedit-tools--choice (value what choices)
  "Return VALUE if it is one of CHOICES, else signal naming WHAT.
The message is the C handler's: WHAT must be A|B|C."
  (unless (member value choices)
    (error "%s must be %s" what (string-join choices "|")))
  value)

(cmacs-brigade-deftool imgedit-new
    "Create a WIDTHxHEIGHT image document; returns its handle."
    ((width integer "Width in pixels")
     (height integer "Height in pixels"))
  :group 'imgedit
  :example "emacsctl tool imgedit new --width 256 --height 256"
  (format "handle %d"
          (cmacs-imgedit-new (cmacs-imgedit-tools--int width "width")
                             (cmacs-imgedit-tools--int height "height"))))

(cmacs-brigade-deftool imgedit-open
    "Open an image file (png/jpg/bmp/...); returns handle and size."
    ((path string "Image file to open"))
  :group 'imgedit
  :example "emacsctl tool imgedit open --path ~/Pictures/shot.png"
  (let ((h (cmacs-imgedit-open path)))
    (format "handle %d (%dx%d)" h
            (cmacs-imgedit-width h) (cmacs-imgedit-height h))))

(cmacs-brigade-deftool imgedit-save
    "Flatten and save the document (format by extension)."
    ((handle integer "Document handle")
     (path string "Destination file; the extension picks the format"))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-save
  :example "emacsctl tool imgedit save --handle 1 --path /tmp/out.png"
  (cmacs-imgedit-save (cmacs-imgedit-tools--int handle "handle") path)
  "saved")

(cmacs-brigade-deftool imgedit-info
    "Describe the document: size, active layer, layer stack."
    ((handle integer "Document handle"))
  :group 'imgedit
  :example "emacsctl tool imgedit info --handle 1"
  (let* ((h (cmacs-imgedit-tools--int handle "handle"))
         (layers nil))
    (dotimes (i (cmacs-imgedit-n-layers h))
      (push (format "%d:%s%s o=%.2f" i (cmacs-imgedit-layer-name h i)
                    (if (cmacs-imgedit-layer-visible-p h i) "" " hidden")
                    (cmacs-imgedit-layer-opacity h i))
            layers))
    (format "%dx%d active=%d layers: %s"
            (cmacs-imgedit-width h) (cmacs-imgedit-height h)
            (cmacs-imgedit-active-layer h)
            (string-join (nreverse layers) " | "))))

(cmacs-brigade-deftool imgedit-set-color
    "Set the draw colour (RGBA 0..255) used by the shape/text tools."
    ((handle integer "Document handle")
     (r integer "Red, 0-255")
     (g integer "Green, 0-255")
     (b integer "Blue, 0-255")
     (a integer "Alpha, 0-255 (default 255)" :optional t))
  :group 'imgedit
  :destructive t
  :undo '(irreversible "the draw colour has no reader to restore from")
  :example "emacsctl tool imgedit set-color --handle 1 --r 255 --g 0 --b 0"
  (cmacs-imgedit-set-color (cmacs-imgedit-tools--int handle "handle")
                           (cmacs-imgedit-tools--int r "r")
                           (cmacs-imgedit-tools--int g "g")
                           (cmacs-imgedit-tools--int b "b")
                           (cmacs-imgedit-tools--int a "a" 255))
  "ok")

(cmacs-brigade-deftool imgedit-draw-shape
    "Draw on the active layer (one undo step).  SHAPE: line|arrow (x1,y1 \
-> x2,y2), rect (corners x1,y1 / x2,y2), circle (centre x1,y1, radius \
x2), ellipse (centre x1,y1, radii x2,y2).  FILLED for \
rect/circle/ellipse."
    ((handle integer "Document handle")
     (shape string "line, arrow, rect, circle or ellipse")
     (x1 integer "First x")
     (y1 integer "First y")
     (x2 integer "Second x, or the radius (default 0)" :optional t)
     (y2 integer "Second y, or the y radius (default 0)" :optional t)
     (filled boolean "Fill a rect, circle or ellipse" :optional t)
     (thickness integer "Stroke width in pixels (default 1)" :optional t))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-edit
  :example "emacsctl tool imgedit draw-shape --handle 1 --shape rect \
--x1 10 --y1 10 --x2 90 --y2 60 --filled true"
  (let ((h (cmacs-imgedit-tools--int handle "handle"))
        (shape (cmacs-imgedit-tools--choice
                shape "shape" '("line" "arrow" "rect" "circle" "ellipse")))
        (x1 (cmacs-imgedit-tools--int x1 "x1"))
        (y1 (cmacs-imgedit-tools--int y1 "y1"))
        (x2 (cmacs-imgedit-tools--int x2 "x2" 0))
        (y2 (cmacs-imgedit-tools--int y2 "y2" 0))
        (th (cmacs-imgedit-tools--int thickness "thickness" 1))
        (filled (and filled t)))
    (cmacs-imgedit-push-undo h)
    (pcase shape
      ("line" (cmacs-imgedit-draw-line h x1 y1 x2 y2 th))
      ("arrow" (cmacs-imgedit-draw-arrow h x1 y1 x2 y2 th))
      ;; The tool takes two corners; the primitive takes a corner and a
      ;; size.
      ("rect" (cmacs-imgedit-draw-rect h x1 y1 (- x2 x1) (- y2 y1) filled th))
      ;; x2 is the radius.
      ("circle" (cmacs-imgedit-draw-circle h x1 y1 x2 filled th))
      ("ellipse" (cmacs-imgedit-draw-ellipse h x1 y1 x2 y2 filled th)))
    "drawn"))

(cmacs-brigade-deftool imgedit-adjust
    "Adjust the active layer.  KIND: \
brightness|contrast|saturation|threshold|posterize (with AMOUNT) or \
invert|grayscale."
    ((handle integer "Document handle")
     (kind string "Which adjustment")
     (amount number "Strength, for the kinds that take one (default 0)"
             :optional t))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-edit
  :example "emacsctl tool imgedit adjust --handle 1 --kind contrast \
--amount 1.2"
  (let ((h (cmacs-imgedit-tools--int handle "handle"))
        (kind (cmacs-imgedit-tools--choice
               kind "kind" '("brightness" "contrast" "saturation"
                             "threshold" "posterize" "invert" "grayscale")))
        (amount (cond ((null amount) 0.0)
                      ((numberp amount) amount)
                      (t (error "amount must be a number")))))
    (cmacs-imgedit-push-undo h)
    (pcase kind
      ;; Brightness, threshold and posterize take whole steps.
      ("brightness" (cmacs-imgedit-brightness h (truncate amount)))
      ("contrast" (cmacs-imgedit-contrast h amount))
      ("saturation" (cmacs-imgedit-saturation h amount))
      ("threshold" (cmacs-imgedit-threshold h (truncate amount)))
      ("posterize" (cmacs-imgedit-posterize h (truncate amount)))
      ("invert" (cmacs-imgedit-invert h))
      ("grayscale" (cmacs-imgedit-grayscale h)))
    "ok"))

(cmacs-brigade-deftool imgedit-filter
    "Filter the active layer.  KIND: blur|pixelate (RADIUS) or \
sharpen|edge|emboss|bloom."
    ((handle integer "Document handle")
     (kind string "Which filter")
     (radius integer "Radius for blur and pixelate (default 2)" :optional t))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-edit
  :example "emacsctl tool imgedit filter --handle 1 --kind blur --radius 4"
  (let ((h (cmacs-imgedit-tools--int handle "handle"))
        (kind (cmacs-imgedit-tools--choice
               kind "kind" '("blur" "pixelate" "sharpen" "edge" "emboss"
                             "bloom")))
        (radius (cmacs-imgedit-tools--int radius "radius" 2)))
    (cmacs-imgedit-push-undo h)
    (pcase kind
      ("blur" (cmacs-imgedit-blur h radius))
      ("pixelate" (cmacs-imgedit-pixelate h radius))
      ("sharpen" (cmacs-imgedit-sharpen h))
      ("edge" (cmacs-imgedit-edge-detect h))
      ("emboss" (cmacs-imgedit-emboss h))
      ("bloom" (cmacs-imgedit-bloom h)))
    "ok"))

(cmacs-brigade-deftool imgedit-transform
    "Transform the whole document.  KIND: \
flip-h|flip-v|rotate-cw|rotate-ccw."
    ((handle integer "Document handle")
     (kind string "Which transform"))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-edit
  :example "emacsctl tool imgedit transform --handle 1 --kind rotate-cw"
  (let ((h (cmacs-imgedit-tools--int handle "handle"))
        (kind (cmacs-imgedit-tools--choice
               kind "kind" '("flip-h" "flip-v" "rotate-cw" "rotate-ccw"))))
    (cmacs-imgedit-push-undo h)
    (pcase kind
      ("flip-h" (cmacs-imgedit-flip h t))
      ("flip-v" (cmacs-imgedit-flip h nil))
      ("rotate-cw" (cmacs-imgedit-rotate h t))
      ("rotate-ccw" (cmacs-imgedit-rotate h nil)))
    "ok"))

(cmacs-brigade-deftool imgedit-draw-text
    "Draw TEXT at X,Y in the current colour (SIZE px; one undo step)."
    ((handle integer "Document handle")
     (x integer "Left edge of the text")
     (y integer "Top edge of the text")
     (text string "Text to draw")
     (size integer "Font size in pixels (default 16)" :optional t))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-edit
  :example "emacsctl tool imgedit draw-text --handle 1 --x 8 --y 8 \
--text Hello"
  (let ((h (cmacs-imgedit-tools--int handle "handle")))
    (cmacs-imgedit-push-undo h)
    (cmacs-imgedit-draw-text h (cmacs-imgedit-tools--int x "x")
                             (cmacs-imgedit-tools--int y "y") text
                             (cmacs-imgedit-tools--int size "size" 16))
    "drawn"))

(cmacs-brigade-deftool imgedit-add-layer
    "Append a transparent layer (becomes active); returns its index."
    ((handle integer "Document handle")
     (name string "Name for the layer" :optional t))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-add-layer
  :example "emacsctl tool imgedit add-layer --handle 1 --name Notes"
  (format "layer %d"
          (cmacs-imgedit-add-layer (cmacs-imgedit-tools--int handle "handle")
                                   name)))

(cmacs-brigade-deftool imgedit-undo
    "Undo the last edit on the document."
    ((handle integer "Document handle"))
  :group 'imgedit
  :destructive t
  :undo 'cmacs-brigade-undo-capture-imgedit-undo
  :example "emacsctl tool imgedit undo --handle 1"
  ;; An empty undo stack is an answer, not a failure.
  (if (cmacs-imgedit-undo (cmacs-imgedit-tools--int handle "handle"))
      "undone"
    "nothing"))

(provide 'cmacs-imgedit-tools)

;;; cmacs-imgedit-tools.el ends here
