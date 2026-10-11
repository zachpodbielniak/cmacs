;;; cmacs-lrg-vr.el --- Controls for Emacs in a VR headset (--lrg=3dvr) -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `emacs --lrg=3dvr' shows the lrg 3D scene in an OpenXR headset (SteamVR,
;; Monado).  The C side (cmacs/lrgterm/cmacs-lrgvr.c) renders it, turns each
;; controller's laser into ordinary mouse events -- trigger = mouse-1, right
;; stick = wheel, right stick press = mouse-3 -- and handles grabbing,
;; moving, turning and the in-world keyboard itself.
;;
;; The face buttons arrive as F25..F30, which this file translates to
;; descriptive events, so they are bound like any other key:
;;
;;   <vr-right-a>     A (right)         toggle the in-world keyboard
;;   <vr-right-b>     B (right)         escape / quit
;;   <vr-left-x>      X (left)          bring the pointed-at window front and centre
;;   <vr-left-y>      Y (left)          M-x
;;   <vr-menu>        menu (left)       recenter the scene ahead of you
;;   <vr-left-stick>  left stick press  reset the view
;;
;; Rebind them in `cmacs-lrg-vr-mode-map', or globally:
;;
;;   (keymap-global-set "<vr-left-y>" #'consult-buffer)

;;; Code:

(declare-function cmacs-lrg-vr-supported-p "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-active-p "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-recenter "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-scale "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-set-scale "cmacs-lrgvr.c" (metres))
(declare-function cmacs-lrg-vr-keyboard "cmacs-lrgvr.c" (&optional arg))
(declare-function cmacs-lrg-vr-set-option "cmacs-lrgvr.c" (key value))
(declare-function cmacs-lrg-vr-pointed-window "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-status "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-turn "cmacs-lrgvr.c" (degrees))
(declare-function cmacs-lrg-3d-focus-panel "cmacs-lrgterm.c")
(declare-function cmacs-lrg-3d-camera "cmacs-lrgterm.c")

(defgroup cmacs-lrg-vr nil
  "Emacs in a VR headset (`emacs --lrg=3dvr')."
  :group 'cmacs
  :prefix "cmacs-lrg-vr-")

(defun cmacs-lrg-vr--set (key)
  "Return a :set function that also pushes the value to the C option KEY."
  (lambda (sym value)
    (set-default-toplevel-value sym value)
    (when (fboundp 'cmacs-lrg-vr-set-option)
      (cmacs-lrg-vr-set-option key value))))

(defcustom cmacs-lrg-vr-snap-degrees 30
  "Degrees one flick of the moving hand's stick turns you."
  :type 'number
  :set (cmacs-lrg-vr--set 'snap-degrees))

(defcustom cmacs-lrg-vr-move-speed 1.5
  "Stick walking speed in metres per second, at full deflection."
  :type 'number
  :set (cmacs-lrg-vr--set 'move-speed))

(defcustom cmacs-lrg-vr-scroll-rate 10
  "Scroll (wheel) events per second with the stick fully deflected."
  :type 'number
  :set (cmacs-lrg-vr--set 'scroll-rate))

(defcustom cmacs-lrg-vr-haptics t
  "Non-nil to pulse the controller on clicks, key presses and grabs."
  :type 'boolean
  :set (cmacs-lrg-vr--set 'haptics))

(defcustom cmacs-lrg-vr-move-hand 'left
  "The hand whose stick walks and turns; the other hand's stick scrolls."
  :type '(choice (const left) (const right))
  :set (cmacs-lrg-vr--set 'move-hand))

(defcustom cmacs-lrg-vr-keyboard-tilt 50
  "Degrees the in-world keyboard leans away from you (0 = upright)."
  :type 'number
  :set (cmacs-lrg-vr--set 'keyboard-tilt))

(defcustom cmacs-lrg-vr-scale nil
  "World scale in metres per scene unit, or nil for the default (0.3).
Larger makes the whole workspace bigger and farther away."
  :type '(choice (const :tag "Default" nil) number))

(defcustom cmacs-lrg-vr-frame-size '(1400 . 1000)
  "Pixel size (WIDTH . HEIGHT) the frame takes when VR starts, or nil.
In VR the frame is drawn offscreen and shown on a panel of fixed angular
size (about 41 degrees tall at the default seat), so this is a
resolution: more pixels fit more text in, each line smaller.  1000 px
tall is about 0.7 degrees a line.  nil leaves the frame as created."
  :type '(choice (const :tag "Leave as created" nil)
                 (cons (integer :tag "Width") (integer :tag "Height"))))

(defcustom cmacs-lrg-vr-escape-key nil
  "What <vr-right-b> sends.
nil means <escape> when `evil-mode' is on and \\[keyboard-quit] otherwise;
a key description string (\"C-g\", \"<escape>\") forces one."
  :type '(choice (const :tag "Automatic" nil) string))

(defconst cmacs-lrg-vr--button-keys
  '(([f25] . [vr-right-a])
    ([f26] . [vr-right-b])
    ([f27] . [vr-left-x])
    ([f28] . [vr-left-y])
    ([f29] . [vr-menu])
    ([f30] . [vr-left-stick]))
  "The function keys the controller buttons arrive as, and their names.")

(defun cmacs-lrg-vr-active-now-p ()
  "Return non-nil while Emacs is showing in a headset."
  (and (fboundp 'cmacs-lrg-vr-active-p) (cmacs-lrg-vr-active-p)))

(defun cmacs-lrg-vr--require-active ()
  (unless (cmacs-lrg-vr-active-now-p)
    (user-error "Not in VR (start Emacs with --lrg=3dvr)")))

;;;###autoload
(defun cmacs-lrg-vr-recenter-view ()
  "Put the scene straight ahead of where you are looking now."
  (interactive)
  (cmacs-lrg-vr--require-active)
  (cmacs-lrg-vr-recenter))

;;;###autoload
(defun cmacs-lrg-vr-reset-view ()
  "Reset the 3D camera to its default seat, then recenter."
  (interactive)
  (cmacs-lrg-vr--require-active)
  (when (fboundp 'cmacs-lrg-3d-camera)
    (cmacs-lrg-3d-camera "reset"))
  (cmacs-lrg-vr-recenter))

;;;###autoload
(defun cmacs-lrg-vr-toggle-keyboard ()
  "Show or hide the in-world keyboard.
Point at a key and pull the trigger to type; Ctrl, Meta and Super stick
until the next key, Shift cycles once -> locked -> off.  Grab the keyboard
with the grip to move it."
  (interactive)
  (cmacs-lrg-vr--require-active)
  (cmacs-lrg-vr-keyboard))

;;;###autoload
(defun cmacs-lrg-vr-focus-pointed-window ()
  "Select the window under the laser and bring its panel front and centre."
  (interactive)
  (cmacs-lrg-vr--require-active)
  (let ((w (cmacs-lrg-vr-pointed-window)))
    (if (not (window-live-p w))
        (user-error "Point at a window first")
      (select-window w)
      (when (fboundp 'cmacs-lrg-3d-focus-panel)
        (ignore-errors (cmacs-lrg-3d-focus-panel w))))))

;;;###autoload
(defun cmacs-lrg-vr-escape ()
  "Escape: <escape> under Evil, `keyboard-quit' otherwise.
See `cmacs-lrg-vr-escape-key'."
  (interactive)
  (let ((key (cond (cmacs-lrg-vr-escape-key (key-parse cmacs-lrg-vr-escape-key))
                   ((bound-and-true-p evil-mode) [escape])
                   (t nil))))
    (if key
        (setq unread-command-events
              (append (listify-key-sequence key) unread-command-events))
      (keyboard-quit))))

;;;###autoload
(defun cmacs-lrg-vr-bigger (&optional n)
  "Make the VR workspace bigger (and farther) by 15%, N times."
  (interactive "p")
  (cmacs-lrg-vr--require-active)
  (let ((s (cmacs-lrg-vr-set-scale (* (cmacs-lrg-vr-scale) (expt 1.15 (or n 1))))))
    (message "VR scale %.2f m/unit" s)))

;;;###autoload
(defun cmacs-lrg-vr-smaller (&optional n)
  "Make the VR workspace smaller (and nearer) by 15%, N times."
  (interactive "p")
  (cmacs-lrg-vr-bigger (- (or n 1))))

;;;###autoload
(defun cmacs-lrg-vr-turn-left (&optional degrees)
  "Turn left by DEGREES (default `cmacs-lrg-vr-snap-degrees')."
  (interactive)
  (cmacs-lrg-vr--require-active)
  (cmacs-lrg-vr-turn (or degrees cmacs-lrg-vr-snap-degrees)))

;;;###autoload
(defun cmacs-lrg-vr-turn-right (&optional degrees)
  "Turn right by DEGREES (default `cmacs-lrg-vr-snap-degrees')."
  (interactive)
  (cmacs-lrg-vr--require-active)
  (cmacs-lrg-vr-turn (- (or degrees cmacs-lrg-vr-snap-degrees))))

;;;###autoload
(defun cmacs-lrg-vr-describe ()
  "Show the VR session's state: runtime, headset, controllers, scale."
  (interactive)
  (let ((st (and (fboundp 'cmacs-lrg-vr-status) (cmacs-lrg-vr-status))))
    (if (not st)
        (message "VR is not active%s"
                 (if (and (fboundp 'cmacs-lrg-vr-supported-p)
                          (cmacs-lrg-vr-supported-p))
                     " (start Emacs with --lrg=3dvr)"
                   " (this build has no OpenXR support)"))
      (message "VR: %s on %s, %s, %.0f Hz, scale %.2f; left %s%s, right %s%s"
               (or (plist-get st :runtime) "?")
               (or (plist-get st :system) "?")
               (plist-get st :state)
               (plist-get st :refresh-rate)
               (plist-get st :scale)
               (or (plist-get st :left-profile) "no controller")
               (if (plist-get st :left-tracked) "" " (untracked)")
               (or (plist-get st :right-profile) "no controller")
               (if (plist-get st :right-tracked) "" " (untracked)")))))

(defvar-keymap cmacs-lrg-vr-mode-map
  :doc "Keymap for `cmacs-lrg-vr-mode': controller buttons and VR commands."
  "<vr-right-a>"    #'cmacs-lrg-vr-toggle-keyboard
  "<vr-right-b>"    #'cmacs-lrg-vr-escape
  "<vr-left-x>"     #'cmacs-lrg-vr-focus-pointed-window
  "<vr-left-y>"     #'execute-extended-command
  "<vr-menu>"       #'cmacs-lrg-vr-recenter-view
  "<vr-left-stick>" #'cmacs-lrg-vr-reset-view
  "C-c v r"         #'cmacs-lrg-vr-recenter-view
  "C-c v k"         #'cmacs-lrg-vr-toggle-keyboard
  "C-c v +"         #'cmacs-lrg-vr-bigger
  "C-c v -"         #'cmacs-lrg-vr-smaller
  "C-c v ?"         #'cmacs-lrg-vr-describe)

(defun cmacs-lrg-vr--install-translations ()
  "Translate the controller's F25..F30 into the <vr-...> events."
  (pcase-dolist (`(,from . ,to) cmacs-lrg-vr--button-keys)
    (define-key function-key-map from to)))

(defun cmacs-lrg-vr--apply-options ()
  "Push the customization variables into the C side."
  (when (fboundp 'cmacs-lrg-vr-set-option)
    (cmacs-lrg-vr-set-option 'snap-degrees cmacs-lrg-vr-snap-degrees)
    (cmacs-lrg-vr-set-option 'move-speed cmacs-lrg-vr-move-speed)
    (cmacs-lrg-vr-set-option 'scroll-rate cmacs-lrg-vr-scroll-rate)
    (cmacs-lrg-vr-set-option 'haptics cmacs-lrg-vr-haptics)
    (cmacs-lrg-vr-set-option 'move-hand cmacs-lrg-vr-move-hand)
    (cmacs-lrg-vr-set-option 'keyboard-tilt cmacs-lrg-vr-keyboard-tilt))
  (when (and cmacs-lrg-vr-scale (cmacs-lrg-vr-active-now-p))
    (cmacs-lrg-vr-set-scale cmacs-lrg-vr-scale)))

;;;###autoload
(define-minor-mode cmacs-lrg-vr-mode
  "Bindings for Emacs in a VR headset (`emacs --lrg=3dvr').
Binds the controller buttons (<vr-right-a> and friends) and \\`C-c v'
VR commands.  Harmless off a headset: the <vr-...> events only come from
controllers."
  :global t
  :keymap cmacs-lrg-vr-mode-map
  :group 'cmacs-lrg-vr
  (when cmacs-lrg-vr-mode
    (cmacs-lrg-vr--install-translations)
    (cmacs-lrg-vr--apply-options)))

(defun cmacs-lrg-vr--announce ()
  "Size the frame for VR and say how to drive it, once a session is up."
  (when (cmacs-lrg-vr-active-now-p)
    (cmacs-lrg-vr--apply-options)
    (when (consp cmacs-lrg-vr-frame-size)
      (set-frame-size (selected-frame) (car cmacs-lrg-vr-frame-size)
                      (cdr cmacs-lrg-vr-frame-size) t))
    (message "VR: trigger clicks, grip grabs, right stick scrolls, left \
stick walks.  A keyboard, Y M-x, X focus, menu recenter")))

(add-hook 'window-setup-hook #'cmacs-lrg-vr--announce)

(provide 'cmacs-lrg-vr)

;;; cmacs-lrg-vr.el ends here
