;;; cmacs-gowl-power.el --- Window effects follow the power profile -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The animated window backdrops (rain, storm, snow, water, ...) never
;; settle: while a translucent window is on a screen, that screen is
;; rendering at the backdrop's frame rate.  On a laptop that is the
;; difference between a day of battery and an afternoon.  The CRT pass
;; is the same story for the whole screen.
;;
;; `cmacs-gowl-power-saver-mode' watches the system power profile --
;; power-profiles-daemon, or tuned-ppd, which serves the same
;; `net.hadess.PowerProfiles' interface -- and while it is `power-saver'
;; it holds the window effects off: the backdrop goes to `none' and the
;; tube off, and a bar toast says so.  Leaving power saver puts back
;; exactly what was showing before.
;;
;; Both ways in are covered by the same signal: a profile already set
;; to power-saver when the session starts (the GDM greeter, a previous
;; session), and one changed afterwards from anywhere -- the bar's power
;; panel, `powerprofilesctl', GNOME settings.  The bar's panel changes
;; the profile through the daemon, so it needs no hook of its own here.
;;
;; The user's own choice is never touched: `cmacs-gowl-backdrop' and
;; `cmacs-gowl-crt' keep saying what they want, and this is an override
;; applied on top of them.  If somebody picks a backdrop by hand while
;; power saver is holding (Super+"), that is an explicit choice, and
;; leaving power saver does not take it away again.
;;
;; Enabled by `cmacs-gowl-mode' when `cmacs-gowl-power-saver-effects' is
;; non-nil, which is the default.  Set it to nil in your config to keep
;; the effects on whatever the profile says.

;;; Code:

(require 'cl-lib)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-backdrop "cmacs-gowl.c" ())
(declare-function gowl-set-backdrop "cmacs-gowl.c" (style))
(declare-function gowl-crt-p "cmacs-gowl.c" ())
(declare-function gowl-set-crt "cmacs-gowl.c" (on))
(declare-function gowl-bar-notify "cmacs-gowl.c" (summary &optional body panel))
(declare-function dbus-get-property "dbus"
                  (bus service path interface property))
(declare-function dbus-register-signal "dbus"
                  (bus service path interface signal handler &rest args))
(declare-function dbus-unregister-object "dbus" (object))

(defvar dbus-interface-properties)

(defgroup cmacs-gowl-power nil
  "Window effects that follow the system power profile."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-power-")

(defcustom cmacs-gowl-power-saver-effects t
  "When non-nil, hold the window effects off while in power saver.

The window backdrop goes to `none' and the CRT pass off whenever the
system power profile is one of `cmacs-gowl-power-saver-profiles' --
already at login, or changed later from the bar's power panel or
anywhere else -- and both come back as they were when the profile
leaves power saver.

The animated backdrops render continuously while a translucent window
is on screen, which on a laptop costs hours of battery; this is the
default for that reason.  Set it to nil to keep the effects on in every
profile.  It is read when `cmacs-gowl-mode' starts; at runtime, toggle
`cmacs-gowl-power-saver-mode' instead."
  :type 'boolean
  :group 'cmacs-gowl-power)

(defcustom cmacs-gowl-power-saver-profiles '("power-saver")
  "Power profiles in which the window effects are held off.

Names as power-profiles-daemon reports them: \"power-saver\",
\"balanced\" and \"performance\".  Adding \"balanced\" keeps the
effects for `performance' only."
  :type '(repeat string)
  :group 'cmacs-gowl-power)

(defcustom cmacs-gowl-power-saver-toast t
  "When non-nil, say on the bar when power saver changes the effects."
  :type 'boolean
  :group 'cmacs-gowl-power)

(defconst cmacs-gowl-power--services
  '(("net.hadess.PowerProfiles"
     "/net/hadess/PowerProfiles"
     "net.hadess.PowerProfiles")
    ("org.freedesktop.UPower.PowerProfiles"
     "/org/freedesktop/UPower/PowerProfiles"
     "org.freedesktop.UPower.PowerProfiles"))
  "Where the active power profile is published, as (SERVICE PATH IFACE).
The first is power-profiles-daemon's historical name and the one tuned-ppd
serves; the second is the name power-profiles-daemon 0.20 added.  A
daemon offering both sends both signals for one change, which is harmless:
a profile that has not changed is ignored.")

(defvar cmacs-gowl-power--profile nil
  "The power profile last seen, or nil before the first answer.")

(defvar cmacs-gowl-power--held nil
  "What to put back when power saver ends, or nil when not holding.
A cons (BACKDROP . CRT): the backdrop symbol and whether the tube was on.")

(defvar cmacs-gowl-power--signals nil
  "D-Bus registrations made by `cmacs-gowl-power-saver-mode'.")

(defvar cmacs-gowl-power--toast-delay 2
  "Seconds to wait before a toast sent while the session is starting.
A toast sent before the bar has drawn its first frame is lost.")

;;; Reading the profile

(defun cmacs-gowl-power--read-profile ()
  "Return the active power profile as a string, or nil when none answers.
`dbus-get-property' carries its own short timeout and swallows errors,
so a machine without a profile daemon costs one failed call per name."
  (when (and (featurep 'dbusbind) (require 'dbus nil t))
    (cl-loop for (service path iface) in cmacs-gowl-power--services
             for value = (dbus-get-property :system service path iface
                                            "ActiveProfile")
             when (stringp value) return value)))

(defun cmacs-gowl-power--changed-profile (changed)
  "Return the ActiveProfile carried in a PropertiesChanged CHANGED list.
D-Bus hands an a{sv} over as ((NAME (VALUE)) ...); the variant arrives
as a one-element list, but a bare VALUE is accepted too."
  (let ((value (cadr (assoc "ActiveProfile" changed))))
    (if (consp value) (car value) value)))

(defun cmacs-gowl-power--on-properties-changed (iface changed invalidated)
  "Handle PropertiesChanged for IFACE with CHANGED and INVALIDATED.
Registered for every entry of `cmacs-gowl-power--services'."
  (when (member iface (mapcar #'caddr cmacs-gowl-power--services))
    (let ((profile (cmacs-gowl-power--changed-profile changed)))
      ;; A property may also be announced as merely invalidated, which
      ;; says it changed without saying to what: ask.
      (when (and (null profile) (member "ActiveProfile" invalidated))
        (setq profile (cmacs-gowl-power--read-profile)))
      (when (stringp profile)
        (cmacs-gowl-power--update profile)))))

;;; The live compositor

(defun cmacs-gowl-power--live-p ()
  "Return non-nil when there is a running compositor to talk to."
  (and (fboundp 'gowl-running-p) (gowl-running-p)
       (fboundp 'gowl-set-backdrop)))

(defun cmacs-gowl-power--live-state ()
  "Return the effects showing now, as (BACKDROP . CRT)."
  (cons (or (ignore-errors (gowl-backdrop)) 'none)
        (and (fboundp 'gowl-crt-p) (ignore-errors (gowl-crt-p)) t)))

(defun cmacs-gowl-power--dark-p (state)
  "Return non-nil when STATE, a (BACKDROP . CRT), draws no effect."
  (and (eq (car state) 'none) (not (cdr state))))

(defun cmacs-gowl-power--toast (summary body &optional later)
  "Show SUMMARY and BODY on the bar, after a delay when LATER.
Silent when toasts are off or the bar cannot take one: the effects
changing is the point, the toast is only the explanation."
  (when (and cmacs-gowl-power-saver-toast (fboundp 'gowl-bar-notify))
    (let ((send (lambda ()
                  (when (cmacs-gowl-power--live-p)
                    (ignore-errors (gowl-bar-notify summary body "power"))))))
      (if later
          (run-at-time cmacs-gowl-power--toast-delay nil send)
        (funcall send)))))

;;; Holding and releasing

(defun cmacs-gowl-power-holding-p ()
  "Return non-nil while power saver is holding the window effects off."
  (and cmacs-gowl-power--held t))

(defun cmacs-gowl-power--hold (backdrop crt &optional announce later)
  "Remember BACKDROP and CRT as what to restore, and switch them off.
A toast is shown when ANNOUNCE is non-nil and something was actually
showing; LATER defers it, for a session that is still starting."
  (let ((state (cons backdrop (and crt t))))
    (setq cmacs-gowl-power--held state)
    (when (and (cmacs-gowl-power--live-p)
               (not (cmacs-gowl-power--dark-p state)))
      ;; Backdrop first: leaving the `crt' stop of the tour takes the
      ;; tube down with it, and a tube switched on by hand needs its
      ;; own switch.
      (ignore-errors (gowl-set-backdrop 'none))
      (when (fboundp 'gowl-set-crt)
        (ignore-errors (gowl-set-crt nil)))
      (when announce
        (cmacs-gowl-power--toast
         "Power saver: window effects off"
         (format "%s paused to save battery; back when power saver ends"
                 (if (eq backdrop 'none) "CRT" backdrop))
         later)))))

(defun cmacs-gowl-power--release (&optional announce)
  "Stop holding, and put back what was showing before power saver.
Nothing is put back when somebody chose an effect by hand meanwhile:
the live compositor not being dark any more is that choice.  ANNOUNCE
shows a toast when something is restored."
  (let ((saved cmacs-gowl-power--held))
    (setq cmacs-gowl-power--held nil)
    (when (and saved
               (not (cmacs-gowl-power--dark-p saved))
               (cmacs-gowl-power--live-p)
               (cmacs-gowl-power--dark-p (cmacs-gowl-power--live-state)))
      ;; Backdrop first: landing on `crt' switches the tube on itself,
      ;; and a hand-set tube beside another backdrop needs its switch.
      (ignore-errors (gowl-set-backdrop (car saved)))
      (when (and (cdr saved) (fboundp 'gowl-set-crt))
        (ignore-errors (gowl-set-crt t)))
      (when announce
        (cmacs-gowl-power--toast "Window effects restored"
                                 (format "Left power saver: %s is back"
                                         (car saved)))))))

(defun cmacs-gowl-power--saver-p (profile)
  "Return non-nil when PROFILE is one that holds the effects off."
  (and (stringp profile)
       (member profile cmacs-gowl-power-saver-profiles)
       t))

(defun cmacs-gowl-power--update (profile)
  "Act on the power profile becoming PROFILE.
A profile equal to the last one seen does nothing, which is what makes a
daemon that announces one change on two interfaces harmless."
  (unless (equal profile cmacs-gowl-power--profile)
    (setq cmacs-gowl-power--profile profile)
    (cond
     ((and (cmacs-gowl-power--saver-p profile)
           (not (cmacs-gowl-power-holding-p))
           (cmacs-gowl-power--live-p))
      (let ((state (cmacs-gowl-power--live-state)))
        (cmacs-gowl-power--hold (car state) (cdr state) t)))
     ((and (not (cmacs-gowl-power--saver-p profile))
           (cmacs-gowl-power-holding-p))
      (cmacs-gowl-power--release t)))))

(defun cmacs-gowl-power-apply (backdrop crt)
  "Apply BACKDROP and CRT unless power saver is holding the effects.
Return non-nil when they were held instead of applied.  This is the
door `cmacs-gowl-mode' pushes the user's choice through at start, so a
session that begins in power saver never draws a frame of rain: the
choice is remembered for later and nothing is switched on."
  (when (cmacs-gowl-power-holding-p)
    (cmacs-gowl-power--hold backdrop crt t t)
    t))

;;; The mode

(defun cmacs-gowl-power--register ()
  "Listen for profile changes on every name in the services table."
  (when (and (featurep 'dbusbind) (require 'dbus nil t))
    (dolist (entry cmacs-gowl-power--services)
      (condition-case nil
          ;; SERVICE nil: `dbus-register-signal' would otherwise pin the
          ;; daemon's unique name at registration, and a restarted daemon
          ;; (or one activated after this ran) would go unheard.  The
          ;; path and the interface check in the handler are enough.
          (push (dbus-register-signal
                 :system nil (nth 1 entry) dbus-interface-properties
                 "PropertiesChanged"
                 #'cmacs-gowl-power--on-properties-changed)
                cmacs-gowl-power--signals)
        (error nil)))))

(defun cmacs-gowl-power--unregister ()
  "Drop every registration `cmacs-gowl-power--register' made."
  (dolist (object cmacs-gowl-power--signals)
    (ignore-errors (dbus-unregister-object object)))
  (setq cmacs-gowl-power--signals nil))

;;;###autoload
(define-minor-mode cmacs-gowl-power-saver-mode
  "Hold the gowl window effects off while the system is in power saver.

While the power profile is one of `cmacs-gowl-power-saver-profiles',
the window backdrop is set to `none' and the CRT pass switched off, with
a toast on the bar saying so; when the profile changes back, they are
restored to what they were.  A profile that is already power saver when
this is enabled counts, which covers one chosen at the login screen.

Turning the mode off releases any hold.  `cmacs-gowl-mode' enables this
at start when `cmacs-gowl-power-saver-effects' is non-nil."
  :global t
  :group 'cmacs-gowl-power
  (cmacs-gowl-power--unregister)
  (if cmacs-gowl-power-saver-mode
      (progn
        (cmacs-gowl-power--register)
        (setq cmacs-gowl-power--profile nil)
        (let ((profile (cmacs-gowl-power--read-profile)))
          (when profile
            (cmacs-gowl-power--update profile))))
    (cmacs-gowl-power--release t)
    (setq cmacs-gowl-power--profile nil)))

(defun cmacs-gowl-power--on-start ()
  "Set up the power-saver hold as `cmacs-gowl-mode' starts.
Runs before the backdrop is first pushed: a profile that is already
power saver marks the hold now, so `cmacs-gowl-power-apply' keeps the
user's backdrop back instead of drawing it."
  (when cmacs-gowl-power-saver-effects
    (cmacs-gowl-power--register)
    (setq cmacs-gowl-power-saver-mode t)
    (let ((profile (cmacs-gowl-power--read-profile)))
      (setq cmacs-gowl-power--profile profile)
      (when (cmacs-gowl-power--saver-p profile)
        ;; A placeholder: the real values arrive through
        ;; `cmacs-gowl-power-apply' a moment later.
        (setq cmacs-gowl-power--held (cons 'none nil))))))

(defun cmacs-gowl-power--on-stop ()
  "Forget the hold and the signals as `cmacs-gowl-mode' stops.
Nothing is restored: the compositor is going away."
  (cmacs-gowl-power--unregister)
  (setq cmacs-gowl-power-saver-mode nil
        cmacs-gowl-power--held nil
        cmacs-gowl-power--profile nil))

(provide 'cmacs-gowl-power)
;;; cmacs-gowl-power.el ends here
