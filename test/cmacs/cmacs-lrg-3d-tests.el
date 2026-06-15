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
  ;; The interaction keys are bound under C-c 3.
  (should (eq (lookup-key cmacs-lrg-3d-mode-map (kbd "C-c 3 f"))
              #'cmacs-lrg-focus-window))
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

(provide 'cmacs-lrg-3d-tests)

;;; cmacs-lrg-3d-tests.el ends here
