;;; cmacs-spacemouse.el --- SpaceMouse / 6DOF input for cmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A 3Dconnexion SpaceMouse (or any device spacenavd drives) as a
;; camera for cmacs's 3D views.  spacenavd owns the device; the C half
;; (cmacs/spacemouse/) reads its reports through the GLib loop and moves
;; the camera itself, at the device's rate -- motion never reaches Lisp.
;; What Lisp decides is which camera, and how it responds:
;;
;;   `cmacs-spacemouse-target'    auto, none, or a buffer
;;   `cmacs-spacemouse-sensitivity', `-translation-scale',
;;   `-rotation-scale', `-deadzone', `-invert', `-dominant-axis'
;;
;; With `auto' the cap flies the VR viewer while `emacs --lrg=3dvr' runs,
;; else orbits/pans/zooms the libregnum scene in the selected window
;; (roamgraph, the second brain, gnuseye's globe, the CAD viewer), else
;; the 3D lrg frame's camera.
;;
;; Buttons are events: <spacemouse-1>, <spacemouse-2>, ... (and
;; <spacemouse-N-release> with `cmacs-spacemouse-send-releases'), bound
;; in `cmacs-spacemouse-mode-map':
;;
;;   (keymap-set cmacs-spacemouse-mode-map "<spacemouse-2>" #'other-window)
;;
;; Turn it on with `cmacs-spacemouse-mode'.  Without spacenavd running it
;; does nothing, and keeps trying quietly, so a device plugged in later
;; (or a daemon started later) just starts working.  Fedora: install
;; spacenavd and `systemctl enable --now spacenavd'.

;;; Code:

(declare-function cmacs-spacemouse-start "cmacs-spacemouse-defuns.c"
                  (&optional socket no-retry))
(declare-function cmacs-spacemouse-stop "cmacs-spacemouse-defuns.c")
(declare-function cmacs-spacemouse-status "cmacs-spacemouse-defuns.c")
(declare-function cmacs-spacemouse-set-target "cmacs-spacemouse-defuns.c"
                  (target))
(declare-function cmacs-spacemouse-set-option "cmacs-spacemouse-defuns.c"
                  (key value))
(declare-function cmacs-spacemouse-key-code "cmacs-spacemouse-defuns.c"
                  (button &optional release))
(declare-function cmacs-lrg-vr-active-p "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-reset-view "cmacs-lrg-vr")
(declare-function cmacs-lrg-3d-camera "cmacs-lrgterm.c")

(defgroup cmacs-spacemouse nil
  "SpaceMouse / 6DOF input (spacenavd) for cmacs's 3D views."
  :group 'cmacs
  :prefix "cmacs-spacemouse-")

(defun cmacs-spacemouse-available-p ()
  "Return non-nil when this build has SpaceMouse support."
  (fboundp 'cmacs-spacemouse-start))

(defun cmacs-spacemouse--set (key)
  "Return a :set function that also pushes the value to C option KEY."
  (lambda (sym value)
    (set-default-toplevel-value sym value)
    (when (fboundp 'cmacs-spacemouse-set-option)
      (cmacs-spacemouse-set-option key value))))

(defcustom cmacs-spacemouse-socket nil
  "spacenavd's socket, or nil for the default.
The default is libspnav's choice where cmacs was built with libspnav,
else $SPNAV_SOCKET, /run/spnav.sock or /var/run/spnav.sock."
  :type '(choice (const :tag "Default" nil) file))

(defcustom cmacs-spacemouse-sensitivity 1.0
  "Overall SpaceMouse speed multiplier."
  :type 'number
  :set (cmacs-spacemouse--set 'sensitivity))

(defcustom cmacs-spacemouse-translation-scale 1.0
  "Extra multiplier for panning and zooming (the cap pushed and pulled)."
  :type 'number
  :set (cmacs-spacemouse--set 'translation-scale))

(defcustom cmacs-spacemouse-rotation-scale 1.0
  "Extra multiplier for orbiting and turning (the cap tilted and twisted)."
  :type 'number
  :set (cmacs-spacemouse--set 'rotation-scale))

(defcustom cmacs-spacemouse-deadzone 0.06
  "Fraction of full deflection ignored around rest (0 .. 0.95).
Caps drift a few units when let go; this keeps a resting cap still."
  :type 'number
  :set (cmacs-spacemouse--set 'deadzone))

(defcustom cmacs-spacemouse-full-scale 350
  "Raw reading that counts as full deflection.
About 350 for current SpaceMouse models, 512 for some older ones."
  :type 'number
  :set (cmacs-spacemouse--set 'full-scale))

(defcustom cmacs-spacemouse-invert nil
  "Axes to invert, from tx ty tz (push right, up, toward you) and rx ry rz
\(tilt, twist, roll)."
  :type '(set (const tx) (const ty) (const tz)
              (const rx) (const ry) (const rz))
  :set (cmacs-spacemouse--set 'invert))

(defcustom cmacs-spacemouse-dominant-axis nil
  "Non-nil: only the most-deflected axis acts at a time.
Makes a pure pan, zoom or orbit easy to hold."
  :type 'boolean
  :set (cmacs-spacemouse--set 'dominant))

(defcustom cmacs-spacemouse-send-releases nil
  "Non-nil: button releases arrive as <spacemouse-N-release> events too."
  :type 'boolean
  :set (cmacs-spacemouse--set 'releases))

(defcustom cmacs-spacemouse-target 'auto
  "What SpaceMouse motion moves.
`auto' is the VR viewer during `emacs --lrg=3dvr', else the libregnum
scene in the selected window, else the 3D lrg frame's camera.  `none'
disconnects motion from everything (buttons still work).  See also
`cmacs-spacemouse-target-this-buffer'."
  :type '(choice (const auto) (const none))
  :set (lambda (sym value)
         (set-default-toplevel-value sym value)
         (when (fboundp 'cmacs-spacemouse-set-target)
           (cmacs-spacemouse-set-target value))))

(defcustom cmacs-spacemouse-buttons 32
  "How many buttons get <spacemouse-N> names (the largest models have 31)."
  :type 'integer)

(defun cmacs-spacemouse--event (n &optional release)
  "The event symbol for button N (counting from 1), or its RELEASE."
  (intern (format "spacemouse-%d%s" n (if release "-release" ""))))

(defun cmacs-spacemouse--install-translations ()
  "Name the buttons' keystrokes: `key-CODE' becomes <spacemouse-N>.
The C side sends each button as a keystroke whose code matches no
keysym, which Emacs names `key-CODE'; see `cmacs-spacemouse-key-code'."
  (dotimes (i cmacs-spacemouse-buttons)
    (dolist (release '(nil t))
      (define-key function-key-map
                  (vector (intern (format "key-%d"
                                          (cmacs-spacemouse-key-code i release))))
                  (vector (cmacs-spacemouse--event (1+ i) release))))))

(defun cmacs-spacemouse--apply-options ()
  "Push the customization variables into the C side."
  (when (fboundp 'cmacs-spacemouse-set-option)
    (cmacs-spacemouse-set-option 'sensitivity cmacs-spacemouse-sensitivity)
    (cmacs-spacemouse-set-option 'translation-scale
                                 cmacs-spacemouse-translation-scale)
    (cmacs-spacemouse-set-option 'rotation-scale cmacs-spacemouse-rotation-scale)
    (cmacs-spacemouse-set-option 'deadzone cmacs-spacemouse-deadzone)
    (cmacs-spacemouse-set-option 'full-scale cmacs-spacemouse-full-scale)
    (cmacs-spacemouse-set-option 'invert cmacs-spacemouse-invert)
    (cmacs-spacemouse-set-option 'dominant cmacs-spacemouse-dominant-axis)
    (cmacs-spacemouse-set-option 'releases cmacs-spacemouse-send-releases)
    (cmacs-spacemouse-set-target cmacs-spacemouse-target)))

;;;###autoload
(defun cmacs-spacemouse-target-this-buffer ()
  "Make the SpaceMouse move this buffer's scene, wherever focus goes.
\\[cmacs-spacemouse-target-auto] returns to following the selected window."
  (interactive)
  (unless (cmacs-spacemouse-available-p)
    (user-error "This build has no SpaceMouse support"))
  (cmacs-spacemouse-set-target (current-buffer))
  (message "SpaceMouse moves %s" (buffer-name)))

;;;###autoload
(defun cmacs-spacemouse-target-auto ()
  "Make the SpaceMouse follow the selected window again (`auto')."
  (interactive)
  (unless (cmacs-spacemouse-available-p)
    (user-error "This build has no SpaceMouse support"))
  (cmacs-spacemouse-set-target 'auto)
  (message "SpaceMouse follows the selected window"))

;;;###autoload
(defun cmacs-spacemouse-describe ()
  "Say whether the SpaceMouse is connected, and what it moves."
  (interactive)
  (if (not (cmacs-spacemouse-available-p))
      (message "This build has no SpaceMouse support")
    (let ((st (cmacs-spacemouse-status)))
      (message "SpaceMouse: %s%s; %d motion, %d button reports; target %s%s"
               (cond ((plist-get st :connected)
                      (format "connected (%s)" (plist-get st :backend)))
                     ((plist-get st :enabled)
                      "waiting for spacenavd")
                     (t "off"))
               (if (plist-get st :socket)
                   (format " at %s" (plist-get st :socket))
                 "")
               (plist-get st :motion-events)
               (plist-get st :button-events)
               (let ((tg (plist-get st :target)))
                 (if (bufferp tg) (buffer-name tg) tg))
               (if (plist-get st :last-target)
                   (format ", last moved %s" (plist-get st :last-target))
                 "")))))

;;;###autoload
(defun cmacs-spacemouse-reset-view ()
  "Reset the camera the SpaceMouse moves (the 3D lrg frame's, or VR's)."
  (interactive)
  (cond ((and (fboundp 'cmacs-lrg-vr-active-p) (cmacs-lrg-vr-active-p)
              (fboundp 'cmacs-lrg-vr-reset-view))
         (cmacs-lrg-vr-reset-view))
        ((fboundp 'cmacs-lrg-3d-camera)
         (ignore-errors (cmacs-lrg-3d-camera "reset")))))

(defvar-keymap cmacs-spacemouse-mode-map
  :doc "Keymap for `cmacs-spacemouse-mode': the SpaceMouse's buttons.
Two-button models have <spacemouse-1> (left) and <spacemouse-2>
(right); larger ones number on from there, in spacenavd's order."
  "<spacemouse-1>" #'cmacs-spacemouse-reset-view
  "<spacemouse-2>" #'cmacs-spacemouse-describe)

;;;###autoload
(define-minor-mode cmacs-spacemouse-mode
  "Use a SpaceMouse (through spacenavd) as the camera for 3D views.
Motion moves the target camera (`cmacs-spacemouse-target'); buttons are
<spacemouse-N> events in `cmacs-spacemouse-mode-map'.  Without spacenavd
running this does nothing visible, and connects when the daemon appears."
  :global t
  :keymap cmacs-spacemouse-mode-map
  :group 'cmacs-spacemouse
  (cond ((not (cmacs-spacemouse-available-p))
         (when cmacs-spacemouse-mode
           (setq cmacs-spacemouse-mode nil)
           (message "This build has no SpaceMouse support")))
        (cmacs-spacemouse-mode
         (cmacs-spacemouse--install-translations)
         (cmacs-spacemouse--apply-options)
         (cmacs-spacemouse-start cmacs-spacemouse-socket))
        (t
         (cmacs-spacemouse-stop))))

(provide 'cmacs-spacemouse)

;;; cmacs-spacemouse.el ends here
