;;; cmacs-brigade-desktop-view.el --- Watch an agent's desktop, and take it  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `M-x cmacs-brigade-desktop-view' shows an agent's private desktop
;; (cmacs-brigade-desktop.el) in a buffer, as a picture taken again every
;; `cmacs-brigade-desktop-view-interval' seconds while the buffer is on
;; screen.  A buffer nobody is looking at asks for nothing.
;;
;; The picture never touches the disk: gowl hands back a PNG over its
;; socket and the image is made from those bytes.
;;
;; `t' takes control.  From then until it is released the agent's acting
;; tools are refused with a sentence telling it so, and the keys you type
;; and the clicks and scrolling you do on the picture go to the desktop
;; instead of to Emacs.  Because every printing key is then the
;; desktop's, releasing is `C-c C-r' (`r' only works while you do not
;; hold it, when there is nothing to release).  Emacs keeps C-x, M-x and
;; the rest of its own keys throughout; a combination the desktop should
;; get is sent with `C-c C-k'.

;;; Code:

(require 'cmacs-brigade-desktop)
(require 'image)
(require 'cl-lib)

(defcustom cmacs-brigade-desktop-view-interval 1.0
  "Seconds between pictures of a desktop that is being watched.
Each one is a screenshot encoded by a software renderer and sent as
text, so this is a few frames a second at best; it is for watching an
agent work, not for playing a video."
  :type 'number
  :group 'cmacs-brigade-desktop)

(defvar-local cmacs-brigade-desktop-view--id nil
  "The desktop this buffer shows.")
(defvar-local cmacs-brigade-desktop-view--timer nil)
(defvar-local cmacs-brigade-desktop-view--asked nil
  "When the picture now on its way was asked for, or nil.
A time rather than a flag, so that a callback that never came cannot
stop the view for good.")
(defvar-local cmacs-brigade-desktop-view--image nil
  "The image being shown, for turning a click into coordinates.")


;;;; Showing

(defun cmacs-brigade-desktop-view--header ()
  "Return the header line for the desktop this buffer shows."
  (let ((status (cmacs-brigade-desktop-status
                 cmacs-brigade-desktop-view--id)))
    (if (null status)
        (format " Desktop %s is gone" cmacs-brigade-desktop-view--id)
      (format " Desktop %s  %s  %sx%s  %s"
              (plist-get status :id)
              (plist-get status :state)
              (plist-get status :width) (plist-get status :height)
              (if (plist-get status :held)
                  (propertize
                   "YOU HAVE CONTROL -- keys and clicks go to it; C-c C-r releases"
                   'face 'warning)
                "the agent has it -- t takes control, l launches, q buries")))))

(defun cmacs-brigade-desktop-view--say (text)
  "Show TEXT in place of a picture."
  (let ((inhibit-read-only t))
    (setq cmacs-brigade-desktop-view--image nil)
    (erase-buffer)
    (insert text "\n")
    (goto-char (point-min))))

(defun cmacs-brigade-desktop-view--show (png)
  "Show PNG, a picture of the desktop, scaled to fit the buffer's window."
  (if (not (display-graphic-p))
      (cmacs-brigade-desktop-view--say
       "The desktop is running.  Its picture needs a graphical frame.")
    (let* ((window (get-buffer-window (current-buffer) 'visible))
           (image (create-image
                   png 'png t
                   :max-width (and window (window-body-width window t))
                   :max-height (and window (window-body-height window t))))
           (inhibit-read-only t))
      ;; The same character each time, with a new picture on it: erasing
      ;; and inserting once a second makes the window flicker.
      (if (and cmacs-brigade-desktop-view--image (> (point-max) 1))
          (put-text-property (point-min) (1+ (point-min)) 'display image)
        (erase-buffer)
        (insert-image image "[desktop]")
        (insert "\n")
        (goto-char (point-min)))
      (setq cmacs-brigade-desktop-view--image image))))

(defun cmacs-brigade-desktop-view-refresh ()
  "Take a new picture of the desktop this buffer shows."
  (interactive)
  (let* ((buffer (current-buffer))
         (id cmacs-brigade-desktop-view--id)
         (status (cmacs-brigade-desktop-status id)))
    (force-mode-line-update)
    (pcase (plist-get status :state)
      ('ready
       (setq cmacs-brigade-desktop-view--asked (float-time))
       (cmacs-brigade-desktop-screenshot
        id
        (lambda (ok value)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq cmacs-brigade-desktop-view--asked nil)
              (if ok
                  (cmacs-brigade-desktop-view--show value)
                (cmacs-brigade-desktop-view--say
                 (format "No picture: %s" value))))))
        'human))
      ('nil (cmacs-brigade-desktop-view--say "This desktop has been stopped."))
      ((or 'locating 'starting)
       (cmacs-brigade-desktop-view--say "The desktop is starting..."))
      (state
       (cmacs-brigade-desktop-view--say
        (format "The desktop is %s: %s%s" state
                (or (plist-get status :reason) "no reason was recorded")
                (if (plist-get status :notes)
                    (concat "\n\n"
                            (string-join (plist-get status :notes) "\n"))
                  "")))))))

(defun cmacs-brigade-desktop-view--tick (buffer)
  "Refresh BUFFER's picture if somebody can see it and none is on its way."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (get-buffer-window buffer 'visible)
                 (or (null cmacs-brigade-desktop-view--asked)
                     (> (- (float-time) cmacs-brigade-desktop-view--asked)
                        (* 2 cmacs-brigade-desktop-call-timeout))))
        (cmacs-brigade-desktop-view-refresh)))))

(defun cmacs-brigade-desktop-view--changed (id)
  "Redraw the views of the desktop ID after its state changed."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'cmacs-brigade-desktop-view-mode)
                 (equal cmacs-brigade-desktop-view--id id))
        (cmacs-brigade-desktop-view-control-mode
         (if (cmacs-brigade-desktop-held-p id) 1 -1))
        (force-mode-line-update)))))

(add-hook 'cmacs-brigade-desktop-changed-functions
          #'cmacs-brigade-desktop-view--changed)


;;;; Taking it and giving it back

(defun cmacs-brigade-desktop-view-take ()
  "Take control of this desktop from its agent."
  (interactive)
  (unless (cmacs-brigade-desktop-take cmacs-brigade-desktop-view--id)
    (user-error "This desktop has been stopped"))
  (message "You have the desktop.  The agent can look but not touch; C-c C-r gives it back."))

(defun cmacs-brigade-desktop-view-release ()
  "Give this desktop back to its agent."
  (interactive)
  (if (not (cmacs-brigade-desktop-held-p cmacs-brigade-desktop-view--id))
      (message "You do not hold this desktop")
    (cmacs-brigade-desktop-release cmacs-brigade-desktop-view--id)
    (message "The agent has its desktop back.")))

(defun cmacs-brigade-desktop-view-quit ()
  "Bury this view, giving the desktop back if you held it.
A desktop held by a buffer nobody can see is an agent stopped for no
reason anybody remembers."
  (interactive)
  (when (cmacs-brigade-desktop-held-p cmacs-brigade-desktop-view--id)
    (cmacs-brigade-desktop-view-release))
  (quit-window))

(defun cmacs-brigade-desktop-view--cleanup ()
  "Stop refreshing and let go of the desktop when the buffer is killed."
  (when cmacs-brigade-desktop-view--timer
    (cancel-timer cmacs-brigade-desktop-view--timer)
    (setq cmacs-brigade-desktop-view--timer nil))
  (when (cmacs-brigade-desktop-held-p cmacs-brigade-desktop-view--id)
    (cmacs-brigade-desktop-release cmacs-brigade-desktop-view--id)))


;;;; Your hands

(defun cmacs-brigade-desktop-view--report (ok value)
  "Say why an action on the desktop failed.  Success says nothing."
  (unless ok (message "Desktop: %s" value)))

(defun cmacs-brigade-desktop-view--need-control ()
  "Signal unless you hold this desktop."
  (unless (cmacs-brigade-desktop-held-p cmacs-brigade-desktop-view--id)
    (user-error "Press t to take control of the desktop first")))

(defun cmacs-brigade-desktop-view--event-point (event)
  "Return where on the desktop the mouse EVENT happened, as (X . Y), or nil.
nil when it was not on the picture."
  (let* ((position (event-start event))
         (image (posn-image position))
         (xy (posn-object-x-y position))
         (status (cmacs-brigade-desktop-status
                  cmacs-brigade-desktop-view--id)))
    (when (and image xy status)
      (let ((shown (image-size image t)))
        (cmacs-brigade-desktop--map-point
         (car xy) (cdr xy) (car shown) (cdr shown)
         (plist-get status :layout-width)
         (plist-get status :layout-height))))))

(defun cmacs-brigade-desktop-view-click (event)
  "Click on the desktop where the mouse EVENT happened on its picture."
  (interactive "e")
  (cmacs-brigade-desktop-view--need-control)
  (when-let* ((at (cmacs-brigade-desktop-view--event-point event)))
    (cmacs-brigade-desktop-click
     cmacs-brigade-desktop-view--id (car at) (cdr at)
     (pcase (event-basic-type event)
       ('mouse-2 "middle") ('mouse-3 "right") (_ "left"))
     #'cmacs-brigade-desktop-view--report 'human)))

(defun cmacs-brigade-desktop-view-scroll (event)
  "Scroll the desktop where the wheel EVENT happened on its picture."
  (interactive "e")
  (cmacs-brigade-desktop-view--need-control)
  (when-let* ((at (cmacs-brigade-desktop-view--event-point event)))
    (cmacs-brigade-desktop-scroll
     cmacs-brigade-desktop-view--id (car at) (cdr at)
     (pcase (event-basic-type event)
       ((or 'wheel-up 'mouse-4) "up")
       ((or 'wheel-left 'mouse-6) "left")
       ((or 'wheel-right 'mouse-7) "right")
       (_ "down"))
     1 #'cmacs-brigade-desktop-view--report 'human)))

(defconst cmacs-brigade-desktop-view--keys
  '((return . "Return") (tab . "Tab") (backspace . "BackSpace")
    (escape . "Escape") (delete . "Delete") (insert . "Insert")
    (left . "Left") (right . "Right") (up . "Up") (down . "Down")
    (home . "Home") (end . "End") (prior . "Prior") (next . "Next")
    (f1 . "F1") (f2 . "F2") (f3 . "F3") (f4 . "F4") (f5 . "F5")
    (f6 . "F6") (f7 . "F7") (f8 . "F8") (f9 . "F9") (f10 . "F10")
    (f11 . "F11") (f12 . "F12")
    (?\r . "Return") (?\t . "Tab") (?\d . "BackSpace") (?\e . "Escape"))
  "Emacs events and the XKB key each is sent to a desktop as.")

(defun cmacs-brigade-desktop-view--key-name (event)
  "Return how EVENT goes to a desktop: (key . NAME), (text . STRING) or nil."
  (let ((named (alist-get event cmacs-brigade-desktop-view--keys)))
    (cond (named (cons 'key named))
          ((and (characterp event) (>= event ?\s) (/= event ?\d))
           (cons 'text (string event))))))

(defun cmacs-brigade-desktop-view-forward-key ()
  "Send the key just typed to the desktop."
  (interactive)
  (cmacs-brigade-desktop-view--need-control)
  (pcase (cmacs-brigade-desktop-view--key-name last-command-event)
    (`(key . ,name)
     (cmacs-brigade-desktop-key cmacs-brigade-desktop-view--id name
                                #'cmacs-brigade-desktop-view--report 'human))
    (`(text . ,text)
     (cmacs-brigade-desktop-type cmacs-brigade-desktop-view--id text
                                 #'cmacs-brigade-desktop-view--report 'human))
    (_ (message "That key has no name the desktop knows; send it with C-c C-k"))))

(defun cmacs-brigade-desktop-view-send-key (key)
  "Send KEY, a key or combination as XKB names it, to the desktop.
For what Emacs keeps for itself: \"Ctrl+s\", \"Alt+F4\", \"Super+Return\"."
  (interactive "sKey or combination (Ctrl+s, Alt+F4, Escape): ")
  (cmacs-brigade-desktop-view--need-control)
  (cmacs-brigade-desktop-key cmacs-brigade-desktop-view--id key
                             #'cmacs-brigade-desktop-view--report 'human))

(defun cmacs-brigade-desktop-view-launch (command)
  "Start COMMAND on the desktop.  You need not hold it to do this."
  (interactive (list (read-shell-command "Launch on the desktop: ")))
  (cmacs-brigade-desktop-launch
   cmacs-brigade-desktop-view--id command
   (lambda (ok value)
     (message (if ok "Started%s" "Desktop: %s")
              (if ok (if value (format " (pid %s)" value) "") value)))
   'human))


;;;; The mode

(defvar cmacs-brigade-desktop-view-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "t" #'cmacs-brigade-desktop-view-take)
    (define-key map "r" #'cmacs-brigade-desktop-view-release)
    (define-key map (kbd "C-c C-r") #'cmacs-brigade-desktop-view-release)
    (define-key map (kbd "C-c C-k") #'cmacs-brigade-desktop-view-send-key)
    (define-key map "l" #'cmacs-brigade-desktop-view-launch)
    (define-key map (kbd "C-c C-l") #'cmacs-brigade-desktop-view-launch)
    (define-key map "g" #'cmacs-brigade-desktop-view-refresh)
    (define-key map "q" #'cmacs-brigade-desktop-view-quit)
    (dolist (button '(mouse-1 mouse-2 mouse-3))
      (define-key map (vector button) #'cmacs-brigade-desktop-view-click)
      ;; Without these a press starts a drag and selects the picture.
      (define-key map (vector (intern (format "down-%s" button))) #'ignore)
      (define-key map (vector (intern (format "drag-%s" button))) #'ignore))
    (dolist (wheel '(wheel-up wheel-down wheel-left wheel-right
                              mouse-4 mouse-5 mouse-6 mouse-7))
      (define-key map (vector wheel) #'cmacs-brigade-desktop-view-scroll))
    map)
  "Keys in a desktop view.")

(defvar cmacs-brigade-desktop-view-control-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Every printing key, and the keys with names.  Not a default
    ;; binding: that would take C-x and M-x too, and a buffer you cannot
    ;; leave is worse than a key you have to send by name.
    (cl-loop for char from ?\s to ?~
             do (define-key map (vector char)
                            #'cmacs-brigade-desktop-view-forward-key))
    (dolist (cell cmacs-brigade-desktop-view--keys)
      (unless (eq (car cell) ?\e)
        (define-key map (vector (car cell))
                    #'cmacs-brigade-desktop-view-forward-key)))
    map)
  "Keys while you hold the desktop: what you type is the desktop's.")

(define-minor-mode cmacs-brigade-desktop-view-control-mode
  "Send what is typed in a desktop view to the desktop.
On while you hold the desktop, off when you release it."
  :lighter " Control"
  :keymap cmacs-brigade-desktop-view-control-mode-map)

(define-derived-mode cmacs-brigade-desktop-view-mode special-mode "Desktop"
  "Watch an agent's private desktop, and take it over.

\\<cmacs-brigade-desktop-view-mode-map>\
\\[cmacs-brigade-desktop-view-take] takes control.  The agent's acting tools are then refused
until you release it, and your keys, clicks and scrolling go to the
desktop.
r or C-c C-r releases it.  While you hold it only the
second does, because the first is typed into the desktop.
\\[cmacs-brigade-desktop-view-send-key] sends a combination by name.
\\[cmacs-brigade-desktop-view-launch] starts a program there.
\\[cmacs-brigade-desktop-view-quit] buries the view."
  (setq-local header-line-format
              '(:eval (cmacs-brigade-desktop-view--header)))
  (setq-local cursor-type nil)
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'cmacs-brigade-desktop-view--cleanup nil t))

;;;###autoload
(defun cmacs-brigade-desktop-view (id)
  "Watch the agent desktop ID, and take it over if you want to.

The picture is refreshed while the buffer is on screen.  See
`cmacs-brigade-desktop-view-mode' for the keys."
  (interactive
   (let ((ids (cmacs-brigade-desktop-list)))
     (cond ((null ids)
            (user-error "No agent desktops; `cmacs-brigade-desktop-start' makes one"))
           ((null (cdr ids)) ids)
           (t (list (completing-read "Desktop: " ids nil t))))))
  (let ((buffer (get-buffer-create (format "*Desktop: %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'cmacs-brigade-desktop-view-mode)
        (cmacs-brigade-desktop-view-mode))
      (setq cmacs-brigade-desktop-view--id (format "%s" id))
      (unless cmacs-brigade-desktop-view--timer
        (setq cmacs-brigade-desktop-view--timer
              (run-at-time cmacs-brigade-desktop-view-interval
                           cmacs-brigade-desktop-view-interval
                           #'cmacs-brigade-desktop-view--tick buffer)))
      (cmacs-brigade-desktop-view-control-mode
       (if (cmacs-brigade-desktop-held-p id) 1 -1)))
    (pop-to-buffer buffer)
    (with-current-buffer buffer (cmacs-brigade-desktop-view-refresh))
    buffer))

(provide 'cmacs-brigade-desktop-view)

;;; cmacs-brigade-desktop-view.el ends here
