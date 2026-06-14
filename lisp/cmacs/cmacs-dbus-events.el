;;; cmacs-dbus-events.el --- Broadcast editor events over D-Bus  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Lisp side of the cmacs events endpoint.  The C interface
;; (cmacs/dbus/cmacs-dbus-iface-events.c) owns the introspection
;; contract for `org.cmacs.Editor1.Events' at /org/cmacs/Editor;
;; this module wires Emacs hooks to it so external D-Bus clients (status
;; bars, dashboards, automation, observability stacks, other editors)
;; can subscribe and react to editor activity.
;;
;; Every event is broadcast two ways:
;;
;;   * the generic firehose signal `Event(category name detail data ts)'
;;     via the `cmacs-dbus-emit-event' DEFUN -- one subscription gets
;;     everything; and
;;   * a typed named signal (FileOpened, BufferSwitched, ...) via
;;     `cmacs-dbus-emit-signal' for selective subscription.
;;
;; Emission is fire-and-forget and a no-op whenever the D-Bus service is
;; down, so the hooks are cheap and safe.  Every handler is wrapped so a
;; bridge can never break editing.
;;
;; Enabled by default for the core categories (file, buffer, project,
;; window, frame, editor); the high-volume `text' category and the
;; subsystem bridges (gsurf, ai, cintrospect) are opt-in via
;; `cmacs-dbus-events-categories'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function project-root "project" (project))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function json-encode "json" (object))

;; Emitter DEFUNs from cmacs/dbus/cmacs-dbus-emit.c (HAVE_CMACS_GLIB).
(declare-function cmacs-dbus-emit-event "cmacs-dbus"
                  (category name &optional detail data))
(declare-function cmacs-dbus-emit-signal "cmacs-dbus"
                  (path iface name &optional params))

(defgroup cmacs-dbus-events nil
  "Broadcast cmacs editor events over D-Bus."
  :group 'cmacs-dbus)

(defconst cmacs-dbus-events--iface "org.cmacs.Editor1.Events"
  "Interface name of the events surface.")

(defconst cmacs-dbus-events--path "/org/cmacs/Editor"
  "Object path the firehose and named event signals are emitted on.
This is the root path (like every other cmacs interface) so emacsctl,
which calls methods at the root, can reach the Events methods.")

(defconst cmacs-dbus-events--root-path "/org/cmacs/Editor"
  "Root object path where the legacy per-manager signals live.")

(defun cmacs-dbus-events--reinit (sym val)
  "Set SYM to VAL and re-install hooks if the mode is active."
  (set-default sym val)
  (when (bound-and-true-p cmacs-dbus-events-mode)
    (cmacs-dbus-events--uninstall)
    (cmacs-dbus-events--install)))

(defcustom cmacs-dbus-events-categories
  '(file buffer project window frame editor)
  "Event categories that are broadcast over D-Bus.
Each symbol enables one family of events:

  file     file open / save / close
  buffer   buffer create / kill / switch / save / modified state
  project  project.el project switches
  window   selected-window changes
  frame    frame open / close / focus
  editor   editor startup / shutdown
  text     fine-grained text edits (high volume; coalesced)
  gsurf    embedded browser load / uri / title / crash
  ai       libreclaw inbound chat messages
  cintrospect  successful C hot-patches

The high-volume `text' category and the subsystem bridges are off by
default.  Changing this while `cmacs-dbus-events-mode' is on re-installs
the hooks immediately."
  :type '(set (const file) (const buffer) (const project) (const window)
              (const frame) (const editor) (const text) (const gsurf)
              (const ai) (const cintrospect))
  :set #'cmacs-dbus-events--reinit
  :group 'cmacs-dbus-events)

(defcustom cmacs-dbus-events-ring-size 256
  "How many recent events to retain for the `Recent' D-Bus method."
  :type 'natnum
  :group 'cmacs-dbus-events)

(defcustom cmacs-dbus-events-buffer-filter
  #'cmacs-dbus-events-default-buffer-filter
  "Predicate deciding whether a buffer's events are interesting.
Called with one buffer argument; return non-nil to broadcast events for
that buffer.  The default skips internal buffers whose name starts with
a space."
  :type 'function
  :group 'cmacs-dbus-events)

(defcustom cmacs-dbus-events-debug nil
  "When non-nil, log emit failures to *Messages* instead of swallowing them."
  :type 'boolean
  :group 'cmacs-dbus-events)

;;; Recent-event ring buffer

(defvar cmacs-dbus-events--ring nil
  "Most-recent-first list of recorded event plists (capped).")

(defun cmacs-dbus-events--record (category name detail data)
  "Push a CATEGORY/NAME event (DETAIL, DATA) onto the ring buffer."
  (push (list :category category :name name :detail (or detail "")
              :data data :time (float-time))
        cmacs-dbus-events--ring)
  (let ((n (length cmacs-dbus-events--ring)))
    (when (> n cmacs-dbus-events-ring-size)
      (setcdr (nthcdr (1- cmacs-dbus-events-ring-size)
                      cmacs-dbus-events--ring)
              nil))))

(defun cmacs-dbus-events--recent-json (n)
  "Return the last N recorded events as a JSON array string (oldest first).
Called from the C `Recent' method handler."
  (condition-case _
      (progn
        (require 'json)
        (json-encode
         (apply #'vector
                (reverse (seq-take cmacs-dbus-events--ring (max 1 n))))))
    (error "[]")))

(defun cmacs-dbus-events--categories-string ()
  "Return the enabled categories joined by \"|||\" for the C side."
  (mapconcat #'symbol-name cmacs-dbus-events-categories "|||"))

;;; Emission helpers

(defun cmacs-dbus-events--emit (category name &optional detail data signal args)
  "Broadcast a CATEGORY/NAME event when CATEGORY is enabled.
DETAIL is the primary subject string; DATA a plist of extra fields
marshalled to a{sv}.  When SIGNAL (a string) is given, also emit that
typed named signal on the Events interface with ARGS (a list)."
  (when (and (memq (intern category) cmacs-dbus-events-categories)
             (fboundp 'cmacs-dbus-emit-event))
    (condition-case err
        (progn
          (cmacs-dbus-events--record category name detail data)
          (cmacs-dbus-emit-event category name (or detail "") data)
          (when signal
            (cmacs-dbus-emit-signal cmacs-dbus-events--path
                                    cmacs-dbus-events--iface signal args)))
      (error
       (when cmacs-dbus-events-debug
         (message "cmacs-dbus-events: %s/%s emit failed: %S"
                  category name err))))))

(defun cmacs-dbus-events--emit-root (iface signal args)
  "Emit SIGNAL on IFACE at the root path with ARGS (legacy manager signals)."
  (when (fboundp 'cmacs-dbus-emit-signal)
    (ignore-errors
      (cmacs-dbus-emit-signal cmacs-dbus-events--root-path iface signal args))))

;;; Predicates and small helpers

(defun cmacs-dbus-events-default-buffer-filter (buffer)
  "Default `cmacs-dbus-events-buffer-filter': skip ` *internal*' buffers."
  (let ((name (buffer-name buffer)))
    (and name (not (string-prefix-p " " name)))))

(defun cmacs-dbus-events--interesting-p (buffer)
  "Non-nil when BUFFER is live and passes `cmacs-dbus-events-buffer-filter'."
  (and (buffer-live-p buffer)
       (condition-case _ (funcall cmacs-dbus-events-buffer-filter buffer)
         (error t))))

(defun cmacs-dbus-events--frame-id (frame)
  "Return a stable string id for FRAME."
  (or (and (frame-live-p frame) (frame-parameter frame 'name))
      (format "%s" frame)))

(defun cmacs-dbus-events--project-root ()
  "Return the current project root as an expanded string, or \"\"."
  (or (ignore-errors
        (when-let* ((proj (project-current nil))
                    ((fboundp 'project-root)))
          (expand-file-name (project-root proj))))
      ""))

;;; Per-category state

(defvar cmacs-dbus-events--known-buffers nil
  "Buffers already seen, for buffer-creation detection.")
(defvar cmacs-dbus-events--last-buffer nil
  "Last current buffer, for switch detection.")
(defvar cmacs-dbus-events--last-project nil
  "Last seen project root, for project-switch detection.")
(defvar cmacs-dbus-events--scan-timer nil
  "Pending idle timer coalescing `buffer-list-update-hook' bursts.")
(defvar cmacs-dbus-events--frame-focus (make-hash-table :test 'equal)
  "Frame id -> last known focus state, for focus-change detection.")
(defvar cmacs-dbus-events--text-pending (make-hash-table :test 'eq)
  "Buffer -> (BEG END LENGTH) of coalesced text changes.")
(defvar cmacs-dbus-events--text-timer nil
  "Pending idle timer flushing coalesced text changes.")

;;; File / buffer handlers

(defun cmacs-dbus-events--on-find-file ()
  "Emit file/opened and check for a project switch."
  (let ((file (buffer-file-name)))
    (when file
      (cmacs-dbus-events--emit
       "file" "opened" file
       (list :file file :buffer (buffer-name) :mode (symbol-name major-mode))
       "FileOpened" (list file))))
  (cmacs-dbus-events--maybe-project-switch))

(defun cmacs-dbus-events--on-after-save ()
  "Emit file/saved, buffer/saved and buffer/unmodified."
  (let ((file (buffer-file-name))
        (name (buffer-name)))
    (when file
      (cmacs-dbus-events--emit "file" "saved" file
                               (list :file file :buffer name)
                               "FileSaved" (list file)))
    (cmacs-dbus-events--emit "buffer" "saved" name
                             (list :name name :file (or file ""))
                             "BufferSaved" (list name (or file "")))
    (cmacs-dbus-events--emit "buffer" "unmodified" name
                             (list :name name)
                             "BufferUnmodified" (list name))))

(defun cmacs-dbus-events--on-first-change ()
  "Emit buffer/modified when a buffer first becomes modified."
  (when (cmacs-dbus-events--interesting-p (current-buffer))
    (let ((name (buffer-name)))
      (cmacs-dbus-events--emit "buffer" "modified" name (list :name name)
                               "BufferModified" (list name)))))

(defun cmacs-dbus-events--on-kill-buffer ()
  "Emit buffer/killed (+ root BufferRemoved) and file/closed."
  (when (cmacs-dbus-events--interesting-p (current-buffer))
    (let ((name (buffer-name))
          (file (buffer-file-name)))
      (cmacs-dbus-events--emit "buffer" "killed" name
                               (list :name name :file (or file ""))
                               "BufferKilled" (list name))
      (cmacs-dbus-events--emit-root
       "org.cmacs.Editor1.BufferManager" "BufferRemoved" (list name))
      (when file
        (cmacs-dbus-events--emit "file" "closed" file
                                 (list :file file :buffer name)
                                 "FileClosed" (list file))))))

(defun cmacs-dbus-events--schedule-scan (&rest _)
  "Coalesce `buffer-list-update-hook' bursts into one idle scan."
  (unless cmacs-dbus-events--scan-timer
    (setq cmacs-dbus-events--scan-timer
          (run-with-idle-timer 0.1 nil #'cmacs-dbus-events--scan))))

(defun cmacs-dbus-events--scan ()
  "Detect newly-created buffers, buffer switches, and project switches."
  (setq cmacs-dbus-events--scan-timer nil)
  (condition-case _
      (progn
        ;; New buffers.
        (dolist (buf (buffer-list))
          (unless (memq buf cmacs-dbus-events--known-buffers)
            (when (cmacs-dbus-events--interesting-p buf)
              (let ((name (buffer-name buf)))
                (cmacs-dbus-events--emit
                 "buffer" "created" name
                 (list :name name :file (buffer-file-name buf))
                 "BufferCreated" (list name))
                (cmacs-dbus-events--emit-root
                 "org.cmacs.Editor1.BufferManager" "BufferAdded"
                 (list name))))))
        (setq cmacs-dbus-events--known-buffers (buffer-list))
        ;; Current-buffer switch.
        (let ((cur (current-buffer)))
          (when (and (not (eq cur cmacs-dbus-events--last-buffer))
                     (cmacs-dbus-events--interesting-p cur))
            (let ((name (buffer-name cur))
                  (prev (and (buffer-live-p cmacs-dbus-events--last-buffer)
                             (buffer-name cmacs-dbus-events--last-buffer))))
              (cmacs-dbus-events--emit
               "buffer" "switched" name
               (list :name name :previous (or prev ""))
               "BufferSwitched" (list name (or prev "")))
              (setq cmacs-dbus-events--last-buffer cur))))
        (cmacs-dbus-events--maybe-project-switch))
    (error nil)))

(defun cmacs-dbus-events--maybe-project-switch ()
  "Emit project/switched when the current project root changes."
  (let ((root (cmacs-dbus-events--project-root)))
    (unless (equal root cmacs-dbus-events--last-project)
      (when (and root (not (string-empty-p root)))
        (cmacs-dbus-events--emit
         "project" "switched" root
         (list :root root :previous (or cmacs-dbus-events--last-project ""))
         "ProjectSwitched"
         (list root (or cmacs-dbus-events--last-project ""))))
      (setq cmacs-dbus-events--last-project root))))

;;; Window / frame handlers

(defun cmacs-dbus-events--on-window-selection (&optional frame)
  "Emit window/selection-changed for FRAME's newly selected window."
  (let* ((buf (window-buffer (selected-window)))
         (name (buffer-name buf))
         (fr (cmacs-dbus-events--frame-id (or frame (selected-frame)))))
    (when (cmacs-dbus-events--interesting-p buf)
      (cmacs-dbus-events--emit "window" "selection-changed" name
                               (list :buffer name :frame fr)
                               "WindowSelectionChanged" (list name fr)))))

(defun cmacs-dbus-events--on-make-frame (frame)
  "Emit frame/opened for FRAME."
  (let ((id (cmacs-dbus-events--frame-id frame)))
    (cmacs-dbus-events--emit "frame" "opened" id (list :frame id)
                             "FrameOpened" (list id))))

(defun cmacs-dbus-events--on-delete-frame (frame)
  "Emit frame/closed for FRAME."
  (let ((id (cmacs-dbus-events--frame-id frame)))
    (cmacs-dbus-events--emit "frame" "closed" id (list :frame id)
                             "FrameClosed" (list id))))

(defun cmacs-dbus-events--on-focus-change ()
  "Emit frame/focused or frame/unfocused as window-system focus changes."
  (dolist (frame (frame-list))
    (let* ((id (cmacs-dbus-events--frame-id frame))
           (focused (eq (frame-focus-state frame) t))
           (prev (gethash id cmacs-dbus-events--frame-focus 'unset)))
      (unless (eq focused prev)
        (puthash id focused cmacs-dbus-events--frame-focus)
        (if focused
            (cmacs-dbus-events--emit "frame" "focused" id (list :frame id)
                                     "FrameFocused" (list id))
          (cmacs-dbus-events--emit "frame" "unfocused" id (list :frame id)
                                   "FrameUnfocused" (list id)))))))

;;; Editor lifecycle

(defun cmacs-dbus-events--on-kill-emacs ()
  "Emit editor/shutdown."
  (cmacs-dbus-events--emit "editor" "shutdown" "" nil "EditorShutdown" nil))

;;; Text changes (opt-in, coalesced)

(defun cmacs-dbus-events--on-change (beg end len)
  "Accumulate a (BEG END LEN) text change and schedule a flush."
  (when (cmacs-dbus-events--interesting-p (current-buffer))
    (let* ((buf (current-buffer))
           (cell (gethash buf cmacs-dbus-events--text-pending)))
      (if cell
          (setf (nth 0 cell) (min (nth 0 cell) beg)
                (nth 1 cell) (max (nth 1 cell) end)
                (nth 2 cell) (+ (nth 2 cell) len))
        (puthash buf (list beg end len) cmacs-dbus-events--text-pending))
      (unless cmacs-dbus-events--text-timer
        (setq cmacs-dbus-events--text-timer
              (run-with-idle-timer 0.2 nil #'cmacs-dbus-events--flush-text))))))

(defun cmacs-dbus-events--flush-text ()
  "Emit one text/changed per buffer that changed since the last flush."
  (setq cmacs-dbus-events--text-timer nil)
  (let ((pending cmacs-dbus-events--text-pending))
    (setq cmacs-dbus-events--text-pending (make-hash-table :test 'eq))
    (maphash
     (lambda (buf cell)
       (when (buffer-live-p buf)
         (let ((name (buffer-name buf)))
           (cmacs-dbus-events--emit
            "text" "changed" name
            (list :name name :beg (nth 0 cell) :end (nth 1 cell)
                  :length (nth 2 cell))
            "TextChanged"
            (list name (nth 0 cell) (nth 1 cell) (nth 2 cell))))))
     pending)))

;;; Subsystem bridges (opt-in)

(defun cmacs-dbus-events--on-gsurf-load (buffer event)
  "Bridge gsurf load-state EVENT on BUFFER."
  (let ((name (buffer-name buffer)) (state (format "%s" event)))
    (cmacs-dbus-events--emit "gsurf" "load-changed" name
                             (list :buffer name :state state)
                             "BrowserLoadChanged" (list name state))))

(defun cmacs-dbus-events--on-gsurf-uri (buffer uri)
  "Bridge gsurf URI change on BUFFER."
  (let ((name (buffer-name buffer)))
    (cmacs-dbus-events--emit "gsurf" "uri-changed" name
                             (list :buffer name :uri uri)
                             "BrowserUriChanged" (list name uri))))

(defun cmacs-dbus-events--on-gsurf-title (buffer title)
  "Bridge gsurf TITLE change on BUFFER."
  (let ((name (buffer-name buffer)))
    (cmacs-dbus-events--emit "gsurf" "title-changed" name
                             (list :buffer name :title title)
                             "BrowserTitleChanged" (list name title))))

(defun cmacs-dbus-events--on-gsurf-crash (buffer)
  "Bridge a gsurf web-process crash on BUFFER."
  (let ((name (buffer-name buffer)))
    (cmacs-dbus-events--emit "gsurf" "crashed" name (list :buffer name)
                             "BrowserCrashed" (list name))))

(defun cmacs-dbus-events--on-ai-message (_channel room-id msg)
  "Bridge an inbound libreclaw message MSG in ROOM-ID."
  (let ((sender (or (plist-get msg :sender-name) ""))
        (text (or (plist-get msg :body) "")))
    (cmacs-dbus-events--emit "ai" "message" room-id
                             (list :room room-id :sender sender :text text)
                             "AiMessage" (list room-id sender text))))

(defun cmacs-dbus-events--on-patch-applied (plist)
  "Bridge a C hot-patch described by PLIST."
  (let ((fn (format "%s" (or (plist-get plist :symbol) ""))))
    (cmacs-dbus-events--emit "cintrospect" "patch-applied" fn
                             (list :function fn :kind
                                   (format "%s" (plist-get plist :kind)))
                             "PatchApplied" (list fn))))

;;; Install / uninstall

(defun cmacs-dbus-events--install ()
  "Add the hooks for every enabled category."
  (let ((cats cmacs-dbus-events-categories))
    (setq cmacs-dbus-events--known-buffers (buffer-list)
          cmacs-dbus-events--last-buffer (current-buffer)
          cmacs-dbus-events--last-project (cmacs-dbus-events--project-root))
    (clrhash cmacs-dbus-events--frame-focus)
    (when (or (memq 'file cats) (memq 'buffer cats) (memq 'project cats))
      (add-hook 'find-file-hook #'cmacs-dbus-events--on-find-file)
      (add-hook 'after-save-hook #'cmacs-dbus-events--on-after-save)
      (add-hook 'first-change-hook #'cmacs-dbus-events--on-first-change)
      (add-hook 'kill-buffer-hook #'cmacs-dbus-events--on-kill-buffer)
      (add-hook 'buffer-list-update-hook #'cmacs-dbus-events--schedule-scan))
    (when (or (memq 'window cats) (memq 'frame cats))
      (add-hook 'window-selection-change-functions
                #'cmacs-dbus-events--on-window-selection)
      (add-hook 'after-make-frame-functions #'cmacs-dbus-events--on-make-frame)
      (add-hook 'delete-frame-functions #'cmacs-dbus-events--on-delete-frame)
      (add-function :after after-focus-change-function
                    #'cmacs-dbus-events--on-focus-change))
    (when (memq 'editor cats)
      (add-hook 'kill-emacs-hook #'cmacs-dbus-events--on-kill-emacs)
      ;; The events surface coming up stands in for editor startup.
      (cmacs-dbus-events--emit "editor" "startup" "" nil "EditorStartup" nil))
    (when (memq 'text cats)
      (add-hook 'after-change-functions #'cmacs-dbus-events--on-change))
    (when (memq 'gsurf cats)
      (when (boundp 'cmacs-gsurf-load-changed-functions)
        (add-hook 'cmacs-gsurf-load-changed-functions
                  #'cmacs-dbus-events--on-gsurf-load))
      (when (boundp 'cmacs-gsurf-uri-changed-functions)
        (add-hook 'cmacs-gsurf-uri-changed-functions
                  #'cmacs-dbus-events--on-gsurf-uri))
      (when (boundp 'cmacs-gsurf-title-changed-functions)
        (add-hook 'cmacs-gsurf-title-changed-functions
                  #'cmacs-dbus-events--on-gsurf-title))
      (when (boundp 'cmacs-gsurf-crashed-functions)
        (add-hook 'cmacs-gsurf-crashed-functions
                  #'cmacs-dbus-events--on-gsurf-crash)))
    (when (and (memq 'ai cats) (boundp 'cmacs-libreclaw-message-hook))
      (add-hook 'cmacs-libreclaw-message-hook
                #'cmacs-dbus-events--on-ai-message))
    (when (and (memq 'cintrospect cats)
               (boundp 'cmacs-cintrospect-patch-applied-hook))
      (add-hook 'cmacs-cintrospect-patch-applied-hook
                #'cmacs-dbus-events--on-patch-applied))))

(defun cmacs-dbus-events--uninstall ()
  "Remove every hook this module may have installed."
  (remove-hook 'find-file-hook #'cmacs-dbus-events--on-find-file)
  (remove-hook 'after-save-hook #'cmacs-dbus-events--on-after-save)
  (remove-hook 'first-change-hook #'cmacs-dbus-events--on-first-change)
  (remove-hook 'kill-buffer-hook #'cmacs-dbus-events--on-kill-buffer)
  (remove-hook 'buffer-list-update-hook #'cmacs-dbus-events--schedule-scan)
  (remove-hook 'window-selection-change-functions
               #'cmacs-dbus-events--on-window-selection)
  (remove-hook 'after-make-frame-functions #'cmacs-dbus-events--on-make-frame)
  (remove-hook 'delete-frame-functions #'cmacs-dbus-events--on-delete-frame)
  (remove-function after-focus-change-function
                   #'cmacs-dbus-events--on-focus-change)
  (remove-hook 'kill-emacs-hook #'cmacs-dbus-events--on-kill-emacs)
  (remove-hook 'after-change-functions #'cmacs-dbus-events--on-change)
  (when (boundp 'cmacs-gsurf-load-changed-functions)
    (remove-hook 'cmacs-gsurf-load-changed-functions
                 #'cmacs-dbus-events--on-gsurf-load))
  (when (boundp 'cmacs-gsurf-uri-changed-functions)
    (remove-hook 'cmacs-gsurf-uri-changed-functions
                 #'cmacs-dbus-events--on-gsurf-uri))
  (when (boundp 'cmacs-gsurf-title-changed-functions)
    (remove-hook 'cmacs-gsurf-title-changed-functions
                 #'cmacs-dbus-events--on-gsurf-title))
  (when (boundp 'cmacs-gsurf-crashed-functions)
    (remove-hook 'cmacs-gsurf-crashed-functions
                 #'cmacs-dbus-events--on-gsurf-crash))
  (when (boundp 'cmacs-libreclaw-message-hook)
    (remove-hook 'cmacs-libreclaw-message-hook
                 #'cmacs-dbus-events--on-ai-message))
  (when (boundp 'cmacs-cintrospect-patch-applied-hook)
    (remove-hook 'cmacs-cintrospect-patch-applied-hook
                 #'cmacs-dbus-events--on-patch-applied))
  (when cmacs-dbus-events--scan-timer
    (cancel-timer cmacs-dbus-events--scan-timer)
    (setq cmacs-dbus-events--scan-timer nil))
  (when cmacs-dbus-events--text-timer
    (cancel-timer cmacs-dbus-events--text-timer)
    (setq cmacs-dbus-events--text-timer nil)))

;;;###autoload
(define-minor-mode cmacs-dbus-events-mode
  "Broadcast cmacs editor events as D-Bus signals.
External clients subscribe to `org.cmacs.Editor1.Events' on the session
bus to observe editor activity.  See `cmacs-dbus-events-categories' to
choose which event families are emitted.  Enabled by default; emission
is a no-op whenever the D-Bus service is not running."
  :global t :group 'cmacs-dbus-events
  (if cmacs-dbus-events-mode
      (cmacs-dbus-events--install)
    (cmacs-dbus-events--uninstall)))

;;;###autoload
(add-hook 'emacs-startup-hook (lambda () (cmacs-dbus-events-mode 1)))

(provide 'cmacs-dbus-events)
;;; cmacs-dbus-events.el ends here
