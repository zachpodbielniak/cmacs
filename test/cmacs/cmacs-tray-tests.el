;;; cmacs-tray-tests.el --- Tests for the system tray -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-tray'.
;;
;; Nothing here touches a bus.  Claiming org.kde.StatusNotifierWatcher
;; in a test would take the tray away from whatever owns it on the
;; developer's desktop for the length of the run.
;;
;; What is tested is the wire parsing, because that is where this breaks
;; without looking broken: an item whose service string is misread, or a
;; menu whose reply shape is misparsed, produces an empty tray -- which
;; is indistinguishable from "no applications are running".
;;
;; The DBusMenu fixture is the exact reply captured from a live Solaar,
;; nesting and all.  It is not a simplification: dbus.el wraps each
;; child in a one-element list and each property value in another list,
;; and a parser written against the specification's prose rather than
;; the actual reply gets both wrong.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-tray)

;;; Service strings

(ert-deftest cmacs-tray-test-service-bare-bus-name ()
  "A bare bus name gets the default object path.
This is the form most applications use."
  (should (equal (cmacs-tray--split-service "org.kde.StatusNotifierItem-42-1")
                 '("org.kde.StatusNotifierItem-42-1" . "/StatusNotifierItem"))))

(ert-deftest cmacs-tray-test-service-bus-and-path ()
  "\"bus/object/path\" splits at the first slash."
  (should (equal (cmacs-tray--split-service "org.example.App/Custom/Item")
                 '("org.example.App" . "/Custom/Item"))))

(ert-deftest cmacs-tray-test-service-bare-path ()
  "A bare path leaves the bus for the caller to supply.
Solaar registers exactly this way -- as
\"/org/ayatana/NotificationItem/indicator_solaar\" with no bus name --
so a tray that assumes a bus name simply never shows it."
  (should (equal (cmacs-tray--split-service
                  "/org/ayatana/NotificationItem/indicator_solaar")
                 '(nil . "/org/ayatana/NotificationItem/indicator_solaar"))))

(ert-deftest cmacs-tray-test-service-nil ()
  "A missing service string is nil rather than an error."
  (should-not (cmacs-tray--split-service nil)))

;;; Labels

(ert-deftest cmacs-tray-test-label-prefers-title ()
  "Title wins, then tooltip, then id, then the bus name.
An item with none of them still gets a row: a nameless tray entry is
more useful than a missing one, because the user can still activate it."
  (should (equal (cmacs-tray--label '(:title "Solaar" :id "x" :bus ":1.7"))
                 "Solaar"))
  (should (equal (cmacs-tray--label '(:title "" :tooltip "Sync idle"
                                      :id "x" :bus ":1.7"))
                 "Sync idle"))
  (should (equal (cmacs-tray--label '(:title "" :tooltip "" :id "syncthing"
                                      :bus ":1.7"))
                 "syncthing"))
  (should (equal (cmacs-tray--label '(:title "" :tooltip "" :id "" :bus ":1.7"))
                 ":1.7")))

;;; Tooltips

(ert-deftest cmacs-tray-test-tooltip-joins-title-and-body ()
  "The ToolTip struct's two strings become one line.
The struct is (icon-name, pixmaps, title, description); a parser that
takes the first string gets the icon name instead of any text."
  (should (equal (cmacs-tray--tooltip-text
                  '("icon" nil "Syncthing" "Up to date"))
                 "Syncthing — Up to date"))
  (should (equal (cmacs-tray--tooltip-text '("icon" nil "Solaar" ""))
                 "Solaar")))

(ert-deftest cmacs-tray-test-tooltip-malformed ()
  "A short or absent ToolTip is nil, not an error."
  (should-not (cmacs-tray--tooltip-text nil))
  (should-not (cmacs-tray--tooltip-text '("icon" nil))))

;;; DBusMenu

(defconst cmacs-tray-tests--solaar-layout
  (list 4
        (list 0 (list (list "children-display" (list "submenu")))
              (list
               (list (list 6 (list (list "label" (list "Unifying Receiver")))
                           nil))
               (list (list 7 (list (list "label" (list "  MX Ergo: "))) nil))
               (list (list 2 (list (list "enabled" (list nil))
                                   (list "visible" (list nil))
                                   (list "label"
                                         (list "No supported device found")))
                           nil))
               (list (list 3 (list (list "enabled" (list t))
                                   (list "type" (list "separator")))
                           nil))
               (list (list 4 (list (list "label" (list "About Solaar"))) nil))
               (list (list 5 (list (list "label" (list "Quit Solaar")))
                           nil)))))
  "A GetLayout reply captured verbatim from a running Solaar.

Every layer of nesting here is real and load-bearing: each child is a
one-element list wrapping the (id, properties, children) struct, and
each property value is itself wrapped in a list, because that is how
dbus.el hands back a variant.")

(defmacro cmacs-tray-tests--with-menu (reply &rest body)
  "Run BODY with DBusMenu calls answering REPLY."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'dbus-call-method)
              (lambda (&rest _) ,reply)))
     ,@body))

(ert-deftest cmacs-tray-test-menu-parses-real-layout ()
  "The captured Solaar menu yields its actionable entries with ids."
  (cmacs-tray-tests--with-menu cmacs-tray-tests--solaar-layout
    (let ((entries (cmacs-tray--menu-entries '(:bus ":1.7" :menu "/m"))))
      (should (equal (mapcar #'car entries)
                     '("Unifying Receiver" "MX Ergo:"
                       "About Solaar" "Quit Solaar")))
      (should (equal (mapcar #'cdr entries) '(6 7 4 5))))))

(ert-deftest cmacs-tray-test-menu-skips-separators ()
  "A separator is not an entry.
Offering one in a completing-read means a keystroke that does nothing."
  (cmacs-tray-tests--with-menu cmacs-tray-tests--solaar-layout
    (should-not (cl-find 3 (cmacs-tray--menu-entries '(:bus "x" :menu "/m"))
                         :key #'cdr))))

(ert-deftest cmacs-tray-test-menu-skips-invisible ()
  "An entry the application marked invisible stays hidden.
Solaar's \"No supported device found\" is present but invisible
whenever a device *is* found; showing it would contradict the entry
above it."
  (cmacs-tray-tests--with-menu cmacs-tray-tests--solaar-layout
    (should-not (cl-find 2 (cmacs-tray--menu-entries '(:bus "x" :menu "/m"))
                         :key #'cdr))))

(ert-deftest cmacs-tray-test-menu-strips-mnemonics-and-pads ()
  "Mnemonic underscores and layout padding are removed from labels."
  (let ((reply (list 1 (list 0 nil
                             (list (list (list 9 (list (list "label"
                                                             (list "_Quit  ")))
                                               nil)))))))
    (cmacs-tray-tests--with-menu reply
      (should (equal (caar (cmacs-tray--menu-entries '(:bus "x" :menu "/m")))
                     "Quit")))))

(ert-deftest cmacs-tray-test-menu-without-menu-path ()
  "An item exposing no menu yields nil rather than calling anything."
  (should-not (cmacs-tray--menu-entries '(:bus ":1.7" :menu nil))))

(ert-deftest cmacs-tray-test-menu-call-failure-is-nil ()
  "A failing GetLayout is an empty menu, not an error up the stack.
The command turns nil into a `no menu' message; an error here would
leave the tray buffer unusable because one application misbehaved."
  (cl-letf (((symbol-function 'dbus-call-method)
             (lambda (&rest _) (error "no such object"))))
    (should-not (cmacs-tray--menu-entries '(:bus "x" :menu "/m")))))

;;; Registry bookkeeping

(ert-deftest cmacs-tray-test-item-services-order ()
  "Services come back in registration order."
  (let ((cmacs-tray--items '(("a" :bus "1") ("b" :bus "2") ("c" :bus "3"))))
    (should (equal (cmacs-tray--item-services) '("a" "b" "c")))))

(ert-deftest cmacs-tray-test-not-serving-by-default ()
  "A fresh Emacs is not the tray until the mode is enabled."
  (let ((cmacs-tray--registered nil))
    (should-not (cmacs-tray-serving-p))))

(provide 'cmacs-tray-tests)

;;; cmacs-tray-tests.el ends here
