;;; cmacs-clawtilla-devices.el --- Paired devices, and pairing this one -*- lexical-binding: t; -*-

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

;; Both ends of pairing.
;;
;; A paired device holds a token of its own, so a lost laptop or phone
;; is one Revoke rather than a new token for every client.  The daemon's
;; own token is the owner's and is never affected.
;;
;; From the daemon's side (the Devices page, `cmacs-clawtilla-devices'):
;; who is paired, when each was last seen, and Revoke -- or Sign out, for
;; the device you are sitting at.  Pairing a new one asks the daemon for
;; a six-digit code, good once and for a few minutes, and shows it with
;; a QR code of the pairing link: an SVG where this Emacs draws images,
;; half blocks where it does not, and the link itself when libclawt was
;; built without a QR encoder.  The code is shown; it is never logged,
;; and closing the buffer before it is used cancels it.
;;
;; From the device's side (`cmacs-clawtilla-pair'): the daemon's address
;; and the code somebody read off the other screen, traded for a token
;; that is saved as a profile in clawtilla's own connections file.  The
;; exchange is over the network and blocks, so it runs on a worker
;; thread in C; nothing here waits for it.
;;
;; The words are libclawt's wherever it has them: how a code is
;; grouped for reading, the countdown, "seen 3 minutes ago", and whether
;; a row offers Revoke, Sign out or nothing at all -- only the owner
;; revokes somebody else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-clawtilla)
(require 'cmacs-clawtilla-ui)
(require 'cmacs-clawtilla-page)

(declare-function cmacs-clawtilla--pair "cmacs-clawtilla-defuns.c")
(declare-function svg-create "svg")
(declare-function svg-rectangle "svg")
(declare-function svg-image "svg")
(declare-function dom-append-child "dom")
(declare-function dom-node "dom")

(defcustom cmacs-clawtilla-qr-scale 5
  "How many pixels a QR module is drawn at."
  :type 'integer
  :group 'cmacs-clawtilla)


;;;; A QR code.

(defun cmacs-clawtilla-qr-modules (text)
  "Return TEXT as a QR code: a list of strings of 0 and 1, or nil.

One string per row, dark being 1 -- libclawt's encoding
\(`clawt_qr_encode').  nil when libclawt was built without libqrencode
or TEXT does not fit, and the caller shows TEXT itself instead."
  (alist-get 'rows (cmacs-clawtilla-ask-parsed "qr" :text text)))

(defun cmacs-clawtilla-qr-image (rows)
  "Return the QR ROWS as an SVG image, or nil if this Emacs draws none.

Dark on white with the four-module quiet zone a scanner needs, whatever
the theme: a code drawn in the theme's colours is one a phone cannot
read on a dark background."
  (when (and rows (display-images-p) (image-type-available-p 'svg)
             (require 'svg nil t))
    (let* ((quiet 4)
           (size (+ (length rows) (* 2 quiet)))
           (scale cmacs-clawtilla-qr-scale)
           (svg (svg-create (* size scale) (* size scale)
                            :viewBox (format "0 0 %d %d" size size)))
           (path nil)
           (y 0))
      (svg-rectangle svg 0 0 size size :fill "white")
      ;; One path for every dark module rather than a rectangle each: a
      ;; pairing link is a few hundred modules, and one element draws
      ;; without the hairline seams adjacent rectangles get when scaled.
      (dolist (row rows)
        (dotimes (x (length row))
          (when (eq (aref row x) ?1)
            (push (format "M%d %dh1v1h-1z" (+ x quiet) (+ y quiet)) path)))
        (setq y (1+ y)))
      (dom-append-child
       svg (dom-node 'path
                     `((d . ,(string-join (nreverse path) ""))
                       (fill . "black"))))
      (svg-image svg :scale 1))))

(defun cmacs-clawtilla-qr-insert (text)
  "Insert TEXT as a QR code at point, in the best form this frame can draw.

An image, else libclawt's half-block rendering, else TEXT itself with a
line saying why there is no code.  Returns the form used: `image',
`blocks' or `text'."
  (let* ((rows (cmacs-clawtilla-qr-modules text))
         (image (cmacs-clawtilla-qr-image rows))
         (blocks (and rows (not image)
                      (cmacs-clawtilla-ask
                       "qr-terminal" :text text
                       :light (if (eq (frame-parameter nil 'background-mode)
                                      'light)
                                  t :false)))))
    (cond
     (image
      (insert "  ")
      (insert-image image "[QR code]")
      (insert "\n")
      'image)
     (blocks
      (dolist (line (split-string blocks "\n" t))
        (insert "  " line "\n"))
      'blocks)
     (t
      (insert "  " (cmacs-clawtilla-dim
                    "(no QR code: this build of libclawt has no encoder)")
              "\n  " text "\n")
      'text))))


;;;; Pairing a new device, from the daemon's side.

(defvar-local cmacs-clawtilla-devices--pairing nil
  "This pairing buffer's state: a plist of :deadline, :paired, :timer, :conn.")

(defun cmacs-clawtilla-devices--pairing-buffer ()
  "Return the live pairing buffer, or nil."
  (let ((buffer (get-buffer "*clawtilla pairing*")))
    (and (buffer-live-p buffer) buffer)))

(defun cmacs-clawtilla-devices--stop-timer ()
  "Stop this pairing buffer's countdown."
  (when-let* ((timer (plist-get cmacs-clawtilla-devices--pairing :timer)))
    (cancel-timer timer)
    (setq cmacs-clawtilla-devices--pairing
          (plist-put cmacs-clawtilla-devices--pairing :timer nil))))

(defun cmacs-clawtilla-devices--countdown-line ()
  "Return what this pairing buffer's last line should say now."
  (let* ((state cmacs-clawtilla-devices--pairing)
         (left (- (plist-get state :deadline) (truncate (float-time)))))
    (cond
     ((plist-get state :paired)
      (format "Paired %s.  It has a token of its own now."
              (or (plist-get state :paired-name) "the new device")))
     ((> left 0)
      (format "Good for %s, once."
              (or (cmacs-clawtilla-ask "device-countdown" :left left)
                  (format "%d seconds" left))))
     (t "This code has expired.  Close this and ask for another."))))

(defun cmacs-clawtilla-devices--tick (buffer)
  "Redraw the countdown in the pairing BUFFER, or stop if it is gone."
  (if (not (buffer-live-p buffer))
      nil
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (marker (plist-get cmacs-clawtilla-devices--pairing :line)))
        (when (markerp marker)
          (save-excursion
            (goto-char marker)
            (delete-region (point) (line-end-position))
            (insert (propertize (cmacs-clawtilla-devices--countdown-line)
                                'face 'cmacs-clawtilla-busy)))))
      (when (or (plist-get cmacs-clawtilla-devices--pairing :paired)
                (<= (- (plist-get cmacs-clawtilla-devices--pairing :deadline)
                       (truncate (float-time)))
                    0))
        (cmacs-clawtilla-devices--stop-timer)))))

(defun cmacs-clawtilla-devices--pairing-closed ()
  "Cancel the code when its buffer goes away unused.

A code nobody will type should not stay good for the rest of its few
minutes on a screen that has moved on."
  (let ((state cmacs-clawtilla-devices--pairing))
    (cmacs-clawtilla-devices--stop-timer)
    (when (and state (not (plist-get state :paired))
               (plist-get state :conn)
               (cmacs-clawtilla--connected-p
                (cmacs-clawtilla-connection-handle (plist-get state :conn))))
      (cmacs-clawtilla-request (plist-get state :conn)
                               "device.pair_cancel" nil #'ignore))))

(defvar cmacs-clawtilla-pairing-mode-map
  (let ((map (make-sparse-keymap)))
    (cmacs-clawtilla-define-common-keys map)
    ;; Killed rather than buried: the buffer going away is what cancels
    ;; a code nobody used.
    (define-key map (kbd "q") #'kill-current-buffer)
    map)
  "Keymap for `cmacs-clawtilla-pairing-mode'.")

(define-derived-mode cmacs-clawtilla-pairing-mode special-mode
  "Clawtilla-Pairing"
  "Major mode for the buffer that shows a pairing code."
  :group 'cmacs-clawtilla)

(defun cmacs-clawtilla-devices--show-pairing (conn data)
  "Show the pairing code in DATA, a `device.pair' reply from CONN."
  (let* ((buffer (get-buffer-create "*clawtilla pairing*"))
         (addresses (cmacs-clawtilla-get data 'addresses))
         (uri (cmacs-clawtilla-get data 'uri))
         (code (or (cmacs-clawtilla-get data 'code) "")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cmacs-clawtilla-pairing-mode)
        (setq-local cmacs-clawtilla-connection conn)
        (insert (propertize "Pair a new device" 'face 'cmacs-clawtilla-heading)
                "\n\n")
        (let ((start (point))
              (fill-column 72))
          (insert
           (if addresses
               (format "On the other device choose Pair with a code in Connections and enter this daemon's address (%s) and the code."
                       (string-join addresses ", "))
             "This daemon is not listening on the network, so no other device can reach it yet.  Turn on daemon.tailscale or daemon.tcp_enabled first.")
           "\n")
          (fill-region start (point)))
        (insert "\n")
        (when (stringp uri)
          (cmacs-clawtilla-qr-insert uri)
          (insert "\n"))
        ;; Grouped for reading aloud by libclawt, the same on every
        ;; client: two people comparing screens should see one thing.
        (insert "  " (propertize
                      (or (cmacs-clawtilla-ask "device-code" :code code) code)
                      'face '(:height 2.0 :weight bold))
                "\n\n  ")
        (setq cmacs-clawtilla-devices--pairing
              (list :deadline (+ (truncate (float-time))
                                 (or (cmacs-clawtilla-get data 'expires_in) 0))
                    :conn conn
                    :line (copy-marker (point))))
        (insert "\n\n  " (cmacs-clawtilla-dim
                          "q closes this; closing it before the code is used cancels the code.")
                "\n"))
      (add-hook 'kill-buffer-hook
                #'cmacs-clawtilla-devices--pairing-closed nil t)
      (setq cmacs-clawtilla-devices--pairing
            (plist-put cmacs-clawtilla-devices--pairing :timer
                       (run-at-time 0 1 #'cmacs-clawtilla-devices--tick
                                    buffer))))
    (pop-to-buffer buffer)))

(defun cmacs-clawtilla-devices-pair-new ()
  "Ask the daemon for a pairing code and show it, with its QR code.

Only the daemon's owner can: a window connected as a paired device is
told so by the daemon."
  (interactive)
  (when (cmacs-clawtilla-devices--pairing-buffer)
    ;; One code at a time: asking again would leave the first on screen
    ;; and good, with nothing to say which of the two is current.
    (kill-buffer (cmacs-clawtilla-devices--pairing-buffer)))
  (let ((conn (cmacs-clawtilla-current)))
    (cmacs-clawtilla-request
     conn "device.pair" nil
     (lambda (data err)
       (if err
           (message "clawtilla: %s" err)
         (cmacs-clawtilla-devices--show-pairing conn data))))))

(defun cmacs-clawtilla-devices--on-event (kind data)
  "React to the `device.' event KIND carrying DATA on the Devices page."
  (when (equal kind "device.paired")
    (when-let* ((buffer (cmacs-clawtilla-devices--pairing-buffer)))
      (with-current-buffer buffer
        (let ((name (cmacs-clawtilla-event-detail data 'name)))
          (setq cmacs-clawtilla-devices--pairing
                (plist-put (plist-put cmacs-clawtilla-devices--pairing
                                      :paired t)
                           :paired-name
                           (and (stringp name) (not (string-empty-p name))
                                name))))
        (cmacs-clawtilla-devices--tick buffer)))))


;;;; The Devices page.

(defun cmacs-clawtilla-devices--draw ()
  "Draw the Devices page."
  (let ((devices (cmacs-clawtilla-page-data 'devices 'devices))
        (owner (eq t (cmacs-clawtilla-page-data 'devices 'owner))))
    (insert "  " (cmacs-clawtilla-dim
                  (if owner
                      "i shows a six-digit code another device can trade for its own token."
                    "Only the daemon's owner can pair -- this is connected as a paired device."))
            "\n\n")
    (if (null devices)
        (cmacs-clawtilla-page-insert-note
         "No paired devices"
         "Pair a laptop or phone to give it a token of its own, which you can revoke without touching anything else.")
      (dolist (device devices)
        (let* ((id (or (alist-get 'id device) ""))
               (current (eq t (alist-get 'current device)))
               (action (cmacs-clawtilla-ask
                        "device-action"
                        :owner (if owner t :false)
                        :current (if current t :false)))
               (created (alist-get 'created device)))
          (cmacs-clawtilla-page-insert-row
           'device device
           (concat (propertize (or (alist-get 'name device) id)
                               'face 'cmacs-clawtilla-agent)
                   (if current
                       (concat "  " (cmacs-clawtilla-badge "this device"))
                     "")
                   (if action
                       (concat "  " (cmacs-clawtilla-dim
                                     (format "D: %s" action)))
                     ""))
           (format "%s · paired %s · %s"
                   (or (cmacs-clawtilla-ask
                        "device-seen"
                        :last_seen (or (alist-get 'last_seen device) 0)
                        :connected (if (eq t (alist-get 'connected device))
                                       t :false))
                       "")
                   (if (and (numberp created) (> created 0))
                       (string-trim (format-time-string
                                     "%e %b %Y" (seconds-to-time created)))
                     "?")
                   id)))))))

(defun cmacs-clawtilla-devices-revoke ()
  "Revoke the device at point, or sign this one out.

Its token stops working at once and anything it has connected is
closed.  The daemon's own token is not affected.  Whether the row
offers this at all is libclawt's rule: only the owner revokes somebody
else, anybody signs themselves out."
  (interactive)
  (let* ((device (cmacs-clawtilla-page-row 'device))
         (owner (eq t (cmacs-clawtilla-page-data 'devices 'owner)))
         (current (eq t (alist-get 'current device)))
         (id (alist-get 'id device))
         (action (cmacs-clawtilla-ask "device-action"
                                      :owner (if owner t :false)
                                      :current (if current t :false))))
    (unless action
      (user-error "Only the daemon's owner can revoke another device"))
    (when (yes-or-no-p
           (if current
               "Sign out this device?  Its token stops working and this client is disconnected; pair again with a new code to come back. "
             (format "%s %s?  Its token stops working at once and anything it has connected is closed. "
                     action (or (alist-get 'name device) id))))
      (cmacs-clawtilla-page-send
       "device.revoke" (list (cons 'id id))
       "revoked; its token no longer works, and anything it had open was closed"))))

(cmacs-clawtilla-define-page "devices"
  :title "Paired devices"
  :intro "Each holds a token of its own, so a lost laptop or phone is one Revoke rather than a new token for every client.  The daemon's own token (clawtilla daemon token) is the owner's and is never affected.  A device unseen for daemon.device_idle_days stops working by itself."
  :fetch '((devices "device.list"))
  :draw #'cmacs-clawtilla-devices--draw
  :events "\\`device\\."
  :on-event #'cmacs-clawtilla-devices--on-event
  :verbs '(("i" "pair a new device" cmacs-clawtilla-devices-pair-new)
           ("D" "revoke / sign out" cmacs-clawtilla-devices-revoke)))

(defun cmacs-clawtilla-devices--paired-anywhere (_conn kind data)
  "Finish the pairing buffer on `device.paired' even with no Devices page.

KIND and DATA are the event's.  The code may have been asked for from
the Devices page and that page since closed; the buffer showing the
code is the thing that has to hear it was used."
  (when (and (equal kind "device.paired")
             (null (cmacs-clawtilla-page-buffers "devices")))
    (cmacs-clawtilla-devices--on-event kind data)))

(add-hook 'cmacs-clawtilla-event-hook #'cmacs-clawtilla-devices--paired-anywhere)

;;;###autoload
(defun cmacs-clawtilla-devices (&optional conn)
  "Show the devices paired with CONN's daemon."
  (interactive)
  (cmacs-clawtilla-page-open "devices" conn))


;;;; Pairing this machine, from the device's side.

;;;###autoload
(defun cmacs-clawtilla-pair (host code &optional name port tls insecure)
  "Pair this machine with the daemon at HOST using the six-digit CODE.

The code is the one the daemon's owner was shown by Pair a new device
\(or `clawtilla device pair').  It is traded for a token of this
machine's own, saved as the profile NAME -- HOST if nil -- in
clawtilla's connections file, and the connection is then opened.

PORT nil is the daemon's default.  TLS non-nil uses TLS; INSECURE
accepts a certificate that does not validate.

The code's shape is checked before anything is dialled, so a typo costs
nothing against the daemon's guess limit.  The exchange itself runs on
a worker thread: this returns at once and reports when it is done."
  (interactive
   (list (read-string "Daemon address: ")
         (read-string "Pairing code: ")
         (let ((name (read-string "Call this connection (empty: its address): ")))
           (and (not (string-empty-p name)) name))
         (let ((port (read-string "Port (empty: the default): ")))
           (and (not (string-empty-p port)) (string-to-number port)))
         (y-or-n-p "Use TLS? ")
         nil))
  (unless (fboundp 'cmacs-clawtilla--pair)
    (user-error "This build cannot pair; connect with a token instead"))
  (when (string-empty-p (string-trim host))
    (user-error "Which daemon?"))
  ;; libclawt's own reading of what was typed: spaces and dashes are
  ;; ignored, and anything that is not six digits is refused here.
  (let ((normal (cmacs-clawtilla-ask "device-code-normalize" :text code)))
    (unless normal
      (user-error "A pairing code is six digits"))
    (if (cmacs-clawtilla--pair
         (string-trim host) (or port 0) normal
         (lambda (json err)
           (if err
               (message "clawtilla: %s" err)
             (let ((profile (alist-get 'name (cmacs-clawtilla--parse json))))
               (message "clawtilla: paired; saved as %s" profile)
               (cmacs-clawtilla-connect-profile profile))))
         name tls insecure nil)
        (message "clawtilla: pairing with %s…" host)
      (user-error "Pairing could not be started"))))

;; Mandatory for any single-key cmacs mode: without it Evil answers
;; first and the buffer is largely inert -- RET, `g', `n', TAB and
;; even `?' are Evil's in motion state.
(cmacs-clawtilla-setup-evil cmacs-clawtilla-pairing-mode-map 'cmacs-clawtilla-pairing-mode)

(provide 'cmacs-clawtilla-devices)

;;; cmacs-clawtilla-devices.el ends here
