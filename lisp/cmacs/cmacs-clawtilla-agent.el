;;; cmacs-clawtilla-agent.el --- One agent, and its mailbox -*- lexical-binding: t; -*-

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

;; The Agent section: Overview and Mailbox, which is what the GTK client
;; groups under that name.
;;
;; Overview is editable in place -- every field is a line you press RET
;; on -- because an agent is mostly a set of small decisions (model,
;; effort, restart policy, whether it starts with the fleet) and a form
;; that has to be filled in and submitted turns changing one of them
;; into a ceremony.
;;
;; Overview also carries what libclawt 0.2-0.9 added per agent: which
;; login its CLI uses (`model.account', offered from `account.list' with
;; the daemon's own usability check), a machine shared with other agents
;; (`computer.use', from `computer.shared'), its browser (`browser.mode'
;; and `browser.use') and its action rules (`policy.rules').  These are
;; read from `agent.show''s `settings' -- every per-agent schema key, as
;; strings -- and written back through `agent.set' as KEY and VALUE.
;;
;; The values a field offers come from the library, never from a list
;; written here: computer types and import modes are enumerations
;; clawtilla exports precisely so a client does not hold its own copy,
;; and `make parity' fails a client that spells any of them out.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(defvar cmacs-clawtilla-agent--draft nil
  "The token `design.agent' last answered with.

A design is a draft the daemon is holding, and committing names which
one -- so this is remembered rather than assumed to be the only one.")

(defvar-local cmacs-clawtilla-agent--id nil)
(defvar-local cmacs-clawtilla-agent--data nil)
(defvar-local cmacs-clawtilla-agent--mailbox nil)
(defvar-local cmacs-clawtilla-agent--settings nil
  "The agent's `settings' from `agent.show': every per-agent schema key.

Keyed by the agent-relative name the daemon uses -- `model.account',
`computer.use', `policy.rules' -- with every value a string, because
that is what `agent.set' parses back against the same schema.")
(defvar-local cmacs-clawtilla-agent--shared nil
  "The `computer.shared' list, for who else is on this agent's machine.")
(defvar-local cmacs-clawtilla-agent--page 'agent
  "Which page of the Agent section this buffer shows.")


;;;; Drawing.

(defun cmacs-clawtilla-agent--field (label value &optional key)
  "Insert LABEL and VALUE as an editable field named KEY."
  (let ((start (point)))
    (insert (format "  %-22s " label)
            (if value (format "%s" value) (cmacs-clawtilla-dim "—"))
            "\n")
    (when key
      (put-text-property start (point) 'cmacs-clawtilla-section
                         (list :type 'field :value key
                               :identity (format "field/%s" key)
                               :level 1 :foldable nil)))))

(defun cmacs-clawtilla-agent--draw-overview ()
  "Draw the agent's overview page."
  (let ((agent cmacs-clawtilla-agent--data))
    (cmacs-clawtilla-agent--field "Name" (alist-get 'name agent) 'name)
    (cmacs-clawtilla-agent--field "Description"
                                  (alist-get 'description agent) 'description)
    (cmacs-clawtilla-agent--field "Provider" (alist-get 'provider agent)
                                  'provider)
    (cmacs-clawtilla-agent--field "Model" (alist-get 'model agent) 'model)
    (cmacs-clawtilla-agent--field "Effort" (alist-get 'effort agent) 'effort)
    (cmacs-clawtilla-agent--field "Account"
                                  (cmacs-clawtilla-agent--setting
                                   'model.account "the CLI's own login")
                                  'model.account)
    (cmacs-clawtilla-agent--field "Computer" (alist-get 'computer agent)
                                  'computer)
    (cmacs-clawtilla-agent--field "Shared computer"
                                  (cmacs-clawtilla-agent--use-label)
                                  'computer.use)
    (cmacs-clawtilla-agent--field "Browser"
                                  (cmacs-clawtilla-agent--setting 'browser.mode)
                                  'browser.mode)
    (cmacs-clawtilla-agent--field "Browser session"
                                  (cmacs-clawtilla-agent--setting 'browser.use)
                                  'browser.use)
    (cmacs-clawtilla-agent--field "Team" (alist-get 'team agent) 'team)
    (cmacs-clawtilla-agent--field "Team role" (alist-get 'team_role agent)
                                  'team_role)
    (cmacs-clawtilla-agent--field "Restart" (alist-get 'restart agent)
                                  'restart)
    (cmacs-clawtilla-agent--field "Autostart"
                                  (if (eq t (alist-get 'autostart agent))
                                      "yes" "no")
                                  'autostart)
    (cmacs-clawtilla-agent--field "Chief of staff"
                                  (if (eq t (alist-get 'chief_of_staff agent))
                                      "yes" "no")
                                  'chief_of_staff)
    (cmacs-clawtilla-agent--field "Enabled"
                                  (if (eq t (alist-get 'enabled agent))
                                      "yes" "no")
                                  'enabled)
    (insert "\n")
    ;; What the agent may do without asking.  One rule a line, in the
    ;; order the daemon reads them: the first that matches decides.
    (let ((rules (cmacs-clawtilla-agent--policy-split
                  (cmacs-clawtilla-agent--setting 'policy.rules))))
      (cmacs-clawtilla-insert-section
       :type 'field :value 'policy.rules :level 0 :foldable t
       :heading (concat (propertize "Action rules" 'face 'cmacs-clawtilla-heading)
                        "  " (cmacs-clawtilla-dim
                              "first match wins; unmatched calls run"))
       :body (lambda ()
               (if (null rules)
                   (insert "    " (cmacs-clawtilla-dim
                                   "none of its own: the fleet's defaults apply")
                           "\n")
                 (dolist (rule rules)
                   (insert "    " rule "\n"))))))
    (insert "\n")
    ;; Credentials are shown by reference and never by value.  A client
    ;; that could print one is a client that eventually does.
    (let ((credentials (alist-get 'credentials agent)))
      (cmacs-clawtilla-insert-section
       :type 'credentials :value "credentials" :level 0 :foldable t
       :heading (propertize "Credentials" 'face 'cmacs-clawtilla-heading)
       :body (lambda ()
               (if (null credentials)
                   (insert "  " (cmacs-clawtilla-dim "none") "\n")
                 (dolist (pair credentials)
                   (cmacs-clawtilla-agent--field
                    (format "%s" (car pair))
                    (cmacs-clawtilla-dim (format "%s" (cdr pair)))))))))))

(defun cmacs-clawtilla-agent--setting (key &optional empty)
  "Return the agent's setting KEY, or EMPTY when it is unset or blank."
  (let ((value (alist-get key cmacs-clawtilla-agent--settings)))
    (if (and (stringp value) (not (string-empty-p value)))
        value
      empty)))

(defun cmacs-clawtilla-agent--use-label ()
  "Return the shared machine this agent uses, with who else is on it."
  (let* ((use (cmacs-clawtilla-agent--setting 'computer.use))
         (computer (and use
                        (seq-find (lambda (c) (equal (alist-get 'id c) use))
                                  cmacs-clawtilla-agent--shared))))
    (cond
     ((null use) "its own machine")
     ((null computer) (format "%s (not declared)" use))
     (t (cmacs-clawtilla-agent--computer-label computer)))))

(defun cmacs-clawtilla-agent--computer-label (computer)
  "Return a one-line label for the shared COMPUTER from `computer.shared'."
  (let ((users (alist-get 'users computer))
        (running (alist-get 'running computer)))
    (concat (format "%s (%s)" (alist-get 'id computer)
                    (or (alist-get 'type computer) "?"))
            (if (alist-get 'description computer)
                (format " -- %s" (alist-get 'description computer))
              "")
            (format " · %s · %d user%s, %d running"
                    (or (alist-get 'state computer) "?")
                    (length users) (if (= 1 (length users)) "" "s")
                    (length running))
            (if users (format " (%s)" (string-join users ", ")) ""))))

(defun cmacs-clawtilla-agent--draw-mailbox ()
  "Draw the agent's mailbox."
  (if (null cmacs-clawtilla-agent--mailbox)
      (insert "  " (cmacs-clawtilla-dim "nothing waiting") "\n")
    (dolist (item cmacs-clawtilla-agent--mailbox)
      (cmacs-clawtilla-insert-section
       :type 'mail :value item :level 1
       :heading (concat
                 (propertize (or (alist-get 'from item) "?")
                             'face 'cmacs-clawtilla-agent)
                 "  "
                 (cmacs-clawtilla-dim
                  (or (cmacs-clawtilla--time-label
                       (or (alist-get 'created item) 0))
                      ""))
                 "  "
                 (or (alist-get 'subject item)
                     (truncate-string-to-width
                      (or (alist-get 'body item) "") 60 nil nil t)))))))

(defun cmacs-clawtilla-agent--draw ()
  "Redraw the agent buffer."
  (cmacs-clawtilla-ui-preserving
    (let* ((agent cmacs-clawtilla-agent--data)
           (id (or cmacs-clawtilla-agent--id (alist-get 'id agent))))
      (insert (propertize (or (alist-get 'name agent) id)
                          'face 'cmacs-clawtilla-heading)
              "  "
              (propertize (or (alist-get 'state agent) "?")
                          'face (cmacs-clawtilla-state-face
                                 (alist-get 'state agent)))
              "\n")
      ;; The pages of this section, named by the library rather than
      ;; here: a section that grows a page should grow one here too,
      ;; without an edit.
      (insert (cmacs-clawtilla-dim
               (mapconcat
                (lambda (page)
                  (let ((nick (alist-get 'nick page)))
                    (if (equal nick (symbol-name cmacs-clawtilla-agent--page))
                        (propertize (alist-get 'label page)
                                    'face 'cmacs-clawtilla-heading)
                      (alist-get 'label page))))
                (cmacs-clawtilla-agent--pages) "  |  "))
              "\n\n")
      (pcase cmacs-clawtilla-agent--page
        ('mailbox (cmacs-clawtilla-agent--draw-mailbox))
        (_ (cmacs-clawtilla-agent--draw-overview))))))

(defun cmacs-clawtilla-agent--pages ()
  "Return the pages of the Agent section, as the library groups them."
  (let ((section (seq-find (lambda (s) (equal (alist-get 'nick s) "agent"))
                           (cmacs-clawtilla-enum "section"))))
    (alist-get 'pages section)))


;;;; Loading.

(defun cmacs-clawtilla-agent--load (&optional buffer)
  "Refetch what the agent buffer draws into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (id (buffer-local-value 'cmacs-clawtilla-agent--id buffer)))
    (cmacs-clawtilla-request
     conn "agent.show" (list (cons 'agent id))
     (lambda (data err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             (setq cmacs-clawtilla-agent--data
                   (or (cmacs-clawtilla-get data 'agent) data))
             (setq cmacs-clawtilla-agent--settings
                   (cmacs-clawtilla-get data 'settings))
             (cmacs-clawtilla-agent--draw))))))
    (cmacs-clawtilla-request
     conn "computer.shared" nil
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-agent--shared
                 (cmacs-clawtilla-get data 'computers))
           (cmacs-clawtilla-agent--draw)))))
    (cmacs-clawtilla-request
     conn "mailbox.list" (list (cons 'agent id))
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-agent--mailbox
                 (or (cmacs-clawtilla-get data 'items)
                     (cmacs-clawtilla-get data 'messages)))
           (cmacs-clawtilla-agent--draw)))))))


;;;; Editing.

(defconst cmacs-clawtilla-agent--setting-keys
  '((name . "name") (description . "description")
    (provider . "model.provider") (model . "model.model")
    (effort . "model.effort") (computer . "computer.type")
    (team . "team") (team_role . "team_role")
    (restart . "runtime.restart") (autostart . "runtime.autostart")
    (chief_of_staff . "chief_of_staff") (enabled . "enabled"))
  "The schema key `agent.set' takes for each overview field.

The overview shows `agent.show''s agent object, whose members are
summaries (`model', `restart'); `agent.set' takes the schema's own
agent-relative key (`model.model', `runtime.restart').  A field drawn
from `settings' is already named by its key and is not listed here.")

(defun cmacs-clawtilla-agent--setting-key (field)
  "Return the `agent.set' key for the overview FIELD, a symbol."
  (or (alist-get field cmacs-clawtilla-agent--setting-keys)
      (symbol-name field)))

(defun cmacs-clawtilla-agent--set-payload (agent key value)
  "Return the `agent.set' payload setting KEY of AGENT to VALUE.

`agent.set' takes `key' and `value' -- not the key as a member of its
own -- and VALUE travels as a string: the daemon parses it against the
schema, so a boolean is \"true\" or \"false\" and an empty string clears
a text setting.  Sending `(model . \"x\")' instead was refused as \"agent
and key are both required\" and nothing in the overview ever saved."
  (list (cons 'agent agent)
        (cons 'key (if (symbolp key) (symbol-name key) key))
        (cons 'value (pcase value
                       ((or 't "yes") "true")
                       ((or :false "no") "false")
                       ('nil "")
                       ((pred stringp) value)
                       (_ (format "%s" value))))))

(defun cmacs-clawtilla-agent--put (key value &optional callback)
  "Set this agent's KEY to VALUE, then reload and call CALLBACK.

`restart_required' is said rather than swallowed: an AI CLI lists its
tools when its session starts, so a permission changed under a running
agent reaches its files and not its session."
  (let ((buffer (current-buffer))
        (agent (or cmacs-clawtilla-agent--id
                   (alist-get 'id cmacs-clawtilla-agent--data))))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.set"
     (cmacs-clawtilla-agent--set-payload agent key value)
     (lambda (data err)
       (cond
        (err (message "clawtilla: %s" err))
        ((eq t (cmacs-clawtilla-get data 'restart_required))
         (message "clawtilla: saved; it takes effect when %s restarts" agent))
        (t (message "clawtilla: saved %s" key)))
       (unless err
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-agent--load buffer))
         (when callback (funcall callback)))))))

(defun cmacs-clawtilla-agent--choices (key)
  "Return the values KEY offers, or nil for free text.

Read out of the library's enumerations rather than listed here.  A
computer type added to clawtilla is offered by this client the moment
it exists, and `make parity' fails a client holding its own copy."
  (pcase key
    ('computer (cmacs-clawtilla-enum-nicks "computer-type"))
    ('browser.mode (cmacs-clawtilla-enum-nicks "browser-mode"))
    ('team_role '("member" "lead"))
    ((or 'autostart 'chief_of_staff 'enabled) '("yes" "no"))
    (_ nil)))

(defun cmacs-clawtilla-agent-set ()
  "Change the field at point."
  (interactive)
  (let* ((key (cmacs-clawtilla-value-at-point 'field)))
    (unless key (user-error "No field at point"))
    (pcase key
      ;; The four that are a choice among things the daemon holds
      ;; rather than a value somebody types.
      ('model.account (call-interactively #'cmacs-clawtilla-agent-account))
      ('computer.use (call-interactively #'cmacs-clawtilla-agent-use-computer))
      ('browser.use (call-interactively #'cmacs-clawtilla-agent-browser-session))
      ('policy.rules (call-interactively #'cmacs-clawtilla-agent-policy-edit))
      (_
       (let* ((agent cmacs-clawtilla-agent--data)
              (choices (cmacs-clawtilla-agent--choices key))
              (current (or (alist-get key agent)
                           (alist-get key cmacs-clawtilla-agent--settings)))
              (value (if choices
                         (completing-read (format "%s: " key) choices nil t)
                       (read-string (format "%s: " key)
                                    (and current (format "%s" current))))))
         (cmacs-clawtilla-agent--put
          (cmacs-clawtilla-agent--setting-key key) value))))))


;;;; Account, shared computer and browser.

(defun cmacs-clawtilla-agent--account-choices (accounts)
  "Return completion entries for ACCOUNTS from `account.list' with `agent'.

Each entry is (LABEL ID REASON): ID is nil for the CLI's own login,
REASON non-nil for an account this agent cannot use.  Usability is the
daemon's answer -- `clawt_account_check', the same check `agent.set'
applies -- so the picker offers exactly what saving accepts, and shows
the others with the reason rather than hiding them."
  (cons (list "the CLI's own login" nil nil)
        (mapcar (lambda (account)
                  (let ((id (alist-get 'id account))
                        (usable (eq t (alist-get 'usable account))))
                    (list (concat id
                                  (if (alist-get 'description account)
                                      (format " -- %s"
                                              (alist-get 'description account))
                                    "")
                                  (if usable ""
                                    (format "  (cannot be used: %s)"
                                            (or (alist-get 'reason account)
                                                "see the agent's warning"))))
                          id
                          (and (not usable)
                               (or (alist-get 'reason account) "not usable")))))
                accounts)))

(defun cmacs-clawtilla-agent-account ()
  "Choose which login this agent's CLI uses (`model.account')."
  (interactive)
  (let ((buffer (current-buffer))
        (agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "account.list" (list (cons 'agent agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((choices (cmacs-clawtilla-agent--account-choices
                          (cmacs-clawtilla-get data 'accounts)))
                (label (completing-read "Account: " choices nil t))
                (entry (cdr (assoc label choices)))
                (id (car entry))
                (reason (cadr entry)))
           ;; Shown so the reason is visible, refused so saving cannot
           ;; turn the agent into a shadow at the next reload.
           (when reason
             (user-error "%s cannot log in as %s: %s" agent id reason))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (cmacs-clawtilla-agent--put "model.account" (or id ""))))))))))

(defun cmacs-clawtilla-agent--shared-choices (computers)
  "Return completion entries for COMPUTERS from `computer.shared'.

Each is (LABEL . ID), with ID nil for the agent's own machine.  A host
computer is not shareable and is left out, as the daemon would refuse
it; who uses each machine and how many of them are running is part of
the label."
  (cons (cons "its own machine" nil)
        (delq nil
              (mapcar (lambda (computer)
                        (and (or (not (assq 'shareable computer))
                                 (eq t (alist-get 'shareable computer)))
                             (cons (cmacs-clawtilla-agent--computer-label
                                    computer)
                                   (alist-get 'id computer))))
                      computers))))

(defun cmacs-clawtilla-agent-use-computer ()
  "Put this agent on a machine declared under `computers:', or its own.

A shared machine's settings are the machine's, kept under `computers:',
and the daemon refuses any other `computer.*' key on an agent that uses
one."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "computer.shared" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let* ((choices (cmacs-clawtilla-agent--shared-choices
                          (cmacs-clawtilla-get data 'computers)))
                (label (completing-read "Use computer: " choices nil t)))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (cmacs-clawtilla-agent--put
                "computer.use" (or (cdr (assoc label choices)) ""))))))))))

(defun cmacs-clawtilla-agent-browser-mode (mode)
  "Set whether this agent drives a browser, and whose, to MODE.

The modes are libclawt's `ClawtBrowserMode', walked off its GType."
  (interactive
   (list (completing-read "Browser: "
                          (cmacs-clawtilla-enum-nicks "browser-mode") nil t)))
  (cmacs-clawtilla-agent--put "browser.mode" mode))

(defun cmacs-clawtilla-agent-browser-session ()
  "Choose the shared browser session this agent drives (`browser.use')."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "browser.list" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (unless (eq t (cmacs-clawtilla-get data 'available))
           (message "clawtilla: this daemon was built without GSURF=1"))
         (let* ((shared (seq-filter
                         (lambda (session)
                           (equal (alist-get 'kind session) "shared"))
                         (cmacs-clawtilla-get data 'sessions)))
                (choices (cons (cons "none" "")
                               (mapcar (lambda (session)
                                         (cons (format "%s  %s"
                                                       (alist-get 'id session)
                                                       (string-join
                                                        (alist-get 'agents session)
                                                        ", "))
                                               (alist-get 'id session)))
                                       shared)))
                (label (completing-read "Shared session: " choices nil t)))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (cmacs-clawtilla-agent--put
                "browser.use" (cdr (assoc label choices)))))))))))


;;;; Action rules.

(defun cmacs-clawtilla-agent--policy-split (text)
  "Return the rules in TEXT, a comma separated `MATCH=MODE' list."
  (and (stringp text)
       (seq-remove #'string-empty-p
                   (mapcar #'string-trim (split-string text ",")))))

(defun cmacs-clawtilla-agent--policy-join (rules)
  "Return RULES as the one line `agent.set' takes for `policy.rules'."
  (string-join rules ", "))

(defun cmacs-clawtilla-agent--policy-put (rules match mode)
  "Return RULES with MATCH set to MODE.

A rule for the same MATCH is replaced where it stands, because order is
meaning here -- the first rule that matches decides -- and moving it to
the end would change what every rule after its old place means."
  (let ((rule (format "%s=%s" match mode))
        (found nil))
    (setq rules (mapcar (lambda (existing)
                          (if (equal (car (split-string existing "=")) match)
                              (progn (setq found t) rule)
                            existing))
                        rules))
    (if found rules (append rules (list rule)))))

(defun cmacs-clawtilla-agent-policy-add (match mode)
  "Add or change the action rule for MATCH to MODE.

MATCH is an action class (offered from libclawt's `ClawtActionClass')
or a tool-name glob such as `mcp__github__*'; MODE is a
`ClawtPolicyMode'.  The daemon parses the rule where it arrives and
refuses one it cannot read, naming what it expected."
  (interactive
   (list (completing-read "Match (an action class or a tool glob): "
                          (cmacs-clawtilla-enum-nicks "action-class"))
         (completing-read "Mode: " (cmacs-clawtilla-enum-nicks "policy-mode")
                          nil t)))
  (cmacs-clawtilla-agent--put
   "policy.rules"
   (cmacs-clawtilla-agent--policy-join
    (cmacs-clawtilla-agent--policy-put
     (cmacs-clawtilla-agent--policy-split
      (cmacs-clawtilla-agent--setting 'policy.rules))
     match mode))))

(defun cmacs-clawtilla-agent-policy-remove (rule)
  "Remove the action RULE from this agent's own list."
  (interactive
   (list (completing-read "Remove rule: "
                          (or (cmacs-clawtilla-agent--policy-split
                               (cmacs-clawtilla-agent--setting 'policy.rules))
                              (user-error "This agent has no rules of its own"))
                          nil t)))
  (cmacs-clawtilla-agent--put
   "policy.rules"
   (cmacs-clawtilla-agent--policy-join
    (remove rule (cmacs-clawtilla-agent--policy-split
                  (cmacs-clawtilla-agent--setting 'policy.rules))))))

(defun cmacs-clawtilla-agent-policy-edit (text)
  "Replace this agent's action rules with TEXT, `MATCH=MODE' comma separated.

Empty clears them, and the fleet's `defaults.policy.rules' apply again:
an agent's own list replaces the fleet's rather than adding to it."
  (interactive
   (list (read-string "Action rules: "
                      (cmacs-clawtilla-agent--setting 'policy.rules))))
  (cmacs-clawtilla-agent--put
   "policy.rules"
   (cmacs-clawtilla-agent--policy-join
    (cmacs-clawtilla-agent--policy-split text))))

(defun cmacs-clawtilla-agent-next-page ()
  "Move to the next page of the Agent section."
  (interactive)
  (let* ((pages (mapcar (lambda (p) (intern (alist-get 'nick p)))
                        (cmacs-clawtilla-agent--pages)))
         (rest (cdr (memq cmacs-clawtilla-agent--page pages))))
    (setq cmacs-clawtilla-agent--page (or (car rest) (car pages)))
    (cmacs-clawtilla-agent--draw)))


;;;; The mailbox, and what to do about a stuck one.

(defun cmacs-clawtilla-agent--mail-id ()
  "Return the id of the mailbox item at point, or signal."
  (let ((item (cmacs-clawtilla-value-at-point 'mail)))
    (unless item (user-error "No mailbox item at point"))
    (or (alist-get 'id item) (user-error "That item has no id"))))

(defun cmacs-clawtilla-agent--mailbox (kind &optional payload)
  "Send KIND with PAYLOAD for this agent's mailbox and reload."
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind
     (append (list (cons 'agent cmacs-clawtilla-agent--id)) payload)
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-agent--load buffer)))))))

(defun cmacs-clawtilla-agent-ack ()
  "Acknowledge the mailbox item at point."
  (interactive)
  (cmacs-clawtilla-agent--mailbox
   "mailbox.ack" (list (cons 'id (cmacs-clawtilla-agent--mail-id)))))

(defun cmacs-clawtilla-agent-requeue ()
  "Put the item at point back on the queue."
  (interactive)
  (cmacs-clawtilla-agent--mailbox
   "mailbox.requeue" (list (cons 'id (cmacs-clawtilla-agent--mail-id)))))

(defun cmacs-clawtilla-agent-dead-letters ()
  "Show what this agent's mailbox gave up on.

Its own view rather than a filter on the queue: a dead letter is not
waiting for anything, and showing it beside things that are invites
somebody to wait for it too."
  (interactive)
  (let ((agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "mailbox.dead" (list (cons 'agent agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (with-current-buffer (get-buffer-create
                               (format "*clawtilla dead: %s*" agent))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (let ((items (or (cmacs-clawtilla-get data 'items)
                              (cmacs-clawtilla-get data 'messages))))
               (if (null items)
                   (insert (cmacs-clawtilla-dim "nothing gave up") "\n")
                 (dolist (item items)
                   (insert (format "%-14s %s\n"
                                   (or (alist-get 'from item) "?")
                                   (or (alist-get 'body item) ""))))))
             (goto-char (point-min))
             (special-mode))
           (cmacs-clawtilla-display (current-buffer))))))))

(defun cmacs-clawtilla-agent-purge ()
  "Throw away everything waiting in this agent's mailbox."
  (interactive)
  (when (yes-or-no-p
         (format "Discard everything waiting for %s? "
                 cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-agent--mailbox "mailbox.purge")))


;;;; The face an agent shows.

(defun cmacs-clawtilla-agent-avatar ()
  "Show this agent's avatar."
  (interactive)
  (let ((agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.avatar" (list (cons 'agent agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (let ((encoded (cmacs-clawtilla-get data 'base64)))
           (if (null encoded)
               (message "clawtilla: %s has no avatar" agent)
             (with-current-buffer (get-buffer-create
                                   (format "*clawtilla avatar: %s*" agent))
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert-image
                  (create-image (base64-decode-string encoded) nil t))
                 (special-mode))
               (cmacs-clawtilla-display (current-buffer))))))))))

(defun cmacs-clawtilla-agent-avatar-set (file)
  "Give this agent the picture in FILE."
  (interactive "fAvatar: ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.avatar_set"
   (list (cons 'agent cmacs-clawtilla-agent--id)
         (cons 'data (base64-encode-string
                       (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file)
                         (buffer-string))
                       t)))
   (lambda (_d e) (message "clawtilla: %s" (or e "avatar set")))))

(defun cmacs-clawtilla-agent-avatar-clear ()
  "Take this agent's avatar away."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.avatar_clear"
   (list (cons 'agent cmacs-clawtilla-agent--id))
   (lambda (_d e) (message "clawtilla: %s" (or e "avatar cleared")))))

(defun cmacs-clawtilla-agent-models ()
  "Offer the models this fleet's providers actually have.

Asked of the daemon rather than typed: a model name that is nearly
right fails at the first turn, by which time the agent exists and the
error mentions the provider rather than the typo."
  (interactive)
  (let ((buffer (current-buffer))
        (agent cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "model.list" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         ;; The daemon answers `providers', each carrying its own
         ;; models -- not a flat list.  Which provider a model belongs
         ;; to is worth showing: two providers can offer the same name.
         (let* ((providers (cmacs-clawtilla-get data 'providers))
                (names
                 (apply #'append
                        (mapcar
                         (lambda (provider)
                           (let ((id (or (alist-get 'id provider)
                                         (alist-get 'name provider) "")))
                             (mapcar
                              (lambda (m)
                                (let ((model (if (stringp m)
                                                 m
                                               (or (alist-get 'id m)
                                                   (alist-get 'name m) ""))))
                                  (format "%s  (%s)" model id)))
                              (alist-get 'models provider))))
                         providers)))
                (picked (completing-read "Model: " names nil t))
                (choice (car (split-string picked "  " t))))
           (cmacs-clawtilla-request
            (cmacs-clawtilla-current) "agent.set"
            (cmacs-clawtilla-agent--set-payload agent "model.model" choice)
            (lambda (_d e)
              (if e (message "clawtilla: %s" e)
                (when (buffer-live-p buffer)
                  (cmacs-clawtilla-agent--load buffer)))))))))))

(defun cmacs-clawtilla-agent-discover ()
  "Find agents the daemon can see but does not manage."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "agent.discover" nil
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (let ((found (cmacs-clawtilla-get data 'found)))
         (if (null found)
             (message "clawtilla: nothing unmanaged found")
           (with-current-buffer (get-buffer-create "*clawtilla discover*")
             (let ((inhibit-read-only t))
               (erase-buffer)
               (dolist (entry found)
                 (insert (format "%-20s %s\n"
                                 (or (alist-get 'id entry) "?")
                                 (or (alist-get 'path entry) ""))))
               (goto-char (point-min))
               (special-mode))
             (cmacs-clawtilla-display (current-buffer)))))))))

(defun cmacs-clawtilla-agent-forget ()
  "Stop managing this agent, leaving what it made alone."
  (interactive)
  (when (yes-or-no-p (format "Stop managing %s? " cmacs-clawtilla-agent--id))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.forget"
     (list (cons 'agent cmacs-clawtilla-agent--id))
     (lambda (_d e) (message "clawtilla: %s" (or e "forgotten"))))))


;;;; The agent designer.

(defun cmacs-clawtilla-agent-design (brief)
  "Have the fleet design an agent from BRIEF, then show what it proposes.

Proposed, not created.  `cmacs-clawtilla-agent-design-commit' is what
makes it, and the two are separate because an agent is a machine as
well as a config: committing one builds a container or boots a VM."
  (interactive "sWhat should this agent do? ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "design.agent"
   ;; `purpose' is the required half of the questionnaire; the rest --
   ;; boundaries, needs, personality, projects, notes -- are optional
   ;; and left to the daemon's defaults here.
   (list (cons 'purpose brief))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (with-current-buffer (get-buffer-create "*clawtilla design*")
         (let ((inhibit-read-only t))
           (erase-buffer)
           ;; The reply is a draft: a token, the YAML it proposes, the
           ;; id, the org files the model wrote, and its notes.
           (insert (propertize "id      " 'face 'cmacs-clawtilla-heading)
                   (format "%s\n" (or (cmacs-clawtilla-get data 'id) "?")))
           (when-let* ((notes (cmacs-clawtilla-get data 'notes)))
             (insert (propertize "notes   " 'face 'cmacs-clawtilla-heading)
                     (format "%s\n" notes)))
           (dolist (file (cmacs-clawtilla-get data 'files))
             (insert (propertize "file    " 'face 'cmacs-clawtilla-heading)
                     (format "%s\n" (or (alist-get 'name file) file))))
           (insert "\n" (or (cmacs-clawtilla-get data 'yaml) "") "\n")
           (setq cmacs-clawtilla-agent--draft
                 (cmacs-clawtilla-get data 'draft))
           (insert "\n" (cmacs-clawtilla-dim
                         "M-x cmacs-clawtilla-agent-design-commit to make it")
                   "\n")
           (goto-char (point-min))
           (special-mode))
         (cmacs-clawtilla-display (current-buffer)))))))

(defun cmacs-clawtilla-agent-design-commit (&optional start)
  "Create the agent that was designed, starting it unless START is nil."
  (interactive (list (y-or-n-p "Start it once made? ")))
  (unless cmacs-clawtilla-agent--draft
    (user-error "Nothing designed yet; M-x cmacs-clawtilla-agent-design"))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "design.commit"
   (list (cons 'draft cmacs-clawtilla-agent--draft)
         (cons 'start (if start t :false)))
   (lambda (data err)
     (cond
      (err (message "clawtilla: %s" err))
      ((cmacs-clawtilla-get data 'start_error)
       (message "clawtilla: made, but did not start: %s"
                (cmacs-clawtilla-get data 'start_error)))
      (t (message "clawtilla: made"))))))

(defun cmacs-clawtilla-agent-design-discard ()
  "Throw away the design that has not been committed."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "design.discard"
   (when cmacs-clawtilla-agent--draft
     (list (cons 'draft cmacs-clawtilla-agent--draft)))
   (lambda (_d e) (message "clawtilla: %s" (or e "discarded")))))

;;;; Creating and importing.

;;;###autoload
(defun cmacs-clawtilla-agent-create ()
  "Create an agent on the current connection.

Answers `started' as well as created, because a computer is built at an
agent's first start: one created and left alone is a configuration file
and no machine, and a start that failed is reported without undoing the
creation."
  (interactive)
  (let* ((conn (cmacs-clawtilla-current))
         (id (read-string "Agent id: "))
         (model (read-string "Model: " "sonnet"))
         (computer (completing-read
                    "Computer: " (cmacs-clawtilla-enum-nicks "computer-type")
                    nil t nil nil "none"))
         (start (y-or-n-p "Start it now? ")))
    (cmacs-clawtilla-request
     conn "agent.create"
     (list (cons 'id id) (cons 'model model) (cons 'computer computer)
           (cons 'start (if start t :false)))
     (lambda (data err)
       (cond
        (err (message "clawtilla: %s" err))
        ((cmacs-clawtilla-get data 'start_error)
         (message "clawtilla: %s created but did not start: %s" id
                  (cmacs-clawtilla-get data 'start_error)))
        (t (message "clawtilla: %s created%s" id
                    (if (eq t (cmacs-clawtilla-get data 'started))
                        " and started" ""))))))))

;;;###autoload
(defun cmacs-clawtilla-agent-import ()
  "Import an agent from a directory or a URL.

The modes come from the library's own enumeration, and which of them
take a URL rather than a path is the library's answer too."
  (interactive)
  (let* ((conn (cmacs-clawtilla-current))
         (modes (cmacs-clawtilla-enum "import-mode"))
         (mode (completing-read "Mode: "
                                (mapcar (lambda (m) (alist-get 'nick m)) modes)
                                nil t))
         (entry (seq-find (lambda (m) (equal (alist-get 'nick m) mode)) modes))
         (from (if (eq t (alist-get 'url entry))
                   (read-string "URL: ")
                 (read-directory-name "Directory: ")))
         (id (read-string "Agent id: ")))
    (cmacs-clawtilla-request
     conn "agent.import"
     (list (cons 'id id) (cons 'from from) (cons 'mode mode))
     (lambda (data err)
       (message "clawtilla: %s" (or err
                                    (cmacs-clawtilla-get data 'detail)
                                    (format "imported %s" id)))))))


;;;; The mode.

(transient-define-prefix cmacs-clawtilla-agent-menu ()
  "What this agent's page can do."
  ["Agent"
   [("RET" "change field" cmacs-clawtilla-agent-set)
    ("TAB" "next page" cmacs-clawtilla-agent-next-page)
    ("m" "pick a model" cmacs-clawtilla-agent-models)]
   [("v" "avatar" cmacs-clawtilla-agent-avatar)
    ("V" "set avatar" cmacs-clawtilla-agent-avatar-set)
    ("C" "clear avatar" cmacs-clawtilla-agent-avatar-clear)]
   [("gr" "refresh" cmacs-clawtilla-refresh)
    ("q" "quit" quit-window)]]
  ["Account, computer and browser"
   [("A" "login account" cmacs-clawtilla-agent-account)
    ("S" "use a shared computer" cmacs-clawtilla-agent-use-computer)]
   [("W" "browser mode" cmacs-clawtilla-agent-browser-mode)
    ("w" "shared browser session" cmacs-clawtilla-agent-browser-session)]]
  ["Action rules"
   [("r" "add or change a rule" cmacs-clawtilla-agent-policy-add)
    ("R" "remove a rule" cmacs-clawtilla-agent-policy-remove)
    ("E" "edit them all" cmacs-clawtilla-agent-policy-edit)]]
  ["Mailbox"
   [("a" "acknowledge" cmacs-clawtilla-agent-ack)
    ("u" "requeue" cmacs-clawtilla-agent-requeue)]
   [("d" "dead letters" cmacs-clawtilla-agent-dead-letters)
    ("P" "purge" cmacs-clawtilla-agent-purge)]]
  ["Fleet"
   [("D" "design an agent" cmacs-clawtilla-agent-design)
    ("K" "commit the design" cmacs-clawtilla-agent-design-commit)
    ("X" "discard it" cmacs-clawtilla-agent-design-discard)]
   [("o" "discover unmanaged" cmacs-clawtilla-agent-discover)
    ("F" "forget this one" cmacs-clawtilla-agent-forget)]])

(defvar cmacs-clawtilla-agent-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "RET") #'cmacs-clawtilla-agent-set)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-agent-next-page)
    (define-key map (kbd "a") #'cmacs-clawtilla-agent-ack)
    (define-key map (kbd "u") #'cmacs-clawtilla-agent-requeue)
    (define-key map (kbd "d") #'cmacs-clawtilla-agent-dead-letters)
    (define-key map (kbd "P") #'cmacs-clawtilla-agent-purge)
    (define-key map (kbd "m") #'cmacs-clawtilla-agent-models)
    (define-key map (kbd "v") #'cmacs-clawtilla-agent-avatar)
    (define-key map (kbd "?") #'cmacs-clawtilla-agent-menu)
    map)
  "Keymap for `cmacs-clawtilla-agent-mode'.")

(define-derived-mode cmacs-clawtilla-agent-mode special-mode "Clawtilla-Agent"
  "Major mode for one clawtilla agent."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-agent--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-agent (conn agent)
  "Show AGENT on CONN."
  (interactive (list (cmacs-clawtilla-current) nil))
  (let* ((id (if (stringp agent) agent (alist-get 'id agent)))
         (buffer (get-buffer-create (format "*clawtilla agent: %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-agent-mode)
        (cmacs-clawtilla-agent-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-agent--id id)
      (setq-local cmacs-clawtilla-agent--data (and (consp agent) agent))
      (cmacs-clawtilla-agent--load buffer))
    (cmacs-clawtilla-display buffer)))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-agent-mode-map 'cmacs-clawtilla-agent-mode)

(provide 'cmacs-clawtilla-agent)

;;; cmacs-clawtilla-agent.el ends here
