;;; cmacs-handtrack-tests.el --- Tests for camera hand tracking -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; No camera and no model needed for most of this: the pipeline's
;; arithmetic is driven with synthetic tensors (anchors, box decoding
;; and NMS, the letterbox, regions of interest), the landmark mapping
;; with landmarks projected from libregnum's synthetic hand (so mapping
;; them back must recover it), and the gestures by running those
;; landmarks through the same classifier VR hands use.  The networks
;; themselves need onnxruntime in the build and the models installed;
;; those tests skip without them, and nothing here downloads anything.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)

(defun cmacs-handtrack-tests--built-p ()
  (fboundp 'cmacs-handtrack--map))

(defun cmacs-handtrack-tests--near (a b &optional eps)
  (< (abs (- a b)) (or eps 1e-3)))

(defun cmacs-handtrack-tests--hand (side pinch &optional palm-up x y)
  "Synthetic landmarks: SIDE hand, PINCH metres, wrist at X Y."
  (cmacs-handtrack--synthetic-landmarks side pinch palm-up
                                        (or x (if (eq side 'left) -0.1 0.1))
                                        (or y -0.1)))

(ert-deftest cmacs-handtrack-feature-flag-matches-the-build ()
  "IS-CMACS-HANDTRACK is always bound and agrees with the primitives."
  (should (boundp 'IS-CMACS-HANDTRACK))
  (should (boundp 'is-cmacs-handtrack))
  (should (eq (and IS-CMACS-HANDTRACK t)
              (and (cmacs-handtrack-tests--built-p) t)))
  (when IS-CMACS-HANDTRACK
    (should (memq 'handtrack (cmacs-compiled-features)))
    (should (booleanp (cmacs-handtrack-available-p)))))

;;;; The palm detector's arithmetic

(ert-deftest cmacs-handtrack-anchors ()
  "2016 anchors: a 24x24 grid of 2, then a 12x12 grid of 6, cell-centred."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (let ((a (cmacs-handtrack--anchors)))
    (should (= (length a) 2016))
    (should (cmacs-handtrack-tests--near (car (aref a 0)) (/ 0.5 24)))
    (should (cmacs-handtrack-tests--near (car (aref a 1)) (/ 0.5 24)))
    (should (cmacs-handtrack-tests--near (car (aref a 2)) (/ 1.5 24)))
    (should (cmacs-handtrack-tests--near (car (aref a 1152)) (/ 0.5 12)))
    (should (cmacs-handtrack-tests--near (cdr (aref a 2015)) (/ 11.5 12)))))

(defun cmacs-handtrack-tests--palm-tensors (anchors)
  "Raw detector output with one palm, at ANCHORS (an alist index . logit)."
  (let ((boxes (make-vector (* 2016 18) 0.0))
        (scores (make-vector 2016 -10.0)))
    (pcase-dolist (`(,i . ,logit) anchors)
      (aset scores i logit)
      (aset boxes (+ (* i 18) 2) 38.4)          ; 0.2 of the 192 input
      (aset boxes (+ (* i 18) 3) 38.4)
      (aset boxes (+ (* i 18) 5) 19.2)          ; wrist below the centre
      (aset boxes (+ (* i 18) 9) -19.2))        ; middle knuckle above
    (cons boxes scores)))

(ert-deftest cmacs-handtrack-decode-and-nms ()
  "A palm decodes into image coordinates; duplicates merge into one."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (pcase-let* ((`(,boxes . ,scores)
                (cmacs-handtrack-tests--palm-tensors '((300 . 5.0) (301 . 4.0))))
               (palms (cmacs-handtrack--decode boxes scores 640 480)))
    (should (= (length palms) 1))
    (pcase-let ((`(,cx ,cy ,w ,h ,score ,wrist ,middle) (car palms)))
      ;; Anchor 300 is cell (6, 6) of the 24x24 grid; 640x480 letterboxes
      ;; at scale 0.3 with 24 px bands top and bottom.
      (should (cmacs-handtrack-tests--near cx (/ 6.5 24)))
      (should (cmacs-handtrack-tests--near cy (/ (- (* (/ 6.5 24) 192) 24) 0.3 480)))
      (should (cmacs-handtrack-tests--near w 0.2))
      (should (cmacs-handtrack-tests--near h (/ 38.4 0.3 480)))
      (should (cmacs-handtrack-tests--near score (/ 1 (+ 1 (exp -5.0)))))
      (should (> (cdr wrist) cy))
      (should (< (cdr middle) cy))))
  ;; Below threshold: nothing.
  (pcase-let ((`(,boxes . ,scores)
               (cmacs-handtrack-tests--palm-tensors '((300 . -1.0)))))
    (should-not (cmacs-handtrack--decode boxes scores 640 480)))
  (should-error (cmacs-handtrack--decode [1 2 3] [1] 640 480)))

(ert-deftest cmacs-handtrack-letterbox ()
  "A 4:3 frame fills the square's width; the bands are zero."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (pcase-let ((`(,scale ,padx ,pady ,mean-r ,covered)
               (cmacs-handtrack--letterbox 640 480 255 0 0)))
    (should (cmacs-handtrack-tests--near scale 0.3))
    (should (cmacs-handtrack-tests--near padx 0.0))
    (should (cmacs-handtrack-tests--near pady 24.0))
    (should (cmacs-handtrack-tests--near covered 0.75 0.02))
    (should (cmacs-handtrack-tests--near mean-r 0.75 0.02))))

(ert-deftest cmacs-handtrack-roi-from-palm ()
  "The region is turned to put the fingers up, shifted toward them, 2.6x."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (pcase-let ((`(,cx ,cy ,size ,rot)
               (cmacs-handtrack--roi-from-palm
                '(0.5 0.5 0.2 0.2 0.5 0.6 0.5 0.4) 640 480)))
    (should (cmacs-handtrack-tests--near rot 0.0))
    (should (cmacs-handtrack-tests--near cx 320.0))
    (should (cmacs-handtrack-tests--near cy (- 240.0 48.0)))
    (should (cmacs-handtrack-tests--near size (* 128 2.6))))
  ;; Fingers pointing right: a quarter turn, shifted right.
  (pcase-let ((`(,cx ,_cy ,_size ,rot)
               (cmacs-handtrack--roi-from-palm
                '(0.5 0.5 0.2 0.2 0.4 0.5 0.6 0.5) 640 480)))
    (should (cmacs-handtrack-tests--near rot (/ float-pi 2)))
    (should (> cx 320.0))))

;;;; 21 landmarks -> libregnum's 26 joints

(ert-deftest cmacs-handtrack-mapping-recovers-the-hand ()
  "A synthetic hand projected onto the camera and mapped back is itself."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (dolist (side '(left right))
    (let ((down (cmacs-handtrack--map (cmacs-handtrack-tests--hand side 0.03)
                                      (eq side 'right)))
          (up (cmacs-handtrack--map (cmacs-handtrack-tests--hand side 0.03 t)
                                    (eq side 'right))))
      ;; All 26: 21 mapped, the palm and four metacarpals synthesised.
      (should (= (plist-get down :valid) 26))
      (should (cmacs-handtrack-tests--near (plist-get down :pinch-distance) 0.03
                                           0.002))
      (should-not (plist-get down :palm-up))
      (should (< (nth 1 (plist-get down :palm-normal)) -0.7))
      (should (plist-get up :palm-up))
      (should (> (nth 1 (plist-get up :palm-normal)) 0.7))
      ;; The wrist sits where it was put, in metres.
      (should (cmacs-handtrack-tests--near (car (plist-get down :wrist))
                                           (if (eq side 'left) -0.1 0.1)))))
  ;; A closed pinch latches; an open one does not.
  (should (plist-get (cmacs-handtrack--map (cmacs-handtrack-tests--hand 'right 0.01) t)
                     :pinched))
  (should-not (plist-get (cmacs-handtrack--map (cmacs-handtrack-tests--hand 'right 0.05) t)
                         :pinched)))

(ert-deftest cmacs-handtrack-mapping-is-distance-independent ()
  "A hand twice as far is half as big on camera: its pinch is the same."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (let* ((near (cmacs-handtrack--synthetic-landmarks 'right 0.03 nil 0.1 -0.1 -0.5))
         (far (cmacs-handtrack--synthetic-landmarks 'right 0.03 nil 0.1 -0.1 -0.5))
         (wrist-x (aref far 0)) (wrist-y (aref far 1)))
    ;; Shrink FAR's landmarks about its wrist, as distance would.
    (dotimes (i 21)
      (aset far (* 3 i) (+ wrist-x (* 0.5 (- (aref far (* 3 i)) wrist-x))))
      (aset far (1+ (* 3 i)) (+ wrist-y (* 0.5 (- (aref far (1+ (* 3 i))) wrist-y))))
      (aset far (+ 2 (* 3 i)) (* 0.5 (aref far (+ 2 (* 3 i))))))
    (should (cmacs-handtrack-tests--near
             (plist-get (cmacs-handtrack--map near t) :pinch-distance)
             (plist-get (cmacs-handtrack--map far t) :pinch-distance)
             0.001))))

;;;; The shared gesture classifier, fed by the camera

(ert-deftest cmacs-handtrack-gestures-tap ()
  "A quick pinch is a tap: <hand-right-pinch>."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (should (equal (cmacs-handtrack--simulate
                  (list (list 0 nil (cmacs-handtrack-tests--hand 'right 0.05))
                        (list 50 nil (cmacs-handtrack-tests--hand 'right 0.01))
                        (list 150 nil (cmacs-handtrack-tests--hand 'right 0.05))))
                 '((tap right)))))

(ert-deftest cmacs-handtrack-gestures-palm-up ()
  "A palm held up is one palm-up; turning it back is palm-down."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (should (equal (cmacs-handtrack--simulate
                  (list (list 0 (cmacs-handtrack-tests--hand 'left 0.05 t) nil)
                        (list 200 (cmacs-handtrack-tests--hand 'left 0.05 t) nil)
                        (list 350 (cmacs-handtrack-tests--hand 'left 0.05 t) nil)
                        (list 500 (cmacs-handtrack-tests--hand 'left 0.05) nil)))
                 '((palm-up left) (palm-down left)))))

(ert-deftest cmacs-handtrack-gestures-pull-orbits ()
  "A pinch moved is a pull: the camera hand's travel, in metres."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (let ((acts (cmacs-handtrack--simulate
               (list (list 0 nil (cmacs-handtrack-tests--hand 'right 0.01 nil 0.1 -0.1))
                     (list 30 nil (cmacs-handtrack-tests--hand 'right 0.01 nil 0.1 -0.05))
                     (list 60 nil (cmacs-handtrack-tests--hand 'right 0.01 nil 0.1 -0.02))
                     (list 90 nil (cmacs-handtrack-tests--hand 'right 0.05 nil 0.1 -0.02))))))
    (should (equal (mapcar #'car acts) '(pull-begin pull-move pull-end)))
    (should (cmacs-handtrack-tests--near (nth 3 (nth 1 acts)) 0.03 0.002))))

(ert-deftest cmacs-handtrack-gestures-two-hand-zoom ()
  "Both hands pinching and drawing apart zoom in."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (let* ((h (lambda (side x pinch)
              (cmacs-handtrack-tests--hand side pinch nil x -0.1)))
         (acts (cmacs-handtrack--simulate
                (list (list 0 (funcall h 'left -0.1 0.01) (funcall h 'right 0.1 0.05))
                      (list 10 (funcall h 'left -0.1 0.01) (funcall h 'right 0.1 0.01))
                      (list 20 (funcall h 'left -0.1 0.01) (funcall h 'right 0.1 0.01))
                      (list 50 (funcall h 'left -0.2 0.01) (funcall h 'right 0.2 0.01))
                      (list 90 (funcall h 'left -0.2 0.05) (funcall h 'right 0.2 0.01))))))
    (should (equal (mapcar #'car acts) '(zoom-begin zoom zoom-end)))
    (should (> (nth 2 (nth 2 acts)) 1.5))))

;;;; The Lisp side and the networks

(ert-deftest cmacs-handtrack-events-are-named ()
  "Gesture keystrokes translate to <hand-...>, each bound."
  (skip-unless (and (cmacs-handtrack-tests--built-p)
                    (require 'cmacs-handtrack nil t)))
  (let ((function-key-map (make-sparse-keymap))
        (codes (cmacs-handtrack-event-codes)))
    (should (= (length codes) 8))
    (cmacs-handtrack--install-translations)
    (pcase-dolist (`(,name . ,code) codes)
      (should (equal (lookup-key function-key-map
                                 (vector (intern (format "key-%d" code))))
                     (vector name)))
      (should (commandp (lookup-key cmacs-handtrack-mode-map (vector name)))))))

(ert-deftest cmacs-handtrack-options-and-target ()
  "Options validate; targets are auto, none or a buffer."
  (skip-unless (cmacs-handtrack-tests--built-p))
  (should (= (cmacs-handtrack-set-option 'orbit-gain 2500) 2500))
  (should-error (cmacs-handtrack-set-option 'palm-threshold 2)
                :type 'args-out-of-range)
  (should-error (cmacs-handtrack-set-option 'no-such 1))
  (should (eq (cmacs-handtrack-set-target 'none) 'none))
  (should-error (cmacs-handtrack-set-target 'sideways)
                :type 'wrong-type-argument)
  (should (eq (cmacs-handtrack-set-target 'auto) 'auto)))

(ert-deftest cmacs-handtrack-without-onnxruntime-says-so ()
  "A build without onnxruntime refuses to open, clearly."
  (skip-unless (and (cmacs-handtrack-tests--built-p)
                    (not (cmacs-handtrack-available-p))))
  (should-error (cmacs-handtrack-open "/nonexistent/palm.onnx"
                                      "/nonexistent/hand.onnx"))
  (should-not (plist-get (cmacs-handtrack-status) :running)))

(ert-deftest cmacs-handtrack-mode-refuses-without-models ()
  "The mode refuses (models or onnxruntime missing) and leaves no camera open."
  (skip-unless (and (cmacs-handtrack-tests--built-p)
                    (require 'cmacs-handtrack nil t)))
  (let ((cmacs-handtrack-models-search-path
         (list (make-temp-name (expand-file-name "cmacs-ht-none-"
                                                 temporary-file-directory))))
        (cmacs-camera-gowl-toast nil))
    (should-error (cmacs-handtrack-mode 1) :type 'user-error)
    (should-not cmacs-handtrack-mode)
    (should-not (cmacs-camera-open-p))))

(ert-deftest cmacs-handtrack-real-models-on-test-video ()
  "With onnxruntime and the models, inference runs on videotestsrc frames."
  (skip-unless (and (cmacs-handtrack-tests--built-p)
                    (require 'cmacs-handtrack nil t)
                    (cmacs-handtrack-available-p)
                    (cmacs-handtrack-models-present-p)))
  (unwind-protect
      (progn
        (cmacs-camera-open "test" 320 240 15)
        (cmacs-handtrack-open
         (cmacs-handtrack-model-path cmacs-handtrack-palm-model)
         (cmacs-handtrack-model-path cmacs-handtrack-landmark-model))
        (let ((deadline (+ (float-time) 20)))
          (while (and (< (plist-get (cmacs-handtrack-status) :results) 3)
                      (< (float-time) deadline))
            (accept-process-output nil 0.05)))
        (should (>= (plist-get (cmacs-handtrack-status) :results) 3)))
    (cmacs-handtrack-close)
    (cmacs-camera-close)))

(provide 'cmacs-handtrack-tests)

;;; cmacs-handtrack-tests.el ends here
