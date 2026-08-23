;;; cmacs-ai-output.el --- Result windows for AI actions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Where the answer goes.
;;
;; Almost every AI action that does not edit your buffer produces a block
;; of text you want to read, maybe copy a piece of, and then dismiss.
;; That wants a specific kind of window: opened beside what you were
;; reading (or below it, when the frame is too narrow for two columns),
;; showing output as it streams in, easy to select from, and gone again
;; on one keypress.
;;
;; So: `q' or `C-c C-k' closes it, and both cancel an in-flight request
;; rather than leaving a model generating into a window you have stopped
;; caring about.  `w' copies the whole answer.  The buffer is Org, like
;; the rest of cmacs-ai, so headings and code blocks in the reply render
;; as headings and code blocks.
;;
;; The split direction is chosen from the frame, not hardcoded: a wide
;; monitor gets a side-by-side window, a laptop in portrait or a narrow
;; tty gets one underneath.  Both are `display-buffer' actions, so a user
;; who disagrees can override the whole thing through
;; `display-buffer-alist' in the normal way.
;;
;; FOLLOW-UPS
;;
;; A one-shot answer is the wrong shape for half the questions it
;; produces.  "Summarize this" is very often followed by "now in one
;; sentence", and re-running the action cannot do that: `g' builds a NEW
;; session, so the model has never seen the answer you are talking about.
;;
;; So when a request settles, a `* Follow-up' compose region opens under
;; the answer and the session stays alive.  `C-c C-c' sends what you type
;; there on the SAME session, which is the whole trick: the conversation
;; lives in C (ai-glib owns the message list), so continuing it costs
;; nothing to set up and re-sends nothing.  `C-c C-k' ends it -- cancel,
;; free, close.  `C-c C-p' promotes the whole thing to a real chat buffer
;; when it turns out to be a real conversation, handing the live session
;; over rather than replaying it.
;;
;; That makes the buffer typable, and typable is where this kind of
;; buffer usually goes wrong:
;;
;;   * It is NOT `special-mode'.  The answer carries a `read-only' TEXT
;;     PROPERTY and the compose region does not, so exactly the part
;;     that needs protecting is protected.  (`cmacs-ai-harness-mode'
;;     made the same decision for the same reason.)
;;
;;     A text property rather than a `before-change-functions' guard,
;;     and that is not a style preference: Emacs CLEARS
;;     `before-change-functions' when a function on it signals.  A guard
;;     that signals `text-read-only' therefore protects the buffer
;;     exactly once, and every edit after the user's first stray
;;     keypress goes through.  The property is enforced in C and cannot
;;     be disarmed that way.
;;
;;   * The single-letter keys `q', `w' and `g' are bound through a
;;     `menu-item' `:filter' that returns nil below the compose marker,
;;     so inside the compose region they fall through to
;;     `self-insert-command' and type a q, a w and a g.  Anything added
;;     to this map that is not a `C-c' key has to do the same.
;;
;;   * Under Evil the bare letters are normal-state motions anyway, so
;;     every command also has a `C-c' binding.  Those are the ones that
;;     always work.

;;; Code:

(require 'subr-x)

(declare-function org-mode "org" ())
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback &optional executor))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-session-append-message "cmacs-ai-session.c"
                  (session role text))
(declare-function cmacs-ai-chat-open "cmacs-ai-chat"
                  (&optional provider model directory))
(declare-function cmacs-ai-chat--insert-heading "cmacs-ai-chat"
                  (buf role body &optional level))
(declare-function cmacs-ai-chat--user-label "cmacs-ai-chat" ())
(declare-function cmacs-ai-chat--assistant-label "cmacs-ai-chat" ())
(declare-function cmacs-ai-view-attach "cmacs-ai-view" (&optional arg))
(defvar cmacs-ai-chat-session-pair)
(defvar cmacs-ai-chat--system-applied)

(defgroup cmacs-ai-output nil
  "Result windows for cmacs-ai actions."
  :group 'cmacs
  :prefix "cmacs-ai-output-")

(defcustom cmacs-ai-output-split-threshold 150
  "Frame width, in columns, at or above which results open side by side.

Below it the result window opens underneath instead.  150 columns is
about where two readable columns of prose stop fitting on one screen;
lower it if you run small fonts, raise it if you like wide code."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-output-width 0.42
  "Fraction of the frame given to a side-by-side result window."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ai-output-height 0.4
  "Fraction of the frame given to a result window opened underneath."
  :type 'number
  :safe #'numberp)

(defcustom cmacs-ai-output-select t
  "Whether to select the result window when it opens.
nil leaves point where it was and just shows the result."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-ai-output-followup t
  "Whether a finished result window offers a follow-up compose region.

The cost of this is that the session is kept alive until the window is
closed, instead of being freed the moment the answer lands.  That is a
handle, not a conversation resent -- but it is a handle, so a window
left open for a week is holding one."
  :type 'boolean
  :safe #'booleanp)

(defcustom cmacs-ai-output-followup-sentinel "* Follow-up"
  "The org heading marking the start of the follow-up compose region."
  :type 'string)

;;;; Buffer-local state ------------------------------------------------

(defvar-local cmacs-ai-output--session nil
  "The (CLIENT . SESSION) pair this buffer's conversation runs on.")

(defvar-local cmacs-ai-output--body-start nil
  "Where the answer starts, past the header, for `cmacs-ai-output-copy'.")

(defvar-local cmacs-ai-output--done nil
  "Non-nil once the request finished, failed, or was cancelled.")

(defvar-local cmacs-ai-output--compose-marker nil
  "Start of the editable follow-up region, or nil while there is none.
Everything above it is the answer and is protected from editing.")

(defvar-local cmacs-ai-output--anchor nil
  "Where streamed text lands, when it is not simply the end of the buffer.
Set once a follow-up region exists, so a reply streams above it.")

(defvar-local cmacs-ai-output--turns nil
  "The conversation so far, as a list of (ROLE . TEXT), oldest first.
Kept so `cmacs-ai-output-promote-to-chat' can render a transcript a
resumed chat will still parse.")

(defvar-local cmacs-ai-output--request nil
  "Plist describing the request that produced this buffer.
Keys `:system', `:prompt', `:provider' and `:model'.  Used to build a
session for a follow-up in a buffer whose producer never made one, and
to label the promoted chat.")

(defvar-local cmacs-ai-output--retry nil
  "A closure re-running whatever produced this buffer, for `g'.")

(defvar cmacs-ai-output--allow-edit nil
  "Bound by the code that legitimately writes the answer.
Kept as a distinct name from `inhibit-read-only' so the intent reads
at the call site; both are bound together by `--writing'.")

;;;; Read-only boundary ------------------------------------------------

(defmacro cmacs-ai-output--writing (&rest body)
  "Run BODY with this buffer's own protections lifted."
  (declare (indent 0) (debug t))
  `(let ((cmacs-ai-output--allow-edit t)
         (inhibit-read-only t))
     ,@body))

(defconst cmacs-ai-output--seal-props '(read-only t front-sticky t)
  "Text properties that make the answer region unmodifiable.

`front-sticky' is load-bearing and the obvious alternative is a trap:
the comint idiom is `(read-only t rear-nonsticky t)', and
`rear-nonsticky' makes Emacs decide that inserted text would join
neither neighbouring interval -- which permits insertion in the MIDDLE
of the sealed text, the one place it must not.  Verified by a test.

`front-sticky' instead refuses insertion at the region's leading edge
too.  Nothing is needed at the trailing edge: the follow-up sentinel
line is deliberately left unsealed, so the characters between the
answer and the compose region carry no property to inherit.")

(defun cmacs-ai-output--seal (&optional beg end)
  "Mark BEG..END (default: everything above the compose region) read-only."
  (let ((beg (or beg (point-min)))
        (end (or end (cmacs-ai-output--answer-end))))
    (when (< beg end)
      (cmacs-ai-output--writing
        (add-text-properties beg end cmacs-ai-output--seal-props)))))

(defun cmacs-ai-output--answer-end ()
  "Where the answer stops and the follow-up sentinel begins."
  (if cmacs-ai-output--compose-marker
      (save-excursion
        (goto-char cmacs-ai-output--compose-marker)
        ;; Back over the sentinel line, leaving it unsealed: it is a
        ;; label, and sealing it would put a read-only character
        ;; immediately before the compose region.
        (forward-line -1)
        (max (point-min) (1- (line-beginning-position))))
    (point-max)))

(defun cmacs-ai-output--reading-p ()
  "Non-nil when point is in the answer rather than in the compose area."
  (or (null cmacs-ai-output--compose-marker)
      (< (point) (marker-position cmacs-ai-output--compose-marker))))

(defun cmacs-ai-output--reading-key (command)
  "COMMAND, bound only while point is in the answer.

Below the compose marker the binding evaporates and the key falls
through to `self-insert-command', which is what makes a buffer with
single-letter commands in it typable at all."
  (list 'menu-item "" command
        :filter (lambda (cmd) (and (cmacs-ai-output--reading-p) cmd))))

;;;; Mode --------------------------------------------------------------

(defvar cmacs-ai-output-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Single letters: only while reading.  See `--reading-key'.
    (define-key map (kbd "q") (cmacs-ai-output--reading-key
                               #'cmacs-ai-output-quit))
    (define-key map (kbd "w") (cmacs-ai-output--reading-key
                               #'cmacs-ai-output-copy))
    (define-key map (kbd "g") (cmacs-ai-output--reading-key
                               #'cmacs-ai-output-retry))
    ;; `C-c' keys: always, in every Evil state, from anywhere in the
    ;; buffer.  Under Evil these are the only ones that reliably work.
    (define-key map (kbd "C-c C-c") #'cmacs-ai-output-send-followup)
    (define-key map (kbd "C-c C-k") #'cmacs-ai-output-quit)
    (define-key map (kbd "C-c C-w") #'cmacs-ai-output-copy)
    (define-key map (kbd "C-c C-r") #'cmacs-ai-output-retry)
    (define-key map (kbd "C-c C-p") #'cmacs-ai-output-promote-to-chat)
    (define-key map (kbd "C-c C-a") #'cmacs-ai-view-attach)
    map)
  "Keymap for `cmacs-ai-output-mode'.")

(define-derived-mode cmacs-ai-output-mode org-mode "cmacs-AI-Out"
  "Org buffer holding the result of an AI action, and its follow-ups.

The answer is protected by a text guard rather than by
`buffer-read-only', so the follow-up compose region below it can be
typed in.  See the Commentary in cmacs-ai-output.el before adding a
non-`C-c' key to this map.

\\{cmacs-ai-output-mode-map}"
  ;; Read-only for its whole streaming life, exactly as before: there is
  ;; nowhere to type yet, and the single-letter keys want a buffer that
  ;; does not self-insert.  Lifted when the follow-up region opens, at
  ;; which point the answer above it is sealed with a text property
  ;; instead.
  (setq buffer-read-only t)
  (setq-local org-startup-folded nil)
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

;; Normal state, not insert: the window opens on something to read.
;; `C-c' keys work from every state, which is why they all exist.
(with-eval-after-load 'evil
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'cmacs-ai-output-mode 'normal)))

;;;; Window placement --------------------------------------------------

(defun cmacs-ai-output--display-action ()
  "A `display-buffer' action placing results beside or below.

Beside when the frame is at least `cmacs-ai-output-split-threshold'
columns wide, below otherwise.  Uses a side window so the result never
steals the window you were working in and `quit-window' can take the
whole thing away again."
  (if (>= (frame-width) cmacs-ai-output-split-threshold)
      `(display-buffer-in-side-window
        (side . right) (slot . 0)
        (window-width . ,cmacs-ai-output-width)
        (preserve-size . (t . nil)))
    `(display-buffer-in-side-window
      (side . bottom) (slot . 0)
      (window-height . ,cmacs-ai-output-height)
      (preserve-size . (nil . t)))))

;;;; Public API --------------------------------------------------------

(defun cmacs-ai-output-buffer (title &optional subtitle)
  "Create (or reset) a result buffer called TITLE and return it.

SUBTITLE, when given, is shown under the heading -- normally what the
action was asked to do, so a window left open for a while still says what
produced it.  Any request still streaming into a buffer of the same name
is cancelled first."
  (let ((buf (get-buffer-create (format "*cmacs-ai: %s*" title))))
    (with-current-buffer buf
      (cmacs-ai-output--cancel)
      (cmacs-ai-output--writing
        (erase-buffer)
        (unless (derived-mode-p 'cmacs-ai-output-mode)
          (cmacs-ai-output-mode))
        ;; A reused buffer may have been unlocked by a previous
        ;; follow-up; it is streaming again now.
        (setq buffer-read-only t)
        (insert (format "#+title: %s\n" title))
        (when (and subtitle (not (string-empty-p subtitle)))
          (insert (format "#+subtitle: %s\n" subtitle)))
        (insert "\n")
        (setq cmacs-ai-output--body-start (point-marker))
        (set-marker-insertion-type cmacs-ai-output--body-start nil)
        (setq cmacs-ai-output--done nil
              cmacs-ai-output--compose-marker nil
              cmacs-ai-output--anchor nil
              cmacs-ai-output--turns nil
              cmacs-ai-output--request nil)))
    buf))

(defun cmacs-ai-output-show (buf)
  "Display BUF in a result window, per `cmacs-ai-output-select'."
  (let ((win (display-buffer buf (cmacs-ai-output--display-action))))
    (when (and win cmacs-ai-output-select)
      (select-window win))
    win))

(defun cmacs-ai-output-set-request (buf &rest plist)
  "Record what produced BUF: `:system' `:prompt' `:provider' `:model'.

The prompt is what makes a promoted chat show the question as well as
the answer, and what lets a producer that never opened a session still
support a follow-up."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq cmacs-ai-output--request plist))))

(defun cmacs-ai-output-append (buf text)
  "Append TEXT to result buffer BUF, keeping point at the end if it was.

Called from stream callbacks, which run inside a GLib dispatch: it must
never prompt, never signal into the caller, and never assume the window
still exists."
  (when (and (buffer-live-p buf) text)
    (with-current-buffer buf
      (let* ((cmacs-ai-output--allow-edit t)
             (inhibit-read-only t)
             (anchor (and cmacs-ai-output--anchor
                          (marker-position cmacs-ai-output--anchor)))
             (win (get-buffer-window buf t))
             ;; Only auto-scroll when the user is already at the end;
             ;; scrolling out from under someone reading the top of a long
             ;; answer is infuriating.
             (follow (and win (null anchor)
                          (>= (window-point win) (point-max)))))
        (save-excursion
          (goto-char (or anchor (point-max)))
          (insert text))
        (when follow
          (set-window-point win (point-max)))))))

(defun cmacs-ai-output-attach-session (buf session)
  "Record SESSION as the request streaming into BUF, so `q' can cancel it."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq cmacs-ai-output--session session))))

(defun cmacs-ai-output-finish (buf &optional error-message)
  "Mark BUF's request finished, noting ERROR-MESSAGE when it failed.

The session is deliberately NOT freed here when
`cmacs-ai-output-followup' is on: it holds the conversation, and a
follow-up continues it.  `cmacs-ai-output-quit' and killing the buffer
are what free it."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when error-message
        (cmacs-ai-output--writing
          (save-excursion
            (goto-char (or (and cmacs-ai-output--anchor
                                (marker-position cmacs-ai-output--anchor))
                           (point-max)))
            (insert (format "\n\n* Failed\n%s\n" error-message)))))
      (setq cmacs-ai-output--done t)
      (cmacs-ai-output--record-answer)
      (if (and cmacs-ai-output-followup
               (null error-message)
               (or cmacs-ai-output--session cmacs-ai-output--request))
          (cmacs-ai-output--open-compose)
        (cmacs-ai-output--release)))))

;;;; Turns --------------------------------------------------------------

(defun cmacs-ai-output--answer-region ()
  "The (BEG . END) of the answer this stream just produced."
  (cons (or (and cmacs-ai-output--turns
                 cmacs-ai-output--anchor
                 ;; A follow-up: the reply starts after the heading the
                 ;; send opened, which is where the anchor was placed.
                 (save-excursion
                   (goto-char cmacs-ai-output--anchor)
                   (line-beginning-position)))
            (marker-position cmacs-ai-output--body-start)
            (point-min))
        (or (and cmacs-ai-output--anchor
                 (marker-position cmacs-ai-output--anchor))
            (point-max))))

(defun cmacs-ai-output--record-answer ()
  "Append this stream's question and answer to `cmacs-ai-output--turns'."
  (let* ((region (cmacs-ai-output--answer-region))
         (text (string-trim (buffer-substring-no-properties
                             (car region) (cdr region))))
         (prompt (plist-get cmacs-ai-output--request :prompt)))
    (when (and (null cmacs-ai-output--turns) prompt)
      (push (cons 'user prompt) cmacs-ai-output--turns))
    (unless (string-empty-p text)
      (setq cmacs-ai-output--turns
            (append cmacs-ai-output--turns (list (cons 'assistant text)))))))

;;;; The follow-up region -----------------------------------------------

(defun cmacs-ai-output--open-compose ()
  "Open the follow-up compose region and seal the answer above it."
  (cmacs-ai-output--writing
    (save-excursion
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "\n" cmacs-ai-output-followup-sentinel "\n")
      (setq cmacs-ai-output--compose-marker (point-marker))
      (set-marker-insertion-type cmacs-ai-output--compose-marker nil)))
  (cmacs-ai-output--seal)
  ;; The buffer stops being read-only as a whole the moment there is
  ;; somewhere legitimate to type; the answer keeps its property.
  (setq buffer-read-only nil)
  ;; Streaming no longer belongs at point-max: the compose region is
  ;; there.  Cleared until a follow-up opens its own answer region.
  (setq cmacs-ai-output--anchor nil))

(defun cmacs-ai-output--read-compose ()
  "Return the follow-up text and empty the compose region, or nil."
  (when cmacs-ai-output--compose-marker
    (let* ((start (marker-position cmacs-ai-output--compose-marker))
           (text (string-trim
                  (buffer-substring-no-properties start (point-max)))))
      (unless (string-empty-p text)
        (cmacs-ai-output--writing
          (delete-region start (point-max)))
        text))))

(defun cmacs-ai-output--open-answer (question)
  "Render QUESTION above the compose sentinel and open a reply region.

Returns a marker where the reply streams, with insertion type t so the
blank line separating it from the sentinel is never consumed -- the
same layout `cmacs-ai-chat--insert-heading' produces, and for the same
reason."
  (save-excursion
    (goto-char cmacs-ai-output--compose-marker)
    ;; Back onto the sentinel line itself.
    (forward-line -1)
    (beginning-of-line)
    (cmacs-ai-output--writing
      (insert "* you\n" question "\n\n")
      (insert "* assistant\n\n\n")
      (forward-line -2)
      (let ((m (point-marker)))
        (set-marker-insertion-type m t)
        ;; Seal the question straight away.  The reply below it is
        ;; sealed when the turn settles -- it does not exist yet.
        (cmacs-ai-output--seal (point-min) (marker-position m))
        m))))

;;;; Sessions -----------------------------------------------------------

(defun cmacs-ai-output--ensure-session ()
  "Return this buffer's session pair, making one if the producer made none.

The Tools group renders a tool's return value with no model call at
all, so there is nothing to continue.  Rather than refuse the
follow-up, open a session and seed it with the answer already on
screen -- the model then has the same context a reader of the window
does."
  (or cmacs-ai-output--session
      (progn
        ;; The producer that skipped the session may also be the first
        ;; thing in this Emacs to need cmacs-ai at all.
        (require 'cmacs-ai)
        nil)
      (let* ((req cmacs-ai-output--request)
             (pair (cmacs-ai-make-session (plist-get req :provider)
                                          (plist-get req :model)
                                          (plist-get req :system))))
        (setq cmacs-ai-output--session pair)
        (dolist (turn cmacs-ai-output--turns)
          (ignore-errors
            (cmacs-ai-session-append-message
             (cdr pair)
             (symbol-name (car turn))
             (cdr turn))))
        pair)))

;;;; Cancellation ------------------------------------------------------

(defun cmacs-ai-output--release ()
  "Free the session attached to this buffer, if any."
  (when cmacs-ai-output--session
    (when (fboundp 'cmacs-ai-free-session)
      (ignore-errors (cmacs-ai-free-session cmacs-ai-output--session)))
    (setq cmacs-ai-output--session nil)))

(defun cmacs-ai-output--cancel ()
  "Cancel any in-flight request streaming into this buffer."
  (when (and cmacs-ai-output--session (not cmacs-ai-output--done))
    (when (fboundp 'cmacs-ai-chat-cancel)
      (ignore-errors (cmacs-ai-chat-cancel (cdr cmacs-ai-output--session))))
    (setq cmacs-ai-output--done t))
  (cmacs-ai-output--release))

;;;; Commands ----------------------------------------------------------

(defun cmacs-ai-output-quit ()
  "Cancel anything still running, drop the conversation, close the window.

Bound to `q' and to `C-c C-k'.  Ending it is the point: a result window
you have dismissed is one you have stopped reading, a model that keeps
generating into it is spending money on nobody, and a session nobody
will continue is a handle held for nothing."
  (interactive)
  (cmacs-ai-output--cancel)
  (quit-window))

(defun cmacs-ai-output-copy ()
  "Copy the answer to the kill ring, without the header or the compose area."
  (interactive)
  (let ((beg (or (and cmacs-ai-output--body-start
                      (marker-position cmacs-ai-output--body-start))
                 (point-min)))
        (end (if cmacs-ai-output--compose-marker
                 (save-excursion
                   (goto-char cmacs-ai-output--compose-marker)
                   (forward-line -1)
                   (line-beginning-position))
               (point-max))))
    (copy-region-as-kill beg (max beg end))
    (message "cmacs-ai: copied %d characters" (- (max beg end) beg))))

(defun cmacs-ai-output-set-retry (buf fn)
  "Record FN as the way to re-run whatever produced BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf (setq cmacs-ai-output--retry fn))))

(defun cmacs-ai-output-retry ()
  "Run the action that produced this buffer again, from scratch.

Not a follow-up: this discards the conversation and asks the original
question again on a new session.  `C-c C-c' is what continues."
  (interactive)
  (if (functionp cmacs-ai-output--retry)
      (funcall cmacs-ai-output--retry)
    (user-error "cmacs-ai: nothing to re-run here")))

(defun cmacs-ai-output-send-followup ()
  "Send the follow-up you typed, continuing the same conversation."
  (interactive)
  (unless cmacs-ai-output--compose-marker
    (user-error "cmacs-ai: no follow-up region here%s"
                (if cmacs-ai-output--done "" " yet -- still generating")))
  (let ((text (cmacs-ai-output--read-compose)))
    (unless text (user-error "cmacs-ai: follow-up is empty"))
    (let* ((buf (current-buffer))
           (pair (cmacs-ai-output--ensure-session))
           (streamed 0))
      (setq cmacs-ai-output--turns
            (append cmacs-ai-output--turns (list (cons 'user text))))
      (setq cmacs-ai-output--anchor (cmacs-ai-output--open-answer text))
      (setq cmacs-ai-output--done nil)
      (cmacs-ai-chat-stream
       (cdr pair) text
       (lambda (payload)
         (pcase (car-safe payload)
           (:delta
            (let ((chunk (cadr payload)))
              (when chunk
                (setq streamed (+ streamed (length chunk)))
                (cmacs-ai-output-append buf chunk))))
           (:end
            (let ((final (plist-get (cdr payload) :text)))
              (when (and final (zerop streamed))
                (cmacs-ai-output-append buf final)))
            (cmacs-ai-output--settle-followup buf nil))
           (:error
            (cmacs-ai-output--settle-followup
             buf (or (cadr payload) "stream error")))))))))

(defun cmacs-ai-output--settle-followup (buf error-message)
  "Close a follow-up turn in BUF, noting ERROR-MESSAGE when it failed."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when error-message
        (cmacs-ai-output--writing
          (save-excursion
            (goto-char cmacs-ai-output--anchor)
            (insert (format "\n[failed: %s]" error-message)))))
      (setq cmacs-ai-output--done t)
      (cmacs-ai-output--record-answer)
      ;; The compose region is already there; just stop streaming into
      ;; the region above it, and seal what arrived.
      (setq cmacs-ai-output--anchor nil)
      (cmacs-ai-output--seal))))

(defun cmacs-ai-output-promote-to-chat ()
  "Move this conversation into a real chat buffer and close this window.

For when a follow-up turned out to be the start of something: a chat
buffer has saving and resuming, the tool loop, `/image', and a provider
you can choose.  The live session is handed over rather than replayed,
so the model keeps the context it already has and nothing is re-sent."
  (interactive)
  (require 'cmacs-ai-chat)
  (unless cmacs-ai-output--session
    (user-error "cmacs-ai: nothing to promote -- no conversation here"))
  (let* ((pair cmacs-ai-output--session)
         (req cmacs-ai-output--request)
         (turns cmacs-ai-output--turns)
         (buf (current-buffer))
         (chat (cmacs-ai-chat-open (plist-get req :provider)
                                   (plist-get req :model))))
    (with-current-buffer chat
      ;; The chat made its own session on open; it has never been used,
      ;; and leaving it attached would leak it.
      (when (and cmacs-ai-chat-session-pair
                 (not (eq cmacs-ai-chat-session-pair pair)))
        (ignore-errors (cmacs-ai-free-session cmacs-ai-chat-session-pair)))
      (setq-local cmacs-ai-chat-session-pair pair)
      ;; The promoted session already carries a system prompt -- the
      ;; action's, which is the one this conversation has been held
      ;; under.  Do not let the first send replace it.
      (setq-local cmacs-ai-chat--system-applied t)
      (dolist (turn turns)
        (cmacs-ai-chat--insert-heading
         chat
         (if (eq (car turn) 'user)
             (cmacs-ai-chat--user-label)
           (cmacs-ai-chat--assistant-label))
         (cdr turn))))
    ;; Clear ours BEFORE killing, or the kill hook frees the session the
    ;; chat is now holding.
    (with-current-buffer buf
      (setq cmacs-ai-output--session nil)
      (setq cmacs-ai-output--done t))
    (let ((win (get-buffer-window buf t)))
      (when win (quit-window nil win)))
    (kill-buffer buf)
    (pop-to-buffer chat)
    chat))

;;;; Teardown ----------------------------------------------------------

(defun cmacs-ai-output--kill-hook ()
  "Cancel a request whose result buffer is being killed."
  (when (derived-mode-p 'cmacs-ai-output-mode)
    (cmacs-ai-output--cancel)))

(add-hook 'kill-buffer-hook #'cmacs-ai-output--kill-hook)

(provide 'cmacs-ai-output)

;;; cmacs-ai-output.el ends here
