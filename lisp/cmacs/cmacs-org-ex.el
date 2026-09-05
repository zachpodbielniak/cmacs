;;; cmacs-org-ex.el --- Org-Ex interactive widget embedding  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Minor mode for embedding interactive widgets in Org buffers.
;;
;; C primitives available:
;;   `org-ex-document-create'           -- create an OrgExDocument
;;   `org-ex-document-register-widget'  -- register widget with document
;;   `org-ex-document-get-widget'       -- retrieve widget by id
;;   `org-ex-document-remove-widget'    -- remove widget from document
;;   `org-ex-document-teardown-all'     -- teardown all widgets
;;   `org-ex-document-notify-property-changed' -- notify property change
;;   `org-ex-widget-gtk-new'            -- wrap a GtkWidget
;;   `org-ex-widget-web-new'            -- create web widget from URL
;;   `org-ex-widget-web-new-from-html'  -- create web widget from HTML
;;   `org-ex-widget-buffer-new'         -- create buffer widget
;;   `org-ex-widget-code-new'           -- create code widget
;;   `org-ex-widget-set-size'           -- set widget dimensions
;;   `org-ex-widget-teardown'           -- teardown single widget
;;   `org-ex-binding-create'            -- create reactive binding
;;   `org-ex-channel-create'            -- create pub/sub channel
;;   `org-ex-channel-publish'           -- publish to channel
;;   `org-ex-widget-export-html'        -- export widget as HTML
;;   `org-ex-widget-export-text'        -- export widget as text
;;   `org-ex-widget-code-set-result'    -- set code widget result
;;
;; This file provides:
;;   - `cmacs-org-ex-mode'    -- buffer-local minor mode
;;   - Automatic activation via #+ORGEX: t keyword
;;   - Widget block scanning and overlay display
;;   - `widget' Org link type for inline widgets

;;; Code:

(require 'cl-lib)
(require 'cmacs)
(require 'org)
(require 'org-element)
(require 'url-util)
(require 'xml)
(require 'cmacs-org-ex-widgets)
(require 'cmacs-org-ex-binding)
(require 'cmacs-org-ex-export)
(require 'cmacs-org-ex-state)

(defgroup cmacs-org-ex nil
  "Org-Ex interactive widget embedding."
  :group 'cmacs
  :prefix "cmacs-org-ex-")

(defcustom cmacs-org-ex-eval-policy 'ask
  "Whether org-ex may evaluate Emacs Lisp found in an Org file.

Two things in a widget document are code, not data: src blocks tagged
`#+ATTR_ORGEX: :eval t', and `elisp' widgets whose `:code' property is
evaluated to produce the widget.  Both run when the mode scans the
buffer, which with `#+ORGEX: t' in the header means when the file is
opened -- so this is the same decision `org-confirm-babel-evaluate'
guards, for a file that may have arrived by mail, from a clone, or
from the second brain's ingester.

`ask' (the default) prompts once per buffer the first time evaluation
would happen, and remembers the answer for that buffer.  When there is
nobody to ask -- the buffer is being scanned from an RPC surface with
`inhibit-interaction' bound, or Emacs is non-interactive -- an
unanswered question counts as no.  `always' evaluates without asking
(the behaviour before this option existed) and `never' skips
evaluation entirely; widgets that do not need code still work.

Files under `cmacs-org-ex-eval-trusted-directories' are evaluated
without a prompt regardless."
  :type '(choice (const :tag "Ask once per buffer" ask)
                 (const :tag "Always evaluate" always)
                 (const :tag "Never evaluate" never))
  :group 'cmacs-org-ex)

(defcustom cmacs-org-ex-eval-trusted-directories nil
  "Directories whose Org files org-ex may evaluate without asking.

Each entry is a directory; a file anywhere below one of them (after
`file-truename') is treated as `always' under
`cmacs-org-ex-eval-policy'.  Your own notes tree is the natural entry."
  :type '(repeat directory)
  :group 'cmacs-org-ex)

(defvar-local cmacs-org-ex--eval-decision nil
  "The remembered answer for this buffer: `allow', `deny', or nil (not asked).")

(defun cmacs-org-ex--trusted-file-p (file)
  "Non-nil when FILE lies under one of the trusted directories."
  (when (and file cmacs-org-ex-eval-trusted-directories)
    (let ((truename (file-truename file)))
      (cl-some (lambda (dir)
                 (string-prefix-p (file-name-as-directory
                                   (file-truename (expand-file-name dir)))
                                  truename))
               cmacs-org-ex-eval-trusted-directories))))

(defun cmacs-org-ex--eval-allowed-p ()
  "Decide, for the current buffer, whether embedded Lisp may run.

Applies `cmacs-org-ex-eval-policy', the trusted directories, and the
per-buffer memory.  A prompt that cannot be shown is a no: RPC
dispatch binds `inhibit-interaction', and the question must never
turn into an error that aborts the scan halfway."
  (cond
   ((eq cmacs-org-ex-eval-policy 'never) nil)
   ((eq cmacs-org-ex-eval-policy 'always) t)
   ((cmacs-org-ex--trusted-file-p buffer-file-name) t)
   ((eq cmacs-org-ex--eval-decision 'allow) t)
   ((eq cmacs-org-ex--eval-decision 'deny) nil)
   ((or noninteractive (bound-and-true-p inhibit-interaction)) nil)
   (t
    (let ((answer (condition-case nil
                      (yes-or-no-p
                       (format "org-ex: %s wants to evaluate Emacs Lisp on load.  Allow? "
                               (if buffer-file-name
                                   (file-name-nondirectory buffer-file-name)
                                 (buffer-name))))
                    (error nil))))
      (setq cmacs-org-ex--eval-decision (if answer 'allow 'deny))
      answer))))

(defun cmacs-org-ex-allow-eval ()
  "Allow embedded Lisp in the current buffer and rescan it.
Use after answering no to the load-time prompt, or when the policy is
`ask' and the buffer was opened non-interactively."
  (interactive)
  (setq cmacs-org-ex--eval-decision 'allow)
  (when (bound-and-true-p cmacs-org-ex-mode)
    (cmacs-org-ex--scan-buffer)))

(defcustom cmacs-org-ex-default-width 400
  "Default widget width in pixels."
  :type 'integer
  :group 'cmacs-org-ex)

(defcustom cmacs-org-ex-default-height 200
  "Default widget height in pixels."
  :type 'integer
  :group 'cmacs-org-ex)

;;; Buffer-local state

(defvar-local cmacs-org-ex--document nil
  "The OrgExDocument for this buffer, or nil.")

(defvar-local cmacs-org-ex--overlays nil
  "List of overlays created for widget blocks.")

(defvar-local cmacs-org-ex--widget-ids nil
  "Alist mapping widget ID strings to overlay objects.")

(defvar-local cmacs-org-ex--wayland-overlay-map nil
  "Alist mapping Wayland client PID (integer) to overlay.")

(defvar-local cmacs-org-ex--inhibit-change nil
  "When non-nil, suppress `after-change-functions' processing.")

(defvar-local cmacs-org-ex--size-specs nil
  "Alist of (ID . (WIDTH-SPEC . HEIGHT-SPEC)) for responsive widgets.
Specs can be pixel integers, percentage strings like \"50%\",
or the string \"auto\".")

;;; Responsive sizing

(defun cmacs-org-ex--resolve-size-spec (spec default window-pixels)
  "Resolve a size SPEC to pixels.
SPEC can be an integer (pixels), a string like \"50%\" (percentage
of WINDOW-PIXELS), \"auto\" (use DEFAULT), or a numeric string.
Returns an integer pixel value."
  (cond
   ((integerp spec) spec)
   ((null spec) default)
   ((and (stringp spec) (string-suffix-p "%" spec))
    (let ((pct (string-to-number (substring spec 0 -1))))
      (max 1 (round (* (/ pct 100.0) window-pixels)))))
   ((and (stringp spec) (string-equal-ignore-case spec "auto"))
    default)
   ((stringp spec)
    (let ((n (string-to-number spec)))
      (if (> n 0) n default)))
   (t default)))

(defun cmacs-org-ex--parse-size-spec (props)
  "Parse width/height from PROPS, returning (WIDTH-SPEC . HEIGHT-SPEC).
Preserves percentage strings and \"auto\" for responsive resolution."
  (let ((w (cdr (assoc "width" props)))
        (h (cdr (assoc "height" props))))
    (cons (or w cmacs-org-ex-default-width)
          (or h cmacs-org-ex-default-height))))

(defun cmacs-org-ex--resolve-dimensions (width-spec height-spec)
  "Resolve WIDTH-SPEC and HEIGHT-SPEC to pixel values.
Uses the current window's pixel dimensions for percentage calculations."
  (let ((win-w (window-body-width nil t))
        (win-h (window-body-height nil t)))
    (cons (cmacs-org-ex--resolve-size-spec
           width-spec cmacs-org-ex-default-width win-w)
          (cmacs-org-ex--resolve-size-spec
           height-spec cmacs-org-ex-default-height win-h))))

;;; Block parsing

(defun cmacs-org-ex--parse-block-subtype (element)
  "Extract the widget subtype string from a special block ELEMENT.
Returns the word after BEGIN_WIDGET, e.g. \"slider\"."
  (let ((type (org-element-property :type element)))
    (when (string-equal-ignore-case type "WIDGET")
      (save-excursion
        (goto-char (org-element-property :begin element))
        (when (re-search-forward
               "^[ \t]*#\\+BEGIN_WIDGET[ \t]+\\(\\S-+\\)"
               (line-end-position) t)
          (match-string-no-properties 1))))))

(defun cmacs-org-ex--parse-block-properties (element)
  "Parse :key value property lines from the contents of ELEMENT.
Returns an alist of (KEY . VALUE) pairs where KEY is a string."
  (let ((beg (org-element-property :contents-begin element))
        (end (org-element-property :contents-end element))
        props)
    (when (and beg end)
      (let ((contents (buffer-substring-no-properties beg end)))
        (dolist (line (split-string contents "\n" t "[ \t]+"))
          (when (string-match "^:\\([^ \t]+\\)[ \t]+\\(.+\\)$" line)
            (push (cons (match-string 1 line)
                        (match-string 2 line))
                  props)))))
    (nreverse props)))

(defun cmacs-org-ex--generate-id (subtype element)
  "Generate a widget ID from SUBTYPE and ELEMENT position."
  (format "%s-%d" subtype (org-element-property :begin element)))

;;; Overlay management

(defun cmacs-org-ex--make-overlay (element xw subtype props)
  "Create an overlay spanning ELEMENT, displaying xwidget XW.
SUBTYPE and PROPS are used for the fallback text description."
  (let* ((beg (org-element-property :begin element))
         (end (save-excursion
                (goto-char (org-element-property :end element))
                (when (re-search-backward
                       "^[ \t]*#\\+END_WIDGET"
                       (org-element-property :begin element) t)
                  (forward-line 1))
                (point)))
         (ov (make-overlay beg end nil t nil)))
    ;; Hide the block text.
    (overlay-put ov 'invisible 'cmacs-org-ex)
    ;; Display the xwidget via before-string with display spec,
    ;; with newlines before and after so it sits on its own line.
    (let ((str (concat "\n"
                       (propertize " "
                                   'display (list 'xwidget :xwidget xw))
                       "\n")))
      (overlay-put ov 'before-string str))
    (overlay-put ov 'cmacs-org-ex t)
    (overlay-put ov 'evaporate t)
    ov))

(defun cmacs-org-ex--remove-overlays ()
  "Remove all org-ex overlays from the current buffer."
  (dolist (ov cmacs-org-ex--overlays)
    (when (overlay-buffer ov)
      (delete-overlay ov)))
  (setq cmacs-org-ex--overlays nil)
  (setq cmacs-org-ex--widget-ids nil))

;;; Rendering support detection

(defun cmacs-org-ex--webkit-available-p ()
  "Return non-nil if WebKit xwidgets can render content."
  (fboundp 'xwidget-webkit-goto-uri))

(defun cmacs-org-ex--gtk-embed-available-p ()
  "Return non-nil if gtk-embed xwidgets are available (pgtk build)."
  (fboundp 'xwidget-gtk-embed-set-widget))

(defun cmacs-org-ex--gtk-widget-subtype-p (subtype)
  "Return non-nil if SUBTYPE produces a native GTK widget."
  (member subtype '("slider" "elisp" "web")))

(defun cmacs-org-ex--make-gtk-embed-overlay (element widget width height
                                                     subtype props)
  "Create an overlay embedding GTK WIDGET directly in the buffer.
ELEMENT is the org element, WIDTH and HEIGHT set the xwidget size.
SUBTYPE and PROPS are stored for later reference.
WIDGET is an OrgExWidgetGtk — the underlying GtkWidget is extracted."
  (let* ((gtk-widget (org-ex-widget-gtk-get-widget widget))
         (xw (make-xwidget 'gtk-embed
                            (format "org-ex-%s" subtype)
                            width height)))
    (xwidget-gtk-embed-set-widget xw gtk-widget)
    (xwidget-resize xw width height)
    (cmacs-org-ex--make-overlay element xw subtype props)))

;;; Text fallback rendering (when WebKit is unavailable)

(defface cmacs-org-ex-widget-border
  '((t :foreground "steel blue"))
  "Face for widget border lines."
  :group 'cmacs-org-ex)

(defface cmacs-org-ex-widget-header
  '((t :weight bold :foreground "steel blue"))
  "Face for widget type header."
  :group 'cmacs-org-ex)

(defface cmacs-org-ex-widget-output
  '((t :foreground "dark green"))
  "Face for widget evaluation output."
  :group 'cmacs-org-ex)

(defun cmacs-org-ex--render-text (subtype props)
  "Render a text-based display of widget SUBTYPE with PROPS."
  (let ((code (cdr (assoc "code" props)))
        (output (cdr (assoc "_output" props)))
        (url (cdr (assoc "url" props)))
        (html (cdr (assoc "html" props)))
        (file (cdr (assoc "file" props))))
    (concat
     (propertize (format "\n┌─── %s ───\n" subtype)
                 'face 'cmacs-org-ex-widget-header)
     (pcase subtype
       ((or "crispy" "bacon" "elisp")
        (concat
         (when code
           (propertize (concat "│ " (replace-regexp-in-string
                                     "\n" "\n│ " code)
                               "\n")
                       'face 'font-lock-string-face))
         (when (and output (not (string-empty-p output)))
           (concat
            (propertize "│ ── output ──\n"
                        'face 'cmacs-org-ex-widget-border)
            (propertize (concat "│ " (replace-regexp-in-string
                                      "\n" "\n│ " output)
                                "\n")
                        'face 'cmacs-org-ex-widget-output)))))
       ("web"
        (cond
         (url (propertize (format "│ URL: %s\n" url) 'face 'link))
         (html (propertize "│ [inline HTML]\n" 'face 'italic))
         (t "│ [web widget]\n")))
       ("buffer"
        (if file
            (concat
             (propertize (format "│ File: %s\n" file) 'face 'link)
             (let ((path (expand-file-name file)))
               (if (file-readable-p path)
                   (with-temp-buffer
                     (insert-file-contents path nil 0 2048)
                     (let ((content (buffer-string)))
                       (propertize
                        (concat "│ " (replace-regexp-in-string
                                      "\n" "\n│ "
                                      (if (> (length content) 2000)
                                          (concat (substring content 0 2000) "…")
                                        content))
                                "\n")
                        'face 'font-lock-comment-face)))
                 (propertize (format "│ [file not found: %s]\n" file)
                             'face 'error))))
          "│ [buffer widget]\n"))
       ("slider"
        (let ((min-val (or (cdr (assoc "min" props)) "0"))
              (max-val (or (cdr (assoc "max" props)) "100"))
              (value (or (cdr (assoc "value" props)) "50")))
          (propertize (format "│ [%s] (%s – %s)\n" value min-val max-val)
                      'face 'font-lock-constant-face)))
       (_ (format "│ [%s widget]\n" subtype)))
     (propertize "└────────────\n"
                 'face 'cmacs-org-ex-widget-border))))

(defun cmacs-org-ex--make-text-overlay (element subtype props)
  "Create a text-based overlay for ELEMENT when xwidgets are unavailable.
SUBTYPE and PROPS describe the widget."
  (let* ((beg (org-element-property :begin element))
         (end (org-element-property :end element))
         (ov (make-overlay beg end nil t nil))
         (text (cmacs-org-ex--render-text subtype props)))
    (overlay-put ov 'invisible 'cmacs-org-ex)
    (overlay-put ov 'before-string text)
    (overlay-put ov 'cmacs-org-ex t)
    (overlay-put ov 'evaporate t)
    ov))

;;; WebKit xwidget rendering

(defun cmacs-org-ex--load-xwidget-content (xw subtype props widget)
  "Load content into xwidget XW based on SUBTYPE and PROPS.
WIDGET is the OrgExWidget GObject."
  (pcase subtype
    ("web"
     (let ((url (cdr (assoc "url" props)))
           (html (cdr (assoc "html" props))))
       (cond
        (url  (xwidget-webkit-goto-uri xw url))
        (html (xwidget-webkit-goto-uri
               xw (concat "data:text/html;charset=utf-8,"
                          (url-hexify-string html)))))))
    ("buffer"
     (let* ((file (cdr (assoc "file" props)))
            (html (format "<pre style='margin:0;padding:8px;font-family:monospace;font-size:13px;background:#f8f8f8;'>%s</pre>"
                          (if (and file (file-readable-p
                                         (expand-file-name file)))
                              (with-temp-buffer
                                (insert-file-contents
                                 (expand-file-name file))
                                (xml-escape-string
                                 (buffer-string)))
                            (format "[File not found: %s]" file)))))
       (xwidget-webkit-goto-uri
        xw (concat "data:text/html;charset=utf-8,"
                   (url-hexify-string html)))))
    ((or "elisp" "crispy" "bacon")
     (let* ((code (cdr (assoc "code" props)))
            (output (cdr (assoc "_output" props)))
            (html (concat
                   "<pre style='margin:0;padding:8px;font-family:monospace;font-size:13px;background:#1e1e2e;color:#cdd6f4;'>"
                   (xml-escape-string (or code ""))
                   "</pre>"
                   (when (and output (not (string-empty-p output)))
                     (format "<pre style='margin:0;padding:8px;font-family:monospace;font-size:13px;background:#181825;color:#a6e3a1;border-top:1px solid #45475a;'>%s</pre>"
                             (xml-escape-string output))))))
       (xwidget-webkit-goto-uri
        xw (concat "data:text/html;charset=utf-8,"
                   (url-hexify-string html)))))
    ("slider"
     ;; Slider renders as an HTML range input.
     (let* ((min-val (or (cdr (assoc "min" props)) "0"))
            (max-val (or (cdr (assoc "max" props)) "100"))
            (value   (or (cdr (assoc "value" props)) "50"))
            (step    (or (cdr (assoc "step" props)) "1"))
            (html (format
                   "<body style='margin:0;padding:8px;display:flex;align-items:center;gap:8px;font-family:sans-serif;'>\
<input type='range' min='%s' max='%s' value='%s' step='%s' style='flex:1;' \
oninput='document.getElementById(\"v\").textContent=this.value'>\
<span id='v'>%s</span></body>"
                   min-val max-val value step value)))
       (xwidget-webkit-goto-uri
        xw (concat "data:text/html;charset=utf-8,"
                   (url-hexify-string html)))))))

(defun cmacs-org-ex--instantiate-block (element)
  "Parse ELEMENT as a widget block and create the widget.
Returns the overlay, or nil on failure."
  (let* ((subtype (cmacs-org-ex--parse-block-subtype element))
         (props (cmacs-org-ex--parse-block-properties element))
         (id (cmacs-org-ex--generate-id subtype element))
         (size-spec (cmacs-org-ex--parse-size-spec props))
         (dims (cmacs-org-ex--resolve-dimensions
                (car size-spec) (cdr size-spec)))
         (width (car dims))
         (height (cdr dims)))
    (when subtype
      (condition-case err
          (let ((widget (cmacs-org-ex-create-widget
                         subtype props width height)))
            (when widget
              (org-ex-document-register-widget
               cmacs-org-ex--document id widget)
              ;; Set up bindings if requested.
              (when (fboundp 'cmacs-org-ex-setup-bindings)
                (cmacs-org-ex-setup-bindings
                 cmacs-org-ex--document widget props))
              ;; Set up reactive re-evaluation / timers.
              (when (fboundp 'cmacs-org-ex-setup-reactive)
                (let ((create-fn (gethash subtype
                                          cmacs-org-ex--widget-types)))
                  (cmacs-org-ex-setup-reactive
                   id widget props create-fn width height subtype)))
              ;; Store size spec for responsive resize.
              (when (or (stringp (car size-spec))
                        (stringp (cdr size-spec)))
                (setf (alist-get id cmacs-org-ex--size-specs
                                 nil nil #'equal)
                      size-spec))
              (let ((ov (cond
                         ;; GTK widget types: embed natively via gtk-embed.
                         ((and (cmacs-org-ex--gtk-embed-available-p)
                               (cmacs-org-ex--gtk-widget-subtype-p subtype)
                               (gobject-p widget)
                               (condition-case nil
                                   (org-ex-widget-gtk-get-widget widget)
                                 (error nil)))
                          (cmacs-org-ex--make-gtk-embed-overlay
                           element widget width height subtype props))
                         ;; WebKit rendering for web/buffer/code types.
                         ((cmacs-org-ex--webkit-available-p)
                          (let* ((xw (make-xwidget
                                      'webkit
                                      (format "org-ex-%s" id)
                                      width height))
                                 (o (cmacs-org-ex--make-overlay
                                     element xw subtype props)))
                            (cmacs-org-ex--load-xwidget-content
                             xw subtype props widget)
                            o))
                         ;; Text fallback rendering.
                         (t
                          (cmacs-org-ex--make-text-overlay
                           element subtype props)))))
                (push ov cmacs-org-ex--overlays)
                (push (cons id ov) cmacs-org-ex--widget-ids)
                ;; Track wayland widget overlays by PID for async
                ;; replacement when the client maps.
                (when-let* ((pid-str (cdr (assoc "_wayland_pid" props))))
                  (push (cons (string-to-number pid-str) ov)
                        cmacs-org-ex--wayland-overlay-map))
                ov)))
        (error
         (message "org-ex: failed to create %s widget: %s"
                  subtype (error-message-string err))
         (warn "org-ex: failed to create %s widget: %s"
               subtype (error-message-string err))
         nil)))))

;;; Buffer scanning

(defun cmacs-org-ex--eval-src-block-p (element)
  "Return non-nil if src block ELEMENT should be auto-evaluated.
A src block is auto-evaluated when it has the attribute
  #+ATTR_ORGEX: :eval t
and its language is emacs-lisp."
  (and (string-equal-ignore-case
        (or (org-element-property :language element) "") "emacs-lisp")
       (let ((attrs (org-element-property :attr_orgex element)))
         (cl-some (lambda (attr)
                    (string-match-p ":eval\\b" attr))
                  attrs))))

(defun cmacs-org-ex--eval-src-block (element)
  "Evaluate an emacs-lisp src block ELEMENT if marked for auto-eval.
Subject to `cmacs-org-ex-eval-policy' (see `cmacs-org-ex--eval-allowed-p')."
  (when (and (cmacs-org-ex--eval-src-block-p element)
             (cmacs-org-ex--eval-allowed-p))
    (let ((code (org-element-property :value element)))
      (when code
        (condition-case err
            (eval (car (read-from-string (concat "(progn " code ")"))) t)
          (error
           (message "org-ex: error evaluating src block: %s"
                    (error-message-string err))))))))

(defun cmacs-org-ex--scan-buffer ()
  "Scan the current buffer for widget blocks and instantiate them.
Src blocks marked with #+ATTR_ORGEX: :eval t are evaluated first
so that bridge handlers and other setup code are registered before
widgets that depend on them are created."
  (cmacs-org-ex--remove-overlays)
  (let ((tree (org-element-parse-buffer)))
    (org-element-map tree 'src-block
      #'cmacs-org-ex--eval-src-block)
    (org-element-map tree 'special-block
      (lambda (element)
        (when (string-equal-ignore-case
               (org-element-property :type element) "WIDGET")
          (cmacs-org-ex--instantiate-block element))))))

;;; Change tracking

(defun cmacs-org-ex--after-change (beg end _len)
  "Handle buffer modifications between BEG and END.
Rebuilds any widget blocks that overlap the changed region."
  (when (and cmacs-org-ex-mode
             (not cmacs-org-ex--inhibit-change)
             cmacs-org-ex--document)
    ;; Check for #+PROPERTY: line changes.
    (save-excursion
      (goto-char beg)
      (when (re-search-forward
             "^[ \t]*#\\+PROPERTY:[ \t]+\\(\\S-+\\)[ \t]+\\(.+\\)$"
             end t)
        (let ((name (match-string-no-properties 1))
              (value (match-string-no-properties 2)))
          (org-ex-document-notify-property-changed
           cmacs-org-ex--document name value))))
    ;; Rebuild overlapping widget blocks.
    (let ((cmacs-org-ex--inhibit-change t))
      (dolist (pair (copy-sequence cmacs-org-ex--widget-ids))
        (let ((ov (cdr pair)))
          (when (and (overlay-buffer ov)
                     (< (overlay-start ov) end)
                     (> (overlay-end ov) beg))
            (let ((id (car pair)))
              (org-ex-document-remove-widget
               cmacs-org-ex--document id)
              (delete-overlay ov)
              (setq cmacs-org-ex--overlays
                    (delq ov cmacs-org-ex--overlays))
              (setq cmacs-org-ex--widget-ids
                    (assoc-delete-all
                     id cmacs-org-ex--widget-ids)))))))))

;;; Keyword detection

(defun cmacs-org-ex--keyword-enabled-p ()
  "Return non-nil if the buffer has #+ORGEX: t."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (re-search-forward
       "^[ \t]*#\\+ORGEX:[ \t]+t[ \t]*$" nil t))))

;;; Org link type

(defun cmacs-org-ex--link-follow (path _)
  "Follow a widget link with PATH of the form TYPE:PARAMS."
  (let* ((parts (split-string path ":"))
         (subtype (car parts))
         (params (mapconcat #'identity (cdr parts) ":")))
    (message "org-ex: inline widget %s (%s)" subtype params)))

(defun cmacs-org-ex--link-export (path desc backend _)
  "Export a widget link with PATH, DESC, and BACKEND."
  (let ((subtype (car (split-string path ":"))))
    (pcase backend
      ('html (format "<span class=\"org-ex-widget\" data-type=\"%s\">%s</span>"
                     subtype (or desc path)))
      ('latex (format "\\texttt{%s}" (or desc path)))
      (_ (or desc path)))))

(with-eval-after-load 'ol
  (org-link-set-parameters "widget"
                           :follow #'cmacs-org-ex--link-follow
                           :export #'cmacs-org-ex--link-export))

;;; Org-mode hook

(defun cmacs-org-ex--org-mode-hook ()
  "Auto-enable `cmacs-org-ex-mode' when #+ORGEX: t is present."
  (when (and (cmacs-feature-p 'org-ex)
             (cmacs-org-ex--keyword-enabled-p))
    (cmacs-org-ex-mode 1)))

;;; Minor mode

;;;###autoload
(define-minor-mode cmacs-org-ex-mode
  "Minor mode for interactive widget embedding in Org buffers.

When enabled, scans the buffer for #+BEGIN_WIDGET ... #+END_WIDGET
special blocks, creates the corresponding widgets via the org-ex
C layer, and displays them as overlays.

Requires the org-ex C subsystem to be compiled in.

\\{cmacs-org-ex-mode-map}"
  :lighter " OrgEx"
  :group 'cmacs-org-ex
  (if cmacs-org-ex-mode
      (progn
        (unless (cmacs-feature-p 'org-ex)
          (cmacs-org-ex-mode -1)
          (user-error "org-ex C subsystem not available"))
        (add-to-invisibility-spec '(cmacs-org-ex . t))
        (setq cmacs-org-ex--document
              (org-ex-document-create buffer-file-name))
        ;; Restore saved state if available.
        (when (fboundp 'cmacs-org-ex-state-restore)
          (cmacs-org-ex-state-restore))
        (cmacs-org-ex--scan-buffer)
        (add-hook 'after-change-functions
                  #'cmacs-org-ex--after-change nil t)
        (add-hook 'kill-buffer-hook
                  #'cmacs-org-ex--teardown nil t))
    (cmacs-org-ex--teardown)))

(defun cmacs-org-ex--teardown ()
  "Tear down all org-ex state in the current buffer."
  (when cmacs-org-ex--document
    ;; Save state before teardown.
    (when (fboundp 'cmacs-org-ex-state-save)
      (cmacs-org-ex-state-save))
    (org-ex-document-teardown-all cmacs-org-ex--document))
  (cmacs-org-ex--remove-overlays)
  (setq cmacs-org-ex--document nil)
  (remove-hook 'after-change-functions
               #'cmacs-org-ex--after-change t)
  (remove-hook 'kill-buffer-hook
               #'cmacs-org-ex--teardown t))

;;;###autoload
(with-eval-after-load 'org
  (add-hook 'org-mode-hook
            (lambda ()
              (when (and (fboundp 'org-ex-document-create)
                         (save-excursion
                           (save-restriction
                             (widen)
                             (goto-char (point-min))
                             (re-search-forward
                              "^[ \t]*#\\+ORGEX:[ \t]+t[ \t]*$"
                              nil t))))
                (cmacs-org-ex-mode 1)))))

(provide 'cmacs-org-ex)
;;; cmacs-org-ex.el ends here
