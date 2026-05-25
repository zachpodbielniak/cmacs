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
  (let ((min-val (if-let* ((v (cdr (assoc "min" props))))
                     (string-to-number v) 0.0))
        (max-val (if-let* ((v (cdr (assoc "max" props))))
                     (string-to-number v) 100.0))
        (init-val (if-let* ((v (cdr (assoc "value" props))))
                      (string-to-number v) 50.0))
        (step (if-let* ((v (cdr (assoc "step" props))))
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
  :url     -- URL to load
  :html    -- inline HTML (used if :url is absent)
  :bridge  -- when \"t\", enable JS-to-Emacs message bridge
Creates a WebKitWebView via GObject Introspection and wraps it
as an OrgExWidgetGtk for embedding via gtk-embed."
  (let ((url (cdr (assoc "url" props)))
        (html (cdr (assoc "html" props))))
    (unless (or url html)
      (error "Web widget requires :url or :html property"))
    (gi-require "WebKit2" "4.1")
    (let* ((webview (gobject-new "WebKitWebView"))
           (widget (org-ex-widget-gtk-new webview)))
      ;; Set up JS bridge BEFORE loading content — the handler must
      ;; be registered before the page context is created, otherwise
      ;; window.webkit.messageHandlers.cmacs won't exist in JS.
      (when (string-equal-ignore-case
             (or (cdr (assoc "bridge" props)) "") "t")
        (require 'cmacs-org-ex-bridge)
        (cmacs-org-ex-bridge-setup webview))
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
    ;; Resolve relative paths against the Org file's directory, not CWD.
    (let* ((file (expand-file-name file
                                   (if buffer-file-name
                                       (file-name-directory buffer-file-name)
                                     default-directory)))
           (widget (org-ex-widget-buffer-new file editable)))
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

;;; Built-in type: wayland

(defvar cmacs-org-ex--wayland-pending nil
  "Alist of (PID . (widget overlay buffer)) for pending Wayland embeds.")

(defvar cmacs-org-ex--wayland-timer nil
  "Timer checking for mapped Wayland clients.")

(defun cmacs-org-ex--create-wayland (props width height)
  "Create a Wayland client embed widget from PROPS with WIDTH and HEIGHT.
Properties:
  :command  -- command to spawn (required)
  :args     -- additional arguments (space-separated string)

Spawns the command, registers for embed, and creates a gowl xwidget
once the client maps."
  (let ((command (cdr (assoc "command" props)))
        (args (cdr (assoc "args" props))))
    (unless command
      (error "Wayland widget requires :command property"))
    (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
      (error "Gowl compositor not running"))
    (let* ((full-cmd (if args
                        (concat command " " args)
                      command))
           (pid (gowl-spawn full-cmd)))
      ;; Register PID for embedding
      (gowl-prefloat-pid pid)
      ;; Store PID in props so instantiate-block can map PID→overlay.
      (nconc props (list (cons "_wayland_pid" (number-to-string pid))))
      ;; Create placeholder widget, will be replaced when client maps
      (let ((widget (org-ex-widget-code-new "sh" full-cmd)))
        (org-ex-widget-set-size widget width height)
        ;; Store pending info for async completion
        (push (list pid widget width height (current-buffer))
              cmacs-org-ex--wayland-pending)
        ;; Start polling timer if not already running
        (unless cmacs-org-ex--wayland-timer
          (setq cmacs-org-ex--wayland-timer
                (run-with-timer 0.2 0.2
                                #'cmacs-org-ex--wayland-check-pending)))
        widget))))

(defun cmacs-org-ex--wayland-check-pending ()
  "Check if any pending Wayland clients have mapped."
  (let (remaining)
    (dolist (entry cmacs-org-ex--wayland-pending)
      (let* ((pid (nth 0 entry))
             (client (gowl-find-client pid 'pid)))
        (if client
            ;; Client mapped — create xwidget and replace placeholder
            (let ((width (nth 2 entry))
                  (height (nth 3 entry))
                  (buf (nth 4 entry)))
              (when (buffer-live-p buf)
                (with-current-buffer buf
                  (condition-case nil
                      (let* ((xw (gowl-make-xwidget client width height buf))
                             (ov (cdr (assq pid
                                            cmacs-org-ex--wayland-overlay-map))))
                        (when (and xw ov (overlay-buffer ov))
                          (let ((str (concat
                                      "\n"
                                      (propertize
                                       " "
                                       'display (list 'xwidget :xwidget xw))
                                      "\n")))
                            (overlay-put ov 'before-string str))))
                    (error nil)))))
          ;; Not yet mapped — keep waiting
          (push entry remaining))))
    (setq cmacs-org-ex--wayland-pending (nreverse remaining))
    ;; Stop timer when no more pending
    (when (null cmacs-org-ex--wayland-pending)
      (when cmacs-org-ex--wayland-timer
        (cancel-timer cmacs-org-ex--wayland-timer)
        (setq cmacs-org-ex--wayland-timer nil)))))

;;; Built-in type: image

(defun cmacs-org-ex--create-image (props width height)
  "Create an image widget from PROPS with WIDTH and HEIGHT.
Properties:
  :file   -- path to image file (required)
  :scale  -- scale factor (default 1.0)

Displays the image using Emacs built-in image support.  Falls back
to a GtkImage via GI on the gtk-embed path."
  (let ((file (cdr (assoc "file" props)))
        (scale (if-let* ((v (cdr (assoc "scale" props))))
                   (string-to-number v) 1.0)))
    (unless file
      (error "Image widget requires :file property"))
    ;; Resolve relative paths against the Org file's directory.
    (setq file (expand-file-name file
                                 (if buffer-file-name
                                     (file-name-directory buffer-file-name)
                                   default-directory)))
    (unless (file-exists-p file)
      (error "Image file not found: %s" file))
    ;; Try native image display first
    (if (display-images-p)
        (let* ((img (create-image file nil nil
                                  :width width :height height
                                  :scale scale))
               ;; Wrap in a web widget with img tag as fallback
               (html (format "<img src=\"file://%s\" width=\"%d\" height=\"%d\">"
                             (expand-file-name file) width height))
               (widget (org-ex-widget-web-new-from-html html width height)))
          widget)
      ;; Fallback: GtkImage via GI
      (gi-require "Gtk" "3.0")
      (let* ((gtk-img (gobject-new "GtkImage"))
             (widget (org-ex-widget-gtk-new gtk-img)))
        (gi-method gtk-img "set_from_file" file)
        (org-ex-widget-set-size widget width height)
        widget))))


;;; Register built-in types

(cmacs-org-ex-register-widget-type "slider"  #'cmacs-org-ex--create-slider)
(cmacs-org-ex-register-widget-type "web"     #'cmacs-org-ex--create-web)
(cmacs-org-ex-register-widget-type "buffer"  #'cmacs-org-ex--create-buffer)
(cmacs-org-ex-register-widget-type "elisp"   #'cmacs-org-ex--create-elisp)
(cmacs-org-ex-register-widget-type "crispy"  #'cmacs-org-ex--create-crispy)
(cmacs-org-ex-register-widget-type "bacon"   #'cmacs-org-ex--create-bacon)
(cmacs-org-ex-register-widget-type "wayland" #'cmacs-org-ex--create-wayland)
(cmacs-org-ex-register-widget-type "image"   #'cmacs-org-ex--create-image)

(provide 'cmacs-org-ex-widgets)
;;; cmacs-org-ex-widgets.el ends here
