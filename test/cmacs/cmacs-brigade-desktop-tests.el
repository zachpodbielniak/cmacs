;;; cmacs-brigade-desktop-tests.el --- Tests for agent desktops  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Everything but the last test runs against a stand-in for gowl: a unix
;; socket server in this Emacs that answers the handful of JSON-RPC
;; methods an agent desktop uses.  No compositor is started and nothing
;; outside a temporary directory is touched.
;;
;; The last test starts a real, headless gowl in a directory of its own
;; and stops it again.  It runs only when a gowl that works is found AND
;; the environment variable CMACS_TEST_DESKTOP is set, so an ordinary
;; `make check-cmacs' never starts a compositor.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-tools)
(require 'cmacs-brigade-desktop)
(require 'cmacs-brigade-desktop-view)


;;;; Helpers

(defmacro cmacs-brigade-desktop-tests--sandbox (dir &rest body)
  "Run BODY with DIR bound to a fresh directory and no desktops known.
The desktop table and the directory desktops are made in are both
replaced, so a test can neither see nor disturb a real one."
  (declare (indent 1))
  `(let* ((,dir (file-name-as-directory (make-temp-file "cbd" t)))
          (cmacs-brigade-desktop--table (make-hash-table :test 'equal))
          (cmacs-brigade-desktop-directory ,dir)
          (cmacs-brigade-desktop-agent-grants nil)
          (cmacs-brigade-desktop-grants '(look act spawn))
          (cmacs-brigade-desktop-changed-functions nil))
     (unwind-protect
         (progn ,@body)
       (dolist (process (process-list))
         (when (string-prefix-p "cbd-test" (process-name process))
           (delete-process process)))
       (maphash (lambda (_id desktop)
                  (cmacs-brigade-desktop--relay-stop desktop))
                cmacs-brigade-desktop--table)
       (delete-directory ,dir t))))

(defun cmacs-brigade-desktop-tests--await (start)
  "Call START with a callback and wait for it; return the callback's arguments.
Waits in `accept-process-output', as the editor's own loop would, and
gives up after ten seconds."
  (let ((answer nil) (deadline (+ (float-time) 10)))
    (funcall start (lambda (&rest arguments) (setq answer (or arguments t))))
    (while (and (not answer) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (or answer (ert-fail "the callback was never called"))))

(defconst cmacs-brigade-desktop-tests--png
  (concat "\x89PNG\r\n\x1a\n" (unibyte-string 0 0 0 13) "IHDR"
          (unibyte-string 0 0 5 0) (unibyte-string 0 0 3 32))
  "The first 24 bytes of a 1280x800 PNG: enough to read its size from.")

(defvar cmacs-brigade-desktop-tests--string-ids nil
  "Non-nil makes the stand-in answer the request with id 1 as \"1\".
gowl 0.5.0's MCP server does, and a client has to cope.")

(defun cmacs-brigade-desktop-tests--fake-gowl (socket seen)
  "Serve a stand-in for gowl's MCP and IPC sockets on SOCKET.
Every message it is sent is pushed onto the list in the car of SEEN."
  (make-network-process
   :name "cbd-test-gowl" :server t :family 'local :service socket
   :coding 'no-conversion :noquery t
   :filter
   (lambda (client chunk)
     (let* ((data (concat (process-get client 'partial) chunk))
            (lines (split-string data "\n")))
       (process-put client 'partial (car (last lines)))
       (dolist (line (butlast lines))
         (let* ((message (json-parse-string
                          (decode-coding-string line 'utf-8)
                          :object-type 'alist :array-type 'list))
                (asked (alist-get 'id message))
                (id (if (and asked cmacs-brigade-desktop-tests--string-ids)
                        (format "%s" asked)
                      asked))
                (method (alist-get 'method message))
                (params (alist-get 'params message))
                (tool (alist-get 'name params))
                (text (lambda (string &optional failed)
                        (list :content (vector (list :type "text"
                                                     :text string))
                              :isError (if failed t :false))))
                (answer
                 (pcase method
                   ("initialize" (list :protocolVersion "2024-11-05"
                                       :capabilities nil))
                   ("tools/list"
                    (list :tools
                          (vconcat
                           (mapcar (lambda (name) (list :name name))
                                   '("list_clients" "screenshot_monitor"
                                     "send_key" "spawn" "start_recording"
                                     "compositor_quit")))))
                   ("tools/call"
                    (pcase tool
                      ("screenshot_monitor"
                       (list :content
                             (vector
                              (list :type "image" :mimeType "image/png"
                                    :data (base64-encode-string
                                           cmacs-brigade-desktop-tests--png
                                           t)))))
                      ("list_clients" (funcall text "[{\"id\":1}]"))
                      ("close_client" (funcall text "no such window" t))
                      (_ (funcall text "ok"))))
                   ("spawn" (list :pid 4242))
                   ("window.send_key" (list :ok t))
                   (_ 'unknown))))
           (push message (car seen))
           (when (equal method "initialize")
             ;; Something nobody asked for, ahead of the answer: a client
             ;; has to pass over lines that are not its reply.
             (process-send-string
              client
              (concat (json-serialize
                       '(:jsonrpc "2.0" :method "event"
                         :params (:event "window.focus")))
                      "\n")))
           (when id
             (process-send-string
              client
              (concat
               (json-serialize
                (if (eq answer 'unknown)
                    (list :jsonrpc "2.0" :id id
                          :error (list :code -32601
                                       :message (format "no method %s"
                                                        method)))
                  (list :jsonrpc "2.0" :id id :result answer)))
               "\n")))))))))

(defun cmacs-brigade-desktop-tests--desktop (id dir socket)
  "Register a desktop called ID that is \"running\" on the fake gowl at SOCKET."
  (let ((home (file-name-as-directory (expand-file-name id dir))))
    (make-directory home t)
    (puthash id
             (cmacs-brigade-desktop--make
              :id id :dir home :state 'ready
              :run-dir (expand-file-name "run" home)
              :mcp-socket socket :ipc-socket socket
              :relay-socket (expand-file-name "relay.sock" home)
              :wayland (expand-file-name "run/wayland-0" home)
              :width 1280 :height 800
              :layout-width 1280 :layout-height 800)
             cmacs-brigade-desktop--table)))

(defun cmacs-brigade-desktop-tests--calls (seen)
  "Return the names of the tools SEEN's server was asked to call, in order."
  (cl-loop for message in (reverse (car seen))
           when (equal (alist-get 'method message) "tools/call")
           collect (alist-get 'name (alist-get 'params message))))


;;;; What is written and exported

(ert-deftest cmacs-brigade-desktop-test-config-is-ipc-and-mcp-only ()
  "The generated gowl.yaml is exactly this: two modules, no HTTP port."
  (should (equal (cmacs-brigade-desktop--config-yaml)
                 (concat
                  "# Written by cmacs for an agent's headless desktop; rewritten at start.\n"
                  "modules:\n"
                  "  ipc:\n"
                  "    enabled: true\n"
                  "  mcp:\n"
                  "    enabled: true\n"
                  "    transport-stdio: true\n"
                  "    transport-http: false\n")))
  ;; Whatever the wording, the modules are those two and no others.
  (let ((modules nil))
    (dolist (line (split-string (cmacs-brigade-desktop--config-yaml) "\n"))
      (when (string-match "\\`  \\([a-z-]+\\):\\'" line)
        (push (match-string 1 line) modules)))
    (should (equal (sort modules #'string<) '("ipc" "mcp")))))

(ert-deftest cmacs-brigade-desktop-test-compositor-environment ()
  "gowl is told to be headless and inherits no display of any kind."
  (let ((env (cmacs-brigade-desktop--environment "/s/run" 1280 800)))
    (should (equal env
                   '("XDG_RUNTIME_DIR=/s/run"
                     "WLR_BACKENDS=headless"
                     "WLR_HEADLESS_OUTPUTS=1"
                     "WLR_RENDERER=pixman"
                     "WLR_LIBINPUT_NO_DEVICES=1"
                     "GOWL_OUTPUT_SIZE=1280x800"
                     "GOWL_DISABLE_SYSTEMD=1"
                     "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                     "GOWL_SOCKET" "GOWL_MCP_SOCKET")))
    ;; Laid over an environment that has a session in it, the session is
    ;; gone: this is what keeps wlroots from opening a window on it.
    (let ((process-environment
           (append env '("WAYLAND_DISPLAY=wayland-1" "DISPLAY=:0"
                         "GOWL_SOCKET=/run/user/1000/gowl.sock"))))
      (should-not (getenv "WAYLAND_DISPLAY"))
      (should-not (getenv "DISPLAY"))
      (should-not (getenv "GOWL_SOCKET"))
      (should (equal (getenv "WLR_BACKENDS") "headless")))))

(ert-deftest cmacs-brigade-desktop-test-app-environment ()
  "Programs get the socket's absolute path and no X display."
  (should (equal (cmacs-brigade-desktop--app-environment "/s/run/wayland-0")
                 '(("WAYLAND_DISPLAY" . "/s/run/wayland-0")
                   ("GDK_BACKEND" . "wayland")
                   ("QT_QPA_PLATFORM" . "wayland")
                   ("DISPLAY" . ""))))
  (should (file-name-absolute-p
           (cmacs-brigade-desktop--wayland-path "/s/run"))))

(ert-deftest cmacs-brigade-desktop-test-resolution ()
  (should (equal (cmacs-brigade-desktop--parse-resolution "1280x800")
                 '(1280 . 800)))
  (should (equal (cmacs-brigade-desktop--parse-resolution "1920X1080")
                 '(1920 . 1080)))
  (dolist (bad '("1280" "32x800" "9000x800" "1280x800x24" "big" "" nil))
    (should-not (cmacs-brigade-desktop--parse-resolution bad))))

(ert-deftest cmacs-brigade-desktop-test-id-cannot-name-a-path ()
  "An id from a plan file never becomes a path component it chose."
  (should (equal (cmacs-brigade-desktop--dir-name "task-12") "task-12"))
  (dolist (id '("../../etc" "a/b" ".hidden" "two words" ""))
    (let ((name (cmacs-brigade-desktop--dir-name id)))
      (should (string-match-p "\\`x-[0-9a-f]\\{16\\}\\'" name)))))

(ert-deftest cmacs-brigade-desktop-test-long-socket-path-is-refused ()
  "A state directory too deep for a socket address is refused, by name."
  (should (cmacs-brigade-desktop--check-socket-path "/tmp/a/gowl-mcp.sock"))
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((cmacs-brigade-desktop-directory
            (expand-file-name (make-string 100 ?d) dir))
           (err (should-error (cmacs-brigade-desktop-start "task-1")
                              :type 'cmacs-brigade-desktop-error)))
      (should (string-match-p "gowl-mcp\\.sock" (cadr err)))
      (should (string-match-p (make-string 100 ?d) (cadr err)))
      ;; Refused before anything was made or started.
      (should-not (cmacs-brigade-desktop-list))
      (should-not (file-exists-p cmacs-brigade-desktop-directory)))))

(ert-deftest cmacs-brigade-desktop-test-layout-on-disk ()
  "A desktop's directory is private and holds the config that was generated."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((desktop (cmacs-brigade-desktop--create "task-1")))
      (should (equal (file-modes (cmacs-brigade-desktop--dir desktop)) #o700))
      (should (equal (file-modes (cmacs-brigade-desktop--run-dir desktop))
                     #o700))
      (should (equal (with-temp-buffer
                       (insert-file-contents
                        (cmacs-brigade-desktop--config desktop))
                       (buffer-string))
                     (cmacs-brigade-desktop--config-yaml)))
      (should (equal (file-modes (cmacs-brigade-desktop--log-file desktop))
                     #o600))
      (should (equal (cmacs-brigade-desktop--wayland desktop)
                     (expand-file-name "task-1/run/wayland-0" dir))))
    ;; A log that is a symlink is somebody choosing where gowl's output
    ;; gets written.
    (let ((log (expand-file-name "task-2/server.log" dir)))
      (make-directory (file-name-directory log) t)
      (make-symbolic-link (expand-file-name "elsewhere" dir) log)
      (should-error (cmacs-brigade-desktop--create "task-2")
                    :type 'cmacs-brigade-desktop-error)
      (should-not (file-exists-p (expand-file-name "elsewhere" dir))))))


;;;; Grants and the takeover

(ert-deftest cmacs-brigade-desktop-test-grants ()
  "Tools are admitted by class; recording and unclassed tools by nothing."
  (let ((all '(look act spawn)))
    (should (cmacs-brigade-desktop--tool-allowed-p "screenshot_monitor" '(look)))
    (should (cmacs-brigade-desktop--tool-allowed-p "screen_text" '(look)))
    (should-not (cmacs-brigade-desktop--tool-allowed-p "send_key" '(look)))
    (should (cmacs-brigade-desktop--tool-allowed-p "send_key" '(look act)))
    (should-not (cmacs-brigade-desktop--tool-allowed-p "spawn" '(look act)))
    (should (cmacs-brigade-desktop--tool-allowed-p "spawn" all))
    (should (cmacs-brigade-desktop--tool-allowed-p "desktop_launch" all))
    (dolist (tool '("start_recording" "drain_recording" "stop_recording"
                    "recording_status" "macro_record"))
      (should-not (cmacs-brigade-desktop--tool-allowed-p tool all))
      ;; Not even when somebody writes it into the grants.
      (should-not (cmacs-brigade-desktop--tool-allowed-p
                   tool '(look act spawn recording))))
    (dolist (tool '("compositor_quit" "signal_client" "add_keybind"
                    "list_clipboard" "macro_run" "a_tool_gowl_gains_later"))
      (should-not (cmacs-brigade-desktop--tool-allowed-p tool all)))))

(ert-deftest cmacs-brigade-desktop-test-grants-per-agent ()
  (let ((cmacs-brigade-desktop-grants '(look act spawn))
        (cmacs-brigade-desktop-agent-grants '((reviewer look)
                                              ("typist" look act))))
    (should (equal (cmacs-brigade-desktop-grants-for 'reviewer) '(look)))
    (should (equal (cmacs-brigade-desktop-grants-for "reviewer") '(look)))
    (should (equal (cmacs-brigade-desktop-grants-for 'typist) '(look act)))
    (should (equal (cmacs-brigade-desktop-grants-for 'anyone)
                   '(look act spawn)))
    (should (equal (cmacs-brigade-desktop-grants-for nil)
                   '(look act spawn)))))

(ert-deftest cmacs-brigade-desktop-test-takeover-refuses-acting ()
  "While a person holds the desktop the agent may look and not touch."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((socket (expand-file-name "gowl.sock" dir))
           (seen (list nil))
           (desktop (progn
                      (cmacs-brigade-desktop-tests--fake-gowl socket seen)
                      (cmacs-brigade-desktop-tests--desktop
                       "task-1" dir socket))))
      (should (cmacs-brigade-desktop-take "task-1"))
      (should (cmacs-brigade-desktop-held-p "task-1"))
      (dolist (tool '("send_key" "send_text" "send_mouse" "send_scroll"
                      "focus_client" "close_client" "spawn"
                      "desktop_click" "desktop_launch"))
        (should (string-match-p
                 "taken control"
                 (cmacs-brigade-desktop--refusal desktop tool nil 'agent))))
      (dolist (tool '("screenshot_monitor" "list_clients" "screen_text"
                      "desktop_screenshot"))
        (should-not (cmacs-brigade-desktop--refusal desktop tool nil 'agent)))
      ;; The person holding it is not refused.
      (should-not (cmacs-brigade-desktop--refusal desktop "send_key" nil
                                                  'human))
      ;; And it is enforced where the hands are, not only where it is
      ;; described: nothing reaches gowl.
      (pcase-let ((`(,ok ,value)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop-click "task-1" 5 5 "left" cb)))))
        (should-not ok)
        (should (string-match-p "taken control" value)))
      (should-not (cmacs-brigade-desktop-tests--calls seen))
      (pcase-let ((`(,ok ,_)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop-click "task-1" 5 5 "left" cb
                                                   'human)))))
        (should ok))
      (pcase-let ((`(,ok ,png)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop-screenshot "task-1" cb)))))
        (should ok)
        (should (equal (cmacs-brigade-desktop--png-size png) '(1280 . 800))))
      (should (cmacs-brigade-desktop-release "task-1"))
      (pcase-let ((`(,ok ,_)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop-key "task-1" "Return" cb)))))
        (should ok)))))

(ert-deftest cmacs-brigade-desktop-test-coordinates ()
  "A click on the scaled picture lands on the same spot of the desktop."
  ;; Shown at its own size.
  (should (equal (cmacs-brigade-desktop--map-point 100 50 1280 800 1280 800)
                 '(100 . 50)))
  ;; Shown at half size.
  (should (equal (cmacs-brigade-desktop--map-point 320 200 640 400 1280 800)
                 '(640 . 400)))
  ;; A scale-2 output: the picture is 2560 wide, the layout 1280.
  (should (equal (cmacs-brigade-desktop--map-point 2000 1000 2560 1600
                                                   1280 800)
                 '(1000 . 500)))
  ;; The picture's last pixel is the layout's last, never one past it.
  (should (equal (cmacs-brigade-desktop--map-point 640 400 640 400 1280 800)
                 '(1279 . 799)))
  (should (equal (cmacs-brigade-desktop--map-point -3 -3 640 400 1280 800)
                 '(0 . 0)))
  (should-not (cmacs-brigade-desktop--map-point 1 1 0 0 1280 800)))

(ert-deftest cmacs-brigade-desktop-test-view-keys ()
  "What is typed at the viewer becomes a named key or text."
  (should (equal (cmacs-brigade-desktop-view--key-name ?a) '(text . "a")))
  (should (equal (cmacs-brigade-desktop-view--key-name ?\s) '(text . " ")))
  (should (equal (cmacs-brigade-desktop-view--key-name ?\r)
                 '(key . "Return")))
  (should (equal (cmacs-brigade-desktop-view--key-name ?\d)
                 '(key . "BackSpace")))
  (should (equal (cmacs-brigade-desktop-view--key-name 'prior)
                 '(key . "Prior")))
  (should-not (cmacs-brigade-desktop-view--key-name ?\C-x))
  (should-not (cmacs-brigade-desktop-view--key-name 'mouse-1))
  ;; Emacs keeps its own prefixes while you hold the desktop.
  (should-not (lookup-key cmacs-brigade-desktop-view-control-mode-map
                          (kbd "C-x")))
  (should (eq (lookup-key cmacs-brigade-desktop-view-control-mode-map "r")
              #'cmacs-brigade-desktop-view-forward-key)))


;;;; The JSON-RPC client

(ert-deftest cmacs-brigade-desktop-test-rpc-client ()
  "The line client handshakes, skips lines that answer nothing, and reports failures."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((socket (expand-file-name "gowl.sock" dir))
          (seen (list nil)))
      (cmacs-brigade-desktop-tests--fake-gowl socket seen)
      ;; An MCP call: initialize, the initialized notification, the call.
      (pcase-let ((`(,ok ,result)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--mcp-call
                       socket "list_clients" nil cb)))))
        (should ok)
        (should (equal (cmacs-brigade-desktop--result-text result)
                       "[{\"id\":1}]")))
      (should (equal (mapcar (lambda (m) (alist-get 'method m))
                             (reverse (car seen)))
                     '("initialize" "notifications/initialized"
                       "tools/call")))
      ;; No arguments means no `arguments' member, as clawtilla sends it.
      (should-not (assq 'arguments (alist-get 'params (car (car seen)))))
      ;; Arguments arrive as an object.
      (cmacs-brigade-desktop-tests--await
       (lambda (cb)
         (cmacs-brigade-desktop--mcp-call
          socket "send_mouse_move" '(:x 10 :y 20) cb)))
      (should (equal (alist-get 'arguments
                                (alist-get 'params (car (car seen))))
                     '((x . 10) (y . 20))))
      ;; A picture comes back as bytes.
      (pcase-let ((`(,ok ,result)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--mcp-call
                       socket "screenshot_monitor" nil cb)))))
        (should ok)
        (should (equal (cmacs-brigade-desktop--result-image result)
                       cmacs-brigade-desktop-tests--png)))
      ;; isError is a failure, in the server's own words.
      (pcase-let ((`(,ok ,message)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--mcp-call
                       socket "close_client" '(:id 9) cb)))))
        (should-not ok)
        (should (equal message "close_client refused: no such window")))
      ;; The IPC socket: one request, a result or an error.
      (pcase-let ((`(,ok ,result)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--ipc-call
                       socket "spawn" '(:command "true") cb)))))
        (should ok)
        (should (equal (alist-get 'pid result) 4242)))
      (pcase-let ((`(,ok ,message)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--ipc-call
                       socket "no.such" nil cb)))))
        (should-not ok)
        (should (equal message "no method no.such")))
      ;; Nothing listening: a failure that names the socket, not a signal.
      (pcase-let ((`(,ok ,message)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--ipc-call
                       (expand-file-name "absent.sock" dir)
                       "rpc.ping" nil cb)))))
        (should-not ok)
        (should (string-match-p "absent\\.sock" message))))))

(ert-deftest cmacs-brigade-desktop-test-ids-answered-as-strings ()
  "A server that answers id 1 as \"1\" is still understood, relay included."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((cmacs-brigade-desktop-tests--string-ids t)
           (socket (expand-file-name "gowl.sock" dir))
           (seen (list nil))
           (desktop (progn
                      (cmacs-brigade-desktop-tests--fake-gowl socket seen)
                      (cmacs-brigade-desktop-tests--desktop
                       "task-1" dir socket))))
      (should (cmacs-brigade-desktop--same-id-p 1 "1"))
      (should-not (cmacs-brigade-desktop--same-id-p 1 "2"))
      (should-not (cmacs-brigade-desktop--same-id-p nil nil))
      (pcase-let ((`(,ok ,text)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop-windows "task-1" cb)))))
        (should ok)
        (should (equal text "[{\"id\":1}]")))
      (cmacs-brigade-desktop--relay-start desktop)
      (pcase-let ((`(,ok ,result)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--rpc
                       (cmacs-brigade-desktop--relay-socket desktop)
                       '((:jsonrpc "2.0" :id 1 :method "initialize")
                         (:jsonrpc "2.0" :id 2 :method "tools/list"))
                       cb)))))
        (should ok)
        (should (equal (mapcar (lambda (tool) (alist-get 'name tool))
                               (alist-get 'tools result))
                       '("list_clients" "screenshot_monitor" "send_key"
                         "spawn")))))))

(ert-deftest cmacs-brigade-desktop-test-rpc-client-times-out ()
  "A server that never answers costs a timeout, not the editor."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((socket (expand-file-name "mute.sock" dir))
          (cmacs-brigade-desktop-call-timeout 0.3))
      (make-network-process :name "cbd-test-mute" :server t :family 'local
                            :service socket :noquery t :filter #'ignore)
      (pcase-let ((`(,ok ,message)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--ipc-call
                       socket "rpc.ping" nil cb)))))
        (should-not ok)
        (should (string-match-p "no answer" message))))))

(ert-deftest cmacs-brigade-desktop-test-click-is-a-move-then-a-press ()
  "gowl clicks where the pointer is, so a click moves it there first."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((socket (expand-file-name "gowl.sock" dir))
          (seen (list nil)))
      (cmacs-brigade-desktop-tests--fake-gowl socket seen)
      (cmacs-brigade-desktop-tests--desktop "task-1" dir socket)
      (cmacs-brigade-desktop-tests--await
       (lambda (cb)
         (cmacs-brigade-desktop-click "task-1" 30 40 "right" cb)))
      (should (equal (cmacs-brigade-desktop-tests--calls seen)
                     '("send_mouse_move" "send_mouse")))
      (should (equal (alist-get 'arguments (alist-get 'params (car (car seen))))
                     '((button . "right") (action . "click"))))
      (setcar seen nil)
      (cmacs-brigade-desktop-tests--await
       (lambda (cb)
         (cmacs-brigade-desktop-scroll "task-1" 30 40 "down" 3 cb)))
      (should (equal (cmacs-brigade-desktop-tests--calls seen)
                     '("send_mouse_move" "send_scroll")))
      ;; One key is gowl's MCP `send_key'; a combination is the IPC
      ;; socket's `window.send_key', which understands modifiers.
      (setcar seen nil)
      (cmacs-brigade-desktop-tests--await
       (lambda (cb) (cmacs-brigade-desktop-key "task-1" "Ctrl+s" cb)))
      (should (equal (alist-get 'method (car (car seen))) "window.send_key"))
      (should-not (cmacs-brigade-desktop-tests--calls seen)))))


;;;; The relay

(ert-deftest cmacs-brigade-desktop-test-relay-verdicts ()
  "What the relay does with each kind of line an agent can send."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((desktop (cmacs-brigade-desktop-tests--desktop
                    "task-1" dir (expand-file-name "none.sock" dir)))
          (call (lambda (tool &optional id)
                  (json-serialize
                   (append (list :jsonrpc "2.0")
                           (and id (list :id id))
                           (list :method "tools/call"
                                 :params (list :name tool)))))))
      (cl-flet ((verdict (line)
                  (cmacs-brigade-desktop--relay-verdict desktop line)))
        (should (equal (verdict (funcall call "screenshot_monitor" 1))
                       '(forward)))
        (should (equal (verdict (funcall call "send_key" 2)) '(forward)))
        (should (equal (verdict "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}")
                       '(list 3)))
        (should (equal (verdict "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\"}")
                       '(forward)))
        (should (equal (verdict "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
                       '(forward)))
        ;; Never relayed, whatever the grants.
        (dolist (tool '("start_recording" "compositor_quit" "signal_client"))
          (pcase (verdict (funcall call tool 5))
            (`(reply ,object)
             (should (eq (plist-get (plist-get object :result) :isError) t))
             (should (equal (plist-get object :id) 5)))
            (other (ert-fail (format "%s was not refused: %S" tool other)))))
        ;; A refused notification has nobody to tell.
        (should (equal (verdict (funcall call "compositor_quit")) '(drop)))
        ;; A call inside an array is still a call.
        (should (eq (car (verdict (concat "[" (funcall call "spawn" 6) "]")))
                    'reply))
        ;; Methods outside the handful an MCP client needs.
        (pcase (verdict "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"resources/list\"}")
          (`(reply ,object)
           (should (equal (plist-get (plist-get object :error) :code)
                          -32601)))
          (other (ert-fail (format "resources/list: %S" other))))
        (should (eq (car (verdict "not json")) 'reply))
        ;; Grants cut it down further...
        (let ((cmacs-brigade-desktop-grants '(look)))
          (should (equal (verdict (funcall call "list_clients" 8)) '(forward)))
          (should (eq (car (verdict (funcall call "send_key" 9))) 'reply))
          (should (eq (car (verdict (funcall call "spawn" 10))) 'reply)))
        ;; ...and so does a person holding the desktop.
        (cmacs-brigade-desktop-take "task-1")
        (should (equal (verdict (funcall call "screenshot_monitor" 11))
                       '(forward)))
        (pcase (verdict (funcall call "send_key" 12))
          (`(reply ,object)
           (should (string-match-p
                    "taken control"
                    (plist-get (aref (plist-get (plist-get object :result)
                                                :content)
                                     0)
                               :text))))
          (other (ert-fail (format "send_key while held: %S" other))))))))

(ert-deftest cmacs-brigade-desktop-test-relay-end-to-end ()
  "An agent talking to the relay sees only its tools and cannot call the rest."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((socket (expand-file-name "gowl.sock" dir))
           (seen (list nil))
           (desktop (progn
                      (cmacs-brigade-desktop-tests--fake-gowl socket seen)
                      (cmacs-brigade-desktop-tests--desktop
                       "task-1" dir socket)))
           (relay (cmacs-brigade-desktop--relay-socket desktop))
           (list-tools
            (lambda ()
              (pcase-let ((`(,ok ,result)
                           (cmacs-brigade-desktop-tests--await
                            (lambda (cb)
                              (cmacs-brigade-desktop--rpc
                               relay
                               '((:jsonrpc "2.0" :id 1 :method "initialize")
                                 (:jsonrpc "2.0" :id 2 :method "tools/list"))
                               cb)))))
                (should ok)
                (mapcar (lambda (tool) (alist-get 'name tool))
                        (alist-get 'tools result))))))
      (cmacs-brigade-desktop--relay-start desktop)
      (should (file-exists-p relay))
      (should (equal (file-modes relay) #o600))
      ;; gowl offered six; recording and quitting are not passed on.
      (should (equal (funcall list-tools)
                     '("list_clients" "screenshot_monitor" "send_key"
                       "spawn")))
      (let ((cmacs-brigade-desktop-grants '(look)))
        (should (equal (funcall list-tools)
                       '("list_clients" "screenshot_monitor"))))
      ;; A granted call goes through to gowl, picture and all.
      (pcase-let ((`(,ok ,result)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--mcp-call
                       relay "screenshot_monitor" nil cb)))))
        (should ok)
        (should (equal (cmacs-brigade-desktop--result-image result)
                       cmacs-brigade-desktop-tests--png)))
      ;; A call that is not granted is answered by the relay; gowl never
      ;; hears of it.
      (setcar seen nil)
      (pcase-let ((`(,ok ,message)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--mcp-call
                       relay "compositor_quit" nil cb)))))
        (should-not ok)
        (should (string-match-p "not among the tools" message)))
      (should-not (cmacs-brigade-desktop-tests--calls seen))
      ;; Held: acting is refused in the takeover's sentence.
      (cmacs-brigade-desktop-take "task-1")
      (pcase-let ((`(,ok ,message)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--mcp-call
                       relay "send_key" '(:key "a") cb)))))
        (should-not ok)
        (should (string-match-p "taken control" message)))
      (should-not (cmacs-brigade-desktop-tests--calls seen))
      (cmacs-brigade-desktop--relay-stop desktop)
      (should-not (file-exists-p relay)))))


;;;; The agent's tools

(ert-deftest cmacs-brigade-desktop-test-tools-reach-only-the-callers-desktop ()
  "A desktop tool acts on the calling task's desktop and can name no other."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((mine (expand-file-name "mine.sock" dir))
          (theirs (expand-file-name "theirs.sock" dir))
          (seen-mine (list nil))
          (seen-theirs (list nil)))
      (cmacs-brigade-desktop-tests--fake-gowl mine seen-mine)
      (cmacs-brigade-desktop-tests--fake-gowl theirs seen-theirs)
      (cmacs-brigade-desktop-tests--desktop "task-1" dir mine)
      (cmacs-brigade-desktop-tests--desktop "task-2" dir theirs)
      ;; The tools take no desktop at all.
      (dolist (name '(desktop-screenshot desktop-windows desktop-text
                      desktop-launch desktop-key desktop-type
                      desktop-click desktop-scroll))
        (let ((tool (cmacs-brigade-registry-get 'tool name)))
          (should tool)
          (should (eq (cmacs-brigade-tool-group tool) 'desktop))
          (should (cmacs-brigade-tool-async tool))
          (should-not (cl-find-if
                       (lambda (p)
                         (string-match-p "desktop\\|socket\\|task\\|agent"
                                         (plist-get p :name)))
                       (cmacs-brigade-tool-params tool)))))
      (should (equal (cmacs-brigade-call-tool
                      "desktop_click" "{\"x\":10,\"y\":20}"
                      'tester nil "task-1")
                     "Clicked left at 10, 20."))
      (should (equal (cmacs-brigade-desktop-tests--calls seen-mine)
                     '("send_mouse_move" "send_mouse")))
      (should-not (car seen-theirs))
      ;; An extra argument naming somebody else's desktop changes nothing.
      (setcar seen-mine nil)
      (should (equal (cmacs-brigade-call-tool
                      "desktop_key"
                      "{\"key\":\"Return\",\"desktop\":\"task-2\",\"id\":\"task-2\"}"
                      'tester nil "task-1")
                     "Pressed Return."))
      (should (equal (cmacs-brigade-desktop-tests--calls seen-mine)
                     '("send_key")))
      (should-not (car seen-theirs))
      ;; No task, no desktop: an external MCP client, a chat buffer.
      (should (string-match-p
               "\\`Error: this call came from no brigade task"
               (cmacs-brigade-call-tool "desktop_click"
                                        "{\"x\":1,\"y\":1}" "mcp")))
      ;; A task without one.
      (should (string-match-p
               "\\`Error: this task has no desktop"
               (cmacs-brigade-call-tool "desktop_windows" "{}"
                                        'tester nil "task-9")))
      ;; The caller noted for one call is not left for the next.
      (should-not cmacs-brigade-desktop--caller)
      ;; A picture reaches the model as a file of the desktop's own.
      (let ((answer (cmacs-brigade-call-tool "desktop_screenshot" "{}"
                                             'tester nil "task-1")))
        (should (string-match "1280x800 pixels, saved as \\(.*\\.png\\)\\."
                              answer))
        (let ((file (match-string 1 answer)))
          (should (file-in-directory-p file (expand-file-name "task-1" dir)))
          (should (equal (file-modes file) #o600))))
      ;; Grants and the takeover apply to the brigade's tools too.
      (let ((cmacs-brigade-desktop-agent-grants '((tester look))))
        (should (string-match-p
                 "not among the tools"
                 (cmacs-brigade-call-tool "desktop_type" "{\"text\":\"x\"}"
                                          'tester nil "task-1")))
        (should (equal (cmacs-brigade-call-tool "desktop_windows" "{}"
                                                'tester nil "task-1")
                       "[{\"id\":1}]")))
      (cmacs-brigade-desktop-take "task-1")
      (setcar seen-mine nil)
      (should (string-match-p
               "taken control"
               (cmacs-brigade-call-tool "desktop_type" "{\"text\":\"x\"}"
                                        'tester nil "task-1")))
      (should-not (cmacs-brigade-desktop-tests--calls seen-mine)))))


;;;; The isolation providers

(ert-deftest cmacs-brigade-desktop-test-providers-are-registered ()
  (dolist (kind '(desktop desktop-worktree desktop-podman))
    (let ((provider (cmacs-brigade-registry-get 'isolation kind)))
      (should provider)
      (should (functionp (plist-get provider :prepare)))
      (should (functionp (plist-get provider :teardown)))))
  (should (cmacs-brigade-registry-get 'panel 'desktops)))

(ert-deftest cmacs-brigade-desktop-test-prepare-returns-what-a-worker-needs ()
  "Prepare hands back the environment at once and teardown undoes it."
  (cmacs-brigade-desktop-tests--sandbox dir
    ;; No gowl is found, so nothing is started; the plist does not depend
    ;; on one.
    (let* ((cmacs-brigade-desktop-gowl-program
            (expand-file-name "no-such-gowl" dir))
           (cmacs-brigade-desktop-relay-program "/usr/bin/true")
           (prepared (cmacs-brigade-desktop--prepare "task-1"))
           (env (plist-get prepared :env))
           (wayland (expand-file-name "task-1/run/wayland-0" dir)))
      (should (equal (cdr (assoc "WAYLAND_DISPLAY" env)) wayland))
      (should (equal (cdr (assoc "GDK_BACKEND" env)) "wayland"))
      (should (equal (cdr (assoc "QT_QPA_PLATFORM" env)) "wayland"))
      (should (equal (cdr (assoc "DISPLAY" env)) ""))
      (should (equal (cdr (assoc "CMACS_BRIGADE_DESKTOP" env)) "task-1"))
      ;; Every entry is a pair of strings: the worker formats them with
      ;; "%s=%s" and anything else would be exported as "nil".
      (dolist (cell env)
        (should (and (stringp (car cell)) (stringp (cdr cell)))))
      (should (plist-get prepared :cwd))
      (should (equal (plist-get prepared :desktop) "task-1"))
      ;; The MCP endpoint is the relay, never gowl's own socket.
      (let ((server (car (plist-get prepared :mcp-servers))))
        (should (equal (plist-get server :name) "desktop"))
        (should (equal (plist-get server :args)
                       (list "--socket"
                             (expand-file-name "task-1/relay.sock" dir))))
        (should-not (string-match-p "gowl-mcp\\.sock"
                                    (format "%S" prepared))))
      ;; The start fails -- the binary does not exist -- and says so.
      (pcase-let ((`(,_id ,ok)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop-start "task-1" cb)))))
        (should-not ok))
      (let ((status (cmacs-brigade-desktop-status "task-1")))
        (should (eq (plist-get status :state) 'failed))
        (should (string-match-p "no-such-gowl" (plist-get status :reason))))
      (cmacs-brigade-desktop--teardown "task-1")
      (should-not (cmacs-brigade-desktop-list))
      ;; Twice, and for an agent that never had one.
      (cmacs-brigade-desktop--teardown "task-1")
      (cmacs-brigade-desktop--teardown "never"))))

(ert-deftest cmacs-brigade-desktop-test-podman-gets-the-socket-file-alone ()
  "A container is given the Wayland socket, never the directory it is in."
  (let* ((wayland "/s/desktops/task-1/run/wayland-0")
         (cmacs-brigade-desktop-podman-args '("--security-opt" "label=disable"))
         (args (cmacs-brigade-desktop--podman-mount-args wayland))
         (volumes (cl-loop for (flag value) on args
                           when (equal flag "--volume") collect value)))
    (should (equal volumes (list (concat wayland ":" wayland))))
    (should-not (cl-find-if (lambda (v) (string-match-p "/run[:/]?\\'" v))
                            volumes))
    (should (member "WAYLAND_DISPLAY=/s/desktops/task-1/run/wayland-0" args))
    (should (member "GDK_BACKEND=wayland" args))
    (should (equal (last args 2) '("--security-opt" "label=disable")))))

(ert-deftest cmacs-brigade-desktop-test-candidate-without-mcp-is-passed-over ()
  "A gowl that runs but lists no mcp module is skipped, with the reason kept."
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((plain (expand-file-name "gowl-plain" dir))
           (broken (expand-file-name "gowl-broken" dir))
           (good (expand-file-name "gowl-good" dir))
           (cmacs-brigade-desktop--trusted nil)
           (script (lambda (file body)
                     (with-temp-file file (insert "#!/bin/sh\n" body "\n"))
                     (set-file-modes file #o700))))
      (funcall script broken "echo 'cannot open shared object file' >&2; exit 127")
      (funcall script plain
               "case \"$1\" in --version) echo 'gowl 0.5.0';; *) echo '  ipc   IPC handler';; esac")
      (funcall script good
               "case \"$1\" in --version) echo 'gowl 0.5.0';; *) echo '  ipc   IPC handler'; echo '  mcp   MCP server';; esac")
      (pcase-let ((`(,program ,notes)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--locate
                       cb (list broken plain good))))))
        (should (equal program good))
        (should (equal (length notes) 2))
        (should (string-match-p "does not run: cannot open shared object"
                                (nth 0 notes)))
        (should (string-match-p "has no mcp module" (nth 1 notes))))
      (pcase-let ((`(,program ,notes)
                   (cmacs-brigade-desktop-tests--await
                    (lambda (cb)
                      (cmacs-brigade-desktop--locate cb (list broken))))))
        (should-not program)
        (should (equal (length notes) 1))))))


;;;; A real one

(defun cmacs-brigade-desktop-tests--working-gowl ()
  "Return a gowl binary to try, or nil.  Only its existence is checked."
  (car (cmacs-brigade-desktop--candidates)))

(ert-deftest cmacs-brigade-desktop-test-real-start-and-stop ()
  "Start a headless gowl of our own, look at it, and stop it.

Skipped unless CMACS_TEST_DESKTOP is set and a gowl exists.  Headless
and in a directory of its own: it does not touch a running session."
  (skip-unless (getenv "CMACS_TEST_DESKTOP"))
  (skip-unless (cmacs-brigade-desktop-tests--working-gowl))
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((cmacs-brigade-desktop--trusted nil)
          (cmacs-brigade-desktop-scale 1.0)
          (cmacs-brigade-desktop-resolution "1280x800")
          (pid nil))
      (unwind-protect
          (progn
            (pcase-let ((`(,_id ,ok)
                         (let ((cmacs-brigade-desktop-start-timeout 20))
                           (cmacs-brigade-desktop-tests--await
                            (lambda (cb)
                              (cmacs-brigade-desktop-start "real" cb))))))
              (unless ok
                (ert-fail (format "the desktop did not start: %S"
                                  (cmacs-brigade-desktop-status "real")))))
            (let ((status (cmacs-brigade-desktop-status "real")))
              (setq pid (plist-get status :pid))
              (should (eq (plist-get status :state) 'ready))
              (should (integerp pid))
              (should (file-exists-p (plist-get status :wayland)))
              (should (file-exists-p (plist-get status :relay))))
            (pcase-let ((`(,ok ,png)
                         (cmacs-brigade-desktop-tests--await
                          (lambda (cb)
                            (cmacs-brigade-desktop-screenshot "real" cb)))))
              (should ok)
              (should (equal (cmacs-brigade-desktop--png-size png)
                             '(1280 . 800))))
            (pcase-let ((`(,ok ,text)
                         (cmacs-brigade-desktop-tests--await
                          (lambda (cb)
                            (cmacs-brigade-desktop-windows "real" cb)))))
              (should ok)
              (should (stringp text)))
            ;; Through the relay, as an agent would: the list is cut down.
            (pcase-let ((`(,ok ,result)
                         (cmacs-brigade-desktop-tests--await
                          (lambda (cb)
                            (cmacs-brigade-desktop--rpc
                             (plist-get (cmacs-brigade-desktop-status "real")
                                        :relay)
                             `((:jsonrpc "2.0" :id 1 :method "initialize"
                                :params (:protocolVersion "2024-11-05"
                                         :capabilities nil
                                         :clientInfo (:name "test"
                                                      :version "0")))
                               (:jsonrpc "2.0"
                                :method "notifications/initialized")
                               (:jsonrpc "2.0" :id 2 :method "tools/list"))
                             cb)))))
              (should ok)
              (let ((names (mapcar (lambda (tool) (alist-get 'name tool))
                                   (alist-get 'tools result))))
                (should (member "screenshot_monitor" names))
                (should (member "send_key" names))
                (should-not (member "start_recording" names))
                (should-not (member "compositor_quit" names)))))
        (cmacs-brigade-desktop-stop "real"))
      (should-not (cmacs-brigade-desktop-list))
      ;; gowl is asked to exit and does; its sockets go with it.
      (let ((deadline (+ (float-time) 10)))
        (while (and pid (file-exists-p (format "/proc/%d" pid))
                    (< (float-time) deadline))
          (accept-process-output nil 0.1)))
      (should-not (and pid (file-exists-p (format "/proc/%d" pid))))
      (should-not (file-exists-p (expand-file-name "real/run" dir))))))


;;;; CLI agents: the MCP config and the task behind a scoped socket
;;
;; A CLI agent is another process.  It gets its desktop two ways, and
;; both are tested against the real thing rather than a description of
;; it: the config `cmacs-brigade-host-provision' writes (in every
;; dialect, from the plist the provider really returns), and a tool call
;; made over a real socket by a client that is not the brigade.

(require 'cmacs-brigade-host)

(defun cmacs-brigade-desktop-tests--mcp-call (socket tool arguments)
  "Call TOOL with ARGUMENTS, a JSON object string, as an MCP client of SOCKET.
Returns the text of the answer.  The client is a plain socket speaking
JSON-RPC: what an agent with a shell has, with no relay in between."
  (let* ((out "")
         (proc (make-network-process
                :name "cbd-test-mcp-client" :family 'local :service socket
                :noquery t :coding 'utf-8-unix
                :filter (lambda (_p s) (setq out (concat out s)))))
         (answer nil))
    (unwind-protect
        (progn
          (process-send-string
           proc
           (concat "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                   "\"params\":{\"protocolVersion\":\"2024-11-05\","
                   "\"capabilities\":{},\"clientInfo\":{\"name\":\"ert\","
                   "\"version\":\"0\"}}}\n"
                   "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
                   "\"params\":{\"name\":\"" tool "\",\"arguments\":"
                   arguments "}}\n"))
          (let ((deadline (+ (float-time) 15)))
            (while (and (not answer) (< (float-time) deadline))
              (accept-process-output nil 0.05)
              (dolist (line (split-string out "\n" t))
                (let ((message (ignore-errors
                                 (json-parse-string line :object-type 'alist
                                                    :array-type 'list))))
                  (when (equal (alist-get 'id message) 2)
                    (setq answer message))))))
          (unless answer
            (ert-fail (format "no answer to %s; got %S" tool out)))
          (or (alist-get 'text
                         (car (alist-get 'content
                                         (alist-get 'result answer))))
              (alist-get 'message (alist-get 'error answer))
              (format "%S" answer)))
      (ignore-errors (delete-process proc)))))

(defvar cmacs-brigade-desktop-tests--injected nil
  "Set by a task id that escaped its string, which must never happen.")

(ert-deftest cmacs-brigade-desktop-test-scoped-socket-call-is-its-tasks ()
  "A tool call over a scoped socket is made for the task the scope was opened for.

This is how a CLI agent's `desktop_*' calls find its desktop.  The task
comes from the scope's record in the editor; the client is not asked,
and what it volunteers is not believed."
  (skip-unless (fboundp 'cmacs-brigade-scope-open))
  (skip-unless (equal (func-arity 'cmacs-brigade-scope-open) '(1 . 2)))
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((mine (expand-file-name "mine.sock" dir))
           (theirs (expand-file-name "theirs.sock" dir))
           (seen-mine (list nil))
           (seen-theirs (list nil))
           (allow "desktop_key,desktop_windows,desktop_click")
           (scopes nil)
           (open (lambda (task)
                   (car (push (cmacs-brigade-scope-open allow task)
                              scopes)))))
      (cmacs-brigade-desktop-tests--fake-gowl mine seen-mine)
      (cmacs-brigade-desktop-tests--fake-gowl theirs seen-theirs)
      (cmacs-brigade-desktop-tests--desktop "task-1" dir mine)
      (cmacs-brigade-desktop-tests--desktop "task-2" dir theirs)
      (unwind-protect
          (progn
            ;; The scope for task-1 reaches task-1's desktop.
            (let ((scope (funcall open "task-1")))
              (should (equal (cmacs-brigade-desktop-tests--mcp-call
                              scope "desktop_key" "{\"key\":\"Return\"}")
                             "Pressed Return."))
              (should (equal (cmacs-brigade-desktop-tests--calls seen-mine)
                             '("send_key")))
              (should-not (car seen-theirs))
              ;; ...and no other, whatever the client says about itself.
              ;; Every name a client might hope is read: none is.
              (setcar seen-mine nil)
              (should (equal
                       (cmacs-brigade-desktop-tests--mcp-call
                        scope "desktop_key"
                        (concat "{\"key\":\"Return\",\"task\":\"task-2\","
                                "\"task_id\":\"task-2\","
                                "\"desktop\":\"task-2\",\"id\":\"task-2\","
                                "\"agent\":\"task-2\"}"))
                       "Pressed Return."))
              (should (equal (cmacs-brigade-desktop-tests--calls seen-mine)
                             '("send_key")))
              (should-not (car seen-theirs)))
            ;; Task 2's scope is task 2's, on the same registry.
            (setcar seen-mine nil)
            (should (equal (cmacs-brigade-desktop-tests--mcp-call
                            (funcall open "task-2") "desktop_windows" "{}")
                           "[{\"id\":1}]"))
            (should (equal (cmacs-brigade-desktop-tests--calls seen-theirs)
                           '("list_clients")))
            (should-not (cmacs-brigade-desktop-tests--calls seen-mine))
            ;; A scope for a task with no desktop gets neither.
            (setcar seen-theirs nil)
            (should (string-match-p
                     "\\`Error: this task has no desktop"
                     (cmacs-brigade-desktop-tests--mcp-call
                      (funcall open "task-9") "desktop_windows" "{}")))
            ;; A scope opened for no task -- a harness buffer's, a chat's
            ;; -- belongs to none, with the tools on its allowlist or not.
            (dolist (task '(nil ""))
              (should (string-match-p
                       "\\`Error: this call came from no brigade task"
                       (cmacs-brigade-desktop-tests--mcp-call
                        (funcall open task) "desktop_click"
                        "{\"x\":1,\"y\":1,\"task\":\"task-1\"}"))))
            ;; A task id is data.  One written to end the string it is
            ;; spliced into names a task nobody has, and evaluates nothing.
            (setq cmacs-brigade-desktop-tests--injected nil)
            (should (string-match-p
                     "\\`Error: this task has no desktop"
                     (cmacs-brigade-desktop-tests--mcp-call
                      (funcall
                       open
                       (concat "task-1\") (setq cmacs-brigade-desktop-tests"
                               "--injected t) (ignore \"\\"))
                      "desktop_windows" "{}")))
            (should-not cmacs-brigade-desktop-tests--injected)
            (should-not (car seen-mine))
            (should-not (car seen-theirs))
            (should-not cmacs-brigade-desktop--caller))
        (dolist (scope scopes)
          (ignore-errors (cmacs-brigade-scope-close scope)))))))

(ert-deftest cmacs-brigade-desktop-test-unscoped-mcp-client-has-no-task ()
  "The plain cmacs socket serves no task: its `desktop_*' calls are refused.

An external MCP client is whoever connected.  It may see the desktop
tools; it has no desktop for them to mean, and saying it is task-1 does
not give it task-1's."
  (skip-unless (and (fboundp 'cmacs-mcp-start)
                    (fboundp 'cmacs-mcp-socket-path)))
  (unless (cmacs-mcp-socket-path)
    (ignore-errors (cmacs-mcp-start)))
  (skip-unless (cmacs-mcp-socket-path))
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((mine (expand-file-name "mine.sock" dir))
          (seen-mine (list nil)))
      (cmacs-brigade-desktop-tests--fake-gowl mine seen-mine)
      (cmacs-brigade-desktop-tests--desktop "task-1" dir mine)
      (should (string-match-p
               "\\`Error: this call came from no brigade task"
               (cmacs-brigade-desktop-tests--mcp-call
                (cmacs-mcp-socket-path) "desktop_key"
                "{\"key\":\"Return\",\"task\":\"task-1\"}")))
      (should-not (car seen-mine)))))

(ert-deftest cmacs-brigade-desktop-test-provision-task-reaches-the-scope ()
  "`cmacs-brigade-host-provision' opens its scope for the task it is given.
The whole path a CLI agent's call takes, minus the agent: provision as
the run does, read the socket out of the config the agent would be
handed, and call a desktop tool on it."
  (skip-unless (and (fboundp 'cmacs-brigade-scope-open)
                    (fboundp 'cmacs-mcp-start)))
  (skip-unless (equal (func-arity 'cmacs-brigade-scope-open) '(1 . 2)))
  (unless (cmacs-mcp-socket-path)
    (ignore-errors (cmacs-mcp-start)))
  (skip-unless (cmacs-mcp-socket-path))
  (cmacs-brigade-desktop-tests--sandbox dir
    (let ((mine (expand-file-name "mine.sock" dir))
          (seen-mine (list nil))
          (cmacs-brigade-desktop-relay-program "/usr/bin/true"))
      (cmacs-brigade-desktop-tests--fake-gowl mine seen-mine)
      (cmacs-brigade-desktop-tests--desktop "task-1" dir mine)
      (unwind-protect
          (let* ((prepared (cmacs-brigade-desktop--prepared "task-1"))
                 (endpoint (cmacs-brigade-host-provision
                            "task-1" "desktop_windows"
                            :extra-servers (plist-get prepared :mcp-servers)
                            :task "task-1"))
                 (text (with-temp-buffer
                         (insert-file-contents (plist-get endpoint :path))
                         (buffer-string)))
                 (config (json-parse-string text :object-type 'plist))
                 (servers (plist-get config :mcpServers))
                 (socket (plist-get (plist-get (plist-get servers :cmacs)
                                               :env)
                                    :CMACS_BRIGADE_SOCKET)))
            (should (plist-get endpoint :scope))
            (should (equal socket (plist-get endpoint :scope)))
            ;; The agent is not told its task: nothing it could send back.
            (should-not (string-match-p "task-1\"" (format "%S" (plist-get
                                                                  (plist-get servers :cmacs)
                                                                  :env))))
            (should (equal (cmacs-brigade-desktop-tests--mcp-call
                            socket "desktop_windows" "{}")
                           "[{\"id\":1}]"))
            (should (equal (cmacs-brigade-desktop-tests--calls seen-mine)
                           '("list_clients")))
            ;; And the same provision, for no task, serves none.
            (let ((bare (cmacs-brigade-host-provision
                         "harness-x" "desktop_windows")))
              (unwind-protect
                  (should (string-match-p
                           "\\`Error: this call came from no brigade task"
                           (cmacs-brigade-desktop-tests--mcp-call
                            (plist-get bare :scope) "desktop_windows" "{}")))
                (cmacs-brigade-host-revoke "harness-x"))))
        (cmacs-brigade-host-revoke "task-1")))))

(ert-deftest cmacs-brigade-desktop-test-mcp-server-in-every-dialect ()
  "The desktop's own MCP server is written beside cmacs in every config dialect.

Provisioned, not emitted, and from the plist the provider really
returns: an emitter called with the shape it would like is how a dialect
came to crash on the shape it is actually given."
  (skip-unless (fboundp 'cmacs-mcp-start))
  (unless (cmacs-mcp-socket-path)
    (ignore-errors (cmacs-mcp-start)))
  (skip-unless (cmacs-mcp-socket-path))
  (cmacs-brigade-desktop-tests--sandbox dir
    (let* ((cmacs-brigade-desktop-relay-program "/usr/bin/true")
           (relay-socket (expand-file-name "task-1/relay.sock" dir)))
      (cmacs-brigade-desktop-tests--desktop
       "task-1" dir (expand-file-name "gowl.sock" dir))
      (let ((servers (plist-get (cmacs-brigade-desktop--prepared "task-1")
                                :mcp-servers)))
        (should servers)
        (should (>= (length cmacs-brigade-host-config-formats) 4))
        (dolist (format (mapcar #'car cmacs-brigade-host-config-formats))
          (let ((agent (format "cbd-fmt-%s" format)))
            (unwind-protect
                (let* ((endpoint (cmacs-brigade-host-provision
                                  agent "desktop" :format format
                                  :extra-servers servers :task "task-1"))
                       (text (with-temp-buffer
                               (insert-file-contents
                                (plist-get endpoint :path))
                               (buffer-string))))
                  (should (eq (plist-get endpoint :format) format))
                  ;; The cmacs server is still there, with its socket.
                  (should (string-match-p "CMACS_BRIGADE_SOCKET" text))
                  (pcase format
                    ('claude
                     (let* ((config (json-parse-string
                                     text :object-type 'plist
                                     :array-type 'list))
                            (all (plist-get config :mcpServers))
                            (desktop (plist-get all :desktop)))
                       (should (plist-get all :cmacs))
                       (should (equal (plist-get desktop :command)
                                      "/usr/bin/true"))
                       (should (equal (plist-get desktop :args)
                                      (list "--socket" relay-socket)))))
                    ('opencode
                     (let* ((config (json-parse-string
                                     text :object-type 'plist
                                     :array-type 'list))
                            (all (plist-get config :mcp))
                            (desktop (plist-get all :desktop)))
                       (should (plist-get all :cmacs))
                       (should (equal (plist-get desktop :type) "local"))
                       (should (eq (plist-get desktop :enabled) t))
                       (should (equal (plist-get desktop :command)
                                      (list "/usr/bin/true" "--socket"
                                            relay-socket)))))
                    ((or 'grok 'codex)
                     (should (string-match-p
                              "^\\[mcp_servers\\.cmacs-brigade\\]$" text))
                     (should (string-match-p
                              "^\\[mcp_servers\\.cmacs-brigade-desktop\\]$"
                              text))
                     (should (string-match-p
                              (concat "^command = \"/usr/bin/true\"\nargs = "
                                      (regexp-quote
                                       (format "[\"--socket\", %S]"
                                               relay-socket)))
                              text)))
                    (_ (ert-fail
                        (format "dialect %s has no assertion here; add one"
                                format)))))
              (cmacs-brigade-host-revoke agent))))))))

(provide 'cmacs-brigade-desktop-tests)

;;; cmacs-brigade-desktop-tests.el ends here
