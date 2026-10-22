;;; cmacs-handtrack.el --- Camera hand tracking for cmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Hands seen by a desktop camera, as gestures.  MediaPipe's two
;; networks -- a palm detector and a hand landmark model, in their ONNX
;; conversions (Apache-2.0) -- run through onnxruntime on a thread of
;; their own; each result becomes the same libregnum hand a VR headset
;; reports, and goes through the same pinch latch and the same gesture
;; classifier as headset hands do.  Continuous gestures act in C at the
;; camera's frame rate:
;;
;;   pinch and move       orbit the libregnum scene in the selected window
;;                        (roamgraph, the second brain, gnuseye, ...)
;;   both hands, stretch  zoom it
;;
;; and the discrete ones are events, bound in `cmacs-handtrack-mode-map':
;;
;;   <hand-left-pinch>      <hand-right-pinch>       a quick pinch
;;   <hand-left-palm-up>    <hand-right-palm-up>     palm turned up
;;   <hand-left-palm-down>  <hand-right-palm-down>   ... and back
;;   <hand-zoom-in>         <hand-zoom-out>          a stretch ended
;;
;; Models are not shipped and never fetched behind your back:
;; \\[cmacs-handtrack-download-models] puts them in
;; `cmacs-handtrack-models-directory' when you ask.  The camera opens
;; with `cmacs-handtrack-mode' and closes with it (cmacs-camera.el's
;; indicator shows while it is open).

;;; Code:

(require 'cl-lib)
(require 'cmacs-camera)

(declare-function cmacs-handtrack-available-p "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-open "cmacs-handtrack-defuns.c"
                  (palm-model landmark-model &optional threads mirror))
(declare-function cmacs-handtrack-close "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-status "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-hands "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-set-target "cmacs-handtrack-defuns.c" (target))
(declare-function cmacs-handtrack-set-option "cmacs-handtrack-defuns.c"
                  (key value))
(declare-function cmacs-handtrack-event-codes "cmacs-handtrack-defuns.c")

(defgroup cmacs-handtrack nil
  "Camera hand tracking (MediaPipe models on onnxruntime)."
  :group 'cmacs
  :prefix "cmacs-handtrack-")

(defun cmacs-handtrack--set (key)
  "A :set function that also pushes the value to C option KEY."
  (lambda (sym value)
    (set-default-toplevel-value sym value)
    (when (fboundp 'cmacs-handtrack-set-option)
      (cmacs-handtrack-set-option key value))))

(defcustom cmacs-handtrack-models-directory
  (expand-file-name ".local/share/cmacs/handtrack-models/" "~")
  "Where `cmacs-handtrack-download-models' writes the models."
  :type 'directory)

(defcustom cmacs-handtrack-models-search-path
  (list cmacs-handtrack-models-directory
        "/usr/share/cmacs/handtrack-models/")
  "Directories searched for the model files, earliest first."
  :type '(repeat directory))

(defcustom cmacs-handtrack-palm-model "palm_detection_mediapipe_2023feb.onnx"
  "The palm detector: MediaPipe's palm detection, ONNX, 192 x 192 input."
  :type 'string)

(defcustom cmacs-handtrack-landmark-model
  "handpose_estimation_mediapipe_2023feb.onnx"
  "The hand landmark model: MediaPipe's, ONNX, 224 x 224 input."
  :type 'string)

(defcustom cmacs-handtrack-download-base-urls
  '(("palm_detection_mediapipe_2023feb.onnx"
     . "https://huggingface.co/opencv/palm_detection_mediapipe/resolve/main/")
    ("handpose_estimation_mediapipe_2023feb.onnx"
     . "https://huggingface.co/opencv/handpose_estimation_mediapipe/resolve/main/"))
  "Where `cmacs-handtrack-download-models' fetches each model from.
The defaults are OpenCV Zoo's conversions of MediaPipe's models
\(Apache-2.0)."
  :type '(alist :key-type string :value-type string))

(defcustom cmacs-handtrack-threads 2
  "onnxruntime threads per network."
  :type 'natnum)

(defcustom cmacs-handtrack-mirror t
  "Non-nil: the networks see the mirrored (selfie) image.
MediaPipe's left/right labels and this package's user-space mapping
assume it; turn it off only for a camera that already mirrors."
  :type 'boolean)

(defcustom cmacs-handtrack-swap-hands nil
  "Non-nil: take the model's left hand for the right, and the reverse."
  :type 'boolean
  :set (cmacs-handtrack--set 'swap-hands))

(defcustom cmacs-handtrack-palm-threshold 0.5
  "Palm detector score a palm needs (0..1)."
  :type 'number
  :set (cmacs-handtrack--set 'palm-threshold))

(defcustom cmacs-handtrack-presence-threshold 0.5
  "Landmark model's hand score a tracked hand needs to stay (0..1)."
  :type 'number
  :set (cmacs-handtrack--set 'presence-threshold))

(defcustom cmacs-handtrack-orbit-gain 2500
  "How far a pinch-drag turns the scene: mouse-drag pixels per metre."
  :type 'number
  :set (cmacs-handtrack--set 'orbit-gain))

(defcustom cmacs-handtrack-zoom-gain 9.5
  "How far a two-hand stretch zooms: wheel ticks per e-fold."
  :type 'number
  :set (cmacs-handtrack--set 'zoom-gain))

(defcustom cmacs-handtrack-target 'auto
  "What a pinch-drag orbits and a stretch zooms.
`auto' is the libregnum scene in the selected window; `none' leaves
scenes alone (events still arrive)."
  :type '(choice (const auto) (const none))
  :set (lambda (sym value)
         (set-default-toplevel-value sym value)
         (when (fboundp 'cmacs-handtrack-set-target)
           (cmacs-handtrack-set-target value))))

(defun cmacs-handtrack-built-p ()
  "Return non-nil when this build has hand tracking."
  (fboundp 'cmacs-handtrack-open))

(defun cmacs-handtrack-model-path (name)
  "The first file NAME along `cmacs-handtrack-models-search-path', or nil."
  (cl-some (lambda (dir)
             (let ((p (expand-file-name name dir)))
               (and (file-readable-p p) p)))
           cmacs-handtrack-models-search-path))

(defun cmacs-handtrack-models-present-p ()
  "Return non-nil when both models are installed."
  (and (cmacs-handtrack-model-path cmacs-handtrack-palm-model)
       (cmacs-handtrack-model-path cmacs-handtrack-landmark-model)))

;;;###autoload
(defun cmacs-handtrack-download-models ()
  "Download the two models into `cmacs-handtrack-models-directory'.
Only ever run by you: nothing in cmacs fetches a model by itself."
  (interactive)
  (make-directory cmacs-handtrack-models-directory t)
  (dolist (name (list cmacs-handtrack-palm-model
                      cmacs-handtrack-landmark-model))
    (let ((base (cdr (assoc name cmacs-handtrack-download-base-urls)))
          (dest (expand-file-name name cmacs-handtrack-models-directory)))
      (unless base
        (user-error "No download URL for %s in `cmacs-handtrack-download-base-urls'"
                    name))
      (unless (file-exists-p dest)
        (message "cmacs-handtrack: downloading %s%s ..." base name)
        (url-copy-file (concat base name) dest))))
  (message "cmacs-handtrack: models in %s" cmacs-handtrack-models-directory))

(defun cmacs-handtrack--install-translations ()
  "Name the gesture keystrokes: `key-CODE' becomes <hand-...>."
  (pcase-dolist (`(,name . ,code) (cmacs-handtrack-event-codes))
    (define-key function-key-map (vector (intern (format "key-%d" code)))
                (vector name))))

(defun cmacs-handtrack--apply-options ()
  (when (fboundp 'cmacs-handtrack-set-option)
    (cmacs-handtrack-set-option 'swap-hands cmacs-handtrack-swap-hands)
    (cmacs-handtrack-set-option 'palm-threshold cmacs-handtrack-palm-threshold)
    (cmacs-handtrack-set-option 'presence-threshold
                                cmacs-handtrack-presence-threshold)
    (cmacs-handtrack-set-option 'orbit-gain cmacs-handtrack-orbit-gain)
    (cmacs-handtrack-set-option 'zoom-gain cmacs-handtrack-zoom-gain)
    (cmacs-handtrack-set-target cmacs-handtrack-target)))

;;;###autoload
(defun cmacs-handtrack-describe ()
  "Say whether hands are tracked, and how fast."
  (interactive)
  (if (not (cmacs-handtrack-built-p))
      (message "This build has no hand tracking (--with-cmacs-handtrack)")
    (let ((st (cmacs-handtrack-status)))
      (message "Hands: %s; %d frames, %d hands now, %.1f ms; %s"
               (cond ((not (plist-get st :inference))
                      "no onnxruntime in this build")
                     ((plist-get st :running) "tracking")
                     (t "off"))
               (plist-get st :frames) (plist-get st :hands)
               (plist-get st :latency-ms)
               (mapconcat (lambda (h)
                            (format "%s%s%s" (car h)
                                    (if (plist-get (cdr h) :pinched) " pinched" "")
                                    (if (plist-get (cdr h) :palm-up) " palm-up" "")))
                          (cmacs-handtrack-hands) ", ")))))

(defvar-keymap cmacs-handtrack-mode-map
  :doc "Keymap for `cmacs-handtrack-mode': the camera's hand gestures."
  "<hand-left-palm-up>"    #'cmacs-handtrack-describe
  "<hand-right-palm-up>"   #'ignore
  "<hand-left-palm-down>"  #'ignore
  "<hand-right-palm-down>" #'ignore
  "<hand-left-pinch>"      #'ignore
  "<hand-right-pinch>"     #'ignore
  "<hand-zoom-in>"         #'ignore
  "<hand-zoom-out>"        #'ignore)

;;;###autoload
(define-minor-mode cmacs-handtrack-mode
  "Track hands with the camera, as gestures.
Opens the camera (its indicator shows) and runs MediaPipe's hand models
on onnxruntime.  Needs the models: \\[cmacs-handtrack-download-models]."
  :global t
  :keymap cmacs-handtrack-mode-map
  :group 'cmacs-handtrack
  (cond
   ((not cmacs-handtrack-mode)
    (when (cmacs-handtrack-built-p)
      (cmacs-handtrack-close))
    (when (fboundp 'cmacs-camera-release)
      (cmacs-camera-release 'cmacs-handtrack)))
   ((not (cmacs-handtrack-built-p))
    (setq cmacs-handtrack-mode nil)
    (user-error "This build has no hand tracking (--with-cmacs-handtrack)"))
   ((not (cmacs-handtrack-available-p))
    (setq cmacs-handtrack-mode nil)
    (user-error "This build has no onnxruntime; install onnxruntime-devel and reconfigure"))
   ((not (cmacs-handtrack-models-present-p))
    (setq cmacs-handtrack-mode nil)
    (user-error "No hand models in %s; M-x cmacs-handtrack-download-models"
                (car cmacs-handtrack-models-search-path)))
   (t
    (cmacs-handtrack--install-translations)
    (cmacs-handtrack--apply-options)
    (cmacs-camera-acquire 'cmacs-handtrack)
    (condition-case err
        (cmacs-handtrack-open
         (cmacs-handtrack-model-path cmacs-handtrack-palm-model)
         (cmacs-handtrack-model-path cmacs-handtrack-landmark-model)
         cmacs-handtrack-threads
         (if cmacs-handtrack-mirror t 'no))
      (error
       (setq cmacs-handtrack-mode nil)
       (cmacs-camera-release 'cmacs-handtrack)
       (signal (car err) (cdr err)))))))

(provide 'cmacs-handtrack)

;;; cmacs-handtrack.el ends here
