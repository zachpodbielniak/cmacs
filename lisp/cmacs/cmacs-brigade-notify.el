;;; cmacs-brigade-notify.el --- Getting your attention  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The problem this solves is not "agents finish silently".  It is that
;; you walk away while one is running, and come back forty minutes after
;; it finished without knowing.  The forty minutes is the cost, and a
;; notification fired at the moment of completion does not recover it:
;; you were not there to hear it.
;;
;; So there are three mechanisms, and the third is the one that matters:
;;
;;   1. Notify when it happens.  Customisable through the same registry
;;      shape as everything else in the brigade -- speak, sound, desktop,
;;      run a script, print a receipt, or your own.
;;
;;   2. Escalate what is *blocked*.  A finished agent costs you nothing
;;      by waiting; one that is waiting on an answer is burning
;;      wall-clock doing nothing, so it repeats, and gets more insistent.
;;
;;   3. Tell you what happened while you were gone.  Events that fire
;;      while you are away are held, and delivered the moment you come
;;      back -- which is the first command you run after a long idle.
;;      That is the mechanism that actually closes the gap, because it
;;      does not require you to have been present.
;;
;; Plus a modeline indicator, so "is anything still running" is
;; answerable by glancing rather than by remembering to check.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-brigade-notify nil
  "How the brigade gets your attention."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-notify-")

(defcustom cmacs-brigade-notify-enabled t
  "Whether the brigade notifies you at all."
  :type 'boolean
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-routes
  '((needs-input     . (speak desktop sound))
    (failed          . (speak desktop))
    (budget-exceeded . (speak desktop))
    (finished        . (sound message))
    (all-done        . (speak))
    (started         . ())
    ;; Used for a non-urgent event that fires while you are away.  Quiet,
    ;; because you are not there to hear it: it will be in the digest
    ;; when you return, and this only exists in case you are in earshot.
    (away-quiet      . (sound)))
  "Which notifiers fire for each kind of event.

The defaults are deliberately uneven.  Something that needs *you* is
worth interrupting for on every channel; a single agent finishing among
several is worth a sound and nothing more, because a spoken sentence per
completion during a fan-out is unbearable.  `all-done' -- the last agent
finishing -- is the one worth saying out loud.

Recognised kinds: started, finished, failed, needs-input,
budget-exceeded, all-done.  Values name registered notifiers; see
`cmacs-brigade-register-notifier'."
  :type '(alist :key-type symbol :value-type (repeat symbol))
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-away-seconds 120
  "Idle seconds after which you are treated as away.

While away, events are held rather than announced, and delivered as a
digest when you return.  Two minutes is short enough to catch stepping
out for coffee and long enough not to fire because you read a paragraph."
  :type 'integer
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-digest-on-return t
  "Whether to summarise what happened while you were away.

The reason this file exists.  Turning it off leaves you relying on
having been present when something fired."
  :type 'boolean
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-digest-speak t
  "Whether the welcome-back digest is spoken as well as shown.

Worth leaving on: you are looking at whatever you came back to do, not
at the echo area."
  :type 'boolean
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-escalate-seconds '(60 300 900)
  "When to re-announce an unacknowledged `needs-input', in seconds.

Increasing gaps: insistent enough not to be forgotten, spaced enough not
to become noise you learn to ignore.  Set to nil to never repeat."
  :type '(repeat integer)
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-sound-file nil
  "Sound played by the `sound' notifier.  nil uses a freedesktop theme sound."
  :type '(choice (const :tag "Theme sound" nil) file)
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-command nil
  "Program run by the `command' notifier.

Receives the event as environment: BRIGADE_EVENT, BRIGADE_TASK,
BRIGADE_AGENT, BRIGADE_STATE, BRIGADE_TEXT.  Run detached, so a slow
script cannot stall the editor."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-voice nil
  "Piper voice used by the `speak' notifier.  nil uses the default."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-brigade-notify)

(defcustom cmacs-brigade-notify-modeline t
  "Whether to show live agent counts in the modeline."
  :type 'boolean
  :group 'cmacs-brigade-notify)


;;;; The notifier registry
;;
;; Same shape as every other brigade registry, so adding a channel is the
;; same gesture as adding a tool.

(cmacs-brigade--define-registry notifier (:notify)
  "Register a way of getting the user's attention, from PLIST.

Recognised keys: :name, :notify (called with an event plist), :available
\(optional predicate; an unavailable notifier is skipped rather than
erroring).

The event plist carries :kind, :task, :agent, :state, :text and :urgent.

  (cmacs-brigade-register-notifier
   :name \\='pushover
   :notify (lambda (ev) (my/push (plist-get ev :text))))

Then route to it:

  (setf (alist-get \\='needs-input cmacs-brigade-notify-routes)
        \\='(speak pushover))")


;;;; Shipped notifiers

(defun cmacs-brigade-notify--message (ev)
  (message "cmacs-brigade: %s" (plist-get ev :text)))

(cmacs-brigade-register-notifier
 :name 'message
 :notify #'cmacs-brigade-notify--message)

(defun cmacs-brigade-notify--speak (ev)
  (when (and (fboundp 'cmacs-piper-supported-p) (cmacs-piper-supported-p))
    ;; Async: speaking is seconds long and this runs from a process
    ;; sentinel.  Blocking here would stall whatever else is finishing.
    (cmacs-piper-speak-async (plist-get ev :text) nil
                             cmacs-brigade-notify-voice)))

(cmacs-brigade-register-notifier
 :name 'speak
 :notify #'cmacs-brigade-notify--speak
 :available (lambda () (and (fboundp 'cmacs-piper-supported-p)
                            (cmacs-piper-supported-p))))

(defun cmacs-brigade-notify--sound (ev)
  (let ((urgent (plist-get ev :urgent)))
    (cond
     (cmacs-brigade-notify-sound-file
      (cmacs-brigade-notify--spawn
       (list (or (executable-find "paplay") (executable-find "ffplay"))
             cmacs-brigade-notify-sound-file)))
     ((executable-find "canberra-gtk-play")
      (cmacs-brigade-notify--spawn
       (list "canberra-gtk-play" "-i"
             (if urgent "dialog-warning" "complete")))))))

(cmacs-brigade-register-notifier
 :name 'sound
 :notify #'cmacs-brigade-notify--sound
 :available (lambda () (or cmacs-brigade-notify-sound-file
                           (executable-find "canberra-gtk-play")
                           (executable-find "paplay"))))

(defun cmacs-brigade-notify--desktop (ev)
  (cmacs-brigade-notify--spawn
   (list "notify-send"
         "--app-name=cmacs"
         (format "--urgency=%s" (if (plist-get ev :urgent) "critical" "normal"))
         ;; A needs-input notification that times out is one you can miss
         ;; by being in another window, which is the whole failure mode.
         (if (plist-get ev :urgent) "--expire-time=0" "--expire-time=8000")
         "cmacs brigade"
         (plist-get ev :text))))

(cmacs-brigade-register-notifier
 :name 'desktop
 :notify #'cmacs-brigade-notify--desktop
 :available (lambda () (executable-find "notify-send")))

(defun cmacs-brigade-notify--command (ev)
  (when cmacs-brigade-notify-command
    (let ((process-environment
           (append (list (format "BRIGADE_EVENT=%s" (plist-get ev :kind))
                         (format "BRIGADE_TASK=%s" (or (plist-get ev :task) ""))
                         (format "BRIGADE_AGENT=%s" (or (plist-get ev :agent) ""))
                         (format "BRIGADE_STATE=%s" (or (plist-get ev :state) ""))
                         (format "BRIGADE_TEXT=%s" (or (plist-get ev :text) "")))
                   process-environment)))
      (cmacs-brigade-notify--spawn (list cmacs-brigade-notify-command)))))

(cmacs-brigade-register-notifier
 :name 'command
 :notify #'cmacs-brigade-notify--command
 :available (lambda () (and cmacs-brigade-notify-command t)))

(defun cmacs-brigade-notify--receipt (ev)
  (cmacs-brigade-notify--spawn
   (list "receipt-print" "--title" "cmacs brigade"
         "--text" (plist-get ev :text))))

(cmacs-brigade-register-notifier
 :name 'receipt
 :notify #'cmacs-brigade-notify--receipt
 :available (lambda () (executable-find "receipt-print")))

(defun cmacs-brigade-notify--spawn (argv)
  "Run ARGV detached, discarding output.

Detached because a notifier is called from a process sentinel: a script
that blocks would stall the run that is trying to report it, and under
`--gowl' that is the compositor."
  (when (car argv)
    (ignore-errors
      (let ((proc (make-process :name "brigade-notify"
                                :command argv
                                :buffer nil
                                :noquery t
                                :connection-type 'pipe)))
        (set-process-sentinel proc #'ignore)
        proc))))


;;;; Away detection
;;
;; "Away" means you were not looking at Emacs.  Idle time is the right
;; proxy: whether you left the room or were in a browser, you did not see
;; the notification either way.

(defvar cmacs-brigade-notify--last-activity (float-time)
  "When a command last ran.")

(defvar cmacs-brigade-notify--held nil
  "Events that fired while you were away, oldest first.")

(defvar cmacs-brigade-notify-digest-functions nil
  "Abnormal hook run with the held events when you return.

Lets a user route the digest somewhere else -- a receipt, a Matrix
message, an org capture -- without replacing the shipped behaviour.")

(defvar cmacs-brigade-notify--pending-input (make-hash-table :test 'equal)
  "TASK-ID -> plist for unacknowledged needs-input events.")

(defun cmacs-brigade-notify-away-p ()
  "Whether you are currently treated as away."
  (> (- (float-time) cmacs-brigade-notify--last-activity)
     cmacs-brigade-notify-away-seconds))

(defun cmacs-brigade-notify--post-command ()
  "Note activity, and deliver a digest if we have just come back."
  (let* ((now (float-time))
         (gap (- now cmacs-brigade-notify--last-activity)))
    (setq cmacs-brigade-notify--last-activity now)
    ;; This is the moment of return: the first command after a long
    ;; silence.  Everything held gets delivered now, which is the point
    ;; of holding it.
    (when (and cmacs-brigade-notify-digest-on-return
               (> gap cmacs-brigade-notify-away-seconds)
               cmacs-brigade-notify--held)
      (cmacs-brigade-notify--deliver-digest gap))))

(defun cmacs-brigade-notify--deliver-digest (gap)
  "Report the held events, which accumulated over GAP seconds."
  (let* ((events (nreverse cmacs-brigade-notify--held))
         (text (cmacs-brigade-notify--digest-text events gap)))
    (setq cmacs-brigade-notify--held nil)
    (message "%s" text)
    (when (and cmacs-brigade-notify-digest-speak
               (fboundp 'cmacs-piper-supported-p)
               (cmacs-piper-supported-p))
      (cmacs-piper-speak-async text nil cmacs-brigade-notify-voice))
    ;; Shown as well as said: a spoken summary is gone as soon as it
    ;; finishes, and you may want to read which task it was.
    (cmacs-brigade-notify--show-digest events gap)
    (run-hook-with-args 'cmacs-brigade-notify-digest-functions events)))

(defun cmacs-brigade-notify--digest-text (events gap)
  "One sentence summarising EVENTS over GAP seconds."
  (let ((finished (cl-count 'finished events :key (lambda (e) (plist-get e :kind))))
        (failed (cl-count 'failed events :key (lambda (e) (plist-get e :kind))))
        (waiting (hash-table-count cmacs-brigade-notify--pending-input))
        (mins (round (/ gap 60.0))))
    (concat
     (format "While you were away (%d min): " mins)
     (string-join
      (delq nil
            (list (when (> finished 0) (format "%d finished" finished))
                  (when (> failed 0) (format "%d failed" failed))
                  ;; Said last and phrased as a demand, because it is the
                  ;; only part that still needs something from you.
                  (when (> waiting 0)
                    (format "%d waiting for you" waiting))))
      ", ")
     ".")))

(defun cmacs-brigade-notify--show-digest (events gap)
  "Display EVENTS in a buffer."
  (with-current-buffer (get-buffer-create "*brigade: while you were away*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (propertize (cmacs-brigade-notify--digest-text events gap)
                          'face 'bold)
              "\n" (make-string 64 ?-) "\n\n")
      (dolist (e events)
        (insert (format "  %-14s %-12s %s\n"
                        (plist-get e :kind)
                        (or (plist-get e :agent) "")
                        (or (plist-get e :text) ""))))
      (when (> (hash-table-count cmacs-brigade-notify--pending-input) 0)
        (insert "\n" (propertize "Still waiting on you:\n" 'face 'warning))
        (maphash (lambda (id ev)
                   (insert (format "  %s  %s\n" id (plist-get ev :text))))
                 cmacs-brigade-notify--pending-input))
      (goto-char (point-min)))
    (special-mode)
    (display-buffer (current-buffer))))


;;;; Escalation

(defvar cmacs-brigade-notify--escalation-timers nil)

(defun cmacs-brigade-notify--schedule-escalation (ev)
  "Re-announce EV until it is acknowledged."
  (let ((id (plist-get ev :task)))
    (puthash id ev cmacs-brigade-notify--pending-input)
    (dolist (secs cmacs-brigade-notify-escalate-seconds)
      (push (run-at-time
             secs nil
             (lambda ()
               ;; Only if still unanswered.  A repeat after you have
               ;; already dealt with it teaches you to ignore the sound.
               (when (gethash id cmacs-brigade-notify--pending-input)
                 (cmacs-brigade-notify--dispatch
                  (plist-put (copy-sequence ev) :urgent t)
                  'needs-input))))
            cmacs-brigade-notify--escalation-timers))))

(defun cmacs-brigade-notify-acknowledge (task-id)
  "Note that TASK-ID no longer needs you, and stop escalating it."
  (interactive "sTask id: ")
  (remhash task-id cmacs-brigade-notify--pending-input))

(defun cmacs-brigade-notify-pending ()
  "Return the tasks currently waiting on you."
  (let (out)
    (maphash (lambda (id ev) (push (cons id ev) out))
             cmacs-brigade-notify--pending-input)
    (nreverse out)))


;;;; Dispatch

(defun cmacs-brigade-notify--dispatch (ev kind)
  "Send EV to the notifiers routed for KIND."
  (dolist (name (alist-get kind cmacs-brigade-notify-routes))
    (let ((n (cmacs-brigade-registry-get 'notifier name)))
      (when n
        (let ((avail (plist-get n :available)))
          (when (or (null avail) (ignore-errors (funcall avail)))
            (condition-case err
                (funcall (plist-get n :notify) ev)
              (error
               ;; One broken channel must not cost you the others -- and
               ;; the whole point is that you find out something happened.
               (message "cmacs-brigade: notifier %s failed: %s"
                        name (error-message-string err))))))))))

(defun cmacs-brigade-notify (kind &rest props)
  "Announce a KIND event described by PROPS.

Held rather than announced when you are away, unless it needs you --
those escalate instead, so they are still waiting when you return."
  (when cmacs-brigade-notify-enabled
    (let* ((ev (append (list :kind kind
                             :urgent (memq kind '(needs-input failed
                                                  budget-exceeded)))
                       props))
           (ev (plist-put ev :text (or (plist-get ev :text)
                                       (cmacs-brigade-notify--describe ev)))))
      (when (eq kind 'needs-input)
        (cmacs-brigade-notify--schedule-escalation ev))
      (if (cmacs-brigade-notify-away-p)
          ;; Held for the digest.  Still fired on the channels that reach
          ;; you when you are not at the keyboard, since those are the
          ;; ones that might actually bring you back.
          (progn
            (push ev cmacs-brigade-notify--held)
            (cmacs-brigade-notify--dispatch
             ev (if (plist-get ev :urgent) kind 'away-quiet)))
        (cmacs-brigade-notify--dispatch ev kind))
      ev)))

(defun cmacs-brigade-notify--describe (ev)
  "A sentence for EV, phrased to be heard rather than read."
  (let ((agent (or (plist-get ev :agent) "an agent"))
        (task (or (plist-get ev :task) "")))
    (pcase (plist-get ev :kind)
      ('finished (format "%s finished." agent))
      ('failed (format "%s failed. %s" agent (or (plist-get ev :error) "")))
      ('needs-input (format "%s needs your input." agent))
      ('budget-exceeded (format "%s stopped: over budget." agent))
      ('all-done "All agents have finished.")
      ('started (format "%s started." agent))
      (_ (format "%s: %s" (plist-get ev :kind) task)))))


;;;; Wiring

(defun cmacs-brigade-notify--on-run-finished (task-id state &optional _output)
  "Announce that TASK-ID reached STATE."
  (let* ((rec (and (fboundp 'cmacs-brigade-task-get)
                   (cmacs-brigade-task-get task-id)))
         (agent (or (plist-get rec :agent) task-id)))
    (cmacs-brigade-notify
     (pcase state
       ('done 'finished)
       ('over-budget 'budget-exceeded)
       (_ 'failed))
     :task task-id :agent agent :state state
     :error (plist-get rec :error))
    ;; Whatever it was, it is no longer waiting on us.
    (cmacs-brigade-notify-acknowledge task-id)
    ;; The last one finishing is worth saying out loud even when a single
    ;; completion is not -- it means the whole fan-out is done.
    (when (and (fboundp 'cmacs-brigade-live-count)
               (zerop (cmacs-brigade-live-count)))
      (cmacs-brigade-notify 'all-done))))

(defun cmacs-brigade-notify--on-transition (task-id state &rest _)
  "Announce TASK-ID entering STATE, for the non-terminal states.

`cmacs-brigade-run-finished-functions' only fires when a run ends, so a
task that stops to ask you something would otherwise be the one event
that never reaches you -- exactly backwards, since a blocked agent is
the only kind that is costing you time by waiting.

Advice rather than a hook at each call site: `cmacs-brigade-task-transition'
is a C DEFUN called from the runner, the dashboard and the plan buffer,
and observing it in one place also covers callers added later."
  (when (memq state '(waiting-input blocked))
    (let* ((rec (ignore-errors (cmacs-brigade-task-get task-id)))
           (agent (or (plist-get rec :agent) task-id)))
      (cmacs-brigade-notify 'needs-input
                            :task task-id :agent agent :state state
                            :text (or (plist-get rec :question)
                                      (format "%s needs your input." agent)))))
  ;; Any other transition means it is no longer blocked on us.
  (unless (memq state '(waiting-input blocked))
    (cmacs-brigade-notify-acknowledge task-id))
  (cmacs-brigade-notify--update-modeline))

(defvar cmacs-brigade-notify--modeline ""
  "Modeline string, recomputed as agents change.")

(defun cmacs-brigade-notify--update-modeline (&rest _)
  "Refresh the live-agent indicator."
  (setq cmacs-brigade-notify--modeline
        (if (not cmacs-brigade-notify-modeline) ""
          (let ((live (if (fboundp 'cmacs-brigade-live-count)
                          (cmacs-brigade-live-count) 0))
                (waiting (hash-table-count cmacs-brigade-notify--pending-input)))
            (cond
             ;; Waiting on you is the state worth colouring: an agent
             ;; that is blocked is spending wall-clock on nothing.
             ((> waiting 0)
              (propertize (format " brigade:%d?" waiting) 'face 'warning))
             ((> live 0) (format " brigade:%d" live))
             (t "")))))
  (force-mode-line-update t))

;;;###autoload
(define-minor-mode cmacs-brigade-notify-mode
  "Let the brigade tell you when something finishes or needs you.

Also summarises what happened while you were away, which is the part
that recovers the time otherwise lost to coming back and finding a run
finished half an hour ago."
  :global t
  :group 'cmacs-brigade-notify
  (if cmacs-brigade-notify-mode
      (progn
        (add-hook 'post-command-hook #'cmacs-brigade-notify--post-command)
        (add-hook 'cmacs-brigade-run-finished-functions
                  #'cmacs-brigade-notify--on-run-finished)
        (add-hook 'cmacs-brigade-run-finished-functions
                  #'cmacs-brigade-notify--update-modeline)
        (when (fboundp 'cmacs-brigade-task-transition)
          (advice-add 'cmacs-brigade-task-transition :after
                      #'cmacs-brigade-notify--on-transition))
        (add-to-list 'global-mode-string
                     '(:eval cmacs-brigade-notify--modeline) t)
        (cmacs-brigade-notify--update-modeline))
    (remove-hook 'post-command-hook #'cmacs-brigade-notify--post-command)
    (remove-hook 'cmacs-brigade-run-finished-functions
                 #'cmacs-brigade-notify--on-run-finished)
    (remove-hook 'cmacs-brigade-run-finished-functions
                 #'cmacs-brigade-notify--update-modeline)
    (when (fboundp 'cmacs-brigade-task-transition)
      (advice-remove 'cmacs-brigade-task-transition
                     #'cmacs-brigade-notify--on-transition))
    (setq global-mode-string
          (delete '(:eval cmacs-brigade-notify--modeline) global-mode-string))))

;;;###autoload
(defun cmacs-brigade-notify-status ()
  "Say what the brigade is doing right now.

The question you would otherwise answer by remembering to look."
  (interactive)
  (let* ((live (if (fboundp 'cmacs-brigade-live-count)
                   (cmacs-brigade-live-count) 0))
         (waiting (hash-table-count cmacs-brigade-notify--pending-input))
         (text (cond
                ((and (zerop live) (zerop waiting)) "Nothing is running.")
                ((> waiting 0)
                 (format "%d running, %d waiting for you." live waiting))
                (t (format "%d running." live)))))
    (message "%s" text)
    (when (and (called-interactively-p 'any)
               cmacs-brigade-notify-digest-speak
               (fboundp 'cmacs-piper-supported-p)
               (cmacs-piper-supported-p))
      (cmacs-piper-speak-async text nil cmacs-brigade-notify-voice))
    text))

(provide 'cmacs-brigade-notify)

;;; cmacs-brigade-notify.el ends here
