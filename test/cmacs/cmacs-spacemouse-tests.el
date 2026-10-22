;;; cmacs-spacemouse-tests.el --- Tests for SpaceMouse / 6DOF input -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; No device and no spacenavd are needed: the tests play the daemon
;; themselves, on a Unix socket of their own, speaking its wire format
;; (built by `cmacs-spacemouse--packet' so the byte order is the
;; machine's).  That covers the whole read path -- connect, GSource on
;; the GLib loop, packet framing, decoding, end of file -- and the axis
;; shaping, the options, the targets and the Lisp event names.  What it
;; cannot cover is a real cap's axis directions; see the docs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)

(defun cmacs-spacemouse-tests--built-p ()
  (fboundp 'cmacs-spacemouse-start))

(defmacro cmacs-spacemouse-tests--with-defaults (&rest body)
  "Run BODY with the shaping options at their defaults, and restore them."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (cmacs-spacemouse-set-option 'sensitivity 1.0)
         (cmacs-spacemouse-set-option 'translation-scale 1.0)
         (cmacs-spacemouse-set-option 'rotation-scale 1.0)
         (cmacs-spacemouse-set-option 'deadzone 0.06)
         (cmacs-spacemouse-set-option 'full-scale 350)
         (cmacs-spacemouse-set-option 'invert nil)
         (cmacs-spacemouse-set-option 'dominant nil)
         ,@body)
     (cmacs-spacemouse-set-option 'sensitivity 1.0)
     (cmacs-spacemouse-set-option 'translation-scale 1.0)
     (cmacs-spacemouse-set-option 'rotation-scale 1.0)
     (cmacs-spacemouse-set-option 'deadzone 0.06)
     (cmacs-spacemouse-set-option 'full-scale 350)
     (cmacs-spacemouse-set-option 'invert nil)
     (cmacs-spacemouse-set-option 'dominant nil)
     (cmacs-spacemouse-set-target 'auto)))

(defun cmacs-spacemouse-tests--near (a b)
  (< (abs (- a b)) 1e-4))

(ert-deftest cmacs-spacemouse-feature-flag-matches-the-build ()
  "IS-CMACS-SPACEMOUSE is always bound and agrees with the primitives."
  (should (boundp 'IS-CMACS-SPACEMOUSE))
  (should (boundp 'is-cmacs-spacemouse))
  (should (eq (and IS-CMACS-SPACEMOUSE t)
              (and (cmacs-spacemouse-tests--built-p) t)))
  (when IS-CMACS-SPACEMOUSE
    (should (memq 'spacemouse (cmacs-compiled-features)))))

(ert-deftest cmacs-spacemouse-shape-deadzone-and-scale ()
  "Rest is still, full deflection is 1, and the deadzone has no step."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (cmacs-spacemouse-tests--with-defaults
    ;; Drift inside the deadzone (6% of 350 = 21) moves nothing.
    (should (equal (cmacs-spacemouse--shape 10 -15 20 0 5 -20)
                   [0.0 0.0 0.0 0.0 0.0 0.0]))
    ;; Full push right / up; pushing the cap away (-Z) is forward.
    (let ((v (cmacs-spacemouse--shape 350 350 -350 0 0 0)))
      (should (cmacs-spacemouse-tests--near (aref v 0) 1.0))
      (should (cmacs-spacemouse-tests--near (aref v 1) 1.0))
      (should (cmacs-spacemouse-tests--near (aref v 2) 1.0)))
    ;; Beyond full scale clamps.
    (should (cmacs-spacemouse-tests--near
             (aref (cmacs-spacemouse--shape 9000 0 0 0 0 0) 0) 1.0))
    ;; Just past the deadzone is just above zero, not a jump to 0.06.
    (let ((x (aref (cmacs-spacemouse--shape 22 0 0 0 0 0) 0)))
      (should (> x 0.0))
      (should (< x 0.01)))
    ;; Halfway through the live range is half speed.
    (should (< (abs (- (aref (cmacs-spacemouse--shape 0 0 0 0 186 0) 4) 0.5))
               0.01))))

(ert-deftest cmacs-spacemouse-shape-options ()
  "Sensitivity, per-group scales, inversion and the dominant axis."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (cmacs-spacemouse-tests--with-defaults
    (cmacs-spacemouse-set-option 'sensitivity 2.0)
    (cmacs-spacemouse-set-option 'rotation-scale 0.5)
    (let ((v (cmacs-spacemouse--shape 350 0 0 350 0 0)))
      (should (cmacs-spacemouse-tests--near (aref v 0) 2.0))
      (should (cmacs-spacemouse-tests--near (aref v 3) 1.0)))
    (cmacs-spacemouse-set-option 'sensitivity 1.0)
    (cmacs-spacemouse-set-option 'rotation-scale 1.0)
    (cmacs-spacemouse-set-option 'invert '(tx ry))
    (let ((v (cmacs-spacemouse--shape 350 0 0 0 350 0)))
      (should (cmacs-spacemouse-tests--near (aref v 0) -1.0))
      (should (cmacs-spacemouse-tests--near (aref v 4) -1.0)))
    (cmacs-spacemouse-set-option 'invert nil)
    (cmacs-spacemouse-set-option 'dominant t)
    (let ((v (cmacs-spacemouse--shape 200 0 -300 100 0 0)))
      (should (equal (aref v 0) 0.0))
      (should (> (aref v 2) 0.0))         ; the strongest axis survives
      (should (equal (aref v 3) 0.0)))
    (cmacs-spacemouse-set-option 'deadzone 0.0)
    (should (> (aref (cmacs-spacemouse--shape 0 0 0 0 0 1) 5) 0.0))))

(ert-deftest cmacs-spacemouse-options-validate ()
  "Options refuse what they cannot use."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (cmacs-spacemouse-tests--with-defaults
    (should-error (cmacs-spacemouse-set-option 'no-such-option 1))
    (should-error (cmacs-spacemouse-set-option 'sensitivity "fast")
                  :type 'wrong-type-argument)
    (should-error (cmacs-spacemouse-set-option 'deadzone 1.5)
                  :type 'args-out-of-range)
    (should-error (cmacs-spacemouse-set-option 'full-scale 0)
                  :type 'args-out-of-range)
    (should-error (cmacs-spacemouse-set-option 'invert '(tx sideways))
                  :type 'wrong-type-argument)
    (should (equal (cmacs-spacemouse-set-option 'invert '(rz)) '(rz)))))

(ert-deftest cmacs-spacemouse-targets ()
  "Targets are auto, none or a buffer; nothing else."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (cmacs-spacemouse-tests--with-defaults
    (should (eq (cmacs-spacemouse-set-target 'none) 'none))
    (should (eq (plist-get (cmacs-spacemouse-status) :target) 'none))
    (with-temp-buffer
      (should (eq (cmacs-spacemouse-set-target (current-buffer))
                  (current-buffer))))
    (should-error (cmacs-spacemouse-set-target 'sideways)
                  :type 'wrong-type-argument)
    (should (eq (cmacs-spacemouse-set-target 'auto) 'auto))))

(ert-deftest cmacs-spacemouse-motion-without-a-scene-moves-nothing ()
  "In batch there is no 3D scene, VR session or lrg frame: motion is a no-op.
It is still counted, and never signals."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (cmacs-spacemouse-tests--with-defaults
    (let ((before (plist-get (cmacs-spacemouse-status) :motion-events)))
      (should-not (cmacs-spacemouse--inject '(motion 300 0 0 0 200 0 16)))
      (cmacs-spacemouse-set-target 'none)
      (should-not (cmacs-spacemouse--inject '(motion 300 0 0 0 200 0)))
      ;; A buffer that shows no scene is not moved either.
      (with-temp-buffer
        (cmacs-spacemouse-set-target (current-buffer))
        (should-not (cmacs-spacemouse--inject '(motion 0 0 -300 0 0 0))))
      (should (= (plist-get (cmacs-spacemouse-status) :motion-events)
                 (+ before 3))))
    (should-error (cmacs-spacemouse--inject '(motion 1 2)))
    (should-error (cmacs-spacemouse--inject '(wiggle)))))

(ert-deftest cmacs-spacemouse-buttons-count-and-validate ()
  "Buttons are counted; numbers out of range are refused."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (let ((before (plist-get (cmacs-spacemouse-status) :button-events)))
    (cmacs-spacemouse--inject '(button 0 t))
    (cmacs-spacemouse--inject '(button 0 nil))
    (should (= (plist-get (cmacs-spacemouse-status) :button-events)
               (+ before 2))))
  (should-error (cmacs-spacemouse--inject '(button -1 t)))
  (should-error (cmacs-spacemouse--inject '(button 4096 t))))

(ert-deftest cmacs-spacemouse-buttons-are-named ()
  "Button keystrokes translate to <spacemouse-N> and their releases."
  (skip-unless (and (cmacs-spacemouse-tests--built-p)
                    (require 'cmacs-spacemouse nil t)))
  (let ((function-key-map (make-sparse-keymap)))
    (cmacs-spacemouse--install-translations)
    (should (equal (lookup-key function-key-map
                               (vector (intern (format "key-%d"
                                                       (cmacs-spacemouse-key-code 0)))))
                   [spacemouse-1]))
    (should (equal (lookup-key function-key-map
                               (vector (intern (format "key-%d"
                                                       (cmacs-spacemouse-key-code 1 t)))))
                   [spacemouse-2-release]))
    ;; Codes are distinct, and above every real keysym range: Unicode
    ;; keysyms end at #x0110ffff, XF86 ones at #x1008ffff.
    (should (/= (cmacs-spacemouse-key-code 0) (cmacs-spacemouse-key-code 0 t)))
    (should (> (cmacs-spacemouse-key-code 0) #x0110ffff))
    (should (> (cmacs-spacemouse-key-code 0) #x1008ffff)))
  (should (commandp (lookup-key cmacs-spacemouse-mode-map [spacemouse-1])))
  (should-error (cmacs-spacemouse-key-code 256)))

(ert-deftest cmacs-spacemouse-no-daemon-is-a-clean-no-op ()
  "With no spacenavd, starting connects to nothing and signals nothing."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (let ((path (make-temp-name
               (expand-file-name "cmacs-spnav-none-" temporary-file-directory))))
    (unwind-protect
        (progn
          (should-not (cmacs-spacemouse-start path t))
          (let ((st (cmacs-spacemouse-status)))
            (should (plist-get st :enabled))
            (should-not (plist-get st :connected))
            (should-not (plist-get st :backend))
            (should (= (plist-get st :attempts) 1))))
      (cmacs-spacemouse-stop))
    (should-not (plist-get (cmacs-spacemouse-status) :enabled))))

(defun cmacs-spacemouse-tests--wait (pred &optional seconds)
  "Pump the event loop (and so the GLib sources) until PRED or SECONDS."
  (let ((deadline (+ (float-time) (or seconds 5.0))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))

(ert-deftest cmacs-spacemouse-reads-a-fake-daemon ()
  "The whole read path against a daemon played on a local socket.
Packets split across writes reassemble; the daemon going away is seen."
  (skip-unless (cmacs-spacemouse-tests--built-p))
  (let* ((dir (make-temp-file "cmacs-spnav-" t))
         (path (expand-file-name "spnav.sock" dir))
         (client nil)
         (server (make-network-process
                  :name "fake-spacenavd" :family 'local :service path
                  :server t :coding 'binary :noquery t
                  :log (lambda (_server proc _msg) (setq client proc)))))
    (unwind-protect
        (cmacs-spacemouse-tests--with-defaults
          (cmacs-spacemouse-set-target 'none)
          (cmacs-spacemouse--recent-events t)
          (should (cmacs-spacemouse-start path t))
          (let ((st (cmacs-spacemouse-status)))
            (should (plist-get st :connected))
            (should (equal (plist-get st :backend) "socket"))
            (should (equal (plist-get st :socket) path)))
          (should (cmacs-spacemouse-tests--wait (lambda () client)))
          (let ((motion (cmacs-spacemouse--packet '(motion 12 -34 56 -78 90 -1 16)))
                (press (cmacs-spacemouse--packet '(button 3 t)))
                (release (cmacs-spacemouse--packet '(button 3 nil))))
            (should (= (length motion) 32))
            (process-send-string client motion)
            ;; A packet in two writes, as a stream socket may deliver it.
            (process-send-string client (substring press 0 13))
            (cmacs-spacemouse-tests--wait
             (lambda () (cmacs-spacemouse--recent-events)) 1.0)
            (process-send-string client (substring press 13))
            (process-send-string client release)
            (should (cmacs-spacemouse-tests--wait
                     (lambda () (= (length (cmacs-spacemouse--recent-events)) 3))))
            (should (equal (cmacs-spacemouse--recent-events)
                           '((motion 12 -34 56 -78 90 -1 16)
                             (button 3 press)
                             (button 3 release)))))
          ;; The daemon goes away: the connection notices, and retries.
          (delete-process client)
          (should (cmacs-spacemouse-tests--wait
                   (lambda ()
                     (not (plist-get (cmacs-spacemouse-status) :connected)))))
          (should (plist-get (cmacs-spacemouse-status) :enabled)))
      (cmacs-spacemouse-stop)
      (delete-process server)
      (delete-directory dir t))))

(ert-deftest cmacs-spacemouse-mode-without-support-or-daemon ()
  "The mode turns on quietly with no daemon, and off again cleanly."
  (skip-unless (and (cmacs-spacemouse-tests--built-p)
                    (require 'cmacs-spacemouse nil t)))
  (let ((cmacs-spacemouse-socket
         (make-temp-name (expand-file-name "cmacs-spnav-mode-"
                                           temporary-file-directory)))
        (function-key-map (make-sparse-keymap)))
    (unwind-protect
        (progn
          (cmacs-spacemouse-mode 1)
          (should cmacs-spacemouse-mode)
          (should (plist-get (cmacs-spacemouse-status) :enabled))
          (should-not (plist-get (cmacs-spacemouse-status) :connected)))
      (cmacs-spacemouse-mode -1))
    (should-not (plist-get (cmacs-spacemouse-status) :enabled))))

(provide 'cmacs-spacemouse-tests)

;;; cmacs-spacemouse-tests.el ends here
