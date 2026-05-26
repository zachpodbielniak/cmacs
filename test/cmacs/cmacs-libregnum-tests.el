;;; cmacs-libregnum-tests.el --- ERT for cmacs-libregnum  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cmacs-libregnum)

(defun cmacs-libregnum-tests--gl-skip-or ()
  "Return non-nil and skip if there is no display to host a GL view."
  (unless (and (display-graphic-p)
               (fboundp 'cmacs-libregnum-supported-p)
               (cmacs-libregnum-supported-p))
    (ert-skip "no display / cmacs-libregnum not built")))

(ert-deftest cmacs-libregnum-tests-supported-p ()
  "cmacs-libregnum-supported-p returns a boolean at all times."
  (let ((r (and (fboundp 'cmacs-libregnum-supported-p)
                (cmacs-libregnum-supported-p))))
    (should (or (eq r t) (null r)))))

(ert-deftest cmacs-libregnum-tests-parse-buffer ()
  "Buffer YAML parser handles bare values + coordinate triples."
  (with-temp-buffer
    (insert "# -*- mode: cmacs-libregnum -*-\n")
    (insert "scene_type: project_tree\n")
    (insert "project_root: /tmp/example\n")
    (insert "position: [1.5, -2.0, 3.25]\n")
    (insert "fov: 60\n")
    (let ((a (cmacs-libregnum--parse-buffer)))
      (should (equal (cmacs-libregnum--alist-get 'scene_type a)
                     "project_tree"))
      (should (equal (cmacs-libregnum--alist-get 'project_root a)
                     "/tmp/example"))
      (should (equal (cmacs-libregnum--alist-get 'position a)
                     '(1.5 -2.0 3.25)))
      (should (= (cmacs-libregnum--alist-get 'fov a) 60)))))

(ert-deftest cmacs-libregnum-tests-serialise-roundtrip ()
  "Parse + serialise is a round-trip on the supported subset."
  (let ((in '((scene_type . "project_tree")
              (project_root . "/tmp/example")
              (position . (1.0 2.0 3.0))
              (target   . (0.0 0.0 0.0))
              (fov      . 60.0))))
    (with-temp-buffer
      (cmacs-libregnum--serialise-buffer in)
      (let ((out (cmacs-libregnum--parse-buffer)))
        (should (equal (cmacs-libregnum--alist-get 'scene_type out)
                       "project_tree"))
        (should (equal (cmacs-libregnum--alist-get 'position out)
                       '(1.0 2.0 3.0)))))))

(ert-deftest cmacs-libregnum-tests-attach-detach ()
  "Attach + detach a view to a temp buffer; check attached-p toggles."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (cmacs-libregnum-mode))
          (should (cmacs-libregnum-attached-p buf))
          (cmacs-libregnum-detach buf)
          (should-not (cmacs-libregnum-attached-p buf)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest cmacs-libregnum-tests-scene-tree ()
  "Building the project-tree scene over a small fixture succeeds."
  (cmacs-libregnum-tests--gl-skip-or)
  (let* ((dir (make-temp-file "cmacs-libregnum-fixture-" t))
         (buf (generate-new-buffer "*cmacs-libregnum tree test*")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "a.txt" dir) (insert "hi"))
          (with-temp-file (expand-file-name "b.org" dir) (insert "* h"))
          (with-current-buffer buf (cmacs-libregnum-mode))
          (should (eq (cmacs-libregnum-build-tree buf dir) t)))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-directory-p dir) (delete-directory dir t)))))

(ert-deftest cmacs-libregnum-tests-scene-gobject ()
  "Building the GObject hierarchy scene with a narrow namespace works."
  (cmacs-libregnum-tests--gl-skip-or)
  (let ((buf (generate-new-buffer "*cmacs-libregnum gobject test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (cmacs-libregnum-mode))
          (should (eq (cmacs-libregnum-build-gobject buf "G") t)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(provide 'cmacs-libregnum-tests)
;;; cmacs-libregnum-tests.el ends here
