;;; cmacs-core-tools.el --- Shared helpers of the editor-core tool families  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The buffer, window, edit, process, debug, project, gi and describe
;; tool families (cmacs-<family>-tools.el) are the editor-core MCP tools
;; moved onto the capability table.  They share three small things, and
;; this file is where those live so that eight files do not each grow
;; their own slightly different copy:
;;
;;   1. How a result is printed.  The C handlers went through
;;      `cmacs_dispatch_eval', which returns the value as `prin1' prints
;;      it -- a string comes back in double quotes with `"' and `\'
;;      escaped, `t' comes back as "t".  A client may be parsing that, so
;;      `cmacs-core-tools-print' keeps the shape.  (Handlers that went
;;      through `cmacs_dispatch_eval_string' returned strings verbatim,
;;      and the tools ported from those return the string itself.)
;;
;;   2. How a buffer is named.  Every tool that takes a buffer resolves
;;      it through `cmacs-core-tools-buffer', which answers a buffer the
;;      redaction rules exclude with exactly the message it gives for a
;;      buffer that does not exist.  One message, so a model cannot use
;;      the tools to find out which excluded buffers are open.
;;
;;   3. How the redaction contract (cmacs-redact.el) is reached.  The
;;      rules decide; these wrappers only load the file on first use and
;;      call it.  When cmacs-redact.el cannot be loaded the `require'
;;      signals and the tool fails, which is the direction to fail in.
;;
;; Nothing here registers a tool.  The family files require this file
;; from inside their tool bodies, never at top level: they are loaded at
;; startup so the tools are listed, and the listing needs none of this.

;;; Code:

(declare-function cmacs-redact-buffer-p "cmacs-redact" (buffer-or-name))
(declare-function cmacs-redact-text "cmacs-redact" (string))
(declare-function cmacs-redact-event "cmacs-redact" (plist))

(defconst cmacs-core-tools-no-buffer-format
  "No such buffer, or it is not available: %s"
  "The one message for a buffer a tool will not touch.
Used both when the buffer does not exist and when the redaction rules
exclude it; the two cases must stay indistinguishable.")

(defun cmacs-core-tools-print (value)
  "Return VALUE as `cmacs_dispatch_eval' returned it: printed with `prin1'."
  (prin1-to-string value))

(defun cmacs-core-tools-buffer-hidden-p (buffer-or-name)
  "Non-nil when the redaction rules exclude BUFFER-OR-NAME."
  (require 'cmacs-redact)
  (and (cmacs-redact-buffer-p buffer-or-name) t))

(defun cmacs-core-tools-buffer (name)
  "Return the live buffer called NAME, or signal the one fixed error.
The error is the same for a missing buffer and for one the redaction
rules exclude.  The rules are asked before the buffer is looked up, by
name, so an excluded name is refused whether or not it is open."
  (unless (and (stringp name) (not (string-empty-p name)))
    (error "Missing required argument: buffer"))
  (let ((buffer (and (not (cmacs-core-tools-buffer-hidden-p name))
                     (get-buffer name))))
    (unless (and (buffer-live-p buffer)
                 ;; Asked again of the buffer itself: the rules also look
                 ;; at its file, mode and project, which a name that
                 ;; matched nothing cannot tell them.
                 (not (cmacs-core-tools-buffer-hidden-p buffer)))
      (error cmacs-core-tools-no-buffer-format name))
    buffer))

(defun cmacs-core-tools-check-name (name)
  "Signal the fixed error when a buffer called NAME would be excluded.
For the tools that may create the buffer they are given (`create_buffer',
`switch_to_buffer'), where a missing buffer is not an error."
  (unless (and (stringp name) (not (string-empty-p name)))
    (error "Missing required argument: buffer"))
  (when (or (cmacs-core-tools-buffer-hidden-p name)
            (let ((buffer (get-buffer name)))
              (and buffer (cmacs-core-tools-buffer-hidden-p buffer))))
    (error cmacs-core-tools-no-buffer-format name)))

(defun cmacs-core-tools-text (string)
  "Return STRING with the free-text redaction rules applied."
  (require 'cmacs-redact)
  (cmacs-redact-text (or string "")))

(defun cmacs-core-tools-file-hidden-p (file &optional project)
  "Non-nil when the redaction rules exclude FILE, a file of PROJECT.
A file on disk is described to the rules the way the journal describes a
buffer visiting it -- kind `buffer' with :file and :project -- so a rule
written to keep a file out of the journal keeps it out of a tool result
without having to be written twice."
  (require 'cmacs-redact)
  (null (cmacs-redact-event
         (append (list :kind 'buffer :file file)
                 (and project (list :project project))))))

(provide 'cmacs-core-tools)

;;; cmacs-core-tools.el ends here
