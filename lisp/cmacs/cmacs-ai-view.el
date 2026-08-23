;;; cmacs-ai-view.el --- What the user is looking at  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The one place that answers "what is on the user's screen right now".
;;
;; A chat buffer is the one place in cmacs where `cmacs-ai-target-at'
;; gives the wrong answer: it resolves to the conversation, because that
;; is what point is in.  But "please review the first paragraph here"
;; does not mean the chat -- it means the file the user was reading a
;; second ago, still visible in the window next door.
;;
;; So this module answers a different question from the target layer: not
;; "what is under point" but "what else is on screen".  Everything that
;; talks to a model -- `cmacs-ai-chat', both libreclaw chat surfaces, and
;; the `current_view' MCP tool -- goes through here, so they all agree
;; about what "here" means.
;;
;; WHAT IS SENT, AND WHY IT IS SO SMALL
;;
;; The obvious implementation attaches the visible buffers' text to every
;; turn.  That is wrong twice over: it is paid for on every turn of a
;; conversation rather than once, and it is usually unnecessary, because
;; a model with the cmacs MCP surface can read any buffer it likes with
;; `get_buffer_content'.
;;
;; So the default is a HINT, not a payload.  A standing instruction goes
;; in the system prompt -- generic references mean the visible buffers,
;; here is how to read them -- and each turn carries a short INVENTORY:
;; buffer name, file, mode, where point is, which lines are on screen.
;; A few hundred bytes.  Never the text.
;;
;; That only works where there are tools.  A plain HTTP provider with no
;; tool executor cannot act on the hint at all, so for those the content
;; IS inlined (`inline' mode) -- clipped, and deduplicated so an
;; unchanged buffer is not re-sent on every turn.  Getting this
;; distinction wrong is the difference between the feature working and
;; the model politely explaining that it cannot see your screen.
;;
;; `C-c C-a' (`cmacs-ai-view-attach') forces the payload regardless: it
;; drops the visible buffers into the compose area as ordinary editable
;; text, so you can trim it before sending and it stays in the saved
;; transcript.

;;; Code:

(require 'subr-x)
(require 'cl-lib)

(declare-function cmacs-ai-target-at "cmacs-ai-target" (&optional click))
(declare-function cmacs-ai-target-p "cmacs-ai-target" (obj))
(declare-function cmacs-ai-target-prompt-context "cmacs-ai-target" (target))

(defgroup cmacs-ai-view nil
  "What the model is told about the user's screen."
  :group 'cmacs
  :prefix "cmacs-ai-view-")

;;;; Configuration -----------------------------------------------------

(defcustom cmacs-ai-view-attach-mode 'hint
  "Whether chats are told what else is on the user's screen.

`hint' -- the standing instruction goes in the system prompt and each
turn carries a short inventory of the visible buffers.  Their text is
sent only where the surface has no tools to fetch it with, and only
when it has changed.

`off' -- nothing is sent.  `cmacs-ai-view-attach' still works on
demand, so this disables the automatic half only.

Worth knowing what `hint' costs in privacy rather than tokens: the
names and file paths of every buffer you have on screen go to the
provider with every message, whether or not the conversation is about
them."
  :type '(choice (const :tag "Hint, with an inventory each turn" hint)
                 (const :tag "Nothing automatic" off))
  :safe #'symbolp)

(defcustom cmacs-ai-view-exclude-modes
  '(cmacs-ai-chat-mode
    cmacs-ai-output-mode
    cmacs-ai-harness-mode
    cmacs-ai-harness-compose-mode
    cmacs-libreclaw-room-mode
    cmacs-libreclaw-cmacs-channel-room-mode
    cmacs-libreclaw-hatch-mode
    cmacs-brigade-dashboard-mode
    cmacs-brigade-compose-mode
    minibuffer-mode
    minibuffer-inactive-mode)
  "Major modes never reported as something the user is looking at.

The AI surfaces themselves, in other words.  A chat that listed itself
as context would answer questions about your question, which is the
exact failure this whole module exists to prevent.

Modes are matched with `derived-mode-p', so naming a parent excludes
its children."
  :type '(repeat symbol))

(defcustom cmacs-ai-view-exclude-name-regexps
  '("\\` " "\\`\\*Minibuf" "\\`\\*Echo Area" "\\`\\*Backtrace\\*\\'")
  "Buffer names never reported as something the user is looking at.

Space-prefixed internal buffers, and the odd surface that shares a mode
with something legitimate.  Matched with `string-match-p'."
  :type '(repeat regexp))

(defcustom cmacs-ai-view-max-buffers 8
  "Most visible buffers reported in one inventory.

A tiling session can have a dozen windows open, and past a handful the
listing stops telling a model anything it can act on.  The excess is
counted, not silently dropped."
  :type 'integer
  :safe #'integerp)

(defcustom cmacs-ai-view-inline-max-chars 12000
  "Total characters of buffer text inlined in `inline' mode.

Only reached where the surface has no tools, so this is the budget for
the whole fallback rather than a per-buffer clip.  Individual buffers
are clipped first by `cmacs-ai-target-max-chars'."
  :type 'integer
  :safe #'integerp)

;;;; Which buffers ------------------------------------------------------

(defvar cmacs-ai-view--last nil
  "The last non-excluded buffer that was selected.

The fallback for a chat that is alone on the frame: with nothing else
on screen there is no window to read, but there is still an obvious
answer to \"what were you just looking at\".")

(defun cmacs-ai-view--excluded-p (buffer)
  "Non-nil when BUFFER must never be reported as visible."
  (or (not (buffer-live-p buffer))
      (with-current-buffer buffer
        (or (apply #'derived-mode-p cmacs-ai-view-exclude-modes)
            (let ((name (buffer-name)))
              (cl-some (lambda (re) (string-match-p re name))
                       cmacs-ai-view-exclude-name-regexps))))))

(defun cmacs-ai-view--record-selection (&optional _window)
  "Remember the selected buffer when it is one the model may be told about."
  (let ((buf (current-buffer)))
    (unless (cmacs-ai-view--excluded-p buf)
      (setq cmacs-ai-view--last buf))))

(defun cmacs-ai-view--windows ()
  "Every live window on a visible frame, minibuffers excluded."
  (let (wins)
    (dolist (frame (visible-frame-list))
      (dolist (win (window-list frame 'no-minibuf))
        (when (window-live-p win)
          (push win wins))))
    (nreverse wins)))

(defun cmacs-ai-view-windows (&optional include-current)
  "Windows showing something the model may be told the user is looking at.

Ordered most-recently-selected first, so the first entry is the buffer
a bare \"here\" most likely means.  The selected window is dropped
unless INCLUDE-CURRENT, because the caller is normally the chat itself.

One window per buffer: the same file in two windows is one thing the
user is looking at, not two."
  (let* ((selected (selected-window))
         (recency (buffer-list))
         (seen (make-hash-table :test 'eq))
         wins)
    (dolist (win (cmacs-ai-view--windows))
      (let ((buf (window-buffer win)))
        (unless (or (gethash buf seen)
                    (and (not include-current) (eq win selected))
                    (cmacs-ai-view--excluded-p buf))
          (puthash buf t seen)
          (push win wins))))
    (cl-flet ((rank (win)
                (or (cl-position (window-buffer win) recency :test #'eq)
                    most-positive-fixnum)))
      (sort (nreverse wins) (lambda (a b) (< (rank a) (rank b)))))))

;;;###autoload
(defun cmacs-ai-view-buffers (&optional include-current)
  "Buffers the user can currently see, most recently selected first.

INCLUDE-CURRENT keeps the selected window's buffer, which the caller
normally does not want -- it is the chat asking the question.

Falls back to `cmacs-ai-view--last' when nothing else is on screen, so
a chat filling the frame still knows what it was opened from."
  (let ((bufs (mapcar #'window-buffer
                      (cmacs-ai-view-windows include-current))))
    (or bufs
        (and (buffer-live-p cmacs-ai-view--last)
             (not (eq cmacs-ai-view--last (current-buffer)))
             (not (cmacs-ai-view--excluded-p cmacs-ai-view--last))
             (list cmacs-ai-view--last)))))

;;;; Describing them ----------------------------------------------------

(defun cmacs-ai-view--visible-lines (win)
  "The (FIRST . LAST) line numbers on screen in WIN, or nil."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (let ((start (window-start win))
            (end (ignore-errors (window-end win t))))
        (when (and start end)
          (cons (line-number-at-pos start)
                (line-number-at-pos (min end (point-max)))))))))

(defun cmacs-ai-view--describe-buffer (buf &optional win)
  "One inventory line for BUF, shown in WIN."
  (with-current-buffer buf
    (let* ((file (buffer-file-name))
           (lines (count-lines (point-min) (point-max)))
           (visible (and win (cmacs-ai-view--visible-lines win)))
           (region (and (region-active-p)
                        (cons (line-number-at-pos (region-beginning))
                              (line-number-at-pos (region-end))))))
      (string-join
       (delq nil
             (list (buffer-name)
                   (and file (abbreviate-file-name file))
                   (symbol-name major-mode)
                   (format "%d lines" lines)
                   (format "point on line %d" (line-number-at-pos (point)))
                   (and visible
                        (format "showing lines %d-%d"
                                (car visible)
                                (max (car visible)
                                     (min lines (cdr visible)))))
                   (and region
                        (format "REGION ACTIVE, lines %d-%d"
                                (car region) (cdr region)))))
       " | "))))

;;;###autoload
(defun cmacs-ai-view-inventory (&optional include-current)
  "A short listing of what the user has on screen, or nil for nothing.

Names, files, modes and positions -- deliberately NOT the buffers'
text.  This is what rides every turn, so it has to stay cheap; the text
is what the model fetches with a tool, or what
`cmacs-ai-view-attach' sends when you ask for it."
  (let ((wins (cmacs-ai-view-windows include-current)))
    (when (or wins (cmacs-ai-view-buffers include-current))
      (let* ((pairs (if wins
                        (mapcar (lambda (w) (cons (window-buffer w) w)) wins)
                      (mapcar (lambda (b) (cons b nil))
                              (cmacs-ai-view-buffers include-current))))
             (total (length pairs))
             (shown (seq-take pairs cmacs-ai-view-max-buffers))
             (n 0))
        (concat
         "[cmacs: on the user's screen right now]\n"
         (mapconcat
          (lambda (pair)
            (setq n (1+ n))
            (format "%d. %s" n (cmacs-ai-view--describe-buffer
                                (car pair) (cdr pair))))
          shown "\n")
         (when (> total cmacs-ai-view-max-buffers)
           (format "\n(%d more visible buffer(s) not listed)"
                   (- total cmacs-ai-view-max-buffers))))))))

;;;###autoload
(defun cmacs-ai-view-context (&optional buffers)
  "The full context of BUFFERS (default: the visible ones), or nil.

Each buffer is resolved through `cmacs-ai-target-at', so this inherits
the whole resolver stack: an active region wins over the buffer, and a
mail message, a terminal's last command, an org subtree, a dired
selection or a diff hunk are each understood as themselves.  Clipping
is `cmacs-ai-target-max-chars', already applied per target."
  (require 'cmacs-ai-target)
  (require 'cmacs-ai-targets nil t)
  (let ((bufs (or buffers (cmacs-ai-view-buffers)))
        parts)
    (dolist (buf bufs)
      (when (buffer-live-p buf)
        (let ((target (with-current-buffer buf
                        (save-excursion (cmacs-ai-target-at)))))
          (when (and target (cmacs-ai-target-p target))
            (push (format "--- %s ---\n%s"
                          (buffer-name buf)
                          (cmacs-ai-target-prompt-context target))
                  parts)))))
    (when parts
      (string-join (nreverse parts) "\n\n"))))

(defun cmacs-ai-view--clip (text limit)
  "Return TEXT clipped to LIMIT characters, noting what was dropped."
  (if (or (null text) (null limit) (<= (length text) limit))
      text
    (concat (substring text 0 limit)
            (format "\n\n[... %d characters elided; ask for the rest ...]"
                    (- (length text) limit)))))

;;;; What the model is told ---------------------------------------------

(defconst cmacs-ai-view--hint-common
  "The user is working inside cmacs (an Emacs fork).  This conversation \
is one buffer among several on their screen.  When they say \"here\", \
\"this\", \"the above\", \"that function\", or otherwise point at \
something without naming it, they mean one of the OTHER visible \
buffers -- not this conversation, and not the message they just typed.

Their turns are preceded by a [cmacs: on the user's screen right now] \
block listing what is visible: buffer name, file, mode, where point is, \
and which lines are on screen."
  "The half of the standing hint that does not depend on tool access.")

(defun cmacs-ai-view-hint (mode)
  "The standing instruction for MODE, or nil when there is nothing to say.

MODE is `tools' where the surface can read the user's editor -- a chat
with a tool executor, a CLI agent, or a libreclaw agent with the cmacs
MCP server tunnelled to it -- and `inline' where it cannot.

The distinction is the whole feature.  Telling a model to \"read the
buffer with your tools\" when it has none produces a polite refusal and
nothing else.

Returns nil when `cmacs-ai-view-attach-mode' is `off', so turning the
feature off is one check in one place rather than a condition at every
call site."
  (pcase (and (not (eq cmacs-ai-view-attach-mode 'off)) mode)
    ('tools
     (concat cmacs-ai-view--hint-common
             "\n\nThe block lists the buffers; it does not contain their \
text.  Read what you need before answering: `get_buffer_content' for a \
whole buffer, `search_buffer' to find something inside one, \
`current_view' to re-read the screen if the listing looks stale.  Ask \
which buffer only when the listing is genuinely ambiguous -- with one \
obvious candidate, just read it."))
    ('inline
     (concat cmacs-ai-view--hint-common
             "\n\nYou have no tools for reading their editor, so the \
visible buffers are included below in full, clipped.  Work from what is \
there, and say plainly when the answer needs a part you were not sent."))
    (_ nil)))

(defun cmacs-ai-view-signature (&optional include-current)
  "A value that changes when the screen or the visible buffers change.

Used to avoid re-sending an identical inventory on every turn.  Keys on
each buffer's `buffer-chars-modified-tick' as well as the window
layout, so an edit counts as a change even when the listing would read
the same."
  (mapcar (lambda (win)
            (let ((buf (window-buffer win)))
              (list (buffer-name buf)
                    (buffer-chars-modified-tick buf)
                    (window-start win)
                    (with-current-buffer buf (point)))))
          (cmacs-ai-view-windows include-current)))

(defun cmacs-ai-view-turn-block (mode &optional last-signature)
  "The per-turn context block for MODE, as (TEXT . SIGNATURE).

TEXT is nil when `cmacs-ai-view-attach-mode' is `off' or nothing is
visible.  When the screen has not changed since LAST-SIGNATURE the text
collapses to a single line -- the model still needs to know the context
is standing, but not to be told it twice."
  (if (eq cmacs-ai-view-attach-mode 'off)
      (cons nil nil)
    (let ((sig (cmacs-ai-view-signature))
          (inventory (cmacs-ai-view-inventory)))
      (cond
       ((null inventory) (cons nil sig))
       ((and last-signature (equal sig last-signature))
        (cons "[cmacs: on the user's screen right now] unchanged since the \
previous message."
              sig))
       (t
        (cons (if (eq mode 'inline)
                  (let ((content (cmacs-ai-view-context)))
                    (if content
                        (concat inventory "\n\n"
                                (cmacs-ai-view--clip
                                 content cmacs-ai-view-inline-max-chars))
                      inventory))
                inventory)
              sig))))))

;;;###autoload
(defun cmacs-ai-view-report (&optional include-content)
  "What the user is looking at, as a plain string for an MCP client.

With INCLUDE-CONTENT, the buffers' text is appended as well.  This is
what the `current_view' MCP tool returns, and it is the thing a remote
agent should call when the inventory in its prompt looks stale."
  (let ((inventory (cmacs-ai-view-inventory t)))
    (cond
     ((null inventory) "Nothing is visible: no buffer is on screen.")
     ((null include-content) inventory)
     (t (let ((content (cmacs-ai-view-context)))
          (if content (concat inventory "\n\n" content) inventory))))))

;;;; Forcing it ---------------------------------------------------------

(defcustom cmacs-ai-view-attach-preamble
  "For context, here is what I have on screen:"
  "Line introducing an explicit attach in a compose area."
  :type 'string)

(defun cmacs-ai-view--compose-marker ()
  "The compose marker of whichever chat surface this buffer is, or nil."
  (or (bound-and-true-p cmacs-ai-chat--compose-marker)
      (bound-and-true-p cmacs-libreclaw-room--compose-marker)
      (bound-and-true-p cmacs-ai-output--compose-marker)))

;;;###autoload
(defun cmacs-ai-view-attach (&optional arg)
  "Insert what is on screen into this chat's compose area.

The automatic half of this feature sends a listing and lets the model
fetch what it needs.  This is the override: the buffers' actual text,
in the compose area as ordinary editable text, so you can trim it
before sending and it survives in the saved transcript.

With a prefix ARG, choose which visible buffers to attach."
  (interactive "P")
  (let ((marker (cmacs-ai-view--compose-marker)))
    (unless marker
      (user-error "cmacs-ai-view: not in a chat compose buffer"))
    (let* ((available (cmacs-ai-view-buffers t))
           (available (delq (current-buffer) available)))
      (unless available
        (user-error "cmacs-ai-view: nothing else is on screen"))
      (let* ((chosen
              (if (null arg)
                  available
                (let ((names (completing-read-multiple
                              "Attach buffers: "
                              (mapcar #'buffer-name available) nil t)))
                  (or (mapcar #'get-buffer names) available))))
             (content (cmacs-ai-view-context chosen)))
        (unless content
          (user-error "cmacs-ai-view: nothing readable in those buffers"))
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert (format "%s\n\n#+begin_example\n%s\n#+end_example\n"
                        cmacs-ai-view-attach-preamble content))
        (goto-char (point-max))
        (message "cmacs-ai-view: attached %d buffer(s), %d characters"
                 (length chosen) (length content))))))

;;;; Tracking -----------------------------------------------------------

;; Cheap and always on: one function on the hook that already fires for
;; every window selection, doing nothing but a `setq' on the buffers it
;; is allowed to remember.  It exists only for the frame where the chat
;; is the only window, which is common enough on a laptop.
(add-hook 'window-selection-change-functions #'cmacs-ai-view--record-selection)

(provide 'cmacs-ai-view)

;;; cmacs-ai-view.el ends here
