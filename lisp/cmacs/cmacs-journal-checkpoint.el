;;; cmacs-journal-checkpoint.el --- Periodic records of what was open and where  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The journal's spans say what had the FOCUS.  They do not say what
;; else was open, or how it was laid out, and "put me back where I was"
;; (cmacs-journal-restore.el) needs both.  A checkpoint is that missing
;; half: every so often, and only when something changed, one journal
;; event of kind `checkpoint' whose `detail' is a JSON document holding
;;
;;   frames    per Emacs frame, the window tree as DATA: splits, their
;;             proportions, and for each window the buffer's name, file,
;;             mode and line.  Never a window-configuration object.
;;   buffers   the file-visiting buffers that were open, shown or not.
;;   urls      the pages open in gsurf buffers.
;;   clients   gowl's windows: app id, title, tags, monitor, floating,
;;             geometry, pid, and the command line when /proc has it.
;;   monitors  per output, the tags in view and the layout symbol.
;;
;; Why a journal event and not a sibling file: `cmacs-journal-forget',
;; `cmacs-journal-retention-days', the 0700/0600 modes, the atomic
;; rewrite, the agent gate and the LQL `activity' source all operate on
;; the day files.  A checkpoint that lives there is forgotten, pruned,
;; protected and queryable by the code that already does those things;
;; a second file would need a second copy of each, and the copy that
;; lags is the one that keeps what you asked to have deleted.
;;
;; The journal's three rules hold here, in this form:
;;
;;   1. Nothing here runs on a hook.  A checkpoint is taken from a
;;      timer, which may read /proc and count lines; the gowl DEFUNs it
;;      calls are the list/info ones, which take the gowl lock
;;      themselves and return.  The timer function never signals.
;;
;;   2. Filters run before the queue.  A checkpoint is many events'
;;      worth of names, so every buffer, URL, window and monitor entry
;;      is turned into the event the journal would have recorded for it
;;      and handed to `cmacs-journal-filter-apply' ON ITS OWN.  An
;;      excluded entry is not blanked, it is absent: its window leaves
;;      the tree, and nothing counts it or says a rule matched.  The
;;      finished event goes through the filters once more as a whole.
;;
;;   3. Fail closed.  Checkpoints are taken only while
;;      `cmacs-journal-recording-p', which is nil whenever the rule set
;;      is unusable; and `cmacs-journal-filter-apply' answers nil for
;;      every entry in that state, so a checkpoint built anyway would be
;;      empty and is not written.
;;
;; OFF by default, like the journal: `cmacs-journal-checkpoint-mode'
;; starts the timer, and even then nothing is written unless
;; `cmacs-journal-mode' is on and recording.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-journal)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-list-clients "cmacs-gowl.c" ())
(declare-function gowl-list-monitors "cmacs-gowl.c" ())
(declare-function gowl-client-info "cmacs-gowl.c" (client))
(declare-function gowl-client-pid "cmacs-gowl.c" (client))
(declare-function gowl-focused-client "cmacs-gowl.c" ())
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))

(defcustom cmacs-journal-checkpoint-interval 120
  "Seconds between looks at the arrangement.
A look that finds nothing changed writes nothing."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-checkpoint-max-age 3600
  "Write a checkpoint at least this often while recording, in seconds.
Unchanged arrangements are otherwise never written again, and the one
checkpoint describing a long quiet afternoon would be deleted by
`cmacs-journal-retention-days' while it was still the current one."
  :type 'number
  :group 'cmacs-journal)

(defcustom cmacs-journal-checkpoint-max-buffers 100
  "At most this many file-visiting buffers are listed in a checkpoint.
The most recently selected come first."
  :type 'integer
  :group 'cmacs-journal)

(defcustom cmacs-journal-checkpoint-line-limit 2000000
  "Buffers larger than this many characters get no line number.
Counting lines is a walk over the buffer, and a checkpoint is taken on
the thread that, under gowl, is also the desktop.  Such a buffer is
still recorded; a restore just reopens it at its start."
  :type 'integer
  :group 'cmacs-journal)

(defcustom cmacs-journal-checkpoint-command-lines t
  "Non-nil records each window's command line, read from /proc.
That is what lets a restore start the program again.  The command line
goes through the filters as the entry's `detail' field, and a command
naming a URL the filters exclude is withheld whole.  Set this to nil to
record no command lines at all; a restore can then only move windows
that are already running."
  :type 'boolean
  :group 'cmacs-journal)

(defconst cmacs-journal-checkpoint-version 1
  "Version of the checkpoint document, its `v' member.")

;;;; State

(defvar cmacs-journal-checkpoint--timer nil
  "The timer `cmacs-journal-checkpoint-mode' started.")

(defvar cmacs-journal-checkpoint--last-hash nil
  "Hash of the arrangement in the last checkpoint written.")

(defvar cmacs-journal-checkpoint--last-time nil
  "When the last checkpoint was written, in seconds.")

(defvar cmacs-journal-checkpoint--commands (make-hash-table :test #'eql)
  "PID -> command string (or `none'), so /proc is read once per process.")

;;;; Emacs: buffers and the window tree

(defun cmacs-journal-checkpoint--buffer-entry (buffer &optional position)
  "The checkpoint entry for BUFFER, or nil when the filters exclude it.

BUFFER becomes the raw event the journal would record for it being
selected, that event goes through the filters, and the entry is built
from what comes back -- so a rule that excludes, drops, replaces or
hashes a buffer in the journal does exactly that here.  POSITION is the
buffer position whose line is recorded (default the buffer's point)."
  (when (buffer-live-p buffer)
    (let* ((raw (cmacs-journal--buffer-event buffer nil))
           (event (and raw (cmacs-journal-filter-apply raw))))
      (when event
        (let ((entry nil))
          (dolist (field '(:buffer :file :mode :url :title :project))
            (let ((value (plist-get event field)))
              (when (and (stringp value) (not (string-empty-p value)))
                (setq entry (plist-put entry field value)))))
          ;; A container is browsing state worth putting back; the
          ;; `para:' detail of a notes file is not.
          (let ((detail (plist-get event :detail)))
            (when (and (stringp detail)
                       (string-prefix-p "container:" detail))
              (setq entry (plist-put entry :container
                                     (substring detail 10)))))
          (when entry
            (if (> (buffer-size buffer) cmacs-journal-checkpoint-line-limit)
                entry
              (plist-put entry :line
                         (with-current-buffer buffer
                           (line-number-at-pos (or position (point))
                                               t))))))))))

(defun cmacs-journal-checkpoint--window (window selected fraction)
  "The tree under WINDOW as data, or nil when all of it is excluded.

A live window is a leaf: its buffer's entry plus FRACTION, the share of
its parent it takes.  An internal window is a split with children.  A
leaf the filters exclude is REMOVED, and a split left with one child is
replaced by that child: the tree a restore sees is the tree of what may
be remembered, with no hole where something else was.  SELECTED is the
frame's selected window."
  (if (window-live-p window)
      (let ((entry (cmacs-journal-checkpoint--buffer-entry
                    (window-buffer window) (window-point window))))
        (when entry
          (setq entry (plist-put entry :size fraction))
          (when (eq window selected)
            (setq entry (plist-put entry :selected t)))
          entry))
    (let* ((horizontal (window-combination-p window t))
           (children nil)
           (child (window-child window)))
      (while child
        (let ((node (cmacs-journal-checkpoint--window
                     child selected
                     (window-normal-size child horizontal))))
          (when node (push node children)))
        (setq child (window-next-sibling child)))
      (setq children (nreverse children))
      (cond
       ((null children) nil)
       ((null (cdr children))
        ;; The only survivor takes its parent's place and share.
        (plist-put (car children) :size fraction))
       (t
        ;; What is left shares the whole of the split again.
        (let ((total (apply #'+ (mapcar (lambda (c) (plist-get c :size))
                                        children))))
          (when (> total 0)
            (dolist (c children)
              (plist-put c :size (/ (plist-get c :size) (float total))))))
        (list :split (if horizontal "h" "v")
              :size fraction
              :children children))))))

(defun cmacs-journal-checkpoint--frames ()
  "The window trees of the visible frames, the selected frame first."
  (let ((frames nil))
    (dolist (frame (cons (selected-frame)
                         (remq (selected-frame) (frame-list))))
      (when (and (frame-live-p frame)
                 (frame-visible-p frame)
                 ;; A child frame or a minibuffer-only frame is a popup,
                 ;; not an arrangement.
                 (null (frame-parameter frame 'parent-frame))
                 (not (eq (frame-parameter frame 'minibuffer) 'only)))
        (let ((tree (cmacs-journal-checkpoint--window
                     (frame-root-window frame)
                     (frame-selected-window frame) 1.0)))
          (when tree
            (push (append (list :tree tree)
                          (and (eq frame (selected-frame))
                               (list :selected t)))
                  frames)))))
    (nreverse frames)))

(defun cmacs-journal-checkpoint--buffers ()
  "Entries for the open file buffers and gsurf pages: (FILES . URLS)."
  (let ((files nil) (urls nil) (count 0))
    (dolist (buffer (buffer-list))
      (when (and (buffer-live-p buffer)
                 (not (string-prefix-p " " (buffer-name buffer))))
        (let ((gsurf (eq (buffer-local-value 'major-mode buffer)
                         'cmacs-gsurf-mode))
              (file (buffer-local-value 'buffer-file-name buffer)))
          (when (or gsurf (and file (< count cmacs-journal-checkpoint-max-buffers)))
            (let ((entry (cmacs-journal-checkpoint--buffer-entry buffer)))
              (cond
               ((null entry))
               ((plist-get entry :url) (push entry urls))
               ((plist-get entry :file)
                (cl-incf count)
                (push entry files))))))))
    (cons (nreverse files) (nreverse urls))))

;;;; The compositor

(defun cmacs-journal-checkpoint--read-cmdline (pid)
  "The argument list of process PID from /proc, or nil."
  (let ((file (format "/proc/%d/cmdline" pid)))
    (when (file-readable-p file)
      (ignore-errors
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (let ((args (split-string (buffer-string) "\0" t)))
            (mapcar (lambda (a) (decode-coding-string a 'utf-8 t)) args)))))))

(defun cmacs-journal-checkpoint--url-arg-ok-p (arg)
  "Non-nil unless ARG is a URL the filters would not record.
A browser started as `firefox https://...' carries a page in its
command line, where no `url' rule would otherwise look."
  (or (not (string-match-p "\\`[a-z][a-z0-9+.-]*://" arg))
      (let ((kept (cmacs-journal-filter-apply (list :kind 'url :url arg))))
        (and kept (equal (plist-get kept :url) arg)))))

(defun cmacs-journal-checkpoint--command (pid app)
  "A command that would start the program of PID again, or nil.

The arguments /proc gives, shell-quoted so `gowl-spawn' reads back the
same list.  A Flatpak's process sees its own /app, which is no command
on the host, so for those the answer is `flatpak run APP' when APP is an
application id.  Cached per PID: a process's command line is read once."
  (when (and cmacs-journal-checkpoint-command-lines
             (integerp pid) (> pid 0))
    (let ((hit (gethash pid cmacs-journal-checkpoint--commands)))
      (unless hit
        (let* ((args (cmacs-journal-checkpoint--read-cmdline pid))
               (command
                (cond
                 ((null args) nil)
                 ((string-prefix-p "/app/" (car args))
                  (and (stringp app)
                       (string-match-p "\\`[A-Za-z0-9_-]+\\(?:\\.[A-Za-z0-9_-]+\\)+\\'"
                                       app)
                       (concat "flatpak run " app)))
                 ((cl-every #'cmacs-journal-checkpoint--url-arg-ok-p args)
                  (mapconcat #'shell-quote-argument args " ")))))
          (setq hit (or command 'none))
          (puthash pid hit cmacs-journal-checkpoint--commands)))
      (and (stringp hit) hit))))

(defun cmacs-journal-checkpoint--monitor-of (geometry monitors)
  "The name of the monitor in MONITORS holding the centre of GEOMETRY.
MONITORS is a list of (NAME X Y W H)."
  (pcase geometry
    (`(,x ,y ,w ,h)
     (let ((cx (+ x (/ w 2))) (cy (+ y (/ h 2))))
       (car (cl-find-if
             (lambda (m)
               (pcase-let ((`(,_ ,mx ,my ,mw ,mh) m))
                 (and (integerp mx) (>= cx mx) (< cx (+ mx mw))
                      (>= cy my) (< cy (+ my mh)))))
             monitors))))))

(defun cmacs-journal-checkpoint--monitors ()
  "Read gowl's monitors: (ENTRIES . GEOMETRIES).
ENTRIES are the filtered checkpoint entries; GEOMETRIES is a list of
\(NAME X Y W H) for placing clients, never written anywhere."
  (let* ((focused (alist-get 'name (ignore-errors (gowl-monitor-info))))
         (entries nil) (geometries nil))
    (dolist (monitor (ignore-errors (gowl-list-monitors)))
      (let* ((info (ignore-errors (gowl-monitor-info monitor)))
             (name (alist-get 'name info)))
        (when (and info (stringp name))
          (push (cons name (alist-get 'geometry info)) geometries)
          (let ((event (cmacs-journal-filter-apply
                        (list :kind 'checkpoint
                              :monitor name
                              :tags (cmacs-journal--tag-list
                                     (alist-get 'tags info))))))
            (when (and event (stringp (plist-get event :monitor)))
              (push (append
                     (list :name (plist-get event :monitor)
                           :tags (plist-get event :tags))
                     (let ((layout (alist-get 'layout-symbol info)))
                       (and (stringp layout) (list :layout layout)))
                     (and (equal name focused) (list :focused t)))
                    entries))))))
    (cons (nreverse entries) (nreverse geometries))))

(defun cmacs-journal-checkpoint--clients (geometries)
  "The filtered entries for gowl's windows.  GEOMETRIES places them.
This Emacs's own frames are left out: they are the `frames' member."
  (let* ((focused (ignore-errors (gowl-focused-client)))
         (focused-id (and focused
                          (alist-get 'id (ignore-errors
                                           (gowl-client-info focused)))))
         (live-pids nil)
         (entries nil))
    (dolist (client (ignore-errors (gowl-list-clients)))
      ;; A client can vanish between the list and the read; that one is
      ;; simply not in this checkpoint.
      (let* ((info (ignore-errors (gowl-client-info client)))
             (pid (and info (ignore-errors (gowl-client-pid client)))))
        (when (and info (not (and (integerp pid) (= pid (emacs-pid)))))
          (when (integerp pid) (push pid live-pids))
          (let* ((geometry (alist-get 'geometry info))
                 (app (alist-get 'app-id info))
                 (raw (list :kind 'focus
                            :app app
                            :title (alist-get 'title info)
                            :pid (and (integerp pid) (> pid 0) pid)
                            :tags (cmacs-journal--tag-list
                                   (alist-get 'tags info))
                            :monitor (cmacs-journal-checkpoint--monitor-of
                                      geometry geometries)
                            :detail (cmacs-journal-checkpoint--command
                                     pid app)))
                 (event (cmacs-journal-filter-apply raw)))
            (when event
              (let ((entry nil))
                (dolist (pair '((:app . :app) (:title . :title)
                                (:pid . :pid) (:tags . :tags)
                                (:monitor . :monitor) (:detail . :command)))
                  (let ((value (plist-get event (car pair))))
                    (when (and value (not (equal value "")))
                      (setq entry (plist-put entry (cdr pair) value)))))
                (when entry
                  (when (alist-get 'floating info)
                    (setq entry (plist-put entry :floating t))
                    ;; Only a floating window has a place of its own;
                    ;; a tiled one is wherever the layout puts it.
                    (when (and (= (length geometry) 4)
                               (cl-every #'integerp geometry))
                      (setq entry (plist-put entry :geometry geometry))))
                  (when (alist-get 'embedded info)
                    (setq entry (plist-put entry :embedded t)))
                  (when (and focused-id
                             (equal (alist-get 'id info) focused-id))
                    (setq entry (plist-put entry :focused t)))
                  (push entry entries))))))))
    ;; Forget the command lines of processes that are gone, so a reused
    ;; pid is read afresh and the table stays the size of the desktop.
    (maphash (lambda (pid _)
               (unless (memq pid live-pids)
                 (remhash pid cmacs-journal-checkpoint--commands)))
             cmacs-journal-checkpoint--commands)
    (nreverse entries)))

;;;; The document

(defun cmacs-journal-checkpoint-snapshot ()
  "The arrangement right now as a filtered plist, or nil for nothing.

Members: :frames :buffers :urls :clients :monitors, each a list of
entries that have individually been through the journal's filters.
Nil when the rule set is unusable or everything was excluded.  Reads
the compositor through its list and info DEFUNs only."
  (when (cmacs-journal-filter-ready-p)
    (let* ((frames (cmacs-journal-checkpoint--frames))
           (open (cmacs-journal-checkpoint--buffers))
           (gowl (and (fboundp 'gowl-running-p)
                      (fboundp 'gowl-list-clients)
                      (ignore-errors (gowl-running-p))))
           (monitors (and gowl (cmacs-journal-checkpoint--monitors)))
           (clients (and gowl (cmacs-journal-checkpoint--clients
                               (cdr monitors)))))
      (when (or frames (car open) (cdr open) clients)
        (list :frames frames
              :buffers (car open)
              :urls (cdr open)
              :clients clients
              :monitors (car monitors))))))

(defun cmacs-journal-checkpoint--json (value)
  "VALUE (plists, lists, strings, numbers, t) as something to serialize.
A plist becomes an object without its nil members, any other list an
array, t stays true."
  (cond
   ((and (consp value) (keywordp (car value)))
    (let ((object nil))
      (cl-loop for (key member) on value by #'cddr
               when member
               do (push (cons (intern (substring (symbol-name key) 1))
                              (cmacs-journal-checkpoint--json member))
                        object))
      (or (nreverse object) (make-hash-table))))
   ((listp value) (vconcat (mapcar #'cmacs-journal-checkpoint--json value)))
   ((stringp value) (substring-no-properties value))
   (t value)))

(defun cmacs-journal-checkpoint-encode (snapshot)
  "SNAPSHOT as the JSON text of a checkpoint event's `detail'."
  (json-serialize
   (cmacs-journal-checkpoint--json
    (append (list :v cmacs-journal-checkpoint-version) snapshot))))

(defun cmacs-journal-checkpoint-decode (event)
  "The snapshot plist a `checkpoint' EVENT holds, or nil.
Nil for an event of another kind, for a `detail' a filter rewrote into
something that is no longer the document, and for a version this code
does not know."
  (when (eq (plist-get event :kind) 'checkpoint)
    (let ((detail (plist-get event :detail)))
      (when (stringp detail)
        (condition-case nil
            (let ((snapshot (json-parse-string
                             detail :object-type 'plist :array-type 'list
                             :null-object nil :false-object nil)))
              (and (listp snapshot)
                   (eql (plist-get snapshot :v)
                        cmacs-journal-checkpoint-version)
                   snapshot))
          (error nil))))))

(defun cmacs-journal-checkpoint--strip-lines (value)
  "VALUE without any :line or :title member, for comparing arrangements.
Point moving is not the arrangement changing, and neither is a terminal
retitling itself after every command: a checkpoint for each would be a
record of activity, which is the spans' job, at many times the size.
The titles are still IN a checkpoint; they just do not cause one."
  (cond
   ((and (consp value) (keywordp (car value)))
    (cl-loop for (key member) on value by #'cddr
             unless (memq key '(:line :title))
             nconc (list key (cmacs-journal-checkpoint--strip-lines member))))
   ((consp value) (mapcar #'cmacs-journal-checkpoint--strip-lines value))
   (t value)))

;;;; Taking one

;;;###autoload
(defun cmacs-journal-checkpoint-take (&optional force)
  "Record the current arrangement in the journal, if it changed.

Nothing is written when the journal is not recording, when the filters
leave nothing, or when the arrangement is the one last written and that
was less than `cmacs-journal-checkpoint-max-age' ago -- unless FORCE
\(interactively, always).  Returns the queued event, or nil."
  (interactive (list t))
  (let ((event nil))
    (when (cmacs-journal-recording-p)
      (let* ((now (cmacs-journal--now))
             (snapshot (cmacs-journal-checkpoint-snapshot))
             (hash (and snapshot
                        (secure-hash
                         'sha1
                         (prin1-to-string
                          (cmacs-journal-checkpoint--strip-lines snapshot))))))
        (when (and snapshot
                   (or force
                       (not (equal hash cmacs-journal-checkpoint--last-hash))
                       (null cmacs-journal-checkpoint--last-time)
                       (>= (- now cmacs-journal-checkpoint--last-time)
                           cmacs-journal-checkpoint-max-age)))
          (let* ((focused (cl-find-if (lambda (m) (plist-get m :focused))
                                      (plist-get snapshot :monitors)))
                 ;; Once more, as a whole: a rule on `kind' can turn
                 ;; checkpoints off, and a rule on `detail' that matches
                 ;; anywhere in the document drops all of it.
                 (kept (cmacs-journal-filter-apply
                        (list :kind 'checkpoint
                              :tags (plist-get focused :tags)
                              :monitor (plist-get focused :name)
                              :detail (cmacs-journal-checkpoint-encode
                                       snapshot)))))
            (when (and kept (stringp (plist-get kept :detail)))
              (setq event (append (list :time now :end now :duration 0)
                                  kept))
              (push event cmacs-journal--queue)
              (cl-incf cmacs-journal--generation)
              (setq cmacs-journal-checkpoint--last-hash hash
                    cmacs-journal-checkpoint--last-time now))))))
    (when (called-interactively-p 'interactive)
      (message (if event "cmacs-journal: checkpoint taken"
                 "cmacs-journal: no checkpoint (not recording, or nothing the filters allow)")))
    event))

(defun cmacs-journal-checkpoint--tick ()
  "Timer: take a checkpoint if one is due.  Never signals."
  (condition-case nil
      (cmacs-journal-checkpoint-take)
    (error nil)))

;;;###autoload
(define-minor-mode cmacs-journal-checkpoint-mode
  "Record, every so often, what is open and how it is arranged.

A checkpoint is a journal event of kind `checkpoint': the Emacs window
tree with each window's buffer, file and line, the open file buffers,
the pages in gsurf buffers, and under gowl every window's app id, title,
tags, monitor and command line.  `cmacs-journal-restore' rebuilds a
moment from the nearest one.

Off by default.  Turning it on starts a timer and nothing else: a
checkpoint is written only while `cmacs-journal-mode' is on and
recording, only when the arrangement changed, and only after every
entry in it has been through the journal's filters on its own.
`cmacs-journal-forget' and `cmacs-journal-retention-days' delete
checkpoints like any other event."
  :global t
  :group 'cmacs-journal
  (when cmacs-journal-checkpoint--timer
    (cancel-timer cmacs-journal-checkpoint--timer)
    (setq cmacs-journal-checkpoint--timer nil))
  ;; Either way the next one written is a fresh look.
  (setq cmacs-journal-checkpoint--last-hash nil
        cmacs-journal-checkpoint--last-time nil)
  (clrhash cmacs-journal-checkpoint--commands)
  (when cmacs-journal-checkpoint-mode
    (setq cmacs-journal-checkpoint--timer
          (run-with-timer (min 10 cmacs-journal-checkpoint-interval)
                          cmacs-journal-checkpoint-interval
                          #'cmacs-journal-checkpoint--tick))))

(provide 'cmacs-journal-checkpoint)

;;; cmacs-journal-checkpoint.el ends here
