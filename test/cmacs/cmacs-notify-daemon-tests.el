;;; cmacs-notify-daemon-tests.el --- Tests for the notification daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; ERT tests for `cmacs-notify-daemon'.
;;
;; None of these register anything on a bus.  A test that claimed
;; org.freedesktop.Notifications would take the name from whatever
;; owns it on the developer's own desktop for the duration of the run,
;; which is a rude thing for a test suite to do and would make the
;; result depend on the session it ran in.  The protocol handlers are
;; called directly instead, with the D-Bus signal emitters stubbed so
;; the assertions can see what would have been sent.
;;
;; The wire behaviour they stand in for -- real notify-send, gdbus
;; Notify with actions, replaces_id, CloseNotification -- was verified
;; against a live daemon on a private bus.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-notify-daemon)

;;; Fixture

(defvar cmacs-notify-daemon-tests--signals nil
  "Signals the daemon tried to emit, as (KIND ID EXTRA).")

(defmacro cmacs-notify-daemon-tests--with-daemon (&rest body)
  "Run BODY against a clean, bus-free daemon.
History, ids and the active table are rebound, and the two signal
emitters are replaced with recorders, so nothing touches a real bus and
nothing leaks into the next test."
  (declare (indent 0))
  `(let ((cmacs-notify-daemon-history nil)
         (cmacs-notify-daemon--next-id 1)
         (cmacs-notify-daemon--active (make-hash-table :test #'eql))
         (cmacs-notify-daemon-echo nil)
         (cmacs-notify-daemon-pop-to-buffer-urgencies nil)
         (cmacs-notify-daemon-log-file nil)
         (cmacs-notify-daemon-functions nil)
         (cmacs-notify-daemon-buffer " *notify-daemon-test*")
         (cmacs-notify-daemon-tests--signals nil))
     (cl-letf (((symbol-function 'cmacs-notify-daemon--emit-closed)
                (lambda (id reason)
                  (push (list 'closed id reason)
                        cmacs-notify-daemon-tests--signals)))
               ((symbol-function 'cmacs-notify-daemon--emit-action)
                (lambda (id key)
                  (push (list 'action id key)
                        cmacs-notify-daemon-tests--signals))))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer cmacs-notify-daemon-buffer)
           (kill-buffer cmacs-notify-daemon-buffer))))))

(defun cmacs-notify-daemon-tests--notify
    (&rest plist)
  "Call the Notify handler with defaults overridden by PLIST."
  (cmacs-notify-daemon--notify
   (or (plist-get plist :app) "test")
   (or (plist-get plist :replaces) 0)
   (or (plist-get plist :icon) "")
   (or (plist-get plist :summary) "Summary")
   (or (plist-get plist :body) "Body")
   (plist-get plist :actions)
   (plist-get plist :hints)
   ;; 0 means never expire, which is the useful default for a test:
   ;; no timer is created, so nothing fires later into another test.
   (or (plist-get plist :timeout) 0)))

;;; Urgency

(ert-deftest cmacs-notify-daemon-test-urgency-levels ()
  "The urgency hint maps 0/1/2 to low/normal/critical."
  (should (eq 'low (cmacs-notify-daemon--urgency '(("urgency" (0))))))
  (should (eq 'normal (cmacs-notify-daemon--urgency '(("urgency" (1))))))
  (should (eq 'critical (cmacs-notify-daemon--urgency '(("urgency" (2)))))))

(ert-deftest cmacs-notify-daemon-test-urgency-defaults-normal ()
  "A missing or unparseable urgency is normal, not an error.
Plenty of senders omit the hint entirely."
  (should (eq 'normal (cmacs-notify-daemon--urgency nil)))
  (should (eq 'normal (cmacs-notify-daemon--urgency '(("category" ("im"))))))
  (should (eq 'normal (cmacs-notify-daemon--urgency '(("urgency" ("x")))))))

(ert-deftest cmacs-notify-daemon-test-urgency-unwraps-nesting ()
  "The value survives however deeply dbus.el wrapped the variant.
Senders differ, and a byte and an integer arrive nested differently."
  (should (eq 'critical (cmacs-notify-daemon--urgency '(("urgency" ((2)))))))
  (should (eq 'critical (cmacs-notify-daemon--urgency '(("urgency" 2))))))

;;; Actions

(ert-deftest cmacs-notify-daemon-test-parse-actions ()
  "The flat key/label array becomes an alist in order."
  (should (equal (cmacs-notify-daemon--parse-actions
                  '("reply" "Reply" "archive" "Archive"))
                 '(("reply" . "Reply") ("archive" . "Archive")))))

(ert-deftest cmacs-notify-daemon-test-parse-actions-empty ()
  "No actions is nil, not a list containing nil."
  (should-not (cmacs-notify-daemon--parse-actions nil))
  (should-not (cmacs-notify-daemon--parse-actions '())))

(ert-deftest cmacs-notify-daemon-test-parse-actions-odd-length ()
  "A trailing key with no label is dropped rather than paired with nil.
A nil label would reach `format' in the renderer and print \"nil\" as
a button."
  (should (equal (cmacs-notify-daemon--parse-actions
                  '("reply" "Reply" "orphan"))
                 '(("reply" . "Reply")))))

;;; Notify

(ert-deftest cmacs-notify-daemon-test-notify-records-history ()
  "A notification lands in history with its fields intact."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify
               :app "mailer" :summary "New mail" :body "lunch?"
               :hints '(("urgency" (2))))))
      (should (= id 1))
      (should (= (length cmacs-notify-daemon-history) 1))
      (let ((n (car cmacs-notify-daemon-history)))
        (should (equal (plist-get n :app) "mailer"))
        (should (equal (plist-get n :summary) "New mail"))
        (should (equal (plist-get n :body) "lunch?"))
        (should (eq (plist-get n :urgency) 'critical))))))

(ert-deftest cmacs-notify-daemon-test-ids-increment-and-skip-zero ()
  "Ids are handed out in sequence and are never 0.
The specification reserves 0 to mean \"no notification\"."
  (cmacs-notify-daemon-tests--with-daemon
    (should (= 1 (cmacs-notify-daemon-tests--notify)))
    (should (= 2 (cmacs-notify-daemon-tests--notify)))
    (should (= 3 (cmacs-notify-daemon-tests--notify)))))

(ert-deftest cmacs-notify-daemon-test-id-wraps-to-one-not-zero ()
  "At the uint32 ceiling the counter wraps to 1, not to 0."
  (cmacs-notify-daemon-tests--with-daemon
    (setq cmacs-notify-daemon--next-id 4294967295)
    (should (= 4294967295 (cmacs-notify-daemon-tests--notify)))
    (should (= 1 (cmacs-notify-daemon-tests--notify)))))

(ert-deftest cmacs-notify-daemon-test-replaces-id-replaces ()
  "replaces_id supersedes the entry instead of stacking a second one.
A progress notification updating itself would otherwise fill history
by itself."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify
               :app "dl" :summary "Downloading" :body "0%")))
      (should (= id (cmacs-notify-daemon-tests--notify
                     :app "dl" :replaces id
                     :summary "Downloading" :body "100%")))
      (should (= (length cmacs-notify-daemon-history) 1))
      (should (equal (plist-get (car cmacs-notify-daemon-history) :body)
                     "100%")))))

(ert-deftest cmacs-notify-daemon-test-history-is-capped ()
  "History stops at `cmacs-notify-daemon-history-limit', newest kept."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((cmacs-notify-daemon-history-limit 5))
      (dotimes (i 12)
        (cmacs-notify-daemon-tests--notify
         :summary (format "n%d" i)))
      (should (= (length cmacs-notify-daemon-history) 5))
      (should (equal (plist-get (car cmacs-notify-daemon-history) :summary)
                     "n11")))))

(ert-deftest cmacs-notify-daemon-test-hook-runs-with-plist ()
  "`cmacs-notify-daemon-functions' sees the arriving notification."
  (cmacs-notify-daemon-tests--with-daemon
    (let (seen)
      (let ((cmacs-notify-daemon-functions
             (list (lambda (n) (push (plist-get n :summary) seen)))))
        (cmacs-notify-daemon-tests--notify :summary "hello"))
      (should (equal seen '("hello"))))))

(ert-deftest cmacs-notify-daemon-test-hook-error-does-not-stop-delivery ()
  "A signalling hook function must not lose the notification.
The hook is a user extension point; a broken one should cost its own
output, not the daemon's."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((cmacs-notify-daemon-functions
           (list (lambda (_n) (error "deliberate")))))
      (cmacs-notify-daemon-tests--notify :summary "still arrives"))
    (should (= (length cmacs-notify-daemon-history) 1))
    (should (equal (plist-get (car cmacs-notify-daemon-history) :summary)
                   "still arrives"))))

;;; Closing

(ert-deftest cmacs-notify-daemon-test-close-emits-once ()
  "CloseNotification emits NotificationClosed with reason 3, once.
A second close on the same id emits nothing, so a sender closing a
notification the user already dismissed does not get a duplicate."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify)))
      (cmacs-notify-daemon--close-notification id)
      (should (equal cmacs-notify-daemon-tests--signals
                     (list (list 'closed id 3))))
      (cmacs-notify-daemon--close-notification id)
      (should (= (length cmacs-notify-daemon-tests--signals) 1)))))

(ert-deftest cmacs-notify-daemon-test-close-unknown-id-is-silent ()
  "Closing an id that was never issued emits nothing."
  (cmacs-notify-daemon-tests--with-daemon
    (cmacs-notify-daemon--close-notification 9999)
    (should-not cmacs-notify-daemon-tests--signals)))

(ert-deftest cmacs-notify-daemon-test-never-expiring-closes-cleanly ()
  "A notification with timeout 0 has a nil timer and still closes.
Presence in the active table has to be tested with an explicit default,
because a nil timer looks exactly like an absent key."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify :timeout 0)))
      (should-not (gethash id cmacs-notify-daemon--active))
      (cmacs-notify-daemon--close id 2)
      (should (equal cmacs-notify-daemon-tests--signals
                     (list (list 'closed id 2)))))))

(ert-deftest cmacs-notify-daemon-test-close-keeps-history ()
  "Closing a notification leaves its history entry.
That is the whole difference from a toast stack."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify :summary "kept")))
      (cmacs-notify-daemon--close-notification id)
      (should (= (length cmacs-notify-daemon-history) 1))
      (should (equal (plist-get (car cmacs-notify-daemon-history) :summary)
                     "kept")))))

(ert-deftest cmacs-notify-daemon-test-expiry-timer-is-created ()
  "A positive timeout creates a timer; 0 does not."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((with (cmacs-notify-daemon-tests--notify :timeout 60000))
          (without (cmacs-notify-daemon-tests--notify :timeout 0)))
      (unwind-protect
          (progn
            (should (timerp (gethash with cmacs-notify-daemon--active)))
            (should-not (gethash without cmacs-notify-daemon--active)))
        ;; Cancel so a 60s timer cannot fire into a later test.
        (cmacs-notify-daemon--close with 4)))))

;;; Rendering

(ert-deftest cmacs-notify-daemon-test-entry-renders-org ()
  "A notification renders as an Org headline with its metadata."
  (cmacs-notify-daemon-tests--with-daemon
    (cmacs-notify-daemon-tests--notify
     :app "mailer" :summary "New mail" :body "lunch?"
     :hints '(("urgency" (2))))
    (let ((text (cmacs-notify-daemon--entry-string
                 (car cmacs-notify-daemon-history))))
      (should (string-match-p "^\\* New mail" text))
      (should (string-match-p ":critical:" text))
      (should (string-match-p ":APP:      mailer" text))
      (should (string-match-p "lunch\\?" text)))))

(ert-deftest cmacs-notify-daemon-test-actions-render-as-links ()
  "Actions render as elisp links that invoke them."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify
               :actions '("reply" "Reply" "archive" "Archive"))))
      (let ((text (cmacs-notify-daemon--entry-string
                   (car cmacs-notify-daemon-history))))
        (should (string-match-p
                 (regexp-quote
                  (format "(cmacs-notify-daemon-invoke-action %d \"reply\")" id))
                 text))
        (should (string-match-p "\\]\\[Reply\\]\\]" text))))))

(ert-deftest cmacs-notify-daemon-test-buffer-lists-newest-first ()
  "The history buffer renders newest first."
  (cmacs-notify-daemon-tests--with-daemon
    (cmacs-notify-daemon-tests--notify :summary "older")
    (cmacs-notify-daemon-tests--notify :summary "newer")
    (with-current-buffer (cmacs-notify-daemon-refresh)
      (goto-char (point-min))
      (should (re-search-forward "^\\* newer" nil t))
      (should (re-search-forward "^\\* older" nil t)))))

(ert-deftest cmacs-notify-daemon-test-empty-buffer-says-so ()
  "With no notifications the buffer is not blank."
  (cmacs-notify-daemon-tests--with-daemon
    (with-current-buffer (cmacs-notify-daemon-refresh)
      (should (string-match-p "Nothing yet" (buffer-string))))))

;;; Actions from the buffer

(ert-deftest cmacs-notify-daemon-test-invoke-action-emits ()
  "Invoking an action emits ActionInvoked with its key."
  (cmacs-notify-daemon-tests--with-daemon
    (let ((id (cmacs-notify-daemon-tests--notify
               :actions '("reply" "Reply"))))
      (cmacs-notify-daemon-invoke-action id "reply")
      (should (equal cmacs-notify-daemon-tests--signals
                     (list (list 'action id "reply")))))))

;;; Specification surface

(ert-deftest cmacs-notify-daemon-test-server-information ()
  "GetServerInformation returns name, vendor, version and spec version."
  (let ((info (cmacs-notify-daemon--server-information)))
    (should (= (length info) 4))
    (should (equal (nth 0 info) "cmacs"))
    (should (equal (nth 3 info) cmacs-notify-daemon-spec-version))))

(ert-deftest cmacs-notify-daemon-test-capabilities-are-honest ()
  "Every claimed capability is one the daemon actually provides.
A capability is a promise the sender cannot verify, so claiming
\"body-markup\" and then showing the markup as literal text would be
worse than not claiming it."
  (let ((caps (car (cmacs-notify-daemon--capabilities))))
    (should (member "body" caps))
    (should (member "actions" caps))
    (should (member "persistence" caps))
    ;; Not claimed, because nothing renders them.
    (should-not (member "body-markup" caps))
    (should-not (member "body-images" caps))
    (should-not (member "sound" caps))))

(provide 'cmacs-notify-daemon-tests)

;;; cmacs-notify-daemon-tests.el ends here
