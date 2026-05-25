;;; cmacs-audio-tests.el --- ERT for cmacs-audio  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Gated on (cmacs-feature-p 'audio).  Uses the synthetic
;; `audiotestsrc' capture source so no microphone hardware is required.

;;; Code:

(require 'ert)
(require 'cmacs)
(when (cmacs-feature-p 'audio)
  (require 'cmacs-audio))

(ert-deftest cmacs-audio--supported-matches-feature ()
  "`cmacs-feature-p 'audio' agrees with `cmacs-audio-supported-p'."
  (skip-unless (fboundp 'cmacs-audio-supported-p))
  (should (eq (cmacs-feature-p 'audio)
              (and (cmacs-audio-supported-p) t))))

(ert-deftest cmacs-audio--capture-open-close ()
  "Open + close a synthetic capture stream; verify registry hygiene."
  (skip-unless (cmacs-feature-p 'audio))
  (let* ((before (length (cmacs-audio-list)))
         (h (cmacs-audio--capture-open-1 :source 'test
                                         :rate 16000 :channels 1)))
    (should (integerp h))
    (should (eq (cmacs-audio-state h) 'ready))
    (cmacs-audio-start h)
    (sleep-for 0.25)
    (let ((pcm (cmacs-audio-read-pcm h 1600)))
      (should (stringp pcm)))
    (cmacs-audio-close h)
    (should (= before (length (cmacs-audio-list))))))

(ert-deftest cmacs-audio--waveform-svg-format ()
  "Waveform renderer produces a parseable SVG fragment."
  (skip-unless (cmacs-feature-p 'audio))
  (let* ((pcm (make-string (* 2 16000) 0))   ;; 1 s of silence
         (svg (cmacs-audio-waveform-svg pcm 400 60)))
    (should (string-prefix-p "<svg " svg))
    (should (string-suffix-p "</svg>\n" svg))))

(provide 'cmacs-audio-tests)

;;; cmacs-audio-tests.el ends here
