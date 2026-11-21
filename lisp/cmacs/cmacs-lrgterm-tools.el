;;; cmacs-lrgterm-tools.el --- The lrg display backend as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Ten of the eleven `lrgterm_*' tools, written once.
;;
;; They used to be handlers in cmacs/mcp/cmacs-mcp-tools-lrgterm.c that
;; evaluated a printf-built Lisp form.  Here they are
;; `cmacs-brigade-deftool' forms (doc_org/cmacs/cmacs-capability.org has
;; the recipe), reaching in-process agents, MCP clients,
;; org.cmacs.Editor1.Tools and `emacsctl tool lrgterm ...' from one
;; definition.  Wire names are the C ones, and the C file stays as the
;; fallback for a build without the brigade;
;; test/cmacs/cmacs-gsurf-lrg-cad-media-tools-tests.el fails when the
;; two drift.
;;
;; Not here: `lrgterm_dump_screen'.  It answers with an inline PNG, and
;; the registry's results are text; it keeps its C handler.
;;
;; What differs from the C handlers, on purpose:
;;
;;   - A failure is a failure.  "No lrg frame" and "not a 3D lrg frame"
;;     were ordinary results; they are errors now.
;;
;;   - A string result is the string, not its `prin1' form in quotes.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function lrg-display-pixel-size "cmacs-lrgterm.c" ())
(declare-function cmacs-lrg-render-mode "cmacs-lrgterm.c" (&optional frame))
(declare-function cmacs-lrg-3d-arrangement "cmacs-lrgterm.c"
                  (&optional frame))
(declare-function cmacs-lrg-3d-environment "cmacs-lrgterm.c"
                  (&optional frame))
(declare-function cmacs-lrg-3d-set-arrangement "cmacs-lrgterm.c"
                  (name &optional frame))
(declare-function cmacs-lrg-3d-set-environment "cmacs-lrgterm.c"
                  (name &optional frame))
(declare-function cmacs-lrg-3d-camera "cmacs-lrgterm.c"
                  (action &optional amount frame))
(declare-function cmacs-lrg-3d-focus-panel "cmacs-lrgterm.c"
                  (&optional window frame))
(declare-function cmacs-lrg-3d-pin-panel "cmacs-lrgterm.c"
                  (&optional window frame))
(declare-function cmacs-lrg-3d-unpin-panel "cmacs-lrgterm.c"
                  (&optional window frame))

(defconst cmacs-lrgterm-tools--arrangements
  '("single-panel" "per-window" "free")
  "The 3D panel arrangements, in the order the cycle tool visits them.")

(defconst cmacs-lrgterm-tools--environments
  '("void" "workshop" "cockpit")
  "The 3D ambient environments, in the order the cycle tool visits them.")

(defun cmacs-lrgterm-tools--frame ()
  "Return the first live output_lrg frame, or signal when there is none."
  (or (seq-find (lambda (frame) (eq (framep frame) 'lrg)) (frame-list))
      (error "No lrg frame (start Emacs with --lrg)")))

(defun cmacs-lrgterm-tools--3d (ok text)
  "Return TEXT when OK is non-nil; otherwise signal that the frame is flat.
The 3D primitives answer nil on a frame that is not in a 3D render mode."
  (unless ok
    (error "Not a 3D lrg frame"))
  text)

(defun cmacs-lrgterm-tools--next (current all)
  "Return the element of ALL after CURRENT, wrapping to the first."
  (or (cadr (member current all)) (car all)))

(cmacs-brigade-deftool lrgterm-frame-info
    "Report the output_lrg frame's pixel/char size, font and monitor."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm frame-info"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (format "size=%dx%d px  %dx%d chars  col=%d line=%d  font=%S  monitor=%S"
            (frame-pixel-width f) (frame-pixel-height f)
            (frame-width f) (frame-height f)
            (frame-char-width f) (frame-char-height f)
            (frame-parameter f 'font) (lrg-display-pixel-size))))

(cmacs-brigade-deftool lrgterm-render-stats
    "Report lrg display stats (frame count, visibility, focus, colour \
depth)."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm render-stats"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (format "frames=%d  visible=%S  focus=%S  display-cells=%d  visual=%S"
            (length (frame-list)) (frame-visible-p f)
            (eq f (selected-frame)) (display-color-cells f)
            (display-visual-class f))))

(cmacs-brigade-deftool lrgterm-force-redraw
    "Force a full redraw + present of the lrg frame."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm force-redraw"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (redraw-frame f)
    ;; One synchronous redisplay pass: it draws, it does not wait on
    ;; input or on a subprocess.
    (redisplay t)
    "redrawn"))

(cmacs-brigade-deftool lrgterm-3d-state
    "Report the lrg 3D render mode, panel arrangement and ambient \
environment."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-state"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (format "render-mode=%S arrangement=%S environment=%S"
            (cmacs-lrg-render-mode f) (cmacs-lrg-3d-arrangement f)
            (cmacs-lrg-3d-environment f))))

(cmacs-brigade-deftool lrgterm-3d-cycle-arrangement
    "Cycle the 3D panel arrangement (single-panel -> per-window -> free)."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-cycle-arrangement"
  (let* ((f (cmacs-lrgterm-tools--frame))
         (next (cmacs-lrgterm-tools--next
                (cmacs-lrg-3d-arrangement f)
                cmacs-lrgterm-tools--arrangements)))
    (cmacs-lrgterm-tools--3d (cmacs-lrg-3d-set-arrangement next f)
                             (format "arrangement -> %s" next))))

(cmacs-brigade-deftool lrgterm-3d-cycle-environment
    "Cycle the 3D ambient environment (void -> workshop -> cockpit)."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-cycle-environment"
  (let* ((f (cmacs-lrgterm-tools--frame))
         (next (cmacs-lrgterm-tools--next
                (cmacs-lrg-3d-environment f)
                cmacs-lrgterm-tools--environments)))
    (cmacs-lrgterm-tools--3d (cmacs-lrg-3d-set-environment next f)
                             (format "environment -> %s" next))))

(cmacs-brigade-deftool lrgterm-3d-camera-orbit
    "Orbit the 3D camera around the panels (use lrgterm_dump_screen to \
see it)."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-camera-orbit"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (cmacs-lrgterm-tools--3d (cmacs-lrg-3d-camera "orbit-left" 20 f)
                             "orbited")))

(cmacs-brigade-deftool lrgterm-3d-focus-selected
    "Bring the selected window's 3D panel front-and-centre (fly the \
camera to it and focus it; others recede). The 'command-the-room' \
gesture."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-focus-selected"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (cmacs-lrgterm-tools--3d
     (cmacs-lrg-3d-focus-panel (frame-selected-window f) f)
     "focused the selected window front-and-centre")))

(cmacs-brigade-deftool lrgterm-3d-pin-selected
    "Pin the selected window's 3D panel in place so the arrangement no \
longer moves it."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-pin-selected"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (cmacs-lrgterm-tools--3d
     (cmacs-lrg-3d-pin-panel (frame-selected-window f) f)
     "pinned the selected window's panel in place")))

(cmacs-brigade-deftool lrgterm-3d-unpin-all
    "Release all manually-placed 3D panels back to automatic layout."
    ()
  :group 'lrgterm
  :example "emacsctl tool lrgterm 3d-unpin-all"
  (let ((f (cmacs-lrgterm-tools--frame)))
    (cmacs-lrgterm-tools--3d
     (cmacs-lrg-3d-unpin-panel t f)
     "released all panels back to automatic layout")))

(provide 'cmacs-lrgterm-tools)

;;; cmacs-lrgterm-tools.el ends here
