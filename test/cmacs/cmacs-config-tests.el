;;; cmacs-config-tests.el --- Tests for CMacs config loading  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'cmacs-config)

;;; Defaults

(ert-deftest cmacs-config-defaults ()
  "Default config options should be t."
  (should (eq cmacs-config-load-bacon t))
  (should (eq cmacs-config-load-crispy t)))

(ert-deftest cmacs-config-variables-initially-nil ()
  "Config file path variables should be nil before loading."
  (should (null cmacs-config-bacon-file))
  (should (null cmacs-config-crispy-file)))

;;; Path detection

(ert-deftest cmacs-config-bacon-init-file-missing ()
  "Should return nil when init.bacon does not exist."
  (let ((user-emacs-directory "/nonexistent-dir/"))
    (should (null (cmacs-config--bacon-init-file)))))

(ert-deftest cmacs-config-crispy-init-file-missing ()
  "Should return nil when init.c does not exist."
  (let ((user-emacs-directory "/nonexistent-dir/"))
    (should (null (cmacs-config--crispy-init-file)))))

(ert-deftest cmacs-config-bacon-init-file-exists ()
  "Should return the path when init.bacon exists."
  (let* ((dir (make-temp-file "cmacs-test-" t))
         (file (expand-file-name "init.bacon" dir))
         (user-emacs-directory (file-name-as-directory dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "echo hello"))
          (should (equal (cmacs-config--bacon-init-file) file)))
      (delete-directory dir t))))

(ert-deftest cmacs-config-crispy-init-file-exists ()
  "Should return the path when init.c exists."
  (let* ((dir (make-temp-file "cmacs-test-" t))
         (file (expand-file-name "init.c" dir))
         (user-emacs-directory (file-name-as-directory dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#include <stdio.h>\nint main(void){return 0;}"))
          (should (equal (cmacs-config--crispy-init-file) file)))
      (delete-directory dir t))))

;;; Loading behavior

(ert-deftest cmacs-config-load-bacon-disabled ()
  "Should not load when cmacs-config-load-bacon is nil."
  (let ((cmacs-config-load-bacon nil)
        (cmacs-config-bacon-file nil))
    (cmacs-config-load-bacon-init)
    (should (null cmacs-config-bacon-file))))

(ert-deftest cmacs-config-load-crispy-disabled ()
  "Should not load when cmacs-config-load-crispy is nil."
  (let ((cmacs-config-load-crispy nil)
        (cmacs-config-crispy-file nil))
    (cmacs-config-load-crispy-init)
    (should (null cmacs-config-crispy-file))))

(ert-deftest cmacs-config-load-bacon-no-file ()
  "Should be a no-op when init.bacon does not exist."
  (let ((user-emacs-directory "/nonexistent-dir/")
        (cmacs-config-bacon-file nil))
    (cmacs-config-load-bacon-init)
    (should (null cmacs-config-bacon-file))))

(ert-deftest cmacs-config-load-crispy-no-file ()
  "Should be a no-op when init.c does not exist."
  (let ((user-emacs-directory "/nonexistent-dir/")
        (cmacs-config-crispy-file nil))
    (cmacs-config-load-crispy-init)
    (should (null cmacs-config-crispy-file))))

(ert-deftest cmacs-config-load-all-no-files ()
  "load-all should be safe when no config files exist."
  (let ((user-emacs-directory "/nonexistent-dir/")
        (cmacs-config-bacon-file nil)
        (cmacs-config-crispy-file nil))
    (cmacs-config-load-all)
    (should (null cmacs-config-bacon-file))
    (should (null cmacs-config-crispy-file))))

;;; Error handling

(ert-deftest cmacs-config-load-bacon-bad-file ()
  "Loading a malformed bacon file should warn, not crash."
  (skip-unless (fboundp 'bacon-source))
  (let* ((dir (make-temp-file "cmacs-test-" t))
         (file (expand-file-name "init.bacon" dir))
         (user-emacs-directory (file-name-as-directory dir))
         (cmacs-config-bacon-file nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "((((invalid syntax"))
          ;; Should not signal -- errors are caught and warned
          (cmacs-config-load-bacon-init))
      (delete-directory dir t))))

(provide 'cmacs-config-tests)
;;; cmacs-config-tests.el ends here
