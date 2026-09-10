;;; cmacs-clawtilla.el --- Drive a clawtilla agent fleet from cmacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak

;; This file is part of CMacs.

;; CMacs is free software: you can redistribute it and/or modify it
;; under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; CMacs is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public
;; License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with CMacs.  If not, see <https://www.gnu.org/licenses/>.

;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The connection layer every other cmacs-clawtilla file sits on: open a
;; link to a daemon, send it frames, and route what it says back.
;;
;; A client, not a daemon.  The normal use is a clawtillad that is
;; already running -- on this machine over its unix socket, or on
;; another one over TCP -- and `cmacs-clawtilla-start-daemon' exists for
;; the case where there is none, deliberately as a command you run
;; rather than something connecting does for you.  Starting a fleet is
;; not a side effect of looking at one.
;;
;; Saved profiles are clawtilla's own `connections.yaml', read through
;; the library rather than parsed here, so a profile added in the GTK
;; client is simply present and the description that hides the token is
;; the library's rather than a second one that could fail to.
;;
;; Everything is asynchronous, and not as a style choice: the library's
;; blocking request turns the caller's main context while it waits, and
;; here that context is the editor's -- under `--gowl' it is also the
;; compositor's, so one slow remote daemon would freeze the desktop.
;; There is no synchronous primitive to reach for by accident.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function cmacs-clawtilla-supported-p "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--default-socket "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--connect-local "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--connect-tcp "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--connect-profile "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--connections "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--saved-connections "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--connections-path "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--request "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--subscribe "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--disconnect "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--close "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--connected-p "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--reconnecting-p "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--set-auto-reconnect "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--cursor "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--link-notice "cmacs-clawtilla-defuns.c")
(declare-function cmacs-clawtilla--enum "cmacs-clawtilla-defuns.c")

(defgroup cmacs-clawtilla nil
  "Drive a clawtilla agent fleet from cmacs."
  :group 'cmacs
  :prefix "cmacs-clawtilla-")

(defcustom cmacs-clawtilla-daemon-program "clawtillad"
  "The daemon binary `cmacs-clawtilla-start-daemon' runs."
  :type 'string
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-auto-reconnect t
  "Whether a dropped connection is retried on its own.

A laptop that suspends or a tailnet that moves takes the link with it,
and the daemon is usually still there when it comes back."
  :type 'boolean
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-request-timeout 30
  "Seconds to wait for a reply before giving up on it.

Only the bookkeeping here gives up.  The frame stays sent, so a reply
that arrives afterwards is discarded rather than mistaken for the
answer to whatever was asked next."
  :type 'integer
  :group 'cmacs-clawtilla)

(defcustom cmacs-clawtilla-connect-hook nil
  "Functions called with one connection once its link comes up."
  :type 'hook
  :group 'cmacs-clawtilla)


;;;; The connection object.

(cl-defstruct (cmacs-clawtilla-connection
               (:constructor cmacs-clawtilla--connection-create)
               (:copier nil))
  "One link to one daemon."
  handle
  name
  describe
  local-p
  ;; `connecting', `connected', `disconnected' or `resync'.
  (state 'connecting)
  ;; Whether this link was ever up.  The library cannot tell "never
  ;; reached" from "was there and went away" once it is down, and the
  ;; two have different remedies -- only one of which is on this
  ;; machine -- so the answer is remembered here.
  (ever-connected nil)
  (cursor 0)
  ;; When this link came up.  The unread rule needs it: without it,
  ;; connecting to a fleet marks its whole history unread and the count
  ;; can never be cleared by reading.
  (connected-at 0)
  ;; Caches, refilled from the daemon rather than derived from events.
  (agents nil)
  (teams nil)
  (rooms nil)
  ;; Callbacks waiting on a reply, keyed by nothing: the C layer owns
  ;; correlation.  This is only the timeout bookkeeping.
  (pending 0))

(defvar cmacs-clawtilla-connections nil
  "Every open connection, newest first.")

(defvar-local cmacs-clawtilla-connection nil
  "The connection this buffer belongs to.")

(defun cmacs-clawtilla--connection-by-handle (handle)
  "Return the connection whose handle is HANDLE, or nil."
  (seq-find (lambda (conn)
              (equal (cmacs-clawtilla-connection-handle conn) handle))
            cmacs-clawtilla-connections))

(defun cmacs-clawtilla-current ()
  "Return the connection to act on, or signal.

The buffer's own if it has one, otherwise the only one that is open.
With several open and no buffer to say which, asking is better than
picking: acting on the wrong fleet is not something you notice."
  (or cmacs-clawtilla-connection
      (pcase cmacs-clawtilla-connections
        ('nil (user-error "Not connected to a clawtilla daemon; %s"
                          "M-x cmacs-clawtilla-connect"))
        (`(,only) only)
        (_ (cmacs-clawtilla-read-connection "Fleet: ")))))

(defun cmacs-clawtilla-read-connection (prompt)
  "Read one open connection with PROMPT."
  (let* ((names (mapcar (lambda (conn)
                          (cons (cmacs-clawtilla-connection-label conn) conn))
                        cmacs-clawtilla-connections))
         (choice (completing-read prompt names nil t)))
    (cdr (assoc choice names))))

(defun cmacs-clawtilla-connection-label (conn)
  "Return a one-line label for CONN."
  (format "%s (%s)"
          (or (cmacs-clawtilla-connection-name conn) "daemon")
          (pcase (cmacs-clawtilla-connection-state conn)
            ('connected "connected")
            ('connecting "connecting")
            ('resync "resyncing")
            (_ (if (cmacs-clawtilla--reconnecting-p
                    (cmacs-clawtilla-connection-handle conn))
                   "reconnecting"
                 "offline")))))


;;;; JSON.

(defun cmacs-clawtilla--parse (json)
  "Parse JSON into an alist, or nil.

Object keys arrive as symbols, which is what every caller here
expects; a malformed reply is nil rather than an error, because the
only thing that could have produced one is the daemon and there is
nothing a backtrace here would tell anybody."
  (and (stringp json)
       (condition-case nil
           (json-parse-string json :object-type 'alist :array-type 'list
                              :null-object nil :false-object nil)
         (error nil))))

(defun cmacs-clawtilla--encode (payload)
  "Encode PAYLOAD, an alist or plist, as a JSON string.

nil is nil rather than \"{}\": the daemon distinguishes a frame with no
payload from one with an empty object, and so does the reply."
  (cond
   ((null payload) nil)
   ((stringp payload) payload)
   (t (json-serialize (cmacs-clawtilla--as-alist payload)))))

(defun cmacs-clawtilla--as-alist (payload)
  "Return PAYLOAD as an alist whether it arrived as one or as a plist.

Accepting both shapes here rather than at each call site, because a
call site that picks a representation per caller has to enumerate them
and that list is always one short."
  (if (and (consp payload) (consp (car payload)))
      payload
    (cl-loop for (key value) on payload by #'cddr
             collect (cons (if (keywordp key)
                               (intern (substring (symbol-name key) 1))
                             key)
                           value))))

(defun cmacs-clawtilla-get (data &rest path)
  "Walk PATH through DATA, an alist from `cmacs-clawtilla--parse'."
  (let ((node data))
    (dolist (key path node)
      (setq node (cond
                  ((and (listp node) (not (null node))
                        (consp (car node)))
                   (alist-get key node))
                  ((and (listp node) (integerp key)) (nth key node))
                  (t nil))))))


;;;; Requests.

(defun cmacs-clawtilla-request (conn kind &optional payload callback)
  "Send KIND with PAYLOAD on CONN and call CALLBACK with the reply.

CALLBACK receives (DATA ERROR): the reply's payload as an alist, or nil
and a string.  A daemon that answers `ok: false' is an error here even
though the transport succeeded -- a caller that had to check both would
eventually check one.

Returns nil without sending if CONN has no live link, so a command run
against a fleet that went away says so rather than waiting out the
timeout."
  (let ((handle (cmacs-clawtilla-connection-handle conn)))
    (unless (cmacs-clawtilla--connected-p handle)
      (user-error "%s" (cmacs-clawtilla-link-notice conn)))
    (cmacs-clawtilla--request
     handle kind (cmacs-clawtilla--encode payload)
     (lambda (json error)
       (cmacs-clawtilla--handle-reply json error callback)))))

(defun cmacs-clawtilla--handle-reply (json error callback)
  "Turn a raw reply into (DATA ERROR) and hand it to CALLBACK."
  (when callback
    (if error
        (funcall callback nil error)
      (let* ((data (cmacs-clawtilla--parse json))
             (ok (cmacs-clawtilla-get data 'ok))
             (message (cmacs-clawtilla-get data 'error)))
        ;; `ok' absent means this is a bare payload rather than a whole
        ;; envelope -- the C layer hands back what the library gave it,
        ;; and eleven handlers answer with no payload at all.
        (if (and (assq 'ok data) (not ok))
            (funcall callback nil (or message "the daemon refused that"))
          (funcall callback (or (cmacs-clawtilla-get data 'payload) data)
                   nil))))))

(defun cmacs-clawtilla-request-raw (conn kind &optional payload callback)
  "Send KIND on CONN and call CALLBACK with the reply as JSON text.

For the one case that matters: anything handed back to C must be the
text the daemon sent, never a re-encoding of the parsed form.  See
`cmacs-clawtilla-member-json' for what goes wrong when it is not.

CALLBACK receives (JSON ERROR)."
  (let ((handle (cmacs-clawtilla-connection-handle conn)))
    (unless (cmacs-clawtilla--connected-p handle)
      (user-error "%s" (cmacs-clawtilla-link-notice conn)))
    (cmacs-clawtilla--request
     handle kind (cmacs-clawtilla--encode payload)
     (lambda (json error) (when callback (funcall callback json error))))))

(defun cmacs-clawtilla-member-json (json member)
  "Return MEMBER of the JSON object text JSON, itself as JSON text.

Parsed and re-encoded with the same null and false objects on both
sides, and with arrays as vectors.  Both halves are load-bearing.

The reader everything else uses maps JSON null to nil, and nil
re-encodes as an empty object -- so cutting a member out with it turns
an agent whose team is null into one whose team is an object.  The
fleet tally read exactly that member, and json-glib logged a CRITICAL
on every redraw while the counts on screen stayed right, because they
came from the parsed copy rather than from what was sent back.

Arrays come back as vectors rather than lists because a JSON array of
objects parsed as a list is a list of conses, which `json-serialize'
cannot tell from an alist.  It does not guess, it signals -- inside a
reply callback, where the signal is swallowed and the caller simply
sees nothing."
  (when (stringp json)
    (let* ((faithful (json-parse-string json
                                        :object-type 'alist
                                        :array-type 'array
                                        :null-object :json-null
                                        :false-object :json-false))
           (value (alist-get member faithful)))
      (when value
        (json-serialize value
                        :null-object :json-null
                        :false-object :json-false)))))

(defmacro cmacs-clawtilla-with-reply (spec &rest body)
  "Send a request and run BODY with the reply bound.

SPEC is (VAR CONN KIND [PAYLOAD]).  BODY runs with VAR bound to the
reply payload; an error is reported and BODY does not run.  This is the
shape nearly every caller wants, and writing it out each time is how
one of them ends up ignoring the error argument."
  (declare (indent 1) (debug ((symbolp form form &optional form) body)))
  (pcase-let ((`(,var ,conn ,kind ,payload) spec))
    `(cmacs-clawtilla-request
      ,conn ,kind ,payload
      (lambda (,var err)
        (if err
            (message "clawtilla: %s" err)
          (ignore ,var)
          ,@body)))))


;;;; Connecting.

(defun cmacs-clawtilla--adopt (handle name describe local-p)
  "Register HANDLE as a connection and return it."
  (let ((conn (cmacs-clawtilla--connection-create
               :handle handle :name name :describe describe
               :local-p local-p)))
    (push conn cmacs-clawtilla-connections)
    (cmacs-clawtilla--set-auto-reconnect handle cmacs-clawtilla-auto-reconnect)
    conn))

(defun cmacs-clawtilla--after-connect (conn error)
  "Finish opening CONN, or report ERROR."
  (if error
      (progn
        (setf (cmacs-clawtilla-connection-state conn) 'disconnected)
        (message "clawtilla: %s" error))
    (setf (cmacs-clawtilla-connection-state conn) 'connected)
    (setf (cmacs-clawtilla-connection-ever-connected conn) t)
    (setf (cmacs-clawtilla-connection-connected-at conn)
          (truncate (float-time)))
    ;; Subscribing from 0 asks for everything the daemon still has.  A
    ;; client that has been away does not know what it missed, and the
    ;; daemon answering `resumed: false' is how it finds out.
    (cmacs-clawtilla--subscribe
     (cmacs-clawtilla-connection-handle conn) 0
     (lambda (json err)
       (unless err
         (let ((data (cmacs-clawtilla--parse json)))
           (unless (cmacs-clawtilla-get data 'resumed)
             (setf (cmacs-clawtilla-connection-state conn) 'resync))))))
    (run-hook-with-args 'cmacs-clawtilla-connect-hook conn)
    (message "clawtilla: connected to %s"
             (or (cmacs-clawtilla-connection-name conn) "the daemon"))))

;;;###autoload
(defun cmacs-clawtilla-connect (&optional profile)
  "Connect to a clawtilla daemon.

With no argument, offers the saved profiles from clawtilla's own
connections file plus the local daemon.  PROFILE names a saved one.

This does not start anything.  A daemon that is not running is reported
as not running -- see `cmacs-clawtilla-start-daemon', which is a
separate decision because starting a fleet should not be a side effect
of looking at one."
  (interactive
   (list (let* ((saved (cmacs-clawtilla-saved-profiles))
                (names (append (mapcar (lambda (p)
                                         (format "%s  %s"
                                                 (alist-get 'name p)
                                                 (alist-get 'describe p)))
                                       saved)
                               (list "local  the daemon on this machine"))))
           (car (split-string
                 (completing-read "Connect to: " names nil t) "  " t)))))
  (if (or (null profile) (equal profile "local"))
      (cmacs-clawtilla-connect-local)
    (cmacs-clawtilla-connect-profile profile)))

(defun cmacs-clawtilla-connect-local (&optional socket)
  "Connect to the daemon on this machine, at SOCKET or its default."
  (interactive)
  (let* ((conn nil)
         (handle (cmacs-clawtilla--connect-local
                  socket
                  (lambda (_payload error)
                    (cmacs-clawtilla--after-connect conn error)))))
    (unless handle
      (user-error "Could not open a connection to the local daemon"))
    (setq conn (cmacs-clawtilla--adopt
                handle "local"
                (or socket (cmacs-clawtilla--default-socket)) t))
    conn))

(defun cmacs-clawtilla-connect-profile (name)
  "Connect to the saved profile NAME."
  (interactive (list (completing-read
                      "Profile: "
                      (mapcar (lambda (p) (alist-get 'name p))
                              (cmacs-clawtilla-saved-profiles))
                      nil t)))
  (let* ((profile (seq-find (lambda (p) (equal (alist-get 'name p) name))
                            (cmacs-clawtilla-saved-profiles)))
         (conn nil)
         (handle (cmacs-clawtilla--connect-profile
                  name
                  (lambda (_payload error)
                    (cmacs-clawtilla--after-connect conn error)))))
    (when handle
      (setq conn (cmacs-clawtilla--adopt
                  handle name (alist-get 'describe profile)
                  (eq t (alist-get 'local profile))))
      conn)))

(defun cmacs-clawtilla-connect-remote (host port token &optional tls insecure)
  "Connect to a daemon at HOST and PORT using TOKEN.

TLS non-nil uses TLS; INSECURE non-nil accepts a certificate that does
not validate, which trusts whatever answers on that address."
  (interactive
   (list (read-string "Host: ")
         (read-number "Port: " 8792)
         (read-passwd "Token: ")
         (y-or-n-p "Use TLS? ")
         nil))
  (let* ((conn nil)
         (handle (cmacs-clawtilla--connect-tcp
                  host port token tls insecure
                  (lambda (_payload error)
                    (cmacs-clawtilla--after-connect conn error)))))
    (unless handle
      (user-error "Could not open a connection to %s:%d" host port))
    (setq conn (cmacs-clawtilla--adopt
                handle (format "%s:%d" host port)
                (format "%s:%d" host port) nil))
    conn))

(defun cmacs-clawtilla-saved-profiles ()
  "Return clawtilla's saved connection profiles as alists."
  (or (cmacs-clawtilla--parse (cmacs-clawtilla--connections)) nil))

(defun cmacs-clawtilla-link-notice (conn)
  "Return what to tell someone about CONN's link."
  (cmacs-clawtilla--link-notice
   (cmacs-clawtilla-connection-handle conn)
   (cmacs-clawtilla-connection-name conn)
   (cmacs-clawtilla-connection-ever-connected conn)))

(defun cmacs-clawtilla-status (&optional conn)
  "Report what CONN's daemon says about itself.

Two counts of agents, and they mean different things: how many the
configuration declares, and how many have a link dialled in right now.
An agent that is configured and not connected is the ordinary case, so
a client showing only one of them reports either a fleet that is always
broken or one that is always fine."
  (interactive)
  (let ((conn (or conn (cmacs-clawtilla-current))))
    (cmacs-clawtilla-request
     conn "control.status" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (message "clawtilla %s: %s configured, %s connected, %s client%s%s"
                  (cmacs-clawtilla-get data 'version)
                  (cmacs-clawtilla-get data 'agents)
                  (cmacs-clawtilla-get data 'connected)
                  (cmacs-clawtilla-get data 'clients)
                  (if (eql 1 (cmacs-clawtilla-get data 'clients)) "" "s")
                  (if (eq t (cmacs-clawtilla-get data 'hold 'held))
                      "; fleet held" "")))))))

(defun cmacs-clawtilla-disconnect (&optional conn)
  "Close CONN and forget it."
  (interactive)
  (let* ((conn (or conn (cmacs-clawtilla-current)))
         (handle (cmacs-clawtilla-connection-handle conn)))
    (cmacs-clawtilla--set-auto-reconnect handle nil)
    (cmacs-clawtilla--disconnect handle)
    (cmacs-clawtilla--close handle)
    (setq cmacs-clawtilla-connections
          (delq conn cmacs-clawtilla-connections))
    (message "clawtilla: disconnected")))


;;;; Events.

(defvar cmacs-clawtilla-event-hook nil
  "Functions called with (CONNECTION KIND DATA) for each daemon event.

Separate from the C-level `cmacs-clawtilla-event-functions' so handlers
here see a connection object and parsed data rather than a handle and a
string.")

(defvar cmacs-clawtilla-state-hook nil
  "Functions called with (CONNECTION STATE) when a link changes.")

(defun cmacs-clawtilla--on-event (handle kind json)
  "Route a daemon event on HANDLE of KIND carrying JSON."
  (when-let* ((conn (cmacs-clawtilla--connection-by-handle handle)))
    (setf (cmacs-clawtilla-connection-cursor conn)
          (cmacs-clawtilla--cursor handle))
    (run-hook-with-args 'cmacs-clawtilla-event-hook conn kind
                        (cmacs-clawtilla--parse json))))

(defun cmacs-clawtilla--on-state (handle state)
  "Note that HANDLE's link moved to STATE."
  (when-let* ((conn (cmacs-clawtilla--connection-by-handle handle)))
    (let ((sym (intern state)))
      (setf (cmacs-clawtilla-connection-state conn) sym)
      (when (eq sym 'connected)
        (setf (cmacs-clawtilla-connection-ever-connected conn) t))
      (run-hook-with-args 'cmacs-clawtilla-state-hook conn sym))))

(add-hook 'cmacs-clawtilla-event-functions #'cmacs-clawtilla--on-event)
(add-hook 'cmacs-clawtilla-state-functions #'cmacs-clawtilla--on-state)


;;;; Enumerations.

(defvar cmacs-clawtilla--enum-cache (make-hash-table :test 'equal))

(defun cmacs-clawtilla-enum (family)
  "Return the values libclawt enumerates for FAMILY.

Asked for, never written down: clawtilla's `make parity' fails a client
that spells any of these values out, because holding a copy of the list
is what lets a client disagree with it.  Cached because the answer
cannot change inside one process."
  (or (gethash family cmacs-clawtilla--enum-cache)
      (puthash family
               (cmacs-clawtilla--parse (cmacs-clawtilla--enum family))
               cmacs-clawtilla--enum-cache)))

(defun cmacs-clawtilla-enum-nicks (family)
  "Return just the nicks of FAMILY."
  (mapcar (lambda (entry) (alist-get 'nick entry))
          (cmacs-clawtilla-enum family)))


;;;; Running a daemon.

(defvar cmacs-clawtilla--daemon-process nil
  "The daemon `cmacs-clawtilla-start-daemon' started, if any.")

;;;###autoload
(defun cmacs-clawtilla-start-daemon (&optional config)
  "Start a clawtilla daemon from inside cmacs, using CONFIG.

Deliberately a command and not something `cmacs-clawtilla-connect'
does for you.  The usual arrangement is a daemon that outlives the
editor -- started by systemd, or already running for the GTK client --
and a fleet quietly starting because somebody opened a buffer is both
surprising and expensive: agents have computers, and starting one
builds a container or boots a VM.

The process is bound to this Emacs.  Quitting the editor stops the
fleet, which is the other reason this is not the normal path."
  (interactive)
  (when (process-live-p cmacs-clawtilla--daemon-process)
    (user-error "A clawtilla daemon started from here is already running"))
  (unless (executable-find cmacs-clawtilla-daemon-program)
    (user-error "No %s on PATH" cmacs-clawtilla-daemon-program))
  (let ((buffer (get-buffer-create "*clawtilla daemon*")))
    (setq cmacs-clawtilla--daemon-process
          (make-process
           :name "clawtillad"
           :buffer buffer
           :command (append (list cmacs-clawtilla-daemon-program
                                  "--foreground")
                            (when config (list "--config" config)))
           :noquery nil
           :sentinel #'cmacs-clawtilla--daemon-sentinel))
    (message "clawtilla: daemon starting; %s"
             "M-x cmacs-clawtilla-connect when it is up")
    cmacs-clawtilla--daemon-process))

(defun cmacs-clawtilla--daemon-sentinel (process event)
  "Report that the daemon PROCESS ended with EVENT."
  (unless (process-live-p process)
    (message "clawtilla: daemon %s" (string-trim event))))

(defun cmacs-clawtilla-stop-daemon ()
  "Stop the daemon started by `cmacs-clawtilla-start-daemon'.

Only that one.  A daemon somebody else started -- systemd, a terminal,
the GTK client -- is not this command's to stop, and stopping a fleet
you did not start is not a mistake you can take back."
  (interactive)
  (unless (process-live-p cmacs-clawtilla--daemon-process)
    (user-error "No daemon was started from here"))
  (interrupt-process cmacs-clawtilla--daemon-process))

(provide 'cmacs-clawtilla)

;;; cmacs-clawtilla.el ends here
