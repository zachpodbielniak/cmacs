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
(require 'cl-lib)
(require 'subr-x)

(defun cmacs-clawtilla-tests--available-p ()
  "Non-nil when this build compiled in the clawtilla client."
  (and (boundp 'is-cmacs-clawtilla) is-cmacs-clawtilla
       (fboundp 'cmacs-clawtilla-supported-p)))

(declare-function cmacs-clawtilla-section--activity-turns
                  "cmacs-clawtilla-section")

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

(ert-deftest cmacs-clawtilla-computer-views-are-five-in-order ()
  "Shell, Screen, Mounts, Exchange and Browser, in the library's order.

Pinned because both graphical clients draw them in that order and a
third that disagreed would be a tab in one window and not another, with
nothing saying so.  Browser arrived with clawtilla 0.9.0, and the
computer buffer draws it rather than falling through to the shell."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (should (equal (cmacs-clawtilla-enum-nicks "computer-view")
                 '("shell" "screen" "mounts" "exchange" "browser"))))


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
parent map means those keys are never promoted: under Evil TAB and the
section motions stay Evil's while the rest of the mode responds, which
is a buffer half of whose keys work and no error anywhere.

`g j' rather than a bare `g': see
`cmacs-clawtilla-tests--motion-keys' for why the prefix stays Evil's."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (dolist (entry cmacs-clawtilla-tests--modes)
    (require (cdr entry) nil t)
    (let ((map (symbol-value (intern (format "%s-map" (car entry))))))
      (dolist (key '("TAB" "C-j" "C-k" "g j" "g k" "g r" "q"))
        ;; Looked up with the parent detached: inheriting it is exactly
        ;; the failure being ruled out, so a plain lookup would pass.
        (let ((own (copy-keymap map)))
          (set-keymap-parent own nil)
          (should (lookup-key own (kbd key))))))))

(defconst cmacs-clawtilla-tests--motion-keys
  '("j" "k" "h" "l" "w" "b" "e" "W" "B" "E"
    "0" "$" "^" "G" "H" "M" "L" "{" "}" "(" ")" "%" "/"
    "n" "N" "f" "F" "t" "T" ";" "g"
    "C-u" "C-d" "C-f" "C-b" "C-e" "C-y" "C-o")
  "The keys an Evil user navigates with.

Not a list of every key Evil binds.  A clawtilla buffer is read-only,
so taking `d', `c', `x' or `i' costs nothing -- there is nothing to
delete, change or insert.  `evil-collection' says so itself: its
read-only setup remaps `i', `a', `o', `p', `d', `c', `x' and friends
to `ignore' in exactly these buffers.  Taking a MOTION costs the
buffer: `k' is how you move up, and a `k' that interrupts a turn
instead means somebody pressing it to scroll gets an error, or worse,
stops an agent.

`g' is in the list as a whole prefix.  A bare `g' takes `gg', `ge' and
every other `g' motion at once, so the rule is that `g' may be a prefix
keymap but never a command -- `gj'/`gk'/`gr' are fine and are what
`evil-collection-magit' uses.  `n' is here because it is
`evil-search-next': `evil-collection-magit' moves Magit's own `n'/`p'
off it for this reason, so a Doom user already expects section motion
on `C-j'/`C-k'.")

(defconst cmacs-clawtilla-tests--doom-leader-keys
  '("SPC" "," "M-SPC")
  "Doom's leader, localleader and alternate leader.

Taking one of these in an intercept map does not merely shadow a
motion, it removes the user's entire command tree inside the buffer.")

(ert-deftest cmacs-clawtilla-no-mode-steals-a-motion-key ()
  "No clawtilla buffer binds a key an Evil user needs to navigate.

These maps are Evil INTERCEPT maps, so whatever they bind wins
outright -- which is what makes them work under Doom and also what
makes this rule necessary.  Stealing an editing key in a read-only
buffer is free; stealing `k' is not.

Checked as a rule rather than remembered, because the list of commands
grows and each new one picks a letter."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((offenders nil))
    (dolist (entry cmacs-clawtilla-tests--modes)
      (require (cdr entry) nil t)
      (let* ((name (intern (format "%s-map" (car entry))))
             (map (and (boundp name) (symbol-value name))))
        (when map
          ;; The parent is detached: an inherited binding is not
          ;; promoted into the intercept map, so it does not shadow
          ;; Evil and is not this rule's business.
          (let ((own (copy-keymap map)))
            (set-keymap-parent own nil)
            (dolist (key (append cmacs-clawtilla-tests--motion-keys
                                 cmacs-clawtilla-tests--doom-leader-keys))
              ;; `commandp', not non-nil: `g' is deliberately a prefix
              ;; keymap holding `gj'/`gk'/`gr', and a prefix shadows
              ;; only the sequences it actually completes.
              (let ((def (lookup-key own (kbd key))))
                (when (commandp def)
                  (push (format "%s binds %s to %s" (car entry) key def)
                        offenders))))))))
    (should (null offenders))))

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

(ert-deftest cmacs-clawtilla-unfiled-agents-come-first ()
  "Agents in no team are drawn above the teams, and the option flips it.

They are the rows with no lead to answer for them, and they used to sit
after every team -- which on a fleet of any size is below the fold.
Checked by rendering, not by reading the option: the ordering lives in
the draw function, so an option nothing consults would pass a test that
only asked what the option was set to."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-fleet nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-fleet--draw))
  (cl-flet
      ((order
         (first)
         (with-temp-buffer
           (cmacs-clawtilla-fleet-mode)
           (setq-local cmacs-clawtilla-fleet-no-team-first first)
           (setq-local cmacs-clawtilla-connection
                       (cmacs-clawtilla--connection-create
                        :name "test" :state 'connected))
           (setq-local cmacs-clawtilla-fleet--teams
                       '(((id . "forge") (name . "forge"))))
           (setq-local cmacs-clawtilla-fleet--agents
                       '(((id . "ox") (name . "ox") (team . "forge")
                          (state . "running"))
                         ((id . "jackal") (name . "jackal")
                          (state . "running"))))
           (let ((inhibit-read-only t))
             (cmacs-clawtilla-fleet--draw))
           (let ((text (buffer-string)))
             (cons (string-match "No team" text)
                   (string-match "forge" text))))))
    (let ((on (order t))
          (off (order nil)))
      ;; Both groups must actually be on screen either way, or "first"
      ;; would be satisfied by having dropped the other one.
      (should (car on)) (should (cdr on))
      (should (car off)) (should (cdr off))
      (should (< (car on) (cdr on)))
      (should (> (car off) (cdr off)))))
  ;; And the DEFAULT is unfiled-first, which is the part that was
  ;; actually asked for.  Read from `standard-value' rather than the
  ;; variable, so a developer who has customised it does not silently
  ;; pass a test about what ships.
  (should (eval (car (get 'cmacs-clawtilla-fleet-no-team-first
                          'standard-value))
                t)))

;;;; Activity, Fleet, Browser, accounts and policy (clawtilla 0.2-0.9).

(ert-deftest cmacs-clawtilla-gtype-enum-families-are-walked ()
  "Browser modes, policy modes and action classes come off their GTypes.

libclawt registers these three only as GTypes, with no label table, so
the label is the nick made readable -- and the daemon validates
`agent.set' against the same GType, so what is offered is what saving
accepts."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--enum)
                    (cmacs-clawtilla-enum "browser-mode")))
  (dolist (family '("browser-mode" "policy-mode" "action-class"
                    "usage-period" "decision-state"))
    (let ((entries (cmacs-clawtilla-enum family)))
      (should entries)
      (dolist (entry entries)
        (should (stringp (alist-get 'nick entry)))
        (should (stringp (alist-get 'label entry)))
        ;; Humanised: no separator survives, and it starts upper-case.
        (should-not (string-match-p "[_-]" (alist-get 'label entry)))
        (should (let ((case-fold-search nil))
                  (string-match-p "\\`[[:upper:][:digit:]]"
                                  (alist-get 'label entry)))))))
  ;; A policy mode with an underscore keeps it in the nick -- that is
  ;; what `policy.rules' must spell -- and only the label loses it.
  (should (seq-some (lambda (nick) (string-match-p "_" nick))
                    (cmacs-clawtilla-enum-nicks "policy-mode")))
  ;; Exactly one period is the library's default.
  (should (= 1 (length (seq-filter (lambda (p) (eq t (alist-get 'default p)))
                                   (cmacs-clawtilla-enum "usage-period")))))
  ;; Decision states carry the integer `decision.list' sends.
  (dolist (entry (cmacs-clawtilla-enum "decision-state"))
    (should (integerp (alist-get 'value entry)))))

(ert-deftest cmacs-clawtilla-grok-job-states-are-the-librarys ()
  "Grok job states come from libclawt: nick, label, tone and attention."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (let ((states (cmacs-clawtilla-enum "grok-job-state")))
    (should (>= (length states) 8))
    (dolist (s states)
      (should (stringp (alist-get 'nick s)))
      (should (stringp (alist-get 'label s)))
      (should (member (alist-get 'tone s) '("good" "bad" "warn" "info" "neutral")))
      (should (memq (alist-get 'attention s) '(t nil))))
    ;; The badge count is the library's rule: a failed job needs somebody,
    ;; a finished one does not.
    (should (eq t (alist-get 'attention
                             (seq-find (lambda (s) (equal (alist-get 'nick s) "failed"))
                                       states))))
    (should-not (alist-get 'attention
                           (seq-find (lambda (s) (equal (alist-get 'nick s) "done"))
                                     states)))))

(ert-deftest cmacs-clawtilla-grok-page-draws ()
  "The Grok page draws reachability, bots, jobs and the bot's own text."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (require 'cmacs-clawtilla-section nil t)))
  (with-temp-buffer
    (cmacs-clawtilla-section-mode)
    (setq-local cmacs-clawtilla-section--page "grok")
    (setq-local cmacs-clawtilla-section--reply
                `((bots . ((reachable . nil)
                           (unreachable_reason . "tailscale is not up")
                           (bots . (((name . "scout") (description . "x")
                                     (agents . ("ada" "bob"))
                                     (key_configured . t) (mcp_key . nil))))))
                  (jobs . ((attention . 1)
                           (jobs . (((id . "gj-1") (bot . "scout") (agent . "ada")
                                     (state . "failed") (instructions . "find it")
                                     (created_at . 0)
                                     (note . "<b>could not</b>"))))))))
    (let ((inhibit-read-only t))
      (cmacs-clawtilla-grok-draw))
    (let ((text (buffer-string)))
      (should (string-match-p "No job can be sent right now: tailscale is not up" text))
      (should (string-match-p "scout" text))
      (should (string-match-p "reachable by ada, bob" text))
      (should (string-match-p "HTTP only" text))
      (should (string-match-p "1 need you" text))
      (should (string-match-p "gj-1 for ada" text))
      ;; The bot's text is drawn as text.
      (should (string-match-p "<b>could not</b>" text)))))

(ert-deftest cmacs-clawtilla-trigger-update-types-values ()
  "trigger.update sends integers and booleans as JSON, not strings."
  (skip-unless (require 'cmacs-clawtilla-section nil t))
  (let (sent)
    (cl-letf (((symbol-function 'cmacs-clawtilla-section--row-id) (lambda () "t1"))
              ((symbol-function 'cmacs-clawtilla-section--send)
               (lambda (_kind payload) (setq sent payload))))
      (cl-letf (((symbol-function 'read-string)
                 (let ((answers (list "organization_id" "42")))
                   (lambda (&rest _) (pop answers)))))
        (cmacs-clawtilla-section-trigger-update))
      (should (equal (alist-get 'organization_id sent) 42))
      (cl-letf (((symbol-function 'read-string)
                 (let ((answers (list "ignore_actors" "bot1,bot2")))
                   (lambda (&rest _) (pop answers)))))
        (cmacs-clawtilla-section-trigger-update))
      (should (equal (alist-get 'ignore_actors sent) "bot1,bot2"))
      (cl-letf (((symbol-function 'read-string)
                 (let ((answers (list "enabled" "false")))
                   (lambda (&rest _) (pop answers)))))
        (cmacs-clawtilla-section-trigger-update))
      (should (eq (alist-get 'enabled sent) :false)))))

(ert-deftest cmacs-clawtilla-sparkline-is-the-librarys ()
  "One character per day, a gap for a day that cost nothing."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--sparkline)))
  (let ((strip (cmacs-clawtilla--sparkline '(0 10 20 0 40))))
    (should (= 5 (length strip)))
    ;; An idle day is drawn unlike the smallest spend.
    (should-not (eq (aref strip 0) (aref strip 1)))
    (should (eq (aref strip 0) (aref strip 3)))
    ;; The largest is the tallest, so it differs from a smaller one.
    (should-not (eq (aref strip 4) (aref strip 1))))
  (should (equal "" (cmacs-clawtilla--sparkline nil))))

(ert-deftest cmacs-clawtilla-activity-words-are-the-librarys ()
  "A turn's age and the Stop question are libclawt's sentences."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--activity-elapsed)))
  (let* ((now 1800000000000000)
         (short (cmacs-clawtilla--activity-elapsed (- now 45000000) now))
         (long (cmacs-clawtilla--activity-elapsed (- now 3900000000) now))
         (future (cmacs-clawtilla--activity-elapsed (+ now 5000000) now)))
    (should (stringp short))
    (should-not (equal short long))
    ;; A turn stamped in the future by a skewed clock is not negative.
    (should-not (string-match-p "-" future)))
  (let ((prompt (cmacs-clawtilla--activity-stop-prompt "scout" 3)))
    (should (stringp prompt))
    (should (string-match-p "scout" prompt))))

(defconst cmacs-clawtilla-tests--usage-reply
  (concat "{\"since\":0,\"now\":1800000000,"
          "\"daily_fleet_budget_micros\":5000000,"
          "\"days\":[" (mapconcat (lambda (n) (format "{\"start\":%d,\"cost_micros\":%d}"
                                                      n (* n 1000)))
                                  (number-sequence 1 14) ",")
          "],"
          "\"total\":{\"turns\":3,\"cost_micros\":3000000},"
          "\"agents\":[{\"id\":\"scout\",\"name\":\"Scout\",\"turns\":2,"
          "\"cost_micros\":2000000,\"last_turn_at\":1799990000,"
          "\"idle\":\"idle\",\"idle_tone\":\"warn\",\"state\":\"running\","
          "\"asleep\":false,\"idle_stop_hours\":0,\"daily\":["
          (mapconcat #'number-to-string
                     '(0 0 0 0 0 0 0 0 0 0 0 0 1000000 1000000) ",")
          "]},{\"id\":\"ox\",\"name\":\"Ox\",\"turns\":1,"
          "\"cost_micros\":1000000,\"last_turn_at\":0,\"idle\":\"never used\","
          "\"idle_tone\":\"neutral\",\"state\":\"stopped\",\"asleep\":false,"
          "\"daily\":[]}]}")
  "A `usage.summary' reply in the 0.8.0 shape, as the daemon sends it.")

(ert-deftest cmacs-clawtilla-fleet-view-answers-the-page ()
  "The Fleet page's figures and wording all come out of one library call."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--fleet-view)))
  (let* ((view (cmacs-clawtilla--parse
                (cmacs-clawtilla--fleet-view cmacs-clawtilla-tests--usage-reply)))
         (agents (alist-get 'agents view)))
    (should (stringp (alist-get 'summary view)))
    (should (stringp (alist-get 'strip view)))
    (should (= 2 (length agents)))
    (should (equal "scout" (alist-get 'id (car agents))))
    ;; A per-agent strip is one cell per daily figure.
    (should (= 14 (length (alist-get 'strip (car agents)))))
    (should (equal "" (alist-get 'strip (cadr agents))))
    (should (stringp (alist-get 'cost (car agents))))
    (should (stringp (alist-get 'share (car agents)))))
  ;; The model the page draws zips the daemon's rows with the view's.
  (require 'cmacs-clawtilla-section nil t)
  (when (fboundp 'cmacs-clawtilla-section--fleet-merge)
    (let* ((model (cmacs-clawtilla-section--fleet-merge
                   cmacs-clawtilla-tests--usage-reply))
           (first (car (alist-get 'agents model))))
      (should (equal "Scout" (alist-get 'name first)))
      (should (equal "scout" (alist-get 'id (alist-get 'view first)))))))

(ert-deftest cmacs-clawtilla-fleet-payload-is-the-librarys ()
  "The Fleet request is built by libclawt: days, and sorted by cost."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--fleet-payload)))
  (let ((payload (cmacs-clawtilla--parse (cmacs-clawtilla--fleet-payload nil 14))))
    (should (equal 14 (alist-get 'days payload)))
    (should (equal "cost" (alist-get 'sort payload)))
    (should (integerp (alist-get 'since payload))))
  (should (stringp (cmacs-clawtilla--format-cost 1500000))))

(ert-deftest cmacs-clawtilla-browser-line-has-a-sentence-for-nothing ()
  "No session is a sentence of its own, not an empty line."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--browser-line)))
  (should (> (length (cmacs-clawtilla--browser-line nil)) 0))
  (should (> (length (cmacs-clawtilla--browser-line
                      "{\"key\":\"agent:a\",\"running\":false}"))
             0)))

(ert-deftest cmacs-clawtilla-browser-click-maps-to-page-pixels ()
  "A click on the scaled picture lands on the page's own CSS pixel."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-computer nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-computer--map-click))
  ;; Drawn at half size: double back up.
  (should (equal '(200 100) (let ((p (cmacs-clawtilla-computer--map-click
                                      100 50 '(640 . 400) '(1280 . 800))))
                              (list (car p) (cdr p)))))
  ;; Unscaled is the identity.
  (should (equal '(7 . 9) (cmacs-clawtilla-computer--map-click
                           7 9 '(100 . 100) '(100 . 100))))
  ;; The edge is clamped inside the page.
  (should (equal '(99 . 99) (cmacs-clawtilla-computer--map-click
                             500 500 '(100 . 100) '(100 . 100))))
  (should-not (cmacs-clawtilla-computer--map-click 1 1 nil '(10 . 10)))
  ;; The page's size is read from the PNG's own header.
  (let ((png (concat "\x89PNG\r\n\x1a\n" "\0\0\0\rIHDR"
                     (unibyte-string 0 0 5 0 0 0 3 32)
                     (make-string 8 0))))
    (should (equal '(1280 . 800) (cmacs-clawtilla-computer--png-size png))))
  (should-not (cmacs-clawtilla-computer--png-size "not a picture")))

(ert-deftest cmacs-clawtilla-routine-flags-are-json-booleans ()
  "Routine flags travel as true and false, never as nil or a string.

nil serializes as an empty object; a string that is not a boolean reads
as the default.  Either way the request succeeds and does the other
thing."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-section nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-section--routine-payload))
  (let* ((payload (cmacs-clawtilla-section--routine-payload
                   "nightly" '(("model" . "haiku") ("read_only" . t)
                               ("proactive" . nil) ("locked" . :false))))
         (json (cmacs-clawtilla--encode payload)))
    (should (equal "nightly" (alist-get 'id payload)))
    (should (equal "haiku" (alist-get 'model payload)))
    (should (eq t (alist-get 'read_only payload)))
    (should (eq :false (alist-get 'proactive payload)))
    (should (eq :false (alist-get 'locked payload)))
    (should (string-match-p "\"proactive\":false" json))
    (should-not (string-match-p "{}" json))))

(ert-deftest cmacs-clawtilla-decisions-are-named-by-decision ()
  "Answer, dismiss and delete name the decision as `decision', not `id'.

The daemon reads `decision' (daemon-misc.c); with `id' every answer was
refused and none ever reached the agent that asked."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-section nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-section-delete-decision))
  (let ((sent nil))
    (cl-letf (((symbol-function 'cmacs-clawtilla-section--send)
               (lambda (kind payload) (push (cons kind payload) sent)))
              ((symbol-function 'cmacs-clawtilla-section--row-id)
               (lambda () "d-1"))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (with-temp-buffer
        (setq-local cmacs-clawtilla-section--page "decisions")
        (cmacs-clawtilla-section-answer "approve")
        (cmacs-clawtilla-section-dismiss)
        (cmacs-clawtilla-section-delete-decision)))
    (should (= 3 (length sent)))
    (dolist (entry sent)
      (should (equal "d-1" (alist-get 'decision (cdr entry))))
      (should-not (assq 'id (cdr entry))))
    (should (assoc "decision.delete" sent))))

(ert-deftest cmacs-clawtilla-agent-set-sends-key-and-value ()
  "`agent.set' takes KEY and VALUE as strings, booleans spelled out."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-agent nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-agent--set-payload))
  (should (equal '((agent . "scout") (key . "runtime.autostart")
                   (value . "true"))
                 (cmacs-clawtilla-agent--set-payload
                  "scout" (cmacs-clawtilla-agent--setting-key 'autostart) "yes")))
  (should (equal "false" (alist-get 'value (cmacs-clawtilla-agent--set-payload
                                            "a" "enabled" :false))))
  (should (equal "model.model" (cmacs-clawtilla-agent--setting-key 'model)))
  ;; A field drawn from `settings' is already its own key.
  (should (equal "model.account"
                 (cmacs-clawtilla-agent--setting-key 'model.account)))
  (should (equal "" (alist-get 'value (cmacs-clawtilla-agent--set-payload
                                       "a" "computer.use" nil)))))

(ert-deftest cmacs-clawtilla-policy-rules-keep-their-order ()
  "Changing a rule replaces it where it stands; the first match decides."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-agent nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-agent--policy-put))
  (let ((rules (cmacs-clawtilla-agent--policy-split
                "exec=review, write=allow,, external=ask ")))
    (should (equal '("exec=review" "write=allow" "external=ask") rules))
    (should (equal '("exec=deny" "write=allow" "external=ask")
                   (cmacs-clawtilla-agent--policy-put rules "exec" "deny")))
    (should (equal '("exec=review" "write=allow" "external=ask" "Bash=ask")
                   (cmacs-clawtilla-agent--policy-put rules "Bash" "ask")))
    (should (equal "exec=review, write=allow, external=ask"
                   (cmacs-clawtilla-agent--policy-join rules))))
  (should (null (cmacs-clawtilla-agent--policy-split ""))))

(ert-deftest cmacs-clawtilla-account-picker-shows-why-not ()
  "Unusable accounts are shown with the daemon's reason, and marked."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-agent nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-agent--account-choices))
  (let ((choices (cmacs-clawtilla-agent--account-choices
                  '(((id . "work") (usable . t) (description . "the job"))
                    ((id . "home") (usable) (reason . "codex cannot take it"))))))
    (should (= 3 (length choices)))
    ;; The CLI's own login comes first and names no account.
    (should (null (nth 1 (car choices))))
    (should (equal "work" (nth 1 (nth 1 choices))))
    (should (null (nth 2 (nth 1 choices))))
    (should (equal "codex cannot take it" (nth 2 (nth 2 choices))))
    (should (string-match-p "codex cannot take it" (car (nth 2 choices))))))

(ert-deftest cmacs-clawtilla-shared-computers-leave-out-the-host ()
  "A host computer is not shareable; who uses each machine is shown."
  (skip-unless (cmacs-clawtilla-tests--available-p))
  (require 'cmacs-clawtilla-agent nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-agent--shared-choices))
  (let ((choices (cmacs-clawtilla-agent--shared-choices
                  '(((id . "lab") (type . "container") (shareable . t)
                     (state . "running") (users "a" "b") (running "a"))
                    ((id . "me") (type . "host") (shareable)
                     (state . "unbuilt") (users) (running))))))
    (should (= 2 (length choices)))
    (should (null (cdr (car choices))))
    (should (equal "lab" (cdr (nth 1 choices))))
    (should (string-match-p "2 users, 1 running" (car (nth 1 choices))))))

(ert-deftest cmacs-clawtilla-activity-turns-carry-a-summary ()
  "Each turn gets a stable id and its steps summed by the library."
  (skip-unless (and (cmacs-clawtilla-tests--available-p)
                    (fboundp 'cmacs-clawtilla--step-summary)))
  (require 'cmacs-clawtilla-section nil t)
  (skip-unless (fboundp 'cmacs-clawtilla-section--activity-turns))
  (let* ((json (concat
                "{\"now\":1800000000000000,\"turns\":[{\"agent\":\"scout\","
                "\"room\":\"dm:scout\",\"started\":1799999990000000,"
                "\"steerable\":true,\"running_turns\":1,\"step_count\":1,"
                "\"steps\":[{\"kind\":\"tool\",\"tool\":\"Read\","
                "\"text\":\"a.c\",\"failed\":null,\"ts\":1799999995}]}]}"))
         (turns (cmacs-clawtilla-section--activity-turns json)))
    (should (= 1 (length turns)))
    (should (equal "scout/dm:scout" (alist-get 'id (car turns))))
    (should (eq t (alist-get 'steerable (car turns))))
    (should (assq 'summary (car turns)))))


(provide 'cmacs-clawtilla-tests)

;;; cmacs-clawtilla-tests.el ends here
