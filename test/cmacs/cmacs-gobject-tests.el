;;; cmacs-gobject-tests.el --- Tests for GObject bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for the CMacs GObject <-> elisp type bridge.
;; Tests cover wrap/unwrap, type predicates, property access,
;; signal listing, object creation, and signal connect/disconnect.

;;; Code:

(require 'ert)
(require 'cmacs)

;; Availability is asked of the primitives themselves.  `cmacs-feature-p'
;; from cmacs.el knows the configure-time feature names, and `gobject' is
;; not one of them -- the bridge ships with `glib' -- so every test gated
;; on it skipped, in every run, and the suite proved nothing.

;;; Predicate tests

(ert-deftest cmacs-gobject-test-p-nil ()
  "Test that nil is not a GObject."
  (skip-unless (fboundp 'gobject-new))
  (should-not (gobject-p nil)))

(ert-deftest cmacs-gobject-test-p-number ()
  "Test that a number is not a GObject."
  (skip-unless (fboundp 'gobject-new))
  (should-not (gobject-p 42)))

(ert-deftest cmacs-gobject-test-p-string ()
  "Test that a string is not a GObject."
  (skip-unless (fboundp 'gobject-new))
  (should-not (gobject-p "hello")))

(ert-deftest cmacs-gobject-test-p-cons ()
  "Test that a cons cell is not a GObject."
  (skip-unless (fboundp 'gobject-new))
  (should-not (gobject-p '(a . b))))

;;; Object creation tests

(ert-deftest cmacs-gobject-test-new-invalid-type ()
  "Test that `gobject-new' signals an error for unknown type."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-new "NonExistentGType12345")
                :type 'error))

(ert-deftest cmacs-gobject-test-new-non-string-type ()
  "Test that `gobject-new' signals an error for non-string type arg."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-new 42)
                :type 'wrong-type-argument))

(ert-deftest cmacs-gobject-test-new-gobject ()
  "Test creating a plain GObject and verifying it is recognized."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should (gobject-p obj))))

;;; Type name tests

(ert-deftest cmacs-gobject-test-type-name-gobject ()
  "Test that a plain GObject reports type name \"GObject\"."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should (equal (gobject-type-name obj) "GObject"))))

(ert-deftest cmacs-gobject-test-type-name-nil ()
  "Test that `gobject-type-name' signals an error for nil."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-type-name nil)
                :type 'error))

(ert-deftest cmacs-gobject-test-type-name-non-gobject ()
  "Test that `gobject-type-name' signals an error for non-GObject."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-type-name 42)
                :type 'error))

;;; Property tests

(ert-deftest cmacs-gobject-test-list-properties-gobject ()
  "Test that `gobject-list-properties' returns a list for GObject."
  (skip-unless (fboundp 'gobject-new))
  (let ((props (gobject-list-properties (gobject-new "GObject"))))
    (should (listp props))))

(ert-deftest cmacs-gobject-test-list-properties-nil ()
  "Test that `gobject-list-properties' errors on nil."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-list-properties nil)
                :type 'error))

(ert-deftest cmacs-gobject-test-get-invalid-property ()
  "Test that `gobject-get' errors on nonexistent property."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-get obj "nonexistent-property-xyz")
                  :type 'error)))

(ert-deftest cmacs-gobject-test-set-invalid-property ()
  "Test that `gobject-set' errors on nonexistent property."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-set obj "nonexistent-property-xyz" 42)
                  :type 'error)))

(ert-deftest cmacs-gobject-test-get-requires-string-property ()
  "Test that `gobject-get' requires a string property name."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-get obj 42)
                  :type 'wrong-type-argument)))

;;; Signal tests

(ert-deftest cmacs-gobject-test-list-signals-gobject ()
  "Test that `gobject-list-signals' returns a list for GObject."
  (skip-unless (fboundp 'gobject-new))
  (let ((signals (gobject-list-signals (gobject-new "GObject"))))
    (should (listp signals))
    ;; GObject has a \"notify\" signal.
    (should (member "notify" signals))))

(ert-deftest cmacs-gobject-test-list-signals-nil ()
  "Test that `gobject-list-signals' errors on nil."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-list-signals nil)
                :type 'error))

(ert-deftest cmacs-gobject-test-connect-requires-string-signal ()
  "Test that `gobject-connect' requires a string signal name."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-connect obj 42 #'ignore)
                  :type 'wrong-type-argument)))

(ert-deftest cmacs-gobject-test-connect-requires-function ()
  "Test that `gobject-connect' requires a function callback."
  (skip-unless (fboundp 'gobject-new))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-connect obj "notify" "not-a-function")
                  :type 'wrong-type-argument)))

(ert-deftest cmacs-gobject-test-connect-returns-handler-id ()
  "Test that `gobject-connect' returns a positive integer handler ID."
  (skip-unless (fboundp 'gobject-new))
  (let* ((obj (gobject-new "GObject"))
         (handler-id (gobject-connect obj "notify" #'ignore)))
    (should (integerp handler-id))
    (should (> handler-id 0))
    (gobject-disconnect obj handler-id)))

(ert-deftest cmacs-gobject-test-disconnect ()
  "`gobject-disconnect' answers t for a live handler and nil afterwards.
An unknown id used to reach g_signal_handler_disconnect and produce a
GLib CRITICAL; now it is simply the nil answer."
  (skip-unless (fboundp 'gobject-new))
  (let* ((obj (gobject-new "GObject"))
         (handler-id (gobject-connect obj "notify" #'ignore)))
    (should (eq t (gobject-disconnect obj handler-id)))
    (should (null (gobject-disconnect obj handler-id)))))

(ert-deftest cmacs-gobject-test-disconnect-nil-object ()
  "Test that `gobject-disconnect' errors on nil object."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-disconnect nil 1)
                :type 'error))

;; Edge cases: boundary values and error recovery
(ert-deftest cmacs-gobject-p-various-types ()
  "gobject-p should reject all non-GObject types gracefully."
  (skip-unless (fboundp 'gobject-p))
  (should-not (gobject-p 0))
  (should-not (gobject-p -1))
  (should-not (gobject-p 1.5))
  (should-not (gobject-p ""))
  (should-not (gobject-p 'symbol))
  (should-not (gobject-p [vector]))
  (should-not (gobject-p (make-hash-table))))

(ert-deftest cmacs-gobject-new-empty-string ()
  "Creating a GObject with empty type string should error."
  (skip-unless (fboundp 'gobject-new))
  (should-error (gobject-new "")))

(ert-deftest cmacs-gobject-wrap-unwrap-identity ()
  "Wrapping and immediately using a GObject should preserve type."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-type-name)))
  (let ((obj (gobject-new "GObject")))
    (should (gobject-p obj))
    (should (equal (gobject-type-name obj) "GObject"))))

(ert-deftest cmacs-gobject-connect-invalid-signal ()
  "Connecting to a nonexistent signal returns 0 (no valid handler)."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-connect)))
  ;; g_signal_connect_closure returns 0 for invalid signals rather
  ;; than raising an error — it emits a GLib warning instead.
  (let* ((obj (gobject-new "GObject"))
         (handler-id (gobject-connect obj "nonexistent-signal-xyz" #'ignore)))
    (should (integerp handler-id))
    (should (= handler-id 0))))

(ert-deftest cmacs-gobject-disconnect-invalid-id ()
  "Disconnecting an invalid handler ID should not crash."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-disconnect)))
  (let ((obj (gobject-new "GObject")))
    ;; Should not signal an error — just a no-op
    (gobject-disconnect obj 999999)))

(ert-deftest cmacs-gobject-set-invalid-property-name ()
  "Setting a nonexistent property should error, not crash."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-set)))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-set obj "totally-fake-property" 42))))

(ert-deftest cmacs-gobject-get-invalid-property-name ()
  "Getting a nonexistent property should error, not crash."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gobject-get)))
  (let ((obj (gobject-new "GObject")))
    (should-error (gobject-get obj "totally-fake-property"))))

;;; Type coverage the original table got wrong

(ert-deftest cmacs-gobject-test-enum-property-round-trips-as-integer ()
  "An enum property reads back as the integer `gobject-set' takes.

Every enum has its own GType derived from G_TYPE_ENUM, and the reader
compared against the fundamental type, so an enum property fell
through to the string fallback and came back as its C name while the
setter demanded an integer -- a get/set pair that could not round
trip."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gi-require)))
  (gi-require "Gio" "2.0")
  (let ((client (gobject-new "GSocketClient")))
    (should (integerp (gobject-get client "type")))
    ;; G_SOCKET_TYPE_DATAGRAM
    (gobject-set client "type" 2)
    (should (= 2 (gobject-get client "type")))))

(ert-deftest cmacs-gobject-test-flags-property-round-trips-as-integer ()
  "A flags property reads back as an integer, like the setter takes."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gi-require)))
  (gi-require "Gio" "2.0")
  (let ((client (gobject-new "GSocketClient")))
    (should (integerp (gobject-get client "tls-validation-flags")))
    ;; G_TLS_CERTIFICATE_BAD_IDENTITY
    (gobject-set client "tls-validation-flags" 2)
    (should (= 2 (gobject-get client "tls-validation-flags")))))

(ert-deftest cmacs-gobject-test-signal-enum-parameter-arrives-as-integer ()
  "A signal's enum parameter reaches the handler as an integer, not nil.

The closure marshaller kept its own type table with the same
fundamental-type comparison, so `GSocketClient::event' handed every
handler nil where the GSocketClientEvent belonged.  A connect to a
closed loopback port emits the event synchronously, RESOLVING first,
before failing; the failure is expected and ignored."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gi-require)))
  (gi-require "Gio" "2.0")
  (let* ((client (gobject-new "GSocketClient"))
         (events nil)
         (id (gobject-connect
              client "event"
              (lambda (event connectable connection)
                (push (list event (gobject-p connectable) connection)
                      events)))))
    (gobject-set client "timeout" 1)
    (ignore-errors (gi-method client "connect_to_host" "127.0.0.1:1" 1 nil))
    (gobject-disconnect client id)
    (should events)
    (dolist (e events)
      (should (integerp (nth 0 e)))
      (should (nth 1 e)))))

(defun cmacs-gobject-tests--scrub-stack (depth)
  "Churn DEPTH frames of stack so no dead slot still holds a closure.
Emacs's collector scans the C stack conservatively: a word left behind
by an earlier call that happens to point at an object keeps it alive.
A test about collection has to overwrite those slots first, or it
passes for a reason that has nothing to do with the root under test."
  (if (<= depth 0)
      (make-string 64 ?z)
    (let ((junk (make-list 32 depth)))
      (concat (cmacs-gobject-tests--scrub-stack (1- depth))
              (format "%S" (car junk))))))

(defun cmacs-gobject-tests--connect-shared (m1 m2 sink)
  "Connect one fresh lambda to `items-changed' on both M1 and M2.
Return (ID1 . ID2).  The handler pushes (TAG POSITION REMOVED ADDED)
onto the car of SINK.  A separate function so the closure object is
never held in the test's own frame."
  (let ((fn (let ((tag (make-string 32 ?h)))
              (lambda (position removed added)
                (push (list tag position removed added) (car sink))))))
    (cons (gobject-connect m1 "items-changed" fn)
          (gobject-connect m2 "items-changed" fn))))

(ert-deftest cmacs-gobject-test-shared-handler-survives-partner-disconnect ()
  "One function connected twice stays rooted while either handler lives.

The GC-protection list is delq'd on disconnect.  It used to hold the
function itself, and `delq' removes every eq element, so disconnecting
one of two handlers sharing a lambda unrooted both -- the survivor
then ran a collected closure.  Each closure now owns a cell of its
own.  Nothing but the two closures refers to the lambda; the first is
disconnected, the stack scrubbed, the collector run, and the second
must still fire with its captured data intact."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gi-require)))
  (gi-require "Gio" "2.0")
  (let* ((m1 (gobject-new "GMenu"))
         (m2 (gobject-new "GMenu"))
         (sink (list nil))
         (ids (cmacs-gobject-tests--connect-shared m1 m2 sink)))
    (should (eq t (gobject-disconnect m1 (car ids))))
    (cmacs-gobject-tests--scrub-stack 200)
    (dotimes (_ 3)
      (cmacs-gobject-tests--scrub-stack 50)
      (garbage-collect))
    (gi-method m2 "append" "entry" nil)
    (should (equal (car (car sink)) (list (make-string 32 ?h) 0 0 1)))
    (gobject-disconnect m2 (cdr ids))))

(ert-deftest cmacs-gobject-test-boxed-property-is-wrapped ()
  "A boxed-typed property comes back as a boxed value, not a printout.
GThemedIcon's `names' is a GStrv; its methods are reachable via
`gi-method' only if the value arrived as a boxed wrapper."
  (skip-unless (and (fboundp 'gobject-new) (fboundp 'gi-require)))
  (gi-require "Gio" "2.0")
  (let* ((icon (gi-call "Gio" "content_type_get_icon" "text/plain")))
    (should (gobject-p icon))
    (should-not (stringp (gobject-get icon "names")))))

(provide 'cmacs-gobject-tests)
;;; cmacs-gobject-tests.el ends here
