;;; cmacs-vidstudio-tests.el --- Tests for the video editor -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the cmacs-vidstudio-* C primitives (the Reel-based video
;; editor model).  Timeline math and headless CPU frame rendering run with no
;; display; export tests are gated on the `ffmpeg' binary.  Skipped unless
;; cmacs was built with --with-cmacs-vidstudio.

;;; Code:

(require 'ert)

(defmacro cmacs-vidstudio-tests--skip-unless ()
  '(skip-unless (and (fboundp 'cmacs-vidstudio-supported-p)
                     (cmacs-vidstudio-supported-p))))

(defmacro cmacs-vidstudio-tests--with-proj (var w h fps &rest body)
  (declare (indent 4))
  `(let ((,var (cmacs-vidstudio-new ,w ,h ,fps)))
     (unwind-protect (progn ,@body)
       (cmacs-vidstudio-free ,var))))

(ert-deftest cmacs-vidstudio-new ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 320 240 30.0
    (should (= (cmacs-vidstudio-width p) 320))
    (should (= (cmacs-vidstudio-height p) 240))
    (should (= (cmacs-vidstudio-n-tracks p) 1))   ; starts with one track
    (should (= (cmacs-vidstudio-total-frames p) 0))))

(ert-deftest cmacs-vidstudio-tracks-and-clips ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 320 240 30.0
    (let ((a (cmacs-vidstudio-add-solid-clip p 0 10 255 0 0 255))
          (b (cmacs-vidstudio-add-solid-clip p 0 10 0 0 255 255)))
      (should (>= a 0))
      (should (>= b 0))
      (should (= (cmacs-vidstudio-track-clip-count p 0) 2))
      ;; No transition: total = sum of durations.
      (should (= (cmacs-vidstudio-total-frames p) 20))
      (should (= (cmacs-vidstudio-clip-duration p a) 10))
      (should (= (cmacs-vidstudio-clip-start-frame p a) 0))
      (should (= (cmacs-vidstudio-clip-start-frame p b) 10)))))

(ert-deftest cmacs-vidstudio-transition-overlap ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 320 240 30.0
    (let ((a (cmacs-vidstudio-add-solid-clip p 0 10 255 0 0 255))
          (b (cmacs-vidstudio-add-solid-clip p 0 10 0 0 255 255)))
      (ignore a)
      ;; Dissolve before B with a 4-frame overlap.
      (should (cmacs-vidstudio-set-transition p b 1 4 0))
      (should (= (cmacs-vidstudio-total-frames p) 16))     ; 10 + 10 - 4
      (should (= (cmacs-vidstudio-clip-start-frame p b) 6))))) ; 10 - 4

(ert-deftest cmacs-vidstudio-render-solid ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (cmacs-vidstudio-add-solid-clip p 0 10 255 0 0 255)  ; full-frame red
    (let ((px (cmacs-vidstudio-frame-pixel p 0 32 24)))
      (should px)
      (should (> (nth 0 px) 250))     ; red
      (should (< (nth 2 px) 5)))))    ; not blue

(ert-deftest cmacs-vidstudio-two-track-composite ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (cmacs-vidstudio-add-solid-clip p 0 10 255 0 0 255)  ; track 0: red
    (let ((t1 (cmacs-vidstudio-add-track p)))
      (cmacs-vidstudio-add-solid-clip p t1 10 0 0 255 255) ; track 1: blue over
      (let ((px (cmacs-vidstudio-frame-pixel p 0 32 24)))
        (should px)
        (should (> (nth 2 px) 250))   ; blue wins (opaque, on top)
        (should (< (nth 0 px) 5))))))

(ert-deftest cmacs-vidstudio-effect-and-text ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (let ((a (cmacs-vidstudio-add-solid-clip p 0 10 100 150 200 255)))
      (should (cmacs-vidstudio-add-effect p a 0))         ; blur
      (should (cmacs-vidstudio-add-effect p a 3))         ; vignette
      ;; Still renders a frame after effects.
      (should (cmacs-vidstudio-frame-pixel p 0 10 10)))
    (let ((tx (cmacs-vidstudio-add-text-clip p 0 "Title" 10 255 255 255 255)))
      (should (>= tx 0)))))

(ert-deftest cmacs-vidstudio-split ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (let* ((a (cmacs-vidstudio-add-solid-clip p 0 20 0 255 0 255))
           (tail (cmacs-vidstudio-split-clip p a 8)))
      (should tail)
      (should (= (cmacs-vidstudio-clip-duration p a) 8))
      (should (= (cmacs-vidstudio-clip-duration p tail) 12))
      (should (= (cmacs-vidstudio-track-clip-count p 0) 2))
      ;; Total length is preserved by the split.
      (should (= (cmacs-vidstudio-total-frames p) 20)))))

(ert-deftest cmacs-vidstudio-remove-ripple ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (let ((a (cmacs-vidstudio-add-solid-clip p 0 10 255 0 0 255))
          (b (cmacs-vidstudio-add-solid-clip p 0 10 0 255 0 255)))
      (ignore b)
      (should (cmacs-vidstudio-remove-clip p a t))   ; ripple
      (should (= (cmacs-vidstudio-track-clip-count p 0) 1))
      (should (= (cmacs-vidstudio-total-frames p) 10)))))

(ert-deftest cmacs-vidstudio-render-png ()
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (cmacs-vidstudio-add-solid-clip p 0 5 10 20 30 255)
    (let ((png (cmacs-vidstudio-render-png p 0)))
      (should (stringp png))
      (should (> (length png) 8))
      (should (= (aref png 0) #x89))
      (should (= (aref png 1) ?P)))))

(ert-deftest cmacs-vidstudio-export-gif ()
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (executable-find "ffmpeg"))  ; reel video path uses ffmpeg tooling
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (cmacs-vidstudio-add-solid-clip p 0 6 200 100 50 255)
    (let ((path (make-temp-file "cmacs-vidstudio-" nil ".gif")))
      (unwind-protect
          (progn
            (should (cmacs-vidstudio-export-gif p path))
            (should (file-exists-p path))
            (should (> (file-attribute-size (file-attributes path)) 0)))
        (delete-file path)))))

(ert-deftest cmacs-vidstudio-render-ppm ()
  "PPM preview: P6 magic, downscale honours MAX-WIDTH, pixels real."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (fboundp 'cmacs-vidstudio-render-ppm))
  (cmacs-vidstudio-tests--with-proj p 640 360 30.0
    (cmacs-vidstudio-add-solid-clip p 0 5 200 30 30 255)
    ;; Full size.
    (let ((d (cmacs-vidstudio-render-ppm p 0 nil)))
      (should (string-prefix-p "P6\n640 360\n255\n" d))
      (should (= (length d) (+ 15 (* 640 360 3)))))
    ;; Downscaled to 320 wide (aspect kept -> 180 high).
    (let ((d (cmacs-vidstudio-render-ppm p 0 320)))
      (should (string-prefix-p "P6\n320 180\n255\n" d))
      ;; A pixel from the body matches the solid clip (red-ish).
      (let ((off 15))                   ; header length
        (should (> (aref d off) 150))         ; R
        (should (< (aref d (+ off 1)) 80))))  ; G
    ;; MAX-WIDTH larger than the frame: no upscale.
    (let ((d (cmacs-vidstudio-render-ppm p 0 4096)))
      (should (string-prefix-p "P6\n640 360\n255\n" d)))))

(ert-deftest cmacs-vidstudio-async-video-decode ()
  "Video import must not block: placeholder until the worker decodes.
Adding a video clip returns after the (fast) probe; the preview
composites a dark placeholder while a worker thread decodes; readiness
flips once the decode lands and real frames replace the placeholder."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (and (executable-find "ffmpeg") (executable-find "ffprobe")))
  (let ((clip (make-temp-file "cmacs-vidstudio-clip" nil ".mp4")))
    (unwind-protect
        (progn
          (should (zerop (call-process
                          "ffmpeg" nil nil nil "-y" "-v" "error"
                          "-f" "lavfi" "-i"
                          "testsrc=duration=2:size=128x72:rate=30" clip)))
          (cmacs-vidstudio-tests--with-proj p 128 72 30.0
            (let* ((t0 (float-time))
                   (id (cmacs-vidstudio-add-video-clip p 0 clip 60)))
              ;; Import returns in probe time, not decode time.
              (should (< (- (float-time) t0) 2.0))
              (should (>= id 0))
              ;; Rendering during the decode must not block on the clip.
              (should (stringp (cmacs-vidstudio-render-png p 0)))
              ;; The worker finishes; readiness becomes t.
              (let ((deadline (+ (float-time) 30.0)))
                (while (and (not (cmacs-vidstudio-clip-ready-p p id))
                            (< (float-time) deadline))
                  (sleep-for 0.1)))
              (should (cmacs-vidstudio-clip-ready-p p id))
              ;; Real frames now: testsrc content is not the placeholder.
              (should-not (equal (cmacs-vidstudio-frame-pixel p 0 64 36)
                                 '(24 24 24 255))))))
      (delete-file clip))))

(provide 'cmacs-vidstudio-tests)
;;; cmacs-vidstudio-tests.el ends here
