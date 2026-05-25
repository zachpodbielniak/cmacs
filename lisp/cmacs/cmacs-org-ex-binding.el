;;; cmacs-org-ex-binding.el --- Reactive binding system  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Reactive data binding for org-ex widgets.
;;
;; Parses binding directives from widget block properties:
;;   :bind PROPERTY     -- bind widget to a document property
;;   :publish CHANNEL   -- publish widget value changes to a channel
;;   :subscribe CHANNEL -- subscribe widget to a channel
;;
;; Bindings use the C primitives:
;;   `org-ex-binding-create'    -- create a property binding
;;   `org-ex-channel-create'    -- create a named channel
;;   `org-ex-channel-publish'   -- publish a value to a channel
;;
;; GObject bridge:
;;   `gobject-connect'          -- connect to value-changed signals

;;; Code:

(require 'cl-lib)

;;; Channel registry

(defvar-local cmacs-org-ex--channels nil
  "Alist mapping channel name strings to OrgExChannel objects.")

(defvar-local cmacs-org-ex--bindings nil
  "List of active OrgExBinding objects in this buffer.")

(defvar-local cmacs-org-ex--inhibit-notify nil
  "When non-nil, suppress binding notifications to prevent loops.")

;;; Channel management

(defun cmacs-org-ex--get-or-create-channel (name)
  "Return the OrgExChannel for NAME, creating it if needed."
  (or (cdr (assoc name cmacs-org-ex--channels))
      (let ((channel (org-ex-channel-create name)))
        (push (cons name channel) cmacs-org-ex--channels)
        channel)))

;;; Binding setup

(defun cmacs-org-ex-setup-bindings (document widget props)
  "Set up bindings for WIDGET registered with DOCUMENT.
PROPS is the alist of (KEY . VALUE) strings from the widget block.
Recognizes :bind, :publish, and :subscribe directives."
  (let ((bind-prop (cdr (assoc "bind" props)))
        (publish-name (cdr (assoc "publish" props)))
        (subscribe-name (cdr (assoc "subscribe" props)))
        (direction (cdr (assoc "direction" props))))
    ;; Property binding.
    (when bind-prop
      (let ((binding (org-ex-binding-create
                      document bind-prop widget
                      (cmacs-org-ex--parse-direction direction))))
        (push binding cmacs-org-ex--bindings)))
    ;; Publish: connect widget's value-changed signal to channel.
    (when publish-name
      (let ((channel (cmacs-org-ex--get-or-create-channel
                      publish-name)))
        (gobject-connect widget "value-changed"
                         (lambda (&rest _args)
                           (unless cmacs-org-ex--inhibit-notify
                             (let ((val (gobject-get widget "value")))
                               (org-ex-channel-publish
                                channel val)))))))
    ;; Subscribe: connect channel's message signal to widget.
    (when subscribe-name
      (let ((channel (cmacs-org-ex--get-or-create-channel
                      subscribe-name)))
        (gobject-connect channel "message"
                         (lambda (value)
                           (let ((cmacs-org-ex--inhibit-notify t))
                             (gobject-set widget "value" value))))))))

(defun cmacs-org-ex--parse-direction (direction-str)
  "Parse DIRECTION-STR into a direction symbol for `org-ex-binding-create'.
Valid values: \"both\", \"to-widget\", \"from-widget\".
Returns nil for the default (bidirectional)."
  (pcase direction-str
    ("to-widget"   'to-widget)
    ("from-widget" 'from-widget)
    ("both"        nil)
    (_             nil)))

;;; Property line change detection

(defun cmacs-org-ex-binding--after-change (beg end _len)
  "Detect #+PROPERTY: line edits between BEG and END.
Notifies the document of property changes so bindings update."
  (when (and (boundp 'cmacs-org-ex-mode)
             cmacs-org-ex-mode
             (not cmacs-org-ex--inhibit-notify)
             (boundp 'cmacs-org-ex--document)
             cmacs-org-ex--document)
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (while (< (point) end)
        (when (looking-at
               "^[ \t]*#\\+PROPERTY:[ \t]+\\(\\S-+\\)[ \t]+\\(.+?\\)[ \t]*$")
          (let ((name (match-string-no-properties 1))
                (value (match-string-no-properties 2))
                (cmacs-org-ex--inhibit-notify t))
            (org-ex-document-notify-property-changed
             cmacs-org-ex--document name value)))
        (forward-line 1)))))

;;; Reactive re-evaluation

(defvar-local cmacs-org-ex--reactive-widgets nil
  "Alist of (ID . CONTEXT) for widgets with `:reactive t'.
CONTEXT is a plist (:create-fn FN :props ALIST :width W :height H
:subtype STR :marker M :widget W).")

(defvar-local cmacs-org-ex--timers nil
  "Alist of (ID . TIMER) for widgets with `:interval N'.")

(defun cmacs-org-ex--reactive-register (id create-fn props width height
                                           subtype marker widget)
  "Register widget ID for reactive re-creation.
CREATE-FN, PROPS, WIDTH, HEIGHT, SUBTYPE are the original creation
parameters.  MARKER points to the widget's position in the buffer.
WIDGET is the current live widget."
  (let ((ctx (list :create-fn create-fn :props props
                   :width width :height height
                   :subtype subtype :marker marker
                   :widget widget)))
    (setf (alist-get id cmacs-org-ex--reactive-widgets) ctx)))

(defun cmacs-org-ex--reactive-recreate (id)
  "Tear down and re-create the widget identified by ID."
  (when-let* ((ctx (alist-get id cmacs-org-ex--reactive-widgets)))
    (let ((create-fn (plist-get ctx :create-fn))
          (props     (plist-get ctx :props))
          (width     (plist-get ctx :width))
          (height    (plist-get ctx :height))
          (old       (plist-get ctx :widget)))
      ;; Teardown old widget if it has a destroy method
      (when (and old (fboundp 'org-ex-widget-destroy))
        (ignore-errors (org-ex-widget-destroy old)))
      ;; Re-create
      (let ((new-widget (funcall create-fn props width height)))
        (plist-put ctx :widget new-widget)
        new-widget))))

(defun cmacs-org-ex-setup-reactive (id widget props create-fn
                                       width height subtype)
  "Set up reactive re-evaluation for widget ID if `:reactive t'.
Also sets up `:interval N' timer polling.
Returns non-nil if reactive was configured."
  (let ((reactive (string-equal-ignore-case
                   (or (cdr (assoc "reactive" props)) "") "t"))
        (interval (when-let* ((v (cdr (assoc "interval" props))))
                    (string-to-number v))))
    (when (or reactive interval)
      (let ((marker (copy-marker (point))))
        (cmacs-org-ex--reactive-register
         id create-fn props width height subtype marker widget)
        ;; Subscribe to channel for reactive updates
        (when reactive
          (when-let* ((sub-name (cdr (assoc "subscribe" props))))
            (let ((channel (cmacs-org-ex--get-or-create-channel
                            sub-name)))
              (gobject-connect channel "message"
                               (lambda (_value)
                                 (cmacs-org-ex--reactive-recreate id))))))
        ;; Set up interval timer
        (when (and interval (> interval 0))
          (let ((timer (run-with-timer
                        interval interval
                        (lambda ()
                          (when (buffer-live-p (marker-buffer marker))
                            (with-current-buffer (marker-buffer marker)
                              (cmacs-org-ex--reactive-recreate id)))))))
            (setf (alist-get id cmacs-org-ex--timers) timer)))
        t))))

;;; Teardown

(defun cmacs-org-ex-binding-teardown ()
  "Clean up all bindings, channels, reactive widgets, and timers."
  (setq cmacs-org-ex--bindings nil)
  (setq cmacs-org-ex--channels nil)
  ;; Cancel all timers
  (dolist (entry cmacs-org-ex--timers)
    (when (timerp (cdr entry))
      (cancel-timer (cdr entry))))
  (setq cmacs-org-ex--timers nil)
  (setq cmacs-org-ex--reactive-widgets nil))

;;; Integration with cmacs-org-ex-mode

(defun cmacs-org-ex-binding--mode-hook ()
  "Set up binding change tracking when `cmacs-org-ex-mode' is enabled."
  (if cmacs-org-ex-mode
      (add-hook 'after-change-functions
                #'cmacs-org-ex-binding--after-change nil t)
    (cmacs-org-ex-binding-teardown)
    (remove-hook 'after-change-functions
                 #'cmacs-org-ex-binding--after-change t)))

(add-hook 'cmacs-org-ex-mode-hook #'cmacs-org-ex-binding--mode-hook)

(provide 'cmacs-org-ex-binding)
;;; cmacs-org-ex-binding.el ends here
