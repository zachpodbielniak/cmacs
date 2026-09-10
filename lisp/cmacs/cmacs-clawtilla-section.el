;;; cmacs-clawtilla-section.el --- Automation, Work and Library -*- lexical-binding: t; -*-

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

;; Automation (Routines, Triggers), Work (Tasks, Decisions, Flow) and
;; Library (Skills, Memory) -- the three sections that are a list of
;; things and a few verbs each.
;;
;; One buffer kind serves all of them, and the grouping is not written
;; here: a section's pages come from `clawt_section_page_count' and its
;; labels from the library, so a page added to clawtilla appears here
;; with no edit.  What IS written here is a renderer and a verb list per
;; page, because those are genuinely per-page.
;;
;; A page nobody has taught this file about still appears in the tab row
;; and says so, rather than being silently absent -- which is the
;; failure mode `make parity' exists to catch, arriving one release
;; early.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(defvar-local cmacs-clawtilla-section--nick nil)
(defvar-local cmacs-clawtilla-section--page nil)
(defvar-local cmacs-clawtilla-section--rows nil)
(defvar-local cmacs-clawtilla-section--agent nil
  "The agent this section is scoped to, when it is scoped to one.")

(defun cmacs-clawtilla-section--scope ()
  "Return the agent scope as a payload fragment, or nil."
  (when cmacs-clawtilla-section--agent
    (list (cons 'agent cmacs-clawtilla-section--agent))))


;;;; What each page is.

(defconst cmacs-clawtilla-section-pages
  `(("routines"
     :list "routine.list" :rows routines :type routine
     :row ,(lambda (row)
             (format "%-20s %-14s %-10s %s"
                     (or (alist-get 'id row) "?")
                     (or (alist-get 'schedule row) "manual")
                     ;; A routine that did not fire because the machine
                     ;; was asleep is MISSED, not failed.  Drawing it as
                     ;; broken trains you to ignore the one that is.
                     (propertize (or (alist-get 'state row) "")
                                 'face (pcase (alist-get 'state row)
                                         ("missed" 'cmacs-clawtilla-dim)
                                         ("failed" 'cmacs-clawtilla-error)
                                         (_ 'cmacs-clawtilla-running)))
                     (cmacs-clawtilla-dim
                      (or (cmacs-clawtilla--time-label
                           (or (alist-get 'last_run row) 0))
                          "never run")))))
    ("triggers"
     :list "trigger.list" :rows triggers :type trigger
     :row ,(lambda (row)
             (format "%-20s %-18s %s"
                     (or (alist-get 'id row) "?")
                     (or (alist-get 'kind row) "")
                     (cmacs-clawtilla-dim (or (alist-get 'agent row) "")))))
    ("tasks"
     :list "task.list" :rows tasks :type task
     :row ,(lambda (row)
             (format "%-12s %-12s %-10s %s"
                     (or (alist-get 'id row) "?")
                     (or (alist-get 'assignee row) "?")
                     (propertize (or (alist-get 'state row) "")
                                 'face (cmacs-clawtilla-state-face
                                        (alist-get 'state row)))
                     (or (alist-get 'title row) ""))))
    ("decisions"
     :list "decision.list" :rows decisions :type decision
     :row ,(lambda (row)
             (format "%-12s %s"
                     (or (alist-get 'agent row) "?")
                     (or (alist-get 'question row)
                         (alist-get 'summary row) ""))))
    ("flow"
     :list "room.history" :rows messages :type message
     :payload ((room . "flow") (as . "user"))
     :row ,(lambda (row)
             (format "%-12s %s"
                     (or (alist-get 'sender row) "?")
                     (string-replace "\n" " " (or (alist-get 'body row) "")))))
    ("skills"
     :list "skill.list" :rows skills :type skill
     :row ,(lambda (row)
             (format "%-24s %-9s %s"
                     (or (alist-get 'id row) (alist-get 'name row) "?")
                     ;; An imported skill arrives switched off, and that
                     ;; is a state worth drawing rather than an absence.
                     (if (eq t (alist-get 'enabled row))
                         (propertize "enabled" 'face 'cmacs-clawtilla-running)
                       (propertize "off" 'face 'cmacs-clawtilla-stopped))
                     (cmacs-clawtilla-dim
                      (or (alist-get 'description row) "")))))
    ("memory"
     :list "memory.list" :rows entries :type memory
     :row ,(lambda (row)
             (format "%-12s %s"
                     (or (alist-get 'scope row) "")
                     (string-replace "\n" " "
                                     (or (alist-get 'text row) ""))))))
  "How each page is fetched and drawn.

Only the parts that are genuinely per-page.  Which pages exist, what
they are called and which section they belong to all come from the
library.")

(defun cmacs-clawtilla-section--spec (page)
  "Return the spec for PAGE, or nil."
  (cdr (assoc page cmacs-clawtilla-section-pages)))

(defun cmacs-clawtilla-section--library-pages (nick)
  "Return the pages the library says section NICK has."
  (let ((section (seq-find (lambda (s) (equal (alist-get 'nick s) nick))
                           (cmacs-clawtilla-enum "section"))))
    (alist-get 'pages section)))


;;;; Drawing.

(defun cmacs-clawtilla-section--draw ()
  "Redraw the section buffer."
  (cmacs-clawtilla-ui-preserving
    (let ((pages (cmacs-clawtilla-section--library-pages
                  cmacs-clawtilla-section--nick)))
      (insert (propertize
               (or (alist-get 'label
                              (seq-find
                               (lambda (s)
                                 (equal (alist-get 'nick s)
                                        cmacs-clawtilla-section--nick))
                               (cmacs-clawtilla-enum "section")))
                   cmacs-clawtilla-section--nick)
               'face 'cmacs-clawtilla-heading))
      (when cmacs-clawtilla-section--agent
        (insert "  " (cmacs-clawtilla-dim
                      (format "for %s" cmacs-clawtilla-section--agent))))
      (insert "\n"
              (mapconcat
               (lambda (page)
                 (let ((nick (alist-get 'nick page)))
                   (if (equal nick cmacs-clawtilla-section--page)
                       (propertize (alist-get 'label page)
                                   'face 'cmacs-clawtilla-heading)
                     (cmacs-clawtilla-dim (alist-get 'label page)))))
               pages "  |  ")
              "\n\n")
      (let ((spec (cmacs-clawtilla-section--spec
                   cmacs-clawtilla-section--page)))
        (cond
         ((null spec)
          ;; The library grew a page this file has not been taught.  Said
          ;; out loud rather than left blank: a page that is silently
          ;; absent is the exact failure `make parity' exists to catch,
          ;; and this is that failure arriving a release early.
          (insert "  "
                  (propertize
                   (format "This build has no view for the %s page yet."
                           cmacs-clawtilla-section--page)
                   'face 'cmacs-clawtilla-error)
                  "\n"))
         ((null cmacs-clawtilla-section--rows)
          (insert "  " (cmacs-clawtilla-dim "nothing here") "\n"))
         (t
          (dolist (row cmacs-clawtilla-section--rows)
            (cmacs-clawtilla-insert-section
             :type (plist-get spec :type) :value row :level 1
             :heading (funcall (plist-get spec :row) row)))))))))


;;;; Loading.

(defun cmacs-clawtilla-section--load (&optional buffer)
  "Refetch the current page into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (page (buffer-local-value 'cmacs-clawtilla-section--page buffer))
         (spec (cmacs-clawtilla-section--spec page)))
    (if (null spec)
        (with-current-buffer buffer (cmacs-clawtilla-section--draw))
      (cmacs-clawtilla-request
       conn (plist-get spec :list)
       (append (plist-get spec :payload)
               (with-current-buffer buffer (cmacs-clawtilla-section--scope)))
       (lambda (data err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if err
                 (message "clawtilla: %s" err)
               (setq cmacs-clawtilla-section--rows
                     (cmacs-clawtilla-get data (plist-get spec :rows)))
               (cmacs-clawtilla-section--draw)))))))))


;;;; Acting.

(defun cmacs-clawtilla-section-next-page ()
  "Move to the next page of this section."
  (interactive)
  (let* ((nicks (mapcar (lambda (p) (alist-get 'nick p))
                        (cmacs-clawtilla-section--library-pages
                         cmacs-clawtilla-section--nick)))
         (rest (cdr (member cmacs-clawtilla-section--page nicks))))
    (setq cmacs-clawtilla-section--page (or (car rest) (car nicks)))
    (setq cmacs-clawtilla-section--rows nil)
    (cmacs-clawtilla-section--load)))

(defun cmacs-clawtilla-section--row-id ()
  "Return the id of the row at point, or signal."
  (let ((row (cmacs-clawtilla-section-at-point)))
    (unless row (user-error "Nothing at point"))
    (or (alist-get 'id (plist-get row :value))
        (user-error "That row has no id"))))

(defun cmacs-clawtilla-section--send (kind payload)
  "Send KIND with PAYLOAD and reload."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind payload
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-section--load buffer)))))))

(defun cmacs-clawtilla-section-run ()
  "Run the routine at point, or a trigger's test."
  (interactive)
  (pcase cmacs-clawtilla-section--page
    ("routines" (cmacs-clawtilla-section--send
                 "routine.run" (list (cons 'id (cmacs-clawtilla-section--row-id)))))
    ("triggers" (cmacs-clawtilla-section--send
                 "trigger.test" (list (cons 'id (cmacs-clawtilla-section--row-id)))))
    ("skills" (cmacs-clawtilla-section--send
               "skill.enable"
               (list (cons 'id (cmacs-clawtilla-section--row-id))
                     (cons 'enabled t))))
    (_ (user-error "Nothing to run on this page"))))

(defun cmacs-clawtilla-section-remove ()
  "Remove the row at point."
  (interactive)
  (let ((id (cmacs-clawtilla-section--row-id)))
    (when (yes-or-no-p (format "Remove %s? " id))
      (pcase cmacs-clawtilla-section--page
        ("routines" (cmacs-clawtilla-section--send
                     "routine.remove" (list (cons 'id id))))
        ("triggers" (cmacs-clawtilla-section--send
                     "trigger.remove" (list (cons 'id id))))
        ("skills" (cmacs-clawtilla-section--send
                   "skill.remove" (list (cons 'id id))))
        ("tasks" (cmacs-clawtilla-section--send
                  "task.cancel" (list (cons 'id id))))
        (_ (user-error "Nothing to remove on this page"))))))

(defun cmacs-clawtilla-section-answer (answer)
  "Answer the decision at point with ANSWER."
  (interactive "sAnswer: ")
  (unless (equal cmacs-clawtilla-section--page "decisions")
    (user-error "Not a decision"))
  (cmacs-clawtilla-section--send
   "decision.answer" (list (cons 'id (cmacs-clawtilla-section--row-id))
                           (cons 'answer answer))))

(defun cmacs-clawtilla-section-dismiss ()
  "Dismiss the decision at point."
  (interactive)
  (unless (equal cmacs-clawtilla-section--page "decisions")
    (user-error "Not a decision"))
  (cmacs-clawtilla-section--send
   "decision.dismiss" (list (cons 'id (cmacs-clawtilla-section--row-id)))))

(defun cmacs-clawtilla-section-show ()
  "Show the row at point in full."
  (interactive)
  (let* ((row (cmacs-clawtilla-value-at-point))
         (buffer (get-buffer-create "*clawtilla detail*")))
    (unless row (user-error "Nothing at point"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (dolist (pair row)
          (insert (propertize (format "%-18s " (car pair))
                              'face 'cmacs-clawtilla-heading)
                  (format "%s" (cdr pair)) "\n"))
        (goto-char (point-min))
        (special-mode)))
    (cmacs-clawtilla-display buffer)))


;;;; Routines.

(defun cmacs-clawtilla-section--presets ()
  "Return the schedule presets, with cron behind Custom.

Most standing work is one of five shapes, and nobody should have to
write `0 9 * * 1-5' to get weekday mornings.  Cron is still there for
the sixth."
  '("manual" "hourly" "daily" "weekdays" "weekly" "custom"))

(defun cmacs-clawtilla-section-routine-add (id schedule prompt)
  "Add a routine ID running PROMPT on SCHEDULE."
  (interactive
   (let* ((id (read-string "Routine id: "))
          (preset (completing-read "When: "
                                   (cmacs-clawtilla-section--presets) nil t))
          (schedule (if (equal preset "custom")
                        (read-string "Cron: ")
                      preset))
          (prompt (read-string "Do what: ")))
     (list id schedule prompt)))
  (cmacs-clawtilla-section--send
   "routine.add" (append (list (cons 'id id) (cons 'schedule schedule)
                               (cons 'prompt prompt))
                         (cmacs-clawtilla-section--scope))))

(defun cmacs-clawtilla-section-routine-update ()
  "Change the routine at point."
  (interactive)
  (let* ((id (cmacs-clawtilla-section--row-id))
         (field (completing-read "Change: "
                                 '("schedule" "prompt" "enabled" "agent")
                                 nil t))
         (value (if (equal field "schedule")
                    (let ((preset (completing-read
                                   "When: "
                                   (cmacs-clawtilla-section--presets) nil t)))
                      (if (equal preset "custom")
                          (read-string "Cron: ")
                        preset))
                  (read-string (format "%s: " field)))))
    (cmacs-clawtilla-section--send
     "routine.update" (list (cons 'id id) (cons field value)))))


;;;; Triggers.

(defun cmacs-clawtilla-section-trigger-add (id kind agent)
  "Add trigger ID of KIND delivering to AGENT."
  (interactive (list (read-string "Trigger id: ")
                     (read-string "Kind: ")
                     (read-string "Deliver to: ")))
  (cmacs-clawtilla-section--send
   "trigger.add" (list (cons 'id id) (cons 'kind kind) (cons 'agent agent))))

(defun cmacs-clawtilla-section-trigger-update ()
  "Change the trigger at point."
  (interactive)
  (let* ((id (cmacs-clawtilla-section--row-id))
         (field (read-string "Field: "))
         (value (read-string (format "%s: " field))))
    (cmacs-clawtilla-section--send
     "trigger.update" (list (cons 'id id) (cons field value)))))

(defun cmacs-clawtilla-section-trigger-capture ()
  "Capture the next event this trigger would match, without acting."
  (interactive)
  (cmacs-clawtilla-section--send
   "trigger.capture" (list (cons 'id (cmacs-clawtilla-section--row-id)))))

(defun cmacs-clawtilla-section-trigger-rotate ()
  "Rotate the webhook secret of the trigger at point."
  (interactive)
  (when (yes-or-no-p "Rotate this trigger's secret? ")
    (cmacs-clawtilla-section--send
     "trigger.rotate" (list (cons 'id (cmacs-clawtilla-section--row-id))))))

(defun cmacs-clawtilla-section-trigger-deliveries ()
  "Show what this trigger has delivered."
  (interactive)
  (let ((id (cmacs-clawtilla-section--row-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "trigger.deliveries" (list (cons 'id id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla deliveries: %s*" id))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (dolist (row (cmacs-clawtilla-get data 'deliveries))
               (insert (format "%-14s %-12s %-10s %s\n"
                               (or (alist-get 'receipt row) "?")
                               (or (alist-get 'agent row) "")
                               (or (alist-get 'state row) "")
                               (or (alist-get 'parent row) ""))))
             (goto-char (point-min))
             (special-mode)
             (setq-local cmacs-clawtilla-section--nick id))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-section-trigger-replay (receipt run)
  "Replay delivery RECEIPT of the trigger at point, running it if RUN.

Previewing and executing are one frame with a flag, and the flag
defaults to off: a replay that acts is indistinguishable from the
original event downstream, so it should never be the thing that happens
because somebody pressed the obvious key.

Execution needs a positive receipt.  A blank one previews the latest
snapshot instead, which is what the daemon does with zero."
  (interactive
   (list (read-number "Receipt (0 previews the latest): " 0)
         (and (yes-or-no-p "Actually run it? ")
              (yes-or-no-p "It will act as though the event just happened.  Sure? "))))
  (let ((id (cmacs-clawtilla-section--row-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "trigger.replay"
     (list (cons 'id id) (cons 'receipt receipt) (cons 'run (if run t :false)))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         ;; A successful envelope means the batch outcomes were
         ;; recorded, not that they all worked: `failed' and `results'
         ;; are where partial failure lives, and a client that read only
         ;; the envelope would report a success that was not one.
         (let ((failed (or (cmacs-clawtilla-get data 'failed) 0)))
           (message "clawtilla: %s%s"
                    (if (eq t (cmacs-clawtilla-get data 'matches))
                        "matched" "did not match")
                    (if (> failed 0)
                        (format "; %d recipient%s failed" failed
                                (if (= failed 1) "" "s"))
                      ""))))))))


;;;; Skills.

(defun cmacs-clawtilla-section-skill-create (id description)
  "Create skill ID described by DESCRIPTION."
  (interactive (list (read-string "Skill id: ")
                     (read-string "What it does: ")))
  (cmacs-clawtilla-section--send
   "skill.create" (list (cons 'id id) (cons 'description description))))

(defun cmacs-clawtilla-section-skill-import (from)
  "Import a skill from FROM.

It arrives switched OFF, which is the daemon's decision and worth
knowing: a skill that starts working the moment it lands is one nobody
read first."
  (interactive "sImport from: ")
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "skill.import" (list (cons 'from from))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (message "clawtilla: imported, and switched off until you enable it")
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-section--load buffer)))))))

(defun cmacs-clawtilla-section-skill-expand ()
  "Show the skill at point with everything it references pulled in."
  (interactive)
  (let ((id (cmacs-clawtilla-section--row-id)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "skill.expand" (list (cons 'id id))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla skill: %s*" id))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (or (cmacs-clawtilla-get data 'text)
                         (cmacs-clawtilla-get data 'content) ""))
             (goto-char (point-min))
             (special-mode))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-section-skill-commands ()
  "Show the slash commands the skill at point adds.

These are why the slash-command parity check cannot see everything: a
command whose name comes from a skill exists in no client's source."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "skill.commands"
   (list (cons 'id (cmacs-clawtilla-section--row-id)))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (message "clawtilla: %s"
                (or (string-join
                     (mapcar (lambda (c)
                               (if (stringp c) c (or (alist-get 'name c) "")))
                             (cmacs-clawtilla-get data 'commands))
                     " ")
                    "no commands"))))))

(defun cmacs-clawtilla-section-skill-reload ()
  "Reread the skills from disk."
  (interactive)
  (cmacs-clawtilla-section--send "skill.reload" nil))

(defun cmacs-clawtilla-section-skill-assign (agent)
  "Give the skill at point to AGENT."
  (interactive "sGive it to: ")
  (cmacs-clawtilla-section--send
   "skill.assign" (list (cons 'id (cmacs-clawtilla-section--row-id))
                        (cons 'agent agent))))

(defun cmacs-clawtilla-section-skill-unassign (agent)
  "Take the skill at point away from AGENT."
  (interactive "sTake it from: ")
  (cmacs-clawtilla-section--send
   "skill.unassign" (list (cons 'id (cmacs-clawtilla-section--row-id))
                          (cons 'agent agent))))

;;;; The mode.

(transient-define-prefix cmacs-clawtilla-section-menu ()
  "What this page can do."
  ["Page"
   [("TAB" "next page" cmacs-clawtilla-section-next-page)
    ("g" "refresh" cmacs-clawtilla-refresh)]]
  ["Row"
   [("RET" "show in full" cmacs-clawtilla-section-show)
    ("r" "run / enable" cmacs-clawtilla-section-run)]
   [("a" "answer" cmacs-clawtilla-section-answer)
    ("d" "dismiss" cmacs-clawtilla-section-dismiss)
    ("D" "remove" cmacs-clawtilla-section-remove)]]
  ["Routines"
   [("A" "add a routine" cmacs-clawtilla-section-routine-add)
    ("U" "change it" cmacs-clawtilla-section-routine-update)]]
  ["Triggers"
   [("T" "add a trigger" cmacs-clawtilla-section-trigger-add)
    ("E" "change it" cmacs-clawtilla-section-trigger-update)
    ("C" "capture the next" cmacs-clawtilla-section-trigger-capture)]
   [("V" "deliveries" cmacs-clawtilla-section-trigger-deliveries)
    ("P" "replay one" cmacs-clawtilla-section-trigger-replay)
    ("O" "rotate the secret" cmacs-clawtilla-section-trigger-rotate)]]
  ["Skills"
   [("N" "create" cmacs-clawtilla-section-skill-create)
    ("I" "import" cmacs-clawtilla-section-skill-import)
    ("X" "expand" cmacs-clawtilla-section-skill-expand)]
   [("M" "its commands" cmacs-clawtilla-section-skill-commands)
    ("L" "reload from disk" cmacs-clawtilla-section-skill-reload)]
   [("G" "give to an agent" cmacs-clawtilla-section-skill-assign)
    ("K" "take it away" cmacs-clawtilla-section-skill-unassign)]])

(defvar cmacs-clawtilla-section-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-section-next-page)
    (define-key map (kbd "RET") #'cmacs-clawtilla-section-show)
    (define-key map (kbd "r") #'cmacs-clawtilla-section-run)
    (define-key map (kbd "a") #'cmacs-clawtilla-section-answer)
    (define-key map (kbd "d") #'cmacs-clawtilla-section-dismiss)
    (define-key map (kbd "D") #'cmacs-clawtilla-section-remove)
    (define-key map (kbd "?") #'cmacs-clawtilla-section-menu)
    map)
  "Keymap for `cmacs-clawtilla-section-mode'.")

(define-derived-mode cmacs-clawtilla-section-mode special-mode
  "Clawtilla-Section"
  "Major mode for one clawtilla section."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-section--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-section (conn nick &optional agent)
  "Open section NICK on CONN, scoped to AGENT if given."
  (interactive
   (list (cmacs-clawtilla-current)
         (completing-read "Section: "
                          (cmacs-clawtilla-enum-nicks "section") nil t)))
  (let* ((buffer (get-buffer-create (format "*clawtilla %s*" nick)))
         (pages (cmacs-clawtilla-section--library-pages nick)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-section-mode)
        (cmacs-clawtilla-section-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-section--nick nick)
      (setq-local cmacs-clawtilla-section--agent agent)
      ;; The default page is the library's, not the first one drawn.
      (setq-local cmacs-clawtilla-section--page
                  (or (alist-get 'default-page
                                 (seq-find
                                  (lambda (s) (equal (alist-get 'nick s) nick))
                                  (cmacs-clawtilla-enum "section")))
                      (alist-get 'nick (car pages))))
      (cmacs-clawtilla-section--load buffer))
    (cmacs-clawtilla-display buffer)))

;;;###autoload
(defun cmacs-clawtilla-work (&optional conn)
  "Show tasks, decisions and flow."
  (interactive)
  (cmacs-clawtilla-section (or conn (cmacs-clawtilla-current)) "work"))

;;;###autoload
(defun cmacs-clawtilla-automation (&optional conn)
  "Show routines and triggers."
  (interactive)
  (cmacs-clawtilla-section (or conn (cmacs-clawtilla-current)) "automation"))

;;;###autoload
(defun cmacs-clawtilla-library (&optional conn)
  "Show skills and memory."
  (interactive)
  (cmacs-clawtilla-section (or conn (cmacs-clawtilla-current)) "library"))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-section-mode-map 'cmacs-clawtilla-section-mode)

(provide 'cmacs-clawtilla-section)

;;; cmacs-clawtilla-section.el ends here
