;;; cmacs-camera-tests.el --- Tests for camera capture -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Everything here runs against GStreamer's videotestsrc ("test"): no
;; real camera is opened, ever.  Listing real devices is opt-in
;; (CMACS_TEST_CAMERA_DEVICES=1), since even a probe touches /dev/video*.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)

(defun cmacs-camera-tests--built-p ()
  (fboundp 'cmacs-camera-open))

(defun cmacs-camera-tests--wait (pred &optional seconds)
  (let ((deadline (+ (float-time) (or seconds 10.0))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))

(defun cmacs-camera-tests--videotestsrc-p ()
  (and (cmacs-camera-tests--built-p)
       (executable-find "gst-inspect-1.0")
       (eq 0 (call-process "gst-inspect-1.0" nil nil nil "videotestsrc"))))

(ert-deftest cmacs-camera-feature-flag-matches-the-build ()
  "IS-CMACS-CAMERA is always bound and agrees with the primitives."
  (should (boundp 'IS-CMACS-CAMERA))
  (should (boundp 'is-cmacs-camera))
  (should (eq (and IS-CMACS-CAMERA t) (and (cmacs-camera-tests--built-p) t)))
  (when IS-CMACS-CAMERA
    (should (memq 'camera (cmacs-compiled-features)))))

(ert-deftest cmacs-camera-closed-by-default ()
  "Nothing is open until asked; closing what is closed is harmless."
  (skip-unless (cmacs-camera-tests--built-p))
  (cmacs-camera-close)
  (let ((st (cmacs-camera-status)))
    (should-not (plist-get st :open))
    (should-not (plist-get st :pending))
    (should-not (plist-get st :source)))
  (should-not (cmacs-camera-frame-ppm))
  (should-not (cmacs-camera-close)))

(ert-deftest cmacs-camera-test-source-delivers-frames-in-memory ()
  "videotestsrc opens, delivers frames of the asked size, and closes."
  (skip-unless (cmacs-camera-tests--videotestsrc-p))
  (unwind-protect
      (progn
        (should (eq t (cmacs-camera-open "test:ball" 160 120 30)))
        (should (cmacs-camera-tests--wait
                 (lambda () (> (plist-get (cmacs-camera-status) :frames) 3))))
        (let ((st (cmacs-camera-status)))
          (should (plist-get st :open))
          (should (= (plist-get st :width) 160))
          (should (= (plist-get st :height) 120))
          (should (equal (plist-get st :source) "test:ball")))
        ;; The preview frame: a PPM in a string, scaled down, never a file.
        (let ((ppm (cmacs-camera-frame-ppm 80)))
          (should (stringp ppm))
          (should-not (multibyte-string-p ppm))
          (should (string-prefix-p "P6\n80 60\n255\n" ppm))
          (should (= (length ppm) (+ (length "P6\n80 60\n255\n") (* 80 60 3))))))
    (cmacs-camera-close))
  (should-not (plist-get (cmacs-camera-status) :open))
  (should-not (cmacs-camera-frame-ppm)))

(ert-deftest cmacs-camera-reopen-replaces ()
  "Opening again closes the first pipeline; sizes are clamped."
  (skip-unless (cmacs-camera-tests--videotestsrc-p))
  (unwind-protect
      (progn
        (cmacs-camera-open "test" 64 48 15)
        (cmacs-camera-open "test" 4 4 500)
        (let ((st (cmacs-camera-status)))
          (should (= (plist-get st :width) 16))
          (should (= (plist-get st :height) 16)))
        (should (cmacs-camera-tests--wait
                 (lambda () (> (plist-get (cmacs-camera-status) :frames) 0)))))
    (cmacs-camera-close)))

(ert-deftest cmacs-camera-bad-device-fails-cleanly ()
  "A missing device is an error (now, or from the bus) and leaves nothing open."
  (skip-unless (cmacs-camera-tests--built-p))
  (unwind-protect
      (condition-case nil
          (progn
            (cmacs-camera-open "/dev/cmacs-no-such-video-node" 64 48 15)
            (should (cmacs-camera-tests--wait
                     (lambda () (not (plist-get (cmacs-camera-status) :open)))))
            (should (plist-get (cmacs-camera-status) :error)))
        (error (should-not (plist-get (cmacs-camera-status) :open))))
    (cmacs-camera-close))
  (should-error (cmacs-camera-open "no camera has this name 3f9a" 64 48 15)))

(ert-deftest cmacs-camera-start-stop-shows-the-indicator ()
  "The command opens with an indicator and stop takes it away."
  (skip-unless (and (cmacs-camera-tests--videotestsrc-p)
                    (require 'cmacs-camera nil t)))
  (let ((cmacs-camera-device "test")
        (cmacs-camera-width 64) (cmacs-camera-height 48)
        (cmacs-camera-gowl-toast nil)
        (global-mode-string nil))
    (unwind-protect
        (progn
          (cmacs-camera-start)
          (should (cmacs-camera-open-p))
          (should (memq 'cmacs-camera-indicator global-mode-string))
          (cmacs-camera-acquire 'test-user)
          (cmacs-camera-release 'test-user)
          ;; Released by its last user: closed.
          (should-not (cmacs-camera-open-p))
          (should-not (memq 'cmacs-camera-indicator global-mode-string)))
      (cmacs-camera-stop))
    (should-not (cmacs-camera-open-p))))

(ert-deftest cmacs-camera-lists-devices-when-asked ()
  "Device listing returns (NAME API SPEC) triples (opt-in: real devices)."
  (skip-unless (and (cmacs-camera-tests--built-p)
                    (getenv "CMACS_TEST_CAMERA_DEVICES")))
  (dolist (d (cmacs-camera-devices))
    (should (= (length d) 3))
    (should (cl-every #'stringp d))))

(provide 'cmacs-camera-tests)

;;; cmacs-camera-tests.el ends here
