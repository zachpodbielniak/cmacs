;;; cmacs-screensaver-tools.el --- The screensaver renderer as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The eight `screensaver_*' MCP tools of
;; cmacs/mcp/cmacs-mcp-tools-gowl.c, moved onto the capability table
;; (doc_org/cmacs/cmacs-capability.org has the recipe).  Wire names,
;; parameter names and the required/optional split are the C ones.
;; Those handlers are deleted; the schema to keep is what they
;; published, frozen in test/cmacs/data/mcp-wire-schema.json.
;;
;; What a body calls is what the C handler's dispatch function
;; (`cmacs_dispatch_screensaver_*' in cmacs/glib/cmacs-eval-dispatch.c)
;; built a form around: a function of cmacs-screensaver.el.  Those
;; functions talk to the out-of-process render child over its control
;; socket and return at once; nothing here waits for a frame.
;;
;; What differs from the C, on purpose:
;;
;;   - No argument is spliced into Lisp source.  The C wrote the config
;;     name into a quoted form after checking its alphabet; here the same
;;     check is made and the name is interned, and nothing is ever read.
;;
;;   - A failure is signalled instead of returned as text.  The messages
;;     are the C ones ("Gowl compositor not running", "invalid
;;     screensaver config name: ...", "screensaver fps must be 1..240").
;;
;;   - The tools that change what is on screen are declared destructive,
;;     so a read-only agent does not get them, and name their surfaces,
;;     so they stay reachable from D-Bus and `emacsctl tool' where the
;;     person asking is the person at the desk.
;;
;; The family's flag is IS-CMACS-GOWL, not IS-CMACS-SCREENSAVER: that is
;; what the C registration was compiled under.  In a build without the
;; screensaver the Lisp functions report that themselves, as they did.

;;; Code:

(require 'cmacs-brigade-registry)

(defvar cmacs-screensaver-configs)
(defvar cmacs-screensaver-wallpaper-config)
(defvar cmacs-screensaver-default-config)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function cmacs-screensaver-set-wallpaper "cmacs-screensaver" (name))
(declare-function cmacs-screensaver-stop-wallpaper "cmacs-screensaver" ())
(declare-function cmacs-screensaver-status "cmacs-screensaver" ())
(declare-function cmacs-screensaver-restart "cmacs-screensaver" ())
(declare-function cmacs-screensaver-pause "cmacs-screensaver" ())
(declare-function cmacs-screensaver-resume "cmacs-screensaver" ())
(declare-function cmacs-screensaver-set-fps "cmacs-screensaver" (fps))

(defun cmacs-screensaver-tools--running ()
  "Signal, in the C's words, unless a gowl compositor runs in this Emacs.
The wallpaper and the lock background are the compositor's; the C
dispatch checked for one (GOWL_DISPATCH_CHECK) before every tool that
changes them."
  (unless (and (fboundp 'gowl-running-p) (gowl-running-p))
    (error "Gowl compositor not running")))

(defun cmacs-screensaver-tools--config (name)
  "Return NAME, a config name, as a symbol; signal when it is not one.
The alphabet is the C's `screensaver_config_name_ok': letters, digits,
`-' and `_'.  A name outside it is refused before it is interned."
  (unless (and (stringp name)
               (string-match-p "\\`[A-Za-z0-9_-]+\\'" name))
    (error "invalid screensaver config name: %s" name))
  (intern name))


;;;; Reading

(cmacs-brigade-deftool screensaver-list-configs
  "List the available screensaver config names (one per line)."
    ()
  :group 'screensaver
  :example "emacsctl tool screensaver list-configs"
  (require 'cmacs-screensaver)
  (mapconcat (lambda (entry) (symbol-name (car entry)))
             cmacs-screensaver-configs "\n"))

(cmacs-brigade-deftool screensaver-status
  "Get the out-of-process screensaver renderer status as a plist \
\(:running :pid :fps :paused :gave-up :targets :wallpaper :lock \
:last-error)."
    ()
  :group 'screensaver
  :example "emacsctl tool screensaver status"
  (require 'cmacs-screensaver)
  (prin1-to-string (cmacs-screensaver-status)))


;;;; Changing what is on screen

(cmacs-brigade-deftool screensaver-set-wallpaper
  "Set the animated libregnum screensaver wallpaper to a named config \
from cmacs-screensaver-configs (omit `config' for the default)."
    ((config string "Config name from cmacs-screensaver-configs \
\(e.g. blackhole-cool)" :optional t))
  :group 'screensaver :destructive t
  :surfaces '(mcp dbus cli agents)
  :example "emacsctl tool screensaver set-wallpaper --config blackhole-cool"
  (cmacs-screensaver-tools--running)
  (require 'cmacs-screensaver)
  (cmacs-screensaver-set-wallpaper
   (if (and (stringp config) (not (string-empty-p config)))
       (cmacs-screensaver-tools--config config)
     (or cmacs-screensaver-wallpaper-config
         cmacs-screensaver-default-config)))
  "t")

(cmacs-brigade-deftool screensaver-stop-wallpaper
  "Stop the animated screensaver wallpaper, restoring the static one."
    ()
  :group 'screensaver :destructive t
  :surfaces '(mcp dbus cli agents)
  (cmacs-screensaver-tools--running)
  (require 'cmacs-screensaver)
  (cmacs-screensaver-stop-wallpaper)
  "t")

(cmacs-brigade-deftool screensaver-restart
  "Kill and respawn the screensaver render child, re-applying the active \
wallpaper/lock sessions (recovery)."
    ()
  :group 'screensaver :destructive t
  :surfaces '(mcp dbus cli agents)
  (cmacs-screensaver-tools--running)
  (require 'cmacs-screensaver)
  (cmacs-screensaver-restart)
  "t")

(cmacs-brigade-deftool screensaver-pause
  "Pause the animated wallpaper/lock rendering (the render child stops \
drawing; the GPU goes idle)."
    ()
  :group 'screensaver :destructive t
  :surfaces '(mcp dbus cli agents)
  (cmacs-screensaver-tools--running)
  (require 'cmacs-screensaver)
  (cmacs-screensaver-pause)
  "t")

(cmacs-brigade-deftool screensaver-resume
  "Resume the animated wallpaper/lock rendering after a pause."
    ()
  :group 'screensaver :destructive t
  :surfaces '(mcp dbus cli agents)
  (cmacs-screensaver-tools--running)
  (require 'cmacs-screensaver)
  (cmacs-screensaver-resume)
  "t")

(cmacs-brigade-deftool screensaver-set-fps
  "Set the animated wallpaper/lock target frame rate (1-240)."
    ((fps integer "Target frames per second"))
  :group 'screensaver :destructive t
  :surfaces '(mcp dbus cli agents)
  :example "emacsctl tool screensaver set-fps --fps 30"
  (cmacs-screensaver-tools--running)
  (unless (and (integerp fps) (<= 1 fps 240))
    (error "screensaver fps must be 1..240 (got %s)" fps))
  (require 'cmacs-screensaver)
  (cmacs-screensaver-set-fps fps)
  "t")

(provide 'cmacs-screensaver-tools)

;;; cmacs-screensaver-tools.el ends here
