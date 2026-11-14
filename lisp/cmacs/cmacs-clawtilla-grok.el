;;; cmacs-clawtilla-grok.el --- The Grok page: bots, sending them work, and what came back -*- lexical-binding: t; -*-

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

;; clawtilla 0.10 hands an agent's work to a Grok bot -- a routine in
;; Grok with a webhook trigger -- and hears back over the tailnet.  This
;; is the cmacs side of the GTK client's Grok page (gtk-grok.c), drawn
;; as the `grok' page of the Work section:
;;
;;   - whether a job could be sent at all right now: the daemon's own
;;     answer (`reachable' / `unreachable_reason' from `grok.bots'),
;;     the same check a send makes;
;;   - the bots, who may reach each, whether it has a routine key and an
;;     MCP key, and the two things done to a bot once: show its
;;     routine's standing prompt (`grok.routine_prompt') and mint its MCP
;;     key (`grok.mcp_key', shown once);
;;   - every job, newest first (`grok.jobs'), its state drawn with the
;;     label and tone libclawt gives it -- the "grok-job-state" enum
;;     family, never a table written here -- and the bot's result or
;;     note folded under it, as plain text;
;;   - a composer that hands a job to a bot on an agent's behalf
;;     (`grok.send').
;;
;; The page's count is the daemon's `attention' -- failed, unanswered,
;; refused, or back with a question -- refreshed on `grok.job_updated'
;; and `grok.bots_changed', so it goes down as well as up.  It shows
;; beside the page's tab in the Work section.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(declare-function cmacs-clawtilla--time-label "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla-section--load "cmacs-clawtilla-section" (&optional buffer))
(declare-function cmacs-clawtilla-section--tone-face "cmacs-clawtilla-section" (tone))
(defvar cmacs-clawtilla-section--reply)
(defvar cmacs-clawtilla-section--page)

(defvar cmacs-clawtilla-grok--attention (make-hash-table :test 'eq)
  "Connection -> the daemon's count of Grok jobs that need somebody.")

(defun cmacs-clawtilla-grok-attention (conn)
  "The number of Grok jobs on CONN that need somebody, or nil if unknown."
  (gethash conn cmacs-clawtilla-grok--attention))


;;;; Job states, as libclawt says them.

(defun cmacs-clawtilla-grok--state (nick)
  "The \"grok-job-state\" entry for NICK, or the failed one."
  (let ((states (cmacs-clawtilla-enum "grok-job-state")))
    (or (seq-find (lambda (s) (equal (alist-get 'nick s) nick)) states)
        (seq-find (lambda (s) (equal (alist-get 'nick s) "failed")) states))))

(defun cmacs-clawtilla-grok--badge (nick)
  "The state badge for job state NICK, in libclawt's label and tone."
  (let ((state (cmacs-clawtilla-grok--state nick)))
    (propertize (or (alist-get 'label state) nick "?")
                'face (cmacs-clawtilla-section--tone-face
                       (alist-get 'tone state)))))


;;;; Loading.

(defun cmacs-clawtilla-grok--load (buffer conn)
  "Fetch the bots and the jobs for the Grok page in BUFFER on CONN."
  (let ((bots nil) (jobs nil) (pending 2))
    (cl-flet ((done ()
                (setq pending (1- pending))
                (when (and (zerop pending) (buffer-live-p buffer))
                  (with-current-buffer buffer
                    (setq cmacs-clawtilla-section--reply
                          (list (cons 'bots bots) (cons 'jobs jobs)))
                    (funcall 'cmacs-clawtilla-section--draw)))))
      (cmacs-clawtilla-request
       conn "grok.bots" nil
       (lambda (data err)
         (if err (message "clawtilla: %s" err) (setq bots data))
         (done)))
      (cmacs-clawtilla-request
       conn "grok.jobs" nil
       (lambda (data err)
         (if err
             (message "clawtilla: %s" err)
           (setq jobs data)
           (puthash conn (or (cmacs-clawtilla-get data 'attention) 0)
                    cmacs-clawtilla-grok--attention))
         (done))))))
(declare-function cmacs-clawtilla-section--draw "cmacs-clawtilla-section" ())


;;;; Drawing.

(defun cmacs-clawtilla-grok--bot-heading (bot)
  "The heading line for BOT."
  (let ((agents (cmacs-clawtilla-get bot 'agents)))
    (concat
     (propertize (or (alist-get 'name bot) "?") 'face 'cmacs-clawtilla-agent)
     "  "
     (if (eq t (alist-get 'mcp_key bot))
         (propertize "MCP" 'face 'cmacs-clawtilla-running)
       (cmacs-clawtilla-dim "HTTP only"))
     (unless (eq t (alist-get 'key_configured bot))
       (concat "  " (propertize "no key" 'face 'cmacs-clawtilla-error)))
     "  "
     (cmacs-clawtilla-dim
      (concat "reachable by "
              (if agents (mapconcat (lambda (a) (format "%s" a)) agents ", ")
                "nobody"))))))

(defun cmacs-clawtilla-grok--job-heading (job)
  "The heading line for JOB."
  (let ((run (alist-get 'run_uuid job)))
    (concat
     (cmacs-clawtilla-grok--badge (or (alist-get 'state job) "failed"))
     "  "
     (propertize (or (alist-get 'bot job) "?") 'face 'cmacs-clawtilla-agent)
     " · "
     ;; Somebody's request, drawn as text on one line.
     (string-replace "\n" " " (or (alist-get 'instructions job) ""))
     "  "
     (cmacs-clawtilla-dim
      (concat (or (alist-get 'id job) "?")
              " for " (or (alist-get 'agent job) "?")
              ", " (or (cmacs-clawtilla--time-label
                        (or (alist-get 'created_at job) 0))
                       "")
              (if (and (stringp run) (not (string-empty-p run)))
                  (concat " · Grok run " run)
                ""))))))

(defun cmacs-clawtilla-grok--job-body (job)
  "The bot's result, else its note, for JOB -- or nil."
  (let ((result (alist-get 'result job))
        (note (alist-get 'note job)))
    (cond ((and (stringp result) (not (string-empty-p result))) result)
          ((and (stringp note) (not (string-empty-p note))) note))))

(defun cmacs-clawtilla-grok-draw ()
  "Draw the Grok page from the section buffer's reply."
  (let* ((reply cmacs-clawtilla-section--reply)
         (bots-reply (alist-get 'bots reply))
         (jobs-reply (alist-get 'jobs reply))
         (bots (cmacs-clawtilla-get bots-reply 'bots))
         (jobs (cmacs-clawtilla-get jobs-reply 'jobs))
         (attention (or (cmacs-clawtilla-get jobs-reply 'attention) 0)))
    ;; Whether anything can be sent right now: the daemon's own answer.
    (insert "  "
            (if (eq t (cmacs-clawtilla-get bots-reply 'reachable))
                (cmacs-clawtilla-dim
                 (format "Bots report back to %s over the tailnet."
                         (or (cmacs-clawtilla-get bots-reply 'callback_host) "?")))
              (propertize (format "No job can be sent right now: %s."
                                  (or (cmacs-clawtilla-get bots-reply
                                                           'unreachable_reason)
                                      "unknown"))
                          'face 'cmacs-clawtilla-error))
            "\n\n")
    (cmacs-clawtilla-insert-section
     :type 'grok-bots :value "bots" :level 0 :foldable t
     :heading (propertize "Bots" 'face 'cmacs-clawtilla-team)
     :body (lambda ()
             (if (null bots)
                 (insert "    "
                         (cmacs-clawtilla-dim
                          "No Grok bot is shared with any agent.  Add a grokbot \
integration in Settings, named for the bot, with its routine's webhook \
address and key.")
                         "\n")
               (dolist (bot bots)
                 (cmacs-clawtilla-insert-section
                  :type 'grok-bot :value bot :level 1
                  :heading (cmacs-clawtilla-grok--bot-heading bot))))))
    (insert "\n")
    (cmacs-clawtilla-insert-section
     :type 'grok-jobs :value "jobs" :level 0 :foldable t
     :heading (concat (propertize "Jobs" 'face 'cmacs-clawtilla-team)
                      (if (> attention 0)
                          (concat "  " (propertize (format "%d need you" attention)
                                                   'face 'cmacs-clawtilla-error))
                        ""))
     :body (lambda ()
             (if (null jobs)
                 (insert "    "
                         (cmacs-clawtilla-dim
                          "No work has been handed to a Grok bot.  Agents send \
it with clawtilla_grok_dispatch; you can send it from here (i).")
                         "\n")
               (dolist (job jobs)
                 (let ((body (cmacs-clawtilla-grok--job-body job)))
                   (cmacs-clawtilla-insert-section
                    :type 'grok-job :value job :level 1 :foldable (and body t)
                    :heading (cmacs-clawtilla-grok--job-heading job)
                    :body (and body
                               (lambda ()
                                 ;; The bot's own text, written outside
                                 ;; the fleet: inserted as text, never
                                 ;; rendered as anything.
                                 (dolist (line (split-string body "\n"))
                                   (insert "      " line "\n"))))))))))))


;;;; Acting.

(defun cmacs-clawtilla-grok--bot-at-point ()
  "The name of the bot at point, or ask for one."
  (let ((bot (cmacs-clawtilla-value-at-point 'grok-bot)))
    (or (alist-get 'name bot)
        (let ((names (mapcar (lambda (b) (alist-get 'name b))
                             (cmacs-clawtilla-get
                              (alist-get 'bots cmacs-clawtilla-section--reply)
                              'bots))))
          (unless names (user-error "No Grok bot is shared with any agent"))
          (completing-read "Bot: " names nil t)))))

(defun cmacs-clawtilla-grok--show-text (title lead text)
  "Show TEXT in a read-only buffer named after TITLE, under LEAD."
  (with-current-buffer (get-buffer-create (format "*clawtilla %s*" title))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize lead 'face 'cmacs-clawtilla-dim) "\n\n" text)
      (unless (bolp) (insert "\n"))
      (goto-char (point-min))
      (special-mode))
    (cmacs-clawtilla-display (current-buffer))
    (current-buffer)))

(defun cmacs-clawtilla-grok-routine-prompt (bot)
  "Show the standing prompt to paste into BOT's routine in Grok."
  (interactive (list (cmacs-clawtilla-grok--bot-at-point)))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "grok.routine_prompt" (list (cons 'bot bot))
   (lambda (data err)
     (if err
         (message "clawtilla: %s" err)
       (cmacs-clawtilla-grok--show-text
        (format "routine prompt: %s" bot)
        "Paste this into the bot's routine in Grok, once.  Every job also \
carries its own instructions for reporting back, so this only sets the \
bot's habits."
        (or (cmacs-clawtilla-get data 'text) ""))))))

(defun cmacs-clawtilla-grok-mint-key (bot)
  "Mint an MCP key for BOT; it is shown once and replaces any old one."
  (interactive (list (cmacs-clawtilla-grok--bot-at-point)))
  (when (yes-or-no-p
         (format "Mint an MCP key for %s?  It is shown once, and an \
existing key stops working at once. " bot))
    (let ((buffer (current-buffer)))
      (cmacs-clawtilla-request
       (cmacs-clawtilla-current) "grok.mcp_key" (list (cons 'bot bot))
       (lambda (data err)
         (if err
             (message "clawtilla: %s" err)
           (cmacs-clawtilla-grok--show-text
            "copy this now"
            ;; Said as shown-once because the daemon said so.
            (if (eq t (cmacs-clawtilla-get data 'secret_shown_once))
                "In Grok, ask the bot to add a remote MCP connection with \
this URL and API key.  This is the only time the key is shown; minting \
another replaces it."
              "In Grok, ask the bot to add a remote MCP connection with this \
URL and API key.")
            (format "URL:     %s\nAPI key: %s\n"
                    (or (cmacs-clawtilla-get data 'mcp_url)
                        "(not reachable yet -- see the top of the Grok page)")
                    (or (cmacs-clawtilla-get data 'key) "?")))
           (when (buffer-live-p buffer)
             (cmacs-clawtilla-section--load buffer))))))))


;;;; Sending.

(defvar-local cmacs-clawtilla-grok--compose nil
  "In a composer: plist (:conn :bot :agent :context :origin).")

(defvar cmacs-clawtilla-grok-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cmacs-clawtilla-grok-compose-send)
    (define-key map (kbd "C-c C-k") #'cmacs-clawtilla-grok-compose-cancel)
    map)
  "Keymap for `cmacs-clawtilla-grok-compose-mode'.")

(define-derived-mode cmacs-clawtilla-grok-compose-mode text-mode "Grok-Job"
  "Write the instructions for a Grok bot.  C-c C-c sends, C-c C-k cancels.

\\{cmacs-clawtilla-grok-compose-mode-map}"
  :group 'cmacs-clawtilla)

(defun cmacs-clawtilla-grok-send (bot agent)
  "Hand BOT some work on AGENT's behalf; write it in a composer.
The answer is delivered to AGENT.  Only agents BOT is shared with are
offered."
  (interactive
   (let* ((bot (cmacs-clawtilla-grok--bot-at-point))
          (entry (seq-find (lambda (b) (equal (alist-get 'name b) bot))
                           (cmacs-clawtilla-get
                            (alist-get 'bots cmacs-clawtilla-section--reply)
                            'bots)))
          (agents (mapcar (lambda (a) (format "%s" a))
                          (cmacs-clawtilla-get entry 'agents))))
     (unless agents (user-error "%s is shared with no agent" bot))
     (list bot (if (cdr agents)
                   (completing-read (format "On behalf of (gets %s's answer): " bot)
                                    agents nil t)
                 (car agents)))))
  (let ((conn (cmacs-clawtilla-current))
        (origin (current-buffer))
        (buffer (get-buffer-create (format "*clawtilla grok: %s*" bot))))
    (with-current-buffer buffer
      (cmacs-clawtilla-grok-compose-mode)
      (erase-buffer)
      (setq cmacs-clawtilla-grok--compose
            (list :conn conn :bot bot :agent agent :origin origin))
      (setq header-line-format
            (format " To %s, on behalf of %s.  C-c C-c sends (C-u: add context), C-c C-k cancels."
                    bot agent)))
    (pop-to-buffer buffer)))

(defun cmacs-clawtilla-grok-compose-send (&optional with-context)
  "Send the instructions written here.  With WITH-CONTEXT, ask for context too."
  (interactive "P")
  (let* ((spec cmacs-clawtilla-grok--compose)
         (instructions (string-trim (buffer-string)))
         (context (and with-context (read-string "Context (optional): "))))
    (unless spec (user-error "Not a Grok composer"))
    (when (string-empty-p instructions)
      (user-error "Say what the bot should do"))
    (let ((buffer (current-buffer))
          (origin (plist-get spec :origin)))
      (cmacs-clawtilla-request
       (plist-get spec :conn) "grok.send"
       (append (list (cons 'bot (plist-get spec :bot))
                     (cons 'agent (plist-get spec :agent))
                     (cons 'instructions instructions))
               (and context (not (string-empty-p context))
                    (list (cons 'context context))))
       (lambda (data err)
         (if err
             (message "clawtilla: %s" err)
           (let ((job (cmacs-clawtilla-get data 'job)))
             (message "clawtilla: sent to %s as %s; the answer goes to %s"
                      (or (alist-get 'bot job) "?") (or (alist-get 'id job) "?")
                      (plist-get spec :agent)))
           (when (buffer-live-p buffer) (kill-buffer buffer))
           (when (buffer-live-p origin)
             (cmacs-clawtilla-section--load origin))))))))

(defun cmacs-clawtilla-grok-compose-cancel ()
  "Abandon this Grok job."
  (interactive)
  (kill-buffer (current-buffer)))


;;;; Events.

(defun cmacs-clawtilla-grok--on-event (conn kind _data)
  "Keep the Grok count and any open Grok page on CONN current after KIND.
Both ends of a job publish `grok.job_updated', so the count goes down
as well as up; a key minted elsewhere changes the bots."
  (when (member kind '("grok.job_updated" "grok.bots_changed"))
    (let (showing)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'cmacs-clawtilla-section-mode)
                     (eq cmacs-clawtilla-connection conn)
                     (equal cmacs-clawtilla-section--page "grok"))
            (setq showing t)
            (cmacs-clawtilla-section--load buffer))))
      ;; Not on screen: fetch just the number.
      (unless showing
        (cmacs-clawtilla-request
         conn "grok.jobs" nil
         (lambda (data err)
           (unless err
             (puthash conn (or (cmacs-clawtilla-get data 'attention) 0)
                      cmacs-clawtilla-grok--attention))))))))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-grok--on-event)

(provide 'cmacs-clawtilla-grok)

;;; cmacs-clawtilla-grok.el ends here
