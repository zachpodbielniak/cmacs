;;; cmacs-lrg-vr-hand-tests.el --- Tests for VR hand tracking -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Hand tracking needs a headset to see a hand, but everything between
;; "the runtime says the hand is pinched here" and "Emacs gets a click"
;; is the C gesture classifier (vr_gesture_step in cmacs-lrgvr.c), which
;; `cmacs-lrg-vr--simulate-hand-gestures' runs over synthetic frames.
;; These tests drive it through every gesture and check what comes out,
;; then check the Lisp half: the event names and their bindings.  The
;; joint math and pinch hysteresis underneath are libregnum's, tested by
;; its own suite (deps/libregnum/tests/test-vr-hand.c).

;;; Code:

(require 'ert)
(require 'cl-lib)

(defun cmacs-lrg-vr-hand-tests--built-p ()
  (fboundp 'cmacs-lrg-vr--simulate-hand-gestures))

(defun cmacs-lrg-vr-hand-tests--hand (pinch &rest props)
  "A hand sample: PINCH, plus PROPS over a default panel hit at (100, 100)."
  (append (list :pinch pinch)
          props
          (list :target 'panel :x 100 :y 100 :pos '(0.2 -0.3 -0.4))))

(defun cmacs-lrg-vr-hand-tests--run (&rest frames)
  "Run FRAMES, (MS LEFT RIGHT) each, through the classifier."
  (cmacs-lrg-vr--simulate-hand-gestures frames))

(defun cmacs-lrg-vr-hand-tests--kinds (actions)
  (mapcar #'car actions))

(ert-deftest cmacs-lrg-vr-hand-tap-is-a-click ()
  "A quick pinch on a panel clicks where it began."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((h #'cmacs-lrg-vr-hand-tests--hand))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 nil (funcall h nil))
                    (list 10 nil (funcall h t))
                    (list 120 nil (funcall h t :x 103 :y 102))
                    (list 200 nil (funcall h nil)))
                   '((click right 100 100))))))

(ert-deftest cmacs-lrg-vr-hand-hold-still-is-a-drag ()
  "A pinch held still on a panel becomes mouse-1 held, released on release."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((h #'cmacs-lrg-vr-hand-tests--hand))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 nil (funcall h t))
                    (list 300 nil (funcall h t))      ; not yet
                    (list 460 nil (funcall h t))      ; held: drag starts
                    (list 500 nil (funcall h t :x 160 :y 140))
                    (list 520 nil (funcall h nil)))
                   '((drag-begin right 100 100)
                     (drag-end right 160 140))))))

(ert-deftest cmacs-lrg-vr-hand-move-is-a-scroll ()
  "A pinch moved before the hold time scrolls, a wheel step per 36 px.
Moving the hand down shows what is above (DY > 0); a scroll never clicks."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let* ((h #'cmacs-lrg-vr-hand-tests--hand)
         (acts (cmacs-lrg-vr-hand-tests--run
                (list 0 nil (funcall h t))
                (list 50 nil (funcall h t :y 120))     ; 20 px: scrolling
                (list 100 nil (funcall h t :y 194))    ; +74: two steps
                (list 150 nil (funcall h t :y 200))    ; +6: none yet
                (list 900 nil (funcall h t :y 200))    ; long, still no drag
                (list 950 nil (funcall h nil)))))
    (should (equal acts '((scroll right 0 2))))))

(ert-deftest cmacs-lrg-vr-hand-empty-space-tap-and-pull ()
  "On nothing: a quick pinch is a tap; a moved one pulls the world."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((empty (lambda (pinch pos)
                 (list :pinch pinch :target nil :x 0 :y 0 :pos pos))))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 (funcall empty t '(0 0 -0.4)) nil)
                    (list 100 (funcall empty nil '(0 0 -0.4)) nil))
                   '((tap left))))
    ;; Held past the tap window and let go without moving: nothing.
    (should-not (cmacs-lrg-vr-hand-tests--run
                 (list 0 (funcall empty t '(0 0 -0.4)) nil)
                 (list 900 (funcall empty nil '(0 0 -0.4)) nil)))
    (let ((acts (cmacs-lrg-vr-hand-tests--run
                 (list 0 (funcall empty t '(0.0 0.0 -0.4)) nil)
                 (list 50 (funcall empty t '(0.0 0.05 -0.4)) nil)  ; 5 cm: pull
                 (list 100 (funcall empty t '(0.0 0.07 -0.4)) nil)
                 (list 150 (funcall empty nil '(0.0 0.07 -0.4)) nil))))
      (should (equal (cmacs-lrg-vr-hand-tests--kinds acts)
                     '(pull-begin pull-move pull-end)))
      ;; The move is the hand's travel since the pull began, in metres.
      (let ((mv (nth 1 acts)))
        (should (< (abs (- (nth 3 mv) 0.02)) 1e-4))
        (should (< (abs (nth 2 mv)) 1e-6))))))

(ert-deftest cmacs-lrg-vr-hand-keyboard-pinch-types-at-once ()
  "On the in-world keyboard a pinch is a key press straight away."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((kb (lambda (pinch) (list :pinch pinch :target 'keyboard
                                  :pos '(0 -0.3 -0.4)))))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 nil (funcall kb t))
                    (list 600 nil (funcall kb t))
                    (list 700 nil (funcall kb nil)))
                   '((key-down right) (key-up right))))))

(ert-deftest cmacs-lrg-vr-hand-workspace-tap-clicks ()
  "A tap on another workspace's panel is a click (the switch)."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((ws (lambda (pinch) (list :pinch pinch :target 'workspace
                                  :x 40 :y 50 :pos '(0 0 -0.4)))))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 (funcall ws t) nil)
                    (list 900 (funcall ws t) nil)   ; no drag on a picture
                    (list 950 (funcall ws nil) nil))
                   '((click left 40 50))))))

(ert-deftest cmacs-lrg-vr-hand-palm-up-held ()
  "A palm held up is one palm-up event; turning it back is palm-down.
A palm that only flashes up sends nothing."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((palm (lambda (up) (list :pinch nil :palm-up up :target nil
                                 :pos '(0 0 -0.4)))))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 (funcall palm t) nil)
                    (list 200 (funcall palm t) nil)
                    (list 310 (funcall palm t) nil)
                    (list 900 (funcall palm t) nil)
                    (list 1000 (funcall palm nil) nil))
                   '((palm-up left) (palm-down left))))
    (should-not (cmacs-lrg-vr-hand-tests--run
                 (list 0 (funcall palm t) nil)
                 (list 200 (funcall palm nil) nil)))))

(ert-deftest cmacs-lrg-vr-hand-two-hand-stretch-zooms ()
  "Both hands pinching on nothing zoom by the change in their distance.
Neither pinch clicks or taps, and the end reports the final ratio."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let* ((at (lambda (pinch x) (list :pinch pinch :target nil :pos (list x 0 -0.4))))
         (acts (cmacs-lrg-vr-hand-tests--run
                (list 0 (funcall at t -0.10) (funcall at nil 0.10))
                (list 10 (funcall at t -0.10) (funcall at t 0.10))  ; both pinched
                (list 20 (funcall at t -0.10) (funcall at t 0.10))  ; 0.20 m: begins
                (list 50 (funcall at t -0.15) (funcall at t 0.15))  ; 0.30 m
                (list 90 (funcall at nil -0.15) (funcall at t 0.15))
                (list 120 (funcall at nil -0.15) (funcall at nil 0.15)))))
    (should (equal (cmacs-lrg-vr-hand-tests--kinds acts)
                   '(zoom-begin zoom zoom-end)))
    (should (eq (nth 1 (car acts)) 'both))
    (should (< (abs (- (nth 2 (nth 1 acts)) 1.5)) 1e-4))
    (should (< (abs (- (nth 2 (nth 2 acts)) 1.5)) 1e-4))))

(ert-deftest cmacs-lrg-vr-hand-busy-pinch-does-not-zoom ()
  "A pinch already scrolling a panel is not the start of a stretch."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let* ((h #'cmacs-lrg-vr-hand-tests--hand)
         (empty (list :pinch t :target nil :pos '(-0.2 0 -0.4)))
         (acts (cmacs-lrg-vr-hand-tests--run
                (list 0 nil (funcall h t))
                (list 30 nil (funcall h t :y 140))          ; scrolling
                (list 60 empty (funcall h t :y 140))))) ; left joins in
    (should-not (memq 'zoom-begin (cmacs-lrg-vr-hand-tests--kinds acts)))))

(ert-deftest cmacs-lrg-vr-hand-lost-mid-drag-releases ()
  "A hand that leaves view mid-drag lets mouse-1 go; it does not click."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (let ((h #'cmacs-lrg-vr-hand-tests--hand))
    (should (equal (cmacs-lrg-vr-hand-tests--run
                    (list 0 nil (funcall h t))
                    (list 500 nil (funcall h t))
                    (list 520 nil nil))
                   '((drag-begin right 100 100) (drag-end right 100 100))))
    ;; Lost while still undecided: nothing at all.
    (should-not (cmacs-lrg-vr-hand-tests--run
                 (list 0 nil (funcall h t))
                 (list 50 nil nil)))))

(ert-deftest cmacs-lrg-vr-hand-simulate-validates ()
  "Malformed frames signal; they never reach the classifier."
  (skip-unless (cmacs-lrg-vr-hand-tests--built-p))
  (should-error (cmacs-lrg-vr--simulate-hand-gestures '((zero nil nil))))
  (should-error (cmacs-lrg-vr--simulate-hand-gestures 'not-a-list))
  (should-error (cmacs-lrg-vr--simulate-hand-gestures
                 '((0 (:pinch t :pos (a b c)) nil)))))

(ert-deftest cmacs-lrg-vr-hand-options ()
  "The hand options take booleans."
  (skip-unless (fboundp 'cmacs-lrg-vr-set-option))
  (should (eq t (cmacs-lrg-vr-set-option 'hands t)))
  (should (eq nil (cmacs-lrg-vr-set-option 'hand-joints nil)))
  (should (eq t (cmacs-lrg-vr-set-option 'hand-joints t))))

(ert-deftest cmacs-lrg-vr-hand-events-are-named ()
  "The gesture keys translate to <vr-hand-...> in every layer."
  (skip-unless (require 'cmacs-lrg-vr nil t))
  (let ((function-key-map (make-sparse-keymap)))
    (cmacs-lrg-vr--install-translations)
    (should (equal (lookup-key function-key-map [A-f32]) [vr-hand-left-palm-up]))
    (should (equal (lookup-key function-key-map [A-f33]) [vr-hand-right-palm-up]))
    (should (equal (lookup-key function-key-map [s-f32]) [vr-hand-left-palm-down]))
    (should (equal (lookup-key function-key-map [H-f33]) [vr-hand-right-pinch]))
    (should (equal (lookup-key function-key-map [A-f34]) [vr-hand-zoom-in]))
    (should (equal (lookup-key function-key-map [A-f35]) [vr-hand-zoom-out]))
    ;; With a layer from a controller in the other hand.
    (should (equal (lookup-key function-key-map
                               (vector (event-convert-list '(shift alt f32))))
                   [S-vr-hand-left-palm-up]))
    ;; The plain flicks are untouched.
    (should (equal (lookup-key function-key-map [f32]) [vr-flick-left]))))

(ert-deftest cmacs-lrg-vr-hand-events-are-bound ()
  "Every hand event has a binding to a real command, so none beeps."
  (skip-unless (require 'cmacs-lrg-vr nil t))
  (pcase-dolist (`(,_key ,_bank ,name) cmacs-lrg-vr--hand-keys)
    (let ((cmd (lookup-key cmacs-lrg-vr-mode-map (vector name))))
      (should (commandp cmd))))
  (should (eq (lookup-key cmacs-lrg-vr-mode-map [vr-hand-left-palm-up])
              #'cmacs-lrg-vr-quick-menu)))

(provide 'cmacs-lrg-vr-hand-tests)

;;; cmacs-lrg-vr-hand-tests.el ends here
