;;; cmacs-brigade-desktop.el --- A desktop of its own for each agent  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; An agent that drives GUI programs on the screen you are sitting at
;; fights you for the pointer and the focus.  This gives each brigade
;; agent a screen nobody is sitting at instead: a private, headless gowl
;; with its own Wayland socket, seat, focus and clipboard.  The agent's
;; programs open there, the agent looks at it and drives it through
;; gowl's own MCP server, and you can watch it
;; (`cmacs-brigade-desktop-view') and take it over.
;;
;; The design is clawtilla's "display computer" (deps/clawtilla,
;; docs/computers.org, the `gowl' backend), restated in Elisp so a brigade
;; agent needs no clawtilla daemon:
;;
;;   - gowl is started as `gowl --config DIR/gowl.yaml --no-c-config' with
;;     WLR_BACKENDS=headless, the pixman renderer and an XDG_RUNTIME_DIR
;;     of its own, so its sockets are never the ones your session uses.
;;   - The generated gowl.yaml turns on exactly two modules, `ipc' and
;;     `mcp' (unix socket only, no HTTP port).  None of your gowl
;;     configuration is read.
;;   - It is up when `gowl.sock' and `gowl-mcp.sock' exist.
;;   - Programs get WAYLAND_DISPLAY as the socket's ABSOLUTE path, which
;;     survives a sandbox that replaces XDG_RUNTIME_DIR.
;;   - A sandbox is given the Wayland socket FILE and never the directory:
;;     the directory also holds gowl.sock and gowl-mcp.sock, and both
;;     answer `spawn' by running a command outside any box.
;;
;; Nothing here blocks.  cmacs may itself be the compositor of the
;; session (`emacs --gowl'), where a blocked Emacs is a frozen desktop,
;; so the binary is probed, started and waited for with processes,
;; sentinels and timers, and every call to the nested gowl is a network
;; process with a callback.  The one exception is `desktop-podman', whose
;; container cannot be created before the socket it mounts exists; see
;; `cmacs-brigade-desktop--podman-prepare'.
;;
;; Three things reach an agent:
;;
;;   1. An environment (the isolation provider's :env) that points its
;;      own processes at the desktop.
;;   2. Brigade tools -- desktop_screenshot, desktop_click and friends --
;;      which act on the CALLING task's desktop and take no desktop
;;      argument at all, so one agent cannot name another's.
;;   3. A filtered relay of gowl's own MCP server on a socket of the
;;      desktop's own (relay.sock), for a CLI agent's MCP config.  The
;;      relay offers only what the agent was granted and refuses acting
;;      tools while a person holds the desktop.
;;
;; A CLI agent gets all three.  The run hands the provider's
;; :mcp-servers to `cmacs-brigade-host-provision', which writes them in
;; the agent's config dialect, and opens the agent's scoped socket for
;; the task -- so a `desktop_*' call arriving over MCP is made for that
;; task, by the editor's record and not the client's say-so.

;;; Code:

(require 'cmacs-brigade)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-agent-def)
(require 'cl-lib)
(require 'subr-x)

;; Loaded lazily by the composed providers; requiring it here would be a
;; cycle, because cmacs-brigade-isolation.el loads this file.
(declare-function cmacs-brigade-isolation--worktree-prepare
                  "cmacs-brigade-isolation" (agent-id))
(declare-function cmacs-brigade-isolation--worktree-teardown
                  "cmacs-brigade-isolation" (agent-id))
(declare-function cmacs-brigade-isolation--podman-prepare
                  "cmacs-brigade-isolation" (agent-id))
(declare-function cmacs-brigade-isolation--podman-teardown
                  "cmacs-brigade-isolation" (agent-id))
(declare-function cmacs-brigade-agent-base-name "cmacs-brigade-agent-def"
                  (name))
(defvar cmacs-brigade-isolation-podman-extra-args)
(defvar cmacs-brigade--runs)

(define-error 'cmacs-brigade-desktop-error
  "Agent desktop error" 'cmacs-brigade-error)

(defgroup cmacs-brigade-desktop nil
  "A private, headless desktop for each brigade agent."
  :group 'cmacs-brigade
  :prefix "cmacs-brigade-desktop-")


;;;; Options

(defcustom cmacs-brigade-desktop-gowl-program nil
  "The gowl binary an agent desktop runs, or nil to search for one.

The search is the in-tree build first (deps/gowl/build/release, then
debug, under `cmacs-brigade-desktop-source-directory'), then every
`gowl' on `exec-path' in order.  Each candidate has to answer
`--version' before it is trusted, and one that says it has no `mcp'
module is passed over, because a desktop that cannot be looked at or
driven is no use.

A path set here is used instead of searching.  It must still answer
`--version'."
  :type '(choice (const :tag "Search" nil) file)
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-source-directory nil
  "The cmacs source tree whose deps/gowl build is tried first.
nil means `source-directory'."
  :type '(choice (const :tag "This build's source tree" nil) directory)
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-relay-program nil
  "The `gowl-mcp' relay binary named in an agent's MCP config, or nil to search.
It bridges stdin and stdout to a unix socket; here it is pointed at the
desktop's filtered relay socket, never at gowl's own."
  :type '(choice (const :tag "Search" nil) file)
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-resolution "1280x800"
  "Size of an agent desktop's one output, as WIDTHxHEIGHT.
Each side is 64 to 8192.  A bigger screen costs more per picture, and
every picture an agent asks for is part of its turn."
  :type 'string
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-scale 1.0
  "Output scale of an agent desktop.

1.0 keeps the agent's coordinates equal to the picture's pixels, which
is what a model clicking on a screenshot expects; leave it there unless
the programs it runs are unreadably small.  Any other value is applied
over gowl's IPC socket (`monitor.configure') once the desktop is up, and
the desktop's layout is then the resolution divided by the scale."
  :type 'number
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-directory
  (expand-file-name "desktops" cmacs-brigade-state-dir)
  "Where agent desktops keep their files, one directory per desktop.

Each holds gowl.yaml, server.log, relay.sock and run/ (gowl's own
sockets).  The directories are 0700.  The path has to be short: a unix
socket address is 108 bytes, and a desktop whose sockets would not fit
is refused at start with the path named."
  :type 'directory
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-start-timeout 15
  "Seconds gowl is given to open its sockets before the start is failed."
  :type 'number
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-call-timeout 30
  "Seconds one call to an agent desktop may take before it is abandoned."
  :type 'number
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-use-pdeathsig t
  "Whether gowl is started under `setpriv --pdeathsig SIGTERM'.

With it the kernel ends the desktop when cmacs dies for any reason,
including a crash, which `kill-emacs-hook' cannot cover.  Ignored when
`setpriv' is not installed."
  :type 'boolean
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-grants '(look act spawn)
  "What an agent may do on its own desktop, unless its name says otherwise.

`look'   screenshots, window lists, reading text off the screen
`act'    keys, text, the pointer, scrolling, focusing, closing and
         placing windows
`spawn'  starting programs

All three are on by default because the screen is private: nobody is
working there.  Input recording is never granted, whatever is written
here.  A tool outside an agent's grants is not offered to it at all."
  :type '(set (const look) (const act) (const spawn))
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-agent-grants nil
  "Per-agent grants, an alist of (AGENT-NAME . GRANTS).
AGENT-NAME is a symbol or string naming an agent definition; GRANTS is
as `cmacs-brigade-desktop-grants'.  An agent not listed gets the default.

  (setq cmacs-brigade-desktop-agent-grants \\='((reviewer look)))"
  :type '(alist :key-type (choice symbol string)
                :value-type (set (const look) (const act) (const spawn)))
  :group 'cmacs-brigade-desktop)

(defcustom cmacs-brigade-desktop-podman-args nil
  "Extra `podman run' arguments for `desktop-podman' isolation.

The provider already mounts the desktop's Wayland socket file and sets
the three variables a Wayland program needs.  On a host with SELinux
enforcing, a container may still be denied the connection; whether to
relax that -- (\"--security-opt\" \"label=disable\") is the usual way -- is
a decision this does not make for you."
  :type '(repeat string)
  :group 'cmacs-brigade-desktop)

(defvar cmacs-brigade-desktop-changed-functions nil
  "Abnormal hook run with a desktop's id when its state changes.
Started, ready, failed, stopped, taken or released.  The viewer and the
dashboard redraw from it.")


;;;; The record

(cl-defstruct (cmacs-brigade-desktop
               (:constructor cmacs-brigade-desktop--make)
               (:conc-name cmacs-brigade-desktop--)
               (:copier nil))
  "One agent desktop."
  id              ; the agent/task id it belongs to
  dir             ; its state directory
  run-dir         ; gowl's XDG_RUNTIME_DIR
  config          ; gowl.yaml
  log-file        ; server.log
  (log-tail "")   ; gowl's last lines, for saying why it died
  width height    ; the output's pixels
  (scale 1.0)
  layout-width layout-height      ; what coordinates are in
  program         ; the gowl that was chosen
  process         ; the gowl process
  (state 'locating)               ; locating starting ready failed stopped
  reason          ; why it failed
  notes           ; candidates passed over, and other things worth saying
  wayland         ; the Wayland socket's absolute path
  mcp-socket ipc-socket
  relay-socket relay relay-clients
  timer deadline
  waiters         ; functions called with non-nil when ready, nil when not
  held            ; non-nil while a person has taken control
  started)

(defvar cmacs-brigade-desktop--table (make-hash-table :test 'equal)
  "Desktop id -> `cmacs-brigade-desktop' record.")

(defun cmacs-brigade-desktop--get (id)
  "Return the desktop record for ID, or nil."
  (and id (gethash (format "%s" id) cmacs-brigade-desktop--table)))

(defun cmacs-brigade-desktop--changed (desktop)
  "Tell whoever is watching that DESKTOP changed."
  (run-hook-with-args 'cmacs-brigade-desktop-changed-functions
                      (cmacs-brigade-desktop--id desktop)))


;;;; Pure parts: paths, the config, the environments

(defconst cmacs-brigade-desktop--sun-path-max 108
  "Bytes in a unix socket address, the terminating NUL included.")

(defun cmacs-brigade-desktop--parse-resolution (text)
  "Return (WIDTH . HEIGHT) for TEXT, \"1280x800\", or nil when it is not one.
Each side is 64 to 8192, which is what clawtilla accepts."
  (when (and (stringp text)
             (string-match "\\`\\([0-9]+\\)[xX]\\([0-9]+\\)\\'" text))
    (let ((w (string-to-number (match-string 1 text)))
          (h (string-to-number (match-string 2 text))))
      (and (<= 64 w 8192) (<= 64 h 8192) (cons w h)))))

(defun cmacs-brigade-desktop--dir-name (id)
  "Return a directory name for the desktop ID.
An id that is already a plain file name is used as it is, so the
directory can be recognised; anything else -- a slash, a space, a
leading dot -- becomes a hash, because an id reaches here from a plan
file and must not be able to name a path."
  (if (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._@-]\\{0,47\\}\\'" id)
      id
    (concat "x-" (substring (secure-hash 'sha1 id) 0 16))))

(defun cmacs-brigade-desktop--check-socket-path (path)
  "Signal when PATH is too long to be a unix socket address.
The message names the path: \"File name too long\" from bind(2) says
neither which socket nor that a socket was involved."
  (let ((bytes (length (encode-coding-string path 'utf-8))))
    (when (>= bytes cmacs-brigade-desktop--sun-path-max)
      (signal 'cmacs-brigade-desktop-error
              (list (format "%s is %d bytes, and a unix socket address holds %d; set `cmacs-brigade-desktop-directory' to a shorter path"
                            path bytes
                            (1- cmacs-brigade-desktop--sun-path-max)))))
    path))

(defun cmacs-brigade-desktop--config-yaml ()
  "Return the gowl.yaml an agent desktop runs with.

The IPC module for starting programs, the MCP module for pictures and
input.  The MCP module's unix socket only: an HTTP port would be one
more thing listening that nobody asked for."
  (concat
   "# Written by cmacs for an agent's headless desktop; rewritten at start.\n"
   "modules:\n"
   "  ipc:\n"
   "    enabled: true\n"
   "  mcp:\n"
   "    enabled: true\n"
   "    transport-stdio: true\n"
   "    transport-http: false\n"))

(defun cmacs-brigade-desktop--environment (run-dir width height)
  "Return `process-environment' entries for a gowl drawing into memory.

RUN-DIR becomes its XDG_RUNTIME_DIR, so its sockets are not the
session's (a second gowl would otherwise replace gowl.sock under a
running one).  The backend is named outright: left to choose, wlroots
would find WAYLAND_DISPLAY and open a window on your screen.  The bare
names at the end unset what must not be inherited."
  (list (concat "XDG_RUNTIME_DIR=" run-dir)
        "WLR_BACKENDS=headless"
        "WLR_HEADLESS_OUTPUTS=1"
        "WLR_RENDERER=pixman"
        "WLR_LIBINPUT_NO_DEVICES=1"
        (format "GOWL_OUTPUT_SIZE=%dx%d" width height)
        "GOWL_DISABLE_SYSTEMD=1"
        "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
        "GOWL_SOCKET" "GOWL_MCP_SOCKET"))

(defun cmacs-brigade-desktop--app-environment (wayland)
  "Return an alist of variables that point a program at the socket WAYLAND.

WAYLAND is an absolute path, which libwayland takes as it is and which
therefore survives a sandbox that replaces XDG_RUNTIME_DIR.  DISPLAY is
emptied: the nested gowl's XWayland display is known only to gowl, and
leaving yours in place would let an X program open on your screen."
  (list (cons "WAYLAND_DISPLAY" wayland)
        (cons "GDK_BACKEND" "wayland")
        (cons "QT_QPA_PLATFORM" "wayland")
        (cons "DISPLAY" "")))

(defun cmacs-brigade-desktop--wayland-path (run-dir)
  "Return the Wayland socket a gowl started in RUN-DIR will open.
RUN-DIR is emptied before each start and holds nothing but that gowl's
files, so the first free name is always wayland-0.  Knowing it ahead of
time is what lets the environment be handed to an agent before gowl has
finished starting; `cmacs-brigade-desktop--poll' checks the guess."
  (expand-file-name "wayland-0" run-dir))


;;;; Grants

(defconst cmacs-brigade-desktop-tool-classes
  '((look "list_clients" "list_monitors" "get_tag_state" "get_config"
          "list_keybinds" "list_modules" "get_focused_client"
          "describe_desktop" "find_window" "get_client_process_info"
          "screenshot_client" "screenshot_monitor" "screenshot_region"
          "screen_text" "pick_color"
          "desktop_screenshot" "desktop_windows" "desktop_text")
    (act "focus_client" "close_client" "move_client_to_tag"
         "set_client_state" "resize_client" "move_client" "swap_clients"
         "zoom_client" "view_tag" "toggle_tag_view" "set_client_tags"
         "set_mfact" "set_nmaster"
         "send_key" "send_text" "send_mouse" "send_mouse_move"
         "send_scroll"
         "desktop_key" "desktop_type" "desktop_click" "desktop_scroll")
    (spawn "spawn" "desktop_launch")
    (recording "start_recording" "drain_recording" "stop_recording"
               "recording_status" "macro_record"))
  "Which grant each tool needs: gowl's own MCP tools and the brigade's.

A tool that appears nowhere here is not relayed.  That is deliberate:
gowl's server also has `compositor_quit', `signal_client', `add_keybind',
the clipboard history and the macro, broadcast and input-remap tools,
and a tool gowl gains later should have to be put in a class by somebody
before an agent can call it.")

(defun cmacs-brigade-desktop--tool-class (tool)
  "Return the grant TOOL needs, or nil for a tool that is never relayed."
  (car (cl-find-if (lambda (class) (member tool (cdr class)))
                   cmacs-brigade-desktop-tool-classes)))

(defun cmacs-brigade-desktop-grants-for (agent)
  "Return the grants of the agent named AGENT, a symbol, string or nil."
  (let* ((name (and agent (format "%s" agent)))
         (base (and name (fboundp 'cmacs-brigade-agent-base-name)
                    (format "%s" (cmacs-brigade-agent-base-name name))))
         (cell (cl-find-if (lambda (c)
                             (member (format "%s" (car c)) (list name base)))
                           cmacs-brigade-desktop-agent-grants)))
    (if cell (cdr cell) cmacs-brigade-desktop-grants)))

(defun cmacs-brigade-desktop--tool-allowed-p (tool grants)
  "Whether GRANTS admit TOOL.  Recording is admitted by nothing."
  (let ((class (cmacs-brigade-desktop--tool-class tool)))
    (and (memq class '(look act spawn))
         (memq class grants)
         t)))

(defun cmacs-brigade-desktop--held-sentence (tool)
  "What an agent is told when TOOL is refused because a person holds the desktop."
  (format "A person has taken control of this desktop, so %s was not done.  Looking still works -- screenshots, window lists, reading text -- so wait and try again once they release it."
          tool))

(defun cmacs-brigade-desktop--refusal (desktop tool agent who)
  "Return why TOOL may not run on DESKTOP, or nil when it may.

AGENT names the caller for its grants.  WHO is `agent' or `human': a
person is not bound by an agent's grants, and is the one holding the
desktop when it is held."
  (let ((class (cmacs-brigade-desktop--tool-class tool)))
    (cond
     ((eq who 'human) nil)
     ((not (cmacs-brigade-desktop--tool-allowed-p
            tool (cmacs-brigade-desktop-grants-for agent)))
      (format "%s is not among the tools this agent was granted on its desktop."
              tool))
     ((and (cmacs-brigade-desktop--held desktop)
           (memq class '(act spawn)))
      (cmacs-brigade-desktop--held-sentence tool)))))

(defun cmacs-brigade-desktop--agent-of (desktop)
  "Return the name of the agent whose task DESKTOP belongs to, or nil.
Asked each time rather than stored: the run record is written after the
isolation is prepared, which is after the desktop was created."
  (and (boundp 'cmacs-brigade--runs)
       (hash-table-p cmacs-brigade--runs)
       (plist-get (gethash (cmacs-brigade-desktop--id desktop)
                           cmacs-brigade--runs)
                  :agent)))


;;;; A JSON-RPC line client
;;
;; Both of gowl's sockets speak newline-delimited JSON-RPC 2.0: the IPC
;; socket its own wire protocol (deps/gowl/docs/ipc.org), the MCP socket
;; the Model Context Protocol.  One connection per call, as clawtilla
;; does it: there is no session worth keeping, and a connection that is
;; gone when the call returns cannot be left half-read by the next one.

(defun cmacs-brigade-desktop--same-id-p (a b)
  "Whether the JSON-RPC ids A and B name the same request.
Compared as text: the mcp-glib in gowl 0.5.0 answers the request with id
1 as \"1\", and a client that insisted on the type would wait for ever
for a reply it had already been sent."
  (and a b (not (eq a :null)) (not (eq b :null))
       (equal (format "%s" a) (format "%s" b))))

(defun cmacs-brigade-desktop--rpc (socket requests callback &optional timeout)
  "Send REQUESTS to the unix socket SOCKET and call CALLBACK with the answer.

REQUESTS is a list of plists, each serialised as one line.  One with an
:id is a request and the next line is held back until its reply has
arrived; one without is a notification and is followed at once.
CALLBACK is called exactly once, with (t RESULT) where RESULT is the
last reply's `result' member, or with (nil MESSAGE).  Lines that answer
nothing asked here -- events, a server's own notifications -- are passed
over.

Returns at once; nothing here waits."
  (let* ((buffer (generate-new-buffer " *cmacs-brigade-desktop-rpc*" t))
         (queue (copy-sequence requests))
         (waiting nil) (result nil) (finished nil)
         (proc nil) (timer nil)
         finish advance)
    (setq finish
          (lambda (ok value)
            (unless finished
              (setq finished t)
              (when timer (cancel-timer timer))
              (when (processp proc) (delete-process proc))
              (when (buffer-live-p buffer) (kill-buffer buffer))
              (funcall callback ok value))))
    (setq advance
          (lambda ()
            (while (and queue (not waiting) (not finished))
              (let ((request (pop queue)))
                (setq waiting (plist-get request :id))
                (condition-case err
                    (process-send-string
                     proc (concat (json-serialize request) "\n"))
                  (error (funcall finish nil (error-message-string err))))))
            (unless (or queue waiting finished)
              (funcall finish t result))))
    (with-current-buffer buffer (set-buffer-multibyte nil))
    (condition-case err
        (progn
          (setq proc
                (make-network-process
                 :name "cmacs-brigade-desktop-rpc"
                 :buffer buffer :family 'local :service socket
                 :coding 'no-conversion :noquery t
                 :filter
                 (lambda (_proc chunk)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (goto-char (point-max))
                       (insert chunk)
                       (goto-char (point-min))
                       ;; A screenshot is megabytes on one line, so the
                       ;; line is cut out of a buffer rather than built
                       ;; by concatenating strings.
                       (while (and (not finished) (buffer-live-p buffer)
                                   (progn (goto-char (point-min))
                                          (search-forward "\n" nil t)))
                         (let* ((line (decode-coding-string
                                       (buffer-substring (point-min)
                                                         (1- (point)))
                                       'utf-8))
                                (reply (ignore-errors
                                         (json-parse-string
                                          line :object-type 'alist
                                          :array-type 'list
                                          :null-object nil
                                          :false-object nil))))
                           (delete-region (point-min) (point))
                           (when (and waiting (consp reply)
                                      (cmacs-brigade-desktop--same-id-p
                                       (alist-get 'id reply) waiting))
                             (setq waiting nil)
                             (if-let* ((problem (alist-get 'error reply)))
                                 (funcall finish nil
                                          (or (alist-get 'message problem)
                                              "no reason given"))
                               (setq result (alist-get 'result reply))
                               (funcall advance))))))))
                 :sentinel
                 (lambda (p _event)
                   (unless (process-live-p p)
                     (funcall finish nil
                              "the connection closed without an answer")))))
          (setq timer
                (run-at-time
                 (or timeout cmacs-brigade-desktop-call-timeout) nil
                 (lambda ()
                   (funcall finish nil
                            (format "no answer in %s seconds"
                                    (or timeout
                                        cmacs-brigade-desktop-call-timeout))))))
          (funcall advance))
      (error
       ;; Prefixed with the path: "Connection refused" alone does not say
       ;; which socket, or that a socket was involved at all.
       (funcall finish nil (format "cannot reach %s: %s" socket
                                   (error-message-string err)))))
    nil))

(defconst cmacs-brigade-desktop--mcp-protocol "2024-11-05"
  "The MCP protocol version offered to gowl's server.")

(defun cmacs-brigade-desktop--result-text (result)
  "Return the text in RESULT, an MCP tool result, joined by newlines."
  (mapconcat (lambda (item) (or (alist-get 'text item) ""))
             (cl-remove-if-not
              (lambda (item) (equal (alist-get 'type item) "text"))
              (alist-get 'content result))
             "\n"))

(defun cmacs-brigade-desktop--result-image (result)
  "Return the first image in RESULT as a unibyte string, or nil."
  (when-let* ((item (cl-find-if
                     (lambda (item) (equal (alist-get 'type item) "image"))
                     (alist-get 'content result)))
              (data (alist-get 'data item)))
    (ignore-errors (base64-decode-string data))))

(defun cmacs-brigade-desktop--mcp-call (socket tool arguments callback)
  "Call TOOL with ARGUMENTS on the MCP server at SOCKET.

ARGUMENTS is a plist or nil.  CALLBACK gets (t RESULT) or (nil MESSAGE).
A result flagged `isError' is a failure: MCP reports a tool's own
refusal inside a successful reply, and a caller that only looked at the
transport would take \"no such window\" for a picture."
  (cmacs-brigade-desktop--rpc
   socket
   (list (list :jsonrpc "2.0" :id 1 :method "initialize"
               :params (list :protocolVersion
                             cmacs-brigade-desktop--mcp-protocol
                             :capabilities nil
                             :clientInfo (list :name "cmacs"
                                               :version emacs-version)))
         ;; The notification the specification requires before any call.
         (list :jsonrpc "2.0" :method "notifications/initialized")
         (list :jsonrpc "2.0" :id 2 :method "tools/call"
               :params (append (list :name tool)
                               (and arguments
                                    (list :arguments arguments)))))
   (lambda (ok value)
     (cond
      ((not ok) (funcall callback nil value))
      ((alist-get 'isError value)
       (let ((text (cmacs-brigade-desktop--result-text value)))
         (funcall callback nil
                  (format "%s refused: %s" tool
                          (if (string-empty-p text) "no reason given"
                            text)))))
      (t (funcall callback t value))))))

(defun cmacs-brigade-desktop--ipc-call (socket method params callback)
  "Call METHOD with PARAMS on gowl's IPC socket SOCKET (its wire protocol).
PARAMS is a plist or nil.  CALLBACK gets (t RESULT) or (nil MESSAGE)."
  (cmacs-brigade-desktop--rpc
   socket
   (list (append (list :jsonrpc "2.0" :id 1 :method method)
                 (and params (list :params params))))
   callback))


;;;; Finding a gowl that runs

(defvar cmacs-brigade-desktop--trusted nil
  "(PROGRAM . MODIFICATION-TIME) of the gowl that last answered, or nil.
Saves probing it again for every desktop; a rebuilt binary is probed
afresh because its time changed.")

(defun cmacs-brigade-desktop--source-directory ()
  "Return the cmacs source tree to look for an in-tree gowl in, or nil."
  (let ((dir (or cmacs-brigade-desktop-source-directory
                 (bound-and-true-p source-directory))))
    (and dir (file-directory-p dir) dir)))

(defun cmacs-brigade-desktop--in-tree (name)
  "Return in-tree build paths of the gowl program NAME, release first."
  (when-let* ((root (cmacs-brigade-desktop--source-directory)))
    (mapcar (lambda (type)
              (expand-file-name (format "deps/gowl/build/%s/%s" type name)
                                root))
            '("release" "debug"))))

(defun cmacs-brigade-desktop--on-path (name)
  "Return every executable called NAME on `exec-path', in order."
  (let (found)
    (dolist (dir (append exec-path '("/usr/bin" "/usr/sbin")))
      (when (stringp dir)
        (let ((path (expand-file-name name dir)))
          (when (and (file-executable-p path)
                     (not (file-directory-p path)))
            (cl-pushnew (file-truename path) found :test #'equal)))))
    (nreverse found)))

(defun cmacs-brigade-desktop--candidates ()
  "Return the gowl binaries to try, in order."
  (if cmacs-brigade-desktop-gowl-program
      (list (expand-file-name cmacs-brigade-desktop-gowl-program))
    (delete-dups
     (append (cl-remove-if-not #'file-executable-p
                               (cmacs-brigade-desktop--in-tree "gowl"))
             (cmacs-brigade-desktop--on-path "gowl")))))

(defun cmacs-brigade-desktop--relay-command ()
  "Return the `gowl-mcp' relay binary, or nil when there is none."
  (or (and cmacs-brigade-desktop-relay-program
           (expand-file-name cmacs-brigade-desktop-relay-program))
      (cl-find-if #'file-executable-p
                  (cmacs-brigade-desktop--in-tree "gowl-mcp"))
      (car (cmacs-brigade-desktop--on-path "gowl-mcp"))))

(defun cmacs-brigade-desktop--probe (program args callback)
  "Run PROGRAM with ARGS and call CALLBACK with its exit status and output.
The status is nil when it could not be run or did not exit in five
seconds.  Asynchronous: a gowl that hangs on `--version' must not hang
the editor with it."
  (let* ((buffer (generate-new-buffer " *cmacs-brigade-desktop-probe*" t))
         (finished nil) (timer nil) (proc nil)
         (finish (lambda (status)
                   (unless finished
                     (setq finished t)
                     (when timer (cancel-timer timer))
                     (let ((output (if (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (buffer-string))
                                     "")))
                       (when (process-live-p proc) (delete-process proc))
                       (when (buffer-live-p buffer) (kill-buffer buffer))
                       (funcall callback status output))))))
    (condition-case err
        (let ((process-environment
               (append '("WLR_BACKENDS=headless" "GOWL_DISABLE_SYSTEMD=1"
                         "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY")
                       process-environment))
              (default-directory temporary-file-directory))
          (setq proc (make-process
                      :name "cmacs-brigade-desktop-probe"
                      :buffer buffer :command (cons program args)
                      :connection-type 'pipe :noquery t
                      :sentinel (lambda (p _event)
                                  (unless (process-live-p p)
                                    (funcall finish
                                             (process-exit-status p))))))
          (setq timer (run-at-time 5 nil (lambda () (funcall finish nil)))))
      (error
       (with-current-buffer buffer (insert (error-message-string err)))
       (funcall finish nil)))))

(defun cmacs-brigade-desktop--first-line (text)
  "Return the first non-empty line of TEXT, for a one-line reason."
  (or (car (split-string (or text "") "\n" t "[ \t]+")) "no output"))

(defun cmacs-brigade-desktop--locate (callback &optional candidates notes)
  "Find a gowl that runs and call CALLBACK with (PROGRAM NOTES).

PROGRAM is nil when none does.  NOTES is a list of sentences saying what
was passed over and why, which is the difference between \"no gowl\" and
knowing that an old hand-built one in /usr/local/bin sits ahead of the
working one on PATH."
  (let* ((candidates (or candidates
                         (and (not notes)
                              (cmacs-brigade-desktop--candidates))))
         (program (car candidates))
         (rest (cdr candidates))
         (next (lambda (note)
                 (let ((notes (append notes (list note))))
                   (if rest
                       (cmacs-brigade-desktop--locate callback rest notes)
                     (funcall callback nil notes))))))
    (cond
     ((null program)
      (funcall callback nil
               (or notes (list "no gowl binary was found"))))
     ((not (file-executable-p program))
      (funcall next (format "%s is not an executable file" program)))
     ((and (equal (car cmacs-brigade-desktop--trusted) program)
           (equal (cdr cmacs-brigade-desktop--trusted)
                  (file-attribute-modification-time
                   (file-attributes program))))
      (funcall callback program notes))
     (t
      (cmacs-brigade-desktop--probe
       program '("--version")
       (lambda (status output)
         (if (not (and (eql status 0)
                       (string-match-p "[^ \t\n]" output)))
             ;; A gowl that cannot load its wlroots fails here and
             ;; nowhere earlier.
             (funcall next (format "%s does not run: %s" program
                                   (cmacs-brigade-desktop--first-line
                                    output)))
           (cmacs-brigade-desktop--probe
            program '("--list-modules-ex")
            (lambda (status output)
              ;; A gowl too old to know the flag is given the benefit of
              ;; the doubt; one that answers and lists no `mcp' was built
              ;; without MCP=1 and cannot be looked at or driven.
              (if (and (eql status 0)
                       (not (string-match-p "^[ \t]*mcp[ \t]" output)))
                  (funcall next
                           (format "%s has no mcp module (built without MCP=1)"
                                   program))
                (setq cmacs-brigade-desktop--trusted
                      (cons program (file-attribute-modification-time
                                     (file-attributes program))))
                (funcall callback program notes)))))))))))


;;;; Lifecycle

(defun cmacs-brigade-desktop--settle (desktop state &optional reason)
  "Move DESKTOP to STATE with REASON and tell everybody waiting on it."
  (when-let* ((timer (cmacs-brigade-desktop--timer desktop)))
    (cancel-timer timer)
    (setf (cmacs-brigade-desktop--timer desktop) nil))
  (setf (cmacs-brigade-desktop--state desktop) state
        (cmacs-brigade-desktop--reason desktop) reason)
  (when (eq state 'ready)
    (cmacs-brigade-desktop--relay-start desktop)
    (cmacs-brigade-desktop--apply-scale desktop))
  (unless (memq state '(locating starting))
    (let ((waiters (nreverse (cmacs-brigade-desktop--waiters desktop))))
      (setf (cmacs-brigade-desktop--waiters desktop) nil)
      (dolist (waiter waiters)
        (with-demoted-errors "cmacs-brigade-desktop: %S"
          (funcall waiter (eq state 'ready))))))
  (cmacs-brigade-desktop--changed desktop))

(defun cmacs-brigade-desktop--when-ready (desktop function)
  "Call FUNCTION with non-nil once DESKTOP is up, or with nil if it will not be."
  (pcase (cmacs-brigade-desktop--state desktop)
    ('ready (funcall function t))
    ((or 'locating 'starting)
     (push function (cmacs-brigade-desktop--waiters desktop)))
    (_ (funcall function nil))))

(defun cmacs-brigade-desktop--cleanup (desktop)
  "Remove what DESKTOP leaves on disk once its gowl is gone.
The sockets, and the pictures taken for an agent.  The log and the
config stay: they are how a failed start is understood afterwards."
  ;; Not when the id has been started again since: an old gowl still on
  ;; its way out would otherwise delete the sockets of its successor,
  ;; which lives in the same directory.
  (when (memq (cmacs-brigade-desktop--get (cmacs-brigade-desktop--id desktop))
              (list nil desktop))
    (dolist (name '("run" "shots"))
      (let ((dir (expand-file-name name
                                   (cmacs-brigade-desktop--dir desktop))))
        (when (file-directory-p dir)
          (ignore-errors (delete-directory dir t)))))
    (when-let* ((relay (cmacs-brigade-desktop--relay-socket desktop)))
      (ignore-errors (delete-file relay)))))

(defun cmacs-brigade-desktop--log-append (desktop chunk)
  "Append CHUNK, gowl's output, to DESKTOP's log and keep its last lines."
  (let ((coding-system-for-write 'no-conversion)
        (tail (concat (cmacs-brigade-desktop--log-tail desktop) chunk)))
    (ignore-errors
      (write-region chunk nil (cmacs-brigade-desktop--log-file desktop)
                    'append 'silent))
    (setf (cmacs-brigade-desktop--log-tail desktop)
          (if (> (length tail) 2000) (substring tail -2000) tail))))

(defun cmacs-brigade-desktop--last-lines (desktop)
  "Return DESKTOP's gowl's last few lines of output, as one line."
  (let ((lines (last (split-string (cmacs-brigade-desktop--log-tail desktop)
                                   "\n" t "[ \t\r]+")
                     3)))
    (if lines (string-join lines " | ") "it said nothing")))

(defun cmacs-brigade-desktop--poll (desktop)
  "Look whether DESKTOP's gowl has opened its sockets yet."
  (when (eq (cmacs-brigade-desktop--state desktop) 'starting)
    (let ((proc (cmacs-brigade-desktop--process desktop))
          (run (cmacs-brigade-desktop--run-dir desktop)))
      (cond
       ((not (process-live-p proc))
        (cmacs-brigade-desktop--settle
         desktop 'failed
         (format "gowl exited before it opened its sockets: %s"
                 (cmacs-brigade-desktop--last-lines desktop)))
        (cmacs-brigade-desktop--cleanup desktop))
       ((and (file-exists-p (cmacs-brigade-desktop--mcp-socket desktop))
             (file-exists-p (cmacs-brigade-desktop--ipc-socket desktop))
             (directory-files run nil "\\`wayland-[0-9]+\\'"))
        (if (file-exists-p (cmacs-brigade-desktop--wayland desktop))
            (cmacs-brigade-desktop--settle desktop 'ready)
          ;; The environment already handed to the agent names
          ;; wayland-0.  A desktop on another name would be one its
          ;; programs cannot find, so it is not called ready.
          (cmacs-brigade-desktop--kill desktop)
          (cmacs-brigade-desktop--settle
           desktop 'failed
           (format "gowl opened %s, not the wayland-0 its programs were told"
                   (car (directory-files run nil "\\`wayland-[0-9]+\\'"))))))
       ((> (float-time) (cmacs-brigade-desktop--deadline desktop))
        (cmacs-brigade-desktop--kill desktop)
        (cmacs-brigade-desktop--settle
         desktop 'failed
         (format "gowl did not open its sockets in %s seconds (one built without MCP=1 never opens gowl-mcp.sock): %s"
                 cmacs-brigade-desktop-start-timeout
                 (cmacs-brigade-desktop--last-lines desktop))))))))

(defun cmacs-brigade-desktop--kill (desktop)
  "End DESKTOP's gowl: asked first, then made to.
The process started here is signalled through its own process object.
Never a pattern: this machine runs other gowls, the session's among
them."
  (let ((proc (cmacs-brigade-desktop--process desktop)))
    (when (process-live-p proc)
      (ignore-errors (signal-process proc 'SIGTERM))
      (run-at-time 3 nil (lambda ()
                           (when (process-live-p proc)
                             (delete-process proc)))))))

(defun cmacs-brigade-desktop--launch (desktop program)
  "Start PROGRAM, a gowl that answered, as DESKTOP's compositor."
  (let* ((setpriv (and cmacs-brigade-desktop-use-pdeathsig
                       (executable-find "setpriv")))
         (command (append (and setpriv
                               (list setpriv "--pdeathsig" "SIGTERM"))
                          (list program "--config"
                                (cmacs-brigade-desktop--config desktop)
                                "--no-c-config")))
         (process-environment
          (append (cmacs-brigade-desktop--environment
                   (cmacs-brigade-desktop--run-dir desktop)
                   (cmacs-brigade-desktop--width desktop)
                   (cmacs-brigade-desktop--height desktop))
                  process-environment))
         ;; Its working directory is the one its `spawn' hands to
         ;; programs, so home -- not the desktop's own state directory,
         ;; which is where a terminal would otherwise open.
         (default-directory (file-name-as-directory (expand-file-name "~"))))
    (setf (cmacs-brigade-desktop--program desktop) program)
    (condition-case err
        (progn
          (setf (cmacs-brigade-desktop--process desktop)
                (make-process
                 :name (format "brigade-desktop-%s"
                               (cmacs-brigade-desktop--id desktop))
                 :buffer nil :command command
                 :connection-type 'pipe :noquery t
                 :filter (lambda (_proc chunk)
                           (cmacs-brigade-desktop--log-append desktop chunk))
                 :sentinel
                 (lambda (proc _event)
                   (unless (process-live-p proc)
                     (pcase (cmacs-brigade-desktop--state desktop)
                       ('starting (cmacs-brigade-desktop--poll desktop))
                       ('ready
                        (cmacs-brigade-desktop--relay-stop desktop)
                        (cmacs-brigade-desktop--settle
                         desktop 'failed
                         (format "gowl exited: %s"
                                 (cmacs-brigade-desktop--last-lines
                                  desktop)))))
                     (cmacs-brigade-desktop--cleanup desktop)))))
          (setf (cmacs-brigade-desktop--state desktop) 'starting
                (cmacs-brigade-desktop--started desktop) (float-time)
                (cmacs-brigade-desktop--deadline desktop)
                (+ (float-time) cmacs-brigade-desktop-start-timeout)
                (cmacs-brigade-desktop--timer desktop)
                (run-at-time 0.1 0.1 #'cmacs-brigade-desktop--poll desktop))
          (cmacs-brigade-desktop--changed desktop))
      (error
       (cmacs-brigade-desktop--settle
        desktop 'failed
        (format "could not start %s: %s" program
                (error-message-string err)))))))

(defun cmacs-brigade-desktop--create (id)
  "Lay out the desktop ID on disk and return its record.
Signals when it cannot be made: a bad resolution, a path too long for a
socket, a log that is not a plain file.  Everything that can be refused
is refused here, before anything is started."
  (let* ((size (or (cmacs-brigade-desktop--parse-resolution
                    cmacs-brigade-desktop-resolution)
                   (signal 'cmacs-brigade-desktop-error
                           (list (format "`cmacs-brigade-desktop-resolution' is %S; it wants WIDTHxHEIGHT with each side 64 to 8192"
                                         cmacs-brigade-desktop-resolution)))))
         (dir (file-name-as-directory
               (expand-file-name (cmacs-brigade-desktop--dir-name id)
                                 cmacs-brigade-desktop-directory)))
         (run (expand-file-name "run" dir))
         (log (expand-file-name "server.log" dir))
         (config (expand-file-name "gowl.yaml" dir))
         (mcp (expand-file-name "gowl-mcp.sock" run))
         (relay (expand-file-name "relay.sock" dir)))
    (cmacs-brigade-desktop--check-socket-path mcp)
    (cmacs-brigade-desktop--check-socket-path relay)
    (with-file-modes #o700
      (make-directory dir t)
      (set-file-modes dir #o700)
      ;; Emptied, so the Wayland socket's name is the first free one and
      ;; a socket left by a crashed start is not mistaken for a live one.
      (when (file-directory-p run) (delete-directory run t))
      (make-directory run t))
    ;; gowl's output is written here by this process, unconfined.  A
    ;; symlink planted where the log goes would have that output written
    ;; to a file of somebody else's choosing.
    (when (or (file-symlink-p log)
              (and (file-exists-p log) (not (file-regular-p log))))
      (signal 'cmacs-brigade-desktop-error
              (list (format "%s is not a plain file; it will not be written to"
                            log))))
    (with-file-modes #o600
      (write-region "" nil log nil 'silent)
      (write-region (cmacs-brigade-desktop--config-yaml) nil config
                    nil 'silent))
    (cmacs-brigade-desktop--make
     :id id :dir dir :run-dir run :config config :log-file log
     :width (car size) :height (cdr size)
     :layout-width (car size) :layout-height (cdr size)
     :scale (float cmacs-brigade-desktop-scale)
     :wayland (cmacs-brigade-desktop--wayland-path run)
     :mcp-socket mcp
     :ipc-socket (expand-file-name "gowl.sock" run)
     :relay-socket relay)))

;;;###autoload
(defun cmacs-brigade-desktop-start (id &optional callback)
  "Start a private, headless desktop for the agent or task ID.

Returns its id at once.  The desktop comes up in the background:
CALLBACK, when given, is called with ID and non-nil once it is ready, or
with ID and nil when it could not be started
\(`cmacs-brigade-desktop-status' then says why).  Starting a desktop that
is already running, or on its way up, starts nothing and waits for that
one.

Signals a `cmacs-brigade-desktop-error' when the desktop cannot even be
laid out -- a state directory too deep for a unix socket address, say."
  (interactive (list (read-string "Start a desktop for agent/task: ")))
  (let* ((id (format "%s" id))
         (desktop (cmacs-brigade-desktop--get id)))
    (when (string-empty-p id)
      (signal 'cmacs-brigade-desktop-error (list "a desktop needs an id")))
    (unless (and desktop
                 (memq (cmacs-brigade-desktop--state desktop)
                       '(locating starting ready)))
      (when desktop (cmacs-brigade-desktop-stop id))
      (setq desktop (cmacs-brigade-desktop--create id))
      (puthash id desktop cmacs-brigade-desktop--table)
      (cmacs-brigade-desktop--changed desktop)
      (cmacs-brigade-desktop--locate
       (lambda (program notes)
         ;; Stopped while it was being looked for: start nothing.
         (when (and (eq (cmacs-brigade-desktop--get id) desktop)
                    (eq (cmacs-brigade-desktop--state desktop) 'locating))
           (setf (cmacs-brigade-desktop--notes desktop) notes)
           (if program
               (cmacs-brigade-desktop--launch desktop program)
             (cmacs-brigade-desktop--settle
              desktop 'failed
              (concat "no gowl could be started: "
                      (string-join notes "; "))))))))
    (when callback
      (cmacs-brigade-desktop--when-ready
       desktop (lambda (ok) (funcall callback id ok))))
    (when (called-interactively-p 'interactive)
      (message "Desktop %s is starting" id))
    id))

;;;###autoload
(defun cmacs-brigade-desktop-stop (id)
  "Stop the desktop ID, and every program on it.  Safe to call twice."
  (interactive
   (list (completing-read "Stop desktop: " (cmacs-brigade-desktop-list)
                          nil t)))
  (when-let* ((desktop (cmacs-brigade-desktop--get id)))
    (remhash (cmacs-brigade-desktop--id desktop) cmacs-brigade-desktop--table)
    (cmacs-brigade-desktop--relay-stop desktop)
    (cmacs-brigade-desktop--kill desktop)
    (cmacs-brigade-desktop--settle desktop 'stopped)
    ;; With gowl already gone its sentinel will not run again, so the
    ;; files are removed here; with it still exiting, the sentinel does.
    (unless (process-live-p (cmacs-brigade-desktop--process desktop))
      (cmacs-brigade-desktop--cleanup desktop))
    t))

(defun cmacs-brigade-desktop-stop-all ()
  "Stop every agent desktop.  On `kill-emacs-hook'."
  (dolist (id (cmacs-brigade-desktop-list))
    (ignore-errors (cmacs-brigade-desktop-stop id))))

(add-hook 'kill-emacs-hook #'cmacs-brigade-desktop-stop-all)

;;;###autoload
(defun cmacs-brigade-desktop-list ()
  "Return the ids of the agent desktops there are, sorted."
  (interactive)
  (let ((ids (sort (hash-table-keys cmacs-brigade-desktop--table)
                   #'string<)))
    (when (called-interactively-p 'interactive)
      (message "%s"
               (if ids
                   (mapconcat
                    (lambda (id)
                      (let ((s (cmacs-brigade-desktop-status id)))
                        (format "%s: %s%s" id (plist-get s :state)
                                (if (plist-get s :held) " (held)" ""))))
                    ids "\n")
                 "No agent desktops")))
    ids))

(defun cmacs-brigade-desktop-status (id)
  "Return a plist describing the desktop ID, or nil when there is none.

:state is `locating' (a gowl is being looked for), `starting', `ready',
`failed' or `stopped'; :reason says why it failed; :notes lists the
binaries that were passed over; :held is non-nil while a person has
taken control."
  (when-let* ((d (cmacs-brigade-desktop--get id)))
    (let ((proc (cmacs-brigade-desktop--process d)))
      (list :id (cmacs-brigade-desktop--id d)
            :state (cmacs-brigade-desktop--state d)
            :reason (cmacs-brigade-desktop--reason d)
            :notes (cmacs-brigade-desktop--notes d)
            :held (and (cmacs-brigade-desktop--held d) t)
            :program (cmacs-brigade-desktop--program d)
            :pid (and (process-live-p proc) (process-id proc))
            :width (cmacs-brigade-desktop--width d)
            :height (cmacs-brigade-desktop--height d)
            :layout-width (cmacs-brigade-desktop--layout-width d)
            :layout-height (cmacs-brigade-desktop--layout-height d)
            :scale (cmacs-brigade-desktop--scale d)
            :wayland (cmacs-brigade-desktop--wayland d)
            :relay (cmacs-brigade-desktop--relay-socket d)
            :directory (cmacs-brigade-desktop--dir d)
            :log (cmacs-brigade-desktop--log-file d)))))

(defun cmacs-brigade-desktop--apply-scale (desktop)
  "Set DESKTOP's output scale, when it is not to be 1.
Over the IPC socket's wire protocol, the only place a running gowl takes
one.  A gowl that refuses keeps scale 1 and the desktop says so."
  (let ((scale (cmacs-brigade-desktop--scale desktop)))
    (unless (= scale 1.0)
      (cmacs-brigade-desktop--ipc-call
       (cmacs-brigade-desktop--ipc-socket desktop)
       "monitor.configure" (list :scale scale)
       (lambda (ok value)
         (if ok
             (setf (cmacs-brigade-desktop--layout-width desktop)
                   (round (/ (cmacs-brigade-desktop--width desktop) scale))
                   (cmacs-brigade-desktop--layout-height desktop)
                   (round (/ (cmacs-brigade-desktop--height desktop) scale)))
           (setf (cmacs-brigade-desktop--scale desktop) 1.0)
           (push (format "scale %s was not applied: %s" scale value)
                 (cmacs-brigade-desktop--notes desktop)))
         (cmacs-brigade-desktop--changed desktop))))))


;;;; Taking a desktop, and giving it back

(defun cmacs-brigade-desktop-take (id)
  "Take control of the desktop ID.
The agent's acting tools -- its own and gowl's -- are refused with a
sentence saying so until `cmacs-brigade-desktop-release'.  Looking is
not refused, so the agent can wait usefully."
  (when-let* ((desktop (cmacs-brigade-desktop--get id)))
    (setf (cmacs-brigade-desktop--held desktop) t)
    (cmacs-brigade-desktop--changed desktop)
    t))

(defun cmacs-brigade-desktop-release (id)
  "Give the desktop ID back to its agent."
  (when-let* ((desktop (cmacs-brigade-desktop--get id)))
    (setf (cmacs-brigade-desktop--held desktop) nil)
    (cmacs-brigade-desktop--changed desktop)
    t))

(defun cmacs-brigade-desktop-held-p (id)
  "Whether a person has taken control of the desktop ID."
  (when-let* ((desktop (cmacs-brigade-desktop--get id)))
    (and (cmacs-brigade-desktop--held desktop) t)))


;;;; Looking and acting
;;
;; Every function below takes the desktop's id, a CALLBACK called with
;; (t VALUE) or (nil MESSAGE), and WHO: `agent' (the default) is bound by
;; the takeover, `human' is the person at the viewer.  Grants are the
;; tools' and the relay's business; these are the hands.

(defun cmacs-brigade-desktop--do (id tool who callback function)
  "Run FUNCTION on the desktop ID once it is ready, unless TOOL is refused.
FUNCTION is called with the desktop record.  A refusal, a desktop that
does not exist and one that failed to start all reach CALLBACK as
\(nil MESSAGE)."
  (let ((desktop (cmacs-brigade-desktop--get id)))
    (cond
     ((null desktop)
      (funcall callback nil "there is no such desktop; it was stopped, or never started"))
     ((and (not (eq who 'human))
           (cmacs-brigade-desktop--held desktop)
           (memq (cmacs-brigade-desktop--tool-class tool) '(act spawn)))
      (funcall callback nil (cmacs-brigade-desktop--held-sentence tool)))
     (t
      (cmacs-brigade-desktop--when-ready
       desktop
       (lambda (ok)
         (if ok
             (funcall function desktop)
           (funcall callback nil
                    (format "the desktop is not running: %s"
                            (or (cmacs-brigade-desktop--reason desktop)
                                "it was stopped"))))))))))

(defun cmacs-brigade-desktop--mcp (desktop tool arguments callback)
  "Call gowl's MCP TOOL with ARGUMENTS on DESKTOP."
  (cmacs-brigade-desktop--mcp-call
   (cmacs-brigade-desktop--mcp-socket desktop) tool arguments callback))

(defun cmacs-brigade-desktop-screenshot (id callback &optional who)
  "Take a picture of the desktop ID.
CALLBACK gets (t PNG), the PNG a unibyte string, or (nil MESSAGE)."
  (cmacs-brigade-desktop--do
   id "screenshot_monitor" who callback
   (lambda (desktop)
     (cmacs-brigade-desktop--mcp
      desktop "screenshot_monitor" nil
      (lambda (ok value)
        (if (not ok)
            (funcall callback nil value)
          (if-let* ((png (cmacs-brigade-desktop--result-image value)))
              (funcall callback t png)
            (funcall callback nil
                     (format "gowl answered with no picture: %s"
                             (cmacs-brigade-desktop--result-text
                              value))))))))))

(defun cmacs-brigade-desktop-windows (id callback &optional who)
  "List the windows on the desktop ID.  CALLBACK gets (t JSON-TEXT)."
  (cmacs-brigade-desktop--do
   id "list_clients" who callback
   (lambda (desktop)
     (cmacs-brigade-desktop--mcp
      desktop "list_clients" nil
      (lambda (ok value)
        (funcall callback ok
                 (if ok (cmacs-brigade-desktop--result-text value)
                   value)))))))

(defun cmacs-brigade-desktop-text (id x y width height callback &optional who)
  "Read the text in a region of the desktop ID (OCR, gowl's `screen_text').
X, Y, WIDTH and HEIGHT are layout coordinates; nil for all four reads
the whole screen.  CALLBACK gets (t TEXT)."
  (cmacs-brigade-desktop--do
   id "screen_text" who callback
   (lambda (desktop)
     (cmacs-brigade-desktop--mcp
      desktop "screen_text"
      (list :x (or x 0) :y (or y 0)
            :width (or width
                       (cmacs-brigade-desktop--layout-width desktop))
            :height (or height
                        (cmacs-brigade-desktop--layout-height desktop)))
      (lambda (ok value)
        (funcall callback ok
                 (if ok (cmacs-brigade-desktop--result-text value)
                   value)))))))

(defun cmacs-brigade-desktop-launch (id command callback &optional who)
  "Start COMMAND, a command line, on the desktop ID.

Through gowl's own spawn, so the program inherits the display of the
nested gowl's XWayland too, which nothing outside gowl knows.  The IPC
socket's `spawn' is tried first, for the pid it returns; a gowl without
the wire protocol is asked through its MCP `spawn' tool, which starts
the program and says nothing of its pid.  CALLBACK gets (t PID-OR-NIL)."
  (cmacs-brigade-desktop--do
   id "spawn" who callback
   (lambda (desktop)
     (if (string-empty-p (string-trim (or command "")))
         (funcall callback nil "launch what? the command is empty")
       (cmacs-brigade-desktop--ipc-call
        (cmacs-brigade-desktop--ipc-socket desktop) "spawn"
        (list :command command
              :cwd (expand-file-name "~")
              :env (list :GDK_BACKEND "wayland" :QT_QPA_PLATFORM "wayland"))
        (lambda (ok value)
          (if ok
              (funcall callback t (and (consp value) (alist-get 'pid value)))
            (cmacs-brigade-desktop--mcp
             desktop "spawn" (list :command command)
             (lambda (ok2 value2)
               (if ok2
                   (funcall callback t nil)
                 (funcall callback nil
                          (format "gowl would not start it: %s (and over its IPC: %s)"
                                  value2 value))))))))))))

(defun cmacs-brigade-desktop-key (id key callback &optional who)
  "Send KEY to the focused window of the desktop ID.

KEY is one key as XKB names it (\"Return\", \"a\", \"F5\") or a combination
\(\"Ctrl+s\").  One key goes through gowl's MCP `send_key', which takes
exactly that; a combination goes to the IPC socket's `window.send_key',
the one that understands modifiers."
  (cmacs-brigade-desktop--do
   id "send_key" who callback
   (lambda (desktop)
     (cond
      ((string-empty-p (or key ""))
       (funcall callback nil "send which key? none was given"))
      ((and (> (length key) 1) (string-search "+" key))
       (cmacs-brigade-desktop--ipc-call
        (cmacs-brigade-desktop--ipc-socket desktop)
        "window.send_key" (list :key key)
        (lambda (ok value) (funcall callback ok (if ok t value)))))
      (t
       (cmacs-brigade-desktop--mcp
        desktop "send_key" (list :key key)
        (lambda (ok value) (funcall callback ok (if ok t value)))))))))

(defun cmacs-brigade-desktop-type (id text callback &optional who)
  "Type TEXT into the focused window of the desktop ID."
  (cmacs-brigade-desktop--do
   id "send_text" who callback
   (lambda (desktop)
     (if (string-empty-p (or text ""))
         (funcall callback nil "type what? the text is empty")
       (cmacs-brigade-desktop--mcp
        desktop "send_text" (list :text text)
        (lambda (ok value) (funcall callback ok (if ok t value))))))))

(defun cmacs-brigade-desktop--move-then (desktop x y callback function)
  "Move DESKTOP's pointer to X, Y and then call FUNCTION.
gowl's `send_mouse' and `send_scroll' act where the pointer already is,
and that is wherever it was left; so every click and scroll is a move
first."
  (if (not (and (numberp x) (numberp y)))
      (funcall function)
    (cmacs-brigade-desktop--mcp
     desktop "send_mouse_move" (list :x x :y y)
     (lambda (ok value)
       (if ok (funcall function) (funcall callback nil value))))))

(defun cmacs-brigade-desktop-click (id x y button callback &optional who)
  "Click BUTTON (\"left\", \"right\" or \"middle\") at X, Y on the desktop ID."
  (cmacs-brigade-desktop--do
   id "send_mouse" who callback
   (lambda (desktop)
     (cmacs-brigade-desktop--move-then
      desktop x y callback
      (lambda ()
        (cmacs-brigade-desktop--mcp
         desktop "send_mouse"
         (list :button (if (member button '("left" "right" "middle"))
                           button
                         "left")
               :action "click")
         (lambda (ok value) (funcall callback ok (if ok t value)))))))))

(defun cmacs-brigade-desktop-scroll (id x y direction amount callback
                                        &optional who)
  "Scroll at X, Y on the desktop ID.
DIRECTION is \"up\", \"down\", \"left\" or \"right\"; AMOUNT is notches."
  (cmacs-brigade-desktop--do
   id "send_scroll" who callback
   (lambda (desktop)
     (if (not (member direction '("up" "down" "left" "right")))
         (funcall callback nil "scroll which way? up, down, left or right")
       (cmacs-brigade-desktop--move-then
        desktop x y callback
        (lambda ()
          (cmacs-brigade-desktop--mcp
           desktop "send_scroll"
           (list :direction direction :amount (max 1 (or amount 1)))
           (lambda (ok value) (funcall callback ok (if ok t value))))))))))

(defun cmacs-brigade-desktop--map-point (x y shown-width shown-height
                                           layout-width layout-height)
  "Map X, Y in a picture drawn SHOWN-WIDTH by SHOWN-HEIGHT to the layout.

The viewer scales the screenshot to fit its window, and a scaled output's
screenshot is bigger than its layout, so a click on the picture is rarely
at the coordinates the desktop uses.  The result is clamped into the
layout: a click on the picture's last pixel must not land outside the
screen.  Returns (X . Y), or nil when the picture has no size."
  (when (and (> shown-width 0) (> shown-height 0))
    (cons (max 0 (min (1- layout-width)
                      (floor (* x layout-width) shown-width)))
          (max 0 (min (1- layout-height)
                      (floor (* y layout-height) shown-height))))))

(defun cmacs-brigade-desktop--png-size (png)
  "Return (WIDTH . HEIGHT) read from PNG's header, or nil when it is not one."
  (when (and (stringp png) (>= (length png) 24)
             (equal (substring png 0 8) "\x89PNG\r\n\x1a\n")
             (equal (substring png 12 16) "IHDR"))
    (cl-flet ((be32 (at) (logior (ash (aref png at) 24)
                                 (ash (aref png (+ at 1)) 16)
                                 (ash (aref png (+ at 2)) 8)
                                 (aref png (+ at 3)))))
      (cons (be32 16) (be32 20)))))


;;;; A filtered relay of gowl's own MCP server
;;
;; gowl's server has every tool, `spawn' and the input recorder among
;; them, and its socket answers anybody who can reach it.  An agent is
;; therefore never given that socket.  It is given this one, which passes
;; lines to gowl and back and looks at three things on the way:
;;
;;   tools/list   the reply is cut down to the tools the agent's grants
;;                admit, so a tool it may not use is not offered at all
;;   tools/call   a tool outside its grants, or an acting tool while a
;;                person holds the desktop, is answered here with an
;;                error result and never reaches gowl
;;   the rest     only the handshake, pings and notifications go through;
;;                a batch is refused whole, because a call inside an
;;                array is still a call

(defun cmacs-brigade-desktop--relay-send (proc object)
  "Send OBJECT, a JSON value, as one line to PROC."
  (when (process-live-p proc)
    (process-send-string proc (concat (json-serialize object) "\n"))))

(defun cmacs-brigade-desktop--relay-verdict (desktop line)
  "Decide what to do with LINE, one line from an agent to DESKTOP's gowl.

Returns (forward), (list ID) -- forward, and the reply with that id is a
tool list to cut down -- (reply OBJECT) to answer here without gowl
seeing the line, or (drop)."
  (let ((message (condition-case nil
                     (json-parse-string line :object-type 'alist
                                        :array-type 'array)
                   (error 'unparsable))))
    (cond
     ((eq message 'unparsable)
      '(reply (:jsonrpc "2.0" :id :null
               :error (:code -32700 :message "that line is not JSON"))))
     ((vectorp message)
      '(reply (:jsonrpc "2.0" :id :null
               :error (:code -32600
                       :message "batches are not relayed to an agent desktop; send one request a line"))))
     ((not (listp message)) '(drop))
     (t
      (let* ((method (alist-get 'method message))
             (has-id (assq 'id message))
             (id (cdr has-id)))
        (cond
         ;; A reply to something the server asked.  It can call nothing.
         ((null method) '(forward))
         ((equal method "tools/call")
          (let* ((tool (alist-get 'name (alist-get 'params message)))
                 (refusal (cmacs-brigade-desktop--refusal
                           desktop (and (stringp tool) tool)
                           (cmacs-brigade-desktop--agent-of desktop)
                           'agent)))
            (cond
             ((not refusal) '(forward))
             ((not has-id) '(drop))
             (t (list 'reply
                      (list :jsonrpc "2.0" :id id
                            :result (list :content
                                          (vector (list :type "text"
                                                        :text refusal))
                                          :isError t)))))))
         ((equal method "tools/list")
          (if has-id (list 'list id) '(forward)))
         ((or (member method '("initialize" "ping"))
              (string-prefix-p "notifications/" method))
          '(forward))
         (has-id
          (list 'reply
                (list :jsonrpc "2.0" :id id
                      :error (list :code -32601
                                   :message (format "%s is not relayed to an agent desktop"
                                                    method)))))
         (t '(drop))))))))

(defun cmacs-brigade-desktop--relay-filter-list (line ids grants)
  "Cut the tool list in LINE, a reply from gowl, down to what GRANTS admit.
IDS are the ids of the tools/list requests still unanswered.  Returns
\(LINE . ID), the line to send on and the id it answered, or nil when
LINE answers none of them and should go on as it is."
  (let ((message (ignore-errors
                   (json-parse-string line :object-type 'alist
                                      :array-type 'array))))
    (when-let* (((consp message))
                (asked (cl-find (alist-get 'id message) ids
                                :test #'cmacs-brigade-desktop--same-id-p)))
      (when-let* ((result (assq 'result message))
                  (tools (assq 'tools (cdr result))))
        (setcdr tools
                (vconcat
                 (cl-remove-if-not
                  (lambda (tool)
                    (cmacs-brigade-desktop--tool-allowed-p
                     (alist-get 'name tool) grants))
                  (cdr tools)))))
      (cons (json-serialize message) asked))))

(defun cmacs-brigade-desktop--relay-upstream (desktop client)
  "Return CLIENT's connection to DESKTOP's gowl, opening it on first use."
  (or (let ((up (process-get client 'upstream)))
        (and (process-live-p up) up))
      (let ((up (make-network-process
                 :name "cmacs-brigade-desktop-relay-up"
                 :family 'local
                 :service (cmacs-brigade-desktop--mcp-socket desktop)
                 :coding 'no-conversion :noquery t
                 :filter
                 (lambda (up chunk)
                   (cmacs-brigade-desktop--relay-from-gowl
                    desktop client up chunk))
                 :sentinel
                 (lambda (up _event)
                   (unless (process-live-p up)
                     (when (process-live-p client)
                       (delete-process client)))))))
        (process-put client 'upstream up)
        up)))

(defun cmacs-brigade-desktop--relay-from-gowl (desktop client up chunk)
  "Pass CHUNK, bytes from DESKTOP's gowl on UP, to the agent on CLIENT.

Bytes go straight through unless a tool list is owed, and that is the
common case by a wide margin: a screenshot is megabytes on one line, and
splitting it into lines only to join them again would copy it twice for
nothing.  While a list is owed, whole lines are held and looked at."
  (let ((data (concat (process-get up 'partial) chunk)))
    (process-put up 'partial nil)
    (while (and (not (string-empty-p data)) (process-live-p client))
      (let ((ids (process-get client 'list-ids))
            (newline (string-search "\n" data)))
        (cond
         ;; The tail of a line whose head has already been sent on.
         ((process-get up 'midline)
          (process-send-string
           client (if newline (substring data 0 (1+ newline)) data))
          (when newline (process-put up 'midline nil))
          (setq data (if newline (substring data (1+ newline)) "")))
         ((null ids)
          (unless (string-suffix-p "\n" data)
            (process-put up 'midline t))
          (process-send-string client data)
          (setq data ""))
         ((null newline)
          (process-put up 'partial data)
          (setq data ""))
         (t
          (let* ((line (substring data 0 newline))
                 (cut (cmacs-brigade-desktop--relay-filter-list
                       (decode-coding-string line 'utf-8) ids
                       (cmacs-brigade-desktop-grants-for
                        (cmacs-brigade-desktop--agent-of desktop)))))
            (when cut
              (process-put client 'list-ids (remove (cdr cut) ids)))
            (process-send-string client
                                 (concat (if cut (car cut) line) "\n"))
            (setq data (substring data (1+ newline))))))))))

(defun cmacs-brigade-desktop--relay-from-agent (desktop client chunk)
  "Handle CHUNK, bytes an agent sent on CLIENT, for DESKTOP."
  (let* ((data (concat (process-get client 'partial) chunk))
         (lines (split-string data "\n"))
         (rest (car (last lines))))
    (process-put client 'partial rest)
    (dolist (line (butlast lines))
      (unless (string-match-p "\\`[ \t\r]*\\'" line)
        (pcase (cmacs-brigade-desktop--relay-verdict
                desktop (decode-coding-string line 'utf-8))
          (`(reply ,object)
           (cmacs-brigade-desktop--relay-send client object))
          (`(drop) nil)
          (verdict
           (when (eq (car verdict) 'list)
             (process-put client 'list-ids
                          (cons (cadr verdict)
                                (process-get client 'list-ids))))
           (condition-case err
               (process-send-string
                (cmacs-brigade-desktop--relay-upstream desktop client)
                (concat line "\n"))
             (error
              ;; gowl is gone.  Hang up, so the agent sees a closed
              ;; connection rather than waiting for an answer that will
              ;; not come.
              (message "cmacs-brigade-desktop: relay for %s: %s"
                       (cmacs-brigade-desktop--id desktop)
                       (error-message-string err))
              (delete-process client)))))))))

(defun cmacs-brigade-desktop--relay-start (desktop)
  "Open DESKTOP's relay socket.  Called when its gowl is up."
  (cmacs-brigade-desktop--relay-stop desktop)
  (let ((path (cmacs-brigade-desktop--relay-socket desktop)))
    (condition-case err
        (with-file-modes #o600
          (setf (cmacs-brigade-desktop--relay desktop)
                (make-network-process
                 :name (format "brigade-desktop-relay-%s"
                               (cmacs-brigade-desktop--id desktop))
                 :server t :family 'local :service path
                 :coding 'no-conversion :noquery t
                 :log (lambda (_server client _message)
                        (push client
                              (cmacs-brigade-desktop--relay-clients desktop)))
                 :filter (lambda (client chunk)
                           (cmacs-brigade-desktop--relay-from-agent
                            desktop client chunk))
                 :sentinel
                 (lambda (client _event)
                   (unless (process-live-p client)
                     (when-let* ((up (process-get client 'upstream)))
                       (when (process-live-p up) (delete-process up)))
                     (setf (cmacs-brigade-desktop--relay-clients desktop)
                           (delq client
                                 (cmacs-brigade-desktop--relay-clients
                                  desktop))))))))
      (error
       (push (format "its relay socket could not be opened: %s"
                     (error-message-string err))
             (cmacs-brigade-desktop--notes desktop))))))

(defun cmacs-brigade-desktop--relay-stop (desktop)
  "Close DESKTOP's relay socket and every connection through it."
  (dolist (client (cmacs-brigade-desktop--relay-clients desktop))
    (when-let* ((up (process-get client 'upstream)))
      (when (process-live-p up) (delete-process up)))
    (when (process-live-p client) (delete-process client)))
  (setf (cmacs-brigade-desktop--relay-clients desktop) nil)
  (when-let* ((server (cmacs-brigade-desktop--relay desktop)))
    (when (process-live-p server) (delete-process server))
    (setf (cmacs-brigade-desktop--relay desktop) nil))
  (ignore-errors
    (delete-file (cmacs-brigade-desktop--relay-socket desktop))))


;;;; Isolation providers
;;
;; `desktop' is `none' with a screen.  The registry has no way to combine
;; two providers, so the combinations that make sense are kinds of their
;; own, built from the shipped providers' own prepare and teardown
;; functions rather than from copies of them.

(defun cmacs-brigade-desktop--prepared (id)
  "Return what an agent whose desktop is ID needs, as a prepare plist.

:env points the agent's own processes at the desktop.  :desktop names
it.  :mcp-servers is a list of extra MCP servers for the agent's config,
each a plist of :name, :command and :args -- the relay of gowl's own
tools, when a `gowl-mcp' binary exists to speak to it."
  (let* ((desktop (cmacs-brigade-desktop--get id))
         (relay (cmacs-brigade-desktop--relay-command)))
    (list :cwd default-directory
          :env (append
                (cmacs-brigade-desktop--app-environment
                 (cmacs-brigade-desktop--wayland desktop))
                (list (cons "CMACS_BRIGADE_DESKTOP" (format "%s" id))))
          :desktop (format "%s" id)
          :mcp-servers
          (and relay
               (list (list :name "desktop"
                           :command relay
                           :args (list "--socket"
                                       (cmacs-brigade-desktop--relay-socket
                                        desktop))))))))

(defun cmacs-brigade-desktop--prepare (agent-id)
  "Start a desktop for AGENT-ID and return where its agent should run.
Returns while gowl is still coming up: the environment is known ahead of
time, and the agent's desktop tools wait for the desktop themselves."
  (cmacs-brigade-desktop-start agent-id)
  (cmacs-brigade-desktop--prepared agent-id))

(defun cmacs-brigade-desktop--teardown (agent-id)
  "Stop AGENT-ID's desktop.  Safe when there is none."
  (cmacs-brigade-desktop-stop (format "%s" agent-id)))

(defun cmacs-brigade-desktop--merge (desktop other)
  "Merge two prepare plists: OTHER's directory, both environments."
  (let ((merged (copy-sequence desktop)))
    (setq merged (plist-put merged :cwd (plist-get other :cwd)))
    (plist-put merged :env (append (plist-get desktop :env)
                                   (plist-get other :env)))))

(defun cmacs-brigade-desktop--worktree-prepare (agent-id)
  "A desktop and a git worktree for AGENT-ID."
  (require 'cmacs-brigade-isolation)
  (let ((prepared (cmacs-brigade-desktop--prepare agent-id)))
    (condition-case err
        (cmacs-brigade-desktop--merge
         prepared (cmacs-brigade-isolation--worktree-prepare agent-id))
      (error
       ;; Half of a pair is a leak: the worktree failed, so the desktop
       ;; started a moment ago goes too.
       (cmacs-brigade-desktop--teardown agent-id)
       (signal (car err) (cdr err))))))

(defun cmacs-brigade-desktop--worktree-teardown (agent-id)
  "Remove AGENT-ID's desktop and its worktree."
  (require 'cmacs-brigade-isolation)
  (ignore-errors (cmacs-brigade-desktop--teardown agent-id))
  (cmacs-brigade-isolation--worktree-teardown agent-id))

(defun cmacs-brigade-desktop--podman-mount-args (wayland)
  "Return the `podman run' arguments that give a container the socket WAYLAND.

The socket FILE, at the same path, and nothing else of its directory:
gowl.sock and gowl-mcp.sock sit beside it, and both run commands on the
host for whoever can reach them."
  (append (list "--volume" (format "%s:%s" wayland wayland))
          (cl-loop for (name . value)
                   in (cmacs-brigade-desktop--app-environment wayland)
                   append (list "--env" (format "%s=%s" name value)))
          cmacs-brigade-desktop-podman-args))

(defun cmacs-brigade-desktop--podman-prepare (agent-id)
  "A desktop and a container for AGENT-ID.

The one place here that waits.  A container's mounts are fixed when it
is created and the mount is of a socket that does not exist until gowl
has started, so the desktop has to be up first.  The wait is bounded by
`cmacs-brigade-desktop-start-timeout' and is spent in
`accept-process-output', so processes and the compositor keep being
served; `podman run' right after it blocks for longer."
  (require 'cmacs-brigade-isolation)
  (let* ((prepared (cmacs-brigade-desktop--prepare agent-id))
         (desktop (cmacs-brigade-desktop--get agent-id))
         (limit (+ (float-time) cmacs-brigade-desktop-start-timeout 6)))
    (condition-case err
        (progn
          (while (and (memq (cmacs-brigade-desktop--state desktop)
                            '(locating starting))
                      (< (float-time) limit))
            (cmacs-brigade-desktop--poll desktop)
            (accept-process-output nil 0.05))
          (unless (eq (cmacs-brigade-desktop--state desktop) 'ready)
            (signal 'cmacs-brigade-desktop-error
                    (list (format "the desktop did not start: %s"
                                  (or (cmacs-brigade-desktop--reason desktop)
                                      "it is still starting")))))
          (let ((cmacs-brigade-isolation-podman-extra-args
                 (cmacs-brigade-desktop--podman-mount-args
                  (cmacs-brigade-desktop--wayland desktop))))
            (cmacs-brigade-desktop--merge
             prepared (cmacs-brigade-isolation--podman-prepare agent-id))))
      (error
       (cmacs-brigade-desktop--teardown agent-id)
       (signal (car err) (cdr err))))))

(defun cmacs-brigade-desktop--podman-teardown (agent-id)
  "Remove AGENT-ID's container and its desktop."
  (require 'cmacs-brigade-isolation)
  ;; The container first: its programs are the desktop's clients.
  (ignore-errors (cmacs-brigade-isolation--podman-teardown agent-id))
  (cmacs-brigade-desktop--teardown agent-id))

(cmacs-brigade-register-isolation
 :name 'desktop
 :prepare #'cmacs-brigade-desktop--prepare
 :teardown #'cmacs-brigade-desktop--teardown
 :describe (lambda () "a private headless desktop"))

(cmacs-brigade-register-isolation
 :name 'desktop-worktree
 :prepare #'cmacs-brigade-desktop--worktree-prepare
 :teardown #'cmacs-brigade-desktop--worktree-teardown
 :describe (lambda () "a private headless desktop and a git worktree"))

(cmacs-brigade-register-isolation
 :name 'desktop-podman
 :prepare #'cmacs-brigade-desktop--podman-prepare
 :teardown #'cmacs-brigade-desktop--podman-teardown
 :describe (lambda () "a private headless desktop and a podman container"))


;;;; The agent's tools
;;
;; None of them takes a desktop.  The desktop is the calling task's, and
;; the task is what the brigade says it is, not what the model writes: an
;; agent that could name a desktop could name another agent's, and one
;; that could name a socket could name the session's.

(defvar cmacs-brigade-desktop--caller nil
  "(TASK . AGENT) of the desktop tool call being dispatched, or nil.

A tool's handler is called with its arguments and nothing about who is
calling.  `cmacs-brigade-before-tool-call-functions' is told, and runs
immediately before the handler, so the caller is noted there and taken
by the handler as its first act.

TASK is what `cmacs-brigade-call-tool' was given: the executor's own
task for an in-process agent, and for a CLI agent the task its scoped
MCP socket was opened for.  Neither is anything the model wrote.")

(defun cmacs-brigade-desktop--note-caller (request)
  "Remember who is making the desktop tool call REQUEST.  Never vetoes."
  (when (string-prefix-p "desktop_" (or (plist-get request :tool) ""))
    (setq cmacs-brigade-desktop--caller
          (cons (plist-get request :task) (plist-get request :agent))))
  t)

(add-hook 'cmacs-brigade-before-tool-call-functions
          #'cmacs-brigade-desktop--note-caller)

(defun cmacs-brigade-desktop--tool (tool done function)
  "Run FUNCTION for the desktop tool TOOL on the calling task's own desktop.

FUNCTION is called with the desktop's id and a callback of (OK VALUE);
DONE receives the string the model reads.  The call is refused, in a
sentence, when it comes from no task, when the task has no desktop, when
the agent's grants do not admit TOOL, and for an acting tool while a
person holds the desktop."
  (let* ((caller (prog1 cmacs-brigade-desktop--caller
                   (setq cmacs-brigade-desktop--caller nil)))
         (task (car caller))
         (desktop (cmacs-brigade-desktop--get task))
         (refusal
          (cond
           ((null task)
            "this call came from no brigade task, so there is no desktop it could mean.  A desktop belongs to the task of an agent whose isolation is `desktop'.")
           ((null desktop)
            "this task has no desktop.  Give its agent `desktop' isolation.")
           (t (cmacs-brigade-desktop--refusal
               desktop tool
               (or (cmacs-brigade-desktop--agent-of desktop) (cdr caller))
               'agent)))))
    (if refusal
        (funcall done (concat "Error: " refusal))
      (condition-case err
          (funcall function (cmacs-brigade-desktop--id desktop)
                   (lambda (ok value)
                     (funcall done (if ok value
                                     (format "Error: %s" value)))))
        (error (funcall done (format "Error: %s"
                                     (error-message-string err))))))))

(defun cmacs-brigade-desktop--save-shot (id png)
  "Write PNG, a picture of the desktop ID, to its file and return the path.
One file, replaced by each picture and removed with the desktop: tool
results are text, so a picture reaches a model as a path it can open."
  (let* ((desktop (cmacs-brigade-desktop--get id))
         (dir (expand-file-name "shots" (cmacs-brigade-desktop--dir desktop)))
         (file (expand-file-name "screen.png" dir))
         (coding-system-for-write 'no-conversion))
    (with-file-modes #o700 (make-directory dir t))
    (with-file-modes #o600 (write-region png nil file nil 'silent))
    file))

(cmacs-brigade-deftool desktop-screenshot
    "Take a picture of your own desktop -- the private screen your GUI programs open on.  Returns the path of a PNG file and its size in pixels; the coordinates the other desktop tools take are positions in that picture."
    ()
  :group 'desktop :async t
  (cmacs-brigade-desktop--tool
   "desktop_screenshot" done
   (lambda (id callback)
     (cmacs-brigade-desktop-screenshot
      id
      (lambda (ok value)
        (if (not ok)
            (funcall callback nil value)
          (let* ((size (cmacs-brigade-desktop--png-size value))
                 (status (cmacs-brigade-desktop-status id))
                 (file (cmacs-brigade-desktop--save-shot id value)))
            (funcall
             callback t
             (format "Your desktop, %sx%s pixels, saved as %s.%s%s"
                     (or (car size) "?") (or (cdr size) "?") file
                     (if (and size
                              (/= (car size) (plist-get status :layout-width)))
                         (format "  Coordinates are in a %sx%s layout, so scale positions in the picture down to it."
                                 (plist-get status :layout-width)
                                 (plist-get status :layout-height))
                       "")
                     (if (plist-get status :held)
                         "  A person has taken control of it for now."
                       ""))))))))))

(cmacs-brigade-deftool desktop-windows
    "List the windows open on your own desktop, with their ids, titles, programs and positions, as JSON."
    ()
  :group 'desktop :async t
  (cmacs-brigade-desktop--tool
   "desktop_windows" done
   (lambda (id callback) (cmacs-brigade-desktop-windows id callback))))

(cmacs-brigade-deftool desktop-text
    "Read the text shown on your own desktop (OCR).  With no arguments it reads the whole screen; give a rectangle to read part of it.  Cheaper than a picture when you only need the words."
    ((x integer "Left edge of the rectangle" :optional t)
     (y integer "Top edge of the rectangle" :optional t)
     (width integer "Width of the rectangle" :optional t)
     (height integer "Height of the rectangle" :optional t))
  :group 'desktop :async t
  (cmacs-brigade-desktop--tool
   "desktop_text" done
   (lambda (id callback)
     (cmacs-brigade-desktop-text id x y width height callback))))

(cmacs-brigade-deftool desktop-launch
    "Start a program on your own desktop.  Returns at once; the program may take a moment to draw its window, so take a screenshot or list the windows to see it."
    ((command string "The command line to run, e.g. \"gedit /tmp/notes.txt\""))
  :group 'desktop :async t :destructive t
  (cmacs-brigade-desktop--tool
   "desktop_launch" done
   (lambda (id callback)
     (cmacs-brigade-desktop-launch
      id command
      (lambda (ok value)
        (funcall callback ok
                 (if ok
                     (format "Started%s.  It may take a moment to draw its window."
                             (if value (format " (pid %s)" value) ""))
                   value)))))))

(cmacs-brigade-deftool desktop-key
    "Press one key or key combination in the focused window of your own desktop.  Keys are XKB names: Return, Escape, Tab, BackSpace, space, F5, a.  Combinations join with +: Ctrl+s, Alt+F4, Ctrl+Shift+t."
    ((key string "The key or combination"))
  :group 'desktop :async t :destructive t
  (cmacs-brigade-desktop--tool
   "desktop_key" done
   (lambda (id callback)
     (cmacs-brigade-desktop-key
      id key
      (lambda (ok value)
        (funcall callback ok (if ok (format "Pressed %s." key) value)))))))

(cmacs-brigade-deftool desktop-type
    "Type text into the focused window of your own desktop, as if at its keyboard.  Click the field you mean first."
    ((text string "The text to type"))
  :group 'desktop :async t :destructive t
  (cmacs-brigade-desktop--tool
   "desktop_type" done
   (lambda (id callback)
     (cmacs-brigade-desktop-type
      id text
      (lambda (ok value)
        (funcall callback ok
                 (if ok (format "Typed %d characters." (length text))
                   value)))))))

(cmacs-brigade-deftool desktop-click
    "Click at a position on your own desktop.  The pointer is moved there first."
    ((x integer "Pixels from the left edge")
     (y integer "Pixels from the top edge")
     (button string "Which button" :optional t :default "left"
             :enum ("left" "right" "middle")))
  :group 'desktop :async t :destructive t
  (cmacs-brigade-desktop--tool
   "desktop_click" done
   (lambda (id callback)
     (cmacs-brigade-desktop-click
      id x y button
      (lambda (ok value)
        (funcall callback ok
                 (if ok (format "Clicked %s at %s, %s." button x y)
                   value)))))))

(cmacs-brigade-deftool desktop-scroll
    "Scroll at a position on your own desktop.  The pointer is moved there first."
    ((x integer "Pixels from the left edge")
     (y integer "Pixels from the top edge")
     (direction string "Which way" :enum ("up" "down" "left" "right"))
     (amount integer "How many notches" :optional t :default 1))
  :group 'desktop :async t :destructive t
  (cmacs-brigade-desktop--tool
   "desktop_scroll" done
   (lambda (id callback)
     (cmacs-brigade-desktop-scroll
      id x y direction amount
      (lambda (ok value)
        (funcall callback ok
                 (if ok (format "Scrolled %s by %s at %s, %s."
                                direction amount x y)
                   value)))))))


;;;; On the dashboard

(defun cmacs-brigade-desktop--panel ()
  "Return the dashboard's lines about agent desktops, or nil for none."
  (mapcar
   (lambda (id)
     (let ((s (cmacs-brigade-desktop-status id)))
       (format "%-24s %-9s %sx%s%s%s"
               id (plist-get s :state)
               (plist-get s :width) (plist-get s :height)
               (if (plist-get s :held) "  held by you" "")
               (if (plist-get s :reason)
                   (format "  %s" (plist-get s :reason))
                 ""))))
   (cmacs-brigade-desktop-list)))

(cmacs-brigade-register-panel
 :name 'desktops
 :title "Desktops  (M-x cmacs-brigade-desktop-view)"
 :order 65
 :render #'cmacs-brigade-desktop--panel)

(autoload 'cmacs-brigade-desktop-view "cmacs-brigade-desktop-view"
  "Watch an agent's desktop, and take it over." t)

(provide 'cmacs-brigade-desktop)

;;; cmacs-brigade-desktop.el ends here
