;;; cmacs-deixis-ask.el --- "Explain THAT": questions about what you point at  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Deictic questions.  `cmacs-deixis' binds a spoken "this" or "that" to
;; what the pointer rested on while the word was said, and runs deictic
;; COMMANDS with it ("move that there").  This file adds QUESTIONS:
;; point at something and ask -- "what is that?", "explain this",
;; "summarise that", "what does this error mean", "translate that",
;; "why is this failing", "compare this and that" -- and what was
;; pointed at becomes the model's context.
;;
;; Three stages, each small:
;;
;;   referent -> content   EXTRACTORS, most specific first, in a public
;;                         registry (`cmacs-deixis-ask-register-extractor'):
;;                           gsurf    a web view: URL, title, and the
;;                                    selection or the text nearest the
;;                                    pointed place
;;                           field    another program's window that has
;;                                    the keyboard: the text SELECTED in
;;                                    its focused field (text-input)
;;                           buffer   an Emacs buffer position: the
;;                                    region, or the compilation error /
;;                                    org subtree / function / paragraph /
;;                                    line there, with the diagnostics on
;;                                    it, its file and its major mode
;;                           ocr      any other window: tesseract over a
;;                                    box around the pointed place, or
;;                                    over the whole window ("what is
;;                                    this window")
;;   privacy               before anything leaves; see PRIVACY below
;;   asking                `cmacs-ai-textops-stream': the answer streams
;;                         into the `cmacs-ai-output' window, which
;;                         keeps its session, so `C-c C-c' follows up
;;                         and `C-c C-p' promotes it to a chat
;;
;; TWO DOORS.  By voice, through `cmacs-deixis-mode': this file's
;; `cmacs-deixis-ask-utterance' is on `cmacs-deixis-unclaimed-functions',
;; which is asked only AFTER the deictic commands, so a question cannot
;; take an utterance a command matches.  The answer is then also spoken,
;; sentence by sentence, the way the loop speaks a chat reply, and
;; talking over it stops it (barge-in).  "And that one?" continues the
;; same conversation with a new referent.  By hand, with no voice at
;; all: `cmacs-deixis-ask-at-pointer' asks about what the pointer is on
;; now, and the AI right-click menu has "Ask about this...".
;;
;; PRIVACY.  Decided before any text is read, and again on what was
;; read:
;;
;;   * The referent is put to `cmacs-redact-window' / `-buffer-p' /
;;     `-url'.  An excluded window, buffer or page is refused, in the
;;     echo area, on the bar, and aloud when the question was spoken.
;;     Nothing is read from it.  If the rules cannot be asked at all the
;;     answer is also a refusal.
;;   * A window on `cmacs-gowl-edit-field-deny' (password managers,
;;     prompts, the lock screen) is refused whole -- the field read by
;;     the edit-field code itself, the OCR by
;;     `cmacs-deixis-ask-deny-applies-to-ocr'.
;;   * Text that comes from OUTSIDE Emacs's buffers -- a field's
;;     selection, OCR, a web page -- goes through `cmacs-redact-text'.
;;     This is deliberately unlike the AI field commands, which send the
;;     field verbatim: there the user asked for that exact text to be
;;     rewritten.  Here the text is whatever happened to be in a box
;;     around a pointer, and a box catches things nobody pointed at.
;;     The text of an Emacs buffer is sent as it is, as the other
;;     `cmacs-ai' actions send it: the buffer check has already passed
;;     and the text is exactly the thing that was pointed at.
;;   * A window's title and application are not sent unless
;;     `cmacs-deixis-ask-send-window-identity' says so, and then as the
;;     rules rewrite them.
;;
;; All of it runs under `cmacs-redact-as-model', because a question
;; asked by the user is still text composed for a model.
;;
;; NOTHING BLOCKS.  Under `emacs --gowl' this runs on the compositor's
;; thread.  A field read, a page's JavaScript, tesseract and the model
;; are all callbacks; every extraction has a timeout.  The one wait is
;; typing a question in the minibuffer, in the keyboard door.
;;
;; IMAGES.  A screen region cannot be handed to a multimodal model:
;; `cmacs-ai-chat-stream' and `cmacs-ai-session-append-message' take
;; text only.  Where OCR finds nothing the question is reported as
;; unanswerable, not guessed at.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-deixis)
;; For the `cmacs-redact-as-model' macro.  The functions are required
;; where they are called.
(eval-when-compile (require 'cmacs-redact))

(declare-function cmacs-redact-window "cmacs-redact" (app title &optional pid))
(declare-function cmacs-redact-buffer-p "cmacs-redact" (buffer-or-name))
(declare-function cmacs-redact-url "cmacs-redact" (url))
(declare-function cmacs-redact-text "cmacs-redact" (string))
(declare-function gowl-running-p "cmacs-gowl.c")
(declare-function gowl-client-info "cmacs-gowl.c")
(declare-function gowl-client-pid "cmacs-gowl.c")
(declare-function gowl-focused-client "cmacs-gowl.c")
(declare-function gowl-bar-notify "cmacs-gowl.c" (summary &optional body panel))
(declare-function cmacs-gowl-tools--screen-text "cmacs-gowl-tools"
                  (done x y width height language copy))
(declare-function cmacs-gowl-edit-field-focused-target "cmacs-gowl-edit-field" ())
(declare-function cmacs-gowl-edit-field-read-async "cmacs-gowl-edit-field"
                  (handler &optional target no-fallback))
(declare-function cmacs-gowl-edit-field-release "cmacs-gowl-edit-field" (session))
(declare-function cmacs-gowl-edit-field--denied-p "cmacs-gowl-edit-field"
                  (app-id title))
(declare-function cmacs-gowl-ai-field--choose "cmacs-gowl-ai-field"
                  (prompt lines callback))
(declare-function cmacs-gowl-ai-field--read-instruction "cmacs-gowl-ai-field"
                  (label))
(declare-function cmacs-gsurf-attached-p "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-get-uri "cmacs-gsurf-defuns.c" (buffer))
(declare-function cmacs-gsurf-run-javascript-async "cmacs-gsurf-defuns.c"
                  (buffer script callback))
(declare-function cmacs-ai-textops-stream "cmacs-ai-textops"
                  (title subtitle system prompt &optional retry))
(declare-function cmacs-ai-output-send-followup "cmacs-ai-output" ())
(declare-function cmacs-ai-output-append "cmacs-ai-output" (buf text))
(declare-function cmacs-ai-chat-cancel "cmacs-ai-stream.c" (session))
(declare-function cmacs-ai-register-action "cmacs-ai-actions" (&rest plist))
(declare-function cmacs-ai-target-buffer "cmacs-ai-target" (target))
(declare-function cmacs-ai-target-bounds "cmacs-ai-target" (target))
(declare-function cmacs-ai-target-kind "cmacs-ai-target" (target))
(declare-function cmacs-voice-loop-speak "cmacs-voice-loop" (text))
(declare-function cmacs-voice-loop--feed-reply "cmacs-voice-loop" (chunk))
(declare-function cmacs-voice-loop--set-state "cmacs-voice-loop" (new))
(declare-function flymake-diagnostics "flymake" (&optional beg end))
(declare-function flymake-diagnostic-text "flymake" (diag))
(declare-function flymake-diagnostic-type "flymake" (diag))
(declare-function flymake-diagnostic-beg "flymake" (diag))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading))
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-defun-at-point "treesit" ())
(declare-function treesit-node-start "treesit.c" (node))
(declare-function treesit-node-end "treesit.c" (node))
;; `compilation--file-struct->file-spec' and its siblings are MACROS in
;; compile.el, and the struct accessors are inlined: compiled without
;; compile.el loaded they become calls to functions that do not exist,
;; which the `ignore-errors' around their use turned into a silently
;; missing note (the interpreted file was fine, so only check-cmacs
;; saw it).
(eval-when-compile (require 'compile))
(declare-function compilation--ensure-parse "compile" (limit))
(declare-function compilation--message->loc "compile" (cl-x) t)
(declare-function compilation--loc->line "compile" (cl-x) t)
(declare-function compilation--loc->file-struct "compile" (cl-x) t)
(declare-function compilation--file-struct->file-spec "compile" (cl-x) t)

;; Special variables of other files that are let-bound or set here.
(defvar cmacs-voice-loop-mode)
(defvar cmacs-voice-loop-speak)
(defvar cmacs-voice-loop-default-route)
(defvar cmacs-voice-loop-barge-in-cancels-stream)
(defvar cmacs-voice-loop-state-change-functions)
(defvar cmacs-voice-loop--last-target)
(defvar cmacs-voice-loop--stream-open)
(defvar cmacs-voice-loop--tts-tail)
(defvar cmacs-ai-textops-provider)
(defvar cmacs-ai-textops-model)
(defvar cmacs-ai-output-select)
(defvar cmacs-ai-output--session)
(defvar cmacs-ai-output--request)
(defvar cmacs-ai-output--done)
(defvar cmacs-ai-output--compose-marker)
(defvar flymake-mode)
(defvar compilation-minor-mode)
(defvar compilation-shell-minor-mode)


;;;; Customization

(defgroup cmacs-deixis-ask nil
  "Asking a model about what you point at."
  :group 'cmacs-deixis
  :prefix "cmacs-deixis-ask-")

(defcustom cmacs-deixis-ask-voice t
  "Whether spoken questions about a pointed thing are answered here.
With nil, `cmacs-deixis-ask-utterance' takes nothing: \"what is that?\"
goes on to the voice loop's route, annotated, as it did before this
file.  `cmacs-deixis-ask-at-pointer' and the menu entry are unaffected."
  :type 'boolean)

(defcustom cmacs-deixis-ask-catch-all t
  "Whether a question that matches no defined one is still taken.
When non-nil, an utterance with a demonstrative that resolved, matching
none of `cmacs-deixis-ask-questions', is taken as a question about the
pointed thing when its first word is one of
`cmacs-deixis-ask-question-words' AND the voice route it was on is one
of `cmacs-deixis-ask-catch-all-routes'.  Everything else goes on to its
route untouched."
  :type 'boolean)

(defcustom cmacs-deixis-ask-question-words
  '("what" "what's" "whats" "why" "how" "who" "who's" "whose" "where"
    "when" "which" "is" "are" "was" "does" "did"
    "explain" "describe" "summarize" "summarise" "translate" "define"
    "compare" "tell" "read")
  "First words that make an utterance a question for the catch-all.
Compared with the utterance's first word, lower-cased, after
`cmacs-deixis-filler-words' and `cmacs-deixis-ask-lead-ins' are dropped.
\"Can\", \"could\", \"would\" and \"will\" are left out on purpose:
\"can you close that\" is a request to DO something, which a model with
tools on the chat route can carry out and an answer in a window cannot."
  :type '(repeat string))

(defcustom cmacs-deixis-ask-lead-ins
  '("so" "ok" "okay" "well" "now" "um" "uh" "hey" "then")
  "Words skipped at the start of an utterance before it is matched."
  :type '(repeat string))

(defcustom cmacs-deixis-ask-catch-all-routes '(chat agent)
  "Voice routes on which the catch-all may take an utterance.
A list of symbols: `chat', `agent' (any agent route), `commands',
`function' (a route that is a function).  The default is the routes
whose utterances were going to a model anyway; on the `commands' route
an unmatched utterance stays the voice commands' to report."
  :type '(set (const chat) (const agent) (const commands) (const function)))

(defcustom cmacs-deixis-ask-whole-words
  '("window" "app" "application" "program" "screen" "page" "site"
    "buffer" "file" "document")
  "Words that, right after a demonstrative, ask about the whole thing.
\"What is this window\" reads the whole window instead of a box around
the pointer; \"summarise this page\" the page instead of the paragraph
under it; \"explain this file\" what the Emacs window shows of it."
  :type '(repeat string))

(defcustom cmacs-deixis-ask-max-chars 6000
  "The most characters of one pointed thing that are sent to the model.
A function, subtree or page longer than this is cut to this much around
the pointed position, and the prompt says so."
  :type 'natnum)

(defcustom cmacs-deixis-ask-context-lines 5
  "Lines taken either side of the pointed line when it stands alone.
Used when what is there is a blank or lone line: the line by itself
would tell a model nothing."
  :type 'natnum)

(defcustom cmacs-deixis-ask-error-lines 15
  "The most lines read for one compilation error.
An error is its own line and the lines under it that belong to no other
message (the source excerpt, the caret)."
  :type 'natnum)

(defcustom cmacs-deixis-ask-ocr-box '(900 . 420)
  "Size (WIDTH . HEIGHT), in layout pixels, of the box OCR reads.
The box is centred on the pointed position and clamped to the window
that was pointed at, so it never reaches into a neighbour.  A window
smaller than the box is read whole."
  :type '(cons natnum natnum))

(defcustom cmacs-deixis-ask-ocr-language nil
  "Tesseract languages for the OCR read, e.g. \"eng+deu\".
nil uses the screenshot module's `ocr-language'."
  :type '(choice (const :tag "The screenshot module's" nil) string))

(defcustom cmacs-deixis-ask-web-min-chars 200
  "How much text the element under the pointer should have on a web page.
The element at the pointed place is often one word of a link.  Its
ancestors are climbed until one holds at least this many characters (and
no more than `cmacs-deixis-ask-max-chars')."
  :type 'natnum)

(defcustom cmacs-deixis-ask-deny-applies-to-ocr t
  "Whether `cmacs-gowl-edit-field-deny' also stops OCR of a window.
The list names windows whose text fields are never read: password
managers, password prompts, the lock screen.  Reading the same window's
pixels is the same breach by another road, so by default it is refused
too."
  :type 'boolean)

(defcustom cmacs-deixis-ask-send-window-identity nil
  "Whether a window's application and title go to the model.
nil (the default) sends the text and says only what kind of thing it
came from.  Non-nil adds the app id and title, as
`cmacs-redact-window' rewrites them.  A web page's URL and title are
always sent (through `cmacs-redact-url' and `cmacs-redact-text'): they
are what the page is."
  :type 'boolean)

(defcustom cmacs-deixis-ask-extract-timeout 45
  "Seconds one pointed thing may take to be read before it is given up.
OCR has its own limit (`cmacs-gowl-grab-ocr-timeout'); this is the
answer to a page or an application that never replies."
  :type 'number)

(defcustom cmacs-deixis-ask-followup-seconds 300
  "How long after an answer \"and that one?\" still continues it.
A follow-up later than this, or with the result window closed, is asked
afresh: the last question, about the new thing."
  :type 'number)

(defcustom cmacs-deixis-ask-provider nil
  "Provider symbol for deictic questions; nil uses `cmacs-ai-textops-provider'."
  :type '(choice (const :tag "The text operations'" nil) symbol))

(defcustom cmacs-deixis-ask-model nil
  "Model for deictic questions; nil uses `cmacs-ai-textops-model'."
  :type '(choice (const :tag "The text operations'" nil) string))

(defcustom cmacs-deixis-ask-system-prompt
  "The user pointed at something on their screen and asked about it.
You are given what they said and the text of what they pointed at: part
of an Emacs buffer, a web page, a text field, or text read off the
screen by OCR.  OCR text has recognition errors and may include
neighbouring text they did not mean; read through both.  Text may have
been redacted before it reached you; do not guess what was removed.
Answer the question about that thing, from that text.  When it is not
enough to answer, say what is missing instead of filling the gap.  Use
Org-mode markup.  Lead with the answer; be brief."
  "System prompt for deictic questions."
  :type 'string)

(defcustom cmacs-deixis-ask-voice-system-suffix
  "The answer will be read aloud: a few plain sentences, no markup, no
lists, no code blocks unless asked for."
  "Added to the system prompt when the answer is going to be spoken."
  :type 'string)

(defcustom cmacs-deixis-ask-menu
  '("What is this?"
    "Explain this."
    "Summarise this."
    "What does this error mean?"
    "Translate this into English.")
  "Questions `cmacs-deixis-ask-at-pointer' offers.
Over another program's window they are the rows of a gowl menu card,
with a last row for typing something else; in Emacs they are the
completions of the minibuffer read."
  :type '(repeat string))

(defcustom cmacs-deixis-ask-toast t
  "Whether refusals and failures are also shown as a toast on the gowl bar.
The echo area is not in view while another program has the screen."
  :type 'boolean)

(defconst cmacs-deixis-ask-title "explain that"
  "The title of the result window; its buffer is \"*cmacs-ai: TITLE*\".")

(defconst cmacs-deixis-ask-refusal-text
  "Your privacy rules keep that from a model; nothing was read."
  "The one sentence every privacy refusal carries.
The same words whatever was matched, so a refusal says nothing about
the rule set.")

(defvar cmacs-deixis-ask-history nil
  "History of the questions typed to `cmacs-deixis-ask-at-pointer'.")


;;;; Telling the user

(defun cmacs-deixis-ask--loop-p ()
  "Non-nil when the voice loop is on and loaded."
  (and (bound-and-true-p cmacs-voice-loop-mode)
       (fboundp 'cmacs-voice-loop--set-state)))

(defun cmacs-deixis-ask--say (voice format-string &rest args)
  "Report FORMAT-STRING with ARGS: echo area, bar toast, and aloud if VOICE.
Never signals: most of this file runs from callbacks."
  (let ((s (apply #'format format-string args)))
    (message "Deixis: %s" s)
    (when (and cmacs-deixis-ask-toast
               (fboundp 'gowl-bar-notify)
               (fboundp 'gowl-running-p)
               (ignore-errors (gowl-running-p)))
      (ignore-errors (gowl-bar-notify "Ask about that" s)))
    (when (and voice (cmacs-deixis-ask--loop-p))
      (ignore-errors (cmacs-voice-loop-speak s)))
    nil))


;;;; Privacy

(defmacro cmacs-deixis-ask--as-model (&rest body)
  "Run BODY as code composing text for a model, with the rules loaded."
  (declare (indent 0) (debug t))
  `(progn
     (require 'cmacs-redact)
     (cmacs-redact-as-model ,@body)))

(defun cmacs-deixis-ask--buffer-referent-p (referent)
  "Non-nil when REFERENT is a place in an Emacs buffer."
  (memq (plist-get referent :kind) '(buffer-position region point)))

(defun cmacs-deixis-ask--window-referent-p (referent)
  "Non-nil when REFERENT is a desktop window that is not an Emacs buffer."
  (eq (plist-get referent :kind) 'window))

(defun cmacs-deixis-ask--gsurf-p (buffer)
  "Non-nil when BUFFER shows a gsurf web view."
  (and (buffer-live-p buffer)
       (fboundp 'cmacs-gsurf-attached-p)
       (ignore-errors (cmacs-gsurf-attached-p buffer))))

(defun cmacs-deixis-ask--denied-p (app title)
  "Non-nil when the window APP / TITLE is on the edit-field deny list."
  (and (require 'cmacs-gowl-edit-field nil t)
       (fboundp 'cmacs-gowl-edit-field--denied-p)
       (cmacs-gowl-edit-field--denied-p app title)))

(defun cmacs-deixis-ask-refusal (referent)
  "Why REFERENT may not be asked about, as a sentence, or nil when it may.
This is the gate: it runs before any extractor, so nothing is read from
a thing it refuses.  A window is put to `cmacs-redact-window' and (see
`cmacs-deixis-ask-deny-applies-to-ocr') the edit-field deny list, a
buffer to `cmacs-redact-buffer-p', a web view also to
`cmacs-redact-url'.  Privacy refusals all read
`cmacs-deixis-ask-refusal-text'.  If the rules cannot be asked -- the
file does not load, a rule signals -- that is a refusal too."
  (cond
   ((null referent) "Nothing was being pointed at.")
   ((plist-get referent :stale) "That window has closed.")
   ((cmacs-deixis-ask--window-referent-p referent)
    (let ((app (plist-get referent :app-id))
          (title (plist-get referent :title))
          (client (plist-get referent :client)))
      (condition-case nil
          (cmacs-deixis-ask--as-model
            (cond
             ((null (cmacs-redact-window
                     app title
                     (and client (fboundp 'gowl-client-pid)
                          (ignore-errors (gowl-client-pid client)))))
              cmacs-deixis-ask-refusal-text)
             ((and cmacs-deixis-ask-deny-applies-to-ocr
                   (cmacs-deixis-ask--denied-p app title))
              cmacs-deixis-ask-refusal-text)))
        (error cmacs-deixis-ask-refusal-text))))
   ((cmacs-deixis-ask--buffer-referent-p referent)
    (let ((buffer (plist-get referent :buffer)))
      (if (not (buffer-live-p buffer))
          "That buffer is gone."
        (condition-case nil
            (cmacs-deixis-ask--as-model
              (cond
               ((cmacs-redact-buffer-p buffer) cmacs-deixis-ask-refusal-text)
               ((cmacs-deixis-ask--gsurf-p buffer)
                (let ((url (ignore-errors (cmacs-gsurf-get-uri buffer))))
                  (and (stringp url) (not (string-empty-p url))
                       (null (cmacs-redact-url url))
                       cmacs-deixis-ask-refusal-text)))))
          (error cmacs-deixis-ask-refusal-text)))))
   (t "There is nothing there to ask about.")))

(defun cmacs-deixis-ask--redact (text)
  "TEXT as a model may be shown it; fails closed to the empty string."
  (if (or (null text) (string-empty-p text))
      ""
    (condition-case nil
        (cmacs-deixis-ask--as-model (cmacs-redact-text text))
      (error ""))))


;;;; Extractors

(defvar cmacs-deixis-ask--extractors nil
  "Registered extractors: an alist of (NAME . PLIST).")

(defun cmacs-deixis-ask-register-extractor (name &rest props)
  "Register extractor NAME, which turns a kind of referent into text.
PROPS:

  :applies  (lambda (REFERENT SCOPE)) -> non-nil when this extractor may
            be able to read REFERENT.  Cheap: no I/O.
  :extract  (lambda (REFERENT SCOPE DONE)).  Reads the thing and calls
            DONE exactly once, now or later, with
              a CONTEXT plist   it was read
              nil               not mine after all: try the next one
              (:failed WHY)     it cannot be read; WHY is a sentence
              (:refused WHY)    it must not be read
            It must not block: anything slow is a callback.  It may
            signal instead of calling DONE, which counts as nil with the
            error remembered for the final report.
  :order    a number; lower runs first.  Default 50.  The built-in ones
            are gsurf 10, field 20, buffer 50, ocr 60.

SCOPE is nil, or `whole' when the question was about the whole window,
page or file.  A CONTEXT plist has
  :source       a symbol naming where the text came from
  :description  one line for the model saying what this is -- no window
                title, no application name; add those under :identity
  :text         the text
  :extra        more text about the same place (diagnostics), or nil
  :foreign      non-nil when the text did not come from an Emacs
                buffer: it is then put through `cmacs-redact-text'
  :clipped      non-nil when :text is part of something longer

The privacy gate (`cmacs-deixis-ask-refusal') has passed before any
extractor is asked.  Re-registering NAME replaces it."
  (setf (alist-get name cmacs-deixis-ask--extractors) props)
  name)

(defun cmacs-deixis-ask-unregister-extractor (name)
  "Forget extractor NAME."
  (setq cmacs-deixis-ask--extractors
        (assq-delete-all name cmacs-deixis-ask--extractors)))

(defun cmacs-deixis-ask-extractors-for (referent &optional scope)
  "The names of the extractors that apply to REFERENT, in the order tried."
  (mapcar
   #'car
   (sort (cl-remove-if-not
          (lambda (e)
            (let ((applies (plist-get (cdr e) :applies)))
              (or (null applies)
                  (ignore-errors (funcall applies referent scope)))))
          (copy-sequence cmacs-deixis-ask--extractors))
         (lambda (a b)
           (< (or (plist-get (cdr a) :order) 50)
              (or (plist-get (cdr b) :order) 50))))))

(defun cmacs-deixis-ask--clip (text &optional around)
  "TEXT cut to `cmacs-deixis-ask-max-chars'; returns (TEXT . CLIPPED).
AROUND, a character index, is kept in view; without it the head is."
  (let ((max cmacs-deixis-ask-max-chars)
        (len (length text)))
    (if (or (<= max 0) (<= len max))
        (cons text nil)
      (let* ((start (if around
                        (max 0 (min (- len max) (- around (/ max 2))))
                      0)))
        (cons (substring text start (+ start max)) t)))))

(defun cmacs-deixis-ask--finalise (result)
  "Make extractor RESULT fit to send: redact foreign text, trim, clip."
  (if (or (null result) (plist-get result :failed) (plist-get result :refused))
      result
    (let* ((foreign (plist-get result :foreign))
           (text (string-trim (or (plist-get result :text) "")))
           (extra (plist-get result :extra)))
      (when foreign
        (setq text (cmacs-deixis-ask--redact text)
              extra (and extra (cmacs-deixis-ask--redact extra))))
      (if (string-empty-p text)
          (list :failed "There is no text there to ask about.")
        (let ((clip (cmacs-deixis-ask--clip text)))
          (append (list :text (car clip)
                        :extra extra
                        :clipped (or (cdr clip) (plist-get result :clipped)))
                  result))))))

(defun cmacs-deixis-ask-extract (referent scope done)
  "Read what REFERENT points at and call DONE once with the result.
SCOPE is nil or `whole'.  The result is a context plist ready to send
\(see `cmacs-deixis-ask-register-extractor'; foreign text has been
through `cmacs-redact-text'), or (:refused WHY) or (:failed WHY).  The
privacy gate is asked first; the extractors that apply are then tried in
order until one answers.  Never blocks; gives up after
`cmacs-deixis-ask-extract-timeout' seconds."
  (let ((why (cmacs-deixis-ask-refusal referent)))
    (if why
        (funcall done (list :refused why))
      (let ((finished nil) (timer nil) (last-error nil))
        (cl-labels
            ((finish (result)
               (unless finished
                 (setq finished t)
                 (when (timerp timer) (cancel-timer timer))
                 (funcall done (cmacs-deixis-ask--finalise result))))
             (try (names)
               (if (null names)
                   (finish (list :failed
                                 (or last-error
                                     "Nothing there could be read.")))
                 (let ((called nil)
                       (extract (plist-get
                                 (alist-get (car names)
                                            cmacs-deixis-ask--extractors)
                                 :extract)))
                   (condition-case err
                       (funcall extract referent scope
                                (lambda (result)
                                  (unless called
                                    (setq called t)
                                    (if result
                                        (finish result)
                                      (try (cdr names))))))
                     (error
                      (unless called
                        (setq called t
                              last-error (error-message-string err))
                        (try (cdr names)))))))))
          (setq timer
                (run-at-time cmacs-deixis-ask-extract-timeout nil
                             (lambda ()
                               (finish
                                (list :failed
                                      "Reading that took too long.")))))
          (try (cmacs-deixis-ask-extractors-for referent scope)))))))


;;;; Extractor: an Emacs buffer

(defun cmacs-deixis-ask--contains-p (bounds pos)
  "Non-nil when BOUNDS, a cons (BEG . END), is a non-empty span around POS."
  (and (consp bounds) (integerp (car bounds)) (integerp (cdr bounds))
       (< (car bounds) (cdr bounds))
       (<= (car bounds) pos) (<= pos (cdr bounds))))

(defun cmacs-deixis-ask--compilation-p ()
  "Non-nil when the current buffer marks its lines as compilation messages."
  (or (derived-mode-p 'compilation-mode)
      (bound-and-true-p compilation-minor-mode)
      (bound-and-true-p compilation-shell-minor-mode)))

(defun cmacs-deixis-ask--compilation-thing (pos)
  "The compilation message at POS as (BEG END NOTE), or nil.
The message is its line and the lines under it that carry no message of
their own (gcc's source excerpt and caret), up to
`cmacs-deixis-ask-error-lines'.  NOTE names the file and line the
message is about, from the data `compilation-next-error' works from."
  (when (cmacs-deixis-ask--compilation-p)
    (save-excursion
      (goto-char pos)
      (let ((bol (line-beginning-position)) (eol (line-end-position)))
        ;; Parsing is lazy; make sure this line and the ones that may
        ;; belong to it have been looked at.
        (when (fboundp 'compilation--ensure-parse)
          (ignore-errors
            (compilation--ensure-parse
             (save-excursion
               (forward-line cmacs-deixis-ask-error-lines)
               (point)))))
        (when-let* ((msg (or (get-text-property pos 'compilation-message)
                             (get-text-property bol 'compilation-message)
                             (let ((at (text-property-not-all
                                        bol eol 'compilation-message nil)))
                               (and at (get-text-property
                                        at 'compilation-message))))))
          (let ((end eol) (count 1))
            (goto-char eol)
            (while (and (< count cmacs-deixis-ask-error-lines)
                        (zerop (forward-line 1))
                        (not (eobp))
                        (not (looking-at-p "[ \t]*$"))
                        (not (text-property-not-all
                              (line-beginning-position) (line-end-position)
                              'compilation-message nil)))
              (setq end (line-end-position)
                    count (1+ count)))
            (list bol end
                  (ignore-errors
                    (let* ((loc (compilation--message->loc msg))
                           (file (car (compilation--file-struct->file-spec
                                       (compilation--loc->file-struct loc))))
                           (line (compilation--loc->line loc)))
                      (and (stringp file)
                           (format "The message is about %s%s."
                                   file
                                   (if line (format ", line %d" line)
                                     ""))))))))))))

(defun cmacs-deixis-ask--org-thing (pos)
  "The org subtree around POS as (BEG . END), or nil before the first heading."
  (when (and (derived-mode-p 'org-mode) (fboundp 'org-back-to-heading))
    (save-excursion
      (goto-char pos)
      (when (ignore-errors (org-back-to-heading t) t)
        (let ((beg (point)))
          (ignore-errors (org-end-of-subtree t t))
          (and (> (point) beg) (cons beg (point))))))))

(defun cmacs-deixis-ask--defun-thing (pos)
  "The function around POS as (BEG . END), or nil when POS is in none.
Tree-sitter's notion when the buffer has a parser, else the major
mode's (`bounds-of-thing-at-point')."
  (when (derived-mode-p 'prog-mode)
    (save-excursion
      (goto-char pos)
      (let ((bounds
             (or (and (fboundp 'treesit-parser-list)
                      (fboundp 'treesit-defun-at-point)
                      (ignore-errors (treesit-parser-list))
                      (when-let* ((node (ignore-errors
                                          (treesit-defun-at-point))))
                        (cons (treesit-node-start node)
                              (treesit-node-end node))))
                 (ignore-errors (bounds-of-thing-at-point 'defun)))))
        (and (cmacs-deixis-ask--contains-p bounds pos) bounds)))))

(defun cmacs-deixis-ask--lines-around (pos)
  "The lines within `cmacs-deixis-ask-context-lines' of POS, as (BEG . END)."
  (save-excursion
    (goto-char pos)
    (cons (progn (forward-line (- cmacs-deixis-ask-context-lines))
                 (line-beginning-position))
          (progn (goto-char pos)
                 (forward-line cmacs-deixis-ask-context-lines)
                 (line-end-position)))))

(defun cmacs-deixis-ask-buffer-thing (buffer position &optional scope window
                                             beg end)
  "Choose what is \"at\" POSITION in BUFFER; a plist (:what :beg :end ...).
The most specific of, in the buffer's own terms:

  `region'             BEG..END when given (a `region' referent), else
                       the active region when POSITION is inside it
  `shown'              SCOPE `whole': what WINDOW shows of the buffer,
                       or all of it when WINDOW does not show it
  `compilation-error'  the compilation message there (with :note)
  `subtree'            the org subtree
  `defun'              the function, by tree-sitter or the major mode
  `paragraph'          the paragraph
  `lines'              the line with a few around it, when the line
                       alone is blank or nearly so
  `line'               the line

Anything longer than `cmacs-deixis-ask-max-chars' is cut to that much
around POSITION and marked :clipped.  Narrowing is respected: what is
outside it is not read."
  (with-current-buffer buffer
    (save-excursion
      (let* ((pos (max (point-min) (min (or position (point)) (point-max))))
             ;; Read before point moves: the region is between the mark
             ;; and POINT.
             (active (and (use-region-p)
                          (cons (region-beginning) (region-end))))
             (note nil)
             (thing
              (progn
                (goto-char pos)
                (or (and (integerp beg) (integerp end) (< beg end)
                         (list 'region (max (point-min) beg)
                               (min (point-max) end)))
                    (and active
                         (<= (car active) pos (cdr active))
                         (list 'region (car active) (cdr active)))
                    (and (eq scope 'whole)
                         (if (and (window-live-p window)
                                  (eq (window-buffer window) buffer))
                             (list 'shown (max (point-min) (window-start window))
                                   (min (point-max)
                                        (or (window-end window) (point-max))))
                           (list 'shown (point-min) (point-max))))
                    (when-let* ((c (cmacs-deixis-ask--compilation-thing pos)))
                      (setq note (nth 2 c))
                      (list 'compilation-error (nth 0 c) (nth 1 c)))
                    (when-let* ((b (cmacs-deixis-ask--org-thing pos)))
                      (list 'subtree (car b) (cdr b)))
                    (when-let* ((b (cmacs-deixis-ask--defun-thing pos)))
                      (list 'defun (car b) (cdr b)))
                    (let ((b (ignore-errors
                               (bounds-of-thing-at-point 'paragraph))))
                      (and (cmacs-deixis-ask--contains-p b pos)
                           (list 'paragraph (car b) (cdr b))))
                    (list 'line (line-beginning-position)
                          (line-end-position)))))
             (what (nth 0 thing)) (b (nth 1 thing)) (e (nth 2 thing))
             (clipped nil))
        ;; A blank or lone line says nothing by itself.  (A region is
        ;; what it is, however short.)
        (when (and (not (eq what 'region))
                   (< (length (string-trim (buffer-substring-no-properties b e))) 3))
          (let ((around (cmacs-deixis-ask--lines-around pos)))
            (setq what 'lines b (car around) e (cdr around))))
        ;; Too long: keep what is around the pointed position, on whole
        ;; lines.
        (when (and (> cmacs-deixis-ask-max-chars 0)
                   (> (- e b) cmacs-deixis-ask-max-chars))
          (let* ((half (/ cmacs-deixis-ask-max-chars 2))
                 (nb (max b (min (- e cmacs-deixis-ask-max-chars)
                                 (- pos half))))
                 (ne (min e (+ nb cmacs-deixis-ask-max-chars))))
            (setq b (progn (goto-char nb)
                           (if (> nb b) (line-beginning-position 2) nb))
                  e (progn (goto-char ne)
                           (if (< ne e) (line-beginning-position) ne))
                  clipped t)
            (when (>= b e) (setq b nb e ne))))
        (list :what what :beg b :end e :clipped clipped :note note)))))

(defun cmacs-deixis-ask--diagnostics (beg end)
  "The flymake diagnostics between BEG and END of the current buffer, or nil.
Eglot reports through flymake, so a language server's are among them."
  (when (and (bound-and-true-p flymake-mode)
             (fboundp 'flymake-diagnostics)
             (fboundp 'flymake-diagnostic-text))
    (when-let* ((diags (ignore-errors (flymake-diagnostics beg end))))
      (mapconcat
       (lambda (d)
         (format "line %d: [%s] %s"
                 (line-number-at-pos (ignore-errors (flymake-diagnostic-beg d))
                                     t)
                 (replace-regexp-in-string
                  "\\`:\\|\\`\\(?:eglot\\|flymake\\)-" ""
                  (format "%s" (ignore-errors (flymake-diagnostic-type d))))
                 (flymake-diagnostic-text d)))
       (seq-take diags 10) "\n"))))

(defconst cmacs-deixis-ask--thing-names
  '((region . "the selected region")
    (shown . "what the window shows of it")
    (compilation-error . "the compiler message at the pointed position")
    (subtree . "the Org subtree at the pointed position")
    (defun . "the function at the pointed position")
    (paragraph . "the paragraph at the pointed position")
    (lines . "the lines around the pointed position")
    (line . "the line at the pointed position"))
  "What each kind of thing is called in a prompt.")

(defun cmacs-deixis-ask--extract-buffer (referent scope done)
  "The buffer extractor: the thing at REFERENT's position, with its setting."
  (let* ((buffer (plist-get referent :buffer))
         (region (eq (plist-get referent :kind) 'region))
         (thing (cmacs-deixis-ask-buffer-thing
                 buffer
                 (or (plist-get referent :position) (plist-get referent :beg))
                 scope (plist-get referent :window)
                 (and region (plist-get referent :beg))
                 (and region (plist-get referent :end)))))
    (with-current-buffer buffer
      (let* ((b (plist-get thing :beg)) (e (plist-get thing :end))
             (diags (cmacs-deixis-ask--diagnostics b e))
             (note (plist-get thing :note)))
        (funcall
         done
         (list :source 'buffer
               :what (plist-get thing :what)
               :description
               (format "text from an Emacs buffer (%s%s; lines %d-%d; %s%s)"
                       major-mode
                       (if buffer-file-name
                           (format "; file %s"
                                   (abbreviate-file-name buffer-file-name))
                         "")
                       (line-number-at-pos b t) (line-number-at-pos e t)
                       (alist-get (plist-get thing :what)
                                  cmacs-deixis-ask--thing-names)
                       (if (plist-get thing :clipped)
                           ", cut to the part around it" ""))
               :text (buffer-substring-no-properties b e)
               :extra (let ((parts (delq nil
                                         (list note
                                               (and diags
                                                    (concat "Diagnostics \
reported there:\n" diags))))))
                        (and parts (string-join parts "\n")))
               :clipped (plist-get thing :clipped)))))))

(cmacs-deixis-ask-register-extractor
 'buffer
 :order 50
 :applies (lambda (r _scope)
            (and (cmacs-deixis-ask--buffer-referent-p r)
                 (buffer-live-p (plist-get r :buffer))))
 :extract #'cmacs-deixis-ask--extract-buffer)


;;;; Extractor: a gsurf web view

(defun cmacs-deixis-ask--window-fraction (referent)
  "Where in its Emacs window REFERENT was pointed, as fractions (FX . FY).
From the frame pixel a frame referent carries (:frame-x, :frame-y) and
the window's body edges; the middle of the window when either is not
known (a referent made from point, or by the VR laser)."
  (let ((win (plist-get referent :window))
        (x (plist-get referent :frame-x))
        (y (plist-get referent :frame-y)))
    (or (and (window-live-p win) (numberp x) (numberp y)
             (when-let* ((edges (ignore-errors (window-body-pixel-edges win))))
               (cl-flet ((unit (v) (min 1.0 (max 0.0 v))))
                 (cons (unit (/ (- x (nth 0 edges))
                                (float (max 1 (- (nth 2 edges)
                                                 (nth 0 edges))))))
                       (unit (/ (- y (nth 1 edges))
                                (float (max 1 (- (nth 3 edges)
                                                 (nth 1 edges))))))))))
        (cons 0.5 0.5))))

(defun cmacs-deixis-ask--web-script (fx fy)
  "JavaScript reading a page at fractions FX, FY of its viewport.
Evaluates to JSON: title, the selection, the text nearest the place
\(the element there, widened to an ancestor with enough text), and the
start of the page's text.  Only numbers are put into it."
  (format "(function(fx,fy,min,max){
var o={title:document.title||'',sel:'',near:'',page:''};
try{var s=window.getSelection();o.sel=s?String(s).slice(0,max):'';}catch(e){}
try{var el=document.elementFromPoint(Math.round(fx*window.innerWidth),
Math.round(fy*window.innerHeight));
var t=el?(el.innerText||el.textContent||''):'';
while(el&&el.parentElement&&t.trim().length<min){
var p=el.parentElement;var pt=p.innerText||p.textContent||'';
if(pt.length>max&&t.trim().length>0)break;el=p;t=pt;}
o.near=t.slice(0,max);}catch(e){}
try{var b=document.body||document.documentElement;
o.page=(b.innerText||'').slice(0,max);}catch(e){}
return JSON.stringify(o);})(%.4f,%.4f,%d,%d)"
          fx fy cmacs-deixis-ask-web-min-chars
          (max 1 cmacs-deixis-ask-max-chars)))

(defun cmacs-deixis-ask--extract-gsurf (referent scope done)
  "The web extractor: REFERENT's page, read by one asynchronous script."
  (let* ((buffer (plist-get referent :buffer))
         (at (cmacs-deixis-ask--window-fraction referent))
         (url (ignore-errors (cmacs-gsurf-get-uri buffer))))
    (cmacs-gsurf-run-javascript-async
     buffer
     (cmacs-deixis-ask--web-script (car at) (cdr at))
     (lambda (json)
       (let* ((page (and (stringp json) (not (string-empty-p json))
                         (ignore-errors
                           (json-parse-string json :object-type 'alist))))
              (sel (string-trim (or (alist-get 'sel page) "")))
              (near (string-trim (or (alist-get 'near page) "")))
              (whole (string-trim (or (alist-get 'page page) "")))
              (pick (cond ((not (string-empty-p sel))
                           (cons "the text selected on it" sel))
                          ((and (not (eq scope 'whole))
                                (not (string-empty-p near)))
                           (cons "the text nearest the pointed position" near))
                          (t (cons "the start of its text" whole)))))
         (funcall
          done
          (if (null page)
              (list :failed "The page did not say what is on it.")
            (list :source 'web
                  :foreign t
                  :description
                  (format "a web page%s%s; %s"
                          (let ((title (cmacs-deixis-ask--redact
                                        (or (alist-get 'title page) ""))))
                            (if (string-empty-p title) ""
                              (format " titled \"%s\"" title)))
                          ;; The gate has already refused an excluded
                          ;; URL; this is the form the rules rewrite it
                          ;; to.
                          (let ((shown (and (stringp url)
                                            (ignore-errors
                                              (cmacs-deixis-ask--as-model
                                                (cmacs-redact-url url))))))
                            (if (and shown (not (string-empty-p shown)))
                                (format " at %s" shown)
                              ""))
                          (car pick))
                  :text (cdr pick)))))))))

(cmacs-deixis-ask-register-extractor
 'gsurf
 :order 10
 :applies (lambda (r _scope)
            (and (cmacs-deixis-ask--buffer-referent-p r)
                 (cmacs-deixis-ask--gsurf-p (plist-get r :buffer))
                 (fboundp 'cmacs-gsurf-run-javascript-async)))
 :extract #'cmacs-deixis-ask--extract-gsurf)


;;;; Extractors: another program's window

(defun cmacs-deixis-ask--gowl-p ()
  "Non-nil when a compositor runs in this Emacs."
  (and (fboundp 'gowl-running-p) (ignore-errors (gowl-running-p))))

(defun cmacs-deixis-ask--identity (referent)
  "\" (APP, titled TITLE)\" for REFERENT's window when that may be sent, else \"\"."
  (if (not cmacs-deixis-ask-send-window-identity)
      ""
    (let ((shown (ignore-errors
                   (cmacs-deixis-ask--as-model
                     (cmacs-redact-window (plist-get referent :app-id)
                                          (plist-get referent :title))))))
      (if (and shown (or (car shown) (cdr shown)))
          (format " (%s%s)"
                  (or (car shown) "an application")
                  (if (and (cdr shown) (not (string-empty-p (cdr shown))))
                      (format ", titled \"%s\"" (cdr shown))
                    ""))
        ""))))

(defun cmacs-deixis-ask--field-target (referent)
  "The edit-field target for REFERENT's window, or nil.
Non-nil only when that window holds the keyboard -- text-input reaches
the focused window and no other -- and its field may be touched."
  (when (and (cmacs-deixis-ask--gowl-p)
             (require 'cmacs-gowl-edit-field nil t)
             (fboundp 'cmacs-gowl-edit-field-focused-target))
    (let ((target (ignore-errors (cmacs-gowl-edit-field-focused-target))))
      (and target
           (not (plist-get target :refused))
           (integerp (plist-get target :id))
           (eql (plist-get target :id) (plist-get referent :client-id))
           target))))

(defun cmacs-deixis-ask--extract-field (referent _scope done)
  "The field extractor: the text SELECTED in REFERENT's focused field.
Through a headless edit-field session, so the deny list, the password
refusal and the text-input read are that file's.  The clipboard
fallback is never used: it types Ctrl+A and Ctrl+C at the application,
which is no way to answer a question.  A field with no selection is not
this extractor's: the next one (OCR) reads what was pointed at."
  (let ((target (cmacs-deixis-ask--field-target referent)))
    (if (null target)
        (funcall done nil)
      (cmacs-gowl-edit-field-read-async
       (lambda (event session &rest args)
         (pcase event
           ('read
            (let* ((text (or (nth 0 args) ""))
                   (cursor (nth 1 args)) (anchor (nth 2 args)))
              (ignore-errors (cmacs-gowl-edit-field-release session))
              (funcall
               done
               (and (integerp cursor) (integerp anchor) (/= cursor anchor)
                    (list :source 'field
                          :foreign t
                          :description
                          (format "the text selected in a text field of \
another program%s"
                                  (cmacs-deixis-ask--identity referent))
                          :text (substring text
                                           (max 0 (min cursor anchor))
                                           (min (length text)
                                                (max cursor anchor))))))))
           ('failed (funcall done nil))))
       target t))))

(cmacs-deixis-ask-register-extractor
 'field
 :order 20
 :applies (lambda (r scope)
            (and (cmacs-deixis-ask--window-referent-p r)
                 (not (eq scope 'whole))
                 (plist-get r :client)))
 :extract #'cmacs-deixis-ask--extract-field)

(defun cmacs-deixis-ask-ocr-region (referent &optional scope geometry)
  "The screen region to read for REFERENT, as (X Y WIDTH HEIGHT), or nil.
GEOMETRY is the window's (X Y WIDTH HEIGHT) in layout pixels (asked of
the compositor when nil).  With SCOPE `whole', or a referent with no
pointed position, that is the answer.  Otherwise it is a box of
`cmacs-deixis-ask-ocr-box' centred on the pointed position and moved to
lie inside the window; a window smaller than the box is read whole."
  (let* ((g (or geometry
                (alist-get 'geometry
                           (ignore-errors
                             (gowl-client-info (plist-get referent :client))))))
         (px (plist-get referent :x)) (py (plist-get referent :y)))
    (when (and (= (length g) 4) (> (nth 2 g) 0) (> (nth 3 g) 0))
      (let* ((gx (max 0 (round (nth 0 g)))) (gy (max 0 (round (nth 1 g))))
             (gw (round (nth 2 g))) (gh (round (nth 3 g))))
        (if (or (eq scope 'whole) (not (numberp px)) (not (numberp py)))
            (list gx gy gw gh)
          (let* ((w (min gw (max 1 (car cmacs-deixis-ask-ocr-box))))
                 (h (min gh (max 1 (cdr cmacs-deixis-ask-ocr-box))))
                 (x (max gx (min (- (+ gx gw) w) (- (round px) (/ w 2)))))
                 (y (max gy (min (- (+ gy gh) h) (- (round py) (/ h 2))))))
            (list x y w h)))))))

(defun cmacs-deixis-ask--extract-ocr (referent scope done)
  "The OCR extractor: tesseract over a region of REFERENT's window.
The capture and the asynchronous tesseract run are the gowl tools'
\(`cmacs-gowl-tools--screen-text', what the `gowl_screen_text' tool
calls), entered as a model would enter it, so its guard refuses a region
that shows a window the rules withhold."
  (let ((region (cmacs-deixis-ask-ocr-region referent scope)))
    (if (null region)
        (funcall done (list :failed "That window has no place on screen."))
      (require 'cmacs-gowl-tools)
      (cmacs-deixis-ask--as-model
        (cmacs-gowl-tools--screen-text
         (lambda (text)
           (funcall
            done
            (cond
             ((not (stringp text)) (list :failed "The screen could not be read."))
             ((string-prefix-p "Error: " text)
              (list :failed (substring text 7)))
             ((string-empty-p (string-trim text))
              ;; This is where a picture would be sent instead, if the
              ;; model interface took one.
              (list :failed "No text could be read there, and a picture \
of it cannot be sent to the model."))
             (t
              (list :source 'ocr
                    :foreign t
                    :description
                    (format "text read by OCR off %s of another program%s; \
expect recognition errors and neighbouring text"
                            (if (eq scope 'whole) "a window"
                              "the part of a window around the pointed \
position")
                            (cmacs-deixis-ask--identity referent))
                    :text text)))))
         (nth 0 region) (nth 1 region) (nth 2 region) (nth 3 region)
         cmacs-deixis-ask-ocr-language nil)))))

(cmacs-deixis-ask-register-extractor
 'ocr
 :order 60
 :applies (lambda (r _scope)
            (and (cmacs-deixis-ask--window-referent-p r)
                 (plist-get r :client)
                 (cmacs-deixis-ask--gowl-p)))
 :extract #'cmacs-deixis-ask--extract-ocr)


;;;; Recognising a question

(defvar cmacs-deixis-ask-questions nil
  "The deictic questions: an alist of (NAME . PLIST), newest first.
PLIST has :pattern, :instruction, :followup and :doc.  See
`cmacs-deixis-define-question'.")

(defmacro cmacs-deixis-define-question (name pattern &rest props)
  "Define deictic question NAME, taken when an utterance matches PATTERN.
The sibling of `cmacs-deixis-define-command', for utterances whose
\"body\" is always the same -- ask a model about what was pointed at --
so there is no argument list and no body.  PATTERN is a regexp matched
against the same canonical form: lower-cased words, fillers dropped,
each bound demonstrative replaced by \"<object>\" or \"<place>\"
\(`cmacs-deixis-canonical'), with `cmacs-deixis-ask-lead-ins' taken off
the front.  \"So what does this error mean?\" is
\"what does <object> error mean\".  Anchor it with \\\\=` and \\\\='.

PROPS may begin with a docstring, then keywords:
  :instruction STRING  added to the prompt under what was said -- how to
                       answer this kind of question
  :followup BOOL       the utterance continues the last answer (\"and
                       that one?\") instead of asking a new question

A question is tried only after every deictic command, and only when
every demonstrative has a referent that still exists.

  (cmacs-deixis-define-question who-wrote
      \"\\\\=`who wrote <object>\\\\='\"
    \"Who wrote the pointed thing.\"
    :instruction \"Name the author if the text says; do not guess.\")"
  (declare (indent 2) (doc-string 3))
  (let ((doc (and (stringp (car props)) (pop props))))
    `(progn
       (setf (alist-get ',name cmacs-deixis-ask-questions)
             (list :pattern ,pattern
                   :instruction ,(plist-get props :instruction)
                   :followup ,(plist-get props :followup)
                   :doc ,doc))
       ',name)))

(cmacs-deixis-define-question what-is
    "\\`what\\(?:'s\\|s\\| is\\| are\\| was\\) <object>\
\\(?: \\(?:called\\|for\\|about\\|doing\\|saying\\|showing\\)\\)?\\'"
  "\"What is that?\"")

(cmacs-deixis-define-question explain
    "\\`\\(?:\\(?:can\\|could\\|would\\) you \\)?\
\\(?:explain\\|describe\\) <object>\\(?: .*\\)?\\'"
  "\"Explain this.\""
  :instruction "Explain what it is and does, concentrating on what is \
not obvious.")

(cmacs-deixis-define-question summarise
    "\\`\\(?:\\(?:can\\|could\\|would\\) you \\)?\
\\(?:summari[sz]e\\|sum\\|tl;?dr\\) <object>\\(?: .*\\)?\\'"
  "\"Summarise that.\""
  :instruction "Summarise it: one line saying what it is, then the \
substance.")

(cmacs-deixis-define-question translate
    "\\`\\(?:\\(?:can\\|could\\|would\\) you \\)?\
translate <object>\\(?: .*\\)?\\'"
  "\"Translate that\" (\"... into German\")."
  :instruction "Translate it.  Into English unless another language was \
asked for.  Give the translation first.")

(cmacs-deixis-define-question meaning
    "\\`what does <object>\\(?: [a-z' ]+\\)? \\(?:mean\\|say\\|do\\)\\'"
  "\"What does this error mean?\""
  :instruction "Say what it means and, if it is an error, the likely \
cause and the fix.")

(cmacs-deixis-define-question why
    "\\`why \\(?:is\\|isn't\\|are\\|aren't\\|does\\|doesn't\\|did\\|didn't\\) \
<object>\\(?: .*\\)?\\'"
  "\"Why is this failing?\""
  :instruction "Give the most likely reason, from what is there, and \
what would confirm it.")

(cmacs-deixis-define-question compare
    "\\`\\(?:\\(?:compare\\|diff\\) <object>\
\\(?: \\(?:and\\|with\\|against\\|versus\\|vs\\)\\)? <object>\
\\|what\\(?:'s\\|s\\| is\\) difference between <object> and <object>\
\\|how \\(?:do\\|does\\) <object> and <object> differ\
\\|how \\(?:is\\|does\\) <object> \\(?:different\\|differ\\) from <object>\\)\\'"
  "\"Compare this and that\"; \"what is the difference between this and that?\""
  :instruction "Compare the two: what they share, then how they differ.")

(cmacs-deixis-define-question and-that
    "\\`\\(?:and\\|\\(?:and \\)?\\(?:what\\|how\\) about\\) \
\\(?:<object>\\|<place>\\)\\(?: too\\| as well\\)?\\'"
  "\"And that one?\": the last question again, about another thing, in
the same conversation."
  :followup t)

(defvar cmacs-deixis-ask--last nil
  "The last question asked: a plist (:question :instruction :time).")

(defun cmacs-deixis-ask--recent-p ()
  "Non-nil when there is a question for \"and that one?\" to continue."
  (and cmacs-deixis-ask--last t))

(defun cmacs-deixis-ask--strip-lead (canon)
  "CANON without `cmacs-deixis-ask-lead-ins' at its start."
  (let ((words (split-string canon " " t)))
    (while (and (cdr words) (member (car words) cmacs-deixis-ask-lead-ins))
      (pop words))
    (string-join words " ")))

(defun cmacs-deixis-ask--route-class (target)
  "The class of voice route TARGET, as in `cmacs-deixis-ask-catch-all-routes'."
  (cond ((null target)
         (cmacs-deixis-ask--route-class
          (or (bound-and-true-p cmacs-voice-loop-default-route) 'chat)))
        ((memq target '(chat commands)) target)
        ((eq (car-safe target) 'agent) 'agent)
        ((functionp target) 'function)
        (t 'unknown)))

(defun cmacs-deixis-ask--scopes (text bindings)
  "The scope of each referent of BINDINGS in TEXT, as an alist (MARKER . SCOPE).
A demonstrative directly followed by one of
`cmacs-deixis-ask-whole-words' asks about the whole thing."
  (let ((norms (mapcar #'cmacs-deixis--norm (cmacs-deixis--tokens text))))
    (cl-loop for b in bindings
             for next = (nth (1+ (plist-get b :index)) norms)
             when (and next (member next cmacs-deixis-ask-whole-words))
             collect (cons (plist-get b :marker) 'whole))))

(defun cmacs-deixis-ask-match (text bindings &optional route)
  "Decide whether utterance TEXT with BINDINGS is a deictic question.
Returns nil when it is not, else a plist:
  :name         the question's name, or `catch-all'
  :instruction  how to answer it, or nil
  :followup     non-nil for \"and that one?\"
  :referents    the distinct things pointed at, in spoken order
  :scopes       for each of those, nil or `whole'

It is one only when every demonstrative resolved to something that
still exists, and then: when it matches one of
`cmacs-deixis-ask-questions' (a follow-up form only while there is a
question to follow up); or, with `cmacs-deixis-ask-catch-all', when its
first word is one of `cmacs-deixis-ask-question-words' and ROUTE -- the
voice route it was on, default the loop's current one -- is one of
`cmacs-deixis-ask-catch-all-routes'.  Pure but for reading those
variables."
  (when (and bindings
             (cl-every (lambda (b)
                         (let ((r (plist-get b :referent)))
                           (and r (not (plist-get r :stale)))))
                       bindings))
    (let* ((case-fold-search nil)
           (canon (cmacs-deixis-ask--strip-lead
                   (cmacs-deixis-canonical text bindings)))
           (defined
            (cl-loop for (name . def) in (reverse cmacs-deixis-ask-questions)
                     when (and (string-match-p (plist-get def :pattern) canon)
                               (or (not (plist-get def :followup))
                                   (cmacs-deixis-ask--recent-p)))
                     return (list :name name
                                  :instruction (plist-get def :instruction)
                                  :followup (plist-get def :followup))))
           (found
            (or defined
                (and cmacs-deixis-ask-catch-all
                     (member (car (split-string canon " " t))
                             cmacs-deixis-ask-question-words)
                     (memq (cmacs-deixis-ask--route-class
                            (or route
                                (bound-and-true-p
                                 cmacs-voice-loop--last-target)))
                           cmacs-deixis-ask-catch-all-routes)
                     (list :name 'catch-all)))))
      (when found
        (let ((scopes (cmacs-deixis-ask--scopes text bindings))
              (seen nil) (referents nil) (order nil))
          (dolist (b bindings)
            (let ((m (plist-get b :marker)))
              (unless (memq m seen)
                (push m seen)
                (push m order)
                (push (plist-get b :referent) referents))))
          (append found
                  (list :referents (nreverse referents)
                        :scopes (mapcar (lambda (m) (cdr (assq m scopes)))
                                        (nreverse order)))))))))


;;;; Composing the prompt

(defun cmacs-deixis-ask--annotate (text bindings)
  "TEXT with each bound demonstrative marked: \"what is this [this=①]\".
The markers are the ones the context blocks are headed with.  Unlike
`cmacs-deixis-annotate' there is no legend: the legend names windows by
title, and the blocks below say what each thing is."
  (if (null bindings)
      text
    (let ((by-index (mapcar (lambda (b) (cons (plist-get b :index) b))
                            bindings)))
      (string-join
       (cl-loop for tok in (cmacs-deixis--tokens text)
                for i from 0
                for b = (cdr (assq i by-index))
                collect (if (and b (plist-get b :marker))
                            (format "%s [%s=%s]" tok (plist-get b :word)
                                    (cmacs-deixis--marker-string
                                     (plist-get b :marker)))
                          tok))
       " "))))

(defun cmacs-deixis-ask-compose (question contexts &optional props)
  "The user message for QUESTION about CONTEXTS.
QUESTION is what was said or typed; CONTEXTS the context plists of the
things pointed at, in spoken order.  PROPS is a plist: :bindings (to
mark the demonstratives), :instruction, :followup, and :previous (the
question a follow-up continues)."
  (let ((bindings (plist-get props :bindings))
        (instruction (plist-get props :instruction)))
    (concat
     (if (plist-get props :followup)
         "The user now pointed at something else and said:\n\n  "
       "The user pointed at something on screen and said:\n\n  ")
     (cmacs-deixis-ask--annotate question bindings)
     "\n"
     (when (plist-get props :followup)
       (format "\nAnswer the earlier question%s for this instead.\n"
               (if (plist-get props :previous)
                   (format " (\"%s\")" (plist-get props :previous))
                 "")))
     (when instruction (concat "\n" instruction "\n"))
     (mapconcat
      (lambda (cell)
        (let ((n (car cell)) (c (cdr cell)))
          (concat
           (format "\n%s %s\n<<<\n%s\n>>>\n"
                   (cmacs-deixis--marker-string n)
                   (plist-get c :description)
                   (plist-get c :text))
           (when-let* ((extra (plist-get c :extra)))
             (concat extra "\n")))))
      (cl-loop for c in contexts for n from 1 collect (cons n c))
      ""))))


;;;; Speaking the answer

(defvar cmacs-deixis-ask--voice nil
  "Non-nil while a spoken question's answer is being fetched or spoken.")

(defun cmacs-deixis-ask--buffer-name ()
  "The name of the result buffer."
  (format "*cmacs-ai: %s*" cmacs-deixis-ask-title))

(defun cmacs-deixis-ask--our-buffer-p (buf)
  "Non-nil when BUF is the result buffer of a spoken question in flight."
  (and cmacs-deixis-ask--voice
       (bufferp buf)
       (equal (buffer-name buf) (cmacs-deixis-ask--buffer-name))))

(defun cmacs-deixis-ask--tap-append (buf text)
  "Advice before `cmacs-ai-output-append': speak a spoken question's answer.
Only BUF = this file's result buffer, and only while the loop's reply
is open -- a barge-in closes it, and what arrives after is not spoken.
The sentence splitting and the speech queue are the loop's own
\(`cmacs-voice-loop--feed-reply'), as for a chat reply."
  (when (and (cmacs-deixis-ask--our-buffer-p buf)
             (stringp text)
             (cmacs-deixis-ask--loop-p)
             (bound-and-true-p cmacs-voice-loop-speak)
             (bound-and-true-p cmacs-voice-loop--stream-open))
    (ignore-errors (cmacs-voice-loop--feed-reply text))))

(defun cmacs-deixis-ask--voice-end (&optional flush)
  "A spoken question is over.  With FLUSH, speak what is left of the answer.
The loop's reply is closed, so its housekeeping returns to listening
\(and opens the follow-up window) once the speech is done."
  (when cmacs-deixis-ask--voice
    (setq cmacs-deixis-ask--voice nil)
    (when (cmacs-deixis-ask--loop-p)
      (let ((tail (if (boundp 'cmacs-voice-loop--tts-tail)
                      cmacs-voice-loop--tts-tail
                    ""))
            (open (bound-and-true-p cmacs-voice-loop--stream-open)))
        (setq cmacs-voice-loop--tts-tail ""
              cmacs-voice-loop--stream-open nil)
        (when (and flush open (stringp tail) (not (string-empty-p tail)))
          (ignore-errors (cmacs-voice-loop-speak tail)))))))

(defun cmacs-deixis-ask--tap-finish (buf &optional error-message &rest _)
  "Advice before the result window settles: the spoken answer is complete.
BUF and ERROR-MESSAGE are `cmacs-ai-output-finish's."
  (when (cmacs-deixis-ask--our-buffer-p buf)
    (cmacs-deixis-ask--voice-end (null error-message))
    (when error-message
      (cmacs-deixis-ask--say t "That did not work: %s" error-message))))

(defun cmacs-deixis-ask--cancel-stream ()
  "Cancel the answer still streaming into the result buffer, if any."
  (let ((buf (get-buffer (cmacs-deixis-ask--buffer-name))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (and (bound-and-true-p cmacs-ai-output--session)
                   (not (bound-and-true-p cmacs-ai-output--done))
                   (fboundp 'cmacs-ai-chat-cancel))
          (ignore-errors
            (cmacs-ai-chat-cancel (cdr cmacs-ai-output--session))))))))

(defvar cmacs-deixis-ask--generation 0
  "Bumped by every new question and by a barge-in; stale work is dropped.")

(defun cmacs-deixis-ask--on-loop-state (new old)
  "The voice loop went from OLD to NEW: a barge-in ends a spoken answer.
The loop enters `hearing' from `thinking' or `speaking' only when the
user talks over a reply.  It has stopped the speech itself; the answer
still being read or streamed is ours to stop, when
`cmacs-voice-loop-barge-in-cancels-stream' says replies are."
  (when (and cmacs-deixis-ask--voice
             (eq new 'hearing)
             (memq old '(thinking speaking)))
    (cmacs-deixis-ask--voice-end nil)
    (when (bound-and-true-p cmacs-voice-loop-barge-in-cancels-stream)
      ;; Drops an extraction still in flight ...
      (cl-incf cmacs-deixis-ask--generation)
      ;; ... and stops the model.
      (cmacs-deixis-ask--cancel-stream))))

(defun cmacs-deixis-ask--voice-begin ()
  "A spoken question was taken: the loop is now waiting for its reply.
Marks the loop's reply open and the loop `thinking', which is what makes
talking over the answer a barge-in and what keeps the loop from
returning to `listening' while the thing is still being read."
  (setq cmacs-deixis-ask--voice t)
  (advice-add 'cmacs-ai-output-append :before #'cmacs-deixis-ask--tap-append)
  (advice-add 'cmacs-ai-output-finish :before #'cmacs-deixis-ask--tap-finish)
  (advice-add 'cmacs-ai-output--settle-followup :before
              #'cmacs-deixis-ask--tap-finish)
  (when (cmacs-deixis-ask--loop-p)
    (add-hook 'cmacs-voice-loop-state-change-functions
              #'cmacs-deixis-ask--on-loop-state)
    (setq cmacs-voice-loop--stream-open t
          cmacs-voice-loop--tts-tail "")
    (cmacs-voice-loop--set-state 'thinking)))


;;;; Asking

(defun cmacs-deixis-ask--followable-buffer ()
  "The result buffer when its conversation can be continued now, else nil.
That is: it exists, its last answer has settled, its follow-up region is
open, there is a session (or a request to rebuild one from), and the
answer is no older than `cmacs-deixis-ask-followup-seconds'."
  (let ((buf (get-buffer (cmacs-deixis-ask--buffer-name))))
    (and (buffer-live-p buf)
         cmacs-deixis-ask--last
         (< (- (float-time) (or (plist-get cmacs-deixis-ask--last :time) 0))
            cmacs-deixis-ask-followup-seconds)
         (with-current-buffer buf
           (and (bound-and-true-p cmacs-ai-output--done)
                (bound-and-true-p cmacs-ai-output--compose-marker)
                (or (bound-and-true-p cmacs-ai-output--session)
                    (bound-and-true-p cmacs-ai-output--request))))
         buf)))

(defun cmacs-deixis-ask--send-followup (buf prompt)
  "Send PROMPT as a follow-up on BUF's session, as `C-c C-c' there would.
PROMPT goes through the window's own compose region, so the turn is
rendered, sealed, recorded for promote-to-chat and streamed exactly as a
typed follow-up is -- and what was sent, context included, is there to
read.  A draft the user had in the compose region is put back."
  (with-current-buffer buf
    (let* ((start (marker-position cmacs-ai-output--compose-marker))
           (draft (string-trim
                   (buffer-substring-no-properties start (point-max)))))
      (save-excursion
        (delete-region start (point-max))
        (goto-char (point-max))
        (insert prompt))
      (cmacs-ai-output-send-followup)
      (unless (string-empty-p draft)
        (save-excursion
          (goto-char (point-max))
          (insert draft))))
    buf))

(defun cmacs-deixis-ask--subtitle (question contexts)
  "What the result window says produced it: QUESTION and what was read.
Local to the window, never sent."
  (format "%s -- %s"
          question
          (mapconcat (lambda (c) (symbol-name (plist-get c :source)))
                     contexts " + ")))

(defun cmacs-deixis-ask--ask (job contexts)
  "Send JOB's question about CONTEXTS; return the result buffer."
  (let* ((voice (plist-get job :voice))
         (question (plist-get job :question))
         (followup (and (plist-get job :followup)
                        (cmacs-deixis-ask--followable-buffer)))
         ;; "And that one?" with nothing left to continue: the question
         ;; it stood for, asked afresh about the new thing.
         (previous (and (plist-get job :followup)
                        (plist-get cmacs-deixis-ask--last :question)))
         (instruction (or (plist-get job :instruction)
                          (and (plist-get job :followup)
                               (plist-get cmacs-deixis-ask--last
                                          :instruction))))
         (prompt (cmacs-deixis-ask-compose
                  question contexts
                  (list :bindings (plist-get job :bindings)
                        :instruction instruction
                        :followup (plist-get job :followup)
                        :previous previous)))
         (speak (and voice (cmacs-deixis-ask--loop-p)
                     (bound-and-true-p cmacs-voice-loop-speak)))
         (buf nil))
    (condition-case err
        (progn
          (setq buf
                (if followup
                    (cmacs-deixis-ask--send-followup followup prompt)
                  (require 'cmacs-ai-textops)
                  (let ((cmacs-ai-textops-provider
                         (or cmacs-deixis-ask-provider
                             cmacs-ai-textops-provider))
                        (cmacs-ai-textops-model
                         (or cmacs-deixis-ask-model cmacs-ai-textops-model))
                        ;; A spoken question must not pull the selected
                        ;; window out from under whatever is being done.
                        (cmacs-ai-output-select
                         (and (not voice)
                              (bound-and-true-p cmacs-ai-output-select))))
                    (cmacs-ai-textops-stream
                     cmacs-deixis-ask-title
                     (cmacs-deixis-ask--subtitle question contexts)
                     (if speak
                         (concat cmacs-deixis-ask-system-prompt "\n\n"
                                 cmacs-deixis-ask-voice-system-suffix)
                       cmacs-deixis-ask-system-prompt)
                     prompt
                     ;; `g' asks the same thing again, silently, on a
                     ;; new session.
                     (lambda ()
                       (cmacs-deixis-ask--ask
                        (append (list :voice nil :followup nil) job)
                        contexts))))))
          ;; A follow-up keeps the question it continues.
          (unless (and (plist-get job :followup) cmacs-deixis-ask--last)
            (setq cmacs-deixis-ask--last
                  (list :question question :instruction instruction)))
          (setq cmacs-deixis-ask--last
                (plist-put cmacs-deixis-ask--last :time (float-time)))
          buf)
      (error
       (when voice (cmacs-deixis-ask--voice-end nil))
       (cmacs-deixis-ask--say voice "Could not ask: %s"
                              (error-message-string err))
       nil))))

(defun cmacs-deixis-ask-run (question referents &rest props)
  "Ask QUESTION about REFERENTS, the things pointed at.
REFERENTS is a list of referent plists (`cmacs-deixis-register-pointer'),
one per distinct thing, in spoken order; two give two contexts.  PROPS:

  :voice        non-nil when the question was spoken: the answer is
                spoken too, and refusals are said aloud
  :bindings     the utterance's bindings, to mark the demonstratives
  :instruction  how to answer, added to the prompt
  :scopes       a list parallel to REFERENTS of nil or `whole'
  :followup     continue the result window's conversation

Everything is checked for privacy first; if any of the things may not
be asked about, nothing is read and nothing is sent.  The things are
then read one after the other, without blocking, and the answer streams
into the result window.  Returns non-nil when the question was taken up
\(not when it has been answered)."
  (let* ((voice (plist-get props :voice))
         (generation (cl-incf cmacs-deixis-ask--generation))
         (job (append (list :question question) props))
         (scopes (plist-get props :scopes))
         (refusal (or (and (null referents) "Nothing was being pointed at.")
                      (cl-some #'cmacs-deixis-ask-refusal referents))))
    (if refusal
        (progn (cmacs-deixis-ask--say voice "%s" refusal) nil)
      (when voice (cmacs-deixis-ask--voice-begin))
      (let ((contexts nil))
        (cl-labels
            ((next (rest rest-scopes)
               (if (null rest)
                   (cmacs-deixis-ask--ask job (nreverse contexts))
                 (cmacs-deixis-ask-extract
                  (car rest) (car rest-scopes)
                  (lambda (result)
                    ;; A newer question, or a barge-in, has made this
                    ;; one moot.
                    (when (= generation cmacs-deixis-ask--generation)
                      (let ((why (or (plist-get result :refused)
                                     (plist-get result :failed))))
                        (if why
                            (progn
                              (when voice (cmacs-deixis-ask--voice-end nil))
                              (cmacs-deixis-ask--say voice "%s" why))
                          (push result contexts)
                          (next (cdr rest) (cdr rest-scopes))))))))))
          (next referents scopes)))
      t)))

;;;###autoload
(defun cmacs-deixis-ask-utterance (text bindings)
  "Take spoken TEXT with BINDINGS if it is a question about a pointed thing.
On `cmacs-deixis-unclaimed-functions': called by `cmacs-deixis-filter'
for an utterance no deictic command matched.  Returns non-nil when the
utterance was taken (it is then not sent on to the voice route), nil
when it is not a question (`cmacs-deixis-ask-match') or
`cmacs-deixis-ask-voice' is off."
  (when cmacs-deixis-ask-voice
    (when-let* ((match (cmacs-deixis-ask-match text bindings)))
      (cmacs-deixis-ask-run text (plist-get match :referents)
                            :voice t
                            :bindings bindings
                            :instruction (plist-get match :instruction)
                            :scopes (plist-get match :scopes)
                            :followup (plist-get match :followup))
      ;; Taken, whether it was then answered or refused: a refused
      ;; question must not go on to another model by the chat route.
      t)))

;;;###autoload
(add-hook 'cmacs-deixis-unclaimed-functions #'cmacs-deixis-ask-utterance)


;;;; The door with no voice

(defun cmacs-deixis-ask--question-scope (question)
  "`whole' when QUESTION names the whole thing (\"what is this window\")."
  (and (cl-some (lambda (tok)
                  (member (cmacs-deixis--norm tok)
                          cmacs-deixis-ask-whole-words))
                (cmacs-deixis--tokens question))
       'whole))

(defun cmacs-deixis-ask--keyboard-in-emacs-p ()
  "Non-nil when a minibuffer read would get the keys typed now.
Always so without a compositor.  Under gowl, only while one of Emacs's
own frames holds the keyboard: a read started while another program has
it would wait for keys that go elsewhere."
  (or (not (cmacs-deixis-ask--gowl-p))
      (not (fboundp 'gowl-focused-client))
      (let ((client (ignore-errors (gowl-focused-client))))
        (and client
             (eql (ignore-errors (gowl-client-pid client)) (emacs-pid))
             (not (alist-get 'embedded
                             (ignore-errors (gowl-client-info client))))))))

(defun cmacs-deixis-ask--read-question (referent callback)
  "Read a question about REFERENT and call CALLBACK with it, or with nil.
While another program has the keyboard, or REFERENT is another
program's window, the questions of `cmacs-deixis-ask-menu' are a gowl
menu card on top of everything, as the AI field commands' actions are,
with a last row that reads a typed question in a floating minibuffer.
Otherwise it is one minibuffer read with those questions as
completions."
  (let ((other "Something else..."))
    (if (and (cmacs-deixis-ask--gowl-p)
             (or (cmacs-deixis-ask--window-referent-p referent)
                 (not (cmacs-deixis-ask--keyboard-in-emacs-p)))
             (require 'cmacs-gowl-ai-field nil t)
             (fboundp 'cmacs-gowl-ai-field--choose))
        (cmacs-gowl-ai-field--choose
         "Ask about that"
         (append cmacs-deixis-ask-menu (list other))
         (lambda (index)
           (funcall
            callback
            (cond ((null index) nil)
                  ((< index (length cmacs-deixis-ask-menu))
                   (nth index cmacs-deixis-ask-menu))
                  (t (cmacs-gowl-ai-field--read-instruction
                      "Ask about that"))))))
      (let ((answer (string-trim
                     (completing-read "Ask about that: " cmacs-deixis-ask-menu
                                      nil nil nil 'cmacs-deixis-ask-history))))
        (funcall callback (and (not (string-empty-p answer)) answer))))))

;;;###autoload
(defun cmacs-deixis-ask-referent (referent &optional question)
  "Ask QUESTION about REFERENT, a referent plist; read QUESTION when nil.
The privacy gate is asked before the question is read, so a refused
thing costs no typing."
  (let ((why (cmacs-deixis-ask-refusal referent)))
    (if why
        (cmacs-deixis-ask--say nil "%s" why)
      (cl-flet ((go (q)
                  (when q
                    (cmacs-deixis-ask-run
                     q (list referent)
                     :scopes (list (cmacs-deixis-ask--question-scope q))))))
        (if question
            (go question)
          (cmacs-deixis-ask--read-question referent #'go))))))

;;;###autoload
(defun cmacs-deixis-ask-at-pointer (&optional question)
  "Ask a model about what the pointer is on now.
No voice involved: bind it to a key (in Emacs, or in the compositor so
it works over any window).  What \"that\" is follows
`cmacs-deixis-referent-now': the active region, else what the mouse is
on -- a place in a buffer, a web page, another program's window -- else
point.  QUESTION is read when nil: from a menu card over another
program's window, from the minibuffer in Emacs.  The answer streams
into the `cmacs-ai-output' window, where \\<cmacs-ai-output-mode-map>\
\\[cmacs-ai-output-send-followup] follows up and \
\\[cmacs-ai-output-promote-to-chat] makes it a chat."
  (interactive)
  (let ((referent (cmacs-deixis-referent-now)))
    (if (null referent)
        (cmacs-deixis-ask--say nil "Nothing is being pointed at.")
      (cmacs-deixis-ask-referent referent question))))


;;;; The AI right-click menu

(defun cmacs-deixis-ask--target-referent (target)
  "A referent for TARGET, a `cmacs-ai-target' from the AI menu.
The menu has been opened by then, so the pointer is on a menu row: the
thing is where the click was, which is what TARGET was resolved from."
  (let* ((buffer (or (and target (cmacs-ai-target-buffer target))
                     (current-buffer)))
         (bounds (and target (cmacs-ai-target-bounds target)))
         (window (get-buffer-window buffer)))
    (if (and bounds (eq (and target (cmacs-ai-target-kind target)) 'region))
        (list :kind 'region :buffer buffer :window window
              :beg (car bounds) :end (cdr bounds) :confidence 1.0)
      (list :kind 'buffer-position :buffer buffer :window window
            :position (or (car-safe bounds)
                          (with-current-buffer buffer (point)))
            :confidence 1.0))))

;;;###autoload
(defun cmacs-deixis-ask-register-menu ()
  "Add \"Ask about this...\" to the AI menu's Ask group.
Through `cmacs-ai-register-action', the menu's own extension point, so
it is in the right-click menu, the `C-c a' transient and
`cmacs-ai-run-action' alike."
  (when (fboundp 'cmacs-ai-register-action)
    (cmacs-ai-register-action
     :name 'deixis-ask
     :label "Ask about this..."
     :group 'ask
     :order 15
     :help "Ask a question about the thing here: the function, error, \
subtree or paragraph, with its diagnostics"
     :run (lambda (target)
            (cmacs-deixis-ask-referent
             (cmacs-deixis-ask--target-referent target))))))

;;;###autoload
(with-eval-after-load 'cmacs-ai-actions
  (cmacs-deixis-ask-register-menu))

(provide 'cmacs-deixis-ask)

;;; cmacs-deixis-ask.el ends here
