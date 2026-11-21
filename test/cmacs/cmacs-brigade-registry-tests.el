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
                saved)
       ;; And the C mirror, which the body emptied: restoring only the
       ;; Lisp table left every real tool unpublished for the rest of
       ;; the run, which nothing noticed while each had a C twin.
       (when (fboundp 'cmacs-brigade-registry-remirror)
         (cmacs-brigade-registry-remirror)))))


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
  "A :confirm tool is refused rather than silently allowed.

Exercised with `cmacs-brigade-auto-approve' bound to nil: it ships as t,
so this path is only reached by a user who asked to be consulted, and
what must hold for them is that being unable to ask does not become
going ahead anyway."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-confirm "Needs confirmation." ((a string "a"))
      :confirm 'ask
      "ran")
    ;; noninteractive is t under ERT batch: "could not ask" must not
    ;; mean "went ahead anyway"
    (let* ((cmacs-brigade-auto-approve nil)
           (out (cmacs-brigade-call-tool "test_confirm" "{\"a\":\"x\"}")))
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
  "With the restriction on, the privileged set needs naming outright.

Ships off: `*' grants everything, which is the user's call to make about
their own editor.  What is asserted here is that the escape hatch works
for someone who wants those tools back behind a deliberate act, since a
documented switch that does nothing would be worse than none."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (dolist (tool '("eval" "bash" "shell" "execute_command" "send_keys"
                  "cmacs_c_patch_defun" "crispy_eval" "bacon_eval"))
    (should (cmacs-brigade-tool-privileged-p tool))
    (let ((cmacs-brigade-restrict-privileged-tools t))
      (should-not (cmacs-brigade-tool-allowed-p "*" tool)))
    ;; named outright it is granted either way
    (should (cmacs-brigade-tool-allowed-p tool tool))
    ;; and by default the wildcard reaches it
    (should (cmacs-brigade-tool-allowed-p "*" tool))))

(ert-deftest cmacs-brigade-gate-group-cannot-smuggle-privilege ()
  "With the restriction on, a group grant never reaches a privileged tool."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (cmacs-brigade-tests--with-clean-registry
    ;; A tool named `eval' filed under a harmless-looking group is
    ;; exactly the accident that rule guards against.
    (cmacs-brigade-register-tool :name 'eval :description "d"
                                 :handler #'ignore :group 'helpers)
    (let ((cmacs-brigade-restrict-privileged-tools t))
      (should-not (cmacs-brigade-tool-allowed-p "helpers" "eval")))
    ;; off by default, so the group does reach it
    (should (cmacs-brigade-tool-allowed-p "helpers" "eval"))))

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

;;;; Structured parameters: arrays and objects

(defmacro cmacs-brigade-tests--with-team-tool (&rest body)
  "Run BODY with `test_team' registered: every structured shape at once.
Its handler returns its arguments as a list, so a test can look at
exactly what a body receives."
  (declare (indent 0))
  `(cmacs-brigade-tests--with-clean-registry
     (cmacs-brigade-deftool test-team "Team."
         ((name string "Team name")
          (members array "Window ids" :items integer)
          (rule object "Who joins" :optional t
                :properties ((app string "App id")
                             (title string "Title" :optional t)
                             (on boolean "Enabled" :optional t)
                             (mode string "Mode" :optional t
                                   :enum ("all" "one"))))
          (extra object "Anything" :optional t)
          (steps array "Steps" :optional t
                 :items (object :properties ((key string "Key")
                                             (times integer "Repeat"
                                                    :optional t)))))
       (list name members rule extra steps))
     ,@body))

(defun cmacs-brigade-tests--team-param (name)
  "Return the parsed parameter NAME of `test_team'."
  (cl-find name (cmacs-brigade-tool-params
                 (cmacs-brigade-registry-get 'tool 'test-team))
           :key (lambda (p) (plist-get p :name)) :test #'equal))

(ert-deftest cmacs-brigade-structured-types-are-declared ()
  "`array' and `object' parse, with :items and :properties, and nest."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    (should (equal (plist-get (cmacs-brigade-tests--team-param "members")
                              :items)
                   '(:type "integer")))
    (let ((rule (cmacs-brigade-tests--team-param "rule")))
      (should (equal (plist-get rule :type) "object"))
      (should (equal (mapcar (lambda (p) (plist-get p :name))
                             (plist-get rule :properties))
                     '("app" "title" "on" "mode")))
      ;; Members are parameters: required unless marked optional.
      (should (plist-get (car (plist-get rule :properties)) :required))
      (should-not (plist-get (cadr (plist-get rule :properties)) :required)))
    ;; A free-form object carries neither key.
    (should-not (plist-member (cmacs-brigade-tests--team-param "extra")
                              :properties))
    ;; An array of objects: the element is itself a schema.
    (should (equal (plist-get
                    (plist-get (cmacs-brigade-tests--team-param "steps")
                               :items)
                    :type)
                   "object"))
    ;; A scalar parameter's plist is what it always was.
    (should-not (plist-member (cmacs-brigade-tests--team-param "name")
                              :items))))

(ert-deftest cmacs-brigade-structured-types-reject-nonsense ()
  "Keys that would be ignored on every surface are refused at definition."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (dolist (params '(((x string "d" :items string))
                      ((x array "d" :properties ((a string "d"))))
                      ((x array "d" :items frobnicate))
                      ((x object "d" :properties ((a frobnicate "d"))))
                      ((x object "d" :properties ((a string))))))
      (ert-info ((format "%S" params))
        (should-error (cmacs-brigade-register-tool
                       :name 'bad :description "d" :handler #'ignore
                       :params params)
                      :type 'cmacs-brigade-tool-error)))))

(ert-deftest cmacs-brigade-structured-value-shapes ()
  "Whatever a surface delivers, a body sees a list or a symbol-keyed alist."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    (let ((members (cmacs-brigade-tests--team-param "members"))
          (rule (cmacs-brigade-tests--team-param "rule"))
          (extra (cmacs-brigade-tests--team-param "extra"))
          (steps (cmacs-brigade-tests--team-param "steps"))
          (hash (make-hash-table :test 'equal)))
      ;; An array: JSON text, a vector, a list -- one answer.  Declared
      ;; integers arrive as integers however they were spelt.
      (dolist (given (list "[1, \"2\", 3.0]" [1 "2" 3.0] '(1 "2" 3.0)))
        (should (equal (cmacs-brigade-structured-value given members)
                       '(1 2 3))))
      (should (null (cmacs-brigade-structured-value "[]" members)))
      (should (null (cmacs-brigade-structured-value "" members)))
      ;; An object: JSON text, a hash table, an alist with string keys.
      (puthash "app" "foot" hash)
      (puthash "on" :false hash)
      (dolist (given (list "{\"app\":\"foot\",\"on\":false}" hash
                           '(("app" . "foot") ("on" . :false))))
        (should (equal (cmacs-brigade-structured-value given rule)
                       '((app . "foot") (on)))))
      ;; Members the schema does not list are kept, in order.
      (should (equal (cmacs-brigade-structured-value
                      "{\"app\":\"a\",\"zzz\":[1,2]}" rule)
                     '((app . "a") (zzz 1 2))))
      ;; Free-form: parsed, and otherwise left alone.
      (should (equal (cmacs-brigade-structured-value
                      "{\"a\":{\"b\":[true,false,null,\"x\"]}}" extra)
                     '((a (b t :false nil "x")))))
      ;; An array of objects, each checked against the element schema.
      (should (equal (cmacs-brigade-structured-value
                      "[{\"key\":\"a\"},{\"key\":\"b\",\"times\":\"2\"}]"
                      steps)
                     '(((key . "a")) ((key . "b") (times . 2))))))))

(ert-deftest cmacs-brigade-structured-value-errors-name-the-path ()
  "A value that does not fit is refused with the argument and the path."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    (pcase-dolist (`(,param ,given ,want)
                   '(("members" "[1, \"x\"]" "members\\[1\\].*integer")
                     ("members" "{\"a\":1}" "members.*array, not an object")
                     ("members" "3" "members.*JSON array")
                     ("members" "[1," "members.*JSON array")
                     ("rule" "[1]" "rule.*object, not an array")
                     ("rule" "{}" "rule\\.app.*required")
                     ("rule" "{\"app\":null}" "rule\\.app.*required")
                     ("rule" "{\"app\":\"a\",\"on\":\"maybe\"}"
                      "rule\\.on.*true or false")
                     ("rule" "{\"app\":\"a\",\"mode\":\"some\"}"
                      "rule\\.mode.*one of: all, one")
                     ("steps" "[{\"key\":\"a\"},{}]"
                      "steps\\[1\\]\\.key.*required")))
      (ert-info ((format "%s <- %s" param given))
        (let ((err (should-error
                    (cmacs-brigade-structured-value
                     given (cmacs-brigade-tests--team-param param)))))
          (should (string-match-p want (error-message-string err))))))))

(ert-deftest cmacs-brigade-structured-arguments-reach-the-handler ()
  "A tool call hands the body Lisp data; a bad argument is a failed call."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    ;; As a provider or an MCP client sends it: one JSON object.
    (should (equal (read (cmacs-brigade-call-tool
                          "test_team"
                          "{\"name\":\"raid\",\"members\":[3,4],
                            \"rule\":{\"app\":\"foot\",\"on\":true},
                            \"extra\":{\"k\":[1]},
                            \"steps\":[{\"key\":\"a\"}]}"))
                   '("raid" (3 4) ((app . "foot") (on . t)) ((k 1))
                     (((key . "a"))))))
    ;; A model that stringified the array still gets through.
    (should (equal (read (cmacs-brigade-call-tool
                          "test_team"
                          "{\"name\":\"raid\",\"members\":\"[3,4]\"}"))
                   '("raid" (3 4) nil nil nil)))
    ;; An optional object that was not given is nil, NOT the empty
    ;; object: that would demand its required members.
    (should (equal (read (cmacs-brigade-call-tool
                          "test_team" "{\"name\":\"raid\",\"members\":[]}"))
                   '("raid" nil nil nil nil)))
    ;; A wrong element is an error the model can read and act on.
    (should (string-match-p
             "\\`Error: argument `members\\[0\\]' must be an integer"
             (cmacs-brigade-call-tool
              "test_team" "{\"name\":\"raid\",\"members\":[\"x\"]}")))
    ;; The handler is the wrapped one, so a direct call -- the menu, a
    ;; test -- converts too.
    (should (equal (funcall (cmacs-brigade-tool-handler
                             (cmacs-brigade-registry-get 'tool 'test-team))
                            "raid" "[1]" "{\"app\":\"a\"}" nil nil)
                   '("raid" (1) ((app . "a")) nil nil)))))

(ert-deftest cmacs-brigade-structured-async-handler-keeps-done ()
  "The wrapper leaves an :async handler's DONE argument alone."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    (cmacs-brigade-deftool test-later "Later."
        ((items array "Items" :items string))
      :async t
      (funcall done (mapconcat #'identity items "+")))
    (should (equal (cmacs-brigade-call-tool
                    "test_later" "{\"items\":[\"a\",\"b\"]}")
                   "a+b"))))

(ert-deftest cmacs-brigade-structured-schema-for-the-mirror ()
  "The JSON handed to the C mirror carries each structured schema whole."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    (let* ((json (cmacs-brigade--params-json
                  (cmacs-brigade-tool-params
                   (cmacs-brigade-registry-get 'tool 'test-team))))
           (params (json-parse-string json :object-type 'alist
                                      :array-type 'list))
           (by-name (lambda (name)
                      (cl-find name params :test #'equal
                               :key (lambda (p) (alist-get 'name p))))))
      ;; A scalar is exactly what it was before these types existed, so
      ;; a mirror built by an older binary reads it unchanged.
      (should (equal (funcall by-name "name")
                     '((name . "name") (type . "string")
                       (description . "Team name") (required . t))))
      (should (equal (alist-get 'schema (funcall by-name "members"))
                     '((type . "array") (description . "Window ids")
                       (items (type . "integer")))))
      (let ((rule (alist-get 'schema (funcall by-name "rule"))))
        (should (equal (alist-get 'type rule) "object"))
        (should (equal (alist-get 'required rule) '("app")))
        (should (equal (alist-get 'mode (alist-get 'properties rule))
                       '((type . "string") (description . "Mode")
                         (enum "all" "one")))))
      ;; Free-form: the bare type, which is JSON Schema for "anything".
      (should (equal (alist-get 'schema (funcall by-name "extra"))
                     '((type . "object") (description . "Anything"))))
      (should (equal (alist-get
                      'required
                      (alist-get 'items
                                 (alist-get 'schema
                                            (funcall by-name "steps"))))
                     '("key"))))))

(ert-deftest cmacs-brigade-structured-provider-params ()
  "What an in-process provider is given: an item schema, and named members."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    (let ((params (cmacs-brigade-tool-provider-params
                   (cmacs-brigade-registry-get 'tool 'test-team))))
      ;; Scalars: the four elements `cmacs-ai-tools-register' always took.
      (should (equal (nth 0 params) '("name" "string" "Team name" t)))
      ;; An array says what one element is: a bare array is a schema
      ;; Gemini refuses and the others guess at.
      (should (equal (nth 1 params)
                     '("members" "array" "Window ids" t
                       "{\"type\":\"integer\"}")))
      ;; ai-glib has no nested properties, so an object's members are
      ;; named where a model will read them.
      (should (equal (nth 1 (nth 2 params)) "object"))
      (should (string-match-p "app (string), title (string, optional)"
                              (nth 2 (nth 2 params))))
      (should (= (length (nth 2 params)) 4))
      (should (equal (nth 3 params) '("extra" "object" "Anything" nil)))
      (should (string-match-p "\"required\":\\[\"key\"\\]"
                              (nth 4 (nth 4 params)))))))

(ert-deftest cmacs-brigade-structured-json-round-trips ()
  "`cmacs-brigade-structured-json' writes back what a body received."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-team-tool
    (let ((extra (cmacs-brigade-tests--team-param "extra"))
          (rule (cmacs-brigade-tests--team-param "rule"))
          (members (cmacs-brigade-tests--team-param "members")))
      (dolist (text '("{\"name\":\"raid\",\"slots\":[{\"name\":\"a\",\"on\":false}],\"groups\":{\"all\":[\"a\",\"b\"]}}"
                      "{\"n\":[[1,2],[true,3]],\"s\":\"x y\",\"f\":1.5}"))
        (should (equal (cmacs-brigade-structured-json
                        (cmacs-brigade-structured-value text extra) extra)
                       text)))
      ;; The declared type settles what nil is at the top...
      (should (equal (cmacs-brigade-structured-json nil extra) "{}"))
      (should (equal (cmacs-brigade-structured-json nil members) "[]"))
      ;; ...and what a declared boolean member is.
      (should (equal (cmacs-brigade-structured-json
                      (cmacs-brigade-structured-value
                       "{\"app\":\"a\",\"on\":false}" rule)
                      rule)
                     "{\"app\":\"a\",\"on\":false}"))
      ;; The documented limit: an empty container nested in free-form
      ;; data has become nil by the time a body sees it, and is null.
      (should (equal (cmacs-brigade-structured-json
                      (cmacs-brigade-structured-value "{\"e\":{},\"l\":[]}"
                                                      extra)
                      extra)
                     "{\"e\":null,\"l\":null}")))))

(ert-deftest cmacs-brigade-structured-menu-tools ()
  "The menu never offers a tool it cannot run, and asks for JSON as JSON."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (cmacs-brigade-tests--with-clean-registry
    ;; The first parameter receives the clicked thing as text.
    (should-error (cmacs-brigade-register-tool
                   :name 'bad :description "d" :handler #'ignore :menu t
                   :params '((targets array "Targets" :items string)))
                  :type 'cmacs-brigade-tool-error)
    ;; Off the menu surface there is nothing to refuse.
    (should (cmacs-brigade-register-tool
             :name 'fine :description "d" :handler #'ignore :menu t
             :surfaces '(mcp agents)
             :params '((targets array "Targets" :items string))))
    ;; A later structured parameter is fine: it is read as JSON.
    (cmacs-brigade-deftool test-tag "Tag."
        ((text string "What") (tags array "Tags" :items string))
      :menu t
      (list text tags))
    (let* ((tool (cmacs-brigade-registry-get 'tool 'test-tag))
           (param (cadr (cmacs-brigade-tool-params tool)))
           (prompts nil))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (prompt &rest _)
                   (push prompt prompts)
                   "[\"a\", \"b\"]")))
        ;; Parsed at the prompt, and the prompt says what is wanted.
        (should (equal (cmacs-brigade-read-param param) '("a" "b")))
        (should (string-match-p "JSON, array of string" (car prompts)))
        ;; A scalar is still read as plain text.
        (should (equal (cmacs-brigade-read-param
                        (car (cmacs-brigade-tool-params tool)))
                       "[\"a\", \"b\"]")))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "nope")))
        (should-error (cmacs-brigade-read-param param))))))

(defun cmacs-brigade-tests--mcp-exchange (path requests want)
  "Send REQUESTS, a list of JSON-RPC lines, to the MCP socket at PATH.
Return everything received once the regexp WANT has matched, or after
ten seconds."
  (let* ((out "")
         (proc (make-network-process
                :name "brigade-structured-test" :family 'local :service path
                :noquery t :coding 'utf-8-unix
                :filter (lambda (_p s) (setq out (concat out s))))))
    (unwind-protect
        (progn
          (process-send-string
           proc
           (concat
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
            "\"params\":{\"protocolVersion\":\"2024-11-05\","
            "\"capabilities\":{},\"clientInfo\":{\"name\":\"ert\","
            "\"version\":\"0\"}}}\n"
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
            (mapconcat (lambda (r) (concat r "\n")) requests "")))
          (let ((deadline (+ (float-time) 10)))
            (while (and (< (float-time) deadline)
                        (not (string-match-p want out)))
              (accept-process-output proc 0.1)))
          out)
      (ignore-errors (delete-process proc)))))

(ert-deftest cmacs-brigade-structured-over-the-mcp-socket ()
  "The wire path: a structured argument through a real MCP session.

Everything above calls Lisp directly.  This one connects to a scoped
socket and speaks JSON-RPC, so the arguments go through the C
publisher's handler -- re-serialised, escaped, evaluated -- and the
schema an MCP client is shown comes from the C mirror."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (skip-unless (fboundp 'cmacs-brigade-scope-open))
  (cmacs-brigade-tests--with-team-tool
    (let* ((path (cmacs-brigade-scope-open "test_team"))
           (out (unwind-protect
                    (cmacs-brigade-tests--mcp-exchange
                     path
                     (list
                      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}"
                      (concat
                       "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
                       "\"params\":{\"name\":\"test_team\",\"arguments\":"
                       "{\"name\":\"raid\",\"members\":[3,4],"
                       "\"rule\":{\"app\":\"foot \\\"q\\\"\",\"on\":false},"
                       "\"steps\":[{\"key\":\"a\"}]}}}")
                      (concat
                       "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\","
                       "\"params\":{\"name\":\"test_team\",\"arguments\":"
                       "{\"name\":\"raid\",\"members\":[\"x\"]}}}"))
                     "\"id\":4")
                  (cmacs-brigade-scope-close path)))
           (replies (mapcar (lambda (line)
                              (ignore-errors
                                (json-parse-string line :object-type 'alist
                                                   :array-type 'list)))
                            (split-string out "\n" t)))
           (reply (lambda (id)
                    (cl-find id replies :key (lambda (r) (alist-get 'id r))))))
      ;; The call: the body received a list and an alist, with the quote
      ;; inside a member intact, and printed them back.
      (let* ((result (alist-get 'result (funcall reply 3)))
             (text (alist-get 'text (car (alist-get 'content result)))))
        (should result)
        (should-not (eq (alist-get 'isError result) t))
        (should (equal (read text)
                       '("raid" (3 4) ((app . "foot \"q\"") (on)) nil
                         (((key . "a")))))))
      ;; A bad element is an MCP error carrying the path.
      (let* ((result (alist-get 'result (funcall reply 4)))
             (text (alist-get 'text (car (alist-get 'content result)))))
        (should (eq (alist-get 'isError result) t))
        (should (string-match-p "members\\[0\\].*integer" text)))
      ;; The schema.  Only a binary whose mirror carries per-parameter
      ;; schemas can publish `items'; an older one publishes the bare
      ;; type, which is what the mirror's docstring tells apart.
      (let* ((tool (cl-find "test_team"
                            (alist-get 'tools
                                       (alist-get 'result (funcall reply 2)))
                            :test #'equal
                            :key (lambda (tool) (alist-get 'name tool))))
             (props (alist-get 'properties (alist-get 'inputSchema tool))))
        (should tool)
        (should (equal (alist-get 'type (alist-get 'members props)) "array"))
        (should (equal (alist-get 'type (alist-get 'rule props)) "object"))
        (when (string-match-p "\"schema\" member"
                              (or (documentation 'cmacs-brigade--mirror-put t)
                                  ""))
          (should (equal (alist-get 'items (alist-get 'members props))
                         '((type . "integer"))))
          (should (equal (alist-get 'required (alist-get 'rule props))
                         '("app")))
          (should (equal (alist-get
                          'type
                          (alist-get 'key
                                     (alist-get
                                      'properties
                                      (alist-get 'items
                                                 (alist-get 'steps props)))))
                         "string")))))))

(provide 'cmacs-brigade-registry-tests)

;;; cmacs-brigade-registry-tests.el ends here

;;; The gate's newer members and the pseudo tools

(ert-deftest cmacs-brigade-gate-recording-and-js-are-privileged ()
  "Input recording and browser JavaScript joined the privileged set.

Both hand an agent something the user did not type for it: what they
really type, and their logged-in sessions.  Named outright they work;
with the restriction on, `*' no longer sweeps them in."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (dolist (tool '("gowl_start_recording" "gowl_drain_recording"
                  "gowl_stop_recording" "gsurf_eval_js"))
    (should (cmacs-brigade-tool-privileged-p tool))
    (should (cmacs-brigade-tool-allowed-p tool tool))
    (let ((cmacs-brigade-restrict-privileged-tools t))
      (should-not (cmacs-brigade-tool-allowed-p "*" tool)))))

(ert-deftest cmacs-brigade-gate-pseudo-tools-follow-the-allowlist ()
  "`resources' and `prompts' are granted by `*' or by name, never for free.

The relay gates resources/read and prompts/get on these, so an
allowlist of two read-only tools does not also hand over every buffer
and any file on disk through file://."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (should (cmacs-brigade-tool-allowed-p "*" "resources"))
  (should (cmacs-brigade-tool-allowed-p "resources,project_read_file" "resources"))
  (should-not (cmacs-brigade-tool-allowed-p "project_read_file" "resources"))
  (should (cmacs-brigade-tool-allowed-p "prompts" "prompts"))
  (should-not (cmacs-brigade-tool-allowed-p "project_read_file" "prompts")))

(ert-deftest cmacs-brigade-gate-recursion-block-is-a-switch ()
  "`cmacs-brigade-block-recursive-tools' nil lets ai_* through by name.

The default stays t; the point is that the editor's answer and the
relay's answer come from the same explicit policy value, which the
provisioner exports as CMACS_BRIGADE_BLOCK_RECURSIVE."
  (skip-unless (fboundp 'cmacs-brigade-tool-allowed-p))
  (should-not (cmacs-brigade-tool-allowed-p "ai_call" "ai_call"))
  (let ((cmacs-brigade-block-recursive-tools nil))
    (should (cmacs-brigade-tool-allowed-p "ai_call" "ai_call"))))

(ert-deftest cmacs-brigade-async-tool-waits-without-reading-events ()
  "An :async tool called under `inhibit-interaction' is waited for, not failed.

The RPC dispatch binds `inhibit-interaction' around every MCP call, and
`sit-for' reads an event, which signals there.  Batch never sees that --
its `sit-for' is `sleep-for' -- so the stub below makes it behave as it
does in a session with a display."
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (unwind-protect
      (progn
        (eval '(cmacs-brigade-deftool test-async-wait "Answer later." ()
                 :async t :timeout 5
                 (run-at-time 0.05 nil done "late answer"))
              t)
        (cl-letf (((symbol-function 'sit-for)
                   (lambda (&rest _)
                     (when (bound-and-true-p inhibit-interaction)
                       (signal 'inhibited-interaction nil))
                     (sleep-for 0.05))))
          (let ((inhibit-interaction t))
            (should (equal (cmacs-brigade-call-tool "test_async_wait" "{}"
                                                    "mcp")
                           "late answer")))
          ;; And with a user to interact with, the wait is `sit-for' still.
          (should (equal (cmacs-brigade-call-tool "test_async_wait" "{}")
                         "late answer"))))
    (cmacs-brigade-unregister-tool 'test-async-wait)))

(ert-deftest cmacs-brigade-scope-task-is-the-servers-not-the-clients ()
  "A scope's task reaches `cmacs-brigade-call-tool'; a client's claim does not.

The hook sees every call the socket's sessions make.  What it is told
about the task is what `cmacs-brigade-scope-open' was told, for every
scope at once and whatever the arguments say."
  (skip-unless (fboundp 'cmacs-brigade-scope-open))
  (skip-unless (equal (func-arity 'cmacs-brigade-scope-open) '(1 . 2)))
  (skip-unless (cmacs-brigade-registry-tests--available-p))
  (let* ((seen nil)
         (note (lambda (request)
                 (when (equal (plist-get request :tool) "test_scope_task")
                   (push (list (plist-get request :task)
                               (plist-get request :agent))
                         seen))
                 t))
         (scopes nil)
         (call
          (lambda (task arguments)
            (let* ((path (car (push (if (eq task 'none)
                                        (cmacs-brigade-scope-open
                                         "test_scope_task")
                                      (cmacs-brigade-scope-open
                                       "test_scope_task" task))
                                    scopes)))
                   (out "")
                   (proc (make-network-process
                          :name "brigade-scope-task-test" :family 'local
                          :service path :noquery t :coding 'utf-8-unix
                          :filter (lambda (_p s) (setq out (concat out s))))))
              (unwind-protect
                  (progn
                    (process-send-string
                     proc
                     (concat
                      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                      "\"params\":{\"protocolVersion\":\"2024-11-05\","
                      "\"capabilities\":{},\"clientInfo\":{\"name\":\"ert\","
                      "\"version\":\"0\"}}}\n"
                      "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
                      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\","
                      "\"params\":{\"name\":\"test_scope_task\",\"arguments\":"
                      arguments "}}\n"))
                    (let ((deadline (+ (float-time) 10)))
                      (while (and (< (float-time) deadline)
                                  (not (string-match-p "\"id\":2" out)))
                        (accept-process-output proc 0.1)))
                    (should (string-match-p "\"id\":2" out))
                    (should (string-match-p "scope-task-ok" out)))
                (ignore-errors (delete-process proc)))))))
    (unwind-protect
        (progn
          (eval '(cmacs-brigade-deftool test-scope-task "Answer." ()
                   "scope-task-ok")
                t)
          (add-hook 'cmacs-brigade-before-tool-call-functions note)
          (funcall call "task-A" "{}")
          (funcall call "task-B" "{\"task\":\"task-A\"}")
          (funcall call 'none "{\"task\":\"task-A\"}")
          (funcall call "" "{}")
          ;; Quotes, a backslash, a newline and non-ASCII survive as data.
          (funcall call "t\"x\\y\nz é" "{}")
          (should (equal (reverse seen)
                         '(("task-A" "mcp") ("task-B" "mcp")
                           (nil "mcp") (nil "mcp")
                           ("t\"x\\y\nz é" "mcp")))))
      (remove-hook 'cmacs-brigade-before-tool-call-functions note)
      (cmacs-brigade-unregister-tool 'test-scope-task)
      (dolist (scope scopes)
        (ignore-errors (cmacs-brigade-scope-close scope))))))

;;; Scoped sockets

(ert-deftest cmacs-brigade-scope-open-close-round-trip ()
  "A scope is a real socket in the runtime dir, listed while open, gone after."
  (skip-unless (fboundp 'cmacs-brigade-scope-open))
  (let ((path (cmacs-brigade-scope-open "project_read_file")))
    (unwind-protect
        (progn
          (should (stringp path))
          (should (file-exists-p path))
          (should (string-match-p "/brigade/mcp-[0-9]+-" path))
          (should (equal (file-modes path) #o600))
          (should (assoc path (cmacs-brigade-scope-list)))
          (should (equal (cdr (assoc path (cmacs-brigade-scope-list)))
                         "project_read_file")))
      (should (cmacs-brigade-scope-close path)))
    (should-not (file-exists-p path))
    (should-not (assoc path (cmacs-brigade-scope-list)))
    (should-not (cmacs-brigade-scope-close path))))

(ert-deftest cmacs-brigade-scope-serves-only-the-allowlist ()
  "A client on the scoped socket sees the allowlisted tools and nothing else.

Talks MCP over the socket with `make-network-process': initialize, then
tools/list.  This is the property the whole arrangement exists for --
the allowlist is enforced by the process that owns the tools, so the
relay is no longer the only thing between an agent and `eval'."
  (skip-unless (fboundp 'cmacs-brigade-scope-open))
  (let* ((path (cmacs-brigade-scope-open "project_read_file,project_root"))
         (out "")
         (proc (make-network-process
                :name "brigade-scope-test" :family 'local :service path
                :noquery t :coding 'utf-8-unix
                :filter (lambda (_p s) (setq out (concat out s))))))
    (unwind-protect
        (progn
          (process-send-string
           proc
           (concat "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                   "\"params\":{\"protocolVersion\":\"2024-11-05\","
                   "\"capabilities\":{},\"clientInfo\":{\"name\":\"ert\","
                   "\"version\":\"0\"}}}\n"
                   "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
                   "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n"))
          (let ((deadline (+ (float-time) 10)))
            (while (and (< (float-time) deadline)
                        (not (string-match-p "\"id\":2" out)))
              (accept-process-output proc 0.1)
              (sit-for 0.05)))
          (should (string-match-p "\"id\":2" out))
          (should (string-match-p "project_read_file" out))
          (should (string-match-p "project_root" out))
          (should-not (string-match-p "\"name\":\"eval\"" out))
          (should-not (string-match-p "\"name\":\"get_buffer_content\"" out)))
      (ignore-errors (delete-process proc))
      (cmacs-brigade-scope-close path))))
