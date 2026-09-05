;;; cmacs-tray.el --- A system tray inside Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Solaar, Syncthing, Steam, Element and a long tail of others put
;; their only always-available interface in a tray icon.  Under gowl
;; there is nowhere to put one -- and on a stock GNOME without the
;; AppIndicator extension there is nowhere either, so those apps have
;; been running with their interface simply absent.
;;
;; The tray is not an X11 thing any more: it is `StatusNotifierItem',
;; three D-Bus interfaces and no compositor involvement at all.  A
;; *watcher* owns a well-known name and keeps the registry; a *host*
;; says it is willing to display items; each *item* is an object on the
;; application's own bus name carrying a title, a status, an icon and a
;; menu.  Nothing in that requires pixels.
;;
;; So this is a real tray that happens to render as a buffer.  It works
;; identically under gowl, under GNOME, in a terminal and over
;; `emacsclient -nw', and because it is the watcher as well as the host
;; it is the whole tray on the machine rather than a second one
;; competing with a shell extension.
;;
;; What it does not do: icons.  An item's icon arrives either as a
;; themed name or as raw ARGB pixmaps over D-Bus, and a list of
;; applications with their titles and statuses is more useful in a
;; buffer than a row of 22-pixel images would be.  The icon *name* is
;; kept, so a graphical renderer could be added without touching any of
;; the protocol below.

;;; Code:

(require 'dbus)
(require 'cl-lib)
(require 'subr-x)

(defgroup cmacs-tray nil
  "A StatusNotifierItem tray rendered in Emacs."
  :group 'cmacs
  :prefix "cmacs-tray-")

(defconst cmacs-tray-watcher-service "org.kde.StatusNotifierWatcher")
(defconst cmacs-tray-watcher-path "/StatusNotifierWatcher")
(defconst cmacs-tray-watcher-interface "org.kde.StatusNotifierWatcher")
(defconst cmacs-tray-item-interface "org.kde.StatusNotifierItem")
(defconst cmacs-tray-menu-interface "com.canonical.dbusmenu")

(defcustom cmacs-tray-buffer "*tray*"
  "Buffer showing tray items."
  :type 'string
  :group 'cmacs-tray)

(defcustom cmacs-tray-call-timeout 500
  "Milliseconds to wait for a tray application to answer.

Deliberately short.  Reading an item's properties is a synchronous call
into another process, and a wedged application must not take the editor
with it -- the cost of giving up is one row rendering as unknown."
  :type 'integer
  :group 'cmacs-tray)

(defcustom cmacs-tray-functions nil
  "Hook run with (EVENT ITEM) when the tray changes.
EVENT is `added', `removed' or `updated'; ITEM is the item plist."
  :type 'hook
  :group 'cmacs-tray)

;;; State

(defvar cmacs-tray--registered nil
  "Non-nil when this Emacs owns the watcher name.")

(defvar cmacs-tray--objects nil
  "D-Bus registrations to release on shutdown.")

(defvar cmacs-tray--items nil
  "Alist of SERVICE -> item plist, in registration order.")

(defvar cmacs-tray--host-name nil
  "The host name this Emacs registered, if any.")

;;; Service strings

(defun cmacs-tray--split-service (service)
  "Split SERVICE into (BUS-NAME . OBJECT-PATH).

An item registers itself either as a bare bus name or as
\"bus/object/path\".  The specification allows both and applications
use both, so a tray that assumes one shows half of them."
  (cond
   ((null service) nil)
   ((string-prefix-p "/" service)
    ;; Just a path: the sender's own name is the bus name, which the
    ;; caller supplies.
    (cons nil service))
   ((string-match "\\`\\([^/]+\\)\\(/.*\\)\\'" service)
    (cons (match-string 1 service) (match-string 2 service)))
   (t (cons service "/StatusNotifierItem"))))

;;; Reading an item

(defun cmacs-tray--property (bus path name)
  "Read property NAME from the item at BUS and PATH, or nil.

Goes through org.freedesktop.DBus.Properties.Get rather than
`dbus-get-property', which takes no timeout: reading a property is a
synchronous call into another process, and a wedged tray application
would otherwise block the editor for D-Bus's 25-second default."
  (condition-case nil
      (car (dbus-call-method :session bus path
                             dbus-interface-properties "Get"
                             :timeout cmacs-tray-call-timeout
                             cmacs-tray-item-interface name))
    (error nil)))

(defun cmacs-tray--tooltip-text (tooltip)
  "Extract readable text from a StatusNotifierItem ToolTip struct.
The struct is (icon-name, icon-pixmaps, title, description); the two
strings are what a text renderer wants."
  (when (and (listp tooltip) (>= (length tooltip) 4))
    (let ((title (nth 2 tooltip))
          (desc (nth 3 tooltip)))
      (string-trim
       (concat (if (stringp title) title "")
               (if (and (stringp desc) (not (string-empty-p desc)))
                   (concat " — " desc) ""))))))

(defun cmacs-tray--read-item (service &optional sender)
  "Build the item plist for SERVICE, or nil when it cannot be read.
SENDER is the unique bus name the registration came from, used when
SERVICE carries only an object path."
  (let* ((split (cmacs-tray--split-service service))
         (bus (or (car split) sender))
         (path (cdr split)))
    (when (and bus path)
      (list :service service
            :bus bus
            :path path
            :id (or (cmacs-tray--property bus path "Id") "")
            :title (or (cmacs-tray--property bus path "Title") "")
            :status (or (cmacs-tray--property bus path "Status") "Active")
            :category (or (cmacs-tray--property bus path "Category") "")
            ;; Kept even though nothing renders it, so a graphical
            ;; front end needs no protocol work.
            :icon-name (or (cmacs-tray--property bus path "IconName") "")
            :tooltip (cmacs-tray--tooltip-text
                      (cmacs-tray--property bus path "ToolTip"))
            :menu (cmacs-tray--property bus path "Menu")))))

(defun cmacs-tray--label (item)
  "A one-line label for ITEM."
  (let ((title (plist-get item :title))
        (id (plist-get item :id))
        (tip (plist-get item :tooltip)))
    (cond
     ((and title (not (string-empty-p title))) title)
     ((and tip (not (string-empty-p tip))) tip)
     ((and id (not (string-empty-p id))) id)
     (t (plist-get item :bus)))))

;;; The registry

(defun cmacs-tray--emit (signal &rest args)
  "Emit SIGNAL on the watcher interface with ARGS."
  (ignore-errors
    (apply #'dbus-send-signal
           :session nil cmacs-tray-watcher-path
           cmacs-tray-watcher-interface signal args)))

(defun cmacs-tray--item-services ()
  "The registered item service strings, in order."
  (mapcar #'car cmacs-tray--items))

(defun cmacs-tray--forget (service &optional reason)
  "Drop SERVICE from the registry and tell everyone."
  (let ((entry (assoc service cmacs-tray--items)))
    (when entry
      (setq cmacs-tray--items (assoc-delete-all service cmacs-tray--items))
      (cmacs-tray--publish-properties)
      (cmacs-tray--emit "StatusNotifierItemUnregistered" service)
      (run-hook-with-args 'cmacs-tray-functions 'removed (cdr entry))
      (when (get-buffer cmacs-tray-buffer)
        (cmacs-tray-refresh))
      (when reason
        (message "cmacs-tray: %s removed (%s)"
                 (cmacs-tray--label (cdr entry)) reason)))))

(defun cmacs-tray--watch-owner (bus)
  "Notice when BUS disappears and drop its items.

Applications exit without unregistering -- there is no
UnregisterStatusNotifierItem in the specification at all -- so tracking
name ownership is the only way a tray ever shrinks."
  (dbus-register-signal
   :session dbus-service-dbus dbus-path-dbus
   dbus-interface-dbus "NameOwnerChanged"
   (lambda (name _old new)
     (when (and (equal name bus) (string-empty-p (or new "")))
       (dolist (entry (copy-sequence cmacs-tray--items))
         (when (equal (plist-get (cdr entry) :bus) bus)
           (cmacs-tray--forget (car entry) "application exited")))))
   bus))

;;; Specification methods

(defun cmacs-tray--populate (service sender)
  "Read SERVICE's properties and add it to the registry.

Deliberately NOT done inside the RegisterStatusNotifierItem handler.
Reading a property is a synchronous call back into the application ---
which at that moment is blocked waiting for our reply to its
registration.  Neither side can proceed, so every read times out and
the item lands with an empty title, no icon and no menu.  It is not
even a reliable failure: whether a given property makes it depends on
how quickly the client returns to its own main loop, which is why the
item looked fine one run and empty the next.

Answering first and reading afterwards costs one idle turn and makes
the whole thing deterministic."
  (let ((item (cmacs-tray--read-item service sender)))
    (if (null item)
        (message "cmacs-tray: could not read item %s" service)
      (setq cmacs-tray--items
            (append (assoc-delete-all service cmacs-tray--items)
                    (list (cons service item))))
      (cmacs-tray--watch-owner (plist-get item :bus))
      (cmacs-tray--publish-properties)
      (cmacs-tray--emit "StatusNotifierItemRegistered" service)
      (run-hook-with-args 'cmacs-tray-functions 'added item)
      (when (get-buffer cmacs-tray-buffer)
        (cmacs-tray-refresh)))))

(defun cmacs-tray--register-item (service)
  "Handle RegisterStatusNotifierItem.

Returns immediately and reads the item on the next idle turn; see
`cmacs-tray--populate' for why that ordering is load-bearing."
  (let ((sender (dbus-event-service-name last-input-event)))
    (run-with-idle-timer
     0 nil
     (lambda () (cmacs-tray--populate service sender))))
  :ignore)

(defun cmacs-tray--register-host (service)
  "Handle RegisterStatusNotifierHost."
  (ignore service)
  (cmacs-tray--emit "StatusNotifierHostRegistered")
  :ignore)

;;; Rendering

(defvar cmacs-tray-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-tray-activate)
    (define-key map (kbd "a") #'cmacs-tray-activate)
    (define-key map (kbd "s") #'cmacs-tray-secondary-activate)
    (define-key map (kbd "m") #'cmacs-tray-menu)
    (define-key map (kbd "c") #'cmacs-tray-context-menu)
    (define-key map (kbd "g") #'cmacs-tray-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `cmacs-tray-mode'.")

(define-derived-mode cmacs-tray-mode special-mode "Tray"
  "Major mode for the system tray.

\\{cmacs-tray-mode-map}")

(defun cmacs-tray-refresh ()
  "Re-read every item and redraw the tray buffer."
  (interactive)
  (with-current-buffer (get-buffer-create cmacs-tray-buffer)
    (unless (derived-mode-p 'cmacs-tray-mode)
      (cmacs-tray-mode))
    (let ((inhibit-read-only t)
          (line (line-number-at-pos)))
      (erase-buffer)
      (if (null cmacs-tray--items)
          (insert (if cmacs-tray--registered
                      "No tray items.\n\nThe tray is running; nothing has registered.\n"
                    "Tray not running.  M-x cmacs-tray-mode-global\n"))
        (insert (format "%d tray item%s   "
                        (length cmacs-tray--items)
                        (if (= (length cmacs-tray--items) 1) "" "s"))
                "(RET activate, s secondary, m menu, g refresh)\n\n")
        (dolist (entry cmacs-tray--items)
          (let* ((item (cdr entry))
                 (status (plist-get item :status))
                 (tip (plist-get item :tooltip)))
            (insert (propertize
                     (format "  %-28s  %-9s  %s\n"
                             (cmacs-tray--label item)
                             (or status "")
                             (or tip ""))
                     'cmacs-tray-service (car entry))))))
      (goto-char (point-min))
      (forward-line (1- line)))
    (current-buffer)))

;;;###autoload
(defun cmacs-tray ()
  "Show the system tray."
  (interactive)
  (pop-to-buffer (cmacs-tray-refresh)))

(defun cmacs-tray--item-at-point ()
  "The item plist on the current line, or nil."
  (let ((service (get-text-property (line-beginning-position)
                                    'cmacs-tray-service)))
    (and service (cdr (assoc service cmacs-tray--items)))))

(defun cmacs-tray--invoke (method)
  "Call METHOD on the item at point.

Position arguments are zero: the specification wants screen
coordinates so an application can place its own popup there, and there
is no meaningful cursor position behind a buffer row.  Applications
treat 0,0 as \"you pick\"."
  (let ((item (cmacs-tray--item-at-point)))
    (unless item (user-error "No tray item on this line"))
    (condition-case err
        (progn
          (dbus-call-method :session (plist-get item :bus) (plist-get item :path)
                            cmacs-tray-item-interface method
                            :timeout cmacs-tray-call-timeout
                            :int32 0 :int32 0)
          (message "%s: %s" (cmacs-tray--label item) method))
      (error
       (message "%s: %s failed: %s" (cmacs-tray--label item) method
                (error-message-string err))))))

(defun cmacs-tray-activate ()
  "Activate the tray item at point, as a left click would."
  (interactive)
  (cmacs-tray--invoke "Activate"))

(defun cmacs-tray-secondary-activate ()
  "Secondary-activate the item at point, as a middle click would."
  (interactive)
  (cmacs-tray--invoke "SecondaryActivate"))

(defun cmacs-tray-context-menu ()
  "Ask the item at point to show its own context menu."
  (interactive)
  (cmacs-tray--invoke "ContextMenu"))

;;; DBusMenu

(defun cmacs-tray--menu-entries (item)
  "Return (LABEL . ID) pairs from ITEM's DBusMenu, or nil.

The layout comes back as a recursive (id, properties, children) struct.
Only the top level is offered: a submenu would need the whole tree
walked, and every tray menu worth using is flat."
  (let ((menu (plist-get item :menu)))
    (when menu
      (condition-case nil
          (let* ((_ (ignore-errors
                      ;; DBusMenu is lazy: many applications build their
                      ;; menu only when told it is about to be shown, so
                      ;; GetLayout on its own returns an empty root.
                      ;; The reply says whether anything changed; we do
                      ;; not care, only that the app got the chance.
                      (dbus-call-method
                       :session (plist-get item :bus) menu
                       cmacs-tray-menu-interface "AboutToShow"
                       :timeout cmacs-tray-call-timeout
                       :int32 0)))
                 (reply (dbus-call-method
                         :session (plist-get item :bus) menu
                         cmacs-tray-menu-interface "GetLayout"
                         :timeout cmacs-tray-call-timeout
                         ;; An empty array needs the :signature form;
                         ;; '(:array :string) with no elements makes
                         ;; dbus.el signal, which is why the menu came
                         ;; back empty for every application.
                         :int32 0 :int32 1 '(:array :signature "s")))
                 ;; (revision, (id, props, children))
                 (root (nth 1 reply))
                 (children (nth 2 root))
                 (out nil))
            (dolist (child children)
              ;; Each child arrives as a one-element list wrapping the
              ;; (id, properties, children) struct, and every property
              ;; value is itself wrapped -- dbus.el unwraps the variant
              ;; to a list, not to the scalar.
              (let* ((node (if (and (consp child) (consp (car child))
                                    (integerp (car (car child))))
                               (car child)
                             child))
                     (id (nth 0 node))
                     (props (nth 1 node))
                     (label (car (cadr (assoc "label" props))))
                     (type (car (cadr (assoc "type" props))))
                     (visible-cell (assoc "visible" props))
                     (visible (if visible-cell
                                  (car (cadr visible-cell))
                                t)))
                (when (and (integerp id)
                           (stringp label)
                           (not (equal type "separator"))
                           visible
                           (not (string-empty-p (string-trim label))))
                  ;; DBusMenu marks a mnemonic with an underscore,
                  ;; which is noise in a completing-read.
                  (push (cons (string-trim
                               (replace-regexp-in-string "_" "" label))
                              id)
                        out))))
            (nreverse out))
        (error nil)))))

(defun cmacs-tray-menu ()
  "Open the DBusMenu of the item at point and pick an entry."
  (interactive)
  (let* ((item (cmacs-tray--item-at-point)))
    (unless item (user-error "No tray item on this line"))
    (let ((entries (cmacs-tray--menu-entries item)))
      (unless entries
        (user-error "%s exposes no menu" (cmacs-tray--label item)))
      (let* ((choice (completing-read
                      (format "%s: " (cmacs-tray--label item))
                      (mapcar #'car entries) nil t))
             (id (cdr (assoc choice entries))))
        (condition-case err
            (progn
              (dbus-call-method
               :session (plist-get item :bus) (plist-get item :menu)
               cmacs-tray-menu-interface "Event"
               :timeout cmacs-tray-call-timeout
               :int32 id "clicked" '(:variant :string "")
               :uint32 (truncate (float-time)))
              (message "%s: %s" (cmacs-tray--label item) choice))
          (error (message "menu event failed: %s"
                          (error-message-string err))))))))

;;; Registration

(defun cmacs-tray--owner ()
  "The current owner of the watcher name, or nil."
  (ignore-errors (dbus-get-name-owner :session cmacs-tray-watcher-service)))

(defun cmacs-tray--publish-properties ()
  "Publish the watcher's three properties with their declared types.

Re-called whenever the item list changes: `dbus-register-property'
stores a value, not a getter, so a list published once would report
the tray as empty forever."
  (ignore-errors
    (dbus-register-property
     :session cmacs-tray-watcher-service cmacs-tray-watcher-path
     cmacs-tray-watcher-interface "ProtocolVersion" :read
     :int32 0 t))
  (ignore-errors
    (dbus-register-property
     :session cmacs-tray-watcher-service cmacs-tray-watcher-path
     cmacs-tray-watcher-interface "IsStatusNotifierHostRegistered" :read
     :boolean t t))
  (ignore-errors
    (dbus-register-property
     :session cmacs-tray-watcher-service cmacs-tray-watcher-path
     cmacs-tray-watcher-interface "RegisteredStatusNotifierItems" :read
     ;; One compound list, not :array plus a Lisp list -- the latter
     ;; makes dbus.el publish a plain string, which clients reject as
     ;; the wrong type for `as'.  The :signature form is how an empty
     ;; array of strings is spelled.
     (if (cmacs-tray--item-services)
         (append '(:array) (cmacs-tray--item-services))
       '(:array :signature "s"))
     t)))

(defun cmacs-tray--register-everything ()
  "Register the watcher's methods, properties and our own host name."
  (setq cmacs-tray--objects
        (list
         (dbus-register-method
          :session cmacs-tray-watcher-service cmacs-tray-watcher-path
          cmacs-tray-watcher-interface "RegisterStatusNotifierItem"
          #'cmacs-tray--register-item t)
         (dbus-register-method
          :session cmacs-tray-watcher-service cmacs-tray-watcher-path
          cmacs-tray-watcher-interface "RegisterStatusNotifierHost"
          #'cmacs-tray--register-host t)))

  ;; Properties an item reads before deciding to register at all.  An
  ;; application that cannot see IsStatusNotifierHostRegistered as true
  ;; assumes nothing will display it and falls back to whatever legacy
  ;; path it has -- which under Wayland is usually none.
  ;;
  ;; Each is registered with an EXPLICIT type.  dbus.el infers one from
  ;; the value otherwise, and it infers wrongly here in two places:
  ;; the integer 0 becomes uint32 where the interface says int32, and an
  ;; empty item list -- nil -- becomes a boolean rather than an empty
  ;; array of strings.  Solaar reports both as warnings and carries on;
  ;; a stricter client would simply not appear.
  (cmacs-tray--publish-properties)

  (setq cmacs-tray--host-name
        (format "org.kde.StatusNotifierHost-%d" (emacs-pid)))
  (ignore-errors
    (dbus-register-service :session cmacs-tray--host-name :do-not-queue))
  (cmacs-tray--emit "StatusNotifierHostRegistered"))

;;;###autoload
(define-minor-mode cmacs-tray-mode-global
  "Own org.kde.StatusNotifierWatcher and show tray items in Emacs.

Claims the watcher name only when it is free.  A desktop that already
has a tray host -- GNOME with the AppIndicator extension, a KDE
session -- keeps it, and this says so rather than fighting for it:
two watchers means applications register with whichever answered
first, and icons scatter between them.

Enabling this makes Emacs the whole tray on the machine.  Under gowl
that is the only one there is; on a stock GNOME without AppIndicator
it is also the only one, which is why Solaar and Syncthing have been
running with no visible interface at all."
  :global t
  :group 'cmacs-tray
  :lighter " Tray"
  (if cmacs-tray-mode-global
      (let ((owner (cmacs-tray--owner)))
        (cond
         (cmacs-tray--registered nil)
         (owner
          (setq cmacs-tray-mode-global nil)
          (message "cmacs-tray: %s is already owned by %s; not claiming it"
                   cmacs-tray-watcher-service owner))
         (t
          (condition-case err
              (let ((result (dbus-register-service
                             :session cmacs-tray-watcher-service
                             :do-not-queue)))
                (if (memq result '(:primary-owner :already-owner))
                    (progn
                      (cmacs-tray--register-everything)
                      (setq cmacs-tray--registered t)
                      (message "cmacs-tray: serving %s"
                               cmacs-tray-watcher-service))
                  (setq cmacs-tray-mode-global nil)
                  (message "cmacs-tray: could not claim %s (%s)"
                           cmacs-tray-watcher-service result)))
            (error
             (setq cmacs-tray-mode-global nil)
             (message "cmacs-tray: %s" (error-message-string err)))))))
    (when cmacs-tray--registered
      (cmacs-tray--emit "StatusNotifierHostUnregistered")
      (dolist (obj cmacs-tray--objects)
        (ignore-errors (dbus-unregister-object obj)))
      (setq cmacs-tray--objects nil)
      (ignore-errors
        (dbus-unregister-service :session cmacs-tray-watcher-service))
      (when cmacs-tray--host-name
        (ignore-errors
          (dbus-unregister-service :session cmacs-tray--host-name)))
      (setq cmacs-tray--items nil)
      (setq cmacs-tray--registered nil))))

;;;###autoload
(defun cmacs-tray-serving-p ()
  "Return non-nil when this Emacs is the tray watcher."
  cmacs-tray--registered)

(provide 'cmacs-tray)

;;; cmacs-tray.el ends here
