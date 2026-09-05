;;; cmacs-gowl-media.el --- Volume, brightness and media keys under gowl  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; What the XF86 keys on a laptop do under `emacs --gowl'.
;;
;; A compositor keybind can only name one of gowl's built-in actions or
;; spawn a subprocess, so the obvious way to bind volume up is
;; `(bind "XF86AudioRaiseVolume" 'spawn "pamixer -i 5")'.  That works
;; and gives no feedback: the volume moves and nothing on screen says
;; so, which is exactly the thing an OSD exists for.
;;
;; gowl's `custom' action hands its argument to the embedder instead,
;; and cmacs evaluates that argument as Elisp.  So these commands are
;; what the media keys actually run, and they can show the new level in
;; the echo area on the way past.
;;
;; The backends are the usual ones: wpctl (which ships with
;; wireplumber, so it is present wherever pipewire is), brightnessctl,
;; and playerctl.  Each is a defcustom; nothing here assumes a
;; particular one beyond the output it parses, and a missing binary
;; reports itself once rather than failing silently on every keypress.
;;
;; Every call is asynchronous.  Under --gowl the Emacs main loop is
;; also the compositor's, so a synchronous `call-process' would stall
;; every client's frame callbacks for the duration -- brief for wpctl,
;; not brief for a brightnessctl on a slow i2c bus.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-gowl-media nil
  "Volume, brightness and media-player control for the gowl session."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-media-")

;;; Backends

(defcustom cmacs-gowl-media-volume-program "wpctl"
  "Program used to read and set the audio volume.
The default, wpctl, is part of wireplumber and so is present on any
pipewire system.  `cmacs-gowl-media--volume-args' and
`cmacs-gowl-media--parse-volume' assume its command line and output;
pointing this at pamixer or amixer means adjusting those too."
  :type 'string
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-brightness-program "brightnessctl"
  "Program used to read and set display brightness."
  :type 'string
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-player-program "playerctl"
  "Program used to control MPRIS media players."
  :type 'string
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-volume-step 5
  "Percentage points a single volume key press moves the sink."
  :type 'integer
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-brightness-step 5
  "Percentage points a single brightness key press moves the backlight."
  :type 'integer
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-volume-max 1.0
  "Ceiling passed to wpctl as its -l limit, as a fraction of 100%.
The default keeps a held key from driving the sink into software
amplification, which distorts and is hard to notice happening.  Set
above 1.0 deliberately if you want the headroom."
  :type 'float
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-osd t
  "When non-nil, show the new level in the echo area after a change.
See `cmacs-gowl-media-osd-function' to render it elsewhere."
  :type 'boolean
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-osd-width 20
  "Number of cells in the echo-area level bar."
  :type 'integer
  :group 'cmacs-gowl-media)

(defcustom cmacs-gowl-media-osd-function #'cmacs-gowl-media-osd-echo
  "Function called to display an OSD.
Receives (LABEL VALUE TEXT): LABEL is a short string such as
\"Volume\", VALUE is a float in 0.0-1.0 or nil when the quantity has no
level (a track change, say), and TEXT is the already-rendered line
that `cmacs-gowl-media-osd-echo' would show.

Replace this to route the OSD somewhere other than the echo area --- a
gowl layer surface, a posframe, or `cmacs-notify' once a notification
daemon is running."
  :type 'function
  :group 'cmacs-gowl-media)

;;; Process plumbing

(defvar cmacs-gowl-media--missing nil
  "Programs already reported missing, so each is only warned about once.")

(defun cmacs-gowl-media--available-p (program)
  "Return non-nil when PROGRAM is on `exec-path'.
Warns once per program otherwise: a media key that does nothing is
worth one message, not one per press."
  (or (executable-find program)
      (progn
        (unless (member program cmacs-gowl-media--missing)
          (push program cmacs-gowl-media--missing)
          (message "cmacs-gowl-media: %s is not installed" program))
        nil)))

(defun cmacs-gowl-media--run (program args &optional callback)
  "Run PROGRAM with ARGS asynchronously.
CALLBACK, when given, is called with the process's standard output as
a string once it exits successfully; a non-zero exit calls it with
nil.  Returns the process, or nil when PROGRAM is not installed.

Asynchronous on purpose: under --gowl this runs on the compositor's
own main loop."
  (when (cmacs-gowl-media--available-p program)
    (let ((buf (generate-new-buffer " *cmacs-gowl-media*")))
      (make-process
       :name "cmacs-gowl-media"
       :buffer buf
       :command (cons program args)
       :noquery t
       :connection-type 'pipe
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let ((ok (and (eq (process-status proc) 'exit)
                          (zerop (process-exit-status proc))))
                 (out (with-current-buffer buf (buffer-string))))
             (kill-buffer buf)
             (when callback
               (funcall callback (and ok out))))))))))

;;; OSD

(defun cmacs-gowl-media-osd-echo (_label _value text)
  "Show TEXT in the echo area.  The default `cmacs-gowl-media-osd-function'."
  (let ((message-log-max nil))          ; an OSD does not belong in *Messages*
    (message "%s" text)))

(defun cmacs-gowl-media--osd (label value &optional suffix)
  "Render an OSD for LABEL at VALUE, a float in 0.0-1.0 or nil.
SUFFIX is appended after the bar, for a state such as \"muted\"."
  (when cmacs-gowl-media-osd
    (let* ((text
            (if (null value)
                (if suffix (format "%s: %s" label suffix) label)
              (let* ((width cmacs-gowl-media-osd-width)
                     ;; Clamp for the bar only: a value above 1.0 is
                     ;; real (amplification) and the number still shows
                     ;; it, but it must not overrun the bar's width.
                     (filled (max 0 (min width (round (* width value))))))
                (format "%s %s%s %3d%%%s"
                        label
                        (make-string filled ?█)
                        (make-string (- width filled) ?░)
                        (round (* 100 value))
                        (if suffix (concat " " suffix) ""))))))
      (funcall cmacs-gowl-media-osd-function label value text))))

;;; Volume

(defconst cmacs-gowl-media-sink "@DEFAULT_AUDIO_SINK@"
  "wpctl node specifier for the default output.")

(defconst cmacs-gowl-media-source "@DEFAULT_AUDIO_SOURCE@"
  "wpctl node specifier for the default input.")

(defun cmacs-gowl-media--parse-volume (output)
  "Parse wpctl get-volume OUTPUT into (VOLUME . MUTED).
OUTPUT looks like \"Volume: 0.65\" or \"Volume: 0.65 [MUTED]\".
Returns nil when it does not."
  (when (and output (string-match "Volume:[ \t]*\\([0-9.]+\\)" output))
    (cons (string-to-number (match-string 1 output))
          ;; Read the flag from OUTPUT, not from the match data, which
          ;; the string-to-number above has not touched but the next
          ;; string-match would.
          (and (string-match-p "\\[MUTED\\]" output) t))))

(defun cmacs-gowl-media--show-volume (&optional node label)
  "Read the volume of NODE and show it as an OSD under LABEL."
  (let ((node (or node cmacs-gowl-media-sink))
        (label (or label "Volume")))
    (cmacs-gowl-media--run
     cmacs-gowl-media-volume-program
     (list "get-volume" node)
     (lambda (out)
       (let ((parsed (cmacs-gowl-media--parse-volume out)))
         (if parsed
             (cmacs-gowl-media--osd label (car parsed)
                                    (and (cdr parsed) "muted"))
           ;; The set succeeded but the read did not parse; say
           ;; something rather than leaving the key looking dead.
           (cmacs-gowl-media--osd label nil "changed")))))))

(defun cmacs-gowl-media--adjust-volume (delta)
  "Move the default sink by DELTA percentage points, then show an OSD."
  (cmacs-gowl-media--run
   cmacs-gowl-media-volume-program
   (append
    (list "set-volume")
    ;; -l caps the result; wpctl only accepts it on an increase.
    (when (> delta 0)
      (list "-l" (number-to-string cmacs-gowl-media-volume-max)))
    (list cmacs-gowl-media-sink
          (format "%d%%%s" (abs delta) (if (> delta 0) "+" "-"))))
   (lambda (_out) (cmacs-gowl-media--show-volume))))

;;;###autoload
(defun cmacs-gowl-volume-raise (&optional step)
  "Raise the default sink's volume by STEP points.
STEP defaults to `cmacs-gowl-media-volume-step'."
  (interactive)
  (cmacs-gowl-media--adjust-volume (or step cmacs-gowl-media-volume-step)))

;;;###autoload
(defun cmacs-gowl-volume-lower (&optional step)
  "Lower the default sink's volume by STEP points.
STEP defaults to `cmacs-gowl-media-volume-step'."
  (interactive)
  (cmacs-gowl-media--adjust-volume
   (- (or step cmacs-gowl-media-volume-step))))

;;;###autoload
(defun cmacs-gowl-volume-mute-toggle ()
  "Toggle mute on the default audio output."
  (interactive)
  (cmacs-gowl-media--run
   cmacs-gowl-media-volume-program
   (list "set-mute" cmacs-gowl-media-sink "toggle")
   (lambda (_out) (cmacs-gowl-media--show-volume))))

;;;###autoload
(defun cmacs-gowl-mic-mute-toggle ()
  "Toggle mute on the default audio input."
  (interactive)
  (cmacs-gowl-media--run
   cmacs-gowl-media-volume-program
   (list "set-mute" cmacs-gowl-media-source "toggle")
   (lambda (_out)
     (cmacs-gowl-media--show-volume cmacs-gowl-media-source "Microphone"))))

;;; Brightness

(defun cmacs-gowl-media--parse-brightness (output)
  "Parse brightnessctl -m OUTPUT into a float in 0.0-1.0, or nil.
The machine-readable form is
\"device,class,current,percent%,max\"."
  (when output
    (let ((fields (split-string (string-trim output) "," t)))
      (when (>= (length fields) 5)
        (let ((cur (string-to-number (nth 2 fields)))
              (max (string-to-number (nth 4 fields))))
          (and (> max 0) (/ (float cur) max)))))))

(defun cmacs-gowl-media--adjust-brightness (delta)
  "Move the backlight by DELTA percentage points, then show an OSD.
Uses brightnessctl's -m form so the resulting level comes back on the
same invocation --- there is no second read to race with a key held
down."
  (cmacs-gowl-media--run
   cmacs-gowl-media-brightness-program
   (list "-m" "set" (format "%d%%%s" (abs delta) (if (> delta 0) "+" "-")))
   (lambda (out)
     (let ((value (cmacs-gowl-media--parse-brightness out)))
       (if value
           (cmacs-gowl-media--osd "Brightness" value)
         (cmacs-gowl-media--osd "Brightness" nil "changed"))))))

;;;###autoload
(defun cmacs-gowl-brightness-up (&optional step)
  "Raise display brightness by STEP points.
STEP defaults to `cmacs-gowl-media-brightness-step'."
  (interactive)
  (cmacs-gowl-media--adjust-brightness
   (or step cmacs-gowl-media-brightness-step)))

;;;###autoload
(defun cmacs-gowl-brightness-down (&optional step)
  "Lower display brightness by STEP points.
STEP defaults to `cmacs-gowl-media-brightness-step'."
  (interactive)
  (cmacs-gowl-media--adjust-brightness
   (- (or step cmacs-gowl-media-brightness-step))))

;;; Media players

(defun cmacs-gowl-media--player (command label)
  "Send COMMAND to playerctl, then show LABEL and the current track."
  (cmacs-gowl-media--run
   cmacs-gowl-media-player-program
   (list command)
   (lambda (ok)
     (if (not ok)
         ;; playerctl exits non-zero when no player is running, which
         ;; is a normal thing to press a media key into.
         (cmacs-gowl-media--osd label nil "no player")
       (cmacs-gowl-media--run
        cmacs-gowl-media-player-program
        (list "metadata" "--format" "{{artist}} - {{title}}")
        (lambda (meta)
          (cmacs-gowl-media--osd
           label nil
           (if (and meta (not (string-empty-p (string-trim meta))))
               (string-trim meta)
             "--"))))))))

;;;###autoload
(defun cmacs-gowl-media-play-pause ()
  "Toggle play/pause on the active MPRIS player."
  (interactive)
  (cmacs-gowl-media--player "play-pause" "Play/pause"))

;;;###autoload
(defun cmacs-gowl-media-next ()
  "Skip to the next track on the active MPRIS player."
  (interactive)
  (cmacs-gowl-media--player "next" "Next"))

;;;###autoload
(defun cmacs-gowl-media-previous ()
  "Go to the previous track on the active MPRIS player."
  (interactive)
  (cmacs-gowl-media--player "previous" "Previous"))

;;;###autoload
(defun cmacs-gowl-media-stop ()
  "Stop the active MPRIS player."
  (interactive)
  (cmacs-gowl-media--player "stop" "Stop"))

;;; The bind table

(defconst cmacs-gowl-media-keybinds
  '(("XF86AudioRaiseVolume"  cmacs-gowl-volume-raise      "Volume up")
    ("XF86AudioLowerVolume"  cmacs-gowl-volume-lower      "Volume down")
    ("XF86AudioMute"         cmacs-gowl-volume-mute-toggle "Mute output")
    ("XF86AudioMicMute"      cmacs-gowl-mic-mute-toggle   "Mute microphone")
    ("XF86MonBrightnessUp"   cmacs-gowl-brightness-up     "Brightness up")
    ("XF86MonBrightnessDown" cmacs-gowl-brightness-down   "Brightness down")
    ("XF86AudioPlay"         cmacs-gowl-media-play-pause  "Play / pause")
    ("XF86AudioNext"         cmacs-gowl-media-next        "Next track")
    ("XF86AudioPrev"         cmacs-gowl-media-previous    "Previous track")
    ("XF86AudioStop"         cmacs-gowl-media-stop        "Stop playback"))
  "Media keys installed by `cmacs-gowl-media-install-keybinds'.
Each entry is (KEY COMMAND DESCRIPTION).  The keys carry no modifier,
which the compositor handles like any other bind: dispatch compares a
cleaned modifier mask and zero matches zero.")

(defun cmacs-gowl-media-install-keybinds ()
  "Bind the XF86 media keys to the commands in this file.
Each is registered as gowl's `custom' action carrying the command as
an Elisp form, so it runs in Emacs --- and can show an OSD --- rather
than spawning a process that changes the volume silently.

Any existing bind for the same key is removed first: gowl dispatches
the first matching entry, so a stale duplicate from an earlier load
would shadow the new one."
  (dolist (entry cmacs-gowl-media-keybinds)
    (let ((key (nth 0 entry))
          (command (nth 1 entry))
          (desc (nth 2 entry)))
      (ignore-errors (gowl-remove-keybind key))
      (ignore-errors
        (gowl-add-keybind key 'custom (format "(%s)" command) desc)))))

(provide 'cmacs-gowl-media)

;;; cmacs-gowl-media.el ends here
