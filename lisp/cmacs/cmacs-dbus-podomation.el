;;; cmacs-dbus-podomation.el --- Bridge podomation events to D-Bus  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Phase 5: every podomation event dispatched by the cmacs PodEngine
;; can also emit a D-Bus signal on
;; /org/cmacs/Editor/Podomation under interface
;; org.cmacs.Editor1.Podomation.Events.  Lets external tools (status
;; bars, dashboards, observability stacks) react to podomation
;; activity without subscribing to elisp hooks.
;;
;; Off by default; enable with `cmacs-dbus-podomation-bridge-mode'.

;;; Code:

(defcustom cmacs-dbus-podomation-bridge-events
  '(:rule-fired :rule-cooldown :rule-failed :module-loaded :timer-tick)
  "List of podomation event keywords to bridge to D-Bus."
  :type '(repeat symbol) :group 'cmacs-dbus)

(defun cmacs-dbus-podomation--emit (event &rest payload)
  "Forward EVENT (a keyword) and PAYLOAD as a D-Bus signal."
  (when (memq event cmacs-dbus-podomation-bridge-events)
    (cmacs-dbus-emit-signal
     "/org/cmacs/Editor/Podomation"
     "org.cmacs.Editor1.Podomation.Events"
     ;; Strip leading colon from event keyword, kebab → CamelCase
     ;; for D-Bus convention.
     (mapconcat #'capitalize
                (split-string (substring (symbol-name event) 1) "-")
                "")
     payload)))

;;;###autoload
(define-minor-mode cmacs-dbus-podomation-bridge-mode
  "Mirror podomation events as D-Bus signals.
Subscribers can `gdbus monitor' the cmacs service for live event
streams without polling.  Off by default."
  :global t :group 'cmacs-dbus
  (if cmacs-dbus-podomation-bridge-mode
      (progn
        (when (boundp 'pod-engine-event-hook)
          (add-hook 'pod-engine-event-hook
                    #'cmacs-dbus-podomation--emit))
        (cmacs-dbus-emit-signal
         "/org/cmacs/Editor/Podomation"
         "org.cmacs.Editor1.Podomation.Events"
         "BridgeStarted" nil))
    (when (boundp 'pod-engine-event-hook)
      (remove-hook 'pod-engine-event-hook
                   #'cmacs-dbus-podomation--emit))))

(provide 'cmacs-dbus-podomation)
;;; cmacs-dbus-podomation.el ends here
