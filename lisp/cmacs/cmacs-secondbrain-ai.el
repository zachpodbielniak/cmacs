;;; cmacs-secondbrain-ai.el --- AI actions on second-brain nodes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Right-click actions that answer a question about whatever you clicked.
;;
;; These register through `cmacs-ai-register-action', so they appear in
;; the shared AI menu -- in the graph's own context menu, in `M-x
;; cmacs-ai-act-on-target', and anywhere else that menu is built -- rather
;; than being a private menu this subsystem owns.  All of them answer
;; through `cmacs-ai-textops-stream', which is the documented way to add
;; an action that replies in prose: it opens the output window, streams
;; deltas, and keeps the session so `C-c C-c' continues the conversation
;; and `g' retries.
;;
;; The questions are chosen to be the ones the rings make askable and a
;; file browser does not.  "What would break if I disconnected this?" is
;; the trust question the Applications ring exists for; "what is stale
;; here?" is the one the Routines ring exists for.

;;; Code:

(require 'cl-lib)

(declare-function cmacs-ai-register-action "cmacs-ai-actions")
(declare-function cmacs-ai-target-content "cmacs-ai-target")
(declare-function cmacs-ai-target-describe "cmacs-ai-target")
(declare-function cmacs-ai-target-plist-get "cmacs-ai-target")
(declare-function cmacs-ai-target-kind "cmacs-ai-target")
(declare-function cmacs-ai-textops-stream "cmacs-ai-textops")
(declare-function cmacs-brigade-memory-search "cmacs-brigade-memory")

(defun cmacs-secondbrain-ai--brain-node-p (target)
  "Return non-nil when TARGET is a second-brain node."
  (and target
       (fboundp 'cmacs-ai-target-kind)
       (eq (cmacs-ai-target-kind target) 'brain-node)))

(defun cmacs-secondbrain-ai--ring-is (target ring)
  "Return non-nil when TARGET sits in RING."
  (and (cmacs-secondbrain-ai--brain-node-p target)
       (eq (cmacs-ai-target-plist-get target :ring) ring)))

(defun cmacs-secondbrain-ai--context (target)
  "Return a short description of TARGET plus its content, for a prompt."
  (let* ((title (or (cmacs-ai-target-plist-get target :title) "this node"))
         (kind  (cmacs-ai-target-plist-get target :kind))
         (ring  (cmacs-ai-target-plist-get target :ring))
         (dept  (cmacs-ai-target-plist-get target :department))
         (body  (ignore-errors (cmacs-ai-target-content target))))
    (concat (format "Node: %s\nRole: %s\nARMS ring: %s\n" title kind ring)
            (if dept (format "Department: %s\n" dept) "")
            (if (and body (not (string-empty-p body)))
                (format "\n---\n%s\n---\n" body)
              "\n(No file content -- reason about it from its name and role.)\n"))))

(defun cmacs-secondbrain-ai--run (title system target)
  "Stream an answer about TARGET under SYSTEM, into a window called TITLE."
  (cmacs-ai-textops-stream
   title
   (or (cmacs-ai-target-plist-get target :title) "node")
   system
   (cmacs-secondbrain-ai--context target)))

;;;; Actions ----------------------------------------------------------

(defconst cmacs-secondbrain-ai--explain-system
  "You are looking at one node of a user's agentic second brain, which is
organised into four ARMS layers: Applications (what the agent is wired
into), Routines (what runs unattended), Memory (what has accumulated),
and Skills (what the agent can do).

Explain what this node is and what it is for, in a few sentences.  If it
is a skill, say what it does and when it would fire.  If it is a routine,
say what it automates.  Be concrete and short.  Do not pad."
  "System prompt for the explain action.")

(defconst cmacs-secondbrain-ai--breakage-system
  "You are looking at one node of a user's agentic second brain.

Answer one question: if this were removed or disconnected, what would
stop working?  Name concrete consequences, and say plainly when the
answer is \"probably nothing\" -- an honest \"this looks unused\" is the
most useful answer this question can have, because the whole point of
asking is to find things worth retiring.

Do not speculate beyond what the content supports."
  "System prompt for the impact action.")

(defconst cmacs-secondbrain-ai--stale-system
  "You are looking at one node of a user's agentic second brain.

Assess whether it looks stale: superseded, abandoned, referring to things
that no longer exist, or duplicating something else.  Say what evidence
points that way.  If it looks current, say so in one line rather than
manufacturing doubt."
  "System prompt for the staleness action.")

(defconst cmacs-secondbrain-ai--department-system
  "You are looking at one department of a user's agentic second brain,
together with a sample of what it contains.

Summarise what this department is actually about, what the main themes
are, and anything that looks out of place in it.  Be specific about what
you saw; do not describe the category in the abstract."
  "System prompt for the department summary action.")

(when (fboundp 'cmacs-ai-register-action)

  (cmacs-ai-register-action
   :name 'cmacs-secondbrain-explain
   :group 'notes :order 5
   :label (lambda (target)
            (pcase (cmacs-ai-target-plist-get target :kind)
              ('skill   "Explain this skill")
              ('routine "Explain this routine")
              ('app     "Explain this application")
              (_        "Explain this node")))
   :help "What this node is and what it is for"
   :applies #'cmacs-secondbrain-ai--brain-node-p
   :run (lambda (target)
          (cmacs-secondbrain-ai--run
           "Explain" cmacs-secondbrain-ai--explain-system target)))

  (cmacs-ai-register-action
   :name 'cmacs-secondbrain-breakage
   :group 'notes :order 6
   :label "What would break without this?"
   :help "The trust and dependency question"
   :applies #'cmacs-secondbrain-ai--brain-node-p
   :run (lambda (target)
          (cmacs-secondbrain-ai--run
           "Impact" cmacs-secondbrain-ai--breakage-system target)))

  (cmacs-ai-register-action
   :name 'cmacs-secondbrain-stale
   :group 'notes :order 7
   :label "Is this stale?"
   :help "Whether this looks superseded or abandoned"
   :applies #'cmacs-secondbrain-ai--brain-node-p
   :run (lambda (target)
          (cmacs-secondbrain-ai--run
           "Staleness" cmacs-secondbrain-ai--stale-system target)))

  (cmacs-ai-register-action
   :name 'cmacs-secondbrain-department
   :group 'notes :order 8
   :label "Summarise this department"
   :help "What this department is actually about"
   ;; Only on a hub: asking a single file to summarise its department is
   ;; a different, worse question.
   :applies (lambda (target)
              (and (cmacs-secondbrain-ai--brain-node-p target)
                   (eq (cmacs-ai-target-plist-get target :kind) 'hub)))
   :run (lambda (target)
          (cmacs-secondbrain-ai--run
           "Department" cmacs-secondbrain-ai--department-system target))))

(provide 'cmacs-secondbrain-ai)

;;; cmacs-secondbrain-ai.el ends here
