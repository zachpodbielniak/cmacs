;;; cmacs-ai-notes.el --- AI actions for org notes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; A Notes group, on org headings and roamgraph nodes.
;;
;; This is the group where cmacs has leverage nothing general-purpose
;; does.  ai-brigade already maintains a similarity index over the notes
;; repository, and roamgraph already holds the link graph, so the
;; questions worth asking here are the ones that need the OTHER notes:
;; what does this connect to, what does it contradict, what is missing.
;; A model looking at one note in isolation cannot answer any of them.
;;
;; So every action here retrieves before it prompts.  The note's text
;; goes to `cmacs-brigade-memory-search', and the neighbours it returns
;; are handed to the model alongside the note.  Where the index has not
;; been built, the actions say so rather than quietly degrading into a
;; worse version of "summarize", which would look like it worked.
;;
;; Nothing here writes to your notes.  Suggestions arrive as text; you
;; decide what goes in.  This is a second brain, and the failure mode of
;; an eager assistant editing it is not one you would notice quickly.

;;; Code:

(require 'cmacs-ai-target)
(require 'cmacs-ai-textops)
(require 'cmacs-ai-actions)

(declare-function cmacs-brigade-memory-search "cmacs-brigade-memory"
                  (query &optional k))
(declare-function cmacs-brigade-memory-build "cmacs-brigade-memory"
                  (&optional force))
(declare-function cmacs-roamgraph-neighbors "cmacs-roamgraph"
                  (buffer id direction))
(declare-function cmacs-roamgraph--title "cmacs-roamgraph" (id))

(defgroup cmacs-ai-notes nil
  "AI actions for org notes and the roamgraph."
  :group 'cmacs-ai
  :prefix "cmacs-ai-notes-")

(defcustom cmacs-ai-notes-neighbours 8
  "How many related notes are retrieved as context.

Enough for the model to see a pattern, few enough that the prompt stays
about the note in front of you rather than becoming a survey of the
whole repository."
  :type 'integer
  :safe #'integerp)

;;;; System prompts ------------------------------------------------------

(defcustom cmacs-ai-notes-links-system-prompt
  "You suggest connections between a note and the rest of a personal
knowledge base.  Use Org-mode markup.

You are given one note and several others retrieved as similar.
Similarity is not a reason to link: say which of them are worth an
actual link and WHY -- what the reader would gain by following it.  One
line each, best first, naming the note.

Reject the rest explicitly, in a single closing line, rather than
padding the list.  Three good links are worth more than eight plausible
ones, and a knowledge base ruined by indiscriminate linking is a common
way to lose one."
  "System prompt for `cmacs-ai-notes-links'."
  :type 'string)

(defcustom cmacs-ai-notes-contradict-system-prompt
  "You look for tension between a note and others from the same
knowledge base.  Use Org-mode markup.

Report only real disagreements: a claim stated one way here and another
way there, a decision that was later reversed, a number or date that
does not match, advice that has since been contradicted.  Quote both
sides briefly and name the notes.

Restating the same idea in different words is NOT a contradiction.
Being about the same topic is not either.  If you find nothing genuine,
say exactly that in one line and stop -- inventing tension to look
useful would send the reader to rewrite notes that were already right."
  "System prompt for `cmacs-ai-notes-contradict'."
  :type 'string)

(defcustom cmacs-ai-notes-expand-system-prompt
  "You help develop a thin note in a personal knowledge base.
Use Org-mode markup, matching the note's existing structure and voice.

Output the questions the note leaves unanswered, and an outline of what
a fuller version would cover -- headings and one-line descriptions, not
finished prose.  Where the related notes supply something the stub
plainly wants, point at it by name.

Do NOT write the note.  You do not know what the author thinks, and a
knowledge base filled with confident text nobody actually reasoned
through is worse than a short honest one.  Prompt them; do not
ghostwrite."
  "System prompt for `cmacs-ai-notes-expand'."
  :type 'string)

;;;; Applicability -------------------------------------------------------

(defun cmacs-ai-notes--target-p (target)
  "Non-nil when TARGET is a note of some kind."
  (memq (cmacs-ai-target-kind target) '(org-node roam-node)))

(defun cmacs-ai-notes--available-p (target)
  "Non-nil when the Notes actions apply to TARGET."
  (and (cmacs-ai-actions--ai-p) (cmacs-ai-notes--target-p target)))

(defun cmacs-ai-notes--corpus-available-p ()
  "Non-nil when the brigade memory index is loadable.

Deliberately only a library check -- whether the index has actually been
BUILT is not knowable cheaply, and a menu must not go to disk to decide
whether to show an item.  An unbuilt index is reported when the action
runs."
  (cmacs-ai-actions--library-p 'cmacs-brigade-memory))

;;;; Retrieval -----------------------------------------------------------

(defun cmacs-ai-notes--related (text)
  "Notes related to TEXT, as a list of plists, or nil.

Returns nil rather than signalling when the index is missing or has
never been built: the caller turns that into an honest message."
  (when (cmacs-ai-notes--corpus-available-p)
    (require 'cmacs-brigade-memory)
    (ignore-errors
      (cmacs-brigade-memory-search
       ;; The query is the note itself.  Truncated hard: an embedding of
       ;; a whole long note is a blur, and the opening of a note is
       ;; usually what it is actually about.
       (substring text 0 (min (length text) 2000))
       cmacs-ai-notes-neighbours))))

(defun cmacs-ai-notes--render-related (related)
  "RELATED rendered for a prompt."
  (mapconcat
   (lambda (r)
     (format "** %s\n%s\n"
             (or (plist-get r :display) (plist-get r :path) "?")
             (string-trim (or (plist-get r :text) ""))))
   related "\n"))

(defun cmacs-ai-notes--run (title system target)
  "Stream SYSTEM over TARGET plus its neighbours into a window called TITLE."
  (let* ((content (or (cmacs-ai-target-content target) ""))
         (related (cmacs-ai-notes--related content)))
    (when (string-empty-p (string-trim content))
      (user-error "cmacs-ai: this note is empty"))
    (unless related
      (user-error
       "cmacs-ai: no memory index -- run M-x cmacs-brigade-memory-build first"))
    (cmacs-ai-textops-stream
     title
     (format "%s (+%d related)"
             (cmacs-ai-target-describe target) (length related))
     system
     (format "* The note in front of me\n%s\n\n* Related notes from the same knowledge base\n%s"
             content (cmacs-ai-notes--render-related related))
     (lambda () (cmacs-ai-notes--run title system target)))))

;;;; Commands ------------------------------------------------------------

(defun cmacs-ai-notes--target ()
  "The note at point, or signal."
  (let ((target (cmacs-ai-target-at)))
    (unless (and target (cmacs-ai-notes--target-p target))
      (user-error "cmacs-ai: not on an org heading or a roamgraph node"))
    target))

;;;###autoload
(defun cmacs-ai-notes-links ()
  "Suggest which related notes this one is worth linking to."
  (interactive)
  (cmacs-ai-notes--run "links" cmacs-ai-notes-links-system-prompt
                       (cmacs-ai-notes--target)))

;;;###autoload
(defun cmacs-ai-notes-contradict ()
  "Look for notes that disagree with this one."
  (interactive)
  (cmacs-ai-notes--run "contradictions"
                       cmacs-ai-notes-contradict-system-prompt
                       (cmacs-ai-notes--target)))

;;;###autoload
(defun cmacs-ai-notes-expand ()
  "Ask what this stub of a note is missing."
  (interactive)
  (cmacs-ai-notes--run "expand" cmacs-ai-notes-expand-system-prompt
                       (cmacs-ai-notes--target)))

;;;; Menu actions --------------------------------------------------------

(cmacs-ai-register-action
 :name 'cmacs-ai-notes-links
 :group 'notes :order 10
 :label "Suggest links"
 :help "Which related notes are worth linking, and why"
 :applies (lambda (target)
            (and (cmacs-ai-notes--available-p target)
                 (cmacs-ai-notes--corpus-available-p)))
 :run (lambda (target)
        (cmacs-ai-notes--run "links"
                             cmacs-ai-notes-links-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-notes-contradict
 :group 'notes :order 20
 :label "What does this contradict?"
 :help "Real disagreements with other notes, not similar topics"
 :applies (lambda (target)
            (and (cmacs-ai-notes--available-p target)
                 (cmacs-ai-notes--corpus-available-p)))
 :run (lambda (target)
        (cmacs-ai-notes--run "contradictions"
                             cmacs-ai-notes-contradict-system-prompt target)))

(cmacs-ai-register-action
 :name 'cmacs-ai-notes-expand
 :group 'notes :order 30
 :label "What is this note missing?"
 :help "Questions and an outline -- it will not write the note for you"
 :applies (lambda (target)
            (and (cmacs-ai-notes--available-p target)
                 (cmacs-ai-notes--corpus-available-p)))
 :run (lambda (target)
        (cmacs-ai-notes--run "expand"
                             cmacs-ai-notes-expand-system-prompt target)))

(provide 'cmacs-ai-notes)

;;; cmacs-ai-notes.el ends here
