;;; cmacs-clawtilla-pages.el --- The rest of the daemon, a page each -*- lexical-binding: t; -*-

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

;; The pages the GTK client keeps under Settings and in an agent's
;; inspector, each as a `cmacs-clawtilla-define-page':
;;
;;   fleet-wide   Spending (the ledger), Version history, Export &
;;                import, Orchestration, the integration broker, the
;;                egress allowlist, Issues (the sentinel's report);
;;   per agent    Memory review, Saved steps, Waits, the browser vault;
;;   per skill    Tests, and the changes agents have proposed.
;;
;; Every one is a list and a few verbs, which is why they share a file
;; and a buffer kind (cmacs-clawtilla-page.el) rather than having a mode
;; each.  What differs is what is asked of the daemon and what is said
;; about the answer -- and wherever libclawt says it, this asks: a
;; ledger row's subtitle and cost, the CSV and its file name, what a
;; journal entry's Undo is called, a wait's schedule, how old the
;; sentinel's scan is, the broker's state and which of Start, Stop and
;; Restart that state allows.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-clawtilla)
(require 'transient)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-page)
;; For the menu at the end, which reaches their pages too.
(require 'cmacs-clawtilla-tasks)
(require 'cmacs-clawtilla-devices)

(defun cmacs-clawtilla-pages--choose (prompt family &optional label-key)
  "Read one of libclawt's FAMILY with PROMPT and return its nick.

LABEL-KEY is which member of an entry is shown; `label' by default.  The
values are the library's, so a choice added there is offered here."
  (let* ((choices (mapcar (lambda (entry)
                            (cons (or (alist-get (or label-key 'label) entry)
                                      (alist-get 'nick entry))
                                  (alist-get 'nick entry)))
                          (cmacs-clawtilla-enum family)))
         (pick (completing-read prompt choices nil t)))
    (cdr (assoc pick choices))))


;;;; Spending: the ledger.

(defun cmacs-clawtilla-spending--payload ()
  "Return the `usage.ledger' payload for this page's period and grouping.

Built by libclawt (`clawt_usage_ledger_payload'), as every client's
Spending page asks it."
  (let* ((period (or (cmacs-clawtilla-page-state :period) 0))
         (group (or (cmacs-clawtilla-page-state :group)
                    (alist-get 'nick
                               (car (cmacs-clawtilla-enum "usage-group")))))
         (since (string-to-number
                 (or (cmacs-clawtilla-ask "period-since" :index period) "0"))))
    (cmacs-clawtilla--parse
     (cmacs-clawtilla-ask "ledger-payload" :since since :by group))))

(defun cmacs-clawtilla-spending--draw ()
  "Draw the Spending page from the ledger."
  (let* ((groups (cmacs-clawtilla-page-data 'ledger 'groups))
         (total (cmacs-clawtilla-page-data 'ledger 'total))
         (text (cmacs-clawtilla-page-text 'ledger))
         ;; Subtitles, costs and the unpriced line are the library's,
         ;; computed from the reply as the daemon sent it.
         (view (and text (cmacs-clawtilla-ask-parsed
                          "ledger-view" :reply (cons :json text))))
         (rows (alist-get 'groups view))
         (periods (cmacs-clawtilla-enum "usage-period"))
         (period (or (cmacs-clawtilla-page-state :period) 0)))
    (insert "  " (cmacs-clawtilla-dim
                  (format "%s, by %s"
                          (or (alist-get 'label (nth period periods)) "")
                          (or (cmacs-clawtilla-page-state :group)
                              (alist-get 'nick
                                         (car (cmacs-clawtilla-enum
                                               "usage-group"))))))
            "\n\n")
    (if (null groups)
        (cmacs-clawtilla-page-insert-note "Nothing recorded"
                                          "No turns in this period.")
      (dolist (group groups)
        (let ((row (pop rows)))
          (cmacs-clawtilla-page-insert-row
           'ledger-group group
           (format "%-28s %s" (or (alist-get 'key group) "?")
                   (propertize (or (alist-get 'cost row) "") 'face 'bold))
           (alist-get 'subtitle row)))))
    (insert "\n  "
            (propertize (format "%-28s %s" "Total"
                                (or (alist-get 'total_cost view) ""))
                        'face 'cmacs-clawtilla-heading)
            "\n      "
            (cmacs-clawtilla-dim
             (format "%d turns across the fleet"
                     (or (alist-get 'turns total) 0)))
            "\n")
    ;; Turns no price was known for: said, because a total that leaves
    ;; them out silently is a total that is wrong in the cheap direction.
    (when-let* ((unpriced (alist-get 'unpriced view)))
      (insert "\n  " (propertize unpriced 'face 'cmacs-clawtilla-busy) "\n"))))

(defun cmacs-clawtilla-spending-period ()
  "Choose the period the ledger covers, from libclawt's periods."
  (interactive)
  (cmacs-clawtilla-page-set-state
   :period (string-to-number
            (cmacs-clawtilla-pages--choose "Period: " "usage-period")))
  (cmacs-clawtilla-page-load))

(defun cmacs-clawtilla-spending-group ()
  "Choose what the ledger is grouped by, from libclawt's groupings."
  (interactive)
  (cmacs-clawtilla-page-set-state
   :group (cmacs-clawtilla-pages--choose "Group by: " "usage-group"))
  (cmacs-clawtilla-page-load))

(defun cmacs-clawtilla-spending-export (file)
  "Save the table on screen to FILE as a spreadsheet-safe CSV.

Both the rows and the suggested name are libclawt's
\(`clawt_usage_ledger_csv', `_csv_name'), so the file is the one the
GTK client's Export writes."
  (interactive
   (let* ((text (or (cmacs-clawtilla-page-text 'ledger)
                    (user-error "Nothing to export yet")))
          (name (alist-get 'csv_name
                           (cmacs-clawtilla-ask-parsed
                            "ledger-view" :reply (cons :json text)))))
     (list (read-file-name "Export spending to: " nil nil nil
                           (or name "spending.csv")))))
  (let ((csv (cmacs-clawtilla-ask
              "ledger-csv"
              :reply (cons :json (cmacs-clawtilla-page-text 'ledger)))))
    (unless csv (user-error "Nothing to export yet"))
    (with-temp-file file (insert csv))
    (message "clawtilla: spending exported to %s" file)))

(cmacs-clawtilla-define-page "spending"
  :title "Spending"
  :intro "What the fleet has cost: the figure each provider reported for each turn.  Token counts cover new input and output only -- cached context is billed but is not reported as tokens, so the cost is larger than the tokens beside it suggest.  Origin says what started the work: you, another agent, a routine or a trigger."
  :fetch (list (list 'ledger "usage.ledger" #'cmacs-clawtilla-spending--payload))
  :draw #'cmacs-clawtilla-spending--draw
  :events "\\`\\(spending\\.\\|turn\\.finished\\)"
  :verbs '(("p" "period" cmacs-clawtilla-spending-period)
           ("o" "group by" cmacs-clawtilla-spending-group)
           ("x" "export CSV" cmacs-clawtilla-spending-export)))

;;;###autoload
(defun cmacs-clawtilla-spending (&optional conn)
  "Show what the fleet on CONN has cost, from the daemon's ledger."
  (interactive)
  (cmacs-clawtilla-page-open "spending" conn))


;;;; Version history.

(defun cmacs-clawtilla-history--draw ()
  "Draw the Version history page."
  (let ((revisions (cmacs-clawtilla-page-data 'revisions 'revisions)))
    (if (null revisions)
        (cmacs-clawtilla-page-insert-note "No versions kept yet")
      (dolist (revision revisions)
        (cmacs-clawtilla-page-insert-row
         'revision
         ;; The id as text under `name', which is what a row's identity
         ;; is built from: an integer id would not keep point in place.
         (cons (cons 'name (format "%s" (alist-get 'id revision))) revision)
         (format "%s %s" (or (alist-get 'kind revision) "")
                 (or (alist-get 'subject revision) ""))
         (format "%s, by %s%s"
                 (format-time-string
                  "%F %R" (seconds-to-time (or (alist-get 'at revision) 0)))
                 (or (alist-get 'author revision) "clawtilla")
                 (if (alist-get 'note revision)
                     (concat " -- " (alist-get 'note revision))
                   "")))))))

(defun cmacs-clawtilla-history-diff ()
  "Show what has changed since the version at point."
  (interactive)
  (let ((id (alist-get 'name (cmacs-clawtilla-page-row 'revision))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "revision.diff" (list (cons 'from id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (cmacs-clawtilla-page-show-text
          (format "*clawtilla revision: %s*" id)
          (or (cmacs-clawtilla-get data 'diff) "") 'diff-mode))))))

(defun cmacs-clawtilla-history-restore ()
  "Put the version at point back.

Which is a save of its own -- the restored version becomes the newest --
so nothing is lost by trying."
  (interactive)
  (let ((id (alist-get 'name (cmacs-clawtilla-page-row 'revision))))
    (when (yes-or-no-p (format "Restore revision %s?  It becomes the newest version. "
                               id))
      (cmacs-clawtilla-page-send
       "revision.restore" (list (cons 'id id))
       (format "revision %s restored; it is the newest version now" id)))))

(cmacs-clawtilla-define-page "history"
  :title "Version history"
  :intro "Every version kept: the config, each agent's persona files and every skill, as they were each time they changed.  Open one to see what has changed since, and to put it back -- which is a save of its own, so nothing is lost by trying."
  :fetch '((revisions "revision.list" ((limit . "100"))))
  :draw #'cmacs-clawtilla-history--draw
  :verbs '(("RET" "what changed since" cmacs-clawtilla-history-diff)
           ("R" "restore this version" cmacs-clawtilla-history-restore)))

;;;###autoload
(defun cmacs-clawtilla-history (&optional conn)
  "Show every version of the config, personas and skills CONN's daemon kept."
  (interactive)
  (cmacs-clawtilla-page-open "history" conn))


;;;; Export & import: a fleet as a directory.

(defun cmacs-clawtilla-pack--draw ()
  "Draw the Export & import page."
  (let ((directory (cmacs-clawtilla-page-state :directory))
        (preview (cmacs-clawtilla-page-state :preview)))
    (cmacs-clawtilla-settings-like-row
     "Directory" (or directory "not chosen -- d sets it"))
    (cmacs-clawtilla-settings-like-row
     "On import" (or (cmacs-clawtilla-page-state :resolutions)
                     "skip whatever already exists"))
    (cmacs-clawtilla-settings-like-row
     "Dangerous settings"
     (if (cmacs-clawtilla-page-state :dangerous) "allowed in" "kept out"))
    (when preview
      (insert "\n  " (propertize "What an import would do"
                                 'face 'cmacs-clawtilla-team)
              "\n")
      (dolist (item (alist-get 'items preview))
        (insert "    "
                (format "%s %s: " (or (alist-get 'kind item) "")
                        (or (alist-get 'id item) ""))
                (if (eq t (alist-get 'exists item))
                    (cmacs-clawtilla-dim
                     "exists, skipped unless replaced or renamed")
                  "new")
                (if (alist-get 'dangerous item)
                    (propertize " -- turns on a dangerous setting"
                                'face 'cmacs-clawtilla-error)
                  "")
                "\n"))
      (when-let* ((to-fill (alist-get 'to_fill preview)))
        (insert "\n    " (cmacs-clawtilla-dim "To fill in afterwards:") "\n")
        (dolist (line to-fill)
          (insert "      " line "\n"))))))

(defun cmacs-clawtilla-settings-like-row (label value)
  "Insert LABEL and VALUE as one aligned line."
  (insert (format "  %-20s " label) (format "%s" value) "\n"))

(defun cmacs-clawtilla-pack--directory ()
  "Return this page's directory, or signal."
  (or (cmacs-clawtilla-page-state :directory)
      (user-error "Choose a directory first (d)")))

(defun cmacs-clawtilla-pack-set-directory (directory)
  "Set the DIRECTORY a pack is written to and read from.

An absolute path on the DAEMON's machine, which is not necessarily this
one -- so it is typed, not chosen from this machine's files."
  (interactive "sDirectory (absolute path on the daemon's machine): ")
  (cmacs-clawtilla-page-set-state :directory (and (not (string-empty-p
                                                        directory))
                                                  directory))
  (cmacs-clawtilla-page-set-state :preview nil)
  (cmacs-clawtilla-page--draw))

(defun cmacs-clawtilla-pack-set-resolutions (resolutions)
  "Set what an import does about items that already exist, as RESOLUTIONS.

A comma-separated list such as agent:scout=rename:scout2, team:crew=replace.
Empty skips whatever exists.  The actions are libclawt's (the
\"resolution\" family)."
  (interactive
   (list (read-string
          (format "On import (%s; e.g. agent:scout=rename:scout2): "
                  (string-join (cmacs-clawtilla-enum-nicks "resolution")
                               ", ")))))
  (cmacs-clawtilla-page-set-state :resolutions (and (not (string-empty-p
                                                          resolutions))
                                                    resolutions))
  (cmacs-clawtilla-page--draw))

(defun cmacs-clawtilla-pack-toggle-dangerous ()
  "Allow, or stop allowing, items that turn on a dangerous setting."
  (interactive)
  (cmacs-clawtilla-page-set-state
   :dangerous (not (cmacs-clawtilla-page-state :dangerous)))
  (cmacs-clawtilla-page--draw))

(defun cmacs-clawtilla-pack-export ()
  "Write the fleet to this page's directory.

The agents, teams, routines, triggers, projects, persona files and
skills -- never a secret or the daemon machine's paths."
  (interactive)
  (cmacs-clawtilla-page-send
   "fleet.export" (list (cons 'dir (cmacs-clawtilla-pack--directory)))
   (lambda (data)
     (format "exported: %d agents, %d skills"
             (or (cmacs-clawtilla-get data 'agents) 0)
             (or (cmacs-clawtilla-get data 'skills) 0)))))

(defun cmacs-clawtilla-pack-preview ()
  "Show what importing this page's directory would do, without doing it."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "fleet.import_preview"
     (list (cons 'dir (cmacs-clawtilla-pack--directory)))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (cmacs-clawtilla-page-set-state :preview data)
             (cmacs-clawtilla-page--draw))))))))

(defun cmacs-clawtilla-pack-import ()
  "Import this page's directory.

Agents arrive held and skills disabled until you start and read them;
what exists is skipped unless the resolutions say replace or rename;
and nothing that turns on a dangerous setting comes in unless allowed."
  (interactive)
  (let ((directory (cmacs-clawtilla-pack--directory)))
    (when (yes-or-no-p (format "Import the fleet pack in %s? " directory))
      (cmacs-clawtilla-page-send
       "fleet.import"
       (cmacs-clawtilla-payload
        :dir directory
        :resolutions (cmacs-clawtilla-page-state :resolutions)
        :allow_dangerous (and (cmacs-clawtilla-page-state :dangerous) "true"))
       "imported; agents are held and skills disabled until you start and read them"))))

(cmacs-clawtilla-define-page "pack"
  :title "Export & import"
  :intro "A fleet as a directory.  Export writes the agents, teams, routines, triggers, projects, persona files and skills -- never a secret or this machine's paths.  Import shows what it would do first; what exists is skipped unless you say replace or rename, agents arrive held, skills disabled, and nothing that turns on a dangerous setting comes in unless you allow it."
  :draw #'cmacs-clawtilla-pack--draw
  :verbs '(("d" "choose the directory" cmacs-clawtilla-pack-set-directory)
           ("x" "export" cmacs-clawtilla-pack-export)
           ("p" "preview an import" cmacs-clawtilla-pack-preview)
           ("i" "import" cmacs-clawtilla-pack-import)
           ("r" "what to do with what exists"
            cmacs-clawtilla-pack-set-resolutions)
           ("!" "allow dangerous settings"
            cmacs-clawtilla-pack-toggle-dangerous)))

;;;###autoload
(defun cmacs-clawtilla-pack (&optional conn)
  "Export CONN's fleet to a directory, or import one."
  (interactive)
  (cmacs-clawtilla-page-open "pack" conn))


;;;; Orchestration.

(defun cmacs-clawtilla-orchestration--model-label (value)
  "Return libclawt's label for the acknowledgement-check model VALUE."
  (or (alist-get 'label
                 (seq-find (lambda (entry) (equal (alist-get 'nick entry) value))
                           (cmacs-clawtilla-enum "ack-check-model")))
      ;; A model set by hand in the config is still a model: the library
      ;; words one it does not list too.
      (cmacs-clawtilla-ask "ack-model-label" :value value)
      value))

(defun cmacs-clawtilla-orchestration--draw ()
  "Draw the Orchestration page."
  (let ((model (or (cmacs-clawtilla-page-data 'orchestration 'ack_check_model)
                   ""))
        (budget (or (cmacs-clawtilla-page-data 'orchestration
                                               'tree_message_budget)
                    0))
        (rooms (cmacs-clawtilla-page-data 'orchestration 'rooms)))
    (insert "  " (propertize "Acknowledgement check" 'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "m chooses the model") "\n    "
            (cmacs-clawtilla-orchestration--model-label model) "\n")
    (cmacs-clawtilla-page--insert-filled
     "When one agent answers another with only an acknowledgement, waking the agent that asked costs it a whole turn.  With a model chosen here a short answer from a turn that did nothing else is put to that model first: only a plain ACK skips the wake, and anything else, a failure, or no verdict within 8 seconds wakes the sender as before."
     "    ")
    (insert "\n  "
            (propertize "Message budget per task tree" 'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "u changes it") "\n    "
            (if (> budget 0)
                (format "%d requests between settlements" budget)
              "no budget")
            "\n")
    (cmacs-clawtilla-page--insert-filled
     "A task tree is a delegated task and everything handed on from it.  This counts the messages agents in one tree send each other and starts again whenever any task in the tree finishes.  At the limit they can still answer and finish their own work, but are not offered the tools to message each other, and you get one alert naming the tree.  0 turns it off."
     "    ")
    (insert "\n  " (propertize "Rounds in group rooms" 'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "RET changes a room's cap") "\n")
    (if (null rooms)
        (insert "    " (cmacs-clawtilla-dim
                        "No group rooms yet.  A room with three or more members appears here.")
                "\n")
      (dolist (room rooms)
        (let ((round (or (alist-get 'round room) 0))
              (cap (or (alist-get 'max_chain room) 0)))
          (cmacs-clawtilla-insert-section
           :type 'round-room :value room :level 2
           :heading (concat
                     (or (alist-get 'name room) (alist-get 'id room) "?")
                     "  "
                     (cmacs-clawtilla-dim
                      (concat (if (> cap 0)
                                  (format "%d repl%s per thread" cap
                                          (if (= cap 1) "y" "ies"))
                                "no cap")
                              (if (> round 0)
                                  (format " · round %d now" round)
                                ""))))))))))

(defun cmacs-clawtilla-orchestration-set-model ()
  "Choose the acknowledgement-check model, from libclawt's list.

A small, fast model reached over HTTP; its key is configured as for AI
assist.  The first choice is off."
  (interactive)
  (let ((value (cmacs-clawtilla-pages--choose "Acknowledgement check: "
                                              "ack-check-model")))
    (cmacs-clawtilla-page-send
     "orchestration.set" (list (cons 'ack_check_model value))
     (if (string-empty-p value) "acknowledgement check off"
       "acknowledgement check saved"))))

(defun cmacs-clawtilla-orchestration-set-budget (budget)
  "Set the message BUDGET per task tree; 0 is no budget."
  (interactive "nRequests between settlements (0: no budget): ")
  (unless (and (integerp budget) (<= 0 budget 10000))
    (user-error "The tree budget is a whole number from 0 (no budget) to 10000"))
  (cmacs-clawtilla-page-send
   ;; An integer, which is how the daemon reads it.
   "orchestration.set" (list (cons 'tree_message_budget budget))
   (if (zerop budget)
       "task trees have no message budget now"
     (format "each task tree may send %d requests between settlements"
             budget))))

(defun cmacs-clawtilla-orchestration-set-cap (cap)
  "Set how many replies a thread in the room at point may have, to CAP.

Within one thread a member answers once; a thread stops after this many
replies.  0 removes the cap."
  (interactive "nReplies per thread (0: no cap): ")
  (let* ((room (cmacs-clawtilla-page-row 'round-room))
         (id (alist-get 'id room)))
    (unless (and (integerp cap) (<= 0 cap 100))
      (user-error "Replies per thread is a whole number from 0 (no cap) to 100"))
    (cmacs-clawtilla-page-send
     "room.set" (list (cons 'room id) (cons 'max_chain cap))
     (if (zerop cap)
         (format "threads in %s are no longer capped; each member still answers once per thread"
                 id)
       (format "a thread in %s now stops after %d repl%s" id cap
               (if (= cap 1) "y" "ies"))))))

(cmacs-clawtilla-define-page "orchestration"
  :title "Orchestration"
  :fetch '((orchestration "orchestration.get"))
  :draw #'cmacs-clawtilla-orchestration--draw
  :verbs '(("m" "acknowledgement-check model"
            cmacs-clawtilla-orchestration-set-model)
           ("u" "message budget per task tree"
            cmacs-clawtilla-orchestration-set-budget)
           ("RET" "replies per thread in this room"
            cmacs-clawtilla-orchestration-set-cap)))

;;;###autoload
(defun cmacs-clawtilla-orchestration (&optional conn)
  "Show how CONN's fleet coordinates: acknowledgements, budgets and rounds."
  (interactive)
  (cmacs-clawtilla-page-open "orchestration" conn))


;;;; The integration broker, and connector thresholds.

(defun cmacs-clawtilla-broker--state ()
  "Return what libclawt says about the broker's state on this page."
  (cmacs-clawtilla-ask-parsed
   "broker-state"
   :state (cmacs-clawtilla-page-data 'broker 'state)
   :enabled (if (eq t (cmacs-clawtilla-page-data 'broker 'enabled))
                t :false)))

(defun cmacs-clawtilla-broker--draw ()
  "Draw the broker page: the gateway, and how connectors are offered."
  (let* ((state (cmacs-clawtilla-broker--state))
         (enabled (eq t (cmacs-clawtilla-page-data 'broker 'enabled)))
         (detail (cmacs-clawtilla-page-data 'broker 'detail))
         (url (cmacs-clawtilla-page-data 'broker 'dashboard_url)))
    (insert "  "
            (propertize (or (cmacs-clawtilla-page-data 'broker 'label)
                            "Integration broker")
                        'face 'cmacs-clawtilla-team)
            " — "
            (propertize (or (alist-get 'label state) "")
                        'face (if (eq t (alist-get 'running state))
                                  'cmacs-clawtilla-running
                                'cmacs-clawtilla-stopped))
            "\n    "
            (cmacs-clawtilla-dim
             (cond
              ((not enabled)
               "Off.  Set broker.enabled to run it; clawtilla then pulls its image and starts it with the daemon.")
              ((cmacs-clawtilla-page-data 'broker 'refusal))
              (detail (format "%s\n    Dashboard: %s" detail (or url "?")))
              (t (format "Dashboard: %s" (or url "?")))))
            "\n    "
            (cmacs-clawtilla-dim
             (string-join
              (delq nil
                    (list (and (eq t (alist-get 'start state)) "s starts it")
                          (and (eq t (alist-get 'stop state)) "S stops it")
                          (and (eq t (alist-get 'restart state))
                               "R restarts it")
                          (and (eq t (alist-get 'running state)) url
                               "o opens its dashboard")))
              " · "))
            "\n\n")
    (insert "  " (propertize "How connectors are offered"
                             'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "c changes these") "\n")
    (cmacs-clawtilla-settings-like-row
     "  Directory at"
     (format "%s tools or %s characters of descriptions"
             (or (cmacs-clawtilla-page-data 'connectors 'directory_min_tools)
                 40)
             (or (cmacs-clawtilla-page-data 'connectors 'directory_min_chars)
                 100000)))
    (when-let* ((bytes (cmacs-clawtilla-page-data 'connectors
                                                  'max_result_bytes)))
      (cmacs-clawtilla-settings-like-row
       "  Largest tool result" (file-size-human-readable bytes)))
    (insert "\n  " (propertize "Connected accounts" 'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "d asks one what it publishes") "\n")
    (let ((connectors (cmacs-clawtilla-page-data 'connectors 'connectors)))
      (if (null connectors)
          (insert "    " (cmacs-clawtilla-dim
                          "No connected accounts.  Settings' Connectors panel connects one.")
                  "\n")
        (dolist (connector connectors)
          (cmacs-clawtilla-insert-section
           :type 'connector :value connector :level 2
           :heading
           ;; Never a token, never a scope that might hold one: the
           ;; credential stays in the daemon and the agents get tools.
           (format "%-20s %-12s %s"
                   (or (alist-get 'name connector) "?")
                   (if (eq t (alist-get 'connected connector))
                       (propertize "connected" 'face 'cmacs-clawtilla-running)
                     (propertize "not connected"
                                 'face 'cmacs-clawtilla-stopped))
                   (cmacs-clawtilla-dim
                    (or (alist-get 'account connector)
                        (alist-get 'provider connector) "")))))))))

(defun cmacs-clawtilla-broker--act (kind allowed verb)
  "Send the broker frame KIND if the state allows ALLOWED; VERB names it."
  (unless (eq t (alist-get allowed (cmacs-clawtilla-broker--state)))
    (user-error "The broker cannot %s from the state it is in" verb))
  (cmacs-clawtilla-page-send kind nil (format "asked the broker to %s" verb)))

(defun cmacs-clawtilla-broker-start ()
  "Start the integration broker."
  (interactive)
  (cmacs-clawtilla-broker--act "broker.start" 'start "start"))

(defun cmacs-clawtilla-broker-stop ()
  "Stop the integration broker."
  (interactive)
  (cmacs-clawtilla-broker--act "broker.stop" 'stop "stop"))

(defun cmacs-clawtilla-broker-restart ()
  "Restart the integration broker."
  (interactive)
  (cmacs-clawtilla-broker--act "broker.restart" 'restart "restart"))

(defun cmacs-clawtilla-broker-dashboard ()
  "Open the broker's dashboard, which holds the SaaS sign-ins."
  (interactive)
  (browse-url (or (cmacs-clawtilla-page-data 'broker 'dashboard_url)
                  (user-error "The broker has no dashboard to open"))))

(defun cmacs-clawtilla-broker-thresholds (tools chars bytes)
  "Set when an agent is given a directory of tools instead of every tool.

At TOOLS tools or CHARS characters of tool descriptions an agent gets a
directory to search rather than the full list.  BYTES caps one tool
result."
  (interactive
   (list (read-number
          "Directory at this many tools: "
          (or (cmacs-clawtilla-page-data 'connectors 'directory_min_tools) 40))
         (read-number
          "...or this many characters of descriptions: "
          (or (cmacs-clawtilla-page-data 'connectors 'directory_min_chars)
              100000))
         (read-number
          "Largest tool result, in bytes: "
          (or (cmacs-clawtilla-page-data 'connectors 'max_result_bytes) 0))))
  (cmacs-clawtilla-page-send
   "connector.settings"
   ;; Integers all three, which is how the daemon reads them.
   (append (list (cons 'directory_min_tools (truncate tools))
                 (cons 'directory_min_chars (truncate chars)))
           (and (> bytes 0) (list (cons 'max_result_bytes (truncate bytes)))))
   "saved"))

(defun cmacs-clawtilla-broker-discover ()
  "Ask the connector at point what it publishes: whether it offers a sign-in."
  (interactive)
  (let ((name (alist-get 'name (cmacs-clawtilla-page-row 'connector))))
    (cmacs-clawtilla-page-send
     "connector.discover" (list (cons 'name name))
     (lambda (data)
       (if (eq t (cmacs-clawtilla-get data 'sign_in))
           (format "%s publishes a sign-in; connect it from Settings' Connectors panel"
                   name)
         (format "%s publishes no sign-in; open it to paste a token" name))))))

(cmacs-clawtilla-define-page "broker"
  :title "Integration broker"
  :intro "App integrations behind one gateway clawtilla runs in podman.  Its dashboard holds the SaaS sign-ins; each agent or team names its gateway server in broker_server and reaches it as a connector."
  :fetch '((broker "broker.status") (connectors "connector.list"))
  :draw #'cmacs-clawtilla-broker--draw
  :events "\\`\\(broker\\|connector\\)\\."
  :verbs '(("s" "start" cmacs-clawtilla-broker-start)
           ("S" "stop" cmacs-clawtilla-broker-stop)
           ("R" "restart" cmacs-clawtilla-broker-restart)
           ("o" "open its dashboard" cmacs-clawtilla-broker-dashboard)
           ("c" "directory thresholds" cmacs-clawtilla-broker-thresholds)
           ("d" "discover what a connector publishes"
            cmacs-clawtilla-broker-discover)))

;;;###autoload
(defun cmacs-clawtilla-broker (&optional conn)
  "Show CONN's integration broker and how connectors are offered."
  (interactive)
  (cmacs-clawtilla-page-open "broker" conn))

(defun cmacs-clawtilla-open-app (agent app &optional conn)
  "Open the MCP app APP that AGENT's connector showed, in a browser.

A tool call may come with an app -- a page the connector serves for
what it just did.  The daemon resolves it (`connector.app_get') because
the link is the connector's and may be signed for one use."
  (interactive
   (list (cmacs-clawtilla-read-agent "Agent: ") (read-string "App id: ")))
  (cmacs-clawtilla-request
   (or conn (cmacs-clawtilla-current)) "connector.app_get"
   (list (cons 'agent agent) (cons 'app app))
   (lambda (data err)
     (let ((url (cmacs-clawtilla-get data 'url)))
       (cond (err (message "clawtilla: %s" err))
             ((stringp url) (browse-url url))
             (t (message "clawtilla: that app has no page to open")))))))


;;;; The egress allowlist.

(defun cmacs-clawtilla-egress--draw ()
  "Draw the egress allowlist."
  (let ((entries (cmacs-clawtilla-page-data 'egress 'entries)))
    (if (null entries)
        (cmacs-clawtilla-page-insert-note
         "Public internet only"
         "Gated agents reach no private address: not this machine, your LAN or your tailnet.")
      (dolist (entry entries)
        (cmacs-clawtilla-insert-section
         :type 'egress-entry :value entry :level 1 :heading entry)))
    (when-let* ((problem (cmacs-clawtilla-page-data 'egress 'problem)))
      (insert "\n  " (propertize "Worth fixing" 'face 'cmacs-clawtilla-error)
              "\n    " problem "\n"))))

(defun cmacs-clawtilla-egress-add (entry)
  "Let gated agents reach ENTRY, a private address or range."
  (interactive "sAllow (an address, a host or a range): ")
  (when (string-empty-p entry) (user-error "Allow what?"))
  (cmacs-clawtilla-page-send "egress.allow.add" (list (cons 'entry entry))))

(defun cmacs-clawtilla-egress-remove ()
  "Stop letting gated agents reach the entry at point."
  (interactive)
  (let ((entry (cmacs-clawtilla-page-row 'egress-entry)))
    (when (yes-or-no-p (format "Stop allowing %s? " entry))
      (cmacs-clawtilla-page-send "egress.allow.remove"
                                 (list (cons 'entry entry))))))

(cmacs-clawtilla-define-page "egress"
  ;; Both the name of this list and what it is for are libclawt's,
  ;; shared with the agent page's network choice.
  :title (lambda ()
           (or (cmacs-clawtilla-label 'egress_allowlist)
               "Private addresses agents may reach"))
  :intro (lambda ()
           (or (cmacs-clawtilla-label 'egress_allowlist_explanation) ""))
  :fetch '((egress "egress.allow.list"))
  :draw #'cmacs-clawtilla-egress--draw
  :verbs '(("i" "allow an address" cmacs-clawtilla-egress-add)
           ("D" "stop allowing it" cmacs-clawtilla-egress-remove)))

;;;###autoload
(defun cmacs-clawtilla-egress (&optional conn)
  "Show the private addresses CONN's gated agents may reach."
  (interactive)
  (cmacs-clawtilla-page-open "egress" conn))


;;;; Issues: the sentinel's report.

(defun cmacs-clawtilla-issues--draw ()
  "Draw the Issues page from the sentinel's last report."
  (let* ((report (cmacs-clawtilla-page-data 'report 'report))
         (header (alist-get 'sentinel report))
         (issues (alist-get 'issues report))
         (error (cmacs-clawtilla-page-data 'report 'error)))
    ;; How old the scan is, in the library's words -- "never" included.
    (insert "  " (cmacs-clawtilla-dim
                  (concat (or (cmacs-clawtilla-ask
                               "sentinel-age"
                               :scanned_at (or (alist-get 'scanned_at header)
                                               0))
                              "")
                          (if (eq t (cmacs-clawtilla-page-data 'report
                                                               'running))
                              " · scanning now…" "")))
            "\n\n")
    (when error
      (cmacs-clawtilla-page-insert-note "The last scan failed" error))
    (cond
     ((null report)
      (cmacs-clawtilla-page-insert-note
       "Not scanned yet"
       "s reads the event log -- without changing it -- and groups failing tools, slow queues, spending and stalled turns into issues."))
     ((null issues)
      (cmacs-clawtilla-page-insert-note
       "No issues"
       (format "%d events in %d day files, nothing recurring."
               (or (alist-get 'events header) 0)
               (or (alist-get 'files header) 0))))
     (t
      (dolist (issue issues)
        (let ((sample (or (alist-get 'sample issue) ""))
              (bad (equal (alist-get 'severity issue) "bad")))
          (cmacs-clawtilla-page-insert-row
           'issue
           (cons (cons 'name (or (alist-get 'title issue) "")) issue)
           (concat
            (propertize (format "%-12s "
                                (or (cmacs-clawtilla-ask
                                     "sentinel-kind"
                                     :kind (or (alist-get 'kind issue) ""))
                                    (alist-get 'kind issue) ""))
                        'face (if bad 'cmacs-clawtilla-error
                                'cmacs-clawtilla-busy))
            (or (alist-get 'title issue) "?"))
           (concat "last "
                   (or (cmacs-clawtilla-time-ago (alist-get 'last_at issue))
                       "?")
                   (if (string-empty-p sample) "" (concat " · " sample))))))))))

(defun cmacs-clawtilla-issues-scan ()
  "Have the sentinel scan the event log now.

The log itself is never changed.  The list updates when the scan
finishes, which the daemon announces."
  (interactive)
  (cmacs-clawtilla-page-send
   "sentinel.scan" nil
   (lambda (data)
     (if (eq t (cmacs-clawtilla-get data 'started))
         "scanning the event log; the list updates when it finishes"
       "a scan is already running"))))

(cmacs-clawtilla-define-page "issues"
  :title "Issues"
  :intro "What the sentinel found by reading the event log for recurring trouble: failing tools, slow queues, spending, stalled turns.  The log itself is never changed."
  :fetch '((report "sentinel.report"))
  :draw #'cmacs-clawtilla-issues--draw
  :events "\\`sentinel\\."
  :verbs '(("s" "scan now" cmacs-clawtilla-issues-scan)))

;;;###autoload
(defun cmacs-clawtilla-issues (&optional conn)
  "Show what the sentinel found in CONN's event log."
  (interactive)
  (cmacs-clawtilla-page-open "issues" conn))


;;;; Memory review, per agent.

(defun cmacs-clawtilla-review--draw ()
  "Draw an agent's memory review: suggestions, then its journal."
  (let* ((proposals (cmacs-clawtilla-page-data 'proposals 'proposals))
         (entries (cmacs-clawtilla-page-data 'journal 'entries))
         (model (or (cmacs-clawtilla-page-data 'proposals 'model) ""))
         (last (or (cmacs-clawtilla-page-data 'proposals 'last_run_at) 0))
         (error (cmacs-clawtilla-page-data 'proposals 'last_error)))
    (insert "  " (propertize "Suggested by the review" 'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "m model · r review now") "\n    "
            (cmacs-clawtilla-dim
             (format "%s · %s"
                     (cmacs-clawtilla-orchestration--model-label model)
                     (cond
                      ((eq t (cmacs-clawtilla-page-data 'proposals 'running))
                       "A pass is running now.")
                      (error (format "The last pass proposed nothing: %s"
                                     error))
                      ((> last 0)
                       (format "Last reviewed %s."
                               (or (cmacs-clawtilla-time-ago last) "?")))
                      (t "Not reviewed yet."))))
            "\n")
    (dolist (proposal proposals)
      (cmacs-clawtilla-insert-section
       :type 'memory-proposal :value proposal :level 2
       :heading (concat (or (alist-get 'line proposal) "A change")
                        "  " (cmacs-clawtilla-dim "a accepts, x rejects"))
       :body (lambda ()
               (when-let* ((reason (alist-get 'reason proposal)))
                 (insert "        " (cmacs-clawtilla-dim
                                     (format "Why: %s" reason))
                         "\n"))
               (when-let* ((content (alist-get 'content proposal)))
                 (insert "        " (cmacs-clawtilla-dim
                                     (format "Into: %s" content))
                         "\n"))
               (dolist (memory (alist-get 'memories proposal))
                 (insert "        "
                         (cmacs-clawtilla-dim
                          (format "%s: %s" (or (alist-get 'id memory) "?")
                                  (or (alist-get 'excerpt memory)
                                      "(gone since)")))
                         "\n")))))
    (insert "\n  " (propertize "Memory review" 'face 'cmacs-clawtilla-team)
            "  " (cmacs-clawtilla-dim "u takes the change at point back")
            "\n")
    (if (null entries)
        (insert "    "
                (cmacs-clawtilla-dim
                 (if (cmacs-clawtilla-page-error 'journal)
                     "This agent has no memory store, or the daemon could not read its journal."
                   "Each time this agent remembers, forgets or pins something it shows here, with a way to take it back."))
                "\n")
      (dolist (entry entries)
        (let* ((action (or (alist-get 'action entry) ""))
               (scope (or (alist-get 'scope entry) "agent"))
               (labels (cmacs-clawtilla-ask-parsed "journal-labels"
                                                   :action action)))
          (cmacs-clawtilla-insert-section
           :type 'memory-entry
           :value (cons (cons 'name (format "%s/%s" scope
                                            (alist-get 'id entry)))
                        entry)
           :level 2
           :heading
           (concat (format "%s: %s" (or (alist-get 'action labels) action)
                           (or (alist-get 'excerpt entry)
                               (alist-get 'memory_id entry) "?"))
                   (if (eq t (alist-get 'undoable entry))
                       (concat "  " (cmacs-clawtilla-dim
                                     (format "u: %s"
                                             (or (alist-get 'undo labels)
                                                 "undo"))))
                     ""))
           :body (lambda ()
                   (insert "        "
                           (cmacs-clawtilla-dim
                            (concat
                             (or (alist-get 'line entry) "") " · "
                             (or (cmacs-clawtilla-time-ago (alist-get 'at entry))
                                 "")
                             (if (equal scope "agent") ""
                               (format " · in the %s's memories" scope))))
                           "\n")
                   ;; Why a change that looks undoable is not: said, on
                   ;; the row, rather than left as a key that refuses.
                   (when-let* ((why (and (not (eq t (alist-get 'undoable
                                                               entry)))
                                         (not (equal action "undo"))
                                         (eql 0 (or (alist-get 'undone_at entry)
                                                    0))
                                         (alist-get 'why_not entry))))
                     (insert "        " (cmacs-clawtilla-dim why) "\n")))))))))

(defun cmacs-clawtilla-review-undo ()
  "Take the memory change at point back.

An added memory is archived, a forgotten one returns, a pin flips
back.  Nothing is deleted."
  (interactive)
  (let ((entry (cmacs-clawtilla-page-row 'memory-entry)))
    (unless (eq t (alist-get 'undoable entry))
      (user-error "%s" (or (alist-get 'why_not entry)
                           "That change cannot be taken back")))
    (cmacs-clawtilla-page-send
     "memory.undo"
     (list (cons 'agent (cmacs-clawtilla-page-need-agent))
           (cons 'scope (or (alist-get 'scope entry) "agent"))
           ;; An integer, which is what the journal's ids are.
           (cons 'id (alist-get 'id entry)))
     "undone; the agent reads its memories as they are now from its next search")))

(defun cmacs-clawtilla-review--resolve (kind said)
  "Send KIND for the suggestion at point and say SAID."
  (cmacs-clawtilla-page-send
   kind
   (list (cons 'agent (cmacs-clawtilla-page-need-agent))
         (cons 'id (alist-get 'id (cmacs-clawtilla-page-row
                                   'memory-proposal))))
   said))

(defun cmacs-clawtilla-review-accept ()
  "Accept the suggestion at point.  It then appears in the journal, with an Undo."
  (interactive)
  (cmacs-clawtilla-review--resolve
   "memory.proposal_accept" "accepted; it is in the memory review with an undo"))

(defun cmacs-clawtilla-review-reject ()
  "Reject the suggestion at point.  Nothing is changed."
  (interactive)
  (cmacs-clawtilla-review--resolve
   "memory.proposal_reject" "rejected; nothing was changed"))

(defun cmacs-clawtilla-review-now ()
  "Have the review model read this agent's memories now."
  (interactive)
  (cmacs-clawtilla-page-send
   "memory.review" (list (cons 'agent (cmacs-clawtilla-page-need-agent)))
   "reviewing; its suggestions appear here when the model answers"))

(defun cmacs-clawtilla-review-set-model ()
  "Choose the model that reviews memories, for the whole fleet.

A small one.  Off spends nothing; on, each agent's memories are read
about once an interval and nothing is changed until you accept a
suggestion."
  (interactive)
  (cmacs-clawtilla-page-send
   "memory.review_set"
   (list (cons 'model (cmacs-clawtilla-pages--choose "Review with: "
                                                     "ack-check-model")))
   "saved for the whole fleet"))

(cmacs-clawtilla-define-page "memory-review"
  :title "Memory review"
  :needs-agent t
  :intro "Everything this agent remembered, forgot or pinned, newest first, and the merges, forgets and pins a small model suggests for its own memories.  Nothing changes until you accept a suggestion, and every change has an undo."
  :fetch '((proposals "memory.proposals") (journal "memory.journal"))
  :draw #'cmacs-clawtilla-review--draw
  :events (lambda (kind data)
            (and (equal kind "memory.changed")
                 (equal (cmacs-clawtilla-event-subject data)
                        cmacs-clawtilla-page--agent)))
  :verbs '(("u" "undo this change" cmacs-clawtilla-review-undo)
           ("a" "accept the suggestion" cmacs-clawtilla-review-accept)
           ("x" "reject the suggestion" cmacs-clawtilla-review-reject)
           ("r" "review now" cmacs-clawtilla-review-now)
           ("m" "review model" cmacs-clawtilla-review-set-model)))

;;;###autoload
(defun cmacs-clawtilla-memory-review (agent &optional conn)
  "Show what AGENT remembered, forgot and pinned on CONN, with a way back."
  (interactive (list (cmacs-clawtilla-read-agent "Memory review for: ")))
  (cmacs-clawtilla-page-open "memory-review" conn agent))


;;;; Saved steps, per agent.

(defun cmacs-clawtilla-steps--line (steps)
  "Return STEPS, a list of step descriptions, as one line."
  (let ((n (length steps)))
    (concat (format "%d step%s" n (if (= n 1) "" "s"))
            (if (> n 0)
                (concat ": " (string-join (seq-take steps 4) " · ")) "")
            (if (> n 4) " …" ""))))

(defun cmacs-clawtilla-steps--draw ()
  "Draw an agent's saved steps: its last turn, then what was kept."
  (let ((run (cmacs-clawtilla-page-data 'last))
        (saved (cmacs-clawtilla-page-data 'saved 'saved)))
    (insert "  "
            (cond
             ((null (alist-get 'steps run))
              (cmacs-clawtilla-dim
               "The agent's last turn did nothing to this screen since the daemon started."))
             ((eq t (alist-get 'saveable run))
              (format "Its last turn: %s.  Saved, it is checked by: %s.  (s saves it)"
                      (cmacs-clawtilla-steps--line (alist-get 'steps run))
                      (or (alist-get 'check_label run) "?")))
             (t
              (format "Its last turn: %s.  Cannot be saved: %s"
                      (cmacs-clawtilla-steps--line (alist-get 'steps run))
                      (or (alist-get 'why_not run) "unknown"))))
            "\n\n")
    (if (null saved)
        (insert "  " (cmacs-clawtilla-dim "Nothing saved yet.") "\n")
      (dolist (entry saved)
        (cmacs-clawtilla-page-insert-row
         'saved-steps entry
         (concat (propertize (or (alist-get 'name entry) "?")
                             'face 'cmacs-clawtilla-agent)
                 (if (alist-get 'other_check entry)
                     (concat "  "
                             (cmacs-clawtilla-dim
                              (format "c: check by %s"
                                      (or (alist-get 'other_check_label entry)
                                          (alist-get 'other_check entry)))))
                   ""))
         (cmacs-clawtilla-steps--line (alist-get 'steps entry))
         (alist-get 'check_line entry))))))

(defun cmacs-clawtilla-steps-save (name)
  "Keep the agent's last turn on this screen as the saved steps NAME."
  (interactive "sName these steps: ")
  (when (string-empty-p name) (user-error "They need a name"))
  (cmacs-clawtilla-page-send
   "steps.save" (list (cons 'agent (cmacs-clawtilla-page-need-agent))
                      (cons 'name name))
   "saved; take the screen and press r to run them again with no model"))

(defun cmacs-clawtilla-steps--act (kind &optional extra said)
  "Send KIND for the saved steps at point, with EXTRA, and say SAID."
  (cmacs-clawtilla-page-send
   kind
   (append (list (cons 'agent (cmacs-clawtilla-page-need-agent))
                 (cons 'name (alist-get 'name (cmacs-clawtilla-page-row
                                               'saved-steps))))
           extra)
   said))

(defun cmacs-clawtilla-steps-replay ()
  "Run the saved steps at point again, with no model.

Only while you hold the screen, and only when it matches the way these
steps are checked: a replay refuses a screen that has changed."
  (interactive)
  (cmacs-clawtilla-steps--act
   "steps.replay" nil
   "checking the screen against the saved picture, then replaying"))

(defun cmacs-clawtilla-steps-set-check ()
  "Change what a replay of the steps at point compares before it sends anything.

The picture and the focused window's title, or the title only -- the
daemon offers whichever these steps are not using."
  (interactive)
  (let ((other (or (alist-get 'other_check (cmacs-clawtilla-page-row
                                            'saved-steps))
                   (user-error "These steps have only one way to be checked"))))
    (cmacs-clawtilla-steps--act "steps.set_check" (list (cons 'check other))
                                "check changed")))

(defun cmacs-clawtilla-steps-delete ()
  "Forget the saved steps at point."
  (interactive)
  (when (yes-or-no-p (format "Forget the steps %s? "
                             (alist-get 'name (cmacs-clawtilla-page-row
                                               'saved-steps))))
    (cmacs-clawtilla-steps--act "steps.delete")))

(defun cmacs-clawtilla-steps--on-event (kind data)
  "Say how a replay ended: the event KIND carrying DATA."
  (when (and (equal kind "steps.replayed")
             (equal (cmacs-clawtilla-event-subject data)
                    cmacs-clawtilla-page--agent))
    (let ((failed (cmacs-clawtilla-event-detail data 'error)))
      (message "clawtilla: %s"
               (if failed (format "the replay stopped: %s" failed)
                 "replayed every saved step")))))

(cmacs-clawtilla-define-page "steps"
  :title "Saved steps"
  :needs-agent t
  :intro "What this agent did to its screen in one turn, kept so it can be done again with no model.  Replay needs you to hold the screen and refuses a screen that has changed."
  :fetch '((last "steps.last") (saved "steps.list"))
  :draw #'cmacs-clawtilla-steps--draw
  :events (lambda (kind data)
            (and (string-prefix-p "steps." kind)
                 (equal (cmacs-clawtilla-event-subject data)
                        cmacs-clawtilla-page--agent)))
  :on-event #'cmacs-clawtilla-steps--on-event
  :verbs '(("s" "save its last turn" cmacs-clawtilla-steps-save)
           ("r" "replay" cmacs-clawtilla-steps-replay)
           ("c" "change what a replay checks" cmacs-clawtilla-steps-set-check)
           ("D" "forget these steps" cmacs-clawtilla-steps-delete)))

;;;###autoload
(defun cmacs-clawtilla-saved-steps (agent &optional conn)
  "Show the steps AGENT did on its screen that were saved, on CONN."
  (interactive (list (cmacs-clawtilla-read-agent "Saved steps of: ")))
  (cmacs-clawtilla-page-open "steps" conn agent))


;;;; Waits, per agent.

(defun cmacs-clawtilla-waits--draw ()
  "Draw what an agent is waiting for."
  (let ((waits (cmacs-clawtilla-page-data 'waits 'waits)))
    (if (null waits)
        (cmacs-clawtilla-page-insert-note
         "Nothing"
         "When this agent sets a wait with clawtilla_wait_until, it shows here until it ends.")
      (dolist (wait waits)
        (cmacs-clawtilla-page-insert-row
         'wait wait
         (propertize (or (alist-get 'label wait) "?")
                     'face 'cmacs-clawtilla-agent)
         (alist-get 'condition wait)
         ;; When it was last checked, when it will be next and when it
         ;; gives up: one sentence, the library's.
         (cmacs-clawtilla-ask
          "wait-schedule"
          :last_check_at (or (alist-get 'last_check_at wait) 0)
          :next_check_at (or (alist-get 'next_check_at wait) 0)
          :expires_at (or (alist-get 'expires_at wait) 0))
         (and (alist-get 'last_result wait)
              (format "Last check saw: %s" (alist-get 'last_result wait))))))))

(defun cmacs-clawtilla-waits-cancel ()
  "Cancel the wait at point.  The agent is told it is no longer waiting."
  (interactive)
  (let ((wait (cmacs-clawtilla-page-row 'wait)))
    (when (yes-or-no-p (format "Cancel the wait %s? "
                               (or (alist-get 'label wait) "")))
      (cmacs-clawtilla-page-send
       "wait.cancel" (list (cons 'wait (alist-get 'id wait)))
       "cancelled; the agent has been told it is no longer waiting"))))

(cmacs-clawtilla-define-page "waits"
  :title "Waiting for"
  :needs-agent t
  :fetch '((waits "wait.list"))
  :draw #'cmacs-clawtilla-waits--draw
  :events "\\`wait\\."
  :verbs '(("D" "cancel this wait" cmacs-clawtilla-waits-cancel)))

;;;###autoload
(defun cmacs-clawtilla-waits (agent &optional conn)
  "Show what AGENT is waiting for on CONN."
  (interactive (list (cmacs-clawtilla-read-agent "Waits of: ")))
  (cmacs-clawtilla-page-open "waits" conn agent))


;;;; The browser vault, per agent.

(defun cmacs-clawtilla-vault--draw ()
  "Draw which vault entries an agent's browser may use."
  (let ((entries (cmacs-clawtilla-page-data 'vault 'entries))
        (index 0))
    (if (null entries)
        (cmacs-clawtilla-page-insert-note
         "No vault entries"
         "Declare them under vault: in clawtilla.yaml to let an agent log in without seeing the password.")
      (dolist (entry entries)
        (cmacs-clawtilla-insert-section
         :type 'vault-entry :value entry :level 1
         :heading
         (concat (if (eq t (alist-get 'granted entry))
                     (propertize "[x] " 'face 'cmacs-clawtilla-running)
                   (cmacs-clawtilla-dim "[ ] "))
                 ;; What an entry is called is the library's -- a name
                 ;; and the site it is for, never the secret, which the
                 ;; daemon does not send.
                 (or (cmacs-clawtilla-ask
                      "vault-entry"
                      :entry (cons :json (cmacs-clawtilla-page-member-text
                                          'vault 'entries index)))
                     (alist-get 'name entry) "?")))
        (setq index (1+ index))))))

(defun cmacs-clawtilla-vault-toggle ()
  "Let this agent's browser use the vault entry at point, or stop letting it.

The agent is given the login, never the password.  The setting that
changes is its `browser.secrets', rewritten whole by libclawt so
flipping one grant cannot drop another."
  (interactive)
  (let* ((entry (cmacs-clawtilla-page-row 'vault-entry))
         (granted (eq t (alist-get 'granted entry)))
         (value (cmacs-clawtilla-ask
                 "vault-grants"
                 :vault (cons :json (cmacs-clawtilla-page-text 'vault))
                 :name (alist-get 'name entry)
                 :granted (if granted :false t))))
    (unless value (user-error "The daemon did not say enough to change that"))
    (cmacs-clawtilla-page-send
     "agent.set"
     (list (cons 'agent (cmacs-clawtilla-page-need-agent))
           (cons 'key "browser.secrets") (cons 'value value))
     (if granted "no longer granted" "granted"))))

(cmacs-clawtilla-define-page "vault"
  :title "Browser vault"
  :needs-agent t
  :intro "Logins this agent's browser may fill in.  The agent never sees a password: the daemon types it into the page."
  :fetch '((vault "vault.list"))
  :draw #'cmacs-clawtilla-vault--draw
  :verbs '(("RET" "grant or take away" cmacs-clawtilla-vault-toggle)))

;;;###autoload
(defun cmacs-clawtilla-vault (agent &optional conn)
  "Show which vault logins AGENT's browser may use on CONN."
  (interactive (list (cmacs-clawtilla-read-agent "Browser vault of: ")))
  (cmacs-clawtilla-page-open "vault" conn agent))


;;;; A skill's tests, and what agents have proposed.

(defun cmacs-clawtilla-skill-tests--draw ()
  "Draw a skill's tests and how each last went."
  (let ((tests (cmacs-clawtilla-page-data 'tests 'tests)))
    (if (null tests)
        (cmacs-clawtilla-page-insert-note
         "No tests yet"
         "Add tests/<name>.yaml beside the SKILL.md: input, and what the answer must (expect) and must not (reject) say.")
      (dolist (test tests)
        (let ((last (alist-get 'last test)))
          (cmacs-clawtilla-page-insert-row
           'skill-test test
           (format "%-24s %s" (or (alist-get 'name test) "")
                   (if last
                       (propertize (or (alist-get 'state last) "")
                                   'face (cmacs-clawtilla-state-face
                                          (alist-get 'state last)))
                     (cmacs-clawtilla-dim "never run")))
           (and last (alist-get 'detail last))))))))

(defun cmacs-clawtilla-skill-tests-run (agent)
  "Run this skill's tests on AGENT, one that has the skill.

They run in the background; refresh for the verdicts."
  (interactive
   (list (cmacs-clawtilla-read-agent
          "Run them on (an agent with the skill; empty: the daemon picks): "
          nil t)))
  (cmacs-clawtilla-page-send
   "skill.test_run"
   (cmacs-clawtilla-payload :skill (cmacs-clawtilla-page-arg) :agent agent)
   "tests running; refresh (gr) for the verdicts"))

(cmacs-clawtilla-define-page "skill-tests"
  :title "Skill tests"
  :fetch (list (list 'tests "skill.tests"
                     (lambda () (list (cons 'skill (cmacs-clawtilla-page-arg))))))
  :draw #'cmacs-clawtilla-skill-tests--draw
  :events "\\`skill\\."
  :verbs '(("r" "run them" cmacs-clawtilla-skill-tests-run)))

;;;###autoload
(defun cmacs-clawtilla-skill-tests (skill &optional conn)
  "Show the tests of SKILL on CONN and how each last went."
  (interactive "sSkill: ")
  (cmacs-clawtilla-page-open "skill-tests" conn nil nil skill))

(defun cmacs-clawtilla-skill-proposals--draw ()
  "Draw the skills and skill changes agents have proposed."
  (let ((proposals (cmacs-clawtilla-page-data 'proposals 'proposals)))
    (if (null proposals)
        (cmacs-clawtilla-page-insert-note
         "Nothing proposed"
         "When an agent proposes a new skill or a change to one, it waits here for you.")
      (dolist (proposal proposals)
        (let ((update (equal (alist-get 'kind proposal) "update"))
              (reason (alist-get 'reason proposal)))
          (cmacs-clawtilla-page-insert-row
           'skill-proposal proposal
           (propertize (or (alist-get 'name proposal) "?")
                       'face 'cmacs-clawtilla-agent)
           (format "%s proposes %s, %s"
                   (or (alist-get 'agent proposal) "an agent")
                   (if update "a change to this skill" "a new skill")
                   ;; `created_at' is microseconds here, unlike most.
                   (or (cmacs-clawtilla-ask
                        "time-ago" :at (or (alist-get 'created_at proposal) 0))
                       "just now"))
           (and (stringp reason) (not (string-empty-p reason)) reason)
           (alist-get 'description proposal)))))))

(defun cmacs-clawtilla-skill-proposals--resolve (action &optional extra)
  "Resolve the proposal at point with ACTION and the fields EXTRA."
  (let ((proposal (cmacs-clawtilla-page-row 'skill-proposal)))
    (cmacs-clawtilla-page-send
     "skill.proposal_resolve"
     (append (list (cons 'proposal (alist-get 'id proposal))
                   (cons 'action action))
             extra))))

(defun cmacs-clawtilla-skill-proposals-approve (note)
  "Approve the proposal at point, with NOTE sent to the agent.

A new skill is then in the library, disabled until you enable it; a
change is applied to the skill."
  (interactive "sWhy (optional, sent to the agent): ")
  (cmacs-clawtilla-skill-proposals--resolve
   "approve" (cmacs-clawtilla-payload :note note)))

(defun cmacs-clawtilla-skill-proposals-reject (note)
  "Reject the proposal at point, with NOTE sent to the agent."
  (interactive "sWhy (optional, sent to the agent): ")
  (cmacs-clawtilla-skill-proposals--resolve
   "reject" (cmacs-clawtilla-payload :note note)))

(defvar-local cmacs-clawtilla-skill-proposals--editing nil
  "The proposal this buffer is an edit of: (CONNECTION ID DESCRIPTION).")

(defun cmacs-clawtilla-skill-proposals-edit ()
  "Edit the proposed skill at point before taking it.

Opens its body in a buffer; C-c C-c takes it as edited, C-c C-k leaves
the proposal as it was."
  (interactive)
  (let* ((proposal (cmacs-clawtilla-page-row 'skill-proposal))
         (conn (cmacs-clawtilla-current))
         (buffer (get-buffer-create
                  (format "*clawtilla proposal: %s*"
                          (or (alist-get 'name proposal) "")))))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (or (alist-get 'body proposal) ""))
      (goto-char (point-min))
      (text-mode)
      (setq cmacs-clawtilla-skill-proposals--editing
            (list conn (alist-get 'id proposal)
                  (or (alist-get 'description proposal) "")))
      ;; A map of this buffer's own: `local-set-key' would bind these
      ;; in `text-mode-map', for every text buffer there is.
      (let ((map (make-sparse-keymap)))
        (set-keymap-parent map (current-local-map))
        (define-key map (kbd "C-c C-c")
                    #'cmacs-clawtilla-skill-proposals-edit-done)
        (define-key map (kbd "C-c C-k") #'kill-current-buffer)
        (use-local-map map))
      (setq header-line-format
            "C-c C-c takes the skill as edited, C-c C-k leaves the proposal alone"))
    (pop-to-buffer buffer)))

(defun cmacs-clawtilla-skill-proposals-edit-done ()
  "Take the proposal this buffer edits, with the body as it now reads."
  (interactive)
  (pcase-let ((`(,conn ,id ,description)
               cmacs-clawtilla-skill-proposals--editing)
              (body (buffer-substring-no-properties (point-min) (point-max)))
              (buffer (current-buffer)))
    (unless id (user-error "This buffer is not an edit of a proposal"))
    (cmacs-clawtilla-request
     conn "skill.proposal_resolve"
     (list (cons 'proposal id) (cons 'action "edit")
           (cons 'description
                 (read-string "Description: " description))
           (cons 'body body))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (message "clawtilla: taken as edited")
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(cmacs-clawtilla-define-page "skill-proposals"
  :title "Proposed by agents"
  :intro "A new skill is in the library disabled; a change is staged and the skill is unchanged.  Either waits for you."
  :fetch '((proposals "skill.proposals"))
  :draw #'cmacs-clawtilla-skill-proposals--draw
  :events "\\`\\(skill\\|decision\\)\\."
  :verbs '(("a" "approve" cmacs-clawtilla-skill-proposals-approve)
           ("x" "reject" cmacs-clawtilla-skill-proposals-reject)
           ("c" "edit, then take it" cmacs-clawtilla-skill-proposals-edit)))

;;;###autoload
(defun cmacs-clawtilla-skill-proposals (&optional conn)
  "Show the skills and skill changes agents on CONN have proposed."
  (interactive)
  (cmacs-clawtilla-page-open "skill-proposals" conn))


;;;; Would this trigger have matched?

;;;###autoload
(defun cmacs-clawtilla-trigger-match-test (id conditions &optional conn)
  "Test CONDITIONS against the last event trigger ID captured, on CONN.

CONDITIONS is a list of (PATH . VALUE): the event is let through when
each PATH in it contains VALUE.  Nothing is delivered -- this answers
whether it would have been, and shows every field the captured event
has, so a condition can be written from what actually arrived.

Interactively, reads conditions as PATH=VALUE until an empty one."
  (interactive
   (list (read-string "Trigger id: ")
         (let ((conditions nil) (line nil))
           (while (progn
                    (setq line (read-string
                                "Condition as path=value (empty to finish): "))
                    (not (string-empty-p line)))
             (if (string-match "\\`\\([^=]*\\)=\\(.*\\)\\'" line)
                 (push (cons (match-string 1 line) (match-string 2 line))
                       conditions)
               (message "clawtilla: write it as path=value")
               (sit-for 1)))
           (nreverse conditions))))
  (cmacs-clawtilla-request
   (or conn (cmacs-clawtilla-current)) "trigger.match_test"
   (list (cons 'id id)
         ;; A vector, so no conditions is `[]' rather than an object.
         (cons 'match (vconcat
                       (mapcar (lambda (condition)
                                 (list (cons 'path (car condition))
                                       (cons 'value (cdr condition))))
                               conditions))))
   (lambda (data err)
     (cond
      (err (message "clawtilla: %s" err))
      ((null (assq 'payload data))
       (message "clawtilla: %s" (or (cmacs-clawtilla-get data 'note)
                                    "Nothing has arrived yet.")))
      (t
       (cmacs-clawtilla-page-show-text
        (format "*clawtilla trigger test: %s*" id)
        (concat
         (if (eq t (cmacs-clawtilla-get data 'matches))
             "It would have been let through"
           "It would have been ignored")
         "\n"
         (if (cmacs-clawtilla-get data 'reason)
             (concat (cmacs-clawtilla-get data 'reason) "\n") "")
         "\n"
         (mapconcat
          (lambda (result)
            (format "%s contains “%s”\n    %s\n"
                    (or (alist-get 'path result) "?")
                    (or (alist-get 'value result) "")
                    (cond
                     ((not (eq t (alist-get 'found result)))
                      "Does not match: nothing is there")
                     ((eq t (alist-get 'matched result))
                      (format "Matches: it is “%s”"
                              (or (alist-get 'actual result) "")))
                     (t (format "Does not match: it is “%s”"
                                (or (alist-get 'actual result) ""))))))
          (cmacs-clawtilla-get data 'results) "")
         "\nEvery field the captured event has:\n"
         (mapconcat
          (lambda (field)
            (format "  %s = %s\n" (or (alist-get 'path field) "")
                    (or (alist-get 'value field) "")))
          (cmacs-clawtilla-get data 'paths) ""))))))))

;;;; Reaching them.

;;;###autoload (autoload 'cmacs-clawtilla-more-menu "cmacs-clawtilla-pages" nil t)
(transient-define-prefix cmacs-clawtilla-more-menu ()
  "The fleet-wide pages the GTK client keeps under Settings."
  ["What the work is for, and what it cost"
   [("p" "projects and budgets" cmacs-clawtilla-projects)
    ("s" "spending: the ledger" cmacs-clawtilla-spending)
    ("i" "issues the sentinel found" cmacs-clawtilla-issues)]]
  ["Keeping and moving a fleet"
   [("h" "version history" cmacs-clawtilla-history)
    ("x" "export & import" cmacs-clawtilla-pack)
    ("d" "paired devices" cmacs-clawtilla-devices)]]
  ["How it runs"
   [("o" "orchestration" cmacs-clawtilla-orchestration)
    ("b" "integration broker" cmacs-clawtilla-broker)
    ("e" "private addresses agents may reach" cmacs-clawtilla-egress)
    ("u" "skills agents proposed" cmacs-clawtilla-skill-proposals)]])

(provide 'cmacs-clawtilla-pages)

;;; cmacs-clawtilla-pages.el ends here
