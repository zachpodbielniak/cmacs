;;; cmacs-context-tools.el --- Contexts as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Three tools over cmacs-context.el:
;;
;;   context_list     the contexts there are, one per line
;;   context_current  the one you are in
;;   context_switch   switch to one
;;
;; A context's name is the person's own text -- a client, a project, a
;; diagnosis -- so every name shown to a caller goes through
;; `cmacs-redact-text', and a name is accepted back in the form it was
;; shown in: `context_switch' resolves what it is given against the
;; redacted names as well as the real ones, so a caller can switch to a
;; context without ever having been told what it is really called.  A
;; name the rules blank or withhold entirely is not listed and cannot be
;; switched to through a tool.
;;
;; `context_switch' starts programs, so it is :destructive and asks the
;; person before it runs (:confirm ask).  That confirmation is the
;; approval cmacs-context.el requires of an agent; the plan buffer a
;; person is shown before a first switch is not shown here, because
;; nothing on this path may prompt.  The switch itself returns at once:
;; the tool's answer says what was started, not that it has finished.
;;
;; This file loads at startup with the other tool families, so its only
;; top-level requirement is the registry; cmacs-context is required in
;; the bodies.

;;; Code:

(require 'cl-lib)
(require 'cmacs-brigade-registry)

(declare-function cmacs-context-names "cmacs-context" ())
(declare-function cmacs-context-info "cmacs-context" (name))
(declare-function cmacs-context-current "cmacs-context" ())
(declare-function cmacs-context-switch "cmacs-context" (name &optional show-plan))
(declare-function cmacs-context--launches "cmacs-context" (plan))
(declare-function cmacs-context--ago "cmacs-context" (time))
(declare-function cmacs-redact-text "cmacs-redact" (string))

(defvar cmacs-context--approved)
(defvar cmacs-context--switch)

(defun cmacs-context-tools--shown (name)
  "NAME as a caller may be shown it, or nil when it may not be shown.
One line, and never the empty string: a name the rules drop is not a
name a caller can use."
  (require 'cmacs-redact)
  (let ((shown (cmacs-redact-text name)))
    (and (stringp shown)
         (not (string-empty-p (string-trim shown)))
         ;; The fixed strings redaction answers with when it withholds a
         ;; text altogether start with a bracket; a name does not.
         (not (and (string-prefix-p "[" shown)
                   (not (string-prefix-p "[" name))))
         (replace-regexp-in-string "[\n\r\t]+" " " shown))))

(defun cmacs-context-tools--names ()
  "The contexts a caller may be told about: a list of (SHOWN . NAME)."
  (require 'cmacs-context)
  (delq nil
        (mapcar (lambda (name)
                  (let ((shown (cmacs-context-tools--shown name)))
                    (and shown (cons shown name))))
                (cmacs-context-names))))

(defun cmacs-context-tools--resolve (given)
  "The real name of the context a caller calls GIVEN, or signal.
GIVEN is matched against the names as shown, then ignoring case.  The
message for a name that is withheld is the one for a name that does not
exist."
  (let* ((given (string-trim (or given "")))
         (names (cmacs-context-tools--names)))
    (or (cdr (assoc given names))
        (cdr (cl-assoc given names :test #'string-equal-ignore-case))
        (error "No context called %s" given))))

(cmacs-brigade-deftool context-list
  "List the user's named contexts (saved arrangements of files, pages \
and applications), one per line: the name, whether it is the current \
one, how many applications and files it holds, its project and when it \
was last used.  Use context_switch to switch to one."
    ()
  :group 'context
  :example "emacsctl tool context list"
  (let ((names (cmacs-context-tools--names)))
    (if (null names)
        "No contexts."
      (mapconcat
       (pcase-lambda (`(,shown . ,name))
         (let ((info (cmacs-context-info name)))
           (format "%s%s\t%d apps\t%d files\t%s\tused %s"
                   shown
                   (if (plist-get info :current) " (current)" "")
                   (plist-get info :apps)
                   (plist-get info :files)
                   (let ((project (plist-get info :project)))
                     (if (stringp project)
                         (or (cmacs-context-tools--shown project) "-")
                       "-"))
                   (cmacs-context--ago (plist-get info :used)))))
       names "\n"))))

(cmacs-brigade-deftool context-current
  "Return the name of the context the user is in, or \"none\"."
    ()
  :group 'context
  :example "emacsctl tool context current"
  (require 'cmacs-context)
  (let ((current (cmacs-context-current)))
    (or (and current (cmacs-context-tools--shown current))
        "none")))

(cmacs-brigade-deftool context-switch
  "Switch the user's desktop to the named context: opens its files and \
pages, starts the applications it holds that are not running, moves the \
running ones to their tags and rebuilds the editor's windows.  Nothing \
is closed.  The user is asked before this runs.  Returns as soon as the \
switch has been started."
    ((name string "The context's name, as context_list shows it"))
  :group 'context :destructive t :confirm 'ask
  :example "emacsctl tool context switch --name work"
  (let ((real (cmacs-context-tools--resolve name))
        ;; The confirmation that let this body run is the person's yes.
        (cmacs-context--approved t))
    (cmacs-context-switch real)
    (let ((launches (cmacs-context--launches
                     (plist-get cmacs-context--switch :plan))))
      (format "Switching to %s%s."
              (or (cmacs-context-tools--shown real) name)
              (if (> launches 0)
                  (format "; starting %d application%s" launches
                          (if (= launches 1) "" "s"))
                "")))))

(provide 'cmacs-context-tools)

;;; cmacs-context-tools.el ends here
