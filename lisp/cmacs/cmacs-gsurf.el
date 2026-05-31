;;; cmacs-gsurf.el --- gsurf embedded web browser buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Major mode + entry points for cmacs-gsurf, the gsurf-backed
;; embedded web browser.  Each `cmacs-gsurf-mode' buffer owns a live
;; WebKitGTK view (a GsurfView) parented into the buffer's frame and
;; clipped to the window showing it (xwidget-style live embed via the C
;; bridge in cmacs/gsurf/).  The buffer text is a hidden placeholder;
;; the web view paints over the window body.
;;
;; gsurf's own modules (search engines, ad-block, vim modal navigation,
;; history, dark mode, ...) run in-process and apply to these views;
;; control is also available from Elisp, cmacsgi (GObject
;; Introspection: (gi-require "Gsurf" "0.1")), MCP, and cmacs-ai.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'json)
(require 'format-spec)
(require 'url-util)

(defgroup cmacs-gsurf nil
  "gsurf embedded web browser subsystem for cmacs."
  :group 'cmacs
  :prefix "cmacs-gsurf-")

(defcustom cmacs-gsurf-home-url "about:blank"
  "Default URL opened by `cmacs-gsurf' when none is supplied."
  :type 'string
  :group 'cmacs-gsurf)

(defcustom cmacs-gsurf-default-zoom 1.0
  "Default zoom level (1.0 = 100%) for new gsurf views."
  :type 'number
  :group 'cmacs-gsurf)

(defcustom cmacs-gsurf-search-url
  "https://duckduckgo.com/?q=%s"
  "URL template used by `cmacs-gsurf' for non-URL input.
The first %s is replaced with the URL-encoded query."
  :type 'string
  :group 'cmacs-gsurf)

(defcustom cmacs-gsurf-scroll-step 80
  "Pixels scrolled by the `h'/`j'/`k'/`l' keys in a gsurf buffer.
These Emacs-side scroll commands run while Emacs holds focus (you do
not need to focus the page first).  When the page itself has focus, the
gsurf `modal' module does the scrolling instead."
  :type 'integer
  :group 'cmacs-gsurf)

(defvar cmacs-gsurf-load-changed-functions nil
  "Abnormal hook run when a gsurf view's load state changes.
Each function is called with (BUFFER EVENT), EVENT being one of the
symbols `started', `committed', `finished' or `failed'.")

(defvar cmacs-gsurf-uri-changed-functions nil
  "Abnormal hook run when a gsurf view's URI changes.
Each function is called with (BUFFER URI).")

(defvar cmacs-gsurf-title-changed-functions nil
  "Abnormal hook run when a gsurf view's title changes.
Each function is called with (BUFFER TITLE).")

(defvar cmacs-gsurf-module-event-functions nil
  "Abnormal hook run by the cmacs `emacs_bridge' gsurf module.
Each function is called with (EVENT URI), EVENT being a symbol such as
`navigated', `load-started', `load-committed' or `load-finished'.  This
fires for every gsurf view in the process (including module-initiated
navigations), so it is the place to hook process-wide browser
automation.")

(defcustom cmacs-gsurf-org-capture-template nil
  "Org-capture template key used by the `open_in_emacs' gsurf module
for `org-capture:' bar input.  Nil prompts for a template."
  :type '(choice (const :tag "Prompt" nil) string)
  :group 'cmacs-gsurf)

;;;; Configuration (Emacs-driven by default) --------------------------
;; cmacs-gsurf configures gsurf from Emacs and does NOT read gsurf's own
;; ~/.config/gsurf/config.yaml (or config.c) unless you opt in via
;; `cmacs-gsurf-load-user-config'.  `cmacs-gsurf-modules' is the primary
;; knob: it is synthesised into a gsurf `modules:' YAML document and
;; applied before the modules load, so it controls which modules are
;; enabled (modal gives vim hjkl + `f' link hints; search engines;
;; history; ...) and their options.

(defcustom cmacs-gsurf-modules
  '(("modal"          :enabled t)
    ("search_engines" :enabled t)
    ("history"        :enabled t))
  "Gsurf modules to configure, from Emacs Lisp.
An alist of (MODULE-NAME . PLIST).  Recognised PLIST keys:
  :enabled BOOL      -- enable or disable the module
  any other :KEY VAL -- a module-specific option (string, number or
                        boolean), passed through to the module's config.

This is synthesised into a gsurf `modules:' YAML document and applied
before the modules load, so it is the Emacs-side replacement for
~/.config/gsurf/config.yaml.  Modules that draw their own chrome
windows (chromebar, tabs, omnibar, find_bar, status_bar) are best left
disabled in the embedded browser; the defaults enable the windowless
ones: vim-style `modal' (hjkl scroll, `f' link hints, `i' insert),
`search_engines', and `history'.

Example:
  ((\"modal\"   :enabled t :scroll_step 100 :hint_chars \"asdfjkl\")
   (\"adblock\" :enabled t)
   (\"dark_mode\" :enabled t))

After changing this in a running session, call
`cmacs-gsurf-reload-config'."
  :type '(alist :key-type string :value-type plist)
  :group 'cmacs-gsurf)

(defcustom cmacs-gsurf-load-user-config nil
  "When non-nil, also load gsurf's own user config from ~/.config/gsurf/.
By default cmacs-gsurf ignores ~/.config/gsurf/config.yaml and
config.c and is configured entirely from Emacs (see
`cmacs-gsurf-modules').  Set this to t to additionally read the
standard gsurf user config files if they exist (Emacs config is
applied first, the gsurf files override it)."
  :type 'boolean
  :group 'cmacs-gsurf)

(defcustom cmacs-gsurf-config-file nil
  "Path to an extra gsurf YAML config file to load, or nil for none.
Loaded after `cmacs-gsurf-modules' (so it overrides it).  This is the
explicit opt-in for a YAML file of your choosing; nil means no YAML
file is read."
  :type '(choice (const :tag "None" nil) file)
  :group 'cmacs-gsurf)

(defcustom cmacs-gsurf-config-c-file nil
  "Path to a gsurf C config (compiled via crispy) to load, or nil.
For example \"~/.config/cmacs/init.c\".  Its gsurf_config_init() runs
against the gsurf config and can configure anything programmatically.
Loaded last, so it overrides the YAML layers.  Nil means no C config."
  :type '(choice (const :tag "None" nil) file)
  :group 'cmacs-gsurf)

(declare-function cmacs-gsurf-supported-p "cmacs-gsurf-defuns.c" ())
(declare-function cmacs-gsurf-attach "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-detach "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-attached-p "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-place "cmacs-gsurf-defuns.c"
                  (buffer frame x y width height))
(declare-function cmacs-gsurf-hide "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-load-uri "cmacs-gsurf-defuns.c" (buffer uri))
(declare-function cmacs-gsurf-reload "cmacs-gsurf-defuns.c" (buffer &optional nocache))
(declare-function cmacs-gsurf-stop "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-back "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-forward "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-title "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-progress "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-set-zoom "cmacs-gsurf-defuns.c" (buffer level))
(declare-function cmacs-gsurf-get-zoom "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-run-javascript "cmacs-gsurf-defuns.c" (buffer script))
(declare-function cmacs-gsurf-find "cmacs-gsurf-defuns.c" (buffer text &optional backward))
(declare-function cmacs-gsurf-find-next "cmacs-gsurf-defuns.c" (buffer &optional backward))
(declare-function cmacs-gsurf-modules-list "cmacs-gsurf-defuns.c" ())
(declare-function cmacs-gsurf-module-set-enabled "cmacs-gsurf-defuns.c" (name enabled))
(declare-function cmacs-gsurf-focus-page "cmacs-gsurf-defuns.c" (&optional buffer))
(declare-function cmacs-gsurf-release-focus "cmacs-gsurf-defuns.c" ())
(declare-function cmacs-gsurf-page-focused-p "cmacs-gsurf-defuns.c" (&optional buffer))
(declare-function cmacs-gsurf-follow "cmacs-gsurf-defuns.c" (&optional buffer))
(declare-function cmacs-gsurf-load-config-data "cmacs-gsurf-defuns.c" (data))
(declare-function cmacs-gsurf-load-config-file "cmacs-gsurf-defuns.c" (file))
(declare-function cmacs-gsurf-load-config-c-file "cmacs-gsurf-defuns.c" (file))
(declare-function cmacs-gsurf-reconfigure-modules "cmacs-gsurf-defuns.c" ())

;;;; Config synthesis + application -----------------------------------

(defvar cmacs-gsurf--config-applied nil
  "Non-nil once `cmacs-gsurf--apply-config' has run (config is process-global).")

(defun cmacs-gsurf--yaml-scalar (v)
  "Render Lisp value V as a YAML scalar string."
  (cond ((eq v t)        "true")
        ((eq v nil)      "false")
        ((integerp v)    (number-to-string v))
        ((numberp v)     (number-to-string v))
        ((symbolp v)     (format "%S" (symbol-name v)))
        ((stringp v)     (format "%S" v))   ; double-quoted, escaped
        (t               (format "%S" v))))

(defun cmacs-gsurf--config-to-yaml ()
  "Build a gsurf `modules:' YAML document from `cmacs-gsurf-modules'.
Returns the empty string when there is nothing to configure."
  (if (null cmacs-gsurf-modules)
      ""
    (let ((out "modules:\n"))
      (dolist (entry cmacs-gsurf-modules)
        (let ((name (car entry))
              (pl (cdr entry)))
          (setq out (concat out (format "  %s:\n" name)))
          (while pl
            (let* ((k (car pl))
                   (v (cadr pl))
                   (key (if (keywordp k)
                            (substring (symbol-name k) 1)
                          (format "%s" k))))
              (setq out (concat out (format "    %s: %s\n"
                                            key (cmacs-gsurf--yaml-scalar v)))))
            (setq pl (cddr pl)))))
      out)))

(defun cmacs-gsurf--user-config-path (name)
  "Return ~/.config/gsurf/NAME (honouring XDG_CONFIG_HOME)."
  (expand-file-name (concat "gsurf/" name)
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name "~/.config"))))

(defun cmacs-gsurf--apply-config (&optional force)
  "Apply the Emacs-side gsurf configuration once (idempotent).
With FORCE non-nil, apply again (e.g. after editing the defcustoms).
Configuration is Lisp-driven: `cmacs-gsurf-modules' is synthesised into a
gsurf `modules:' YAML document and loaded via `gsurf_config_load_from_
data'; gsurf's own ~/.config/gsurf/config.yaml is NOT read unless you opt
in.  Layers, last wins: `cmacs-gsurf-modules' -> optional user
config.yaml -> `cmacs-gsurf-config-file' -> C config."
  (when (or force (not cmacs-gsurf--config-applied))
    (setq cmacs-gsurf--config-applied t)
    ;; 1. Emacs-defined module config (synthesised YAML; the default path).
    (let ((yaml (cmacs-gsurf--config-to-yaml)))
      (when (> (length yaml) 0)
        (ignore-errors (cmacs-gsurf-load-config-data yaml))))
    ;; 2. gsurf's own ~/.config/gsurf/config.yaml -- opt-in only.
    (when cmacs-gsurf-load-user-config
      (let ((y (cmacs-gsurf--user-config-path "config.yaml")))
        (when (file-readable-p y)
          (ignore-errors (cmacs-gsurf-load-config-file y)))))
    ;; 3. An explicit YAML file of the user's choosing.
    (when cmacs-gsurf-config-file
      (let ((f (expand-file-name cmacs-gsurf-config-file)))
        (when (file-readable-p f)
          (ignore-errors (cmacs-gsurf-load-config-file f)))))
    ;; 4. A C config (compiled via crispy): explicit file, else the
    ;;    gsurf user config.c when user-config loading is enabled.
    (let ((c (cond (cmacs-gsurf-config-c-file
                    (expand-file-name cmacs-gsurf-config-c-file))
                   (cmacs-gsurf-load-user-config
                    (cmacs-gsurf--user-config-path "config.c")))))
      (when (and c (file-readable-p c))
        (ignore-errors (cmacs-gsurf-load-config-c-file c))))))

(defun cmacs-gsurf-reload-config ()
  "Re-apply the Emacs-side gsurf configuration to a running session.
Reloads `cmacs-gsurf-modules' (and any config files).  The programmatic
setters apply live to already-loaded modules, and loaded modules are
reconfigured to pick up option changes."
  (interactive)
  (cmacs-gsurf--apply-config t)
  (when (fboundp 'cmacs-gsurf-reconfigure-modules)
    (ignore-errors (cmacs-gsurf-reconfigure-modules)))
  (message "cmacs-gsurf: configuration reloaded"))

;;;; Internal book-keeping ---------------------------------------------

(defvar cmacs-gsurf--buffers nil
  "List of live `cmacs-gsurf-mode' buffers (for widget repositioning).")

(defun cmacs-gsurf--register (buffer)
  (cl-pushnew buffer cmacs-gsurf--buffers)
  (cmacs-gsurf--install-hooks))

(defun cmacs-gsurf--unregister (buffer)
  (setq cmacs-gsurf--buffers (delq buffer cmacs-gsurf--buffers)))

(defun cmacs-gsurf--live-buffers ()
  "Prune dead buffers and return the live gsurf buffers."
  (setq cmacs-gsurf--buffers
        (seq-filter #'buffer-live-p cmacs-gsurf--buffers)))

;;;; Widget positioning -----------------------------------------------

;; The live web widget is a real GTK child of the frame; Emacs does not
;; know its geometry.  Whenever the window layout changes we walk the
;; windows, place the widget over the body of any window showing a
;; gsurf buffer, and hide the widgets of gsurf buffers not on screen.

(defun cmacs-gsurf--reposition (&rest _)
  (when cmacs-gsurf--buffers
    (let ((shown (make-hash-table :test 'eq)))
      (dolist (win (window-list nil 'no-minibuffer))
        (let ((buf (window-buffer win)))
          (when (and (buffer-live-p buf)
                     (cmacs-gsurf-attached-p buf))
            (puthash buf t shown)
            (pcase-let ((`(,l ,top ,r ,bot)
                         (window-edges win t nil t)))
              (cmacs-gsurf-place buf (window-frame win) l top
                                 (max 1 (- r l)) (max 1 (- bot top)))))))
      (dolist (buf (cmacs-gsurf--live-buffers))
        (when (and (cmacs-gsurf-attached-p buf)
                   (not (gethash buf shown)))
          (cmacs-gsurf-hide buf)))
      (cmacs-gsurf--update-focus))))

;;;; Focus handoff ----------------------------------------------------

;; The live web widget is a real GTK child; if it could take GTK
;; keyboard focus, a page that autofocuses an element (DuckDuckGo's
;; search box, etc.) would steal keys and Emacs/evil would stop seeing
;; them.  The C side therefore creates the widget NON-focusable
;; (gtk_widget_set_can_focus FALSE), so by default keyboard focus stays
;; with Emacs and every keybind (SPC leader, C-w, M-x) works.  The page
;; gets the keyboard only on an explicit `cmacs-gsurf-focus-page' (i/RET)
;; or `cmacs-gsurf-follow' (f); clicks navigate but do NOT grab the
;; keyboard (press i/RET to type into a field).  Escape inside the page
;; (handled in C) returns focus to Emacs and calls `cmacs-gsurf--on-escape'.
;; Whenever the selected window is not a gsurf page we also release, so
;; switching windows always restores normal Emacs/evil keybindings.

(defun cmacs-gsurf--update-focus (&rest _)
  "Ensure Emacs holds keyboard focus unless a gsurf page is selected."
  (when cmacs-gsurf--buffers
    (let ((buf (window-buffer (selected-window))))
      (unless (and (buffer-live-p buf) (cmacs-gsurf-attached-p buf))
        (cmacs-gsurf-release-focus)))))

(defun cmacs-gsurf--on-escape ()
  "Called from C when Escape is pressed in a gsurf page.
Focus has already returned to Emacs; drop evil to normal state."
  (when (and (bound-and-true-p evil-mode)
             (fboundp 'evil-force-normal-state))
    (ignore-errors (evil-force-normal-state)))
  (force-mode-line-update))

(defvar cmacs-gsurf--hooks-installed nil)

(defun cmacs-gsurf--install-hooks ()
  (unless cmacs-gsurf--hooks-installed
    (setq cmacs-gsurf--hooks-installed t)
    (add-hook 'window-configuration-change-hook #'cmacs-gsurf--reposition)
    (add-hook 'window-size-change-functions #'cmacs-gsurf--reposition)
    (add-hook 'window-buffer-change-functions #'cmacs-gsurf--reposition)
    ;; Selecting another window (e.g. clicking it) must release page focus.
    (add-hook 'window-selection-change-functions #'cmacs-gsurf--update-focus)))

;;;; URL helpers ------------------------------------------------------

(defun cmacs-gsurf--looks-like-url-p (s)
  (or (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" s)
      (string-match-p "\\`\\(about\\|file\\|data\\|view-source\\):" s)
      (and (not (string-match-p "[[:space:]]" s))
           (string-match-p "\\." s))))

(defun cmacs-gsurf--normalize-url (input)
  "Turn user INPUT into a URL: pass URLs through, search otherwise."
  (let ((s (string-trim input)))
    (cond
     ((string-empty-p s) cmacs-gsurf-home-url)
     ((cmacs-gsurf--looks-like-url-p s)
      (if (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" s)
          s
        (concat "https://" s)))
     (t (format-spec cmacs-gsurf-search-url
                     `((?s . ,(url-hexify-string s))))))))

;;;; Scrolling --------------------------------------------------------

;; These run while Emacs holds focus (no need to focus the page first):
;; the buffer text is a hidden 1-line placeholder, so rebinding h/j/k/l
;; from evil motions to page scrolling is pure win and matches what you
;; expect in a browser.  When the page itself has focus, the gsurf
;; `modal' module does the scrolling instead (same keys).

(defun cmacs-gsurf--scroll (js)
  "Run scroll JS in the current gsurf buffer (no-op if not attached)."
  (when (cmacs-gsurf-attached-p (current-buffer))
    (cmacs-gsurf-run-javascript (current-buffer) js)))

(defun cmacs-gsurf-scroll-down ()
  "Scroll the page down by `cmacs-gsurf-scroll-step' pixels."
  (interactive)
  (cmacs-gsurf--scroll (format "window.scrollBy(0,%d);" cmacs-gsurf-scroll-step)))

(defun cmacs-gsurf-scroll-up ()
  "Scroll the page up by `cmacs-gsurf-scroll-step' pixels."
  (interactive)
  (cmacs-gsurf--scroll (format "window.scrollBy(0,%d);" (- cmacs-gsurf-scroll-step))))

(defun cmacs-gsurf-scroll-left ()
  "Scroll the page left by `cmacs-gsurf-scroll-step' pixels."
  (interactive)
  (cmacs-gsurf--scroll (format "window.scrollBy(%d,0);" (- cmacs-gsurf-scroll-step))))

(defun cmacs-gsurf-scroll-right ()
  "Scroll the page right by `cmacs-gsurf-scroll-step' pixels."
  (interactive)
  (cmacs-gsurf--scroll (format "window.scrollBy(%d,0);" cmacs-gsurf-scroll-step)))

(defun cmacs-gsurf-scroll-half-down ()
  "Scroll the page down half a screen."
  (interactive)
  (cmacs-gsurf--scroll "window.scrollBy(0,window.innerHeight/2);"))

(defun cmacs-gsurf-scroll-half-up ()
  "Scroll the page up half a screen."
  (interactive)
  (cmacs-gsurf--scroll "window.scrollBy(0,-window.innerHeight/2);"))

(defun cmacs-gsurf-scroll-screen-down ()
  "Scroll the page down nearly a full screen."
  (interactive)
  (cmacs-gsurf--scroll "window.scrollBy(0,window.innerHeight*0.9);"))

(defun cmacs-gsurf-scroll-screen-up ()
  "Scroll the page up nearly a full screen."
  (interactive)
  (cmacs-gsurf--scroll "window.scrollBy(0,-window.innerHeight*0.9);"))

(defun cmacs-gsurf-scroll-top ()
  "Scroll to the top of the page."
  (interactive)
  (cmacs-gsurf--scroll "window.scrollTo(0,0);"))

(defun cmacs-gsurf-scroll-bottom ()
  "Scroll to the bottom of the page."
  (interactive)
  (cmacs-gsurf--scroll "window.scrollTo(0,document.body.scrollHeight);"))

(defun cmacs-gsurf-reload-nocache ()
  "Reload the current gsurf buffer, bypassing the cache."
  (interactive)
  (cmacs-gsurf-reload (current-buffer) t))

;;;; Mode -------------------------------------------------------------

(defvar cmacs-gsurf-mode-map
  (let ((m (make-sparse-keymap)))
    ;; Focus / page interaction
    (define-key m (kbd "RET")     #'cmacs-gsurf-focus-page)
    (define-key m (kbd "i")       #'cmacs-gsurf-focus-page)
    (define-key m (kbd "f")       #'cmacs-gsurf-follow)
    (define-key m (kbd "C-c C-f") #'cmacs-gsurf-focus-page)
    (define-key m (kbd "C-c C-g") #'cmacs-gsurf-release-focus)
    ;; Scrolling (no page focus needed)
    (define-key m (kbd "j")       #'cmacs-gsurf-scroll-down)
    (define-key m (kbd "k")       #'cmacs-gsurf-scroll-up)
    (define-key m (kbd "h")       #'cmacs-gsurf-scroll-left)
    (define-key m (kbd "l")       #'cmacs-gsurf-scroll-right)
    (define-key m (kbd "C-d")     #'cmacs-gsurf-scroll-half-down)
    (define-key m (kbd "C-u")     #'cmacs-gsurf-scroll-half-up)
    ;; Full-page scroll on C-f/C-b (vim convention).  Deliberately NOT
    ;; SPC -- SPC is the evil/Doom leader and must pass through.
    (define-key m (kbd "C-f")     #'cmacs-gsurf-scroll-screen-down)
    (define-key m (kbd "C-b")     #'cmacs-gsurf-scroll-screen-up)
    (define-key m (kbd "<")       #'cmacs-gsurf-scroll-top)
    (define-key m (kbd ">")       #'cmacs-gsurf-scroll-bottom)
    (define-key m (kbd "g g")     #'cmacs-gsurf-scroll-top)
    (define-key m (kbd "G")       #'cmacs-gsurf-scroll-bottom)
    ;; History
    (define-key m (kbd "H")       #'cmacs-gsurf-back-buffer)
    (define-key m (kbd "L")       #'cmacs-gsurf-forward-buffer)
    (define-key m (kbd "B")       #'cmacs-gsurf-back-buffer)
    (define-key m (kbd "F")       #'cmacs-gsurf-forward-buffer)
    ;; Open / reload / zoom / find / quit
    (define-key m (kbd "o")       #'cmacs-gsurf-open-url)
    (define-key m (kbd "C-c C-o") #'cmacs-gsurf-open-url)
    (define-key m (kbd "r")       #'cmacs-gsurf-reload-buffer)
    (define-key m (kbd "R")       #'cmacs-gsurf-reload-nocache)
    (define-key m (kbd "C-c C-r") #'cmacs-gsurf-reload-buffer)
    (define-key m (kbd "+")       #'cmacs-gsurf-zoom-in)
    (define-key m (kbd "=")       #'cmacs-gsurf-zoom-in)
    (define-key m (kbd "-")       #'cmacs-gsurf-zoom-out)
    (define-key m (kbd "0")       #'cmacs-gsurf-zoom-reset)
    (define-key m (kbd "/")       #'cmacs-gsurf-find-in-page)
    (define-key m (kbd "s")       #'cmacs-gsurf-find-in-page)
    (define-key m (kbd "q")       #'quit-window)
    m)
  "Keymap for `cmacs-gsurf-mode'.
A gsurf buffer starts under Emacs/evil control: the web widget is
non-focusable, so all normal Emacs and evil keys (the \\`SPC' leader,
window commands like \\`C-w v', motions, \\[execute-extended-command]) work by default.
\\`h'/\\`j'/\\`k'/\\`l' scroll the page (no need to focus it);
\\[cmacs-gsurf-follow] pops vimium-style link hints; \\[cmacs-gsurf-focus-page] gives the page
keyboard focus so you can type into it; Escape hands control back to
Emacs (evil returns to normal state).")

(defun cmacs-gsurf--on-kill ()
  (when (cmacs-gsurf-attached-p (current-buffer))
    (cmacs-gsurf-detach (current-buffer)))
  (cmacs-gsurf--unregister (current-buffer)))

;;;###autoload
(define-derived-mode cmacs-gsurf-mode special-mode "gsurf"
  "Major mode for cmacs-gsurf embedded web browser buffers.

The window body IS the browser: a live WebKitGTK widget is parented
into the frame and clipped to the window showing this buffer.

The buffer starts under Emacs/evil control (the page is shown but does
not capture keys), so window management and motions work normally.
\\[cmacs-gsurf-focus-page] or a click gives the page keyboard focus;
Escape returns control to Emacs.

\\{cmacs-gsurf-mode-map}"
  (unless (cmacs-gsurf-supported-p)
    (user-error "cmacs-gsurf not built; reconfigure with --with-cmacs-gsurf"))
  (buffer-disable-undo)
  (setq-local truncate-lines t)
  (setq-local cursor-type nil)
  (setq-local mode-line-format
              '("%e" mode-line-front-space
                mode-line-buffer-identification
                "  " (:eval (cmacs-gsurf--mode-line-url)) "  gsurf"))
  (add-hook 'kill-buffer-hook #'cmacs-gsurf--on-kill nil t)
  ;; Apply the Emacs-side gsurf configuration (modules etc.) BEFORE the
  ;; first attach, which is what triggers module loading -- module
  ;; `enabled' flags are read from this config at load time.  Idempotent.
  (cmacs-gsurf--apply-config)
  (cmacs-gsurf-attach (current-buffer))
  (when (/= cmacs-gsurf-default-zoom 1.0)
    (cmacs-gsurf-set-zoom (current-buffer) cmacs-gsurf-default-zoom))
  (cmacs-gsurf--register (current-buffer))
  (cmacs-gsurf--reposition)
  ;; Make sure Emacs keeps keyboard focus when the buffer first appears
  ;; (the C side also grabs focus back on the widget's first show).
  (cmacs-gsurf-release-focus))

(defun cmacs-gsurf--mode-line-url ()
  (when (cmacs-gsurf-attached-p (current-buffer))
    (let ((u (ignore-errors (cmacs-gsurf-get-uri (current-buffer)))))
      (if (and u (> (length u) 60)) (concat (substring u 0 57) "...") (or u "")))))

;; Evil (Doom) integration.  Keep gsurf buffers in *normal* state so the
;; user's evil keys -- window management (`C-w v', `C-w h/j/k/l'),
;; motions, Escape -- all behave exactly as in any other buffer.  The
;; browsing commands are bound in normal+motion state so evil's
;; single-letter motions don't shadow them; `C-w' is deliberately left
;; to evil's window map.  To interact with the page, RET/i focuses it;
;; Escape (handled in C) returns to normal state.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-gsurf-mode 'normal))
  (when (fboundp 'evil-define-key*)
    (evil-define-key* '(normal motion) cmacs-gsurf-mode-map
      (kbd "RET") #'cmacs-gsurf-focus-page
      "i"  #'cmacs-gsurf-focus-page
      "f"  #'cmacs-gsurf-follow
      ;; scrolling -- override evil motions in gsurf buffers
      "j"  #'cmacs-gsurf-scroll-down
      "k"  #'cmacs-gsurf-scroll-up
      "h"  #'cmacs-gsurf-scroll-left
      "l"  #'cmacs-gsurf-scroll-right
      (kbd "C-d") #'cmacs-gsurf-scroll-half-down
      (kbd "C-u") #'cmacs-gsurf-scroll-half-up
      ;; Full-page scroll on C-f/C-b; SPC is left to the evil/Doom leader.
      (kbd "C-f") #'cmacs-gsurf-scroll-screen-down
      (kbd "C-b") #'cmacs-gsurf-scroll-screen-up
      "gg" #'cmacs-gsurf-scroll-top
      "G"  #'cmacs-gsurf-scroll-bottom
      ;; history
      "H"  #'cmacs-gsurf-back-buffer
      "L"  #'cmacs-gsurf-forward-buffer
      "B"  #'cmacs-gsurf-back-buffer
      "F"  #'cmacs-gsurf-forward-buffer
      ;; open / reload / zoom / find
      "o"  #'cmacs-gsurf-open-url
      "r"  #'cmacs-gsurf-reload-buffer
      "R"  #'cmacs-gsurf-reload-nocache
      "+"  #'cmacs-gsurf-zoom-in
      "="  #'cmacs-gsurf-zoom-in
      "-"  #'cmacs-gsurf-zoom-out
      "0"  #'cmacs-gsurf-zoom-reset
      "/"  #'cmacs-gsurf-find-in-page
      "q"  #'quit-window)))

;;;; Interactive commands ---------------------------------------------

(defun cmacs-gsurf-open-url (url)
  "Prompt for URL (or search query) and load it in the current view."
  (interactive "sOpen URL or search: ")
  (cmacs-gsurf-load-uri (current-buffer) (cmacs-gsurf--normalize-url url)))

(defun cmacs-gsurf-reload-buffer (&optional nocache)
  "Reload the current gsurf buffer.  With prefix arg, bypass the cache."
  (interactive "P")
  (cmacs-gsurf-reload (current-buffer) nocache))

(defun cmacs-gsurf-back-buffer ()
  "Go back in the current gsurf buffer's history."
  (interactive)
  (cmacs-gsurf-back (current-buffer)))

(defun cmacs-gsurf-forward-buffer ()
  "Go forward in the current gsurf buffer's history."
  (interactive)
  (cmacs-gsurf-forward (current-buffer)))

(defun cmacs-gsurf-zoom-in ()
  "Increase zoom in the current gsurf buffer."
  (interactive)
  (cmacs-gsurf-set-zoom (current-buffer)
                        (+ (cmacs-gsurf-get-zoom (current-buffer)) 0.1)))

(defun cmacs-gsurf-zoom-out ()
  "Decrease zoom in the current gsurf buffer."
  (interactive)
  (cmacs-gsurf-set-zoom (current-buffer)
                        (max 0.2 (- (cmacs-gsurf-get-zoom (current-buffer)) 0.1))))

(defun cmacs-gsurf-zoom-reset ()
  "Reset zoom to 100% in the current gsurf buffer."
  (interactive)
  (cmacs-gsurf-set-zoom (current-buffer) 1.0))

(defun cmacs-gsurf-find-in-page (text)
  "Find TEXT in the current gsurf buffer's page."
  (interactive "sFind in page: ")
  (cmacs-gsurf-find (current-buffer) text))

;;;; Entry points -----------------------------------------------------

;;;###autoload
(defun cmacs-gsurf (&optional url)
  "Open a cmacs-gsurf web browser buffer at URL (prompted if nil)."
  (interactive
   (list (read-string "URL or search: " nil nil cmacs-gsurf-home-url)))
  (unless (cmacs-gsurf-supported-p)
    (user-error "cmacs-gsurf not built; reconfigure with --with-cmacs-gsurf"))
  (let* ((target (cmacs-gsurf--normalize-url (or url cmacs-gsurf-home-url)))
         (buf (generate-new-buffer "*gsurf*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (insert "cmacs-gsurf: the window body shows the live web view.\n"))
      (cmacs-gsurf-mode)
      (cmacs-gsurf-load-uri buf target))
    (switch-to-buffer buf)
    buf))

;;;###autoload
(defun cmacs-gsurf-browse-url (url &rest _args)
  "Open URL in a cmacs-gsurf buffer.
Suitable as `browse-url-browser-function'."
  (cmacs-gsurf url))

;;;; MCP / agent helpers ----------------------------------------------
;; Thin string-returning wrappers used by the cmacs-mcp gsurf tools (and
;; therefore reachable from cmacs-ai).  They resolve a target buffer
;; (named, or the most-recently-opened gsurf buffer) and return plain
;; strings / JSON so the MCP layer can stay a trivial eval bridge.

(defun cmacs-gsurf--mcp-target (&optional name)
  "Return the target gsurf buffer for an MCP call.
NAME, when non-empty, selects a buffer by name; otherwise the most
recently opened gsurf buffer is used."
  (or (and name (not (string-empty-p name)) (get-buffer name))
      (car (cmacs-gsurf--live-buffers))
      (user-error "No gsurf buffer is open")))

(defun cmacs-gsurf-mcp-open (url)
  "Open URL in a new gsurf buffer; return the buffer name."
  (buffer-name (cmacs-gsurf (or url cmacs-gsurf-home-url))))

(defun cmacs-gsurf-mcp-navigate (url &optional buffer)
  "Load URL in BUFFER (or the current gsurf buffer); return the URL."
  (let ((buf (cmacs-gsurf--mcp-target buffer)))
    (cmacs-gsurf-load-uri buf (cmacs-gsurf--normalize-url url))
    (cmacs-gsurf--normalize-url url)))

(defun cmacs-gsurf-mcp-back (&optional buffer)
  (cmacs-gsurf-back (cmacs-gsurf--mcp-target buffer)) "ok")
(defun cmacs-gsurf-mcp-forward (&optional buffer)
  (cmacs-gsurf-forward (cmacs-gsurf--mcp-target buffer)) "ok")
(defun cmacs-gsurf-mcp-reload (&optional buffer)
  (cmacs-gsurf-reload (cmacs-gsurf--mcp-target buffer)) "ok")
(defun cmacs-gsurf-mcp-stop (&optional buffer)
  (cmacs-gsurf-stop (cmacs-gsurf--mcp-target buffer)) "ok")

(defun cmacs-gsurf-mcp-eval-js (script &optional buffer)
  (cmacs-gsurf-run-javascript (cmacs-gsurf--mcp-target buffer) script) "ok")

(defun cmacs-gsurf-mcp-set-zoom (level &optional buffer)
  (cmacs-gsurf-set-zoom (cmacs-gsurf--mcp-target buffer) level)
  (format "%s" level))

(defun cmacs-gsurf-mcp-get-uri (&optional buffer)
  (or (cmacs-gsurf-get-uri (cmacs-gsurf--mcp-target buffer)) ""))
(defun cmacs-gsurf-mcp-get-title (&optional buffer)
  (or (cmacs-gsurf-get-title (cmacs-gsurf--mcp-target buffer)) ""))

(defun cmacs-gsurf-mcp-current ()
  "Return JSON describing the current gsurf buffer."
  (let ((buf (cmacs-gsurf--mcp-target nil)))
    (json-encode
     (list :buffer (buffer-name buf)
           :uri (or (cmacs-gsurf-get-uri buf) "")
           :title (or (cmacs-gsurf-get-title buf) "")
           :progress (cmacs-gsurf-get-progress buf)))))

(defun cmacs-gsurf-mcp-list ()
  "Return a JSON array describing all open gsurf buffers."
  (require 'json)
  (json-encode
   (vconcat
    (mapcar (lambda (buf)
              (list :buffer (buffer-name buf)
                    :uri (or (ignore-errors (cmacs-gsurf-get-uri buf)) "")
                    :title (or (ignore-errors (cmacs-gsurf-get-title buf)) "")))
            (cmacs-gsurf--live-buffers)))))

;;;; Module bridge callbacks ------------------------------------------
;; Called from the cmacs gsurf modules (gsurf-emacs-bridge,
;; gsurf-open-in-emacs, gsurf-elisp) via the C host bridge
;; `cmacs_gsurf_emacs_eval_async'.  `cmacs-gsurf--module-eval' is the
;; single entry point: it reads + evaluates a form string inside a
;; condition-case so a bad form from the page side can never escape.

(defun cmacs-gsurf--module-eval (form-string)
  "Evaluate FORM-STRING (Elisp source) safely; for gsurf module callbacks."
  (condition-case err
      (eval (car (read-from-string form-string)) t)
    (error (message "cmacs-gsurf module eval error: %S" err))))

(defun cmacs-gsurf--module-find-file (path)
  "Open PATH (from the gsurf `emacs:' pseudo-scheme)."
  (find-file (expand-file-name path)))

(defun cmacs-gsurf--module-eww (url)
  "Open URL in eww (from the gsurf `eww:' pseudo-scheme)."
  (require 'eww)
  (eww url))

(defun cmacs-gsurf--module-org-capture (text)
  "Capture TEXT via org-capture (from the gsurf `org-capture:' scheme)."
  (require 'org-capture)
  (let ((org-capture-initial text))
    (org-capture nil cmacs-gsurf-org-capture-template)))

(provide 'cmacs-gsurf)
;;; cmacs-gsurf.el ends here
