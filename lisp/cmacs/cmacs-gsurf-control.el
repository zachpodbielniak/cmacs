;;; cmacs-gsurf-control.el --- gsurf 0.5 control surface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Emacs commands over the toolkit-neutral libgsurf features (the C half
;; is cmacs/gsurf/cmacs-gsurf-control.c):
;;
;;   - page input: trusted key presses, clicks and typing, and "click the
;;     element matching a CSS selector" (`cmacs-gsurf-press-key',
;;     `cmacs-gsurf-type-text', `cmacs-gsurf-click-selector',
;;     `cmacs-gsurf-focus-first-input');
;;   - cookies and proxy (`cmacs-gsurf-cookie-add', `cmacs-gsurf-proxy');
;;   - containers: open a page in a named or temporary container
;;     (`cmacs-gsurf-open-in-container',
;;     `cmacs-gsurf-open-in-temporary-container',
;;     `cmacs-gsurf-reopen-in-container');
;;   - "Open Link in New Tab" opens a child buffer, and `cmacs-gsurf-tree'
;;     draws the buffers as the opener tree gsurf records;
;;   - every gsurf action by name (`cmacs-gsurf-run-action'), with the
;;     module ones (dark mode, form autofill) on their own commands;
;;   - the page input mode (NORMAL/INSERT/FOLLOW/...) in the mode line;
;;   - `cmacs-gsurf-keybinds-help', gsurf's help overlay as a buffer.
;;
;; The standalone gsurf window's tab strip, tree sidebar, wmux panes and
;; control socket have no counterpart here on purpose: Emacs buffers are
;; the tabs and Emacs windows the panes.
;;
;; This file is loaded by cmacs-gsurf.el (at its end) and does not
;; require it back, to keep the load acyclic.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'json)
(require 'url-parse)

;; C primitives (cmacs/gsurf/cmacs-gsurf-control.c).
(declare-function cmacs-gsurf-keyval "cmacs-gsurf-control.c" (name))
(declare-function cmacs-gsurf-modifier-mask "cmacs-gsurf-control.c" (modifiers))
(declare-function cmacs-gsurf-send-key "cmacs-gsurf-control.c"
                  (buffer key &optional modifiers))
(declare-function cmacs-gsurf-click "cmacs-gsurf-control.c"
                  (buffer x y &optional button modifiers))
(declare-function cmacs-gsurf-type "cmacs-gsurf-control.c" (buffer text))
(declare-function cmacs-gsurf-click-element "cmacs-gsurf-control.c"
                  (buffer selector &optional callback button))
(declare-function cmacs-gsurf-add-cookie "cmacs-gsurf-control.c"
                  (buffer cookie &optional callback))
(declare-function cmacs-gsurf-set-cookie-policy "cmacs-gsurf-control.c"
                  (buffer policy))
(declare-function cmacs-gsurf-set-proxy "cmacs-gsurf-control.c" (buffer uri))
(declare-function cmacs-gsurf-containers "cmacs-gsurf-control.c" ())
(declare-function cmacs-gsurf-containers-enabled-p "cmacs-gsurf-control.c" ())
(declare-function cmacs-gsurf-container-id "cmacs-gsurf-control.c" (buffer))
(declare-function cmacs-gsurf-view-id "cmacs-gsurf-control.c" (buffer))
(declare-function cmacs-gsurf-opener-id "cmacs-gsurf-control.c" (buffer))
(declare-function cmacs-gsurf-buffer-for-view-id "cmacs-gsurf-control.c" (id))
(declare-function cmacs-gsurf-actions "cmacs-gsurf-control.c" ())
(declare-function cmacs-gsurf-dispatch-action "cmacs-gsurf-control.c"
                  (buffer action))
(declare-function cmacs-gsurf-input-mode "cmacs-gsurf-control.c" ())
(declare-function cmacs-gsurf-editing-p "cmacs-gsurf-control.c" (buffer))
(declare-function cmacs-gsurf-keybinds "cmacs-gsurf-control.c" ())
;; Older primitives and cmacs-gsurf.el helpers.
(declare-function cmacs-gsurf-attached-p "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-offscreen-p "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-page-focused-p "cmacs-gsurf-defuns.c"
                  (&optional buffer))
(declare-function cmacs-gsurf-focus-page "cmacs-gsurf-defuns.c"
                  (&optional buffer))
(declare-function cmacs-gsurf-release-focus "cmacs-gsurf-defuns.c" ())
(declare-function cmacs-gsurf-follow "cmacs-gsurf-defuns.c" (&optional buffer))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-load-uri "cmacs-gsurf-defuns.c" (buffer uri))
(declare-function cmacs-gsurf-stop "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-find-next "cmacs-gsurf-defuns.c"
                  (buffer &optional backward))
(declare-function cmacs-gsurf-module-set-enabled "cmacs-gsurf-defuns.c"
                  (name enabled))
(declare-function cmacs-gsurf "cmacs-gsurf" (&optional url))
(declare-function cmacs-gsurf--open "cmacs-gsurf" (url &optional container opener))
(declare-function cmacs-gsurf--live-buffers "cmacs-gsurf" ())
(declare-function cmacs-gsurf--normalize-url "cmacs-gsurf" (input))
(declare-function cmacs-gsurf--mcp-target "cmacs-gsurf" (&optional name))
(defvar cmacs-gsurf-home-url)
(defvar cmacs-gsurf-mode-map)

(defgroup cmacs-gsurf-control nil
  "Page input, containers, actions and help for cmacs-gsurf buffers."
  :group 'cmacs-gsurf
  :prefix "cmacs-gsurf-")

;;;; Hooks fired from C ---------------------------------------------

(defvar cmacs-gsurf-input-mode-changed-functions nil
  "Abnormal hook run when gsurf's input mode changes.
Each function is called with (MODE), a symbol from
`cmacs-gsurf-input-modes' (`normal', `insert', `follow', `find',
`passthrough').  The mode is process-wide: it is what the modal module
published, and governs keys only while a page holds the keyboard.")

(defvar cmacs-gsurf-editing-changed-functions nil
  "Abnormal hook run when a page field gains or loses DOM focus.
Each function is called with (BUFFER EDITING), EDITING non-nil while a
text input, textarea, contenteditable or select is focused.")

;;;; Input mode indicator -------------------------------------------

(defcustom cmacs-gsurf-show-input-mode t
  "When non-nil, show gsurf's input mode in a gsurf buffer's mode line.
The indicator (\"-- NORMAL --\", \"-- INSERT --\", \"-- FOLLOW --\") only
appears while the page holds the keyboard; while Emacs has it the
Emacs keymaps apply and nothing is shown."
  :type 'boolean
  :group 'cmacs-gsurf-control)

(defvar cmacs-gsurf--input-mode 'normal
  "Last gsurf input mode reported by C (process-wide).")

(defvar-local cmacs-gsurf--editing nil
  "Non-nil while a field has DOM focus in this buffer's page.")

(defun cmacs-gsurf--input-mode-text (mode editing focused)
  "Mode-line text for input MODE, page EDITING state and page FOCUSED.
Empty unless FOCUSED (the page holds the keyboard).  A focused field
reads INSERT in NORMAL mode, as gsurf's own indicators do."
  (if (not focused)
      ""
    (let ((m (if (and editing (memq mode '(nil normal))) 'insert
               (or mode 'normal))))
      (format "-- %s --  " (upcase (symbol-name m))))))

(defun cmacs-gsurf--mode-line-input-mode ()
  "Mode-line snippet: the page input mode while the page has the keys."
  (if (and cmacs-gsurf-show-input-mode
           (fboundp 'cmacs-gsurf-page-focused-p)
           (cmacs-gsurf-attached-p (current-buffer)))
      (propertize
       (cmacs-gsurf--input-mode-text
        cmacs-gsurf--input-mode cmacs-gsurf--editing
        (ignore-errors (cmacs-gsurf-page-focused-p (current-buffer))))
       'face 'mode-line-emphasis)
    ""))

(defun cmacs-gsurf--on-input-mode-changed (mode)
  "Default handler: record MODE and refresh the gsurf mode lines."
  (setq cmacs-gsurf--input-mode mode)
  (force-mode-line-update t))

(defun cmacs-gsurf--on-editing-changed (buffer editing)
  "Default handler: record BUFFER's EDITING state for its mode line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq cmacs-gsurf--editing editing)
      (force-mode-line-update))))

(add-hook 'cmacs-gsurf-input-mode-changed-functions
          #'cmacs-gsurf--on-input-mode-changed)
(add-hook 'cmacs-gsurf-editing-changed-functions
          #'cmacs-gsurf--on-editing-changed)

;;;; Page input -----------------------------------------------------

(defconst cmacs-gsurf--key-symbol-names
  '((return . "Return") (RET . "Return") (tab . "Tab") (TAB . "Tab")
    (escape . "Escape") (ESC . "Escape") (backspace . "BackSpace")
    (DEL . "BackSpace") (delete . "Delete") (deletechar . "Delete")
    (insert . "Insert") (left . "Left") (right . "Right") (up . "Up")
    (down . "Down") (home . "Home") (end . "End") (prior . "Page_Up")
    (next . "Page_Down") (SPC . "space") (menu . "Menu"))
  "Emacs key symbols and their X keysym names.")

(defun cmacs-gsurf--event-to-key (event)
  "Translate an Emacs input EVENT into (NAME . MODIFIERS) for gsurf.
NAME is a key name `cmacs-gsurf-keyval' accepts; MODIFIERS a list of
`shift', `control', `meta' and `super'.  Returns nil for events that
are not keys (mouse events)."
  (let* ((mods (cl-intersection (event-modifiers event)
                                '(shift control meta super)))
         (base (event-basic-type event))
         (name (cond
                ((characterp base)
                 (cond ((eq base ?\s) "space")
                       ((eq base ?\t) "Tab")
                       ((memq base '(?\r ?\n)) "Return")
                       ((eq base ?\e) "Escape")
                       ((eq base 127) "BackSpace")
                       (t (string base))))
                ((assq base cmacs-gsurf--key-symbol-names)
                 (cdr (assq base cmacs-gsurf--key-symbol-names)))
                ((and (symbolp base)
                      (string-match "\\`f\\([0-9]+\\)\\'" (symbol-name base)))
                 (concat "F" (match-string 1 (symbol-name base))))
                (t nil))))
    ;; `event-basic-type' folds an upper-case letter to lower case and
    ;; reports `shift'; type the letter as it was pressed instead.
    (when (and name (characterp event) (= (length name) 1)
               (/= (upcase event) (downcase event)))
      (setq name (string (logand event #x3fffff))
            mods (delq 'shift mods)))
    (and name (cons name mods))))

(defun cmacs-gsurf--modifiers-from-string (spec)
  "Parse SPEC, e.g. \"ctrl+shift\" or \"C-M\", into a modifier list.
Separators are `+', `-', `,' and spaces.  Nil or \"\" yields nil."
  (when (and spec (not (string-empty-p spec)))
    (mapcar (lambda (m)
              (pcase (downcase m)
                ((or "c" "ctrl" "control") 'control)
                ((or "m" "alt" "meta" "a") 'meta)
                ("shift" 'shift)
                ((or "s" "super" "logo" "win") (if (equal m "S") 'shift 'super))
                (_ (intern m))))
            (split-string spec "[-+, ]+" t))))

(defun cmacs-gsurf--target-buffer ()
  "The gsurf buffer an interactive command acts on, or a `user-error'."
  (let ((buf (current-buffer)))
    (unless (and (derived-mode-p 'cmacs-gsurf-mode)
                 (cmacs-gsurf-attached-p buf))
      (user-error "Not in a live gsurf buffer"))
    buf))

(defun cmacs-gsurf-press-key (event)
  "Read a key EVENT and press it in the current gsurf page.
The page gets a trusted key press while Emacs keeps the keyboard, so
this sends Tab, Enter, arrows or shortcuts to the page without focusing
it."
  (interactive (list (read-key "Key to send to the page: ")))
  (let ((key (cmacs-gsurf--event-to-key event)))
    (unless key (user-error "Not a key: %S" event))
    (cmacs-gsurf-send-key (cmacs-gsurf--target-buffer) (car key) (cdr key))
    (message "gsurf: sent %s%s"
             (mapconcat (lambda (m) (concat (symbol-name m) "+")) (cdr key) "")
             (car key))))

(defun cmacs-gsurf-type-text (text)
  "Type TEXT into the focused element of the current gsurf page.
Each character is a trusted key press; a newline presses Return.  Focus
a field first (\\[cmacs-gsurf-click-selector], \\[cmacs-gsurf-focus-first-input])."
  (interactive "sType into page: ")
  (cmacs-gsurf-type (cmacs-gsurf--target-buffer) text))

(defun cmacs-gsurf-click-at (x y &optional button)
  "Click at X, Y (CSS pixels) in the current gsurf page with BUTTON."
  (interactive "nX (CSS px): \nnY (CSS px): ")
  (cmacs-gsurf-click (cmacs-gsurf--target-buffer) x y button))

(defvar cmacs-gsurf--last-click-element nil
  "(SELECTOR RESULT) of the last finished click-element, for agents.
RESULT is t, nil (no match) or an error message.")

(defun cmacs-gsurf--report-click (selector)
  "A `cmacs-gsurf-click-element' callback reporting on SELECTOR."
  (lambda (result)
    (setq cmacs-gsurf--last-click-element (list selector result))
    (cond ((eq result t) (message "gsurf: clicked %s" selector))
          ((null result) (message "gsurf: nothing matches %s" selector))
          (t (message "gsurf: click on %s failed: %s" selector result)))))

(defun cmacs-gsurf-click-selector (selector &optional button)
  "Click the first element matching CSS SELECTOR in the current page.
It is scrolled into view and focused first, then clicked at its centre
with a trusted click; with a prefix argument, BUTTON 3 (right)."
  (interactive (list (read-string "CSS selector: ")
                     (and current-prefix-arg 3)))
  (cmacs-gsurf-click-element (cmacs-gsurf--target-buffer) selector
                             (cmacs-gsurf--report-click selector) button))

(defcustom cmacs-gsurf-first-input-selector
  (concat "input:not([type=hidden]):not([type=submit]):not([type=button])"
          ":not([type=checkbox]):not([type=radio]):not([disabled]),"
          "textarea:not([disabled]),[contenteditable=\"\"],"
          "[contenteditable=true]")
  "CSS selector `cmacs-gsurf-focus-first-input' clicks (vimium's `gi')."
  :type 'string
  :group 'cmacs-gsurf-control)

(defun cmacs-gsurf-focus-first-input ()
  "Click the page's first text field and hand the page the keyboard.
Vimium's `gi': type straight away; Escape returns to Emacs."
  (interactive)
  (let ((buf (cmacs-gsurf--target-buffer)))
    (cmacs-gsurf-click-element
     buf cmacs-gsurf-first-input-selector
     (lambda (result)
       (cond ((eq result t)
              (when (buffer-live-p buf)
                (cmacs-gsurf-focus-page buf)))
             ((null result) (message "gsurf: no text field on this page"))
             (t (message "gsurf: %s" result)))))))

;;;; Cookies and proxy ----------------------------------------------

(defun cmacs-gsurf--current-host (buffer)
  "The host of BUFFER's current URI, or nil."
  (let ((uri (ignore-errors (cmacs-gsurf-get-uri buffer))))
    (and uri (url-host (url-generic-parse-url uri)))))

(defun cmacs-gsurf-cookie-add (name value domain &optional path secure)
  "Add cookie NAME=VALUE for DOMAIN (and PATH) to this view's session.
With a prefix argument the cookie is SECURE (https only).  It lands in
the view's own cookie jar -- its container's, for a view in one."
  (interactive
   (let* ((buf (cmacs-gsurf--target-buffer))
          (host (cmacs-gsurf--current-host buf)))
     (list (read-string "Cookie name: ")
           (read-string "Cookie value: ")
           (read-string (format-prompt "Domain" host) nil nil host)
           (read-string "Path: " nil nil "/")
           current-prefix-arg)))
  (cmacs-gsurf-add-cookie
   (cmacs-gsurf--target-buffer)
   (list :name name :value value :domain domain :path (or path "/")
         :secure (and secure t))
   (lambda (r)
     (if (eq r t) (message "gsurf: cookie %s set for %s" name domain)
       (message "gsurf: cookie not stored: %s" r)))))

(defun cmacs-gsurf-proxy (uri)
  "Route the current view's session through proxy URI (empty = system).
E.g. socks5://127.0.0.1:9050.  Applies to every view sharing the
session; use a container for a per-identity proxy."
  (interactive "sProxy URI (empty for system default): ")
  (cmacs-gsurf-set-proxy (cmacs-gsurf--target-buffer)
                         (if (string-empty-p uri) nil uri)))

;;;; Containers -----------------------------------------------------

(defun cmacs-gsurf--container-candidates ()
  "Completion candidates for a container: ids plus the two tokens."
  (append (list "temporary" "default")
          (mapcar (lambda (c) (plist-get c :id)) (cmacs-gsurf-containers))))

(defun cmacs-gsurf--read-container (prompt)
  "Read a container id with PROMPT."
  (completing-read prompt (cmacs-gsurf--container-candidates) nil nil nil nil
                   "temporary"))

(defun cmacs-gsurf--current-uri-or-home ()
  "The current gsurf buffer's URI, else `cmacs-gsurf-home-url'."
  (or (and (derived-mode-p 'cmacs-gsurf-mode)
           (ignore-errors (cmacs-gsurf-get-uri (current-buffer))))
      cmacs-gsurf-home-url))

(defun cmacs-gsurf-open-in-container (url container)
  "Open URL in a new gsurf buffer browsing in CONTAINER.
CONTAINER is a container id, \"temporary\" (a fresh throw-away
container) or \"default\".  The current gsurf buffer, if any, is
recorded as the opener."
  (interactive
   (list (read-string (format-prompt "URL" (cmacs-gsurf--current-uri-or-home))
                      nil nil (cmacs-gsurf--current-uri-or-home))
         (cmacs-gsurf--read-container "Container: ")))
  (let* ((opener (and (derived-mode-p 'cmacs-gsurf-mode) (current-buffer)))
         (buf (cmacs-gsurf--open url container opener)))
    (switch-to-buffer buf)
    buf))

(defun cmacs-gsurf-open-in-temporary-container (url)
  "Open URL in a new gsurf buffer in a new temporary container.
Its cookies and storage vanish shortly after the buffer is killed."
  (interactive
   (list (read-string (format-prompt "URL" (cmacs-gsurf--current-uri-or-home))
                      nil nil (cmacs-gsurf--current-uri-or-home))))
  (cmacs-gsurf-open-in-container url "temporary"))

(defun cmacs-gsurf-reopen-in-container (container)
  "Reopen the current page in CONTAINER, replacing this buffer.
A view's container is fixed when it is created, so this opens a new
buffer (same opener) in CONTAINER, shows it in this window and kills
the old one."
  (interactive (list (cmacs-gsurf--read-container "Reopen in container: ")))
  (let* ((old (cmacs-gsurf--target-buffer))
         (uri (or (cmacs-gsurf-get-uri old) cmacs-gsurf-home-url))
         (buf (cmacs-gsurf--open uri container
                                 (bound-and-true-p cmacs-gsurf--opener))))
    (switch-to-buffer buf)
    (kill-buffer old)
    buf))

(defun cmacs-gsurf-list-containers ()
  "Show the gsurf containers in the echo area."
  (interactive)
  (let ((cs (cmacs-gsurf-containers)))
    (message "%s"
             (if cs
                 (mapconcat (lambda (c)
                              (format "%s%s (%d view%s)"
                                      (plist-get c :id)
                                      (if (plist-get c :temporary) "*" "")
                                      (plist-get c :views)
                                      (if (= 1 (plist-get c :views)) "" "s")))
                            cs ", ")
               (if (cmacs-gsurf-containers-enabled-p)
                   "No containers defined"
                 "No containers (enable `cmacs-gsurf-containers')")))))

;;;; New views ("Open Link in New Tab") and the buffer tree ---------

(defcustom cmacs-gsurf-new-view-display-function #'switch-to-buffer
  "How a gsurf buffer opened by \"Open Link in New Tab\" is shown.
Called with the new buffer when the page asked for a foreground tab; a
background request never displays it.  Nil never displays."
  :type '(choice (const :tag "Do not display" nil)
                 (function-item switch-to-buffer)
                 (function-item pop-to-buffer)
                 (function-item display-buffer)
                 function)
  :group 'cmacs-gsurf-control)

(defun cmacs-gsurf--open-child (url background opener-id)
  "Open URL as a child of the gsurf view OPENER-ID (from C).
The page context menu's \"Open Link in New Tab\" (and modules calling
gsurf_view_request_new_view) land here.  BACKGROUND non-nil keeps the
opener in front."
  (when (and url (not (string-empty-p url)))
    (let* ((opener (cmacs-gsurf-buffer-for-view-id opener-id))
           (buf (cmacs-gsurf--open url nil opener)))
      (cond (background
             (message "gsurf: opened %s in the background" (buffer-name buf)))
            ((functionp cmacs-gsurf-new-view-display-function)
             (funcall cmacs-gsurf-new-view-display-function buf)))
      buf)))

(defun cmacs-gsurf--tree-order (nodes)
  "Order NODES as an opener tree.
NODES is a list of (KEY ID OPENER-ID).  Returns a list of
\(KEY . DEPTH) in depth-first order, siblings in input order.  A node
whose opener is not among NODES (closed, or opened by the user) is a
root.  Cycles cannot occur in gsurf (an opener is older than its
children) but are broken defensively."
  (let ((ids (make-hash-table :test 'eql))
        (children (make-hash-table :test 'eql))
        (seen (make-hash-table :test 'eql))
        roots out)
    (dolist (n nodes) (puthash (nth 1 n) n ids))
    (dolist (n nodes)
      (let ((parent (nth 2 n)))
        (if (and parent (gethash parent ids) (not (eql parent (nth 1 n))))
            (puthash parent (append (gethash parent children) (list n))
                     children)
          (push n roots))))
    (cl-labels ((walk (n depth)
                  (unless (gethash (nth 1 n) seen)
                    (puthash (nth 1 n) t seen)
                    (push (cons (car n) depth) out)
                    (dolist (c (gethash (nth 1 n) children))
                      (walk c (1+ depth))))))
      (dolist (r (nreverse roots)) (walk r 0))
      ;; Anything unreached sat on a cycle: list it as a root.
      (dolist (n nodes)
        (unless (gethash (nth 1 n) seen) (walk n 0))))
    (nreverse out)))

(defun cmacs-gsurf--tree-nodes ()
  "(BUFFER VIEW-ID OPENER-ID) for every live, visible-kind gsurf buffer."
  (let (nodes)
    (dolist (b (reverse (cmacs-gsurf--live-buffers)))
      (when (and (cmacs-gsurf-attached-p b) (not (cmacs-gsurf-offscreen-p b)))
        (push (list b (cmacs-gsurf-view-id b) (cmacs-gsurf-opener-id b)) nodes)))
    (nreverse nodes)))

(defvar cmacs-gsurf-tree-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cmacs-gsurf-tree-visit)
    (define-key m (kbd "o")   #'cmacs-gsurf-tree-visit-other-window)
    (define-key m (kbd "k")   #'cmacs-gsurf-tree-kill)
    (define-key m (kbd "g")   #'cmacs-gsurf-tree-refresh)
    (define-key m (kbd "n")   #'next-line)
    (define-key m (kbd "p")   #'previous-line)
    m)
  "Keymap for `cmacs-gsurf-tree-mode'.")

(define-derived-mode cmacs-gsurf-tree-mode special-mode "gsurf-tree"
  "Gsurf buffers drawn as the tree of which page opened which.
\\{cmacs-gsurf-tree-mode-map}"
  (setq-local revert-buffer-function
              (lambda (&rest _) (cmacs-gsurf-tree-refresh)))
  (setq truncate-lines t))

(defun cmacs-gsurf-tree-refresh ()
  "Redraw the *gsurf-tree* buffer."
  (interactive)
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize "gsurf buffers (by opener)\n\n" 'face 'bold))
    (let ((rows (cmacs-gsurf--tree-order (cmacs-gsurf--tree-nodes))))
      (if (null rows)
          (insert "  (no gsurf buffers)\n")
        (dolist (row rows)
          (let* ((b (car row))
                 (title (or (ignore-errors (cmacs-gsurf-get-title b)) ""))
                 (uri (or (ignore-errors (cmacs-gsurf-get-uri b)) ""))
                 (ctr (ignore-errors (cmacs-gsurf-container-id b))))
            (insert (propertize
                     (concat (make-string (* 2 (cdr row)) ?\s)
                             (if (> (cdr row) 0) "└ " "• ")
                             (if (string-empty-p title) (buffer-name b) title)
                             (if ctr (propertize (format "  [%s]" ctr)
                                                 'face 'font-lock-type-face)
                               "")
                             "  "
                             (propertize uri 'face 'shadow)
                             "\n")
                     'cmacs-gsurf-tree-buffer b))))))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun cmacs-gsurf--tree-buffer-at-point ()
  "The gsurf buffer on the current tree line, or a `user-error'."
  (let ((b (get-text-property (line-beginning-position)
                              'cmacs-gsurf-tree-buffer)))
    (unless (buffer-live-p b) (user-error "No gsurf buffer on this line"))
    b))

(defun cmacs-gsurf-tree-visit ()
  "Show the gsurf buffer on this line in this window."
  (interactive)
  (switch-to-buffer (cmacs-gsurf--tree-buffer-at-point)))

(defun cmacs-gsurf-tree-visit-other-window ()
  "Show the gsurf buffer on this line in another window."
  (interactive)
  (switch-to-buffer-other-window (cmacs-gsurf--tree-buffer-at-point)))

(defun cmacs-gsurf-tree-kill ()
  "Kill the gsurf buffer on this line."
  (interactive)
  (kill-buffer (cmacs-gsurf--tree-buffer-at-point))
  (cmacs-gsurf-tree-refresh))

(defun cmacs-gsurf-tree ()
  "Show every gsurf buffer as the tree of which page opened which.
Buffers opened from a link (\"Open Link in New Tab\", a popup, a
container reopen) are indented under their opener; the opener id is
kept by gsurf, so a child of a closed buffer becomes a root."
  (interactive)
  (let ((buf (get-buffer-create "*gsurf-tree*")))
    (with-current-buffer buf
      (cmacs-gsurf-tree-mode)
      (cmacs-gsurf-tree-refresh))
    (pop-to-buffer buf)))

;;;; Actions --------------------------------------------------------

(defun cmacs-gsurf--next-gsurf-buffer (step)
  "Switch STEP (1 or -1) gsurf buffers along the live list."
  (let* ((bufs (seq-filter (lambda (b) (not (cmacs-gsurf-offscreen-p b)))
                           (cmacs-gsurf--live-buffers)))
         (pos (cl-position (current-buffer) bufs)))
    (when bufs
      (switch-to-buffer (nth (mod (+ (or pos 0) step) (length bufs)) bufs)))))

(defconst cmacs-gsurf--core-action-commands
  '(("back" . cmacs-gsurf-back-buffer)
    ("forward" . cmacs-gsurf-forward-buffer)
    ("reload" . cmacs-gsurf-reload-buffer)
    ("reload-nocache" . cmacs-gsurf-reload-nocache)
    ("stop" . cmacs-gsurf--action-stop)
    ("home" . cmacs-gsurf--action-home)
    ("open-prompt" . cmacs-gsurf-open-url)
    ("open-new-view" . cmacs-gsurf)
    ("tab-new" . cmacs-gsurf)
    ("scroll-up" . cmacs-gsurf-scroll-up)
    ("scroll-down" . cmacs-gsurf-scroll-down)
    ("scroll-left" . cmacs-gsurf-scroll-left)
    ("scroll-right" . cmacs-gsurf-scroll-right)
    ("scroll-top" . cmacs-gsurf-scroll-top)
    ("scroll-bottom" . cmacs-gsurf-scroll-bottom)
    ("page-up" . cmacs-gsurf-scroll-screen-up)
    ("page-down" . cmacs-gsurf-scroll-screen-down)
    ("half-page-up" . cmacs-gsurf-scroll-half-up)
    ("half-page-down" . cmacs-gsurf-scroll-half-down)
    ("zoom-in" . cmacs-gsurf-zoom-in)
    ("zoom-out" . cmacs-gsurf-zoom-out)
    ("zoom-reset" . cmacs-gsurf-zoom-reset)
    ("find" . cmacs-gsurf-find-in-page)
    ("find-next" . cmacs-gsurf--action-find-next)
    ("find-prev" . cmacs-gsurf--action-find-prev)
    ("copy-url" . cmacs-gsurf--action-copy-url)
    ("enter-normal-mode" . cmacs-gsurf-release-focus)
    ("enter-insert-mode" . cmacs-gsurf-focus-page)
    ("follow-hints" . cmacs-gsurf-follow)
    ("tab-close" . kill-current-buffer)
    ("tab-next" . cmacs-gsurf--action-tab-next)
    ("tab-prev" . cmacs-gsurf--action-tab-prev)
    ("tab-sidebar-toggle" . cmacs-gsurf-tree)
    ("show-keybinds" . cmacs-gsurf-keybinds-help)
    ("container-new-temp" . cmacs-gsurf-open-in-temporary-container)
    ("container-reopen-next" . cmacs-gsurf--action-reopen-next))
  "Core gsurf actions mapped onto cmacs commands.
The standalone gsurf window implements these itself; in Emacs they are
ordinary commands.  Every other action is offered to the gsurf modules
through `cmacs-gsurf-dispatch-action'.")

(defun cmacs-gsurf--action-stop ()
  "Stop loading the current page."
  (interactive)
  (cmacs-gsurf-stop (cmacs-gsurf--target-buffer)))

(defun cmacs-gsurf--action-home ()
  "Load `cmacs-gsurf-home-url' in the current buffer."
  (interactive)
  (cmacs-gsurf-load-uri (cmacs-gsurf--target-buffer)
                        (cmacs-gsurf--normalize-url cmacs-gsurf-home-url)))

(defun cmacs-gsurf--action-find-next ()
  "Next find match."
  (interactive)
  (cmacs-gsurf-find-next (cmacs-gsurf--target-buffer)))

(defun cmacs-gsurf--action-find-prev ()
  "Previous find match."
  (interactive)
  (cmacs-gsurf-find-next (cmacs-gsurf--target-buffer) t))

(defun cmacs-gsurf--action-copy-url ()
  "Copy the current URI to the kill ring."
  (interactive)
  (let ((u (cmacs-gsurf-get-uri (cmacs-gsurf--target-buffer))))
    (when u (kill-new u) (message "%s" u))))

(defun cmacs-gsurf--action-tab-next ()
  "Switch to the next gsurf buffer."
  (interactive)
  (cmacs-gsurf--next-gsurf-buffer 1))

(defun cmacs-gsurf--action-tab-prev ()
  "Switch to the previous gsurf buffer."
  (interactive)
  (cmacs-gsurf--next-gsurf-buffer -1))

(defun cmacs-gsurf--action-reopen-next ()
  "Reopen the current page in the next container (gsurf's C-M-c)."
  (interactive)
  (let* ((ids (append (mapcar (lambda (c) (plist-get c :id))
                              (seq-remove (lambda (c) (plist-get c :temporary))
                                          (cmacs-gsurf-containers)))
                      (list "temporary" "default")))
         (cur (or (cmacs-gsurf-container-id (cmacs-gsurf--target-buffer))
                  "default"))
         (pos (or (cl-position cur ids :test #'equal) -1)))
    (cmacs-gsurf-reopen-in-container (nth (mod (1+ pos) (length ids)) ids))))

(defun cmacs-gsurf--action-command (name)
  "The cmacs command implementing core gsurf action NAME, or nil."
  (cdr (assoc name cmacs-gsurf--core-action-commands)))

(defun cmacs-gsurf--actions-annotated ()
  "Completion table of action names with their descriptions."
  (let ((acts (cmacs-gsurf-actions)))
    (lambda (string pred action)
      (if (eq action 'metadata)
          `(metadata
            (annotation-function
             . ,(lambda (a)
                  (let ((d (cdr (assoc a acts))))
                    (concat (if (cmacs-gsurf--action-command a) "  [cmacs]" "")
                            (if d (concat "  " d) ""))))))
        (complete-with-action action acts string pred)))))

(defun cmacs-gsurf-run-action (action)
  "Run gsurf ACTION (by name) on the current gsurf buffer.
Core actions (navigation, scrolling, zoom, find, \"tabs\") run the
matching cmacs command; every other one is offered to the loaded gsurf
modules -- e.g. dark-mode-toggle, dark-mode-toggle-site and
form-autofill.  Window-only actions (wmux panes, the --lrg=3d tab
space) have no effect in a buffer."
  (interactive
   (list (completing-read "gsurf action: " (cmacs-gsurf--actions-annotated)
                          nil t)))
  (let ((cmd (cmacs-gsurf--action-command action)))
    (if cmd
        (call-interactively cmd)
      (if (cmacs-gsurf-dispatch-action (cmacs-gsurf--target-buffer) action)
          (message "gsurf: %s" action)
        (message "gsurf: no loaded module handles `%s'" action)))))

(defun cmacs-gsurf--module-action (action module knob)
  "Dispatch ACTION; explain MODULE and its KNOB when nothing handled it."
  (unless (cmacs-gsurf-dispatch-action (cmacs-gsurf--target-buffer) action)
    (user-error "gsurf: `%s' needs the %s module (set `%s' to t)"
                action module knob)))

(defun cmacs-gsurf-dark-mode-toggle ()
  "Toggle gsurf dark mode for every page (the dark_mode module)."
  (interactive)
  (cmacs-gsurf--module-action "dark-mode-toggle" "dark_mode"
                              'cmacs-gsurf-dark-mode))

(defun cmacs-gsurf-dark-mode-toggle-site ()
  "Toggle gsurf dark mode for the current site; the module remembers it."
  (interactive)
  (cmacs-gsurf--module-action "dark-mode-toggle-site" "dark_mode"
                              'cmacs-gsurf-dark-mode))

(defun cmacs-gsurf-form-autofill ()
  "Fill the current page's form from a gsurf autofill profile.
One profile fills at once; several pop the module's picker."
  (interactive)
  (cmacs-gsurf--module-action "form-autofill" "form_autofill"
                              'cmacs-gsurf-form-autofill))

;;;; Keybinding help ------------------------------------------------

(defun cmacs-gsurf--keybind-rows ()
  "The C keybinding help rows grouped as ((SOURCE . ROWS) ...)."
  (let (groups)
    (dolist (r (cmacs-gsurf-keybinds))
      (let* ((src (or (plist-get r :source) "?"))
             (cell (assoc src groups)))
        (if cell (setcdr cell (append (cdr cell) (list r)))
          (setq groups (append groups (list (list src r)))))))
    groups))

(defun cmacs-gsurf-keybinds-help ()
  "Show the gsurf keybindings in a help buffer.
Three parts: the Emacs bindings of `cmacs-gsurf-mode' (active while
Emacs holds the keyboard -- the default), the bindings of the active
gsurf modules (active while the page holds it, after
\\<cmacs-gsurf-mode-map>\\[cmacs-gsurf-focus-page]), and gsurf's core
table, which belongs to the standalone gsurf window and is listed for
reference."
  (interactive)
  (let ((groups (ignore-errors (cmacs-gsurf--keybind-rows))))
    (with-help-window (get-buffer-create "*gsurf-keys*")
      (with-current-buffer standard-output
        (insert (propertize "Emacs bindings (cmacs-gsurf-mode)\n" 'face 'bold))
        (insert (substitute-command-keys "\\{cmacs-gsurf-mode-map}"))
        (insert "\n")
        (dolist (core-first '(nil t))
          (dolist (g groups)
            (when (eq core-first (equal (car g) "core"))
              (insert (propertize
                       (if (equal (car g) "core")
                           "gsurf core (standalone gsurf window only)\n"
                         (format "Module %s (while the page has the keyboard)\n"
                                 (car g)))
                       'face 'bold))
              (dolist (r (cdr g))
                (insert (format "  %-22s %-24s %s\n"
                                (or (plist-get r :pretty) "")
                                (or (plist-get r :action) "")
                                (or (plist-get r :description) ""))))
              (insert "\n"))))
        (unless groups
          (insert "(gsurf modules not loaded yet: open a gsurf buffer)\n"))))))

;;;; MCP / D-Bus helpers --------------------------------------------
;; String-returning wrappers the MCP tools (cmacs-mcp-tools-gsurf.c) and
;; the D-Bus interface (cmacs-dbus-iface-gsurf.c) call; buffer resolution
;; is `cmacs-gsurf--mcp-target' as for the older tools.

(defun cmacs-gsurf-mcp-click (x y &optional button buffer)
  "Click at X, Y (CSS px) with BUTTON in BUFFER; return \"ok\"."
  (cmacs-gsurf-click (cmacs-gsurf--mcp-target buffer) x y
                     (and button (> button 0) button))
  "ok")

(defun cmacs-gsurf-mcp-type-text (text &optional buffer)
  "Type TEXT into the focused element of BUFFER's page; return \"ok\"."
  (cmacs-gsurf-type (cmacs-gsurf--mcp-target buffer) text)
  "ok")

(defun cmacs-gsurf-mcp-press-key (key &optional modifiers buffer)
  "Press KEY with MODIFIERS (a string like \"ctrl+shift\") in BUFFER."
  (cmacs-gsurf-send-key (cmacs-gsurf--mcp-target buffer) key
                        (cmacs-gsurf--modifiers-from-string modifiers))
  "ok")

(defun cmacs-gsurf-mcp-click-element (selector &optional buffer)
  "Start clicking the first SELECTOR match in BUFFER; return a status.
The lookup is asynchronous: the result (t, nil for no match, or an
error) lands in `cmacs-gsurf--last-click-element' and the echo area."
  (cmacs-gsurf-click-element (cmacs-gsurf--mcp-target buffer) selector
                             (cmacs-gsurf--report-click selector))
  (format "started: clicking %s (asynchronous; see the echo area)" selector))

(defun cmacs-gsurf-mcp-set-cookie (name value domain &optional path secure
                                        http-only expires buffer)
  "Add cookie NAME=VALUE for DOMAIN to BUFFER's session; return \"ok\".
PATH defaults to \"/\"; SECURE and HTTP-ONLY are booleans; EXPIRES is
Unix seconds (0 or nil = session cookie).  The store is asynchronous."
  (cmacs-gsurf-add-cookie (cmacs-gsurf--mcp-target buffer)
                          (list :name name :value value :domain domain
                                :path (if (or (null path) (string-empty-p path))
                                          "/" path)
                                :secure secure :http-only http-only
                                :expires (and expires (> expires 0) expires)))
  "ok")

(defun cmacs-gsurf-mcp-toggle-module (name enabled)
  "Enable (ENABLED non-nil) or disable gsurf module NAME; return a status."
  (if (cmacs-gsurf-module-set-enabled name enabled)
      (format "%s %s" name (if enabled "enabled" "disabled"))
    (format "no such gsurf module: %s (open a gsurf buffer first?)" name)))

(defun cmacs-gsurf-mcp-run-action (action &optional buffer)
  "Run gsurf ACTION on BUFFER; return \"performed\" or \"not handled\".
Core actions map to cmacs commands (run in BUFFER); the rest go to the
modules."
  (let ((buf (cmacs-gsurf--mcp-target buffer))
        (cmd (cmacs-gsurf--action-command action)))
    (if cmd
        (with-current-buffer buf
          (let ((inhibit-interaction t))
            (if (memq cmd '(cmacs-gsurf-open-url cmacs-gsurf-find-in-page
                            cmacs-gsurf cmacs-gsurf-open-in-temporary-container))
                "not handled (prompts; use gsurf_navigate / gsurf_open)"
              (call-interactively cmd)
              "performed")))
      (if (cmacs-gsurf-dispatch-action buf action) "performed"
        "not handled"))))

(defun cmacs-gsurf-mcp-list-actions ()
  "Return a JSON array of gsurf actions: name, description, handler."
  (json-encode
   (vconcat
    (mapcar (lambda (a)
              `((name . ,(car a))
                (description . ,(cdr a))
                (handler . ,(if (cmacs-gsurf--action-command (car a))
                                "cmacs" "module"))))
            (cmacs-gsurf-actions)))))

(defun cmacs-gsurf-mcp-list-containers ()
  "Return a JSON array of the gsurf containers."
  (json-encode
   (vconcat
    (mapcar (lambda (c)
              `((id . ,(plist-get c :id))
                (name . ,(or (plist-get c :name) ""))
                (color . ,(or (plist-get c :color) ""))
                (temporary . ,(if (plist-get c :temporary) t :json-false))
                (views . ,(plist-get c :views))
                (proxy . ,(or (plist-get c :proxy) ""))))
            (cmacs-gsurf-containers)))))

(provide 'cmacs-gsurf-control)
;;; cmacs-gsurf-control.el ends here
