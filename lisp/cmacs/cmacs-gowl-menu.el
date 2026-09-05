;;; cmacs-gowl-menu.el --- The gowl session's control surface  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A gowl session has a compositor and no way to drive the machine
;; around it: no power menu, no network picker, no audio-output
;; chooser.  Omarchy solves this with a Quickshell panel stack plus
;; `omarchy-menu.jsonc' -- a tree of entries with bash guards, rendered
;; by QML.
;;
;; The tree is the good idea; QML is the wrong half to copy here.  A
;; menu is a list of choices, and Emacs has had the best list-of-choices
;; widget on the machine for forty years.  So this is the same
;; data-driven tree, rendered by `completing-read', with its guards
;; evaluated in-process as Elisp rather than forked as one bash process
;; per open.
;;
;; What that buys beyond parity: the menu works identically in a GUI
;; frame, in a terminal, over `emacsclient -nw' from another machine,
;; and under `emacs --lrg'; it composes with whatever completion
;; framework is already configured; and adding an entry is a line in
;; `init.el' rather than a QML plugin.
;;
;; Bound to Super+Escape by default, through gowl's `custom' keybind
;; action -- so the compositor key runs Elisp instead of spawning a
;; process.  Opening the menu blocks Emacs's main loop while it waits
;; for a choice, but *not* the compositor: under --gowl the compositor
;; runs on its own thread, so the desktop keeps compositing and other
;; clients keep animating with the menu open.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-gowl-menu nil
  "The gowl session's control surface."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-menu-")

;;; Running backend commands

(defcustom cmacs-gowl-menu-terminal "gst"
  "Terminal used to host a TUI a menu entry launches."
  :type 'string
  :group 'cmacs-gowl-menu)

(defun cmacs-gowl-menu--run (program &rest args)
  "Run PROGRAM with ARGS asynchronously, discarding output.
Asynchronous because several of these (systemctl, nmcli) can block for
seconds, and the menu should be gone by then."
  (when (executable-find program)
    (make-process :name (concat "cmacs-gowl-menu-" program)
                  :command (cons program args)
                  :noquery t
                  :buffer nil)))

(defun cmacs-gowl-menu--output (program &rest args)
  "Run PROGRAM with ARGS and return its standard output as a string.
Synchronous, so only for the short queries that populate a submenu --
listing wifi networks, audio sinks, bluetooth devices.  Returns nil
when PROGRAM is absent or exits non-zero."
  (when (executable-find program)
    (with-temp-buffer
      (let ((status (apply #'call-process program nil t nil args)))
        (and (eq status 0) (buffer-string))))))

(defun cmacs-gowl-menu--in-terminal (&rest command)
  "Launch COMMAND inside `cmacs-gowl-menu-terminal'.
The escape hatch for anything whose full interface is a TUI: rather
than reimplement nmtui or bluetoothctl badly, offer the real thing."
  (when (fboundp 'cmacs-gowl-spawn-command-or-error)
    (ignore-errors (cmacs-gowl-spawn-command-or-error)))
  (apply #'cmacs-gowl-menu--run cmacs-gowl-menu-terminal "-e" command))

;;; Power

(defcustom cmacs-gowl-menu-confirm-destructive t
  "When non-nil, confirm before reboot, power off and logging out.
These end the session and every unsaved buffer with it, and a menu is
exactly the interface where a mis-click reaches them."
  :type 'boolean
  :group 'cmacs-gowl-menu)

(defun cmacs-gowl-menu--confirm (action)
  "Return non-nil when ACTION should proceed."
  (or (not cmacs-gowl-menu-confirm-destructive)
      (yes-or-no-p (format "%s: are you sure? " action))))

(defun cmacs-gowl-menu-lock ()
  "Lock the session."
  (interactive)
  (if (fboundp 'gowl-lock)
      (gowl-lock)
    (cmacs-gowl-menu--run "loginctl" "lock-session")))

(defun cmacs-gowl-menu-suspend ()
  "Suspend to RAM."
  (interactive)
  (cmacs-gowl-menu--run "systemctl" "suspend"))

(defun cmacs-gowl-menu-hibernate ()
  "Hibernate to disk."
  (interactive)
  (cmacs-gowl-menu--run "systemctl" "hibernate"))

(defun cmacs-gowl-menu-reboot ()
  "Reboot the machine, after confirmation."
  (interactive)
  (when (cmacs-gowl-menu--confirm "Reboot")
    (cmacs-gowl-menu--run "systemctl" "reboot")))

(defun cmacs-gowl-menu-poweroff ()
  "Power the machine off, after confirmation."
  (interactive)
  (when (cmacs-gowl-menu--confirm "Power off")
    (cmacs-gowl-menu--run "systemctl" "poweroff")))

(defun cmacs-gowl-menu-logout ()
  "End the session, after confirmation.
Under `--gowl' the compositor is this Emacs, so this is
`save-buffers-kill-emacs' -- which is the honest thing to call, since
it is what actually happens."
  (interactive)
  (when (cmacs-gowl-menu--confirm "Log out")
    (save-buffers-kill-emacs)))

;;; Audio

(defconst cmacs-gowl-menu--wpctl-tree-chars "[ \t\u2502\u251c\u2514\u2500]*"
  "Leading box-drawing and whitespace in a `wpctl status' line.
wpctl draws its output as a tree, so every node line begins with some
mixture of vertical bars, tees, elbows and dashes before the data.")

(defun cmacs-gowl-menu--wpctl-nodes (kind)
  "Return a list of (LABEL . ID) audio nodes of KIND (\"Sinks\"/\"Sources\").

Parses `wpctl status', which is a drawn tree rather than a table:

  Audio
   ├─ Sinks:
   │      93. USB Audio Analog Stereo       [vol: 1.00]
   │  *   95. Schiit Modi 3E Analog Stereo  [vol: 1.00]

so a line has to be stripped of its box-drawing prefix before anything
can be matched against it, and the leading star marking the default
sits between that prefix and the id.

Both Audio and Video have a `Sources:' section --- microphones in one,
webcams in the other --- so the top-level section is tracked too, and
only Audio's nodes are returned."
  (let ((out (cmacs-gowl-menu--output "wpctl" "status"))
        (top nil) (section nil) (nodes nil))
    (when out
      (dolist (line (split-string out "\n"))
        (cond
         ;; A top-level section is flush left: "Audio", "Video".
         ((string-match "\\`\\([A-Z][A-Za-z]*\\)[ \t]*\\'" line)
          (setq top (match-string 1 line) section nil))
         (t
          (let ((body (replace-regexp-in-string
                       (concat "\\`" cmacs-gowl-menu--wpctl-tree-chars) ""
                       line)))
            (cond
             ((string-match "\\`\\([A-Za-z ]+\\):[ \t]*\\'" body)
              (setq section (match-string 1 body)))
             ((string-match
               "\\`\\(\\*?\\)[ \t]*\\([0-9]+\\)\\. +\\(.*?\\)[ \t]*\\(\\[vol.*\\)?\\'"
               body)
              (when (and (equal top "Audio") (equal section kind))
                (let ((default (equal (match-string 1 body) "*"))
                      (id (match-string 2 body))
                      (name (string-trim (match-string 3 body))))
                  (unless (string-empty-p name)
                    (push (cons (concat (if default "* " "  ") name) id)
                          nodes)))))))))))
    (nreverse nodes)))

(defun cmacs-gowl-menu-audio-output ()
  "Choose the default audio output."
  (interactive)
  (let ((nodes (cmacs-gowl-menu--wpctl-nodes "Sinks")))
    (unless nodes (user-error "No audio sinks found"))
    (let* ((choice (completing-read "Output: " (mapcar #'car nodes) nil t))
           (id (cdr (assoc choice nodes))))
      (cmacs-gowl-menu--run "wpctl" "set-default" id)
      (message "Default output: %s" (string-trim choice)))))

(defun cmacs-gowl-menu-audio-input ()
  "Choose the default audio input."
  (interactive)
  (let ((nodes (cmacs-gowl-menu--wpctl-nodes "Sources")))
    (unless nodes (user-error "No audio sources found"))
    (let* ((choice (completing-read "Input: " (mapcar #'car nodes) nil t))
           (id (cdr (assoc choice nodes))))
      (cmacs-gowl-menu--run "wpctl" "set-default" id)
      (message "Default input: %s" (string-trim choice)))))

;;; Network

(defun cmacs-gowl-menu--nmcli-rows (fields &rest args)
  "Run nmcli with terse output over FIELDS plus ARGS, returning rows.
Each row is a list of field values.  Terse mode escapes a literal
colon as \\:, so the split has to respect that or an SSID containing a
colon would come back as two fields."
  (let ((out (apply #'cmacs-gowl-menu--output
                    "nmcli" "-t" "-f" fields args)))
    (when out
      (cl-remove-if
       #'null
       (mapcar (lambda (line)
                 (unless (string-empty-p line)
                   (let ((parts nil) (cur "") (i 0) (n (length line)))
                     (while (< i n)
                       (let ((ch (aref line i)))
                         (cond
                          ((and (eq ch ?\\) (< (1+ i) n))
                           (setq cur (concat cur (string (aref line (1+ i)))))
                           (setq i (1+ i)))
                          ((eq ch ?:) (push cur parts) (setq cur ""))
                          (t (setq cur (concat cur (string ch))))))
                       (setq i (1+ i)))
                     (push cur parts)
                     (nreverse parts))))
               (split-string out "\n"))))))

(defun cmacs-gowl-menu-wifi-connect ()
  "Pick a visible wifi network and connect to it.
Networks needing a password that NetworkManager does not already hold
are handed to nmtui, which knows how to ask."
  (interactive)
  (let* ((rows (cmacs-gowl-menu--nmcli-rows
                "IN-USE,SSID,SIGNAL,SECURITY" "device" "wifi" "list"))
         (entries (cl-remove-if
                   (lambda (r) (string-empty-p (or (nth 1 r) "")))
                   rows)))
    (unless entries (user-error "No wifi networks visible"))
    (let* ((labels (mapcar (lambda (r)
                             (format "%s %-28s %3s%%  %s"
                                     (if (equal (nth 0 r) "*") "*" " ")
                                     (nth 1 r) (or (nth 2 r) "?")
                                     (or (nth 3 r) "")))
                           entries))
           (choice (completing-read "Wifi: " labels nil t))
           (ssid (nth 1 (nth (cl-position choice labels :test #'equal)
                             entries))))
      (message "Connecting to %s..." ssid)
      (let ((proc (cmacs-gowl-menu--run "nmcli" "device" "wifi"
                                        "connect" ssid)))
        (when proc
          (set-process-sentinel
           proc
           (lambda (p _e)
             (when (memq (process-status p) '(exit signal))
               (if (zerop (process-exit-status p))
                   (message "Connected to %s" ssid)
                 ;; The usual cause is a password NetworkManager does
                 ;; not have.  nmtui can ask for one; this cannot.
                 (message "Could not connect to %s -- opening nmtui" ssid)
                 (cmacs-gowl-menu--in-terminal "nmtui-connect"))))))))))

(defun cmacs-gowl-menu-network-toggle-wifi ()
  "Toggle the wifi radio."
  (interactive)
  (let* ((state (string-trim (or (cmacs-gowl-menu--output
                                  "nmcli" "radio" "wifi") "")))
         (on (equal state "enabled")))
    (cmacs-gowl-menu--run "nmcli" "radio" "wifi" (if on "off" "on"))
    (message "Wifi %s" (if on "off" "on"))))

(defun cmacs-gowl-menu-network-status ()
  "Show NetworkManager device status."
  (interactive)
  (let ((out (cmacs-gowl-menu--output "nmcli" "device" "status")))
    (if out
        (with-current-buffer (get-buffer-create "*network status*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert out))
          (goto-char (point-min))
          (special-mode)
          (display-buffer (current-buffer)))
      (user-error "nmcli returned nothing"))))

;;; Bluetooth

(defun cmacs-gowl-menu--bt-devices ()
  "Return a list of (LABEL . MAC) known bluetooth devices."
  (let ((out (cmacs-gowl-menu--output "bluetoothctl" "devices")))
    (when out
      (cl-remove-if
       #'null
       (mapcar (lambda (line)
                 (when (string-match "^Device \\([0-9A-F:]+\\) \\(.*\\)$" line)
                   (cons (format "%-24s %s" (match-string 2 line)
                                 (match-string 1 line))
                         (match-string 1 line))))
               (split-string out "\n"))))))

(defun cmacs-gowl-menu-bluetooth-connect ()
  "Connect to a known bluetooth device."
  (interactive)
  (let ((devices (cmacs-gowl-menu--bt-devices)))
    (unless devices (user-error "No known bluetooth devices"))
    (let* ((choice (completing-read "Connect: " (mapcar #'car devices) nil t))
           (mac (cdr (assoc choice devices))))
      (message "Connecting to %s..." (string-trim choice))
      (cmacs-gowl-menu--run "bluetoothctl" "connect" mac))))

(defun cmacs-gowl-menu-bluetooth-disconnect ()
  "Disconnect a bluetooth device."
  (interactive)
  (let ((devices (cmacs-gowl-menu--bt-devices)))
    (unless devices (user-error "No known bluetooth devices"))
    (let* ((choice (completing-read "Disconnect: " (mapcar #'car devices) nil t))
           (mac (cdr (assoc choice devices))))
      (cmacs-gowl-menu--run "bluetoothctl" "disconnect" mac))))

(defun cmacs-gowl-menu-bluetooth-toggle ()
  "Toggle the bluetooth radio."
  (interactive)
  (let* ((out (or (cmacs-gowl-menu--output "bluetoothctl" "show") ""))
         (on (string-match-p "Powered: yes" out)))
    (cmacs-gowl-menu--run "bluetoothctl" "power" (if on "off" "on"))
    (message "Bluetooth %s" (if on "off" "on"))))

;;; The tree

(defcustom cmacs-gowl-menu-tree
  '(("Applications"
     :items (("Launcher"      :call cmacs-gowl-menu--launcher)
             ("Run command"   :call cmacs-gowl-menu--runner)
             ("Terminal"      :call cmacs-gowl-menu--terminal)))
    ("Audio"
     :when (executable-find "wpctl")
     :items (("Output device"  :call cmacs-gowl-menu-audio-output)
             ("Input device"   :call cmacs-gowl-menu-audio-input)
             ("Volume up"      :call cmacs-gowl-volume-raise)
             ("Volume down"    :call cmacs-gowl-volume-lower)
             ("Mute output"    :call cmacs-gowl-volume-mute-toggle)
             ("Mute microphone" :call cmacs-gowl-mic-mute-toggle)))
    ("Network"
     :when (executable-find "nmcli")
     :items (("Wifi networks"  :call cmacs-gowl-menu-wifi-connect)
             ("Toggle wifi"    :call cmacs-gowl-menu-network-toggle-wifi)
             ("Status"         :call cmacs-gowl-menu-network-status)
             ("Editor (nmtui)" :call cmacs-gowl-menu--nmtui)))
    ("Bluetooth"
     :when (executable-find "bluetoothctl")
     :items (("Connect"        :call cmacs-gowl-menu-bluetooth-connect)
             ("Disconnect"     :call cmacs-gowl-menu-bluetooth-disconnect)
             ("Toggle radio"   :call cmacs-gowl-menu-bluetooth-toggle)))
    ("Display"
     :items (("Brightness up"   :call cmacs-gowl-brightness-up)
             ("Brightness down" :call cmacs-gowl-brightness-down)
             ("Monitors"        :call cmacs-gowl-menu--monitors)))
    ("Compositor"
     :when (and (fboundp 'gowl-running-p) (gowl-running-p))
     :items (("Keybind cheatsheet" :call cmacs-gowl-describe-keybinds)
             ("Reload config"      :call gowl-reload-config)
             ("Tile layout"        :call (lambda () (gowl-set-layout "tile")))
             ("Float layout"       :call (lambda () (gowl-set-layout "float")))
             ("Monocle layout"     :call (lambda () (gowl-set-layout "monocle")))))
    ("Power"
     :items (("Lock"      :call cmacs-gowl-menu-lock)
             ("Suspend"   :call cmacs-gowl-menu-suspend)
             ("Hibernate" :call cmacs-gowl-menu-hibernate
              :when (cmacs-gowl-menu--can-hibernate-p))
             ("Log out"   :call cmacs-gowl-menu-logout)
             ("Reboot"    :call cmacs-gowl-menu-reboot)
             ("Power off" :call cmacs-gowl-menu-poweroff))))
  "The control-surface menu, as data.

A list of (LABEL . PLIST).  A group carries `:items', itself a list of
the same shape, so groups nest to any depth.  A leaf carries `:call',
either a command symbol or a function.

`:when' is an Elisp form evaluated when the menu is built; an entry
whose form returns nil is not shown.  That is how a machine without
bluetooth simply has no Bluetooth group rather than a group whose every
item errors.  Guards run in-process --- Omarchy forks a bash process
per menu open to evaluate the equivalent.

Add to this from `init.el' like any other defcustom; nothing here is
privileged over what you add."
  :type 'sexp
  :group 'cmacs-gowl-menu)

(defun cmacs-gowl-menu--can-hibernate-p ()
  "Return non-nil when the system claims it can hibernate.
Offering an entry that answers \"Not enough swap space\" is worse than
not offering it."
  (let ((out (cmacs-gowl-menu--output "systemctl" "hibernate" "--dry-run")))
    (and out t)))

(defun cmacs-gowl-menu--launcher ()
  "Run the configured application launcher."
  (interactive)
  (if (and (boundp 'cmacs-gowl-menu-command) cmacs-gowl-menu-command
           (fboundp 'cmacs-gowl-spawn))
      (cmacs-gowl-spawn cmacs-gowl-menu-command)
    (cmacs-gowl-menu--run "wofi" "--show" "drun")))

(defun cmacs-gowl-menu--runner ()
  "Run the configured run-command dialog."
  (interactive)
  (if (and (boundp 'cmacs-gowl-run-command) cmacs-gowl-run-command
           (fboundp 'cmacs-gowl-spawn))
      (cmacs-gowl-spawn cmacs-gowl-run-command)
    (cmacs-gowl-menu--run "wofi" "--show" "run")))

(defun cmacs-gowl-menu--terminal ()
  "Launch a terminal."
  (interactive)
  (cmacs-gowl-menu--run cmacs-gowl-menu-terminal))

(defun cmacs-gowl-menu--nmtui ()
  "Open nmtui in a terminal."
  (interactive)
  (cmacs-gowl-menu--in-terminal "nmtui"))

(defun cmacs-gowl-menu--monitors ()
  "Show the compositor's monitor list."
  (interactive)
  (unless (fboundp 'gowl-list-monitors)
    (user-error "Gowl is not available"))
  (with-current-buffer (get-buffer-create "*gowl monitors*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dolist (m (gowl-list-monitors))
        (insert (format "%S\n\n" m))))
    (goto-char (point-min))
    (special-mode)
    (display-buffer (current-buffer))))

;;; Rendering

(defun cmacs-gowl-menu--visible-p (entry)
  "Return non-nil when ENTRY's `:when' guard passes.
A guard that signals is treated as a failed guard rather than being
allowed to abort the whole menu: one broken entry should cost itself,
not the control surface."
  ;; plist-member, not plist-get: an entry written `:when nil' to
  ;; disable it must stay hidden, and plist-get cannot tell that from
  ;; an entry with no :when at all.
  (let ((cell (plist-member (cdr entry) :when)))
    (or (null cell)
        (condition-case err
            (and (eval (cadr cell) t) t)
          (error
           (message "cmacs-gowl-menu: guard for %S failed: %s"
                    (car entry) (error-message-string err))
           nil)))))

(defun cmacs-gowl-menu--level (entries breadcrumb)
  "Present ENTRIES, a menu level, under BREADCRUMB."
  (let* ((visible (cl-remove-if-not #'cmacs-gowl-menu--visible-p entries))
         (labels (mapcar (lambda (e)
                           (if (plist-get (cdr e) :items)
                               (concat (car e) " >")
                             (car e)))
                         visible)))
    (unless visible
      (user-error "Nothing available in %s" breadcrumb))
    (let* ((choice (completing-read (concat breadcrumb ": ") labels nil t))
           (idx (cl-position choice labels :test #'equal))
           (entry (nth idx visible))
           (items (plist-get (cdr entry) :items))
           (call (plist-get (cdr entry) :call)))
      (cond
       (items (cmacs-gowl-menu--level
               items (concat breadcrumb " / " (car entry))))
       ((functionp call) (call-interactively call))
       ((and call (symbolp call) (fboundp call)) (call-interactively call))
       (call (eval call t))
       (t (user-error "Menu entry %S does nothing" (car entry)))))))

;;;###autoload
(defun cmacs-gowl-menu ()
  "Open the gowl control surface.

A tree of power, audio, network, bluetooth, display and compositor
actions, rendered with `completing-read' so it works in a GUI frame, a
terminal, over `emacsclient -nw', and under `emacs --lrg' alike.

Entries come from `cmacs-gowl-menu-tree', which is a defcustom: adding
one is a line in `init.el'."
  (interactive)
  (cmacs-gowl-menu--level cmacs-gowl-menu-tree "Menu"))

(provide 'cmacs-gowl-menu)

;;; cmacs-gowl-menu.el ends here
