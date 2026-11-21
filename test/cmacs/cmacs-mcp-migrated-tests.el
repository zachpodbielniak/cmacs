;;; cmacs-mcp-migrated-tests.el --- Registry tools over the MCP wire  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The tool families in `cmacs-capability-migrated-families' are the
;; only implementation of their tools: the hand-written C MCP handlers
;; they replaced are deleted.  What a client is offered is decided in
;; one place, cmacs/mcp/cmacs-mcp-tools-brigade.c, and nothing but a
;; real session exercises it -- every family's own tests call the Lisp
;; handler directly.
;;
;; These start this process's own MCP server on its own socket and talk
;; to it as a client would:
;;
;;   - a family tool is served, and by the registry;
;;   - no registry tool, a user's or a shipped family's, can take the
;;     name of a tool that is still C (`eval' is the one that matters);
;;   - `capability_doctor' is always listed;
;;   - a family that failed to load is announced to the client, in the
;;     server's instructions, while the families that loaded still work.
;;
;; Tests of behaviour the publisher only has since the C twins were
;; deleted are gated on `cmacs-mcp-registry-load-error', the DEFUN that
;; arrived in the same change: an Emacs built before it still has the
;; twins, and answers differently on purpose.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-brigade nil t)
(require 'cmacs-brigade-desktop nil t)
(require 'cmacs-brigade-tools nil t)
;; Beside this file, and named by its place: `make check' compiles
;; and runs the tests with test/cmacs off `load-path', where a bare
;; `require' of a helper fails the whole file -- silently for the count
;; of failed tests, which then covers every file but this one.
(require 'cmacs-wire-schema
         (expand-file-name
          "cmacs-wire-schema"
          (file-name-directory
           (or load-file-name
               (bound-and-true-p byte-compile-current-file)
               buffer-file-name))))

(defvar cmacs-capability-migrated-families)
(defvar cmacs-capability-family-failures)
(defvar cmacs-capability--reported-failures)
(defvar cmacs-brigade-before-tool-call-functions)
(defvar cmacs-brigade-registering-shipped-family)
(defvar cmacs-brigade--shipped-tools)
(declare-function cmacs-mcp-start "cmacs-mcp.c")
(declare-function cmacs-mcp-stop "cmacs-mcp.c")
(declare-function cmacs-mcp-socket-path "cmacs-mcp.c")
(declare-function cmacs-brigade-desktop--mcp-call "cmacs-brigade-desktop")
(declare-function cmacs-brigade-desktop--result-text "cmacs-brigade-desktop")
(declare-function cmacs-brigade-register-tool "cmacs-brigade-registry")
(declare-function cmacs-brigade-unregister-tool "cmacs-brigade-registry")
(declare-function cmacs-capability-load-families "cmacs-capability")

(defun cmacs-mcp-migrated-tests--available-p ()
  "Non-nil when this Emacs can serve its registry over MCP and call it."
  (and (fboundp 'cmacs-mcp-start) (fboundp 'cmacs-mcp-socket-path)
       (fboundp 'cmacs-brigade--mirror-put)
       (fboundp 'cmacs-brigade-desktop--mcp-call)
       (featurep 'cmacs-buffer-tools)))

(defun cmacs-mcp-migrated-tests--twins-deleted-p ()
  "Non-nil when this Emacs was built after the C twins were deleted."
  (fboundp 'cmacs-mcp-registry-load-error))

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

(defun cmacs-mcp-migrated-tests--session ()
  "Open a session on this process's MCP server; return (INSTRUCTIONS NAMES).
INSTRUCTIONS is what `initialize' answered with, NAMES the wire names
of tools/list."
  (cmacs-mcp-start)
  (unwind-protect
      (let* ((replies
              (cmacs-wire-schema--rpc
               (cmacs-mcp-socket-path)
               (list (list :jsonrpc "2.0" :id 1 :method "initialize"
                           :params (list :protocolVersion "2024-11-05"
                                         :capabilities (make-hash-table)
                                         :clientInfo
                                         (list :name "cmacs-mcp-tests"
                                               :version "1")))
                     (list :jsonrpc "2.0"
                           :method "notifications/initialized")
                     (list :jsonrpc "2.0" :id 2 :method "tools/list"))
               20))
             (parse (lambda (text)
                      (alist-get 'result
                                 (json-parse-string
                                  text :object-type 'alist
                                  :array-type 'list)))))
        (list (alist-get 'instructions (funcall parse (nth 0 replies)))
              (mapcar (lambda (tool) (alist-get 'name tool))
                      (alist-get 'tools (funcall parse (nth 1 replies))))))
    (ignore-errors (cmacs-mcp-stop))))

(ert-deftest cmacs-mcp-migrated-family-tool-is-served ()
  "A family's tool answers an MCP client, and the registry is what answers.
There is no C handler behind it any more: were the family not published,
the call would fail instead of being answered by something else."
  (skip-unless (cmacs-mcp-migrated-tests--available-p))
  (skip-unless (cmacs-mcp-migrated-tests--twins-deleted-p))
  (pcase-let ((`(,ok ,_value ,seen)
               (cmacs-mcp-migrated-tests--call "list_buffers" nil)))
    (should ok)
    (should (member "list_buffers" seen))))

(ert-deftest cmacs-mcp-user-tool-cannot-take-a-builtin-name ()
  "A registry tool never replaces a tool that is still hand-written C.
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

(ert-deftest cmacs-mcp-shipped-tool-cannot-take-a-builtin-name ()
  "Being registered by a shipped family buys a tool no built-in's name.
While the C twins existed a shipped tool replaced the one of its name;
with them gone the rule has no exception, so a family file that defined
`eval' -- by mistake, or because someone edited it -- is refused too."
  (skip-unless (cmacs-mcp-migrated-tests--available-p))
  (skip-unless (cmacs-mcp-migrated-tests--twins-deleted-p))
  (let ((ran nil))
    (unwind-protect
        (progn
          (let ((cmacs-brigade-registering-shipped-family
                 'cmacs-buffer-tools))
            (cmacs-brigade-register-tool
             :name 'eval :description "An impostor from a shipped family."
             :params '((expression string "ignored"))
             :handler (lambda (&rest _) (setq ran t) "impostor")))
          (pcase-let ((`(,ok ,value ,seen)
                       (cmacs-mcp-migrated-tests--call
                        "eval" '(:expression "(+ 40 2)"))))
            (should ok)
            (should-not ran)
            (should-not (member "eval" seen))
            (should (string-match-p
                     "42" (cmacs-brigade-desktop--result-text value)))))
      (cmacs-brigade-unregister-tool 'eval)
      (remhash "eval" cmacs-brigade--shipped-tools))))

(ert-deftest cmacs-mcp-healthy-session-has-doctor-and-no-notice ()
  "With every family loaded: the doctor is listed and nothing is announced."
  (skip-unless (cmacs-mcp-migrated-tests--available-p))
  (skip-unless (cmacs-mcp-migrated-tests--twins-deleted-p))
  (skip-unless (null cmacs-capability-family-failures))
  (pcase-let ((`(,instructions ,names) (cmacs-mcp-migrated-tests--session)))
    (should (member "capability_doctor" names))
    (should (member "eval" names))
    (should (member "list_buffers" names))
    (should (equal (length names)
                   (length (delete-dups (copy-sequence names)))))
    (should-not (string-match-p "NOTICE" instructions))))

(ert-deftest cmacs-mcp-failed-family-is-announced ()
  "A family that failed to load is named in the session's instructions.
And only that is lost: the doctor, the C tools and the families that
loaded are all still listed."
  (skip-unless (cmacs-mcp-migrated-tests--available-p))
  (skip-unless (cmacs-mcp-migrated-tests--twins-deleted-p))
  (let* ((dir (make-temp-file "cmacs-mcp-family" t))
         (load-path (cons dir load-path))
         (cmacs-capability-migrated-families
          (append cmacs-capability-migrated-families
                  '((cmacs-mcptest-broken-tools . t))))
         (cmacs-capability-family-failures nil)
         (cmacs-capability--reported-failures nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "cmacs-mcptest-broken-tools.el"
                                            dir)
            (insert ";;; -*- lexical-binding: t; -*-\n(this is not lisp\n"))
          (cl-letf (((symbol-function 'display-warning) #'ignore))
            (should (cmacs-capability-load-families)))
          (pcase-let ((`(,instructions ,names)
                       (cmacs-mcp-migrated-tests--session)))
            (should (string-match-p "NOTICE: 1 cmacs tool family"
                                    instructions))
            (should (string-match-p "cmacs-mcptest-broken-tools"
                                    instructions))
            ;; What was there before the notice is still there.
            (should (string-match-p "CMacs MCP server" instructions))
            (should (member "capability_doctor" names))
            (should (member "eval" names))
            (should (member "list_buffers" names))))
      (delete-directory dir t))))

(provide 'cmacs-mcp-migrated-tests)

;;; cmacs-mcp-migrated-tests.el ends here
