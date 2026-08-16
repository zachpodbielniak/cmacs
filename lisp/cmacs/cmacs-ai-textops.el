;;; cmacs-ai-textops.el --- Summarize, rephrase and reply  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three things you want to do to a piece of highlighted text often
;; enough that they deserve to be one gesture away:
;;
;;   summarize   what does this say?
;;   rephrase    say this better
;;   reply       write an answer to this
;;
;; Each asks one optional question in the minibuffer -- what to focus on,
;; what tone, what you actually want to say -- and each treats RET on an
;; empty answer as "use your judgement", because most of the time you do
;; not have a refinement in mind and being forced to invent one is worse
;; than the default.  The history is per-operation, so the refinement you
;; used last time is one `M-p' away.
;;
;; Output streams into a `cmacs-ai-output' window rather than touching
;; your buffer.  None of these three should ever modify what you were
;; reading: summarize and reply obviously produce something new, and
;; rephrase deliberately shows you the rewrite instead of applying it --
;; if you want the in-place version, that is `cmacs-ai-rewrite-region',
;; which has always been a different command with different consequences.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-output)

(declare-function cmacs-ai--ensure "cmacs-ai" ())
(declare-function cmacs-ai-make-session "cmacs-ai"
                  (&optional provider model system-prompt))
(declare-function cmacs-ai-chat-stream "cmacs-ai-stream.c"
                  (session prompt callback))

(defgroup cmacs-ai-textops nil
  "Summarize, rephrase and reply actions for cmacs-ai."
  :group 'cmacs
  :prefix "cmacs-ai-")

(defcustom cmacs-ai-textops-provider 'claude-code
  "Provider symbol used by summarize/rephrase/reply.

A SYMBOL, not a string -- `cmacs-ai-client-new' checks for one.  nil
falls back to `cmacs-ai-default-provider'.

Defaults to `claude-code' rather than to the cmacs-ai default (`claude'),
because these run off a right-click.  The HTTP providers need an API key
in the environment, so a fresh session with no key set answers a menu
click with an unexplained HTTP 401; the CLI providers reuse the
subscription auth the `claude' binary already holds, and cost nothing per
call.  `cmacs-ai-completion-provider' defaults the same way for the same
reason."
  :type '(choice (const :tag "cmacs-ai default" nil)
                 (const claude) (const openai) (const gemini)
                 (const grok) (const ollama)
                 (const claude-code) (const opencode) (const claude-tmux)
                 (const grok-build)))

(defcustom cmacs-ai-textops-model "sonnet"
  "Model string used by summarize/rephrase/reply.

nil means the provider's own default.  These are short, latency-sensitive
calls, so the mid-tier model is the right trade: summarizing a region or
drafting a reply does not need a frontier model, and you are waiting on
the answer."
  :type '(choice (const :tag "Provider default" nil) string))

;;;; The three operations ----------------------------------------------
;;
;; Each system prompt is a defcustom because the right answer is a matter
;; of taste, and taste is exactly the thing that should not require
;; editing the source to change.

(defcustom cmacs-ai-summarize-system-prompt
  "You summarize text for an expert reader who is short on time.
Lead with a one-line answer to \"what is this?\", then the substance as a
short bullet list -- six bullets at the very most, one line each.  Use
Org-mode markup.  Keep specifics: names, numbers, versions, error codes,
decisions.  Drop pleasantries, hedging and restatement.  No preamble, no
closing summary of your summary."
  "System prompt for `cmacs-ai-summarize'."
  :type 'string)

(defcustom cmacs-ai-rephrase-system-prompt
  "You rewrite text so it says the same thing better.
Preserve meaning, facts, names and technical content exactly -- you are
changing how it reads, not what it claims.  Default to clearer, tighter
and more direct: cut padding, prefer plain words, keep the author's
register rather than making it formal.  Match the source format (prose
stays prose, a bullet list stays a bullet list, code comments stay
comments).  Output ONLY the rewritten text: no preamble, no notes on
what you changed, no fences unless the source had them."
  "System prompt for `cmacs-ai-rephrase'."
  :type 'string)

(defcustom cmacs-ai-reply-system-prompt
  "You draft a reply to the text you are given, in the author's voice.
The reply is a draft for a human to send, so: answer what was actually
asked, be direct, do not invent facts or commitments you were not given,
and mark anything you had to assume with a bracketed [?] the writer can
resolve.  Match the medium -- an email gets an email, a chat message gets
a chat message, a code review comment gets a code review comment.  No
preamble, no sign-off boilerplate beyond what the medium needs.  Output
ONLY the reply text."
  "System prompt for `cmacs-ai-reply'."
  :type 'string)

(defcustom cmacs-ai-explain-system-prompt
  "You explain things to an expert colleague who has not seen this
particular code, message or document before.  Assume fluency in the
language and the domain; spend your words on intent, consequences and
the parts that would surprise a careful reader, not on narrating syntax.
Use Org-mode markup, be concise, and say plainly when something looks
wrong."
  "System prompt for `cmacs-ai-explain'."
  :type 'string)

(defcustom cmacs-ai-ask-system-prompt
  "You answer questions about the text you are given.
Answer from the text; when it does not contain the answer, say so rather
than filling the gap.  Use Org-mode markup.  Be direct and brief -- lead
with the answer, then only as much support as it needs."
  "System prompt for `cmacs-ai-ask'."
  :type 'string)

(defvar cmacs-ai-textops--specs
  '((summarize
     :title "summarize"
     :system cmacs-ai-summarize-system-prompt
     :read "Summarize -- focus on (RET for a general summary): "
     :history cmacs-ai-textops--summarize-history
     :instruction "Summarize the following."
     :default "Summarize it for someone who has not seen it before.")
    (rephrase
     :title "rephrase"
     :system cmacs-ai-rephrase-system-prompt
     :read "Rephrase -- how? (RET for clearer and tighter): "
     :history cmacs-ai-textops--rephrase-history
     :instruction "Rephrase the following."
     :default "Make it clearer, tighter and more direct.")
    (reply
     :title "reply"
     :system cmacs-ai-reply-system-prompt
     :read "Reply -- what do you want to say? (RET to draft one): "
     :history cmacs-ai-textops--reply-history
     :instruction "Draft a reply to the following."
     :default "Draft the reply you judge most appropriate.")
    ;; The same machinery, for the two things the old region-only menu
    ;; offered.  Routing them through here means one prompt style, one
    ;; result window and one cancel path for everything in the Ask group.
    (explain
     :title "explain"
     :system cmacs-ai-explain-system-prompt
     :read "Explain -- focus on (RET for the non-obvious parts): "
     :history cmacs-ai-textops--explain-history
     :instruction "Explain the following."
     :default "Explain what it does and why, concentrating on what is not obvious.")
    (ask
     :title "ask"
     :system cmacs-ai-ask-system-prompt
     :read "Ask about this: "
     :history cmacs-ai-textops--ask-history
     :instruction "Answer a question about the following."
     :default "What is the most useful thing to know about this?"))
  "Specifications for the three text operations.

Each entry is (NAME . PLIST).  :system names the defcustom holding the
system prompt (indirected, so customising it takes effect immediately
rather than at load time); :read is the minibuffer prompt; :default is
what an empty answer means; :history names the per-operation history
variable.")

(defvar cmacs-ai-textops--summarize-history nil)
(defvar cmacs-ai-textops--rephrase-history nil)
(defvar cmacs-ai-textops--reply-history nil)
(defvar cmacs-ai-textops--explain-history nil)
(defvar cmacs-ai-textops--ask-history nil)

(defun cmacs-ai-textops--spec (op)
  "The specification plist for OP, or signal."
  (or (alist-get op cmacs-ai-textops--specs)
      (error "cmacs-ai: unknown text operation %s" op)))

(defun cmacs-ai-textops-read-refinement (op)
  "Ask how to perform OP, returning the refinement string.

An empty answer is not an error and not a re-prompt: it means the
operation's default, which is the common case."
  (let* ((spec (cmacs-ai-textops--spec op))
         (hist (plist-get spec :history))
         (answer (read-string (plist-get spec :read) nil hist)))
    (if (string-empty-p (string-trim answer))
        (plist-get spec :default)
      (string-trim answer))))

;;;; Running -----------------------------------------------------------

(defun cmacs-ai-textops--prompt (spec target refinement)
  "The user-message text for SPEC over TARGET with REFINEMENT."
  (format "%s\n\nHow: %s\n\nThe text (%s):\n\n%s"
          (plist-get spec :instruction)
          refinement
          (cmacs-ai-target-describe target)
          (or (cmacs-ai-target-content target) "")))

;;;###autoload
(defun cmacs-ai-textops-run (op target &optional refinement)
  "Run text operation OP over TARGET and stream the result to a window.

OP is `summarize\=', `rephrase\=', `reply\=', `explain\=' or `ask\='.  REFINEMENT
is the free-text instruction; when omitted it is read from the
minibuffer.  Returns the result buffer."
  (unless (cmacs-ai-target-p target)
    (user-error "cmacs-ai: nothing here to %s" op))
  (let* ((spec (cmacs-ai-textops--spec op))
         (refinement (or refinement (cmacs-ai-textops-read-refinement op)))
         (content (cmacs-ai-target-content target)))
    (when (or (null content) (string-empty-p (string-trim content)))
      (user-error "cmacs-ai: no text to %s here" op))
    (cmacs-ai-textops-stream
     (plist-get spec :title)
     (format "%s -- %s" (cmacs-ai-target-describe target) refinement)
     ;; The system prompt is read through its symbol so a `setq\=' or a
     ;; customise between calls is honoured.
     (symbol-value (plist-get spec :system))
     (cmacs-ai-textops--prompt spec target refinement)
     (lambda () (cmacs-ai-textops-run op target refinement)))))

;;;###autoload
(defun cmacs-ai-textops-stream (title subtitle system prompt &optional retry)
  "Stream SYSTEM/PROMPT into a result window called TITLE.

The plumbing every AI action that produces prose shares: make a session,
open the window, append the deltas, settle the non-streaming case, free
the session.  SUBTITLE says what produced it; RETRY, a thunk, is what
`g\=' in the window re-runs.  Returns the result buffer.

Public because it is the way to add an action that answers in prose
without writing this loop again."
  ;; cmacs-ai\='s Elisp loads lazily, and the menu can be the first thing in
  ;; a session that needs it.
  (require 'cmacs-ai)
  (cmacs-ai--ensure)
  (let* ((buf (cmacs-ai-output-buffer title subtitle))
         (pair (cmacs-ai-make-session cmacs-ai-textops-provider
                                      cmacs-ai-textops-model
                                      system))
         (streamed 0))
    (cmacs-ai-output-attach-session buf pair)
    (when retry
      (cmacs-ai-output-set-retry buf (lambda () (interactive) (funcall retry))))
    (cmacs-ai-output-show buf)
    (cmacs-ai-chat-stream
     (cdr pair) prompt
     (lambda (payload)
       (pcase (car-safe payload)
         (:start nil)
         (:delta
          (let ((chunk (cadr payload)))
            (when chunk
              (setq streamed (+ streamed (length chunk)))
              (cmacs-ai-output-append buf chunk))))
         (:tool-use nil)
         (:end
          ;; Providers that do not stream deliver everything here.  Only
          ;; use it when nothing arrived incrementally, so a streaming
          ;; provider does not get its answer printed twice.
          (let ((final (plist-get (cdr payload) :text)))
            (when (and final (zerop streamed))
              (cmacs-ai-output-append buf final)))
          (cmacs-ai-output-finish buf nil))
         (:error
          (cmacs-ai-output-finish buf (or (cadr payload) "stream error"))))))
    buf))

;;;; Interactive commands ----------------------------------------------

(defun cmacs-ai-textops--target ()
  "The target for an interactive text operation.
Resolves at point, which -- because the region resolver runs first --
means the highlighted text whenever there is any."
  (or (cmacs-ai-target-at)
      (user-error "cmacs-ai: nothing here to act on")))

;;;###autoload
(defun cmacs-ai-summarize (&optional refinement)
  "Summarize the region, or whatever is at point, in a result window.
REFINEMENT is read from the minibuffer; RET accepts the default."
  (interactive (list (cmacs-ai-textops-read-refinement 'summarize)))
  (cmacs-ai-textops-run 'summarize (cmacs-ai-textops--target) refinement))

;;;###autoload
(defun cmacs-ai-rephrase (&optional refinement)
  "Rephrase the region, or whatever is at point, in a result window.
The buffer is not modified -- use `cmacs-ai-rewrite-region' for that.
REFINEMENT is read from the minibuffer; RET accepts the default."
  (interactive (list (cmacs-ai-textops-read-refinement 'rephrase)))
  (cmacs-ai-textops-run 'rephrase (cmacs-ai-textops--target) refinement))

;;;###autoload
(defun cmacs-ai-reply (&optional refinement)
  "Draft a reply to the region, or whatever is at point.
REFINEMENT is read from the minibuffer; RET accepts the default."
  (interactive (list (cmacs-ai-textops-read-refinement 'reply)))
  (cmacs-ai-textops-run 'reply (cmacs-ai-textops--target) refinement))

;;;###autoload
(defun cmacs-ai-explain (&optional refinement)
  "Explain the region, or whatever is at point, in a result window.
Unlike `cmacs-ai-explain-region' this works on every surface the target
resolvers understand -- a diff hunk, a diagnostic, a terminal's last
command -- not only on an active region."
  (interactive (list (cmacs-ai-textops-read-refinement 'explain)))
  (cmacs-ai-textops-run 'explain (cmacs-ai-textops--target) refinement))

;;;###autoload
(defun cmacs-ai-ask (&optional question)
  "Ask a QUESTION about the region, or whatever is at point."
  (interactive (list (cmacs-ai-textops-read-refinement 'ask)))
  (cmacs-ai-textops-run 'ask (cmacs-ai-textops--target) question))

(provide 'cmacs-ai-textops)

;;; cmacs-ai-textops.el ends here
