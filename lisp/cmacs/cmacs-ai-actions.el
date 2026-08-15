;;; cmacs-ai-actions.el --- What you can do with a target  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The other half of the pair: cmacs-ai-target.el says what is under the
;; click, and this file says what can be done with it.
;;
;; Actions are registered, not hardcoded, for the same reason resolvers
;; are: the shipped ones and yours go through the same door.  A
;; registered action carries a :group (which submenu it lands in), an
;; :applies predicate (so a "Rewrite in place" entry never appears over a
;; read-only diff hunk) and a :run function.  Everything that renders a
;; list of things you can do -- the right-click menu, the `C-c a'
;; transient -- reads this registry and nothing else.
;;
;; The groups are fixed, and deliberately so.  Four submenus in the same
;; order everywhere means you stop reading the menu after a week:
;;
;;   Ask AI   answer something about this, in a result window
;;   Chat     carry this into a conversation that persists
;;   Brigade  hand this to an agent that works while you do not watch
;;   Tools    whatever you published with `cmacs-brigade-deftool :menu t'
;;
;; One rule runs through every brigade action here: menu items COMPOSE,
;; they do not FIRE.  Choosing "Spawn agent on this" fills in the compose
;; transient and shows it to you; it does not start a run.  A right-click
;; is a cheap, half-deliberate gesture and starting paid work off one is
;; how you end up with a bill you did not intend.  `cmacs-brigade-compose'
;; already takes this line with voice input; the menu holds it too.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-targets)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-output)

;; cmacs-ai proper, the brigade, libreclaw and the per-subsystem AI
;; commands are all optional at build time.  Nothing here requires them;
;; each action's :applies predicate checks for what it needs.
(declare-function cmacs-ai-supported-p "cmacs-ai-defuns.c" ())
(declare-function cmacs-ai-chat-open "cmacs-ai-chat"
                  (&optional provider model directory))
(declare-function cmacs-ai-rewrite-region "cmacs-ai-region" (instruction))
(declare-function cmacs-ai-doc-region "cmacs-ai-region" ())
(declare-function cmacs-ai-test-region "cmacs-ai-region" ())
(declare-function cmacs-gsurf-summarize "cmacs-gsurf-ai" ())
(declare-function cmacs-gsurf-ask "cmacs-gsurf-ai" (question))
(declare-function cmacs-imgedit-ai-describe "cmacs-imgedit-ai" ())
(declare-function cmacs-imgedit-ai-prompt "cmacs-imgedit-ai" (instruction))
(declare-function cmacs-libreclaw-send-message "cmacs-libreclaw.c"
                  (channel room-id text))
(declare-function cmacs-libreclaw-list-rooms "cmacs-libreclaw" (&optional channel))
(declare-function cmacs-brigade-compose-set "cmacs-brigade-compose" (spec))
(declare-function cmacs-brigade-mailbox-send "cmacs-brigade-mailbox"
                  (id text &optional from))
(declare-function cmacs-brigade-task-list "cmacs-brigade-state.c" ())
(declare-function cmacs-brigade-plan-append-task "cmacs-brigade-plan" (file spec))
(declare-function cmacs-brigade-registry-list "cmacs-brigade-registry" (kind))
(declare-function cmacs-brigade-registry-get "cmacs-brigade-registry" (kind name))
;; `cmacs-brigade-tool' is a cl-struct; these are its accessors.
(declare-function cmacs-brigade-tool-p "cmacs-brigade-registry" (obj))
(declare-function cmacs-brigade-tool-menu "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-menu-label "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-description "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-params "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-handler "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-name "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-async "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-confirm "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-tool-destructive "cmacs-brigade-registry" (tool))
(declare-function cmacs-brigade-register-context-provider
                  "cmacs-brigade-registry" (&rest plist))
(declare-function cmacs-ai-commit--root "cmacs-ai-commit" ())
(declare-function cmacs-ai-suggest-commit-message "cmacs-ai-commit" ())
(defvar cmacs-ai-chat--compose-marker)

(defgroup cmacs-ai-actions nil
  "Actions offered by the cmacs AI menu."
  :group 'cmacs
  :prefix "cmacs-ai-action")

;;;; Groups ------------------------------------------------------------

(defconst cmacs-ai-action-groups
  '((ask     . "Ask AI")
    (chat    . "Chat")
    (brigade . "Brigade")
    (tools   . "Tools"))
  "Submenu groups, in the order they appear.  See the Commentary.")

(defun cmacs-ai-action-group-label (group)
  "The submenu label for GROUP."
  (or (alist-get group cmacs-ai-action-groups)
      (capitalize (symbol-name group))))

;;;; Registry ----------------------------------------------------------

(defvar cmacs-ai--actions (make-hash-table :test 'eq)
  "Registered AI actions, keyed by name symbol.")

(defun cmacs-ai-register-action (&rest plist)
  "Register an AI menu action from PLIST.

Recognised keys:

  :name    symbol identifying the action (required; re-registering the
           same name replaces it, so reloading a file is safe)
  :label   menu text, or a function of the target returning it (required)
  :group   one of `cmacs-ai-action-groups'.  Default `ask'.
  :applies (lambda (TARGET) -> bool).  Default: always.
  :run     (lambda (TARGET)) (required)
  :order   sort key within the group, ascending.  Default 50.
  :help    tooltip text.

The action is responsible for everything it does, including asking the
user anything it needs; it runs from the command loop, so prompting is
fine here in a way it is not inside a resolver."
  (let ((name (plist-get plist :name)))
    (unless name (error "cmacs-ai-actions: an action needs a :name"))
    (unless (plist-get plist :run)
      (error "cmacs-ai-actions: action %s needs a :run" name))
    (unless (plist-get plist :label)
      (error "cmacs-ai-actions: action %s needs a :label" name))
    (puthash name plist cmacs-ai--actions)
    name))

(defun cmacs-ai-unregister-action (name)
  "Remove the action called NAME.  Returns non-nil if it was there."
  (let ((had (gethash name cmacs-ai--actions)))
    (remhash name cmacs-ai--actions)
    (and had t)))

(defun cmacs-ai-action-label (action target)
  "The menu label for ACTION over TARGET."
  (let ((l (plist-get action :label)))
    (if (functionp l) (funcall l target) l)))

(defun cmacs-ai-actions-for (target)
  "Registered actions applying to TARGET, grouped and ordered.

Returns an alist (GROUP . ACTIONS) in `cmacs-ai-action-groups' order,
omitting groups that ended up empty -- an empty submenu is worse than no
submenu."
  (let ((all nil))
    (maphash (lambda (_k v) (push v all)) cmacs-ai--actions)
    (let ((usable
           (seq-filter
            (lambda (a)
              (let ((p (plist-get a :applies)))
                (or (null p)
                    (condition-case err
                        (funcall p target)
                      (error
                       ;; A predicate that signals must not blank the menu.
                       (message "cmacs-ai-actions: %s :applies failed: %s"
                                (plist-get a :name) (error-message-string err))
                       nil)))))
            all))
          (out nil))
      (dolist (g cmacs-ai-action-groups)
        (let ((members
               (sort (seq-filter (lambda (a)
                                   (eq (or (plist-get a :group) 'ask) (car g)))
                                 usable)
                     (lambda (a b)
                       (let ((oa (or (plist-get a :order) 50))
                             (ob (or (plist-get b :order) 50)))
                         (if (= oa ob)
                             (string< (symbol-name (plist-get a :name))
                                      (symbol-name (plist-get b :name)))
                           (< oa ob)))))))
          ;; The Tools group is computed rather than registered: brigade
          ;; tools come and go as your init reloads, and mirroring them
          ;; into this registry would mean keeping two copies in step.
          (when (eq (car g) 'tools)
            (setq members
                  (append members (cmacs-ai-actions--tool-actions target))))
          (when members (push (cons (car g) members) out))))
      (nreverse out))))

(defun cmacs-ai-action-run (action target)
  "Run ACTION over TARGET."
  (funcall (plist-get action :run) target))

;;;; Shared predicates -------------------------------------------------

(defun cmacs-ai-actions--ai-p ()
  "Non-nil when the cmacs-ai C subsystem is available.

Asks the C primitive, NOT `cmacs-ai--available-p'.  The Elisp side of
cmacs-ai loads lazily -- `cmacs-ai-load-all' runs on the first
`M-x cmacs-ai-chat' -- so a predicate that needs cmacs-ai.el to be loaded
reports \"no AI here\" on a fresh session and quietly empties the menu
until you have used cmacs-ai some other way first.  `cmacs-ai-supported-p'
is a DEFUN and is bound from startup in any --with-cmacs-ai build."
  (and (fboundp 'cmacs-ai-supported-p)
       (ignore-errors (cmacs-ai-supported-p))))

(defun cmacs-ai-actions--library-p (feature)
  "Non-nil when FEATURE is loaded or loadable.

The right test for an action whose :run does `(require FEATURE)'.
Testing `fboundp' of a function that lives in a lazily-loaded file is the
trap: cmacs-ai, gsurf, imgedit and the brigade all defer most of their
Elisp, so an :applies written that way hides the action until something
else happens to load the file -- which, for a menu whose whole job is to
be the first thing you reach for, means it is missing exactly when you
want it."
  (or (featurep feature)
      (and (locate-library (symbol-name feature)) t)))

(defun cmacs-ai-actions--textual-p (target)
  "Non-nil when TARGET has something a model can read.
File-backed targets count: the content is fetched on demand, so a menu
built over a thousand marked files still costs nothing to build."
  (and (cmacs-ai-actions--ai-p)
       (or (cmacs-ai-target-text target)
           (let ((f (cmacs-ai-target-file target)))
             (and f (file-readable-p f) (not (file-directory-p f)))))))

(defun cmacs-ai-actions--editable-p (target)
  "Non-nil when TARGET names a live, writable span of a buffer."
  (and (cmacs-ai-actions--ai-p)
       (cmacs-ai-target-bounds target)
       (let ((buf (cmacs-ai-target-buffer target)))
         (and (buffer-live-p buf)
              (with-current-buffer buf (not buffer-read-only))))))

(defun cmacs-ai-actions--brigade-p ()
  "Non-nil when ai-brigade is available to compose a task."
  (cmacs-ai-actions--library-p 'cmacs-brigade-compose))

;;;; Ask group ---------------------------------------------------------
;;
;; All five run through `cmacs-ai-textops-run', so they share one prompt
;; style, one result window, and one cancel path.

(dolist (spec '((ask       . 10)
                (summarize . 20)
                (rephrase  . 30)
                (reply     . 40)
                (explain   . 50)))
  (let ((op (car spec)) (order (cdr spec)))
    (cmacs-ai-register-action
     :name (intern (format "cmacs-ai-%s" op))
     :group 'ask
     :order order
     :label (pcase op
              ('ask "Ask about this...")
              ('summarize "Summarize...")
              ('rephrase "Rephrase...")
              ('reply "Reply...")
              ('explain "Explain..."))
     :help (format "%s this with cmacs-ai, in a result window"
                   (capitalize (symbol-name op)))
     :applies #'cmacs-ai-actions--textual-p
     :run (lambda (target) (cmacs-ai-textops-run op target)))))

(cmacs-ai-register-action
 :name 'cmacs-ai-rewrite-in-place
 :group 'ask :order 60
 :label "Rewrite in place..."
 :help "Replace this text with an AI rewrite (one undo step)"
 :applies #'cmacs-ai-actions--editable-p
 :run
 (lambda (target)
   ;; The one Ask action that touches your buffer, so it is spelled
   ;; differently from "Rephrase" (which only shows you the result) and
   ;; keeps using the existing region command, undo boundary and all.
   (require 'cmacs-ai-region)
   (let ((buf (cmacs-ai-target-buffer target))
         (bounds (cmacs-ai-target-bounds target)))
     (with-current-buffer buf
       (save-excursion
         (goto-char (car bounds))
         (set-mark (cdr bounds))
         (activate-mark)
         (call-interactively #'cmacs-ai-rewrite-region))))))

(cmacs-ai-register-action
 :name 'cmacs-ai-commit-draft
 :group 'ask :order 12
 :label "Draft a commit message"
 :help "Draft one from the diff and this project's recent commit style"
 :applies
 (lambda (target)
   ;; Keyed on the BUFFER, not the target kind: the useful place for this
   ;; is magit-status, where the target under the pointer is a hunk, a
   ;; file heading, or nothing in particular.  What matters is that you
   ;; are looking at a repository.
   (and (cmacs-ai-actions--ai-p)
        (cmacs-ai-actions--library-p 'cmacs-ai-commit)
        (buffer-live-p (cmacs-ai-target-buffer target))
        (with-current-buffer (cmacs-ai-target-buffer target)
          (and (or (derived-mode-p 'magit-status-mode 'magit-diff-mode
                                   'magit-revision-mode 'magit-stash-mode
                                   'diff-mode 'vc-dir-mode 'vc-diff-mode
                                   'log-edit-mode 'vc-git-log-edit-mode)
                   (bound-and-true-p git-commit-mode))
               ;; `cmacs-ai-commit--root', not `vc-root-dir': the latter
               ;; answers nil in a magit-status buffer, which would hide
               ;; this entry exactly where it belongs.
               (and (fboundp 'cmacs-ai-commit--root)
                    (cmacs-ai-commit--root) t)))))
 :run
 (lambda (target)
   (require 'cmacs-ai-commit)
   (with-current-buffer (cmacs-ai-target-buffer target)
     (cmacs-ai-suggest-commit-message))))

(cmacs-ai-register-action
 :name 'cmacs-ai-document
 :group 'ask :order 70
 :label "Document this"
 :help "Insert an AI-written documentation comment above"
 :applies
 (lambda (target)
   (and (cmacs-ai-actions--editable-p target)
        (cmacs-ai-actions--library-p 'cmacs-ai-region)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (derived-mode-p 'prog-mode))))
 :run
 (lambda (target)
   (require 'cmacs-ai-region)
   (let ((bounds (cmacs-ai-target-bounds target)))
     (with-current-buffer (cmacs-ai-target-buffer target)
       (save-excursion
         (goto-char (car bounds))
         (set-mark (cdr bounds))
         (activate-mark)
         (cmacs-ai-doc-region))))))

(cmacs-ai-register-action
 :name 'cmacs-ai-generate-test
 :group 'ask :order 75
 :label "Generate a test for this"
 :applies
 (lambda (target)
   (and (cmacs-ai-actions--textual-p target)
        (cmacs-ai-actions--library-p 'cmacs-ai-region)
        (cmacs-ai-target-bounds target)
        (buffer-live-p (cmacs-ai-target-buffer target))
        (with-current-buffer (cmacs-ai-target-buffer target)
          (derived-mode-p 'prog-mode))))
 :run
 (lambda (target)
   (require 'cmacs-ai-region)
   (let ((bounds (cmacs-ai-target-bounds target)))
     (with-current-buffer (cmacs-ai-target-buffer target)
       (save-excursion
         (goto-char (car bounds))
         (set-mark (cdr bounds))
         (activate-mark)
         (cmacs-ai-test-region))))))

;; gsurf's page body only arrives asynchronously, so the browser gets its
;; own two entries rather than being forced through the generic path.
(cmacs-ai-register-action
 :name 'cmacs-ai-gsurf-summarize
 :group 'ask :order 15
 :label "Summarize this page"
 :applies (lambda (target)
            (and (eq (cmacs-ai-target-kind target) 'gsurf-page)
                 (cmacs-ai-actions--library-p 'cmacs-gsurf-ai)))
 :run (lambda (target)
        (require 'cmacs-gsurf-ai)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-gsurf-summarize))))

(cmacs-ai-register-action
 :name 'cmacs-ai-gsurf-ask
 :group 'ask :order 16
 :label "Ask about this page..."
 :applies (lambda (target)
            (and (eq (cmacs-ai-target-kind target) 'gsurf-page)
                 (cmacs-ai-actions--library-p 'cmacs-gsurf-ai)))
 :run (lambda (target)
        (require 'cmacs-gsurf-ai)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (call-interactively #'cmacs-gsurf-ask))))

(cmacs-ai-register-action
 :name 'cmacs-ai-imgedit-describe
 :group 'ask :order 15
 :label "Describe this image"
 :applies (lambda (target)
            (and (eq (cmacs-ai-target-kind target) 'image)
                 (cmacs-ai-actions--library-p 'cmacs-imgedit-ai)
                 (with-current-buffer (cmacs-ai-target-buffer target)
                   (derived-mode-p 'cmacs-imgedit-mode))))
 :run (lambda (target)
        (require 'cmacs-imgedit-ai)
        (with-current-buffer (cmacs-ai-target-buffer target)
          (cmacs-imgedit-ai-describe))))

;;;; Chat group --------------------------------------------------------

(defcustom cmacs-ai-actions-chat-preamble
  "For context, here is what I am looking at:"
  "Line introducing a target pasted into a chat compose area."
  :type 'string)

(defun cmacs-ai-actions--chat-payload (target)
  "The block of text carried into a chat for TARGET."
  (format "%s\n\n#+begin_example\n%s\n#+end_example\n"
          cmacs-ai-actions-chat-preamble
          (cmacs-ai-target-prompt-context target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-chat-new-with
 :group 'chat :order 10
 :label "New chat with this"
 :help "Open a cmacs-ai chat with this pasted into the compose area"
 :applies (lambda (target)
            (and (cmacs-ai-actions--textual-p target)
                 (cmacs-ai-actions--library-p 'cmacs-ai-chat)))
 :run
 (lambda (target)
   (require 'cmacs-ai-chat)
   (let ((payload (cmacs-ai-actions--chat-payload target)))
     (cmacs-ai-chat-open)
     ;; Seeded into the compose area, NOT sent.  You still get to say
     ;; what you actually want before anything is spent.
     (cmacs-ai-actions--insert-in-compose payload))))

(defun cmacs-ai-actions--insert-in-compose (text)
  "Insert TEXT at the end of the current chat buffer's compose area."
  (when (bound-and-true-p cmacs-ai-chat--compose-marker)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert text)
    (goto-char (point-max))))

(cmacs-ai-register-action
 :name 'cmacs-ai-chat-send-to-open
 :group 'chat :order 20
 :label "Send to an open chat..."
 :applies
 (lambda (target)
   (and (cmacs-ai-actions--textual-p target)
        (seq-some (lambda (b)
                    (with-current-buffer b (derived-mode-p 'cmacs-ai-chat-mode)))
                  (buffer-list))))
 :run
 (lambda (target)
   (let* ((chats (seq-filter
                  (lambda (b)
                    (with-current-buffer b
                      (derived-mode-p 'cmacs-ai-chat-mode)))
                  (buffer-list)))
          (pick (completing-read "Chat buffer: " (mapcar #'buffer-name chats)
                                 nil t)))
     (with-current-buffer (get-buffer pick)
       (cmacs-ai-actions--insert-in-compose
        (cmacs-ai-actions--chat-payload target))
       (pop-to-buffer (current-buffer))))))

(cmacs-ai-register-action
 :name 'cmacs-ai-libreclaw-send
 :group 'chat :order 30
 :label "Send to a libreclaw room..."
 :help "Post this into one of your libreclaw rooms"
 :applies (lambda (target)
            (and (cmacs-ai-actions--textual-p target)
                 ;; The DEFUN is bound from startup in a libreclaw build;
                 ;; the room list is lazily-loaded Elisp.
                 (fboundp 'cmacs-libreclaw-send-message)
                 (cmacs-ai-actions--library-p 'cmacs-libreclaw)))
 :run
 (lambda (target)
   (require 'cmacs-libreclaw)
   (let* ((rooms (ignore-errors (cmacs-libreclaw-list-rooms)))
          (choices
           ;; `cmacs-libreclaw-list-rooms' yields per-channel room
           ;; descriptors; accept both the plist and bare-string shapes
           ;; rather than assume one, since the channel plugins differ.
           (mapcar (lambda (r)
                     (cond
                      ((stringp r) (cons r (list :channel nil :room r)))
                      ((consp r)
                       (cons (format "%s / %s"
                                     (or (plist-get r :channel) "?")
                                     (or (plist-get r :name)
                                         (plist-get r :id) "?"))
                             r))))
                   rooms)))
     (unless choices
       (user-error "cmacs-ai: no libreclaw rooms available"))
     (let* ((pick (completing-read "Room: " (mapcar #'car choices) nil t))
            (room (cdr (assoc pick choices)))
            (text (read-string "Message (RET to send the context alone): "
                               nil nil "")))
       (cmacs-libreclaw-send-message
        (plist-get room :channel)
        (or (plist-get room :id) (plist-get room :room))
        (if (string-empty-p (string-trim text))
            (cmacs-ai-actions--chat-payload target)
          (concat text "\n\n" (cmacs-ai-actions--chat-payload target))))
       (message "cmacs-ai: sent to %s" pick)))))

;;;; Brigade group -----------------------------------------------------

(defcustom cmacs-ai-actions-spawn-prompt
  "Ask an agent to (RET for \"work on this\"): "
  "Minibuffer prompt when composing a task from a target."
  :type 'string)

(defvar cmacs-ai-actions--spawn-history nil)

(cmacs-ai-register-action
 :name 'cmacs-ai-brigade-spawn
 :group 'brigade :order 10
 :label "Spawn an agent on this..."
 :help "Fill in the brigade compose menu with this as the task context"
 :applies (lambda (_target) (cmacs-ai-actions--brigade-p))
 :run
 (lambda (target)
   (require 'cmacs-brigade-compose)
   (let* ((what (read-string cmacs-ai-actions-spawn-prompt nil
                             'cmacs-ai-actions--spawn-history))
          (what (if (string-empty-p (string-trim what))
                    "Work on this."
                  (string-trim what)))
          (dir (or (and (cmacs-ai-target-file target)
                        (file-name-directory (cmacs-ai-target-file target)))
                   (and (buffer-live-p (cmacs-ai-target-buffer target))
                        (with-current-buffer (cmacs-ai-target-buffer target)
                          default-directory))
                   default-directory)))
     ;; COMPOSE, never create: this shows you the transient with
     ;; everything filled in and waits.  See the Commentary.
     (cmacs-brigade-compose-set
      (list :title (format "%s: %s"
                           (cmacs-ai-target-kind target)
                           (cmacs-ai-target-describe target))
            :prompt (format "%s\n\n%s" what
                            (cmacs-ai-target-prompt-context target))
            :cwd dir)))))

(cmacs-ai-register-action
 :name 'cmacs-ai-brigade-send
 :group 'brigade :order 20
 :label "Send to a running task..."
 :help "Add this to a task's mailbox; it is picked up at the next turn"
 :applies
 (lambda (target)
   (and (cmacs-ai-actions--textual-p target)
        (cmacs-ai-actions--library-p 'cmacs-brigade-mailbox)
        ;; `cmacs-brigade-task-list' is a DEFUN; no tasks means nothing
        ;; to send to, so the entry stays off the menu entirely.
        (fboundp 'cmacs-brigade-task-list)
        (ignore-errors (and (cmacs-brigade-task-list) t))))
 :run
 (lambda (target)
   (require 'cmacs-brigade-mailbox)
   (let* ((records (cmacs-brigade-task-list))
          (choices (mapcar (lambda (r)
                             (cons (format "%s  %s  [%s]"
                                           (plist-get r :id)
                                           (or (plist-get r :title) "")
                                           (or (plist-get r :state) ""))
                                   (plist-get r :id)))
                           records)))
     (unless choices (user-error "cmacs-ai: no brigade tasks"))
     (let* ((pick (completing-read "Task: " (mapcar #'car choices) nil t))
            (id (cdr (assoc pick choices)))
            (note (read-string "Say what about it? (RET for just the context): "
                               nil nil "")))
       (cmacs-brigade-mailbox-send
        id
        (if (string-empty-p (string-trim note))
            (cmacs-ai-target-prompt-context target)
          (concat note "\n\n" (cmacs-ai-target-prompt-context target)))
        "menu")
       (message "cmacs-ai: queued for %s" id)))))

;; A pinned-context list served through the brigade's own
;; `context-provider' registry, so anything pinned here is injected into
;; every agent start without a single line of special-casing in the run
;; path.
(defvar cmacs-ai-actions--pinned nil
  "Targets pinned as ambient context for brigade agents, newest first.")

(defcustom cmacs-ai-actions-pinned-max 8
  "How many pinned context items to keep.
Pinning is meant to be a scratchpad, not an archive: past this many the
oldest falls off, because an agent prompt that silently grows without
bound is a cost problem before it is a quality problem."
  :type 'integer
  :safe #'integerp)

(cmacs-ai-register-action
 :name 'cmacs-ai-brigade-pin
 :group 'brigade :order 30
 :label "Pin as agent context"
 :help "Include this in the context of every agent that starts from now"
 :applies (lambda (target)
            (and (cmacs-ai-actions--textual-p target)
                 (cmacs-ai-actions--library-p 'cmacs-brigade-registry)))
 :run
 (lambda (target)
   (push (cons (cmacs-ai-target-describe target)
               (cmacs-ai-target-prompt-context target))
         cmacs-ai-actions--pinned)
   (when (> (length cmacs-ai-actions--pinned) cmacs-ai-actions-pinned-max)
     (setq cmacs-ai-actions--pinned
           (seq-take cmacs-ai-actions--pinned cmacs-ai-actions-pinned-max)))
   (cmacs-ai-actions-install-context-provider)
   (message "cmacs-ai: pinned %s (%d pinned; M-x cmacs-ai-unpin-all to clear)"
            (cmacs-ai-target-describe target)
            (length cmacs-ai-actions--pinned))))

(defun cmacs-ai-actions-install-context-provider ()
  "Register the pinned-context provider with the brigade, once."
  (when (fboundp 'cmacs-brigade-register-context-provider)
    (cmacs-brigade-register-context-provider
     :name 'menu-pinned
     :order 60
     :provide
     (lambda (_agent)
       (when cmacs-ai-actions--pinned
         (concat "Pinned context (from the cmacs AI menu):\n\n"
                 (mapconcat #'cdr (reverse cmacs-ai-actions--pinned)
                            "\n\n")))))))

;;;###autoload
(defun cmacs-ai-unpin-all ()
  "Forget everything pinned as ambient agent context."
  (interactive)
  (setq cmacs-ai-actions--pinned nil)
  (message "cmacs-ai: pinned context cleared"))

(defcustom cmacs-ai-actions-plan-file nil
  "Plan file that \"Make this a brigade task\" appends to.
nil means ask each time."
  :type '(choice (const :tag "Ask" nil) file))

(cmacs-ai-register-action
 :name 'cmacs-ai-brigade-make-task
 :group 'brigade :order 40
 :label "Make this a brigade task"
 :help "Append this to a plan file as a task, without starting it"
 :applies
 (lambda (target)
   (and (cmacs-ai-actions--library-p 'cmacs-brigade-plan)
        (memq (cmacs-ai-target-kind target) '(org-node region file diagnostic))))
 :run
 (lambda (target)
   (require 'cmacs-brigade-plan)
   (let* ((file (or cmacs-ai-actions-plan-file
                    (read-file-name "Plan file: " nil nil nil "plan.org")))
          (id (cmacs-brigade-plan-append-task
               file
               (list :title (cmacs-ai-target-describe target)
                     :prompt (cmacs-ai-target-prompt-context target)))))
     ;; Created, not queued and not started -- the same discipline the
     ;; compose path keeps.
     (message "cmacs-ai: created %s in %s (not started)"
              id (file-name-nondirectory file)))))

;;;; Tools group -------------------------------------------------------
;;
;; The extension surface the brigade already promises: one
;; `cmacs-brigade-deftool' form publishes a capability to in-process
;; agents, CLI agents over the MCP relay, and external MCP clients.  With
;; :menu it also gets a right-click entry, with no second registration
;; and no menu-specific code in the tool itself.

(defcustom cmacs-ai-actions-tool-max 12
  "Most brigade tools shown in the menu's Tools submenu.
A registry with fifty tools in it would produce a menu nobody can use."
  :type 'integer
  :safe #'integerp)

(defun cmacs-ai-actions--menu-tools ()
  "Registered brigade tools that asked to appear in the menu."
  (when (and (fboundp 'cmacs-brigade-registry-list)
             (fboundp 'cmacs-brigade-registry-get)
             (fboundp 'cmacs-brigade-tool-menu))
    (let ((out nil))
      (dolist (name (ignore-errors (cmacs-brigade-registry-list 'tool)))
        (let ((tool (cmacs-brigade-registry-get 'tool name)))
          (when (and (cmacs-brigade-tool-p tool)
                     (cmacs-brigade-tool-menu tool))
            (push (cons name tool) out))))
      (seq-take (nreverse out) cmacs-ai-actions-tool-max))))

(defun cmacs-ai-actions--tool-actions (target)
  "Menu actions for the brigade tools that opted in, applicable to TARGET."
  (let ((out nil) (order 10))
    (dolist (entry (cmacs-ai-actions--menu-tools))
      (let* ((name (car entry))
             (tool (cdr entry))
             (menu (cmacs-brigade-tool-menu tool))
             ;; :menu t means "offer it on anything"; :menu (KIND...)
             ;; restricts it to those target kinds.
             (kinds (and (consp menu) menu)))
        (when (or (null kinds)
                  (memq (cmacs-ai-target-kind target) kinds))
          (push (list :name (intern (format "cmacs-ai-tool-%s" name))
                      :group 'tools
                      :order order
                      :label (or (cmacs-brigade-tool-menu-label tool)
                                 (format "%s" name))
                      :help (cmacs-brigade-tool-description tool)
                      :run (let ((tool tool))
                             (lambda (tg) (cmacs-ai-actions--run-tool tool tg))))
                out)
          (setq order (+ order 10)))))
    (nreverse out)))

(defun cmacs-ai-actions--run-tool (tool target)
  "Invoke brigade TOOL with TARGET's context as its first parameter.

The tool's own params decide what it is called with: the first receives
the rendered target, and anything else is read from the minibuffer.
Tools marked :confirm or :destructive are confirmed first -- a menu click
must not be a quieter way to do something the tool itself considers worth
asking about.

Asynchronous tools are not offered here: their handler takes a DONE
callback rather than returning, and pretending otherwise would print the
callback instead of the answer."
  (let* ((params (cmacs-brigade-tool-params tool))
         (handler (cmacs-brigade-tool-handler tool))
         (name (cmacs-brigade-tool-name tool)))
    (unless (functionp handler)
      (user-error "cmacs-ai: tool %s has no handler" name))
    (when (cmacs-brigade-tool-async tool)
      (user-error "cmacs-ai: %s is asynchronous; run it from an agent" name))
    (when (or (cmacs-brigade-tool-destructive tool)
              (cmacs-brigade-tool-confirm tool))
      (unless (yes-or-no-p (format "Run %s on %s? "
                                   name (cmacs-ai-target-describe target)))
        (user-error "cmacs-ai: cancelled")))
    (let ((args nil) (first t))
      (dolist (p params)
        ;; Params are normalised plists by the time they are in the
        ;; registry (see `cmacs-brigade--parse-param'), not raw specs.
        (let ((pname (plist-get p :name)) (doc (plist-get p :doc)))
          (push (if first
                    (progn (setq first nil)
                           (cmacs-ai-target-prompt-context target))
                  (read-string (format "%s (%s): " pname (or doc "")) nil nil ""))
                args)))
      (let* ((result (apply handler (nreverse args)))
             (buf (cmacs-ai-output-buffer (format "%s" name)
                                          (cmacs-ai-target-describe target))))
        (cmacs-ai-output-append buf (format "%s" result))
        (cmacs-ai-output-finish buf nil)
        (cmacs-ai-output-show buf)))))

;;;; Commands ----------------------------------------------------------
;;
;; The menu can run any registered action, because it holds the action
;; plist.  A keybinding cannot: `define-key' wants a command, and an
;; action is an entry in a hash table.  So every shipped action also gets
;; a real named command -- bindable, `M-x'-able, and discoverable in
;; `apropos' -- and anything registered later is still reachable through
;; `cmacs-ai-run-action' and the group pickers.

(defun cmacs-ai-action-names (&optional group)
  "Names of registered actions, optionally only those in GROUP."
  (let ((out nil))
    (maphash (lambda (k v)
               (when (or (null group)
                         (eq (or (plist-get v :group) 'ask) group))
                 (push k out)))
             cmacs-ai--actions)
    (sort out (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

;;;###autoload
(defun cmacs-ai-run-action (name &optional target)
  "Run the registered AI action NAME on TARGET.

TARGET defaults to whatever is at point -- which, because the region
resolver runs first, means the highlighted text whenever there is any.
Interactively, completes over every registered action."
  (interactive
   (list (intern (completing-read "AI action: "
                                  (mapcar #'symbol-name (cmacs-ai-action-names))
                                  nil t))))
  (let ((action (gethash name cmacs-ai--actions))
        (target (or target (cmacs-ai-target-at))))
    (unless action
      (user-error "cmacs-ai: no action called %s" name))
    (unless target
      (user-error "cmacs-ai: nothing here to act on"))
    ;; Honour :applies rather than charging ahead: "Rewrite in place" on a
    ;; read-only buffer would otherwise fail somewhere less explicable
    ;; than here.
    (let ((p (plist-get action :applies)))
      (when (and p (not (ignore-errors (funcall p target))))
        (user-error "cmacs-ai: %s does not apply to %s"
                    name (cmacs-ai-target-describe target))))
    (cmacs-ai-action-run action target)))

(defmacro cmacs-ai-define-action-command (command action docstring)
  "Define COMMAND as an interactive wrapper running ACTION at point.

Each call site carries its own explicit `autoload' cookie.  A
`;;;###autoload' inside this macro body would do nothing: the autoload
scraper reads source text and never expands macros, so it would see the
cookie here once and the call sites never."
  (declare (indent 2) (doc-string 3))
  `(defun ,command ()
     ,docstring
     (interactive)
     (cmacs-ai-run-action ',action)))

;; The Ask group already has commands of its own (`cmacs-ai-summarize'
;; and friends in cmacs-ai-textops.el, `cmacs-ai-rewrite-region' and
;; friends in cmacs-ai-region.el).  These are the ones that existed only
;; as menu entries.

;;;###autoload (autoload 'cmacs-ai-chat-with-this "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-chat-with-this
    cmacs-ai-chat-new-with
  "Open a cmacs-ai chat seeded with whatever is at point.
Seeded into the compose area, not sent.")

;;;###autoload (autoload 'cmacs-ai-send-to-open-chat "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-send-to-open-chat
    cmacs-ai-chat-send-to-open
  "Paste whatever is at point into an already-open cmacs-ai chat.")

;;;###autoload (autoload 'cmacs-ai-send-to-libreclaw "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-send-to-libreclaw
    cmacs-ai-libreclaw-send
  "Post whatever is at point into one of your libreclaw rooms.")

;;;###autoload (autoload 'cmacs-ai-spawn-agent "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-spawn-agent
    cmacs-ai-brigade-spawn
  "Compose a brigade task from whatever is at point.
Fills in the compose transient and shows it; starts nothing.")

;;;###autoload (autoload 'cmacs-ai-send-to-task "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-send-to-task
    cmacs-ai-brigade-send
  "Add whatever is at point to a running brigade task's mailbox.")

;;;###autoload (autoload 'cmacs-ai-pin-context "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-pin-context
    cmacs-ai-brigade-pin
  "Pin whatever is at point as ambient context for future agents.
Clear the pins again with `cmacs-ai-unpin-all'.")

;;;###autoload (autoload 'cmacs-ai-make-brigade-task "cmacs-ai-actions" nil t)
(cmacs-ai-define-action-command cmacs-ai-make-brigade-task
    cmacs-ai-brigade-make-task
  "Append whatever is at point to a plan file as a task, without starting it.")

(provide 'cmacs-ai-actions)

;;; cmacs-ai-actions.el ends here
