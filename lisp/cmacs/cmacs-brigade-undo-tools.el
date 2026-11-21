;;; cmacs-brigade-undo-tools.el --- action_log and action_undo  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The action log (cmacs-brigade-undo.el) as two tools, so an agent can
;; see and take back what IT did:
;;
;;   action_log   read-only.  The caller's own actions; every caller's
;;                only for an agent or task named in
;;                `cmacs-brigade-undo-log-all-callers'.  Arguments,
;;                results and reasons go through `cmacs-redact-text'.
;;   action_undo  destructive, asks (:confirm 'ask).  Undoes the
;;                caller's own actions only -- never the user's, never
;;                another agent's -- with the staleness check always on:
;;                there is no force for a tool.
;;
;; Who the caller is comes from the dispatch (`cmacs-brigade-current-call'),
;; never from an argument: a task id is the editor's own record of the
;; scoped socket or executor the call came through.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'cmacs-brigade-registry)

(declare-function cmacs-brigade-undo-log "cmacs-brigade-undo" ())
(declare-function cmacs-brigade-undo-own-p "cmacs-brigade-undo"
                  (entry &optional req))
(declare-function cmacs-brigade-undo-entry-line "cmacs-brigade-undo"
                  (entry &optional strict))
(declare-function cmacs-brigade-undo-run-list "cmacs-brigade-undo"
                  (entries &optional stop-at-irreversible))
(declare-function cmacs-brigade-action-id "cmacs-brigade-undo" (entry))
(declare-function cmacs-brigade-action-state "cmacs-brigade-undo" (entry))
(declare-function cmacs-brigade-action-agent "cmacs-brigade-undo" (entry))
(declare-function cmacs-brigade-action-task "cmacs-brigade-undo" (entry))

(defvar cmacs-brigade-current-call)
(defvar cmacs-brigade-undo-log-all-callers)

(defun cmacs-brigade-undo-tools--caller ()
  "The dispatch plist of the calling caller; signal outside a dispatch."
  (or cmacs-brigade-current-call
      (error "action tools must be called through the tool dispatch")))

(defun cmacs-brigade-undo-tools--may-see-all-p (req)
  "Non-nil when the caller REQ was granted every caller's log."
  (let ((agent (plist-get req :agent))
        (task (plist-get req :task)))
    (and (or (and agent (member agent cmacs-brigade-undo-log-all-callers))
             (and task (member (format "%s" task)
                               cmacs-brigade-undo-log-all-callers)))
         t)))

(cmacs-brigade-deftool action-log
    "List the actions (destructive tool calls) you made in this session, \
newest first, with what undoing each would do.  One line per action: \
#ID time caller tool [state] arguments -> result (undo would ...).  \
State is done, undone, irreversible, stale, failed-to-undo or \
nothing-to-undo.  Use action_undo with an ID to take one back."
    ((limit integer "Most actions to list (default 20)" :optional t)
     (all boolean "Every caller's actions, not only yours (needs a grant \
in cmacs-brigade-undo-log-all-callers)" :optional t))
  :group 'action
  :example "emacsctl tool action log --limit 5"
  (require 'cmacs-brigade-undo)
  (let* ((req (cmacs-brigade-undo-tools--caller))
         (everyone (and all
                        (or (cmacs-brigade-undo-tools--may-see-all-p req)
                            (error "Not granted: listing other callers' \
actions needs this agent named in cmacs-brigade-undo-log-all-callers"))))
         (rows (take (if (and (integerp limit) (> limit 0)) limit 20)
                     (if everyone
                         (cmacs-brigade-undo-log)
                       (cl-remove-if-not
                        (lambda (e) (cmacs-brigade-undo-own-p e req))
                        (cmacs-brigade-undo-log))))))
    (if (null rows)
        "No actions."
      (mapconcat (lambda (e) (cmacs-brigade-undo-entry-line e 'strict))
                 rows "\n"))))

(cmacs-brigade-deftool action-undo
    "Undo actions you made, by ID (see action_log) or, without an ID, \
your most recent one; with count, your last COUNT, newest first.  You \
can only undo your own actions.  An undo is refused, with the reason, \
when something changed since your action (the text you wrote was edited, \
the window you moved was moved again); a run stops at the first action \
that cannot be undone."
    ((id integer "The action to undo, from action_log" :optional t)
     (count integer "Undo your last COUNT undoable actions (ignored with \
id)" :optional t))
  :group 'action :destructive t :confirm 'ask
  ;; Nothing to record: the undo is the entries' own state change, and
  ;; an undo of an undo is not offered.
  :undo 'cmacs-brigade-undo-capture-nothing
  (require 'cmacs-brigade-undo)
  (let* ((req (cmacs-brigade-undo-tools--caller))
         (mine (cl-remove-if-not (lambda (e) (cmacs-brigade-undo-own-p e req))
                                 (cmacs-brigade-undo-log)))
         (targets
          (if (integerp id)
              (list (or (cl-find id mine :key #'cmacs-brigade-action-id)
                        ;; The same answer whether #ID is someone else's
                        ;; or does not exist: no oracle about others.
                        (error "No action #%d among yours" id)))
            (let ((undoable (cl-remove-if-not
                             (lambda (e)
                               (memq (cmacs-brigade-action-state e)
                                     '(done stale failed irreversible)))
                             mine)))
              (take (if (and (integerp count) (> count 0)) count 1)
                    undoable))))
         (outcome (if targets
                      (cmacs-brigade-undo-run-list targets 'stop)
                    (cons nil nil))))
    (cond
     ((and (null (car outcome)) (null (cdr outcome)))
      (if targets "Nothing to undo." "You have no actions to undo."))
     ((and (cdr outcome) (null (car outcome)))
      (error "%s" (cdr outcome)))
     (t (string-join (append (car outcome)
                             (and (cdr outcome) (list (cdr outcome))))
                     "\n")))))

(provide 'cmacs-brigade-undo-tools)

;;; cmacs-brigade-undo-tools.el ends here
