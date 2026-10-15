;;; cmacs-gowl-floatdesk.el --- Floating desktop workspaces in gowl -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; gowl's `floatdesk' module turns a workspace (a tag) into a floating
;; desktop: every window on it floats, new windows open centred at a
;; sensible size and cascade, floating windows get title bars
;; (close, minimize and maximize on the left, the title centred; drag
;; to an edge to snap; double-click to maximize), focus follows the
;; click, and a dock of pinned and running
;; applications sits along one edge of the output.  Leaving the mode
;; tiles again exactly the windows the mode floated -- dialogs, windows
;; a rule floated and windows the user floated are left alone.
;;
;; Under `cmacs --gowl' the module is loaded by default and bound:
;;
;;   Super+w          this workspace: floating desktop <-> tiling
;;   Super+n          minimize the focused window (floating desktops only)
;;   Super+Shift+n    bring back the window minimized last
;;   Super+Shift+w    the dock's all-apps grid
;;
;; It is also an entry in the layout cycle (`desktop'), so Super+< and
;; Super+> reach it like any layout.  Which workspaces float is kept in
;; $XDG_STATE_HOME/gowl/floatdesk.yaml and restored at the next start.
;;
;; Everything here goes through `gowl-run-command' and the module's
;; `floatdesk-' commands -- the same words the IPC socket, D-Bus
;; (Compositor.Floatdesk), `emacsctl compositor floatdesk' and the bacon
;; builtin `cmacsgi floatdesk' reach -- so no C primitive is involved.
;; The module's announcements ("mode 3 floating", "default tiled",
;; "dock position left") arrive as the compositor's `module-event'
;; signal through `cmacs-gowl-module-event-functions'; they drive the
;; mode-line lighter and `cmacs-gowl-floatdesk-changed-functions'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gowl-run-command "cmacs-gowl")
(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-enable-module "cmacs-gowl")
(declare-function gowl-configure-module "cmacs-gowl")
(defvar cmacs-gowl-module-event-functions)
(defvar cmacs-gowl-tag-changed-functions)
(defvar cmacs-gowl-layout-changed-functions)
(defvar cmacs-gowl-terminal-command)
(defvar cmacs-gowl-default-dropdown-terminal)

(defgroup cmacs-gowl-floatdesk nil
  "Floating desktop workspaces in gowl."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-floatdesk-")

(defconst cmacs-gowl-floatdesk--module "floatdesk"
  "The gowl module's name.")

;;;; Options

(defcustom cmacs-gowl-floatdesk-default-floating 'saved
  "Whether workspaces with no setting of their own are floating desktops.
`saved' (the default) leaves it to what was last set at run time
\(`cmacs-gowl-floatdesk-default-toggle', kept in the state file); t or
nil decide it at every start, outranking the state file.  A workspace
set explicitly (Super+w) keeps its own setting either way."
  :type '(choice (const :tag "As last set at run time" saved)
                 (const :tag "Float every workspace" t)
                 (const :tag "Tile every workspace" nil))
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-width-pct 0.6
  "A new window's width on a floating desktop, as a fraction of the screen."
  :type 'number
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-height-pct 0.7
  "A new window's height on a floating desktop, as a fraction of the screen."
  :type 'number
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-cascade 32
  "Pixels each new window is offset from the last one opened."
  :type 'integer
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-focus-follows-click t
  "Non-nil: on a floating desktop the keyboard follows clicks, not the pointer.
Overlapping windows make sloppy focus a hazard there; tiled workspaces
keep `gowl-set-sloppy-focus' behaviour."
  :type 'boolean
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-titlebars t
  "Non-nil: floating windows on a floating desktop get title bars.
A window that draws its own (client-side decorations) gets none."
  :type 'boolean
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-titlebar-height 28
  "Title bar height in pixels (16 to 96)."
  :type 'integer
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-snap-threshold 6
  "How close to an output edge a dropped window must be to snap, in pixels."
  :type 'integer
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-dock t
  "Non-nil: show the dock on outputs viewing a floating desktop."
  :type 'boolean
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-dock-position 'bottom
  "The edge the dock sits on.
A position chosen from the dock's own menu is kept in the state file
and wins over this."
  :type '(choice (const bottom) (const left) (const right) (const top))
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-dock-autohide nil
  "Non-nil: the dock slides off its edge until the pointer touches it.
It always does under a maximized window.  A setting chosen from the
dock's menu is kept in the state file and wins over this."
  :type 'boolean
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-dock-pins nil
  "Desktop entry ids pinned to the dock, in order, e.g. (\"firefox\" \"foot\").
The initial list only: pins changed from the dock (drag, right click,
`cmacs-gowl-floatdesk-dock-pin') are kept in the state file and win."
  :type '(repeat string)
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-dock-icon-size 48
  "Dock icon size in pixels (16 to 128)."
  :type 'integer
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-terminal nil
  "The terminal a terminal program (a TUI) launched from the dock runs in.
nil uses `cmacs-gowl-terminal-command', else
`cmacs-gowl-default-dropdown-terminal'.  The window gets the app id
\"tui.<entry id>\" so the dock shows it as that program; foot, kitty,
alacritty, ghostty, wezterm, st and gst are understood."
  :type '(choice (const :tag "The session terminal" nil) string)
  :group 'cmacs-gowl-floatdesk)

(defcustom cmacs-gowl-floatdesk-lighter " Desk"
  "Mode-line text while the selected workspace is a floating desktop, or nil."
  :type '(choice (const :tag "None" nil) string)
  :group 'cmacs-gowl-floatdesk)

(defvar cmacs-gowl-floatdesk-changed-functions nil
  "Functions run when the floating desktop changes state.
Each gets WHAT, a symbol -- `mode', `default' or `dock' -- and DETAIL,
the rest of the module's announcement as a string: \"3 floating\",
\"tiled\", \"position left\".")

(defvar cmacs-gowl-floatdesk--view-floating nil
  "Non-nil while the selected workspace is a floating desktop.")

(defvar cmacs-gowl-floatdesk--refresh-timer nil
  "The pending idle refresh of `cmacs-gowl-floatdesk--view-floating'.")

;;;; Talking to the module

(defun cmacs-gowl-floatdesk--terminal ()
  "The terminal the module launches TUIs in."
  (or cmacs-gowl-floatdesk-terminal
      (bound-and-true-p cmacs-gowl-terminal-command)
      (bound-and-true-p cmacs-gowl-default-dropdown-terminal)
      "foot"))

(defun cmacs-gowl-floatdesk--settings ()
  "The module settings, as the string alist `gowl-configure-module' takes."
  (let ((b (lambda (v) (if v "true" "false")))
        (n #'number-to-string))
    (append
     (unless (eq cmacs-gowl-floatdesk-default-floating 'saved)
       (list (cons "default-floating"
                   (funcall b cmacs-gowl-floatdesk-default-floating))))
     (list (cons "width-pct" (funcall n cmacs-gowl-floatdesk-width-pct))
           (cons "height-pct" (funcall n cmacs-gowl-floatdesk-height-pct))
           (cons "cascade" (funcall n cmacs-gowl-floatdesk-cascade))
           (cons "focus-follows-click"
                 (funcall b cmacs-gowl-floatdesk-focus-follows-click))
           (cons "titlebars" (funcall b cmacs-gowl-floatdesk-titlebars))
           (cons "titlebar-height"
                 (funcall n cmacs-gowl-floatdesk-titlebar-height))
           (cons "snap-threshold"
                 (funcall n cmacs-gowl-floatdesk-snap-threshold))
           (cons "dock" (funcall b cmacs-gowl-floatdesk-dock))
           (cons "dock-position"
                 (symbol-name cmacs-gowl-floatdesk-dock-position))
           (cons "dock-autohide" (funcall b cmacs-gowl-floatdesk-dock-autohide))
           (cons "dock-icon-size"
                 (funcall n cmacs-gowl-floatdesk-dock-icon-size))
           (cons "terminal" (cmacs-gowl-floatdesk--terminal)))
     ;; A module setting value is one string; the module splits pins on
     ;; newlines and commas.
     (when cmacs-gowl-floatdesk-dock-pins
       (list (cons "pins" (string-join cmacs-gowl-floatdesk-dock-pins "\n")))))))

(defun cmacs-gowl-floatdesk--command (line)
  "Run the module command LINE and return the text after \"OK \".
An \"ERROR ...\" reply becomes a `user-error' carrying the module's own
explanation; no reply at all means the module is not loaded."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (let ((reply (gowl-run-command line)))
    (cond ((null reply)
           (user-error "The gowl floatdesk module is not loaded; call `cmacs-gowl-floatdesk-start'"))
          ((string-prefix-p "ERROR" reply)
           (user-error "Floating desktop: %s" (string-trim (substring reply 5))))
          ((string-prefix-p "OK " reply) (substring reply 3))
          ((equal reply "OK") "")
          (t reply))))

(defun cmacs-gowl-floatdesk--parse-status (text)
  "Parse the module's key=value TEXT into an alist of symbols to strings."
  (let (out)
    (dolist (word (split-string (or text "") " " t))
      (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" word)
        (push (cons (intern (match-string 1 word)) (match-string 2 word)) out)))
    (nreverse out)))

(defun cmacs-gowl-floatdesk--tag-list (text)
  "TEXT, \"1,3\", as a list of numbers."
  (mapcar #'string-to-number (split-string (or text "") "," t)))

;;;###autoload
(defun cmacs-gowl-floatdesk-start ()
  "Load gowl's `floatdesk' module if needed and push its settings.
Idempotent.  Loading floats nothing: a workspace becomes a floating
desktop only when switched (Super+w) or through the default."
  (interactive)
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (user-error "Gowl compositor is not running"))
  (unless (gowl-run-command "floatdesk-status")
    (gowl-enable-module cmacs-gowl-floatdesk--module))
  (condition-case err
      (gowl-configure-module cmacs-gowl-floatdesk--module
                             (cmacs-gowl-floatdesk--settings))
    (error (message "cmacs-gowl-floatdesk: settings failed: %s"
                    (error-message-string err))))
  (cmacs-gowl-floatdesk--listen t)
  (cmacs-gowl-floatdesk--schedule-refresh))

(defun cmacs-gowl-floatdesk-apply-settings ()
  "Push the `cmacs-gowl-floatdesk-*' options into the running module."
  (interactive)
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (gowl-configure-module cmacs-gowl-floatdesk--module
                           (cmacs-gowl-floatdesk--settings))))

;;;; Commands

(defun cmacs-gowl-floatdesk-status ()
  "The module's state, as an alist.
Keys: `view', `view-floating', `default', `floating-tags', `tiled-tags',
`minimized', `dock', `autohide', `pins', `state' -- string values.
Interactively, a summary in the echo area."
  (interactive)
  (let ((s (cmacs-gowl-floatdesk--parse-status
            (cmacs-gowl-floatdesk--command "floatdesk-status"))))
    (when (called-interactively-p 'interactive)
      (message "Floating desktop: view %s %s; floating tags %s; default %s; dock %s%s"
               (alist-get 'view s)
               (if (equal (alist-get 'view-floating s) "1") "floats" "tiles")
               (let ((f (alist-get 'floating-tags s)))
                 (if (string-empty-p (or f "")) "none" f))
               (if (equal (alist-get 'default s) "1") "floating" "tiled")
               (alist-get 'dock s)
               (if (equal (alist-get 'autohide s) "1") " (auto-hide)" "")))
    s))

(defun cmacs-gowl-floatdesk--tag-arg (tag)
  "TAG (a number, or nil for the view) as a command argument."
  (if tag (format " %d" tag) ""))

;;;###autoload
(defun cmacs-gowl-floatdesk-toggle (&optional tag)
  "Make the workspace in view a floating desktop, or tile it again.
With a numeric prefix argument, TAG instead -- in view or not."
  (interactive (list (and current-prefix-arg
                          (prefix-numeric-value current-prefix-arg))))
  (message "Floating desktop: %s"
           (cmacs-gowl-floatdesk--command
            (concat "floatdesk-toggle" (cmacs-gowl-floatdesk--tag-arg tag)))))

(defun cmacs-gowl-floatdesk-on (&optional tag)
  "Make the workspace in view (or TAG) a floating desktop."
  (interactive (list (and current-prefix-arg
                          (prefix-numeric-value current-prefix-arg))))
  (cmacs-gowl-floatdesk--command
   (concat "floatdesk-on" (cmacs-gowl-floatdesk--tag-arg tag))))

(defun cmacs-gowl-floatdesk-off (&optional tag)
  "Tile the workspace in view (or TAG) again."
  (interactive (list (and current-prefix-arg
                          (prefix-numeric-value current-prefix-arg))))
  (cmacs-gowl-floatdesk--command
   (concat "floatdesk-off" (cmacs-gowl-floatdesk--tag-arg tag))))

(defun cmacs-gowl-floatdesk-default-toggle (&optional arg)
  "Float every workspace not set on its own, or stop.
With ARG, on when positive, off otherwise.  Kept in the state file."
  (interactive "P")
  (message "Floating desktop: %s"
           (cmacs-gowl-floatdesk--command
            (concat "floatdesk-default "
                    (cond ((null arg) "toggle")
                          ((> (prefix-numeric-value arg) 0) "on")
                          (t "off"))))))

(defun cmacs-gowl-floatdesk--client-arg (id)
  "ID, a client id or nil for the focused window, as a command argument."
  (if id (format " %d" id) ""))

(defun cmacs-gowl-floatdesk-minimize (&optional id)
  "Minimize the focused window (or client ID).  Floating desktops only."
  (interactive)
  (cmacs-gowl-floatdesk--command
   (concat "floatdesk-minimize" (cmacs-gowl-floatdesk--client-arg id))))

(defun cmacs-gowl-floatdesk-restore (&optional id)
  "Bring back the window minimized last (or client ID), where you are."
  (interactive)
  (cmacs-gowl-floatdesk--command
   (concat "floatdesk-restore" (cmacs-gowl-floatdesk--client-arg id))))

(defun cmacs-gowl-floatdesk-maximize (&optional id)
  "Maximize the focused window (or client ID), or put it back."
  (interactive)
  (cmacs-gowl-floatdesk--command
   (concat "floatdesk-maximize" (cmacs-gowl-floatdesk--client-arg id))))

(defun cmacs-gowl-floatdesk-snap (where &optional id)
  "Snap the focused window (or client ID) to WHERE: `left', `right' or `max'."
  (interactive (list (intern (completing-read "Snap to: " '("left" "right" "max")
                                              nil t))))
  (cmacs-gowl-floatdesk--command
   (format "floatdesk-snap %s%s" where (cmacs-gowl-floatdesk--client-arg id))))

(defun cmacs-gowl-floatdesk-dock-position (position)
  "Move the dock to POSITION: `bottom', `left', `right' or `top'.  Kept."
  (interactive (list (intern (completing-read "Dock position: "
                                              '("bottom" "left" "right" "top")
                                              nil t))))
  (cmacs-gowl-floatdesk--command
   (format "floatdesk-dock-position %s" position)))

(defun cmacs-gowl-floatdesk-dock-autohide (&optional arg)
  "Toggle the dock's auto-hide; with ARG, on when positive.  Kept."
  (interactive "P")
  (cmacs-gowl-floatdesk--command
   (concat "floatdesk-dock-autohide "
           (cond ((null arg) "toggle")
                 ((> (prefix-numeric-value arg) 0) "on")
                 (t "off")))))

(defun cmacs-gowl-floatdesk-dock-pin (app &optional index)
  "Pin desktop entry APP (\"firefox\") to the dock, at INDEX or the end.  Kept."
  (interactive "sPin app id: ")
  (cmacs-gowl-floatdesk--command
   (format "floatdesk-dock-pin %s%s" app (if index (format " %d" index) ""))))

(defun cmacs-gowl-floatdesk-dock-unpin (app)
  "Unpin desktop entry APP from the dock.  Kept."
  (interactive (list (completing-read
                      "Unpin: "
                      (split-string (or (alist-get 'pins
                                                   (cmacs-gowl-floatdesk-status))
                                        "")
                                    "," t)
                      nil t)))
  (cmacs-gowl-floatdesk--command (format "floatdesk-dock-unpin %s" app)))

(defun cmacs-gowl-floatdesk-dock-launch (app)
  "Start desktop entry APP as the dock would (a TUI in a terminal)."
  (interactive "sLaunch app id: ")
  (cmacs-gowl-floatdesk--command (format "floatdesk-dock-launch %s" app)))

(defun cmacs-gowl-floatdesk-dock-apps ()
  "Open or close the dock's all-apps grid."
  (interactive)
  (cmacs-gowl-floatdesk--command "floatdesk-dock-apps"))

(defun cmacs-gowl-floatdesk-dock-items ()
  "The dock's items, as a list of plists.
Each has :app, :pinned, :windows, :minimized and :launching."
  (let* ((s (cmacs-gowl-floatdesk--parse-status
             (cmacs-gowl-floatdesk--command "floatdesk-dock-status")))
         (items (alist-get 'items s)))
    (mapcar (lambda (item)
              (pcase-let ((`(,app ,pinned ,windows ,minimized ,launching)
                           (split-string item ":")))
                (list :app app
                      :pinned (equal pinned "1")
                      :windows (string-to-number windows)
                      :minimized (string-to-number minimized)
                      :launching (equal launching "1"))))
            (split-string (or items "") ";" t))))

;;;; Hearing the module

(defun cmacs-gowl-floatdesk--on-module-event (module text)
  "Handle a gowl `module-event' from MODULE carrying TEXT."
  (when (equal module cmacs-gowl-floatdesk--module)
    (let* ((words (split-string (or text "") " " t))
           (what (intern (or (car words) "unknown")))
           (detail (string-join (cdr words) " ")))
      (cmacs-gowl-floatdesk--schedule-refresh)
      (run-hook-with-args 'cmacs-gowl-floatdesk-changed-functions
                          what detail))))

(defun cmacs-gowl-floatdesk--refresh ()
  "Re-read whether the selected workspace floats, for the lighter."
  (setq cmacs-gowl-floatdesk--refresh-timer nil)
  (when (and (fboundp 'gowl-running-p) (gowl-running-p))
    (let* ((reply (ignore-errors (gowl-run-command "floatdesk-status")))
           (s (and reply (string-prefix-p "OK " reply)
                   (cmacs-gowl-floatdesk--parse-status (substring reply 3))))
           (on (equal (alist-get 'view-floating s) "1")))
      (unless (eq on cmacs-gowl-floatdesk--view-floating)
        (setq cmacs-gowl-floatdesk--view-floating on)
        (force-mode-line-update t)))))

(defun cmacs-gowl-floatdesk--schedule-refresh (&rest _)
  "Refresh the lighter from the main loop, soon.
Never from inside the compositor's own signal: the hooks this hangs off
run while gowl is arranging, and a command from there would re-enter it."
  (unless cmacs-gowl-floatdesk--refresh-timer
    (setq cmacs-gowl-floatdesk--refresh-timer
          (run-at-time 0.05 nil #'cmacs-gowl-floatdesk--refresh))))

(defun cmacs-gowl-floatdesk--listen (on)
  "Listen to the module's events and to tag/layout changes (ON), or stop."
  (let ((fn (if on #'add-hook #'remove-hook)))
    (funcall fn 'cmacs-gowl-module-event-functions
             #'cmacs-gowl-floatdesk--on-module-event)
    (funcall fn 'cmacs-gowl-tag-changed-functions
             #'cmacs-gowl-floatdesk--schedule-refresh)
    (funcall fn 'cmacs-gowl-layout-changed-functions
             #'cmacs-gowl-floatdesk--schedule-refresh)))

(defun cmacs-gowl-floatdesk--lighter ()
  "The mode-line text while the selected workspace floats, or nil."
  (and cmacs-gowl-floatdesk--view-floating cmacs-gowl-floatdesk-lighter
       (propertize cmacs-gowl-floatdesk-lighter
                   'help-echo "Floating desktop\nSuper+w tiles this workspace")))

(defconst cmacs-gowl-floatdesk--mode-line-entry
  '(:eval (cmacs-gowl-floatdesk--lighter))
  "The `mode-line-misc-info' entry for the floating desktop.")

(add-to-list 'mode-line-misc-info cmacs-gowl-floatdesk--mode-line-entry t)

;;;; RPC (D-Bus, bacon, emacsctl)

(defconst cmacs-gowl-floatdesk-rpc-verbs
  '("status" "toggle" "on" "off" "default" "minimize" "restore" "maximize"
    "snap" "dock-position" "dock-autohide" "dock-pin" "dock-unpin"
    "dock-launch" "dock-activate" "dock-apps" "dock-status")
  "The verbs `cmacs-gowl-floatdesk-rpc' accepts: the module's own words
without their `floatdesk-' prefix.")

(defun cmacs-gowl-floatdesk-rpc (verb &optional args)
  "Run floatdesk VERB with ARGS (a string) for an RPC caller; never signal.
VERB is one of `cmacs-gowl-floatdesk-rpc-verbs'.  Returns the module's
reply text (\"OK ...\") or \"ERROR ...\"."
  (condition-case err
      (cond
       ((not (member verb cmacs-gowl-floatdesk-rpc-verbs))
        (format "ERROR unknown floatdesk verb %s; one of %s" verb
                (string-join cmacs-gowl-floatdesk-rpc-verbs ", ")))
       ;; One line, one command: a newline would be a second command on
       ;; the IPC socket's framing.
       ((and args (string-match-p "[\n\r]" args))
        "ERROR floatdesk arguments must be one line")
       ((not (and (fboundp 'gowl-running-p) (gowl-running-p)))
        "ERROR gowl is not running")
       (t
        (unless (gowl-run-command "floatdesk-status")
          (cmacs-gowl-floatdesk-start))
        (or (gowl-run-command
             (concat "floatdesk-" verb
                     (if (and args (not (string-empty-p args)))
                         (concat " " args) "")))
            "ERROR the floatdesk module did not answer")))
    (error (concat "ERROR " (error-message-string err)))))

;;;; Startup

(defun cmacs-gowl-floatdesk--on-start ()
  "Push the settings into the module cmacs loaded, and start listening.
Called by `cmacs-gowl-mode' when the compositor (re)starts.  The module
itself is in cmacs's default set (cmacs-gowl.c); a build without it is
reported and otherwise ignored."
  (setq cmacs-gowl-floatdesk--view-floating nil)
  (condition-case err
      (cmacs-gowl-floatdesk-start)
    (error (message "cmacs-gowl-floatdesk: %s" (error-message-string err)))))

(provide 'cmacs-gowl-floatdesk)

;;; cmacs-gowl-floatdesk.el ends here
