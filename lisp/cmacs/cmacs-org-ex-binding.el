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

;;; Teardown

(defun cmacs-org-ex-binding-teardown ()
  "Clean up all bindings and channels in the current buffer."
  (setq cmacs-org-ex--bindings nil)
  (setq cmacs-org-ex--channels nil))

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
