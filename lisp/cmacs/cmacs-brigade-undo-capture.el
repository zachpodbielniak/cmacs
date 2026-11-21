;;; cmacs-brigade-undo-capture.el --- What each tool's undo captures  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The capture functions the shipped tool families name in their
;; `:undo' declarations, e.g.
;;
;;   (cmacs-brigade-deftool gowl-set-client-geometry ...
;;     :undo 'cmacs-brigade-undo-capture-gowl-geometry
;;     ...)
;;
;; Each is called BEFORE the tool's handler with exactly the handler's
;; arguments and returns an undo record (cmacs-brigade-undo.el has the
;; format), nil when the call will change nothing, or
;; (irreversible REASON).  They live here, not in the family files, so a
;; family declares its undo in one line and the logic is in one place;
;; the first line of each docstring is what the generated undo table
;; (`cmacs-brigade-undo-decision-table') says the undo does.
;;
;; A capture that signals makes the call "irreversible: the state before
;; could not be captured" rather than failing the call: the log is a
;; record, never a gate.  Most signal exactly when the handler is about
;; to fail anyway (no such buffer, no such window).
;;
;; Everything that reaches the compositor goes through the gowl DEFUNs,
;; which take the gowl lock themselves, and runs on the thread the tool
;; itself runs on.  Nothing here waits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-brigade-undo)

(declare-function cmacs-project-tools--resolve "cmacs-project-tools" (path))
(declare-function cmacs-gowl-tools--find-or-signal "cmacs-gowl-tools"
                  (pattern by))
(declare-function gowl-list-clients "cmacs-gowl.c" ())
(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-client-pid "cmacs-gowl.c" (client))
(declare-function gowl-focused-client "cmacs-gowl.c" ())
(declare-function gowl-focus-client "cmacs-gowl.c" (client))
(declare-function gowl-close-client "cmacs-gowl.c" (client))
(declare-function gowl-client-set-geometry "cmacs-gowl.c" (client x y w h))
(declare-function gowl-set-client-floating "cmacs-gowl.c" (client floating))
(declare-function gowl-arrange "cmacs-gowl.c" ())
(declare-function gowl-get-layout "cmacs-gowl.c" (&optional monitor))
(declare-function gowl-set-layout "cmacs-gowl.c" (layout &optional monitor))
(declare-function gowl-workspace-current "cmacs-gowl.c" ())
(declare-function gowl-workspace-switch "cmacs-gowl.c" (id))
(declare-function gowl-list-monitors "cmacs-gowl.c" ())
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function gowl-set-monitor-transform "cmacs-gowl.c"
                  (transform &optional monitor))
(declare-function cmacs-context-current "cmacs-context" ())
(declare-function cmacs-context-switch "cmacs-context"
                  (name &optional show-plan))
(declare-function cmacs-screensaver--wallpaper-active-p
                  "cmacs-screensaver-defuns.c" ())
(declare-function cmacs-screensaver-set-wallpaper "cmacs-screensaver" (name))
(declare-function cmacs-screensaver-stop-wallpaper "cmacs-screensaver" ())
(declare-function cmacs-screensaver-status "cmacs-screensaver" ())
(declare-function cmacs-screensaver-pause "cmacs-screensaver" ())
(declare-function cmacs-screensaver-resume "cmacs-screensaver" ())
(declare-function cmacs-screensaver-set-fps "cmacs-screensaver" (fps))
(declare-function cmacs-gsurf-tools--target "cmacs-gsurf-tools"
                  (name &optional allow-excluded))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-load-uri "cmacs-gsurf-defuns.c" (buffer uri))
(declare-function cmacs-gsurf-get-zoom "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-set-zoom "cmacs-gsurf-defuns.c" (buffer level))
(declare-function cmacs-gsurf-modules-list "cmacs-gsurf-defuns.c" ())
(declare-function cmacs-gsurf-module-set-enabled "cmacs-gsurf-defuns.c"
                  (name enabled))
(declare-function cmacs-imgedit-undo "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-redo "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-imgedit-remove-layer "cmacs-imgedit-defuns.c"
                  (handle index))
(declare-function cmacs-imgedit-n-layers "cmacs-imgedit-defuns.c" (handle))
(declare-function cmacs-podomation-running-p "cmacs-podomation.c" ())
(declare-function cmacs-podomation-start "cmacs-podomation.c" ())
(declare-function cmacs-podomation-stop "cmacs-podomation.c" ())

(defvar cmacs-context--approved)
(defvar cmacs-screensaver-wallpaper-config)
(defvar cmacs-screensaver-default-config)


;;;; Buffers and edits

(defun cmacs-brigade-undo-capture-nothing (&rest _)
  "Nothing to undo: the call leaves no state behind.
For a tool that is :destructive for what it can reach rather than for
what it changes -- reading the screen, re-spawning a renderer."
  nil)

;; Read by `cmacs-brigade-undo-decision-table'.
(put 'cmacs-brigade-undo-capture-nothing 'cmacs-brigade-undo-kind 'nothing)

(defun cmacs-brigade-undo-capture-buffer-text (buffer &rest _)
  "Restore the buffer's text (its own undo list, else a snapshot).
For every tool whose first argument names the buffer it edits."
  (cmacs-brigade-undo-buffer-record buffer))

(defun cmacs-brigade-undo-capture-create-buffer (name content)
  "Kill the created buffer if unchanged since (or restore an existing one's text).
`create_buffer' inserts CONTENT into a buffer NAME that already exists,
so then it is an edit; with no CONTENT it changes nothing."
  (cond
   ((null (get-buffer name)) (cmacs-brigade-undo-created-buffer-record name))
   (content (cmacs-brigade-undo-buffer-record name))))

(defun cmacs-brigade-undo-capture-kill-buffer (buffer)
  "Bring the buffer back: its file, or its text, mode and point."
  (cmacs-brigade-undo-killed-buffer-record buffer))

(defun cmacs-brigade-undo-capture-switch-to-buffer (buffer)
  "Put the window layout back, and kill the buffer if the call created it."
  (cmacs-brigade-undo-compose
   (cmacs-brigade-undo-window-record)
   (and (stringp buffer) (not (string-empty-p buffer))
        (cmacs-brigade-undo-created-buffer-record buffer))))

(defun cmacs-brigade-undo-capture-save-buffer (buffer)
  "Put the file's previous contents back on disk; the buffer keeps its text.
The buffer is left modified (its text is no longer what is on disk) and
its visited-file time is updated, so nothing asks about a changed file."
  (let* ((b (get-buffer buffer))
         (file (and b (buffer-file-name b))))
    (when file
      (let ((rec (cmacs-brigade-undo-file-record file 'no-revert)))
        (if (cmacs-brigade-undo--irreversible-p rec)
            rec
          (append
           (list :summary (format "put %s on disk back as it was before the \
save (buffer %s keeps its text, unsaved)"
                                  (abbreviate-file-name file) (buffer-name b))
                 :inverse
                 (lambda (r)
                   (cmacs-brigade-undo--file-inverse r)
                   (when (and (buffer-live-p b)
                              (equal (buffer-file-name b) (plist-get r :file)))
                     (with-current-buffer b
                       (set-visited-file-modtime)
                       (set-buffer-modified-p t)))))
           rec))))))

(defun cmacs-brigade-undo-capture-find-file (path)
  "Kill the buffer the call opened if unchanged since; put the windows back."
  (let* ((file (and (stringp path) (expand-file-name path)))
         (visited (and file (find-buffer-visiting file))))
    (cmacs-brigade-undo-compose
     (cmacs-brigade-undo-window-record)
     (and file (not visited)
          (list :kind 'buffer-visited
                :file file
                :object (cons 'file-buffer file)
                :summary (format "kill the buffer visiting %s"
                                 (abbreviate-file-name file))
                :after (lambda (rec _result)
                         (when-let* ((b (find-buffer-visiting
                                         (plist-get rec :file))))
                           (append (list :buffer b
                                         :tick (buffer-chars-modified-tick b))
                                   rec)))
                :stale (lambda (rec)
                         (let ((b (plist-get rec :buffer)))
                           (cond
                            ((not (buffer-live-p b))
                             "the buffer was already killed")
                            ((/= (buffer-chars-modified-tick b)
                                 (plist-get rec :tick))
                             (format "buffer %s was changed since"
                                     (buffer-name b))))))
                :inverse (lambda (rec)
                           (let ((inhibit-interaction t))
                             (kill-buffer (plist-get rec :buffer)))))))))

(defun cmacs-brigade-undo-capture-goto-line (buffer &rest _)
  "Move point back where it was, unless it moved again since."
  (cmacs-brigade-undo-point-record buffer))

(defun cmacs-brigade-undo-capture-windows (&rest _)
  "Put the window layout back, unless it was changed again since."
  (cmacs-brigade-undo-window-record))


;;;; Files

(defun cmacs-brigade-undo-capture-project-write (path &rest _)
  "Put the file's previous contents back (or trash a file the call created)."
  (require 'cmacs-project-tools)
  (cmacs-brigade-undo-file-record (cdr (cmacs-project-tools--resolve path))))

(defun cmacs-brigade-undo-capture-file-arg (path)
  "Put the file at PATH back as it was (or trash it if the call created it)."
  (when (and (stringp path) (not (string-empty-p path)))
    (cmacs-brigade-undo-file-record path)))


;;;; gowl

(defconst cmacs-brigade-undo-gowl-layout-names
  '(("[]=" . "tile") ("[M]" . "monocle") ("><>" . "float"))
  "Layout symbols `gowl-get-layout' reports, and the names that set them.")

(defun cmacs-brigade-undo--gowl-client (id)
  "The live gowl client with id ID, or nil."
  (cl-find-if (lambda (c) (eql id (alist-get 'id (gowl-client-info c))))
              (gowl-list-clients)))

(defun cmacs-brigade-undo--gowl-client-or-stale (id)
  "The live gowl client with id ID; refuse the undo if it is gone."
  (or (cmacs-brigade-undo--gowl-client id)
      (cmacs-brigade-undo--stale "window %d was closed since" id)))

(defun cmacs-brigade-undo-capture-gowl-focus (_pattern _by)
  "Give focus back to the window that had it."
  (when-let* ((prev (gowl-focused-client)))
    (list :kind 'gowl-focus
          :prev (alist-get 'id (gowl-client-info prev))
          :object '(gowl-focus)
          :summary "give focus back to the window that had it"
          :after (lambda (rec _result)
                   (let ((now (gowl-focused-client)))
                     (append (list :now (and now (alist-get
                                                  'id (gowl-client-info now))))
                             rec)))
          :stale (lambda (rec)
                   (let ((now (gowl-focused-client)))
                     (unless (eql (and now (alist-get 'id (gowl-client-info
                                                           now)))
                                  (plist-get rec :now))
                       "focus moved to another window since")))
          :inverse (lambda (rec)
                     (gowl-focus-client
                      (cmacs-brigade-undo--gowl-client-or-stale
                       (plist-get rec :prev)))))))

(defun cmacs-brigade-undo-capture-gowl-geometry (pattern by x y width height)
  "Put the window back where it was (its float state and geometry)."
  ;; Only a gowl tool reaches this, and that tool's family is loaded by
  ;; then; required here rather than at the top because the gowl family
  ;; exists only in a build with the compositor.
  (require 'cmacs-gowl-tools)
  (let* ((client (cmacs-gowl-tools--find-or-signal pattern by))
         (info (gowl-client-info client))
         (id (alist-get 'id info)))
    (list :kind 'gowl-geometry
          :id id
          :geometry (alist-get 'geometry info)
          :floating (and (alist-get 'floating info) t)
          :requested (list x y width height)
          :object (cons 'gowl-client id)
          :summary (format "put window %d back at %S" id
                           (alist-get 'geometry info))
          :after (lambda (rec _result)
                   (let ((c (cmacs-brigade-undo--gowl-client (plist-get rec :id))))
                     (append (list :left (and c (alist-get
                                                 'geometry (gowl-client-info c))))
                             rec)))
          :stale (lambda (rec)
                   (let ((c (cmacs-brigade-undo--gowl-client (plist-get rec :id))))
                     (cond
                      ((null c) (format "window %d was closed since"
                                        (plist-get rec :id)))
                      ;; Only a window that floated before has a place
                      ;; of its own to compare; a tiled one is moved by
                      ;; every re-arrange, user or not.
                      ((and (plist-get rec :floating)
                            (not (member (alist-get 'geometry
                                                    (gowl-client-info c))
                                         (list (plist-get rec :left)
                                               (plist-get rec :requested)))))
                       (format "window %d was moved or resized since"
                               (plist-get rec :id))))))
          :inverse (lambda (rec)
                     (let* ((c (cmacs-brigade-undo--gowl-client-or-stale
                                (plist-get rec :id)))
                            (was-floating (plist-get rec :floating))
                            (g (plist-get rec :geometry)))
                       (unless (eq was-floating
                                   (and (alist-get 'floating
                                                   (gowl-client-info c))
                                        t))
                         (gowl-set-client-floating c was-floating))
                       ;; A tiled window's place is the layout's: back in
                       ;; the tile layer, a re-arrange puts it where the
                       ;; layout says (a resize does not take a window out
                       ;; of the tiling, so the layout is what moves it).
                       (if was-floating
                           (apply #'gowl-client-set-geometry c g)
                         (gowl-arrange)))))))

(defun cmacs-brigade-undo-capture-gowl-spawn (_command)
  "Close the windows of the spawned process, if they are still its."
  (list :kind 'gowl-spawn
        :object nil
        :summary "close the windows of the process the call started"
        :after (lambda (rec result)
                 (let ((pid (and (stringp result) (string-to-number result))))
                   (and pid (> pid 0)
                        (append (list :pid pid
                                      :summary
                                      (format "close the windows of process %d"
                                              pid))
                                rec))))
        :inverse (lambda (rec)
                   (let* ((pid (plist-get rec :pid))
                          (mine (cl-remove-if-not
                                 (lambda (c)
                                   (eql pid (ignore-errors (gowl-client-pid c))))
                                 (gowl-list-clients))))
                     (unless mine
                       (cmacs-brigade-undo--stale
                        "no window of process %d is open (it never mapped \
one, or it was closed)" pid))
                     (mapc #'gowl-close-client mine)))))

(defun cmacs-brigade-undo-capture-gowl-layout (_layout)
  "Set the focused monitor's previous layout again."
  (let* ((sym (gowl-get-layout nil))
         (name (cdr (assoc sym cmacs-brigade-undo-gowl-layout-names))))
    (if (null name)
        (list 'irreversible
              (format "the layout before (%s) is not one set_layout can name"
                      sym))
      (list :kind 'gowl-layout
            :name name
            :object '(gowl-layout)
            :summary (format "set the %s layout again" name)
            :after (lambda (rec _result)
                     (append (list :left (gowl-get-layout nil)) rec))
            :stale (lambda (rec)
                     (unless (equal (gowl-get-layout nil) (plist-get rec :left))
                       "the layout was changed since (or another monitor \
has focus)"))
            :inverse (lambda (rec)
                       (unless (gowl-set-layout (plist-get rec :name))
                         (error "gowl refused the layout %s"
                                (plist-get rec :name))))))))

(defun cmacs-brigade-undo-capture-gowl-workspace (_id)
  "Switch back to the workspace that was current."
  (let ((prev (and (fboundp 'gowl-workspace-current) (gowl-workspace-current))))
    (if (null prev)
        '(irreversible "no workspace was current before the switch")
      (list :kind 'gowl-workspace
            :prev prev
            :object '(gowl-workspace)
            :summary (format "switch back to workspace %s" prev)
            :after (lambda (rec _result)
                     (append (list :left (gowl-workspace-current)) rec))
            :stale (lambda (rec)
                     (unless (equal (gowl-workspace-current)
                                    (plist-get rec :left))
                       "the workspace was switched again since"))
            :inverse (lambda (rec)
                       (gowl-workspace-switch (plist-get rec :prev)))))))

(defun cmacs-brigade-undo-capture-gowl-transform (name _transform)
  "Set the monitor's previous transform again."
  (let ((monitor (cl-find-if (lambda (m)
                               (equal (alist-get 'name (gowl-monitor-info m))
                                      name))
                             (gowl-list-monitors))))
    (when monitor
      (list :kind 'gowl-transform
            :name name
            :prev (or (alist-get 'transform (gowl-monitor-info monitor)) 0)
            :object (cons 'gowl-monitor name)
            :summary (format "set %s's transform back" name)
            :inverse (lambda (rec)
                       (let ((m (cl-find-if
                                 (lambda (m)
                                   (equal (alist-get 'name (gowl-monitor-info m))
                                          (plist-get rec :name)))
                                 (gowl-list-monitors))))
                         (unless m
                           (cmacs-brigade-undo--stale "monitor %s is gone"
                                                      (plist-get rec :name)))
                         (gowl-set-monitor-transform (plist-get rec :prev)
                                                     m)))))))


;;;; Contexts

(defun cmacs-brigade-undo-capture-context-switch (_name)
  "Switch back to the context that was current (nothing it opened is closed)."
  (require 'cmacs-context)
  (let ((prev (cmacs-context-current)))
    (if (null prev)
        '(irreversible "no context was current before the switch")
      (list :kind 'context
            :prev prev
            :object '(context)
            :summary (format "switch back to the context %s (what the \
switch opened stays open)" prev)
            :after (lambda (rec _result)
                     (append (list :left (cmacs-context-current)) rec))
            :stale (lambda (rec)
                     (unless (equal (cmacs-context-current)
                                    (plist-get rec :left))
                       "the context was switched again since"))
            :inverse (lambda (rec)
                       ;; The person asking for the undo is the yes.
                       (let ((cmacs-context--approved t))
                         (cmacs-context-switch (plist-get rec :prev))))))))


;;;; Screensaver

(defvar cmacs-brigade-undo--wallpaper nil
  "The config of the animated wallpaper a tool call last started, or nil.
Only calls through the tools are seen, which is why an animated
wallpaper started some other way makes `set_wallpaper' irreversible.")

(defun cmacs-brigade-undo--wallpaper-active-p ()
  "Non-nil when an animated wallpaper is running."
  (and (fboundp 'cmacs-screensaver--wallpaper-active-p)
       (cmacs-screensaver--wallpaper-active-p)))

(defun cmacs-brigade-undo--wallpaper-restore (rec)
  "Put back the wallpaper state RECORD (REC) captured."
  (require 'cmacs-screensaver)
  (if (plist-get rec :was-active)
      (progn
        (cmacs-screensaver-set-wallpaper (plist-get rec :prev))
        (setq cmacs-brigade-undo--wallpaper (plist-get rec :prev)))
    (cmacs-screensaver-stop-wallpaper)
    (setq cmacs-brigade-undo--wallpaper nil)))

(defun cmacs-brigade-undo--wallpaper-record (applied)
  "Record the wallpaper state before a call that leaves APPLIED running.
APPLIED is a config symbol, or nil for a call that stops the wallpaper."
  (let ((active (cmacs-brigade-undo--wallpaper-active-p)))
    (cond
     ((and (not active) (null applied)) nil)
     ((and active (null cmacs-brigade-undo--wallpaper))
      '(irreversible "an animated wallpaper was running whose config is not \
known (it was not started by a tool)"))
     (t
      (list :kind 'wallpaper
            :was-active active
            :prev cmacs-brigade-undo--wallpaper
            :object '(wallpaper)
            :summary (if active
                         (format "set the %s wallpaper again"
                                 cmacs-brigade-undo--wallpaper)
                       "stop the animated wallpaper")
            :after (lambda (rec _result)
                     (setq cmacs-brigade-undo--wallpaper applied)
                     rec)
            :inverse #'cmacs-brigade-undo--wallpaper-restore)))))

(defun cmacs-brigade-undo-capture-wallpaper-set (config)
  "Set the animated wallpaper that ran before again (or stop it)."
  (require 'cmacs-screensaver)
  (cmacs-brigade-undo--wallpaper-record
   (if (and (stringp config) (not (string-empty-p config)))
       (intern config)
     (or cmacs-screensaver-wallpaper-config cmacs-screensaver-default-config))))

(defun cmacs-brigade-undo-capture-wallpaper-stop ()
  "Start the animated wallpaper that was stopped again."
  (cmacs-brigade-undo--wallpaper-record nil))

(defun cmacs-brigade-undo-capture-screensaver-pause ()
  "Resume rendering, if it was running before the pause."
  (require 'cmacs-screensaver)
  (unless (plist-get (cmacs-screensaver-status) :paused)
    (list :kind 'screensaver-pause
          :object '(screensaver-paused)
          :summary "resume the screensaver rendering"
          :inverse (lambda (_rec) (cmacs-screensaver-resume)))))

(defun cmacs-brigade-undo-capture-screensaver-resume ()
  "Pause rendering again, if it was paused before."
  (require 'cmacs-screensaver)
  (when (plist-get (cmacs-screensaver-status) :paused)
    (list :kind 'screensaver-resume
          :object '(screensaver-paused)
          :summary "pause the screensaver rendering again"
          :inverse (lambda (_rec) (cmacs-screensaver-pause)))))

(defun cmacs-brigade-undo-capture-screensaver-fps (_fps)
  "Set the previous frame rate again."
  (require 'cmacs-screensaver)
  (let ((prev (plist-get (cmacs-screensaver-status) :fps)))
    (when (integerp prev)
      (list :kind 'screensaver-fps
            :prev prev
            :object '(screensaver-fps)
            :summary (format "set the frame rate back to %d" prev)
            :inverse (lambda (rec)
                       (cmacs-screensaver-set-fps (plist-get rec :prev)))))))


;;;; gsurf

(defun cmacs-brigade-undo-capture-gsurf-open (_url)
  "Close the browser view the call opened."
  (list :kind 'gsurf-open
        :summary "close the gsurf view the call opened"
        :after (lambda (rec result)
                 (let ((b (and (stringp result) (get-buffer result))))
                   (and b (append (list :buffer b
                                        :object (cons 'gsurf b)
                                        :summary
                                        (format "close the gsurf view %s"
                                                (buffer-name b)))
                                  rec))))
        :stale (lambda (rec)
                 (unless (buffer-live-p (plist-get rec :buffer))
                   "the view was already closed"))
        :inverse (lambda (rec)
                   (let ((inhibit-interaction t))
                     (kill-buffer (plist-get rec :buffer))))))

(defun cmacs-brigade-undo-capture-gsurf-navigate (_url buffer)
  "Load the page the view showed before."
  (require 'cmacs-gsurf-tools)
  (let* ((b (cmacs-gsurf-tools--target buffer t))
         (prev (ignore-errors (cmacs-gsurf-get-uri b))))
    (if (or (null prev) (string-empty-p prev) (equal prev "about:blank"))
        '(irreversible "the view had no page before")
      (list :kind 'gsurf-navigate
            :buffer b
            :prev prev
            :object (cons 'gsurf b)
            :summary "load the page the view showed before"
            :stale (lambda (rec)
                     (unless (buffer-live-p (plist-get rec :buffer))
                       "the gsurf view was closed since"))
            ;; The URL came from the view, so it needs none of the
            ;; normalising `gsurf_navigate' does to what a caller types.
            :inverse (lambda (rec)
                       (cmacs-gsurf-load-uri (plist-get rec :buffer)
                                             (plist-get rec :prev)))))))

(defun cmacs-brigade-undo-capture-gsurf-zoom (_level buffer)
  "Set the view's previous zoom level again."
  (require 'cmacs-gsurf-tools)
  (let* ((b (cmacs-gsurf-tools--target buffer))
         (prev (cmacs-gsurf-get-zoom b)))
    (list :kind 'gsurf-zoom
          :buffer b
          :prev prev
          :object (cons 'gsurf-zoom b)
          :summary (format "set the zoom back to %s" prev)
          :after (lambda (rec _result)
                   (append (list :left (cmacs-gsurf-get-zoom
                                        (plist-get rec :buffer)))
                           rec))
          :stale (lambda (rec)
                   (let ((b (plist-get rec :buffer)))
                     (cond ((not (buffer-live-p b))
                            "the gsurf view was closed since")
                           ((not (equal (cmacs-gsurf-get-zoom b)
                                        (plist-get rec :left)))
                            "the zoom was changed since"))))
          :inverse (lambda (rec)
                     (cmacs-gsurf-set-zoom (plist-get rec :buffer)
                                           (plist-get rec :prev))))))

(defun cmacs-brigade-undo--gsurf-module-enabled (name)
  "Whether the gsurf module NAME is enabled: t, :false, or nil if unknown."
  (let ((json (cmacs-gsurf-modules-list)))
    (when json
      (let ((row (cl-find name (json-parse-string json :object-type 'alist
                                                  :array-type 'list
                                                  :false-object :false)
                          :key (lambda (r) (alist-get 'name r))
                          :test #'equal)))
        (and row (if (eq (alist-get 'enabled row) t) t :false))))))

(defun cmacs-brigade-undo-capture-gsurf-module (name enabled)
  "Set the module back to enabled or disabled, as it was."
  (let ((prev (cmacs-brigade-undo--gsurf-module-enabled name)))
    (cond
     ((null prev) nil)
     ((eq (eq prev t) (and enabled t)) nil)
     (t
      (list :kind 'gsurf-module
            :name name
            :prev (eq prev t)
            :object (cons 'gsurf-module name)
            :summary (format "%s the %s module again"
                             (if (eq prev t) "enable" "disable") name)
            :stale (lambda (rec)
                     (let ((now (cmacs-brigade-undo--gsurf-module-enabled
                                 (plist-get rec :name))))
                       (when (eq (eq now t) (plist-get rec :prev))
                         "the module was toggled again since")))
            :inverse (lambda (rec)
                       (cmacs-gsurf-module-set-enabled
                        (plist-get rec :name) (plist-get rec :prev))))))))


;;;; Image editor
;;
;; imgedit keeps its own undo stack per document; each of these tools
;; pushes exactly one step, so the inverse is one step of the
;; document's own undo.  That stack does not say who pushed a step, so
;; the ordering rule (a newer logged edit of the same document must be
;; undone first) is the staleness check here; an edit made in
;; `cmacs-imgedit-mode' meanwhile is not seen.

(defun cmacs-brigade-undo-capture-imgedit-edit (handle &rest _)
  "One step of the document's own undo."
  (when (integerp handle)
    (list :kind 'imgedit
          :handle handle
          :object (cons 'imgedit handle)
          :summary (format "undo one step of image document %d" handle)
          :inverse (lambda (rec)
                     (unless (cmacs-imgedit-undo (plist-get rec :handle))
                       (cmacs-brigade-undo--stale
                        "image document %d has nothing left to undo"
                        (plist-get rec :handle)))))))

(defun cmacs-brigade-undo-capture-imgedit-add-layer (handle &rest _)
  "Remove the layer the call added."
  (when (integerp handle)
    (list :kind 'imgedit-layer
          :handle handle
          :object (cons 'imgedit handle)
          :summary "remove the layer the call added"
          :after (lambda (rec result)
                   (and (stringp result)
                        (string-match "\\`layer \\([0-9]+\\)" result)
                        (append (list :index (string-to-number
                                              (match-string 1 result))
                                      :layers (cmacs-imgedit-n-layers
                                               (plist-get rec :handle)))
                                rec)))
          :stale (lambda (rec)
                   (unless (eql (cmacs-imgedit-n-layers (plist-get rec :handle))
                                (plist-get rec :layers))
                     "the document's layers changed since"))
          :inverse (lambda (rec)
                     (unless (cmacs-imgedit-remove-layer
                              (plist-get rec :handle) (plist-get rec :index))
                       (error "the layer could not be removed"))))))

(defun cmacs-brigade-undo-capture-imgedit-undo (handle)
  "Redo the step the call undid."
  (when (integerp handle)
    (list :kind 'imgedit-undo
          :handle handle
          :object (cons 'imgedit handle)
          :summary (format "redo the step undone in image document %d" handle)
          ;; "nothing" means the stack was empty: nothing to take back.
          :after (lambda (rec result) (and (equal result "undone") rec))
          :inverse (lambda (rec)
                     (unless (cmacs-imgedit-redo (plist-get rec :handle))
                       (cmacs-brigade-undo--stale
                        "image document %d has nothing to redo"
                        (plist-get rec :handle)))))))

(defun cmacs-brigade-undo-capture-imgedit-save (_handle path)
  "Put the file the call saved over back as it was (or trash a new one)."
  (cmacs-brigade-undo-capture-file-arg path))


;;;; Database export

(defun cmacs-brigade-undo-capture-db-export (_connection _sql _format path)
  "Put the file the export wrote back as it was (or trash a new one)."
  (cmacs-brigade-undo-capture-file-arg path))


;;;; podomation

(defun cmacs-brigade-undo-capture-podomation-control (action _pod _event)
  "Stop or start the engine again, as it was; a run cannot be undone."
  (pcase action
    ((or "start" "stop")
     (let ((was (and (cmacs-podomation-running-p) t)))
       (unless (eq was (equal action "start"))
         (list :kind 'podomation
               :was was
               :object '(podomation-engine)
               :summary (if was "start the engine again"
                          "stop the engine again")
               :inverse (lambda (rec)
                          (if (plist-get rec :was)
                              (cmacs-podomation-start)
                            (cmacs-podomation-stop)))))))
    ("status" nil)
    (_ '(irreversible "a pod's rules have run; what they did is the pod's \
own"))))

(provide 'cmacs-brigade-undo-capture)

;;; cmacs-brigade-undo-capture.el ends here
