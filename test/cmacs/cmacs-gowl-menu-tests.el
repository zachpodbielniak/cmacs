;;; cmacs-gowl-menu-tests.el --- Tests for the gowl control surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-gowl-menu'.
;;
;; Nothing here runs a backend.  The parsers are fed captured output
;; from the real tools, which is the part that actually breaks: a
;; format change in `wpctl status' or `nmcli -t' turns a working menu
;; into an empty one, and an empty menu looks like "no devices" rather
;; than like a bug.
;;
;; The tree walk is exercised through its guards, because a guard that
;; signals must cost its own entry and not the whole control surface --
;; the entry that would break is exactly the one whose backend is
;; missing or misbehaving.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl-menu)

(declare-function cmacs-feature-p "cmacs-glib-tests")

;;; Guards

(ert-deftest cmacs-gowl-menu-test-no-guard-is-visible ()
  "An entry with no `:when' is always shown."
  (should (cmacs-gowl-menu--visible-p '("Plain" :call ignore))))

(ert-deftest cmacs-gowl-menu-test-guard-decides ()
  "A `:when' form decides whether the entry appears."
  (should (cmacs-gowl-menu--visible-p '("Yes" :when t :call ignore)))
  (should-not (cmacs-gowl-menu--visible-p '("No" :when nil :call ignore))))

(ert-deftest cmacs-gowl-menu-test-guard-error-hides-entry ()
  "A guard that signals hides its entry rather than aborting the menu.
The entry most likely to have a broken guard is the one whose backend
is missing, which is precisely when the rest of the menu still needs
to open."
  (should-not
   (cmacs-gowl-menu--visible-p '("Boom" :when (error "deliberate")
                                 :call ignore))))

(ert-deftest cmacs-gowl-menu-test-shipped-tree-is-well-formed ()
  "Every shipped entry is a group with items or a leaf with a call.
An entry that is neither is a typo that would only surface when the
user selected it."
  ;; The shipped tree names gowl DEFUNs, which only exist when the
  ;; feature is compiled in.  On a build without it the tree is still
  ;; well-formed; the symbols just are not bound.
  (skip-unless (cmacs-feature-p 'gowl))
  (let ((seen 0))
    (cl-labels
        ((walk (entries path)
           (dolist (e entries)
             (should (stringp (car e)))
             (let ((items (plist-get (cdr e) :items))
                   (call (plist-get (cdr e) :call)))
               (should (or items call))
               (if items
                   (walk items (concat path "/" (car e)))
                 (setq seen (1+ seen))
                 ;; A symbol must name something real; a lambda is
                 ;; fine as it stands.
                 (when (and call (symbolp call))
                   (should (fboundp call))))))))
      (walk cmacs-gowl-menu-tree ""))
    (should (> seen 10))))

(ert-deftest cmacs-gowl-menu-test-power-group-has-lock-and-poweroff ()
  "The power group covers the session-ending actions.
This is the group the register asked for by name."
  (let* ((power (assoc "Power" cmacs-gowl-menu-tree))
         (labels (mapcar #'car (plist-get (cdr power) :items))))
    (should power)
    (dolist (want '("Lock" "Suspend" "Log out" "Reboot" "Power off"))
      (should (member want labels)))))

;;; wpctl parsing

(defconst cmacs-gowl-menu-tests--wpctl-status
  "PipeWire 'pipewire-0' [1.6.8, zach@host, cookie:1]
 └─ Clients:
        33. pipewire                        [1.6.8, zach@host, pid:1]

Audio
 ├─ Devices:
 │      73. Radeon High Definition Audio Controller [alsa]
 │
 ├─ Sinks:
 │      38. dummy Audio/Sink sink           [vol: 0.00 MUTED]
 │      93. USB Audio Analog Stereo         [vol: 1.00]
 │  *   95. Schiit Modi 3E Analog Stereo    [vol: 1.00]
 │
 ├─ Sources:
 │  *   96. AT2020USB+ Analog Stereo        [vol: 1.00]
 │
 └─ Streams:

Video
 ├─ Devices:
 │      78. C920 PRO HD Webcam              [v4l2]
 │
 └─ Sources:
        79. C920 PRO HD Webcam              [vol: 1.00]
"
  "Captured `wpctl status' output, trimmed but structurally faithful.")

(defmacro cmacs-gowl-menu-tests--with-wpctl (&rest body)
  "Run BODY with `wpctl status' stubbed to the captured output."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'cmacs-gowl-menu--output)
              (lambda (program &rest _args)
                (when (equal program "wpctl")
                  cmacs-gowl-menu-tests--wpctl-status))))
     ,@body))

(ert-deftest cmacs-gowl-menu-test-wpctl-parses-sinks ()
  "Sinks are found under the box-drawing tree, with their ids."
  (cmacs-gowl-menu-tests--with-wpctl
    (let ((sinks (cmacs-gowl-menu--wpctl-nodes "Sinks")))
      (should (= (length sinks) 3))
      (should (equal (mapcar #'cdr sinks) '("38" "93" "95"))))))

(ert-deftest cmacs-gowl-menu-test-wpctl-marks-the-default ()
  "The leading star marks the default and is kept in the label."
  (cmacs-gowl-menu-tests--with-wpctl
    (let ((sinks (cmacs-gowl-menu--wpctl-nodes "Sinks")))
      (should (string-prefix-p "* " (car (nth 2 sinks))))
      (should (string-prefix-p "  " (car (nth 0 sinks))))
      (should (string-match-p "Schiit Modi 3E" (car (nth 2 sinks)))))))

(ert-deftest cmacs-gowl-menu-test-wpctl-strips-volume ()
  "The trailing [vol: ...] is not part of the device name."
  (cmacs-gowl-menu-tests--with-wpctl
    (dolist (n (cmacs-gowl-menu--wpctl-nodes "Sinks"))
      (should-not (string-match-p "vol:" (car n))))))

(ert-deftest cmacs-gowl-menu-test-wpctl-audio-sources-not-video ()
  "Sources come from Audio, not Video.
Both sections are called `Sources:' -- microphones in one, webcams in
the other -- so a parser that ignores the top-level heading offers the
webcam as a microphone."
  (cmacs-gowl-menu-tests--with-wpctl
    (let ((sources (cmacs-gowl-menu--wpctl-nodes "Sources")))
      (should (= (length sources) 1))
      (should (string-match-p "AT2020USB" (car (car sources))))
      (should-not (cl-find-if (lambda (n) (string-match-p "Webcam" (car n)))
                              sources)))))

(ert-deftest cmacs-gowl-menu-test-wpctl-absent-is-empty-not-error ()
  "With wpctl missing the list is empty rather than an error."
  (cl-letf (((symbol-function 'cmacs-gowl-menu--output)
             (lambda (&rest _) nil)))
    (should-not (cmacs-gowl-menu--wpctl-nodes "Sinks"))))

;;; nmcli parsing

(ert-deftest cmacs-gowl-menu-test-nmcli-splits-rows ()
  "Terse output splits on unescaped colons."
  (cl-letf (((symbol-function 'cmacs-gowl-menu--output)
             (lambda (&rest _) "eth0:ethernet:connected\nwlan0:wifi:disconnected\n")))
    (should (equal (cmacs-gowl-menu--nmcli-rows "X" "y")
                   '(("eth0" "ethernet" "connected")
                     ("wlan0" "wifi" "disconnected"))))))

(ert-deftest cmacs-gowl-menu-test-nmcli-honours-escaped-colon ()
  "An escaped colon stays inside its field.
nmcli escapes a literal colon in a value, so an SSID like \"a:b\"
arrives as \"a\\\\:b\" -- split naively it becomes two fields and every
column after it shifts."
  (cl-letf (((symbol-function 'cmacs-gowl-menu--output)
             (lambda (&rest _) "*:my\\:net:70:WPA2\n")))
    (should (equal (cmacs-gowl-menu--nmcli-rows "X" "y")
                   '(("*" "my:net" "70" "WPA2"))))))

(ert-deftest cmacs-gowl-menu-test-nmcli-absent-is-empty ()
  "With nmcli missing the row list is empty rather than an error."
  (cl-letf (((symbol-function 'cmacs-gowl-menu--output)
             (lambda (&rest _) nil)))
    (should-not (cmacs-gowl-menu--nmcli-rows "X" "y"))))

;;; bluetoothctl parsing

(ert-deftest cmacs-gowl-menu-test-bt-devices ()
  "Paired devices parse into (LABEL . MAC)."
  (cl-letf (((symbol-function 'cmacs-gowl-menu--output)
             (lambda (&rest _)
               (concat "Device CC:F8:26:9C:F2:DB Zach's Buds2 Pro\n"
                       "Device 70:3E:97:9B:82:7B Wacom Intuos PBM\n"))))
    (let ((devices (cmacs-gowl-menu--bt-devices)))
      (should (= (length devices) 2))
      (should (equal (cdr (car devices)) "CC:F8:26:9C:F2:DB"))
      (should (string-match-p "Buds2" (car (car devices)))))))

(ert-deftest cmacs-gowl-menu-test-bt-ignores-noise ()
  "Lines that are not device records are skipped.
bluetoothctl prefixes agent chatter onto its output when run
non-interactively, and a parser that trusts every line invents devices
with mangled names."
  (cl-letf (((symbol-function 'cmacs-gowl-menu--output)
             (lambda (&rest _)
               (concat "Agent registered\n"
                       "Device AA:BB:CC:DD:EE:FF Speaker\n"
                       "[bluetooth]# \n"))))
    (let ((devices (cmacs-gowl-menu--bt-devices)))
      (should (= (length devices) 1))
      (should (equal (cdr (car devices)) "AA:BB:CC:DD:EE:FF")))))

;;; Confirmation

(ert-deftest cmacs-gowl-menu-test-destructive-actions-confirm ()
  "Reboot and power off ask first, and do nothing when refused."
  (let ((ran nil))
    (cl-letf (((symbol-function 'cmacs-gowl-menu--run)
               (lambda (&rest args) (push args ran)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (cmacs-gowl-menu-reboot)
      (cmacs-gowl-menu-poweroff)
      (should-not ran))
    (cl-letf (((symbol-function 'cmacs-gowl-menu--run)
               (lambda (&rest args) (push args ran)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (cmacs-gowl-menu-reboot)
      (should (equal (car ran) '("systemctl" "reboot"))))))

(ert-deftest cmacs-gowl-menu-test-suspend-does-not-confirm ()
  "Suspend is reversible, so it does not ask.
A confirmation on every lid-adjacent action is what trains people to
answer yes without reading."
  (let ((ran nil))
    (cl-letf (((symbol-function 'cmacs-gowl-menu--run)
               (lambda (&rest args) (push args ran)))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "should not be asked"))))
      (cmacs-gowl-menu-suspend)
      (should (equal (car ran) '("systemctl" "suspend"))))))

(provide 'cmacs-gowl-menu-tests)

;;; cmacs-gowl-menu-tests.el ends here
