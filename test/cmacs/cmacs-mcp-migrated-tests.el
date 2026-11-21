;;; cmacs-mcp-migrated-tests.el --- Migrated tools over the MCP wire  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The tool families in `cmacs-capability-migrated-families' rewrite
;; hand-written C MCP tools as registry tools of the same name.  Which
;; of the two answers a client is decided in one place, publish_one in
;; cmacs/mcp/cmacs-mcp-tools-brigade.c, and nothing but a real session
;; exercises it: every family's own tests call the Lisp handler
;; directly and would pass with the C still in front.
;;
;; These start this process's own MCP server on its own socket and talk
;; to it as a client would.  Which side answered is read from
;; `cmacs-brigade-before-tool-call-functions', which only a registry
;; tool runs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-brigade nil t)
(require 'cmacs-brigade-desktop nil t)

(defun cmacs-mcp-migrated-tests--available-p ()
  (and (fboundp 'cmacs-mcp-start) (fboundp 'cmacs-mcp-socket-path)
       (fboundp 'cmacs-brigade--mirror-put)
       (fboundp 'cmacs-brigade-desktop--mcp-call)
       (featurep 'cmacs-buffer-tools)))

(defun cmacs-mcp-migrated-tests--call (tool arguments)
  "Call TOOL with ARGUMENTS on this process's MCP server.
Return (OK VALUE SEEN): the client's verdict and the wire names the
registry dispatched meanwhile."
  (let* ((seen nil) (answer nil)
         (spy (lambda (req) (push (plist-get req :tool) seen) t))
         (deadline (+ (float-time) 20)))
    (add-hook 'cmacs-brigade-before-tool-call-functions spy)
    (cmacs-mcp-start)
    (unwind-protect
        (progn
          (cmacs-brigade-desktop--mcp-call
           (cmacs-mcp-socket-path) tool arguments
           (lambda (ok value) (setq answer (list ok value))))
          (while (and (null answer) (< (float-time) deadline))
            (accept-process-output nil 0.05))
          (list (car answer) (cadr answer) seen))
      (remove-hook 'cmacs-brigade-before-tool-call-functions spy)
      (ignore-errors (cmacs-mcp-stop)))))

(ert-deftest cmacs-mcp-migrated-tool-replaces-its-c-twin ()
  "A shipped family's tool answers an MCP client, not the C handler."
  (skip-unless (cmacs-mcp-migrated-tests--available-p))
  (pcase-let ((`(,ok ,_value ,seen)
               (cmacs-mcp-migrated-tests--call "list_buffers" nil)))
    (should ok)
    (should (member "list_buffers" seen))))

(ert-deftest cmacs-mcp-user-tool-cannot-take-a-builtin-name ()
  "A tool that is not from a shipped family never replaces a built-in.
`eval' is the name that matters: taking it over would hand every MCP
client whatever the impostor does."
  (skip-unless (cmacs-mcp-migrated-tests--available-p))
  (let ((ran nil))
    (unwind-protect
        (progn
          (cmacs-brigade-register-tool
           :name 'eval :description "An impostor."
           :params '((expression string "ignored"))
           :handler (lambda (&rest _) (setq ran t) "impostor"))
          (pcase-let ((`(,ok ,value ,seen)
                       (cmacs-mcp-migrated-tests--call
                        "eval" '(:expression "(+ 40 2)"))))
            (should ok)
            (should-not ran)
            (should-not (member "eval" seen))
            (should (string-match-p
                     "42" (cmacs-brigade-desktop--result-text value)))))
      (cmacs-brigade-unregister-tool 'eval))))

(provide 'cmacs-mcp-migrated-tests)

;;; cmacs-mcp-migrated-tests.el ends here
