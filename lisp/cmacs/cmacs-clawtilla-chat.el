;;; cmacs-clawtilla-chat.el --- A clawtilla transcript -*- lexical-binding: t; -*-

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

;; One conversation, in the shape ement.el gave Emacs for this: a
;; read-only transcript that appends, and composing as a separate act.
;;
;; What is drawn is decided by the library wherever there is a decision
;; to make -- where a run starts, when a day divider belongs, how a
;; timestamp reads, how a group of tool calls summarises -- because
;; those answers already exist and a third opinion about them is how
;; three clients stop looking like one product.
;;
;; Two behaviours are worth naming because they are easy to get subtly
;; wrong and nobody reports them as bugs, they just stop using the
;; thing:
;;
;; A refresh APPENDS.  Redrawing the whole transcript on every event
;; loses the selection, the scroll position and any collapsed tool run,
;; and does it most often exactly when the agent is busiest.
;;
;; Following the live edge is conditional on already being at it.  A
;; transcript that scrolls to the bottom while you are reading further
;; up is one you cannot read during a turn -- which is the only time
;; anybody is watching it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-alerts)

(declare-function cmacs-clawtilla--run-is-start "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--time-label "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--step-summary "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--steps "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--step-precedes "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--unread-should-count
                  "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla-files "cmacs-clawtilla-files")
(declare-function cmacs-clawtilla-open-app "cmacs-clawtilla-pages")
(declare-function cmacs-clawtilla-fleet "cmacs-clawtilla-fleet")
(declare-function cmacs-clawtilla-agent "cmacs-clawtilla-agent")

(defcustom cmacs-clawtilla-chat-follow t
  "Whether the transcript follows new messages to the bottom.

Only when point is already at the bottom.  Scrolling somebody down
while they are reading further up makes a transcript unreadable during
a turn, which is the only time anybody watches one."
  :type 'boolean
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-chat-fold-tool-runs t
  "Whether a run of tool calls starts collapsed.

Collapsed by default: a turn can be twenty calls long, and what somebody
reads is the answer.  The summary line says what was done, and TAB opens
it when that is not enough."
  :type 'boolean
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-chat-sender-width 12
  "Columns reserved for a sender's name."
  :type 'integer
  :group 'cmacs-clawtilla)

(defvar-local cmacs-clawtilla-chat--room nil)
(defvar-local cmacs-clawtilla-chat--agent nil)
(defvar-local cmacs-clawtilla-chat--seen nil
  "Ids of the messages already drawn, so a refresh appends.")
(defvar-local cmacs-clawtilla-chat--last-sender nil)
(defvar-local cmacs-clawtilla-chat--last-day nil)
(defvar-local cmacs-clawtilla-chat--steps-json nil
  "The steps array exactly as the daemon sent it.

Kept as text.  A step has to travel back to C as the JSON that arrived:
re-encoding a parsed one turns a null `failed' into an empty object,
which the library reads with a has_member() check that a null passes --
one GLib CRITICAL per step, per redraw.")
(defvar-local cmacs-clawtilla-chat--drawn-steps 0
  "How many steps of the raw array are already in the transcript.

An index rather than a set of identities, because a step run is a
CONTIGUOUS range of that array and the library summarises a range by
its bounds.  Steps are only ever appended, so an index that has been
drawn stays drawn.")
(defvar-local cmacs-clawtilla-chat--steps-start nil
  "Where the live activity line begins, or nil.")
(defvar-local cmacs-clawtilla-chat--busy nil
  "Non-nil while this agent is mid-turn.")
(defvar-local cmacs-clawtilla-chat--peer nil
  "The agent this one is working with, if any.")

(defvar-local cmacs-clawtilla-chat--rule-at nil
  "The id of the message the \"New messages\" rule goes above, once.

Placed by the first history load from the daemon's read mark and spent
when drawn: a replay of the history must not draw a second rule above
something that has since been read.")
(defvar-local cmacs-clawtilla-chat--rule-done nil
  "Non-nil once this buffer has decided where its rule goes.")
(defvar-local cmacs-clawtilla-chat--read-sent nil
  "The message id this buffer last told the daemon it had read up to.")
(defvar-local cmacs-clawtilla-chat--last-round 0
  "The round of the last message drawn, so a new round is marked once.")
(defvar-local cmacs-clawtilla-chat--decisions nil
  "The decisions asked in this conversation: a list of (DATA . TEXT).

DATA is one parsed `decision.list' entry and TEXT the same entry as the
daemon sent it, which is what libclawt is asked about.")
(defvar-local cmacs-clawtilla-chat--rescue nil
  "What the daemon offers for a turn that has gone quiet: rescue offers.")

(defface cmacs-clawtilla-chat-mark
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for a mark the daemon put on a message: steered, acknowledged."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-chat-self
  '((t :inherit font-lock-string-face))
  "Face for the operator's own name in a transcript."
  :group 'cmacs-clawtilla)


;;;; Drawing.

(defun cmacs-clawtilla-chat--at-end-p ()
  "Return non-nil if point is at the live edge."
  (>= (point) (- (point-max) 1)))

(defmacro cmacs-clawtilla-chat--appending (&rest body)
  "Append with BODY, following the live edge only if already there."
  (declare (indent 0) (debug t))
  `(let ((inhibit-read-only t)
         (follow (and cmacs-clawtilla-chat-follow
                      (cmacs-clawtilla-chat--at-end-p)))
         (windows (get-buffer-window-list (current-buffer) nil t)))
     (save-excursion
       (goto-char (point-max))
       ,@body)
     (when follow
       (goto-char (point-max))
       (dolist (window windows)
         (with-selected-window window
           (goto-char (point-max))
           (recenter -1))))))

(defun cmacs-clawtilla-chat--seal (start end)
  "Make the region from START to END read-only.

`front-sticky' as well as `rear-nonsticky': without the first, text can
be inserted at the very START of a protected run, which is not
protection, it is protection that fails in the one place somebody would
notice."
  (add-text-properties start end
                       '(read-only t front-sticky (read-only)
                                   rear-nonsticky (read-only))))

(defun cmacs-clawtilla-chat--day (ts)
  "Return the day key for TS."
  (format-time-string "%F" (seconds-to-time ts)))

(defun cmacs-clawtilla-chat--marks (message)
  "Return the marks the daemon put on MESSAGE, as one propertised string.

Every word is libclawt's: that a message was folded into a running turn
(`steered'), cut short (`interrupted'), answered without waking anybody
(`acknowledged'), is a consultation, or crossed over from another
conversation.  A client that worded these itself would be the third
spelling of each."
  (let ((marks nil)
        (steered (alist-get 'steered message))
        (consult (alist-get 'consult message))
        (answer (alist-get 'answer_from message)))
    (cl-flet ((mark (label &optional tip)
                (when (and (stringp label) (not (string-empty-p label)))
                  (push (propertize label 'face 'cmacs-clawtilla-chat-mark
                                    'help-echo tip)
                        marks))))
      (when (and (stringp steered) (not (string-empty-p steered)))
        (mark (cmacs-clawtilla-label 'steered)
              (cmacs-clawtilla-ask "steered-tooltip" :outcome steered)))
      (when (and (numberp (alist-get 'interrupted message))
                 (/= 0 (alist-get 'interrupted message)))
        (mark (cmacs-clawtilla-label 'interrupted)
              (cmacs-clawtilla-label 'interrupted_tooltip)))
      (when (and (numberp (alist-get 'acknowledged message))
                 (/= 0 (alist-get 'acknowledged message)))
        (mark (cmacs-clawtilla-label 'ack)
              (cmacs-clawtilla-label 'ack_tooltip)))
      (when (and (numberp consult) (/= 0 consult))
        (mark (cmacs-clawtilla-ask "message-consult" :role consult)
              (cmacs-clawtilla-label 'consult_tooltip)))
      (when (stringp (alist-get 'crosstalk_room message))
        (mark (cmacs-clawtilla-label 'crosstalk)
              (cmacs-clawtilla-label 'crosstalk_tooltip))
        (when (and (stringp answer) (not (string-empty-p answer)))
          (mark (cmacs-clawtilla-ask "message-answer" :answer_from answer)))))
    (string-join (nreverse marks) "  ")))

(defun cmacs-clawtilla-chat--insert-notes (message)
  "Insert the notes the daemon put under MESSAGE.

Who it is waiting on, and who was named but skipped this round."
  (let ((waiting (alist-get 'waiting_on message))
        (skipped (alist-get 'skipped message)))
    (when (and (stringp waiting) (not (string-empty-p waiting)))
      (when-let* ((note (cmacs-clawtilla-ask "message-waiting"
                                             :waiting_on waiting)))
        (insert "    " (propertize note 'face 'cmacs-clawtilla-chat-mark
                                   'help-echo (cmacs-clawtilla-label
                                               'waiting_tooltip))
                "\n")))
    ;; Somebody named in a group room who already answered this thread:
    ;; kept in the room, marked as not delivered, with the reason.
    (when (and (stringp skipped) (not (string-empty-p skipped)))
      (when-let* ((note (cmacs-clawtilla-ask
                         "round-skip" :skipped skipped
                         :reason (alist-get 'skip_reason message))))
        (insert "    " (propertize note 'face 'cmacs-clawtilla-chat-mark
                                   'help-echo (cmacs-clawtilla-label
                                               'round_skip_tooltip))
                "\n")))))

(defun cmacs-clawtilla-chat--insert-body (sender body)
  "Insert BODY, a message from SENDER, folded if the library says so.

Another agent's long message to the agent whose conversation this is
folds to one line (`clawt_chat_should_fold'): a page-long brief from a
chief should not bury the lines around it.  TAB opens it.  A group room
has no such agent and never folds."
  (let* ((fold (and cmacs-clawtilla-chat--agent
                    (cmacs-clawtilla-ask-parsed
                     "chat-fold" :sender sender
                     :viewer cmacs-clawtilla-chat--agent :body body)))
         (lines (split-string (cmacs-clawtilla-render-markdown body) "\n")))
    (if (not (eq t (alist-get 'fold fold)))
        (dolist (line lines)
          (insert "    " line "\n"))
      (let ((start (point)) heading-end body-start)
        (insert "    "
                (propertize "▸ " 'face 'cmacs-clawtilla-chat-step)
                (or (alist-get 'preview fold) "")
                "\n")
        (setq heading-end (point)
              body-start (point))
        (dolist (line lines)
          (insert "    " line "\n"))
        ;; The same overlay the tool runs fold with, so TAB opens both.
        (let ((overlay (make-overlay body-start (point) nil t nil)))
          (overlay-put overlay 'cmacs-clawtilla-step-body t)
          (overlay-put overlay 'invisible t)
          (put-text-property start heading-end
                             'cmacs-clawtilla-step-run overlay))))))

(defun cmacs-clawtilla-chat--insert-message (message)
  "Insert MESSAGE at point."
  (let* ((sender (or (alist-get 'sender message) "?"))
         (body (or (alist-get 'body message) ""))
         (ts (or (alist-get 'ts message) 0))
         (round (or (alist-get 'round message) 0))
         (day (cmacs-clawtilla-chat--day ts))
         (boundary (cmacs-clawtilla--parse
                    (cmacs-clawtilla--run-is-start
                     cmacs-clawtilla-chat--last-sender
                     cmacs-clawtilla-chat--last-day sender day)))
         (start-run (eq t (alist-get 'start boundary)))
         (new-day (eq t (alist-get 'new-day boundary)))
         (marks (cmacs-clawtilla-chat--marks message))
         (start (point)))
    ;; The divider, and whether there should be one, are both the
    ;; library's answer.  A client that decided for itself would draw
    ;; one on every message or lose it entirely.
    (when new-day
      (insert "\n"
              (cmacs-clawtilla-dim
               (format "── %s ──"
                       (or (cmacs-clawtilla--time-label ts t) day)))
              "\n"))
    ;; "New messages": above the first message after the read mark that
    ;; somebody else sent, where `clawt_unread_rule_index' put it.
    (when (and cmacs-clawtilla-chat--rule-at
               (equal (alist-get 'id message) cmacs-clawtilla-chat--rule-at))
      (setq cmacs-clawtilla-chat--rule-at nil)
      (insert (propertize "──────────────  New messages  ──────────────"
                          'face 'cmacs-clawtilla-unread)
              "\n"))
    ;; A round in a group room starts at each message from you, a
    ;; routine or a trigger; said once, where it starts.
    (when (and (numberp round) (> round 0)
               (/= round cmacs-clawtilla-chat--last-round))
      (setq cmacs-clawtilla-chat--last-round round)
      (when-let* ((label (cmacs-clawtilla-ask "round-label" :round round)))
        (insert (cmacs-clawtilla-dim (format "· %s ·" label)) "\n")))
    (when (or start-run (not (string-empty-p marks)))
      (insert (propertize
               (truncate-string-to-width
                sender cmacs-clawtilla-chat-sender-width nil ?\s)
               'face (if (equal sender "user")
                         'cmacs-clawtilla-chat-self
                       'cmacs-clawtilla-agent))
              " "
              (cmacs-clawtilla-dim (or (cmacs-clawtilla--time-label ts) ""))
              (if (string-empty-p marks) "" (concat "  " marks))
              "\n"))
    (cmacs-clawtilla-chat--insert-body sender body)
    (cmacs-clawtilla-chat--insert-notes message)
    (put-text-property start (point) 'cmacs-clawtilla-section
                       (list :type 'message :value message
                             :identity (format "message/%s"
                                               (alist-get 'id message))
                             :level 0 :foldable nil))
    (cmacs-clawtilla-chat--seal start (point))
    (setq cmacs-clawtilla-chat--last-sender sender)
    (setq cmacs-clawtilla-chat--last-day day)))

(defun cmacs-clawtilla-chat--split-steps ()
  "Return the split of the steps this room has seen.

An alist of `history', `live' and `summary'.  The summary is computed
in C from the step objects rather than here, because building it here
would mean re-encoding a step -- and a step that has been through
`json-parse-string' and back has its `failed: false' turned into an
empty object, which the library then reads as a boolean."
  (and cmacs-clawtilla-chat--steps-json
       (cmacs-clawtilla--parse
        (cmacs-clawtilla--steps
         cmacs-clawtilla-chat--steps-json
         cmacs-clawtilla-chat--agent
         (cmacs-clawtilla-chat--newest-ts)))))

(defun cmacs-clawtilla-chat--append-messages (messages)
  "Append any of MESSAGES not already drawn, and refresh the status line."
  (cmacs-clawtilla-chat--appending
    ;; The status line lives at the very end, so it comes down before
    ;; anything is added and goes back after.
    (cmacs-clawtilla-chat--clear-activity)
    (dolist (message messages)
      (let ((id (alist-get 'id message)))
        (unless (member id cmacs-clawtilla-chat--seen)
          (push id cmacs-clawtilla-chat--seen)
          ;; Whatever this message overtook goes in FIRST: the calls
          ;; happened before the answer, and a transcript that puts them
          ;; after it reads backwards.
          (cmacs-clawtilla-chat--append-steps-before
           (or (alist-get 'ts message) 0))
          (cmacs-clawtilla-chat--insert-message message))))
    (cmacs-clawtilla-chat--draw-activity
     (cmacs-clawtilla-chat--split-steps))))

(defface cmacs-clawtilla-chat-step
  '((t :inherit shadow))
  "Face for a tool call in the transcript."
  :group 'cmacs-clawtilla)

(defface cmacs-clawtilla-chat-step-failed
  '((t :inherit error))
  "Face for a tool call that failed."
  :group 'cmacs-clawtilla)

(defun cmacs-clawtilla-chat--step-identity (step)
  "Return a stable identity for STEP."
  (format "%s/%s/%s"
          (or (alist-get 'timestamp step) 0)
          (or (alist-get 'tool step) "")
          (or (alist-get 'text step) "")))

(defun cmacs-clawtilla-chat--step-line (step)
  "Return the one-line rendering of STEP."
  (let ((tool (alist-get 'tool step))
        (text (alist-get 'text step))
        (failed (eq t (alist-get 'failed step))))
    (concat "    "
            (propertize
             (concat (if failed "✗ " "· ")
                     (if (and tool (not (string-empty-p tool)))
                         (concat tool
                                 (when (and text (not (string-empty-p text)))
                                   (concat " " text)))
                       (or text "")))
             'face (if failed
                       'cmacs-clawtilla-chat-step-failed
                     'cmacs-clawtilla-chat-step))
            ;; A tool call that came with an app: a link out, worded by
            ;; the library, opened with `o' on this line.
            (if (alist-get 'app_id step)
                (concat "  "
                        (propertize
                         (format "[%s]" (or (alist-get 'app_label step) "app"))
                         'face 'cmacs-clawtilla-link
                         'cmacs-clawtilla-app (alist-get 'app_id step)))
              ""))))

(defun cmacs-clawtilla-chat-open-app ()
  "Open the app the tool call on this line came with, in a browser.

This client draws no HTML in a transcript, so it links out, as the GTK
one does: the daemon answers where the web client's sandboxed view of
the app is (`connector.app_get')."
  (interactive)
  (let ((app (or (get-text-property (point) 'cmacs-clawtilla-app)
                 (save-excursion
                   (goto-char (line-beginning-position))
                   (let ((at (text-property-not-all
                              (point) (line-end-position)
                              'cmacs-clawtilla-app nil)))
                     (and at (get-text-property at 'cmacs-clawtilla-app)))))))
    (unless app (user-error "No app on this line"))
    (unless cmacs-clawtilla-chat--agent
      (user-error "This room is not one agent's"))
    (require 'cmacs-clawtilla-pages)
    (cmacs-clawtilla-open-app cmacs-clawtilla-chat--agent app
                              (cmacs-clawtilla-current))))

(defun cmacs-clawtilla-chat--insert-step-run (steps summary)
  "Insert STEPS as one collapsible run headed by SUMMARY.

Folded with an overlay rather than by redrawing.  This transcript
APPENDS -- it is never rebuilt -- so there is nothing to re-render a
fold into; an overlay toggles in place and survives everything that
arrives after it."
  (let ((start (point))
        (heading-end nil)
        (body-start nil))
    (insert "    "
            (propertize (concat (if cmacs-clawtilla-chat-fold-tool-runs
                                    "\u25b8 " "\u25be ")
                                (or summary
                                    (format "%d tool call%s" (length steps)
                                            (if (= 1 (length steps)) "" "s"))))
                        'face 'cmacs-clawtilla-chat-step)
            "\n")
    (setq heading-end (point))
    (setq body-start (point))
    (dolist (step steps)
      (insert (cmacs-clawtilla-chat--step-line step) "\n"))
    (let ((overlay (make-overlay body-start (point) nil t nil)))
      (overlay-put overlay 'cmacs-clawtilla-step-body t)
      (overlay-put overlay 'invisible cmacs-clawtilla-chat-fold-tool-runs)
      (put-text-property start heading-end 'cmacs-clawtilla-step-run overlay))
    (cmacs-clawtilla-chat--seal start (point))))

(defun cmacs-clawtilla-chat-toggle-step-run ()
  "Open or close the run of tool calls at point.

Falls through to the ordinary section fold when point is not on one, so
TAB means the same thing everywhere."
  (interactive)
  (let ((overlay (get-text-property (point) 'cmacs-clawtilla-step-run)))
    (if (not (overlayp overlay))
        (if (cmacs-clawtilla-section-at-point)
            (cmacs-clawtilla-toggle-fold)
          (user-error "Nothing to fold here"))
      (let ((closed (overlay-get overlay 'invisible))
            (inhibit-read-only t))
        (overlay-put overlay 'invisible (not closed))
        (save-excursion
          (goto-char (line-beginning-position))
          (when (re-search-forward "[\u25b8\u25be]" (line-end-position) t)
            (replace-match (if closed "\u25be" "\u25b8"))))))))

(defun cmacs-clawtilla-chat--append-steps-before (message-ts)
  "Write the steps MESSAGE-TS has overtaken, as one collapsible run.

Before the message rather than after it, which is where they happened.
Appending them afterwards -- which is what this did -- puts a turn's
tool calls below the answer they produced, so the transcript reads
backwards."
  (let* ((raw cmacs-clawtilla-chat--steps-json)
         (split (and raw (cmacs-clawtilla--parse
                          (cmacs-clawtilla--steps
                           raw cmacs-clawtilla-chat--agent message-ts))))
         (history (alist-get 'history split))
         (upto (length history))
         (from cmacs-clawtilla-chat--drawn-steps))
    (when (> upto from)
      (let ((steps (seq-subseq history from upto))
            ;; Summarised from the RAW array by its bounds, which is
            ;; what the library takes -- and means no step is re-encoded
            ;; to ask the question.
            (summary (cmacs-clawtilla--step-summary
                      raw cmacs-clawtilla-chat--agent from upto)))
        (cmacs-clawtilla-chat--insert-step-run steps summary))
      (setq cmacs-clawtilla-chat--drawn-steps upto))))

(defun cmacs-clawtilla-chat--clear-activity ()
  "Remove the live activity line, if there is one."
  (when (and cmacs-clawtilla-chat--steps-start
             (<= cmacs-clawtilla-chat--steps-start (point-max)))
    (let ((inhibit-read-only t))
      (delete-region cmacs-clawtilla-chat--steps-start (point-max)))
    (setq cmacs-clawtilla-chat--steps-start nil)))

(defun cmacs-clawtilla-chat--newest-ts ()
  "Return the timestamp of the newest message drawn, or 0."
  (let ((newest 0))
    (save-excursion
      (goto-char (point-max))
      (let ((limit 0))
        (while (and (> (point) (point-min)) (< limit 200))
          (let ((section (cmacs-clawtilla-section-at-point)))
            (when (and section (eq (plist-get section :type) 'message))
              (setq newest (max newest
                                (or (alist-get 'ts (plist-get section :value))
                                    0)))))
          (forward-line -1)
          (setq limit (1+ limit)))))
    newest))

(defun cmacs-clawtilla-chat--draw-activity (split)
  "Draw the status line from SPLIT: what the agent is doing.

The sentence is `clawt_agent_activity_label', the same one the GTK
client and the CLI say, and the tool summary beside it is
`clawt_turn_step_run_summary' -- \"Read 3 files, Changed 2 files\"
rather than every operation called a command."
  (setq cmacs-clawtilla-chat--steps-start (point-max))
  (goto-char (point-max))
  (cmacs-clawtilla-chat--draw-decisions)
  (cmacs-clawtilla-chat--draw-rescue)
  (let* ((activity (and cmacs-clawtilla-chat--busy
                        (cmacs-clawtilla--activity-label
                         cmacs-clawtilla-chat--busy
                         cmacs-clawtilla-chat--peer)))
         (summary (let ((text (alist-get 'summary split)))
                    (unless (or (null text) (string-empty-p text))
                      text)))
         (parts (delq nil (list activity summary))))
    (when parts
      (let ((start (point)))
        ;; The marker says whether a turn is RUNNING, which the words
        ;; alone do not: a summary of what was just done reads the same
        ;; whether the agent is still doing it or has stopped, and only
        ;; one of those is worth waiting for.
        (insert "\n"
                (propertize (concat (if cmacs-clawtilla-chat--busy "⟳ " "· ")
                                    (string-join parts " — "))
                            'face (if cmacs-clawtilla-chat--busy
                                      'cmacs-clawtilla-busy
                                    'cmacs-clawtilla-dim))
                "\n")
        (cmacs-clawtilla-chat--seal start (point))))))


;;;; Decisions asked here, and a turn that has gone quiet.

(defun cmacs-clawtilla-chat--draw-decisions ()
  "Draw the decisions asked in this conversation, at the live edge.

Where they are answered: an agent that asks you something in your own
conversation with it should not need you to go to another page.  The
sentences around the question -- where it was routed, what happens if
nobody answers, how it ended -- are libclawt's, from the decision as
the daemon sent it."
  (dolist (entry cmacs-clawtilla-chat--decisions)
    (let* ((decision (car entry))
           (view (cmacs-clawtilla-ask-parsed
                  "decision-view" :decision (cons :json (cdr entry))))
           (options (alist-get 'options decision))
           (outcome (alist-get 'outcome view))
           (start (point)))
      (insert "\n"
              (propertize (format "%s asks" (or (alist-get 'agent decision)
                                                "?"))
                          'face 'cmacs-clawtilla-agent)
              (if (alist-get 'routed view)
                  (concat "  " (cmacs-clawtilla-dim (alist-get 'routed view)))
                "")
              "\n    "
              (or (cmacs-clawtilla-ask
                   "decision-question"
                   :question (alist-get 'question decision)
                   :loses (alist-get 'loses decision))
                  (alist-get 'question decision) "")
              "\n")
      (cond
       ((and outcome (not (string-empty-p outcome)))
        (insert "    " (cmacs-clawtilla-dim outcome) "\n"))
       (options
        (insert "    "
                (mapconcat (lambda (option)
                             (propertize (format "[%s]" option)
                                         'face 'cmacs-clawtilla-badge))
                           options "  ")
                "   " (cmacs-clawtilla-dim "y answers") "\n"))
       (t
        (insert "    " (cmacs-clawtilla-dim
                        "No options offered: y answers in your own words.")
                "\n")))
      (when (and (alist-get 'default view) (not outcome))
        (insert "    " (cmacs-clawtilla-dim (alist-get 'default view)) "\n"))
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type 'decision :value decision
                               :identity (format "decision/%s"
                                                 (alist-get 'id decision))
                               :level 0 :foldable nil))
      (cmacs-clawtilla-chat--seal start (point)))))

(defun cmacs-clawtilla-chat--draw-rescue ()
  "Draw what the daemon offers for a turn that has said nothing for a while."
  (dolist (offer cmacs-clawtilla-chat--rescue)
    (let ((start (point)))
      (insert "\n"
              (propertize
               (or (cmacs-clawtilla-ask
                    "rescue-offer" :agent cmacs-clawtilla-chat--agent
                    :seconds (or (alist-get 'seconds offer) 0))
                   "")
               'face 'cmacs-clawtilla-busy)
              "\n    "
              (cmacs-clawtilla-dim "u stops it, or sends it again on another model")
              "\n")
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type 'rescue :value offer
                               :identity (format "rescue/%s"
                                                 (alist-get 'room offer))
                               :level 0 :foldable nil))
      (cmacs-clawtilla-chat--seal start (point)))))

(defun cmacs-clawtilla-chat--redraw-tail ()
  "Redraw everything below the last message: decisions, rescue, activity."
  (cmacs-clawtilla-chat--appending
    (cmacs-clawtilla-chat--clear-activity)
    (cmacs-clawtilla-chat--draw-activity
     (cmacs-clawtilla-chat--split-steps))))

(defun cmacs-clawtilla-chat--load-decisions (&optional buffer)
  "Fetch the decisions asked in BUFFER's conversation."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (room (buffer-local-value 'cmacs-clawtilla-chat--room buffer)))
    (cmacs-clawtilla-request-both
     conn "decision.list" (list (cons 'room room))
     (lambda (data text err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (let ((faithful (cmacs-clawtilla-faithful-get
                            (cmacs-clawtilla-faithful text) 'decisions))
                 (index 0)
                 (entries nil))
             (dolist (decision (cmacs-clawtilla-get data 'decisions))
               (push (cons decision
                           (cmacs-clawtilla-faithful-text
                            (cmacs-clawtilla-faithful-get faithful index)))
                     entries)
               (setq index (1+ index)))
             (setq cmacs-clawtilla-chat--decisions (nreverse entries)))
           (cmacs-clawtilla-chat--redraw-tail)))))))

(defun cmacs-clawtilla-chat--load-rescue (&optional buffer)
  "Ask whether BUFFER's agent has a turn the daemon offers to rescue."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (agent (buffer-local-value 'cmacs-clawtilla-chat--agent buffer)))
    (when agent
      (cmacs-clawtilla-request
       conn "turn.rescue" (list (cons 'action "list") (cons 'agent agent))
       (lambda (data err)
         (when (and (buffer-live-p buffer) (not err))
           (with-current-buffer buffer
             (setq cmacs-clawtilla-chat--rescue
                   (cmacs-clawtilla-get data 'offers))
             (cmacs-clawtilla-chat--redraw-tail))))))))

(defun cmacs-clawtilla-chat-answer ()
  "Answer the decision at point, or the only one waiting here.

Offers the options the agent gave; anything else typed is sent as it
is.  Recorded as answered from the chat, which is what the other
clients then say about it."
  (interactive)
  (let* ((open (seq-filter
                (lambda (entry) (alist-get 'options (car entry)))
                cmacs-clawtilla-chat--decisions))
         (decision (or (cmacs-clawtilla-value-at-point 'decision)
                       (and (= 1 (length cmacs-clawtilla-chat--decisions))
                            (car (car cmacs-clawtilla-chat--decisions)))
                       (car (car open))
                       (user-error "No decision is waiting here")))
         (options (alist-get 'options decision))
         (answer (if options
                     (completing-read
                      (format "%s: " (or (alist-get 'question decision)
                                         "Answer"))
                      options)
                   (read-string "Answer: ")))
         (buffer (current-buffer)))
    (when (string-empty-p answer) (user-error "Nothing to answer with"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "decision.answer"
     (cmacs-clawtilla--as-alist
      (list :decision (alist-get 'id decision) :answer answer
            :via (or (cmacs-clawtilla-label 'decision_via_chat) "")))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-chat--load-decisions buffer)))))))

(defun cmacs-clawtilla-chat-rescue ()
  "Stop the turn that has gone quiet, or send it again on another model.

The choices are the daemon's, per turn: Stop always, and each model it
could switch to for this turn only.  Either one stops everything else
the agent is running too -- the agent stays up."
  (interactive)
  (let* ((offer (or (cmacs-clawtilla-value-at-point 'rescue)
                    (car cmacs-clawtilla-chat--rescue)
                    (user-error "Nothing here needs rescuing")))
         (choices (mapcar (lambda (model)
                            (cons (or (cmacs-clawtilla-ask "rescue-switch"
                                                           :model model)
                                      model)
                                  model))
                          (alist-get 'choices offer)))
         (stop "Stop")
         (pick (completing-read "Rescue: " (cons stop (mapcar #'car choices))
                                nil t))
         (model (cdr (assoc pick choices)))
         (buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "turn.rescue"
     (append (list (cons 'action (if model "switch" "stop"))
                   (cons 'agent cmacs-clawtilla-chat--agent))
             (and (alist-get 'room offer)
                  (list (cons 'room (alist-get 'room offer))))
             (and model (list (cons 'model model))))
     (lambda (_data err)
       (message "clawtilla: %s"
                (or err
                    (if model
                        "stopped, and sent the same message again on the other model, for this turn only"
                      "stopped")))
       (when (buffer-live-p buffer)
         (cmacs-clawtilla-chat--load-rescue buffer))))))


;;;; Loading.

(defun cmacs-clawtilla-chat--place-rule (data text)
  "Decide, once, where this buffer's \"New messages\" rule goes.

DATA and TEXT are a `room.history' reply.  The index is libclawt's,
from the read mark the daemon holds; a daemon too old to hold one sends
no `read_upto' and gets no rule, because a rule above the whole
transcript says nothing true."
  (unless cmacs-clawtilla-chat--rule-done
    (setq cmacs-clawtilla-chat--rule-done t)
    (when (assq 'read_upto data)
      (let* ((messages (cmacs-clawtilla-get data 'messages))
             (index (string-to-number
                     (or (cmacs-clawtilla-ask
                          "unread-rule-index"
                          :messages (cons :json (cmacs-clawtilla-member-json
                                                 text 'messages))
                          :read_upto (alist-get 'read_upto data))
                         "-1"))))
        (when (and (>= index 0) (< index (length messages)))
          (setq cmacs-clawtilla-chat--rule-at
                (alist-get 'id (nth index messages))))))))

(defun cmacs-clawtilla-chat--read-upto (conn data)
  "Tell CONN's daemon this conversation is read up to DATA's last message.

After the history is drawn, never before it: its `read_upto' is what
placed the rule.  Only when the daemon holds marks, and only while the
transcript is actually in a window -- a buffer reloading in the
background has shown nobody anything."
  (let ((messages (cmacs-clawtilla-get data 'messages)))
    (when (and (assq 'read_upto data) messages
               (get-buffer-window (current-buffer) t))
      (let ((upto (alist-get 'id (car (last messages)))))
        ;; Once per newest message: this runs on every reload, and a
        ;; turn publishing steps reloads several times a second.
        (unless (equal upto cmacs-clawtilla-chat--read-sent)
          (setq cmacs-clawtilla-chat--read-sent upto)
          (cmacs-clawtilla-mark-read cmacs-clawtilla-chat--room conn upto))))))

(defun cmacs-clawtilla-chat--load (&optional buffer)
  "Fetch history and steps for BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (room (buffer-local-value 'cmacs-clawtilla-chat--room buffer)))
    (cmacs-clawtilla-request-both
     conn "room.history" (list (cons 'room room) (cons 'as "user"))
     (lambda (data text err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             ;; The resolved room, not the id asked for: an agent id
             ;; resolves to its direct room, and every later frame has
             ;; to name the same thing the daemon named back.
             (setq cmacs-clawtilla-chat--room
                   (or (cmacs-clawtilla-get data 'room) room))
             (cmacs-clawtilla-chat--place-rule data text)
             (cmacs-clawtilla-chat--append-messages
              (cmacs-clawtilla-get data 'messages))
             (cmacs-clawtilla-chat--read-upto conn data))))))
    (cmacs-clawtilla-chat--load-decisions buffer)
    (cmacs-clawtilla-chat--load-rescue buffer)
    (cmacs-clawtilla-request-raw
     conn "room.steps" (list (cons 'room room) (cons 'as "user")
                             (cons 'live t))
     (lambda (json err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           ;; Kept as the text that arrived; see the variable.
           (setq cmacs-clawtilla-chat--steps-json
                 (cmacs-clawtilla-member-json json 'steps))
           (cmacs-clawtilla-chat--appending
             (cmacs-clawtilla-chat--clear-activity)
             ;; Steps the newest message already overtook, in case they
             ;; arrived after it did.
             (cmacs-clawtilla-chat--append-steps-before
              (cmacs-clawtilla-chat--newest-ts))
             (cmacs-clawtilla-chat--draw-activity
              (cmacs-clawtilla-chat--split-steps)))))))
    ;; Whether the agent is mid-turn, and with whom.  Asked rather than
    ;; inferred from the steps: a turn can be running with nothing to
    ;; show for it yet, and that is exactly when somebody wants to know.
    (when (buffer-local-value 'cmacs-clawtilla-chat--agent buffer)
      (cmacs-clawtilla-request
       conn "agent.show"
       (list (cons 'agent (buffer-local-value 'cmacs-clawtilla-chat--agent
                                              buffer)))
       (lambda (data err)
         (when (and (buffer-live-p buffer) (not err))
           (with-current-buffer buffer
             (let ((agent (or (cmacs-clawtilla-get data 'agent) data)))
               (setq cmacs-clawtilla-chat--busy
                     (eq t (alist-get 'busy agent)))
               (setq cmacs-clawtilla-chat--peer (alist-get 'peer agent)))
             (cmacs-clawtilla-chat--appending
               (cmacs-clawtilla-chat--clear-activity)
               (cmacs-clawtilla-chat--draw-activity
                (cmacs-clawtilla-chat--split-steps))))))))))


;;;; Sending.

(defun cmacs-clawtilla-chat--send (body)
  "Send BODY to this conversation."
  (let ((conn (cmacs-clawtilla-current))
        (target (or cmacs-clawtilla-chat--agent cmacs-clawtilla-chat--room))
        (buffer (current-buffer)))
    (cmacs-clawtilla-request
     conn "msg.send"
     (list (cons 'target target) (cons 'body body) (cons 'from "user"))
     (lambda (data err)
       (cond
        (err (message "clawtilla: %s" err))
        ;; A stopped agent accepts mail -- that is what the mailbox is
        ;; for -- but nothing will read it until it starts, and a client
        ;; that cannot say so shows a spinner that never resolves.
        ((equal (cmacs-clawtilla-get data 'target_state) "stopped")
         (message "clawtilla: held in %s's mailbox until it starts" target))
        ((eq t (cmacs-clawtilla-get data 'steered))
         (message "clawtilla: steered into the running turn")))
       (when (buffer-live-p buffer)
         (cmacs-clawtilla-chat--load buffer))))))

(defvar-local cmacs-clawtilla-chat--parent nil
  "The transcript a compose buffer belongs to.")

(defvar cmacs-clawtilla-chat-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-clawtilla-chat-compose-send)
    (define-key map (kbd "C-c C-k") #'cmacs-clawtilla-chat-compose-cancel)
    map)
  "Keymap for `cmacs-clawtilla-chat-compose-mode'.")

(define-derived-mode cmacs-clawtilla-chat-compose-mode text-mode
  "Clawtilla-Compose"
  "Major mode for writing a message to an agent.

A real buffer rather than the minibuffer, because a message to an agent
is usually not one line: it has a paragraph, a path, a snippet of code.
The minibuffer can hold those and is a bad place to write them -- no
newline without a prefix, no wrapping, and nothing you can leave and
come back to."
  :group 'cmacs-clawtilla
  (setq-local header-line-format
              (substitute-command-keys
               "\\[cmacs-clawtilla-chat-compose-send] to send, \\[cmacs-clawtilla-chat-compose-cancel] to abandon"))
  (visual-line-mode 1))

(defcustom cmacs-clawtilla-chat-compose-height 10
  "How many lines the compose buffer gets."
  :type 'integer
  :group 'cmacs-clawtilla)

(defun cmacs-clawtilla-chat-send ()
  "Write a message to this conversation.

Opens a compose buffer under the transcript.  A slash command works
there too: a buffer whose whole content begins with `/' is run as one
rather than sent, so `/help' does not have to be typed somewhere else."
  (interactive)
  (cmacs-clawtilla-chat-compose))

(defun cmacs-clawtilla-chat-compose (&optional initial)
  "Compose a message, starting from INITIAL."
  (interactive)
  (let* ((parent (current-buffer))
         (buffer (get-buffer-create
                  (format "*clawtilla compose: %s*"
                          (or cmacs-clawtilla-chat--agent
                              cmacs-clawtilla-chat--room "message"))))
         (window (display-buffer-below-selected
                  buffer
                  `((window-height . ,cmacs-clawtilla-chat-compose-height)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-chat-compose-mode)
        (cmacs-clawtilla-chat-compose-mode))
      (erase-buffer)
      (when initial (insert initial))
      (setq-local cmacs-clawtilla-chat--parent parent))
    (when window (select-window window))
    buffer))

(defun cmacs-clawtilla-chat-compose-send ()
  "Send what is in the compose buffer."
  (interactive)
  (let ((body (string-trim (buffer-string)))
        (parent cmacs-clawtilla-chat--parent)
        (window (get-buffer-window (current-buffer))))
    (if (string-empty-p body)
        (message "clawtilla: nothing to send")
      (unless (buffer-live-p parent)
        (user-error "That conversation is gone"))
      (with-current-buffer parent
        (if (string-prefix-p "/" body)
            (cmacs-clawtilla-chat--slash body)
          (cmacs-clawtilla-chat--send body)))
      (cmacs-clawtilla-chat--close-compose window))))

(defun cmacs-clawtilla-chat-compose-cancel ()
  "Abandon what is in the compose buffer."
  (interactive)
  (cmacs-clawtilla-chat--close-compose (get-buffer-window (current-buffer)))
  (message "clawtilla: abandoned"))

(defun cmacs-clawtilla-chat--close-compose (window)
  "Close the compose buffer showing in WINDOW."
  (let ((buffer (current-buffer)))
    (when (and window (window-live-p window)
               (not (eq window (frame-root-window window))))
      (delete-window window))
    (kill-buffer buffer)))


;;;; Slash commands.

(defconst cmacs-clawtilla-chat-slash-commands
  '(("/agents"    . "list the fleet")
    ("/attach"    . "send a file")
    ("/clear"     . "clear this transcript")
    ("/compose"   . "write a longer message")
    ("/copy"      . "copy the last reply")
    ("/edit"      . "open a file of this agent's")
    ("/export"    . "save this conversation")
    ("/files"     . "browse this agent's files")
    ("/flow"      . "what the agents said to each other")
    ("/help"      . "this list")
    ("/interrupt" . "stop the running turn")
    ("/memory"    . "search what is remembered")
    ("/new"       . "start a fresh conversation")
    ("/recall"    . "recall a past conversation")
    ("/reset"     . "reset this agent's session")
    ("/restart"   . "restart this agent")
    ("/retry"     . "send the last message again")
    ("/start"     . "start this agent")
    ("/stop"      . "stop this agent")
    ("/tasks"     . "what has been delegated"))
  "Every slash command, with what it does.

The same twenty the GTK client answers.  clawtilla's `make parity'
compares the literal set each client contains, so one added there and
not here fails the build rather than going unnoticed until somebody
reaches for the half that was not built.")

(defun cmacs-clawtilla-chat--slash (input)
  "Run INPUT, a slash command."
  (pcase-let* ((`(,command . ,rest)
                (let ((space (string-search " " input)))
                  (if space
                      (cons (substring input 0 space)
                            (string-trim (substring input space)))
                    (cons input "")))))
    (pcase command
      ("/help" (cmacs-clawtilla-chat-help))
      ("/agents" (cmacs-clawtilla-fleet (cmacs-clawtilla-current)))
      ("/compose" (cmacs-clawtilla-chat-compose))
      ("/clear" (cmacs-clawtilla-chat-clear))
      ("/copy" (cmacs-clawtilla-chat-copy-last))
      ("/export" (cmacs-clawtilla-chat-export))
      ("/interrupt" (cmacs-clawtilla-chat--agent-frame "agent.interrupt"))
      ("/start" (cmacs-clawtilla-chat--agent-frame "agent.start"))
      ("/stop" (cmacs-clawtilla-chat--agent-frame "agent.stop"))
      ("/restart" (cmacs-clawtilla-chat--agent-frame "agent.restart"))
      ("/reset" (cmacs-clawtilla-chat--agent-frame "agent.reset"))
      ("/new" (cmacs-clawtilla-chat-new))
      ("/retry" (cmacs-clawtilla-chat-retry))
      ("/attach" (call-interactively #'cmacs-clawtilla-chat-attach))
      ("/files" (cmacs-clawtilla-chat-files))
      ("/edit" (cmacs-clawtilla-chat-edit rest))
      ("/memory" (cmacs-clawtilla-chat-memory rest))
      ("/recall" (cmacs-clawtilla-chat-recall rest))
      ("/flow" (cmacs-clawtilla-chat-flow))
      ("/tasks" (cmacs-clawtilla-chat-tasks))
      (_ (message "clawtilla: no such command %s; /help lists them"
                  command)))))

(defun cmacs-clawtilla-chat-help ()
  "Show every slash command."
  (interactive)
  (with-current-buffer (get-buffer-create "*clawtilla help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dolist (entry cmacs-clawtilla-chat-slash-commands)
        (insert (propertize (format "%-12s" (car entry))
                            'face 'cmacs-clawtilla-heading)
                (cdr entry) "\n"))
      (goto-char (point-min))
      (special-mode))
    (cmacs-clawtilla-display (current-buffer))))

(defun cmacs-clawtilla-chat--agent-frame (kind)
  "Send KIND for this conversation's agent."
  (let ((agent cmacs-clawtilla-chat--agent))
    (unless agent
      (user-error "This is a room, not one agent"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind (list (cons 'agent agent))
     (lambda (_data err)
       (message "clawtilla: %s" (or err (format "%s %s" agent kind)))))))

(defun cmacs-clawtilla-chat-clear ()
  "Clear what is on screen, leaving the record alone.

Only the buffer.  What was said is the daemon's and is still there; a
client that could delete it from here would be one keystroke from
losing a conversation."
  (interactive)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq cmacs-clawtilla-chat--seen nil)
    (setq cmacs-clawtilla-chat--drawn-steps 0)
    (setq cmacs-clawtilla-chat--last-sender nil)
    (setq cmacs-clawtilla-chat--last-day nil)
    (setq cmacs-clawtilla-chat--steps-start nil)))

(defun cmacs-clawtilla-chat-copy-last ()
  "Copy the last message's body."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (let ((section nil))
      (while (and (not section) (> (point) (point-min)))
        (setq section (cmacs-clawtilla-section-at-point))
        (unless section (forward-line -1)))
      (if section
          (let ((body (alist-get 'body (plist-get section :value))))
            (kill-new body)
            (message "clawtilla: copied"))
        (user-error "Nothing to copy")))))

(defun cmacs-clawtilla-chat-export ()
  "Save this conversation to a file."
  (interactive)
  (let ((file (read-file-name "Export to: " nil nil nil
                              (format "%s.org" cmacs-clawtilla-chat--room))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "room.history"
     (list (cons 'room cmacs-clawtilla-chat--room) (cons 'as "user"))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-temp-file file
           (insert (format "#+title: %s\n\n" cmacs-clawtilla-chat--room))
           (dolist (message (cmacs-clawtilla-get data 'messages))
             (insert (format "* %s  %s\n%s\n\n"
                             (alist-get 'sender message)
                             (or (cmacs-clawtilla--time-label
                                  (or (alist-get 'ts message) 0)) "")
                             (alist-get 'body message)))))
         (message "clawtilla: exported to %s" file))))))

(defun cmacs-clawtilla-chat-new ()
  "Start a fresh conversation with this agent."
  (interactive)
  (cmacs-clawtilla-chat--agent-frame "agent.reset")
  (cmacs-clawtilla-chat-clear)
  (cmacs-clawtilla-chat--load))

(defun cmacs-clawtilla-chat-retry ()
  "Send the operator's last message again."
  (interactive)
  (let ((last nil))
    (save-excursion
      (goto-char (point-max))
      (while (and (not last) (> (point) (point-min)))
        (let ((section (cmacs-clawtilla-section-at-point)))
          (when (and section
                     (equal (alist-get 'sender (plist-get section :value))
                            "user"))
            (setq last (alist-get 'body (plist-get section :value)))))
        (forward-line -1)))
    (if last
        (cmacs-clawtilla-chat--send last)
      (user-error "Nothing of yours to send again"))))

(defun cmacs-clawtilla-chat--file-data (file)
  "Return FILE's bytes as base64 on one line."
  (base64-encode-string
   (with-temp-buffer
     (set-buffer-multibyte nil)
     (insert-file-contents-literally file)
     (buffer-string))
   t))

(defun cmacs-clawtilla-chat-attach (files &optional body)
  "Send FILES with the message BODY to this conversation.

Each file goes to the daemon first (`attachment.put'), and the message
that follows names them in libclawt's attachment block -- the one
spelling every client previews from and the conversation's Files page
finds.  A file the daemon refused is named as not saved rather than
dropped: an agent told nothing about a file it was meant to have
answers as if it had been sent nothing.

Interactively, reads files until an empty answer, then the message."
  (interactive
   (let ((files nil) (file nil))
     (while (progn
              (setq file (read-file-name
                          (if files "Another file (RET to finish): "
                            "Send file: ")
                          nil "" t))
              (and (not (string-empty-p file))
                   (file-regular-p file)))
       (push (expand-file-name file) files))
     (unless files (user-error "No file chosen"))
     (list (nreverse files) (read-string "Say with it (optional): "))))
  (let* ((files (if (listp files) files (list files)))
         (conn (cmacs-clawtilla-current))
         (agent (or cmacs-clawtilla-chat--agent ""))
         (buffer (current-buffer))
         (pending (length files))
         (items (make-vector (length files) nil))
         (index 0))
    (dolist (file files)
      (let ((slot index)
            (name (file-name-nondirectory file)))
        (cmacs-clawtilla-request
         conn "attachment.put"
         (list (cons 'agent agent) (cons 'name name)
               (cons 'data (cmacs-clawtilla-chat--file-data file)))
         (lambda (data err)
           ;; Both paths and the id, as attachment.put reports them: the
           ;; host path for the agent's own read tool, the guest path for
           ;; a command inside its container, the id for every preview.
           (aset items slot
                 (if err
                     (list (cons 'name name) (cons 'unsaved t))
                   (cmacs-clawtilla--as-alist
                    (list :name name
                          :host_path (or (alist-get 'host_path data) "")
                          :path (or (alist-get 'path data) "")
                          :id (or (alist-get 'id data) "")))))
           (setq pending (1- pending))
           (when (zerop pending)
             (let ((block (cmacs-clawtilla-ask
                           "attachment-block" :body (or body "")
                           :items (cons :json
                                        (json-serialize items)))))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (cmacs-clawtilla-chat--send
                    (or block body ""))))))))
        (setq index (1+ index))))))

(defun cmacs-clawtilla-chat-files ()
  "Browse this agent's files."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.files"
   (list (cons 'agent cmacs-clawtilla-chat--agent))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (with-current-buffer (get-buffer-create "*clawtilla files*")
         (let ((inhibit-read-only t))
           (erase-buffer)
           (dolist (file (cmacs-clawtilla-get data 'files))
             (insert (format "%s\n" (or (alist-get 'path file) file))))
           (goto-char (point-min))
           (special-mode))
         (cmacs-clawtilla-display (current-buffer)))))))

(defun cmacs-clawtilla-chat-edit (path)
  "Open PATH, one of this agent's files, in a buffer."
  (interactive "sFile: ")
  (let ((agent cmacs-clawtilla-chat--agent)
        (conn (cmacs-clawtilla-current)))
    (cmacs-clawtilla-request
     conn "agent.file_read" (list (cons 'agent agent) (cons 'name path))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let ((buffer (get-buffer-create
                        (format "*clawtilla:%s:%s*" agent path))))
           (with-current-buffer buffer
             (erase-buffer)
             (insert (or (cmacs-clawtilla-get data 'content) ""))
             (goto-char (point-min))
             (setq-local cmacs-clawtilla-connection conn)
             (setq-local cmacs-clawtilla-chat--agent agent))
           (cmacs-clawtilla-display buffer)))))))

(defun cmacs-clawtilla-chat-memory (query)
  "Search what this fleet remembers for QUERY."
  (interactive "sRecall what? ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "memory.search"
   (list (cons 'query query) (cons 'agent cmacs-clawtilla-chat--agent))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla memory*" (cmacs-clawtilla-get data 'memories)
        ;; Each memory says which store it came out of.  A listing that
        ;; mixed an agent's own conclusion with something the whole
        ;; fleet believes would turn two different claims into one row.
        (lambda (row) (format "%-6s %s"
                              (or (alist-get 'scope row) "")
                              (or (alist-get 'summary row)
                                  (alist-get 'content row) ""))))))))

(defun cmacs-clawtilla-chat-recall (query)
  "Find a past conversation matching QUERY."
  (interactive "sRecall which conversation? ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "memory.recall"
   ;; Recall searches the TRANSCRIPT rather than the memories, and is
   ;; not room-filtered: a person can open any transcript already.
   (list (cons 'query query) (cons 'agent cmacs-clawtilla-chat--agent))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla recall*" (cmacs-clawtilla-get data 'hits)
        (lambda (row) (format "%-14s %-12s %s"
                              (or (alist-get 'room row) "")
                              (or (alist-get 'from_name row)
                                  (alist-get 'from row) "")
                              (or (alist-get 'body row) ""))))))))

(defun cmacs-clawtilla-chat-flow ()
  "Show what the agents said to each other."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "room.history"
   (list (cons 'room "flow") (cons 'as "user"))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla flow*" (cmacs-clawtilla-get data 'messages)
        (lambda (row) (format "%-12s %s" (alist-get 'sender row)
                              (alist-get 'body row))))))))

(defun cmacs-clawtilla-chat-tasks ()
  "Show what has been delegated."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "task.list" nil
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-chat--show-list
        "*clawtilla tasks*" (cmacs-clawtilla-get data 'tasks)
        (lambda (row) (format "%-10s %-10s %s"
                              (or (alist-get 'assignee row) "?")
                              (or (alist-get 'state row) "?")
                              (or (alist-get 'title row) ""))))))))

(defun cmacs-clawtilla-chat--show-list (name rows format-row)
  "Show ROWS in NAME, each through FORMAT-ROW."
  (with-current-buffer (get-buffer-create name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (if (null rows)
          (insert (cmacs-clawtilla-dim "nothing to show") "\n")
        (dolist (row rows)
          (insert (funcall format-row row) "\n")))
      (goto-char (point-min))
      (special-mode))
    (cmacs-clawtilla-display (current-buffer))))


;;;; Attachments already sent, and rooms.

(defun cmacs-clawtilla-chat-attachment-get ()
  "Fetch the attachment at point and open it."
  (interactive)
  (let* ((message (cmacs-clawtilla-value-at-point 'message))
         (id (and message (or (alist-get 'attachment message)
                              (alist-get 'attachment_id message)))))
    (unless id (user-error "No attachment on the message at point"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "attachment.get" (list (cons 'id id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((name (or (cmacs-clawtilla-get data 'name) id))
                (encoded (cmacs-clawtilla-get data 'base64))
                (file (expand-file-name name temporary-file-directory)))
           (when encoded
             (let ((coding-system-for-write 'binary))
               (with-temp-file file
                 (set-buffer-multibyte nil)
                 (insert (base64-decode-string encoded))))
             (find-file file))))))))

(defun cmacs-clawtilla-chat-attachment-remove ()
  "Remove the attachment at point."
  (interactive)
  (let* ((message (cmacs-clawtilla-value-at-point 'message))
         (id (and message (or (alist-get 'attachment message)
                              (alist-get 'attachment_id message)))))
    (unless id (user-error "No attachment on the message at point"))
    (when (yes-or-no-p "Remove that attachment? ")
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "attachment.remove"
       ;; Named by agent and file name, not by id: this deletes from an
       ;; agent's drop-box, and it answers with the host path it
       ;; unlinked.
       (list (cons 'agent (or cmacs-clawtilla-chat--agent ""))
             (cons 'name id))
       (lambda (data e)
         (message "clawtilla: %s"
                  (or e (cmacs-clawtilla-get data 'removed) "removed")))))))

(defun cmacs-clawtilla-chat-gallery ()
  "Show every file sent in this conversation, by you or the agent."
  (interactive)
  (require 'cmacs-clawtilla-files)
  (cmacs-clawtilla-files (cmacs-clawtilla-current)
                         cmacs-clawtilla-chat--agent
                         cmacs-clawtilla-chat--room))

(defun cmacs-clawtilla-chat-toggle-mute ()
  "Mute this conversation's agent, or unmute it."
  (interactive)
  (let* ((conn (cmacs-clawtilla-current))
         (agent (or cmacs-clawtilla-chat--agent
                    (user-error "This room is not one agent's")))
         (muted (cmacs-clawtilla-agent-muted-p conn agent)))
    (cmacs-clawtilla-set-agent-muted conn agent (not muted))
    (message "clawtilla: %s %s" agent (if muted "unmuted" "muted"))))

(defun cmacs-clawtilla-chat-room-create (room name members)
  "Make a room called NAME with id ROOM holding MEMBERS.

Creating it writes the config entry AND makes the room, because writing
the config is not creating it: a room that lived only in the running
daemon was one somebody made, used, restarted, and could not find --
with its transcript still on disk and nothing that would reopen it."
  (interactive (list (read-string "Room id: ")
                     (read-string "Name: ")
                     (read-string "Members (comma separated): ")))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "room.create"
   (list (cons 'room room) (cons 'name name) (cons 'members members))
   (lambda (_d e) (message "clawtilla: %s" (or e (format "made %s" room))))))

(defun cmacs-clawtilla-chat-room-set ()
  "Change this room.

A `members' list REPLACES the membership rather than adding to it, so
it is how somebody is taken out of a room as well as put in -- and
membership is permission, so it is worth knowing which one you are
doing."
  (interactive)
  (let* ((field (completing-read "Change: "
                                 '("name" "members" "require_mention") nil t))
         (value (read-string
                 (if (equal field "members")
                     "Members (this REPLACES the list): "
                   (format "%s: " field)))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "room.set"
     (list (cons 'room cmacs-clawtilla-chat--room) (cons field value))
     (lambda (_d e) (message "clawtilla: %s" (or e "changed"))))))

;;;; The mode.

(transient-define-prefix cmacs-clawtilla-chat-menu ()
  "What this conversation can do."
  ["Say"
   [("i" "send a message" cmacs-clawtilla-chat-send)
    ("c" "compose" cmacs-clawtilla-chat-compose)
    ("a" "attach a file" cmacs-clawtilla-chat-attach)]
   [("r" "send the last again" cmacs-clawtilla-chat-retry)
    ("C" "copy the last" cmacs-clawtilla-chat-copy-last)
    ("x" "export" cmacs-clawtilla-chat-export)]
   [("y" "answer a decision" cmacs-clawtilla-chat-answer)
    ("u" "rescue a quiet turn" cmacs-clawtilla-chat-rescue)
    ("z" "mute / unmute this agent" cmacs-clawtilla-chat-toggle-mute)]]
  ["Agent"
   [("s" "start" (lambda () (interactive)
                   (cmacs-clawtilla-chat--agent-frame "agent.start")))
    ("S" "stop" (lambda () (interactive)
                  (cmacs-clawtilla-chat--agent-frame "agent.stop")))]
   [("k" "interrupt" (lambda () (interactive)
                       (cmacs-clawtilla-chat--agent-frame "agent.interrupt")))
    ("n" "fresh conversation" cmacs-clawtilla-chat-new)]]
  ["Look at"
   [("f" "files" cmacs-clawtilla-chat-files)
    ("P" "files sent here" cmacs-clawtilla-chat-gallery)
    ("o" "open the app on this line" cmacs-clawtilla-chat-open-app)
    ("m" "memory" cmacs-clawtilla-chat-memory)]
   [("t" "tasks" cmacs-clawtilla-chat-tasks)
    ("F" "flow" cmacs-clawtilla-chat-flow)]]
  ["Attachments and rooms"
   [("g" "open the attachment" cmacs-clawtilla-chat-attachment-get)
    ("D" "remove it" cmacs-clawtilla-chat-attachment-remove)]
   [("N" "make a room" cmacs-clawtilla-chat-room-create)
    ("E" "change this room" cmacs-clawtilla-chat-room-set)]])

(defvar cmacs-clawtilla-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-chat-toggle-step-run)
    (define-key map (kbd "RET") #'cmacs-clawtilla-chat-send)
    (define-key map (kbd "i") #'cmacs-clawtilla-chat-send)
    (define-key map (kbd "c") #'cmacs-clawtilla-chat-compose)
    (define-key map (kbd "a") #'cmacs-clawtilla-chat-attach)
    (define-key map (kbd "r") #'cmacs-clawtilla-chat-retry)
    (define-key map (kbd "C") #'cmacs-clawtilla-chat-copy-last)
    (define-key map (kbd "x") #'cmacs-clawtilla-chat-export)
    (define-key map (kbd "y") #'cmacs-clawtilla-chat-answer)
    (define-key map (kbd "u") #'cmacs-clawtilla-chat-rescue)
    (define-key map (kbd "z") #'cmacs-clawtilla-chat-toggle-mute)
    (define-key map (kbd "P") #'cmacs-clawtilla-chat-gallery)
    (define-key map (kbd "o") #'cmacs-clawtilla-chat-open-app)
    (define-key map (kbd "?") #'cmacs-clawtilla-chat-menu)
    map)
  "Keymap for `cmacs-clawtilla-chat-mode'.")

(define-derived-mode cmacs-clawtilla-chat-mode special-mode "Clawtilla-Chat"
  "Major mode for one clawtilla conversation."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-chat--load (current-buffer))))
  (setq-local cmacs-clawtilla-chat--seen nil)
  (setq-local cmacs-clawtilla-chat--drawn-steps 0)
  (visual-line-mode 1))

;;;###autoload
(defun cmacs-clawtilla-chat (conn &optional agent room)
  "Open the conversation with AGENT, or ROOM, on CONN."
  (interactive (list (cmacs-clawtilla-current) nil nil))
  (let* ((agent-id (cond ((stringp agent) agent)
                         ((consp agent) (alist-get 'id agent))))
         (room-id (cond ((stringp room) room)
                        ((consp room) (alist-get 'id room))
                        (t agent-id)))
         (buffer (get-buffer-create
                  (format "*clawtilla: %s*" (or agent-id room-id)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-chat-mode)
        (cmacs-clawtilla-chat-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-chat--agent agent-id)
      (setq-local cmacs-clawtilla-chat--room room-id)
      (cmacs-clawtilla-chat--load buffer))
    ;; Opening it is reading it, and saying so is what stops the count
    ;; being raised again while it is in front of you.  Only the local
    ;; count is cleared here: the daemon is told once the history has
    ;; been drawn (`cmacs-clawtilla-chat--read-upto'), up to the last
    ;; message actually on screen.
    (setq cmacs-clawtilla--viewing-room room-id)
    (remhash room-id cmacs-clawtilla-unread)
    (cmacs-clawtilla-display buffer)))

;;;###autoload
(defun cmacs-clawtilla-open (target &optional conn)
  "Open the conversation TARGET names on CONN.

TARGET is a `clawtilla://' link or what one carries: an agent, an agent
and a peer for the exchange between them, or a room.  What it leads to
is libclawt's answer (`clawt_open_target_resolve') against the fleet as
the daemon lists it, so a link pasted from another client opens the
same conversation here -- and one that names nothing in this fleet is
refused in the library's words rather than opening an empty buffer."
  (interactive "sOpen (a clawtilla:// link, an agent or a room): ")
  (let ((conn (or conn (cmacs-clawtilla-current)))
        (agents nil) (rooms nil) (pending 2))
    (cl-flet ((resolve ()
                (setq pending (1- pending))
                (when (zerop pending)
                  (let ((found (cmacs-clawtilla-ask-parsed
                                "open-target" :text target
                                :agents (cons :json (or agents "[]"))
                                :rooms (cons :json (or rooms "[]")))))
                    (cond
                     ((null found)
                      (message "clawtilla: this build cannot follow links"))
                     ((alist-get 'error found)
                      (message "clawtilla: %s" (alist-get 'error found)))
                     ((alist-get 'room found)
                      (cmacs-clawtilla-chat conn (alist-get 'agent found)
                                            (alist-get 'room found)))
                     ((alist-get 'agent found)
                      (cmacs-clawtilla-chat conn (alist-get 'agent found)))
                     (t (message "clawtilla: that names nothing here")))))))
      (cmacs-clawtilla-request-raw
       conn "agent.list" nil
       (lambda (json _err)
         (setq agents (and json (cmacs-clawtilla-member-json
                                 (cmacs-clawtilla-payload-text json) 'agents)))
         (resolve)))
      (cmacs-clawtilla-request-raw
       conn "room.list" nil
       (lambda (json _err)
         (setq rooms (and json (cmacs-clawtilla-member-json
                                (cmacs-clawtilla-payload-text json) 'rooms)))
         (resolve))))))

(defun cmacs-clawtilla-chat--note-turn (kind data)
  "Move this buffer's busy state for an event of KIND carrying DATA.

Tracked from events as well as asked for on reload, because a turn
starts and ends between reloads: a status line that only moved when
something else happened would say \"working\" after the answer had
arrived, which is worse than saying nothing."
  (cond
   ((member kind '("agent.typing" "turn.step" "turn.started"))
    (setq cmacs-clawtilla-chat--busy t)
    (setq cmacs-clawtilla-chat--peer
          (or (cmacs-clawtilla-event-detail data 'peer)
              cmacs-clawtilla-chat--peer)))
   ((member kind '("turn.finished" "turn.timed_out" "message.refused"))
    (setq cmacs-clawtilla-chat--busy nil)
    (setq cmacs-clawtilla-chat--peer nil))
   ((and (equal kind "message")
         ;; The agent answering ends its own turn.  Its own message is
         ;; the end of the turn; yours is the start of the next one.
         (not (equal (cmacs-clawtilla-event-detail data 'from) "user")))
    (setq cmacs-clawtilla-chat--busy nil)
    (setq cmacs-clawtilla-chat--peer nil))))

(defun cmacs-clawtilla-chat--on-event (conn kind data)
  "Append to any transcript for CONN that KIND in DATA concerns."
  ;; A decision asked, settled or deleted in a conversation, and a turn
  ;; that has gone quiet in one: both redraw only the tail, and both name
  ;; their conversation in `detail' rather than as the subject.
  (when (or (string-prefix-p "decision." kind)
            (string-prefix-p "turn.no_reply" kind))
    (let ((room (cmacs-clawtilla-event-detail data 'room))
          (subject (cmacs-clawtilla-event-subject data)))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'cmacs-clawtilla-chat-mode)
                     (eq cmacs-clawtilla-connection conn))
            (cond
             ((and (string-prefix-p "decision." kind)
                   (equal room cmacs-clawtilla-chat--room))
              (cmacs-clawtilla-chat--load-decisions buffer))
             ((and (string-prefix-p "turn.no_reply" kind)
                   (equal subject cmacs-clawtilla-chat--agent))
              (cmacs-clawtilla-chat--load-rescue buffer))))))))
  (when (string-match-p (rx bos (or "message" "turn." "agent.typing")) kind)
    (let ((subject (if (equal kind "turn.steered")
                       ;; A steer names its conversation in `detail'.
                       (or (cmacs-clawtilla-event-detail data 'room)
                           (cmacs-clawtilla-event-subject data))
                     (cmacs-clawtilla-event-subject data))))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'cmacs-clawtilla-chat-mode)
                     (eq cmacs-clawtilla-connection conn)
                     ;; Only the transcript this concerns.  Reloading
                     ;; every open one meant a message in one room
                     ;; refetched the history of all of them, which is a
                     ;; request per buffer per message and gets worse the
                     ;; more conversations somebody keeps open.
                     (or (null subject)
                         (equal subject cmacs-clawtilla-chat--room)
                         (equal subject cmacs-clawtilla-chat--agent)))
            (cmacs-clawtilla-chat--note-turn kind data)
            (cmacs-clawtilla-chat--load buffer)))))))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-chat--on-event)


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-chat-mode-map 'cmacs-clawtilla-chat-mode)

(provide 'cmacs-clawtilla-chat)

;;; cmacs-clawtilla-chat.el ends here
