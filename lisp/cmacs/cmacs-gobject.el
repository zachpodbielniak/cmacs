;;; cmacs-gobject.el --- GObject elisp helpers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Higher-level GObject utilities built on the C primitives from
;; cmacs-gobject.c and cmacs-gclosure.c.
;;
;; C primitives available:
;;   `gobject-p'              -- test if value is a wrapped GObject
;;   `gobject-type-name'      -- get GType name string
;;   `gobject-get'            -- get a GObject property
;;   `gobject-set'            -- set a GObject property
;;   `gobject-connect'        -- connect signal handler
;;   `gobject-disconnect'     -- disconnect signal handler
;;   `gobject-new'            -- construct a new GObject
;;   `gobject-list-properties' -- list property names
;;   `gobject-list-signals'   -- list signal names

;;; Code:

(require 'cl-lib)

;;; Type checking

(defsubst cmacs-gobject-ensure (object)
  "Signal an error if OBJECT is not a wrapped GObject, otherwise return it."
  (unless (gobject-p object)
    (signal 'wrong-type-argument (list 'gobject-p object)))
  object)

(defun cmacs-gobject-type-of (object)
  "Return the GType name of OBJECT as a symbol."
  (intern (gobject-type-name (cmacs-gobject-ensure object))))

(defun cmacs-gobject-is-a (object type-name)
  "Return non-nil if OBJECT is a GObject of type TYPE-NAME.
TYPE-NAME is a string like \"GtkWindow\" or \"GObject\"."
  (and (gobject-p object)
       (string= (gobject-type-name object) type-name)))

;;; Property access

(defun cmacs-gobject-get-properties (object &rest properties)
  "Get multiple PROPERTIES from GObject OBJECT.
Returns an alist of (PROPERTY-NAME . VALUE) pairs."
  (cmacs-gobject-ensure object)
  (mapcar (lambda (prop)
            (cons prop (gobject-get object prop)))
          properties))

(defun cmacs-gobject-set-properties (object &rest prop-values)
  "Set multiple properties on GObject OBJECT.
PROP-VALUES is a plist of property names and values.

Example:
  (cmacs-gobject-set-properties widget
    \"visible\" t
    \"sensitive\" nil)"
  (cmacs-gobject-ensure object)
  (cl-loop for (prop val) on prop-values by #'cddr
           do (gobject-set object prop val))
  object)

(defmacro cmacs-gobject-with-properties (object bindings &rest body)
  "Bind GObject properties of OBJECT to local variables, then execute BODY.
BINDINGS is a list of (VAR PROPERTY) pairs.

Example:
  (cmacs-gobject-with-properties widget
      ((title \"title\")
       (visible \"visible\"))
    (message \"Widget %s is %s\" title (if visible \"visible\" \"hidden\")))"
  (declare (indent 2))
  (let ((obj-sym (gensym "object")))
    `(let* ((,obj-sym ,object)
            ,@(mapcar (lambda (binding)
                        (list (car binding)
                              `(gobject-get ,obj-sym ,(cadr binding))))
                      bindings))
       ,@body)))

;;; Signal helpers

(defun cmacs-gobject-connect-once (object signal callback)
  "Connect CALLBACK to SIGNAL on OBJECT, disconnecting after first emission.
Returns the handler ID."
  (cmacs-gobject-ensure object)
  (let (handler-id)
    (setq handler-id
          (gobject-connect object signal
                           (lambda (&rest args)
                             (gobject-disconnect object handler-id)
                             (apply callback args))))
    handler-id))

(defun cmacs-gobject-connect-all (object signal-callback-alist)
  "Connect multiple signals on OBJECT at once.
SIGNAL-CALLBACK-ALIST is an alist of (SIGNAL . CALLBACK) pairs.
Returns a list of handler IDs."
  (cmacs-gobject-ensure object)
  (mapcar (lambda (pair)
            (gobject-connect object (car pair) (cdr pair)))
          signal-callback-alist))

(defun cmacs-gobject-disconnect-all (object handler-ids)
  "Disconnect all HANDLER-IDS from OBJECT."
  (cmacs-gobject-ensure object)
  (dolist (id handler-ids)
    (gobject-disconnect object id)))

;;; Construction helpers

(defun cmacs-gobject-create (type-name &rest properties)
  "Create a new GObject of TYPE-NAME with PROPERTIES.
PROPERTIES is a plist of property names and values.

Example:
  (cmacs-gobject-create \"GtkButton\"
    \"label\" \"Click Me\"
    \"visible\" t)"
  (apply #'gobject-new type-name properties))

;;; Introspection

(defun cmacs-gobject-describe (object)
  "Display detailed information about GObject OBJECT."
  (interactive
   (list (eval (read--expression "GObject expression: "))))
  (cmacs-gobject-ensure object)
  (let ((type-name (gobject-type-name object))
        (properties (gobject-list-properties object))
        (signals (gobject-list-signals object)))
    (with-help-window "*GObject Info*"
      (princ (format "GObject Type: %s\n\n" type-name))
      (princ (format "Properties (%d):\n" (length properties)))
      (dolist (prop properties)
        (let ((val (condition-case nil
                       (gobject-get object prop)
                     (error "<unreadable>"))))
          (princ (format "  %-30s = %S\n" prop val))))
      (princ (format "\nSignals (%d):\n" (length signals)))
      (dolist (sig signals)
        (princ (format "  %s\n" sig))))))

(defun cmacs-gobject-property-names (object)
  "Return property names of OBJECT as a list of strings.
Alias for `gobject-list-properties' for discoverability."
  (gobject-list-properties (cmacs-gobject-ensure object)))

(defun cmacs-gobject-signal-names (object)
  "Return signal names of OBJECT as a list of strings.
Alias for `gobject-list-signals' for discoverability."
  (gobject-list-signals (cmacs-gobject-ensure object)))

(provide 'cmacs-gobject)
;;; cmacs-gobject.el ends here
