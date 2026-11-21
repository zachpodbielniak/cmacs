;;; cmacs-gowl-input-remap-pad-tests.el --- Game controllers in the Elisp remap surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The new rule shapes `cmacs-gowl-input-remap-rule-json' writes for
;; gowl's inputremap module: game-controller inputs, the pointer and
;; scroll targets, virtual-pad targets, `:grab', `:analog' and
;; `:virtual-pad' -- and the refusals that happen in Elisp before
;; anything is sent.  Pure: no compositor, nothing sent.  The module
;; side of the same shapes is gowl's test-input-remap-pad-rule.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-gowl-input-remap)

(defun cmacs-gowl-input-remap-pad-tests--rule (&rest plist)
  "The rule PLIST becomes, parsed back into alists."
  (json-parse-string (apply #'cmacs-gowl-input-remap-rule-json "t" plist)
                     :object-type 'alist :array-type 'list
                     :false-object nil))

(ert-deftest cmacs-gowl-input-remap-pad-test-stick-as-keys ()
  "A gamepad rule: directions to keys, grab, analog settings."
  (let* ((rule (cmacs-gowl-input-remap-pad-tests--rule
                :match '(:id "045e:028e" :type gamepad)
                :grab t
                :analog '(:press 0.6 :release 0.3 :invert (ABS_Y))
                :map '((left-stick-up . (key KEY_W))
                       (ABS_X+ . (key KEY_D))
                       (pad-a . (key KEY_SPACE)))))
         (map (alist-get 'map rule)))
    (should (equal (alist-get 'match rule)
                   '((id . "045e:028e") (type . "gamepad"))))
    (should (eq (alist-get 'grab rule) t))
    (should (equal (alist-get 'analog rule)
                   '((press . 0.6) (release . 0.3) (invert "ABS_Y"))))
    (should (equal (alist-get 'left-stick-up map) '((key . "KEY_W"))))
    (should (equal (alist-get 'ABS_X+ map) '((key . "KEY_D"))))))

(ert-deftest cmacs-gowl-input-remap-pad-test-continuous-targets ()
  "Pointer and scroll targets are one value each."
  (let ((map (alist-get 'map (cmacs-gowl-input-remap-pad-tests--rule
                              :match '(:name "*Pad*")
                              :map '((right-stick-x . (pointer x))
                                     (ABS_RY . (scroll vertical)))))))
    (should (equal (alist-get 'right-stick-x map) '((pointer . "x"))))
    (should (equal (alist-get 'ABS_RY map) '((scroll . "vertical"))))))

(ert-deftest cmacs-gowl-input-remap-pad-test-virtual-pad ()
  "Keys onto a virtual pad: sticks, a trigger, a button, the mouse."
  (let* ((rule (cmacs-gowl-input-remap-pad-tests--rule
                :match '(:id "1234:5678" :type keyboard)
                :virtual-pad '(:name "keypad" :id "1209:0042"
                                     :buttons (BTN_SOUTH BTN_EAST))
                :map '((KEY_KP8 . (stick left :y -1))
                       (KEY_KP6 . (stick left :x 1))
                       (KEY_KP7 . (stick dpad :x -1))
                       (KEY_KPENTER . (trigger right))
                       (KEY_KPPLUS . (trigger left 0.5))
                       (KEY_KP0 . (pad-button BTN_SOUTH))
                       (mouse-x . (stick right)))))
         (map (alist-get 'map rule)))
    (should (equal (alist-get 'virtual-pad rule)
                   '((name . "keypad") (id . "1209:0042")
                     (buttons "BTN_SOUTH" "BTN_EAST"))))
    (should (equal (alist-get 'KEY_KP8 map) '((stick . "left") (y . -1.0))))
    (should (equal (alist-get 'KEY_KP6 map) '((stick . "left") (x . 1.0))))
    (should (equal (alist-get 'KEY_KP7 map) '((stick . "dpad") (x . -1.0))))
    (should (equal (alist-get 'KEY_KPENTER map) '((trigger . "right"))))
    (should (equal (alist-get 'KEY_KPPLUS map)
                   '((trigger . "left") (value . 0.5))))
    (should (equal (alist-get 'KEY_KP0 map) '((pad-button . "BTN_SOUTH"))))
    (should (equal (alist-get 'mouse-x map) '((stick . "right"))))
    ;; a bare name is a pad too
    (should (equal (alist-get 'virtual-pad
                              (cmacs-gowl-input-remap-pad-tests--rule
                               :match '(:name "k") :virtual-pad "game"))
                   '((name . "game"))))))

(ert-deftest cmacs-gowl-input-remap-pad-test-refusals ()
  "Shapes that are more than one output, or malformed, never leave Elisp."
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k")
                 :map '((KEY_A . (stick left :x 1 :y 1))))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k")
                 :map '((KEY_A . (stick up :x 1))))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k")
                 :map '((KEY_A . (stick left :x 1 :repeat 3))))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k")
                 :map '((KEY_A . (trigger dpad))))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k") :analog '(:wobble 1))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k") :virtual-pad '(:id "1209:0001"))
                :type 'user-error)
  (should-error (cmacs-gowl-input-remap-rule-json
                 "t" :match '(:name "k")
                 :map '((KEY_A . (pointer x y))))
                :type 'user-error))

(ert-deftest cmacs-gowl-input-remap-pad-test-pads-command ()
  "`cmacs-gowl-input-remap-pads' asks the module for `inputremap-pads'."
  (let (sent)
    (cl-letf (((symbol-function 'cmacs-gowl-input-remap--command)
               (lambda (line &rest _)
                 (setq sent line)
                 "[{\"name\":\"game\",\"created\":true,\"failed\":false,\"holds\":0}]")))
      (let ((pads (cmacs-gowl-input-remap-pads)))
        (should (equal sent "inputremap-pads"))
        (should (equal (alist-get 'name (car pads)) "game"))
        (should (eq (alist-get 'created (car pads)) t))))))

(provide 'cmacs-gowl-input-remap-pad-tests)

;;; cmacs-gowl-input-remap-pad-tests.el ends here
