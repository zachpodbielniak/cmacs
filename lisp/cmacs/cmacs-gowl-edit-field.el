;;; cmacs-gowl-edit-field.el --- Edit any application's text field in Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; With the keyboard in a text field of ANY window -- a browser's
;; comment box, a chat client, a form -- `cmacs-gowl-edit-field' pops
;; that field's text into an Emacs buffer; `C-c C-c' puts the edited
;; text back, `C-c C-k' gives up.  In between, the whole of cmacs
;; applies to text that lives in somebody else's program: evil,
;; snippets, spell checking, the AI region commands.
;;
;; It needs `cmacs --gowl': Emacs has to be the compositor, because only
;; the compositor sits between an application and its input method.
;;
;; HOW THE TEXT TRAVELS.  An application with a text field describes it
;; to the compositor over text-input-v3 so an input method can work: the
;; text around the cursor, where the cursor is, what is selected.  gowl
;; reads that (`gowl-text-field-read') and answers the way an input
;; method does, with one "delete this much around the cursor, insert
;; this" (`gowl-text-field-replace').  No keys are typed and the
;; clipboard is not touched, so any character arrives intact and the
;; application sees one edit it can undo as one.
;;
;; WHAT IS NOT KNOWABLE.  The protocol caps the text an application
;; reports at 4000 bytes, and a field holding more sends a window around
;; the cursor.  Text near that cap is treated as a window, and the
;; header line says so before anything is typed ("editing the N bytes
;; around the cursor").  Text under the cap is only "all the application
;; chose to send": some multi-line widgets report the paragraph around
;; the cursor rather than the field.  Either way only the text that was
;; read is ever replaced, so a commit cannot damage what Emacs never
;; saw.
;;
;; THE EDITOR WINDOW.  The buffer is shown in a frame of its own, named
;; `cmacs-gowl-edit-field-frame-name', which a gowl window rule floats
;; BEFORE its first placement -- so the tiled layout never reflows, on
;; the way in or on the way out.  (The pre-map hook cannot do this: it
;; runs on the Lisp thread, after the window has been placed once.)  The
;; frame is then centred over the window it is editing.
;;
;; THE FALLBACK.  A window with no text input (X11 programs, some
;; toolkits) can be reached through the clipboard instead: select all,
;; copy, edit, select all, paste.  It is best effort, visible in the
;; application, and never used on a terminal, where Ctrl+C means
;; something else.  See `cmacs-gowl-edit-field-fallback'.
;;
;; NOTHING BLOCKS.  Under `cmacs --gowl' this thread is the desktop's:
;; every wait here -- for the application's answer, for focus to land,
;; for a copy to arrive -- is a callback or a timer, never a loop.
;;
;; Setup, in an init file:
;;
;;   (add-hook 'cmacs-gowl-mode-hook #'cmacs-gowl-edit-field-setup)
;;
;; which binds `cmacs-gowl-edit-field-key' (Super+Ctrl+e) in the
;; compositor.  Nothing is bound until that function is called.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-focused-client "cmacs-gowl")
(declare-function gowl-focus-client "cmacs-gowl")
(declare-function gowl-list-clients "cmacs-gowl")
(declare-function gowl-client-info "cmacs-gowl")
(declare-function gowl-client-pid "cmacs-gowl")
(declare-function gowl-client-set-geometry "cmacs-gowl")
(declare-function gowl-set-client-floating "cmacs-gowl")
(declare-function gowl-usable-area "cmacs-gowl")
(declare-function gowl-add-rule-entry "cmacs-gowl")
(declare-function gowl-remove-rule "cmacs-gowl")
(declare-function gowl-add-keybind "cmacs-gowl")
(declare-function gowl-remove-keybind "cmacs-gowl")
(declare-function gowl-clipboard-get "cmacs-gowl")
(declare-function gowl-text-field-read "cmacs-gowl-textfield")
(declare-function gowl-text-field-replace "cmacs-gowl-textfield")
(declare-function gowl-text-field-send-key "cmacs-gowl-textfield")
(declare-function gowl-clipboard-set-transient "cmacs-gowl-textfield")
(declare-function evil-insert-state "ext:evil-states")

(defvar cmacs-gowl-focus-changed-functions)
(defvar cmacs-gowl-client-removed-functions)

;;;; Options

(defgroup cmacs-gowl-edit-field nil
  "Edit another application's text field in an Emacs buffer."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-edit-field-")

(defcustom cmacs-gowl-edit-field-key "Super+Ctrl+e"
  "The gowl key that runs `cmacs-gowl-edit-field', or nil for none.
Bound by `cmacs-gowl-edit-field-setup', and by nothing else.  Super+e is
the bar's AI rewrite and Super+Alt+e gabbrev's search, hence the chord."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-major-mode #'text-mode
  "The major mode of an edit-field buffer.
`cmacs-gowl-edit-field-mode-alist' is tried first."
  :type 'function
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-mode-alist
  '(("discord\\|vesktop\\|element\\|fractal\\|slack\\|signal\\|telegram\
\\|zulip\\|mattermost\\|matrix" . markdown-mode))
  "Major modes by application: an alist of (APP-ID-REGEXP . MODE).
The first entry whose regexp matches the window's app-id, ignoring case,
and whose MODE is defined, wins; otherwise
`cmacs-gowl-edit-field-major-mode' is used.  The default writes chat
messages as Markdown when `markdown-mode' is installed."
  :type '(alist :key-type regexp :value-type function)
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-deny
  '("keepass" "bitwarden" "1password" "lastpass" "enpass"
    "proton[-. ]?pass" "seahorse" "org\\.gnome\\.World\\.Secrets"
    "pinentry" "polkit" "gcr-prompter" "gowl-lock" "swaylock"
    "screen ?lock" "password")
  "Windows whose text fields are never read or written.
A list of regexps matched, ignoring case, against a window's app-id and
its title: password managers, password prompts, the lock screen.  It
applies to the text-input path and to the clipboard fallback alike.  A
field the application itself marks as a password or PIN is refused
whatever this says."
  :type '(repeat regexp)
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-fallback 'clipboard
  "What to do with a window that cannot be reached through text-input.
`clipboard': select all and copy in the application, and on commit
select all and paste, with the clipboard put back afterwards.  Best
effort -- it trusts the application to treat Ctrl+A, Ctrl+C and Ctrl+V
the usual way, the selection is visible, and the copy passes through
the clipboard like any other.  nil: report that the field cannot be
read and do nothing."
  :type '(choice (const :tag "Through the clipboard" clipboard)
                 (const :tag "No fallback" nil))
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-fallback-deny
  '("\\`\\(?:gst\\|st\\|st-256color\\|foot\\(?:client\\)?\\|xterm\\|urxvt\\)\\'"
    "terminal" "console" "konsole" "kitty" "alacritty" "ptyxis"
    "wezterm" "ghostty" "\\`tui\\.")
  "Windows the clipboard fallback is never used on.
A list of regexps matched, ignoring case, against the app-id.  In a
terminal Ctrl+C interrupts the program and Ctrl+A is the shell's, so
the fallback would do harm there."
  :type '(repeat regexp)
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-partial-action 'window
  "What to do when only a window of the field's text could be read.
`window': edit that window (the header line says how much it is), and
replace only it.  `fallback': fetch the whole field with
`cmacs-gowl-edit-field-fallback' instead, where that is allowed."
  :type '(choice (const :tag "Edit the part that was read" window)
                 (const :tag "Use the fallback" fallback))
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-verify t
  "Non-nil reads the field again before writing it.
The edit is \"delete N bytes around the cursor, insert this\": if the
field changed while its text was in Emacs, those bytes are no longer
the ones that were read.  With this on, a field that changed is not
overwritten -- the header line says so, and a second `C-c C-c'
overwrites it knowingly."
  :type 'boolean
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-frame-name "cmacs-edit-field"
  "The name, and so the window title, of the editor frame.
A gowl window rule floats windows with exactly this title."
  :type 'string
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-frame-width 100
  "The editor frame's width, in columns."
  :type 'natnum
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-frame-height 24
  "The editor frame's height, in lines."
  :type 'natnum
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-frame-minibuffer t
  "The editor frame's `minibuffer' parameter.
t gives it a minibuffer of its own; nil borrows the main frame's, which
then shows this frame's prompts in another window."
  :type '(choice (const :tag "Its own" t) (const :tag "The main frame's" nil))
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-frame-parameters nil
  "Extra frame parameters for the editor frame, an alist.
They win over the ones this file sets, except `name', which the float
rule depends on (see `cmacs-gowl-edit-field-frame-name')."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-focus-timeout 1.0
  "Seconds to wait for a window to take the keyboard before giving up."
  :type 'number
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-key-delay 0.15
  "Seconds the clipboard fallback gives the application to act on a key."
  :type 'number
  :group 'cmacs-gowl-edit-field)

(defcustom cmacs-gowl-edit-field-evil-insert t
  "Non-nil starts an edit-field buffer in evil's insert state."
  :type 'boolean
  :group 'cmacs-gowl-edit-field)

(defface cmacs-gowl-edit-field-note
  '((t :inherit warning))
  "Face for what the header line of an edit-field buffer warns about."
  :group 'cmacs-gowl-edit-field)

;;;; Pure helpers: bytes and characters
;;
;; The compositor speaks bytes of UTF-8 -- that is what text-input-v3
;; carries -- and a buffer speaks characters.  Everything that crosses
;; goes through these.

(defsubst cmacs-gowl-edit-field--utf8-char-length (char)
  "Return how many bytes CHAR takes in UTF-8."
  (cond ((< char #x80) 1)
        ((< char #x800) 2)
        ((< char #x10000) 3)
        (t 4)))

(defun cmacs-gowl-edit-field--utf8-length (string &optional start end)
  "Return the UTF-8 length in bytes of STRING, or of its START..END part."
  (let ((i (or start 0))
        (end (or end (length string)))
        (bytes 0))
    (while (< i end)
      (setq bytes (+ bytes (cmacs-gowl-edit-field--utf8-char-length
                            (aref string i)))
            i (1+ i)))
    bytes))

(defun cmacs-gowl-edit-field--byte-to-char (text byte)
  "Return the index of the character at UTF-8 offset BYTE in TEXT.
An offset inside a character is taken as the start of that character,
and one past the end as the end: an application's offsets are not
trusted further than that."
  (let ((i 0)
        (n (length text))
        (seen 0)
        (done nil))
    (while (and (not done) (< i n))
      (let ((next (+ seen (cmacs-gowl-edit-field--utf8-char-length
                           (aref text i)))))
        (if (> next byte)
            (setq done t)
          (setq seen next
                i (1+ i)))))
    i))

(defun cmacs-gowl-edit-field--char-to-byte (text index)
  "Return the UTF-8 offset in bytes of the character at INDEX in TEXT."
  (cmacs-gowl-edit-field--utf8-length
   text 0 (max 0 (min index (length text)))))

(defun cmacs-gowl-edit-field--compute-replace (old new cursor-byte)
  "Return the smallest edit turning OLD into NEW around CURSOR-BYTE.
OLD is the text the application reported, CURSOR-BYTE its cursor as a
UTF-8 offset into OLD, NEW the text wanted.  The value is a list
\(DELETE-BEFORE DELETE-AFTER INSERT), in the terms of
`gowl-text-field-replace' -- bytes to remove before and after the
cursor, and the string to put there -- or nil when OLD and NEW are the
same.

Text OLD and NEW share at either end is left alone, as far as the
cursor allows: a deletion is measured from the cursor, so the part
that is kept before it cannot reach past it, nor the part kept after
it start before it.  Changing one word of a long field therefore sends
one word, not the field."
  (unless (string= old new)
    (let* ((old-len (length old))
           (new-len (length new))
           (cursor (cmacs-gowl-edit-field--byte-to-char old cursor-byte))
           (max-prefix (min cursor new-len))
           (prefix 0)
           (suffix 0))
      (while (and (< prefix max-prefix)
                  (eq (aref old prefix) (aref new prefix)))
        (setq prefix (1+ prefix)))
      ;; The kept tail may not start before the cursor in OLD, nor
      ;; overlap the kept head in NEW.
      (let ((max-suffix (min (- old-len cursor) (- new-len prefix))))
        (while (and (< suffix max-suffix)
                    (eq (aref old (- old-len suffix 1))
                        (aref new (- new-len suffix 1))))
          (setq suffix (1+ suffix))))
      (list (cmacs-gowl-edit-field--utf8-length old prefix cursor)
            (cmacs-gowl-edit-field--utf8-length old cursor (- old-len suffix))
            (substring new prefix (- new-len suffix))))))

;;;; Pure helpers: policy

(defun cmacs-gowl-edit-field--match-p (regexps &rest strings)
  "Return non-nil if any of REGEXPS matches any of STRINGS, ignoring case."
  (let ((case-fold-search t))
    (cl-some (lambda (re)
               (cl-some (lambda (s)
                          (and (stringp s) (string-match-p re s)))
                        strings))
             regexps)))

(defun cmacs-gowl-edit-field--denied-p (app-id title)
  "Return non-nil if the window with APP-ID and TITLE is on the deny list."
  (cmacs-gowl-edit-field--match-p cmacs-gowl-edit-field-deny app-id title))

(defun cmacs-gowl-edit-field--fallback-allowed-p (app-id title)
  "Return non-nil if the clipboard fallback may be used on APP-ID / TITLE."
  (and (eq cmacs-gowl-edit-field-fallback 'clipboard)
       (not (cmacs-gowl-edit-field--denied-p app-id title))
       (not (cmacs-gowl-edit-field--match-p
             cmacs-gowl-edit-field-fallback-deny app-id))))

(defun cmacs-gowl-edit-field--sensitive-p (result)
  "Return non-nil if RESULT, a read's plist, describes a secret field.
The application says so itself: content purpose password (8) or PIN
\(9), or the hidden-text (#x40) or sensitive-data (#x80) hint."
  (or (memq (plist-get result :purpose) '(8 9))
      (/= 0 (logand (or (plist-get result :hint) 0) #xc0))))

(defun cmacs-gowl-edit-field--mode-for (app-id)
  "Return the major mode for a field of the application APP-ID."
  (let ((case-fold-search t))
    (or (cl-loop for (re . mode) in cmacs-gowl-edit-field-mode-alist
                 when (and (stringp app-id) (fboundp mode)
                           (string-match-p re app-id))
                 return mode)
        cmacs-gowl-edit-field-major-mode)))

(defun cmacs-gowl-edit-field--frame-parameters ()
  "Return the parameters of the editor frame.
The name is what the float rule matches, so it is not the user's to
override; everything else is."
  (let ((ours `((width . ,cmacs-gowl-edit-field-frame-width)
                (height . ,cmacs-gowl-edit-field-frame-height)
                (minibuffer . ,cmacs-gowl-edit-field-frame-minibuffer)
                (tab-bar-lines . 0)
                (tool-bar-lines . 0)
                (menu-bar-lines . 0)
                (unsplittable . t)
                ;; How other code can tell this frame from a real one.
                (cmacs-edit-field . t)))
        (theirs (assq-delete-all
                 'name (copy-alist cmacs-gowl-edit-field-frame-parameters))))
    `((name . ,cmacs-gowl-edit-field-frame-name)
      ,@theirs
      ,@(cl-remove-if (lambda (p) (assq (car p) theirs)) ours))))

(defun cmacs-gowl-edit-field--float-rule ()
  "Return the gowl window rule that floats the editor frame.
Matched on the title alone: every Emacs frame has the same app-id.  It
assigns no tags and asks for no focus -- a new window takes the
keyboard anyway, and `cmacs-gowl-edit-field--adopt-frame' makes sure."
  `((title . ,cmacs-gowl-edit-field-frame-name)
    (floating . t)
    (center . t)))

(defun cmacs-gowl-edit-field--buffer-name (title)
  "Return the buffer name for editing a field of the window titled TITLE."
  (format "*edit-field: %s*"
          (truncate-string-to-width
           (if (or (null title) (string-empty-p title)) "untitled" title)
           48 nil nil "...")))

(defun cmacs-gowl-edit-field--centre (width height over area)
  "Return (X . Y) placing a WIDTH x HEIGHT window centred over OVER.
OVER is the (X Y W H) of the window being edited; AREA, when non-nil,
the (X Y W H) of the output's usable area, which the result is kept
inside as far as the size allows -- a small window near an edge would
otherwise put the editor half off the screen."
  (let ((x (+ (nth 0 over) (/ (- (nth 2 over) width) 2)))
        (y (+ (nth 1 over) (/ (- (nth 3 over) height) 2))))
    (when area
      (setq x (max (nth 0 area)
                   (min x (- (+ (nth 0 area) (nth 2 area)) width)))
            y (max (nth 1 area)
                   (min y (- (+ (nth 1 area) (nth 3 area)) height)))))
    (cons x y)))

;;;; Sessions

(cl-defstruct (cmacs-gowl-edit-field--session
               (:constructor cmacs-gowl-edit-field--session-create)
               (:copier nil))
  "One field being edited."
  client          ; the window the field is in
  id              ; its gowl id: a client object is not `eq' across calls
  app-id
  title
  method          ; `text-input' or `clipboard'
  text            ; the text as read
  cursor          ; the cursor, a UTF-8 byte offset into `text'
  complete        ; nil when `text' is known to be a window of the field
  buffer
  frame
  frame-id        ; the gowl id of the editor frame's window
  clipboard       ; the user's clipboard, to put back (clipboard method)
  state           ; `reading', `editing', `committing' or `closing'
  gone            ; non-nil once the window has disappeared
  conflict        ; a fresh read that differed from `text', or nil
  note            ; what the header line should warn about, or nil
  ;; A HEADLESS session has no buffer and no frame: another feature (the
  ;; AI field commands) borrowed the read and the write-back, and
  ;; `handler' is told what would otherwise have been shown in an
  ;; editor.  See "Headless sessions" below.
  handler         ; nil, or a function (EVENT SESSION &rest ARGS)
  no-fallback)    ; non-nil never reaches for the clipboard fallback

(defvar cmacs-gowl-edit-field--sessions nil
  "The fields being edited, as session structs.")

(defvar-local cmacs-gowl-edit-field--session nil
  "The session this buffer is the editor of.")
(put 'cmacs-gowl-edit-field--session 'permanent-local t)

(defun cmacs-gowl-edit-field--client-id (client)
  "Return CLIENT's gowl id, or nil if it cannot be asked."
  (ignore-errors (alist-get 'id (gowl-client-info client))))

(defun cmacs-gowl-edit-field--focused-id ()
  "Return the gowl id of the window holding the keyboard, or nil."
  (when-let* ((c (ignore-errors (gowl-focused-client))))
    (cmacs-gowl-edit-field--client-id c)))

(defun cmacs-gowl-edit-field--client-live-p (id)
  "Return non-nil if a window with gowl id ID is still mapped."
  (cl-some (lambda (c) (eql id (cmacs-gowl-edit-field--client-id c)))
           (ignore-errors (gowl-list-clients))))

(defun cmacs-gowl-edit-field--say (format-string &rest args)
  "Report FORMAT-STRING with ARGS to the user.
Never signals: most of this file runs from the compositor's keybind or
from a callback in the main loop, where an error has nobody to reach."
  (apply #'message (concat "edit-field: " format-string) args)
  nil)

;;;; Headless sessions
;;
;; Everything this file knows about reaching a field -- the text-input
;; read, the clipboard fallback, the verify-before-write, the deny
;; lists, the password refusal -- is also what a feature with no editor
;; needs.  Such a feature opens a session with a handler
;; (`cmacs-gowl-edit-field-read-async') and is called back at the
;; points where an editor session would have opened, closed or put a
;; note in its header line:
;;
;;   (HANDLER \='read SESSION TEXT CURSOR ANCHOR)
;;       the field was read; CURSOR and ANCHOR are character indexes
;;       into TEXT and differ when the application reports a selection.
;;       The session stays open, for `cmacs-gowl-edit-field-write-async'
;;       or `cmacs-gowl-edit-field-release'.
;;   (HANDLER \='committed SESSION)   the new text is in the field
;;   (HANDLER \='unchanged SESSION)   the new text was what is there
;;   (HANDLER \='failed SESSION WHY)  the read or the write did not
;;       happen; WHY is a sentence for the user.
;;
;; After any event but `read' the session is closed already.  A
;; headless session never moves the keyboard: where an editor session
;; hands focus back to its window, a headless one leaves it alone.

(defun cmacs-gowl-edit-field--notify (session event &rest args)
  "Tell SESSION's handler about EVENT with ARGS.
Return non-nil if SESSION is headless, nil if it has an editor (and so
nothing was told).  Never signals: this runs from compositor callbacks."
  (let ((handler (cmacs-gowl-edit-field--session-handler session)))
    (when handler
      (condition-case err
          (apply handler event session args)
        (error (cmacs-gowl-edit-field--say
                "handler failed: %s" (error-message-string err))))
      t)))

;;;; Waiting for focus, without waiting
;;
;; An edit can only be sent to the window that holds the keyboard, and
;; asking for focus is not having it.  A waiter is a function to call
;; when a window has focus and another for when it never got it; the
;; compositor's focus-changed hook resolves it, a short repeating timer
;; resolves it where that hook is not bridged, and a deadline ends it.

(defvar cmacs-gowl-edit-field--waiters nil
  "Waiters, each a list (ID THEN ELSE POLL-TIMER DEADLINE-TIMER).")

(defun cmacs-gowl-edit-field--resolve-waiter (waiter landed)
  "Finish WAITER: call its THEN if LANDED, else its ELSE."
  (when (memq waiter cmacs-gowl-edit-field--waiters)
    (setq cmacs-gowl-edit-field--waiters
          (delq waiter cmacs-gowl-edit-field--waiters))
    (dolist (timer (nthcdr 3 waiter))
      (when (timerp timer) (cancel-timer timer)))
    (funcall (if landed (nth 1 waiter) (nth 2 waiter)))))

(defun cmacs-gowl-edit-field--check-waiters (&rest _)
  "Resolve every waiter whose window now holds the keyboard."
  (when cmacs-gowl-edit-field--waiters
    (let ((focused (cmacs-gowl-edit-field--focused-id)))
      (dolist (waiter (copy-sequence cmacs-gowl-edit-field--waiters))
        (when (eql focused (car waiter))
          (cmacs-gowl-edit-field--resolve-waiter waiter t))))))

(defun cmacs-gowl-edit-field--on-focus-changed (&rest _)
  "The compositor moved the keyboard: look at the waiters, soon.
Deferred to a timer so that nothing of substance runs inside the
compositor's signal."
  (when cmacs-gowl-edit-field--waiters
    (run-at-time 0 nil #'cmacs-gowl-edit-field--check-waiters)))

(defun cmacs-gowl-edit-field--when-focused (client id then else)
  "Give CLIENT (gowl id ID) the keyboard; call THEN once it has it.
Call ELSE instead if it does not within
`cmacs-gowl-edit-field-focus-timeout'.  Returns at once either way."
  (let ((waiter (list id then else nil nil)))
    (push waiter cmacs-gowl-edit-field--waiters)
    (setf (nth 3 waiter)
          (run-at-time 0.03 0.03 #'cmacs-gowl-edit-field--check-waiters))
    (setf (nth 4 waiter)
          (run-at-time cmacs-gowl-edit-field-focus-timeout nil
                       #'cmacs-gowl-edit-field--resolve-waiter waiter nil))
    (condition-case nil
        (gowl-focus-client client)
      (error nil))
    ;; Usually it has landed already: the compositor moves focus inside
    ;; that call.
    (cmacs-gowl-edit-field--check-waiters)))

;;;; Hooks into the compositor

(defun cmacs-gowl-edit-field--on-client-removed (client &rest _)
  "CLIENT unmapped: a session editing one of its fields has lost it."
  (let ((id (cmacs-gowl-edit-field--client-id client)))
    (dolist (session cmacs-gowl-edit-field--sessions)
      (when (and id (eql id (cmacs-gowl-edit-field--session-id session)))
        (cmacs-gowl-edit-field--mark-gone session)))))

(defun cmacs-gowl-edit-field--mark-gone (session)
  "Record that SESSION's window has disappeared, and say so."
  (unless (cmacs-gowl-edit-field--session-gone session)
    (setf (cmacs-gowl-edit-field--session-gone session) t)
    (if (cmacs-gowl-edit-field--session-handler session)
        ;; No buffer holds the text: whoever borrowed the session does.
        (cmacs-gowl-edit-field--failed session "the window is gone")
      (setf (cmacs-gowl-edit-field--session-note session)
            "the window is gone -- C-c M-w copies this text")
      (cmacs-gowl-edit-field--refresh session)
      (cmacs-gowl-edit-field--say
       "the window being edited is gone; the text is still in %s"
       (buffer-name (cmacs-gowl-edit-field--session-buffer session))))))

(defun cmacs-gowl-edit-field--sync-hooks ()
  "Listen to the compositor while there is a session, and only then."
  (if cmacs-gowl-edit-field--sessions
      (progn
        (add-hook 'cmacs-gowl-focus-changed-functions
                  #'cmacs-gowl-edit-field--on-focus-changed)
        (add-hook 'cmacs-gowl-client-removed-functions
                  #'cmacs-gowl-edit-field--on-client-removed)
        (add-hook 'delete-frame-functions
                  #'cmacs-gowl-edit-field--on-delete-frame))
    (remove-hook 'cmacs-gowl-focus-changed-functions
                 #'cmacs-gowl-edit-field--on-focus-changed)
    (remove-hook 'cmacs-gowl-client-removed-functions
                 #'cmacs-gowl-edit-field--on-client-removed)
    (remove-hook 'delete-frame-functions
                 #'cmacs-gowl-edit-field--on-delete-frame)))

;;;; The editor buffer

(defvar-keymap cmacs-gowl-edit-field-mode-map
  :doc "Keys of an edit-field buffer."
  "C-c C-c" #'cmacs-gowl-edit-field-finish
  "C-c C-k" #'cmacs-gowl-edit-field-abort
  "C-c M-w" #'cmacs-gowl-edit-field-copy
  "C-c C-w" #'cmacs-gowl-edit-field-fetch-whole
  ;; `server-edit' is what the hand reaches for to say "done with this
  ;; buffer somebody handed me"; here that is a commit.
  "C-x #" #'cmacs-gowl-edit-field-finish)

(define-minor-mode cmacs-gowl-edit-field-mode
  "Minor mode of a buffer holding another application's text field.
Committing puts the text back in the field; aborting leaves the field
as it was; copying keeps the text on the kill ring when it cannot go
back; fetching the whole field goes through the clipboard when only
part of it could be read.

\\{cmacs-gowl-edit-field-mode-map}"
  :lighter " EditField"
  :keymap cmacs-gowl-edit-field-mode-map)
(put 'cmacs-gowl-edit-field-mode 'permanent-local t)

(defun cmacs-gowl-edit-field--header (session)
  "Return the header line of SESSION's buffer.
It says, before anything is typed, how much of the field this is."
  (let* ((text (or (cmacs-gowl-edit-field--session-text session) ""))
         (scope
          (cond
           ((eq (cmacs-gowl-edit-field--session-method session) 'clipboard)
            "the whole field, through the clipboard (best effort)")
           ((not (cmacs-gowl-edit-field--session-complete session))
            (format "editing the %d bytes around the cursor, not the \
whole field"
                    (cmacs-gowl-edit-field--utf8-length text)))
           (t "the text the application reported")))
         (note (cmacs-gowl-edit-field--session-note session)))
    (concat
     (propertize " " 'display '(space :align-to 0))
     (format "%s: %s"
             (or (cmacs-gowl-edit-field--session-app-id session) "?")
             scope)
     (when note
       (concat "  " (propertize (concat "[" note "]")
                                'face 'cmacs-gowl-edit-field-note)))
     (substitute-command-keys
      "   \\<cmacs-gowl-edit-field-mode-map>\
\\[cmacs-gowl-edit-field-finish] commit  \
\\[cmacs-gowl-edit-field-abort] abort"))))

(defun cmacs-gowl-edit-field--refresh (session)
  "Redraw the header line of SESSION's buffer."
  (let ((buffer (cmacs-gowl-edit-field--session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (force-mode-line-update)))))

(defun cmacs-gowl-edit-field--fill-buffer (session text cursor anchor)
  "Put TEXT in SESSION's buffer, creating it if need be.
CURSOR and ANCHOR are character indexes into TEXT: point goes to the
first, and the region is active between them when they differ."
  (let ((buffer (cmacs-gowl-edit-field--session-buffer session)))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer
                    (cmacs-gowl-edit-field--buffer-name
                     (cmacs-gowl-edit-field--session-title session))))
      (setf (cmacs-gowl-edit-field--session-buffer session) buffer)
      (with-current-buffer buffer
        (funcall (cmacs-gowl-edit-field--mode-for
                  (cmacs-gowl-edit-field--session-app-id session)))
        (setq cmacs-gowl-edit-field--session session)
        (cmacs-gowl-edit-field-mode 1)
        (setq header-line-format
              '(:eval (and cmacs-gowl-edit-field--session
                           (cmacs-gowl-edit-field--header
                            cmacs-gowl-edit-field--session))))
        (add-hook 'kill-buffer-hook
                  #'cmacs-gowl-edit-field--on-kill-buffer nil t)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text))
      (set-buffer-modified-p nil)
      (buffer-disable-undo)
      (buffer-enable-undo)
      (goto-char (+ (point-min) (min cursor (length text))))
      (if (= cursor anchor)
          (deactivate-mark)
        (set-mark (+ (point-min) (min anchor (length text))))
        (activate-mark)))
    buffer))

;;;; The editor frame
;;
;; A frame of its own, floated by a compositor rule before it is first
;; placed, so nothing that is tiled moves.  The rule is (re)installed
;; each time: `cmacs-gowl-float-rules' clears every rule when it is
;; reapplied, and removing ours first keeps one copy however often this
;; runs.

(defun cmacs-gowl-edit-field--install-float-rule ()
  "Make gowl float windows titled `cmacs-gowl-edit-field-frame-name'."
  (when (fboundp 'gowl-add-rule-entry)
    (ignore-errors
      (when (fboundp 'gowl-remove-rule)
        (gowl-remove-rule nil cmacs-gowl-edit-field-frame-name))
      (gowl-add-rule-entry (cmacs-gowl-edit-field--float-rule)))))

(defun cmacs-gowl-edit-field--frame-client (session)
  "Return the gowl window of SESSION's editor frame, or nil if not mapped.
It is one of Emacs's own windows, titled with the frame's name, that no
other session has claimed."
  (let ((taken (delq nil (mapcar #'cmacs-gowl-edit-field--session-frame-id
                                 (remq session
                                       cmacs-gowl-edit-field--sessions))))
        (pid (emacs-pid)))
    (cl-find-if
     (lambda (c)
       (let ((info (ignore-errors (gowl-client-info c))))
         (and info
              (equal (alist-get 'title info)
                     cmacs-gowl-edit-field-frame-name)
              (not (alist-get 'embedded info))
              (not (memql (alist-get 'id info) taken))
              (eql pid (ignore-errors (gowl-client-pid c))))))
     (ignore-errors (gowl-list-clients)))))

(defun cmacs-gowl-edit-field--adopt-frame (session tries)
  "Find SESSION's editor window in the compositor and place it.
The float rule has normally floated and centred it already; this
centres it over the window being edited, makes sure it floats where the
rule did not apply, and gives it the keyboard.  The window appears a
moment after `make-frame' returns, so this retries, TRIES more times,
from a timer."
  (when (and (memq session cmacs-gowl-edit-field--sessions)
             (frame-live-p (cmacs-gowl-edit-field--session-frame session)))
    (let ((client (cmacs-gowl-edit-field--frame-client session)))
      (cond
       (client
        (let* ((info (gowl-client-info client))
               (geometry (alist-get 'geometry info))
               (over (alist-get 'geometry
                                (ignore-errors
                                  (gowl-client-info
                                   (cmacs-gowl-edit-field--session-client
                                    session))))))
          (setf (cmacs-gowl-edit-field--session-frame-id session)
                (alist-get 'id info))
          (unless (alist-get 'floating info)
            (ignore-errors (gowl-set-client-floating client t)))
          (when (and over geometry)
            (let ((at (cmacs-gowl-edit-field--centre
                       (nth 2 geometry) (nth 3 geometry) over
                       (ignore-errors (gowl-usable-area)))))
              (ignore-errors
                (gowl-client-set-geometry client (car at) (cdr at)
                                          (nth 2 geometry)
                                          (nth 3 geometry)))))
          (ignore-errors (gowl-focus-client client))))
       ((> tries 0)
        (run-at-time 0.05 nil #'cmacs-gowl-edit-field--adopt-frame
                     session (1- tries)))))))

(defun cmacs-gowl-edit-field--show (session)
  "Show SESSION's buffer in its floating editor frame."
  (let ((buffer (cmacs-gowl-edit-field--session-buffer session))
        (frame (cmacs-gowl-edit-field--session-frame session)))
    (unless (frame-live-p frame)
      (cmacs-gowl-edit-field--install-float-rule)
      (setq frame (make-frame (cmacs-gowl-edit-field--frame-parameters)))
      (setf (cmacs-gowl-edit-field--session-frame session) frame))
    (let ((window (frame-root-window frame)))
      (set-window-dedicated-p window nil)
      (set-window-buffer window buffer)
      (set-window-dedicated-p window t)
      (set-window-point window (with-current-buffer buffer (point))))
    (select-frame-set-input-focus frame)
    (with-current-buffer buffer
      (when (and cmacs-gowl-edit-field-evil-insert
                 (bound-and-true-p evil-local-mode)
                 (fboundp 'evil-insert-state)
                 (not (region-active-p)))
        (evil-insert-state)))
    ;; Two seconds of looking for the window is generous; it is there
    ;; within a frame or two.
    (cmacs-gowl-edit-field--adopt-frame session 40)))

(defun cmacs-gowl-edit-field--open (session text cursor anchor)
  "Start editing TEXT for SESSION, point at CURSOR, region to ANCHOR.
CURSOR and ANCHOR are character indexes.  A headless session gets the
text handed to its handler instead of an editor."
  (if (cmacs-gowl-edit-field--session-handler session)
      (progn
        (setf (cmacs-gowl-edit-field--session-state session) 'held)
        (cmacs-gowl-edit-field--notify session 'read text cursor anchor))
    (setf (cmacs-gowl-edit-field--session-state session) 'editing)
    (cmacs-gowl-edit-field--fill-buffer session text cursor anchor)
    (cmacs-gowl-edit-field--show session)))

;;;; Ending a session

(defun cmacs-gowl-edit-field--close (session &optional keep-buffer refocus)
  "End SESSION: delete its frame and forget it.
Kill its buffer too unless KEEP-BUFFER.  With REFOCUS, hand the
keyboard back to the window that was being edited."
  (setf (cmacs-gowl-edit-field--session-state session) 'closing)
  (setq cmacs-gowl-edit-field--sessions
        (delq session cmacs-gowl-edit-field--sessions))
  (cmacs-gowl-edit-field--sync-hooks)
  (let ((frame (cmacs-gowl-edit-field--session-frame session))
        (buffer (cmacs-gowl-edit-field--session-buffer session)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq cmacs-gowl-edit-field--session nil)
        (remove-hook 'kill-buffer-hook
                     #'cmacs-gowl-edit-field--on-kill-buffer t)
        (when keep-buffer
          (cmacs-gowl-edit-field-mode -1)
          (setq header-line-format nil))))
    (when (and (frame-live-p frame) (cdr (frame-list)))
      (ignore-errors (delete-frame frame)))
    (when (and (buffer-live-p buffer) (not keep-buffer))
      (kill-buffer buffer)))
  (when (and refocus
             (not (cmacs-gowl-edit-field--session-gone session))
             (fboundp 'gowl-focus-client))
    (ignore-errors
      (gowl-focus-client (cmacs-gowl-edit-field--session-client session)))))

(defun cmacs-gowl-edit-field--on-kill-buffer ()
  "The editor buffer is being killed by hand: end its session."
  (let ((session cmacs-gowl-edit-field--session))
    (when (and session
               (not (eq (cmacs-gowl-edit-field--session-state session)
                        'closing)))
      (setq cmacs-gowl-edit-field--session nil)
      (setf (cmacs-gowl-edit-field--session-buffer session) nil)
      (cmacs-gowl-edit-field--close session t t))))

(defun cmacs-gowl-edit-field--on-delete-frame (frame)
  "FRAME is being deleted: if it is an editor, end its session.
Closing the window is giving up, but not on the text: a buffer with
edits in it is kept, so a slip of the hand loses nothing."
  (dolist (session (copy-sequence cmacs-gowl-edit-field--sessions))
    (when (and (eq frame (cmacs-gowl-edit-field--session-frame session))
               (not (eq (cmacs-gowl-edit-field--session-state session)
                        'closing)))
      (let* ((buffer (cmacs-gowl-edit-field--session-buffer session))
             (keep (and (buffer-live-p buffer) (buffer-modified-p buffer))))
        ;; The frame is going by itself; do not delete it a second time.
        (setf (cmacs-gowl-edit-field--session-frame session) nil)
        (cmacs-gowl-edit-field--close session keep t)
        (when keep
          (cmacs-gowl-edit-field--say "editor closed; your text is in %s"
                                      (buffer-name buffer)))))))

(defun cmacs-gowl-edit-field--failed (session why)
  "SESSION's commit did not happen, for the reason WHY: keep editing.
A headless session has no editor to keep: it is closed, and its handler
is told WHY."
  (if (cmacs-gowl-edit-field--session-handler session)
      (progn
        (cmacs-gowl-edit-field--close session)
        (cmacs-gowl-edit-field--notify session 'failed why)
        nil)
    (setf (cmacs-gowl-edit-field--session-state session) 'editing
          (cmacs-gowl-edit-field--session-note session) why)
    (cmacs-gowl-edit-field--refresh session)
    ;; Back to the editor, so the text and the reason are in front of
    ;; the user rather than behind the window that refused them.
    (let ((frame (cmacs-gowl-edit-field--session-frame session)))
      (when (frame-live-p frame)
        (when-let* ((client (cmacs-gowl-edit-field--frame-client session)))
          (ignore-errors (gowl-focus-client client)))
        (ignore-errors (select-frame-set-input-focus frame))))
    (cmacs-gowl-edit-field--say "%s" why)))

(defun cmacs-gowl-edit-field--committed (session)
  "SESSION's text is in the field: close the editor."
  (if (cmacs-gowl-edit-field--session-handler session)
      (progn
        ;; No refocus: a headless session never took the keyboard away.
        (cmacs-gowl-edit-field--close session)
        (cmacs-gowl-edit-field--notify session 'committed))
    (cmacs-gowl-edit-field--close session nil t)
    (cmacs-gowl-edit-field--say "field updated")))

;;;; Committing through text-input

(defun cmacs-gowl-edit-field--send-replace (session new old cursor)
  "Replace OLD, whose cursor is at byte CURSOR, with NEW in SESSION's field."
  (let ((edit (cmacs-gowl-edit-field--compute-replace old new cursor)))
    (cond
     ((null edit)
      (if (cmacs-gowl-edit-field--session-handler session)
          (progn
            (cmacs-gowl-edit-field--close session)
            (cmacs-gowl-edit-field--notify session 'unchanged))
        (cmacs-gowl-edit-field--close session nil t)
        (cmacs-gowl-edit-field--say "nothing changed")))
     ((not (condition-case nil
               (gowl-text-field-replace
                (cmacs-gowl-edit-field--session-client session)
                (nth 0 edit) (nth 1 edit) (nth 2 edit)
                (lambda (delivered)
                  (when (memq session cmacs-gowl-edit-field--sessions)
                    (if delivered
                        (cmacs-gowl-edit-field--committed session)
                      (cmacs-gowl-edit-field--failed
                       session
                       "the application did not take the text")))))
             (error nil)))
      (cmacs-gowl-edit-field--failed
       session "the field can no longer be reached")))))

(defun cmacs-gowl-edit-field--commit-verified (session new result force)
  "Send NEW for SESSION now that RESULT, a fresh read, has arrived.
A field that still holds what was read is replaced, measuring from
wherever its cursor is now.  One that changed is left alone unless
FORCE, and the fresh read is kept so that a second commit can
overwrite it."
  (when (memq session cmacs-gowl-edit-field--sessions)
    (let ((status (plist-get result :status))
          (text (plist-get result :text)))
      (cond
       ((not (eq status 'ok))
        (cmacs-gowl-edit-field--failed
         session "the field can no longer be read"))
       ((or force
            (string= text (cmacs-gowl-edit-field--session-text session)))
        (cmacs-gowl-edit-field--send-replace
         session new text (plist-get result :cursor)))
       (t
        (setf (cmacs-gowl-edit-field--session-conflict session) t)
        (cmacs-gowl-edit-field--failed
         session
         "the field changed in the application -- C-c C-c again \
overwrites what is there now"))))))

(defun cmacs-gowl-edit-field--commit-text-input (session new)
  "Put NEW in SESSION's field through text-input.  The window has focus."
  (let ((client (cmacs-gowl-edit-field--session-client session))
        (force (cmacs-gowl-edit-field--session-conflict session)))
    (if (not (or cmacs-gowl-edit-field-verify force))
        (cmacs-gowl-edit-field--send-replace
         session new
         (cmacs-gowl-edit-field--session-text session)
         (cmacs-gowl-edit-field--session-cursor session))
      (unless (condition-case nil
                  (gowl-text-field-read
                   client
                   (lambda (result)
                     (cmacs-gowl-edit-field--commit-verified
                      session new result force)))
                (error nil))
        (cmacs-gowl-edit-field--failed
         session "the field can no longer be reached")))))

;;;; The clipboard fallback
;;
;; Best effort, and labelled so wherever the user can see it.  The
;; user's clipboard is read first and put back afterwards, marked
;; transient both times it is set from here, so neither the text in
;; transit nor the restored clipboard lands in the clipboard history
;; or the kill ring a second time.  (The application's own copy is an
;; ordinary copy: that one does pass through the history.)

(defun cmacs-gowl-edit-field--chord (session key)
  "Send Ctrl+KEY to SESSION's window; non-nil if the compositor took it."
  (condition-case nil
      (gowl-text-field-send-key
       (cmacs-gowl-edit-field--session-client session) key '(control))
    (error nil)))

(defun cmacs-gowl-edit-field--restore-clipboard (session)
  "Put the user's clipboard back as SESSION found it."
  (ignore-errors
    (gowl-clipboard-set-transient
     (or (cmacs-gowl-edit-field--session-clipboard session) "")))
  (setf (cmacs-gowl-edit-field--session-clipboard session) nil))

(defun cmacs-gowl-edit-field--clipboard-read (session)
  "Fetch SESSION's whole field through the clipboard.  Its window has focus.
A marker is put on the clipboard first: if it is still there after the
application was asked to copy, the application copied nothing."
  (let ((marker (format "cmacs-edit-field-%d-%d" (emacs-pid)
                        (random most-positive-fixnum))))
    (setf (cmacs-gowl-edit-field--session-clipboard session)
          (ignore-errors (gowl-clipboard-get)))
    (if (not (and (ignore-errors (gowl-clipboard-set-transient marker) t)
                  (cmacs-gowl-edit-field--chord session "a")
                  (cmacs-gowl-edit-field--chord session "c")))
        (progn
          (cmacs-gowl-edit-field--restore-clipboard session)
          (cmacs-gowl-edit-field--read-failed
           session "the window could not be sent keys"))
      (run-at-time cmacs-gowl-edit-field-key-delay nil
                   #'cmacs-gowl-edit-field--clipboard-collect
                   session marker 3))))

(defun cmacs-gowl-edit-field--clipboard-collect (session marker tries)
  "Read what SESSION's application copied; MARKER means nothing yet.
Looks TRIES more times before deciding it copied nothing."
  (when (memq session cmacs-gowl-edit-field--sessions)
    (let ((text (ignore-errors (gowl-clipboard-get))))
      (cond
       ((and (stringp text) (not (string= text marker)))
        (cmacs-gowl-edit-field--restore-clipboard session)
        (setf (cmacs-gowl-edit-field--session-method session) 'clipboard
              (cmacs-gowl-edit-field--session-text session) text
              (cmacs-gowl-edit-field--session-cursor session) nil
              (cmacs-gowl-edit-field--session-complete session) t
              (cmacs-gowl-edit-field--session-note session) nil)
        ;; Where the cursor was cannot be learnt this way: the end of
        ;; the text is where one usually goes on writing.
        (cmacs-gowl-edit-field--open session text (length text)
                                     (length text)))
       ((> tries 0)
        (run-at-time cmacs-gowl-edit-field-key-delay nil
                     #'cmacs-gowl-edit-field--clipboard-collect
                     session marker (1- tries)))
       (t
        (cmacs-gowl-edit-field--restore-clipboard session)
        (cmacs-gowl-edit-field--read-failed
         session "the application copied nothing (an empty field, or \
no text field has its focus)"))))))

(defun cmacs-gowl-edit-field--commit-clipboard (session new)
  "Put NEW in SESSION's field by pasting over it.  The window has focus."
  (setf (cmacs-gowl-edit-field--session-clipboard session)
        (ignore-errors (gowl-clipboard-get)))
  (if (not (and (ignore-errors (gowl-clipboard-set-transient new) t)
                (cmacs-gowl-edit-field--chord session "a")
                (cmacs-gowl-edit-field--chord session "v")))
      (progn
        (cmacs-gowl-edit-field--restore-clipboard session)
        (cmacs-gowl-edit-field--failed
         session "the window could not be sent keys"))
    ;; The application reads the clipboard when it handles the paste,
    ;; which is after this returns: the clipboard goes back once it has
    ;; had time to.  Whether it pasted cannot be known from here.
    (run-at-time (* 2 cmacs-gowl-edit-field-key-delay) nil
                 (lambda ()
                   (cmacs-gowl-edit-field--restore-clipboard session)
                   (when (memq session cmacs-gowl-edit-field--sessions)
                     (cmacs-gowl-edit-field--committed session))))))

;;;; Reading

(defun cmacs-gowl-edit-field--read-failed (session why)
  "SESSION could not be started, or its refetch failed, for the reason WHY."
  (if (or (buffer-live-p (cmacs-gowl-edit-field--session-buffer session))
          (cmacs-gowl-edit-field--session-handler session))
      ;; A refetch from inside an editor: the editor stays as it was.
      ;; A headless session: its handler hears about it.
      (cmacs-gowl-edit-field--failed session why)
    (cmacs-gowl-edit-field--close session)
    (cmacs-gowl-edit-field--say "%s" why)))

(defun cmacs-gowl-edit-field--try-fallback (session why)
  "Read SESSION's field through the fallback, or report WHY it was not read."
  (if (cmacs-gowl-edit-field--session-fallback-allowed-p session)
      (cmacs-gowl-edit-field--clipboard-read session)
    (cmacs-gowl-edit-field--read-failed session why)))

(defun cmacs-gowl-edit-field--session-fallback-allowed-p (session)
  "Return non-nil if the clipboard fallback may be used for SESSION."
  (and (not (cmacs-gowl-edit-field--session-no-fallback session))
       (cmacs-gowl-edit-field--fallback-allowed-p
        (cmacs-gowl-edit-field--session-app-id session)
        (cmacs-gowl-edit-field--session-title session))))

(defun cmacs-gowl-edit-field--on-read (session result)
  "Act on RESULT, the compositor's answer to reading SESSION's field."
  (when (and (memq session cmacs-gowl-edit-field--sessions)
             (eq (cmacs-gowl-edit-field--session-state session) 'reading))
    (let ((status (plist-get result :status))
          (text (plist-get result :text)))
      (cond
       ;; Whatever the path, a field its application calls a secret is
       ;; not read: no fallback either.
       ((cmacs-gowl-edit-field--sensitive-p result)
        (cmacs-gowl-edit-field--read-failed
         session "that is a password field; it stays where it is"))
       ((not (eq status 'ok))
        (cmacs-gowl-edit-field--try-fallback
         session
         (if (eq status 'no-field)
             "no text field has the focus in that window"
           "the application does not say what is in that field")))
       ((and (not (plist-get result :complete))
             (eq cmacs-gowl-edit-field-partial-action 'fallback)
             (cmacs-gowl-edit-field--session-fallback-allowed-p session))
        (cmacs-gowl-edit-field--clipboard-read session))
       (t
        (setf (cmacs-gowl-edit-field--session-method session) 'text-input
              (cmacs-gowl-edit-field--session-text session) text
              (cmacs-gowl-edit-field--session-cursor session)
              (plist-get result :cursor)
              (cmacs-gowl-edit-field--session-complete session)
              (plist-get result :complete))
        (cmacs-gowl-edit-field--open
         session text
         (cmacs-gowl-edit-field--byte-to-char text (plist-get result :cursor))
         (cmacs-gowl-edit-field--byte-to-char
          text (plist-get result :anchor))))))))

(defun cmacs-gowl-edit-field--unavailable ()
  "Return why this Emacs cannot edit fields, or nil if it can."
  (cond
   ((not (and (fboundp 'gowl-running-p) (gowl-running-p)))
    "this needs the gowl compositor: run cmacs as `emacs --gowl'")
   ((not (fboundp 'gowl-text-field-read))
    "this build of cmacs has no `gowl-text-field-read'")))

;;;; Commands

;;;###autoload
(defun cmacs-gowl-edit-field ()
  "Edit the text field that has the keyboard, in an Emacs buffer.
The field may be in any window on the gowl desktop.  Its text opens in
a floating editor frame, point where the field's cursor was and its
selection as the region;
\\<cmacs-gowl-edit-field-mode-map>\\[cmacs-gowl-edit-field-finish] \
puts the edited text back and \\[cmacs-gowl-edit-field-abort] gives up.

Meant for a compositor key (`cmacs-gowl-edit-field-key', bound by
`cmacs-gowl-edit-field-setup'), since the keyboard is in another
program when it is wanted.  Returns at once: the text arrives, and the
editor opens, a moment later."
  (interactive)
  (let* ((target (cmacs-gowl-edit-field-focused-target))
         (id (plist-get target :id))
         (existing (and id (cl-find id cmacs-gowl-edit-field--sessions
                                    :key #'cmacs-gowl-edit-field--session-id))))
    (cond
     ((plist-get target :refused)
      (cmacs-gowl-edit-field--say "%s" (plist-get target :refused)))
     ;; Already editing a field of this window: show that editor.
     (existing
      (cond
       ((cmacs-gowl-edit-field--session-handler existing)
        (cmacs-gowl-edit-field--say
         "another command is working on that window's field"))
       ((buffer-live-p (cmacs-gowl-edit-field--session-buffer existing))
        (cmacs-gowl-edit-field--show existing))))
     (t
      (cmacs-gowl-edit-field--start-read
       (cmacs-gowl-edit-field--session-create
        :client (plist-get target :client) :id id
        :app-id (plist-get target :app-id)
        :title (plist-get target :title)
        :state 'reading))))
    nil))

(defun cmacs-gowl-edit-field--start-read (session)
  "Register SESSION and ask the compositor for its field's text."
  (push session cmacs-gowl-edit-field--sessions)
  (cmacs-gowl-edit-field--sync-hooks)
  (unless (condition-case nil
              (gowl-text-field-read
               (cmacs-gowl-edit-field--session-client session)
               (lambda (result)
                 (cmacs-gowl-edit-field--on-read session result)))
            (error nil))
    ;; No text input reaches the window at all.
    (cmacs-gowl-edit-field--try-fallback
     session
     "that window has no text input; its fields cannot be read")))

;;;; The read and the write-back, for other features

(defun cmacs-gowl-edit-field-focused-target ()
  "Describe the window whose text field a command would act on now.
The value is a plist.  When the field may be touched it has :client,
:id (the window's gowl id), :app-id, :title and :pid; when it may not,
it has :refused, a sentence saying why -- no compositor, no focused
window, the keyboard being in Emacs itself, or a window on
`cmacs-gowl-edit-field-deny' -- and, where a window was found, the
same keys.  Never signals and never waits."
  (let ((why (cmacs-gowl-edit-field--unavailable))
        (client nil) (info nil) (id nil) (app-id nil) (title nil) (pid nil))
    (unless why
      (setq client (ignore-errors (gowl-focused-client))
            info (and client (ignore-errors (gowl-client-info client)))
            id (alist-get 'id info)
            app-id (alist-get 'app-id info)
            title (alist-get 'title info)
            pid (and client (ignore-errors (gowl-client-pid client))))
      (setq why
            (cond
             ((null id) "no window has the keyboard")
             ;; One of Emacs's own frames (an embedded application is
             ;; another process, and is fair game).
             ((and (not (alist-get 'embedded info))
                   (eql pid (emacs-pid)))
              "the keyboard is in Emacs already; put it in another \
program's text field first")
             ((cmacs-gowl-edit-field--denied-p app-id title)
              (format "%s is on `cmacs-gowl-edit-field-deny'; its fields \
are left alone"
                      (if (string-empty-p (or app-id "")) title app-id))))))
    `(,@(and why (list :refused why))
      :client ,client :id ,id :app-id ,app-id :title ,title :pid ,pid)))

(defun cmacs-gowl-edit-field-read-async (handler &optional target no-fallback)
  "Read the focused text field with no editor; tell HANDLER what came.
HANDLER is called as described under \"Headless sessions\" in this
file: (HANDLER \='read SESSION TEXT CURSOR ANCHOR) once the text is
here, or (HANDLER \='failed SESSION WHY).  TARGET is a plist from
`cmacs-gowl-edit-field-focused-target' (asked for when nil); a refused
one fails at once.  With NO-FALLBACK the clipboard fallback is not
used whatever `cmacs-gowl-edit-field-fallback' says.

Password fields, the deny lists, the partial-read policy and the
fallback are exactly `cmacs-gowl-edit-field's.  Returns the session,
or nil when nothing was started; HANDLER has been told either way, and
may be called before this returns."
  (let* ((target (or target (cmacs-gowl-edit-field-focused-target)))
         (id (plist-get target :id))
         (session (cmacs-gowl-edit-field--session-create
                   :client (plist-get target :client) :id id
                   :app-id (plist-get target :app-id)
                   :title (plist-get target :title)
                   :state 'reading :handler handler
                   :no-fallback no-fallback)))
    (cond
     ((plist-get target :refused)
      (cmacs-gowl-edit-field--notify session 'failed
                                     (plist-get target :refused))
      nil)
     ;; One conversation with a window's input method at a time.
     ((cl-find id cmacs-gowl-edit-field--sessions
               :key #'cmacs-gowl-edit-field--session-id)
      (cmacs-gowl-edit-field--notify
       session 'failed "that window's field is being edited already")
      nil)
     (t
      (cmacs-gowl-edit-field--start-read session)
      session))))

(defun cmacs-gowl-edit-field-write-async (session new)
  "Replace the text SESSION read with NEW, in its field.
SESSION is a headless session that has delivered its `read'.  Its
window must hold the keyboard NOW: this does not move focus, and the
caller is the one who knows whether typing there is still wanted.  The
field is read again first (`cmacs-gowl-edit-field-verify') and left
alone if it changed.  SESSION's handler hears `committed', `unchanged'
or `failed'; the session is closed by then."
  (cond
   ((not (memq session cmacs-gowl-edit-field--sessions))
    (cmacs-gowl-edit-field--notify session 'failed
                                   "the field is no longer held"))
   ((or (cmacs-gowl-edit-field--session-gone session)
        (not (cmacs-gowl-edit-field--client-live-p
              (cmacs-gowl-edit-field--session-id session))))
    (cmacs-gowl-edit-field--mark-gone session)
    ;; `--mark-gone' reports once; a session it had marked before is
    ;; still to be closed.
    (when (memq session cmacs-gowl-edit-field--sessions)
      (cmacs-gowl-edit-field--failed session "the window is gone")))
   (t
    (setf (cmacs-gowl-edit-field--session-state session) 'committing)
    (if (eq (cmacs-gowl-edit-field--session-method session) 'clipboard)
        (cmacs-gowl-edit-field--commit-clipboard session new)
      (cmacs-gowl-edit-field--commit-text-input session new))))
  nil)

(defun cmacs-gowl-edit-field-release (session)
  "Let go of SESSION, a headless session, without writing anything.
Its handler is not called.  Harmless on a session already closed."
  (when (memq session cmacs-gowl-edit-field--sessions)
    (cmacs-gowl-edit-field--close session))
  nil)

(defun cmacs-gowl-edit-field-session-info (session)
  "Return what is known of SESSION's field, as a plist.
:id, :app-id and :title of its window, :method (`text-input' or
`clipboard'), :text as read, and :complete, nil when :text is only the
part of the field around the cursor."
  (list :id (cmacs-gowl-edit-field--session-id session)
        :app-id (cmacs-gowl-edit-field--session-app-id session)
        :title (cmacs-gowl-edit-field--session-title session)
        :method (cmacs-gowl-edit-field--session-method session)
        :text (cmacs-gowl-edit-field--session-text session)
        :complete (cmacs-gowl-edit-field--session-complete session)))

(defun cmacs-gowl-edit-field--current ()
  "Return this buffer's session, or signal that it has none."
  (or (and cmacs-gowl-edit-field--session
           (memq cmacs-gowl-edit-field--session
                 cmacs-gowl-edit-field--sessions)
           cmacs-gowl-edit-field--session)
      (user-error "This buffer is not editing a text field")))

(defun cmacs-gowl-edit-field-finish ()
  "Put this buffer's text back in the field it came from.
The window that owns the field is given the keyboard first, and the
text is sent once it has it.  If the window has gone, offer to keep the
text on the kill ring instead."
  (interactive)
  (let* ((session (cmacs-gowl-edit-field--current))
         (new (buffer-substring-no-properties (point-min) (point-max)))
         (id (cmacs-gowl-edit-field--session-id session)))
    (cond
     ((eq (cmacs-gowl-edit-field--session-state session) 'committing)
      (message "Already sending this text"))
     ((or (cmacs-gowl-edit-field--session-gone session)
          (not (cmacs-gowl-edit-field--client-live-p id)))
      (cmacs-gowl-edit-field--mark-gone session)
      (when (y-or-n-p "The window is gone.  Copy the text to the kill ring? ")
        (cmacs-gowl-edit-field-copy)))
     (t
      (setf (cmacs-gowl-edit-field--session-state session) 'committing
            (cmacs-gowl-edit-field--session-note session) nil)
      (cmacs-gowl-edit-field--refresh session)
      (cmacs-gowl-edit-field--when-focused
       (cmacs-gowl-edit-field--session-client session) id
       (lambda ()
         (when (memq session cmacs-gowl-edit-field--sessions)
           (if (eq (cmacs-gowl-edit-field--session-method session)
                   'clipboard)
               (cmacs-gowl-edit-field--commit-clipboard session new)
             (cmacs-gowl-edit-field--commit-text-input session new))))
       (lambda ()
         (when (memq session cmacs-gowl-edit-field--sessions)
           (cmacs-gowl-edit-field--failed
            session "the window did not take the keyboard"))))))))

(defun cmacs-gowl-edit-field-abort ()
  "Give up editing: close the editor and leave the field as it was."
  (interactive)
  (let ((session (cmacs-gowl-edit-field--current)))
    (when (or (not (buffer-modified-p))
              (y-or-n-p "Discard the edits to this field? "))
      (cmacs-gowl-edit-field--close session nil t)
      (message "Field left as it was"))))

(defun cmacs-gowl-edit-field-copy ()
  "Copy this buffer's text to the kill ring and close the editor.
For when the text cannot go back where it came from."
  (interactive)
  (let ((session (cmacs-gowl-edit-field--current)))
    (kill-new (buffer-substring-no-properties (point-min) (point-max)))
    (cmacs-gowl-edit-field--close session nil t)
    (message "Text copied to the kill ring")))

(defun cmacs-gowl-edit-field-fetch-whole ()
  "Fetch the whole field through the clipboard, replacing this buffer's text.
For a field of which only the part around the cursor could be read.
Subject to `cmacs-gowl-edit-field-fallback' and its deny list."
  (interactive)
  (let ((session (cmacs-gowl-edit-field--current)))
    (cond
     ((not (cmacs-gowl-edit-field--fallback-allowed-p
            (cmacs-gowl-edit-field--session-app-id session)
            (cmacs-gowl-edit-field--session-title session)))
      (user-error "The clipboard fallback is off, or not allowed for %s"
                  (cmacs-gowl-edit-field--session-app-id session)))
     ((and (buffer-modified-p)
           (not (y-or-n-p "Fetching the whole field discards these edits.  \
Go on? ")))
      nil)
     (t
      (cmacs-gowl-edit-field--when-focused
       (cmacs-gowl-edit-field--session-client session)
       (cmacs-gowl-edit-field--session-id session)
       (lambda ()
         (when (memq session cmacs-gowl-edit-field--sessions)
           (cmacs-gowl-edit-field--clipboard-read session)))
       (lambda ()
         (when (memq session cmacs-gowl-edit-field--sessions)
           (cmacs-gowl-edit-field--failed
            session "the window did not take the keyboard"))))))))

;;;###autoload
(defun cmacs-gowl-edit-field-setup ()
  "Bind `cmacs-gowl-edit-field-key' to `cmacs-gowl-edit-field' in gowl.
Does nothing when the compositor is not running or the key is nil.
Safe to call again: the key is unbound before it is bound.  Put it on
`cmacs-gowl-mode-hook' to have the key whenever the desktop is up."
  (interactive)
  (when (and cmacs-gowl-edit-field-key
             (fboundp 'gowl-running-p) (gowl-running-p)
             (fboundp 'gowl-add-keybind))
    (condition-case err
        (progn
          ;; gowl runs the first bind that matches, so one left by an
          ;; earlier call would shadow this one.
          (ignore-errors (gowl-remove-keybind cmacs-gowl-edit-field-key))
          (gowl-add-keybind cmacs-gowl-edit-field-key 'custom
                            "(cmacs-gowl-edit-field)"
                            "Edit this text field in Emacs")
          t)
      (error (message "cmacs-gowl-edit-field: cannot bind %s: %s"
                      cmacs-gowl-edit-field-key
                      (error-message-string err))
             nil))))

(provide 'cmacs-gowl-edit-field)

;;; cmacs-gowl-edit-field.el ends here
