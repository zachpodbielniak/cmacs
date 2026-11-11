;;; cmacs-lrgeditor-tests.el --- tests for the embedded lrgeditor shell  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Two tiers.  The key translation is pure and runs in batch.  The rest
;; hosts libregnum's real editor application in a view, which needs a GL
;; context (a display); those tests skip without one.  Run them under a
;; private headless compositor, never against a live desktop session.

;;; Code:

(require 'ert)
(require 'cmacs)
(require 'cmacs-lrgeditor)

(defun cmacs-lrgeditor-tests--gl-skip-or ()
  "Skip unless a GL view can be hosted and the shell is built."
  (unless (and (display-graphic-p)
               (fboundp 'cmacs-libregnum-supported-p)
               (cmacs-libregnum-supported-p)
               (fboundp 'cmacs-lrgeditor--attach))
    (ert-skip "no display / lrgeditor shell not built")))

;;;; Key translation (batch).

(ert-deftest cmacs-lrgeditor-tests-translate-letters ()
  "Letters map to raylib KEY_A..KEY_Z and type themselves."
  (should (equal (cmacs-lrgeditor--translate ?w) '(87 0 "w")))
  ;; Upper case is the same key with shift.
  (should (equal (cmacs-lrgeditor--translate ?W) '(87 1 "W"))))

(ert-deftest cmacs-lrgeditor-tests-translate-control ()
  "C-s is KEY_S with the control bit and types nothing."
  (should (equal (cmacs-lrgeditor--translate ?\C-s) '(83 2 nil)))
  (should (equal (cmacs-lrgeditor--translate (aref (kbd "C-S-z") 0))
                 '(90 3 nil))))

(ert-deftest cmacs-lrgeditor-tests-translate-symbols ()
  "Function and editing keys map to their raylib codes."
  (should (equal (car (cmacs-lrgeditor--translate 'f5)) 294))
  (should (equal (car (cmacs-lrgeditor--translate 'S-f5)) 294))
  (should (= (cadr (cmacs-lrgeditor--translate 'S-f5)) 1))
  (should (equal (car (cmacs-lrgeditor--translate 'delete)) 261))
  (should (equal (car (cmacs-lrgeditor--translate ?\r)) 257))
  (should (equal (car (cmacs-lrgeditor--translate 'escape)) 256)))

(ert-deftest cmacs-lrgeditor-tests-translate-shifted-punctuation ()
  "Shifted punctuation is its base key plus shift, and types itself."
  (should (equal (cmacs-lrgeditor--translate ?!) '(49 1 "!")))
  (should (equal (cmacs-lrgeditor--translate ?:) '(59 1 ":"))))

(ert-deftest cmacs-lrgeditor-tests-translate-ignores-mouse ()
  "Mouse events are not keys."
  (should-not (cmacs-lrgeditor--translate 'mouse-1))
  (should-not (cmacs-lrgeditor--translate 'down-mouse-1)))

(ert-deftest cmacs-lrgeditor-tests-passthrough-keys ()
  "The prefix and pass-through keys are not the editor's."
  (with-temp-buffer
    (cmacs-lrgeditor--install-escapes)
    (should (keymapp (lookup-key cmacs-lrgeditor-mode-map
                                 (kbd cmacs-lrgeditor-prefix))))
    (should (eq (lookup-key cmacs-lrgeditor-prefix-map (kbd "a"))
                #'cmacs-lrgeditor-run-action))
    ;; An explicitly unbound key does not take the default binding.
    (should-not (lookup-key cmacs-lrgeditor-mode-map (kbd "M-x")))
    (should (eq (lookup-key cmacs-lrgeditor-mode-map (kbd "C-s") t)
                #'cmacs-lrgeditor-dispatch-key))))

;;;; The real shell (needs GL).

(ert-deftest cmacs-lrgeditor-tests-symbols ()
  "The shell's primitives are defined when libregnum is built."
  (skip-unless (fboundp 'cmacs-libregnum-supported-p))
  (dolist (fn '(cmacs-lrgeditor--attach cmacs-lrgeditor-attached-p
                cmacs-lrgeditor--open cmacs-lrgeditor--new-project
                cmacs-lrgeditor--start-server cmacs-lrgeditor-socket
                cmacs-lrgeditor--key cmacs-lrgeditor--text
                cmacs-lrgeditor--release-all cmacs-lrgeditor--idle-seconds
                cmacs-lrgeditor-playing-p cmacs-lrgeditor-quit-requested-p
                cmacs-lrgeditor-status cmacs-lrgeditor-activate-action
                cmacs-lrgeditor-actions))
    (should (fboundp fn))))

(ert-deftest cmacs-lrgeditor-tests-host-project-and-play ()
  "Host the shell, make a project, run actions, play and stop."
  (cmacs-lrgeditor-tests--gl-skip-or)
  (let* ((dir (make-temp-file "cmacs-lrgeditor-" t))
         (settings (expand-file-name "editor.yaml" dir))
         (cmacs-lrgeditor-settings-file settings)
         (cmacs-lrgeditor-start-server nil)
         (cmacs-lrgeditor-connect-libregnum-el nil)
         (buf nil))
    (unwind-protect
        (progn
          (setq buf (cmacs-lrgeditor))
          (should (cmacs-lrgeditor-attached-p buf))
          (should (member "file.save" (cmacs-lrgeditor-actions buf)))
          (cmacs-lrgeditor--new-project buf (expand-file-name "game" dir)
                                        "game")
          (should (file-exists-p (expand-file-name "game/project.ryaml" dir)))
          ;; The shell's document is the one the older node DEFUNs edit.
          (should (cmacs-libregnum-editor-active-p buf))
          (let ((id (cmacs-libregnum-editor-add-primitive
                     buf cmacs-libregnum-primitive-cube "Box")))
            (should (integerp id)))
          ;; Keys and text reach it without error; a frame renders.
          (cmacs-lrgeditor--key buf 87 0 0)
          (cmacs-lrgeditor--key buf 87 2 0)
          (cmacs-lrgeditor--text buf "x")
          (redisplay t)
          ;; The editor's canvas really reaches the view: menus, docks and
          ;; panels leave ink across the frame, not one flat clear colour.
          (let ((bbox (cmacs-libregnum-ink-bbox buf)))
            (should bbox)
            (should (> (- (nth 2 bbox) (nth 0 bbox)) 100))
            (should (> (- (nth 3 bbox) (nth 1 bbox)) 100)))
          (should (cmacs-lrgeditor-activate-action buf "play.start"))
          (should (cmacs-lrgeditor-playing-p buf))
          (should (cmacs-lrgeditor-activate-action buf "play.stop"))
          (should-not (cmacs-lrgeditor-playing-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t))))

(ert-deftest cmacs-lrgeditor-tests-server-socket ()
  "The shell serves libregnum's editor protocol on a socket."
  (cmacs-lrgeditor-tests--gl-skip-or)
  (let* ((dir (make-temp-file "cmacs-lrgeditor-" t))
         (cmacs-lrgeditor-settings-file (expand-file-name "editor.yaml" dir))
         (cmacs-lrgeditor-start-server t)
         (cmacs-lrgeditor-socket (expand-file-name "ed.sock" dir))
         (cmacs-lrgeditor-connect-libregnum-el nil)
         (buf nil))
    (unwind-protect
        (progn
          (setq buf (cmacs-lrgeditor))
          (should (equal (cmacs-lrgeditor-socket buf)
                         cmacs-lrgeditor-socket))
          (should (file-exists-p cmacs-lrgeditor-socket))
          ;; A JSON-lines round trip over the socket, answered while this
          ;; Emacs waits in accept-process-output -- the path libregnum.el's
          ;; synchronous requests take.
          (let* ((reply nil)
                 (proc (make-network-process
                        :name "lrgeditor-test" :family 'local
                        :service cmacs-lrgeditor-socket :noquery t
                        :filter (lambda (_p s) (setq reply (concat reply s))))))
            (unwind-protect
                (progn
                  (process-send-string
                   proc "{\"id\":1,\"method\":\"editor.info\"}\n")
                  (with-timeout (5 nil)
                    (while (not (and reply (string-match-p "\n" reply)))
                      (accept-process-output proc 0.05)))
                  (should reply)
                  (should (string-match-p "\"id\" *: *1" reply)))
              (delete-process proc))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-directory dir t))))

(provide 'cmacs-lrgeditor-tests)

;;; cmacs-lrgeditor-tests.el ends here
