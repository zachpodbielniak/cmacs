;;; cmacs-context.el --- Named arrangements you switch between  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; `cmacs-journal-restore' answers "put me back where I was at TIME".
;; This answers "switch me to WORK": a context is a named arrangement --
;; the Emacs window tree, the open files and pages, and under gowl the
;; applications, their tags and each monitor's view and layout -- that
;; you save, switch to, update and list.
;;
;;   M-x cmacs-context-save RET work RET     capture what is up now
;;   M-x cmacs-context-switch RET research   go somewhere else
;;   M-x cmacs-context-list                  all of them, with keys
;;
;; It is not a second implementation of anything.  An arrangement is a
;; checkpoint snapshot (`cmacs-journal-checkpoint-snapshot', the format
;; the journal's checkpoints use), a switch is a restore plan built from
;; that snapshot (`cmacs-journal-restore-plan-from-snapshot') and carried
;; out by the restore's executor (`cmacs-journal-restore-execute-plan').
;; The journal itself is not involved: a context is saved and switched
;; to with `cmacs-journal-mode' off, and saving writes nothing to the
;; journal.
;;
;; Two kinds of context, and how they combine:
;;
;;   SAVED     captured from the live arrangement, one JSON file per
;;             context under `cmacs-context-directory' (0700/0600).
;;   DECLARED  written in your init with `cmacs-context-define' (or in a
;;             YAML file named in `cmacs-context-files'): files, pages,
;;             applications, a layout, a directory, environment
;;             variables, and :setup/:teardown functions.
;;
;;   A context can be both.  Then the SAVED ARRANGEMENT WINS, category
;;   by category (buffers, pages, applications, layout): a category the
;;   saved state holds replaces the declaration's, it is not merged with
;;   it.  Everything that is not arrangement -- :directory, :project,
;;   :env, :label, :setup, :teardown -- comes from the declaration
;;   whenever it is declared there.  `cmacs-context-delete' removes the
;;   saved state and leaves the declaration, which is how you get back
;;   to what your init says.
;;
;; What a switch does, and never does:
;;
;;   * It ADDS and ARRANGES.  Files and pages are opened, applications
;;     that are not running are started on their tags, running ones are
;;     moved there, the Emacs windows are rebuilt, tags are viewed.
;;     Nothing is closed: no buffer is killed and no application's
;;     window is ever closed.  Windows that belong to neither context
;;     stay where they are, unless `cmacs-context-park-others' names a
;;     tag to move them to.
;;   * The context you leave is saved into itself first
;;     (`cmacs-context-auto-save-on-leave'), so contexts drift with you
;;     the way workspaces do.
;;   * It is immediate.  The plan is shown and confirmed only before the
;;     first switch to a context and when more than
;;     `cmacs-context-confirm-launches' applications would be started.
;;   * It does not block.  Each step runs from a timer; a second switch
;;     while one is in flight cancels the first between steps, and a
;;     context that was never fully arrived at is not saved on leaving.
;;
;; The same filters that decide what the journal may remember decide
;; what a saved context holds, because the snapshot is the checkpoint's:
;; a buffer, page or window the rules exclude is not in the file, and
;; when the rule set cannot be loaded nothing is saved at all.
;;
;; Environment variables (:env) are for the applications a context
;; starts.  They come from your Elisp, are never captured from running
;; programs and never written to a saved state file -- and they are
;; visible in the plan buffer and in the process list like any command
;; line.  They are not a place for secrets.
;;
;; Without the compositor (a pgtk or tty Emacs) a context is its Emacs
;; half: buffers, pages and the window tree.  Every gowl call here is
;; behind `cmacs-context--gowl-p'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)

(declare-function gowl-running-p "cmacs-gowl.c" ())
(declare-function gowl-add-keybind "cmacs-gowl.c" (key action &optional arg desc))
(declare-function gowl-remove-keybind "cmacs-gowl.c" (key))
(declare-function gowl-run-command "cmacs-gowl.c" (command))
(declare-function gowl-set-tags "cmacs-gowl.c" (client tags))
(declare-function gowl-find-client "cmacs-gowl.c" (pattern &optional by))
(declare-function gowl-focus-client "cmacs-gowl.c" (client))
(declare-function gowl-monitor-info "cmacs-gowl.c" (&optional monitor))
(declare-function cmacs-yaml-parse-file "cmacs-yaml.c" (file))
(declare-function cmacs-journal-recording-p "cmacs-journal" ())
(declare-function cmacs-journal-agent-context-p "cmacs-journal" ())
(declare-function cmacs-journal--record-point "cmacs-journal"
                  (raw &optional time duration))
(declare-function cmacs-journal--tag-list "cmacs-journal" (mask))
(declare-function cmacs-journal-filter-ready-p "cmacs-journal-filter" ())
(declare-function cmacs-journal-filter-error "cmacs-journal-filter" ())
(declare-function cmacs-journal-filters-reload "cmacs-journal-filter" ())
(declare-function cmacs-journal-checkpoint-snapshot "cmacs-journal-checkpoint" ())
(declare-function cmacs-journal-checkpoint-encode "cmacs-journal-checkpoint"
                  (snapshot))
(declare-function cmacs-journal-restore-plan-from-snapshot
                  "cmacs-journal-restore" (snapshot &rest props))
(declare-function cmacs-journal-restore-execute-plan "cmacs-journal-restore"
                  (plan &rest options))
(declare-function cmacs-journal-restore-cancel "cmacs-journal-restore" (plan))
(declare-function cmacs-journal-restore-show-plan "cmacs-journal-restore" (plan))
(declare-function cmacs-journal-restore--running "cmacs-journal-restore" ())
(declare-function cmacs-journal-restore--match "cmacs-journal-restore"
                  (entries running))
(declare-function cmacs-gowl-bar-push "cmacs-gowl-bar-ai" (widget alist))
(declare-function cmacs-gowl-bar-slot-set "cmacs-gowl-bar-slots" (id &rest plist))
(declare-function cmacs-gowl-bar-slot-remove "cmacs-gowl-bar-slots" (id))
(declare-function cmacs-voice-define-command "cmacs-voice-commands"
                  (regexp function &optional doc append &rest props))
(declare-function cmacs-voice-confirm "cmacs-voice-commands" (prompt action))
(declare-function persp-switch "ext:persp-mode" (name &optional frame window norecord))
(declare-function project-root "project" (project))

;; Special variables of other files that are let-bound or read here.
(defvar cmacs-journal-restore-layout-names)
(defvar cmacs-journal-checkpoint-version)
(defvar cmacs-journal-filter--loaded)
(defvar cmacs-voice-commands)
(defvar cmacs-voice-confirm-destructive)
(defvar compile-command)

(defgroup cmacs-context nil
  "Named, saved arrangements of buffers, pages and applications."
  :group 'cmacs
  :prefix "cmacs-context-")

(defcustom cmacs-context-directory
  (expand-file-name "cmacs/contexts"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "Where saved contexts are kept, one NAME.json each.
Created with mode 0700; the files are 0600."
  :type 'directory
  :group 'cmacs-context)

(defcustom cmacs-context-files nil
  "YAML files declaring contexts, read when contexts are first asked for.
Each holds a `contexts:' mapping of NAME to the keys of
`cmacs-context-define' that are data: files, urls, apps, layout, tags,
project, directory, label, env.  Functions (:setup, :teardown) can only
be given in Elisp.  Read through `cmacs-yaml-parse-file'; ignored, with
a warning, in a build without it."
  :type '(repeat file)
  :group 'cmacs-context)

(defcustom cmacs-context-auto-save-on-leave t
  "Non-nil saves the arrangement you leave into the context you leave.
That is what makes a context follow you: open a file while in `work',
switch away, and `work' has that file when you come back.  With nil a
context changes only when you say so (`cmacs-context-update').  A
declaration's :auto-save key overrides this for that context.  A context
whose switch was cancelled before it finished is never saved on leaving:
it would be saved half-arrived."
  :type 'boolean
  :group 'cmacs-context)

(defcustom cmacs-context-park-others nil
  "A tag number to move other windows to on a switch, or nil to leave them.
\"Other\" means a running window that is not part of the context being
switched to and sits on one of that context's tags.  Such a window is
never closed either way; with a number here it is moved to that tag so
the context's tags show only the context.  It is not moved back."
  :type '(choice (const :tag "Leave them where they are" nil)
                 (integer :tag "Parking tag"))
  :group 'cmacs-context)

(defcustom cmacs-context-confirm-first-switch t
  "Non-nil shows the plan and asks before the first switch to a context."
  :type 'boolean
  :group 'cmacs-context)

(defcustom cmacs-context-confirm-launches 3
  "Show the plan and ask when a switch would start more applications than this.
nil never asks on that account."
  :type '(choice (const :tag "Never ask" nil) integer)
  :group 'cmacs-context)

(defcustom cmacs-context-save-include '(buffers urls apps layout)
  "What a save captures: any of `buffers', `urls', `apps' and `layout'.
`buffers' is the Emacs window tree and the open files, `urls' the pages
in gsurf buffers, `apps' the compositor's windows, `layout' each
monitor's tags in view and layout.  \\[universal-argument] \\[cmacs-context-save] asks."
  :type '(set (const buffers) (const urls) (const apps) (const layout))
  :group 'cmacs-context)

(defcustom cmacs-context-set-default-directory t
  "Non-nil makes a context's directory the default `default-directory'.
New buffers that visit no file then start there.  `cmacs-context-directory-now'
returns it for anything else, and `cmacs-context-project-find-file' and
`cmacs-context-compile' run there whatever buffer is current."
  :type 'boolean
  :group 'cmacs-context)

(defcustom cmacs-context-use-perspectives t
  "Non-nil maps a context to the persp-mode perspective of the same name.
Only when `persp-mode' is on; otherwise this does nothing.  The
perspective is switched to (and made, if new) before the context's
buffers are opened, so they land in it."
  :type 'boolean
  :group 'cmacs-context)

(defcustom cmacs-context-key "Super+Ctrl+c"
  "The gowl key that opens the context switcher, or nil for none.
Bound by `cmacs-context-setup', and by nothing else."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-context)

(defcustom cmacs-context-mode-line-format " [%s]"
  "How the current context's name is shown in the mode line, or nil for not.
A `format' string taking the name."
  :type '(choice (const :tag "Not shown" nil) string)
  :group 'cmacs-context)

(defcustom cmacs-context-bar-widget "label"
  "The gowl bar widget whose text is set to the current context, or nil.
Used only until the bar has named slots: when `cmacs-gowl-bar-slot-set'
exists the name goes to the slot `cmacs-context-bar-slot' instead.  The
shipped `label' widget is one item; if something else drives it (an LQL
watch's :bar), set this to nil."
  :type '(choice (const :tag "Do not push to a widget" nil) string)
  :group 'cmacs-context)

(defcustom cmacs-context-bar-slot "context"
  "The bar slot the current context's name is put in, when slots exist."
  :type 'string
  :group 'cmacs-context)

(defcustom cmacs-context-after-switch-functions nil
  "Functions called after a switch has finished: (NAME PREVIOUS).
PREVIOUS is the name of the context left, or nil.  Each is called under
`condition-case'; one that fails is reported and the rest still run."
  :type 'hook
  :group 'cmacs-context)

(defconst cmacs-context-version 1
  "Version of a saved context file, its `v' member.")

(defconst cmacs-context--categories
  '((buffers :frames :buffers) (urls :urls) (apps :clients)
    (layout :monitors))
  "What `cmacs-context-save-include' names, as snapshot members.")

(defconst cmacs-context--define-keys
  '(:files :urls :apps :layout :tags :project :directory :label :env
    :setup :teardown :auto-save :source)
  "The keys `cmacs-context-define' accepts.")

;;;; State

(defvar cmacs-context--declared nil
  "Declared contexts: an alist of (NAME . PLIST), newest first.")

(defvar cmacs-context--current nil
  "The name of the context you are in, or nil.")

(defvar cmacs-context--settled nil
  "Non-nil once the switch to the current context has finished.
Only a settled context is saved, and torn down, on leaving.")

(defvar cmacs-context--switch nil
  "The switch last started: a plist of :name and :plan, or nil.")

(defvar cmacs-context--approved nil
  "Non-nil while a caller the person has approved is switching.
Bound by the `context_switch' tool, whose confirmation is the approval.")

(defvar cmacs-context--original-directory 'unset
  "The default `default-directory' before any context set one.")

(defvar cmacs-context--files-loaded nil
  "Non-nil once `cmacs-context-files' have been read.")

(defvar cmacs-context-integrations nil
  "Optional integrations: an alist of (SYMBOL . PLIST).
See `cmacs-context-register-integration'.")

;;;; Small things

(defun cmacs-context--gowl-p ()
  "Non-nil when this Emacs is running the gowl compositor."
  (and (fboundp 'gowl-running-p)
       (ignore-errors (gowl-running-p))))

(defun cmacs-context--agent-p ()
  "Non-nil when the caller is an agent or a remote client."
  (and (require 'cmacs-journal nil t)
       (cmacs-journal-agent-context-p)))

(defun cmacs-context--check-name (name)
  "Return NAME if it can name a context; signal a `user-error' if not.
A name is one line of at most 64 characters with no slash, not starting
with a dot: it becomes a file name."
  (unless (and (stringp name)
               (string-match-p "\\`[^./[:cntrl:]][^/[:cntrl:]]\\{0,63\\}\\'"
                               name)
               (not (string-match-p "\\`[ \t]\\|[ \t]\\'" name)))
    (user-error "Not a usable context name: %S" name))
  name)

(defun cmacs-context--file (name)
  "The file a context called NAME is saved in."
  (expand-file-name (concat (url-hexify-string name) ".json")
                    cmacs-context-directory))

(defun cmacs-context--ensure-directory ()
  "Create `cmacs-context-directory' with mode 0700 and return it."
  (let ((dir (file-name-as-directory
              (expand-file-name cmacs-context-directory))))
    (unless (file-directory-p dir)
      (with-file-modes #o700 (make-directory dir t)))
    (ignore-errors (set-file-modes dir #o700))
    dir))

(defun cmacs-context--plist-without (plist keys)
  "PLIST without the members named in KEYS."
  (cl-loop for (key value) on plist by #'cddr
           unless (memq key keys) nconc (list key value)))

(defun cmacs-context--ago (time)
  "How long ago TIME (seconds) was, in a few characters."
  (if (not (numberp time))
      "never"
    (let ((s (max 0 (- (float-time) time))))
      (cond ((< s 90) "just now")
            ((< s 5400) (format "%dm ago" (round (/ s 60))))
            ((< s 129600) (format "%dh ago" (round (/ s 3600))))
            (t (format "%dd ago" (round (/ s 86400))))))))

;;;; Saved state: the files

(defun cmacs-context--read (name)
  "The saved state of the context NAME as a plist, or nil.
Members: :name :saved :used :directory :project :include (a list of
strings) and :snapshot, a checkpoint snapshot.  Nil for a file that is
not JSON, or is of a version this code does not know."
  (let ((file (cmacs-context--file name)))
    (when (file-readable-p file)
      (condition-case nil
          (let ((state (json-parse-string
                        (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string))
                        :object-type 'plist :array-type 'list
                        :null-object nil :false-object nil)))
            (and (listp state)
                 (eql (plist-get state :v) cmacs-context-version)
                 state))
        (error nil)))))

(defun cmacs-context--encode (state)
  "STATE, a saved-state plist, as the JSON text of its file."
  (let ((object (list (cons 'v cmacs-context-version))))
    (dolist (key '(:name :saved :used :directory :project))
      (let ((value (plist-get state key)))
        (when value
          (push (cons (intern (substring (symbol-name key) 1))
                      (if (stringp value)
                          (substring-no-properties value)
                        value))
                object))))
    (when (plist-member state :include)
      (push (cons 'include
                  (vconcat (mapcar (lambda (c) (format "%s" c))
                                   (plist-get state :include))))
            object))
    (when (plist-member state :snapshot)
      (require 'cmacs-journal-checkpoint)
      ;; The checkpoint encoder is the one writer of the snapshot
      ;; format; its text is read back only to nest it in this object.
      (push (cons 'snapshot
                  (json-parse-string
                   (cmacs-journal-checkpoint-encode
                    (cmacs-context--plist-without
                     (plist-get state :snapshot) '(:v)))
                   :object-type 'alist))
            object))
    (json-serialize (nreverse object))))

(defun cmacs-context--write (name state)
  "Write STATE as the saved state of the context NAME, atomically."
  (let* ((dir (cmacs-context--ensure-directory))
         (file (cmacs-context--file name))
         ;; `make-temp-file' makes it 0600; the rename keeps that.
         (temp (make-temp-file (expand-file-name ".context-" dir)))
         (coding-system-for-write 'utf-8-unix))
    (condition-case err
        (progn
          (with-temp-file temp
            (insert (cmacs-context--encode (plist-put state :name name)))
            ;; Someone will open this file one day; one member per line
            ;; costs nothing.  A pretty-printer that fails leaves the
            ;; compact text, which is just as valid.
            (ignore-errors (json-pretty-print-buffer))
            (goto-char (point-max))
            (unless (bolp) (insert "\n")))
          (set-file-modes temp #o600)
          (rename-file temp file t))
      (error
       (ignore-errors (delete-file temp))
       (signal (car err) (cdr err))))
    file))

(defun cmacs-context--saved-names ()
  "The names of the contexts that have a saved state."
  (let ((dir (expand-file-name cmacs-context-directory)))
    (when (file-directory-p dir)
      (delq nil
            (mapcar
             (lambda (file)
               (let ((name (decode-coding-string
                            (url-unhex-string (file-name-base file))
                            'utf-8)))
                 (and (ignore-errors (cmacs-context--check-name name))
                      name)))
             (directory-files dir nil "\\`[^.].*\\.json\\'"))))))

;;;; Declared contexts

;;;###autoload
(defun cmacs-context-define (name &rest plist)
  "Declare a context called NAME (a string or a symbol).  Returns its name.

PLIST says what it is made of.  All of it is optional:

  :files LIST      files to open; a relative name is under :directory
  :urls LIST       pages to open
  :apps LIST       applications.  Each is a command string, or a plist
                   (:command STRING :app APP-ID :tag N :tags (N...)
                   :floating BOOL :monitor NAME :geometry (X Y W H)).
                   :app is the window's app id, by which a running one
                   is recognised; it defaults to the command's name.
                   Without a tag an application goes to the context's
                   :tags, or tag 1.
  :tags LIST       the tags to view on switching
  :layout NAME     the gowl layout to set (\"tile\", \"monocle\", ...)
  :directory DIR   where the context lives: the default directory, and
                   where the applications it starts are started
  :project NAME    a label for the list and the journal
  :label STRING    the name the journal records (default NAME)
  :env ALIST       ((\"VAR\" . \"VALUE\")...) set for the applications
                   this context STARTS.  Not for secrets: the values are
                   on a command line.  Never written to saved state.
  :setup FN        called with no argument after arriving
  :teardown FN     called with no argument before leaving
  :auto-save BOOL  overrides `cmacs-context-auto-save-on-leave'

:setup and :teardown run on the main thread under `condition-case'; one
that fails is reported and the switch goes on.

Once the context has been saved (by leaving it, or `cmacs-context-update')
the saved arrangement is used instead of :files, :urls, :apps, :tags and
:layout, category by category; `cmacs-context-delete' goes back to this
declaration.  The other keys always come from here."
  (let ((name (cmacs-context--check-name
               (if (symbolp name) (symbol-name name) name))))
    (cl-loop for (key _) on plist by #'cddr
             unless (memq key cmacs-context--define-keys)
             do (error "cmacs-context-define %s: unknown key %S" name key))
    (setf (alist-get name cmacs-context--declared nil nil #'equal) plist)
    (cmacs-context--refresh-voice)
    name))

(defun cmacs-context--yaml-plist (name body file)
  "The `cmacs-context-define' plist for BODY, the YAML mapping of NAME in FILE."
  (let (plist)
    (pcase-dolist (`(,key . ,value) body)
      (pcase key
        ((or 'files 'urls)
         (setq plist (plist-put plist (intern (format ":%s" key))
                                (mapcar (lambda (v) (format "%s" v)) value))))
        ((or 'layout 'project 'directory 'label)
         (setq plist (plist-put plist (intern (format ":%s" key))
                                (format "%s" value))))
        ('tags (setq plist (plist-put plist :tags
                                      (if (listp value) value (list value)))))
        ('env
         (setq plist (plist-put
                      plist :env
                      (mapcar (lambda (cell)
                                (cons (format "%s" (car cell))
                                      (format "%s" (cdr cell))))
                              value))))
        ('apps
         (setq plist
               (plist-put
                plist :apps
                (mapcar
                 (lambda (app)
                   (if (stringp app)
                       app
                     (cl-loop for (k . v) in app
                              unless (memq k '(command app tag tags floating
                                                       monitor geometry))
                              do (error "%s: context %s: unknown app key `%s'"
                                        file name k)
                              nconc (list (intern (format ":%s" k)) v))))
                 value))))
        (_ (error "%s: context %s: unknown key `%s'%s" file name key
                  (if (memq key '(setup teardown))
                      " (functions can only be given in Elisp)"
                    "")))))
    (plist-put plist :source file)))

(defun cmacs-context-load-file (file)
  "Declare the contexts in the YAML FILE.  Return how many there were.
Signals when FILE does not parse or holds a key this does not know."
  (unless (fboundp 'cmacs-yaml-parse-file)
    (error "This cmacs was built without a YAML reader (cmacs-yaml-parse-file)"))
  (let* ((file (expand-file-name file))
         (doc (json-parse-string (cmacs-yaml-parse-file file)
                                 :object-type 'alist :array-type 'list
                                 :null-object nil :false-object nil))
         (contexts (if (assq 'contexts doc) (alist-get 'contexts doc) doc))
         (count 0))
    (pcase-dolist (`(,name . ,body) contexts)
      (let ((name (format "%s" name)))
        (apply #'cmacs-context-define name
               (cmacs-context--yaml-plist name body file))
        (cl-incf count)))
    count))

(defun cmacs-context-reload-files ()
  "Read `cmacs-context-files' again, dropping what they declared before."
  (interactive)
  (setq cmacs-context--declared
        (cl-remove-if (lambda (cell) (plist-get (cdr cell) :source))
                      cmacs-context--declared)
        cmacs-context--files-loaded t)
  (dolist (file cmacs-context-files)
    (condition-case err
        (cmacs-context-load-file file)
      (error
       (display-warning
        'cmacs-context
        (format "Contexts in %s were not loaded: %s" file
                (error-message-string err))
        :warning))))
  (cmacs-context--refresh-voice))

(defun cmacs-context--ensure-files ()
  "Read `cmacs-context-files' if that has not been done."
  (unless cmacs-context--files-loaded
    (setq cmacs-context--files-loaded t)
    (when cmacs-context-files
      (cmacs-context-reload-files))))

(defun cmacs-context--declaration (name)
  "The declared plist of the context NAME, or nil.
Nil too for a context declared with no keys at all; ask
`cmacs-context--declared-p' whether there is a declaration."
  (cmacs-context--ensure-files)
  (cdr (assoc name cmacs-context--declared)))

(defun cmacs-context--declared-p (name)
  "Non-nil when the context NAME is declared, with keys or without."
  (cmacs-context--ensure-files)
  (and (assoc name cmacs-context--declared) t))

(defun cmacs-context--declared-client (app default-tags)
  "The snapshot client entry for APP, an element of a declaration's :apps.
DEFAULT-TAGS are the tags of an application that names none."
  (let* ((app (if (stringp app) (list :command app) app))
         (command (plist-get app :command))
         (id (or (plist-get app :app)
                 (and (stringp command)
                      (file-name-nondirectory
                       (or (car (split-string command)) "")))))
         (tags (or (plist-get app :tags)
                   (and (plist-get app :tag) (list (plist-get app :tag)))
                   default-tags
                   '(1))))
    (append (list :app id :tags tags)
            (and (stringp command) (list :command command))
            (and (plist-get app :monitor)
                 (list :monitor (plist-get app :monitor)))
            (and (plist-get app :floating) (list :floating t))
            (and (plist-get app :floating) (plist-get app :geometry)
                 (list :geometry (plist-get app :geometry))))))

(defun cmacs-context--declared-snapshot (declaration)
  "The checkpoint snapshot DECLARATION describes.
A declared layout is a layout NAME, and a snapshot holds the SYMBOL a
monitor showed; the name is carried as \"=NAME\", which
`cmacs-context--plan' teaches the restore to read."
  (let* ((directory (plist-get declaration :directory))
         (files (mapcar
                 (lambda (file)
                   (list :file (abbreviate-file-name
                                (expand-file-name file directory))))
                 (plist-get declaration :files)))
         (tags (plist-get declaration :tags))
         (layout (plist-get declaration :layout))
         (view-tags
          (or tags
              ;; A layout with no tags named is for the tags in view.
              (and layout (cmacs-context--gowl-p)
                   (require 'cmacs-journal nil t)
                   (cmacs-journal--tag-list
                    (alist-get 'tags (ignore-errors (gowl-monitor-info))))))))
    (list
     ;; The first file is what you see on arriving; the rest are open.
     :frames (and files
                  (list (list :tree (append (car files)
                                            (list :size 1.0 :selected t))
                              :selected t)))
     :buffers files
     :urls (mapcar (lambda (url) (list :url url))
                   (plist-get declaration :urls))
     :clients (mapcar (lambda (app)
                        (cmacs-context--declared-client app tags))
                      (plist-get declaration :apps))
     :monitors (and view-tags
                    (cmacs-context--gowl-p)
                    (let ((name (alist-get 'name
                                           (ignore-errors (gowl-monitor-info)))))
                      (and (stringp name)
                           (list (append
                                  (list :name name :tags view-tags :focused t)
                                  (and layout
                                       (list :layout (concat "=" layout)))))))))))

;;;; What a context is, all told

(defun cmacs-context-names ()
  "The names of every context, declared or saved, sorted."
  (cmacs-context--ensure-files)
  (sort (delete-dups (append (mapcar #'car cmacs-context--declared)
                             (cmacs-context--saved-names)))
        #'string<))

(defun cmacs-context-exists-p (name)
  "Non-nil when there is a context called NAME."
  (and (stringp name)
       (or (cmacs-context--declared-p name)
           (file-readable-p (cmacs-context--file name)))
       t))

;;;###autoload
(defun cmacs-context-current ()
  "The name of the context you are in, or nil."
  cmacs-context--current)

(defun cmacs-context--effective (name)
  "Everything the context NAME is, from its declaration and saved state.
A plist: :name :declared (non-nil when declared) :state (the saved
state) :snapshot :directory :project :label :env :setup :teardown.

The precedence is the one in the commentary: a category of arrangement
the saved state holds replaces the declaration's; the rest comes from
the declaration when it is declared there."
  (let* ((declaration (cmacs-context--declaration name))
         (state (cmacs-context--read name))
         (saved (plist-get state :snapshot))
         (declared (cmacs-context--declared-p name))
         (base (and declared
                    (cmacs-context--declared-snapshot declaration)))
         (held (mapcar #'intern (plist-get state :include)))
         (snapshot
          (if (null (plist-member state :snapshot))
              base
            (cl-loop for (category . members) in cmacs-context--categories
                     nconc (cl-loop for member in members
                                    nconc (list member
                                                (plist-get
                                                 (if (memq category held)
                                                     saved
                                                   base)
                                                 member)))))))
    (list :name name
          :declared declared
          :state state
          :snapshot snapshot
          :directory (or (plist-get declaration :directory)
                         (plist-get state :directory))
          :project (or (plist-get declaration :project)
                       (plist-get state :project))
          :label (plist-get declaration :label)
          :env (plist-get declaration :env)
          :setup (plist-get declaration :setup)
          :teardown (plist-get declaration :teardown))))

(defun cmacs-context-info (name)
  "What the lists show about the context NAME, as a plist.
:name :kind (`declared', `saved' or `both') :used (seconds, or nil)
:apps :files :urls (counts) :project :directory :current."
  (let* ((effective (cmacs-context--effective name))
         (snapshot (plist-get effective :snapshot))
         (state (plist-get effective :state)))
    (list :name name
          :kind (cond ((and (plist-get effective :declared)
                            (plist-member state :snapshot))
                       'both)
                      ((plist-get effective :declared) 'declared)
                      (t 'saved))
          :used (plist-get state :used)
          :apps (length (plist-get snapshot :clients))
          :files (length (plist-get snapshot :buffers))
          :urls (length (plist-get snapshot :urls))
          :project (plist-get effective :project)
          :directory (plist-get effective :directory)
          :current (equal name cmacs-context--current))))

(defun cmacs-context--annotation (name)
  "A one-line description of the context NAME for a chooser."
  (let ((info (cmacs-context-info name)))
    (string-join
     (delq nil
           (list (and (plist-get info :current) "current")
                 (format "%d app%s, %d file%s"
                         (plist-get info :apps)
                         (if (= 1 (plist-get info :apps)) "" "s")
                         (plist-get info :files)
                         (if (= 1 (plist-get info :files)) "" "s"))
                 (plist-get info :project)
                 (concat "used " (cmacs-context--ago (plist-get info :used)))))
     ", ")))

(defun cmacs-context--names-by-use ()
  "Every context's name, the most recently used first, the current one last.
So the first candidate of a switcher is where you were before."
  (let* ((names (cmacs-context-names))
         (used (mapcar (lambda (name)
                         (cons name (or (plist-get (cmacs-context--read name)
                                                   :used)
                                        0)))
                       names)))
    (sort names
          (lambda (a b)
            (cond ((equal a cmacs-context--current) nil)
                  ((equal b cmacs-context--current) t)
                  (t (> (cdr (assoc a used)) (cdr (assoc b used)))))))))

(defun cmacs-context--read-name (prompt &optional require-match default)
  "Read a context's name with PROMPT, annotated.
REQUIRE-MATCH and DEFAULT are as in `completing-read'."
  (let* ((names (cmacs-context--names-by-use))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      `(metadata
                        (category . cmacs-context)
                        (display-sort-function . identity)
                        (annotation-function
                         . ,(lambda (name)
                              (concat "  "
                                      (ignore-errors
                                        (cmacs-context--annotation name))))))
                    (complete-with-action action names string predicate)))))
    (cmacs-context--check-name
     (string-trim
      (completing-read prompt table nil require-match nil nil default)))))

;;;; Capturing

(defun cmacs-context--capture (include)
  "The arrangement right now, limited to the categories in INCLUDE.
A checkpoint snapshot.  Signals a `user-error' when the journal's rule
set cannot be used: what may not be remembered cannot be told apart
then, so nothing is."
  (require 'cmacs-journal-checkpoint)
  ;; The rules are loaded by the journal's mode, which need not be on.
  (unless (bound-and-true-p cmacs-journal-filter--loaded)
    (unless (cmacs-journal-filter-error)
      (ignore-errors (cmacs-journal-filters-reload))))
  (unless (cmacs-journal-filter-ready-p)
    (user-error "Not saved: the journal's filter rules could not be loaded (%s)"
                (or (cmacs-journal-filter-error) "not loaded")))
  (let ((snapshot (cmacs-journal-checkpoint-snapshot)))
    (cl-loop for (category . members) in cmacs-context--categories
             when (memq category include)
             nconc (cl-loop for member in members
                            nconc (list member (plist-get snapshot member))))))

(defun cmacs-context--guess-directory ()
  "The directory of what is selected now: its project's root, or its own.
Nil for a remote one, which is not looked at."
  (let ((directory default-directory))
    (when (and (stringp directory) (not (file-remote-p directory)))
      (abbreviate-file-name
       (or (ignore-errors
             (when-let* ((project (project-current nil directory)))
               (project-root project)))
           directory)))))

(defun cmacs-context--save (name &optional include)
  "Capture the arrangement into the context NAME and write it.
INCLUDE is the list of categories (default: what the context was saved
with before, else `cmacs-context-save-include').  The context's
directory is set the first time and kept after.  Returns the state."
  (let* ((old (cmacs-context--read name))
         (include (or include
                      (mapcar #'intern (plist-get old :include))
                      cmacs-context-save-include))
         (snapshot (cmacs-context--capture include))
         (directory (or (plist-get old :directory)
                        (and (null (plist-get (cmacs-context--declaration name)
                                              :directory))
                             (cmacs-context--guess-directory))))
         (state (list :name name
                      :saved (float-time)
                      :used (plist-get old :used)
                      :directory directory
                      :project (or (plist-get old :project)
                                   (and directory
                                        (file-name-nondirectory
                                         (directory-file-name directory))))
                      :include include
                      :snapshot snapshot)))
    (cmacs-context--write name state)
    state))

(defun cmacs-context--read-include ()
  "Ask what a save should capture; return the list of categories."
  (let ((chosen (completing-read-multiple
                 "Include (comma separated): "
                 '("buffers" "urls" "apps" "layout") nil t
                 (mapconcat #'symbol-name cmacs-context-save-include ","))))
    (or (mapcar #'intern chosen)
        (user-error "Nothing to include"))))

;;;###autoload
(defun cmacs-context-save (name &optional include)
  "Save the arrangement that is up now as the context NAME, and be in it.

Captured: the Emacs window tree and open files, the pages in gsurf
buffers, and under gowl every window's application, tags, monitor and
command line, and each monitor's view and layout.  With a prefix
argument, asks which of those to include (INCLUDE, a list of `buffers',
`urls', `apps', `layout').

Saving over a declared context refines it: see `cmacs-context-define'.
Nothing is written to the journal, and the journal need not be on.
What the journal's filters exclude is not saved."
  (interactive
   (list (cmacs-context--read-name "Save context as: " nil
                                   cmacs-context--current)
         (and current-prefix-arg (cmacs-context--read-include))))
  (cmacs-context--check-name name)
  (when (cmacs-context--agent-p)
    (error "cmacs-context-save is for the person at the keyboard"))
  (let ((state (cmacs-context--save name include)))
    (setq cmacs-context--current name
          cmacs-context--settled t)
    (cmacs-context--announce)
    (cmacs-context--refresh-voice)
    (message "Context %s saved (%d app%s, %d file%s)" name
             (length (plist-get (plist-get state :snapshot) :clients))
             (if (= 1 (length (plist-get (plist-get state :snapshot) :clients)))
                 "" "s")
             (length (plist-get (plist-get state :snapshot) :buffers))
             (if (= 1 (length (plist-get (plist-get state :snapshot) :buffers)))
                 "" "s"))
    name))

;;;###autoload
(defun cmacs-context-update ()
  "Save the arrangement that is up now into the context you are in."
  (interactive)
  (unless cmacs-context--current
    (user-error "You are in no context; M-x cmacs-context-save names one"))
  (cmacs-context-save cmacs-context--current))

;;;; The plan

(defun cmacs-context--launches (plan)
  "How many applications PLAN would start as it stands."
  (cl-count-if (lambda (item)
                 (and (eq (plist-get item :type) 'launch)
                      (plist-get item :enabled)))
               (plist-get plan :items)))

(defun cmacs-context--env-prefix (effective)
  "The words to put before a command EFFECTIVE's context starts, or nil.
`env', with the context's directory and variables: `gowl-spawn' runs a
command line, not a shell, and env(1) is how a command line carries a
directory and variables."
  (let* ((directory (plist-get effective :directory))
         (directory (and (stringp directory)
                         (not (file-remote-p directory))
                         (file-directory-p directory)
                         (expand-file-name directory)))
         (env (cl-remove-if-not
               (lambda (cell)
                 (and (consp cell) (stringp (car cell)) (stringp (cdr cell))
                      (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'"
                                      (car cell))))
               (plist-get effective :env))))
    (when (or directory env)
      (concat "env "
              (and directory
                   (concat "-C " (shell-quote-argument directory) " "))
              (mapconcat (lambda (cell)
                           (shell-quote-argument
                            (concat (car cell) "=" (cdr cell))))
                         env " ")
              (and env " ")))))

(defun cmacs-context--plan (name)
  "The restore plan that switching to the context NAME would carry out.
Changes nothing."
  (require 'cmacs-journal-restore)
  (let* ((effective (cmacs-context--effective name))
         (snapshot (plist-get effective :snapshot))
         ;; A declared layout is carried as "=NAME"; say what that means.
         (cmacs-journal-restore-layout-names
          (append
           (delq nil
                 (mapcar (lambda (monitor)
                           (let ((layout (plist-get monitor :layout)))
                             (and (stringp layout)
                                  (string-prefix-p "=" layout)
                                  (cons layout (substring layout 1)))))
                         (plist-get snapshot :monitors)))
           cmacs-journal-restore-layout-names))
         (plan (cmacs-journal-restore-plan-from-snapshot
                snapshot
                :title (format "Switch to context %s" name)
                :notes
                (delq nil
                      (list
                       "A context adds and arranges.  Nothing is closed; windows that are not part of it stay where they are."
                       (and (integerp cmacs-context-park-others)
                            (cmacs-context--gowl-p)
                            (format "Other windows on this context's tags move to tag %d (`cmacs-context-park-others')."
                                    cmacs-context-park-others))
                       (and cmacs-context--current
                            (not (equal cmacs-context--current name))
                            cmacs-context--settled
                            (cmacs-context--auto-save-p cmacs-context--current)
                            (format "The arrangement you leave is saved into %s first."
                                    cmacs-context--current))))
                :execute (lambda (plan) (cmacs-context--proceed name plan))
                :refresh (lambda () (cmacs-context--plan name))))
         (prefix (cmacs-context--env-prefix effective)))
    (when prefix
      (dolist (item (plist-get plan :items))
        (when (and (eq (plist-get item :type) 'launch)
                   (stringp (plist-get item :command)))
          (plist-put item :command
                     (concat prefix (plist-get item :command))))))
    plan))

;;;; Switching

(defun cmacs-context--auto-save-p (name)
  "Non-nil when the context NAME is saved on leaving it."
  (let ((declaration (cmacs-context--declaration name)))
    (if (plist-member declaration :auto-save)
        (plist-get declaration :auto-save)
      cmacs-context-auto-save-on-leave)))

(defun cmacs-context--call (what function &rest args)
  "Call FUNCTION with ARGS; report an error as WHAT failing, and go on.
The hooks and integrations of a switch run through here: none of them
may stop it."
  (when (functionp function)
    (condition-case err
        (apply function args)
      (error
       (message "cmacs-context: %s failed: %s" what
                (error-message-string err))
       nil))))

(defun cmacs-context-register-integration (name &rest plist)
  "Register the optional integration NAME (a symbol).

PLIST: :when FN, called with no argument, says whether it applies now;
:enter FN and :leave FN are called with a context's name on arriving at
it and on leaving it.  All three run under `condition-case'.  Shipped:
`persp', which maps a context to the persp-mode perspective of its name
when `persp-mode' is on (see `cmacs-context-use-perspectives')."
  (setf (alist-get name cmacs-context-integrations) plist)
  name)

(cmacs-context-register-integration
 'persp
 :when (lambda ()
         (and cmacs-context-use-perspectives
              (bound-and-true-p persp-mode)
              (fboundp 'persp-switch)))
 :enter (lambda (name) (persp-switch name)))

(defun cmacs-context--integrations (key name)
  "Run the KEY (:enter or :leave) function of each integration for NAME."
  (pcase-dolist (`(,integration . ,plist) cmacs-context-integrations)
    (when (and (plist-get plist key)
               (or (null (plist-get plist :when))
                   (cmacs-context--call (format "integration %s" integration)
                                        (plist-get plist :when))))
      (cmacs-context--call (format "integration %s" integration)
                           (plist-get plist key) name))))

(defun cmacs-context-directory-now ()
  "The directory of the context you are in, or nil."
  (and cmacs-context--current
       (let ((directory (plist-get (cmacs-context--effective
                                    cmacs-context--current)
                                   :directory)))
         (and (stringp directory)
              (file-name-as-directory (expand-file-name directory))))))

(defun cmacs-context--apply-directory (effective)
  "Make EFFECTIVE's directory the default one, or put the original back."
  (when cmacs-context-set-default-directory
    (when (eq cmacs-context--original-directory 'unset)
      (setq cmacs-context--original-directory
            (default-value 'default-directory)))
    (let ((directory (plist-get effective :directory)))
      (setq-default default-directory
                    (if (and (stringp directory)
                             (not (file-remote-p directory))
                             (file-directory-p directory))
                        (file-name-as-directory (expand-file-name directory))
                      cmacs-context--original-directory)))))

(defun cmacs-context--journal (effective)
  "Note the switch to EFFECTIVE's context in the journal, if it is recording.
One ordinary event of kind `context' whose title is the context's label
or name, through the journal's filtered write path: a rule can rewrite
it or drop it like any other event.  Nothing when the journal is off."
  (when (and (featurep 'cmacs-journal)
             (fboundp 'cmacs-journal--record-point)
             (ignore-errors (cmacs-journal-recording-p)))
    (ignore-errors
      (cmacs-journal--record-point
       (list :kind 'context
             :app "emacs"
             :title (or (plist-get effective :label)
                        (plist-get effective :name))
             :project (plist-get effective :project)
             :detail "switch")))))

(defun cmacs-context--park (snapshot)
  "Move windows that are not in SNAPSHOT off its tags, if asked to.
See `cmacs-context-park-others'.  Never closes anything."
  (when (and (integerp cmacs-context-park-others)
             (<= 1 cmacs-context-park-others 31)
             (cmacs-context--gowl-p)
             (fboundp 'gowl-set-tags))
    (let* ((tags (delete-dups
                  (append
                   (mapcan (lambda (m) (copy-sequence (plist-get m :tags)))
                           (copy-sequence (plist-get snapshot :monitors)))
                   (mapcan (lambda (c) (copy-sequence (plist-get c :tags)))
                           (copy-sequence (plist-get snapshot :clients))))))
           (running (cmacs-journal-restore--running))
           (mine (delq nil (mapcar #'cdr (cmacs-journal-restore--match
                                          (plist-get snapshot :clients)
                                          running)))))
      (unless (memq cmacs-context-park-others tags)
        (dolist (window running)
          (when (and (not (memq window mine))
                     (cl-intersection (plist-get window :tags) tags))
            (ignore-errors
              (gowl-set-tags (plist-get window :obj)
                             (ash 1 (1- cmacs-context-park-others))))))))))

(defun cmacs-context--touch (name)
  "Record that the context NAME was used now."
  (cmacs-context--call
   "recording the switch"
   (lambda ()
     (let ((state (or (cmacs-context--read name) (list :name name))))
       (cmacs-context--write name (plist-put state :used (float-time)))))))

(defun cmacs-context--focus-emacs ()
  "Under gowl, give this Emacs the keyboard: it is about to ask something."
  (when (and (cmacs-context--gowl-p) (fboundp 'gowl-find-client))
    (ignore-errors
      (when-let* ((self (gowl-find-client (emacs-pid) 'pid)))
        (gowl-focus-client self)))))

;;;###autoload
(defun cmacs-context-cancel ()
  "Stop the switch that is in flight, if one is.
What it has done stays done; nothing more is opened, moved or focused.
Returns non-nil when there was something to stop."
  (interactive)
  (let ((plan (plist-get cmacs-context--switch :plan))
        (name (plist-get cmacs-context--switch :name)))
    (setq cmacs-context--switch nil)
    (when (and plan
               (require 'cmacs-journal-restore nil t)
               (cmacs-journal-restore-cancel plan))
      (message "cmacs-context: the switch to %s was stopped" name)
      t)))

(defun cmacs-context--proceed (name plan)
  "Leave the current context and carry out PLAN, the switch to NAME.
Returns at once; the steps run from timers."
  (cmacs-context-cancel)
  ;; The plan buffer is not part of any arrangement.
  (when-let* ((window (get-buffer-window "*cmacs-journal-restore*")))
    (ignore-errors (quit-window nil window)))
  (let ((previous cmacs-context--current)
        (effective (cmacs-context--effective name)))
    ;; Leaving.  A context that was never fully arrived at has no
    ;; arrangement of its own to save and no setup to undo.
    (when (and previous cmacs-context--settled (not (equal previous name)))
      (cmacs-context--call
       (format "%s :teardown" previous)
       (plist-get (cmacs-context--declaration previous) :teardown))
      (when (cmacs-context--auto-save-p previous)
        (cmacs-context--call (format "saving %s" previous)
                             #'cmacs-context--save previous))
      (cmacs-context--integrations :leave previous))
    ;; Arriving.
    (setq cmacs-context--current name
          cmacs-context--settled nil)
    (cmacs-context--touch name)
    (cmacs-context--apply-directory effective)
    (cmacs-context--journal effective)
    (cmacs-context--announce)
    (cmacs-context--integrations :enter name)
    (cmacs-context--call "parking other windows" #'cmacs-context--park
                         (plist-get effective :snapshot))
    (setq cmacs-context--switch (list :name name :plan plan))
    (cmacs-journal-restore-execute-plan
     plan :async t :quiet t
     :on-done (lambda (plan) (cmacs-context--done name previous plan)))
    name))

(defun cmacs-context--done (name previous plan)
  "The steps of PLAN, the switch from PREVIOUS to NAME, have run."
  (when (and (equal name cmacs-context--current)
             (eq plan (plist-get cmacs-context--switch :plan)))
    (setq cmacs-context--settled t)
    (cmacs-context--call
     (format "%s :setup" name)
     (plist-get (cmacs-context--declaration name) :setup))
    (dolist (function cmacs-context-after-switch-functions)
      (cmacs-context--call "an after-switch function" function name previous))
    (let ((failed (cl-count "failed" (plist-get plan :log)
                            :key #'car :test #'equal)))
      (message "Context %s%s" name
               (if (> failed 0)
                   (format " (%d step%s failed; M-x cmacs-context-log)"
                           failed (if (= failed 1) "" "s"))
                 "")))))

(defun cmacs-context-log ()
  "Show what the last switch did, step by step."
  (interactive)
  (let ((plan (plist-get cmacs-context--switch :plan)))
    (unless plan (user-error "No switch to show"))
    (require 'cmacs-journal-restore)
    (cmacs-journal-restore-show-plan plan)))

(defun cmacs-context--begin (name &optional show-plan)
  "Start switching to the context NAME; return (PLAN . ASKED).
ASKED is non-nil when the plan was shown for confirming instead of being
carried out: SHOW-PLAN, a first switch, or too many applications to
start.  An agent's switch is never shown -- its tool has already asked."
  (cmacs-context--check-name name)
  (require 'cmacs-journal-restore)
  (let ((agent (cmacs-context--agent-p)))
    (when (and agent (not cmacs-context--approved))
      (error "A context switch starts programs: agents reach it through the context_switch tool, which asks the person first"))
    (unless (cmacs-context-exists-p name)
      (user-error "No context called %s" name))
    (let* ((plan (cmacs-context--plan name))
           (ask (and (not agent)
                     (or show-plan
                         (and cmacs-context-confirm-first-switch
                              (null (plist-get (cmacs-context--read name)
                                               :used)))
                         (and cmacs-context-confirm-launches
                              (> (cmacs-context--launches plan)
                                 cmacs-context-confirm-launches))))))
      (if (not ask)
          (cmacs-context--proceed name plan)
        (cmacs-context--focus-emacs)
        (cmacs-journal-restore-show-plan plan)
        (message "%s"
                 (substitute-command-keys
                  "Nothing has been changed; \\<cmacs-journal-restore-mode-map>\\[cmacs-journal-restore-confirm] here switches.")))
      (cons plan ask))))

;;;###autoload
(defun cmacs-context-switch (name &optional show-plan)
  "Switch to the context NAME.

Opens its files and pages, rebuilds its Emacs windows and, under gowl,
starts the applications that are not running on their tags, moves the
ones that are, and views its tags.  Nothing is closed.  The context you
leave is saved into itself first when `cmacs-context-auto-save-on-leave'.

Immediate, except that the plan is shown for confirming before the
first switch to a context, when more than
`cmacs-context-confirm-launches' applications would be started, and with
a prefix argument (SHOW-PLAN).  The steps run from timers; switching
again before they finish stops them.

Switching to the context you are in puts its saved arrangement back
without saving the current one first."
  (interactive (list (cmacs-context--read-name "Switch to context: " t)
                     current-prefix-arg))
  (cmacs-context--begin name show-plan)
  name)

;;;###autoload
(defun cmacs-context-diff (name)
  "Show what switching to the context NAME would change.  Changes nothing.
The plan buffer of `cmacs-journal-restore': each line can be turned off,
and confirming there switches."
  (interactive (list (cmacs-context--read-name "Diff against context: " t)))
  (cmacs-context--check-name name)
  (unless (cmacs-context-exists-p name)
    (user-error "No context called %s" name))
  (require 'cmacs-journal-restore)
  (cmacs-journal-restore-show-plan (cmacs-context--plan name)))

;;;###autoload
(defun cmacs-context-delete (name)
  "Delete the saved state of the context NAME.
A declared context is still declared afterwards and goes back to what
its declaration says.  No window or buffer is touched."
  (interactive (list (cmacs-context--read-name "Delete context: " t)))
  (cmacs-context--check-name name)
  (let ((file (cmacs-context--file name))
        (declared (cmacs-context--declared-p name)))
    (unless (or declared (file-exists-p file))
      (user-error "No context called %s" name))
    (when (file-exists-p file)
      (delete-file file t))
    (when (and (equal name cmacs-context--current) (not declared))
      (setq cmacs-context--current nil
            cmacs-context--settled nil)
      (cmacs-context--announce))
    (cmacs-context--refresh-voice)
    (message (if declared
                 "Context %s: saved state removed; its declaration remains"
               "Context %s deleted")
             name)
    name))

;;;###autoload
(defun cmacs-context-rename (name new)
  "Rename the saved context NAME to NEW.
A declared context is named in your init and is renamed there."
  (interactive
   (let ((name (cmacs-context--read-name "Rename context: " t)))
     (list name (cmacs-context--check-name
                 (string-trim (read-string (format "Rename %s to: " name)))))))
  (cmacs-context--check-name name)
  (cmacs-context--check-name new)
  (when (cmacs-context--declared-p name)
    (user-error "%s is declared in your init; rename it there" name))
  (when (cmacs-context-exists-p new)
    (user-error "There is already a context called %s" new))
  (let ((state (or (cmacs-context--read name)
                   (user-error "No context called %s" name))))
    (cmacs-context--write new state)
    (delete-file (cmacs-context--file name))
    (when (equal name cmacs-context--current)
      (setq cmacs-context--current new)
      (cmacs-context--announce))
    (cmacs-context--refresh-voice)
    (message "Context %s is now %s" name new)
    new))

;;;; Working in the context's directory

;;;###autoload
(defun cmacs-context-project-find-file ()
  "Run `project-find-file' in the current context's directory."
  (interactive)
  (let ((default-directory (or (cmacs-context-directory-now)
                               default-directory)))
    (call-interactively #'project-find-file)))

;;;###autoload
(defun cmacs-context-compile (command)
  "Run `compile' with COMMAND in the current context's directory."
  (interactive
   (list (progn (require 'compile)
                (read-shell-command "Compile command: " compile-command))))
  (let ((default-directory (or (cmacs-context-directory-now)
                               default-directory)))
    (compile command)))

;;;; Showing where you are: the mode line and the bar

(defconst cmacs-context--mode-line-entry
  '(:eval (cmacs-context-mode-line))
  "What `global-mode-string' holds for the current context.")

(defun cmacs-context-mode-line ()
  "The mode line text for the current context, or the empty string."
  (if (and cmacs-context--current cmacs-context-mode-line-format)
      (format cmacs-context-mode-line-format cmacs-context--current)
    ""))

(defun cmacs-context--announce ()
  "Show the current context in the mode line and, under gowl, the bar."
  (when cmacs-context-mode-line-format
    (unless (member cmacs-context--mode-line-entry global-mode-string)
      (setq global-mode-string
            (append (if (listp global-mode-string)
                        global-mode-string
                      (list global-mode-string))
                    (list cmacs-context--mode-line-entry))))
    (force-mode-line-update t))
  (when (cmacs-context--gowl-p)
    (let ((text (or cmacs-context--current "")))
      (cond
       ;; Real slots, when the bar has them.
       ((fboundp 'cmacs-gowl-bar-slot-set)
        ;; A slot's content is a plist; with no context there is
        ;; nothing to show, and an empty slot would still take room.
        (ignore-errors
          (if (and (string-empty-p text)
                   (fboundp 'cmacs-gowl-bar-slot-remove))
              (cmacs-gowl-bar-slot-remove cmacs-context-bar-slot)
            (cmacs-gowl-bar-slot-set cmacs-context-bar-slot :text text))))
       ;; Otherwise the one widget whose text is a setting.
       ((and cmacs-context-bar-widget
             (or (fboundp 'cmacs-gowl-bar-push)
                 (require 'cmacs-gowl-bar-ai nil t)))
        (cmacs-gowl-bar-push cmacs-context-bar-widget
                             (list (cons "text" text))))))))

;;;; The switcher: gowl's menu card, or the minibuffer

(defconst cmacs-context--card-poll 0.1
  "Seconds between looks at the menu card's answer.")

(defconst cmacs-context--card-patience 300
  "Seconds after which an unanswered card is taken as cancelled.")

(defun cmacs-context--card-open (prompt lines)
  "Open gowl's menu card titled PROMPT on LINES; return its token, or nil.
nil when there is no card to open: no compositor, no menu module, a
locked session."
  (when (and (cmacs-context--gowl-p) (fboundp 'gowl-run-command))
    (let ((reply (ignore-errors
                   (gowl-run-command
                    (concat "menu-choose "
                            (mapconcat
                             (lambda (line)
                               (replace-regexp-in-string "[\t\n\r]+" " " line))
                             (cons prompt lines) "\t"))))))
      (and (stringp reply)
           (string-match "\\`OK \\([^ \t\n]+\\)" reply)
           (match-string 1 reply)))))

(defun cmacs-context--card-wait (token count tries callback)
  "Ask the card for the answer to TOKEN; call CALLBACK when it has one.
CALLBACK gets the index of the row picked, of COUNT rows, or nil for a
cancelled card.  TRIES is how many more times to ask.  Never waits: one
look, then a timer."
  (let ((reply (ignore-errors
                 (gowl-run-command (concat "menu-choice " token)))))
    (cond
     ((and (stringp reply)
           (string-match (concat "\\`OK " (regexp-quote token)
                                 " chosen \\([0-9]+\\)")
                         reply))
      (let ((index (string-to-number (match-string 1 reply))))
        (funcall callback (and (< index count) index))))
     ((and (stringp reply)
           (string-match-p (concat "\\`OK " (regexp-quote token) " pending")
                           reply)
           (> tries 0))
      (run-at-time cmacs-context--card-poll nil #'cmacs-context--card-wait
                   token count (1- tries) callback))
     (t (funcall callback nil)))))

;;;###autoload
(defun cmacs-context-menu ()
  "Choose a context to switch to: gowl's menu card, else the minibuffer.
The card is the compositor's, so it comes up over whatever application
has the keyboard.  The previous context is the first row."
  (interactive)
  (let* ((names (cmacs-context--names-by-use))
         (token (and names
                     (cmacs-context--card-open
                      "Context"
                      (mapcar (lambda (name)
                                (format "%s  --  %s" name
                                        (or (ignore-errors
                                              (cmacs-context--annotation name))
                                            "")))
                              names)))))
    (cond
     ((null names)
      (message "No contexts yet; M-x cmacs-context-save makes one"))
     (token
      (cmacs-context--card-wait
       token (length names)
       (round (/ cmacs-context--card-patience cmacs-context--card-poll))
       (lambda (index)
         (when index
           (cmacs-context--call "the switch" #'cmacs-context-switch
                                (nth index names))))))
     (t
      (cmacs-context--focus-emacs)
      (call-interactively #'cmacs-context-switch)))))

;;;###autoload
(defun cmacs-context-setup ()
  "Bind `cmacs-context-key' to the context switcher in gowl.
Does nothing when the compositor is not running or the key is nil.
Safe to call again: the key is unbound before it is bound."
  (interactive)
  (when (and cmacs-context-key
             (cmacs-context--gowl-p)
             (fboundp 'gowl-add-keybind))
    (condition-case err
        (progn
          ;; gowl runs the first bind that matches, so one left by an
          ;; earlier call would shadow this one.
          (ignore-errors (gowl-remove-keybind cmacs-context-key))
          (gowl-add-keybind cmacs-context-key 'custom
                            "(cmacs-context-menu)"
                            "Switch context")
          t)
      (error (message "cmacs-context: cannot bind %s: %s"
                      cmacs-context-key (error-message-string err))
             nil))))

;;;; The list

(defvar cmacs-context-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'cmacs-context-list-switch)
    (define-key map "s" #'cmacs-context-list-switch)
    (define-key map "S" #'cmacs-context-list-save)
    (define-key map "d" #'cmacs-context-list-diff)
    (define-key map "D" #'cmacs-context-list-delete)
    (define-key map "r" #'cmacs-context-list-rename)
    (define-key map "+" #'cmacs-context-save)
    map)
  "Keymap of the context list.")

(define-derived-mode cmacs-context-list-mode tabulated-list-mode "Contexts"
  "The contexts there are.

\\[cmacs-context-list-switch] switches to the one at point, \\[cmacs-context-list-diff] shows what that would change,
\\[cmacs-context-list-save] saves the arrangement that is up now over it, \\[cmacs-context-list-delete] deletes its
saved state, \\[cmacs-context-list-rename] renames it, \\[cmacs-context-save] saves a new one."
  (setq tabulated-list-format
        [("" 1 nil) ("Context" 20 t) ("Kind" 9 t) ("Apps" 5 nil)
         ("Files" 6 nil) ("Used" 9 nil) ("Project" 16 t) ("Directory" 0 nil)]
        tabulated-list-padding 1
        tabulated-list-entries #'cmacs-context--list-entries)
  (tabulated-list-init-header))

(defun cmacs-context--list-entries ()
  "The `tabulated-list-entries' of the context list."
  (mapcar
   (lambda (name)
     (let ((info (cmacs-context-info name)))
       (list name
             (vector (if (plist-get info :current) "*" "")
                     name
                     (symbol-name (plist-get info :kind))
                     (number-to-string (plist-get info :apps))
                     (number-to-string (plist-get info :files))
                     (cmacs-context--ago (plist-get info :used))
                     (or (plist-get info :project) "")
                     (or (plist-get info :directory) "")))))
   (cmacs-context-names)))

(defun cmacs-context--list-name ()
  "The context on the line at point, or a `user-error'."
  (or (tabulated-list-get-id) (user-error "No context on this line")))

(defun cmacs-context-list-switch ()
  "Switch to the context at point."
  (interactive nil cmacs-context-list-mode)
  (cmacs-context-switch (cmacs-context--list-name)))

(defun cmacs-context-list-diff ()
  "Show what switching to the context at point would change."
  (interactive nil cmacs-context-list-mode)
  (cmacs-context-diff (cmacs-context--list-name)))

(defun cmacs-context-list-save ()
  "Save the arrangement that is up now over the context at point."
  (interactive nil cmacs-context-list-mode)
  (let ((name (cmacs-context--list-name)))
    (when (y-or-n-p (format "Save what is up now as %s? " name))
      (cmacs-context-save name)
      (revert-buffer))))

(defun cmacs-context-list-delete ()
  "Delete the saved state of the context at point."
  (interactive nil cmacs-context-list-mode)
  (let ((name (cmacs-context--list-name)))
    (when (y-or-n-p (format "Delete the saved state of %s? " name))
      (cmacs-context-delete name)
      (revert-buffer))))

(defun cmacs-context-list-rename ()
  "Rename the context at point."
  (interactive nil cmacs-context-list-mode)
  (let ((name (cmacs-context--list-name)))
    (cmacs-context-rename
     name (string-trim (read-string (format "Rename %s to: " name))))
    (revert-buffer)))

;;;###autoload
(defun cmacs-context-list ()
  "List the contexts, with keys to switch, save, diff, delete and rename."
  (interactive)
  (let ((buffer (get-buffer-create "*cmacs-contexts*")))
    (with-current-buffer buffer
      (cmacs-context-list-mode)
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

;;;; Voice

(defun cmacs-context--spoken (phrase)
  "The context a spoken PHRASE names, or nil.  Case and spacing are ignored."
  (let ((want (downcase (string-join (split-string (or phrase "")) " "))))
    (cl-find-if (lambda (name)
                  (string= (downcase (string-join (split-string name) " "))
                           want))
                (cmacs-context-names))))

;;;###autoload
(defun cmacs-context-voice-switch (&optional phrase)
  "Voice command: switch to the context PHRASE names.
A switch that needs confirming shows its plan and asks the voice way; a
yes carries it out.  With voice confirmations off the plan stays up for
you to confirm by hand."
  (let ((name (cmacs-context--spoken phrase)))
    (if (null name)
        (message "No context called \"%s\"" (or phrase ""))
      (pcase-let ((`(,plan . ,asked) (cmacs-context--begin name)))
        (when (and asked
                   (fboundp 'cmacs-voice-confirm)
                   (bound-and-true-p cmacs-voice-confirm-destructive))
          (cmacs-voice-confirm
           (format "Switch to %s?" name)
           (lambda () (cmacs-context--proceed name plan))))))))

;;;###autoload
(defun cmacs-context-voice-save (&optional phrase)
  "Voice command: save what is up now as the context PHRASE names.
An existing context is matched whatever its case; otherwise PHRASE is
the new one's name.  With no PHRASE, updates the current context."
  (let ((phrase (and phrase (string-trim phrase))))
    (if (or (null phrase) (string-empty-p phrase))
        (cmacs-context-update)
      (cmacs-context-save (or (cmacs-context--spoken phrase) phrase)))))

(defun cmacs-context--refresh-voice ()
  "Make \"switch to NAME\" a voice command for each context there is.
The bare phrase is only safe to claim for names that are contexts --
\"switch to firefox\" is a window -- so the command's regexp is rebuilt
from the names whenever they change.  Does nothing until voice commands
are loaded."
  (when (and (featurep 'cmacs-voice-commands)
             (boundp 'cmacs-voice-commands))
    (setq cmacs-voice-commands
          (cl-remove-if (lambda (entry)
                          (and (eq (nth 1 entry) 'cmacs-context-voice-switch)
                               (plist-get (nth 3 entry) :cmacs-context-names)))
                        cmacs-voice-commands))
    (let ((names (ignore-errors (cmacs-context-names))))
      (when names
        (cmacs-voice-define-command
         (concat "\\(?:switch\\|go\\|change\\)\\(?: back\\)? to \\(?:the \\)?"
                 (regexp-opt (mapcar #'downcase names) t)
                 "\\(?: context\\)?")
         #'cmacs-context-voice-switch
         "switch to CONTEXT" nil :context 'desktop
         :cmacs-context-names t)))))

;; As in cmacs-journal-restore.el: the autoloaded form below may only
;; call an autoloaded function of this file, because loaddefs.el is
;; compiled without cmacs-voice-commands.
;;;###autoload
(defun cmacs-context-register-voice ()
  "Register the context phrases with the voice-command registry."
  (cmacs-voice-define-command
   "\\(?:switch\\|go\\|change\\) to \\(?:the \\)?context \\(.+\\)"
   #'cmacs-context-voice-switch
   "switch to context NAME" nil :context 'desktop)
  (cmacs-voice-define-command
   "\\(?:switch\\|go\\|change\\) to \\(?:the \\)?\\(.+\\) context"
   #'cmacs-context-voice-switch
   "switch to the NAME context" nil :context 'desktop)
  (cmacs-voice-define-command
   "save \\(?:this\\|the\\|my\\)?\\(?: ?\\(?:context\\|arrangement\\|layout\\|desktop\\)\\)? ?as \\(.+\\)"
   #'cmacs-context-voice-save
   "save this as NAME" nil :context 'desktop)
  (cmacs-voice-define-command
   "\\(?:update\\|save\\) \\(?:this\\|the\\|my\\) context"
   #'cmacs-context-voice-save
   "update this context" nil :context 'desktop)
  (cmacs-context--refresh-voice))

;;;###autoload
(with-eval-after-load 'cmacs-voice-commands
  (cmacs-context-register-voice))

(provide 'cmacs-context)

;;; cmacs-context.el ends here
