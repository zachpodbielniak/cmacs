;;; cmacs-brigade-deliver-tests.el --- Deliverables  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-deliver nil 'noerror)

(defun cmacs-brigade-deliver-tests--available-p ()
  (featurep 'cmacs-brigade-deliver))

(defmacro cmacs-brigade-deliver-tests--with-org (text &rest body)
  "Run BODY in an org buffer containing TEXT, bound as BUF."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer " *deliver-test*")))
     (unwind-protect
         (with-current-buffer buf
           (insert ,text)
           (org-mode)
           ,@body)
       (kill-buffer buf))))

(ert-deftest cmacs-brigade-deliver-all-registered ()
  "All four deliverables go through the public registry."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (dolist (k '(sparkpage slides pod clip))
    (let ((d (cmacs-brigade-registry-get 'deliverable k)))
      (should d)
      (should (functionp (plist-get d :render))))))

(ert-deftest cmacs-brigade-deliver-unknown-kind-refused ()
  "An unregistered kind is refused rather than half-rendered."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (should-error (cmacs-brigade-deliver 'no-such-kind "/tmp/x.org")
                :type 'cmacs-brigade-deliver-error))

(ert-deftest cmacs-brigade-deliver-sparkpage-requires-citations ()
  "An uncited claim fails the export.

Not advisory: a research artifact whose citations are optional is one
whose citations are decorative, and the reason to produce a cited report
rather than a summary is that the claims can be checked."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (cmacs-brigade-deliver-tests--with-org
      "#+title: T\n\nThe quarterly revenue figure rose substantially over the period.\n"
    (let ((problems (cmacs-brigade-deliver--lint-sparkpage buf)))
      (should problems)
      (should (cl-some (lambda (p) (string-match-p "no citation" p)) problems)))))

(ert-deftest cmacs-brigade-deliver-sparkpage-accepts-cited ()
  "A claim carrying a citation to a declared source passes."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (cmacs-brigade-deliver-tests--with-org
      "#+title: T\n#+BRIGADE_SOURCE: src1\n\nThe quarterly revenue figure rose substantially over the period. [[cite:src1]]\n"
    (should-not (cmacs-brigade-deliver--lint-sparkpage buf))))

(ert-deftest cmacs-brigade-deliver-sparkpage-rejects-phantom-source ()
  "Citing a source that was never declared is caught.

This one reads as *more* trustworthy than an uncited claim and is worse:
the reader sees a citation and stops checking."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (cmacs-brigade-deliver-tests--with-org
      "#+title: T\n#+BRIGADE_SOURCE: src1\n\nSomething. [[cite:src2]]\n"
    (let ((problems (cmacs-brigade-deliver--lint-sparkpage buf)))
      (should (cl-some (lambda (p) (string-match-p "not declared" p))
                       problems)))))

(ert-deftest cmacs-brigade-deliver-slides-validate-layouts ()
  "An unknown :LAYOUT: is reported before anything is rendered."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (cmacs-brigade-deliver-tests--with-org
      "* Slide one\n  :PROPERTIES:\n  :LAYOUT: bullets\n  :END:\n  Body.\n
* Slide two\n  :PROPERTIES:\n  :LAYOUT: interpretive-dance\n  :END:\n  Body.\n"
    (let ((problems (cmacs-brigade-deliver--lint-slides buf)))
      (should (= 1 (length problems)))
      (should (string-match-p "interpretive-dance" (car problems))))))

(ert-deftest cmacs-brigade-deliver-pod-turns ()
  "Pod turns parse with their voices, and empty ones are dropped."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (cmacs-brigade-deliver-tests--with-org
      "* Turn\n  :PROPERTIES:\n  :VOICE: a\n  :END:\n  First thing.\n
* Turn\n  :PROPERTIES:\n  :VOICE: b\n  :END:\n  Second thing.\n
* Empty\n  :PROPERTIES:\n  :VOICE: a\n  :END:\n"
    (let ((turns (cmacs-brigade-deliver--pod-turns buf)))
      (should (= 2 (length turns)))
      (should (equal "a" (car (nth 0 turns))))
      (should (equal "b" (car (nth 1 turns))))
      (should (string-match-p "First thing" (cdr (nth 0 turns)))))))

(ert-deftest cmacs-brigade-deliver-clip-validates-source ()
  "A clip refuses a source that is not a readable recording."
  (skip-unless (cmacs-brigade-deliver-tests--available-p))
  (should (cmacs-brigade-deliver--lint-clip "/nonexistent/x.mp4"))
  (should (cmacs-brigade-deliver--lint-clip nil)))

(ert-deftest cmacs-brigade-deliver-tool-reports-refusal ()
  "The tool reports a refusal instead of signalling.

An agent that can read why its document was rejected can fix it; one
that gets an exception cannot."
  (skip-unless (and (cmacs-brigade-deliver-tests--available-p)
                    (fboundp 'cmacs-brigade-call-tool)))
  (let ((out (cmacs-brigade-call-tool
              "deliverable_emit"
              "{\"kind\":\"clip\",\"source\":\"/nonexistent/x.mp4\"}")))
    (should (string-match-p "Refused\\|Error" out))))

(provide 'cmacs-brigade-deliver-tests)

;;; cmacs-brigade-deliver-tests.el ends here
