;;; cmacs-handtrack-point-tests.el --- Tests for a bare hand pointing -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The pointing history (cmacs/handtrack/cmacs-handtrack-point-history.c
;; and its DEFUNs in cmacs-handtrack-defuns.c): the pose classifier, the
;; mapping onto an output, the ring read by time, the dwell requirement,
;; and that nothing outlives the tracker.  No camera and no model: hands
;; are built here as MediaPipe landmarks -- a flat hand, wrist down,
;; with each finger straight or folded -- and fed through
;; `cmacs-handtrack--simulate-point', which takes the same path live
;; results do.
;;
;; The C-backed tests are gated on the primitive, never on a feature
;; name.  The source guards and the calibration arithmetic need no C and
;; always run.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)
(require 'cmacs-handtrack)

(declare-function cmacs-handtrack-set-option "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-close "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack--synthetic-landmarks
                  "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack--point-pose "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack--simulate-point "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-point-history-enable
                  "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-point-history-clear
                  "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-point-history-at "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-point-history-status
                  "cmacs-handtrack-defuns.c")
(declare-function cmacs-handtrack-point-history-dwell
                  "cmacs-handtrack-defuns.c")

(defconst cmacs-handtrack-point-tests--this-file
  (or load-file-name buffer-file-name
      (bound-and-true-p byte-compile-current-file)))

(defun cmacs-handtrack-point-tests--built-p ()
  (fboundp 'cmacs-handtrack--simulate-point))

(defun cmacs-handtrack-point-tests--source (relative)
  "The text of source file RELATIVE (from the tree's root), or nil."
  (let* ((here (or cmacs-handtrack-point-tests--this-file
                   (locate-library "cmacs-handtrack-point-tests")))
         (file (and here (expand-file-name
                          relative
                          (expand-file-name "../.." (file-name-directory here))))))
    (and file (file-readable-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (buffer-string)))))

(defun cmacs-handtrack-point-tests--code (text)
  "TEXT with its /* ... */ comments removed."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (search-forward "/*" nil t)
      (let ((beg (- (point) 2)))
        (delete-region beg (or (search-forward "*/" nil t) (point-max)))
        (insert " ")))
    (buffer-string)))

(defun cmacs-handtrack-point-tests--body (code name)
  "The body of C function NAME in CODE: from its name at the start of a
line to the closing brace at the start of one.  Nil when there is none."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (when (re-search-forward (concat "^" (regexp-quote name) " (") nil t)
      (let ((beg (match-beginning 0)))
        (and (re-search-forward "^}" nil t)
             (buffer-substring beg (point)))))))


;;;; Hands

;; The camera plane of cmacs-handtrack.h: an image CMACS_HT_PLANE_W_M
;; wide, 0.75 as tall.  A point X, Y metres from the image centre (+Y
;; up) is at u = 0.5 + X / K, v = 0.5 - Y / (K * 0.75).
(defconst cmacs-handtrack-point-tests--k 0.577)
(defconst cmacs-handtrack-point-tests--geom '(0 0 1920 1080))

;; Knuckles, metres from the wrist, fingers toward +Y.  The middle
;; knuckle is the standard palm's 0.094 m away, so the mapping leaves
;; the hand at this size.
(defconst cmacs-handtrack-point-tests--knuckles
  '((-0.025 . 0.088) (0.0 . 0.094) (0.020 . 0.088) (0.040 . 0.080)))

;; The index fingertip of a straight index finger, from the wrist.
(defconst cmacs-handtrack-point-tests--tip '(-0.025 . 0.163))

(defun cmacs-handtrack-point-tests--finger (knuckle straight)
  "Four joints of a finger from KNUCKLE: STRAIGHT, or folded into the palm."
  (let ((x (car knuckle)) (y (cdr knuckle)))
    (if straight
        (list (cons x y) (cons x (+ y 0.035)) (cons x (+ y 0.058))
              (cons x (+ y 0.075)))
      (list (cons x y) (cons x (+ y 0.025)) (cons x (+ y 0.005))
            (cons x (- y 0.035))))))

(defun cmacs-handtrack-point-tests--hand (pose &optional wx wy scale)
  "Landmarks (63 numbers) of a flat hand in POSE with its wrist at WX, WY.
POSE is `pointing' (index straight, the rest folded), `open', `fist',
`peace' (index and middle straight), `pinch' (open, thumb on the index
tip) or `pinch-folded' (as `pointing', thumb on the index tip).  WX, WY
are metres from the image centre; SCALE shrinks the hand about its
wrist, as moving it away from the camera does."
  (let* ((wx (or wx 0.0)) (wy (or wy -0.1)) (scale (or scale 1.0))
         (straight (pcase pose
                     ((or 'pointing 'pinch-folded) '(t nil nil nil))
                     ((or 'open 'pinch) '(t t t t))
                     ('fist '(nil nil nil nil))
                     ('peace '(t t nil nil))))
         (fingers (cl-mapcan #'cmacs-handtrack-point-tests--finger
                             cmacs-handtrack-point-tests--knuckles straight))
         (index-tip (nth 3 fingers))
         (thumb (list '(-0.030 . 0.020) '(-0.050 . 0.040) '(-0.065 . 0.060)
                      (if (memq pose '(pinch pinch-folded))
                          (cons (- (car index-tip) 0.010) (cdr index-tip))
                        '(-0.080 . 0.075))))
         (points (append (list '(0.0 . 0.0)) thumb fingers))
         (k cmacs-handtrack-point-tests--k)
         (v (make-vector 63 0.0))
         (i 0))
    (dolist (p points)
      (aset v (* 3 i) (+ 0.5 (/ (+ wx (* scale (car p))) k)))
      (aset v (+ 1 (* 3 i)) (- 0.5 (/ (+ wy (* scale (cdr p))) (* k 0.75))))
      (cl-incf i))
    v))

(defun cmacs-handtrack-point-tests--at (fu fv &optional pose)
  "A hand in POSE (default `pointing') whose index tip is at FU, FV of the screen.
With the default active region (0.2 0.2 0.8 0.8)."
  (let* ((k cmacs-handtrack-point-tests--k)
         (u (+ 0.2 (* 0.6 fu)))
         (v (+ 0.2 (* 0.6 fv))))
    (cmacs-handtrack-point-tests--hand
     (or pose 'pointing)
     (- (* (- u 0.5) k) (car cmacs-handtrack-point-tests--tip))
     (- (* (- 0.5 v) k 0.75) (cdr cmacs-handtrack-point-tests--tip)))))

(defun cmacs-handtrack-point-tests--frames (from to hand &optional side)
  "Frames every 33 ms from FROM to TO with HAND as the SIDE (default right) hand."
  (cl-loop for ms from from to to by 33
           collect (if (eq side 'left) (list ms hand nil) (list ms nil hand))))

(defmacro cmacs-handtrack-point-tests--with-ring (&rest body)
  "Run BODY with the ring on and empty, default options; leave it off."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (cmacs-handtrack-point-tests--defaults)
         (cmacs-handtrack-point-history-enable nil)
         (cmacs-handtrack-point-history-enable t)
         ,@body)
     (cmacs-handtrack-point-history-enable nil)
     (cmacs-handtrack-point-tests--defaults)))

(defun cmacs-handtrack-point-tests--defaults ()
  (cmacs-handtrack-set-option 'pointer-region '(0.2 0.2 0.8 0.8))
  (cmacs-handtrack-set-option 'point-hand 'any)
  (cmacs-handtrack-set-option 'point-extend 0.055)
  (cmacs-handtrack-set-option 'point-curl 0.035)
  (cmacs-handtrack-set-option 'point-min-confidence 0.5)
  (cmacs-handtrack-set-option 'point-dwell 120)
  (cmacs-handtrack-set-option 'point-radius 96)
  (cmacs-handtrack-set-option 'point-latency 40)
  (cmacs-handtrack-set-option 'point-min-cutoff 1.2)
  (cmacs-handtrack-set-option 'point-beta 0.02))

(defun cmacs-handtrack-point-tests--near (a b eps)
  (< (abs (- a b)) eps))


;;;; The pose

(ert-deftest cmacs-handtrack-point-pose-table ()
  "Pointing is index out, the rest folded -- not a palm, a fist or a pinch."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--defaults)
  (pcase-dolist (`(,pose . ,pointing)
                 '((pointing . t) (open . nil) (fist . nil) (peace . nil)
                   (pinch . nil) (pinch-folded . nil)))
    (let ((p (cmacs-handtrack--point-pose
              (cmacs-handtrack-point-tests--hand pose) t)))
      (ert-info ((format "pose %s: %S" pose p))
        (should (eq (plist-get p :pointing) pointing))
        (if pointing
            (should (> (plist-get p :confidence) 0.9))
          (should (< (plist-get p :confidence) 0.5))))))
  ;; What it measured: a straight index finger reaches 0.075 m past its
  ;; knuckle; the folded ones fall short of theirs.
  (let ((p (cmacs-handtrack--point-pose
            (cmacs-handtrack-point-tests--hand 'pointing) t)))
    (should (cmacs-handtrack-point-tests--near
             (plist-get p :index-reach) 0.075 0.004))
    (should (< (plist-get p :other-reach) 0.0)))
  ;; Either hand.
  (should (plist-get (cmacs-handtrack--point-pose
                      (cmacs-handtrack-point-tests--hand 'pointing) nil)
                     :pointing)))

(ert-deftest cmacs-handtrack-point-pose-is-distance-independent ()
  "A hand half the size in the image -- twice as far -- reads the same."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--defaults)
  (let ((near (cmacs-handtrack--point-pose
               (cmacs-handtrack-point-tests--hand 'pointing 0.0 -0.1 1.0) t))
        (far (cmacs-handtrack--point-pose
              (cmacs-handtrack-point-tests--hand 'pointing 0.0 -0.1 0.5) t)))
    (should (plist-get far :pointing))
    (should (cmacs-handtrack-point-tests--near (plist-get near :index-reach)
                                               (plist-get far :index-reach)
                                               0.002))
    (should-not (plist-get (cmacs-handtrack--point-pose
                            (cmacs-handtrack-point-tests--hand
                             'open 0.0 -0.1 0.5)
                            t)
                           :pointing))))

(ert-deftest cmacs-handtrack-point-pose-thresholds-are-options ()
  "The thresholds are the options, and a bad one is refused."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (unwind-protect
      (progn
        (cmacs-handtrack-point-tests--defaults)
        ;; Ask for a straighter index finger than a hand has.
        (cmacs-handtrack-set-option 'point-extend 0.12)
        (should-not (plist-get (cmacs-handtrack--point-pose
                                (cmacs-handtrack-point-tests--hand 'pointing) t)
                               :pointing))
        (cmacs-handtrack-set-option 'point-extend 0.055)
        ;; Let the other fingers be straight: an open palm then "points".
        (cmacs-handtrack-set-option 'point-curl 0.15)
        (should (plist-get (cmacs-handtrack--point-pose
                            (cmacs-handtrack-point-tests--hand 'open) t)
                           :pointing))
        (should-error (cmacs-handtrack-set-option 'point-dwell -1))
        (should-error (cmacs-handtrack-set-option 'point-radius 0))
        (should-error (cmacs-handtrack-set-option 'point-min-confidence 2))
        (should-error (cmacs-handtrack-set-option 'point-extend 'far))
        (should-error (cmacs-handtrack-set-option 'point-no-such-thing 1)))
    (cmacs-handtrack-point-tests--defaults)))


;;;; The mapping

(ert-deftest cmacs-handtrack-point-maps-through-the-region ()
  "The fingertip goes through the hand cursor's region onto the output."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (should (> (cmacs-handtrack--simulate-point
                (cmacs-handtrack-point-tests--frames
                 1000 1400 (cmacs-handtrack-point-tests--at 0.25 0.5))
                cmacs-handtrack-point-tests--geom)
               10))
    (let ((r (cmacs-handtrack-point-history-dwell 1000 1400)))
      (should r)
      (should (cmacs-handtrack-point-tests--near (plist-get r :x)
                                                 (* 0.25 1919) 4.0))
      (should (cmacs-handtrack-point-tests--near (plist-get r :y)
                                                 (* 0.5 1079) 4.0))
      (should (cmacs-handtrack-point-tests--near (plist-get r :u) 0.25 0.005))
      (should (cmacs-handtrack-point-tests--near (plist-get r :v) 0.5 0.005))
      (should (eq (plist-get r :hand) 'right))
      (should (eq (plist-get r :layout) t))
      ;; No compositor was asked.
      (should (eql (plist-get r :client-id) 0))
      (should-not (plist-get r :monitor))
      (should (> (plist-get r :confidence) 0.9))))
  ;; An output that is not at the origin.
  (cmacs-handtrack-point-tests--with-ring
    (cmacs-handtrack--simulate-point
     (cmacs-handtrack-point-tests--frames
      0 400 (cmacs-handtrack-point-tests--at 0.5 0.5) 'left)
     '(1920 100 2560 1440))
    (let ((r (cmacs-handtrack-point-history-dwell 0 400)))
      (should (eq (plist-get r :hand) 'left))
      (should (cmacs-handtrack-point-tests--near
               (plist-get r :x) (+ 1920 (* 0.5 2559)) 4.0))
      (should (cmacs-handtrack-point-tests--near
               (plist-get r :y) (+ 100 (* 0.5 1439)) 4.0))))
  ;; A narrower region needs less reach: the same hand lands further out.
  (cmacs-handtrack-point-tests--with-ring
    (let ((hand (cmacs-handtrack-point-tests--at 0.75 0.5)))
      (cmacs-handtrack-set-option 'pointer-region '(0.3 0.2 0.7 0.8))
      (cmacs-handtrack--simulate-point
       (cmacs-handtrack-point-tests--frames 0 400 hand)
       cmacs-handtrack-point-tests--geom)
      (should (> (plist-get (cmacs-handtrack-point-history-dwell 0 400) :u)
                 0.8)))))

(ert-deftest cmacs-handtrack-point-off-screen-is-nothing ()
  "A fingertip well past the region's edge points at nothing."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (should (= 0 (cmacs-handtrack--simulate-point
                  (cmacs-handtrack-point-tests--frames
                   0 400 (cmacs-handtrack-point-tests--at 1.3 0.5))
                  cmacs-handtrack-point-tests--geom)))
    ;; Just past the edge is the edge.
    (should (> (cmacs-handtrack--simulate-point
                (cmacs-handtrack-point-tests--frames
                 1000 1400 (cmacs-handtrack-point-tests--at 1.05 0.5))
                cmacs-handtrack-point-tests--geom)
               0))
    (should (cmacs-handtrack-point-tests--near
             (plist-get (cmacs-handtrack-point-history-dwell 1000 1400) :u)
             1.0 0.001))))


;;;; The ring

(ert-deftest cmacs-handtrack-point-only-pointing-is-noted ()
  "An open palm, a fist and a pinch leave nothing; nor does a ring that is off."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (dolist (pose '(open fist peace pinch))
      (should (= 0 (cmacs-handtrack--simulate-point
                    (cmacs-handtrack-point-tests--frames
                     0 400 (cmacs-handtrack-point-tests--at 0.5 0.5 pose))
                    cmacs-handtrack-point-tests--geom))))
    (should (= 0 (plist-get (cmacs-handtrack-point-history-status) :samples)))
    (should-not (cmacs-handtrack-point-history-dwell 0 400 nil 0)))
  ;; Off: pointing is not noted either.
  (cmacs-handtrack-point-tests--defaults)
  (cmacs-handtrack-point-history-enable nil)
  (should (= 0 (cmacs-handtrack--simulate-point
                (cmacs-handtrack-point-tests--frames
                 0 400 (cmacs-handtrack-point-tests--at 0.5 0.5))
                cmacs-handtrack-point-tests--geom)))
  (should-not (plist-get (cmacs-handtrack-point-history-status) :enabled))
  (should-not (cmacs-handtrack-point-history-at 200)))

(ert-deftest cmacs-handtrack-point-read-by-time ()
  "Two rests, one after the other, are told apart by when they were."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (cmacs-handtrack--simulate-point
     (append (cmacs-handtrack-point-tests--frames
              1000 1400 (cmacs-handtrack-point-tests--at 0.2 0.3))
             ;; The hand drops out of the pose on the way across.
             (cmacs-handtrack-point-tests--frames
              1433 1600 (cmacs-handtrack-point-tests--at 0.5 0.5 'open))
             (cmacs-handtrack-point-tests--frames
              1700 2100 (cmacs-handtrack-point-tests--at 0.8 0.6)))
     cmacs-handtrack-point-tests--geom)
    (let ((first (cmacs-handtrack-point-history-dwell 900 1450))
          (second (cmacs-handtrack-point-history-dwell 1650 2200))
          (both (cmacs-handtrack-point-history-dwell 1300 2200)))
      (should (cmacs-handtrack-point-tests--near (plist-get first :u) 0.2 0.01))
      (should (cmacs-handtrack-point-tests--near (plist-get second :u) 0.8 0.02))
      ;; Asked about both, the one that lasted longer in the window.
      (should (cmacs-handtrack-point-tests--near (plist-get both :u) 0.8 0.02))
      (should (= (plist-get first :time) 1000))
      (should (= (plist-get first :since) 1000))
      (should (>= (plist-get first :duration) 380))
      ;; A window that opens mid-rest: the rest is clipped to it, and
      ;; :since still says when it began.
      (let ((late (cmacs-handtrack-point-history-dwell 1250 1450)))
        (should (>= (plist-get late :time) 1250))
        (should (= (plist-get late :since) 1000))
        (should (< (plist-get late :duration) 200))))
    ;; One instant.
    (should (cmacs-handtrack-point-tests--near
             (plist-get (cmacs-handtrack-point-history-at 1200) :u) 0.2 0.01))
    (should (cmacs-handtrack-point-tests--near
             (plist-get (cmacs-handtrack-point-history-at 2000) :u) 0.8 0.02))
    ;; While the palm was open nobody was pointing -- but a sample is
    ;; good for a quarter of a second, and no longer.
    (should (cmacs-handtrack-point-history-at 1500))
    (should-not (cmacs-handtrack-point-history-at 1680))
    (should-not (cmacs-handtrack-point-history-at 900))
    (should-not (cmacs-handtrack-point-history-at 5000))
    (should-not (cmacs-handtrack-point-history-dwell 3000 4000))))

(ert-deftest cmacs-handtrack-point-dwell-is-required ()
  "A hand passing through is not a referent."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  ;; Two frames of the pose and gone.
  (cmacs-handtrack-point-tests--with-ring
    (should (= 2 (cmacs-handtrack--simulate-point
                  (cmacs-handtrack-point-tests--frames
                   1000 1033 (cmacs-handtrack-point-tests--at 0.5 0.5))
                  cmacs-handtrack-point-tests--geom)))
    (should-not (cmacs-handtrack-point-history-dwell 800 1300))
    ;; The requirement is the option, and an argument.
    (should (cmacs-handtrack-point-history-dwell 800 1300 nil 0))
    (cmacs-handtrack-set-option 'point-dwell 20)
    (should (cmacs-handtrack-point-history-dwell 800 1300)))
  ;; Sweeping across the screen in the pose (a hundred pixels a frame):
  ;; it rests nowhere.
  (cmacs-handtrack-point-tests--with-ring
    (cmacs-handtrack-set-option 'point-min-cutoff 50)
    (cmacs-handtrack-set-option 'point-radius 40)
    (cmacs-handtrack--simulate-point
     (cl-loop for ms from 0 to 594 by 33
              collect (list ms nil (cmacs-handtrack-point-tests--at
                                    (/ ms 600.0) 0.5)))
     cmacs-handtrack-point-tests--geom)
    (should (> (plist-get (cmacs-handtrack-point-history-status) :samples) 10))
    (should-not (cmacs-handtrack-point-history-dwell 0 600))))

(ert-deftest cmacs-handtrack-point-hand-option ()
  "`point-hand' confines the history to one hand."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (cmacs-handtrack-set-option 'point-hand 'left)
    (should (= 0 (cmacs-handtrack--simulate-point
                  (cmacs-handtrack-point-tests--frames
                   0 400 (cmacs-handtrack-point-tests--at 0.5 0.5))
                  cmacs-handtrack-point-tests--geom)))
    (should (> (cmacs-handtrack--simulate-point
                (cmacs-handtrack-point-tests--frames
                 0 400 (cmacs-handtrack-point-tests--at 0.5 0.5) 'left)
                cmacs-handtrack-point-tests--geom)
               0))))

(ert-deftest cmacs-handtrack-point-both-hands ()
  "Each hand has rests of its own; the longer one answers."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (cmacs-handtrack--simulate-point
     (cl-loop for ms from 0 to 600 by 33
              collect (list ms
                            ;; The left points all along, the right only briefly.
                            (cmacs-handtrack-point-tests--at 0.2 0.5)
                            (and (< ms 200)
                                 (cmacs-handtrack-point-tests--at 0.8 0.5))))
     cmacs-handtrack-point-tests--geom)
    (let ((r (cmacs-handtrack-point-history-dwell 0 600)))
      (should (eq (plist-get r :hand) 'left))
      (should (cmacs-handtrack-point-tests--near (plist-get r :u) 0.2 0.01)))
    (should (equal (plist-get (cmacs-handtrack-point-history-status) :pointing)
                   '(left)))))


;;;; Privacy

(ert-deftest cmacs-handtrack-point-nothing-outlives-the-tracker ()
  "Closing the tracker, or turning the history off, empties the ring."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cl-flet ((fill ()
              (cmacs-handtrack--simulate-point
               (cmacs-handtrack-point-tests--frames
                0 400 (cmacs-handtrack-point-tests--at 0.5 0.5))
               cmacs-handtrack-point-tests--geom))
            (samples ()
              (plist-get (cmacs-handtrack-point-history-status) :samples)))
    (cmacs-handtrack-point-tests--with-ring
      (should (> (fill) 0))
      (should (> (samples) 0))
      ;; The tracker closes (no worker is running here; closing is safe).
      (cmacs-handtrack-close)
      (should (= 0 (samples)))
      (should-not (cmacs-handtrack-point-history-dwell 0 400 nil 0))
      ;; Still on: the next session is noted again.
      (should (plist-get (cmacs-handtrack-point-history-status) :enabled))
      (should (> (fill) 0))
      (cmacs-handtrack-point-history-clear)
      (should (= 0 (samples)))
      (should (> (fill) 0))
      (should-not (cmacs-handtrack-point-history-enable nil))
      (should (= 0 (samples)))
      ;; Turning it back on does not bring anything back.
      (should (cmacs-handtrack-point-history-enable t))
      (should (= 0 (samples))))))

(ert-deftest cmacs-handtrack-point-source-guards ()
  "The ring is pure, allocates nothing, writes nothing, and is wired in."
  (let ((ring (cmacs-handtrack-point-tests--source
               "cmacs/handtrack/cmacs-handtrack-point-history.c"))
        (defuns (cmacs-handtrack-point-tests--source
                 "cmacs/handtrack/cmacs-handtrack-defuns.c"))
        (case-fold-search nil))
    (skip-unless (and ring defuns))
    (let ((code (cmacs-handtrack-point-tests--code ring)))
      ;; The split: this TU never sees Lisp or the compositor.
      (should-not (string-match-p "lisp\\.h\\|gowl" code))
      ;; No allocation per sample, or at all.
      (should-not (string-match-p
                   "\\_<\\(?:g_malloc0?\\|g_new0?\\|g_slice_\\|malloc\\|calloc\\|realloc\\|g_strdup\\|xmalloc\\)\\_>"
                   code))
      ;; Where the user pointed is never written anywhere.
      (should-not (string-match-p
                   "\\_<\\(?:fopen\\|open\\|fwrite\\|write\\|g_file_set_contents\\|g_log\\|g_message\\|g_warning\\|printf\\|fprintf\\)[[:space:]]*("
                   code)))
    (let ((code (cmacs-handtrack-point-tests--code defuns)))
      (cl-flet ((body (name)
                  (or (cmacs-handtrack-point-tests--body code name) "")))
        ;; Results reach the ring from the main-thread handler...
        (should (string-search "ht_point_result (r);" (body "ht_on_result")))
        ;; ... stamped with the frame's time, not with now, and without
        ;; touching Lisp: this runs from a GLib dispatch.
        (should (string-search "r->frame_us / 1000 - pt.latency_ms"
                               (body "ht_point_result")))
        (should-not (string-match-p "Lisp_Object\\|intern\\|error ("
                                    (body "ht_point_step")))
        ;; Closing the tracker forgets it.
        (should (string-match-p
                 "Fcmacs_handtrack_close[^}]*ht_point_forget ();" code))
        ;; The mapping and the smoothing are the hand cursor's own
        ;; functions, not copies of their arithmetic.
        (dolist (fn '("cursor_target" "ht_point_step"))
          (should (string-search "ht_region_uv (" (body fn)))
          (should (string-search "ht_output_smooth (" (body fn))))
        ;; What is under the fingertip is asked through the helper that
        ;; takes the gowl lock, never with a bare gowl_ call here.
        (should (string-search "cmacs_gowl_pointer_history_hit ("
                               (body "ht_point_step")))
        (should-not (string-match-p "\\_<gowl_[a-z_]+ (" code))))))


;;;; Calibration

(ert-deftest cmacs-handtrack-point-pinch-onset-is-stamped ()
  "The frame a pinch closes in is noted, for the calibration."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (cmacs-handtrack-point-tests--with-ring
    (cmacs-handtrack-point-history-clear)
    (should-not (plist-get (cmacs-handtrack-point-history-status) :pinch-right))
    (cmacs-handtrack--simulate-point
     (list (list 1000 nil (cmacs-handtrack--synthetic-landmarks 'right 0.05 nil
                                                                 0.1 -0.1))
           (list 1033 nil (cmacs-handtrack--synthetic-landmarks 'right 0.05 nil
                                                                 0.1 -0.1))
           (list 1066 nil (cmacs-handtrack--synthetic-landmarks 'right 0.01 nil
                                                                 0.1 -0.1))
           (list 1100 nil (cmacs-handtrack--synthetic-landmarks 'right 0.01 nil
                                                                 0.1 -0.1)))
     cmacs-handtrack-point-tests--geom)
    (let ((st (cmacs-handtrack-point-history-status)))
      (should (= (plist-get st :pinch-right) 1066))
      (should-not (plist-get st :pinch-left))
      (should (= (plist-get st :latency-ms) 40))
      ;; The key came at 1040: the pinch was stamped 26 ms late.
      (should (equal (cmacs-handtrack--point-calibration 1040 st)
                     '(26 . 66))))))

(ert-deftest cmacs-handtrack-point-calibration-arithmetic ()
  "The suggested latency makes the pinch land on the key."
  (should (equal (cmacs-handtrack--point-calibration
                  1000 '(:pinch-right 1030 :latency-ms 40))
                 '(30 . 70)))
  ;; Stamped early: the correction was too large.
  (should (equal (cmacs-handtrack--point-calibration
                  1000 '(:pinch-left 990 :latency-ms 40))
                 '(-10 . 30)))
  ;; Both hands pinched at some time: the one nearer the key.
  (should (equal (cmacs-handtrack--point-calibration
                  5000 '(:pinch-left 4100 :pinch-right 5020 :latency-ms 0))
                 '(20 . 20)))
  ;; A pinch from long ago is not this key's.
  (should-not (cmacs-handtrack--point-calibration
               9000 '(:pinch-right 1000 :latency-ms 40)))
  (should-not (cmacs-handtrack--point-calibration 9000 '(:latency-ms 40))))

(ert-deftest cmacs-handtrack-point-options-wait-for-the-primitive ()
  "A `point-*' option is not pushed at a binary that would refuse it."
  (let ((pushed nil))
    (cl-letf (((symbol-function 'cmacs-handtrack-set-option)
               (lambda (&rest args) (push args pushed))))
      (let ((sym (make-symbol "opt")))
        (set sym nil)
        (funcall (cmacs-handtrack--set 'point-dwell
                                       'cmacs-handtrack-point-tests--no-such)
                 sym 5)
        (should-not pushed)
        (should (= (symbol-value sym) 5))
        (funcall (cmacs-handtrack--set 'point-dwell 'car) sym 6)
        (should (equal pushed '((point-dwell 6))))
        (funcall (cmacs-handtrack--set 'swap-hands) sym t)
        (should (equal (car pushed) '(swap-hands t)))))))

;;;; End to end: landmarks and word times in, a command out

(defvar cmacs-deixis--pointers)
(defvar cmacs-deixis-pointer-order)
(defvar cmacs-deixis-fallback-to-point)
(defvar cmacs-deixis-latency-ms)
(defvar cmacs-deixis-confirm-destructive)
(defvar cmacs-deixis-clock-function)
(declare-function cmacs-deixis-register-pointer "cmacs-deixis")
(declare-function cmacs-deixis-resolve "cmacs-deixis")
(declare-function cmacs-deixis-run-command "cmacs-deixis")
(declare-function cmacs-deixis--hand-pointer "cmacs-deixis")

(ert-deftest cmacs-handtrack-point-move-that-there ()
  "Simulated landmarks through the real ring, bound to words by time.
The hand points at the left of the screen while \"that\" is said, drops
out of the pose, and points at the right while \"there\" is said."
  (skip-unless (cmacs-handtrack-point-tests--built-p))
  (require 'cmacs-deixis)
  (cmacs-handtrack-point-tests--with-ring
    (let ((cmacs-deixis--pointers nil)
          (cmacs-deixis-pointer-order '(hand))
          (cmacs-deixis-fallback-to-point nil)
          (cmacs-deixis-latency-ms 0)
          (cmacs-deixis-confirm-destructive nil)
          ;; The frames below are stamped on this clock.
          (cmacs-deixis-clock-function (lambda () 3000))
          (calls nil))
      (cmacs-deixis-register-pointer 'hand #'cmacs-deixis--hand-pointer)
      (cmacs-handtrack--simulate-point
       (append (cmacs-handtrack-point-tests--frames
                1200 1700 (cmacs-handtrack-point-tests--at 0.2 0.4))
               (cmacs-handtrack-point-tests--frames
                1733 2200 (cmacs-handtrack-point-tests--at 0.5 0.5 'open))
               (cmacs-handtrack-point-tests--frames
                2300 3000 (cmacs-handtrack-point-tests--at 0.85 0.4)))
       cmacs-handtrack-point-tests--geom)
      (cl-letf (((symbol-function 'cmacs-deixis--gowl-live-p)
                 (lambda (&rest _) t))
                ;; No compositor was asked what is under the fingertip, so
                ;; the samples carry positions only: say here what is at
                ;; them.  The left half is a browser, the right an output.
                ((symbol-function 'cmacs-deixis--gowl-referent)
                 (lambda (&rest args)
                   (let ((x (plist-get (car args) :x)))
                     (if (< x 960)
                         (list :kind 'window :client 'browser :client-id 12
                               :monitor 0 :x x :confidence 1.0
                               :label "window: librewolf (client 12)")
                       (list :kind 'monitor :monitor 1 :x x :confidence 1.0
                             :label "monitor 1")))))
                ((symbol-function 'gowl-list-monitors)
                 (lambda (&rest _) '(mon-0 mon-1)))
                ((symbol-function 'gowl-monitor-info)
                 (lambda (&rest _) '((name . "DP-2") (geometry 1920 0 1920 1080))))
                ((symbol-function 'gowl-move-client-to-monitor)
                 (lambda (&rest args) (push (cons 'to-monitor args) calls) nil))
                ((symbol-function 'cmacs-deixis--run-later)
                 (lambda (fn) (funcall fn)))
                ((symbol-function 'message) #'ignore))
        ;; The audio began at 1000 on the ring's clock.
        (let* ((text "move that over there")
               (words '(("move" 0 200) ("that" 300 500) ("over" 1200 1300)
                        ("there" 1500 1800)))
               (bindings (cmacs-deixis-resolve text words 1000))
               (that (plist-get (nth 0 bindings) :referent))
               (there (plist-get (nth 1 bindings) :referent)))
          (should (eq (plist-get that :client) 'browser))
          (should (eq (plist-get that :device) 'hand))
          (should (cmacs-handtrack-point-tests--near (plist-get that :x)
                                                     (* 0.2 1919) 6.0))
          (should (eq (plist-get there :kind) 'monitor))
          (should (cmacs-handtrack-point-tests--near (plist-get there :x)
                                                     (* 0.85 1919) 12.0))
          (should (plist-get that :approximate))
          (should (<= (plist-get that :confidence) 0.9))
          (should (eq (cmacs-deixis-run-command text bindings) 'move))
          (should (equal calls '((to-monitor browser mon-1)))))
        ;; The same words a second later: the hand was elsewhere, or
        ;; nowhere, and nothing is moved.
        (setq calls nil)
        (let ((bindings (cmacs-deixis-resolve
                         "move that over there"
                         '(("move" 0 200) ("that" 300 500) ("over" 1200 1300)
                           ("there" 1500 1800))
                         4000)))
          (should-not (cmacs-deixis-run-command "move that over there"
                                                bindings))
          (should-not calls))))))

(provide 'cmacs-handtrack-point-tests)

;;; cmacs-handtrack-point-tests.el ends here
