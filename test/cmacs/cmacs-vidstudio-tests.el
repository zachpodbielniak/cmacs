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

;; ── Import: whole-video + in/out slicing ───────────────────────────────

(defun cmacs-vidstudio-tests--make-video (path secs fps)
  "Write a SECS-second test video at PATH (FPS), or return nil if no ffmpeg."
  (and (executable-find "ffmpeg")
       (zerop (call-process
               "ffmpeg" nil nil nil "-y" "-f" "lavfi" "-i"
               (format "testsrc=duration=%s:size=160x120:rate=%s" secs fps)
               "-pix_fmt" "yuv420p" path))
       path))

(ert-deftest cmacs-vidstudio-tests-import-whole-and-slice ()
  "Blank in/out imports the whole video; in/out slices it; frames match."
  (cmacs-vidstudio-tests--skip-unless)
  (let ((v (make-temp-file "cmvs-import" nil ".mp4")))
    (unless (cmacs-vidstudio-tests--make-video v 4 30)
      (delete-file v) (ert-skip "ffmpeg not available"))
    (unwind-protect
        (cmacs-vidstudio-tests--with-proj p 160 120 30.0
          ;; whole video: 4 s * 30 fps = 120 frames
          (let ((id (cmacs-vidstudio-add-video-clip p 0 v nil nil nil)))
            (should (= (cmacs-vidstudio-clip-duration p id) 120)))
          ;; slice 1..2.5 s -> 1.5 s -> 45 frames
          (let ((id (cmacs-vidstudio-add-video-clip p 0 v nil 1.0 2.5)))
            (should (= (cmacs-vidstudio-clip-duration p id) 45)))
          ;; out before in is a fat-finger: keep IN, run to source end (never
          ;; zero/negative frames) -- here 3..4 s = 30 frames.
          (let ((id (cmacs-vidstudio-add-video-clip p 0 v nil 3.0 1.0)))
            (should (= (cmacs-vidstudio-clip-duration p id) 30)))
          ;; back-compat: a positive DURATION with no in/out = that many frames
          (let ((id (cmacs-vidstudio-add-video-clip p 0 v 60)))
            (should (= (cmacs-vidstudio-clip-duration p id) 60))))
      (delete-file v))))

(defun cmacs-vidstudio-tests--solid-png (path r g b)
  "Write a 100x100 solid RGB PNG to PATH (via imgedit); return PATH."
  (let ((h (cmacs-imgedit-new 100 100)))
    (cmacs-imgedit-fill h r g b 255)
    (cmacs-imgedit-save h path)
    (cmacs-imgedit-free h)
    path))

(ert-deftest cmacs-vidstudio-trim-in-out ()
  "Re-slicing a video clip's in/out points recomputes its on-timeline length;
the on-timeline duration is independent of the slice; both round-trip through
serialization."
  (skip-unless (executable-find "ffmpeg"))
  (let ((vid (make-temp-file "vs-clip" nil ".mp4")))
    (unwind-protect
        (progn
          (call-process "ffmpeg" nil nil nil "-y" "-v" "error" "-f" "lavfi"
                        "-i" "color=c=red:s=64x48:d=2:r=30"
                        "-pix_fmt" "yuv420p" vid)
          (let ((h (cmacs-vidstudio-new 64 48 30.0)))
            (unwind-protect
                (let ((id (cmacs-vidstudio-add-video-clip h 0 vid nil)))
                  (should (equal (cmacs-vidstudio-clip-slice h id)
                                 '(0.0 2.0 2.0)))
                  (should (= (cmacs-vidstudio-clip-duration h id) 60))
                  ;; re-slice to a 1s window -> duration follows
                  (should (cmacs-vidstudio-set-clip-trim h id 0.5 1.5))
                  (should (equal (cmacs-vidstudio-clip-slice h id)
                                 '(0.5 1.5 2.0)))
                  (should (= (cmacs-vidstudio-clip-duration h id) 30))
                  ;; on-timeline duration is independent (freeze-hold)
                  (should (cmacs-vidstudio-set-clip-duration h id 90))
                  (should (= (cmacs-vidstudio-clip-duration h id) 90))
                  (should (equal (cmacs-vidstudio-clip-slice h id)
                                 '(0.5 1.5 2.0)))
                  ;; both round-trip through serialize/reload
                  (let ((h2 (cmacs-vidstudio--build-from-sexp
                             (car (read-from-string
                                   (cmacs-vidstudio-serialize h))))))
                    (unwind-protect
                        (progn
                          (should (equal (cmacs-vidstudio-clip-slice h2 id)
                                         '(0.5 1.5 2.0)))
                          (should (= (cmacs-vidstudio-clip-duration h2 id) 90)))
                      (cmacs-vidstudio-free h2))))
              (cmacs-vidstudio-free h))))
      (ignore-errors (delete-file vid)))))

(ert-deftest cmacs-vidstudio-picture-in-picture ()
  "A clip with a destination box renders as an overlay window (video-in-
video), compositing over the tracks beneath it, and the box survives a
serialize/reload round-trip."
  (skip-unless (fboundp 'cmacs-imgedit-new))
  (let* ((red (cmacs-vidstudio-tests--solid-png
               (make-temp-file "vs-red" nil ".png") 200 0 0))
         (green (cmacs-vidstudio-tests--solid-png
                 (make-temp-file "vs-green" nil ".png") 0 200 0))
         (h (cmacs-vidstudio-new 100 100 30.0)))
    (unwind-protect
        (progn
          (cmacs-vidstudio-add-image-clip h 0 red 30)             ; red base
          (let ((ov (cmacs-vidstudio-add-image-clip
                     h (cmacs-vidstudio-add-track h) green 30)))  ; green overlay
            (should (cmacs-vidstudio-set-clip-box h ov 60 60 30 30))
            ;; base shows outside the box; overlay shows inside it
            (should (equal (cmacs-vidstudio-frame-pixel h 0 10 10)
                           '(200 0 0 255)))
            (should (equal (cmacs-vidstudio-frame-pixel h 0 75 75)
                           '(0 200 0 255)))
            ;; box round-trips through serialization
            (should (string-match-p "(box 60 60 30 30)"
                                    (cmacs-vidstudio-serialize h)))
            ;; clearing the box (w/h 0) restores the full frame
            (should (cmacs-vidstudio-set-clip-box h ov 0 0 0 0))
            (should (equal (cmacs-vidstudio-frame-pixel h 0 10 10)
                           '(0 200 0 255)))))
      (cmacs-vidstudio-free h)
      (ignore-errors (delete-file red) (delete-file green)))))

;; ── Per-clip transform / effect / export setters ───────────────────────

(ert-deftest cmacs-vidstudio-tests-clip-setters ()
  "Opacity, transform, blend, effect-param, and video-only guards."
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 64 48 30.0
    (let ((id (cmacs-vidstudio-add-solid-clip p 0 30 200 40 40 255)))
      (should (cmacs-vidstudio-set-opacity p id 0.5))
      (should (cmacs-vidstudio-set-transform p id 5 5 2.0 2.0))
      (should (cmacs-vidstudio-set-rotation p id 0.5))
      (should (cmacs-vidstudio-set-anchor p id 0.0 0.0))
      (should (cmacs-vidstudio-set-blend-mode p id 5))
      ;; video-only setters return nil on a solid clip
      (should (null (cmacs-vidstudio-set-video-rate p id 2.0)))
      (should (null (cmacs-vidstudio-set-video-fit p id 2)))
      ;; effect param after adding an effect
      (cmacs-vidstudio-add-effect p id 0)         ; blur, index 0
      (should (cmacs-vidstudio-set-effect-param p id 0 (cons "radius" 8.0)))
      ;; bad effect index -> nil
      (should (null (cmacs-vidstudio-set-effect-param p id 9
                                                      (cons "radius" 1.0)))))))

(ert-deftest cmacs-vidstudio-tests-export-still ()
  "A still export writes a decodable image file."
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 32 24 30.0
    (cmacs-vidstudio-add-solid-clip p 0 10 10 200 50 255)
    (let ((png (make-temp-file "cmvs-still" nil ".png")))
      (unwind-protect
          (progn
            (cmacs-vidstudio-export-still p 0 png)
            (should (> (file-attribute-size (file-attributes png)) 0)))
        (delete-file png)))))

;; ── Audio lane ─────────────────────────────────────────────────────────

(ert-deftest cmacs-vidstudio-tests-audio ()
  "Add an audio file, tweak it, mix + export a WAV, then remove it."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (executable-find "ffmpeg"))
  (let ((tone (make-temp-file "cmvs-tone" nil ".wav")))
    (unless (zerop (call-process "ffmpeg" nil nil nil "-y" "-f" "lavfi" "-i"
                                 "sine=frequency=440:duration=1" "-ar" "44100"
                                 tone))
      (delete-file tone) (ert-skip "ffmpeg tone gen failed"))
    (unwind-protect
        (cmacs-vidstudio-tests--with-proj p 32 24 30.0
          (cmacs-vidstudio-add-solid-clip p 0 30 20 20 20 255)
          (let ((aid (cmacs-vidstudio-add-audio-file p tone 0 0.8 0.0 0.0)))
            (should (>= aid 0))
            (should (= (cmacs-vidstudio-audio-count p) 1))
            (should (cmacs-vidstudio-set-audio-volume p aid 0.5))
            (should (cmacs-vidstudio-set-audio-fade p aid (cons 0.2 0.2)))
            (let ((wav (make-temp-file "cmvs-mix" nil ".wav")))
              (unwind-protect
                  (progn
                    (cmacs-vidstudio-export-audio p wav 0)
                    (should (> (file-attribute-size (file-attributes wav)) 0)))
                (delete-file wav)))
            (should (cmacs-vidstudio-remove-audio p aid))
            (should (= (cmacs-vidstudio-audio-count p) 0))))
      (delete-file tone))))

;; ── Keyframing ─────────────────────────────────────────────────────────

(ert-deftest cmacs-vidstudio-tests-keyframes ()
  "An opacity keyframe ramp animates the composited alpha per frame."
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 16 16 30.0
    (let ((id (cmacs-vidstudio-add-solid-clip p 0 30 255 0 0 255)))
      ;; opacity 0 -> 1 across frames 0..29
      (cmacs-vidstudio-add-keyframe p id 0 0 0.0)
      (cmacs-vidstudio-add-keyframe p id 0 29 1.0)
      (should (= (cmacs-vidstudio-keyframe-count p id) 2))
      (let ((a0 (nth 3 (cmacs-vidstudio-frame-pixel p 0 8 8)))
            (a15 (nth 3 (cmacs-vidstudio-frame-pixel p 15 8 8)))
            (a29 (nth 3 (cmacs-vidstudio-frame-pixel p 29 8 8))))
        (should (< a0 20))          ; ~transparent at the start
        (should (and (> a15 90) (< a15 170)))  ; ~half-way
        (should (> a29 240)))       ; ~opaque at the end
      ;; clearing restores the static default (opaque)
      (cmacs-vidstudio-clear-keyframes p id)
      (should (= (cmacs-vidstudio-keyframe-count p id) 0))
      (should (> (nth 3 (cmacs-vidstudio-frame-pixel p 0 8 8)) 240)))))

;; ── Save / load (.vstudio) round-trip ──────────────────────────────────

(ert-deftest cmacs-vidstudio-tests-serialize-roundtrip ()
  "serialize -> build-from-sexp -> serialize is bit-identical."
  (cmacs-vidstudio-tests--skip-unless)
  (require 'cmacs-vidstudio)
  (cmacs-vidstudio-tests--with-proj p 320 240 30.0
    (let ((id (cmacs-vidstudio-add-solid-clip p 0 60 200 40 40 255)))
      (cmacs-vidstudio-set-opacity p id 0.7)
      (cmacs-vidstudio-set-blend-mode p id 2)
      (cmacs-vidstudio-set-transition p id 0 12 0)
      (cmacs-vidstudio-set-transform p id 5 7 2.0 2.0 0.5)
      (cmacs-vidstudio-add-effect p id 0)
      (cmacs-vidstudio-set-effect-param p id 0 (cons "radius" 6.0))
      (cmacs-vidstudio-add-keyframe p id 3 0 1.0)
      (cmacs-vidstudio-add-keyframe p id 3 30 2.0))
    (cmacs-vidstudio-add-text-clip p 0 "Hi" 30 255 255 255 255)
    (let* ((s1 (cmacs-vidstudio-serialize p))
           (data (car (read-from-string s1)))
           (p2 (cmacs-vidstudio--build-from-sexp data))
           (s2 (cmacs-vidstudio-serialize p2)))
      (unwind-protect
          (should (string= s1 s2))
        (cmacs-vidstudio-free p2)))))

(ert-deftest cmacs-vidstudio-tests-gradient-clip ()
  "A linear gradient clip ramps dark->light top to bottom."
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 32 32 30.0
    (cmacs-vidstudio-add-gradient-clip p 0 30 '(0 0 0 255) '(255 255 255 255))
    (should (< (nth 0 (cmacs-vidstudio-frame-pixel p 0 16 2))
               (nth 0 (cmacs-vidstudio-frame-pixel p 0 16 29))))))

(ert-deftest cmacs-vidstudio-tests-shape-clip ()
  "A filled rect shape clip paints inside and is transparent outside."
  (cmacs-vidstudio-tests--skip-unless)
  (cmacs-vidstudio-tests--with-proj p 32 32 30.0
    (cmacs-vidstudio-add-shape-rect p 0 10 8 8 16 16 '(0 255 0 255))
    (should (equal (cmacs-vidstudio-frame-pixel p 0 16 16) '(0 255 0 255)))
    (should (= (nth 3 (cmacs-vidstudio-frame-pixel p 0 2 2)) 0))))

(ert-deftest cmacs-vidstudio-tests-sequence-clips ()
  "Loop + freeze sequence clips wrap a video source and add to the timeline."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (executable-find "ffmpeg"))
  (let ((mp4 (make-temp-file "cmvs-seq" nil ".mp4")))
    (unwind-protect
        (progn
          (call-process "ffmpeg" nil nil nil "-y" "-v" "error" "-f" "lavfi"
                        "-i" "testsrc=duration=2:size=64x48:rate=30" mp4)
          (cmacs-vidstudio-tests--with-proj p 64 48 30.0
            (cmacs-vidstudio-add-loop-clip p 0 mp4 60 0.5)
            (cmacs-vidstudio-add-freeze-clip p 0 mp4 30 1.0)
            (should (= (cmacs-vidstudio-track-clip-count p 0) 2))
            (should (= (cmacs-vidstudio-total-frames p) 90))))
      (delete-file mp4))))

(ert-deftest cmacs-vidstudio-tests-rich-text-clip ()
  "An animated text clip rasterises glyphs; effects animate per character."
  (cmacs-vidstudio-tests--skip-unless)
  (cl-flet ((glyphs (h fr w ht)
              (let ((n 0) (colored 0))
                (dotimes (y ht)
                  (dotimes (x w)
                    (let ((px (cmacs-vidstudio-frame-pixel h fr x y)))
                      (when (and px (> (nth 3 px) 0))
                        (setq n (1+ n))
                        (when (> (abs (- (nth 0 px) (nth 2 px))) 40)
                          (setq colored (1+ colored)))))))
                (cons n colored))))
    ;; rainbow: glyphs render AND get per-character colours
    (cmacs-vidstudio-tests--with-proj p 200 60 30.0
      (cmacs-vidstudio-add-rich-text p 0 "HELLO WORLD" 30 28 3
                                     '(255 255 255 255))
      (let ((g (glyphs p 5 200 60)))
        (should (> (car g) 0))
        (should (> (cdr g) 0))))       ; rainbow colours present
    ;; typewriter reveals more glyphs at a later frame than at frame 0
    (cmacs-vidstudio-tests--with-proj p 200 60 30.0
      (cmacs-vidstudio-add-rich-text p 0 "HELLO WORLD" 60 28 4
                                     '(255 255 255 255))
      (should (< (car (glyphs p 0 200 60))
                 (car (glyphs p 40 200 60)))))))
(ert-deftest cmacs-vidstudio-tests-extracted-audio-serialize ()
  "Clip-extracted audio serializes (via the video path) and round-trips."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (executable-find "ffmpeg"))
  (let ((mp4 (make-temp-file "cmvs-av" nil ".mp4")))
    (unwind-protect
        (progn
          (call-process "ffmpeg" nil nil nil "-y" "-v" "error"
                        "-f" "lavfi" "-i" "testsrc=duration=2:size=64x48:rate=30"
                        "-f" "lavfi" "-i" "sine=frequency=440:duration=2"
                        "-shortest" mp4)
          (cmacs-vidstudio-tests--with-proj p 64 48 30.0
            (let ((vid (cmacs-vidstudio-add-video-clip p 0 mp4 -1.0)))
              (cmacs-vidstudio-add-audio-from-clip p vid 0 1.0))
            (let* ((s1 (cmacs-vidstudio-serialize p)))
              (should (string-match-p "extract" s1))
              (let* ((h2 (cmacs-vidstudio--build-from-sexp
                          (car (read-from-string s1))))
                     (s2 (cmacs-vidstudio-serialize h2)))
                (should (string= s1 s2))
                (cmacs-vidstudio-free h2)))))
      (delete-file mp4))))

(ert-deftest cmacs-vidstudio-tests-frame-cache ()
  "The playback frame cache returns rendered PPM and reuses it on a hit."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (fboundp 'cmacs-vidstudio-render-ppm))
  (with-temp-buffer
    (setq cmacs-vidstudio--handle (cmacs-vidstudio-new 64 48 30.0)
          cmacs-vidstudio--preview-scale 0.5)
    (unwind-protect
        (progn
          (cmacs-vidstudio-add-solid-clip cmacs-vidstudio--handle 0 30
                                          200 50 50 255)
          (let ((fresh (cmacs-vidstudio--cache-ppm 5)))
            (should (> (length fresh) 0))
            (setq cmacs-vidstudio--frame-cache (make-hash-table :test 'eq))
            (let ((miss (cmacs-vidstudio--cache-ppm 5))    ; render + cache
                  (hit (cmacs-vidstudio--cache-ppm 5)))    ; same object
              (should (eq miss hit))
              (should (equal miss fresh)))))
      (cmacs-vidstudio-free cmacs-vidstudio--handle))))

(ert-deftest cmacs-vidstudio-tests-whole-video-duration ()
  "Whole-video import (nil/nil or -1) gets the full length; refresh is a
safe no-op on an already-resolved clip and refresh-all never errors."
  (cmacs-vidstudio-tests--skip-unless)
  (skip-unless (and (executable-find "ffmpeg") (executable-find "ffprobe")))
  (let ((mp4 (make-temp-file "cmvs-wv" nil ".mp4")))
    (unwind-protect
        (progn
          (call-process "ffmpeg" nil nil nil "-y" "-v" "error" "-f" "lavfi"
                        "-i" "testsrc=duration=2:size=64x48:rate=30" mp4)
          (cmacs-vidstudio-tests--with-proj p 64 48 30.0
            (let ((a (cmacs-vidstudio-add-video-clip p 0 mp4 nil nil nil))
                  (b (cmacs-vidstudio-add-video-clip p 0 mp4 -1)))
              ;; both whole-video forms -> ~2s @ 30 = ~60 frames
              (should (>= (cmacs-vidstudio-clip-duration p a) 55))
              (should (>= (cmacs-vidstudio-clip-duration p b) 55))
              ;; refresh is a no-op on an already-resolved clip
              (should-not (cmacs-vidstudio-refresh-video-duration p a))
              ;; refresh-all never errors
              (cmacs-vidstudio-refresh-video-duration p nil))))
      (delete-file mp4))))

(provide 'cmacs-vidstudio-tests)
;;; cmacs-vidstudio-tests.el ends here
