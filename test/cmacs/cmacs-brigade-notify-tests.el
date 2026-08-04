;;; cmacs-brigade-notify-tests.el --- Tests for notification and voice  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The behaviour under test is "you find out", so the cases that matter
;; are the ones where the obvious implementation quietly does not tell
;; you: an event that fires while you are away, a notifier that throws,
;; an escalation for something you already dealt with.
;;
;; Nothing here records audio or speaks.  Both are subprocesses with
;; hardware behind them; the notifiers are stubbed and the parsing,
;; routing and away logic -- the parts that can actually be wrong -- are
;; tested directly.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-notify nil 'noerror)
(require 'cmacs-brigade-voice nil 'noerror)

(defun cmacs-brigade-notify-tests--available-p ()
  (featurep 'cmacs-brigade-notify))

(defvar cmacs-brigade-notify-tests--fired nil
  "Events captured by the stub notifier.")

(defmacro cmacs-brigade-notify-tests--with-stub (routes &rest body)
  "Run BODY with every event routed to a recording stub, under ROUTES.

The stub replaces the shipped notifiers wholesale: a test that actually
spoke would need piper, a sound device and eight seconds."
  (declare (indent 1))
  `(let ((cmacs-brigade-notify-tests--fired nil)
         (cmacs-brigade-notify-enabled t)
         (cmacs-brigade-notify-escalate-seconds nil)
         (cmacs-brigade-notify--held nil)
         (cmacs-brigade-notify--pending-input (make-hash-table :test 'equal))
         (cmacs-brigade-notify--last-activity (float-time))
         (cmacs-brigade-notify-routes ,routes))
     (cmacs-brigade-register-notifier
      :name 'stub
      :notify (lambda (ev) (push ev cmacs-brigade-notify-tests--fired)))
     ,@body))

(defun cmacs-brigade-notify-tests--kinds ()
  (mapcar (lambda (e) (plist-get e :kind))
          (reverse cmacs-brigade-notify-tests--fired)))


;;;; Routing

(ert-deftest cmacs-brigade-notify-routes-by-kind ()
  "Only the notifiers routed for a kind fire for it."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (stub))
                                           (started . ()))
    (cmacs-brigade-notify 'finished :agent "a")
    (cmacs-brigade-notify 'started :agent "a")
    (should (equal (cmacs-brigade-notify-tests--kinds) '(finished)))))

(ert-deftest cmacs-brigade-notify-disabled-is-silent ()
  "Nothing fires when notification is switched off."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (stub)))
    (let ((cmacs-brigade-notify-enabled nil))
      (cmacs-brigade-notify 'finished :agent "a"))
    (should (null cmacs-brigade-notify-tests--fired))))

(ert-deftest cmacs-brigade-notify-unknown-notifier-is-skipped ()
  "A route naming something unregistered does not error."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (nope stub)))
    (cmacs-brigade-notify 'finished :agent "a")
    (should (equal (cmacs-brigade-notify-tests--kinds) '(finished)))))

(ert-deftest cmacs-brigade-notify-unavailable-notifier-is-skipped ()
  "An :available predicate returning nil skips without erroring."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (absent stub)))
    (cmacs-brigade-register-notifier
     :name 'absent
     :available #'ignore
     :notify (lambda (_) (error "must not be called")))
    (cmacs-brigade-notify 'finished :agent "a")
    (should (equal (cmacs-brigade-notify-tests--kinds) '(finished)))))

(ert-deftest cmacs-brigade-notify-one-broken-notifier-does-not-block-others ()
  "A notifier that throws must not cost you the rest.

The whole point is finding out something happened; a channel failing is
the case where that matters most."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (broken stub)))
    (cmacs-brigade-register-notifier
     :name 'broken :notify (lambda (_) (error "boom")))
    (cmacs-brigade-notify 'finished :agent "a")
    (should (equal (cmacs-brigade-notify-tests--kinds) '(finished)))))


;;;; Descriptions

(ert-deftest cmacs-brigade-notify-supplies-a-description ()
  "An event with no :text gets a spoken-sounding one."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (stub)))
    (cmacs-brigade-notify 'finished :agent "researcher")
    (let ((ev (car cmacs-brigade-notify-tests--fired)))
      (should (equal (plist-get ev :text) "researcher finished.")))))

(ert-deftest cmacs-brigade-notify-keeps-an-explicit-description ()
  "A caller-supplied :text is not overwritten."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((needs-input . (stub)))
    (cmacs-brigade-notify 'needs-input :agent "a" :text "Which tier?")
    (should (equal (plist-get (car cmacs-brigade-notify-tests--fired) :text)
                   "Which tier?"))))

(ert-deftest cmacs-brigade-notify-marks-urgency ()
  "Things that need you are urgent; things that merely finished are not."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((needs-input . (stub))
                                           (finished . (stub)))
    (cmacs-brigade-notify 'needs-input :agent "a")
    (cmacs-brigade-notify 'finished :agent "a")
    (let ((evs (reverse cmacs-brigade-notify-tests--fired)))
      (should (plist-get (nth 0 evs) :urgent))
      (should-not (plist-get (nth 1 evs) :urgent)))))


;;;; Away and the digest -- the reason the file exists

(ert-deftest cmacs-brigade-notify-away-holds-non-urgent-events ()
  "A completion that fires while you are away is held for the digest."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (stub))
                                           (away-quiet . ()))
    (setq cmacs-brigade-notify--last-activity
          (- (float-time) (* 10 cmacs-brigade-notify-away-seconds)))
    (should (cmacs-brigade-notify-away-p))
    (cmacs-brigade-notify 'finished :agent "a")
    ;; Held, and routed to away-quiet (empty here) rather than the
    ;; normal `finished' route.
    (should (null cmacs-brigade-notify-tests--fired))
    (should (= 1 (length cmacs-brigade-notify--held)))))

(ert-deftest cmacs-brigade-notify-away-still-fires-urgent-events ()
  "Something that needs you fires even while you are away.

Held-and-quiet is right for a completion and wrong for a question: the
notification is the only thing that might bring you back."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((needs-input . (stub)))
    (setq cmacs-brigade-notify--last-activity
          (- (float-time) (* 10 cmacs-brigade-notify-away-seconds)))
    (cmacs-brigade-notify 'needs-input :agent "a")
    (should (equal (cmacs-brigade-notify-tests--kinds) '(needs-input)))))

(ert-deftest cmacs-brigade-notify-digest-counts-what-happened ()
  "The digest reports finished, failed and still-waiting separately."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (puthash "t1" '(:kind needs-input) cmacs-brigade-notify--pending-input)
    (let ((text (cmacs-brigade-notify--digest-text
                 '((:kind finished) (:kind finished) (:kind failed))
                 1800)))
      (should (string-match-p "30 min" text))
      (should (string-match-p "2 finished" text))
      (should (string-match-p "1 failed" text))
      (should (string-match-p "1 waiting for you" text)))))

(ert-deftest cmacs-brigade-notify-digest-omits-empty-categories ()
  "A digest with only completions does not claim zero failures."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (let ((text (cmacs-brigade-notify--digest-text '((:kind finished)) 300)))
      (should (string-match-p "1 finished" text))
      (should-not (string-match-p "failed" text))
      (should-not (string-match-p "waiting" text)))))

(ert-deftest cmacs-brigade-notify-return-delivers-and-clears ()
  "Coming back delivers the digest once, not on every later command."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (stub))
                                           (away-quiet . ()))
    (let ((delivered 0))
      (let ((cmacs-brigade-notify-digest-speak nil)
            (cmacs-brigade-notify-digest-functions
             (list (lambda (&rest _) (setq delivered (1+ delivered))))))
        (setq cmacs-brigade-notify--last-activity
              (- (float-time) (* 10 cmacs-brigade-notify-away-seconds)))
        (cmacs-brigade-notify 'finished :agent "a")
        (should cmacs-brigade-notify--held)
        ;; The moment of return.
        (cmacs-brigade-notify--post-command)
        (should (= delivered 1))
        (should (null cmacs-brigade-notify--held))
        ;; Every subsequent command: nothing more to say.
        (cmacs-brigade-notify--post-command)
        (should (= delivered 1))))))

(ert-deftest cmacs-brigade-notify-no-digest-without-events ()
  "Returning after a long idle with nothing held says nothing."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (let ((delivered 0))
      (let ((cmacs-brigade-notify-digest-functions
             (list (lambda (&rest _) (setq delivered (1+ delivered))))))
        (setq cmacs-brigade-notify--last-activity
              (- (float-time) (* 10 cmacs-brigade-notify-away-seconds)))
        (cmacs-brigade-notify--post-command)
        (should (= delivered 0))))))

(ert-deftest cmacs-brigade-notify-present-does-not-hold ()
  "While you are here, events fire normally and nothing accumulates."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((finished . (stub)))
    (cmacs-brigade-notify 'finished :agent "a")
    (should (equal (cmacs-brigade-notify-tests--kinds) '(finished)))
    (should (null cmacs-brigade-notify--held))))


;;;; Escalation

(ert-deftest cmacs-brigade-notify-tracks-what-is-waiting ()
  "A needs-input event is remembered until acknowledged."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((needs-input . (stub)))
    (cmacs-brigade-notify 'needs-input :task "t1" :agent "a")
    (should (= 1 (length (cmacs-brigade-notify-pending))))
    (cmacs-brigade-notify-acknowledge "t1")
    (should (null (cmacs-brigade-notify-pending)))))

(ert-deftest cmacs-brigade-notify-acknowledging-unknown-is-harmless ()
  "Acknowledging something that was never pending does not error."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (should-not (cmacs-brigade-notify-acknowledge "never-existed"))))

(ert-deftest cmacs-brigade-notify-escalation-stops-once-answered ()
  "A scheduled repeat does not fire for a task already dealt with.

The failure this guards is the one that trains you to ignore the sound."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '((needs-input . (stub)))
    (let ((cmacs-brigade-notify-escalate-seconds '(0.05)))
      (cmacs-brigade-notify 'needs-input :task "t1" :agent "a")
      (cmacs-brigade-notify-acknowledge "t1")
      (sleep-for 0.15)
      ;; Only the original, no repeat.
      (should (= 1 (length cmacs-brigade-notify-tests--fired))))))


;;;; Status

(ert-deftest cmacs-brigade-notify-status-is-a-sentence ()
  "Status reads as something that can be spoken."
  (skip-unless (cmacs-brigade-notify-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (let ((s (cmacs-brigade-notify-status)))
      (should (stringp s))
      (should (string-suffix-p "." s)))))


;;;; Voice

(defun cmacs-brigade-voice-tests--available-p ()
  (featurep 'cmacs-brigade-voice))

(ert-deftest cmacs-brigade-voice-classifies-spoken-questions ()
  "Each phrasing reaches the question it is actually asking."
  (skip-unless (cmacs-brigade-voice-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    ;; Nothing running, nothing pending: the answers are the empty ones,
    ;; which is enough to tell the four branches apart.
    (should (string-match-p "waiting"
                            (cmacs-brigade-voice-answer-query
                             "what is waiting on me")))
    (should (string-match-p "waiting"
                            (cmacs-brigade-voice-answer-query
                             "is anything stuck")))
    (should (string-match-p "dollar\\|cannot see"
                            (cmacs-brigade-voice-answer-query
                             "how much has this cost")))
    (should (string-match-p "finished\\|cannot see"
                            (cmacs-brigade-voice-answer-query
                             "what has finished")))))

(ert-deftest cmacs-brigade-voice-unrecognised-question-gives-status ()
  "Something that matches nothing still answers, rather than erroring."
  (skip-unless (cmacs-brigade-voice-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (let ((s (cmacs-brigade-voice-answer-query "banana telephone")))
      (should (stringp s))
      (should (string-suffix-p "." s)))))

(ert-deftest cmacs-brigade-voice-waiting-beats-status ()
  "\"What still needs me\" is a waiting query, not a status one.

Ordering bug bait: the status regexp matches \"doing\" and \"active\",
and a question about blocked tasks must not fall through to it."
  (skip-unless (cmacs-brigade-voice-tests--available-p))
  (cmacs-brigade-notify-tests--with-stub '()
    (puthash "t1" '(:kind needs-input :agent "coder")
             cmacs-brigade-notify--pending-input)
    (let ((s (cmacs-brigade-voice-answer-query "what still needs me")))
      (should (string-match-p "coder" s)))))

(ert-deftest cmacs-brigade-voice-summarize-shortens-long-speech ()
  "A long dictated task still yields a headline-length heading."
  (skip-unless (cmacs-brigade-voice-tests--available-p))
  (let ((long (make-string 300 ?x)))
    (should (<= (length (cmacs-brigade-voice--summarize long)) 60)))
  ;; Newlines would break the headline; they must not survive.
  (should-not (string-match-p "\n" (cmacs-brigade-voice--summarize
                                    "one\ntwo\nthree"))))

(ert-deftest cmacs-brigade-voice-summarize-keeps-short-speech-intact ()
  "A short phrase is used verbatim, not truncated or padded."
  (skip-unless (cmacs-brigade-voice-tests--available-p))
  (should (equal (cmacs-brigade-voice--summarize "  survey the notes  ")
                 "survey the notes")))

(ert-deftest cmacs-brigade-voice-not-recording-stop-errors ()
  "Stopping when nothing is recording is a user error, not a crash."
  (skip-unless (cmacs-brigade-voice-tests--available-p))
  (should-not (cmacs-brigade-voice-recording-p))
  (should-error (cmacs-brigade-voice-stop) :type 'user-error))

(provide 'cmacs-brigade-notify-tests)

;;; cmacs-brigade-notify-tests.el ends here
