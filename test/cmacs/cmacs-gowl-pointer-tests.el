;;; cmacs-gowl-pointer-tests.el --- Tests for injected gowl pointer input -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of cmacs, a fork of GNU Emacs.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The `gowl-pointer-*' DEFUNs against a real compositor -- started in a
;; SECOND cmacs on wlroots' headless backend, with a private runtime
;; directory, never the session this runs in -- and their behaviour with
;; no compositor at all.  The lock discipline of their source is checked
;; by `cmacs-gowl-test-compositor-defuns-take-the-lock'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs nil t)

(defun cmacs-gowl-pointer-tests--run-headless (form)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Return (STATUS . OUTPUT).  The same isolation as cmacs-gowl-tests.el's
harness: a private runtime directory, no parent display, systemd off,
the pixman renderer, fatal GLib criticals."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file (expand-file-name "cmacs-gowl-ptr-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME=" (expand-file-name "state" runtime))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "120" emacs))
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defun cmacs-gowl-pointer-tests--runnable-p ()
  (and (fboundp 'gowl-pointer-warp)
       (let ((dir (getenv "XDG_RUNTIME_DIR")))
         (and dir (file-directory-p dir)))))

(ert-deftest cmacs-gowl-pointer-without-a-compositor ()
  "With no compositor the position is nil and every action says why."
  (skip-unless (fboundp 'gowl-pointer-warp))
  (skip-unless (not (gowl-running-p)))
  (should-not (gowl-pointer-position))
  (should-not (gowl-output-geometry))
  (should-error (gowl-pointer-warp 10 10))
  (should-error (gowl-pointer-move 1 1))
  (should-error (gowl-pointer-button 'left))
  (should-error (gowl-pointer-scroll 1))
  ;; Argument checks come first, and take the lock with them on the way out.
  (should-error (gowl-pointer-button 'elbow) :type 'wrong-type-argument)
  (should-error (gowl-pointer-button 'left 'sideways) :type 'wrong-type-argument)
  (should-error (gowl-pointer-warp "x" 1) :type 'wrong-type-argument))

(defconst cmacs-gowl-pointer-tests--form
  '(progn
     (gowl-start)
     (unless (gowl-running-p)
       (princ "no compositor\n")
       (kill-emacs 77))
     (let* ((geom (gowl-output-geometry))
            (w (nth 2 geom)) (h (nth 3 geom))
            (fail (lambda (fmt &rest args)
                    (princ (apply #'format (concat fmt "\n") args))
                    (ignore-errors (gowl-stop))
                    (kill-emacs 3))))
       (unless (and geom (> w 0) (> h 0))
         (funcall fail "no output geometry: %S" geom))
       ;; Absolute, then relative, then off the layout: clamped onto it.
       (let ((p (gowl-pointer-warp 100 50)))
         (unless (and (< (abs (- (car p) 100)) 0.01) (< (abs (- (cdr p) 50)) 0.01))
           (funcall fail "warp landed at %S" p)))
       (let ((p (gowl-pointer-move 10 -5)))
         (unless (and (< (abs (- (car p) 110)) 0.01) (< (abs (- (cdr p) 45)) 0.01))
           (funcall fail "move landed at %S" p)))
       (let ((p (gowl-pointer-warp -50 99999)))
         (unless (and (>= (car p) 0) (< (car p) w) (>= (cdr p) 0) (< (cdr p) h))
           (funcall fail "off-layout warp not clamped: %S in %S" p geom)))
       ;; The position reads back what the compositor has, not a cache.
       (gowl-pointer-warp (/ w 2) (/ h 2))
       (let ((p (gowl-pointer-position)))
         (unless (< (abs (- (car p) (/ w 2))) 0.01)
           (funcall fail "position %S after warp to the centre" p)))
       ;; Buttons and scroll go through on an empty desktop without error.
       (gowl-pointer-button 'left)
       (gowl-pointer-button 'right 'press)
       (gowl-pointer-button 'right 'release)
       (gowl-pointer-button #x112)
       (gowl-pointer-scroll 1)
       (gowl-pointer-scroll -0.5 2)
       ;; By name: the headless output.
       (let ((name (and (fboundp 'gowl-list-monitors)
                        (ignore-errors
                          (plist-get (car (gowl-list-monitors)) :name)))))
         (when (and (stringp name)
                    (not (equal (gowl-output-geometry name) geom)))
           (funcall fail "geometry of %s differs" name)))
       (unless (null (gowl-output-geometry "cmacs-no-such-output"))
         (funcall fail "an unknown output has a geometry"))
       (gowl-stop)
       (when (gowl-pointer-position)
         (funcall fail "a position after `gowl-stop'"))
       (princ "cmacs-gowl-pointer: ok\n")))
  "What `cmacs-gowl-pointer-headless' runs in the second cmacs.")

(ert-deftest cmacs-gowl-pointer-headless ()
  "Warp, move, clamp, read back, click and scroll on a headless compositor."
  (skip-unless (cmacs-gowl-pointer-tests--runnable-p))
  (let* ((result (cmacs-gowl-pointer-tests--run-headless
                  cmacs-gowl-pointer-tests--form))
         (status (car result))
         (output (cdr result)))
    (when (eql status 77)
      (ert-skip "no headless compositor here"))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-search "cmacs-gowl-pointer: ok" output)))))

;;;; The lock discipline, read from the source

(defconst cmacs-gowl-pointer-tests--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "This file's directory, captured at load: `load-file-name' is nil by
the time a test body runs.")

(defun cmacs-gowl-pointer-tests--source ()
  (let ((f (expand-file-name "../../cmacs/gowl/cmacs-gowl-pointer.c"
                             cmacs-gowl-pointer-tests--dir)))
    (and (file-readable-p f) f)))

(defun cmacs-gowl-pointer-tests--chunks (regexp)
  "(NAME . TEXT) for each top-level definition whose start matches REGEXP."
  (with-temp-buffer
    (insert-file-contents (cmacs-gowl-pointer-tests--source))
    (let (starts chunks)
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (push (cons (match-string 1) (match-beginning 0)) starts))
      (setq starts (nreverse starts))
      (while starts
        (let* ((this (pop starts))
               (end (save-excursion
                      (goto-char (cdr this))
                      (if (re-search-forward "^}" nil t) (point) (point-max)))))
          (push (cons (car this) (buffer-substring-no-properties (cdr this) end))
                chunks)))
      (nreverse chunks))))

(defun cmacs-gowl-pointer-tests--count (regexp text)
  (let ((start 0) (n 0))
    (while (string-match regexp text start)
      (setq n (1+ n) start (match-end 0)))
    n))

(ert-deftest cmacs-gowl-pointer-everything-takes-the-lock ()
  "Every DEFUN holds the scoped lock and returns through `unbind_to';
every C entry point takes the gowl lock and releases it on every path.
`cmacs-gowl-test-compositor-defuns-take-the-lock' sees only the DEFUNs
that name the compositor themselves; most of these reach it through the
C functions, so they are checked here."
  (skip-unless (cmacs-gowl-pointer-tests--source))
  (let ((defuns (cmacs-gowl-pointer-tests--chunks "^DEFUN (\"\\([^\"]+\\)\""))
        (entries (cmacs-gowl-pointer-tests--chunks
                  "^\\(cmacs_gowl_\\(?:pointer_[a-z]+\\|output_geometry\\)\\) (")))
    (should (>= (length defuns) 6))
    (should (>= (length entries) 6))
    (pcase-dolist (`(,name . ,text) defuns)
      (ert-info ((format "DEFUN %s" name))
        (should (string-match-p "cmacs_gowl_lock_scoped ()" text))
        (should-not (string-match-p "^  return [^u]" text))))
    (pcase-dolist (`(,name . ,text) entries)
      (ert-info ((format "C %s" name))
        (should (string-match-p "cmacs_gowl_lock ();" text))
        ;; As many unlocks as there are ways out.
        (should (= (cmacs-gowl-pointer-tests--count "cmacs_gowl_unlock ();" text)
                   (cmacs-gowl-pointer-tests--count "\\_<return\\_>" text)))))))

(provide 'cmacs-gowl-pointer-tests)

;;; cmacs-gowl-pointer-tests.el ends here
