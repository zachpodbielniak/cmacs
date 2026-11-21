;;; cmacs-rig-inputremap-tests.el --- Controller remapping in a rig  -*- lexical-binding: t; -*-

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

;; Game controllers and virtual pads (deps/gowl/docs/input-remap.org)
;; through the Elisp surface of a real `cmacs --gowl' child
;; (cmacs-rig.el), on its headless backend:
;;
;;   inputremap-pads-surface
;;     The module answers `inputremap-pads' and reports `pads=' in its
;;     status.  Needs the gowl of this change in the child's binary and
;;     skips, saying so, when the child's gowl predates it.
;;
;;   inputremap-pad-rule-round-trip
;;     A rule defined from Elisp with :grab, :analog, :virtual-pad and
;;     stick/pointer targets is accepted by the child's module, listed
;;     with its virtual pad and its continuous targets, and removed.
;;
;;   inputremap-pad-is-lazy
;;     Defining a rule that declares a virtual pad makes NO uinput
;;     device (they are created on the first press), and removing it
;;     leaves none: /proc/bus/input/devices holds no pad named for the
;;     rig before, during or after.
;;
;; The pad is named "cmacs-rig test pad" and the rules match vendor
;; 1209 (pid.codes' test range) with product 000a, an id no real rule
;; would name -- the live session's own inputremap would only ever open
;; such a device if one of the user's rules matched it.  The end-to-end
;; uinput path (a real source pad read, a virtual pad read back) is
;; gowl's own test-input-remap-gamepad; a rig child cannot press a key
;; on a claimed keyboard, since injected keys never pass a claim.
;;
;; Run with
;;
;;   CMACS_RIG=1 src/emacs --batch -Q -L lisp/cmacs -L test/cmacs \
;;     --eval '(setq load-prefer-newer t)' -l ert \
;;     -l test/cmacs/cmacs-rig-inputremap-tests.el -f ert-run-tests-batch-and-exit
;;
;; Without CMACS_RIG every test skips.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'cmacs)
;; Beside this file, and named by its place: `make check' runs with
;; test/cmacs off `load-path'.
(require 'cmacs-rig
         (expand-file-name
          "cmacs-rig"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

;;;; Fixture

(defvar cmacs-rig-inputremap-tests--rig nil
  "The rig this file's tests share.")

(defconst cmacs-rig-inputremap-tests--pad "cmacs-rig test pad"
  "The virtual pad the rules here declare.")

(defun cmacs-rig-inputremap-tests--rig ()
  "Return the shared rig, starting it; skip when rigs are not asked for."
  (unless (getenv "CMACS_RIG")
    (ert-skip "rig tests run only with CMACS_RIG=1"))
  (when-let* ((why (cmacs-rig-available-p)))
    (ert-skip (format "no rig here: %s" why)))
  (unless (and cmacs-rig-inputremap-tests--rig
               (cmacs-rig-alive-p cmacs-rig-inputremap-tests--rig))
    (setq cmacs-rig-inputremap-tests--rig
          (condition-case err
              (cmacs-rig-start)
            (cmacs-rig-error
             (ert-skip (format "the rig would not start: %s" (cadr err)))))))
  cmacs-rig-inputremap-tests--rig)

(defun cmacs-rig-inputremap-tests--command (rig line)
  "Run module command LINE in RIG's compositor; return the reply."
  (cmacs-rig-eval rig `(progn (require 'cmacs-gowl-input-remap)
                              (unless cmacs-gowl-input-remap--enabled
                                (cmacs-gowl-input-remap-enable))
                              (gowl-run-command ,line))))

(defun cmacs-rig-inputremap-tests--require-pads (rig)
  "Skip unless RIG's gowl knows virtual pads."
  (let ((reply (cmacs-rig-inputremap-tests--command rig "inputremap-pads")))
    (unless (and (stringp reply) (string-prefix-p "OK" reply))
      (ert-skip (format "the child's gowl predates virtual pads: %S" reply)))
    reply))

(defun cmacs-rig-inputremap-tests--pads-in-kernel ()
  "How many of this file's virtual pads /proc/bus/input/devices lists."
  (if (not (file-readable-p "/proc/bus/input/devices"))
      0
    (with-temp-buffer
      (insert-file-contents "/proc/bus/input/devices")
      (how-many (regexp-quote (concat "gowl virtual pad: "
                                      cmacs-rig-inputremap-tests--pad))
                (point-min) (point-max)))))

(defun cmacs-rig-inputremap-tests--reset (rig)
  "Remove this file's rules from RIG."
  (when (cmacs-rig-alive-p rig)
    (ignore-errors
      (cmacs-rig-eval rig '(progn
                             (require 'cmacs-gowl-input-remap)
                             (ignore-errors
                               (cmacs-gowl-input-remap-remove "rig-pad"))
                             (ignore-errors
                               (cmacs-gowl-input-remap-remove "rig-stick"))
                             t)))))

(defmacro cmacs-rig-inputremap-tests--deftest (name docstring &rest body)
  "Define cmacs-rig-inputremap-test-NAME with `rig' bound; reset after."
  (declare (indent 1) (doc-string 2))
  `(ert-deftest ,(intern (format "cmacs-rig-inputremap-test-%s" name)) ()
     ,docstring
     (let ((rig (cmacs-rig-inputremap-tests--rig)))
       (unwind-protect (progn ,@body)
         (cmacs-rig-inputremap-tests--reset rig))
       (should (cmacs-rig-alive-p rig)))))

;;;; Tests

(cmacs-rig-inputremap-tests--deftest inputremap-pads-surface
  "The module answers `inputremap-pads' and counts pads in its status."
  (let ((pads (cmacs-rig-inputremap-tests--require-pads rig))
        (status (cmacs-rig-inputremap-tests--command rig "inputremap-status")))
    (should (string-prefix-p "OK [" pads))
    (should (string-match-p " pads=[0-9]+" status))))

(cmacs-rig-inputremap-tests--deftest inputremap-pad-rule-round-trip
  "A controller rule defined from Elisp is accepted, listed and removed."
  (cmacs-rig-inputremap-tests--require-pads rig)
  (let ((listed
         (cmacs-rig-eval
          rig
          `(progn
             (require 'cmacs-gowl-input-remap)
             (cmacs-gowl-input-remap-define
              "rig-stick"
              :match '(:id "1209:000a" :type gamepad)
              :analog '(:pointer-speed 900 :press 0.6 :release 0.3)
              :map '((right-stick-x . (pointer x))
                     (left-stick-up . (key KEY_W))))
             (cmacs-gowl-input-remap-define
              "rig-pad"
              :match '(:id "1209:000a" :type keyboard)
              :virtual-pad ,cmacs-rig-inputremap-tests--pad
              :map '((KEY_W . (stick left :y -1))
                     (KEY_SPACE . (pad-button BTN_SOUTH))))
             (mapcar (lambda (r)
                       (list (alist-get 'name r)
                             (alist-get 'virtual-pad r)
                             (alist-get 'continuous r)))
                     (cmacs-gowl-input-remap-list))))))
    (should (member (list "rig-stick" nil '("ABS_RX: {pointer: x}")) listed))
    (should (member (list "rig-pad" cmacs-rig-inputremap-tests--pad nil)
                    listed))
    (cmacs-rig-eval rig '(progn (cmacs-gowl-input-remap-remove "rig-stick")
                                (cmacs-gowl-input-remap-remove "rig-pad")
                                t))
    (should-not (cl-some (lambda (r) (member (car r) '("rig-stick" "rig-pad")))
                         (cmacs-rig-eval
                          rig '(mapcar (lambda (r) (list (alist-get 'name r)))
                                       (cmacs-gowl-input-remap-list)))))))

(cmacs-rig-inputremap-tests--deftest inputremap-pad-is-lazy
  "Declaring a virtual pad creates no device; removing the rule leaves none."
  (cmacs-rig-inputremap-tests--require-pads rig)
  (let ((before (cmacs-rig-inputremap-tests--pads-in-kernel)))
    (should (= before 0))
    (cmacs-rig-eval
     rig `(progn
            (require 'cmacs-gowl-input-remap)
            (cmacs-gowl-input-remap-define
             "rig-pad"
             :match '(:id "1209:000a" :type keyboard)
             :virtual-pad ,cmacs-rig-inputremap-tests--pad
             :map '((KEY_W . (stick left :y -1))))
            t))
    (should (= (cmacs-rig-inputremap-tests--pads-in-kernel) 0))
    ;; the module knows of no created pad: nothing was pressed
    (should-not (string-match-p
                 "\"created\":true"
                 (cmacs-rig-inputremap-tests--command rig "inputremap-pads")))
    (cmacs-rig-eval rig '(progn (cmacs-gowl-input-remap-remove "rig-pad") t))
    (should (= (cmacs-rig-inputremap-tests--pads-in-kernel) 0))))

(provide 'cmacs-rig-inputremap-tests)

;;; cmacs-rig-inputremap-tests.el ends here
