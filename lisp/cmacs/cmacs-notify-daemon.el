;;; cmacs-notify-daemon.el --- A notification daemon inside Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; cmacs ships three things that send desktop notifications and, under
;; gowl, nothing that receives them.  `cmacs-notify' calls
;; org.freedesktop.Notifications over D-Bus; `cmacs-brigade-notify' and
;; podomation's cmacs module both shell out to notify-send, which is
;; the same D-Bus client by another route.  In a GNOME session GNOME
;; Shell owns that name.  In a gowl session nothing does, so all three
;; fail silently -- including gnuseye's `critical' alerts and the
;; brigade's away digest, which exists precisely to reach you when you
;; are not looking.
;;
;; This claims the name and implements the freedesktop specification,
;; so every libnotify application works too.
;;
;; The design is the one only this stack can build: a notification is
;; an entry in an Org buffer, not a toast that vanishes.  History is
;; searchable, foldable, exportable and survives the notification's
;; timeout; the echo area gets the transient part.  A notification's
;; actions are buttons in that buffer, so "reply" or "open" on a
;; message from any application is a keypress in Emacs.
;;
;; It will not take the name from an existing owner.  Under GNOME,
;; enabling this is a no-op with a message saying who has it.

;;; Code:

(require 'dbus)
(require 'cl-lib)
(require 'subr-x)
;; The history buffer derives from Org, so Org is a hard requirement
;; here rather than something the mode pulls in when first shown: a
;; notification can arrive before anyone looks at the buffer.
(require 'org)

(defgroup cmacs-notify-daemon nil
  "A freedesktop notification daemon implemented in Emacs."
  :group 'cmacs
  :prefix "cmacs-notify-daemon-")

(defconst cmacs-notify-daemon-service "org.freedesktop.Notifications"
  "The well-known name a notification daemon owns.")

(defconst cmacs-notify-daemon-path "/org/freedesktop/Notifications"
  "The object path the specification requires.")

(defconst cmacs-notify-daemon-interface "org.freedesktop.Notifications"
  "The interface name, which the specification makes equal to the service.")

(defconst cmacs-notify-daemon-spec-version "1.2"
  "The version of the freedesktop notification specification implemented.")

;;; Customization

(defcustom cmacs-notify-daemon-buffer "*notifications*"
  "Buffer holding notification history."
  :type 'string
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-history-limit 200
  "Number of notifications kept in history.
Older ones are dropped from `cmacs-notify-daemon-history' and from the
history buffer when it is next rendered."
  :type 'integer
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-default-timeout 5000
  "Milliseconds a notification stays active when the sender asks for the
daemon's default (an expire timeout of -1).

Expiry only closes the notification and emits NotificationClosed; the
history entry stays.  That is the point of keeping history in a buffer
rather than a toast stack."
  :type 'integer
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-echo t
  "When non-nil, show each arriving notification in the echo area."
  :type 'boolean
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-echo-urgencies '(normal critical)
  "Urgencies that reach the echo area when `cmacs-notify-daemon-echo'.
Low-urgency notifications are usually chatter -- a track change, a
finished download -- and still land in history."
  :type '(repeat symbol)
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-pop-to-buffer-urgencies '(critical)
  "Urgencies that additionally display the history buffer on arrival.
Critical notifications are the ones a specification says must not be
missed, and an echo-area line can be missed."
  :type '(repeat symbol)
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-log-file nil
  "Org file each notification is appended to, or nil for no file log.
The in-memory history is capped; a file is not, so set this when you
want notifications to outlive the session."
  :type '(choice (const :tag "No file log" nil) file)
  :group 'cmacs-notify-daemon)

(defcustom cmacs-notify-daemon-functions nil
  "Hook run with one argument, the plist of an arriving notification.
Keys are :id, :app, :summary, :body, :urgency, :icon, :actions,
:hints, :timeout and :time.  Run before the notification is displayed,
so a function here can act on it -- speak it, print it, forward it --
without waiting for the user."
  :type 'hook
  :group 'cmacs-notify-daemon)

;;; State

(defvar cmacs-notify-daemon--registered nil
  "Non-nil when the service name is currently held by this Emacs.")

(defvar cmacs-notify-daemon--objects nil
  "Registration objects returned by `dbus-register-method', for release.")

(defvar cmacs-notify-daemon--next-id 1
  "Next notification id to hand out.
The specification requires a non-zero unsigned 32-bit value.")

(defvar cmacs-notify-daemon-history nil
  "List of notification plists, newest first.")

(defvar cmacs-notify-daemon--active (make-hash-table :test #'eql)
  "Live notifications by id, mapping to their expiry timer or nil.
A notification leaves this table when it expires, is dismissed, or is
closed by its sender; its history entry stays.")

;;; Helpers

(defun cmacs-notify-daemon--urgency (hints)
  "Return the urgency symbol carried by HINTS, defaulting to `normal'.
The hint is a byte: 0 low, 1 normal, 2 critical."
  (let ((raw (cadr (assoc "urgency" hints))))
    ;; The value arrives wrapped as a variant, which dbus.el unwraps to
    ;; a one-element list, and different senders send it as a byte or
    ;; as an integer.  Reduce whatever arrives to a number.
    (while (and (consp raw) raw) (setq raw (car raw)))
    (pcase raw
      (0 'low)
      (2 'critical)
      (_ 'normal))))

(defun cmacs-notify-daemon--hint (hints key)
  "Return the scalar value of HINTS entry KEY, unwrapping variants."
  (let ((raw (cadr (assoc key hints))))
    (while (and (consp raw) raw) (setq raw (car raw)))
    raw))

(defun cmacs-notify-daemon--parse-actions (actions)
  "Turn the flat ACTIONS array into a list of (KEY . LABEL).
The specification sends them as alternating key and label strings.  An
odd-length array is malformed; the trailing key is dropped rather than
consing a nil label onto it."
  (let (out)
    (while (and actions (cdr actions))
      (push (cons (car actions) (cadr actions)) out)
      (setq actions (cddr actions)))
    (nreverse out)))

(defun cmacs-notify-daemon--find (id)
  "Return the history entry for notification ID, or nil."
  (cl-find id cmacs-notify-daemon-history
           :key (lambda (n) (plist-get n :id))))

;;; Emitting the specification's signals

(defun cmacs-notify-daemon--emit-closed (id reason)
  "Emit NotificationClosed for ID with REASON.
REASON is 1 expired, 2 dismissed by the user, 3 closed by a
CloseNotification call, 4 undefined."
  (ignore-errors
    (dbus-send-signal
     :session nil cmacs-notify-daemon-path
     cmacs-notify-daemon-interface "NotificationClosed"
     :uint32 id :uint32 reason)))

(defun cmacs-notify-daemon--emit-action (id key)
  "Emit ActionInvoked for notification ID with action KEY."
  (ignore-errors
    (dbus-send-signal
     :session nil cmacs-notify-daemon-path
     cmacs-notify-daemon-interface "ActionInvoked"
     :uint32 id :string key)))

;;; Closing

(defun cmacs-notify-daemon--close (id reason)
  "Close notification ID with REASON, cancelling any expiry timer.

Idempotent: closing an already-closed notification emits nothing, so a
sender that calls CloseNotification on one the user already dismissed
does not get a second signal.

Presence is tested with an explicit default rather than by the stored
value, because a notification that never expires is stored with a nil
timer -- and nil is exactly what an absent key would look like."
  (let ((entry (gethash id cmacs-notify-daemon--active 'missing)))
    (unless (eq entry 'missing)
      (when (timerp entry) (cancel-timer entry))
      (remhash id cmacs-notify-daemon--active)
      (cmacs-notify-daemon--emit-closed id reason))))

;;; Rendering

(defvar cmacs-notify-daemon-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'cmacs-notify-daemon-refresh)
    (define-key map (kbd "d") #'cmacs-notify-daemon-dismiss-at-point)
    (define-key map (kbd "a") #'cmacs-notify-daemon-invoke-action-at-point)
    (define-key map (kbd "k") #'cmacs-notify-daemon-clear)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-notify-daemon-mode'.")

(define-derived-mode cmacs-notify-daemon-mode org-mode "Notifications"
  "Major mode for the notification history buffer.

Derived from Org so the history is foldable, searchable and
exportable, which a toast stack is not.  Each notification is a
headline; its actions are listed under it and can be invoked with
\\[cmacs-notify-daemon-invoke-action-at-point], which sends
ActionInvoked back to the application that sent it."
  (setq buffer-read-only t)
  (setq-local org-startup-folded nil))

(defun cmacs-notify-daemon--entry-string (n)
  "Render notification plist N as an Org entry."
  (let* ((urg (plist-get n :urgency))
         (actions (plist-get n :actions))
         (body (plist-get n :body))
         (id (plist-get n :id)))
    (concat
     (format "* %s%s\n"
             (plist-get n :summary)
             (pcase urg
               ('critical "  :critical:")
               ('low      "  :low:")
               (_         "")))
     ":PROPERTIES:\n"
     (format ":ID-NUM:   %d\n" id)
     (format ":APP:      %s\n" (plist-get n :app))
     (format ":URGENCY:  %s\n" urg)
     (format ":TIME:     %s\n"
             (format-time-string "%Y-%m-%dT%H:%M:%S%z" (plist-get n :time)))
     (if (gethash id cmacs-notify-daemon--active)
         ":STATE:    active\n"
       ":STATE:    closed\n")
     ":END:\n"
     (if (and body (not (string-empty-p body)))
         (concat body "\n")
       "")
     (if actions
         (concat "\n"
                 (mapconcat
                  (lambda (a)
                    (format "  - [[elisp:(cmacs-notify-daemon-invoke-action %d \"%s\")][%s]]"
                            id (car a) (cdr a)))
                  actions "\n")
                 "\n")
       "")
     "\n")))

(defun cmacs-notify-daemon-refresh ()
  "Re-render the notification history buffer."
  (interactive)
  (with-current-buffer (get-buffer-create cmacs-notify-daemon-buffer)
    (unless (derived-mode-p 'cmacs-notify-daemon-mode)
      (cmacs-notify-daemon-mode))
    (let ((inhibit-read-only t)
          (line (line-number-at-pos)))
      (erase-buffer)
      (if (null cmacs-notify-daemon-history)
          (insert "#+title: Notifications\n\nNothing yet.\n")
        (insert "#+title: Notifications\n\n")
        (dolist (n cmacs-notify-daemon-history)
          (insert (cmacs-notify-daemon--entry-string n))))
      (goto-char (point-min))
      (forward-line (1- line)))
    (current-buffer)))

;;;###autoload
(defun cmacs-notify-daemon-history-buffer ()
  "Show the notification history."
  (interactive)
  (pop-to-buffer (cmacs-notify-daemon-refresh)))

(defun cmacs-notify-daemon--id-at-point ()
  "Return the notification id of the entry at point, or nil."
  (save-excursion
    (when (or (org-at-heading-p) (org-back-to-heading t))
      (let ((v (org-entry-get (point) "ID-NUM")))
        (and v (string-to-number v))))))

(defun cmacs-notify-daemon-dismiss-at-point ()
  "Close the notification at point as dismissed by the user."
  (interactive)
  (let ((id (cmacs-notify-daemon--id-at-point)))
    (unless id (user-error "No notification at point"))
    ;; Reason 2 is the specification's "dismissed by the user", which
    ;; is what an application distinguishes from a timeout when
    ;; deciding whether to send the same thing again.
    (cmacs-notify-daemon--close id 2)
    (cmacs-notify-daemon-refresh)))

(defun cmacs-notify-daemon-invoke-action (id key)
  "Send ActionInvoked for notification ID and action KEY."
  (cmacs-notify-daemon--emit-action id key)
  (message "Sent action %s for notification %d" key id))

(defun cmacs-notify-daemon-invoke-action-at-point ()
  "Invoke one of the actions on the notification at point."
  (interactive)
  (let* ((id (cmacs-notify-daemon--id-at-point))
         (n (and id (cmacs-notify-daemon--find id)))
         (actions (and n (plist-get n :actions))))
    (unless id (user-error "No notification at point"))
    (unless actions (user-error "That notification has no actions"))
    (let* ((choice (completing-read "Action: " (mapcar #'cdr actions) nil t))
           (key (car (cl-find choice actions :key #'cdr :test #'equal))))
      (cmacs-notify-daemon-invoke-action id key))))

(defun cmacs-notify-daemon-clear ()
  "Clear notification history.
Active notifications are closed first, so their senders are told."
  (interactive)
  (maphash (lambda (id _timer) (cmacs-notify-daemon--close id 2))
           (copy-hash-table cmacs-notify-daemon--active))
  (setq cmacs-notify-daemon-history nil)
  (cmacs-notify-daemon-refresh))

;;; Delivery

(defun cmacs-notify-daemon--echo (n)
  "Show notification N in the echo area."
  (let ((body (plist-get n :body)))
    (message "%s%s%s"
             (if (string-empty-p (or (plist-get n :app) ""))
                 "" (format "[%s] " (plist-get n :app)))
             (plist-get n :summary)
             (if (and body (not (string-empty-p body)))
                 (concat " — " (car (split-string body "\n" t)))
               ""))))

(defun cmacs-notify-daemon--log-to-file (n)
  "Append notification N to `cmacs-notify-daemon-log-file'."
  (when cmacs-notify-daemon-log-file
    (condition-case err
        (let ((file (expand-file-name cmacs-notify-daemon-log-file)))
          (make-directory (file-name-directory file) t)
          (with-temp-buffer
            (insert (cmacs-notify-daemon--entry-string n))
            (write-region (point-min) (point-max) file t 'silent)))
      ;; A failing log must not take the daemon down with it: the
      ;; notification still has to be delivered.
      (error (message "cmacs-notify-daemon: log failed: %s"
                      (error-message-string err))))))

(defun cmacs-notify-daemon--deliver (n)
  "Record and display notification N."
  (let ((urg (plist-get n :urgency)))
    (push n cmacs-notify-daemon-history)
    (when (> (length cmacs-notify-daemon-history)
             cmacs-notify-daemon-history-limit)
      (setcdr (nthcdr (1- cmacs-notify-daemon-history-limit)
                      cmacs-notify-daemon-history)
              nil))
    (cmacs-notify-daemon--log-to-file n)
    ;; Hook first, so a consumer can act before the user is told.
    ;; Errors in a hook function must not stop delivery.
    (dolist (fn cmacs-notify-daemon-functions)
      (condition-case err
          (funcall fn n)
        (error (message "cmacs-notify-daemon: hook %s failed: %s"
                        fn (error-message-string err)))))
    (when (get-buffer cmacs-notify-daemon-buffer)
      (cmacs-notify-daemon-refresh))
    (when (and cmacs-notify-daemon-echo
               (memq urg cmacs-notify-daemon-echo-urgencies))
      (cmacs-notify-daemon--echo n))
    (when (memq urg cmacs-notify-daemon-pop-to-buffer-urgencies)
      (display-buffer (cmacs-notify-daemon-refresh)))))

;;; The specification's methods

(defun cmacs-notify-daemon--notify (app-name replaces-id app-icon
                                             summary body actions
                                             hints expire-timeout)
  "Handle org.freedesktop.Notifications.Notify.
Returns the notification id, which the sender uses to replace or close
it later."
  (let* ((urgency (cmacs-notify-daemon--urgency hints))
         (id (if (and (integerp replaces-id) (> replaces-id 0))
                 replaces-id
               (prog1 cmacs-notify-daemon--next-id
                 ;; Stay inside uint32 and never hand out 0, which the
                 ;; specification reserves.
                 (setq cmacs-notify-daemon--next-id
                       (if (>= cmacs-notify-daemon--next-id 4294967295)
                           1
                         (1+ cmacs-notify-daemon--next-id))))))
         (timeout (cond ((and (integerp expire-timeout) (> expire-timeout 0))
                         expire-timeout)
                        ;; 0 means "never expire"; -1 means "your choice".
                        ((eql expire-timeout 0) nil)
                        (t cmacs-notify-daemon-default-timeout)))
         (n (list :id id
                  :app (or app-name "")
                  :icon (or app-icon "")
                  :summary (or summary "")
                  :body (or body "")
                  :urgency urgency
                  :actions (cmacs-notify-daemon--parse-actions actions)
                  :category (cmacs-notify-daemon--hint hints "category")
                  :hints hints
                  :timeout timeout
                  :time (current-time))))
    ;; A replacing notification supersedes the old entry rather than
    ;; stacking a second one -- that is what replaces_id is for, and a
    ;; progress notification would otherwise fill history by itself.
    (when (and (integerp replaces-id) (> replaces-id 0))
      (let ((old (gethash id cmacs-notify-daemon--active)))
        (when (timerp old) (cancel-timer old)))
      (setq cmacs-notify-daemon-history
            (cl-remove id cmacs-notify-daemon-history
                       :key (lambda (e) (plist-get e :id)))))
    (puthash id
             (when timeout
               (run-with-timer (/ timeout 1000.0) nil
                               (lambda ()
                                 ;; Reason 1: expired.
                                 (cmacs-notify-daemon--close id 1)
                                 (when (get-buffer
                                        cmacs-notify-daemon-buffer)
                                   (cmacs-notify-daemon-refresh)))))
             cmacs-notify-daemon--active)
    (cmacs-notify-daemon--deliver n)
    id))

(defun cmacs-notify-daemon--close-notification (id)
  "Handle org.freedesktop.Notifications.CloseNotification for ID."
  ;; Reason 3: closed by a CloseNotification call.
  (cmacs-notify-daemon--close id 3)
  (when (get-buffer cmacs-notify-daemon-buffer)
    (cmacs-notify-daemon-refresh))
  ;; The specification's return is empty; dbus.el wants something.
  :ignore)

(defun cmacs-notify-daemon--capabilities ()
  "Handle org.freedesktop.Notifications.GetCapabilities.

Deliberately conservative.  A capability here is a promise: claiming
\"body-markup\" and then showing the markup as literal text is worse
for the sender than not claiming it, because it cannot tell."
  (list (list "body"          ; a multi-line body is rendered
              "body-hyperlinks" ; Org linkifies URLs in the body
              "actions"       ; ActionInvoked is emitted, from the buffer
              "persistence"   ; history outlives the notification
              "icon-static")))

(defun cmacs-notify-daemon--server-information ()
  "Handle org.freedesktop.Notifications.GetServerInformation."
  (list "cmacs" "Zach Podbielniak"
        (or (and (boundp 'emacs-version) emacs-version) "unknown")
        cmacs-notify-daemon-spec-version))

;;; Registration

(defun cmacs-notify-daemon--owner ()
  "Return the current owner of the notification name, or nil."
  (ignore-errors
    (dbus-get-name-owner :session cmacs-notify-daemon-service)))

(defun cmacs-notify-daemon--register-methods ()
  "Register the four specification methods, recording them for release."
  (setq cmacs-notify-daemon--objects
        (list
         (dbus-register-method
          :session cmacs-notify-daemon-service cmacs-notify-daemon-path
          cmacs-notify-daemon-interface "Notify"
          #'cmacs-notify-daemon--notify t)
         (dbus-register-method
          :session cmacs-notify-daemon-service cmacs-notify-daemon-path
          cmacs-notify-daemon-interface "CloseNotification"
          #'cmacs-notify-daemon--close-notification t)
         (dbus-register-method
          :session cmacs-notify-daemon-service cmacs-notify-daemon-path
          cmacs-notify-daemon-interface "GetCapabilities"
          #'cmacs-notify-daemon--capabilities t)
         (dbus-register-method
          :session cmacs-notify-daemon-service cmacs-notify-daemon-path
          cmacs-notify-daemon-interface "GetServerInformation"
          #'cmacs-notify-daemon--server-information t))))

;;;###autoload
(define-minor-mode cmacs-notify-daemon-mode-global
  "Own org.freedesktop.Notifications and deliver notifications in Emacs.

Enabling claims the name only if it is free.  Under GNOME, GNOME Shell
already owns it and this is a no-op that says so -- taking the name
from a running shell would break its own notifications and gain
nothing, since GNOME's are already visible.

Disabling releases the name, so a daemon started afterwards gets it."
  :global t
  :group 'cmacs-notify-daemon
  :lighter " Notify"
  (if cmacs-notify-daemon-mode-global
      (let ((owner (cmacs-notify-daemon--owner)))
        (cond
         (cmacs-notify-daemon--registered
          nil)                          ; already ours
         (owner
          (setq cmacs-notify-daemon-mode-global nil)
          (message
           "cmacs-notify-daemon: %s is already owned by %s; not claiming it"
           cmacs-notify-daemon-service owner))
         (t
          (condition-case err
              (let ((result (dbus-register-service
                             :session cmacs-notify-daemon-service
                             :do-not-queue)))
                ;; :do-not-queue means we either get it outright or we
                ;; do not; queueing would leave us silently inactive
                ;; and then silently active later when the other daemon
                ;; exited, which is worse than failing now.
                (if (memq result '(:primary-owner :already-owner))
                    (progn
                      (cmacs-notify-daemon--register-methods)
                      (setq cmacs-notify-daemon--registered t)
                      (message "cmacs-notify-daemon: serving %s"
                               cmacs-notify-daemon-service))
                  (setq cmacs-notify-daemon-mode-global nil)
                  (message "cmacs-notify-daemon: could not claim %s (%s)"
                           cmacs-notify-daemon-service result)))
            (error
             (setq cmacs-notify-daemon-mode-global nil)
             (message "cmacs-notify-daemon: %s"
                      (error-message-string err)))))))
    (when cmacs-notify-daemon--registered
      (dolist (obj cmacs-notify-daemon--objects)
        (ignore-errors (dbus-unregister-object obj)))
      (setq cmacs-notify-daemon--objects nil)
      (ignore-errors
        (dbus-unregister-service :session cmacs-notify-daemon-service))
      (setq cmacs-notify-daemon--registered nil))))

;;;###autoload
(defun cmacs-notify-daemon-serving-p ()
  "Return non-nil when this Emacs is the notification daemon."
  cmacs-notify-daemon--registered)

(provide 'cmacs-notify-daemon)

;;; cmacs-notify-daemon.el ends here
