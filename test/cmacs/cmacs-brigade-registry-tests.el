;;; cmacs-brigade-registry-tests.el --- Tests for the brigade fabric  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The extension surface is the product, so it gets the edge cases:
;; malformed definitions, argument coercion, async timeouts, and above
;; all the authorisation gate, where a wrong answer is a security bug
;; rather than a bug report.

;;; Code:

(require 'ert)
(require 'cmacs-brigade nil 'noerror)
(require 'cmacs-brigade-registry nil 'noerror)
(require 'cmacs-brigade-tools nil 'noerror)

(defun cmacs-brigade-registry-tests--available-p ()
  (and (featurep 'cmacs-brigade-registry) (featurep 'cmacs-brigade-tools)))

(defmacro cmacs-brigade-tests--with-clean-registry (&rest body)
  "Run BODY with a private tool registry, restoring the real one after.

Tests must not leak tools into a live session's registry -- and must not
inherit tools a previous test registered, or an allowlist assertion can
pass for the wrong reason."
  (declare (indent 0))
  `(let ((saved (copy-hash-table (cmacs-brigade--registry 'tool)))
         (saved-mirror (and (fboundp 'cmacs-brigade--mirror-names)
                            (cmacs-brigade--mirror-names))))
     (unwind-protect
         (progn (clrhash (cmacs-brigade--registry 'tool))
                (dolist (n saved-mirror)
                  (when (fboundp 'cmacs-brigade--mirror-remove)
                    (cmacs-brigade--mirror-remove n)))
                ,@body)
       (clrhash (cmacs-brigade--registry 'tool))
       (maphash (lambda (k v) (puthash k v (cmacs-brigade--registry 'tool)))
                saved))))


;;;; Definition validation

(ert-deftest cmacs-brigade-deftool-registers-everywhere ()
  "A single definition reaches the Elisp registry and the C mirror."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-echo "Echo." ((text string "What")) text)
    (should (memq 'test-echo (cmacs-brigade-registry-list 'tool)))
    (when (fboundp 'cmacs-brigade--mirror-names)
      ;; A disagreement here means MCP clients and in-process agents
      ;; would see different tool sets.
      (should (member "test_echo" (cmacs-brigade--mirror-names))))))

(ert-deftest cmacs-brigade-wire-name-is-snake-case ()
  "Kebab-case symbols become snake_case on the wire, and only there."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (should (equal (cmacs-brigade-wire-name 'call-for-me) "call_for_me"))
  (should (equal (cmacs-brigade-wire-name "already_snake") "already_snake"))
  (should (equal (cmacs-brigade-wire-name 'plain) "plain")))

(ert-deftest cmacs-brigade-deftool-rejects-bad-definitions ()
  "Malformed definitions signal at registration, not at call time."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    ;; unknown parameter type: would validate here and be silently
    ;; dropped on the wire, which is worse than refusing
    (should-error (cmacs-brigade-register-tool
                   :name 'bad :description "d" :handler #'ignore
                   :params '((x frobnicate "doc")))
                  :type 'cmacs-brigade-tool-error)
    ;; missing description
    (should-error (cmacs-brigade-register-tool :name 'bad :handler #'ignore)
                  :type 'cmacs-brigade-tool-error)
    ;; missing handler
    (should-error (cmacs-brigade-register-tool :name 'bad :description "d")
                  :type 'cmacs-brigade-tool-error)
    ;; nonsense confirm mode
    (should-error (cmacs-brigade-register-tool
                   :name 'bad :description "d" :handler #'ignore
                   :confirm 'maybe)
                  :type 'cmacs-brigade-tool-error)
    ;; parameter description must be a string
    (should-error (cmacs-brigade-register-tool
                   :name 'bad :description "d" :handler #'ignore
                   :params '((x string 42)))
                  :type 'cmacs-brigade-tool-error)))

(ert-deftest cmacs-brigade-register-is-idempotent ()
  "Re-registering a name replaces it, so reloading an init file is safe."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-dup "First." ((a string "a")) "one")
    (cmacs-brigade-deftool test-dup "Second." ((a string "a")) "two")
    (should (= 1 (length (cmacs-brigade-registry-list 'tool))))
    (should (equal "two" (cmacs-brigade-call-tool "test_dup" "{\"a\":\"x\"}")))))

(ert-deftest cmacs-brigade-unregister-clears-both-sides ()
  "Unregistering removes the tool from Elisp and from the C mirror."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-gone "Gone." ((a string "a")) "x")
    (should (cmacs-brigade-unregister-tool 'test-gone))
    (should-not (memq 'test-gone (cmacs-brigade-registry-list 'tool)))
    (when (fboundp 'cmacs-brigade--mirror-names)
      (should-not (member "test_gone" (cmacs-brigade--mirror-names))))
    ;; second removal is a no-op, not an error
    (should-not (cmacs-brigade-unregister-tool 'test-gone))))


;;;; Dispatch and argument handling

(ert-deftest cmacs-brigade-call-coerces-and-defaults ()
  "Model-supplied arguments are coerced; optionals fall back to defaults."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-args "Args."
      ((n integer "count")
       (flag boolean "on?" :optional t)
       (unit string "unit" :optional t :default "metric"))
      (format "%S %S %s" n flag unit))
    ;; a model sending "3" for an integer is common enough that
    ;; refusing would just produce retry loops
    (should (equal "3 nil metric"
                   (cmacs-brigade-call-tool "test_args" "{\"n\":\"3\"}")))
    (should (equal "3 t metric"
                   (cmacs-brigade-call-tool "test_args"
                                            "{\"n\":3,\"flag\":true}")))
    (should (equal "3 nil imperial"
                   (cmacs-brigade-call-tool
                    "test_args" "{\"n\":3,\"unit\":\"imperial\"}")))
    ;; JSON false must not read as truthy
    (should (equal "3 nil metric"
                   (cmacs-brigade-call-tool "test_args"
                                            "{\"n\":3,\"flag\":false}")))))

(ert-deftest cmacs-brigade-call-returns-errors-as-text ()
  "Failures come back as \"Error: ...\" rather than signalling.

ai-glib's soft-error convention: a signalled error aborts the agent's
whole turn, a returned one lets the model read what went wrong."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-req "Req." ((a string "a")) a)
    (should (string-prefix-p "Error: " (cmacs-brigade-call-tool "nope" "{}")))
    (should (string-prefix-p "Error: " (cmacs-brigade-call-tool "test_req" "{}")))
    (should (string-prefix-p "Error: "
                             (cmacs-brigade-call-tool "test_req" "not json")))
    (cmacs-brigade-deftool test-boom "Boom." ((a string "a"))
      (error "handler exploded"))
    (should (string-match-p "exploded"
                            (cmacs-brigade-call-tool "test_boom"
                                                     "{\"a\":\"x\"}")))))

(ert-deftest cmacs-brigade-async-waits-and-times-out ()
  "An async tool's result is waited for; a stalled one times out."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-async "Async." ((a string "a"))
      :async t :timeout 5
      (run-at-time 0.05 nil (lambda () (funcall done (concat "got " a)))))
    (should (equal "got x" (cmacs-brigade-call-tool "test_async" "{\"a\":\"x\"}")))
    ;; A handler that never calls DONE must fail rather than hang the
    ;; caller forever -- this is the case that wedges an agent.
    (cmacs-brigade-deftool test-stall "Stalls." ((a string "a"))
      :async t :timeout 1
      (ignore a))
    (let ((res (cmacs-brigade-call-tool "test_stall" "{\"a\":\"x\"}")))
      (should (string-match-p "timed out" res)))))

(ert-deftest cmacs-brigade-before-hook-can-veto ()
  "A before-tool-call hook returning nil blocks the call."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-veto "Veto." ((a string "a")) "ran")
    (let ((cmacs-brigade-before-tool-call-functions (list (lambda (_) nil))))
      (should (string-match-p "vetoed"
                              (cmacs-brigade-call-tool "test_veto"
                                                       "{\"a\":\"x\"}"))))
    ;; and permits it when the hook approves
    (let ((cmacs-brigade-before-tool-call-functions (list (lambda (_) t))))
      (should (equal "ran" (cmacs-brigade-call-tool "test_veto"
                                                    "{\"a\":\"x\"}"))))))

(ert-deftest cmacs-brigade-confirm-refuses-when-it-cannot-ask ()
  "A :confirm tool is refused in batch rather than silently allowed."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-confirm "Needs confirmation." ((a string "a"))
      :confirm 'ask
      "ran")
    ;; noninteractive is t under ERT batch: "could not ask" must not
    ;; mean "went ahead anyway"
    (let ((out (cmacs-brigade-call-tool "test_confirm" "{\"a\":\"x\"}")))
      ;; refused, and the body did not run
      (should-not (equal "ran" out))
      (should (string-match-p "needs approval" out))
      ;; and it says how to allow it, since there is nowhere to ask
      (should (string-match-p "cmacs-brigade-auto-approve" out)))
    ;; an explicit confirm function is honoured
    (let ((cmacs-brigade-confirm-function (lambda (_) t)))
      (should (equal "ran" (cmacs-brigade-call-tool "test_confirm"
                                                    "{\"a\":\"x\"}"))))))


;;;; The authorisation gate

(ert-deftest cmacs-brigade-gate-basic-matching ()
  "Exact names, groups and the wildcard behave as documented."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-w "W." ((a string "a")) :group 'weather a)
    (should (cmacs-brigade-tool-allowed-p "test_w" "test_w"))
    (should (cmacs-brigade-tool-allowed-p "weather" "test_w"))
    (should (cmacs-brigade-tool-allowed-p "*" "test_w"))
    (should (cmacs-brigade-tool-allowed-p " weather , other " "test_w"))
    (should-not (cmacs-brigade-tool-allowed-p "other" "test_w"))))

(ert-deftest cmacs-brigade-gate-fails-closed ()
  "Empty, nil and malformed allowlists grant nothing."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (should-not (cmacs-brigade-tool-allowed-p "" "anything"))
  (should-not (cmacs-brigade-tool-allowed-p nil "anything"))
  (should-not (cmacs-brigade-tool-allowed-p "," "anything"))
  (should-not (cmacs-brigade-tool-allowed-p "   " "anything")))

(ert-deftest cmacs-brigade-gate-privileged-needs-explicit-grant ()
  "The privileged set is unreachable through `*' or a group.

This is the assertion that matters most in the file: if `*' ever admits
`eval', every agent granted broad access silently gains the ability to
run arbitrary Lisp in the editor."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (dolist (tool '("eval" "bash" "shell" "execute_command" "send_keys"
                  "cmacs_c_patch_defun" "crispy_eval" "bacon_eval"))
    (should (cmacs-brigade-tool-privileged-p tool))
    (should-not (cmacs-brigade-tool-allowed-p "*" tool))
    ;; named outright, it is granted -- the deliberate act the set exists
    ;; to require
    (should (cmacs-brigade-tool-allowed-p tool tool))))

(ert-deftest cmacs-brigade-gate-group-cannot-smuggle-privilege ()
  "A group grant never reaches a privileged tool, even if it is in one."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (cmacs-brigade-tests--with-clean-registry
    ;; A tool named `eval' filed under a harmless-looking group is
    ;; exactly the accident the rule guards against.
    (cmacs-brigade-register-tool :name 'eval :description "d"
                                 :handler #'ignore :group 'helpers)
    (should-not (cmacs-brigade-tool-allowed-p "helpers" "eval"))))

(ert-deftest cmacs-brigade-gate-blocks-recursion-prefixes ()
  "ai_ and brigade_ tools are refused unconditionally.

Otherwise an agent could spawn agents outside the orchestrator's budget
accounting, which is both a cost and a supervision hole."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (dolist (tool '("ai_call" "ai_prompt" "brigade_spawn" "brigade_status"))
    (should-not (cmacs-brigade-tool-allowed-p "*" tool))
    (should-not (cmacs-brigade-tool-allowed-p tool tool))
    (should-not (cmacs-brigade-tool-allowed-p (concat "*," tool) tool))))

(ert-deftest cmacs-brigade-allowlist-expansion ()
  "Groups expand to concrete names; unknown entries and `*' pass through.

The relay has no registry of its own, so a group name that survived to
that side would match nothing -- silently."
  (skip-unless (fboundp 'cmacs-brigade-allowlist-expand))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-e1 "1." ((a string "a")) :group 'grp a)
    (cmacs-brigade-deftool test-e2 "2." ((a string "a")) :group 'grp a)
    (let ((expanded (cmacs-brigade-allowlist-expand "grp")))
      (should (string-match-p "test_e1" expanded))
      (should (string-match-p "test_e2" expanded)))
    ;; Unknown names pass through: most of what an agent uses is a
    ;; built-in MCP tool this registry has never seen, and dropping
    ;; those would quietly strip nearly everything it was granted.
    (should (equal "project_read_file"
                   (cmacs-brigade-allowlist-expand "project_read_file")))
    (should (equal "*" (cmacs-brigade-allowlist-expand "*")))
    (should (equal "" (cmacs-brigade-allowlist-expand "")))))

(ert-deftest cmacs-brigade-tools-for-allowlist-filters-destructive ()
  "A read-only agent does not receive destructive tools it could name."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-safe "Safe." ((a string "a")) a)
    (cmacs-brigade-deftool test-danger "Danger." ((a string "a"))
      :destructive t a)
    (let ((ro (mapcar #'cmacs-brigade-tool-wire-name
                      (cmacs-brigade-tools-for-allowlist "*")))
          (rw (mapcar #'cmacs-brigade-tool-wire-name
                      (cmacs-brigade-tools-for-allowlist "*" t))))
      (should (member "test_safe" ro))
      (should-not (member "test_danger" ro))
      (should (member "test_danger" rw)))))


;;;; Other registries

(ert-deftest cmacs-brigade-registries-accept-symbol-or-string ()
  "A :name may be a symbol or a string and lands under the same key.

An agent defined in markdown frontmatter has a string name and one
written in Lisp has a symbol; a plan file must be able to reference
either interchangeably."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-register-agent :name "str-agent" :prompt "p")
  (cmacs-brigade-register-agent :name 'sym-agent :prompt "p")
  (should (cmacs-brigade-registry-get 'agent 'str-agent))
  (should (cmacs-brigade-registry-get 'agent 'sym-agent))
  (should (eq 'str-agent
              (plist-get (cmacs-brigade-registry-get 'agent 'str-agent) :name))))

(ert-deftest cmacs-brigade-registries-require-their-keys ()
  "Each registry rejects a registration missing what it needs to work."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (should-error (cmacs-brigade-register-agent :name 'a) :type 'cmacs-brigade-error)
  (should-error (cmacs-brigade-register-worker :name 'w) :type 'cmacs-brigade-error)
  (should-error (cmacs-brigade-register-isolation :name 'i)
                :type 'cmacs-brigade-error)
  (should-error (cmacs-brigade-register-memory-source
                 :name 'm :enumerate #'ignore)   ; no :read-chunk
                :type 'cmacs-brigade-error)
  (should-error (cmacs-brigade-register-panel :name 'p) :type 'cmacs-brigade-error)
  ;; and a nameless registration is rejected everywhere
  (should-error (cmacs-brigade-register-agent :prompt "p")
                :type 'cmacs-brigade-error))

(ert-deftest cmacs-brigade-all-registries-exist ()
  "Every registry named in the documentation is actually callable."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (dolist (kind '("tool" "agent" "worker" "isolation" "memory-source"
                  "deliverable" "panel" "context-provider"
                  "approval-handler"))
    (should (fboundp (intern (format "cmacs-brigade-register-%s" kind))))))

(provide 'cmacs-brigade-registry-tests)

;;; cmacs-brigade-registry-tests.el ends here
