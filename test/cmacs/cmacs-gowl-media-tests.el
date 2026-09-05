;;; cmacs-gowl-media-tests.el --- Tests for gowl media keys -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-gowl-media' -- the volume, brightness and
;; media-player layer the XF86 keys are bound to under `emacs --gowl'.
;;
;; Everything here runs headless.  The parsers, the OSD renderer and
;; the bind table are pure functions of their inputs, so none of it
;; needs a compositor or the backend programs; the async process
;; plumbing is the only part that does, and it is exercised through
;; `cmacs-gowl-media--available-p' rather than by actually spawning
;; wpctl.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cmacs-gowl-media)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Volume parsing

(ert-deftest cmacs-gowl-media-test-parse-volume-plain ()
  "wpctl's ordinary output parses to a level and an unmuted flag."
  (let ((parsed (cmacs-gowl-media--parse-volume "Volume: 0.65\n")))
    (should parsed)
    (should (< (abs (- (car parsed) 0.65)) 0.001))
    (should-not (cdr parsed))))

(ert-deftest cmacs-gowl-media-test-parse-volume-muted ()
  "The [MUTED] suffix is reported without disturbing the level."
  (let ((parsed (cmacs-gowl-media--parse-volume "Volume: 0.30 [MUTED]\n")))
    (should parsed)
    (should (< (abs (- (car parsed) 0.30)) 0.001))
    (should (cdr parsed))))

(ert-deftest cmacs-gowl-media-test-parse-volume-integer ()
  "A level with no decimal point still parses."
  (let ((parsed (cmacs-gowl-media--parse-volume "Volume: 1\n")))
    (should parsed)
    (should (< (abs (- (car parsed) 1.0)) 0.001))))

(ert-deftest cmacs-gowl-media-test-parse-volume-garbage ()
  "Unrecognised output is nil, not a bogus level.
The caller distinguishes the two: nil means \"say the volume changed\"
rather than \"claim it is at 0%\"."
  (should-not (cmacs-gowl-media--parse-volume nil))
  (should-not (cmacs-gowl-media--parse-volume ""))
  (should-not (cmacs-gowl-media--parse-volume "wpctl: no such node\n")))

;;; Brightness parsing

(ert-deftest cmacs-gowl-media-test-parse-brightness ()
  "brightnessctl -m output parses to a fraction of maximum.
The level comes from current/max rather than the percentage field,
which brightnessctl rounds."
  (let ((value (cmacs-gowl-media--parse-brightness
                "amdgpu_bl1,backlight,128,50%,255")))
    (should value)
    (should (< (abs (- value (/ 128.0 255))) 0.001))))

(ert-deftest cmacs-gowl-media-test-parse-brightness-zero ()
  "A zero level is a real answer, distinct from a parse failure."
  (let ((value (cmacs-gowl-media--parse-brightness
                "intel_backlight,backlight,0,0%,1000")))
    (should value)
    (should (= value 0.0))))

(ert-deftest cmacs-gowl-media-test-parse-brightness-garbage ()
  "Short, empty or absent output is nil rather than a division by zero."
  (should-not (cmacs-gowl-media--parse-brightness nil))
  (should-not (cmacs-gowl-media--parse-brightness ""))
  (should-not (cmacs-gowl-media--parse-brightness "device,backlight,10"))
  ;; A max of zero would divide by zero if it were not guarded.
  (should-not (cmacs-gowl-media--parse-brightness "d,backlight,0,0%,0")))

;;; OSD rendering

(defmacro cmacs-gowl-media-tests--capture-osd (&rest body)
  "Run BODY with the OSD captured, returning the last (LABEL VALUE TEXT).
Deliberately does not bind `cmacs-gowl-media-osd': a caller that binds
it to nil is testing that no OSD is produced at all, and a binding
here would override theirs."
  (declare (indent 0))
  `(let* ((captured nil)
          (cmacs-gowl-media-osd-function
           (lambda (label value text)
             (setq captured (list label value text)))))
     ,@body
     captured))

(ert-deftest cmacs-gowl-media-test-osd-bar-width ()
  "The bar is exactly `cmacs-gowl-media-osd-width' cells wide."
  (let* ((cmacs-gowl-media-osd-width 10)
         (osd (cmacs-gowl-media-tests--capture-osd
                (cmacs-gowl-media--osd "Volume" 0.5)))
         (text (nth 2 osd)))
    (should (string-match-p "Volume" text))
    (should (string-match-p "50%" text))
    ;; Five filled, five empty.
    (should (string-match-p (concat (make-string 5 ?█)
                                    (make-string 5 ?░))
                            text))))

(ert-deftest cmacs-gowl-media-test-osd-clamps-over-unity ()
  "A level above 1.0 renders a full bar, not one that overruns it.
wpctl can report amplification above 100%, and the percentage still
says so -- but the bar has a fixed width."
  (let* ((cmacs-gowl-media-osd-width 10)
         (osd (cmacs-gowl-media-tests--capture-osd
                (cmacs-gowl-media--osd "Volume" 1.4)))
         (text (nth 2 osd)))
    (should (string-match-p "140%" text))
    (should (string-match-p (make-string 10 ?█) text))
    (should-not (string-match-p "░" text))))

(ert-deftest cmacs-gowl-media-test-osd-clamps-below-zero ()
  "A negative level renders an empty bar rather than erroring."
  (let* ((cmacs-gowl-media-osd-width 8)
         (osd (cmacs-gowl-media-tests--capture-osd
                (cmacs-gowl-media--osd "Volume" -0.2)))
         (text (nth 2 osd)))
    (should (string-match-p (make-string 8 ?░) text))))

(ert-deftest cmacs-gowl-media-test-osd-suffix ()
  "A state suffix such as \"muted\" is appended after the percentage."
  (let* ((osd (cmacs-gowl-media-tests--capture-osd
                (cmacs-gowl-media--osd "Volume" 0.4 "muted")))
         (text (nth 2 osd)))
    (should (string-match-p "muted" text))))

(ert-deftest cmacs-gowl-media-test-osd-no-value ()
  "With no level -- a track change -- the OSD is the label and suffix.
No bar and no percentage, because there is nothing to measure."
  (let* ((osd (cmacs-gowl-media-tests--capture-osd
                (cmacs-gowl-media--osd "Next" nil "Sabaton - Bismarck")))
         (text (nth 2 osd)))
    (should (equal text "Next: Sabaton - Bismarck"))
    (should-not (string-match-p "%" text))
    (should-not (nth 1 osd))))

(ert-deftest cmacs-gowl-media-test-osd-disabled ()
  "With `cmacs-gowl-media-osd' nil the function is never called."
  (let ((cmacs-gowl-media-osd nil))
    (should-not (cmacs-gowl-media-tests--capture-osd
                  (cmacs-gowl-media--osd "Volume" 0.5)))))

;;; Missing backends

(ert-deftest cmacs-gowl-media-test-missing-program-warns-once ()
  "An absent backend reports itself once, not once per keypress.
A media key with no backend installed is a normal state; a message on
every press would be worse than the silence it replaces."
  (let ((cmacs-gowl-media--missing nil)
        (messages 0))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _) (setq messages (1+ messages)))))
      (should-not (cmacs-gowl-media--available-p
                   "cmacs-gowl-media-no-such-program"))
      (should-not (cmacs-gowl-media--available-p
                   "cmacs-gowl-media-no-such-program"))
      (should-not (cmacs-gowl-media--available-p
                   "cmacs-gowl-media-no-such-program")))
    (should (= messages 1))))

(ert-deftest cmacs-gowl-media-test-run-missing-program-returns-nil ()
  "Running an absent backend is nil, not a process or an error."
  (let ((cmacs-gowl-media--missing '("cmacs-gowl-media-no-such-program")))
    (should-not (cmacs-gowl-media--run
                 "cmacs-gowl-media-no-such-program" '("x")))))

;;; The bind table

(ert-deftest cmacs-gowl-media-test-keybind-table-shape ()
  "Every entry is (KEY COMMAND DESCRIPTION) with a bound command."
  (dolist (entry cmacs-gowl-media-keybinds)
    (should (= (length entry) 3))
    (should (stringp (nth 0 entry)))
    (should (string-prefix-p "XF86" (nth 0 entry)))
    (should (fboundp (nth 1 entry)))
    (should (stringp (nth 2 entry)))
    (should-not (string-empty-p (nth 2 entry)))))

(ert-deftest cmacs-gowl-media-test-keybind-keys-unique ()
  "No key is bound twice -- gowl dispatches the first match, so a
duplicate would silently shadow the later entry."
  (let ((keys (mapcar #'car cmacs-gowl-media-keybinds)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))))

(ert-deftest cmacs-gowl-media-test-keysyms-resolve ()
  "Every media keysym in the table is one gowl can actually parse.
A typo here would fail at bind time in a live session and nowhere
else; `gowl-add-keybind' errors on an unknown keysym."
  (skip-unless (cmacs-feature-p 'gowl))
  (skip-unless (gowl-running-p))
  (dolist (entry cmacs-gowl-media-keybinds)
    (should (gowl-add-keybind (nth 0 entry) 'none nil "test probe"))
    (gowl-remove-keybind (nth 0 entry))))

(provide 'cmacs-gowl-media-tests)

;;; cmacs-gowl-media-tests.el ends here
