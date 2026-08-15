;;; cmacs-ai-mail.el --- AI actions for mail buffers  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A Mail group on the AI menu, present only in mail buffers.
;;
;; Mail is the one place where the useful questions are not "explain
;; this" or "rephrase that" but things a general-purpose menu has no
;; vocabulary for: what arrived, what actually wants me, what can be
;; deleted unread, what did I agree to.  So it gets its own group rather
;; than more entries under Ask AI.
;;
;; The group is empty outside mail, and an empty group is omitted, so it
;; costs nothing anywhere else.
;;
;; Everything here reads the messages themselves, not the header table --
;; a `mail-folder' target carries a thunk that pulls the bodies off the
;; maildir when an action runs (see cmacs-ai-targets.el).  In a view
;; buffer the message is already there.
;;
;; Where ai-brigade's GenMail is compiled in, its triage and briefing are
;; offered too rather than reimplemented: GenMail keeps state, buckets
;; and an actionable report, and a menu entry that pretended to do the
;; same thing with one prompt would be a worse version of it.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-actions)

(declare-function cmacs-brigade-genmail-triage "cmacs-brigade-genmail"
                  (&optional limit force))
(declare-function cmacs-brigade-genmail-briefing "cmacs-brigade-genmail" ())
(declare-function mu4e-headers-mark-for-refile "mu4e-mark" ())

(defgroup cmacs-ai-mail nil
  "AI actions for mail buffers."
  :group 'cmacs-ai
  :prefix "cmacs-ai-mail-")

;;;; System prompts ------------------------------------------------------
;;
;; defcustoms, like the text operations: what makes a good inbox digest
;; is a matter of how you work, and that should not need a recompile.

(defcustom cmacs-ai-mail-digest-system-prompt
  "You summarize a mailbox for someone who has been away from it.
Use Org-mode markup.  Group the messages by what they want from the
reader, most demanding first, with these headings -- omit any that are
empty:

* Needs a reply
* Needs a decision or an action (no reply required)
* Worth reading
* Bulk and noise

Under each, one line per message: who it is from, what it wants, and any
date or figure that matters.  Name senders and subjects so a line can be
found again.  Do not invent urgency the message does not have, and do
not pad: a quiet inbox should produce a short answer."
  "System prompt for `cmacs-ai-mail-digest'."
  :type 'string)

(defcustom cmacs-ai-mail-attention-system-prompt
  "You find what in a mailbox actually requires the reader to act.
Use Org-mode markup.  Output ONLY things with a real claim on them: a
question addressed to them, a deadline, a payment, an approval, a
commitment someone is waiting on, an account or security problem.

One line each, most time-critical first: who, what is needed, and by
when if a date is given.  End with a single line naming the one thing to
do first.

If nothing in the mailbox genuinely requires action, say exactly that
and stop.  Do not manufacture tasks out of newsletters and receipts --
being wrong in that direction wastes the reader's day."
  "System prompt for `cmacs-ai-mail-attention'."
  :type 'string)

(defcustom cmacs-ai-mail-unsubscribe-system-prompt
  "You identify bulk mail a reader could stop receiving.
Use Org-mode markup.  List senders whose mail is promotional,
newsletters, notification digests or automated marketing -- anything
carrying List-Unsubscribe is a strong hint, but judge the content too.

One line per sender: the sender, roughly how much of the mailbox is
theirs, and whether it looks safe to unsubscribe (transactional mail
from a bank or a service you pay for is NOT safe to drop, even when it
is automated).  Say plainly which ones you are unsure about."
  "System prompt for `cmacs-ai-mail-unsubscribe'."
  :type 'string)

(defcustom cmacs-ai-mail-thread-system-prompt
  "You summarize an email thread for someone joining it late.
Use Org-mode markup.  Lead with one line saying what the thread is
about and where it stands.  Then: what was decided, what is still open,
and who owes whom what.  Name people.  Keep dates and figures exact.
Ignore quoted history, signatures and disclaimers."
  "System prompt for `cmacs-ai-mail-thread'."
  :type 'string)

;;;; Targets -------------------------------------------------------------

(defun cmacs-ai-mail--target-p (target)
  "Non-nil when TARGET is mail of some kind."
  (memq (cmacs-ai-target-kind target) '(mail mail-folder)))

(defun cmacs-ai-mail--folder-p (target)
  "Non-nil when TARGET is a whole folder listing."
  (eq (cmacs-ai-target-kind target) 'mail-folder))

(defun cmacs-ai-mail--available-p (target)
  "Non-nil when the mail actions apply to TARGET."
  (and (cmacs-ai-actions--ai-p) (cmacs-ai-mail--target-p target)))

(defun cmacs-ai-mail--run (title system target)
  "Stream SYSTEM over TARGET's messages into a result window called TITLE."
  (let ((content (cmacs-ai-target-content target)))
    (when (or (null content) (string-empty-p (string-trim content)))
      (user-error "cmacs-ai: no mail here to read"))
    (cmacs-ai-textops-stream
     title
     (cmacs-ai-target-describe target)
     system
     (format "%s\n\n%s"
             (if (cmacs-ai-mail--folder-p target)
                 "The messages in this mail folder:"
               "This message:")
             content)
     (lambda () (cmacs-ai-mail--run title system target)))))

;;;; Commands ------------------------------------------------------------
;;
;; Named commands as well as menu entries, so they can be bound.  Each
;; resolves the target at point, which in a mu4e headers buffer is the
;; whole folder and in a view buffer is the message.

(defun cmacs-ai-mail--target ()
  "The mail target at point, or signal."
  (let ((target (cmacs-ai-target-at)))
    (unless (and target (cmacs-ai-mail--target-p target))
      (user-error "cmacs-ai: not in a mail buffer"))
    target))

;;;###autoload
(defun cmacs-ai-mail-digest ()
  "Read every message in this folder and summarize what arrived.

Reads the message bodies off the maildir, not the header table, bounded
by `cmacs-ai-target-mail-max-messages'."
  (interactive)
  (cmacs-ai-mail--run "inbox digest"
                      cmacs-ai-mail-digest-system-prompt
                      (cmacs-ai-mail--target)))

;;;###autoload
(defun cmacs-ai-mail-attention ()
  "List only what in this folder actually needs you to do something."
  (interactive)
  (cmacs-ai-mail--run "needs attention"
                      cmacs-ai-mail-attention-system-prompt
                      (cmacs-ai-mail--target)))

;;;###autoload
(defun cmacs-ai-mail-unsubscribe-candidates ()
  "List bulk senders in this folder that could be unsubscribed from."
  (interactive)
  (cmacs-ai-mail--run "unsubscribe candidates"
                      cmacs-ai-mail-unsubscribe-system-prompt
                      (cmacs-ai-mail--target)))

;;;###autoload
(defun cmacs-ai-mail-thread-summary ()
  "Summarize the message or thread being viewed."
  (interactive)
  (cmacs-ai-mail--run "thread"
                      cmacs-ai-mail-thread-system-prompt
                      (cmacs-ai-mail--target)))

;;;###autoload
(defun cmacs-ai-mail-ask (question)
  "Ask a QUESTION about the mail in this buffer.

Goes through the generic `ask' operation so the question actually
reaches the prompt -- the mail runner takes a system prompt and a
target, and has nowhere to put one."
  (interactive "sAsk about this mail: ")
  (cmacs-ai-textops-run 'ask (cmacs-ai-mail--target) question))

;;;; Menu actions --------------------------------------------------------

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-digest
 :group 'mail :order 10
 :label (lambda (target)
          (if (cmacs-ai-mail--folder-p target)
              "Read and summarize this folder"
            "Summarize this message"))
 :help "Read the messages themselves, not just the subject lines"
 :applies #'cmacs-ai-mail--available-p
 :run (lambda (target)
        (if (cmacs-ai-mail--folder-p target)
            (cmacs-ai-mail--run "inbox digest"
                                cmacs-ai-mail-digest-system-prompt target)
          (cmacs-ai-mail--run "thread"
                              cmacs-ai-mail-thread-system-prompt target))))

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-attention
 :group 'mail :order 20
 :label "What needs my attention?"
 :help "Only the messages with a real claim on you"
 :applies #'cmacs-ai-mail--available-p
 :run (lambda (target)
        (cmacs-ai-mail--run "needs attention"
                            cmacs-ai-mail-attention-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-reply
 :group 'mail :order 30
 :label "Draft a reply..."
 :help "Draft a reply to this message, in your voice"
 :applies (lambda (target)
            (and (cmacs-ai-mail--available-p target)
                 (not (cmacs-ai-mail--folder-p target))))
 :run (lambda (target) (cmacs-ai-textops-run 'reply target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-unsubscribe
 :group 'mail :order 40
 :label "What could I unsubscribe from?"
 :applies (lambda (target)
            (and (cmacs-ai-mail--available-p target)
                 (cmacs-ai-mail--folder-p target)))
 :run (lambda (target)
        (cmacs-ai-mail--run "unsubscribe candidates"
                            cmacs-ai-mail-unsubscribe-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-ask
 :group 'mail :order 50
 :label "Ask about this mail..."
 :applies #'cmacs-ai-mail--available-p
 :run (lambda (target) (cmacs-ai-textops-run 'ask target)))

;; GenMail, when it is compiled in.  Offered rather than reimplemented:
;; it keeps buckets, state and an actionable report with buttons, and a
;; one-prompt imitation would be strictly worse.

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-genmail-triage
 :group 'mail :order 60
 :label "Triage (GenMail)"
 :help "Classify the inbox into buckets with recommended actions"
 :applies (lambda (target)
            (and (cmacs-ai-mail--available-p target)
                 (cmacs-ai-actions--library-p 'cmacs-brigade-genmail)))
 :run (lambda (_target)
        (require 'cmacs-brigade-genmail)
        (call-interactively #'cmacs-brigade-genmail-triage)))

(cmacs-ai-register-action
 :name 'cmacs-ai-mail-genmail-briefing
 :group 'mail :order 70
 :label "Briefing (GenMail)"
 :applies (lambda (target)
            (and (cmacs-ai-mail--available-p target)
                 (cmacs-ai-actions--library-p 'cmacs-brigade-genmail)))
 :run (lambda (_target)
        (require 'cmacs-brigade-genmail)
        (cmacs-brigade-genmail-briefing)))

(provide 'cmacs-ai-mail)

;;; cmacs-ai-mail.el ends here
