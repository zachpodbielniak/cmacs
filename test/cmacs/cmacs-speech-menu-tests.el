;;; cmacs-speech-menu-tests.el --- ERT for the right-click Speech menu  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The menu is built as data (a keymap) and inspected with the
;; `cmacs-media-menu' helpers, over fake engines, so it runs anywhere.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs-speech-menu)

(defmacro cmacs-speech-menu-test--engines (components &rest body)
  "Run BODY with one fake engine serving COMPONENTS."
  (declare (indent 1) (debug t))
  `(let ((cmacs-speech--backends (make-hash-table :test 'eq))
         (cmacs-speech-backend-order nil)
         (cmacs-speech-config nil) (cmacs-speech-override nil)
         (cmacs-speech--session nil) (cmacs-speech--ui nil) (cmacs-speech--ui-loaded t)
         (cmacs-speech-auto-preference nil))
     (cmacs-speech-define-backend
      'fake :components ,components
      :default-model (lambda (_c) "m") :models (lambda (_c) '("m" "m2"))
      :transcribe #'ignore :synthesize #'ignore :run #'ignore)
     ,@body))

(defun cmacs-speech-menu-test--labels (ctx)
  "Top-level labels of the Speech menu for CTX."
  (let ((map (cmacs-speech-menu-keymap ctx)))
    (and map (cmacs-media-menu-labels map))))

(ert-deftest cmacs-speech-menu-test-region-items ()
  (cmacs-speech-menu-test--engines '(tts punctuate)
    (with-temp-buffer
      (insert "hello there. general kenobi")
      (let ((labels (cmacs-speech-menu-test--labels
                     (list :buffer (current-buffer) :point 1 :region '(1 . 12)
                           :text "hello there"))))
        (should (member "Speak selection" labels))
        (should (member "Speak with voice" labels))
        (should (member "Add punctuation" labels))
        (should (member "Speech settings…" labels))))))

(ert-deftest cmacs-speech-menu-test-gated-on-engines ()
  "Nothing is offered that cannot run: no TTS, no Speak."
  (cmacs-speech-menu-test--engines '(stt)
    (with-temp-buffer
      (let ((labels (cmacs-speech-menu-test--labels
                     (list :buffer (current-buffer) :region '(1 . 2) :text "x"))))
        (should-not (member "Speak selection" labels))
        (should-not (member "Add punctuation" labels))
        (should (member "Speech settings…" labels))))))

(ert-deftest cmacs-speech-menu-test-file-items ()
  (cmacs-speech-menu-test--engines '(stt diarize lang-id audio-tag denoise separate tts)
    (let ((f (make-temp-file "talk" nil ".mp3" "x")))
      (unwind-protect
          (with-temp-buffer
            (let* ((map (cmacs-speech-menu-keymap
                         (list :buffer (current-buffer) :file f :text "a sentence")))
                   (labels (cmacs-media-menu-labels map)))
              (should (member "Transcribe" labels))
              (should (member "Who spoke? (speaker-labelled transcript)" labels))
              (should (member "Detect language" labels))
              (should (member "What's in this audio?" labels))
              (should (member "Clean up noise → new file" labels))
              (should (member "Split vocals / accompaniment" labels))
              ;; A file and no region: prose items stay out of the way.
              (should-not (member "Speak sentence" labels))
              (let ((sub (plist-get (cmacs-media-menu-lookup map "Transcribe") :submenu)))
                (should (member "As an org note" (cmacs-media-menu-labels sub)))
                (should (member "With model" (cmacs-media-menu-labels sub))))))
        (delete-file f)))))

(ert-deftest cmacs-speech-menu-test-media-detection ()
  (let ((f (make-temp-file "clip" nil ".WAV" "x"))
        (g (make-temp-file "doc" nil ".txt" "x")))
    (unwind-protect
        (progn
          (should (cmacs-speech-menu--media-p f))
          (should-not (cmacs-speech-menu--media-p g))
          (should-not (cmacs-speech-menu--media-p "/nonexistent/x.mp3"))
          (with-temp-buffer
            (insert f)
            (goto-char 2)
            (should (equal (cmacs-speech-menu--file-at-point) f))))
      (delete-file f) (delete-file g))))

(ert-deftest cmacs-speech-menu-test-dired-context ()
  (let* ((dir (make-temp-file "speech-dired" t))
         (f (expand-file-name "a.flac" dir)))
    (unwind-protect
        (progn
          (with-temp-file f (insert "x"))
          (let ((buf (dired-noselect dir)))
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-min))
                  (search-forward "a.flac")
                  (should (equal (plist-get (cmacs-speech-menu-context) :file) f)))
              (kill-buffer buf))))
      (delete-directory dir t))))

(ert-deftest cmacs-speech-menu-test-provider-hook ()
  "Anyone can add items with `add-hook'; a broken provider costs only itself."
  (cmacs-speech-menu-test--engines '(tts)
    (let ((cmacs-speech-context-menu-functions
           (list (lambda (_c) (list (list :label "Mine" :action #'ignore)))
                 (lambda (_c) (error "Broken provider"))))
          (inhibit-message t))
      (should (member "Mine" (cmacs-speech-menu-test--labels
                              (list :buffer (current-buffer))))))))

(ert-deftest cmacs-speech-menu-test-srt ()
  (should (equal (cmacs-speech-menu--clock 3723456) "01:02:03,456"))
  (should (string-match-p "\\`1\n00:00:00,000 --> 00:00:01,500\nHi\n\\'"
                          (cmacs-speech-menu--srt '(((:start . 0) (:end . 1500) (:text . " Hi ")))))))

(ert-deftest cmacs-speech-menu-test-speaker-labels ()
  "Transcript segments take the speaker they overlap most; numbering is
by first appearance, not the diarizer's cluster ids; runs merge."
  (let ((turns '(((:start . 0) (:end . 5000) (:speaker . 3))
                 ((:start . 5000) (:end . 9000) (:speaker . 0))))
        (segs '(((:start . 0) (:end . 2000) (:text . "one"))
                ((:start . 2000) (:end . 4800) (:text . "two"))
                ((:start . 5100) (:end . 8000) (:text . "three")))))
    (should (equal (cmacs-speech-menu-label-speakers turns segs)
                   "- *Speaker 1* [00:00:00] one two\n- *Speaker 2* [00:00:05] three"))))

(provide 'cmacs-speech-menu-tests)
;;; cmacs-speech-menu-tests.el ends here
