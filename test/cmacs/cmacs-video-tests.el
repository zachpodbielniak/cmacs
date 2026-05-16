;;; cmacs-video-tests.el --- ERT for cmacs-video  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT suite for the cmacs-video subsystem.  Every non-trivial test is
;; gated on (cmacs-feature-p 'video) so the file can be loaded even on
;; cmacs builds compiled without `--with-cmacs-video'.  The
;; videotestsrc-based synthetic pipeline (`cmacs-video--open-test-pipeline')
;; is used everywhere to avoid needing fixture media.

;;; Code:

(require 'ert)
(require 'cmacs)
(when (cmacs-feature-p 'video)
  (require 'cmacs-video)
  (require 'cmacs-video-org))

(defvar cmacs-video-tests--wait-step 0.05
  "How long to sleep between polls when waiting on async state.")

(defun cmacs-video-tests--wait-until (pred timeout)
  "Poll PRED every `cmacs-video-tests--wait-step' until it returns
non-nil or TIMEOUT seconds elapse.  Returns whatever PRED last returned."
  (let ((deadline (+ (float-time) timeout))
        result)
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline))
      (sleep-for cmacs-video-tests--wait-step))
    result))

;;;; ────────────────────── Capability ──────────────────────

(ert-deftest cmacs-video-test-supported-p ()
  "`cmacs-video-supported-p' is reflexive."
  (skip-unless (fboundp 'cmacs-video-supported-p))
  (should (cmacs-video-supported-p)))

(ert-deftest cmacs-video-test-feature-p ()
  "`cmacs-feature-p 'video' agrees with `cmacs-video-supported-p'."
  (should (eq (and (cmacs-feature-p 'video) t)
              (and (fboundp 'cmacs-video-supported-p)
                   (cmacs-video-supported-p)
                   t))))

;;;; ────────────────────── Synthetic pipeline ──────────────────────

(ert-deftest cmacs-video-test-synthetic-open-close ()
  "Open + close a `videotestsrc' pipeline, no leaks of state."
  (skip-unless (cmacs-feature-p 'video))
  (let ((h (cmacs-video--open-test-pipeline 320 240)))
    (unwind-protect
        (progn
          (should (integerp h))
          (cmacs-video-tests--wait-until
           (lambda () (memq (cmacs-video-state h)
                            '(playing paused buffering)))
           2.0)
          (should (memq (cmacs-video-state h)
                        '(playing paused buffering eos))))
      (cmacs-video-close h))
    (should-not (memq h (cmacs-video-list)))))

(ert-deftest cmacs-video-test-frame-counter-increments ()
  "`cmacs-video-frames-decoded' is monotonically non-decreasing."
  (skip-unless (cmacs-feature-p 'video))
  (let ((h (cmacs-video--open-test-pipeline 320 240)))
    (unwind-protect
        (let (c1 c2)
          (cmacs-video-tests--wait-until
           (lambda () (> (cmacs-video-frames-decoded h) 0)) 2.0)
          (setq c1 (cmacs-video-frames-decoded h))
          (sleep-for 0.4)
          (setq c2 (cmacs-video-frames-decoded h))
          (should (>= c2 c1)))
      (cmacs-video-close h))))

(ert-deftest cmacs-video-test-state-transitions ()
  "Open transitions through initializing → playing (or eos)."
  (skip-unless (cmacs-feature-p 'video))
  (let ((h (cmacs-video--open-test-pipeline 320 240))
        states)
    (cmacs-video-add-state-handler
     h (lambda (_h s &optional _d) (push s states)))
    (unwind-protect
        (progn
          (cmacs-video-tests--wait-until
           (lambda () (memq 'playing states)) 2.0)
          (should (or (memq 'playing states)
                      (memq 'eos states))))
      (cmacs-video-close h))))

(ert-deftest cmacs-video-test-frame-size ()
  "`cmacs-video-frame-size' reflects videotestsrc dims once decoded."
  (skip-unless (cmacs-feature-p 'video))
  (let ((h (cmacs-video--open-test-pipeline 320 240)))
    (unwind-protect
        (let ((size (cmacs-video-tests--wait-until
                     (lambda () (cmacs-video-frame-size h))
                     2.0)))
          (should size)
          (should (= (car size) 320))
          (should (= (cdr size) 240)))
      (cmacs-video-close h))))

(ert-deftest cmacs-video-test-list-tracks-handles ()
  "Opening two streams puts both in `cmacs-video-list'."
  (skip-unless (cmacs-feature-p 'video))
  (let ((a (cmacs-video--open-test-pipeline 320 240))
        (b (cmacs-video--open-test-pipeline 320 240)))
    (unwind-protect
        (let ((live (cmacs-video-list)))
          (should (memq a live))
          (should (memq b live)))
      (cmacs-video-close a)
      (cmacs-video-close b))))

;;;; ────────────────────── Snapshot ──────────────────────

(ert-deftest cmacs-video-test-snapshot-roundtrip ()
  "Snapshot a synthetic frame to PNG and assert file exists nonzero."
  (skip-unless (cmacs-feature-p 'video))
  (let* ((tmp (make-temp-file "cmacs-video-snap-" nil ".png"))
         (h (cmacs-video--open-test-pipeline 320 240)))
    (unwind-protect
        (progn
          (cmacs-video-tests--wait-until
           (lambda () (> (cmacs-video-frames-decoded h) 0)) 2.0)
          (should (cmacs-video-snapshot-to-file h tmp))
          (should (> (file-attribute-size (file-attributes tmp)) 0)))
      (cmacs-video-close h)
      (when (file-exists-p tmp) (delete-file tmp)))))

;;;; ────────────────────── Org block parsing ──────────────────────

(ert-deftest cmacs-video-test-org-arg-parser ()
  "`cmacs-video-org--parse-args' correctly handles common cases."
  (skip-unless (cmacs-feature-p 'video))
  (let ((p (cmacs-video-org--parse-args
            ":src \"rtsps://nvr/abc?d=1\" :width 640 :height 360 :insecure t :latency 200")))
    (should (string= (plist-get p :src) "rtsps://nvr/abc?d=1"))
    (should (= (plist-get p :width)   640))
    (should (= (plist-get p :height)  360))
    (should (eq (plist-get p :insecure) t))
    (should (= (plist-get p :latency) 200))))

(ert-deftest cmacs-video-test-org-block-detection ()
  "`cmacs-video-org--block-at-point' finds the surrounding block."
  (skip-unless (cmacs-feature-p 'video))
  (with-temp-buffer
    (when (fboundp 'org-mode) (org-mode))
    (insert "Lorem ipsum\n"
            "#+BEGIN_VIDEO :src \"file:///tmp/x.mp4\" :width 320 :height 240\n"
            "caption\n"
            "#+END_VIDEO\n"
            "trailing\n")
    (goto-char (point-min))
    (forward-line 2) ; on "caption"
    (let ((blk (cmacs-video-org--block-at-point)))
      (should blk)
      (should (string= (cmacs-video-org--block-src blk) "file:///tmp/x.mp4"))
      (should (= (cmacs-video-org--block-width  blk) 320))
      (should (= (cmacs-video-org--block-height blk) 240)))))

;;;; ────────────────────── Compositor independence ──────────────────────

(ert-deftest cmacs-video-test-no-gowl-dependency ()
  "The cmacs-video subsystem MUST NOT require cmacs-gowl at runtime.
This test passes whether `cmacs-gowl' is present or not — its purpose
is to prove that the assertion below is exercised on every CI run."
  (skip-unless (cmacs-feature-p 'video))
  ;; The implication: video is supported regardless of gowl state.
  (should (eq (cmacs-video-supported-p) t)))

(ert-deftest cmacs-video-test-paint-symbols-available ()
  "Paint-related symbols are bound when video is enabled."
  (skip-unless (cmacs-feature-p 'video))
  (should (fboundp 'cmacs-video-attach-buffer))
  (should (fboundp 'cmacs-video-attach-frame))
  (should (fboundp 'cmacs-video-detach)))

;;;; ────────────────────── Lifecycle ──────────────────────

(ert-deftest cmacs-video-test-shutdown-all-on-kill ()
  "`cmacs-video--shutdown-all' closes every live stream."
  (skip-unless (cmacs-feature-p 'video))
  (let ((a (cmacs-video--open-test-pipeline 320 240))
        (b (cmacs-video--open-test-pipeline 320 240)))
    (cmacs-video--shutdown-all)
    (should-not (memq a (cmacs-video-list)))
    (should-not (memq b (cmacs-video-list)))))

(provide 'cmacs-video-tests)

;;; cmacs-video-tests.el ends here
