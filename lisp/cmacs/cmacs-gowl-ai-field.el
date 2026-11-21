;;; cmacs-gowl-ai-field.el --- AI commands on any application's text field -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; With the keyboard in a text field of ANY window -- a browser's
;; comment box, a chat client, a form -- `cmacs-gowl-ai-field' reads the
;; field, runs one cmacs-ai text action on it (fix the grammar, rewrite
;; it, shorten it, translate it, or whatever you ask for), and writes
;; the answer straight back into the field.  No Emacs frame opens: this
;; is the sibling of `cmacs-gowl-edit-field', which brings the text to
;; Emacs; here the model's answer goes to the text.
;;
;; It needs `cmacs --gowl', for the same reason the editor does: only
;; the compositor sits between an application and its input method.
;;
;; WHAT IS REUSED.  Reaching the field is cmacs-gowl-edit-field.el's
;; business and stays there: the text-input-v3 read, the clipboard
;; fallback, the read-again-before-writing check, the deny lists and
;; the refusal of password fields are that file's, used through its
;; headless sessions (`cmacs-gowl-edit-field-read-async' and
;; `-write-async').  The prompts are cmacs-ai-textops.el's: an action
;; here names one of its operations (`proofread', `rephrase') and says
;; HOW, so the system prompts you customised for the region commands
;; are the ones a text field gets.
;;
;; WHAT IS ACTED ON.  The selection, when the application reports one;
;; otherwise the whole of the text it reported.  (Through the clipboard
;; fallback a selection cannot be learnt, so it is always the whole
;; field.)  A field longer than text-input can carry is seen as a
;; window around the cursor; only that window is rewritten, and the
;; toast says so.
;;
;; THE ANSWER IS WRITTEN ONCE.  The model streams, but an application
;; cannot take a stream of edits reliably, so the answer is collected
;; and sent as one edit when it is complete -- one undo step in the
;; application.  Progress is a toast on the gowl bar.
;;
;; NEVER THE WRONG WINDOW.  When the answer arrives, the window that
;; was asked about must still hold the keyboard, and its field must
;; still hold the text that was read.  If either is not so, nothing is
;; typed anywhere: the answer goes to the kill ring and a toast says
;; so.  This file never moves focus to make a write possible.
;;
;; UNDO.  The text as it was is kept, and `cmacs-gowl-ai-field-undo'
;; puts it back while the same window is focused and its field still
;; holds the answer.  (The application's own undo works too: it saw
;; one edit.)
;;
;; PRIVACY.  The text of the field is sent to a model -- that is the
;; whole point, and the user asked for it by name, so the text itself
;; is NOT passed through `cmacs-redact-text': a rewrite of text with
;; holes punched in it would be written back over the original.  What
;; IS honoured, before anything is read:
;;   - `cmacs-gowl-edit-field-deny' (password managers, prompts, locks);
;;   - the redaction rule set, asked about the WINDOW
;;     (`cmacs-redact-window'): a window the rules exclude is refused,
;;     and so is every window while the rules have failed to load;
;;   - a field its application marks as a password or PIN.
;; Nothing but the field's text and the instruction reaches the model:
;; not the window's title, not its application.
;;
;; NOTHING BLOCKS the compositor.  Every wait -- for the application,
;; for the menu card, for the model -- is a callback or a timer.  The
;; one exception is typing a free-form instruction, which is a
;; minibuffer read on Emacs's thread, as the gowl menu's is; the
;; desktop keeps running under it.
;;
;; Setup, in an init file:
;;
;;   (add-hook 'cmacs-gowl-mode-hook #'cmacs-gowl-ai-field-setup)
;;
;; which binds `cmacs-gowl-ai-field-key' (Super+Ctrl+a) in the
;; compositor.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-gowl-edit-field)

(declare-function gowl-running-p "cmacs-gowl")
(declare-function gowl-focused-client "cmacs-gowl")
(declare-function gowl-focus-client "cmacs-gowl")
(declare-function gowl-list-clients "cmacs-gowl")
(declare-function gowl-client-info "cmacs-gowl")
(declare-function gowl-client-pid "cmacs-gowl")
(declare-function gowl-add-rule-entry "cmacs-gowl")
(declare-function gowl-remove-rule "cmacs-gowl")
(declare-function gowl-add-keybind "cmacs-gowl")
(declare-function gowl-remove-keybind "cmacs-gowl")
(declare-function gowl-run-command "cmacs-gowl.c" (line))
(declare-function gowl-bar-notify "cmacs-gowl.c" (summary &optional body panel))
(declare-function cmacs-redact-window "cmacs-redact" (app title &optional pid))
(declare-function cmacs-ai--ensure "cmacs-ai" ())
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-free-session "cmacs-ai" (pair))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-textops--spec "cmacs-ai-textops" (op))
(declare-function cmacs-ai-textops--prompt "cmacs-ai-textops"
                  (spec target refinement))
(declare-function cmacs-ai-target-create "cmacs-ai-target" (&rest args))
(declare-function cmacs-ai-proofread--strip-wrapping "cmacs-ai-proofread"
                  (text original))

(defvar cmacs-ai-textops-provider)
(defvar cmacs-ai-textops-model)
(defvar cmacs-ai-target-max-chars)

;;;; Options

(defgroup cmacs-gowl-ai-field nil
  "AI commands on another application's text field."
  :group 'cmacs-gowl
  :prefix "cmacs-gowl-ai-field-")

(defcustom cmacs-gowl-ai-field-key "Super+Ctrl+a"
  "The gowl key that runs `cmacs-gowl-ai-field', or nil for none.
Bound by `cmacs-gowl-ai-field-setup', and by nothing else.  While an
action is running the same key offers to cancel it."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-undo-key nil
  "The gowl key that runs `cmacs-gowl-ai-field-undo', or nil for none.
The chooser offers the undo as a row whenever there is one to make, so
a key of its own is a convenience."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-cancel-key nil
  "The gowl key that runs `cmacs-gowl-ai-field-cancel', or nil for none."
  :type '(choice (const :tag "No key" nil) string)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-action-keys nil
  "Gowl keys that run one action directly: an alist of (KEY . ACTION).
ACTION is a name from `cmacs-gowl-ai-field-actions'.  For example
\((\"Super+Ctrl+g\" . proofread)) fixes the grammar of the focused field
with one chord and no menu."
  :type '(alist :key-type string :value-type symbol)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-translate-language "English"
  "The language the `translate' action translates into."
  :type 'string
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-actions
  '((proofread :label "Fix spelling and grammar" :op proofread)
    (rewrite :label "Rewrite: clearer and tighter" :op rephrase)
    (shorten :label "Shorten" :op rephrase
             :how "Make it substantially shorter.  Keep every fact and \
the author's voice.")
    (formal :label "More formal" :op rephrase
            :how "Make the register more formal and professional, \
without making it longer.")
    (friendly :label "Friendlier" :op rephrase
              :how "Make the tone warmer and more friendly, without \
making it longer.")
    (translate :label "Translate" :op rephrase
               :how cmacs-gowl-ai-field-translate-how)
    (custom :label "Custom instruction..." :op rephrase :ask t))
  "The actions `cmacs-gowl-ai-field' offers, in menu order.
An alist of (NAME . PLIST).  The keys of PLIST:

  :label   the menu row.
  :op      the cmacs-ai text operation that supplies the prompts: a
           name in `cmacs-ai-textops--specs' whose answer REPLACES the
           text, which is `proofread' or `rephrase'.  Its system prompt
           is the one the region commands use
           (`cmacs-ai-proofread-system-prompt',
           `cmacs-ai-rephrase-system-prompt'), read when the action
           runs, so customising it there changes it here.
  :how     how to perform the operation: a string, or a function of no
           arguments returning one.  Omitted, the operation's own
           default (\"fix only spelling, grammar and punctuation\",
           \"clearer, tighter and more direct\").
  :ask     non-nil reads :how from the user when the action is chosen.
  :system  a system prompt of your own, a string, instead of :op's.

Whatever the model answers replaces the text, so a :system of your own
must make it answer with the new text and nothing else."
  :type '(alist :key-type symbol :value-type plist)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-provider nil
  "The cmacs-ai provider for field actions, a symbol, or nil.
nil uses what the region text commands use: `cmacs-ai-textops-provider'
with `cmacs-ai-textops-model' (and, where those are nil, cmacs-ai's own
defaults).  Non-nil, `cmacs-gowl-ai-field-model' goes with it."
  :type '(choice (const :tag "As the text commands" nil) symbol)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-model nil
  "The model for field actions, a string, or nil.
With `cmacs-gowl-ai-field-provider' nil, nil means
`cmacs-ai-textops-model'.  With a provider set here, nil means that
provider's default model."
  :type '(choice (const :tag "Default" nil) string)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-chooser 'card
  "Where the list of actions is shown.
`card': gowl's menu card, drawn by the compositor over the application
\(the `menu-choose' command of the menu module), falling back to the
minibuffer when the card is not available.  `minibuffer': a small
floating minibuffer frame, with whatever completion you have
configured."
  :type '(choice (const :tag "The gowl menu card" card)
                 (const :tag "A minibuffer frame" minibuffer))
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-clipboard-fallback t
  "Non-nil lets a field be reached through the clipboard fallback.
That is `cmacs-gowl-edit-field-fallback', with its deny list, for
windows that have no text input.  A field read that way cannot say
that it is a password field; applications do not copy out of those,
but set this to nil if you would rather the model only ever saw text
an application described over text-input."
  :type 'boolean
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-max-chars 20000
  "The longest text, in characters, that is sent to the model.
A longer field is refused.  `cmacs-ai-target-max-chars' is a second
limit: text it would clip is refused too, since a rewrite of clipped
text would be written back over the whole."
  :type 'natnum
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-timeout 120
  "Seconds to wait for the model before giving up, or nil to wait forever."
  :type '(choice (const :tag "No limit" nil) number)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-progress-interval 5
  "Seconds between progress toasts while the model answers, or nil for none.
The toast at the start and the one at the end are shown either way."
  :type '(choice (const :tag "No progress toasts" nil) number)
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-toast t
  "Non-nil reports on the gowl bar as well as in the echo area.
The echo area is in an Emacs frame, which is not where the eyes are
when this runs."
  :type 'boolean
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-prompt-frame-name "cmacs-ai-field-prompt"
  "The name, and so the window title, of the minibuffer frame.
It is used for a free-form instruction and for the minibuffer chooser;
a gowl window rule floats windows with exactly this title."
  :type 'string
  :group 'cmacs-gowl-ai-field)

(defcustom cmacs-gowl-ai-field-prompt-frame-width 80
  "The width, in columns, of the minibuffer frame."
  :type 'natnum
  :group 'cmacs-gowl-ai-field)

;;;; Pure helpers

(defun cmacs-gowl-ai-field-translate-how ()
  "Return the instruction of the `translate' action."
  (format "Translate it into %s.  Keep the meaning, the tone and the \
formatting; translate, do not comment."
          cmacs-gowl-ai-field-translate-language))

(defun cmacs-gowl-ai-field--action (name)
  "Return the plist of the action NAME, or nil."
  (alist-get name cmacs-gowl-ai-field-actions))

(defun cmacs-gowl-ai-field--label (name)
  "Return the menu label of the action NAME."
  (or (plist-get (cmacs-gowl-ai-field--action name) :label)
      (symbol-name name)))

(defun cmacs-gowl-ai-field--line (string)
  "Return STRING fit to be one row of the menu card.
The card's protocol is tab separated lines."
  (replace-regexp-in-string "[\t\n\r]+" " " string))

(defun cmacs-gowl-ai-field--subject (text cursor anchor)
  "Return what an action acts on in TEXT, as (START . END).
CURSOR and ANCHOR are character indexes, or nil when not known: the
selection when they differ, otherwise all of TEXT."
  (if (and (integerp cursor) (integerp anchor) (/= cursor anchor))
      (cons (max 0 (min cursor anchor))
            (min (length text) (max cursor anchor)))
    (cons 0 (length text))))

(defun cmacs-gowl-ai-field--splice (text start end replacement)
  "Return TEXT with its START..END part replaced by REPLACEMENT."
  (concat (substring text 0 start) replacement (substring text end)))

(defun cmacs-gowl-ai-field--provider+model ()
  "Return (PROVIDER . MODEL) for a field action.
See `cmacs-gowl-ai-field-provider'."
  (if cmacs-gowl-ai-field-provider
      (cons cmacs-gowl-ai-field-provider cmacs-gowl-ai-field-model)
    (cons (bound-and-true-p cmacs-ai-textops-provider)
          (or cmacs-gowl-ai-field-model
              (bound-and-true-p cmacs-ai-textops-model)))))

(defun cmacs-gowl-ai-field--request (name subject how)
  "Return (SYSTEM . PROMPT) for the action NAME over the string SUBJECT.
HOW, a string or nil, is the instruction when the action asks for one.
The prompts are cmacs-ai-textops.el's, so that a field is rewritten the
way a region is."
  (require 'cmacs-ai-textops)
  (let* ((action (or (cmacs-gowl-ai-field--action name)
                     (error "No field action named %s" name)))
         (spec (cmacs-ai-textops--spec (or (plist-get action :op) 'rephrase)))
         (how (or how
                  (let ((h (plist-get action :how)))
                    (cond ((stringp h) h)
                          ((functionp h) (funcall h))))
                  (plist-get spec :default)))
         (target (cmacs-ai-target-create
                  :kind 'text-field :label "text" :text subject)))
    (cons (or (plist-get action :system)
              ;; Through the symbol, so a customisation made since
              ;; this file was loaded is the one in force.
              (symbol-value (plist-get spec :system)))
          (cmacs-ai-textops--prompt spec target how))))

(defun cmacs-gowl-ai-field--too-long-p (subject)
  "Return non-nil if SUBJECT is longer than may be sent to a model."
  (let ((n (length subject)))
    (or (> n cmacs-gowl-ai-field-max-chars)
        (and (boundp 'cmacs-ai-target-max-chars)
             (integerp cmacs-ai-target-max-chars)
             (> n cmacs-ai-target-max-chars)))))

;;;; Telling the user

(defun cmacs-gowl-ai-field--say (summary &optional body)
  "Report SUMMARY, with the detail BODY, on the bar and in the echo area.
Never signals: nearly everything here runs from a compositor key or
from a callback, where an error has nobody to reach."
  (when (and cmacs-gowl-ai-field-toast (fboundp 'gowl-bar-notify))
    (ignore-errors (gowl-bar-notify (concat "AI: " summary) body)))
  (message "ai-field: %s%s" summary (if body (concat " -- " body) ""))
  nil)

;;;; Privacy

;; Special in cmacs-redact.el; declared here so the binding below is
;; dynamic when this file is compiled without that one loaded.
(defvar cmacs-redact--as-model)

(defun cmacs-gowl-ai-field--withheld-p (target)
  "Return non-nil if the redaction rules keep TARGET's window from a model.
TARGET is a plist from `cmacs-gowl-edit-field-focused-target'.  The
rule set is the journal's, asked through `cmacs-redact-window', which
fails closed by itself; this fails closed as well when it cannot be
asked at all."
  (condition-case nil
      (progn
        (require 'cmacs-redact)
        ;; As a model: this runs from the user's own key, where the
        ;; redaction functions are deliberately no-ops, and without the
        ;; binding the question "may a model see this window" was
        ;; answered "yes" for every window -- an excluded one had its
        ;; field read and sent.  Found by the rig
        ;; (ai-field-excluded-window-is-withheld).  Bound by variable,
        ;; not through the `cmacs-redact-as-model' macro, because this
        ;; file loads cmacs-redact only when it is first needed.
        (let ((cmacs-redact--as-model t))
          (null (cmacs-redact-window (plist-get target :app-id)
                                     (plist-get target :title)
                                     (plist-get target :pid)))))
    (error t)))

;;;; The job
;;
;; One at a time: there is one keyboard, and an answer has one place to
;; go.  A job is everything between the key and the last toast.

(cl-defstruct (cmacs-gowl-ai-field--job
               (:constructor cmacs-gowl-ai-field--job-create)
               (:copier nil))
  "One AI action on one text field."
  target          ; the window, from `cmacs-gowl-edit-field-focused-target'
  field           ; the edit-field headless session, or nil once let go
  action          ; the action's name, once chosen
  how             ; the instruction typed for it, or nil
  text            ; the text as read
  start end       ; the part acted on, character indexes into `text'
  selection       ; non-nil when that part is the application's selection
  partial         ; non-nil when `text' is a window of a longer field
  pair            ; the cmacs-ai (CLIENT . SESSION), while the model runs
  chunks          ; the answer so far, newest first
  received        ; how many characters of it
  answer          ; the answer, once complete
  new             ; `text' with the answer spliced in
  state           ; `reading' `choosing' `running' `writing' or `done'
  lost            ; why the field can no longer be written, or nil
  timers)         ; timers to cancel when the job ends

(defvar cmacs-gowl-ai-field--job nil
  "The action in progress, a job struct, or nil.")

(defvar cmacs-gowl-ai-field--last nil
  "The last edit made, for `cmacs-gowl-ai-field-undo', or nil.
A plist: :id (the window), :before and :after (the text read, and that
text with the answer in it), :label.")

(defun cmacs-gowl-ai-field--live-p (job)
  "Return non-nil if JOB is the action in progress."
  (and job (eq job cmacs-gowl-ai-field--job)
       (not (eq (cmacs-gowl-ai-field--job-state job) 'done))))

(defun cmacs-gowl-ai-field--timer (job secs repeat function &rest args)
  "Run FUNCTION with ARGS after SECS (and every REPEAT) for JOB."
  (let ((timer (apply #'run-at-time secs repeat function args)))
    (when (timerp timer)
      (push timer (cmacs-gowl-ai-field--job-timers job)))
    timer))

(defun cmacs-gowl-ai-field--stop-model (job &optional finished)
  "Free JOB's model session, cancelling its request unless FINISHED."
  (when-let* ((pair (cmacs-gowl-ai-field--job-pair job)))
    (setf (cmacs-gowl-ai-field--job-pair job) nil)
    (unless finished
      (ignore-errors (cmacs-ai-chat-cancel (cdr pair))))
    ;; Freed on a later turn of the loop, never from inside the stream
    ;; callback that may be what is running now.
    (run-at-time 0 nil (lambda ()
                         (ignore-errors (cmacs-ai-free-session pair))))))

(defun cmacs-gowl-ai-field--end (job)
  "JOB is over: let go of everything it holds."
  (setf (cmacs-gowl-ai-field--job-state job) 'done)
  (dolist (timer (cmacs-gowl-ai-field--job-timers job))
    (when (timerp timer) (cancel-timer timer)))
  (setf (cmacs-gowl-ai-field--job-timers job) nil)
  (cmacs-gowl-ai-field--stop-model job)
  (when-let* ((field (cmacs-gowl-ai-field--job-field job)))
    (setf (cmacs-gowl-ai-field--job-field job) nil)
    (cmacs-gowl-edit-field-release field))
  (when (eq job cmacs-gowl-ai-field--job)
    (setq cmacs-gowl-ai-field--job nil)))

(defun cmacs-gowl-ai-field--fail (job summary &optional body)
  "End JOB, reporting SUMMARY and BODY."
  (when (cmacs-gowl-ai-field--live-p job)
    (cmacs-gowl-ai-field--end job)
    (cmacs-gowl-ai-field--say summary body)))

(defun cmacs-gowl-ai-field--keep (job why)
  "End JOB with its answer on the kill ring, because of WHY.
For an answer that arrived and cannot go into the field: it is not
thrown away, and it is not typed anywhere else."
  (when (cmacs-gowl-ai-field--live-p job)
    (let ((answer (cmacs-gowl-ai-field--job-answer job)))
      (cmacs-gowl-ai-field--end job)
      (kill-new answer)
      (cmacs-gowl-ai-field--say
       "the answer is on the kill ring"
       (format "%s; nothing was typed" why)))))

;;;; Choosing: the menu card
;;
;; The card is the compositor's, so it appears over the application
;; with no Emacs frame involved.  `menu-choose' answers with a token at
;; once and the pick is read back with `menu-choice'; there is no event
;; to wait on from Lisp, so a short timer asks until there is an answer.

(defconst cmacs-gowl-ai-field--card-poll 0.1
  "Seconds between looks at the menu card's answer.")

(defconst cmacs-gowl-ai-field--card-patience 300
  "Seconds after which an unanswered card is taken as cancelled.")

(defun cmacs-gowl-ai-field--card-open (prompt lines)
  "Open the menu card titled PROMPT on LINES; return its token, or nil.
nil when there is no card to open: no menu module, a locked session."
  (when (fboundp 'gowl-run-command)
    (let ((reply (ignore-errors
                   (gowl-run-command
                    (concat "menu-choose "
                            (mapconcat #'cmacs-gowl-ai-field--line
                                       (cons prompt lines) "\t"))))))
      (and (stringp reply)
           (string-match "\\`OK \\([^ \t\n]+\\)" reply)
           (match-string 1 reply)))))

(defun cmacs-gowl-ai-field--card-poll (token count tries callback)
  "Ask the card for the answer to TOKEN; call CALLBACK when it has one.
CALLBACK gets the index of the row picked, of COUNT rows, or nil for a
cancelled card.  TRIES is how many more times to ask."
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
      (run-at-time cmacs-gowl-ai-field--card-poll nil
                   #'cmacs-gowl-ai-field--card-poll
                   token count (1- tries) callback))
     ;; Cancelled, superseded by another choice, the module gone, or
     ;; nobody answered: all of them are "no".
     (t (funcall callback nil)))))

;;;; Choosing and asking: the minibuffer frame
;;
;; A frame that is only a minibuffer, floated by a compositor rule the
;; way the edit-field editor is, so nothing tiled moves.  Reading in it
;; occupies Emacs's thread -- as the gowl menu's `completing-read' does
;; -- and not the compositor's.

(defun cmacs-gowl-ai-field--prompt-client ()
  "Return the gowl window of the minibuffer frame, or nil if not mapped."
  (let ((pid (emacs-pid)))
    (cl-find-if
     (lambda (c)
       (let ((info (ignore-errors (gowl-client-info c))))
         (and info
              (equal (alist-get 'title info)
                     cmacs-gowl-ai-field-prompt-frame-name)
              (eql pid (ignore-errors (gowl-client-pid c))))))
     (ignore-errors (gowl-list-clients)))))

(defun cmacs-gowl-ai-field--focus-prompt (frame tries)
  "Give the minibuffer FRAME the keyboard once the compositor has mapped it.
Looks TRIES more times; the window appears a moment after `make-frame'."
  (when (frame-live-p frame)
    (let ((client (cmacs-gowl-ai-field--prompt-client)))
      (cond
       (client (ignore-errors (gowl-focus-client client)))
       ((> tries 0)
        (run-at-time 0.05 nil #'cmacs-gowl-ai-field--focus-prompt
                     frame (1- tries)))))))

(defun cmacs-gowl-ai-field--in-prompt-frame (function)
  "Call FUNCTION with a floating minibuffer frame selected; return its value.
The frame is deleted afterwards, however FUNCTION ends.  A quit is nil."
  (let ((frame nil))
    (unwind-protect
        (condition-case nil
            (progn
              (when (fboundp 'gowl-add-rule-entry)
                (ignore-errors
                  (when (fboundp 'gowl-remove-rule)
                    (gowl-remove-rule
                     nil cmacs-gowl-ai-field-prompt-frame-name))
                  (gowl-add-rule-entry
                   `((title . ,cmacs-gowl-ai-field-prompt-frame-name)
                     (floating . t)
                     (center . t)))))
              (setq frame
                    (make-frame
                     `((name . ,cmacs-gowl-ai-field-prompt-frame-name)
                       (minibuffer . only)
                       (width . ,cmacs-gowl-ai-field-prompt-frame-width)
                       (height . 1)
                       (tab-bar-lines . 0)
                       (tool-bar-lines . 0)
                       (menu-bar-lines . 0)
                       (cmacs-ai-field-prompt . t))))
              (select-frame-set-input-focus frame)
              ;; Timers run while the minibuffer waits, so this finds
              ;; the window under the read.
              (run-at-time 0.05 nil #'cmacs-gowl-ai-field--focus-prompt
                           frame 40)
              (with-selected-frame frame
                (funcall function)))
          (quit nil))
      (when (and (frame-live-p frame) (cdr (frame-list)))
        (ignore-errors (delete-frame frame))))))

(defvar cmacs-gowl-ai-field-instruction-history nil
  "History of the free-form instructions given to field actions.")

(defun cmacs-gowl-ai-field--read-instruction (label)
  "Read a free-form instruction for the action labelled LABEL.
Return it, or nil if none was given."
  (let ((answer (cmacs-gowl-ai-field--in-prompt-frame
                 (lambda ()
                   (read-string
                    (format "%s -- how? "
                            (string-trim-right label "[. ]+"))
                    nil 'cmacs-gowl-ai-field-instruction-history)))))
    (and (stringp answer)
         (not (string-empty-p (string-trim answer)))
         (string-trim answer))))

(defun cmacs-gowl-ai-field--read-choice (prompt lines)
  "Read one of LINES in the minibuffer frame, under PROMPT.
Return its index, or nil."
  (let ((answer (cmacs-gowl-ai-field--in-prompt-frame
                 (lambda ()
                   (completing-read (concat prompt ": ") lines nil t)))))
    (and (stringp answer)
         (cl-position answer lines :test #'string=))))

(defun cmacs-gowl-ai-field--choose (prompt lines callback)
  "Have the user pick one of LINES under PROMPT; call CALLBACK with the index.
CALLBACK gets nil when nothing was picked.  It is always called from a
timer or a later callback, never before this returns."
  (let ((token (and (eq cmacs-gowl-ai-field-chooser 'card)
                    (cmacs-gowl-ai-field--card-open prompt lines))))
    (if token
        (run-at-time cmacs-gowl-ai-field--card-poll nil
                     #'cmacs-gowl-ai-field--card-poll
                     token (length lines)
                     (ceiling (/ cmacs-gowl-ai-field--card-patience
                                 cmacs-gowl-ai-field--card-poll))
                     callback)
      (run-at-time 0 nil
                   (lambda ()
                     (funcall callback
                              (cmacs-gowl-ai-field--read-choice
                               prompt lines)))))))

;;;; Running the model

(defun cmacs-gowl-ai-field--on-stream (job payload)
  "Take PAYLOAD, one event of the model's answer, for JOB."
  (when (and (cmacs-gowl-ai-field--live-p job)
             (eq (cmacs-gowl-ai-field--job-state job) 'running))
    (pcase (car-safe payload)
      (:delta
       (when-let* ((chunk (cadr payload)))
         (push chunk (cmacs-gowl-ai-field--job-chunks job))
         (cl-incf (cmacs-gowl-ai-field--job-received job) (length chunk))))
      (:end
       ;; A provider that does not stream delivers everything here.
       (let ((streamed (apply #'concat
                              (reverse (cmacs-gowl-ai-field--job-chunks job))))
             (final (plist-get (cdr payload) :text)))
         (cmacs-gowl-ai-field--answered
          job (if (string-empty-p streamed) (or final "") streamed))))
      (:error
       (cmacs-gowl-ai-field--stop-model job t)
       (cmacs-gowl-ai-field--fail
        job "the model failed" (or (cadr payload) "stream error"))))))

(defun cmacs-gowl-ai-field--progress (job)
  "Say how far JOB's answer has come."
  (when (and (cmacs-gowl-ai-field--live-p job)
             (eq (cmacs-gowl-ai-field--job-state job) 'running))
    (cmacs-gowl-ai-field--say
     (format "%s..." (cmacs-gowl-ai-field--label
                      (cmacs-gowl-ai-field--job-action job)))
     (format "%d characters so far" (cmacs-gowl-ai-field--job-received job)))))

(defun cmacs-gowl-ai-field--timed-out (job)
  "JOB's model did not answer in time."
  (cmacs-gowl-ai-field--fail
   job "the model took too long"
   (format "gave up after %s seconds; the field is as it was"
           cmacs-gowl-ai-field-timeout)))

(defun cmacs-gowl-ai-field--run (job)
  "Send JOB's text to the model.  The action is chosen and the text read."
  (when (cmacs-gowl-ai-field--live-p job)
    (condition-case err
        (let* ((text (cmacs-gowl-ai-field--job-text job))
               (subject (substring text
                                   (cmacs-gowl-ai-field--job-start job)
                                   (cmacs-gowl-ai-field--job-end job)))
               (request (cmacs-gowl-ai-field--request
                         (cmacs-gowl-ai-field--job-action job)
                         subject
                         (cmacs-gowl-ai-field--job-how job)))
               (who (cmacs-gowl-ai-field--provider+model)))
          (require 'cmacs-ai)
          (cmacs-ai--ensure)
          (setf (cmacs-gowl-ai-field--job-pair job)
                (cmacs-ai-make-session (car who) (cdr who) (car request))
                (cmacs-gowl-ai-field--job-chunks job) nil
                (cmacs-gowl-ai-field--job-received job) 0
                (cmacs-gowl-ai-field--job-state job) 'running)
          (when cmacs-gowl-ai-field-timeout
            (cmacs-gowl-ai-field--timer
             job cmacs-gowl-ai-field-timeout nil
             #'cmacs-gowl-ai-field--timed-out job))
          (when cmacs-gowl-ai-field-progress-interval
            (cmacs-gowl-ai-field--timer
             job cmacs-gowl-ai-field-progress-interval
             cmacs-gowl-ai-field-progress-interval
             #'cmacs-gowl-ai-field--progress job))
          (cmacs-gowl-ai-field--say
           (format "%s..." (cmacs-gowl-ai-field--label
                            (cmacs-gowl-ai-field--job-action job)))
           (format "%s%s%s"
                   (cond ((cmacs-gowl-ai-field--job-selection job)
                          "the selection")
                         ((cmacs-gowl-ai-field--job-partial job)
                          "the text around the cursor (the field is \
longer than could be read)")
                         (t "the whole field"))
                   (format ", %d characters" (length subject))
                   (if cmacs-gowl-ai-field-key
                       (format "; %s cancels" cmacs-gowl-ai-field-key)
                     "")))
          (cmacs-ai-chat-stream
           (cdr (cmacs-gowl-ai-field--job-pair job))
           (cdr request)
           (lambda (payload)
             (cmacs-gowl-ai-field--on-stream job payload))))
      (error
       (cmacs-gowl-ai-field--fail job "the model could not be asked"
                                  (error-message-string err))))))

;;;; Writing the answer back

(defun cmacs-gowl-ai-field--focused-p (job)
  "Return non-nil if JOB's window holds the keyboard now."
  (let ((id (plist-get (cmacs-gowl-ai-field--job-target job) :id))
        (now (ignore-errors (gowl-focused-client))))
    (and id now
         (eql id (alist-get 'id (ignore-errors (gowl-client-info now)))))))

(defun cmacs-gowl-ai-field--answered (job raw)
  "JOB's model answered RAW: put it in the field, or keep it."
  (require 'cmacs-ai-proofread)
  (let* ((text (cmacs-gowl-ai-field--job-text job))
         (start (cmacs-gowl-ai-field--job-start job))
         (end (cmacs-gowl-ai-field--job-end job))
         (answer (cmacs-ai-proofread--strip-wrapping
                  raw (substring text start end))))
    ;; The request is over; its session goes before anything else can
    ;; go wrong.
    (cmacs-gowl-ai-field--stop-model job t)
    (setf (cmacs-gowl-ai-field--job-answer job) answer
          (cmacs-gowl-ai-field--job-new job)
          (cmacs-gowl-ai-field--splice text start end answer))
    (cond
     ((string-empty-p (string-trim answer))
      (cmacs-gowl-ai-field--fail job "the model answered nothing"
                                 "the field is as it was"))
     ((cmacs-gowl-ai-field--job-lost job)
      (cmacs-gowl-ai-field--keep job (cmacs-gowl-ai-field--job-lost job)))
     ;; The one check that matters most: this never types into a window
     ;; other than the one that was asked about, and never moves the
     ;; keyboard to make the write possible.
     ((not (cmacs-gowl-ai-field--focused-p job))
      (cmacs-gowl-ai-field--keep job "the keyboard moved to another window"))
     (t
      (setf (cmacs-gowl-ai-field--job-state job) 'writing)
      (cmacs-gowl-edit-field-write-async
       (cmacs-gowl-ai-field--job-field job)
       (cmacs-gowl-ai-field--job-new job))))))

(defun cmacs-gowl-ai-field--wrote (job changed)
  "JOB's answer is in its field; CHANGED is nil if it was what was there."
  (when (cmacs-gowl-ai-field--live-p job)
    (let ((label (cmacs-gowl-ai-field--label
                  (cmacs-gowl-ai-field--job-action job))))
      (when changed
        (setq cmacs-gowl-ai-field--last
              (list :id (plist-get (cmacs-gowl-ai-field--job-target job) :id)
                    :before (cmacs-gowl-ai-field--job-text job)
                    :after (cmacs-gowl-ai-field--job-new job)
                    :label label)))
      (setf (cmacs-gowl-ai-field--job-field job) nil)
      (cmacs-gowl-ai-field--end job)
      (if changed
          (cmacs-gowl-ai-field--say
           (format "%s: done" label)
           "`cmacs-gowl-ai-field-undo' puts the old text back")
        (cmacs-gowl-ai-field--say
         (format "%s: nothing to change" label))))))

;;;; The field's side of a job

(defun cmacs-gowl-ai-field--on-field (job event field &rest args)
  "Take EVENT with ARGS from FIELD, the edit-field session of JOB.
See \"Headless sessions\" in cmacs-gowl-edit-field.el for the events."
  (when (cmacs-gowl-ai-field--live-p job)
    (pcase event
      ('read
       (setf (cmacs-gowl-ai-field--job-field job) field)
       (apply #'cmacs-gowl-ai-field--on-read job args))
      ('committed (cmacs-gowl-ai-field--wrote job t))
      ('unchanged (cmacs-gowl-ai-field--wrote job nil))
      ('failed
       ;; The session is closed already.
       (setf (cmacs-gowl-ai-field--job-field job) nil)
       (pcase (cmacs-gowl-ai-field--job-state job)
         ;; The answer exists and could not be written: keep it.
         ('writing (cmacs-gowl-ai-field--keep job (car args)))
         ;; The window went while the model was working.  The answer is
         ;; still wanted; it will have nowhere to go but the kill ring.
         ('running (setf (cmacs-gowl-ai-field--job-lost job) (car args)))
         (_ (cmacs-gowl-ai-field--fail job (car args))))))))

(defun cmacs-gowl-ai-field--on-read (job text cursor anchor)
  "JOB's field holds TEXT, with CURSOR and ANCHOR as character indexes."
  (let* ((info (cmacs-gowl-edit-field-session-info
                (cmacs-gowl-ai-field--job-field job)))
         ;; Through the clipboard the cursor is not known, and the
         ;; indexes handed over are only "the end of the text".
         (known (eq (plist-get info :method) 'text-input))
         (subject (cmacs-gowl-ai-field--subject
                   text (and known cursor) (and known anchor))))
    (setf (cmacs-gowl-ai-field--job-text job) text
          (cmacs-gowl-ai-field--job-start job) (car subject)
          (cmacs-gowl-ai-field--job-end job) (cdr subject)
          (cmacs-gowl-ai-field--job-selection job)
          (and known (/= cursor anchor))
          (cmacs-gowl-ai-field--job-partial job)
          (not (plist-get info :complete)))
    (let ((part (substring text (car subject) (cdr subject))))
      (cond
       ((string-empty-p (string-trim part))
        (cmacs-gowl-ai-field--fail job "there is no text in that field"))
       ((cmacs-gowl-ai-field--too-long-p part)
        (cmacs-gowl-ai-field--fail
         job "that text is too long"
         (format "%d characters; see `cmacs-gowl-ai-field-max-chars'"
                 (length part))))
       ((cmacs-gowl-ai-field--job-action job)
        (cmacs-gowl-ai-field--chosen job (cmacs-gowl-ai-field--job-action job)))
       (t
        (cmacs-gowl-ai-field--offer job))))))

(defun cmacs-gowl-ai-field--offer (job)
  "Show the actions for JOB's text, and go on with the one picked."
  (setf (cmacs-gowl-ai-field--job-state job) 'choosing)
  (let* ((names (mapcar #'car cmacs-gowl-ai-field-actions))
         (undo (and cmacs-gowl-ai-field--last
                    (eql (plist-get cmacs-gowl-ai-field--last :id)
                         (plist-get (cmacs-gowl-ai-field--job-target job)
                                    :id))))
         (rows (append (mapcar #'cmacs-gowl-ai-field--label names)
                       (and undo
                            (list (format "Undo: %s"
                                          (plist-get cmacs-gowl-ai-field--last
                                                     :label)))))))
    (cmacs-gowl-ai-field--choose
     (format "AI on %s"
             (cond ((cmacs-gowl-ai-field--job-selection job) "the selection")
                   ((cmacs-gowl-ai-field--job-partial job)
                    "the text around the cursor")
                   (t "this field")))
     rows
     (lambda (index)
       (when (cmacs-gowl-ai-field--live-p job)
         (cond
          ((null index)
           (cmacs-gowl-ai-field--end job))
          ((< index (length names))
           (cmacs-gowl-ai-field--chosen job (nth index names)))
          (t
           ;; The undo row.  This job's read is let go first: the undo
           ;; reads the field for itself.
           (cmacs-gowl-ai-field--end job)
           (cmacs-gowl-ai-field-undo))))))))

(defun cmacs-gowl-ai-field--chosen (job name)
  "Go on with JOB now that the action NAME is settled."
  (let ((action (cmacs-gowl-ai-field--action name)))
    (setf (cmacs-gowl-ai-field--job-action job) name)
    (cond
     ((null action)
      (cmacs-gowl-ai-field--fail
       job (format "there is no field action named %s" name)))
     ((and (plist-get action :ask)
           (null (cmacs-gowl-ai-field--job-how job)))
      (let ((how (cmacs-gowl-ai-field--read-instruction
                  (cmacs-gowl-ai-field--label name))))
        ;; The read took the keyboard into an Emacs frame; hand it back
        ;; to the window it came from.  That is not "moving focus to
        ;; write": the write, much later, still checks where it is.
        (ignore-errors
          (gowl-focus-client
           (plist-get (cmacs-gowl-ai-field--job-target job) :client)))
        (if (null how)
            (cmacs-gowl-ai-field--end job)
          (setf (cmacs-gowl-ai-field--job-how job) how)
          (cmacs-gowl-ai-field--run job))))
     (t
      (cmacs-gowl-ai-field--run job)))))

;;;; Commands

(defun cmacs-gowl-ai-field--start (action how)
  "Begin a job on the focused field: ACTION, or the chooser when nil.
HOW is the instruction for an action that asks for one."
  (let ((target (cmacs-gowl-edit-field-focused-target)))
    (cond
     ((cmacs-gowl-ai-field--live-p cmacs-gowl-ai-field--job)
      (cmacs-gowl-ai-field--busy))
     ((plist-get target :refused)
      (cmacs-gowl-ai-field--say (plist-get target :refused)))
     ((cmacs-gowl-ai-field--withheld-p target)
      (cmacs-gowl-ai-field--say
       "that window is withheld from models"
       "the redaction rules exclude it, or could not be loaded"))
     (t
      (let ((job (cmacs-gowl-ai-field--job-create
                  :target target :action action :how how
                  :state 'reading :received 0)))
        (setq cmacs-gowl-ai-field--job job)
        (cmacs-gowl-edit-field-read-async
         (lambda (event field &rest args)
           (apply #'cmacs-gowl-ai-field--on-field job event field args))
         target
         (not cmacs-gowl-ai-field-clipboard-fallback)))))
    nil))

(defun cmacs-gowl-ai-field--busy ()
  "An action is in progress and another was asked for: offer to cancel it."
  (let* ((job cmacs-gowl-ai-field--job)
         (label (if (cmacs-gowl-ai-field--job-action job)
                    (cmacs-gowl-ai-field--label
                     (cmacs-gowl-ai-field--job-action job))
                  "the action")))
    (if (eq (cmacs-gowl-ai-field--job-state job) 'choosing)
        ;; Its own menu is what is on the screen.
        (cmacs-gowl-ai-field--say "an action is being chosen already")
      (cmacs-gowl-ai-field--choose
       (format "AI: %s is running" label)
       (list (format "Cancel: %s" label) "Let it finish")
       (lambda (index)
         (when (and (eql index 0) (cmacs-gowl-ai-field--live-p job))
           (cmacs-gowl-ai-field-cancel)))))))

;;;###autoload
(defun cmacs-gowl-ai-field ()
  "Choose an AI action for the text field that has the keyboard.
The field may be in any window on the gowl desktop.  The actions
\(`cmacs-gowl-ai-field-actions') are listed on the compositor's menu
card; the one picked is run on the field's selection, or on its whole
text when nothing is selected, and the model's answer replaces that
text in the field.  No Emacs frame is involved, except to type a
free-form instruction.

Run again while an action is in progress, it offers to cancel it.
`cmacs-gowl-ai-field-undo' puts the old text back.

Meant for a compositor key (`cmacs-gowl-ai-field-key', bound by
`cmacs-gowl-ai-field-setup').  Returns at once."
  (interactive)
  (cmacs-gowl-ai-field--start nil nil))

;;;###autoload
(defun cmacs-gowl-ai-field-run (action &optional instruction)
  "Run ACTION, a name in `cmacs-gowl-ai-field-actions', on the focused field.
INSTRUCTION, a string, says how, for an action that would otherwise ask
\(or in place of any action's own instruction).  Returns at once; the
answer replaces the text when it arrives."
  (interactive
   (list (intern (completing-read
                  "Field action: "
                  (mapcar (lambda (a) (symbol-name (car a)))
                          cmacs-gowl-ai-field-actions)
                  nil t))))
  (cmacs-gowl-ai-field--start action instruction))

;;;###autoload
(defun cmacs-gowl-ai-field-proofread ()
  "Fix the spelling and grammar of the focused text field, in place."
  (interactive)
  (cmacs-gowl-ai-field-run 'proofread))

;;;###autoload
(defun cmacs-gowl-ai-field-rewrite ()
  "Rewrite the focused text field to be clearer and tighter, in place."
  (interactive)
  (cmacs-gowl-ai-field-run 'rewrite))

;;;###autoload
(defun cmacs-gowl-ai-field-shorten ()
  "Shorten the text of the focused text field, in place."
  (interactive)
  (cmacs-gowl-ai-field-run 'shorten))

;;;###autoload
(defun cmacs-gowl-ai-field-translate ()
  "Translate the focused text field, in place.
Into `cmacs-gowl-ai-field-translate-language'."
  (interactive)
  (cmacs-gowl-ai-field-run 'translate))

;;;###autoload
(defun cmacs-gowl-ai-field-custom (&optional instruction)
  "Rewrite the focused text field as INSTRUCTION says, in place.
With no INSTRUCTION, it is asked for once the field has been read."
  (interactive)
  (cmacs-gowl-ai-field-run 'custom instruction))

;;;###autoload
(defun cmacs-gowl-ai-field-cancel ()
  "Cancel the field action in progress.  The field is left as it is."
  (interactive)
  (let ((job cmacs-gowl-ai-field--job))
    (if (not (cmacs-gowl-ai-field--live-p job))
        (cmacs-gowl-ai-field--say "nothing is running")
      (cmacs-gowl-ai-field--end job)
      (cmacs-gowl-ai-field--say "cancelled" "the field is as it was")))
  nil)

;;;###autoload
(defun cmacs-gowl-ai-field-undo ()
  "Put back the text the last field action replaced.
Only while the window it was in holds the keyboard and its field still
holds the answer: if the field has been edited since, nothing is
overwritten, and the old text goes to the kill ring instead."
  (interactive)
  (let* ((last cmacs-gowl-ai-field--last)
         (target (cmacs-gowl-edit-field-focused-target)))
    (cond
     ((null last)
      (cmacs-gowl-ai-field--say "there is nothing to undo"))
     ((cmacs-gowl-ai-field--live-p cmacs-gowl-ai-field--job)
      (cmacs-gowl-ai-field--say "an action is still running"))
     ((plist-get target :refused)
      (cmacs-gowl-ai-field--say (plist-get target :refused)))
     ((not (eql (plist-get target :id) (plist-get last :id)))
      (cmacs-gowl-ai-field--say
       "the last AI edit was in another window"
       "put the keyboard back in its field first"))
     (t
      (cmacs-gowl-edit-field-read-async
       (lambda (event field &rest args)
         (cmacs-gowl-ai-field--on-undo last event field args))
       target
       (not cmacs-gowl-ai-field-clipboard-fallback))))
    nil))

(defun cmacs-gowl-ai-field--on-undo (last event field args)
  "Take EVENT with ARGS from FIELD, the session undoing the edit LAST."
  (pcase event
    ('read
     (if (string= (car args) (plist-get last :after))
         (cmacs-gowl-edit-field-write-async field (plist-get last :before))
       (cmacs-gowl-edit-field-release field)
       (kill-new (plist-get last :before))
       (cmacs-gowl-ai-field--say
        "the field has changed since"
        "nothing was overwritten; the old text is on the kill ring")))
    ((or 'committed 'unchanged)
     (when (eq last cmacs-gowl-ai-field--last)
       (setq cmacs-gowl-ai-field--last nil))
     (cmacs-gowl-ai-field--say "the old text is back"))
    ('failed
     (cmacs-gowl-ai-field--say "could not undo" (car args)))))

;;;; Keys

(defvar cmacs-gowl-ai-field--bound-keys nil
  "The gowl keys `cmacs-gowl-ai-field-setup' bound last time.")

;;;###autoload
(defun cmacs-gowl-ai-field-setup ()
  "Bind the field action keys in gowl.
`cmacs-gowl-ai-field-key' to the chooser, and, where they are set,
`cmacs-gowl-ai-field-undo-key', `cmacs-gowl-ai-field-cancel-key' and
each of `cmacs-gowl-ai-field-action-keys'.  Does nothing when the
compositor is not running.  Safe to call again: the keys it bound
before are unbound first, so a key taken out of an option stops
working.  Put it on `cmacs-gowl-mode-hook' to have the keys whenever
the desktop is up."
  (interactive)
  (when (and (fboundp 'gowl-running-p) (gowl-running-p)
             (fboundp 'gowl-add-keybind))
    (dolist (key cmacs-gowl-ai-field--bound-keys)
      (ignore-errors (gowl-remove-keybind key)))
    (setq cmacs-gowl-ai-field--bound-keys nil)
    (let ((binds
           `(,@(and cmacs-gowl-ai-field-key
                    `((,cmacs-gowl-ai-field-key
                       "(cmacs-gowl-ai-field)"
                       "AI on this text field")))
             ,@(and cmacs-gowl-ai-field-undo-key
                    `((,cmacs-gowl-ai-field-undo-key
                       "(cmacs-gowl-ai-field-undo)"
                       "Undo the last AI edit of a text field")))
             ,@(and cmacs-gowl-ai-field-cancel-key
                    `((,cmacs-gowl-ai-field-cancel-key
                       "(cmacs-gowl-ai-field-cancel)"
                       "Cancel the AI action on a text field")))
             ,@(cl-loop
                for (key . action) in cmacs-gowl-ai-field-action-keys
                ;; Only names of actions become Lisp here, and a name
                ;; is printed, never spliced as text.
                when (and (stringp key) (symbolp action)
                          (cmacs-gowl-ai-field--action action))
                collect (list key
                              (prin1-to-string
                               `(cmacs-gowl-ai-field-run ',action))
                              (format "AI: %s"
                                      (cmacs-gowl-ai-field--label action)))))))
      (dolist (bind binds)
        (condition-case err
            (progn
              ;; gowl runs the first bind that matches, so one left by
              ;; something else would shadow this one.
              (ignore-errors (gowl-remove-keybind (nth 0 bind)))
              (gowl-add-keybind (nth 0 bind) 'custom (nth 1 bind) (nth 2 bind))
              (push (nth 0 bind) cmacs-gowl-ai-field--bound-keys))
          (error (message "cmacs-gowl-ai-field: cannot bind %s: %s"
                          (nth 0 bind) (error-message-string err)))))
      (and cmacs-gowl-ai-field--bound-keys t))))

(provide 'cmacs-gowl-ai-field)

;;; cmacs-gowl-ai-field.el ends here
