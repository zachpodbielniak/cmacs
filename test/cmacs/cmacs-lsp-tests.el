;;; cmacs-lsp-tests.el --- Tests for the in-binary LSP framework -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; End-to-end tests for `emacs --cmacs-lsp gnucalc': the tests spawn
;; THIS Emacs binary as the language server (the same call-back-to-self
;; model the eglot client uses), speak Content-Length-framed JSON-RPC
;; over a pipe, and assert on real responses.  Plus the CLI surface
;; (--help auto-population, bare/unknown language listing) and the
;; drift guard for the generated data header.  Everything runs
;; headlessly; every test skips itself in a build without
;; --with-cmacs-lsp + --with-cmacs-calculator.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defun cmacs-lsp-tests--available-p ()
  "Non-nil when this build compiled in the lsp framework + gnucalc."
  (and (boundp 'is-cmacs-lsp) is-cmacs-lsp
       (boundp 'is-cmacs-calculator) is-cmacs-calculator))

(defconst cmacs-lsp-tests--binary
  (expand-file-name invocation-name invocation-directory)
  "The Emacs binary under test -- the server is this same binary.")

(defconst cmacs-lsp-tests--root
  (expand-file-name "../.." (file-name-directory
                             (or load-file-name buffer-file-name)))
  "Repository root, derived from this file's location in test/cmacs/.")

;;; Framed JSON-RPC harness

(defun cmacs-lsp-tests--start ()
  "Spawn the gnucalc server; return the process."
  (let* ((buf (generate-new-buffer " *cmacs-lsp-tests*"))
         (proc (make-process
                :name "cmacs-lsp-tests"
                :command (list cmacs-lsp-tests--binary "--cmacs-lsp" "gnucalc")
                :connection-type 'pipe
                :coding 'no-conversion
                :noquery t
                :buffer buf)))
    (with-current-buffer buf
      (set-buffer-multibyte nil))
    proc))

(defun cmacs-lsp-tests--send (proc msg)
  "Send MSG (a plist for `json-serialize') to PROC, framed."
  (let ((body (encode-coding-string (json-serialize msg) 'utf-8)))
    (process-send-string
     proc (format "Content-Length: %d\r\n\r\n" (length body)))
    (process-send-string proc body)))

(defun cmacs-lsp-tests--read (proc &optional timeout)
  "Read one framed message from PROC; return it as an alist.
Signals an error after TIMEOUT (default 15) seconds."
  (let ((deadline (+ (float-time) (or timeout 15))))
    (with-current-buffer (process-buffer proc)
      (catch 'msg
        (while t
          (goto-char (point-min))
          (let ((body-start nil)
                (len nil))
            (when (re-search-forward
                   "Content-Length: \\([0-9]+\\)\r\n\r\n" nil t)
              (setq len (string-to-number (match-string 1))
                    body-start (point)))
            (if (and len (>= (- (point-max) body-start) len))
                (let ((body (buffer-substring body-start (+ body-start len))))
                  (delete-region (point-min) (+ body-start len))
                  (throw 'msg
                         (json-parse-string
                          (decode-coding-string body 'utf-8)
                          :object-type 'alist :array-type 'list
                          :null-object nil)))
              (accept-process-output proc 0.2)
              (when (> (float-time) deadline)
                (error "cmacs-lsp-tests: read timeout")))))))))

(defun cmacs-lsp-tests--response (proc id)
  "Read messages from PROC until the response to request ID arrives.
Notifications on the way are discarded."
  (let (msg)
    (while (not (eql (alist-get 'id (setq msg (cmacs-lsp-tests--read proc)))
                     id)))
    msg))

(defun cmacs-lsp-tests--notification (proc method)
  "Read messages from PROC until a METHOD notification arrives."
  (let (msg)
    (while (not (equal (alist-get 'method
                                  (setq msg (cmacs-lsp-tests--read proc)))
                       method)))
    msg))

(defmacro cmacs-lsp-tests--with-server (proc &rest body)
  "Run BODY with PROC bound to an initialized gnucalc server.
Sends initialize/initialized first and always kills the process."
  (declare (indent 1))
  `(let ((,proc (cmacs-lsp-tests--start)))
     (unwind-protect
         (progn
           (cmacs-lsp-tests--send
            ,proc '(:jsonrpc "2.0" :id 1 :method "initialize"
                    :params (:capabilities #s(hash-table))))
           (cmacs-lsp-tests--response ,proc 1)
           (cmacs-lsp-tests--send
            ,proc '(:jsonrpc "2.0" :method "initialized"
                    :params #s(hash-table)))
           ,@body)
       (when (process-live-p ,proc)
         (delete-process ,proc))
       (kill-buffer (process-buffer ,proc)))))

(defun cmacs-lsp-tests--open (proc text)
  "didOpen TEXT as file:///t.calc on PROC; return the diagnostics list."
  (cmacs-lsp-tests--send
   proc `(:jsonrpc "2.0" :method "textDocument/didOpen"
          :params (:textDocument (:uri "file:///t.calc"
                                  :languageId "gnucalc"
                                  :version 1 :text ,text))))
  (alist-get 'diagnostics
             (alist-get 'params
                        (cmacs-lsp-tests--notification
                         proc "textDocument/publishDiagnostics"))))

(defconst cmacs-lsp-tests--sheet
  "rate := 0.05\nsqrrt(2)\npmt(rate, 360, 300000)\n"
  "The standard test sheet: a binding, a typo call, a real call.")

;;; The E2E scenarios

(ert-deftest cmacs-lsp-tests-initialize-capabilities ()
  "The server advertises the full gnucalc capability set."
  (skip-unless (cmacs-lsp-tests--available-p))
  (let ((proc (cmacs-lsp-tests--start)))
    (unwind-protect
        (progn
          (cmacs-lsp-tests--send
           proc '(:jsonrpc "2.0" :id 1 :method "initialize"
                  :params (:capabilities #s(hash-table))))
          (let* ((result (alist-get 'result (cmacs-lsp-tests--response proc 1)))
                 (caps (alist-get 'capabilities result)))
            (should (eql (alist-get 'textDocumentSync caps) 1))
            (should (alist-get 'completionProvider caps))
            ;; Argument-position completion: clients auto-pop the list
            ;; right after "(" and "," without a typed prefix.
            (should (member "(" (alist-get 'triggerCharacters
                                          (alist-get 'completionProvider
                                                     caps))))
            (should (member "," (alist-get 'triggerCharacters
                                          (alist-get 'completionProvider
                                                     caps))))
            (should (alist-get 'hoverProvider caps))
            (should (alist-get 'definitionProvider caps))
            (should (alist-get 'documentSymbolProvider caps))
            (should (alist-get 'signatureHelpProvider caps))
            (should (alist-get 'semanticTokensProvider caps))
            (should (equal (alist-get 'name (alist-get 'serverInfo result))
                           "cmacs-lsp-gnucalc"))))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer (process-buffer proc)))))

(ert-deftest cmacs-lsp-tests-diagnostics ()
  "Unknown call heads warn; unbalanced delimiters error; `:=' and
result annotations produce nothing."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (let ((diags (cmacs-lsp-tests--open
                  proc (concat cmacs-lsp-tests--sheet
                               "bscall(100, 100, 0.05, 0.2, 1)  ⇒  10.45\n"
                               "2 + (3\n"))))
      (should (= (length diags) 2))
      (let ((unknown (car diags))
            (unclosed (cadr diags)))
        (should (equal (alist-get 'code unknown) "unknown-function"))
        (should (eql (alist-get 'severity unknown) 2))
        (should (eql (alist-get 'line (alist-get 'start
                                                 (alist-get 'range unknown)))
                     1))
        (should (string-match-p "sqrrt" (alist-get 'message unknown)))
        (should (equal (alist-get 'code unclosed) "unbalanced-delimiter"))
        (should (eql (alist-get 'severity unclosed) 1))
        (should (eql (alist-get 'line (alist-get 'start
                                                 (alist-get 'range unclosed)))
                     4))))))

(ert-deftest cmacs-lsp-tests-completion ()
  "Completion serves built-ins, defcalcs, units and sheet variables."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc cmacs-lsp-tests--sheet)
    (cl-flet ((labels-at (line char)
                (cmacs-lsp-tests--send
                 proc `(:jsonrpc "2.0" :id 2 :method "textDocument/completion"
                        :params (:textDocument (:uri "file:///t.calc")
                                 :position (:line ,line :character ,char))))
                (mapcar (lambda (item) (alist-get 'label item))
                        (alist-get 'result
                                   (cmacs-lsp-tests--response proc 2)))))
      ;; "sq|" inside the typo on line 1.
      (let ((labels (labels-at 1 2)))
        (should (member "sqrt" labels))
        (should-not (member "abs" labels)))
      ;; Empty prefix at line start: everything, including defcalcs,
      ;; units, constants and the sheet variable.
      (let ((labels (labels-at 2 0)))
        (should (member "bscall" labels))
        (should (member "lorentz" labels))
        (should (member "lyr" labels))
        (should (member "pi" labels))
        (should (member "rate" labels))))))

(ert-deftest cmacs-lsp-tests-hover ()
  "Hover shows catalog docs for built-ins and definitions for
sheet variables."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc cmacs-lsp-tests--sheet)
    ;; pmt on line 2.
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 3 :method "textDocument/hover"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 2 :character 1))))
    (let* ((result (alist-get 'result (cmacs-lsp-tests--response proc 3)))
           (value (alist-get 'value (alist-get 'contents result))))
      (should (string-match-p "\\*\\*pmt\\*\\*" value))
      (should (string-match-p "Calc built-in" value)))
    ;; The rate reference on line 2 hovers as a sheet variable.
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 4 :method "textDocument/hover"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 2 :character 5))))
    (let* ((result (alist-get 'result (cmacs-lsp-tests--response proc 4)))
           (value (alist-get 'value (alist-get 'contents result))))
      (should (string-match-p "sheet variable" value))
      (should (string-match-p "rate := 0\\.05" value)))))

(ert-deftest cmacs-lsp-tests-signature-help ()
  "Signature help names the arguments and tracks the active one."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc cmacs-lsp-tests--sheet)
    ;; After "pmt(rate," -- the second argument is active.
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 5 :method "textDocument/signatureHelp"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 2 :character 9))))
    (let* ((result (alist-get 'result (cmacs-lsp-tests--response proc 5)))
           (sig (car (alist-get 'signatures result))))
      (should (string-prefix-p "pmt(" (alist-get 'label sig)))
      (should (eql (alist-get 'activeParameter result) 1))
      (should (consp (alist-get 'parameters sig))))))

(ert-deftest cmacs-lsp-tests-signature-help-at-open-paren ()
  "Signature help fires immediately after `(' -- typed alone or as an
electric pair -- with the first argument active."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc "loanpmt(\nloanpmt()\n")
    ;; "loanpmt(" -- cursor right after the open paren.
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 10 :method "textDocument/signatureHelp"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 0 :character 8))))
    (let* ((result (alist-get 'result (cmacs-lsp-tests--response proc 10)))
           (sig (car (alist-get 'signatures result))))
      (should (equal (alist-get 'label sig)
                     "loanpmt(principal, annrate, years)"))
      (should (eql (alist-get 'activeParameter result) 0)))
    ;; "loanpmt()" -- electric pair, cursor between the parens.
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 11 :method "textDocument/signatureHelp"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 1 :character 8))))
    (let* ((result (alist-get 'result (cmacs-lsp-tests--response proc 11)))
           (sig (car (alist-get 'signatures result))))
      (should (equal (alist-get 'label sig)
                     "loanpmt(principal, annrate, years)"))
      (should (eql (alist-get 'activeParameter result) 0)))))

(ert-deftest cmacs-lsp-tests-completion-at-open-paren ()
  "Empty-prefix completion at an argument position serves candidates.
This is what the `(' trigger character pops in the client."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc "rate := 0.05\nloanpmt(\n")
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 12 :method "textDocument/completion"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 1 :character 8))))
    (let ((labels (mapcar (lambda (item) (alist-get 'label item))
                          (alist-get 'result
                                     (cmacs-lsp-tests--response proc 12)))))
      (should (member "rate" labels))
      (should (member "pi" labels))
      (should (member "sqrt" labels)))))

(ert-deftest cmacs-lsp-tests-definition-and-symbols ()
  "`:=' bindings resolve as definitions and list as symbols."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc cmacs-lsp-tests--sheet)
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 6 :method "textDocument/definition"
            :params (:textDocument (:uri "file:///t.calc")
                     :position (:line 2 :character 5))))
    (let ((result (alist-get 'result (cmacs-lsp-tests--response proc 6))))
      (should (equal (alist-get 'uri result) "file:///t.calc"))
      (should (eql (alist-get 'line (alist-get 'start
                                               (alist-get 'range result)))
                   0)))
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 7 :method "textDocument/documentSymbol"
            :params (:textDocument (:uri "file:///t.calc"))))
    (let ((result (alist-get 'result (cmacs-lsp-tests--response proc 7))))
      (should (equal (mapcar (lambda (s) (alist-get 'name s)) result)
                     '("rate")))
      (should (eql (alist-get 'kind (car result)) 13)))))

(ert-deftest cmacs-lsp-tests-semantic-tokens ()
  "semanticTokens/full returns well-formed delta-encoded data."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--open proc cmacs-lsp-tests--sheet)
    (cmacs-lsp-tests--send
     proc '(:jsonrpc "2.0" :id 8 :method "textDocument/semanticTokens/full"
            :params (:textDocument (:uri "file:///t.calc"))))
    (let ((data (alist-get 'data
                           (alist-get 'result
                                      (cmacs-lsp-tests--response proc 8)))))
      (should (consp data))
      (should (zerop (mod (length data) 5))))))

(ert-deftest cmacs-lsp-tests-shutdown-exit ()
  "shutdown then exit terminates the server with status 0."
  (skip-unless (cmacs-lsp-tests--available-p))
  (cmacs-lsp-tests--with-server proc
    (cmacs-lsp-tests--send proc '(:jsonrpc "2.0" :id 9 :method "shutdown"))
    (cmacs-lsp-tests--response proc 9)
    (cmacs-lsp-tests--send proc '(:jsonrpc "2.0" :method "exit"))
    (let ((deadline (+ (float-time) 15)))
      (while (and (process-live-p proc) (< (float-time) deadline))
        (accept-process-output proc 0.2)))
    (should-not (process-live-p proc))
    (should (zerop (process-exit-status proc)))))

(ert-deftest cmacs-lsp-tests-uninitialized-request-errors ()
  "Requests before `initialized' get -32002."
  (skip-unless (cmacs-lsp-tests--available-p))
  (let ((proc (cmacs-lsp-tests--start)))
    (unwind-protect
        (progn
          (cmacs-lsp-tests--send
           proc '(:jsonrpc "2.0" :id 1 :method "textDocument/completion"
                  :params (:textDocument (:uri "file:///t.calc")
                           :position (:line 0 :character 0))))
          (let ((msg (cmacs-lsp-tests--response proc 1)))
            (should (eql (alist-get 'code (alist-get 'error msg)) -32002))))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer (process-buffer proc)))))

;;; The CLI surface

(ert-deftest cmacs-lsp-tests-cli-lists-languages ()
  "Bare and unknown --cmacs-lsp list the servers and exit 1."
  (skip-unless (cmacs-lsp-tests--available-p))
  (dolist (args '(("--cmacs-lsp") ("--cmacs-lsp" "nosuch")))
    (with-temp-buffer
      (let ((status (apply #'call-process cmacs-lsp-tests--binary
                           nil t nil args)))
        (should (eql status 1))
        (should (string-match-p "gnucalc" (buffer-string)))))))

(ert-deftest cmacs-lsp-tests-help-lists-languages ()
  "--help auto-populates the compiled-in language-server section."
  (skip-unless (cmacs-lsp-tests--available-p))
  (with-temp-buffer
    (should (eql (call-process cmacs-lsp-tests--binary nil t nil "--help") 0))
    (should (string-match-p "Compiled-in --cmacs-lsp language servers"
                            (buffer-string)))
    (should (string-match-p "gnucalc" (buffer-string)))))

;;; Generated-data drift guard

(ert-deftest cmacs-lsp-tests-gnucalc-data-in-sync ()
  "The committed data header byte-matches a fresh regeneration.
A failure means the catalog, the registry, or Calc's units table
changed: rerun cmacs-calc-builtins-generate-lsp-data (see
admin/cmacs-calc-builtins-catalog.el) and commit the result."
  (skip-unless (cmacs-lsp-tests--available-p))
  (let ((catalog (expand-file-name "admin/cmacs-calc-builtins-catalog.el"
                                   cmacs-lsp-tests--root))
        (header (expand-file-name "cmacs/lsp/cmacs-lsp-gnucalc-data.h"
                                  cmacs-lsp-tests--root)))
    (skip-unless (and (file-readable-p catalog) (file-readable-p header)))
    (skip-unless (require 'cmacs-calculator nil t))
    (load catalog nil t)
    (should (equal (cmacs-calc-builtins--lsp-data-string)
                   (with-temp-buffer
                     (insert-file-contents header)
                     (buffer-string))))))

(provide 'cmacs-lsp-tests)
;;; cmacs-lsp-tests.el ends here
