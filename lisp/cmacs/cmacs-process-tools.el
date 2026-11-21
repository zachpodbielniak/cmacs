;;; cmacs-process-tools.el --- The process tools as registered capabilities  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The read-only half of cmacs/mcp/cmacs-mcp-tools-process.c, written
;; once (doc_org/cmacs/cmacs-capability.org has the recipe).
;;
;; `list_processes' is here.  `send_to_process' is not: writing to a
;; subprocess is typing into a shell, which puts it in the privileged
;; set, and it stays a C tool until that set has been reviewed.
;;
;; Redaction (cmacs-redact.el): a command line is free text and goes
;; through the text rules -- it is where a token passed as an argument
;; shows up -- and the buffer column is blank for a process whose buffer
;; the rules exclude.

;;; Code:

(require 'cmacs-brigade-registry)

(declare-function cmacs-core-tools-print "cmacs-core-tools" (value))
(declare-function cmacs-core-tools-text "cmacs-core-tools" (string))
(declare-function cmacs-core-tools-buffer-hidden-p "cmacs-core-tools"
                  (buffer-or-name))

(cmacs-brigade-deftool list-processes
  "List all Emacs subprocesses with name, status, buffer, and command."
    ()
  :group 'process
  :example "emacsctl tool process list-processes"
  (require 'cmacs-core-tools)
  (cmacs-core-tools-print
   (mapconcat
    (lambda (p)
      (format "%s|%s|%s|%s"
              (process-name p)
              (symbol-name (process-status p))
              (let ((buffer (process-buffer p)))
                (or (and (buffer-live-p buffer)
                         (not (cmacs-core-tools-buffer-hidden-p buffer))
                         (buffer-name buffer))
                    ""))
              ;; A network or pipe process has t, not a list, for its
              ;; command; the C form signalled on those and took the
              ;; whole listing with it.
              (let ((command (process-command p)))
                (cmacs-core-tools-text
                 (if (listp command)
                     (mapconcat (lambda (word) (format "%s" word))
                                command " ")
                   "")))))
    (process-list) "\n")))

(provide 'cmacs-process-tools)

;;; cmacs-process-tools.el ends here
