;;; cmacs-camera.el --- Camera capture for cmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A camera as a frame source for cmacs: GStreamer (PipeWire's camera,
;; else a V4L2 node, else -- inside a Flatpak -- the xdg-desktop-portal
;; Camera) into memory, on a worker thread.  Hand tracking
;; (cmacs-handtrack.el) is its main consumer.
;;
;; Privacy, deliberately:
;;
;;   - off until `cmacs-camera-start' (or a feature you start that
;;     calls it); nothing in cmacs opens a camera on its own;
;;   - frames stay in memory: nothing is ever written to disk;
;;   - while it is open the mode line says so (`cmacs-camera-indicator')
;;     and, under gowl, a bar toast says it opened and closed;
;;   - `cmacs-camera-stop' releases the device before it returns, so the
;;     camera's own light goes out with it.
;;
;;   M-x cmacs-camera-start     open (prompts for a device with C-u)
;;   M-x cmacs-camera-stop      close
;;   M-x cmacs-camera-preview   what it sees, in a buffer
;;   M-x cmacs-camera-describe  what is open

;;; Code:

(require 'cl-lib)

(declare-function cmacs-camera-open "cmacs-camera-defuns.c"
                  (&optional spec width height fps))
(declare-function cmacs-camera-close "cmacs-camera-defuns.c")
(declare-function cmacs-camera-status "cmacs-camera-defuns.c")
(declare-function cmacs-camera-devices "cmacs-camera-defuns.c")
(declare-function cmacs-camera-frame-ppm "cmacs-camera-defuns.c"
                  (&optional max-width))
(declare-function gowl-bar-notify "cmacs-gowl.c" (summary &optional body panel))

(defgroup cmacs-camera nil
  "Camera capture (GStreamer) for cmacs."
  :group 'cmacs
  :prefix "cmacs-camera-")

(defcustom cmacs-camera-device nil
  "The camera `cmacs-camera-start' opens.
nil is the first one found: PipeWire's, else a V4L2 node, else (inside a
Flatpak) the xdg-desktop-portal Camera.  A string is a spec
`cmacs-camera-open' takes: \"/dev/video0\", \"pipewire:SERIAL\", \"portal\",
\"test\", or part of a name from `cmacs-camera-devices'."
  :type '(choice (const :tag "First found" nil) string))

(defcustom cmacs-camera-width 640
  "Frame width delivered to consumers, pixels."
  :type 'natnum)

(defcustom cmacs-camera-height 480
  "Frame height delivered to consumers, pixels."
  :type 'natnum)

(defcustom cmacs-camera-fps 30
  "Frames per second delivered to consumers."
  :type 'natnum)

(defcustom cmacs-camera-indicator
  (propertize " ●CAM" 'face '(:foreground "red" :weight bold)
              'help-echo "The camera is open: M-x cmacs-camera-stop")
  "Shown in the mode line while the camera is open."
  :type 'string)

(defcustom cmacs-camera-gowl-toast t
  "Non-nil: under gowl, a bar toast when the camera opens and closes."
  :type 'boolean)

(defcustom cmacs-camera-preview-fps 10
  "Refresh rate of `cmacs-camera-preview'."
  :type 'natnum)

(defcustom cmacs-camera-preview-width 480
  "Width of `cmacs-camera-preview''s image, pixels."
  :type 'natnum)

(defvar cmacs-camera--watch nil
  "Timer keeping the indicator true while the camera is open.")

(defvar cmacs-camera--users nil
  "Features holding the camera open (symbols); see `cmacs-camera-acquire'.")

(defun cmacs-camera-available-p ()
  "Return non-nil when this build has camera support."
  (fboundp 'cmacs-camera-open))

(defun cmacs-camera-open-p ()
  "Return non-nil while the camera is open (or a portal is asking)."
  (and (cmacs-camera-available-p)
       (let ((st (cmacs-camera-status)))
         (or (plist-get st :open) (plist-get st :pending)))))

(defun cmacs-camera--toast (summary)
  "Tell the gowl bar SUMMARY, if a compositor runs here."
  (when (and cmacs-camera-gowl-toast (fboundp 'gowl-bar-notify))
    (ignore-errors (gowl-bar-notify summary))))

(defun cmacs-camera--indicate (on)
  "Show or hide the mode-line indicator; keep it honest while ON."
  (setq global-mode-string
        (delq 'cmacs-camera-indicator
              (if (listp global-mode-string)
                  global-mode-string
                (list global-mode-string))))
  (when on
    (setq global-mode-string
          (append (or global-mode-string '("")) '(cmacs-camera-indicator))))
  (when cmacs-camera--watch
    (cancel-timer cmacs-camera--watch)
    (setq cmacs-camera--watch nil))
  ;; The camera can stop by itself (unplugged, taken by another
  ;; program); the indicator must not outlive it.
  (when on
    (setq cmacs-camera--watch
          (run-with-timer 1 1 #'cmacs-camera--check)))
  (force-mode-line-update t))

(defun cmacs-camera--check ()
  "Drop the indicator once the camera has closed on its own."
  (unless (cmacs-camera-open-p)
    (setq cmacs-camera--users nil)
    (cmacs-camera--indicate nil)
    (let ((err (plist-get (cmacs-camera-status) :error)))
      (when err
        (message "Camera closed: %s" err)))))

;;;###autoload
(defun cmacs-camera-start (&optional device)
  "Open the camera: DEVICE, else `cmacs-camera-device'.
With a prefix argument, choose from `cmacs-camera-devices'."
  (interactive
   (list (when current-prefix-arg
           (let* ((devs (cmacs-camera-devices))
                  (names (mapcar (lambda (d) (format "%s  [%s]" (car d) (nth 1 d)))
                                 devs))
                  (pick (completing-read "Camera: " names nil t)))
             (nth 2 (nth (cl-position pick names :test #'equal) devs))))))
  (unless (cmacs-camera-available-p)
    (user-error "This build has no camera support (--with-cmacs-camera)"))
  (let ((r (cmacs-camera-open (or device cmacs-camera-device)
                              cmacs-camera-width cmacs-camera-height
                              cmacs-camera-fps)))
    (cmacs-camera--indicate t)
    (cmacs-camera--toast "Camera on")
    (when (called-interactively-p 'interactive)
      (message (if (eq r 'pending) "Camera: waiting for permission"
                 "Camera on: %s")
               (plist-get (cmacs-camera-status) :source)))
    r))

;;;###autoload
(defun cmacs-camera-stop ()
  "Close the camera; it is released before this returns."
  (interactive)
  (when (cmacs-camera-available-p)
    (let ((was (cmacs-camera-open-p)))
      (cmacs-camera-close)
      (setq cmacs-camera--users nil)
      (cmacs-camera--indicate nil)
      (when was
        (cmacs-camera--toast "Camera off"))
      (when (called-interactively-p 'interactive)
        (message "Camera off")))))

(defun cmacs-camera-acquire (user)
  "Open the camera for USER (a symbol) unless it already is open.
Features that need frames call this; `cmacs-camera-release' with the
same USER closes it again once nobody holds it."
  (unless (cmacs-camera-open-p)
    (cmacs-camera-start))
  (cl-pushnew user cmacs-camera--users))

(defun cmacs-camera-release (user)
  "Let go of the camera for USER; close it when nobody else holds it."
  (setq cmacs-camera--users (delq user cmacs-camera--users))
  (unless cmacs-camera--users
    (cmacs-camera-stop)))

;;;###autoload
(defun cmacs-camera-describe ()
  "Say whether the camera is open, and what it is."
  (interactive)
  (if (not (cmacs-camera-available-p))
      (message "This build has no camera support")
    (let ((st (cmacs-camera-status)))
      (message "Camera: %s%s, %d frames%s"
               (cond ((plist-get st :open) "open")
                     ((plist-get st :pending) "waiting for permission")
                     (t "closed"))
               (if (plist-get st :source)
                   (format " (%s, %dx%d)" (plist-get st :source)
                           (plist-get st :width) (plist-get st :height))
                 "")
               (plist-get st :frames)
               (if (plist-get st :error)
                   (format "; last error: %s" (plist-get st :error))
                 "")))))

;;;; Preview

(defvar-local cmacs-camera--preview-timer nil)

(defun cmacs-camera--preview-tick (buf)
  "Redraw BUF's preview from the latest frame, in memory."
  (if (not (buffer-live-p buf))
      nil
    (with-current-buffer buf
      (let ((ppm (and (cmacs-camera-open-p)
                      (cmacs-camera-frame-ppm cmacs-camera-preview-width)))
            (inhibit-read-only t))
        (erase-buffer)
        (if ppm
            (insert-image (create-image ppm 'pbm t))
          (insert "Camera closed.  M-x cmacs-camera-start to open it."))))))

(define-derived-mode cmacs-camera-preview-mode special-mode "Camera"
  "What the camera sees, refreshed from memory."
  (add-hook 'kill-buffer-hook
            (lambda () (when cmacs-camera--preview-timer
                         (cancel-timer cmacs-camera--preview-timer)))
            nil t))

;;;###autoload
(defun cmacs-camera-preview ()
  "Show what the camera sees, opening it if it is closed.
The image is made from the frame in memory (a PPM string): nothing is
written to disk.  Killing the buffer stops the refresh, not the camera."
  (interactive)
  (unless (cmacs-camera-open-p)
    (cmacs-camera-start))
  (let ((buf (get-buffer-create "*cmacs-camera*")))
    (with-current-buffer buf
      (cmacs-camera-preview-mode)
      (when cmacs-camera--preview-timer
        (cancel-timer cmacs-camera--preview-timer))
      (setq cmacs-camera--preview-timer
            (run-with-timer 0 (/ 1.0 (max 1 cmacs-camera-preview-fps))
                            #'cmacs-camera--preview-tick buf)))
    (pop-to-buffer buf)))

(provide 'cmacs-camera)

;;; cmacs-camera.el ends here
