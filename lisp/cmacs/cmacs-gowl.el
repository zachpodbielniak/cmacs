;;; cmacs-gowl.el --- Gowl compositor control  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Elisp interface for the Gowl Wayland compositor.
;;
;; C primitives available:
;;   `gowl-start'         -- start the compositor
;;   `gowl-stop'          -- stop the compositor
;;   `gowl-running-p'     -- check if compositor is running
;;   `gowl-list-clients'  -- list managed window clients
;;   `gowl-focus-client'  -- focus a client window
;;   `gowl-spawn'         -- launch a Wayland client
;;   `gowl-list-monitors' -- list connected monitors
;;   `gowl-view-tags'     -- switch tag view
;;   `gowl-set-layout'    -- set layout on monitor
;;   `gowl-client-info'   -- get client info alist
;;   `gowl-move-client'   -- move client to x,y
;;   `gowl-resize-client' -- resize client to w,h
;;   `gowl-set-tags'      -- set tags bitmask on client
;;   `gowl-close-client'  -- close client window
;;
;; This file provides:
;;   - `cmacs-gowl-mode'  -- global minor mode
;;   - Customization for borders, layouts, autostart
;;   - Interactive window management commands

;;; Code:

(require 'cl-lib)
(require 'cmacs-gowl-focus)
(require 'cmacs-gowl-app)

;; Loaded on demand when `cmacs-gowl-media-keybindings' is on, rather
;; than required here: the media layer is only useful in a running
;; session, and nothing else in this file needs it.
(declare-function cmacs-gowl-media-install-keybinds "cmacs-gowl-media" ())
(declare-function cmacs-notify-daemon-mode-global "cmacs-notify-daemon"
                  (&optional arg))
;; Autoloaded, but declared so the byte compiler knows the arity of the
;; command the Super+Escape bind names.
(declare-function cmacs-gowl-menu "cmacs-gowl-menu" ())
(declare-function cmacs-tray-mode-global "cmacs-tray" (&optional arg))

(defgroup cmacs-gowl nil
  "Gowl Wayland compositor integration."
  :group 'cmacs
  :prefix "cmacs-gowl-")

;;; Customization

(defcustom cmacs-gowl-border-width 2
  "Border width in pixels for Gowl windows."
  :type 'integer
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-border-color-focus "#5e81ac"
  "Border color for the focused window (hex string)."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-border-color-unfocus "#4c566a"
  "Border color for unfocused windows (hex string)."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-layouts '("tile" "monocle" "float")
  "List of available layout names."
  :type '(repeat string)
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-autostart nil
  "List of commands to spawn when `cmacs-gowl-mode' is enabled.
Each element is a string command to launch as a Wayland client.

Example:
  (setq cmacs-gowl-autostart
        \\='(\"foot\" \"waybar\"))"
  :type '(repeat string)
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-float-rules
  '(;; Video conferencing
    (:app-id "zoom"                  :floating t)
    (:app-id "Zoom"                  :floating t)
    (:title  "^Zoom Meeting$"        :floating t :regex t)
    (:title  "Join Meeting"          :floating t)
    (:title  "^Zoom - .*"            :floating t :regex t)
    (:app-id "teams-for-linux"       :floating t)
    (:app-id "discord" :title "^Discord Updater$" :floating t)
    ;; Email / productivity popups
    (:app-id "ch.protonmail.protonmail-bridge" :floating t)
    (:app-id "protonmail-bridge"     :floating t)
    (:app-id "thunderbird" :title "^Write: .*" :floating t :regex t)
    (:title  "^Compose: .*"          :floating t :regex t)
    ;; Password / secret prompts
    (:app-id "org.keepassxc.KeePassXC" :title "Unlock" :floating t)
    (:app-id "pinentry"              :floating t)
    (:app-id "pinentry-gtk-2"        :floating t)
    (:app-id "pinentry-qt"           :floating t)
    (:app-id "1password"             :floating t)
    (:app-id "bitwarden"             :floating t)
    ;; System / media control popups
    (:app-id "pavucontrol"           :floating t)
    (:app-id "org.pulseaudio.pavucontrol" :floating t)
    (:app-id "blueman-manager"       :floating t)
    (:app-id "nm-connection-editor"  :floating t)
    (:app-id "org.gnome.FileRoller"  :floating t)
    ;; File choosers / dialog titles
    (:title  "^Open File$"           :floating t)
    (:title  "^Open Files$"          :floating t)
    (:title  "^Save As$"             :floating t)
    (:title  "^Save File$"           :floating t)
    (:title  "^Print$"               :floating t)
    (:title  "^Print Preview$"       :floating t)
    (:title  "^Preferences$"         :floating t)
    (:title  "^Settings$"            :floating t)
    (:title  "^About .*"             :floating t :regex t)
    (:title  "^File Properties$"     :floating t)
    ;; Image viewers (typically float in a tiling WM)
    (:app-id "imv"                   :floating t)
    (:app-id "feh"                   :floating t)
    (:app-id "org.gnome.Loupe"       :floating t))
  "Window rules applied by `cmacs-gowl-mode' on enable.
Each element is a plist with the following keys:

  :app-id    Pattern matched against the Wayland app_id.
  :title     Pattern matched against the window title.
  :floating  Non-nil to force the client floating.
  :regex     Non-nil to interpret :app-id and :title as PCRE
             regexes instead of shell globs.
  :tags      Optional integer tag bitmask.
  :monitor   Optional integer monitor index (-1 for any).
  :width     Optional explicit width in pixels.
  :height    Optional explicit height in pixels.
  :center    t (default) to center floated matches on the
             target monitor, nil to keep the client's position.

The shipped defaults cover common modal/popup windows that
should float above the tiled Emacs frame: Zoom \"Join Meeting\",
Proton Mail Bridge, KeePassXC unlock, pinentry, pavucontrol,
file chooser dialogs, and similar one-shot UI windows."
  :type '(repeat plist)
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-default-dropdown-terminal "gst"
  "Default terminal command used by `cmacs-gowl-dropdowns' entries
whose :spawn-cmd is nil.  Defaults to gst (gtk-shell-toolkit
terminal) since that's what the gowl config ships with; set to
foot, alacritty, wezterm, kitty, etc. if you prefer one of those."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-terminal-command nil
  "Terminal command bound to Super+Return by the default keybindings.
When nil, falls back to `cmacs-gowl-default-dropdown-terminal'."
  :type '(choice (const :tag "Use dropdown terminal" nil)
                 (string :tag "Command"))
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-menu-command "wofi --show drun"
  "Application launcher bound to Super+p by the default keybindings.
This is the standalone gowl default.  It is a plain drun/run launcher,
not a dmenu-mode picker -- `cmacs-gowl-bemenu-in-tag' uses the separate
`cmacs-gowl-dmenu-command' (a dmenu-mode binary) instead."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-run-command "wofi --show run"
  "Run-dialog command bound to Super+Shift+p by the default keybindings.
A plain executable launcher (the \"run\" counterpart to
`cmacs-gowl-menu-command' \"drun\")."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-dmenu-command "bemenu"
  "Dmenu-mode binary used by `cmacs-gowl-bemenu-in-tag' (the in-tag app
picker).  This is deliberately separate from `cmacs-gowl-menu-command':
the picker needs a dmenu-mode binary (one that reads the app list on
stdin and prints the selection on stdout), not a drun/run launcher.
Defaults to `bemenu'; `wofi' would need `--dmenu' and a different
invocation, so leave this as `bemenu' unless you adapt the picker."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-default-keybindings t
  "When non-nil, install the standard dwm-style compositor keybindings
on `cmacs-gowl-mode' enable.

Under `emacs --gowl' the compositor starts with an empty keybind
table, so none of the familiar Super+N tag bindings work until they
are installed.  This option restores the full default set that
standalone gowl ships with (see
`cmacs-gowl--install-default-keybinds'):

  Super+Return        launch terminal (`cmacs-gowl-terminal-command')
  Super+p             launch menu (`cmacs-gowl-menu-command')
  Super+Shift+p       run dialog (`cmacs-gowl-run-command')
  Super+Shift+c       kill focused client
  Super+j / Super+k   focus next / previous in stack
  Super+h / Super+l   shrink / grow master area
  Super+i / Super+d   increment / decrement master count
  Super+Shift+Return  zoom (promote to master)
  Super+t / f / m     tile / float / monocle layout
  Super+s             scrolling layout (niri-style columns)
  Super+Tab           next layout (Super+Shift+Tab for previous)
  Super+[ / Super+]   scroll the column strip
  Super+space         toggle floating
  Super+Shift+space   toggle fullscreen
  Super+0             view all tags
  Super+Shift+0       tag focused client to all tags
  Super+1..9          view tag N
  Super+Shift+1..9    move focused client to tag N
  Super+Ctrl+1..9     toggle visibility of tag N
  Super+Shift+Ctrl+N  toggle tag N on focused client
  Super+, / Super+.   focus previous / next monitor
  Super+Shift+, / .   move focused client to previous / next monitor
  Super+Shift+q       quit the compositor
  Super+Shift+r       reload config
  Super+/             show the keybind cheatsheet
  Super+Escape        control surface (power, audio, network, ...)

Every bind is registered with a description, which is what
`cmacs-gowl-describe-keybinds' renders.

Note: under `--gowl' the compositor IS the Emacs session, so
Super+Shift+q quits Emacs.  To customise, set this to nil and add
your own binds with `gowl-add-keybind', or edit
`cmacs-gowl--install-default-keybinds'."
  :type 'boolean
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-notification-daemon t
  "When non-nil, serve org.freedesktop.Notifications on mode enable.

A gowl session has no notification daemon, so `notify-send' and every
libnotify application are silent in it -- and so are cmacs's own three
notification senders: `cmacs-notify', `cmacs-brigade-notify' and
podomation's cmacs module all end up at that same D-Bus name.

Claiming it is conditional: if something already owns the name -- GNOME
Shell in a GNOME session -- this does nothing and says so.  See
`cmacs-notify-daemon-mode-global'."
  :type 'boolean
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-tray t
  "When non-nil, serve the system tray on `cmacs-gowl-mode' enable.

A gowl session has no tray, so Solaar, Syncthing, Steam, Element and
every other tray-only application runs with its interface absent.  So
does a stock GNOME without the AppIndicator extension --- the tray is
D-Bus, not a compositor feature, and nothing owns the name by default.

Claimed only when free; a desktop that already has a tray host keeps
it.  See `cmacs-tray-mode-global'."
  :type 'boolean
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-media-keybindings t
  "When non-nil, bind the XF86 media keys on `cmacs-gowl-mode' enable.

Volume, microphone, brightness and player keys, bound to the commands
in `cmacs-gowl-media' via gowl's `custom' action -- so they run in
Emacs and show the resulting level in the echo area, rather than
spawning a helper that changes the volume with no feedback.

The backends are wpctl, brightnessctl and playerctl; see
`cmacs-gowl-media-volume-program' and friends.  A key whose backend is
not installed says so once instead of failing silently.

Set to nil to leave those keysyms unbound, or to bind them yourself
with `gowl-add-keybind'."
  :type 'boolean
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-bar-show-tags t
  "When non-nil, enable the in-process status bar on mode start.
The bar renders a dwm-style tag indicator on its left edge
(occupied / selected / urgent tags) plus the focused-window title
and the default data widgets.  Set to nil to leave the bar
disabled — you can still turn it on later with `gowl-bar-enable'.
The tag row itself can be toggled at runtime with the bar's
\"show-tags\" configuration key via `gowl-bar-configure'."
  :type 'boolean
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-monitor-tags-on-launch t
  "When non-nil, give each monitor its own initial tag on mode start.
Tags are per-monitor (dwm model): the main (first) monitor views
tag 1, the second monitor views tag 2, and so on, up to nine
monitors.  Each monitor then switches its own tags independently
(focus a monitor with Super+,/.\\ then press Super+N).  Re-apply at
any time with `cmacs-gowl-assign-monitor-tags'.

Launching into a tag (see `cmacs-gowl-spawn-in-tag') also targets
the monitor currently showing that tag, so e.g. launching on tag 2
lands on the monitor whose workspace is tag 2."
  :type 'boolean
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-dropdowns
  '((:name "term"
     :spawn-cmd nil
     :keybind "Super+grave"
     :width-pct 1.0
     :height-pct 0.4
     :anchor top))
  "Guake-style dropdown entries managed by `cmacs-gowl-mode'.
Each element is a plist:

  :name        Unique string identifier.
  :spawn-cmd   Shell command to spawn on first toggle, or nil
               to fall back to `cmacs-gowl-default-dropdown-terminal'.
  :keybind     Keybind string (e.g. \"Super+grave\"), or nil.
  :width-pct   Fractional width (0.0–1.0) of target output.
  :height-pct  Fractional height (0.0–1.0) of target output.
  :width       Optional absolute width in pixels.
  :height      Optional absolute height in pixels.
  :anchor      Symbol `top', `bottom', `left', or `right'.

The first press of the keybind spawns the command and captures
its first Wayland toplevel.  Subsequent presses toggle the
window's visibility without destroying it, and re-compute its
position for the currently focused output so the dropdown
always appears on the user's active monitor."
  :type '(repeat plist)
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-default-layout "tile"
  "Default layout to apply when the compositor starts."
  :type 'string
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-session-file nil
  "File path for automatic session save/restore, or nil to disable.
When non-nil, `cmacs-gowl-mode' enable calls `gowl-session-restore'
with this path (if the file exists), and `kill-emacs-hook' calls
`gowl-session-save' to refresh it.  Set to a file like
\"~/.config/gowl/session.yaml\" to opt in."
  :type '(choice (const :tag "Disabled" nil)
                 (file :tag "Session file"))
  :group 'cmacs-gowl)

(defcustom cmacs-gowl-config-evaluation '(yaml c)
  "Which portions of ~/.config/gowl/ to apply under --gowl.
A list of symbols from the set `yaml' and `c'.  Presence of the
symbol enables evaluation of that config source; absence disables
it.  The two gates are independent: YAML is loaded first, then
C config.

This defcustom mirrors the two root-level GowlConfig properties
`evaluate-gowl-config-with-cmacs' (YAML gate) and
`evaluate-c-config-with-cmacs' (C-config gate).  It exists so
users can write:

  (setq cmacs-gowl-config-evaluation \\='(yaml))      ; YAML only
  (setq cmacs-gowl-config-evaluation \\='(c))         ; C only
  (setq cmacs-gowl-config-evaluation nil)             ; neither

…without touching a YAML file.  The initial load at --gowl
startup respects the YAML's root-level declarations first; this
defcustom only takes effect when applied at runtime (post-start)
via `cmacs-gowl-apply-config-evaluation' — at that point the
compositor is already up, so the gates are informational until
the next `gowl-reload-config'.

Standalone gowl and nested-gowl ignore the two gates entirely;
they are purely a cmacs `--gowl' concern."
  :type '(set (const :tag "YAML config" yaml)
              (const :tag "C config"    c))
  :group 'cmacs-gowl)

(defun cmacs-gowl-apply-config-evaluation ()
  "Push `cmacs-gowl-config-evaluation' onto the live GowlConfig.
Sets the two root-level properties so any subsequent
`gowl-reload-config' respects them.  No-op if gowl isn't running."
  (interactive)
  (when (gowl-running-p)
    (let* ((cfg (gowl-config-object))
           (yaml-on (memq 'yaml cmacs-gowl-config-evaluation))
           (c-on    (memq 'c    cmacs-gowl-config-evaluation)))
      (when cfg
        ;; Uses the generic GObject set DEFUN from cmacs-gobject;
        ;; emits notify:: on change.
        (gobject-set cfg "evaluate-gowl-config-with-cmacs"
                     (if yaml-on t nil))
        (gobject-set cfg "evaluate-c-config-with-cmacs"
                     (if c-on t nil))))))

;;; Internal state

(defvar cmacs-gowl--active nil
  "Non-nil when `cmacs-gowl-mode' is active.")

(defvar cmacs-gowl--autostart-launched nil
  "Non-nil if autostart programs have already been launched.")

;;; Internal functions

(defun cmacs-gowl--apply-float-rules ()
  "Push `cmacs-gowl-float-rules' into the running gowl config.
Clears any existing rules first so this function is idempotent
across mode re-enables.  Skips the push entirely if the rules
list is empty or gowl is not running."
  (when (and (gowl-running-p) cmacs-gowl-float-rules)
    (gowl-clear-rules)
    (dolist (rule cmacs-gowl-float-rules)
      (let ((app-id   (plist-get rule :app-id))
            (title    (plist-get rule :title))
            (tags     (or (plist-get rule :tags) 0))
            (floating (plist-get rule :floating))
            (monitor  (or (plist-get rule :monitor) -1))
            (width    (or (plist-get rule :width) 0))
            (height   (or (plist-get rule :height) 0))
            (regex    (plist-get rule :regex)))
        ;; The :center key is honored by YAML but always true via
        ;; this DEFUN entry point (Emacs DEFUN max is 8 args).
        (condition-case err
            (gowl-add-rule-full app-id title tags floating
                                 monitor width height regex)
          (error
           (message "cmacs-gowl: rule %S failed: %s" rule err)))))))

(defun cmacs-gowl--apply-dropdowns ()
  "Push `cmacs-gowl-dropdowns' into the running gowl config.
Each entry whose :spawn-cmd is nil is replaced with
`cmacs-gowl-default-dropdown-terminal' so users can override the
terminal choice with a single setting."
  (when (and (gowl-running-p) cmacs-gowl-dropdowns)
    (dolist (dd cmacs-gowl-dropdowns)
      (let ((name        (plist-get dd :name))
            (spawn-cmd   (or (plist-get dd :spawn-cmd)
                             cmacs-gowl-default-dropdown-terminal))
            (keybind     (plist-get dd :keybind))
            (width-pct   (or (plist-get dd :width-pct) 1.0))
            (height-pct  (or (plist-get dd :height-pct) 0.4))
            (width       (or (plist-get dd :width) 0))
            (height      (or (plist-get dd :height) 0))
            (anchor      (or (plist-get dd :anchor) 'top)))
        (condition-case err
            (gowl-add-dropdown name spawn-cmd keybind
                                width-pct height-pct
                                width height anchor)
          (error
           (message "cmacs-gowl: dropdown %S failed: %s" dd err)))))))

(defvar cmacs-gowl--keybinds-installed nil
  "Non-nil once `cmacs-gowl--install-default-keybinds' has run.
Reset by `cmacs-gowl--stop' so re-enabling the mode re-installs.")

(defun cmacs-gowl--install-default-keybinds ()
  "Install the standard dwm-style gowl keybindings into the live config.
Idempotent within a mode session.  See `cmacs-gowl-default-keybindings'
for the full binding table.

Each bind is added via `gowl-add-keybind'.  The compositor evaluates
its config keybind table before forwarding keys to the focused
surface, so these work globally even while Emacs or an embedded
client holds keyboard focus.  Tag action args are 1-based tag
numbers as strings (\"0\" means all tags), matching the C defaults.

Each bind first removes any existing bind for the same key combo via
`gowl-remove-keybind' before adding the new one.  gowl dispatches the
first matching entry, so without this an older bind for the same key
(a stale duplicate left by a previous load of this function, e.g. an
outdated `cmacs-gowl.elc' that used a different launcher) would shadow
the freshly installed one.  Removing first makes each default bind
authoritative and keeps re-runs idempotent."
  (unless cmacs-gowl--keybinds-installed
    (let ((term (or cmacs-gowl-terminal-command
                    cmacs-gowl-default-dropdown-terminal
                    "gst"))
          (menu (or cmacs-gowl-menu-command "wofi --show drun"))
          (run  (or cmacs-gowl-run-command "wofi --show run")))
      (cl-flet ((bind (key action &optional arg desc)
                  ;; Remove any stale bind for this key combo first so
                  ;; the new entry below is the one gowl dispatches.
                  ;; `ignore-errors' tolerates older builds that lack
                  ;; `gowl-remove-keybind' (void-function).
                  (ignore-errors (gowl-remove-keybind key))
                  ;; DESC is the fourth argument and older builds took
                  ;; three, so fall back rather than losing the bind
                  ;; entirely on a mismatched C layer.
                  (or (ignore-errors
                        (gowl-add-keybind key action arg desc))
                      (ignore-errors (gowl-add-keybind key action arg)))))
        ;; Spawns.
        (bind "Super+Return" 'spawn term "Terminal")
        (bind "Super+p" 'spawn menu "App launcher")
        (bind "Super+Shift+p" 'spawn run "Run command")
        ;; Client management.
        (bind "Super+Shift+c" 'kill-client nil "Close window")
        (bind "Super+j" 'focus-stack "+1" "Focus next window")
        (bind "Super+k" 'focus-stack "-1" "Focus previous window")
        (bind "Super+h" 'set-mfact "-0.05" "Shrink master area")
        (bind "Super+l" 'set-mfact "+0.05" "Grow master area")
        (bind "Super+i" 'inc-nmaster "+1" "More master windows")
        (bind "Super+d" 'inc-nmaster "-1" "Fewer master windows")
        (bind "Super+Shift+Return" 'zoom nil "Promote to master")
        ;; Layouts.
        (bind "Super+t" 'set-layout "tile" "Tile layout")
        (bind "Super+f" 'set-layout "float" "Float layout")
        (bind "Super+m" 'set-layout "monocle" "Monocle layout")
        (bind "Super+s" 'set-layout "scrolling" "Scrolling layout")
        (bind "Super+Tab" 'cycle-layout nil "Next layout")
        (bind "Super+Shift+Tab" 'cycle-layout "-1" "Previous layout")
        ;; Scroll the column strip.  Only meaningful in the scrolling
        ;; layout; harmless everywhere else.
        (bind "Super+bracketleft" 'custom "(gowl-scroll-by -200)"
              "Scroll columns left")
        (bind "Super+bracketright" 'custom "(gowl-scroll-by 200)"
              "Scroll columns right")
        (bind "Super+v" 'set-split "vsplit" "Vertical split")
        (bind "Super+Shift+v" 'set-split "normal" "Horizontal split")
        (bind "Super+space" 'toggle-float nil "Toggle floating")
        (bind "Super+Shift+space" 'toggle-fullscreen nil "Toggle fullscreen")
        ;; Tags.  The compositor interprets every tag-action arg as a
        ;; raw tag *bitmask* (atoi(arg) & TAGMASK), not a 1-based tag
        ;; number — and arg "0" is a no-op.  So tag N uses the string
        ;; for (ash 1 (1- N)) and "view/tag all" uses the all-tags
        ;; mask (1<<9)-1.  (gowl's shipped default-config.c passes
        ;; plain "1".."9"/"0" here, which is only correct for tags 1
        ;; and 2 and a no-op for "all"; we pass real bitmasks.)
        (let ((all (number-to-string (1- (ash 1 9)))))
          (bind "Super+0" 'tag-view all "View all tags")
          (bind "Super+Shift+0" 'tag-set all "Tag window to all"))
        (dotimes (i 9)
          (let* ((n    (1+ i))
                 (key  (number-to-string n))
                 (mask (number-to-string (ash 1 i))))
            (bind (concat "Super+" key) 'tag-view mask
                  (format "View tag %d" n))
            (bind (concat "Super+Shift+" key) 'tag-set mask
                  (format "Move window to tag %d" n))
            (bind (concat "Super+Ctrl+" key) 'tag-toggle-view mask
                  (format "Toggle tag %d in view" n))
            (bind (concat "Super+Shift+Ctrl+" key) 'tag-toggle mask
                  (format "Toggle tag %d on window" n))))
        ;; Multi-monitor.
        (bind "Super+comma" 'focus-monitor "-1" "Focus previous monitor")
        (bind "Super+period" 'focus-monitor "+1" "Focus next monitor")
        (bind "Super+Shift+comma" 'move-to-monitor "-1"
              "Move window to previous monitor")
        (bind "Super+Shift+period" 'move-to-monitor "+1"
              "Move window to next monitor")
        ;; Session.
        (bind "Super+Shift+q" 'quit nil "Quit cmacs")
        (bind "Super+Shift+r" 'reload-config nil "Reload gowl config")
        (bind "Super+slash" 'custom "(cmacs-gowl-describe-keybinds)"
              "Show this cheatsheet")
        (bind "Super+Escape" 'custom "(cmacs-gowl-menu)"
              "Control surface (power, audio, network, ...)"))
      ;; Media, volume and brightness keys.  Bound to Elisp via gowl's
      ;; `custom' action rather than spawned, so each one can show the
      ;; resulting level.  Opt out with `cmacs-gowl-media-keybindings'.
      (when cmacs-gowl-media-keybindings
        (require 'cmacs-gowl-media)
        (ignore-errors (cmacs-gowl-media-install-keybinds))))
    (setq cmacs-gowl--keybinds-installed t)))

;;; Keybind cheatsheet

(defvar cmacs-gowl-describe-keybinds-buffer "*gowl keybinds*"
  "Buffer name used by `cmacs-gowl-describe-keybinds'.")

(defun cmacs-gowl--keybind-label (entry)
  "Return the human-readable label for keybind alist ENTRY.
Prefers the bind's own description.  Falls back to the action and its
argument, so a bind registered without a description --- from a YAML
config, or by a module --- still says something more useful than a
bare action name."
  (let ((desc   (cdr (assq 'desc entry)))
        (action (cdr (assq 'action entry)))
        (arg    (cdr (assq 'arg entry))))
    (cond
     ((and (stringp desc) (not (string-empty-p desc))) desc)
     ((and arg (not (string-empty-p arg)))
      (format "%s: %s" action arg))
     (t (format "%s" action)))))

(defun cmacs-gowl--keybind-sort-key (entry)
  "Return a sort key for keybind alist ENTRY.
Groups by modifier set first so that the plain media keys, the Super
binds and the Super+Shift binds each land together, then by the key
name inside a group."
  (let* ((key (or (cdr (assq 'key entry)) ""))
         (parts (split-string key "+" t))
         (mods (butlast parts))
         (base (car (last parts))))
    (cons (length mods) (concat (mapconcat #'identity mods "+") "\0" base))))

;;;###autoload
(defun cmacs-gowl-describe-keybinds ()
  "Show every active compositor keybind, with what it does.

Reads the live table out of the running compositor rather than any
config file, so binds added at runtime --- by a module, by a
podomation rule, from an MCP tool --- appear alongside the defaults.

Each line shows its description where the bind carries one, and falls
back to the action and argument where it does not."
  (interactive)
  (unless (fboundp 'gowl-list-keybinds)
    (user-error "Gowl support is not compiled into this build"))
  (let ((binds (ignore-errors (gowl-list-keybinds))))
    (unless binds
      (user-error "No compositor keybinds (is gowl running?)"))
    (setq binds
          (sort (copy-sequence binds)
                (lambda (a b)
                  (let ((ka (cmacs-gowl--keybind-sort-key a))
                        (kb (cmacs-gowl--keybind-sort-key b)))
                    (if (= (car ka) (car kb))
                        (string< (cdr ka) (cdr kb))
                      (< (car ka) (car kb)))))))
    ;; Elisp's `format' has no `*' width, so the column is baked into
    ;; the control string once rather than passed per line.
    (let* ((width (apply #'max 3 (mapcar (lambda (e)
                                           (length (or (cdr (assq 'key e)) "")))
                                         binds)))
           (line (format "  %%-%ds  %%s\n" width)))
      (with-current-buffer (get-buffer-create
                            cmacs-gowl-describe-keybinds-buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "%d compositor keybinds\n\n" (length binds)))
          (dolist (entry binds)
            (insert (format line
                            (or (cdr (assq 'key entry)) "")
                            (cmacs-gowl--keybind-label entry)))))
        (goto-char (point-min))
        (special-mode)
        (display-buffer (current-buffer))))))

(defun cmacs-gowl--start ()
  "Start the Gowl compositor and apply configuration.
When launched with --gowl, the compositor is already running and
Emacs is rendering inside it.  This function ensures the dispatch
thread is running and applies configuration."
  (gowl-start)  ;; no-op if already running via --gowl
  ;; Reflect the Elisp defcustom onto the live GowlConfig so any
  ;; later `gowl-reload-config' honours it.
  (cmacs-gowl-apply-config-evaluation)
  ;; Apply default layout.
  (when cmacs-gowl-default-layout
    (gowl-set-layout cmacs-gowl-default-layout))
  ;; Restore the standard dwm-style keybindings.  The --gowl launch
  ;; path starts with an empty keybind table, so without this Super+N
  ;; tag switching, Super+p menu, etc. are all inert.
  (when cmacs-gowl-default-keybindings
    (cmacs-gowl--install-default-keybinds))
  ;; Serve org.freedesktop.Notifications.  Nothing else does in a gowl
  ;; session, which is why cmacs's own notification senders are silent
  ;; in it.  A no-op when something already owns the name.
  (when cmacs-gowl-notification-daemon
    (require 'cmacs-notify-daemon)
    (ignore-errors (cmacs-notify-daemon-mode-global 1)))
  ;; Serve the system tray.  Same reasoning as the notification daemon:
  ;; nothing else on the machine does, so tray-only applications are
  ;; running with no interface at all.
  (when cmacs-gowl-tray
    (require 'cmacs-tray)
    (ignore-errors (cmacs-tray-mode-global 1)))
  ;; Enable the in-process status bar with its dwm-style tag
  ;; indicator.  Opt-out via `cmacs-gowl-bar-show-tags'.
  (when (and cmacs-gowl-bar-show-tags
             (fboundp 'gowl-bar-enable))
    (ignore-errors
      (gowl-bar-enable)
      (when (fboundp 'gowl-bar-configure)
        (gowl-bar-configure '(("show-tags" . "true"))))
      (when (fboundp 'cmacs-gowl-bar-sync-enable)
        (cmacs-gowl-bar-sync-enable))))
  ;; Give each monitor its own initial tag (main → 1, second → 2, …).
  ;; Outputs may settle slightly after the compositor starts, so try
  ;; immediately and once more shortly after.
  (when cmacs-gowl-monitor-tags-on-launch
    (ignore-errors (cmacs-gowl-assign-monitor-tags))
    (run-with-timer
     0.6 nil
     (lambda ()
       (when (and cmacs-gowl-monitor-tags-on-launch (gowl-running-p))
         (ignore-errors (cmacs-gowl-assign-monitor-tags))))))
  ;; Push float rules and dropdowns from defcustoms into the
  ;; running gowl config.  Dropdowns must be pushed before the
  ;; dropdown module reads them at its own startup; in the
  ;; --gowl launch path the module has already initialised, so
  ;; runtime additions work via the config-scan fallback in
  ;; modules/dropdown/dd_adopt_config_entry().
  (cmacs-gowl--apply-float-rules)
  (cmacs-gowl--apply-dropdowns)
  ;; Tell the dropdown module to adopt any newly-added config
  ;; entries so per-entry keybinds work for defcustom-driven
  ;; dropdowns after module startup.  The DEFUN is a no-op if
  ;; the dropdown module isn't loaded.
  (when (fboundp 'gowl-dropdown-refresh)
    (ignore-errors (gowl-dropdown-refresh)))
  ;; Install the prefix-key policy + post-command hook.  Keeps
  ;; C-x/C-c/M-x/C-g/C-h reaching Emacs even when an embed has
  ;; focus.  Replaces the old ESC-timer escape hatch.
  (cmacs-gowl-focus-setup)
  ;; Install the default workspace provider.  Enables the
  ;; `workspace-*` signals on the compositor.  Standalone users
  ;; never hit this — it's cmacs-gowl-mode exclusive.
  (when (fboundp 'gowl-install-frame-workspace-manager)
    (gowl-install-frame-workspace-manager))
  ;; Auto-restore session if configured.
  (when (and cmacs-gowl-session-file
             (file-exists-p (expand-file-name cmacs-gowl-session-file)))
    (condition-case err
        (gowl-session-restore (expand-file-name cmacs-gowl-session-file))
      (error
       (message "cmacs-gowl: session restore failed: %s" err))))
  ;; Install the save-on-exit hook idempotently.
  (add-hook 'kill-emacs-hook #'cmacs-gowl--save-session-if-configured)
  ;; Ensure Emacs has keyboard focus.  The client may have mapped
  ;; before focus was properly assigned, so explicitly focus it.
  (run-with-timer 0.5 nil
    (lambda ()
      (when (gowl-running-p)
        (let ((clients (gowl-list-clients)))
          (when clients
            (gowl-focus-client (car clients)))))))
  ;; Launch autostart programs (only once per session).
  (unless cmacs-gowl--autostart-launched
    (dolist (cmd cmacs-gowl-autostart)
      (condition-case err
          (gowl-spawn cmd)
        (gowl-error
         (message "Gowl autostart failed for %S: %s"
                  cmd (cadr err)))))
    (setq cmacs-gowl--autostart-launched t))
  (setq cmacs-gowl--active t))

(defun cmacs-gowl--save-session-if-configured ()
  "Run `gowl-session-save' against `cmacs-gowl-session-file' when set."
  (when (and cmacs-gowl-session-file
             (fboundp 'gowl-session-save)
             (gowl-running-p))
    (ignore-errors
      (gowl-session-save (expand-file-name cmacs-gowl-session-file)))))

(defun cmacs-gowl--stop ()
  "Stop the Gowl compositor."
  (cmacs-gowl--save-session-if-configured)
  (remove-hook 'kill-emacs-hook #'cmacs-gowl--save-session-if-configured)
  (cmacs-gowl-focus-teardown)
  (when (and (gowl-running-p)
             (fboundp 'gowl-uninstall-workspace-provider))
    (gowl-uninstall-workspace-provider))
  (when (gowl-running-p)
    (gowl-stop))
  (setq cmacs-gowl--keybinds-installed nil)
  (setq cmacs-gowl--active nil))

;;; Global minor mode

;;;###autoload
(define-minor-mode cmacs-gowl-mode
  "Global minor mode for Gowl Wayland compositor control.

When enabled, starts the embedded Gowl compositor (if not already
running), applies configuration from the `cmacs-gowl' customization
group, and launches autostart programs.

When disabled, stops the compositor."
  :global t
  :lighter " Gowl"
  :group 'cmacs-gowl
  (if cmacs-gowl-mode
      (cmacs-gowl--start)
    (cmacs-gowl--stop)))

;;;###autoload
(defun cmacs-gowl-attach ()
  "Bring up the embedded Gowl compositor in THIS Emacs; return its host frame.
The runtime equivalent of the `--gowl' startup flag: `emacs --gowl' owns
the compositor from early `main', while this enables `cmacs-gowl-mode' in
an Emacs that is already up, so a running instance (or a daemon) can host
the session on demand.  `emacsclient --gowl' uses it, via the server's
`-gowl' request.

Started inside an existing Wayland session, wlroots uses its nested
backend, so the compositor is an *embedded* session -- a window in the
outer compositor -- driven by this Emacs.

There is one compositor per process, so this never starts a second one:
with Gowl already running (either launch path) it just returns the host
frame.

Signals an error when this cmacs was built without `--with-cmacs-gowl',
or when there is no display to nest inside (a headless daemon) -- wlroots
cannot create an output then."
  (interactive)
  (unless (fboundp 'gowl-start)
    (error "cmacs-gowl-attach: built without --with-cmacs-gowl"))
  ;; A compositor needs either a parent Wayland session to nest in or a
  ;; graphical frame whose display it can borrow (`gowl-start' recovers
  ;; the socket name from GDK when WAYLAND_DISPLAY is unset).  Refuse
  ;; early and clearly instead of letting wlroots fail deep inside.
  (unless (or (gowl-running-p)
              (getenv "WAYLAND_DISPLAY")
              (cl-some #'display-graphic-p (frame-list)))
    (error "cmacs-gowl-attach: no Wayland display to nest inside; start \
the Emacs that should own the compositor inside a graphical session"))
  (unless cmacs-gowl-mode
    (cmacs-gowl-mode 1))
  ;; Hand the client the frame that hosts the session: the selected one
  ;; when it is graphical, else any graphical frame (a daemon's initial
  ;; terminal frame is no use to a compositor).  nil is fine -- server
  ;; then uses its own current frame.
  (let ((frame (if (display-graphic-p) (selected-frame)
                 (cl-find-if #'display-graphic-p (frame-list)))))
    (when (frame-live-p frame)
      (select-frame-set-input-focus frame))
    frame))

;;; Interactive window management commands

(defun cmacs-gowl-list-windows ()
  "Display a list of managed Gowl windows."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((clients (gowl-list-clients)))
    (if (null clients)
        (message "No windows")
      (with-help-window "*Gowl Windows*"
        (princ (format "Gowl Windows (%d):\n\n" (length clients)))
        (princ (format "%-30s %-20s %-8s %s\n"
                       "Title" "App ID" "Tags" "Geometry"))
        (princ (make-string 78 ?-))
        (princ "\n")
        (dolist (client clients)
          (let ((info (gowl-client-info client)))
            (princ (format "%-30s %-20s %-8s %s\n"
                           (truncate-string-to-width
                            (cdr (assq 'title info)) 30)
                           (truncate-string-to-width
                            (cdr (assq 'app-id info)) 20)
                           (cdr (assq 'tags info))
                           (cdr (assq 'geometry info))))))))))

(defun cmacs-gowl-focus-window ()
  "Interactively select and focus a Gowl window."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((clients (gowl-list-clients))
         (candidates
          (mapcar (lambda (client)
                    (let ((info (gowl-client-info client)))
                      (cons (format "%s [%s]"
                                    (cdr (assq 'title info))
                                    (cdr (assq 'app-id info)))
                            client)))
                  clients))
         (choice (completing-read "Focus window: " candidates nil t))
         (client (cdr (assoc choice candidates))))
    (when client
      (gowl-focus-client client))))

(defun cmacs-gowl-close-window ()
  "Interactively select and close a Gowl window."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((clients (gowl-list-clients))
         (candidates
          (mapcar (lambda (client)
                    (let ((info (gowl-client-info client)))
                      (cons (format "%s [%s]"
                                    (cdr (assq 'title info))
                                    (cdr (assq 'app-id info)))
                            client)))
                  clients))
         (choice (completing-read "Close window: " candidates nil t))
         (client (cdr (assoc choice candidates))))
    (when client
      (gowl-close-client client))))

;;;###autoload
(defun cmacs-gowl-spawn-command (command)
  "Launch COMMAND as a Wayland client in the Gowl compositor."
  (interactive "sSpawn command: ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (gowl-spawn command))

(defun cmacs-gowl--bar-redraw ()
  "Force the gowl bar to repaint, if the bar module is loaded.
Used after Elisp-driven tag changes so the tag indicator updates
immediately rather than waiting for the next bar tick."
  (when (fboundp 'gowl-bar-redraw)
    (ignore-errors (gowl-bar-redraw))))

(defun cmacs-gowl--refresh-view ()
  "Re-apply the focused monitor's current tag view.
After a low-level change to a client's tags (e.g. moving it to
another tag), re-viewing the monitor's active tags makes
`gowl-view-tags' run the full dwm view() — hiding the moved client,
re-tiling, and refocusing the top remaining client."
  (let ((active (cdr (assq 'active (ignore-errors (gowl-tag-info))))))
    (when (and (integerp active) (> active 0))
      (gowl-view-tags active))))

(defun cmacs-gowl-view-tag (tag)
  "Switch to TAG (1-9)."
  (interactive "nTag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (when (and (>= tag 1) (<= tag 9))
    (gowl-view-tags (ash 1 (1- tag)))
    (cmacs-gowl--bar-redraw)))

(defun cmacs-gowl-send-to-tag (tag)
  "Send the focused client to TAG (1-9)."
  (interactive "nSend to tag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (when (and (>= tag 1) (<= tag 9))
    (let ((client (and (fboundp 'gowl-focused-client)
                       (gowl-focused-client))))
      ;; Fall back to the first managed client if no explicit focus.
      (unless client
        (setq client (car (gowl-list-clients))))
      (when client
        (gowl-set-tags client (ash 1 (1- tag)))
        ;; Re-tile + refocus so the moved client leaves the view.
        (cmacs-gowl--refresh-view)
        (cmacs-gowl--bar-redraw)))))

(defun cmacs-gowl-toggle-tag (tag)
  "Toggle visibility of TAG (1-9) on the focused monitor."
  (interactive "nToggle tag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (when (and (>= tag 1) (<= tag 9)
             (fboundp 'gowl-toggle-tag-view))
    (gowl-toggle-tag-view (1- tag))
    ;; Re-tile + refocus for the newly toggled tag set.
    (cmacs-gowl--refresh-view)
    (cmacs-gowl--bar-redraw)))

;;; Tag and window pickers (M-x)

(defun cmacs-gowl--tag-mask-label (mask)
  "Return a compact label like \"3\" or \"1,2\" for tag bitmask MASK."
  (let (tags)
    (dotimes (i 9)
      (when (/= 0 (logand mask (ash 1 i)))
        (push (number-to-string (1+ i)) tags)))
    (if tags (mapconcat #'identity (nreverse tags) ",") "—")))

(defun cmacs-gowl--client-label (info)
  "Build a completion label for client INFO alist."
  (let ((title (cdr (assq 'title info)))
        (app   (cdr (assq 'app-id info)))
        (tags  (or (cdr (assq 'tags info)) 0)))
    (format "%s%s  — tag %s"
            (if (and title (not (string-empty-p title))) title "(untitled)")
            (if (and app (not (string-empty-p app)))
                (format "  [%s]" app) "")
            (cmacs-gowl--tag-mask-label tags))))

;;;###autoload
(defun cmacs-gowl-switch-tag ()
  "Pick a tag from a list annotated with what's open, and switch to it.
Switches the focused monitor's view (tags are per-monitor).  A
friendlier `M-x' alternative to `cmacs-gowl-view-tag' / Super+N."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((infos (mapcar #'gowl-client-info (gowl-list-clients)))
         (candidates
          (mapcar
           (lambda (n)
             (let* ((bit (ash 1 (1- n)))
                    (apps (delq nil
                                (mapcar
                                 (lambda (info)
                                   (when (/= 0 (logand
                                                (or (cdr (assq 'tags info)) 0)
                                                bit))
                                     (let ((a (cdr (assq 'app-id info)))
                                           (ti (cdr (assq 'title info))))
                                       (if (and a (not (string-empty-p a)))
                                           a ti))))
                                 infos)))
                    (label (if apps
                               (format "Tag %d — %s" n
                                       (mapconcat #'identity apps ", "))
                             (format "Tag %d — (empty)" n))))
               (cons label n)))
           (number-sequence 1 9)))
         (choice (completing-read "Switch to tag: " candidates nil t))
         (n (cdr (assoc choice candidates))))
    (when n
      (cmacs-gowl-view-tag n))))

;;;###autoload
(defun cmacs-gowl-switch-to-app ()
  "Pick an open window from all tags/monitors and jump to it.
Presents every managed window (title, app-id and its tag); selecting
one reveals that tag on the window's monitor and focuses it — so you
can reach an app open in another tag or on another monitor without
hunting for it.  Embedded clients (apps inside Emacs windows) are
excluded; reach those with \\[switch-to-buffer]."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((candidates
         (delq nil
               (mapcar
                (lambda (c)
                  (let ((info (gowl-client-info c)))
                    (unless (cdr (assq 'embedded info))
                      (cons (cmacs-gowl--client-label info) c))))
                (gowl-list-clients)))))
    (if (null candidates)
        (message "No windows open")
      (let* ((choice (completing-read "Switch to window: " candidates nil t))
             (client (cdr (assoc choice candidates))))
        (when client
          (gowl-focus-client client)
          (cmacs-gowl--bar-redraw))))))

;;; Multi-monitor tag assignment

;;;###autoload
(defun cmacs-gowl-assign-monitor-tags ()
  "Give each ENABLED monitor its own initial tag: 1st → tag 1, 2nd → tag 2…
Tags are per-monitor, so the main monitor views tag 1, the second views
tag 2, and so on, up to nine monitors.  Each monitor then switches its
own tags independently.  Called on mode start when
`cmacs-gowl-monitor-tags-on-launch' is non-nil; also runnable by hand
after hotplugging a monitor.

Powered-off monitors (e.g. a lid-shut internal panel in clamshell mode)
are SKIPPED: they must not consume a tag slot.  Otherwise a disabled
internal panel at list index 0 would take tag 1 (where the Emacs frame
lives) and push the only visible external monitor onto tag 2, hiding all
its windows — and `gowl-view-tags' on the disabled panel would also make
it the selected monitor, stranding focus / the bar on the dark screen."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((i 0))
    (dolist (mon (gowl-list-monitors))
      (when (and (ignore-errors (gowl-monitor-enabled-p mon)) (< i 9))
        (gowl-view-tags (ash 1 i) mon)
        (setq i (1+ i)))))
  ;; `gowl-view-tags' focus-follows per monitor, which would leave
  ;; keyboard focus on the last monitor's top client (or nowhere if
  ;; it is empty).  Return focus to Emacs.
  (when (fboundp 'gowl-emacs-client)
    (let ((ec (ignore-errors (gowl-emacs-client))))
      (when ec (ignore-errors (gowl-focus-client ec)))))
  (cmacs-gowl--bar-redraw))

(defun cmacs-gowl--monitor-index-showing-tag (mask)
  "Return the 0-based index of the monitor currently viewing MASK, or nil.
Lets a launched client land on the monitor whose workspace is that
tag.  nil when no monitor shows the tag (e.g. fewer monitors than
tags) — the client then maps on the focused monitor."
  (let ((monitors (gowl-list-monitors))
        (idx 0)
        (found nil))
    (while (and monitors (not found))
      (let ((tags (cdr (assq 'tags (ignore-errors
                                     (gowl-monitor-info (car monitors)))))))
        (when (and (integerp tags) (/= 0 (logand tags mask)))
          (setq found idx)))
      (setq monitors (cdr monitors))
      (setq idx (1+ idx)))
    found))

;;; Launching applications into a specific tag (workspace)

(defun cmacs-gowl--retag-pid-when-mapped (pid mask &optional monitor attempts)
  "Poll for the gowl client with PID, place it on MONITOR and tags MASK.
MONITOR is a 0-based index or nil (keep current monitor).  Fallback
used only when the compositor lacks `gowl-pretag-pid'.  Retries every
0.1s up to ATTEMPTS times (default 30 ≈ 3s)."
  (let ((attempts (or attempts 30)))
    (run-with-timer
     0.1 nil
     (lambda ()
       (when (gowl-running-p)
         (let ((client (seq-find (lambda (c) (= (gowl-client-pid c) pid))
                                 (gowl-list-clients))))
           (cond
            (client
             (when monitor
               (let ((mon (nth monitor (gowl-list-monitors))))
                 (when (and mon (fboundp 'gowl-move-client-to-monitor))
                   (ignore-errors (gowl-move-client-to-monitor client mon)))))
             (gowl-set-tags client mask)
             (cmacs-gowl--bar-redraw))
            ((> attempts 0)
             (cmacs-gowl--retag-pid-when-mapped
              pid mask monitor (1- attempts))))))))))

;;;###autoload
(defun cmacs-gowl-spawn-in-tag (command tag)
  "Spawn COMMAND as a Wayland client placed on TAG (1-9).
Registers the spawned PID with the compositor so the new client
adopts TAG's bitmask — and the monitor currently showing that tag —
the instant it maps, so it never flashes on the current tag/monitor.
Returns the spawned PID.

Unlike `gowl-embed', the app runs as an independent tiled/floating
client in its own workspace rather than inside an Emacs window."
  (interactive
   (list (read-string "Spawn command: ")
         (read-number "Tag (1-9): ")))
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (unless (and (integerp tag) (>= tag 1) (<= tag 9))
    (user-error "Tag must be between 1 and 9"))
  (let* ((mask (ash 1 (1- tag)))
         (mon (cmacs-gowl--monitor-index-showing-tag mask))
         (pid (gowl-spawn command)))
    (if (fboundp 'gowl-pretag-pid)
        (ignore-errors (gowl-pretag-pid pid mask mon))
      (cmacs-gowl--retag-pid-when-mapped pid mask mon))
    (message "Launching %s on tag %d%s…" command tag
             (if mon (format " (monitor %d)" (1+ mon)) ""))
    pid))

;;;###autoload
(defun cmacs-gowl-launch-in-tag (tag)
  "Pick a GUI application and launch it on TAG (1-9).
Uses Emacs completion over installed .desktop applications, then
hands off to `cmacs-gowl-spawn-in-tag'."
  (interactive "nLaunch on tag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((apps (gowl-embed--list-apps))
         (name (completing-read (format "Launch on tag %d: " tag)
                                (mapcar #'car apps) nil t))
         (exec (cdr (assoc name apps))))
    (unless exec (user-error "App not found: %s" name))
    (cmacs-gowl-spawn-in-tag exec tag)))

(defun cmacs-gowl--bemenu-binary ()
  "Return the dmenu-mode binary used for in-tag app selection.
Taken from `cmacs-gowl-dmenu-command' (first word, with any trailing
-run stripped).  Decoupled from `cmacs-gowl-menu-command' so the
Super+p launcher can be a drun/run tool (e.g. wofi) without breaking
the dmenu-mode picker."
  (let ((base (car (split-string (or cmacs-gowl-dmenu-command "bemenu")))))
    (replace-regexp-in-string "-run\\'" "" base)))

;;;###autoload
(defun cmacs-gowl-bemenu-in-tag (tag)
  "Pick a GUI application via bemenu and launch it on TAG (1-9).
Runs bemenu in dmenu mode (reading the app list on stdin) so cmacs
owns the spawn — and thus the PID — and can place the client on
TAG via `cmacs-gowl-spawn-in-tag'.  The bemenu UI itself is shown
inside gowl by pointing WAYLAND_DISPLAY at the compositor socket.
Falls back to `cmacs-gowl-launch-in-tag' when bemenu is missing."
  (interactive "nLaunch on tag (1-9): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((bemenu (cmacs-gowl--bemenu-binary)))
    (if (not (executable-find bemenu))
        (cmacs-gowl-launch-in-tag tag)
      (let* ((apps (gowl-embed--list-apps))
             (socket (and (fboundp 'gowl-socket-name) (gowl-socket-name)))
             (process-environment
              (if socket
                  (cons (concat "WAYLAND_DISPLAY=" socket)
                        (copy-sequence process-environment))
                process-environment))
             (name (with-temp-buffer
                     (insert (mapconcat #'car apps "\n"))
                     (when (zerop (call-process-region
                                   (point-min) (point-max)
                                   bemenu t t nil
                                   "-p" (format "tag %d" tag)))
                       (string-trim (buffer-string)))))
             (exec (and name (not (string-empty-p name))
                        (cdr (assoc name apps)))))
        (if exec
            (cmacs-gowl-spawn-in-tag exec tag)
          (message "No application selected"))))))

(defun cmacs-gowl-set-layout (layout)
  "Set the current monitor LAYOUT."
  (interactive
   (list (completing-read "Layout: " cmacs-gowl-layouts nil t)))
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (gowl-set-layout layout))

(defun cmacs-gowl-toggle-vsplit ()
  "Toggle the vsplit tile orientation on the focused monitor.
With vsplit on, the master row is on top and the stack row on the
bottom (the existing window stays on top, new windows underneath);
with it off, the normal left/right split is restored."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (gowl-set-vsplit (not (gowl-get-vsplit)))
  (message "gowl vsplit: %s"
           (if (gowl-get-vsplit) "on (master on top)" "off (master left)")))

(defun cmacs-gowl-list-monitors ()
  "Display information about connected monitors."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((monitors (gowl-list-monitors)))
    (if (null monitors)
        (message "No monitors detected")
      (with-help-window "*Gowl Monitors*"
        (princ (format "Gowl Monitors (%d):\n\n" (length monitors)))
        (princ (format "%-14s %-18s %-10s %-6s %-8s %s\n"
                       "Name" "Mode" "Position" "Scale" "Status" "Transform"))
        (princ (make-string 78 ?-))
        (princ "\n")
        (dolist (m monitors)
          (let* ((info (gowl-monitor-info m))
                 (name (cdr (assq 'name info)))
                 (geo (cdr (assq 'geometry info)))
                 (mode (gowl-monitor-current-mode m))
                 (scale (gowl-monitor-scale m))
                 (enabled (gowl-monitor-enabled-p m))
                 (xform (gowl-monitor-transform m)))
            (princ (format "%-14s %-18s %-10s %-6.1f %-8s %s\n"
                           name
                           (if mode
                               (format "%dx%d@%dHz"
                                       (nth 0 mode) (nth 1 mode)
                                       (/ (nth 2 mode) 1000))
                             "unknown")
                           (format "%d,%d" (nth 0 geo) (nth 1 geo))
                           scale
                           (if enabled "on" "off")
                           xform))))))))

(defun cmacs-gowl--read-monitor (prompt)
  "Read a monitor name with completion using PROMPT."
  (let* ((monitors (gowl-list-monitors))
         (names (mapcar (lambda (m)
                          (cdr (assq 'name (gowl-monitor-info m))))
                        monitors))
         (name (completing-read prompt names nil t)))
    (gowl-find-monitor name)))

(defun cmacs-gowl-monitor-info ()
  "Display detailed info for a selected monitor."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (info (gowl-monitor-info mon)))
    (with-help-window "*Gowl Monitor Info*"
      (dolist (kv info)
        (princ (format "%-15s %S\n" (car kv) (cdr kv)))))))

(defun cmacs-gowl-set-resolution ()
  "Set resolution for a selected monitor from available modes."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (modes (gowl-monitor-modes mon))
         (choices (mapcar (lambda (m)
                            (format "%dx%d@%dHz"
                                    (nth 0 m) (nth 1 m)
                                    (/ (nth 2 m) 1000)))
                          modes))
         (choice (completing-read "Mode: " choices nil t))
         (idx (cl-position choice choices :test #'string=))
         (mode (nth idx modes)))
    (if (gowl-set-monitor-mode (nth 0 mode) (nth 1 mode) (nth 2 mode) mon)
        (message "Mode set to %s" choice)
      (message "Failed to set mode"))))

(defun cmacs-gowl-set-scale (scale)
  "Set SCALE factor for a selected monitor."
  (interactive "nScale factor: ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((mon (cmacs-gowl--read-monitor "Monitor: ")))
    (if (gowl-set-monitor-scale scale mon)
        (message "Scale set to %.1f" scale)
      (message "Failed to set scale"))))

(defun cmacs-gowl-set-transform ()
  "Set transform for a selected monitor."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (transforms '("normal" "90" "180" "270"
                        "flipped" "flipped-90" "flipped-180" "flipped-270"))
         (choice (completing-read "Transform: " transforms nil t))
         (sym (intern choice)))
    (if (gowl-set-monitor-transform sym mon)
        (message "Transform set to %s" choice)
      (message "Failed to set transform"))))

(defun cmacs-gowl-toggle-monitor ()
  "Toggle enable/disable for a selected monitor."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((mon (cmacs-gowl--read-monitor "Monitor: "))
         (enabled (gowl-monitor-enabled-p mon)))
    (if (gowl-set-monitor-enabled (not enabled) mon)
        (message "Monitor %s"
                 (if enabled "disabled" "enabled"))
      (message "Failed to toggle monitor"))))


;;; ── Client embedding ──────────────────────────────────────────────
;;
;; Embeds Wayland clients as xwidget buffer content.  Each embedded
;; client is backed by a gowl-type xwidget whose GtkDrawingArea is
;; managed by the Emacs display engine (XWIDGET_GLYPH).  The C layer
;; reads pixels from the client's wlr_texture on each surface commit
;; and paints them via Cairo.  Mouse and keyboard events on the widget
;; are forwarded to the Wayland client through the compositor's wlr_seat.

(define-derived-mode gowl-embed-mode special-mode "GowlEmbed"
  "Major mode for buffers displaying an embedded Wayland client.
The client renders as an xwidget glyph — real buffer content
managed by the Emacs display engine.

In Evil, pressing \\`i' or \\`a' gives keyboard focus to the
embedded client.  Pressing ESC in the embedded client returns
control to Emacs."
  :group 'cmacs-gowl
  (setq-local cursor-type nil)
  (setq-local mode-line-buffer-identification
              (propertize "%b" 'face 'mode-line-buffer-id))
  (when (boundp 'doom-real-buffer-p)
    (setq-local doom-real-buffer-p t)))

(with-eval-after-load 'evil
  (eval '(evil-define-key 'normal gowl-embed-mode-map
           "i" #'gowl-embed--enter-client
           "a" #'gowl-embed--enter-client
           "A" #'gowl-embed--enter-client
           "I" #'gowl-embed--enter-client
           "o" #'gowl-embed--enter-client
           "O" #'gowl-embed--enter-client
           (kbd "RET") #'gowl-embed--enter-client)))

(defun gowl-embed--enter-client ()
  "Give keyboard focus to the embedded client in the current buffer."
  (interactive)
  (when gowl-embedded-client
    (gowl-embed-focus gowl-embedded-client)))

(defvar-local gowl-embedded-client nil
  "The gowl client embedded in this buffer, or nil.")

(defvar-local gowl-embedded-client-pid nil
  "PID of the embedded client, cached to avoid dereferencing dead objects.")

(defvar-local gowl-embed--xwidget nil
  "The xwidget displaying the embedded client, or nil.")

(defvar gowl-embed--pending nil
  "List of (PID WINDOW BUFFER) for spawned clients awaiting map.")

(defvar gowl-embed--pending-timer nil
  "Timer polling for pending embeds.")

(defvar gowl-embed--health-timer nil
  "Timer checking if embedded clients are still alive.")

(defun gowl-embed--find-emacs-client (exclude)
  "Find the Emacs frame's gowl client (the non-embedded tiled client).
EXCLUDE is the client being embedded — skip it."
  (cl-find-if
   (lambda (c)
     (and (not (eq c exclude))
          (let ((info (gowl-client-info c)))
            (not (cdr (assq 'embedded info))))))
   (gowl-list-clients)))

(defun gowl-embed--frame-offset ()
  "Return the Emacs frame's content origin as (X . Y).
Computes from usable area + gap offset + border width.  This
avoids client geometry lookup which can be unreliable."
  (let* ((area (and (fboundp 'gowl-usable-area) (gowl-usable-area)))
         (gaps (and (fboundp 'gowl-gaps-info) (gowl-gaps-info)))
         (ax (or (nth 0 area) 0))
         (ay (or (nth 1 area) 0))
         (oh (or (cdr (assq 'outer-h gaps)) 0))
         (ov (or (cdr (assq 'outer-v gaps)) 0))
         ;; Border width defaults to 1 for tiled clients
         (bw 1))
    (cons (+ ax oh bw) (+ ay ov bw))))

(defun gowl-embed--do-embed (client window buf)
  "Embed CLIENT into the compositor scene tree, displayed in WINDOW's area.
The client stays on the OVERLAY layer and is positioned at
monitor-absolute coordinates (frame position + window position).
The compositor renders it directly — no xwidget or GTK widget involved."
  (set-window-buffer window buf)
  (with-selected-window window
    (let* ((edges (window-inside-absolute-pixel-edges window))
           (offset (gowl-embed--frame-offset))
           (x (+ (car offset) (nth 0 edges)))
           (y (+ (cdr offset) (nth 1 edges)))
           (w (- (nth 2 edges) (nth 0 edges)))
           (h (- (nth 3 edges) (nth 1 edges))))
      (setq-local gowl-embedded-client client)
      (setq-local gowl-embedded-client-pid (gowl-client-pid client))
      ;; Mark as embedded so arrange() skips it.
      (gowl-set-client-embedded client t)
      (gowl-set-client-border-width client 0)
      ;; Position first, THEN show — avoids a flash at (0,0).
      ;; Client stays on OVERLAY layer (set by map callback).
      (gowl-position-embedded client x y w h)
      (gowl-set-client-visible client t)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (gowl-embed--ensure-health-timer))))

(defun gowl-embed--setup-buffer (buf command)
  "Initialize BUF as an embed buffer for COMMAND."
  (with-current-buffer buf
    (gowl-embed-mode)
    ;; Placeholder until client maps and xwidget is inserted.
    (let ((inhibit-read-only t))
      (insert (propertize (format " Embedding %s…" command)
                          'face 'shadow)))))

(defun gowl-embed--display-buffer (buf window)
  "Display BUF in WINDOW with soft dedication.
Soft dedication (non-t) protects the window from `display-buffer'
hijacking but allows `set-window-buffer' and workspace management
to replace the buffer (clearing the dedication)."
  (set-window-buffer window buf)
  (set-window-dedicated-p window 'gowl-embed)
  (when (bound-and-true-p persp-mode)
    (persp-add-buffer buf)))

(defun gowl-embed--client-has-buffer-p (client)
  "Return non-nil if CLIENT is already owned by an embed buffer."
  (let ((pid (gowl-client-pid client)))
    (cl-some (lambda (buf)
               (let ((buf-pid (buffer-local-value 'gowl-embedded-client-pid buf)))
                 (and buf-pid (= buf-pid pid))))
             (buffer-list))))

(defun gowl-embed--check-pending ()
  "Match pending embeds to newly mapped gowl clients.
First tries PID matching (works for direct processes).  If that
fails, falls back to matching any embedded client that doesn't
have an embed view yet (catches flatpak/sandbox launchers)."
  (if (null gowl-embed--pending)
      (progn
        (when gowl-embed--pending-timer
          (cancel-timer gowl-embed--pending-timer)
          (setq gowl-embed--pending-timer nil)))
    (let ((clients (gowl-list-clients)))
      (dolist (entry (copy-sequence gowl-embed--pending))
        (let* ((pid (nth 0 entry))
               (window (nth 1 entry))
               (command (nth 2 entry))
               ;; Try PID match first.
               (client (seq-find
                        (lambda (c) (= (gowl-client-pid c) pid))
                        clients))
               ;; Fallback: any embedded client not yet owned by a buffer.
               ;; The client-map callback marks it embedded; this
               ;; catches flatpak/sandbox where spawn PID != client PID.
               (client (or client
                          (seq-find
                           (lambda (c)
                             (and (alist-get 'embedded (gowl-client-info c))
                                  (not (gowl-embed--client-has-buffer-p c))))
                           clients))))
          (when client
            (setq gowl-embed--pending (delq entry gowl-embed--pending))
            (when (window-live-p window)
              (let ((buf (generate-new-buffer
                          (format "*gowl: %s*" command))))
                (gowl-embed--setup-buffer buf command)
                (gowl-embed--display-buffer buf window)
                (gowl-embed--do-embed client window buf)))))))))

(defun gowl-embed--start-pending-timer ()
  "Start the timer that checks for pending embeds."
  (unless gowl-embed--pending-timer
    (setq gowl-embed--pending-timer
          (run-with-timer 0.1 0.1 #'gowl-embed--check-pending))))

(defun gowl-embed--check-health ()
  "Kill embed buffers whose clients have exited.
Uses the cached PID to avoid dereferencing dead client objects
whose underlying wlr resources may already be freed."
  (let ((client-pids (when (gowl-running-p)
                       (mapcar #'gowl-client-pid (gowl-list-clients))))
        (has-embeds nil))
    (dolist (buf (buffer-list))
      (when-let* ((pid (buffer-local-value 'gowl-embedded-client-pid buf)))
        (if (memq pid client-pids)
            (setq has-embeds t)
          ;; Client is gone — clean up without touching the dead object.
          (with-current-buffer buf
            (setq gowl-embedded-client nil)
            (setq gowl-embedded-client-pid nil)
            (let ((win (get-buffer-window buf t)))
              (when win (set-window-dedicated-p win nil)))
            (kill-buffer buf)))))
    (unless has-embeds
      (when gowl-embed--health-timer
        (cancel-timer gowl-embed--health-timer)
        (setq gowl-embed--health-timer nil)))))

(defun gowl-embed--ensure-health-timer ()
  "Start the health-check timer if not running."
  (unless gowl-embed--health-timer
    (setq gowl-embed--health-timer
          (run-with-timer 1 1 #'gowl-embed--check-health))))

(defun gowl-embed--on-kill-buffer ()
  "Close the embedded client when its buffer is killed."
  (when gowl-embedded-client
    (let ((win (get-buffer-window (current-buffer) t))
          (client gowl-embedded-client)
          (pid gowl-embedded-client-pid)
          (live-pids (when (gowl-running-p)
                       (mapcar #'gowl-client-pid (gowl-list-clients)))))
      (when win (set-window-dedicated-p win nil))
      ;; Only call gowl functions if the client is still alive.
      (when (and pid (memq pid live-pids))
        (condition-case nil
            (progn
              (gowl-set-client-visible client nil)
              (gowl-close-client client))
          (error nil)))
      (setq gowl-embedded-client nil)
      (setq gowl-embedded-client-pid nil))))

;;;###autoload
(defun cmacs-gowl-embed-release (&optional client)
  "Release CLIENT from its embedded buffer and float it freely.
Clears the compositor's `embedded' flag, reparents the scene
node to the FLOAT layer, re-arranges the layout so neighbouring
tiled clients reclaim space, and centers the released client on
its current monitor at half its monitor's size.

Also detaches the embed bookkeeping on the elisp side: clears
the owning buffer's `gowl-embedded-client' / `-pid' buffer-locals
and removes window dedication so `gowl-embed--adjust-size' stops
tracking it.

CLIENT defaults to the buffer-local `gowl-embedded-client' in the
current buffer, or the focused gowl client if there is none."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((c (or client
               gowl-embedded-client
               (gowl-focused-client))))
    (unless c
      (user-error "No client to release"))
    ;; Detach elisp-side embed state: walk every buffer that
    ;; references this client and clear its bookkeeping.
    (let ((target-pid (gowl-client-pid c)))
      (dolist (buf (buffer-list))
        (when (and (buffer-local-value 'gowl-embedded-client-pid buf)
                   (equal (buffer-local-value 'gowl-embedded-client-pid buf)
                          target-pid))
          (with-current-buffer buf
            (setq gowl-embedded-client nil)
            (setq gowl-embedded-client-pid nil))
          (dolist (win (get-buffer-window-list buf nil t))
            (set-window-dedicated-p win nil)))))
    ;; Compositor-side release: clear isembedded, then set
    ;; floating which reparents to FLOAT and re-arranges.
    (gowl-set-client-embedded c nil)
    (gowl-set-client-floating c t)
    ;; Center the released client on its monitor at half size.
    (let* ((mon-info (gowl-monitor-info))
           (geom (cdr (assq 'geometry mon-info)))
           (mx (nth 0 geom))
           (my (nth 1 geom))
           (mw (nth 2 geom))
           (mh (nth 3 geom))
           (cw (/ mw 2))
           (ch (/ mh 2)))
      (gowl-move-client c
                        (+ mx (/ (- mw cw) 2))
                        (+ my (/ (- mh ch) 2)))
      (gowl-resize-client c cw ch))
    (message "Released embedded client; floating on monitor center")))

(defun gowl-embed--adjust-size (frame)
  "Reposition embedded clients to match their window dimensions in FRAME.
Enforces single-window display first, then positions each embedded
client's scene node at monitor-absolute coordinates (frame offset +
window position)."
  (gowl-embed--enforce-single-window)
  (let ((offset (gowl-embed--frame-offset)))
    (walk-windows
     (lambda (win)
       (when-let* ((client (buffer-local-value 'gowl-embedded-client
                                                (window-buffer win))))
         (let* ((edges (window-inside-absolute-pixel-edges win))
                (x (+ (car offset) (nth 0 edges)))
                (y (+ (cdr offset) (nth 1 edges)))
                (w (- (nth 2 edges) (nth 0 edges)))
                (h (- (nth 3 edges) (nth 1 edges))))
           (if (and (> w 0) (> h 0))
               (progn
                 (gowl-set-client-visible client t)
                 (gowl-position-embedded client x y w h))
             (gowl-set-client-visible client nil)))))
     'no-minibuf frame)))

(defun gowl-embed--manage-dedication (&rest _)
  "Manage soft dedication for gowl-embed windows.
Re-establish soft dedication when a gowl-embed buffer is displayed
in a window without it (e.g. after workspace restore clears it).
This runs on `window-configuration-change-hook'."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'gowl-embedded-client buf)
      (let ((win (get-buffer-window buf t)))
        (when (and win (not (window-dedicated-p win)))
          (set-window-dedicated-p win 'gowl-embed))))))

(defun gowl-embed--enforce-single-window (&rest _)
  "Ensure each gowl-embed buffer is displayed in at most one window.
When a split duplicates a gowl-embed buffer, switch the extra
window to the previous buffer."
  (let ((seen (make-hash-table :test #'eq)))
    (walk-windows
     (lambda (win)
       (let ((buf (window-buffer win)))
         (when (buffer-local-value 'gowl-embedded-client buf)
           (if (gethash buf seen)
               ;; Duplicate — switch this window away.
               (switch-to-prev-buffer win)
             (puthash buf t seen)))))
     'no-minibuf)))

(defun gowl-embed--on-buffer-change (&rest _)
  "Show/hide embedded clients based on buffer visibility.
When a buffer with an embedded client is displayed in a window,
position the client at that window's monitor-absolute coordinates
(frame offset + window position).  When the buffer is no longer
visible, hide the client's scene node."
  (let ((offset (gowl-embed--frame-offset)))
    (dolist (buf (buffer-list))
      (when-let* ((client (buffer-local-value 'gowl-embedded-client buf)))
        (let ((win (get-buffer-window buf t)))
          (if win
              (let* ((edges (window-inside-absolute-pixel-edges win))
                     (x (+ (car offset) (nth 0 edges)))
                     (y (+ (cdr offset) (nth 1 edges)))
                     (w (- (nth 2 edges) (nth 0 edges)))
                     (h (- (nth 3 edges) (nth 1 edges))))
                (when (and (> w 0) (> h 0))
                  (gowl-set-client-visible client t)
                  (gowl-position-embedded client x y w h)))
            (gowl-set-client-visible client nil)))))))

(add-hook 'kill-buffer-hook #'gowl-embed--on-kill-buffer)
(add-hook 'window-size-change-functions #'gowl-embed--adjust-size)
(add-hook 'window-configuration-change-hook #'gowl-embed--manage-dedication)
(add-hook 'window-configuration-change-hook #'gowl-embed--enforce-single-window)
(add-hook 'window-buffer-change-functions #'gowl-embed--on-buffer-change)
(add-hook 'window-selection-change-functions #'gowl-embed--on-buffer-change)

(defun gowl-embed--prepare-command (command)
  "Prepare COMMAND for Wayland embedding.
Injects --socket=wayland and toolkit env vars into flatpak run
commands so the sandboxed app can connect to gowl's Wayland socket."
  (if (string-match "\\bflatpak run\\b" command)
      (replace-regexp-in-string
       "\\(flatpak run\\)"
       (concat "\\1 --socket=wayland"
               " --env=ELECTRON_OZONE_PLATFORM_HINT=auto"
               " --env=GDK_BACKEND=wayland"
               " --env=QT_QPA_PLATFORM=wayland"
               " --env=MOZ_ENABLE_WAYLAND=1")
       command nil nil)
    command))

;;;###autoload
(defun gowl-embed (command)
  "Spawn COMMAND and embed it in the current window via the compositor.
The client's scene node is reparented into Emacs's scene tree and
positioned at the window's pixel coordinates.  The surface resizes
with the window and hides/shows with buffer switching."
  (interactive "sEmbed: ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((command (gowl-embed--prepare-command command))
         (pid (gowl-spawn command))
         (win (selected-window)))
    (gowl-prefloat-pid pid)
    (gowl-embed-expect-client)
    (push (list pid win command) gowl-embed--pending)
    (gowl-embed--start-pending-timer)
    (message "Spawning %s…" command)))

(defun gowl-embed--read-desktop-file (file)
  "Parse FILE and return (NAME . EXEC) or nil if not a GUI app."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((name nil) (exec nil) (type nil) (terminal nil) (nodisplay nil))
      (goto-char (point-min))
      (when (re-search-forward "^\\[Desktop Entry\\]" nil t)
        (forward-line)
        (while (and (not (eobp))
                    (not (looking-at "^\\[")))
          (cond
           ((looking-at "^Name=\\(.+\\)") (setq name (match-string 1)))
           ((looking-at "^Exec=\\(.+\\)") (setq exec (match-string 1)))
           ((looking-at "^Type=\\(.+\\)") (setq type (match-string 1)))
           ((looking-at "^Terminal=true") (setq terminal t))
           ((looking-at "^NoDisplay=true") (setq nodisplay t)))
          (forward-line)))
      (when (and name exec
                 (equal type "Application")
                 (not terminal) (not nodisplay))
        (cons name (replace-regexp-in-string " *%[fFuUdDnNickvm]" "" exec))))))

(defun gowl-embed--list-apps ()
  "Return alist of (NAME . EXEC) from XDG .desktop files."
  (let ((dirs (mapcar (lambda (d) (expand-file-name "applications" d))
                      (cons (xdg-data-home) (xdg-data-dirs))))
        (seen (make-hash-table :test #'equal))
        apps)
    (dolist (dir dirs)
      (when (file-directory-p dir)
        (dolist (file (directory-files dir t "\\.desktop\\'"))
          (unless (gethash (file-name-nondirectory file) seen)
            (puthash (file-name-nondirectory file) t seen)
            (when-let* ((app (gowl-embed--read-desktop-file file)))
              (push app apps))))))
    (sort apps (lambda (a b) (string< (car a) (car b))))))

;;;###autoload
(defun gowl-embed-app ()
  "Select a GUI application from installed .desktop files and embed it."
  (interactive)
  (let* ((apps (gowl-embed--list-apps))
         (name (completing-read "Embed app: " (mapcar #'car apps) nil t))
         (exec (cdr (assoc name apps))))
    (unless exec (user-error "App not found: %s" name))
    (gowl-embed exec)))

;;;###autoload
(defun gowl-embed-client (client)
  "Embed an existing gowl CLIENT in the current Emacs window."
  (interactive
   (list (let* ((clients (gowl-list-clients))
                (candidates
                 (mapcar (lambda (c)
                           (let ((info (gowl-client-info c)))
                             (cons (format "%s — %s"
                                           (cdr (assq 'title info))
                                           (cdr (assq 'app-id info)))
                                   c)))
                         clients))
                (choice (completing-read "Embed client: " candidates nil t)))
           (cdr (assoc choice candidates)))))
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let* ((info (gowl-client-info client))
         (title (or (cdr (assq 'title info)) "client"))
         (buf (generate-new-buffer (format "*gowl: %s*" title)))
         (win (selected-window)))
    (gowl-embed--setup-buffer buf title)
    (gowl-embed--display-buffer buf win)
    (gowl-embed--do-embed client win buf)))

(defun gowl-unembed ()
  "Release the embedded client from the current buffer."
  (interactive)
  (when-let* ((client gowl-embedded-client))
    (setq gowl-embedded-client nil)
    (setq gowl-embedded-client-pid nil)
    (set-window-dedicated-p (selected-window) nil)
    (gowl-set-client-embedded client nil)
    (gowl-set-client-border-width client 1)
    ;; Move back to TILE layer (index 2) for normal tiling.
    (gowl-reparent-client client 2)
    (gowl-set-client-visible client t)
    (gowl-arrange)
    (kill-buffer (current-buffer))))

;;; Signal convenience wrappers

(defvar cmacs-gowl--signal-handles nil
  "Alist of (HANDLE . DESCRIPTION) for active signal connections.")

(defun cmacs-gowl-on-focus-changed (callback)
  "Connect CALLBACK to the compositor's \"focus-changed\" signal.
CALLBACK is called with one argument, the newly focused client
GObject (or nil when focus is cleared).
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let ((handle (gobject-connect (gowl-compositor)
                                 "focus-changed" callback)))
    (push (cons handle "focus-changed") cmacs-gowl--signal-handles)
    handle))

(defun cmacs-gowl-on-client-added (callback)
  "Connect CALLBACK to the compositor's \"client-added\" signal.
CALLBACK is called with one argument, the new client GObject.
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let ((handle (gobject-connect (gowl-compositor)
                                 "client-added" callback)))
    (push (cons handle "client-added") cmacs-gowl--signal-handles)
    handle))

(defun cmacs-gowl-on-client-removed (callback)
  "Connect CALLBACK to the compositor's \"client-removed\" signal.
CALLBACK is called with one argument, the departing client GObject.
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let ((handle (gobject-connect (gowl-compositor)
                                 "client-removed" callback)))
    (push (cons handle "client-removed") cmacs-gowl--signal-handles)
    handle))

(defun cmacs-gowl-on-tag-changed (callback &optional monitor)
  "Connect CALLBACK to a monitor's \"tag-changed\" signal.
CALLBACK is called with no arguments when the viewed tags change.
MONITOR is a GowlMonitor object or nil for the focused monitor.
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let* ((mon (or monitor (gowl-focused-monitor)))
         (handle (gobject-connect mon "tag-changed" callback)))
    (push (cons handle "tag-changed") cmacs-gowl--signal-handles)
    handle))

(defun cmacs-gowl-on-layout-changed (callback &optional monitor)
  "Connect CALLBACK to a monitor's \"layout-changed\" signal.
CALLBACK is called with no arguments when the layout changes.
MONITOR is a GowlMonitor object or nil for the focused monitor.
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let* ((mon (or monitor (gowl-focused-monitor)))
         (handle (gobject-connect mon "layout-changed" callback)))
    (push (cons handle "layout-changed") cmacs-gowl--signal-handles)
    handle))

(defun cmacs-gowl-on-idle (callback)
  "Connect CALLBACK to the idle manager's \"idle\" signal.
CALLBACK is called with no arguments when the idle timeout elapses.
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let ((mgr (gowl-idle-manager)))
    (when mgr
      (let ((handle (gobject-connect mgr "idle" callback)))
        (push (cons handle "idle") cmacs-gowl--signal-handles)
        handle))))

(defun cmacs-gowl-on-resume (callback)
  "Connect CALLBACK to the idle manager's \"resume\" signal.
CALLBACK is called with no arguments when input resumes after idle.
Returns a handle for `cmacs-gowl-signal-disconnect'."
  (let ((mgr (gowl-idle-manager)))
    (when mgr
      (let ((handle (gobject-connect mgr "resume" callback)))
        (push (cons handle "resume") cmacs-gowl--signal-handles)
        handle))))

(defun cmacs-gowl-signal-disconnect (handle)
  "Disconnect a signal connection identified by HANDLE.
HANDLE is a value previously returned by one of the
`cmacs-gowl-on-*' functions."
  (when handle
    (gobject-disconnect handle)
    (setq cmacs-gowl--signal-handles
          (assq-delete-all handle cmacs-gowl--signal-handles))))


;;; Interactive commands

(defun cmacs-gowl-zoom ()
  "Promote the focused client to master position."
  (interactive)
  (gowl-zoom-client nil))

(defun cmacs-gowl-swap-master ()
  "Swap the focused client with the master client."
  (interactive)
  (let* ((focused (gowl-focused-client))
         (clients (gowl-list-clients))
         (master (car clients)))
    (when (and focused master (not (eq focused master)))
      (gowl-swap-clients focused master))))

(defun cmacs-gowl-set-repeat (rate delay)
  "Set keyboard repeat RATE (keys/sec) and DELAY (ms)."
  (interactive "nRepeat rate (keys/sec): \nnRepeat delay (ms): ")
  (gowl-set-keyboard-repeat-rate rate)
  (gowl-set-keyboard-repeat-delay delay))

(defun cmacs-gowl-kill-ring-sync ()
  "Push the top of the Emacs kill ring to the Wayland clipboard.
This uses the IPC event channel to notify external clipboard tools."
  (interactive)
  (when (car kill-ring)
    (gowl-ipc-push-event
     (format "EVENT clipboard %s" (car kill-ring)))))

;;; Bar title sync — keeps the compositor bar in sync with the
;;; active Emacs buffer or embedded client.

(defvar cmacs-gowl-bar--last-title nil
  "Last title sent to the bar, to avoid redundant updates.")

(defun cmacs-gowl-bar--update-title ()
  "Update the compositor bar title to reflect the current context.
Shows the embedded client title if one is active, otherwise the
current buffer name."
  (when (and (bound-and-true-p IS-GOWL)
             (fboundp 'gowl-bar-set-title))
    (let ((title (if (and (boundp 'gowl-embedded-client)
                          (buffer-local-value 'gowl-embedded-client
                                              (current-buffer)))
                     ;; Embedded client — show its title
                     (let ((info (gowl-client-info
                                  (buffer-local-value
                                   'gowl-embedded-client
                                   (current-buffer)))))
                       (or (cdr (assq 'title info)) (buffer-name)))
                   ;; Normal buffer
                   (buffer-name))))
      (unless (equal title cmacs-gowl-bar--last-title)
        (setq cmacs-gowl-bar--last-title title)
        (gowl-bar-set-title title)))))

(defun cmacs-gowl-bar-sync-enable ()
  "Enable automatic bar title sync with Emacs buffer changes."
  (add-hook 'window-buffer-change-functions
            (lambda (_frame) (cmacs-gowl-bar--update-title)))
  (add-hook 'window-selection-change-functions
            (lambda (_frame) (cmacs-gowl-bar--update-title)))
  ;; Initial update
  (cmacs-gowl-bar--update-title))

;;; Multi-bar helpers — route a config alist to a specific slot.
;;; Both wrappers prepend a ("position" . "top"|"bottom") entry to
;;; ALIST and hand it to `gowl-bar-configure', which dispatches on
;;; the position key inside the bar module.

(defun cmacs-gowl-bar-configure-top (alist)
  "Configure the top gowl bar with ALIST (an alist of string pairs).
Equivalent to `gowl-bar-configure' with `(\"position\" . \"top\")'
prepended; useful as a symmetric counterpart to
`cmacs-gowl-bar-configure-bottom'."
  (gowl-bar-configure (cons '("position" . "top") alist)))

(defun cmacs-gowl-bar-configure-bottom (alist)
  "Configure the bottom gowl bar with ALIST (an alist of string pairs).
The bottom slot stays dormant until it has been configured at
least once, so this is how you make a second bar appear."
  (gowl-bar-configure (cons '("position" . "bottom") alist)))


;;; ─── Rounded Corners ───────────────────────────────────────────────

(defun cmacs-gowl-set-corner-radius (radius)
  "Set the corner radius for rounded window borders.
Requires the roundcorners module to be enabled."
  (interactive "nCorner radius (pixels): ")
  (gowl-set-corner-radius radius))


;;; ─── Clipboard Sync (Wayland ↔ kill-ring) ──────────────────────────

(defvar cmacs-gowl--clipboard-last nil
  "Last clipboard text pushed from Wayland, for deduplication.")

(defun cmacs-gowl--on-clipboard-changed (text)
  "Called from C when a Wayland client changes the clipboard.
Pushes TEXT to the kill-ring if it differs from the last known value."
  (when (and text (not (string-empty-p text))
              (not (equal text cmacs-gowl--clipboard-last))
              (not (equal text (car kill-ring))))
    (setq cmacs-gowl--clipboard-last text)
    (kill-new text)))

(defun cmacs-gowl--interprogram-cut (text)
  "Cut function for `interprogram-cut-function'.
Sends TEXT to the Wayland clipboard."
  (when (and (fboundp 'gowl-clipboard-set) (gowl-running-p))
    (setq cmacs-gowl--clipboard-last text)
    (gowl-clipboard-set text)))

(defun cmacs-gowl--interprogram-paste ()
  "Paste function for `interprogram-paste-function'.
Returns the Wayland clipboard text if it differs from the kill-ring top."
  (when (and (fboundp 'gowl-clipboard-get) (gowl-running-p))
    (let ((text (gowl-clipboard-get)))
      (when (and text (not (string-empty-p text))
                 (not (equal text (car kill-ring))))
        (setq cmacs-gowl--clipboard-last text)
        text))))

;;;###autoload
(define-minor-mode cmacs-gowl-clipboard-sync-mode
  "Bidirectional clipboard sync between Wayland and Emacs kill-ring.

When enabled:
- Text copied by Wayland clients is pushed to the kill-ring.
- Text killed in Emacs is placed on the Wayland clipboard.
- `interprogram-cut-function' and `interprogram-paste-function'
  are set to route through the gowl compositor."
  :global t
  :lighter " GowlClip"
  :group 'cmacs-gowl
  (if cmacs-gowl-clipboard-sync-mode
      (progn
        (when (and (fboundp 'gowl-clipboard-watch) (gowl-running-p))
          (gowl-clipboard-watch))
        (setq interprogram-cut-function   #'cmacs-gowl--interprogram-cut
              interprogram-paste-function  #'cmacs-gowl--interprogram-paste))
    (when (fboundp 'gowl-clipboard-unwatch)
      (gowl-clipboard-unwatch))
    (setq interprogram-cut-function   nil
          interprogram-paste-function nil)))


;;; ─── Screenshot & Recording ────────────────────────────────────────

(defcustom cmacs-gowl-screenshot-directory
  (expand-file-name "Screenshots"
                    (or (getenv "XDG_PICTURES_DIR")
                        (expand-file-name "Pictures" "~")))
  "Default directory for screenshots."
  :type 'directory :group 'cmacs-gowl)

(defcustom cmacs-gowl-recording-directory
  (expand-file-name "Recordings"
                    (or (getenv "XDG_VIDEOS_DIR")
                        (expand-file-name "Videos" "~")))
  "Default directory for screen recordings."
  :type 'directory :group 'cmacs-gowl)

(defvar gowl-screenshot-done-hook nil
  "Hook run after an async screenshot completes.
Each function receives the saved file path as its argument.")

(defun cmacs-gowl-screenshot-desktop ()
  "Screenshot the current monitor."
  (interactive)
  (let ((path (gowl-screenshot 'desktop)))
    (when path (message "Screenshot saved: %s" path))
    path))

(defun cmacs-gowl-screenshot-window ()
  "Screenshot the focused window."
  (interactive)
  (let ((path (gowl-screenshot 'window)))
    (when path (message "Screenshot saved: %s" path))
    path))

(defun cmacs-gowl-screenshot-all ()
  "Screenshot all monitors stitched together."
  (interactive)
  (let ((path (gowl-screenshot 'all)))
    (when path (message "Screenshot saved: %s" path))
    path))

(defun cmacs-gowl-record-toggle ()
  "Start or stop screen recording."
  (interactive)
  (if (and (fboundp 'gowl-recording-p) (gowl-recording-p))
      (let ((path (gowl-record-stop)))
        (message "Recording saved: %s" path))
    (let ((path (gowl-record-start 'desktop)))
      (message "Recording started: %s" path))))

(defun cmacs-gowl-record-start (&optional mode path)
  "Start recording.  MODE defaults to `desktop'."
  (interactive (list (intern (completing-read "Mode: "
                               '("desktop" "window" "all")
                               nil t nil nil "desktop"))))
  (let ((result (gowl-record-start (or mode 'desktop) path)))
    (when result (message "Recording started: %s" result))
    result))

(defun cmacs-gowl-record-stop ()
  "Stop the current recording."
  (interactive)
  (let ((path (gowl-record-stop)))
    (if path
        (message "Recording saved: %s" path)
      (message "No recording in progress"))
    path))

;;; Interactive commands for window rules and dropdowns

(defun cmacs-gowl-toggle-float ()
  "Toggle the floating state of the currently focused client."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (unless (gowl-float-toggle)
    (message "No focused client")))

;;; Module keybind testing — synthesize key events from elisp

;; These constants mirror the GOWL_KEY_MOD_* bits in gowl-enums.h,
;; which are the same bits wlroots reports for keyboard modifier
;; state.  Combine with logior.
(defconst cmacs-gowl-mod-shift 1)
(defconst cmacs-gowl-mod-caps  2)
(defconst cmacs-gowl-mod-ctrl  4)
(defconst cmacs-gowl-mod-alt   8)
(defconst cmacs-gowl-mod-mod2  16)
(defconst cmacs-gowl-mod-mod3  32)
(defconst cmacs-gowl-mod-super 64)
(defconst cmacs-gowl-mod-mod5  128)

;; A handful of XKB keysym constants that are awkward to spell as
;; raw hex.  Full list lives in /usr/include/xkbcommon/xkbcommon-keysyms.h.
(defconst cmacs-gowl-key-grave #x0060)   ; `
(defconst cmacs-gowl-key-space #x0020)   ; space
(defconst cmacs-gowl-key-left  #xFF51)
(defconst cmacs-gowl-key-right #xFF53)
(defconst cmacs-gowl-key-up    #xFF52)
(defconst cmacs-gowl-key-down  #xFF54)
(defconst cmacs-gowl-key-F10   #xFFC7)
(defconst cmacs-gowl-key-F11   #xFFC8)
(defconst cmacs-gowl-key-F12   #xFFC9)

;;;###autoload
(defun cmacs-gowl-test-dropdown (&optional name)
  "Test-trigger a dropdown by NAME without using a real keybind.
If NAME is nil, toggles the first entry in `cmacs-gowl-dropdowns'
(usually \"term\").  Dispatches through the same code path as a
real key event — goes through the dropdown module's
toggle_by_name implementation, which spawns the command on first
call and toggles visibility on subsequent calls."
  (interactive "sDropdown name (empty = first): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((target (or name
                    (plist-get (car cmacs-gowl-dropdowns) :name)
                    "term")))
    (if (gowl-dropdown-toggle target)
        (message "Dropdown %s toggled" target)
      (message "Dropdown %s not found" target))))

;;;###autoload
(defun cmacs-gowl-test-float-toggle ()
  "Test-trigger the windowrules float-toggle action on the focused
client.  Goes through `gowl-float-toggle' directly (bypassing the
keybind layer) so the test works even if no modifier keybind is
registered."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (if (gowl-float-toggle)
      (message "Floating toggled on focused client")
    (message "No focused client")))

;;;###autoload
(defun cmacs-gowl-test-synth-key (modifiers keysym)
  "Synthesise a module keybind dispatch for MODIFIERS and KEYSYM.
MODIFIERS is an integer bitmask built from
`cmacs-gowl-mod-super', `cmacs-gowl-mod-shift', etc.
KEYSYM is an XKB keysym integer.  Returns t if any module
consumed the event.

Example — simulate pressing Super+grave (the default dropdown
keybind) without touching the keyboard:

  (cmacs-gowl-test-synth-key cmacs-gowl-mod-super cmacs-gowl-key-grave)"
  (interactive "nModifiers (integer bitmask): \nnKeysym (integer): ")
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (let ((consumed (gowl-module-dispatch-key modifiers keysym)))
    (message "synth dispatch mods=%d key=0x%X consumed=%s"
             modifiers keysym consumed)
    consumed))

(defun cmacs-gowl-dropdown-toggle (name)
  "Toggle the dropdown named NAME.
Interactively prompts using the names from `cmacs-gowl-dropdowns'
and any entries currently registered in the running gowl config."
  (interactive
   (let ((names (delete-dups
                  (append
                    (mapcar (lambda (dd) (plist-get dd :name))
                            cmacs-gowl-dropdowns)
                    (and (gowl-running-p)
                         (mapcar (lambda (e)
                                   (cdr (assq 'name e)))
                                 (gowl-list-dropdowns)))))))
     (list (completing-read "Dropdown: " (delq nil names) nil t))))
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (unless (gowl-dropdown-toggle name)
    (message "Dropdown %s not found" name)))

(defun cmacs-gowl-reapply-float-rules ()
  "Push `cmacs-gowl-float-rules' into the running gowl config.
Use after editing the defcustom at runtime to re-sync the rule
set without restarting `cmacs-gowl-mode'."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (cmacs-gowl--apply-float-rules)
  (message "Applied %d float rules" (length cmacs-gowl-float-rules)))

(defun cmacs-gowl-reapply-dropdowns ()
  "Push `cmacs-gowl-dropdowns' into the running gowl config.
Use after editing the defcustom at runtime.  Calls
`gowl-dropdown-refresh' so the dropdown module picks up new
entries without a mode cycle."
  (interactive)
  (unless (gowl-running-p)
    (user-error "Gowl compositor is not running"))
  (cmacs-gowl--apply-dropdowns)
  (when (fboundp 'gowl-dropdown-refresh)
    (ignore-errors (gowl-dropdown-refresh)))
  (message "Applied %d dropdowns" (length cmacs-gowl-dropdowns)))

(provide 'cmacs-gowl)
;;; cmacs-gowl.el ends here
