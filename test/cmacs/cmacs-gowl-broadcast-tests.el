;;; cmacs-gowl-broadcast-tests.el --- Tests for input broadcasting -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Zach Podbielniak
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; The Elisp half of gowl's input broadcasting (multiboxing): the team
;; and rule a plist turns into, the refusals made before anything is
;; sent, the opt-in startup (nothing loads unless asked), the module's
;; announcements driving the state and the hook, the RPC entry points
;; that never signal, and the D-Bus and MCP surfaces.  The last test
;; runs the real module in a second cmacs on gowl's headless backend.
;;
;; The example team is three EverQuest clients (EverQuest's live
;; servers allow boxing).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'cmacs)
(require 'cmacs-gowl-broadcast)

;; Special, so the fake-compositor `let' below binds it dynamically and
;; `add-hook' lands in the binding (cmacs-gowl.el, which defines it, is
;; not loaded by these tests).
(defvar cmacs-gowl-module-event-functions)

(defconst cmacs-gowl-broadcast-tests--this-file
  (or load-file-name buffer-file-name)
  "This file, for finding the source tree.")

(defun cmacs-gowl-broadcast-tests--parse (json)
  "JSON as alists and lists."
  (json-parse-string json :object-type 'alist :array-type 'list
                     :false-object :false :null-object nil))

(defun cmacs-gowl-broadcast-tests--source-file (relative)
  "RELATIVE (to the source tree root) as an absolute name, or nil."
  (let ((f (expand-file-name (concat "../../" relative)
                             (file-name-directory
                              cmacs-gowl-broadcast-tests--this-file))))
    (and (file-readable-p f) f)))

(defconst cmacs-gowl-broadcast-tests--team
  '(:slots ((tank :match (app-id "eqgame.exe") :focus-key "Super+F1")
            (cleric :match (and (app-id "eqgame.exe") (title ~ "Cleric"))
                    :delivery activate)
            wizard)
    :groups ((casters cleric wizard)))
  "The EverQuest team, as `cmacs-gowl-broadcast-define-team' takes it.")

;;;; Teams

(ert-deftest cmacs-gowl-broadcast-test-team-json ()
  "A team plist becomes the team the module reads."
  (let* ((team (cmacs-gowl-broadcast-tests--parse
                (apply #'cmacs-gowl-broadcast-team-json "eq"
                       cmacs-gowl-broadcast-tests--team)))
         (slots (alist-get 'slots team)))
    (should (equal (alist-get 'name team) "eq"))
    (should (= (length slots) 3))
    (should (equal (car slots)
                   '((name . "tank") (match . "app-id=\"eqgame.exe\"")
                     (focus-key . "Super+F1"))))
    (should (equal (nth 1 slots)
                   '((name . "cleric")
                     (match . "(app-id=\"eqgame.exe\" and title~\"Cleric\")")
                     (delivery . "activate"))))
    ;; a bare name: filled by hand only
    (should (equal (nth 2 slots) '((name . "wizard"))))
    (should (equal (alist-get 'groups team)
                   '((casters "cleric" "wizard"))))))

(ert-deftest cmacs-gowl-broadcast-test-team-refusals ()
  "Bad teams are refused before anything is sent."
  (dolist (bad '((:groups ((g a)))                       ; no slots
                 (:slots ((a :match (colour "red"))))     ; unknown field
                 (:slots ((a :match (focused-slot "a")))) ; a rule field
                 (:slots ((a :delivery teleport)))
                 (:slots ((a :sticky t)))                 ; unknown slot key
                 (:slots ("two words"))
                 (:slots (a) :colour red)))               ; unknown team key
    (should-error (apply #'cmacs-gowl-broadcast-team-json "t" bad)
                  :type 'user-error))
  (should-error (cmacs-gowl-broadcast-team-json "a b" :slots '(x))
                :type 'user-error))

;;;; Rules

(ert-deftest cmacs-gowl-broadcast-test-rule-json ()
  "Every rule key has one JSON form."
  (let ((rule (cmacs-gowl-broadcast-tests--parse
               (cmacs-gowl-broadcast-rule-json
                "follow" :team "eq" :when '(focused-slot "tank")
                :enabled nil
                :keys '("1-9" w a s d) :exclude '(Return slash)
                :modifiers 'none
                :targets '(all-other (group casters))
                :translate '((cleric ("1" . "2")) (* (f . "Shift+g")))
                :mode 'round-robin :reset-ms 1500
                :delivery 'activate :mouse 'scaled :delay-ms 25
                :local 'block))))
    (should (equal (alist-get 'name rule) "follow"))
    (should (equal (alist-get 'team rule) "eq"))
    (should (equal (alist-get 'when rule) "focused-slot=\"tank\""))
    (should (eq (alist-get 'enabled rule) :false))
    (should (equal (alist-get 'keys rule)
                   '((include "1-9" "w" "a" "s" "d")
                     (exclude "Return" "slash"))))
    (should (equal (alist-get 'modifiers rule) "none"))
    (should (equal (alist-get 'targets rule)
                   '("all-other" "group:casters")))
    (should (equal (alist-get 'translate rule)
                   '((cleric (\1 . "2")) (* (f . "Shift+g")))))
    (should (equal (alist-get 'mode rule) "round-robin"))
    (should (equal (alist-get 'reset-ms rule) 1500))
    (should (equal (alist-get 'delivery rule) "activate"))
    (should (equal (alist-get 'mouse rule) "scaled"))
    (should (equal (alist-get 'delay-ms rule) 25))
    (should (equal (alist-get 'local rule) "block"))))

(ert-deftest cmacs-gowl-broadcast-test-rule-key-shorthands ()
  "`all', a single target, and an explicit empty key list."
  (let ((all (cmacs-gowl-broadcast-tests--parse
              (cmacs-gowl-broadcast-rule-json
               "a" :team "eq" :keys 'all :targets '(slot cleric))))
        (clicks (cmacs-gowl-broadcast-tests--parse
                 (cmacs-gowl-broadcast-rule-json
                  "c" :team "eq" :keys nil :mouse 'same))))
    (should (equal (alist-get 'keys all) '((include "all"))))
    (should (equal (alist-get 'targets all) '("slot:cleric")))
    ;; :keys nil is NO keys: a clicks-only rule
    (should (equal (alist-get 'keys clicks) '((include))))))

(ert-deftest cmacs-gowl-broadcast-test-rule-refusals ()
  "Bad rules are refused before anything is sent."
  (dolist (bad '((:keys (a))                                 ; no team
                 (:team "eq" :when (colour "red"))
                 (:team "eq" :targets (everyone))
                 (:team "eq" :targets ((slot "a b")))
                 (:team "eq" :mode sometimes)
                 (:team "eq" :mouse maybe)
                 (:team "eq" :local drop)
                 (:team "eq" :modifiers some)
                 (:team "eq" :delivery teleport)
                 (:team "eq" :delay-ms -1)
                 (:team "eq" :translate (oops))
                 (:team "eq" :colour red)))
    (should-error (apply #'cmacs-gowl-broadcast-rule-json "r" bad)
                  :type 'user-error)))

;;;; Defining, starting

(ert-deftest cmacs-gowl-broadcast-test-define-before-start ()
  "Defining without a compositor keeps the definition; redefining replaces."
  (let ((cmacs-gowl-broadcast--teams nil)
        (cmacs-gowl-broadcast--rules nil)
        (sent nil))
    (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil))
              ((symbol-function 'gowl-run-command)
               (lambda (&rest args) (push args sent) "OK")))
      (should (equal (apply #'cmacs-gowl-broadcast-define-team "eq"
                            cmacs-gowl-broadcast-tests--team)
                     "eq"))
      (cmacs-gowl-broadcast-define-rule "follow" :team "eq")
      (cmacs-gowl-broadcast-define-rule "follow" :team "eq" :keys '(w))
      (should (= (length cmacs-gowl-broadcast--rules) 1))
      (should (equal (plist-get (cdar cmacs-gowl-broadcast--rules) :keys)
                     '(w)))
      (should-not sent)
      (should-error (cmacs-gowl-broadcast-define-rule "bad" :team "eq"
                                                      :mode 'never)
                    :type 'user-error))))

(defmacro cmacs-gowl-broadcast-tests--with-fake-gowl (&rest body)
  "Run BODY with a fake running compositor that records commands.
Binds `enabled' (module loads), `configured' (settings pushed) and
`commands' (every line sent, newest first)."
  (declare (indent 0))
  `(let ((enabled nil) (configured nil) (commands nil)
         (cmacs-gowl-broadcast--enabled nil)
         (cmacs-gowl-module-event-functions nil))
     (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
               ((symbol-function 'gowl-enable-module)
                (lambda (&rest args) (push args enabled) t))
               ((symbol-function 'gowl-configure-module)
                (lambda (&rest args) (push args configured) t))
               ((symbol-function 'gowl-run-command)
                (lambda (line &rest _)
                  (push line commands)
                  (cond ((equal line "broadcast-status")
                         (and enabled
                              "OK {\"on\":false,\"teams\":[],\"rules\":[]}"))
                        ((string-prefix-p "broadcast-add-" line)
                         "OK added x")
                        ((equal line "broadcast-toggle") "OK on")
                        (t "OK")))))
       ,@body)))

(ert-deftest cmacs-gowl-broadcast-test-opt-in-startup ()
  "Nothing configured, nothing loaded; `enable' loads it with settings."
  (let ((cmacs-gowl-broadcast--teams nil)
        (cmacs-gowl-broadcast--rules nil)
        (cmacs-gowl-broadcast-teams nil)
        (cmacs-gowl-broadcast-rules nil)
        (cmacs-gowl-broadcast-enable nil)
        (cmacs-gowl-broadcast-toggle-key "Super+b")
        (cmacs-gowl-broadcast-strict t))
    (cmacs-gowl-broadcast-tests--with-fake-gowl
      (cmacs-gowl-broadcast--on-start)
      (should-not enabled)
      (should-not commands)

      (setq cmacs-gowl-broadcast-enable t)
      (cmacs-gowl-broadcast--on-start)
      (should (equal enabled '(("broadcast"))))
      (let ((settings (cadr (car configured))))
        (should (equal (alist-get "toggle-key" settings nil nil #'equal)
                       "Super+b"))
        (should (equal (alist-get "strict" settings nil nil #'equal)
                       "true")))
      ;; listening for the module's announcements
      (should (memq #'cmacs-gowl-broadcast--on-module-event
                    cmacs-gowl-module-event-functions)))))

(ert-deftest cmacs-gowl-broadcast-test-teams-before-rules ()
  "Configured teams are installed before rules, which name them."
  (let ((cmacs-gowl-broadcast--teams nil)
        (cmacs-gowl-broadcast--rules nil)
        (cmacs-gowl-broadcast-enable nil)
        (cmacs-gowl-broadcast-rules '(("follow" :team "eq")))
        (cmacs-gowl-broadcast-teams
         (list (cons "eq" cmacs-gowl-broadcast-tests--team))))
    (cmacs-gowl-broadcast-tests--with-fake-gowl
      (cmacs-gowl-broadcast--on-start)
      (let* ((sent (reverse commands))
             (team (cl-position-if (lambda (l)
                                     (string-prefix-p "broadcast-add-team " l))
                                   sent))
             (rule (cl-position-if (lambda (l)
                                     (string-prefix-p "broadcast-add-rule " l))
                                   sent)))
        (should team)
        (should rule)
        (should (< team rule))))))

(ert-deftest cmacs-gowl-broadcast-test-command-errors ()
  "The module's ERROR replies and its absence become user errors."
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) t))
            ((symbol-function 'gowl-run-command)
             (lambda (line &rest _)
               (if (string-suffix-p "missing" line) nil
                 "ERROR no team named x"))))
    (should-error (cmacs-gowl-broadcast--command "broadcast-remove-team x")
                  :type 'user-error)
    (should-error (cmacs-gowl-broadcast--command "broadcast-missing")
                  :type 'user-error)))

;;;; Hearing the module

(ert-deftest cmacs-gowl-broadcast-test-module-events ()
  "The module's announcements drive the state and the changed hook."
  (let ((cmacs-gowl-broadcast--on nil)
        (cmacs-gowl-broadcast--team nil)
        (seen nil)
        (cmacs-gowl-broadcast-changed-functions nil))
    (add-hook 'cmacs-gowl-broadcast-changed-functions
              (lambda (state detail) (push (list state detail) seen)))
    (cmacs-gowl-broadcast--on-module-event "broadcast" "on eq")
    (should cmacs-gowl-broadcast--on)
    (should (equal cmacs-gowl-broadcast--team "eq"))
    (should (cmacs-gowl-broadcast--lighter))
    ;; another module's news is not ours
    (cmacs-gowl-broadcast--on-module-event "macro" "off panic")
    (should cmacs-gowl-broadcast--on)
    (cmacs-gowl-broadcast--on-module-event "broadcast" "off panic")
    (should-not cmacs-gowl-broadcast--on)
    (should-not (cmacs-gowl-broadcast--lighter))
    (should (equal seen '((off "panic") (on "eq"))))
    ;; switched on from a window in no team
    (cmacs-gowl-broadcast--on-module-event "broadcast" "on -")
    (should cmacs-gowl-broadcast--on)
    (should-not cmacs-gowl-broadcast--team)))

;;;; RPC

(ert-deftest cmacs-gowl-broadcast-test-rpc-never-signals ()
  "The RPC entry points answer \"ERROR ...\" rather than signal."
  (cl-letf (((symbol-function 'gowl-running-p) (lambda (&rest _) nil)))
    (should (string-prefix-p "ERROR" (cmacs-gowl-broadcast-rpc "status")))
    (should (string-prefix-p "ERROR" (cmacs-gowl-broadcast-rpc "dance")))
    (should (string-prefix-p "ERROR"
                             (cmacs-gowl-broadcast-command "macro-run x")))
    (should (string-prefix-p "ERROR"
                             (cmacs-gowl-broadcast-command
                              "broadcast-status")))))

(ert-deftest cmacs-gowl-broadcast-test-toggle-loads-module ()
  "Switching on is a first use: it loads the module, then toggles."
  (let ((cmacs-gowl-broadcast--teams nil)
        (cmacs-gowl-broadcast--rules nil))
    (cmacs-gowl-broadcast-tests--with-fake-gowl
      (should (equal (cmacs-gowl-broadcast-toggle) "on"))
      (should (equal enabled '(("broadcast"))))
      (should (member "broadcast-toggle" commands)))))

(ert-deftest cmacs-gowl-broadcast-test-dbus-source ()
  "D-Bus Broadcast is on the compositor interface, checks its verb, and
ModuleEvent relays the compositor's module-event signal."
  (let ((iface (cmacs-gowl-broadcast-tests--source-file
                "cmacs/dbus/cmacs-dbus-iface-compositor.c"))
        (dispatch (cmacs-gowl-broadcast-tests--source-file
                   "cmacs/glib/cmacs-eval-dispatch.c"))
        (gowl (cmacs-gowl-broadcast-tests--source-file
               "cmacs/gowl/cmacs-gowl.c")))
    (skip-unless (and iface dispatch gowl))
    (with-temp-buffer
      (insert-file-contents iface)
      (should (search-forward "<method name='Broadcast'>" nil t))
      (goto-char (point-min))
      (should (search-forward "<signal name='ModuleEvent'>" nil t))
      (should (search-forward "cmacs_dispatch_gowl_broadcast (verb" nil t)))
    (with-temp-buffer
      (insert-file-contents dispatch)
      (should (re-search-forward "^cmacs_dispatch_gowl_broadcast " nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        ;; the verb is checked against a fixed list before any form
        (should (string-match-p "g_strv_contains (verbs, verb)" body))
        (should (string-match-p "cmacs-gowl-broadcast-rpc" body))))
    (with-temp-buffer
      (insert-file-contents gowl)
      (should (search-forward "\"module-event\"" nil t)))))

(ert-deftest cmacs-gowl-broadcast-test-mcp-source ()
  "The cmacs MCP server registers the broadcast tools, and escapes the
lines it splices into Lisp."
  (let ((tools (cmacs-gowl-broadcast-tests--source-file
                "cmacs/mcp/cmacs-mcp-tools-gowl.c")))
    (skip-unless tools)
    (with-temp-buffer
      (insert-file-contents tools)
      (dolist (name '("gowl_broadcast_status" "gowl_broadcast_list"
                      "gowl_broadcast_set" "gowl_broadcast_add_team"
                      "gowl_broadcast_add_rule" "gowl_broadcast_remove"
                      "gowl_broadcast_assign" "gowl_broadcast_focus_slot"))
        (goto-char (point-min))
        (should (search-forward (format "\"%s\"" name) nil t)))
      (goto-char (point-min))
      (should (re-search-forward "^gowl_broadcast_line " nil t))
      (let ((body (buffer-substring (point)
                                    (progn (re-search-forward "^}" nil t)
                                           (point)))))
        (should (string-match-p "cmacs_dispatch_lisp_escape (line)" body))))))

;;;; Through the real module, in a second cmacs

(defun cmacs-gowl-broadcast-tests--run-headless (form)
  "Evaluate FORM in a second cmacs on gowl's headless backend.
Return (STATUS . OUTPUT): a private runtime directory, systemd off, no
parent display, pixman, fatal criticals, as the other child-cmacs
tests do it."
  (let* ((parent (getenv "XDG_RUNTIME_DIR"))
         (runtime (make-temp-file
                   (expand-file-name "cmacs-gowl-broadcast-test-" parent) t))
         (default-directory (file-name-as-directory runtime))
         (emacs (expand-file-name invocation-name invocation-directory))
         (timeout (executable-find "timeout"))
         (process-environment
          (append (list "WAYLAND_DISPLAY" "WAYLAND_SOCKET" "DISPLAY"
                        "GOWL_DISABLE_SYSTEMD=1"
                        (concat "XDG_RUNTIME_DIR=" runtime)
                        (concat "XDG_CONFIG_HOME=" runtime)
                        (concat "XDG_STATE_HOME="
                                (expand-file-name "state" runtime))
                        (concat "XDG_CACHE_HOME="
                                (expand-file-name "cache" runtime))
                        (concat "GOWL_MENU_FILE="
                                (expand-file-name
                                 "../../deps/gowl/data/menu.yaml"
                                 (file-name-directory
                                  cmacs-gowl-broadcast-tests--this-file)))
                        "WLR_BACKENDS=headless"
                        "WLR_HEADLESS_OUTPUTS=1"
                        "WLR_RENDERER=pixman"
                        "G_DEBUG=fatal-criticals")
                  process-environment)))
    (unwind-protect
        (with-temp-buffer
          (let ((status (apply #'call-process (or timeout emacs) nil t nil
                               (append (and timeout (list "120" emacs))
                                       (list "--batch" "-Q" "--eval"
                                             "(setq backtrace-on-error-noninteractive nil)"
                                             "--eval" (prin1-to-string form))))))
            (cons status (buffer-string))))
      (delete-directory runtime t))))

(defconst cmacs-gowl-broadcast-tests--headless-form
  '(progn
     (defun test-wait (pred)
       (let ((n 0))
         (while (and (not (funcall pred)) (< n 100))
           (sit-for 0.05)
           (setq n (1+ n)))
         (funcall pred)))
     (gowl-start)
     (require 'cmacs-gowl)
     (require 'cmacs-gowl-broadcast)
     (cmacs-gowl--install-hook-bridges)
     ;; Opt-in: starting the compositor loaded no broadcast module
     (when (gowl-run-command "broadcast-status")
       (error "The broadcast module was loaded before anyone asked"))
     (setq cmacs-gowl-broadcast-toast nil)
     ;; Defining a team is a first use
     (cmacs-gowl-broadcast-define-team
      "eq" :slots '((tank :match (app-id "eqgame.exe") :focus-key "Super+F1")
                    (cleric :match (app-id "eqgame.exe")))
      :groups '((healers cleric)))
     (unless (gowl-run-command "broadcast-status")
       (error "Defining a team did not load the module"))
     (cmacs-gowl-broadcast-define-rule
      "follow" :team "eq" :when '(focused-slot "tank")
      :keys '("1-9" w) :targets 'all-other)
     (let* ((s (cmacs-gowl-broadcast-status))
            (team (car (alist-get 'teams s)))
            (rule (car (alist-get 'rules s))))
       (unless (equal (alist-get 'name team) "eq")
         (error "The module has no team eq: %S" s))
       (unless (and (equal (alist-get 'name rule) "follow")
                    (null (alist-get 'problem rule)))
         (error "The rule did not arrive in force: %S" rule))
       (when (alist-get 'on s)
         (error "Broadcasting was on before it was switched on")))
     ;; A rule naming a team that does not exist is kept and reported
     (cmacs-gowl-broadcast-define-rule "ghost" :team "nobody")
     (unless (cl-some (lambda (r) (and (equal (alist-get 'name r) "ghost")
                                       (alist-get 'problem r)))
                      (alist-get 'rules (cmacs-gowl-broadcast-status)))
       (error "A rule for a missing team was not reported"))
     ;; Switching on: the module says so, the state follows through
     ;; the module-event bridge
     (cmacs-gowl-broadcast-on)
     (unless (alist-get 'on (cmacs-gowl-broadcast-status))
       (error "broadcast-on left it off"))
     (unless (test-wait (lambda () cmacs-gowl-broadcast--on))
       (error "The module-event never reached Lisp"))
     (cmacs-gowl-broadcast-panic)
     (when (alist-get 'on (cmacs-gowl-broadcast-status))
       (error "Panic left it on"))
     (unless (test-wait (lambda () (not cmacs-gowl-broadcast--on)))
       (error "The panic's module-event never reached Lisp"))
     ;; Strict mode refuses the mirroring rule, at once
     (cmacs-gowl-broadcast-strict 1)
     (unless (alist-get 'problem
                        (cl-find "follow"
                                 (alist-get 'rules
                                            (cmacs-gowl-broadcast-status))
                                 :key (lambda (r) (alist-get 'name r))
                                 :test #'equal))
       (error "Strict mode did not refuse a mirroring rule"))
     ;; D-Bus/MCP's entry point
     (unless (string-prefix-p "{" (cmacs-gowl-broadcast-rpc "status"))
       (error "rpc status did not answer JSON"))
     (gowl-stop)
     (princ "cmacs-gowl-broadcast: ok\n"))
  "What `cmacs-gowl-broadcast-test-headless' runs in the second cmacs.")

(ert-deftest cmacs-gowl-broadcast-test-headless ()
  "The broadcast module, driven from Elisp in a real compositor.
Not loaded until asked for; teams and rules arrive and are reported;
on, panic and strict mode work, and the module's announcements reach
Lisp through the module-event bridge."
  (skip-unless (fboundp 'gowl-start))
  (skip-unless (let ((d (getenv "XDG_RUNTIME_DIR")))
                 (and d (file-directory-p d))))
  (let* ((result (cmacs-gowl-broadcast-tests--run-headless
                  cmacs-gowl-broadcast-tests--headless-form))
         (status (car result))
         (output (cdr result)))
    (ert-info (output :prefix "child output: ")
      (should (eql status 0))
      (should (string-match-p "cmacs-gowl-broadcast: ok" output)))))

(provide 'cmacs-gowl-broadcast-tests)

;;; cmacs-gowl-broadcast-tests.el ends here
