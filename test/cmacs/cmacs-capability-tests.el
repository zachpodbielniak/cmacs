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

(defun cmacs-capability-tests--c-calc-tools (root)
  "Return ((NAME . PARAM-NAMES)...) from the calculator MCP C file at ROOT."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "cmacs/mcp/cmacs-mcp-tools-calculator.c" root))
    (let ((out nil))
      (while (re-search-forward "mcp_tool_new (\"\\([a-z_]+\\)\"" nil t)
        (let* ((name (match-string 1))
               (end (save-excursion
                      (re-search-forward "g_object_unref (tool)" nil t)))
               (params nil))
          (save-excursion
            (when (re-search-forward "\\\\\"properties\\\\\":{" end t)
              (while (re-search-forward
                      "\\\\\"\\([a-z_]+\\)\\\\\":{\\\\\"type\\\\\"" end t)
                (push (match-string 1) params))))
          (push (cons name (nreverse params)) out)))
      (nreverse out))))

(ert-deftest cmacs-capability-test-calculator-family-matches-c ()
  "The registry calculator tools are the C ones: same names, same params.
The C handlers stay as the fallback for a build without the brigade, so
the two must not drift while both exist."
  (let ((root (cmacs-capability-tests--source-root)))
    (skip-unless root)
    (skip-unless (file-readable-p
                  (expand-file-name
                   "cmacs/mcp/cmacs-mcp-tools-calculator.c" root)))
    (cmacs-capability-tests--with-registry
      (let ((load-prefer-newer t))
        (load (expand-file-name "lisp/cmacs/cmacs-calculator-tools" root)
              nil t))
      (let ((c (cmacs-capability-tests--c-calc-tools root)))
        (should (= (length c) 5))
        (should (equal (sort (mapcar #'car c) #'string<)
                       (mapcar (lambda (e) (plist-get e :name))
                               (cmacs-capability-describe))))
        (pcase-dolist (`(,name . ,params) c)
          (let ((entry (cmacs-capability-describe-tool name)))
            (should (equal (mapcar (lambda (p) (plist-get p :name))
                                   (plist-get entry :params))
                           params))
            ;; Read-only tools, so nothing keeps them off any surface.
            (should-not (plist-get entry :destructive))
            (should (memq 'dbus (plist-get entry :surfaces)))
            (should (string-prefix-p "calc " (plist-get entry :cli))))))
      ;; The fallback must stand aside when the registry already serves
      ;; a name, or it would silently replace the registry's handler.
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "cmacs/mcp/cmacs-mcp-tools-calculator.c" root))
        (should-not (re-search-forward
                     "mcp_server_add_tool (server, tool, handle_calc" nil t))
        (goto-char (point-min))
        (should (= (how-many "calc_add_tool (server, tool, handle_calc") 5))))))

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
      (should-not (member "cmacs-capability.el" files)))))

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

(provide 'cmacs-capability-tests)

;;; cmacs-capability-tests.el ends here
