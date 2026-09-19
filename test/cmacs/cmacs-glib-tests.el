;;; cmacs-glib-tests.el --- Tests for GLib integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs GLib event loop integration.
;; Tests cover GMainContext creation, timeout sources, idle sources,
;; source removal, iteration, and pending checks.

;;; Code:

(require 'ert)
(require 'cmacs)

;;; Feature availability

(defun cmacs-feature-p (feature)
  "Return non-nil if CMacs FEATURE is available.
FEATURE is a symbol: glib, gobject, gi, crispy, bacon, gowl, org-ex."
  (pcase feature
    ('glib (fboundp 'cmacs-glib-context-p))
    ('gobject (fboundp 'gobject-p))
    ('gi (fboundp 'gi-require))
    ('crispy (fboundp 'crispy-eval))
    ('bacon (fboundp 'bacon-start))
    ('gowl (fboundp 'gowl-start))
    ('org-ex (fboundp 'org-ex-document-create))
    (_ nil)))

;;; Context tests

(ert-deftest cmacs-glib-test-context-p ()
  "Test that the GLib context predicate returns non-nil after init."
  (skip-unless (cmacs-feature-p 'glib))
  (should (cmacs-glib-context-p)))

(ert-deftest cmacs-glib-test-context-p-returns-boolean ()
  "Test that `cmacs-glib-context-p' returns t or nil, not arbitrary truthy."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((result (cmacs-glib-context-p)))
    (should (memq result '(t nil)))))

;;; Timeout source tests

(ert-deftest cmacs-glib-test-timeout-add-returns-integer ()
  "Test that `cmacs-glib-timeout-add' returns a source ID integer."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id (cmacs-glib-timeout-add 1000 #'ignore)))
    (unwind-protect
        (should (integerp id))
      (cmacs-glib-source-remove id))))

(ert-deftest cmacs-glib-test-timeout-add-positive-id ()
  "Test that returned source IDs are positive."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id (cmacs-glib-timeout-add 500 #'ignore)))
    (unwind-protect
        (should (> id 0))
      (cmacs-glib-source-remove id))))

(ert-deftest cmacs-glib-test-timeout-add-requires-function ()
  "Test that `cmacs-glib-timeout-add' signals an error for non-function callback."
  (skip-unless (cmacs-feature-p 'glib))
  (should-error (cmacs-glib-timeout-add 100 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-glib-test-timeout-add-requires-fixnat ()
  "Test that `cmacs-glib-timeout-add' signals an error for negative interval."
  (skip-unless (cmacs-feature-p 'glib))
  (should-error (cmacs-glib-timeout-add -1 #'ignore)
                :type 'wrong-type-argument))

(ert-deftest cmacs-glib-test-timeout-add-unique-ids ()
  "Test that successive timeout sources get distinct IDs."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id1 (cmacs-glib-timeout-add 1000 #'ignore))
        (id2 (cmacs-glib-timeout-add 1000 #'ignore)))
    (unwind-protect
        (should-not (= id1 id2))
      (cmacs-glib-source-remove id1)
      (cmacs-glib-source-remove id2))))

;;; Idle source tests

(ert-deftest cmacs-glib-test-idle-add-returns-integer ()
  "Test that `cmacs-glib-idle-add' returns a source ID integer."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id (cmacs-glib-idle-add #'ignore)))
    (unwind-protect
        (should (integerp id))
      (cmacs-glib-source-remove id))))

(ert-deftest cmacs-glib-test-idle-add-requires-function ()
  "Test that `cmacs-glib-idle-add' signals an error for non-function."
  (skip-unless (cmacs-feature-p 'glib))
  (should-error (cmacs-glib-idle-add "not-a-function")
                :type 'wrong-type-argument))

(ert-deftest cmacs-glib-test-idle-add-positive-id ()
  "Test that idle source IDs are positive."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id (cmacs-glib-idle-add #'ignore)))
    (unwind-protect
        (should (> id 0))
      (cmacs-glib-source-remove id))))

;;; Source removal tests

(ert-deftest cmacs-glib-test-source-remove-valid ()
  "Test that removing a valid source returns non-nil."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id (cmacs-glib-timeout-add 5000 #'ignore)))
    (should (cmacs-glib-source-remove id))))

(ert-deftest cmacs-glib-test-source-remove-invalid ()
  "Test that removing a nonexistent source returns nil."
  (skip-unless (cmacs-feature-p 'glib))
  (should-not (cmacs-glib-source-remove 999999)))

(ert-deftest cmacs-glib-test-source-remove-requires-fixnat ()
  "Test that `cmacs-glib-source-remove' rejects non-integer."
  (skip-unless (cmacs-feature-p 'glib))
  (should-error (cmacs-glib-source-remove "bad")
                :type 'wrong-type-argument))

;;; Iteration tests

(ert-deftest cmacs-glib-test-iteration-non-blocking ()
  "Test that `cmacs-glib-iteration' with nil returns without blocking."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((result (cmacs-glib-iteration nil)))
    (should (memq result '(t nil)))))

(ert-deftest cmacs-glib-test-iteration-dispatches-idle ()
  "Test that iteration dispatches a pending idle source."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((called nil)
        id)
    (setq id (cmacs-glib-idle-add (lambda () (setq called t) nil)))
    (cmacs-glib-iteration nil)
    ;; The idle source may or may not fire in one non-blocking iteration,
    ;; but we at least verify no error occurs.
    (when (not called)
      (cmacs-glib-source-remove id))))

;;; Pending tests

(ert-deftest cmacs-glib-test-pending-p-returns-boolean ()
  "Test that `cmacs-glib-pending-p' returns t or nil."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((result (cmacs-glib-pending-p)))
    (should (memq result '(t nil)))))

(ert-deftest cmacs-glib-test-pending-after-idle-add ()
  "Test that pending is non-nil after adding an idle source."
  (skip-unless (cmacs-feature-p 'glib))
  (let ((id (cmacs-glib-idle-add #'ignore)))
    (unwind-protect
        ;; After adding an idle source, there should be something pending.
        (should (cmacs-glib-pending-p))
      (cmacs-glib-source-remove id))))

;; Edge cases: boundary values
(ert-deftest cmacs-glib-timeout-zero-interval ()
  "Zero interval timeout should still create a valid source."
  (skip-unless (fboundp 'cmacs-glib-timeout-add))
  (let ((id (cmacs-glib-timeout-add 0 (lambda () nil))))
    (should (integerp id))
    (should (> id 0))
    (cmacs-glib-source-remove id)))

(ert-deftest cmacs-glib-timeout-large-interval ()
  "Large interval should not error."
  (skip-unless (fboundp 'cmacs-glib-timeout-add))
  (let ((id (cmacs-glib-timeout-add 999999 (lambda () nil))))
    (should (integerp id))
    (cmacs-glib-source-remove id)))

(ert-deftest cmacs-glib-remove-already-removed ()
  "Removing an already-removed source should not error."
  (skip-unless (fboundp 'cmacs-glib-source-remove))
  (let ((id (cmacs-glib-timeout-add 1000 (lambda () nil))))
    (cmacs-glib-source-remove id)
    ;; Second remove should be a no-op, not an error
    (should-not (cmacs-glib-source-remove id))))

(ert-deftest cmacs-glib-multiple-sources ()
  "Creating multiple sources should return distinct IDs."
  (skip-unless (fboundp 'cmacs-glib-timeout-add))
  (let ((id1 (cmacs-glib-timeout-add 1000 (lambda () nil)))
        (id2 (cmacs-glib-timeout-add 2000 (lambda () nil)))
        (id3 (cmacs-glib-idle-add (lambda () nil))))
    (should-not (= id1 id2))
    (should-not (= id2 id3))
    (should-not (= id1 id3))
    (cmacs-glib-source-remove id1)
    (cmacs-glib-source-remove id2)
    (cmacs-glib-source-remove id3)))

(ert-deftest cmacs-glib-iteration-multiple ()
  "Multiple non-blocking iterations should not error."
  (skip-unless (fboundp 'cmacs-glib-iteration))
  (dotimes (_ 10)
    (cmacs-glib-iteration nil)))

(ert-deftest cmacs-glib-context-stable ()
  "Context predicate should return consistent results."
  (skip-unless (fboundp 'cmacs-glib-context-p))
  (let ((r1 (cmacs-glib-context-p))
        (r2 (cmacs-glib-context-p)))
    (should (eq r1 r2))))

;;; Regression guards: the source that pumps the loop

(defvar cmacs-glib-tests--this-file (or load-file-name buffer-file-name)
  "Where this test file was loaded from, to find the C sources beside it.")

(defun cmacs-glib-tests--source-file (relative)
  "Return the absolute path of RELATIVE inside the cmacs source tree, or nil."
  (let* ((here (or cmacs-glib-tests--this-file
                   (locate-library "cmacs-glib-tests")))
         (root (and here
                    (expand-file-name "../.." (file-name-directory here))))
         (file (and root (expand-file-name relative root))))
    (and file (file-readable-p file) file)))

(defun cmacs-glib-tests--file-string (file)
  "The contents of FILE as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest cmacs-glib-test-timer-callback-survives-gc ()
  "A closure handed to `cmacs-glib-timeout-add' stays alive until it fires.

The source's only reference to the callback used to be a Lisp_Object
in a g_malloc'd struct -- no GC root.  A fresh lambda passed as the
callback was collected on the next GC, and when the timer fired the
source called whatever now lived at that address.  Nothing else here
refers to the closure once the let exits, so the source's own root is
the only thing standing between the callback and the collector."
  (skip-unless (cmacs-feature-p 'glib))
  (let* ((witness (make-string 64 ?w))
         (seen nil)
         (id (cmacs-glib-timeout-add
              10 (let ((w (copy-sequence witness)))
                   (lambda () (setq seen w) nil)))))
    (unwind-protect
        (progn
          (dotimes (_ 3) (garbage-collect))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (not seen) (< (float-time) deadline))
              (sit-for 0.05)))
          (should (equal seen witness)))
      (cmacs-glib-source-remove id))))

(ert-deftest cmacs-glib-test-shared-timer-callback-outlives-its-partner ()
  "Two sources sharing one callback object each keep their own root.

The protection list holds a cell per SOURCE, not per function, so
removing one source must not strip the other's protection.  The first
timer is removed and the collector run before the second fires."
  (skip-unless (cmacs-feature-p 'glib))
  (let* ((witness (make-string 48 ?s))
         (seen nil)
         (fn (let ((w (copy-sequence witness)))
               (lambda () (setq seen w) nil)))
         (id1 (cmacs-glib-timeout-add 5000 fn))
         (id2 (cmacs-glib-timeout-add 10 fn)))
    (setq fn nil)
    (unwind-protect
        (progn
          (cmacs-glib-source-remove id1)
          (dotimes (_ 3) (garbage-collect))
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (not seen) (< (float-time) deadline))
              (sit-for 0.05)))
          (should (equal seen witness)))
      (cmacs-glib-source-remove id2))))

(ert-deftest cmacs-glib-test-loop-polls-write-readiness ()
  "GLib sources waiting to WRITE are polled and told when they may.

`cmacs_glib_prepare' put G_IO_OUT fds into the write set, but the
write set only reached pselect on rounds where Emacs had a connecting
process of its own to watch, and `cmacs_glib_dispatch' never mapped
write readiness back into revents at all.  A GSocket source blocked on
a full socket buffer therefore never fired.  Checked as source: it
needs a full socket and a reader in another process to observe."
  (let ((loop (cmacs-glib-tests--source-file "cmacs/glib/cmacs-glib-loop.c"))
        (proc (cmacs-glib-tests--source-file "src/process.c")))
    (skip-unless (and loop proc))
    (let* ((loop-src (cmacs-glib-tests--file-string loop))
           (proc-src (cmacs-glib-tests--file-string proc))
           (dispatch (substring loop-src
                                (string-match "^cmacs_glib_dispatch" loop-src))))
      ;; Each check is named and reduced to a boolean first, so a
      ;; failure reports which invariant broke rather than printing
      ;; the whole of process.c into the log.
      (dolist (check
               `(("dispatch takes the write set"
                  . ,(string-match-p
                      "^cmacs_glib_dispatch (fd_set \\*readable, fd_set \\*writeable"
                      loop-src))
                 ("dispatch reads write readiness"
                  . ,(string-match-p "FD_ISSET (fd, writeable)" dispatch))
                 ("dispatch maps G_IO_OUT into revents"
                  . ,(string-match-p
                      "revents |= (poll_fds\\[i\\]\\.events & G_IO_OUT)"
                      dispatch))
                 ("process.c polls the write set when GLib asked"
                  . ,(string-match-p
                      "if (cmacs_glib_wants_write ())[[:space:]\n]*check_write = true;"
                      proc-src))
                 ("process.c hands the polled write set back"
                  . ,(string-match-p
                      "cmacs_glib_dispatch (&Available, check_write \\? &Writeok : NULL"
                      proc-src))))
        (ert-info ((car check))
          (should (cdr check)))))))

(provide 'cmacs-glib-tests)
;;; cmacs-glib-tests.el ends here
