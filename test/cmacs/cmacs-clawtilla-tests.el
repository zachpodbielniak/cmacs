;;; cmacs-clawtilla-tests.el --- Tests for the clawtilla client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What can be tested without a daemon: the marshalling, the rules the
;; library answers, the rendering, and the source guards.
;;
;; The availability predicate checks a concrete DEFUN as well as the
;; flag.  The flag says the subsystem was compiled in; the DEFUN says
;; its symbols actually loaded -- and `cmacs-feature-p' is deliberately
;; not used, because it lives in cmacs.el, which is not loaded when a
;; test file is run on its own.  A void function there is a skip, and
;; every `skip-unless' in the file then passes vacuously while the suite
;; reports green having executed nothing.

;;; Code:

(require 'ert)
(require 'subr-x)

(defun cmacs-clawtilla-tests--available-p ()
  "Non-nil when this build compiled in the clawtilla client."
  (and (boundp 'is-cmacs-clawtilla) is-cmacs-clawtilla
       (fboundp 'cmacs-clawtilla-supported-p)))

(when (cmacs-clawtilla-tests--available-p)
  (require 'cmacs-clawtilla)
  (require 'cmacs-clawtilla-ui)
  (require 'cmacs-clawtilla-chat nil t))


;;;; The feature flag.

(ert-deftest cmacs-clawtilla-feature-flag ()
  "The feature flag is always bound, and agrees with the primitives."
  (should (boundp 'is-cmacs-clawtilla))
  (should (eq (and (boundp 'IS-CMACS-CLAWTILLA) IS-CMACS-CLAWTILLA)
              (and (boundp 'is-cmacs-clawtilla) is-cmacs-clawtilla)))
  (when (and (boundp 'is-cmacs-clawtilla) is-cmacs-clawtilla)
    (should (fboundp 'cmacs-clawtilla-supported-p))
    (should (cmacs-clawtilla-supported-p))))


;;;; Marshalling.

(ert-deftest cmacs-clawtilla-encode-takes-either-shape ()
  "A payload may be an alist or a plist.

Accepted in one place rather than at each call site, because a call
site that picks a representation per caller has to enumerate them and
that list is always one short -- which is exactly how a codex session
came to hand a plist to a TOML emitter expecting pairs."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((from-alist (cmacs-clawtilla--encode '((agent . "scout"))))
        (from-plist (cmacs-clawtilla--encode '(:agent "scout"))))
    (should (equal from-alist from-plist))
    (should (equal (cmacs-clawtilla--parse from-alist) '((agent . "scout")))))
  ;; nil is nil, not "{}": the daemon distinguishes a frame with no
  ;; payload from one carrying an empty object.
  (should (null (cmacs-clawtilla--encode nil))))

(ert-deftest cmacs-clawtilla-member-json-keeps-null-a-null ()
  "Cutting a member out of a reply must not turn null into an object.

This is a regression test for a bug that produced no visible symptom.
`json-parse-string' maps JSON null to nil and `json-serialize' writes
nil back as `{}', so re-encoding a parsed reply turned an agent whose
team is null -- which every agent in no team has -- into one whose team
is an OBJECT.  The team tally read that member and json-glib logged a
CRITICAL on every redraw, fatal under G_DEBUG=fatal-criticals, while the
counts on screen stayed correct because they came from the parsed copy."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let* ((raw "{\"agents\":[{\"id\":\"a\",\"team\":null},\
{\"id\":\"b\",\"team\":\"t\"}]}")
         (agents (cmacs-clawtilla-member-json raw 'agents)))
    (should (stringp agents))
    (should (string-match-p "\"team\":null" agents))
    (should-not (string-match-p "\"team\":{}" agents))
    ;; And an array stays an array.  A JSON array of objects parsed as a
    ;; list is a list of conses, which `json-serialize' cannot tell from
    ;; an alist -- it signals rather than guessing, inside a reply
    ;; callback where the signal is swallowed.
    (should (string-prefix-p "[" agents))))

(ert-deftest cmacs-clawtilla-get-walks-a-path ()
  "`cmacs-clawtilla-get' reaches nested members and tolerates absence."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((data (cmacs-clawtilla--parse "{\"hold\":{\"held\":true},\"n\":2}")))
    (should (eq t (cmacs-clawtilla-get data 'hold 'held)))
    (should (equal 2 (cmacs-clawtilla-get data 'n)))
    (should (null (cmacs-clawtilla-get data 'missing 'deeper)))))


;;;; The rules the library answers.

(ert-deftest cmacs-clawtilla-activity-label-comes-from-the-library ()
  "The activity sentence is the library's, including its absence.

Not assembled here: the CLI read `busy' and `peer' for as long as they
existed and rendered neither, and the web client drew a bare badge that
dropped `peer'.  A sentence written in three places is three
sentences."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (should (null (cmacs-clawtilla--activity-label nil nil)))
  (let ((working (cmacs-clawtilla--activity-label t nil))
        (with-peer (cmacs-clawtilla--activity-label t "scout")))
    (should (stringp working))
    (should (stringp with-peer))
    ;; The peer has to appear, which is the half the web client lost.
    (should (string-match-p "scout" with-peer))
    (should-not (equal working with-peer))))

(ert-deftest cmacs-clawtilla-run-boundaries-answer-two-questions ()
  "A run start and a new day are separate answers.

A new day always starts a run, but a run can start without the day
changing.  A client that collapsed them would either lose the day
divider or draw one on every message."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((first (cmacs-clawtilla--parse
                (cmacs-clawtilla--run-is-start nil nil "a" "2026-01-01")))
        (same (cmacs-clawtilla--parse
               (cmacs-clawtilla--run-is-start "a" "2026-01-01" "a"
                                              "2026-01-01")))
        (next-day (cmacs-clawtilla--parse
                   (cmacs-clawtilla--run-is-start "a" "2026-01-01" "a"
                                                  "2026-01-02"))))
    (should (eq t (alist-get 'start first)))
    (should (eq t (alist-get 'new-day first)))
    (should (null (alist-get 'start same)))
    (should (null (alist-get 'new-day same)))
    ;; Same sender, different day: a run starts and so does a day.
    (should (eq t (alist-get 'start next-day)))
    (should (eq t (alist-get 'new-day next-day)))))

(ert-deftest cmacs-clawtilla-alert-tiers-skip-the-noise ()
  "Which events are worth interrupting somebody for is the library's.

`turn.step' and `agent.typing' arrive constantly during a turn; a
client that alerted on them would train somebody to ignore the tier
that matters."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (should (equal "skip" (cmacs-clawtilla--alert-tier "turn.step" "a")))
  (should (equal "skip" (cmacs-clawtilla--alert-tier "agent.typing" "a")))
  (should (equal "error" (cmacs-clawtilla--alert-tier "message.refused" "a"))))

(ert-deftest cmacs-clawtilla-alert-on-screen-arrives-read ()
  "An alert that lands in front of somebody has been seen.

Marking it unread would leave a count that reading cannot clear."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (should (cmacs-clawtilla--alert-arrives-read t "error"))
  (should-not (cmacs-clawtilla--alert-arrives-read nil "error")))

(ert-deftest cmacs-clawtilla-unread-ignores-your-own-and-the-past ()
  "The unread rule is the library's, including its awkward clause.

Not your own room, not your own message, and not older than the
connection.  That last one is what stops connecting to a fleet marking
its whole history unread -- a count nothing can then clear."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((connected 1000)
        (rows (json-serialize ["room:a"])))
    ;; Somebody else, another room, after connecting, with a row: counts.
    (should (cmacs-clawtilla--unread-should-count
             "room:a" "room:b" "scout" 2000 connected rows))
    ;; The room being looked at: does not.
    (should-not (cmacs-clawtilla--unread-should-count
                 "room:a" "room:a" "scout" 2000 connected rows))
    ;; Older than the connection: does not.  This is the clause that
    ;; stops connecting to a fleet marking its whole history unread.
    (should-not (cmacs-clawtilla--unread-should-count
                 "room:a" "room:b" "scout" 10 connected rows))
    ;; Your own message: does not.
    (should-not (cmacs-clawtilla--unread-should-count
                 "room:a" "room:b" "user" 2000 connected rows))
    ;; A room this client has no row for: does not, because there is
    ;; nothing on screen a count could appear on.  Passing no rows at
    ;; all is the same answer, which is why omitting them made an
    ;; unread count impossible in the first cut of this primitive.
    (should-not (cmacs-clawtilla--unread-should-count
                 "room:z" "room:b" "scout" 2000 connected rows))
    (should-not (cmacs-clawtilla--unread-should-count
                 "room:a" "room:b" "scout" 2000 connected nil))))

(ert-deftest cmacs-clawtilla-team-tally-is-counted-once ()
  "The tally is the library's count, not one made from the rows drawn."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((tally (cmacs-clawtilla--parse
                (cmacs-clawtilla--team-tally
                 "[{\"id\":\"a\",\"team\":\"t\",\"state\":\"running\"},\
{\"id\":\"b\",\"team\":\"t\",\"state\":\"stopped\"},\
{\"id\":\"c\",\"team\":null,\"state\":\"running\"}]"
                 "t"))))
    (should (equal 2 (alist-get 'total tally)))
    (should (equal 1 (alist-get 'running tally)))))


;;;; Enumerations.

(ert-deftest cmacs-clawtilla-enumerations-are-walked ()
  "Every enumeration this client offers is asked for, and answers.

An empty answer would mean the client silently offering nothing to
choose from, which looks like a feature that does not exist."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (dolist (family '("section" "computer-type" "computer-view" "import-mode"
                    "measure-unit" "memory-scope" "appearance-scheme"
                    "appearance-theme" "relabel"))
    (let ((entries (cmacs-clawtilla-enum family)))
      (should entries)
      (dolist (entry entries)
        (should (stringp (alist-get 'nick entry)))
        (should (stringp (alist-get 'label entry)))))))

(ert-deftest cmacs-clawtilla-sections-carry-their-pages ()
  "A section carries its pages, and there is no flat page family.

clawtilla ships `clawt_page_count' without a `_nth' beside it and says
why: a page is reached through its section, never chosen from a list of
eleven.  Asking for a page family must answer nothing rather than
inventing one."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((sections (cmacs-clawtilla-enum "section")))
    (should (> (length sections) 1))
    (dolist (section sections)
      (should (alist-get 'pages section))
      (should (stringp (alist-get 'default-page section)))))
  (should (null (cmacs-clawtilla-enum "page"))))

(ert-deftest cmacs-clawtilla-computer-views-are-four-in-order ()
  "Shell, Screen, Mounts and Exchange, in the library's order.

Pinned because both graphical clients draw them in that order and a
third that disagreed would be a tab in one window and not another, with
nothing saying so."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (should (equal (cmacs-clawtilla-enum-nicks "computer-view")
                 '("shell" "screen" "mounts" "exchange"))))


;;;; Rendering.

(ert-deftest cmacs-clawtilla-markdown-renders-through-the-library ()
  "Markdown becomes faces, and text that looks like markup survives.

The parse is the library's cmark, so all three clients agree about what
markdown means.  The markup is parsed with libxml rather than by
regexp, because agents emit arbitrary text and a regexp that is nearly
right about nesting mangles somebody's message about HTML."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((rendered (cmacs-clawtilla-render-markdown "a **bold** word")))
    (should (string-match-p "bold" rendered))
    (should-not (string-match-p "<b>" rendered))
    (should (seq-some (lambda (i)
                        (let ((face (get-text-property i 'face rendered)))
                          (or (eq face 'bold)
                              (and (listp face) (memq 'bold face)))))
                      (number-sequence 0 (1- (length rendered))))))
  ;; Entities decode rather than leaking their escaped form.
  (let ((rendered (cmacs-clawtilla-render-markdown "a <tag> & more")))
    (should (string-match-p "<tag>" rendered))
    (should-not (string-match-p "&lt;" rendered))
    (should-not (string-match-p "&amp;" rendered))))

(ert-deftest cmacs-clawtilla-time-labels-come-from-the-library ()
  "One stamp and one format, across every client."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((now (truncate (float-time))))
    (should (stringp (cmacs-clawtilla--time-label now)))
    (should (stringp (cmacs-clawtilla--time-label now t)))))


;;;; Redrawing.

(ert-deftest cmacs-clawtilla-redraw-keeps-its-place ()
  "A redraw restores point by section identity, not by offset.

A fleet buffer redraws on every event, and the line an agent sits on
moves when a team above it gains a member.  Restoring a character
offset would land somewhere else and read as the buffer jumping on its
own -- most often while the fleet is busy, which is when somebody is
actually looking at it."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (with-temp-buffer
    (let ((draw (lambda (extra)
                  (cmacs-clawtilla-ui-preserving
                    (when extra
                      (cmacs-clawtilla-insert-section
                       :type 'agent :value "newcomer" :heading "newcomer"))
                    (cmacs-clawtilla-insert-section
                     :type 'agent :value "scout" :heading "scout")
                    (cmacs-clawtilla-insert-section
                     :type 'agent :value "scribe" :heading "scribe")))))
      (funcall draw nil)
      (goto-char (point-min))
      (search-forward "scribe")
      (goto-char (match-beginning 0))
      (should (equal "scribe" (cmacs-clawtilla-value-at-point 'agent)))
      ;; A row appears above it; point must still be on scribe.
      (funcall draw t)
      (should (equal "scribe" (cmacs-clawtilla-value-at-point 'agent))))))


(ert-deftest cmacs-clawtilla-a-child-section-outranks-its-parent ()
  "Point inside a nested section reports the innermost one.

A parent is written after its body, so applying its text property over
the whole range overwrites every section nested inside it.  In the
fleet buffer that meant point on an agent reported the TEAM it was in:
RET said there was nothing to open while sitting on the thing to open,
and nothing anywhere said why.

Nothing about the buffer looked wrong -- the agent was drawn, the
badges were right, the fold worked -- which is why this is a test and
not a thing to remember."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (with-temp-buffer
    (cmacs-clawtilla-insert-section
     :type 'team :value "research" :foldable t :heading "Research"
     :body (lambda ()
             (cmacs-clawtilla-insert-section
              :type 'agent :value '((id . "scout")) :level 1
              :heading "  scout")))
    (goto-char (point-min))
    (should (equal 'team (plist-get (cmacs-clawtilla-section-at-point) :type)))
    (search-forward "scout")
    (goto-char (match-beginning 0))
    (let ((section (cmacs-clawtilla-section-at-point)))
      (should (eq 'agent (plist-get section :type)))
      (should (equal "scout" (alist-get 'id (plist-get section :value)))))))

(ert-deftest cmacs-clawtilla-buffers-take-over-the-window ()
  "A clawtilla buffer takes the window rather than splitting it.

These buffers are the thing you are doing, not a reference you glance
at: a transcript in half a window is one nobody reads."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (should (eq cmacs-clawtilla-display-buffer-function
              #'pop-to-buffer-same-window))
  (save-window-excursion
    (delete-other-windows)
    (let ((before (length (window-list))))
      (cmacs-clawtilla-display (get-buffer-create "*clawtilla display test*"))
      (should (= before (length (window-list))))
      (should (equal "*clawtilla display test*" (buffer-name)))))
  (kill-buffer "*clawtilla display test*"))

(ert-deftest cmacs-clawtilla-saved-profiles-read-the-shared-file ()
  "Saved profiles come from clawtilla's file, not this session's links.

`cmacs-clawtilla--saved-connections' reads the connections file every
clawtilla client shares.  `cmacs-clawtilla--connections' is the list of
links THIS process has open.  The names are one word apart, and calling
the wrong one fails in the worst possible way: it answers an empty
list, which is exactly what somebody with no saved profiles would see.
It read as cmacs being unable to see machines the GTK client offers.

Asserted on the primitives rather than on the file's contents, because
a machine with no profiles saved must still pass -- what is being
pinned is which question gets asked."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  ;; The two answer different questions, and the saved one is a file.
  (should (stringp (cmacs-clawtilla--connections-path)))
  (let ((saved (cmacs-clawtilla--saved-connections))
        (open (cmacs-clawtilla--connections)))
    ;; Nothing is connected in a batch run, so the open list is empty
    ;; and any saved profile would be visible only through the other.
    (should (equal "[]" open))
    (when (and saved (not (equal saved "[]")))
      (should (cmacs-clawtilla-saved-profiles))
      (should (= (length (cmacs-clawtilla-saved-profiles))
                 (length (cmacs-clawtilla--parse saved))))
      (dolist (profile (cmacs-clawtilla-saved-profiles))
        (should (stringp (alist-get 'name profile)))
        ;; The description is the library's, and it is what hides the
        ;; token.  A profile that carried one into Lisp would be one
        ;; keystroke from a buffer.
        (should (stringp (alist-get 'describe profile)))
        (should-not (alist-get 'token profile))))))

(defconst cmacs-clawtilla-tests--modes
  '((cmacs-clawtilla-fleet-mode     . cmacs-clawtilla-fleet)
    (cmacs-clawtilla-agent-mode     . cmacs-clawtilla-agent)
    (cmacs-clawtilla-chat-mode      . cmacs-clawtilla-chat)
    (cmacs-clawtilla-computer-mode  . cmacs-clawtilla-computer)
    (cmacs-clawtilla-section-mode   . cmacs-clawtilla-section)
    (cmacs-clawtilla-settings-mode  . cmacs-clawtilla-settings)
    (cmacs-clawtilla-alerts-mode    . cmacs-clawtilla-alerts)
    (cmacs-clawtilla-teach-mode     . cmacs-clawtilla-teach))
  "Every clawtilla major mode, and the feature that defines it.")

(ert-deftest cmacs-clawtilla-modes-own-their-shared-keys ()
  "Each mode map binds the shared keys itself rather than inheriting them.

This is what makes them work under Doom, and it is not obvious.
`cmacs-evil-setup-mode-map' promotes a map's OWN bindings and skips
inherited ones on purpose -- promoting what a `special-mode' keymap
inherits would put SPC, the Doom leader, above Evil.  So a shared
parent map means those keys are never promoted: under Evil `g', `n' and
TAB stay Evil's while the rest of the mode responds, which is a buffer
half of whose keys work and no error anywhere."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (dolist (entry cmacs-clawtilla-tests--modes)
    (require (cdr entry) nil t)
    (let ((map (symbol-value (intern (format "%s-map" (car entry))))))
      (dolist (key '("TAB" "n" "p" "g" "q"))
        ;; Looked up with the parent detached: inheriting it is exactly
        ;; the failure being ruled out, so a plain lookup would pass.
        (let ((own (copy-keymap map)))
          (set-keymap-parent own nil)
          (should (lookup-key own (kbd key))))))))

(ert-deftest cmacs-clawtilla-every-mode-registers-with-evil ()
  "Every clawtilla mode calls `cmacs-clawtilla-setup-evil'.

Checked in the source rather than by behaviour because Evil is not
loaded in a batch test run, and the failure being prevented is an
absent call: a mode that forgets it looks perfect in `emacs -Q' and is
inert under Doom, which is how this shipped the first time."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((dir (file-name-directory (locate-library "cmacs-clawtilla")))
        (missing nil))
    (dolist (entry cmacs-clawtilla-tests--modes)
      (let* ((feature (symbol-name (cdr entry)))
             (file (expand-file-name (concat feature ".el") dir)))
        (when (file-exists-p file)
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (unless (search-forward
                     (format "(cmacs-clawtilla-setup-evil %s-map" (car entry))
                     nil t)
              (push (car entry) missing))))))
    (should (null missing))))

(ert-deftest cmacs-clawtilla-event-timestamps-are-microseconds ()
  "An event's stamp is in microseconds and is converted to seconds.

Everything that reads one -- the alert tier, the unread rule, every
label -- works in seconds, and feeding it microseconds does not fail.
It produces a date about fifty thousand years from now, which reads as
newer than everything and is wrong in no way anybody notices."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((event (cmacs-clawtilla--parse
                "{\"ts\":1789071308517850,\"subject\":\"dm:a:user\"}")))
    (should (= 1789071308 (cmacs-clawtilla-event-seconds event)))
    ;; A stamp already in seconds is left alone, so history loaded from
    ;; a different source is not divided twice.
    (should (= 1789071308
               (cmacs-clawtilla-event-seconds
                (cmacs-clawtilla--parse "{\"ts\":1789071308}"))))))

(ert-deftest cmacs-clawtilla-events-name-their-subject-and-detail ()
  "An event's room is `subject' and its payload is inside `detail'.

Not `room' and `sender', which is what the unread path read: both are
absent, so it found nothing and counted nothing -- silently, because a
count that stays at zero is what a quiet fleet looks like."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((event (cmacs-clawtilla--parse
                "{\"kind\":\"message\",\"subject\":\"dm:scout:user\",\
\"detail\":{\"from\":\"scout\",\"body\":\"hi\"}}")))
    (should (equal "dm:scout:user" (cmacs-clawtilla-event-subject event)))
    (should (equal "scout" (cmacs-clawtilla-event-detail event 'from)))
    (should (null (cmacs-clawtilla-get event 'room)))
    (should (null (cmacs-clawtilla-get event 'sender)))))

(ert-deftest cmacs-clawtilla-unread-rises-only-for-somebody-else ()
  "An agent's message raises a count; yours and the open room do not."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla-alerts--on-event)))
  (let* ((conn (cmacs-clawtilla--connection-create
                :handle 0 :name "t" :state 'connected :connected-at 1000))
         (cmacs-clawtilla-known-rooms-function (lambda () '("dm:scout:user")))
         (cmacs-clawtilla--viewing-room nil)
         (cmacs-clawtilla-unread (make-hash-table :test 'equal))
         (from-agent "{\"kind\":\"message\",\"subject\":\"dm:scout:user\",\
\"ts\":2000000000,\"detail\":{\"from\":\"scout\"}}")
         (from-you "{\"kind\":\"message\",\"subject\":\"dm:scout:user\",\
\"ts\":2000000000,\"detail\":{\"from\":\"user\"}}"))
    (cmacs-clawtilla-alerts--on-event conn "message"
                                      (cmacs-clawtilla--parse from-agent))
    (should (= 1 (cmacs-clawtilla-unread-count "dm:scout:user")))
    ;; Looking at it means reading it.
    (setq cmacs-clawtilla--viewing-room "dm:scout:user")
    (cmacs-clawtilla-alerts--on-event conn "message"
                                      (cmacs-clawtilla--parse from-agent))
    (should (= 1 (cmacs-clawtilla-unread-count "dm:scout:user")))
    ;; And your own message never counts.
    (setq cmacs-clawtilla--viewing-room nil)
    (cmacs-clawtilla-alerts--on-event conn "message"
                                      (cmacs-clawtilla--parse from-you))
    (should (= 1 (cmacs-clawtilla-unread-count "dm:scout:user")))))

(ert-deftest cmacs-clawtilla-steps-never-travel-re-encoded ()
  "A step goes back to C as the JSON that arrived, never re-encoded.

`json-parse-string' maps JSON false to nil and `json-serialize' writes
nil back as an empty object, so a step that has been through Lisp has
its `failed: false' turned into `{}'.  The library reads that member
with `json_object_get_boolean_member' behind a `has_member' check that
an object passes -- one GLib CRITICAL per step, per redraw, which is
why this arrived as a screenful of them on every tool call.

Asserted by splitting the RAW text and checking the result is sane:
under G_DEBUG=fatal-criticals a regression aborts, and without it the
counts still come out right, so this also pins the summary."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let* ((raw "[{\"step_kind\":\"tool\",\"tool\":\"read\",\"text\":\"a\",\
\"failed\":false,\"ts\":100000000},\
{\"step_kind\":\"tool\",\"tool\":\"edit\",\"text\":\"b\",\
\"failed\":false,\"ts\":900000000}]")
         ;; A message at 500 seconds overtakes the first step only: the
         ;; library divides a step stamp by a million before comparing,
         ;; because steps are microseconds and messages are seconds.
         (split (cmacs-clawtilla--parse
                 (cmacs-clawtilla--steps raw "scout" 500))))
    (should (= 1 (length (alist-get 'history split))))
    (should (= 1 (length (alist-get 'live split))))
    (should (equal "read" (alist-get 'tool (car (alist-get 'history split)))))
    (should (equal "edit" (alist-get 'tool (car (alist-get 'live split)))))
    ;; `failed' survives as a boolean rather than becoming an object.
    (should (memq (alist-get 'failed (car (alist-get 'history split)))
                  '(nil :false)))
    ;; And the summary is built in C, so nothing had to be re-encoded.
    (should (stringp (alist-get 'summary split)))
    (should-not (string-empty-p (alist-get 'summary split)))))

(defun cmacs-clawtilla-tests--steps-json (&rest stamps)
  "Return a raw steps array stamped at STAMPS microseconds."
  (json-serialize
   (vconcat (mapcar (lambda (ts)
                      `((step_kind . "tool") (tool . "read")
                        (text . "f") (failed . :false) (ts . ,ts)))
                    stamps))))

(ert-deftest cmacs-clawtilla-tool-calls-come-before-the-answer ()
  "A turn's tool calls sit above the message they produced.

They happened first.  Appending them after the message -- which is what
this did -- puts a turn's work below the answer it produced, so the
transcript reads backwards: you scroll past the reply to find out how
it was reached."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla-chat-mode)))
  (with-temp-buffer
    (cmacs-clawtilla-chat-mode)
    (setq-local cmacs-clawtilla-chat--agent "scout")
    (setq-local cmacs-clawtilla-chat--steps-json
                (cmacs-clawtilla-tests--steps-json 100000000 110000000))
    (cmacs-clawtilla-chat--append-messages
     (cmacs-clawtilla--parse
      "[{\"id\":\"m1\",\"sender\":\"user\",\"body\":\"ask\",\"ts\":90},
        {\"id\":\"m2\",\"sender\":\"scout\",\"body\":\"answer\",\"ts\":500}]"))
    (let ((text (buffer-string)))
      (should (string-match-p "read" text))
      ;; The run is between the question and the answer, not after it.
      (should (< (string-match "ask" text) (string-match "read" text)))
      (should (< (string-match "read" text) (string-match "answer" text))))))

(ert-deftest cmacs-clawtilla-tool-runs-fold ()
  "A run of tool calls starts collapsed and TAB opens it.

Collapsed because a turn can be twenty calls long and what somebody
reads is the answer.  Folded with an overlay rather than by redrawing:
this transcript appends and is never rebuilt, so there is nothing to
re-render a fold into."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla-chat-toggle-step-run)))
  (with-temp-buffer
    (cmacs-clawtilla-chat-mode)
    (setq-local cmacs-clawtilla-chat--agent "scout")
    (setq-local cmacs-clawtilla-chat--steps-json
                (cmacs-clawtilla-tests--steps-json 100000000 110000000))
    (cmacs-clawtilla-chat--append-messages
     (cmacs-clawtilla--parse
      "[{\"id\":\"m2\",\"sender\":\"scout\",\"body\":\"answer\",\"ts\":500}]"))
    (let ((body (seq-find (lambda (o)
                            (overlay-get o 'cmacs-clawtilla-step-body))
                          (overlays-in (point-min) (point-max)))))
      (should body)
      (should (overlay-get body 'invisible))
      ;; The heading is what carries the toggle, and it is visible.
      (goto-char (point-min))
      (should (re-search-forward "\u25b8" nil t))
      (goto-char (match-beginning 0))
      (cmacs-clawtilla-chat-toggle-step-run)
      (should-not (overlay-get body 'invisible))
      ;; And the marker follows the state, so the buffer does not lie.
      (goto-char (point-min))
      (should (re-search-forward "\u25be" nil t)))))

(ert-deftest cmacs-clawtilla-composing-is-a-buffer ()
  "A message is written in a buffer, with C-c C-c and C-c C-k.

The minibuffer can hold a paragraph and is a bad place to write one:
no newline without a prefix, no wrapping, and nothing you can leave and
come back to."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla-chat-compose)))
  (let (compose)
    (unwind-protect
        (with-temp-buffer
          (cmacs-clawtilla-chat-mode)
          (setq-local cmacs-clawtilla-chat--agent "scout")
          (setq compose (cmacs-clawtilla-chat-compose "one\ntwo"))
          (with-current-buffer compose
            (should (derived-mode-p 'cmacs-clawtilla-chat-compose-mode))
            (should (eq (key-binding (kbd "C-c C-c"))
                        'cmacs-clawtilla-chat-compose-send))
            (should (eq (key-binding (kbd "C-c C-k"))
                        'cmacs-clawtilla-chat-compose-cancel))
            ;; Multiple lines survive, which is the point of it.
            (should (equal "one\ntwo" (buffer-string)))))
      (when (buffer-live-p compose) (kill-buffer compose)))))

;;;; Source guards.

(ert-deftest cmacs-clawtilla-answers-every-gtk-slash-command ()
  "The twenty slash commands the GTK client answers are answered here.

Checked as a list rather than by behaviour because the failure being
prevented is a missing entry, not a broken one: a command nobody
implemented is invisible until somebody types it."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (boundp 'cmacs-clawtilla-chat-slash-commands)))
  (dolist (command '("/agents" "/attach" "/clear" "/compose" "/copy" "/edit"
                     "/export" "/files" "/flow" "/help" "/interrupt"
                     "/memory" "/new" "/recall" "/reset" "/restart" "/retry"
                     "/start" "/stop" "/tasks"))
    (should (assoc command cmacs-clawtilla-chat-slash-commands)))
  (should (= 20 (length cmacs-clawtilla-chat-slash-commands))))

(ert-deftest cmacs-clawtilla-holds-no-copy-of-an-enumeration ()
  "No value the library enumerates is spelled out in the elisp.

Having a copy of the list is what makes a client able to disagree with
it.  This is the same rule clawtilla's `make parity' enforces, checked
here too so it fails in the suite a developer already runs."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((sources (directory-files
                  (file-name-directory (locate-library "cmacs-clawtilla"))
                  t "\\`cmacs-clawtilla.*\\.el\\'"))
        (offenders nil))
    (dolist (family '("appearance-theme" "appearance-scheme"))
      (dolist (nick (cmacs-clawtilla-enum-nicks family))
        ;; Short nicks are excluded: a two-letter value is evidence of
        ;; nothing, and a check that reports a hardcoding which is not
        ;; there is one people learn to ignore.
        (when (> (length nick) 4)
          (dolist (file sources)
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (when (search-forward (format "\"%s\"" nick) nil t)
                (push (cons nick (file-name-nondirectory file))
                      offenders)))))))
    (should (null offenders))))

(provide 'cmacs-clawtilla-tests)

;;; cmacs-clawtilla-tests.el ends here
