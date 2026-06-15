;;; cmacs-lrg-3d-tests.el --- Tests for the lrg 3D backend control layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `emacs --lrg=3d' control.  The presence / vocabulary / minor-mode
;; / off-3D-frame tests run anywhere (including -batch).  Tests that need a live
;; 3D lrg frame are skip-guarded with `cmacs-lrg-3d--live-p' (so check-cmacs stays
;; green under -batch and pgtk).

;;; Code:

(require 'ert)
(require 'cmacs-lrg-3d nil t)

(defun cmacs-lrg-3d--live-p ()
  "Non-nil when running on a live 3D lrg frame."
  (and (fboundp 'cmacs-lrg-3d-supported-p)
       (cmacs-lrg-3d-supported-p)))

;; --------------------------------------------------------------- presence ---

(ert-deftest cmacs-lrg-3d-tests-elisp-loaded ()
  "The control layer loads and provides its commands."
  (should (featurep 'cmacs-lrg-3d))
  (should (fboundp 'cmacs-lrg-set-arrangement))
  (should (fboundp 'cmacs-lrg-set-environment))
  (should (fboundp 'cmacs-lrg-3d-describe))
  (should (fboundp 'cmacs-lrg-camera-reset))
  (should (fboundp 'cmacs-lrg-camera-orbit-left))
  ;; Spatial interaction commands.
  (should (fboundp 'cmacs-lrg-focus-window))
  (should (fboundp 'cmacs-lrg-pin-window))
  (should (fboundp 'cmacs-lrg-unpin-window))
  (should (fboundp 'cmacs-lrg-unpin-all))
  (should (keymapp cmacs-lrg-3d-mode-map))
  (should (fboundp 'cmacs-lrg-maximize-window))
  ;; The interaction keys are bound under C-c 3.
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 f"))
              #'cmacs-lrg-focus-window))
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 2"))
              #'cmacs-lrg-maximize-window))
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 p"))
              #'cmacs-lrg-pin-window))
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 U"))
              #'cmacs-lrg-unpin-all)))

(ert-deftest cmacs-lrg-3d-tests-defuns-present ()
  "The C DEFUNs the control layer dispatches to are built in."
  (should (fboundp 'cmacs-lrg-3d-supported-p))
  (should (fboundp 'cmacs-lrg-render-mode))
  (should (fboundp 'cmacs-lrg-3d-set-arrangement))
  (should (fboundp 'cmacs-lrg-3d-set-environment))
  (should (fboundp 'cmacs-lrg-3d-arrangement))
  (should (fboundp 'cmacs-lrg-3d-environment))
  (should (fboundp 'cmacs-lrg-3d-focus-window))
  (should (fboundp 'cmacs-lrg-3d-camera))
  ;; Spatial intent DEFUNs (mouse / voice / AI all route through these).
  (should (fboundp 'cmacs-lrg-3d-pick-panel))
  (should (fboundp 'cmacs-lrg-3d-focus-panel))
  (should (fboundp 'cmacs-lrg-3d-maximize-window))
  (should (fboundp 'cmacs-lrg-3d-orbit))
  (should (fboundp 'cmacs-lrg-3d-dolly))
  (should (fboundp 'cmacs-lrg-3d-move-panel))
  (should (fboundp 'cmacs-lrg-3d-pin-panel))
  (should (fboundp 'cmacs-lrg-3d-unpin-panel)))

(ert-deftest cmacs-lrg-3d-tests-vocabulary ()
  "The built-in arrangement / environment ids are present."
  (should (member "single-panel" cmacs-lrg-3d-arrangements))
  (should (member "per-window" cmacs-lrg-3d-arrangements))
  (should (member "free" cmacs-lrg-3d-arrangements))
  (should (member "void" cmacs-lrg-3d-environments))
  (should (member "workshop" cmacs-lrg-3d-environments))
  (should (member "cockpit" cmacs-lrg-3d-environments)))

;; --------------------------------------------------------------- minor mode -

(ert-deftest cmacs-lrg-3d-tests-minor-mode-hook ()
  "Enabling the mode installs the focus-follow hook; disabling removes it."
  (let ((was cmacs-lrg-3d-mode))
    (unwind-protect
        (progn
          (cmacs-lrg-3d-mode 1)
          (should (memq #'cmacs-lrg-3d--track-selected-window
                        window-selection-change-functions))
          (cmacs-lrg-3d-mode -1)
          (should-not (memq #'cmacs-lrg-3d--track-selected-window
                            window-selection-change-functions)))
      (cmacs-lrg-3d-mode (if was 1 -1)))))

;; ------------------------------------------------- off a non-3D frame --------

(ert-deftest cmacs-lrg-3d-tests-off-3d-frame ()
  "The DEFUNs degrade gracefully when the frame is not a 3D lrg frame."
  (skip-unless (not (cmacs-lrg-3d--live-p)))
  (should-not (cmacs-lrg-3d-supported-p))
  ;; render-mode is nil off any lrg frame; arrangement/environment nil off 3D.
  (should (null (cmacs-lrg-3d-arrangement)))
  (should (null (cmacs-lrg-3d-environment)))
  ;; Setting an arrangement off a 3D frame returns nil, does not error.
  (should (null (cmacs-lrg-3d-set-arrangement "per-window")))
  (should (null (cmacs-lrg-3d-set-environment "cockpit")))
  (should (null (cmacs-lrg-3d-camera "reset")))
  ;; The spatial intents also no-op (return nil) off a 3D frame.
  (should (null (cmacs-lrg-3d-focus-panel)))
  (should (null (cmacs-lrg-3d-orbit 10 0)))
  (should (null (cmacs-lrg-3d-pin-panel)))
  (should (null (cmacs-lrg-3d-unpin-panel))))

;; ------------------------------------------------- live 3D frame (skip) ------

(ert-deftest cmacs-lrg-3d-tests-live-switching ()
  "On a live 3D frame, arrangement / environment round-trip."
  (skip-unless (cmacs-lrg-3d--live-p))
  (should (cmacs-lrg-3d-set-arrangement "per-window"))
  (should (equal (cmacs-lrg-3d-arrangement) "per-window"))
  (should (cmacs-lrg-3d-set-environment "cockpit"))
  (should (equal (cmacs-lrg-3d-environment) "cockpit"))
  (should (equal (cmacs-lrg-render-mode) "3d"))
  (should (cmacs-lrg-3d-set-arrangement "single-panel"))
  (should (equal (cmacs-lrg-3d-arrangement) "single-panel"))
  ;; Unknown ids are rejected.
  (should (null (cmacs-lrg-3d-set-arrangement "no-such-arrangement"))))

;; ----------------------------------------------- spatial workspaces ---------

(require 'cmacs-lrg-3d-workspaces nil t)

(ert-deftest cmacs-lrg-3d-tests-workspaces-loaded ()
  "The spatial workspace switcher loads with its commands + C primitives."
  (should (featurep 'cmacs-lrg-3d-workspaces))
  (should (fboundp 'cmacs-lrg-3d-workspaces-mode))
  (should (fboundp 'cmacs-lrg-3d-workspaces-refresh))
  (should (fboundp 'cmacs-lrg-3d-workspaces-relayout))
  ;; The off-screen-render + workspace-panel C DEFUNs the layer dispatches to.
  (should (fboundp 'cmacs-lrg-3d-begin-offscreen))
  (should (fboundp 'cmacs-lrg-3d-end-offscreen))
  (should (fboundp 'cmacs-lrg-3d-render-into-panel))
  (should (fboundp 'cmacs-lrg-3d-place-workspace-panel))
  (should (fboundp 'cmacs-lrg-3d-rotate-workspace-panel))
  (should (fboundp 'cmacs-lrg-3d-remove-workspace-panel))
  (should (fboundp 'cmacs-lrg-3d-workspace-panel-geometry)))

(ert-deftest cmacs-lrg-3d-tests-workspaces-index-map ()
  "Workspace -> panel index is stable, distinct, and forgettable."
  (let ((cmacs-lrg-3d-workspaces--index-table (make-hash-table :test 'equal))
        (cmacs-lrg-3d-workspaces--index-counter 0))
    (let ((a (cmacs-lrg-3d-workspaces--index "alpha"))
          (b (cmacs-lrg-3d-workspaces--index "beta")))
      (should (integerp a))
      (should-not (= a b))
      ;; Stable: same workspace keeps its index.
      (should (= a (cmacs-lrg-3d-workspaces--index "alpha")))
      ;; Forget then re-request: a fresh (different) index is handed out.
      (cmacs-lrg-3d-workspaces--forget "alpha")
      (should-not (= a (cmacs-lrg-3d-workspaces--index "alpha"))))))

(ert-deftest cmacs-lrg-3d-tests-workspaces-arc-math ()
  "Arc slots: the centre is dead ahead; +/-N mirror across it and toe in."
  (let ((cmacs-lrg-3d-workspaces-radius 9.0)
        (cmacs-lrg-3d-workspaces-spacing 24.0)
        (cmacs-lrg-3d-workspaces-height 3.2)
        (cmacs-lrg-3d-workspaces-elevation 0.0))
    (pcase-let ((`(,px0 ,_py0 ,pz0 ,yaw0 ,w0 ,h0)
                 (cmacs-lrg-3d-workspaces--slot 0 1.6)))
      (should (< (abs px0) 0.001))
      (should (< (abs pz0) 0.001))
      (should (< (abs yaw0) 0.001))
      (should (< (abs (- w0 (* 3.2 1.6))) 0.001)) ; width = height * aspect
      (should (< (abs (- h0 3.2)) 0.001)))
    (pcase-let ((`(,pxr ,_pyr ,pzr ,yawr ,_wr ,_hr)
                 (cmacs-lrg-3d-workspaces--slot 1 1.6))
                (`(,pxl ,_pyl ,pzl ,yawl ,_wl ,_hl)
                 (cmacs-lrg-3d-workspaces--slot -1 1.6)))
      ;; Right slot: positive X, recedes (negative Z), toed IN toward the
      ;; viewer (yaw = -beta, so negative on the right).
      (should (> pxr 0.0))
      (should (< pzr 0.0))
      (should (< (abs (- yawr -24.0)) 0.001))
      ;; Left slot mirrors the right one across the centre.
      (should (< (abs (+ pxr pxl)) 0.001))
      (should (< (abs (- pzr pzl)) 0.001))
      (should (< (abs (+ yawr yawl)) 0.001)))))

(ert-deftest cmacs-lrg-3d-tests-workspaces-visibility ()
  "Visibility respects `cmacs-lrg-3d-workspaces-max'."
  (let ((cmacs-lrg-3d-workspaces-max 8))
    (should (cmacs-lrg-3d-workspaces--visible-p 0))
    (should (cmacs-lrg-3d-workspaces--visible-p 8))
    (should (cmacs-lrg-3d-workspaces--visible-p -8))
    (should-not (cmacs-lrg-3d-workspaces--visible-p 9))
    (should-not (cmacs-lrg-3d-workspaces--visible-p -9)))
  (let ((cmacs-lrg-3d-workspaces-max nil))
    (should (cmacs-lrg-3d-workspaces--visible-p 999))))

(ert-deftest cmacs-lrg-3d-tests-workspaces-off-frame ()
  "Workspace entry points no-op (do not error) off a 3D lrg frame."
  (skip-unless (not (cmacs-lrg-3d--live-p)))
  (should-not (cmacs-lrg-3d-workspaces--available-p))
  ;; refresh / relayout / a live-updater tick are safe to call and do nothing.
  (should-not (cmacs-lrg-3d-workspaces-refresh))
  (should-not (cmacs-lrg-3d-workspaces-relayout))
  (should-not (cmacs-lrg-3d-workspaces--tick)))

;; --------------------------------------------- live round-robin updater -----

(require 'cl-lib)

(ert-deftest cmacs-lrg-3d-tests-workspaces-updater-present ()
  "The live updater machinery and its knobs exist."
  (should (fboundp 'cmacs-lrg-3d-workspaces--tick))
  (should (fboundp 'cmacs-lrg-3d-workspaces--start-timer))
  (should (fboundp 'cmacs-lrg-3d-workspaces--stop-timer))
  (should (fboundp 'cmacs-lrg-3d-workspaces--signature))
  (should (boundp 'cmacs-lrg-3d-workspaces-live))
  (should (boundp 'cmacs-lrg-3d-workspaces-update-interval)))

(ert-deftest cmacs-lrg-3d-tests-workspaces-non-current ()
  "Non-current name selection excludes the current and honours visibility."
  (cl-letf (((symbol-function '+workspace-list-names)
             (lambda () '("a" "b" "c" "d")))
            ((symbol-function '+workspace-current-name)
             (lambda () "b")))
    (let ((cmacs-lrg-3d-workspaces-max nil))
      (should (equal (cmacs-lrg-3d-workspaces--non-current-names)
                     '("a" "c" "d"))))
    ;; current "b" at index 1: a=-1, c=+1, d=+2; max 1 drops d.
    (let ((cmacs-lrg-3d-workspaces-max 1))
      (should (equal (cmacs-lrg-3d-workspaces--non-current-names)
                     '("a" "c"))))))

(ert-deftest cmacs-lrg-3d-tests-workspaces-dirty ()
  "Signature is nil without a persp buffer list; force-dirty clears the map."
  (skip-unless (not (fboundp 'persp-buffers)))
  (should (null (cmacs-lrg-3d-workspaces--signature "anything")))
  (let ((cmacs-lrg-3d-workspaces--last-sig (make-hash-table :test 'equal)))
    (puthash "a" 7 cmacs-lrg-3d-workspaces--last-sig)
    (puthash "b" 9 cmacs-lrg-3d-workspaces--last-sig)
    (cmacs-lrg-3d-workspaces--force-dirty)
    (should (= 0 (hash-table-count cmacs-lrg-3d-workspaces--last-sig)))))

;; ------------------------------------ transitions / switch / persistence ----

(ert-deftest cmacs-lrg-3d-tests-workspaces-phase-e-present ()
  "The switch / transition / persistence surface exists."
  (should (fboundp 'cmacs-lrg-3d-workspaces-overview))
  (should (fboundp 'cmacs-lrg-3d-workspaces-toggle))
  (should (fboundp 'cmacs-lrg-3d-workspaces-rotate))
  ;; C primitives for click-to-switch + eased carousel transition.
  (should (fboundp 'cmacs-lrg-3d-take-pending-workspace))
  (should (fboundp 'cmacs-lrg-3d-place-workspace-panel-eased))
  ;; Bound under C-c 3.
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 SPC"))
              #'cmacs-lrg-3d-workspaces-toggle))
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 o"))
              #'cmacs-lrg-3d-workspaces-overview))
  ;; Auto-enable surface.
  (should (fboundp 'cmacs-lrg-3d-workspaces--maybe-auto-enable))
  (should (boundp 'cmacs-lrg-3d-workspaces-auto))
  (should (boundp 'cmacs-lrg-3d-workspaces-frame-zoom)))

(ert-deftest cmacs-lrg-3d-tests-workspaces-name-for-index ()
  "Index <-> name round-trips through the map."
  (let ((cmacs-lrg-3d-workspaces--index-table (make-hash-table :test 'equal))
        (cmacs-lrg-3d-workspaces--index-counter 0))
    (let ((ia (cmacs-lrg-3d-workspaces--index "alpha"))
          (ib (cmacs-lrg-3d-workspaces--index "beta")))
      (should (equal "alpha" (cmacs-lrg-3d-workspaces--name-for-index ia)))
      (should (equal "beta" (cmacs-lrg-3d-workspaces--name-for-index ib)))
      (should (null (cmacs-lrg-3d-workspaces--name-for-index 999))))))

(ert-deftest cmacs-lrg-3d-tests-workspaces-xform-moved ()
  "A manual move/rotate is detected; an identical transform is not."
  (let ((a '(1.0 0.0 -2.0 30.0 4.0 3.0)))
    (should-not (cmacs-lrg-3d-workspaces--xform-moved-p a (copy-sequence a)))
    ;; position change
    (should (cmacs-lrg-3d-workspaces--xform-moved-p '(2.0 0.0 -2.0 30.0 4.0 3.0) a))
    ;; yaw change
    (should (cmacs-lrg-3d-workspaces--xform-moved-p '(1.0 0.0 -2.0 45.0 4.0 3.0) a))
    ;; width/height-only change is NOT a move (tracks the frame aspect)
    (should-not
     (cmacs-lrg-3d-workspaces--xform-moved-p '(1.0 0.0 -2.0 30.0 9.0 9.0) a))))

(ert-deftest cmacs-lrg-3d-tests-workspaces-placement-saved ()
  "Placement prefers a saved persp transform over the computed arc slot."
  (cl-letf (((symbol-function '+workspace-get) (lambda (name &optional _) name))
            ((symbol-function 'persp-parameter)
             (lambda (param &optional persp)
               (when (and (eq param 'lrg-3d-xform) (equal persp "saved"))
                 '(5.0 1.0 -1.0 12.0 4.0 3.0)))))
    ;; A workspace with a saved xform gets exactly that.
    (should (equal (cmacs-lrg-3d-workspaces--placement "saved" 1 1.6)
                   '(5.0 1.0 -1.0 12.0 4.0 3.0)))
    ;; One without falls back to the computed slot (non-zero for rel 1).
    (let ((slot (cmacs-lrg-3d-workspaces--placement "fresh" 1 1.6)))
      (should (> (nth 0 slot) 0.0)))))

(provide 'cmacs-lrg-3d-tests)

;;; cmacs-lrg-3d-tests.el ends here
