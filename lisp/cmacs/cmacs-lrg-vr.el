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
;; The left controller is a *modifier hand* (`cmacs-lrg-vr-modifier-hand'):
;; its trigger, its bumper (the grip on controllers without one), or both
;; held are layers -- shift, meta, control by default -- added to every
;; button, click (S-mouse-1 extends the region), wheel event (C-wheel zooms
;; text) and in-world key.
;;
;; Buttons are named by the letter on them, whichever hand it is on (the
;; Steam Frame has A, B, X, Y on the right; Touch-style controllers X and Y
;; on the left): <vr-a> <vr-b> <vr-x> <vr-y> <vr-menu> <vr-view>
;; <vr-bumper> <vr-left-bumper> <vr-dpad-up> <vr-dpad-down> <vr-dpad-left>
;; <vr-dpad-right> <vr-left-stick> and <vr-right-stick> (the pointer stick
;; pressed off a panel; on one it is mouse-3).  Each tells a tap from a
;; hold:
;;
;;   <vr-a>          tap        <vr-a-hold>     held 0.35 s
;;   <vr-a-release>  let go after a hold
;;
;; with the layer's modifiers (S-<vr-y-hold>).  The pointer stick flicked
;; off a panel, or anywhere with a layer held, sends <vr-flick-left>,
;; <vr-flick-right>, <vr-flick-up>, <vr-flick-down>.  The C side sends them
;; as F25..F35 (alt for the second bank, hyper for a hold, super for its
;; release); `cmacs-lrg-vr--install-translations' names them.  A hold with
;; no binding of its own does what the tap does, and a release runs what
;; the hold asked for (`cmacs-lrg-vr-on-release') -- so push-to-talk is one
;; hold command.
;;
;; Rebind any of them in `cmacs-lrg-vr-mode-map':
;;
;;   (keymap-set cmacs-lrg-vr-mode-map "<vr-y>" #'consult-buffer)
;;   (keymap-set cmacs-lrg-vr-mode-map "S-<vr-a>" #'magit-status)
;;
;; \[cmacs-lrg-vr-controller-help] lists every binding; the voice,
;; workspace and quick-menu commands are in cmacs-lrg-vr-voice.el and
;; cmacs-lrg-vr-ui.el.

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
(declare-function cmacs-lrg-vr-set-indicator "cmacs-lrgvr.c" (hand color))
(declare-function cmacs-lrg-vr-layer "cmacs-lrgvr.c")
(declare-function cmacs-lrg-vr-haptic "cmacs-lrgvr.c" (hand &optional seconds amplitude))

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

(defcustom cmacs-lrg-vr-frame-size '(1240 . 880)
  "Pixel size (WIDTH . HEIGHT) the frame takes when VR starts, or nil.
In VR the frame is drawn offscreen and shown on a panel of fixed angular
size (about 41 degrees tall at the default seat), so this sets how many
frame pixels share each degree.  The default puts about one frame pixel
on one display pixel of a Steam Frame (about 21 per degree): text is as
sharp as the headset can show it.  More pixels fit more text in, each
line smaller, but the headset then has to shrink them and fine strokes
blur; fewer make text larger.  nil leaves the frame as created."
  :type '(choice (const :tag "Leave as created" nil)
                 (cons (integer :tag "Width") (integer :tag "Height"))))

(defcustom cmacs-lrg-vr-modifier-hand t
  "Non-nil: the move hand's trigger and bumper are layer modifiers.
While on, that hand's trigger does not click; its trigger, its bumper (the
grip on a controller without one, which then does not grab), or both held
add `cmacs-lrg-vr-trigger-modifier', `cmacs-lrg-vr-bumper-modifier' or
`cmacs-lrg-vr-both-modifier' to every button, click, scroll and keyboard
key.  A coloured dot on the controller shows the layer: blue trigger,
green bumper, orange both."
  :type 'boolean
  :set (cmacs-lrg-vr--set 'modifier-hand))

(defcustom cmacs-lrg-vr-modifier-source 'auto
  "The modifier hand's second layer button.
`auto' is the bumper on controllers that have one (the Steam Frame) and
the grip elsewhere."
  :type '(choice (const auto) (const bumper) (const grip))
  :set (cmacs-lrg-vr--set 'mod-second-source))

(defconst cmacs-lrg-vr--modifier-type
  '(choice (const shift) (const meta) (const control))
  "The modifiers a controller layer can be.
Hyper and super mark a button's hold and release, alt its second bank.")

(defcustom cmacs-lrg-vr-trigger-modifier 'shift
  "Modifier while the modifier hand's trigger is held."
  :type cmacs-lrg-vr--modifier-type
  :set (cmacs-lrg-vr--set 'mod-trigger))

(defcustom cmacs-lrg-vr-bumper-modifier 'meta
  "Modifier while the modifier hand's bumper (or grip) is held.
See `cmacs-lrg-vr-modifier-source'."
  :type cmacs-lrg-vr--modifier-type
  :set (cmacs-lrg-vr--set 'mod-bumper))

(defcustom cmacs-lrg-vr-both-modifier 'control
  "Modifier while the modifier hand's trigger and bumper are both held."
  :type cmacs-lrg-vr--modifier-type
  :set (cmacs-lrg-vr--set 'mod-both))

(defcustom cmacs-lrg-vr-hold-seconds 0.35
  "How long a controller button is held before it counts as a hold."
  :type 'number
  :set (cmacs-lrg-vr--set 'hold-seconds))

(defcustom cmacs-lrg-vr-dpad-arrows t
  "Non-nil: the D-pad sends arrow keys, repeating while held.
They move point, scroll completion lists and popup menus, and with a
layer held are S-<up>, M-<left> and so on.  nil sends <vr-dpad-up> and
friends instead, with tap and hold, to bind as you like."
  :type 'boolean
  :set (cmacs-lrg-vr--set 'dpad-arrows))

(defcustom cmacs-lrg-vr-escape-key nil
  "What <vr-b> sends.
nil means <escape> when `evil-mode' is on and \\[keyboard-quit] otherwise;
a key description string (\"C-g\", \"<escape>\") forces one."
  :type '(choice (const :tag "Automatic" nil) string))

(defconst cmacs-lrg-vr--button-keys
  '((f25 nil vr-a)
    (f26 nil vr-b)
    (f27 nil vr-x)
    (f28 nil vr-y)
    (f29 nil vr-menu)
    (f30 nil vr-left-stick)
    (f31 nil vr-right-stick)
    (f25 alt vr-bumper)
    (f26 alt vr-left-bumper)
    (f27 alt vr-view)
    (f28 alt vr-dpad-up)
    (f29 alt vr-dpad-down)
    (f30 alt vr-dpad-left)
    (f31 alt vr-dpad-right))
  "The keys the controller buttons arrive as, (KEY BANK NAME).
BANK is alt for the second bank.  Each also comes with hyper (held) and
super (released after a hold).")

(defconst cmacs-lrg-vr--flick-keys
  '((f32 . vr-flick-left)
    (f33 . vr-flick-right)
    (f34 . vr-flick-up)
    (f35 . vr-flick-down))
  "The function keys the pointer stick's flicks arrive as.")

(defun cmacs-lrg-vr--layer-modifiers ()
  "The modifier sets a controller layer can add: none, then each layer's."
  (delete-dups (list nil
                     (list cmacs-lrg-vr-trigger-modifier)
                     (list cmacs-lrg-vr-bumper-modifier)
                     (list cmacs-lrg-vr-both-modifier))))

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
Point at a key and pull either trigger to type.  Tap Ctrl, Meta or Super
to latch it for the next key (Shift cycles once -> locked -> off), or hold
it down with one trigger while the other hand types: Meta held + x is
M-x.  Grab the keyboard with the grip to move it."
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
  :doc "Keymap for `cmacs-lrg-vr-mode': controller buttons and VR commands.
Layers (the modifier hand): S- trigger, M- grip, C- both, by default."
  ;; No layer.
  "<vr-a>"                 #'cmacs-lrg-vr-toggle-keyboard
  "<vr-a-hold>"            #'cmacs-lrg-vr-voice-dictate-hold
  "<vr-b>"                 #'cmacs-lrg-vr-escape
  "<vr-b-hold>"            #'cmacs-lrg-vr-undo
  "<vr-x>"                 #'cmacs-lrg-vr-focus-pointed-window
  "<vr-x-hold>"            #'cmacs-lrg-vr-workspace-peek
  "<vr-y>"                 #'execute-extended-command
  "<vr-y-hold>"            #'cmacs-lrg-vr-voice-command-hold
  "<vr-menu>"              #'cmacs-lrg-vr-quick-menu
  "<vr-menu-hold>"         #'cmacs-lrg-vr-recenter-view
  "<vr-view>"              #'cmacs-lrg-vr-workspace-overview
  "<vr-view-hold>"         #'cmacs-lrg-vr-controller-help
  "<vr-bumper>"            #'cmacs-lrg-vr-switch-buffer
  "<vr-left-stick>"        #'cmacs-lrg-vr-reset-view
  "<vr-left-stick-hold>"   #'cmacs-lrg-vr-controller-help
  "<vr-right-stick>"       #'cmacs-lrg-vr-workspace-overview
  "<vr-dpad-left>"         #'cmacs-lrg-vr-workspace-previous
  "<vr-dpad-right>"        #'cmacs-lrg-vr-workspace-next
  "<vr-dpad-up>"           #'cmacs-lrg-vr-workspace-overview
  "<vr-dpad-down>"         #'cmacs-lrg-vr-workspace-overview-off
  "<vr-flick-left>"        #'cmacs-lrg-vr-workspace-previous
  "<vr-flick-right>"       #'cmacs-lrg-vr-workspace-next
  "<vr-flick-up>"          #'cmacs-lrg-vr-workspace-overview
  "<vr-flick-down>"        #'cmacs-lrg-vr-workspace-overview-off
  ;; Trigger layer (S-): workspaces and buffers.
  "S-<vr-a>"               #'cmacs-lrg-vr-workspace-new
  "S-<vr-b>"               #'cmacs-lrg-vr-workspace-close
  "S-<vr-x>"               #'cmacs-lrg-vr-workspace-switch
  "S-<vr-y>"               #'cmacs-lrg-vr-switch-buffer
  "S-<vr-menu>"            #'cmacs-lrg-vr-controller-help
  "S-<vr-dpad-up>"         #'scroll-down-command
  "S-<vr-dpad-down>"       #'scroll-up-command
  "S-<vr-flick-left>"      #'cmacs-lrg-vr-workspace-previous
  "S-<vr-flick-right>"     #'cmacs-lrg-vr-workspace-next
  ;; Bumper layer (M-): files and buffers.
  "M-<vr-a>"               #'cmacs-lrg-vr-find-file
  "M-<vr-b>"               #'cmacs-lrg-vr-close-window
  "M-<vr-b-hold>"          #'cmacs-lrg-vr-kill-buffer
  "M-<vr-x>"               #'cmacs-lrg-vr-recent-file
  "M-<vr-y>"               #'save-buffer
  "M-<vr-dpad-left>"       #'previous-buffer
  "M-<vr-dpad-right>"      #'next-buffer
  "M-<vr-flick-left>"      #'previous-buffer
  "M-<vr-flick-right>"     #'next-buffer
  ;; Both (C-): windows.
  "C-<vr-a>"               #'cmacs-lrg-vr-split-right
  "C-<vr-b>"               #'cmacs-lrg-vr-close-window
  "C-<vr-x>"               #'delete-other-windows
  "C-<vr-y>"               #'cmacs-lrg-vr-split-below
  "C-<vr-menu>"            #'cmacs-lrg-vr-cycle-arrangement
  "C-<vr-dpad-left>"       #'cmacs-lrg-vr-other-window-back
  "C-<vr-dpad-right>"      #'other-window
  "C-<vr-flick-left>"      #'cmacs-lrg-vr-other-window-back
  "C-<vr-flick-right>"     #'other-window
  ;; The keyboard, under the voice prefix (`C-c v', shared with
  ;; cmacs-audio/whisper/piper, whose r R p x d s S it leaves alone).
  "C-c v SPC"              #'cmacs-lrg-vr-voice-command
  "C-c v i"                #'cmacs-lrg-vr-voice-dictate
  "C-c v m"                #'cmacs-lrg-vr-quick-menu
  "C-c v h"                #'cmacs-lrg-vr-controller-help
  "C-c v o"                #'cmacs-lrg-vr-workspace-overview
  "C-c v n"                #'cmacs-lrg-vr-workspace-new
  "C-c v ]"                #'cmacs-lrg-vr-workspace-next
  "C-c v ["                #'cmacs-lrg-vr-workspace-previous
  "C-c v w"                #'cmacs-lrg-vr-workspace-switch
  "C-c v q"                #'cmacs-lrg-vr-workspace-close
  "C-c v c"                #'cmacs-lrg-vr-recenter-view
  "C-c v 0"                #'cmacs-lrg-vr-reset-view
  "C-c v k"                #'cmacs-lrg-vr-toggle-keyboard
  "C-c v +"                #'cmacs-lrg-vr-bigger
  "C-c v -"                #'cmacs-lrg-vr-smaller
  "C-c v ?"                #'cmacs-lrg-vr-describe
  ;; Voice results run as commands (`cmacs-lrg-vr-run-later').
  "<cmacs-lrg-vr-deferred>" #'cmacs-lrg-vr--run-deferred)

(defun cmacs-lrg-vr--event (base mods &optional suffix)
  "The event BASE (a symbol) with SUFFIX appended and modifiers MODS."
  (event-convert-list
   (append mods (list (if suffix (intern (format "%s-%s" base suffix)) base)))))

(defun cmacs-lrg-vr--install-translations ()
  "Name the controller's function keys: <vr-a>, its -hold, -release.
Every layer gets its own translation, since `function-key-map' does not
carry modifiers across.  Holds and releases with no binding go to the
dispatchers, so a slow press still does the tap and no release is ever
\"undefined\"."
  (dolist (mods (cmacs-lrg-vr--layer-modifiers))
    (pcase-dolist (`(,fkey ,bank ,name) cmacs-lrg-vr--button-keys)
      (define-key function-key-map
                  (vector (event-convert-list
                           (append mods (and bank (list bank)) (list fkey))))
                  (vector (cmacs-lrg-vr--event name mods)))
      (pcase-dolist (`(,bit . ,suffix) '((hyper . "hold") (super . "release")))
        (let ((to (cmacs-lrg-vr--event name mods suffix)))
          (define-key function-key-map
                      (vector (event-convert-list
                               (append mods (and bank (list bank)) (list bit fkey))))
                      (vector to))
          (unless (lookup-key cmacs-lrg-vr-mode-map (vector to))
            (define-key cmacs-lrg-vr-mode-map (vector to)
                        (if (equal suffix "hold")
                            #'cmacs-lrg-vr-hold-as-tap
                          #'cmacs-lrg-vr-button-released))))))
    (pcase-dolist (`(,fkey . ,name) cmacs-lrg-vr--flick-keys)
      (define-key function-key-map
                  (vector (event-convert-list (append mods (list fkey))))
                  (vector (cmacs-lrg-vr--event name mods))))))

;;;; Holds and releases

(defvar cmacs-lrg-vr--release-actions nil
  "Alist (BUTTON . FUNCTION): what releasing BUTTON after a hold runs.")

(defun cmacs-lrg-vr--button-of (event)
  "The button symbol (vr-a ...) EVENT is a tap, hold or release of."
  (let ((name (symbol-name (event-basic-type event))))
    (intern (replace-regexp-in-string "-\\(hold\\|release\\)\\'" "" name))))

(defun cmacs-lrg-vr-on-release (function)
  "Run FUNCTION when the button whose hold is running now is let go.
For hold commands: push-to-talk starts recording here and stops in
FUNCTION.  Outside a button hold, does nothing and returns nil."
  (when (and (symbolp (event-basic-type last-command-event))
             (string-suffix-p "-hold" (symbol-name
                                       (event-basic-type last-command-event))))
    (setf (alist-get (cmacs-lrg-vr--button-of last-command-event)
                     cmacs-lrg-vr--release-actions)
          function)
    t))

(defun cmacs-lrg-vr-button-released ()
  "Run what the hold of this button asked to run when let go."
  (interactive)
  (let* ((button (cmacs-lrg-vr--button-of last-command-event))
         (fn (alist-get button cmacs-lrg-vr--release-actions)))
    (setf (alist-get button cmacs-lrg-vr--release-actions nil t) nil)
    (when fn
      (funcall fn))))

(defun cmacs-lrg-vr-hold-as-tap ()
  "A hold with no binding of its own: do what the tap does."
  (interactive)
  (let* ((ev last-command-event)
         (tap (event-convert-list
               (append (event-modifiers ev)
                       (list (cmacs-lrg-vr--button-of ev)))))
         (cmd (key-binding (vector tap))))
    (when (commandp cmd)
      (setq this-command cmd)
      (call-interactively cmd))))

;;;; Running things later, as commands

(defvar cmacs-lrg-vr--deferred nil
  "Functions queued by `cmacs-lrg-vr-run-later', oldest first.")

(defun cmacs-lrg-vr-run-later (function)
  "Run FUNCTION as a command, from the command loop, as soon as it can.
Voice results arrive in a transcription callback; running what they say
there would run it outside any command -- no undo boundary, no
`this-command', and a minibuffer opened from a callback.  This queues
FUNCTION and an input event bound to `cmacs-lrg-vr--run-deferred'."
  (setq cmacs-lrg-vr--deferred (append cmacs-lrg-vr--deferred (list function)))
  (push 'cmacs-lrg-vr-deferred unread-command-events))

(defun cmacs-lrg-vr--run-deferred ()
  "Run the oldest function `cmacs-lrg-vr-run-later' queued."
  (interactive)
  (let ((fn (pop cmacs-lrg-vr--deferred)))
    (when fn
      (funcall fn))))

(defun cmacs-lrg-vr--apply-options ()
  "Push the customization variables into the C side."
  (when (fboundp 'cmacs-lrg-vr-set-option)
    (cmacs-lrg-vr-set-option 'snap-degrees cmacs-lrg-vr-snap-degrees)
    (cmacs-lrg-vr-set-option 'move-speed cmacs-lrg-vr-move-speed)
    (cmacs-lrg-vr-set-option 'scroll-rate cmacs-lrg-vr-scroll-rate)
    (cmacs-lrg-vr-set-option 'haptics cmacs-lrg-vr-haptics)
    (cmacs-lrg-vr-set-option 'move-hand cmacs-lrg-vr-move-hand)
    (cmacs-lrg-vr-set-option 'keyboard-tilt cmacs-lrg-vr-keyboard-tilt)
    (cmacs-lrg-vr-set-option 'modifier-hand cmacs-lrg-vr-modifier-hand)
    (cmacs-lrg-vr-set-option 'mod-trigger cmacs-lrg-vr-trigger-modifier)
    (cmacs-lrg-vr-set-option 'mod-bumper cmacs-lrg-vr-bumper-modifier)
    (cmacs-lrg-vr-set-option 'mod-second-source cmacs-lrg-vr-modifier-source)
    (cmacs-lrg-vr-set-option 'mod-both cmacs-lrg-vr-both-modifier)
    (cmacs-lrg-vr-set-option 'hold-seconds cmacs-lrg-vr-hold-seconds)
    (cmacs-lrg-vr-set-option 'dpad-arrows cmacs-lrg-vr-dpad-arrows))
  (when (and cmacs-lrg-vr-scale (cmacs-lrg-vr-active-now-p))
    (cmacs-lrg-vr-set-scale cmacs-lrg-vr-scale)))

;;;###autoload
(define-minor-mode cmacs-lrg-vr-mode
  "Bindings for Emacs in a VR headset (`emacs --lrg=3dvr').
Binds the controller buttons (<vr-a> and friends) and \\`C-c v'
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
    (when (fboundp 'cmacs-lrg-vr-ui--session-start)
      (cmacs-lrg-vr-ui--session-start))
    (message "%s" (substitute-command-keys "VR: menu button = quick menu, \
hold View or the left stick = all controls (\\[cmacs-lrg-vr-controller-help]).  Hold A to \
dictate, hold Y for a voice command"))))

(add-hook 'window-setup-hook #'cmacs-lrg-vr--announce)

(provide 'cmacs-lrg-vr)

;; The interface on top: voice, workspaces, the quick menu, help.  After
;; `provide', since they require this file.
(require 'cmacs-lrg-vr-voice nil t)
(require 'cmacs-lrg-vr-ui nil t)

;;; cmacs-lrg-vr.el ends here
