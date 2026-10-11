;;; cmacs-lrg-vr-ui.el --- The VR interface: workspaces, quick menu, help -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The controller-first layer of Emacs in a VR headset (`emacs --lrg=3dvr'),
;; on top of the bindings in cmacs-lrg-vr.el:
;;
;; - Workspaces you can see.  Each Doom workspace (persp-mode; tab-bar
;;   tabs without Doom) is a panel on the 3D carousel around you
;;   (cmacs-lrg-3d-workspaces.el).  Flick the pointer stick left / right
;;   off a panel -- or anywhere with the trigger layer held -- to cycle;
;;   hold X to pull back and see them all, let go to return.
;; - A quick menu on the menu button: voice, workspaces, buffers, files,
;;   windows and the view, chosen with the laser.
;; - \\[cmacs-lrg-vr-controller-help]: every controller binding, layer by
;;   layer, read from the keymap -- so it stays true when you rebind.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-lrg-vr)

(declare-function lrg-popup-menu "cmacs-lrgterm.c" (items &optional x y))
(declare-function cmacs-lrg-3d-camera "cmacs-lrgterm.c" (op &optional amount frame))
(declare-function cmacs-lrg-3d-dolly "cmacs-lrgterm.c" (factor &optional frame))
(declare-function cmacs-lrg-3d-set-arrangement "cmacs-lrgterm.c" (name &optional frame))
(declare-function cmacs-lrg-3d-arrangement "cmacs-lrgterm.c" (&optional frame))
(declare-function cmacs-lrg-3d-set-environment "cmacs-lrgterm.c" (name &optional frame))
(declare-function cmacs-lrg-3d-workspaces-mode "cmacs-lrg-3d-workspaces" (&optional arg))
(declare-function cmacs-lrg-3d-workspaces-overview "cmacs-lrg-3d-workspaces")
(declare-function cmacs-lrg-3d-workspaces-refresh "cmacs-lrg-3d-workspaces" (&optional frame))
(declare-function cmacs-lrg-vr-voice-command "cmacs-lrg-vr-voice")
(declare-function cmacs-lrg-vr-voice-dictate "cmacs-lrg-vr-voice")
(declare-function cmacs-lrg-vr-voice-help "cmacs-lrg-vr-voice")
(declare-function +workspace-list-names "workspaces")
(declare-function +workspace-current-name "workspaces")
(declare-function +workspace-switch "workspaces" (name &optional auto-create-p))
(declare-function +workspace/new "workspaces" (&optional name clone-p))
(declare-function +workspace/cycle "workspaces" (n))
(declare-function +workspace/kill "workspaces" (name))
(declare-function evil-undo "evil-commands" (count))
(declare-function consult-buffer "consult")
(declare-function consult-recent-file "consult")
(declare-function projectile-project-p "projectile" (&optional dir))
(declare-function projectile-find-file "projectile" (&optional invalidate-cache))
(defvar cmacs-lrg-3d-workspaces-mode)
(defvar recentf-list)

(defgroup cmacs-lrg-vr-ui nil
  "The VR interface: workspaces, the quick menu, controller help."
  :group 'cmacs-lrg-vr
  :prefix "cmacs-lrg-vr-")

(defcustom cmacs-lrg-vr-carousel t
  "Non-nil: show every workspace on the 3D carousel while in VR."
  :type 'boolean)

(defcustom cmacs-lrg-vr-arrangements '("per-window" "single-panel" "free")
  "The panel arrangements \\[cmacs-lrg-vr-cycle-arrangement] steps through."
  :type '(repeat string))


;;;; Small commands the controller bindings name

(defun cmacs-lrg-vr--buzz (&optional hand seconds amplitude)
  "Pulse HAND's controller (default right) when in VR, haptics on."
  (when (and (cmacs-lrg-vr-active-now-p) cmacs-lrg-vr-haptics
             (fboundp 'cmacs-lrg-vr-haptic))
    (ignore-errors (cmacs-lrg-vr-haptic (or hand 'right) (or seconds 0.03)
                                        (or amplitude 0.5)))))

;;;###autoload
(defun cmacs-lrg-vr-undo ()
  "Undo -- through Evil's undo when Evil is on."
  (interactive)
  (if (and (bound-and-true-p evil-mode) (fboundp 'evil-undo))
      (evil-undo 1)
    (undo)))

;;;###autoload
(defun cmacs-lrg-vr-switch-buffer ()
  "Switch buffer, with `consult-buffer' when it is there."
  (interactive)
  (call-interactively (if (fboundp 'consult-buffer) #'consult-buffer
                        #'switch-to-buffer)))

;;;###autoload
(defun cmacs-lrg-vr-find-file (&optional initial)
  "Find a file: in the project when in one, else from the current directory.
INITIAL, when given (a spoken file name), is typed into the prompt."
  (interactive)
  (minibuffer-with-setup-hook (lambda () (when initial (insert initial)))
    (call-interactively
     (cond ((and (fboundp 'projectile-project-p) (projectile-project-p)
                 (fboundp 'projectile-find-file))
            #'projectile-find-file)
           ((and (fboundp 'project-current) (project-current)) #'project-find-file)
           (t #'find-file)))))

;;;###autoload
(defun cmacs-lrg-vr-recent-file ()
  "Open a recently visited file."
  (interactive)
  (cond ((fboundp 'consult-recent-file) (call-interactively #'consult-recent-file))
        ((require 'recentf nil t)
         (unless (bound-and-true-p recentf-mode) (recentf-mode 1))
         (find-file (completing-read "Recent file: " recentf-list nil t)))))

;;;###autoload
(defun cmacs-lrg-vr-kill-buffer ()
  "Kill the current buffer (asking first if it is modified)."
  (interactive)
  (kill-buffer (current-buffer)))

;;;###autoload
(defun cmacs-lrg-vr-split-right ()
  "Split the window side by side and show the other half."
  (interactive)
  (select-window (split-window-right)))

;;;###autoload
(defun cmacs-lrg-vr-split-below ()
  "Split the window top and bottom and show the lower half."
  (interactive)
  (select-window (split-window-below)))

;;;###autoload
(defun cmacs-lrg-vr-other-window-back ()
  "Select the previous window."
  (interactive)
  (other-window -1))

;;;###autoload
(defun cmacs-lrg-vr-cycle-arrangement ()
  "Step the 3D panels through `cmacs-lrg-vr-arrangements'."
  (interactive)
  (unless (fboundp 'cmacs-lrg-3d-set-arrangement)
    (user-error "Not a 3D lrg frame"))
  (let* ((cur (and (fboundp 'cmacs-lrg-3d-arrangement) (cmacs-lrg-3d-arrangement)))
         (tail (cdr (member cur cmacs-lrg-vr-arrangements)))
         (next (or (car tail) (car cmacs-lrg-vr-arrangements))))
    (cmacs-lrg-3d-set-arrangement next)
    (message "Arrangement: %s" next)))


;;;; Workspaces

(defun cmacs-lrg-vr--doom-workspaces-p ()
  "Non-nil when Doom's workspaces (persp-mode) are in use."
  (and (fboundp '+workspace-list-names) (fboundp '+workspace-switch)
       (bound-and-true-p persp-mode)))

(defun cmacs-lrg-vr-workspace-names ()
  "The workspace names, in order."
  (if (cmacs-lrg-vr--doom-workspaces-p)
      (+workspace-list-names)
    (mapcar (lambda (tab) (alist-get 'name tab)) (funcall #'tab-bar-tabs))))

(defun cmacs-lrg-vr-workspace-current ()
  "The current workspace's name."
  (if (cmacs-lrg-vr--doom-workspaces-p)
      (+workspace-current-name)
    (alist-get 'name (tab-bar--current-tab))))

(defun cmacs-lrg-vr--workspace-announce ()
  "Say which workspace this is, of how many, and buzz."
  (let* ((names (cmacs-lrg-vr-workspace-names))
         (cur (cmacs-lrg-vr-workspace-current))
         (i (cl-position cur names :test #'equal)))
    (cmacs-lrg-vr--buzz 'right 0.02 0.4)
    (message "%s"
             (mapconcat (lambda (n)
                          (if (equal n cur)
                              (propertize (format "[%s]" n) 'face 'success)
                            n))
                        names "  "))
    (and i (1+ i))))

;;;###autoload
(defun cmacs-lrg-vr-workspace-new (&optional name)
  "Make a new workspace and switch to it.  NAME, if given, names it.
In VR the one you left joins the carousel around you."
  (interactive)
  (if (cmacs-lrg-vr--doom-workspaces-p)
      (+workspace/new (and name (not (string-empty-p name)) name))
    (tab-bar-new-tab)
    (when name (tab-bar-rename-tab name)))
  (cmacs-lrg-vr--workspace-announce))

;;;###autoload
(defun cmacs-lrg-vr-workspace-next (&optional n)
  "Switch to the next workspace (the Nth next with a prefix argument)."
  (interactive "p")
  (if (cmacs-lrg-vr--doom-workspaces-p)
      (+workspace/cycle (or n 1))
    (tab-bar-switch-to-next-tab (or n 1)))
  (cmacs-lrg-vr--workspace-announce))

;;;###autoload
(defun cmacs-lrg-vr-workspace-previous (&optional n)
  "Switch to the previous workspace (the Nth previous with a prefix)."
  (interactive "p")
  (cmacs-lrg-vr-workspace-next (- (or n 1))))

;;;###autoload
(defun cmacs-lrg-vr-workspace-goto (which)
  "Switch to workspace WHICH: a 1-based number (string or integer) or a name.
A name that is not exact matches the workspace whose name contains it."
  (interactive (list (completing-read "Workspace: " (cmacs-lrg-vr-workspace-names))))
  (let* ((names (cmacs-lrg-vr-workspace-names))
         (n (cond ((integerp which) which)
                  ((string-match-p "\\`[0-9]+\\'" which) (string-to-number which))))
         (name (cond (n (nth (1- n) names))
                     ((member which names) which)
                     (t (cl-find-if (lambda (x) (string-search (downcase which)
                                                               (downcase x)))
                                    names)))))
    (unless name
      (user-error "No workspace %s" which))
    (if (cmacs-lrg-vr--doom-workspaces-p)
        (+workspace-switch name)
      (tab-bar-switch-to-tab name))
    (cmacs-lrg-vr--workspace-announce)))

;;;###autoload
(defun cmacs-lrg-vr-workspace-switch ()
  "Pick a workspace to switch to."
  (interactive)
  (call-interactively #'cmacs-lrg-vr-workspace-goto))

;;;###autoload
(defun cmacs-lrg-vr-workspace-close ()
  "Close the current workspace, after asking."
  (interactive)
  (let ((cur (cmacs-lrg-vr-workspace-current)))
    (when (y-or-n-p (format "Close workspace %s? " cur))
      (if (cmacs-lrg-vr--doom-workspaces-p)
          (+workspace/kill cur)
        (tab-bar-close-tab))
      (cmacs-lrg-vr--workspace-announce))))

(defvar cmacs-lrg-vr--overview nil
  "Non-nil while the view is pulled back to show every workspace.")

;;;###autoload
(defun cmacs-lrg-vr-workspace-overview (&optional arg)
  "Pull back to see every workspace on the carousel; again to return.
With ARG, show when positive, return when not."
  (interactive "P")
  (let ((on (if arg (> (prefix-numeric-value arg) 0)
              (not cmacs-lrg-vr--overview))))
    (if on
        (progn
          (when (fboundp 'cmacs-lrg-3d-workspaces-refresh)
            (ignore-errors (cmacs-lrg-3d-workspaces-refresh)))
          (cond ((fboundp 'cmacs-lrg-3d-workspaces-overview)
                 (cmacs-lrg-3d-workspaces-overview))
                ((fboundp 'cmacs-lrg-3d-dolly) (cmacs-lrg-3d-dolly 1.9))
                (t (user-error "No 3D workspace view here")))
          (setq cmacs-lrg-vr--overview t)
          (cmacs-lrg-vr--workspace-announce))
      (when (fboundp 'cmacs-lrg-3d-camera)
        (cmacs-lrg-3d-camera "reset"))
      (when (cmacs-lrg-vr-active-now-p)
        (cmacs-lrg-vr-recenter))
      (setq cmacs-lrg-vr--overview nil))))

;;;###autoload
(defun cmacs-lrg-vr-workspace-overview-off ()
  "Return from the workspace overview."
  (interactive)
  (cmacs-lrg-vr-workspace-overview -1))

;;;###autoload
(defun cmacs-lrg-vr-workspace-peek ()
  "Show every workspace while the button is held; return when let go.
Off a controller, a toggle like \\[cmacs-lrg-vr-workspace-overview]."
  (interactive)
  (cmacs-lrg-vr-workspace-overview 1)
  (cmacs-lrg-vr-on-release #'cmacs-lrg-vr-workspace-overview-off))


;;;; The quick menu

(defun cmacs-lrg-vr--menu-buffers ()
  "Recent buffers worth switching to, most recent first, at most 12."
  (seq-take (cl-remove-if (lambda (b) (or (string-prefix-p " " (buffer-name b))
                                          (eq b (current-buffer))))
                          (buffer-list))
            12))

(defun cmacs-lrg-vr--menu-spec ()
  "The quick menu: a tree of (LABEL . FUNCTION) and (LABEL ITEM...)."
  (let ((ws (cmacs-lrg-vr-workspace-names))
        (cur (cmacs-lrg-vr-workspace-current)))
    `(("Voice command (hold Y)" . cmacs-lrg-vr-voice-command)
      ("Dictate at cursor (hold A)" . cmacs-lrg-vr-voice-dictate)
      ("M-x..." . execute-extended-command)
      nil
      ("Workspaces"
       ("New workspace" . cmacs-lrg-vr-workspace-new)
       ("Next" . cmacs-lrg-vr-workspace-next)
       ("Previous" . cmacs-lrg-vr-workspace-previous)
       ("Show all (overview)" . cmacs-lrg-vr-workspace-overview)
       ("Close this workspace" . cmacs-lrg-vr-workspace-close)
       nil
       ,@(cl-loop for n in ws for i from 1
                  collect (cons (format "%d  %s%s" i n (if (equal n cur) "  *" ""))
                                (let ((name n))
                                  (lambda () (interactive)
                                    (cmacs-lrg-vr-workspace-goto name))))))
      ("Buffers"
       ("Switch buffer..." . cmacs-lrg-vr-switch-buffer)
       ("Kill this buffer" . cmacs-lrg-vr-kill-buffer)
       nil
       ,@(mapcar (lambda (b)
                   (cons (buffer-name b)
                         (lambda () (interactive) (switch-to-buffer b))))
                 (cmacs-lrg-vr--menu-buffers)))
      ("Files"
       ("Find file..." . cmacs-lrg-vr-find-file)
       ("Recent files..." . cmacs-lrg-vr-recent-file)
       ("Save" . save-buffer)
       ("Save all" . ,(lambda () (interactive) (save-some-buffers t))))
      ("Windows"
       ("Split right" . cmacs-lrg-vr-split-right)
       ("Split below" . cmacs-lrg-vr-split-below)
       ("Other window" . other-window)
       ("Close window" . delete-window)
       ("Only this window" . delete-other-windows)
       nil
       ,@(mapcar (lambda (a)
                   (cons (format "Arrangement: %s" a)
                         (lambda () (interactive)
                           (cmacs-lrg-3d-set-arrangement a))))
                 cmacs-lrg-vr-arrangements))
      ("View"
       ("Recenter in front of me" . cmacs-lrg-vr-recenter-view)
       ("Reset view" . cmacs-lrg-vr-reset-view)
       ("Keyboard" . cmacs-lrg-vr-toggle-keyboard)
       ("Bigger" . cmacs-lrg-vr-bigger)
       ("Smaller" . cmacs-lrg-vr-smaller)
       nil
       ,@(mapcar (lambda (e)
                   (cons (format "Room: %s" e)
                         (lambda () (interactive)
                           (cmacs-lrg-3d-set-environment e))))
                 '("void" "workshop" "cockpit")))
      nil
      ("Controller help" . cmacs-lrg-vr-controller-help)
      ("Voice commands" . cmacs-lrg-vr-voice-help))))

(defun cmacs-lrg-vr--menu-tree (spec values)
  "Turn SPEC into an `lrg-popup-menu' tree; push each leaf's function on VALUES.
VALUES is a cons cell whose car is the list of functions so far; a leaf's
index is its position in that list."
  (mapcar
   (lambda (item)
     (cond ((null item) nil)
           ((and (consp item) (consp (cdr item)) (not (functionp (cdr item)))
                 (listp (cadr item)))
            (cons (car item) (cmacs-lrg-vr--menu-tree (cdr item) values)))
           (t
            (setcar values (append (car values) (list (cdr item))))
            (cons (car item) (1- (length (car values)))))))
   spec))

(defun cmacs-lrg-vr--menu-flat (spec &optional prefix)
  "SPEC as (\"Path > Label\" . FUNCTION) pairs, for `completing-read'."
  (cl-loop for item in spec
           when item
           append (let ((label (if prefix (concat prefix " > " (car item))
                                 (car item))))
                    (if (and (consp (cdr item)) (listp (cadr item))
                             (not (functionp (cdr item))))
                        (cmacs-lrg-vr--menu-flat (cdr item) label)
                      (list (cons label (cdr item)))))))

;;;###autoload
(defun cmacs-lrg-vr-quick-menu ()
  "A menu of the things you do in VR, at the laser.
Point and pull the trigger to choose; B or the right-stick press closes
it.  Off an lrg frame, a completion list of the same items."
  (interactive)
  (let* ((spec (cmacs-lrg-vr--menu-spec))
         (fn (if (fboundp 'lrg-popup-menu)
                 (let* ((values (list nil))
                        (tree (cmacs-lrg-vr--menu-tree spec values))
                        (idx (lrg-popup-menu tree)))
                   (and idx (nth idx (car values))))
               (let* ((flat (cmacs-lrg-vr--menu-flat spec))
                      (pick (completing-read "VR: " flat nil t)))
                 (cdr (assoc pick flat))))))
    (when fn
      (setq this-command fn)
      (if (commandp fn) (call-interactively fn) (funcall fn)))))


;;;; Controller help

(defconst cmacs-lrg-vr--help-buttons
  '((vr-a . "A")
    (vr-b . "B")
    (vr-x . "X")
    (vr-y . "Y")
    (vr-menu . "Menu")
    (vr-view . "View")
    (vr-bumper . "Right bumper")
    (vr-left-bumper . "Left bumper (modifiers off)")
    (vr-dpad-up . "D-pad up")
    (vr-dpad-down . "D-pad down")
    (vr-dpad-left . "D-pad left")
    (vr-dpad-right . "D-pad right")
    (vr-left-stick . "Left stick press")
    (vr-right-stick . "Right stick press (off a panel)")
    (vr-flick-left . "Right stick flick left")
    (vr-flick-right . "Right stick flick right")
    (vr-flick-up . "Right stick flick up")
    (vr-flick-down . "Right stick flick down"))
  "The controller events the help sheet lists, and what to call them.")

(defun cmacs-lrg-vr--help-binding (event)
  "A short description of EVENT's binding in the VR keymap, or nil."
  (let ((cmd (lookup-key cmacs-lrg-vr-mode-map (vector event))))
    (cond ((memq cmd '(nil cmacs-lrg-vr-button-released)) nil)
          ((eq cmd 'cmacs-lrg-vr-hold-as-tap) nil)
          ((symbolp cmd)
           (replace-regexp-in-string "\\`cmacs-lrg-vr-" "" (symbol-name cmd)))
          (t "(lambda)"))))

;;;###autoload
(defun cmacs-lrg-vr-controller-help ()
  "Show every controller binding, layer by layer.
Read from `cmacs-lrg-vr-mode-map', so it shows your own bindings too."
  (interactive)
  (let ((layers `((nil . "")
                  ((,cmacs-lrg-vr-trigger-modifier) . "trigger")
                  ((,cmacs-lrg-vr-bumper-modifier) . "bumper")
                  ((,cmacs-lrg-vr-both-modifier) . "both"))))
    (with-help-window "*VR Controls*"
      (princ "VR controller bindings  (cmacs-lrg-vr-mode-map)\n\n")
      (princ "Right hand points:  trigger = click (mouse-1)   grip = grab a panel,\n")
      (princ "the keyboard or the world   stick = scroll   stick press on a panel\n")
      (princ "= context menu (mouse-3).  Left hand: stick walks and snap-turns,\n")
      (princ "grip grabs too.\n")
      (when cmacs-lrg-vr-modifier-hand
        (princ (format "Left trigger = %s layer, left bumper = %s, both = %s; the\n"
                       cmacs-lrg-vr-trigger-modifier cmacs-lrg-vr-bumper-modifier
                       cmacs-lrg-vr-both-modifier))
        (princ "layer applies to every button, click, scroll and key.  (On a\n")
        (princ "controller with no bumper the left grip is the second layer.)\n"))
      (princ (format "\nTap = press and let go;  hold = %.2gs or longer.\n\n"
                     cmacs-lrg-vr-hold-seconds))
      (pcase-dolist (`(,mods . ,lname) layers)
        (princ (if (string-empty-p lname) "--- No layer ---\n"
                 (format "--- %s layer (%s held) ---\n"
                         (car mods) lname)))
        (let ((any nil))
          (pcase-dolist (`(,button . ,label) cmacs-lrg-vr--help-buttons)
            (let ((tap (cmacs-lrg-vr--help-binding (cmacs-lrg-vr--event button mods)))
                  (hold (and (not (string-prefix-p "vr-flick" (symbol-name button)))
                             (cmacs-lrg-vr--help-binding
                              (cmacs-lrg-vr--event button mods "hold")))))
              (when (or tap hold)
                (setq any t)
                (princ (format "  %-34s %s%s\n" label (or tap "-")
                               (if hold (format "   [hold: %s]" hold) ""))))))
          (unless any (princ "  (nothing bound)\n")))
        (princ "\n"))
      (princ "Keyboard:  C-c v SPC voice command   C-c v i dictate   C-c v m menu\n")
      (princ "C-c v o overview  C-c v n/]/[/w/q workspaces  C-c v c recenter\n")
      (princ "C-c v k keyboard  C-c v h this help.  Voice: M-x cmacs-lrg-vr-voice-help\n"))))


;;;; Session

(defun cmacs-lrg-vr-ui--session-start ()
  "Set up the VR interface once a headset session is up."
  (when (and cmacs-lrg-vr-carousel
             (require 'cmacs-lrg-3d-workspaces nil t)
             (not (bound-and-true-p cmacs-lrg-3d-workspaces-mode)))
    (ignore-errors (cmacs-lrg-3d-workspaces-mode 1))))

(provide 'cmacs-lrg-vr-ui)

;;; cmacs-lrg-vr-ui.el ends here
