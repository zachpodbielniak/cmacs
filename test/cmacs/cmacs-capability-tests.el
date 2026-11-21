;;; cmacs-capability-tests.el --- The one capability table  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The tool registry is the table every surface derives from, so these
;; tests are about what a surface would get wrong if the table lied:
;;
;;   - the description (`cmacs-capability-describe') and its JSON
;;   - the ONE rule that turns a tool into `emacsctl tool GROUP VERB'
;;   - which tools are on which surface, including the rule that a
;;     destructive tool is not on D-Bus or the CLI until it says so
;;   - JSON arguments becoming typed parameters, and being refused
;;   - an async call being answered exactly once
;;   - an old `cmacs-brigade-deftool' form meaning what it always did
;;   - the migrated calculator family still matching the C it replaces
;;   - the checked-in reference not having gone stale
;;
;; Everything runs against a private registry: each test rebinds the
;; registry table, and the C mirror is stubbed, so nothing registered
;; here reaches the MCP surface of the Emacs running the tests.

;;; Code:

(require 'cmacs)
(require 'ert)
(require 'cl-lib)
(require 'cmacs-brigade-registry)
(require 'cmacs-brigade-tools)
(require 'cmacs-capability)
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

;; Defined in cmacs/dbus/cmacs-dbus-iface-tools.c; the one test that
;; calls them for real is gated on `fboundp'.
(declare-function cmacs-capability--dbus-reply "cmacs-dbus-iface-tools.c"
                  (token kind text))
(declare-function cmacs-capability--dbus-pending "cmacs-dbus-iface-tools.c"
                  ())

(defmacro cmacs-capability-tests--with-registry (&rest body)
  "Run BODY with an empty tool registry and the C mirror stubbed out."
  (declare (indent 0) (debug t))
  `(let ((cmacs-brigade--registries (make-hash-table :test 'eq))
         (cmacs-brigade-tool-registered-functions nil)
         (cmacs-brigade-before-tool-call-functions nil)
         (cmacs-brigade-after-tool-call-functions nil)
         (cmacs-brigade-confirm-function nil)
         (cmacs-brigade-auto-approve t))
     (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                (lambda (&rest _) t))
               ((symbol-function 'cmacs-brigade--mirror-remove)
                (lambda (&rest _) t)))
       ,@body)))

(defun cmacs-capability-tests--source-root ()
  "Return the source tree's root, or nil when it cannot be found."
  (let ((dir (locate-dominating-file
              (or load-file-name buffer-file-name default-directory)
              "lisp/cmacs/cmacs-capability.el")))
    (and dir (file-name-as-directory (expand-file-name dir)))))

(defun cmacs-capability-tests--call (name json &optional surface)
  "Call NAME with JSON on SURFACE; return the list of (KIND TEXT) replies."
  (let ((replies nil))
    (cmacs-capability-call name json (or surface 'dbus)
                           (lambda (kind text)
                             (push (list kind text) replies)))
    (nreverse replies)))


;;;; Backward compatibility

(ert-deftest cmacs-capability-test-old-style-deftool ()
  "A form written before the capability keys existed is unchanged."
  (cmacs-capability-tests--with-registry
    (let ((seen nil))
      (cmacs-brigade-deftool weather-now
          "Current conditions for a place."
          ((place string "City or 'lat,lon'")
           (days integer "Days ahead" :optional t :default 1))
        :group 'weather :destructive nil :timeout 30
        (setq seen (list place days))
        (format "%s/%s" place days))
      (let ((tool (cmacs-brigade-registry-get 'tool 'weather-now)))
        (should (cmacs-brigade-tool-p tool))
        (should (equal (cmacs-brigade-tool-wire-name tool) "weather_now"))
        (should (eq (cmacs-brigade-tool-group tool) 'weather))
        (should (= (cmacs-brigade-tool-timeout tool) 30))
        ;; The new slots default to "not said".
        (should (null (cmacs-brigade-tool-surfaces tool)))
        (should (null (cmacs-brigade-tool-cli tool)))
        (should (eq (cmacs-brigade-tool-returns tool) 'string))
        (should (null (cmacs-brigade-tool-aliases tool)))
        ;; ... and "not said" means every surface.
        (should (equal (cmacs-brigade-tool-effective-surfaces tool)
                       cmacs-brigade-tool-surfaces)))
      ;; The blocking path the providers use still works as before.
      (should (equal (cmacs-brigade-call-tool
                      "weather_now" "{\"place\":\"Oslo\"}" "test")
                     "Oslo/1"))
      (should (equal seen '("Oslo" 1)))
      (should (string-prefix-p
               "Error: " (cmacs-brigade-call-tool "weather_now" "{}"))))))

(ert-deftest cmacs-capability-test-old-style-async-deftool ()
  "An old :async form still completes through the blocking path."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool slow-echo
        "Echo, asynchronously."
        ((text string "Text"))
      :async t :timeout 5
      (funcall done (upcase text)))
    (should (equal (cmacs-brigade-call-tool "slow_echo" "{\"text\":\"hi\"}")
                   "HI"))))

(ert-deftest cmacs-capability-test-metadata-validation ()
  "Bad capability keys are refused at registration, not at call time."
  (cmacs-capability-tests--with-registry
    (cl-flet ((reg (&rest keys)
                (apply #'cmacs-brigade-register-tool
                       :name 'x :description "d" :handler #'ignore keys)))
      (should-error (reg :surfaces '(mcp telepathy))
                    :type 'cmacs-brigade-tool-error)
      (should-error (reg :cli "oneword") :type 'cmacs-brigade-tool-error)
      (should-error (reg :cli "Three Word verb")
                    :type 'cmacs-brigade-tool-error)
      ;; `emacsctl tool list' is the listing, not a tool group.
      (should-error (reg :cli "list things") :type 'cmacs-brigade-tool-error)
      (should-error (reg :returns 'xml) :type 'cmacs-brigade-tool-error)
      (should-error (reg :example 42) :type 'cmacs-brigade-tool-error)
      (should (eq (reg :cli "desk go" :returns 'json :surfaces '(dbus cli))
                  'x)))))


;;;; describe

(ert-deftest cmacs-capability-test-describe-shape ()
  "The table has one entry per tool with every documented member."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool desktop-launch
        "Start a program.  More words."
        ((command string "What to run")
         (wait boolean "Wait for exit" :optional t)
         (mode string "How" :optional t :enum ("fg" "bg") :default "fg"))
      :group 'desktop :confirm 'ask :async t :timeout 9
      :returns 'json :example "emacsctl tool desktop launch --command ls"
      :aliases '(run-program)
      (funcall done command wait mode))
    (let* ((table (cmacs-capability-describe))
           (e (car table)))
      (should (= (length table) 1))
      (dolist (key '(:name :description :group :params :destructive :confirm
                           :async :timeout :surfaces :cli :returns :example
                           :aliases))
        (should (plist-member e key)))
      (should (equal (plist-get e :name) "desktop_launch"))
      (should (equal (plist-get e :group) "desktop"))
      (should (equal (plist-get e :cli) "desktop launch"))
      (should (eq (plist-get e :confirm) 'ask))
      (should (eq (plist-get e :async) t))
      (should (= (plist-get e :timeout) 9))
      (should (eq (plist-get e :returns) 'json))
      (should (equal (plist-get e :aliases) '("run_program")))
      (should (equal (plist-get e :surfaces) cmacs-brigade-tool-surfaces))
      (let ((params (plist-get e :params)))
        (should (equal (mapcar (lambda (p) (plist-get p :name)) params)
                       '("command" "wait" "mode")))
        (should (equal (mapcar (lambda (p) (plist-get p :type)) params)
                       '("string" "boolean" "string")))
        (should (equal (mapcar (lambda (p) (plist-get p :required)) params)
                       '(t nil nil)))
        (should (equal (plist-get (nth 2 params) :enum) '("fg" "bg")))
        (should (equal (plist-get (nth 2 params) :default) "fg")))
      ;; The same thing by name, by alias and by registry symbol.
      (should (equal (cmacs-capability-describe-tool "desktop_launch") e))
      (should (equal (cmacs-capability-describe-tool "run_program") e))
      (should (equal (cmacs-capability-describe-tool 'desktop-launch) e))
      (should (null (cmacs-capability-describe-tool "nope"))))))

(ert-deftest cmacs-capability-test-describe-json ()
  "The JSON table parses and carries the types a C client relies on."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool desktop-launch
        "Start a program."
        ((command string "What to run")
         (count integer "Times" :optional t :default 2))
      :group 'desktop :destructive t :surfaces '(dbus cli agents)
      (ignore command count))
    (cmacs-brigade-deftool plain "No group, no arguments." () "ok")
    (let* ((doc (json-parse-string (cmacs-capability-json)
                                   :object-type 'alist :array-type 'list
                                   :null-object nil :false-object :false))
           (tools (alist-get 'tools doc))
           (launch (cl-find "desktop_launch" tools :test #'equal
                            :key (lambda (to) (alist-get 'name to))))
           (plain (cl-find "plain" tools :test #'equal
                           :key (lambda (to) (alist-get 'name to)))))
      (should (= (alist-get 'version doc) cmacs-capability-version))
      (should (= (length tools) 2))
      (should (eq (alist-get 'destructive launch) t))
      (should (eq (alist-get 'async launch) :false))
      (should (equal (alist-get 'surfaces launch) '("dbus" "cli" "agents")))
      (should (equal (alist-get 'cli launch) "desktop launch"))
      (should (equal (alist-get 'returns launch) "string"))
      (should (integerp (alist-get 'timeout launch)))
      (let ((count (nth 1 (alist-get 'params launch))))
        (should (equal (alist-get 'type count) "integer"))
        (should (eq (alist-get 'required count) :false))
        (should (= (alist-get 'default count) 2)))
      ;; Absent things are null/empty, never a missing member.
      (should (assq 'group plain))
      (should (null (alist-get 'group plain)))
      (should (null (alist-get 'params plain)))
      (should (equal (alist-get 'cli plain) "misc plain")))
    ;; Filtered views, by symbol and by name (the form D-Bus sends).
    (should (= (length (cmacs-capability-describe 'mcp)) 1))
    (should (string-match-p "\"desktop_launch\""
                            (cmacs-capability-json "dbus")))
    (should-not (string-match-p "\"desktop_launch\""
                                (cmacs-capability-json 'mcp)))
    (should (string-match-p "\"cli\":\"desktop launch\""
                            (cmacs-capability-tool-json "desktop_launch")))
    (should-error (cmacs-capability-tool-json "desktop_launch" 'mcp)
                  :type 'cmacs-capability-error)
    (should-error (cmacs-capability-tool-json "nope")
                  :type 'cmacs-capability-error)))


;;;; CLI verbs

(ert-deftest cmacs-capability-test-cli-derivation ()
  "GROUP VERB follows the one documented rule."
  (cmacs-capability-tests--with-registry
    (cl-flet ((reg (name &rest keys)
                (apply #'cmacs-brigade-register-tool
                       :name name :description "d" :handler #'ignore keys))
              (cli (wire)
                (plist-get (cmacs-capability-describe-tool wire) :cli)))
      ;; The group prefix is dropped from the verb...
      (reg 'desktop-launch :group 'desktop)
      (should (equal (cli "desktop_launch") "desktop launch"))
      ;; ... a name without it is kept whole ...
      (reg 'lql-query :group 'data)
      (should (equal (cli "lql_query") "data lql-query"))
      ;; ... underscores in either word become hyphens ...
      (reg 'second-brain-find-notes :group 'second-brain)
      (should (equal (cli "second_brain_find_notes")
                     "second-brain find-notes"))
      ;; ... a tool that is only its group's name keeps its name ...
      (reg 'mail :group 'mail)
      (should (equal (cli "mail") "mail mail"))
      ;; ... no group is `misc', and so is a group emacsctl reserves.
      (reg 'lonely)
      (should (equal (cli "lonely") "misc lonely"))
      (reg 'list-things :group 'list)
      (should (equal (cli "list_things") "misc list-things"))
      ;; An explicit :cli wins outright.
      (reg 'agent-spawn :group 'agent :cli "brigade start")
      (should (equal (cli "agent_spawn") "brigade start")))))

(ert-deftest cmacs-capability-test-cli-collision ()
  "Two tools that would share a verb both keep their full names."
  (cmacs-capability-tests--with-registry
    (cl-flet ((reg (name &rest keys)
                (apply #'cmacs-brigade-register-tool
                       :name name :description "d" :handler #'ignore keys))
              (cli (wire)
                (plist-get (cmacs-capability-describe-tool wire) :cli)))
      (reg 'desktop-launch :group 'desktop)
      (reg 'launch :group 'desktop)
      (reg 'desktop-close :group 'desktop)
      (should (equal (cli "desktop_launch") "desktop desktop-launch"))
      (should (equal (cli "launch") "desktop launch"))
      ;; A bystander in the same group is not disturbed.
      (should (equal (cli "desktop_close") "desktop close"))
      ;; Whatever the registry holds, no two tools share CLI words, and
      ;; the spelling does not depend on which surface asked.
      (let ((all (mapcar (lambda (e) (plist-get e :cli))
                         (cmacs-capability-describe))))
        (should (= (length all) (length (delete-dups (copy-sequence all))))))
      (should (equal (plist-get (cmacs-capability-describe-tool
                                 "desktop_launch" 'dbus)
                                :cli)
                     "desktop desktop-launch")))))


;;;; Surfaces

(ert-deftest cmacs-capability-test-surfaces ()
  "A tool is listed on exactly the surfaces it is published on."
  (cmacs-capability-tests--with-registry
    (cl-flet ((reg (name &rest keys)
                (apply #'cmacs-brigade-register-tool
                       :name name :description "d" :handler #'ignore keys))
              (names (surface)
                (mapcar (lambda (e) (plist-get e :name))
                        (cmacs-capability-describe surface))))
      (reg 'everywhere)
      (reg 'agents-only :surfaces '(agents mcp))
      (reg 'shell-only :surfaces '(dbus cli))
      ;; `cli' rides D-Bus: without `dbus' there is no wire for it.
      (reg 'orphan-cli :surfaces '(cli))
      (should (equal (names nil)
                     '("agents_only" "everywhere" "orphan_cli" "shell_only")))
      (should (equal (names 'mcp) '("agents_only" "everywhere")))
      (should (equal (names 'agents) '("agents_only" "everywhere")))
      (should (equal (names 'dbus) '("everywhere" "shell_only")))
      (should (equal (names 'cli) '("everywhere" "shell_only")))
      (should (null (plist-get (cmacs-capability-describe-tool "orphan_cli")
                               :surfaces)))
      ;; The in-process executor honours it too.
      (cl-letf (((symbol-function 'cmacs-brigade-tool-allowed-p)
                 (lambda (&rest _) t)))
        (should (equal (sort (mapcar #'cmacs-brigade-tool-wire-name
                                     (cmacs-brigade-tools-for-allowlist "*"))
                             #'string<)
                       '("agents_only" "everywhere")))))))

(ert-deftest cmacs-capability-test-menu-surface ()
  "Opting out of the menu surface clears the tool's menu entry."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-register-tool :name 'a :description "d" :handler #'ignore
                                 :menu '(file))
    (cmacs-brigade-register-tool :name 'b :description "d" :handler #'ignore
                                 :menu '(file) :surfaces '(agents mcp))
    (should (equal (cmacs-brigade-tool-menu
                    (cmacs-brigade-registry-get 'tool 'a))
                   '(file)))
    (should (null (cmacs-brigade-tool-menu
                   (cmacs-brigade-registry-get 'tool 'b))))))

(ert-deftest cmacs-capability-test-destructive-not-on-dbus ()
  "A destructive tool is off D-Bus and the CLI until it opts in."
  (cmacs-capability-tests--with-registry
    (let ((ran nil))
      (cmacs-brigade-deftool wipe-disk "Erase." ()
        :destructive t
        (setq ran 'wipe) "wiped")
      (cmacs-brigade-deftool drop-table "Drop." ()
        :destructive t :surfaces '(mcp dbus cli agents)
        (setq ran 'drop) "dropped")
      (let ((wipe (cmacs-capability-describe-tool "wipe_disk")))
        (should (equal (plist-get wipe :surfaces) '(mcp menu agents))))
      (should (equal (mapcar (lambda (e) (plist-get e :name))
                             (cmacs-capability-describe 'dbus))
                     '("drop_table")))
      ;; Refused before the handler is anywhere near it, with a message
      ;; that says how to change that.
      (let ((r (cmacs-capability-tests--call "wipe_disk" "{}")))
        (should (= (length r) 1))
        (should (equal (caar r) "NotOnSurface"))
        (should (string-match-p ":surfaces" (cadar r))))
      (should (null ran))
      (should (equal (cmacs-capability-tests--call "wipe_disk" "{}" 'cli)
                     (list (list "NotOnSurface"
                                 (cadar (cmacs-capability-tests--call
                                         "wipe_disk" "{}" 'cli))))))
      (should (null ran))
      ;; The one that opted in runs.
      (should (equal (cmacs-capability-tests--call "drop_table" "{}")
                     '((nil "dropped"))))
      (should (eq ran 'drop))
      ;; MCP is a scoped surface, so the default leaves it there.
      (should (cmacs-brigade-tool-on-surface-p
               (cmacs-brigade-registry-get 'tool 'wipe-disk) 'mcp)))))


;;;; Arguments

(ert-deftest cmacs-capability-test-parse-args ()
  "A JSON object becomes the typed alist the handler is applied to."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool typed "Typed."
        ((s string "S")
         (i integer "I" :optional t)
         (n number "N" :optional t)
         (b boolean "B" :optional t)
         (m string "M" :optional t :enum ("fg" "bg"))
         (d integer "D" :optional t :default 7))
      (ignore s i n b m d))
    (let ((tool (cmacs-brigade-registry-get 'tool 'typed)))
      (cl-flet ((parse (json) (cmacs-capability-parse-args tool json)))
        (should (equal (parse "{\"s\":\"x\",\"i\":3,\"n\":1.5,\"b\":true}")
                       '(("s" . "x") ("i" . 3) ("n" . 1.5) ("b" . t))))
        ;; The unambiguous spellings are accepted ...
        (should (equal (parse "{\"s\":42,\"i\":\"-3\",\"n\":\"2e3\",\
\"b\":\"false\"}")
                       '(("s" . "42") ("i" . -3) ("n" . 2000.0)
                         ("b" . :false))))
        (should (equal (parse "{\"s\":\"x\",\"i\":4.0}")
                       '(("s" . "x") ("i" . 4))))
        ;; ... null is "not given" ...
        (should (equal (parse "{\"s\":\"x\",\"i\":null}") '(("s" . "x"))))
        ;; ... and structured data for a string parameter is its JSON.
        (should (equal (parse "{\"s\":[1,{\"a\":true}]}")
                       '(("s" . "[1,{\"a\":true}]"))))
        (should (equal (parse "{\"s\":\"x\",\"m\":\"bg\"}")
                       '(("s" . "x") ("m" . "bg"))))
        ;; The refusals.
        (dolist (bad '("{\"s\":\"x\",\"i\":\"three\"}"   ; not an integer
                       "{\"s\":\"x\",\"i\":3.5}"         ; not a whole number
                       "{\"s\":\"x\",\"n\":\"1.5x\"}"    ; not a number
                       "{\"s\":\"x\",\"b\":\"maybe\"}"   ; not a boolean
                       "{\"s\":\"x\",\"b\":1}"
                       "{\"s\":true}"                    ; not a string
                       "{\"s\":\"x\",\"m\":\"sideways\"}" ; outside :enum
                       "{\"s\":\"x\",\"bogus\":1}"       ; no such argument
                       "{\"i\":3}"                       ; s is required
                       "{}"
                       ""
                       "null"
                       "[1,2]"                           ; not an object
                       "\"s\""
                       "{\"s\":"))                       ; not JSON
          (let ((err (should-error (parse bad)
                                   :type 'cmacs-capability-error)))
            (should (equal (nth 2 err) "BadArguments"))))))
    ;; A required parameter with a default is satisfied by the default,
    ;; and the handler really receives the converted values.
    (let ((got nil))
      (cmacs-brigade-deftool defaulted "D."
          ((a integer "A" :default 5)
           (flag boolean "F" :optional t))
        (setq got (list a flag)) "ok")
      (should (equal (cmacs-capability-tests--call "defaulted" "{}")
                     '((nil "ok"))))
      (should (equal got '(5 nil)))
      (should (equal (cmacs-capability-tests--call
                      "defaulted" "{\"a\":\"9\",\"flag\":false}")
                     '((nil "ok"))))
      (should (equal got '(9 nil)))
      (cmacs-capability-tests--call "defaulted" "{\"flag\":true}")
      (should (equal got '(5 t))))))

(ert-deftest cmacs-capability-test-args-are-data ()
  "Argument text reaches the handler as a value, whatever it contains."
  (cmacs-capability-tests--with-registry
    (let ((got nil)
          (nasty "\") (kill-emacs) (\"\\\\ é \n 'quoted'"))
      (cmacs-brigade-deftool echo "Echo." ((text string "T"))
        (setq got text) text)
      (should (equal (cmacs-capability-tests--call
                      "echo" (json-serialize (list :text nasty)))
                     (list (list nil nasty))))
      (should (equal got nasty)))))


;;;; Calling

(ert-deftest cmacs-capability-test-call-kinds ()
  "Each way a call can end has its own kind, and exactly one reply."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool ok-tool "Fine." ((x integer "X")) (* 2 x))
    (cmacs-brigade-deftool soft-fail "Returns an error string." ()
      "Error: disk on fire")
    (cmacs-brigade-deftool hard-fail "Signals." () (error "Boom"))
    (should (equal (cmacs-capability-tests--call "ok_tool" "{\"x\":21}")
                   '((nil "42"))))
    ;; The registry symbol's spelling is accepted for the name.
    (should (equal (cmacs-capability-tests--call "ok-tool" "{\"x\":1}")
                   '((nil "2"))))
    (should (equal (mapcar #'car (cmacs-capability-tests--call "nope" "{}"))
                   '("NoSuchTool")))
    (should (equal (mapcar #'car
                           (cmacs-capability-tests--call "ok_tool" "{}"))
                   '("BadArguments")))
    (should (equal (cmacs-capability-tests--call "soft_fail" "{}")
                   '(("ToolFailed" "disk on fire"))))
    (should (equal (cmacs-capability-tests--call "hard_fail" "{}")
                   '(("ToolFailed" "Boom"))))
    ;; A before-call hook's veto is a refusal, not a crash.
    (let ((cmacs-brigade-before-tool-call-functions (list #'ignore)))
      (let ((r (cmacs-capability-tests--call "ok_tool" "{\"x\":1}")))
        (should (equal (mapcar #'car r) '("ToolFailed")))
        (should (string-match-p "vetoed" (cadar r)))))
    ;; The audit hook sees the caller's surface as the agent.
    (let* ((seen nil)
           (cmacs-brigade-after-tool-call-functions
            (list (lambda (req) (push req seen)))))
      (cmacs-capability-tests--call "ok_tool" "{\"x\":1}")
      (should (equal (plist-get (car seen) :agent) "dbus"))
      (should (equal (plist-get (car seen) :result) "2")))))

(ert-deftest cmacs-capability-test-confirm-never-prompts ()
  "A tool needing confirmation is refused under RPC, never prompted for."
  (cmacs-capability-tests--with-registry
    (let ((ran 0))
      (cmacs-brigade-deftool careful "Asks first." ()
        :confirm 'ask
        (cl-incf ran) "done")
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "Prompted under RPC")))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Prompted under RPC"))))
        ;; The dispatch's own binding, and nobody to ask: refused.
        (let ((cmacs-brigade-auto-approve nil)
              (inhibit-interaction t))
          (let ((r (cmacs-capability-tests--call "careful" "{}")))
            (should (equal (mapcar #'car r) '("ToolFailed")))
            (should (string-match-p "approval" (cadar r)))
            (should (= ran 0)))
          ;; An approval handler is asked instead, and its answer holds.
          (cmacs-brigade-register-approval-handler
           :name 'test :ask (lambda (req)
                              (equal (plist-get req :agent) "dbus")))
          (should (equal (cmacs-capability-tests--call "careful" "{}")
                         '((nil "done"))))
          (should (= ran 1))
          (cmacs-brigade-register-approval-handler
           :name 'test :ask #'ignore)
          (should (equal (mapcar #'car
                                 (cmacs-capability-tests--call "careful" "{}"))
                         '("ToolFailed")))
          (should (= ran 1)))
        ;; Pre-approved runs without asking anyone.
        (let ((cmacs-brigade-auto-approve '("careful"))
              (inhibit-interaction t))
          (should (equal (cmacs-capability-tests--call "careful" "{}")
                         '((nil "done"))))
          (should (= ran 2)))))))


;;;; Async: exactly once

(ert-deftest cmacs-capability-test-async-exactly-once ()
  "An async tool answers once: not before `done', not twice, not late."
  (cmacs-capability-tests--with-registry
    (let ((done-fn nil) (timeout-fn nil) (cancelled 0))
      (cmacs-brigade-deftool slow "Slow." ((text string "T"))
        :async t :timeout 60
        (setq done-fn (lambda (v) (funcall done (concat text v)))))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_secs _repeat fn &rest _)
                   (setq timeout-fn fn)
                   'fake-timer))
                ((symbol-function 'timerp) (lambda (x) (eq x 'fake-timer)))
                ((symbol-function 'cancel-timer)
                 (lambda (&rest _) (cl-incf cancelled))))
        ;; 1. Completion: nothing until `done', then one reply; a second
        ;;    `done' and a timeout that fires afterwards are dropped.
        (let ((replies nil))
          (cmacs-capability-call "slow" "{\"text\":\"a\"}" 'dbus
                                 (lambda (k v) (push (list k v) replies)))
          (should (null replies))
          (should (functionp done-fn))
          (funcall done-fn "1")
          (should (equal replies '((nil "a1"))))
          (should (= cancelled 1))
          (funcall done-fn "2")
          (funcall timeout-fn)
          (should (equal replies '((nil "a1")))))
        ;; 2. Timeout: one Timeout reply; a `done' that arrives after it
        ;;    is dropped.
        (let ((replies nil))
          (cmacs-capability-call "slow" "{\"text\":\"b\"}" 'dbus
                                 (lambda (k v) (push (list k v) replies)))
          (should (null replies))
          (funcall timeout-fn)
          (should (equal (mapcar #'car replies) '("Timeout")))
          (funcall done-fn "late")
          (funcall timeout-fn)
          (should (= (length replies) 1)))
        ;; 3. An async tool that reports failure through `done'.
        (let ((replies nil))
          (cmacs-capability-call "slow" "{\"text\":\"Error: \"}" 'dbus
                                 (lambda (k v) (push (list k v) replies)))
          (funcall done-fn "no microphone")
          (should (equal replies '(("ToolFailed" "no microphone")))))))))

(ert-deftest cmacs-capability-test-async-handler-signals ()
  "An async handler that signals before parking still answers once."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool broken "Signals at start." ()
      :async t :timeout 60
      (ignore done) (error "Could not start"))
    (should (equal (cmacs-capability-tests--call "broken" "{}")
                   '(("ToolFailed" "Could not start"))))))

(ert-deftest cmacs-capability-test-dbus-call-replies-once ()
  "The D-Bus entry point hands each outcome to the reply primitive once."
  (cmacs-capability-tests--with-registry
    (let ((replies nil) (done-fn nil))
      (cmacs-brigade-deftool quick "Sync." () "now")
      (cmacs-brigade-deftool slow "Async." ()
        :async t :timeout 60
        (setq done-fn done))
      (cl-letf (((symbol-function 'cmacs-capability--dbus-reply)
                 (lambda (&rest args) (push args replies) t)))
        ;; Returns nil whatever happened: the answer is the reply call.
        (should (null (cmacs-capability-dbus-call 7 "quick" "{}")))
        (should (equal replies '((7 nil "now"))))
        (should (null (cmacs-capability-dbus-call 8 "nope" "{}")))
        (should (equal (car replies) '(8 "NoSuchTool" "no tool named nope")))
        (should (null (cmacs-capability-dbus-call 9 "slow" "")))
        ;; Parked: no reply for token 9 yet.
        (should (= (length replies) 2))
        (funcall done-fn "later")
        (funcall done-fn "again")
        (should (equal (car replies) '(9 nil "later")))
        (should (= (length replies) 3))))))

(ert-deftest cmacs-capability-test-dbus-reply-primitive ()
  "The C reply primitive answers a token at most once."
  (skip-unless (fboundp 'cmacs-capability--dbus-reply))
  ;; Nothing is parked in a batch Emacs, so every token is unknown: the
  ;; primitive must say so rather than signal or answer something.
  (should (null (cmacs-capability--dbus-reply 1 nil "x")))
  (should (null (cmacs-capability--dbus-reply 0 "ToolFailed" "x")))
  (should (= (cmacs-capability--dbus-pending) 0))
  (should-error (cmacs-capability--dbus-reply -1 nil "x"))
  (should-error (cmacs-capability--dbus-reply 1 nil nil)))


;;;; Aliases

(ert-deftest cmacs-capability-test-aliases ()
  "An old wire name keeps answering after a tool is renamed."
  (cmacs-capability-tests--with-registry
    (let ((mirrored nil) (removed nil))
      (cl-letf (((symbol-function 'cmacs-brigade--mirror-put)
                 (lambda (wire &rest _) (push wire mirrored) t))
                ((symbol-function 'cmacs-brigade--mirror-remove)
                 (lambda (wire) (push wire removed) t)))
        (cmacs-brigade-deftool lrgeditor-open "Open." ()
          :aliases '(lrg-editor-open "old_open")
          "opened")
        ;; Each alias is published as a tool of its own.
        (should (equal (sort (copy-sequence mirrored) #'string<)
                       '("lrg_editor_open" "lrgeditor_open" "old_open")))
        (should (equal (cmacs-brigade-call-tool "lrg_editor_open" "{}")
                       "opened"))
        (should (equal (cmacs-capability-tests--call "old_open" "{}")
                       '((nil "opened"))))
        ;; One table entry, not three.
        (should (= (length (cmacs-capability-describe)) 1))
        ;; Dropping an alias on re-registration unpublishes it.
        (cmacs-brigade-deftool lrgeditor-open "Open." ()
          :aliases '(lrg-editor-open)
          "opened")
        (should (equal removed '("old_open")))
        (should (equal (mapcar #'car
                               (cmacs-capability-tests--call "old_open" "{}"))
                       '("NoSuchTool")))
        (setq removed nil)
        (should (cmacs-brigade-unregister-tool 'lrgeditor-open))
        (should (equal (sort removed #'string<)
                       '("lrg_editor_open" "lrgeditor_open")))))))


;;;; The migrated family

(ert-deftest cmacs-capability-test-calculator-family-matches-c ()
  "The registry calculator tools are the C ones: same names, same params.
The C handlers are gone; what they published is the frozen wire schema
\(cmacs-wire-schema.el), and the family may not drift from it."
  (let ((root (cmacs-capability-tests--source-root)))
    (skip-unless root)
    (cmacs-capability-tests--with-registry
      (let ((load-prefer-newer t))
        (load (expand-file-name "lisp/cmacs/cmacs-calculator-tools" root)
              nil t))
      (let ((c (cmacs-wire-schema-names "cmacs-mcp-tools-calculator.c")))
        (should (= (length c) 5))
        (should (equal (sort (copy-sequence c) #'string<)
                       (mapcar (lambda (e) (plist-get e :name))
                               (cmacs-capability-describe))))
        (dolist (name c)
          (let ((entry (cmacs-capability-describe-tool name)))
            (cmacs-wire-schema-should-match name)
            ;; Read-only tools, so nothing keeps them off any surface.
            (should-not (plist-get entry :destructive))
            (should (memq 'dbus (plist-get entry :surfaces)))
            (should (string-prefix-p "calc " (plist-get entry :cli)))))))))

(ert-deftest cmacs-capability-test-calculator-family-runs ()
  "A migrated tool computes, and reports bad input as a failure."
  (skip-unless (locate-library "cmacs-calculator"))
  (skip-unless (locate-library "cmacs-calculator-tools"))
  (cmacs-capability-tests--with-registry
    (let ((load-prefer-newer t))
      (load "cmacs-calculator-tools" nil t))
    (skip-unless (ignore-errors (require 'cmacs-calculator) t))
    (let ((r (cmacs-capability-tests--call
              "calc_eval" "{\"expression\":\"2+2\"}")))
      (should (equal (mapcar #'car r) '(nil)))
      (should (string-match-p "\\`4\\.?\\'" (cadar r))))
    (should (equal (mapcar #'car (cmacs-capability-tests--call
                                  "calc_eval" "{\"expression\":\"\"}"))
                   '("ToolFailed")))
    (should (equal (mapcar #'car (cmacs-capability-tests--call
                                  "calc_describe"
                                  "{\"name\":\"(kill-emacs)\"}"))
                   '("ToolFailed")))))


;;;; Rendering and the checked-in reference

(ert-deftest cmacs-capability-test-renderers ()
  "The org and Texinfo renderings say the same things about a tool."
  (cmacs-capability-tests--with-registry
    (cmacs-brigade-deftool desktop-launch
        "Start a {program}.\nSecond line."
        ((command string "What | to run")
         (mode string "How" :optional t :enum ("fg" "bg") :default "fg"))
      :group 'desktop :destructive t :surfaces '(mcp dbus cli)
      :example "emacsctl tool desktop launch --command ls"
      (ignore command mode))
    (let* ((table (cmacs-capability-describe))
           (org (cmacs-capability-org table))
           (texi (cmacs-capability-texi table)))
      (dolist (text (list org texi))
        (should (string-match-p "desktop_launch" text))
        (should (string-match-p "emacsctl tool desktop launch" text))
        (should (string-match-p "mcp, dbus, cli" text))
        (should (string-match-p "destructive" text))
        (should (string-match-p "One of: fg, bg\\." text))
        (should (string-match-p "Default: fg\\." text)))
      ;; Each format's own special characters are neutralised.
      (should (string-match-p "Start a {program}\\. Second line\\." org))
      (should-not (string-match-p "What | to run" org))
      (should (string-match-p "Start a @{program@}\\." texi))
      (should (string-match-p "^\\* desktop$" org))
      (should (string-match-p "^@subheading desktop$" texi)))))

(ert-deftest cmacs-capability-test-shipped-files ()
  "The generator finds the tool files by their contents."
  (let ((root (cmacs-capability-tests--source-root)))
    (skip-unless root)
    (let ((files (mapcar #'file-name-nondirectory
                         (cmacs-capability-shipped-files
                          (expand-file-name "lisp/cmacs" root)))))
      (should (member "cmacs-calculator-tools.el" files))
      (should (member "cmacs-brigade-subagent.el" files))
      ;; It registers one tool of its own, `capability_doctor'.
      (should (member "cmacs-capability.el" files)))))

(ert-deftest cmacs-capability-test-reference-is-current ()
  "The checked-in capability reference matches what the tree generates.

Regenerate with `admin/cmacs-capability-audit.sh --write-docs'.  Run in
a child Emacs with an empty HOME, so the reference describes the shipped
tools and not whatever this session or the user's init registered."
  (let* ((root (cmacs-capability-tests--source-root))
         (emacs (and invocation-directory
                     (expand-file-name invocation-name invocation-directory))))
    (skip-unless root)
    (skip-unless (and emacs (file-executable-p emacs)))
    (skip-unless (file-readable-p
                  (expand-file-name cmacs-capability-reference-org root)))
    (let* ((home (make-temp-file "cmacs-capability-home" t))
           ;; Absolute: `default-directory' is usually spelt with a `~',
           ;; and HOME is about to mean something else.
           (default-directory root)
           (process-environment
            (append (list (concat "HOME=" home)
                          (concat "XDG_CONFIG_HOME=" home "/config")
                          (concat "XDG_DATA_HOME=" home "/data")
                          (concat "XDG_STATE_HOME=" home "/state")
                          (concat "XDG_CACHE_HOME=" home "/cache"))
                    process-environment))
           (status
            (unwind-protect
                (with-temp-buffer
                  (prog1 (call-process
                          emacs nil t nil "--batch" "-Q"
                          "-L" (expand-file-name "lisp/cmacs" root)
                          "--eval" "(setq load-prefer-newer t)"
                          "-l" "cmacs-capability"
                          "-f" "cmacs-capability-batch-write-reference"
                          root "--check")
                    (message "%s" (buffer-string))))
              (delete-directory home t))))
      ;; 2 = a tool file would not load in this build (a subsystem is
      ;; compiled out), so this build cannot judge the reference.
      (skip-unless (not (eql status 2)))
      (should (eql status 0)))))

;;;; Structured parameters on every surface

(defmacro cmacs-capability-tests--with-team (&rest body)
  "Run BODY with `team_add' registered: an array, two objects, nesting."
  (declare (indent 0) (debug t))
  `(cmacs-capability-tests--with-registry
     (cmacs-brigade-deftool team-add "Define a team."
         ((name string "Team name")
          (members array "Window ids" :items integer)
          (rule object "Who joins" :optional t
                :properties ((app string "App id")
                             (title string "Title" :optional t)))
          (extra object "Anything" :optional t)
          (steps array "Steps" :optional t
                 :items (object :properties ((key string "Key")))))
       :group 'team
       (prin1-to-string (list name members rule extra steps)))
     ,@body))

(ert-deftest cmacs-capability-test-structured-describe ()
  "The table says what is inside an array or object, as data and as JSON."
  (cmacs-capability-tests--with-team
    (let* ((entry (cmacs-capability-describe-tool "team_add"))
           (param (lambda (name)
                    (cl-find name (plist-get entry :params) :test #'equal
                             :key (lambda (p) (plist-get p :name))))))
      (should (equal (plist-get (funcall param "members") :type) "array"))
      (should (equal (plist-get (funcall param "members") :items)
                     '(:type "integer")))
      (should (equal (mapcar (lambda (p) (plist-get p :name))
                             (plist-get (funcall param "rule") :properties))
                     '("app" "title")))
      ;; A scalar entry has no structure keys at all.
      (should-not (plist-member (funcall param "name") :items))
      (should-not (plist-member (funcall param "name") :properties)))
    ;; The JSON table: `type' stays the plain word an older client reads,
    ;; and `schema' carries the rest as JSON Schema.
    (let* ((tool (json-parse-string (cmacs-capability-tool-json "team_add")
                                    :object-type 'alist :array-type 'list))
           (param (lambda (name)
                    (cl-find name (alist-get 'params tool) :test #'equal
                             :key (lambda (p) (alist-get 'name p))))))
      (should (equal (alist-get 'type (funcall param "members")) "array"))
      (should (equal (alist-get 'schema (funcall param "members"))
                     '((type . "array") (items (type . "integer")))))
      (should (equal (alist-get 'required
                                (alist-get 'schema (funcall param "rule")))
                     '("app")))
      (should (equal (alist-get 'schema (funcall param "extra"))
                     '((type . "object"))))
      (should-not (assq 'schema (funcall param "name"))))))

(ert-deftest cmacs-capability-test-structured-parse-args ()
  "D-Bus arguments: arrays become lists, objects alists, both checked."
  (cmacs-capability-tests--with-team
    (let ((tool (cmacs-brigade--tool-by-wire "team_add")))
      (should (equal (cmacs-capability-parse-args
                      tool "{\"name\":\"raid\",\"members\":[1,2],
                             \"rule\":{\"app\":\"foot\"},
                             \"extra\":{\"k\":{\"deep\":[true]}},
                             \"steps\":[{\"key\":\"a\"}]}")
                     '(("name" . "raid") ("members" 1 2)
                       ("rule" (app . "foot")) ("extra" (k (deep t)))
                       ("steps" ((key . "a"))))))
      ;; `emacsctl tool' sends JSON text when it cannot type the flag.
      (should (equal (cmacs-capability-parse-args
                      tool "{\"name\":\"raid\",\"members\":\"[1,2]\"}")
                     '(("name" . "raid") ("members" 1 2))))
      ;; An empty array is given, not missing.
      (should (equal (cmacs-capability-parse-args
                      tool "{\"name\":\"raid\",\"members\":[]}")
                     '(("name" . "raid") ("members"))))
      (pcase-dolist (`(,json ,want)
                     '(("{\"name\":\"r\"}" "missing required argument `members'")
                       ("{\"name\":\"r\",\"members\":null}"
                        "missing required argument `members'")
                       ("{\"name\":\"r\",\"members\":{\"a\":1}}"
                        "must be an array, not an object")
                       ("{\"name\":\"r\",\"members\":[1,\"two\"]}"
                        "`members\\[1\\]' must be an integer")
                       ("{\"name\":\"r\",\"members\":[],\"rule\":[1]}"
                        "must be an object, not an array")
                       ("{\"name\":\"r\",\"members\":[],\"rule\":{}}"
                        "`rule\\.app' is required")
                       ("{\"name\":\"r\",\"members\":[],\"steps\":[{}]}"
                        "`steps\\[0\\]\\.key' is required")))
        (ert-info (json)
          (let ((err (should-error (cmacs-capability-parse-args tool json)
                                   :type 'cmacs-capability-error)))
            (should (equal (nth 2 err) "BadArguments"))
            (should (string-match-p want (nth 1 err)))))))))

(ert-deftest cmacs-capability-test-structured-call ()
  "A structured argument goes from the D-Bus entry point to the body."
  (cmacs-capability-tests--with-team
    (should (equal (cmacs-capability-tests--call
                    "team_add"
                    "{\"name\":\"raid\",\"members\":[3],\"rule\":{\"app\":\"foot\",\"title\":\"x\"}}")
                   '((nil "(\"raid\" (3) ((app . \"foot\") (title . \"x\")) nil nil)"))))
    (should (equal (mapcar #'car (cmacs-capability-tests--call
                                  "team_add"
                                  "{\"name\":\"raid\",\"members\":\"no\"}"))
                   '("BadArguments")))))

(ert-deftest cmacs-capability-test-structured-renderers ()
  "The reference names a structured parameter by what is in it."
  (cmacs-capability-tests--with-team
    (let* ((table (cmacs-capability-describe))
           (org (cmacs-capability-org table))
           (texi (cmacs-capability-texi table)))
      (should (string-match-p "| =members= | array of integer | yes |" org))
      (should (string-match-p "| =rule= | object {app, title} | no |" org))
      (should (string-match-p "| =extra= | object | no |" org))
      (should (string-match-p "| =steps= | array of object {key} | no |" org))
      (should (string-match-p "@tab array of integer @tab yes" texi))
      ;; Braces are Texinfo syntax.
      (should (string-match-p "@tab object @{app, title@} @tab no" texi)))))


;;;; The table without the brigade
;;
;; Read as text, because they are statements about a build this test
;; run is not: one configured with an MCP server and no AI subsystems.

(defun cmacs-capability-tests--file-text (relative)
  "Return the text of the source file RELATIVE to the tree's root, or nil."
  (let* ((root (cmacs-capability-tests--source-root))
         (file (and root (expand-file-name relative root))))
    (and file (file-readable-p file)
         (with-temp-buffer
           (insert-file-contents file)
           (buffer-string)))))

(ert-deftest cmacs-capability-test-publisher-needs-no-brigade ()
  "The MCP publisher and the registry mirror compile without the brigade."
  (let ((publisher (cmacs-capability-tests--file-text
                    "cmacs/mcp/cmacs-mcp-tools-brigade.c"))
        (mirror (cmacs-capability-tests--file-text
                 "cmacs/core/cmacs-tool-registry.c"))
        (header (cmacs-capability-tests--file-text
                 "cmacs/core/cmacs-tool-registry.h")))
    (skip-unless (and publisher mirror header))
    ;; The publisher: everything up to the scoped sockets is outside any
    ;; brigade guard, and the sockets are inside one.
    (let* ((sockets (string-search
                     "#ifdef HAVE_CMACS_AI_BRIGADE\n\n/* ── Scoped sockets"
                     publisher))
           (before (substring publisher 0 sockets))
           (after (substring publisher sockets)))
      (should sockets)
      (dolist (function '("handle_brigade_tool (McpServer"
                          "schema_for_tool (const CmacsBrigadeTool"
                          "publish_one (const CmacsBrigadeTool"
                          "cmacs_mcp_tools_brigade_register (McpServer"))
        (ert-info (function)
          (should (string-search function before))))
      ;; Every brigade guard opened before the sockets is closed again:
      ;; the publisher is not inside one.
      (should (= (cl-count-if
                  (lambda (line)
                    (string-match-p "\\`#ifdef HAVE_CMACS_AI_BRIGADE" line))
                  (split-string before "\n"))
                 (cl-count-if
                  (lambda (line)
                    (string-match-p "\\`#endif" line))
                  (split-string before "\n"))))
      (should (string-match-p "cmacs_brigade_tool_allowed_with_policy" after))
      (should-not (string-match-p "cmacs_brigade_tool_allowed_with_policy"
                                  before))
      (should-not (string-match-p "cmacs_brigade_policy_from_lisp" before)))
    ;; It loads the Lisp side that needs no brigade, by name, and
    ;; WITHOUT `noerror': nothing stands in for these tools any more, so
    ;; a table that does not load is remembered and announced.
    (should (string-search "(require 'cmacs-brigade-tools)" publisher))
    (should (string-search "(require 'cmacs-capability)" publisher))
    (should-not (string-search "(require 'cmacs-brigade-tools nil t)"
                               publisher))
    (should (string-search "registry_load_error = g_strdup" publisher))
    (should (string-search "mcp_server_set_instructions (server" publisher))
    ;; No registry tool takes a C tool's name: the rule has no exception.
    (should (string-search
             "if (g_hash_table_contains (pass->builtin, tool->name))"
             publisher))
    (should-not (string-search "replaces_builtin" publisher))
    (should-not (string-search "replaces_builtin" header))
    ;; A structured parameter's schema is copied, not rebuilt.
    (should (string-match-p
             "json_object_has_member (p, \"schema\")" publisher))
    ;; The mirror: compiled for either, including nothing of either.
    (dolist (text (list mirror header))
      (should (string-match-p
               "#if defined HAVE_CMACS_MCP || defined HAVE_CMACS_AI_BRIGADE"
               text)))
    (should-not (string-match-p "#include \"cmacs-brigade\\.h\"" mirror))
    (should-not (string-match-p "#include <mcp\\.h>" mirror))
    (dolist (defun '("cmacs-brigade--mirror-put" "cmacs-brigade--mirror-remove"
                     "cmacs-brigade--mirror-names"))
      (should (string-search (format "DEFUN (\"%s\"" defun) mirror)))))

(ert-deftest cmacs-capability-test-lisp-core-needs-no-brigade ()
  "The registry, the dispatcher and the table load with the C brigade absent."
  (let* ((root (cmacs-capability-tests--source-root))
         (emacs (and invocation-directory
                     (expand-file-name invocation-name invocation-directory))))
    (skip-unless root)
    (skip-unless (and emacs (file-executable-p emacs)))
    ;; A child, so `fmakunbound' reaches nothing in this session.  It
    ;; removes every C entry point of the brigade before loading the
    ;; Lisp, which is the situation of a build without it; the mirror
    ;; stays, because the mirror is what such a build still has.
    (let* ((home (make-temp-file "cmacs-capability-home" t))
           (form
            (prin1-to-string
             '(progn
                (setq load-prefer-newer t)
                (dolist (f '(cmacs-brigade-supported-p
                             cmacs-brigade-abi-version
                             cmacs-brigade-capabilities
                             cmacs-brigade-tool-allowed-p
                             cmacs-brigade-scope-open
                             cmacs-brigade-scope-close
                             cmacs-brigade-index-open
                             cmacs-brigade-index-search))
                  (fmakunbound f))
                (require 'cmacs-brigade)
                (require 'cmacs-brigade-tools)
                (unless (and (featurep 'cmacs-brigade-registry)
                             (featurep 'cmacs-capability)
                             (not (cmacs-brigade-available-p))
                             ;; The fabric was NOT pulled in...
                             (not (featurep 'cmacs-brigade-run))
                             (not (featurep 'cmacs-brigade-subagent))
                             ;; ...and the core families were.
                             (cmacs-capability-describe-tool "list_buffers")
                             ;; A tool runs with no allowlist gate to ask.
                             (equal (cmacs-brigade-call-tool
                                     "list_buffers" "{}")
                                    (cmacs-brigade-call-tool
                                     "list_buffers" nil)))
                  (kill-emacs 3))
                (kill-emacs 0))))
           (default-directory root)
           (process-environment
            (append (list (concat "HOME=" home)
                          (concat "XDG_CONFIG_HOME=" home "/config")
                          (concat "XDG_STATE_HOME=" home "/state")
                          (concat "XDG_CACHE_HOME=" home "/cache"))
                    process-environment))
           (status
            (unwind-protect
                (with-temp-buffer
                  (prog1 (call-process
                          emacs nil t nil "--batch" "-Q"
                          "-L" (expand-file-name "lisp/cmacs" root)
                          "--eval" form)
                    (message "%s" (buffer-string))))
              (delete-directory home t))))
      (should (eql status 0)))))

(ert-deftest cmacs-capability-test-families-are-files ()
  "Every migrated family names a file that exists and a flag that exists."
  (let ((root (cmacs-capability-tests--source-root)))
    (skip-unless root)
    (pcase-dolist (`(,feature . ,flag) cmacs-capability-migrated-families)
      (ert-info ((format "%s" feature))
        (should (file-readable-p
                 (expand-file-name (format "lisp/cmacs/%s.el" feature) root)))
        ;; A misspelt flag is never bound, so its family would never
        ;; load and every tool in it would silently stay the C one.
        (should (or (eq flag t) (boundp flag)))))
    ;; No family twice: the second load would re-register every tool.
    (should (equal (length cmacs-capability-migrated-families)
                   (length (delete-dups
                            (mapcar #'car
                                    cmacs-capability-migrated-families)))))
    (dolist (feature '(cmacs-screensaver-tools cmacs-podomation-tools
                       cmacs-video-tools cmacs-ai-models-tools
                       cmacs-secondbrain-ingest-tools
                       cmacs-secondbrain-search-tools))
      (should (assq feature cmacs-capability-migrated-families)))))

;;;; A family that does not load is loud
;;
;; The C handlers the families replaced are deleted, so a family file
;; that fails to load takes its tools off every surface.  These hold
;; that it is recorded, reported, and does not take the others with it.

(defmacro cmacs-capability-tests--with-families (spec &rest body)
  "Run BODY with temporary tool families on the load path.
SPEC is a list of (FEATURE TEXT): each becomes FEATURE.el holding TEXT
in a fresh directory (no file at all when TEXT is nil), and
`cmacs-capability-migrated-families' is those features, each built into
every cmacs.  BODY runs with an empty
registry and no recorded failure; the features are forgotten after."
  (declare (indent 1) (debug t))
  `(let* ((dir (make-temp-file "cmacs-capability-families" t))
          (spec ,spec)
          (load-path (cons dir load-path))
          (cmacs-capability-migrated-families
           (mapcar (lambda (family) (cons (car family) t)) spec))
          (cmacs-capability-family-failures nil)
          (cmacs-capability--reported-failures nil)
          (cmacs-brigade--shipped-tools (make-hash-table :test #'equal)))
     (unwind-protect
         (progn
           (pcase-dolist (`(,feature ,text) spec)
             (when text
               (with-temp-file (expand-file-name
                                (format "%s.el" feature) dir)
                 (insert text))))
           (cmacs-capability-tests--with-registry ,@body))
       (dolist (family spec)
         (setq features (delq (car family) features)))
       (delete-directory dir t))))

(defconst cmacs-capability-tests--good-family
  ";;; -*- lexical-binding: t; -*-
(require 'cmacs-brigade-registry)
(cmacs-brigade-deftool captest-good \"A tool that loads.\" () \"good\")
(provide 'cmacs-captest-good-tools)\n"
  "A family file with nothing wrong with it.")

(defconst cmacs-capability-tests--broken-family
  ";;; -*- lexical-binding: t; -*-
(require 'cmacs-brigade-registry)
(cmacs-brigade-deftool captest-before \"Registered before the mistake.\" ()
  \"before\")
(cmacs-brigade-deftool captest-never \"Never reached.\" (
(provide 'cmacs-captest-broken-tools)\n"
  "A family file with an unbalanced parenthesis: reading it signals.")

(ert-deftest cmacs-capability-test-broken-family-is-recorded ()
  "A family that fails to load is recorded, and the others still load."
  (let ((warnings nil))
    (cmacs-capability-tests--with-families
        `((cmacs-captest-broken-tools ,cmacs-capability-tests--broken-family)
          (cmacs-captest-good-tools ,cmacs-capability-tests--good-family)
          ;; No such file at all.
          (cmacs-captest-missing-tools nil))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (type message &optional level &rest _)
                   (push (list type level message) warnings)))
                ;; The report is deferred in a session; run it now.
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args)
                   (apply function args))))
        (let ((failures (cmacs-capability-load-families)))
          ;; Both failures, each with its reason.
          (should (equal (sort (mapcar #'car failures) #'string<)
                         '(cmacs-captest-broken-tools
                           cmacs-captest-missing-tools)))
          (should (string-match-p
                   "not found"
                   (plist-get (alist-get 'cmacs-captest-missing-tools
                                         failures)
                              :error)))
          (should (stringp (plist-get (alist-get 'cmacs-captest-broken-tools
                                                 failures)
                                      :error)))
          ;; The family after the broken one loaded and works.
          (should (cmacs-capability-describe-tool "captest_good"))
          (should (equal (cmacs-brigade-call-tool "captest_good" "{}")
                         "good"))
          (should-not (cmacs-capability-describe-tool "captest_never"))
          ;; Reported once each, at :error level...
          (should (= (length warnings) 2))
          (dolist (warning warnings)
            (should (eq (nth 0 warning) 'cmacs-capability))
            (should (eq (nth 1 warning) :error)))
          (should (cl-some (lambda (warning)
                             (string-match-p "cmacs-captest-broken-tools"
                                             (nth 2 warning)))
                           warnings))
          ;; ...and not again when asked a second time.
          (cmacs-capability-load-families)
          (should (= (length warnings) 2))
          ;; What an MCP client is told names each family and its error.
          (let ((notice (cmacs-capability-status-notice)))
            (should (string-prefix-p "NOTICE: 2 cmacs tool families" notice))
            (should (string-match-p "cmacs-captest-broken-tools: " notice))
            (should (string-match-p "cmacs-captest-missing-tools: " notice))
            (should (string-match-p "capability_doctor" notice)))
          ;; And the doctor says the same, with the count.
          (let ((report (cmacs-capability-doctor-text)))
            (should (string-match-p "1 of 3 tool families loaded" report))
            (should (string-match-p "2 FAILED to load" report))
            (should (string-match-p "cmacs-captest-broken-tools" report))))))))

(ert-deftest cmacs-capability-test-fixed-family-reloads ()
  "A family fixed after failing loads on retry and leaves the failures."
  (cmacs-capability-tests--with-families
      `((cmacs-captest-broken-tools ,cmacs-capability-tests--broken-family))
    (cl-letf (((symbol-function 'display-warning) #'ignore)
              ((symbol-function 'run-at-time) #'ignore))
      (should (cmacs-capability-load-families))
      (should-not (equal (cmacs-capability-status-notice) ""))
      ;; Fix the file.
      (with-temp-file (expand-file-name "cmacs-captest-broken-tools.el" dir)
        (insert ";;; -*- lexical-binding: t; -*-
(require 'cmacs-brigade-registry)
(cmacs-brigade-deftool captest-never \"Reached now.\" () \"fixed\")
(provide 'cmacs-captest-broken-tools)\n"))
      ;; Not retried unless asked: a failure is not re-read on every
      ;; session an MCP client opens.
      (should (cmacs-capability-load-families))
      (should-not (cmacs-capability-reload-families))
      (should-not cmacs-capability-family-failures)
      (should (equal (cmacs-capability-status-notice) ""))
      (should (equal (cmacs-brigade-call-tool "captest_never" "{}")
                     "fixed"))
      (should (string-match-p "No tool family failed"
                              (cmacs-capability-doctor-text))))))

(ert-deftest cmacs-capability-test-doctor-is-a-tool ()
  "`capability_doctor' is registered, read-only, and on every surface."
  (let ((entry (cmacs-capability-describe-tool "capability_doctor")))
    (should entry)
    (should-not (plist-get entry :destructive))
    (dolist (surface '(mcp dbus cli agents))
      (should (memq surface (plist-get entry :surfaces))))
    (should (string-prefix-p "Capability table: "
                             (cmacs-brigade-call-tool "capability_doctor"
                                                      "{}")))))

(ert-deftest cmacs-capability-test-shipped-tree-has-no-failed-family ()
  "Every tool family this build should have loaded when the table did."
  (should-not cmacs-capability-family-failures)
  (pcase-dolist (`(,feature . ,flag) cmacs-capability-migrated-families)
    (when (cmacs-capability--family-wanted-p flag)
      (ert-info ((format "family %s" feature))
        (should (featurep feature))))))

;;;; What a tool is declared to do
;;
;; :destructive is what an MCP client is shown (readOnlyHint when it is
;; nil), what keeps a tool from a read-only agent, and what keeps it off
;; D-Bus and the CLI by default.  A tool that acts and forgot to say so
;; is published as read-only.  Two guards: the tool's own name, and what
;; the C handler it replaced told clients.

(defconst cmacs-capability-tests--action-verbs
  '("write" "set" "delete" "kill" "close" "remove" "drop" "create" "add"
    "insert" "edit" "replace" "save" "export" "spawn" "launch" "run"
    "fire" "send" "type" "click" "press" "key" "scroll" "navigate" "open"
    "back" "forward" "reload" "record" "start" "stop" "pause" "resume"
    "restart" "cancel" "toggle" "switch" "focus" "select" "move" "assign"
    "migrate" "ingest" "emit" "load" "print" "slice" "patch" "copy" "play"
    "split" "undo" "transform" "adjust" "draw" "filter" "render"
    "synthesize" "generate" "call" "prompt" "connect" "disconnect" "fly"
    "pin" "unpin" "cycle" "orbit" "goto" "expand" "eval" "execute"
    "control" "drain" "say" "watch" "unwatch" "enabled")
  "Words that, as one `_'-separated part of a wire name, mean the tool acts.
Anything that writes, deletes, closes, launches, types, clicks,
navigates, records, spends money or changes the compositor's or the
editor's state.")

(defconst cmacs-capability-tests--not-destructive
  '(;; Named like an action, reviewed, and not one.
    ("calc_eval" . "evaluates arithmetic; no state")
    ("calc_eval_symbolic" . "evaluates algebra; no state")
    ("cad_eval" . "re-evaluates the part file as it is on disk; writes nothing")
    ("cad_open" . "loads a part to be inspected; C published it read-only")
    ("imgedit_open" . "reads an image into a new in-memory document")
    ("db_connect" . "opens a session for read-only queries; the write \
tools are the gated ones, and read-only is enforced per connection in C")
    ("db_disconnect" . "closes a session the caller opened")
    ("profiler_start" . "a diagnostic toggle; nothing of the user's changes")
    ("profiler_stop" . "a diagnostic toggle; nothing of the user's changes")
    ("lrgterm_render_stats" . "reports counters; `render' is the subject")
    ("secondbrain_ingest_status" . "reports on a job; `ingest' is the subject")
    ("lql_watch" . "an agent's own, bounded, ephemeral standing query; \
removed when its run ends")
    ("lql_unwatch" . "removes the caller's own watch")
    ("speech_say" . "speaks aloud by design; registered by the speech \
fabric, not a tool family -- owner to review")
    ;; Not named like an action, but the C never called them read-only.
    ("gnuseye_forecast" . "fetches a forecast; changes nothing")
    ("gnuseye_refresh" . "re-reads the data layers; nothing of the user's changes")
    ("imgedit_new" . "creates a new in-memory document; nothing existing changes")
    ("vidstudio_new" . "creates a new in-memory project; nothing existing changes")
    ("lrgterm_force_redraw" . "repaints the frame as it already is")
    ("screensaver_list_configs" . "a listing; the C simply set no hint")
    ("secondbrain_refresh" . "re-reads the sources; nothing of the user's changes")
    ("secondbrain_search" . "a search; highlighting the matches is its answer"))
  "Tools that are not :destructive although a guard below would expect it.
An alist of (WIRE-NAME . REASON), each reviewed.  An entry for a tool
that is destructive after all, or that no guard asks about, fails the
suite: the list cannot quietly outlive its reasons.")

(defun cmacs-capability-tests--action-name-p (wire)
  "Return the action verb in the wire name WIRE, or nil."
  (cl-find-if (lambda (part)
                (member part cmacs-capability-tests--action-verbs))
              (split-string wire "_")))

(ert-deftest cmacs-capability-test-action-tools-are-destructive ()
  "A tool named like an action is :destructive, or is a reviewed exception.
`gsurf_click' was once published to MCP clients as read-only: its
family file had not said otherwise, and nothing checked."
  (let ((asked nil))
    (dolist (entry (cmacs-capability-describe))
      (let* ((name (plist-get entry :name))
             (verb (cmacs-capability-tests--action-name-p name))
             (excused (assoc name cmacs-capability-tests--not-destructive)))
        (when verb
          (ert-info ((format "tool %s (named for `%s')" name verb))
            (if excused
                (progn (push name asked)
                       (should-not (plist-get entry :destructive)))
              (should (plist-get entry :destructive)))))))
    ;; Every exception is for a tool that exists here and is asked about
    ;; by this guard or the next one.
    (dolist (excused cmacs-capability-tests--not-destructive)
      (let ((entry (cmacs-capability-describe-tool (car excused))))
        (when entry
          (ert-info ((format "exception %s" (car excused)))
            (should-not (plist-get entry :destructive))
            (should (or (member (car excused) asked)
                        (and (cmacs-wire-schema-tool (car excused))
                             (not (cmacs-wire-schema-read-only-p
                                   (car excused))))))))))))

(ert-deftest cmacs-capability-test-c-hints-are-kept ()
  "No tool became read-only, or stopped being read-only, by being migrated.
The C handlers published `readOnlyHint' for the tools that only read.
A registry tool the C called read-only is not :destructive; one the C
did not is :destructive, unless it is a reviewed exception."
  (let ((checked 0))
    (dolist (entry (cmacs-capability-describe))
      (let ((name (plist-get entry :name)))
        (when (cmacs-wire-schema-tool name)
          (cl-incf checked)
          (ert-info ((format "tool %s" name))
            (cond
             ((cmacs-wire-schema-read-only-p name)
              (should-not (plist-get entry :destructive)))
             ((assoc name cmacs-capability-tests--not-destructive)
              (should-not (plist-get entry :destructive)))
             (t (should (plist-get entry :destructive))))))))
    ;; The registry of this build really was compared, not an empty one.
    (should (> checked 50))))

(ert-deftest cmacs-capability-test-legacy-reach-is-granted ()
  "A destructive tool a legacy D-Bus method has always served is on `dbus'.
Becoming :destructive takes a tool off D-Bus and the CLI by default.
Where a hand-written method did the same thing before the table existed
and is now served from the tool, that would have removed something a
script may call, so those tools list their surfaces."
  (dolist (name '("generate_image" "goto_line" "select_window"
                  "gnuseye_add_geofence" "gnuseye_fly_to" "gnuseye_open"
                  "gnuseye_toggle_layer"
                  "gsurf_back" "gsurf_click" "gsurf_click_element"
                  "gsurf_download_cancel" "gsurf_forward" "gsurf_lite_open"
                  "gsurf_navigate" "gsurf_open" "gsurf_reload"
                  "gsurf_run_action" "gsurf_set_zoom" "gsurf_stop"
                  "gsurf_toggle_module"
                  "lrgeditor_action" "lrgeditor_add_primitive"
                  "lrgeditor_add_visual" "lrgeditor_delete" "lrgeditor_move"
                  "lrgeditor_open" "lrgeditor_play" "lrgeditor_save"
                  "lrgeditor_select" "lrgeditor_stop"
                  "secondbrain_expand" "secondbrain_ingest_cancel"
                  "secondbrain_open" "secondbrain_set_layout"
                  "ai_call" "ai_prompt" "ai_open_chat" "record_audio"))
    (let ((entry (cmacs-capability-describe-tool name)))
      ;; A build without the subsystem has no such tool to ask about.
      (when entry
        (ert-info ((format "tool %s" name))
          (should (plist-get entry :destructive))
          (should (memq 'dbus (plist-get entry :surfaces)))
          (should (memq 'cli (plist-get entry :surfaces)))
          (should (memq 'mcp (plist-get entry :surfaces))))))))

;;;; Families compile their tools, whatever the build loaded first

(ert-deftest cmacs-capability-test-deftool-macro-known-at-compile-time ()
  "Every file using `cmacs-brigade-deftool' loads the registry to compile.
The macro is an autoload, but a build can compile a file before that
autoload is in effect.  A use the compiler cannot expand is compiled as
a call to a FUNCTION named `cmacs-brigade-deftool', and loading the
result evaluates the tool name as a variable: the whole family fails
with \"void-variable db-connections\".  The tree's own build worked
while the OS image shipped the broken `.elc', so the rule is checked
in the source: a top-level `require' of the registry (or of
cmacs-brigade-tools, which requires it), or one in `eval-when-compile'.
A `declare-function' of the macro is refused too: it tells the
compiler the macro is a function."
  (let* ((root (cmacs-capability-tests--source-root))
         (dir (and root (expand-file-name "lisp/cmacs" root)))
         (bad nil))
    (skip-unless (and dir (file-directory-p dir)))
    (dolist (file (directory-files dir t "\\.el\\'"))
      (unless (equal (file-name-nondirectory file)
                     "cmacs-brigade-registry.el")
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (re-search-forward
                 "^[ \t]*(declare-function cmacs-brigade-deftool\\_>" nil t)
            (push (cons (file-name-nondirectory file) "declare-function")
                  bad))
          (goto-char (point-min))
          (when (and (re-search-forward
                      "^[ \t]*(cmacs-brigade-deftool[ \t\n]" nil t)
                     (progn
                       (goto-char (point-min))
                       (not (re-search-forward
                             (concat
                              "^(\\(?:eval-when-compile[ \t\n]+\\)?"
                              "(?require '"
                              "cmacs-brigade-\\(?:registry\\|tools\\)\\_>")
                             nil t))))
            (push (cons (file-name-nondirectory file) "no compile-time require")
                  bad)))))
    (should-not bad)))

(provide 'cmacs-capability-tests)

;;; cmacs-capability-tests.el ends here
