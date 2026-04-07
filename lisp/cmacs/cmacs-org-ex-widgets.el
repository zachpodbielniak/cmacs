;;; cmacs-org-ex-widgets.el --- Widget type dispatch  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Registry and creation dispatch for org-ex widget types.
;;
;; Each widget type is a string (e.g. "slider", "web") mapped to a
;; creation function.  The creation function receives a property alist,
;; width, and height, and returns an OrgExWidget GObject.
;;
;; Built-in types:
;;   "slider"  -- GtkScale via GI, wrapped in org-ex-widget-gtk-new
;;   "web"     -- web view from URL via org-ex-widget-web-new
;;   "buffer"  -- file buffer via org-ex-widget-buffer-new
;;   "elisp"   -- evaluate block contents as elisp
;;   "crispy"  -- evaluate via crispy-eval-string
;;   "bacon"   -- evaluate via bacon-eval

;;; Code:

(require 'cl-lib)

(defvar cmacs-org-ex--widget-types (make-hash-table :test 'equal)
  "Hash table mapping widget subtype strings to creation functions.
Each function takes (PROPS WIDTH HEIGHT) and returns an OrgExWidget.")

;;; Registration API

(defun cmacs-org-ex-register-widget-type (subtype create-fn)
  "Register SUBTYPE string to be handled by CREATE-FN.
CREATE-FN is called with (PROPS WIDTH HEIGHT) where PROPS is an
alist of (KEY . VALUE) strings parsed from the widget block."
  (puthash subtype create-fn cmacs-org-ex--widget-types))

(defun cmacs-org-ex-widget-type-p (subtype)
  "Return non-nil if SUBTYPE is a registered widget type."
  (gethash subtype cmacs-org-ex--widget-types))

(defun cmacs-org-ex-widget-types ()
  "Return a list of registered widget type name strings."
  (let (types)
    (maphash (lambda (k _v) (push k types))
             cmacs-org-ex--widget-types)
    (nreverse types)))

;;; Dispatch

(defun cmacs-org-ex-create-widget (subtype props width height)
  "Create a widget of SUBTYPE with PROPS, WIDTH, and HEIGHT.
Dispatches to the registered creation function.
Returns an OrgExWidget GObject, or signals an error."
  (let ((create-fn (gethash subtype cmacs-org-ex--widget-types)))
    (unless create-fn
      (error "Unknown org-ex widget type: %s" subtype))
    (funcall create-fn props width height)))

;;; Built-in type: slider

(defun cmacs-org-ex--create-slider (props width height)
  "Create a GtkScale slider widget from PROPS with WIDTH and HEIGHT.
Properties:
  :min    -- minimum value (default 0)
  :max    -- maximum value (default 100)
  :value  -- initial value (default 50)
  :step   -- step increment (default 1)"
  (let ((min-val (if-let ((v (cdr (assoc "min" props))))
                     (string-to-number v) 0.0))
        (max-val (if-let ((v (cdr (assoc "max" props))))
                     (string-to-number v) 100.0))
        (init-val (if-let ((v (cdr (assoc "value" props))))
                      (string-to-number v) 50.0))
        (step (if-let ((v (cdr (assoc "step" props))))
                  (string-to-number v) 1.0)))
    (gi-require "Gtk" "3.0")
    (let* ((adjustment (gobject-new "GtkAdjustment"))
           (scale (gobject-new "GtkScale")))
      (gobject-set adjustment "lower" min-val)
      (gobject-set adjustment "upper" max-val)
      (gobject-set adjustment "value" init-val)
      (gobject-set adjustment "step-increment" step)
      (gobject-set adjustment "page-increment" (* step 10))
      (gobject-set scale "adjustment" adjustment)
      (gobject-set scale "draw-value" t)
      (let ((widget (org-ex-widget-gtk-new scale)))
        (org-ex-widget-set-size widget width height)
        widget))))

;;; Built-in type: web

(defun cmacs-org-ex--create-web (props width height)
  "Create a web view widget from PROPS with WIDTH and HEIGHT.
Properties:
  :url   -- URL to load
  :html  -- inline HTML (used if :url is absent)
Creates a WebKitWebView via GObject Introspection and wraps it
as an OrgExWidgetGtk for embedding via gtk-embed."
  (let ((url (cdr (assoc "url" props)))
        (html (cdr (assoc "html" props))))
    (unless (or url html)
      (error "Web widget requires :url or :html property"))
    (gi-require "WebKit2" "4.1")
    (let* ((webview (gobject-new "WebKitWebView"))
           (widget (org-ex-widget-gtk-new webview)))
      (cond
       (url  (gi-method webview "load_uri" url))
       (html (gi-method webview "load_html" html "")))
      (org-ex-widget-set-size widget width height)
      widget)))

;;; Built-in type: buffer

(defun cmacs-org-ex--create-buffer (props width height)
  "Create a buffer widget from PROPS with WIDTH and HEIGHT.
Properties:
  :file      -- file path to display
  :editable  -- if \"t\", buffer is editable (default nil)"
  (let ((file (cdr (assoc "file" props)))
        (editable (string-equal-ignore-case
                   (or (cdr (assoc "editable" props)) "")
                   "t")))
    (unless file
      (error "Buffer widget requires :file property"))
    (let ((widget (org-ex-widget-buffer-new file editable)))
      (org-ex-widget-set-size widget width height)
      widget)))

;;; Built-in type: elisp

(defun cmacs-org-ex--create-elisp (props width height)
  "Evaluate block contents as elisp, result becomes a widget.
Properties:
  :code  -- elisp code string to evaluate

The code must return an OrgExWidget or a GtkWidget (which gets
wrapped automatically).  If evaluation fails, creates a code
widget displaying the error."
  (let ((code (cdr (assoc "code" props))))
    (unless code
      (error "Elisp widget requires :code property"))
    (condition-case err
        (let ((result (eval (car (read-from-string code)) t)))
          (cond
           ((and (fboundp 'gobject-p) (gobject-p result))
            (let ((widget (org-ex-widget-gtk-new result)))
              (org-ex-widget-set-size widget width height)
              widget))
           (t
            ;; Treat as HTML string.
            (let ((widget (org-ex-widget-web-new-from-html
                           (format "%s" result) width height)))
              widget))))
      (error
       ;; Evaluation failed — create a code widget with the error.
       (nconc props (list (cons "_output"
                                (format "[error: %s]"
                                        (error-message-string err)))))
       (let ((widget (org-ex-widget-code-new "elisp" code)))
         (org-ex-widget-set-size widget width height)
         widget)))))

;;; Built-in type: crispy

(defun cmacs-org-ex--create-crispy (props width height)
  "Evaluate block contents via crispy-eval-string.
Properties:
  :code  -- C code string to evaluate

The stdout output is rendered as a code widget."
  (let ((code (cdr (assoc "code" props))))
    (unless code
      (error "Crispy widget requires :code property"))
    (unless (fboundp 'crispy-eval-string)
      (error "Crispy subsystem not available"))
    (let* ((output (crispy-eval-string code))
           (widget (org-ex-widget-code-new "c" code)))
      ;; Store output for display stage (nconc mutates props in caller).
      (nconc props (list (cons "_output" (or output ""))))
      (org-ex-widget-set-size widget width height)
      widget)))

;;; Built-in type: bacon

(defun cmacs-org-ex--create-bacon (props width height)
  "Evaluate block contents via bacon-eval.
Properties:
  :code  -- shell code string to evaluate

The output is rendered as a code widget."
  (let ((code (cdr (assoc "code" props))))
    (unless code
      (error "Bacon widget requires :code property"))
    (unless (fboundp 'bacon-eval)
      (error "Bacon subsystem not available"))
    (let* ((result (bacon-eval code))
           (output (cdr result))
           (widget (org-ex-widget-code-new "sh" code)))
      ;; Store output for display stage (nconc mutates props in caller).
      (nconc props (list (cons "_output" (or output ""))))
      (org-ex-widget-set-size widget width height)
      widget)))

;;; Register built-in types

(cmacs-org-ex-register-widget-type "slider"  #'cmacs-org-ex--create-slider)
(cmacs-org-ex-register-widget-type "web"     #'cmacs-org-ex--create-web)
(cmacs-org-ex-register-widget-type "buffer"  #'cmacs-org-ex--create-buffer)
(cmacs-org-ex-register-widget-type "elisp"   #'cmacs-org-ex--create-elisp)
(cmacs-org-ex-register-widget-type "crispy"  #'cmacs-org-ex--create-crispy)
(cmacs-org-ex-register-widget-type "bacon"   #'cmacs-org-ex--create-bacon)

(provide 'cmacs-org-ex-widgets)
;;; cmacs-org-ex-widgets.el ends here
