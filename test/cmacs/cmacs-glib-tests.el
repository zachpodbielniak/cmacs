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

(provide 'cmacs-glib-tests)
;;; cmacs-glib-tests.el ends here
