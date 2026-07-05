;;; cmacs-imgedit-tests.el --- Tests for the 2D image editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the cmacs-imgedit-* C primitives (the image / sprite editor
;; model layer).  These exercise the LrgImageDocument-backed DEFUNs and run
;; headlessly -- no display required.  Skipped unless cmacs was built with
;; --with-cmacs-imgedit.

;;; Code:

(require 'ert)

(defmacro cmacs-imgedit-tests--skip-unless ()
  "Skip the test unless the image editor is available."
  '(skip-unless (and (fboundp 'cmacs-imgedit-supported-p)
                     (cmacs-imgedit-supported-p))))

(defmacro cmacs-imgedit-tests--with-doc (var w h &rest body)
  "Bind VAR to a fresh WxH image handle, run BODY, then free it."
  (declare (indent 3))
  `(let ((,var (cmacs-imgedit-new ,w ,h)))
     (unwind-protect (progn ,@body)
       (cmacs-imgedit-free ,var))))

(ert-deftest cmacs-imgedit-new-dimensions ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 64 48
    (should (= (cmacs-imgedit-width h) 64))
    (should (= (cmacs-imgedit-height h) 48))
    (should (= (cmacs-imgedit-n-layers h) 1))
    (should (= (cmacs-imgedit-active-layer h) 0))))

(ert-deftest cmacs-imgedit-layers ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 8 8
    (should (= (cmacs-imgedit-add-layer h "Top") 1))
    (should (= (cmacs-imgedit-n-layers h) 2))
    (should (string= (cmacs-imgedit-layer-name h 1) "Top"))
    (should (cmacs-imgedit-move-layer h 1 0))
    (should (string= (cmacs-imgedit-layer-name h 0) "Top"))
    (should (= (cmacs-imgedit-duplicate-layer h 0) 1))
    (should (= (cmacs-imgedit-n-layers h) 3))
    (should (cmacs-imgedit-remove-layer h 0))
    (should (cmacs-imgedit-remove-layer h 0))
    ;; The last layer cannot be removed.
    (should-not (cmacs-imgedit-remove-layer h 0))))

(ert-deftest cmacs-imgedit-fill-and-pixel ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 4 4
    (cmacs-imgedit-fill h 255 0 0 255)
    (should (equal (cmacs-imgedit-pixel-at h 0 0) '(255 0 0 255)))
    (should (equal (cmacs-imgedit-pixel-at h 3 3) '(255 0 0 255)))
    ;; Out of bounds -> nil.
    (should-not (cmacs-imgedit-pixel-at h 4 0))))

(ert-deftest cmacs-imgedit-draw-rect ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 8 8
    ;; Filled blue rectangle covering the whole canvas.
    (cmacs-imgedit-set-color h 0 0 255 255)
    (cmacs-imgedit-draw-rect h 0 0 8 8 t 1)
    (should (equal (cmacs-imgedit-pixel-at h 4 4) '(0 0 255 255)))))

(ert-deftest cmacs-imgedit-flood-fill ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 4 4
    (cmacs-imgedit-fill h 255 255 255 255)
    (cmacs-imgedit-flood-fill h 0 0 0 255 0 255 0)
    (should (equal (cmacs-imgedit-pixel-at h 2 2) '(0 255 0 255)))))

(ert-deftest cmacs-imgedit-layer-blend-over ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 4 4
    (cmacs-imgedit-fill h 255 0 0 255)        ; layer 0 red
    (cmacs-imgedit-add-layer h "Top")
    (cmacs-imgedit-fill h 0 0 255 255)        ; layer 1 blue, OVER
    (should (equal (cmacs-imgedit-pixel-at h 0 0) '(0 0 255 255)))
    ;; Hide the top layer -> red shows through.
    (cmacs-imgedit-set-layer-visible h 1 nil)
    (should (equal (cmacs-imgedit-pixel-at h 0 0) '(255 0 0 255)))))

(ert-deftest cmacs-imgedit-undo-redo ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 4 4
    (cmacs-imgedit-fill h 255 0 0 255)
    (should-not (cmacs-imgedit-can-undo-p h))
    (cmacs-imgedit-push-undo h)
    (cmacs-imgedit-fill h 0 0 255 255)
    (should (equal (cmacs-imgedit-pixel-at h 0 0) '(0 0 255 255)))
    (should (cmacs-imgedit-can-undo-p h))
    (should (cmacs-imgedit-undo h))
    (should (equal (cmacs-imgedit-pixel-at h 0 0) '(255 0 0 255)))
    (should (cmacs-imgedit-can-redo-p h))
    (should (cmacs-imgedit-redo h))
    (should (equal (cmacs-imgedit-pixel-at h 0 0) '(0 0 255 255)))))

(ert-deftest cmacs-imgedit-add-layer-rgba ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 2 2
    ;; A 2x2 all-green RGBA buffer.
    (let ((rgba (apply #'unibyte-string
                       (apply #'append (make-list 4 '(0 255 0 255))))))
      (let ((idx (cmacs-imgedit-add-layer-rgba h 2 2 rgba "Pasted")))
        (should (>= idx 1))
        (should (equal (cmacs-imgedit-pixel-at h 0 0) '(0 255 0 255)))))))

(ert-deftest cmacs-imgedit-export-png-bytes ()
  (cmacs-imgedit-tests--skip-unless)
  (cmacs-imgedit-tests--with-doc h 4 4
    (cmacs-imgedit-fill h 10 20 30 255)
    (let ((png (cmacs-imgedit-export-png-bytes h)))
      (should (stringp png))
      (should (> (length png) 8))
      ;; PNG magic: 0x89 'P' 'N' 'G'.
      (should (= (aref png 0) #x89))
      (should (= (aref png 1) ?P)))))

(ert-deftest cmacs-imgedit-save-and-reopen ()
  (cmacs-imgedit-tests--skip-unless)
  (let ((path (make-temp-file "cmacs-imgedit-" nil ".png")))
    (unwind-protect
        (progn
          (cmacs-imgedit-tests--with-doc h 4 4
            (cmacs-imgedit-fill h 0 255 0 255)
            (should (cmacs-imgedit-save h path)))
          (should (file-exists-p path))
          (let ((h3 (cmacs-imgedit-open path)))
            (unwind-protect
                (progn
                  (should (= (cmacs-imgedit-width h3) 4))
                  (let ((px (cmacs-imgedit-pixel-at h3 0 0)))
                    (should (> (nth 1 px) 250))
                    (should (< (nth 0 px) 5))))
              (cmacs-imgedit-free h3))))
      (delete-file path))))

(ert-deftest cmacs-imgedit-gtk-clipboard-headless ()
  "The GTK clipboard degrades cleanly with no display: available-p nil,
get returns nil, set signals (never crashes)."
  (cmacs-imgedit-tests--skip-unless)
  (skip-unless (fboundp 'cmacs-imgedit-clipboard-available-p))
  (skip-unless (not (cmacs-imgedit-clipboard-available-p))) ; headless only
  (should-not (cmacs-imgedit-clipboard-get-png))
  (should-error (cmacs-imgedit-clipboard-set-png "not-a-png")))

(ert-deftest cmacs-imgedit-annotation-shapes ()
  "Arrow (both directions), ellipse (outline + filled), text."
  (cmacs-imgedit-tests--skip-unless)
  (skip-unless (fboundp 'cmacs-imgedit-draw-arrow))
  (cmacs-imgedit-tests--with-doc h 64 64
    ;; Arrow left->right: shaft and head pixels painted.
    (cmacs-imgedit-set-color h 255 0 0 255)
    (cmacs-imgedit-draw-arrow h 10 32 50 32 2)
    (should (equal (cmacs-imgedit-pixel-at h 25 32) '(255 0 0 255)))
    (should (equal (cmacs-imgedit-pixel-at h 48 32) '(255 0 0 255)))
    ;; Opposite direction: triangle winding must still fill the head.
    (cmacs-imgedit-set-color h 0 255 0 255)
    (cmacs-imgedit-draw-arrow h 50 10 10 10 2)
    (should (equal (cmacs-imgedit-pixel-at h 12 10) '(0 255 0 255)))
    ;; Ellipse outline: edge painted, centre untouched.
    (cmacs-imgedit-set-color h 0 0 255 255)
    (cmacs-imgedit-draw-ellipse h 32 48 20 8 nil 2)
    (should (equal (cmacs-imgedit-pixel-at h 12 48) '(0 0 255 255)))
    (should (equal (cmacs-imgedit-pixel-at h 32 48) '(0 0 0 0)))
    ;; Filled ellipse covers the centre.
    (cmacs-imgedit-draw-ellipse h 32 48 6 3 t 1)
    (should (equal (cmacs-imgedit-pixel-at h 32 48) '(0 0 255 255)))
    ;; Text: the embedded bitmap font sets pixels in the glyph box.
    (cmacs-imgedit-set-color h 255 255 0 255)
    (cmacs-imgedit-draw-text h 2 20 "Hi" 12)
    (should (cl-loop for x from 2 to 21 thereis
                     (cl-loop for y from 20 to 33 thereis
                              (equal (cmacs-imgedit-pixel-at h x y)
                                     '(255 255 0 255)))))))

(ert-deftest cmacs-imgedit-mouse-click-from-other-buffer ()
  "A canvas click must draw even when another window/buffer is selected.
Mouse commands run with the SELECTED window's buffer current (e.g. a side
panel after clicking a tool button); the handler must switch to the clicked
window's buffer or it silently no-ops on the panel's nil handle."
  (cmacs-imgedit-tests--skip-unless)
  (require 'cmacs-imgedit)
  (let* ((h (cmacs-imgedit-new 64 64))
         (canvas (generate-new-buffer "*imgedit-test-canvas*"))
         (panel (generate-new-buffer "*imgedit-test-panel*"))
         (cwin (frame-root-window))
         pwin)
    (unwind-protect
        (progn
          (setq pwin (split-window cwin))
          (with-current-buffer canvas
            (cmacs-imgedit-mode)
            (setq cmacs-imgedit--handle h
                  cmacs-imgedit--tool 'fill
                  cmacs-imgedit--color (list 255 0 0 255)))
          (set-window-buffer cwin canvas)
          (set-window-buffer pwin panel)
          (select-window pwin)          ; the state after a panel-button click
          (let* ((posn (list cwin 1 (cons 256 256) 0 nil 1 (cons 1 1) nil
                             (cons 256 256) (cons 512 512)))
                 (ev (list 'down-mouse-1 posn)))
            (cmacs-imgedit-mouse-1 ev))
          (should (equal (cmacs-imgedit-pixel-at h 32 32) '(255 0 0 255))))
      (when (window-live-p pwin) (delete-window pwin))
      ;; Detach the handle so killing the canvas buffer's cleanup hook does
      ;; not free it twice; free it ourselves below.
      (with-current-buffer canvas (setq cmacs-imgedit--handle nil))
      (kill-buffer canvas)
      (kill-buffer panel)
      (ignore-errors (cmacs-imgedit-free h)))))

(ert-deftest cmacs-imgedit-canvas-keymap-beats-emulation-maps ()
  "The canvas text-property keymap must win over emulation maps.
Evil (Doom) binds down-mouse-1 in its state maps, which outrank the
major-mode map — only a position `keymap' property outranks those.
Simulate that shadowing generically and assert the canvas still resolves
to the editor's handler."
  (cmacs-imgedit-tests--skip-unless)
  (require 'cmacs-imgedit)
  (let* ((h (cmacs-imgedit-new 16 16))
         (buf (generate-new-buffer "*imgedit-test-keymap*"))
         (shadow-map (make-sparse-keymap))
         ;; Key `t' = unconditionally active, like an enabled Evil state map.
         (emulation-mode-map-alists
          (cons (list (cons t shadow-map)) emulation-mode-map-alists)))
    (define-key shadow-map [down-mouse-1] #'ignore)
    (define-key shadow-map [down-mouse-3] #'ignore)
    (unwind-protect
        (progn
          ;; Without the canvas text property the emulation map shadows the
          ;; mode map — the exact pre-fix failure under Evil.
          (with-temp-buffer
            (cmacs-imgedit-mode)
            (should (eq (key-binding [down-mouse-1]) #'ignore)))
          ;; On the rendered canvas the position keymap outranks it.
          (with-current-buffer buf
            (cmacs-imgedit-mode)
            (setq cmacs-imgedit--handle h)
            (cmacs-imgedit--render)
            (should (eq (key-binding [down-mouse-1] nil nil (point-min))
                        'cmacs-imgedit-mouse-1))
            (should (eq (key-binding [down-mouse-3] nil nil (point-min))
                        'cmacs-imgedit-context-menu))))
      (with-current-buffer buf (setq cmacs-imgedit--handle nil))
      (kill-buffer buf)
      (ignore-errors (cmacs-imgedit-free h)))))

(ert-deftest cmacs-imgedit-drag-without-motion-events ()
  "A drag must commit at the RELEASE position even with no motion events.
Display backends may deliver zero mouse-movement events during
`track-mouse' (the --lrg backend did, before its mouse_moved fix); the
shape loops must then take the endpoint from the button-release event
itself instead of drawing a dot at the press position."
  (cmacs-imgedit-tests--skip-unless)
  (require 'cmacs-imgedit)
  (let* ((h (cmacs-imgedit-new 64 64))
         (canvas (generate-new-buffer "*imgedit-test-drag*"))
         (win (frame-root-window)))
    (unwind-protect
        (progn
          (with-current-buffer canvas
            (cmacs-imgedit-mode)
            (setq cmacs-imgedit--handle h
                  cmacs-imgedit--tool 'line
                  cmacs-imgedit--color (list 255 0 0 255)))
          (set-window-buffer win canvas)
          (select-window win)
          (let* ((down-posn (list win 1 (cons 64 64) 0 nil 1 (cons 1 1) nil
                                  (cons 64 64) (cons 512 512)))    ; -> (8,8)
                 (up-posn (list win 1 (cons 448 448) 0 nil 1 (cons 1 1) nil
                                (cons 448 448) (cons 512 512)))    ; -> (56,56)
                 ;; A cross-canvas drag terminates as `drag-mouse-1' with
                 ;; TWO posns: event-start = the PRESS, event-end = the
                 ;; release.  The loop must take the endpoint from
                 ;; event-end -- reading event-start rewound every drag
                 ;; to its press point (the --lrg "only a dot" bug).
                 (unread-command-events
                  (list (list 'drag-mouse-1 down-posn up-posn))))
            (cmacs-imgedit-mouse-1 (list 'down-mouse-1 down-posn)))
          ;; The line must reach the release point, not stop at the press.
          (should (equal (cmacs-imgedit-pixel-at h 56 56) '(255 0 0 255)))
          (should (equal (cmacs-imgedit-pixel-at h 32 32) '(255 0 0 255)))
          ;; A plain click (no drag detected): event-end = event-start.
          (with-current-buffer canvas
            (setq cmacs-imgedit--color (list 0 255 0 255)))
          (let* ((down2 (list win 1 (cons 64 448) 0 nil 1 (cons 1 1) nil
                              (cons 64 448) (cons 512 512)))       ; -> (8,56)
                 (unread-command-events (list (list 'mouse-1 down2 1))))
            (cmacs-imgedit-mouse-1 (list 'down-mouse-1 down2)))
          (should (equal (cmacs-imgedit-pixel-at h 8 56) '(0 255 0 255))))
      (with-current-buffer canvas (setq cmacs-imgedit--handle nil))
      (kill-buffer canvas)
      (ignore-errors (cmacs-imgedit-free h)))))

;; ── Adjustments / filters / flip / lock (headless model ops) ────────────

(ert-deftest cmacs-imgedit-tests-adjustments ()
  "Invert, brightness, grayscale, and color-replace transform pixels."
  (skip-unless (fboundp 'cmacs-imgedit-new))
  (let ((h (cmacs-imgedit-new 8 8)))
    (unwind-protect
        (progn
          (cmacs-imgedit-fill h 200 100 50 255)
          (cmacs-imgedit-invert h)
          (should (equal (cmacs-imgedit-pixel-at h 4 4) '(55 155 205 255)))
          (cmacs-imgedit-fill h 100 100 100 255)
          (cmacs-imgedit-brightness h 50)
          (should (equal (cmacs-imgedit-pixel-at h 4 4) '(150 150 150 255)))
          (cmacs-imgedit-fill h 90 30 210 255)
          (cmacs-imgedit-grayscale h)
          (let ((p (cmacs-imgedit-pixel-at h 4 4)))    ; R==G==B after gray
            (should (= (nth 0 p) (nth 1 p)))
            (should (= (nth 1 p) (nth 2 p))))
          (cmacs-imgedit-fill h 10 20 30 255)
          (cmacs-imgedit-color-replace h '(10 20 30 255) '(90 80 70 255))
          (should (equal (cmacs-imgedit-pixel-at h 4 4) '(90 80 70 255))))
      (cmacs-imgedit-free h))))

(ert-deftest cmacs-imgedit-tests-flip ()
  "A whole-document horizontal flip mirrors pixels left-to-right."
  (skip-unless (fboundp 'cmacs-imgedit-new))
  (let ((h (cmacs-imgedit-new 4 1)))
    (unwind-protect
        (progn
          (cmacs-imgedit-set-pixel h 0 0 255 0 0 255)   ; red at x=0
          (cmacs-imgedit-set-pixel h 3 0 0 255 0 255)   ; green at x=3
          (cmacs-imgedit-flip h t)
          (should (equal (cmacs-imgedit-pixel-at h 3 0) '(255 0 0 255)))
          (should (equal (cmacs-imgedit-pixel-at h 0 0) '(0 255 0 255))))
      (cmacs-imgedit-free h))))

(ert-deftest cmacs-imgedit-tests-layer-lock ()
  "A locked layer refuses edits until unlocked."
  (skip-unless (fboundp 'cmacs-imgedit-set-layer-locked))
  (let ((h (cmacs-imgedit-new 4 4)))
    (unwind-protect
        (progn
          (cmacs-imgedit-fill h 90 80 70 255)
          (cmacs-imgedit-set-layer-locked h 0 t)
          (should (cmacs-imgedit-layer-locked-p h 0))
          (cmacs-imgedit-fill h 1 2 3 255)              ; ignored while locked
          (should (equal (cmacs-imgedit-pixel-at h 2 2) '(90 80 70 255)))
          (cmacs-imgedit-set-layer-locked h 0 nil)
          (cmacs-imgedit-fill h 1 2 3 255)
          (should (equal (cmacs-imgedit-pixel-at h 2 2) '(1 2 3 255))))
      (cmacs-imgedit-free h))))

;; ── Transforms + pixel-buffer filters ──────────────────────────────────

(ert-deftest cmacs-imgedit-tests-transforms ()
  "Resize / crop / rotate change the document dimensions correctly."
  (skip-unless (fboundp 'cmacs-imgedit-resize))
  (let ((h (cmacs-imgedit-new 8 4)))
    (unwind-protect
        (progn
          (cmacs-imgedit-resize h 16 8)
          (should (= (cmacs-imgedit-width h) 16))
          (should (= (cmacs-imgedit-height h) 8))
          (cmacs-imgedit-crop h 2 1 10 6)
          (should (= (cmacs-imgedit-width h) 10))
          (should (= (cmacs-imgedit-height h) 6))
          (cmacs-imgedit-rotate h t)          ; 10x6 -> 6x10
          (should (= (cmacs-imgedit-width h) 6))
          (should (= (cmacs-imgedit-height h) 10)))
      (cmacs-imgedit-free h))))

(ert-deftest cmacs-imgedit-tests-pixel-filters ()
  "Threshold, posterize, and pixelate remap the active layer."
  (skip-unless (fboundp 'cmacs-imgedit-threshold))
  (let ((h (cmacs-imgedit-new 8 8)))
    (unwind-protect
        (progn
          (cmacs-imgedit-fill h 200 200 200 255)
          (cmacs-imgedit-threshold h 128)
          (should (equal (cmacs-imgedit-pixel-at h 4 4) '(255 255 255 255)))
          (cmacs-imgedit-fill h 10 10 10 255)
          (cmacs-imgedit-threshold h 128)
          (should (equal (cmacs-imgedit-pixel-at h 4 4) '(0 0 0 255)))
          ;; posterize to 2 levels snaps a mid value to an endpoint
          (cmacs-imgedit-fill h 200 40 130 255)
          (cmacs-imgedit-posterize h 2)
          (let ((p (cmacs-imgedit-pixel-at h 4 4)))
            (dolist (c (list (nth 0 p) (nth 1 p) (nth 2 p)))
              (should (memq c '(0 255)))))
          ;; pixelate a checker -> a uniform block average (no crash, alpha kept)
          (cmacs-imgedit-pixelate h 8)
          (should (= (nth 3 (cmacs-imgedit-pixel-at h 4 4)) 255)))
      (cmacs-imgedit-free h))))

(ert-deftest cmacs-imgedit-tests-svg-import ()
  "Importing an SVG rect fills the active layer with its colour."
  (skip-unless (fboundp 'cmacs-imgedit-import-svg))
  (let ((svg (make-temp-file "cmie" nil ".svg"))
        (h (cmacs-imgedit-new 32 32)))
    (unwind-protect
        (progn
          (with-temp-file svg
            (insert "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\""
                    " height=\"32\"><rect x=\"4\" y=\"4\" width=\"24\""
                    " height=\"24\" fill=\"rgb(0,200,0)\"/></svg>"))
          (cmacs-imgedit-import-svg h svg 96)
          (let ((p (cmacs-imgedit-pixel-at h 16 16)))
            (should (> (nth 1 p) 150))    ; green channel high
            (should (< (nth 0 p) 60))))   ; red low
      (cmacs-imgedit-free h)
      (delete-file svg))))

(ert-deftest cmacs-imgedit-tests-gif-export ()
  "Export layers as an animated GIF; visibility is restored afterward."
  (skip-unless (fboundp 'cmacs-imgedit-export-gif))
  (let ((gif (make-temp-file "cmie" nil ".gif"))
        (h (cmacs-imgedit-new 16 16)))
    (unwind-protect
        (progn
          (cmacs-imgedit-fill h 255 0 0 255)
          (cmacs-imgedit-add-layer h "f2") (cmacs-imgedit-fill h 0 255 0 255)
          (cmacs-imgedit-export-gif h gif 20)
          (should (> (file-attribute-size (file-attributes gif)) 0))
          ;; both layers visible again (top green shows)
          (should (equal (cmacs-imgedit-pixel-at h 8 8) '(0 255 0 255))))
      (cmacs-imgedit-free h)
      (delete-file gif))))

(provide 'cmacs-imgedit-tests)
;;; cmacs-imgedit-tests.el ends here
