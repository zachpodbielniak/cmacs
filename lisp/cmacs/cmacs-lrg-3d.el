;;; cmacs-lrg-3d.el --- Runtime control for the lrg 3D display backend -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Interactive commands, a minor mode, and depth-of-field focus-follow for the
;; libregnum 3D display backend (`emacs --lrg=3d').  The heavy lifting lives in
;; C DEFUNs (`cmacs-lrg-3d-set-arrangement', `cmacs-lrg-3d-set-environment',
;; `cmacs-lrg-3d-focus-window', `cmacs-lrg-render-mode', ...); this file is the
;; ergonomic Lisp surface over them.  All commands no-op gracefully off an lrg
;; 3D frame.

;;; Code:

(defgroup cmacs-lrg-3d nil
  "Control the libregnum 3D display backend (`emacs --lrg=3d')."
  :group 'cmacs
  :prefix "cmacs-lrg-3d-")

(defconst cmacs-lrg-3d-arrangements '("single-panel" "per-window" "free")
  "Built-in 3D panel arrangements (see `cmacs-lrg-set-arrangement').")

(defconst cmacs-lrg-3d-environments '("void" "workshop" "cockpit")
  "Built-in 3D ambient environments (see `cmacs-lrg-set-environment').")

(defcustom cmacs-lrg-3d-follow-selected-window t
  "When non-nil, depth-of-field focus follows the selected window.
Only has an effect under a per-window / free arrangement on a 3D lrg frame."
  :type 'boolean
  :group 'cmacs-lrg-3d)

(defun cmacs-lrg-3d-active-p (&optional frame)
  "Return non-nil if FRAME (default selected) is a 3D lrg frame."
  (and (fboundp 'cmacs-lrg-3d-supported-p)
       (cmacs-lrg-3d-supported-p frame)))

;;;###autoload
(defun cmacs-lrg-set-arrangement (arrangement)
  "Set the 3D panel ARRANGEMENT of the selected lrg frame.
ARRANGEMENT is an id string such as \"single-panel\" or \"per-window\"."
  (interactive
   (list (completing-read
          "3D arrangement: " cmacs-lrg-3d-arrangements nil nil nil nil
          (or (and (fboundp 'cmacs-lrg-3d-arrangement)
                   (cmacs-lrg-3d-arrangement))
              "single-panel"))))
  (if (and (fboundp 'cmacs-lrg-3d-set-arrangement)
           (cmacs-lrg-3d-set-arrangement arrangement))
      (message "lrg 3D arrangement: %s" arrangement)
    (user-error "Not a 3D lrg frame, or unknown arrangement: %s" arrangement)))

;;;###autoload
(defun cmacs-lrg-set-environment (environment)
  "Set the 3D ambient ENVIRONMENT of the selected lrg frame.
ENVIRONMENT is an id string such as \"void\", \"workshop\" or \"cockpit\"."
  (interactive
   (list (completing-read
          "3D environment: " cmacs-lrg-3d-environments nil nil nil nil
          (or (and (fboundp 'cmacs-lrg-3d-environment)
                   (cmacs-lrg-3d-environment))
              "void"))))
  (if (and (fboundp 'cmacs-lrg-3d-set-environment)
           (cmacs-lrg-3d-set-environment environment))
      (message "lrg 3D environment: %s" environment)
    (user-error "Not a 3D lrg frame, or unknown environment: %s" environment)))

;;;###autoload
(defun cmacs-lrg-3d-describe ()
  "Echo the selected frame's lrg render mode, arrangement and environment."
  (interactive)
  (message "lrg: mode=%s  arrangement=%s  environment=%s"
           (or (and (fboundp 'cmacs-lrg-render-mode) (cmacs-lrg-render-mode))
               "n/a")
           (or (and (fboundp 'cmacs-lrg-3d-arrangement)
                    (cmacs-lrg-3d-arrangement))
               "n/a")
           (or (and (fboundp 'cmacs-lrg-3d-environment)
                    (cmacs-lrg-3d-environment))
               "n/a")))

(defcustom cmacs-lrg-3d-focus-follow-flies-camera nil
  "When non-nil, selecting a window also flies the camera to it front-and-centre.
When nil (the default, the \"hybrid\" feel), selecting a window only moves the
depth-of-field focus to it; the camera flies only on an explicit focus command
\(\\[cmacs-lrg-focus-window] or Ctrl+double-left-click).  Set to t for a fully
\"command-the-room\" feel where the view always follows your attention."
  :type 'boolean
  :group 'cmacs-lrg-3d)

(defun cmacs-lrg-3d--track-selected-window (&rest _)
  "Point depth-of-field focus at the selected window (focus-follow).
Also flies the camera when `cmacs-lrg-3d-focus-follow-flies-camera' is non-nil."
  (when (and cmacs-lrg-3d-follow-selected-window
             (cmacs-lrg-3d-active-p))
    (ignore-errors
      (if (and cmacs-lrg-3d-focus-follow-flies-camera
               (fboundp 'cmacs-lrg-3d-focus-panel))
          (cmacs-lrg-3d-focus-panel (selected-window))
        (when (fboundp 'cmacs-lrg-3d-focus-window)
          (cmacs-lrg-3d-focus-window (selected-window)))))))

;;;###autoload
(defun cmacs-lrg-camera-reset ()
  "Reset the 3D camera to its default head-on pose."
  (interactive) (cmacs-lrg-3d-camera "reset"))

;;;###autoload
(defun cmacs-lrg-camera-zoom-in ()
  "Move the 3D camera toward the panels."
  (interactive) (cmacs-lrg-3d-camera "zoom-in"))

;;;###autoload
(defun cmacs-lrg-camera-zoom-out ()
  "Move the 3D camera away from the panels."
  (interactive) (cmacs-lrg-3d-camera "zoom-out"))

;;;###autoload
(defun cmacs-lrg-camera-orbit-left ()
  "Orbit the 3D camera left around the panels."
  (interactive) (cmacs-lrg-3d-camera "orbit-left"))

;;;###autoload
(defun cmacs-lrg-camera-orbit-right ()
  "Orbit the 3D camera right around the panels."
  (interactive) (cmacs-lrg-3d-camera "orbit-right"))

;;;###autoload
(defun cmacs-lrg-camera-orbit-up ()
  "Orbit the 3D camera up around the panels."
  (interactive) (cmacs-lrg-3d-camera "orbit-up"))

;;;###autoload
(defun cmacs-lrg-camera-orbit-down ()
  "Orbit the 3D camera down around the panels."
  (interactive) (cmacs-lrg-3d-camera "orbit-down"))

;;;###autoload
(defun cmacs-lrg-focus-window ()
  "Bring the selected window's 3D panel front-and-centre (fly the camera to it).
The keyboard/command equivalent of Ctrl+double-left-click on a panel."
  (interactive)
  (if (and (fboundp 'cmacs-lrg-3d-focus-panel)
           (cmacs-lrg-3d-focus-panel (selected-window)))
      (message "lrg 3D: focused %s front-and-centre" (buffer-name))
    (user-error "Not a 3D lrg frame")))

;;;###autoload
(defun cmacs-lrg-maximize-window ()
  "Maximize the selected window's 3D panel to a flat, 2D-like view.
Frames it head-on and level (0-degree tilt), filling the viewport edge-to-edge —
the same view the 2D backend / PGTK would show, but inside the 3D scene.  Return
to the 3D view with \\[cmacs-lrg-camera-reset]."
  (interactive)
  (if (and (fboundp 'cmacs-lrg-3d-maximize-window)
           (cmacs-lrg-3d-maximize-window))
      (message "lrg: 2D view -- %s maximized (%s to return to 3D)"
               (buffer-name)
               (substitute-command-keys "\\[cmacs-lrg-camera-reset]"))
    (user-error "Not a 3D lrg frame")))

;;;###autoload
(defun cmacs-lrg-pin-window ()
  "Pin the selected window's 3D panel where it is (manual placement).
A pinned panel keeps its place across re-layouts, resizes and arrangement
switches until unpinned (see `cmacs-lrg-unpin-window')."
  (interactive)
  (if (and (fboundp 'cmacs-lrg-3d-pin-panel)
           (cmacs-lrg-3d-pin-panel (selected-window)))
      (message "lrg 3D: pinned %s" (buffer-name))
    (user-error "Not a 3D lrg frame")))

;;;###autoload
(defun cmacs-lrg-unpin-window ()
  "Release the selected window's 3D panel back to automatic layout."
  (interactive)
  (if (and (fboundp 'cmacs-lrg-3d-unpin-panel)
           (cmacs-lrg-3d-unpin-panel (selected-window)))
      (message "lrg 3D: unpinned %s" (buffer-name))
    (user-error "Not a 3D lrg frame")))

;;;###autoload
(defun cmacs-lrg-unpin-all ()
  "Release every 3D panel back to automatic layout."
  (interactive)
  (if (and (fboundp 'cmacs-lrg-3d-unpin-panel)
           (cmacs-lrg-3d-unpin-panel t))
      (message "lrg 3D: all panels released to automatic layout")
    (user-error "Not a 3D lrg frame")))

;;;###autoload
(defun cmacs-lrg-place-wall (buffer)
  "Show BUFFER's libregnum 3D view on the cockpit back wall.
BUFFER must have a live libregnum view (a gnuseye / gobject-graph / editor / CAD
buffer); switches the environment to \"cockpit\" so the wall is visible."
  (interactive "bBuffer with a 3D view (gnuseye/gobject/editor): ")
  (when (fboundp 'cmacs-lrg-3d-set-environment)
    (cmacs-lrg-3d-set-environment "cockpit"))
  (if (and (fboundp 'cmacs-lrg-3d-set-wall)
           (cmacs-lrg-3d-set-wall (get-buffer buffer)))
      (message "lrg cockpit wall: %s" buffer)
    (user-error "Could not set the cockpit wall to %s" buffer)))

;;;###autoload
(defun cmacs-lrg-clear-wall ()
  "Clear the cockpit back wall."
  (interactive)
  (when (fboundp 'cmacs-lrg-3d-set-wall)
    (cmacs-lrg-3d-set-wall nil))
  (message "lrg cockpit wall cleared"))

(defvar cmacs-lrg-3d-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c 3 a") #'cmacs-lrg-set-arrangement)
    (define-key map (kbd "C-c 3 e") #'cmacs-lrg-set-environment)
    (define-key map (kbd "C-c 3 ?") #'cmacs-lrg-3d-describe)
    (define-key map (kbd "C-c 3 0") #'cmacs-lrg-camera-reset)
    (define-key map (kbd "C-c 3 +") #'cmacs-lrg-camera-zoom-in)
    (define-key map (kbd "C-c 3 =") #'cmacs-lrg-camera-zoom-in)
    (define-key map (kbd "C-c 3 -") #'cmacs-lrg-camera-zoom-out)
    (define-key map (kbd "C-c 3 <left>")  #'cmacs-lrg-camera-orbit-left)
    (define-key map (kbd "C-c 3 <right>") #'cmacs-lrg-camera-orbit-right)
    (define-key map (kbd "C-c 3 <up>")    #'cmacs-lrg-camera-orbit-up)
    (define-key map (kbd "C-c 3 <down>")  #'cmacs-lrg-camera-orbit-down)
    (define-key map (kbd "C-c 3 f") #'cmacs-lrg-focus-window)
    (define-key map (kbd "C-c 3 2") #'cmacs-lrg-maximize-window)
    (define-key map (kbd "C-c 3 p") #'cmacs-lrg-pin-window)
    (define-key map (kbd "C-c 3 u") #'cmacs-lrg-unpin-window)
    (define-key map (kbd "C-c 3 U") #'cmacs-lrg-unpin-all)
    (define-key map (kbd "C-c 3 w") #'cmacs-lrg-place-wall)
    (define-key map (kbd "C-c 3 W") #'cmacs-lrg-clear-wall)
    ;; Spatial workspaces (the 3D workspace carousel); commands live in
    ;; cmacs-lrg-3d-workspaces.el (loaded below) and no-op without persp-mode.
    (define-key map (kbd "C-c 3 m")   #'cmacs-lrg-3d-workspaces-mode)
    (define-key map (kbd "C-c 3 SPC") #'cmacs-lrg-3d-workspaces-toggle)
    (define-key map (kbd "C-c 3 o")   #'cmacs-lrg-3d-workspaces-overview)
    (define-key map (kbd "C-c 3 r")   #'cmacs-lrg-3d-workspaces-rotate)
    (define-key map (kbd "C-c 3 g")   #'cmacs-lrg-3d-workspaces-refresh)
    map)
  "Keymap for `cmacs-lrg-3d-mode'.")

;;;###autoload
(define-minor-mode cmacs-lrg-3d-mode
  "Global minor mode for the lrg 3D backend.
Enables the `C-c 3' command keymap and (when
`cmacs-lrg-3d-follow-selected-window' is non-nil) depth-of-field focus that
follows the selected window."
  :global t
  :group 'cmacs-lrg-3d
  :keymap cmacs-lrg-3d-mode-map
  (if cmacs-lrg-3d-mode
      (add-hook 'window-selection-change-functions
                #'cmacs-lrg-3d--track-selected-window)
    (remove-hook 'window-selection-change-functions
                 #'cmacs-lrg-3d--track-selected-window)))

(provide 'cmacs-lrg-3d)

;; Spatial 3D workspace switcher (Doom / persp-mode workspaces as a live carousel
;; in 3D).  Loaded after `provide' above so its own `(require 'cmacs-lrg-3d)' is
;; already satisfied (no recursive require).  Soft dependency: no-ops without
;; persp-mode or off a 3D lrg frame.
(require 'cmacs-lrg-3d-workspaces nil t)

;;; cmacs-lrg-3d.el ends here
