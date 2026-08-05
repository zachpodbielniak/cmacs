;;; cmacs-brigade-dashboard.el --- Watching the brigade  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A live view of what the agents are doing.
;;
;; The dashboard is a *pure projection*.  It never holds state of its
;; own, and its keys call exactly the functions the org hooks call -- so
;; there are two writers (org and the runtime) and three readers, rather
;; than three things that each think they know the answer.
;;
;; Rendering is a full redraw on `special-mode' rather than
;; `tabulated-list-mode': the view is a tree with per-row progress, which
;; tabulated-list does badly, and `cmacs-transcode' already worked out
;; how to redraw without losing the cursor.
;;
;; Refresh is event-driven with a coalescing idle timer, never a poll.
;; Eight streaming agents deliver progress at tens of hertz each, and
;; redrawing per event melts the display; a 2-second heartbeat only
;; refreshes elapsed times.
;;
;; It works identically in a terminal.  Under `emacs --lrg'
;; `display-graphic-p' returns t while there is no menu bar, so anything
;; here that wants a menu uses `cmacs-libregnum-popup-menu' -- an ERT
;; test greps this file to keep it that way.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
;; Every command here dispatches into the runner; without this the keys
;; are bound to void functions.
(require 'cmacs-brigade-run)
;; Required, not fboundp-guarded: every other cmacs UI file requires this
;; for Evil/Doom keymap precedence, and a guard that quietly does nothing
;; is how `s' ends up running evil-snipe instead of starting an agent.
(require 'cmacs-evil)
;; The editing keys write org headlines and re-adopt, and the plan
;; commands need the directory default, so the plan layer is a hard
;; dependency rather than something to declare-function around.
(require 'cmacs-brigade-plan)
(require 'cmacs-brigade-output)
(require 'cl-lib)
(require 'subr-x)

(defcustom cmacs-brigade-dashboard-refresh-idle 0.15
  "Seconds of idle time before a dirty dashboard redraws."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-dashboard-heartbeat 2
  "Seconds between refreshes of elapsed times."
  :type 'number
  :group 'cmacs-brigade)

(defcustom cmacs-brigade-dashboard-unicode 'auto
  "Whether to use Unicode status glyphs.
`auto' checks whether the display can show them."
  :type '(choice (const auto) (const t) (const nil))
  :group 'cmacs-brigade)

(defvar cmacs-brigade-dashboard--timer nil)
(defvar cmacs-brigade-dashboard--heartbeat nil)
(defvar cmacs-brigade-dashboard--dirty nil)

(defconst cmacs-brigade-dashboard--glyphs
  '((running       . ("▶" . ">"))
    (starting      . ("▶" . ">"))
    (queued        . ("⏳" . "."))
    (draft         . ("·" . "-"))
    (waiting-input . ("?" . "?"))
    (blocked       . ("⏸" . "|"))
    (interrupted   . ("⚠" . "!"))
    (done          . ("✔" . "+"))
    (failed        . ("✖" . "x"))
    (over-budget   . ("⚠" . "$"))
    (cancelled     . ("⊘" . "o")))
  "Status glyphs, Unicode and ASCII.")

(defun cmacs-brigade-dashboard--unicode-p ()
  (pcase cmacs-brigade-dashboard-unicode
    ('auto (char-displayable-p ?▶))
    (v v)))

(defun cmacs-brigade-dashboard--glyph (state)
  (let ((pair (alist-get state cmacs-brigade-dashboard--glyphs)))
    (if (cmacs-brigade-dashboard--unicode-p) (car pair) (cdr pair))))

(defun cmacs-brigade-dashboard--elapsed (record)
  "Human-readable elapsed time for RECORD."
  (let ((start (plist-get record :started-at))
        (end (plist-get record :ended-at)))
    (if (or (null start) (zerop start)) "—"
      (let ((secs (- (if (and end (> end 0)) end (floor (float-time))) start)))
        (format "%d:%02d" (/ secs 60) (% secs 60))))))

(defcustom cmacs-brigade-dashboard-min-width 150
  "Narrowest the table is laid out at, however narrow the window is.

Below this the columns truncate to nothing useful: a task id clipped to
ten characters cannot be matched against the one an agent reported, and a
model clipped to eighteen loses the half that says which model it is.
The dashboard sets `truncate-lines\=', so in a narrower window the line
scrolls rather than wrapping -- the lesser problem."
  :type 'integer
  :group 'cmacs-brigade)

(defun cmacs-brigade-dashboard--columns ()
  "Column widths for the table, as a plist, fitted to the window.

TASK takes whatever is left over: it is the one field whose useful length
has no upper bound, and the only one worth truncating first."
  (let* ((total (max cmacs-brigade-dashboard-min-width
                     (- (window-width
                         (get-buffer-window (current-buffer) t))
                        1)))
         ;; A uuid is 36; ids are compared against what an agent prints,
         ;; so it is shown whole.
         (id 36)
         (agent 20)
         (model 28)
         (fixed (+ 3 1 id 1 agent 1 model 1 5 1 11 1 9))
         ;; TASK absorbs the slack, with a floor: a title cut to a
         ;; dozen characters is as useless as no title.
         (task (max 24 (- total fixed 1))))
    (list :st 3 :id id :agent agent :model model :task task
          :turns 5 :tokens 11 :cost 9
          :total (+ fixed task 1))))

(defun cmacs-brigade-dashboard--row-format (c)
  "Build the row format string for column widths C.

Emacs `format\=' has no `%-*s\=' -- the star width is a C printf feature --
so the spec is assembled from the widths rather than passed alongside
them."
  (format "%%-%ds %%-%ds %%-%ds %%-%ds %%-%ds %%%ds %%%ds %%%ds"
          (plist-get c :st) (plist-get c :id) (plist-get c :agent)
          (plist-get c :model) (plist-get c :task) (plist-get c :turns)
          (plist-get c :tokens) (plist-get c :cost)))

(defun cmacs-brigade-dashboard--render ()
  "Redraw the dashboard, keeping the cursor where it was."
  (let ((buf (get-buffer "*brigade*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (line (line-number-at-pos))
              (records (and (fboundp 'cmacs-brigade-task-list)
                            (cmacs-brigade-task-list))))
          (erase-buffer)
          (let ((c (cmacs-brigade-dashboard--columns)))
            (cmacs-brigade-dashboard--insert-header records)
            ;; The rule matches the table, rather than a constant that
            ;; stopped matching the moment a column changed.
            (insert (make-string (plist-get c :total) ?─) "\n")
            (insert (propertize
                     (concat (format (cmacs-brigade-dashboard--row-format c)
                                     "ST" "ID" "AGENT" "MODEL" "TASK"
                                     "TURNS" "TOKENS" "COST")
                             "\n")
                     'face 'bold))
            (if (null records)
                (cmacs-brigade-dashboard--insert-empty)
              (dolist (r (cmacs-brigade-dashboard--sort records))
                (cmacs-brigade-dashboard--insert-row r c)))
            (insert (make-string (plist-get c :total) ?─) "\n"))
          (cmacs-brigade-dashboard--insert-panels)
          (insert "\n" (cmacs-brigade-dashboard--hints) "\n")
          (goto-char (point-min))
          (forward-line (1- line)))))))

(defun cmacs-brigade-dashboard--sort (records)
  "Live tasks first, then by id, so what is happening is at the top."
  (sort (copy-sequence records)
        (lambda (a b)
          (let ((la (memq (plist-get a :state) '(running starting waiting-input)))
                (lb (memq (plist-get b :state) '(running starting waiting-input))))
            (cond ((and la (not lb)) t)
                  ((and lb (not la)) nil)
                  (t (string< (or (plist-get a :id) "")
                              (or (plist-get b :id) ""))))))))

(defun cmacs-brigade-dashboard--insert-header (records)
  (let ((live (cl-count-if (lambda (r)
                             (memq (plist-get r :state)
                                   '(running starting waiting-input blocked)))
                           records))
        (spend (/ (cl-reduce #'+ records :key
                             (lambda (r) (or (plist-get r :cost-micros) 0))
                             :initial-value 0)
                  1000000.0)))
    (insert (format " brigade    live %d    spend $%.4f    %s\n"
                    live spend
                    (if (and (boundp 'cmacs-brigade-memory-enabled)
                             cmacs-brigade-memory-enabled)
                        (cmacs-brigade-dashboard--memory-summary)
                      "memory off")))))

(defun cmacs-brigade-dashboard--memory-summary ()
  (if (fboundp 'cmacs-brigade-memory-manifest)
      (let ((m (cmacs-brigade-memory-manifest)))
        (if m (format "idx %s chunks" (plist-get m :count)) "no index"))
    "memory unavailable"))

(defun cmacs-brigade-dashboard--insert-row (r &optional c)
  (let* ((c (or c (cmacs-brigade-dashboard--columns)))
         (state (plist-get r :state))
         (id (or (plist-get r :id) "?"))
         (agent (plist-get r :agent))
         (line (format (cmacs-brigade-dashboard--row-format c)
                       (cmacs-brigade-dashboard--glyph state)
                       (truncate-string-to-width id (plist-get c :id))
                       ;; The base name, not the internal `researcher@b12c7a46'
                       ;; that a per-task model override produces.
                       (truncate-string-to-width
                        (if agent
                            (format "%s" (cmacs-brigade-agent-base-name
                                          (intern agent)))
                          "—")
                        (plist-get c :agent))
                       (truncate-string-to-width
                        (cmacs-brigade-dashboard--model r)
                        (plist-get c :model))
                       (truncate-string-to-width
                        (or (plist-get r :title) id) (plist-get c :task))
                       (or (plist-get r :turns) 0)
                       (format "%s/%s" (or (plist-get r :in-tokens) 0)
                               (or (plist-get r :out-tokens) 0))
                       (format "$%.4f" (/ (or (plist-get r :cost-micros) 0)
                                          1000000.0)))))
    ;; The record travels with the row, so a command acts on what the
    ;; cursor is on rather than re-deriving it from the display.
    (insert (propertize line 'cmacs-brigade-record r) "\n")
    (when (plist-get r :error)
      (insert (propertize (format "     %s\n" (plist-get r :error))
                          'face 'error))
      ;; An error naming an agent is nearly always a definition that was
      ;; never loaded, and the fix is one key away -- say so rather than
      ;; leaving the message to be interpreted.
      (when (string-match-p "no agent definition" (plist-get r :error))
        (insert (propertize
                 (format "     %d definition(s) loaded; press A to reload, \
a to pick another\n"
                         (length (cmacs-brigade-registry-list 'agent)))
                 'face 'shadow))))))

(defun cmacs-brigade-dashboard--model (r)
  "The model R will actually run with, as a display string."
  (let* ((agent (plist-get r :agent))
         (def (and agent (cmacs-brigade-agent-get (intern agent)))))
    (or (plist-get def :model)
        (and (boundp 'cmacs-brigade-default-model) cmacs-brigade-default-model)
        "—")))

(defun cmacs-brigade-dashboard--insert-empty ()
  "What to show when there are no tasks: how to get one."
  (insert "\n  No tasks yet.\n\n")
  (insert "    c   create a plan and open it\n")
  (insert "    o   read what a finished task produced\n")
  (insert "    N   write a new agent definition\n")
  (insert "    p   open an existing plan\n")
  (insert "    ?   all keys\n\n")
  (let ((agents (cmacs-brigade-registry-list 'agent)))
    (insert (if agents
                (format "  %d agent definition(s): %s\n"
                        (length agents)
                        (mapconcat #'symbol-name agents ", "))
              (propertize
               "  No agent definitions loaded -- press A to reload.\n"
               'face 'warning)))))

(defun cmacs-brigade-dashboard--insert-panels ()
  "Render registered panels, lowest :order first."
  (dolist (name (sort (cmacs-brigade-registry-list 'panel)
                      (lambda (a b)
                        (< (or (plist-get (cmacs-brigade-registry-get 'panel a)
                                          :order) 50)
                           (or (plist-get (cmacs-brigade-registry-get 'panel b)
                                          :order) 50)))))
    (let ((p (cmacs-brigade-registry-get 'panel name)))
      (condition-case err
          (let ((lines (funcall (plist-get p :render))))
            (when lines
              (insert "\n " (propertize (or (plist-get p :title)
                                            (symbol-name name))
                                        'face 'bold) "\n")
              (dolist (l lines) (insert "   " l "\n"))))
        (error
         ;; A user panel that signals must not take the dashboard with
         ;; it -- the dashboard is how they would notice.
         (insert (propertize (format "\n [panel %s failed: %s]\n" name
                                     (error-message-string err))
                             'face 'error)))))))

(defun cmacs-brigade-dashboard--hints ()
  (concat " s start   K cancel  d delete   o output    RET plan\n"
          " a agent   m model   b budget   t tools      c new plan\n"
          " N new agent  T tool list  A reload agents   p open plan\n"
          " g refresh M memory  ? keys     q quit"))

(defun cmacs-brigade-dashboard--record-at-point ()
  (get-text-property (line-beginning-position) 'cmacs-brigade-record))


;;;; Commands
;;
;; Each one calls the same function the org side calls; the dashboard
;; has no privileged path into the runtime.

(defun cmacs-brigade-dashboard-start ()
  "Start the task on this line."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-at-point)))
    (unless r (user-error "No task on this line"))
    (cmacs-brigade-task-transition (plist-get r :id) 'queued)
    (cmacs-brigade-start-task (plist-get r :id))
    (cmacs-brigade-dashboard-refresh)))

(defun cmacs-brigade-dashboard-cancel ()
  "Cancel the task on this line."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-at-point)))
    (unless r (user-error "No task on this line"))
    (cmacs-brigade-cancel-task (plist-get r :id))
    (cmacs-brigade-dashboard-refresh)))

(defun cmacs-brigade-dashboard-visit ()
  "Jump to this task's headline in its plan."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-at-point)))
    (unless r (user-error "No task on this line"))
    (let ((plan (plist-get r :plan)))
      (if (and plan (file-exists-p plan))
          (progn (find-file-other-window plan)
                 (goto-char (point-min))
                 (when (fboundp 'org-id-goto)
                   (ignore-errors (org-id-goto (plist-get r :id)))))
        (user-error "No plan file for %s" (plist-get r :id))))))

(defun cmacs-brigade-dashboard-refresh ()
  "Redraw now."
  (interactive)
  (cmacs-brigade-dashboard--render))

(defun cmacs-brigade-dashboard-mark-dirty (&rest _)
  "Note that the dashboard is out of date and schedule a redraw."
  (setq cmacs-brigade-dashboard--dirty t)
  (unless cmacs-brigade-dashboard--timer
    (setq cmacs-brigade-dashboard--timer
          (run-with-idle-timer
           cmacs-brigade-dashboard-refresh-idle nil
           (lambda ()
             (setq cmacs-brigade-dashboard--timer nil)
             (when cmacs-brigade-dashboard--dirty
               (setq cmacs-brigade-dashboard--dirty nil)
               ;; Only when someone can see it: redrawing a buried
               ;; buffer eight times a second is pure waste.
               (when (get-buffer-window "*brigade*" t)
                 (cmacs-brigade-dashboard--render))))))))


;;;; Editing a task from the dashboard
;;
;; Every one of these writes the org headline and re-adopts, rather than
;; poking the runtime.  Org owns intent; the dashboard is a projection,
;; and a projection that could set a model the plan file did not know
;; about would be a second source of truth.

(defun cmacs-brigade-dashboard--set-property (r property value)
  "Set PROPERTY to VALUE on R's headline in its plan, and re-adopt."
  (let ((plan (plist-get r :plan))
        (id (plist-get r :id)))
    (unless (and plan (file-exists-p plan))
      (user-error "cmacs-brigade: this task has no plan file to edit"))
    (with-current-buffer (find-file-noselect plan)
      (let ((index (cmacs-brigade-plan--id-index)))
        (let ((marker (gethash id index)))
          (unless marker
            (user-error "cmacs-brigade: %s is not in %s" id plan))
          (save-excursion
            (goto-char marker)
            (if (and value (not (string-empty-p value)))
                (org-entry-put nil property value)
              (org-entry-delete nil property)))))
      (save-buffer)
      (cmacs-brigade-plan-adopt))
    (cmacs-brigade-dashboard-refresh)))

(defun cmacs-brigade-dashboard--record-or-error ()
  (or (cmacs-brigade-dashboard--record-at-point)
      (user-error "No task on this line")))

(defun cmacs-brigade-dashboard-set-agent ()
  "Set the agent for the task on this line."
  (interactive)
  (let* ((r (cmacs-brigade-dashboard--record-or-error))
         (agents (cmacs-brigade-registry-list 'agent)))
    (unless agents
      (user-error "cmacs-brigade: no agent definitions loaded; press A"))
    (cmacs-brigade-dashboard--set-property
     r "AGENT" (completing-read "Agent: " (mapcar #'symbol-name agents)
                                nil t))))

(defun cmacs-brigade-dashboard-set-model ()
  "Set the provider and model for the task on this line.

Provider first, then its models: the two are one string on the wire
\(`claude/claude-sonnet-4-6\='), but picking a model without first
narrowing to a provider means reading one list of everything."
  (interactive)
  (let* ((r (cmacs-brigade-dashboard--record-or-error))
         (provider (cmacs-brigade-dashboard--read-provider))
         (model (cmacs-brigade-dashboard--read-model provider)))
    (cmacs-brigade-dashboard--set-property
     r "MODEL" (if (string-empty-p model) "" (format "%s/%s" provider model)))))

(defun cmacs-brigade-dashboard--read-provider ()
  "Prompt for an AI provider."
  (let ((providers (if (fboundp 'cmacs-ai-providers)
                       (mapcar #'symbol-name (cmacs-ai-providers))
                     '("claude" "openai" "gemini" "grok" "ollama"
                       "claude-code" "opencode" "claude-tmux"))))
    (completing-read "Provider: " providers nil nil
                     (and (boundp 'cmacs-ai-default-provider)
                          (format "%s" cmacs-ai-default-provider)))))

(defun cmacs-brigade-dashboard--read-model (provider)
  "Prompt for a model offered by PROVIDER.

Completion, not a fixed set: a provider ships new model names between
cmacs releases, and a closed list would make the newest model the one
option the UI cannot express."
  (let ((models (and (fboundp 'cmacs-ai-list-models)
                     (ignore-errors
                       (mapcar (lambda (m) (format "%s" m))
                               (cmacs-ai-list-models (intern provider)))))))
    (completing-read (format "Model for %s (empty = provider default): "
                             provider)
                     models nil nil)))

(defun cmacs-brigade-dashboard-set-budget ()
  "Set the spend ceiling for the task on this line.  Empty or 0 means none."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-or-error)))
    (cmacs-brigade-dashboard--set-property
     r "BUDGET" (read-string "Budget in dollars (0 = no ceiling): " "0.00"))))

(defun cmacs-brigade-dashboard-set-tools ()
  "Set the tool allowlist for the task on this line."
  (interactive)
  (let* ((r (cmacs-brigade-dashboard--record-or-error))
         (tools (completing-read-multiple
                 "Tools (comma-separated, empty = agent default): "
                 (mapcar #'symbol-name
                         (cmacs-brigade-registry-list 'tool)))))
    (cmacs-brigade-dashboard--set-property
     r "TOOLS" (string-join tools ", "))))

(defun cmacs-brigade-dashboard-output ()
  "Show what the task on this line produced."
  (interactive)
  (let ((r (cmacs-brigade-dashboard--record-or-error)))
    (cmacs-brigade-output-show (plist-get r :id))))

(defun cmacs-brigade-dashboard-delete ()
  "Delete the task on this line, from the runtime and from its plan.

Both, because deleting only the runtime record leaves the headline to be
re-adopted on the next save, and deleting only the headline leaves a
record with nothing behind it."
  (interactive)
  (let* ((r (cmacs-brigade-dashboard--record-or-error))
         (id (plist-get r :id))
         (plan (plist-get r :plan))
         (title (or (plist-get r :title) id)))
    (when (y-or-n-p (format "Delete %s? " title))
      ;; A running task is stopped first: forgetting the record while the
      ;; process lives would orphan it, still spending.
      (when (memq (plist-get r :state) '(running starting queued))
        (ignore-errors (cmacs-brigade-cancel-task id)))
      (when (and plan (stringp plan) (file-exists-p plan))
        (with-current-buffer (find-file-noselect plan)
          (save-excursion
            (when-let* ((marker (gethash id (cmacs-brigade-plan--id-index))))
              (goto-char marker)
              (org-back-to-heading t)
              (org-cut-subtree)))
          (save-buffer)))
      (when (fboundp 'cmacs-brigade-task-forget)
        (cmacs-brigade-task-forget id))
      (cmacs-brigade-dashboard-refresh)
      (message "cmacs-brigade: deleted %s" title))))

(defun cmacs-brigade-dashboard-new-agent ()
  "Create a new agent definition."
  (interactive)
  (call-interactively #'cmacs-brigade-new-agent))

(defun cmacs-brigade-dashboard-list-tools ()
  "Show the tools an agent can be given."
  (interactive)
  (cmacs-brigade-list-tools))

(defun cmacs-brigade-dashboard-reload-agents ()
  "Re-read agent definitions from disk."
  (interactive)
  (let ((n (length (cmacs-brigade-agent-reload))))
    (cmacs-brigade-dashboard-refresh)
    (message "cmacs-brigade: %d agent definition(s): %s" n
             (mapconcat #'symbol-name
                        (cmacs-brigade-registry-list 'agent) ", "))))


;;;; Getting a plan in the first place

(defun cmacs-brigade-dashboard-new-plan (file title)
  "Create plan FILE titled TITLE and open it.

On the dashboard because creating a plan was otherwise a matter of
knowing that `cmacs-brigade-plan-create\=' exists and where plans live."
  (interactive
   (let* ((title (read-string "Plan title: "))
          (default (concat (replace-regexp-in-string
                            "[^a-z0-9]+" "-" (downcase title))
                           ".org")))
     (list (read-file-name "Plan file: "
                           (file-name-as-directory
                            cmacs-brigade-plan-directory)
                           nil nil default)
           title)))
  (cmacs-brigade-plan-create file title)
  (message "cmacs-brigade: edit the task, then C-c C-c (or save) to adopt it"))

(defun cmacs-brigade-dashboard-open-plan (file)
  "Open an existing plan."
  (interactive
   (list (read-file-name "Plan: " (file-name-as-directory
                                   cmacs-brigade-plan-directory)
                         nil t)))
  (find-file file)
  (when (fboundp 'cmacs-brigade-plan-mode) (cmacs-brigade-plan-mode 1)))

(defun cmacs-brigade-dashboard-help ()
  "Describe every dashboard key."
  (interactive)
  (describe-keymap 'cmacs-brigade-dashboard-mode-map))

(defvar cmacs-brigade-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'cmacs-brigade-dashboard-start)
    (define-key map (kbd "K") #'cmacs-brigade-dashboard-cancel)
    (define-key map (kbd "RET") #'cmacs-brigade-dashboard-visit)
    (define-key map (kbd "o") #'cmacs-brigade-dashboard-output)
    (define-key map (kbd "g") #'cmacs-brigade-dashboard-refresh)
    (define-key map (kbd "M") #'cmacs-brigade-memory-find)
    ;; Getting a plan without having to know where plans live.
    (define-key map (kbd "c") #'cmacs-brigade-dashboard-new-plan)
    (define-key map (kbd "p") #'cmacs-brigade-dashboard-open-plan)
    ;; Per-task intent.  Each writes the org headline and re-adopts.
    (define-key map (kbd "a") #'cmacs-brigade-dashboard-set-agent)
    (define-key map (kbd "m") #'cmacs-brigade-dashboard-set-model)
    (define-key map (kbd "b") #'cmacs-brigade-dashboard-set-budget)
    (define-key map (kbd "t") #'cmacs-brigade-dashboard-set-tools)
    (define-key map (kbd "A") #'cmacs-brigade-dashboard-reload-agents)
    (define-key map (kbd "d") #'cmacs-brigade-dashboard-delete)
    (define-key map (kbd "N") #'cmacs-brigade-dashboard-new-agent)
    (define-key map (kbd "T") #'cmacs-brigade-dashboard-list-tools)
    (define-key map (kbd "?") #'cmacs-brigade-dashboard-help)
    (define-key map (kbd "q") #'cmacs-brigade-dashboard-quit)
    ;; Evil's intercept map takes the buffer over completely, so motion
    ;; has to be bound explicitly to survive.
    (define-key map (kbd "j") #'next-line)
    (define-key map (kbd "k") #'previous-line)
    ;; Voice under `v', only in a build that can actually record.
    (when (fboundp 'cmacs-brigade-voice-setup-dashboard)
      (cmacs-brigade-voice-setup-dashboard map))
    map)
  "Keymap for `cmacs-brigade-dashboard-mode'.
Defined at top level and mutated in place, so reloading this file
updates buffers that are already open.")

(define-derived-mode cmacs-brigade-dashboard-mode special-mode "Brigade"
  "Watch the brigade's agents."
  (buffer-disable-undo)
  (setq truncate-lines t)
  (unless cmacs-brigade-dashboard--heartbeat
    (setq cmacs-brigade-dashboard--heartbeat
          (run-at-time cmacs-brigade-dashboard-heartbeat
                       cmacs-brigade-dashboard-heartbeat
                       (lambda ()
                         (when (get-buffer-window "*brigade*" t)
                           (cmacs-brigade-dashboard--render))))))
  (add-hook 'kill-buffer-hook
            (lambda ()
              (when cmacs-brigade-dashboard--heartbeat
                (cancel-timer cmacs-brigade-dashboard--heartbeat)
                (setq cmacs-brigade-dashboard--heartbeat nil)))
            nil t))

;; Mandatory for any single-key cmacs mode: without it s/K/g are eaten
;; by Evil's own bindings under Doom.
(cmacs-evil-setup-mode-map cmacs-brigade-dashboard-mode-map
                           'cmacs-brigade-dashboard-mode)

(defcustom cmacs-brigade-dashboard-display 'full-frame
  "How the dashboard takes over the screen.

`full-frame' gives it the whole frame and restores your layout when you
quit; `same-window' reuses the selected window and leaves the rest of the
layout alone; `other-window' is Emacs's default splitting behaviour.

`full-frame' is the default because the dashboard is a wide table plus
panels -- in half a frame the columns wrap and it becomes hard to read.
None of these ever create a window, which the old `pop-to-buffer' did on
every invocation from a single-window frame."
  :type '(choice (const :tag "Whole frame, restoring layout on quit" full-frame)
                 (const :tag "Reuse the selected window" same-window)
                 (const :tag "Split (Emacs default)" other-window))
  :group 'cmacs-brigade)

(defvar-local cmacs-brigade-dashboard--saved-layout nil
  "Window configuration to restore when this dashboard is quit.")

;;;###autoload
(defun cmacs-brigade-dashboard ()
  "Show the brigade dashboard.

Honours `cmacs-brigade-dashboard-display'; by default it takes the whole
frame and gives your layout back on `q'."
  (interactive)
  (let* ((buf (get-buffer-create "*brigade*"))
         ;; Captured before anything is displayed, so it is genuinely the
         ;; layout the user was looking at.
         (layout (current-window-configuration))
         ;; Likewise checked before displaying: whether the dashboard was
         ;; already on screen is what decides if this is a re-render or a
         ;; fresh open, and after `pop-to-buffer-same-window' it always
         ;; looks like the former.
         (already (get-buffer-window buf)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cmacs-brigade-dashboard-mode)
        (cmacs-brigade-dashboard-mode)))
    (cmacs-brigade-dashboard--render)
    (pcase cmacs-brigade-dashboard-display
      ('full-frame
       (pop-to-buffer-same-window buf)
       ;; Re-running the command while already looking at the dashboard
       ;; keeps the layout it originally replaced; opening it afresh
       ;; records the one being replaced now.  Keying this off the
       ;; stored value instead would restore a layout from some earlier
       ;; visit that was left by switching away rather than quitting.
       (unless already
         (setq cmacs-brigade-dashboard--saved-layout layout))
       (delete-other-windows))
      ('same-window (pop-to-buffer-same-window buf))
      (_ (pop-to-buffer buf)))
    buf))

(defun cmacs-brigade-dashboard-quit ()
  "Leave the dashboard, restoring the layout it replaced."
  (interactive)
  (let ((layout cmacs-brigade-dashboard--saved-layout))
    (setq cmacs-brigade-dashboard--saved-layout nil)
    (if (and layout (window-configuration-p layout))
        (progn (bury-buffer)
               (set-window-configuration layout))
      (quit-window))))

;;;###autoload
(defalias 'cmacs-brigade #'cmacs-brigade-dashboard)

(add-hook 'cmacs-brigade-run-finished-functions
          #'cmacs-brigade-dashboard-mark-dirty)

(provide 'cmacs-brigade-dashboard)

;;; cmacs-brigade-dashboard.el ends here
