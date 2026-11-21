;;; cmacs-rig.el --- A private cmacs --gowl session to test against  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A RIG is a second cmacs, started as `emacs --gowl -Q' on wlroots'
;; headless backend, with its own MCP server, its own D-Bus session bus
;; and real Wayland clients inside it.  Tests drive it from the OUTSIDE,
;; over the real MCP socket, the way an agent or `emacsctl' does.
;; Nothing is stubbed: a tools/call goes through the socket, the
;; publisher, the registry and the dispatch a user's call goes through.
;;
;; Why it exists.  Features were landing with unit tests that called
;; the Lisp handler directly and stubbed the C primitives.  Two bugs
;; were found only when one test talked to a real socket: migrated Lisp
;; tools were not replacing their C twins, and a tools/call with no
;; "arguments" crashed the editor.  Neither is reachable from a test
;; that never leaves its own process.
;;
;; ISOLATION IS THE INVARIANT.  The developer's desktop is itself a
;; `cmacs --gowl' session, so a rig that reached it could kill it.
;;
;;   - The child's environment is BUILT, not inherited: a short list of
;;     names is copied (PATH, the locale, the time zone) and everything
;;     else is set here.  DBUS_SESSION_BUS_ADDRESS of the parent can
;;     therefore not leak in: it is not on the list.  WAYLAND_DISPLAY
;;     and DISPLAY are, in addition, explicitly UNSET, because Emacs
;;     hands a subprocess the DISPLAY it was itself started with unless
;;     told otherwise -- which the isolation test found, by reading
;;     /proc/PID/environ of the child, not by reading this file.
;;   - XDG_RUNTIME_DIR, HOME and the four XDG base directories are
;;     fresh directories under one `make-temp-file' directory (0700).
;;     No user init, journal, gabbrev or bar state is read or written.
;;   - The compositor runs on WLR_BACKENDS=headless with the pixman
;;     renderer: no DRM, no parent compositor, no GPU.
;;   - D-Bus is a `dbus-daemon --session' of the rig's own, listening
;;     in the private runtime directory.
;;   - `cmacs-rig-start' refuses to go on (`cmacs-rig-unsafe') if the
;;     directory it computed is the real runtime directory or the real
;;     HOME, or if a socket of the live session would be in reach.
;;   - Every process is known by PID and signalled by PID.  Before a
;;     PID that is not one of this Emacs's own process objects is
;;     signalled, /proc/PID/environ must name the rig's runtime
;;     directory.  Nothing is ever killed by pattern.
;;   - Every wait has a deadline.  The child also ends itself when the
;;     Emacs that started it disappears, and `timeout' ends it whatever
;;     happens after `cmacs-rig-lifetime' seconds.
;;
;; USE
;;
;;   (cmacs-rig-with-rig (rig)                 ; start, run, always stop
;;     (cmacs-rig-tool-text rig "list_buffers")
;;     (cmacs-rig-eval rig '(buffer-name)))
;;
;; `cmacs-rig-tests.el' keeps one rig for the whole file
;; (`cmacs-rig-session') because a compositor takes seconds to start.
;;
;; Set CMACS_RIG_KEEP=1 to leave the directory (logs, screenshots)
;; behind after a run; a failing start always says where it is.
;; `cmacs-rig-attach' connects to a rig left running by
;; `cmacs-rig-start' in another Emacs, for poking at one by hand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

;;;; Options

(defgroup cmacs-rig nil
  "A private cmacs --gowl session for end-to-end tests."
  :group 'cmacs
  :prefix "cmacs-rig-")

(defcustom cmacs-rig-start-timeout 60
  "Seconds to wait for the child to be ready before giving up."
  :type 'number
  :group 'cmacs-rig)

(defcustom cmacs-rig-call-timeout 30
  "Seconds one MCP request may take before it counts as hung."
  :type 'number
  :group 'cmacs-rig)

(defcustom cmacs-rig-lifetime 1800
  "Seconds after which `timeout' kills the child, whatever happens.
The last line of defence against a child whose main thread is wedged
and whose parent died without unwinding."
  :type 'integer
  :group 'cmacs-rig)

(defcustom cmacs-rig-renderer (or (getenv "CMACS_RIG_RENDERER") "pixman")
  "The wlroots renderer of the rig (WLR_RENDERER).
\"pixman\" needs no GPU and is what `cmacs-gowl-tests.el' uses;
\"gles2\" exercises the effect modules where a render node exists."
  :type 'string
  :group 'cmacs-rig)

(defcustom cmacs-rig-fatal-criticals t
  "Non-nil runs the child with G_DEBUG=fatal-criticals.
A GLib critical then kills the child, and the test that caused it
fails on a dead child rather than passing over a broken invariant."
  :type 'boolean
  :group 'cmacs-rig)

(defvar cmacs-rig-extra-environment nil
  "More \"NAME=VALUE\" strings for the child, for debugging a failure.
For example (\"WAYLAND_DEBUG=server\") puts every protocol message the
compositor sends or receives in the child's log.  Never a display, a
socket or a bus: `cmacs-rig--assert-private' checks the result.")

(defconst cmacs-rig-inherited-environment
  '("PATH" "TZ" "USER" "LOGNAME" "LD_LIBRARY_PATH")
  "The only variables a rig's processes inherit from this Emacs.
Everything else is set by `cmacs-rig--environment'.  Adding a name here
is adding a way for the live session to reach the rig: do not add
anything that names a socket, a display or a bus.")

;;;; Errors

(define-error 'cmacs-rig-error "Rig error")
(define-error 'cmacs-rig-unsafe
              "Refusing to start a rig that could touch the live session"
              'cmacs-rig-error)
(define-error 'cmacs-rig-transport-error
              "The rig did not answer" 'cmacs-rig-error)
(define-error 'cmacs-rig-dead "The rig's cmacs has died" 'cmacs-rig-error)
(define-error 'cmacs-rig-rpc-error "JSON-RPC error from the rig"
              'cmacs-rig-error)
(define-error 'cmacs-rig-tool-error "The tool refused" 'cmacs-rig-error)
(define-error 'cmacs-rig-timeout "Timed out waiting on the rig"
              'cmacs-rig-error)

;;;; The rig

(cl-defstruct (cmacs-rig (:constructor cmacs-rig--create) (:copier nil))
  "One private session."
  base          ; the temporary directory everything lives under
  runtime       ; its XDG_RUNTIME_DIR
  home config state data cache
  log           ; the child's stdout and stderr
  bus           ; the dbus-daemon process object
  bus-address
  process       ; the `timeout ... emacs' process object
  pid           ; the child cmacs itself
  socket        ; its MCP socket
  display       ; its WAYLAND_DISPLAY, a name inside `runtime'
  spawned       ; process objects of clients this Emacs started
  environment   ; what its processes run with
  attached)     ; non-nil: started elsewhere, not ours to stop

(defvar cmacs-rig--all nil
  "Every rig this Emacs started and has not stopped.")

(defun cmacs-rig--tree ()
  "Return the root of the source tree this Emacs was built in."
  (file-name-as-directory
   (if (and (bound-and-true-p source-directory)
            (file-directory-p (expand-file-name "deps/gowl"
                                                source-directory)))
       source-directory
     (expand-file-name ".." invocation-directory))))

(defun cmacs-rig--emacs ()
  "Return the cmacs binary a rig runs: the one running this."
  (expand-file-name invocation-name invocation-directory))

(defun cmacs-rig-available-p ()
  "Return nil if a rig can start here, else a sentence saying why not."
  (cond
   ((not (fboundp 'gowl-start)) "this cmacs has no gowl")
   ((not (fboundp 'cmacs-mcp-start)) "this cmacs has no MCP server")
   ((not (eq system-type 'gnu/linux)) "the rig reads /proc")
   ((not (executable-find "dbus-daemon")) "no dbus-daemon")
   ((not (executable-find "timeout")) "no timeout(1)")
   ((getenv "CMACS_RIG_DISABLE") "CMACS_RIG_DISABLE is set")))

;;;; Isolation

(defun cmacs-rig--real-directories ()
  "Return the directories of the live session a rig must never use."
  (delq nil
        (mapcar (lambda (dir)
                  (and dir (not (string-empty-p dir))
                       (file-truename (file-name-as-directory dir))))
                (list (getenv "XDG_RUNTIME_DIR") (getenv "HOME")
                      (getenv "XDG_CONFIG_HOME") (getenv "XDG_STATE_HOME")
                      (getenv "XDG_DATA_HOME")
                      (expand-file-name "~/.config")
                      (expand-file-name "~/.local/state")
                      (expand-file-name "~/.local/share")))))

(defun cmacs-rig--assert-private (rig &optional bus-started)
  "Signal `cmacs-rig-unsafe' unless RIG is out of the live session's reach.
Called before anything is started, and again, with BUS-STARTED, between
the rig's own bus and the child (the bus socket is then expected)."
  (let ((real (cmacs-rig--real-directories)))
    (dolist (slot (list (cmacs-rig-runtime rig) (cmacs-rig-home rig)
                        (cmacs-rig-config rig) (cmacs-rig-state rig)
                        (cmacs-rig-data rig) (cmacs-rig-cache rig)))
      (let ((dir (file-truename (file-name-as-directory slot))))
        (when (member dir real)
          (signal 'cmacs-rig-unsafe
                  (list (format "%s is a directory of the live session"
                                dir))))
        (unless (string-prefix-p
                 (file-truename (file-name-as-directory
                                 (cmacs-rig-base rig)))
                 dir)
          (signal 'cmacs-rig-unsafe
                  (list (format "%s is outside the rig" dir))))))
    ;; A fresh runtime directory holds nothing.  A compositor or MCP
    ;; socket in it would be somebody else's.
    (when (directory-files (cmacs-rig-runtime rig) nil
                           (if bus-started
                               "\\`\\(wayland-\\|cmacs-mcp-\\)"
                             "\\`\\(wayland-\\|cmacs-mcp-\\|bus\\'\\)"))
      (signal 'cmacs-rig-unsafe
              (list (format "%s already holds sockets"
                            (cmacs-rig-runtime rig)))))
    (unless (eql (logand (file-modes (cmacs-rig-runtime rig)) #o777) #o700)
      (signal 'cmacs-rig-unsafe
              (list (format "%s is not mode 0700" (cmacs-rig-runtime rig)))))
    ;; The longest socket name a rig makes, against sun_path.
    (when (>= (length (expand-file-name "cmacs-mcp-4194304.sock"
                                        (cmacs-rig-runtime rig)))
              100)
      (signal 'cmacs-rig-unsafe
              (list (format "%s is too long for a socket path"
                            (cmacs-rig-runtime rig)))))
    (dolist (entry (cmacs-rig-environment rig))
      (when (string-match
             "\\`\\(WAYLAND_DISPLAY\\|WAYLAND_SOCKET\\|DISPLAY\\|GOWL_SOCKET\\|SWAYSOCK\\)=." entry)
        (signal 'cmacs-rig-unsafe
                (list (format "the child would inherit %s" entry))))
      ;; Whatever bus is named, it is the rig's.
      (when (and (string-prefix-p "DBUS_SESSION_BUS_ADDRESS=" entry)
                 (not (string-search (cmacs-rig-runtime rig) entry)))
        (signal 'cmacs-rig-unsafe
                (list (format "the child would use the bus %s" entry)))))
    t))

(defun cmacs-rig--environment (rig)
  "Return the whole environment of RIG's processes, as a list of strings.
Built from nothing: see `cmacs-rig-inherited-environment'."
  (append
   (delq nil (mapcar (lambda (name)
                       (when-let* ((value (getenv name)))
                         (concat name "=" value)))
                     cmacs-rig-inherited-environment))
   ;; UNSET, by name.  Not decoration: when `process-environment' has
   ;; no entry for DISPLAY, Emacs gives a subprocess the DISPLAY of
   ;; `initial-environment' (callproc.c) -- the live session's X
   ;; server.  An entry with no \"=\" is \"defined, and unset\", which
   ;; is also how `cmacs-gowl-tests--run-headless' does it.
   (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY")
   ;; One locale for every run, whoever runs it: UTF-8, so a test may
   ;; put any character in a window title or a text field.
   (list "LANG=C.UTF-8" "LC_ALL=C.UTF-8")
   (list "SHELL=/bin/sh" "TERM=dumb"
         (concat "HOME=" (cmacs-rig-home rig))
         (concat "XDG_RUNTIME_DIR=" (cmacs-rig-runtime rig))
         (concat "XDG_CONFIG_HOME=" (cmacs-rig-config rig))
         (concat "XDG_STATE_HOME=" (cmacs-rig-state rig))
         (concat "XDG_DATA_HOME=" (cmacs-rig-data rig))
         (concat "XDG_CACHE_HOME=" (cmacs-rig-cache rig))
         ;; The launch recipe of `cmacs-gowl-tests--run-headless'.
         "GOWL_DISABLE_SYSTEMD=1"
         "WLR_BACKENDS=headless"
         "WLR_HEADLESS_OUTPUTS=1"
         (concat "WLR_RENDERER=" cmacs-rig-renderer)
         ;; Nothing of the desktop's: no accessibility bus, no dconf
         ;; daemon, no gvfs (its FUSE mount would land in the runtime
         ;; directory and outlive the run).
         "NO_AT_BRIDGE=1" "GSETTINGS_BACKEND=memory"
         "GIO_USE_VFS=local" "GVFS_DISABLE_FUSE=1"
         (concat "GOWL_MENU_FILE="
                 (expand-file-name "deps/gowl/data/menu.yaml"
                                   (cmacs-rig--tree)))
         (concat "CMACS_RIG_BASE=" (cmacs-rig-base rig))
         (format "CMACS_RIG_PARENT=%d" (emacs-pid)))
   cmacs-rig-extra-environment
   (and cmacs-rig-fatal-criticals (list "G_DEBUG=fatal-criticals"))
   (and (cmacs-rig-bus-address rig)
        (list (concat "DBUS_SESSION_BUS_ADDRESS="
                      (cmacs-rig-bus-address rig))))))

(defun cmacs-rig-client-environment (rig)
  "Return the environment of a Wayland client inside RIG.
The rig's own, plus its compositor's WAYLAND_DISPLAY -- the only
display such a process can reach."
  (append (list (concat "WAYLAND_DISPLAY=" (cmacs-rig-display rig))
                "GDK_BACKEND=wayland" "QT_QPA_PLATFORM=wayland"
       "GTK_IM_MODULE=wayland")
          (cl-remove-if (lambda (entry)
                          (or (string-prefix-p "G_DEBUG=" entry)
                              ;; Replaced by the entry above.
                              (equal entry "WAYLAND_DISPLAY")))
                        (cmacs-rig-environment rig))))

;;;; Processes, by PID

(defun cmacs-rig--pid-in-rig-p (rig pid)
  "Return non-nil if process PID runs with RIG's runtime directory.
Read from /proc/PID/environ.  This is what makes signalling a PID that
is not one of our own process objects safe: a recycled PID, or a wrong
one, does not carry the rig's directory."
  (let ((file (format "/proc/%d/environ" pid)))
    (and (integerp pid) (> pid 1)
         (file-readable-p file)
         (with-temp-buffer
           (set-buffer-multibyte nil)
           (ignore-errors (insert-file-contents-literally file))
           (goto-char (point-min))
           (search-forward
            (concat "XDG_RUNTIME_DIR=" (cmacs-rig-runtime rig) "\0")
            nil t)))))

(defun cmacs-rig--pid-live-p (pid)
  "Return non-nil if PID is a process that is not a zombie."
  (when-let* ((attrs (and (integerp pid) (process-attributes pid))))
    (not (equal (alist-get 'state attrs) "Z"))))

(defun cmacs-rig--signal-pid (rig pid signal)
  "Send SIGNAL to PID if, and only if, it belongs to RIG."
  (when (and (cmacs-rig--pid-live-p pid) (cmacs-rig--pid-in-rig-p rig pid))
    (ignore-errors (signal-process pid signal))))

(defun cmacs-rig-processes (rig)
  "Return the PIDs of every live process that runs inside RIG.
That is, of this user's processes whose environment has RIG's runtime
directory as XDG_RUNTIME_DIR.  Another user's /proc/PID/environ is not
readable and so never matches."
  (cl-remove-if-not (lambda (pid)
                      (and (/= pid (emacs-pid))
                           (cmacs-rig--pid-live-p pid)
                           (cmacs-rig--pid-in-rig-p rig pid)))
                    (list-system-processes)))

(defun cmacs-rig--wait (seconds predicate)
  "Call PREDICATE until it is non-nil or SECONDS have passed; return it.
Turns this Emacs's event loop meanwhile, so process output is read."
  (let ((deadline (+ (float-time) seconds)) value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    value))

(defun cmacs-rig-alive-p (rig)
  "Return non-nil while RIG's cmacs is running."
  (and (cmacs-rig-pid rig) (cmacs-rig--pid-live-p (cmacs-rig-pid rig))))

(defun cmacs-rig-log-tail (rig &optional lines)
  "Return the last LINES (default 40) of RIG's log that say something."
  (let ((file (cmacs-rig-log rig)))
    (if (not (and file (file-readable-p file)))
        ""
      (with-temp-buffer
        (insert-file-contents file)
        ;; One line per frame per effect module under pixman.
        (flush-lines "the renderer is not GLES2" (point-min) (point-max))
        (goto-char (point-max))
        (forward-line (- (or lines 40)))
        (buffer-substring (point) (point-max))))))

(defun cmacs-rig-describe (rig)
  "Return where RIG's evidence is, for a failure message."
  (format "rig %s (pid %s%s); log %s\n%s"
          (cmacs-rig-base rig) (cmacs-rig-pid rig)
          (if (cmacs-rig-alive-p rig) "" ", DEAD")
          (cmacs-rig-log rig) (cmacs-rig-log-tail rig 25)))

;;;; The child's init file

(defun cmacs-rig--init-form (extra)
  "Return the form the child loads at startup; EXTRA forms run first.
It never signals out: a failure is written to the ready file, which is
what the parent waits for."
  `(progn
     (setq load-prefer-newer t
           ;; A source newer than its .elc is loaded as source, and the
           ;; native compiler would then spend the run compiling it.
           native-comp-jit-compilation nil
           inhibit-startup-screen t
           ring-bell-function #'ignore
           ;; Nothing in the rig may stop to ask.
           use-dialog-box nil
           confirm-kill-processes nil
           confirm-kill-emacs nil
           make-backup-files nil
           auto-save-default nil
           create-lockfiles nil)
     (let ((base (getenv "CMACS_RIG_BASE"))
           (parent (string-to-number (or (getenv "CMACS_RIG_PARENT") "0")))
           (problem nil))
       ;; Go when the Emacs that started us goes.  A wedged main thread
       ;; never runs this; `timeout' is for that.
       (when (> parent 1)
         (run-at-time 2 2 (lambda ()
                            (unless (process-attributes parent)
                              (kill-emacs 0)))))
       ;; `cmacs-rig-do': run a form from the main loop, the way a key
       ;; binding or a timer runs one, and keep its value for the
       ;; parent to collect.  A form sent through the MCP `eval' tool
       ;; runs inside the RPC dispatch instead, where
       ;; `inhibit-interaction' is bound and every redaction rule is in
       ;; force -- which is right for testing what an agent sees and
       ;; wrong for testing what the person at the keyboard gets.
       (defvar cmacs-rig-child-results (make-hash-table :test #'eql))
       (defvar cmacs-rig-child-frame (selected-frame))
       (defun cmacs-rig-child-do (id form)
         (run-at-time
          0 nil
          (lambda ()
            (puthash id
                     (condition-case err
                         (list :ok (eval form t))
                       (error (list :error (error-message-string err))))
                     cmacs-rig-child-results)))
         id)
       (condition-case err
           (progn
             ,@extra
             (require 'cmacs)
             (require 'cmacs-gowl nil t)
             (require 'cmacs-brigade nil t)
             (require 'cmacs-capability nil t)
             ;; What cmacs.el arranges on `after-init-hook' in a real
             ;; `--gowl' session; under -Q that hook has already run by
             ;; the time this file loads.  It applies the configuration,
             ;; installs the key bindings and bridges the compositor's
             ;; signals to the Lisp hooks every feature here listens on.
             (when (and (fboundp 'cmacs-gowl-mode)
                        (not (bound-and-true-p cmacs-gowl-mode)))
               (cmacs-gowl-mode 1))
             (unless (cmacs-mcp-server-p) (cmacs-mcp-start)))
         (error (setq problem (error-message-string err))))
       (with-temp-file (expand-file-name "ready.tmp" base)
         (prin1 (list :pid (emacs-pid)
                      :socket (ignore-errors (cmacs-mcp-socket-path))
                      :display (getenv "WAYLAND_DISPLAY")
                      :gowl (ignore-errors (gowl-running-p))
                      :problem problem)
                (current-buffer)))
       (rename-file (expand-file-name "ready.tmp" base)
                    (expand-file-name "ready" base) t))))

;;;; Starting and stopping

(defun cmacs-rig--make-directories ()
  "Make a rig's directories and return the rig, with nothing started.
The parent is the user's runtime directory when there is one: it is
short (a socket path has 108 bytes), private and in memory.  The rig's
own runtime directory is a NEW directory inside it, never it."
  (let* ((parent (let ((dir (getenv "XDG_RUNTIME_DIR")))
                   (if (and dir (file-directory-p dir)
                            (file-writable-p dir))
                       dir
                     "/tmp")))
         (base (file-name-as-directory
                (make-temp-file (expand-file-name "crig-" parent) t)))
         (rig (cmacs-rig--create
               :base base
               :runtime (expand-file-name "r" base)
               :home (expand-file-name "home" base)
               :config (expand-file-name "config" base)
               :state (expand-file-name "state" base)
               :data (expand-file-name "data" base)
               :cache (expand-file-name "cache" base)
               :log (expand-file-name "child.log" base))))
    (set-file-modes base #o700)
    (dolist (dir (list (cmacs-rig-runtime rig) (cmacs-rig-home rig)
                       (cmacs-rig-config rig) (cmacs-rig-state rig)
                       (cmacs-rig-data rig) (cmacs-rig-cache rig)))
      (make-directory dir)
      (set-file-modes dir #o700))
    rig))

(defun cmacs-rig--start-bus (rig)
  "Start RIG's own D-Bus session bus and record its address."
  (let* ((path (expand-file-name "bus" (cmacs-rig-runtime rig)))
         (address (concat "unix:path=" path))
         (process-environment (cmacs-rig--environment rig))
         (default-directory (cmacs-rig-base rig)))
    (setf (cmacs-rig-bus rig)
          (make-process
           :name "cmacs-rig-bus" :noquery t :connection-type 'pipe
           :buffer nil
           :stderr nil
           :command (list (executable-find "timeout")
                          "--kill-after=5"
                          (number-to-string (+ 30 cmacs-rig-lifetime))
                          (executable-find "dbus-daemon")
                          "--session" "--nofork" "--nopidfile"
                          (concat "--address=" address))))
    (unless (cmacs-rig--wait 10 (lambda () (file-exists-p path)))
      (signal 'cmacs-rig-timeout (list "the private D-Bus never came up")))
    (setf (cmacs-rig-bus-address rig) address)))

(defun cmacs-rig--socket-answers-p (path)
  "Return non-nil if something accepts a connection on socket PATH."
  (condition-case nil
      (let ((p (make-network-process :name "cmacs-rig-probe" :family 'local
                                     :service path :noquery t)))
        (delete-process p)
        t)
    (error nil)))

(cl-defun cmacs-rig-start (&key files init)
  "Start a rig and return it once it answers.
FILES is an alist of (RELATIVE-NAME . CONTENTS) written before the child
starts; a name is relative to the rig's base directory, so
\"config/cmacs/journal-filters.yaml\" lands in its XDG_CONFIG_HOME.
INIT is a list of forms the child evaluates first in its init file.

Ready means: the child wrote its ready file, its compositor's socket
accepts a connection, and its MCP server answered `initialize'.
Signals `cmacs-rig-unsafe' before starting anything if the rig could
reach the live session, and a `cmacs-rig-error' naming the log if the
child does not come up."
  (when-let* ((why (cmacs-rig-available-p)))
    (signal 'cmacs-rig-error (list why)))
  (let ((rig (cmacs-rig--make-directories))
        (ok nil))
    (unwind-protect
        (progn
          (setf (cmacs-rig-environment rig) (cmacs-rig--environment rig))
          (cmacs-rig--assert-private rig)
          (push rig cmacs-rig--all)
          (pcase-dolist (`(,name . ,contents) files)
            (let ((file (expand-file-name name (cmacs-rig-base rig))))
              (make-directory (file-name-directory file) t)
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region contents nil file nil 'silent))))
          (let ((init-file (expand-file-name "init.el" (cmacs-rig-base rig)))
                (coding-system-for-write 'utf-8-unix))
            (write-region
             (concat ";;; -*- lexical-binding: t; -*-\n"
                     (let ((print-length nil) (print-level nil))
                       (prin1-to-string (cmacs-rig--init-form init)))
                     "\n")
             nil init-file nil 'silent)
            (cmacs-rig--start-bus rig)
            (setf (cmacs-rig-environment rig) (cmacs-rig--environment rig))
            (cmacs-rig--assert-private rig t)
            ;; In the base directory: a gowl config reload looks for
            ;; data/config.yaml relative to where it runs before it
            ;; looks at the user's.
            (let ((process-environment (cmacs-rig-environment rig))
                  (default-directory (cmacs-rig-base rig)))
              (setf (cmacs-rig-process rig)
                    (make-process
                     :name "cmacs-rig" :noquery t :connection-type 'pipe
                     :buffer nil
                     :command
                     (list "/bin/sh" "-c"
                           ;; The log is a file, so it survives this
                           ;; Emacs and is there to read after a crash.
                           "exec \"$@\" >\"$CMACS_RIG_BASE/child.log\" 2>&1"
                           "cmacs-rig"
                           (executable-find "timeout") "--kill-after=5"
                           (number-to-string cmacs-rig-lifetime)
                           (cmacs-rig--emacs) "--gowl" "-Q"
                           "-l" init-file)))))
          (cmacs-rig--await-ready rig)
          (setq ok t)
          rig)
      (unless ok
        (let ((where (cmacs-rig-describe rig)))
          (let ((process-environment
                 (cons "CMACS_RIG_KEEP=1" process-environment)))
            (cmacs-rig-stop rig))
          (message "cmacs-rig: start failed; %s" where))))))

(defun cmacs-rig--await-ready (rig)
  "Wait until RIG is ready, or signal saying what is missing."
  (let ((ready (expand-file-name "ready" (cmacs-rig-base rig)))
        info)
    (unless (cmacs-rig--wait
             cmacs-rig-start-timeout
             (lambda () (or (file-exists-p ready)
                            (not (process-live-p (cmacs-rig-process rig))))))
      (signal 'cmacs-rig-timeout
              (list (concat "the child never finished starting; "
                            (cmacs-rig-describe rig)))))
    (unless (file-exists-p ready)
      (signal 'cmacs-rig-dead
              (list (concat "the child died while starting; "
                            (cmacs-rig-describe rig)))))
    (setq info (with-temp-buffer
                 (insert-file-contents ready)
                 (read (current-buffer))))
    (setf (cmacs-rig-pid rig) (plist-get info :pid)
          (cmacs-rig-socket rig) (plist-get info :socket)
          (cmacs-rig-display rig) (plist-get info :display))
    (when (plist-get info :problem)
      (signal 'cmacs-rig-error
              (list (format "the child's init failed: %s; %s"
                            (plist-get info :problem)
                            (cmacs-rig-describe rig)))))
    ;; The child says where its sockets are; they must be in the rig.
    (dolist (path (list (cmacs-rig-socket rig)
                        (and (cmacs-rig-display rig)
                             (expand-file-name (cmacs-rig-display rig)
                                               (cmacs-rig-runtime rig)))))
      (unless (and path
                   (string-prefix-p (cmacs-rig-base rig)
                                    (expand-file-name path))
                   (cmacs-rig--wait
                    10 (lambda () (cmacs-rig--socket-answers-p path))))
        (signal 'cmacs-rig-error
                (list (format "socket %s is missing, silent or outside \
the rig; %s" path (cmacs-rig-describe rig))))))
    (unless (plist-get info :gowl)
      (signal 'cmacs-rig-error
              (list (concat "no compositor in the child; "
                            (cmacs-rig-describe rig)))))
    ;; Sockets that exist AND answer.
    (cmacs-rig-request rig "tools/list" nil 20)
    (cmacs-rig--await-settled rig)
    rig))

(defun cmacs-rig--await-settled (rig)
  "Wait until RIG's startup has gone quiet, for ten seconds at most.
A session is not finished starting when its sockets answer: the bar is
configured a second time a couple of seconds in, and the Emacs frame
takes the keyboard back as it settles, away from a window mapped in
that moment.  A test that began there would be testing the startup.
Quiet is: the child's log has not grown and the focused window has not
changed for a second."
  (let ((deadline (+ (float-time) 10))
        (last nil) (since (float-time)))
    (while (and (< (float-time) deadline)
                (< (- (float-time) since) 1.0))
      (let ((now (list (file-attribute-size
                        (file-attributes (cmacs-rig-log rig)))
                       (ignore-errors
                         (cmacs-rig-eval
                          rig '(ignore-errors
                                 (alist-get 'id (gowl-client-info
                                                 (gowl-focused-client)))))))))
        (unless (equal now last)
          (setq last now since (float-time))))
      (accept-process-output nil 0.2))))

(defun cmacs-rig-attach (base)
  "Return a rig for the one running in directory BASE.
For poking at a rig another Emacs started.  `cmacs-rig-stop' leaves an
attached rig running."
  (let* ((base (file-name-as-directory (expand-file-name base)))
         (info (with-temp-buffer
                 (insert-file-contents (expand-file-name "ready" base))
                 (read (current-buffer))))
         (rig (cmacs-rig--create
               :base base :runtime (expand-file-name "r" base)
               :home (expand-file-name "home" base)
               :config (expand-file-name "config" base)
               :state (expand-file-name "state" base)
               :data (expand-file-name "data" base)
               :cache (expand-file-name "cache" base)
               :log (expand-file-name "child.log" base)
               :pid (plist-get info :pid)
               :socket (plist-get info :socket)
               :display (plist-get info :display)
               :bus-address (concat "unix:path="
                                    (expand-file-name "r/bus" base))
               :attached t)))
    (setf (cmacs-rig-environment rig) (cmacs-rig--environment rig))
    rig))

(defun cmacs-rig--child-client-pids (rig)
  "Return the PIDs of the windows in RIG, asked of its compositor.
Best effort, with a short deadline: this runs on the way out."
  (ignore-errors
    (let ((cmacs-rig-call-timeout 5))
      (cmacs-rig-eval rig '(delq nil (mapcar (lambda (c)
                                               (ignore-errors
                                                 (gowl-client-pid c)))
                                             (gowl-list-clients)))))))

(defun cmacs-rig-stop (rig)
  "Stop everything RIG started and remove its directory.
Safe to call twice and on a rig that only half started.  The directory
is kept, and its name printed, when CMACS_RIG_KEEP is set."
  (unless (cmacs-rig-attached rig)
    (let* ((pid (cmacs-rig-pid rig))
           (inside (and pid (cmacs-rig-alive-p rig) (cmacs-rig-socket rig)
                        (cmacs-rig--child-client-pids rig))))
      ;; Clients first, so they are not left talking to a dead socket.
      (dolist (client (cmacs-rig-spawned rig))
        (when (process-live-p client)
          (ignore-errors (signal-process client 'SIGTERM))))
      ;; The child itself, then `timeout' above it.
      (when pid (cmacs-rig--signal-pid rig pid 'SIGTERM))
      (cmacs-rig--wait 5 (lambda () (not (cmacs-rig-alive-p rig))))
      (when (process-live-p (cmacs-rig-process rig))
        (ignore-errors (signal-process (cmacs-rig-process rig) 'SIGTERM)))
      (cmacs-rig--wait
       8 (lambda () (and (not (cmacs-rig-alive-p rig))
                         (not (process-live-p (cmacs-rig-process rig))))))
      (when pid (cmacs-rig--signal-pid rig pid 'SIGKILL))
      (when (process-live-p (cmacs-rig-process rig))
        (ignore-errors (signal-process (cmacs-rig-process rig) 'SIGKILL)))
      ;; Whatever the child started itself (a restored window, a spawned
      ;; program) lost its compositor; anything still there is told.
      (dolist (p (delete-dups (copy-sequence inside)))
        (cmacs-rig--signal-pid rig p 'SIGTERM))
      (dolist (client (cmacs-rig-spawned rig))
        (when (process-live-p client)
          (cmacs-rig--wait 2 (lambda () (not (process-live-p client))))
          (when (process-live-p client)
            (ignore-errors (signal-process client 'SIGKILL)))))
      (when (process-live-p (cmacs-rig-bus rig))
        (ignore-errors (signal-process (cmacs-rig-bus rig) 'SIGTERM))
        (cmacs-rig--wait 3 (lambda ()
                             (not (process-live-p (cmacs-rig-bus rig)))))
        (when (process-live-p (cmacs-rig-bus rig))
          (ignore-errors (signal-process (cmacs-rig-bus rig) 'SIGKILL))))
      (dolist (p (list (cmacs-rig-process rig) (cmacs-rig-bus rig)))
        (when (processp p) (ignore-errors (delete-process p))))
      ;; Last, whatever is left that was started inside the rig by
      ;; something other than this Emacs: a program the child spawned,
      ;; a service its bus activated.  Found by what it IS -- a process
      ;; whose environment names this rig's runtime directory -- never
      ;; by what it is called.
      (dolist (signal '(SIGTERM SIGKILL))
        (when-let* ((left (cmacs-rig-processes rig)))
          (dolist (p left) (cmacs-rig--signal-pid rig p signal))
          (cmacs-rig--wait 3 (lambda () (null (cmacs-rig-processes rig))))))
      (setq cmacs-rig--all (delq rig cmacs-rig--all))
      (let ((base (cmacs-rig-base rig)))
        (cond
         ((not (and base (file-directory-p base))) nil)
         ((getenv "CMACS_RIG_KEEP")
          (message "cmacs-rig: kept %s" base))
         ;; Only ever a directory this file made.
         ((string-match-p "/crig-[^/]+/\\'" base)
          (ignore-errors (delete-directory base t)))))))
  nil)

(defun cmacs-rig-stop-all ()
  "Stop every rig this Emacs started.  On `kill-emacs-hook'."
  (dolist (rig (copy-sequence cmacs-rig--all))
    (ignore-errors (cmacs-rig-stop rig))))

(add-hook 'kill-emacs-hook #'cmacs-rig-stop-all)

(defmacro cmacs-rig-with-rig (spec &rest body)
  "Start a rig, bind it to VAR, run BODY, and stop it whatever happens.
SPEC is (VAR START-ARGS...), the arguments those of `cmacs-rig-start'."
  (declare (indent 1) (debug ((symbolp &rest form) body)))
  (let ((var (car spec)))
    `(let ((,var (cmacs-rig-start ,@(cdr spec))))
       (unwind-protect (progn ,@body)
         (cmacs-rig-stop ,var)))))

;;;; MCP, over the socket

(defun cmacs-rig--rpc (rig requests timeout)
  "Send REQUESTS to RIG's MCP socket on one connection; return the replies.
REQUESTS is a list of plists.  One with an :id is sent and its reply
awaited before the next goes; one without is a notification.  The value
is the list of replies, as alists, in order.  Signals
`cmacs-rig-transport-error' when the connection closes or TIMEOUT
seconds pass without an answer, and `cmacs-rig-dead' when the reason is
that the child is gone."
  (let* ((buffer (generate-new-buffer " *cmacs-rig-rpc*" t))
         (closed nil) (replies nil) proc)
    (unwind-protect
        (progn
          (with-current-buffer buffer (set-buffer-multibyte nil))
          (condition-case err
              (setq proc (make-network-process
                          :name "cmacs-rig-rpc" :buffer buffer
                          :family 'local :service (cmacs-rig-socket rig)
                          :coding 'no-conversion :noquery t
                          :sentinel (lambda (p _e)
                                      (unless (process-live-p p)
                                        (setq closed t)))))
            (error
             (signal (if (cmacs-rig-alive-p rig) 'cmacs-rig-transport-error
                       'cmacs-rig-dead)
                     (list (format "cannot connect: %s; %s"
                                   (error-message-string err)
                                   (cmacs-rig-describe rig))))))
          (dolist (request requests)
            (process-send-string
             proc (concat (json-serialize request :null-object :null
                                          :false-object :false)
                          "\n"))
            (when-let* ((id (plist-get request :id)))
              (let ((deadline (+ (float-time) timeout)) reply)
                (while (and (not reply) (< (float-time) deadline))
                  (with-current-buffer buffer
                    (goto-char (point-min))
                    (while (and (not reply) (search-forward "\n" nil t))
                      (let* ((line (decode-coding-string
                                    (buffer-substring (point-min)
                                                      (1- (point)))
                                    'utf-8))
                             (parsed (ignore-errors
                                       (json-parse-string
                                        line :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil))))
                        (delete-region (point-min) (point))
                        (goto-char (point-min))
                        (when (and (consp parsed)
                                   (equal (format "%s" (alist-get 'id parsed))
                                          (format "%s" id)))
                          (setq reply parsed)))))
                  (unless reply
                    (when closed
                      (signal (if (cmacs-rig-alive-p rig)
                                  'cmacs-rig-transport-error
                                'cmacs-rig-dead)
                              (list (format "connection closed during %s; %s"
                                            (plist-get request :method)
                                            (cmacs-rig-describe rig)))))
                    (accept-process-output proc 0.05)))
                (unless reply
                  (signal (if (cmacs-rig-alive-p rig)
                              'cmacs-rig-transport-error
                            'cmacs-rig-dead)
                          (list (format "no answer to %s in %s s; %s"
                                        (plist-get request :method) timeout
                                        (cmacs-rig-describe rig)))))
                (push reply replies))))
          (nreverse replies))
      (when (processp proc) (delete-process proc))
      (kill-buffer buffer))))

(defconst cmacs-rig--handshake
  (list (list :jsonrpc "2.0" :id 1 :method "initialize"
              :params (list :protocolVersion "2024-11-05"
                            :capabilities (make-hash-table)
                            :clientInfo (list :name "cmacs-rig"
                                              :version "1")))
        (list :jsonrpc "2.0" :method "notifications/initialized"))
  "What an MCP client says before its first request.")

(defun cmacs-rig-request (rig method &optional params timeout)
  "Send METHOD with PARAMS (a plist or nil) to RIG; return its `result'.
A fresh connection and handshake each time, as a one-shot client does.
Signals `cmacs-rig-rpc-error' with (MESSAGE CODE) on a JSON-RPC error
and a transport error as `cmacs-rig--rpc' does."
  (let* ((replies (cmacs-rig--rpc
                   rig
                   (append cmacs-rig--handshake
                           (list (append (list :jsonrpc "2.0" :id 2
                                               :method method)
                                         (and params
                                              (list :params params)))))
                   (or timeout cmacs-rig-call-timeout)))
         (reply (car (last replies))))
    (if-let* ((problem (alist-get 'error reply)))
        (signal 'cmacs-rig-rpc-error
                (list (alist-get 'message problem)
                      (alist-get 'code problem)))
      (alist-get 'result reply))))

(defun cmacs-rig-tools (rig)
  "Return RIG's tools/list: a list of alists with `name', `inputSchema'..."
  (alist-get 'tools (cmacs-rig-request rig "tools/list")))

(defun cmacs-rig-result-text (result)
  "Return the text items of RESULT, an MCP tool result, joined by newlines."
  (mapconcat (lambda (item) (or (alist-get 'text item) ""))
             (cl-remove-if-not
              (lambda (item) (equal (alist-get 'type item) "text"))
              (alist-get 'content result))
             "\n"))

(defun cmacs-rig-call (rig tool &optional arguments timeout)
  "Call TOOL on RIG and return the whole MCP result, an alist.
ARGUMENTS is a plist; nil sends an empty object, and the symbol `omit'
sends no \"arguments\" member at all (which a client may do).  A tool's
own refusal comes back as a result with `isError' -- it is an answer,
not a failure of the wire -- so this only signals for the transport,
JSON-RPC errors and a dead child."
  (cmacs-rig-request
   rig "tools/call"
   (append (list :name tool)
           (cond ((eq arguments 'omit) nil)
                 ((null arguments) (list :arguments (make-hash-table)))
                 (t (list :arguments arguments))))
   timeout))

(defun cmacs-rig-tool-text (rig tool &optional arguments timeout)
  "Call TOOL on RIG and return its text.
Signals `cmacs-rig-tool-error' with the text when the tool refused."
  (let* ((result (cmacs-rig-call rig tool arguments timeout))
         (text (cmacs-rig-result-text result)))
    (when (alist-get 'isError result)
      (signal 'cmacs-rig-tool-error (list tool text)))
    text))

;;;; Running Lisp in the child

(defun cmacs-rig-eval (rig form &optional timeout)
  "Evaluate FORM in RIG's cmacs and return its value.
Through the child's own MCP `eval' tool on its private socket.  The
value must print readably; FORM is wrapped so that an error in it
arrives as a `cmacs-rig-tool-error' naming the condition rather than as
whatever the tool makes of it.  FORM runs on the child's main thread,
which is its compositor's too: it must not wait."
  (let* ((wrapped `(let ((print-length nil) (print-level nil)
                         (print-escape-newlines t))
                     (prin1-to-string
                      (condition-case cmacs-rig--err
                          (list :ok (progn ,form))
                        (error (list :error
                                     (error-message-string
                                      cmacs-rig--err)))))))
         (text (cmacs-rig-tool-text
                rig "eval"
                (list :expression (let ((print-length nil)
                                        (print-level nil))
                                    (prin1-to-string wrapped)))
                timeout))
         ;; The tool prints the string we made; reading it once gives
         ;; the string back and reading that gives the value.
         (string (condition-case nil (read text) (error text)))
         (value (if (stringp string)
                    (condition-case nil (read string)
                      (error (list :unreadable string)))
                  (list :unreadable text))))
    (pcase value
      (`(:ok ,v) v)
      (`(:error ,message)
       (signal 'cmacs-rig-tool-error (list "eval" message)))
      (_ (signal 'cmacs-rig-tool-error
                 (list "eval" (format "unreadable answer: %s" text)))))))

(defun cmacs-rig-wait-for (rig form &optional seconds)
  "Evaluate FORM in RIG until it is non-nil; return that value.
Polls from here, every tenth of a second, for SECONDS (default 10):
the child never waits.  Signals `cmacs-rig-timeout' with FORM."
  (let ((deadline (+ (float-time) (or seconds 10))) value)
    (while (and (not (setq value (cmacs-rig-eval rig form)))
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (or value
        (signal 'cmacs-rig-timeout
                (list (format "never true in the rig: %S; %s" form
                              (cmacs-rig-describe rig)))))))

;;;; Running Lisp in the child, as the person at the keyboard

(defvar cmacs-rig--do-counter 0
  "The last id handed to `cmacs-rig-child-do'.")

(defun cmacs-rig-do (rig form &optional seconds)
  "Evaluate FORM in RIG from its main loop and return its value.
Unlike `cmacs-rig-eval', FORM does not run inside the RPC dispatch: it
is queued with a zero timer, so it runs as a command bound to a key
runs -- `inhibit-interaction' unbound, no redaction, no \"an agent is
asking\".  Commands under test go through this; reads of state can use
either.  Waits up to SECONDS (default 10) for FORM to have run; what
FORM starts (a read, a model call) is the caller's to wait for.  An
error in FORM is a `cmacs-rig-tool-error'."
  (let* ((id (cl-incf cmacs-rig--do-counter))
         (_ (cmacs-rig-eval rig `(cmacs-rig-child-do ,id ',form)))
         (value (cmacs-rig-wait-for
                 rig `(gethash ,id cmacs-rig-child-results) seconds)))
    (cmacs-rig-eval rig `(remhash ,id cmacs-rig-child-results))
    (pcase value
      (`(:ok ,v) v)
      (`(:error ,message)
       (signal 'cmacs-rig-tool-error (list "do" message))))))

;;;; D-Bus, on the rig's own bus

(defun cmacs-rig-dbus (rig &rest args)
  "Run gdbus with ARGS against RIG's private session bus.
Return (STATUS . OUTPUT).  The address is passed explicitly and the
environment is the rig's, so the user's session bus is not reachable
from here even by mistake.  Ten seconds, enforced by timeout(1)."
  (let ((process-environment (cmacs-rig-environment rig))
        (default-directory (cmacs-rig-base rig)))
    (with-temp-buffer
      (cons (apply #'call-process (executable-find "timeout") nil t nil
                   "10" (or (executable-find "gdbus") "gdbus")
                   (car args) "--address" (cmacs-rig-bus-address rig)
                   (cdr args))
            (buffer-string)))))

;;;; Windows

(defun cmacs-rig-clients (rig)
  "Return RIG's windows as a list of alists from `gowl-client-info'."
  (cmacs-rig-eval
   rig '(mapcar (lambda (c)
                  (append (list (cons 'pid (ignore-errors
                                             (gowl-client-pid c))))
                          (gowl-client-info c)))
                (gowl-list-clients))))

(defun cmacs-rig-client (rig id)
  "Return the alist of RIG's window with gowl id ID, or nil."
  (cl-find id (cmacs-rig-clients rig)
           :key (lambda (info) (alist-get 'id info))))

(defun cmacs-rig-spawn (rig command &optional seconds)
  "Start COMMAND, a list of strings, as a Wayland client inside RIG.
Wait up to SECONDS (default 15) for a window of that process and
return its gowl id.  The process is this Emacs's child, tracked and
stopped with the rig, and its only display is the rig's compositor."
  (let* ((process-environment (cmacs-rig-client-environment rig))
         (default-directory (cmacs-rig-base rig))
         (log (expand-file-name
               (format "client-%d.log" (length (cmacs-rig-spawned rig)))
               (cmacs-rig-base rig)))
         ;; Arguments reach the program as UTF-8, whatever locale this
         ;; Emacs was started in.
         (coding-system-for-write 'utf-8-unix)
         (proc (make-process
                :name "cmacs-rig-client" :noquery t :connection-type 'pipe
                :buffer nil
                :command (append
                          (list "/bin/sh" "-c"
                                "log=$1; shift; exec \"$@\" >\"$log\" 2>&1"
                                "cmacs-rig-client" log)
                          command)))
         (pid (process-id proc)))
    (push proc (cmacs-rig-spawned rig))
    (or (cmacs-rig--wait
         (or seconds 15)
         (lambda ()
           (and (process-live-p proc)
                (alist-get 'id (cl-find pid (cmacs-rig-clients rig)
                                        :key (lambda (info)
                                               (alist-get 'pid info)))))))
        (signal 'cmacs-rig-timeout
                (list (format "%s never mapped a window (log %s); %s"
                              (car command) log
                              (cmacs-rig-describe rig)))))))

(defun cmacs-rig-close-client (rig id)
  "Ask RIG's window ID to close and wait until it is gone."
  (cmacs-rig-eval
   rig `(when-let* ((c (cl-find-if
                        (lambda (c)
                          (eql ,id (alist-get 'id (gowl-client-info c))))
                        (gowl-list-clients))))
          (gowl-close-client c)
          t))
  (cmacs-rig-wait-for
   rig `(not (cl-find-if
              (lambda (c) (eql ,id (alist-get 'id (gowl-client-info c))))
              (gowl-list-clients)))
   10))

(defun cmacs-rig-focus (rig id &optional seconds)
  "Give RIG's window ID the keyboard and wait until it keeps it.
Asked again on every poll until the compositor reports ID focused on
two polls in a row: focus that lands and is taken straight back is not
focus a test can build on.  SECONDS (default 8) is the deadline."
  (let ((deadline (+ (float-time) (or seconds 8)))
        (held 0))
    (while (and (< held 2) (< (float-time) deadline))
      (if (eql id (cmacs-rig-eval
                   rig `(let ((now (ignore-errors
                                     (alist-get 'id (gowl-client-info
                                                     (gowl-focused-client))))))
                          (unless (eql now ,id)
                            (when-let* ((c (cl-find-if
                                            (lambda (c)
                                              (eql ,id
                                                   (alist-get
                                                    'id (gowl-client-info c))))
                                            (gowl-list-clients))))
                              (gowl-focus-client c)))
                          now)))
          (cl-incf held)
        (setq held 0))
      (accept-process-output nil 0.15))
    (unless (>= held 2)
      (signal 'cmacs-rig-timeout
              (list (format "window %s never kept the keyboard; %s" id
                            (cmacs-rig-describe rig)))))
    t))

(defun cmacs-rig-screenshot (rig name)
  "Save a picture of RIG's screen as NAME.png in its directory.
Taken with the `gowl_screenshot' tool, over the socket.  Return the
file name, or nil if the tool refused or sent no image.  For a failing
test to leave behind; never signals."
  (ignore-errors
    (let* ((result (cmacs-rig-call rig "gowl_screenshot"))
           (item (cl-find-if (lambda (item)
                               (equal (alist-get 'type item) "image"))
                             (alist-get 'content result)))
           (data (and item (alist-get 'data item)))
           (file (expand-file-name (concat name ".png")
                                   (cmacs-rig-base rig))))
      (when (and data (not (alist-get 'isError result)))
        (let ((coding-system-for-write 'binary))
          (write-region (base64-decode-string data) nil file nil 'silent))
        file))))

;;;; Pictures of a run

(defvar cmacs-rig--shot-counter 0
  "How many pictures `cmacs-rig-shot' has taken in this Emacs.")

(defun cmacs-rig-shots-directory ()
  "Return the directory pictures of a run go to, or nil for none.
The environment variable CMACS_RIG_SHOTS; created when missing."
  (when-let* ((dir (getenv "CMACS_RIG_SHOTS"))
              ((not (string-empty-p dir))))
    (make-directory dir t)
    (file-name-as-directory (expand-file-name dir))))

(defun cmacs-rig-shot (rig name)
  "Save a picture of RIG's screen as NN-NAME.png; return the file or nil.
Does nothing unless CMACS_RIG_SHOTS names a directory.  The picture is
taken INSIDE the child, by its own `gowl-screenshot' of its own
headless output, and from its main loop rather than over RPC -- so it
also shows the states a model-facing screenshot is refused in, which
are among the ones worth looking at.  Never signals: a picture is
evidence for a person, not part of what a test asserts."
  (when-let* ((dir (cmacs-rig-shots-directory)))
    (ignore-errors
      (let ((file (expand-file-name
                   (format "%02d-%s.png" (cl-incf cmacs-rig--shot-counter)
                           name)
                   dir)))
        ;; Let what was just done reach the screen first.
        (cmacs-rig-eval rig '(progn (redisplay t) t))
        (accept-process-output nil 0.25)
        (cmacs-rig-do rig `(progn (gowl-screenshot 'desktop ,file t) t) 10)
        (and (file-exists-p file) file)))))

;;;; The text-field client

(defconst cmacs-rig--directory
  (file-name-directory (or load-file-name buffer-file-name
                           default-directory))
  "Where this file is, and `cmacs-rig-field.c' beside it.")

(defvar cmacs-rig--field-client 'unknown
  "The built text-field client, nil when it cannot be built, or `unknown'.")

(defun cmacs-rig--run (log program &rest args)
  "Run PROGRAM with ARGS, appending its output to buffer LOG; return t on 0."
  (eql 0 (apply #'call-process program nil log nil args)))

(defun cmacs-rig--pkg-config (&rest args)
  "Return pkg-config's answer to ARGS as a list of words, or nil."
  (when-let* ((pkg-config (executable-find "pkg-config")))
    (with-temp-buffer
      (and (eql 0 (apply #'call-process pkg-config nil '(t nil) nil args))
           (split-string (buffer-string))))))

(defun cmacs-rig-field-client ()
  "Return the rig's text-field client program, building it on first use.
It is `cmacs-rig-field.c' beside this file: a Wayland window that is
one text-input-v3 text field, with no toolkit (see that file for why).
Built into a temporary directory with the system gcc, pkg-config and
wayland-scanner, from the protocol descriptions wayland-protocols
installs.  Return nil when any of those is missing: a test that needs
the client skips."
  (when (eq cmacs-rig--field-client 'unknown)
    (setq cmacs-rig--field-client
          (let* ((default-directory temporary-file-directory)
                 (source (expand-file-name "cmacs-rig-field.c"
                                           cmacs-rig--directory))
                 (gcc (executable-find "gcc"))
                 (scanner (executable-find "wayland-scanner"))
                 (protocols (car (cmacs-rig--pkg-config
                                  "--variable=pkgdatadir"
                                  "wayland-protocols")))
                 (flags (cmacs-rig--pkg-config "--cflags" "--libs"
                                               "wayland-client" "glib-2.0"))
                 ;; Optional: with pangocairo the window draws its text,
                 ;; so a screenshot shows what the field holds.
                 (draw (cmacs-rig--pkg-config "--cflags" "--libs"
                                              "pangocairo"))
                 (flags (and flags
                             (append flags
                                     (and draw (cons "-DRIG_FIELD_DRAW"
                                                     draw)))))
                 (xmls (and protocols
                            (mapcar
                             (lambda (x) (expand-file-name x protocols))
                             '("stable/xdg-shell/xdg-shell.xml"
                               "unstable/text-input/\
text-input-unstable-v3.xml"))))
                 (dir (and gcc scanner flags xmls
                           (file-readable-p source)
                           (cl-every #'file-readable-p xmls)
                           (make-temp-file "cmacs-rig-field-" t)))
                 (out (and dir (expand-file-name "cmacs-rig-field" dir))))
            (when out
              (with-temp-buffer
                (let ((log (current-buffer)) (codes nil) (ok t))
                  (dolist (xml xmls)
                    (let* ((stem (expand-file-name (file-name-base xml) dir))
                           (header (concat stem ".h"))
                           (code (concat stem ".c")))
                      (setq ok (and ok
                                    (cmacs-rig--run log scanner
                                                    "client-header" xml
                                                    header)
                                    (cmacs-rig--run log scanner
                                                    "private-code" xml code)))
                      (push code codes)))
                  (setq ok (and ok
                                (apply #'cmacs-rig--run log gcc
                                       "-std=gnu89" "-O1" "-Wall" "-Wextra"
                                       (concat "-I" dir) "-o" out source
                                       (append (nreverse codes) flags))))
                  (cond
                   (ok
                    (unless (string-empty-p (string-trim (buffer-string)))
                      (message "cmacs-rig-field.c: %s" (buffer-string)))
                    (add-hook 'kill-emacs-hook
                              (lambda ()
                                (ignore-errors (delete-directory dir t))))
                    out)
                   (t
                    (message "cmacs-rig: cannot build the field client:\n%s"
                             (buffer-string))
                    (ignore-errors (delete-directory dir t))
                    nil))))))))
  cmacs-rig--field-client)

(cl-defun cmacs-rig-spawn-field (rig &key (title "rig-field")
                                     (app-id "rig-field") (text "") password
                                     idle)
  "Open a window that is one text field in RIG; return a plist for it.
:id is the window's gowl id and :dump a file the program rewrites with
the field's text whenever it changes -- what the APPLICATION holds, as
opposed to what the compositor believes it holds.  TEXT is what the
field starts with, the cursor after it; PASSWORD declares it a
password field.

The program pings the compositor every 20 ms, as a desktop with
anything alive on it does, unless IDLE: then it is silent between
events and the compositor's event loop sleeps.  See `rig_field_run' in
cmacs-rig-field.c for what that difference shows."
  (let* ((program (or (cmacs-rig-field-client)
                      (signal 'cmacs-rig-error
                              (list "the field client cannot be built"))))
         (dump (make-temp-file (expand-file-name "field-"
                                                 (cmacs-rig-base rig))
                               nil ".txt"))
         (id (cmacs-rig-spawn
              rig (append (list program "--title" title "--app-id" app-id
                                "--text" text "--dump" dump)
                          (and password '("--password"))
                          (and (not idle) '("--heartbeat" "20"))))))
    (list :id id :dump dump :title title :app-id app-id)))

(defun cmacs-rig-field-text (field)
  "Return what the application of FIELD holds in its field right now."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents (plist-get field :dump)))
    (buffer-string)))

(defun cmacs-rig-wait-field-text (rig field text &optional seconds)
  "Wait until FIELD's application holds exactly TEXT; return TEXT.
Signals `cmacs-rig-timeout' saying what it holds instead."
  (or (cmacs-rig--wait (or seconds 5)
                       (lambda () (equal (cmacs-rig-field-text field) text)))
      (signal 'cmacs-rig-timeout
              (list (format "the field holds %S, not %S; %s"
                            (cmacs-rig-field-text field) text
                            (cmacs-rig-describe rig)))))
  text)

(provide 'cmacs-rig)

;;; cmacs-rig.el ends here
