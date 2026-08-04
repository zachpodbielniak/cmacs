;;; cmacs-brigade-media-tests.el --- imgedit/vidstudio AI  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The parsing and clamping are pure functions and are tested directly.
;; Nothing here calls a model.

;;; Code:

(require 'ert)
(require 'cmacs-imgedit-ai nil 'noerror)
(require 'cmacs-vidstudio-ai nil 'noerror)

(ert-deftest cmacs-imgedit-ai-loads-without-imgedit ()
  "The AI layer never breaks the subsystem it extends.

Guarded at load rather than behind a configure flag, so a build with
cmacs-ai off simply has no commands here and imgedit is untouched."
  (should t))

(ert-deftest cmacs-imgedit-ai-arg-coercion ()
  "Model-supplied arguments coerce, including numbers sent as strings."
  (skip-unless (featurep 'cmacs-imgedit-ai))
  (should (= 20 (cmacs-imgedit-ai--arg "{\"delta\":20}" "delta" 0)))
  (should (= 20 (cmacs-imgedit-ai--arg "{\"delta\":\"20\"}" "delta" 0)))
  (should (= 20 (cmacs-imgedit-ai--arg "{\"delta\":20.4}" "delta" 0)))
  ;; a missing or unparseable argument falls back rather than signalling
  (should (= 5 (cmacs-imgedit-ai--arg "{}" "delta" 5)))
  (should (= 5 (cmacs-imgedit-ai--arg "not json" "delta" 5)))
  (should (equal "vertical"
                 (cmacs-imgedit-ai--arg-string
                  "{\"direction\":\"vertical\"}" "direction" "horizontal"))))

(ert-deftest cmacs-vidstudio-ai-parses-srt ()
  "SRT timings parse to seconds, with both comma and dot separators."
  (skip-unless (featurep 'cmacs-vidstudio-ai))
  (let ((f (make-temp-file "cmacs-srt" nil ".srt")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "1\n00:00:01,500 --> 00:00:04,000\nHello there\n\n"
                    "2\n00:01:02.250 --> 00:01:05.000\nSecond line\nwrapped\n\n"))
          (let ((segs (cmacs-vidstudio-ai--parse-srt f)))
            (should (= 2 (length segs)))
            (should (< (abs (- 1.5 (nth 0 (nth 0 segs)))) 0.001))
            (should (< (abs (- 4.0 (nth 1 (nth 0 segs)))) 0.001))
            (should (equal "Hello there" (nth 2 (nth 0 segs))))
            ;; 1:02.25 = 62.25s
            (should (< (abs (- 62.25 (nth 0 (nth 1 segs)))) 0.001))
            ;; a wrapped caption joins into one line
            (should (equal "Second line wrapped" (nth 2 (nth 1 segs))))))
      (delete-file f))))

(ert-deftest cmacs-vidstudio-ai-extracts-json-from-prose ()
  "Spans are found even when the model wraps them in prose and fences.

Models do this however firmly they are asked not to, and treating the
whole reply as JSON would fail on most real answers."
  (skip-unless (featurep 'cmacs-vidstudio-ai))
  (let ((spans (cmacs-vidstudio-ai--parse-spans
                "Sure! Here are the good bits:\n```json\n\
[{\"start\": 10, \"end\": 25, \"why\": \"the argument\"},
 {\"start\": 40.5, \"end\": 62, \"why\": \"the demo\"}]\n```\nHope that helps.")))
    (should (= 2 (length spans)))
    (should (= 10 (plist-get (nth 0 spans) :start)))
    (should (equal "the demo" (plist-get (nth 1 spans) :why)))))

(ert-deftest cmacs-vidstudio-ai-rejects-impossible-spans ()
  "A span that ends before it starts is dropped, not compiled.

It would become a clip of negative length, which is a corrupt timeline
rather than a bad edit."
  (skip-unless (featurep 'cmacs-vidstudio-ai))
  (let ((spans (cmacs-vidstudio-ai--parse-spans
                "[{\"start\": 30, \"end\": 10}, {\"start\": 1, \"end\": 5}]")))
    (should (= 1 (length spans)))
    (should (= 1 (plist-get (car spans) :start))))
  ;; and an empty list is a legitimate answer
  (should (null (cmacs-vidstudio-ai--parse-spans "[]")))
  (should (null (cmacs-vidstudio-ai--parse-spans "nothing useful here"))))

(ert-deftest cmacs-brigade-media-tools-registered ()
  "The media tools reach agents through the public registry."
  (skip-unless (and (featurep 'cmacs-brigade-registry)
                    (featurep 'cmacs-imgedit-ai)))
  (should (cmacs-brigade-registry-get 'tool 'imgedit-prompt))
  (should (cmacs-brigade-registry-get 'tool 'imgedit-describe))
  ;; editing someone's open document is destructive; describing it is not
  (should (cmacs-brigade-tool-destructive
           (cmacs-brigade-registry-get 'tool 'imgedit-prompt)))
  (should-not (cmacs-brigade-tool-destructive
               (cmacs-brigade-registry-get 'tool 'imgedit-describe))))

(provide 'cmacs-brigade-media-tests)

;;; cmacs-brigade-media-tests.el ends here
