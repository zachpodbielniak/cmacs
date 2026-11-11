;;; cmacs-clawtilla-computer.el --- An agent's computer -*- lexical-binding: t; -*-

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

;; The Computer page and its four halves: Shell, Screen, Mounts and
;; Exchange.
;;
;; Four, and in that order, because `clawt_computer_view_count' says so
;; -- not because they are listed here.  A view added to clawtilla
;; appears in this buffer with no edit, and `make parity' fails a client
;; that walks the enumeration in one place and hardcodes it in another.
;;
;; The fifth, Browser (clawtilla 0.9.0), is the agent's web browser: a
;; gsurf on a private Xvfb that the daemon starts on the first browser
;; call.  This buffer draws its picture, opens an address in it, clicks
;; where the mouse clicks on the picture -- mapped back from the scaled
;; image to the page's own CSS pixels -- and stops it.  A daemon built
;; without GSURF=1 says so rather than drawing an empty frame.
;;
;; Which halves are worth showing at all depends on the computer's type,
;; and that is also the library's answer: `computer-type' carries
;; `screen', `mounts' and `image' per type, so an agent with
;; `computer: none' is not offered a shell into nothing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)

(defvar-local cmacs-clawtilla-computer--agent nil)
(defvar-local cmacs-clawtilla-computer--view "shell")
(defvar-local cmacs-clawtilla-computer--status nil)
(defvar-local cmacs-clawtilla-computer--mounts nil)
(defvar-local cmacs-clawtilla-computer--exchange nil)
(defvar-local cmacs-clawtilla-computer--output nil)
(defvar-local cmacs-clawtilla-computer--screen nil
  "What `computer.screen' last said about the screen.")
(defvar-local cmacs-clawtilla-computer--frame nil
  "The last screen frame, as an Emacs image, or nil.")
(defvar-local cmacs-clawtilla-computer--browser nil
  "What `browser.frame' last said about this agent's browser, or nil.

JSON text, as the daemon sent it less the picture: it goes back to the
library for the session line, and a re-encoding of the ordinary parse
would turn `running: false' into an object.")
(defvar-local cmacs-clawtilla-computer--browser-list nil
  "The last `browser.list' reply: `available' and every session.")
(defvar-local cmacs-clawtilla-computer--browser-image nil
  "The browser picture as an Emacs image, or nil.")
(defvar-local cmacs-clawtilla-computer--browser-size nil
  "The picture's own size in pixels, (WIDTH . HEIGHT), or nil.

Read from the PNG itself, because the image is drawn scaled to fit the
window and a click must be mapped back to the page's pixels.")

(declare-function cmacs-clawtilla--browser-line "cmacs-clawtilla-defuns.c")

(defun cmacs-clawtilla-computer--views ()
  "Return the computer's views, in the library's order."
  (cmacs-clawtilla-enum "computer-view"))

(defun cmacs-clawtilla-computer--type-info (nick)
  "Return what the library says about computer type NICK."
  (seq-find (lambda (entry) (equal (alist-get 'nick entry) nick))
            (cmacs-clawtilla-enum "computer-type")))


;;;; Drawing.

(defun cmacs-clawtilla-computer--draw-shell ()
  "Draw the Shell view."
  (insert (cmacs-clawtilla-dim
           "e runs a command on this agent's computer.\n\n"))
  (when cmacs-clawtilla-computer--output
    (dolist (entry (reverse cmacs-clawtilla-computer--output))
      (insert (propertize (concat "$ " (car entry))
                          'face 'cmacs-clawtilla-heading)
              "\n")
      (let ((text (cdr entry)))
        (unless (string-empty-p (string-trim (or text "")))
          (dolist (line (split-string text "\n"))
            (insert "  " line "\n"))))
      (insert "\n"))))

(defun cmacs-clawtilla-computer--draw-screen ()
  "Draw the Screen view."
  (if (null cmacs-clawtilla-computer--frame)
      (insert (cmacs-clawtilla-dim
               (concat "No frame yet.  `f' asks for one; `t' takes the "
                       "screen over\nand `T' hands it back.\n")))
    (insert-image cmacs-clawtilla-computer--frame)
    (insert "\n"))
  ;; Taking over is a state worth naming rather than inferring from a
  ;; button's label: an agent whose screen somebody else is driving is
  ;; not one whose idleness means anything.
  (when-let* ((holder (alist-get 'holder cmacs-clawtilla-computer--screen)))
    (insert "\n" (propertize (format "screen held by %s" holder)
                             'face 'cmacs-clawtilla-busy) "\n")))

(defun cmacs-clawtilla-computer--draw-mounts ()
  "Draw the Mounts view."
  (if (null cmacs-clawtilla-computer--mounts)
      (insert "  " (cmacs-clawtilla-dim "nothing shared in") "\n")
    (dolist (mount cmacs-clawtilla-computer--mounts)
      (cmacs-clawtilla-insert-section
       :type 'mount :value mount :level 1
       :heading (format "%-30s %-30s %s"
                        (or (alist-get 'source mount) "?")
                        (or (alist-get 'target mount) "?")
                        (cmacs-clawtilla-dim
                         (or (alist-get 'mode mount) "")))))))

(defun cmacs-clawtilla-computer--draw-exchange ()
  "Draw the Exchange view."
  (if (null cmacs-clawtilla-computer--exchange)
      (insert "  " (cmacs-clawtilla-dim "the exchange is empty") "\n")
    (dolist (file cmacs-clawtilla-computer--exchange)
      (cmacs-clawtilla-insert-section
       :type 'exchange-file :value file :level 1
       :heading (format "%-40s %s"
                        (or (alist-get 'name file) (format "%s" file))
                        (cmacs-clawtilla-dim
                         (let ((size (alist-get 'size file)))
                           (if size (file-size-human-readable size) ""))))))))

(defun cmacs-clawtilla-computer--browser-sessions ()
  "Return the `browser.list' sessions this agent drives or shares."
  (let ((agent cmacs-clawtilla-computer--agent))
    (seq-filter (lambda (session)
                  (or (member agent (alist-get 'agents session))
                      (equal (alist-get 'key session)
                             (format "agent:%s" agent))))
                (alist-get 'sessions cmacs-clawtilla-computer--browser-list))))

(defun cmacs-clawtilla-computer--draw-browser ()
  "Draw the Browser view."
  (let ((listing cmacs-clawtilla-computer--browser-list))
    (cond
     ((and listing (assq 'available listing)
           (not (eq t (alist-get 'available listing))))
      (insert "  " (propertize
                    "This daemon was built without GSURF=1, so no agent has a browser."
                    'face 'cmacs-clawtilla-error)
              "\n"))
     (t
      ;; The line above the picture is the library's sentence, the same
      ;; one the GTK, web and lrg clients draw.
      (insert "  " (or (cmacs-clawtilla--browser-line
                        cmacs-clawtilla-computer--browser)
                       "")
              "\n\n")
      (if cmacs-clawtilla-computer--browser-image
          (progn
            (insert-image cmacs-clawtilla-computer--browser-image
                          nil nil nil t)
            (insert "\n\n  " (cmacs-clawtilla-dim
                              "mouse-1 clicks in the page; x clicks at a point")
                    "\n"))
        (insert "  " (cmacs-clawtilla-dim
                      "No picture.  a opens an address; r reads the page again.")
                "\n"))
      (let ((sessions (cmacs-clawtilla-computer--browser-sessions)))
        (when sessions
          (insert "\n" (propertize "Sessions" 'face 'cmacs-clawtilla-heading)
                  "\n")
          (dolist (session sessions)
            (cmacs-clawtilla-insert-section
             :type 'browser-session :value session :level 1
             :heading (format "%-24s %-7s %-8s %s"
                              (or (alist-get 'key session) "?")
                              (or (alist-get 'kind session) "")
                              (if (eq t (alist-get 'running session))
                                  (propertize "running"
                                              'face 'cmacs-clawtilla-running)
                                (propertize "stopped"
                                            'face 'cmacs-clawtilla-stopped))
                              (cmacs-clawtilla-dim
                               (or (alist-get 'uri session) "")))))))))))

(defun cmacs-clawtilla-computer--draw ()
  "Redraw the computer buffer."
  (cmacs-clawtilla-ui-preserving
    (let* ((status cmacs-clawtilla-computer--status)
           ;; The TYPE is the agent's, and computer.status does not
           ;; answer it -- it answers `state' and `description'.  The
           ;; screen reply is where the type appears.
           (type (or (alist-get 'type cmacs-clawtilla-computer--screen)
                     "none"))
           (info (cmacs-clawtilla-computer--type-info type)))
      (insert (propertize (format "%s's computer"
                                  cmacs-clawtilla-computer--agent)
                          'face 'cmacs-clawtilla-heading)
              "  "
              (propertize type 'face 'cmacs-clawtilla-team)
              "  "
              (propertize (or (alist-get 'state status) "?")
                          'face (cmacs-clawtilla-state-face
                                 (alist-get 'state status)))
              "\n")
      (when-let* ((description (alist-get 'description status)))
        (insert "  " (cmacs-clawtilla-dim description) "\n"))
      (when (and info (not (eq t (alist-get 'machine info))))
        (insert (cmacs-clawtilla-dim
                 "This agent has no machine of its own.\n")))
      (insert (mapconcat
               (lambda (view)
                 (let ((nick (alist-get 'nick view)))
                   (if (equal nick cmacs-clawtilla-computer--view)
                       (propertize (alist-get 'label view)
                                   'face 'cmacs-clawtilla-heading)
                     (cmacs-clawtilla-dim (alist-get 'label view)))))
               (cmacs-clawtilla-computer--views) "  |  ")
              "\n\n")
      (pcase cmacs-clawtilla-computer--view
        ("screen" (cmacs-clawtilla-computer--draw-screen))
        ("mounts" (cmacs-clawtilla-computer--draw-mounts))
        ("exchange" (cmacs-clawtilla-computer--draw-exchange))
        ("browser" (cmacs-clawtilla-computer--draw-browser))
        (_ (cmacs-clawtilla-computer--draw-shell))))))


;;;; Loading.

(defun cmacs-clawtilla-computer--load (&optional buffer)
  "Refetch what the computer buffer draws into BUFFER."
  (let* ((buffer (or buffer (current-buffer)))
         (conn (buffer-local-value 'cmacs-clawtilla-connection buffer))
         (agent (buffer-local-value 'cmacs-clawtilla-computer--agent buffer))
         (payload (list (cons 'agent agent))))
    (cmacs-clawtilla-request
     conn "computer.status" payload
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-computer--status data)
           (cmacs-clawtilla-computer--draw)))))
    (cmacs-clawtilla-request
     conn "agent.mount.list" payload
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-computer--mounts
                 (cmacs-clawtilla-get data 'mounts))
           (cmacs-clawtilla-computer--draw)))))
    (cmacs-clawtilla-request
     conn "computer.screen" payload
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-computer--screen data)
           (cmacs-clawtilla-computer--draw)))))
    (cmacs-clawtilla-request
     conn "browser.list" nil
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-computer--browser-list data)
           (cmacs-clawtilla-computer--draw)))))
    (when (equal (buffer-local-value 'cmacs-clawtilla-computer--view buffer)
                 "browser")
      (with-current-buffer buffer (cmacs-clawtilla-computer-browser-frame)))
    (cmacs-clawtilla-request
     conn "exchange.list" payload
     (lambda (data err)
       (when (and (buffer-live-p buffer) (not err))
         (with-current-buffer buffer
           (setq cmacs-clawtilla-computer--exchange
                 (cmacs-clawtilla-get data 'entries))
           (cmacs-clawtilla-computer--draw)))))))


;;;; Acting.

(defun cmacs-clawtilla-computer-next-view ()
  "Move to the next of the computer's views."
  (interactive)
  (let* ((nicks (mapcar (lambda (v) (alist-get 'nick v))
                        (cmacs-clawtilla-computer--views)))
         (rest (cdr (member cmacs-clawtilla-computer--view nicks))))
    (setq cmacs-clawtilla-computer--view (or (car rest) (car nicks)))
    (cmacs-clawtilla-computer--draw)
    ;; A frame is a screenshot of a live page: asked for on arrival,
    ;; never on a timer from a buffer nobody is reading.
    (when (equal cmacs-clawtilla-computer--view "browser")
      (cmacs-clawtilla-computer-browser-frame))))

(defun cmacs-clawtilla-computer-exec (command)
  "Run COMMAND on this agent's computer."
  (interactive "sRun: ")
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "computer.exec"
     (list (cons 'agent cmacs-clawtilla-computer--agent)
           (cons 'command command))
     (lambda (data err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (push (cons command
                       (or err
                           (concat (or (cmacs-clawtilla-get data 'stdout) "")
                                   (or (cmacs-clawtilla-get data 'stderr) ""))))
                 cmacs-clawtilla-computer--output)
           (cmacs-clawtilla-computer--draw)))))))

(defun cmacs-clawtilla-computer-frame ()
  "Fetch one frame of this agent's screen."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "computer.frame"
     (list (cons 'agent cmacs-clawtilla-computer--agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if (eq t (cmacs-clawtilla-get data 'pending))
                 ;; A stated absence, not a failure: nothing has been
                 ;; captured yet, which is the first second of watching
                 ;; and the whole time a VM takes to boot.
                 (message "clawtilla: no picture yet (%s watching)"
                          (or (cmacs-clawtilla-get data 'watchers) 0))
               (let ((encoded (cmacs-clawtilla-get data 'base64)))
                 (setq cmacs-clawtilla-computer--frame
                       (and encoded
                            (create-image (base64-decode-string encoded)
                                          nil t)))))
             (setq cmacs-clawtilla-computer--view "screen")
             (cmacs-clawtilla-computer--draw))))))))

(defun cmacs-clawtilla-computer-takeover ()
  "Take this agent's screen over.

While it is held the agent is not driving it, so anything the agent
looks idle about is you."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "computer.takeover"
   (list (cons 'agent cmacs-clawtilla-computer--agent))
   (lambda (_d e) (message "clawtilla: %s" (or e "screen taken over")))))

(defun cmacs-clawtilla-computer-release ()
  "Hand this agent's screen back."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "computer.release"
   (list (cons 'agent cmacs-clawtilla-computer--agent))
   (lambda (_d e) (message "clawtilla: %s" (or e "screen released")))))

(defun cmacs-clawtilla-computer-mount-add (source target mode)
  "Share SOURCE into this computer at TARGET with MODE."
  (interactive (list (read-directory-name "Share which directory: ")
                     (read-string "Mount it where: ")
                     (completing-read "Mode: " '("ro" "rw") nil t "ro")))
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.mount.add"
     (list (cons 'agent cmacs-clawtilla-computer--agent)
           (cons 'source source) (cons 'target target) (cons 'mode mode))
     (lambda (_data err)
       ;; Validated before it is written, so a mount that could never
       ;; work is refused now rather than at the agent's next start --
       ;; by which time the message mentions neither path nor reason.
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-computer--load buffer)))))))

(defun cmacs-clawtilla-computer-mount-remove ()
  "Stop sharing the mount at point."
  (interactive)
  (let* ((mount (cmacs-clawtilla-value-at-point 'mount))
         (buffer (current-buffer)))
    (unless mount (user-error "No mount at point"))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "agent.mount.remove"
     (list (cons 'agent cmacs-clawtilla-computer--agent)
           (cons 'target (alist-get 'target mount)))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (cmacs-clawtilla-computer--load buffer)))))))

(defun cmacs-clawtilla-computer-copy (path)
  "Copy PATH into the exchange directory."
  (interactive "fCopy in: ")
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "computer.copy"
   ;; One side carries the agent: `src' and `dst', with `<agent>:<path>'
   ;; naming the side that is inside the computer.
   (list (cons 'src path)
         (cons 'dst (format "%s:%s" cmacs-clawtilla-computer--agent
                            (file-name-nondirectory path))))
   (lambda (_d e) (message "clawtilla: %s" (or e "copied")))))

(defun cmacs-clawtilla-computer--lifecycle (kind)
  "Send KIND for this computer."
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) kind
   (list (cons 'agent cmacs-clawtilla-computer--agent))
   (lambda (_d e) (message "clawtilla: %s" (or e kind)))))

(defun cmacs-clawtilla-computer-start ()
  "Start this computer."
  (interactive) (cmacs-clawtilla-computer--lifecycle "computer.start"))

(defun cmacs-clawtilla-computer-stop ()
  "Stop this computer."
  (interactive) (cmacs-clawtilla-computer--lifecycle "computer.stop"))

(defun cmacs-clawtilla-computer-restart ()
  "Restart this computer."
  (interactive) (cmacs-clawtilla-computer--lifecycle "computer.restart"))

(defun cmacs-clawtilla-computer-rebuild ()
  "Rebuild this computer from scratch."
  (interactive)
  (when (yes-or-no-p "Rebuild this computer, discarding its state? ")
    (cmacs-clawtilla-computer--lifecycle "computer.rebuild")))


;;;; Watching, and driving.

(defvar-local cmacs-clawtilla-computer--observing nil)

(defun cmacs-clawtilla-computer-screen ()
  "Ask for this computer's screen and show it."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "computer.screen"
     (list (cons 'agent cmacs-clawtilla-computer--agent))
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             ;; This verb answers everything needed to DRAW the tab --
             ;; whether the type has a screen, who holds it, whether
             ;; input is allowed -- and no bytes.  The picture comes
             ;; from `computer.frame'.
             (setq cmacs-clawtilla-computer--screen data)
             (setq cmacs-clawtilla-computer--view "screen")
             (cmacs-clawtilla-computer--draw)
             (cmacs-clawtilla-computer-frame))))))))

(defun cmacs-clawtilla-computer-observe ()
  "Start watching this computer's screen as it changes."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "computer.observe"
     (list (cons 'agent cmacs-clawtilla-computer--agent))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq cmacs-clawtilla-computer--observing t)))
         (message "clawtilla: watching; `O' stops"))))))

(defun cmacs-clawtilla-computer-observe-stop ()
  "Stop watching this computer's screen.

Stopped explicitly rather than when the buffer goes away: the daemon is
producing frames for somebody, and a client that only stopped asking
would leave it doing that for the rest of the session."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) "computer.observe_stop"
     (list (cons 'agent cmacs-clawtilla-computer--agent))
     (lambda (_data err)
       (if err
           (message "clawtilla: %s" err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (setq cmacs-clawtilla-computer--observing nil)))
         (message "clawtilla: stopped watching"))))))

(defun cmacs-clawtilla-computer-input (keys)
  "Type KEYS into this computer.

Only while the screen is taken over.  Sending input to a screen the
agent is still driving means two things typing into one window, which
is not shared control, it is a corrupted command line."
  (interactive "sType: ")
  ;; `can_input' is the daemon's answer to whether typing is possible at
  ;; all, and `held' to whether this client is the one holding it.
  ;; Sending input to a screen the agent is still driving is not shared
  ;; control, it is a corrupted command line.
  (unless (eq t (alist-get 'held cmacs-clawtilla-computer--screen))
    (user-error "Take the screen over first (`t')"))
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "computer.input"
   (list (cons 'agent cmacs-clawtilla-computer--agent)
         (cons 'text keys))
   (lambda (_d e) (when e (message "clawtilla: %s" e)))))

(defun cmacs-clawtilla-computer-control ()
  "Hand this computer's desktop to the agent, or take it back."
  (interactive)
  (cmacs-clawtilla-request
   (cmacs-clawtilla-current) "computer.control"
   (list (cons 'agent cmacs-clawtilla-computer--agent))
   (lambda (_d e) (message "clawtilla: %s" (or e "control toggled")))))

;;;; The browser.

(defun cmacs-clawtilla-computer--png-size (data)
  "Return the pixel size of the PNG in the unibyte string DATA.

As (WIDTH . HEIGHT), read from the IHDR chunk, or nil when DATA is not
a PNG.  The picture is drawn scaled to the window, so mapping a click
needs the page's own size -- which is the picture's, one CSS pixel to
one image pixel."
  (when (and (stringp data) (>= (length data) 24)
             (string-prefix-p "\x89PNG" data))
    (cl-flet ((u32 (offset)
                (logior (ash (aref data offset) 24)
                        (ash (aref data (+ offset 1)) 16)
                        (ash (aref data (+ offset 2)) 8)
                        (aref data (+ offset 3)))))
      (cons (u32 16) (u32 20)))))

(defun cmacs-clawtilla-computer--map-click (x y shown native)
  "Map a click at X, Y on an image drawn at SHOWN to the page's pixels.

SHOWN and NATIVE are (WIDTH . HEIGHT): the size the image is drawn at,
and its own size.  Returns (PX . PY) in the page's CSS pixels, clamped
inside the page, or nil when either size is unknown or empty."
  (when (and shown native
             (> (car shown) 0) (> (cdr shown) 0)
             (> (car native) 0) (> (cdr native) 0))
    (cons (max 0 (min (1- (car native))
                      (floor (* x (/ (float (car native)) (car shown))))))
          (max 0 (min (1- (cdr native))
                      (floor (* y (/ (float (cdr native)) (cdr shown)))))))))

(defun cmacs-clawtilla-computer--browser-image-of (data)
  "Return an Emacs image of the PNG DATA, scaled to fit the window."
  (let ((window (get-buffer-window (current-buffer))))
    (apply #'create-image data 'png t
           (when window
             (list :max-width (max 64 (- (window-body-width window t) 16)))))))

(defun cmacs-clawtilla-computer--split-frame (json)
  "Split the `browser.frame' reply text JSON into (SESSION-JSON . PNG).

SESSION-JSON is the reply less its picture, still as JSON text with
null and false kept as themselves; PNG is the decoded picture as a
unibyte string, or nil when the session is not running."
  (when (stringp json)
    (let* ((faithful (json-parse-string json :object-type 'alist
                                        :array-type 'array
                                        :null-object :json-null
                                        :false-object :json-false))
           (payload (if (and (assq 'ok faithful) (assq 'payload faithful))
                        (alist-get 'payload faithful)
                      faithful))
           (encoded (alist-get 'png_base64 payload))
           (rest (seq-remove (lambda (pair) (eq (car pair) 'png_base64))
                             payload)))
      (cons (and (consp rest)
                 (json-serialize rest :null-object :json-null
                                 :false-object :json-false))
            (and (stringp encoded) (base64-decode-string encoded))))))

(defun cmacs-clawtilla-computer-browser-frame ()
  "Read this agent's browser page again.

A session that is not running answers at once with no picture; a
frame never starts one."
  (interactive)
  (let ((buffer (current-buffer)))
    (cmacs-clawtilla-request-raw
     (cmacs-clawtilla-current) "browser.frame"
     (list (cons 'agent cmacs-clawtilla-computer--agent))
     (lambda (json err)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (if err
               (message "clawtilla: %s" err)
             (let* ((parts (cmacs-clawtilla-computer--split-frame json))
                    (bytes (cdr parts)))
               (setq cmacs-clawtilla-computer--browser (car parts))
               (setq cmacs-clawtilla-computer--browser-size
                     (cmacs-clawtilla-computer--png-size bytes))
               (setq cmacs-clawtilla-computer--browser-image
                     (and bytes
                          (cmacs-clawtilla-computer--browser-image-of bytes)))))
           (cmacs-clawtilla-computer--draw)))))))

(defun cmacs-clawtilla-computer--browser-act (kind &optional extra note)
  "Send KIND for this agent's browser with EXTRA, then read the page again.

NOTE, when given, is said while the daemon works: a start waits seconds
for an X server and an open waits up to twenty for the load."
  (let ((buffer (current-buffer)))
    (when note (message "clawtilla: %s" note))
    (cmacs-clawtilla-request
     (cmacs-clawtilla-current) kind
     (append (list (cons 'agent cmacs-clawtilla-computer--agent)) extra)
     (lambda (_data err)
       (when err (message "clawtilla: %s" err))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (cmacs-clawtilla-computer-browser-frame)))))))

(defun cmacs-clawtilla-computer-browser-open (url)
  "Open URL in this agent's browser, starting it if it must.

https:// is assumed without a scheme -- by the daemon, not here."
  (interactive "sOpen address: ")
  (when (string-empty-p (string-trim url))
    (user-error "No address"))
  (setq cmacs-clawtilla-computer--view "browser")
  (cmacs-clawtilla-computer--browser-act
   "browser.open" (list (cons 'url (string-trim url))) "opening..."))

(defun cmacs-clawtilla-computer-browser-stop ()
  "Stop this agent's browser.

The open page is lost; the profile and its logins stay."
  (interactive)
  (when (yes-or-no-p "Stop the browser? The page closes; logins stay. ")
    (cmacs-clawtilla-computer--browser-act "browser.stop")))

(defun cmacs-clawtilla-computer-browser-click-at (x y)
  "Click at X, Y in the page's own CSS pixels.

A person's click: it does not take a shared session's driver lease,
since a person at the Computer page outranks an agent."
  (interactive
   (let ((size cmacs-clawtilla-computer--browser-size))
     (list (read-number (format "x (0-%s): "
                                (if size (1- (car size)) "?")))
           (read-number (format "y (0-%s): "
                                (if size (1- (cdr size)) "?"))))))
  (cmacs-clawtilla-computer--browser-act
   "browser.click" (list (cons 'x (truncate x)) (cons 'y (truncate y)))))

(defun cmacs-clawtilla-computer-browser-click (event)
  "Click in the agent's page where EVENT clicked on its picture."
  (interactive "e")
  (let* ((posn (event-start event))
         (image (posn-image posn))
         (xy (posn-object-x-y posn))
         (window (posn-window posn)))
    (if (not (and image
                  (equal cmacs-clawtilla-computer--view "browser")
                  cmacs-clawtilla-computer--browser-size))
        ;; Not on the picture: an ordinary click, so point still moves.
        (when (windowp window)
          (select-window window)
          (when (posn-point posn) (goto-char (posn-point posn))))
      (let* ((shown (image-size image t (and (windowp window)
                                             (window-frame window))))
             (target (cmacs-clawtilla-computer--map-click
                      (car xy) (cdr xy)
                      (cons (truncate (car shown)) (truncate (cdr shown)))
                      cmacs-clawtilla-computer--browser-size)))
        (when target
          (cmacs-clawtilla-computer-browser-click-at (car target)
                                                     (cdr target)))))))


;;;; The mode.

(transient-define-prefix cmacs-clawtilla-computer-menu ()
  "What this computer can do."
  ["View"
   [("TAB" "next view" cmacs-clawtilla-computer-next-view)
    ("gr" "refresh" cmacs-clawtilla-refresh)]]
  ["Shell and screen"
   [("!" "run a command" cmacs-clawtilla-computer-exec)
    ("v" "grab a frame" cmacs-clawtilla-computer-frame)
    ("V" "the screen" cmacs-clawtilla-computer-screen)]
   [("u" "take the screen" cmacs-clawtilla-computer-takeover)
    ("U" "hand it back" cmacs-clawtilla-computer-release)
    ("i" "type into it" cmacs-clawtilla-computer-input)]
   [("o" "watch it" cmacs-clawtilla-computer-observe)
    ("O" "stop watching" cmacs-clawtilla-computer-observe-stop)
    ("D" "toggle desktop control" cmacs-clawtilla-computer-control)]]
  ["Browser"
   [("a" "open an address" cmacs-clawtilla-computer-browser-open)
    ("r" "read the page again" cmacs-clawtilla-computer-browser-frame)]
   [("x" "click at a point" cmacs-clawtilla-computer-browser-click-at)
    ("X" "stop the browser" cmacs-clawtilla-computer-browser-stop)]]
  ["Files"
   [("m" "share a directory" cmacs-clawtilla-computer-mount-add)
    ("d" "stop sharing" cmacs-clawtilla-computer-mount-remove)]
   [("c" "copy into exchange" cmacs-clawtilla-computer-copy)]]
  ["Lifecycle"
   [("s" "start" cmacs-clawtilla-computer-start)
    ("S" "stop" cmacs-clawtilla-computer-stop)]
   [("R" "restart" cmacs-clawtilla-computer-restart)
    ("B" "rebuild" cmacs-clawtilla-computer-rebuild)]])

(defvar cmacs-clawtilla-computer-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    (define-key map (kbd "TAB") #'cmacs-clawtilla-computer-next-view)
    (define-key map (kbd "!") #'cmacs-clawtilla-computer-exec)
    (define-key map (kbd "v") #'cmacs-clawtilla-computer-frame)
    (define-key map (kbd "u") #'cmacs-clawtilla-computer-takeover)
    (define-key map (kbd "U") #'cmacs-clawtilla-computer-release)
    (define-key map (kbd "m") #'cmacs-clawtilla-computer-mount-add)
    (define-key map (kbd "d") #'cmacs-clawtilla-computer-mount-remove)
    (define-key map (kbd "c") #'cmacs-clawtilla-computer-copy)
    (define-key map (kbd "V") #'cmacs-clawtilla-computer-screen)
    (define-key map (kbd "i") #'cmacs-clawtilla-computer-input)
    (define-key map (kbd "o") #'cmacs-clawtilla-computer-observe)
    (define-key map (kbd "O") #'cmacs-clawtilla-computer-observe-stop)
    (define-key map (kbd "a") #'cmacs-clawtilla-computer-browser-open)
    (define-key map (kbd "r") #'cmacs-clawtilla-computer-browser-frame)
    (define-key map (kbd "x") #'cmacs-clawtilla-computer-browser-click-at)
    (define-key map (kbd "X") #'cmacs-clawtilla-computer-browser-stop)
    (define-key map [mouse-1] #'cmacs-clawtilla-computer-browser-click)
    (define-key map (kbd "?") #'cmacs-clawtilla-computer-menu)
    map)
  "Keymap for `cmacs-clawtilla-computer-mode'.")

(define-derived-mode cmacs-clawtilla-computer-mode special-mode
  "Clawtilla-Computer"
  "Major mode for an agent's computer."
  :group 'cmacs-clawtilla
  (setq-local cmacs-clawtilla-refresh-function
              (lambda () (cmacs-clawtilla-computer--load (current-buffer))))
  (setq-local truncate-lines t))

;;;###autoload
(defun cmacs-clawtilla-computer (conn agent)
  "Show AGENT's computer on CONN."
  (interactive (list (cmacs-clawtilla-current) (read-string "Agent: ")))
  (let* ((id (if (stringp agent) agent (alist-get 'id agent)))
         (buffer (get-buffer-create (format "*clawtilla computer: %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-clawtilla-computer-mode)
        (cmacs-clawtilla-computer-mode))
      (setq-local cmacs-clawtilla-connection conn)
      (setq-local cmacs-clawtilla-computer--agent id)
      ;; The first view is the library's first, not "shell" written here.
      (setq-local cmacs-clawtilla-computer--view
                  (alist-get 'nick (car (cmacs-clawtilla-computer--views))))
      (cmacs-clawtilla-computer--load buffer))
    (cmacs-clawtilla-display buffer)))


;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-computer-mode-map 'cmacs-clawtilla-computer-mode)

(provide 'cmacs-clawtilla-computer)

;;; cmacs-clawtilla-computer.el ends here
