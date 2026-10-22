;;; cmacs-vidstudio-menu-tests.el --- vidstudio right-click menu tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Tests for the context-built right-click menu of the video editor.
;; Menus are built for synthetic click contexts -- a clip, a track row,
;; an audio segment, empty space -- over a REAL headless project (solid
;; and text clips need no decoder and no display), their items and
;; enabled state are asserted, and items are run to prove the timeline
;; changed.  The --lrg path is covered by standing in for
;; `lrg-popup-menu'.
;;
;; Gated on the primitives (`cmacs-vidstudio-new'), never on a feature
;; name.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-media-menu)
(require 'cmacs-vidstudio nil t)

;;;; Helpers ------------------------------------------------------------

(defmacro cmacs-vidstudio-menu-tests--skip-unless ()
  "Skip unless the vidstudio primitives are compiled in."
  '(skip-unless (and (fboundp 'cmacs-vidstudio-new)
                     (fboundp 'cmacs-vidstudio-context-menu-keymap))))

(defmacro cmacs-vidstudio-menu-tests--with-project (h &rest body)
  "Run BODY in a vidstudio buffer over a fresh 64x48@10fps project H.
The project starts with clips A (20 frames, red) and B (10 frames,
green) on track 0, bound to `a' and `b'.  Items run synchronously and
never ask for confirmation."
  (declare (indent 1))
  `(let* ((,h (cmacs-vidstudio-new 64 48 10.0))
          (buf (generate-new-buffer " *vidstudio-menu-test*"))
          (cmacs-media-menu--defer nil)
          (cmacs-media-menu-use-context-menu-mode nil)
          (cmacs-vidstudio-confirm-destructive nil)
          (cmacs-vidstudio--clip-clipboard nil)
          (a (cmacs-vidstudio-add-solid-clip ,h 0 20 255 0 0 255))
          (b (cmacs-vidstudio-add-solid-clip ,h 0 10 0 255 0 255)))
     (ignore a b)
     (unwind-protect
         (with-current-buffer buf
           (cmacs-vidstudio-mode)
           (setq cmacs-vidstudio--handle ,h)
           ,@body)
       (with-current-buffer buf (setq cmacs-vidstudio--handle nil))
       (kill-buffer buf)
       (ignore-errors (cmacs-vidstudio-free ,h)))))

(defun cmacs-vidstudio-menu-tests--menu (&rest props)
  "The menu keymap for a context built from PROPS in this buffer."
  (cmacs-vidstudio-context-menu-keymap
   (apply #'cmacs-vidstudio-menu-context props)))

(defun cmacs-vidstudio-menu-tests--enabled (map &rest path)
  "Enabled state of the entry at PATH in MAP; fail if it is missing."
  (let ((e (apply #'cmacs-media-menu-lookup map path)))
    (should e)
    (plist-get e :enabled)))

(defun cmacs-vidstudio-menu-tests--run (map &rest path)
  "Run the leaf at PATH in MAP (it must exist and be enabled)."
  (let ((e (apply #'cmacs-media-menu-lookup map path)))
    (should e)
    (should (plist-get e :enabled))
    (funcall (plist-get e :binding))))

(defun cmacs-vidstudio-menu-tests--clips (h track)
  "The clip ids on TRACK of H, in order."
  (mapcar (lambda (i) (cmacs-vidstudio-clip-at h track i))
          (number-sequence 0 (1- (cmacs-vidstudio-track-clip-count h track)))))

;;;; Menus for synthetic click contexts ---------------------------------

(ert-deftest cmacs-vidstudio-menu-test-clip-under-pointer ()
  "A clip context leads with that clip's items, enabled from the model:
cuts need the playhead inside the clip, reordering needs neighbours."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    ;; Playhead on A's first frame: no cut is possible there.
    (setq cmacs-vidstudio--playhead 0)
    (let ((map (cmacs-vidstudio-menu-tests--menu :clip a)))
      (should (equal (car (cmacs-media-menu-labels map))
                     (format "Clip #%d · solid · frames 0–20" a)))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Split at playhead"))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Trim in to playhead"))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Move earlier"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Move later"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Transition out" "Fade"))
      (should (cmacs-media-menu-lookup map "Transition in" "None (current)"))
      (should-not (cmacs-vidstudio-menu-tests--enabled
                   map "Keyframe" "Clear keyframes"))
      (should-not (cmacs-vidstudio-menu-tests--enabled
                   map "Effects" "Clear effects"))
      ;; Solid colour: no source slice, so no source-only entries.
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Extract audio"))
      (should-not (cmacs-vidstudio-menu-tests--enabled
                   map "Timing" "Source in/out…"))
      ;; The track section comes along with the clip's track.
      (should (cmacs-media-menu-lookup map "Track 0 (active) · 2 clip(s)"))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Paste clip here")))
    ;; Inside A, and on the last clip: cuts on, no outgoing transition.
    (setq cmacs-vidstudio--playhead 5)
    (let ((map (cmacs-vidstudio-menu-tests--menu :clip a)))
      (should (cmacs-vidstudio-menu-tests--enabled map "Split at playhead"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Trim out to playhead")))
    (let ((map (cmacs-vidstudio-menu-tests--menu :clip b)))
      (should (cmacs-vidstudio-menu-tests--enabled map "Move earlier"))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Move later"))
      (should-not (cmacs-media-menu-lookup map "Transition out")))
    ;; Keyframes and effects light up their "clear" entries.
    (cmacs-vidstudio-add-keyframe h a 0 0 0.5)
    (cmacs-vidstudio-add-effect h a 0)
    (let ((map (cmacs-vidstudio-menu-tests--menu :clip a)))
      (should (cmacs-vidstudio-menu-tests--enabled map "Keyframe" "Clear keyframes"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Effects" "Clear effects")))))

(ert-deftest cmacs-vidstudio-menu-test-track-and-empty-space ()
  "A track row gets track items; empty space gets project items, with
transport and export enabled from the real timeline."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (let ((empty (cmacs-vidstudio-add-track h)))
      (let ((map (cmacs-vidstudio-menu-tests--menu :track empty)))
        (should (equal (car (cmacs-media-menu-labels map))
                       (format "Track %d · 0 clip(s)" empty)))
        (should (cmacs-vidstudio-menu-tests--enabled map "Make active track"))
        (should-not (cmacs-vidstudio-menu-tests--enabled map "Clear track…"))
        (should (cmacs-media-menu-lookup map "Add to this track" "Title…"))
        ;; No clip: no clip section.
        (should-not (cl-some (lambda (l) (string-prefix-p "Clip #" l))
                             (cmacs-media-menu-labels map)))))
    (setq cmacs-vidstudio--playhead 0)
    (let ((map (cmacs-vidstudio-menu-tests--menu)))
      (should (equal (car (cmacs-media-menu-labels map)) "Add"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Transport" "Play"))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Transport" "Step back"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Transport" "Step forward"))
      (should (cmacs-vidstudio-menu-tests--enabled map "Export"))
      (should-not (cmacs-vidstudio-menu-tests--enabled map "Paste clip")))))

(ert-deftest cmacs-vidstudio-menu-test-empty-project ()
  "On an empty timeline nothing that needs frames is offered as live."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (let ((h (cmacs-vidstudio-new 32 32 10.0))
        (buf (generate-new-buffer " *vidstudio-menu-empty*")))
    (unwind-protect
        (with-current-buffer buf
          (cmacs-vidstudio-mode)
          (setq cmacs-vidstudio--handle h)
          (let ((map (cmacs-vidstudio-menu-tests--menu)))
            (should-not (cmacs-vidstudio-menu-tests--enabled map "Export"))
            (should-not (cmacs-vidstudio-menu-tests--enabled
                         map "Transport" "Play"))
            (should-not (cmacs-vidstudio-menu-tests--enabled
                         map "Render frame" "Export this frame as an image…"))
            (should (cmacs-vidstudio-menu-tests--enabled map "Add" "Title…"))))
      (with-current-buffer buf (setq cmacs-vidstudio--handle nil))
      (kill-buffer buf)
      (cmacs-vidstudio-free h))))

(ert-deftest cmacs-vidstudio-menu-test-hook-adds-items ()
  "`cmacs-vidstudio-context-menu-functions' is the extension point."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (let ((cmacs-vidstudio-context-menu-functions
           (copy-sequence cmacs-vidstudio-context-menu-functions))
          (seen nil))
      (add-hook 'cmacs-vidstudio-context-menu-functions
                (lambda (ctx)
                  (when (plist-get ctx :clip)
                    `((:in effects :label "Add glitch"
                       :action ,(lambda (c) (setq seen (plist-get c :clip)))))))
                95)
      (let ((map (cmacs-vidstudio-menu-tests--menu :clip b)))
        (cmacs-vidstudio-menu-tests--run map "Effects" "Add glitch")
        (should (eql seen b)))
      (should-not (cmacs-media-menu-lookup (cmacs-vidstudio-menu-tests--menu)
                                           "Add glitch")))))

(ert-deftest cmacs-vidstudio-menu-test-ai-registers-through-the-hook ()
  "The AI entries arrive through the hook, gated on `cmacs-ai-supported-p'."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (skip-unless (locate-library "cmacs-vidstudio-ai"))
  (require 'cmacs-vidstudio-ai)
  (should (memq 'cmacs-vidstudio-ai-context-menu-items
                cmacs-vidstudio-context-menu-functions))
  (cmacs-vidstudio-menu-tests--with-project h
    (cl-letf (((symbol-function 'cmacs-ai-supported-p) (lambda () t)))
      (let ((map (cmacs-vidstudio-menu-tests--menu)))
        (should (cmacs-media-menu-lookup map "AI" "Captions from a transcript…"))
        (should (cmacs-media-menu-lookup map "AI" "Build a highlight reel…"))))
    (cl-letf (((symbol-function 'cmacs-ai-supported-p) (lambda () nil)))
      (should-not (member "AI" (cmacs-media-menu-labels
                                (cmacs-vidstudio-menu-tests--menu)))))))

(ert-deftest cmacs-vidstudio-menu-test-lrg-path ()
  "Under --lrg the in-engine popup gets the very same menu, and the
leaf it returns runs against the clicked clip."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (setq cmacs-vidstudio--playhead 5)
    (let* ((ctx (cmacs-vidstudio-menu-context :clip a :source 'viewport))
           (want (car (cmacs-menu-keymap-to-tree
                       (cmacs-vidstudio-context-menu-keymap ctx))))
           (got nil))
      (cl-letf (((symbol-function 'framep) (lambda (&rest _) 'lrg))
                ((symbol-function 'lrg-popup-menu)
                 (lambda (tree &rest _)
                   (setq got tree)
                   (cdr (assoc "Split at playhead" tree)))))
        (cmacs-media-menu-show ctx #'cmacs-vidstudio-context-menu-keymap
                               (list '(10 10) (selected-frame))))
      (should (equal got want))
      (should (= (cmacs-vidstudio-track-clip-count h 0) 3))
      (should (= (cmacs-vidstudio-clip-duration h a) 5)))))

(ert-deftest cmacs-vidstudio-menu-test-bindings-and-click-context ()
  "mouse-3 on the timeline beats emulation maps, and a click on a clip
cell or a track row resolves to that clip or that track."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (set-window-buffer (selected-window) (current-buffer))
    (cmacs-vidstudio--render)
    (let* ((shadow (make-sparse-keymap))
           (emulation-mode-map-alists
            (cons (list (cons t shadow)) emulation-mode-map-alists)))
      (define-key shadow [down-mouse-3] #'ignore)
      (should (eq (key-binding [down-mouse-3] nil nil (point-min))
                  'cmacs-vidstudio-context-menu)))
    (should (eq (lookup-key cmacs-vidstudio-mode-map [menu])
                'cmacs-vidstudio-context-menu-at-point))
    (let* ((win (selected-window))
           (ev (lambda (pos)
                 (list 'down-mouse-3
                       (list win pos (cons 0 0) 0 nil pos (cons 0 0) nil
                             (cons 0 0) (cons 1 1)))))
           (cell (text-property-any (point-min) (point-max)
                                    'cmacs-vidstudio-clip b))
           (row (text-property-any (point-min) (point-max)
                                   'cmacs-vidstudio-track 0)))
      (should cell)
      (let ((ctx (cmacs-vidstudio--click-context (funcall ev cell))))
        (should (eql (plist-get ctx :clip) b))
        (should (eql (plist-get ctx :track) 0))
        (should (eq (plist-get ctx :area) 'clip)))
      (let ((ctx (cmacs-vidstudio--click-context (funcall ev row))))
        (should-not (plist-get ctx :clip))
        (should (eql (plist-get ctx :track) 0))
        (should (eq (plist-get ctx :area) 'track)))
      (let ((ctx (cmacs-vidstudio--click-context (funcall ev (point-min)))))
        (should (eq (plist-get ctx :area) 'preview))))))

;;;; Items run against the real model ------------------------------------

(ert-deftest cmacs-vidstudio-menu-test-cut-items ()
  "Split, trim in/out, ripple delete and gap delete edit the timeline."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (setq cmacs-vidstudio--playhead 5)
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip a)
                                     "Trim out to playhead")
    (should (= (cmacs-vidstudio-clip-duration h a) 5))
    (should (= (cmacs-vidstudio-total-frames h) 15))
    (setq cmacs-vidstudio--playhead 7)                ; 2 frames into B
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip b)
                                     "Trim in to playhead")
    (should (= (cmacs-vidstudio-clip-duration h b) 8))
    (should (= cmacs-vidstudio--playhead 5))         ; parked on B's start
    ;; A gap delete keeps the timeline length; a ripple delete closes it.
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip a)
                                     "Delete (leave gap)")
    (should (= (cmacs-vidstudio-total-frames h) 13))
    (should (equal (cadr (assq 'color (cdr (cmacs-vidstudio--clip-sexp a))))
                   0))
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip a)
                                     "Ripple delete")
    (should (= (cmacs-vidstudio-total-frames h) 8))
    (should (equal (cmacs-vidstudio-menu-tests--clips h 0) (list b)))))

(ert-deftest cmacs-vidstudio-menu-test-arrange-items ()
  "Move to a new track, reorder, transition in/out and add an effect."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip b)
                                     "Move earlier")
    (should (equal (cmacs-vidstudio-menu-tests--clips h 0) (list b a)))
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip b)
                                     "Transition out" "Dissolve")
    (should (equal (assq 'transition (cdr (cmacs-vidstudio--clip-sexp a)))
                   (list 'transition 1
                         (cmacs-vidstudio--secs-to-frames
                          cmacs-vidstudio-menu-transition-seconds)
                         0)))
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip a)
                                     "Effects" "Add vignette")
    (should (equal (car (cadr (assq 'effects (cdr (cmacs-vidstudio--clip-sexp a)))))
                   3))
    ;; A keyframed clip survives a move between tracks (the C fix: the
    ;; move used to free its keyframes, crashing the next serialize).
    (cmacs-vidstudio-add-keyframe h a 0 0 0.25)
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip a)
                                     "Move to track" "New track")
    (should (= (cmacs-vidstudio-n-tracks h) 2))
    (should (equal (cmacs-vidstudio-menu-tests--clips h 1) (list a)))
    (should (assq 'keyframes (cdr (cmacs-vidstudio--clip-sexp a))))))

(ert-deftest cmacs-vidstudio-menu-test-clipboard-and-track-items ()
  "Copy/paste/duplicate clips, make a track active, clear a track."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip a)
                                     "Duplicate clip")
    (let ((ids (cmacs-vidstudio-menu-tests--clips h 0)))
      (should (= (length ids) 3))
      (should (eql (nth 0 ids) a))
      (should (eql (nth 2 ids) b))
      (should (= (cmacs-vidstudio-clip-duration h (nth 1 ids)) 20)))
    (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :clip b)
                                     "Copy clip")
    (let ((tr (cmacs-vidstudio-add-track h)))
      (let ((map (cmacs-vidstudio-menu-tests--menu :track tr)))
        (cmacs-vidstudio-menu-tests--run map "Paste clip here"))
      (should (= (cmacs-vidstudio-track-clip-count h tr) 1))
      (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :track tr)
                                       "Make active track")
      (should (= cmacs-vidstudio--active-track tr))
      (cmacs-vidstudio-menu-tests--run (cmacs-vidstudio-menu-tests--menu :track 0)
                                       "Clear track…")
      (should (= (cmacs-vidstudio-track-clip-count h 0) 0)))))

(ert-deftest cmacs-vidstudio-menu-test-track-scoped-add ()
  "\"Add to this track\" lands on the track that was clicked."
  (cmacs-vidstudio-menu-tests--skip-unless)
  (cmacs-vidstudio-menu-tests--with-project h
    (let ((tr (cmacs-vidstudio-add-track h)))
      (setq cmacs-vidstudio--active-track 0)
      (cl-letf (((symbol-function 'read-color) (lambda (&rest _) "#0000ff"))
                ((symbol-function 'read-number) (lambda (&rest _) 1.0)))
        (cmacs-vidstudio-menu-tests--run
         (cmacs-vidstudio-menu-tests--menu :track tr)
         "Add to this track" "Solid colour…"))
      (should (= (cmacs-vidstudio-track-clip-count h tr) 1))
      (should (= (cmacs-vidstudio-track-clip-count h 0) 2)))))

(provide 'cmacs-vidstudio-menu-tests)

;;; cmacs-vidstudio-menu-tests.el ends here
